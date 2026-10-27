import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.x509.client';
final _method = NodeId.fromString(1, 'x509.whoami');

class CertificateLogins extends AccessControl {
  final activations = <SessionActivation>[];
  var refuseUnsecured = false;

  @override
  Set<UserTokenType> get userTokenTypes => {UserTokenType.certificate};

  @override
  Object? activateSession(SessionActivation activation) {
    activations.add(activation);
    if (refuseUnsecured && activation.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE) {
      throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
    }
    return activation.userCertificate?.sha1Thumbprint;
  }
}

/// Runs [future] while pumping [client].
Future<T> pumped<T>(Client client, Future<T> future) async {
  var done = false;
  future.whenComplete(() => done = true).ignore();
  while (!done) {
    client.runIterate(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return future;
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
  late SecuredServer server;
  late List<MethodSessionInfo> calls;

  setUp(() {
    ac = CertificateLogins();
    calls = [];
    server = SecuredServer(
      ServerSecurity(
        certificate: serverIdentity.certificate,
        privateKey: serverIdentity.privateKey,
        applicationTrust: TrustList(trusted: [clientIdentity.certificate]),
        userTrust: TrustList(trusted: [trustedUser.certificate]),
        allowNone: true,
      ),
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
    serverTrust: secured ? TrustList(trusted: [serverIdentity.certificate]) : null,
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
    expect(activation.tokenType, UserTokenType.certificate);
    expect(activation.userCertificate!.sha1Thumbprint, trustedUser.certificate.sha1Thumbprint);
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
    // open62541 hides why an X.509 token failed validation.
    expect(statusCodeToString(await connectStatus(client, server.url)), 'BadIdentityTokenRejected');
    expect(ac.activations, isEmpty);
    expect(server.server.rejectedUserCertificates, [untrustedUser.certificate]);
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
      serverTrust: TrustList(trusted: [serverIdentity.certificate]),
      securityMode: signAndEncrypt,
      userCertificate: trustedUser.certificate.der,
      userPrivateKey: trustedUser.privateKey,
    );
    addTearDown(client.delete);
    await client.connect(server.url, timeout: const Duration(seconds: 10));
    expect(ac.activations.single.userCertificate, trustedUser.certificate);
  });

  test('user certificate misconfigurations throw', () {
    expect(() => Client(userCertificate: trustedUser.certificate.der), throwsArgumentError);
    expect(
      () => Client(userCertificate: trustedUser.certificate.der, userPrivateKey: untrustedUser.privateKey),
      throwsArgumentError,
    );
    expect(
      () => Client(username: 'u', userCertificate: trustedUser.certificate.der, userPrivateKey: trustedUser.privateKey),
      throwsArgumentError,
    );
  });
}
