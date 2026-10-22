// layoutStructure, the member layout addCustomType registers a custom
// structure with, against the C layout from two sources: the `UA_TYPES`
// tables open62541's generator filled with `offsetof`/`sizeof`, and Dart FFI
// structs (laid out by the target's C ABI) read back through decodeNative.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/src/common.dart' show getType, getTypeByIndex;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/types/native_decode.dart';
import 'package:open62541/src/types/struct_layout.dart';
import 'package:open62541/src/ua_allocation.dart' show ua_calloc;

final class _ByteString extends ffi.Struct {
  @ffi.Uint8()
  external int a;
  external raw.UA_String b;
}

final class _BoolInt64Array extends ffi.Struct {
  @ffi.Bool()
  external bool a;
  @ffi.Size()
  external int bLength;
  external ffi.Pointer<ffi.Int64> b;
}

final class _StringByteDouble extends ffi.Struct {
  external raw.UA_String a;
  @ffi.Uint8()
  external int b;
  @ffi.Double()
  external double c;
}

final class _ByteOptInt16Byte extends ffi.Struct {
  @ffi.Uint8()
  external int a;
  external ffi.Pointer<ffi.Int16> b;
  @ffi.Uint8()
  external int c;
}

final class _Inner extends ffi.Struct {
  @ffi.Double()
  external double x;
  external raw.UA_String y;
}

final class _ByteNested extends ffi.Struct {
  @ffi.Uint8()
  external int a;
  external _Inner b;
}

typedef _Member = ({String name, ffi.Pointer<raw.UA_DataType> type, bool isArray, bool isOptional});

_Member _m(String name, ffi.Pointer<raw.UA_DataType> type, {bool isArray = false, bool isOptional = false}) =>
    (name: name, type: type, isArray: isArray, isOptional: isOptional);

void main() {
  final owned = <ffi.Pointer>[];
  tearDown(() {
    for (final pointer in owned.reversed) {
      ua_calloc.free(pointer);
    }
    owned.clear();
  });

  ffi.Pointer<T> alloc<T extends ffi.NativeType>(int bytes) {
    final pointer = ua_calloc.allocate<T>(bytes);
    owned.add(pointer);
    return pointer;
  }

  void string(raw.UA_String target, String value) {
    target.set(value);
    owned.add(target.data);
  }

  ffi.Pointer<raw.UA_DataType> structure(List<_Member> members) {
    final type = alloc<raw.UA_DataType>(ffi.sizeOf<raw.UA_DataType>());
    type.ref.typeKind = members.any((m) => m.isOptional)
        ? raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT
        : raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE;
    type.ref.membersSize = members.length;
    type.ref.members = alloc<raw.UA_DataTypeMember>(ffi.sizeOf<raw.UA_DataTypeMember>() * members.length);
    for (var i = 0; i < members.length; i++) {
      final name = members[i].name.toNativeUtf8(allocator: ua_calloc);
      owned.add(name);
      type.ref.members[i].memberName = name.cast();
      type.ref.members[i].memberType = members[i].type;
      type.ref.members[i].isArray = members[i].isArray;
      type.ref.members[i].isOptional = members[i].isOptional;
    }
    layoutStructure(type);
    return type;
  }

  test('every structure in UA_TYPES gets the padding and size its C compiler gave it', () {
    var checked = 0;
    for (var i = 0; i < raw.UA_TYPES_COUNT; i++) {
      final generated = getTypeByIndex(i);
      final kind = generated.ref.typeKind;
      if (kind != raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE &&
          kind != raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT) {
        continue;
      }
      final copy = alloc<raw.UA_DataType>(ffi.sizeOf<raw.UA_DataType>());
      copy.ref = generated.ref;
      copy.ref.memSize = 0;
      final count = generated.ref.membersSize;
      copy.ref.members = alloc<raw.UA_DataTypeMember>(ffi.sizeOf<raw.UA_DataTypeMember>() * (count == 0 ? 1 : count));
      for (var j = 0; j < count; j++) {
        copy.ref.members[j] = generated.ref.members[j];
        copy.ref.members[j].padding = 0;
      }

      layoutStructure(copy);

      final name = generated.ref.typeName.cast<Utf8>().toDartString();
      for (var j = 0; j < count; j++) {
        expect(copy.ref.members[j].padding, generated.ref.members[j].padding, reason: '$name member $j');
      }
      expect(copy.ref.memSize, generated.ref.memSize, reason: '$name memSize');
      checked++;
    }
    expect(checked, greaterThan(100));
  });

  group('a wide member after a narrow one sits where the C struct has it', () {
    test('Byte, String', () {
      final type = structure([_m('a', getType(UaTypes.byte)), _m('b', getType(UaTypes.string))]);
      expect(type.ref.memSize, ffi.sizeOf<_ByteString>());

      final value = alloc<_ByteString>(ffi.sizeOf<_ByteString>());
      value.ref.a = 0xAB;
      string(value.ref.b, 'after a byte');
      final decoded = decodeNative(value.cast(), type);
      expect(decoded['a'].value, 0xAB);
      expect(decoded['b'].value, 'after a byte');
    });

    test('Boolean, Int64 array', () {
      final type = structure([_m('a', getType(UaTypes.boolean)), _m('b', getType(UaTypes.int64), isArray: true)]);
      expect(type.ref.memSize, ffi.sizeOf<_BoolInt64Array>());

      final value = alloc<_BoolInt64Array>(ffi.sizeOf<_BoolInt64Array>());
      value.ref.a = true;
      value.ref.bLength = 3;
      value.ref.b = alloc<ffi.Int64>(3 * ffi.sizeOf<ffi.Int64>());
      value.ref.b.asTypedList(3).setAll(0, [-1, 1 << 40, 3]);
      final decoded = decodeNative(value.cast(), type);
      expect(decoded['a'].value, true);
      expect(decoded['b'].asArray.map((e) => e.value), [-1, 1 << 40, 3]);
    });

    test('String, Byte, Double', () {
      final type = structure([
        _m('a', getType(UaTypes.string)),
        _m('b', getType(UaTypes.byte)),
        _m('c', getType(UaTypes.double)),
      ]);
      expect(type.ref.memSize, ffi.sizeOf<_StringByteDouble>());

      final value = alloc<_StringByteDouble>(ffi.sizeOf<_StringByteDouble>());
      string(value.ref.a, 'lead');
      value.ref.b = 0x7F;
      value.ref.c = 2.5;
      final decoded = decodeNative(value.cast(), type);
      expect(decoded['a'].value, 'lead');
      expect(decoded['b'].value, 0x7F);
      expect(decoded['c'].value, 2.5);
    });

    test('Byte, optional Int16 (a pointer), Byte', () {
      final type = structure([
        _m('a', getType(UaTypes.byte)),
        _m('b', getType(UaTypes.int16), isOptional: true),
        _m('c', getType(UaTypes.byte)),
      ]);
      expect(type.ref.typeKind, raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT);
      expect(type.ref.memSize, ffi.sizeOf<_ByteOptInt16Byte>());

      final value = alloc<_ByteOptInt16Byte>(ffi.sizeOf<_ByteOptInt16Byte>());
      value.ref.a = 9;
      value.ref.b = alloc<ffi.Int16>(ffi.sizeOf<ffi.Int16>())..value = -1234;
      value.ref.c = 0xEE;
      final decoded = decodeNative(value.cast(), type);
      expect(decoded['a'].value, 9);
      expect(decoded['b'].value, -1234);
      expect(decoded['c'].value, 0xEE);
    });

    test('Byte, nested {Double, String}', () {
      final inner = structure([_m('x', getType(UaTypes.double)), _m('y', getType(UaTypes.string))]);
      expect(inner.ref.memSize, ffi.sizeOf<_Inner>());
      final type = structure([_m('a', getType(UaTypes.byte)), _m('b', inner)]);
      expect(type.ref.memSize, ffi.sizeOf<_ByteNested>());

      final value = alloc<_ByteNested>(ffi.sizeOf<_ByteNested>());
      value.ref.a = 5;
      value.ref.b.x = -0.125;
      string(value.ref.b.y, 'inner');
      final decoded = decodeNative(value.cast(), type);
      expect(decoded['a'].value, 5);
      expect(decoded['b']['x'].value, -0.125);
      expect(decoded['b']['y'].value, 'inner');
    });
  });
}
