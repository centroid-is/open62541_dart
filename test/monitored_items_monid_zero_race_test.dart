import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// Reproduces the monId==0 race that motivated identifying monitored items by
// their request-time context instead of the server-assigned monitoredItemId.
//
// open62541 registers a monitored item in its dispatch tree at REQUEST time
// (keyed by clientHandle) and invokes the data callback with mon->context set
// then, but mon->monitoredItemId stays 0 until the CreateMonitoredItemsResponse
// is processed. A server can put the initial DataChange notification on the wire
// before that response is processed (seen against Beckhoff at boot: the
// "Error converting data for: null ... Null check operator" flood). The old
// monId-keyed lookup throws on those early notifications and drops them; the
// request-order context always resolves them.
//
// The in-process open62541 test server answers create before it publishes, so
// the race cannot occur naturally. This test forces it with a byte-level TCP
// proxy that HOLDS the CreateMonitoredItemsResponse and lets the first data
// PublishResponse through first, rewriting SequenceNumbers so the secure channel
// stays contiguous (open62541 rejects a sequence gap). The client then processes
// an initial DataChange while monId is still 0.
//
// The client also reads the initial value directly, so both code paths
// eventually surface every value -- the observable difference is the dropped
// notification itself. This test therefore asserts on the client's own error
// log (captured via IOOverrides): the pre-fix code emits
// "Error converting data for: ..." for the monId==0 notification; the
// context-based code emits nothing. FAILS before the fix, PASSES after.

const int _createMonitoredItemsResponseId = 754; // FourByte ns0 id; PublishResponse is 829.

int _u32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
void _w32(Uint8List b, int o, int v) {
  b[o] = v & 0xff;
  b[o + 1] = (v >> 8) & 0xff;
  b[o + 2] = (v >> 16) & 0xff;
  b[o + 3] = (v >> 24) & 0xff;
}

// Holds the first CreateMonitoredItemsResponse for [holdWindow] while forwarding
// everything else, renumbering every MSG chunk's SequenceNumber contiguously so
// the reorder is invisible to the channel layer.
class _ServerToClient {
  _ServerToClient(this.from, this.to, {required this.holdWindow});
  final Socket from;
  final Socket to;
  final Duration holdWindow;

  final BytesBuilder _buf = BytesBuilder();
  int? _seq;
  Uint8List? _held;
  bool _reorderDone = false;
  Timer? _release;

  void run() {
    from.listen(_onData, onError: (_) => _teardown(), onDone: _teardown, cancelOnError: true);
  }

  void _teardown() {
    _release?.cancel();
    try {
      to.destroy();
    } catch (_) {}
  }

  void _onData(List<int> data) {
    _buf.add(data);
    final bytes = _buf.toBytes();
    var off = 0;
    while (bytes.length - off >= 8) {
      final size = _u32(bytes, off + 4);
      if (size < 8 || bytes.length - off < size) break; // wait for the whole chunk
      _handle(Uint8List.fromList(bytes.sublist(off, off + size)));
      off += size;
    }
    _buf.clear();
    _buf.add(bytes.sublist(off));
  }

  void _handle(Uint8List chunk) {
    final isMsg = chunk[0] == 0x4d && chunk[1] == 0x53 && chunk[2] == 0x47; // "MSG"
    if (!isMsg) {
      _send(chunk); // HEL/ACK/OPN/CLO: forward untouched (own seq domain)
      return;
    }
    _seq ??= _u32(chunk, 16); // seed from the first MSG SequenceNumber
    int? svc;
    if (chunk[3] == 0x46 /* 'F' */ && chunk.length >= 28 && chunk[24] == 0x01 && chunk[25] == 0x00) {
      svc = chunk[26] | (chunk[27] << 8);
    }
    if (!_reorderDone && svc == _createMonitoredItemsResponseId) {
      _held = chunk; // hold it back; forward later, after the data publish(es)
      _release = Timer(holdWindow, _releaseHeld);
      return;
    }
    _forwardMsg(chunk);
  }

  void _forwardMsg(Uint8List chunk) {
    final c = Uint8List.fromList(chunk);
    _w32(c, 16, _seq!); // renumber SequenceNumber contiguously
    _seq = _seq! + 1;
    _send(c);
  }

  void _releaseHeld() {
    final held = _held;
    _held = null;
    _reorderDone = true;
    if (held != null) _forwardMsg(held);
  }

  void _send(Uint8List c) {
    try {
      to.add(c);
    } catch (_) {
      _teardown();
    }
  }
}

class _ReorderProxy {
  _ReorderProxy._(this._listener, this._targetPort, this._holdWindow);
  final ServerSocket _listener;
  final int _targetPort;
  final Duration _holdWindow;
  final List<Socket> _sockets = [];

  int get port => _listener.port;

  static Future<_ReorderProxy> start(int targetPort, {required Duration holdWindow}) async {
    final l = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = _ReorderProxy._(l, targetPort, holdWindow);
    l.listen(p._onClient);
    return p;
  }

  Future<void> _onClient(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, _targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    _sockets.addAll([client, upstream]);
    client.done.catchError((_) => client);
    upstream.done.catchError((_) => upstream);
    client.listen(
      (d) {
        try {
          upstream.add(d);
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () {
        try {
          upstream.destroy();
        } catch (_) {}
      },
      cancelOnError: true,
    );
    _ServerToClient(upstream, client, holdWindow: _holdWindow).run();
  }

  Future<void> dispose() async {
    for (final s in _sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    await _listener.close();
  }
}

void main() {
  final serverPort = Random().nextInt(10000) + 4840;
  const nodeCount = 6;
  late Server server;
  late _ReorderProxy proxy;
  Client? client;
  bool running = false;

  setUp(() async {
    server = setupServer(serverPort);
    for (var i = 0; i < nodeCount; i++) {
      server.addVariableNode(
        NodeId.fromString(1, "race.int$i"),
        DynamicValue(value: 100 + i, typeId: NodeId.int32, name: "race.int$i"),
      );
    }
    proxy = await _ReorderProxy.start(serverPort, holdWindow: const Duration(seconds: 4));
  });

  tearDown(() async {
    running = false;
    if (client != null) await client!.delete();
    await proxy.dispose();
    server.shutdown();
    server.delete();
  });

  test('first emission arrives from the reordered notification, before the create-response is released', () async {
    final nodes = {for (var i = 0; i < nodeCount; i++) NodeId.fromString(1, "race.int$i"): 100 + i};
    final c = Client();
    client = c;
    running = true;
    () async {
      while (running && c.runIterate(const Duration(milliseconds: 10))) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();
    await c.connect("opc.tcp://127.0.0.1:${proxy.port}");
    final subscription = await c.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 10));
    final first = Completer<Map<NodeId, DynamicValue>>();
    final sw = Stopwatch()..start();
    final sub = c
        .monitoredItems(
          {
            for (final n in nodes.keys) n: [AttributeId.UA_ATTRIBUTEID_VALUE],
          },
          subscription,
          samplingInterval: const Duration(milliseconds: 10),
        )
        .listen((values) {
          if (!first.isCompleted) first.complete(values);
        });
    // The context-based code delivers this value from the reordered notification
    // (~100 ms). The pre-fix monId-keyed code drops it at monId==0 (throwing
    // "Error converting data for: null") and only recovers it via the
    // create-response backfill, which cannot run until the held
    // CreateMonitoredItemsResponse is released at 4 s. A 2.5 s bound cleanly
    // separates the two: it passes on the fix and times out on the old code.
    late final Map<NodeId, DynamicValue> values;
    try {
      values = await first.future.timeout(const Duration(milliseconds: 2500));
    } on TimeoutException {
      fail(
        'No monitored value arrived within 2.5s while the '
        'CreateMonitoredItemsResponse was held: the initial notification was '
        'processed with monId==0 and dropped, instead of being resolved by '
        'request-order context (elapsed ${sw.elapsedMilliseconds} ms).',
      );
    }
    for (final e in nodes.entries) {
      expect(
        values[e.key]?.value,
        e.value,
        reason: 'value for ${e.key} landed on the wrong item (context<->index off-by-one)',
      );
    }
    await sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
