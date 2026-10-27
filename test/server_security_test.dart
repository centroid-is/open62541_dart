import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'pki_fixtures.dart';

const _serverUri = 'urn:open62541.dart.test.secured';
const _signAndEncrypt = MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;

/// An endpoint as GetEndpoints describes it, reduced to plain Dart values so
/// it crosses the isolate boundary.
typedef RawEndpoint = ({String policyUri, int mode, List<int> tokenTypes, Uint8List serverCertificate});

/// GetEndpoints over a raw client in another isolate: the call blocks until
/// answered, and the server is pumped by this one.
Future<List<RawEndpoint>> rawGetEndpoints(String url) => Isolate.run(() {
  final config = ua_calloc<raw.UA_ClientConfig>();
  raw.UA_ClientConfig_setDefault(config);
  // A configured endpoint skips the endpoint selection a session would need.
  config.ref.endpoint.endpointUrl.set(url);
  config.ref.endpoint.securityModeAsInt = MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE.value;
  config.ref.endpoint.securityPolicyUri.set(SecurityPolicy.none.uri);
  final client = raw.UA_Client_newWithConfig(config);
  ua_calloc.free(config);
  try {
    return using((arena) {
      final size = arena<ffi.Size>();
      final endpoints = arena<ffi.Pointer<raw.UA_EndpointDescription>>();
      final status = raw.UA_Client_getEndpoints(client, url.toNativeUtf8(allocator: arena).cast(), size, endpoints);
      if (status != raw.UA_STATUSCODE_GOOD) throw UaStatusException(status);
      final result = [
        for (var i = 0; i < size.value; i++)
          (
            policyUri: endpoints.value[i].securityPolicyUri.value,
            mode: endpoints.value[i].securityModeAsInt,
            tokenTypes: [
              for (var t = 0; t < endpoints.value[i].userIdentityTokensSize; t++)
                endpoints.value[i].userIdentityTokens[t].tokenTypeAsInt,
            ],
            serverCertificate: Uint8List.fromList(endpoints.value[i].serverCertificate.asTypedList()),
          ),
      ];
      raw.UA_Array_delete(endpoints.value.cast(), size.value, getTypeByIndex(raw.UA_TYPES_ENDPOINTDESCRIPTION));
      return result;
    }, ua_calloc);
  } finally {
    raw.UA_Client_delete(client);
  }
});

class SecuredServer {
  SecuredServer(ServerSecurity security, {String applicationUri = _serverUri})
    : server = Server(
        port: 0,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
        applicationUri: applicationUri,
        security: security,
      ) {
    server.start();
    _pump = Timer.periodic(const Duration(milliseconds: 2), (_) => server.runIterate());
  }

  final Server server;
  late final Timer _pump;

  String get url => 'opc.tcp://127.0.0.1:${server.port}';

  void delete() {
    _pump.cancel();
    server.shutdown();
    server.delete();
  }
}

/// Connects [client] and answers Good once the session is activated, or
/// the first bad connect status the client reports.
Future<int> connectStatus(Client client, String url) async {
  final result = Completer<int>();
  final states = client.config.stateStream.listen((state) {
    if (result.isCompleted) return;
    if (state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED) {
      result.complete(raw.UA_STATUSCODE_GOOD);
    } else if (state.recoveryStatus != raw.UA_STATUSCODE_GOOD) {
      result.complete(state.recoveryStatus);
    }
  });
  client.connect(url).ignore();
  final pump = Timer.periodic(const Duration(milliseconds: 2), (_) => client.runIterate(Duration.zero));
  try {
    return await result.future.timeout(const Duration(seconds: 15));
  } finally {
    pump.cancel();
    await states.cancel();
  }
}

Future<void> deleteClient(Client client) async {
  try {
    client.disconnect();
  } catch (_) {}
  await client.delete();
}

Client clientWith(CertificateAndKey identity, String applicationUri, {MessageSecurityMode? mode = _signAndEncrypt}) {
  final client = Client(
    certificate: identity.certificate.der,
    privateKey: identity.privateKey,
    securityMode: mode,
    logLevel: LogLevel.UA_LOGLEVEL_FATAL,
  );
  client.config.applicationUri = applicationUri;
  return client;
}

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey selfSignedClient;
  const selfSignedClientUri = 'urn:open62541.dart.test.selfsigned.client';

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(
      applicationUri: _serverUri,
      subject: ['CN=open62541-dart secured server'],
      dnsNames: ['localhost'],
      ipAddresses: ['127.0.0.1'],
    );
    selfSignedClient = createSelfSignedCertificate(
      applicationUri: selfSignedClientUri,
      subject: ['CN=open62541-dart self-signed client'],
    );
  });

  ServerSecurity security({
    TrustList applicationTrust = const TrustList(),
    TrustList? userTrust,
    bool allowNone = false,
    Set<SecurityPolicy> policies = SecurityPolicy.secure,
  }) => ServerSecurity(
    certificate: serverIdentity.certificate,
    privateKey: serverIdentity.privateKey,
    applicationTrust: applicationTrust,
    userTrust: userTrust,
    allowNone: allowNone,
    policies: policies,
  );

  Future<int> attempt(SecuredServer server, CertificateAndKey identity, String uri) async {
    final client = clientWith(identity, uri);
    try {
      return await connectStatus(client, server.url);
    } finally {
      await deleteClient(client);
    }
  }

  group('client application certificates', () {
    test('a pinned self-signed client connects with SignAndEncrypt', () async {
      final server = SecuredServer(security(applicationTrust: TrustList(trusted: [selfSignedClient.certificate])));
      addTearDown(server.delete);
      expect(await attempt(server, selfSignedClient, selfSignedClientUri), raw.UA_STATUSCODE_GOOD);
      expect(server.server.rejectedApplicationCertificates, isEmpty);
    });

    test('a CA-issued client connects through its trusted CA and CRL', () async {
      final server = SecuredServer(
        security(
          applicationTrust: TrustList(trusted: [pkiCertificate('ca')], trustedCrls: [pkiBytes('ca.crl')]),
        ),
      );
      addTearDown(server.delete);
      expect(await attempt(server, pkiCertificateAndKey('client'), fixtureClientUri), raw.UA_STATUSCODE_GOOD);
    });

    test('an untrusted client is refused and listed as rejected', () async {
      final server = SecuredServer(security());
      addTearDown(server.delete);
      final status = await attempt(server, selfSignedClient, selfSignedClientUri);
      expect(statusCodeToString(status), 'BadSecurityChecksFailed');
      expect(server.server.rejectedApplicationCertificates, contains(selfSignedClient.certificate));
    });

    test('a client announcing another ApplicationUri than its certificate is refused', () async {
      final server = SecuredServer(security(applicationTrust: TrustList(trusted: [selfSignedClient.certificate])));
      addTearDown(server.delete);
      final status = await attempt(server, selfSignedClient, 'urn:open62541.dart.test.impostor');
      expect(statusCodeToString(status), 'BadCertificateUriInvalid');
    });

    test('expired, CA-as-leaf and revoked client certificates are refused', () async {
      final server = SecuredServer(
        security(
          applicationTrust: TrustList(
            trusted: [pkiCertificate('ca'), pkiCertificate('expired'), pkiCertificate('ca_leaf')],
            trustedCrls: [pkiBytes('ca_revoked_client.crl')],
          ),
        ),
      );
      addTearDown(server.delete);
      // What the client sees: the server answers OpenSecureChannel with the
      // validation status, but hides Untrusted, Revoked, ChainIncomplete and
      // the like as BadSecurityChecksFailed (ua_securechannel.c, hideErrors).
      for (final (name, expected) in [
        ('expired', 'BadCertificateTimeInvalid'),
        ('ca_leaf', 'BadCertificateUseNotAllowed'),
        ('client', 'BadSecurityChecksFailed'),
      ]) {
        final status = await attempt(server, pkiCertificateAndKey(name), fixtureClientUri);
        expect(statusCodeToString(status), expected, reason: name);
        expect(server.server.rejectedApplicationCertificates, contains(pkiCertificate(name)), reason: name);
      }
    });

    test('TrustList.acceptAll accepts any client and says so', () async {
      final warnings = <String>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final records = Logger.root.onRecord.listen((r) {
        if (r.level >= Level.WARNING) warnings.add(r.message);
      });
      addTearDown(() {
        records.cancel();
        Logger.root.level = previousLevel;
      });
      final server = SecuredServer(security(applicationTrust: const TrustList.acceptAll()));
      addTearDown(server.delete);
      expect(warnings, contains(contains('accepts every certificate')));
      expect(await attempt(server, selfSignedClient, selfSignedClientUri), raw.UA_STATUSCODE_GOOD);
      expect(server.server.rejectedApplicationCertificates, isEmpty);
    });
  });

  group('SecurityPolicy#None', () {
    test('serves discovery only: no None endpoint, and no None session', () async {
      final server = SecuredServer(security());
      addTearDown(server.delete);
      final endpoints = await rawGetEndpoints(server.url);
      expect(endpoints, hasLength(SecurityPolicy.secure.length * 2));
      expect(endpoints.map((e) => e.policyUri).toSet(), {for (final p in SecurityPolicy.secure) p.uri});
      expect(endpoints.map((e) => e.mode).toSet(), {
        MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN.value,
        MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT.value,
      });
      for (final endpoint in endpoints) {
        expect(endpoint.serverCertificate, serverIdentity.certificate.der);
        // No user trust list: no certificate login on offer.
        expect(endpoint.tokenTypes.toSet(), {UserTokenType.anonymous.value});
      }

      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      try {
        expect(await connectStatus(client, server.url), isNot(raw.UA_STATUSCODE_GOOD));
      } finally {
        await deleteClient(client);
      }
    });

    test('allowNone opens a None endpoint for anonymous sessions', () async {
      final server = SecuredServer(security(allowNone: true));
      addTearDown(server.delete);
      final endpoints = await rawGetEndpoints(server.url);
      expect(endpoints.where((e) => e.policyUri == SecurityPolicy.none.uri).map((e) => e.mode), [
        MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE.value,
      ]);
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      try {
        expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
      } finally {
        await deleteClient(client);
      }
    });

    test('policies and modes select the endpoints', () async {
      final server = SecuredServer(
        ServerSecurity(
          certificate: serverIdentity.certificate,
          privateKey: serverIdentity.privateKey,
          policies: {SecurityPolicy.aes256Sha256RsaPss},
          modes: {MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN},
        ),
      );
      addTearDown(server.delete);
      final endpoints = await rawGetEndpoints(server.url);
      expect(endpoints.map((e) => (e.policyUri, e.mode)), [
        (SecurityPolicy.aes256Sha256RsaPss.uri, MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN.value),
      ]);
    });

    test('a user trust list puts certificate login on offer', () async {
      final server = SecuredServer(security(userTrust: TrustList(trusted: [selfSignedClient.certificate])));
      addTearDown(server.delete);
      final endpoints = await rawGetEndpoints(server.url);
      expect(endpoints.first.tokenTypes.toSet(), {UserTokenType.anonymous.value, UserTokenType.certificate.value});
      expect(server.server.rejectedUserCertificates, isEmpty);
    });
  });

  group('construction', () {
    test('an applicationUri other than the certificate URI throws, naming both', () {
      expect(
        () => Server(port: 0, applicationUri: 'urn:open62541.dart.test.wrong', security: security()),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('urn:open62541.dart.test.wrong'), contains(_serverUri)),
          ),
        ),
      );
      expect(() => Server(port: 0, security: security()), throwsArgumentError);
    });

    test('a key that is not the certificate key throws', () {
      expect(
        () => Server(
          port: 0,
          applicationUri: _serverUri,
          security: ServerSecurity(certificate: serverIdentity.certificate, privateKey: selfSignedClient.privateKey),
        ),
        throwsArgumentError,
      );
    });

    test('an unparseable key fails in Dart, without a password prompt', () {
      final garbage = Uint8List.fromList(List.generate(64, (i) => i + 1));
      expect(
        () => Server(
          port: 0,
          applicationUri: _serverUri,
          security: ServerSecurity(certificate: serverIdentity.certificate, privateKey: garbage),
        ),
        throwsA(
          isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED),
        ),
      );
    });

    test('an encrypted key is used with its password', () async {
      final client = pkiCertificateAndKey('client');
      final server = SecuredServer(
        ServerSecurity(
          certificate: client.certificate,
          privateKey: pkiBytes('client_key_encrypted.pem'),
          privateKeyPassword: fixtureKeyPassword,
          applicationTrust: TrustList(trusted: [selfSignedClient.certificate]),
        ),
        applicationUri: fixtureClientUri,
      );
      addTearDown(server.delete);
      expect(await attempt(server, selfSignedClient, selfSignedClientUri), raw.UA_STATUSCODE_GOOD);
      expect(
        () => Server(
          port: 0,
          applicationUri: fixtureClientUri,
          security: ServerSecurity(
            certificate: client.certificate,
            privateKey: pkiBytes('client_key_encrypted.pem'),
            privateKeyPassword: 'wrong',
          ),
        ),
        throwsA(isA<UaStatusException>()),
      );
    });

    test('invalid policies, modes and CRLs throw', () {
      ServerSecurity with_({
        Set<SecurityPolicy> policies = SecurityPolicy.secure,
        Set<MessageSecurityMode> modes = const {_signAndEncrypt},
        TrustList applicationTrust = const TrustList(),
      }) => ServerSecurity(
        certificate: serverIdentity.certificate,
        privateKey: serverIdentity.privateKey,
        policies: policies,
        modes: modes,
        applicationTrust: applicationTrust,
      );
      for (final bad in [
        with_(policies: {}),
        with_(policies: {SecurityPolicy.none, SecurityPolicy.basic256Sha256}),
        with_(modes: {}),
        with_(modes: {MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE}),
        with_(applicationTrust: TrustList(trustedCrls: [pkiBytes('ca.der')])),
        with_(
          applicationTrust: TrustList(
            issuerCrls: [
              Uint8List.fromList([1, 2, 3]),
            ],
          ),
        ),
      ]) {
        expect(() => Server(port: 0, applicationUri: _serverUri, security: bad), throwsArgumentError);
      }
    });
  });

  test('a server without security reports no rejected certificates', () {
    final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    addTearDown(server.delete);
    expect(server.rejectedApplicationCertificates, isEmpty);
    expect(server.rejectedUserCertificates, isEmpty);
  });
}
