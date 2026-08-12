// HMI "Dashboard" scenario.
//
// A single control-screen client subscribes to EVERY sensor across all tanks
// (5 tanks x 5 sensors = 25 monitored items) at a realistic 250ms HMI refresh
// rate, then verifies it receives a coherent, steady stream of updates for
// every tag over several seconds -- no loss, no stall, values in range.
//
// Runs for both ClientKind.direct and ClientKind.isolate.
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
const _hmiRate = Duration(milliseconds: 250);

void main() {
  group('HMI dashboard', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: _tanks, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('subscribes to all ${_tanks * allSensors.length} tags and gets a coherent stream ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        StreamSubscription<Map<NodeId, DynamicValue>>? sub;
        try {
          final tags = await resolveSensorTags(dc.client, tanks: _tanks);
          expect(tags, hasLength(_tanks * allSensors.length));
          final byId = {for (final t in tags) t.nodeId: t};

          final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: _hmiRate);
          final stream = dc.client.monitoredItems(valueParam(tags), subId, samplingInterval: _hmiRate);

          var emissions = 0;
          var undersizedEmissions = 0;
          final errors = <Object>[];
          final changeCounts = {for (final t in tags) t.label: 0};
          final lastValue = <String, double>{};
          final rangeViolations = <String>[];
          DateTime? lastEmissionAt;
          Duration maxGap = Duration.zero;

          sub = stream.listen((map) {
            final now = DateTime.now();
            if (lastEmissionAt != null) {
              final gap = now.difference(lastEmissionAt!);
              if (gap > maxGap) maxGap = gap;
            }
            lastEmissionAt = now;

            emissions++;
            if (map.length != tags.length) undersizedEmissions++;

            // Extract primitives synchronously: the direct client re-emits the
            // SAME mutated map/DynamicValue instances, so we must read now.
            for (final entry in map.entries) {
              final tag = byId[entry.key];
              if (tag == null) continue;
              final v = entry.value.asDouble;
              if (!inRange(tag.sensor, v)) {
                rangeViolations.add('${tag.label}=$v');
              }
              final prev = lastValue[tag.label];
              if (prev == null || prev != v) {
                changeCounts[tag.label] = changeCounts[tag.label]! + 1;
              }
              lastValue[tag.label] = v;
            }
          }, onError: errors.add);

          // Observe a few seconds of live operation.
          await Future<void>.delayed(const Duration(seconds: 5));
          await sub.cancel();
          sub = null;

          // No unhandled stream errors while healthy.
          expect(errors, isEmpty, reason: 'unexpected stream errors: $errors');

          // Steady flow: many emissions, no long stall between them.
          expect(emissions, greaterThanOrEqualTo(20), reason: 'too few emissions ($emissions) -- stream stalled?');
          expect(maxGap, lessThan(const Duration(seconds: 2)), reason: 'gap between emissions too large: $maxGap');

          // Every emission is a full snapshot of all monitored tags.
          expect(undersizedEmissions, 0, reason: 'saw $undersizedEmissions emissions missing tags');

          // Every tag was reported at least once, in range.
          for (final t in tags) {
            expect(lastValue.containsKey(t.label), isTrue, reason: 'never received a value for ${t.label}');
          }
          expect(rangeViolations, isEmpty, reason: 'out-of-range readings: $rangeViolations');

          // Live sensors must actually keep updating (no per-tag stall).
          for (final t in tags.where((t) => liveSensors.contains(t.sensor))) {
            expect(
              changeCounts[t.label],
              greaterThanOrEqualTo(4),
              reason: '${t.label} updated only ${changeCounts[t.label]} times',
            );
          }
          // Salinity is static: reported, but not expected to change.
          for (final t in tags.where((t) => staticSensors.contains(t.sensor))) {
            expect(changeCounts[t.label], greaterThanOrEqualTo(1), reason: '${t.label} never reported');
          }
        } finally {
          await sub?.cancel();
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 90)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
