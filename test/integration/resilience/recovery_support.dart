// Shared helpers for the RESILIENCE category.
//
// KEY FINDING (see resilience findings): open62541 does NOT keep trying to
// reconnect once the peer becomes unreachable. On an unexpected drop it makes a
// single reconnect attempt; if that attempt fails (server briefly gone during a
// crash/restart/partition) the client's `connectStatus` is set to a bad code
// (BADCONNECTIONREJECTED) and `connectActivity()` then bails out early forever —
// `connectStatus` is only reset by an explicit `connect()` call. On top of that,
// both the harness `connectClient` pump (`while (runIterate()) ...`) and the
// isolate's internal iterate loop TERMINATE the moment `runIterate()` returns a
// non-GOOD status, so a `DrivenClient` stops being pumped at all after a drop.
//
// Consequently a real HMI must drive its own recovery: keep an event loop
// running that does NOT stop on a bad status, and call `connect()` again until
// the session re-activates. [ResilientClient] encapsulates exactly that so the
// recovery tests can assert genuine reconnection rather than working around the
// harness. It lives here (not in harness/) because the harness is frozen.

import 'dart:async';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart' show ClientKind;

export '../harness/dart_client.dart' show ClientKind, clientTypes;

bool isActivated(ClientState s) => s.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED;

bool channelOpen(ClientState s) => s.channelState == SecureChannelState.UA_SECURECHANNELSTATE_OPEN;

/// A client whose event loop is pumped by a loop that never gives up on a bad
/// status, plus an application-driven [reconnect]. Works for both client kinds.
abstract class ResilientClient {
  ClientApi get client;
  ClientKind get kind;

  /// The current client state (synchronous snapshot from the C client).
  Future<ClientState> currentState();

  Stream<ClientState> get stateStream => client.stateStream;

  /// Retries `connect(url)` until the session activates or [timeout] elapses.
  /// Re-establishes the event-loop pump first (the isolate loop dies on drop).
  Future<void> reconnect(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    Duration retry = const Duration(milliseconds: 300),
  });

  Future<void> dispose();

  static Future<ResilientClient> connect(
    String url, {
    ClientKind kind = ClientKind.direct,
    LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL,
    Duration connectTimeout = const Duration(seconds: 20),
  }) async {
    switch (kind) {
      case ClientKind.direct:
        final c = Client(logLevel: logLevel);
        final rc = _ResilientDirect(c);
        rc._startPump();
        await c.connect(url).timeout(connectTimeout);
        return rc;
      case ClientKind.isolate:
        final c = await ClientIsolate.create(logLevel: logLevel, iterateInterval: const Duration(milliseconds: 10));
        final rc = _ResilientIsolate(c);
        rc._startPump();
        await c.connect(url).timeout(connectTimeout);
        return rc;
    }
  }
}

class _ResilientDirect extends ResilientClient {
  _ResilientDirect(this._client);
  final Client _client;
  bool _running = true;

  @override
  ClientApi get client => _client;
  @override
  ClientKind get kind => ClientKind.direct;

  void _startPump() {
    unawaited(() async {
      while (_running) {
        // Deliberately ignore the return value: unlike the harness pump we do
        // not stop when a reconnect attempt reports a bad status.
        _client.runIterate(const Duration(milliseconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }());
  }

  @override
  Future<ClientState> currentState() async => _client.state;

  @override
  Future<void> reconnect(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    Duration retry = const Duration(milliseconds: 300),
  }) async {
    final sw = Stopwatch()..start();
    Object? last;
    while (sw.elapsed < timeout) {
      try {
        await _client.connect(url).timeout(const Duration(seconds: 3));
        return;
      } catch (e) {
        last = e;
        await Future<void>.delayed(retry);
      }
    }
    throw TimeoutException('reconnect to $url did not activate within $timeout (last: $last)');
  }

  @override
  Future<void> dispose() async {
    _running = false;
    await _client.delete();
  }
}

class _ResilientIsolate extends ResilientClient {
  _ResilientIsolate(this._client);
  final ClientIsolate _client;

  @override
  ClientApi get client => _client;
  @override
  ClientKind get kind => ClientKind.isolate;

  void _startPump() {
    // The isolate iterate loop terminates on a non-GOOD status; swallow the
    // resulting error and simply (re)start it.
    unawaited(_client.runIterate(duration: const Duration(milliseconds: 10)).catchError((_) {}));
  }

  @override
  Future<ClientState> currentState() => _client.state;

  @override
  Future<void> reconnect(
    String url, {
    Duration timeout = const Duration(seconds: 25),
    Duration retry = const Duration(milliseconds: 300),
  }) async {
    final sw = Stopwatch()..start();
    Object? last;
    while (sw.elapsed < timeout) {
      try {
        // Re-arm the iterate loop each attempt (it stopped when the drop made
        // runIterate() return non-GOOD).
        _startPump();
        await _client.connect(url).timeout(const Duration(seconds: 3));
        return;
      } catch (e) {
        last = e;
        await Future<void>.delayed(retry);
      }
    }
    throw TimeoutException('reconnect to $url did not activate within $timeout (last: $last)');
  }

  @override
  Future<void> dispose() async {
    await _client.delete();
  }
}
