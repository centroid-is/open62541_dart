// An array of known NS0 structures, and a method output that is one, read
// through both clients.
//
// Fixture
//   The in-process Server publishes a `NetworkGroupDataType[]` variable
//   (the shape of `Server/ServerRedundancy/ServerNetworkGroups`, i=14415,
//   which open62541 removes from NS0 at startup) and a method whose outputs
//   are a `Range` and a `Range[]`. The Dart server encodes a struct as a
//   binary ExtensionObject; the client's open62541 knows the types, decodes
//   the bodies into native `UA_NetworkGroupDataType` / `UA_Range` memory, and
//   the client decodes those from their native layout.
//
// Write side, failing first
//   A `DynamicValue` whose `typeId` is an NS0 struct id outside the
//   `Namespace0Id` enum was rejected by `valueToVariant` before it was
//   encoded (`ArgumentError: Unknown Namespace0Id value: 11944`), and a struct
//   written with its DataType id as the ExtensionObject's typeId would not be
//   recognised by any receiver, which match the binary encoding id
//   (`NetworkGroupDataType_Encoding_DefaultBinary`, i=11958). The encoding
//   id is now resolved from the `UA_TYPES` table when `extObjEncodingId` is
//   not set.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

final networkGroupsId = NodeId.fromString(1, 'the.networkGroups');
final abstractGroupsId = NodeId.fromString(1, 'the.abstractGroups');
final rangeMethodId = NodeId.fromString(1, 'the.rangeMethod');
final networkGroupTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_NETWORKGROUPDATATYPE);
final networkGroupEncodingId = NodeId.fromNumeric(0, raw.UA_NS0ID_NETWORKGROUPDATATYPE_ENCODING_DEFAULTBINARY);
final endpointUrlListTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_ENDPOINTURLLISTDATATYPE);
final rangeTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE);
final rangeEncodingId = NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE_ENCODING_DEFAULTBINARY);

DynamicValue endpointUrlList(List<String> urls) {
  final value = DynamicValue(typeId: endpointUrlListTypeId);
  value['EndpointUrlList'] = DynamicValue.fromList(urls, typeId: NodeId.uastring);
  return value;
}

DynamicValue networkGroup(String serverUri, List<List<String>> networkPaths) {
  final value = DynamicValue(typeId: networkGroupTypeId);
  value['ServerUri'] = DynamicValue(value: serverUri, typeId: NodeId.uastring);
  value['NetworkPaths'] = DynamicValue.fromList([
    for (final path in networkPaths) endpointUrlList(path),
  ], typeId: endpointUrlListTypeId);
  return value;
}

DynamicValue networkGroups(List<DynamicValue> groups) {
  return DynamicValue.fromList(groups, typeId: networkGroupTypeId, name: 'the.networkGroups');
}

DynamicValue range(double low, double high) {
  final value = DynamicValue(typeId: rangeTypeId);
  value['Low'] = DynamicValue(value: low, typeId: NodeId.double);
  value['High'] = DynamicValue(value: high, typeId: NodeId.double);
  return value;
}

/// The groups the server publishes first: two groups, the second with an
/// empty path list and a two-URL path.
final initialGroups = networkGroups([
  networkGroup('urn:server:a', [
    ['opc.tcp://a:4840'],
  ]),
  networkGroup('urn:server:b', [
    [],
    ['opc.tcp://b:4840', 'opc.tcp://b:4841'],
  ]),
]);

/// [rootTypeId] is the array's own typeId: `read`, `readAttribute` and the
/// monitors report the node's declared DataType (Structure here, see setUp:
/// "prefer explicitly fetched type id"), `readValue` and `call` the concrete
/// type the value came decoded as. The elements always carry the concrete one.
void expectInitialGroups(DynamicValue read, {NodeId? rootTypeId}) {
  expect(read.isArray, isTrue, reason: 'expected an array, got ${read.value}');
  expect(read.typeId, rootTypeId ?? networkGroupTypeId);
  expect(read.asArray.length, 2);
  for (final group in read.asArray) {
    expect(group.isObject, isTrue);
    expect(group.typeId, networkGroupTypeId);
    expect(group.extObjEncodingId, networkGroupEncodingId);
    expect(group.asObject.keys.toList(), ['ServerUri', 'NetworkPaths']);
    expect(group['NetworkPaths'].isArray, isTrue);
    expect(group['NetworkPaths'].typeId, endpointUrlListTypeId);
  }
  final a = read[0];
  expect(a['ServerUri'].asString, 'urn:server:a');
  expect(a['NetworkPaths'].asArray.length, 1);
  expect(a['NetworkPaths'][0].typeId, endpointUrlListTypeId);
  expect(a['NetworkPaths'][0]['EndpointUrlList'].asArray.map((u) => u.asString), ['opc.tcp://a:4840']);
  final b = read[1];
  expect(b['ServerUri'].asString, 'urn:server:b');
  expect(b['NetworkPaths'].asArray.length, 2);
  expect(b['NetworkPaths'][0]['EndpointUrlList'].isArray, isTrue);
  expect(b['NetworkPaths'][0]['EndpointUrlList'].asArray, isEmpty);
  expect(b['NetworkPaths'][1]['EndpointUrlList'].asArray.map((u) => u.asString), [
    'opc.tcp://b:4840',
    'opc.tcp://b:4841',
  ]);
  expect(b['NetworkPaths'][1]['EndpointUrlList'][0].typeId, NodeId.uastring);
}

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: array of known NS0 structures', () {
      late Server server;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        // open62541's reduced NS0 nodeset has no DataType nodes for
        // EndpointUrlListDataType (i=11943) and NetworkGroupDataType
        // (i=11944), although its UA_TYPES table knows both types. Adding them
        // as subtypes of Structure lets the property declare its Part 5
        // DataType (open62541 then serves their DataTypeDefinition from
        // UA_TYPES). The _Encoding_DefaultBinary objects (i=11957/11958)
        // cannot be added: the nodeset has no HasEncoding reference type.
        // Harmless on the wire; the encoding id travels in the value.
        server.addDataTypeNode(endpointUrlListTypeId, 'EndpointUrlListDataType');
        server.addDataTypeNode(networkGroupTypeId, 'NetworkGroupDataType');
        server.addVariableNode(networkGroupsId, initialGroups, typeId: networkGroupTypeId);
        // The same value under the abstract Structure (i=22): the concrete
        // type comes from the value, not from the declared DataType.
        server.addVariableNode(
          abstractGroupsId,
          DynamicValue.from(initialGroups)..name = 'the.abstractGroups',
          typeId: NodeId.structure,
        );
        server.addMethodNode(
          rangeMethodId,
          outputArguments: [
            Argument(name: 'range', dataType: rangeTypeId),
            Argument(name: 'ranges', dataType: rangeTypeId, valueRank: 1),
          ],
          callback: (inputs, session) async => [
            range(-1.5, 2.5),
            DynamicValue.fromList([range(0, 1), range(10, 20)], typeId: rangeTypeId),
          ],
        );
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      test('read NetworkGroupDataType[] with nested EndpointUrlListDataType[] and String[]', () async {
        expectInitialGroups(await client.read(networkGroupsId));
      });

      test('readValue and readAttribute agree; the DataType attribute is NetworkGroupDataType', () async {
        expectInitialGroups((await client.readValue(networkGroupsId)).value);
        final read = await client.readAttribute({
          networkGroupsId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expectInitialGroups(read[networkGroupsId]!);
        final dataType = await client.readAttribute({
          networkGroupsId: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expect(dataType[networkGroupsId]!.typeId, networkGroupTypeId);
      });

      test('a property declared as the abstract Structure: the concrete type comes from the value', () async {
        expectInitialGroups(await client.read(abstractGroupsId), rootTypeId: NodeId.structure);
        expectInitialGroups((await client.readValue(abstractGroupsId)).value);
        final dataType = await client.readAttribute({
          abstractGroupsId: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expect(dataType[abstractGroupsId]!.typeId, NodeId.structure);
      });

      test('the client can read the DataTypeDefinition of the added DataType nodes', () async {
        final definition = await client.readAttribute({
          networkGroupTypeId: [AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION],
        });
        final fields = definition[networkGroupTypeId]!;
        expect(fields.isObject, isTrue);
        expect(fields.asObject.keys.toList(), ['ServerUri', 'NetworkPaths']);
      });

      test('a server write replaces the array, and an empty array reads back empty', () async {
        server.write(networkGroupsId, networkGroups([networkGroup('urn:server:c', [])]));
        final replaced = await client.read(networkGroupsId);
        expect(replaced.asArray.length, 1);
        expect(replaced[0]['ServerUri'].asString, 'urn:server:c');
        expect(replaced[0]['NetworkPaths'].asArray, isEmpty);

        server.write(networkGroupsId, networkGroups([]));
        final empty = await client.read(networkGroupsId);
        expect(empty.isArray, isTrue);
        expect(empty.asArray, isEmpty);
      });

      test('monitor delivers the array', () async {
        final subId = await client.subscriptionCreate();
        final first = await client
            .monitor(networkGroupsId, subId, samplingInterval: Duration(milliseconds: 50))
            .first
            .timeout(Duration(seconds: 10));
        expectInitialGroups(first);
      });

      test('Client.call: a Range and a Range[] output', () async {
        final outputs = await client.call(NodeId.objectsFolder, rangeMethodId, []);
        expect(outputs.length, 2);
        final scalar = outputs[0];
        expect(scalar.isObject, isTrue, reason: 'expected a Range object, got ${scalar.value}');
        expect(scalar.typeId, rangeTypeId);
        expect(scalar.extObjEncodingId, rangeEncodingId);
        expect(scalar.asObject.keys.toList(), ['Low', 'High']);
        expect(scalar['Low'].asDouble, -1.5);
        expect(scalar['High'].asDouble, 2.5);
        expect(scalar['Low'].typeId, NodeId.double);
        final array = outputs[1];
        expect(array.isArray, isTrue);
        expect(array.typeId, rangeTypeId);
        expect(array.asArray.map((r) => (r['Low'].asDouble, r['High'].asDouble)).toList(), [(0.0, 1.0), (10.0, 20.0)]);
      });

      test('a scalar Range variable, written with its DataType id only', () async {
        // Fails on main before anything is encoded: `Namespace0Id.fromInt(884)`.
        final rangeId = NodeId.fromString(1, 'the.range');
        final value = range(1, 2)..name = 'the.range';
        server.addVariableNode(rangeId, value, typeId: rangeTypeId);
        expect(value.extObjEncodingId, isNull, reason: 'the caller\'s value is left alone');
        final read = await client.read(rangeId);
        expect(read.isObject, isTrue, reason: 'expected a Range object, got ${read.value}');
        expect(read.typeId, rangeTypeId);
        expect(read['Low'].asDouble, 1);
        expect(read['High'].asDouble, 2);
      });

      test('the struct read back can be written back as it is', () async {
        // A decoded struct carries its binary encoding id; writing it through
        // the server round-trips without the caller resolving anything.
        final read = await client.read(networkGroupsId);
        read.name = 'the.networkGroups';
        server.write(networkGroupsId, read);
        expectInitialGroups(await client.read(networkGroupsId));
      });
    });
  }

  group('Server.read of a value the server published as an encoded ExtensionObject', () {
    // The Dart server stores a struct as the binary ExtensionObject
    // valueToVariant encoded; nothing decoded it into the native struct (no
    // wire trip), so variantToValue used to throw `Unsupported nodeId type`
    // at the root. The encoding id maps to a UA_TYPES entry, and the body is
    // decoded with UA_decodeBinary into a native struct that is walked.
    late Server server;

    setUp(() {
      server = setupServer();
      server.addDataTypeNode(endpointUrlListTypeId, 'EndpointUrlListDataType');
      server.addDataTypeNode(networkGroupTypeId, 'NetworkGroupDataType');
      server.addVariableNode(networkGroupsId, initialGroups, typeId: networkGroupTypeId);
    });

    tearDown(() {
      server.shutdown();
      server.delete();
    });

    test('NetworkGroupDataType[] (an array of encoded ExtensionObjects)', () {
      expectInitialGroups(server.read(networkGroupsId));
    });

    test('a scalar Range, and an empty array of Range', () {
      final rangeId = NodeId.fromString(1, 'the.range');
      server.addVariableNode(rangeId, range(1, 2)..name = 'the.range', typeId: rangeTypeId);
      final read = server.read(rangeId);
      expect(read.isObject, isTrue, reason: 'expected a Range object, got ${read.value}');
      expect(read.typeId, rangeTypeId);
      expect(read.extObjEncodingId, rangeEncodingId);
      expect(read['Low'].asDouble, 1);
      expect(read['High'].asDouble, 2);

      final emptyId = NodeId.fromString(1, 'the.ranges');
      server.addVariableNode(
        emptyId,
        DynamicValue.fromList([], typeId: rangeTypeId, name: 'the.ranges'),
        typeId: rangeTypeId,
      );
      final empty = server.read(emptyId);
      expect(empty.isArray, isTrue);
      expect(empty.asArray, isEmpty);
    });

    test('an encoded ExtensionObject of a type open62541 does not know keeps the old path', () {
      // A custom struct type with no schema at hand: the root throws the same
      // way as before (there is nothing to decode it with).
      final customId = NodeId.fromString(1, 'the.custom');
      final value = DynamicValue(typeId: NodeId.fromString(1, 'CustomType'), name: 'the.custom');
      value['A'] = DynamicValue(value: 1, typeId: NodeId.int32);
      server.addVariableNode(customId, value, typeId: NodeId.structure);
      expect(() => server.read(customId), throwsA(isA<String>()));
    });
  });
}
