// NETWORK CHAOS — packet fragmentation (slicer toxic).
//
// A slicer chops the TCP byte stream into many small segments (here ~512 bytes
// each, with a small inter-segment delay). OPC UA messages then arrive split
// across many reads, stressing the client's chunk/message reassembly. Data
// integrity of a large payload must be preserved.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/toxiproxy.dart';
import 'chaos_support.dart';

void main() {
  group('chaos: slicer (fragmentation)', () {
    late LargeArrayServer server;
    late Toxiproxy toxiproxy;
    late ToxiProxyHandle proxy;

    setUp(() async {
      server = await LargeArrayServer.start(port: await freePort(), length: 8000);
      toxiproxy = await Toxiproxy.start();
      proxy = await toxiproxy.createProxy(upstreamHost: '127.0.0.1', upstreamPort: server.port);
    });

    tearDown(() async {
      await toxiproxy.stop();
      await server.stop();
    });

    test('fragmented large messages reassemble byte-exact', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        // Sanity: clean read is correct before fragmenting.
        final clean = await dc.client.read(server.nodeId).timeout(const Duration(seconds: 15));
        expect(arrayMismatch(clean, server.data), isNull);

        // Slice the server->client stream into ~512-byte chunks with a small
        // delay so a ~64 KB response is split into >100 fragments.
        await proxy.addSlicer(averageSize: 512, delayMicros: 200, sizeVariation: 128);

        // Read several times under fragmentation; each must be byte-exact.
        for (var i = 0; i < 3; i++) {
          final v = await dc.client.read(server.nodeId).timeout(const Duration(seconds: 30));
          expect(arrayMismatch(v, server.data), isNull, reason: 'fragmented read #$i corrupted the payload');
        }

        // Removing the slicer, reads remain correct.
        await proxy.reset();
        final after = await dc.client.read(server.nodeId).timeout(const Duration(seconds: 15));
        expect(arrayMismatch(after, server.data), isNull);
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 150)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
