// A structured type whose fields share a type (D0 {a: D1, b: D1}, ...) is
// read once per type, but decoding a value of it copies the shared
// definition once per field: 20 levels expanded to 3 million DynamicValues
// (467 MB) for one value, after 21 cheap definition reads. An array holds a
// copy of its element type per element as well.
//
// Now buildSchema counts the nodes a type expands to and refuses one above
// ValueTooLarge.limit, and an array whose elements times its element type's
// nodes is above it is refused before anything is copied: the read fails
// with ValueTooLarge and the client stays usable.

import 'dart:async';
import 'dart:isolate';

import 'package:binarize/binarize.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

final _diaNode = NodeId.fromString(1, 'dia.node');
final _wideType = NodeId.fromString(1, 'Wide200');
final _okArray = NodeId.fromString(1, 'array.ok');
final _bigArray = NodeId.fromString(1, 'array.big');

/// Wide200 {f0..f198: Boolean}: 200 nodes.
DynamicValue _wide() {
  final v = DynamicValue(name: 'Wide200', typeId: _wideType);
  for (var i = 0; i < 199; i++) {
    v['f$i'] = DynamicValue(value: i.isEven, typeId: NodeId.boolean);
  }
  return v;
}

DynamicValue _wides(int n) =>
    DynamicValue.fromList([for (var i = 0; i < n; i++) _wide()], typeId: _wideType, name: 'Wide200s');

Matcher _throwsValueTooLarge(String detail) => throwsA(
  predicate<Object>((e) => '$e'.contains('ValueTooLarge') && '$e'.contains(detail), 'ValueTooLarge ($detail)'),
);

/// The test server on an isolate of its own: a ~1 MB response is larger than
/// a Windows loopback buffer, and open62541's client blocks in its receive
/// until the peer drains it, which a server pumped by the client's isolate
/// cannot do meanwhile (the read then times out).
class _IsolateServer {
  _IsolateServer._(this.port, this._control, this._exited);

  final int port;
  final SendPort _control;
  final ReceivePort _exited;

  static Future<_IsolateServer> start() async {
    final ready = ReceivePort();
    final exited = ReceivePort();
    await Isolate.spawn(_serve, ready.sendPort, onExit: exited.sendPort);
    final (port, control) = await ready.first as (int, SendPort);
    return _IsolateServer._(port, control, exited);
  }

  static Future<void> _serve(SendPort ready) async {
    final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    server.addVariableNode(_diaNode, addDiamond(server, 20), typeId: diamondType(0));
    server.addCustomType(_wideType, _wide());
    server.addDataTypeNode(_wideType, 'Wide200');
    server.addVariableNode(_okArray, _wides(1000), typeId: _wideType);
    server.addVariableNode(_bigArray, _wides(ValueTooLarge.limit ~/ 200 + 1), typeId: _wideType);
    final control = ReceivePort();
    var serving = true;
    control.listen((_) => serving = false);
    ready.send((server.port, control.sendPort));
    while (serving) {
      server.runIterate();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    control.close();
    server.shutdown();
    server.delete();
  }

  Future<void> stop() async {
    _control.send(null);
    await _exited.first;
  }
}

void main() {
  test('deserialize refuses a struct array member before copying its template per element', () {
    final schema = DynamicValue(typeId: NodeId.fromString(1, 'Holder'));
    schema['items'] = DynamicValue.fromList([_wide()], typeId: _wideType);
    const length = ValueTooLarge.limit ~/ 200 + 1;
    final body = Uint8List(4 + length * 199)..buffer.asByteData().setInt32(0, length, Endian.little);
    expect(
      () =>
          OpcUaDynamicValueSerializer.deserialize(schema, ByteReader(body, endian: Endian.little), Endian.little, true),
      throwsA(isA<ValueTooLarge>().having((e) => e.elements, 'elements', length)),
    );
  });

  for (final clientType in clientTypes) {
    group('$clientType client: values that expand past ValueTooLarge.limit', () {
      late _IsolateServer server;
      late ClientApi client;

      setUp(() async {
        server = await _IsolateServer.start();
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        await server.stop();
      });

      test('a 20-level diamond is refused, and the client stays usable', () async {
        final watch = Stopwatch()..start();
        await expectLater(client.read(_diaNode), _throwsValueTooLarge(diamondType(2).toString()));
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        expect((await client.read(_okArray)).asArray, hasLength(1000));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('an array of 1000 values of a 200-node struct decodes', () async {
        final value = await client.read(_okArray);
        expect(value.asArray, hasLength(1000));
        expect(value[999]['f198'].asBool, isTrue);
      });

      test('an array whose elements expand past the limit is refused', () async {
        await expectLater(
          client.read(_bigArray),
          _throwsValueTooLarge('an array of ${ValueTooLarge.limit ~/ 200 + 1}'),
        );
      });
    });
  }
}
