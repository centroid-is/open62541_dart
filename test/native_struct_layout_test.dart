// The native-layout walk of `variantToValue`, against `UA_DataType` tables
// built by hand in native memory, so every rule of the layout is pinned on
// its own, without a server: `padding` before a member (before the `size_t`
// of an array member, from the start of the union for a union member), the
// `size_t` length + pointer of an array member and the empty-array sentinel,
// the pointer of an optional member (NULL when absent), the switch field of
// a union, the enum type's member table as the enum's fields, every built-in
// kind as a member, a nested Variant / ExtensionObject / DataValue /
// DiagnosticInfo, and the variant-level scalar, array and multi-dimensional
// array of structs. The rules are those of `copyStructure` / `copyUnion` in
// open62541's src/ua_types.c and the `UA_DataTypeMember` comment in
// include/open62541/types.h.
//
// Every native allocation is made with ua_calloc and freed when the test
// ends; nothing here is owned by open62541.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show dateTimeToUaDateTime, getType, getTypeByIndex, variantToValue;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/types/native_decode.dart';
import 'package:open62541/src/ua_allocation.dart' show ua_calloc;

/// A member of a hand-built type: [type] is a `UA_DataType*` (for an enum
/// value it is the value cast to a pointer, the way open62541 stores it).
class Member {
  const Member(this.name, this.type, {this.padding = 0, this.isArray = false, this.isOptional = false});
  final String name;
  final ffi.Pointer<raw.UA_DataType> type;
  final int padding;
  final bool isArray;
  final bool isOptional;
}

/// Native memory a test builds its types and values in, freed by [free].
class Native {
  final List<ffi.Pointer> _owned = [];

  ffi.Pointer<T> alloc<T extends ffi.NativeType>(int bytes) {
    final pointer = ua_calloc.allocate<T>(bytes);
    _owned.add(pointer);
    return pointer;
  }

  /// [bytes] zeroed bytes, for a struct value of that `memSize`.
  ffi.Pointer<ffi.Void> bytes(int bytes) => alloc<ffi.Uint8>(bytes).cast();

  ffi.Pointer<ffi.Char> cstr(String value) {
    final pointer = value.toNativeUtf8(allocator: ua_calloc);
    _owned.add(pointer);
    return pointer.cast();
  }

  /// Points the in-place [string] at a copy of [value].
  void string(raw.UA_String string, String value) {
    string.set(value);
    _owned.add(string.data);
  }

  void nodeId(raw.UA_NodeId target, NodeId value) {
    target.fromNodeId(value);
    if (value.isString()) _owned.add(target.identifier.string.data);
  }

  ffi.Pointer<raw.UA_DataType> type({
    required String name,
    required int typeId,
    int encodingId = 0,
    required raw.UA_DataTypeKind kind,
    required int memSize,
    required List<Member> members,
  }) {
    final type = alloc<raw.UA_DataType>(ffi.sizeOf<raw.UA_DataType>());
    type.ref.typeName = cstr(name);
    type.ref.typeId.fromNodeId(NodeId.fromNumeric(0, typeId));
    type.ref.binaryEncodingId.fromNodeId(NodeId.fromNumeric(0, encodingId));
    type.ref.memSize = memSize;
    type.ref.typeKind = kind;
    type.ref.membersSize = members.length;
    final table = alloc<raw.UA_DataTypeMember>(ffi.sizeOf<raw.UA_DataTypeMember>() * members.length);
    for (var i = 0; i < members.length; i++) {
      final m = members[i];
      table[i].memberName = cstr(m.name);
      table[i].memberType = m.type;
      table[i].padding = m.padding;
      table[i].isArray = m.isArray;
      table[i].isOptional = m.isOptional;
    }
    type.ref.members = table;
    return type;
  }

  /// A variant over [data] of [type]; [dims] empty for a scalar.
  ffi.Pointer<raw.UA_Variant> variant(
    ffi.Pointer<raw.UA_DataType> type,
    ffi.Pointer<ffi.Void> data, [
    List<int> dims = const [],
  ]) {
    final variant = alloc<raw.UA_Variant>(ffi.sizeOf<raw.UA_Variant>());
    variant.ref.type = type;
    variant.ref.data = data;
    if (dims.isNotEmpty) {
      variant.ref.arrayLength = dims.fold(1, (a, b) => a * b);
    }
    if (dims.length > 1) {
      final dimensions = alloc<ffi.Uint32>(ffi.sizeOf<ffi.Uint32>() * dims.length);
      dimensions.asTypedList(dims.length).setAll(0, dims);
      variant.ref.arrayDimensions = dimensions;
      variant.ref.arrayDimensionsSize = dims.length;
    }
    return variant;
  }

  void free() {
    for (final pointer in _owned.reversed) {
      ua_calloc.free(pointer);
    }
    _owned.clear();
  }
}

final sizeT = ffi.sizeOf<ffi.Size>();
final sizePtr = ffi.sizeOf<ffi.Pointer>();
final sizeString = ffi.sizeOf<raw.UA_String>();
final emptyArraySentinel = ffi.Pointer<ffi.Void>.fromAddress(0x01);

void main() {
  late Native native;
  setUp(() => native = Native());
  tearDown(() => native.free());

  ffi.Pointer<raw.UA_DataType> ns0(int index) => getTypeByIndex(index);

  /// `struct { UA_Byte a; UA_Double b; UA_Int16 c; UA_String s; }` with the
  /// alignment padding the compiler would insert: a at 0, b at 8, c at 16,
  /// s at 24; 40 bytes.
  ffi.Pointer<raw.UA_DataType> paddedType() => native.type(
    name: 'Padded',
    typeId: 7001,
    encodingId: 7002,
    kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE,
    memSize: 24 + sizeString,
    members: [
      Member('A', getType(UaTypes.byte)),
      Member('B', getType(UaTypes.double), padding: 7),
      Member('C', getType(UaTypes.int16)),
      Member('S', getType(UaTypes.string), padding: 6),
    ],
  );

  void fillPadded(ffi.Pointer<ffi.Void> p, int a, double b, int c, String s) {
    p.cast<ffi.Uint8>().value = a;
    ffi.Pointer<ffi.Double>.fromAddress(p.address + 8).value = b;
    ffi.Pointer<ffi.Int16>.fromAddress(p.address + 16).value = c;
    native.string(ffi.Pointer<raw.UA_String>.fromAddress(p.address + 24).ref, s);
  }

  group('structure members', () {
    test('padding is skipped before a member; fields are named, typed and ordered', () {
      final type = paddedType();
      final value = native.bytes(type.ref.memSize);
      fillPadded(value, 0x2A, 1.5, -3, 'héllo');

      final decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.isObject, isTrue);
      expect(decoded.typeId, NodeId.fromNumeric(0, 7001));
      expect(decoded.extObjEncodingId, NodeId.fromNumeric(0, 7002));
      expect(decoded.asObject.keys.toList(), ['A', 'B', 'C', 'S']);
      expect(decoded['A'].asInt, 0x2A);
      expect(decoded['A'].typeId, NodeId.byte);
      expect(decoded['A'].name, 'A');
      expect(decoded['B'].asDouble, 1.5);
      expect(decoded['B'].typeId, NodeId.double);
      expect(decoded['C'].asInt, -3);
      expect(decoded['C'].typeId, NodeId.int16);
      expect(decoded['S'].asString, 'héllo');
      expect(decoded['S'].typeId, NodeId.uastring);
      for (final field in decoded.asObject.values) {
        expect(field.isOptional, isFalse);
      }
    });

    test('an array member is a size_t length and a pointer; nested structs and the empty sentinel', () {
      // Inner { UA_Int32 x; size_t namesSize; UA_String *names; }: x at 0,
      // namesSize at 8 (padding 4), names at 16; 24 bytes.
      final inner = native.type(
        name: 'Inner',
        typeId: 7003,
        kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE,
        memSize: 8 + sizeT + sizePtr,
        members: [
          Member('X', getType(UaTypes.int32)),
          Member('Names', getType(UaTypes.string), padding: 4, isArray: true),
        ],
      );
      // Outer { size_t itemsSize; Inner *items; UA_Int32 tail; }: tail at 16,
      // 4 bytes of trailing alignment; 24 bytes.
      final outer = native.type(
        name: 'Outer',
        typeId: 7004,
        kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE,
        memSize: sizeT + sizePtr + 8,
        members: [Member('Items', inner, isArray: true), Member('Tail', getType(UaTypes.int32))],
      );

      final items = native.alloc<ffi.Uint8>(ffi.sizeOf<ffi.Uint8>() * (2 * inner.ref.memSize)).cast<ffi.Void>();
      // items[0]: x = 1, names = ["a", "b"]
      items.cast<ffi.Int32>().value = 1;
      final names = native.alloc<raw.UA_String>(ffi.sizeOf<raw.UA_String>() * 2);
      native.string(names[0], 'a');
      native.string(names[1], 'b');
      ffi.Pointer<ffi.Size>.fromAddress(items.address + 8).value = 2;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(items.address + 16).value = names.cast();
      // items[1]: x = 2, names = [] (length 0, the sentinel pointer)
      final item1 = items.address + inner.ref.memSize;
      ffi.Pointer<ffi.Int32>.fromAddress(item1).value = 2;
      ffi.Pointer<ffi.Size>.fromAddress(item1 + 8).value = 0;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(item1 + 16).value = emptyArraySentinel;

      final value = native.bytes(outer.ref.memSize);
      value.cast<ffi.Size>().value = 2;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(value.address + sizeT).value = items;
      ffi.Pointer<ffi.Int32>.fromAddress(value.address + sizeT + sizePtr).value = 99;

      final decoded = variantToValue(native.variant(outer, value).ref);
      expect(decoded.asObject.keys.toList(), ['Items', 'Tail']);
      final list = decoded['Items'];
      expect(list.isArray, isTrue);
      expect(list.typeId, NodeId.fromNumeric(0, 7003));
      expect(list.name, 'Items');
      expect(list.asArray.length, 2);
      expect(list[0]['X'].asInt, 1);
      expect(list[0]['Names'].asArray.map((n) => n.asString), ['a', 'b']);
      expect(list[0]['Names'][0].typeId, NodeId.uastring);
      expect(list[1]['X'].asInt, 2);
      expect(list[1]['Names'].isArray, isTrue);
      expect(list[1]['Names'].asArray, isEmpty);
      // The walk advanced past the length and the pointer, not past memSize.
      expect(decoded['Tail'].asInt, 99);
    });

    test('an optional member is a pointer, NULL when absent, and the walk continues past it', () {
      // Opt { UA_Int32 a; UA_Double *optB; size_t optCSize; UA_String *optC;
      //       UA_Int32 *optD; UA_Int32 e; }: a 0, optB 8 (padding 4), optCSize
      // 16, optC 24, optD 32, e 40; 48 bytes.
      final type = native.type(
        name: 'Opt',
        typeId: 7005,
        kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT,
        memSize: 8 + sizePtr + sizeT + sizePtr + sizePtr + 8,
        members: [
          Member('A', getType(UaTypes.int32)),
          Member('OptB', getType(UaTypes.double), padding: 4, isOptional: true),
          Member('OptC', getType(UaTypes.string), isArray: true, isOptional: true),
          Member('OptD', getType(UaTypes.int32), isOptional: true),
          Member('E', getType(UaTypes.int32)),
        ],
      );
      final value = native.bytes(type.ref.memSize);
      value.cast<ffi.Int32>().value = 7;
      final optB = native.alloc<ffi.Double>(ffi.sizeOf<ffi.Double>())..value = 2.5;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(value.address + 8).value = optB.cast();
      final optC = native.alloc<raw.UA_String>(ffi.sizeOf<raw.UA_String>());
      native.string(optC[0], 'z');
      ffi.Pointer<ffi.Size>.fromAddress(value.address + 16).value = 1;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(value.address + 24).value = optC.cast();
      // optD stays NULL (calloc).
      ffi.Pointer<ffi.Int32>.fromAddress(value.address + 40).value = 11;

      final decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.asObject.keys.toList(), ['A', 'OptB', 'OptC', 'OptD', 'E']);
      expect(decoded['A'].asInt, 7);
      expect(decoded['A'].isOptional, isFalse);
      expect(decoded['OptB'].asDouble, 2.5);
      expect(decoded['OptB'].isOptional, isTrue);
      expect(decoded['OptC'].asArray.map((s) => s.asString), ['z']);
      expect(decoded['OptC'].isOptional, isTrue);
      expect(decoded['OptD'].isNull, isTrue);
      expect(decoded['OptD'].isOptional, isTrue);
      expect(decoded['OptD'].typeId, NodeId.int32);
      expect(decoded['OptD'].name, 'OptD');
      expect(decoded['E'].asInt, 11);
    });

    test('an absent optional array member is NULL with its length ignored', () {
      // { size_t size; UA_String *opt; UA_Int32 after; }
      final type = native.type(
        name: 'OptArray',
        typeId: 7006,
        kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT,
        memSize: sizeT + sizePtr + 8,
        members: [
          Member('Opt', getType(UaTypes.string), isArray: true, isOptional: true),
          Member('After', getType(UaTypes.int32)),
        ],
      );
      final value = native.bytes(type.ref.memSize);
      value.cast<ffi.Size>().value = 5; // stale length, pointer NULL
      ffi.Pointer<ffi.Int32>.fromAddress(value.address + sizeT + sizePtr).value = 3;
      final decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded['Opt'].isNull, isTrue);
      expect(decoded['Opt'].isOptional, isTrue);
      expect(decoded['After'].asInt, 3);
    });
  });

  group('union', () {
    // U { UA_UInt32 switchField; union { UA_Int32 i; UA_String s;
    //     struct { size_t n; UA_Int32 *arr; } arr; } fields; }: the union at 8
    // (its alignment is 8); 24 bytes. The padding of every member is 8, the
    // offset from the start of the union type.
    ffi.Pointer<raw.UA_DataType> unionType() => native.type(
      name: 'U',
      typeId: 7007,
      encodingId: 7008,
      kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_UNION,
      memSize: 8 + 16,
      members: [
        Member('I', getType(UaTypes.int32), padding: 8),
        Member('S', getType(UaTypes.string), padding: 8),
        Member('Arr', getType(UaTypes.int32), padding: 8, isArray: true),
      ],
    );

    test('switch field 0: no member', () {
      final type = unionType();
      final value = native.bytes(type.ref.memSize);
      final decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.isObject, isTrue);
      expect(decoded.asObject, isEmpty);
      expect(decoded.typeId, NodeId.fromNumeric(0, 7007));
      expect(decoded.extObjEncodingId, NodeId.fromNumeric(0, 7008));
    });

    test('switch field selects members[switch - 1] at its padding', () {
      final type = unionType();
      final value = native.bytes(type.ref.memSize);
      value.cast<ffi.Uint32>().value = 1;
      ffi.Pointer<ffi.Int32>.fromAddress(value.address + 8).value = -5;
      var decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.asObject.keys.toList(), ['I']);
      expect(decoded['I'].asInt, -5);
      expect(decoded['I'].name, 'I');

      value.cast<ffi.Uint32>().value = 2;
      native.string(ffi.Pointer<raw.UA_String>.fromAddress(value.address + 8).ref, 'text');
      decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.asObject.keys.toList(), ['S']);
      expect(decoded['S'].asString, 'text');
    });

    test('an array member of a union', () {
      final type = unionType();
      final value = native.bytes(type.ref.memSize);
      value.cast<ffi.Uint32>().value = 3;
      final arr = native.alloc<ffi.Int32>(ffi.sizeOf<ffi.Int32>() * 3)..asTypedList(3).setAll(0, [1, 2, 3]);
      ffi.Pointer<ffi.Size>.fromAddress(value.address + 8).value = 3;
      ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(value.address + 8 + sizeT).value = arr.cast();
      final decoded = variantToValue(native.variant(type, value).ref);
      expect(decoded.asObject.keys.toList(), ['Arr']);
      expect(decoded['Arr'].asArray.map((v) => v.asInt), [1, 2, 3]);
    });

    test('a switch field past the member table is an error, not a read', () {
      final type = unionType();
      final value = native.bytes(type.ref.memSize);
      value.cast<ffi.Uint32>().value = 4;
      expect(() => variantToValue(native.variant(type, value).ref), throwsStateError);
    });
  });

  group('member kinds', () {
    /// A struct with the single member `Value` of [memberType], at offset 0.
    ffi.Pointer<raw.UA_DataType> single(ffi.Pointer<raw.UA_DataType> memberType, {int typeId = 7100}) => native.type(
      name: 'Single',
      typeId: typeId,
      kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE,
      memSize: memberType.ref.memSize,
      members: [Member('Value', memberType)],
    );

    DynamicValue decodeSingle(ffi.Pointer<raw.UA_DataType> memberType, void Function(ffi.Pointer<ffi.Void>) fill) {
      final type = single(memberType);
      final value = native.bytes(type.ref.memSize);
      fill(value);
      return variantToValue(native.variant(type, value).ref)['Value'];
    }

    test('Boolean, Float, DateTime, StatusCode, XmlElement, ByteString', () {
      final boolean = decodeSingle(getType(UaTypes.boolean), (p) => p.cast<ffi.Uint8>().value = 1);
      expect(boolean.value, isTrue);
      expect(boolean.typeId, NodeId.boolean);

      final float = decodeSingle(getType(UaTypes.float), (p) => p.cast<ffi.Float>().value = 0.5);
      expect(float.asDouble, 0.5);
      expect(float.typeId, NodeId.float);

      final when = DateTime.utc(2021, 3, 4, 5, 6, 7);
      final dateTime = decodeSingle(
        getType(UaTypes.dateTime),
        (p) => p.cast<ffi.Int64>().value = dateTimeToUaDateTime(when),
      );
      expect(dateTime.value, when);
      expect(dateTime.typeId, NodeId.datetime);

      final status = decodeSingle(getType(UaTypes.statusCode), (p) => p.cast<ffi.Uint32>().value = 0x80340000);
      expect(status.asInt, 0x80340000);
      expect(status.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_STATUSCODE));

      final xml = decodeSingle(getType(UaTypes.xmlElement), (p) => native.string(p.cast<raw.UA_String>().ref, '<a/>'));
      expect(xml.asString, '<a/>');
      expect(xml.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_XMLELEMENT));

      final bytes = decodeSingle(getType(UaTypes.byteString), (p) => native.string(p.cast<raw.UA_String>().ref, 'ab'));
      expect(bytes.value, isA<Uint8List>());
      expect(bytes.value, [0x61, 0x62]);
      expect(bytes.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_BYTESTRING));

      // A null string (NULL data, length 0) is an empty string.
      final empty = decodeSingle(getType(UaTypes.string), (_) {});
      expect(empty.asString, '');
    });

    test('Guid, NodeId, ExpandedNodeId, QualifiedName, LocalizedText', () {
      final guid = decodeSingle(getType(UaTypes.guid), (p) {
        final g = p.cast<raw.UA_Guid>().ref;
        g.data1 = 0x09087e75;
        g.data2 = 0x8e5e;
        g.data3 = 0x499b;
        final tail = [0x95, 0x4f, 0xf2, 0xa9, 0x60, 0x3d, 0xb2, 0x8a];
        for (var i = 0; i < 8; i++) {
          g.data4[i] = tail[i];
        }
      });
      expect(guid.asString, '09087e75-8e5e-499b-954f-f2a9603db28a');
      expect(guid.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_GUID));

      final numeric = decodeSingle(
        getType(UaTypes.nodeId),
        (p) => native.nodeId(p.cast<raw.UA_NodeId>().ref, NodeId.fromNumeric(3, 42)),
      );
      expect(numeric.value, NodeId.fromNumeric(3, 42));
      expect(numeric.typeId, NodeId.nodeId);
      final string = decodeSingle(
        getType(UaTypes.nodeId),
        (p) => native.nodeId(p.cast<raw.UA_NodeId>().ref, NodeId.fromString(2, 'the.id')),
      );
      expect(string.value, NodeId.fromString(2, 'the.id'));

      final expanded = decodeSingle(getType(UaTypes.expandedNodeId), (p) {
        final e = p.cast<raw.UA_ExpandedNodeId>().ref;
        native.nodeId(e.nodeId, NodeId.fromNumeric(1, 9));
        native.string(e.namespaceUri, 'urn:ns');
        e.serverIndex = 4;
      });
      expect(expanded.asObject.keys.toList(), ['NodeId', 'NamespaceUri', 'ServerIndex']);
      expect(expanded['NodeId'].value, NodeId.fromNumeric(1, 9));
      expect(expanded['NamespaceUri'].asString, 'urn:ns');
      expect(expanded['ServerIndex'].asInt, 4);
      expect(expanded.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_EXPANDEDNODEID));

      final qualified = decodeSingle(getType(UaTypes.qualifiedName), (p) {
        final q = p.cast<raw.UA_QualifiedName>().ref;
        q.namespaceIndex = 5;
        native.string(q.name, 'Name');
      });
      expect(qualified.asObject.keys.toList(), ['NamespaceIndex', 'Name']);
      expect(qualified['NamespaceIndex'].asInt, 5);
      expect(qualified['Name'].asString, 'Name');
      expect(qualified.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_QUALIFIEDNAME));

      final localized = decodeSingle(getType(UaTypes.localizedText), (p) {
        final l = p.cast<raw.UA_LocalizedText>().ref;
        native.string(l.locale, 'en');
        native.string(l.text, 'Hello');
      });
      expect(localized.value, LocalizedText('Hello', 'en'));
      expect(localized.typeId, NodeId.localizedText);
    });

    test('an enum member is Int32 with the enum type\'s members as fields', () {
      final enumType = native.type(
        name: 'Temperature',
        typeId: 7101,
        kind: raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM,
        memSize: 4,
        members: [
          Member('Cold', ffi.Pointer.fromAddress(0)),
          Member('Warm', ffi.Pointer.fromAddress(1)),
          Member('Hot', ffi.Pointer.fromAddress(7)),
        ],
      );
      final value = decodeSingle(enumType, (p) => p.cast<ffi.Int32>().value = 7);
      expect(value.asInt, 7);
      expect(value.typeId, NodeId.int32);
      expect(value.enumFields!.keys.toList(), [0, 1, 7]);
      expect(value.enumFields![7]!.name, 'Hot');
      expect(value.toString(), 'Hot(7)');
    });

    test('a nested Variant is decoded through variantToValue', () {
      final value = decodeSingle(getType(UaTypes.variant), (p) {
        final v = p.cast<raw.UA_Variant>().ref;
        v.type = getType(UaTypes.int32);
        v.data = (native.alloc<ffi.Int32>(ffi.sizeOf<ffi.Int32>())..value = 77).cast();
      });
      expect(value.asInt, 77);
      expect(value.typeId, NodeId.int32);
    });

    test('a nested ExtensionObject: decoded, encoded unknown, encoded with a schema', () {
      // Decoded: a UA_TYPES Range in it.
      final decoded = decodeSingle(getType(UaTypes.extensionObject), (p) {
        final eo = p.cast<raw.UA_ExtensionObject>().ref;
        eo.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED.value;
        eo.content.decoded.type = ns0(raw.UA_TYPES_RANGE);
        final range = native.alloc<ffi.Double>(ffi.sizeOf<ffi.Double>() * 2)..asTypedList(2).setAll(0, [-1, 1]);
        eo.content.decoded.data = range.cast();
      });
      expect(decoded.asObject.keys.toList(), ['Low', 'High']);
      expect(decoded['Low'].asDouble, -1);
      expect(decoded['High'].asDouble, 1);
      expect(decoded.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE));

      // Encoded, unknown type: the body is kept.
      final unknown = decodeSingle(getType(UaTypes.extensionObject), (p) {
        final eo = p.cast<raw.UA_ExtensionObject>().ref;
        eo.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
        native.nodeId(eo.content.encoded.typeId, NodeId.fromNumeric(1, 5000));
        native.string(eo.content.encoded.body, 'raw');
      });
      expect(unknown.value, [0x72, 0x61, 0x77]);
      expect(unknown.typeId, NodeId.structure);
      expect(unknown.extObjEncodingId, NodeId.fromNumeric(1, 5000));

      // Encoded, a type open62541 knows (the encoding id of Range, i=886) and
      // no schema: the body is decoded with UA_decodeBinary and walked.
      final known = decodeSingle(getType(UaTypes.extensionObject), (p) {
        final eo = p.cast<raw.UA_ExtensionObject>().ref;
        eo.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
        native.nodeId(eo.content.encoded.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE_ENCODING_DEFAULTBINARY));
        final body = native.alloc<ffi.Uint8>(16);
        body.cast<ffi.Double>().asTypedList(2).setAll(0, [-2.5, 2.5]);
        eo.content.encoded.body.length = 16;
        eo.content.encoded.body.data = body;
      });
      expect(known.asObject.keys.toList(), ['Low', 'High']);
      expect(known['Low'].asDouble, -2.5);
      expect(known['High'].asDouble, 2.5);
      expect(known.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE));
      expect(known.extObjEncodingId, NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE_ENCODING_DEFAULTBINARY));

      // Encoded, a known type, a body that does not decode: an error, and
      // nothing left behind (the ASan runs check that).
      final type2 = single(getType(UaTypes.extensionObject));
      final value2 = native.bytes(type2.ref.memSize);
      final eo2 = value2.cast<raw.UA_ExtensionObject>().ref;
      eo2.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      native.nodeId(eo2.content.encoded.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE_ENCODING_DEFAULTBINARY));
      final short = native.alloc<ffi.Uint8>(4);
      eo2.content.encoded.body.length = 4;
      eo2.content.encoded.body.data = short;
      expect(() => variantToValue(native.variant(type2, value2).ref), throwsA(isA<UaStatusException>()));

      // Encoded, with a schema for its type in `defs`: decoded through it.
      final schemaId = NodeId.fromString(1, 'MyType');
      final schema = DynamicValue(typeId: schemaId);
      schema['A'] = DynamicValue(typeId: NodeId.int32);
      schema['B'] = DynamicValue(typeId: NodeId.uastring);
      final type = single(getType(UaTypes.extensionObject));
      final value = native.bytes(type.ref.memSize);
      final eo = value.cast<raw.UA_ExtensionObject>().ref;
      eo.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      native.nodeId(eo.content.encoded.typeId, schemaId);
      final body = native.alloc<ffi.Uint8>(ffi.sizeOf<ffi.Uint8>() * 10)
        ..asTypedList(10).setAll(0, [42, 0, 0, 0, 2, 0, 0, 0, 0x68, 0x69]);
      eo.content.encoded.body.length = 10;
      eo.content.encoded.body.data = body;
      final withSchema = variantToValue(native.variant(type, value).ref, defs: {schemaId: schema})['Value'];
      expect(withSchema['A'].asInt, 42);
      expect(withSchema['B'].asString, 'hi');
      expect(withSchema.typeId, schemaId);
      expect(withSchema.extObjEncodingId, schemaId);
      // The schema itself is untouched.
      expect(schema['A'].isNull, isTrue);
    });

    test('a nested DataValue is an object of value, status and timestamps', () {
      final when = DateTime.utc(2020, 1, 2, 3, 4, 5);
      final value = decodeSingle(getType(UaTypes.dataValue), (p) {
        final dv = p.cast<raw.UA_DataValue>().ref;
        dv.value.type = getType(UaTypes.int32);
        dv.value.data = (native.alloc<ffi.Int32>(ffi.sizeOf<ffi.Int32>())..value = 9).cast();
        dv.status = 0x80000000;
        dv.sourceTimestamp = dateTimeToUaDateTime(when);
        dv.serverTimestamp = dateTimeToUaDateTime(when);
        dv.substitute = 0x01 | 0x02 | 0x04; // hasValue, hasStatus, hasSourceTimestamp
      });
      expect(value.asObject.keys.toList(), ['Value', 'StatusCode', 'SourceTimestamp', 'ServerTimestamp']);
      expect(value['Value'].asInt, 9);
      expect(value['StatusCode'].asInt, 0x80000000);
      expect(value['SourceTimestamp'].value, when);
      expect(value['ServerTimestamp'].isNull, isTrue, reason: 'hasServerTimestamp is clear');
      expect(value.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_DATAVALUE));
    });

    test('a nested DiagnosticInfo follows its flags and its inner info', () {
      final value = decodeSingle(getType(UaTypes.diagnosticInfo), (p) {
        final info = p.cast<raw.UA_DiagnosticInfo>().ref;
        info.substitute = 0x01 | 0x10 | 0x20 | 0x40;
        info.symbolicId = 3;
        info.namespaceUri = 8; // flag clear: not reported
        native.string(info.additionalInfo, 'more');
        info.innerStatusCode = 0x80010000;
        final inner = native.alloc<raw.UA_DiagnosticInfo>(ffi.sizeOf<raw.UA_DiagnosticInfo>());
        inner.ref.substitute = 0x08;
        inner.ref.locale = 2;
        info.innerDiagnosticInfo = inner;
      });
      expect(value['SymbolicId'].asInt, 3);
      expect(value['NamespaceUri'].isNull, isTrue);
      expect(value['LocalizedText'].isNull, isTrue);
      expect(value['Locale'].isNull, isTrue);
      expect(value['AdditionalInfo'].asString, 'more');
      expect(value['InnerStatusCode'].asInt, 0x80010000);
      final inner = value['InnerDiagnosticInfo'];
      expect(inner['Locale'].asInt, 2);
      expect(inner['SymbolicId'].isNull, isTrue);
      expect(inner['InnerDiagnosticInfo'].isNull, isTrue);
      expect(value.typeId, NodeId.fromNumeric(0, raw.UA_NS0ID_DIAGNOSTICINFO));
    });
  });

  group('variant level', () {
    test('an array of structs: arrayLength elements, memSize apart', () {
      final type = paddedType();
      final elements = native.bytes(3 * type.ref.memSize);
      for (var i = 0; i < 3; i++) {
        fillPadded(ffi.Pointer.fromAddress(elements.address + i * type.ref.memSize), i, i * 0.5, -i, 's$i');
      }
      final decoded = variantToValue(native.variant(type, elements, [3]).ref);
      expect(decoded.isArray, isTrue);
      expect(decoded.typeId, NodeId.fromNumeric(0, 7001));
      expect(decoded.asArray.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(decoded[i]['A'].asInt, i);
        expect(decoded[i]['B'].asDouble, i * 0.5);
        expect(decoded[i]['C'].asInt, -i);
        expect(decoded[i]['S'].asString, 's$i');
        expect(decoded[i].typeId, NodeId.fromNumeric(0, 7001));
      }
    });

    test('a multi-dimensional array of structs is nested lists, row-major', () {
      final type = paddedType();
      final elements = native.bytes(6 * type.ref.memSize);
      for (var i = 0; i < 6; i++) {
        fillPadded(ffi.Pointer.fromAddress(elements.address + i * type.ref.memSize), i, 0, 0, '');
      }
      final decoded = variantToValue(native.variant(type, elements, [2, 3]).ref);
      expect(decoded.asArray.length, 2);
      expect(decoded[0].asArray.length, 3);
      expect(decoded[1].asArray.length, 3);
      expect(
        [for (final row in decoded.asArray) row.asArray.map((e) => e['A'].asInt).toList()],
        [
          [0, 1, 2],
          [3, 4, 5],
        ],
      );
    });

    test('an empty array of structs is an empty list', () {
      final type = paddedType();
      final variant = native.variant(type, emptyArraySentinel);
      final decoded = variantToValue(variant.ref);
      expect(decoded.isArray, isTrue);
      expect(decoded.asArray, isEmpty);
    });

    test('an enum open62541 knows, with no schema, is Int32 with its fields', () {
      final value = native.alloc<ffi.Int32>(ffi.sizeOf<ffi.Int32>())..value = 3;
      final decoded = variantToValue(native.variant(ns0(raw.UA_TYPES_SERVERSTATE), value.cast()).ref);
      expect(decoded.asInt, 3);
      expect(decoded.typeId, NodeId.int32);
      expect(decoded.enumFields![3]!.name, 'Suspended');
      expect(decoded.enumFields!.length, 8);
    });
  });

  group('UA_TYPES lookup', () {
    test('nativeEnumFields of ServerState', () {
      final fields = nativeEnumFields(ns0(raw.UA_TYPES_SERVERSTATE));
      expect(fields.map((k, v) => MapEntry(k, v.name)), {
        0: 'Running',
        1: 'Failed',
        2: 'NoConfiguration',
        3: 'Suspended',
        4: 'Shutdown',
        5: 'Test',
        6: 'CommunicationFault',
        7: 'Unknown',
      });
    });

    test('findNs0DataType and ns0BinaryEncodingId', () {
      expect(
        findNs0DataType(NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE))!.ref.typeKind,
        raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE,
      );
      expect(findNs0DataType(NodeId.int32)!.ref.typeKind, raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32);
      expect(findNs0DataType(NodeId.fromNumeric(1, raw.UA_NS0ID_RANGE)), isNull);
      expect(findNs0DataType(NodeId.fromString(0, 'Range')), isNull);
      expect(findNs0DataType(NodeId.fromNumeric(0, 999999)), isNull);
      expect(
        ns0BinaryEncodingId(NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE)),
        NodeId.fromNumeric(0, raw.UA_NS0ID_RANGE_ENCODING_DEFAULTBINARY),
      );
      expect(
        ns0BinaryEncodingId(NodeId.fromNumeric(0, raw.UA_NS0ID_SERVERSTATUSDATATYPE)),
        NodeId.fromNumeric(0, raw.UA_NS0ID_SERVERSTATUSDATATYPE_ENCODING_DEFAULTBINARY),
      );
      // Not a structure: no encoding id.
      expect(ns0BinaryEncodingId(NodeId.int32), isNull);
      expect(ns0BinaryEncodingId(NodeId.fromNumeric(0, raw.UA_NS0ID_SERVERSTATE)), isNull);
    });
  });
}
