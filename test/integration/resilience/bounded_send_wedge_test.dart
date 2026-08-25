// RESILIENCE: the client-isolate "wedge" and the bounded-send fix that cures it.
//
// ROOT CAUSE (see hook/build.dart `_patchBoundedSend`): open62541's
// `TCP_sendWithConnection` (arch/posix/eventloop_posix_tcp.c) uses a
// non-blocking socket, but when the OS send buffer fills against a peer that
// keeps the connection open yet stops draining, `UA_send` returns EWOULDBLOCK
// and the code spins
//
//     do { poll_ret = UA_poll(&fd, 1, 100); ... } while(poll_ret <= 0);
//
// with NO overall deadline. POLLOUT never becomes ready, so the call — reached
// synchronously from `UA_Client_run_iterate` (and from any client request send)
// — never returns and freezes the whole client isolate. Our build hook patches
// that loop with a monotonic wall-clock deadline (default 5000 ms); on timeout
// it tears the connection down exactly like any other send error, so the send
// returns, `connectStatus` goes bad, and `keepConnected` reconnects.
//
// WHAT THIS TEST REPRODUCES
// A "non-draining but open" peer is reproduced with an in-process TCP relay that
// forwards both directions, then STOPS reading the client->server direction on
// command while holding the socket open (`StallRelay.stall()`). Driving write
// pressure through it fills the client's kernel send buffer and enters the
// blocking send path.
//   * With the patch (the shipped library): the blocking native send returns
//     within ~the deadline instead of hanging forever, and `keepConnected`
//     re-establishes the session on its own.
//   * Without the patch: the very same scenario hangs indefinitely (verified
//     out-of-band by building the library with the patch disabled — the write
//     burst below never returns and this test then fails on its timeout).
//
// WHY A RELAY AND NOT toxiproxy: on loopback, toxiproxy's `timeout` / `bandwidth`
// toxics keep *reading* the client's bytes into their own buffers, so the
// client's send buffer never fills and the blocking send path is never entered
// (confirmed empirically). A relay that genuinely stops reading is the faithful
// way to hold a socket open without draining it on a single host. The second
// test uses toxiproxy to confirm normal operation of the patched library.
//
// WHY PLAIN (not SignAndEncrypt): the wedge lives in the TCP layer *below* TLS
// and is independent of SecurityMode — SignAndEncrypt only matters upstream as
// the write pressure that fills the buffer in production. The Dart `Server` API
// currently exposes no server-side encryption binding, so an in-process
// SignAndEncrypt server is not constructible here; the plain channel exercises
// the identical `TCP_sendWithConnection` code path.
//
// These tests are timing-sensitive and need spare TCP ports (and toxiproxy for
// the second), so they are tagged `integration` (local-only, skipped by
// default).
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/toxiproxy.dart';

/// An in-process TCP relay that can freeze one connection's client->server
/// direction while keeping the socket open (a "non-draining but open" peer).
///
/// Before [stall] it forwards both directions normally. After [stall], the
/// client->server subscription of the *currently open* connection is paused, so
/// bytes the client writes are no longer read and its kernel send buffer fills.
/// A subsequent fresh connection (what `keepConnected` opens when it reconnects)
/// gets its own subscription and drains normally — mirroring how a fresh connect
/// to a still-reachable server recovers after a half-open socket died.
class StallRelay {
  StallRelay._(this._listen, this._upstreamPort);

  final ServerSocket _listen;
  final int _upstreamPort;
  final List<Socket> _sockets = [];
  StreamSubscription<Uint8List>? _latestClientSub;

  int get port => _listen.port;
  String get url => 'opc.tcp://127.0.0.1:$port';

  static Future<StallRelay> start(int upstreamPort) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = StallRelay._(s, upstreamPort);
    s.listen(relay._onClient);
    return relay;
  }

  Future<void> _onClient(Socket client) async {
    final server = await Socket.connect(InternetAddress.loopbackIPv4, _upstreamPort);
    _sockets
      ..add(client)
      ..add(server);
    // server -> client always flows.
    server.listen(client.add, onError: (_) {}, onDone: client.destroy);
    // client -> server; this is the direction we can freeze.
    _latestClientSub = client.listen(server.add, onError: (_) {}, onDone: server.destroy);
  }

  /// Stops draining the currently-open connection's client->server direction.
  void stall() => _latestClientSub?.pause();

  Future<void> stop() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _listen.close();
  }
}

/// A plain in-process OPC UA server with one string variable, plus a stop hook.
class _TestServer {
  _TestServer(this.server, this.port, this.node, this._stop);
  final Server server;
  final int port;
  final NodeId node;
  final Future<void> Function() _stop;
  Future<void> stop() => _stop();
}

Future<_TestServer> _startServer() async {
  final port = await freePort();
  final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
  server.start();
  final node = NodeId.fromString(1, 'big');
  server.addVariableNode(node, DynamicValue(value: 'x' * 1024, typeId: NodeId.uastring, name: 'big'));
  var running = true;
  unawaited(() async {
    while (running && server.runIterate()) {
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }());
  return _TestServer(server, port, node, () async => running = false);
}

void main() {
  test('a stalled send is bounded by the deadline and keepConnected recovers', () async {
    final srv = await _startServer();
    final relay = await StallRelay.start(srv.port);
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    var reconnects = 0;
    final recSub = client.reconnectStream.listen((_) => reconnects++);

    try {
      await client.keepConnected(relay.url).timeout(const Duration(seconds: 20));
      expect(
        client.state.sessionState,
        SessionState.UA_SESSIONSTATE_ACTIVATED,
        reason: 'precondition: session should be active before stalling',
      );

      // Freeze the live connection, then push enough write pressure to fill the
      // client's kernel send buffer and enter the blocking native send path.
      relay.stall();
      final payload = DynamicValue(value: 'y' * (32 * 1024), typeId: NodeId.uastring, name: 'big');
      final burst = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        unawaited(client.write(srv.node, payload).catchError((_) {}));
      }
      burst.stop();

      // The blocking native send must have actually been entered (a full buffer
      // takes seconds to hit the deadline; a non-blocking send would return in
      // milliseconds) AND must have been bounded (an unpatched library never
      // returns here — this test would then hang and fail on its timeout). The
      // window brackets the 5000 ms compile-time deadline with generous slack
      // for CI jitter and the burst overhead.
      expect(
        burst.elapsed,
        greaterThan(const Duration(seconds: 3)),
        reason:
            'send did not block: the buffer never filled (relay drained?) — '
            'the wedge path was not exercised. burst=${burst.elapsed}',
      );
      expect(
        burst.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason:
            'send was NOT bounded: the bounded-send deadline did not fire '
            '(is the patch present in the linked library?). burst=${burst.elapsed}',
      );

      // keepConnected must re-establish the session on its own, on a fresh
      // socket, with no manual reconnect and no isolate involvement.
      final recovered = await _waitUntil(
        () async => reconnects > 0 && await _canRead(client, srv.node),
        timeout: const Duration(seconds: 30),
      );
      expect(
        recovered,
        isTrue,
        reason:
            'keepConnected did not auto-recover after the bounded send. '
            'reconnects=$reconnects state=${client.state}',
      );
    } finally {
      await recSub.cancel();
      client.stopKeepConnected();
      await client.delete();
      await relay.stop();
      await srv.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'normal operation is unaffected through a (real toxiproxy) proxy',
    () async {
      final srv = await _startServer();
      final tp = await Toxiproxy.start();
      final proxy = await tp.createProxy(upstreamHost: '127.0.0.1', upstreamPort: srv.port);
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      var running = true;
      unawaited(() async {
        while (running && client.runIterate(const Duration(milliseconds: 10))) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }());

      try {
        await client.connect(proxy.url).timeout(const Duration(seconds: 20));
        // A round-trip write + read succeeds normally with the patched library.
        await client
            .write(srv.node, DynamicValue(value: 'hello', typeId: NodeId.uastring, name: 'big'))
            .timeout(const Duration(seconds: 10));
        final v = await client.read(srv.node).timeout(const Duration(seconds: 10));
        expect(v.value, 'hello', reason: 'patched library must behave normally through a proxy');
      } finally {
        running = false;
        await client.delete();
        await tp.stop();
        await srv.stop();
      }
    },
    skip: toxiproxyAvailable() ? false : 'run test/integration/setup_local.sh first',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<bool> _canRead(Client client, NodeId node) async {
  try {
    await client.read(node).timeout(const Duration(seconds: 5));
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _waitUntil(Future<bool> Function() cond, {required Duration timeout}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await cond()) return true;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  return false;
}
