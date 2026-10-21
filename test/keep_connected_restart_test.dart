import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Counts the pump's calls through the public [runIterate], so the number of
/// pump loops alive can be observed without any hook in the library.
class _CountingClient extends Client {
  _CountingClient() : super(logLevel: LogLevel.UA_LOGLEVEL_ERROR);
  int iterations = 0;

  @override
  bool runIterate([Duration iterate = const Duration(milliseconds: 100)]) {
    iterations++;
    return super.runIterate(iterate);
  }
}

/// Regression test: calling [Client.keepConnected] again must replace the
/// running pump and supervisor, not add a second pair. The old code reset
/// `_keepConnected` to false and back to true synchronously, so the loops
/// already running never observed the stop and kept going alongside the new
/// ones.
void main() {
  late Server server;
  late Timer serverTimer;

  setUp(() {
    server = setupServer();
    serverTimer = Timer.periodic(const Duration(milliseconds: 5), (_) => server.runIterate());
  });

  tearDown(() {
    serverTimer.cancel();
    server.shutdown();
    server.delete();
  });

  test('a second keepConnected() replaces the pump instead of doubling it', () async {
    final client = _CountingClient();
    final url = 'opc.tcp://127.0.0.1:${server.port}';
    const interval = Duration(milliseconds: 20);
    const window = Duration(milliseconds: 600);

    // Baseline: one pump, measured on this machine (a blocking runIterate plus
    // a 20 ms sleep per turn, so the count depends on the runner's speed).
    await client.keepConnected(url, iterateInterval: interval);
    await client.awaitConnect();
    await Future.delayed(const Duration(milliseconds: 200));
    client.iterations = 0;
    await Future.delayed(window);
    final single = client.iterations;

    // Restart: the old pump must stop, so the rate must not change.
    await client.keepConnected(url, iterateInterval: interval);
    await Future.delayed(const Duration(milliseconds: 200));
    client.iterations = 0;
    await Future.delayed(window);
    final afterRestart = client.iterations;
    await client.delete();

    expect(single, greaterThan(0), reason: 'the pump is not running');
    // A doubled pump makes about twice the calls; allow jitter but not that.
    expect(
      afterRestart,
      lessThan((single * 1.5).ceil() + 1),
      reason: 'after a restart the pump made $afterRestart iterations against $single for a single pump',
    );
  });

  test('stopKeepConnected() after a restart stops everything', () async {
    final client = _CountingClient();
    final url = 'opc.tcp://127.0.0.1:${server.port}';
    await client.keepConnected(url, iterateInterval: const Duration(milliseconds: 20));
    await client.keepConnected(url, iterateInterval: const Duration(milliseconds: 20));
    await client.awaitConnect();
    client.stopKeepConnected();
    await Future.delayed(const Duration(milliseconds: 100));
    client.iterations = 0;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(client.iterations, 0, reason: 'a pump kept running after stopKeepConnected()');
    await client.delete();
  });
}
