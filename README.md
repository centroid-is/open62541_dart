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

### Building open62541 manually

```bash
mkdir open62541_build
cd open62541_build
cmake ../open62541/ -DBUILD_SHARED_LIBS=ON -DUA_ENABLE_INLINABLE_EXPORT=ON \
  -DCMAKE_INSTALL_PREFIX=install -DUA_BUILD_EXAMPLES=OFF \
  -DUA_BUILD_UNIT_TESTS=OFF -DUA_ENABLE_AMALGAMATION=ON -DUA_MULTITHREADING=0
make
```

`-DUA_ENABLE_INLINABLE_EXPORT=ON` is required so that methods are not exported as
`static inline` (otherwise the functions are skipped by the bindings generator).
Optionally set `-DUA_LOGLEVEL=100` to control the log level (600 Fatal, 500
Error, 400 Warning, 300 Info, 200 Debug, 100 Trace).

### Regenerating the bindings

After building, copy the generated header and regenerate:

```bash
cp .dart_tool/hooks_runner/shared/open62541/build/download/open62541-includes/build/linux/x64/open62541.h third_party/open62541/open62541.h
bash open62541_tooling/patch_header.sh
CPATH="/usr/lib/clang/21/include:/usr/include" dart run tool/ffigen.dart
```

The header patch removes the bitfields from `UA_DiagnosticsInfo`,
`UA_DataValue`, `UA_DataTypeMember` and `UA_DataType`, replacing them with a
single byte (the struct size is unchanged).

### Known limitations

- Monitoring a structure with a multi-dimensional array member yields an empty
  array.
- Descriptions of structure fields are not propagated.
- `monitoredItemCreate<List<dynamic>>` must be used instead of a concrete
  element type such as `List<int>`.

## License

MIT. See [LICENSE](LICENSE).
