import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

// A Dart server that runs its pump on the isolate; kept up for the whole test.
class _Server {
  _Server._(this.port, this.server);
  final int port;
  final Server server;
  bool _running = false;

  static _Server start(int port) {
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    final managed = _Server._(port, server);
    managed._running = true;
    () async {
      final s = server;
      while (managed._running && s.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 2));
      }
    }();
    return managed;
  }

  void stop() {
    _running = false;
    server.shutdown();
    server.delete();
  }
}

// An in-process TCP proxy the test fully controls. The client connects to the
// proxy; the proxy forwards to the real server. [cut] severs every live
// connection AND stops forwarding in both directions first, so a response the
// server has already put on the wire never reaches the client -- which is what
// makes a mid-handshake drop deterministic (a same-process server otherwise
// answers before the drop can be interposed). The listener stays open, so the
// client's own reconnect goes straight back to the still-alive server.
class _Conn {
  _Conn(this.client, this.upstream);
  final Socket client;
  final Socket upstream;
  var active = true;

  void kill() {
    active = false;
    client.destroy();
    upstream.destroy();
  }
}

class _Proxy {
  _Proxy._(this._listener, this.targetPort);
  final ServerSocket _listener;
  final int targetPort;
  final List<_Conn> _conns = [];

  int get port => _listener.port;

  static Future<_Proxy> start(int targetPort) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _Proxy._(listener, targetPort);
    listener.listen(proxy._onClient);
    return proxy;
  }

  static void _pipe(_Conn conn, Socket from, Socket to) {
    from.listen(
      (d) {
        if (!conn.active) return;
        try {
          to.add(d);
        } catch (_) {
          conn.kill();
        }
      },
      onError: (_) => conn.kill(),
      onDone: () => conn.kill(),
      cancelOnError: true,
    );
  }

  Future<void> _onClient(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    // A destroyed socket surfaces its aborted write as an error on `done`
    // (Windows errno 10053), asynchronously and not at the add() call site.
    // Swallow it -- tearing the pair down mid-write is the whole point.
    client.done.catchError((_) => client);
    upstream.done.catchError((_) => upstream);
    final conn = _Conn(client, upstream);
    _conns.add(conn);
    _pipe(conn, client, upstream);
    _pipe(conn, upstream, client);
  }

  // Sever every live connection, dropping any bytes still in flight, so a
  // response the server already sent never reaches the client. The listener
  // stays open, so the client's own reconnect gets a fresh pair to the still-
  // alive server.
  void cut() {
    for (final c in _conns) {
      c.kill();
    }
    _conns.clear();
  }

  Future<void> dispose() async {
    cut();
    await _listener.close();
  }
}

// Single-step a fresh client through its handshake against [proxyPort]; when the
// session first reaches [dropAt], sever the connection with [proxy.cut] (server
// stays up) and then let the client recover on its own. Returns the final
// session state.
Future<SessionState> _connectDroppingAt(_Proxy proxy, SessionState dropAt) async {
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  try {
    // connect() awaits ACTIVATED; drive run_iterate ourselves and don't await
    // it (pre-fix it may never complete) -- read the live state directly.
    unawaited(client.connect('opc.tcp://127.0.0.1:${proxy.port}').catchError((_) {}));

    var dropped = false;
    final seen = <SessionState>{};
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final ss = client.state.sessionState;
      seen.add(ss);
      if (ss == SessionState.UA_SESSIONSTATE_ACTIVATED) break;
      if (!dropped && ss == dropAt) {
        proxy.cut();
        dropped = true;
      }
      client.runIterate(const Duration(milliseconds: 5));
      await Future.delayed(const Duration(milliseconds: 1));
    }

    expect(
      dropped,
      isTrue,
      reason:
          'never observed $dropAt to arm the drop; '
          'states seen: ${seen.map((s) => s.name).join(",")}; '
          'final channel=${client.state.channelState.name}',
    );
    return client.state.sessionState;
  } finally {
    try {
      client.disconnect();
    } catch (_) {}
    await client.delete();
  }
}

void main() {
  // A transport drop while the session handshake is in flight
  // (CreateSession / ActivateSession sent, response not yet processed) must not
  // permanently wedge the client. Without the fix the client latches a fatal
  // connectStatus and never recovers -- it sits at channel OPEN / session
  // CLOSED while the connect state machine, which only advances on inbound
  // bytes, is never driven again. With the fix the client re-runs the handshake
  // on the reconnected channel and reaches ACTIVATED.
  late _Server server;
  late _Proxy proxy;

  setUp(() async {
    server = _Server.start(await freeTcpPort());
    proxy = await _Proxy.start(server.port);
  });
  tearDown(() async {
    await proxy.dispose();
    server.stop();
  });

  test(
    'a drop during CreateSession recovers to an activated session',
    () async {
      final end = await _connectDroppingAt(proxy, SessionState.UA_SESSIONSTATE_CREATE_REQUESTED);
      expect(end, SessionState.UA_SESSIONSTATE_ACTIVATED, reason: 'client wedged after a drop during CreateSession');
    },
    timeout: const Timeout(Duration(seconds: 90)),
    tags: 'integration',
  );

  test(
    'a drop during ActivateSession recovers to an activated session',
    () async {
      final end = await _connectDroppingAt(proxy, SessionState.UA_SESSIONSTATE_ACTIVATE_REQUESTED);
      expect(end, SessionState.UA_SESSIONSTATE_ACTIVATED, reason: 'client wedged after a drop during ActivateSession');
    },
    timeout: const Timeout(Duration(seconds: 90)),
    tags: 'integration',
  );
}
