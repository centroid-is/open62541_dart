import 'package:ffi/ffi.dart';

import 'generated/open62541_bindings.dart' as raw;
import 'dart:ffi' as ffi;

class Server {
  Server(raw.open62541 lib) {
    _lib = lib;
    _server = _lib.UA_Server_new();
  }

  late raw.open62541 _lib;
  late ffi.Pointer<raw.UA_Server> _server;

  void start() {
    _lib.UA_Server_run_startup(_server);
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

  String statusCodeToString(int statusCode) {
    return _lib.UA_StatusCode_name(statusCode).cast<Utf8>().toDartString();
  }

  void shutdown() {
    int ret = _lib.UA_Server_run_shutdown(_server);
    if (ret != 0) {
      throw "Failed to shutdown server ${statusCodeToString(ret)}";
    }
  }

  void delete() {
    int ret = _lib.UA_Server_delete(_server);
    if (ret != 0) {
      throw "Failed to delete server ${statusCodeToString(ret)}";
    }
  }
}
