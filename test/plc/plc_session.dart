// Session-frugal access to a PLC (real or emulated).
//
// Small controllers exhaust their OPC UA session table quickly (the M240/M241
// caps at ~4). So the whole suite shares ONE session per PLC: a test file opens
// it in setUpAll and disposes it in tearDownAll. A process-wide budget guard
// makes an accidental over-open fail loudly instead of silently exhausting the
// controller.
//
// In `emulator` mode a single asyncua emulator per target is shared by every
// client in the run (so CurrentSessionCount is meaningful); call
// PlcSession.shutdownEmulators() once at the very end.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:open62541/open62541.dart';
import '../integration/harness/net.dart';
import '../integration/harness/paths.dart';
import 'plc_browse.dart';
import 'plc_config.dart';

class PlcSession {
  PlcSession._(this.config, this.client, this._stopPump);

  final PlcConfig config;
  final ClientApi client;
  final void Function() _stopPump;
  final Map<String, NodeId> _byName = {};

  /// Process-wide count of open sessions per target, to enforce the budget.
  static final Map<PlcTarget, int> _open = {};

  /// Currently-open session count for [target] (for tests/diagnostics).
  static int debugOpenCount(PlcTarget target) => _open[target] ?? 0;

  /// Shared emulator per target (emulator mode only).
  static final Map<PlcTarget, ({Process proc, String url})> _emulators = {};

  static Future<PlcSession> open(PlcConfig config, {Duration connectTimeout = const Duration(seconds: 20)}) async {
    final current = _open[config.target] ?? 0;
    if (current + 1 > config.maxSessions) {
      throw StateError(
        'Session budget exceeded for ${config.name}: '
        '$current already open, cap ${config.maxSessions}. '
        'PLC tests must share one session (setUpAll/tearDownAll).',
      );
    }

    final url = config.useEmulator ? await _sharedEmulatorUrl(config) : config.url;

    final client = Client(
      username: config.username,
      password: config.password,
      // Lab controllers commonly use username/password over an unencrypted
      // channel; open62541 needs this to send the password there.
      allowUnencryptedPassword: true,
      // SHORT timeouts so an abandoned session/channel is reaped by the PLC.
      requestedSessionTimeout: config.sessionTimeout,
      secureChannelLifeTime: config.secureChannelLifetime,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
    );
    var running = true;
    unawaited(() async {
      while (running && client.runIterate(const Duration(milliseconds: 10))) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }());

    try {
      await client.connect(url).timeout(connectTimeout);
    } catch (e) {
      running = false;
      await client.delete();
      rethrow;
    }

    _open[config.target] = current + 1;
    return PlcSession._(config, client, () => running = false);
  }

  Future<void> dispose() async {
    _stopPump();
    await client.delete(); // clean CloseSession -> frees the controller slot
    _open[config.target] = (_open[config.target] ?? 1) - 1;
  }

  /// Resolves a fixture variable by BrowseName (Objects subtree, bounded),
  /// caching the result. Vendor namespaces/paths differ, so tests never
  /// hard-code NodeIds.
  Future<NodeId> node(String browseName) async {
    final cached = _byName[browseName];
    if (cached != null) return cached;
    final found = await findByBrowseName(client, browseName);
    if (found == null) {
      throw StateError('BrowseName "$browseName" not found on ${config.name}');
    }
    _byName[browseName] = found;
    return found;
  }

  /// Reads Server/ServerDiagnostics/ServerDiagnosticsSummary/CurrentSessionCount
  /// (ns=0;i=2277) so a test can prove sessions are actually freed on the
  /// controller. Returns null if the server does not expose diagnostics.
  Future<int?> currentSessionCount() async {
    try {
      final v = await client.read(NodeId.fromNumeric(0, 2277)).timeout(const Duration(seconds: 5));
      return v.asInt;
    } catch (_) {
      return null;
    }
  }

  /// The upstream host:port to reach this target directly (starting the shared
  /// emulator if needed). Used to put a toxiproxy in front of it for the
  /// reconnection tests.
  static Future<({String host, int port})> upstream(PlcConfig config) async {
    final url = config.useEmulator ? await _sharedEmulatorUrl(config) : config.url;
    final u = Uri.parse(url);
    return (host: u.host, port: u.port);
  }

  // --- Shared emulator lifecycle (emulator mode) ----------------------------
  static Future<String> _sharedEmulatorUrl(PlcConfig config) async {
    final existing = _emulators[config.target];
    if (existing != null) return existing.url;
    if (!asyncuaAvailable()) {
      throw StateError('emulator requested but asyncua venv missing; run test/integration/setup_local.sh');
    }
    final port = await freePort();
    final url = 'opc.tcp://127.0.0.1:$port/';
    final script = '${integrationDir()}/../plc/emulators/plc_emulator.py';
    final proc = await Process.start(venvPython(), [
      script,
      '--port',
      '$port',
      '--profile',
      config.profile,
      '--user',
      config.username,
      '--password',
      config.password,
    ]);
    final ready = Completer<void>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (!ready.isCompleted && l.startsWith('READY')) ready.complete();
    });
    proc.stderr.transform(utf8.decoder).listen((l) => stderr.write('[plc-emu:${config.profile}] $l'));
    unawaited(
      proc.exitCode.then((c) {
        if (!ready.isCompleted) ready.completeError(StateError('emulator exited ($c) before ready'));
      }),
    );
    await ready.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw TimeoutException('plc emulator ${config.profile} not ready');
      },
    );
    _emulators[config.target] = (proc: proc, url: url);
    return url;
  }

  /// Kills every shared emulator. Call once in the final tearDownAll.
  static Future<void> shutdownEmulators() async {
    for (final e in _emulators.values) {
      e.proc.kill(ProcessSignal.sigkill);
      await e.proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
    _emulators.clear();
  }
}
