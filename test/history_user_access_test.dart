import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'history_memory_backend.dart';
import 'history_raw_client.dart';

/// HistoryRead checks the HistoryRead bit of the session's UserAccessLevel:
/// the node's AccessLevel, ANDed with `ServerAuthorization.userAccessLevel`.

final temperature = NodeId.fromString(1, 'history.temperature');
final pressure = NodeId.fromString(1, 'history.pressure');
final noHistoryRead = NodeId.fromString(1, 'history.noHistoryRead');
final throwing = NodeId.fromString(1, 'history.throwing');

RawHistoryNode node(NodeId id, [Uint8List? cp]) => (nodeId: id, continuationPoint: cp);

String? userOf(MethodSessionInfo session) => switch (session.identity) {
  UsernameSessionIdentity(:final username) => username,
  _ => null,
};

/// Bob loses the HistoryRead bit on [temperature]; [throwing] has a bug.
AccessLevelMask? userAccessLevel(MethodSessionInfo session, NodeId node) {
  if (node == throwing) throw StateError('a bug in the hook');
  if (node == temperature && userOf(session) == 'bob') return const AccessLevelMask(read: true);
  return null;
}

void main() {
  late Server server;
  late MemoryBackend backend;
  final clients = <RawHistoryClient>[];

  Server start({ServerAuthorization? authorization}) {
    final server = Server(
      port: 0,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      users: {'alice': 'a', 'bob': 'b'},
      allowUnencryptedPassword: true,
      authorization: authorization,
    );
    for (final id in [temperature, pressure, throwing]) {
      server.addVariableNode(
        id,
        DynamicValue(value: 0, typeId: NodeId.int32, name: id.string),
        accessLevel: const AccessLevelMask(read: true, historyRead: true),
        historizing: true,
      );
    }
    server.addVariableNode(
      noHistoryRead,
      DynamicValue(value: 0, typeId: NodeId.int32, name: noHistoryRead.string),
      historizing: true,
    );
    backend = MemoryBackend({
      temperature: samples(3),
      pressure: samples(2, base: 100),
      noHistoryRead: samples(1),
      throwing: samples(1),
    });
    server.setHistoryBackend(backend);
    server.start();
    () async {
      while (server.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();
    return server;
  }

  Future<RawHistoryClient> connect({String? username, String? password}) async {
    final client = await RawHistoryClient.connect(server.port, username: username, password: password);
    clients.add(client);
    return client;
  }

  List<Object?> valuesOf(RawHistoryResult r) => r.values.map((v) => v.value).toList();
  List<NodeId> backendNodes() => [
    for (final call in backend.calls)
      for (final request in call) request.nodeId,
  ];

  // The server goes first: deleting a raw client disconnects it with a
  // blocking CloseSession, which a server pumped on this isolate cannot
  // answer.
  tearDown(() {
    server.shutdown();
    server.delete();
    for (final client in clients) {
      client.delete();
    }
    clients.clear();
  });

  group('with a userAccessLevel hook', () {
    setUp(() => server = start(authorization: ServerAuthorization(userAccessLevel: userAccessLevel)));

    test('a node the hook strips of HistoryRead is denied; the others in the request are read', () async {
      final client = await connect(username: 'bob', password: 'b');
      final response = await client.read([node(temperature), node(pressure)]);
      expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
      expect(response.results[0].statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
      expect(response.results[0].values, isEmpty);
      expect(response.results[1].statusCode, raw.UA_STATUSCODE_GOOD);
      expect(valuesOf(response.results[1]), [100, 101]);
      expect(backendNodes(), [pressure], reason: 'a denied node never reaches the backend');
    });

    test('a user the hook leaves alone reads the same node', () async {
      final client = await connect(username: 'alice', password: 'a');
      final response = await client.read([node(temperature), node(pressure)]);
      expect(response.results.map((r) => r.statusCode), [raw.UA_STATUSCODE_GOOD, raw.UA_STATUSCODE_GOOD]);
      expect(valuesOf(response.results[0]), [0, 1, 2]);
    });

    test('the hook cannot grant what the AccessLevel lacks', () async {
      final client = await connect(username: 'alice', password: 'a');
      final response = await client.read([node(noHistoryRead)]);
      expect(response.results.single.statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
      expect(backend.calls, isEmpty);
    });

    test('a hook that throws denies the node', () async {
      final client = await connect(username: 'alice', password: 'a');
      final response = await client.read([node(throwing), node(pressure)]);
      expect(response.results[0].statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
      expect(response.results[1].statusCode, raw.UA_STATUSCODE_GOOD);
      expect(backendNodes(), [pressure]);
    });

    test('a release of continuation points is not checked', () async {
      final client = await connect(username: 'bob', password: 'b');
      final response = await client.read([node(temperature, cpFor(1))], releaseContinuationPoints: true);
      expect(response.results.single.statusCode, raw.UA_STATUSCODE_GOOD);
      expect(backend.released.map(offsetOf), [1]);
    });
  });

  group('without a hook', () {
    setUp(() => server = start());

    test("the node's AccessLevel decides, per node", () async {
      final client = await connect();
      final response = await client.read([node(noHistoryRead), node(temperature)]);
      expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
      expect(response.results[0].statusCode, raw.UA_STATUSCODE_BADUSERACCESSDENIED);
      expect(response.results[1].statusCode, raw.UA_STATUSCODE_GOOD);
      expect(valuesOf(response.results[1]), [0, 1, 2]);
      expect(backendNodes(), [temperature]);
    });

    test('adding the HistoryRead bit with setAccessLevel lets the node be read', () async {
      server.setAccessLevel(noHistoryRead, const AccessLevelMask(read: true, historyRead: true));
      final client = await connect(username: 'bob', password: 'b');
      final response = await client.read([node(noHistoryRead)]);
      expect(response.results.single.statusCode, raw.UA_STATUSCODE_GOOD);
      expect(valuesOf(response.results.single), [0]);
    });
  });
}
