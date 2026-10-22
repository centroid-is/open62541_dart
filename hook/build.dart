import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Pinned download checksums (supply-chain / reproducibility hardening).
//
// Every third-party source archive fetched by this hook is downloaded over
// HTTPS and verified against a pinned SHA-256 before use. A mismatch fails the
// build loudly instead of silently building tampered or unexpected sources.
//
// Bumping a version is a one-line change: add/replace the {version: sha256}
// entry below (and, for open62541, the `version` string in main()).
//
// How to (re)generate a checksum for a version:
//   open62541 (auto-generated GitHub source archive):
//     curl -sL -o o62.zip \
//       https://github.com/open62541/open62541/archive/<version>.zip
//     sha256sum o62.zip
//   mbedTLS (official release asset):
//     curl -sL -o mbedtls.tar.bz2 \
//       https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-<v>/mbedtls-<v>.tar.bz2
//     sha256sum mbedtls.tar.bz2
//
// NOTE: The open62541 URL uses GitHub's *auto-generated* source archive
// (/archive/<tag>.zip). GitHub has historically kept these byte-stable, but has
// changed auto-generated archive bytes once before (Jan 2023). If a checksum
// mismatch ever appears without an intentional version bump, re-verify against a
// trusted source before updating the pin. The mbedTLS URL is an uploaded
// release asset, which is immutable.
// ---------------------------------------------------------------------------

/// SHA-256 of the open62541 source archive, keyed by version tag.
const Map<String, String> _open62541Sha256 = {
  'v1.5.6': 'c142bd304f7f614f570a2b8ec0a618608bc22a94b43e4e477525829ba1c69641',
  'v1.5.7': '79ded488caf7b8dc7f1ad1269d0142a80c47bab1d5725663f194f72ac8911a78',
  'v1.5.8': 'aae5d1e6c73f8fd5a72e36e6d21afb27bf5eacbe3f20e3581dbde80d3024cadc',
  'v1.5.9': 'e67790c33feeee660a3831fb2546a3dea070d93003c7901523cf8ed3963ef840',
};

/// mbedTLS release version and the SHA-256 of its `.tar.bz2` release asset.
const String _mbedtlsVersion = '3.6.7';
const String _mbedtlsSha256 = 'a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6';

/// Downloads [url] over HTTPS and verifies the payload against
/// [expectedSha256], returning the raw bytes.
///
/// Fails loudly (throws) when:
///   - [url] is not HTTPS,
///   - the HTTP request does not return 200, or
///   - the SHA-256 of the downloaded bytes does not match [expectedSha256].
Future<Uint8List> _downloadVerified(Uri url, {required String expectedSha256, required String what}) async {
  if (url.scheme != 'https') {
    throw Exception(
      'Refusing to download $what over insecure scheme "${url.scheme}": $url '
      '(HTTPS is required).',
    );
  }
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw Exception('Error downloading $what: HTTP ${response.statusCode} from $url');
  }
  final bytes = response.bodyBytes;
  final actual = sha256.convert(bytes).toString();
  if (actual != expectedSha256.toLowerCase()) {
    throw Exception(
      'Checksum mismatch for $what downloaded from $url\n'
      '  expected sha256: $expectedSha256\n'
      '  actual   sha256: $actual\n'
      'Refusing to build with an unverified artifact. If you intentionally '
      'changed the version, update the pinned checksum in hook/build.dart.',
    );
  }
  return bytes;
}

Future<Uri> _downloadMbedTLS(Uri baseDir) async {
  // Use short directory names to avoid Windows MAX_PATH (260 char) limit.
  // CMake TryCompile creates deeply nested paths inside the build directory.
  final extractDir = Directory.fromUri(baseDir.resolve('tls/'));
  final url = Uri.parse(
    'https://github.com/Mbed-TLS/mbedtls/releases/download/'
    'mbedtls-$_mbedtlsVersion/mbedtls-$_mbedtlsVersion.tar.bz2',
  );

  // Reuse the extracted tree only if it holds the pinned version. The shared
  // output directory outlives a package upgrade, so an unstamped or
  // differently-stamped tree is a previous release's source: discard it
  // together with everything built from it (the CMake build directory inside
  // src/ and every i-<target>/ install prefix beside it) rather than silently
  // link the old mbedTLS into the new library.
  final srcDir = Directory.fromUri(extractDir.uri.resolve('src/'));
  final versionStamp = File.fromUri(extractDir.uri.resolve('version'));
  if (await srcDir.exists() &&
      await versionStamp.exists() &&
      (await versionStamp.readAsString()).trim() == _mbedtlsVersion) {
    return srcDir.uri;
  }
  if (await extractDir.exists()) {
    await extractDir.delete(recursive: true);
  }

  final bytes = await _downloadVerified(url, expectedSha256: _mbedtlsSha256, what: 'mbedTLS $_mbedtlsVersion');

  final decompressed = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(decompressed);

  await extractArchiveInto(archive, extractDir);
  // Rename extracted folder (e.g. mbedtls-3.6.7) to 'src' for shorter paths
  final folder = extractDir.listSync().firstWhere((element) => element is Directory);
  await (folder as Directory).rename(srcDir.path);
  await versionStamp.writeAsString(_mbedtlsVersion);
  return srcDir.uri;
}

/// Writes the regular files of [archive] under [extractDir].
///
/// Directory entries are implied by the files under them, and symbolic links
/// are skipped: nothing this hook builds needs one, and a link is how an
/// archive reaches outside its own tree (an entry under a link that points at
/// `/` or `..` lands wherever the link does). Every entry's path must resolve
/// inside [extractDir] once `..` and absolute names are taken into account,
/// or the whole extraction is refused naming the entry. The archives are
/// verified against a pinned SHA-256 before they get here, so this is
/// defense in depth, not the line that holds.
Future<void> extractArchiveInto(Archive archive, Directory extractDir) async {
  if (!await extractDir.exists()) {
    await extractDir.create(recursive: true);
  }
  // Resolved: the base must be the same string the entries are compared to,
  // and a relative extractDir or one reached through a symlink is not.
  final base = Directory(await extractDir.resolveSymbolicLinks()).uri;
  final basePath = base.toFilePath();
  for (final file in archive) {
    if (file.isSymbolicLink || !file.isFile) continue;
    // An entry name is refused when it is absolute (a leading separator or
    // a Windows drive letter, which `Uri.toFilePath` would reject on Windows
    // rather than resolve), when the URI resolution removing `.` and `..`
    // segments lands outside the base, or when the name is not a file path
    // at all.
    final name = file.name.replaceAll('\\', '/');
    final absolute = name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name);
    String? target;
    if (!absolute) {
      try {
        target = base.resolveUri(Uri(path: name)).toFilePath();
      } on UnsupportedError {
        target = null;
      } on FormatException {
        target = null;
      }
    }
    if (target == null || !target.startsWith(basePath) || target == basePath) {
      throw Exception('Refusing to extract "${file.name}": it resolves outside ${extractDir.path}');
    }
    final outputStream = OutputFileStream(target);
    file.writeContent(outputStream);
    outputStream.closeSync();
  }
}

String _targetKey(BuildInput input) {
  final os = input.config.code.targetOS.toString();
  final arch = input.config.code.targetArchitecture.toString();
  return '$os-$arch';
}

/// Compiler and linker hardening for the native builds, per toolchain.
///
/// The toolchain follows the target OS the way the build itself does:
/// `native_toolchain_cmake` configures a Windows target with CMake's default
/// generator there (Visual Studio, so MSVC), an Android target through the
/// NDK's toolchain file and an iOS/macOS target through its Xcode toolchain
/// file (clang both), and Linux with the system compiler (GCC or clang). Every
/// one of them understands its flags, so nothing is probed on the host.
///
/// GCC/clang: `-fstack-protector-strong` puts a canary in every frame that
/// holds an array or has a local's address taken; `_FORTIFY_SOURCE=2` compiles
/// a bounded `__*_chk` libc call in place of an unbounded one wherever the
/// compiler knows the destination size (it needs optimisation, which the
/// Release build's -O3 gives; Apple's libc fortifies a subset and the rest
/// compiles as before). On Linux and Android the shared library is linked
/// with `-z relro -z now` as well: the GOT is resolved at load and then made
/// read-only, so a write primitive cannot redirect a call through it. The
/// Apple linker has no RELRO (`__DATA_CONST` is its default equivalent).
///
/// MSVC: `/GS` is the canary, `/guard:cf` Control Flow Guard (wanted by both
/// the compiler and the linker), `/DYNAMICBASE` ASLR and `/NXCOMPAT` DEP for
/// the DLL.
///
/// mbedTLS is built as a static library and linked into libopen62541, so it
/// takes the same compile flags; the linker flags apply where it is linked.
/// `test/native_hardening_test.dart` reads the marks these leave in the ELF.
///
/// The flags reach CMake as a script passed in `CMAKE_PROJECT_INCLUDE`, which
/// CMake runs after every `project()` call, after the toolchain file. They
/// cannot go in `CMAKE_C_FLAGS`: `native_toolchain_cmake`'s toolchain files
/// `set()` that variable (`-march=...`) and shadow the command-line value.
///
/// The text of the script for [targetOS]; [floatLittleEndian] adds the
/// open62541-only define, [sanitizer] ASan + UBSan.
String hardeningCmake(OS targetOS, {bool floatLittleEndian = false, bool sanitizer = false}) {
  final compile = <String>[];
  final link = <String>[];
  if (targetOS == OS.windows) {
    compile.addAll(['/GS', '/guard:cf']);
    link.addAll(['/DYNAMICBASE', '/NXCOMPAT', '/guard:cf']);
  } else {
    compile.addAll(['-fstack-protector-strong', '-D_FORTIFY_SOURCE=2']);
    if (targetOS == OS.linux || targetOS == OS.android) {
      link.addAll(['-Wl,-z,relro', '-Wl,-z,now']);
    }
  }
  if (sanitizer) {
    compile.addAll(['-fsanitize=address,undefined', '-fno-omit-frame-pointer']);
    link.add('-fsanitize=address,undefined');
  }
  return [
    if (floatLittleEndian) 'add_compile_definitions(UA_FLOAT_LITTLE_ENDIAN=1)',
    'add_compile_options("\$<\$<COMPILE_LANGUAGE:C>:${compile.join(';')}>")',
    if (link.isNotEmpty) 'add_link_options(${link.join(' ')})',
    '',
  ].join('\n');
}

/// Writes [script] to `hardening-<name>.cmake` under [dir] and returns the
/// path to hand to `CMAKE_PROJECT_INCLUDE`.
Future<String> _writeHardening(Uri dir, String name, String script) async {
  final file = File.fromUri(dir.resolve('hardening-$name.cmake'));
  await file.parent.create(recursive: true);
  await file.writeAsString(script);
  return file.path;
}

/// Configures + builds + installs a CMake project via `native_toolchain_cmake`.
///
/// [CMakeBuilder] manages its own build directory via `buildLocal`, and honors
/// `CMAKE_INSTALL_PREFIX` passed in [defines], so callers pick up the install
/// output the same way.
Future<void> _buildCmakeProject({
  required BuildInput input,
  required BuildOutputBuilder output,
  required Logger logger,
  required String name,
  required Uri sourceDir,
  required Map<String, String?> defines,
  required List<String> targets,
}) async {
  final builder = CMakeBuilder.create(
    name: name,
    sourceDir: sourceDir,
    buildMode: BuildMode.release,
    generator: Generator.defaultGenerator,
    defines: defines,
    targets: targets,
    buildLocal: true,
    logger: logger,
  );
  await builder.run(input: input, output: output, logger: logger);
}

Future<Uri> _buildMbedTLS(BuildInput input, BuildOutputBuilder output, Logger logger) async {
  final targetKey = _targetKey(input);
  final mbedtlsBase = input.outputDirectoryShared.resolve('tls/');
  final installPrefix = mbedtlsBase.resolve('i-$targetKey/');

  // Resolve the source tree before looking for an install: a tree of another
  // version is discarded there along with every i-<target>/ prefix built from
  // it, so an install that is still present afterwards is the pinned version.
  final sourceDir = await _downloadMbedTLS(input.outputDirectoryShared);

  // Skip if already built for this target with these flags. The flags are
  // stamped into the install prefix: the prefix outlives a package upgrade,
  // and an install built under other flags (or none) would otherwise be
  // linked in as it is. A mismatch discards the install and rebuilds; the
  // CMake build directory under src/ is reconfigured, so only the objects
  // the flags touch recompile.
  final hardening = hardeningCmake(input.config.code.targetOS);
  final flags = hardening;
  final flagsStamp = File.fromUri(installPrefix.resolve('flags'));
  final includeCheck = File.fromUri(installPrefix.resolve('include/mbedtls/ssl.h'));
  if (await includeCheck.exists()) {
    if (await flagsStamp.exists() && await flagsStamp.readAsString() == flags) {
      logger.info('mbedTLS already built, skipping');
      return installPrefix;
    }
    logger.info('mbedTLS install was built with other flags, rebuilding');
    await Directory.fromUri(installPrefix).delete(recursive: true);
  }

  await _buildCmakeProject(
    input: input,
    output: output,
    logger: logger,
    name: 'mbedtls',
    sourceDir: sourceDir,
    defines: {
      'CMAKE_BUILD_TYPE': 'Release',
      'CMAKE_INSTALL_PREFIX': installPrefix.toFilePath(),
      'MBEDTLS_FATAL_WARNINGS': 'OFF',
      'ENABLE_TESTING': 'OFF',
      'ENABLE_PROGRAMS': 'OFF',
      'USE_STATIC_MBEDTLS_LIBRARY': 'ON',
      'BUILD_SHARED_LIBS': 'OFF',
      'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
      'CMAKE_PROJECT_INCLUDE': await _writeHardening(input.outputDirectoryShared, 'mbedtls', hardening),
    },
    targets: ['install'],
  );
  await flagsStamp.writeAsString(flags);

  return installPrefix;
}

Future<Uri> download(Uri outputDirectory, String version) async {
  // Use short directory names to avoid Windows MAX_PATH (260 char) limit.
  final extractDir = Directory.fromUri(outputDirectory.resolve('dl/'));

  // Reuse the extracted tree only if it holds the pinned version. The shared
  // output directory outlives a package upgrade, so an unstamped or
  // differently-stamped tree is a previous release's source (and CMake build
  // directory, which lives inside it): discard it rather than silently build
  // the old library against the new bindings.
  final srcDir = Directory.fromUri(extractDir.uri.resolve('src/'));
  final versionStamp = File.fromUri(extractDir.uri.resolve('version'));
  if (await srcDir.exists() && await versionStamp.exists() && (await versionStamp.readAsString()).trim() == version) {
    return srcDir.uri;
  }
  if (await extractDir.exists()) {
    await extractDir.delete(recursive: true);
  }

  final expectedSha256 = _open62541Sha256[version];
  if (expectedSha256 == null) {
    throw Exception(
      'No pinned SHA-256 checksum for open62541 version "$version". '
      'Add its checksum to _open62541Sha256 in hook/build.dart '
      '(see the regeneration note at the top of the file).',
    );
  }

  // final url = Uri.parse('https://github.com/open62541/open62541/archive/refs/tags/$version.zip');
  final url = Uri.parse('https://github.com/open62541/open62541/archive/$version.zip');
  final bytes = await _downloadVerified(url, expectedSha256: expectedSha256, what: 'open62541 $version');
  final archive = ZipDecoder().decodeBytes(bytes);

  await extractArchiveInto(archive, extractDir);
  // Rename extracted folder (e.g. open62541-includes) to 'src' for shorter paths
  final folder = extractDir.listSync().firstWhere((element) => element is Directory);
  if (!await Directory.fromUri(folder.uri).exists()) {
    throw Exception('Error extracting open62541 version $version: extracted directory not found');
  }
  await (folder as Directory).rename(srcDir.path);
  await versionStamp.writeAsString(version);
  return srcDir.uri;
}

/// Applies every open62541 source patch this package carries against the
/// freshly extracted source tree at [sourceDir]. Patch files live under
/// `[packageRoot]/hook/`. Each patch is anchored on stable surrounding source
/// text and fails the build loudly if it cannot be applied — so a future
/// open62541 version bump cannot silently drop a fix.
Future<void> _applyPatches(Uri sourceDir, Uri packageRoot) async {
  await _patchSubscriptionCleanup(sourceDir);
  await _patchBoundedSend(sourceDir, packageRoot);
  await _patchSessionRecreateRace(sourceDir, packageRoot);
  await _patchDeleteByClientHandle(sourceDir, packageRoot);
  await _patchAsyncManagerSingleThread(sourceDir);
  await _patchDynamicPort(sourceDir, packageRoot);
}

/// Gives a server started on port 0 ONE port for every address family.
///
/// open62541 supports dynamic port assignment (`UA_ServerConfig_setMinimal`
/// with port 0: the listen socket binds port 0, `getsockname` reads the port
/// the OS picked, and the binary protocol manager advertises it as a
/// DiscoveryUrl). But `TCP_registerListenSockets` in
/// `arch/posix/eventloop_posix_tcp.c` passes the configured port (0) to every
/// `getaddrinfo` result separately, so on a dual-stack host the IPv4 and the
/// IPv6 listen socket each get their own OS-picked port and the server
/// advertises two DiscoveryUrls that differ only in the port. The patch binds
/// the IPv4 addresses first and reuses the port the OS picked for them for the
/// remaining families, so `Server.port` is THE port. Same delivery mechanism
/// as [_patchSessionRecreateRace].
Future<void> _patchDynamicPort(Uri sourceDir, Uri packageRoot) async {
  final targetFile = File.fromUri(sourceDir.resolve('arch/posix/eventloop_posix_tcp.c'));
  if (!await targetFile.exists()) {
    throw Exception('Cannot apply dynamic-port patch: arch/posix/eventloop_posix_tcp.c not found under $sourceDir.');
  }

  // Idempotent: the patch injects a uniquely-worded comment (warm shared
  // source dir reused across builds).
  const marker = 'reuse the port the OS picked for them for the';
  if ((await targetFile.readAsString()).contains(marker)) {
    return;
  }

  final patchFile = File.fromUri(packageRoot.resolve('hook/dynamic_port.patch'));
  if (!await patchFile.exists()) {
    throw Exception(
      'Cannot apply dynamic-port patch: patch file not found at ${patchFile.path}. '
      'It must ship with the package (check .pubignore does not exclude hook/).',
    );
  }

  await _applyUnifiedDiff(sourceDir: sourceDir, patchFile: patchFile, what: 'dynamic-port');

  if (!(await targetFile.readAsString()).contains(marker)) {
    throw Exception(
      'dynamic-port patch tool reported success but the fix is absent from '
      'eventloop_posix_tcp.c. The upstream source likely changed shape; re-verify the patch.',
    );
  }
}

/// Runs the server's AsyncManager lifecycle in single-threaded builds too.
///
/// open62541 1.5.7 compiles the async-operation SERVICE paths unconditionally
/// (a method/read/write callback may return
/// `UA_STATUSCODE_GOODCOMPLETESASYNCHRONOUSLY` and complete later via
/// `UA_Server_setAsyncCallMethodResult` etc.), but guards the AsyncManager's
/// init/start/stop/clear calls in `ua_server.c` behind
/// `#if UA_MULTITHREADING >= 100`. This package builds with
/// `UA_MULTITHREADING=0`, so the manager's TAILQ heads stay zeroed and the
/// FIRST parked async operation crashes with a NULL store
/// (`TAILQ_INSERT_TAIL` through `waitingOps.tqh_last == NULL`).
///
/// The async machinery itself is thread-agnostic — operations are parked and
/// completed on the event-loop thread; the 1s timeout sweep is a regular
/// server callback; ready responses are flushed via the event loop's delayed
/// callbacks — so the fix is simply to run the manager lifecycle
/// unconditionally. The threading model is NOT changed (UA_MULTITHREADING
/// stays 0). Anchored string replacement, same delivery mechanism as
/// [_patchSubscriptionCleanup].
Future<void> _patchAsyncManagerSingleThread(Uri sourceDir) async {
  final targetFile = File.fromUri(sourceDir.resolve('src/server/ua_server.c'));
  if (!await targetFile.exists()) {
    throw Exception('Cannot apply async-manager patch: ua_server.c not found under $sourceDir');
  }

  var content = await targetFile.readAsString();

  // Already patched? (idempotency marker)
  if (content.contains('AsyncManager also runs in single-threaded builds')) return;

  const blocks = <(String original, String patched)>[
    (
      '''
#if UA_MULTITHREADING >= 100
    UA_AsyncManager_init(&server->asyncManager, server);
#endif''',
      '''
    /* AsyncManager also runs in single-threaded builds (open62541_dart patch):
     * the async service paths are compiled unconditionally upstream, so the
     * manager must be initialized regardless of UA_MULTITHREADING. */
    UA_AsyncManager_init(&server->asyncManager, server);''',
    ),
    (
      '''
#if UA_MULTITHREADING >= 100
    /* Add regulare callback for async operation processing */
    UA_AsyncManager_start(&server->asyncManager, server);
#endif''',
      '''
    /* Add regular callback for async operation processing */
    UA_AsyncManager_start(&server->asyncManager, server);''',
    ),
    (
      '''
#if UA_MULTITHREADING >= 100
    /* Stop regular callback for async operation processing */
    UA_AsyncManager_stop(&server->asyncManager, server);
#endif''',
      '''
    /* Stop regular callback for async operation processing */
    UA_AsyncManager_stop(&server->asyncManager, server);''',
    ),
    (
      '''
#if UA_MULTITHREADING >= 100
    UA_AsyncManager_clear(&server->asyncManager, server);
#endif''',
      '''
    UA_AsyncManager_clear(&server->asyncManager, server);''',
    ),
  ];

  for (final (original, patched) in blocks) {
    final matches = original.allMatches(content).length;
    if (matches != 1) {
      throw Exception(
        'Cannot apply async-manager patch: expected exactly 1 occurrence of '
        'anchor "${original.trim().split('\n').last.trim()}" in ua_server.c, '
        'found $matches. The upstream source changed shape — re-verify and '
        'update the anchors.',
      );
    }
    content = content.replaceFirst(original, patched);
  }
  await targetFile.writeAsString(content);
}

/// Stops a transient, recoverable event from permanently wedging the client's
/// session state machine.
///
/// ROOT CAUSE (session-recreate-race; field evidence: Beckhoff TwinCAT,
/// SignAndEncrypt/Aes256_Sha256_RsaPss, reproduced 6/6 process restarts):
/// two paths in the client's connect logic latch a fatal `connectStatus`
/// during a live handshake, after which `connectActivity` returns on its first
/// line forever and only a fresh application-driven connect can revive it.
///
///  1. `processServiceResponse` (ua_client.c) tears the Session down on ANY
///     BadSessionIdInvalid/BadSessionClosed response regardless of state. When
///     a CreateSession is already in flight, a late response for a request from
///     the *previous* Session resets the state to CLOSED; the next connect
///     iteration issues a SECOND CreateSession, `createSessionAsync`
///     regenerates `clientSessionNonce`, and the response to the FIRST
///     CreateSession is then verified against the wrong nonce ->
///     BadSecurityChecksFailed -> fatal.
///  2. A CreateSession/ActivateSession cancelled by a SecureChannel close
///     (BadSecureChannelClosed) reaches the same failure path as a server
///     rejection and latches fatal, so the channel reconnect that follows
///     never re-creates the Session.
///
/// The fix (ua_client.c + ua_client_connect.c): only tear the Session down on
/// a stale-session response while it is ACTIVATED, and treat a
/// BadSecureChannelClosed on the CreateSession/ActivateSession callbacks as the
/// local cancellation it is (put the session state back, let the reconnected
/// channel finish the handshake) instead of a fatal server rejection.
///
/// Submitted upstream; carried here as a build-time patch until it lands in a
/// tagged open62541 release. Same delivery mechanism as [_patchBoundedSend].
Future<void> _patchSessionRecreateRace(Uri sourceDir, Uri packageRoot) async {
  final clientFile = File.fromUri(sourceDir.resolve('src/client/ua_client.c'));
  final connectFile = File.fromUri(sourceDir.resolve('src/client/ua_client_connect.c'));
  if (!await clientFile.exists() || !await connectFile.exists()) {
    throw Exception(
      'Cannot apply session-recreate patch: ua_client.c / ua_client_connect.c '
      'not found under $sourceDir.',
    );
  }

  // Idempotent: the patch injects a uniquely-worded comment. If it is already
  // present the source is patched (e.g. a warm shared source dir reused across
  // builds), so there is nothing to do.
  const marker = 'The request was cancelled locally because the SecureChannel closed';
  if ((await connectFile.readAsString()).contains(marker)) {
    return;
  }

  final patchFile = File.fromUri(packageRoot.resolve('hook/session_recreate_race.patch'));
  if (!await patchFile.exists()) {
    throw Exception(
      'Cannot apply session-recreate patch: patch file not found at '
      '${patchFile.path}. It must ship with the package (check .pubignore does '
      'not exclude hook/).',
    );
  }

  await _applyUnifiedDiff(sourceDir: sourceDir, patchFile: patchFile, what: 'session-recreate');

  // Belt-and-suspenders: confirm the fix actually landed, so a patch tool that
  // exits 0 without applying still fails the build loudly.
  if (!(await connectFile.readAsString()).contains(marker)) {
    throw Exception(
      'session-recreate patch tool reported success but the fix is absent from '
      'ua_client_connect.c — refusing to ship the frozen-session bug. The '
      'upstream source likely changed shape; re-verify the patch.',
    );
  }
}

/// Fixes the orphaned-monitored-item bookkeeping race in open62541's
/// DeleteMonitoredItems response handling.
///
/// ROOT CAUSE (stale-keys / orphaned monitored items): the delete-response
/// handler removes local MonitoredItems by their server-assigned
/// `monitoredItemId` at response-processing time. That id is server-recyclable,
/// so when a delete and a create interleave the handler can erase the NEW live
/// item locally while the server keeps sampling and publishing it — the
/// notification then arrives for a clientHandle the client has forgotten
/// ("Could not process a notification with clienthandle N") and the key freezes
/// silently. The patch snapshots the client-assigned, monotonically-unique
/// `clientHandle` of each requested id at request-build time and removes by that
/// handle at response time, so the collision is structurally impossible.
///
/// Delivered as a build-time source patch (same mechanism as
/// [_patchBoundedSend]); submitted upstream in parallel.
Future<void> _patchDeleteByClientHandle(Uri sourceDir, Uri packageRoot) async {
  final targetFile = File.fromUri(sourceDir.resolve('src/client/ua_client_subscriptions.c'));
  if (!await targetFile.exists()) {
    throw Exception('Cannot apply delete-by-client-handle patch: ua_client_subscriptions.c not found under $sourceDir');
  }

  if ((await targetFile.readAsString()).contains('UA62541_DART_DELETE_BY_HANDLE')) {
    return; // already patched (warm shared source dir)
  }

  final patchFile = File.fromUri(packageRoot.resolve('hook/delete_by_client_handle.patch'));
  if (!await patchFile.exists()) {
    throw Exception(
      'Cannot apply delete-by-client-handle patch: patch file not found at ${patchFile.path}. '
      'It must ship with the package (check .pubignore does not exclude hook/).',
    );
  }

  await _applyUnifiedDiff(sourceDir: sourceDir, patchFile: patchFile, what: 'delete-by-client-handle');

  if (!(await targetFile.readAsString()).contains('UA62541_DART_DELETE_BY_HANDLE')) {
    throw Exception(
      'delete-by-client-handle patch tool reported success but UA62541_DART_DELETE_BY_HANDLE '
      'is absent from ua_client_subscriptions.c — refusing to ship the orphaned-monitored-item '
      'bookkeeping race. The upstream source likely changed shape; re-verify the patch.',
    );
  }
}

/// OPC UA Part 4, 5.13.5, Table 95: when BadNoSubscription arrives with
/// subscriptionId == 0, clean ALL client-side subscriptions so that
/// deleteCallback fires for each.
Future<void> _patchSubscriptionCleanup(Uri sourceDir) async {
  final targetFile = File.fromUri(sourceDir.resolve('src/client/ua_client_subscriptions.c'));
  if (!await targetFile.exists()) {
    throw Exception('Cannot apply subscription patch: ua_client_subscriptions.c not found under $sourceDir');
  }

  var content = await targetFile.readAsString();

  // Already patched?
  if (content.contains('Clean up all client-side subscriptions')) return;

  // Anchored on the v1.5.x BadNoSubscription case in the PublishResponse
  // handler.
  const original = '''        UA_LOG_DEBUG(client->config.logging, UA_LOGCATEGORY_CLIENT,
                     "PublishResponse: Received BadNoSubscription status");
        return;''';

  const patched = '''        UA_LOG_DEBUG(client->config.logging, UA_LOGCATEGORY_CLIENT,
                     "PublishResponse: Received BadNoSubscription status");
        /* OPC UA Part 4, 5.13.5, Table 95: subscriptionId 0 means "no
         * Subscriptions defined for which a response could be sent."
         * Clean up all client-side subscriptions so deleteCallback fires
         * for each. */
        if(response->subscriptionId == 0) {
            UA_Client_Subscription *s, *s_tmp;
            LIST_FOREACH_SAFE(s, &client->subscriptions, listEntry, s_tmp)
                __Client_Subscription_deleteInternal(client, s);
        }
        return;''';

  final matches = original.allMatches(content).length;
  if (matches != 1) {
    throw Exception(
      'Cannot apply subscription patch: expected exactly 1 occurrence of the '
      'BadNoSubscription anchor in ua_client_subscriptions.c, found $matches. '
      'The upstream source changed shape — re-verify and update the anchor.',
    );
  }
  content = content.replaceFirst(original, patched);
  await targetFile.writeAsString(content);
}

/// Bounds the blocking send-retry loop in the POSIX/WinSock TCP connection
/// manager so a dead secured connection can no longer wedge the client isolate.
///
/// ROOT CAUSE (bounded-send-fix; bench evidence tfc-hmi #345/#346):
/// `TCP_sendWithConnection` in `arch/posix/eventloop_posix_tcp.c` uses a
/// non-blocking socket, but when `UA_send` returns EWOULDBLOCK (the OS send
/// buffer is full and cannot drain because the peer stopped ACKing — a
/// half-open / CloseWait socket) it enters
///
///     do { poll_ret = UA_poll(&fd, 1, 100); ... } while(poll_ret <= 0);
///
/// with NO overall deadline: the 100 ms only bounds a single poll. On a dead
/// peer POLLOUT never becomes ready (and on Windows, WSAPoll never reports
/// POLLHUP/POLLERR for a peer gone without RST), so the loop spins forever
/// *inside* `UA_Client_run_iterate`. Because the Dart client isolate drives
/// open62541 from its single event-loop thread, that one synchronous FFI call
/// freezes the whole isolate: state queries, monitored items and even
/// `disconnect` are never processed again.
///
/// This fix adds a monotonic wall-clock deadline to the retry loop. When the
/// socket cannot be written for longer than `UA62541_DART_SEND_DEADLINE_MS` the
/// send is treated as a dead connection (`goto shutdown`), exactly like any
/// other unrecoverable send error: `UA_Client_run_iterate` returns,
/// `connectStatus` goes bad, and the existing `keepConnected` supervisor
/// reconnects — with no isolate killed and no leaked `UA_Client`. The deadline
/// is wall-clock and independent of what poll reports, so it fixes every
/// platform including the Windows WSAPoll case.
///
/// The change ships as a unified-diff patch file,
/// `hook/bounded_send_deadline.patch`, applied here with a standard patch tool
/// (`git apply`, falling back to `patch`). See [_applyUnifiedDiff]. The
/// patched loop uses two symbols (`UA_DateTime_nowMonotonic`, `UA_DATETIME_MSEC`)
/// both declared in open62541/types.h, which this translation unit includes
/// directly.
Future<void> _patchBoundedSend(Uri sourceDir, Uri packageRoot) async {
  final targetFile = File.fromUri(sourceDir.resolve('arch/posix/eventloop_posix_tcp.c'));
  if (!await targetFile.exists()) {
    throw Exception('Cannot apply bounded-send patch: eventloop_posix_tcp.c not found under $sourceDir');
  }

  // Idempotent: the patch injects a uniquely-named compile-time constant. If it
  // is already present the source is patched (e.g. a warm shared source dir
  // reused across builds), so there is nothing to do.
  if ((await targetFile.readAsString()).contains('UA62541_DART_SEND_DEADLINE_MS')) {
    return;
  }

  final patchFile = File.fromUri(packageRoot.resolve('hook/bounded_send_deadline.patch'));
  if (!await patchFile.exists()) {
    throw Exception(
      'Cannot apply bounded-send patch: patch file not found at ${patchFile.path}. '
      'It must ship with the package (check .pubignore does not exclude hook/).',
    );
  }

  await _applyUnifiedDiff(sourceDir: sourceDir, patchFile: patchFile, what: 'bounded-send');

  // Belt-and-suspenders: confirm the fix actually landed, so a patch tool that
  // exits 0 without applying (should never happen) still fails the build loudly
  // rather than silently shipping the wedge.
  if (!(await targetFile.readAsString()).contains('UA62541_DART_SEND_DEADLINE_MS')) {
    throw Exception(
      'bounded-send patch tool reported success but UA62541_DART_SEND_DEADLINE_MS '
      'is absent from eventloop_posix_tcp.c — refusing to ship the client-isolate '
      'wedge. The upstream source likely changed shape; re-verify the patch.',
    );
  }
}

/// Applies the unified-diff [patchFile] to the extracted source tree rooted at
/// [sourceDir] using a standard patch tool, and fails the build loudly on any
/// non-zero exit.
///
/// Preference order:
///   1. `git apply -p1` — works on a plain (non-repo) extracted directory and
///      is the most predictable. `-p1` strips the leading `a/`/`b/` component
///      from the diff headers so the hunk lands on
///      `<sourceDir>/arch/posix/eventloop_posix_tcp.c`. A `git apply --check`
///      runs first; a non-zero check means the source no longer matches the
///      diff (an upstream version bump changed its shape), which is a hard
///      error — we do NOT silently fall through to another tool that would just
///      fail again with a murkier message.
///   2. `patch -p1` — used only when `git` is not on PATH at all.
///
/// TRADE-OFF: applying with an external tool adds a build-time dependency on
/// `git` (or `patch`) on the *consumer's* machine, which the previous in-Dart
/// string surgery did not need. In practice git is near-ubiquitous wherever a
/// native build runs — it sits alongside cmake and a C toolchain, and on Windows
/// it ships with Git-for-Windows (which also provides `patch`). If neither tool
/// is present we fail with an explicit, actionable message.
Future<void> _applyUnifiedDiff({required Uri sourceDir, required File patchFile, required String what}) async {
  final workingDirectory = sourceDir.toFilePath();

  // Apply an LF-normalized COPY of the patch. On a Windows checkout with
  // core.autocrlf=true the committed .patch file becomes CRLF, but the extracted
  // open62541 source is always LF — mismatched line endings make `git apply`
  // fail with "patch does not apply". Normalizing to LF here fixes it on every
  // platform regardless of how the file was checked out. (A .gitattributes rule
  // also keeps the committed patch LF; this is belt-and-suspenders and also
  // covers `patch` consumers.)
  final normalized = patchFile.readAsStringSync().replaceAll('\r\n', '\n');
  final tmpDir = Directory.systemTemp.createTempSync('o62_patch_');
  try {
    final patchPath = (File('${tmpDir.path}/$what.patch')..writeAsStringSync(normalized)).absolute.path;

    // Preferred path: `git apply` (--ignore-whitespace adds tolerance).
    final gitCheck = await _tryRun('git', [
      'apply',
      '--check',
      '--ignore-whitespace',
      '-p1',
      patchPath,
    ], workingDirectory);
    if (gitCheck != null) {
      if (gitCheck.exitCode != 0) {
        throw Exception(
          'Cannot apply $what patch: `git apply --check` failed (exit '
          '${gitCheck.exitCode}). The extracted open62541 source no longer matches '
          '${patchFile.path} — an upstream version bump likely changed its shape; '
          're-verify and regenerate the patch.\n${gitCheck.stderr}',
        );
      }
      final applied = await _tryRun('git', [
        'apply',
        '--verbose',
        '--ignore-whitespace',
        '-p1',
        patchPath,
      ], workingDirectory);
      if (applied == null || applied.exitCode != 0) {
        throw Exception(
          'Cannot apply $what patch: `git apply` failed (exit '
          '${applied?.exitCode}).\n${applied?.stderr}',
        );
      }
      return;
    }

    // Fallback: POSIX `patch -p1` when git is unavailable.
    final patched = await _tryRun('patch', ['-p1', '-i', patchPath], workingDirectory);
    if (patched == null) {
      throw Exception(
        'Cannot apply $what patch: neither `git` nor `patch` is available on PATH. '
        'Install git (recommended) or a patch tool to build this package.',
      );
    }
    if (patched.exitCode != 0) {
      throw Exception(
        'Cannot apply $what patch: `patch -p1` failed (exit ${patched.exitCode}).\n'
        'stdout: ${patched.stdout}\nstderr: ${patched.stderr}',
      );
    }
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Runs [executable] with [arguments] in [workingDirectory], returning its
/// [ProcessResult], or `null` if the executable is not found on PATH.
Future<ProcessResult?> _tryRun(String executable, List<String> arguments, String workingDirectory) async {
  try {
    return await Process.run(executable, arguments, workingDirectory: workingDirectory);
  } on ProcessException {
    return null; // executable not installed / not on PATH
  }
}

Future<void> main(List<String> args) async {
  final version = "v1.5.9";
  await build(args, (input, output) async {
    // A web build asks for no code assets, and there is nothing this hook could
    // usefully produce for one: dart2js has no C library to link. Without this
    // guard the hook still runs and dies in `_targetKey`, because
    // `input.config.code` throws rather than answering when code assets were
    // not requested — so `flutter build web` fails on a package the web code
    // never calls into. The pure-Dart half of this package
    // (`open62541_types.dart`) is exactly what such a build imports.
    if (!input.config.buildCodeAssets) return;

    final extractedFiles = await download(input.outputDirectoryShared, version);
    await _applyPatches(extractedFiles, input.packageRoot);

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

    // An (empty) `.open62541_sanitizer` file in the package root builds the
    // library with ASan + UBSan (CI's test-asan job), on top of the hardening
    // flags. The hooks runner starts hooks with a scrubbed environment, so an
    // environment variable never reaches this point, and `dart test` passes no
    // user-defines; a file is the one switch that does. It is registered as a
    // dependency so creating or removing it reruns the hook.
    final marker = input.packageRoot.resolve('.open62541_sanitizer');
    final sanitizer = await File.fromUri(marker).exists();
    output.dependencies.add(marker);
    final hardening = hardeningCmake(input.config.code.targetOS, floatLittleEndian: true, sanitizer: sanitizer);

    await _buildCmakeProject(
      input: input,
      output: output,
      logger: logger,
      name: name,
      sourceDir: extractedFiles,
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
        // OPC UA PubSub (Part 14). The base flag includes the UDP (UADP)
        // transport in 1.5.x; the information-model flag additionally surfaces
        // the PubSub configuration in the server's address space. MQTT, SKS
        // and raw-Ethernet transports stay off.
        'UA_ENABLE_PUBSUB': 'ON',
        'UA_ENABLE_PUBSUB_INFORMATIONMODEL': 'ON',
        // No XML decoder in the library: nothing in the Dart API or on the
        // opc.tcp binary path reaches it, and turning it off changes no
        // struct the bindings use. JSON stays on: event filter parsing
        // requires it, and turning events off shifts UA_ServerConfig fields.
        'UA_ENABLE_XML_ENCODING': 'OFF',
        'MBEDTLS_INCLUDE_DIRS': mbedtlsInstall.resolve('include/').toFilePath(),
        'MBEDTLS_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedtls$libSuffix').toFilePath(),
        'MBEDX509_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedx509$libSuffix').toFilePath(),
        'MBEDCRYPTO_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedcrypto$libSuffix').toFilePath(),
        // Also forces UA_FLOAT_LITTLE_ENDIAN=1: open62541's config.h leaves it 0 under clang
        // (macOS arm64), which selects the pack754 codec that corrupts subnormal floats.
        'CMAKE_PROJECT_INCLUDE': await _writeHardening(
          input.outputDirectoryShared,
          sanitizer ? '$name-asan' : name,
          hardening,
        ),
      },
      targets: ['install'],
    );

    // Manually add assets. Switch on OS.name (a String with primitive
    // equality) rather than on the OS constants directly: code_assets 2.x
    // overrides OS.== / OS.hashCode, which makes the OS values illegal as
    // constant switch patterns. Keying on the name works on both 1.x and 2.x.
    final libPath = switch (input.config.code.targetOS.name) {
      'linux' || 'android' => "install/lib/libopen62541.so",
      'macos' || 'ios' => "install/lib/libopen62541.dylib",
      'windows' => "install/bin/open62541.dll",
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
