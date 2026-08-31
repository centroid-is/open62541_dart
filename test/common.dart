import 'dart:io';

import 'package:open62541/open62541.dart';

/// Returns a TCP port that is free right now, allocated by the OS.
///
/// `dart test` runs suite files in PARALLEL, so tests that picked ports with
/// `Random().nextInt(10000) + 4840` could collide across concurrently running
/// suites: two servers racing to bind the same port, or worse, a client
/// connecting to another suite's server that then tears down mid-session
/// (broken pipe -> service faults with zero results). Binding port 0 lets the
/// OS hand out a port from its ephemeral range, which both avoids
/// suite-vs-suite collisions and stays clear of 4840-14839, where local
/// Docker rigs commonly publish OPC UA ports.
///
/// The tiny window between closing the probe socket and the server binding
/// the port is safe in practice: the OS does not reuse an ephemeral port it
/// just handed out while other ports remain available.
Future<int> freeTcpPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
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

Server setupServer(int port, {LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR}) {
  final server = Server(port: port, logLevel: logLevel);
  server.start();

  // Run the server while we test.
  // runIterate() defaults to a non-blocking poll, so this loop cooperates
  // with other servers/clients pumped on the same isolate. The 50ms delay
  // is REQUIRED to throttle the loop and avoid a 100% CPU busy-spin.
  () async {
    while (server.runIterate()) {
      await Future.delayed(Duration(milliseconds: 50));
    }
  }();
  return server;
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
