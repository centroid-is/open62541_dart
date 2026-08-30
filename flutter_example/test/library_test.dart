import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

void main() {
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
    // logger): open62541's log lines share stdout with flutter test's
    // machine-readable JSON event stream, and an interleaved write can
    // corrupt an event mid-line — the tool then miscounts tests and exits 1
    // with every test green (seen as Windows CI flakiness).
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
    // Same stdout-quieting as the server tests (see above).
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
