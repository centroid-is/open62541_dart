// Resolves paths to the local-only integration dependencies.
//
// `dart test` runs with the current directory at the package root, so the
// integration tree lives at <cwd>/test/integration. We also walk upward as a
// fallback so tests work when invoked from a subdirectory.

import 'dart:io';

String integrationDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/test/integration');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Last resort: assume cwd is the package root.
  return '${Directory.current.path}/test/integration';
}

String integrationBin(String name) => '${integrationDir()}/.bin/$name';
String venvPython() => '${integrationDir()}/.venv/bin/python';
String serverScript(String name) => '${integrationDir()}/servers/$name';

/// True when the Python venv (asyncua) is available.
bool asyncuaAvailable() => File(venvPython()).existsSync();

/// True when node-opcua has been installed.
bool nodeOpcuaAvailable() =>
    Directory('${integrationDir()}/servers/node_modules/node-opcua').existsSync() && _which('node') != null;

/// True when the toxiproxy binary is present.
bool toxiproxyAvailable() => File(integrationBin('toxiproxy-server')).existsSync();

String? _which(String exe) {
  final sep = Platform.isWindows ? ';' : ':';
  for (final p in (Platform.environment['PATH'] ?? '').split(sep)) {
    if (p.isEmpty) continue;
    final f = File('$p/$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}
