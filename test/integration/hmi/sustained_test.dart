// HMI "Sustained operation" scenario (soak).
//
// A compressed long-run dashboard subscription that must stay healthy: over
// 30s of continuous operation the client should keep receiving steady, in-range
// updates for every tag, with no unhandled stream errors and no multi-second
// stall in any window.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'hmi_support.dart';

const _tanks = 5;
const _rate = Duration(milliseconds: 250);
const _soak = Duration(seconds: 30);
const _bucket = Duration(seconds: 5);

void main() {
  group('HMI sustained operation', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: _tanks, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('30s dashboard soak stays healthy ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        StreamSubscription<Map<NodeId, DynamicValue>>? sub;
        try {
          final tags = await resolveSensorTags(dc.client, tanks: _tanks);
          final byId = {for (final t in tags) t.nodeId: t};

          final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: _rate);
          final stream = dc.client.monitoredItems(valueParam(tags), subId, samplingInterval: _rate);

          final errors = <Object>[];
          final rangeViolations = <String>[];
          final changeCounts = {for (final t in tags) t.label: 0};
          final lastValue = <String, double>{};
          final bucketCount = (_soak.inMilliseconds / _bucket.inMilliseconds).ceil();
          final buckets = List<int>.filled(bucketCount, 0);
          final start = DateTime.now();

          sub = stream.listen((map) {
            final elapsed = DateTime.now().difference(start);
            final b = elapsed.inMilliseconds ~/ _bucket.inMilliseconds;
            if (b >= 0 && b < bucketCount) buckets[b]++;
            for (final entry in map.entries) {
              final tag = byId[entry.key];
              if (tag == null) continue;
              final v = entry.value.asDouble;
              if (!inRange(tag.sensor, v)) rangeViolations.add('${tag.label}=$v');
              final prev = lastValue[tag.label];
              if (prev == null || prev != v) {
                changeCounts[tag.label] = changeCounts[tag.label]! + 1;
              }
              lastValue[tag.label] = v;
            }
          }, onError: errors.add);

          await Future<void>.delayed(_soak);
          await sub.cancel();
          sub = null;

          // Healthy throughout.
          expect(errors, isEmpty, reason: 'stream errors during soak: $errors');
          expect(rangeViolations, isEmpty, reason: 'out-of-range readings: $rangeViolations');

          // Steady: every 5s window saw traffic (no stall). Allow the final
          // window to be partial but still non-empty.
          for (var i = 0; i < bucketCount; i++) {
            expect(buckets[i], greaterThan(0), reason: 'no updates in window $i of $bucketCount (buckets=$buckets)');
          }

          // Live sensors kept updating across the whole run. At 250ms and a 30s
          // soak, expect many dozens of changes; assert a conservative floor.
          for (final t in tags.where((t) => liveSensors.contains(t.sensor))) {
            expect(
              changeCounts[t.label],
              greaterThanOrEqualTo(30),
              reason: '${t.label} only changed ${changeCounts[t.label]} times in 30s',
            );
          }
        } finally {
          await sub?.cancel();
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 120)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
