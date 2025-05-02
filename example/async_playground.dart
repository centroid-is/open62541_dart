import 'package:open62541/open62541.dart';

Future<void> main(List<String> arguments) async {
  Client c = Client(Open62541Singleton().lib, secureChannelLifeTime: Duration(seconds: 20));

  c.config.stateStream.listen((event) => print('State: $event'));

  c.config.subscriptionInactivityStream.listen((event) => print('inactive subscription $event'));

  // Parse the endpoint url from the command line
  String endpointUrl = "opc.tcp://10.50.20.99:4840";

  print('Endpoint url: $endpointUrl');

  // Run the c execution loop from the same isolate
  () async {
    // Outer connect loop
    while (c.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  await c.connect(endpointUrl).onError((error, stacktrace) {
    throw 'Error connecting: $error';
  });

  // final start = DateTime.now();

  final counterId = NodeId.fromString(4, "GVL_BatchLines.Drives_Line1[1].HMI");
  final subscriptionId = await c.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
  print("Subscription created");
  c
      .monitoredItem(counterId, subscriptionId, samplingInterval: Duration(milliseconds: 10))
      .listen((data) => print(data));

  // while (true) {

  //   // Resubscribe once a new session is created
  //   await c.config.stateStream
  //       .firstWhere((element) => element.sessionState == UA_SessionState.UA_SESSIONSTATE_CREATE_REQUESTED);
  //   await c.config.stateStream
  //       .firstWhere((element) => element.sessionState == UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
  //   print("Subscription has been lost, will be recreated");
  // }
  await Future.delayed(Duration(seconds: 10));

  c.delete();
}
