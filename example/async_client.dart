import 'dart:io';

import 'package:open62541/open62541.dart';

Future<int> main(List<String> arguments) async {
  Client c = Client(Open62541Singleton().lib);

  c.config.stateStream.listen((event) => print('Channel state: ${event.channelState}'));

  c.config.subscriptionInactivityStream.listen((event) => print('inactive subscription $event'));

  // Parse the endpoint url from the command line
  String endpointUrl = '';
  if (arguments.isNotEmpty) {
    endpointUrl = arguments[0];
  } else {
    print('Usage: async_client <endpoint_url>');
    return -1;
  }

  print('Endpoint url: $endpointUrl');

  // Run the c execution loop from the same isolate
  () async {
    while (c.runIterate(Duration(milliseconds: 0))) {
      await Future.delayed(Duration(milliseconds: 5));
    }
  }();

  await c.connect(endpointUrl).onError((error, stacktrace) {
    throw "Error connecting $error";
  });

  print("Connected");

  final start = DateTime.now();
  final counterId = NodeId.fromString(4, "MAIN.lines[1][1].rLength");

  final subscriptionId = await c.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
  print(subscriptionId);
  final subscription = c.monitoredItem(counterId, subscriptionId, samplingInterval: Duration(milliseconds: 10));

  subscription.stream.listen((event) {
    print('Subscription event: $event');
  });

  while (start.isAfter(DateTime.now().subtract(Duration(seconds: 1)))) {
    DynamicValue value = await c.readValue(counterId).onError((error, stacktrace) {
      print('Error reading value: $error');
      return DynamicValue(value: 0, typeId: NodeId.int32);
    });

    print('Value: ${value.value}');

    // write a new value to trigger the subscription
    value.value = value.value + 1;
    await c.writeValue(counterId, value).onError((error, stacktrace) {
      print('Error writing value: $error');
    });
  }

  await Future.delayed(Duration(milliseconds: 10)); // Let the subscription catch up

  stderr.writeln('Closing subscription');
  await subscription.close();
  stderr.writeln('Deleting client');
  await c.delete();
  stderr.writeln('Deleted client');
  return 0;
}
