// Canonical definition of the test fixture that lives on every PLC.
//
// Single source of truth mirrored by:
//   - the asyncua emulators   (test/plc/emulators/*.py)
//   - the PLC programs         (test/plc/plc_programs/*)
// Tests resolve these by BrowseName (see plc_session.dart), so the containing
// namespace/path differs per vendor without affecting the tests.

import 'package:open62541/open62541.dart';

/// An OPC UA scalar the fixture exposes, with the NodeId type used to write it
/// and two round-trip test values.
class ScalarVar {
  ScalarVar(this.name, this.typeId, this.writeA, this.writeB, {this.tolerance = 0});

  /// BrowseName on every PLC (and emulator).
  final String name;

  /// The OPC UA scalar type used when writing (matches the PLC declaration).
  final NodeId typeId;

  /// Two distinct values written/read back during the round-trip test.
  final Object writeA;
  final Object writeB;

  /// Absolute tolerance for float compares (REAL/LREAL need it; exact types 0).
  final num tolerance;
}

class StructField {
  StructField(this.name, this.typeId, this.value);
  final String name;
  final NodeId typeId;
  final Object value;
}

/// The fixture. Fields are `final` (NodeId statics are getters, not const).
class PlcFixture {
  // --- Scalars (present on ALL PLCs, read/write) ----------------------------
  static final bool_ = ScalarVar('TestBool', NodeId.boolean, true, false);
  static final int16 = ScalarVar('TestInt', NodeId.int16, 12345, -12345);
  static final int32 = ScalarVar('TestDint', NodeId.int32, 2000000000, -2000000000);
  static final real = ScalarVar('TestReal', NodeId.float, 3.5, -12.25, tolerance: 1e-3);
  static final lreal = ScalarVar('TestLreal', NodeId.double, 3.141592653589793, -2.718281828, tolerance: 1e-9);
  static final string = ScalarVar('TestString', NodeId.uastring, 'hello-plc', 'Ω≈ç√-2');

  /// Writable setpoint (REAL) — used by the write/timing tests.
  static final setpoint = ScalarVar('Setpoint', NodeId.float, 42.5, 7.25, tolerance: 1e-3);

  static final scalars = [bool_, int16, int32, real, lreal, string, setpoint];

  /// Free-running counter (DINT), incremented by the PLC every cycle. Read-only;
  /// proves liveness and drives subscription/read timing measurements.
  static const counterName = 'Counter';

  // --- Array (present on ALL PLCs, read/write) ------------------------------
  static const arrayName = 'TestArray'; // ARRAY[0..9] OF DINT
  static const arrayLength = 10;
  static final arrayTypeId = NodeId.int32;

  // --- Struct (TwinCAT / M262 ONLY) -----------------------------------------
  static const structName = 'TestStruct';
  static final structFields = [
    StructField('Id', NodeId.int32, 77),
    StructField('Value', NodeId.float, 19.5),
    StructField('Enabled', NodeId.boolean, true),
    StructField('Label', NodeId.uastring, 'tank-1'),
  ];
}
