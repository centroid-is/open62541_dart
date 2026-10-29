import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'pki_fixtures.dart';
import 'security_harness.dart';

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey selfSignedClient;
  const selfSignedClientUri = 'urn:open62541.dart.test.selfsigned.client';

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(
      applicationUri: securedServerUri,
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
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints, hasLength(SecurityPolicy.secure.length * 2));
      expect(endpoints.map((e) => e.securityPolicyUri).toSet(), {for (final p in SecurityPolicy.secure) p.uri});
      expect(endpoints.map((e) => e.securityMode).toSet(), {
        MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN,
        MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
      });
      for (final endpoint in endpoints) {
        expect(endpoint.serverCertificate, serverIdentity.certificate);
        // No user trust list: no certificate login on offer.
        expect(endpoint.userTokenPolicies.map((p) => p.tokenType).toSet(), {UserTokenType.anonymous});
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
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints.where((e) => e.securityPolicyUri == SecurityPolicy.none.uri).map((e) => e.securityMode), [
        MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE,
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
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints.map((e) => (e.securityPolicyUri, e.securityMode)), [
        (SecurityPolicy.aes256Sha256RsaPss.uri, MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN),
      ]);
    });

    test('a user trust list puts certificate login on offer', () async {
      final server = SecuredServer(security(userTrust: TrustList(trusted: [selfSignedClient.certificate])));
      addTearDown(server.delete);
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints.first.userTokenPolicies.map((p) => p.tokenType).toSet(), {
        UserTokenType.anonymous,
        UserTokenType.certificate,
      });
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
            allOf(contains('urn:open62541.dart.test.wrong'), contains(securedServerUri)),
          ),
        ),
      );
      expect(() => Server(port: 0, security: security()), throwsArgumentError);
    });

    test('a key that is not the certificate key throws', () {
      expect(
        () => Server(
          port: 0,
          applicationUri: securedServerUri,
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
          applicationUri: securedServerUri,
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
        Set<MessageSecurityMode> modes = const {signAndEncrypt},
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
        expect(() => Server(port: 0, applicationUri: securedServerUri, security: bad), throwsArgumentError);
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
