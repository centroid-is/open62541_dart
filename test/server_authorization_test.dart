// Per-user authorization (`Server(authorization: ServerAuthorization(...))`):
// the user access level, method execution and browsing decided per session,
// within what the node itself allows, never for the host's own calls.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'client_trust_list_test.dart' show refusedWith;
import 'common.dart';
import 'heap_growth.dart';
import 'server_security_test.dart' show Running, clientOf;

const _fatal = LogLevel.UA_LOGLEVEL_FATAL;

final writable = NodeId.fromString(1, 'authz.writable');
final readOnly = NodeId.fromString(1, 'authz.readonly');
final throwing = NodeId.fromString(1, 'authz.throwing');
final hidden = NodeId.fromString(1, 'authz.hidden');
final allowedMethod = NodeId.fromString(1, 'authz.allowed');
final deniedMethod = NodeId.fromString(1, 'authz.denied');
final objectsFolder = NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);

String? userOf(MethodSessionInfo session) => switch (session.identity) {
  UsernameSessionIdentity(:final username) => username,
  _ => null,
};

/// Alice may write [writable], Bob only read it, anyone else nothing. The
/// hook tries to grant write on [readOnly], throws for [throwing].
AccessLevelMask? accessLevel(MethodSessionInfo session, NodeId node) {
  if (node == throwing) throw StateError('a bug in the hook');
  if (node == readOnly) return const AccessLevelMask(read: true, write: true);
  if (node != writable) return null;
  return switch (userOf(session)) {
    'alice' => null,
    'bob' => const AccessLevelMask(read: true),
    _ => const AccessLevelMask(),
  };
}

/// What [future] failed with, `null` if it did not.
Future<Object?> errorOf(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

void addNodes(Server server) {
  for (final node in [writable, throwing, hidden]) {
    server.addVariableNode(
      node,
      DynamicValue(value: 1, typeId: NodeId.int32, name: node.string),
      accessLevel: readWrite,
    );
  }
  server.addVariableNode(readOnly, DynamicValue(value: 1, typeId: NodeId.int32, name: readOnly.string));
  for (final method in [allowedMethod, deniedMethod]) {
    server.addMethodNode(
      method,
      callback: (inputs, session) async => [DynamicValue(value: 42, typeId: NodeId.int32)],
      outputArguments: [Argument(name: 'answer', dataType: NodeId.int32)],
    );
  }
}

final allowing = ServerAuthorization(
  userAccessLevel: accessLevel,
  userExecutable: (session, method, object) => true,
  allowBrowse: (session, node) => true,
);

/// An isolate's entry: a server with [allowing] for alice, pumped until
/// `null` arrives on the port it sends to [ready] with its own port; a
/// [SendPort] sent there is answered with the open channel count.
Future<void> serveWithAuthorization(SendPort ready) async {
  final server = Server(
    port: 0,
    logLevel: _fatal,
    users: {'alice': 'a'},
    allowUnencryptedPassword: true,
    authorization: allowing,
    // The cycles open and close channels faster than a loaded machine may
    // reap them; the caps are not what this test is about.
    limits: ServerLimits.unlimited,
  );
  addNodes(server);
  server.start();
  final control = ReceivePort();
  var serving = true;
  control.listen((message) {
    if (message is SendPort) {
      message.send(server.statistics.currentChannelCount);
    } else {
      serving = false;
    }
  });
  ready.send((server.port, control.sendPort));
  while (serving) {
    server.runIterate();
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  control.close();
  server.shutdown();
  server.delete();
}

void main() {
  group('a server with users and an authorization:', () {
    late Running running;
    final executableAsked = <(String?, NodeId, NodeId?)>[];

    setUpAll(() {
      running = Running(
        Server(
          port: 0,
          logLevel: _fatal,
          users: {'alice': 'a', 'bob': 'b'},
          allowUnencryptedPassword: true,
          authorization: ServerAuthorization(
            userAccessLevel: accessLevel,
            userExecutable: (session, method, object) {
              executableAsked.add((userOf(session), method, object));
              return method != deniedMethod;
            },
            allowBrowse: (session, node) => node != hidden,
          ),
        ),
      );
      addNodes(running.server);
    });
    tearDownAll(() => running.stop());

    Future<ClientApi> login(String clientType, String? user) async {
      final client = await clientOf(
        clientType,
        username: user,
        password: user == null ? null : user[0],
        allowUnencryptedPassword: true,
      );
      await client.connect(running.url);
      return client;
    }

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('alice writes the node, bob is refused, both read it', () async {
          final alice = await login(clientType, 'alice');
          final bob = await login(clientType, 'bob');
          await alice.write(writable, DynamicValue(value: 7, typeId: NodeId.int32));
          expect((await bob.read(writable)).asInt, 7);
          await expectLater(
            bob.write(writable, DynamicValue(value: 8, typeId: NodeId.int32)),
            refusedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED),
          );
          expect((await alice.read(writable)).asInt, 7);
        });

        test('the hook cannot grant: a read-only node stays read-only', () async {
          final alice = await login(clientType, 'alice');
          await expectLater(
            alice.write(readOnly, DynamicValue(value: 2, typeId: NodeId.int32)),
            refusedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED),
          );
        });

        test('an anonymous session gets what the hook says: nothing', () async {
          final anonymous = await login(clientType, null);
          final value = await anonymous.readValue(writable);
          expect(value.statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
          // The other nodes are left to their own access level.
          expect((await anonymous.read(readOnly)).asInt, 1);
        });

        test('a method the hook refuses is BadUserAccessDenied, the other is called', () async {
          final bob = await login(clientType, 'bob');
          executableAsked.clear();
          expect((await bob.call(objectsFolder, allowedMethod, [])).single.asInt, 42);
          expect('${await errorOf(bob.call(objectsFolder, deniedMethod, []))}', contains('BadUserAccessDenied'));
          expect(executableAsked, [('bob', allowedMethod, objectsFolder), ('bob', deniedMethod, objectsFolder)]);
        });

        test('a node the hook hides is neither browsed nor described, its value stays readable', () async {
          final bob = await login(clientType, 'bob');
          expect('${await errorOf(bob.browse(hidden))}', contains('BadUserAccessDenied'));
          // Every attribute but Value (and RolePermissions) is refused
          // (src/server/ua_services_attribute.c, ReadWithNodeMaybeAsync);
          // read() asks for DisplayName, Description and DataType too.
          expect('${await errorOf(bob.read(hidden))}', contains('BadUserAccessDenied'));
          expect((await bob.readValue(hidden)).value.asInt, 1);
          // open62541 asks allowBrowseNode only for the node a Browse starts
          // from (src/server/ua_services_view.c): the parent still lists it.
          final children = await bob.browse(objectsFolder);
          expect(children.map((c) => c.nodeId), contains(hidden));
        });

        test('a hook that throws denies, and the server goes on', () async {
          final alice = await login(clientType, 'alice');
          for (var i = 0; i < 3; i++) {
            final value = await alice.readValue(throwing);
            expect(value.statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
          }
          expect((await alice.read(writable)).asInt, isNotNull);
        });
      });
    }

    test('the host is never asked: it reads and writes what no client may', () {
      final server = running.server;
      server.write(throwing, DynamicValue(value: 5, typeId: NodeId.int32));
      expect(server.read(throwing).asInt, 5);
      server.write(readOnly, DynamicValue(value: 6, typeId: NodeId.int32));
      expect(server.read(readOnly).asInt, 6);
    });
  });

  test('a hook is cheap: the identity is resolved once per session, not per read', () async {
    // Server-side cost of userAccessLevel: the same 10 000-node Read from a
    // server without and one with a trivial hook, taken in turns. The hook
    // adds about 0.1 us a read (the FFI trampoline, a map lookup, the NodeId
    // decode); resolving the session on every call adds about 3 us.
    final servers = [
      Server(port: 0, logLevel: _fatal),
      Server(
        port: 0,
        logLevel: _fatal,
        authorization: ServerAuthorization(userAccessLevel: (session, node) => null),
      ),
    ];
    final clients = [for (final _ in servers) Client(logLevel: _fatal)];
    for (final server in servers) {
      server.addVariableNode(writable, DynamicValue(value: 1, typeId: NodeId.int32, name: 'w'));
      server.start();
    }
    Future<T> pump<T>(Future<T> future) async {
      var done = false;
      future.whenComplete(() => done = true).ignore();
      while (!done) {
        for (final server in servers) {
          server.runIterate();
        }
        for (final client in clients) {
          client.runIterate(Duration.zero);
        }
        await Future<void>.delayed(Duration.zero);
      }
      return future;
    }

    for (var i = 0; i < servers.length; i++) {
      await pump(clients[i].connect('opc.tcp://127.0.0.1:${servers[i].port}'));
    }
    const reads = 10000;
    final request = {writable: List.filled(reads, AttributeId.UA_ATTRIBUTEID_VALUE)};
    final times = [<int>[], <int>[]];
    for (var round = 0; round < 25; round++) {
      for (var i = 0; i < servers.length; i++) {
        final watch = Stopwatch()..start();
        await pump(clients[i].readAttribute(request));
        times[i].add(watch.elapsedMicroseconds);
      }
    }
    for (final server in servers) {
      server.shutdown();
    }
    for (var i = 0; i < 10; i++) {
      for (final client in clients) {
        client.runIterate(Duration.zero);
      }
    }
    for (final client in clients) {
      await client.delete();
    }
    for (final server in servers) {
      server.delete();
    }

    int median(List<int> list) => (list..sort())[list.length ~/ 2];
    final without = median(times[0]);
    final withHook = median(times[1]);
    final perRead = (withHook - without) / reads;
    printOnFailure('$reads reads: $without us without, $withHook us with the hook, $perRead us a read');
    expect(perRead, lessThan(1.5));
  });

  group('the hooks and the session cache across a server\'s life:', () {
    test('connect, read and disconnect cycles leave nothing on the C heap', () async {
      // The server runs on its own isolate: a client's delete() waits for
      // the CloseSession answer, which a server pumped by this isolate
      // could not give meanwhile. The heap is the process's either way.
      final ready = ReceivePort();
      final exited = ReceivePort();
      await Isolate.spawn(serveWithAuthorization, ready.sendPort, onExit: exited.sendPort);
      final (port, control) = await ready.first as (int, SendPort);
      addTearDown(() async {
        control.send(null);
        await exited.first;
      });
      final replies = ReceivePort();
      addTearDown(replies.close);
      final channelCounts = StreamIterator(replies);
      Future<void> untilChannelsClosed() async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (true) {
          control.send(replies.sendPort);
          await channelCounts.moveNext();
          if (channelCounts.current == 0) return;
          if (DateTime.now().isAfter(deadline)) fail('the server kept ${channelCounts.current} channels open');
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      await expectNoHeapGrowth(
        () async {
          final client = Client(logLevel: _fatal, username: 'alice', password: 'a', allowUnencryptedPassword: true);
          final pump = () async {
            while (client.runIterate(Duration.zero)) {
              await Future<void>.delayed(Duration.zero);
            }
          }();
          await client.connect('opc.tcp://127.0.0.1:$port');
          await client.read(writable);
          await client.delete();
          await pump;
          await untilChannelsClosed();
        },
        warmUp: 20,
        iterations: 10,
        rounds: 7,
        maxGrowth: 1000,
        attempts: 3,
      );
    }, timeout: const Timeout.factor(3));

    for (final clientType in clientTypes) {
      test('$clientType client: delete() with sessions open and identities cached is clean', () async {
        final server = Server(
          port: 0,
          logLevel: _fatal,
          users: {'alice': 'a', 'bob': 'b'},
          allowUnencryptedPassword: true,
          authorization: allowing,
        );
        addNodes(server);
        final running = Running(server);
        final clients = [
          for (final user in ['alice', 'bob'])
            await clientOf(clientType, username: user, password: user[0], allowUnencryptedPassword: true),
          await clientOf(clientType),
        ];
        for (final client in clients) {
          await client.connect(running.url);
          await client.readValue(writable);
          await client.browse(objectsFolder);
        }
        // The server closes the three sessions (through the closeSession
        // wrapper) inside UA_Server_delete, before its callbacks are closed.
        await running.stop();
      });
    }
  });
}
