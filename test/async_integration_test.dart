import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:open62541/open62541.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'package:test/test.dart';

void main() async {
  final lib = Open62541Singleton().lib;
  test('Basic read and write boolean async', () async {
    // Initalize an open62541 server
    Pointer<UA_Server> server = lib.UA_Server_new();
    lib.UA_Server_run_startup(server);
    var quit = false;

    // Run the server while we test
    () async {
      while (!quit) {
        // The true is if the server should wait for messages in the network layer
        // The function returns how long it can wait before the next iteration
        // That is a really high number and causes my tests to run slow.
        // Lets just wait 50ms
        lib.UA_Server_run_iterate(server, true);
        await Future.delayed(Duration(milliseconds: 50));
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

    final boolNodeId = NodeId.fromString(1, "the.bBool");
    UA_QualifiedName name = lib.UA_QUALIFIEDNAME(1, "the bool".toNativeUtf8().cast());
    UA_NodeId parentNodeId = NodeId.fromNumeric(0, UA_NS0ID_OBJECTSFOLDER).toRaw(lib);
    UA_NodeId parentReferenceNodeId = NodeId.fromNumeric(0, UA_NS0ID_ORGANIZES).toRaw(lib);
    UA_NodeId basedatavariableType = NodeId.fromNumeric(0, UA_NS0ID_BASEDATAVARIABLETYPE).toRaw(lib);
    lib.UA_Server_addVariableNode(server, boolNodeId.toRaw(lib), parentNodeId, parentReferenceNodeId, name,
        basedatavariableType, attr.ref, nullptr, nullptr);

    // Test
    final client = Client(lib);
    client.connect("opc.tcp://localhost:4840");
    // Run the client while we connect
    () async {
      while (!quit) {
        client.runIterate(Duration(milliseconds: 50));
        await Future.delayed(Duration(milliseconds: 50));
      }
    }();
    Future<void> waitForConnected() async {
      await client.config.stateStream.firstWhere((event) =>
          event.channelState == UA_SecureChannelState.UA_SECURECHANNELSTATE_OPEN &&
          event.sessionState == UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
      return;
    }

    await waitForConnected();

    expect((await client.readValue(boolNodeId)).value, true);
    await client.writeValue(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));
    expect((await client.readValue(boolNodeId)).value, false);
    await client.writeValue(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
    expect((await client.readValue(boolNodeId)).value, true);
    quit = true;
    client.delete();
    lib.UA_Server_run_shutdown(server);
    lib.UA_Server_delete(server);
  });
}
