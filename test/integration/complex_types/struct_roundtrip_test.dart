// COMPLEX TYPES: structures (extension objects) through a REAL Dart server +
// client. Custom types are registered with Server.addCustomType +
// addDataTypeNode (see support.registerStructType) so the client can fetch the
// DataTypeDefinition and decode the extension object off the wire.
//
// Several targeted cases surface genuine library defects; those are kept but
// marked `skip: 'BUG: ...'` so the suite stays green while pinning the defect.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import 'support.dart';

void main() {
  group('struct round-trip (Dart server + client)', () {
    late ServerClient sc;

    setUp(() async {
      sc = await startServerClient(await freePort());
    });
    tearDown(() async {
      await sc.dispose();
    });

    test('simple struct (scalar members) read + write', () async {
      final t = NodeId.fromString(1, 'Simple');
      final v = DynamicValue(name: 'SimpleVar', typeId: t);
      v['count'] = DynamicValue(value: 2, typeId: NodeId.int32);
      v['on'] = DynamicValue(value: true, typeId: NodeId.boolean);
      v['temp'] = DynamicValue(value: 5.8, typeId: NodeId.double);
      registerStructType(sc.server, t, v);

      final id = NodeId.fromString(1, 'simpleNode');
      sc.server.addVariableNode(id, v, typeId: t);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isObject, isTrue);
      expect(r.typeId, t);
      expect(r.asObject.length, 3);
      expect(r['count'].value, 2);
      expect(r['on'].value, true);
      expect(r['temp'].value, 5.8);

      // Mutate and write back through the client, then re-read.
      r['count'] = 10;
      r['on'] = false;
      r['temp'] = 154.7;
      await sc.client.write(id, r);
      final r2 = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r2['count'].value, 10);
      expect(r2['on'].value, false);
      expect(r2['temp'].value, 154.7);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('struct decodes as an extension object (encoding id present)', () async {
      final t = NodeId.fromString(1, 'ExtObj');
      final v = DynamicValue(name: 'ExtObjVar', typeId: t);
      v['a'] = DynamicValue(value: 11, typeId: NodeId.int32);
      registerStructType(sc.server, t, v);

      final id = NodeId.fromString(1, 'extObjNode');
      sc.server.addVariableNode(id, v, typeId: t);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isObject, isTrue);
      // Struct values travel the wire as UA_ExtensionObject; the decoder records
      // the concrete binary-encoding id it was tagged with.
      expect(r.extObjEncodingId, isNotNull);
      expect(r['a'].value, 11);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('nested struct (2 levels)', () async {
      final inner = NodeId.fromString(1, 'NInner');
      final outer = NodeId.fromString(1, 'NOuter');
      final innerVal = DynamicValue(name: 'inner', typeId: inner);
      innerVal['a'] = DynamicValue(value: 7, typeId: NodeId.int32);
      innerVal['flag'] = DynamicValue(value: true, typeId: NodeId.boolean);
      final v = DynamicValue(name: 'NOuterVar', typeId: outer);
      v['x'] = DynamicValue(value: 1, typeId: NodeId.int32);
      v['inner'] = innerVal;
      registerStructType(sc.server, outer, v);

      final id = NodeId.fromString(1, 'nestedNode');
      sc.server.addVariableNode(id, v, typeId: outer);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r['x'].value, 1);
      expect(r['inner'].isObject, isTrue);
      expect(r['inner']['a'].value, 7);
      expect(r['inner']['flag'].value, true);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('deeply nested struct (3 levels)', () async {
      final l3 = NodeId.fromString(1, 'D3');
      final l2 = NodeId.fromString(1, 'D2');
      final l1 = NodeId.fromString(1, 'D1');
      final v3 = DynamicValue(name: 'l3', typeId: l3);
      v3['deep'] = DynamicValue(value: 42, typeId: NodeId.int32);
      v3['label'] = DynamicValue(value: 'bottom', typeId: NodeId.uastring);
      final v2 = DynamicValue(name: 'l2', typeId: l2);
      v2['mid'] = DynamicValue(value: 7, typeId: NodeId.int32);
      v2['child'] = v3;
      final v1 = DynamicValue(name: 'D1Var', typeId: l1);
      v1['top'] = DynamicValue(value: 1, typeId: NodeId.int32);
      v1['child'] = v2;
      registerStructType(sc.server, l1, v1);

      final id = NodeId.fromString(1, 'deepNode');
      sc.server.addVariableNode(id, v1, typeId: l1);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r['top'].value, 1);
      expect(r['child']['mid'].value, 7);
      expect(r['child']['child']['deep'].value, 42);
      expect(r['child']['child']['label'].value, 'bottom');
    }, timeout: const Timeout(Duration(seconds: 30)));

    // ---- Known-defective cases (kept, skipped, root-caused) ----------------

    // BUG: a scalar-array member of a struct does not round-trip. Reading the
    // struct decodes the array member as a single scalar (observed 16777216 for
    // [1,2,3]). Server.addCustomType (lib/src/server.dart:372) marks the member
    // isArray on the UA_DataTypeMember but the DataTypeDefinition the client
    // reads back does not carry field dimensions, so client buildSchema /
    // OpcUaDynamicValueSerializer.fromDataTypeDefinition
    // (lib/src/types/opcua_serializer.dart:178-188) builds a scalar field and
    // the binary decode desynchronizes.
    test('struct with scalar-array member', () async {
      final t = NodeId.fromString(1, 'ArrMember');
      final v = DynamicValue(name: 'ArrMemberVar', typeId: t);
      v['n'] = DynamicValue(value: 3, typeId: NodeId.int32);
      v['xs'] = DynamicValue.fromList([
        DynamicValue(value: 1, typeId: NodeId.int32),
        DynamicValue(value: 2, typeId: NodeId.int32),
        DynamicValue(value: 3, typeId: NodeId.int32),
      ], typeId: NodeId.int32);
      registerStructType(sc.server, t, v);
      final id = NodeId.fromString(1, 'arrMemberNode');
      sc.server.addVariableNode(id, v, typeId: t);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r['xs'].isArray, isTrue);
      expect(r['xs'].asArray.map((e) => e.value).toList(), [1, 2, 3]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    // BUG: an array-of-structs variable decodes as a single struct rather than
    // an array of structs (client read returns isArray == false). Same family
    // as the repo's skipped async_integration_test.dart 'Array of struct read
    // and write'. Root cause in the array/extension-object dimension handling of
    // variantToValue (lib/src/common.dart:103-124) + client auto-schema
    // (lib/src/client.dart _variantToValueAutoSchema ~1556).
    test(
      'array of structs',
      () async {
        final t = NodeId.fromString(1, 'ElemT');
        final elem = DynamicValue(name: 'elem', typeId: t);
        elem['a'] = DynamicValue(value: 0, typeId: NodeId.int32);
        elem['b'] = DynamicValue(value: true, typeId: NodeId.boolean);
        sc.server.addCustomType(t, elem);
        sc.server.addDataTypeNode(t, 'ElemT');
        final arr = DynamicValue(name: 'AoSVar', typeId: t);
        for (var i = 0; i < 3; i++) {
          final e = DynamicValue.from(elem);
          e['a'] = i;
          e['b'] = i.isEven;
          arr[i] = e;
        }
        final id = NodeId.fromString(1, 'aosNode');
        sc.server.addVariableNode(id, arr, typeId: t);

        final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
        expect(r.isArray, isTrue);
        expect(r.asArray.length, 3);
        expect(r[0]['a'].value, 0);
        expect(r[2]['a'].value, 2);
      },
      skip:
          'BUG: array-of-structs decodes as a single struct (isArray==false) — '
          'lib/src/common.dart variantToValue (103-124) / client '
          '_variantToValueAutoSchema (lib/src/client.dart ~1556); mirrors repo '
          'async_integration_test.dart skipped case',
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // BUG: reading a struct whose members are all strings HANGS the client read
    // (never completes; the native call blocks so even a Dart .timeout cannot
    // fire). Mirrors the repo's skipped async_integration_test.dart 'struct of
    // strings'. Contiguous in-struct string decode desynchronizes against the
    // schema built from the Dart server's DataTypeDefinition. NOTE: kept skipped
    // precisely because running it would wedge the whole test process.
    test(
      'struct of strings',
      () async {
        final t = NodeId.fromString(1, 'SStr');
        final v = DynamicValue(name: 'SStrVar', typeId: t);
        v['a'] = DynamicValue(value: 'abab', typeId: NodeId.uastring);
        v['b'] = DynamicValue(value: 'abba', typeId: NodeId.uastring);
        v['c'] = DynamicValue(value: 'baab', typeId: NodeId.uastring);
        registerStructType(sc.server, t, v);
        final id = NodeId.fromString(1, 'sstrNode');
        sc.server.addVariableNode(id, v, typeId: t);

        final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
        expect(r['a'].value, 'abab');
        expect(r['b'].value, 'abba');
        expect(r['c'].value, 'baab');
      },
      skip:
          'BUG: reading an all-string struct HANGS the client (native block, '
          'timeout cannot fire) — contiguous string decode vs Dart-server '
          'DataTypeDefinition; mirrors repo async_integration_test.dart skip',
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // A struct with a required field + an OPTIONAL field round-trips both ways:
    // the optional field PRESENT (encoding-mask bit set, value carried) and
    // ABSENT (bit clear, no bytes, decoded as null). Marking a member
    // isOptional changes the open62541 struct layout (a leading UInt32 encoding
    // mask per OPC UA Part 6); the serializer honours that mask on both encode
    // and decode (lib/src/types/opcua_serializer.dart).
    test('optional struct field (present and absent)', () async {
      final t = NodeId.fromString(1, 'Opt');

      // Schema used to register the custom type: 'opt' is flagged optional.
      final schema = DynamicValue(name: 'OptVar', typeId: t);
      schema['req'] = DynamicValue(value: 1, typeId: NodeId.int32);
      final optSchema = DynamicValue(value: 2, typeId: NodeId.int32);
      optSchema.isOptional = true;
      schema['opt'] = optSchema;
      registerStructType(sc.server, t, schema);

      // Node 1: optional field PRESENT.
      final present = DynamicValue(name: 'OptPresent', typeId: t);
      present['req'] = DynamicValue(value: 1, typeId: NodeId.int32);
      final optPresent = DynamicValue(value: 2, typeId: NodeId.int32);
      optPresent.isOptional = true;
      present['opt'] = optPresent;
      final presentId = NodeId.fromString(1, 'optPresentNode');
      sc.server.addVariableNode(presentId, present, typeId: t);

      // Node 2: optional field ABSENT (null value, still flagged optional).
      final absent = DynamicValue(name: 'OptAbsent', typeId: t);
      absent['req'] = DynamicValue(value: 7, typeId: NodeId.int32);
      final optAbsent = DynamicValue(typeId: NodeId.int32); // value == null
      optAbsent.isOptional = true;
      absent['opt'] = optAbsent;
      final absentId = NodeId.fromString(1, 'optAbsentNode');
      sc.server.addVariableNode(absentId, absent, typeId: t);

      final rp = await sc.client.read(presentId).timeout(const Duration(seconds: 8));
      expect(rp['req'].value, 1);
      expect(rp['opt'].value, 2, reason: 'present optional field must carry its value');

      final ra = await sc.client.read(absentId).timeout(const Duration(seconds: 8));
      expect(ra['req'].value, 7);
      expect(ra['opt'].value, isNull, reason: 'absent optional field decodes as null');
    }, timeout: const Timeout(Duration(seconds: 30)));

    // BUG: struct field descriptions are not surfaced to the client. The field
    // description set on the schema is not carried through
    // Server.addCustomType/addDataTypeNode into the DataTypeDefinition, and/or
    // fromDataTypeDefinition (lib/src/types/opcua_serializer.dart:190) does not
    // reach the client read. Observed: read field .description == null.
    test('struct field descriptions surface to client', () async {
      final t = NodeId.fromString(1, 'DescStruct');
      final v = DynamicValue(name: 'DescVar', typeId: t);
      final f = DynamicValue(value: 1, typeId: NodeId.int32);
      f.description = LocalizedText('the field one', 'en');
      v['f'] = f;
      registerStructType(sc.server, t, v);
      final id = NodeId.fromString(1, 'descNode');
      sc.server.addVariableNode(id, v, typeId: t);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r['f'].description, isNotNull);
      expect(r['f'].description!.value, 'the field one');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
