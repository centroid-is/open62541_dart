// STRESS: high-frequency subscription updates sustained for several seconds.
//
// A server that mutates its sensors every 20ms is subscribed at a 20ms
// publishing/sampling interval. Over a sustained window we assert throughput
// (many value changes actually delivered) and that there is no unbounded
// backlog: emissions stay current (the last emission lands right up to the end
// of the run, not seconds behind).
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
  group('high-frequency subscription', () {
    late ReferenceServer server;

    setUp(() async {
      // Fast mutation so there is genuinely something to deliver at 20ms.
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 3, updateMs: 20);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('20ms subscription sustains throughput without backlog ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        StreamSubscription<DynamicValue>? sub;
        try {
          final tags = await resolveTankSensors(dc.client, tanks: 3, sensors: liveSensors);
          final tempId = tags.firstWhere((t) => t.sensor == 'Temperature').nodeId;

          final subId = await dc.client.subscriptionCreate(
            requestedPublishingInterval: const Duration(milliseconds: 20),
          );
          final stream = dc.client.monitor(
            tempId,
            subId,
            samplingInterval: const Duration(milliseconds: 20),
            queueSize: 8,
          );

          final errors = <Object>[];
          var count = 0;
          var changes = 0;
          double? last;
          DateTime? lastAt;
          const run = Duration(seconds: 6);
          final start = DateTime.now();

          sub = stream.listen((v) {
            count++;
            lastAt = DateTime.now();
            final d = v.asDouble;
            if (last == null || last != d) changes++;
            last = d;
          }, onError: errors.add);

          await Future<void>.delayed(run);
          await sub.cancel();
          sub = null;

          expect(errors, isEmpty, reason: 'stream errors during high-frequency run: $errors');

          // Throughput: the server changed Temperature roughly every 20ms for
          // 6s (~300 distinct values). Even with coalescing and scheduling
          // slack, we must have delivered many dozens of updates. Assert a
          // conservative floor rather than an exact rate.
          expect(count, greaterThan(50), reason: 'only $count updates in 6s at 20ms');
          expect(changes, greaterThan(50), reason: 'only $changes distinct values in 6s');

          // No unbounded backlog: the final emission must be recent relative to
          // when we stopped listening. If the client fell hopelessly behind,
          // the last delivered value would lag the run end by many seconds.
          final lag = start.add(run).difference(lastAt!);
          expect(
            lag.inMilliseconds,
            lessThan(2000),
            reason: 'last update lagged run end by ${lag.inMilliseconds}ms (backlog building up)',
          );
        } finally {
          await sub?.cancel();
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 90)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
