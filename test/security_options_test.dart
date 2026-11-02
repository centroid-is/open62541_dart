// What the security branches add next to the trust lists: an encrypted
// private key with its password on both sides, the client's
// SecurityPolicy pin and ApplicationUri, and the certificates either side
// refused.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'pki_fixtures.dart';
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.options.client';

/// Anonymous sessions, each activation kept.
class _Recording extends DefaultAccessControl {
  final activations = <SessionActivation>[];

  @override
  Object? activateSession(SessionActivation activation) {
    activations.add(activation);
    return super.activateSession(activation);
  }
}

Matcher _status(int code) => throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', code));

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey clientIdentity;
  late CertificateAndKey stranger;

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(applicationUri: securedServerUri, subject: ['CN=options server']);
    clientIdentity = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=options client']);
    stranger = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=options stranger']);
  });

  group('Server', () {
    test('an encrypted PEM key is used with its privateKeyPassword', () async {
      final ac = _Recording();
      final server = PumpedServer(
        Server(
          port: 0,
          logLevel: LogLevel.UA_LOGLEVEL_FATAL,
          applicationUri: fixtureClientUri,
          certificate: pkiBytes('client.der'),
          privateKey: pkiBytes('client_key_encrypted.pem'),
          privateKeyPassword: fixtureKeyPassword,
          trustList: [clientIdentity.certificate.der],
          accessControl: ac,
        ),
      );
      addTearDown(server.delete);
      final client = Client(
        certificate: clientIdentity.certificate.der,
        privateKey: clientIdentity.privateKey,
        applicationUri: _clientUri,
        trustList: [pkiBytes('ca.der')],
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
      expect(ac.activations.single.securityMode, signAndEncrypt);
    });

    test('a wrong or missing password is refused before open62541 sees the key', () {
      Server server({String? password, Uint8List? key}) => Server(
        port: 0,
        applicationUri: fixtureClientUri,
        certificate: pkiBytes('client.der'),
        privateKey: key ?? pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: password,
        trustList: [clientIdentity.certificate.der],
      );
      expect(() => server(password: 'wrong'), _status(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED));
      expect(() => server(), throwsArgumentError);
      expect(() => Server(port: 0, privateKeyPassword: fixtureKeyPassword), throwsArgumentError);
      // A password for a plain DER key changes nothing.
      server(password: 'unused', key: pkiBytes('client_key.der')).delete();
    });

    test('a key of another certificate is an ArgumentError, not a server no client can use', () {
      expect(
        () => Server(
          port: 0,
          applicationUri: securedServerUri,
          certificate: serverIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          trustList: [clientIdentity.certificate.der],
        ),
        throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains('not the key'))),
      );
    });

    test('rejectedClientCertificates lists an untrusted client', () async {
      final server = PumpedServer.secured(serverIdentity, trustList: [clientIdentity.certificate.der]);
      addTearDown(server.delete);
      expect(server.server.rejectedClientCertificates, isEmpty);
      final client = Client(
        certificate: stranger.certificate.der,
        privateKey: stranger.privateKey,
        applicationUri: _clientUri,
        trustList: [serverIdentity.certificate.der],
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(statusCodeToString(await connectStatus(client, server.url)), 'BadSecurityChecksFailed');
      expect(server.server.rejectedClientCertificates, contains(stranger.certificate));
    });

    test('a plain server has no rejected list', () {
      final server = Server(port: 0);
      addTearDown(server.delete);
      expect(server.rejectedClientCertificates, isEmpty);
      expect(server.rejectedUserCertificates, isEmpty);
    });
  });

  group('Client', () {
    late _Recording ac;
    late PumpedServer server;

    setUp(() {
      ac = _Recording();
      server = PumpedServer.secured(
        serverIdentity,
        trustList: [clientIdentity.certificate.der, pkiBytes('ca.der')],
        allowNone: true,
        accessControl: ac,
      );
    });
    tearDown(() => server.delete());

    test('securityPolicy pins the endpoint policy', () async {
      for (final policy in SecurityPolicy.secure) {
        final client = Client(
          certificate: clientIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          applicationUri: _clientUri,
          trustList: [serverIdentity.certificate.der],
          securityMode: signAndEncrypt,
          securityPolicy: policy,
          logLevel: LogLevel.UA_LOGLEVEL_FATAL,
        );
        expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
        await deleteClient(client);
        expect(ac.activations.last.securityPolicyUri, policy.uri);
      }
    });

    test('applicationUri is announced, and must be the certificate\'s', () async {
      final plain = Client(applicationUri: 'urn:open62541.dart.test.plain', logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      addTearDown(() => deleteClient(plain));
      expect(plain.config.applicationUri, 'urn:open62541.dart.test.plain');
      expect(await connectStatus(plain, server.url), raw.UA_STATUSCODE_GOOD);
      expect(ac.activations.single.clientApplicationUri, 'urn:open62541.dart.test.plain');

      final mismatch = throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains(_clientUri)));
      expect(
        () => Client(
          certificate: clientIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          applicationUri: 'urn:open62541.dart.test.other',
          acceptAllCertificates: true,
        ),
        mismatch,
      );
      await expectLater(
        ClientIsolate.create(
          certificate: clientIdentity.certificate.der,
          privateKey: clientIdentity.privateKey,
          applicationUri: 'urn:open62541.dart.test.other',
          acceptAllCertificates: true,
        ),
        mismatch,
      );
    });

    test('an encrypted PEM key is used with its privateKeyPassword', () async {
      final client = Client(
        certificate: pkiBytes('client.der'),
        privateKey: pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: fixtureKeyPassword,
        applicationUri: fixtureClientUri,
        trustList: [serverIdentity.certificate.der],
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
      expect(ac.activations.single.clientCertificate, pkiCertificate('client'));

      Client withPassword(String? password) => Client(
        certificate: pkiBytes('client.der'),
        privateKey: pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: password,
        acceptAllCertificates: true,
      );
      expect(() => withPassword('wrong'), _status(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED));
      expect(() => withPassword(null), throwsArgumentError);
      expect(() => Client(privateKeyPassword: fixtureKeyPassword), throwsArgumentError);
    });

    test('rejectedServerCertificates lists a server the trust list refused', () async {
      final client = Client(
        certificate: clientIdentity.certificate.der,
        privateKey: clientIdentity.privateKey,
        applicationUri: _clientUri,
        trustList: [stranger.certificate.der],
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(client.rejectedServerCertificates, isEmpty);
      expect(statusCodeToString(await connectStatus(client, server.url)), 'BadCertificateUntrusted');
      expect(client.rejectedServerCertificates, contains(serverIdentity.certificate));
    });
  });

  group('ClientIsolate', () {
    late _Recording ac;
    late PumpedServer server;

    setUp(() {
      ac = _Recording();
      server = PumpedServer.secured(
        serverIdentity,
        trustList: [clientIdentity.certificate.der, pkiBytes('ca.der')],
        accessControl: ac,
      );
    });
    tearDown(() => server.delete());

    test('carries securityPolicy, applicationUri and privateKeyPassword', () async {
      final client = await ClientIsolate.create(
        certificate: pkiBytes('client.der'),
        privateKey: pkiBytes('client_key_encrypted.pem'),
        privateKeyPassword: fixtureKeyPassword,
        applicationUri: fixtureClientUri,
        trustList: [serverIdentity.certificate.der],
        securityMode: signAndEncrypt,
        securityPolicy: SecurityPolicy.basic256Sha256,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(client.delete);
      await client.connect(server.url, timeout: const Duration(seconds: 10));
      expect(ac.activations.single.securityPolicyUri, SecurityPolicy.basic256Sha256.uri);
      expect(ac.activations.single.clientApplicationUri, fixtureClientUri);
      expect(await client.rejectedServerCertificates, isEmpty);
      await expectLater(
        ClientIsolate.create(
          certificate: pkiBytes('client.der'),
          privateKey: pkiBytes('client_key_encrypted.pem'),
          privateKeyPassword: 'wrong',
          acceptAllCertificates: true,
        ),
        _status(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED),
      );
    });

    test('rejectedServerCertificates lists a server the trust list refused', () async {
      final client = await ClientIsolate.create(
        certificate: clientIdentity.certificate.der,
        privateKey: clientIdentity.privateKey,
        applicationUri: _clientUri,
        trustList: [stranger.certificate.der],
        securityMode: signAndEncrypt,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(client.delete);
      await expectLater(
        client.connect(server.url, timeout: const Duration(seconds: 10)),
        _status(raw.UA_STATUSCODE_BADCERTIFICATEUNTRUSTED),
      );
      expect(await client.rejectedServerCertificates, contains(serverIdentity.certificate));
    });
  });
}
