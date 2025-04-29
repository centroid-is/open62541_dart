import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:binarize/binarize.dart' as binarize;
import 'package:open62541/open62541.dart';

import 'generated/open62541_bindings.dart' as raw;
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
    _state = ffi.NativeCallable<
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
    _clientConfig.ref.stateCallback = _state.nativeFunction;
    _inactivity = ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>.isolateLocal(
      (ffi.Pointer<raw.UA_Client> client, int subId, ffi.Pointer<ffi.Void> subContext) =>
          _subscriptionInactivity.add(subId),
    );
    _clientConfig.ref.subscriptionInactivityCallback = _inactivity.nativeFunction;
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

  Future<void> close() async {
    await _stateStream.close();
    await _subscriptionInactivity.close();
    _state.close();
    _inactivity.close();
  }

  // Private interface
  final ffi.Pointer<raw.UA_ClientConfig> _clientConfig;
  final StreamController<ClientState> _stateStream = StreamController<ClientState>.broadcast();
  final StreamController<int> _subscriptionInactivity = StreamController<int>.broadcast();
  late ffi.NativeCallable<
      ffi.Void Function(
        ffi.Pointer<raw.UA_Client> client,
        ffi.UnsignedInt channelState,
        ffi.UnsignedInt sessionState,
        raw.UA_StatusCode connectStatus,
      )> _state;
  late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>
      _inactivity;
}

class Client {
  Client(raw.open62541 lib)
      : _lib = lib,
        _client = lib.UA_Client_new() {
    final config = lib.UA_Client_getConfig(_client);
    lib.UA_ClientConfig_setDefault(config);
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
    if (Platform.isAndroid) {
      return Client(raw.open62541(ffi.DynamicLibrary.open('libopen62541.so')));
    } else {
      return Client(raw.open62541(ffi.DynamicLibrary.executable()));
    }
  }

  ClientConfig get config => _clientConfig;

  Future<void> connect(String url) async {
    final instantReturn = _lib.UA_Client_connectAsync(_client, url.toNativeUtf8().cast());
    if (instantReturn != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to connect: ${statusCodeToString(instantReturn)}';
    }
    await config.stateStream.firstWhere((state) => state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
  }

  int syncConnect(String url, {String? username, String? password}) {
    ffi.Pointer<ffi.Char> urlPointer = url.toNativeUtf8().cast();
    if (username != null && password != null) {
      ffi.Pointer<ffi.Char> usernamePointer = username.toNativeUtf8().cast();
      ffi.Pointer<ffi.Char> passwordPointer = password.toNativeUtf8().cast();
      return _lib.UA_Client_connectUsername(_client, urlPointer, usernamePointer, passwordPointer);
    }
    return _lib.UA_Client_connect(_client, urlPointer);
  }

  bool runIterate(Duration iterate) {
    if (_client != ffi.nullptr) {
      // Get the client state
      int ms = iterate.inMilliseconds;
      return _lib.UA_Client_run_iterate(_client, ms) == raw.UA_STATUSCODE_GOOD;
    }
    return false;
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

  Future<void> writeValue(NodeId nodeId, DynamicValue value) {
    Completer<void> completer = Completer<void>();

    final variant = valueToVariant(value, _lib);

    late ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Pointer<raw.UA_WriteResponse>,
        )> callback;
    // Create callback for this specific write request
    callback = ffi.NativeCallable<
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
      if (response.ref.results.value != raw.UA_STATUSCODE_GOOD) {
        completer.completeError(
          'Failed to write value: ${statusCodeToString(response.ref.results.value)}',
        );
        return;
      }
      completer.complete();

      // Close our callback so it can be garbage collected
      callback.close();
    });
    _lib.UA_Client_writeValueAttribute_async(
      _client,
      nodeId.toRaw(_lib),
      variant,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    return completer.future;
  }

  ClientState get state {
    ffi.Pointer<ffi.UnsignedInt> state = calloc<ffi.UnsignedInt>();
    ffi.Pointer<ffi.UnsignedInt> sessionState = calloc<ffi.UnsignedInt>();
    ffi.Pointer<ffi.Uint32> connectStatus = calloc<ffi.Uint32>();
    _lib.UA_Client_getState(_client, state, sessionState, connectStatus);
    final retValue = ClientState(
        channelState: raw.UA_SecureChannelState.fromValue(state.value),
        sessionState: raw.UA_SessionState.fromValue(sessionState.value),
        recoveryStatus: connectStatus.value);
    calloc.free(state);
    calloc.free(sessionState);
    calloc.free(connectStatus);
    return retValue;
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

  Future<DynamicValue> readValue(NodeId nodeId) {
    Completer<DynamicValue> completer = Completer<DynamicValue>();

    // Create callback for this specific read request
    late ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, raw.UA_StatusCode,
            ffi.Pointer<raw.UA_DataValue>)> callback;
    callback = ffi.NativeCallable<
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
    ) async {
      if (completer.isCompleted) {
        return; // Request timed out already
      }
      if (status != raw.UA_STATUSCODE_GOOD) {
        completer.completeError('Failed to read value: ${statusCodeToString(status)}');
        return;
      }
      if (value.ref.status != raw.UA_STATUSCODE_GOOD) {
        completer.completeError('Failed to read value: ${statusCodeToString(value.ref.status)}');
        return;
      }
      // Steal the variant pointer from open62541 so they don't delete it
      // if we don't do this, the variant will be freed on a flutter async
      // boundary. f.e. while we fetch the structure of a schema.
      // because the callback we are currently in "returns" before completing.
      final source = calloc<raw.UA_Variant>();
      source.ref = value.ref.value;
      final variant = calloc<raw.UA_Variant>();
      _lib.UA_Variant_copy(source, variant);
      calloc.free(source);
      final retVal = await _variantToValueAutoSchema(variant.ref);

      // Close our callback so it can be garbage collected
      callback.close();

      // Delete the variant again that we used to reference the data
      _lib.UA_Variant_delete(variant);
      completer.complete(retVal);
    });
    _lib.UA_Client_readValueAttribute_async(
      _client,
      nodeId.toRaw(_lib),
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    return completer.future;
  }

  dynamic syncReadValue(NodeId nodeId) {
    ffi.Pointer<raw.UA_Variant> data = calloc<raw.UA_Variant>();
    int statusCode = _lib.UA_Client_readValueAttribute(_client, nodeId.toRaw(_lib), data);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      final statusCodeName = _lib.UA_StatusCode_name(statusCode);
      throw 'Bad status code $statusCode name: ${statusCodeName.cast<Utf8>().toDartString()}';
    }

    final retVal = _variantToValueAutoSchemaSync(data.ref);
    calloc.free(data);
    return retVal;
  }

  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
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

    // late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>)>
    //     deleteCallback;

    // deleteCallback = ffi
    //     .NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>)>.isolateLocal(
    //     (ffi.Pointer<raw.UA_Client> client, int subid, ffi.Pointer<ffi.Void> somedata) {
    //   stderr.write("Subscription deleted $subid");
    //   deleteCallback.close();
    // });

    final completer = Completer<int>();
    late ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
            ffi.Pointer<raw.UA_CreateSubscriptionResponse>)> callback;

    callback = ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
            ffi.Pointer<raw.UA_CreateSubscriptionResponse>)>.isolateLocal((ffi.Pointer<raw.UA_Client> client,
        ffi.Pointer<ffi.Void> somedata, int requestId, ffi.Pointer<raw.UA_CreateSubscriptionResponse> response) {
      _lib.UA_CreateSubscriptionRequest_delete(request);
      callback.close();
      if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
        completer.completeError(
            'unable to create subscription ${response.ref.responseHeader.serviceResult} ${statusCodeToString(response.ref.responseHeader.serviceResult)}');
        return;
      }
      completer.complete(response.ref.subscriptionId);
    });
    _lib.UA_Client_Subscriptions_create_async(
      _client,
      request.ref,
      ffi.nullptr,
      ffi.nullptr,
      //deleteCallback.nativeFunction,
      ffi.nullptr,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    return completer.future;
  }

  StreamController<DynamicValue> monitoredItem(
    NodeId nodeId,
    int subscriptionId, {
    raw.UA_AttributeId attr = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE,
    raw.UA_MonitoringMode monitoringMode = raw.UA_MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 250),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    // force the stream to be synchronous and run in the same isolate as the callback
    StreamController<DynamicValue> controller = StreamController<DynamicValue>();

    // We define our monitor callback here so we can use it in the onListen and onCancel closures
    late ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32,
            ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)> monitorCallback;

    // Since the api we are using handles creating multiple monitored items at once, we need to create an array of callbacks
    final callbacks = calloc<
        ffi.Pointer<
            ffi.NativeFunction<
                ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32,
                    ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)>>>(); // For now just allocate one

    // Store the monitored item id here so we can use it in the onCancel closure
    int? monId;

    controller.onCancel = () {
      final completer = Completer<void>();
      if (monId == null) {
        throw 'No monitored item id to delete, this propably mean the stream was closed before fully created';
      }
      final request = calloc<raw.UA_DeleteMonitoredItemsRequest>();
      _lib.UA_DeleteMonitoredItemsRequest_init(request);
      request.ref.subscriptionId = subscriptionId;
      final ids = calloc<ffi.Uint32>(1);
      ids[0] = monId!;
      request.ref.monitoredItemIds = ids;
      request.ref.monitoredItemIdsSize = 1;
      request.ref.subscriptionId = subscriptionId;

      late ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
              ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>)> deleteCallback;
      deleteCallback = ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
              ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>)>.isolateLocal((ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata, int requestId, ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse> response) {
        if (response.ref.results.value != raw.UA_STATUSCODE_GOOD) {
          stderr.write(
              "Error deleting monitored item: ${response.ref.results.value} ${statusCodeToString(response.ref.results.value)}");
        }
        _lib.UA_DeleteMonitoredItemsRequest_delete(request); // This frees ids as well
        monitorCallback.close();
        calloc.free(callbacks);
        deleteCallback.close();
        monId = null;
        completer.complete();
      });
      _lib.UA_Client_MonitoredItems_delete_async(
        _client,
        request.ref,
        deleteCallback.nativeFunction,
        ffi.nullptr,
        ffi.nullptr,
      );

      return completer.future;
    };

    controller.onListen = () {
      // Create our request
      ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest = calloc<raw.UA_MonitoredItemCreateRequest>();
      _lib.UA_MonitoredItemCreateRequest_init(monRequest);
      monRequest.ref.itemToMonitor.nodeId = nodeId.toRaw(_lib);
      monRequest.ref.itemToMonitor.attributeId = attr.value;
      monRequest.ref.monitoringModeAsInt = monitoringMode.value;
      monRequest.ref.requestedParameters.samplingInterval = samplingInterval.inMicroseconds / 1000.0;
      monRequest.ref.requestedParameters.discardOldest = discardOldest;
      monRequest.ref.requestedParameters.queueSize = queueSize;

      ffi.Pointer<raw.UA_CreateMonitoredItemsRequest> createRequest = calloc<raw.UA_CreateMonitoredItemsRequest>();
      _lib.UA_CreateMonitoredItemsRequest_init(createRequest);
      createRequest.ref.subscriptionId = subscriptionId;
      createRequest.ref.itemsToCreate = monRequest;
      createRequest.ref.itemsToCreateSize = 1;

      // Assign our monitor callback pointer, This one stays alive for the duration of the stream

      monitorCallback = ffi.NativeCallable<
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
      ) async {
        // Don't process the data if we are closed
        if (controller.isClosed) {
          stderr.writeln("Stream closed, data still sent from monitored item $monId");
          return;
        }
        DynamicValue data = DynamicValue();
        final variant = calloc<raw.UA_Variant>();
        try {
          // Steal the variant pointer from open62541 so they don't delete it
          // if we don't do this, the variant will be freed on a flutter async
          // boundary. f.e. while we fetch the structure of a schema.
          // because the callback we are currently in "returns" before completing.
          final source = calloc<raw.UA_Variant>();
          source.ref = value.ref.value;
          _lib.UA_Variant_copy(source, variant);
          calloc.free(source);
          data = await _variantToValueAutoSchema(variant.ref);
        } catch (e) {
          stderr.write("Error converting data to type $DynamicValue: $e");
        } finally {
          // Delete the variant again that we used to reference the data
          _lib.UA_Variant_delete(variant);
        }
        if (controller.isClosed) {
          return; // While processing the data, the stream might have been closed
        }
        try {
          controller.add(data);
        } catch (e) {
          stderr.write("Error adding data: $e $data");
        }
      });

      callbacks[0] = monitorCallback.nativeFunction;

      // Define the callback that is invoked when the monitored item is created
      late ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
              ffi.Pointer<raw.UA_CreateMonitoredItemsResponse>)> createCallback;
      createCallback = ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
              ffi.Pointer<raw.UA_CreateMonitoredItemsResponse>)>.isolateLocal((ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata, int requestId, ffi.Pointer<raw.UA_CreateMonitoredItemsResponse> response) {
        // Cleanup the request memory
        _lib.UA_CreateMonitoredItemsRequest_delete(createRequest);
        createCallback.close();
        monId = response.ref.results.ref.monitoredItemId;

        bool error = false;

        if (response.ref.resultsSize == 0) {
          controller.addError('No results for create monitored item');
          error = true;
        }
        if (response.ref.results.ref.statusCode != raw.UA_STATUSCODE_GOOD) {
          controller.addError(
              'Unable to create monitored item: ${response.ref.results.ref.statusCode} ${statusCodeToString(response.ref.results.ref.statusCode)}');
          error = true;
        }
        if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
          controller.addError(
              'Unable to create monitored item: ${response.ref.responseHeader.serviceResult} ${statusCodeToString(response.ref.responseHeader.serviceResult)}');
          error = true;
        }
        if (error) {
          controller.onCancel = () {}; // Don't invoke the real close callback
          monitorCallback.close();
          calloc.free(callbacks);
          controller.close();
        }
      });
      final statusCode = _lib.UA_Client_MonitoredItems_createDataChanges_async(
        _client,
        createRequest.ref,
        ffi.nullptr,
        callbacks,
        ffi.nullptr,
        createCallback.nativeFunction,
        ffi.nullptr,
        ffi.nullptr,
      );
      if (statusCode != raw.UA_STATUSCODE_GOOD) {
        _lib.UA_CreateMonitoredItemsRequest_delete(createRequest);
        calloc.free(callbacks);
        monitorCallback.close();
        createCallback.close();
        controller.addError('Unable to create monitored item: $statusCode ${statusCodeToString(statusCode)}');

        // Cleanup resources that the close callback was suppose to do
        controller.onCancel = () {}; // Don't invoke the real close callback
        monitorCallback.close();
        calloc.free(callbacks);
      }
    };

    return controller;
  }

  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args) async {
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
    ) async {
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
            result.add(await _variantToValueAutoSchema(results.outputArguments[i]));
          }
          completer.complete(result);
        }
      } catch (e) {
        stderr.write("Error calling callback: $e");
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
    return completer.future;
  }

  Schema readDataTypeDefinitionSync(NodeId nodeIdType) {
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
          final mp = readDataTypeDefinitionSync(dataType.toNodeId());
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

  Future<Schema> readDataTypeDefinition(NodeId nodeIdType) async {
    ffi.Pointer<raw.UA_ReadValueId> readValueId = calloc<raw.UA_ReadValueId>();
    _lib.UA_ReadValueId_init(readValueId);
    var map = Schema();
    final completer = Completer<Schema>();
    readValueId.ref.nodeId = nodeIdType.toRaw(_lib);
    readValueId.ref.attributeId = raw.UA_AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION.value;

    late ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, raw.UA_StatusCode,
            ffi.Pointer<raw.UA_DataValue>)> callback;

    callback = ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, raw.UA_StatusCode,
            ffi.Pointer<raw.UA_DataValue>)>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      ffi.Pointer<ffi.Void> userdata,
      int requestId,
      int statusCode,
      ffi.Pointer<raw.UA_DataValue> value,
    ) async {
      // Clean up request parameters
      _lib.UA_ReadValueId_delete(readValueId);

      if (statusCode != raw.UA_STATUSCODE_GOOD) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Bad status code $statusCode ${statusCodeToString(statusCode)}, NodeID: $nodeIdType';
      }
      final res = value.ref;
      if (res.value.type.ref.typeKind != raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected structure type, got ${res.value.type.ref.typeKind}';
      }
      if (!nodeIdType.isString()) {
        throw 'UA_Client_read[DATATYPEDEFINITION]: Expected string type, got $nodeIdType';
      }

      // Read our current structure
      final source = res.value.data.cast<raw.UA_StructureDefinition>();
      final structDef = calloc<raw.UA_StructureDefinition>();
      _lib.UA_StructureDefinition_copy(source, structDef);
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
          final mp = await readDataTypeDefinition(dataType.toNodeId());
          for (var subId in mp.keys) {
            map[subId] = mp[subId]!;
          }
        } else {
          throw 'Unsupported field type: $dataType';
        }
      }
      completer.complete(map);

      // Close our callback so it can be garbage collected
      callback.close();
    });
    _lib.UA_Client_readAttribute_async(
      _client,
      readValueId,
      raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );

    return completer.future;
  }

  Schema defs = {};

  DynamicValue _variantToValueAutoSchemaSync(raw.UA_Variant data) {
    if (data.type.ref.typeId.toNodeId() == NodeId.structure) {
      // Cast the data to extension object
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      final typeId = ext.ref.content.encoded.typeId.toNodeId();
      if (!defs.containsKey(typeId)) {
        defs.addAll(readDataTypeDefinitionSync(typeId));
      }
    }
    final retValue = variantToValue(data, defs: defs);
    return retValue;
  }

  Future<DynamicValue> _variantToValueAutoSchema(raw.UA_Variant data) async {
    if (data.type.ref.typeId.toNodeId() == NodeId.structure) {
      // Cast the data to extension object
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      final typeId = ext.ref.content.encoded.typeId.toNodeId();
      if (!defs.containsKey(typeId)) {
        // Copy our data before async switch
        defs.addAll(await readDataTypeDefinition(typeId));
      }
    }
    final retValue = variantToValue(data, defs: defs);
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
  }

  Future<void> delete() async {
    ffi.Pointer<raw.UA_Client> client = _client;
    _client = ffi.nullptr;
    await Future.delayed(Duration(milliseconds: 10));
    _lib.UA_Client_delete(client);
    // Client_delete calls client config state callbacks
    // Need to close the config after deleting the client
    // s.t. the native callbacks are not closed when called
    await _clientConfig.close();
    // Clear the memory allocated to structure definitions
    for (var value in defs.values) {
      _lib.UA_StructureDefinition_delete(value);
    }
  }

  final raw.open62541 _lib;
  ffi.Pointer<raw.UA_Client> _client;
  late final ClientConfig _clientConfig;
}
