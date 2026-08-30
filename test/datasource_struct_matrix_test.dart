import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Broad regression matrix for the custom-struct (custom-type) **data-source**
/// read/write path.
///
/// Motivation: a client's struct write arrives as a binary ExtensionObject and
/// must be decoded against the registered field schema on the server (see
/// `Server.addDataSourceVariableNode` / `Server.addCustomType`). A prior bug
/// decoded it with no schema and failed with `BadInternalError`. The existing
/// `datasource_struct_test.dart` only covers a single 4-field struct; this file
/// broadens coverage to a diverse matrix so the whole path is regression-proof.
///
/// For every case we:
///   1. register the custom struct DataType,
///   2. expose a struct-valued data-source node,
///   3. have the client read it back and verify **every** field, then
///   4. write a modified struct, verify the server's `onWrite` received it
///      fully typed, and re-read to confirm the change is reflected.
void main() {
  const readTimeout = Duration(seconds: 10);

  group('Custom-struct data-source read/write matrix', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    /// Registers [schema] as a custom struct type, exposes a writable
    /// data-source node backed by [initial], reads it back (checked by
    /// [checkRead]), writes [toWrite] (server-side backing checked by
    /// [checkBacking]), then re-reads (checked by [checkReread], defaulting to
    /// [checkBacking]).
    Future<void> runCase({
      required NodeId typeId,
      required NodeId nodeId,
      required String browseName,
      required DynamicValue schema,
      required DynamicValue initial,
      required DynamicValue toWrite,
      required void Function(DynamicValue read) checkRead,
      required void Function(DynamicValue written) checkBacking,
      void Function(DynamicValue reread)? checkReread,
    }) async {
      server.addCustomType(typeId, schema);
      server.addDataTypeNode(typeId, schema.name ?? browseName, displayName: LocalizedText(browseName, 'en-US'));

      DynamicValue backing = initial;
      server.addDataSourceVariableNode(
        nodeId,
        browseName: browseName,
        typeId: typeId,
        onRead: () => backing,
        onWrite: (value) async => backing = value,
      );

      // (1) read back the initial value and verify every field.
      final r = await client.read(nodeId).timeout(readTimeout);
      expect(r.isObject, isTrue, reason: 'read of $browseName should be a struct');
      expect(r.typeId, typeId, reason: 'read typeId should be the custom type');
      checkRead(r);

      // (2) write a modified struct; server decodes it against the schema.
      await client.write(nodeId, toWrite).timeout(readTimeout);
      expect(backing.isObject, isTrue, reason: 'onWrite of $browseName should receive a struct');
      checkBacking(backing);

      // (3) re-read reflects the new backing state.
      final r2 = await client.read(nodeId).timeout(readTimeout);
      (checkReread ?? checkBacking)(r2);
    }

    DynamicValue scalarField(NodeId type, dynamic v) => DynamicValue(value: v, typeId: type);

    // ---- Every scalar leaf type, one struct per type ---------------------

    test('Boolean field (true -> false)', () async {
      final t = NodeId.fromString(1, 'M_Bool');
      DynamicValue mk(bool v) {
        final s = DynamicValue(name: 'M_Bool', typeId: t);
        s['flag'] = scalarField(NodeId.boolean, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.bool'),
        browseName: 'BoolStruct',
        schema: mk(false),
        initial: mk(true),
        toWrite: mk(false),
        checkRead: (r) => expect(r['flag'].value, isTrue),
        checkBacking: (b) {
          expect(b['flag'].value, isFalse);
          expect(b['flag'].value, isA<bool>());
        },
      );
    });

    test('SByte field (min/max edges: 127 -> -128)', () async {
      final t = NodeId.fromString(1, 'M_SByte');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_SByte', typeId: t);
        s['v'] = scalarField(NodeId.sbyte, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.sbyte'),
        browseName: 'SByteStruct',
        schema: mk(0),
        initial: mk(127),
        toWrite: mk(-128),
        checkRead: (r) => expect(r['v'].value, 127),
        checkBacking: (b) {
          expect(b['v'].value, -128);
          expect(b['v'].value, isA<int>());
        },
      );
    });

    test('Byte field (0 -> 255)', () async {
      final t = NodeId.fromString(1, 'M_Byte');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_Byte', typeId: t);
        s['v'] = scalarField(NodeId.byte, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.byte'),
        browseName: 'ByteStruct',
        schema: mk(0),
        initial: mk(0),
        toWrite: mk(255),
        checkRead: (r) => expect(r['v'].value, 0),
        checkBacking: (b) => expect(b['v'].value, 255),
      );
    });

    test('Int16 field (min/max: 32767 -> -32768)', () async {
      final t = NodeId.fromString(1, 'M_Int16');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_Int16', typeId: t);
        s['v'] = scalarField(NodeId.int16, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.int16'),
        browseName: 'Int16Struct',
        schema: mk(0),
        initial: mk(32767),
        toWrite: mk(-32768),
        checkRead: (r) => expect(r['v'].value, 32767),
        checkBacking: (b) => expect(b['v'].value, -32768),
      );
    });

    test('UInt16 field (0 -> 65535)', () async {
      final t = NodeId.fromString(1, 'M_UInt16');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_UInt16', typeId: t);
        s['v'] = scalarField(NodeId.uint16, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.uint16'),
        browseName: 'UInt16Struct',
        schema: mk(0),
        initial: mk(0),
        toWrite: mk(65535),
        checkRead: (r) => expect(r['v'].value, 0),
        checkBacking: (b) => expect(b['v'].value, 65535),
      );
    });

    test('Int32 field (min/max: 2147483647 -> -2147483648)', () async {
      final t = NodeId.fromString(1, 'M_Int32');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_Int32', typeId: t);
        s['v'] = scalarField(NodeId.int32, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.int32'),
        browseName: 'Int32Struct',
        schema: mk(0),
        initial: mk(2147483647),
        toWrite: mk(-2147483648),
        checkRead: (r) => expect(r['v'].value, 2147483647),
        checkBacking: (b) => expect(b['v'].value, -2147483648),
      );
    });

    test('UInt32 field (0 -> 4294967295)', () async {
      final t = NodeId.fromString(1, 'M_UInt32');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_UInt32', typeId: t);
        s['v'] = scalarField(NodeId.uint32, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.uint32'),
        browseName: 'UInt32Struct',
        schema: mk(0),
        initial: mk(0),
        toWrite: mk(4294967295),
        checkRead: (r) => expect(r['v'].value, 0),
        checkBacking: (b) => expect(b['v'].value, 4294967295),
      );
    });

    test('Int64 field (min/max: 9223372036854775807 -> -9223372036854775808)', () async {
      final t = NodeId.fromString(1, 'M_Int64');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_Int64', typeId: t);
        s['v'] = scalarField(NodeId.int64, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.int64'),
        browseName: 'Int64Struct',
        schema: mk(0),
        initial: mk(9223372036854775807),
        toWrite: mk(-9223372036854775808),
        checkRead: (r) => expect(r['v'].value, 9223372036854775807),
        checkBacking: (b) => expect(b['v'].value, -9223372036854775808),
      );
    });

    test('UInt64 field (0 -> 9223372036854775807, the max Dart int)', () async {
      // NB: OPC UA UInt64 spans 0..2^64-1, but Dart's `int` is signed 64-bit,
      // so unsigned values above 2^63-1 cannot be represented as a positive
      // Dart int. That is a Dart language limitation, not a limitation of this
      // path; we exercise the largest representable positive value here.
      final t = NodeId.fromString(1, 'M_UInt64');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_UInt64', typeId: t);
        s['v'] = scalarField(NodeId.uint64, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.uint64'),
        browseName: 'UInt64Struct',
        schema: mk(0),
        initial: mk(0),
        toWrite: mk(9223372036854775807),
        checkRead: (r) => expect(r['v'].value, 0),
        checkBacking: (b) => expect(b['v'].value, 9223372036854775807),
      );
    });

    test('Float field (round-trips exactly; subnormal/negative edges)', () async {
      final t = NodeId.fromString(1, 'M_Float');
      DynamicValue mk(double v) {
        final s = DynamicValue(name: 'M_Float', typeId: t);
        s['v'] = scalarField(NodeId.float, v);
        return s;
      }

      // 0.5 is exactly representable in float32; the written value is the
      // smallest positive float32 subnormal (1.401298464324817e-45), which must
      // survive the float32 encode/decode without flushing to zero.
      const subnormalF32 = 1.401298464324817e-45;
      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.float'),
        browseName: 'FloatStruct',
        schema: mk(0.0),
        initial: mk(0.5),
        toWrite: mk(subnormalF32),
        checkRead: (r) => expect((r['v'].value as num).toDouble(), 0.5),
        checkBacking: (b) => expect((b['v'].value as num).toDouble(), subnormalF32),
      );
    });

    test('Double field (exact round-trip of a specific value)', () async {
      final t = NodeId.fromString(1, 'M_Double');
      DynamicValue mk(double v) {
        final s = DynamicValue(name: 'M_Double', typeId: t);
        s['v'] = scalarField(NodeId.double, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.double'),
        browseName: 'DoubleStruct',
        schema: mk(0.0),
        initial: mk(2.718281828459045),
        toWrite: mk(-1.7976931348623157e308),
        checkRead: (r) => expect(r['v'].value, 2.718281828459045),
        checkBacking: (b) => expect(b['v'].value, -1.7976931348623157e308),
      );
    });

    test('String field (non-empty -> empty)', () async {
      final t = NodeId.fromString(1, 'M_String');
      DynamicValue mk(String v) {
        final s = DynamicValue(name: 'M_String', typeId: t);
        s['v'] = scalarField(NodeId.uastring, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.string'),
        browseName: 'StringStruct',
        schema: mk(''),
        initial: mk('hello world'),
        toWrite: mk(''),
        checkRead: (r) => expect(r['v'].value, 'hello world'),
        checkBacking: (b) {
          expect(b['v'].value, '');
          expect(b['v'].value, isA<String>());
        },
      );
    });

    // ---- Mixed multi-field struct (10 fields) ---------------------------

    test('Mixed 10-field struct (ints, floats, bool, string)', () async {
      final t = NodeId.fromString(1, 'M_Mixed');
      DynamicValue mk({
        required bool enabled,
        required int b,
        required int sb,
        required int i16,
        required int u16,
        required int i32,
        required int u32,
        required int i64,
        required double f,
        required double d,
        required String label,
      }) {
        final s = DynamicValue(name: 'M_Mixed', typeId: t);
        s['Enabled'] = scalarField(NodeId.boolean, enabled);
        s['B'] = scalarField(NodeId.byte, b);
        s['SB'] = scalarField(NodeId.sbyte, sb);
        s['I16'] = scalarField(NodeId.int16, i16);
        s['U16'] = scalarField(NodeId.uint16, u16);
        s['I32'] = scalarField(NodeId.int32, i32);
        s['U32'] = scalarField(NodeId.uint32, u32);
        s['I64'] = scalarField(NodeId.int64, i64);
        s['F'] = scalarField(NodeId.float, f);
        s['D'] = scalarField(NodeId.double, d);
        s['Label'] = scalarField(NodeId.uastring, label);
        return s;
      }

      final schema = mk(enabled: false, b: 0, sb: 0, i16: 0, u16: 0, i32: 0, u32: 0, i64: 0, f: 0.0, d: 0.0, label: '');
      final initial = mk(
        enabled: true,
        b: 200,
        sb: -5,
        i16: -1000,
        u16: 40000,
        i32: 123456,
        u32: 3000000000,
        i64: 5000000000,
        f: 1.5,
        d: 3.5,
        label: 'start',
      );
      final modified = mk(
        enabled: false,
        b: 1,
        sb: 6,
        i16: 1000,
        u16: 1,
        i32: -123456,
        u32: 1,
        i64: -5000000000,
        f: -2.25,
        d: -6.5,
        label: 'end',
      );

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.mixed'),
        browseName: 'MixedStruct',
        schema: schema,
        initial: initial,
        toWrite: modified,
        checkRead: (r) {
          expect(r.asObject.keys.length, 11);
          expect(r['Enabled'].value, true);
          expect(r['B'].value, 200);
          expect(r['SB'].value, -5);
          expect(r['I16'].value, -1000);
          expect(r['U16'].value, 40000);
          expect(r['I32'].value, 123456);
          expect(r['U32'].value, 3000000000);
          expect(r['I64'].value, 5000000000);
          expect((r['F'].value as num).toDouble(), 1.5);
          expect(r['D'].value, 3.5);
          expect(r['Label'].value, 'start');
        },
        checkBacking: (b) {
          expect(b['Enabled'].value, false);
          expect(b['B'].value, 1);
          expect(b['SB'].value, 6);
          expect(b['I16'].value, 1000);
          expect(b['U16'].value, 1);
          expect(b['I32'].value, -123456);
          expect(b['U32'].value, 1);
          expect(b['I64'].value, -5000000000);
          expect((b['F'].value as num).toDouble(), -2.25);
          expect(b['D'].value, -6.5);
          expect(b['Label'].value, 'end');
        },
      );
    });

    // ---- Single-field struct -------------------------------------------

    test('Single-field struct (one Int32)', () async {
      final t = NodeId.fromString(1, 'M_Single');
      DynamicValue mk(int v) {
        final s = DynamicValue(name: 'M_Single', typeId: t);
        s['only'] = scalarField(NodeId.int32, v);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.single'),
        browseName: 'SingleStruct',
        schema: mk(0),
        initial: mk(42),
        toWrite: mk(-7),
        checkRead: (r) {
          expect(r.asObject.keys.length, 1);
          expect(r['only'].value, 42);
        },
        checkBacking: (b) => expect(b['only'].value, -7),
      );
    });

    // ---- String-heavy struct (empty + long strings) --------------------

    test('String-heavy struct (empty, short, long strings)', () async {
      final t = NodeId.fromString(1, 'M_Strings');
      final longStr = 'x' * 1000;
      DynamicValue mk(String a, String b, String c) {
        final s = DynamicValue(name: 'M_Strings', typeId: t);
        s['a'] = scalarField(NodeId.uastring, a);
        s['b'] = scalarField(NodeId.uastring, b);
        s['c'] = scalarField(NodeId.uastring, c);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.strings'),
        browseName: 'StringsStruct',
        schema: mk('', '', ''),
        initial: mk('', 'short', longStr),
        toWrite: mk('now-set', '', 'unicode: éà中文'),
        checkRead: (r) {
          expect(r['a'].value, '');
          expect(r['b'].value, 'short');
          expect(r['c'].value, longStr);
          expect((r['c'].value as String).length, 1000);
        },
        checkBacking: (b) {
          expect(b['a'].value, 'now-set');
          expect(b['b'].value, '');
          expect(b['c'].value, 'unicode: éà中文');
        },
      );
    });

    // ---- Field-order / value-range edges in one struct -----------------

    test('Edge-value struct (negatives, zero, empty string, false)', () async {
      final t = NodeId.fromString(1, 'M_Edges');
      DynamicValue mk({required int i32, required double d, required bool flag, required String s}) {
        final o = DynamicValue(name: 'M_Edges', typeId: t);
        o['i32'] = scalarField(NodeId.int32, i32);
        o['d'] = scalarField(NodeId.double, d);
        o['flag'] = scalarField(NodeId.boolean, flag);
        o['s'] = scalarField(NodeId.uastring, s);
        return o;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.edges'),
        browseName: 'EdgeStruct',
        schema: mk(i32: 0, d: 0.0, flag: false, s: ''),
        initial: mk(i32: -1, d: -0.0, flag: false, s: ''),
        // 5e-324 is Double.minPositive (a subnormal double).
        toWrite: mk(i32: -2147483648, d: 5e-324, flag: false, s: ''),
        checkRead: (r) {
          expect(r['i32'].value, -1);
          expect(r['d'].value, 0.0);
          expect(r['flag'].value, false);
          expect(r['s'].value, '');
        },
        checkBacking: (b) {
          expect(b['i32'].value, -2147483648);
          expect(b['d'].value, 5e-324);
          expect(b['flag'].value, false);
          expect(b['s'].value, '');
        },
      );
    });

    // ---- Write robustness: a value that must round-trip exactly --------

    test('Write robustness: exact double round-trip with a default-left field', () async {
      final t = NodeId.fromString(1, 'M_Robust');
      DynamicValue mk(double v, int keep) {
        final s = DynamicValue(name: 'M_Robust', typeId: t);
        s['precise'] = scalarField(NodeId.double, v);
        s['keep'] = scalarField(NodeId.int32, keep);
        return s;
      }

      const precise = 0.1 + 0.2; // 0.30000000000000004, exercises exactness
      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.robust'),
        browseName: 'RobustStruct',
        schema: mk(0.0, 0),
        initial: mk(1.0, 55),
        // 'keep' left at its schema default (0) to prove defaulted fields write.
        toWrite: mk(precise, 0),
        checkRead: (r) {
          expect(r['precise'].value, 1.0);
          expect(r['keep'].value, 55);
        },
        checkBacking: (b) {
          expect(b['precise'].value, precise);
          expect(b['keep'].value, 0);
        },
      );
    });

    // ---- Nested struct (struct-in-struct) ------------------------------

    test('Nested struct (a struct field whose value is itself a struct)', () async {
      final inner = NodeId.fromString(1, 'M_Inner');
      final outer = NodeId.fromString(1, 'M_Outer');
      DynamicValue mkInner(int x, double y) {
        final s = DynamicValue(name: 'M_Inner', typeId: inner);
        s['x'] = scalarField(NodeId.int32, x);
        s['y'] = scalarField(NodeId.double, y);
        return s;
      }

      DynamicValue mkOuter(int id, int ix, double iy, String label) {
        final s = DynamicValue(name: 'M_Outer', typeId: outer);
        s['id'] = scalarField(NodeId.int32, id);
        s['inner'] = mkInner(ix, iy);
        s['label'] = scalarField(NodeId.uastring, label);
        return s;
      }

      // The inner type is registered AND its DataType node published
      // automatically: addCustomType recurses into struct-valued members and
      // publishes each nested type's node (a HasSubtype child of Structure).
      // This is required for reads — a dynamic client resolves every field
      // type's DataTypeDefinition over the wire, so the inner type's node must
      // exist or the read fails BadNodeIdUnknown. We deliberately do NOT
      // pre-register `inner` here; runCase only registers the outer type, and
      // the nested read below proves the inner node was auto-published.
      await runCase(
        typeId: outer,
        nodeId: NodeId.fromString(1, 'ds.nested'),
        browseName: 'NestedStruct',
        schema: mkOuter(0, 0, 0.0, ''),
        initial: mkOuter(1, 10, 2.5, 'outer'),
        toWrite: mkOuter(2, -10, -2.5, 'changed'),
        checkRead: (r) {
          expect(r['id'].value, 1);
          expect(r['inner'].isObject, isTrue, reason: 'inner should decode as a nested struct');
          expect(r['inner']['x'].value, 10);
          expect(r['inner']['y'].value, 2.5);
          expect(r['label'].value, 'outer');
        },
        checkBacking: (b) {
          expect(b['id'].value, 2);
          expect(b['inner'].isObject, isTrue);
          expect(b['inner']['x'].value, -10);
          expect(b['inner']['y'].value, -2.5);
          expect(b['label'].value, 'changed');
        },
      );
    });

    // ---- Doubly-nested struct (struct-in-struct-in-struct) -------------

    test('Doubly-nested struct (L1 contains L2 contains L3)', () async {
      final l3 = NodeId.fromString(1, 'M_L3');
      final l2 = NodeId.fromString(1, 'M_L2');
      final l1 = NodeId.fromString(1, 'M_L1');

      // Deepest leaf struct.
      DynamicValue mkL3(int n, bool flag) {
        final s = DynamicValue(name: 'M_L3', typeId: l3);
        s['n'] = scalarField(NodeId.int32, n);
        s['flag'] = scalarField(NodeId.boolean, flag);
        return s;
      }

      // Middle struct: a scalar plus an L3.
      DynamicValue mkL2(double ratio, int n, bool flag) {
        final s = DynamicValue(name: 'M_L2', typeId: l2);
        s['ratio'] = scalarField(NodeId.double, ratio);
        s['leaf'] = mkL3(n, flag);
        return s;
      }

      // Top struct: a scalar plus an L2 (which itself carries an L3).
      DynamicValue mkL1(String tag, double ratio, int n, bool flag) {
        final s = DynamicValue(name: 'M_L1', typeId: l1);
        s['tag'] = scalarField(NodeId.uastring, tag);
        s['mid'] = mkL2(ratio, n, flag);
        return s;
      }

      // Only the top type is registered. addCustomType recurses the whole
      // chain (L1 -> L2 -> L3), auto-publishing the DataType node at every
      // level; a read that decodes all three levels proves the transitive
      // closure was published, not just the first level down.
      await runCase(
        typeId: l1,
        nodeId: NodeId.fromString(1, 'ds.nested2'),
        browseName: 'DoublyNestedStruct',
        schema: mkL1('', 0.0, 0, false),
        initial: mkL1('root', 1.5, 42, true),
        toWrite: mkL1('root2', -1.5, -42, false),
        checkRead: (r) {
          expect(r['tag'].value, 'root');
          expect(r['mid'].isObject, isTrue, reason: 'L2 should decode as a struct');
          expect(r['mid']['ratio'].value, 1.5);
          expect(r['mid']['leaf'].isObject, isTrue, reason: 'L3 should decode as a struct');
          expect(r['mid']['leaf']['n'].value, 42);
          expect(r['mid']['leaf']['flag'].value, isTrue);
        },
        checkBacking: (b) {
          expect(b['tag'].value, 'root2');
          expect(b['mid'].isObject, isTrue);
          expect(b['mid']['ratio'].value, -1.5);
          expect(b['mid']['leaf'].isObject, isTrue);
          expect(b['mid']['leaf']['n'].value, -42);
          expect(b['mid']['leaf']['flag'].value, isFalse);
        },
      );
    });

    // ---- Array-valued field inside a struct ----------------------------

    test('Array-valued field inside a struct (Int32[])', () async {
      final t = NodeId.fromString(1, 'M_ArrField');
      DynamicValue mk(List<int> arr, String tag) {
        final s = DynamicValue(name: 'M_ArrField', typeId: t);
        s['values'] = DynamicValue.fromList([
          for (final v in arr) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32);
        s['tag'] = scalarField(NodeId.uastring, tag);
        return s;
      }

      await runCase(
        typeId: t,
        nodeId: NodeId.fromString(1, 'ds.arrfield'),
        browseName: 'ArrayFieldStruct',
        schema: mk([0], ''),
        initial: mk([1, 2, 3], 'nums'),
        toWrite: mk([10, 20, 30, 40], 'more'),
        checkRead: (r) {
          expect(r['values'].isArray, isTrue, reason: 'array member should decode as an array');
          expect(r['values'].asArray.map((e) => e.value).toList(), [1, 2, 3]);
          expect(r['tag'].value, 'nums');
        },
        checkBacking: (b) {
          expect(b['values'].isArray, isTrue);
          expect(b['values'].asArray.map((e) => e.value).toList(), [10, 20, 30, 40]);
          expect(b['tag'].value, 'more');
        },
      );
    });
  });
}
