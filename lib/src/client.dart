import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/types/create_type.dart';
import 'package:tuple/tuple.dart';

import 'generated/open62541_bindings.dart' as raw;
import 'extensions.dart';
import 'dynamic_value.dart';
import 'common.dart';

class ClientState {
  raw.UA_SecureChannelState channelState;
  raw.UA_SessionState sessionState;
  int recoveryStatus;
  ClientState({required this.channelState, required this.sessionState, required this.recoveryStatus});

  @override
  String toString() {
    return 'ClientState(channelState: $channelState, sessionState: $sessionState, recoveryStatus: $recoveryStatus)';
  }
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

typedef ReadAttributeParam = Map<NodeId, List<AttributeId>>;

class Client {
  Client(
    raw.open62541 lib, {
    Duration? secureChannelLifeTime,
    String? username,
    String? password,
    MessageSecurityMode? securityMode,
    Uint8List? certificate,
    Uint8List? privateKey,
  })  : _lib = lib,
        _client = lib.UA_Client_new() {
    final config = lib.UA_Client_getConfig(_client);
    lib.UA_ClientConfig_setDefault(config);
    if (secureChannelLifeTime != null) {
      config.ref.secureChannelLifeTime = secureChannelLifeTime.inMilliseconds;
    }

    if (securityMode != null) {
      config.ref.securityModeAsInt = securityMode.value;
    }

    if (certificate != null && privateKey != null) {
      ffi.Pointer<raw.UA_ByteString> rawCertificate = calloc<raw.UA_ByteString>();
      ffi.Pointer<raw.UA_ByteString> rawPrivateKey = calloc<raw.UA_ByteString>();

      rawCertificate.ref.data = calloc<ffi.Uint8>(certificate.length);
      rawCertificate.ref.length = certificate.length;
      rawCertificate.ref.data.asTypedList(certificate.length).setRange(0, certificate.length, certificate);

      rawPrivateKey.ref.data = calloc<ffi.Uint8>(privateKey.length);
      rawPrivateKey.ref.length = privateKey.length;
      rawPrivateKey.ref.data.asTypedList(privateKey.length).setRange(0, privateKey.length, privateKey);

      _lib.UA_ClientConfig_setDefaultEncryption(
          config, rawCertificate.ref, rawPrivateKey.ref, ffi.nullptr, 0, ffi.nullptr, 0);

      // Accept all certificates
      ffi.Pointer<raw.UA_CertificateGroup> certificateVerification = calloc<raw.UA_CertificateGroup>();
      certificateVerification.ref = config.ref.certificateVerification;
      _lib.UA_CertificateGroup_AcceptAll(certificateVerification);
      config.ref.certificateVerification = certificateVerification.ref;
      calloc.free(certificateVerification);

      calloc.free(rawCertificate.ref.data);
      calloc.free(rawPrivateKey.ref.data);
      calloc.free(rawCertificate);
      calloc.free(rawPrivateKey);
    }

    if (username != null) {
      _lib.UA_ClientConfig_setAuthenticationUsername(
          config, username.toNativeUtf8().cast(), password != null ? password.toNativeUtf8().cast() : ffi.nullptr);
    }
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

  Future<void> awaitConnect() async {
    if (state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED) {
      return;
    }
    await config.stateStream.firstWhere((state) => state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
  }

  Future<void> connect(String url) async {
    final instantReturn = _lib.UA_Client_connectAsync(_client, url.toNativeUtf8().cast());
    if (instantReturn != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to connect: ${statusCodeToString(instantReturn, _lib)}';
    }
    await awaitConnect();
  }

  bool runIterate(Duration iterate) {
    if (_client != ffi.nullptr) {
      // Get the client state
      int ms = iterate.inMilliseconds;
      return _lib.UA_Client_run_iterate(_client, ms) == raw.UA_STATUSCODE_GOOD;
    }
    return false;
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
          'Failed to write value: ${statusCodeToString(response.ref.responseHeader.serviceResult, _lib)}',
        );
        return;
      }
      if (response.ref.results.value != raw.UA_STATUSCODE_GOOD) {
        completer.completeError(
          'Failed to write value: ${statusCodeToString(response.ref.results.value, _lib)}',
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

  /// Reads a value from the server.
  Future<DynamicValue> read(NodeId nodeId) async {
    final parameters = {
      nodeId: [
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
        AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        AttributeId.UA_ATTRIBUTEID_DATATYPE,
        AttributeId.UA_ATTRIBUTEID_VALUE,
      ],
    };
    final results = await readAttribute(parameters);

    assert(results.length == 1);
    assert(results.containsKey(nodeId));
    return results[nodeId]!;
  }

  // Reimplementation of the readAttribute method from open62541
  // this method on the flutter side has the same purpose. To deal with
  // the complexity of calling the underlying service and provide a
  // single point of entry for all read operations.
  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes) async {
    final nodeCount = nodes.entries.map<int>((entry) => entry.value.length).fold(0, (prev, curr) => prev + curr);
    ffi.Pointer<raw.UA_ReadValueId> readValueId = calloc<raw.UA_ReadValueId>(nodeCount);
    final completer = Completer<Map<NodeId, DynamicValue>>();
    final indorderNodes = [];
    var index = 0;
    for (var entry in nodes.entries) {
      for (var attributeId in entry.value) {
        readValueId[index].nodeId = entry.key.toRaw(_lib);
        readValueId[index].attributeId = attributeId.value;
        index++;
        indorderNodes.add((entry.key, attributeId));
      }
    }
    assert(index == nodeCount);

    ffi.Pointer<raw.UA_ReadRequest> request = calloc<raw.UA_ReadRequest>();
    _lib.UA_ReadRequest_init(request);
    request.ref.nodesToRead = readValueId;
    request.ref.nodesToReadSize = nodeCount;
    request.ref.timestampsToReturnAsInt = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH.value;

    ffi.Pointer<ffi.Uint32> requestIdPtr = calloc<ffi.Uint32>();

    late ffi.NativeCallable<
            ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>
        callback;

    callback = ffi.NativeCallable<
        ffi.Void Function(
            ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>.isolateLocal((
      ffi.Pointer<raw.UA_Client> client,
      ffi.Pointer<ffi.Void> userdata,
      int requestId,
      ffi.Pointer<ffi.Void> voidPointer,
    ) async {
      // Cleanup request and callback method
      callback.close();
      _lib.UA_ReadRequest_delete(request);
      calloc.free(requestIdPtr);

      if (voidPointer == ffi.nullptr) {
        completer.completeError('readAttribute callback received null pointer');
        return;
      }
      ffi.Pointer<raw.UA_ReadResponse> response = ffi.Pointer.fromAddress(voidPointer.address);
      List<ffi.Pointer<raw.UA_DataValue>> pointers = [];

      // Steal the data_value pointer from open62541 so they don't delete it
      // if we don't do this, the data_value will be freed on a flutter async
      // boundary. f.e. while we fetch the structure of a schema.
      // because the callback we are currently in "returns" before completing.
      ffi.Pointer<raw.UA_DataValue> source = calloc<raw.UA_DataValue>();
      for (var i = 0; i < response.ref.resultsSize; i++) {
        pointers.add(calloc<raw.UA_DataValue>());
        _lib.UA_DataValue_init(pointers.last);
        source.ref = response.ref.results[i];
        _lib.UA_DataValue_copy(source, pointers.last);
      }
      calloc.free(source);

      assert(pointers.length == response.ref.resultsSize);
      assert(nodeCount == pointers.length);

      final retVal = <NodeId, DynamicValue>{};
      for (var i = 0; i < pointers.length; i++) {
        if (pointers[i].ref.status != raw.UA_STATUSCODE_GOOD) {
          completer.completeError(
              'Failed to read attribute: ${statusCodeToString(pointers[i].ref.status, _lib)} NodeId: ${indorderNodes[i].$1} AttributeId: ${indorderNodes[i].$2}');
          break; // Break here to cleanup pointers memory below
        }
        final status = pointers[i].ref.status;
        final ok = status == raw.UA_STATUSCODE_GOOD;
        var reference = retVal[indorderNodes[i].$1] ?? DynamicValue();
        raw.UA_Variant? value = ok ? pointers[i].ref.value : null;

        switch (indorderNodes[i].$2) {
          case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
            final description = value!.data.cast<raw.UA_LocalizedText>();
            reference.description = LocalizedText(description.ref.text.value, description.ref.locale.value);
          case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
            final displayName = value!.data.cast<raw.UA_LocalizedText>();
            reference.displayName = LocalizedText(displayName.ref.text.value, displayName.ref.locale.value);
          case AttributeId.UA_ATTRIBUTEID_DATATYPE:
            final dataType = value!.data.cast<raw.UA_NodeId>();
            reference.typeId = dataType.ref.toNodeId();
          case AttributeId.UA_ATTRIBUTEID_VALUE:
            final temporary = await _variantToValueAutoSchema(value!, reference.typeId);
            reference.value = temporary.value;
            reference.typeId = reference.typeId ?? temporary.typeId; // Prefer explicitly fetched type id
            reference.enumFields = reference.enumFields ?? temporary.enumFields;
          case AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION:
            final temporary =
                DynamicValue.fromDataTypeDefinition(reference.typeId ?? value!.type.ref.typeId.toNodeId(), value!);
            reference.value = temporary.value;
            reference.typeId = reference.typeId ?? temporary.typeId;
            reference.enumFields = reference.enumFields ?? temporary.enumFields;
          default:
            throw 'Unhandled attribute id ${indorderNodes[i].$2}';
        }
        retVal[indorderNodes[i].$1] = reference;
      }
      for (var element in pointers) {
        _lib.UA_DataValue_delete(element);
      }
      if (!completer.isCompleted) completer.complete(retVal);
    });

    int res = _lib.UA_Client_AsyncService(
      _client,
      request.cast(),
      getType(UaTypes.readRequest, _lib),
      callback.nativeFunction,
      getType(UaTypes.readResponse, _lib),
      ffi.nullptr,
      requestIdPtr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      _lib.UA_ReadRequest_delete(request);
      calloc.free(requestIdPtr);
      completer.completeError('Failed to read attribute: ${statusCodeToString(res, _lib)}');
      return completer.future;
    }

    return completer.future;
  }

  Future<NodeId> readDataTypeAttribute(NodeId nodeId) async {
    final parameters = {
      nodeId: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
    };
    final results = await readAttribute(parameters);
    assert(results.length == 1);
    assert(results.containsKey(nodeId));
    return results[nodeId]!.typeId!;
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
            'unable to create subscription ${response.ref.responseHeader.serviceResult} ${statusCodeToString(response.ref.responseHeader.serviceResult, _lib)}');
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

  /// Creates a monitored item on the server.
  ///
  /// If [prefetchTypeId] is true, the data type of the node will be read and cached.
  /// This is useful if you are reading a value that is a structure or an enum.
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    StreamController<Map<NodeId, DynamicValue>> controller = StreamController<Map<NodeId, DynamicValue>>();

    // We define our monitor callback here so we can use it in the onListen and onCancel closures
    late ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32,
            ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)> monitorCallback;

    // figure out the size of the node set
    final nodeCount = nodes.entries.map<int>((entry) => entry.value.length).fold(0, (prev, curr) => prev + curr);

    // Since the api we are using handles creating multiple monitored items at once, we need to create an array of callbacks
    final callbacks = calloc<
        ffi.Pointer<
            ffi.NativeFunction<
                ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32,
                    ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)>>>(nodeCount);

    // Store the monitored item id here so we can use it in the onCancel closure
    List<int> monIds = [];
    ffi.Pointer<ffi.Uint32> localRequestId = ffi.nullptr;
    Map<int, Tuple2<NodeId, AttributeId>> monIdToNodeAndAttribute = {};

    controller.onCancel = () {
      final completer = Completer<void>();
      if (monIds.isEmpty) {
        if (localRequestId == ffi.nullptr) {
          throw 'This should not happen';
        } else {
          // The monitored item request has not yet returned
          _lib.UA_Client_cancelByRequestId(_client, localRequestId.value, ffi.nullptr);
          completer.complete();
        }
      } else {
        final request = calloc<raw.UA_DeleteMonitoredItemsRequest>();
        _lib.UA_DeleteMonitoredItemsRequest_init(request);
        request.ref.subscriptionId = subscriptionId;
        final ids = calloc<ffi.Uint32>(monIds.length);
        for (var i = 0; i < monIds.length; i++) {
          ids[i] = monIds[i];
        }
        request.ref.monitoredItemIds = ids;
        request.ref.monitoredItemIdsSize = monIds.length;
        request.ref.subscriptionId = subscriptionId;

        late ffi.NativeCallable<
            ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
                ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>)> deleteCallback;
        deleteCallback = ffi.NativeCallable<
            ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32,
                ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>)>.isolateLocal((ffi.Pointer<raw.UA_Client> client,
            ffi.Pointer<ffi.Void> userdata, int requestId, ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse> response) {
          if (response == ffi.nullptr) {
            stderr.write(
                "Error deleting monitored item, nullptr provided connection propably already closed. Client cleanup.");
          } else if (response.ref.resultsSize == 0) {
            stderr.write(
                "Error deleting monitored item, no results provided, connection propably already closed. Client cleanup.");
          } else {
            for (var i = 0; i < response.ref.resultsSize; i++) {
              if (response.ref.results[i] != raw.UA_STATUSCODE_GOOD) {
                stderr.write(
                    "Error deleting monitored item: ${response.ref.results.value} ${statusCodeToString(response.ref.results.value, _lib)}");
              }
            }
          }
          _lib.UA_DeleteMonitoredItemsRequest_delete(request); // This frees ids as well
          monitorCallback.close();
          calloc.free(callbacks);
          deleteCallback.close();
          monIds.clear();
          completer.complete();
        });
        _lib.UA_Client_MonitoredItems_delete_async(
          _client,
          request.ref,
          deleteCallback.nativeFunction,
          ffi.nullptr,
          ffi.nullptr,
        );
      }
      return completer.future;
    };

    controller.onListen = () async {
      // Create our request
      ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest = calloc<raw.UA_MonitoredItemCreateRequest>(nodeCount);
      var index = 0;
      for (var entry in nodes.entries) {
        for (var attribute in entry.value) {
          monRequest[index].itemToMonitor.nodeId = entry.key.toRaw(_lib);
          monRequest[index].itemToMonitor.attributeId = attribute.value;
          monRequest[index].monitoringModeAsInt = monitoringMode.value;
          monRequest[index].requestedParameters.samplingInterval = samplingInterval.inMicroseconds / 1000.0;
          monRequest[index].requestedParameters.discardOldest = discardOldest;
          monRequest[index].requestedParameters.queueSize = queueSize;
          index++;
        }
      }

      ffi.Pointer<raw.UA_CreateMonitoredItemsRequest> createRequest = calloc<raw.UA_CreateMonitoredItemsRequest>();
      _lib.UA_CreateMonitoredItemsRequest_init(createRequest);
      createRequest.ref.subscriptionId = subscriptionId;
      createRequest.ref.itemsToCreate = monRequest;
      createRequest.ref.itemsToCreateSize = nodeCount;

      Map<NodeId, DynamicValue> latestValues = {};
      Set<int> seenMonIds = {};

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
        if (value == ffi.nullptr) {
          controller.addError('Failed to read value, nullptr provided');
          return;
        }
        if (value.ref.status != raw.UA_STATUSCODE_GOOD) {
          controller.addError('Failed to read value: ${statusCodeToString(value.ref.status, _lib)}');
          return;
        }
        try {
          //TODO: Find the stuff we used to create the request
          final temp = monIdToNodeAndAttribute[monId]!;
          final nodeId = temp.item1;
          final attributeId = temp.item2;
          seenMonIds.add(monId);

          var reference = latestValues[nodeId] ?? DynamicValue();
          final ref = value.ref.value;

          switch (attributeId) {
            case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
              final description = ref.data.cast<raw.UA_LocalizedText>();
              reference.description = LocalizedText(description.ref.text.value, description.ref.locale.value);
            case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
              final displayName = ref.data.cast<raw.UA_LocalizedText>();
              reference.displayName = LocalizedText(displayName.ref.text.value, displayName.ref.locale.value);
            case AttributeId.UA_ATTRIBUTEID_DATATYPE:
              final dataType = ref.data.cast<raw.UA_NodeId>();
              reference.typeId = dataType.ref.toNodeId();
            case AttributeId.UA_ATTRIBUTEID_VALUE:
              // Steal the variant pointer from open62541 so they don't delete it
              // if we don't do this, the variant will be freed on a flutter async
              // boundary. f.e. while we fetch the structure of a schema.
              // because the callback we are currently in "returns" before completing.
              final source = calloc<raw.UA_Variant>();
              source.ref = value.ref.value;
              final variant = calloc<raw.UA_Variant>();
              _lib.UA_Variant_copy(source, variant);
              calloc.free(source);
              final data = await _variantToValueAutoSchema(variant.ref, reference.typeId);
              reference.value = data.value;
              reference.typeId = reference.typeId ?? data.typeId;
              reference.enumFields = data.enumFields;
              _lib.UA_Variant_delete(variant);
            case AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION:
              final temporary =
                  DynamicValue.fromDataTypeDefinition(reference.typeId ?? ref.type.ref.typeId.toNodeId(), ref);
              reference.value = temporary.value;
              reference.typeId = reference.typeId ?? temporary.typeId;
              reference.enumFields = reference.enumFields ?? temporary.enumFields;
            default:
              throw 'Unhandled attribute id $attributeId';
          }
          latestValues[nodeId] = reference;
          if (controller.isClosed) {
            return; // While processing the data the controller might have been closed
          }
          try {
            if (seenMonIds.length == nodeCount) {
              controller.add(latestValues);
            }
          } catch (e) {
            stderr.write("Error adding data: $e");
          }
        } catch (e) {
          stderr.write("Error converting data to type $DynamicValue: $e");
        }
      });

      // Set all the callbacks to have the same handler function
      for (var i = 0; i < nodeCount; i++) {
        callbacks[i] = monitorCallback.nativeFunction;
      }

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
        calloc.free(localRequestId);

        bool error = false;
        if (response == ffi.nullptr) {
          controller.addError('ffi pointer is null');
          error = true;
        } else {
          if (response.ref.resultsSize == 0) {
            controller.addError('No results for create monitored item');
            error = true;
          } else if (response.ref.results.ref.statusCode != raw.UA_STATUSCODE_GOOD) {
            controller.addError(
                'Unable to create monitored item: ${response.ref.results.ref.statusCode} ${statusCodeToString(response.ref.results.ref.statusCode, _lib)}');
            error = true;
          } else if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            controller.addError(
                'Unable to create monitored item: ${response.ref.responseHeader.serviceResult} ${statusCodeToString(response.ref.responseHeader.serviceResult, _lib)}');
            error = true;
          }

          if (error) {
            controller.onCancel = () {}; // Don't invoke the real close callback
            monitorCallback.close();
            calloc.free(callbacks);
            controller.close();
          } else {
            assert(response.ref.resultsSize == nodeCount);
            int index = 0;
            Map<Tuple2<NodeId, AttributeId>, int> failures = {};
            for (var node in nodes.keys) {
              for (var attributes in nodes[node]!) {
                if (response.ref.results[index].statusCode != raw.UA_STATUSCODE_GOOD) {
                  failures[Tuple2(node, attributes)] = response.ref.results[index].statusCode;
                } else {
                  monIds.add(response.ref.results[index].monitoredItemId);
                  monIdToNodeAndAttribute[response.ref.results[index].monitoredItemId] = Tuple2(node, attributes);
                }
                index++;
              }
            }
            if (failures.isNotEmpty) {
              controller.addError(
                  "Unable to create monitored item: ${failures.entries.map((e) => "${e.key}: ${statusCodeToString(e.value, _lib)}").join(", ")}");
              controller.close(); // Call onCancel above
            }
          }
        }
      });
      localRequestId = calloc<ffi.Uint32>();
      final statusCode = _lib.UA_Client_MonitoredItems_createDataChanges_async(
        _client,
        createRequest.ref,
        ffi.nullptr,
        callbacks,
        ffi.nullptr,
        createCallback.nativeFunction,
        ffi.nullptr,
        localRequestId,
      );
      if (statusCode != raw.UA_STATUSCODE_GOOD) {
        _lib.UA_CreateMonitoredItemsRequest_delete(createRequest);
        calloc.free(callbacks);
        monitorCallback.close();
        createCallback.close();
        controller.addError('Unable to create monitored item: $statusCode ${statusCodeToString(statusCode, _lib)}');

        // Cleanup resources that the close callback was suppose to do
        controller.onCancel = () {}; // Don't invoke the real close callback
        monitorCallback.close();
        calloc.free(callbacks);
      }
    };

    return controller.stream;
  }

  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    final controller = StreamController<DynamicValue>();
    final stream = monitoredItems(
      {
        nodeId: [
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
          AttributeId.UA_ATTRIBUTEID_VALUE,
        ]
      },
      subscriptionId,
      monitoringMode: monitoringMode,
      samplingInterval: samplingInterval,
      discardOldest: discardOldest,
      queueSize: queueSize,
    );
    final subscription = stream.listen((event) => controller.add(event.values.first));
    subscription.onError((error) => controller.addError(error));
    controller.onCancel = () {
      subscription.cancel();
    };
    subscription.onDone(() {
      controller.close();
    });
    return controller.stream;
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
            "Results error on call to $objectId $methodId failed with ${statusCodeToString(results.statusCode, _lib)}",
            StackTrace.current,
          );
        }
        if (ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
          return completer.completeError(
            "Header error on call to $objectId $methodId failed with ${statusCodeToString(ref.responseHeader.serviceResult, _lib)}",
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
      throw 'Unable to call method: $statusCode ${statusCodeToString(statusCode, _lib)}';
    }
    return completer.future;
  }

  Future<Schema> buildSchema(NodeId nodeIdType) async {
    var map = Schema();
    map[nodeIdType] = (await readAttribute({
      nodeIdType: [AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION]
    }))
        .values
        .first;
    final val = map[nodeIdType]!;
    if (val.typeId == NodeId.structureDefinition) {
      val.typeId =
          nodeIdType; // TODO: Inside the read enum typeids are overwritten as int32. This is a mix and needs to be cleaned up
    }
    if (val.isObject) {
      for (var entry in val.entries) {
        if (nodeIdToPayloadType(entry.value.typeId) == null) {
          final temporary = await buildSchema(entry.value.typeId!);
          map.addAll(temporary);
          val[entry.value.name] = map[entry.value.typeId]!;
        }
      }
    }
    return map;
  }

  Schema defs = {};

  Future<DynamicValue> _variantToValueAutoSchema(raw.UA_Variant data, [NodeId? dataTypeId]) async {
    var typeId = data.type.ref.typeId.toNodeId();
    if (dataTypeId != null && nodeIdToPayloadType(dataTypeId) == null) {
      if (!defs.containsKey(dataTypeId)) {
        defs.addAll(await buildSchema(dataTypeId));
      }
    } else if (typeId == NodeId.structure) {
      // Cast the data to extension object
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      typeId = ext.ref.content.encoded.typeId.toNodeId();
      if (!defs.containsKey(typeId)) {
        // Copy our data before async switch
        defs.addAll(await buildSchema(typeId));
      }
    }
    final retValue = variantToValue(data, defs: defs, dataTypeId: dataTypeId);
    return retValue;
  }

  void disconnect() {
    final statusCode = _lib.UA_Client_disconnect(_client);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to disconnect: $statusCode ${statusCodeToString(statusCode, _lib)}';
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
  }

  final raw.open62541 _lib;
  ffi.Pointer<raw.UA_Client> _client;
  late final ClientConfig _clientConfig;
}
