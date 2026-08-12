// Toxiproxy controller for the integration suite.
//
// Wraps the `toxiproxy-server` binary (fetched by setup_local.sh into
// test/integration/.bin/) and its HTTP control API so tests can put a fault
// injecting TCP proxy in front of any OPC UA server. opc.tcp is plain TCP, so
// the client simply connects to the proxy's listen port instead of the server.
//
// Typical use:
//   final tp = await Toxiproxy.start();
//   final proxy = await tp.createProxy('srv', upstreamHost: '127.0.0.1', upstreamPort: 4841);
//   // client connects to opc.tcp://127.0.0.1:${proxy.listenPort}
//   await proxy.addLatency(latency: Duration(milliseconds: 300), jitter: Duration(milliseconds: 50));
//   await proxy.reset();                    // remove all toxics
//   await proxy.disable();                  // hard-drop: refuse/kill connections
//   await tp.stop();

import 'dart:convert';
import 'dart:io';

import 'paths.dart';

class Toxiproxy {
  Toxiproxy._(this._process, this.apiPort, this._client);

  final Process _process;
  final int apiPort;
  final HttpClient _client;
  final List<String> _proxyNames = [];

  static Future<Toxiproxy> start({int? apiPort}) async {
    final bin = integrationBin('toxiproxy-server');
    if (!File(bin).existsSync()) {
      throw StateError('toxiproxy-server not found at $bin. Run test/integration/setup_local.sh');
    }
    final port = apiPort ?? await _freePort();
    final process = await Process.start(bin, ['-host', '127.0.0.1', '-port', '$port']);
    // Surface toxiproxy logs to stderr for debugging, prefixed.
    process.stderr.transform(utf8.decoder).listen((l) => stderr.write('[toxiproxy] $l'));
    process.stdout.transform(utf8.decoder).drain<void>();

    final client = HttpClient();
    final tp = Toxiproxy._(process, port, client);
    await tp._waitReady();
    return tp;
  }

  Future<void> _waitReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await _get('/version');
        if (r.statusCode == 200) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('toxiproxy API did not come up on port $apiPort');
  }

  /// Creates a proxy: listens on 127.0.0.1:[listenPort] (auto if null) and
  /// forwards to [upstreamHost]:[upstreamPort].
  Future<ToxiProxyHandle> createProxy({
    required String upstreamHost,
    required int upstreamPort,
    int? listenPort,
    String? name,
  }) async {
    final port = listenPort ?? await _freePort();
    final proxyName = name ?? 'p_${port}_$upstreamPort';
    final body = {
      'name': proxyName,
      'listen': '127.0.0.1:$port',
      'upstream': '$upstreamHost:$upstreamPort',
      'enabled': true,
    };
    final r = await _post('/proxies', body);
    if (r.statusCode != 201 && r.statusCode != 200) {
      throw StateError('createProxy failed (${r.statusCode}): ${r.body}');
    }
    _proxyNames.add(proxyName);
    return ToxiProxyHandle._(this, proxyName, port);
  }

  Future<void> stop() async {
    for (final n in List<String>.from(_proxyNames)) {
      try {
        await _delete('/proxies/$n');
      } catch (_) {}
    }
    _client.close(force: true);
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }

  // --- HTTP helpers ----------------------------------------------------------
  Future<_Resp> _get(String path) => _send('GET', path, null);
  Future<_Resp> _post(String path, Object body) => _send('POST', path, body);
  Future<_Resp> _delete(String path) => _send('DELETE', path, null);

  Future<_Resp> _send(String method, String path, Object? body) async {
    final req = await _client.openUrl(method, Uri.parse('http://127.0.0.1:$apiPort$path'));
    if (body != null) {
      final bytes = utf8.encode(json.encode(body));
      req.headers.contentType = ContentType.json;
      req.add(bytes);
    }
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return _Resp(resp.statusCode, text);
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }
}

/// A single proxy in front of one upstream server.
class ToxiProxyHandle {
  ToxiProxyHandle._(this._tp, this.name, this.listenPort);

  final Toxiproxy _tp;
  final String name;
  final int listenPort;
  int _toxicSeq = 0;

  String get url => 'opc.tcp://127.0.0.1:$listenPort';

  /// Adds latency (+/- jitter) on [stream] ('downstream' | 'upstream').
  Future<String> addLatency({
    required Duration latency,
    Duration jitter = Duration.zero,
    String stream = 'downstream',
    double toxicity = 1.0,
  }) => _addToxic('latency', stream, toxicity, {'latency': latency.inMilliseconds, 'jitter': jitter.inMilliseconds});

  /// Caps throughput to [kbps] kilobytes/second.
  Future<String> addBandwidth({required int kbps, String stream = 'downstream', double toxicity = 1.0}) =>
      _addToxic('bandwidth', stream, toxicity, {'rate': kbps});

  /// Stops data and closes the connection after [after]. If [after] is zero the
  /// connection stays open but all data is dropped (a hang).
  Future<String> addTimeout({Duration after = Duration.zero, String stream = 'downstream', double toxicity = 1.0}) =>
      _addToxic('timeout', stream, toxicity, {'timeout': after.inMilliseconds});

  /// Simulates a TCP RST after [after].
  Future<String> addResetPeer({Duration after = Duration.zero, String stream = 'downstream', double toxicity = 1.0}) =>
      _addToxic('reset_peer', stream, toxicity, {'timeout': after.inMilliseconds});

  /// Slices packets into small chunks with [delayMicros] between them.
  Future<String> addSlicer({
    required int averageSize,
    int delayMicros = 0,
    int sizeVariation = 0,
    String stream = 'downstream',
    double toxicity = 1.0,
  }) => _addToxic('slicer', stream, toxicity, {
    'average_size': averageSize,
    'delay': delayMicros,
    'size_variation': sizeVariation,
  });

  Future<String> _addToxic(String type, String stream, double toxicity, Map<String, Object> attrs) async {
    final toxicName = '${type}_${stream}_${_toxicSeq++}';
    final r = await _tp._post('/proxies/$name/toxics', {
      'name': toxicName,
      'type': type,
      'stream': stream,
      'toxicity': toxicity,
      'attributes': attrs,
    });
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw StateError('addToxic $type failed (${r.statusCode}): ${r.body}');
    }
    return toxicName;
  }

  Future<void> removeToxic(String toxicName) => _tp._delete('/proxies/$name/toxics/$toxicName');

  /// Removes every toxic on this proxy (restores a clean pass-through).
  Future<void> reset() async {
    final r = await _tp._get('/proxies/$name/toxics');
    if (r.statusCode == 200) {
      final toxics = (json.decode(r.body) as List).cast<Map<String, dynamic>>();
      for (final t in toxics) {
        await removeToxic(t['name'] as String);
      }
    }
  }

  /// Disables the proxy: existing connections are dropped and new ones refused.
  Future<void> disable() => _setEnabled(false);

  /// Re-enables the proxy.
  Future<void> enable() => _setEnabled(true);

  Future<void> _setEnabled(bool enabled) async {
    final r = await _tp._post('/proxies/$name', {'enabled': enabled});
    if (r.statusCode != 200) {
      throw StateError('set enabled=$enabled failed (${r.statusCode}): ${r.body}');
    }
  }
}

class _Resp {
  _Resp(this.statusCode, this.body);
  final int statusCode;
  final String body;
}
