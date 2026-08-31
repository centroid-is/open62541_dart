import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// A server whose run_iterate pump we control, so we can cleanly simulate a
// crash: stop pumping, shut down, delete and drop the instance, then bring a
// fresh server up on the SAME port with the SAME variables.
class ManagedServer {
  ManagedServer._(this.port, this.server);

  final int port;
  Server server;
  bool _running = false;

  static ManagedServer start(int port) {
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    final managed = ManagedServer._(port, server);
    managed._running = true;
    managed._pump();
    return managed;
  }

  void _pump() {
    () async {
      // Drop the reference eagerly so we never touch a deleted server.
      final s = server;
      while (_running && s.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }();
  }

  // Simulate an abrupt server loss (crash / restart / partition).
  Future<void> crash() async {
    _running = false;
    // Let the pump loop observe the flag and exit before we free the server.
    await Future.delayed(const Duration(milliseconds: 60));
    server.shutdown();
    server.delete();
  }
}

/// Polls the synchronous client state until the session is ACTIVATED or the
/// [timeout] elapses. Returns true on activation.
Future<bool> _waitForActivated(Client client, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (client.state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return client.state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED;
}

/// Reads [nodeId], retrying transient failures within [timeout]. Used right
/// after a recovery where the very first attempt may still race the handshake.
Future<DynamicValue> _readWithRetry(Client client, NodeId nodeId, Duration timeout) async {
  final sw = Stopwatch()..start();
  Object? last;
  while (sw.elapsed < timeout) {
    try {
      return await client.read(nodeId).timeout(const Duration(seconds: 3));
    } catch (e) {
      last = e;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('read did not succeed within $timeout (last error: $last)');
}

Future<T> _retry<T>(Future<T> Function() action, Duration timeout) async {
  final sw = Stopwatch()..start();
  Object? last;
  while (sw.elapsed < timeout) {
    try {
      return await action();
    } catch (e) {
      last = e;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('action did not succeed within $timeout (last error: $last)');
}

void main() {
  test('client auto-recovers a read after a server crash/restart', () async {
    final port = await freeTcpPort();
    var srv = ManagedServer.start(port);
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    // Opt in to auto-reconnect. This owns the run_iterate pump for us.
    await client.keepConnected('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));

    // Baseline read works.
    expect((await client.read(boolNodeId)).value, true);

    // Simulate a crash and (after a real outage window) a restart on the same
    // port with the same variables.
    await srv.crash();
    await Future.delayed(const Duration(milliseconds: 500));
    srv = ManagedServer.start(port);

    // The client must recover ON ITS OWN — the test never calls connect() again.
    final recovered = await _waitForActivated(client, const Duration(seconds: 20));
    expect(recovered, isTrue, reason: 'session should return to ACTIVATED after restart');

    // And a read succeeds again.
    final value = await _readWithRetry(client, boolNodeId, const Duration(seconds: 10));
    expect(value.value, true);

    client.stopKeepConnected();
    await client.delete();
    srv._running = false;
    srv.server.shutdown();
    srv.server.delete();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a fresh subscription delivers data after recovery', () async {
    final port = await freeTcpPort();
    var srv = ManagedServer.start(port);
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    await client.keepConnected('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));

    // A subscription/monitored item works before the drop.
    final sub1 = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 20));
    final firstBefore = Completer<DynamicValue>();
    final before = client.monitor(intNodeId, sub1, samplingInterval: const Duration(milliseconds: 20)).listen((v) {
      if (!firstBefore.isCompleted) firstBefore.complete(v);
    }, onError: (_) {});
    expect((await firstBefore.future.timeout(const Duration(seconds: 10))).value, 1);
    await before.cancel();

    // Crash + restart.
    await srv.crash();
    await Future.delayed(const Duration(milliseconds: 500));
    srv = ManagedServer.start(port);

    final recovered = await _waitForActivated(client, const Duration(seconds: 20));
    expect(recovered, isTrue);

    // open62541 clears client-side subscriptions on a drop, so the old
    // subscription is gone — create a NEW one and confirm data flows again.
    final sub2 = await _retry(
      () => client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 20)),
      const Duration(seconds: 10),
    );
    final firstAfter = Completer<DynamicValue>();
    final after = client.monitor(intNodeId, sub2, samplingInterval: const Duration(milliseconds: 20)).listen((v) {
      if (!firstAfter.isCompleted) firstAfter.complete(v);
    }, onError: (_) {});
    expect((await firstAfter.future.timeout(const Duration(seconds: 15))).value, 1);
    await after.cancel();

    client.stopKeepConnected();
    await client.delete();
    srv._running = false;
    srv.server.shutdown();
    srv.server.delete();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'control: without opt-in the client gives up after a drop',
    () async {
      final port = await freeTcpPort();
      var srv = ManagedServer.start(port);
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

      // Classic stop-on-non-GOOD drive loop (like test/common.dart setupClient).
      var pumpAlive = true;
      () async {
        while (pumpAlive && client.runIterate(const Duration(milliseconds: 10))) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
        pumpAlive = false; // loop terminated because run_iterate returned non-GOOD
      }();
      await client.connect('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));
      expect((await client.read(boolNodeId)).value, true);

      // Crash + restart on the same port.
      await srv.crash();
      await Future.delayed(const Duration(seconds: 2));
      srv = ManagedServer.start(port);

      // Give the (defunct) client ample time; without opt-in it must NOT recover.
      final recovered = await _waitForActivated(client, const Duration(seconds: 8));
      expect(recovered, isFalse, reason: 'legacy stop-on-non-GOOD loop must not self-recover');
      expect(pumpAlive, isFalse, reason: 'the drive loop should have stopped on a non-GOOD status');

      pumpAlive = false;
      await client.delete();
      srv._running = false;
      srv.server.shutdown();
      srv.server.delete();
      // Local-only: this asserts a NEGATIVE (the legacy loop must NOT recover),
      // which depends on platform-specific disconnect-detection timing -- on some
      // runners (Windows) the client detects the drop late, keeps pumping, and
      // recovers, so the negative assertion is inherently flaky in CI. The
      // positive recovery tests above run in CI and cover the fix.
    },
    timeout: const Timeout(Duration(seconds: 90)),
    tags: 'integration',
  );
}
