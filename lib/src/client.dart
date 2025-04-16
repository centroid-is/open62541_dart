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
import 'types/create_type.dart';

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

  UA_MessageSecurityModeEnum get securityMode =>
      UA_MessageSecurityModeEnum.fromInt(_clientConfig.ref.securityMode);
  set securityMode(UA_MessageSecurityModeEnum mode) {
    _clientConfig.ref.securityMode = mode.value;
  }

  String get securityPolicyUri => _clientConfig.ref.securityPolicyUri.value;
  set securityPolicyUri(String uri) {
    _clientConfig.ref.securityPolicyUri.set(uri);
  }

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
    final config = lib.UA_Client_getConfig(_client);
    _clientConfig = ClientConfig(config);
  }

  ClientConfig get config => _clientConfig;

  int connect(String url, {String? username, String? password}) {
    ffi.Pointer<ffi.Char> urlPointer = url.toNativeUtf8().cast();
    if (username != null && password != null) {
      ffi.Pointer<ffi.Char> usernamePointer = username.toNativeUtf8().cast();
      ffi.Pointer<ffi.Char> passwordPointer = password.toNativeUtf8().cast();
      return _lib.UA_Client_connectUsername(
          _client, urlPointer, usernamePointer, passwordPointer);
    }
    return _lib.UA_Client_connect(_client, urlPointer);
  }

  void runIterate(Duration iterate) {
    int ms = iterate.inMilliseconds;
    _lib.UA_Client_run_iterate(_client, ms);
  }

  static ffi.Pointer<raw.UA_DataType> getType(
      UaTypes uaType, raw.open62541 lib) {
    int type = uaType.value;
    if (type < 0 || type > raw.UA_TYPES_COUNT) {
      throw 'Type out of boundary $type';
    }
    return ffi.Pointer.fromAddress(lib.addresses.UA_TYPES.address +
        (type * ffi.sizeOf<raw.UA_DataType>()));
  }

  static ffi.Pointer<raw.UA_Variant> valueToVariant(
      DynamicValue value, raw.open62541 lib) {
    ffi.Pointer<raw.UA_Variant> variant = calloc<raw.UA_Variant>();

    binarize.ByteWriter wr = binarize.ByteWriter();
    value.set(wr, value, Endian.little);
    final bytes = wr.toBytes();
    int offset = 0;
    if (value.isArray) {
      offset = 4;
    }
    ffi.Pointer<ffi.Uint8> pointer = calloc<ffi.Uint8>(bytes.length);
    for (int i = offset; i < bytes.length; i++) {
      pointer[i - offset] = bytes[i];
    }

    //TODO: This is propably not correct, do this for now
    if (value.typeId != null && value.typeId!.isString()) {
      //TODO: Array
      ffi.Pointer<raw.UA_ExtensionObject> ext =
          calloc<raw.UA_ExtensionObject>();
      ext.ref.content.encoded.typeId = value.typeId!.toRaw(lib);
      ext.ref.content.encoded.body.length = bytes.length;
      ext.ref.content.encoded.body.data = pointer;
      ext.ref.encoding = 1;
      pointer = ext.cast();
      raw.UA_TYPES_BOOLEAN;
    }

    Namespace0Id id;
    if (value.typeId!.isNumeric()) {
      id = Namespace0Id.fromInt(value.typeId!.numeric);
    } else {
      id = Namespace0Id.structure;
    }
    if (value.isArray) {
      lib.UA_Variant_setArray(variant, pointer.cast(), value.asArray.length,
          getType(id.toUaTypes(), lib));
    } else {
      lib.UA_Variant_setScalar(
          variant, pointer.cast(), getType(id.toUaTypes(), lib));
    }

    return variant;
  }

  Future<bool> asyncWriteValue(
      NodeId nodeId, dynamic value, TypeKindEnum tKind) {
    Completer<bool> future = Completer<bool>();
    throw 'unimplemented';
    return future.future;
  }

  bool rawWrite(NodeId nodeId, ffi.Pointer<raw.UA_Variant> variant) {
    // Write value
    final retValue = _lib.UA_Client_writeValueAttribute(
        _client, nodeId.toRaw(_lib), variant);
    if (retValue != raw.UA_STATUSCODE_GOOD) {
      stderr.write(
          'Write off $nodeId to failed with $retValue, name: ${statusCodeToString(retValue)}');
    }

    // Use variant delete to delete the internal data pointer as well
    //_lib.UA_Variant_delete(variant);
    return retValue == raw.UA_STATUSCODE_GOOD;
  }

  bool writeValue(NodeId nodeId, DynamicValue value) {
    final variant = valueToVariant(value, _lib);

    // Write value
    final retValue = _lib.UA_Client_writeValueAttribute(
        _client, nodeId.toRaw(_lib), variant);
    if (retValue != raw.UA_STATUSCODE_GOOD) {
      stderr.write(
          'Write off $nodeId to $value failed with $retValue, name: ${statusCodeToString(retValue)}');
    }

    // Use variant delete to delete the internal data pointer as well
    _lib.UA_Variant_delete(variant);
    return retValue == raw.UA_STATUSCODE_GOOD;
  }

  ffi.Pointer<raw.UA_Variant> rawRead(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode =
        _lib.UA_Client_readValueAttribute(_client, nodeId.toRaw(_lib), data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      final statusCodeName = _lib.UA_StatusCode_name(statusCode);
      throw 'Bad status code $statusCode name: ${statusCodeName.cast<Utf8>().toDartString()}';
    }
    return data;
  }

  dynamic readValue(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode =
        _lib.UA_Client_readValueAttribute(_client, nodeId.toRaw(_lib), data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      final statusCodeName = _lib.UA_StatusCode_name(statusCode);
      throw 'Bad status code $statusCode name: ${statusCodeName.cast<Utf8>().toDartString()}';
    }

    Map<NodeId, raw.UA_StructureDefinition>? defs;
    if (data.ref.type.ref.typeId.toNodeId() == NodeId.structure) {
      // Cast the data to extension object
      final ext = data.ref.data.cast<raw.UA_ExtensionObject>();
      final typeId = ext.ref.content.encoded.typeId.toNodeId();
      defs = readDataTypeDefinition(typeId);
    }
    final retVal = variantToValue(data, defs: defs);
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
            stderr.write("Subscription deleted $subid"));
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

  int monitoredItemCreate(NodeId nodeid, int subscriptionId,
      void Function(DynamicValue data) callback,
      {int attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
      int monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
      Duration samplingInterval = const Duration(milliseconds: 250),
      bool discardOldest = true,
      int queueSize = 1}) {
    ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest =
        calloc<raw.UA_MonitoredItemCreateRequest>();
    _lib.UA_MonitoredItemCreateRequest_init(monRequest);
    monRequest.ref.itemToMonitor.nodeId = nodeid.toRaw(_lib);
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
      DynamicValue data = DynamicValue();
      try {
        Map<NodeId, raw.UA_StructureDefinition>? defs;
        if (variantPointer.ref.type.ref.typeId.toNodeId() == NodeId.structure) {
          // Cast the data to extension object
          final ext = variantPointer.ref.data.cast<raw.UA_ExtensionObject>();
          final typeId = ext.ref.content.encoded.typeId.toNodeId();
          defs = readDataTypeDefinition(typeId);
        }
        data = variantToValue(variantPointer, defs: defs);
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

  Stream<DynamicValue> monitoredItemStream(
    NodeId nodeId,
    int subscriptionId, {
    int attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
    int monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
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
      _lib.UA_Client_MonitoredItems_deleteSingle(
          _client, subscriptionId, monitoredItemId);
      controller.close();
    };

    return controller.stream;
  }

  Map<NodeId, raw.UA_StructureDefinition> readDataTypeDefinition(
      NodeId nodeIdType) {
    ffi.Pointer<raw.UA_ReadValueId> readValueId = calloc<raw.UA_ReadValueId>();
    _lib.UA_ReadValueId_init(readValueId);
    raw.UA_DataValue res;
    var map = <NodeId, raw.UA_StructureDefinition>{};
    try {
      readValueId.ref.nodeId = nodeIdType.toRaw(_lib);
      readValueId.ref.attributeId =
          raw.UA_AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION;
      res = _lib.UA_Client_read(_client, readValueId);

      if (res.status != raw.UA_STATUSCODE_GOOD) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Bad status code ${res.status} ${statusCodeToString(res.status)}, NodeID: $nodeIdType';
      }
      if (res.value.type.ref.typeKind != TypeKindEnum.structure) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected structure type, got ${res.value.type.ref.typeKind}';
      }
      if (!nodeIdType.isString()) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected string type, got $nodeIdType';
      }

      // Read our current structure
      final structDef = res.value.data.cast<raw.UA_StructureDefinition>().ref;
      map[nodeIdType] = structDef;

      // Crawl the structure for sub structures recursivly
      for (var i = 0; i < structDef.fieldsSize; i++) {
        final field = structDef.fields[i];
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

  static DynamicValue variantToValue(ffi.Pointer<raw.UA_Variant> data,
      {Map<NodeId, raw.UA_StructureDefinition>? defs}) {
    // Check if the variant contains no data
    if (data.ref.data == ffi.nullptr) {
      return DynamicValue();
    }

    final typeKind = data.ref.type.ref.typeKind;
    final typeId = data.ref.type.ref.typeId;
    final ref = data.ref;

    switch (typeKind) {
      case TypeKindEnum.boolean:
      case TypeKindEnum.sbyte:
      case TypeKindEnum.byte:
      case TypeKindEnum.int16:
      case TypeKindEnum.uint16:
      case TypeKindEnum.int32:
      case TypeKindEnum.uint32:
      case TypeKindEnum.int64:
      case TypeKindEnum.uint64:
      case TypeKindEnum.float:
      case TypeKindEnum.double:
      case TypeKindEnum.datetime:
      case TypeKindEnum.string:
        final dimensions =
            ref.arrayLength > 0 ? [ref.arrayLength] : ref.dimensions;
        final payloadType =
            wrapInArray(nodeIdToPayloadType(typeId.toNodeId()), dimensions);
        final dimensionsMultiplied = dimensions.fold(1, (a, b) => a * b);
        final bufferLength = dimensionsMultiplied * ref.type.ref.memSize;
        final reader = binarize.ByteReader(
            ref.data.cast<ffi.Uint8>().asTypedList(bufferLength),
            endian: binarize.Endian.little);

        final value = payloadType.get(reader, Endian.little);
        if (reader.isNotDone) {
          throw StateError(
              'Reader is not done reading where value is\n $value');
        }
        if (value is List) {
          return DynamicValue.fromList(value, typeId: typeId.toNodeId());
        } else {
          return DynamicValue(value: value, typeId: typeId.toNodeId());
        }

      case TypeKindEnum.extensionObject:
        // Read structure from opc-ua server
        assert(defs != null);

        final ext = ref.data.cast<raw.UA_ExtensionObject>().ref.content.encoded;
        var tt = ext.typeId;
        DynamicValue object =
            DynamicValue.fromDataTypeDefinition(tt.toNodeId(), defs!);

        //TODO: I want raw.UA_String to implemnt TypedData s.t. no copy is needed here
        var buffer = <int>[];
        for (int i = 0; i < ext.body.length; i++) {
          buffer.add(ext.body.data[i]);
        }
        var reader = binarize.ByteReader(Uint8List.fromList(buffer));
        object.get(reader, Endian.little);

        return object;
      default:
        throw 'Unsupported variant type: $typeKind';
    }
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
