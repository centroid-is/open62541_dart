# TwinCAT 3 (Beckhoff) — TF6100 OPC UA Server deploy guide

PLC-side program that places the shared OPC UA test fixture (see
`../../plc_fixture.dart`) on a Beckhoff TwinCAT 3 runtime and publishes it with
the **TF6100 OPC UA Server**.

> You cannot compile these files on this machine. They are TwinCAT native XML
> objects and **must be added to a TwinCAT PLC project and compiled/activated in
> the TwinCAT XAE (Visual Studio) IDE** on a Windows engineering station.

## Files

| File | Object | Purpose |
|------|--------|---------|
| `GVL_Test.TcGVL`     | Global Variable List | Declares every fixture variable with the `OPC.UA.DA` publish pragma. |
| `DUT_TestStruct.TcDUT` | DUT (STRUCT) | `ST_TestStruct { Id:DINT; Value:REAL; Enabled:BOOL; Label:STRING }` — the type behind `TestStruct`. |
| `MAIN.TcPOU`         | PROGRAM | Increments `Counter` every cycle and seeds initial values. |

The fixture is intentionally full: TwinCAT supports structured types, so
`TestStruct` **is** present here (`supportsComplexTypes = true`).

## 1. Create the project

1. On a Windows box with **TwinCAT 3 XAE** and **TF6100** installed, create a
   new *TwinCAT XAE Project*.
2. Add a *Standard PLC Project* under **PLC**.
3. Import the three files:
   - Right-click the PLC project → **Add → Existing Item…** and add
     `GVL_Test.TcGVL`, `DUT_TestStruct.TcDUT`, and `MAIN.TcPOU`
     (or copy them into the PLC project folder on disk, then reload). GVLs live
     under **GVLs**, the DUT under **DUTs**, and MAIN under **POUs**.
4. Make sure `MAIN` is called by a task — add it to **PlcTask** (or your cyclic
   task) so `Counter` actually increments. A 10 ms task is fine.
5. **Build** the PLC project.

## 2. Enable the OPC UA symbols

TF6100 publishes the PLC symbols that carry the `OPC.UA.DA` attribute (already in
`GVL_Test.TcGVL`). You still have to switch symbol download on:

1. In the PLC project → **SYSTEM/Project settings** or the PLC project's
   **Compiler / Symbol** settings, enable **"Download Symbols"** /
   *Publish symbols* so the compiled symbol file is generated. (In newer XAE:
   PLC project → **Properties → TwinCAT → check "Download symbols"** and, if
   present, **"OPC UA symbols"**.)
2. **Activate Configuration** and put the target in **Run**.
3. The TF6100 server (running on the target, default TCP port **4840**) reads the
   symbol file and exposes each tagged variable. Browse them in **UaExpert** to
   confirm the BrowseNames match the fixture exactly.

> Attribute recap (do not change): every fixture variable has
> `{attribute 'OPC.UA.DA' := '1'}`. `TestStruct` additionally has
> `{attribute 'OPC.UA.DA.StructuredType' := '1'}` on the **instance** line in the
> GVL — that pragma is what makes TF6100 publish it as a real OPC UA structured
> data type with `Id/Value/Enabled/Label` members, instead of a flat/opaque
> blob. **Placement matters:** the `StructuredType` attribute goes on the
> variable instance in the GVL, *not* on the `TYPE … END_TYPE` in the DUT.
> We deliberately did **not** add the read-only attribute
> (`{attribute 'OPC.UA.DA.Access' := '1'}`) to any writable variable, so they
> stay CurrentRead|CurrentWrite. `Counter` is owned/incremented by `MAIN`; the
> tests only read it.

## 3. Authentication (username / password)

The suite defaults to user **`tester`** / password **`test-pass-1`**
(from `../../plc_config.dart`) and connects with **username auth over an
UNENCRYPTED channel** (`allowUnencryptedPassword: true`, security policy *None*).
Configure TF6100 to accept that:

1. Edit the TF6100 server config file
   `TcUaServer.Config.xml` (typically under
   `C:\TwinCAT\Functions\TF6100-OPC-UA\Win32\Server\` or the 3.x equivalent
   `%TC_INSTALLPATH%\Functions\TF6100-OPC-UA\...`).
2. Ensure a **username/password endpoint** is enabled and that a login named
   `tester` with password `test-pass-1` exists (TF6100 can authenticate against
   the config file's user list or Windows users, depending on version — use the
   config-file user list for a self-contained lab setup).
3. Keep an endpoint with **SecurityPolicy = None / SecurityMode = None** enabled
   so username auth works over the unencrypted channel the tests use. (For
   production you would require Sign&Encrypt; the tests intentionally do not.)
4. Restart the **TcUaServer** service after editing the config.

If you use different creds on real hardware, pass them via the env vars below.

## 4. Endpoint URL

```
opc.tcp://<PLC-IP-or-host>:4840
```

TF6100's default port is **4840**. Some installs append a server path
(e.g. `.../TcOpcUaServer`); check UaExpert's discovery. The tests resolve nodes
by BrowseName under the *Objects* folder, so the containing path
(`PLC1/GVL_Test/…` in the emulator, `<PLC>/GVL_Test/…` here) does not matter.

## 5. Point the tests at it

```bash
export PLC_TWINCAT_URL='opc.tcp://192.168.0.10:4840'
export PLC_TWINCAT_USER='tester'          # optional; defaults to tester
export PLC_TWINCAT_PASS='test-pass-1'     # optional; defaults to test-pass-1
# optional tuning:
export PLC_TWINCAT_MAX_SESSIONS=8         # default 8
export PLC_TWINCAT_SESSION_TIMEOUT_MS=20000
```

Set `PLC_TWINCAT_URL=emulator` to run against the local asyncua emulator instead
of hardware.

## TF6100 session / monitored-item limits

TF6100 is more generous than the Schneider controllers but is still bounded and
licensed. Relevant caveats:

- **Sessions/subscriptions/monitored items** are capped by the TF6100 license
  level and the `MaxSessionCount` / `MaxSubscriptionCount` /
  `MaxMonitoredItemsPerCall` entries in `TcUaServer.Config.xml`. The default
  budget here is `PLC_TWINCAT_MAX_SESSIONS = 8`, but the suite shares **one**
  session per controller regardless (see `../../plc_session.dart`).
- Sampling faster than the PLC task cycle gains nothing — TF6100 samples symbols
  at (at best) the task rate, so set monitored-item sampling intervals ≥ your
  task cycle (e.g. ≥ 10 ms).
- The short `sessionTimeout` (20 s) the client requests lets TF6100 reap an
  abandoned session quickly instead of holding the slot for minutes.
