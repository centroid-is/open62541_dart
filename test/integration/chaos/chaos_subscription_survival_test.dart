// NETWORK CHAOS — subscription survival across a transient degradation.
//
// A subscription against a live sensor should ride out a bounded window of
// network degradation (high latency, not a full disconnect) and, once the
// degradation lifts, keep delivering FRESH values on the same stream.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import '../harness/toxiproxy.dart';
import 'chaos_support.dart';

void main() {
  group('chaos: subscription survival', () {
    late ReferenceServer server;
    late Toxiproxy toxiproxy;
    late ToxiProxyHandle proxy;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 200);
      await server.start();
      toxiproxy = await Toxiproxy.start();
      proxy = await toxiproxy.createProxy(upstreamHost: '127.0.0.1', upstreamPort: server.port);
    });

    tearDown(() async {
      await toxiproxy.stop();
      await server.stop();
    });

    test('monitored stream resumes fresh values after a transient latency window', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        // Generous lifetime so a few seconds of degradation cannot expire it.
        final subId = await dc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 200),
          requestedLifetimeCount: 6000,
          requestedMaxKeepAliveCount: 10,
        );

        var count = 0;
        double? last;
        final errors = <Object>[];
        final mSub = dc.client.monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 200)).listen((v) {
          count++;
          last = v.asDouble;
        }, onError: errors.add);

        // Baseline: values are flowing.
        final flowing = await waitUntil(() => count > 0, timeout: const Duration(seconds: 20));
        expect(flowing, isTrue, reason: 'no baseline values; errors=$errors');

        // Transient degradation window: heavy latency+jitter for ~4s. The link
        // stays up (keepalives still flow) so the subscription should survive.
        await proxy.addLatency(latency: const Duration(milliseconds: 350), jitter: const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(seconds: 4));
        await proxy.reset();

        // After the window lifts, the stream must deliver NEW values.
        final countAfterRemoval = count;
        final resumed = await waitUntil(() => count > countAfterRemoval, timeout: const Duration(seconds: 25));
        await mSub.cancel();

        expect(
          resumed,
          isTrue,
          reason:
              'subscription did not resume delivering values after the degradation. '
              'count=$count errors=$errors',
        );
        expect(
          errors.whereType<SubscriptionDeleted>(),
          isEmpty,
          reason: 'subscription was deleted rather than surviving the transient degradation',
        );
        expect(last, isNotNull);
        expect(last, allOf(greaterThan(0), lessThan(100)), reason: 'resumed value out of sensor range');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
