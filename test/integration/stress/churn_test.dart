// STRESS: rapid lifecycle churn.
//
//  1. Connect -> operate -> delete in a tight loop, for both the direct and
//     the isolate client, verifying every cycle completes (no crash, hang, or
//     FD/resource exhaustion) and the whole loop finishes within a bound.
//  2. Subscription + monitored-item create/destroy churn on ONE persistent
//     connection: repeatedly create a subscription, attach a monitored item,
//     await first data, tear the stream down again.
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
  group('lifecycle churn', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 100);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('30x connect -> read -> delete churn ($kind)', () async {
        const cycles = 30;
        var ok = 0;
        final failures = <String>[];
        final sw = Stopwatch()..start();

        for (var i = 0; i < cycles; i++) {
          DrivenClient? dc;
          try {
            dc = await connectClient(server.endpoint, kind: kind);
            // A real unit of work each cycle: resolve + read a live sensor.
            final tempId = await tankVar(dc.client, 1, 'Temperature');
            final v = await dc.client.read(tempId).timeout(const Duration(seconds: 10));
            expect(v.asDouble, allOf(greaterThan(0), lessThan(100)));
            ok++;
          } catch (e) {
            failures.add('cycle $i: $e');
          } finally {
            await dc?.dispose();
          }
        }
        sw.stop();

        expect(failures, isEmpty, reason: 'churn failures: $failures');
        expect(ok, cycles);
        // If FDs/threads leaked and the OS started refusing, later cycles would
        // slow to a crawl or hang; a generous overall bound catches that.
        expect(sw.elapsed, lessThan(const Duration(seconds: 120)), reason: '$cycles cycles took ${sw.elapsed}');
      }, timeout: const Timeout(Duration(seconds: 180)));
    }

    test('40x subscription + monitored-item create/destroy churn (persistent client)', () async {
      final dc = await connectClient(server.endpoint);
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');
        const cycles = 40;
        var ok = 0;
        final failures = <String>[];

        for (var i = 0; i < cycles; i++) {
          StreamSubscription<Map<NodeId, DynamicValue>>? sub;
          try {
            final subId = await dc.client.subscriptionCreate(
              requestedPublishingInterval: const Duration(milliseconds: 50),
            );
            final firstData = Completer<void>();
            final errs = <Object>[];
            final stream = dc.client.monitoredItems(
              valueParam([tempId]),
              subId,
              samplingInterval: const Duration(milliseconds: 50),
            );
            sub = stream.listen((_) {
              if (!firstData.isCompleted) firstData.complete();
            }, onError: errs.add);
            await firstData.future.timeout(
              const Duration(seconds: 10),
              onTimeout: () => throw StateError('no data on cycle $i'),
            );
            if (errs.isNotEmpty) throw StateError('stream errors on cycle $i: $errs');
            ok++;
          } catch (e) {
            failures.add('cycle $i: $e');
          } finally {
            await sub?.cancel();
          }
        }

        expect(failures, isEmpty, reason: 'sub/monitor churn failures: $failures');
        expect(ok, cycles);

        // The connection is still usable after all that churn.
        final v = await dc.client.read(tempId).timeout(const Duration(seconds: 10));
        expect(v.asDouble, allOf(greaterThan(0), lessThan(100)));
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 180)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
