# open62541 Dart bindings - WIP

Dart FFI bindings to the [open62541](https://github.com/open62541/open62541) OPC UA stack.

There is a raw example where read and subscribe are implemented.

## Building

The native library is built automatically by the Dart [build hook](hook/build.dart)
(`hook/build.dart`) whenever you run `dart pub get`, `dart test`, `dart run`, or build a
depending app. The hook:

1. Downloads the pinned upstream open62541 source (`v1.5.6`) directly from GitHub — no
   submodule and no fork.
2. Builds it with CMake and bundles the resulting shared library as a
   [code asset](https://dart.dev/interop/c-interop) so the `@Native` bindings resolve at
   runtime. No manual copying of `.so`/`.dylib`/`.dll` into `lib/`.

To bump the open62541 version, change `version` in `hook/build.dart` and regenerate the
bindings (see below).

### Prerequisites

- CMake and a C compiler.
- An encryption backend for open62541:
  - Linux: `sudo apt install libmbedtls-dev`
  - macOS: `brew install mbedtls`
  - Windows: `choco install openssl` (the hook uses OpenSSL on Windows, mbedTLS elsewhere)

### Notes on the build configuration

- `UA_MULTITHREADING=0` — Dart drives open62541 by calling `run_iterate` periodically from a
  single isolate, so multithreading must be off.
- `UA_ENABLE_INLINABLE_EXPORT=ON` — otherwise the API is emitted as `static inline` and the
  symbols are not exported for FFI.
- `UA_LOGLEVEL=100` (Trace) — levels: `600` Fatal, `500` Error, `400` Warning, `300` Info,
  `200` Debug, `100` Trace.

## Regenerating the bindings

The checked-in bindings (`lib/src/third_party/open62541.g.dart`) are generated from a patched
copy of open62541's amalgamated header. ffigen removes all members of any struct that contains
a bitfield, so `open62541_tooling/remove_bitfields.patch` replaces the bitfields of
`UA_DataValue`, `UA_DiagnosticInfo`, `UA_DataTypeMember`, and `UA_DataType` with a single
`substitute` field of the same width (the bits are decoded in `lib/src/extensions.dart`). The
struct sizes are unchanged, which `test/verify_sizes_test.dart` verifies.

1. Produce the amalgamated header for the pinned version (any CMake configure with
   `-DUA_ENABLE_AMALGAMATION=ON` emits `open62541.h`) and copy it to
   `third_party/open62541/open62541.h`.
2. Apply the bitfield patch:
   ```bash
   ./open62541_tooling/patch_header.sh   # -> third_party/open62541/open62541_modified.h
   ```
3. Generate the Dart bindings:
   ```bash
   dart run tool/ffigen.dart
   ```

## Known limitations

- Monitoring a structure with a multi-dimensional array member returns an empty array.
- Description of structure fields is not working.
- `monitoredItemCreate<List<dynamic>>` must be used instead of `List<int>` or another element type.
