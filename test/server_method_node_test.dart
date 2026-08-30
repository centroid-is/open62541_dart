import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

void main() {
  group('Server method nodes', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      // Delete client before server shutdown to avoid memory corruption.
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('adds two Int32 inputs and returns the sum', () async {
      final methodId = NodeId.fromString(1, 'method.add');
      server.addMethodNode(
        methodId,
        browseName: 'add',
        inputArguments: [
          Argument(name: 'a', dataType: NodeId.int32),
          Argument(name: 'b', dataType: NodeId.int32),
        ],
        outputArguments: [Argument(name: 'sum', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          final sum = inputs[0].asInt + inputs[1].asInt;
          return [DynamicValue(value: sum, typeId: NodeId.int32)];
        },
      );

      final result = await client.call(NodeId.objectsFolder, methodId, [
        DynamicValue(value: 20, typeId: NodeId.int32),
        DynamicValue(value: 22, typeId: NodeId.int32),
      ]);

      expect(result, hasLength(1));
      expect(result.first.asInt, 42);
    });

    test('echoes a string input as uppercase (string marshalling)', () async {
      final methodId = NodeId.fromString(1, 'method.upper');
      server.addMethodNode(
        methodId,
        browseName: 'upper',
        inputArguments: [Argument(name: 'text', dataType: NodeId.uastring)],
        outputArguments: [Argument(name: 'upper', dataType: NodeId.uastring)],
        callback: (inputs, session) async {
          return [DynamicValue(value: inputs[0].asString.toUpperCase(), typeId: NodeId.uastring)];
        },
      );

      final result = await client.call(NodeId.objectsFolder, methodId, [
        DynamicValue(value: 'hello world', typeId: NodeId.uastring),
      ]);

      expect(result, hasLength(1));
      expect(result.first.asString, 'HELLO WORLD');
    });

    test('a throwing callback yields a Bad status without crashing', () async {
      final methodId = NodeId.fromString(1, 'method.throws');
      server.addMethodNode(
        methodId,
        browseName: 'boom',
        inputArguments: [Argument(name: 'a', dataType: NodeId.int32)],
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          throw StateError('boom');
        },
      );

      await expectLater(
        client.call(NodeId.objectsFolder, methodId, [DynamicValue(value: 1, typeId: NodeId.int32)]),
        throwsA(anything),
      );

      // The isolate/server survived: a subsequent healthy method still works.
      final okId = NodeId.fromString(1, 'method.ok');
      server.addMethodNode(
        okId,
        browseName: 'ok',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async => [DynamicValue(value: 7, typeId: NodeId.int32)],
      );
      final ok = await client.call(NodeId.objectsFolder, okId, const []);
      expect(ok.first.asInt, 7);
    });

    test('callback receives the calling session identity', () async {
      // A dedicated client so we can declare the session attributes the
      // handler should observe. Username coverage: the Server constructor
      // cannot enable server-side username/password logins today (its default
      // access control allows anonymous only — backlog item 15), so this
      // exercises the anonymous path; username/certificate identities land
      // with item 15.
      final identifiedClient = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      identifiedClient.config.applicationUri = 'urn:open62541_dart:test:session-identity';
      identifiedClient.config.applicationName = 'session identity test client';
      identifiedClient.config.sessionName = 'session-identity-test-session';
      () async {
        while (identifiedClient.runIterate(Duration(milliseconds: 10))) {
          await Future.delayed(Duration(milliseconds: 5));
        }
      }();
      await identifiedClient.connect('opc.tcp://localhost:$port');

      MethodSessionInfo? captured;
      final methodId = NodeId.fromString(1, 'method.whoami');
      server.addMethodNode(
        methodId,
        browseName: 'whoami',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          captured = session;
          return [DynamicValue(value: 1, typeId: NodeId.int32)];
        },
      );

      try {
        final result = await identifiedClient.call(NodeId.objectsFolder, methodId, const []);
        expect(result.first.asInt, 1);

        final info = captured!;
        // open62541 assigns each session a Guid NodeId; it must be a real,
        // non-null id (and not the admin session's all-but-one-zero guid).
        expect(info.sessionId, isNot(NodeId.nullId));
        expect(info.sessionId.isGuid(), isTrue);
        expect(info.sessionId, isNot(NodeId.fromGuid(0, '00000001-0000-0000-0000-000000000000')));
        // The attributes the client declared above.
        expect(info.applicationUri, 'urn:open62541_dart:test:session-identity');
        expect(info.applicationName, 'session identity test client');
        expect(info.sessionName, 'session-identity-test-session');
        // The default client connects without a user token -> anonymous.
        expect(info.identity, isA<AnonymousSessionIdentity>());
      } finally {
        await identifiedClient.delete();
      }
    });

    test('deleteNode releases a method node and its callback', () async {
      final methodId = NodeId.fromString(1, 'method.temp');
      server.addMethodNode(
        methodId,
        browseName: 'temp',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async => [DynamicValue(value: 1, typeId: NodeId.int32)],
      );

      // Callable before deletion.
      final before = await client.call(NodeId.objectsFolder, methodId, const []);
      expect(before.first.asInt, 1);

      server.deleteNode(methodId);

      // The node is gone; calling it now fails.
      await expectLater(client.call(NodeId.objectsFolder, methodId, const []), throwsA(anything));
    });
  });
}
