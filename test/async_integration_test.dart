import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'package:test/test.dart';

void main() async {
  final lib = Open62541Singleton().lib;
  Pointer<UA_Server> server = nullptr;
  Client? client;
  final boolNodeId = NodeId.fromString(1, "the.bBool");
  final intNodeId = NodeId.fromString(1, "the.int");
  setUp(() async {
    // Initalize an open62541 server
    server = lib.UA_Server_new();
    lib.UA_Server_run_startup(server);

    // Run the server while we test
    () async {
      while (true) {
        // The true is if the server should wait for messages in the network layer
        // The function returns how long it can wait before the next iteration
        // That is a really high number and causes my tests to run slow.
        // Lets just wait 50ms
        lib.UA_Server_run_iterate(server, true);
        // Check if the server is running
        final state = lib.UA_Server_getLifecycleState(server);
        if (state == UA_LifecycleState.UA_LIFECYCLESTATE_STOPPED) {
          break;
        }
        await Future.delayed(Duration(milliseconds: 10));
      }
    }();

    {
      // Create a boolean variable to read and write
      DynamicValue boolValue = DynamicValue(value: true, typeId: NodeId.boolean);
      Pointer<UA_VariableAttributes> attr = calloc<UA_VariableAttributes>();
      attr.ref = lib.UA_VariableAttributes_default;
      final variant = Client.valueToVariant(boolValue, lib);
      attr.ref.value = variant.ref;
      attr.ref.accessLevel = UA_ACCESSLEVELMASK_READ | UA_ACCESSLEVELMASK_WRITE;
      attr.ref.dataType = NodeId.boolean.toRaw(lib);

      UA_QualifiedName name = lib.UA_QUALIFIEDNAME(1, "the bool".toNativeUtf8().cast());
      UA_NodeId parentNodeId = NodeId.fromNumeric(0, UA_NS0ID_OBJECTSFOLDER).toRaw(lib);
      UA_NodeId parentReferenceNodeId = NodeId.fromNumeric(0, UA_NS0ID_ORGANIZES).toRaw(lib);
      UA_NodeId basedatavariableType = NodeId.fromNumeric(0, UA_NS0ID_BASEDATAVARIABLETYPE).toRaw(lib);
      lib.UA_Server_addVariableNode(server, boolNodeId.toRaw(lib), parentNodeId, parentReferenceNodeId, name,
          basedatavariableType, attr.ref, nullptr, nullptr);
    }
    {
      // Create a int variables to read and write
      DynamicValue intValue = DynamicValue(value: 0, typeId: NodeId.int32);
      Pointer<UA_VariableAttributes> attr = calloc<UA_VariableAttributes>();
      attr.ref = lib.UA_VariableAttributes_default;
      final variant = Client.valueToVariant(intValue, lib);
      attr.ref.value = variant.ref;
      attr.ref.accessLevel = UA_ACCESSLEVELMASK_READ | UA_ACCESSLEVELMASK_WRITE;
      attr.ref.dataType = NodeId.int32.toRaw(lib);

      UA_QualifiedName name = lib.UA_QUALIFIEDNAME(1, "the int".toNativeUtf8().cast());
      UA_NodeId parentNodeId = NodeId.fromNumeric(0, UA_NS0ID_OBJECTSFOLDER).toRaw(lib);
      UA_NodeId parentReferenceNodeId = NodeId.fromNumeric(0, UA_NS0ID_ORGANIZES).toRaw(lib);
      UA_NodeId basedatavariableType = NodeId.fromNumeric(0, UA_NS0ID_BASEDATAVARIABLETYPE).toRaw(lib);
      lib.UA_Server_addVariableNode(server, intNodeId.toRaw(lib), parentNodeId, parentReferenceNodeId, name,
          basedatavariableType, attr.ref, nullptr, nullptr);
    }

    client = Client(lib);
    // Run the client while we connect
    () async {
      while (client!.runIterate(Duration(milliseconds: 10))) {
        await Future.delayed(Duration(milliseconds: 5));
      }
    }();
    await client!.connect("opc.tcp://localhost:4840").onError((error, stackTrace) {
      throw Exception("Failed to connect to the server: $error");
    });
  });
  test('Basic read and write boolean async', () async {
    expect((await client!.readValue(boolNodeId)).value, true);
    await client!.writeValue(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));
    expect((await client!.readValue(boolNodeId)).value, false);
    await client!.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    expect((await client!.readValue(boolNodeId)).value, true);
  });

  test('Basic subscription', () async {
    // Set current value to false to get a change
    await client!.writeValue(
        boolNodeId,
        DynamicValue(
            value: true,
            typeId: NodeId.boolean)); // It seems we get a value straigt away, make it match the first in the list
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final controller = client!.monitoredItem(boolNodeId, subscription);
    final stream = controller.stream.map<bool>((event) => event.value);
    final items = [true, false, true, false];
    expect(stream, emitsInOrder(items));
    for (var item in items) {
      await client!.writeValue(boolNodeId, DynamicValue(value: item, typeId: NodeId.boolean));
      await Future.delayed(Duration(milliseconds: 100)); // Give the server and client time to do stuff
    }
    await Future.delayed(Duration(milliseconds: 400)); // Let the subscription catch up
    await controller.close();
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
    final boolController = client!.monitoredItem(boolNodeId, subscription);
    final boolStream = boolController.stream.map<bool>((event) => event.value);
    final intController = client!.monitoredItem(intNodeId, subscription);
    final intStream = intController.stream.map<int>((event) => event.value);
    final items = [true, false, true, false];
    final intItems = [1, 2, 3, 4];
    expect(boolStream, emitsInOrder(items));
    expect(intStream, emitsInOrder(intItems));
    expect(items.length, intItems.length);
    for (var i = 0; i < items.length; i++) {
      await client!.writeValue(boolNodeId, DynamicValue(value: items[i], typeId: NodeId.boolean));
      await client!.writeValue(intNodeId, DynamicValue(value: intItems[i], typeId: NodeId.int32));
      await Future.delayed(Duration(milliseconds: 100)); // Give the server and client time to do stuff
    }
    await Future.delayed(Duration(milliseconds: 400)); // Let the subscription catch up
    await intController.close();
    await boolController.close();
  });

  test('Creating a subscription and not using it should not hang the process', () async {
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    // ignore: unused_local_variable
    final controller = client!.monitoredItem(boolNodeId, subscription);
    await Future.delayed(Duration(milliseconds: 100));
  });

  tearDown(() async {
    await client!.delete();
    lib.UA_Server_run_shutdown(server);
    await Future.delayed(Duration(seconds: 1));

    lib.UA_Server_delete(server);
  });
}
