// TODO: Put public facing types in this file.
// import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:open62541_bindings/src/client.dart';
import 'package:open62541_bindings/src/nodeId.dart';
import 'package:open62541_bindings/src/library.dart';
import 'package:open62541_bindings/src/extensions.dart';

void clientIsolate(SendPort mainSendPort) async {
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

  try {
    int subId = c.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 5));
    mainSendPort.send('Created subscription $subId');

    // final definition =
    //     c.readValueAttribute(NodeId.string(4, "#Type|ST_SpeedBatcher"));
    // print("definition: $definition");
    //<StructuredDataType>:ST_SpeedBatcher

    final schema = c.variableToSchema(NodeId.string(4, "GVL_IO.single_SB"));
    print("got schema: $schema");

    // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB"));
    // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB.a_struct"));

    NodeId sb = NodeId.string(4, "GVL_IO.single_SB");
    final monId = c.monitoredItemCreate<dynamic>(sb, subId, (data) {
      print('print DATA: $data');
      mainSendPort.send('SB DATA: $data');
    });

    NodeId outSignal = NodeId.string(4, "GVL_IO.single_SB.i_xBatchReady");
    final outSignalMonId =
        c.monitoredItemCreate<bool>(outSignal, subId, (data) {
      print('print DATA: $data');
      mainSendPort.send('Out signal DATA: $data');
    });
  } catch (error) {
    mainSendPort.send('ERROR: $error');
    c.close();
    mainSendPort.send('EXIT');
    return;
  }

  // Add signal handler
  ProcessSignal.sigint.watch().listen((signal) {
    print('Shutting down client gracefully...');
    c.close();
    mainSendPort.send('EXIT');
  });

  while (true) {
    try {
      c.runIterate(Duration(milliseconds: 10));
      // Add small delay to allow event loop to process
      await Future.delayed(Duration(milliseconds: 1));
    } catch (error) {
      print('Error: $error');
      break;
    }
  }

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
