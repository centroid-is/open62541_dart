import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show freeTcpPort;
import 'heap_growth.dart';

/// Regression tests for native memory a [Client] allocated and never freed.
/// Each repeats one operation that must leave the C heap as it found it, see
/// heap_growth.dart.
void main() {
  test('a client with a username and password leaves nothing on the C heap once deleted', () async {
    // Long credentials, so that the two strings stand out against the rest of
    // a client's life: delete() takes 10 ms, which leaves few clients per round.
    final username = 'u' * 2000;
    final password = 'p' * 3000;
    await expectNoHeapGrowth(
      () => Client(username: username, password: password, logLevel: LogLevel.UA_LOGLEVEL_FATAL).delete(),
      warmUp: 20,
      iterations: 10,
      rounds: 7,
      maxGrowth: 1000,
      attempts: 3,
    );
  });

  group('connected:', () {
    late Server server;
    late Client client;
    late Client unconnected;
    late String url;

    final variableId = NodeId.fromString(1, 'leak.test.variable.${'v' * 100}');
    final objectId = NodeId.fromString(1, 'leak.test.object.${'o' * 100}');
    final methodId = NodeId.fromString(1, 'leak.test.method.${'m' * 100}');
    final numericMethodId = NodeId.fromNumeric(1, 5000);

    /// Drives both event loops until [future] completes. Nothing else pumps
    /// them: a timer-driven loop would stretch every round trip to milliseconds.
    Future<T> pump<T>(Future<T> future) async {
      var done = false;
      future.whenComplete(() => done = true).ignore();
      while (!done) {
        server.runIterate();
        client.runIterate(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }
      return future;
    }

    setUpAll(() async {
      final port = await freeTcpPort();
      server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      server.start();
      server.addVariableNode(variableId, DynamicValue(value: 0, typeId: NodeId.int32, name: 'variable'));
      server.addObjectNode(objectId, browseName: 'object');
      for (final (id, parent) in [(methodId, objectId), (numericMethodId, NodeId.objectsFolder)]) {
        server.addMethodNode(
          id,
          browseName: 'sum',
          parentNodeId: parent,
          inputArguments: [Argument(name: 'terms', dataType: NodeId.int32, valueRank: 1)],
          outputArguments: [Argument(name: 'sum', dataType: NodeId.int32)],
          callback: (inputs, session) async => [
            DynamicValue(value: inputs[0].asArray.fold<int>(0, (sum, term) => sum + term.asInt), typeId: NodeId.int32),
          ],
        );
      }

      url = 'opc.tcp://127.0.0.1:$port';
      client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      await pump(client.connect(url));
      unconnected = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    });

    tearDownAll(() async {
      await unconnected.delete();
      // The server goes first, and the client gets to see its channel close.
      // Deleting a client whose session is still active waits five seconds
      // for a CloseSession answer that a server pumped by this very isolate
      // cannot give meanwhile.
      server.shutdown();
      for (var i = 0; i < 10; i++) {
        client.runIterate(Duration.zero);
      }
      await client.delete();
      server.delete();
    });

    // A round trip takes about 50 µs, so the rounds are shorter than the
    // default. What these tests leaked was 64 bytes per operation or more.
    Future<void> expectNoGrowth(Future<void> Function() operation) =>
        expectNoHeapGrowth(operation, warmUp: 500, iterations: 500, rounds: 9, maxGrowth: 16);

    test('connecting leaves nothing on the C heap', () async {
      // open62541 takes its own copy of the URL on every connect call, also on
      // one that finds the client connected already, which is the cheap way to
      // repeat it: the session stays as it is.
      await expectNoHeapGrowth(() => client.connect(url), warmUp: 2000, iterations: 1000, rounds: 9);
      expect((await pump(client.read(variableId))).asInt, 0, reason: 'the session must have survived');
    });

    test('writing to a string NodeId leaves nothing on the C heap', () async {
      var value = 0;
      await expectNoGrowth(() => pump(client.write(variableId, DynamicValue(value: ++value, typeId: NodeId.int32))));
      expect(server.read(variableId).asInt, value);
    });

    DynamicValue terms(int count) {
      final array = DynamicValue(typeId: NodeId.int32);
      for (var i = 0; i < count; i++) {
        array[i] = DynamicValue(value: i + 1, typeId: NodeId.int32);
      }
      return array;
    }

    test('calling a method with string NodeIds leaves nothing on the C heap', () async {
      final arguments = [terms(4)];
      expect((await pump(client.call(objectId, methodId, arguments))).single.asInt, 10);
      await expectNoGrowth(() => pump(client.call(objectId, methodId, arguments)));
    });

    test('calling a method with numeric NodeIds leaves nothing on the C heap', () async {
      final arguments = [terms(4)];
      expect((await pump(client.call(NodeId.objectsFolder, numericMethodId, arguments))).single.asInt, 10);
      await expectNoGrowth(() => pump(client.call(NodeId.objectsFolder, numericMethodId, arguments)));
    });

    /// Makes the call, which must fail, and checks the failure leaves nothing.
    Future<void> expectFailedCallLeavesNothing(Client client, List<DynamicValue> arguments, Matcher error) async {
      await expectLater(client.call(objectId, methodId, arguments), error);
      await expectNoGrowth(() async {
        try {
          await client.call(objectId, methodId, arguments);
        } catch (_) {
          // Expected, checked above.
        }
      });
    }

    test('a call with an argument that cannot be encoded leaves nothing on the C heap', () async {
      // The second argument has no type, so encoding stops after the first.
      await expectFailedCallLeavesNothing(client, [terms(4), DynamicValue(value: 1)], throwsA(anything));
    });

    test('a call on a client that is not connected leaves nothing on the C heap', () async {
      await expectFailedCallLeavesNothing(unconnected, [terms(4)], throwsA(contains('BadServerNotConnected')));
    });
  });
}
