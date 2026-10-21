import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

void main() {
  setUpAll(commitStackForWindowsProfiler);

  test('Version symbols accessible', () {
    expect(UA_OPEN62541_VER_MAJOR, greaterThanOrEqualTo(1));
    expect(UA_OPEN62541_VER_MINOR, greaterThanOrEqualTo(0));
    expect(UA_OPEN62541_VER_PATCH, greaterThanOrEqualTo(0));
    expect(UA_OPEN62541_VERSION, isNotEmpty);
  });

  test('UA_StatusCode_name symbol works', () {
    final name = raw.UA_StatusCode_name(raw.UA_STATUSCODE_GOOD);
    expect(name, isNotNull);
    final str = name.cast<Utf8>().toDartString();
    expect(str, equals('Good'));
  });

  test('UA_Variant new and delete', () {
    final variant = raw.UA_Variant_new();
    expect(variant, isNotNull);
    expect(variant.address, isNot(0));
    raw.UA_Variant_delete(variant);
  });

  test('UA_NodeId numeric creation', () {
    final nodeId = raw.UA_NODEID_NUMERIC(0, 85);
    expect(nodeId.namespaceIndex, equals(0));
    expect(nodeId.identifierType, equals(raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC));
    expect(nodeId.identifier.numeric, equals(85));
  });

  test('UA_Server creation with config', () {
    final config = ua_calloc<raw.UA_ServerConfig>();
    // Silence the native logger BEFORE setMinimal (which keeps a pre-set
    // logger) so the test output stays readable. Native stdout cannot corrupt
    // the test protocol: flutter_tools relays the tester's stdout line by line
    // ("Shell: ...") and the test events travel over a separate WebSocket.
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    final result = raw.UA_ServerConfig_setMinimal(config, 4840, nullptr);
    expect(result, equals(raw.UA_STATUSCODE_GOOD));
    // Server takes ownership of config
    final server = raw.UA_Server_newWithConfig(config);
    expect(server, isNotNull);
    expect(server.address, isNot(0));
    raw.UA_Server_delete(server);
  });

  test('UA_Client creation with config', () {
    final config = ua_calloc<raw.UA_ClientConfig>();
    raw.UA_ClientConfig_setDefault(config);
    // Same quiet logger as the server tests (see above).
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    expect(config.ref.timeout, greaterThan(0));
    // Client takes ownership of config
    final client = raw.UA_Client_newWithConfig(config);
    expect(client, isNotNull);
    expect(client.address, isNot(0));
    raw.UA_Client_delete(client);
  });

  test('Server wrapper can be created', () {
    final server = Server(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    expect(server, isNotNull);
    server.delete();
  });
}

/// Works around flutter/flutter#191069 on Windows: `flutter test` starts
/// flutter_tester with `--enable-dart-profiling`, which makes the Dart VM
/// sample this thread every millisecond and walk its stack from the sampled
/// `rbp`. A function with a large frame in open62541.dll (MSVC emits
/// `lea rbp,[rsp-0x103b8]; call __chkstk`) points `rbp` 66 KB below `rsp`
/// while `__chkstk` is still committing those pages, and the profiler's read
/// of a not-yet-committed stack page is an access violation that kills
/// flutter_tester with 0xC0000005. flutter_tools then discards the exit code,
/// so the run shows every test ✅, "🎉 4 tests passed." and exit 1 (two full
/// dumps taken with ProcDump on CI, both faulting in
/// dart::ProfilerNativeStackWalker::walk with the sampled thread in __chkstk).
///
/// Dart fixed the walker in 0a7701121e ("[vm, profiler] Refine the stack
/// boundary using the top SP", 2026-08-24); Flutter 3.47.x (Dart 3.13.5) and
/// the 3.48 beta (Dart 3.14.0-95) predate it. Until the stable channel ships
/// a Dart with the fix, commit the whole stack of the test thread once before
/// the first native call: Windows never decommits stack pages, so every later
/// sample reads committed memory and the race is harmless. Remove this when
/// the Windows Flutter job runs on a Flutter whose Dart contains that commit.
void commitStackForWindowsProfiler() {
  if (!Platform.isWindows) return;
  try {
    _touchStack(0);
  } on StackOverflowError {
    // The thread's usable stack is committed down to the VM's own limit.
  }
}

@pragma('vm:never-inline')
int _touchStack(int depth) => _touchStack(depth + 1) + 1;
