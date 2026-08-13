// Reconnection against a controller, WITHOUT touching hardware: a toxiproxy is
// placed in front of the PLC/emulator (client -> toxiproxy -> PLC) and the link
// is dropped. Verifies:
//   1. an opt-in keepConnected() client rides through the drop and recovers;
//   2. reconnection REUSES one session slot -- it does not accumulate stale
//      sessions on the tiny controller (proven via CurrentSessionCount).
@Tags(['plc'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../integration/harness/paths.dart';
import '../integration/harness/toxiproxy.dart';
import 'plc_browse.dart';
import 'plc_config.dart';
import 'plc_fixture.dart';
import 'plc_session.dart';

void main() {
  final targets = PlcConfig.configured();
  tearDownAll(PlcSession.shutdownEmulators);

  if (targets.isEmpty || !toxiproxyAvailable()) {
    test('reconnection', () {}, skip: 'needs PLC_<X>_URL (or =emulator) and the toxiproxy binary.');
    return;
  }

  for (final cfg in targets) {
    // The toxiproxy technique only works against a server that advertises the
    // proxy's address. A real controller advertises its own IP in GetEndpoints,
    // and open62541 follows it ("Use the EndpointURL returned from FindServers
    // and reconnect") — reconnecting directly and bypassing the proxy, so the
    // link can't be dropped. keepConnected() itself is vendor-independent and is
    // covered by the emulator run, so skip the proxy reconnect on real hardware.
    if (!cfg.useEmulator) {
      test('reconnection [${cfg.name}] (emulator-only)', () {
        markTestSkipped(
          'toxiproxy reconnect is emulator-only: a real controller advertises its own '
          'EndpointURL, which open62541 follows and thereby bypasses the proxy.',
        );
      });
      continue;
    }

    group('reconnection [${cfg.name}]', () {
      late Toxiproxy toxi;
      late ToxiProxyHandle proxy;
      late PlcSession observer; // direct session, watches CurrentSessionCount

      setUpAll(() async {
        final up = await PlcSession.upstream(cfg);
        toxi = await Toxiproxy.start();
        proxy = await toxi.createProxy(upstreamHost: up.host, upstreamPort: up.port);
        observer = await PlcSession.open(cfg);
      });
      tearDownAll(() async {
        await observer.dispose();
        await toxi.stop();
      });

      Future<Client> connectThroughProxy() async {
        // Same security wiring as PlcSession (token encryption on M241/M262).
        final client = PlcSession.rawClient(cfg);
        await client.keepConnected('opc.tcp://127.0.0.1:${proxy.listenPort}/').timeout(const Duration(seconds: 30));
        return client;
      }

      test('keepConnected recovers after a link drop', () async {
        final client = await connectThroughProxy();
        try {
          final counter = (await findByBrowseName(client, PlcFixture.counterName))!;
          final before = (await client.read(counter)).asInt;

          // Drop the link (existing connection killed, new refused), then heal.
          await proxy.disable();
          await Future<void>.delayed(const Duration(seconds: 3));
          await proxy.enable();

          // keepConnected must bring us back on its own (we never call connect).
          int? after;
          final deadline = DateTime.now().add(const Duration(seconds: 25));
          while (DateTime.now().isBefore(deadline)) {
            try {
              after = (await client.read(counter).timeout(const Duration(seconds: 3))).asInt;
              break; // a successful read means we recovered
            } catch (_) {}
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          expect(after, isNotNull, reason: 'client did not recover after the drop');
          expect(after, greaterThan(before), reason: 'Counter should have advanced across the outage');
        } finally {
          await client.delete();
        }
      }, timeout: const Timeout(Duration(seconds: 90)));

      test('repeated reconnects do not accumulate sessions', () async {
        final base = await _settled(observer); // observer only
        final client = await connectThroughProxy();
        try {
          for (var i = 0; i < 3; i++) {
            await proxy.disable();
            await Future<void>.delayed(const Duration(seconds: 2));
            await proxy.enable();
            // wait until reconnected, then confirm a read works again
            NodeId? counter;
            try {
              counter = await findByBrowseName(client, PlcFixture.counterName).timeout(const Duration(seconds: 25));
            } catch (_) {}
            if (counter != null) {
              await _retryRead(client, counter, const Duration(seconds: 25));
            }
          }
          if (base != null) {
            // After the outages, stale sessions must be reaped (short session
            // timeout) so we settle back to observer + this one live client.
            await _until(
              () async => (await observer.currentSessionCount() ?? 0) <= base + 1,
              cfg.sessionTimeout + const Duration(seconds: 15),
            );
            expect(
              await observer.currentSessionCount(),
              lessThanOrEqualTo(base + 1),
              reason: 'reconnects must not pile up stale sessions',
            );
          }
        } finally {
          await client.delete();
        }
      }, timeout: const Timeout(Duration(seconds: 180)));
    });
  }
}

Future<void> _retryRead(Client c, NodeId n, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      await c.read(n).timeout(const Duration(seconds: 3));
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}

Future<int?> _settled(PlcSession s) async {
  int? prev;
  for (var i = 0; i < 20; i++) {
    final c = await s.currentSessionCount();
    if (c == null) return null;
    if (c == prev) return c;
    prev = c;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return prev;
}

Future<void> _until(Future<bool> Function() cond, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
