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
set on the standard NS0 nodes, and a client given one endpoint discovers the
set and follows whichever member is healthiest — moving when the ranking
changes, when a member announces its shutdown, or when one dies.

### What it demonstrates

* **The redundant set on the standard nodes, through `Server.setRedundancy`.**
  Each member calls
  `setRedundancy(RedundancySupport.hot, serverUris: [...], networkGroups: {...})`,
  which types `Server/ServerRedundancy` (`ns=0;i=2296`) as
  `NonTransparentNetworkRedundancyType` (`i=11945`, creating the type chain
  `ServerRedundancyType` → `NonTransparentRedundancyType` →
  `NonTransparentNetworkRedundancyType` that open62541's reduced NS0 lacks;
  [OPC 10000-5 §6.3.7](https://reference.opcfoundation.org/Core/Part5/6.3.7)
  forbids a non-None `RedundancySupport` on the base type), serves
  `RedundancySupport` (`i=3709`) = `Hot`, and adds the two properties:
  `ServerUriArray` (`i=11314`) holding the **ServerUris** — the
  ApplicationUris — of both members, the local one first
  ([§6.3.9](https://reference.opcfoundation.org/Core/Part5/6.3.9)), and
  `ServerNetworkGroups` (`i=14415`, a `NetworkGroupDataType[]`) mapping each
  of those URIs to the member's endpoint URL
  ([§6.3.10](https://reference.opcfoundation.org/Core/Part5/6.3.10)). Only
  `ServiceLevel` (`i=2267`) is the example's own: open62541 pins it at 255
  through a callback that accepts no write, so the server replaces its value
  source with `Server.setVariableValueSource`. No vendor nodes are invented —
  any standards-based client can discover and rank the set.
* **One identity per member.** The members of a non-transparent set must have
  unique ApplicationUris ([OPC 10000-4 §6.6.2.4](https://reference.opcfoundation.org/specs/OPC-10000-4/6.6.2.4)),
  so each instance announces its own — `urn:<host>:metar:<instance>` unless
  `--uri` says otherwise — through `Server(applicationUri:)`. Clients see it
  in the ApplicationDescription and as `Server/ServerArray[0]` (`ns=0;i=2254`).
* **Discovery from one seed.** A ServerUri is an identity, not an address, so
  the client never dials one. Given a single endpoint it reads that server's
  `ServerArray[0]`, `ServerUriArray` and `ServerNetworkGroups` (a built-in
  NS0 structure, decoded by the package from open62541's native layout) and
  connects to every other member at the endpoint the groups give for it; a
  member whose group has no network path is reported, not dialled. More
  `--endpoint`s are an override, and `--no-discover` turns the discovery off.
* **Why `Hot`.** Both members run, serve data continuously and are equally
  usable; a client reads from one and switches by ServiceLevel, which is the
  definition of Hot in Part 4. `Warm` would misdescribe them: a Warm backup is
  required to sit Degraded and answer data requests with
  `Bad_NoCommunication`, which neither member does. (That every node here is
  read-only is a property of a weather feed, not of the mode.)
* **Honest ServiceLevel, in the spec's bands.** [OPC 10000-4 §6.6.2.4.2,
  Table 105](https://reference.opcfoundation.org/Core/Part4/v105/docs/6.6.2.4.2)
  divides the 0-255 range into **Maintenance** (0: clients shall disconnect
  and stay away), **NoData** (1: up, but nothing to serve), **Degraded**
  (2-199) and **Healthy** (200-255). Each instance computes its own level
  from its own state: `250` with a fresh observation, `100` / `5` as the data
  ages past the staleness threshold, minus 60 for every consecutive failed
  fetch floored at `2` (a server still serving its last-known value, however
  Bad, is still exchanging data, so it stays Degraded rather than claiming
  NoData), `1` while it has never fetched anything, and `0` only during its
  shutdown hold.
* **Orderly shutdown.** `Ctrl-C` calls
  `Server.shutdown(delay: 2 s, announceServiceLevel: true)`: for the delay
  `ServerStatus.State` (`i=2259`) reads `Shutdown`, `SecondsTillShutdown`
  counts down (Part 5 §12.6) and `ServiceLevel` reads 0 (Table 105), while
  every read and subscription is still served — so a connected client moves
  to the other member while the data is still Good, instead of losing the
  socket.
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
dart run example/metar_redundant_server.dart --instance metar-a --port 4840 \
    --peer urn:localhost:metar:metar-b=opc.tcp://localhost:4841

# terminal 2
dart run example/metar_redundant_server.dart --instance metar-b --port 4841 \
    --peer urn:localhost:metar:metar-a=opc.tcp://localhost:4840

# terminal 3 — one seed endpoint is enough (this one is the default)
dart run example/metar_redundant_client.dart --endpoint opc.tcp://localhost:4840
```

The client identifies the seed server by its ApplicationUri, reads the set
and the members' endpoints it advertises, connects to the other member, reads
every member's ServiceLevel and ServerStatus.State on a timer, subscribes to
the METAR structure on the highest-ranked one, and prints a line on every
switch:

```
[client] tracking opc.tcp://localhost:4840
[client] opc.tcp://localhost:4840 is urn:localhost:metar:metar-a, set: urn:localhost:metar:metar-a, urn:localhost:metar:metar-b
[client] discovered urn:localhost:metar:metar-b at opc.tcp://localhost:4841 from opc.tcp://localhost:4840's ServerNetworkGroups
[client] tracking opc.tcp://localhost:4841 (discovered: urn:localhost:metar:metar-b)
[client] opc.tcp://localhost:4841 is urn:localhost:metar:metar-b, set: urn:localhost:metar:metar-b, urn:localhost:metar:metar-a
[client] switched (none) -> urn:localhost:metar:metar-a (opc.tcp://localhost:4840): ServiceLevel unreachable -> 250, reason: initial selection
[opc.tcp://localhost:4840] BIRK 2026-09-01T19:00:00.000Z 10.0/2.0 C  wind 300@3.0kt  QNH 1013.0  VFR
```

### Things to try

* **Stop a server.** `Ctrl-C` the active one. It announces the shutdown and
  keeps serving for two more seconds; the client moves at once:
  `switched … -> …: ServiceLevel 0 -> 250, reason: server announced shutdown (ServerStatus.State 4, ServiceLevel 0)`,
  disconnects from it, and only looks at that endpoint again after
  `--maintenance-retry` seconds (30 by default). Kill it with `SIGKILL`
  instead and the reason becomes `connection lost`.
* **Force a low ServiceLevel** without killing anything — start (or restart)
  an instance with `--service-level 10` and watch the client move; with
  `--service-level 0` it disconnects, and with `--service-level 1` it keeps
  polling the member but takes no data from it.
* **Watch the quality path.** Cut the machine's network, or point a server at
  a station that reports nothing (`--station ZZZZ`). Its fetches start failing:
  it keeps serving the last observation, now `Bad_NoCommunication`, and its
  ServiceLevel walks down 250 → 190 → 130 → … → 2. The first step already
  leaves the Healthy band, so the client moves to the other server if that
  one is Healthy; if both are Degraded, the hysteresis margin decides.
* **Browse it in UaExpert.** Besides the structure node
  (`ns=1;s=BIRK.Metar`) each server exposes plain scalar mirrors
  `ns=1;s=BIRK.TemperatureC` and `ns=1;s=BIRK.WindSpeedKt`, which carry the
  same status and timestamps. Under `Server/ServerRedundancy` the type,
  `ServerUriArray` and `ServerNetworkGroups` are there to inspect.

Both servers can run on one machine, or on two — pass `--host` so each
publishes an endpoint URL clients can actually reach (it also goes into the
default ApplicationUri; `--uri` sets that explicitly, and `--peer` names the
other member by *its* ApplicationUri and endpoint).

### Switching policy

The client follows Table 105 band by band rather than chasing the highest
number:

* **Initial selection:** the highest ServiceLevel among the members at 2 or
  more (it waits, up to a settle timeout, for every known endpoint to answer
  first). A member at **NoData (1)** is polled for ServiceLevel and
  ServerStatus and never given the data subscription; with no member at 2 or
  more the client holds no subscription and keeps polling.
* **Active server Healthy (200-255):** no failover, whatever the others
  report — a 255 appearing next to an active 240 changes nothing. The client
  leaves only when the server becomes unreachable, reports 0 (Maintenance),
  announces a shutdown (`ServerStatus.State` ≠ Running, treated like 0) or
  drops out of the Healthy band.
* **Active server Degraded (2-199):** switch to the best Healthy server if
  there is one, margin or no margin (195 → 200 switches). With no Healthy
  server in the set, switch to a higher Degraded one only if it clears the
  hysteresis margin (`--hysteresis`, default 10), so two similarly degraded
  servers do not ping-pong the subscription.
* **Maintenance (0) or not Running:** the member is not just left, the client
  disconnects from it and reconnects only after a much longer interval
  (`--maintenance-retry`, 30 s) to read its level again, until it is above 0.

The client therefore does fail **back**, but only because the server it is on
has left the Healthy band — a recovered peer alone never causes a switch.

### What is spec-exact, and what is simplified

Exact, per OPC 10000-4 §6.6.2 and OPC 10000-5 §6.3.9-6.3.10 / §12.6: unique
ApplicationUris per member; `ServerUriArray` holding ServerUris with the local
server first; `ServerNetworkGroups` with the same URIs and each member's
endpoint; `ServerRedundancy` typed `NonTransparentNetworkRedundancyType`
(never a non-None mode on the base type); `RedundancySupport = Hot` for two
equal members; the Table 105 bands on the server and the band-aware
switching, the Maintenance disconnect and the NoData no-data rule on the
client; `ServerStatus.State = Shutdown` with a countdown and ServiceLevel 0
during the shutdown hold.

Simplified, deliberately, and labelled so nobody copies them as the general
pattern:

* **ServiceLevel is polled, not subscribed.** Part 4 expects a client to
  monitor `ServiceLevel` (and `ServerStatus`) with a subscription; this
  client reads both on a timer (`--poll`), which is simpler to follow and
  bounds the reaction time by the poll interval.
* **Cold-style switch-over.** The data subscription is created on the new
  server at failover time, not kept pre-created on every member as Warm/Hot
  clients may. Data changes between the unsubscribe and the first Publish on
  the new server can be lost; a Hot client that cannot afford that creates
  the subscriptions on every member up front and only switches which one it
  publishes from.
* **No discovery-server registration.** The members do not register with an
  LDS / FindServers; the set is found through `ServerNetworkGroups` of a seed
  endpoint you are given.
* **`--service-level` is a demo knob.** Part 4 wants every member to run the
  same algorithm for its ServiceLevel so that the levels are comparable; a
  forced value breaks that rule on purpose, to show a failover without
  breaking a feed.

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
