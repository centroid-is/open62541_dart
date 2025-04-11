import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'generated/open62541_bindings.dart' as raw;

import 'extensions.dart';

class NodeId {
  NodeId._internal(this._namespaceIndex, {stringId, numericId})
      : _stringId = stringId,
        _numericId = numericId;

  factory NodeId.fromRaw(raw.UA_NodeId nodeId) {
    if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      return NodeId._internal(nodeId.namespaceIndex,
          stringId: nodeId.identifier.string.value);
    } else if (nodeId.identifierType ==
        raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC) {
      return NodeId._internal(nodeId.namespaceIndex,
          numericId: nodeId.identifier.numeric);
    } else {
      throw 'NodeId todo implement';
    }
  }

  factory NodeId.numeric(int nsIndex, int identifier) {
    return NodeId._internal(nsIndex, numericId: identifier);
  }

  factory NodeId.string(int nsIndex, String chars) {
    return NodeId._internal(nsIndex, stringId: chars);
  }

  raw.UA_NodeId toRaw(raw.open62541 lib) {
    if (_stringId != null) {
      return lib.UA_NODEID_STRING(
          _namespaceIndex, _stringId!.toNativeUtf8().cast());
    } else if (_numericId != null) {
      return lib.UA_NODEID_NUMERIC(_namespaceIndex, _numericId!);
    } else {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  int get numeric => _numericId!;
  String get string => _stringId!;
  // GUID
  // String get byteString => _byteStringId!;

  bool isNumeric() {
    return _numericId != null;
  }

  bool isString() {
    return _stringId != null;
  }

  // bool isGuid() {
  //   return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_GUID;
  // }

  // bool isByteString() {
  //   return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_BYTESTRING;
  // }

  @override
  String toString() {
    if (_stringId != null) {
      return 'NodeId(namespace: $_namespaceIndex, string: $_stringId)';
    } else if (_numericId != null) {
      return 'NodeId(namespace: $_namespaceIndex, numeric: $_numericId)';
    } else {
      return 'NodeId(TODO)';
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is NodeId) {
      return _namespaceIndex == other._namespaceIndex &&
          _stringId == other._stringId &&
          _numericId == other._numericId;
    }
    return false;
  }

  @override
  int get hashCode =>
      _namespaceIndex.hashCode ^ _stringId.hashCode ^ _numericId.hashCode;

  String? _stringId;
  int? _numericId;
  // String? _byteStringId;
  int _namespaceIndex;
}
