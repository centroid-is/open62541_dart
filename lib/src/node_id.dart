import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

class NodeId {
  NodeId._internal(this._namespaceIndex, {dynamic id, String? guid})
    : _stringId = id is String ? id : null,
      _numericId = id is int ? id : null,
      _guidId = guid {
    if (_stringId == null && _numericId == null && _guidId == null) {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  factory NodeId.from(NodeId other) {
    if (other.isString()) {
      return NodeId.fromString(other.namespace, other.string);
    } else if (other.isNumeric()) {
      return NodeId.fromNumeric(other.namespace, other.numeric);
    } else if (other.isGuid()) {
      return NodeId.fromGuid(other.namespace, other.guid);
    } else {
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
    } else if (nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_GUID) {
      final g = nodeId.identifier.guid;
      String hex(int value, int width) => value.toRadixString(16).padLeft(width, '0');
      final tail = [for (var i = 2; i < 8; i++) hex(g.data4[i], 2)].join();
      final guid =
          '${hex(g.data1, 8)}-${hex(g.data2, 4)}-${hex(g.data3, 4)}-'
          '${hex(g.data4[0], 2)}${hex(g.data4[1], 2)}-$tail';
      return NodeId._internal(nodeId.namespaceIndex, guid: guid);
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

  /// Creates a GUID NodeId from its canonical textual form, e.g.
  /// `NodeId.fromGuid(1, '09087e75-8e5e-499b-954f-f2a9603db28a')`.
  factory NodeId.fromGuid(int nsIndex, String guid) {
    if (!_guidPattern.hasMatch(guid)) {
      throw 'Invalid GUID "$guid" (expected 8-4-4-4-12 hexadecimal groups)';
    }
    return NodeId._internal(nsIndex, guid: guid.toLowerCase());
  }

  static final RegExp _guidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  // Handy methods for namespace 0 types
  static NodeId get nullId {
    return NodeId.fromNumeric(0, 0);
  }

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

  static NodeId get structureDefinition {
    return NodeId.fromNumeric(0, Namespace0Id.structureDefinition.value);
  }

  static NodeId get structureDefinitionDefaultBinary {
    return NodeId.fromNumeric(0, Namespace0Id.structureDefinitionDefaultBinary.value);
  }

  static NodeId get enumDefinitionDefaultBinary {
    return NodeId.fromNumeric(0, Namespace0Id.enumDefinitionDefaultBinary.value);
  }

  static NodeId get nodeId {
    return NodeId.fromNumeric(0, Namespace0Id.nodeId.value);
  }

  static NodeId get localizedText {
    return NodeId.fromNumeric(0, Namespace0Id.localizedText.value);
  }

  static NodeId get serverStatusCurrentTime {
    return NodeId.fromNumeric(0, 2258);
  }

  static NodeId get rootFolder {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_ROOTFOLDER);
  }

  static NodeId get objectsFolder {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
  }

  static NodeId get typesFolder {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_TYPESFOLDER);
  }

  static NodeId get viewsFolder {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_VIEWSFOLDER);
  }

  static NodeId get hierarchicalReferences {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_HIERARCHICALREFERENCES);
  }

  static NodeId get hasSubtype {
    return NodeId.fromNumeric(0, raw.UA_NS0ID_HASSUBTYPE);
  }

  raw.UA_NodeId toRaw() {
    if (_stringId != null) {
      return raw.UA_NODEID_STRING(_namespaceIndex, _stringId!.toNativeUtf8(allocator: ua_malloc).cast());
    } else if (_numericId != null) {
      return raw.UA_NODEID_NUMERIC(_namespaceIndex, _numericId!);
    } else if (_guidId != null) {
      // No UA_NODEID_GUID helper is exported (it is a C macro); build the
      // struct directly. A GUID identifier is inline, so - like a numeric
      // NodeId - the result owns no heap memory.
      final nodeId = Struct.create<raw.UA_NodeId>();
      nodeId.namespaceIndex = _namespaceIndex;
      nodeId.identifierTypeAsInt = raw.UA_NodeIdType.UA_NODEIDTYPE_GUID.value;
      final parts = _guidId!.split('-');
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

  int get namespace => _namespaceIndex;
  int get numeric => _numericId!;
  String get string => _stringId!;

  /// The canonical lowercase textual form of a GUID identifier
  /// (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
  String get guid => _guidId!;
  // String get byteString => _byteStringId!;

  bool isNumeric() {
    return _numericId != null;
  }

  bool isString() {
    return _stringId != null;
  }

  bool isGuid() {
    return _guidId != null;
  }

  // bool isByteString() {
  //   return _nodeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_BYTESTRING;
  // }

  @override
  String toString() {
    if (_stringId != null) {
      return "ns=$namespace;s=$_stringId";
    } else if (_numericId != null) {
      return "ns=$namespace;i=$_numericId";
    } else if (_guidId != null) {
      return "ns=$namespace;g=$_guidId";
    } else {
      return 'NodeId(TODO)';
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is NodeId) {
      return _namespaceIndex == other._namespaceIndex &&
          _stringId == other._stringId &&
          _numericId == other._numericId &&
          _guidId == other._guidId;
    }
    return false;
  }

  @override
  int get hashCode => _namespaceIndex.hashCode ^ _stringId.hashCode ^ _numericId.hashCode ^ _guidId.hashCode;

  String? _stringId;
  int? _numericId;
  String? _guidId;
  // String? _byteStringId;
  int _namespaceIndex;
}
