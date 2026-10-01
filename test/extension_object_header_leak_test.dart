import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/src/common.dart';
import 'package:open62541/src/dynamic_value.dart';
import 'package:open62541/src/node_id.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'schema_util.dart';

/// Regression tests for native memory left behind by the struct paths of
/// OpcUaDynamicValueSerializer: decoding a struct-valued variant, writing one,
/// and a write that fails part-way.
///
/// They measure the C heap itself (glibc `mallinfo2`): each test repeats one
/// operation that must leave the heap as it found it, and fails if the bytes in
/// use grew. One leaked allocation per operation is at least 32 bytes per
/// operation (the smallest glibc chunk); the limit is 8.
///
/// glibc only. `dart test` runs every suite in one process, so another suite can
/// allocate or free while a round is being measured. A leak grows the heap by
/// the same amount in every round, so the median over the rounds discards that.

final class _Mallinfo2 extends ffi.Struct {
  @ffi.Size()
  external int arena;
  @ffi.Size()
  external int ordblks;
  @ffi.Size()
  external int smblks;
  @ffi.Size()
  external int hblks;
  @ffi.Size()
  external int hblkhd;
  @ffi.Size()
  external int usmblks;
  @ffi.Size()
  external int fsmblks;
  @ffi.Size()
  external int uordblks;
  @ffi.Size()
  external int fordblks;
  @ffi.Size()
  external int keepcost;
}

final _Mallinfo2 Function() _mallinfo2 = ffi.DynamicLibrary.process()
    .lookupFunction<_Mallinfo2 Function(), _Mallinfo2 Function()>('mallinfo2');

/// Bytes handed out by malloc and not yet freed, across all arenas.
int _heapInUse() {
  final info = _mallinfo2();
  return info.uordblks + info.hblkhd;
}

const _warmUp = 50000;
const _rounds = 15;
const _iterations = 4000;
const _maxGrowth = 8 * _iterations;

/// Median growth of the C heap over [_rounds] rounds of [_iterations] calls.
int _heapGrowth(void Function() operation) {
  // Let the JIT and anything lazily initialised settle before measuring.
  for (var i = 0; i < _warmUp; i++) {
    operation();
  }
  final growth = <int>[];
  for (var round = 0; round < _rounds; round++) {
    final before = _heapInUse();
    for (var i = 0; i < _iterations; i++) {
      operation();
    }
    growth.add(_heapInUse() - before);
  }
  growth.sort();
  return growth[_rounds ~/ 2];
}

/// Why the heap cannot be measured here, or null if it can.
String? _whyUnmeasurable() {
  if (!Platform.isLinux) return 'needs glibc mallinfo2, not available on ${Platform.operatingSystem}';
  if (!ffi.DynamicLibrary.process().providesSymbol('mallinfo2')) return 'this libc has no mallinfo2 (glibc >= 2.33)';
  // mallinfo2 must see what ua_calloc allocates. It does not when malloc is
  // replaced, e.g. under AddressSanitizer.
  const blocks = 4096, blockSize = 64;
  for (var attempt = 0; attempt < 3; attempt++) {
    final before = _heapInUse();
    final held = [for (var i = 0; i < blocks; i++) ua_calloc<ffi.Uint8>(blockSize)];
    final growth = _heapInUse() - before;
    held.forEach(ua_calloc.free);
    if (growth >= blocks * blockSize) return null;
  }
  return 'mallinfo2 does not track this process\'s allocator (malloc replaced?)';
}

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

  DynamicValue arrayOf(List<DynamicValue> elements) {
    final array = DynamicValue(typeId: structId);
    for (var i = 0; i < elements.length; i++) {
      array[i] = elements[i];
    }
    return array;
  }

  /// A struct whose body cannot be serialised: field `b` has no value.
  DynamicValue unserialisable() {
    final v = instance(9);
    v['b'] = DynamicValue(typeId: NodeId.double);
    return v;
  }

  final defs = {structId: schema()};
  late final String? unmeasurable = _whyUnmeasurable();

  /// Runs [operation] repeatedly and fails if the C heap grew.
  void expectNoHeapGrowth(void Function() operation) {
    if (unmeasurable != null) {
      markTestSkipped(unmeasurable);
      return;
    }
    final growth = _heapGrowth(operation);
    expect(
      growth,
      lessThan(_maxGrowth),
      reason: 'C heap grew by $growth bytes per $_iterations operations (${growth / _iterations} per operation)',
    );
  }

  group('decoding leaves nothing on the C heap:', () {
    test('a struct', () {
      final variant = valueToVariant(instance(7));
      addTearDown(() => raw.UA_Variant_delete(variant));

      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      expect(decoded['a'].asInt, 7);
      expect(decoded['c'].asString, 'item 7');

      expectNoHeapGrowth(() => variantToValue(variant.ref, defs: defs, dataTypeId: structId));
    });

    test('an array of structs', () {
      final variant = valueToVariant(arrayOf([instance(0), instance(1), instance(2)]));
      addTearDown(() => raw.UA_Variant_delete(variant));

      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      expect(decoded.asArray.length, 3);
      expect(decoded[2]['a'].asInt, 2);

      expectNoHeapGrowth(() => variantToValue(variant.ref, defs: defs, dataTypeId: structId));
    });
  });

  group('writing leaves nothing on the C heap once the variant is deleted:', () {
    test('a struct', () {
      final value = instance(1);

      final variant = valueToVariant(value);
      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      raw.UA_Variant_delete(variant);
      expect(decoded['b'].asDouble, 0.5);
      expect(decoded['c'].asString, 'item 1');

      expectNoHeapGrowth(() => raw.UA_Variant_delete(valueToVariant(value)));
    });

    test('an array of structs', () {
      final value = arrayOf([instance(0), instance(1), instance(2)]);

      final variant = valueToVariant(value);
      final decoded = variantToValue(variant.ref, defs: defs, dataTypeId: structId);
      raw.UA_Variant_delete(variant);
      expect(decoded.asArray.length, 3);
      expect(decoded[1]['c'].asString, 'item 1');

      expectNoHeapGrowth(() => raw.UA_Variant_delete(valueToVariant(value)));
    });
  });

  group('a write that fails leaves nothing on the C heap:', () {
    void Function() failingWrite(DynamicValue value, Matcher error) {
      expect(() => valueToVariant(value), error);
      return () {
        try {
          valueToVariant(value);
        } catch (_) {
          // Expected, checked above.
        }
      };
    }

    test('a struct whose body cannot be serialised', () {
      expectNoHeapGrowth(failingWrite(unserialisable(), throwsStateError));
    });

    test('an array of structs whose last element cannot be serialised', () {
      final value = arrayOf([instance(0), instance(1), unserialisable()]);
      expectNoHeapGrowth(failingWrite(value, throwsStateError));
    });
  });
}
