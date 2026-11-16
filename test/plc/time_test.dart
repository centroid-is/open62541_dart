// TwinCAT `TIME` read/write (MAIN.timeTest).
//
// TwinCAT TF6100 publishes a TIME under its own DataType (ns=3;i=3005, a
// subtype of Int64) and sends the value as an Int64 of milliseconds. The PLC
// variable itself is 32-bit (UDINT ms), so the server range-checks writes:
// 0 .. 4294967295 ms (T#49D17H2M47S295MS) is accepted, anything outside is
// Bad_OutOfRange. Int32 is refused with Bad_TypeMismatch; Int64 and UInt32
// are accepted. A value read and written back (typeId = the TIME DataType)
// goes as Int64: Client.write resolves the DataType to its built-in type.
//
// Declare it on the PLC (see plc_programs/twincat/MAIN.TcPOU):
//   {attribute 'OPC.UA.DA' := '1'}
//   timeTest : TIME;
//
//   PLC_TWINCAT_URL=opc.tcp://10.50.10.10:4840 dart test --run-skipped test/plc/time_test.dart
@Tags(['plc'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'plc_config.dart';
import 'plc_session.dart';

const _name = 'timeTest';
const _maxTimeMs = 0xFFFFFFFF; // TIME is a 32-bit count of milliseconds

void main() {
  final cfg = PlcConfig.fromEnv(PlcTarget.twincat);
  tearDownAll(PlcSession.shutdownEmulators);

  if (cfg == null) {
    test('TwinCAT not configured', () {}, skip: 'Set PLC_TWINCAT_URL.');
    return;
  }

  group('TIME [${cfg.name}]', () {
    late PlcSession s;
    NodeId? node;
    setUpAll(() async {
      s = await PlcSession.open(cfg);
      node = await s.tryNode(_name);
    });
    tearDownAll(() async {
      // Leave the PLC as we found it most of the time: zero.
      if (node != null) await s.client.write(node!, _time(0));
      await s.dispose();
    });

    NodeId? requireNode() {
      if (node == null) markTestSkipped('$_name is not published on ${cfg.name}');
      return node;
    }

    test('reads as an int of milliseconds with the TwinCAT TIME DataType', () async {
      final n = requireNode();
      if (n == null) return;
      final v = await s.client.read(n);
      expect(v.value, isA<int>());
      expect(v.typeId?.namespace, isNot(0), reason: 'TwinCAT exposes TIME under a vendor DataType');
      expect((await s.client.readValue(n)).value.typeId, NodeId.int64, reason: 'wire type');
    });

    test('round-trips values across the TIME range', () async {
      final n = requireNode();
      if (n == null) return;
      for (final ms in [1500, 0, 1, 60 * 60 * 1000, 25 * 24 * 60 * 60 * 1000, _maxTimeMs]) {
        await s.client.write(n, _time(ms));
        final got = await s.client.read(n);
        expect(got.value, ms, reason: 'wrote T#${ms}MS');
        // Same value through readValue (status + timestamps).
        final dv = await s.client.readValue(n);
        expect(dv.statusCode, 0);
        expect(dv.value.value, ms);
      }
    });

    // Regression: read() reports TwinCAT's TIME DataType (ns=3;i=3005) as the
    // typeId, which write() used to refuse with "Unknown Namespace0Id value:
    // 3005". See test/write_vendor_datatype_test.dart.
    test('read -> change -> write back', () async {
      final n = requireNode();
      if (n == null) return;
      final v = await s.client.read(n);
      v.value = 7000;
      await s.client.write(n, v);
      expect((await s.client.read(n)).value, 7000);
    });

    test('a value built with the TIME DataType from read()', () async {
      final n = requireNode();
      if (n == null) return;
      final timeType = (await s.client.read(n)).typeId!;
      await s.client.write(n, DynamicValue(value: 8000, typeId: timeType));
      expect((await s.client.read(n)).value, 8000);
    });

    test('a Duration converts both ways', () async {
      final n = requireNode();
      if (n == null) return;
      const want = Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4);
      await s.client.write(n, _time(want.inMilliseconds));
      final got = Duration(milliseconds: (await s.client.read(n)).value as int);
      expect(got, want);
    });

    test('out-of-range values are refused and leave the value unchanged', () async {
      final n = requireNode();
      if (n == null) return;
      await s.client.write(n, _time(4242));
      for (final ms in [-1, _maxTimeMs + 1]) {
        await expectLater(
          s.client.write(n, _time(ms)),
          throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', 0x803C0000 /* Bad_OutOfRange */)),
          reason: 'T#${ms}MS',
        );
      }
      expect((await s.client.read(n)).value, 4242);
    });

    test('Int32 is refused (Bad_TypeMismatch); UInt32 is accepted', () async {
      final n = requireNode();
      if (n == null) return;
      await expectLater(
        s.client.write(n, DynamicValue(value: 10, typeId: NodeId.int32)),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', 0x80740000 /* Bad_TypeMismatch */)),
      );
      await s.client.write(n, DynamicValue(value: 2500, typeId: NodeId.uint32));
      expect((await s.client.read(n)).value, 2500);
    });
  });
}

/// A TIME value as TwinCAT expects it on the wire: Int64 milliseconds.
DynamicValue _time(int ms) => DynamicValue(value: ms, typeId: NodeId.int64);
