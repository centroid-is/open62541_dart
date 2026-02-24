import 'dart:async';
import 'dart:typed_data';

import 'package:open62541/open62541.dart';

// Tracks whether the direct client event loop should keep running
bool _directClientRunning = false;

// Factory function to create different client types
Future<ClientApi> createClient(String clientType, int port) async {
  switch (clientType) {
    case 'isolate':
      final client = await ClientIsolate.create();
      // Start event loop BEFORE connect - needed for async operations
      // Catch errors since runIterate fails when connection is closed (expected in tearDown)
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();
      return client;
    case 'direct':
      final client = Client();
      _directClientRunning = true;
      // Start event loop BEFORE connect - needed for async operations
      unawaited(() async {
        while (_directClientRunning && client.runIterate(Duration(milliseconds: 10))) {
          await Future.delayed(Duration(milliseconds: 5));
        }
      }());
      await client.connect("opc.tcp://localhost:$port");
      return client;
    default:
      throw ArgumentError('Unknown client type: $clientType');
  }
}

// Stop the direct client event loop
void stopDirectClientLoop() {
  _directClientRunning = false;
}

final boolNodeId = NodeId.fromString(1, "the.bool");
final intNodeId = NodeId.fromString(1, "the.int");
final doubleNodeId = NodeId.fromString(1, "the.double");
final stringNodeId = NodeId.fromString(1, "the.string");

// Not all tests need this and it is annoying me to have this
// be added while I am debugging other tests.
void addBasicVariables(Server server) {
  // Create a boolean variable to read and write
  DynamicValue boolValue = DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool");
  server.addVariableNode(boolNodeId, boolValue);
  // Create a int variables to read and write
  DynamicValue intValue = DynamicValue(value: 1, typeId: NodeId.int32, name: "the.int");
  server.addVariableNode(intNodeId, intValue);
  // Create a double variables to read and write
  DynamicValue doubleValue = DynamicValue(value: 3.14, typeId: NodeId.double, name: "the.double");
  server.addVariableNode(doubleNodeId, doubleValue);
  // Create a string variables to read and write
  DynamicValue stringValue = DynamicValue(value: "Hello World!", typeId: NodeId.uastring, name: "the.string");
  server.addVariableNode(stringNodeId, stringValue);
}

final _runningServers = <Server>{};

Server setupServer(
  int port, {
  LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR,
  int? maxSecureChannels,
  int? maxSessions,
  Uint8List? certificate,
  Uint8List? privateKey,
  Map<String, String>? users,
  bool allowAnonymous = true,
  bool allowNonePolicyPassword = false,
}) {
  final server = Server(
    port: port,
    logLevel: logLevel,
    maxSecureChannels: maxSecureChannels,
    maxSessions: maxSessions,
    certificate: certificate,
    privateKey: privateKey,
    users: users,
    allowAnonymous: allowAnonymous,
    allowNonePolicyPassword: allowNonePolicyPassword,
  );
  server.start();
  _runningServers.add(server);

  // Run the server while we test
  // Use waitInterval: false to avoid blocking the Dart event loop in select(),
  // which is critical when multiple servers/clients share the same isolate.
  () async {
    while (_runningServers.contains(server) && server.runIterate(waitInterval: false)) {
      await Future.delayed(Duration(milliseconds: 1));
    }
  }();
  return server;
}

void stopServerLoop([Server? server]) {
  if (server != null) {
    _runningServers.remove(server);
  } else {
    _runningServers.clear();
  }
}

Future<Client> setupClient(int port, {LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL}) async {
  final client = Client(logLevel: logLevel);
  // Run the client while we connect
  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 5));
    }
  }();
  await client.connect("opc.tcp://localhost:$port").onError((error, stackTrace) {
    throw Exception("Failed to connect to the server: $error");
  });

  return client;
}

Future<Client> setupClientWithAuth(
  int port, {
  String? username,
  String? password,
  Uint8List? certificate,
  Uint8List? privateKey,
  MessageSecurityMode? securityMode,
  LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL,
}) async {
  final client = Client(
    logLevel: logLevel,
    username: username,
    password: password,
    certificate: certificate,
    privateKey: privateKey,
    securityMode: securityMode,
  );
  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 5));
    }
  }();
  await client.connect("opc.tcp://localhost:$port").onError((error, stackTrace) {
    throw Exception("Failed to connect to the server: $error");
  });
  return client;
}
