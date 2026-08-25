# Physical-PLC tests & solutions

Tests and library solutions for using this OPC UA client against small industrial
controllers — **Beckhoff TwinCAT**, **Schneider Modicon M240/M241** (scalars only),
and **Schneider M262** (complex types). The goal is not to catalogue vendor limits
but to make *our library* behave well against them; the tests verify the solutions.

Everything runs **locally** against per-vendor emulators, and unchanged against
real hardware by pointing an env var at the controller.

## The problems these controllers pose, and our solutions

The rows below (except reconnection) are **verified against physical hardware**:
a Schneider **M241** and a Beckhoff **TwinCAT** (the rest against the emulators).

| Problem | Solution (verified by) |
|---|---|
| A controller (Schneider M241/M262, Beckhoff TwinCAT) refuses a plaintext password even under "None" security — it requires the **UserName token encrypted** (Basic256Sha256), yet may not trust a client cert | **`PlcSecurity.token`**: connect on a `None` channel but load the client cert/key so the token is encrypted with the *server's* cert — **no controller-side cert trust needed**. (default for real controllers; M241 + TwinCAT) |
| Some controllers advertise **only** `SignAndEncrypt` endpoints | **`Client(securityMode: …SIGNANDENCRYPT, certificate:, privateKey:)`** — encrypted channel; the controller must trust our cert (`test/plc/certs/`). (`PlcSecurity.encrypt`) |
| Username/password over an unencrypted channel silently fails (open62541 drops the plaintext-password token) | **`Client(allowUnencryptedPassword: true)`** — new library option. (emulators, `PlcSecurity.none`) |
| TwinCAT exposes `STRING` (and other simple types) under a **vendor DataType NodeId** with no `DataTypeDefinition`; the library used to fail the read (`BadAttributeIdInvalid`, then `Unsupported nodeId type`) | Library tolerates a missing `DataTypeDefinition` and **falls back to the variant's wire type**, so a value read never fails on a vendor type alias. (TwinCAT `TestString`) |
| A PLC `STRING` is single-byte and returns the **whole fixed buffer** with trailing garbage; non-UTF-8 bytes previously **crashed** the read | Library now decodes leniently (`utf8.decode(allowMalformed)`) so a read never throws; tests treat a PLC `STRING` as a NUL-terminated C string. (every scalar `TestString`) |
| CODESYS qualifies BrowseNames (`GVL_Test.TestBool`) and publishes arrays **element-wise** (`TestArray[0..9]`) | BrowseName lookup matches the trailing segment; the array test handles both one-node and element-wise layouts. (`scalar_roundtrip_test`) |
| Tiny session table (M240 ≈ 4, M262 ≈ 5); a crashed/dropped client squats a slot until a long timeout | **Short `requestedSessionTimeout`** so the controller reaps an abandoned session in seconds (**confirmed on the real M241**); **guaranteed `CloseSession`** on `dispose()` for the clean case. Proven via `CurrentSessionCount`. (`session_management_test`) |
| Accidentally opening too many sessions | **Client-side session-budget guard** — fails loud before over-opening. (`session_management_test`, emulator-only) |
| Reconnecting after a network blip must not pile up stale sessions | **`Client.keepConnected()`** reconnect reuses one slot. Tested with **toxiproxy** in front of the emulator. (Real hardware is skipped: a controller advertises its own EndpointURL, which open62541 follows — bypassing the proxy.) (`reconnect_test`) |

## Test files

- `scalar_roundtrip_test.dart` — every scalar type (+ array, live counter), all controllers.
- `complex_type_test.dart` — struct round-trip; TwinCAT & M262 only.
- `timing_test.dart` — read/write/struct round-trip latency (min/avg/p95/max) + accuracy under repetition.
- `session_management_test.dart` — the session solutions above.
- `reconnect_test.dart` — reconnection + no-session-accumulation via toxiproxy.

Harness: `plc_config.dart` (env-driven per-PLC config; short session timeout),
`plc_session.dart` (one shared session + budget guard + shared emulator),
`plc_browse.dart` (BrowseName lookup), `plc_fixture.dart` (the canonical fixture).

## Running locally (emulators)

```bash
bash test/integration/setup_local.sh        # once: asyncua venv + toxiproxy binary
PLC_TWINCAT_URL=emulator \
PLC_M240_URL=emulator \
PLC_M262_URL=emulator \
  dart test --run-skipped test/plc
```

Each `emulator` target starts a matching asyncua server (`emulators/plc_emulator.py`)
that mirrors the fixture, requires username/password, exposes a live `CurrentSessionCount`,
and (for twincat/m262) a real OPC UA struct.

## Running against real hardware

Deploy the vendor program (see `plc_programs/`), then set the controller's URL (and
credentials if not the defaults `tester` / `test-pass-1`). Real M241/M262 default
to `token` security automatically, so the URL alone is enough:

```bash
# Schneider M241 / Beckhoff TwinCAT — verified working (token security is the
# default for real controllers, so the URL alone is enough):
PLC_M240_URL=opc.tcp://192.168.0.20:4840 dart test --run-skipped test/plc
PLC_TWINCAT_URL=opc.tcp://192.168.0.10:4840 dart test --run-skipped test/plc

# Several controllers at once:
PLC_TWINCAT_URL=opc.tcp://192.168.0.10:4840 PLC_TWINCAT_USER=... PLC_TWINCAT_PASS=... \
PLC_M262_URL=opc.tcp://192.168.0.20:4840 \
  dart test --run-skipped test/plc
```

Per-target env vars: `PLC_<T>_URL`, `PLC_<T>_USER`, `PLC_<T>_PASS`,
`PLC_<T>_MAX_SESSIONS`, `PLC_<T>_SESSION_TIMEOUT_MS`, and `PLC_<T>_SECURITY`
(`none` | `token` | `encrypt`; see `certs/README.md`) — T = `TWINCAT` | `M240` |
`M262`. `PLC_TIMING_MAX_MS` sets the latency bound. Unconfigured targets skip.

On real hardware the emulator-only checks (session-budget guard, toxiproxy
reconnect) and unsupported features (M240 has no structs) self-skip.

These tests are tagged `plc` and skipped by default (local-only), so CI stays green.
```
