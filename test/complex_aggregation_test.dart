import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';
import 'common.dart';

/// Custom "SensorReading" type: { temperature: Double, pressure: Int32, valid: Boolean }
DynamicValue buildSensorReadingSchema(NodeId typeId) {
  final schema = DynamicValue(name: "SensorReading", typeId: typeId);
  schema["temperature"] = DynamicValue(value: 0.0, typeId: NodeId.double);
  schema["pressure"] = DynamicValue(value: 0, typeId: NodeId.int32);
  schema["valid"] = DynamicValue(value: false, typeId: NodeId.boolean);
  return schema;
}

/// Custom "DeviceStatus" type: { deviceId: Int32, online: Boolean, errorCode: Int32 }
DynamicValue buildDeviceStatusSchema(NodeId typeId) {
  final schema = DynamicValue(name: "DeviceStatus", typeId: typeId);
  schema["deviceId"] = DynamicValue(value: 0, typeId: NodeId.int32);
  schema["online"] = DynamicValue(value: false, typeId: NodeId.boolean);
  schema["errorCode"] = DynamicValue(value: 0, typeId: NodeId.int32);
  return schema;
}

/// Helper: create a SensorReading instance with given values
DynamicValue makeSensorReading(NodeId typeId, String name,
    {required double temperature, required int pressure, required bool valid}) {
  final v = DynamicValue(name: name, typeId: typeId);
  v["temperature"] = DynamicValue(value: temperature, typeId: NodeId.double);
  v["pressure"] = DynamicValue(value: pressure, typeId: NodeId.int32);
  v["valid"] = DynamicValue(value: valid, typeId: NodeId.boolean);
  return v;
}

/// Helper: create a DeviceStatus instance with given values
DynamicValue makeDeviceStatus(NodeId typeId, String name,
    {required int deviceId, required bool online, required int errorCode}) {
  final v = DynamicValue(name: name, typeId: typeId);
  v["deviceId"] = DynamicValue(value: deviceId, typeId: NodeId.int32);
  v["online"] = DynamicValue(value: online, typeId: NodeId.boolean);
  v["errorCode"] = DynamicValue(value: errorCode, typeId: NodeId.int32);
  return v;
}

void main() {
  group('Complex aggregation with custom objects', () {
    Server? serverA;
    Server? serverB;
    Client? clientA;
    Client? clientB;
    final portA = Random().nextInt(8000) + 20000;
    final portB = portA + 1;

    final sensorTypeId = NodeId.fromString(1, "SensorReadingType");
    final deviceTypeId = NodeId.fromString(1, "DeviceStatusType");
    final sensorNodeId = NodeId.fromString(1, "sensor.reading.1");
    final deviceNodeId = NodeId.fromString(1, "device.status.1");

    setUp(() async {
      serverA = setupServer(portA);
      serverB = setupServer(portB);
      clientA = await setupClient(portA);
      clientB = await setupClient(portB);
    });

    tearDown(() async {
      await clientA?.delete();
      await clientB?.delete();
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      serverA?.shutdown();
      serverA?.delete();
      serverB?.shutdown();
      serverB?.delete();
    });

    void registerSensorType(Server server) {
      server.addCustomType(sensorTypeId, buildSensorReadingSchema(sensorTypeId));
      server.addDataTypeNode(sensorTypeId, "SensorReadingType",
          displayName: LocalizedText("Sensor Reading Type", "en-US"));
    }

    void registerDeviceType(Server server) {
      server.addCustomType(deviceTypeId, buildDeviceStatusSchema(deviceTypeId));
      server.addDataTypeNode(deviceTypeId, "DeviceStatusType",
          displayName: LocalizedText("Device Status Type", "en-US"));
    }

    test('simple struct: Server A -> Client A -> Server B -> Client B', () async {
      // 1. Server A defines custom type and adds a node with data
      registerSensorType(serverA!);
      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 23.5, pressure: 1013, valid: true),
        typeId: sensorTypeId,
      );

      // 2. Client A reads the struct from Server A
      final readFromA = await clientA!.read(sensorNodeId);
      expect(readFromA.isObject, isTrue, reason: 'Should be a struct');
      expect(readFromA.asObject.length, 3, reason: 'Should have 3 fields');
      expect(readFromA["temperature"].value, 23.5);
      expect(readFromA["pressure"].value, 1013);
      expect(readFromA["valid"].value, true);

      // 3. Server B registers the same type and replicates data from Client A's read
      registerSensorType(serverB!);
      final replica = DynamicValue(name: "sensor.reading.1", typeId: sensorTypeId);
      replica["temperature"] = DynamicValue(value: readFromA["temperature"].value, typeId: NodeId.double);
      replica["pressure"] = DynamicValue(value: readFromA["pressure"].value, typeId: NodeId.int32);
      replica["valid"] = DynamicValue(value: readFromA["valid"].value, typeId: NodeId.boolean);
      serverB!.addVariableNode(sensorNodeId, replica, typeId: sensorTypeId);

      // 4. Client B reads from Server B and verifies the aggregated data
      final readFromB = await clientB!.read(sensorNodeId);
      expect(readFromB.isObject, isTrue, reason: 'Server B should serve a struct');
      expect(readFromB["temperature"].value, 23.5, reason: 'Temperature should match');
      expect(readFromB["pressure"].value, 1013, reason: 'Pressure should match');
      expect(readFromB["valid"].value, true, reason: 'Valid flag should match');
    });

    test('multiple custom types aggregated from Server A to Server B', () async {
      // 1. Server A has two different custom types
      registerSensorType(serverA!);
      registerDeviceType(serverA!);

      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: -40.0, pressure: 500, valid: false),
        typeId: sensorTypeId,
      );
      serverA!.addVariableNode(
        deviceNodeId,
        makeDeviceStatus(deviceTypeId, "device.status.1",
            deviceId: 42, online: true, errorCode: 0),
        typeId: deviceTypeId,
      );

      // 2. Client A reads both custom structs
      final sensorFromA = await clientA!.read(sensorNodeId);
      final deviceFromA = await clientA!.read(deviceNodeId);
      expect(sensorFromA.isObject, isTrue);
      expect(deviceFromA.isObject, isTrue);

      // 3. Server B registers both types and replicates
      registerSensorType(serverB!);
      registerDeviceType(serverB!);

      final sensorReplica = DynamicValue(name: "sensor.reading.1", typeId: sensorTypeId);
      sensorReplica["temperature"] = DynamicValue(value: sensorFromA["temperature"].value, typeId: NodeId.double);
      sensorReplica["pressure"] = DynamicValue(value: sensorFromA["pressure"].value, typeId: NodeId.int32);
      sensorReplica["valid"] = DynamicValue(value: sensorFromA["valid"].value, typeId: NodeId.boolean);

      final deviceReplica = DynamicValue(name: "device.status.1", typeId: deviceTypeId);
      deviceReplica["deviceId"] = DynamicValue(value: deviceFromA["deviceId"].value, typeId: NodeId.int32);
      deviceReplica["online"] = DynamicValue(value: deviceFromA["online"].value, typeId: NodeId.boolean);
      deviceReplica["errorCode"] = DynamicValue(value: deviceFromA["errorCode"].value, typeId: NodeId.int32);

      serverB!.addVariableNode(sensorNodeId, sensorReplica, typeId: sensorTypeId);
      serverB!.addVariableNode(deviceNodeId, deviceReplica, typeId: deviceTypeId);

      // 4. Client B reads both types from Server B
      final sensorFromB = await clientB!.read(sensorNodeId);
      expect(sensorFromB["temperature"].value, -40.0);
      expect(sensorFromB["pressure"].value, 500);
      expect(sensorFromB["valid"].value, false);

      final deviceFromB = await clientB!.read(deviceNodeId);
      expect(deviceFromB["deviceId"].value, 42);
      expect(deviceFromB["online"].value, true);
      expect(deviceFromB["errorCode"].value, 0);
    });

    test('client writes updated struct, then aggregate to server B', () async {
      // 1. Server A with sensor type
      registerSensorType(serverA!);
      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 20.0, pressure: 1000, valid: true),
        typeId: sensorTypeId,
      );

      // 2. Client A writes updated values
      final updated = makeSensorReading(sensorTypeId, "sensor.reading.1",
          temperature: 99.9, pressure: 2000, valid: false);
      await clientA!.write(sensorNodeId, updated);

      // 3. Read back the updated values
      final readAfterUpdate = await clientA!.read(sensorNodeId);
      expect(readAfterUpdate["temperature"].value, 99.9);
      expect(readAfterUpdate["pressure"].value, 2000);

      // 4. Aggregate to Server B
      registerSensorType(serverB!);
      final replica = DynamicValue(name: "sensor.reading.1", typeId: sensorTypeId);
      replica["temperature"] = DynamicValue(value: readAfterUpdate["temperature"].value, typeId: NodeId.double);
      replica["pressure"] = DynamicValue(value: readAfterUpdate["pressure"].value, typeId: NodeId.int32);
      replica["valid"] = DynamicValue(value: readAfterUpdate["valid"].value, typeId: NodeId.boolean);
      serverB!.addVariableNode(sensorNodeId, replica, typeId: sensorTypeId);

      // 5. Client B verifies updated values
      final readFromB = await clientB!.read(sensorNodeId);
      expect(readFromB["temperature"].value, 99.9);
      expect(readFromB["pressure"].value, 2000);
      expect(readFromB["valid"].value, false);
    });

    test('aggregation with basic types and custom types mixed', () async {
      // 1. Server A has both basic and custom type nodes
      addBasicVariables(serverA!);
      registerSensorType(serverA!);
      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 36.6, pressure: 760, valid: true),
        typeId: sensorTypeId,
      );

      // 2. Client A reads basic values
      final basicResults = await clientA!.readAttribute({
        boolNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        doubleNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        stringNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
      });
      // Client A reads the custom struct
      final sensorFromA = await clientA!.read(sensorNodeId);

      // 3. Replicate basic types to Server B
      for (final entry in basicResults.entries) {
        final data = entry.value;
        serverB!.addVariableNode(
          entry.key,
          DynamicValue(value: data.value, typeId: data.typeId, name: entry.key.toString()),
        );
      }

      // Replicate custom type to Server B
      registerSensorType(serverB!);
      final replica = DynamicValue(name: "sensor.reading.1", typeId: sensorTypeId);
      replica["temperature"] = DynamicValue(value: sensorFromA["temperature"].value, typeId: NodeId.double);
      replica["pressure"] = DynamicValue(value: sensorFromA["pressure"].value, typeId: NodeId.int32);
      replica["valid"] = DynamicValue(value: sensorFromA["valid"].value, typeId: NodeId.boolean);
      serverB!.addVariableNode(sensorNodeId, replica, typeId: sensorTypeId);

      // 4. Client B verifies all data
      final boolFromB = await clientB!.read(boolNodeId);
      expect(boolFromB.value, true, reason: 'Bool should match');

      final intFromB = await clientB!.read(intNodeId);
      expect(intFromB.value, 1, reason: 'Int should match');

      final doubleFromB = await clientB!.read(doubleNodeId);
      expect(doubleFromB.value, closeTo(3.14, 0.001), reason: 'Double should match');

      final stringFromB = await clientB!.read(stringNodeId);
      expect(stringFromB.value, "Hello World!", reason: 'String should match');

      final sensorFromB = await clientB!.read(sensorNodeId);
      expect(sensorFromB.isObject, isTrue, reason: 'Sensor should be struct');
      expect(sensorFromB["temperature"].value, 36.6, reason: 'Temp should match');
      expect(sensorFromB["pressure"].value, 760, reason: 'Pressure should match');
    });

    test('live monitoring: custom struct changes on A propagate to B', () async {
      // 1. Both servers have the sensor type
      registerSensorType(serverA!);
      registerSensorType(serverB!);

      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 10.0, pressure: 900, valid: true),
        typeId: sensorTypeId,
      );
      serverB!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 10.0, pressure: 900, valid: true),
        typeId: sensorTypeId,
      );

      // 2. Client A monitors Server A for changes
      final sub = await clientA!.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 10),
      );

      final receivedValues = <DynamicValue>[];
      final completer = Completer<void>();
      final stream = clientA!.monitor(
        sensorNodeId,
        sub,
        samplingInterval: Duration(milliseconds: 10),
      );

      final subscription = stream.listen((data) {
        receivedValues.add(data);
        // When we get updated data, replicate to Server B
        if (data.isObject) {
          serverB!.write(sensorNodeId, data);
        }
        // initial + 2 writes = 3 values
        if (receivedValues.length >= 3 && !completer.isCompleted) {
          completer.complete();
        }
      });

      await Future.delayed(Duration(milliseconds: 300));

      // 3. Write changes to Server A via Client A
      await clientA!.write(sensorNodeId,
          makeSensorReading(sensorTypeId, "sensor.reading.1",
              temperature: 50.0, pressure: 1100, valid: true));
      await Future.delayed(Duration(milliseconds: 300));

      await clientA!.write(sensorNodeId,
          makeSensorReading(sensorTypeId, "sensor.reading.1",
              temperature: -10.0, pressure: 800, valid: false));

      // 4. Wait for changes to propagate
      await completer.future.timeout(Duration(seconds: 10));
      await subscription.cancel();

      // 5. Client B reads the final state
      final readFromB = await clientB!.read(sensorNodeId);
      expect(readFromB.isObject, isTrue);
      expect(readFromB["temperature"].value, -10.0, reason: 'Temperature should be last value');
      expect(readFromB["pressure"].value, 800, reason: 'Pressure should be last value');
      expect(readFromB["valid"].value, false, reason: 'Valid should be last value');
    });

    test('browse custom type nodes from aggregated server', () async {
      // 1. Server A has custom type nodes plus basic nodes
      addBasicVariables(serverA!);
      registerSensorType(serverA!);
      serverA!.addVariableNode(
        sensorNodeId,
        makeSensorReading(sensorTypeId, "sensor.reading.1",
            temperature: 25.0, pressure: 1013, valid: true),
        typeId: sensorTypeId,
      );

      // 2. Client A browses Server A's Objects folder
      final browseA = await clientA!.browse(NodeId.objectsFolder);
      expect(browseA, isNotEmpty);

      final nodeIds = browseA.map((i) => i.nodeId).toSet();
      expect(nodeIds.contains(boolNodeId), isTrue, reason: 'Should find bool node');
      expect(nodeIds.contains(sensorNodeId), isTrue, reason: 'Should find sensor node');

      // 3. Replicate variable nodes from browse to Server B
      registerSensorType(serverB!);

      for (final item in browseA) {
        if (item.nodeClass == NodeClass.UA_NODECLASS_VARIABLE) {
          final data = await clientA!.read(item.nodeId);
          if (data.typeId != null) {
            try {
              serverB!.addVariableNode(
                item.nodeId,
                DynamicValue(
                  value: data.value,
                  typeId: data.typeId,
                  name: item.displayName,
                ),
                typeId: data.isObject ? data.typeId : null,
              );
            } catch (_) {
              // Skip unsupported types
            }
          }
        }
      }

      // 4. Client B browses Server B and finds the replicated nodes
      final browseB = await clientB!.browse(NodeId.objectsFolder);
      final nodeIdsB = browseB.map((i) => i.nodeId).toSet();
      expect(nodeIdsB.contains(sensorNodeId), isTrue,
          reason: 'Server B should have the sensor node');
    });
  }, timeout: Timeout(Duration(seconds: 120)));
}
