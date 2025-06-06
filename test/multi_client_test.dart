import 'dart:async';
import 'dart:math';

import 'common.dart';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

void main() async {
  final lib = loadOpen62541Library(local: true);

  final serverCount = 2;
  final clientPerServer = 1;
  var serverPorts = List.generate(serverCount, (index) => Random().nextInt(10000) + 4840);
  while (serverPorts.toSet().length != serverCount) {
    serverPorts = List.generate(serverCount, (index) => Random().nextInt(10000) + 4840);
  }

  LogLevel logLevel = LogLevel.UA_LOGLEVEL_INFO;

  Map<Server, List<Client>> serversAndClients = {};

  setUp(() async {
    print("Setup starting");
    for (var port in serverPorts) {
      final server = setupServer(lib, port, logLevel: logLevel);
      serversAndClients[server] =
          await Future.wait(List.generate(clientPerServer, (index) => setupClient(lib, port, logLevel: logLevel)));
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
  });

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
