// X.509 user identity tokens: Client(userCertificate:, userPrivateKey:)
// activates the session with a certificate the server verifies against its
// trust list, and the server's AccessControl sees it.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'pki_fixtures.dart';
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.x509.client';
const _certificate = UserTokenType.UA_USERTOKENTYPE_CERTIFICATE;
final _method = NodeId.fromString(1, 'x509.whoami');

class CertificateLogins extends AccessControl {
  final activations = <SessionActivation>[];
  var refuseUnsecured = false;

  @override
  Set<UserTokenType> get userTokenTypes => {_certificate};

  @override
  Object? activateSession(SessionActivation activation) {
    activations.add(activation);
    if (refuseUnsecured && activation.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE) {
      throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
    }
    return activation.userCertificate?.sha1Thumbprint;
  }
}

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey clientIdentity;
  late CertificateAndKey trustedUser;
  late CertificateAndKey untrustedUser;

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(applicationUri: securedServerUri, subject: ['CN=x509 server']);
    clientIdentity = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=x509 client']);
    trustedUser = createSelfSignedCertificate(applicationUri: 'urn:user:alice', subject: ['CN=alice']);
    untrustedUser = createSelfSignedCertificate(applicationUri: 'urn:user:mallory', subject: ['CN=mallory']);
  });

  late CertificateLogins ac;
  late PumpedServer server;
  late List<MethodSessionInfo> calls;

  setUp(() {
    ac = CertificateLogins();
    calls = [];
    // One trust list verifies both the client applications and the users.
    server = PumpedServer.secured(
      serverIdentity,
      trustList: [clientIdentity.certificate.der, trustedUser.certificate.der, pkiBytes('ca.der')],
      allowNone: true,
      accessControl: ac,
    );
    server.server.addMethodNode(
      _method,
      callback: (inputs, session) async {
        calls.add(session);
        return [];
      },
    );
  });
  tearDown(() => server.delete());

  Client userClient(CertificateAndKey user, {bool secured = true}) => Client(
    certificate: secured ? clientIdentity.certificate.der : null,
    privateKey: secured ? clientIdentity.privateKey : null,
    applicationUri: _clientUri,
    trustList: secured ? [serverIdentity.certificate.der] : null,
    securityMode: secured ? signAndEncrypt : MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE,
    userCertificate: user.certificate.der,
    userPrivateKey: user.privateKey,
    logLevel: LogLevel.UA_LOGLEVEL_FATAL,
  );

  test('a trusted user certificate logs in', () async {
    final client = userClient(trustedUser);
    addTearDown(() => deleteClient(client));
    expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    final activation = ac.activations.single;
    expect(activation.tokenType, _certificate);
    expect(activation.userCertificate, trustedUser.certificate);
    expect(activation.username, isNull);

    await pumped(client, client.call(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER), _method, []));
    expect(
      calls.single.identity,
      isA<CertificateSessionIdentity>().having((i) => i.subjectName, 'subjectName', trustedUser.certificate.subject),
    );
    expect(calls.single.context, trustedUser.certificate.sha1Thumbprint);
    expect(server.server.rejectedUserCertificates, isEmpty);
  });

  test('an untrusted user certificate is refused and listed', () async {
    final client = userClient(untrustedUser);
    addTearDown(() => deleteClient(client));
    // open62541 hides why an X.509 token failed verification.
    expect(statusCodeToString(await connectStatus(client, server.url)), 'BadIdentityTokenRejected');
    expect(ac.activations, isEmpty);
    expect(server.server.rejectedUserCertificates, [untrustedUser.certificate]);
  });

  test('connect fails at once with the refusal, on both clients', () async {
    final client = userClient(untrustedUser);
    addTearDown(() => deleteClient(client));
    final pump = Timer.periodic(const Duration(milliseconds: 2), (_) => client.runIterate(Duration.zero));
    addTearDown(pump.cancel);
    final watch = Stopwatch()..start();
    await expectLater(
      client.connect(server.url),
      throwsA(
        isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)), reason: 'well within the 30 s connect timeout');

    final isolate = await ClientIsolate.create(
      certificate: clientIdentity.certificate.der,
      privateKey: clientIdentity.privateKey,
      applicationUri: _clientUri,
      trustList: [serverIdentity.certificate.der],
      securityMode: signAndEncrypt,
      userCertificate: untrustedUser.certificate.der,
      userPrivateKey: untrustedUser.privateKey,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
    );
    addTearDown(isolate.delete);
    watch.reset();
    await expectLater(
      isolate.connect(server.url),
      throwsA(
        isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('an X.509 token on a None endpoint is signed under a secure policy; the access control decides', () async {
    // open62541 refuses an X.509 token only when its token policy is None.
    // A secured server gives the certificate token of its None endpoint its
    // best encrypting policy, so the client signs the token with that and
    // the user's key, and the activation reaches the access control with the
    // channel's mode and policy.
    final accepted = userClient(trustedUser, secured: false);
    expect(await connectStatus(accepted, server.url), raw.UA_STATUSCODE_GOOD);
    await deleteClient(accepted);
    final activation = ac.activations.single;
    expect(activation.securityMode, MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE);
    expect(activation.securityPolicyUri, SecurityPolicy.none.uri);
    expect(activation.userCertificate, trustedUser.certificate);
    expect(activation.clientCertificate, isNull);

    ac.refuseUnsecured = true;
    final refused = userClient(trustedUser, secured: false);
    addTearDown(() => deleteClient(refused));
    expect(statusCodeToString(await connectStatus(refused, server.url)), 'BadUserAccessDenied');
  });

  test('ClientIsolate carries the user certificate', () async {
    final client = await ClientIsolate.create(
      certificate: clientIdentity.certificate.der,
      privateKey: clientIdentity.privateKey,
      applicationUri: _clientUri,
      trustList: [serverIdentity.certificate.der],
      securityMode: signAndEncrypt,
      userCertificate: trustedUser.certificate.der,
      userPrivateKey: trustedUser.privateKey,
    );
    addTearDown(client.delete);
    await client.connect(server.url, timeout: const Duration(seconds: 10));
    expect(ac.activations.single.userCertificate, trustedUser.certificate);
  });

  test('an encrypted user key is used with its userPrivateKeyPassword', () async {
    final client = Client(
      certificate: clientIdentity.certificate.der,
      privateKey: clientIdentity.privateKey,
      applicationUri: _clientUri,
      trustList: [serverIdentity.certificate.der],
      securityMode: signAndEncrypt,
      userCertificate: pkiBytes('client.der'),
      userPrivateKey: pkiBytes('client_key_encrypted.pem'),
      userPrivateKeyPassword: fixtureKeyPassword,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
    );
    addTearDown(() => deleteClient(client));
    expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    expect(ac.activations.single.userCertificate, pkiCertificate('client'));
  });

  test('user certificate misconfigurations throw, on both clients', () async {
    final cases = <String, ({Uint8List? certificate, Uint8List? key, String? password, String? username})>{
      'a certificate without its key': (
        certificate: trustedUser.certificate.der,
        key: null,
        password: null,
        username: null,
      ),
      'a key without its certificate': (certificate: null, key: trustedUser.privateKey, password: null, username: null),
      'the key of another certificate': (
        certificate: trustedUser.certificate.der,
        key: untrustedUser.privateKey,
        password: null,
        username: null,
      ),
      'a user name as well': (
        certificate: trustedUser.certificate.der,
        key: trustedUser.privateKey,
        password: null,
        username: 'u',
      ),
      'an encrypted key without its password': (
        certificate: pkiBytes('client.der'),
        key: pkiBytes('client_key_encrypted.pem'),
        password: null,
        username: null,
      ),
      'a password without a key': (certificate: null, key: null, password: fixtureKeyPassword, username: null),
    };
    for (final MapEntry(key: reason, value: c) in cases.entries) {
      expect(
        () => Client(
          userCertificate: c.certificate,
          userPrivateKey: c.key,
          userPrivateKeyPassword: c.password,
          username: c.username,
        ),
        throwsArgumentError,
        reason: reason,
      );
      await expectLater(
        ClientIsolate.create(
          userCertificate: c.certificate,
          userPrivateKey: c.key,
          userPrivateKeyPassword: c.password,
          username: c.username,
        ),
        throwsArgumentError,
        reason: reason,
      );
    }
  });
}
