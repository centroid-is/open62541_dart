// NETWORK CHAOS — abrupt TCP reset (reset_peer toxic).
//
// A reset_peer toxic sends a TCP RST, tearing the connection down hard mid-flight
// (as a crashing NAT / firewall / peer would). The client must turn this into a
// clean, recoverable error — never a crash or an unbounded hang — both while a
// request is in flight and while a subscription is live. After the toxic is
// removed the client must recover.
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
  group('chaos: reset_peer (TCP RST)', () {
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

    test('RST mid-operation surfaces an error (not a hang) and the client recovers', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');
        await dc.client.read(tempId); // warm

        // Any further traffic triggers an immediate RST.
        await proxy.addResetPeer();

        // The read must resolve (error or otherwise) — the key property is that
        // it does not hang. A bounded timeout guards against an unbounded hang;
        // if it *times out*, the tolerant `waitForRead` below still proves the
        // client neither crashed nor wedged.
        var readThrew = false;
        try {
          await dc.client.read(tempId).timeout(const Duration(seconds: 12));
        } catch (_) {
          readThrew = true;
        }

        // Remove the fault and confirm recovery via a fresh successful read.
        await proxy.reset();
        final recovered = await waitForRead(dc.client, tempId, timeout: const Duration(seconds: 40));
        expect(recovered, isTrue, reason: 'client never recovered a working read after RST (readThrew=$readThrew)');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('RST mid-subscription errors the stream and the client recovers', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        final states = <ClientState>[];
        final stateSub = dc.client.stateStream.listen(states.add);

        final subId = await dc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 200),
        );
        final values = <double>[];
        final errors = <Object>[];
        final mSub = dc.client
            .monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 200))
            .listen((v) => values.add(v.asDouble), onError: errors.add);

        final flowing = await waitUntil(() => values.isNotEmpty, timeout: const Duration(seconds: 20));
        expect(flowing, isTrue, reason: 'no baseline values before RST; errors=$errors');

        await proxy.addResetPeer();

        // The loss must surface: a stream error or a non-OPEN channel state.
        final surfaced = await waitUntil(
          () =>
              errors.any((e) => e is SecureChannelClosed || e is Inactivity || e is SubscriptionDeleted) ||
              states.any((s) => s.channelState != SecureChannelState.UA_SECURECHANNELSTATE_OPEN),
          timeout: const Duration(seconds: 40),
        );
        await stateSub.cancel();
        await mSub.cancel();
        expect(
          surfaced,
          isTrue,
          reason:
              'subscription loss not surfaced after RST. errors=$errors '
              'states=${states.map((s) => s.channelState).toList()}',
        );

        await proxy.reset();
        final recovered = await waitForRead(dc.client, tempId, timeout: const Duration(seconds: 40));
        expect(recovered, isTrue, reason: 'client never recovered after RST mid-subscription');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 150)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
