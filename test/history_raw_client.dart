import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

/// One DataValue of a HistoryRead result, copied out of the response.
class RawHistoryValue {
  RawHistoryValue(this.value, this.status, this.sourceTimestamp, this.serverTimestamp, this.flags);

  final Object? value;
  final int status;
  final int sourceTimestamp;
  final int serverTimestamp;

  /// The DataValue's flag byte: hasValue 0x01, hasStatus 0x02,
  /// hasSourceTimestamp 0x04, hasServerTimestamp 0x08.
  final int flags;
}

/// One node's HistoryReadResult, copied out of the response.
class RawHistoryResult {
  RawHistoryResult(this.statusCode, this.continuationPoint, this.values, {required this.dataValuesNull});

  final int statusCode;
  final Uint8List? continuationPoint;
  final List<RawHistoryValue> values;

  /// The HistoryData's array was encoded as null (length -1) rather than empty.
  final bool dataValuesNull;
}

class RawHistoryResponse {
  RawHistoryResponse(this.serviceResult, this.results);

  final int serviceResult;
  final List<RawHistoryResult> results;
}

/// A HistoryRead request on the wire: its request handle (for Cancel) and
/// its response.
class PendingHistoryRead {
  PendingHistoryRead(this.requestHandle, this.response);

  final int requestHandle;
  final Future<RawHistoryResponse> response;
}

/// One node to read: [nodeId] and the [continuationPoint] of a previous page.
typedef RawHistoryNode = ({NodeId nodeId, Uint8List? continuationPoint});

/// The HistoryReadDetails of a request: a malloc'd value of [type], owned by
/// the request once passed (freed with it).
typedef RawHistoryDetails = ({ffi.Pointer<raw.UA_DataType> type, ffi.Pointer<ffi.Void> data});

RawHistoryDetails readRawDetails({
  int startTime = 0,
  int endTime = 0,
  int numValuesPerNode = 0,
  bool returnBounds = false,
  bool isReadModified = false,
}) {
  final details = ua_calloc<raw.UA_ReadRawModifiedDetails>();
  details.ref
    ..isReadModified = isReadModified
    ..startTime = startTime
    ..endTime = endTime
    ..numValuesPerNode = numValuesPerNode
    ..returnBounds = returnBounds;
  return (type: getType(UaTypes.readRawModifiedDetails), data: details.cast());
}

/// A raw open62541 client that sends HistoryRead through
/// `UA_Client_AsyncService` (the library's `Client` has no HistoryRead of its
/// own here). Pumped by a timer until [delete].
class RawHistoryClient {
  RawHistoryClient._(this.client) {
    _pump = Timer.periodic(const Duration(milliseconds: 5), (_) => raw.UA_Client_run_iterate(client, 0));
  }

  final ffi.Pointer<raw.UA_Client> client;
  late final Timer _pump;
  final _callbacks = <ffi.NativeCallable>[];
  // The client numbers requests from 100000 on; a handle set in the request
  // header is kept, which is what lets [cancel] name the request.
  var _nextRequestHandle = 1;

  static Future<RawHistoryClient> connect(int port) async {
    final config = ua_calloc<raw.UA_ClientConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    raw.UA_ClientConfig_setDefault(config);
    final client = raw.UA_Client_newWithConfig(config);
    ua_calloc.free(config);
    using((arena) {
      final url = 'opc.tcp://127.0.0.1:$port'.toNativeUtf8(allocator: arena);
      expect(raw.UA_Client_connectAsync(client, url.cast()), raw.UA_STATUSCODE_GOOD);
    }, ua_calloc);
    final channelState = ua_calloc<ffi.UnsignedInt>();
    final sessionState = ua_calloc<ffi.UnsignedInt>();
    final connectStatus = ua_calloc<ffi.Uint32>();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        raw.UA_Client_run_iterate(client, 5);
        raw.UA_Client_getState(client, channelState, sessionState, connectStatus);
        if (sessionState.value == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED.value) break;
        if (DateTime.now().isAfter(deadline)) {
          fail('raw client failed to connect to port $port');
        }
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      ua_calloc.free(channelState);
      ua_calloc.free(sessionState);
      ua_calloc.free(connectStatus);
    }
    return RawHistoryClient._(client);
  }

  /// Sends a HistoryRead for [nodes] with [details] (default: ReadRaw over
  /// all time).
  PendingHistoryRead send(
    List<RawHistoryNode> nodes, {
    RawHistoryDetails? details,
    raw.UA_TimestampsToReturn timestampsToReturn = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
    bool releaseContinuationPoints = false,
  }) {
    final d = details ?? readRawDetails();
    final request = raw.UA_HistoryReadRequest_new();
    final requestHandle = _nextRequestHandle++;
    request.ref.requestHeader.requestHandle = requestHandle;
    request.ref.historyReadDetails.encoding = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED;
    request.ref.historyReadDetails.content.decoded.type = d.type;
    request.ref.historyReadDetails.content.decoded.data = d.data;
    request.ref.timestampsToReturn = timestampsToReturn;
    request.ref.releaseContinuationPoints = releaseContinuationPoints;
    if (nodes.isNotEmpty) {
      final ids = raw.UA_Array_new(nodes.length, getType(UaTypes.historyReadValueId)).cast<raw.UA_HistoryReadValueId>();
      for (var i = 0; i < nodes.length; i++) {
        // Allocated with ua_calloc (libc), freed by UA_HistoryReadRequest_delete.
        ids[i].nodeId = nodes[i].nodeId.toRaw(allocator: ua_calloc);
        final cp = nodes[i].continuationPoint;
        if (cp != null && cp.isNotEmpty) {
          final bytes = ua_calloc<ffi.Uint8>(cp.length);
          bytes.asTypedList(cp.length).setAll(0, cp);
          ids[i].continuationPoint.data = bytes;
          ids[i].continuationPoint.length = cp.length;
        }
      }
      request.ref.nodesToRead = ids;
      request.ref.nodesToReadSize = nodes.length;
    }

    final response = _service(
      request.cast(),
      getType(UaTypes.historyReadRequest),
      getType(UaTypes.historyReadResponse),
      (ptr) => _decode(ptr.cast<raw.UA_HistoryReadResponse>().ref),
    );
    raw.UA_HistoryReadRequest_delete(request);
    return PendingHistoryRead(requestHandle, response);
  }

  /// Sends [request] and decodes the response with [decode] inside the
  /// callback (the response is freed when it returns).
  Future<T> _service<T>(
    ffi.Pointer<ffi.Void> request,
    ffi.Pointer<raw.UA_DataType> requestType,
    ffi.Pointer<raw.UA_DataType> responseType,
    T Function(ffi.Pointer<ffi.Void> response) decode,
  ) {
    final completer = Completer<T>();
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> _, ffi.Pointer<ffi.Void> _, int _, ffi.Pointer<ffi.Void> ptr) {
          completer.complete(decode(ptr));
        });
    _callbacks.add(callback);
    final status = raw.UA_Client_AsyncService(
      client,
      request,
      requestType,
      callback.nativeFunction,
      responseType,
      ffi.nullptr,
      ffi.nullptr,
    );
    expect(status, raw.UA_STATUSCODE_GOOD);
    return completer.future.timeout(const Duration(seconds: 15));
  }

  Future<RawHistoryResponse> read(
    List<RawHistoryNode> nodes, {
    RawHistoryDetails? details,
    raw.UA_TimestampsToReturn timestampsToReturn = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
    bool releaseContinuationPoints = false,
  }) => send(
    nodes,
    details: details,
    timestampsToReturn: timestampsToReturn,
    releaseContinuationPoints: releaseContinuationPoints,
  ).response;

  /// Sends the Cancel service for the request [requestHandle]; completes with
  /// the server's cancel count. (`UA_Client_cancelByRequestId` is a blocking
  /// call, which would starve the server pumped on this isolate.)
  Future<int> cancel(int requestHandle) {
    // UA_CancelRequest / UA_CancelResponse are not bound: a header struct
    // followed by one UInt32 (requestHandle / cancelCount).
    final requestType = getTypeByIndex(raw.UA_TYPES_CANCELREQUEST);
    final request = ua_calloc<ffi.Uint8>(requestType.ref.memSize);
    (request + ffi.sizeOf<raw.UA_RequestHeader>()).cast<ffi.Uint32>().value = requestHandle;
    final count = _service(
      request.cast(),
      requestType,
      getTypeByIndex(raw.UA_TYPES_CANCELRESPONSE),
      (ptr) => (ptr.cast<ffi.Uint8>() + ffi.sizeOf<raw.UA_ResponseHeader>()).cast<ffi.Uint32>().value,
    );
    ua_calloc.free(request);
    return count;
  }

  static RawHistoryResponse _decode(raw.UA_HistoryReadResponse response) {
    final results = <RawHistoryResult>[];
    for (var i = 0; i < response.resultsSize; i++) {
      final r = response.results[i];
      final cp = r.continuationPoint.length == 0
          ? null
          : Uint8List.fromList(r.continuationPoint.data.asTypedList(r.continuationPoint.length));
      final values = <RawHistoryValue>[];
      var dataValuesNull = true;
      if (r.historyData.encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED &&
          r.historyData.content.decoded.type == getType(UaTypes.historyData)) {
        final data = r.historyData.content.decoded.data.cast<raw.UA_HistoryData>().ref;
        dataValuesNull = data.dataValues == ffi.nullptr;
        for (var j = 0; j < data.dataValuesSize; j++) {
          final dv = data.dataValues[j];
          final flags = dv.substitute;
          values.add(
            RawHistoryValue(
              flags & 0x01 != 0 ? variantToValue(dv.value).value : null,
              dv.status,
              dv.sourceTimestamp,
              dv.serverTimestamp,
              flags,
            ),
          );
        }
      }
      results.add(RawHistoryResult(r.statusCode, cp, values, dataValuesNull: dataValuesNull));
    }
    return RawHistoryResponse(response.responseHeader.serviceResult, results);
  }

  var _deleted = false;

  void delete() {
    if (_deleted) return;
    _deleted = true;
    _pump.cancel();
    raw.UA_Client_delete(client);
    for (final callback in _callbacks) {
      callback.close();
    }
  }
}
