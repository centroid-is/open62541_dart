import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'extensions.dart';
import 'generated/open62541_bindings.dart' as raw;

class Server {
  Server(raw.open62541 lib) {
    _lib = lib;
    _server = _lib.UA_Server_new();
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
  void addVariableNode(
    NodeId variableNodeId,
    DynamicValue value, {
    AccessLevelMask accessLevel = const AccessLevelMask(read: true, write: true),
    NodeId? parentNodeId,
    NodeId? parentReferenceNodeId,
    NodeId? basedatavariableType,
  }) {
    ffi.Pointer<raw.UA_VariableAttributes> attr = calloc<raw.UA_VariableAttributes>();
    attr.ref = _lib.UA_VariableAttributes_default;
    final variant = valueToVariant(value, _lib);
    attr.ref.value = variant.ref;
    attr.ref.accessLevel = accessLevel.value;
    attr.ref.dataType = value.typeId!.toRaw(_lib);

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
      throw 'Failed to add variable node ${statusCodeToString(returnCode, _lib)}';
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
