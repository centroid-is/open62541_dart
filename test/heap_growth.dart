import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/src/ua_allocation.dart';

/// Leak checks for tests, measured on the C heap itself (glibc `mallinfo2`).
///
/// [expectNoHeapGrowth] repeats one operation that must leave the heap as it
/// found it and fails if the bytes in use grew. Nothing in `lib/` is
/// instrumented: what is measured is what malloc handed out and did not get
/// back, whoever asked for it (Dart through `ua_calloc`/`ua_malloc`, or
/// open62541).
///
/// glibc only. `dart test` runs every suite in one process, so the heap also
/// moves with what other suites do meanwhile, by megabytes when one is loaded
/// or torn down. A leak grows the heap by the same amount in every round, so
/// the median over the rounds discards the odd disturbed round, and a
/// measurement that still comes out too high is repeated a little later: a
/// suite being loaded passes, a leak does not.

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

/// [_heapInUse] without what the VM's own threads hold for a moment. The JIT
/// compiler and the garbage collector work out of malloc'd memory, megabytes
/// of it, that they hand back within milliseconds. The lowest of a few
/// readings, a millisecond apart, is the heap without them.
int _settledHeapInUse() {
  var lowest = _heapInUse();
  for (var i = 0; i < 10; i++) {
    sleep(const Duration(milliseconds: 1));
    final inUse = _heapInUse();
    if (inUse < lowest) lowest = inUse;
  }
  return lowest;
}

/// Why the C heap cannot be measured here, or null if it can.
final String? heapUnmeasurable = _whyUnmeasurable();

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

/// Runs [operation] repeatedly and fails the test if the C heap grew.
///
/// [operation] may be synchronous or return a future, which is awaited. It is
/// first run [warmUp] times, to let the JIT and anything lazily initialised
/// settle, then measured: the median heap growth over [rounds] rounds of
/// [iterations] calls must stay below [maxGrowth] bytes per call. A measurement
/// above that is repeated up to [attempts] times before the test fails.
///
/// One leaked allocation costs at least 32 bytes per call (the smallest glibc
/// chunk), so the default [maxGrowth] of 8 catches any leak that happens on
/// every call. The defaults suit an operation taking microseconds. For a slow
/// one (a connect, a whole server) lower [warmUp] and [iterations], make what
/// could leak large where the test controls its size (a long string), and raise
/// [maxGrowth] to stay well below that size but above the noise of a short
/// round.
///
/// Where the heap cannot be measured (see [heapUnmeasurable]) the test is
/// marked skipped, after the warm-up: that still puts the operation under
/// whatever sanitizer is watching.
Future<void> expectNoHeapGrowth(
  FutureOr<void> Function() operation, {
  int warmUp = 50000,
  int iterations = 4000,
  int rounds = 15,
  int maxGrowth = 8,
  int attempts = 10,
}) async {
  Future<void> repeat(int count) async {
    for (var i = 0; i < count; i++) {
      final pending = operation();
      if (pending is Future) await pending;
    }
  }

  /// Median growth of the C heap over [rounds] rounds of [iterations] calls.
  Future<int> medianHeapGrowth() async {
    final growth = <int>[];
    var before = _settledHeapInUse();
    for (var round = 0; round < rounds; round++) {
      await repeat(iterations);
      final after = _settledHeapInUse();
      growth.add(after - before);
      before = after;
    }
    growth.sort();
    return growth[rounds ~/ 2];
  }

  await repeat(warmUp);
  if (heapUnmeasurable != null) {
    markTestSkipped(heapUnmeasurable!);
    return;
  }
  final limit = maxGrowth * iterations;
  var growth = await medianHeapGrowth();
  for (var attempt = 1; growth >= limit && attempt < attempts; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    growth = await medianHeapGrowth();
  }
  expect(
    growth,
    lessThan(limit),
    reason: 'C heap grew by $growth bytes per $iterations operations (${growth / iterations} per operation)',
  );
}
