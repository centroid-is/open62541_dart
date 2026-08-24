// CONCURRENCY: many concurrent subscriptions / monitored items on ONE client.
//
// A single client fans out a large number of monitored items - both as many
// separate subscriptions each with one item, and as one subscription carrying
// many items - and asserts that every one of them receives data. This stresses
// the per-client callback demultiplexing (each monitored item maps back to its
// own Dart stream via an isolate-local native callback).
//
// The asyncua variant subscribes to every live sensor on every tank; the Dart
// variant drives deterministic values so each item's exact value is checked.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'concurrency_support.dart';

void main() {
  // ---- asyncua: many live monitored items on one client -------------------
  group('many monitored items on one asyncua client', () {
    const tanks = 3;
    const liveSensors = ['Temperature', 'DissolvedOxygen', 'PH', 'WaterLevel'];
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: tanks, updateMs: 100);
      await server.start();
    });
    tearDown(() async => server.stop());

    test('one subscription, many items: every item receives an update', () async {
      final dc = await connect1(server.endpoint);
      try {
        // Resolve every live sensor on every tank (tanks * liveSensors items).
        final ids = <NodeId>[];
        for (var t = 1; t <= tanks; t++) {
          for (final s in liveSensors) {
            ids.add(await tankVar(dc.client, t, s));
          }
        }
        expect(ids.length, tanks * liveSensors.length);

        final subId = await dc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 100),
        );
        final param = {
          for (final id in ids) id: const [AttributeId.UA_ATTRIBUTEID_VALUE],
        };
        final updated = <NodeId>{};
        final allSeen = Completer<void>();
        final sub = dc.client.monitoredItems(param, subId, samplingInterval: const Duration(milliseconds: 100)).listen((
          batch,
        ) {
          updated.addAll(batch.keys);
          if (updated.length >= ids.length && !allSeen.isCompleted) allSeen.complete();
        });
        await allSeen.future.timeout(const Duration(seconds: 40));
        await sub.cancel();
        expect(updated.length, ids.length, reason: 'not every monitored item reported');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('many separate subscriptions, one item each, all deliver', () async {
      final dc = await connect1(server.endpoint);
      try {
        final ids = <NodeId>[];
        for (var t = 1; t <= tanks; t++) {
          ids.add(await tankVar(dc.client, t, 'Temperature'));
        }

        final waits = <Future<void>>[];
        final subs = <StreamSubscription<DynamicValue>>[];
        for (final id in ids) {
          final subId = await dc.client.subscriptionCreate(
            requestedPublishingInterval: const Duration(milliseconds: 100),
          );
          final got = Completer<void>();
          subs.add(
            dc.client.monitor(id, subId, samplingInterval: const Duration(milliseconds: 100)).listen((v) {
              if (!got.isCompleted) got.complete();
            }),
          );
          waits.add(got.future);
        }
        await Future.wait(waits).timeout(const Duration(seconds: 40));
        for (final s in subs) {
          await s.cancel();
        }
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');

  // ---- Dart server: deterministic many-item fan-out -----------------------
  group('many monitored items on one Dart-server client', () {
    test('16 nodes, one subscription: each item delivers its own value', () async {
      const nodeCount = 16;
      final port = await freePort();
      final server = await startDartServer(port, seed: (s) => seedPerClientNodes(s, nodeCount));
      DrivenClient? dc;
      try {
        dc = await connect1(server.endpoint);
        final client = dc.client;

        // Prime each node to a distinct value, then subscribe to all of them.
        final want = <NodeId, double>{};
        for (var i = 0; i < nodeCount; i++) {
          want[clientDoubleNode(i)] = (i + 1).toDouble();
          await client.write(clientDoubleNode(i), DynamicValue(value: 0.0, typeId: NodeId.double));
        }

        final subId = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 20));
        final param = {
          for (final id in want.keys) id: const [AttributeId.UA_ATTRIBUTEID_VALUE],
        };
        final latest = <NodeId, double>{};
        final done = Completer<void>();
        final sub = client.monitoredItems(param, subId, samplingInterval: const Duration(milliseconds: 20)).listen((
          batch,
        ) {
          batch.forEach((k, v) => latest[k] = v.asDouble);
          final converged = want.entries.every((e) => (latest[e.key] ?? -1) == e.value);
          if (converged && !done.isCompleted) done.complete();
        });

        // Now write the distinct target values.
        for (final e in want.entries) {
          await client.write(e.key, DynamicValue(value: e.value, typeId: NodeId.double));
        }

        await done.future.timeout(const Duration(seconds: 30));
        await sub.cancel();

        for (final e in want.entries) {
          expect(latest[e.key], e.value, reason: 'monitored item ${e.key} wrong/absent');
        }
      } finally {
        await dc?.dispose();
        await server.stop();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
