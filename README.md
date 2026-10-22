# open62541 for Dart

Dart FFI bindings to the [open62541](https://www.open62541.org/) OPC UA stack.
This package provides idiomatic Dart client and server APIs for OPC UA over TCP,
including subscriptions, custom types and encrypted (mbedTLS) connections
with certificate verification on both sides: a client that verifies the
server against a trust list, and a server with a certificate, a trust list,
users, a listen address and limits; see [Security](#security).

> Status: work in progress. The API is functional but still evolving and may
> change between releases.

## Features

- **Client**: connect / reconnect, browse and recursive tree browsing, read,
  subscriptions and monitored items, and encrypted connections
  (`SignAndEncrypt` with a certificate) that authenticate the server against
  a trust list; accepting any server certificate is an explicit opt-in.
  Endpoint discovery (`Client.getEndpoints`) lists a server's endpoints with
  its certificate, which is how the trust list gets that certificate.
- **Server** (SecurityPolicy None and anonymous by default; a certificate,
  trust list, users and limits make it a secured one, see
  [Security](#security)): expose scalar, array and structure (custom type) variable nodes,
  data-type nodes, custom object types, and monitor variables via streams.
  Redundant sets are published with `setRedundancy` (Part 5
  `NonTransparentRedundancyType`, `ServerUriArray`), and `shutdown(delay:)`
  announces an orderly shutdown (`ServerStatus.State` = Shutdown,
  `SecondsTillShutdown`) while serving for the delay.
- **PubSub** (OPC UA Part 14, UDP + UADP): publish variable nodes via
  PublishedDataSets / WriterGroups / DataSetWriters, and subscribe with
  ReaderGroups / DataSetReaders that map received fields into local variable
  nodes (both sides configured on `Server`, per the OPC UA PubSub model).
  Received values can be observed with `Server.onValueChanged`.
- **Encryption** via mbedTLS (client side).
- **`DynamicValue`** for ergonomic access to OPC UA values, including structures
  and arrays.

## Supported platforms

Linux, macOS, Windows, Android and iOS. The client and server are a native FFI
binding, so they do not run in a browser; the value types (`DynamicValue`,
`NodeId`, ...) do — see [Using the types on the web](#using-the-types-on-the-web).

## How the native library is built

This package does **not** ship a precompiled binary. It uses Dart's
[native build hooks](https://dart.dev/interop/c-interop) (`hook/build.dart`
together with the `hooks`, `code_assets` and `native_toolchain_cmake` packages).
The first time the package is built, the hook:

1. Downloads the open62541 and mbedTLS source archives over the network.
2. Builds them from source with CMake for your target platform.
3. Bundles the resulting shared library as a code asset.

Because of this you need a working C/C++ toolchain, **CMake**, and network
access available at build time. The first build is slow; subsequent builds are
cached.

Native build hooks are stable since Dart 3.10, so consumers need no experiment
flag.

## Installation

```yaml
dependencies:
  open62541: ^1.5.9
```

Then run `dart pub get` (allow extra time for the first native build).

## Versioning

The package version mirrors the bundled open62541 release exactly: `1.5.9` wraps
open62541 `v1.5.9`. Dart-side fixes that ship the **same** native library version
use a build-metadata suffix — `1.5.9+1`, `1.5.9+2`, … — which pub.dev orders
after `1.5.9`. So `open62541: ^1.5.9` accepts `1.5.9`, any binding-only `+N`
revision, and later `1.x` upstream releases.

## Usage

Read the current server time from an OPC UA server:

```dart
import 'package:open62541/open62541.dart';

void main(List<String> args) async {
  final client = Client();
  client.connect('opc.tcp://localhost:4840');

  // Drive the client event loop.
  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  await client.awaitConnect();

  final time = await client.read(NodeId.serverStatusCurrentTime);
  print('Server time: ${time.asDateTime}');

  client.disconnect();
  await client.delete();
}
```

More examples are in the [`example/`](example/) directory: a minimal client
(`example.dart`), address-space browsing (`browse_test.dart`), a server
(`server_example.dart`) and an encrypted, self-healing client
(`resilient_client.dart`).

> **Threading note:** open62541 is built with multithreading disabled, so the
> client/server event loop must be driven periodically by calling `runIterate`
> as shown above.

### Security

**Client.** Without a certificate the client offers SecurityPolicy None:
nothing on the wire is signed or encrypted, and a username/password only
travels if `allowUnencryptedPassword: true` is set (in clear text then; for a
network you trust end to end). With a `certificate` and `privateKey` (DER,
not encrypted: an encrypted key is an `ArgumentError`, a key open62541
cannot load a `UaStatusException` from the constructor) and `securityMode: SignAndEncrypt` the channel is encrypted, and the server
is authenticated against the `trustList` (DER: the server's own certificate,
or the CA certificate that issued it), with an optional `issuerList`
(intermediate CAs, which complete a chain but are not trusted by themselves)
and `revocationList` (CRLs). A server whose certificate does not verify is
refused: `connect` throws a `UaStatusException` with the certificate status
(`BadCertificateUntrusted`, `BadCertificateChainIncomplete`,
`BadCertificateRevoked`, ...).

```dart
final client = Client(
  securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
  certificate: await File('client_cert.der').readAsBytes(),
  privateKey: await File('client_key.der').readAsBytes(),
  trustList: [await File('server_cert.der').readAsBytes()],
);
```

`acceptAllCertificates: true` skips the verification: the session is still
encrypted, which stops passive eavesdropping, but the server is not
authenticated, so an active attacker (a machine in the middle, a spoofed
endpoint) goes unnoticed. It is an explicit opt-in: a certificate with
neither a `trustList` nor `acceptAllCertificates: true` is an
`ArgumentError`, because open62541 treats an empty trust list as "accept
every certificate". `ClientIsolate.create` takes the same arguments. The
endpoint hostname is not checked against the server certificate.

**Discovery, and trust on first use.** The trust list needs the server
certificate before the first secure connection, and the server itself hands
it out: `Client.getEndpoints` (the same static on `ClientIsolate`) runs the
GetEndpoints service over a SecurityPolicy None channel without a session,
so it needs no certificate and no trust list, and every
`EndpointDescription` it returns carries the `serverCertificate` (DER) next
to the policy, mode and identity tokens of that endpoint. Discovery
authenticates nothing: a machine in the middle at that moment hands over
its own certificate, and trusting it would make every later "encrypted"
session its to read. So compare the `certificateThumbprint` (SHA-1, what
the server's own certificate manager shows) with one obtained out of band,
from the server's operator, before trusting it; then persist the DER and
pass it as `trustList` from then on. A server whose certificate changes is
refused with `BadCertificateUntrusted` after that, which is the point.

```dart
final endpoints = await Client.getEndpoints('opc.tcp://plc:4840');
final endpoint = endpoints.firstWhere(
  (e) => e.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
);
print('server certificate ${endpoint.certificateThumbprint}'); // confirm out of band
await File('server_cert.der').writeAsBytes(endpoint.serverCertificate);
```

The call makes a native client of its own for the duration, on an isolate
of its own (open62541's `UA_Client_getEndpoints` blocks until the answer),
and keeps nothing. A host that does not answer within `timeout` is a
`TimeoutException`; a refused connection or a Bad service result is a
`UaStatusException`. `example/discover_endpoints.dart` prints the endpoints
and thumbprints of a server.

**Server.** A plain `Server()` offers SecurityPolicy None with anonymous
access on all interfaces, so any client that can reach the port can read every
node, write every node whose access level allows it and call methods; it may
not add or delete nodes or references (new: those services answer
`BadUserAccessDenied` unless `allowClientNodeManagement: true`). Run it on a
trusted network only (a machine network behind its own firewall, a lab,
`localhost`). `addVariableNode` defaults to `AccessLevelMask(read: true,
write: true)`; `addDataSourceVariableNode` is read-only unless `onWrite` is
given.

A secured server takes its own `certificate` and `privateKey` (DER; the
`applicationUri` must be the URI in the certificate's subjectAltName, or the
constructor throws) and the client certificates to trust, and refuses
anonymous sessions in favour of users:

```dart
final server = Server(
  certificate: await File('server_cert.der').readAsBytes(),
  privateKey: await File('server_key.der').readAsBytes(),
  trustList: [await File('client_cert.der').readAsBytes()],
  allowAnonymous: false,
  users: {'operator': 'a long passphrase'},
  hostname: 'plc-gateway.example',   // or 'localhost'; null binds all interfaces
  limits: const ServerLimits(maxSessions: 10, maxNodesPerRead: 1000),
);
```

With a certificate the server offers Basic256Sha256, Aes256Sha256RsaPss and
Aes128Sha256RsaOaep, each in Sign and SignAndEncrypt (`Server.endpoints`),
and verifies the client's certificate against the `trustList` (plus
`issuerList` and `revocationList`) before the channel opens; a client whose
certificate is in no list gets no channel. `acceptAllClientCertificates: true`
is the explicit opt-out (encrypted, not authenticated; a certificate with
neither is an `ArgumentError`, as on the client). SecurityPolicy None is then
off by default (`allowNone`; the None policy stays for discovery, so a client
can still call GetEndpoints) and a client that offers only None finds no
endpoint. Anonymous sessions are allowed exactly when `allowAnonymous` is,
on every endpoint; `users` are username/password logins that open62541's
default access-control plugin keeps in memory in plain text and compares in
constant time. A password over SecurityPolicy None travels in clear text,
and the server refuses it unless `allowUnencryptedPassword: true` (the
`Client` has the same opt-in); over an encrypted channel it is always
accepted. `ServerLimits` bounds what one client can ask for, and every
server has them: 100 secure channels and sessions, 1000 subscriptions (50
per session), 100 000 monitored items (10 000 per subscription), 10 000
nodes per Read, Write and Browse, 1000 methods per Call, 16 MiB per message
in at most 512 chunks (`ServerLimits.defaults`; a request beyond a limit is
answered `BadTooManyOperations`, `BadTooManySubscriptions`,
`BadTooManyMonitoredItems`, `BadTooManySessions` or `BadTcpMessageTooLarge`).
A field left out keeps its default, an explicit 0 lifts that cap (except
sessions and channels, which open62541 cannot leave uncapped: 65535 is the
ceiling), and `ServerLimits.unlimited` lifts every cap for a server whose
clients are all known to behave. `Server.limits` reports what is in force.

Who may do what is `authorization`: hooks that open62541 asks per session,
each optional, each given the session (`MethodSessionInfo`, whose `identity`
is anonymous, a username or a certificate subject):

```dart
final server = Server(
  users: {'operator': '...', 'viewer': '...'},
  authorization: ServerAuthorization(
    userAccessLevel: (session, node) => switch (session.identity) {
      UsernameSessionIdentity(username: 'operator') => null, // the node's own
      _ => const AccessLevelMask(read: true),
    },
    userExecutable: (session, method, object) => session.identity is UsernameSessionIdentity,
    allowBrowse: (session, node) => node != secretFolder,
  ),
);
```

A hook only restricts: open62541 ANDs the user access level with the node's
own, so a read-only node stays read-only. What it refuses is answered
`BadUserAccessDenied` (a Read or Write of the value, a Call, a Browse of the
node and a Read of its other attributes). The host's own `read`, `write` and
`add...Node` calls are never asked. The hooks run synchronously on the
server's isolate inside `runIterate`, `userAccessLevel` once per value read
or written, so they must be quick; the session's identity is looked up once
per session, and a trivial hook adds about 0.1 µs to a read. A hook that
throws denies.

### Monitoring with quality

`monitor` / `monitoredItems` deliver the value alone: a notification with a
non-Good status becomes a `UaStatusException` *error* event on the stream and
nothing is delivered for it. To get every sample with the status code and the
timestamps the server attached to it, use `monitorDataValue` /
`monitoredDataValues`, which emit the same `DataValue` that `readValue`
returns:

```dart
final subscriptionId = await client.subscriptionCreate();
client.monitorDataValue(nodeId, subscriptionId).listen((sample) {
  // statusCode 0 is Good; isGood / isUncertain / isBad read the severity.
  // sourceTimestamp and serverTimestamp are null when the server sent none.
  print('${sample.value.value} ${statusCodeToString(sample.statusCode)} at ${sample.sourceTimestamp}');
});
```

A Bad sample is delivered with the value it carries, or else the last known
one; a Good sample without a value is a null value. Every event is a fresh
`DataValue` (the value copied), on `Client` and on `ClientIsolate` alike, so
it is safe to keep. The two methods are declared on `DataValueMonitoringApi`,
which both clients implement next to `ClientApi`; code that holds a
`ClientApi` checks `is DataValueMonitoringApi` to reach them. `ClientApi`
itself is unchanged, so a class written against it keeps compiling.

### PubSub (UDP multicast)

Both PubSub roles are configured on a `Server` (per OPC UA Part 14 the
subscriber also lives on a server instance). Publisher:

```dart
final connection = server.addPubSubConnection(
  name: 'UADP Connection',
  url: 'opc.udp://224.0.0.22:4840/',
  publisherId: PubSubPublisherId.uint16(2234),
);
final pds = server.addPublishedDataSet(name: 'Demo PDS');
server.addDataSetField(pds, name: 'Counter', publishedVariable: counterNodeId);
final group = server.addWriterGroup(connection,
    name: 'WG', writerGroupId: 100, publishingInterval: Duration(milliseconds: 100));
server.addDataSetWriter(group, pds, name: 'DSW', dataSetWriterId: 62541);
server.enableAllPubSubComponents();
```

Subscriber (on another — or the same — server):

```dart
final connection = server.addPubSubConnection(name: 'Sub', url: 'opc.udp://224.0.0.22:4840/');
final readerGroup = server.addReaderGroup(connection, name: 'RG');
final reader = server.addDataSetReader(readerGroup,
    name: 'DSR',
    publisherId: PubSubPublisherId.uint16(2234),
    writerGroupId: 100,
    dataSetWriterId: 62541,
    dataSetName: 'Demo PDS',
    fields: [DataSetFieldMeta(name: 'Counter', dataType: NodeId.int32)]);
server.setDataSetReaderTargetVariables(reader, [targetNodeId]);
server.onValueChanged(targetNodeId).listen((v) => print('received: ${v.value}'));
server.enableAllPubSubComponents();
```

### Using the types on the web

`package:open62541/open62541.dart` imports `dart:ffi`, which makes a Flutter
web build a compile error, not a runtime one. Code that only passes values
around — an HMI widget that renders a `DynamicValue`, a model that keys on
`NodeId` — imports the pure-Dart barrel instead:

```dart
import 'package:open62541/open62541_types.dart';

final motor = DynamicValue(typeId: NodeId.fromString(2, 'ST_Motor'))
  ..['run'] = DynamicValue(value: true)
  ..['speed'] = DynamicValue(value: 1450);
print('${motor.typeId}: ${motor['speed'].asInt}'); // ns=2;s=ST_Motor: 1450
```

It exports `DynamicValue`, `DynamicType`, `LocalizedText`, `EnumField`,
`Schema` and `NodeId` (with every namespace-0 static, `NodeId.server`,
`NodeId.serverStatusCurrentTime`, ...), and nothing that needs the native
library. Keep the `Client`/`Server` behind a platform-conditional import or in
a separate package; a web build still runs this package's build hook, which
returns without building anything when no code assets are requested.

The FFI conversions on `NodeId` live in `extension NodeIdFfi` in the main
library: `nodeId.toRaw()` resolves as before, and what used to be
`NodeId.fromRaw(raw)` is `NodeIdFfi.fromRaw(raw)`.

`test/web/types_web_test.dart` compiles the barrel with dart2js and runs it in
Chrome (`dart test -p chrome test/web`); CI runs it on every push.

## Development

The sections below are only relevant if you are hacking on the package itself
(for example regenerating the FFI bindings), not for normal use.

### Regenerating the bindings

The native library is built automatically by `hook/build.dart`, which downloads a
pinned open62541 source archive and builds it with CMake (amalgamation enabled,
so it also produces a single `open62541.h`). You do **not** need to build
open62541 by hand for normal use.

To regenerate the FFI bindings (for example after bumping the open62541 version),
build once, then copy the amalgamated header the hook produced and run the
generator:

```bash
dart test test/verify_version_test.dart   # triggers the hook build

# Locate the amalgamated header (the path is OS/arch-specific):
find .dart_tool/hooks_runner -name open62541.h
# e.g. on macOS/arm64:
cp .dart_tool/hooks_runner/shared/open62541/build/dl/src/build/macos/arm64/open62541.h \
   third_party/open62541/open62541.h

bash open62541_tooling/patch_header.sh
dart run tool/ffigen.dart
```

`ffigen` needs libclang; on some Linux setups you may need to prefix the last
command with `CPATH=/usr/lib/clang/<version>/include:/usr/include`.

The header patch removes the bitfields from `UA_DiagnosticInfo`, `UA_DataValue`,
`UA_DataTypeMember` and `UA_DataType`, replacing each with a single field (the
struct size is unchanged) so the generator does not drop the surrounding members.

### Sanitizer build

`touch .open62541_sanitizer` in the package root makes the hook build open62541
with ASan + UBSan (remove the file for the normal build). An environment
variable would not work: the hooks runner scrubs it before starting the hook.
Run the tests with the runtime preloaded:

```bash
LD_PRELOAD=$(gcc -print-file-name=libasan.so) ASAN_OPTIONS=detect_leaks=0 dart test
```

### Known limitations

- A multi-dimensional array that is a **member of a structure** is not modeled and
  decodes as an empty array. (Top-level multi-dimensional arrays are supported.)
- Structure-field descriptions are not carried over the wire by open62541
  (v1.5.x), so they do not surface from a remote server. For an in-process Dart
  `Server` + `Client`, descriptions are restored from the locally registered
  schema.
- `monitor` / `monitoredItems` do not surface per-notification status codes or
  timestamps on the value stream: a notification with a non-Good status is
  delivered as an *error* event on the stream (carrying the status), and its
  value/timestamps are dropped. Use `monitorDataValue` / `monitoredDataValues`
  (see [Monitoring with quality](#monitoring-with-quality)) or, for a one-off
  read, `Client.readValue`. The status and timestamps are those of the Value
  attribute's notification; `read` / `readAttribute` / `call` return a
  `DynamicValue` without them.
- `Server.statistics` exposes aggregate counters only (sessions, secure
  channels, subscriptions, total monitored items). Per-session and
  per-subscription diagnostic detail (client identity, publish rates, queue
  overflows, ...) exists in the NS0 diagnostics nodes but is not surfaced as a
  typed Dart API.
- PubSub: only the UDP + UADP transport is enabled (no MQTT/raw Ethernet), and
  message security (SKS / PubSub security policies), delta frames and
  DataSetMetaData ConfigurationVersion handling are not exposed. Dataset fields
  on the subscriber side must use builtin namespace-0 data types.

## License

MIT. See [LICENSE](LICENSE).
