import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

void main() async {
  final lib = loadOpen62541Library(local: true);

  int port = Random().nextInt(10000) + 4840;
  Client? client;
  Server? server;
  final boolNodeId = NodeId.fromString(1, "the.bool");
  final intNodeId = NodeId.fromString(1, "the.int");

  setUp(() async {
    server = Server(lib, port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server!.start();

    // Run the server while we test
    () async {
      while (server!.runIterate()) {
        // The function returns how long it can wait before the next iteration
        // That is a really high number and causes my tests to run slow.
        // Lets just wait 50ms
        await Future.delayed(Duration(milliseconds: 50));
      }
    }();

    {
      // Create a boolean variable to read and write
      DynamicValue boolValue = DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool");
      server!.addVariableNode(boolNodeId, boolValue);
    }
    {
      // Create a int variables to read and write
      DynamicValue intValue = DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int");
      server!.addVariableNode(intNodeId, intValue);
    }

    client = Client(lib, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    // Run the client while we connect
    () async {
      while (client!.runIterate(Duration(milliseconds: 10))) {
        await Future.delayed(Duration(milliseconds: 5));
      }
    }();
    await client!.connect("opc.tcp://localhost:$port").onError((error, stackTrace) {
      throw Exception("Failed to connect to the server: $error");
    });
  });
  test('Basic read and write boolean async', () async {
    expect((await client!.read(boolNodeId)).value, true);
    await client!.writeValue(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));
    expect((await client!.read(boolNodeId)).value, false);
    await client!.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    expect((await client!.read(boolNodeId)).value, true);
  });

  test('Basic subscription', () async {
    // Set current value to false to get a change
    await client!.writeValue(
        boolNodeId,
        DynamicValue(
            value: true,
            typeId: NodeId.boolean)); // It seems we get a value straigt away, make it match the first in the list
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final items = [true, false, true, false];
    final comp = Completer<void>();
    int counter = 0;
    final stream =
        client!.monitor(boolNodeId, subscription, samplingInterval: Duration(milliseconds: 10)).map<bool>((event) {
      counter = counter + 1;
      if (counter == items.length) {
        comp.complete();
      }
      return event.value;
    });
    expect(stream, emitsInOrder(items));
    for (var item in items) {
      await client!.writeValue(boolNodeId, DynamicValue(value: item, typeId: NodeId.boolean));
      await Future.delayed(Duration(milliseconds: 100)); // Give the server and client time to do stuff
    }
    await comp.future;
  });
  test('Multiple monitored items', () async {
    // Set current value to false to get a change
    await client!.writeValue(
        boolNodeId,
        DynamicValue(
            value: true,
            typeId: NodeId.boolean)); // It seems we get a value straigt away, make it match the first in the list
    await client!.writeValue(
        intNodeId,
        DynamicValue(
            value: 1,
            typeId: NodeId.int32)); // It seems we get a value straigt away, make it match the first in the list
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    int boolCounter = 0;
    int intCounter = 0;
    final comp = Completer<void>();
    final items = [true, false, true, false];
    final intItems = [1, 2, 3, 4];
    final boolStream =
        client!.monitor(boolNodeId, subscription, samplingInterval: Duration(milliseconds: 10)).map<bool>((event) {
      boolCounter = boolCounter + 1;
      if (boolCounter == items.length && intCounter == intItems.length) {
        comp.complete();
      }
      return event.value;
    });
    final intStream =
        client!.monitor(intNodeId, subscription, samplingInterval: Duration(milliseconds: 10)).map<int>((event) {
      intCounter = intCounter + 1;
      if (boolCounter == items.length && intCounter == intItems.length) {
        comp.complete();
      }
      return event.value;
    });
    expect(boolStream, emitsInOrder(items));
    expect(intStream, emitsInOrder(intItems));
    expect(items.length, intItems.length);
    for (var i = 0; i < items.length; i++) {
      await client!.writeValue(boolNodeId, DynamicValue(value: items[i], typeId: NodeId.boolean));
      await client!.writeValue(intNodeId, DynamicValue(value: intItems[i], typeId: NodeId.int32));
      await Future.delayed(Duration(milliseconds: 100)); // Give the server and client time to do stuff
    }
    await comp.future;
  });

  test('Creating a subscription and not using it should not hang the process', () async {
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    // ignore: unused_local_variable
    final controller = client!.monitor(boolNodeId, subscription, samplingInterval: Duration(milliseconds: 10));
  });

  test('Create a monitored item and then cancel before it has been created', () async {
    // This test has no expected outcome.
    // A failure of the test is a timeout.

    // Not properly closing callbacks or cleaning up resources will cause the test to hang.
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final stream = client!.monitor(boolNodeId, subscription, samplingInterval: Duration(milliseconds: 10));
    final streamSub = stream.listen((event) => expect(true, false));
    await streamSub.cancel();
  });

  test('Test server and client descriptions', () async {
    final description = LocalizedText("This is a test", "en-US");
    server!.writeDescription(boolNodeId, description);
    final value = await client!.read(boolNodeId);
    expect(value.description, description);
  });

  test('Just run the server so we can connect with a client', () async {
    await Future.delayed(Duration(minutes: 10));
    // expect((await client!.read(boolNodeId)).value, false);
    // await client!.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    // expect((await client!.read(boolNodeId)).value, true);
  }, timeout: Timeout(Duration(minutes: 10)), skip: true);

  test('Partial read failures should return partial data', () async {
    final doesNotExist = NodeId.fromString(1, "does.not.exist");
    final value = await client!.readAttribute({
      boolNodeId: [
        // Should this entire nodeid be a failure?
        AttributeId.UA_ATTRIBUTEID_VALUE, // This succeeds
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION, // This succeeds
        AttributeId.UA_ATTRIBUTEID_ROLEPERMISSIONS, // This fails
      ],
      doesNotExist: [
        AttributeId.UA_ATTRIBUTEID_VALUE, // This fails
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION, // This fails
        AttributeId.UA_ATTRIBUTEID_ROLEPERMISSIONS, // This fails
      ]
    });

    expect(value.length, 2);
    expect(value[boolNodeId], isNotNull);
    expect(value[boolNodeId]!.value, isNotNull);
    expect(value[boolNodeId]!.description, isNotNull);

    expect(value[doesNotExist], isNotNull);
    expect(value[doesNotExist]!.value, isNull);
    expect(value[doesNotExist]!.description, isNull);
  }, skip: true);

  test('Update data from the server', () async {
    server!.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    expect((await client!.read(boolNodeId)).value, true);
    expect(server!.readValue(boolNodeId).value, true);
    server!.writeValue(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));
    expect((await client!.read(boolNodeId)).value, false);
    expect(server!.readValue(boolNodeId).value, false);
  });

  test('Read a basic struct from a server', () async {
    final structureVariableNodeId = NodeId.fromString(1, "structureVariable");
    final myStructureTypeId = NodeId.fromString(1, "myStructureType");
    DynamicValue structureValue = DynamicValue(name: "My Structure Variable", typeId: myStructureTypeId);
    structureValue["a"] = DynamicValue(value: 0, typeId: NodeId.int32);
    structureValue["b"] = DynamicValue(value: true, typeId: NodeId.boolean);
    structureValue["c"] = DynamicValue(value: 5.8, typeId: NodeId.double);

    server!.addCustomType(myStructureTypeId, structureValue);

    server!.addDataTypeNode(myStructureTypeId, "myStructureType",
        displayName: LocalizedText("My Structure Type", "en-US"));
    //server.addVariableTypeNode(structureValue, myStructureTypeId, "Very good name");
    server!.addVariableNode(structureVariableNodeId, structureValue,
        accessLevel: AccessLevelMask(read: true, write: true), typeId: myStructureTypeId);

    final value = await client!.read(structureVariableNodeId);
    expect(value.isObject, isTrue);
    expect(value.typeId, myStructureTypeId);
    expect(value.asObject.length, 3);
    expect(value.asObject["a"]!.value, 0);
    expect(value.asObject["b"]!.value, true);
    expect(value.asObject["c"]!.value, 5.8);
  });

  tearDown(() async {
    server!.shutdown();

    await client!.delete();

    server!.delete();
  });
}
