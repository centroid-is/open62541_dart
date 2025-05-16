/*
   An example of a client that tries to reconnect to the server and keep a
   single monitored item alive.
*/

import 'package:open62541/open62541.dart';
import 'dart:io';

void main(List<String> args) async {
  final certificate = await File("client_cert.der").readAsBytes();
  final privateKey = await File("client_key.der").readAsBytes();

  if (args.isEmpty) {
    print("Usage: resilient_client <endpoint> <optional:username> <optional:password>");
    exit(1);
  }
  final endpoint = args[0];

  final username = args.length < 2 ? null : args[1];
  final password = args.length < 3 ? null : args[2];
  print("Connecting to server ($endpoint) as $username");
  var c = Client(
    Open62541Singleton().lib,
    username: username,
    password: password,
    securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
    certificate: certificate,
    privateKey: privateKey,
  );

  final id = NodeId.serverStatusCurrentTime;

  c.config.subscriptionInactivityStream.listen((value) => print("Subscription Inactivity: $value"));
  c.config.inactivityStream.listen((value) => print("Inactivity"));
  bool sessionLost = true;
  c.config.stateStream.listen((value) async {
    print("State: $value");
    if (value.sessionState == SessionState.UA_SESSIONSTATE_CREATE_REQUESTED) {
      sessionLost = true;
    }
    // Recreate our subscriptions
    if (value.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED && sessionLost) {
      sessionLost = false;
      final subscriptionId = await c.subscriptionCreate();
      c.monitoredItems({
        id: [AttributeId.UA_ATTRIBUTEID_VALUE],
      }, samplingInterval: Duration(milliseconds: 3000), subscriptionId).listen((value) {
        print(value.values.first.asDateTime);
      });
    }
  });

  () async {
    while (true) {
      c.connect(endpoint);
      while (c.runIterate(Duration(milliseconds: 10))) {
        await Future.delayed(Duration(milliseconds: 10));
      }
      c.disconnect(); // Sometimes it seems that outstanding publish requests are not zeroed out.
      // Leading to a publishreponse exhaustion. ie. when the server recovers we dont send any
      // new publish requests.
      await Future.delayed(Duration(seconds: 1));
    }
  }();

  await c.awaitConnect();
}
