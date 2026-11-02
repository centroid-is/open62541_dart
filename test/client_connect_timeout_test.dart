// connect() is bounded (issue #138): a peer that accepts the TCP connection
// and never answers, or a server that opens the secure channel and never
// activates the session, is a TimeoutException after the timeout, on both
// clients, and the client can still be deleted or connect again.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

/// A peer that accepts connections and never answers or closes them while
/// [blackHole] is set, and forwards new ones to [targetPort] once it is
/// cleared. Unlike a stalled [TcpProxy], the server never sees the held
/// connections, so its own idle timeout cannot end them.
class _BlackHole {
  _BlackHole._(this._listener, this.targetPort);

  final ServerSocket _listener;
  final int targetPort;
  final _sockets = <Socket>[];
  bool blackHole = true;

  int get port => _listener.port;

  static Future<_BlackHole> start(int targetPort) async {
    final peer = _BlackHole._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), targetPort);
    peer._listener.listen(peer._accept);
    addTearDown(peer._close);
    return peer;
  }

  Future<void> _accept(Socket client) async {
    client.done.ignore();
    _sockets.add(client);
    if (blackHole) {
      client.listen((_) {}, onError: (_) {});
      return;
    }
    final upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    upstream.done.ignore();
    _sockets.add(upstream);
    client.listen(upstream.add, onDone: upstream.destroy, onError: (_) => upstream.destroy());
    upstream.listen(client.add, onDone: client.destroy, onError: (_) => client.destroy());
  }

  Future<void> _close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _listener.close();
  }
}

const _activateSessionResponse = 470;

/// [message] with the request id of an ActivateSessionResponse replaced, so
/// the client never matches it to its request: the session is never activated.
Uint8List _unanswerActivateSession(Uint8List message) {
  if (message.length < 28 || String.fromCharCodes(message.sublist(0, 3)) != 'MSG') return message;
  if (message[24] != 0x01 || message[25] != 0x00) return message;
  if (ByteData.sublistView(message).getUint16(26, Endian.little) != _activateSessionResponse) return message;
  final out = Uint8List.fromList(message);
  ByteData.sublistView(out).setUint32(20, 0x7fffffff, Endian.little);
  return out;
}

Future<ClientApi> _newClient(String clientType) async {
  switch (clientType) {
    case 'isolate':
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      // runIterate fails once the client is deleted.
      unawaited(client.runIterate().catchError((_) {}));
      return client;
    case 'direct':
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      () async {
        while (client.runIterate(const Duration(milliseconds: 10))) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }();
      return client;
    default:
      throw ArgumentError(clientType);
  }
}

Future<void> _connect(ClientApi client, String url, Duration timeout) => switch (client) {
  Client c => c.connect(url, timeout: timeout),
  ClientIsolate c => c.connect(url, timeout: timeout),
  _ => throw ArgumentError(client),
};

/// Connects again after a timed-out attempt; the isolate client's iterate
/// loop stopped on the abandoned attempt, so it is started again.
Future<void> _reconnect(ClientApi client, String url) async {
  await _connect(client, url, const Duration(seconds: 10));
  if (client is ClientIsolate) unawaited(client.runIterate().catchError((_) {}));
}

/// Server_ServerStatus_State, which every server has.
final _serverState = NodeId.fromNumeric(0, 2259);

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: connect timeout', () {
      late Server server;

      setUp(() => server = setupServer());
      tearDown(() {
        server.shutdown();
        server.delete();
      });

      Future<void> expectTimeout(ClientApi client, String url) async {
        final sw = Stopwatch()..start();
        await expectLater(_connect(client, url, const Duration(seconds: 2)), throwsA(isA<TimeoutException>()));
        expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      }

      test('a peer that never answers is a TimeoutException; the client connects afterwards', () async {
        final peer = await _BlackHole.start(server.port);
        final client = await _newClient(clientType);
        try {
          await expectTimeout(client, 'opc.tcp://127.0.0.1:${peer.port}');
          peer.blackHole = false;
          await _reconnect(client, 'opc.tcp://127.0.0.1:${peer.port}');
          expect((await client.read(_serverState)).value, isNotNull);
        } finally {
          await client.delete();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a session that is never activated is a TimeoutException; the client connects afterwards', () async {
        final proxy = await DataValueRewritingProxy.start(server.port);
        addTearDown(proxy.close);
        proxy.rewriteMessage = _unanswerActivateSession;
        final client = await _newClient(clientType);
        try {
          await expectTimeout(client, 'opc.tcp://127.0.0.1:${proxy.port}');
          proxy.rewriteMessage = null;
          await _reconnect(client, 'opc.tcp://127.0.0.1:${proxy.port}');
          expect((await client.read(_serverState)).value, isNotNull);
        } finally {
          await client.delete();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a timed-out client deletes cleanly', () async {
        final peer = await _BlackHole.start(server.port);
        final client = await _newClient(clientType);
        await expectTimeout(client, 'opc.tcp://127.0.0.1:${peer.port}');
        await client.delete().timeout(const Duration(seconds: 10));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('keepConnected abandons an attempt the peer never answers and retries', () async {
        final peer = await _BlackHole.start(server.port);
        final client = await _newClient(clientType);
        try {
          final url = 'opc.tcp://127.0.0.1:${peer.port}';
          const connectTimeout = Duration(seconds: 1);
          final activated = switch (client) {
            Client c => c.keepConnected(url, connectTimeout: connectTimeout),
            ClientIsolate c => c.keepConnected(url, connectTimeout: connectTimeout),
            _ => throw ArgumentError(client),
          };
          // The first attempt is held; only a new one gets through.
          await Future.delayed(const Duration(milliseconds: 500));
          peer.blackHole = false;
          await activated.timeout(const Duration(seconds: 15));
          expect((await client.read(_serverState)).value, isNotNull);
        } finally {
          await client.delete();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  }
}
