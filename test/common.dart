import 'package:open62541/open62541.dart';

// Every test server is started with `port: 0` and its port read back through
// `Server.port`: the OS picks a free port and the server holds it from that
// moment, so servers started at the same time by the suites `dart test` runs
// in parallel never share one. A probe that binds port 0, closes, and hands
// the number to a server that binds it moments later is a race: the OS may
// hand the same number out again in between, and open62541's listen sockets
// are SO_REUSEPORT, so two servers given one port BOTH bind it and the
// connections are split between them. See port_allocation_test.dart.

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

/// Starts a server on a port the OS picks (read it from `Server.port`) and
/// pumps it until it is shut down.
Server setupServer({LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR}) {
  final server = Server(port: 0, logLevel: logLevel);
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
  // 127.0.0.1, not localhost: the client connects to the first address the
  // name resolves to (::1 on many hosts), and it is the IPv4 listen socket
  // that owns the OS-picked port; the IPv6 socket binds that number second.
  await client.connect("opc.tcp://127.0.0.1:$port").onError((error, stackTrace) {
    throw Exception("Failed to connect to the server: $error");
  });

  return client;
}
