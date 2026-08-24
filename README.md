# open62541 for Dart

Dart FFI bindings to the [open62541](https://www.open62541.org/) OPC UA stack.
This package provides idiomatic Dart client and server APIs for OPC UA over TCP,
including subscriptions, custom types and encrypted (mbedTLS) connections.

> Status: work in progress. The API is functional but still evolving and may
> change between releases.

## Features

- **Client**: connect / reconnect, browse and recursive tree browsing, read,
  subscriptions and monitored items, and secure connections with certificates
  (`SignAndEncrypt`).
- **Server**: expose scalar, array and structure (custom type) variable nodes,
  data-type nodes, and monitor variables via streams.
- **Encryption** via mbedTLS.
- **`DynamicValue`** for ergonomic access to OPC UA values, including structures
  and arrays.

## Supported platforms

Linux, macOS, Windows, Android and iOS. (Web is not supported — this is a native
FFI binding.)

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
  open62541: ^1.5.7
```

Then run `dart pub get` (allow extra time for the first native build).

## Versioning

The package version mirrors the bundled open62541 release exactly: `1.5.7` wraps
open62541 `v1.5.7`. Dart-side fixes that ship the **same** native library version
use a build-metadata suffix — `1.5.7+1`, `1.5.7+2`, … — which pub.dev orders
after `1.5.7`. So `open62541: ^1.5.7` accepts `1.5.7`, any binding-only `+N`
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
(`server_example.dart`) and a secure self-healing client
(`resilient_client.dart`).

> **Threading note:** open62541 is built with multithreading disabled, so the
> client/server event loop must be driven periodically by calling `runIterate`
> as shown above.

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

### Known limitations

- A multi-dimensional array that is a **member of a structure** is not modeled and
  decodes as an empty array. (Top-level multi-dimensional arrays are supported.)
- Structure-field descriptions are not carried over the wire by open62541
  (v1.5.x), so they do not surface from a remote server. For an in-process Dart
  `Server` + `Client`, descriptions are restored from the locally registered
  schema.

## License

MIT. See [LICENSE](LICENSE).
