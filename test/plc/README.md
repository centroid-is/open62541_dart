# Physical-PLC tests & solutions

Tests and library solutions for using this OPC UA client against small industrial
controllers — **Beckhoff TwinCAT**, **Schneider Modicon M240/M241** (scalars only),
and **Schneider M262** (complex types). The goal is not to catalogue vendor limits
but to make *our library* behave well against them; the tests verify the solutions.

Everything runs **locally** against per-vendor emulators, and unchanged against
real hardware by pointing an env var at the controller.

## The problems these controllers pose, and our solutions

| Problem | Solution (verified by) |
|---|---|
| Username/password auth over an unencrypted channel silently fails (open62541 drops the plaintext-password token) | **`Client(allowUnencryptedPassword: true)`** — new library option. (`session_management_test`, every scalar test) |
| Tiny session table (M240 ≈ 4, M262 ≈ 5); a crashed/dropped client squats a slot until a long timeout | **Short `requestedSessionTimeout`** so an abandoned session is reaped in seconds; **guaranteed `CloseSession`** on `dispose()`. (`session_management_test`) |
| An occasional-poll HMI shouldn't hold a slot at all | **`LeasedPlcClient`** — holds *zero* sessions while idle, opens on demand, closes after a short idle window. Proven to add 0 to the server's `CurrentSessionCount`. (`session_management_test`) |
| Accidentally opening too many sessions | **Client-side session-budget guard** — fails loud before over-opening. (`session_management_test`) |
| Reconnecting after a network blip must not pile up stale sessions | **`Client.keepConnected()`** reconnect reuses one slot. Tested by putting **toxiproxy in front of the controller** and dropping the link. (`reconnect_test`) |

## Test files

- `scalar_roundtrip_test.dart` — every scalar type (+ array, live counter), all controllers.
- `complex_type_test.dart` — struct round-trip; TwinCAT & M262 only.
- `timing_test.dart` — read/write/struct round-trip latency (min/avg/p95/max) + accuracy under repetition.
- `session_management_test.dart` — the session solutions above.
- `reconnect_test.dart` — reconnection + no-session-accumulation via toxiproxy.

Harness: `plc_config.dart` (env-driven per-PLC config), `plc_session.dart` (one shared
session + budget guard + shared emulator), `plc_client.dart` (`LeasedPlcClient`),
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
credentials if not the defaults `tester` / `test-pass-1`):

```bash
PLC_TWINCAT_URL=opc.tcp://192.168.0.10:4840 PLC_TWINCAT_USER=... PLC_TWINCAT_PASS=... \
PLC_M262_URL=opc.tcp://192.168.0.20:4840 \
  dart test --run-skipped test/plc
```

Per-target env vars: `PLC_<T>_URL`, `PLC_<T>_USER`, `PLC_<T>_PASS`,
`PLC_<T>_MAX_SESSIONS`, `PLC_<T>_SESSION_TIMEOUT_MS` (T = `TWINCAT` | `M240` | `M262`),
and `PLC_TIMING_MAX_MS` for the latency bound. Unconfigured targets skip.

These tests are tagged `plc` and skipped by default (local-only), so CI stays green.
```
