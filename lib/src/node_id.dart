import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'extensions.dart';
import 'node_id_core.dart' as core;
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

export 'node_id_core.dart';

/// Extension on NodeId adding FFI methods for native OPC UA interop.
extension NodeIdFfi on core.NodeId {
  /// Create a NodeId from a raw UA_NodeId FFI struct.
  static core.NodeId fromRaw(raw.UA_NodeId nodeId) {
    if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      var str = nodeId.identifier.string.value;
      if (str.endsWith('__DefaultBinary')) {
        str = str.substring(0, str.length - 15);
      }
      return core.NodeId.fromString(nodeId.namespaceIndex, str);
    } else if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC) {
      return core.NodeId.fromNumeric(nodeId.namespaceIndex, nodeId.identifier.numeric);
    } else {
      throw 'NodeId todo implement';
    }
  }

  raw.UA_NodeId toRaw() {
    if (isString()) {
      return raw.UA_NODEID_STRING(namespace, string.toNativeUtf8(allocator: ua_malloc).cast());
    } else if (isNumeric()) {
      return raw.UA_NODEID_NUMERIC(namespace, numeric);
    } else {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  Pointer<raw.UA_NodeId> toRawPointer() {
    final nodeId = ua_calloc<raw.UA_NodeId>();
    nodeId.ref = toRaw();
    return nodeId;
  }
}
