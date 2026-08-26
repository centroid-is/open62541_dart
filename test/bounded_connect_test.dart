import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

// Bounded connect / bounded reconnect-supervision.
//
// Field failure this pins (SVN plant, deterministic on one Beckhoff endpoint):
// after a mid-handshake fatal, open62541 can end up with the secure channel
// OPEN, the session never re-created and connectStatus GOOD — forever. In that
// state nothing errors: run_iterate keeps returning GOOD, awaitConnect() waits
// for an ACTIVATED that never comes, and keepConnected's supervisor classifies
// it as "still connecting" indefinitely. The client is a zombie: socket
// established, no data, no log lines, no recovery.
//
// The exact C state is not reproducible with an in-process open62541 server,
// but the property under test does not depend on it: a black-hole TCP peer
// (accepts, never speaks) produces the same observable shape — a connect
// attempt that makes no progress and never errors. These tests pin that no
// such state is waited on unboundedly:
//   * connect() must fail within its bound and tear the attempt down, so the
//     dead state cannot outlive the call (the next runIterate reports false
//     instead of pumping a zombie forever);
//   * keepConnected() must abandon a stuck "connecting" state after
//     connectTimeout and re-issue a fresh connect, observable as repeated TCP
//     accepts on the black-hole listener.
void main() {
  test('connect() to a black-hole endpoint fails within its bound and tears down', () async {
    // Accepts TCP connections and never sends a byte: no progress, no error.
    final blackHole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    blackHole.listen(held.add);

    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    var running = true;
    () async {
      while (running && client.runIterate(const Duration(milliseconds: 10))) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();

    final sw = Stopwatch()..start();
    await expectLater(
      client.connect("opc.tcp://127.0.0.1:${blackHole.port}", timeout: const Duration(seconds: 2)),
      throwsA(anything),
    );
    sw.stop();
    // Must be our 2 s bound (plus scheduling slack), not open62541's own 5 s
    // request timeout and certainly not forever.
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 4500)));

    // The dead attempt was torn down: the client is not left pumping a
    // half-connected channel, so a caller-driven iterate loop terminates
    // instead of parking on a zombie.
    expect(client.runIterate(const Duration(milliseconds: 10)), isFalse);

    running = false;
    await client.delete();
    for (final s in held) {
      s.destroy();
    }
    await blackHole.close();
  }, timeout: Timeout(Duration(seconds: 30)));

  test('connect() to a refused port fails fast instead of waiting forever', () async {
    // Bind then close to get a port that actively refuses connections.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    var running = true;
    () async {
      while (running && client.runIterate(const Duration(milliseconds: 10))) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();

    final sw = Stopwatch()..start();
    await expectLater(
      client.connect("opc.tcp://127.0.0.1:$port", timeout: const Duration(seconds: 10)),
      throwsA(anything),
    );
    sw.stop();
    // Fail-fast on the terminal connectStatus, well before the 10 s backstop.
    // Before the bound existed this call parked forever: a refused connect
    // never reaches ACTIVATED and awaitConnect() had no other exit.
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)));

    running = false;
    await client.delete();
  }, timeout: Timeout(Duration(seconds: 30)));

  test('keepConnected abandons a stuck connect and re-issues instead of parking', () async {
    final blackHole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    var accepts = 0;
    blackHole.listen((socket) {
      accepts++;
      held.add(socket); // Keep it open: never answer, never close.
    });

    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    // The supervisor owns the pump. The returned future only completes on a
    // first activation, which never happens against a black hole.
    unawaited(
      client
          .keepConnected(
            "opc.tcp://127.0.0.1:${blackHole.port}",
            retryInterval: const Duration(milliseconds: 200),
            connectTimeout: const Duration(seconds: 2),
          )
          .catchError((_) {}),
    );

    // The unfixed supervisor connects once and then classifies the silent
    // half-open channel as "connecting" forever: exactly one accept, ever.
    // The bounded supervisor tears the stuck attempt down after
    // connectTimeout and dials again — observable as further accepts.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (accepts < 2 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(accepts, greaterThanOrEqualTo(2), reason: 'supervisor parked on a wedged connect instead of retrying');

    client.stopKeepConnected();
    await client.delete();
    for (final s in held) {
      s.destroy();
    }
    await blackHole.close();
  }, timeout: Timeout(Duration(seconds: 40)));

  test('bounded connect still activates against a live server (isolate client)', () async {
    final port = Random().nextInt(10000) + 4840;
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    () async {
      while (server.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }();

    final client = await ClientIsolate.create();
    unawaited(client.runIterate().catchError((_) {}));
    await client.connect("opc.tcp://localhost:$port", timeout: const Duration(seconds: 15));
    await client.delete();
    server.shutdown();
    server.delete();
  }, timeout: Timeout(Duration(seconds: 30)));
}
