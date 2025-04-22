import 'dart:io';

import 'package:open62541_bindings/open62541_bindings.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart';

Future<int> main(List<String> arguments) async {
  Client c = Client(Open62541Singleton().lib);

  c.config.stateStream
      .listen((event) => print('Channel state: ${event.channelState}'));

  c.config.subscriptionInactivityStream
      .listen((event) => print('inactive subscription $event'));

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
    var statusCode = c.connect(endpointUrl);
    if (statusCode != UA_STATUSCODE_GOOD) {
      stderr.write("Not connected. retrying in 10 milliseconds");
    }
    while (true) {
      c.runIterate(Duration(milliseconds: 10));
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  final start = DateTime.now();
  final counterId = NodeId.fromString(4, "MAIN.nCounter");

  final subscriptionId = c.subscriptionCreate(
      requestedPublishingInterval: Duration(milliseconds: 10));
  final subscription = c.monitoredItemStream(counterId, subscriptionId,
      samplingInterval: Duration(milliseconds: 10));

  subscription.listen((event) {
    print('Subscription event: $event');
  });

  while (start.isAfter(DateTime.now().subtract(Duration(seconds: 10)))) {
    try {
      DynamicValue value = await c.asyncReadValue(counterId);
      print('Read value: $value');

      // write a new value to trigger the subscription
      value.value = value.value + 1;
      await c.asyncWriteValue(counterId, value);
    } catch (e) {
      print(e);
    }
  }

  c.delete();
  return 0;
}
