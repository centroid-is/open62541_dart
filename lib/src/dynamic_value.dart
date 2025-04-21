import 'dart:collection' show LinkedHashMap;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:binarize/binarize.dart';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart' as raw;
import 'package:open62541_bindings/src/types/payloads.dart';
import 'types/create_type.dart';
import 'node_id.dart';

enum DynamicType { object, array, string, boolean, nullValue, unknown, integer, double }

class MemberDescription {
  final String value;
  final String locale;
  MemberDescription(this.value, this.locale);
}

typedef Schema = Map<NodeId, ffi.Pointer<raw.UA_StructureDefinition>>;

class DynamicValue extends PayloadType<DynamicValue> {
  dynamic _data;
  NodeId? typeId;
  MemberDescription? _description;

  factory DynamicValue.fromMap(LinkedHashMap<String, dynamic> entries) {
    DynamicValue v = DynamicValue();
    entries.forEach((key, value) => v[key] = value);
    return v;
  }

  factory DynamicValue.fromList(List<dynamic> entries, {NodeId? typeId}) {
    DynamicValue v = DynamicValue(typeId: typeId);
    var counter = 0;
    for (var value in entries) {
      v[counter] = value;
      if (typeId != null) {
        v[counter].typeId = typeId;
      }
      counter = counter + 1;
    }
    return v;
  }
  DynamicValue({value, description, this.typeId}) : _data = value, _description = description;

  DynamicType get type {
    if (_data == null) return DynamicType.nullValue;
    if (_data is LinkedHashMap) return DynamicType.object;
    if (_data is List<DynamicValue>) return DynamicType.array;
    if (_data is String) return DynamicType.string;
    if (_data is int) return DynamicType.integer;
    if (_data is double) return DynamicType.double;
    if (_data is bool) return DynamicType.boolean;
    return DynamicType.unknown;
  }

  // Accessors for specific types
  bool get isNull => type == DynamicType.nullValue;
  bool get isObject => type == DynamicType.object;
  bool get isArray => type == DynamicType.array;
  bool get isString => type == DynamicType.string;
  bool get isInteger => type == DynamicType.integer;
  bool get isDouble => type == DynamicType.double;
  bool get isBoolean => type == DynamicType.boolean;

  double get asDouble => _parseDouble(_data) ?? 0.0;
  int get asInt => _parseInt(_data) ?? 0;
  String get asString => _data?.toString() ?? '';
  bool get asBool => _parseBool(_data) ?? false;
  DateTime? get asDateTime => _parseDateTime(_data);
  dynamic get value => _data;
  MemberDescription? get description => _description;

  List<DynamicValue> get asArray =>
      isArray ? _data : throw StateError('DynamicValue is not an array, ${_data.runtimeType}');

  Map<String, DynamicValue> get asObject =>
      isObject ? _data : throw StateError('DynamicValue is not an object, ${_data.runtimeType}');

  bool contains(dynamic key) {
    if (key is int && isArray) {
      final list = _data as List<DynamicValue>;
      return (key >= 0 && key < list.length);
    } else if (key is String && isObject) {
      return (_data as Map<String, DynamicValue>).containsKey(key);
    }
    return false;
  }

  DynamicValue operator [](dynamic key) {
    if (key is int && isArray) {
      final list = _data as List<DynamicValue>;
      return (key >= 0 && key < list.length) ? list[key] : throw StateError('Index "$key" out of bounds');
    } else if (key is String && isObject) {
      return (_data as Map<String, DynamicValue>).putIfAbsent(key, () => throw StateError('Key "$key" not found'));
    }
    throw StateError('Invalid key type: ${key.runtimeType}');
  }

  operator []=(dynamic key, dynamic passed) {
    // Try to acomidate people setting trivial values directly
    DynamicValue value;
    if (passed is DynamicValue) {
      value = passed;
    } else {
      if (passed is LinkedHashMap<String, dynamic>) {
        value = DynamicValue.fromMap(passed);
      } else if (passed is Map) {
        throw 'Unstable ordering, will not result in correct structures.';
      } else if (passed is List) {
        value = DynamicValue.fromList(passed);
      } else {
        NodeId? foundType = contains(key) ? this[key].typeId : null;
        value = DynamicValue(value: passed, typeId: foundType);
      }
    }
    if (key is int) {
      if (isNull) _data = <DynamicValue>[];
      if (isArray) {
        var list = _data as List<DynamicValue>;
        if (key > list.length) {
          throw StateError('Index "$key" out of bounds');
        } else if (key == list.length) {
          list.add(value);
        } else {
          list[key] = value;
        }
      } else {
        throw StateError('DynamicValue is not an array');
      }
    } else if (key is String) {
      if (isNull) {
        _data = LinkedHashMap<String, DynamicValue>();
      }
      if (isObject) {
        (_data as LinkedHashMap<String, DynamicValue>)[key] = value;
      } else {
        throw StateError('DynamicValue is not an object');
      }
    }
  }

  set value(dynamic value) {
    _data = value;
  }

  List<T> toList<T>(T Function(DynamicValue)? converter) {
    if (!isArray) return [];
    final list = asArray;
    return converter != null ? list.map(converter).toList() : [];
  }

  Map<String, T> toMap<T>(T Function(DynamicValue)? converter) {
    if (!isObject) return {};
    final map = asObject;
    return converter != null ? map.map((k, v) => MapEntry(k, converter(v))) : {};
  }

  @override
  String toString() => _data?.toString() ?? 'null';

  static double? _parseDouble(dynamic val) {
    if (val is double) return val;
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val);
    return null;
  }

  static int? _parseInt(dynamic val) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val);
    return null;
  }

  static bool? _parseBool(dynamic val) {
    if (val is bool) return val;
    if (val is num) return val != 0;
    if (val is String) {
      final lc = val.trim().toLowerCase();
      return (lc == 'true' || lc == '1');
    }
    return null;
  }

  static DateTime? _parseDateTime(dynamic val) {
    if (val is DateTime) return val;
    if (val is String) return DateTime.tryParse(val);
    return null;
  }

  NodeId autoDeduceType<T>(dynamic data) {
    if (T is bool) return NodeId.boolean;
    if (T is String) return NodeId.uastring;
    if (T is int) throw 'Unable to auto deduce type';
    throw 'Unable to deduce type $T for $data';
  }

  Iterable<MapEntry<String, DynamicValue>> get entries {
    if (!isObject) {
      throw StateError('DynamicValue is not an object');
    }
    return (_data as LinkedHashMap<String, DynamicValue>).entries;
  }

  // Lesa TypeId frá server fyrir gefna týpu
  // Nýta TypeId til að búa til readValueId (með nodeid og AttributeId (DATATYPEDEFINITION))

  factory DynamicValue.fromDataTypeDefinition(NodeId root, Schema defs) {
    DynamicValue tree = DynamicValue(typeId: root);

    // Base case
    if (root.isNumeric()) {
      return tree;
    }

    // Assert after trivial return
    assert(defs.containsKey(root));

    // Object case & Array case
    for (int i = 0; i < defs[root]!.ref.fieldsSize; i++) {
      final field = defs[root]!.ref.fields[i];

      if (field.dimensions.isEmpty) {
        tree[field.fieldName] = DynamicValue.fromDataTypeDefinition(field.dataType.toNodeId(), defs);
      } else {
        // Don't support multi dimensional fields for now
        assert(field.dimensions.length == 1);
        var collection = [];
        for (int i = 0; i < field.dimensions[0]; i++) {
          collection.add(DynamicValue.fromDataTypeDefinition(field.dataType.toNodeId(), defs));
        }
        tree[field.fieldName] = DynamicValue.fromList(collection, typeId: field.dataType.toNodeId());
      }
      tree[field.fieldName]._description = field.fieldDescription;
    }
    return tree;
  }

  @override
  DynamicValue get(ByteReader reader, [Endian? endian, insideStruct = false, root = false]) {
    // Assume we are in a structure of DynamicValue where typeId is set but alll values are null
    // {
    // { }
    // [DynamicValue([DynamicValue(null, typeId)], )]
    // }
    // Trivial case ( bool, int, etc )
    if (!isArray && !isObject) {
      // Special case for strings, encoded differetly for structs here then UA_String
      if (typeId == NodeId.uastring && insideStruct) {
        _data = ContiguousStringPayload().get(reader, endian);
      } else {
        _data = nodeIdToPayloadType(typeId).get(reader, endian);
      }
    }

    // We are a object case
    if (isObject) {
      ByteReader bodyReader = reader;
      if (root) {
        final objBytes = reader.read(ffi.sizeOf<raw.UA_ExtensionObject>());
        ffi.Pointer<raw.UA_ExtensionObject> obj = calloc();
        final ref = obj.ref;
        obj
            .cast<ffi.Uint8>()
            .asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>())
            .setRange(0, ffi.sizeOf<raw.UA_ExtensionObject>(), objBytes);
        // Todo only support encoded byte string for now
        assert(ref.encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING);
        final bodyBytes = obj.ref.content.encoded.body.asTypedList();
        bodyReader = ByteReader(bodyBytes, endian: endian ?? Endian.little);
      }
      for (final key in _data.keys) {
        _data[key] = _data[key].get(bodyReader, endian, true);
      }
    }

    // We are a array case
    if (isArray) {
      // Read the size of the stack to increment the
      // read pointer but only if we are not the root
      if (!root) {
        final arrayLength = reader.int32(endian);
        if (arrayLength != asArray.length) {
          throw 'Structure definition and array length from buffer dont match';
        }
      }
      for (int i = 0; i < asArray.length; i++) {
        // if array is root and subsequent type is array we should treat that also as root
        // as in not read the subsequent array length
        _data[i] = _data[i].get(reader, endian, false, root);
      }
    }
    return this;
  }

  @override
  void set(ByteWriter writer, DynamicValue value, [Endian? endian, bool insideStruct = false, root = false]) {
    if (value.isArray) {
      // Don't encode the array length if we are the root
      if (!root) {
        writer.int32(value._data.length, endian);
      }
      for (var i = 0; i < value._data.length; i++) {
        // if array is root and subsequent type is array we should treat that also as root
        // as in not read the subsequent array length
        value._data[i].set(writer, value._data[i], endian, false, root);
      }
    } else if (value.isObject && root) {
      ffi.Pointer<raw.UA_ExtensionObject> obj = calloc<raw.UA_ExtensionObject>();
      obj.ref.content.encoded.typeId.fromNodeId(value.typeId!);
      ByteWriter bodyWriter = ByteWriter();
      value._data.forEach((key, value) => value.set(bodyWriter, value, endian, true));
      obj.ref.content.encoded.body.fromBytes(bodyWriter.toBytes());
      // todo support other encodings
      obj.ref.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      // write the extension object to the writer
      final extObjView = obj.cast<ffi.Uint8>().asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>());
      // here we have made a view into the ext object on the C heap
      // I would like to believe that this is freed when the variant is freed
      writer.write(extObjView);
    } else if (value.isObject) {
      value._data.forEach((key, value) => value.set(writer, value, endian, true));
    } else {
      if (value.isNull) {
        throw StateError('Element type is not set for where value is\n $value');
      }
      //Special case for strings, they are different the UA_Strings when
      // encoded inside of a struct
      if (typeId == NodeId.uastring && insideStruct) {
        ContiguousStringPayload().set(writer, value.value, endian);
      } else {
        nodeIdToPayloadType(value.typeId ?? autoDeduceType(value._data)).set(writer, value.value, endian);
      }
    }
  }
}
