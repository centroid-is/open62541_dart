// NETWORK CHAOS — frozen link (timeout toxic).
//
// A timeout toxic with `after: 0` keeps the TCP connection open but silently
// drops all data — a classic half-open "black hole". The client must DETECT the
// stall (surface Inactivity / SecureChannelClosed on a monitored stream, or the
// channel leaves OPEN) rather than hang forever, and must RECOVER once the toxic
// is removed.
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
  group('chaos: frozen link', () {
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

    test('stall is detected on the monitored stream and the client recovers', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        final states = <ClientState>[];
        final stateSub = dc.client.stateStream.listen(states.add);

        final subId = await dc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 200),
          requestedMaxKeepAliveCount: 3,
        );
        final values = <double>[];
        final errors = <Object>[];
        final mSub = dc.client
            .monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 200))
            .listen((v) => values.add(v.asDouble), onError: errors.add);

        // Confirm live data is flowing before we freeze the link.
        final flowing = await waitUntil(() => values.isNotEmpty, timeout: const Duration(seconds: 20));
        expect(flowing, isTrue, reason: 'no baseline values before freeze; errors=$errors');

        // Freeze: connection stays open, all data is dropped.
        await proxy.addTimeout();

        // The client must SURFACE the stall: a stream error, or the channel
        // leaving OPEN. It must not hang silently forever.
        final detected = await waitUntil(
          () =>
              errors.any((e) => e is Inactivity || e is SecureChannelClosed || e is SubscriptionDeleted) ||
              states.any((s) => s.channelState != SecureChannelState.UA_SECURECHANNELSTATE_OPEN),
          timeout: const Duration(seconds: 40),
        );
        await stateSub.cancel();
        await mSub.cancel();
        expect(
          detected,
          isTrue,
          reason:
              'client did not detect the frozen link within 40s. '
              'errors=$errors states=${states.map((s) => s.channelState).toList()}',
        );

        // Unfreeze and confirm the client recovers to a usable channel.
        await proxy.reset();
        final recovered = await waitForRead(dc.client, tempId, timeout: const Duration(seconds: 40));
        expect(recovered, isTrue, reason: 'client never recovered a working read after the freeze was removed');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 150)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
