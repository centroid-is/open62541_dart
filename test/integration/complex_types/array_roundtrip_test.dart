// COMPLEX TYPES: arrays (1-D, large, multi-dimensional; of scalars and of
// structs) through a REAL Dart server + client.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import 'support.dart';

void main() {
  group('array round-trip (Dart server + client)', () {
    late ServerClient sc;

    setUp(() async {
      sc = await startServerClient(await freePort());
    });
    tearDown(() async {
      await sc.dispose();
    });

    test('large 1-D scalar array (5000 Int32)', () async {
      final list = [for (var i = 0; i < 5000; i++) DynamicValue(value: i, typeId: NodeId.int32)];
      final v = DynamicValue.fromList(list, typeId: NodeId.int32)..name = 'big';
      final id = NodeId.fromString(1, 'bigNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r.asArray.length, 5000);
      expect(r[0].value, 0);
      expect(r[2500].value, 2500);
      expect(r[4999].value, 4999);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('1-D double array round-trips with write', () async {
      final v = DynamicValue.fromList([
        DynamicValue(value: 1.5, typeId: NodeId.double),
        DynamicValue(value: -2.5, typeId: NodeId.double),
        DynamicValue(value: 3.25, typeId: NodeId.double),
      ], typeId: NodeId.double)..name = 'darr';
      final id = NodeId.fromString(1, 'darrNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.double);

      final updated = DynamicValue.fromList([
        DynamicValue(value: 10.0, typeId: NodeId.double),
        DynamicValue(value: 20.0, typeId: NodeId.double),
        DynamicValue(value: 30.0, typeId: NodeId.double),
      ], typeId: NodeId.double);
      await sc.client.write(id, updated);
      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.asArray.map((e) => e.asDouble).toList(), [10.0, 20.0, 30.0]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('2-D scalar array (Int16 4x2)', () async {
      DynamicValue cell(int x) => DynamicValue(value: x, typeId: NodeId.int16);
      final v = DynamicValue.fromList([
        DynamicValue.fromList([cell(1), cell(2)], typeId: NodeId.int16),
        DynamicValue.fromList([cell(3), cell(4)], typeId: NodeId.int16),
        DynamicValue.fromList([cell(5), cell(6)], typeId: NodeId.int16),
        DynamicValue.fromList([cell(7), cell(8)], typeId: NodeId.int16),
      ], typeId: NodeId.int16)..name = 'grid2d';
      final id = NodeId.fromString(1, 'grid2dNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.int16);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r.asArray.length, 4);
      expect(r[0].asArray.length, 2);
      expect([r[0][0].value, r[0][1].value, r[3][0].value, r[3][1].value], [1, 2, 7, 8]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('3-D scalar array (Int32 2x2x2)', () async {
      DynamicValue cell(int x) => DynamicValue(value: x, typeId: NodeId.int32);
      DynamicValue row(int a, int b) => DynamicValue.fromList([cell(a), cell(b)], typeId: NodeId.int32);
      DynamicValue plane(int a, int b, int c, int d) =>
          DynamicValue.fromList([row(a, b), row(c, d)], typeId: NodeId.int32);
      final v = DynamicValue.fromList([plane(1, 2, 3, 4), plane(5, 6, 7, 8)], typeId: NodeId.int32)..name = 'cube';
      final id = NodeId.fromString(1, 'cubeNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.asArray.length, 2);
      expect(r[0].asArray.length, 2);
      expect(r[0][0].asArray.length, 2);
      expect(r[0][0][0].value, 1);
      expect(r[0][0][1].value, 2);
      expect(r[1][1][1].value, 8);
    }, timeout: const Timeout(Duration(seconds: 30)));

    // ---- Known-defective cases (kept, skipped, root-caused) ----------------

    // Empty arrays are legal in OPC UA and must round-trip as an array of
    // length 0 (not a null value and not a scalar).
    test('empty Int32 array', () async {
      final v = DynamicValue(value: <DynamicValue>[], typeId: NodeId.int32)..name = 'empty';
      final id = NodeId.fromString(1, 'emptyNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);
      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r.asArray, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('empty Double array (via fromList) round-trips with write', () async {
      final v = DynamicValue.fromList(<DynamicValue>[], typeId: NodeId.double)..name = 'emptyD';
      expect(v.isArray, isTrue);
      expect(v.asArray, isEmpty);
      final id = NodeId.fromString(1, 'emptyDoubleNode');
      sc.server.addVariableNode(id, v, typeId: NodeId.double);

      var r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r.asArray, isEmpty);

      // Write a non-empty array, then write an empty one back.
      await sc.client.write(
        id,
        DynamicValue.fromList([
          DynamicValue(value: 1.5, typeId: NodeId.double),
          DynamicValue(value: 2.5, typeId: NodeId.double),
        ], typeId: NodeId.double),
      );
      r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.asArray.length, 2);

      await sc.client.write(id, DynamicValue.fromList(<DynamicValue>[], typeId: NodeId.double));
      r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r.asArray, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    // BUG: a multi-dimensional array whose element type is a custom struct
    // cannot even be encoded. valueToVariant only tags an extension-object type
    // when `asArray.first.isObject`; for a 2-D struct array `asArray.first` is
    // itself an array, so it falls through and throws
    // 'Unable to determine type for ...' (lib/src/common.dart:55-61). Aligns
    // with the AGENTS.md note that multi-dim struct members decode as empty
    // (lib/src/types/opcua_serializer.dart:178-188).
    test('2-D array of structs', () async {
      final t = NodeId.fromString(1, 'Cell');
      final proto = DynamicValue(name: 'cell', typeId: t);
      proto['v'] = DynamicValue(value: 0, typeId: NodeId.int32);
      sc.server.addCustomType(t, proto);
      sc.server.addDataTypeNode(t, 'Cell');
      DynamicValue mk(int x) => DynamicValue.from(proto)..['v'] = x;
      final v = DynamicValue.fromList([
        DynamicValue.fromList([mk(1), mk(2)], typeId: t),
        DynamicValue.fromList([mk(3), mk(4)], typeId: t),
      ], typeId: t)..name = 'grid';
      final id = NodeId.fromString(1, 'structGridNode');
      sc.server.addVariableNode(id, v, typeId: t);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.isArray, isTrue);
      expect(r[0][0]['v'].value, 1);
      expect(r[1][1]['v'].value, 4);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
