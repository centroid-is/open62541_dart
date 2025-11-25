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
    final extracted_files = await download(input.outputDirectoryShared, version);

    final name = 'open62541';
    final logger = Logger('')
      ..level = Level.ALL
      // temp fwd to stderr until process logs pass to stdout
      ..onRecord.listen((record) => stderr.writeln(record));
    final builder = CMakeBuilder.create(
      name: name,
      sourceDir: extracted_files,
      buildMode: BuildMode.release,
      defines: {
        'CMAKE_BUILD_TYPE': 'Release',
        'CMAKE_INSTALL_PREFIX': '${input.outputDirectory.toFilePath()}/install',
        'BUILD_SHARED_LIBS': 'ON',
        'UA_ENABLE_INLINABLE_EXPORT': 'ON',
        'UA_ENABLE_ENCRYPTION': 'MBEDTLS',
        'UA_BUILD_EXAMPLES': 'OFF',
        'UA_BUILD_UNIT_TESTS': 'OFF',
        'UA_MULTITHREADING': '0',
        'UA_LOGLEVEL': '100',
        //'UA_ENABLE_AMALGAMATION': 'ON'
      },
      targets: ['install'],
      buildLocal: true,
      logger: logger,
    );

    await builder.run(input: input, output: output, logger: logger);

    // manually add assets
    final libPath = switch (input.config.code.targetOS) {
      OS.linux => "install/lib/libopen62541.so",
      OS.macOS => "install/lib/libopen62541.dylib",
      OS.windows => "install/lib/libopen62541.dll",
      OS.android => "install/lib/libopen62541.so",
      OS.iOS => "install/lib/libopen62541.dylib",
      _ => throw UnsupportedError("Unsupported OS"),
    };
    output.assets.code.add(
      CodeAsset(
        package: 'open62541/src/third_party',
        name: '$name.g.dart',
        linkMode: DynamicLoadingBundled(),
        file: input.outputDirectory.resolve(libPath),
      ),
    );
  });
}
