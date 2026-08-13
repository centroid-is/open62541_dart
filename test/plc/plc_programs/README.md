# PLC programs — OPC UA test fixture

PLC-side programs (IEC 61131-3 Structured Text) that place the shared OPC UA test
fixture on three real controllers so the `open62541_dart` PLC integration suite
can run against hardware. Each vendor folder holds the ST source **and** a
`README.md` with vendor-specific deploy steps.

> These are the on-controller counterpart to the local emulators in
> `../emulators/plc_emulator.py`. All three are the same fixture, resolved by
> **BrowseName** — see the single source of truth in `../plc_fixture.dart`.

## The shared fixture

Every controller exposes these variables over OPC UA, with **exactly** these
BrowseNames and types:

| BrowseName   | IEC type            | OPC UA type      | Access | Notes |
|--------------|---------------------|------------------|--------|-------|
| `TestBool`   | `BOOL`              | Boolean          | R/W    | |
| `TestInt`    | `INT`               | Int16            | R/W    | 16-bit |
| `TestDint`   | `DINT`              | Int32            | R/W    | 32-bit |
| `TestReal`   | `REAL`              | Float            | R/W    | float32 |
| `TestLreal`  | `LREAL`            | Double           | R/W    | float64 |
| `TestString` | `STRING`            | String           | R/W    | |
| `Setpoint`   | `REAL`              | Float            | R/W    | writable setpoint |
| `Counter`    | `DINT`              | Int32            | R (only) | PLC **increments it every cycle** (liveness + timing) |
| `TestArray`  | `ARRAY[0..9] OF DINT` | Int32[10]      | R/W    | |
| `TestStruct` | `ST_TestStruct` DUT | structured type  | R/W    | **TwinCAT & M262 only** — `{ Id:DINT; Value:REAL; Enabled:BOOL; Label:STRING }` |

`Counter` must be incremented every scan/cycle by the PLC program; the tests read
it to prove the program is live and to measure read/subscription update timing.
The tests write to `Counter` never — they only read it.

## Which controller supports what

| Controller | Folder | Structured types? | Notes |
|------------|--------|-------------------|-------|
| Beckhoff **TwinCAT 3** (TF6100 OPC UA Server) | [`twincat/`](twincat/) | **Yes** — `TestStruct` present | Publish via `{attribute 'OPC.UA.DA' := '1'}` pragmas; struct needs `{attribute 'OPC.UA.DA.StructuredType' := '1'}` on the instance. |
| Schneider **Modicon M240/M241** | [`schneider_m240/`](schneider_m240/) | **No** — `TestStruct` OMITTED | Flat symbols only. Hard cap ~4 sessions; suite is single-session. |
| Schneider **Modicon M262** | [`schneider_m262/`](schneider_m262/) | **Yes** — `TestStruct` present | Symbols selected in the Symbol Configuration (no pragmas). |

The M240 omission matches `supportsComplexTypes = false` in `../plc_config.dart`;
TwinCAT and M262 set it `true`.

## Username / password convention

All three controllers authenticate with the fixture credentials and the tests
connect using **username auth over an UNENCRYPTED channel** (security policy
*None*; the client sets `allowUnencryptedPassword: true`). Defaults (from
`../plc_config.dart`):

- user: **`tester`**
- password: **`test-pass-1`**

Each vendor README explains how to create that account and allow the unencrypted
username endpoint on the server. Override per target with the `*_USER` / `*_PASS`
env vars for real hardware.

## Controller → folder → env vars

| Controller | Program folder | URL var | User / Pass vars | Extra |
|------------|----------------|---------|------------------|-------|
| TwinCAT 3  | `twincat/`         | `PLC_TWINCAT_URL` | `PLC_TWINCAT_USER` / `PLC_TWINCAT_PASS` | `PLC_TWINCAT_MAX_SESSIONS` (def 8), `PLC_TWINCAT_SESSION_TIMEOUT_MS` (def 20000) |
| M240/M241  | `schneider_m240/`  | `PLC_M240_URL`    | `PLC_M240_USER` / `PLC_M240_PASS`       | `PLC_M240_MAX_SESSIONS` (def **4**, hard cap), `PLC_M240_SESSION_TIMEOUT_MS` (def 20000) |
| M262       | `schneider_m262/`  | `PLC_M262_URL`    | `PLC_M262_USER` / `PLC_M262_PASS`       | `PLC_M262_MAX_SESSIONS` (def 5), `PLC_M262_SESSION_TIMEOUT_MS` (def 20000) |

Set a target's `*_URL` to a real endpoint (e.g. `opc.tcp://192.168.0.10:4840`) to
run against hardware, or to the literal `emulator` to spin up the matching local
asyncua emulator. Targets whose `*_URL` is unset are skipped.

## Deploying

None of these can be compiled on a dev box — each must be built and downloaded in
its vendor IDE (TwinCAT XAE for Beckhoff, EcoStruxure Machine Expert for
Schneider). Follow the per-folder `README.md`.
