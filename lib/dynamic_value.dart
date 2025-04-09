import 'src/types/abstract.dart';
import 'dart:collection' show LinkedHashMap;

enum DynamicType {
  object,
  array,
  string,
  boolean,
  nullValue,
  unknown,
  integer,
  float,
}

class DynamicValue {
  List<MixinNodeIdType> typeDefinitions = [];
  dynamic _data;
  String id;

  DynamicValue(this.id);

  DynamicType get type {
    if (_data == null) return DynamicType.nullValue;
    if (_data is LinkedHashMap) return DynamicType.object;
    if (_data is List<DynamicValue>) return DynamicType.array;
    if (_data is String) return DynamicType.string;
    if (_data is int) return DynamicType.integer;
    if (_data is double) return DynamicType.float;
    if (_data is bool) return DynamicType.boolean;
    return DynamicType.unknown;
  }

  // Accessors for specific types
  bool get isNull => type == DynamicType.nullValue;
  bool get isObject => type == DynamicType.object;
  bool get isArray => type == DynamicType.array;
  bool get isString => type == DynamicType.string;
  bool get isInteger => type == DynamicType.integer;
  bool get isFloat => type == DynamicType.float;
  bool get isBoolean => type == DynamicType.boolean;

  double get asDouble => _parseDouble(_data) ?? 0.0;
  int get asInt => _parseInt(_data) ?? 0;
  String get asString => _data?.toString() ?? '';
  bool get asBool => _parseBool(_data) ?? false;
  DateTime? get asDateTime => _parseDateTime(_data);
  dynamic get asDynamic => _data;

  List<DynamicValue> get asArray => isArray
      ? _data
      : throw StateError('DynamicValue is not an array, ${_data.runtimeType}');

  Map<String, DynamicValue> get asObject => isObject
      ? _data
      : throw StateError('DynamicValue is not an object, ${_data.runtimeType}');

  DynamicValue operator [](dynamic key) {
    if (key is int && isArray) {
      final list = _data as List<DynamicValue>;
      return (key >= 0 && key < list.length)
          ? list[key]
          : throw StateError('Index "$key" out of bounds');
    } else if (key is String && isObject) {
      return (_data as Map<String, DynamicValue>)
          .putIfAbsent(key, () => throw StateError('Key "$key" not found'));
    }
    throw StateError('Invalid key type: ${key.runtimeType}');
  }

  operator []=(dynamic key, DynamicValue value) {
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
        _data = <String, DynamicValue>{}.cast<String, DynamicValue>()
            as LinkedHashMap<String, DynamicValue>;
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
    return converter != null
        ? map.map((k, v) => MapEntry(k, converter(v)))
        : {};
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

  Iterable<MapEntry<String, DynamicValue>> get entries {
    if (!isObject) {
      throw StateError('DynamicValue is not an object');
    }
    return (_data as LinkedHashMap<String, DynamicValue>).entries;
  }
}
