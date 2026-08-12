// STRESS: resource-sanity soak.
//
// Sustained subscription load for ~30s on a moderately large farm: one
// subscription, 60 monitored items, fast publishing interval. This is the
// category most likely to expose leaks / use-after-free (the repo also runs an
// ASan CI job); here we simply assert steady behaviour over the whole run:
//   * traffic in every time window (no stall),
//   * no unhandled stream errors,
//   * a roughly steady delivery rate (no runaway growth or collapse), and
//   * the connection is still fully functional at the end (read + write).
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
import 'stress_support.dart';

void main() {
  group('resource-sanity soak', () {
    late ReferenceServer server;
    const tanks = 12; // 12 tanks x 5 sensors = 60 monitored items.

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: tanks, updateMs: 100);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('sustained 60-item subscription stays steady', () async {
      final dc = await connectClient(server.endpoint);
      StreamSubscription<Map<NodeId, DynamicValue>>? sub;
      try {
        final tags = await resolveTankSensors(dc.client, tanks: tanks);
        expect(tags.length, 60);

        final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
        final stream = dc.client.monitoredItems(
          valueParam(tags.map((t) => t.nodeId)),
          subId,
          samplingInterval: const Duration(milliseconds: 50),
        );

        const soak = Duration(seconds: 30);
        const bucket = Duration(seconds: 5);
        final bucketCount = soak.inMilliseconds ~/ bucket.inMilliseconds;
        final buckets = List<int>.filled(bucketCount, 0);
        final errors = <Object>[];
        var emissions = 0;
        final start = DateTime.now();

        sub = stream.listen((map) {
          emissions++;
          final b = DateTime.now().difference(start).inMilliseconds ~/ bucket.inMilliseconds;
          if (b >= 0 && b < bucketCount) buckets[b]++;
        }, onError: errors.add);

        await Future<void>.delayed(soak);
        await sub.cancel();
        sub = null;

        expect(errors, isEmpty, reason: 'stream errors during soak: $errors');
        expect(emissions, greaterThan(100), reason: 'suspiciously few emissions ($emissions) over 40s');

        // No stall: every 5s window carried traffic.
        for (var i = 0; i < bucketCount; i++) {
          expect(buckets[i], greaterThan(0), reason: 'no updates in window $i of $bucketCount (buckets=$buckets)');
        }

        // Steady rate: compare the busiest and quietest full windows. A healthy
        // run keeps a fairly flat rate; a runaway backlog or progressive
        // slowdown would blow this ratio out. Generous 6x bound absorbs GC and
        // scheduling jitter on a shared machine.
        final maxB = buckets.reduce((a, b) => a > b ? a : b);
        final minB = buckets.reduce((a, b) => a < b ? a : b);
        expect(maxB, lessThanOrEqualTo(minB * 6), reason: 'delivery rate not steady across windows: $buckets');

        // Still fully functional after the soak.
        final setId = await tankVar(dc.client, 1, 'TempSetpoint');
        await dc.client.write(setId, DynamicValue(value: 11.25, typeId: NodeId.double));
        final back = await dc.client.read(setId).timeout(const Duration(seconds: 10));
        expect(back.asDouble, closeTo(11.25, 1e-9));
      } finally {
        await sub?.cancel();
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
