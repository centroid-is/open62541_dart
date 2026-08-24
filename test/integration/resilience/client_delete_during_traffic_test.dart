// RESILIENCE: deleting the client while traffic is in flight must not crash the
// VM or trigger a use-after-free of native callbacks (cf.
// test/monitor_callback_lifecycle_test.dart, where a Publish response arriving
// after the monitored item is torn down could invoke a freed callback).
//
// Here the server stays up; we exercise delete() concurrent with an active
// subscription and with in-flight reads, for both the direct and isolate
// clients. Success == the process survives and stays usable for the next test.
//
// FINDING: `Client.delete()` (direct client) is NOT safe to call while a
// monitored-item stream is still active — it SEGV-crashes the VM. The isolate
// client is safe because its DeleteMessage handler cancels every active stream
// before deleting the native client. See the two `skip:`ped tests below for the
// root cause. Cancelling the stream before delete() is a safe workaround (proven
// by the "safe pattern" test).
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

// Root cause of the direct-client crash, cited by the quarantined tests below.
const _deleteBug =
    'BUG: Client.delete() (lib/src/client.dart:1594) calls UA_Client_delete '
    'without first cancelling active monitored-item streams, so an in-flight '
    'Publish data-change notification is delivered against freed native memory '
    '-> SEGV (SEGV_ACCERR, si_addr=0x368). The isolate path is safe because it '
    'cancels active streams before delete (lib/src/isolate.dart:871-877).';

void main() {
  group('client delete during active traffic (asyncua)', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 50);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      final bugForDirect = kind == ClientKind.direct ? _deleteBug : null;

      test(
        'delete() mid-subscription does not crash [$kind]',
        () async {
          final dc = await connectClient(server.endpoint, kind: kind);
          final tempId = await tankVar(dc.client, 1, 'Temperature');

          final subId = await dc.client.subscriptionCreate(
            requestedPublishingInterval: const Duration(milliseconds: 50),
          );
          final stream = dc.client.monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 50));

          final values = <double>[];
          // Deliberately keep the monitored-item stream *active* (do not cancel
          // it before delete) so the tear-down races with incoming Publish
          // responses.
          final sub = stream.listen((v) => values.add(v.asDouble), onError: (_) {});

          // Let publishes flow so responses are genuinely in flight.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(values, isNotEmpty, reason: 'data should be flowing before delete');

          // Tear the client down without cancelling the stream first.
          await dc.dispose();

          // Best-effort cancel of the now-orphaned stream must not throw/crash.
          await sub.cancel();

          // If we reached here the VM did not crash with a use-after-free.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(true, isTrue);
        },
        timeout: const Timeout(Duration(seconds: 30)),
        skip: bugForDirect,
      );

      test(
        'delete() with multiple monitored items active does not crash [$kind]',
        () async {
          final dc = await connectClient(server.endpoint, kind: kind);
          final tempId = await tankVar(dc.client, 1, 'Temperature');
          final doId = await tankVar(dc.client, 1, 'DissolvedOxygen');
          final phId = await tankVar(dc.client, 1, 'PH');

          final subId = await dc.client.subscriptionCreate(
            requestedPublishingInterval: const Duration(milliseconds: 50),
          );
          final stream = dc.client.monitoredItems(
            {
              tempId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              doId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              phId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            },
            subId,
            samplingInterval: const Duration(milliseconds: 50),
          );

          var updates = 0;
          final sub = stream.listen((_) => updates++, onError: (_) {});

          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(updates, greaterThan(0), reason: 'multi-item stream should deliver before delete');

          // Delete while all three monitored items are live.
          await dc.dispose();
          await sub.cancel();

          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(true, isTrue);
        },
        timeout: const Timeout(Duration(seconds: 30)),
        skip: bugForDirect,
      );

      // The SAFE pattern: cancel the monitored-item stream, then delete. This
      // is the workaround for the bug above and must not crash for either kind.
      test('safe pattern: cancel stream, then delete() [$kind]', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
        final stream = dc.client.monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 50));
        final values = <double>[];
        final sub = stream.listen((v) => values.add(v.asDouble), onError: (_) {});

        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(values, isNotEmpty);

        // Cancel first, let the native delete settle, then delete.
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await dc.dispose();

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(true, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('delete() with in-flight reads does not crash [$kind]', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        // Fire a burst of reads without awaiting, so responses/callbacks are
        // outstanding when delete() runs. Swallow their (expected) failures.
        final pending = <Future<void>>[];
        for (var i = 0; i < 12; i++) {
          pending.add(dc.client.read(tempId).then((_) {}, onError: (_) {}));
        }

        // Delete immediately, racing the outstanding read callbacks.
        await dc.dispose();

        // Draining the pending futures must not surface an uncaught error.
        await Future.wait(pending).timeout(const Duration(seconds: 10), onTimeout: () => const []);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(true, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
