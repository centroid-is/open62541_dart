// NETWORK CHAOS — high latency.
//
// A latency toxic (hundreds of ms, with jitter) must only make the client
// slower, never break it: connect / read / write / subscribe still succeed, and
// configurable connect + operation timeouts behave as documented.
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
import '../harness/toxiproxy.dart';

void main() {
  group('chaos: latency', () {
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

    test('connect, read, write and subscribe all survive high latency+jitter', () async {
      // Latency applied BEFORE connect: the whole handshake crosses the slow
      // link too, so this also proves connect tolerates a latent link.
      await proxy.addLatency(latency: const Duration(milliseconds: 300), jitter: const Duration(milliseconds: 150));

      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');

        // A read still returns a valid value, just slower (>= ~one latency).
        final sw = Stopwatch()..start();
        final temp = await dc.client.read(tempId).timeout(const Duration(seconds: 15));
        sw.stop();
        expect(temp.asDouble, allOf(greaterThan(0), lessThan(100)));
        expect(
          sw.elapsedMilliseconds,
          greaterThanOrEqualTo(200),
          reason: 'read should be delayed by roughly the injected latency',
        );

        // Write + read-back still round-trips correctly under latency.
        final setId = await tankVar(dc.client, 1, 'TempSetpoint');
        await dc.client
            .write(setId, DynamicValue(value: 12.25, typeId: NodeId.double))
            .timeout(const Duration(seconds: 15));
        final back = await dc.client.read(setId).timeout(const Duration(seconds: 15));
        expect(back.asDouble, closeTo(12.25, 1e-9));

        // A subscription still delivers values across the slow link.
        final subId = await dc.client.subscriptionCreate(
          requestedPublishingInterval: const Duration(milliseconds: 200),
        );
        final got = <double>[];
        final mErrors = <Object>[];
        final mSub = dc.client
            .monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 200))
            .listen((v) => got.add(v.asDouble), onError: mErrors.add);
        final delivered = await () async {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (DateTime.now().isBefore(deadline)) {
            if (got.isNotEmpty) return true;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return got.isNotEmpty;
        }();
        await mSub.cancel();
        expect(delivered, isTrue, reason: 'subscription delivered no value under latency; errors=$mErrors');
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('operation timeout: a too-short read timeout fails cleanly, a generous one succeeds', () async {
      final dc = await connectClient(proxy.url, connectTimeout: const Duration(seconds: 30));
      try {
        final tempId = await tankVar(dc.client, 1, 'Temperature');
        await dc.client.read(tempId); // warm

        // Heavy latency so a tight per-operation timeout is guaranteed to trip.
        await proxy.addLatency(latency: const Duration(milliseconds: 800));

        await expectLater(
          dc.client.read(tempId).timeout(const Duration(milliseconds: 150)),
          throwsA(isA<TimeoutException>()),
          reason: 'a 150ms operation timeout must fire under 800ms latency',
        );

        // Remove the latency; the client is still healthy and reads succeed.
        await proxy.reset();
        final v = await dc.client.read(tempId).timeout(const Duration(seconds: 15));
        expect(
          v.asDouble,
          allOf(greaterThan(0), lessThan(100)),
          reason: 'client must remain usable after an operation timeout',
        );
      } finally {
        await dc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('connect timeout: a too-short connectTimeout fails cleanly under heavy latency', () async {
      // 500ms downstream latency makes the multi-round-trip handshake take a
      // couple of seconds, so a sub-second connect timeout must trip.
      await proxy.addLatency(latency: const Duration(milliseconds: 500));

      // Build the client by hand so we can always tear it down even though
      // connect() never returns a DrivenClient here.
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      var running = true;
      unawaited(() async {
        while (running && client.runIterate(const Duration(milliseconds: 10))) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }());
      try {
        await expectLater(
          client.connect(proxy.url).timeout(const Duration(milliseconds: 400)),
          throwsA(isA<TimeoutException>()),
          reason: 'a 400ms connect timeout must fire under 500ms latency',
        );
      } finally {
        running = false;
        await client.delete();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: asyncuaAvailable() && toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first');
}
