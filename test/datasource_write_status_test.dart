import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  group('Typed status-code rejection (UaStatusException)', () {
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

    Matcher throwsUaStatus(int statusCode) =>
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', statusCode));

    test('gate-denied write answers exactly Bad_NotWritable', () async {
      expect(UA_STATUSCODE_BADNOTWRITABLE, 0x803B0000);
      final nodeId = NodeId.fromString(1, 'datasource.gated');
      var value = 10;

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Gated',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'Gated', value: value, typeId: NodeId.int32),
        // The node advertises Write access (the gate decides per write), but
        // the gate is currently closed.
        onWrite: (_) async => throw const UaStatusException(UA_STATUSCODE_BADNOTWRITABLE),
      );

      await expectLater(
        client.write(nodeId, DynamicValue(value: 11, typeId: NodeId.int32)),
        throwsUaStatus(UA_STATUSCODE_BADNOTWRITABLE),
      );
      expect(value, 10); // backing state untouched
    });

    test('a custom status code (Bad_UserAccessDenied) round-trips verbatim', () async {
      expect(UA_STATUSCODE_BADUSERACCESSDENIED, 0x801F0000);
      final nodeId = NodeId.fromString(1, 'datasource.denied');

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Denied',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'Denied', value: 0, typeId: NodeId.int32),
        onWrite: (_) async => throw const UaStatusException(UA_STATUSCODE_BADUSERACCESSDENIED),
      );

      await expectLater(
        client.write(nodeId, DynamicValue(value: 1, typeId: NodeId.int32)),
        throwsUaStatus(UA_STATUSCODE_BADUSERACCESSDENIED),
      );
    });

    test('a non-UaStatusException throw still maps to Bad_InternalError', () async {
      final nodeId = NodeId.fromString(1, 'datasource.internal');

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Internal',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(name: 'Internal', value: 0, typeId: NodeId.int32),
        onWrite: (_) async => throw StateError('boom'),
      );

      await expectLater(
        client.write(nodeId, DynamicValue(value: 1, typeId: NodeId.int32)),
        throwsUaStatus(UA_STATUSCODE_BADINTERNALERROR),
      );
    });

    test('read symmetry: onRead throwing UaStatusException fails the read with that code', () async {
      final nodeId = NodeId.fromString(1, 'datasource.read_gated');

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'ReadGated',
        typeId: NodeId.int32,
        onRead: () => throw const UaStatusException(UA_STATUSCODE_BADNOCOMMUNICATION),
      );

      // readValue surfaces the code without throwing (no value attached — to
      // serve a value WITH a Bad status use onReadValue instead).
      final dv = await client.readValue(nodeId);
      expect(dv.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(dv.isBad, isTrue);
      expect(dv.value.value, isNull);
    });
  });
}
