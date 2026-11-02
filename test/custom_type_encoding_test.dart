// A custom structured DataType must be resolvable by a third-party client
// (UaExpert, asyncua) the OPC UA 1.04 way: the ExtensionObject on the wire
// carries the DefaultBinary DataTypeEncoding NodeId that the DataType node
// advertises, and that node exists as a `Default Binary` Object (type
// DataTypeEncodingType, i=76) reached from the DataType via HasEncoding
// (i=38). Before 1.5.9 the server encoded the value under its DataType id and
// published no encoding object: the Dart client (which resolves the schema
// from the variable's DataType attribute) read it fine while UaExpert and
// asyncua showed an opaque ExtensionObject.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  final structType = NodeId.fromString(1, 'ST_Enc');
  final nestedType = NodeId.fromString(1, 'ST_Enc_Inner');
  final numericType = NodeId.fromNumeric(1, 4711);
  final nodeId = NodeId.fromString(1, 'enc.struct');
  final dataSourceNode = NodeId.fromString(1, 'enc.datasource');
  // A bundled NS0 structure the reduced nodeset ships no node for.
  final networkGroupDataType = NodeId.fromNumeric(0, 11944);
  final networkGroupDefaultBinary = NodeId.fromNumeric(0, 11958);
  // A value under BaseDataType whose encoding id exists nowhere (what a relay
  // serves when it forwards an upstream custom struct verbatim).
  final phantomNode = NodeId.fromString(1, 'enc.phantom');
  final phantomEncodingId = NodeId.fromString(1, 'Phantom_Encoding_DefaultBinary');

  DynamicValue inner() {
    final s = DynamicValue(name: 'ST_Enc_Inner', typeId: nestedType);
    s['Flag'] = DynamicValue(value: true, typeId: NodeId.boolean);
    return s;
  }

  DynamicValue schema() {
    final s = DynamicValue(name: 'ST_Enc', typeId: structType);
    s['Id'] = DynamicValue(value: 7, typeId: NodeId.int32);
    s['Label'] = DynamicValue(value: 'seven', typeId: NodeId.uastring);
    s['Inner'] = inner();
    return s;
  }

  DynamicValue phantom() {
    final s = DynamicValue(name: 'Phantom', typeId: NodeId.fromString(1, 'Phantom'));
    s['A'] = DynamicValue(value: 0x01020304, typeId: NodeId.int32);
    s.extObjEncodingId = phantomEncodingId;
    return s;
  }

  DynamicValue numericSchema() {
    final s = DynamicValue(name: 'ST_Numeric', typeId: numericType);
    s['Count'] = DynamicValue(value: 3, typeId: NodeId.uint32);
    return s;
  }

  for (final clientType in clientTypes) {
    group('$clientType client: Default Binary encoding of a custom struct', () {
      late Server server;
      late ClientApi client;
      // What the data-source node's onWrite received last.
      DynamicValue? received;

      setUp(() async {
        server = setupServer();
        server.addCustomType(structType, schema());
        server.addDataTypeNode(structType, 'ST_Enc');
        server.addCustomType(numericType, numericSchema());
        server.addDataTypeNode(numericType, 'ST_Numeric');
        server.addVariableNode(
          nodeId,
          schema(),
          typeId: structType,
          accessLevel: const AccessLevelMask(read: true, write: true),
        );
        server.addDataTypeNode(networkGroupDataType, 'NetworkGroupDataType');
        server.addVariableNode(phantomNode, phantom(), typeId: NodeId.fromNumeric(0, 24));
        received = null;
        server.addDataSourceVariableNode(
          dataSourceNode,
          browseName: 'Enc',
          typeId: structType,
          onRead: schema,
          onWrite: (value) async => received = value,
        );
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      Future<BrowseResultItem> defaultBinaryOf(NodeId type) async {
        final encodings = await client.browse(type, direction: 0, referenceTypeId: NodeId.hasEncoding);
        expect(encodings, hasLength(1), reason: 'exactly one DataTypeEncoding via HasEncoding from $type');
        final enc = encodings.single;
        expect(enc.browseName, 'Default Binary');
        expect(enc.nodeClass, NodeClass.UA_NODECLASS_OBJECT);
        expect(enc.typeDefinition, NodeId.dataTypeEncodingType);
        expect(enc.nodeId, isNot(type));
        return enc;
      }

      test('the DataType node has a HasEncoding -> Default Binary object with the conventional id', () async {
        final enc = await defaultBinaryOf(structType);
        expect(enc.nodeId, NodeId.fromString(1, 'ST_Enc_Encoding_DefaultBinary'));
        // The object is reachable, is of DataTypeEncodingType, and leads back
        // to its DataType by the inverse reference (what a browser follows).
        final back = await client.browse(enc.nodeId, direction: 1, referenceTypeId: NodeId.hasEncoding);
        expect(back.map((r) => r.nodeId), [structType]);
        final typeDef = await client.browse(enc.nodeId, direction: 0, referenceTypeId: NodeId.hasTypeDefinition);
        expect(typeDef.map((r) => r.nodeId), [NodeId.dataTypeEncodingType]);
      });

      test('a nested struct type auto-registered by addCustomType gets its own encoding object', () async {
        final enc = await defaultBinaryOf(nestedType);
        expect(enc.nodeId, NodeId.fromString(1, 'ST_Enc_Inner_Encoding_DefaultBinary'));
      });

      test('a bundled NS0 structure published with addDataTypeNode gets its bundled Default Binary object', () async {
        // NetworkGroupDataType i=11944 is in UA_TYPES but not in the reduced
        // nodeset; its encoding object is the bundled i=11958, not a derived
        // string id.
        final enc = await defaultBinaryOf(networkGroupDataType);
        expect(enc.nodeId, networkGroupDefaultBinary);
        expect(enc.nodeId.isNumeric(), isTrue);
        final back = await client.browse(enc.nodeId, direction: 1, referenceTypeId: NodeId.hasEncoding);
        expect(back.map((r) => r.nodeId), [networkGroupDataType]);
        // No derived-string sibling was published for it.
        expect(
          () => client.browse(NodeId.fromString(0, '11944_Encoding_DefaultBinary'), direction: 0),
          throwsA(predicate((e) => '$e'.contains('BadNodeIdUnknown'))),
        );
      });

      test('readValue of an ExtensionObject whose encoding id resolves to no DataType is opaque, not thrown', () async {
        // No DataType at hand; the inverse HasEncoding browse finds no node
        // at the wire id, and nothing else describes the type.
        final dv = await client.readValue(phantomNode);
        expect(dv.statusCode, 0);
        expect(dv.value.typeId, NodeId.structure);
        expect(dv.value.extObjEncodingId, phantomEncodingId);
        expect(dv.value.value, [4, 3, 2, 1], reason: 'the body, untouched (Int32 0x01020304 little-endian)');
      });

      test('read of a BaseDataType variable holding such an ExtensionObject is opaque, not thrown', () async {
        // The DataType attribute is BaseDataType i=24, which has no
        // definition; the wire id decides, and it resolves to nothing.
        final v = await client.read(phantomNode);
        expect(v.typeId, NodeId.fromNumeric(0, 24), reason: 'read reports the DataType attribute it fetched');
        expect(v.extObjEncodingId, phantomEncodingId);
        expect(v.value, [4, 3, 2, 1]);
      });

      test('a numeric DataType id gets a string encoding id derived from its number', () async {
        // (A value of such a type cannot be serialised by valueToVariant, a
        // limit this test does not touch; the DataType and encoding nodes are
        // published all the same.)
        final enc = await defaultBinaryOf(numericType);
        expect(enc.nodeId, NodeId.fromString(1, '4711_Encoding_DefaultBinary'));
      });

      test('the ExtensionObject on the wire carries the Default Binary id (read, with the DataType at hand)', () async {
        final enc = await defaultBinaryOf(structType);
        final value = await client.read(nodeId);
        expect(value.isObject, isTrue);
        expect(value['Id'].asInt, 7);
        expect(value['Inner']['Flag'].asBool, isTrue);
        expect(value.typeId, structType);
        expect(value.extObjEncodingId, enc.nodeId, reason: 'wire encoding id == the advertised Default Binary node');
      });

      test('readValue (no DataType at hand) resolves the encoding id to the DataType and decodes', () async {
        final enc = await defaultBinaryOf(structType);
        for (final node in [nodeId, dataSourceNode]) {
          final dv = await client.readValue(node);
          expect(dv.statusCode, 0);
          expect(dv.value.isObject, isTrue, reason: '$node decodes');
          expect(dv.value['Label'].asString, 'seven');
          expect(dv.value.typeId, structType);
          expect(dv.value.extObjEncodingId, enc.nodeId);
        }
      });

      test('DataTypeDefinition.defaultEncodingId is the Default Binary id, and a value built from the fetched '
          'schema writes with it', () async {
        final enc = await defaultBinaryOf(structType);
        final definition = (await client.readAttribute({
          structType: [AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION],
        }))[structType]!;
        expect(definition.isObject, isTrue);
        expect(definition.asObject.keys, ['Id', 'Label', 'Inner']);
        expect(definition.extObjEncodingId, enc.nodeId, reason: 'defaultEncodingId == the HasEncoding target');

        // A client that knows nothing but what the server told it: build the
        // value from the fetched definitions (a nested field comes back as a
        // typed placeholder; its own definition fills it in) and write it.
        final innerDefinition = (await client.readAttribute({
          nestedType: [AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION],
        }))[nestedType]!;
        final fresh = DynamicValue.from(definition);
        fresh.typeId = structType;
        fresh['Id'].value = 11;
        fresh['Label'].value = 'eleven';
        fresh['Inner'] = DynamicValue.from(innerDefinition)..typeId = nestedType;
        fresh['Inner']['Flag'].value = false;
        await client.write(dataSourceNode, fresh);

        // The server decoded it (open62541 matched the encoding id to the
        // registered type; the native struct came through the write path).
        expect(received, isNotNull);
        expect(received!['Id'].asInt, 11);
        expect(received!['Label'].asString, 'eleven');
        expect(received!['Inner']['Flag'].asBool, isFalse);
        expect(received!.extObjEncodingId, enc.nodeId, reason: 'the wire carried the Default Binary id');
      });

      test('a value read back writes back as it is, and one built from scratch still decodes on the server', () async {
        final value = await client.read(nodeId);
        value['Id'].value = 8;
        await client.write(nodeId, value);
        expect((await client.read(nodeId))['Id'].asInt, 8);
        expect(server.read(nodeId)['Id'].asInt, 8);

        final fresh = schema();
        fresh['Id'].value = 9;
        fresh['Label'].value = 'nine';
        await client.write(nodeId, fresh);
        final back = await client.read(nodeId);
        expect(back['Id'].asInt, 9);
        expect(back['Label'].asString, 'nine');
      });
    });
  }
}
