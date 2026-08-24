// RESILIENCE: what happens to a monitored-item stream when the server crashes
// and restarts underneath it.
//
// Observed behaviour: on the drop the monitored stream emits a
// `SecureChannelClosed` error (it does NOT close/`onDone`). open62541 clears all
// client-side subscriptions on disconnect, and there is no auto-reconnect, so
// the stream never resumes on its own. After an application-driven reconnect the
// app must create a NEW subscription + monitored item to resume delivery.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'recovery_support.dart';

void main() {
  group('subscription recovery across restart (asyncua)', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 100);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('monitored stream surfaces SecureChannelClosed on crash and does not self-resume', () async {
      final rc = await ResilientClient.connect(server.endpoint);
      try {
        final tempId = await tankVar(rc.client, 1, 'Temperature');
        final subId = await rc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 100),
        );
        final stream = rc.client.monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 100));

        final values = <double>[];
        final errors = <Object>[];
        var done = false;
        final firstError = Completer<Object>();
        final sub = stream.listen(
          (v) => values.add(v.asDouble),
          onError: (Object e) {
            errors.add(e);
            if (!firstError.isCompleted) firstError.complete(e);
          },
          onDone: () => done = true,
        );

        // Confirm the subscription is delivering.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(values, isNotEmpty, reason: 'subscription should deliver before the crash');
        final countBeforeCrash = values.length;

        // Crash + restart the server on the same port.
        await server.restart();

        // The stream must surface a channel-loss error.
        final err = await firstError.future.timeout(const Duration(seconds: 15));
        expect(err, isA<SecureChannelClosed>(), reason: 'expected SecureChannelClosed, got ${err.runtimeType}');

        // Give the (now back) server time; the stream must NOT self-resume,
        // because there is no auto-reconnect and the subscription was cleared.
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(
          values.length,
          countBeforeCrash,
          reason: 'stream should not resume on its own after the crash (no auto-reconnect)',
        );
        expect(done, isFalse, reason: 'stream errors rather than closing on channel loss');

        await sub.cancel();
      } finally {
        await rc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('subscription resumes after app reconnect + fresh subscribe', () async {
      final rc = await ResilientClient.connect(server.endpoint);
      try {
        final tempId = await tankVar(rc.client, 1, 'Temperature');

        // First subscription, pre-crash.
        final subId1 = await rc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 100),
        );
        final stream1 = rc.client.monitor(tempId, subId1, samplingInterval: const Duration(milliseconds: 100));
        final pre = <double>[];
        final err1 = Completer<Object>();
        final sub1 = stream1.listen(
          (v) => pre.add(v.asDouble),
          onError: (Object e) {
            if (!err1.isCompleted) err1.complete(e);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(pre, isNotEmpty);

        // Crash + restart, then application-driven reconnect.
        await server.restart();
        await err1.future.timeout(const Duration(seconds: 15));
        await sub1.cancel();

        await rc.reconnect(server.endpoint, timeout: const Duration(seconds: 25));
        expect(isActivated(await rc.currentState()), isTrue);

        // Re-resolve (namespace can be re-established) and re-subscribe.
        final tempId2 = await tankVar(rc.client, 1, 'Temperature');
        final subId2 = await rc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 100),
        );
        final stream2 = rc.client.monitor(tempId2, subId2, samplingInterval: const Duration(milliseconds: 100));
        final post = <double>[];
        final got = Completer<void>();
        final sub2 = stream2.listen((v) {
          post.add(v.asDouble);
          if (!got.isCompleted) got.complete();
        });

        // New subscription must start delivering again.
        await got.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            fail('resubscribed stream did not deliver after recovery');
          },
        );
        expect(post, isNotEmpty);
        expect(post.first, allOf(greaterThan(0), lessThan(100)));

        await sub2.cancel();
      } finally {
        await rc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
