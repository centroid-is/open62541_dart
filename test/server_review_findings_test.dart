import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show getType, valueToVariant, variantToValue;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'common.dart';

/// Regression tests pinning the review findings on [Server] (PR #87).
///
/// Each group is annotated with the finding it pins:
///   * F1 - a failed duplicate [Server.addDataSourceVariableNode] must not
///     destroy the existing node's live read/write handlers.
///   * F2 - [Server.delete] must leave the server unusable-but-safe:
///     [Server.runIterate] returns false instead of touching freed memory.
///   * F3 - the binary encoding NodeId of a custom struct type must be unique
///     per type, so an ExtensionObject write is never decoded against another
///     type's schema.
///   * F4 - index-range reads/writes on data-source nodes are rejected with
///     BadIndexRangeInvalid instead of being silently ignored.
void main() {
  group('F1: failed duplicate addDataSourceVariableNode keeps original handlers', () {
    late int port;
    late Server server;
    late Client client;

    final nodeId = NodeId.fromString(1, 'review.f1.datasource');

    late int backing;
    final writesSeen = <int>[];

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);
      client = await setupClient(port);

      backing = 42;
      writesSeen.clear();
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'F1Tag',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(value: backing, typeId: NodeId.int32),
        onWrite: (value) {
          backing = value.value as int;
          writesSeen.add(backing);
        },
      );
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('original node still reads and writes after a failed duplicate add', () async {
      // Sanity: the node works before the duplicate registration attempt.
      expect((await client.read(nodeId).timeout(const Duration(seconds: 10))).value, 42);

      // A second registration with the SAME NodeId must fail (BadNodeIdExists).
      expect(
        () => server.addDataSourceVariableNode(
          nodeId,
          browseName: 'F1TagDuplicate',
          typeId: NodeId.int32,
          onRead: () => DynamicValue(value: -1, typeId: NodeId.int32),
        ),
        throwsA(predicate((e) => e.toString().contains('BadNodeIdExists'))),
      );

      // The ORIGINAL node's handlers must survive the failed duplicate:
      // reads keep serving the live value...
      expect((await client.read(nodeId).timeout(const Duration(seconds: 10))).value, 42);

      // ...and writes still reach the original onWrite.
      await client.write(nodeId, DynamicValue(value: 7, typeId: NodeId.int32)).timeout(const Duration(seconds: 10));
      expect(writesSeen, [7]);
      expect(backing, 7);
      expect((await client.read(nodeId).timeout(const Duration(seconds: 10))).value, 7);
    });
  });

  group('F2: delete() invalidates the server handle', () {
    test('runIterate returns false after delete()', () async {
      final port = Random().nextInt(10000) + 4840;
      final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
      server.start();
      expect(server.runIterate(), isTrue);

      server.shutdown();
      server.delete();

      // Contract: a deleted server must report "not running" instead of
      // dereferencing the freed native handle (use-after-free). Every test's
      // detached `while (server.runIterate())` pump relies on this to exit
      // safely when tearDown deletes the server between two loop turns.
      expect(server.runIterate(), isFalse);
      // And a second delete() must be a safe no-op rather than a double free.
      server.delete();
    });
  });

  group('F3: binary encoding ids of custom struct types must not collide', () {
    late int port;
    late Server server;
    late Client client;

    final typeA = NodeId.fromString(1, 'review.FT_A');
    final typeB = NodeId.fromString(1, 'review.FT_B');
    final nodeA = NodeId.fromString(1, 'review.f3.a');
    final nodeB = NodeId.fromString(1, 'review.f3.b');

    // Both schemas deliberately carry a null [DynamicValue.name]: nested
    // auto-registration commonly produces unnamed schemas, and the encoding id
    // used to be derived from the name ("BinaryEncoding_Default:null" for
    // BOTH types - one shared encoding id for two different layouts).
    DynamicValue makeSchemaA() {
      final s = DynamicValue(typeId: typeA);
      s['a'] = DynamicValue(value: 0, typeId: NodeId.int32);
      s['b'] = DynamicValue(value: 0, typeId: NodeId.int32);
      return s;
    }

    DynamicValue makeSchemaB() {
      final s = DynamicValue(typeId: typeB);
      s['x'] = DynamicValue(value: 0.0, typeId: NodeId.double);
      return s;
    }

    DynamicValue? capturedA;
    DynamicValue? capturedB;

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);
      client = await setupClient(port);

      // Registration order matters: open62541 scans the (prepended) custom
      // type list head-first, so with a shared encoding id the later
      // registration (typeB) shadows the earlier one (typeA).
      server.addCustomType(typeA, makeSchemaA());
      server.addDataTypeNode(typeA, 'FT_A');
      server.addCustomType(typeB, makeSchemaB());
      server.addDataTypeNode(typeB, 'FT_B');

      capturedA = null;
      capturedB = null;
      server.addDataSourceVariableNode(
        nodeA,
        browseName: 'F3TagA',
        typeId: typeA,
        onRead: makeSchemaA,
        onWrite: (value) => capturedA = value,
      );
      server.addDataSourceVariableNode(
        nodeB,
        browseName: 'F3TagB',
        typeId: typeB,
        onRead: makeSchemaB,
        onWrite: (value) => capturedB = value,
      );
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('write with a name-derived encoding id decodes against the target node\'s schema', () async {
      // A spec-conformant OPC UA client addresses a struct write by the type's
      // advertised DefaultBinary DataTypeEncoding NodeId, not by the DataType
      // NodeId itself. Simulate that by stamping the id the (pre-fix) server
      // derived for BOTH unnamed types onto the outgoing ExtensionObject.
      // With colliding ids open62541 decoded this against whichever type
      // happened to sit first in its list (typeB), corrupting writes to nodeA;
      // with unique ids the write must land in onWrite with the fields intact.
      final collidingEncodingId = NodeId.fromString(1, 'BinaryEncoding_Default:null');

      final wA = makeSchemaA();
      wA['a'] = DynamicValue(value: 1, typeId: NodeId.int32);
      wA['b'] = DynamicValue(value: 2, typeId: NodeId.int32);
      wA.extObjEncodingId = collidingEncodingId;
      await client.write(nodeA, wA).timeout(const Duration(seconds: 10));

      expect(capturedA, isNotNull);
      expect(capturedA!.isObject, isTrue);
      expect(capturedA!.asObject.keys, containsAll(<String>['a', 'b']));
      expect(capturedA!['a'].value, 1);
      expect(capturedA!['b'].value, 2);

      final wB = makeSchemaB();
      wB['x'] = DynamicValue(value: 3.5, typeId: NodeId.double);
      wB.extObjEncodingId = collidingEncodingId;
      await client.write(nodeB, wB).timeout(const Duration(seconds: 10));

      expect(capturedB, isNotNull);
      expect(capturedB!.isObject, isTrue);
      expect((capturedB!['x'].value as num).toDouble(), closeTo(3.5, 1e-9));
    });
  });

  group('F4: index-range reads/writes on data-source nodes are rejected', () {
    late int port;
    late Server server;
    late ffi.Pointer<raw.UA_Client> rawClient;

    final nodeId = NodeId.fromString(1, 'review.f4.array');
    late List<int> backing;
    final writesSeen = <List<int>>[];

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);

      backing = [10, 20, 30, 40];
      writesSeen.clear();
      // No typeId: an array node must keep open62541's permissive defaults
      // (typeId would mark the node scalar).
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'F4Array',
        onRead: () => DynamicValue.fromList([
          for (final v in backing) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32),
        onWrite: (value) {
          backing = [for (final v in value.asArray) v.value as int];
          writesSeen.add(backing);
        },
      );

      rawClient = await _connectRawClient(port);
    });

    tearDown(() async {
      raw.UA_Client_disconnect(rawClient);
      raw.UA_Client_delete(rawClient);
      server.shutdown();
      server.delete();
    });

    test('read with an index range returns BadIndexRangeInvalid, not the full array', () async {
      // Sanity: a rangeless read serves the full array.
      final (fullStatus, fullValue) = await _rawReadValue(rawClient, nodeId, null);
      expect(fullStatus, raw.UA_STATUSCODE_GOOD);
      expect(fullValue!.asArray.map((v) => v.value), [10, 20, 30, 40]);

      // The read dispatcher cannot apply a range (and open62541 does not apply
      // it afterwards for callback value sources), so a ranged read MUST be
      // rejected - silently returning the full array with status Good would
      // hand the client wrong data for arr[1:2].
      final (rangedStatus, rangedValue) = await _rawReadValue(rawClient, nodeId, '1:2');
      expect(
        rangedStatus,
        raw.UA_STATUSCODE_BADINDEXRANGEINVALID,
        reason: 'a ranged read must be rejected, not silently serve the full array',
      );
      expect(rangedValue, isNull);
    });

    test('write with an index range returns BadIndexRangeInvalid and leaves the value untouched', () async {
      // Sanity: a rangeless write reaches onWrite.
      final fullStatus = await _rawWriteValue(
        rawClient,
        nodeId,
        DynamicValue.fromList([
          for (final v in [1, 2, 3, 4]) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32),
        null,
      );
      expect(fullStatus, raw.UA_STATUSCODE_GOOD);
      expect(backing, [1, 2, 3, 4]);

      // A ranged write (arr[1:2] = [9, 9]) MUST be rejected: the dispatcher
      // cannot apply the range, so accepting it would replace the ENTIRE value
      // with the two-element sub-array.
      writesSeen.clear();
      final rangedStatus = await _rawWriteValue(
        rawClient,
        nodeId,
        DynamicValue.fromList([
          for (final v in [9, 9]) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32),
        '1:2',
      );
      expect(
        rangedStatus,
        raw.UA_STATUSCODE_BADINDEXRANGEINVALID,
        reason: 'a ranged write must be rejected, not silently replace the whole value',
      );
      expect(writesSeen, isEmpty, reason: 'onWrite must not observe a rejected ranged write');
      expect(backing, [1, 2, 3, 4]);
    });
  });
}

// ---- F4 raw-client plumbing -------------------------------------------------
//
// The binding's [Client] cannot express an OPC UA index range, so the F4 tests
// drive a bare `UA_Client` through the generated bindings and issue Read/Write
// service requests with `indexRange` set on the ReadValueId/WriteValue.

/// `UA_WriteValue` / `UA_WriteRequest` are not part of the generated bindings
/// (only the response side is), so mirror their layout here.
final class _RawWriteValue extends ffi.Struct {
  external raw.UA_NodeId nodeId;

  @ffi.Uint32()
  external int attributeId;

  external raw.UA_String indexRange;

  external raw.UA_DataValue value;
}

final class _RawWriteRequest extends ffi.Struct {
  external raw.UA_RequestHeader requestHeader;

  @ffi.Size()
  external int nodesToWriteSize;

  external ffi.Pointer<_RawWriteValue> nodesToWrite;
}

/// Resolves `&UA_TYPES[index]` for type indices missing from [UaTypes]
/// (WriteRequest/WriteResponse). Mirrors `getType` in `src/common.dart`.
ffi.Pointer<raw.UA_DataType> _uaTypeByIndex(int index) {
  final baseAddress = ffi.Native.addressOf<raw.UA_DataType>(raw.UA_TYPES);
  return ffi.Pointer.fromAddress(baseAddress.address + (index * ffi.sizeOf<raw.UA_DataType>()));
}

/// Frees the string identifier buffer a `NodeId.toRaw()` allocated, if any.
void _freeRawNodeId(raw.UA_NodeId rawNodeId) {
  if (rawNodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
    final data = rawNodeId.identifier.string.data;
    if (data != ffi.nullptr) {
      ua_malloc.free(data);
    }
  }
}

Future<ffi.Pointer<raw.UA_Client>> _connectRawClient(int port) async {
  final config = ua_calloc<raw.UA_ClientConfig>();
  config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
  raw.UA_ClientConfig_setDefault(config);
  final client = raw.UA_Client_newWithConfig(config);
  final url = 'opc.tcp://localhost:$port'.toNativeUtf8(allocator: ua_malloc);
  final rc = raw.UA_Client_connectAsync(client, url.cast());
  expect(rc, raw.UA_STATUSCODE_GOOD);

  final channelState = ua_calloc<ffi.UnsignedInt>();
  final sessionState = ua_calloc<ffi.UnsignedInt>();
  final connectStatus = ua_calloc<ffi.Uint32>();
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      raw.UA_Client_run_iterate(client, 5);
      raw.UA_Client_getState(client, channelState, sessionState, connectStatus);
      if (sessionState.value == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED.value) {
        return client;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('raw client failed to connect to port $port');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  } finally {
    ua_calloc.free(channelState);
    ua_calloc.free(sessionState);
    ua_calloc.free(connectStatus);
    ua_malloc.free(url);
  }
}

/// Pumps [client] until [completer] completes (responses are delivered from
/// within `UA_Client_run_iterate`).
Future<T> _pumpUntilComplete<T>(ffi.Pointer<raw.UA_Client> client, Completer<T> completer) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!completer.isCompleted) {
    raw.UA_Client_run_iterate(client, 5);
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for a service response');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
  return completer.future;
}

/// Reads the Value attribute of [nodeId], optionally with an [indexRange]
/// (e.g. `'1:2'`). Returns the operation status code and the decoded value
/// (null when the result carries no value).
Future<(int, DynamicValue?)> _rawReadValue(ffi.Pointer<raw.UA_Client> client, NodeId nodeId, String? indexRange) async {
  final completer = Completer<(int, DynamicValue?)>();

  final readValueId = ua_calloc<raw.UA_ReadValueId>();
  readValueId.ref.nodeId = nodeId.toRaw();
  readValueId.ref.attributeId = AttributeId.UA_ATTRIBUTEID_VALUE.value;
  if (indexRange != null) {
    readValueId.ref.indexRange.set(indexRange);
  }
  final request = raw.UA_ReadRequest_new();
  raw.UA_ReadRequest_init(request);
  request.ref.nodesToRead = readValueId;
  request.ref.nodesToReadSize = 1;

  late ffi.NativeCallable<
    ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
  >
  callback;
  callback =
      ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
      >.isolateLocal((
        ffi.Pointer<raw.UA_Client> client,
        ffi.Pointer<ffi.Void> userdata,
        int requestId,
        ffi.Pointer<ffi.Void> responsePtr,
      ) {
        callback.close();
        final response = responsePtr.cast<raw.UA_ReadResponse>();
        if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
          completer.complete((response.ref.responseHeader.serviceResult, null));
          return;
        }
        expect(response.ref.resultsSize, 1);
        final result = response.ref.results[0];
        // Bit 0 of the UA_DataValue bitfield byte flags hasValue.
        final hasValue = (result.substitute & 0x01) != 0;
        completer.complete((result.status, hasValue ? variantToValue(result.value) : null));
      });

  final requestId = ua_calloc<ffi.Uint32>();
  final res = raw.UA_Client_AsyncService(
    client,
    request.cast(),
    getType(UaTypes.readRequest),
    callback.nativeFunction,
    getType(UaTypes.readResponse),
    ffi.nullptr,
    requestId,
  );
  expect(res, raw.UA_STATUSCODE_GOOD);

  final result = await _pumpUntilComplete(client, completer);
  // Deep-frees nodesToRead (incl. the NodeId identifier and indexRange buffers,
  // which were allocated with the same system allocator open62541 uses).
  raw.UA_ReadRequest_delete(request);
  ua_calloc.free(requestId);
  return result;
}

/// Writes [value] to the Value attribute of [nodeId], optionally with an
/// [indexRange]. Returns the per-node operation status code.
Future<int> _rawWriteValue(
  ffi.Pointer<raw.UA_Client> client,
  NodeId nodeId,
  DynamicValue value,
  String? indexRange,
) async {
  final completer = Completer<int>();

  final writeValue = ua_calloc<_RawWriteValue>();
  writeValue.ref.nodeId = nodeId.toRaw();
  writeValue.ref.attributeId = AttributeId.UA_ATTRIBUTEID_VALUE.value;
  if (indexRange != null) {
    writeValue.ref.indexRange.set(indexRange);
  }
  final variant = valueToVariant(value);
  writeValue.ref.value.value = variant.ref;
  writeValue.ref.value.substitute = 0x01; // hasValue
  final request = ua_calloc<_RawWriteRequest>();
  request.ref.nodesToWrite = writeValue;
  request.ref.nodesToWriteSize = 1;

  late ffi.NativeCallable<
    ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
  >
  callback;
  callback =
      ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
      >.isolateLocal((
        ffi.Pointer<raw.UA_Client> client,
        ffi.Pointer<ffi.Void> userdata,
        int requestId,
        ffi.Pointer<ffi.Void> responsePtr,
      ) {
        callback.close();
        final response = responsePtr.cast<raw.UA_WriteResponse>();
        if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
          completer.complete(response.ref.responseHeader.serviceResult);
          return;
        }
        expect(response.ref.resultsSize, 1);
        completer.complete(response.ref.results[0]);
      });

  final requestId = ua_calloc<ffi.Uint32>();
  final res = raw.UA_Client_AsyncService(
    client,
    request.cast(),
    _uaTypeByIndex(raw.UA_TYPES_WRITEREQUEST),
    callback.nativeFunction,
    _uaTypeByIndex(raw.UA_TYPES_WRITERESPONSE),
    ffi.nullptr,
    requestId,
  );
  expect(res, raw.UA_STATUSCODE_GOOD);

  final result = await _pumpUntilComplete(client, completer);
  // No generated UA_WriteRequest_delete: free the pieces manually. The variant
  // owns the encoded payload; `writeValue.ref.value.value` was only a shallow
  // alias of it for the (synchronous) request serialization.
  _freeRawNodeId(writeValue.ref.nodeId);
  writeValue.ref.indexRange.free();
  raw.UA_Variant_delete(variant);
  ua_calloc.free(writeValue);
  ua_calloc.free(request);
  ua_calloc.free(requestId);
  return result;
}
