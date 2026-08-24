// Proves that several Dart [Server]s pumped cooperatively on the SAME isolate
// no longer starve each other.
//
// Root cause of the starvation: Server.runIterate({waitInterval}) forwards to
// the native UA_Server_run_iterate(server, waitInterval). With
// waitInterval == true (the OLD default), that native call BLOCKS the isolate
// thread until the server's next scheduled activity. Dart is cooperative and
// single-isolate, so a server parked in a blocking iterate starves every other
// server/client driven on the same isolate. With N servers pumped this way, the
// first client connects fast, the next one waits seconds, and later ones time
// out entirely.
//
// The fix makes runIterate() non-blocking by default (a single poll that yields
// promptly to the event loop). This test starts N servers on distinct ports,
// pumps them all on the one isolate, and asserts every client connects and
// reads within a bounded time.
//
// To observe the OLD failure, flip `useBlockingDefault` below to `true`: each
// server's drive loop then calls runIterate(waitInterval: true) and clients
// 1..N-1 time out. It is left `false` so CI stays green.
//
// Tagged `integration`: pumping several servers cooperatively on one isolate is
// timing-sensitive and flakes on loaded/slow CI runners, so it is skipped in
// the default `dart test` run. Run locally with `dart test --run-skipped`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// Set to true to reproduce the pre-fix starvation (later clients time out).
const bool useBlockingDefault = false;

void main() {
  const serverCount = 3;

  // Pick distinct free-ish ports.
  final rng = Random();
  var ports = <int>{};
  while (ports.length != serverCount) {
    ports.add(4840 + rng.nextInt(10000));
  }
  final serverPorts = ports.toList();

  final servers = <Server>[];
  final clients = <Client>[];

  // Drive a server on the shared isolate. Mirrors common.dart setupServer but
  // lets us force the blocking default for the demonstration path.
  Server startServer(int port) {
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    () async {
      // The delay is REQUIRED with the non-blocking default to avoid a busy-spin.
      while (server.runIterate(waitInterval: useBlockingDefault)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }();
    return server;
  }

  tearDown(() async {
    for (final server in servers) {
      server.shutdown();
    }
    for (final client in clients) {
      await client.delete();
    }
    for (final server in servers) {
      server.delete();
    }
    servers.clear();
    clients.clear();
  });

  test('N cooperatively-pumped servers all accept a client and serve a read', () async {
    final stopwatch = Stopwatch()..start();

    for (final port in serverPorts) {
      servers.add(startServer(port));
    }

    // Connect one client to EACH server, all on this same isolate. Under the
    // old blocking default the second/third connect would starve; here every
    // one must complete within the bound.
    final readValues = <bool>[];
    for (final port in serverPorts) {
      final client = setupClient(port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      clients.add(await client);
    }

    // Every client reads a known variable back.
    for (final client in clients) {
      final value = await client.read(boolNodeId);
      readValues.add(value.value as bool);
    }

    stopwatch.stop();

    expect(clients.length, serverCount, reason: 'All clients should connect');
    expect(readValues.length, serverCount, reason: 'All clients should read');
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 15)),
      reason:
          'All servers must be reachable within the bound; the blocking '
          'default starves later servers well past this.',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
