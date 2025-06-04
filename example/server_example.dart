import 'package:open62541/open62541.dart';

void main() async {
  final lib = loadOpen62541Library(local: true);
  final server = Server(lib);

  print("Starting server");
  server.start();

  () async {
    while (server.runIterate()) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  // Add some variables to our little server
  final variableNodeId = NodeId.fromString(1, "myVariable");
  DynamicValue value = DynamicValue(value: true, typeId: NodeId.boolean, name: "My Variable");
  server.addVariableNode(variableNodeId, value, accessLevel: AccessLevelMask(read: true, write: true));

  final variableSubscription = server.monitorVariable(variableNodeId).listen((event) => print(event));

  // Try adding a array variable to our server
  final complexVariableNodeId = NodeId.fromString(1, "arrayVariable");
  final complexValue = DynamicValue.fromList([1337, 2005, 3535], typeId: NodeId.int32, name: "My Array Variable");
  server.addVariableNode(complexVariableNodeId, complexValue, accessLevel: AccessLevelMask(read: true, write: true));

  // Try adding a structure variable to our server
  final structureVariableNodeId = NodeId.fromString(1, "structureVariable");
  final myStructureTypeId = NodeId.fromString(1, "myStructureType");
  DynamicValue structureValue = DynamicValue(name: "My Structure Variable", typeId: myStructureTypeId);
  structureValue["a"] = DynamicValue(value: 0, typeId: NodeId.int32);
  structureValue["b"] = DynamicValue(value: true, typeId: NodeId.boolean);
  structureValue["c"] = DynamicValue(value: 5.8, typeId: NodeId.float);

  server.addCustomType(myStructureTypeId, structureValue);

  server.addDataTypeNode(myStructureTypeId, "myStructureType",
      displayName: LocalizedText("My Structure Type", "en-US"));
  server.addVariableNode(structureVariableNodeId, structureValue,
      accessLevel: AccessLevelMask(read: true, write: true), typeId: myStructureTypeId);

  final runTime = Duration(minutes: 60);
  print("The server will now run for $runTime");
  await Future.delayed(runTime);

  await variableSubscription.cancel();

  server.shutdown();

  server.delete();

  print("Server stopped and deleted");
}
