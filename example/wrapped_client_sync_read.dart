// TODO: Put public facing types in this file.
// import 'dart:ffi';
import 'dart:io';

import 'package:open62541_bindings/src/client.dart';
import 'package:open62541_bindings/src/nodeId.dart';
import 'package:open62541_bindings/src/library.dart';

int main() {
  Client c = Client(Open62541Singleton().lib);

  c.config.stateStream
      .listen((event) => print('Channel state: ${event.channelState}'));

  c.config.subscriptionInactivityStream
      .listen((event) => print('inactive subscription $event'));

  // // Pointer<Pointer<UA_EndpointDescription>> endpointDescription = nullptr;
  String endpointUrl = 'opc.tcp://localhost:4840';
  var statusCode = c.connect(endpointUrl);
  print('Endpoint url: $endpointUrl');
  if (statusCode == 0) {
    print('Client connected!');
  } else {
    c.close();
    exit(-1);
  }

  NodeId currentTime = NodeId.numeric(0, 2258);
  print("Starting read loop");
  for (int i = 0; i < 10; i++) {
    try {
      print(c.readValueAttribute(currentTime));
    } catch (error) {
      print(error);
      c.close();
      exit(-1);
    }
    sleep(Duration(milliseconds: 100));
  }

  print('Read complete');
  print('Subscription!');
  try {
    int subId = c.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 10));
    print('Created subscription $subId');
    c.monitoredItemCreate(
        currentTime, subId, (dynamic data) => print("got $data"),
        samplingInterval: Duration(milliseconds: 10));
  } catch (error) {
    print(error);
    c.close();
    exit(-1);
  }

  print('setup complete');

  var startTime = DateTime.now().millisecondsSinceEpoch;
  while (true) {
    c.runIterate(Duration(milliseconds: 100));
    if (startTime < DateTime.now().millisecondsSinceEpoch - 5000) {
      break;
    }
  }
  print('CLOSING CLIENT');
  c.close();
  print('Exiting');
  return 0;
}
