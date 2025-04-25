import 'dart:io';

import 'package:open62541/open62541.dart';

Future<int> main(List<String> arguments) async {
  Client c = Client(Open62541Singleton().lib);

  c.config.stateStream.listen((event) => print('Channel state: ${event.channelState}'));

  c.config.subscriptionInactivityStream.listen((event) => print('inactive subscription $event'));

  // Parse the endpoint url from the command line
  String endpointUrl = "opc.tcp://172.30.118.178:4840";

  print('Endpoint url: $endpointUrl');

  // Run the c execution loop from the same isolate
  () async {
    var statusCode = c.connect(endpointUrl);
    if (statusCode != UA_STATUSCODE_GOOD) {
      stderr.write("Not connected. retrying in 10 milliseconds");
    }
    while (c.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  // final start = DateTime.now();
  // final counterId = NodeId.fromString(4, "MAIN.nCounter");
  print("Start");
  final hmi_data_type_id = NodeId.fromString(4, "<StructuredDataType>:ST_Drive_HMI");
  final data_t_definition = await c.readDataTypeDefinition(hmi_data_type_id);
  c.defs.addAll(data_t_definition);
  print(data_t_definition);
  final hmi_struct = NodeId.fromString(4, "GVL_HMI.Drives_Line1[1].HMI");
  final hmi_struct_value = c.syncReadValue(hmi_struct);
  print(hmi_struct_value);
  final hmi_struct_value2 = await c.readValue(hmi_struct);
  print(hmi_struct_value2);
  print("End");

  await Future.delayed(Duration(seconds: 2));

  // final subscriptionId = c.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
  // final subscription = c.monitoredItemStream(counterId, subscriptionId, samplingInterval: Duration(milliseconds: 10));

  // subscription.listen((event) {
  //   print('Subscription event: $event');
  // });

  // while (start.isAfter(DateTime.now().subtract(Duration(seconds: 10)))) {
  //   try {
  //     DynamicValue value = await c.readValue(counterId);
  //     print('Read value: $value');

  //     // write a new value to trigger the subscription
  //     value.value = value.value + 1;
  //     await c.writeValue(counterId, value);
  //   } catch (e) {
  //     print(e);
  //   }
  // }

  c.delete();
  return 0;
}
