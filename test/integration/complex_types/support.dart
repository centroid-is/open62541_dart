// Shared helpers for the COMPLEX TYPES category.
//
// Spins up a real Dart `Server` (own OPC UA server) plus a driven `Client`, and
// tears them down in the correct order (client first, then server) to avoid the
// native use-after-free that the library is sensitive to. Everything round-trips
// through the real server + client — no in-memory-only encode.

import 'dart:async';

import 'package:open62541/open62541.dart';

/// A live Dart server + connected client pair for round-trip tests.
class ServerClient {
  ServerClient(this.server, this.client, this._stop);

  final Server server;
  final ClientApi client;
  final Future<void> Function() _stop;

  Future<void> dispose() => _stop();
}

/// Brings up a Dart [Server] on a free port and a connected [Client], both
/// pumped by fire-and-forget iterate loops (mirrors test/common.dart).
Future<ServerClient> startServerClient(
  int port, {
  LogLevel serverLog = LogLevel.UA_LOGLEVEL_ERROR,
  LogLevel clientLog = LogLevel.UA_LOGLEVEL_FATAL,
}) async {
  final server = Server(port: port, logLevel: serverLog);
  server.start();
  var running = true;
  unawaited(() async {
    while (running && server.runIterate()) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }());

  final client = Client(logLevel: clientLog);
  unawaited(() async {
    while (running && client.runIterate(const Duration(milliseconds: 10))) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }());
  await client.connect('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));

  Future<void> stop() async {
    running = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await client.delete();
    server.shutdown();
    server.delete();
  }

  return ServerClient(server, client, stop);
}

/// Registers a (possibly nested) struct type on the server so that a client can
/// decode it: every custom-struct type in the tree needs both an entry in the
/// server's `customDataTypes` (via [Server.addCustomType], which recurses into
/// members) AND a DataType node in the address space (via
/// [Server.addDataTypeNode]) — otherwise the client hangs building the schema
/// for a member type that has no DataType node.
void registerStructType(Server server, NodeId rootTypeId, DynamicValue root) {
  server.addCustomType(rootTypeId, root);
  final seen = <String>{};
  void walk(NodeId typeId, DynamicValue v) {
    if (v.isObject) {
      final key = typeId.toString();
      if (seen.add(key)) {
        server.addDataTypeNode(typeId, _browseNameFor(typeId));
      }
      for (final e in v.entries) {
        if (e.value.isObject && e.value.typeId != null) {
          walk(e.value.typeId!, e.value);
        } else if (e.value.isArray &&
            e.value.asArray.isNotEmpty &&
            e.value.asArray.first.isObject &&
            e.value.asArray.first.typeId != null) {
          walk(e.value.asArray.first.typeId!, e.value.asArray.first);
        }
      }
    }
  }

  walk(rootTypeId, root);
}

String _browseNameFor(NodeId typeId) => typeId.string;
