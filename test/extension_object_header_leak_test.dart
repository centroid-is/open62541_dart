import 'dart:ffi' as ffi;

import 'package:test/test.dart';

import 'package:open62541/src/common.dart';
import 'package:open62541/src/dynamic_value.dart';
import 'package:open62541/src/node_id.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'schema_util.dart';

/// Regression test for the extension-object header leak.
///
/// OpcUaDynamicValueSerializer.deserialize used to calloc a UA_ExtensionObject
/// to read the header of every struct-valued variant -- once per struct
/// notification, per struct read, and per ELEMENT of an array of structs -- and
/// never freed it (48 bytes each). serialize did the same for every struct
/// written. On a station subscribing whole machine structs that was about
/// 1.07 million allocations an hour, ~70 MB/h of allocator growth before arena
/// fragmentation, against a measured 97-110 MiB/h process leak.
///
/// The check is a counting one, not an RSS one: ua_allocation.dart keeps
/// running totals of the allocations and frees made through ua_malloc /
/// ua_calloc. Decoding N variants must leave (allocs - frees) exactly where it
/// was. Before the fix every decode left one allocation behind (three per
/// three-element array); after it, none.
void main() {
  final structId = NodeId.fromString(4, 'LeakTestStruct');

  DynamicValue schema() {
    final def = DynamicValue(typeId: structId);
    def['a'] = buildField(NodeId.int32, 'a', [], '');
    def['b'] = buildField(NodeId.double, 'b', [], '');
    def['c'] = buildField(NodeId.uastring, 'c', [], '');
    return def;
  }

  DynamicValue instance(int i) {
    final v = DynamicValue(typeId: structId);
    v['a'] = DynamicValue(value: i, typeId: NodeId.int32);
    v['b'] = DynamicValue(value: i * 0.5, typeId: NodeId.double);
    v['c'] = DynamicValue(value: 'item $i', typeId: NodeId.uastring);
    return v;
  }

  int outstanding() => uaAllocCount - uaFreeCount;

  test('decoding a struct-valued variant allocates nothing it does not free', () {
    final variant = valueToVariant(instance(7));
    final defs = {structId: schema()};
    addTearDown(() => raw.UA_Variant_delete(variant));

    // Warm up once so lazily-initialised state is not counted against the loop.
    variantToValue(variant.ref, defs: defs, dataTypeId: structId);

    const n = 1000;
    final before = outstanding();
    for (var i = 0; i < n; i++) {
      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      expect(decoded['a'].asInt, 7);
      expect(decoded['c'].asString, 'item 7');
    }
    expect(outstanding() - before, 0, reason: 'each decode of a struct variant left native memory behind');
  });

  test('decoding an array of structs allocates nothing per element either', () {
    final array = DynamicValue(typeId: structId);
    for (var i = 0; i < 3; i++) {
      array[i] = instance(i);
    }
    final variant = valueToVariant(array);
    final defs = {structId: schema()};
    addTearDown(() => raw.UA_Variant_delete(variant));

    variantToValue(variant.ref, defs: defs, dataTypeId: structId);

    const n = 500;
    final before = outstanding();
    for (var i = 0; i < n; i++) {
      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      expect(decoded.asArray.length, 3);
      expect(decoded[2]['a'].asInt, 2);
    }
    expect(outstanding() - before, 0, reason: 'each element of an array of structs left native memory behind');
  });

  test('encoding a struct allocates only what the variant takes ownership of', () {
    // A struct write allocates natively exactly what the variant takes
    // ownership of: the encoded body, the characters of its string typeId,
    // and the variant's own data buffer -- three, all released by
    // UA_Variant_delete. The header must not be a fourth, leaked one.
    final v = instance(1);

    valueToVariant(v); // warm-up, deliberately not freed: counts only bracket the loop
    const n = 200;
    final variants = <ffi.Pointer<raw.UA_Variant>>[];
    final before = uaAllocCount;
    for (var i = 0; i < n; i++) {
      variants.add(valueToVariant(v));
    }
    expect(
      uaAllocCount - before,
      3 * n,
      reason: 'a struct write must allocate body, typeId string and data buffer, nothing else',
    );
    for (final p in variants) {
      raw.UA_Variant_delete(p);
    }
  });
}
