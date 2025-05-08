import 'dart:collection' show LinkedHashMap;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:binarize/binarize.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/generated/open62541_bindings.dart' as raw;
import 'package:open62541/src/types/payloads.dart';
import 'types/create_type.dart';
import 'node_id.dart';

enum DynamicType { object, array, string, boolean, nullValue, unknown, integer, double }

class LocalizedText {
  final String value;
  final String locale;
  LocalizedText(this.value, this.locale);

  factory LocalizedText.from(LocalizedText other) {
    return LocalizedText(other.value, other.locale);
  }

  @override
  String toString() {
    if (value.isNotEmpty && locale.isNotEmpty) return "$locale : $value";
    return value;
  }
}

class EnumField {
  final int value;
  final LocalizedText displayName;
  final LocalizedText description;
  final String name;
  EnumField(this.value, this.name, this.displayName, this.description);

  factory EnumField.from(EnumField other) {
    return EnumField(other.value, other.name, other.displayName, other.description);
  }
}

typedef Schema = Map<NodeId, DynamicValue>;

class DynamicValue extends PayloadType<DynamicValue> {
  dynamic value;
  NodeId? typeId;
  String? name;
  LocalizedText? description;
  LocalizedText? displayName;
  Map<int, EnumField>? enumFields;
  bool isOptional = false;

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
  factory DynamicValue.from(DynamicValue other) {
    var v = DynamicValue();
    if (other.value is DynamicValue) {
      v.value = DynamicValue.from(other.value);
    } else if (other.value is LinkedHashMap) {
      v.value = LinkedHashMap<String, DynamicValue>();
      other.value.forEach((key, value) => v.value[key] = DynamicValue.from(value));
    } else if (other.value is List) {
      v.value = other.value.map((e) => DynamicValue.from(e)).toList();
    } else {
      v.value = other.value;
    }

    if (other.typeId != null) {
      v.typeId = NodeId.from(other.typeId!);
    }
    if (other.displayName != null) {
      v.displayName = LocalizedText.from(other.displayName!);
    }
    if (other.description != null) {
      v.description = LocalizedText.from(other.description!);
    }
    if (other.enumFields != null) {
      v.enumFields = LinkedHashMap<int, EnumField>();
      other.enumFields!.forEach((key, value) => v.enumFields![key] = EnumField.from(value));
    }
    v.name = other.name;
    v.isOptional = other.isOptional;
    return v;
  }
  DynamicValue({this.value, this.description, this.typeId, this.displayName});

  DynamicType get type {
    if (value == null) return DynamicType.nullValue;
    if (value is LinkedHashMap) return DynamicType.object;
    if (value is List<DynamicValue>) return DynamicType.array;
    if (value is String) return DynamicType.string;
    if (value is int) return DynamicType.integer;
    if (value is double) return DynamicType.double;
    if (value is bool) return DynamicType.boolean;
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

  double get asDouble => _parseDouble(value) ?? 0.0;
  int get asInt => _parseInt(value) ?? 0;
  String get asString => value?.toString() ?? '';
  bool get asBool => _parseBool(value) ?? false;
  DateTime? get asDateTime => _parseDateTime(value);

  List<DynamicValue> get asArray =>
      isArray ? value : throw StateError('DynamicValue is not an array, ${value.runtimeType}');

  Map<String, DynamicValue> get asObject =>
      isObject ? value : throw StateError('DynamicValue is not an object, ${value.runtimeType}');

  bool contains(dynamic key) {
    if (key is int && isArray) {
      final list = value as List<DynamicValue>;
      return (key >= 0 && key < list.length);
    } else if (key is String && isObject) {
      return (value as Map<String, DynamicValue>).containsKey(key);
    }
    return false;
  }

  DynamicValue operator [](dynamic key) {
    if (key is int && isArray) {
      final list = value as List<DynamicValue>;
      return (key >= 0 && key < list.length) ? list[key] : throw StateError('Index "$key" out of bounds');
    } else if (key is String && isObject) {
      return (value as Map<String, DynamicValue>).putIfAbsent(key, () => throw StateError('Key "$key" not found'));
    }
    throw StateError('Invalid key type: ${key.runtimeType}');
  }

  operator []=(dynamic key, dynamic passed) {
    // Try to acomidate people setting trivial values directly
    DynamicValue innerValue;
    if (passed is DynamicValue) {
      innerValue = passed;
    } else {
      if (passed is LinkedHashMap<String, dynamic>) {
        innerValue = DynamicValue.fromMap(passed);
      } else if (passed is Map) {
        throw 'Unstable ordering, will not result in correct structures.';
      } else if (passed is List) {
        innerValue = DynamicValue.fromList(passed);
      } else {
        NodeId? foundType = contains(key) ? this[key].typeId : null;
        innerValue = DynamicValue(value: passed, typeId: foundType);
      }
    }
    if (key is int) {
      if (isNull) value = <DynamicValue>[];
      if (isArray) {
        var list = value as List<DynamicValue>;
        if (key > list.length) {
          throw StateError('Index "$key" out of bounds');
        } else if (key == list.length) {
          list.add(innerValue);
        } else {
          list[key] = innerValue;
        }
      } else {
        throw StateError('DynamicValue is not an array');
      }
    } else if (key is String) {
      if (isNull) {
        value = LinkedHashMap<String, DynamicValue>();
      }
      if (isObject) {
        (value as LinkedHashMap<String, DynamicValue>)[key] = innerValue;
      } else {
        throw StateError('DynamicValue is not an object');
      }
    }
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
  String toString() {
    if (enumFields != null) {
      if (value == null) {
        return "null";
      }
      return "${enumFields![value]!.name}(${value.toString()})";
    }
    return "${displayName == null ? '' : displayName!.value} ${description == null ? '' : description!.value} ${value?.toString() ?? 'null'}";
  }

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
    return (value as LinkedHashMap<String, DynamicValue>).entries;
  }

  // Lesa TypeId frá server fyrir gefna týpu
  // Nýta TypeId til að búa til readValueId (með nodeid og AttributeId (DATATYPEDEFINITION))

  factory DynamicValue.fromDataTypeDefinition(NodeId typeId, raw.UA_Variant def) {
    DynamicValue tree = DynamicValue(typeId: typeId);

    // If we know how to deal with this type
    if (nodeIdToPayloadType(typeId) != null) {
      return tree;
    }

    // Check if we are an enum
    final binaryEncodingId = def.type.ref.binaryEncodingId.toNodeId();
    if (binaryEncodingId == NodeId.enumDefinitionDefaultBinary) {
      final enumDefinition = def.data.cast<raw.UA_EnumDefinition>();
      final enumFields = <int, EnumField>{};
      for (int i = 0; i < enumDefinition.ref.fieldsSize; i++) {
        final field = enumDefinition.ref.fields[i];
        enumFields[field.value] =
            EnumField(field.value, field.name.value, field.displayName.localizedText, field.description.localizedText);
      }
      tree.enumFields = enumFields;
      //TODO: This only supports int32 enums for now
      tree.typeId = NodeId.int32;
    } else if (binaryEncodingId == NodeId.structureDefinitionDefaultBinary) {
      final structSchema = def.data.cast<raw.UA_StructureDefinition>();
      // Object case & Array case
      for (int i = 0; i < structSchema.ref.fieldsSize; i++) {
        final field = structSchema.ref.fields[i];

        if (field.dimensions.isEmpty) {
          tree[field.fieldName] = DynamicValue(typeId: field.dataType.toNodeId());
        } else {
          // Don't support multi dimensional fields for now
          assert(field.dimensions.length == 1);
          var collection = [];
          for (int i = 0; i < field.dimensions[0]; i++) {
            collection.add(DynamicValue(typeId: field.dataType.toNodeId()));
          }
          tree[field.fieldName] = DynamicValue.fromList(collection, typeId: field.dataType.toNodeId());
        }
        tree[field.fieldName].isOptional = field.isOptional;
        tree[field.fieldName].description = field.description.localizedText;
        tree[field.fieldName].name = field.name.value;
      }
    } else {
      throw 'Unsupported binary encoding id: $binaryEncodingId for AttributeId UA_ATTRIBUTEID_DATATYPEDEFINITION';
    }
    // Need description and displayname for the root
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
      if (isOptional) {
        throw 'Optional values not supported currently';
      }
      // Special case for strings, encoded differetly for structs here then UA_String
      if (typeId == NodeId.uastring && insideStruct) {
        value = ContiguousStringPayload().get(reader, endian);
      } else {
        final pload = nodeIdToPayloadType(typeId);
        if (pload == null) {
          throw 'Unsupported typeId: $typeId';
        }
        value = pload.get(reader, endian);
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
      for (final key in value.keys) {
        value[key] = value[key].get(bodyReader, endian, true);
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
        value[i] = value[i].get(reader, endian, insideStruct, root);
      }
    }
    return this;
  }

  @override
  void set(ByteWriter writer, DynamicValue value, [Endian? endian, bool insideStruct = false, root = false]) {
    if (value.isArray) {
      // Don't encode the array length if we are the root
      if (!root) {
        writer.int32(value.value.length, endian);
      }
      for (var i = 0; i < value.value.length; i++) {
        // if array is root and subsequent type is array we should treat that also as root
        // as in not read the subsequent array length
        value.value[i].set(writer, value.value[i], endian, insideStruct, root);
      }
    } else if (value.isObject && root) {
      ffi.Pointer<raw.UA_ExtensionObject> obj = calloc<raw.UA_ExtensionObject>();
      obj.ref.content.encoded.typeId.fromNodeId(value.typeId!);
      ByteWriter bodyWriter = ByteWriter();
      value.value.forEach((key, value) => value.set(bodyWriter, value, endian, true));
      obj.ref.content.encoded.body.fromBytes(bodyWriter.toBytes());
      // todo support other encodings
      obj.ref.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      // write the extension object to the writer
      final extObjView = obj.cast<ffi.Uint8>().asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>());
      // here we have made a view into the ext object on the C heap
      // I would like to believe that this is freed when the variant is freed
      writer.write(extObjView);
    } else if (value.isObject) {
      value.value.forEach((key, value) => value.set(writer, value, endian, true));
    } else {
      if (value.isNull) {
        throw StateError('Element type is not set for where value is\n $value');
      }
      //Special case for strings, they are different the UA_Strings when
      // encoded inside of a struct
      if (typeId == NodeId.uastring && insideStruct) {
        ContiguousStringPayload().set(writer, value.value, endian);
      } else {
        nodeIdToPayloadType(value.typeId ?? autoDeduceType(value.value))!.set(writer, value.value, endian);
      }
    }
  }
}
