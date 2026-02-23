import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';
import 'common.dart';

/// Create an isolate client (each runs in its own isolate, no event loop contention).
Future<ClientIsolate> setupIsolateClient(int port) async {
  final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  unawaited(client.runIterate().catchError((_) {}));
  unawaited(client.connect("opc.tcp://localhost:$port"));
  await client.awaitConnect();
  return client;
}

/// Create [count] isolate clients in parallel batches of [batchSize].
Future<List<ClientIsolate>> setupIsolateClients(int port, int count, {int batchSize = 10}) async {
  final clients = <ClientIsolate>[];
  for (var start = 0; start < count; start += batchSize) {
    final end = (start + batchSize).clamp(0, count);
    final batch = await Future.wait([
      for (var i = start; i < end; i++) setupIsolateClient(port),
    ]);
    clients.addAll(batch);
  }
  return clients;
}

void main() {
  group('Client limit stress test', () {
    final port = Random().nextInt(8000) + 30000;
    late Server server;

    setUp(() {
      server = setupServer(port);
      addBasicVariables(server);
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 50));
      server.shutdown();
      server.delete();
    });

    test('10 isolate clients read simultaneously', () async {
      final clients = await setupIsolateClients(port, 10);

      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].value, 1, reason: 'Client $i should read 1');
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('25 isolate clients read simultaneously', () async {
      final clients = await setupIsolateClients(port, 25);
      print('Connected 25 isolate clients');

      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].value, 1, reason: 'Client $i should read 1');
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('50 isolate clients read simultaneously', () async {
      final clients = await setupIsolateClients(port, 50);
      print('Connected 50 isolate clients');

      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].value, 1, reason: 'Client $i should read 1');
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('100 isolate clients connect and read', () async {
      final clients = await setupIsolateClients(port, 100);
      print('Connected ${clients.length} out of 100 isolate clients');

      // Read in batches of 25
      for (var batch = 0; batch < clients.length; batch += 25) {
        final end = (batch + 25).clamp(0, clients.length);
        final results = await Future.wait(
          clients.sublist(batch, end).map((c) => c.read(intNodeId)),
        );
        for (var i = 0; i < results.length; i++) {
          expect(results[i].value, 1, reason: 'Client ${batch + i} read failed');
        }
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('50 isolate clients write concurrently then all read', () async {
      final clients = await setupIsolateClients(port, 50);

      await Future.wait([
        for (var i = 0; i < clients.length; i++)
          clients[i].write(intNodeId, DynamicValue(value: i * 10, typeId: NodeId.int32)),
      ]);

      final results = await Future.wait(clients.map((c) => c.read(intNodeId)));
      final values = results.map((r) => r.value).toSet();
      expect(values.length, 1, reason: 'All clients should see same final value');

      for (final c in clients) {
        await c.delete();
      }
    });

    test('50 isolate clients each write their own node', () async {
      for (var i = 0; i < 50; i++) {
        server.addVariableNode(
          NodeId.fromNumeric(1, 8000 + i),
          DynamicValue(value: 0, typeId: NodeId.int32, name: "limit_$i"),
        );
      }

      final clients = await setupIsolateClients(port, 50);

      await Future.wait([
        for (var i = 0; i < 50; i++)
          () async {
            for (var round = 0; round < 5; round++) {
              await clients[i].write(
                NodeId.fromNumeric(1, 8000 + i),
                DynamicValue(value: round, typeId: NodeId.int32),
              );
            }
          }(),
      ]);

      for (var i = 0; i < 50; i++) {
        final result = await clients[i].read(NodeId.fromNumeric(1, 8000 + i));
        expect(result.value, 4, reason: 'Client $i node should have 4');
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('25 isolate clients browse simultaneously', () async {
      for (var i = 0; i < 20; i++) {
        server.addVariableNode(
          NodeId.fromString(1, "browse_limit_$i"),
          DynamicValue(value: i, typeId: NodeId.int32, name: "browse_limit_$i"),
        );
      }

      final clients = await setupIsolateClients(port, 25);

      final results = await Future.wait(
        clients.map((c) => c.browse(NodeId.objectsFolder)),
      );

      final expectedCount = results[0].length;
      for (var i = 1; i < results.length; i++) {
        expect(results[i].length, expectedCount,
            reason: 'Client $i should see same node count');
      }

      for (final c in clients) {
        await c.delete();
      }
    });

    test('50 isolate clients mixed operations', () async {
      for (var i = 0; i < 10; i++) {
        server.addVariableNode(
          NodeId.fromString(1, "mixed_limit_$i"),
          DynamicValue(value: i, typeId: NodeId.int32, name: "mixed_limit_$i"),
        );
      }

      final clients = await setupIsolateClients(port, 50);

      final futures = <Future>[];

      // 20 writers
      for (var c = 0; c < 20; c++) {
        for (var round = 0; round < 3; round++) {
          futures.add(
            clients[c].write(intNodeId, DynamicValue(value: round, typeId: NodeId.int32)),
          );
        }
      }

      // 20 readers
      for (var c = 20; c < 40; c++) {
        for (var round = 0; round < 3; round++) {
          futures.add(clients[c].read(intNodeId));
        }
      }

      // 10 browsers
      for (var c = 40; c < 50; c++) {
        futures.add(clients[c].browse(NodeId.objectsFolder));
      }

      await Future.wait(futures);

      final check = await clients[0].read(boolNodeId);
      expect(check.value, isNotNull);

      for (final c in clients) {
        await c.delete();
      }
    });
  }, timeout: Timeout(Duration(seconds: 300)));
}
