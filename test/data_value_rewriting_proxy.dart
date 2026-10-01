// A TCP proxy for tests that rewrites one DataValue on the wire.
//
// The in-process open62541 server cannot produce every spec-legal answer the
// client has to survive: it never answers a non-Value attribute with an empty
// variant, and it stamps every Value sample with a source timestamp. This
// proxy sits between a client and that server (SecurityPolicy None, so the
// stream is plain OPC UA binary) and replaces the DataValue of a ReadResponse
// or of a data-change PublishResponse on its way to the client.
//
// Only the shape the tests use is rewritten: a single-chunk response carrying
// exactly ONE DataValue (one attribute read, or one monitored item's
// notification). Everything else passes through byte for byte, and the
// rewrite counters say what was changed so a test can prove it happened.
//
// This is a helper library (imported, not run directly), so it has no `main`.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Maps the binary-encoded DataValue the server sent to the one the client
/// receives.
typedef DataValueRewrite = Uint8List Function(Uint8List dataValue);

/// Status Good with `hasValue` clear: an encoding mask with no field set.
Uint8List goodWithoutValue(Uint8List _) => Uint8List.fromList([0x00]);

/// Status Good with `hasValue` set around a null variant (built-in type 0).
Uint8List goodWithEmptyVariant(Uint8List _) => Uint8List.fromList([0x01, 0x00]);

/// A sample the server marked Bad: `hasStatus` set, nothing else.
DataValueRewrite badWithoutValue(int statusCode) {
  final bytes = ByteData(5)
    ..setUint8(0, 0x02)
    ..setUint32(1, statusCode, Endian.little);
  return (_) => bytes.buffer.asUint8List();
}

/// The same DataValue with its source timestamp (and picoseconds) removed.
Uint8List withoutSourceTimestamp(Uint8List dataValue) {
  // Encoding mask: 0x01 value, 0x02 status, 0x04 sourceTimestamp,
  // 0x08 serverTimestamp, 0x10 sourcePicoseconds, 0x20 serverPicoseconds.
  // The fields follow the mask in that order, except that each picoseconds
  // field directly follows its timestamp.
  final mask = dataValue[0];
  if (mask & 0x04 == 0) return dataValue;
  final serverLength = (mask & 0x08 != 0 ? 8 : 0) + (mask & 0x20 != 0 ? 2 : 0);
  final sourceLength = 8 + (mask & 0x10 != 0 ? 2 : 0);
  final sourceStart = dataValue.length - serverLength - sourceLength;
  return Uint8List.fromList([
    mask & ~0x14,
    ...dataValue.sublist(1, sourceStart),
    ...dataValue.sublist(dataValue.length - serverLength),
  ]);
}

class DataValueRewritingProxy {
  DataValueRewritingProxy._(this._listener, this._upstreamPort);

  final ServerSocket _listener;
  final int _upstreamPort;
  final _sockets = <Socket>[];

  /// Applied to the DataValue of every single-result ReadResponse while set.
  /// That includes the reads the client issues on its own (open62541's
  /// connectivity check reads one attribute once a second).
  DataValueRewrite? rewriteRead;

  /// Applied to the DataValue of every PublishResponse that carries exactly
  /// one data-change notification while set.
  DataValueRewrite? rewriteNotification;

  /// How many responses [rewriteRead] / [rewriteNotification] were applied to.
  int readRewrites = 0;
  int notificationRewrites = 0;

  /// The port a client connects to instead of the server's.
  int get port => _listener.port;

  /// Starts a proxy in front of the server listening on [upstreamPort].
  static Future<DataValueRewritingProxy> start(int upstreamPort) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = DataValueRewritingProxy._(listener, upstreamPort);
    listener.listen(proxy._accept);
    return proxy;
  }

  Future<void> close() async {
    await _listener.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
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
      // A write racing the peer's close fails this future; nobody awaits it.
      socket.done.ignore();
    }

    client.listen(upstream.add, onDone: upstream.destroy, onError: (_) => upstream.destroy());

    // The server -> client direction is re-framed into whole OPC UA messages
    // (8-byte header: 3-byte type, chunk type, little-endian total size) so a
    // response can be rewritten as a unit.
    var pending = Uint8List(0);
    upstream.listen(
      (data) {
        pending = Uint8List.fromList([...pending, ...data]);
        while (pending.length >= 8) {
          final size = ByteData.sublistView(pending).getUint32(4, Endian.little);
          if (size < 8 || pending.length < size) break;
          client.add(_rewriteMessage(pending.sublist(0, size)));
          pending = pending.sublist(size);
        }
      },
      onDone: client.destroy,
      onError: (_) => client.destroy(),
    );
  }

  static const _readResponse = 634;
  static const _publishResponse = 829;
  static const _dataChangeNotification = 811;

  Uint8List _rewriteMessage(Uint8List message) {
    if (rewriteRead == null && rewriteNotification == null) return message;
    final view = ByteData.sublistView(message);

    // A final ('F') chunk of a symmetric 'MSG': message header (8), secure
    // channel id, token id, sequence number, request id (4 each), then the
    // body, which opens with the response's type NodeId in its four-byte form
    // (0x01, namespace 0, 16-bit identifier).
    const typeIdOffset = 24;
    const headerOffset = typeIdOffset + 4;
    // ResponseHeader as open62541 encodes it for a Good service result:
    // timestamp (8), requestHandle (4), serviceResult (4), an empty
    // serviceDiagnostics (mask 0x00), an empty stringTable (int32 length) and
    // a null additionalHeader (two-byte NodeId 0 + encoding byte 0).
    const bodyOffset = headerOffset + 24;
    if (message.length < bodyOffset + 8) return message;
    if (message[0] != 0x4D || message[1] != 0x53 || message[2] != 0x47 || message[3] != 0x46) return message;
    if (message[typeIdOffset] != 0x01 || message[typeIdOffset + 1] != 0x00) return message;
    if (view.getUint32(headerOffset + 12, Endian.little) != 0) return message;
    if (message[headerOffset + 16] != 0x00 || view.getInt32(headerOffset + 17, Endian.little) > 0) return message;
    if (message[headerOffset + 21] != 0x00 || message[headerOffset + 22] != 0x00) return message;
    if (message[headerOffset + 23] != 0x00) return message;

    final DataValueRewrite? rewrite;
    int dataValueStart;
    int dataValueEnd;
    int? extensionLengthOffset;
    switch (view.getUint16(typeIdOffset + 2, Endian.little)) {
      case _readResponse:
        rewrite = rewriteRead;
        // results: int32 count, the DataValues, then diagnosticInfos (int32).
        if (view.getInt32(bodyOffset, Endian.little) != 1) return message;
        dataValueStart = bodyOffset + 4;
        dataValueEnd = message.length - 4;
      case _publishResponse:
        rewrite = rewriteNotification;
        // subscriptionId (4), availableSequenceNumbers (int32 count + 4 each),
        // moreNotifications (1), then the NotificationMessage: sequenceNumber
        // (4), publishTime (8), notificationData (int32 count).
        var offset = bodyOffset + 4;
        final available = view.getInt32(offset, Endian.little);
        offset += 4 + (available > 0 ? available * 4 : 0) + 1 + 4 + 8;
        if (offset + 4 + 9 + 12 > message.length) return message;
        if (view.getInt32(offset, Endian.little) != 1) return message;
        offset += 4;
        // The one notification: an ExtensionObject with a four-byte type
        // NodeId, a ByteString body (encoding 0x01) and its int32 length.
        if (message[offset] != 0x01 || message[offset + 1] != 0x00) return message;
        if (view.getUint16(offset + 2, Endian.little) != _dataChangeNotification) return message;
        if (message[offset + 4] != 0x01) return message;
        extensionLengthOffset = offset + 5;
        final extensionStart = offset + 9;
        final extensionEnd = extensionStart + view.getInt32(extensionLengthOffset, Endian.little);
        // DataChangeNotification: monitoredItems (int32 count, then per item a
        // clientHandle (4) and the DataValue), then diagnosticInfos (int32).
        if (view.getInt32(extensionStart, Endian.little) != 1) return message;
        dataValueStart = extensionStart + 8;
        dataValueEnd = extensionEnd - 4;
      default:
        return message;
    }
    if (rewrite == null || dataValueEnd <= dataValueStart) return message;

    final replacement = rewrite(message.sublist(dataValueStart, dataValueEnd));
    final rewritten = Uint8List.fromList([
      ...message.sublist(0, dataValueStart),
      ...replacement,
      ...message.sublist(dataValueEnd),
    ]);
    final delta = rewritten.length - message.length;
    final out = ByteData.sublistView(rewritten);
    out.setUint32(4, rewritten.length, Endian.little);
    if (extensionLengthOffset != null) {
      out.setInt32(extensionLengthOffset, view.getInt32(extensionLengthOffset, Endian.little) + delta, Endian.little);
    }
    if (extensionLengthOffset == null) {
      readRewrites++;
    } else {
      notificationRewrites++;
    }
    return rewritten;
  }
}
