// Server.setDataType: the DataType (and ValueRank) of an existing variable
// node replaced in place — a data-source node created without a type gets
// one later, its monitored items untouched.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Bad_TypeMismatch (not exported by the package).
const _badTypeMismatch = 0x80740000;

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

  group('ValueRank and ArrayDimensions', () {
    Future<Object?> clientReads(NodeId node, AttributeId attribute) async {
      final attributes = await client.readAttribute({
        node: [attribute],
      });
      final value = attributes[node]?.value;
      // An array attribute arrives as a list of DynamicValue.
      return value is List ? [for (final e in value) (e as DynamicValue).value] : value;
    }

    void addUntypedDataSource(NodeId node, {void Function()? onRead}) {
      server.addDataSourceVariableNode(
        node,
        browseName: node.string,
        onReadValue: () {
          onRead?.call();
          throw const UaStatusException(UA_STATUSCODE_BADNODATA);
        },
      );
    }

    test('an untyped data-source node becomes a String[20]', () async {
      final node = NodeId.fromString(1, 'array.later');
      var reads = 0;
      addUntypedDataSource(node, onRead: () => reads++);
      expect(server.readValueRank(node), -2);
      expect(server.readArrayDimensions(node), isEmpty);

      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [20]);

      expect(server.readDataType(node), NodeId.uastring);
      expect(server.readValueRank(node), 1);
      expect(server.readArrayDimensions(node), [20]);
      expect(reads, 0);
      // What a strict client (UaExpert, Ignition) sees over the wire.
      expect(await clientReads(node, AttributeId.UA_ATTRIBUTEID_VALUERANK), 1);
      expect(await clientReads(node, AttributeId.UA_ATTRIBUTEID_ARRAYDIMENSIONS), [20]);
      expect(
        (await client.readAttribute({
          node: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
        }))[node]!.typeId,
        NodeId.uastring,
      );
    });

    test('an array goes back to a scalar of the same DataType in one call', () async {
      final node = NodeId.fromString(1, 'array.to.scalar');
      addUntypedDataSource(node);
      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [20]);

      server.setDataType(node, NodeId.uastring);

      expect(server.readDataType(node), NodeId.uastring);
      expect(server.readValueRank(node), -1);
      expect(server.readArrayDimensions(node), isEmpty);
      expect(await clientReads(node, AttributeId.UA_ATTRIBUTEID_VALUERANK), -1);
    });

    test('a change of only the ArrayDimensions is not skipped', () {
      final node = NodeId.fromString(1, 'array.resized');
      addUntypedDataSource(node);
      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [20]);

      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [30]);
      expect(server.readArrayDimensions(node), [30]);

      // An empty list clears them; the ValueRank stays.
      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: []);
      expect(server.readValueRank(node), 1);
      expect(server.readArrayDimensions(node), isEmpty);
    });

    test('a change of only the ValueRank is not skipped', () {
      final node = NodeId.fromString(1, 'array.rank');
      addUntypedDataSource(node);
      server.setDataType(node, NodeId.int32, valueRank: 1, arrayDimensions: [4]);

      // The ArrayDimensions left out: cleared, since the old ones cannot fit
      // the new ValueRank.
      server.setDataType(node, NodeId.int32, valueRank: 2);
      expect(server.readValueRank(node), 2);
      expect(server.readArrayDimensions(node), isEmpty);

      server.setDataType(node, NodeId.int32, valueRank: 2, arrayDimensions: [2, 3]);
      expect(server.readArrayDimensions(node), [2, 3]);
      // Same everything: a no-op.
      server.setDataType(node, NodeId.int32, valueRank: 2, arrayDimensions: [2, 3]);
      expect(server.readArrayDimensions(node), [2, 3]);
      // ArrayDimensions left out with the ValueRank unchanged: kept.
      server.setDataType(node, NodeId.int64, valueRank: 2);
      expect(server.readDataType(node), NodeId.int64);
      expect(server.readArrayDimensions(node), [2, 3]);
    });

    test('scalar: false keeps the ValueRank and the ArrayDimensions', () {
      final node = NodeId.fromString(1, 'array.kept');
      addUntypedDataSource(node);
      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [20]);
      server.setDataType(node, NodeId.localizedText, scalar: false);
      expect(server.readDataType(node), NodeId.localizedText);
      expect(server.readValueRank(node), 1);
      expect(server.readArrayDimensions(node), [20]);
    });

    test('ArrayDimensions that do not fit the ValueRank are an ArgumentError', () {
      final node = NodeId.fromString(1, 'array.mismatch');
      addUntypedDataSource(node);
      expect(() => server.setDataType(node, NodeId.uastring, valueRank: 2, arrayDimensions: [20]), throwsArgumentError);
      // `scalar` (the default) with ArrayDimensions.
      expect(() => server.setDataType(node, NodeId.uastring, arrayDimensions: [20]), throwsArgumentError);
      expect(() => server.setDataType(node, NodeId.uastring, valueRank: 0, arrayDimensions: [20]), throwsArgumentError);
      expect(() => server.setDataType(node, NodeId.uastring, valueRank: -4), throwsArgumentError);
      expect(() => server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [-1]), throwsArgumentError);
      // Nothing was written.
      expect(server.readDataType(node), NodeId.fromNumeric(0, 24));
      expect(server.readValueRank(node), -2);
    });

    test('a stored array value is checked against the ValueRank and ArrayDimensions', () {
      final node = NodeId.fromString(1, 'array.stored');
      server.addVariableNode(
        node,
        DynamicValue.fromList(['a', 'b', 'c'], typeId: NodeId.uastring, name: 'ArrayStored'),
      );
      server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [3]);
      expect(server.readValueRank(node), 1);
      expect(server.readArrayDimensions(node), [3]);

      // Three elements do not fit two; the node is left as it was.
      expect(
        () => server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [2]),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', _badTypeMismatch)),
      );
      expect(server.readArrayDimensions(node), [3]);

      // An array value cannot be declared a scalar; the failed call is undone.
      expect(
        () => server.setDataType(node, NodeId.uastring),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', _badTypeMismatch)),
      );
      expect(server.readValueRank(node), 1);
      expect(server.readArrayDimensions(node), [3]);
    });

    test('a stored scalar value refuses an array ValueRank: Bad_TypeMismatch', () {
      final node = NodeId.fromString(1, 'array.stored.scalar');
      server.addVariableNode(node, DynamicValue(value: 'text', typeId: NodeId.uastring, name: 'ArrayStoredScalar'));
      final rank = server.readValueRank(node);
      expect(
        () => server.setDataType(node, NodeId.uastring, valueRank: 1, arrayDimensions: [20]),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', _badTypeMismatch)),
      );
      expect(server.readValueRank(node), rank);
      expect(server.readArrayDimensions(node), isEmpty);
    });

    test('readArrayDimensions of a missing node is Bad_NodeIdUnknown', () {
      expect(
        () => server.readArrayDimensions(NodeId.fromString(1, 'array.missing')),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', UA_STATUSCODE_BADNODEIDUNKNOWN)),
      );
    });
  });

  test('a missing node is Bad_NodeIdUnknown', () {
    expect(
      () => server.setDataType(NodeId.fromString(1, 'typed.missing'), NodeId.boolean),
      throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', UA_STATUSCODE_BADNODEIDUNKNOWN)),
    );
  });
}
