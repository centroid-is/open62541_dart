import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

/// Tests for [Server.addNamespace]: registering an application namespace and
/// creating / reading nodes in it via the returned namespace index.
void main() {
  group('Server.addNamespace', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('registers a namespace and a node created in it reads back', () async {
      final ns = server.addNamespace('urn:test:bridge');
      // The default application namespace is 1; a freshly added one is >= 2.
      expect(ns, greaterThanOrEqualTo(2));

      final nodeId = NodeId.fromString(ns, 'x');
      server.addVariableNode(nodeId, DynamicValue(value: 123, typeId: NodeId.int32, name: 'x'));

      final v = await client.read(nodeId).timeout(const Duration(seconds: 10));
      expect(v.value, 123);
    });

    test('registering the same uri twice returns the same index', () {
      final a = server.addNamespace('urn:test:dedup');
      final b = server.addNamespace('urn:test:dedup');
      expect(a, equals(b));
    });

    test('distinct uris get distinct indices', () {
      final a = server.addNamespace('urn:test:one');
      final b = server.addNamespace('urn:test:two');
      expect(a, isNot(equals(b)));
    });
  });
}
