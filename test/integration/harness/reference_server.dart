// Launches external reference OPC UA servers as child processes and manages
// their lifecycle (start / wait-ready / kill / restart). Used both for
// cross-implementation interop tests and for resilience tests that crash and
// restart a server underneath a live client.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// A reference server backed by a child process that announces readiness by
/// printing a line matching [readyPattern] to stdout.
class ReferenceServer {
  ReferenceServer._(this._executable, this._args, this.port, this._readyPattern, this.label);

  final String _executable;
  final List<String> _args;
  final int port;
  final RegExp _readyPattern;
  final String label;

  Process? _process;
  String? _endpoint;

  String get endpoint => _endpoint ?? 'opc.tcp://127.0.0.1:$port';

  /// asyncua fish-farm server. Requires the Python venv (see setup_local.sh).
  static ReferenceServer asyncuaFishFarm({required int port, int tanks = 3, bool live = true, int updateMs = 250}) {
    final args = [
      serverScript('fish_farm_asyncua.py'),
      '--port',
      '$port',
      '--tanks',
      '$tanks',
      '--host',
      '127.0.0.1',
      '--update-ms',
      '$updateMs',
      if (!live) '--no-live',
    ];
    return ReferenceServer._(venvPython(), args, port, RegExp(r'^READY '), 'asyncua');
  }

  /// node-opcua fish-farm server. Requires node + node-opcua (see setup_local.sh).
  static ReferenceServer nodeOpcuaFishFarm({required int port, int tanks = 3, bool live = true, int updateMs = 250}) {
    final args = [
      serverScript('fish_farm_node.js'),
      '--port',
      '$port',
      '--tanks',
      '$tanks',
      '--update-ms',
      '$updateMs',
      if (!live) '--no-live',
    ];
    return ReferenceServer._('node', args, port, RegExp(r'^READY '), 'node-opcua');
  }

  /// Starts the process and resolves once it prints its ready marker.
  Future<void> start({Duration timeout = const Duration(seconds: 30)}) async {
    if (_process != null) throw StateError('$label already started');
    final proc = await Process.start(_executable, _args);
    _process = proc;

    final ready = Completer<void>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!ready.isCompleted && _readyPattern.hasMatch(line)) {
        final m = RegExp(r'READY\s+(\S+)').firstMatch(line);
        if (m != null) _endpoint = m.group(1);
        ready.complete();
      }
    });
    proc.stderr.transform(utf8.decoder).listen((l) => stderr.write('[$label:$port] $l'));

    // If the process dies before READY, fail fast rather than hang.
    unawaited(
      proc.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('$label exited (code $code) before ready'));
        }
      }),
    );

    await ready.future.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw TimeoutException('$label did not become ready within $timeout');
      },
    );
  }

  /// Hard-kills the server (SIGKILL by default to simulate a crash).
  Future<void> stop({ProcessSignal signal = ProcessSignal.sigkill}) async {
    final proc = _process;
    if (proc == null) return;
    proc.kill(signal);
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    _process = null;
    // Give the OS a moment to release the listen port before any restart.
    await _waitPortFree(port, const Duration(seconds: 5));
  }

  /// Crash-and-restart on the same port (the core resilience primitive).
  Future<void> restart({Duration downtime = Duration.zero}) async {
    await stop();
    if (downtime > Duration.zero) await Future<void>.delayed(downtime);
    _process = null;
    await start();
  }

  bool get isRunning => _process != null;

  static Future<void> _waitPortFree(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await s.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}
