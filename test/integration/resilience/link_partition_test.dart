// RESILIENCE: network partition WITHOUT process death. The server stays up; the
// TCP link is dropped and later restored via toxiproxy disable()/enable().
//
// Observed behaviour mirrors a crash: while the link is down the client's single
// reconnect attempt fails (BADCONNECTIONREJECTED) and it gives up; the session
// leaves ACTIVATED and does not return on its own. Once the link is restored the
// application-driven reconnect re-activates the session quickly and reads work.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import '../harness/browse_resolver.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import '../harness/toxiproxy.dart';
import 'recovery_support.dart';

void main() {
  group(
    'network partition via toxiproxy',
    () {
      late ReferenceServer server;
      late Toxiproxy toxiproxy;
      late ToxiProxyHandle proxy;

      setUp(() async {
        server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 150);
        await server.start();
        toxiproxy = await Toxiproxy.start();
        proxy = await toxiproxy.createProxy(upstreamHost: '127.0.0.1', upstreamPort: server.port);
      });

      tearDown(() async {
        await toxiproxy.stop();
        await server.stop();
      });

      for (final kind in clientTypes) {
        test('link down/up: client detects the partition and recovers [$kind]', () async {
          final rc = await ResilientClient.connect(proxy.url, kind: kind);
          try {
            final tempId = await tankVar(rc.client, 1, 'Temperature');
            expect((await rc.client.read(tempId)).asDouble, allOf(greaterThan(0), lessThan(100)));

            // Arm a detector for the channel leaving OPEN before partitioning.
            final dropped = rc.stateStream.firstWhere((s) => !channelOpen(s));

            // Partition: drop existing connection, refuse new ones.
            await proxy.disable();

            await dropped.timeout(const Duration(seconds: 10));
            expect(isActivated(await rc.currentState()), isFalse, reason: 'session should be down during partition');

            // Hold the partition a moment, then heal the link.
            await Future<void>.delayed(const Duration(seconds: 2));
            await proxy.enable();

            // Application-driven reconnect over the restored link.
            await rc.reconnect(proxy.url, timeout: const Duration(seconds: 25));
            expect(isActivated(await rc.currentState()), isTrue, reason: 'session should re-activate after healing');

            final v = await rc.client.read(tempId).timeout(const Duration(seconds: 10));
            expect(v.asDouble, allOf(greaterThan(0), lessThan(100)));
          } finally {
            await rc.dispose();
          }
        }, timeout: const Timeout(Duration(seconds: 120)));
      }
    },
    skip: asyncuaAvailable() && toxiproxyAvailable()
        ? false
        : 'run test/integration/setup_local.sh first (needs asyncua + toxiproxy)',
  );
}
