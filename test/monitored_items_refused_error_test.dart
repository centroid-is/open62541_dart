// Regression test for #38: a monitored item the server refuses (here a
// NodeId that does not exist, answered with BadNodeIdUnknown) reached the
// stream as a String error, so a caller could neither match on the type nor
// read the status code; service-level failures of the same create were
// already a UaStatusException. The refusal is now a MonitoredItemsRefused,
// a UaStatusException carrying the status of every refused item, and it
// crosses the ClientIsolate boundary as itself. The DataValue stream of #130
// (monitoredDataValues) shares the create with monitoredItems, so it reports
// the same error.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

final missingNodeId = NodeId.fromString(1, 'does.not.exist');

/// Monitors [missingNodeId] on [client], through `monitoredItems` or, with
/// [dataValues], `monitoredDataValues`, and returns the first error the
/// stream delivers.
Future<Object> firstStreamError(ClientApi client, {bool dataValues = false}) async {
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
  final nodes = {
    missingNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
  };
  final Stream<Object> stream = dataValues
      ? (client as DataValueMonitoringApi).monitoredDataValues(nodes, subscriptionId)
      : client.monitoredItems(nodes, subscriptionId);
  final error = Completer<Object>();
  final subscription = stream.listen(
    (_) {},
    onError: (Object e) {
      if (!error.isCompleted) error.complete(e);
    },
  );
  addTearDown(subscription.cancel);
  return error.future.timeout(
    Duration(seconds: 10),
    onTimeout: () => fail('the stream reported no error for a refused monitored item'),
  );
}

void expectRefused(Object error) {
  expect(error, isA<MonitoredItemsRefused>(), reason: 'the stream error is ${error.runtimeType}: $error');
  final refused = error as MonitoredItemsRefused;
  expect(refused, isA<UaStatusException>());
  expect(refused.statusCode, raw.UA_STATUSCODE_BADNODEIDUNKNOWN);
  expect(refused.failures, {(missingNodeId, AttributeId.UA_ATTRIBUTEID_VALUE): raw.UA_STATUSCODE_BADNODEIDUNKNOWN});
  // The text log readers knew from the String error.
  expect(
    refused.toString(),
    'Unable to create monitored item: ($missingNodeId, ${AttributeId.UA_ATTRIBUTEID_VALUE}): BadNodeIdUnknown',
  );
}

void main() {
  late Server server;

  setUp(() {
    server = setupServer();
    addBasicVariables(server);
  });

  tearDown(() {
    server.shutdown();
    server.delete();
  });

  Future<ClientIsolate> setupClientIsolate() async {
    final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    // The worker pumps the native client only while runIterate runs; it ends
    // with an error once the client is deleted in the teardown.
    unawaited(client.runIterate().catchError((_) {}));
    await client.connect('opc.tcp://127.0.0.1:${server.port}');
    addTearDown(client.delete);
    return client;
  }

  test('Client: a refused monitored item fails the stream with MonitoredItemsRefused', () async {
    final client = await setupClient(server.port);
    addTearDown(client.delete);
    expectRefused(await firstStreamError(client));
  }, timeout: Timeout(Duration(seconds: 30)));

  test('ClientIsolate: the MonitoredItemsRefused crosses the isolate boundary typed', () async {
    expectRefused(await firstStreamError(await setupClientIsolate()));
  }, timeout: Timeout(Duration(seconds: 30)));

  test('Client, monitoredDataValues: the same MonitoredItemsRefused', () async {
    final client = await setupClient(server.port);
    addTearDown(client.delete);
    expectRefused(await firstStreamError(client, dataValues: true));
  }, timeout: Timeout(Duration(seconds: 30)));

  test('ClientIsolate, monitoredDataValues: the same MonitoredItemsRefused, typed', () async {
    expectRefused(await firstStreamError(await setupClientIsolate(), dataValues: true));
  }, timeout: Timeout(Duration(seconds: 30)));
}
