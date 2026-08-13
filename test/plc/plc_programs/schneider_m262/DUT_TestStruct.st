// DUT for the OPC UA test fixture struct (M262 / EcoStruxure Machine Expert).
//
// The M262 OPC UA server CAN publish structured data types, so TestStruct is
// present on this controller (supportsComplexTypes = true).
//
// The OPC UA BrowseName of the *instance* is "TestStruct" (declared in
// GVL_Test). Field names + scalar types must match what the tests expect,
// resolved by BrowseName:
//   Id      : DINT   -> OPC UA Int32
//   Value   : REAL   -> OPC UA Float
//   Enabled : BOOL   -> OPC UA Boolean
//   Label   : STRING -> OPC UA String
//
// Create this as a DUT object named "ST_TestStruct" in Machine Expert.
TYPE ST_TestStruct :
STRUCT
    Id      : DINT;
    Value   : REAL;
    Enabled : BOOL;
    Label   : STRING;
END_STRUCT
END_TYPE
