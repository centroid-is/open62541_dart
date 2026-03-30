/// Pure-Dart core of NodeId — no FFI dependencies.
///
/// This file can be imported on all platforms including web.
/// The full NodeId with FFI methods (fromRaw, toRaw) is in node_id.dart.
class NodeId {
  NodeId._internal(this._namespaceIndex, {dynamic id})
    : _stringId = id is String ? id : null,
      _numericId = id is int ? id : null {
    if (_stringId == null && _numericId == null) {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  factory NodeId.from(NodeId other) {
    if (other.isString()) {
      return NodeId.fromString(other.namespace, other.string);
    } else if (other.isNumeric()) {
      return NodeId.fromNumeric(other.namespace, other.numeric);
    } else {
      throw 'NodeId is not initialized or unimplemented';
    }
  }

  factory NodeId.fromNumeric(int nsIndex, int identifier) {
    return NodeId._internal(nsIndex, id: identifier);
  }

  factory NodeId.fromString(int nsIndex, String chars) {
    return NodeId._internal(nsIndex, id: chars);
  }

  static NodeId get nullId => NodeId.fromNumeric(0, 0);
  static NodeId get serverStatusCurrentTime => NodeId.fromNumeric(0, 2258);

  // NS0 type NodeIds — hardcoded values matching OPC UA spec
  static NodeId get boolean => NodeId.fromNumeric(0, 1);
  static NodeId get sbyte => NodeId.fromNumeric(0, 2);
  static NodeId get byte => NodeId.fromNumeric(0, 3);
  static NodeId get int16 => NodeId.fromNumeric(0, 4);
  static NodeId get uint16 => NodeId.fromNumeric(0, 5);
  static NodeId get int32 => NodeId.fromNumeric(0, 6);
  static NodeId get uint32 => NodeId.fromNumeric(0, 7);
  static NodeId get int64 => NodeId.fromNumeric(0, 8);
  static NodeId get uint64 => NodeId.fromNumeric(0, 9);
  static NodeId get float => NodeId.fromNumeric(0, 10);
  static NodeId get double => NodeId.fromNumeric(0, 11);
  static NodeId get uastring => NodeId.fromNumeric(0, 12);
  static NodeId get datetime => NodeId.fromNumeric(0, 13);
  static NodeId get nodeId => NodeId.fromNumeric(0, 17);
  static NodeId get localizedText => NodeId.fromNumeric(0, 21);
  static NodeId get structure => NodeId.fromNumeric(0, 22);
  static NodeId get structureDefinition => NodeId.fromNumeric(0, 99);
  static NodeId get structureDefinitionDefaultBinary => NodeId.fromNumeric(0, 122);
  static NodeId get enumDefinitionDefaultBinary => NodeId.fromNumeric(0, 123);

  // Folder and reference NodeIds
  static NodeId get rootFolder => NodeId.fromNumeric(0, 84);
  static NodeId get objectsFolder => NodeId.fromNumeric(0, 85);
  static NodeId get typesFolder => NodeId.fromNumeric(0, 86);
  static NodeId get viewsFolder => NodeId.fromNumeric(0, 87);
  static NodeId get hierarchicalReferences => NodeId.fromNumeric(0, 33);
  static NodeId get hasSubtype => NodeId.fromNumeric(0, 45);

  int get namespace => _namespaceIndex;
  int get numeric => _numericId!;
  String get string => _stringId!;

  bool isNumeric() => _numericId != null;
  bool isString() => _stringId != null;

  @override
  String toString() {
    if (_stringId != null) {
      return "ns=$namespace;s=$_stringId";
    } else if (_numericId != null) {
      return "ns=$namespace;i=$_numericId";
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
  int _namespaceIndex;
}
