import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// The data-change dispatch identifies monitored items by their request-time
// context (their request-order index), NOT by the server-assigned
// monitoredItemId: open62541 registers items in its dispatch tree at request
// time and invokes the data callback with monitoredItemId still 0 for
// notifications the server delivered before the CreateMonitoredItemsResponse
// was processed (observed in the field against Beckhoff servers — the
// boot-time "Error converting data for: null" flood). A monId-keyed lookup
// cannot identify those notifications; the request-order context can always.
//
// The in-process open62541 test server always answers the create request
// before its first publish, so the exact wire race cannot be reproduced here.
// Instead these tests pin the property that makes the race harmless: identity
// flows exclusively through the request-order context, so with many items in
// one request every value must land on the node and attribute that requested
// it — any off-by-one or scramble in the context mapping fails loudly.
void main() {
  final port = Random().nextInt(10000) + 4840;
  late Server server;
  late Client client;
  bool running = false;

  setUp(() async {
    server = setupServer(port);
    addBasicVariables(server);
    client = Client();
    running = true;
    () async {
      while (running && client.runIterate(const Duration(milliseconds: 10))) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }();
    await client.connect("opc.tcp://localhost:$port");
  });

  tearDown(() async {
    running = false;
    await client.delete();
    server.shutdown();
    server.delete();
  });

  test('many single-attribute items: every value lands on its own node', () async {
    // The sharpest scramble detector: N items whose only difference is their
    // request-order position, each holding a value derived from that position.
    final nodes = <NodeId, int>{};
    for (var i = 0; i < 6; i++) {
      final node = NodeId.fromString(1, "identity.int$i");
      server.addVariableNode(node, DynamicValue(value: 100 + i, typeId: NodeId.int32, name: "identity.int$i"));
      nodes[node] = 100 + i;
    }

    final subscription = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final first = Completer<Map<NodeId, DynamicValue>>();
    final sub = client
        .monitoredItems(
          {
            for (final node in nodes.keys) node: [AttributeId.UA_ATTRIBUTEID_VALUE],
          },
          subscription,
          samplingInterval: Duration(milliseconds: 10),
        )
        .listen((values) {
          if (!first.isCompleted) first.complete(values);
        });

    final values = await first.future.timeout(Duration(seconds: 10));
    expect(values.keys, containsAll(nodes.keys));
    for (final entry in nodes.entries) {
      expect(values[entry.key]!.value, entry.value, reason: 'value for ${entry.key} mapped to the wrong item');
    }
    await sub.cancel();
  }, timeout: Timeout(Duration(seconds: 30)));

  test('multi-attribute items: values and static attributes land on their own nodes', () async {
    // Multiple attributes per node interleaved across nodes — the context
    // indexes cover VALUE and static attributes, and the first emission must
    // be complete (the gate requires every item to have been seen).
    final attrs = [
      AttributeId.UA_ATTRIBUTEID_DATATYPE,
      AttributeId.UA_ATTRIBUTEID_VALUE,
      AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
    ];
    final subscription = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
    final first = Completer<Map<NodeId, DynamicValue>>();
    Map<NodeId, DynamicValue>? latestEmission;
    final sub = client
        .monitoredItems(
          {boolNodeId: attrs, intNodeId: attrs, doubleNodeId: attrs, stringNodeId: attrs},
          subscription,
          samplingInterval: Duration(milliseconds: 10),
        )
        .listen((values) {
          latestEmission = values;
          if (!first.isCompleted) first.complete(values);
        });

    final values = await first.future.timeout(Duration(seconds: 10));
    expect(values[boolNodeId]!.value, true);
    expect(values[intNodeId]!.value, 1);
    expect(values[doubleNodeId]!.value, 3.14);
    expect(values[stringNodeId]!.value, "Hello World!");
    expect(values[intNodeId]!.typeId, NodeId.int32, reason: 'DATATYPE attribute mapped to the wrong item');
    expect(values[doubleNodeId]!.typeId, NodeId.double, reason: 'DATATYPE attribute mapped to the wrong item');

    // Updates must keep landing on the right nodes.
    await client.write(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32));
    await client.write(doubleNodeId, DynamicValue(value: 2.5, typeId: NodeId.double));
    final deadline = DateTime.now().add(Duration(seconds: 10));
    while ((latestEmission![intNodeId]!.value != 42 || latestEmission![doubleNodeId]!.value != 2.5) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(milliseconds: 20));
    }
    expect(latestEmission![intNodeId]!.value, 42);
    expect(latestEmission![doubleNodeId]!.value, 2.5);
    expect(latestEmission![boolNodeId]!.value, true, reason: 'update leaked onto an unrelated item');
    expect(latestEmission![stringNodeId]!.value, "Hello World!", reason: 'update leaked onto an unrelated item');

    await sub.cancel();
  }, timeout: Timeout(Duration(seconds: 30)));
}
