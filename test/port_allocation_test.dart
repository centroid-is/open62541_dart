// How the test servers get their ports.
//
// `dart test` runs the suites in parallel, as isolates of one process, and
// most of them start a server. The servers used to get a port from a probe
// that bound port 0, read the number, closed, and handed it to a Server that
// bound it moments later. That is a race: the OS can hand the same number out
// again in between (macOS picks ephemeral ports at random), and open62541's
// listen sockets are SO_REUSEPORT, so two servers given one port BOTH bind it
// and the kernel splits the connections between them: a client reaches a
// server from another suite that tears down mid-session (seen on CI as
// "Address already in use" followed by a 30 s connect timeout, and as
// BadSessionClosed from clients in unrelated tests).
//
// Now every test server is started with `port: 0` and holds the port from the
// moment the OS picks it; the number is read back through `Server.port`.
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Each server publishes who it is, so a client can tell which server a port
/// led it to.
final _idNodeId = NodeId.fromString(1, 'server.id');

void _identify(Server server, String id) {
  server.addVariableNode(_idNodeId, DynamicValue(value: id, typeId: NodeId.uastring, name: 'server.id'));
}

/// Upper bound on one connect or one read. Nothing in this file waits
/// unboundedly: a step that does not finish fails the test instead of
/// hanging it until the runner's timeout.
const _step = Duration(seconds: 10);

/// Connects to [port], reads the server's identity, and deletes the client
/// whatever happens, so a failed expectation never leaves a client pumping.
Future<String> _whoAnswers(int port) async {
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  var pumping = true;
  () async {
    while (pumping && client.runIterate(const Duration(milliseconds: 10))) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }();
  try {
    await client.connect('opc.tcp://127.0.0.1:$port').timeout(_step);
    return (await client.read(_idNodeId).timeout(_step)).value as String;
  } finally {
    pumping = false;
    await client.delete();
  }
}

/// Isolate body: starts [count] servers the way every suite does and reports
/// their ports, then keeps them running until told to stop.
void _serverIsolate(List<Object> args) {
  final reply = args[0] as SendPort;
  final tag = args[1] as String;
  final count = args[2] as int;

  final servers = <Server>[];
  final ids = <String>[];
  for (var i = 0; i < count; i++) {
    final server = setupServer();
    final id = '$tag/$i';
    _identify(server, id);
    servers.add(server);
    ids.add(id);
  }

  final control = ReceivePort();
  reply.send([
    control.sendPort,
    for (var i = 0; i < count; i++) [servers[i].port, ids[i]],
  ]);
  control.listen((_) {
    for (final server in servers) {
      server.shutdown();
      server.delete();
    }
    control.close();
  });
}

void main() {
  test('the port a test server reports is already bound: nothing can take it after the fact', () async {
    final server = setupServer();
    _identify(server, 'the one');
    addTearDown(() {
      server.shutdown();
      server.delete();
    });
    final port = server.port;
    expect(port, isNot(0));

    // The old probe reported a port it had just released. This one is held by
    // the server: a plain listen socket (no SO_REUSEPORT) cannot bind it.
    await expectLater(
      ServerSocket.bind(InternetAddress.anyIPv4, port),
      throwsA(isA<SocketException>()),
      reason: 'port $port must be in use by the server that reported it',
    );
    expect(await _whoAnswers(port), 'the one');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('servers started at the same time, across isolates, never share a port', () async {
    const isolates = 6;
    const serversPerIsolate = 4;

    // Every isolate's stop port is registered before anything can fail, so no
    // server outlives the test on any path (a timeout included).
    final controls = <SendPort>[];
    addTearDown(() {
      for (final control in controls) {
        control.send('stop');
      }
    });

    final replies = <Future<dynamic>>[];
    for (var i = 0; i < isolates; i++) {
      final reply = ReceivePort();
      replies.add(reply.first);
      await Isolate.spawn(_serverIsolate, <Object>[reply.sendPort, 'isolate$i', serversPerIsolate]);
    }
    final reported = <(int, String)>[];
    for (final message in await Future.wait(replies).timeout(_step)) {
      final parts = message as List;
      controls.add(parts[0] as SendPort);
      for (final entry in parts.skip(1)) {
        reported.add(((entry as List)[0] as int, entry[1] as String));
      }
    }

    final owners = <int, String>{};
    for (final (port, id) in reported) {
      expect(owners, isNot(contains(port)), reason: 'port $port handed to both ${owners[port]} and $id');
      owners[port] = id;
    }
    expect(owners, hasLength(isolates * serversPerIsolate));

    // Every port leads to the server that reported it.
    for (final MapEntry(key: port, value: id) in owners.entries) {
      expect(await _whoAnswers(port), id, reason: 'port $port');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'why a probed port was unsafe: two servers given one port both bind it and split the connections',
    () async {
      // What freeTcpPort() did: bind 0, read the number, close. Nothing holds
      // the port once it is reported.
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = probe.port;
      await probe.close();

      final servers = <Server>[];
      addTearDown(() {
        for (final server in servers) {
          server.shutdown();
          server.delete();
        }
      });
      Server startOn(int port, String id) {
        final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
        server.start();
        _identify(server, id);
        servers.add(server);
        () async {
          while (server.runIterate()) {
            await Future.delayed(const Duration(milliseconds: 20));
          }
        }();
        return server;
      }

      final owner = startOn(port, 'owner');
      expect(owner.port, port);
      // open62541 sets SO_REUSEPORT on its listen sockets, so the second bind
      // does not fail: the collision is silent.
      final squatter = startOn(port, 'squatter');
      expect(squatter.port, port);

      // Linux spreads the connections over both listeners by 4-tuple hash, so
      // a handful of connects reaches the squatter. Each connect is bounded by
      // [_step]; the loop ends at the first squatter answer.
      final answered = <String>{};
      for (var i = 0; i < 12 && !answered.contains('squatter'); i++) {
        answered.add(await _whoAnswers(port));
      }
      expect(answered, contains('squatter'), reason: 'connections to port $port reached $answered');
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: _onlyOnLinux,
  );
}

/// The squatter illustration is Linux-only. Two SO_REUSEPORT listeners on one
/// port behave differently per kernel: on the macOS CI runner this test
/// timed out (a connect to the doubly bound port never completed), and
/// Windows has no SO_REUSEPORT at all, where the collision is a bind failure
/// instead. The guarantees live in the first two tests, which run everywhere.
final _onlyOnLinux = Platform.isLinux
    ? null
    : 'kernel behaviour for two SO_REUSEPORT listeners differs; illustrated on Linux only';
