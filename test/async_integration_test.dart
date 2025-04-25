import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'package:test/test.dart';

void main() async {
  final lib = Open62541Singleton().lib;
  Pointer<UA_Server> server = Pointer<UA_Server>.fromAddress(0);
  Client client = Client(lib); // This will be overwritten in setup but lets define it so we can use it in the tests
  final boolNodeId = NodeId.fromString(1, "the.bBool");
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

    // Create some boolean variables to read and write
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

    print("Initializing the client");

    client = Client(lib);
    client.connect("opc.tcp://localhost:4840");
    // Run the client while we connect
    () async {
      while (client.runIterate(Duration(milliseconds: 10))) {
        await Future.delayed(Duration(milliseconds: 10));
      }
    }();
    Future<void> waitForConnected() async {
      await client.config.stateStream.firstWhere((event) =>
          event.channelState == UA_SecureChannelState.UA_SECURECHANNELSTATE_OPEN &&
          event.sessionState == UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
      return;
    }

    await waitForConnected();
  });
  test('Basic read and write boolean async', () async {
    expect((await client.readValue(boolNodeId)).value, true);
    await client.writeValue(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));
    expect((await client.readValue(boolNodeId)).value, false);
    await client.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    expect((await client.readValue(boolNodeId)).value, true);
  });

  test('Basic subscription', () async {
    // Set current value to false to get a change
    await client.writeValue(
        boolNodeId,
        DynamicValue(
            value: true,
            typeId: NodeId.boolean)); // It seems we get a value straigt away, make it match the first in the list
    print("Creating subscription");
    final subscription = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    print("Subscription created $subscription");
    final stream = (await client.monitoredItemStream(boolNodeId, subscription)).map((event) => event.value);
    print("Stream created");
    final items = [true, false, true, false];
    expect(stream, emitsInOrder(items));
    for (var item in items) {
      await client.writeValue(boolNodeId, DynamicValue(value: item, typeId: NodeId.boolean));
      await Future.delayed(Duration(milliseconds: 200)); // Give the server and client time to do stuff
    }
  });

  tearDown(() async {
    print("Disconnecting");
    client.disconnect();
    client.delete();
    lib.UA_Server_run_shutdown(server);
    await Future.delayed(Duration(seconds: 1));

    print("Clearing memory");
    lib.UA_Server_delete(server);

    print("Done");
  });
}
