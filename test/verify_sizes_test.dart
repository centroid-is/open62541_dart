import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/src/access_control.dart' show UaUserNameIdentityToken, UaX509IdentityToken;
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/security.dart' show UaKeyValuePair;
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

typedef _Write = void Function(Pointer<Void> p);

/// Offset of each member of the native type [typeIndex], by the padding rules
/// of `UA_DataTypeMember`. An array member's offset is that of its `size_t`.
Map<String, int> _nativeOffsets(int typeIndex) {
  final type = getTypeByIndex(typeIndex).ref;
  final offsets = <String, int>{};
  var offset = 0;
  for (var i = 0; i < type.membersSize; i++) {
    final member = type.members[i];
    offset += member.padding;
    offsets[member.memberName.cast<Utf8>().toDartString()] = offset;
    offset += member.isArray
        ? sizeOf<Size>() + sizeOf<Pointer>()
        : member.isOptional
        ? sizeOf<Pointer>()
        : member.memberType.ref.memSize;
  }
  return offsets;
}

/// The offset at which [write] puts its first non-zero byte into zeroed memory.
int _dartOffset(int size, _Write write) {
  final buffer = calloc<Uint8>(size);
  try {
    write(buffer.cast());
    return buffer.asTypedList(size).indexWhere((byte) => byte != 0);
  } finally {
    calloc.free(buffer);
  }
}

/// Pins a bound struct to the native type table: its size is the type's
/// `memSize`, and every member [fields] writes (each writes a value whose
/// first byte is non-zero) sits at the member's native offset.
void _expectLayout(int typeIndex, int dartSize, Map<String, _Write> fields) {
  final type = getTypeByIndex(typeIndex).ref;
  final name = type.typeName.cast<Utf8>().toDartString();
  expect(dartSize, type.memSize, reason: '$name size');
  final native = _nativeOffsets(typeIndex);
  expect(fields.keys, unorderedEquals(native.keys), reason: '$name members');
  for (final field in fields.entries) {
    expect(_dartOffset(type.memSize, field.value), native[field.key], reason: '$name.${field.key}');
  }
}

void main() {
  test("Verify sizes", () {
    // UA_ClientConfig is unchanged by enabling PubSub (the PubSub subscriber
    // hangs off UA_Server, not UA_Client). open62541 v1.5.9 appended the
    // internal `securityPolicyHistory` pointer (888 -> 896 on 64-bit).
    expect(sizeOf<raw.UA_ClientConfig>(), 896);
    expect(sizeOf<raw.UA_DataType>(), 96);
    // Hand-added binding (tool/ffigen.dart lists it for the next
    // regeneration): four pointers and a size_t.
    expect(sizeOf<raw.UA_DecodeBinaryOptions>(), 4 * sizeOf<Pointer>() + sizeOf<Size>());
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
    // UA_ServerConfig grew with UA_ENABLE_PUBSUB (it now embeds the
    // UA_PubSubConfiguration). Pin the layout of the config structs the Dart
    // wrappers fill so a bindings/native drift fails loudly here rather than
    // as memory corruption.
    expect(sizeOf<raw.UA_ServerConfig>(), 1184);
    expect(sizeOf<raw.UA_PubSubConnectionConfig>(), 192);
    expect(sizeOf<raw.UA_WriterGroupConfig>(), 224);
    expect(sizeOf<raw.UA_DataSetReaderConfig>(), 376);
    // Hand-added to the bindings (tool/ffigen.dart lists them for the next
    // regeneration): the ObjectType attributes Server.addObjectTypeNode fills
    // and the BrowseResult UA_Server_browse returns by value.
    expect(sizeOf<raw.UA_ObjectTypeAttributes>(), getTypeByIndex(raw.UA_TYPES_OBJECTTYPEATTRIBUTES).ref.memSize);
    expect(sizeOf<raw.UA_BrowseResult>(), getTypeByIndex(raw.UA_TYPES_BROWSERESULT).ref.memSize);
  });
  test("History structs match the native type table", () {
    _expectLayout(raw.UA_TYPES_HISTORYREADVALUEID, sizeOf<raw.UA_HistoryReadValueId>(), {
      'NodeId': (p) => p.cast<raw.UA_HistoryReadValueId>().ref.nodeId.namespaceIndex = 1,
      'IndexRange': (p) => p.cast<raw.UA_HistoryReadValueId>().ref.indexRange.length = 1,
      'DataEncoding': (p) => p.cast<raw.UA_HistoryReadValueId>().ref.dataEncoding.namespaceIndex = 1,
      'ContinuationPoint': (p) => p.cast<raw.UA_HistoryReadValueId>().ref.continuationPoint.length = 1,
    });
    _expectLayout(raw.UA_TYPES_HISTORYREADRESULT, sizeOf<raw.UA_HistoryReadResult>(), {
      'StatusCode': (p) => p.cast<raw.UA_HistoryReadResult>().ref.statusCode = 1,
      'ContinuationPoint': (p) => p.cast<raw.UA_HistoryReadResult>().ref.continuationPoint.length = 1,
      'HistoryData': (p) => p.cast<raw.UA_HistoryReadResult>().ref.historyData.encodingAsInt = 1,
    });
    _expectLayout(raw.UA_TYPES_HISTORYREADREQUEST, sizeOf<raw.UA_HistoryReadRequest>(), {
      'RequestHeader': (p) =>
          p.cast<raw.UA_HistoryReadRequest>().ref.requestHeader.authenticationToken.namespaceIndex = 1,
      'HistoryReadDetails': (p) => p.cast<raw.UA_HistoryReadRequest>().ref.historyReadDetails.encodingAsInt = 1,
      'TimestampsToReturn': (p) => p.cast<raw.UA_HistoryReadRequest>().ref.timestampsToReturnAsInt = 1,
      'ReleaseContinuationPoints': (p) => p.cast<raw.UA_HistoryReadRequest>().ref.releaseContinuationPoints = true,
      'NodesToRead': (p) => p.cast<raw.UA_HistoryReadRequest>().ref.nodesToReadSize = 1,
    });
    _expectLayout(raw.UA_TYPES_HISTORYREADRESPONSE, sizeOf<raw.UA_HistoryReadResponse>(), {
      'ResponseHeader': (p) => p.cast<raw.UA_HistoryReadResponse>().ref.responseHeader.timestamp = 1,
      'Results': (p) => p.cast<raw.UA_HistoryReadResponse>().ref.resultsSize = 1,
      'DiagnosticInfos': (p) => p.cast<raw.UA_HistoryReadResponse>().ref.diagnosticInfosSize = 1,
    });
    _expectLayout(raw.UA_TYPES_HISTORYDATA, sizeOf<raw.UA_HistoryData>(), {
      'DataValues': (p) => p.cast<raw.UA_HistoryData>().ref.dataValuesSize = 1,
    });
    _expectLayout(raw.UA_TYPES_HISTORYUPDATERESULT, sizeOf<raw.UA_HistoryUpdateResult>(), {
      'StatusCode': (p) => p.cast<raw.UA_HistoryUpdateResult>().ref.statusCode = 1,
      'OperationResults': (p) => p.cast<raw.UA_HistoryUpdateResult>().ref.operationResultsSize = 1,
      'DiagnosticInfos': (p) => p.cast<raw.UA_HistoryUpdateResult>().ref.diagnosticInfosSize = 1,
    });
    _expectLayout(raw.UA_TYPES_READRAWMODIFIEDDETAILS, sizeOf<raw.UA_ReadRawModifiedDetails>(), {
      'IsReadModified': (p) => p.cast<raw.UA_ReadRawModifiedDetails>().ref.isReadModified = true,
      'StartTime': (p) => p.cast<raw.UA_ReadRawModifiedDetails>().ref.startTime = 1,
      'EndTime': (p) => p.cast<raw.UA_ReadRawModifiedDetails>().ref.endTime = 1,
      'NumValuesPerNode': (p) => p.cast<raw.UA_ReadRawModifiedDetails>().ref.numValuesPerNode = 1,
      'ReturnBounds': (p) => p.cast<raw.UA_ReadRawModifiedDetails>().ref.returnBounds = true,
    });
    _expectLayout(raw.UA_TYPES_READATTIMEDETAILS, sizeOf<raw.UA_ReadAtTimeDetails>(), {
      'ReqTimes': (p) => p.cast<raw.UA_ReadAtTimeDetails>().ref.reqTimesSize = 1,
      'UseSimpleBounds': (p) => p.cast<raw.UA_ReadAtTimeDetails>().ref.useSimpleBounds = true,
    });
    _expectLayout(raw.UA_TYPES_READPROCESSEDDETAILS, sizeOf<raw.UA_ReadProcessedDetails>(), {
      'StartTime': (p) => p.cast<raw.UA_ReadProcessedDetails>().ref.startTime = 1,
      'EndTime': (p) => p.cast<raw.UA_ReadProcessedDetails>().ref.endTime = 1,
      // The smallest subnormal: its only set bit is in the lowest byte.
      'ProcessingInterval': (p) => p.cast<raw.UA_ReadProcessedDetails>().ref.processingInterval = double.minPositive,
      'AggregateType': (p) => p.cast<raw.UA_ReadProcessedDetails>().ref.aggregateTypeSize = 1,
      'AggregateConfiguration': (p) =>
          p.cast<raw.UA_ReadProcessedDetails>().ref.aggregateConfiguration.useServerCapabilitiesDefaults = true,
    });
  });
  test("Security structs match the native type table", () {
    _expectLayout(raw.UA_TYPES_TRUSTLISTDATATYPE, sizeOf<raw.UA_TrustListDataType>(), {
      'SpecifiedLists': (p) => p.cast<raw.UA_TrustListDataType>().ref.specifiedLists = 1,
      'TrustedCertificates': (p) => p.cast<raw.UA_TrustListDataType>().ref.trustedCertificatesSize = 1,
      'TrustedCrls': (p) => p.cast<raw.UA_TrustListDataType>().ref.trustedCrlsSize = 1,
      'IssuerCertificates': (p) => p.cast<raw.UA_TrustListDataType>().ref.issuerCertificatesSize = 1,
      'IssuerCrls': (p) => p.cast<raw.UA_TrustListDataType>().ref.issuerCrlsSize = 1,
    });
    // Not a UA_TYPES entry: a plain {UA_String, UA_ByteString}.
    expect(sizeOf<raw.UA_UsernamePasswordLogin>(), 2 * getTypeByIndex(raw.UA_TYPES_STRING).ref.memSize);
    _expectLayout(raw.UA_TYPES_USERNAMEIDENTITYTOKEN, sizeOf<UaUserNameIdentityToken>(), {
      'PolicyId': (p) => p.cast<UaUserNameIdentityToken>().ref.policyId.length = 1,
      'UserName': (p) => p.cast<UaUserNameIdentityToken>().ref.userName.length = 1,
      'Password': (p) => p.cast<UaUserNameIdentityToken>().ref.password.length = 1,
      'EncryptionAlgorithm': (p) => p.cast<UaUserNameIdentityToken>().ref.encryptionAlgorithm.length = 1,
    });
    _expectLayout(raw.UA_TYPES_X509IDENTITYTOKEN, sizeOf<UaX509IdentityToken>(), {
      'PolicyId': (p) => p.cast<UaX509IdentityToken>().ref.policyId.length = 1,
      'CertificateData': (p) => p.cast<UaX509IdentityToken>().ref.certificateData.length = 1,
    });
    _expectLayout(raw.UA_TYPES_KEYVALUEPAIR, sizeOf<UaKeyValuePair>(), {
      'Key': (p) => p.cast<UaKeyValuePair>().ref.key.namespaceIndex = 1,
      'Value': (p) => p.cast<UaKeyValuePair>().ref.value.type = Pointer.fromAddress(1),
    });
  });
  test("History types are reachable through UaTypes", () {
    for (final (type, name) in [
      (UaTypes.historyReadValueId, 'HistoryReadValueId'),
      (UaTypes.historyReadResult, 'HistoryReadResult'),
      (UaTypes.historyReadRequest, 'HistoryReadRequest'),
      (UaTypes.historyReadResponse, 'HistoryReadResponse'),
      (UaTypes.historyData, 'HistoryData'),
      (UaTypes.historyUpdateResult, 'HistoryUpdateResult'),
      (UaTypes.readRawModifiedDetails, 'ReadRawModifiedDetails'),
      (UaTypes.readAtTimeDetails, 'ReadAtTimeDetails'),
      (UaTypes.readProcessedDetails, 'ReadProcessedDetails'),
    ]) {
      expect(getType(type).ref.typeName.cast<Utf8>().toDartString(), name);
    }
  });
  test("Verify types", () {
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
    expect(getType(UaTypes.readRequest).ref.typeName.cast<Utf8>().toDartString(), "ReadRequest");
    expect(getType(UaTypes.readResponse).ref.typeName.cast<Utf8>().toDartString(), "ReadResponse");
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
  });
}
