import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';
import 'package:binarize/binarize.dart' as binarize;

import 'generated/open62541_bindings.dart' as raw;
import 'nodeId.dart';
import 'extensions.dart';
import 'dynamic_value.dart';
import 'types/schema.dart';
import 'types/create_type.dart';

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

  KnownStructures get knownStructures => _knownStructures;
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

  static ffi.Pointer<raw.UA_DataType> getType(int type, raw.open62541 lib) {
    if (type < 0 || type > raw.UA_TYPES_COUNT) {
      throw 'Type out of boundary $type';
    }
    return ffi.Pointer.fromAddress(lib.addresses.UA_TYPES.address +
        (type * ffi.sizeOf<raw.UA_DataType>()));
  }

  static ffi.Pointer<raw.UA_Variant> valueToVariant(
      dynamic value, TypeKindEnum tKind, raw.open62541 lib) {
    ffi.Pointer<raw.UA_Variant> variant = calloc<raw.UA_Variant>();

    var pload = typeKindToPayloadType(tKind);
    var offset = 0;
    if (value is List) {
      pload = wrapInArray(pload, [value.length]);
      offset = 4; // Size encoded in the front
    }

    binarize.ByteWriter wr = binarize.ByteWriter();
    pload.set(wr, value, Endian.little);
    final bytes = wr.toBytes();
    ffi.Pointer<ffi.Uint8> pointer = calloc<ffi.Uint8>(bytes.length);
    for (int i = offset; i < bytes.length; i++) {
      pointer[i - offset] = bytes[i];
    }

    if (value is List) {
      lib.UA_Variant_setArray(
          variant, pointer.cast(), value.length, getType(tKind.value, lib));
    } else {
      lib.UA_Variant_setScalar(
          variant, pointer.cast(), getType(tKind.value, lib));
    }

    return variant;
  }

  Future<bool> asyncWriteValue(
      NodeId nodeId, dynamic value, TypeKindEnum tKind) {
    Completer<bool> future = Completer<bool>();
    throw 'unimplemented';
    return future.future;
  }

  bool writeValue(NodeId nodeId, dynamic value, TypeKindEnum tKind) {
    final variant = valueToVariant(value, tKind, _lib);

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

  dynamic readValue(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode =
        _lib.UA_Client_readValueAttribute(_client, nodeId.toRaw(_lib), data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      final statusCodeName = _lib.UA_StatusCode_name(statusCode);
      throw 'Bad status code $statusCode name: ${statusCodeName.cast<Utf8>().toDartString()}';
    }

    final typeKind = data.ref.type.ref.typeKind;
    if (typeKind == TypeKindEnum.extensionObject) {
      // Populate missing structure definition, todo dont fetch already fetched items
      variableToSchema(nodeId);
    }
    final retVal = variantToValue(data, structs: _knownStructures);
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
      _lib.UA_Client_MonitoredItems_deleteSingle(
          _client, subscriptionId, monitoredItemId);
      controller.close();
    };

    return controller.stream;
  }

  // This is reading a DataTypeDefinition from namespace 0
  StructureSchema readDataTypeDefinition(
      raw.UA_NodeId nodeIdType, String fieldName) {
    ffi.Pointer<raw.UA_ReadValueId> readValueId = calloc<raw.UA_ReadValueId>();
    _lib.UA_ReadValueId_init(readValueId);
    raw.UA_DataValue res;
    StructureSchema schema;
    try {
      readValueId.ref.nodeId = nodeIdType;
      readValueId.ref.attributeId =
          raw.UA_AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION;
      res = _lib.UA_Client_read(_client, readValueId);

      if (res.status != raw.UA_STATUSCODE_GOOD) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Bad status code ${res.status} ${statusCodeToString(res.status)}';
      }
      if (res.value.type.ref.typeKind != TypeKindEnum.structure) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected structure type, got ${res.value.type.ref.typeKind}';
      }
      if (!nodeIdType.isString()) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected string type, got ${nodeIdType.format()}';
      }

      // TODO: get this to work
      // rvi.ref.attributeId = raw.UA_AttributeId.UA_ATTRIBUTEID_DESCRIPTION;
      // final descriptionRes = _lib.UA_Client_read(_client, rvi);
      // if (descriptionRes.status == raw.UA_STATUSCODE_GOOD) {

      //   print(
      //       'Description: ${descriptionRes.value.data.cast<raw.UA_LocalizedText>().ref.text.value}');
      // }

      schema = StructureSchema(fieldName, structureName: nodeIdType.string!);
      final structDef = res.value.data.cast<raw.UA_StructureDefinition>().ref;
      for (var i = 0; i < structDef.fieldsSize; i++) {
        final field = structDef.fields[i];
        raw.UA_NodeId dataType = field.dataType;
        StructureSchema fieldSchema;
        List<int> arrayDimensions = field.dimensions;
        if (dataType.isNumeric()) {
          fieldSchema = createPredefinedType(
              dataType.toNodeId(), field.fieldName, arrayDimensions);
        } else if (dataType.isString()) {
          // recursively read the nested structure type
          fieldSchema = readDataTypeDefinition(dataType, field.fieldName);
        } else {
          throw 'Unsupported field type: $dataType';
        }
        // print('fieldName: ${field.fieldName}');
        fieldSchema.description = field.fieldDescription;
        schema.addField(fieldSchema);
      }
    } catch (e) {
      print("Error reading DataTypeDefinition: $e");
      rethrow;
    } finally {
      _lib.UA_ReadValueId_delete(readValueId);
    }
    return schema;
  }

  StructureSchema variableToSchema(NodeId nodeId) {
    ffi.Pointer<raw.UA_NodeId> output = calloc<raw.UA_NodeId>();
    int statusCode = _lib.UA_Client_readDataTypeAttribute(
        _client, nodeId.toRaw(_lib), output);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      _lib.UA_NodeId_delete(output);
      throw 'UA_Client_readDataTypeAttribute: Bad status code $statusCode ${statusCodeToString(statusCode)}';
    }
    StructureSchema result;
    try {
      result = readDataTypeDefinition(output.ref, StructureSchema.schemaRootId);
    } finally {
      // todo the node is released by delete of readvalueid
      // _lib.UA_NodeId_delete(output);
    }
    _knownStructures.add(result);
    return result;
  }

  static dynamic variantToValue(ffi.Pointer<raw.UA_Variant> data,
      {KnownStructures? structs}) {
    // Check if the variant contains no data
    if (data.ref.data == ffi.nullptr) {
      return null;
    }

    final typeKind = data.ref.type.ref.typeKind;
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
      case TypeKindEnum.dateTime:
      case TypeKindEnum.string:
        final dimensions =
            ref.arrayLength > 0 ? [ref.arrayLength] : ref.dimensions;
        final payloadType =
            wrapInArray(typeKindToPayloadType(typeKind), dimensions);
        final dimensionsMultiplied = dimensions.fold(1, (a, b) => a * b);
        final bufferLength = dimensionsMultiplied * ref.type.ref.memSize;
        final reader = binarize.ByteReader(
            ref.data.cast<ffi.Uint8>().asTypedList(bufferLength),
            endian: binarize.Endian.little);

        final value = payloadType.get(reader);
        if (reader.isNotDone) {
          throw StateError(
              'Reader is not done reading where value is\n $value');
        }
        return value;

      case TypeKindEnum.extensionObject:
        if (structs == null) {
          throw 'Structs needs to be provided';
        }
        final dimensions =
            ref.arrayLength > 0 ? [ref.arrayLength] : ref.dimensions;
        if (dimensions.isEmpty) {
          final extObj = ref.data.cast<raw.UA_ExtensionObject>().ref;
          return extObj.toDynamicValue(structs);
        }
        if (dimensions.length == 1) {
          final result = <DynamicValue>[];
          for (var i = 0; i < dimensions[0]; i++) {
            final extObj = ref.data.cast<raw.UA_ExtensionObject>()[i];
            result.add(extObj.toDynamicValue(structs));
          }
          return result;
        }
        final result = <List<DynamicValue>>[];
        for (var dimension in dimensions) {
          final innerResult = <DynamicValue>[];
          for (var i = 0; i < dimension; i++) {
            final extObj = ref.data.cast<raw.UA_ExtensionObject>()[i];
            innerResult.add(extObj.toDynamicValue(structs));
          }
          result.add(innerResult);
        }
        return result;

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

    final value = variantToValue(data, structs: _knownStructures);

    // Special case for dynamic type
    if (T == dynamic) {
      return value as T;
    }

    // For specific types
    if (value is T) {
      return value;
    }
    // todo: handle lists
    _logger
        .e('Expected type $T but got ${value.runtimeType} with value $value');
    throw 'Expected type $T but got ${value.runtimeType} with value $value';
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
  final _knownStructures = KnownStructures();
  Map<int, raw.UA_CreateSubscriptionResponse> subscriptionIds = {};
  List<raw.UA_MonitoredItemCreateResult> monitoredItems = [];
}
