import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';
import 'package:http/http.dart' as http;

Future<Uri> download(Uri outputDirectory, String version) async {
  final extractDir = Directory.fromUri(outputDirectory.resolve('download/'));

  final url = Uri.parse('https://github.com/open62541/open62541/archive/refs/tags/$version.zip');
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw Exception('Error downloading open62541 version $version: ${response.statusCode}');
  }

  final archive = ZipDecoder().decodeBytes(response.bodyBytes);

  if (!await extractDir.exists()) {
    await extractDir.create(recursive: true);
  }

  for (var file in archive) {
    if (file.isFile) {
      final outputStream = OutputFileStream('${extractDir.path.toString()}/${file.name}');
      file.writeContent(outputStream);
      outputStream.closeSync();
    } else if (file.isDirectory) {
      final dir = Directory(extractDir.toString() + '/' + file.name);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }
  final version_no_v_prefix = version.substring(1);
  final folder = extractDir.uri.resolve('open62541-$version_no_v_prefix/');
  if (!await Directory.fromUri(folder).exists()) {
    throw Exception('Error extracting open62541 version $version: extracted directory not found');
  }
  return folder;
}

Future<void> main(List<String> args) async {
  final version = "v1.5.0-rc1";
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final extracted_files = await download(input.outputDirectoryShared, version);

    print(extracted_files);

    final _logger = Logger('')
      ..level = Level.ALL
      // temp fwd to stderr until process logs pass to stdout
      ..onRecord.listen((record) => stderr.writeln(record));
    final builder = CMakeBuilder.create(
      name: 'open62541',
      sourceDir: extracted_files,
      generator: Generator.ninja,
      buildMode: BuildMode.release,
      defines: {
        'CMAKE_BUILD_TYPE': 'Release',
        'CMAKE_INSTALL_PREFIX': '${input.outputDirectory.toFilePath()}/install',
        'BUILD_SHARED_LIBS': 'ON',
        'UA_ENABLE_INLINABLE_EXPORT': 'ON',
        'UA_ENABLE_ENCRYPTION': 'MBEDTLS',
        'UA_BUILD_EXAMPLES': 'OFF',
        'UA_BUILD_UNIT_TESTS': 'OFF',
        'UA_ENABLE_AMALGAMATION': 'ON',
        'UA_MULTITHREADING': '0',
        'UA_LOGLEVEL': '100',
      },
      targets: ['install'],
      buildLocal: true,
      logger: _logger,
    );

    await builder.run(input: input, output: output, logger: _logger);
  });
}

// patch $BUILD_DIR/open62541.h -i $PROJECT_ROOT/open62541_tooling/remove_bitfields.patch
