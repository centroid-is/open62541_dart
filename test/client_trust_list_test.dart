// A client with a certificate used to accept any server certificate
// (`UA_CertificateGroup_AcceptAll` after `UA_ClientConfig_setDefaultEncryption`
// with empty lists): the channel was encrypted, the server never
// authenticated. Now the server certificate is verified against the
// `trustList` (plus `issuerList` and `revocationList`), `acceptAllCertificates`
// is the explicit opt-out, and a certificate with neither is an ArgumentError
// (open62541 keeps accept-all for an empty trust list). The Dart `Server` has
// no security API, so the server here is open62541's own
// `UA_ServerConfig_setDefaultWithSecurityPolicies` through the raw bindings,
// with certificates from `UA_CreateCertificate` (mbedTLS); the CA-issued
// cases need openssl and are skipped without it.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show getType;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'common.dart';
import 'heap_growth.dart';

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

/// Certificates issued by a CA, made with openssl: a CA, a server certificate
/// it signed, and a CRL of the CA that revokes that server certificate. Null
/// when openssl is not on the PATH.
class IssuedCertificates {
  IssuedCertificates._({required this.ca, required this.server, required this.crl});

  final Uint8List ca;
  final Identity server;
  final Uint8List crl;

  /// Null when openssl is not on the PATH. The files are made in a fresh
  /// temporary directory, which [create] deletes again.
  static Future<IssuedCertificates?> create() async {
    final dir = await Directory.systemTemp.createTemp('open62541_trust_list_');
    try {
      return await _create(dir.path);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  static Future<IssuedCertificates?> _create(String path) async {
    Future<bool> openssl(List<String> args) async {
      final ProcessResult result;
      try {
        result = await Process.run('openssl', args, workingDirectory: path);
      } on ProcessException {
        return false;
      }
      if (result.exitCode != 0) fail('openssl ${args.join(' ')}: ${result.stderr}');
      return true;
    }

    if (!await openssl(['version'])) return null;
    await File('$path/leaf.cnf').writeAsString(
      'subjectAltName=URI:$applicationUri,DNS:localhost\n'
      'keyUsage=critical,digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment\n'
      'extendedKeyUsage=serverAuth,clientAuth\n'
      'basicConstraints=CA:FALSE\n',
    );
    // Relative names: every openssl call runs in [path], and an absolute
    // Windows path in an OpenSSL config loses its backslashes (the config
    // parser reads them as escapes).
    await File('$path/ca.cnf').writeAsString(
      '[ca]\ndefault_ca = test_ca\n'
      '[test_ca]\ndatabase = index.txt\ncrlnumber = crlnumber\n'
      'certificate = ca.pem\nprivate_key = ca.key\n'
      'default_md = sha256\ndefault_crl_days = 2\n',
    );
    await File('$path/index.txt').writeAsString('');
    await File('$path/crlnumber').writeAsString('01\n');
    for (final args in [
      // The CA.
      [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', //
        '-subj', '/O=open62541_dart test/CN=test CA', '-days', '2',
        '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
      ],
      // A server certificate the CA signs.
      [
        'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'server.key', '-out', 'server.csr', //
        '-subj', '/O=open62541_dart test/CN=issued server',
      ],
      [
        'x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', //
        '-out', 'server.pem', '-days', '2', '-extfile', 'leaf.cnf',
      ],
      // The CA revokes it.
      ['ca', '-config', 'ca.cnf', '-revoke', 'server.pem'],
      ['ca', '-config', 'ca.cnf', '-gencrl', '-out', 'crl.pem'],
      // DER, as the Client takes them.
      ['x509', '-in', 'ca.pem', '-outform', 'DER', '-out', 'ca.der'],
      ['x509', '-in', 'server.pem', '-outform', 'DER', '-out', 'server.der'],
      ['pkey', '-in', 'server.key', '-outform', 'DER', '-out', 'server_key.der'],
      ['crl', '-in', 'crl.pem', '-outform', 'DER', '-out', 'crl.der'],
    ]) {
      await openssl(args);
    }
    return IssuedCertificates._(
      ca: await File('$path/ca.der').readAsBytes(),
      server: (
        certificate: await File('$path/server.der').readAsBytes(),
        privateKey: await File('$path/server_key.der').readAsBytes(),
      ),
      crl: await File('$path/crl.der').readAsBytes(),
    );
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

Matcher refusedWith(int statusCode) =>
    throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', statusCode));

void main() {
  late Identity serverIdentity;
  late Identity clientIdentity;
  late Identity strangerIdentity;

  setUpAll(() {
    serverIdentity = createIdentity('test server');
    clientIdentity = createIdentity('test client');
    strangerIdentity = createIdentity('a stranger');
  });

  group('the certificate arguments are checked together:', () {
    test('a certificate without a trust list is refused, not silently accept-all', () {
      expect(
        () => Client(certificate: clientIdentity.certificate, privateKey: clientIdentity.privateKey),
        throwsArgumentError,
      );
      expect(
        () => Client(certificate: clientIdentity.certificate, privateKey: clientIdentity.privateKey, trustList: []),
        throwsArgumentError,
      );
      // Issuer certificates cannot anchor trust on their own.
      expect(
        () => Client(
          certificate: clientIdentity.certificate,
          privateKey: clientIdentity.privateKey,
          issuerList: [serverIdentity.certificate],
        ),
        throwsArgumentError,
      );
    });

    test('accept-all and a trust list contradict each other', () {
      expect(
        () => Client(
          certificate: clientIdentity.certificate,
          privateKey: clientIdentity.privateKey,
          trustList: [serverIdentity.certificate],
          acceptAllCertificates: true,
        ),
        throwsArgumentError,
      );
    });

    test('a certificate and a private key come together', () {
      expect(() => Client(certificate: clientIdentity.certificate), throwsArgumentError);
      expect(() => Client(privateKey: clientIdentity.privateKey), throwsArgumentError);
    });

    test('the lists and accept-all need a certificate', () {
      expect(() => Client(trustList: [serverIdentity.certificate]), throwsArgumentError);
      expect(() => Client(acceptAllCertificates: true), throwsArgumentError);
    });

    test('ClientIsolate.create checks the same, before spawning anything', () async {
      await expectLater(
        ClientIsolate.create(certificate: clientIdentity.certificate, privateKey: clientIdentity.privateKey),
        throwsArgumentError,
      );
      await expectLater(
        ClientIsolate.create(
          certificate: clientIdentity.certificate,
          privateKey: clientIdentity.privateKey,
          trustList: [serverIdentity.certificate],
          acceptAllCertificates: true,
        ),
        throwsArgumentError,
      );
      await expectLater(ClientIsolate.create(trustList: [serverIdentity.certificate]), throwsArgumentError);
    });
  });

  group('against a self-signed server:', () {
    late SecureServer server;

    setUpAll(() {
      server = SecureServer.start(serverIdentity, trustedClients: [clientIdentity.certificate]);
    });
    tearDownAll(() => server.stop());

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('with the server certificate in the trust list the session activates, encrypted', () async {
          final client = await secureClient(clientType, clientIdentity, trustList: [serverIdentity.certificate]);
          await client.connect(server.url);
          // A read proves the session, not just the channel.
          final time = await client.read(NodeId.serverStatusCurrentTime);
          expect(time.asDateTime!.difference(DateTime.now()).abs(), lessThan(const Duration(minutes: 1)));
          if (client is Client) {
            expect(client.config.securityMode, MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT);
            expect(client.config.securityPolicyUri, isNot('http://opcfoundation.org/UA/SecurityPolicy#None'));
          }
        });

        test('with an unrelated certificate in the trust list the server is refused as untrusted', () async {
          final client = await secureClient(clientType, clientIdentity, trustList: [strangerIdentity.certificate]);
          await expectLater(client.connect(server.url), refusedWith(raw.UA_STATUSCODE_BADCERTIFICATEUNTRUSTED));
        });

        test('acceptAllCertificates opens the channel to any server', () async {
          final client = await secureClient(clientType, clientIdentity, acceptAllCertificates: true);
          await client.connect(server.url);
          await client.read(NodeId.serverStatusCurrentTime);
        });

        test('an unrelated issuer certificate changes nothing for a trusted server', () async {
          final client = await secureClient(
            clientType,
            clientIdentity,
            trustList: [serverIdentity.certificate],
            issuerList: [strangerIdentity.certificate],
          );
          await client.connect(server.url);
          await client.read(NodeId.serverStatusCurrentTime);
        });
      });
    }
  });

  group('against a CA-issued server (openssl):', () {
    IssuedCertificates? issued;
    SecureServer? server;

    setUpAll(() async {
      issued = await IssuedCertificates.create();
      if (issued == null) return;
      server = SecureServer.start(issued!.server, trustedClients: [clientIdentity.certificate]);
    });
    tearDownAll(() => server?.stop());

    /// Skips the test when openssl is not on the PATH.
    Future<void> withIssued(Future<void> Function(IssuedCertificates issued, SecureServer server) body) async {
      if (issued == null) {
        markTestSkipped('openssl is not on the PATH, cannot issue certificates');
        return;
      }
      await body(issued!, server!);
    }

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('the CA certificate in the trust list trusts the server it issued', () async {
          await withIssued((issued, server) async {
            final client = await secureClient(clientType, clientIdentity, trustList: [issued.ca]);
            await client.connect(server.url);
            await client.read(NodeId.serverStatusCurrentTime);
          });
        });

        test('the CA in the issuer list completes the chain but trusts nothing', () async {
          await withIssued((issued, server) async {
            // Without the CA anywhere the chain cannot be built.
            final incomplete = await secureClient(
              clientType,
              clientIdentity,
              trustList: [strangerIdentity.certificate],
            );
            await expectLater(
              incomplete.connect(server.url),
              refusedWith(raw.UA_STATUSCODE_BADCERTIFICATECHAININCOMPLETE),
            );
            // With it as an issuer the chain is complete, and still untrusted.
            final untrusted = await secureClient(
              clientType,
              clientIdentity,
              trustList: [strangerIdentity.certificate],
              issuerList: [issued.ca],
            );
            await expectLater(untrusted.connect(server.url), refusedWith(raw.UA_STATUSCODE_BADCERTIFICATEUNTRUSTED));
          });
        });

        test("the CA's revocation list revokes the server certificate", () async {
          await withIssued((issued, server) async {
            final client = await secureClient(
              clientType,
              clientIdentity,
              trustList: [issued.ca],
              revocationList: [issued.crl],
            );
            await expectLater(client.connect(server.url), refusedWith(raw.UA_STATUSCODE_BADCERTIFICATEREVOKED));
          });
        });
      });
    }
  });

  test('a client with a certificate and lists leaves nothing on the C heap once deleted', () async {
    // The lists are what is new here: several copies of a certificate, so
    // that a leaked list stands out against the rest of a client's life.
    final trustList = [for (var i = 0; i < 4; i++) serverIdentity.certificate];
    final issuerList = [for (var i = 0; i < 4; i++) strangerIdentity.certificate];
    await expectNoHeapGrowth(
      () => Client(
        certificate: clientIdentity.certificate,
        privateKey: clientIdentity.privateKey,
        trustList: trustList,
        issuerList: issuerList,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      ).delete(),
      warmUp: 20,
      iterations: 10,
      rounds: 7,
      maxGrowth: 1000,
      attempts: 3,
    );
  });
}
