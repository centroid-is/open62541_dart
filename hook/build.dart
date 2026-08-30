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
};

/// mbedTLS release version and the SHA-256 of its `.tar.bz2` release asset.
const String _mbedtlsVersion = '3.6.5';
const String _mbedtlsSha256 = '4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8';

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

  // Return early if already downloaded and renamed
  final srcDir = Directory.fromUri(extractDir.uri.resolve('src/'));
  if (await srcDir.exists()) {
    return srcDir.uri;
  }

  final bytes = await _downloadVerified(url, expectedSha256: _mbedtlsSha256, what: 'mbedTLS $_mbedtlsVersion');

  final decompressed = BZip2Decoder().decodeBytes(bytes);
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

  // Skip if already built
  final includeCheck = File.fromUri(installPrefix.resolve('include/mbedtls/ssl.h'));
  if (await includeCheck.exists()) {
    logger.info('mbedTLS already built, skipping');
    return installPrefix;
  }

  final sourceDir = await _downloadMbedTLS(input.outputDirectoryShared);

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
    },
    targets: ['install'],
  );

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
  if (content.contains('Clean up all client-side subscriptions') &&
      content.contains('Immediately null out the notification callbacks')) return;

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

  // Null out monitored item callbacks immediately when a delete request is
  // sent.  This prevents use-after-free crashes when a Publish response
  // arrives before the DeleteMonitoredItems response is processed.
  // processDataChangeNotification() already guards with a NULL check.
  const deleteOriginal =
      '''    /* Send the request */
    CustomCallback *cc = (CustomCallback *)UA_calloc(1, sizeof(CustomCallback));
    if(!cc)
        return UA_STATUSCODE_BADOUTOFMEMORY;''';

  const deletePatched =
      '''    /* Immediately null out the notification callbacks for the monitored items
     * being deleted. This prevents use-after-free when a Publish response
     * arrives before the DeleteMonitoredItems response is processed.
     * processDataChangeNotification() already checks for NULL. */
    {
        UA_Client_Subscription *sub =
            findSubscriptionById(client, request.subscriptionId);
        if(sub) {
            for(size_t i = 0; i < request.monitoredItemIdsSize; i++) {
                UA_Client_MonitoredItem *mon;
                UA_Client_MonitoredItem dummy;
                dummy.monitoredItemId = request.monitoredItemIds[i];
                mon = ZIP_FIND(MonitorItemsTree, &sub->monitoredItems, &dummy);
                if(mon) {
                    mon->handler.dataChangeCallback = NULL;
                    mon->handler.eventCallback = NULL;
                }
            }
        }
    }

    /* Send the request */
    CustomCallback *cc = (CustomCallback *)UA_calloc(1, sizeof(CustomCallback));
    if(!cc)
        return UA_STATUSCODE_BADOUTOFMEMORY;''';

  if (!content.contains(deleteOriginal)) {
    throw Exception('Cannot apply delete-nullify patch: expected code not found');
  }
  content = content.replaceFirst(deleteOriginal, deletePatched);

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
  final version = "v1.5.7";
  await build(args, (input, output) async {
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

    final sanitizer = Platform.environment['ENABLE_SANITIZER'] == '1';

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
        'MBEDTLS_INCLUDE_DIRS': mbedtlsInstall.resolve('include/').toFilePath(),
        'MBEDTLS_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedtls$libSuffix').toFilePath(),
        'MBEDX509_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedx509$libSuffix').toFilePath(),
        'MBEDCRYPTO_LIBRARY': mbedtlsLibDir.resolve('${libPrefix}mbedcrypto$libSuffix').toFilePath(),
        // Force the fast (memcpy/"overlayable") IEEE 754 encoding path.
        //
        // open62541's config.h only sets UA_FLOAT_LITTLE_ENDIAN=1 when the
        // compiler defines __FLOAT_WORD_ORDER__ (a GCC-only macro) or when the
        // target is x86. clang (e.g. on macOS arm64) defines neither, so
        // UA_FLOAT_LITTLE_ENDIAN resolves to 0, UA_BINARY_OVERLAYABLE_FLOAT
        // becomes 0, and the library falls back to the slow generic pack754/
        // unpack754 codec in ua_types_encoding_binary.c. That generic codec
        // normalizes the mantissa to "1.x" and therefore silently corrupts
        // subnormal (denormalized) Float/Double values on the wire. Every
        // target we build for uses little-endian IEEE 754 floats, so forcing
        // this on is both correct and required for subnormals to round-trip.
        'CMAKE_C_FLAGS': sanitizer
            ? '-DUA_FLOAT_LITTLE_ENDIAN=1 -fsanitize=address,undefined -fno-omit-frame-pointer'
            : '-DUA_FLOAT_LITTLE_ENDIAN=1',
        if (sanitizer) 'CMAKE_SHARED_LINKER_FLAGS': '-fsanitize=address,undefined',
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
