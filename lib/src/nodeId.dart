import 'package:ffi/ffi.dart';

import 'generated/open62541_bindings.dart' as raw;
import 'library.dart';
import 'types/string.dart';

class NodeId {
  NodeId._internal(this._nodeId);

  factory NodeId.fromRaw(raw.UA_NodeId nodeId) {
    return NodeId._internal(nodeId);
  }

  factory NodeId.numeric(int nsIndex, int identifier) {
    // BIG TODO we need to change this, I dont want to use the singleton
    return NodeId._internal(
        Open62541Singleton().lib.UA_NODEID_NUMERIC(nsIndex, identifier));
  }

  factory NodeId.string(int nsIndex, String chars) {
    // BIG TODO we need to change this, I dont want to use the singleton
    return NodeId._internal(Open62541Singleton()
        .lib
        .UA_NODEID_STRING(nsIndex, chars.toNativeUtf8().cast()));
  }

  int get numeric => _nodeId.identifier.numeric;
  String get string => _nodeId.identifier.string.value;
  // GUID
  String get byteString => _nodeId.identifier.byteString.value;

  bool isNumeric() {
    return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC;
  }

  bool isString() {
    return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING;
  }

  bool isGuid() {
    return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_GUID;
  }

  bool isByteString() {
    return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_BYTESTRING;
  }

  String toString() {
    return 'NodeId';
    try {
      if (isNumeric()) {
        return 'NodeId(namespace: $_nodeId.namespaceIndex, numeric: $numeric)';
      } else if (isString()) {
        return 'NodeId(namespace: $_nodeId.namespaceIndex, string: $string)';
      } else {
        return 'NodeId(TODO)';
      }
    } catch (e) {
      return 'NodeId(error formatting toString) $e';
    }
  }

  raw.UA_NodeId _nodeId;

  raw.UA_NodeId get rawNodeId => _nodeId;
}
