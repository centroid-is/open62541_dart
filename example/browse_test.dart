import 'package:open62541/open62541.dart';

void main() async {
  final client = Client();

  print("Connecting to opc.tcp://10.50.10.10:4840 ...");
  client.connect("opc.tcp://10.50.10.10:4840");

  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }();

  await client.awaitConnect();
  print("Connected!\n");

  // Simple browse of Objects folder
  print("=== Browse Objects folder ===");
  final items = await client.browse(NodeId.objectsFolder);
  for (final item in items) {
    print("  ${item.displayName} (${item.nodeId}) [${item.nodeClass}]");
  }

  // Recursive tree walk
  print("\n=== Browse tree from Root (maxDepth: 3) ===");
  await client.browseTree(NodeId.rootFolder, maxDepth: 3, referenceTypeId: NodeId.hierarchicalReferences).listen((
    item,
  ) {
    print(item);
  }).asFuture();

  print("\nDone.");
  client.disconnect();
  await client.delete();
}
