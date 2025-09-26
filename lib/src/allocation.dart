// Copy of ffi allocation.dart, using ucrtbase.dll on Windows instead of ole32.dll to match open62541.

// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';

bool debug = false;

typedef PosixMallocNative = Pointer Function(IntPtr);

@Native<PosixMallocNative>(symbol: 'malloc')
external Pointer posixMalloc(int size);

typedef PosixCallocNative = Pointer Function(IntPtr num, IntPtr size);

@Native<PosixCallocNative>(symbol: 'calloc')
external Pointer posixCalloc(int num, int size);

typedef PosixFreeNative = Void Function(Pointer);

@Native<Void Function(Pointer)>(symbol: 'free')
external void posixFree(Pointer ptr);

final Pointer<NativeFunction<PosixFreeNative>> posixFreePointer = Native.addressOf(posixFree);

final DynamicLibrary ucrtbaselib = DynamicLibrary.open(debug ? 'ucrtbased.dll' : 'ucrtbase.dll');

typedef WinMalloc = Pointer Function(int);
final WinMalloc winMalloc = ucrtbaselib.lookupFunction<PosixMallocNative, WinMalloc>(
  'malloc',
);

typedef WinCalloc = Pointer Function(int, int);
final WinCalloc winCalloc = ucrtbaselib.lookupFunction<PosixCallocNative, WinCalloc>(
  'calloc',
);

typedef WinFree = void Function(Pointer);
final Pointer<NativeFunction<PosixFreeNative>> winFreePointer = ucrtbaselib.lookup('free');
final WinFree winFree = winFreePointer.asFunction();

/// Manages memory on the native heap.
///
/// Does not initialize newly allocated memory to zero. Use [CallocAllocator]
/// for zero-initialized memory on allocation.
///
/// For POSIX-based & Windows systems, this uses `malloc` and `free`.
final class MallocAllocator implements Allocator {
  const MallocAllocator._();

  /// Allocates [byteCount] bytes of of unitialized memory on the native heap.
  ///
  /// For POSIX-based & Windows systems, this uses `malloc`.
  ///
  /// Throws an [ArgumentError] if the number of bytes or alignment cannot be
  /// satisfied.
  // TODO: Stop ignoring alignment if it's large, for example for SSE data.
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    Pointer<T> result;
    if (Platform.isWindows) {
      result = winMalloc(byteCount).cast();
    } else {
      result = posixMalloc(byteCount).cast();
    }
    if (result.address == 0) {
      throw ArgumentError('Could not allocate $byteCount bytes.');
    }
    return result;
  }

  /// Releases memory allocated on the native heap.
  ///
  /// For POSIX-based & Windows systems, this uses `free`.
  /// It may only be used against pointers allocated in a
  /// manner equivalent to [allocate].
  @override
  void free(Pointer pointer) {
    if (Platform.isWindows) {
      winFree(pointer);
    } else {
      posixFree(pointer);
    }
  }

  /// Returns a pointer to a native free function.
  ///
  /// This function can be used to release memory allocated by [allocate]
  /// from the native side. It can also be used as a finalization callback
  /// passed to `NativeFinalizer` constructor or `Pointer.atTypedList`
  /// method.
  ///
  /// For example to automatically free native memory when the Dart object
  /// wrapping it is reclaimed by GC:
  ///
  /// ```dart
  /// class Wrapper implements Finalizable {
  ///   static final finalizer = NativeFinalizer(malloc.nativeFree);
  ///
  ///   final Pointer<Uint8> data;
  ///
  ///   Wrapper() : data = malloc.allocate<Uint8>(length) {
  ///     finalizer.attach(this, data);
  ///   }
  /// }
  /// ```
  ///
  /// or to free native memory that is owned by a typed list:
  ///
  /// ```dart
  /// malloc.allocate<Uint8>(n).asTypedList(n, finalizer: malloc.nativeFree)
  /// ```
  ///
  Pointer<NativeFinalizerFunction> get nativeFree => Platform.isWindows ? winFreePointer : posixFreePointer;
}

/// Manages memory on the native heap.
///
/// Does not initialize newly allocated memory to zero. Use [calloc] for
/// zero-initialized memory allocation.
///
/// For POSIX-based & Windows systems, this uses `malloc` and `free`.
const MallocAllocator malloc = MallocAllocator._();

/// Manages memory on the native heap.
///
/// Initializes newly allocated memory to zero.
///
/// For POSIX-based & Windows systems, this uses `calloc` and `free`.
final class CallocAllocator implements Allocator {
  const CallocAllocator._();

  /// Allocates [byteCount] bytes of zero-initialized of memory on the native
  /// heap.
  ///
  /// For POSIX-based & Windows systems, this uses `malloc`.
  ///
  /// Throws an [ArgumentError] if the number of bytes or alignment cannot be
  /// satisfied.
  // TODO: Stop ignoring alignment if it's large, for example for SSE data.
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    Pointer<T> result;
    if (Platform.isWindows) {
      result = winCalloc(byteCount, 1).cast();
    } else {
      result = posixCalloc(byteCount, 1).cast();
    }
    if (result.address == 0) {
      throw ArgumentError('Could not allocate $byteCount bytes.');
    }
    return result;
  }

  /// Releases memory allocated on the native heap.
  ///
  /// For POSIX-based systems, this uses `free`. It may only be used against pointers allocated in a
  /// manner equivalent to [allocate].
  @override
  void free(Pointer pointer) {
    if (Platform.isWindows) {
      winFree(pointer);
    } else {
      posixFree(pointer);
    }
  }

  /// Returns a pointer to a native free function.
  ///
  /// This function can be used to release memory allocated by [allocate]
  /// from the native side. It can also be used as a finalization callback
  /// passed to `NativeFinalizer` constructor or `Pointer.atTypedList`
  /// method.
  ///
  /// For example to automatically free native memory when the Dart object
  /// wrapping it is reclaimed by GC:
  ///
  /// ```dart
  /// class Wrapper implements Finalizable {
  ///   static final finalizer = NativeFinalizer(calloc.nativeFree);
  ///
  ///   final Pointer<Uint8> data;
  ///
  ///   Wrapper() : data = calloc.allocate<Uint8>(length) {
  ///     finalizer.attach(this, data);
  ///   }
  /// }
  /// ```
  ///
  /// or to free native memory that is owned by a typed list:
  ///
  /// ```dart
  /// calloc.allocate<Uint8>(n).asTypedList(n, finalizer: calloc.nativeFree)
  /// ```
  ///
  Pointer<NativeFinalizerFunction> get nativeFree => Platform.isWindows ? winFreePointer : posixFreePointer;
}

/// Manages memory on the native heap.
///
/// Initializes newly allocated memory to zero. Use [malloc] for uninitialized
/// memory allocation.
///
/// For POSIX-based & Windows systems, this uses `calloc` and `free`.
const CallocAllocator calloc = CallocAllocator._();
