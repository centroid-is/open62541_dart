# Changelog

## 1.5.7

- Bump bundled open62541 from `v1.5.6` to `v1.5.7`.
  - Upstream v1.5.7 is a maintenance release focused on security hardening and
    stability: rejects custom DataType definitions that overflow
    `memSize`/`membersSize`, fixes a PubSub off-by-one heap-OOB read in
    `getFieldMetaData`, guards several server-side use-after-free / NULL-deref /
    recursion-depth issues, and tightens URI and certificate-subject handling in
    plugins. See https://github.com/open62541/open62541/releases/tag/v1.5.7.
- Regenerated the amalgamated header (`third_party/open62541/open62541_modified.h`),
  the `remove_bitfields.patch` line offsets, and the ffigen bindings
  (`lib/src/third_party/open62541.g.dart`) against v1.5.7.
- Struct layouts are unchanged: `UA_ClientConfig` (888 bytes) and `UA_DataType`
  (96 bytes) match the previous release, so `verify_sizes_test` still passes.
