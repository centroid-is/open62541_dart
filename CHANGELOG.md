# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## 1.5.7

- Bump bundled open62541 from `v1.5.6` to `v1.5.7`.
  - Upstream v1.5.7 is a maintenance release focused on security hardening and
    stability: rejects custom DataType definitions that overflow
    `memSize`/`membersSize`, fixes a PubSub off-by-one heap-OOB read in
    `getFieldMetaData`, guards several server-side use-after-free / NULL-deref /
    recursion-depth issues, and tightens URI and certificate-subject handling in
    plugins. See https://github.com/open62541/open62541/releases/tag/v1.5.7.
  - Regenerated the amalgamated header
    (`third_party/open62541/open62541_modified.h`), the `remove_bitfields.patch`
    line offsets, and the ffigen bindings (`lib/src/third_party/open62541.g.dart`)
    against v1.5.7. Struct layouts are unchanged: `UA_ClientConfig` (888 bytes)
    and `UA_DataType` (96 bytes) match the previous release, so
    `verify_sizes_test` still passes.
- Hardened the native build hook (`hook/build.dart`): every third-party source
  archive is now fetched over HTTPS (scheme enforced in code) and verified
  against a pinned SHA-256 before use, failing the build loudly on mismatch.
- Prepared the package for pub.dev publishing: expanded the description, added
  `homepage`/`issue_tracker` metadata, raised the SDK floor to `^3.10.0` (native
  build hooks are stable from Dart 3.10), and added an `example/`.

Native-build feature set (built from source at install time via Dart native
build hooks, downloading open62541 and mbedTLS `3.6.5` and building them with
CMake):

- Enable OPC UA encryption through mbedTLS (`SignAndEncrypt`).
- Force little-endian IEEE 754 float encoding so subnormal `Float`/`Double`
  values round-trip correctly on all supported targets.
- Patch the client subscription handler so `deleteCallback` fires for every
  client-side subscription when the server reports `BadNoSubscription`
  (OPC UA Part 4, 5.13.5).
- Client APIs: connect/reconnect, browse and recursive tree browse,
  subscriptions and monitored items, secure connections with certificates.
- Server APIs: variable nodes, array and structure (custom type) nodes,
  data-type nodes, and variable monitoring streams.
- Supports Linux, macOS, Windows, Android and iOS.
