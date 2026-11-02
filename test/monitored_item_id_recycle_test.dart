// A deleted MonitoredItem's monitoredItemId may be handed to a new item by the
// server, and the new item's CreateMonitoredItemsResponse may be processed
// before the old item's DeleteMonitoredItemsResponse. open62541 used to drop
// local items by monitoredItemId when the delete response arrived, so it then
// dropped the NEW item: the server kept publishing to it and every
// notification was discarded ("Could not process a notification with
// clienthandle N"), the value frozen.
//
// The in-process server never recycles ids and answers in order, so a proxy
// stages it: it holds the delete response until the next create response has
// passed, gives that create result the deleted item's id, and renumbers the
// sequence numbers it reordered.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show clientTypes, setupClientOfType;

final sampledNodeId = NodeId.fromString(1, 'the.sampled');

class _RecyclingProxy {
  _RecyclingProxy._(this._listener, this._upstreamPort);

  final ServerSocket _listener;
  final int _upstreamPort;
  final _sockets = <Socket>[];

  /// The monitoredItemId of every single-result CreateMonitoredItemsResponse.
  final createdIds = <int>[];

  /// When set, the next DeleteMonitoredItemsResponse is held back until the
  /// next CreateMonitoredItemsResponse, whose id becomes [recycleId].
  int? recycleId;

  /// Completes once a delete response was delivered after a create response.
  final reordered = Completer<void>();

  int get port => _listener.port;

  static Future<_RecyclingProxy> start(int upstreamPort) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _RecyclingProxy._(listener, upstreamPort);
    listener.listen(proxy._accept);
    return proxy;
  }

  Future<void> close() async {
    await _listener.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  static const _createResponse = 754;
  static const _deleteResponse = 784;

  static int? _responseType(Uint8List m) {
    if (m.length < 28 || m[0] != 0x4D || m[1] != 0x53 || m[2] != 0x47 || m[3] != 0x46) return null;
    if (m[24] != 0x01 || m[25] != 0x00) return null;
    return ByteData.sublistView(m).getUint16(26, Endian.little);
  }

  /// Offset of the monitoredItemId of the one result of a Good
  /// CreateMonitoredItemsResponse, or null.
  static int? _createdIdOffset(Uint8List m) {
    if (_responseType(m) != _createResponse || m.length < 64) return null;
    final view = ByteData.sublistView(m);
    // ResponseHeader: timestamp, requestHandle, serviceResult, empty
    // diagnostics, empty stringTable, null additionalHeader (24 bytes).
    if (view.getUint32(40, Endian.little) != 0 || m[44] != 0 || view.getInt32(45, Endian.little) > 0) return null;
    if (view.getInt32(52, Endian.little) != 1 || view.getUint32(56, Endian.little) != 0) return null;
    return 60;
  }

  Future<void> _accept(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, _upstreamPort);
    } catch (_) {
      client.destroy();
      return;
    }
    _sockets
      ..add(client)
      ..add(upstream);
    for (final socket in [client, upstream]) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      socket.done.ignore();
    }
    client.listen(upstream.add, onDone: upstream.destroy, onError: (_) => upstream.destroy());

    List<Uint8List>? held;
    Timer? fallback;
    void release(List<Uint8List> order) {
      // The client checks that sequence numbers increase by one.
      final seqs = [for (final m in order) ByteData.sublistView(m).getUint32(16, Endian.little)]..sort();
      for (var i = 0; i < order.length; i++) {
        ByteData.sublistView(order[i]).setUint32(16, seqs[i], Endian.little);
        client.add(order[i]);
      }
    }

    var pending = Uint8List(0);
    upstream.listen(
      (data) {
        pending = Uint8List.fromList([...pending, ...data]);
        while (pending.length >= 8) {
          final size = ByteData.sublistView(pending).getUint32(4, Endian.little);
          if (size < 8 || pending.length < size) break;
          final message = pending.sublist(0, size);
          pending = pending.sublist(size);

          final idOffset = _createdIdOffset(message);
          if (idOffset != null) {
            final view = ByteData.sublistView(message);
            if (held != null) view.setUint32(idOffset, recycleId!, Endian.little);
            createdIds.add(view.getUint32(idOffset, Endian.little));
          }
          if (held != null) {
            if (idOffset != null) {
              fallback!.cancel();
              final rest = held!;
              held = null;
              recycleId = null;
              release([message, ...rest]);
              if (!reordered.isCompleted) reordered.complete();
            } else {
              held!.add(message);
            }
          } else if (recycleId != null && _responseType(message) == _deleteResponse) {
            held = [message];
            fallback = Timer(const Duration(seconds: 5), () {
              final rest = held!;
              held = null;
              release(rest);
            });
          } else {
            client.add(message);
          }
        }
      },
      onDone: client.destroy,
      onError: (_) => client.destroy(),
    );
  }
}

void main() {
  for (final clientType in clientTypes) {
    group(clientType, () {
      late Server server;
      late Timer serverTimer;
      late _RecyclingProxy proxy;
      late ClientApi api;
      var reads = 0;

      setUp(() async {
        server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
        server.start();
        server.addDataSourceVariableNode(
          sampledNodeId,
          browseName: 'the.sampled',
          typeId: NodeId.int32,
          onRead: () => DynamicValue(value: ++reads, typeId: NodeId.int32),
        );
        serverTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => server.runIterate());
        proxy = await _RecyclingProxy.start(server.port);
        api = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
      });

      tearDown(() async {
        await api.delete();
        await proxy.close();
        serverTimer.cancel();
        server.shutdown();
        server.delete();
      });

      test('a new item that inherits a deleted item\'s id keeps its notifications', () async {
        final subId = await api.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
        Stream<Map<NodeId, DynamicValue>> watch() => api.monitoredItems(
          {
            sampledNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          },
          subId,
          samplingInterval: const Duration(milliseconds: 20),
        );

        final firstA = Completer<void>();
        final a = watch().listen((_) {
          if (!firstA.isCompleted) firstA.complete();
        });
        await firstA.future.timeout(const Duration(seconds: 10));
        expect(proxy.createdIds, hasLength(1));

        proxy.recycleId = proxy.createdIds.single;
        final aCancelled = a.cancel();
        var bValues = 0;
        final b = watch().listen((_) => bValues++);
        await proxy.reordered.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('the proxy never delivered the delete response after the create response'),
        );
        await aCancelled.timeout(const Duration(seconds: 10));
        expect(proxy.createdIds.last, proxy.createdIds.first, reason: 'B must carry A\'s recycled id');

        final before = bValues;
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(
          bValues - before,
          greaterThan(3),
          reason: 'the new item stopped receiving values: the delete response for the old item removed it',
        );
        await b.cancel();
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  }
}
