# open62541 examples

Runnable examples for the `open62541` package. On the first run the native
open62541 library is built from source by the package's build hook, so allow
some extra time for the initial `dart pub get` / `dart run`.

## `example.dart` — minimal client

Connects to an OPC UA server and reads the current server time. Run it against
any OPC UA endpoint:

```bash
dart run example/example.dart opc.tcp://localhost:4840
```

## `browse_test.dart` — browsing the address space

Browses the `Objects` folder and walks the address-space tree:

```bash
dart run example/browse_test.dart opc.tcp://localhost:4840
```

## `server_example.dart` — running a server

Starts an OPC UA server exposing scalar, array and custom-structure variables:

```bash
dart run example/server_example.dart
```

## `resilient_client.dart` — secure, self-healing client

A client that connects with certificates (`SignAndEncrypt`), recreates its
subscriptions after a session loss, and keeps a monitored item alive across
reconnects. It expects `client_cert.der` and `client_key.der` in the working
directory:

```bash
dart run example/resilient_client.dart opc.tcp://localhost:4840 [username] [password]
```

## Redundant METAR servers with ServiceLevel failover

Files: `metar_common.dart`, `metar_redundant_server.dart`,
`metar_redundant_client.dart`.

A pair of OPC UA servers publish live METAR weather for **BIRK** (Reykjavík
Airport) as a custom structured type, advertise each other as a hot-redundant
set on the standard NS0 nodes, and a client follows whichever one is healthiest
— moving when the ranking changes or when a server dies.

### What it demonstrates

* **Server-side redundancy on the standard nodes.** Each server takes over the
  value source of `Server/ServiceLevel` (`ns=0;i=2267`) and
  `Server/ServerRedundancy/RedundancySupport` (`ns=0;i=3709`, set to `Hot`)
  with `Server.setVariableValueSource`, and republishes
  `Server/ServerRedundancy/ServerUriArray` (`ns=0;i=11314`) listing both
  members of the set. open62541 pins ServiceLevel at 255 internally and stores
  `RedundancySupport = None`; neither accepts a write, so replacing the value
  source is the only way to publish a real service level. No vendor nodes are
  invented — any standards-based client can discover and rank the set.
* **Honest ServiceLevel.** Each instance computes its own 0-255 level: `250`
  with a fresh observation, falling as the data ages, minus 60 for every
  consecutive failed fetch (floored at 1), and `0` when it has never fetched
  anything or is shutting down — `0` being the OPC UA way of saying *do not
  use me*.
* **Quality and timestamps on a data-source node.** The observation is served
  from a data-source variable node through `onReadValue`, so every read carries
  a real `StatusCode` and the **observation's own** `sourceTimestamp`. When the
  upstream feed goes down, or the newest observation ages past the staleness
  threshold, the server keeps serving the **last known value** flagged
  `Bad_NoCommunication` **with its original source timestamp** — stale but
  useful data with honest quality, rather than a hole or a silent lie.
* **A real METAR decoder.** `metar_common.dart` parses the raw report text
  (not just the API's convenience fields), which is what makes the plain-text
  fallback endpoint work too. It handles `VRB` and calm winds, gusts, `CAVOK`,
  metric and statute-mile visibility including `1 1/2SM` / `P6SM` / `M1/4SM`,
  negative temperatures (`M04/M06`), missing groups (`/////KT`, `////`,
  `M04///`), `AUTO`, `SPECI`, `COR`, `NIL`, `RMK` sections, trend groups and
  vertical visibility, and derives ceiling, relative humidity and FAA flight
  category.

### Running it — three terminals

```bash
# terminal 1
dart run example/metar_redundant_server.dart \
    --instance metar-a --port 4840 --peer opc.tcp://localhost:4841

# terminal 2
dart run example/metar_redundant_server.dart \
    --instance metar-b --port 4841 --peer opc.tcp://localhost:4840

# terminal 3 — one endpoint is enough; the peer is discovered
dart run example/metar_redundant_client.dart --endpoint opc.tcp://localhost:4840
```

The client reads every server's ServiceLevel on a timer, subscribes to the
METAR structure on the highest-ranked one, and prints a line on every
switch:

```
[client] discovered 1 peer(s) from opc.tcp://localhost:4840: opc.tcp://localhost:4841
[client] switched (none) -> opc.tcp://localhost:4840: ServiceLevel unreachable -> 250, reason: initial selection
[opc.tcp://localhost:4840] BIRK 2026-09-01T19:00:00.000Z 10.0/2.0 C  wind 300@3.0kt  QNH 1013.0  VFR
```

### Things to try

* **Kill a server.** `Ctrl-C` the active one. It drops its ServiceLevel to 0
  and keeps serving for two more seconds so the client sees the hand-off, then
  exits. Expect:
  `switched … -> …: ServiceLevel 0 -> 250, reason: server reported ServiceLevel 0 (out of service)`.
  Kill it with `SIGKILL` instead and the reason becomes `connection lost`.
* **Force a low ServiceLevel** without killing anything — start (or restart)
  an instance with `--service-level 10` and watch the client move.
* **Watch the quality path.** Cut the machine's network, or point a server at
  a station that reports nothing (`--station ZZZZ`). Its fetches start failing:
  it keeps serving the last observation, now `Bad_NoCommunication`, and its
  ServiceLevel walks down 250 → 190 → 130 → … until the other server wins.
* **Browse it in UaExpert.** Besides the structure node
  (`ns=1;s=BIRK.Metar`) each server exposes plain scalar mirrors
  `ns=1;s=BIRK.TemperatureC` and `ns=1;s=BIRK.WindSpeedKt`, which carry the
  same status and timestamps.

Both servers can run on one machine, or on two — pass `--host` so each
publishes an endpoint URL the other side can actually reach.

### Failback policy

The client fails **back**, but only when the returning server beats the active
one by more than the hysteresis margin (`--hysteresis`, default 10). Two
equally healthy servers therefore never ping-pong the subscription: a recovered
peer at the same ServiceLevel leaves the current server in place.

### Data source

`https://aviationweather.gov/api/data/metar?ids=BIRK&format=json` — NOAA /
Aviation Weather Center, US-government public-domain data, no API key or
registration. Their guidelines ask for a custom `User-Agent` and no more than
100 requests/minute; the server polls every five minutes by default (`--poll`),
and METARs are only issued every 30-60 minutes anyway. `--text` switches to the
plain-text mirror at
`https://tgftp.nws.noaa.gov/data/observations/metar/stations/BIRK.TXT`.

**The examples need internet access; the tests do not.** The fetcher sits
behind the `MetarSource` interface, and `test/metar_parser_test.dart` (recorded
fixtures) and `test/metar_redundancy_test.dart` (two in-process servers plus a
fake source, on OS-allocated ports) never open a network connection to anything
but loopback.
