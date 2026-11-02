import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/src/third_party/open62541.g.dart' as raw;

// The build hook compiles open62541 (and the mbedTLS it links in) with
// `-fstack-protector-strong -D_FORTIFY_SOURCE=2` and links the shared library
// with `-Wl,-z,relro,-z,now` (hook/build.dart, `_hardeningFor`). Nothing else
// in the suite would notice a toolchain that dropped the flags: the library
// runs the same without them. This reads the ELF the VM loaded and checks the
// marks the flags leave behind:
//
//   - BIND_NOW in the dynamic section (with GNU_RELRO: full RELRO, the GOT is
//     resolved at load and then made read-only, so a write primitive cannot
//     redirect a call through it);
//   - a `__*_chk` import (FORTIFY: a bounded libc call compiled in place of an
//     unbounded one where the compiler knew the destination size);
//   - `__stack_chk_fail` (the stack protector's canary check).
//
// The library is found through /proc/self/maps rather than through the hook's
// output directory, so the one inspected is the one the tests run against.
void main() {
  test('libopen62541.so is linked with full RELRO and compiled with FORTIFY_SOURCE and a stack protector', () async {
    final missing = await _missingTool();
    if (missing != null) {
      markTestSkipped('$missing is not on PATH (binutils)');
      return;
    }

    final library = _loadedLibraryPath();
    expect(library, isNotNull, reason: 'libopen62541.so is not mapped into this process');

    final dynamic_ = await _run('readelf', ['-d', library!]);
    expect(dynamic_, contains('BIND_NOW'), reason: 'no BIND_NOW in the dynamic section of $library');

    final segments = await _run('readelf', ['-lW', library]);
    expect(segments, contains('GNU_RELRO'), reason: 'no GNU_RELRO segment in $library');

    final symbols = await _run('nm', ['-D', library]);
    // `__memcpy_chk`, `__snprintf_chk`, ... but not `__stack_chk_fail`,
    // which the stack protector references and the third check covers.
    final fortified = RegExp(
      r' U (__\w+_chk)(?:@|\s|$)',
      multiLine: true,
    ).allMatches(symbols).map((m) => m.group(1)!).toSet();
    expect(fortified, isNotEmpty, reason: 'no FORTIFY __*_chk import in $library');
    expect(symbols, contains('__stack_chk_fail'), reason: 'no stack protector in $library');
  }, skip: _onlyOnLinux);
}

/// ELF and its `readelf`/`nm` are Linux's. A Mach-O (macOS, iOS) or a PE
/// (Windows) would need `otool -l` / `dumpbin /headers` and different marks.
final _onlyOnLinux = Platform.isLinux ? null : 'reads the ELF marks of the hardening flags; ELF is Linux';

/// The first of `readelf` and `nm` that is not on PATH, or null.
Future<String?> _missingTool() async {
  for (final tool in ['readelf', 'nm']) {
    try {
      await Process.run(tool, ['--version']);
    } on ProcessException {
      return tool;
    }
  }
  return null;
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  expect(result.exitCode, 0, reason: '$executable ${arguments.join(' ')} failed: ${result.stderr}');
  return result.stdout as String;
}

/// The path of the libopen62541.so mapped into this process.
///
/// The bindings load the library lazily on the first native call, so one is
/// made first; `UA_StatusCode_name` touches nothing but a string table.
String? _loadedLibraryPath() {
  raw.UA_StatusCode_name(raw.UA_STATUSCODE_GOOD);
  for (final line in File('/proc/self/maps').readAsLinesSync()) {
    final path = line.substring(line.indexOf('/').clamp(0, line.length));
    if (line.contains('/') && path.endsWith('/libopen62541.so')) {
      return path;
    }
  }
  return null;
}
