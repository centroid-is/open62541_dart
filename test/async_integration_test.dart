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

  bool quitServer = false; // For tests that need to stop the server
  setUp(() async {
    print("Setting up");
    // Initalize an open62541 server
    server = lib.UA_Server_new();
    lib.UA_Server_run_startup(server);

    // Run the server while we test
    () async {
      while (!quitServer) {
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

    print("Creating client");
    client = Client(lib);
    // Print the state of the client connection
    client!.config.stateStream.listen((state) {
      print("Client state: $state");
    });
    // Run the client while we connect
    () async {
      while (client!.runIterate(Duration(milliseconds: 10))) {
        await Future.delayed(Duration(milliseconds: 5));
      }
    }();
    await client!.connect("opc.tcp://localhost:4840").onError((error, stackTrace) {
      throw Exception("Failed to connect to the server: $error");
    });
    print("Client connected!");
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
    final stream = client!.monitoredItem(boolNodeId, subscription).map<bool>((event) {
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
    final boolStream = client!.monitoredItem(boolNodeId, subscription).map<bool>((event) {
      boolCounter = boolCounter + 1;
      if (boolCounter == items.length && intCounter == intItems.length) {
        comp.complete();
      }
      return event.value;
    });
    final intStream = client!.monitoredItem(intNodeId, subscription).map<int>((event) {
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
    final controller = client!.monitoredItem(boolNodeId, subscription);
    await Future.delayed(Duration(milliseconds: 100));
  });

  test('Create a monitored item and then cancel before it has been created', () async {
    // This test has no expected outcome.
    // A failure is of the test is a timeout.

    // Not properly closing callbacks or cleaning up resources will cause the test to hang.
    final subscription = await client!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final stream = client!.monitoredItem(boolNodeId, subscription);
    final streamSub = stream.listen((event) => expect(true, false));
    await streamSub.cancel();
  });

  tearDown(() async {
    print("Tearing down");
    await client!.delete();
    lib.UA_Server_run_shutdown(server);

    lib.UA_Server_delete(server);
    print("Done tearing down");
  });
}
