# Modicon M240 / M241 (Schneider) — EcoStruxure Machine Expert deploy guide

PLC-side program that places the shared OPC UA test fixture (see
`../../plc_fixture.dart`) on a Schneider **Modicon M240/M241** controller and
publishes it with the controller's built-in **OPC UA Server**.

> **Scalars only.** The M240/M241 OPC UA server exposes **flat symbols and cannot
> publish structured (DUT) types**, so `TestStruct` is intentionally absent here.
> This matches `supportsComplexTypes = false` for the `m240` target.

> You cannot compile these files on this machine — they are plain IEC 61131-3
> Structured Text sources. Create the objects in **EcoStruxure Machine Expert**
> and paste the declarations/implementation in, then build and download to the
> controller.

## Files

| File | Object | Purpose |
|------|--------|---------|
| `GVL_Test.st` | Global Variable List `GVL_Test` | Declares the scalar fixture (no struct). |
| `PLC_PRG.st`  | PROGRAM `PLC_PRG`               | Increments `Counter` every cycle, seeds initial values. |

## 1. Create the project

1. In **EcoStruxure Machine Expert**, create a project for your **M241** (or
   M240) controller.
2. Under **Application**, add a **GVL** named `GVL_Test` and paste the
   `VAR_GLOBAL … END_VAR` body from `GVL_Test.st`.
3. Add/open the **PLC_PRG** POU and paste the declaration + implementation from
   `PLC_PRG.st`. Ensure `PLC_PRG` is assigned to a **cyclic task** (e.g. `MAST`)
   so `Counter` increments.
4. **Build** the application.

## 2. Select the OPC UA symbols

The M241 does **not** use publish pragmas; you pick the symbols explicitly:

1. In the device tree, add/open the **Symbol Configuration** object (right-click
   **Application → Add Object → Symbol Configuration**). When prompted, enable
   **"Support OPC UA features"**.
2. **Build** once so the symbol list is populated, then in the Symbol
   Configuration grid **tick each fixture variable** under `GVL_Test`
   (`TestBool, TestInt, TestDint, TestReal, TestLreal, TestString, Setpoint,
   Counter, TestArray`). Give `Counter` read access; the others read/write.
   - Symbol-selection quirk: only variables that are **actually referenced/used**
     (or explicitly checked) get compiled into the symbol set — because
     `PLC_PRG` seeds every variable, they are all reachable; still verify each
     one is ticked after a rebuild, as the grid can drop unreferenced entries.
   - `TestArray` publishes as an array symbol (indices 0..9). There is **no**
     struct symbol — the M241 exposes flat symbols only.
3. Under the controller's **OPC UA Server** configuration, make sure the OPC UA
   server is **enabled**. Rebuild and **download** to the controller.
4. Browse the endpoint in **UaExpert** and confirm the BrowseNames match the
   fixture exactly.

## 3. Authentication (username / password)

The suite defaults to user **`tester`** / password **`test-pass-1`**
(from `../../plc_config.dart`) and connects with **username auth over an
UNENCRYPTED channel** (security policy *None*, `allowUnencryptedPassword`).

1. In Machine Expert, open the controller's **User Management / Security**
   settings and create a user **`tester`** with password **`test-pass-1`**
   (the OPC UA server authenticates against the controller user accounts).
2. In the **OPC UA Server** settings, allow the **None** security policy /
   username sign-in (disable "require encryption") so the unencrypted username
   login the tests use is accepted. For production you would require encryption;
   the tests intentionally do not.

Use different creds on real hardware by exporting the env vars below.

## 4. Endpoint URL

```
opc.tcp://<PLC-IP>:4840
```

The M241 OPC UA server listens on TCP **4840** by default. Nodes are resolved by
BrowseName under *Objects*, so the containing path does not matter.

## 5. Point the tests at it

```bash
export PLC_M240_URL='opc.tcp://192.168.0.11:4840'
export PLC_M240_USER='tester'          # optional; defaults to tester
export PLC_M240_PASS='test-pass-1'     # optional; defaults to test-pass-1
# optional tuning:
export PLC_M240_MAX_SESSIONS=4         # default 4 — HARD controller cap
export PLC_M240_SESSION_TIMEOUT_MS=20000
```

Set `PLC_M240_URL=emulator` to run against the local asyncua emulator instead of
hardware.

## Session limits — read this

- The M241 OPC UA server hard-caps at roughly **4 parallel sessions**, and having
  **more than one session at a time noticeably degrades performance**. The suite
  is therefore **deliberately single-session**: every test file shares one
  session (`setUpAll`/`tearDownAll`), and a process-wide budget guard makes an
  accidental over-open fail loudly (`../../plc_session.dart`).
- Keep `PLC_M240_MAX_SESSIONS` at **4** or lower; the default budget is 4.
- The short requested `sessionTimeout` (20 s) lets the controller reap an
  abandoned session in seconds instead of holding one of its 4 slots for minutes.
- Sample monitored items no faster than the task cycle; the OPC UA server samples
  at the task rate.
