// NETWORK CHAOS — bandwidth throttle + large payload.
//
// With a hard throughput cap (tens of KB/s) a large array read must be *slow*
// but must arrive byte-for-byte intact. Uses a Dart Server hosting a large
// Double array as a controllable large-payload upstream behind the proxy.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/toxiproxy.dart';
import 'chaos_support.dart';

void main() {
  group('chaos: bandwidth throttle', () {
    late LargeArrayServer server;
    late Toxiproxy toxiproxy;
    late ToxiProxyHandle proxy;

    setUp(() async {
      // 8000 doubles ≈ 64 KB of payload (plus OPC UA framing).
      server = await LargeArrayServer.start(port: await freePort(), length: 8000);
      toxiproxy = await Toxiproxy.start();
      proxy = await toxiproxy.createProxy(upstreamHost: '127.0.0.1', upstreamPort: server.port);
    });

    tearDown(() async {
      await toxiproxy.stop();
      await server.stop();
    });

    test('throttled large read is slow but byte-exact', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        // Baseline: unthrottled read is correct and quick.
        final baseSw = Stopwatch()..start();
        final base = await dc.client.read(server.nodeId).timeout(const Duration(seconds: 15));
        baseSw.stop();
        expect(arrayMismatch(base, server.data), isNull);

        // Cap throughput at 20 KB/s on the server->client stream.
        await proxy.addBandwidth(kbps: 20);

        final sw = Stopwatch()..start();
        final v = await dc.client.read(server.nodeId).timeout(const Duration(seconds: 60));
        sw.stop();

        // Data integrity: every element must match exactly.
        expect(arrayMismatch(v, server.data), isNull, reason: 'throttled transfer corrupted the payload');

        // Behavioural timing: ~64 KB at 20 KB/s cannot finish instantly.
        // Robust lower bound well under the ~3.2s theoretical minimum.
        expect(
          sw.elapsedMilliseconds,
          greaterThanOrEqualTo(1500),
          reason: 'throttled read finished implausibly fast (base=${baseSw.elapsedMilliseconds}ms)',
        );
        expect(
          sw.elapsedMilliseconds,
          greaterThan(baseSw.elapsedMilliseconds),
          reason: 'throttled read should be slower than the baseline read',
        );
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
