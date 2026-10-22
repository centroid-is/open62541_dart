// The build hook's archive extraction (`extractArchiveInto` in
// hook/build.dart) writes only regular files, only under the directory it was
// given. The archives it extracts are checked against a pinned SHA-256 first;
// this is the layer behind that one.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '../hook/build.dart';

void main() {
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
}
