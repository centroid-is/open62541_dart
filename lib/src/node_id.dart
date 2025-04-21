import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'generated/open62541_bindings.dart' as raw;

import 'extensions.dart';

class NodeId {
  NodeId._internal(this._namespaceIndex, {dynamic id})
      : _stringId = id is String ? id : null,
        _numericId = id is int ? id : null {
    if (_stringId == null && _numericId == null) {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  factory NodeId.fromRaw(raw.UA_NodeId nodeId) {
    if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      // Drop the __DefaultBinary if attached to string, don't know why it is there
      var str = nodeId.identifier.string.value;
      if (str.endsWith('__DefaultBinary')) {
        str = str.substring(0, str.length - 15);
      }
      return NodeId._internal(nodeId.namespaceIndex, id: str);
    } else if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC) {
      return NodeId._internal(nodeId.namespaceIndex, id: nodeId.identifier.numeric);
    } else {
      throw 'NodeId todo implement';
    }
  }

  factory NodeId.fromNumeric(int nsIndex, int identifier) {
    return NodeId._internal(nsIndex, id: identifier);
  }

  factory NodeId.fromString(int nsIndex, String chars) {
    return NodeId._internal(nsIndex, id: chars);
  }

  // Handy methods for namespace 0 types
  static NodeId get boolean {
    return NodeId.fromNumeric(0, Namespace0Id.boolean.value);
  }

  static NodeId get uint16 {
    return NodeId.fromNumeric(0, Namespace0Id.uint16.value);
  }

  static NodeId get int16 {
    return NodeId.fromNumeric(0, Namespace0Id.int16.value);
  }

  static NodeId get uint32 {
    return NodeId.fromNumeric(0, Namespace0Id.uint32.value);
  }

  static NodeId get int32 {
    return NodeId.fromNumeric(0, Namespace0Id.int32.value);
  }

  static NodeId get uint64 {
    return NodeId.fromNumeric(0, Namespace0Id.uint64.value);
  }

  static NodeId get int64 {
    return NodeId.fromNumeric(0, Namespace0Id.int64.value);
  }

  static NodeId get uastring {
    return NodeId.fromNumeric(0, Namespace0Id.string.value);
  }

  static NodeId get double {
    return NodeId.fromNumeric(0, Namespace0Id.double.value);
  }

  static NodeId get float {
    return NodeId.fromNumeric(0, Namespace0Id.float.value);
  }

  static NodeId get datetime {
    return NodeId.fromNumeric(0, Namespace0Id.datetime.value);
  }

  static NodeId get byte {
    return NodeId.fromNumeric(0, Namespace0Id.byte.value);
  }

  static NodeId get sbyte {
    return NodeId.fromNumeric(0, Namespace0Id.sbyte.value);
  }

  static NodeId get structure {
    return NodeId.fromNumeric(0, Namespace0Id.structure.value);
  }

  raw.UA_NodeId toRaw(raw.open62541 lib) {
    if (_stringId != null) {
      return lib.UA_NODEID_STRING(_namespaceIndex, _stringId!.toNativeUtf8().cast());
    } else if (_numericId != null) {
      return lib.UA_NODEID_NUMERIC(_namespaceIndex, _numericId!);
    } else {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  Pointer<raw.UA_NodeId> toRawPointer(raw.open62541 lib) {
    final nodeId = calloc<raw.UA_NodeId>();
    nodeId.ref = toRaw(lib);
    return nodeId;
  }

  int get namespace => _namespaceIndex;
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
      return _namespaceIndex == other._namespaceIndex && _stringId == other._stringId && _numericId == other._numericId;
    }
    return false;
  }

  @override
  int get hashCode => _namespaceIndex.hashCode ^ _stringId.hashCode ^ _numericId.hashCode;

  String? _stringId;
  int? _numericId;
  // String? _byteStringId;
  int _namespaceIndex;
}
