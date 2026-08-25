import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

// The production runaway this guards against (tfc-hmi#346, plant
// 2026-08-25): a failed handshake leaves its transport half-open —
// UA_Client_disconnect mid-handshake does not close the socket — and the
// supervisor's retry cycle then leaks one Established connection per
// attempt. Enough leaked connections exhaust the server's connection pool,
// the server stops answering OPN, handshakes stall harder, and the client
// manufactures the very "sickness" it is retrying against (observed live: 20
// zombie sockets strangling one PLC).
//
// The fix is that the supervisor recreates the native client between
// attempts (UA_Client_delete is what actually closes the transport), so at
// any moment at most the current attempt's connection may be open. This test
// stalls every handshake at the TCP level and asserts both halves: retries
// keep coming, and dead attempts' sockets get CLOSED. It also pins the
// stream-continuity contract of the recreation: a stateStream subscription
// taken once must keep emitting across every native-client swap.

void main() {
  test('retry cycles must not accumulate half-open connections', () async {
    // Accepts TCP connections and never speaks: every handshake stalls,
    // every attempt fails by timeout, the supervisor retries forever.
    final gate = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var accepted = 0;
    final live = <Socket>{};
    gate.listen((socket) {
      accepted++;
      live.add(socket);
      socket.done.catchError((_) {});
      socket.listen((_) {}, onError: (_) => live.remove(socket), onDone: () => live.remove(socket));
    });

    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL, requestTimeout: const Duration(milliseconds: 300));

    // One subscription, taken before any recreation happens.
    var transitions = 0;
    client.stateStream.listen((_) => transitions++);

    // Never activates — that's the point. Ignore the dangling future.
    client
        .keepConnected(
          'opc.tcp://127.0.0.1:${gate.port}',
          retryInterval: const Duration(milliseconds: 200),
          maxBackoff: const Duration(milliseconds: 500),
          // A handshake that makes no observable progress for this long is
          // abandoned — that's what turns the stall into retry cycles.
          handshakeTimeout: const Duration(seconds: 1),
        )
        .catchError((_) {});

    // Let several retry cycles run.
    final sw = Stopwatch()..start();
    while ((accepted < 4 || transitions < 4) && sw.elapsed < const Duration(seconds: 30)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    expect(accepted, greaterThanOrEqualTo(4), reason: 'sanity: the supervisor must keep retrying a dead endpoint');
    // Give in-flight closes a moment to land at the gate.
    await Future.delayed(const Duration(seconds: 1));
    expect(
      live.length,
      lessThanOrEqualTo(2),
      reason:
          'dead attempts must CLOSE their sockets: one leaked '
          'Established connection per retry cycle is what exhausts a '
          "PLC's connection pool in production",
    );
    expect(
      transitions,
      greaterThanOrEqualTo(4),
      reason:
          'a stateStream subscription taken once must keep emitting '
          'across native-client recreations',
    );

    client.stopKeepConnected();
    await client.delete();
    await gate.close();
    for (final socket in live) {
      socket.destroy();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('requestTimeout bounds the native config timeout', () async {
    final rng = Random();
    final defaulted = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    expect(
      defaulted.config.timeoutMs,
      500,
      reason:
          'the default must bound the multi-second handshake selects '
          'that starve the isolate (captured: ~5s ws2_32!select chunks '
          'inside a 10ms run_iterate budget)',
    );
    await defaulted.delete();

    final tuned = Client(
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      requestTimeout: Duration(milliseconds: 1000 + rng.nextInt(1000)),
    );
    expect(tuned.config.timeoutMs, greaterThanOrEqualTo(1000));
    await tuned.delete();
  });
}
