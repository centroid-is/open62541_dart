# Integration suite — findings & fix-branch triage

Bugs surfaced by the integration suite. Each genuine library bug gets its own
`fix/<slug>` branch off `upstream-v1.5.6` with a root-cause writeup, for human
review. The revealing test stays on `integration-test-suite`, quarantined with
`skip: 'BUG: ...'`, and each fix branch re-enables its own test.

Status legend: **open** (needs a fix branch) · **branch** (fix branch exists) ·
**server-limitation** (Dart `Server` gap, not a client/protocol bug) ·
**by-design** (documented behavior, no fix).

_Wave 2 (concurrency/stress/chaos/resilience) findings are appended as agents land._

---

## Wave 1 — complex_types (12 quarantines)

| # | Slug | Symptom | Root cause (file:line) | Severity |
|---|------|---------|------------------------|----------|
| 1 | `fix/client-subnormal-float` | Subnormal float/double corrupt over the client wire (`5e-324` → garbage); in-memory codec + server storage are fine, only the client wire path corrupts (repro'd vs asyncua too) | Dart client scalar wire decode/encode — `lib/src/client.dart` `_variantToValueAutoSchema` (~1556) | **High — data corruption** |
| 2 | `fix/struct-all-string-hang` | Reading a struct whose members are all strings **never returns** — native call blocks so even a Dart `.timeout` can't fire | contiguous in-struct string decode vs Dart-server DataTypeDefinition; mirrors repo's skipped `struct of strings` | **High — unbounded hang** |
| 3 | `fix/struct-array-member-decode` | Struct scalar-array member decodes as a scalar (`[1,2,3]` → `16777216`) | `Server.addCustomType` doesn't carry field dimensions (`lib/src/server.dart:372`); `fromDataTypeDefinition` builds a scalar field (`lib/src/types/opcua_serializer.dart:178-188`) → binary desync | High |
| 4 | `fix/array-of-structs-decode` | Array-of-structs decodes as a single struct (`isArray == false`) | ext-object/dimension handling in `variantToValue` (`lib/src/common.dart:103-124`) + client auto-schema; mirrors repo's skipped `Array of struct read and write` | High |
| 5 | `fix/optional-struct-fields` | Optional struct field misreads (`0` instead of value); layout uses pointers for optional members | schema ignores `isOptional`; explicit `throw 'Optional values not supported currently'` (`lib/src/types/opcua_serializer.dart:39`) | Medium |
| 6 | `fix/struct-field-descriptions` | Struct field `.description` is null after read | not carried by `Server.addCustomType`/`addDataTypeNode`, not surfaced via `fromDataTypeDefinition` (`lib/src/types/opcua_serializer.dart:190`) | Low |
| 7 | `fix/empty-arrays` | Empty arrays unrepresentable (legal in OPC UA) | `valueToVariant` throws `ArgumentError('Empty array')` (`lib/src/common.dart:41-44`); `DynamicValue.fromList([])` yields null not array | Medium |
| 8 | `fix/multidim-struct-array-encode` | Multi-dimensional struct arrays cannot be encoded | `valueToVariant` only tags ext-object type when `asArray.first.isObject`; a 2-D struct array's first element is an array → `throw 'Unable to determine type'` (`lib/src/common.dart:55-61`) | Medium |
| 9 | `fix/server-enum-definition` | Dart server never publishes an EnumDefinition, so client read `enumFields == null` | `Server.addDataTypeNode` (`lib/src/server.dart:205`) | server-limitation |
| 10 | `fix/enum-non-int32-decode` | Enums always decoded as Int32; non-Int32 enum would misdecode | hardcoded Int32 (`lib/src/types/opcua_serializer.dart:168-169`) | Low (needs #9 or a struct server to exercise live) |

Notes (passing, documented — **not** bugs):
- DateTime out-of-range values clamp to sentinels (`lib/src/types/payloads.dart:191-215`) — **by-design**, asserted as lossy.
- NaN / ±Infinity round-trip correctly (float & double).
- Nested/deeply-nested structs work **only** if every nested type also gets an `addDataTypeNode`; a missing inner DataType node hangs the client read (same family as #2).

## Wave 1 — interop (0 bugs)
asyncua + node-opcua fully interoperate (browse/read/write/methods/subscriptions,
direct + isolate) and the Dart server interoperates outward. One harness issue
(isolate `runIterate` not `.catchError`-guarded) — **fixed in the harness**, not a
`lib/` bug.

## Wave 1 — hmi (0 bugs)
All 17 dashboard/alarm/setpoint/command/multi-screen/soak scenarios pass.
Observations (not bugs): reference alarm variables are read-only with no
server-side raise path; `Salinity` is static; direct-client `monitoredItems`
re-emits a mutated instance (`lib/src/client.dart` ~1199-1205).

---

## Wave 2 — resilience (1 bug + 1 design gap)

| # | Slug | Symptom | Root cause (file:line) | Severity |
|---|------|---------|------------------------|----------|
| 11 | `fix/client-delete-segv` | `Client.delete()` (direct) **SEGV-crashes the VM** when a monitored-item stream is still active (deterministic `SEGV_ACCERR`); an in-flight Publish notification lands on freed native memory. Isolate client is safe (it cancels streams first, `lib/src/isolate.dart:871-877`) | `Client.delete()` calls `UA_Client_delete` without cancelling active monitored-item streams (`lib/src/client.dart:1594`) | **High — use-after-free crash** |

Design gap (documented, not a one-line fix): **open62541 does not auto-reconnect**
across a server crash/restart/partition — a single reconnect attempt fails with
`BADCONNECTIONREJECTED` and `connectStatus` stays bad until an explicit
`connect()` (`ua_client_connect.c:1904,2685`). Both harness pump loops also stop
on the first non-GOOD `runIterate()`. Recovery needs app-driven "keep pumping +
reconnect()" (captured as `ResilientClient` in `resilience/recovery_support.dart`).
Monitored streams emit `SecureChannelClosed` on drop and require a **fresh**
subscription after reconnect. Candidate library enhancement: a built-in
reconnect/keepalive path so HMI clients ride through network blips.

## Wave 2 — concurrency (0 bugs)
14 tests pass. The repo's known-failing `multi_client` does **not** reproduce as
a data bug: `Server.runIterate(waitInterval: true)` (`lib/src/server.dart:442`)
blocks the isolate, so several Dart servers pumped on one isolate serialize and
starve client connects. Non-blocking poll (`waitInterval: false`) fixes it —
an **ergonomics limitation**, candidate for a doc note or a non-blocking default.

## Wave 2 — stress (0 bugs)
11 tests pass, flat RSS (no leaks) across connect/subscription churn and a 30s
soak. 250 monitored items, 50k arrays, 200k strings, 20ms high-frequency all OK.

## Wave 2 — chaos (pending authoritative serial run)
Latency/bandwidth/timeout/reset/slicer + recovery tests authored, analyze-clean;
full runs were OOM-killed under concurrent-agent load. Pass/fail to be confirmed
by the serial validation run.

---

## Environmental (not library issues)
- The OS OOM-kills (SIGKILL/137) long-lived Dart runs under memory pressure.
- Concurrent `dart test` processes race on the shared `.dart_tool` native-asset
  bundle (`install_name_tool: cannot rename ...libopen62541.dylib`).
- **Validate the suite serially, one category at a time.**
