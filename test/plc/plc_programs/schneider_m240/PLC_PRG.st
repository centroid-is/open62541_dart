// PLC_PRG — cyclic program for the M240/M241 fixture.
// Assign this POU to a cyclic task (e.g. MAST) so Counter actually increments.
//
// Declaration part:
PROGRAM PLC_PRG
VAR
    bInit : BOOL := TRUE;
END_VAR

// Implementation part:
IF bInit THEN
    bInit := FALSE;
    GVL_Test.TestBool   := FALSE;
    GVL_Test.TestInt    := 0;
    GVL_Test.TestDint   := 0;
    GVL_Test.TestReal   := 0.0;
    GVL_Test.TestLreal  := 0.0;
    GVL_Test.TestString := '';
    GVL_Test.Setpoint   := 0.0;
    GVL_Test.Counter    := 0;
END_IF

// Liveness counter: increment every scan so clients can prove the program is
// running and measure read/subscription update timing. Wraps at the DINT limit.
GVL_Test.Counter := GVL_Test.Counter + 1;
