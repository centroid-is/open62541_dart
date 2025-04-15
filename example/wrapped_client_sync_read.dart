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

    final schema = c.variableToSchema(NodeId.string(4, "GVL_HMI.Drives_Line2"));
    print("got schema: $schema");

    // // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB"));
    // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB.a_struct"));

    NodeId sb = NodeId.string(4, "GVL_IO.single_SB");
    final monId = c.monitoredItemCreate<dynamic>(sb, subId, (data) {
      print('print data: $data');
      mainSendPort.send('DATA: $data');
    });
    NodeId foo = NodeId.string(4, "GVL_IO.single_SB.a_struct.i_xStrings");
    final fooMonId = c.monitoredItemCreate<List<dynamic>>(foo, subId, (data) {
      print('print foo DATA: $data');
      mainSendPort.send('foo DATA: $data');
    });
    // NodeId sb = NodeId.string(4, "GVL_HMI.Drives_Line2");
    // final monId = c.monitoredItemCreate<dynamic>(sb, subId, (data) {
    //   print('print data: $data');
    //   mainSendPort.send('DATA: $data');
    // });

    // Test writing value attribute
    // boolean
    NodeId toWrite =
        NodeId.string(4, "MAIN.lines[1][1].xInUse"); // The bool to write
    final current_value = c.readValue(toWrite);
    print("Current value : $current_value");
    c.writeValue(toWrite, false, TypeKindEnum.boolean);

    // int16
    int curr = 0;
    NodeId int16ToWrite =
        NodeId.string(4, "MAIN.nCounter"); // The bool to write
    curr = c.readValue(int16ToWrite);
    c.writeValue(int16ToWrite, curr + 1, TypeKindEnum.int16);

    NodeId nreal = NodeId.string(4, "GVL_HMI.Drives_Line1[1].i_rFreq");
    var currReal = c.readValue(nreal);
    c.writeValue(nreal, currReal + 0.1337, TypeKindEnum.float);

    var arrayReadTest = [
      "GVL_HMI.bool_array",
      "GVL_HMI.dint_array",
      "GVL_HMI.udint_array",
      "GVL_HMI.uint_array",
      "GVL_HMI.int_array",
    ];

    print("Arrays begin");
    for (var value in arrayReadTest) {
      NodeId id = NodeId.string(4, value);
      print(c.readValue(id));
    }
    print("Arrays end");

    print("Bool array write things");
    NodeId nBoolArray = NodeId.string(4, "GVL_HMI.bool_array");
    List<dynamic> bArray = c.readValue(nBoolArray);
    // Invert bArray
    for (int i = 0; i < bArray.length; i++) {
      bArray[i] = !bArray[i];
    }
    c.writeValue(nBoolArray, bArray, TypeKindEnum.boolean);

    print("int array write things");
    NodeId nIntArray = NodeId.string(4, "GVL_HMI.int_array");
    List<dynamic> iArray = c.readValue(nIntArray);
    // Invert bArray
    for (int i = 0; i < iArray.length; i++) {
      iArray[i] = iArray[i] + i;
    }
    c.writeValue(nIntArray, iArray, TypeKindEnum.int16);

    print("uint array write things");
    NodeId unIntArray = NodeId.string(4, "GVL_HMI.uint_array");
    List<dynamic> uArray = c.readValue(unIntArray);
    // Invert bArray
    for (int i = 0; i < uArray.length; i++) {
      uArray[i] = uArray[i] + i;
    }
    c.writeValue(unIntArray, uArray, TypeKindEnum.uint16);

    print("dint array write things");
    NodeId dIntArray = NodeId.string(4, "GVL_HMI.dint_array");
    List<dynamic> dArray = c.readValue(dIntArray);
    // Invert bArray
    for (int i = 0; i < dArray.length; i++) {
      dArray[i] = i + dArray[i];
    }
    c.writeValue(dIntArray, dArray, TypeKindEnum.int32);

    print("udint array write things");
    NodeId udIntArray = NodeId.string(4, "GVL_HMI.udint_array");
    List<dynamic> udArray = c.readValue(udIntArray);
    // Invert bArray
    for (int i = 0; i < udArray.length; i++) {
      udArray[i] = i + udArray[i];
    }
    c.writeValue(udIntArray, udArray, TypeKindEnum.uint32);

    print("writing struct and stuff");
    NodeId sId = NodeId.string(4, "GVL_IO.single_SB");
    var value = c.readValue(sId);
    print(value);

    NodeId tId = NodeId.string(4, "GVL_HMI.t");
    print("Time: ${c.readValue(tId)}");

    NodeId dId = NodeId.string(4, "GVL_HMI.d");
    print("Date: ${c.readValue(dId)}");

    NodeId lId = NodeId.string(4, "GVL_IO.single_SB");
    var lval = c.readValue(lId);
    print(lval);
    print(lval["jbb"]);
    lval["jbb"] = !lval["jbb"].asBool();
    print(lval);
    throw 'Done';
    c.writeValue(lId, lval, TypeKindEnum.extensionObject);
    //    print(curr_real);
    //    c.writeValue(nreal, curr_real + 0.1337);
    //    curr_real = c.readValue(nreal);
    //    await Future.delayed(Duration(milliseconds: 100));
    //  }
    //  c.writeValue(nreal, 1000.0);
    // NodeId arr = NodeId.string(4, "GVL_IO.single_SB.a_struct.i_xSpare2");
    // final arrMonId = c.monitoredItemCreate<dynamic>(arr, subId, (data) {
    //   print('print arr DATA: $data');
    //   mainSendPort.send('Arr DATA: $data');
    // });

    // NodeId outSignal = NodeId.string(4, "GVL_IO.single_SB.i_xBatchReady");
    // final outSignalMonId =
    //     c.monitoredItemCreate<bool>(outSignal, subId, (data) {
    //   print('print DATA: $data');
    //   mainSendPort.send('Out signal DATA: $data');
    // });
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
      // print('Received subscription data: ${message.substring(6)}');
      // print('message: $message');
    } else {
      // Print other messages
      print(message);
    }
  }

  return 0;
}
