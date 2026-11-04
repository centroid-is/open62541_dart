// `requestTimeout`: open62541's per-request response timeout
// (`UA_ClientConfig.timeout`, 5 s by default). It bounds every service call
// the client sends, so a method call that legitimately runs longer than 5 s
// fails with Bad_Timeout however long the caller is willing to wait. A Dart
// `.timeout()` around the call cannot lengthen it; the option can.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

void main() {
  group('Client requestTimeout config', () {
    test('defaults to open62541\'s 5 s', () async {
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      addTearDown(client.delete);

      expect(Client.defaultRequestTimeout, const Duration(seconds: 5));
      expect(client.requestTimeout, const Duration(seconds: 5));
      expect(client.config.requestTimeout, const Duration(seconds: 5));
    });

    test('the constructor option lands in the client\'s live UA_ClientConfig.timeout', () async {
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL, requestTimeout: const Duration(seconds: 42));
      addTearDown(client.delete);

      expect(client.config.requestTimeout, const Duration(seconds: 42));
      expect(client.requestTimeout, const Duration(seconds: 42));
    });

    test('the setter writes the live config', () async {
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      addTearDown(client.delete);

      client.requestTimeout = const Duration(milliseconds: 1234);
      expect(client.config.requestTimeout, const Duration(milliseconds: 1234));
      client.config.requestTimeout = const Duration(seconds: 7);
      expect(client.requestTimeout, const Duration(seconds: 7));
    });

    test('Duration.zero (no timeout) is accepted; negative or > UInt32 ms is an ArgumentError', () async {
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL, requestTimeout: Duration.zero);
      addTearDown(client.delete);
      expect(client.requestTimeout, Duration.zero);

      expect(() => client.requestTimeout = const Duration(milliseconds: -1), throwsArgumentError);
      expect(() => client.requestTimeout = const Duration(milliseconds: 0x100000000), throwsArgumentError);
      expect(() => Client(requestTimeout: const Duration(seconds: -1)), throwsArgumentError);
      expect(client.requestTimeout, Duration.zero);
    });

    test('ClientIsolate passes the option to its worker and reads it back', () async {
      final client = await ClientIsolate.create(
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
        requestTimeout: const Duration(seconds: 11),
      );
      addTearDown(client.delete);

      expect(await client.getRequestTimeout(), const Duration(seconds: 11));
      await client.setRequestTimeout(const Duration(seconds: 3));
      expect(await client.getRequestTimeout(), const Duration(seconds: 3));
    });

    test('ClientIsolate default is 5 s; invalid values are refused on the caller\'s isolate', () async {
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      addTearDown(client.delete);

      expect(await client.getRequestTimeout(), const Duration(seconds: 5));
      await expectLater(client.setRequestTimeout(const Duration(seconds: -1)), throwsArgumentError);
      await expectLater(ClientIsolate.create(requestTimeout: const Duration(seconds: -1)), throwsArgumentError);
    });
  });

  for (final clientType in clientTypes) {
    group('[$clientType] a method call longer than the request timeout', () {
      late Server server;
      final slowId = NodeId.fromString(1, 'method.sleep6s');

      setUp(() async {
        server = setupServer();
        server.addMethodNode(
          slowId,
          browseName: 'sleep6s',
          outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
          callback: (inputs, session) async {
            await Future<void>.delayed(const Duration(seconds: 6));
            return [DynamicValue(value: 7, typeId: NodeId.int32)];
          },
        );
      });

      tearDown(() {
        server.shutdown();
        server.delete();
      });

      String url() => 'opc.tcp://127.0.0.1:${server.port}';

      test('default client: Bad_Timeout after about 5 s', () async {
        final client = await setupClientOfType(clientType, url());
        addTearDown(client.delete);
        final started = DateTime.now();

        await expectLater(
          client.call(NodeId.objectsFolder, slowId, []),
          throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADTIMEOUT)),
        );
        expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 6)));
      });

      test('requestTimeout: 10 s: Good', () async {
        final client = await setupClientOfType(clientType, url(), requestTimeout: const Duration(seconds: 10));
        addTearDown(client.delete);

        final result = await client.call(NodeId.objectsFolder, slowId, []);
        expect(result.single.asInt, 7);
      });

      test('raised after connect: the next call uses it', () async {
        final client = await setupClientOfType(clientType, url());
        addTearDown(client.delete);
        switch (client) {
          case Client c:
            c.requestTimeout = const Duration(seconds: 10);
          case ClientIsolate c:
            await c.setRequestTimeout(const Duration(seconds: 10));
        }

        final result = await client.call(NodeId.objectsFolder, slowId, []);
        expect(result.single.asInt, 7);
      });
    });
  }
}
