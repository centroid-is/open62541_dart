import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'history_memory_backend.dart';

/// HistoryRead under `Server(accessControl:)`: the read needs the HistoryRead
/// bit of the session's UserAccessLevel (the node's AccessLevel ANDed with
/// [AccessControl.userAccessLevel]), which open62541 itself never checks.

const _historyReader = 'history-reader';
const _historyTag = 7;

final historized = NodeId.fromString(1, 'history.gated');
final noHistoryBit = NodeId.fromString(1, 'history.no-bit');

class _Gate extends AccessControl {
  /// What [userAccessLevel] grants on a [_historyTag] node.
  int level = 0xFF;
  var throwOnAccessLevel = false;

  @override
  Set<UserTokenType> get userTokenTypes => {UserTokenType.anonymous};

  @override
  Object? activateSession(SessionActivation activation) => _historyReader;

  @override
  int userAccessLevel(Object? context, NodeRef node) {
    if (throwOnAccessLevel) throw StateError('userAccessLevel failed');
    return node.tag == _historyTag ? level : 0xFF;
  }
}

void main() {
  late _Gate gate;
  late Server server;
  late MemoryBackend backend;
  late ClientIsolate client;

  setUp(() async {
    gate = _Gate();
    server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR, accessControl: gate);
    server.start();
    () async {
      while (server.runIterate()) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();
    server.addVariableNode(
      historized,
      DynamicValue(value: 0, typeId: NodeId.int32, name: 'gated'),
      accessLevel: const AccessLevelMask(read: true, historyRead: true),
      historizing: true,
      accessTag: _historyTag,
    );
    server.addVariableNode(
      noHistoryBit,
      DynamicValue(value: 0, typeId: NodeId.int32, name: 'no-bit'),
      historizing: true,
    );
    backend = MemoryBackend({historized: samples(3), noHistoryBit: samples(2)});
    server.setHistoryBackend(backend);
    client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    unawaited(client.runIterate().catchError((_) {}));
    await client.connect('opc.tcp://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await client.delete();
    server.shutdown();
    server.delete();
  });

  Matcher deniedWith(int status) => throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', status));

  test('a session granted the HistoryRead bit reads, with its context', () async {
    final history = await client.historyReadRaw([historized]);
    expect(history[historized]!.map((v) => v.value.value), [0, 1, 2]);
    expect(backend.calls.single.single.session.context, _historyReader);
  });

  test('a session without the HistoryRead bit is answered Bad_UserAccessDenied', () async {
    gate.level = raw.UA_ACCESSLEVELMASK_READ;
    await expectLater(client.historyReadRaw([historized]), deniedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
    expect(backend.calls, isEmpty, reason: 'the backend never sees a denied node');
    // The same session still reads the value.
    expect((await client.read(historized)).value, 0);
  });

  test('the node AccessLevel must carry the bit too', () async {
    await expectLater(client.historyReadRaw([noHistoryBit]), deniedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
    expect(backend.calls, isEmpty);
  });

  test('a throwing hook denies', () async {
    gate.throwOnAccessLevel = true;
    await expectLater(client.historyReadRaw([historized]), deniedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
    expect(backend.calls, isEmpty);
  });
}
