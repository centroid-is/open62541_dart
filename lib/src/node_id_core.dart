/// Pure-Dart core of [NodeId] — no FFI, no generated bindings.
///
/// Split out of `node_id.dart` so that [DynamicValue] — which is the value type
/// the whole HMI speaks — can be imported on a platform that has no `dart:ffi`,
/// i.e. Flutter web. The FFI half ([NodeIdFfi], with `fromRaw`/`toRaw`) stays in
/// `node_id.dart` and is only reachable where open62541's native library is.
///
/// The namespace-0 identifiers below are written as literals rather than read
/// from `third_party/open62541.g.dart`, because reading them is exactly what
/// would drag `dart:ffi` back in. `test/ns0_literals_test.dart` asserts every
/// one of them against the generated constant, so a regenerated binding that
/// moved a number fails a test instead of silently mis-addressing a node.
library;

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

  // Handy methods for namespace 0 types. See the library doc for why these are
  // literals; ns0_literals_test.dart pins every one against the binding.
  static NodeId get nullId => NodeId.fromNumeric(0, 0);
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

  // Well-known nodes of namespace 0 (OPC UA Part 5), each a literal of the
  // generated `UA_NS0ID_*` constant (see the library doc): the standard
  // folders, the Server object and the variables under it an application
  // reads or serves, and the reference and type nodes standard properties and
  // components are added with. Every open62541 server has them.

  /// The Root folder, `i=84`.
  static NodeId get rootFolder => NodeId.fromNumeric(0, 84);

  /// The Objects folder, `i=85`.
  static NodeId get objectsFolder => NodeId.fromNumeric(0, 85);

  /// The Types folder, `i=86`.
  static NodeId get typesFolder => NodeId.fromNumeric(0, 86);

  /// The Views folder, `i=87`.
  static NodeId get viewsFolder => NodeId.fromNumeric(0, 87);

  /// The Server object, `i=2253`.
  static NodeId get server => NodeId.fromNumeric(0, 2253);

  /// `Server/ServerArray`, `i=2254`: the URIs of the servers the server
  /// knows, index 0 its own.
  static NodeId get serverArray => NodeId.fromNumeric(0, 2254);

  /// `Server/NamespaceArray`, `i=2255`: the namespace URIs by index.
  static NodeId get namespaceArray => NodeId.fromNumeric(0, 2255);

  /// `Server/ServerStatus`, `i=2256`: the ServerStatusDataType structure.
  static NodeId get serverStatus => NodeId.fromNumeric(0, 2256);

  /// `Server/ServerStatus/StartTime`, `i=2257`.
  static NodeId get serverStatusStartTime => NodeId.fromNumeric(0, 2257);

  /// `Server/ServerStatus/CurrentTime`, `i=2258`: the server's clock, a
  /// `DateTime`.
  static NodeId get serverStatusCurrentTime => NodeId.fromNumeric(0, 2258);

  /// `Server/ServerStatus/State`, `i=2259`: the ServerState enumeration
  /// (0 is Running).
  static NodeId get serverStatusState => NodeId.fromNumeric(0, 2259);

  /// `Server/ServerStatus/BuildInfo`, `i=2260`.
  static NodeId get serverStatusBuildInfo => NodeId.fromNumeric(0, 2260);

  /// `Server/ServiceLevel`, `i=2267`: a Byte, 255 for a server fully able
  /// to serve; a redundant set's clients pick the server with the highest.
  static NodeId get serviceLevel => NodeId.fromNumeric(0, 2267);

  /// `Server/ServerRedundancy`, `i=2296`.
  static NodeId get serverRedundancy => NodeId.fromNumeric(0, 2296);

  /// `Server/ServerRedundancy/RedundancySupport`, `i=3709`: the
  /// RedundancySupport enumeration (0 None, 1 Cold, 2 Warm, 3 Hot, ...).
  static NodeId get redundancySupport => NodeId.fromNumeric(0, 3709);

  /// `Server/ServerRedundancy/ServerUriArray`, `i=11314`: the URIs of the
  /// servers in the redundant set. open62541 removes this property at
  /// startup; a server that is part of a set adds it back under
  /// [serverRedundancy] with [hasProperty].
  static NodeId get serverUriArray => NodeId.fromNumeric(0, 11314);

  /// `Server/ServerRedundancy/ServerNetworkGroups`, `i=14415`: a
  /// `NetworkGroupDataType[]` mapping each ServerUri of [serverUriArray] to
  /// its network paths (lists of endpoint URLs), Part 5 §6.3.10. Published
  /// by `Server.setRedundancy(networkGroups:)`.
  static NodeId get serverNetworkGroups => NodeId.fromNumeric(0, 14415);

  /// The HierarchicalReferences reference type, `i=33`.
  static NodeId get hierarchicalReferences => NodeId.fromNumeric(0, 33);

  /// The HasSubtype reference type, `i=45`.
  static NodeId get hasSubtype => NodeId.fromNumeric(0, 45);

  /// The Organizes reference type, `i=35`: a folder to what it holds.
  static NodeId get organizes => NodeId.fromNumeric(0, 35);

  /// The HasComponent reference type, `i=47`: an object to its variables
  /// and sub-objects.
  static NodeId get hasComponent => NodeId.fromNumeric(0, 47);

  /// The HasProperty reference type, `i=46`: a node to its properties.
  static NodeId get hasProperty => NodeId.fromNumeric(0, 46);

  /// The HasEncoding reference type, `i=38`: a DataType to its
  /// DataTypeEncoding objects (`Default Binary`, ...).
  static NodeId get hasEncoding => NodeId.fromNumeric(0, 38);

  /// The HasTypeDefinition reference type, `i=40`.
  static NodeId get hasTypeDefinition => NodeId.fromNumeric(0, 40);

  /// The BaseObjectType, `i=58`.
  static NodeId get baseObjectType => NodeId.fromNumeric(0, 58);

  /// The FolderType, `i=61`.
  static NodeId get folderType => NodeId.fromNumeric(0, 61);

  /// The BaseDataVariableType, `i=63`: the type definition of a plain
  /// variable.
  static NodeId get baseDataVariableType => NodeId.fromNumeric(0, 63);

  /// The PropertyType, `i=68`: the type definition of a property.
  static NodeId get propertyType => NodeId.fromNumeric(0, 68);

  /// The DataTypeEncodingType object type, `i=76`: the TypeDefinition of a
  /// `Default Binary` encoding object.
  static NodeId get dataTypeEncodingType => NodeId.fromNumeric(0, 76);

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

  final String? _stringId;
  final int? _numericId;
  final String? _guidId;
  // String? _byteStringId;
  final int _namespaceIndex;
}
