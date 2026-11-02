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
import 'history_raw_client.dart';

/// The native async HistoryRead patch (hook/async_history_read.patch), driven
/// through raw FFI: a raw `UA_HistoryDatabase.readRaw` that answers at once,
/// parks the response with `UA_STATUSCODE_GOODCOMPLETESASYNCHRONOUSLY` and
/// completes it with `UA_Server_setAsyncHistoryReadResult`, or never
/// completes (timeout, Cancel, shutdown).

/// One readRaw invocation, captured inside the callback.
class _ReadCall {
  _ReadCall(this.results, this.historyData, this.nodeIds, this.release);

  final ffi.Pointer<raw.UA_HistoryReadResult> results;
  final List<ffi.Pointer<raw.UA_HistoryData>> historyData;
  final List<int> nodeIds;
  final bool release;
}

/// A raw server whose history database is a Dart [onReadRaw]. [cancelled]
/// records every asyncOperationCancelCallback: the identity pointer and the
/// per-node statuses the server set before calling it.
class _HistoryServer {
  _HistoryServer({Duration asyncTimeout = const Duration(minutes: 2), int maxAsyncQueue = 0}) {
    _readRaw = ffi.NativeCallable<_ReadRawNative>.isolateLocal(_onReadRaw);
    _cancel = ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>)>.isolateLocal(
      _onCancel,
    );
    using((arena) {
      final config = arena<raw.UA_ServerConfig>();
      config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
      expect(raw.UA_ServerConfig_setMinimal(config, 0, ffi.nullptr), raw.UA_STATUSCODE_GOOD);
      // Never dereferenced: Service_HistoryRead only requires it non-NULL.
      config.ref.historyDatabase.context = ffi.Pointer.fromAddress(1);
      config.ref.historyDatabase.readRaw = _readRaw.nativeFunction;
      config.ref.asyncOperationCancelCallback = _cancel.nativeFunction;
      config.ref.asyncOperationTimeout = asyncTimeout.inMilliseconds.toDouble();
      config.ref.maxAsyncOperationQueueSize = maxAsyncQueue;
      server = raw.UA_Server_newWithConfig(config);
    }, ua_calloc);
    expect(raw.UA_Server_run_startup(server), raw.UA_STATUSCODE_GOOD);
    _pump = Timer.periodic(const Duration(milliseconds: 5), (_) => raw.UA_Server_run_iterate(server, false));
  }

  late final ffi.Pointer<raw.UA_Server> server;
  late final Timer _pump;
  late final ffi.NativeCallable<_ReadRawNative> _readRaw;
  late final ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>)> _cancel;
  var _deleted = false;

  /// Answers one readRaw. Returning normally leaves the response as filled
  /// (synchronous); setting the service result to GoodCompletesAsynchronously
  /// parks it.
  late void Function(_ReadCall call, ffi.Pointer<raw.UA_HistoryReadResponse> response) onReadRaw;

  final calls = <_ReadCall>[];
  final cancelled = <({int address, List<int> statuses})>[];

  int get port {
    final description = raw.UA_Server_getConfig(server).ref.applicationDescription;
    return int.parse(RegExp(r':(\d+)/?$').firstMatch(description.discoveryUrls[0].value)!.group(1)!);
  }

  void _onReadRaw(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<ffi.Void> hdbContext,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_RequestHeader> requestHeader,
    ffi.Pointer<raw.UA_ReadRawModifiedDetails> details,
    int timestampsToReturn,
    bool release,
    int nodesToReadSize,
    ffi.Pointer<raw.UA_HistoryReadValueId> nodesToRead,
    ffi.Pointer<raw.UA_HistoryReadResponse> response,
    ffi.Pointer<ffi.Pointer<raw.UA_HistoryData>> historyData,
  ) {
    final call = _ReadCall(
      response.ref.results,
      [for (var i = 0; i < nodesToReadSize; i++) historyData[i]],
      [for (var i = 0; i < nodesToReadSize; i++) nodesToRead[i].nodeId.identifier.numeric],
      release,
    );
    calls.add(call);
    onReadRaw(call, response);
  }

  void _onCancel(ffi.Pointer<raw.UA_Server> server, ffi.Pointer<ffi.Void> out) {
    final match = calls.where((c) => c.results.address == out.address);
    cancelled.add((
      address: out.address,
      statuses: match.isEmpty
          ? const []
          : [for (var i = 0; i < match.first.nodeIds.length; i++) match.first.results[i].statusCode],
    ));
  }

  void delete() {
    if (_deleted) return;
    _deleted = true;
    _pump.cancel();
    raw.UA_Server_run_shutdown(server);
    raw.UA_Server_delete(server);
    _readRaw.close();
    _cancel.close();
  }
}

typedef _ReadRawNative =
    ffi.Void Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_RequestHeader>,
      ffi.Pointer<raw.UA_ReadRawModifiedDetails>,
      ffi.UnsignedInt,
      ffi.Bool,
      ffi.Size,
      ffi.Pointer<raw.UA_HistoryReadValueId>,
      ffi.Pointer<raw.UA_HistoryReadResponse>,
      ffi.Pointer<ffi.Pointer<raw.UA_HistoryData>>,
    );

/// Fills node [i] of [call] with [count] Int32 values `base + j` (source
/// timestamps 1000 + j ticks) and an optional continuation point, the way a
/// backend must: heap memory the server frees with the response.
void _fill(_ReadCall call, int i, int count, {int base = 0, List<int>? continuationPoint}) {
  final data = call.historyData[i];
  final values = raw.UA_Array_new(count, getType(UaTypes.dataValue)).cast<raw.UA_DataValue>();
  for (var j = 0; j < count; j++) {
    final variant = valueToVariant(DynamicValue(value: base + j, typeId: NodeId.int32));
    expect(raw.UA_Variant_copy(variant, (values + j).cast()), raw.UA_STATUSCODE_GOOD);
    raw.UA_Variant_delete(variant);
    values[j].sourceTimestamp = 1000 + j;
    values[j].substitute = 0x01 | 0x04;
  }
  data.ref.dataValues = values;
  data.ref.dataValuesSize = count;
  if (continuationPoint != null) {
    final bytes = ua_calloc<ffi.Uint8>(continuationPoint.length);
    bytes.asTypedList(continuationPoint.length).setAll(0, continuationPoint);
    call.results[i].continuationPoint.data = bytes;
    call.results[i].continuationPoint.length = continuationPoint.length;
  }
}

void _parkAsync(ffi.Pointer<raw.UA_HistoryReadResponse> response) =>
    response.ref.responseHeader.serviceResult = raw.UA_STATUSCODE_GOODCOMPLETESASYNCHRONOUSLY;

List<RawHistoryNode> _nodes(List<int> ids) => [
  for (final id in ids) (nodeId: NodeId.fromNumeric(1, id), continuationPoint: null),
];

void main() {
  late _HistoryServer server;
  late RawHistoryClient client;

  Future<void> start({Duration? asyncTimeout, int maxAsyncQueue = 0}) async {
    server = _HistoryServer(asyncTimeout: asyncTimeout ?? const Duration(minutes: 2), maxAsyncQueue: maxAsyncQueue);
    client = await RawHistoryClient.connect(server.port);
  }

  // The server goes first: deleting a client disconnects it with a blocking
  // CloseSession, which a server pumped on this isolate cannot answer.
  tearDown(() {
    server.delete();
    client.delete();
  });

  test('a backend that answers synchronously still works', () async {
    await start();
    server.onReadRaw = (call, response) {
      _fill(call, 0, 3, base: 10);
      _fill(call, 1, 0);
      call.results[1].statusCode = raw.UA_STATUSCODE_BADNODEIDUNKNOWN;
    };
    final response = await client.read(_nodes([1, 2]));
    expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
    expect(response.results[0].statusCode, raw.UA_STATUSCODE_GOOD);
    expect(response.results[0].values.map((v) => v.value), [10, 11, 12]);
    expect(response.results[0].values.map((v) => v.sourceTimestamp), [1000, 1001, 1002]);
    expect(response.results[1].statusCode, raw.UA_STATUSCODE_BADNODEIDUNKNOWN);
    expect(server.cancelled, isEmpty);
  });

  test('a parked read is answered when the backend sets the result', () async {
    await start();
    server.onReadRaw = (call, response) => _parkAsync(response);
    var answered = false;
    final pending = client.read(_nodes([7, 8])).whenComplete(() => answered = true);

    await Future.delayed(const Duration(milliseconds: 500));
    expect(server.calls, hasLength(1));
    expect(server.calls.single.nodeIds, [7, 8]);
    expect(answered, isFalse, reason: 'answered before the backend completed');

    final call = server.calls.single;
    _fill(call, 0, 2, base: 70, continuationPoint: [1, 2, 3]);
    _fill(call, 1, 1, base: 80);
    call.results[1].statusCode = raw.UA_STATUSCODE_GOODNODATA;
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, call.results), raw.UA_STATUSCODE_GOOD);

    final response = await pending;
    expect(response.serviceResult, raw.UA_STATUSCODE_GOOD, reason: 'the parked serviceResult must not leak');
    expect(response.results, hasLength(2));
    expect(response.results[0].statusCode, raw.UA_STATUSCODE_GOOD);
    expect(response.results[0].values.map((v) => v.value), [70, 71]);
    expect(response.results[0].continuationPoint, Uint8List.fromList([1, 2, 3]));
    expect(response.results[1].statusCode, raw.UA_STATUSCODE_GOODNODATA);
    expect(response.results[1].values.map((v) => v.value), [80]);
    expect(response.results[1].continuationPoint, isNull);
    expect(server.cancelled, isEmpty);

    // Completed: the operation is gone.
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, call.results), raw.UA_STATUSCODE_BADNOTFOUND);
  });

  test('parked reads complete independently, in any order', () async {
    await start();
    server.onReadRaw = (call, response) => _parkAsync(response);
    final first = client.read(_nodes([1]));
    final second = client.read(_nodes([2]));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(server.calls, hasLength(2));

    _fill(server.calls[1], 0, 1, base: 200);
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, server.calls[1].results), raw.UA_STATUSCODE_GOOD);
    expect((await second).results.single.values.single.value, 200);

    _fill(server.calls[0], 0, 1, base: 100);
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, server.calls[0].results), raw.UA_STATUSCODE_GOOD);
    expect((await first).results.single.values.single.value, 100);
  });

  test('setAsyncHistoryReadResult with a pointer that is no operation is Bad_NotFound', () async {
    await start();
    final bogus = ua_calloc<raw.UA_HistoryReadResult>();
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, bogus), raw.UA_STATUSCODE_BADNOTFOUND);
    ua_calloc.free(bogus);
  });

  test('a read never completed times out with Bad_Timeout and the cancel callback gets the results pointer', () async {
    await start(asyncTimeout: const Duration(milliseconds: 300));
    server.onReadRaw = (call, response) => _parkAsync(response);
    final response = await client.read(_nodes([1, 2]));
    expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
    expect(response.results.map((r) => r.statusCode), [raw.UA_STATUSCODE_BADTIMEOUT, raw.UA_STATUSCODE_BADTIMEOUT]);
    expect(response.results.every((r) => r.values.isEmpty), isTrue);
    expect(server.cancelled, hasLength(1));
    expect(server.cancelled.single.address, server.calls.single.results.address);
    expect(server.cancelled.single.statuses, [raw.UA_STATUSCODE_BADTIMEOUT, raw.UA_STATUSCODE_BADTIMEOUT]);
  });

  test('the Cancel service cancels a parked read', () async {
    await start();
    server.onReadRaw = (call, response) => _parkAsync(response);
    final pending = client.send(_nodes([5]));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(server.calls, hasLength(1));

    expect(await client.cancel(pending.requestHandle), 1);
    final response = await pending.response;
    expect(response.serviceResult, raw.UA_STATUSCODE_BADREQUESTCANCELLEDBYCLIENT);
    expect(server.cancelled.single.address, server.calls.single.results.address);
    expect(server.cancelled.single.statuses, [raw.UA_STATUSCODE_BADOPERATIONABANDONED]);
  });

  test('a full async queue refuses to park: Bad_TooManyOperations at once', () async {
    await start(maxAsyncQueue: 1);
    server.onReadRaw = (call, response) => _parkAsync(response);
    final parked = client.read(_nodes([1]));
    await Future.delayed(const Duration(milliseconds: 300));
    final refused = await client.read(_nodes([2, 3]));
    expect(refused.serviceResult, raw.UA_STATUSCODE_GOOD);
    expect(refused.results.map((r) => r.statusCode), [
      raw.UA_STATUSCODE_BADTOOMANYOPERATIONS,
      raw.UA_STATUSCODE_BADTOOMANYOPERATIONS,
    ]);
    expect(server.cancelled.single.address, server.calls[1].results.address);

    _fill(server.calls[0], 0, 1, base: 1);
    expect(raw.UA_Server_setAsyncHistoryReadResult(server.server, server.calls[0].results), raw.UA_STATUSCODE_GOOD);
    expect((await parked).results.single.values.single.value, 1);
  });

  test('deleting the server with a read in flight cancels it with Bad_Shutdown', () async {
    await start();
    server.onReadRaw = (call, response) => _parkAsync(response);
    final pending = client.read(_nodes([1, 2]));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(server.calls, hasLength(1));
    final results = server.calls.single.results.address;

    server.delete();
    expect(server.cancelled, hasLength(1));
    expect(server.cancelled.single.address, results);
    expect(server.cancelled.single.statuses, [raw.UA_STATUSCODE_BADSHUTDOWN, raw.UA_STATUSCODE_BADSHUTDOWN]);

    // The session is gone before the AsyncManager is cleared, so no response
    // is sent: the client fails the request when it goes down.
    client.delete();
    final outcome = await pending;
    expect(outcome.serviceResult, isNot(raw.UA_STATUSCODE_GOOD));
    expect(outcome.results, isEmpty);
  });
}
