import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

/// Describes a single input or output argument of a method node.
///
/// Mirrors open62541's `UA_Argument`: a [name], the argument's [dataType]
/// (a [NodeId], e.g. [NodeId.int32]), a [valueRank] (`-1` = scalar — the
/// default, `0` = one-or-more dimensions, `>= 1` = a fixed number of
/// dimensions), optional [arrayDimensions], and an optional [description].
class Argument {
  const Argument({
    required this.name,
    required this.dataType,
    this.valueRank = -1,
    this.arrayDimensions = const [],
    this.description,
  });

  final String name;
  final NodeId dataType;
  final int valueRank;
  final List<int> arrayDimensions;
  final LocalizedText? description;
}

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

  // ---- Data-source (callback) variable node plumbing -----------------------
  //
  // A data-source node sources its value live from a Dart callback on every
  // client read, and (optionally) delivers client writes to a Dart callback.
  // Rather than allocate one NativeCallable per node, the server keeps a single
  // shared read/write dispatcher pair (created lazily on first use) and routes
  // to the per-node Dart handlers via [_dataSourceReads]/[_dataSourceWrites],
  // keyed by NodeId. This keeps exactly two native callbacks alive for the
  // whole server, both closed in [delete].
  ffi.NativeCallable<
    raw.UA_StatusCode Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Bool,
      ffi.Pointer<raw.UA_NumericRange>,
      ffi.Pointer<raw.UA_DataValue>,
    )
  >?
  _dsReadDispatcher;
  ffi.NativeCallable<
    raw.UA_StatusCode Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NumericRange>,
      ffi.Pointer<raw.UA_DataValue>,
    )
  >?
  _dsWriteDispatcher;
  final Map<NodeId, DynamicValue Function()> _dataSourceReads = {};
  final Map<NodeId, void Function(DynamicValue)> _dataSourceWrites = {};

  // The declared DataType of each data-source node whose `typeId` was given.
  // The write dispatcher uses it to marshal an incoming custom-struct value with
  // the correct field schema: a client writes a structured value as a binary
  // ExtensionObject, and decoding it back into a [DynamicValue] with typed
  // fields requires the registered schema (see [addCustomType]). Without it a
  // struct write would decode as an opaque ExtensionObject and fail. Keyed by
  // the node's NodeId; scalar nodes are present too but resolve to a payload
  // type and take the plain (schema-less) decode path.
  final Map<NodeId, NodeId> _dataSourceTypeIds = {};

  // Value-change notification plumbing backing [onValueChanged]: a single
  // shared onWrite dispatcher (created lazily, closed in [delete]) routes to
  // the per-node broadcast StreamControllers, keyed by NodeId.
  ffi.NativeCallable<
    ffi.Void Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NumericRange>,
      ffi.Pointer<raw.UA_DataValue>,
    )
  >?
  _valueChangeDispatcher;
  final Map<NodeId, StreamController<DynamicValue>> _valueChangeControllers = {};

  // Keeps the native callbacks backing method nodes alive for as long as the
  // node (and the server) exists. A `NativeCallable` must not be garbage
  // collected while open62541 still holds its function pointer; it is closed
  // when the owning node is deleted ([deleteNode]) or the server is torn down
  // ([delete]). Keyed by the method node's NodeId.
  final Map<NodeId, ffi.NativeCallable> _methodCallbacks = {};

  /// Releases the UTF-8 identifier buffer that [NodeId.toRaw] allocates (via
  /// `ua_malloc`) for a **string** NodeId. Numeric NodeIds own no heap memory,
  /// so this is a no-op for them.
  ///
  /// open62541's `UA_Server_add*Node` / `addReference` / `deleteNode` /
  /// `readValue` / `writeValue` / `writeDescription` / `findDataType` APIs all
  /// take their `UA_NodeId` arguments **by value** and either deep-copy them
  /// into the node or use them only transiently for a lookup; none retain the
  /// caller's pointer past the call. It is therefore safe to free the raw
  /// NodeId once such a call has returned. Do NOT call this on a NodeId that was
  /// stored into a struct with its own clean-up (e.g. a `*Attributes.dataType`
  /// field freed by `UA_*Attributes_delete`, or a `UA_DataType.typeId` cleared
  /// by open62541's config teardown) — that would double-free.
  void _freeRawNodeId(raw.UA_NodeId rawNodeId) {
    if (rawNodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      final data = rawNodeId.identifier.string.data;
      if (data != ffi.nullptr) {
        ua_malloc.free(data);
      }
    }
  }

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

    final variableNodeIdRaw = variableNodeId.toRaw();
    final parentNodeIdRaw = parentNodeId.toRaw();
    final parentReferenceNodeIdRaw = parentReferenceNodeId.toRaw();
    final baseDataVariableTypeRaw = baseDataVariableType.toRaw();

    var returnCode = raw.UA_Server_addVariableNode(
      _server,
      variableNodeIdRaw,
      parentNodeIdRaw,
      parentReferenceNodeIdRaw,
      name,
      baseDataVariableTypeRaw,
      attr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );
    // open62541 deep-copied the NodeId arguments; free our copies. The
    // `attr.ref.dataType` NodeId is owned by `attr` and released by
    // `UA_VariableAttributes_delete` below, so it is not freed here.
    _freeRawNodeId(variableNodeIdRaw);
    _freeRawNodeId(parentNodeIdRaw);
    _freeRawNodeId(parentReferenceNodeIdRaw);
    _freeRawNodeId(baseDataVariableTypeRaw);
    raw.UA_VariableAttributes_delete(attr);
    ua_calloc.free(variant);
    if (returnCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable node ${statusCodeToString(returnCode)}, nodeId: $variableNodeId';
    }
  }

  /// Lazily creates the shared native read/write dispatchers used by every
  /// data-source variable node on this server. See [addDataSourceVariableNode].
  void _ensureDataSourceDispatchers() {
    if (_dsReadDispatcher != null) return;

    // Read: invoked by the server (inside runIterate, on this isolate) whenever
    // a client reads the node's value. It looks up the per-node [onRead], asks
    // it for the live value, and copies that into the outgoing UA_DataValue.
    int readCb(
      ffi.Pointer<raw.UA_Server> server,
      ffi.Pointer<raw.UA_NodeId> sessionId,
      ffi.Pointer<ffi.Void> sessionContext,
      ffi.Pointer<raw.UA_NodeId> nodeId,
      ffi.Pointer<ffi.Void> nodeContext,
      bool includeSourceTimeStamp,
      ffi.Pointer<raw.UA_NumericRange> range,
      ffi.Pointer<raw.UA_DataValue> value,
    ) {
      ffi.Pointer<raw.UA_Variant>? srcVar;
      try {
        final handler = _dataSourceReads[nodeId.ref.toNodeId()];
        if (handler == null) {
          return raw.UA_STATUSCODE_BADNODEIDUNKNOWN;
        }
        // Index-range reads are rejected. open62541 forwards the parsed range
        // to a callback value source and does NOT apply it afterwards, so
        // ignoring it here would return the FULL value with status Good for a
        // request like `arr[1:2]` - silently wrong data.
        if (range != ffi.nullptr && range.ref.dimensionsSize > 0) {
          return raw.UA_STATUSCODE_BADINDEXRANGEINVALID;
        }
        // onRead is synchronous and may throw; a throw surfaces to the client
        // as a Bad status rather than crashing the isolate.
        final dyn = handler();
        srcVar = valueToVariant(dyn);
        // UA_Variant is the first member of UA_DataValue, so a UA_DataValue*
        // cast to UA_Variant* points at the inline `value` field. Deep-copy the
        // freshly built variant into it (the server owns/frees it afterwards).
        final status = raw.UA_Variant_copy(srcVar, value.cast<raw.UA_Variant>());
        if (status != raw.UA_STATUSCODE_GOOD) {
          return status;
        }
        // Flag hasValue (bit 0 of the UA_DataValue bitfield byte).
        value.ref.substitute = value.ref.substitute | 0x01;
        return raw.UA_STATUSCODE_GOOD;
      } catch (_) {
        return raw.UA_STATUSCODE_BADINTERNALERROR;
      } finally {
        if (srcVar != null) {
          raw.UA_Variant_delete(srcVar);
        }
      }
    }

    // Write: invoked when a client writes the node. Marshals the incoming
    // UA_DataValue's variant to a DynamicValue and hands it to the per-node
    // [onWrite]. Nodes without an onWrite never register here (and are created
    // read-only), so a missing handler is defensive only.
    int writeCb(
      ffi.Pointer<raw.UA_Server> server,
      ffi.Pointer<raw.UA_NodeId> sessionId,
      ffi.Pointer<ffi.Void> sessionContext,
      ffi.Pointer<raw.UA_NodeId> nodeId,
      ffi.Pointer<ffi.Void> nodeContext,
      ffi.Pointer<raw.UA_NumericRange> range,
      ffi.Pointer<raw.UA_DataValue> value,
    ) {
      try {
        final nid = nodeId.ref.toNodeId();
        final handler = _dataSourceWrites[nid];
        if (handler == null) {
          return raw.UA_STATUSCODE_BADWRITENOTSUPPORTED;
        }
        // Index-range writes are rejected (mirroring the read dispatcher):
        // accepting one would hand [onWrite] the sub-array as if it were the
        // whole value, silently replacing the entire node value.
        if (range != ffi.nullptr && range.ref.dimensionsSize > 0) {
          return raw.UA_STATUSCODE_BADINDEXRANGEINVALID;
        }
        // Same first-field aliasing trick as the read path.
        final variant = value.cast<raw.UA_Variant>().ref;
        // A client writes a structured value as a binary-encoded
        // ExtensionObject (typeKind EXTENSIONOBJECT), not a native struct. To
        // restore its typed fields we must decode against the registered schema:
        // pass the node's declared DataType as `dataTypeId` and the local schema
        // registry as `defs`. Scalars (whose typeId maps to a known payload
        // type, or nodes created without a typeId) take the plain decode path,
        // preserving the previous behaviour. See [addCustomType] /
        // [OpcUaDynamicValueSerializer.localSchemas].
        final structType = _dataSourceTypeIds[nid];
        final DynamicValue dyn;
        if (structType != null && OpcUaDynamicValueSerializer.localSchemas.containsKey(structType)) {
          dyn = variantToValue(variant, defs: OpcUaDynamicValueSerializer.localSchemas, dataTypeId: structType);
        } else {
          dyn = variantToValue(variant);
        }
        handler(dyn);
        return raw.UA_STATUSCODE_GOOD;
      } catch (_) {
        return raw.UA_STATUSCODE_BADINTERNALERROR;
      }
    }

    _dsReadDispatcher =
        ffi.NativeCallable<
          raw.UA_StatusCode Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Bool,
            ffi.Pointer<raw.UA_NumericRange>,
            ffi.Pointer<raw.UA_DataValue>,
          )
        >.isolateLocal(readCb, exceptionalReturn: raw.UA_STATUSCODE_BADINTERNALERROR);
    _dsWriteDispatcher =
        ffi.NativeCallable<
          raw.UA_StatusCode Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NumericRange>,
            ffi.Pointer<raw.UA_DataValue>,
          )
        >.isolateLocal(writeCb, exceptionalReturn: raw.UA_STATUSCODE_BADINTERNALERROR);
  }

  /// Adds a variable node whose value is sourced live from a Dart callback.
  ///
  /// Unlike [addVariableNode] (which stores a static value in the address
  /// space), the value of a data-source node is produced on demand: every time
  /// a client reads the node, [onRead] is invoked and its returned
  /// [DynamicValue] is sent to the client. This makes the server usable as a
  /// proxy / data-source that bridges live external state (e.g. a PLC tag).
  ///
  /// * [onRead] is **synchronous** and returns the current value. It fires
  ///   inside the server's `runIterate` on the calling isolate, so it cannot
  ///   `await`. If it throws, the client read fails with a Bad status
  ///   (`BadInternalError`) — the isolate is never crashed.
  /// * [onWrite] (optional) receives the [DynamicValue] a client wrote. Passing
  ///   `null` makes the node read-only: the node is created without the Write
  ///   access bit, so client writes are rejected with `BadNotWritable`. When
  ///   [onWrite] throws, the write fails with `BadInternalError`. `void` return
  ///   semantics (throw-for-bad) are used rather than an `int` status code to
  ///   keep the surface pure-Dart and mirror [onRead]'s throw behaviour.
  /// * [accessLevel] defaults to read + (write iff [onWrite] != null). Pass a
  ///   value to override (e.g. to expose a writable node whose backing store is
  ///   currently read-only).
  /// * [typeId] sets the node's DataType attribute (and marks it scalar) so
  ///   browsing clients see the correct type; when omitted the node keeps
  ///   open62541's permissive defaults.
  ///
  /// The value marshalling reuses `valueToVariant`/`variantToValue`, so scalar
  /// numeric/bool/string types work directly. Custom **structured** types are
  /// also supported end to end: pass the struct's DataType as [typeId] (after
  /// registering it with [addCustomType] + [addDataTypeNode]) and return a
  /// struct-valued [DynamicValue] from [onRead]. A client read then decodes it
  /// as a structured value, and a client write is decoded back into a
  /// struct-valued [DynamicValue] (its typed fields restored from the registered
  /// schema) before [onWrite] receives it.
  ///
  /// **Index ranges are not supported.** A client read or write that specifies
  /// an index range (e.g. `arr[1:2]`) is rejected with `BadIndexRangeInvalid`:
  /// open62541 forwards the range to the value-source callbacks without
  /// applying it itself, and the callbacks always produce/consume the complete
  /// value, so honouring the request silently would return (or overwrite) the
  /// full value instead of the requested slice.
  void addDataSourceVariableNode(
    NodeId nodeId, {
    required DynamicValue Function() onRead,
    void Function(DynamicValue value)? onWrite,
    required String browseName,
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    NodeId? baseDataVariableType,
    NodeId? typeId,
    AccessLevelMask? accessLevel,
  }) {
    _ensureDataSourceDispatchers();

    final effectiveAccess = accessLevel ?? AccessLevelMask(read: true, write: onWrite != null);

    // 1) Create a plain variable node (no stored value). Its value comes from
    //    the callback source attached in step 2.
    final attr = raw.UA_VariableAttributes_new();
    attr.ref = raw.UA_VariableAttributes_default;
    attr.ref.accessLevel = effectiveAccess.value;
    if (typeId != null) {
      // Owned by `attr`; released by UA_VariableAttributes_delete below.
      attr.ref.dataType = typeId.toRaw();
      attr.ref.valueRank = raw.UA_VALUERANK_SCALAR;
    }

    final name = raw.UA_QUALIFIEDNAME(1, browseName.toNativeUtf8(allocator: ua_malloc).cast());

    final resolvedParent = parentNodeId ?? NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    final resolvedRef = parentReferenceNodeId ?? NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES);
    final resolvedType = baseDataVariableType ?? NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE);

    final nodeIdRaw = nodeId.toRaw();
    final parentRaw = resolvedParent.toRaw();
    final refRaw = resolvedRef.toRaw();
    final typeRaw = resolvedType.toRaw();

    final addStatus = raw.UA_Server_addVariableNode(
      _server,
      nodeIdRaw,
      parentRaw,
      refRaw,
      name,
      typeRaw,
      attr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );
    _freeRawNodeId(nodeIdRaw);
    _freeRawNodeId(parentRaw);
    _freeRawNodeId(refRaw);
    _freeRawNodeId(typeRaw);
    raw.UA_VariableAttributes_delete(attr);
    if (addStatus != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add data source variable node ${statusCodeToString(addStatus)}, nodeId: $nodeId';
    }

    // 2) Attach the callback value source. The struct is passed by value; the
    //    server copies the two function pointers, so the temporary can be freed
    //    immediately. The NativeCallables themselves outlive this call (they are
    //    server fields, closed in [delete]).
    final source = ua_calloc<raw.UA_CallbackValueSource>();
    source.ref.read = _dsReadDispatcher!.nativeFunction;
    source.ref.write = onWrite != null ? _dsWriteDispatcher!.nativeFunction : ffi.nullptr;
    final setNodeIdRaw = nodeId.toRaw();
    final setStatus = raw.UA_Server_setVariableNode_callbackValueSource(_server, setNodeIdRaw, source.ref);
    _freeRawNodeId(setNodeIdRaw);
    ua_calloc.free(source);
    if (setStatus != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to attach data source ${statusCodeToString(setStatus)}, nodeId: $nodeId';
    }

    // 3) Register the Dart handlers only once BOTH native calls succeeded.
    //    Requests are dispatched from runIterate on this isolate, so no client
    //    read/write can race the registration between steps 1-3. Installing the
    //    entries earlier (and removing them again on failure) would let a failed
    //    duplicate add - e.g. BadNodeIdExists for a NodeId that already has a
    //    data source - wipe the EXISTING node's live handlers and schema.
    _dataSourceReads[nodeId] = onRead;
    if (onWrite != null) {
      _dataSourceWrites[nodeId] = onWrite;
    }
    if (typeId != null) {
      _dataSourceTypeIds[nodeId] = typeId;
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

    final variableTypeIdRaw = variableTypeId.toRaw();
    final parentNodeIdRaw = parentNodeId.toRaw();
    final referenceTypeIdRaw = referenceTypeId.toRaw();
    final qualifiedName = raw.UA_QUALIFIEDNAME(1, name.toNativeUtf8(allocator: ua_malloc).cast());

    int res = raw.UA_Server_addVariableTypeNode(
      _server,
      variableTypeIdRaw,
      parentNodeIdRaw,
      referenceTypeIdRaw,
      qualifiedName,
      parentNodeIdRaw,
      dattr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );

    // open62541 deep-copied the NodeId arguments; free our copies. The
    // `dattr.ref.dataType` NodeId is owned by `dattr` and released by
    // `UA_VariableTypeAttributes_delete` below.
    _freeRawNodeId(variableTypeIdRaw);
    _freeRawNodeId(parentNodeIdRaw);
    _freeRawNodeId(referenceTypeIdRaw);
    raw.UA_Variant_delete(variant);
    raw.UA_VariableTypeAttributes_delete(dattr);

    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add variable type node ${statusCodeToString(res)}';
    }
  }

  /// Registers an application namespace [uri] and returns its namespace index.
  ///
  /// The returned index can then be used to create nodes in that namespace
  /// instead of the default application namespace (`ns=1`), e.g.
  /// ```dart
  /// final ns = server.addNamespace('urn:test:bridge');
  /// server.addVariableNode(NodeId.fromString(ns, 'x'), value);
  /// ```
  /// open62541 does not duplicate namespaces: registering a [uri] that is
  /// already present returns its existing index. The namespace array is
  /// 0-based, so a freshly added application namespace has an index `>= 2`
  /// (index 0 is the OPC UA namespace, index 1 the local application URI).
  int addNamespace(String uri) {
    final cstr = uri.toNativeUtf8(allocator: ua_malloc);
    // open62541 copies the name into its namespace array (UA_String_fromChars),
    // so the temporary C string can be freed immediately after the call.
    final index = raw.UA_Server_addNamespace(_server, cstr.cast());
    ua_malloc.free(cstr);
    return index;
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

  /// Adds a callable method node to the server's address space.
  ///
  /// When a client calls the method (see `ClientApi.call`), open62541 invokes
  /// [callback] synchronously on this isolate from within [runIterate]. The
  /// request's input variants are marshalled into a list of [DynamicValue]s and
  /// passed to [callback]; the [DynamicValue]s it returns are marshalled back
  /// into the method's output variants. Because the callback runs inside the
  /// server's single-threaded iterate step it must be synchronous — it cannot
  /// `await`.
  ///
  /// Each returned [DynamicValue] must carry a [DynamicValue.typeId] so it can
  /// be encoded (e.g. `DynamicValue(value: 42, typeId: NodeId.int32)`). If the
  /// callback throws, the caller receives a `Bad` status
  /// (`UA_STATUSCODE_BADINTERNALERROR`) and the isolate is not disturbed.
  ///
  /// Required parameters:
  /// * [methodNodeId] - The unique identifier for the new method node.
  /// * [callback] - The Dart function invoked when a client calls the method.
  ///
  /// Optional parameters:
  /// * [inputArguments] / [outputArguments] - describe the method's signature.
  /// * [parentNodeId] - The parent node (defaults to the Objects folder). This
  ///   is the object a client passes as the `objectId` when calling.
  /// * [parentReferenceNodeId] - The reference type to the parent (defaults to
  ///   HasComponent).
  /// * [browseName] - The browse/display name (defaults to the method node's
  ///   string identifier; required if [methodNodeId] is numeric).
  void addMethodNode(
    NodeId methodNodeId, {
    required List<DynamicValue> Function(List<DynamicValue> inputs) callback,
    List<Argument> inputArguments = const [],
    List<Argument> outputArguments = const [],
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    String? browseName,
  }) {
    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    parentReferenceNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_HASCOMPONENT);
    if (browseName == null) {
      if (!methodNodeId.isString()) {
        throw 'A browseName must be provided for a method node with a numeric NodeId';
      }
      browseName = methodNodeId.string;
    }

    // Method attributes. calloc zero-initializes; open62541's high-level
    // addMethodNode uses the struct directly (no attribute-mask filtering), so
    // we only set the fields we care about.
    final attr = ua_calloc<raw.UA_MethodAttributes>();
    attr.ref.displayName.text.set(browseName);
    attr.ref.executable = true;
    attr.ref.userExecutable = true;

    final inputArgsPtr = _buildArguments(inputArguments);
    final outputArgsPtr = _buildArguments(outputArguments);

    // The native method callback. isolateLocal: it runs on this isolate,
    // synchronously, from within runIterate.
    final nativeCallback =
        ffi.NativeCallable<
          raw.UA_StatusCode Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Size,
            ffi.Pointer<raw.UA_Variant>,
            ffi.Size,
            ffi.Pointer<raw.UA_Variant>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Server> server,
          ffi.Pointer<raw.UA_NodeId> sessionId,
          ffi.Pointer<ffi.Void> sessionContext,
          ffi.Pointer<raw.UA_NodeId> methodId,
          ffi.Pointer<ffi.Void> methodContext,
          ffi.Pointer<raw.UA_NodeId> objectId,
          ffi.Pointer<ffi.Void> objectContext,
          int inputSize,
          ffi.Pointer<raw.UA_Variant> input,
          int outputSize,
          ffi.Pointer<raw.UA_Variant> output,
        ) {
          try {
            final inputs = <DynamicValue>[];
            for (var i = 0; i < inputSize; i++) {
              inputs.add(variantToValue(input[i]));
            }

            final results = callback(inputs);

            // Marshal each result into the corresponding output variant. Deep
            // copy into open62541-owned memory, then free our temporary.
            for (var i = 0; i < results.length && i < outputSize; i++) {
              final variantPtr = valueToVariant(results[i]);
              raw.UA_Variant_copy(variantPtr, output + i);
              raw.UA_Variant_delete(variantPtr);
            }

            return raw.UA_STATUSCODE_GOOD;
          } catch (_) {
            // Never let a Dart exception unwind into native code; report a Bad
            // status to the caller instead.
            return raw.UA_STATUSCODE_BADINTERNALERROR;
          }
        }, exceptionalReturn: raw.UA_STATUSCODE_BADINTERNALERROR);

    final browse = raw.UA_QUALIFIEDNAME(1, browseName.toNativeUtf8(allocator: ua_malloc).cast());

    final methodNodeIdRaw = methodNodeId.toRaw();
    final parentNodeIdRaw = parentNodeId.toRaw();
    final parentReferenceNodeIdRaw = parentReferenceNodeId.toRaw();

    final retCode = raw.UA_Server_addMethodNode(
      _server,
      methodNodeIdRaw,
      parentNodeIdRaw,
      parentReferenceNodeIdRaw,
      browse,
      attr.ref,
      nativeCallback.nativeFunction,
      inputArguments.length,
      inputArgsPtr,
      outputArguments.length,
      outputArgsPtr,
      ffi.nullptr,
      ffi.nullptr,
    );

    // open62541 has deep-copied the attributes, argument arrays and NodeId
    // arguments into the node; release our copies.
    _freeRawNodeId(methodNodeIdRaw);
    _freeRawNodeId(parentNodeIdRaw);
    _freeRawNodeId(parentReferenceNodeIdRaw);
    _freeArguments(inputArgsPtr, inputArguments.length);
    _freeArguments(outputArgsPtr, outputArguments.length);
    attr.ref.displayName.text.free();
    ua_calloc.free(attr);

    if (retCode != raw.UA_STATUSCODE_GOOD) {
      nativeCallback.close();
      throw 'Failed to add method node ${statusCodeToString(retCode)}, nodeId: $methodNodeId';
    }

    // Keep the callback alive for the lifetime of the node.
    _methodCallbacks[methodNodeId] = nativeCallback;
  }

  /// Allocates and populates a native `UA_Argument` array from [args].
  /// Returns `nullptr` for an empty list.
  ffi.Pointer<raw.UA_Argument> _buildArguments(List<Argument> args) {
    if (args.isEmpty) return ffi.nullptr;
    final ptr = ua_calloc<raw.UA_Argument>(args.length);
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      (ptr + i).ref.name.set(a.name);
      (ptr + i).ref.dataType = a.dataType.toRaw();
      (ptr + i).ref.valueRank = a.valueRank;
      final description = a.description;
      if (description != null) {
        (ptr + i).ref.description.locale.set(description.locale);
        (ptr + i).ref.description.text.set(description.value);
      }
      if (a.arrayDimensions.isNotEmpty) {
        final dims = ua_calloc<ffi.Uint32>(a.arrayDimensions.length);
        dims.asTypedList(a.arrayDimensions.length).setRange(0, a.arrayDimensions.length, a.arrayDimensions);
        (ptr + i).ref.arrayDimensions = dims;
        (ptr + i).ref.arrayDimensionsSize = a.arrayDimensions.length;
      }
    }
    return ptr;
  }

  /// Frees the strings/arrays allocated by [_buildArguments] and the array
  /// itself.
  void _freeArguments(ffi.Pointer<raw.UA_Argument> ptr, int length) {
    if (ptr == ffi.nullptr) return;
    for (var i = 0; i < length; i++) {
      (ptr + i).ref.name.free();
      // The dataType NodeId's string identifier (if any) was allocated by
      // NodeId.toRaw(); open62541 has copied it into the node, so free ours.
      _freeRawNodeId((ptr + i).ref.dataType);
      (ptr + i).ref.description.locale.free();
      (ptr + i).ref.description.text.free();
      if ((ptr + i).ref.arrayDimensions != ffi.nullptr) {
        ua_calloc.free((ptr + i).ref.arrayDimensions);
      }
    }
    ua_calloc.free(ptr);
  }

  /// Adds a generic Object node to the server's address space.
  ///
  /// Object nodes are the containers used to build an address-space hierarchy
  /// (for example to mirror a PLC symbol tree). Use [addFolderNode] for the
  /// common `FolderType` case.
  ///
  /// Required parameters:
  /// * [nodeId] - The unique identifier for the new object node.
  ///
  /// Optional parameters:
  /// * [browseName] - The BrowseName (defaults to [displayName], else empty).
  /// * [displayName] - The human-readable DisplayName (defaults to [browseName]).
  /// * [parentNodeId] - The parent node (defaults to the Objects folder).
  /// * [parentReferenceNodeId] - The reference type to the parent (defaults to
  ///   Organizes).
  /// * [typeDefinition] - The object's TypeDefinition (defaults to
  ///   BaseObjectType).
  ///
  /// Throws an exception if the server fails to add the node.
  ///
  /// Example:
  /// ```dart
  /// final tank = NodeId.fromString(1, "tank.1");
  /// server.addObjectNode(tank, browseName: "Tank1", displayName: "Tank 1");
  /// ```
  void addObjectNode(
    NodeId nodeId, {
    String? browseName,
    String? displayName,
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    NodeId? typeDefinition,
  }) {
    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    parentReferenceNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES);
    typeDefinition ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEOBJECTTYPE);

    final effectiveBrowseName = browseName ?? displayName ?? '';
    final effectiveDisplayName = displayName ?? browseName ?? '';

    final attr = raw.UA_ObjectAttributes_new();
    attr.ref = raw.UA_ObjectAttributes_default;
    if (effectiveDisplayName.isNotEmpty) {
      attr.ref.displayName.text.set(effectiveDisplayName);
    }

    _addNode(
      raw.UA_NodeClass.UA_NODECLASS_OBJECT,
      nodeId,
      parentNodeId,
      parentReferenceNodeId,
      effectiveBrowseName,
      typeDefinition,
      attr.cast(),
      getType(UaTypes.objectAttributes),
    );

    raw.UA_ObjectAttributes_delete(attr);
  }

  /// Adds an Object node of type `FolderType` - a convenience over
  /// [addObjectNode].
  ///
  /// Folders are the idiomatic way to group nodes in the address space.
  ///
  /// Required parameters:
  /// * [nodeId] - The unique identifier for the new folder node.
  /// * [name] - The BrowseName for the folder (also used as the default
  ///   DisplayName).
  ///
  /// Optional parameters:
  /// * [displayName] - The DisplayName (defaults to [name]).
  /// * [parentNodeId] - The parent node (defaults to the Objects folder).
  /// * [parentReferenceNodeId] - The reference type to the parent (defaults to
  ///   Organizes).
  ///
  /// Throws an exception if the server fails to add the node.
  ///
  /// Example:
  /// ```dart
  /// server.addFolderNode(NodeId.fromString(1, "plc"), "PLC");
  /// ```
  void addFolderNode(
    NodeId nodeId,
    String name, {
    String? displayName,
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
  }) {
    addObjectNode(
      nodeId,
      browseName: name,
      displayName: displayName ?? name,
      parentNodeId: parentNodeId,
      parentReferenceNodeId: parentReferenceNodeId,
      typeDefinition: NodeId.fromNumeric(0, raw.UA_NS0ID_FOLDERTYPE),
    );
  }

  /// Deletes a node from the server's address space.
  ///
  /// Required parameters:
  /// * [nodeId] - The identifier of the node to remove.
  ///
  /// Optional parameters:
  /// * [deleteReferences] - When `true` (the default) references pointing to and
  ///   from the node are removed as well; when `false` only the node itself is
  ///   removed, leaving any dangling references.
  ///
  /// Any per-node native resources this server holds for [nodeId] are released:
  /// a method node's backing [ffi.NativeCallable] (from [addMethodNode]) is
  /// closed, and any data-source read/write handlers (from
  /// [addDataSourceVariableNode]) are dropped.
  ///
  /// Throws an exception if the server fails to delete the node.
  ///
  /// Example:
  /// ```dart
  /// server.deleteNode(NodeId.fromString(1, "the.int"));
  /// ```
  void deleteNode(NodeId nodeId, {bool deleteReferences = true}) {
    final nodeIdRaw = nodeId.toRaw();
    final code = raw.UA_Server_deleteNode(_server, nodeIdRaw, deleteReferences);
    _freeRawNodeId(nodeIdRaw);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to delete node ${statusCodeToString(code)}, nodeId: $nodeId';
    }
    // Release any native resources this server holds for the node.
    _methodCallbacks.remove(nodeId)?.close();
    _dataSourceReads.remove(nodeId);
    _dataSourceWrites.remove(nodeId);
    _dataSourceTypeIds.remove(nodeId);
    _valueChangeControllers.remove(nodeId)?.close();
  }

  /// Adds a reference between two nodes.
  ///
  /// Required parameters:
  /// * [sourceNodeId] - The node the reference originates from.
  /// * [referenceTypeId] - The reference type (e.g.
  ///   `NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES)`).
  /// * [targetNodeId] - The node the reference points to.
  ///
  /// Optional parameters:
  /// * [forward] - Reference direction; `true` (the default) adds a forward
  ///   reference from source to target, `false` adds an inverse reference.
  ///
  /// Throws an exception if the server fails to add the reference.
  ///
  /// Example:
  /// ```dart
  /// server.addReference(
  ///   folderNodeId,
  ///   NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES),
  ///   variableNodeId,
  /// );
  /// ```
  void addReference(NodeId sourceNodeId, NodeId referenceTypeId, NodeId targetNodeId, {bool forward = true}) {
    final sourceRaw = sourceNodeId.toRaw();
    final referenceTypeRaw = referenceTypeId.toRaw();
    final target = ua_calloc<raw.UA_ExpandedNodeId>();
    target.ref.nodeId = targetNodeId.toRaw();

    final code = raw.UA_Server_addReference(_server, sourceRaw, referenceTypeRaw, target.ref, forward);
    // open62541 deep-copied all three NodeIds; free our copies (the target's
    // NodeId is nested inside the ExpandedNodeId).
    _freeRawNodeId(sourceRaw);
    _freeRawNodeId(referenceTypeRaw);
    _freeRawNodeId(target.ref.nodeId);
    ua_calloc.free(target);

    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add reference ${statusCodeToString(code)}, source: $sourceNodeId, target: $targetNodeId';
    }
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

    final requestedRaw = requestedNewNodeId.toRaw();
    final parentRaw = parentNodeId.toRaw();
    final referenceRaw = referenceTypeId.toRaw();
    final typeDefinitionRaw = typeDefinition.toRaw();

    try {
      //TODO: It seems this method has been removed.
      var retCode = raw.UA_Server_addNode_begin(
        _server,
        nodeClass,
        requestedRaw,
        parentRaw,
        referenceRaw,
        browse,
        typeDefinitionRaw,
        attr.cast(),
        attributeType,
        ffi.nullptr,
        ffi.nullptr,
      );

      if (retCode != raw.UA_STATUSCODE_GOOD) {
        throw 'Failed to add node begin ${statusCodeToString(retCode)}';
      }

      retCode = raw.UA_Server_addNode_finish(_server, requestedRaw);

      if (retCode != raw.UA_STATUSCODE_GOOD) {
        throw 'Failed to add node finish ${statusCodeToString(retCode)}';
      }
    } finally {
      // open62541 deep-copied the NodeId arguments (both begin and finish use
      // copies); free ours whether or not the calls succeeded.
      _freeRawNodeId(requestedRaw);
      _freeRawNodeId(parentRaw);
      _freeRawNodeId(referenceRaw);
      _freeRawNodeId(typeDefinitionRaw);
    }
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
    final variableNodeIdRaw = variableNodeId.toRaw();
    raw.UA_Server_writeDescription(_server, variableNodeIdRaw, descriptionRaw.ref);
    // writeDescription uses the NodeId transiently for a lookup; free ours.
    _freeRawNodeId(variableNodeIdRaw);
    raw.UA_LocalizedText_delete(descriptionRaw);
  }

  DynamicValue read(NodeId variableNodeId, {Schema? schema}) {
    final variant = raw.UA_Variant_new();
    final variableNodeIdRaw = variableNodeId.toRaw();
    raw.UA_Server_readValue(_server, variableNodeIdRaw, variant);
    // readValue uses the NodeId transiently for a lookup; free ours.
    _freeRawNodeId(variableNodeIdRaw);
    final value = variantToValue(variant.ref, defs: schema);
    raw.UA_Variant_delete(variant);
    return value;
  }

  void write(NodeId variableNodeId, DynamicValue value) {
    final variant = valueToVariant(value);
    final variableNodeIdRaw = variableNodeId.toRaw();
    raw.UA_Server_writeValue(_server, variableNodeIdRaw, variant.ref);
    // writeValue uses the NodeId transiently for a lookup; free ours.
    _freeRawNodeId(variableNodeIdRaw);
    raw.UA_Variant_delete(variant);
  }

  // populate structschema for out type
  void addCustomType(NodeId typeId, DynamicValue value) {
    if (!value.isObject) {
      throw 'Value must be a object';
    }

    // Already registered: keep the first registration (mirroring
    // [_addEnumType]'s reuse semantics). Without this guard a second call
    // would prepend a duplicate native type entry (identical typeId AND
    // encoding id) and silently overwrite the local schema, breaking the
    // decoding of writes against the original layout.
    if (_findDataType(typeId) != ffi.nullptr) {
      return;
    }

    final array = ua_calloc<raw.UA_DataTypeArray>();

    // Record the rich schema locally. open62541's generated DataTypeDefinition
    // cannot carry per-field descriptions / display names, so an in-process
    // client read restores them from here (see
    // OpcUaDynamicValueSerializer.overlayLocalFieldMetadata).
    OpcUaDynamicValueSerializer.registerLocalSchema(typeId, value);
    array.ref.typesSize = 1;
    array.ref.types = ua_calloc<raw.UA_DataType>(1);
    array.ref.types[0].typeId = typeId.toRaw();
    // Derive the DefaultBinary DataTypeEncoding NodeId from the typeId, which
    // is unique by construction. Deriving it from `value.name` (as done
    // previously) collides for same-namespace types with a null or duplicate
    // name - e.g. nested auto-registered schemas - and open62541 resolves an
    // incoming ExtensionObject by the FIRST type whose encoding id matches, so
    // colliding ids made client writes decode against the wrong schema. Keep
    // this derivation stable: it is part of the wire contract for this type.
    array.ref.types[0].binaryEncodingId = NodeId.fromString(typeId.namespace, "BinaryEncoding_Default:$typeId").toRaw();

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
        // A struct-valued member is itself a structured DataType. Register its
        // encoding type AND publish its DataType node (a HasSubtype child of
        // Structure). A dynamic client decodes the outer struct by resolving
        // each field type's DataTypeDefinition over the wire, so every nested
        // type in the transitive closure must exist as a node — otherwise the
        // read fails BadNodeIdUnknown even though writes (which decode against
        // the local schema) succeed. The `_findDataType == null` guard fires
        // once per type, so a type shared by several parents is published
        // exactly once. Mirrors what _addEnumType already does for enums.
        addCustomType(member.typeId!, member);
        addDataTypeNode(member.typeId!, member.name ?? memberName);
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
    // findDataType only reads the NodeId; free the string identifier buffer
    // toRaw() allocated before releasing the container.
    _freeRawNodeId(nodeId.ref);
    ua_calloc.free(nodeId);
    return ret;
  }

  // ---- PubSub (OPC UA Part 14) ---------------------------------------------
  //
  // PubSub components hang off the *server* on both sides: the publisher
  // (PubSubConnection -> WriterGroup -> DataSetWriter, fed by a
  // PublishedDataSet) and the subscriber (PubSubConnection -> ReaderGroup ->
  // DataSetReader, writing into local target variable nodes). All components
  // are created disabled; call [enableAllPubSubComponents] once the topology is
  // complete. The PubSub state machines are driven from [runIterate], so the
  // usual iterate loop must keep running for messages to be sent/received.

  /// Fills the native tagged-union [dst] from [id]. A string id allocates the
  /// identifier bytes; release them with [_clearRawPublisherId] after the
  /// config has been deep-copied by open62541.
  void _fillRawPublisherId(raw.UA_PublisherId dst, PubSubPublisherId id) {
    switch (id.type) {
      case PubSubPublisherIdType.byte:
        dst.idTypeAsInt = raw.UA_PublisherIdType.UA_PUBLISHERIDTYPE_BYTE.value;
        dst.id.byte = id.numeric!;
      case PubSubPublisherIdType.uint16:
        dst.idTypeAsInt = raw.UA_PublisherIdType.UA_PUBLISHERIDTYPE_UINT16.value;
        dst.id.uint16 = id.numeric!;
      case PubSubPublisherIdType.uint32:
        dst.idTypeAsInt = raw.UA_PublisherIdType.UA_PUBLISHERIDTYPE_UINT32.value;
        dst.id.uint32 = id.numeric!;
      case PubSubPublisherIdType.uint64:
        dst.idTypeAsInt = raw.UA_PublisherIdType.UA_PUBLISHERIDTYPE_UINT64.value;
        dst.id.uint64 = id.numeric!;
      case PubSubPublisherIdType.string:
        dst.idTypeAsInt = raw.UA_PublisherIdType.UA_PUBLISHERIDTYPE_STRING.value;
        dst.id.string.set(id.string!);
    }
  }

  void _clearRawPublisherId(raw.UA_PublisherId dst, PubSubPublisherId id) {
    if (id.type == PubSubPublisherIdType.string) {
      dst.id.string.free();
    }
  }

  /// Converts the component NodeId open62541 wrote into [out] to a [NodeId]
  /// and releases the native copy.
  NodeId _takeOutNodeId(ffi.Pointer<raw.UA_NodeId> out) {
    final nodeId = out.ref.toNodeId();
    _freeRawNodeId(out.ref);
    ua_calloc.free(out);
    return nodeId;
  }

  /// Adds a PubSubConnection - the binding between a transport (UDP + UADP by
  /// default) and the PubSub machinery. Both WriterGroups (publisher side) and
  /// ReaderGroups (subscriber side) are created below a connection.
  ///
  /// Required parameters:
  /// * [name] - Component name (shown in the information model / logs).
  /// * [url] - The network address URL, e.g. `opc.udp://224.0.0.22:4840/` for
  ///   UDP multicast.
  ///
  /// Optional parameters:
  /// * [publisherId] - The PublisherId stamped into outgoing NetworkMessages
  ///   and matched by DataSetReaders (defaults to `PubSubPublisherId.byte(1)`,
  ///   mirroring open62541's default id type).
  /// * [networkInterface] - The local interface to bind (name or IP address).
  /// * [transportProfileUri] - The transport profile (defaults to UDP UADP,
  ///   [pubSubTransportUdpUadp]).
  ///
  /// Returns the NodeId identifying the new connection; pass it to
  /// [addWriterGroup] / [addReaderGroup]. The connection starts disabled - see
  /// [enableAllPubSubComponents].
  ///
  /// Throws an exception if the server rejects the connection configuration.
  NodeId addPubSubConnection({
    required String name,
    required String url,
    PubSubPublisherId publisherId = const PubSubPublisherId.byte(1),
    String? networkInterface,
    String transportProfileUri = pubSubTransportUdpUadp,
  }) {
    final config = ua_calloc<raw.UA_PubSubConnectionConfig>();
    config.ref.name.set(name);
    config.ref.transportProfileUri.set(transportProfileUri);
    _fillRawPublisherId(config.ref.publisherId, publisherId);

    // The address is a variant holding a scalar UA_NetworkAddressUrlDataType.
    final address = ua_calloc<raw.UA_NetworkAddressUrlDataType>();
    address.ref.url.set(url);
    if (networkInterface != null) {
      address.ref.networkInterface.set(networkInterface);
    }
    config.ref.address.type = getTypeByIndex(raw.UA_TYPES_NETWORKADDRESSURLDATATYPE);
    config.ref.address.data = address.cast();

    final out = ua_calloc<raw.UA_NodeId>();
    final code = raw.UA_Server_addPubSubConnection(_server, config, out);

    // open62541 deep-copied the whole config; release our copies.
    address.ref.url.free();
    address.ref.networkInterface.free();
    ua_calloc.free(address);
    config.ref.name.free();
    config.ref.transportProfileUri.free();
    _clearRawPublisherId(config.ref.publisherId, publisherId);
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add PubSub connection ${statusCodeToString(code)}';
    }
    return nodeId;
  }

  /// Adds an (initially empty) PublishedDataSet - the container that collects
  /// the published fields. Add fields with [addDataSetField] and link the set
  /// to a WriterGroup with [addDataSetWriter].
  ///
  /// Returns the NodeId identifying the new PublishedDataSet.
  ///
  /// Throws an exception if the server rejects the configuration.
  NodeId addPublishedDataSet({required String name}) {
    final config = ua_calloc<raw.UA_PublishedDataSetConfig>();
    config.ref.name.set(name);
    config.ref.publishedDataSetTypeAsInt = raw.UA_PublishedDataSetType.UA_PUBSUB_DATASET_PUBLISHEDITEMS.value;

    final out = ua_calloc<raw.UA_NodeId>();
    final result = raw.UA_Server_addPublishedDataSet(_server, config, out);

    config.ref.name.free();
    ua_calloc.free(config);
    // The by-value result owns an (empty for PUBLISHEDITEMS) field-result
    // array allocated by open62541's malloc; release it if present. Guard the
    // empty-array sentinel (0x1), which must never be freed.
    if (result.fieldAddResults != ffi.nullptr && result.fieldAddResults.address != 0x1) {
      ua_malloc.free(result.fieldAddResults);
    }

    final nodeId = _takeOutNodeId(out);
    if (result.addResult != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add PublishedDataSet ${statusCodeToString(result.addResult)}';
    }
    return nodeId;
  }

  /// Adds a DataSetField to the PublishedDataSet [publishedDataSet]: the value
  /// of the existing variable node [publishedVariable] is sampled and published
  /// as one field of every DataSetMessage.
  ///
  /// The field ORDER is significant: a DataSetReader decodes the message
  /// positionally against its DataSetMetaData, so add fields in the same order
  /// as the subscriber's [DataSetFieldMeta] list (see [addDataSetReader]).
  ///
  /// Required parameters:
  /// * [publishedDataSet] - The PublishedDataSet (from [addPublishedDataSet]).
  /// * [name] - The field name alias.
  /// * [publishedVariable] - The variable node whose Value attribute is
  ///   published.
  ///
  /// Returns the NodeId identifying the new DataSetField.
  ///
  /// Throws an exception if the server rejects the field (e.g. the variable
  /// node does not exist).
  NodeId addDataSetField(NodeId publishedDataSet, {required String name, required NodeId publishedVariable}) {
    final config = ua_calloc<raw.UA_DataSetFieldConfig>();
    config.ref.dataSetFieldTypeAsInt = raw.UA_DataSetFieldType.UA_PUBSUB_DATASETFIELD_VARIABLE.value;
    config.ref.field.variable.fieldNameAlias.set(name);
    config.ref.field.variable.promotedField = false;
    config.ref.field.variable.publishParameters.publishedVariable = publishedVariable.toRaw();
    config.ref.field.variable.publishParameters.attributeId = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE.value;

    final pdsRaw = publishedDataSet.toRaw();
    final out = ua_calloc<raw.UA_NodeId>();
    final result = raw.UA_Server_addDataSetField(_server, pdsRaw, config, out);

    _freeRawNodeId(pdsRaw);
    config.ref.field.variable.fieldNameAlias.free();
    _freeRawNodeId(config.ref.field.variable.publishParameters.publishedVariable);
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (result.result != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add DataSetField ${statusCodeToString(result.result)}, variable: $publishedVariable';
    }
    return nodeId;
  }

  /// Adds a WriterGroup below the PubSubConnection [connection]. The
  /// WriterGroup produces one NetworkMessage per [publishingInterval],
  /// containing the DataSetMessages of its DataSetWriters.
  ///
  /// The group's UADP message settings default to sending the PublisherId,
  /// GroupHeader/WriterGroupId and PayloadHeader
  /// ([uadpDefaultNetworkMessageContentMask]) so that a subscriber can match
  /// messages on (publisherId, writerGroupId, dataSetWriterId).
  ///
  /// Required parameters:
  /// * [connection] - The PubSubConnection (from [addPubSubConnection]).
  /// * [name] - Component name.
  /// * [writerGroupId] - The group id stamped into the NetworkMessages; a
  ///   matching DataSetReader must be configured with the same id.
  ///
  /// Optional parameters:
  /// * [publishingInterval] - The publish cycle (defaults to 100 ms).
  /// * [keepAliveTime] - Interval for keep-alive messages when nothing was
  ///   published (defaults to open62541's default when omitted).
  ///
  /// Returns the NodeId identifying the new WriterGroup.
  ///
  /// Throws an exception if the server rejects the configuration.
  NodeId addWriterGroup(
    NodeId connection, {
    required String name,
    required int writerGroupId,
    Duration publishingInterval = const Duration(milliseconds: 100),
    Duration? keepAliveTime,
  }) {
    final config = ua_calloc<raw.UA_WriterGroupConfig>();
    config.ref.name.set(name);
    config.ref.writerGroupId = writerGroupId;
    config.ref.publishingInterval = publishingInterval.inMicroseconds / 1000.0;
    if (keepAliveTime != null) {
      config.ref.keepAliveTime = keepAliveTime.inMicroseconds / 1000.0;
    }
    config.ref.encodingMimeTypeAsInt = raw.UA_PubSubEncodingType.UA_PUBSUB_ENCODING_UADP.value;

    // UADP message settings: a decoded ExtensionObject holding a
    // UA_UadpWriterGroupMessageDataType. Deep-copied with the config, so the
    // temporary is freed right after the call.
    final message = ua_calloc<raw.UA_UadpWriterGroupMessageDataType>();
    message.ref.networkMessageContentMask = uadpDefaultNetworkMessageContentMask;
    config.ref.messageSettings.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED.value;
    config.ref.messageSettings.content.decoded.type = getTypeByIndex(raw.UA_TYPES_UADPWRITERGROUPMESSAGEDATATYPE);
    config.ref.messageSettings.content.decoded.data = message.cast();

    final connectionRaw = connection.toRaw();
    final out = ua_calloc<raw.UA_NodeId>();
    final code = raw.UA_Server_addWriterGroup(_server, connectionRaw, config, out);

    _freeRawNodeId(connectionRaw);
    ua_calloc.free(message);
    config.ref.name.free();
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add WriterGroup ${statusCodeToString(code)}';
    }
    return nodeId;
  }

  /// Adds a DataSetWriter below [writerGroup], linking it to
  /// [publishedDataSet]. The writer serializes the dataset's fields into a
  /// DataSetMessage inside the group's NetworkMessage.
  ///
  /// Required parameters:
  /// * [writerGroup] - The WriterGroup (from [addWriterGroup]).
  /// * [publishedDataSet] - The PublishedDataSet (from [addPublishedDataSet]).
  /// * [name] - Component name.
  /// * [dataSetWriterId] - The writer id stamped into the messages; a matching
  ///   DataSetReader must be configured with the same id.
  ///
  /// Optional parameters:
  /// * [keyFrameCount] - Every n-th message is a key frame carrying all fields
  ///   (defaults to 10). Delta frames are only produced when the server-wide
  ///   `enableDeltaFrames` PubSub option is on; open62541's default (off)
  ///   makes every message a key frame regardless.
  ///
  /// Returns the NodeId identifying the new DataSetWriter.
  ///
  /// Throws an exception if the server rejects the configuration.
  NodeId addDataSetWriter(
    NodeId writerGroup,
    NodeId publishedDataSet, {
    required String name,
    required int dataSetWriterId,
    int keyFrameCount = 10,
  }) {
    final config = ua_calloc<raw.UA_DataSetWriterConfig>();
    config.ref.name.set(name);
    config.ref.dataSetWriterId = dataSetWriterId;
    config.ref.keyFrameCount = keyFrameCount;

    final writerGroupRaw = writerGroup.toRaw();
    final pdsRaw = publishedDataSet.toRaw();
    final out = ua_calloc<raw.UA_NodeId>();
    final code = raw.UA_Server_addDataSetWriter(_server, writerGroupRaw, pdsRaw, config, out);

    _freeRawNodeId(writerGroupRaw);
    _freeRawNodeId(pdsRaw);
    config.ref.name.free();
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add DataSetWriter ${statusCodeToString(code)}';
    }
    return nodeId;
  }

  /// Adds a ReaderGroup below the PubSubConnection [connection]. A ReaderGroup
  /// collects DataSetReaders (the PubSub *subscriber* side, which in OPC UA
  /// lives on a server instance - see [addDataSetReader]).
  ///
  /// Returns the NodeId identifying the new ReaderGroup.
  ///
  /// Throws an exception if the server rejects the configuration.
  NodeId addReaderGroup(NodeId connection, {required String name}) {
    final config = ua_calloc<raw.UA_ReaderGroupConfig>();
    config.ref.name.set(name);

    final connectionRaw = connection.toRaw();
    final out = ua_calloc<raw.UA_NodeId>();
    final code = raw.UA_Server_addReaderGroup(_server, connectionRaw, config, out);

    _freeRawNodeId(connectionRaw);
    config.ref.name.free();
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add ReaderGroup ${statusCodeToString(code)}';
    }
    return nodeId;
  }

  /// Adds a DataSetReader below [readerGroup]. The reader processes incoming
  /// NetworkMessages whose identifiers match ([publisherId], [writerGroupId],
  /// [dataSetWriterId]) and decodes the DataSetMessage against the
  /// DataSetMetaData described by [fields].
  ///
  /// [fields] must list the published fields in the SAME ORDER as the
  /// publisher added them (see [addDataSetField]); each entry gives the field
  /// name and its builtin data type. After adding the reader, map the decoded
  /// fields into local variable nodes with [setDataSetReaderTargetVariables] -
  /// without target variables the received values are dropped.
  ///
  /// Optional parameters:
  /// * [messageReceiveTimeout] - When set, the reader reports an error state
  ///   if no matching message arrives within this interval.
  ///
  /// Returns the NodeId identifying the new DataSetReader.
  ///
  /// Throws an exception if the server rejects the configuration, or if a
  /// field's data type is not a builtin namespace-0 type.
  NodeId addDataSetReader(
    NodeId readerGroup, {
    required String name,
    required PubSubPublisherId publisherId,
    required int writerGroupId,
    required int dataSetWriterId,
    required String dataSetName,
    required List<DataSetFieldMeta> fields,
    Duration? messageReceiveTimeout,
  }) {
    final config = ua_calloc<raw.UA_DataSetReaderConfig>();
    config.ref.name.set(name);
    _fillRawPublisherId(config.ref.publisherId, publisherId);
    config.ref.writerGroupId = writerGroupId;
    config.ref.dataSetWriterId = dataSetWriterId;
    if (messageReceiveTimeout != null) {
      config.ref.messageReceiveTimeout = messageReceiveTimeout.inMicroseconds / 1000.0;
    }

    // DataSetMetaData: name + ordered field list. The builtInType byte of a
    // field equals the numeric ns=0 NodeId of its builtin data type (Part 14
    // uses the same numbering, e.g. Int32 = 6).
    config.ref.dataSetMetaData.name.set(dataSetName);
    final fieldArray = ua_calloc<raw.UA_FieldMetaData>(fields.length);
    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      if (!field.dataType.isNumeric() || field.dataType.namespace != 0) {
        // Roll back what was allocated so far before throwing.
        for (var j = 0; j < i; j++) {
          (fieldArray + j).ref.name.free();
          if ((fieldArray + j).ref.arrayDimensions != ffi.nullptr) {
            ua_calloc.free((fieldArray + j).ref.arrayDimensions);
          }
        }
        ua_calloc.free(fieldArray);
        config.ref.dataSetMetaData.name.free();
        config.ref.name.free();
        _clearRawPublisherId(config.ref.publisherId, publisherId);
        ua_calloc.free(config);
        throw 'DataSetFieldMeta "${field.name}" must use a builtin namespace-0 data type, got: ${field.dataType}';
      }
      (fieldArray + i).ref.name.set(field.name);
      (fieldArray + i).ref.builtInType = field.dataType.numeric;
      (fieldArray + i).ref.dataType = field.dataType.toRaw();
      (fieldArray + i).ref.valueRank = field.valueRank;
      if (field.arrayDimensions.isNotEmpty) {
        final dims = ua_calloc<ffi.Uint32>(field.arrayDimensions.length);
        dims.asTypedList(field.arrayDimensions.length).setRange(0, field.arrayDimensions.length, field.arrayDimensions);
        (fieldArray + i).ref.arrayDimensions = dims;
        (fieldArray + i).ref.arrayDimensionsSize = field.arrayDimensions.length;
      }
    }
    config.ref.dataSetMetaData.fieldsSize = fields.length;
    config.ref.dataSetMetaData.fields = fieldArray;

    final readerGroupRaw = readerGroup.toRaw();
    final out = ua_calloc<raw.UA_NodeId>();
    final code = raw.UA_Server_addDataSetReader(_server, readerGroupRaw, config, out);

    // open62541 deep-copied the config (including the metadata field array).
    _freeRawNodeId(readerGroupRaw);
    for (var i = 0; i < fields.length; i++) {
      (fieldArray + i).ref.name.free();
      if ((fieldArray + i).ref.arrayDimensions != ffi.nullptr) {
        ua_calloc.free((fieldArray + i).ref.arrayDimensions);
      }
    }
    ua_calloc.free(fieldArray);
    config.ref.dataSetMetaData.name.free();
    config.ref.name.free();
    _clearRawPublisherId(config.ref.publisherId, publisherId);
    ua_calloc.free(config);

    final nodeId = _takeOutNodeId(out);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add DataSetReader ${statusCodeToString(code)}';
    }
    return nodeId;
  }

  /// Maps the fields decoded by [dataSetReader] into local variable nodes:
  /// field `i` of every received DataSetMessage is written to the Value
  /// attribute of `targetNodeIds[i]`. The target nodes must already exist
  /// (e.g. created with [addVariableNode]) and their length/order must match
  /// the reader's [DataSetFieldMeta] list.
  ///
  /// The DataSetReader must still be disabled (targets cannot be replaced on a
  /// live reader), so call this before [enableAllPubSubComponents].
  ///
  /// Received values can then be observed via [read], a regular client
  /// subscription, or [onValueChanged].
  ///
  /// Throws an exception if the server rejects the mapping.
  void setDataSetReaderTargetVariables(NodeId dataSetReader, List<NodeId> targetNodeIds) {
    final targets = ua_calloc<raw.UA_FieldTargetDataType>(targetNodeIds.length);
    for (var i = 0; i < targetNodeIds.length; i++) {
      (targets + i).ref.attributeId = raw.UA_AttributeId.UA_ATTRIBUTEID_VALUE.value;
      (targets + i).ref.targetNodeId = targetNodeIds[i].toRaw();
    }

    final readerRaw = dataSetReader.toRaw();
    final code = raw.UA_Server_setDataSetReaderTargetVariables(_server, readerRaw, targetNodeIds.length, targets);

    // open62541 deep-copied the target array; release our copies.
    _freeRawNodeId(readerRaw);
    for (var i = 0; i < targetNodeIds.length; i++) {
      _freeRawNodeId((targets + i).ref.targetNodeId);
    }
    ua_calloc.free(targets);

    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to set DataSetReader target variables ${statusCodeToString(code)}';
    }
  }

  /// Enables every PubSub component on this server (connections, writer/reader
  /// groups, dataset writers/readers). Components are created disabled, so
  /// call this once the PubSub topology is fully configured. The components
  /// then converge to [PubSubState.operational] on their own (driven from
  /// [runIterate]).
  ///
  /// Throws an exception if any component fails to enable (the underlying call
  /// returns the ORed status codes of the individual components).
  void enableAllPubSubComponents() {
    final code = raw.UA_Server_enableAllPubSubComponents(_server);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to enable PubSub components ${statusCodeToString(code)}';
    }
  }

  /// Disables every PubSub component on this server. Readers are disabled
  /// before writers so a loopback configuration cannot time out.
  void disableAllPubSubComponents() {
    raw.UA_Server_disableAllPubSubComponents(_server);
  }

  /// Immediately publishes the [writerGroup]'s NetworkMessage, independent of
  /// its publishing interval. Useful for tests and on-demand publishing.
  ///
  /// Throws an exception if the server rejects the trigger (e.g. the group is
  /// not operational).
  void triggerWriterGroupPublish(NodeId writerGroup) {
    final writerGroupRaw = writerGroup.toRaw();
    final code = raw.UA_Server_triggerWriterGroupPublish(_server, writerGroupRaw);
    _freeRawNodeId(writerGroupRaw);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to trigger WriterGroup publish ${statusCodeToString(code)}';
    }
  }

  PubSubState _pubSubState(
    NodeId componentId,
    int Function(ffi.Pointer<raw.UA_Server>, raw.UA_NodeId, ffi.Pointer<ffi.UnsignedInt>) getState,
    String what,
  ) {
    final componentRaw = componentId.toRaw();
    final state = ua_calloc<ffi.UnsignedInt>();
    final code = getState(_server, componentRaw, state);
    _freeRawNodeId(componentRaw);
    final value = state.value;
    ua_calloc.free(state);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to get $what state ${statusCodeToString(code)}, nodeId: $componentId';
    }
    return PubSubState.fromRaw(value);
  }

  /// The current [PubSubState] of the WriterGroup [writerGroup].
  PubSubState writerGroupState(NodeId writerGroup) =>
      _pubSubState(writerGroup, raw.UA_Server_getWriterGroupState, 'WriterGroup');

  /// The current [PubSubState] of the DataSetWriter [dataSetWriter].
  PubSubState dataSetWriterState(NodeId dataSetWriter) =>
      _pubSubState(dataSetWriter, raw.UA_Server_getDataSetWriterState, 'DataSetWriter');

  /// The current [PubSubState] of the ReaderGroup [readerGroup].
  PubSubState readerGroupState(NodeId readerGroup) =>
      _pubSubState(readerGroup, raw.UA_Server_getReaderGroupState, 'ReaderGroup');

  /// The current [PubSubState] of the DataSetReader [dataSetReader].
  PubSubState dataSetReaderState(NodeId dataSetReader) =>
      _pubSubState(dataSetReader, raw.UA_Server_getDataSetReaderState, 'DataSetReader');

  /// Lazily creates the shared onWrite notification dispatcher backing
  /// [onValueChanged].
  void _ensureValueChangeDispatcher() {
    if (_valueChangeDispatcher != null) return;

    void onWriteCb(
      ffi.Pointer<raw.UA_Server> server,
      ffi.Pointer<raw.UA_NodeId> sessionId,
      ffi.Pointer<ffi.Void> sessionContext,
      ffi.Pointer<raw.UA_NodeId> nodeId,
      ffi.Pointer<ffi.Void> nodeContext,
      ffi.Pointer<raw.UA_NumericRange> range,
      ffi.Pointer<raw.UA_DataValue> data,
    ) {
      try {
        final controller = _valueChangeControllers[nodeId.ref.toNodeId()];
        if (controller == null || controller.isClosed) return;
        // UA_Variant is the first member of UA_DataValue, so a UA_DataValue*
        // cast to UA_Variant* points at the inline `value` field (same
        // aliasing as the data-source dispatchers).
        final variant = data.cast<raw.UA_Variant>().ref;
        if (variant.data == ffi.nullptr) return;
        controller.add(variantToValue(variant));
      } catch (_) {
        // Never let a Dart exception unwind into native code.
      }
    }

    _valueChangeDispatcher =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NumericRange>,
            ffi.Pointer<raw.UA_DataValue>,
          )
        >.isolateLocal(onWriteCb);
  }

  /// A broadcast stream of the values written to the variable node [nodeId].
  ///
  /// Emits on every write to the node's Value attribute - client writes,
  /// [write] calls and, notably, values delivered by a PubSub DataSetReader
  /// into one of its target variables (see [setDataSetReaderTargetVariables]),
  /// making this the idiomatic way to consume received PubSub values:
  ///
  /// ```dart
  /// server.setDataSetReaderTargetVariables(reader, [targetNodeId]);
  /// server.onValueChanged(targetNodeId).listen((v) => print(v.value));
  /// ```
  ///
  /// The stream is backed by open62541's value-source notification (an
  /// after-write callback attached to the node), which fires inside
  /// [runIterate] on this isolate. The node must already exist. Repeated calls
  /// for the same node return the same broadcast stream. The notification and
  /// stream are released when the node is deleted ([deleteNode]) or the server
  /// is torn down ([delete]).
  ///
  /// Do NOT use this on a node created with [addDataSourceVariableNode]:
  /// attaching the notification switches the node to an *internal* value
  /// source, silently detaching its callback value source. Data-source nodes
  /// already deliver writes to their `onWrite` handler.
  ///
  /// Throws an exception if the notification cannot be attached (e.g. the node
  /// does not exist or is not a variable node).
  Stream<DynamicValue> onValueChanged(NodeId nodeId) {
    final existing = _valueChangeControllers[nodeId];
    if (existing != null) return existing.stream;

    _ensureValueChangeDispatcher();

    final notifications = ua_calloc<raw.UA_ValueSourceNotifications>();
    notifications.ref.onWrite = _valueChangeDispatcher!.nativeFunction;
    final nodeIdRaw = nodeId.toRaw();
    // Keeps the node's internal value source, only attaching the notification
    // callbacks (the struct is copied by value into the node).
    final code = raw.UA_Server_setVariableNode_internalValueSource(_server, nodeIdRaw, ffi.nullptr, notifications);
    _freeRawNodeId(nodeIdRaw);
    ua_calloc.free(notifications);
    if (code != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to attach value-change notification ${statusCodeToString(code)}, nodeId: $nodeId';
    }

    final controller = StreamController<DynamicValue>.broadcast();
    _valueChangeControllers[nodeId] = controller;
    return controller.stream;
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
    if (_server == ffi.nullptr) {
      throw StateError('Server has been deleted; shutdown() must be called before delete()');
    }
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
    // Already deleted: a second delete() is a safe no-op (not a double free).
    if (_server == ffi.nullptr) {
      return;
    }
    final server = _server;
    // Invalidate the handle FIRST so nothing can observe a dangling pointer:
    // [runIterate] (typically driven from a detached async loop) checks
    // `_server != nullptr` and now returns false instead of calling into freed
    // native memory when the loop ticks after this delete.
    _server = ffi.nullptr;
    int ret = raw.UA_Server_delete(server);
    // The server no longer holds references to any of our native callbacks, so
    // it is safe to close them and release the native trampolines.
    //
    // Data-source dispatchers (shared read/write pair):
    _dsReadDispatcher?.close();
    _dsWriteDispatcher?.close();
    _dsReadDispatcher = null;
    _dsWriteDispatcher = null;
    _dataSourceReads.clear();
    _dataSourceWrites.clear();
    _dataSourceTypeIds.clear();
    // Value-change notification dispatcher and streams:
    _valueChangeDispatcher?.close();
    _valueChangeDispatcher = null;
    for (final controller in _valueChangeControllers.values) {
      controller.close();
    }
    _valueChangeControllers.clear();
    // Per-method-node callbacks:
    for (final callback in _methodCallbacks.values) {
      callback.close();
    }
    _methodCallbacks.clear();
    if (ret != 0) {
      throw "Failed to delete server ${statusCodeToString(ret)}";
    }
  }
}
