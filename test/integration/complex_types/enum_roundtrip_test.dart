// COMPLEX TYPES: enumerations through a REAL Dart server + client.
//
// The Dart Server exposes enum-typed variables as their underlying integer; it
// does not publish an EnumDefinition, so enum *metadata* (field names) is not
// surfaced to the client. Enum *value* fidelity is what round-trips.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import 'support.dart';

void main() {
  group('enum round-trip (Dart server + client)', () {
    late ServerClient sc;

    setUp(() async {
      sc = await startServerClient(await freePort());
    });
    tearDown(() async {
      await sc.dispose();
    });

    // Enum fields for a pump state, mirrored client-side for value->name mapping.
    Map<int, EnumField> pumpStates() => {
      0: EnumField(0, 'Idle', LocalizedText('Idle', ''), LocalizedText('', '')),
      1: EnumField(1, 'Running', LocalizedText('Running', ''), LocalizedText('', '')),
      2: EnumField(2, 'Fault', LocalizedText('Fault', ''), LocalizedText('', '')),
    };

    test('int32-based enum value round-trips (read + write)', () async {
      final v = DynamicValue(value: 2, typeId: NodeId.int32, name: 'pumpState')..enumFields = pumpStates();
      final id = NodeId.fromString(1, 'pumpStateNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.asInt, 2);
      // Client-side we can still resolve the label via a local enum table.
      expect(pumpStates()[r.asInt]!.name, 'Fault');

      // Write a different enum member and read it back.
      await sc.client.write(id, DynamicValue(value: 1, typeId: NodeId.int32));
      final r2 = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r2.asInt, 1);
      expect(pumpStates()[r2.asInt]!.name, 'Running');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('enum boundary values round-trip', () async {
      final id = NodeId.fromString(1, 'enumBoundNode');
      sc.server.addVariableNode(
        id,
        DynamicValue(value: 0, typeId: NodeId.int32, name: 'enumBound'),
        typeId: NodeId.int32,
      );
      for (final val in [0, 1, 2147483647, -2147483648]) {
        await sc.client.write(id, DynamicValue(value: val, typeId: NodeId.int32));
        final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
        expect(r.asInt, val);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    // BUG/limitation: enum field metadata is not surfaced by the Dart server.
    // Server.addDataTypeNode (lib/src/server.dart:205) creates a DataType node
    // but never publishes an EnumDefinition/DataTypeDefinition, so the client's
    // buildSchema has nothing to read and the read value carries enumFields ==
    // null (observed). Full metadata requires a server that exposes an
    // EnumDefinition (e.g. asyncua), which the harness fish-farm server does not.
    test('enum field metadata surfaces to client', () async {
      final v = DynamicValue(value: 2, typeId: NodeId.int32, name: 'pumpState2')..enumFields = pumpStates();
      final id = NodeId.fromString(1, 'pumpState2Node');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.enumFields, isNotNull);
      expect(r.enumFields![2]!.name, 'Fault');
    }, timeout: const Timeout(Duration(seconds: 30)));

    // BUG: only int32-based enums are supported. When a server publishes an
    // EnumDefinition, the decoder unconditionally forces the enum type to Int32
    // (lib/src/types/opcua_serializer.dart:168-169), so a non-Int32 enum (e.g.
    // one whose transport type is another integer width) is misdecoded. This
    // path additionally requires a server that publishes an EnumDefinition,
    // which the local harness servers do not provide.
    test(
      'non-int32 enum decodes with correct width',
      () async {
        // Placeholder assertion — the defect is in the decode path referenced in
        // the skip reason; there is no harness server that publishes a non-Int32
        // EnumDefinition to drive it end-to-end.
        expect(true, isTrue);
      },
      skip:
          'BUG: enums are always forced to Int32 on decode '
          '(lib/src/types/opcua_serializer.dart:168-169); no harness server '
          'publishes a non-Int32 EnumDefinition to exercise it end-to-end',
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
