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
        // The DataType is the abstract Structure (i=22): open62541's reduced
        // NS0 nodeset has no NetworkGroupDataType node (i=11944) to check a
        // value against, although its UA_TYPES table knows the type and
        // decodes it. The client reads the concrete type from the value.
        server.addVariableNode(networkGroupsId, initialGroups, typeId: NodeId.structure);
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
        expectInitialGroups(await client.read(networkGroupsId), rootTypeId: NodeId.structure);
      });

      test('readValue and readAttribute agree', () async {
        expectInitialGroups((await client.readValue(networkGroupsId)).value);
        final read = await client.readAttribute({
          networkGroupsId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expectInitialGroups(read[networkGroupsId]!, rootTypeId: NodeId.structure);
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
        expectInitialGroups(first, rootTypeId: NodeId.structure);
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
        expectInitialGroups(await client.read(networkGroupsId), rootTypeId: NodeId.structure);
      });
    });
  }
}
