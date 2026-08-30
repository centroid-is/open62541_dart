import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

void main() {
  test("Verify sizes", () {
    expect(sizeOf<raw.UA_ClientConfig>(), 888);
    expect(sizeOf<raw.UA_DataType>(), 96);
    // Statistics structs (Server.statistics). UA_ServerStatistics is returned
    // by value from UA_Server_getStatistics; the diagnostics data types are
    // cast straight out of native variant memory, so their Dart layout must
    // match the native one — compare against the native type table's memSize.
    expect(
      sizeOf<raw.UA_ServerStatistics>(),
      sizeOf<raw.UA_SecureChannelStatistics>() + sizeOf<raw.UA_SessionStatistics>(),
    );
    expect(
      sizeOf<raw.UA_ServerDiagnosticsSummaryDataType>(),
      getTypeByIndex(raw.UA_TYPES_SERVERDIAGNOSTICSSUMMARYDATATYPE).ref.memSize,
    );
    expect(
      sizeOf<raw.UA_SubscriptionDiagnosticsDataType>(),
      getTypeByIndex(raw.UA_TYPES_SUBSCRIPTIONDIAGNOSTICSDATATYPE).ref.memSize,
    );
  });
  test("Verify types", () {
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
    expect(getType(UaTypes.readRequest).ref.typeName.cast<Utf8>().toDartString(), "ReadRequest");
    expect(getType(UaTypes.readResponse).ref.typeName.cast<Utf8>().toDartString(), "ReadResponse");
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
  });
}
