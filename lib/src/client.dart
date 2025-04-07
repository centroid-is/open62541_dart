import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';

import 'generated/open62541_bindings.dart' as raw;
import 'nodeId.dart';
import 'extensions.dart';

class Result<T, E> {
  final T? _ok;
  final E? _err;
  final bool isOk;

  Result.ok(this._ok)
      : isOk = true,
        _err = null;
  Result.error(this._err)
      : isOk = false,
        _ok = null;
  T unwrap() {
    return _ok!;
  }

  E error() {
    return _err!;
  }

  R match<R>({required R Function(T) ok, required R Function(E) err}) {
    return isOk ? ok(_ok!) : err(_err!);
  }
}

class ClientState {
  int channelState;
  int sessionState;
  int connectStatus;
  ClientState(
      {required this.channelState,
      required this.sessionState,
      required this.connectStatus});
}

class ClientConfig {
  ClientConfig(this._clientConfig) {
    // Intercept callbacks
    final state = ffi.NativeCallable<
            ffi.Void Function(
                ffi.Pointer<raw.UA_Client> client,
                ffi.Int32 channelState,
                ffi.Int32 sessionState,
                raw.UA_StatusCode connectStatus)>.isolateLocal(
        (ffi.Pointer<raw.UA_Client> client, int channelState, int sessionState,
                int connectStatus) =>
            _stateStream.add(ClientState(
                channelState: channelState,
                sessionState: sessionState,
                connectStatus: connectStatus)));
    _clientConfig.ref.stateCallback = state.nativeFunction;
    final inactivity = ffi.NativeCallable<
            ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32,
                ffi.Pointer<ffi.Void>)>.isolateLocal(
        (ffi.Pointer<raw.UA_Client> client, int subId,
                ffi.Pointer<ffi.Void> subContext) =>
            _subscriptionInactivity.add(subId));
    _clientConfig.ref.subscriptionInactivityCallback =
        inactivity.nativeFunction;
  }
  Stream<ClientState> get stateStream => _stateStream.stream;
  Stream<int> get subscriptionInactivityStream =>
      _subscriptionInactivity.stream;
  // Private interface
  final ffi.Pointer<raw.UA_ClientConfig> _clientConfig;
  final StreamController<ClientState> _stateStream =
      StreamController<ClientState>.broadcast();
  final StreamController<int> _subscriptionInactivity =
      StreamController<int>.broadcast();
}

class Client {
  Client(raw.open62541 lib)
      : _lib = lib,
        _client = lib.UA_Client_new() {
    _clientConfig = ClientConfig(lib.UA_Client_getConfig(_client));
  }

  ClientConfig get config => _clientConfig;

  int connect(String url) {
    ffi.Pointer<ffi.Char> urlPointer = url.toNativeUtf8().cast();
    return _lib.UA_Client_connect(_client, urlPointer);
  }

  void runIterate(Duration iterate) {
    int ms = iterate.inMilliseconds;
    _lib.UA_Client_run_iterate(_client, ms);
  }

  dynamic readValueAttribute(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode =
        _lib.UA_Client_readValueAttribute(_client, nodeId.rawNodeId, data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Bad status code $statusCode';
    }

    final retVal = _uaVariantToDart(data);
    calloc.free(data);
    return retVal;
  }

  int subscriptionCreate(
      {Duration requestedPublishingInterval = const Duration(milliseconds: 500),
      int requestedLifetimeCount = 10000,
      int requestedMaxKeepAliveCount = 10,
      int maxNotificationsPerPublish = 0,
      bool publishingEnabled = true,
      int priority = 0}) {
    ffi.Pointer<raw.UA_CreateSubscriptionRequest> request =
        calloc<raw.UA_CreateSubscriptionRequest>();
    _lib.UA_CreateSubscriptionRequest_init(request);
    request.ref.requestedPublishingInterval =
        requestedPublishingInterval.inMicroseconds / 1000.0;
    request.ref.requestedLifetimeCount = requestedLifetimeCount;
    request.ref.requestedMaxKeepAliveCount = requestedMaxKeepAliveCount;
    request.ref.maxNotificationsPerPublish = maxNotificationsPerPublish;
    request.ref.publishingEnabled = publishingEnabled;
    request.ref.priority = priority;

    final deleteCallback = ffi.NativeCallable<
            ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32,
                ffi.Pointer<ffi.Void>)>.isolateLocal(
        (ffi.Pointer<raw.UA_Client> client, int subid,
                ffi.Pointer<ffi.Void> somedata) =>
            print("Subscription deleted $subid"));
    raw.UA_CreateSubscriptionResponse response =
        _lib.UA_Client_Subscriptions_create(_client, request.ref, ffi.nullptr,
            ffi.nullptr, deleteCallback.nativeFunction);
    if (response.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
      throw 'unable to create subscription ${response.responseHeader.serviceResult} ${statusCodeToString(response.responseHeader.serviceResult)}';
    }
    calloc.free(request);
    _logger.t("Created subscription ${response.subscriptionId}");
    subscriptionIds[response.subscriptionId] = response;
    return response.subscriptionId;
  }

  void subscriptionDelete(int subId) {
    final statusCode =
        _lib.UA_Client_Subscriptions_deleteSingle(_client, subId);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to delete subscription $subId: $statusCode ${statusCodeToString(statusCode)}';
    }
    _logger.t("Deleted subscription $subId");
    subscriptionIds.remove(subId);
  }

  int monitoredItemCreate<T>(
      NodeId nodeid, int subscriptionId, void Function(T data) callback,
      {int attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
      int monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
      Duration samplingInterval = const Duration(milliseconds: 250),
      bool discardOldest = true,
      int queueSize = 1}) {
    ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest =
        calloc<raw.UA_MonitoredItemCreateRequest>();
    _lib.UA_MonitoredItemCreateRequest_init(monRequest);
    monRequest.ref.itemToMonitor.nodeId = nodeid.rawNodeId;
    monRequest.ref.itemToMonitor.attributeId = attr;
    monRequest.ref.monitoringMode = monitoringMode;
    monRequest.ref.requestedParameters.samplingInterval =
        samplingInterval.inMicroseconds / 1000.0;
    monRequest.ref.requestedParameters.discardOldest = discardOldest;
    monRequest.ref.requestedParameters.queueSize = queueSize;

    final monitorCallback = ffi.NativeCallable<
            ffi.Void Function(
                ffi.Pointer<raw.UA_Client>,
                ffi.Uint32,
                ffi.Pointer<ffi.Void>,
                ffi.Uint32,
                ffi.Pointer<ffi.Void>,
                ffi.Pointer<raw.UA_DataValue>)>.isolateLocal(
        (ffi.Pointer<raw.UA_Client> client,
            int subId,
            ffi.Pointer<ffi.Void> subContext,
            int monId,
            ffi.Pointer<ffi.Void> monContext,
            ffi.Pointer<raw.UA_DataValue> value) {
      ffi.Pointer<raw.UA_Variant> variantPointer = calloc<raw.UA_Variant>();
      variantPointer.ref = value.ref.value;
      late final T data;
      try {
        data = _uaVariantToType<T>(variantPointer);
      } catch (e) {
        print("Error converting data to type $T: $e");
      } finally {
        calloc.free(variantPointer);
      }
      try {
        callback(data);
      } catch (e) {
        print("Error calling callback: $e");
      }
    });
    raw.UA_MonitoredItemCreateResult monResponse =
        _lib.UA_Client_MonitoredItems_createDataChange(
            _client,
            subscriptionId,
            raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
            monRequest.ref,
            ffi.nullptr,
            monitorCallback.nativeFunction,
            ffi.nullptr);
    if (monResponse.statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to create monitored item: ${monResponse.statusCode} ${statusCodeToString(monResponse.statusCode)}';
    }
    final monId = monResponse.monitoredItemId;
    _logger.t("Created monitored item $monId");
    monitoredItems.add(monResponse);
    return monId;
  }

  Stream<T> monitoredItemStream<T>(
    NodeId nodeId,
    int subscriptionId, {
    int attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
    int monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 250),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    // force the stream to be synchronous and run in the same isolate as the callback
    final controller = StreamController<T>(sync: true);

    int monitoredItemId = monitoredItemCreate<T>(
      nodeId,
      subscriptionId,
      (data) => controller.add(data),
      attr: attr,
      monitoringMode: monitoringMode,
      samplingInterval: samplingInterval,
      discardOldest: discardOldest,
      queueSize: queueSize,
    );

    controller.onCancel = () {
      _logger.t("Cancelling monitored item $monitoredItemId");
      controller.close();
    };

    return controller.stream;
  }

  dynamic _uaVariantToDart(ffi.Pointer<raw.UA_Variant> data) {
    // Check if the variant contains no data
    if (data.ref.data == ffi.nullptr) {
      return null;
    }

    final typeKind = data.ref.type.ref.typeKind;
    switch (typeKind) {
      case UA_DataTypeKindEnum.boolean:
        return data.ref.data.cast<ffi.Bool>().value;

      case UA_DataTypeKindEnum.sbyte:
        return data.ref.data.cast<ffi.Int8>().value;

      case UA_DataTypeKindEnum.byte:
        return data.ref.data.cast<ffi.Uint8>().value;

      case UA_DataTypeKindEnum.int16:
        return data.ref.data.cast<ffi.Int16>().value;

      case UA_DataTypeKindEnum.uint16:
        return data.ref.data.cast<ffi.Uint16>().value;

      case UA_DataTypeKindEnum.int32:
        return data.ref.data.cast<ffi.Int32>().value;

      case UA_DataTypeKindEnum.uint32:
        return data.ref.data.cast<ffi.Uint32>().value;

      case UA_DataTypeKindEnum.int64:
        return data.ref.data.cast<ffi.Int64>().value;

      case UA_DataTypeKindEnum.uint64:
        return data.ref.data.cast<ffi.Uint64>().value;

      case UA_DataTypeKindEnum.float:
        return data.ref.data.cast<ffi.Float>().value;

      case UA_DataTypeKindEnum.double:
        return data.ref.data.cast<ffi.Double>().value;

      case UA_DataTypeKindEnum.string:
        final str = data.ref.data.cast<raw.UA_String>().ref;
        if (str.length == 0 || str.data == ffi.nullptr) {
          return '';
        }
        return String.fromCharCodes(
            str.data.cast<ffi.Uint8>().asTypedList(str.length));

      case UA_DataTypeKindEnum.dateTime:
        return _opcuaToDateTime(_lib.UA_DateTime_toStruct(
            data.ref.data.cast<raw.UA_DateTime>().value));

      default:
        throw 'Unsupported variant type: $typeKind';
    }
  }

  T _uaVariantToType<T>(ffi.Pointer<raw.UA_Variant> data) {
    if (data.ref.data == ffi.nullptr) {
      if (null is T) {
        return null as T;
      }
      throw 'Null value cannot be converted to non-nullable type $T';
    }

    final value = _uaVariantToDart(data);

    // Special case for dynamic type
    if (T == dynamic) {
      return value as T;
    }

    // For specific types
    if (value is T) {
      return value;
    }
    _logger
        .e('Expected type $T but got ${value.runtimeType} with value $value');
    throw 'Expected type $T but got ${value.runtimeType} with value $value';
  }

  DateTime _opcuaToDateTime(raw.UA_DateTimeStruct dts) {
    return DateTime(
        dts.year, dts.month, dts.day, dts.hour, dts.min, dts.sec, dts.milliSec);
  }

  String statusCodeToString(int statusCode) {
    return _lib.UA_StatusCode_name(statusCode).cast<Utf8>().toDartString();
  }

  void disconnect() {
    final statusCode = _lib.UA_Client_disconnect(_client);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to disconnect: $statusCode ${statusCodeToString(statusCode)}';
    }
    _logger.t("Disconnected");
  }

  void delete() {
    _lib.UA_Client_delete(_client);
    _logger.t("Deleted client");
  }

  void close() {
    for (var subId in List.from(subscriptionIds.keys)) {
      subscriptionDelete(subId);
    }
    assert(subscriptionIds.isEmpty);
    disconnect();
    Future.delayed(Duration(seconds: 1), () {
      _logger.t("Deleting client");
      // idk why but the client may not be deleted immediately, it segfaults if we delete it immediately
      delete();
    });
  }

  final Logger _logger = Logger(
    level: Level.all,
    printer: SimplePrinter(colors: true),
  );
  final raw.open62541 _lib;
  final ffi.Pointer<raw.UA_Client> _client;
  late final ClientConfig _clientConfig;
  Map<int, raw.UA_CreateSubscriptionResponse> subscriptionIds = {};
  List<raw.UA_MonitoredItemCreateResult> monitoredItems = [];
}
