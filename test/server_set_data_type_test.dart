// Server.setDataType: the DataType (and ValueRank) of an existing variable
// node replaced in place — a data-source node created without a type gets
// one later, its monitored items untouched.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  late Server server;
  late Client client;

  setUp(() async {
    server = setupServer();
    client = await setupClient(server.port);
  });

  tearDown(() async {
    await client.delete();
    server.shutdown();
    server.delete();
  });

  test('a data-source node without a value gets its DataType and ValueRank', () async {
    final node = NodeId.fromString(1, 'typed.later');
    var reads = 0;
    server.addDataSourceVariableNode(
      node,
      browseName: 'TypedLater',
      onReadValue: () {
        reads++;
        throw const UaStatusException(UA_STATUSCODE_BADNODATA);
      },
    );
    expect(server.readDataType(node), NodeId.fromNumeric(0, 24));
    expect(server.readValueRank(node), isNot(-1));

    server.setDataType(node, NodeId.boolean);

    expect(server.readDataType(node), NodeId.boolean);
    expect(server.readValueRank(node), -1);
    // The node's handler is not asked for the value check.
    expect(reads, 0);
    final attributes = await client.readAttribute({
      node: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
    });
    expect(attributes[node]!.typeId, NodeId.boolean);
  });

  test('an equal DataType is a no-op; a different one replaces it', () {
    final node = NodeId.fromString(1, 'typed.twice');
    server.addDataSourceVariableNode(
      node,
      browseName: 'TypedTwice',
      typeId: NodeId.int16,
      onRead: () => DynamicValue(value: 3, typeId: NodeId.int16),
    );
    server.setDataType(node, NodeId.int16);
    expect(server.readDataType(node), NodeId.int16);
    server.setDataType(node, NodeId.int32);
    expect(server.readDataType(node), NodeId.int32);
    expect(server.readValueRank(node), -1);
  });

  test('a monitored item on the node survives the change', () async {
    final node = NodeId.fromString(1, 'typed.monitored');
    var value = 1;
    server.addDataSourceVariableNode(
      node,
      browseName: 'TypedMonitored',
      onRead: () => DynamicValue(value: value, typeId: NodeId.int32),
    );
    final subscription = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
    final seen = StreamController<Object?>.broadcast();
    final sub = client
        .monitor(node, subscription, samplingInterval: const Duration(milliseconds: 20))
        .listen((v) => seen.add(v.value));
    addTearDown(sub.cancel);
    await seen.stream.firstWhere((v) => v == 1).timeout(const Duration(seconds: 5));

    server.setDataType(node, NodeId.int32);
    value = 2;
    await seen.stream.firstWhere((v) => v == 2).timeout(const Duration(seconds: 5));
    final attributes = await client.readAttribute({
      node: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
    });
    expect(attributes[node]!.typeId, NodeId.int32);
  });

  test('a node with a stored value of another type refuses: Bad_TypeMismatch', () {
    final node = NodeId.fromString(1, 'typed.stored');
    server.addVariableNode(node, DynamicValue(value: 'text', typeId: NodeId.uastring, name: 'TypedStored'));
    expect(
      () => server.setDataType(node, NodeId.int32),
      throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', 0x80740000)),
    );
  });

  test('a missing node is Bad_NodeIdUnknown', () {
    expect(
      () => server.setDataType(NodeId.fromString(1, 'typed.missing'), NodeId.boolean),
      throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', UA_STATUSCODE_BADNODEIDUNKNOWN)),
    );
  });
}
