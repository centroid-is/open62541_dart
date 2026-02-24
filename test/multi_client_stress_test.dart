import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  group('Multi-client stress tests', () {
    final port = Random().nextInt(8000) + 30000;
    late Server server;
    final clients = <Client>[];
    final clientCount = 6;

    setUp(() async {
      server = setupServer(port);
      addBasicVariables(server);
      clients.clear();
      for (var i = 0; i < clientCount; i++) {
        clients.add(await setupClient(port));
      }
    });

    tearDown(() async {
      for (final c in clients) {
        await c.delete();
      }
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      server.shutdown();
      server.delete();
      clients.clear();
    });

    test('all clients write to the same node simultaneously', () async {
      // Every client writes a different value to the same int node at once
      final futures = <Future>[];
      for (var i = 0; i < clientCount; i++) {
        futures.add(clients[i].write(intNodeId, DynamicValue(value: i * 100, typeId: NodeId.int32)));
      }
      await Future.wait(futures);

      // All reads should return one of the written values
      final validValues = List.generate(clientCount, (i) => i * 100).toSet();
      for (var i = 0; i < clientCount; i++) {
        final result = await clients[i].read(intNodeId);
        expect(
          validValues.contains(result.value),
          isTrue,
          reason: 'Client $i read ${result.value}, not in $validValues',
        );
      }

      // All clients should agree on the same final value
      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      final values = results.map((r) => r.value).toSet();
      expect(values.length, 1, reason: 'All clients should see the same final value');
    });

    test('all clients read the same node simultaneously', () async {
      // Set a known value
      await clients[0].write(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));

      // All clients read at once
      final results = await Future.wait(clients.map((c) => c.read(boolNodeId)));

      for (var i = 0; i < clientCount; i++) {
        expect(results[i].value, true, reason: 'Client $i should read true');
      }
    });

    test('interleaved reads and writes from all clients', () async {
      // Clients alternate writing and reading in a storm
      final futures = <Future>[];
      for (var round = 0; round < 10; round++) {
        for (var i = 0; i < clientCount; i++) {
          if ((round + i) % 2 == 0) {
            futures.add(clients[i].write(intNodeId, DynamicValue(value: round * 1000 + i, typeId: NodeId.int32)));
          } else {
            futures.add(clients[i].read(intNodeId));
          }
        }
      }
      await Future.wait(futures);

      // Server should still be healthy — read from all clients
      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      final values = results.map((r) => r.value).toSet();
      expect(values.length, 1, reason: 'Final value should be consistent');
    });

    test('all clients write different nodes concurrently', () async {
      // Create a node per client
      for (var i = 0; i < clientCount; i++) {
        server.addVariableNode(
          NodeId.fromString(1, "client_$i"),
          DynamicValue(value: 0, typeId: NodeId.int32, name: "client_$i"),
        );
      }

      // Each client writes to its own node 20 times
      final futures = <Future>[];
      for (var i = 0; i < clientCount; i++) {
        futures.add(() async {
          for (var round = 0; round < 20; round++) {
            await clients[i].write(NodeId.fromString(1, "client_$i"), DynamicValue(value: round, typeId: NodeId.int32));
          }
        }());
      }
      await Future.wait(futures);

      // Each node should have the last written value
      for (var i = 0; i < clientCount; i++) {
        final result = await clients[i].read(NodeId.fromString(1, "client_$i"));
        expect(result.value, 19, reason: 'Client $i node should have last value');
      }
    });

    test('readAttribute bulk from all clients simultaneously', () async {
      await server.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_DESCRIPTION, LocalizedText("A boolean", ""));

      final futures = <Future<Map<NodeId, DynamicValue>>>[];
      for (var i = 0; i < clientCount; i++) {
        futures.add(
          clients[i].readAttribute({
            boolNodeId: [
              AttributeId.UA_ATTRIBUTEID_VALUE,
              AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
              AttributeId.UA_ATTRIBUTEID_DATATYPE,
            ],
            intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
            doubleNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
            stringNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
          }),
        );
      }
      final results = await Future.wait(futures);

      for (var i = 0; i < clientCount; i++) {
        final r = results[i];
        expect(r[boolNodeId]!.value, true, reason: 'Client $i bool');
        expect(r[boolNodeId]!.description!.value, "A boolean", reason: 'Client $i desc');
        expect(r[intNodeId]!.value, 1, reason: 'Client $i int');
        expect(r[doubleNodeId]!.value, closeTo(3.14, 0.001), reason: 'Client $i double');
        expect(r[stringNodeId]!.value, "Hello World!", reason: 'Client $i string');
      }
    });

    test('all clients browse simultaneously', () async {
      // Add extra nodes
      for (var i = 0; i < 10; i++) {
        server.addVariableNode(
          NodeId.fromString(1, "browse_$i"),
          DynamicValue(value: i, typeId: NodeId.int32, name: "browse_$i"),
        );
      }

      final futures = <Future<List<BrowseResultItem>>>[];
      for (var i = 0; i < clientCount; i++) {
        futures.add(clients[i].browse(NodeId.objectsFolder));
      }
      final results = await Future.wait(futures);

      // All clients should see the same browse results
      final expectedCount = results[0].length;
      for (var i = 1; i < clientCount; i++) {
        expect(results[i].length, expectedCount, reason: 'Client $i should see same node count as client 0');
      }
    });

    test('multiple monitors on the same node from different clients', () async {
      final subs = <int>[];
      for (var i = 0; i < clientCount; i++) {
        subs.add(await clients[i].subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10)));
      }

      final allValues = List.generate(clientCount, (_) => <int>[]);
      final completers = List.generate(clientCount, (_) => Completer<void>());
      final subscriptions = <StreamSubscription>[];

      for (var i = 0; i < clientCount; i++) {
        final stream = clients[i].monitor(intNodeId, subs[i], samplingInterval: Duration(milliseconds: 10));
        subscriptions.add(
          stream.listen((data) {
            allValues[i].add(data.value as int);
            // initial value + 3 writes = 4 values
            if (allValues[i].length >= 4 && !completers[i].isCompleted) {
              completers[i].complete();
            }
          }),
        );
      }

      await Future.delayed(Duration(milliseconds: 300));

      // Write 3 changes from client 0
      for (var v = 10; v <= 30; v += 10) {
        await clients[0].write(intNodeId, DynamicValue(value: v, typeId: NodeId.int32));
        await Future.delayed(Duration(milliseconds: 150));
      }

      // All monitors should see the changes
      await Future.wait(completers.map((c) => c.future.timeout(Duration(seconds: 10))));

      for (final sub in subscriptions) {
        await sub.cancel();
      }

      for (var i = 0; i < clientCount; i++) {
        expect(
          allValues[i].length,
          greaterThanOrEqualTo(4),
          reason: 'Client $i should have received at least 4 values',
        );
        expect(allValues[i].last, 30, reason: 'Client $i should end with final value 30');
      }
    });

    test('write storm then bulk read from all clients', () async {
      // Create 30 nodes
      const nodeCount = 30;
      for (var i = 0; i < nodeCount; i++) {
        server.addVariableNode(
          NodeId.fromNumeric(1, 5000 + i),
          DynamicValue(value: 0, typeId: NodeId.int32, name: "storm_$i"),
        );
      }

      // All clients write to all nodes concurrently
      final writeFutures = <Future>[];
      for (var c = 0; c < clientCount; c++) {
        for (var n = 0; n < nodeCount; n++) {
          writeFutures.add(
            clients[c].write(NodeId.fromNumeric(1, 5000 + n), DynamicValue(value: c * 1000 + n, typeId: NodeId.int32)),
          );
        }
      }
      await Future.wait(writeFutures);

      // Now all clients read all nodes concurrently
      final readFutures = <Future<DynamicValue>>[];
      for (var c = 0; c < clientCount; c++) {
        for (var n = 0; n < nodeCount; n++) {
          readFutures.add(clients[c].read(NodeId.fromNumeric(1, 5000 + n)));
        }
      }
      final readResults = await Future.wait(readFutures);

      // For each node, all clients should agree on the value
      for (var n = 0; n < nodeCount; n++) {
        final nodeValues = <int>{};
        for (var c = 0; c < clientCount; c++) {
          nodeValues.add(readResults[c * nodeCount + n].value as int);
        }
        expect(nodeValues.length, 1, reason: 'All clients should agree on node $n, got $nodeValues');
      }
    });

    test('server write while clients read simultaneously', () async {
      // Server writes directly while all clients are reading
      final readFutures = <Future<DynamicValue>>[];

      // Kick off reads from all clients
      for (var round = 0; round < 5; round++) {
        for (var c = 0; c < clientCount; c++) {
          readFutures.add(clients[c].read(intNodeId));
        }
        // Server writes between read rounds
        await server.write(intNodeId, DynamicValue(value: round * 10, typeId: NodeId.int32));
      }

      final results = await Future.wait(readFutures);
      // All reads should return valid int values (no crashes, no garbage)
      for (var i = 0; i < results.length; i++) {
        expect(results[i].value, isA<int>(), reason: 'Read $i should be an int');
      }
    });

    test('mixed operations: read + write + browse + readAttribute all at once', () async {
      for (var i = 0; i < 5; i++) {
        server.addVariableNode(
          NodeId.fromString(1, "mixed_$i"),
          DynamicValue(value: i, typeId: NodeId.int32, name: "mixed_$i"),
        );
      }

      // Client 0,1: writes
      // Client 2,3: reads
      // Client 4: browse
      // Client 5: readAttribute
      final futures = <Future>[];

      // Writers
      for (var c = 0; c < 2; c++) {
        for (var round = 0; round < 10; round++) {
          futures.add(clients[c].write(intNodeId, DynamicValue(value: round, typeId: NodeId.int32)));
        }
      }

      // Readers
      for (var c = 2; c < 4; c++) {
        for (var round = 0; round < 10; round++) {
          futures.add(clients[c].read(intNodeId));
        }
      }

      // Browser
      for (var round = 0; round < 5; round++) {
        futures.add(clients[4].browse(NodeId.objectsFolder));
      }

      // Attribute reader
      for (var round = 0; round < 5; round++) {
        futures.add(
          clients[5].readAttribute({
            boolNodeId: [
              AttributeId.UA_ATTRIBUTEID_VALUE,
              AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
            ],
            intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
          }),
        );
      }

      // Fire everything and wait
      await Future.wait(futures);

      // Server should still be alive
      final check = await clients[0].read(boolNodeId);
      expect(check.value, isNotNull);
    });

    test('rapid sequential writes from each client in turn', () async {
      // Each client takes a turn writing 50 values as fast as possible
      for (var c = 0; c < clientCount; c++) {
        for (var i = 0; i < 50; i++) {
          await clients[c].write(intNodeId, DynamicValue(value: c * 1000 + i, typeId: NodeId.int32));
        }
      }

      // Final value should be from the last client
      final result = await clients[0].read(intNodeId);
      expect(result.value, (clientCount - 1) * 1000 + 49);
    });

    test('all types written and read by all clients', () async {
      // Each client writes a different type
      final writes = <Future>[
        clients[0].write(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean)),
        clients[1].write(intNodeId, DynamicValue(value: 999, typeId: NodeId.int32)),
        clients[2].write(doubleNodeId, DynamicValue(value: 2.718, typeId: NodeId.double)),
        clients[3].write(stringNodeId, DynamicValue(value: "stress_test", typeId: NodeId.uastring)),
      ];
      await Future.wait(writes);

      // Every client reads every type
      final readFutures = <Future<DynamicValue>>[];
      for (var c = 0; c < clientCount; c++) {
        readFutures.add(clients[c].read(boolNodeId));
        readFutures.add(clients[c].read(intNodeId));
        readFutures.add(clients[c].read(doubleNodeId));
        readFutures.add(clients[c].read(stringNodeId));
      }
      final results = await Future.wait(readFutures);

      for (var c = 0; c < clientCount; c++) {
        final base = c * 4;
        expect(results[base].value, false, reason: 'Client $c bool');
        expect(results[base + 1].value, 999, reason: 'Client $c int');
        expect((results[base + 2].value as double), closeTo(2.718, 0.001), reason: 'Client $c double');
        expect(results[base + 3].value, "stress_test", reason: 'Client $c string');
      }
    });
  }, timeout: Timeout(Duration(seconds: 120)));
}
