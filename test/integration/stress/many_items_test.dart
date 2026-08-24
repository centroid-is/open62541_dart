// STRESS: many monitored items on a single subscription.
//
// A large fish farm (many tanks) is subscribed with a few hundred monitored
// items on ONE subscription at a fast publishing interval. The library's
// `monitoredItems` stream only emits once EVERY item has reported at least
// once (see client.dart: it waits for seenMonIds == nodeCount), so a first
// emission that carries all keys is itself proof that every monitored item's
// initial value flowed. We then assert that live sensors keep updating.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'stress_support.dart';

void main() {
  group('many monitored items on one subscription', () {
    late ReferenceServer server;
    const tanks = 50; // 50 tanks * 5 sensors = 250 monitored items.

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: tanks, updateMs: 100);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('250 items all report and live ones keep updating', () async {
      final dc = await connectClient(server.endpoint);
      StreamSubscription<Map<NodeId, DynamicValue>>? sub;
      try {
        final tags = await resolveTankSensors(dc.client, tanks: tanks);
        expect(tags.length, 250, reason: 'expected 50 tanks x 5 sensors');
        final liveIds = tags.where((t) => t.live).map((t) => t.nodeId).toSet();

        final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
        final stream = dc.client.monitoredItems(
          valueParam(tags.map((t) => t.nodeId)),
          subId,
          samplingInterval: const Duration(milliseconds: 50),
        );

        final errors = <Object>[];
        final firstFull = Completer<Map<NodeId, DynamicValue>>();
        var emissions = 0;
        // Track how many times each live node's value actually changed.
        final lastLive = <NodeId, double>{};
        final changeCounts = <NodeId, int>{for (final id in liveIds) id: 0};

        sub = stream.listen((map) {
          emissions++;
          if (!firstFull.isCompleted) firstFull.complete(Map.of(map));
          for (final id in liveIds) {
            final v = map[id]?.asDouble;
            if (v == null) continue;
            final prev = lastLive[id];
            if (prev == null || prev != v) {
              changeCounts[id] = changeCounts[id]! + 1;
              lastLive[id] = v;
            }
          }
        }, onError: errors.add);

        // First full emission = every one of the 250 items reported. Allow
        // plenty of slack: 250 monitored-item creates + first publish cycle.
        final full = await firstFull.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw StateError('never received a full emission (250 items)'),
        );
        expect(full.length, 250, reason: 'first emission must carry every monitored item');
        expect(full.keys.toSet(), tags.map((t) => t.nodeId).toSet());

        // Let it run so live sensors update repeatedly.
        await Future<void>.delayed(const Duration(seconds: 8));
        await sub.cancel();
        sub = null;

        expect(errors, isEmpty, reason: 'stream errors: $errors');
        expect(emissions, greaterThan(1), reason: 'subscription stalled after first emission');

        // Every live sensor must have changed several times (server mutates at
        // 100ms; over 8s that is dozens of ticks). A conservative floor guards
        // against a subset of items silently stalling.
        final stalled = changeCounts.entries.where((e) => e.value < 5).toList();
        expect(stalled, isEmpty, reason: '${stalled.length} live items updated < 5 times: $stalled');
      } finally {
        await sub?.cancel();
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
