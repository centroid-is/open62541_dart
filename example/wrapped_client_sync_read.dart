// TODO: Put public facing types in this file.
// import 'dart:ffi';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:open62541_bindings/src/client.dart';
import 'package:open62541_bindings/src/dynamic_value.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart'
    as raw;
import 'package:open62541_bindings/src/node_id.dart';
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

    // // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB"));
    // c.readDataTypeAttribute(NodeId.string(4, "GVL_IO.single_SB.a_struct"));

    // NodeId sb = NodeId.fromString(4, "GVL_IO.single_SB");
    // final monId = c.monitoredItemCreate(sb, subId, (data) {
    //   print('print data: $data');
    //   mainSendPort.send('DATA: $data');
    // });
    // NodeId foo = NodeId.fromString(4, "GVL_IO.single_SB.a_struct.i_xStrings");
    // final fooMonId = c.monitoredItemCreate(foo, subId, (data) {
    //   print('print foo DATA: $data');
    //   mainSendPort.send('foo DATA: $data');
    // });

    // NodeId sb2 = NodeId.fromString(4, "GVL_HMI.Drives_Line2");
    // final monId2 = c.monitoredItemCreate(sb2, subId, (data) {
    //   print('print data: $data');
    //   mainSendPort.send('DATA: $data');
    // });

    // Test writing value attribute
    // boolean
    NodeId toWrite =
        NodeId.fromString(4, "MAIN.lines[1][1].xInUse"); // The bool to write
    final currentValue = c.readValue(toWrite);
    print("Current value : $currentValue");
    c.writeValue(toWrite, DynamicValue(value: false, typeId: NodeId.boolean));

    // int16
    DynamicValue curr;
    NodeId int16ToWrite =
        NodeId.fromString(4, "MAIN.nCounter"); // The bool to write
    curr = c.readValue(int16ToWrite);
    c.writeValue(int16ToWrite,
        DynamicValue(value: curr.asInt + 1, typeId: NodeId.int16));

    NodeId nreal = NodeId.fromString(4, "GVL_HMI.Drives_Line1[1].i_rFreq");
    var currReal = c.readValue(nreal);
    c.writeValue(nreal,
        DynamicValue(value: currReal.asDouble + 0.1337, typeId: NodeId.float));

    var arrayReadTest = [
      "GVL_HMI.bool_array",
      "GVL_HMI.dint_array",
      "GVL_HMI.udint_array",
      "GVL_HMI.uint_array",
      "GVL_HMI.int_array",
    ];

    print("Arrays begin");
    for (var value in arrayReadTest) {
      NodeId id = NodeId.fromString(4, value);
      print(c.readValue(id));
    }
    print("Arrays end");

    print("Bool array write things");
    NodeId nBoolArray = NodeId.fromString(4, "GVL_HMI.bool_array");
    var bArray = c.readValue(nBoolArray);
    // Invert bArray
    for (int i = 0; i < bArray.asArray.length; i++) {
      bArray[i] = !bArray[i].asBool;
    }
    c.writeValue(nBoolArray, bArray);

    print("int array write things");
    NodeId nIntArray = NodeId.fromString(4, "GVL_HMI.int_array");
    var iArray = c.readValue(nIntArray);
    // Invert bArray
    for (int i = 0; i < iArray.asArray.length; i++) {
      iArray[i] = iArray[i].asInt + i;
    }
    c.writeValue(nIntArray, iArray);

    print("uint array write things");
    NodeId unIntArray = NodeId.fromString(4, "GVL_HMI.uint_array");
    var uArray = c.readValue(unIntArray);
    // Invert bArray
    for (int i = 0; i < uArray.asArray.length; i++) {
      uArray[i] = uArray[i].asInt + i;
    }
    c.writeValue(unIntArray, uArray);

    NodeId dIntArray = NodeId.fromString(4, "GVL_HMI.dint_array");
    var dArray = c.readValue(dIntArray);
    // Invert bArray
    for (int i = 0; i < dArray.asArray.length; i++) {
      dArray[i] = 1 + dArray[i].asInt;
    }
    c.writeValue(dIntArray, dArray);

    print("udint array write things");
    NodeId udIntArray = NodeId.fromString(4, "GVL_HMI.udint_array");
    var udArray = c.readValue(udIntArray);
    // Invert bArray
    for (int i = 0; i < udArray.asArray.length; i++) {
      udArray[i] = i + udArray[i].asInt;
    }
    c.writeValue(udIntArray, udArray);

    // print("writing struct and stuff");
    // NodeId sId = NodeId.fromString(4, "GVL_IO.single_SB");
    // var value = c.readValue(sId);
    // print(value);

    NodeId tId = NodeId.fromString(4, "GVL_HMI.t");
    print("Time: ${c.readValue(tId)}");

    NodeId dId = NodeId.fromString(4, "GVL_HMI.d");
    print("Date: ${c.readValue(dId)}");

    // void printVariant(ffi.Pointer<raw.UA_Variant> lval) {
    //   print(lval.ref.type.ref.typeName.cast<Utf8>().toDartString());
    //   print(lval.ref.type.ref.typeId.format());
    //   print((lval.ref.type.address -
    //           Open62541Singleton().lib.addresses.UA_TYPES.address) /
    //       ffi.sizeOf<raw.UA_DataType>());
    //   print(lval.ref.type.ref.members);
    //   print(lval.ref.storageType);
    //   print(lval.ref.arrayLength);

    //   print("Substitute");
    //   raw.UA_DataType t = lval.ref.type.ref;
    //   print(lval.ref.type.ref.substitute);
    //   print(t.memSize);
    //   print(t.typeKind);
    //   print(t.pointerFree);
    //   print(t.overlayable);
    //   print(t.membersSize);

    //   print("Ext");
    //   final ext = lval.ref.data.cast<raw.UA_ExtensionObject>();
    //   print(ext.ref.encoding);
    //   final length = ext.ref.content.encoded.body.length;
    //   print(length);
    //   var bytes = [];
    //   for (int i = 0; i < length; i++) {
    //     bytes.add(ext.ref.content.encoded.body.data[i]);
    //   }
    //   print(bytes);
    //   print(ext.ref.content.encoded.typeId.format());
    // }

    NodeId lId = NodeId.fromString(4, "GVL_HMI.k");

    print("Flipping");
    DynamicValue rr = c.readValue(lId);
    print(rr);
    rr["bool1"] = !rr["bool1"].asBool;
    rr["bool2"] = !rr["bool2"].asBool;
    c.writeValue(lId, rr);
    await Future.delayed(Duration(milliseconds: 150));

    NodeId sId = NodeId.fromString(4, "GVL_HMI.m");
    print(c.readValue(sId));
    NodeId s2Id = NodeId.fromString(4, "GVL_HMI.n");
    var n = c.readValue(s2Id);
    print(n);
    // todo should we throw if typeid is not declared during assignment?
    n[0]["field1"] = "JBB";
    n[1]["field1"] = "JBB2";
    n[2]["field1"] = "JBB3";
    n[0]["bigfield1"] = "BIGBIGJBB";
    n[1]["bigfield1"] = "BIGBIGJBB2";
    n[2]["bigfield1"] = "BIGBIGJBB3";
    c.writeValue(s2Id, n);
    n = c.readValue(s2Id);
    print(n);

    //    print(curr_real);
    //    c.writeValue(nreal, curr_real + 0.1337);
    //    curr_real = c.readValue(nreal);
    //    await Future.delayed(Duration(milliseconds: 100));
    //  }
    //  c.writeValue(nreal, 1000.0);
    NodeId arr = NodeId.fromString(4, "GVL_IO.single_SB.a_struct.i_xSpare2");
    print("Multidimension baby");
    print(c.readValue(arr));
    print("Multidimension baby");

    NodeId marr = NodeId.fromString(4, "GVL_IO.single_SB.a_struct.i_xSpare3");
    print("Multidimension baby");
    print(c.readValue(marr));
    print("Multidimension baby");

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
