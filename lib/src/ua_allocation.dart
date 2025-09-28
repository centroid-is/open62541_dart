// Copy of ffi allocation.dart, using ucrtbase.dll on Windows instead of ole32.dll to match open62541.

// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';

bool debug = false;

typedef UaPosixMallocNative = Pointer Function(IntPtr);

@Native<UaPosixMallocNative>(symbol: 'malloc')
external Pointer uaPosixMalloc(int size);

typedef UaPosixCallocNative = Pointer Function(IntPtr num, IntPtr size);

@Native<UaPosixCallocNative>(symbol: 'calloc')
external Pointer uaPosixCalloc(int num, int size);

typedef UaPosixFreeNative = Void Function(Pointer);

@Native<Void Function(Pointer)>(symbol: 'free')
external void uaPosixFree(Pointer ptr);

final Pointer<NativeFunction<UaPosixFreeNative>> uaPosixFreePointer = Native.addressOf(uaPosixFree);

final DynamicLibrary ucrtbaselib = DynamicLibrary.open(debug ? 'ucrtbased.dll' : 'ucrtbase.dll');

typedef WinMalloc = Pointer Function(int);
final WinMalloc winMalloc = ucrtbaselib.lookupFunction<UaPosixMallocNative, WinMalloc>(
  'malloc',
);

typedef WinCalloc = Pointer Function(int, int);
final WinCalloc winCalloc = ucrtbaselib.lookupFunction<UaPosixCallocNative, WinCalloc>(
  'calloc',
);

typedef WinFree = void Function(Pointer);
final Pointer<NativeFunction<UaPosixFreeNative>> winFreePointer = ucrtbaselib.lookup('free');
final WinFree winFree = winFreePointer.asFunction();

/// Manages memory on the native heap.
///
/// Does not initialize newly allocated memory to zero. Use [CallocAllocator]
/// for zero-initialized memory on allocation.
///
/// For POSIX-based & Windows systems, this uses `malloc` and `free`.
final class UaMallocAllocator implements Allocator {
  const UaMallocAllocator._();

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
      result = uaPosixMalloc(byteCount).cast();
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
      uaPosixFree(pointer);
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
  Pointer<NativeFinalizerFunction> get nativeFree => Platform.isWindows ? winFreePointer : uaPosixFreePointer;
}

/// Manages memory on the native heap.
///
/// Does not initialize newly allocated memory to zero. Use [calloc] for
/// zero-initialized memory allocation.
///
/// For POSIX-based & Windows systems, this uses `malloc` and `free`.
// ignore: constant_identifier_names
const UaMallocAllocator ua_malloc = UaMallocAllocator._();

/// Manages memory on the native heap.
///
/// Initializes newly allocated memory to zero.
///
/// For POSIX-based & Windows systems, this uses `calloc` and `free`.
final class UaCallocAllocator implements Allocator {
  const UaCallocAllocator._();

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
      result = uaPosixCalloc(byteCount, 1).cast();
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
      uaPosixFree(pointer);
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
  Pointer<NativeFinalizerFunction> get nativeFree => Platform.isWindows ? winFreePointer : uaPosixFreePointer;
}

/// Manages memory on the native heap.
///
/// Initializes newly allocated memory to zero. Use [malloc] for uninitialized
/// memory allocation.
///
/// For POSIX-based & Windows systems, this uses `calloc` and `free`.
// ignore: constant_identifier_names
const UaCallocAllocator ua_calloc = UaCallocAllocator._();
