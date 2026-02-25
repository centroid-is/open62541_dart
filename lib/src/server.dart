import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'browse_types.dart';
import 'common.dart';
import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

class Server {
  Server({
    LogLevel? logLevel,
    int? port,
    int? maxSecureChannels,
    int? maxSessions,
    Uint8List? certificate,
    Uint8List? privateKey,
    Map<String, String>? users,
    bool allowAnonymous = true,
    bool allowNonePolicyPassword = false,
    bool securityPolicyNoneDiscoveryOnly = false,
    double? maxSessionTimeout,
    int? maxSecurityTokenLifetime,
  }) {
    final config = ua_calloc<raw.UA_ServerConfig>();

    if (logLevel != null) {
      config.ref.logging = raw.UA_Log_Stdout_new(logLevel);
    }

    int res;
    if (certificate != null && privateKey != null) {
      // TLS path: configure with security policies
      final rawCert = _uint8ListToByteString(certificate);
      final rawKey = _uint8ListToByteString(privateKey);

      res = raw.UA_ServerConfig_setDefaultWithSecurityPolicies(
        config,
        port ?? 4840,
        rawCert,
        rawKey,
        ffi.nullptr, // trustList
        0,
        ffi.nullptr, // issuerList
        0,
        ffi.nullptr, // revocationList
        0,
      );

      _freeByteString(rawCert);
      _freeByteString(rawKey);

      if (res != raw.UA_STATUSCODE_GOOD) {
        throw 'Failed to set server config with security policies: ${statusCodeToString(res)}';
      }

      // Accept all client certificates (same pattern as Client)
      final secureChannelPKI = ua_calloc<raw.UA_CertificateGroup>();
      secureChannelPKI.ref = config.ref.secureChannelPKI;
      raw.UA_CertificateGroup_AcceptAll(secureChannelPKI);
      config.ref.secureChannelPKI = secureChannelPKI.ref;
      ua_calloc.free(secureChannelPKI);

      final sessionPKI = ua_calloc<raw.UA_CertificateGroup>();
      sessionPKI.ref = config.ref.sessionPKI;
      raw.UA_CertificateGroup_AcceptAll(sessionPKI);
      config.ref.sessionPKI = sessionPKI.ref;
      ua_calloc.free(sessionPKI);
    } else {
      // No TLS: minimal config
      res = raw.UA_ServerConfig_setMinimal(config, port ?? 4840, ffi.nullptr);
      if (res != raw.UA_STATUSCODE_GOOD) {
        throw 'Failed to set default server config ${statusCodeToString(res)}';
      }
    }

    // Authentication
    if (users != null && users.isNotEmpty) {
      final logins = ua_calloc<raw.UA_UsernamePasswordLogin>(users.length);
      var i = 0;
      for (final entry in users.entries) {
        logins[i].username.set(entry.key);
        logins[i].password.set(entry.value);
        i++;
      }

      final authRes = raw.UA_AccessControl_default(
        config,
        allowAnonymous,
        ffi.nullptr, // auto-detect from configured security policies
        users.length,
        logins,
      );

      // C function copies the data, so free our temporaries
      for (var j = 0; j < users.length; j++) {
        logins[j].username.free();
        logins[j].password.free();
      }
      ua_calloc.free(logins);

      if (authRes != raw.UA_STATUSCODE_GOOD) {
        throw 'Failed to set access control: ${statusCodeToString(authRes)}';
      }
    }

    if (allowNonePolicyPassword) {
      config.ref.allowNonePolicyPassword = true;
    }

    if (maxSecureChannels != null) config.ref.maxSecureChannels = maxSecureChannels;
    if (maxSessions != null) config.ref.maxSessions = maxSessions;
    if (maxSessionTimeout != null) config.ref.maxSessionTimeout = maxSessionTimeout;
    if (maxSecurityTokenLifetime != null) config.ref.maxSecurityTokenLifetime = maxSecurityTokenLifetime;
    if (securityPolicyNoneDiscoveryOnly) config.ref.securityPolicyNoneDiscoveryOnly = true;

    _server = raw.UA_Server_newWithConfig(config);
    _config = raw.UA_Server_getConfig(_server);
  }

  static ffi.Pointer<raw.UA_ByteString> _uint8ListToByteString(Uint8List bytes) {
    final bs = ua_calloc<raw.UA_ByteString>();
    bs.ref.data = ua_calloc<ffi.Uint8>(bytes.length);
    bs.ref.length = bytes.length;
    bs.ref.data.asTypedList(bytes.length).setRange(0, bytes.length, bytes);
    return bs;
  }

  static void _freeByteString(ffi.Pointer<raw.UA_ByteString> bs) {
    if (bs.ref.data != ffi.nullptr) {
      ua_calloc.free(bs.ref.data);
    }
    ua_calloc.free(bs);
  }

  late ffi.Pointer<raw.UA_Server> _server;
  late ffi.Pointer<raw.UA_ServerConfig> _config;
  final _methodCallbacks = <ffi.NativeCallable>[];
  final _methodAccessRules = <NodeId, Set<String>>{};
  final _sessionUsernames = <String, String>{}; // sessionId key → username
  bool _sessionTrackingInstalled = false;
  bool _accessControlInstalled = false;

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
    int writeMask = 0,
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    NodeId? baseDataVariableType,
    NodeId? typeId,
  }) {
    ffi.Pointer<raw.UA_VariableAttributes> attr = raw.UA_VariableAttributes_new();
    attr.ref = raw.UA_VariableAttributes_default;

    final variant = valueToVariant(value);
    typeId ??= value.typeId;

    // For custom types, decode the ExtensionObject body into proper in-memory format
    // using UA_decodeBinary. This handles types with pointers (e.g., strings) correctly.
    if (variant.ref.type.ref.typeId.toNodeId() == NodeId.structure) {
      final t = _findDataType(typeId!);
      if (t == ffi.nullptr) {
        throw 'Failed to find data type $typeId';
      }

      final count = variant.ref.arrayLength > 0 ? variant.ref.arrayLength : 1;
      final isArray = variant.ref.arrayLength > 0;

      // Allocate memSize bytes for all decoded structs
      final decoded = ua_calloc<ffi.Uint8>(t.ref.memSize * count);
      final bodyPtr = ua_calloc<raw.UA_ByteString>();

      for (var i = 0; i < count; i++) {
        final extObj = variant.ref.data.cast<raw.UA_ExtensionObject>() + i;
        bodyPtr.ref = extObj.ref.content.encoded.body;
        final offset = ffi.Pointer<ffi.Uint8>.fromAddress(decoded.address + (i * t.ref.memSize));
        final status = raw.UA_decodeBinary(bodyPtr, offset.cast(), t, ffi.nullptr);
        if (status != raw.UA_STATUSCODE_GOOD) {
          ua_calloc.free(bodyPtr);
          ua_calloc.free(decoded);
          throw 'Failed to decode custom type element $i: ${statusCodeToString(status)}';
        }
      }
      ua_calloc.free(bodyPtr);

      attr.ref.value.type = t;
      attr.ref.value.data = decoded.cast();
      attr.ref.value.arrayLength = isArray ? count : 0;

      // Copy array dimensions if multidimensional
      if (variant.ref.arrayDimensionsSize > 0) {
        attr.ref.value.arrayDimensionsSize = variant.ref.arrayDimensionsSize;
        attr.ref.value.arrayDimensions = ua_calloc<ffi.Uint32>(variant.ref.arrayDimensionsSize);
        for (var d = 0; d < variant.ref.arrayDimensionsSize; d++) {
          attr.ref.value.arrayDimensions[d] = variant.ref.arrayDimensions[d];
        }
      }
    } else {
      attr.ref.value = variant.ref;
    }
    attr.ref.accessLevel = accessLevel.value;
    attr.ref.writeMask = writeMask;
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

  /// Add an object node (folder/container) to the server address space.
  void addObjectNode(
    NodeId objectNodeId,
    String browseName, {
    NodeId? parentNodeId,
    NodeId? referenceTypeId,
    NodeId? typeDefinition,
  }) {
    final attrType = getType(UaTypes.objectAttributes);

    // Allocate and zero-initialize the full UA_ObjectAttributes struct
    final attrMem = ua_calloc<ffi.Uint8>(attrType.ref.memSize);

    // Set displayName through the UA_NodeAttributes view (common leading fields)
    final attr = attrMem.cast<raw.UA_NodeAttributes>();
    final ltPtr = localizedTextToRaw(LocalizedText(browseName, ''));
    attr.ref.displayName = ltPtr.ref;

    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    referenceTypeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES);
    typeDefinition ??= NodeId.fromNumeric(0, raw.UA_NS0ID_BASEOBJECTTYPE);

    _addNode(
      raw.UA_NodeClass.UA_NODECLASS_OBJECT,
      objectNodeId,
      parentNodeId,
      referenceTypeId,
      browseName,
      typeDefinition,
      attr,
      attrType,
    );

    ua_calloc.free(attrMem);
  }

  /// Add a method node to the server address space.
  ///
  /// [methodNodeId] is the NodeId for the new method.
  /// [browseName] is the display/browse name.
  /// [callback] is the Dart function invoked when a client calls this method.
  /// [inputArguments] and [outputArguments] describe the method's signature.
  void addMethodNode(
    NodeId methodNodeId,
    String browseName, {
    required List<DynamicValue> Function(List<DynamicValue> inputs) callback,
    List<DynamicValue> inputArguments = const [],
    List<DynamicValue> outputArguments = const [],
    NodeId? parentNodeId,
    NodeId? referenceTypeId,
  }) {
    parentNodeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
    referenceTypeId ??= NodeId.fromNumeric(0, raw.UA_NS0ID_HASCOMPONENT);

    // Build method attributes
    final attrType = getType(UaTypes.methodAttributes);
    final attrMem = ua_calloc<ffi.Uint8>(attrType.ref.memSize);
    final attr = attrMem.cast<raw.UA_MethodAttributes>();
    final ltPtr = localizedTextToRaw(LocalizedText(browseName, ''));
    attr.ref.displayName = ltPtr.ref;
    attr.ref.executable = true;
    attr.ref.userExecutable = true;

    // Build input arguments
    final inputArgsPtr = inputArguments.isEmpty
        ? ffi.nullptr.cast<raw.UA_Argument>()
        : ua_calloc<raw.UA_Argument>(inputArguments.length);
    for (var i = 0; i < inputArguments.length; i++) {
      final arg = inputArguments[i];
      if (arg.name != null) (inputArgsPtr + i).ref.name.set(arg.name!);
      if (arg.typeId != null) (inputArgsPtr + i).ref.dataType = arg.typeId!.toRaw();
      (inputArgsPtr + i).ref.valueRank = -1; // scalar
    }

    // Build output arguments
    final outputArgsPtr = outputArguments.isEmpty
        ? ffi.nullptr.cast<raw.UA_Argument>()
        : ua_calloc<raw.UA_Argument>(outputArguments.length);
    for (var i = 0; i < outputArguments.length; i++) {
      final arg = outputArguments[i];
      if (arg.name != null) (outputArgsPtr + i).ref.name.set(arg.name!);
      if (arg.typeId != null) (outputArgsPtr + i).ref.dataType = arg.typeId!.toRaw();
      (outputArgsPtr + i).ref.valueRank = -1; // scalar
    }

    // Create the native callback
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
            // Marshal inputs
            final inputs = <DynamicValue>[];
            for (var i = 0; i < inputSize; i++) {
              inputs.add(variantToValue(input[i]));
            }

            // Call Dart callback
            final results = callback(inputs);

            // Marshal outputs using UA_Variant_copy for proper deep copy
            for (var i = 0; i < results.length && i < outputSize; i++) {
              final variantPtr = valueToVariant(results[i]);
              raw.UA_Variant_copy(variantPtr, output + i);
              raw.UA_Variant_delete(variantPtr);
            }

            return raw.UA_STATUSCODE_GOOD;
          } catch (_) {
            return raw.UA_STATUSCODE_BADINTERNALERROR;
          }
        }, exceptionalReturn: raw.UA_STATUSCODE_BADINTERNALERROR);

    // Store the callable so it doesn't get garbage collected
    _methodCallbacks.add(nativeCallback);

    final browse = raw.UA_QUALIFIEDNAME(1, browseName.toNativeUtf8(allocator: ua_malloc).cast());

    final retCode = raw.UA_Server_addMethodNode(
      _server,
      methodNodeId.toRaw(),
      parentNodeId.toRaw(),
      referenceTypeId.toRaw(),
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

    // Cleanup allocations
    if (inputArguments.isNotEmpty) ua_calloc.free(inputArgsPtr);
    if (outputArguments.isNotEmpty) ua_calloc.free(outputArgsPtr);
    ua_calloc.free(attrMem);

    if (retCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to add method node: ${statusCodeToString(retCode)}';
    }
  }

  /// Deletes a node from the server's address space.
  ///
  /// By default, all references to and from the node are also deleted.
  void deleteNode(NodeId nodeId, {bool deleteReferences = true}) {
    final res = raw.UA_Server_deleteNode(_server, nodeId.toRaw(), deleteReferences);
    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to delete node: ${statusCodeToString(res)}';
    }
  }

  /// Restrict a method node so only [allowedUsers] may call it.
  ///
  /// Overrides `getUserExecutableOnObject` in the server's access control.
  /// Methods without a rule are unrestricted (default allow).
  /// Anonymous sessions are denied if a rule exists.
  void setMethodAccess(NodeId methodNodeId, {required Set<String> allowedUsers}) {
    _methodAccessRules[methodNodeId] = allowedUsers;
    _installSessionTracking();
    _installAccessControlCallback();
  }

  /// String key for any UA_NodeId type (including GUID session IDs).
  static String _nodeIdKey(raw.UA_NodeId id) {
    final ns = id.namespaceIndex;
    switch (id.identifierType) {
      case raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC:
        return 'ns=$ns;i=${id.identifier.numeric}';
      case raw.UA_NodeIdType.UA_NODEIDTYPE_STRING:
        return 'ns=$ns;s=${id.identifier.string.value}';
      case raw.UA_NodeIdType.UA_NODEIDTYPE_GUID:
        final g = id.identifier.guid;
        return 'ns=$ns;g=${g.data1}-${g.data2}-${g.data3}';
      case raw.UA_NodeIdType.UA_NODEIDTYPE_BYTESTRING:
        return 'ns=$ns;b=${id.identifier.byteString.length}';
    }
  }

  /// Wraps activateSession/closeSession to track which username is associated
  /// with each sessionId. open62541 v1.5's default activateSession does NOT
  /// store the username in sessionContext, so we do it ourselves.
  void _installSessionTracking() {
    if (_sessionTrackingInstalled) return;
    _sessionTrackingInstalled = true;

    // Save original functions before overwriting
    final originalActivateFn = _config.ref.accessControl.activateSession
        .asFunction<
          int Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_AccessControl>,
            ffi.Pointer<raw.UA_EndpointDescription>,
            ffi.Pointer<raw.UA_ByteString>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<raw.UA_ExtensionObject>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>,
          )
        >();
    final originalCloseFn = _config.ref.accessControl.closeSession
        .asFunction<
          void Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_AccessControl>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
          )
        >();

    // Wrap activateSession to extract username on successful login
    final activateCallable =
        ffi.NativeCallable<
          raw.UA_StatusCode Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_AccessControl>,
            ffi.Pointer<raw.UA_EndpointDescription>,
            ffi.Pointer<raw.UA_ByteString>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<raw.UA_ExtensionObject>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Server> server,
          ffi.Pointer<raw.UA_AccessControl> ac,
          ffi.Pointer<raw.UA_EndpointDescription> endpointDescription,
          ffi.Pointer<raw.UA_ByteString> secureChannelRemoteCertificate,
          ffi.Pointer<raw.UA_NodeId> sessionId,
          ffi.Pointer<raw.UA_ExtensionObject> userIdentityToken,
          ffi.Pointer<ffi.Pointer<ffi.Void>> sessionContext,
        ) {
          final result = originalActivateFn(
            server,
            ac,
            endpointDescription,
            secureChannelRemoteCertificate,
            sessionId,
            userIdentityToken,
            sessionContext,
          );

          if (result == raw.UA_STATUSCODE_GOOD &&
              userIdentityToken.ref.encodingAsInt >= raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED.value) {
            final tokenTypeId = userIdentityToken.ref.content.decoded.type.ref.typeId.toNodeId();
            if (tokenTypeId == NodeId.fromNumeric(0, raw.UA_NS0ID_USERNAMEIDENTITYTOKEN)) {
              final userToken = userIdentityToken.ref.content.decoded.data.cast<raw.UA_UserNameIdentityToken>();
              _sessionUsernames[_nodeIdKey(sessionId.ref)] = userToken.ref.userName.value;
            }
          }

          return result;
        }, exceptionalReturn: raw.UA_STATUSCODE_BADINTERNALERROR);

    _methodCallbacks.add(activateCallable);
    _config.ref.accessControl.activateSession = activateCallable.nativeFunction;

    // Wrap closeSession to clean up our map
    final closeCallable =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_AccessControl>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Server> server,
          ffi.Pointer<raw.UA_AccessControl> ac,
          ffi.Pointer<raw.UA_NodeId> sessionId,
          ffi.Pointer<ffi.Void> sessionContext,
        ) {
          _sessionUsernames.remove(_nodeIdKey(sessionId.ref));
          originalCloseFn(server, ac, sessionId, sessionContext);
        });

    _methodCallbacks.add(closeCallable);
    _config.ref.accessControl.closeSession = closeCallable.nativeFunction;
  }

  void _installAccessControlCallback() {
    if (_accessControlInstalled) return;
    _accessControlInstalled = true;

    final callable =
        ffi.NativeCallable<
          ffi.Bool Function(
            ffi.Pointer<raw.UA_Server>,
            ffi.Pointer<raw.UA_AccessControl>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<raw.UA_NodeId>,
            ffi.Pointer<ffi.Void>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Server> server,
          ffi.Pointer<raw.UA_AccessControl> ac,
          ffi.Pointer<raw.UA_NodeId> sessionId,
          ffi.Pointer<ffi.Void> sessionContext,
          ffi.Pointer<raw.UA_NodeId> methodId,
          ffi.Pointer<ffi.Void> methodContext,
          ffi.Pointer<raw.UA_NodeId> objectId,
          ffi.Pointer<ffi.Void> objectContext,
        ) {
          final dartMethodId = methodId.ref.toNodeId();
          final allowedUsers = _methodAccessRules[dartMethodId];
          if (allowedUsers == null) return true; // no restriction

          final sessionIdStr = _nodeIdKey(sessionId.ref);
          final username = _sessionUsernames[sessionIdStr];
          if (username == null) return false; // anonymous or unknown
          return allowedUsers.contains(username);
        }, exceptionalReturn: false);

    _methodCallbacks.add(callable);
    _config.ref.accessControl.getUserExecutableOnObject = callable.nativeFunction;
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

  /// Register callbacks on [variableNodeId] to get notifications
  /// when the value is read or written by external clients.
  ///
  /// Returns a stream of `(String event, DynamicValue? value)` records
  /// where event is "read" (value is null) or "write" (value is the written data).
  Stream<(String, DynamicValue?)> monitorVariable(NodeId variableNodeId) {
    final controller = StreamController<(String, DynamicValue?)>();

    void onRead(
      ffi.Pointer<raw.UA_Server> server,
      ffi.Pointer<raw.UA_NodeId> sessionId,
      ffi.Pointer<ffi.Void> sessionCtx,
      ffi.Pointer<raw.UA_NodeId> nodeId,
      ffi.Pointer<ffi.Void> nodeCtx,
      ffi.Pointer<raw.UA_NumericRange> range,
      ffi.Pointer<raw.UA_DataValue> value,
    ) {
      if (!controller.isClosed) {
        controller.add(('read', null));
      }
    }

    void onWrite(
      ffi.Pointer<raw.UA_Server> server,
      ffi.Pointer<raw.UA_NodeId> sessionId,
      ffi.Pointer<ffi.Void> sessionCtx,
      ffi.Pointer<raw.UA_NodeId> nodeId,
      ffi.Pointer<ffi.Void> nodeCtx,
      ffi.Pointer<raw.UA_NumericRange> range,
      ffi.Pointer<raw.UA_DataValue> data,
    ) {
      if (!controller.isClosed) {
        final dynValue = variantToValue(data.ref.value);
        controller.add(('write', dynValue));
      }
    }

    final onReadCallable =
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
        >.isolateLocal(onRead);

    final onWriteCallable =
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
        >.isolateLocal(onWrite);

    final callback = ua_calloc<raw.UA_ValueSourceNotifications>();
    callback.ref.onRead = onReadCallable.nativeFunction;
    callback.ref.onWrite = onWriteCallable.nativeFunction;

    raw.UA_Server_setVariableNode_internalValueSource(_server, variableNodeId.toRaw(), ffi.nullptr, callback);

    controller.onCancel = () {
      // Clear callbacks on the node by passing nullptr for notifications
      raw.UA_Server_setVariableNode_internalValueSource(_server, variableNodeId.toRaw(), ffi.nullptr, ffi.nullptr);

      onReadCallable.close();
      onWriteCallable.close();
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
    final ptr = localizedTextToRaw(description);
    final res = raw.UA_Server_writeDescription(_server, variableNodeId.toRaw(), ptr.ref);
    raw.UA_LocalizedText_delete(ptr);
    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to write Description: ${statusCodeToString(res)}';
    }
  }

  void writeDisplayName(NodeId variableNodeId, LocalizedText displayName) {
    final ptr = localizedTextToRaw(displayName);
    final res = raw.UA_Server_writeDisplayName(_server, variableNodeId.toRaw(), ptr.ref);
    raw.UA_LocalizedText_delete(ptr);
    if (res != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to write DisplayName: ${statusCodeToString(res)}';
    }
  }

  Future<DynamicValue> read(NodeId variableNodeId) async {
    final dv = DynamicValue();
    await _readSingleAttributeAsync(variableNodeId, AttributeId.UA_ATTRIBUTEID_DATATYPE, dv);
    await _readSingleAttributeAsync(variableNodeId, AttributeId.UA_ATTRIBUTEID_VALUE, dv);
    return dv;
  }

  /// Reads multiple attributes from multiple nodes using the async C API.
  ///
  /// Uses [UA_Server_read_async] with NativeCallable callbacks. For normal
  /// variable nodes, the callback fires synchronously (same thread) so reads
  /// complete immediately. For DataSource nodes, the callback fires during the
  /// next [runIterate].
  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes) async {
    final results = <NodeId, DynamicValue>{};
    final futures = <Future<void>>[];

    for (final entry in nodes.entries) {
      final nodeId = entry.key;
      final attributes = entry.value;
      final dv = DynamicValue();
      results[nodeId] = dv;

      // Sort so DATATYPE is read before VALUE (typeId hint for value parsing).
      // Since callbacks fire in call order, DATATYPE completes first.
      final sorted = List<AttributeId>.from(attributes);
      sorted.sort((a, b) {
        if (a == AttributeId.UA_ATTRIBUTEID_DATATYPE) return -1;
        if (b == AttributeId.UA_ATTRIBUTEID_DATATYPE) return 1;
        return 0;
      });

      for (final attr in sorted) {
        futures.add(_readSingleAttributeAsync(nodeId, attr, dv));
      }
    }

    await Future.wait(futures);
    return results;
  }

  Future<void> _readSingleAttributeAsync(NodeId nodeId, AttributeId attr, DynamicValue dv) {
    final completer = Completer<void>();

    final readValueId = ua_calloc<raw.UA_ReadValueId>();
    readValueId.ref.nodeId = nodeId.toRaw();
    readValueId.ref.attributeId = attr.value;

    late ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Pointer<raw.UA_DataValue>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Server> server,
          ffi.Pointer<ffi.Void> ctx,
          ffi.Pointer<raw.UA_DataValue> result,
        ) {
          // Callback fires synchronously (same thread) — data pointers are valid.
          callback.close();

          try {
            if (result == ffi.nullptr || result.ref.status != raw.UA_STATUSCODE_GOOD) {
              completer.complete(); // No data, but don't error — attribute may just be empty
              return;
            }

            final value = result.ref.value;
            if (value.data == ffi.nullptr) {
              completer.complete();
              return;
            }

            switch (attr) {
              case AttributeId.UA_ATTRIBUTEID_VALUE:
                final val = variantToValue(value, dataTypeId: dv.typeId);
                dv.value = val.value;
                dv.typeId ??= val.typeId;

              case AttributeId.UA_ATTRIBUTEID_DATATYPE:
                final dataType = value.data.cast<raw.UA_NodeId>();
                dv.typeId = dataType.ref.toNodeId();

              case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
                final lt = value.data.cast<raw.UA_LocalizedText>();
                dv.displayName = LocalizedText(lt.ref.text.value, lt.ref.locale.value);

              case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
                final lt = value.data.cast<raw.UA_LocalizedText>();
                dv.description = LocalizedText(lt.ref.text.value, lt.ref.locale.value);

              case AttributeId.UA_ATTRIBUTEID_BROWSENAME:
                final qn = value.data.cast<raw.UA_QualifiedName>();
                dv.name = qn.ref.name.value;

              case AttributeId.UA_ATTRIBUTEID_NODECLASS:
                final nc = value.data.cast<ffi.UnsignedInt>();
                dv.value = nc.value;

              case AttributeId.UA_ATTRIBUTEID_ACCESSLEVEL:
                final al = value.data.cast<raw.UA_Byte>();
                dv.value = al.value;

              default:
                throw 'readAttribute not implemented for $attr';
            }

            completer.complete();
          } catch (e, st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          } finally {
            ua_calloc.free(readValueId);
          }
        });

    final res = raw.UA_Server_read_async(
      _server,
      readValueId,
      raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH,
      callback.nativeFunction,
      ffi.nullptr,
      0,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      ua_calloc.free(readValueId);
      completer.completeError('UA_Server_read_async failed: ${statusCodeToString(res)}');
    }

    return completer.future;
  }

  /// Writes a value to a variable node using the async C API.
  Future<void> write(NodeId variableNodeId, DynamicValue value) {
    return writeAttribute(variableNodeId, AttributeId.UA_ATTRIBUTEID_VALUE, value);
  }

  /// Writes a specific attribute of a node using the async C API.
  ///
  /// For VALUE, pass a [DynamicValue]. For DISPLAYNAME/DESCRIPTION, pass a
  /// [LocalizedText]. The [value] type must match the attribute.
  Future<void> writeAttribute(NodeId nodeId, AttributeId attributeId, dynamic value) async {
    final completer = Completer<void>();

    final writeValue = ua_calloc<raw.UA_WriteValue>();
    raw.UA_WriteValue_init(writeValue);
    writeValue.ref.nodeId = nodeId.toRaw();
    writeValue.ref.attributeId = attributeId.value;
    writeValue.ref.value.substitute = 1; // hasValue = true

    try {
      switch (attributeId) {
        case AttributeId.UA_ATTRIBUTEID_VALUE:
          final dynVal = value as DynamicValue;
          final variant = valueToVariant(dynVal);
          writeValue.ref.value.value = variant.ref;
          ua_calloc.free(variant); // Free the pointer, data is now owned by writeValue

        case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
        case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
          final ltRaw = localizedTextToRaw(value as LocalizedText);
          writeValue.ref.value.value.data = ltRaw.cast();
          writeValue.ref.value.value.type = getType(UaTypes.localizedText);

        default:
          throw 'writeAttribute not implemented for $attributeId';
      }
    } catch (e) {
      raw.UA_WriteValue_delete(writeValue);
      rethrow;
    }

    late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Uint32)> callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.Pointer<ffi.Void>, ffi.Uint32)
        >.isolateLocal((ffi.Pointer<raw.UA_Server> server, ffi.Pointer<ffi.Void> ctx, int statusCode) {
          callback.close();
          raw.UA_WriteValue_delete(writeValue);

          if (statusCode != raw.UA_STATUSCODE_GOOD) {
            completer.completeError('Failed to write: ${statusCodeToString(statusCode)}');
          } else {
            completer.complete();
          }
        });

    final res = raw.UA_Server_write_async(_server, writeValue, callback.nativeFunction, ffi.nullptr, 0);
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      raw.UA_WriteValue_delete(writeValue);
      completer.completeError('UA_Server_write_async failed: ${statusCodeToString(res)}');
    }

    await completer.future;
  }

  /// Browses the references of a node.
  ///
  /// Returns the list of references from [nodeId].
  List<BrowseResultItem> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) {
    final bd = ua_calloc<raw.UA_BrowseDescription>();
    raw.UA_BrowseDescription_init(bd);
    bd.ref.nodeId = nodeId.toRaw();
    bd.ref.browseDirectionAsInt = direction;
    bd.ref.includeSubtypes = includeSubtypes;
    bd.ref.nodeClassMask = nodeClassMask;
    bd.ref.resultMask = resultMask.value;
    if (referenceTypeId != null) {
      bd.ref.referenceTypeId = referenceTypeId.toRaw();
    }

    final result = raw.UA_Server_browse(_server, 0, bd);
    if (result.statusCode != raw.UA_STATUSCODE_GOOD) {
      ua_calloc.free(bd);
      throw 'Failed to browse node $nodeId: ${statusCodeToString(result.statusCode)}';
    }
    final allItems = extractReferences(result);

    // Handle continuation points
    var cp = result.continuationPoint;
    while (cp.length > 0) {
      final cpPtr = ua_calloc<raw.UA_ByteString>();
      cpPtr.ref = cp;
      final nextResult = raw.UA_Server_browseNext(_server, false, cpPtr);
      allItems.addAll(extractReferences(nextResult));
      cp = nextResult.continuationPoint;
      ua_calloc.free(cpPtr);
    }

    ua_calloc.free(bd);
    return allItems;
  }

  /// Recursively walks the address space tree starting from [root].
  ///
  /// Returns a list of [BrowseTreeItem] with depth and parent info.
  /// Cycle-safe: tracks visited nodes.
  List<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {NodeClass.UA_NODECLASS_OBJECT, NodeClass.UA_NODECLASS_VIEW},
  }) {
    final results = <BrowseTreeItem>[];
    final visited = <NodeId>{};

    void walk(NodeId nodeId, int depth) {
      if (depth > maxDepth) return;
      if (visited.contains(nodeId)) return;
      visited.add(nodeId);

      final children = browse(nodeId, referenceTypeId: referenceTypeId, includeSubtypes: includeSubtypes);

      for (final child in children) {
        results.add(BrowseTreeItem(item: child, depth: depth, parentNodeId: nodeId));
        if (recurseInto.contains(child.nodeClass)) {
          walk(child.nodeId, depth + 1);
        }
      }
    }

    walk(root, 0);
    return results;
  }

  // populate structschema for out type
  void addCustomType(NodeId typeId, DynamicValue value) {
    final array = ua_calloc<raw.UA_DataTypeArray>();
    if (!value.isObject) {
      throw 'Value must be a object';
    }
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

    var totalMemSize = 0;
    for (var i = 0; i < memberCount; i++) {
      final entry = value.asObject.entries.elementAt(i);
      final member = entry.value;
      final memberName = entry.key;
      if (member.isObject && _findDataType(member.typeId!) == ffi.nullptr) {
        // If we contain a member add that first
        addCustomType(member.typeId!, member);
      }
      final memberType = _findDataType(member.typeId!);
      array.ref.types[0].members[i].memberName = memberName.toNativeUtf8(allocator: ua_malloc).cast();
      array.ref.types[0].members[i].memberType = memberType;
      array.ref.types[0].members[i].isOptional = member.isOptional;
      array.ref.types[0].members[i].isArray = member.isArray;

      // Calculate padding for proper alignment
      final memberMemSize = memberType.ref.memSize;
      final alignment = memberMemSize.clamp(1, 8);
      final misalignment = totalMemSize % alignment;
      final padding = misalignment == 0 ? 0 : alignment - misalignment;
      array.ref.types[0].members[i].padding = padding;
      totalMemSize += padding + memberMemSize;
    }
    array.ref.types[0].memSize = totalMemSize;

    // Have open62541 clear the pointers we are allocating here on configuration clean-up
    array.ref.cleanup = true;
    array.ref.next = _config.ref.customDataTypes;
    _config.ref.customDataTypes = array;
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
