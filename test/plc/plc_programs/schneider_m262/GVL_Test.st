// GVL_Test — OPC UA test fixture for Modicon M262 (EcoStruxure Machine Expert).
// FULL fixture INCLUDING the TestStruct DUT: the M262 OPC UA server supports
// structured data types (matches supportsComplexTypes = true).
//
// Mirrors test/plc/plc_fixture.dart. BrowseNames and IEC types below MUST NOT
// change; the tests resolve every node by BrowseName.
//
// Publishing is done by selecting these variables in the OPC UA Symbol
// Configuration in Machine Expert (see README.md), not with pragmas.
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

    // --- Struct instance (read/write) -------------------------------------
    // Published as an OPC UA structured type (Id/Value/Enabled/Label members).
    TestStruct  : ST_TestStruct;
END_VAR
