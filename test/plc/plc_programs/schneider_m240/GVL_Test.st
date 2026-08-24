// GVL_Test — OPC UA test fixture for Modicon M240 / M241 (EcoStruxure Machine
// Expert). SCALARS ONLY: the M240/M241 OPC UA server exposes flat symbols and
// cannot publish structured (DUT) types, so TestStruct is intentionally OMITTED
// here (matches supportsComplexTypes = false in ../../plc_config.dart).
//
// Mirrors test/plc/plc_fixture.dart. BrowseNames and IEC types below MUST NOT
// change; the tests resolve every node by BrowseName.
//
// Publishing is NOT done with pragmas on the M241 — you select these variables
// in the OPC UA Symbol Configuration in Machine Expert (see README.md).
// Paste this declaration into a Global Variable List named "GVL_Test".
VAR_GLOBAL
    // --- Scalars (read/write) ---------------------------------------------
    TestBool    : BOOL;                 // -> OPC UA Boolean
    TestInt     : INT;                  // 16-bit -> OPC UA Int16
    TestDint    : DINT;                 // 32-bit -> OPC UA Int32
    TestReal    : REAL;                 // float32 -> OPC UA Float
    TestLreal   : LREAL;                // float64 -> OPC UA Double
    TestString  : STRING;               // -> OPC UA String

    // --- Writable setpoint (REAL) -----------------------------------------
    Setpoint    : REAL;

    // --- Free-running liveness counter (DINT) -----------------------------
    // Incremented by PLC_PRG every cycle. Read-only from a client's view.
    Counter     : DINT;

    // --- Array[0..9] OF DINT (read/write) ---------------------------------
    TestArray   : ARRAY[0..9] OF DINT;
END_VAR
