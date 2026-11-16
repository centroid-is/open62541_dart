// Regression test: writing a value whose typeId is a vendor DataType.
//
// Symptom
//   Beckhoff TwinCAT publishes a PLC `TIME` under its own DataType
//   (ns=3;i=3005, a HasSubtype child of Int64) and sends the value as an
//   Int64. Client.read reports that DataType as the value's typeId, so the
//   ordinary read -> change -> write failed in the client, before anything
//   was sent:
//     ArgumentError: Unknown Namespace0Id value: 3005
//   valueToVariant looked the numeric part of the typeId up among the NS0
//   types and ignored the namespace. Writing with the vendor DataType given
//   explicitly failed the same way.
//
// Fix
//   Client.write resolves a DataType it cannot encode to the built-in type it
//   derives from (walking HasSubtype up to namespace 0) and writes the value
//   as that type. Client.read is unchanged: typeId stays the node's DataType.
//
// Fixture
//   An in-process Server with the same shape as TwinCAT: a DataType
//   ns=1;i=3005 subtyping Int64, and variables of that type.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show clientTypes, readWrite, setupClientOfType, setupServer;

// The numeric id matters: the bug looked the number (3005) up in NS0.
final timeType = NodeId.fromNumeric(1, 3005);
// A DataType deriving from timeType: the client has to walk two levels.
final shortTimeType = NodeId.fromNumeric(1, 3006);
// A string alias with a string NodeId (TwinCAT's STRING is a vendor alias too).
final textType = NodeId.fromString(1, 'Text');

final timeVar = NodeId.fromString(1, 'MAIN.timeTest');
final shortTimeVar = NodeId.fromString(1, 'MAIN.shortTime');
final timeArrayVar = NodeId.fromString(1, 'MAIN.timeArray');
final textVar = NodeId.fromString(1, 'MAIN.text');
// An NS0 subtype the client has no encoder for either: Duration (i=290) is a
// Double.
final durationType = NodeId.fromNumeric(0, 290);
final durationVar = NodeId.fromString(1, 'MAIN.duration');

void main() {
  late Server server;

  setUpAll(() {
    server = setupServer();
    server.addDataTypeNode(timeType, 'TIME', parentNodeId: NodeId.int64);
    server.addDataTypeNode(shortTimeType, 'SHORT_TIME', parentNodeId: timeType);
    server.addDataTypeNode(textType, 'TEXT', parentNodeId: NodeId.uastring);

    server.addVariableNode(
      timeVar,
      DynamicValue(value: 0, typeId: NodeId.int64, name: 'timeTest'),
      typeId: timeType,
      accessLevel: readWrite,
    );
    server.addVariableNode(
      shortTimeVar,
      DynamicValue(value: 0, typeId: NodeId.int64, name: 'shortTime'),
      typeId: shortTimeType,
      accessLevel: readWrite,
    );
    server.addVariableNode(
      timeArrayVar,
      DynamicValue.fromList([1, 2, 3], typeId: NodeId.int64, name: 'timeArray'),
      typeId: timeType,
      accessLevel: readWrite,
    );
    server.addVariableNode(
      textVar,
      DynamicValue(value: 'hello', typeId: NodeId.uastring, name: 'text'),
      typeId: textType,
      accessLevel: readWrite,
    );
    server.addVariableNode(
      durationVar,
      DynamicValue(value: 0.0, typeId: NodeId.double, name: 'duration'),
      typeId: durationType,
      accessLevel: readWrite,
    );
  });

  tearDownAll(() {
    server.shutdown();
    server.delete();
  });

  for (final clientType in clientTypes) {
    group('[$clientType]', () {
      late ClientApi client;
      setUpAll(() async => client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}'));
      tearDownAll(() async => client.delete());

      test('read reports the vendor DataType (unchanged)', () async {
        final v = await client.read(timeVar);
        expect(v.typeId, timeType);
        expect(v.value, isA<int>());
      });

      test('read -> change -> write round-trips', () async {
        final v = await client.read(timeVar);
        v.value = 1500;
        await client.write(timeVar, v);
        expect((await client.read(timeVar)).value, 1500);
      });

      test('a value built with the vendor DataType is written', () async {
        await client.write(timeVar, DynamicValue(value: 4294967295, typeId: timeType));
        expect((await client.read(timeVar)).value, 4294967295);
      });

      test('the write travels as the built-in type', () async {
        await client.write(timeVar, DynamicValue(value: 42, typeId: timeType));
        expect((await client.readValue(timeVar)).value.typeId, NodeId.int64);
      });

      test('a DataType two levels below the built-in type', () async {
        final v = await client.read(shortTimeVar);
        expect(v.typeId, shortTimeType);
        v.value = 250;
        await client.write(shortTimeVar, v);
        expect((await client.read(shortTimeVar)).value, 250);
      });

      test('an array of the vendor DataType', () async {
        final v = await client.read(timeArrayVar);
        expect(v.typeId, timeType);
        expect(v.isArray, isTrue);
        await client.write(timeArrayVar, DynamicValue.fromList([10, 20, 30, 40], typeId: timeType));
        final got = await client.read(timeArrayVar);
        expect([for (var i = 0; i < 4; i++) got[i].asInt], [10, 20, 30, 40]);
      });

      test('a string alias with a string NodeId', () async {
        final v = await client.read(textVar);
        expect(v.typeId, textType);
        v.value = 'world';
        await client.write(textVar, v);
        expect((await client.read(textVar)).value, 'world');
      });

      test('an NS0 subtype (Duration) goes as its built-in type (Double)', () async {
        final v = await client.read(durationVar);
        expect(v.typeId, durationType);
        v.value = 250.5;
        await client.write(durationVar, v);
        expect((await client.read(durationVar)).value, 250.5);
      });

      test('a DataType with no built-in supertype is a clear error', () async {
        // No such node on the server: nothing to derive a built-in type from.
        // (Across the ClientIsolate boundary the ArgumentError arrives as its
        // text, so the message is checked on toString.)
        final bogus = NodeId.fromNumeric(1, 99999);
        await expectLater(
          client.write(timeVar, DynamicValue(value: 1, typeId: bogus)),
          throwsA(
            predicate(
              (Object e) => e.toString().contains('ns=1;i=99999') && !e.toString().contains('Namespace0Id'),
              'an error naming ns=1;i=99999 (not "Unknown Namespace0Id")',
            ),
          ),
        );
        // Nothing was written.
        expect((await client.read(timeVar)).value, isNot(1));
      });
    });
  }
}
