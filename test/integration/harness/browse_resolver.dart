// Resolves NodeIds by BrowseName path so tests are server-agnostic: different
// server implementations (asyncua, node-opcua, open62541, the Dart Server) put
// the same model under different namespace indices, but the BrowseName path
// (e.g. Plant/Tank1/Temperature) is stable.

import 'package:open62541/open62541.dart';

/// Walks [path] (BrowseNames) from [root] (defaults to the Objects folder) and
/// returns the matching NodeId. Throws if any segment is missing.
Future<NodeId> resolvePath(ClientApi client, List<String> path, {NodeId? root}) async {
  var current = root ?? NodeId.objectsFolder;
  for (final segment in path) {
    final children = await client.browse(current);
    final match = children.where((c) => c.browseName == segment).toList();
    if (match.isEmpty) {
      final available = children.map((c) => c.browseName).toList();
      throw StateError('BrowseName "$segment" not found under $current. Available: $available');
    }
    current = match.first.nodeId;
  }
  return current;
}

/// Resolves several paths in one call, returning a map keyed by the last
/// segment of each path (or by the full slash-joined path when [byFullPath]).
Future<Map<String, NodeId>> resolveAll(
  ClientApi client,
  List<List<String>> paths, {
  NodeId? root,
  bool byFullPath = false,
}) async {
  final out = <String, NodeId>{};
  for (final p in paths) {
    final key = byFullPath ? p.join('/') : p.last;
    out[key] = await resolvePath(client, p, root: root);
  }
  return out;
}

/// Convenience: a tank's variable node, e.g. tankVar(client, 1, 'Temperature').
Future<NodeId> tankVar(ClientApi client, int tank, String variable) =>
    resolvePath(client, ['Plant', 'Tank$tank', variable]);

/// Convenience: a tank's method node.
Future<NodeId> tankMethod(ClientApi client, int tank, String method) =>
    resolvePath(client, ['Plant', 'Tank$tank', method]);
