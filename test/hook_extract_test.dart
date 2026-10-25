// The build hook's archive extraction (`extractArchiveInto` in
// hook/build.dart) writes only regular files, only under the directory it was
// given. The archives it extracts are checked against a pinned SHA-256 first;
// this is the layer behind that one.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/build.dart';

void main() {
  group('hardeningCmake', () {
    test('Linux compiles with canaries + FORTIFY and links RELRO/BIND_NOW', () {
      final script = hardeningCmake(OS.linux, floatLittleEndian: true);
      expect(script, contains('add_compile_definitions(UA_FLOAT_LITTLE_ENDIAN=1)'));
      expect(
        script,
        contains(r'add_compile_options("$<$<COMPILE_LANGUAGE:C>:-fstack-protector-strong;-D_FORTIFY_SOURCE=2>")'),
      );
      expect(script, contains('add_link_options(-Wl,-z,relro -Wl,-z,now)'));
    });

    test('macOS has no link options, and no float define unless asked', () {
      final script = hardeningCmake(OS.macOS);
      expect(script, contains('-fstack-protector-strong'));
      expect(script, isNot(contains('add_link_options')));
      expect(script, isNot(contains('UA_FLOAT_LITTLE_ENDIAN')));
    });

    test('Windows uses the MSVC flags', () {
      final script = hardeningCmake(OS.windows);
      expect(script, contains('/GS;/guard:cf'));
      expect(script, contains('add_link_options(/DYNAMICBASE /NXCOMPAT /guard:cf)'));
      expect(script, isNot(contains('-fstack')));
    });

    test('the sanitizer adds to both', () {
      final script = hardeningCmake(OS.linux, sanitizer: true);
      expect(script, contains('-fsanitize=address,undefined;-fno-omit-frame-pointer'));
      expect(script, contains('-Wl,-z,now -fsanitize=address,undefined'));
    });
  });

  // native_toolchain_cmake reconfigures on every run, and on Apple targets
  // its ios.toolchain.cmake prepends its flags to the cached ones each time,
  // so flags.make changed on every run and everything recompiled. The hook
  // configures only when what it configures with changed.
  group('configureStamp', () {
    final defines = {'CMAKE_BUILD_TYPE': 'Release', 'CMAKE_PROJECT_INCLUDE': '/b/hardening-open62541.cmake'};
    const config = {'target_os': 'macos', 'target_architecture': 'arm64'};
    const script = 'add_compile_options(-fstack-protector-strong)\n';

    test('is the same for the same inputs in any order', () {
      final reordered = Map.fromEntries(defines.entries.toList().reversed);
      expect(configureStamp(reordered, config, script), configureStamp(defines, config, script));
    });

    test('changes with a define, the target config or the hardening script', () {
      final stamp = configureStamp(defines, config, script);
      expect(configureStamp({...defines, 'CMAKE_PROJECT_INCLUDE': '/b/hardening-open62541-asan.cmake'}, config, script),
          isNot(stamp));
      expect(configureStamp(defines, {...config, 'target_architecture': 'x64'}, script), isNot(stamp));
      expect(configureStamp(defines, config, '$script-fsanitize=address\n'), isNot(stamp));
    });
  });

  late Directory sandbox;
  late Directory extractDir;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('open62541_extract_');
    extractDir = Directory('${sandbox.path}/extract');
  });

  tearDown(() => sandbox.delete(recursive: true));

  Archive archiveOf(List<ArchiveFile> files) {
    final archive = Archive();
    for (final file in files) {
      archive.add(file);
    }
    return archive;
  }

  test('regular files land under the extract directory, with their directories', () async {
    await extractArchiveInto(
      archiveOf([
        ArchiveFile.string('pkg-1.0/a.txt', 'a'),
        ArchiveFile.string('pkg-1.0/sub/b.txt', 'b'),
        ArchiveFile.directory('pkg-1.0/empty/'),
      ]),
      extractDir,
    );

    expect(await File('${extractDir.path}/pkg-1.0/a.txt').readAsString(), 'a');
    expect(await File('${extractDir.path}/pkg-1.0/sub/b.txt').readAsString(), 'b');
  });

  test('an entry that climbs out with .. is refused by name, and nothing is written outside', () async {
    final archive = archiveOf([
      ArchiveFile.string('pkg-1.0/a.txt', 'a'),
      ArchiveFile.string('pkg-1.0/../../escaped.txt', 'escaped'),
    ]);

    await expectLater(
      extractArchiveInto(archive, extractDir),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('pkg-1.0/../../escaped.txt'))),
    );
    expect(await File('${sandbox.path}/escaped.txt').exists(), isFalse);
  });

  test('an absolute entry name is refused', () async {
    final outside = '${sandbox.path}/absolute.txt';
    final archive = archiveOf([ArchiveFile.string(outside, 'absolute')]);

    await expectLater(
      extractArchiveInto(archive, extractDir),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains(outside))),
    );
    expect(await File(outside).exists(), isFalse);
  });

  test('a symbolic link entry is skipped and the files beside it are extracted', () async {
    await extractArchiveInto(
      archiveOf([ArchiveFile.symlink('pkg-1.0/link', '/etc'), ArchiveFile.string('pkg-1.0/a.txt', 'a')]),
      extractDir,
    );

    expect(await File('${extractDir.path}/pkg-1.0/a.txt').readAsString(), 'a');
    expect(await FileSystemEntity.type('${extractDir.path}/pkg-1.0/link'), FileSystemEntityType.notFound);
  });

  test('a climbing entry survives a zip round trip verbatim, so the decoder is not what stops it', () async {
    final bytes = ZipEncoder().encode(archiveOf([ArchiveFile.string('pkg-1.0/../../escaped.txt', 'escaped')]));
    final decoded = ZipDecoder().decodeBytes(bytes);
    expect(decoded.first.name, 'pkg-1.0/../../escaped.txt', reason: 'anti-vacuity: the name reaches the extractor');

    await expectLater(extractArchiveInto(decoded, extractDir), throwsA(isA<Exception>()));
    expect(await File('${sandbox.path}/escaped.txt').exists(), isFalse);
  });

  // A skipped configure keeps the build directory's tools, so a CMake, Xcode
  // or SDK that has since moved or been removed must configure again.
  group('missingCachedTools', () {
    test('names the cached tool paths that no longer exist', () async {
      final cmake = await File('${sandbox.path}/cmake').create();
      final sdk = await Directory('${sandbox.path}/MacOSX15.2.sdk').create();
      final cache = [
        '# This is the CMakeCache file.',
        'CMAKE_COMMAND:INTERNAL=${cmake.path}',
        'CMAKE_OSX_SYSROOT:INTERNAL=${sdk.path}',
        'CMAKE_AR:FILEPATH=${sandbox.path}/gone/ar',
        'CMAKE_MAKE_PROGRAM:FILEPATH=make',
        'CMAKE_C_FLAGS:INTERNAL=/not/a/tool',
      ].join('\n');

      expect(await missingCachedTools(cache), ['${sandbox.path}/gone/ar']);
    });

    test('is empty when every cached tool is still there', () async {
      final cmake = await File('${sandbox.path}/cmake').create();
      expect(await missingCachedTools('CMAKE_COMMAND:INTERNAL=${cmake.path}\n'), isEmpty);
    });
  });

  // The hardening script is CMake's CMAKE_PROJECT_INCLUDE: a new mtime on it
  // reconfigures and recompiles, the relinked library is a hook dependency
  // modified during the run, and the hooks runner then reruns the hook on the
  // next start. Unchanged content must leave the file alone.
  group('writeIfChanged', () {
    final past = DateTime(2020, 1, 1);

    test('leaves a file with the same content untouched', () async {
      final file = File('${sandbox.path}/hardening-open62541.cmake');
      await file.writeAsString('add_compile_options(-fstack-protector-strong)\n');
      await file.setLastModified(past);

      expect(await writeIfChanged(file, 'add_compile_options(-fstack-protector-strong)\n'), isFalse);
      expect(await file.lastModified(), past);
    });

    test('rewrites a file whose content differs', () async {
      final file = File('${sandbox.path}/flags');
      await file.writeAsString('old');
      await file.setLastModified(past);

      expect(await writeIfChanged(file, 'new'), isTrue);
      expect(await file.readAsString(), 'new');
      expect(await file.lastModified(), isNot(past));
    });

    test('creates a missing file and its directory', () async {
      final file = File('${sandbox.path}/nested/dir/version');

      expect(await writeIfChanged(file, 'v1.5.9'), isTrue);
      expect(await file.readAsString(), 'v1.5.9');
    });
  });
}
