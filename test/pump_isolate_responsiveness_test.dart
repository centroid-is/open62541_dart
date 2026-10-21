import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Regression test for the problem `keepConnected(nonBlocking: true)` fixes
/// (PR #116): the default pump blocks the owning isolate inside open62541's
/// `select()` for up to [iterateInterval] on every turn, so a Dart timer on
/// the same isolate cannot fire meanwhile. Measured through a 5 ms metronome:
/// with the blocking pump its gaps grow to the pump interval; with the
/// non-blocking pump they stay at timer granularity.
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

  /// Pumps [client] with the given mode for ~1 s and returns the largest gap
  /// between two ticks of a 5 ms metronome running on this isolate.
  Future<Duration> maxMetronomeGap({required bool nonBlocking}) async {
    const pumpInterval = Duration(milliseconds: 300);
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    await client.keepConnected(
      'opc.tcp://127.0.0.1:${server.port}',
      iterateInterval: pumpInterval,
      nonBlocking: nonBlocking,
    );
    await client.awaitConnect();

    var worst = Duration.zero;
    var last = DateTime.now();
    final metronome = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = DateTime.now();
      final gap = now.difference(last);
      if (gap > worst) worst = gap;
      last = now;
    });
    await Future.delayed(const Duration(seconds: 1));
    metronome.cancel();
    await client.delete();
    return worst;
  }

  test('the owning isolate stays responsive while the client is pumped', () async {
    final worst = await maxMetronomeGap(nonBlocking: true);
    // The blocking pump produces gaps of about the pump interval (300 ms);
    // a responsive isolate keeps the 5 ms metronome within scheduling jitter,
    // which on a loaded CI runner has been seen above 60 ms, hence the margin.
    expect(worst, lessThan(const Duration(milliseconds: 150)), reason: 'metronome stalled for $worst');
  });

  test('the blocking pump is what stalls the isolate (documents the problem)', () async {
    final worst = await maxMetronomeGap(nonBlocking: false);
    expect(worst, greaterThan(const Duration(milliseconds: 200)), reason: 'blocking pump stalled only $worst');
  });
}
