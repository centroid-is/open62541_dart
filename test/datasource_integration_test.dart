import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

void main() {
  group('Data source (callback) variable nodes', () {
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

    test('read-write node: reads use onRead, writes deliver to onWrite', () async {
      // Backing state held purely in Dart and bridged through the callbacks.
      double temperature = 21.5;
      final tempNodeId = NodeId.fromString(1, 'datasource.temperature');

      server.addDataSourceVariableNode(
        tempNodeId,
        browseName: 'Temperature',
        typeId: NodeId.double,
        onRead: () => DynamicValue(name: 'Temperature', value: temperature, typeId: NodeId.double),
        onWrite: (value) async => temperature = (value.value as num).toDouble(),
      );

      // Initial read comes from onRead.
      final r1 = await client.read(tempNodeId);
      expect((r1.value as num).toDouble(), 21.5);

      // A client write is delivered to onWrite, which mutates the backing state.
      await client.write(tempNodeId, DynamicValue(value: 37.2, typeId: NodeId.double));
      expect(temperature, 37.2);

      // A subsequent read reflects the new backing state.
      final r2 = await client.read(tempNodeId);
      expect((r2.value as num).toDouble(), closeTo(37.2, 1e-9));
    });

    test('read-only node (no onWrite): client write is rejected', () async {
      int counter = 7;
      final counterNodeId = NodeId.fromString(1, 'datasource.counter');

      server.addDataSourceVariableNode(
        counterNodeId,
        browseName: 'Counter',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'Counter', value: counter, typeId: NodeId.int32),
        // no onWrite => read-only
      );

      // Server-side mutation is visible to the client via onRead.
      final r1 = await client.read(counterNodeId);
      expect(r1.value, 7);
      counter = 42;
      final r2 = await client.read(counterNodeId);
      expect(r2.value, 42);

      // A client write must be rejected (node created without the Write bit).
      await expectLater(client.write(counterNodeId, DynamicValue(value: 99, typeId: NodeId.int32)), throwsA(anything));
      // Backing state untouched by the rejected write.
      expect(counter, 42);
    });

    test('onRead that throws surfaces as a Bad status (no isolate crash)', () async {
      final badNodeId = NodeId.fromString(1, 'datasource.throws');

      server.addDataSourceVariableNode(
        badNodeId,
        browseName: 'Throws',
        typeId: NodeId.int32,
        onRead: () => throw Exception('no value available'),
      );

      await expectLater(client.read(badNodeId), throwsA(anything));

      // The server/isolate is still alive: a healthy node still reads fine.
      final okNodeId = NodeId.fromString(1, 'datasource.ok');
      server.addDataSourceVariableNode(
        okNodeId,
        browseName: 'Ok',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'Ok', value: 1, typeId: NodeId.int32),
      );
      expect((await client.read(okNodeId)).value, 1);
    });

    test('onWrite that throws surfaces as a Bad status', () async {
      final nodeId = NodeId.fromString(1, 'datasource.write_throws');
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'WriteThrows',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'WriteThrows', value: 0, typeId: NodeId.int32),
        onWrite: (value) async => throw Exception('rejected'),
      );

      await expectLater(client.write(nodeId, DynamicValue(value: 5, typeId: NodeId.int32)), throwsA(anything));
    });

    test('string-valued data source node', () async {
      String label = 'hello';
      final nodeId = NodeId.fromString(1, 'datasource.label');
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Label',
        typeId: NodeId.uastring,
        onRead: () => DynamicValue(name: 'Label', value: label, typeId: NodeId.uastring),
        onWrite: (value) async => label = value.value as String,
      );

      expect((await client.read(nodeId)).value, 'hello');
      await client.write(nodeId, DynamicValue(value: 'world', typeId: NodeId.uastring));
      expect(label, 'world');
      expect((await client.read(nodeId)).value, 'world');
    });
  });
}
