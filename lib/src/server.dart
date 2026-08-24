import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

class Server {
  Server({LogLevel? logLevel, int? port}) {
    final config = ua_calloc<raw.UA_ServerConfig>();

    if (logLevel != null) {
      config.ref.logging = raw.UA_Log_Stdout_new(logLevel);
    }
    // setMinimal sets the logging level if not set.
    int res = raw.UA_ServerConfig_setMinimal(config, port ?? 4840, ffi.nullptr);
    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to set default server config ${statusCodeToString(res)}';
    }

    _server = raw.UA_Server_newWithConfig(config);
    _config = raw.UA_Server_getConfig(_server);
  }

  late ffi.Pointer<raw.UA_Server> _server;
  late ffi.Pointer<raw.UA_ServerConfig> _config;

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
    int retCode = raw.UA_Server_run_startup(_server);
    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to start server ${statusCodeToString(retCode)}';
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
  void addVariableNode(
    NodeId variableNodeId,
    DynamicValue value, {
    AccessLevelMask accessLevel = const AccessLevelMask(read: true, write: true),
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    NodeId? baseDataVariableType,
    NodeId? typeId,
  }) {
    ffi.Pointer<raw.UA_VariableAttributes> attr = raw.UA_VariableAttributes_new();
    attr.ref = raw.UA_VariableAttributes_default;

    final variant = valueToVariant(value);
    typeId ??= value.typeId;

    // Enum metadata: when the value carries enum field definitions, publish a
    // custom enum DataType so a client can read back an EnumDefinition (field
    // value + name). open62541 derives the DataTypeDefinition attribute of a
    // DataType node from the registered custom `UA_DataType`, so we register an
    // enum-kind type and point this node's DataType attribute at it. The stored
    // value stays Int32 on the wire; open62541 relabels it to the enum type on
    // write via `adjustType` (an enum is Int32-equivalent).
    if (value.enumFields != null && value.enumFields!.isNotEmpty) {
      typeId = _addEnumType(value, typeId);
    }

    // For a structured value, `valueToVariant` returns a variant wrapping a
    // binary-encoded UA_ExtensionObject. Store it as such and keep the node's
    // DataType attribute (set below) pointing at the concrete custom type.
    //
    // Historically this branch instead re-labelled the variant as the native
    // custom type and copied the *binary-encoded* body into `value.data`. That
    // only happens to work for structs whose members are all fixed-size,
    // pointer-free primitives (int/bool/double), where the encoded layout
    // coincides with the in-memory layout. For any member that is a pointer type
    // in native memory - notably UA_String, which is `{size_t length; UA_Byte*
    // data}` in memory but `[int32 length][utf8 bytes]` on the wire - open62541
    // would later walk the members and dereference the encoded bytes as a
    // pointer, corrupting the heap and aborting the process (e.g. during the
    // UA_Variant_copy performed by UA_Server_addVariableNode). Storing the value
    // as an ExtensionObject lets open62541 keep it opaque, and the client read
    // path already decodes the encoded body via variantToValue/deserialize.
    attr.ref.value = variant.ref;
    attr.ref.accessLevel = accessLevel.value;
    attr.ref.dataType = typeId!.toRaw();

    if (value.name == null) {
      throw 'Value name must be provided to use as a browse name';
    }
    final name = raw.UA_QUALIFIEDNAME(1, value.name!.toNativeUtf8(allocator: ua_malloc).cast());

    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    parentReferenceNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES);
    baseDataVariableType ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE);

    final parentNodeIdRaw = parentNodeId.toRaw();
    final parentReferenceNodeIdRaw = parentReferenceNodeId.toRaw();
    final baseDataVariableTypeRaw = baseDataVariableType.toRaw();

    var returnCode = raw.UA_Server_addVariableNode(
      _server,
      variableNodeId.toRaw(),
      parentNodeIdRaw,
      parentReferenceNodeIdRaw,
      name,
      baseDataVariableTypeRaw,
      attr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_VariableAttributes_delete(attr);
    ua_calloc.free(variant);
    if (returnCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable node ${statusCodeToString(returnCode)}, nodeId: $variableNodeId';
    }
  }

  void addVariableTypeNode(
    DynamicValue schema,
    NodeId variableTypeId,
    String name, {
    LocalizedText? displayName,
    NodeId? parentNodeId,
    NodeId? referenceTypeId,
  }) {
    var dattr = raw.UA_VariableTypeAttributes_new();
    if (displayName != null) {
      dattr.ref.displayName.locale.set(displayName.locale);
      dattr.ref.displayName.text.set(displayName.value);
    }
    dattr.ref.dataType = variableTypeId.toRaw();
    dattr.ref.valueRank = raw.UA_VALUERANK_SCALAR;
    final variant = valueToVariant(schema);
    dattr.ref.value = variant.ref;

    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE);
    referenceTypeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_HASSUBTYPE);

    final parentNodeIdRaw = parentNodeId.toRaw();
    final referenceTypeIdRaw = referenceTypeId.toRaw();
    final qualifiedName = raw.UA_QUALIFIEDNAME(1, name.toNativeUtf8(allocator: ua_malloc).cast());

    int res = raw.UA_Server_addVariableTypeNode(
      _server,
      variableTypeId.toRaw(),
      parentNodeIdRaw,
      referenceTypeIdRaw,
      qualifiedName,
      parentNodeIdRaw,
      dattr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );

    raw.UA_Variant_delete(variant);
    raw.UA_VariableTypeAttributes_delete(dattr);

    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable type node ${statusCodeToString(res)}';
    }
  }

  void addDataTypeNode(
    NodeId requestedNewNodeId,
    String browseName, {
    LocalizedText? displayName,
    NodeId? parentNodeId,
    NodeId? referenceTypeId,
  }) {
    var attr = raw.UA_DataTypeAttributes_new();

    if (displayName != null) {
      attr.ref.displayName.locale.set(displayName.locale);
      attr.ref.displayName.text.set(displayName.value);
    }

    parentNodeId ??= NodeId.structure;
    referenceTypeId ??= NodeId.hasSubtype;

    _addNode(
      raw.UA_NodeClass.UA_NODECLASS_DATATYPE,
      requestedNewNodeId,
      parentNodeId,
      referenceTypeId,
      browseName,
      NodeId.nullId,
      attr.cast(),
      getType(UaTypes.dataTypeAttributes),
    );

    raw.UA_DataTypeAttributes_delete(attr);
  }

  void _addNode(
    raw.UA_NodeClass nodeClass,
    NodeId requestedNewNodeId,
    NodeId parentNodeId,
    NodeId referenceTypeId,
    String browseName,
    NodeId typeDefinition,
    ffi.Pointer<raw.UA_NodeAttributes> attr,
    ffi.Pointer<raw.UA_DataType> attributeType,
  ) {
    final browse = raw.UA_QUALIFIEDNAME(1, browseName.toNativeUtf8(allocator: ua_malloc).cast());

    //TODO: It seems this method has been removed.
    var retCode = raw.UA_Server_addNode_begin(
      _server,
      nodeClass,
      requestedNewNodeId.toRaw(),
      parentNodeId.toRaw(),
      referenceTypeId.toRaw(),
      browse,
      typeDefinition.toRaw(),
      attr.cast(),
      attributeType,
      ffi.nullptr,
      ffi.nullptr,
    );

    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add node begin ${statusCodeToString(retCode)}';
    }

    retCode = raw.UA_Server_addNode_finish(_server, requestedNewNodeId.toRaw());

    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add node finish ${statusCodeToString(retCode)}';
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

    ffi.Pointer<raw.UA_CallbackValueSource> callback = ua_calloc<raw.UA_CallbackValueSource>();

    //TODO : FIX
    // raw.UA_UInt32 onRead(
    //   ffi.Pointer<raw.UA_Server> server,
    //   ffi.Pointer<raw.UA_NodeId> sessionId,
    //   ffi.Pointer<ffi.Void> sessionContext,
    //   ffi.Pointer<raw.UA_NodeId> nodeId,
    //   ffi.Pointer<ffi.Void> nodeContext,
    //   ffi.Bool includeSourceTimeStamp,
    //   ffi.Pointer<raw.UA_NumericRange> range,
    //   ffi.Pointer<raw.UA_DataValue> value,
    // ) {
    //   // TODO: Implement the read callback logic
    //   controller.add("Read callback triggered");
    //   return raw.UA_STATUSCODE_GOOD as raw.UA_StatusCode;
    // }

    //TODO: FIX
    // final onReadCallback = ffi.NativeCallable<
    //     raw.UA_UInt32 Function(
    //         ffi.Pointer<raw.UA_Server>,
    //         ffi.Pointer<raw.UA_NodeId>,
    //         ffi.Pointer<ffi.Void>,
    //         ffi.Pointer<raw.UA_NodeId>,
    //         ffi.Pointer<ffi.Void>,
    //         ffi.Bool,
    //         ffi.Pointer<raw.UA_NumericRange>,
    //         ffi.Pointer<raw.UA_DataValue>
    //         )>.isolateLocal(onRead);

    //callback.ref.read = onReadCallback.nativeFunction;
    raw.UA_Server_setVariableNode_callbackValueSource(_server, variableNodeId.toRaw(), callback.ref);

    controller.onCancel = () {
      // _lib.UA_Server_setVariableNode_valueCallback(_server, variableNodeId.toRaw(_lib), ffi.nullptr); TODO: This cannot call us anymore

      //TODO: FIX
      //onReadCallback.close();
      ua_calloc.free(callback);
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
    ffi.Pointer<raw.UA_LocalizedText> descriptionRaw = raw.UA_LocalizedText_new();
    descriptionRaw.ref.locale.set(description.locale);
    descriptionRaw.ref.text.set(description.value);
    raw.UA_Server_writeDescription(_server, variableNodeId.toRaw(), descriptionRaw.ref);
    raw.UA_LocalizedText_delete(descriptionRaw);
  }

  DynamicValue read(NodeId variableNodeId, {Schema? schema}) {
    final variant = raw.UA_Variant_new();
    raw.UA_Server_readValue(_server, variableNodeId.toRaw(), variant);
    final value = variantToValue(variant.ref, defs: schema);
    raw.UA_Variant_delete(variant);
    return value;
  }

  void write(NodeId variableNodeId, DynamicValue value) {
    final variant = valueToVariant(value);
    raw.UA_Server_writeValue(_server, variableNodeId.toRaw(), variant.ref);
    raw.UA_Variant_delete(variant);
  }

  // populate structschema for out type
  void addCustomType(NodeId typeId, DynamicValue value) {
    final array = ua_calloc<raw.UA_DataTypeArray>();
    if (!value.isObject) {
      throw 'Value must be a object';
    }

    // Record the rich schema locally. open62541's generated DataTypeDefinition
    // cannot carry per-field descriptions / display names, so an in-process
    // client read restores them from here (see
    // OpcUaDynamicValueSerializer.overlayLocalFieldMetadata).
    OpcUaDynamicValueSerializer.registerLocalSchema(typeId, value);
    array.ref.typesSize = 1;
    array.ref.types = ua_calloc<raw.UA_DataType>(1);
    array.ref.types[0].typeId = typeId.toRaw();
    array.ref.types[0].binaryEncodingId = NodeId.fromString(
      typeId.namespace,
      "BinaryEncoding_Default:${value.name}",
    ).toRaw();

    array.ref.types[0].typeKind = raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE;

    final memberCount = value.asObject.length;
    array.ref.types[0].membersSize = memberCount;
    array.ref.types[0].members = ua_calloc<raw.UA_DataTypeMember>(memberCount);
    // Accumulate the in-memory size of the struct. open62541 materialises the
    // struct in native memory (e.g. when validating/decoding the value) by
    // walking the members: each member is placed at the running offset plus its
    // `padding`, then the offset advances by the member type's `memSize`. With a
    // packed layout (padding == 0) the total size must therefore equal the sum
    // of the member type sizes. A too-small `memSize` makes open62541 write
    // past the allocation while placing pointer-bearing members (e.g. UA_String),
    // corrupting the heap and aborting the process.
    int memSize = 0;
    for (var i = 0; i < memberCount; i++) {
      final entry = value.asObject.entries.elementAt(i);
      final member = entry.value;
      final memberName = entry.key;
      if (member.isObject && _findDataType(member.typeId!) == ffi.nullptr) {
        // If we contain a member add that first
        addCustomType(member.typeId!, member);
      }
      final memberType = _findDataType(member.typeId!);
      if (memberType == ffi.nullptr) {
        throw 'Unable to resolve data type for member "$memberName" (${member.typeId}) of $typeId';
      }
      array.ref.types[0].members[i].memberName = memberName.toNativeUtf8(allocator: ua_malloc).cast();
      array.ref.types[0].members[i].memberType = memberType;
      array.ref.types[0].members[i].isOptional = member.isOptional;
      array.ref.types[0].members[i].isArray = member.isArray;
      array.ref.types[0].members[i].padding = 0;
      // Arrays are stored as a (size_t length, T* data) pair in the native
      // struct; scalar members occupy the member type's own size.
      memSize += member.isArray ? ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer<ffi.Void>>() : memberType.ref.memSize;
    }
    array.ref.types[0].memSize = memSize;

    // Have open62541 clear the pointers we are allocating here on configuration clean-up
    array.ref.cleanup = true;
    array.ref.next = _config.ref.customDataTypes;
    _config.ref.customDataTypes = array;
  }

  /// Registers a custom enum `UA_DataType` (kind [raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM])
  /// for [value]'s [DynamicValue.enumFields] and adds a matching DataType node
  /// (a subtype of `Enumeration`). Returns the synthesized enum type NodeId,
  /// which the caller uses as the variable's DataType so a client reading the
  /// DataType node's `DataTypeDefinition` attribute gets an `EnumDefinition`.
  ///
  /// open62541 stores each enum field's integer value in the member's
  /// `memberType` pointer slot and its name in `memberName`
  /// (see `UA_DataType_toEnumDescription`); enum values are copied as a flat
  /// Int32 (`copy4Byte`), so the pointer slot is never dereferenced.
  NodeId _addEnumType(DynamicValue value, NodeId? underlying) {
    final fields = value.enumFields!;
    final ns = underlying?.namespace ?? value.typeId?.namespace ?? 1;
    final browseName = 'EnumType_${value.name ?? 'anon'}';
    final enumTypeId = NodeId.fromString(ns, browseName);

    // Reuse if this enum type was already published on the server.
    if (_findDataType(enumTypeId) != ffi.nullptr) {
      return enumTypeId;
    }

    final array = ua_calloc<raw.UA_DataTypeArray>();
    array.ref.typesSize = 1;
    array.ref.types = ua_calloc<raw.UA_DataType>(1);
    array.ref.types[0].typeId = enumTypeId.toRaw();
    array.ref.types[0].typeKind = raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM;

    final memberCount = fields.length;
    array.ref.types[0].membersSize = memberCount;
    array.ref.types[0].members = ua_calloc<raw.UA_DataTypeMember>(memberCount);
    var i = 0;
    for (final field in fields.values) {
      array.ref.types[0].members[i].memberName = field.name.toNativeUtf8(allocator: ua_malloc).cast();
      array.ref.types[0].members[i].memberType = ffi.Pointer.fromAddress(field.value);
      i++;
    }
    // Int32-sized. Set memSize last so the packed bitfield write preserves the
    // typeKind/membersSize bits set above (mirrors `addCustomType`).
    array.ref.types[0].memSize = ffi.sizeOf<ffi.Int32>();

    // Have open62541 clear the pointers we are allocating here on clean-up.
    array.ref.cleanup = true;
    array.ref.next = _config.ref.customDataTypes;
    _config.ref.customDataTypes = array;

    // Publish the DataType node so the client can read its DataTypeDefinition.
    addDataTypeNode(enumTypeId, browseName, parentNodeId: NodeId.fromNumeric(0, raw.UA_NS0ID_ENUMERATION));

    return enumTypeId;
  }

  ffi.Pointer<raw.UA_DataType> _findDataType(NodeId typeId) {
    final nodeId = ua_calloc<raw.UA_NodeId>();
    nodeId.ref = typeId.toRaw();
    final ret = raw.UA_Server_findDataType(_server, nodeId);
    ua_calloc.free(nodeId);
    return ret;
  }

  /// Runs a single iteration of the server's main loop.
  ///
  /// This method processes any pending network messages and handles outstanding
  /// asynchronous operations on the server. It is required for the server to
  /// function properly and handle client requests.
  ///
  /// The [waitInterval] parameter determines whether the server should block the
  /// calling isolate thread while waiting for network activity. If `false` (the
  /// default) the server performs a single non-blocking poll of pending
  /// operations and returns immediately, yielding control back to the Dart event
  /// loop. If `true`, the underlying native call blocks the isolate thread until
  /// the server's next scheduled activity.
  ///
  /// The default is non-blocking on purpose. Dart runs cooperatively on a single
  /// isolate, so a blocking iterate parks the whole isolate: any sibling
  /// [Server] (or a [Client]) driven on the same isolate is starved until this
  /// call returns. Concretely, three cooperatively-pumped servers with the old
  /// blocking default let the first client connect quickly but starved later
  /// ones for seconds (or indefinitely). A non-blocking poll returns promptly so
  /// every pump on the isolate gets a turn.
  ///
  /// IMPORTANT (busy-spin): because the non-blocking default returns immediately,
  /// callers MUST `await` a short delay between iterations. A tight
  /// `while (server.runIterate());` with no delay would spin at 100% CPU. Drive
  /// the server from an `async` loop with a `Future.delayed` (or a
  /// `Timer.periodic`) as the examples below show. The native `UA_Server_run_iterate`
  /// API only exposes a boolean (block-until-next-scheduled vs poll-once) with no
  /// intermediate timeout, so throttling is the caller's responsibility via that
  /// delay rather than an internal wait cap.
  ///
  /// Returns `false` if the server is stopped or if the server is not initialized.
  /// returns `true` if the server is running and the iteration was successful.
  ///
  /// Example (non-blocking default — cooperates with other work on the isolate):
  /// ```dart
  /// // MUST include a delay so the loop does not busy-spin.
  /// while (server.runIterate()) {
  ///   await Future.delayed(Duration(milliseconds: 50));
  /// }
  /// ```
  ///
  /// Opt back into the old blocking behavior only for a single, standalone
  /// server that owns the isolate:
  /// ```dart
  /// while (server.runIterate(waitInterval: true)) {
  ///   await Future.delayed(Duration(milliseconds: 50));
  /// }
  /// ```
  bool runIterate({bool waitInterval = false}) {
    if (_server != ffi.nullptr) {
      // Check if the server is running
      final state = raw.UA_Server_getLifecycleState(_server);
      if (state == raw.UA_LifecycleState.UA_LIFECYCLESTATE_STOPPED) {
        return false;
      }
      // This function returns the time in ms it can wait before the next iteration
      // This number is kind of high and I am unsure of the purpose. For now I will just ignore it.
      raw.UA_Server_run_iterate(_server, waitInterval);
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
    int ret = raw.UA_Server_run_shutdown(_server);
    if (ret != 0) {
      throw "Failed to shutdown server ${statusCodeToString(ret)}";
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
    int ret = raw.UA_Server_delete(_server);
    if (ret != 0) {
      throw "Failed to delete server ${statusCodeToString(ret)}";
    }
  }
}
