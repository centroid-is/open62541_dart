import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';
import 'package:http/http.dart' as http;

Future<Uri> _downloadMbedTLS(Uri baseDir) async {
  // Use short directory names to avoid Windows MAX_PATH (260 char) limit.
  // CMake TryCompile creates deeply nested paths inside the build directory.
  final extractDir = Directory.fromUri(baseDir.resolve('tls/'));
  final url = 'https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2';

  // Return early if already downloaded and renamed
  final srcDir = Directory.fromUri(extractDir.uri.resolve('src/'));
  if (await srcDir.exists()) {
    return srcDir.uri;
  }

  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception('Error downloading mbedTLS: ${response.statusCode}');
  }

  final decompressed = BZip2Decoder().decodeBytes(response.bodyBytes);
  final archive = TarDecoder().decodeBytes(decompressed);

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
  // Rename extracted folder (e.g. mbedtls-3.6.5) to 'src' for shorter paths
  final folder = extractDir.listSync().firstWhere((element) => element is Directory);
  await (folder as Directory).rename(srcDir.path);
  return srcDir.uri;
}

String _targetKey(BuildInput input) {
  final os = input.config.code.targetOS.toString();
  final arch = input.config.code.targetArchitecture.toString();
  return '$os-$arch';
}

Future<Uri> _buildMbedTLS(BuildInput input, BuildOutputBuilder output, Logger logger) async {
  final targetKey = _targetKey(input);
  final mbedtlsBase = input.outputDirectoryShared.resolve('tls/');
  final installPrefix = mbedtlsBase.resolve('i-$targetKey/');

  // Skip if already built
  final includeCheck = File.fromUri(installPrefix.resolve('include/mbedtls/ssl.h'));
  if (await includeCheck.exists()) {
    logger.info('mbedTLS already built, skipping');
    return installPrefix;
  }

  final sourceDir = await _downloadMbedTLS(input.outputDirectoryShared);

  final builder = CMakeBuilder.create(
    name: 'mbedtls',
    sourceDir: sourceDir,
    buildMode: BuildMode.release,
    generator: Generator.defaultGenerator,
    defines: {
      'CMAKE_BUILD_TYPE': 'Release',
      'CMAKE_INSTALL_PREFIX': installPrefix.toFilePath(),
      'MBEDTLS_FATAL_WARNINGS': 'OFF',
      'ENABLE_TESTING': 'OFF',
      'ENABLE_PROGRAMS': 'OFF',
      'USE_STATIC_MBEDTLS_LIBRARY': 'ON',
      'BUILD_SHARED_LIBS': 'OFF',
      'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
    },
    targets: ['install'],
    buildLocal: true,
    logger: logger,
  );

  await builder.run(input: input, output: output, logger: logger);

  return installPrefix;
}

Future<Uri> download(Uri outputDirectory, String version) async {
  // Use short directory names to avoid Windows MAX_PATH (260 char) limit.
  final extractDir = Directory.fromUri(outputDirectory.resolve('dl/'));

  // Return early if already downloaded and renamed
  final srcDir = Directory.fromUri(extractDir.uri.resolve('src/'));
  if (await srcDir.exists()) {
    return srcDir.uri;
  }

  // final url = Uri.parse('https://github.com/open62541/open62541/archive/refs/tags/$version.zip');
  final url = Uri.parse('https://github.com/open62541/open62541/archive/$version.zip');
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
  // Rename extracted folder (e.g. open62541-includes) to 'src' for shorter paths
  final folder = extractDir.listSync().firstWhere((element) => element is Directory);
  if (!await Directory.fromUri(folder.uri).exists()) {
    throw Exception('Error extracting open62541 version $version: extracted directory not found');
  }
  await (folder as Directory).rename(srcDir.path);
  return srcDir.uri;
}

Future<void> _applyPatches(Uri sourceDir) async {
  final targetFile = File.fromUri(sourceDir.resolve('src/client/ua_client_subscriptions.c'));
  if (!await targetFile.exists()) return;

  var content = await targetFile.readAsString();

  // Already patched?
  if (content.contains('Clean up all client-side subscriptions')) return;

  // OPC UA Part 4, 5.13.5, Table 95: when BadNoSubscription arrives with
  // subscriptionId == 0, clean ALL client-side subscriptions so that
  // deleteCallback fires for each.
  const original = '''        if(sub != NULL)
            __Client_Subscription_deleteInternal(client, sub);
        return;''';

  const patched = '''        if(sub != NULL) {
            __Client_Subscription_deleteInternal(client, sub);
        } else if(response->subscriptionId == 0) {
            /* OPC UA Part 4, 5.13.5, Table 95: subscriptionId 0 means
             * "no Subscriptions defined for which a response could be sent."
             * Clean up all client-side subscriptions. */
            UA_Client_Subscription *s, *s_tmp;
            LIST_FOREACH_SAFE(s, &client->subscriptions, listEntry, s_tmp)
                __Client_Subscription_deleteInternal(client, s);
        }
        return;''';

  if (!content.contains(original)) {
    throw Exception('Cannot apply subscription patch: expected code not found');
  }
  content = content.replaceFirst(original, patched);
  await targetFile.writeAsString(content);
}

Future<void> main(List<String> args) async {
  // final version = "v1.5.2";
  final version = "97a4ee6c1c687ba1909ca59369e2b73b1c938d07";
  await build(args, (input, output) async {
    final extractedFiles = await download(input.outputDirectoryShared, version);
    await _applyPatches(extractedFiles);

    final name = 'open62541';
    final logger = Logger('')
      ..level = Level.ALL
      // temp fwd to stderr until process logs pass to stdout
      ..onRecord.listen((record) => stderr.writeln(record));

    // Build mbedTLS first
    final mbedtlsInstall = await _buildMbedTLS(input, output, logger);
    final mbedtlsLibDir = mbedtlsInstall.resolve('lib/');
    final isWindows = input.config.code.targetOS == OS.windows;
    final libPrefix = isWindows ? '' : 'lib';
    final libSuffix = isWindows ? '.lib' : '.a';

    final builder = CMakeBuilder.create(
      name: name,
      sourceDir: extractedFiles,
      buildMode: BuildMode.release,
      generator: Generator.defaultGenerator,
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
        'UA_ENABLE_AMALGAMATION': 'ON',
        'MBEDTLS_INCLUDE_DIRS': mbedtlsInstall.resolve('include/').toFilePath(),
        'MBEDTLS_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedtls$libSuffix').toFilePath(),
        'MBEDX509_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedx509$libSuffix').toFilePath(),
        'MBEDCRYPTO_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedcrypto$libSuffix').toFilePath(),
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
      OS.windows => "install/bin/open62541.dll",
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
