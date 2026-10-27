import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'pki_fixtures.dart';
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.trusting.client';

/// The SecurityPolicyUri of every activated session the server has, from
/// its NS0 SessionSecurityDiagnosticsArray (a session that is not activated
/// has none yet).
List<String> sessionPolicies(Server server) => [
  for (final session
      in server
          .read(
            NodeId.fromNumeric(
              0,
              raw.UA_NS0ID_SERVER_SERVERDIAGNOSTICS_SESSIONSDIAGNOSTICSSUMMARY_SESSIONSECURITYDIAGNOSTICSARRAY,
            ),
          )
          .asArray)
    if ((session['SecurityPolicyUri'].value as String).isNotEmpty) session['SecurityPolicyUri'].value as String,
];

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey clientIdentity;

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(applicationUri: securedServerUri, subject: ['CN=trusted server']);
    clientIdentity = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=trusting client']);
  });

  /// A server trusting [clientIdentity], with [identity] as its certificate.
  SecuredServer serverWith(CertificateAndKey identity, String applicationUri) => SecuredServer(
    ServerSecurity(
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      applicationTrust: TrustList(trusted: [clientIdentity.certificate]),
    ),
    applicationUri: applicationUri,
  );

  Client trustingClient(TrustList? serverTrust, {SecurityPolicy? securityPolicy}) => Client(
    certificate: clientIdentity.certificate.der,
    privateKey: clientIdentity.privateKey,
    applicationUri: _clientUri,
    serverTrust: serverTrust,
    securityPolicy: securityPolicy,
    securityMode: signAndEncrypt,
    logLevel: LogLevel.UA_LOGLEVEL_FATAL,
  );

  Future<int> attempt(SecuredServer server, TrustList? serverTrust) async {
    final client = trustingClient(serverTrust);
    try {
      return await connectStatus(client, server.url);
    } finally {
      await deleteClient(client);
    }
  }

  group('serverTrust', () {
    test('a pinned server certificate connects', () async {
      final server = serverWith(serverIdentity, securedServerUri);
      addTearDown(server.delete);
      final client = trustingClient(TrustList(trusted: [serverIdentity.certificate]));
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
      expect(client.rejectedServerCertificates, isEmpty);
    });

    test('an untrusted server is refused with BadCertificateUntrusted and listed', () async {
      final server = serverWith(serverIdentity, securedServerUri);
      addTearDown(server.delete);
      final client = trustingClient(const TrustList());
      addTearDown(() => deleteClient(client));
      expect(statusCodeToString(await connectStatus(client, server.url)), 'BadCertificateUntrusted');
      expect(client.rejectedServerCertificates, [serverIdentity.certificate]);
    });

    test('a CA-issued server connects through its trusted CA until the CRL revokes it', () async {
      final server = serverWith(pkiCertificateAndKey('server'), fixtureServerUri);
      addTearDown(server.delete);
      final ca = pkiCertificate('ca');
      expect(
        await attempt(server, TrustList(trusted: [ca], trustedCrls: [pkiBytes('ca.crl')])),
        raw.UA_STATUSCODE_GOOD,
      );
      expect(
        statusCodeToString(
          await attempt(server, TrustList(trusted: [ca], trustedCrls: [pkiBytes('ca_revoked_server.crl')])),
        ),
        'BadCertificateRevoked',
      );
    });

    test('a pinned CA-issued server chains through the issuer list', () async {
      final server = serverWith(pkiCertificateAndKey('server'), fixtureServerUri);
      addTearDown(server.delete);
      final leaf = pkiCertificate('server');
      final ca = pkiCertificate('ca');
      expect(
        await attempt(server, TrustList(trusted: [leaf], issuers: [ca], issuerCrls: [pkiBytes('ca.crl')])),
        raw.UA_STATUSCODE_GOOD,
      );
      expect(
        statusCodeToString(
          await attempt(
            server,
            TrustList(trusted: [leaf], issuers: [ca], issuerCrls: [pkiBytes('ca_revoked_server.crl')]),
          ),
        ),
        'BadCertificateRevoked',
      );
      // An issuer alone is no trust anchor.
      expect(statusCodeToString(await attempt(server, TrustList(issuers: [ca]))), 'BadCertificateUntrusted');
    });

    test('without serverTrust every server is accepted, with a warning', () async {
      final warnings = <String>[];
      final records = Logger.root.onRecord.listen((r) {
        if (r.level >= Level.WARNING) warnings.add(r.message);
      });
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() {
        records.cancel();
        Logger.root.level = previousLevel;
      });
      final server = serverWith(serverIdentity, securedServerUri);
      addTearDown(server.delete);
      expect(await attempt(server, null), raw.UA_STATUSCODE_GOOD);
      expect(warnings, contains(contains('accepts every server certificate')));
    });
  });

  group('selection', () {
    test('securityPolicy pins the endpoint policy', () async {
      final trust = TrustList(trusted: [serverIdentity.certificate]);
      for (final policy in [SecurityPolicy.aes128Sha256RsaOaep, SecurityPolicy.aes256Sha256RsaPss, null]) {
        final server = serverWith(serverIdentity, securedServerUri);
        final client = trustingClient(trust, securityPolicy: policy);
        try {
          expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
          // Unpinned, the client takes the highest SecurityLevel: Aes256Sha256RsaPss.
          expect(sessionPolicies(server.server), [(policy ?? SecurityPolicy.aes256Sha256RsaPss).uri]);
        } finally {
          await deleteClient(client);
          server.delete();
        }
      }
    });

    test('an encrypted client key is used with its password', () async {
      final fixture = pkiCertificateAndKey('client');
      final server = SecuredServer(
        ServerSecurity(
          certificate: serverIdentity.certificate,
          privateKey: serverIdentity.privateKey,
          // A pinned CA-issued leaf still needs its issuer to build the chain.
          applicationTrust: TrustList(trusted: [fixture.certificate], issuers: [pkiCertificate('ca')]),
        ),
      );
      addTearDown(server.delete);
      final client = Client(
        certificate: Uint8List.fromList(fixture.certificate.toPem().codeUnits),
        privateKey: pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: fixtureKeyPassword,
        applicationUri: fixtureClientUri,
        serverTrust: TrustList(trusted: [serverIdentity.certificate]),
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    });

    test('misconfigurations throw', () {
      expect(
        () => Client(
          certificate: clientIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          applicationUri: 'urn:open62541.dart.test.other',
        ),
        throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains(_clientUri))),
      );
      expect(() => Client(serverTrust: const TrustList()), throwsArgumentError);
      expect(
        () => Client(
          certificate: clientIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          serverTrust: TrustList(
            trustedCrls: [
              Uint8List.fromList([1, 2, 3]),
            ],
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => Client(
          certificate: pkiBytes('client.der'),
          privateKey: pkiBytes('client_key_encrypted.pem'),
          privateKeyPassword: 'wrong',
        ),
        throwsA(isA<UaStatusException>()),
      );
    });

    test('applicationUri without a certificate is announced', () {
      final client = Client(applicationUri: 'urn:open62541.dart.test.plain');
      addTearDown(() => client.delete());
      expect(client.config.applicationUri, 'urn:open62541.dart.test.plain');
    });
  });

  group('Client.getEndpoints', () {
    test('describes every endpoint of a discovery-only server', () async {
      final server = serverWith(serverIdentity, securedServerUri);
      addTearDown(server.delete);
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints, hasLength(SecurityPolicy.secure.length * 2));
      for (final endpoint in endpoints) {
        expect(endpoint.endpointUrl, startsWith('opc.tcp://'));
        expect(endpoint.securityPolicy, isIn(SecurityPolicy.secure));
        expect(endpoint.securityMode, isNot(MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE));
        expect(endpoint.securityLevel, greaterThan(0));
        expect(endpoint.serverCertificate, serverIdentity.certificate);
        expect(endpoint.applicationUri, securedServerUri);
        expect(endpoint.userTokenPolicies.map((p) => p.tokenType).toSet(), {UserTokenType.anonymous});
      }
      final best = endpoints.reduce((a, b) => a.securityLevel >= b.securityLevel ? a : b);
      expect(best.securityPolicy, SecurityPolicy.aes256Sha256RsaPss);
    });

    test('a plain server lists its None endpoint', () async {
      final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      server.start();
      final pump = Timer.periodic(const Duration(milliseconds: 2), (_) => server.runIterate());
      addTearDown(() {
        pump.cancel();
        server.shutdown();
        server.delete();
      });
      final endpoints = await Client.getEndpoints('opc.tcp://127.0.0.1:${server.port}');
      expect(endpoints.single.securityPolicy, SecurityPolicy.none);
      expect(endpoints.single.serverCertificate, isNull);
      expect(endpoints.single.applicationUri, server.applicationUri);
    });

    test('an unreachable server throws', () async {
      final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL)..start();
      final port = server.port;
      server.shutdown();
      server.delete();
      await expectLater(
        Client.getEndpoints('opc.tcp://127.0.0.1:$port', timeout: const Duration(seconds: 2)),
        throwsA(isA<UaStatusException>()),
      );
    });
  });

  group('ClientIsolate', () {
    late SecuredServer server;
    setUp(() => server = serverWith(serverIdentity, securedServerUri));
    tearDown(() => server.delete());

    Future<ClientIsolate> isolate(TrustList serverTrust, {SecurityPolicy? securityPolicy}) => ClientIsolate.create(
      certificate: clientIdentity.certificate.der,
      privateKey: clientIdentity.privateKey,
      applicationUri: _clientUri,
      serverTrust: serverTrust,
      securityPolicy: securityPolicy,
      securityMode: signAndEncrypt,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
    );

    test('carries serverTrust, applicationUri and securityPolicy', () async {
      final client = await isolate(
        TrustList(trusted: [serverIdentity.certificate]),
        securityPolicy: SecurityPolicy.basic256Sha256,
      );
      addTearDown(client.delete);
      await client.connect(server.url, timeout: const Duration(seconds: 10));
      expect(sessionPolicies(server.server), [SecurityPolicy.basic256Sha256.uri]);
      expect(await client.rejectedServerCertificates, isEmpty);
    });

    test('refuses an untrusted server and reports it', () async {
      final client = await isolate(const TrustList());
      addTearDown(client.delete);
      await expectLater(
        client.connect(server.url, timeout: const Duration(seconds: 3)),
        throwsA(isA<UaStatusException>()),
      );
      expect(await client.rejectedServerCertificates, contains(serverIdentity.certificate));
    });

    test('carries privateKeyPassword', () async {
      await expectLater(
        ClientIsolate.create(
          certificate: pkiBytes('client.der'),
          privateKey: pkiBytes('client_key_encrypted.pem'),
          privateKeyPassword: 'wrong',
        ),
        throwsA(isA<UaStatusException>()),
      );
      final client = await ClientIsolate.create(
        certificate: pkiBytes('client.der'),
        privateKey: pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: fixtureKeyPassword,
        applicationUri: fixtureClientUri,
        serverTrust: TrustList(trusted: [serverIdentity.certificate]),
      );
      await client.delete();
    });
  });
}
