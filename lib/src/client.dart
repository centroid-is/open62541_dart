import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';
import 'package:binarize/binarize.dart' as binarize;

import 'generated/open62541_bindings.dart' as raw;
import 'node_id.dart';
import 'extensions.dart';
import 'dynamic_value.dart';

class ClientState {
  raw.UA_SecureChannelState channelState;
  raw.UA_SessionState sessionState;
  int recoveryStatus;
  ClientState({required this.channelState, required this.sessionState, required this.recoveryStatus});
}

class ClientConfig {
  ClientConfig(this._clientConfig) {
    // Intercept callbacks
    final state = ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client> client,
          ffi.UnsignedInt channelState,
          ffi.UnsignedInt sessionState,
          raw.UA_StatusCode connectStatus,
        )>.isolateLocal(
      (ffi.Pointer<raw.UA_Client> client, int channelState, int sessionState, int recoveryStatus) => _stateStream.add(
        ClientState(
          channelState: raw.UA_SecureChannelState.fromValue(channelState),
          sessionState: raw.UA_SessionState.fromValue(sessionState),
          recoveryStatus: recoveryStatus,
        ),
      ),
    );
    _clientConfig.ref.stateCallback = state.nativeFunction;
    final inactivity = ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>.isolateLocal(
      (ffi.Pointer<raw.UA_Client> client, int subId, ffi.Pointer<ffi.Void> subContext) =>
          _subscriptionInactivity.add(subId),
    );
    _clientConfig.ref.subscriptionInactivityCallback = inactivity.nativeFunction;
  }
  Stream<ClientState> get stateStream => _stateStream.stream;
  Stream<int> get subscriptionInactivityStream => _subscriptionInactivity.stream;

  raw.UA_MessageSecurityMode get securityMode => _clientConfig.ref.securityMode;
  set securityMode(raw.UA_MessageSecurityMode mode) {
    _clientConfig.ref.securityModeAsInt = mode.value;
  }

  String get securityPolicyUri => _clientConfig.ref.securityPolicyUri.value;
  set securityPolicyUri(String uri) {
    _clientConfig.ref.securityPolicyUri.set(uri);
  }

  // Private interface
  final ffi.Pointer<raw.UA_ClientConfig> _clientConfig;
  final StreamController<ClientState> _stateStream = StreamController<ClientState>.broadcast();
  final StreamController<int> _subscriptionInactivity = StreamController<int>.broadcast();
}

class Client {
  Client(raw.open62541 lib)
      : _lib = lib,
        _client = lib.UA_Client_new() {
    final config = lib.UA_Client_getConfig(_client);
    _clientConfig = ClientConfig(config);
  }

  /// Creates a Client instance using static linking or dynamic linking based on platform.
  /// 
  /// On Android, it uses dynamic linking by loading 'libopen62541.so' since Android
  /// does not support static linking by design. For all other platforms, it uses
  /// static linking by loading from the executable itself.
  /// 
  /// Returns:
  ///   A new [Client] instance.
  factory Client.fromStatic() {
    if (Platform.isAndroid) { // android cannot support static linking by design
      return Client(raw.open62541(ffi.DynamicLibrary.open('libopen62541.so')));
    } else {
      return Client(raw.open62541(ffi.DynamicLibrary.executable()));
    }
  }

  ClientConfig get config => _clientConfig;

  int connect(String url, {String? username, String? password}) {
    ffi.Pointer<ffi.Char> urlPointer = url.toNativeUtf8().cast();
    if (username != null && password != null) {
      ffi.Pointer<ffi.Char> usernamePointer = username.toNativeUtf8().cast();
      ffi.Pointer<ffi.Char> passwordPointer = password.toNativeUtf8().cast();
      return _lib.UA_Client_connectUsername(_client, urlPointer, usernamePointer, passwordPointer);
    }
    return _lib.UA_Client_connect(_client, urlPointer);
  }

  void runIterate(Duration iterate) {
    if (_client != ffi.nullptr) {
      // Get the client state
      int ms = iterate.inMilliseconds;
      _lib.UA_Client_run_iterate(_client, ms);
    }
  }

  static ffi.Pointer<raw.UA_DataType> getType(UaTypes uaType, raw.open62541 lib) {
    int type = uaType.index;
    if (type < 0 || type > raw.UA_TYPES_COUNT) {
      throw 'Type out of boundary $type';
    }
    return ffi.Pointer.fromAddress(lib.addresses.UA_TYPES.address + (type * ffi.sizeOf<raw.UA_DataType>()));
  }

  static ffi.Pointer<raw.UA_Variant> valueToVariant(DynamicValue value, raw.open62541 lib) {
    ffi.Pointer<ffi.Uint8> pointer;

    binarize.ByteWriter wr = binarize.ByteWriter();
    value.set(wr, value, Endian.little, false, true);
    pointer = calloc<ffi.Uint8>(wr.length);
    pointer.asTypedList(wr.length).setRange(0, wr.length, wr.toBytes());

    Namespace0Id id;
    if (value.typeId!.isNumeric()) {
      id = Namespace0Id.fromInt(value.typeId!.numeric);
    } else {
      id = Namespace0Id.structure;
    }
    List<int> getDimensions(DynamicValue value) {
      if (!value.isArray) {
        return [];
      }
      if (value.asArray.isEmpty) {
        // I would like this to be an error case
        throw ArgumentError('Empty array');
      }
      var dims = [value.asArray.length];
      if (value[0].isArray) {
        dims.addAll(getDimensions(value[0]));
      }
      return dims;
    }

    final dimensions = getDimensions(value);
    ffi.Pointer<raw.UA_Variant> variant = calloc<raw.UA_Variant>();
    lib.UA_Variant_init(variant); // todo is this needed?
    variant.ref.data = pointer.cast();
    variant.ref.type = getType(id.toUaTypes(), lib);
    if (dimensions.isNotEmpty) {
      variant.ref.arrayLength = dimensions.fold(1, (a, b) => a * b);
    }
    if (dimensions.length > 1) {
      variant.ref.arrayDimensions = calloc<ffi.Uint32>(dimensions.length);
      variant.ref.arrayDimensions.asTypedList(dimensions.length).setRange(0, dimensions.length, dimensions);
      variant.ref.arrayDimensionsSize = dimensions.length;
    }

    return variant;
  }

  Future<void> writeValue(NodeId nodeId, DynamicValue value, {Duration timeout = const Duration(seconds: 10)}) {
    Completer<void> completer = Completer<void>();

    final variant = valueToVariant(value, _lib);

    // Create callback for this specific write request
    final callback = ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Pointer<raw.UA_WriteResponse>,
        )>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      ffi.Pointer<ffi.Void> userdata,
      int reqId,
      ffi.Pointer<raw.UA_WriteResponse> response,
    ) {
      if (completer.isCompleted) {
        return; // Request timed out already
      }
      _lib.UA_Variant_delete(variant);
      if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
        completer.completeError(
          'Failed to write value: ${statusCodeToString(response.ref.responseHeader.serviceResult)}',
        );
        return;
      }
      completer.complete();
    });
    _lib.UA_Client_writeValueAttribute_async(
      _client,
      nodeId.toRaw(_lib),
      variant,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    Future.delayed(timeout, () {
      // Dont complete if already completed
      if (!completer.isCompleted) {
        completer.completeError('Timeout writing $nodeId to $value');
      }
      _lib.UA_Variant_delete(variant);
    });
    return completer.future;
  }

  bool syncWriteValue(NodeId nodeId, DynamicValue value) {
    final variant = valueToVariant(value, _lib);

    // Write value
    final retValue = _lib.UA_Client_writeValueAttribute(_client, nodeId.toRaw(_lib), variant);
    if (retValue != raw.UA_STATUSCODE_GOOD) {
      stderr.write('Write off $nodeId to $value failed with $retValue, name: ${statusCodeToString(retValue)}');
    }

    // Use variant delete to delete the internal data pointer as well
    _lib.UA_Variant_delete(variant);
    return retValue == raw.UA_STATUSCODE_GOOD;
  }

  Future<DynamicValue> readValue(NodeId nodeId, {Duration timeout = const Duration(seconds: 10)}) {
    Completer<DynamicValue> completer = Completer<DynamicValue>();

    // Create callback for this specific read request
    final callback = ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          raw.UA_StatusCode,
          ffi.Pointer<raw.UA_DataValue>,
        )>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      ffi.Pointer<ffi.Void> userdata,
      int reqId,
      int status,
      ffi.Pointer<raw.UA_DataValue> value,
    ) {
      if (completer.isCompleted) {
        return; // Request timed out already
      }
      if (status != raw.UA_STATUSCODE_GOOD) {
        completer.completeError('Failed to read value: ${statusCodeToString(status)}');
        return;
      }
      final retVal = _variantToValueAutoSchema(value.ref.value);
      completer.complete(retVal);
    });
    _lib.UA_Client_readValueAttribute_async(
      _client,
      nodeId.toRaw(_lib),
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );

    // Create a timeout to avoid deadlocks
    Future.delayed(timeout, () {
      // Dont complete if already completed
      if (!completer.isCompleted) {
        completer.completeError('Timeout reading $nodeId');
      }
    });
    return completer.future;
  }

  dynamic syncReadValue(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode = _lib.UA_Client_readValueAttribute(_client, nodeId.toRaw(_lib), data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      final statusCodeName = _lib.UA_StatusCode_name(statusCode);
      throw 'Bad status code $statusCode name: ${statusCodeName.cast<Utf8>().toDartString()}';
    }

    final retVal = _variantToValueAutoSchema(data.ref);
    calloc.free(data);
    return retVal;
  }

  int subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 500),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) {
    ffi.Pointer<raw.UA_CreateSubscriptionRequest> request = calloc<raw.UA_CreateSubscriptionRequest>();
    _lib.UA_CreateSubscriptionRequest_init(request);
    request.ref.requestedPublishingInterval = requestedPublishingInterval.inMicroseconds / 1000.0;
    request.ref.requestedLifetimeCount = requestedLifetimeCount;
    request.ref.requestedMaxKeepAliveCount = requestedMaxKeepAliveCount;
    request.ref.maxNotificationsPerPublish = maxNotificationsPerPublish;
    request.ref.publishingEnabled = publishingEnabled;
    request.ref.priority = priority;

    final deleteCallback = ffi
        .NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>)>.isolateLocal(
      (ffi.Pointer<raw.UA_Client> client, int subid, ffi.Pointer<ffi.Void> somedata) =>
          stderr.write("Subscription deleted $subid"),
    );
    raw.UA_CreateSubscriptionResponse response = _lib.UA_Client_Subscriptions_create(
      _client,
      request.ref,
      ffi.nullptr,
      ffi.nullptr,
      deleteCallback.nativeFunction,
    );
    if (response.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
      throw 'unable to create subscription ${response.responseHeader.serviceResult} ${statusCodeToString(response.responseHeader.serviceResult)}';
    }
    calloc.free(request);
    _logger.t("Created subscription ${response.subscriptionId}");
    subscriptionIds[response.subscriptionId] = response;
    return response.subscriptionId;
  }

  void subscriptionDelete(int subId) {
    final statusCode = _lib.UA_Client_Subscriptions_deleteSingle(_client, subId);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to delete subscription $subId: $statusCode ${statusCodeToString(statusCode)}';
    }
    _logger.t("Deleted subscription $subId");
    subscriptionIds.remove(subId);
  }

  int monitoredItemCreate(
    NodeId nodeid,
    int subscriptionId,
    void Function(DynamicValue data) callback, {
    raw.UA_AttributeId attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
    raw.UA_MonitoringMode monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 250),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest = calloc<raw.UA_MonitoredItemCreateRequest>();
    _lib.UA_MonitoredItemCreateRequest_init(monRequest);
    monRequest.ref.itemToMonitor.nodeId = nodeid.toRaw(_lib);
    monRequest.ref.itemToMonitor.attributeId = attr.value;
    monRequest.ref.monitoringModeAsInt = monitoringMode.value;
    monRequest.ref.requestedParameters.samplingInterval = samplingInterval.inMicroseconds / 1000.0;
    monRequest.ref.requestedParameters.discardOldest = discardOldest;
    monRequest.ref.requestedParameters.queueSize = queueSize;

    final monitorCallback = ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client>,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<raw.UA_DataValue>,
        )>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      int subId,
      ffi.Pointer<ffi.Void> subContext,
      int monId,
      ffi.Pointer<ffi.Void> monContext,
      ffi.Pointer<raw.UA_DataValue> value,
    ) {
      ffi.Pointer<raw.UA_Variant> variantPointer = calloc<raw.UA_Variant>();
      variantPointer.ref = value.ref.value;
      DynamicValue data = DynamicValue();
      try {
        data = _variantToValueAutoSchema(variantPointer.ref);
      } catch (e) {
        stderr.write("Error converting data to type $DynamicValue: $e");
      } finally {
        calloc.free(variantPointer);
      }
      try {
        callback(data);
      } catch (e) {
        stderr.write("Error calling callback: $e");
      }
    });
    raw.UA_MonitoredItemCreateResult monResponse = _lib.UA_Client_MonitoredItems_createDataChange(
      _client,
      subscriptionId,
      raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
      monRequest.ref,
      ffi.nullptr,
      monitorCallback.nativeFunction,
      ffi.nullptr,
    );
    if (monResponse.statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to create monitored item: ${monResponse.statusCode} ${statusCodeToString(monResponse.statusCode)}';
    }
    final monId = monResponse.monitoredItemId;
    _logger.t("Created monitored item $monId");
    monitoredItems.add(monResponse);
    return monId;
  }

  Stream<DynamicValue> monitoredItemStream(
    NodeId nodeId,
    int subscriptionId, {
    raw.UA_AttributeId attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
    raw.UA_MonitoringMode monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 250),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    // force the stream to be synchronous and run in the same isolate as the callback
    final controller = StreamController<DynamicValue>(sync: true);

    int monitoredItemId = monitoredItemCreate(
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
      _lib.UA_Client_MonitoredItems_deleteSingle(_client, subscriptionId, monitoredItemId);
      controller.close();
    };

    return controller.stream;
  }

  Future<List<DynamicValue>> call(
    NodeId objectId,
    NodeId methodId,
    Iterable<DynamicValue> args, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final len = args.length;
    var inputArgs = calloc<raw.UA_Variant>(len);
    var ptrs = <ffi.Pointer<raw.UA_Variant>>[];
    final argsIter = args.iterator;

    for (var i = 0; i < len; i++) {
      argsIter.moveNext();
      final ptr = valueToVariant(argsIter.current, _lib);
      ptrs.add(ptr);
      inputArgs[i] = ptr.ref;
    }
    final completer = Completer<List<DynamicValue>>();
    final callbackInner = ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
            ffi.Pointer<raw.UA_CallResponse>)>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      ffi.Pointer<ffi.Void> userdata,
      int requestId,
      ffi.Pointer<raw.UA_CallResponse> cr,
    ) {
      try {
        final ref = cr.ref;
        if (ref.resultsSize == 0) {
          return completer.completeError("No results for call to $objectId $methodId", StackTrace.current);
        }
        if (ref.resultsSize > 1) {
          return completer.completeError(
            "Unsupported, multiple results for call to $objectId $methodId",
            StackTrace.current,
          );
        }
        final results = ref.results.ref;
        if (results.statusCode != raw.UA_STATUSCODE_GOOD) {
          return completer.completeError(
            "Results error on call to $objectId $methodId failed with ${statusCodeToString(results.statusCode)}",
            StackTrace.current,
          );
        }
        if (ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
          return completer.completeError(
            "Header error on call to $objectId $methodId failed with ${statusCodeToString(ref.responseHeader.serviceResult)}",
            StackTrace.current,
          );
        }
        if (results.outputArgumentsSize == 0) {
          completer.complete([]);
        } else {
          final result = <DynamicValue>[];
          for (var i = 0; i < results.outputArgumentsSize; i++) {
            result.add(_variantToValueAutoSchema(results.outputArguments[i]));
          }
          completer.complete(result);
        }
      } catch (e) {
        print("Error calling callback: $e");
        completer.completeError(e, StackTrace.current);
      } finally {
        // cleanup input arguments
        for (var ptr in ptrs) {
          _lib.UA_Variant_delete(ptr);
        }
      }
    });

    final statusCode = _lib.UA_Client_call_async(
      _client,
      objectId.toRaw(_lib),
      methodId.toRaw(_lib),
      len,
      inputArgs,
      callbackInner.nativeFunction,
      ffi.nullptr, // todo set context?
      ffi.nullptr,
    );
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to call method: $statusCode ${statusCodeToString(statusCode)}';
    }
    Future.delayed(timeout, () {
      // Dont complete if already completed
      if (!completer.isCompleted) {
        completer.completeError('Timeout calling $objectId $methodId');
        for (var ptr in ptrs) {
          _lib.UA_Variant_delete(ptr);
        }
      }
    });
    return completer.future;
  }

  Schema readDataTypeDefinition(NodeId nodeIdType) {
    ffi.Pointer<raw.UA_ReadValueId> readValueId = calloc<raw.UA_ReadValueId>();
    _lib.UA_ReadValueId_init(readValueId);
    raw.UA_DataValue res;
    var map = Schema();
    try {
      readValueId.ref.nodeId = nodeIdType.toRaw(_lib);
      readValueId.ref.attributeId = raw.UA_AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION.value;
      res = _lib.UA_Client_read(_client, readValueId);

      if (res.status != raw.UA_STATUSCODE_GOOD) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Bad status code ${res.status} ${statusCodeToString(res.status)}, NodeID: $nodeIdType';
      }
      if (res.value.type.ref.typeKind != raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected structure type, got ${res.value.type.ref.typeKind}';
      }
      if (!nodeIdType.isString()) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected string type, got $nodeIdType';
      }

      // Read our current structure
      final structDef = res.value.data.cast<raw.UA_StructureDefinition>();
      map[nodeIdType] = structDef;

      // Crawl the structure for sub structures recursivly
      for (var i = 0; i < structDef.ref.fieldsSize; i++) {
        final field = structDef.ref.fields[i];
        raw.UA_NodeId dataType = field.dataType;
        if (dataType.isNumeric()) {
          continue;
        }
        if (dataType.isString()) {
          // recursively read the nested structure type
          final mp = readDataTypeDefinition(dataType.toNodeId());
          for (var subId in mp.keys) {
            map[subId] = mp[subId]!;
          }
        } else {
          throw 'Unsupported field type: $dataType';
        }
      }
    } catch (e) {
      stderr.write("Error reading DataTypeDefinition: $e");
      rethrow;
    } finally {
      _lib.UA_ReadValueId_delete(readValueId);
    }
    return map;
  }

  DynamicValue _variantToValueAutoSchema(raw.UA_Variant data) {
    Schema defs = {};
    if (data.type.ref.typeId.toNodeId() == NodeId.structure) {
      // Cast the data to extension object
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      final typeId = ext.ref.content.encoded.typeId.toNodeId();
      defs = readDataTypeDefinition(typeId);
      for (var def in defs.keys) {
        print(defs[def]!.ref.format());
      }
    }
    final retValue = variantToValue(data, defs: defs);
    // Cleanup the defs pointers if any
    for (final ptr in defs.values) {
      _lib.UA_StructureDefinition_delete(ptr);
    }
    return retValue;
  }

  static DynamicValue variantToValue(raw.UA_Variant data, {Schema? defs}) {
    // Check if the variant contains no data
    if (data.data == ffi.nullptr) {
      return DynamicValue();
    }

    var typeId = data.type.ref.typeId.toNodeId();
    if (typeId == NodeId.structure) {
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      typeId = ext.ref.content.encoded.typeId.toNodeId();
    }

    final dimensions = data.dimensions;
    final dimensionsMultiplied = dimensions.fold(1, (a, b) => a * b);
    final bufferLength = dimensionsMultiplied * data.type.ref.memSize;
    DynamicValue retValue;

    // Read structure from opc-ua server
    DynamicValue dynamicValueSchema(NodeId nodeId) {
      if (nodeId.isNumeric()) {
        return DynamicValue(typeId: nodeId);
      }
      if (nodeId.isString()) {
        return DynamicValue.fromDataTypeDefinition(nodeId, defs!);
      }
      throw 'Unsupported nodeId type: $nodeId';
    }

    DynamicValue createNestedArray(NodeId typeId, List<int> dims) {
      if (dims.isEmpty) {
        return dynamicValueSchema(typeId);
      }

      DynamicValue list = DynamicValue(typeId: typeId);
      if (dims.length == 1) {
        // Base case: create array of the final dimension
        for (int i = 0; i < dims[0]; i++) {
          list[i] = dynamicValueSchema(typeId);
        }
      } else {
        for (int i = 0; i < dims[0]; i++) {
          list[i] = createNestedArray(typeId, dims.sublist(1));
        }
      }
      return list;
    }

    retValue = createNestedArray(typeId, dimensions.toList());
    final reader = binarize.ByteReader(data.data.cast<ffi.Uint8>().asTypedList(bufferLength));
    retValue.get(reader, Endian.little, false, true);

    return retValue;
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

  final Logger _logger = Logger(level: Level.all, printer: SimplePrinter(colors: true));
  final raw.open62541 _lib;
  final ffi.Pointer<raw.UA_Client> _client;
  late final ClientConfig _clientConfig;
  Map<int, raw.UA_CreateSubscriptionResponse> subscriptionIds = {};
  List<raw.UA_MonitoredItemCreateResult> monitoredItems = [];
}
