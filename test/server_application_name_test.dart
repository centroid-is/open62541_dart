import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Tests for the identity a [Server] announces: the constructor's
/// `applicationName` / `applicationUri` / `productName` / `manufacturerName`
/// / `productUri` replace open62541's defaults, and a client sees them
/// through ns0.
void main() {
  // What open62541's UA_ServerConfig_setMinimal puts in the config.
  const defaultApplicationName = 'open62541-based OPC UA Application';
  const defaultApplicationUri = 'urn:open62541.unconfigured.application';

  final serverArray = NodeId.fromNumeric(0, 2254);
  final namespaceArray = NodeId.fromNumeric(0, 2255);
  final buildInfoProductUri = NodeId.fromNumeric(0, 2262);
  final buildInfoProductName = NodeId.fromNumeric(0, 2261);
  final buildInfoManufacturerName = NodeId.fromNumeric(0, 2263);

  group('Server identity', () {
    late Server server;
    late Client client;

    setUp(() async {
      server = Server(
        port: 0,
        logLevel: LogLevel.UA_LOGLEVEL_ERROR,
        applicationName: 'CentroidM agg-test',
        applicationUri: 'urn:centroidm:agg-test',
        productName: 'CentroidM',
        manufacturerName: 'Centroid',
        productUri: 'urn:centroid:centroidm',
      );
      server.start();
      () async {
        while (server.runIterate()) {
          await Future.delayed(Duration(milliseconds: 50));
        }
      }();
      client = await setupClient(server.port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('the getters answer what the constructor was given', () {
      expect(server.applicationName, 'CentroidM agg-test');
      expect(server.applicationUri, 'urn:centroidm:agg-test');
      expect(server.productUri, 'urn:centroid:centroidm');
    });

    test('NamespaceArray[1] is the ApplicationUri (the server\'s own namespace)', () async {
      final value = await client.read(namespaceArray).timeout(const Duration(seconds: 10));
      expect(value.isArray, isTrue);
      expect(value[1].asString, 'urn:centroidm:agg-test');
    });

    test('ServerArray[0] is the ApplicationUri', () async {
      final value = await client.read(serverArray).timeout(const Duration(seconds: 10));
      expect(value.isArray, isTrue);
      expect(value.asArray, hasLength(1));
      expect(value[0].asString, 'urn:centroidm:agg-test');
    });

    test('Server/ServerStatus/BuildInfo carries the product and manufacturer', () async {
      final product = await client.read(buildInfoProductName).timeout(const Duration(seconds: 10));
      expect(product.asString, 'CentroidM');
      final manufacturer = await client.read(buildInfoManufacturerName).timeout(const Duration(seconds: 10));
      expect(manufacturer.asString, 'Centroid');
      final productUri = await client.read(buildInfoProductUri).timeout(const Duration(seconds: 10));
      expect(productUri.asString, 'urn:centroid:centroidm');
    });
  });

  test('Server() keeps open62541\'s default identity', () {
    final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    addTearDown(server.delete);
    expect(server.applicationName, defaultApplicationName);
    expect(server.applicationUri, defaultApplicationUri);
  });
}
