// Phase-0 gate: proves the shared harness works end to end before the rest of
// the suite is built on top of it. Exercises:
//   asyncua reference server -> toxiproxy -> driven Dart client
//   browse-based node resolution, read, write, method call,
//   a latency toxic, and a hard connection drop.
//
// Requires the local deps from test/integration/setup_local.sh.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'harness/browse_resolver.dart';
import 'harness/dart_client.dart';
import 'harness/net.dart';
import 'harness/paths.dart';
import 'harness/reference_server.dart';
import 'harness/toxiproxy.dart';

void main() {
  group('harness smoke', () {
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

    test('browse, read, write, method call through the proxy', () async {
      final dc = await connectClient(proxy.url);
      try {
        // Browse-resolve a sensor and read it.
        final tempId = await tankVar(dc.client, 1, 'Temperature');
        final temp = await dc.client.read(tempId);
        expect(temp.asDouble, allOf(greaterThan(0), lessThan(100)));

        // Write a setpoint and read it back.
        final setId = await tankVar(dc.client, 1, 'TempSetpoint');
        await dc.client.write(setId, DynamicValue(value: 13.5, typeId: NodeId.double));
        final readBack = await dc.client.read(setId);
        expect(readBack.asDouble, closeTo(13.5, 1e-9));

        // Call a method on the tank object.
        final tankId = await resolvePath(dc.client, ['Plant', 'Tank1']);
        final feedId = await tankMethod(dc.client, 1, 'FeedNow');
        final result = await dc.client.call(tankId, feedId, [DynamicValue(value: 25.0, typeId: NodeId.double)]);
        expect(result.first.asBool, isTrue);
      } finally {
        await dc.dispose();
      }
    });

    test('latency toxic slows but does not break reads', () async {
      final dc = await connectClient(proxy.url);
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');
        await dc.client.read(tempId); // warm

        await proxy.addLatency(latency: const Duration(milliseconds: 200));
        final sw = Stopwatch()..start();
        final v = await dc.client.read(tempId).timeout(const Duration(seconds: 10));
        sw.stop();
        expect(v.asDouble, isNotNull);
        // Round trip crosses the proxy twice, so >= one latency.
        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
      } finally {
        await dc.dispose();
      }
    });

    test('hard connection drop surfaces as a client state change', () async {
      final dc = await connectClient(proxy.url);
      try {
        final states = <ClientState>[];
        final sub = dc.client.stateStream.listen(states.add);

        // Drop the link: existing connection killed, new ones refused.
        await proxy.disable();

        // The client should observe the channel leaving OPEN within a few seconds.
        await Future<void>.delayed(const Duration(seconds: 3));
        await sub.cancel();

        expect(
          states.any((s) => s.channelState != SecureChannelState.UA_SECURECHANNELSTATE_OPEN),
          isTrue,
          reason: 'expected a non-OPEN channel state after the drop; saw $states',
        );
      } finally {
        await dc.dispose();
      }
    });
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
