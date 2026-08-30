import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

// ClientIsolate mirror of auto_reconnect_test.dart. The isolate client is the
// path long-running applications actually use, and it is also the path where
// a dead session is the most invisible: the caller's runIterate() future only
// completes when native run_iterate returns non-GOOD, so a session that dies
// while iterate keeps reporting GOOD parks the caller forever. keepConnected
// moves the supervisor (and the pump) inside the isolate so recovery does not
// depend on any error ever surfacing to the caller.

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

  Future<void> stop() async {
    _running = false;
    await Future.delayed(const Duration(milliseconds: 60));
    server.shutdown();
    server.delete();
  }
}

/// Polls the isolate client state until the session is ACTIVATED or the
/// [timeout] elapses. Returns true on activation.
Future<bool> _waitForActivated(ClientIsolate client, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final state = await client.state;
    if (state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return (await client.state).sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED;
}

/// Reads [nodeId], retrying transient failures within [timeout]. Used right
/// after a recovery where the very first attempt may still race the handshake.
Future<DynamicValue> _readWithRetry(ClientIsolate client, NodeId nodeId, Duration timeout) async {
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
  test('isolate client auto-recovers a read after a server crash/restart', () async {
    final port = await freeTcpPort();
    var srv = ManagedServer.start(port);
    final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    // Opt in to auto-reconnect. The supervisor and pump live in the isolate.
    await client.keepConnected('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));

    // Baseline read works.
    expect((await client.read(boolNodeId)).value, true);

    // Simulate a crash and (after a real outage window) a restart on the same
    // port with the same variables.
    await srv.crash();
    await Future.delayed(const Duration(milliseconds: 500));
    srv = ManagedServer.start(port);

    // The client must recover ON ITS OWN — the test never calls connect() or
    // runIterate(): no error ever surfaces to this side of the isolate.
    final recovered = await _waitForActivated(client, const Duration(seconds: 20));
    expect(recovered, isTrue, reason: 'session should return to ACTIVATED after restart');

    // And a read succeeds again.
    final value = await _readWithRetry(client, boolNodeId, const Duration(seconds: 10));
    expect(value.value, true);

    await client.stopKeepConnected();
    await client.delete();
    await srv.stop();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('reconnectStream fires and a fresh subscription delivers data after recovery', () async {
    final port = await freeTcpPort();
    var srv = ManagedServer.start(port);
    final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    final reconnected = Completer<void>();
    final reconnectSub = client.reconnectStream.listen((_) {
      if (!reconnected.isCompleted) reconnected.complete();
    });

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

    // The recovery must be announced — this is what applications hook to
    // re-create their subscriptions.
    await reconnected.future.timeout(const Duration(seconds: 10));

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

    await reconnectSub.cancel();
    await client.stopKeepConnected();
    await client.delete();
    await srv.stop();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
