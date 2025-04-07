// TODO: Put public facing types in this file.
// import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:open62541_bindings/src/client.dart';
import 'package:open62541_bindings/src/nodeId.dart';
import 'package:open62541_bindings/src/library.dart';

void clientIsolate(SendPort mainSendPort) {
  Client c = Client(Open62541Singleton().lib);

  c.config.stateStream.listen(
      (event) => mainSendPort.send('Channel state: ${event.channelState}'));

  c.config.subscriptionInactivityStream
      .listen((event) => mainSendPort.send('inactive subscription $event'));

  String endpointUrl = 'opc.tcp://172.30.118.23:4840';
  var statusCode = c.connect(endpointUrl);
  mainSendPort.send('Endpoint url: $endpointUrl');

  if (statusCode == 0) {
    mainSendPort.send('Client connected!');
  } else {
    c.close();
    mainSendPort.send('EXIT');
    return;
  }

  NodeId currentTime = NodeId.numeric(0, 2258);
  try {
    int subId = c.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 10));
    mainSendPort.send('Created subscription $subId');
    final monId = c.monitoredItemCreate<DateTime>(currentTime, subId, (data) {
      print('print DATA: $data');
      mainSendPort.send('DATA: $data');
    });
  } catch (error) {
    mainSendPort.send('ERROR: $error');
    c.close();
    mainSendPort.send('EXIT');
    return;
  }

  var startTime = DateTime.now().millisecondsSinceEpoch;
  while (true) {
    c.runIterate(Duration(milliseconds: 100));
    if (startTime < DateTime.now().millisecondsSinceEpoch - 5000) {
      break;
    }
  }

  mainSendPort.send('CLOSING CLIENT');
  c.close();
  mainSendPort.send('EXIT');
}

Future<int> main() async {
  final receivePort = ReceivePort();

  // Start client in separate isolate
  await Isolate.spawn(clientIsolate, receivePort.sendPort);

  // Listen for messages from client isolate
  await for (final message in receivePort) {
    if (message == 'EXIT') {
      break;
    } else if (message.startsWith('DATA: ')) {
      // Handle subscription data
      print('Received subscription data: ${message.substring(6)}');
      print('message: $message');
    } else {
      // Print other messages
      print(message);
    }
  }

  return 0;
}
