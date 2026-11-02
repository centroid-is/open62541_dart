// An encrypted open62541 server and clients with certificates, for the
// suites that verify a server certificate (client_trust_list_test.dart) or
// discover one (endpoint_discovery_test.dart). The Dart `Server` has no
// security API, so the server here is open62541's own
// `UA_ServerConfig_setDefaultWithSecurityPolicies` through the raw bindings.
// Certificates come from `UA_CreateCertificate` (mbedTLS), so there is no
// external tool and every platform the package builds on can run them.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show getType;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

/// A certificate (DER) with the private key (DER) that goes with it.
typedef Identity = ({Uint8List certificate, Uint8List privateKey});

/// open62541's default ApplicationUri, on the client and the server. The
/// server checks a client certificate's URI against the ApplicationDescription
/// of the session, so the client certificate carries this one; the server
/// certificate too, which spares the server config a URI of its own.
const applicationUri = 'urn:open62541.unconfigured.application';

/// A self-signed certificate from open62541's `UA_CreateCertificate`
/// (mbedTLS): no external tool, every platform.
Identity createIdentity(String commonName) {
  return using((arena) {
    final subject = arena<raw.UA_String>(2);
    subject[0].set('O=open62541_dart test', allocator: arena);
    subject[1].set('CN=$commonName', allocator: arena);
    final altNames = arena<raw.UA_String>(2);
    altNames[0].set('DNS:localhost', allocator: arena);
    altNames[1].set('URI:$applicationUri', allocator: arena);
    // 2048 bits: the 4096-bit default takes seconds per key with mbedTLS.
    final keySize = arena<ffi.Uint16>()..value = 2048;
    final param = arena<raw.UA_KeyValuePair>();
    param.ref.key = raw.UA_QUALIFIEDNAME(0, 'key-size-bits'.toNativeUtf8(allocator: arena).cast());
    param.ref.value.type = getType(UaTypes.uint16);
    param.ref.value.storageTypeAsInt = raw.UA_VariantStorageType.UA_VARIANT_DATA_NODELETE.value;
    param.ref.value.data = keySize.cast();
    final params = arena<raw.UA_KeyValueMap>();
    params.ref.mapSize = 1;
    params.ref.map = param;
    final privateKey = arena<raw.UA_ByteString>();
    final certificate = arena<raw.UA_ByteString>();
    final logger = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_ERROR);
    try {
      final status = raw.UA_CreateCertificate(
        logger,
        subject,
        2,
        altNames,
        2,
        raw.UA_CertificateFormat.UA_CERTIFICATEFORMAT_DER,
        params,
        privateKey,
        certificate,
      );
      expect(status, raw.UA_STATUSCODE_GOOD, reason: 'UA_CreateCertificate: ${statusCodeToString(status)}');
      final identity = (
        certificate: Uint8List.fromList(certificate.ref.data.asTypedList(certificate.ref.length)),
        privateKey: Uint8List.fromList(privateKey.ref.data.asTypedList(privateKey.ref.length)),
      );
      raw.UA_clear(certificate.cast(), getType(UaTypes.byteString));
      raw.UA_clear(privateKey.cast(), getType(UaTypes.byteString));
      return identity;
    } finally {
      // UA_Log_Stdout_new's logger frees itself through its clear.
      logger.ref.clear.asFunction<void Function(ffi.Pointer<raw.UA_Logger>)>()(logger);
    }
  }, ua_calloc);
}

/// An open62541 server with every security policy the build has
/// (Basic256Sha256, Aes128Sha256RsaOaep, ...) next to None, trusting
/// [trustedClients], pumped on this isolate until [stop].
class SecureServer {
  SecureServer._(this._server, this.port);

  final ffi.Pointer<raw.UA_Server> _server;
  final int port;
  bool _running = true;
  final Completer<void> _stopped = Completer<void>();

  static SecureServer start(Identity identity, {required List<Uint8List> trustedClients}) {
    // The config is scratch: UA_Server_newWithConfig moves its contents into
    // the server. The lists are copied by the certificate group.
    final server = using((arena) {
      final config = arena<raw.UA_ServerConfig>();
      config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
      final trust = arena<raw.UA_ByteString>(trustedClients.length);
      for (var i = 0; i < trustedClients.length; i++) {
        trust[i].fromBytes(trustedClients[i]);
      }
      final status = raw.UA_ServerConfig_setDefaultWithSecurityPolicies(
        config,
        0,
        _byteString(arena, identity.certificate),
        _byteString(arena, identity.privateKey),
        trust,
        trustedClients.length,
        ffi.nullptr,
        0,
        ffi.nullptr,
        0,
      );
      for (var i = 0; i < trustedClients.length; i++) {
        trust[i].free();
      }
      expect(status, raw.UA_STATUSCODE_GOOD, reason: 'setDefaultWithSecurityPolicies: ${statusCodeToString(status)}');
      return raw.UA_Server_newWithConfig(config);
    }, ua_calloc);
    final startup = raw.UA_Server_run_startup(server);
    expect(startup, raw.UA_STATUSCODE_GOOD, reason: 'UA_Server_run_startup: ${statusCodeToString(startup)}');
    // Port 0: the OS picked one, startup registered it in the DiscoveryUrls
    // (as Server.port reads it).
    final url = raw.UA_Server_getConfig(server).ref.applicationDescription.discoveryUrls[0].value;
    final port = int.parse(RegExp(r':(\d+)/?$').firstMatch(url)!.group(1)!);
    final secure = SecureServer._(server, port);
    () async {
      while (secure._running) {
        raw.UA_Server_run_iterate(server, false);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      secure._stopped.complete();
    }();
    return secure;
  }

  String get url => 'opc.tcp://127.0.0.1:$port';

  Future<void> stop() async {
    _running = false;
    await _stopped.future;
    raw.UA_Server_run_shutdown(_server);
    raw.UA_Server_delete(_server);
  }

  static ffi.Pointer<raw.UA_ByteString> _byteString(Arena arena, Uint8List bytes) {
    final string = arena<raw.UA_ByteString>();
    string.ref.length = bytes.length;
    string.ref.data = arena<ffi.Uint8>(bytes.length);
    string.ref.data.asTypedList(bytes.length).setAll(0, bytes);
    return string;
  }
}

/// A client of [clientType] with [identity] and the given verification,
/// pumped, not yet connected. Deleted at the end of the test.
Future<ClientApi> secureClient(
  String clientType,
  Identity identity, {
  List<Uint8List>? trustList,
  List<Uint8List>? issuerList,
  List<Uint8List>? revocationList,
  bool acceptAllCertificates = false,
}) async {
  final ClientApi client;
  switch (clientType) {
    case 'isolate':
      final isolate = await ClientIsolate.create(
        securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
        certificate: identity.certificate,
        privateKey: identity.privateKey,
        trustList: trustList,
        issuerList: issuerList,
        revocationList: revocationList,
        acceptAllCertificates: acceptAllCertificates,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      // runIterate fails once the client is deleted (expected in tearDown).
      unawaited(isolate.runIterate().catchError((_) {}));
      client = isolate;
    case 'direct':
      final direct = Client(
        securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
        certificate: identity.certificate,
        privateKey: identity.privateKey,
        trustList: trustList,
        issuerList: issuerList,
        revocationList: revocationList,
        acceptAllCertificates: acceptAllCertificates,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      () async {
        while (direct.runIterate(const Duration(milliseconds: 10))) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }();
      client = direct;
    default:
      throw ArgumentError('Unknown client type: $clientType');
  }
  addTearDown(client.delete);
  return client;
}
