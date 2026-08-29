import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// A Dart server that can be crashed and restarted on the SAME port, so a client
// pointed at that port sees the connection drop and then a server that is
// reachable again.
class _ManagedServer {
  _ManagedServer._(this.port, this.server);
  final int port;
  Server server;
  bool _running = false;

  static _ManagedServer start(int port) {
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    final managed = _ManagedServer._(port, server);
    managed._running = true;
    managed._pump();
    return managed;
  }

  void _pump() {
    () async {
      final s = server;
      while (_running && s.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 2));
      }
    }();
  }

  Future<void> stop() async {
    _running = false;
    await Future.delayed(const Duration(milliseconds: 40));
    server.shutdown();
    server.delete();
  }
}

int _randomPort() => Random().nextInt(10000) + 4840;

// Reproduce the frozen-session bug deterministically by single-stepping the
// client through its handshake and dropping the transport at a chosen state.
//
// [dropAt] is the session state whose window we want the drop to land in.
// Returns the session state the client ended at.
Future<SessionState> _connectDroppingAt(int port, SessionState dropAt) async {
  var srv = _ManagedServer.start(port);
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  try {
    // Fire the connect but drive run_iterate ourselves so we can observe every
    // intermediate state and act inside the handshake window. connect() awaits
    // ACTIVATED; we don't await it (it may never come pre-fix) and read the
    // live state directly.
    unawaited(client
        .connect('opc.tcp://localhost:$port')
        .catchError((Object _) {}));

    var dropped = false;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final ss = client.state.sessionState;
      if (ss == SessionState.UA_SESSIONSTATE_ACTIVATED) break;

      if (!dropped && ss == dropAt) {
        // Drop the transport with the handshake request in flight, then bring
        // the server back BEFORE we resume pumping, so open62541's own single
        // reconnect attempt finds it up. No keepConnected: recovery must come
        // from the client's connect state machine itself, which is exactly what
        // the fix restores.
        await srv.stop();
        srv = _ManagedServer.start(port);
        await Future.delayed(const Duration(milliseconds: 150));
        dropped = true;
      }

      client.runIterate(const Duration(milliseconds: 10));
      await Future.delayed(const Duration(milliseconds: 2));
    }

    expect(dropped, isTrue,
        reason: 'test did not observe the $dropAt window to arm the drop');
    return client.state.sessionState;
  } finally {
    try {
      client.disconnect();
    } catch (_) {}
    await client.delete();
    await srv.stop();
  }
}

void main() {
  // A transport drop while the session handshake is in flight
  // (CreateSession/ActivateSession sent but not yet answered) must not
  // permanently wedge the client. Without the fix the client latches a fatal
  // connectStatus (or clobbers its own CreateSession nonce with a duplicate
  // request) and never recovers -- it sits at channel OPEN / session CLOSED
  // while the connect state machine, which only advances on inbound bytes, is
  // never driven again. With the fix the client re-runs the handshake on the
  // reconnected channel and reaches ACTIVATED.
  //
  // Deterministic: the client is single-stepped so the drop reliably lands in
  // the target handshake window, and the server is restarted before pumping
  // resumes so the one automatic reconnect attempt has a server to reach.
  test(
    'a drop during CreateSession recovers to an activated session',
    () async {
      final end = await _connectDroppingAt(
          _randomPort(), SessionState.UA_SESSIONSTATE_CREATE_REQUESTED);
      expect(end, SessionState.UA_SESSIONSTATE_ACTIVATED,
          reason: 'client wedged after a drop during CreateSession');
    },
    timeout: const Timeout(Duration(seconds: 90)),
    tags: 'integration',
  );
}
