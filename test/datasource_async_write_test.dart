import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

import 'common.dart';

/// Async data-source writes (backlog item 13): `onWrite` is
/// `Future`-returning — the client's write parks as an open62541 async
/// operation and is answered with the handler's awaited outcome, so a proxy
/// can report the REAL downstream (device) result instead of an optimistic
/// Good.
void main() {
  group('Async data-source writes', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('the client write completes only after the handler future does', () async {
      final nodeId = NodeId.fromString(1, 'async.write.ok');
      var stored = 0;
      final gate = Completer<void>();
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'async.write.ok',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(value: stored, typeId: NodeId.int32),
        onWrite: (value) async {
          // Simulates the downstream (device) write finishing later.
          await gate.future;
          stored = value.asInt;
        },
      );

      var writeDone = false;
      final write = client
          .write(nodeId, DynamicValue(value: 42, typeId: NodeId.int32))
          .whenComplete(() => writeDone = true);
      // The write must stay in flight while the handler is parked.
      await Future.delayed(const Duration(milliseconds: 300));
      expect(writeDone, isFalse, reason: 'write answered before the handler completed');
      expect(stored, 0);

      gate.complete();
      await write;
      expect(stored, 42);
      expect((await client.read(nodeId)).asInt, 42);
    });

    test('a UaStatusException after a real await reaches the client typed', () async {
      final nodeId = NodeId.fromString(1, 'async.write.denied');
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'async.write.denied',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
        onWrite: (value) async {
          await Future.delayed(const Duration(milliseconds: 100));
          // The downstream refused — the in-flight client write gets the code.
          throw const UaStatusException(raw.UA_STATUSCODE_BADNOTWRITABLE);
        },
      );

      await expectLater(
        client.write(nodeId, DynamicValue(value: 2, typeId: NodeId.int32)),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADNOTWRITABLE)),
      );
    });

    test('setVariableValueSource writes take the same async path', () async {
      final nodeId = NodeId.fromString(1, 'async.write.replaced');
      // Plain variable first; then take over its value source with handlers.
      server.addVariableNode(nodeId, DynamicValue(value: 0, typeId: NodeId.int32, name: 'async.write.replaced'));
      var seen = -1;
      server.setVariableValueSource(
        nodeId,
        onRead: () => DynamicValue(value: seen, typeId: NodeId.int32),
        onWrite: (value) async {
          await Future.delayed(const Duration(milliseconds: 50));
          seen = value.asInt;
        },
      );

      await client.write(nodeId, DynamicValue(value: 7, typeId: NodeId.int32));
      expect(seen, 7);
    });
  });
}
