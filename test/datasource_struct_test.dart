import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// End-to-end test for exposing a custom OPC UA structured type through a
/// **data-source** variable node (value sourced live from a Dart callback).
///
/// A struct `ST_Test { Id: Int32, Value: Double, Enabled: Boolean, Label:
/// String }` is registered as a custom DataType, published as a DataType node,
/// and exposed as a data-source node. A client then:
///   1. reads the node back as a structured value with all four fields, and
///   2. writes a modified struct which the server's `onWrite` receives fully
///      decoded (schema restored), after which a re-read reflects the change.
///
/// The write path is the interesting one: a client sends a structured value as
/// a binary ExtensionObject. Decoding it back into a [DynamicValue] with typed
/// fields on the server requires the registered field schema — the data-source
/// write dispatcher marshals it with the node's declared DataType + the local
/// schema registry (see `Server.addDataSourceVariableNode` / `addCustomType`).
void main() {
  group('Data-source node of a custom structured type', () {
    late int port;
    late Server server;
    late Client client;

    final structType = NodeId.fromString(1, 'ST_Test');
    final nodeId = NodeId.fromString(1, 'datasource.struct');

    // The registered field schema (used as a template; values are placeholders).
    DynamicValue makeSchema() {
      final s = DynamicValue(name: 'ST_Test', typeId: structType);
      s['Id'] = DynamicValue(value: 0, typeId: NodeId.int32);
      s['Value'] = DynamicValue(value: 0.0, typeId: NodeId.double);
      s['Enabled'] = DynamicValue(value: false, typeId: NodeId.boolean);
      s['Label'] = DynamicValue(value: '', typeId: NodeId.uastring);
      return s;
    }

    // Live backing state bridged through the data-source callbacks.
    late DynamicValue backing;

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);
      client = await setupClient(port);

      server.addCustomType(structType, makeSchema());
      server.addDataTypeNode(structType, 'ST_Test', displayName: LocalizedText('ST Test', 'en-US'));

      backing = makeSchema();
      backing['Id'] = DynamicValue(value: 7, typeId: NodeId.int32);
      backing['Value'] = DynamicValue(value: 1.5, typeId: NodeId.double);
      backing['Enabled'] = DynamicValue(value: true, typeId: NodeId.boolean);
      backing['Label'] = DynamicValue(value: 'initial', typeId: NodeId.uastring);

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'StructTag',
        typeId: structType,
        onRead: () => backing,
        onWrite: (value) => backing = value,
      );
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('client reads the struct back with all four fields', () async {
      final v = await client.read(nodeId).timeout(const Duration(seconds: 10));

      expect(v.isObject, isTrue);
      expect(v.typeId, structType);
      expect(v.asObject.keys, containsAll(<String>['Id', 'Value', 'Enabled', 'Label']));
      expect(v['Id'].value, 7);
      expect((v['Value'].value as num).toDouble(), closeTo(1.5, 1e-9));
      expect(v['Enabled'].value, true);
      expect(v['Label'].value, 'initial');
    });

    test('client writes a modified struct; server decodes it and re-read reflects it', () async {
      // Build a modified struct value to write.
      final w = makeSchema();
      w['Id'] = DynamicValue(value: 99, typeId: NodeId.int32);
      w['Value'] = DynamicValue(value: 3.14159, typeId: NodeId.double);
      w['Enabled'] = DynamicValue(value: false, typeId: NodeId.boolean);
      w['Label'] = DynamicValue(value: 'updated', typeId: NodeId.uastring);

      await client.write(nodeId, w).timeout(const Duration(seconds: 10));

      // onWrite received the fully-decoded struct (schema restored).
      expect(backing.isObject, isTrue);
      expect(backing['Id'].value, 99);
      expect((backing['Value'].value as num).toDouble(), closeTo(3.14159, 1e-9));
      expect(backing['Enabled'].value, false);
      expect(backing['Label'].value, 'updated');

      // A subsequent client read reflects the new backing state.
      final v = await client.read(nodeId).timeout(const Duration(seconds: 10));
      expect(v['Id'].value, 99);
      expect((v['Value'].value as num).toDouble(), closeTo(3.14159, 1e-9));
      expect(v['Enabled'].value, false);
      expect(v['Label'].value, 'updated');
    });
  });
}
