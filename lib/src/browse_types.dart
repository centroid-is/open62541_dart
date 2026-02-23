import 'dart:ffi';

import 'extensions.dart';
import 'node_id.dart';
import 'third_party/open62541.g.dart' as raw;

typedef NodeClass = raw.UA_NodeClass;

typedef BrowseResultMask = raw.UA_BrowseResultMask;

typedef ReadAttributeParam = Map<NodeId, List<AttributeId>>;

class BrowseResultItem {
  final NodeId referenceTypeId;
  final bool isForward;
  final NodeId nodeId;
  final String browseName;
  final String displayName;
  final NodeClass nodeClass;
  final NodeId? typeDefinition;

  const BrowseResultItem({
    required this.referenceTypeId,
    required this.isForward,
    required this.nodeId,
    required this.browseName,
    required this.displayName,
    required this.nodeClass,
    this.typeDefinition,
  });

  @override
  String toString() {
    return 'BrowseResultItem(displayName: $displayName, nodeId: $nodeId, nodeClass: $nodeClass)';
  }
}

class BrowseTreeItem {
  final BrowseResultItem item;
  final int depth;
  final NodeId parentNodeId;

  const BrowseTreeItem({required this.item, required this.depth, required this.parentNodeId});

  NodeId get nodeId => item.nodeId;
  String get displayName => item.displayName;
  String get browseName => item.browseName;
  NodeClass get nodeClass => item.nodeClass;

  @override
  String toString() {
    return '${"  " * depth}${item.displayName} (${item.nodeId}) [${item.nodeClass}]';
  }
}

NodeId? tryParseNodeId(raw.UA_NodeId rawNodeId) {
  try {
    return rawNodeId.toNodeId();
  } catch (_) {
    return null;
  }
}

List<BrowseResultItem> extractReferences(raw.UA_BrowseResult browseResult) {
  final items = <BrowseResultItem>[];
  for (var i = 0; i < browseResult.referencesSize; i++) {
    final ref = browseResult.references[i];
    final nodeId = tryParseNodeId(ref.nodeId.nodeId);
    if (nodeId == null) continue;
    items.add(
      BrowseResultItem(
        referenceTypeId: tryParseNodeId(ref.referenceTypeId) ?? NodeId.nullId,
        isForward: ref.isForward,
        nodeId: nodeId,
        browseName: ref.browseName.name.value,
        displayName: ref.displayName.text.value,
        nodeClass: ref.nodeClass,
        typeDefinition: tryParseNodeId(ref.typeDefinition.nodeId),
      ),
    );
  }
  return items;
}
