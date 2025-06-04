import 'dart:async';

import 'package:ffi/ffi.dart';
import 'package:open62541/open62541.dart';

import 'generated/open62541_bindings.dart' as raw;
import 'dart:ffi' as ffi;

import 'common.dart';
import 'extensions.dart';

class Server {
  Server(
    ffi.DynamicLibrary lib, {
    LogLevel? logLevel,
    int? port,
  }) {
    _lib = raw.open62541(lib);
    final config = calloc<raw.UA_ServerConfig>();

    if (logLevel != null) {
      config.ref.logging = _lib.UA_Log_Stdout_new(logLevel);
    }
    // setMinimal sets the logging level if not set.
    int res = _lib.UA_ServerConfig_setMinimal(config, port ?? 4840, ffi.nullptr);
    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to set default server config ${statusCodeToString(res, _lib)}';
    }

    _server = _lib.UA_Server_newWithConfig(config);
  }

  late raw.open62541 _lib;
  late ffi.Pointer<raw.UA_Server> _server;

  /// Initializes and starts the OPC UA server.
  ///
  /// This method performs the initial startup sequence for the server, including:
  /// * Initializing the server's internal state
  /// * Setting up the network layer
  /// * Initializing the server's lifecycle state
  /// * Preparing the server for client connections
  ///
  /// This method must be called before any other server operations can be performed.
  /// After calling this method, you should start running server iterations using
  /// [runIterate] to process client requests.
  ///
  /// Throws an exception if the server startup fails, with the error
  /// message including the status code.
  ///
  /// Example:
  /// ```dart
  /// server.start();
  /// while (server.runIterate(waitInterval: true)) {
  ///   await Future.delayed(Duration(milliseconds: 50));
  /// }
  /// ```
  void start() {
    int retCode = _lib.UA_Server_run_startup(_server);
    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to start server ${statusCodeToString(retCode, _lib)}';
    }
  }

  /// Adds a variable node to the OPC UA server.
  ///
  /// This method creates a new variable node in the server's address space with the
  /// specified properties and value. The variable can be read and written by clients
  /// based on the provided access level.
  ///
  /// Required parameters:
  /// * [variableNodeId] - The unique identifier for the new variable node
  /// * [value] - The initial value and type information for the variable
  ///
  /// Optional parameters:
  /// * [accessLevel] - Controls read/write access to the variable (defaults to read and write enabled)
  /// * [parentNodeId] - The parent node in the address space (defaults to Objects folder)
  /// * [parentReferenceNodeId] - The reference type to the parent (defaults to Organizes)
  /// * [basedatavariableType] - The base type for the variable (defaults to BaseDataVariableType)
  ///
  /// Throws an exception if:
  /// * The value's name is not provided (required for browse name)
  /// * The server fails to add the variable node
  ///
  /// Example:
  /// ```dart
  /// final nodeId = NodeId.fromString(1, "my.variable");
  /// final value = DynamicValue(
  ///   name: "My Variable",
  ///   value: 42,
  ///   typeId: NodeId.int32,
  /// );
  /// server.addVariableNode(nodeId, value);
  /// ```
  void addVariableNode(NodeId variableNodeId, DynamicValue value,
      {AccessLevelMask accessLevel = const AccessLevelMask(read: true, write: true),
      NodeId? parentNodeId,
      NodeId? parentReferenceNodeId,
      NodeId? basedatavariableType,
      NodeId? typeId}) {
    ffi.Pointer<raw.UA_VariableAttributes> attr = calloc<raw.UA_VariableAttributes>();
    attr.ref = _lib.UA_VariableAttributes_default;
    final variant = valueToVariant(value, _lib);
    if (variant.ref.type.ref.typeId.toNodeId() == NodeId.structure) {
      variant.ref.type.ref.typeId = typeId!.toRaw(_lib);
    }
    attr.ref.value = variant.ref;
    attr.ref.accessLevel = accessLevel.value;
    typeId ??= value.typeId;
    attr.ref.dataType = typeId!.toRaw(_lib);

    if (value.name == null) {
      throw 'Value name must be provided to use as a browse name';
    }
    final name = _lib.UA_QUALIFIEDNAME(1, value.name!.toNativeUtf8().cast());

    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    parentReferenceNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES);
    basedatavariableType ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE);

    final parentNodeIdRaw = parentNodeId.toRaw(_lib);
    final parentReferenceNodeIdRaw = parentReferenceNodeId.toRaw(_lib);
    final basedatavariableTypeRaw = basedatavariableType.toRaw(_lib);

    var returnCode = _lib.UA_Server_addVariableNode(_server, variableNodeId.toRaw(_lib), parentNodeIdRaw,
        parentReferenceNodeIdRaw, name, basedatavariableTypeRaw, attr.ref, ffi.nullptr, ffi.nullptr);
    _lib.UA_VariableAttributes_delete(attr);
    if (returnCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable node ${statusCodeToString(returnCode, _lib)}, nodeId: $variableNodeId';
    }
  }

  void addVariableTypeNode(DynamicValue schema, NodeId variableTypeId, String name,
      {LocalizedText? displayName, NodeId? parentNodeId, NodeId? referenceTypeId}) {
    var dattr = calloc<raw.UA_VariableTypeAttributes>();
    if (displayName != null) {
      dattr.ref.displayName.locale.set(displayName.locale);
      dattr.ref.displayName.text.set(displayName.value);
    }
    dattr.ref.dataType = variableTypeId.toRaw(_lib);
    dattr.ref.valueRank = raw.UA_VALUERANK_SCALAR;
    final variant = valueToVariant(schema, _lib);
    dattr.ref.value = variant.ref;

    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE);
    referenceTypeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_HASSUBTYPE);

    final parentNodeIdRaw = parentNodeId.toRaw(_lib);
    final referenceTypeIdRaw = referenceTypeId.toRaw(_lib);
    final qualifiedName = _lib.UA_QUALIFIEDNAME(1, name.toNativeUtf8().cast());

    int res = _lib.UA_Server_addVariableTypeNode(_server, variableTypeId.toRaw(_lib), parentNodeIdRaw,
        referenceTypeIdRaw, qualifiedName, parentNodeIdRaw, dattr.ref, ffi.nullptr, ffi.nullptr);

    _lib.UA_Variant_delete(variant);
    _lib.UA_VariableTypeAttributes_delete(dattr);

    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable type node ${statusCodeToString(res, _lib)}';
    }
  }

  void addDataTypeNode(NodeId requestedNewNodeId, String browseName,
      {LocalizedText? displayName, NodeId? parentNodeId, NodeId? referenceTypeId}) {
    var attr = calloc<raw.UA_DataTypeAttributes>();

    if (displayName != null) {
      attr.ref.displayName.locale.set(displayName.locale);
      attr.ref.displayName.text.set(displayName.value);
    }

    parentNodeId ??= NodeId.structure;
    referenceTypeId ??= NodeId.hasSubtype;

    _addNode(raw.UA_NodeClass.UA_NODECLASS_DATATYPE, requestedNewNodeId, parentNodeId, referenceTypeId, browseName,
        NodeId.nullId, attr.cast(), getType(UaTypes.dataTypeAttributes, _lib));

    _lib.UA_DataTypeAttributes_delete(attr);
  }

  void _addNode(
      raw.UA_NodeClass nodeClass,
      NodeId requestedNewNodeId,
      NodeId parentNodeId,
      NodeId referenceTypeId,
      String browseName,
      NodeId typeDefinition,
      ffi.Pointer<raw.UA_NodeAttributes> attr,
      ffi.Pointer<raw.UA_DataType> attributeType) {
    nodeIdPtrIfNotNull(NodeId? nodeId) {
      if (nodeId == null) {
        return ffi.nullptr;
      }
      final ptr = calloc<raw.UA_NodeId>();
      ptr.ref = nodeId.toRaw(_lib);
      return ptr;
    }

    freeNodeIdIfNotNull(ffi.Pointer<raw.UA_NodeId> nodeId) {
      if (nodeId != ffi.nullptr) {
        _lib.UA_NodeId_delete(nodeId);
      }
    }

    // This is dereferenced in the underlying c code. Throw errors here
    // to avoid a segfault in the c code. which is harder to debug.
    final _requestedNewNodeId = nodeIdPtrIfNotNull(requestedNewNodeId);
    final _parentNodeId = nodeIdPtrIfNotNull(parentNodeId);
    final _referenceTypeId = nodeIdPtrIfNotNull(referenceTypeId);
    final _typeDefinition = nodeIdPtrIfNotNull(typeDefinition);

    final _browseName = _lib.UA_QUALIFIEDNAME(1, browseName.toNativeUtf8().cast());

    final retCode = _lib.UA_Server_addNode(_server, nodeClass, _requestedNewNodeId, _parentNodeId, _referenceTypeId,
        _browseName, _typeDefinition, attr, attributeType, ffi.nullptr, ffi.nullptr);

    freeNodeIdIfNotNull(_requestedNewNodeId);
    freeNodeIdIfNotNull(_parentNodeId);
    freeNodeIdIfNotNull(_referenceTypeId);
    freeNodeIdIfNotNull(_typeDefinition);

    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add node ${statusCodeToString(retCode, _lib)}';
    }
  }

  // Register callbacks onto the `variableNodeId` to get notifications
  // when the value is read and written to.
  Stream<String> monitorVariable(NodeId variableNodeId) {
    // UA_NodeId currentNodeId = UA_NODEID_STRING(1, "current-time-value-callback");
    // UA_ValueCallback callback ;
    // callback.onRead = beforeReadTime;
    // callback.onWrite = afterWriteTime;
    // UA_Server_setVariableNode_valueCallback(server, currentNodeId, callback);

    StreamController<String> controller = StreamController<String>();

    ffi.Pointer<raw.UA_ValueCallback> callback = calloc<raw.UA_ValueCallback>();

    void onRead(
        ffi.Pointer<raw.UA_Server> server,
        ffi.Pointer<raw.UA_NodeId> sessionId,
        ffi.Pointer<ffi.Void> sessionContext,
        ffi.Pointer<raw.UA_NodeId> nodeId,
        ffi.Pointer<ffi.Void> nodeContext,
        ffi.Pointer<raw.UA_NumericRange> range,
        ffi.Pointer<raw.UA_DataValue> value) {
      // TODO: Implement the read callback logic
      controller.add("Read callback triggered");
    }

    final onReadCallback = ffi.NativeCallable<
        ffi.Void Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NumericRange>,
            ffi.Pointer<raw.UA_DataValue>)>.isolateLocal(onRead);

    callback.ref.onRead = onReadCallback.nativeFunction;
    _lib.UA_Server_setVariableNode_valueCallback(_server, variableNodeId.toRaw(_lib), callback.ref);

    controller.onCancel = () {
      // _lib.UA_Server_setVariableNode_valueCallback(_server, variableNodeId.toRaw(_lib), ffi.nullptr); TODO: This cannot call us anymore
      onReadCallback.close();
      calloc.free(callback);
    };

    return controller.stream;
  }

  /// Writes a description to a variable node in the OPC UA server.
  ///
  /// This method sets the description attribute of a variable node using a
  /// localized text value. The description can be used to provide additional
  /// information about the variable to clients.
  ///
  /// Required parameters:
  /// * [variableNodeId] - The identifier of the variable node to update
  /// * [description] - The localized text containing the description
  ///
  /// Example:
  /// ```dart
  /// final nodeId = NodeId.fromString(1, "my.variable");
  /// final description = LocalizedText(
  ///   locale: "en-US",
  ///   value: "Temperature sensor reading in Celsius"
  /// );
  /// server.writeDescription(nodeId, description);
  /// ```
  void writeDescription(NodeId variableNodeId, LocalizedText description) {
    ffi.Pointer<raw.UA_LocalizedText> descriptionRaw = calloc<raw.UA_LocalizedText>();
    descriptionRaw.ref.locale.set(description.locale);
    descriptionRaw.ref.text.set(description.value);
    _lib.UA_Server_writeDescription(_server, variableNodeId.toRaw(_lib), descriptionRaw.ref);
    _lib.UA_LocalizedText_delete(descriptionRaw);
  }

  /// Runs a single iteration of the server's main loop.
  ///
  /// This method processes any pending network messages and handles outstanding
  /// asynchronous operations on the server. It is required for the server to
  /// function properly and handle client requests.
  ///
  /// The [waitInterval] parameter determines whether the server should wait for
  /// messages in the network layer. If `true`, the server will wait for incoming
  /// messages; if `false`, it will process any pending operations and return
  /// immediately.
  ///
  /// Returns `false` if the server is stopped or if the server is not initialized.
  /// returns `true` if the server is running and the iteration was successful.
  ///
  /// Example:
  /// ```dart
  /// // Run server iterations with waiting for messages
  /// while (true) {
  ///   server.runIterate(waitInterval: true);
  ///   await Future.delayed(Duration(milliseconds: 50));
  /// }
  /// ```
  bool runIterate({bool waitInterval = true}) {
    if (_server != ffi.nullptr) {
      // Check if the server is running
      final state = _lib.UA_Server_getLifecycleState(_server);
      if (state == raw.UA_LifecycleState.UA_LIFECYCLESTATE_STOPPED) {
        return false;
      }
      // This function returns the time in ms it can wait before the next iteration
      // This number is kind of high and I am unsure of the purpose. For now I will just ignore it.
      _lib.UA_Server_run_iterate(_server, waitInterval);
      return true;
    }
    return false;
  }

  /// Shuts down the OPC UA server gracefully.
  ///
  /// This method performs a controlled shutdown of the server, stopping all
  /// network operations and cleaning up resources. It should be called before
  /// deleting the server instance.
  ///
  /// Throws an exception if the shutdown operation fails, with the error
  /// message including the status code.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   server.shutdown();
  /// } catch (e) {
  ///   print('Failed to shutdown server: $e');
  /// }
  /// ```
  void shutdown() {
    int ret = _lib.UA_Server_run_shutdown(_server);
    if (ret != 0) {
      throw "Failed to shutdown server ${statusCodeToString(ret, _lib)}";
    }
  }

  /// Deletes the OPC UA server instance and frees all associated resources.
  ///
  /// This method should be called after [shutdown] to clean up all server resources.
  /// It is important to call this method to prevent memory leaks when the server
  /// is no longer needed.
  ///
  /// Throws an exception if the deletion operation fails, with the error
  /// message including the status code.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   server.shutdown();
  ///   server.delete();
  /// } catch (e) {
  ///   print('Failed to cleanup server: $e');
  /// }
  /// ```
  void delete() {
    int ret = _lib.UA_Server_delete(_server);
    if (ret != 0) {
      throw "Failed to delete server ${statusCodeToString(ret, _lib)}";
    }
  }
}
