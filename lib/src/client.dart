import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';
import 'package:binarize/binarize.dart' as binarize;

import 'generated/open62541_bindings.dart' as raw;
import 'nodeId.dart';
import 'extensions.dart';
import 'types/string.dart';
import '../dynamic_value.dart';
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

  // This is reading a DataTypeDefinition from namespace 0
  StructureSchema readDataTypeDefinition(NodeId nodeIdType, String fieldName) {
    ffi.Pointer<raw.UA_ReadValueId> rvi = calloc<raw.UA_ReadValueId>();
    _lib.UA_ReadValueId_init(rvi);
    raw.UA_DataValue res;
    StructureSchema schema;
    try {
      rvi.ref.nodeId = nodeIdType.rawNodeId;
      rvi.ref.attributeId =
          raw.UA_AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION;
      res = _lib.UA_Client_read(_client, rvi);

      if (res.status != raw.UA_STATUSCODE_GOOD) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Bad status code ${res.status} ${statusCodeToString(res.status)}';
      }
      if (res.value.type.ref.typeKind != UA_DataTypeKindEnum.structure) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected structure type, got ${res.value.type.ref.typeKind}';
      }
      schema = StructureSchema(nodeIdType, fieldName);
      final structDef = res.value.data.cast<raw.UA_StructureDefinition>().ref;
      for (var i = 0; i < structDef.fieldsSize; i++) {
        final field = structDef.fields[i];
        final dataType = NodeId.fromRaw(field.dataType);
        if (dataType.isNumeric()) {
          schema.addField(createPredefinedType(dataType, field.name.value));
        } else if (dataType.isString()) {
          // recursively read the nested structure type
          schema.addField(readDataTypeDefinition(dataType, field.name.value));
        } else {
          throw 'Unsupported field type: $dataType';
        }
      }
    } catch (e) {
      print("Error reading DataTypeDefinition: $e");
      rethrow;
    } finally {
      _lib.UA_ReadValueId_delete(rvi);
    }
    return schema;
  }

  StructureSchema variableToSchema(NodeId nodeId) {
    ffi.Pointer<raw.UA_NodeId> output = calloc<raw.UA_NodeId>();
    int statusCode =
        _lib.UA_Client_readDataTypeAttribute(_client, nodeId.rawNodeId, output);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      _lib.UA_NodeId_delete(output);
      throw 'UA_Client_readDataTypeAttribute: Bad status code $statusCode ${statusCodeToString(statusCode)}';
    }
    StructureSchema result;
    try {
      result = readDataTypeDefinition(NodeId.fromRaw(output.ref), '__root');
    } finally {
      // todo the node is released by delete of readvalueid
      // _lib.UA_NodeId_delete(output);
    }
    _knownStructures.add(result);
    return result;
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

      case UA_DataTypeKindEnum.extensionObject:
        final extObj = data.ref.data.cast<raw.UA_ExtensionObject>().ref;
        if (extObj.encoding ==
            raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_NOBODY) {
          return null;
        }

        // Get the datatype
        final typeId = extObj.content.encoded.typeId;
        if (typeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
          final name = typeId.identifier.string.value;
          final schema = knownStructures.get(name);
          if (schema == null) {
            print("Unknown structure type: $name");
            return null;
          }
          final reader =
              binarize.Payload.read(extObj.content.encoded.body.dataIterable);
          final data = reader.get(schema);
          return data;
        }
        print("typeId: ${typeId.string()}");

        // Read first two boolean fields
        var bodyData = extObj.content.encoded.body.data;
        print("i_xBatchReady: ${bodyData.cast<ffi.Bool>().value}");
        bodyData += 1;
        print("i_xDropped: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("i_xCleaning: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("i_xOk: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("q_xDropOk: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("jbb: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("ohg: ${(bodyData).cast<ffi.Float>().value}");
        bodyData += 4;
        //       Field 8:
        // Name: a_struct
        // DataType: ns=4;s="<StructuredDataType>:ST_FP"
        print("a_struct i_xDropOk: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("a_struct i_xRun: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        final a_struct_len = (bodyData).cast<ffi.Uint32>().value;
        print("a_struct len: ${a_struct_len}");
        bodyData += 4;
        print("a_struct i_xSpare[0]: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        print("a_struct i_xSpare[1]: ${(bodyData).cast<ffi.Bool>().value}");
        bodyData += 1;
        final string_len = (bodyData).cast<ffi.Uint32>().value;
        bodyData += 4;
        print("the_string length: ${string_len}");
        final string_data =
            (bodyData).cast<ffi.Uint8>().asTypedList(string_len);
        String the_string = String.fromCharCodes(string_data);
        print("the_string: $the_string");

        print(
            "encoding: ${UA_ExtensionObjectEncodingEnum.fromInt(extObj.encoding)}"); // ENCODED_BYTESTRING
        print("content: ${extObj.content.encoded.body.length}");
        print("members size: ${data.ref.type.ref.membersSize}");
        print(
            "binary encoding id: ${data.ref.type.ref.binaryEncodingId.string()}");

      // final dataTypePtr = data.ref.type;
      // ffi.Pointer<raw.UA_String> output = calloc<raw.UA_String>();
      // _lib.UA_print(data.cast<ffi.Void>(), dataTypePtr, output);
      // print("output: ${output.ref.value}");

      // final otherType = extObj.content.decoded.type;
      // if (otherType == ffi.nullptr) {
      //   print("otherType is nullptr");
      // } else {
      //   print("other type ${otherType.ref.typeId.string()}");
      // }

      // // Handle based on typeId
      // switch (typeId.identifier.numeric) {
      //   // Add cases for specific extension object types you need to support
      //   // Example:
      //   // case UA_TYPES_ARGUMENT:
      //   //   final arg = extObj.content.encoded.body.data.cast<raw.UA_Argument>().ref;
      //   //   return ArgumentType(...);

      //   default:
      //     _logger.w(
      //         'Unsupported extension object type: ${typeId.identifier.numeric}');
      //     return null;
      // }

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
  final _knownStructures = KnownStructures();
  Map<int, raw.UA_CreateSubscriptionResponse> subscriptionIds = {};
  List<raw.UA_MonitoredItemCreateResult> monitoredItems = [];
}
