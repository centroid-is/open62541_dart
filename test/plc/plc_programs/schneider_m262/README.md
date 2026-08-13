# Modicon M262 (Schneider) — EcoStruxure Machine Expert deploy guide

PLC-side program that places the shared OPC UA test fixture (see
`../../plc_fixture.dart`) on a Schneider **Modicon M262** controller and
publishes it with the controller's built-in **OPC UA Server**.

> **Full fixture, including `TestStruct`.** The M262 OPC UA server supports
> **structured data types**, so the struct is present here
> (`supportsComplexTypes = true`).

> You cannot compile these files on this machine — they are plain IEC 61131-3
> Structured Text sources. Create the objects in **EcoStruxure Machine Expert**,
> paste the declarations/implementation in, then build and download to the
> controller.

## Files

| File | Object | Purpose |
|------|--------|---------|
| `DUT_TestStruct.st` | DUT (STRUCT) `ST_TestStruct` | `{ Id:DINT; Value:REAL; Enabled:BOOL; Label:STRING }` — type behind `TestStruct`. |
| `GVL_Test.st`       | Global Variable List `GVL_Test` | Declares the scalar fixture **plus** the `TestStruct` instance. |
| `PLC_PRG.st`        | PROGRAM `PLC_PRG`               | Increments `Counter` every cycle, seeds initial values. |

## 1. Create the project

1. In **EcoStruxure Machine Expert**, create a project for your **M262**
   controller.
2. Add a **DUT** named `ST_TestStruct` and paste the `TYPE … END_TYPE` body from
   `DUT_TestStruct.st`.
3. Add a **GVL** named `GVL_Test` and paste the `VAR_GLOBAL … END_VAR` body from
   `GVL_Test.st`.
4. Add/open **PLC_PRG** and paste the declaration + implementation from
   `PLC_PRG.st`. Assign `PLC_PRG` to a **cyclic task** (e.g. `MAST`) so `Counter`
   increments.
5. **Build** the application.

## 2. Select the OPC UA symbols (including the struct)

1. Add/open the **Symbol Configuration** object (right-click **Application → Add
   Object → Symbol Configuration**) and enable **"Support OPC UA features"**.
2. **Build** so the symbol list populates, then **tick each fixture variable**
   under `GVL_Test`: the scalars (`TestBool … Setpoint`), `Counter`, `TestArray`,
   and the struct instance **`TestStruct`**. Give `Counter` read access; the rest
   read/write.
3. **Exposing the structured type:** tick `TestStruct` itself. The M262 publishes
   it as an OPC UA structure whose members (`Id/Value/Enabled/Label`) appear as
   child nodes / structure fields; the `ST_TestStruct` **data type** is published
   into the server's type dictionary automatically. If the grid lets you expand
   `TestStruct`, make sure the members are included (they inherit the parent's
   selection). Verify in **UaExpert** that `TestStruct` shows up as a structured
   value with the four fields — not a flat blob.
   - Symbol-selection quirk: only referenced/checked variables get compiled into
     the symbol set. `PLC_PRG` seeds every member, so all are reachable; still
     confirm each is ticked after a rebuild.
4. Ensure the controller's **OPC UA Server** is **enabled**, rebuild, and
   **download** to the controller.

## 3. Authentication (username / password)

The suite defaults to user **`tester`** / password **`test-pass-1`**
(from `../../plc_config.dart`) and connects with **username auth over an
UNENCRYPTED channel** (security policy *None*, `allowUnencryptedPassword`).

1. In Machine Expert, open the controller's **User Management / Security**
   settings and create a user **`tester`** with password **`test-pass-1`**.
2. In the **OPC UA Server** settings, allow the **None** security policy /
   username sign-in (disable "require encryption") so the unencrypted username
   login the tests use is accepted. Production would require encryption; the
   tests intentionally do not.

Use different creds on real hardware via the env vars below.

## 4. Endpoint URL

```
opc.tcp://<PLC-IP>:4840
```

The M262 OPC UA server listens on TCP **4840** by default. Nodes are resolved by
BrowseName under *Objects*, so the containing path does not matter.

## 5. Point the tests at it

```bash
export PLC_M262_URL='opc.tcp://192.168.0.12:4840'
export PLC_M262_USER='tester'          # optional; defaults to tester
export PLC_M262_PASS='test-pass-1'     # optional; defaults to test-pass-1
# optional tuning:
export PLC_M262_MAX_SESSIONS=5         # default 5
export PLC_M262_SESSION_TIMEOUT_MS=20000
```

Set `PLC_M262_URL=emulator` to run against the local asyncua emulator instead of
hardware.

## Session limits

- The M262 OPC UA server allows a small number of concurrent sessions (default
  budget here is **5**). The suite is still **deliberately single-session**:
  every test file shares one session (`setUpAll`/`tearDownAll`), guarded by a
  process-wide budget check (`../../plc_session.dart`).
- The short requested `sessionTimeout` (20 s) lets the controller reap an
  abandoned session quickly instead of holding the slot for minutes.
- Sample monitored items no faster than the task cycle; the server samples at the
  task rate.
