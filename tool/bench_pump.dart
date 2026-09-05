// Fan-in benchmark: N OPC UA clients subscribed to M nodes each, all values
// merged on ONE isolate.
//
// Two client modes:
//   isolate — the status quo. Every client is a `ClientIsolate`, so the pump
//             (`runIterate`, a BLOCKING call) lives on a worker isolate and
//             every value crosses an isolate boundary before the merging
//             isolate sees it.
//   local   — every client is a plain `Client` on the merging isolate, pumped
//             with a NON-BLOCKING `runIterate(Duration.zero)`. No boundary, no
//             copy; values are constructed on the owning heap.
//
// Throughput alone does not separate the two — a loopback server saturates
// first. What separates them is (a) end-to-end latency, (b) CPU burned per
// delivered value, and (c) how starved the merging isolate's event loop is,
// which is what "one isolate congesting over receiving data from other
// isolates" actually looks like.
//
// The server runs as a SEPARATE PROCESS so the client process's CPU time is
// attributable to the client side only.
//
// Usage:
//   dart run tool/bench_pump.dart --serve --port=4855 --nodes=200
//   dart run tool/bench_pump.dart --mode=local --port=4855 --clients=8 --nodes=200 --seconds=20

import 'dart:async';
import 'dart:io';

import 'package:open62541/open62541.dart';

/// Node carrying the server's wall clock in microseconds, used for end-to-end
/// latency. Kept out of the bulk load so its own queue never backs up.
final tsNode = NodeId.fromString(1, 'ts');

int _arg(List<String> a, String n, int f) {
  final h = a.firstWhere((x) => x.startsWith('--$n='), orElse: () => '');
  return h.isEmpty ? f : int.parse(h.split('=')[1]);
}

String _str(List<String> a, String n, String f) {
  final h = a.firstWhere((x) => x.startsWith('--$n='), orElse: () => '');
  return h.isEmpty ? f : h.split('=')[1];
}

Future<void> _serve(int port, int nodes) async {
  final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  server.start();

  final ids = <NodeId>[];
  for (var i = 0; i < nodes; i++) {
    final id = NodeId.fromString(1, 'n$i');
    ids.add(id);
    server.addVariableNode(id, DynamicValue(value: 0, typeId: NodeId.int32, name: 'n$i'));
  }
  server.addVariableNode(tsNode, DynamicValue(value: 0.0, typeId: NodeId.double, name: 'ts'));
  stdout.writeln('ready');

  var tick = 0;
  var lastTs = DateTime.now();
  // Non-blocking server pump interleaved with the write burst.
  while (server.runIterate()) {
    tick++;
    for (final id in ids) {
      server.write(id, DynamicValue(value: tick, typeId: NodeId.int32));
    }
    final now = DateTime.now();
    if (now.difference(lastTs).inMilliseconds >= 20) {
      lastTs = now;
      server.write(tsNode, DynamicValue(value: now.microsecondsSinceEpoch.toDouble(), typeId: NodeId.double));
    }
    await Future.delayed(const Duration(milliseconds: 1));
  }
}

/// Process CPU time in microseconds, from `ps` (centisecond resolution).
Future<int> _cpuMicros() async {
  final r = await Process.run('ps', ['-o', 'time=', '-p', '$pid']);
  final t = (r.stdout as String).trim(); // [DD-]HH:MM:SS.ss or MM:SS.ss
  final parts = t.split(':');
  var secs = 0.0;
  for (final p in parts) {
    secs = secs * 60 + double.parse(p);
  }
  return (secs * 1e6).round();
}

List<int> _pcts(List<int> xs) {
  if (xs.isEmpty) return [0, 0, 0, 0];
  xs.sort();
  int at(double p) => xs[(xs.length * p).clamp(0, xs.length - 1).toInt()];
  return [at(0.5), at(0.9), at(0.99), xs.last];
}

Future<void> main(List<String> args) async {
  final port = _arg(args, 'port', 4855);
  final nNodes = _arg(args, 'nodes', 200);

  if (args.contains('--serve')) {
    await _serve(port, nNodes);
    return;
  }

  final mode = _str(args, 'mode', 'local');
  final nClients = _arg(args, 'clients', 8);
  final seconds = _arg(args, 'seconds', 20);
  final pumpMs = _arg(args, 'pump-ms', 1);
  final url = 'opc.tcp://localhost:$port';
  final publish = Duration(milliseconds: _arg(args, 'publish-ms', 50));
  const sampling = Duration.zero;

  const beat = Duration(milliseconds: 5);
  final lateness = <int>[];
  final latency = <int>[];
  var last = DateTime.now();
  final metronome = Timer.periodic(beat, (_) {
    final now = DateTime.now();
    lateness.add(now.difference(last).inMicroseconds - beat.inMicroseconds);
    last = now;
  });

  var received = 0;
  final subs = <StreamSubscription<DynamicValue>>[];
  final locals = <Client>[];
  final remotes = <ClientIsolate>[];
  var pumping = true;

  final nodeIds = [for (var i = 0; i < nNodes; i++) NodeId.fromString(1, 'n$i')];

  void onTs(DynamicValue v) {
    final sentUs = (v.asDouble).round();
    if (sentUs <= 0) return;
    latency.add(DateTime.now().microsecondsSinceEpoch - sentUs);
  }

  if (mode == 'local') {
    for (var c = 0; c < nClients; c++) {
      locals.add(Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL));
    }
    // ONE non-blocking pump loop drives every client on this isolate.
    () async {
      final tick = Duration(milliseconds: pumpMs);
      while (pumping) {
        for (final c in locals) {
          c.runIterate(Duration.zero);
        }
        await Future.delayed(tick);
      }
    }();
    for (final c in locals) {
      await c.connect(url);
      final sub = await c.subscriptionCreate(requestedPublishingInterval: publish);
      for (final id in nodeIds) {
        subs.add(
          c.monitor(id, sub, samplingInterval: sampling, queueSize: 10).listen((_) => received++, onError: (_) {}),
        );
      }
      if (c == locals.first) {
        subs.add(c.monitor(tsNode, sub, samplingInterval: sampling).listen(onTs, onError: (_) {}));
      }
    }
  } else {
    for (var c = 0; c < nClients; c++) {
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      remotes.add(client);
      await client.connect(url);
      unawaited(client.runIterate(duration: Duration(milliseconds: pumpMs == 1 ? 10 : pumpMs)));
      final sub = await client.subscriptionCreate(requestedPublishingInterval: publish);
      for (final id in nodeIds) {
        subs.add(
          client.monitor(id, sub, samplingInterval: sampling, queueSize: 10).listen((_) => received++, onError: (_) {}),
        );
      }
      if (client == remotes.first) {
        subs.add(client.monitor(tsNode, sub, samplingInterval: sampling).listen(onTs, onError: (_) {}));
      }
    }
  }

  // Discard the setup transient, then measure.
  await Future.delayed(const Duration(seconds: 3));
  lateness.clear();
  latency.clear();
  received = 0;
  final cpu0 = await _cpuMicros();
  final t0 = DateTime.now();
  await Future.delayed(Duration(seconds: seconds));
  final elapsed = DateTime.now().difference(t0);
  final cpuUs = await _cpuMicros() - cpu0;

  metronome.cancel();
  pumping = false;
  for (final s in subs) {
    unawaited(s.cancel().catchError((_) {}));
  }

  final lat = _pcts(latency);
  final late = _pcts(lateness);
  final rate = received / (elapsed.inMilliseconds / 1000);
  print('mode=$mode clients=$nClients nodes=$nNodes pump=${pumpMs}ms publish=${publish.inMilliseconds}ms');
  print('  values      : $received  (${rate.toStringAsFixed(0)}/s)');
  print(
    '  cpu         : ${(cpuUs / 1e6).toStringAsFixed(2)}s  '
    '(${(cpuUs / elapsed.inMicroseconds * 100).toStringAsFixed(0)}% of one core, '
    '${(cpuUs / (received == 0 ? 1 : received)).toStringAsFixed(2)} us/value)',
  );
  print('  latency  us : p50=${lat[0]} p90=${lat[1]} p99=${lat[2]} max=${lat[3]} (n=${latency.length})');
  print('  loop lag us : p50=${late[0]} p90=${late[1]} p99=${late[2]} max=${late[3]} (n=${lateness.length})');

  for (final c in locals) {
    c.delete();
  }
  for (final c in remotes) {
    unawaited(c.delete().catchError((_) {}));
  }
  await Future.delayed(const Duration(milliseconds: 300));
  exit(0);
}
