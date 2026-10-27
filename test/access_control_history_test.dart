import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/access_control.dart' show AccessControlHooks;
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'raw_session.dart';

// open62541's default history database is compiled into the library but not
// bound; it is the plugin that asks the access control about HistoryUpdate.
const _asset = 'package:open62541/src/third_party/open62541.g.dart';

/// `UA_HistoryDataGathering`: a context and seven function pointers.
final class _Gathering extends ffi.Struct {
  @ffi.Array(8)
  external ffi.Array<ffi.Pointer<ffi.Void>> slots;
}

/// `UA_HistoryDataBackend`: a context and sixteen function pointers.
final class _Backend extends ffi.Struct {
  @ffi.Array(17)
  external ffi.Array<ffi.Pointer<ffi.Void>> slots;
}

/// `UA_HistorizingNodeIdSettings`.
final class _Settings extends ffi.Struct {
  external _Backend historizingBackend;
  @ffi.Size()
  external int maxHistoryDataResponseSize;
  @ffi.Int32()
  external int historizingUpdateStrategy;
  @ffi.Size()
  external int pollingInterval;
  external ffi.Pointer<ffi.Void> userContext;
}

@ffi.Native<_Gathering Function(ffi.Size)>(symbol: 'UA_HistoryDataGathering_Default', assetId: _asset)
external _Gathering _gatheringDefault(int initialNodeIdStoreSize);

@ffi.Native<raw.UA_HistoryDatabase Function(_Gathering)>(symbol: 'UA_HistoryDatabase_default', assetId: _asset)
external raw.UA_HistoryDatabase _databaseDefault(_Gathering gathering);

@ffi.Native<_Backend Function(ffi.Size, ffi.Size)>(symbol: 'UA_HistoryDataBackend_Memory', assetId: _asset)
external _Backend _memoryBackend(int initialNodeIdStoreSize, int initialDataStoreSize);

typedef _Register =
    ffi.Uint32 Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_NodeId>, _Settings);

class _HistoryGate extends AccessControl {
  var allow = false;
  final asked = <NodeId>[];

  @override
  Set<UserTokenType> get userTokenTypes => {UserTokenType.anonymous};

  @override
  Object? activateSession(SessionActivation activation) => null;

  @override
  bool allowHistoryUpdate(Object? context, NodeRef node) {
    asked.add(node.nodeId);
    return allow;
  }
}

void main() {
  final historized = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME);
  late _HistoryGate gate;
  late AccessControlHooks hooks;
  late ffi.Pointer<raw.UA_Server> server;
  late Timer pump;
  late RawSession session;

  setUp(() async {
    gate = _HistoryGate();
    hooks = AccessControlHooks(gate);
    final gathering = _gatheringDefault(1);
    final config = ua_calloc<raw.UA_ServerConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    expect(raw.UA_ServerConfig_setMinimal(config, 0, ffi.nullptr), raw.UA_STATUSCODE_GOOD);
    hooks.install(config, [UserTokenType.anonymous]);
    config.ref.historyDatabase = _databaseDefault(gathering);
    server = raw.UA_Server_newWithConfig(config);
    ua_calloc.free(config);
    expect(raw.UA_Server_run_startup(server), raw.UA_STATUSCODE_GOOD);
    // The database asks for HistoryWrite access and a historizing node first.
    final rawId = raw.UA_NODEID_NUMERIC(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME);
    expect(
      raw.UA_Server_writeAccessLevel(
        server,
        rawId,
        raw.UA_ACCESSLEVELMASK_READ | raw.UA_ACCESSLEVELMASK_HISTORYREAD | raw.UA_ACCESSLEVELMASK_HISTORYWRITE,
      ),
      raw.UA_STATUSCODE_GOOD,
    );
    expect(raw.UA_Server_writeHistorizing(server, rawId, true), raw.UA_STATUSCODE_GOOD);

    final settings = ffi.Struct.create<_Settings>()
      ..historizingBackend = _memoryBackend(1, 10)
      ..maxHistoryDataResponseSize = 10;
    final register = gathering.slots[2]
        .cast<ffi.NativeFunction<_Register>>()
        .asFunction<
          int Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_NodeId>, _Settings)
        >();
    final status = using((arena) {
      final id = arena<raw.UA_NodeId>()..ref = historized.toRaw(allocator: arena);
      return register(server, gathering.slots[0], id, settings);
    }, ua_calloc);
    expect(status, raw.UA_STATUSCODE_GOOD);

    pump = Timer.periodic(const Duration(milliseconds: 2), (_) => raw.UA_Server_run_iterate(server, false));
    final description = raw.UA_Server_getConfig(server).ref.applicationDescription;
    final port = RegExp(r':(\d+)/?$').firstMatch(description.discoveryUrls[0].value)!.group(1);
    session = await RawSession.open('opc.tcp://127.0.0.1:$port');
  });

  tearDown(() {
    // The server goes first: a disconnect waits for a CloseSession answer that
    // a server pumped by this isolate cannot give meanwhile.
    pump.cancel();
    raw.UA_Server_run_shutdown(server);
    session.close();
    raw.UA_Server_delete(server);
    hooks.close();
  });

  /// Sends one HistoryUpdate with [details] of type [detailsType] and answers
  /// (result status, operation results).
  Future<(int, List<int>)> historyUpdate(int detailsType, void Function(ffi.Pointer<ffi.Uint8> details) fill) {
    final request = memberOffsets(raw.UA_TYPES_HISTORYUPDATEREQUEST)['HistoryUpdateDetails']!;
    final response = memberOffsets(raw.UA_TYPES_HISTORYUPDATERESPONSE)['Results']!;
    final result = memberOffsets(raw.UA_TYPES_HISTORYUPDATERESULT);
    return session.service(
      raw.UA_TYPES_HISTORYUPDATEREQUEST,
      raw.UA_TYPES_HISTORYUPDATERESPONSE,
      (r) {
        final type = getTypeByIndex(detailsType);
        final details = ua_calloc<ffi.Uint8>(type.ref.memSize);
        fill(details);
        final object = ua_calloc<raw.UA_ExtensionObject>();
        object.ref.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED.value;
        object.ref.content.decoded.type = type;
        object.ref.content.decoded.data = details.cast();
        (r + request).cast<ffi.Size>().value = 1;
        (r + request + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<raw.UA_ExtensionObject>>().value = object;
      },
      (r) {
        expect((r + response).cast<ffi.Size>().value, 1);
        final first = (r + response + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<ffi.Uint8>>().value;
        final status = (first + result['StatusCode']!).cast<ffi.Uint32>().value;
        final count = (first + result['OperationResults']!).cast<ffi.Size>().value;
        final operations = (first + result['OperationResults']! + ffi.sizeOf<ffi.Size>())
            .cast<ffi.Pointer<ffi.Uint32>>()
            .value;
        return (status, [for (var i = 0; i < count; i++) operations[i]]);
      },
    );
  }

  Future<(int, List<int>)> updateData() {
    final offsets = memberOffsets(raw.UA_TYPES_UPDATEDATADETAILS);
    return historyUpdate(raw.UA_TYPES_UPDATEDATADETAILS, (d) {
      (d + offsets['NodeId']!).cast<raw.UA_NodeId>().ref = historized.toRaw();
      (d + offsets['PerformInsertReplace']!).cast<ffi.Int32>().value =
          raw.UA_PerformUpdateType.UA_PERFORMUPDATETYPE_INSERT.value;
      (d + offsets['UpdateValues']!).cast<ffi.Size>().value = 2;
      (d + offsets['UpdateValues']! + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<raw.UA_DataValue>>().value =
          ua_calloc<raw.UA_DataValue>(2);
    });
  }

  Future<(int, List<int>)> deleteRawModified() {
    final offsets = memberOffsets(raw.UA_TYPES_DELETERAWMODIFIEDDETAILS);
    return historyUpdate(raw.UA_TYPES_DELETERAWMODIFIEDDETAILS, (d) {
      (d + offsets['NodeId']!).cast<raw.UA_NodeId>().ref = historized.toRaw();
      (d + offsets['EndTime']!).cast<ffi.Int64>().value = dateTimeToUaDateTime(DateTime.now());
    });
  }

  test('allowHistoryUpdate refuses every value of an UpdateData', () async {
    final (status, operations) = await updateData();
    expect(status, raw.UA_STATUSCODE_GOOD);
    expect(operations.map(statusCodeToString), ['BadUserAccessDenied', 'BadUserAccessDenied']);
    expect(gate.asked, [historized, historized]);

    gate.allow = true;
    final (_, allowed) = await updateData();
    expect(allowed.map(statusCodeToString), isNot(contains('BadUserAccessDenied')));
  });

  test('allowHistoryUpdate refuses a DeleteRawModified', () async {
    final (status, _) = await deleteRawModified();
    expect(statusCodeToString(status), 'BadUserAccessDenied');
    expect(gate.asked, [historized]);

    gate.allow = true;
    final (allowed, _) = await deleteRawModified();
    expect(statusCodeToString(allowed), isNot('BadUserAccessDenied'));
  });
}
