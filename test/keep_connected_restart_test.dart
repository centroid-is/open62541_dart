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
    await client.keepConnected(url, iterateInterval: interval);
    await client.keepConnected(url, iterateInterval: interval);
    await client.awaitConnect();
    // Let any stale loop show itself, then count one window's worth of pumping.
    await Future.delayed(const Duration(milliseconds: 200));
    client.iterations = 0;
    await Future.delayed(const Duration(milliseconds: 600));
    final iterations = client.iterations;
    await client.delete();
    // One pump at 20 ms (blocking runIterate + 20 ms sleep) makes ~15 calls in
    // 600 ms; two pumps make ~30. Allow generous jitter but not a doubling.
    expect(iterations, lessThan(24), reason: 'a doubled pump made $iterations iterations in 600 ms');
    expect(iterations, greaterThan(5), reason: 'the pump is not running');
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
