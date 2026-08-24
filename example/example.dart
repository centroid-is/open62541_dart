import 'dart:io';

import 'package:open62541/open62541.dart';

/// Minimal open62541 client: connect to an OPC UA server and read the
/// current server time.
///
/// Usage:
///   dart run example/example.dart opc.tcp://localhost:4840
void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run example/example.dart <endpoint>');
    print('Example: dart run example/example.dart opc.tcp://localhost:4840');
    exit(1);
  }
  final endpoint = args[0];

  final client = Client();

  print('Connecting to $endpoint ...');
  client.connect(endpoint);

  // Drive the client event loop in the background.
  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  await client.awaitConnect();
  print('Connected!');

  final serverTime = await client.read(NodeId.serverStatusCurrentTime);
  print('Server time: ${serverTime.asDateTime}');

  client.disconnect();
  await client.delete();
}
