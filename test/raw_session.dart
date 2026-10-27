import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

Future<void> waitFor(bool Function() condition, {String reason = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The node management services, sent with one item whose first NodeId
/// (parent, node or source) is the node under test.
enum NodeManagement {
  addNodes(raw.UA_TYPES_ADDNODESREQUEST, raw.UA_TYPES_ADDNODESRESPONSE, raw.UA_TYPES_ADDNODESITEM, 'NodesToAdd'),
  addReferences(
    raw.UA_TYPES_ADDREFERENCESREQUEST,
    raw.UA_TYPES_ADDREFERENCESRESPONSE,
    raw.UA_TYPES_ADDREFERENCESITEM,
    'ReferencesToAdd',
  ),
  deleteNodes(
    raw.UA_TYPES_DELETENODESREQUEST,
    raw.UA_TYPES_DELETENODESRESPONSE,
    raw.UA_TYPES_DELETENODESITEM,
    'NodesToDelete',
  ),
  deleteReferences(
    raw.UA_TYPES_DELETEREFERENCESREQUEST,
    raw.UA_TYPES_DELETEREFERENCESRESPONSE,
    raw.UA_TYPES_DELETEREFERENCESITEM,
    'ReferencesToDelete',
  );

  const NodeManagement(this.request, this.response, this.item, this.itemsMember);
  final int request;
  final int response;
  final int item;
  final String itemsMember;
}

/// Offset of each member of a native type, by `UA_DataTypeMember` padding.
Map<String, int> memberOffsets(int typeIndex) {
  final type = getTypeByIndex(typeIndex).ref;
  final offsets = <String, int>{};
  var offset = 0;
  for (var i = 0; i < type.membersSize; i++) {
    final member = type.members[i];
    offset += member.padding;
    offsets[member.memberName.cast<Utf8>().toDartString()] = offset;
    offset += member.isArray
        ? ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer>()
        : member.isOptional
        ? ffi.sizeOf<ffi.Pointer>()
        : member.memberType.ref.memSize;
  }
  return offsets;
}

/// An anonymous session of a raw open62541 client, for the services the
/// `Client` class does not offer.
class RawSession {
  RawSession._(this._client);

  final ffi.Pointer<raw.UA_Client> _client;

  static Future<RawSession> open(String url) async {
    final config = ua_calloc<raw.UA_ClientConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    raw.UA_ClientConfig_setDefault(config);
    final client = raw.UA_Client_newWithConfig(config);
    ua_calloc.free(config);
    final session = RawSession._(client);
    using((arena) => raw.UA_Client_connectAsync(client, url.toNativeUtf8(allocator: arena).cast()), ua_calloc);
    await waitFor(() {
      raw.UA_Client_run_iterate(client, 0);
      return using((arena) {
        final channel = arena<ffi.UnsignedInt>();
        final state = arena<ffi.UnsignedInt>();
        final status = arena<ffi.Uint32>();
        raw.UA_Client_getState(client, channel, state, status);
        return state.value == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED.value;
      }, ua_calloc);
    }, reason: 'raw session');
    return session;
  }

  /// Sends [service] for [node] and answers the operation's status.
  Future<int> manage(NodeManagement service, NodeId node) async {
    final requestType = getTypeByIndex(service.request);
    final itemType = getTypeByIndex(service.item);
    final request = ua_calloc<ffi.Uint8>(requestType.ref.memSize);
    final item = ua_calloc<ffi.Uint8>(itemType.ref.memSize);
    item.cast<raw.UA_NodeId>().ref = node.toRaw();
    if (service == NodeManagement.addNodes) {
      final browseName = (item + memberOffsets(service.item)['BrowseName']!).cast<raw.UA_QualifiedName>();
      browseName.ref.namespaceIndex = 1;
      browseName.ref.name.set('added');
    }
    final itemsOffset = memberOffsets(service.request)[service.itemsMember]!;
    (request + itemsOffset).cast<ffi.Size>().value = 1;
    (request + itemsOffset + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<ffi.Uint8>>().value = item;

    final result = Completer<int>();
    final responseResults = memberOffsets(service.response)['Results']!;
    final serviceResult = memberOffsets(raw.UA_TYPES_RESPONSEHEADER)['ServiceResult']!;
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> c, ffi.Pointer<ffi.Void> userdata, int id, ffi.Pointer<ffi.Void> r) {
          final response = r.cast<ffi.Uint8>();
          final status = (response + serviceResult).cast<ffi.Uint32>().value;
          if (status != raw.UA_STATUSCODE_GOOD) {
            result.complete(status);
            return;
          }
          // Every result type starts with its StatusCode.
          final results = (response + responseResults + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<ffi.Uint32>>().value;
          result.complete(results.value);
        });
    final sent = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      requestType,
      callback.nativeFunction,
      getTypeByIndex(service.response),
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_clear(request.cast(), requestType);
    ua_calloc.free(request);
    try {
      if (sent != raw.UA_STATUSCODE_GOOD) return sent;
      while (!result.isCompleted) {
        raw.UA_Client_run_iterate(_client, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await result.future;
    } finally {
      callback.close();
    }
  }

  /// Reads attribute [attributeId] of [node]; a Boolean comes back as is,
  /// anything else as `null`.
  Future<bool?> readBoolean(NodeId node, int attributeId) async {
    final request = raw.UA_ReadRequest_new();
    request.ref.nodesToRead = ua_calloc<raw.UA_ReadValueId>();
    request.ref.nodesToReadSize = 1;
    request.ref.nodesToRead.ref.nodeId = node.toRaw();
    request.ref.nodesToRead.ref.attributeId = attributeId;
    final result = Completer<bool?>();
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> c, ffi.Pointer<ffi.Void> userdata, int id, ffi.Pointer<ffi.Void> r) {
          final response = r.cast<raw.UA_ReadResponse>().ref;
          final value = response.resultsSize == 1 ? response.results.ref.value : null;
          result.complete(
            value != null && value.type == getTypeByIndex(raw.UA_TYPES_BOOLEAN)
                ? value.data.cast<ffi.Bool>().value
                : null,
          );
        });
    final readType = getTypeByIndex(raw.UA_TYPES_READREQUEST);
    final sent = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      readType,
      callback.nativeFunction,
      getTypeByIndex(raw.UA_TYPES_READRESPONSE),
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_ReadRequest_delete(request);
    try {
      expect(sent, raw.UA_STATUSCODE_GOOD);
      while (!result.isCompleted) {
        raw.UA_Client_run_iterate(_client, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await result.future;
    } finally {
      callback.close();
    }
  }

  /// Sends a request of type [requestType], filled in by [fill] into zeroed
  /// memory (allocations from `ua_calloc`, freed with the request), and
  /// answers what [read] takes from the response of type [responseType].
  Future<T> service<T>(
    int requestType,
    int responseType,
    void Function(ffi.Pointer<ffi.Uint8> request) fill,
    T Function(ffi.Pointer<ffi.Uint8> response) read,
  ) async {
    final type = getTypeByIndex(requestType);
    final request = ua_calloc<ffi.Uint8>(type.ref.memSize);
    fill(request);
    final result = Completer<T>();
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> c, ffi.Pointer<ffi.Void> userdata, int id, ffi.Pointer<ffi.Void> r) {
          try {
            result.complete(read(r.cast()));
          } catch (e, s) {
            result.completeError(e, s);
          }
        });
    final sent = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      type,
      callback.nativeFunction,
      getTypeByIndex(responseType),
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_clear(request.cast(), type);
    ua_calloc.free(request);
    try {
      expect(sent, raw.UA_STATUSCODE_GOOD);
      while (!result.isCompleted) {
        raw.UA_Client_run_iterate(_client, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await result.future;
    } finally {
      callback.close();
    }
  }

  void close() {
    raw.UA_Client_disconnect(_client);
    raw.UA_Client_delete(_client);
  }
}
