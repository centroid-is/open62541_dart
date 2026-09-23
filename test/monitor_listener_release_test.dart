// Regression tests for the monitored-item listener leak.
//
// Every monitored-item stream attaches three listeners to the client config's
// broadcast streams (subscription inactivity, subscription deleted, client
// state) so it can forward those conditions as errors. Each listener closure
// captures the item's own value map, so a listener that outlives its item pins
// the key's last value — enum fields, localized texts, node ids and all.
//
// Those listeners used to be released lazily: each began with
// `if (controller.isClosed) { sub?.cancel(); return; }`, which only runs on
// the NEXT event on that stream — and on a quiet client that is never. On a
// production HMI the caller tears down and rebuilds a monitored item whenever
// the server gives a hard answer (BadNodeIdUnknown, ...), forever, so the
// leaked listeners (and everything they capture) grew without bound: RSS
// climbed 72–122 MiB/h until the panel was OOM-killed.
//
// The property pinned here: after ANY path that ends a monitored item, the
// config streams have no listener left from it — immediately, without waiting
// for an unrelated event to arrive.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show freeTcpPort;

final intNodeId = NodeId.fromString(1, "the.int");
final unknownNodeId = NodeId.fromString(1, "does.not.exist");

/// Runs in its own isolate: rebuild a refused item a few times, tear the
/// client down, return. A live NativeCallable.isolateLocal keeps its isolate
/// alive, so if any rebuild leaks its monitor callback the isolate never
/// exits — the same technique as write_callback_release_test.dart.
Future<void> refusedRebuildsThenReturn((int, SendPort) args) async {
  final (port, report) = args;
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final pump = Timer.periodic(Duration(milliseconds: 5), (_) {
    client.runIterate(Duration(milliseconds: 5));
  });
  await client.connect('opc.tcp://127.0.0.1:$port');
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

  var refusals = 0;
  for (var i = 0; i < 3; i++) {
    final done = Completer<void>();
    client
        .monitoredItems({
          unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: (_) => refusals++, onDone: done.complete);
    await done.future.timeout(Duration(seconds: 5));
  }

  pump.cancel();
  await client.delete();
  report.send(refusals);
}

void main() {
  late int serverPort;
  late Server server;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;
  var serverShutdown = false;

  void startClientPump() {
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });
  }

  void stopClientPump() {
    clientTimer?.cancel();
    clientTimer = null;
  }

  setUp(() async {
    serverPort = await freeTcpPort();
    serverShutdown = false;
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    server.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    startClientPump();
    await client.connect("opc.tcp://127.0.0.1:$serverPort");
    // Nothing else in these tests subscribes to the config streams, so the
    // gauge starts clean and reads false exactly when no monitored item holds
    // a listener.
    expect(client.config.hasStreamListeners, isFalse);
  });

  tearDown(() async {
    stopClientPump();
    serverTimer.cancel();
    if (!serverShutdown) server.shutdown();
    await client.delete();
    if (!serverShutdown) server.delete();
  });

  test('a create refused for every node (BadNodeIdUnknown) releases the listeners, rebuild after rebuild', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    // The production trigger: the caller rebuilds a refused item forever, on
    // a backoff ladder. Each rebuild must leave nothing behind.
    for (var i = 0; i < 5; i++) {
      final errors = <Object>[];
      final done = Completer<void>();
      client
          .monitoredItems({
            unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subscriptionId)
          .listen((_) {}, onError: errors.add, onDone: done.complete);

      await done.future.timeout(Duration(seconds: 5), onTimeout: () => fail('rebuild $i: the stream never closed'));
      expect(errors, hasLength(1), reason: 'rebuild $i');
      expect(errors.single.toString(), contains('BadNodeIdUnknown'), reason: 'rebuild $i');
      // Released by the time the stream is done — not on the next state
      // change, which on a quiet client never comes.
      expect(client.config.hasStreamListeners, isFalse, reason: 'rebuild $i left a listener behind');
    }

    // The client is still healthy after the churn.
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('refused rebuilds release their native monitor callback: the isolate can exit', () async {
    // The listeners are one half of what a refused rebuild used to keep; the
    // other is the item's NativeCallable, which the old path never closed
    // (it ran the "create still in flight" branch of the teardown instead).
    final report = ReceivePort();
    final exited = ReceivePort();
    await Isolate.spawn(refusedRebuildsThenReturn, (serverPort, report.sendPort), onExit: exited.sendPort);

    expect(await report.first.timeout(Duration(seconds: 20)), 3, reason: 'every rebuild must be refused');
    await exited.first.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('the isolate never exited: a NativeCallable is still open after the refused rebuilds'),
    );
  }, timeout: Timeout(Duration(seconds: 45)));

  test('a partial refusal (one node unknown, one fine) releases the listeners', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final errors = <Object>[];
    final done = Completer<void>();
    client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: errors.add, onDone: done.complete);

    await done.future.timeout(Duration(seconds: 5), onTimeout: () => fail('the stream never closed'));
    expect(errors.single.toString(), contains('BadNodeIdUnknown'));
    expect(client.config.hasStreamListeners, isFalse);

    // The item the server DID create is deleted again in the background; the
    // client stays healthy.
    await Future.delayed(Duration(milliseconds: 200));
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('cancelling a live item releases the listeners as part of the cancel', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final values = <DynamicValue>[];
    final sub = client
        .monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 50))
        .listen(values.add);
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty, reason: 'should have received the initial value');
    expect(client.config.hasStreamListeners, isTrue, reason: 'a live item holds its listeners');

    await sub.cancel();
    expect(client.config.hasStreamListeners, isFalse);
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling while the create is still in flight leaves no listener', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    // Pause the pump so the create request cannot be answered before the
    // cancel is issued.
    stopClientPump();
    final sub = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: (_) {});
    unawaited(sub.cancel());
    startClientPump();

    // Let the create response (and the deferred delete it triggers) go by.
    await Future.delayed(Duration(milliseconds: 500));
    expect(client.config.hasStreamListeners, isFalse);
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling on a dead connection completes and releases the listeners', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final values = <Map<NodeId, DynamicValue>>[];
    final sub = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen(values.add, onError: (_) {});
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty);

    // Kill the server so the secure channel is gone by the time we cancel:
    // the DeleteMonitoredItems request then cannot even be sent.
    serverTimer.cancel();
    server.shutdown();
    server.delete();
    serverShutdown = true;
    await Future.delayed(Duration(milliseconds: 500));

    // A cancel that cannot reach the server must still finish (the caller
    // awaits it) and must still let go of the listeners.
    await sub.cancel().timeout(Duration(seconds: 3), onTimeout: () => fail('cancel() never completed'));
    expect(client.config.hasStreamListeners, isFalse);
  }, timeout: Timeout(Duration(seconds: 15)));
}
