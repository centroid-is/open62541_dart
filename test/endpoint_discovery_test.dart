// How a client learns a server's certificate before it has anything to
// trust: the GetEndpoints service. `Client.getEndpoints` (the same static on
// `ClientIsolate`) runs it over a SecurityPolicy#None channel without a
// session, so it needs no certificate and no trust list, and every endpoint
// it returns carries the server certificate (DER) with the policy, mode and
// identity tokens of that endpoint. The certificate goes into `trustList`
// for the next connection (trust on first use), after its thumbprint was
// checked out of band. The encrypted server is secure_fixtures.dart's.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'heap_growth.dart';
import 'secure_fixtures.dart';

const nonePolicy = 'http://opcfoundation.org/UA/SecurityPolicy#None';

typedef Discover = Future<List<EndpointDescription>> Function(String url, {Duration timeout, LogLevel logLevel});

/// `getEndpoints` of the client type: a static on both, with no client behind
/// it, so the test holds that both names do the same thing.
Discover discoverOf(String clientType) => switch (clientType) {
  'direct' => Client.getEndpoints,
  'isolate' => ClientIsolate.getEndpoints,
  _ => throw ArgumentError('Unknown client type: $clientType'),
};

/// The thumbprint OPC UA tooling shows for a certificate: SHA-1 of the DER,
/// uppercase hex.
String thumbprintOf(List<int> der) => sha1.convert(der).toString().toUpperCase();

void main() {
  late Identity serverIdentity;
  late Identity clientIdentity;

  setUpAll(() {
    serverIdentity = createIdentity('test server');
    clientIdentity = createIdentity('test client');
  });

  group('against an encrypted open62541 server:', () {
    late SecureServer server;

    setUpAll(() {
      server = SecureServer.start(serverIdentity, trustedClients: [clientIdentity.certificate]);
    });
    tearDownAll(() => server.stop());

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('discovery needs no certificate and returns every endpoint with the server certificate', () async {
          final endpoints = await discoverOf(clientType)(server.url, logLevel: LogLevel.UA_LOGLEVEL_FATAL);

          final none = endpoints.where((e) => e.securityPolicyUri == nonePolicy).toList();
          expect(none, hasLength(1), reason: 'one None endpoint: $endpoints');
          expect(none.single.securityMode, MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE);

          final signed = endpoints.where((e) => e.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN);
          final encrypted = endpoints.where(
            (e) => e.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
          );
          expect(signed, isNotEmpty, reason: 'Sign endpoints: $endpoints');
          expect(encrypted, isNotEmpty, reason: 'SignAndEncrypt endpoints: $endpoints');
          for (final endpoint in [...signed, ...encrypted]) {
            expect(endpoint.securityPolicyUri, startsWith('http://opcfoundation.org/UA/SecurityPolicy#'));
            expect(endpoint.securityPolicyUri, isNot(nonePolicy));
            // The whole point: the DER the server was created with.
            expect(endpoint.serverCertificate, serverIdentity.certificate);
            expect(endpoint.certificateThumbprint, thumbprintOf(serverIdentity.certificate));
            expect(endpoint.certificateThumbprint, hasLength(40));
            expect(endpoint.securityLevel, greaterThan(none.single.securityLevel));
          }
          // open62541 puts the certificate on the None endpoint as well: a
          // client that has nothing to trust yet can read it there.
          expect(none.single.serverCertificate, serverIdentity.certificate);

          for (final endpoint in endpoints) {
            expect(endpoint.endpointUrl, startsWith('opc.tcp://'));
            expect(endpoint.applicationUri, applicationUri);
            expect(endpoint.productUri, isNotEmpty);
            expect(endpoint.applicationName, isNotEmpty);
            expect(endpoint.transportProfileUri, contains('uatcp'));
            // open62541's default access control on a server with a
            // certificate: anonymous and certificate logins.
            final tokenTypes = endpoint.userIdentityTokens.map((t) => t.tokenType).toSet();
            expect(tokenTypes, contains(UserTokenType.UA_USERTOKENTYPE_ANONYMOUS));
            expect(tokenTypes, contains(UserTokenType.UA_USERTOKENTYPE_CERTIFICATE));
            for (final token in endpoint.userIdentityTokens) {
              expect(token.policyId, isNotEmpty);
            }
          }
          // The description reads like what it holds.
          expect(
            '${encrypted.first}',
            allOf(contains('SignAndEncrypt'), contains(encrypted.first.certificateThumbprint)),
          );
        });

        test('the discovered certificate is the trust list of the next connection: trust on first use', () async {
          final endpoints = await discoverOf(clientType)(server.url, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
          final endpoint = endpoints.firstWhere(
            (e) => e.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
          );
          // What a user does between the two steps: compare the thumbprint
          // with the one the server's operator gave them.
          expect(endpoint.certificateThumbprint, thumbprintOf(serverIdentity.certificate));

          final client = await secureClient(clientType, clientIdentity, trustList: [endpoint.serverCertificate]);
          await client.connect(server.url);
          // A read proves the session, not just the channel.
          final time = await client.read(NodeId.serverStatusCurrentTime);
          expect(time.asDateTime!.difference(DateTime.now()).abs(), lessThan(const Duration(minutes: 1)));
          if (client is Client) {
            expect(client.config.securityMode, MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT);
            expect(client.config.securityPolicyUri, isNot(nonePolicy));
          }
        });
      });
    }

    test('a discovery loop leaves nothing on the C heap', () async {
      // Three endpoints with a certificate each: a leaked endpoint array is
      // kilobytes per call, well above the limit.
      await expectNoHeapGrowth(
        () => Client.getEndpoints(server.url, logLevel: LogLevel.UA_LOGLEVEL_FATAL),
        warmUp: 20,
        iterations: 10,
        rounds: 7,
        maxGrowth: 1000,
        attempts: 3,
      );
    });
  });

  group('against the Dart Server (SecurityPolicy#None only):', () {
    late Server server;

    setUpAll(() => server = setupServer());
    tearDownAll(() => server.shutdown());

    for (final clientType in clientTypes) {
      test('$clientType client: one None endpoint without a certificate', () async {
        final endpoints = await discoverOf(clientType)(
          'opc.tcp://127.0.0.1:${server.port}',
          logLevel: LogLevel.UA_LOGLEVEL_FATAL,
        );
        expect(endpoints, hasLength(1));
        final endpoint = endpoints.single;
        expect(endpoint.securityMode, MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE);
        expect(endpoint.securityPolicyUri, nonePolicy);
        expect(endpoint.serverCertificate, isEmpty);
        expect(endpoint.certificateThumbprint, isEmpty);
        expect(endpoint.endpointUrl, contains(':${server.port}'));
      });
    }
  });

  group('errors:', () {
    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('a port nobody listens on fails with a status, well within the timeout', () async {
          // A port the OS just handed out and that was closed again: refused.
          final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          final port = socket.port;
          await socket.close();
          final watch = Stopwatch()..start();
          await expectLater(
            discoverOf(clientType)(
              'opc.tcp://127.0.0.1:$port',
              timeout: const Duration(seconds: 10),
              logLevel: LogLevel.UA_LOGLEVEL_FATAL,
            ),
            throwsA(isA<UaStatusException>()),
          );
          expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        });

        test('a host that never answers is a TimeoutException after the timeout', () async {
          final server = setupServer();
          addTearDown(server.shutdown);
          final proxy = await TcpProxy.start(server.port);
          proxy.stall();
          final watch = Stopwatch()..start();
          await expectLater(
            discoverOf(clientType)(
              'opc.tcp://127.0.0.1:${proxy.port}',
              timeout: const Duration(seconds: 1),
              logLevel: LogLevel.UA_LOGLEVEL_FATAL,
            ),
            throwsA(isA<TimeoutException>()),
          );
          expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
          expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        });

        test('a URL that is not one fails with a status', () async {
          await expectLater(
            discoverOf(clientType)('not an endpoint url', logLevel: LogLevel.UA_LOGLEVEL_FATAL),
            throwsA(isA<UaStatusException>()),
          );
        });
      });
    }
  });
}
