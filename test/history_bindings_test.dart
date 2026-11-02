// The Historizing and AccessLevel attribute bindings, exercised on a node of a
// running server before any Dart API wraps them.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

/// A bare native server; `Server` does not hand out its pointer.
ffi.Pointer<raw.UA_Server> _rawServer() => using((arena) {
  final config = arena<raw.UA_ServerConfig>();
  config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
  expect(raw.UA_ServerConfig_setMinimal(config, 0, ffi.nullptr), raw.UA_STATUSCODE_GOOD);
  return raw.UA_Server_newWithConfig(config);
}, ua_calloc);

void main() {
  test('Historizing and AccessLevel round-trip through the raw bindings', () {
    final native = _rawServer();
    try {
      using((arena) {
        final currentTime = raw.UA_NODEID_NUMERIC(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME);
        final historizing = arena<ffi.Bool>();
        final accessLevel = arena<ffi.Uint8>();
        expect(raw.UA_Server_writeHistorizing(native, currentTime, true), raw.UA_STATUSCODE_GOOD);
        expect(raw.UA_Server_readHistorizing(native, currentTime, historizing), raw.UA_STATUSCODE_GOOD);
        expect(historizing.value, isTrue);
        final level = raw.UA_ACCESSLEVELMASK_READ | raw.UA_ACCESSLEVELMASK_HISTORYREAD;
        expect(raw.UA_Server_writeAccessLevel(native, currentTime, level), raw.UA_STATUSCODE_GOOD);
        expect(raw.UA_Server_readAccessLevel(native, currentTime, accessLevel), raw.UA_STATUSCODE_GOOD);
        expect(accessLevel.value, level);
      }, ua_calloc);
    } finally {
      raw.UA_Server_delete(native);
    }
  });
}
