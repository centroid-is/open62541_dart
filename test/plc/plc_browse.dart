// Recursive BrowseName lookup so tests never hard-code vendor NodeIds.

import 'package:open62541/open62541.dart';

/// Finds a node by BrowseName in the Objects subtree (bounded, cycle-guarded).
Future<NodeId?> findByBrowseName(ClientApi client, String browseName, {int maxDepth = 8}) async {
  final visited = <NodeId>{};
  Future<NodeId?> walk(NodeId root, int depth) async {
    if (depth > maxDepth || visited.contains(root)) return null;
    visited.add(root);
    final children = await client.browse(root);
    for (final c in children) {
      if (c.browseName == browseName) return c.nodeId;
    }
    for (final c in children) {
      if (c.nodeClass == NodeClass.UA_NODECLASS_OBJECT || c.nodeClass == NodeClass.UA_NODECLASS_VARIABLE) {
        final r = await walk(c.nodeId, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  return walk(NodeId.objectsFolder, 0);
}
