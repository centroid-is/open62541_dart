import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// Client/server hygiene (backlog items 10-12): `Server.write` surfaces the
/// native status code, a bare `ClientIsolate.connect()` completes on its own
/// (self-pumped handshake + timeout), and `UaStatusException` survives the
/// isolate boundary with its status code intact.
void main() {
  group('Server.write status (item 10)', () {
    late int port;
    late Server server;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
    });

    tearDown(() {
      server.shutdown();
      server.delete();
    });

    test('a good write returns; a write to a missing node throws typed', () {
      addBasicVariables(server);
      // Good path: no throw.
      server.write(intNodeId, DynamicValue(value: 7, typeId: NodeId.int32));
      expect(server.read(intNodeId).asInt, 7);

      // Bad path: the native BadNodeIdUnknown surfaces as UaStatusException.
      expect(
        () => server.write(NodeId.fromString(1, 'no.such.node'), DynamicValue(value: 1, typeId: NodeId.int32)),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADNODEIDUNKNOWN)),
      );
    });

    test('a type-mismatched write throws typed', () {
      addBasicVariables(server);
      expect(
        () => server.write(intNodeId, DynamicValue(value: 'not an int', typeId: NodeId.uastring)),
        throwsA(isA<UaStatusException>()),
      );
    });
  });

  group('Bare ClientIsolate.connect (item 11)', () {
    test('completes without any external pump (deadlock regression)', () async {
      final port = await freeTcpPort();
      final server = setupServer(port);
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      try {
        // Historically this awaited forever: nothing pumped the worker's
        // iterate loop unless keepConnected ran. The worker now pumps the
        // handshake itself. Test-level timeout guards the regression.
        await client.connect('opc.tcp://localhost:$port').timeout(const Duration(seconds: 15));
        final state = await client.state;
        expect(state.sessionState, raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
      } finally {
        await client.delete();
        server.shutdown();
        server.delete();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('an unreachable endpoint fails with Bad_Timeout within the timeout', () async {
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      try {
        final sw = Stopwatch()..start();
        await expectLater(
          client.connect('opc.tcp://192.0.2.1:4840', timeout: const Duration(seconds: 2)),
          throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADTIMEOUT)),
        );
        sw.stop();
        // Bounded: it must not hang anywhere near the old forever-wait.
        expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      } finally {
        await client.delete();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('Typed errors across the isolate boundary (item 12)', () {
    test('a UaStatusException from a server callback keeps its code', () async {
      final port = await freeTcpPort();
      final server = setupServer(port);
      // A read-write node whose write handler refuses with a specific code.
      server.addDataSourceVariableNode(
        NodeId.fromString(1, 'gate.value'),
        browseName: 'gate.value',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
        onWrite: (_) => throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED),
      );

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      try {
        await client.keepConnected('opc.tcp://localhost:$port').timeout(const Duration(seconds: 15));
        await expectLater(
          client.write(NodeId.fromString(1, 'gate.value'), DynamicValue(value: 2, typeId: NodeId.int32)),
          throwsA(
            isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADUSERACCESSDENIED),
          ),
        );
      } finally {
        await client.delete();
        server.shutdown();
        server.delete();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
