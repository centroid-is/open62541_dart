import 'package:open62541_bindings/open62541_bindings.dart';

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
  var statusCode = c.connect(endpointUrl);
  print('Endpoint url: $endpointUrl');

  if (statusCode == 0) {
    print('Client connected!');
  } else {
    c.close();
    print('EXIT');
    return -1;
  }

  final counterId = NodeId.fromString(4, "MAIN.nCounter");
  Future<DynamicValue> value = c.asyncReadValue(counterId);
  value.then((value) {
    print('Value: ${value.value}');
    value.value = value.value + 1;
    c.asyncWriteValue(counterId, value).then((_) {
      print('Wrote value: ${value.value}');
    });
  });

  // Run for 1 seconds
  final start = DateTime.now();
  while (DateTime.now().difference(start).inSeconds < 1) {
    try {
      c.runIterate(Duration(milliseconds: 150));
      // Add small delay to allow event loop to process
      await Future.delayed(Duration(milliseconds: 1));
    } catch (error) {
      print('Error: $error');
      break;
    }
  }

  c.close();
  return 0;
}
