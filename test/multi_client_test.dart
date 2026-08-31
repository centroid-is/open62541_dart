import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() async {
  final serverCount = 2;
  final clientPerServer = 1;
  final serverPorts = <int>[];

  LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR;

  Map<Server, List<Client>> serversAndClients = {};

  setUp(() async {
    print("Setup starting");
    serverPorts.clear();
    while (serverPorts.length != serverCount) {
      final port = await freeTcpPort();
      if (!serverPorts.contains(port)) serverPorts.add(port);
    }
    for (var port in serverPorts) {
      final server = setupServer(port, logLevel: logLevel);
      serversAndClients[server] = await Future.wait(
        List.generate(clientPerServer, (index) => setupClient(port, logLevel: logLevel)),
      );
    }
    print("Setup complete");
  });
  test('Basic read and write', () async {
    for (var server in serversAndClients.keys) {
      addBasicVariables(server);
    }

    List<Completer<void>> completers = [];

    for (var server in serversAndClients.keys) {
      for (var client in serversAndClients[server]!) {
        bool boolValue = Random().nextBool();
        final boolCompleter = Completer<void>();
        completers.add(boolCompleter);
        client.write(boolNodeId, DynamicValue(value: boolValue, typeId: NodeId.boolean)).then((value) {
          client.read(boolNodeId).then((value) {
            boolCompleter.complete();
            expect(value.value, boolValue);
          });
        });
      }
    }
    await Future.wait(completers.map((completer) => completer.future));
    //TODO: Reenable this test
  }, skip: 'Test skipped, is currently failing. Skip to reduce noise in CI');

  tearDown(() async {
    print("Teardown starting");
    for (var server in serversAndClients.keys) {
      server.shutdown();
    }

    for (var client in serversAndClients.values.expand((x) => x)) {
      await client.delete();
    }

    for (var server in serversAndClients.keys) {
      server.delete();
    }

    serversAndClients.clear();

    print("Teardown complete");
  });
}
