import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'extensions.dart';
import 'node_id_core.dart' as core;
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

export 'node_id_core.dart';

/// The FFI half of [core.NodeId], kept out of `node_id_core.dart` so the value
/// type itself compiles on a platform with no `dart:ffi`. Importing this file
/// at all requires the native library; importing `node_id_core.dart` does not.
extension NodeIdFfi on core.NodeId {
  /// Reads a [core.NodeId] out of a raw `UA_NodeId` struct.
  ///
  /// Static rather than a factory because the class it belongs to no longer
  /// lives in this file — call it as `NodeIdFfi.fromRaw(...)`.
  static core.NodeId fromRaw(raw.UA_NodeId nodeId) {
    if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      // Drop the __DefaultBinary if attached to string, don't know why it is there
      var str = nodeId.identifier.string.value;
      if (str.endsWith('__DefaultBinary')) {
        str = str.substring(0, str.length - 15);
      }
      return core.NodeId.fromString(nodeId.namespaceIndex, str);
    } else if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC) {
      return core.NodeId.fromNumeric(nodeId.namespaceIndex, nodeId.identifier.numeric);
    } else if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_GUID) {
      final g = nodeId.identifier.guid;
      String hex(int value, int width) => value.toRadixString(16).padLeft(width, '0');
      final tail = [for (var i = 2; i < 8; i++) hex(g.data4[i], 2)].join();
      final guid =
          '${hex(g.data1, 8)}-${hex(g.data2, 4)}-${hex(g.data3, 4)}-'
          '${hex(g.data4[0], 2)}${hex(g.data4[1], 2)}-$tail';
      return core.NodeId.fromGuid(nodeId.namespaceIndex, guid);
    } else {
      throw 'NodeId todo implement';
    }
  }

  /// This NodeId as a by-value `UA_NodeId`.
  ///
  /// A numeric or GUID identifier is inline, so the result owns no native
  /// memory. A string identifier is copied into a buffer from [allocator], and
  /// whoever ends up holding the struct has to release it: open62541, when the
  /// struct is stored in something open62541 frees (a request passed to
  /// `UA_*_delete`, a config it clears), which needs the default `ua_calloc`;
  /// otherwise the caller. Where the NodeId is only passed by value to a call
  /// that copies it, pass an [Arena] so the buffer goes with the scope.
  raw.UA_NodeId toRaw({Allocator allocator = ua_calloc}) {
    if (isString()) {
      return raw.UA_NODEID_STRING(namespace, string.toNativeUtf8(allocator: allocator).cast());
    } else if (isNumeric()) {
      return raw.UA_NODEID_NUMERIC(namespace, numeric);
    } else if (isGuid()) {
      // No UA_NODEID_GUID helper is exported (it is a C macro); build the
      // struct directly. A GUID identifier is inline, so - like a numeric
      // NodeId - the result owns no heap memory.
      final nodeId = Struct.create<raw.UA_NodeId>();
      nodeId.namespaceIndex = namespace;
      nodeId.identifierTypeAsInt = raw.UA_NodeIdType.UA_NODEIDTYPE_GUID.value;
      final parts = guid.split('-');
      nodeId.identifier.guid.data1 = int.parse(parts[0], radix: 16);
      nodeId.identifier.guid.data2 = int.parse(parts[1], radix: 16);
      nodeId.identifier.guid.data3 = int.parse(parts[2], radix: 16);
      final tail = parts[3] + parts[4];
      for (var i = 0; i < 8; i++) {
        nodeId.identifier.guid.data4[i] = int.parse(tail.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return nodeId;
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
