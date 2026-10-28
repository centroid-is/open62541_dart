// A monitored value's QUALITY and SOURCE TIME must reach Dart.
//
// The monitored-item callback used to read `value.ref.status` only to throw
// the sample away: anything but Good became
// `controller.addError(UaStatusException(status))` and returned, and
// `value.ref.sourceTimestamp` was never read at all. A consumer could
// therefore only ever say "the moment I heard about it", and saw BadOutOfRange
// as a stream error, never on a value. `monitor` / `monitoredItems` still do
// exactly that (pinned below); `monitorDataValue` / `monitoredDataValues`
// deliver every sample as a DataValue with its status and timestamps.
//
// What UA_DataValue actually carries, MEASURED against the in-process server
// rather than assumed. ffigen does not emit the C bitfield members
// individually; the generated struct ends with a single
// `@UA_Byte() external int substitute`, which IS the packed storage unit for
// the six flags. Bit positions follow the C declaration order in
// `include/open62541/types.h`:
//
//     bit 0 (0x01)  hasValue
//     bit 1 (0x02)  hasStatus
//     bit 2 (0x04)  hasSourceTimestamp
//     bit 3 (0x08)  hasServerTimestamp
//     bit 4 (0x10)  hasSourcePicoseconds
//     bit 5 (0x20)  hasServerPicoseconds
//
// Observed notifications for a four-attribute monitor of a healthy Int32:
//     VALUE        status=0x0        substitute=0b00000101  src=1343276754998...
//     DATATYPE     status=0x0        substitute=0b00000001  src=0
//     DESCRIPTION  status=0x0        substitute=0b00000001  src=0
//     DISPLAYNAME  status=0x0        substitute=0b00000001  src=0
// and for a data-source node whose read refuses:
//     VALUE        status=0x80020000 substitute=0b00000110  src=1343276755242...
//
// Three consequences the implementation must respect, each pinned below:
//   1. Only the VALUE attribute carries a sourceTimestamp; the other three
//      arrive with src=0 and hasSourceTimestamp clear. Recording a timestamp
//      from those would clobber the real one with the year 1601.
//   2. A Bad sample has hasValue CLEAR — there is no payload to decode. Its
//      quality is still news.
//   3. hasStatus is clear on a Good sample and the status field reads 0, which
//      is exactly UA_STATUSCODE_GOOD. An absent status means Good (OPC UA Part
//      4); the raw field is therefore safe to record unconditionally.
//
// The default lane runs this file on purpose: an `integration`/`plc` tag would
// make it local-only and it would prove nothing in CI.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show clientTypes, setupClientOfType;
import 'data_value_rewriting_proxy.dart';

final goodNodeId = NodeId.fromString(1, "the.int");
final otherNodeId = NodeId.fromString(1, "the.other");
final refusingNodeId = NodeId.fromString(1, "the.refusing");
final tickZeroNodeId = NodeId.fromString(1, "the.tickZero");
final lastKnownNodeId = NodeId.fromString(1, "the.lastKnown");
final flakyNodeId = NodeId.fromString(1, "the.flaky");
final doomedNodeId = NodeId.fromString(1, "the.doomed");

/// What the data-source read dispatcher returns when `onRead` throws.
/// `UA_STATUSCODE_BADINTERNALERROR`.
const badInternalError = 0x80020000;

/// What a monitored item samples once its node has been deleted.
/// `UA_STATUSCODE_BADNODEIDUNKNOWN`.
const badNodeIdUnknown = 0x80340000;

/// `UA_STATUSCODE_BADNOCOMMUNICATION`.
const badNoCommunication = 0x80310000;

/// What the default path puts on the error channel: since 1.5.7+3 a typed
/// [UaStatusException] carrying the exact notification status (for two years
/// before that it was an English string). The DataValue API must not move it:
/// a caller that never asked for qualities keeps getting the typed error.
final legacyBadStatusMatcher = isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', badInternalError);

/// The client types the DataValue monitoring API is available on: both. On
/// ClientIsolate every event crosses the SendPort as a `Map<NodeId, DataValue>`.
const monitoringClientTypes = clientTypes;

void main() {
  group('UA_DateTime conversion', () {
    test('a known instant converts, so an off-by-369-years is caught', () {
      // UA_DateTime counts 100 ns ticks from the Windows FILETIME epoch
      // (1601-01-01T00:00:00Z), not the Unix one. The two are 11644473600
      // seconds apart, and getting that constant wrong is the classic failure
      // here — invisible without a fixed-value assertion.
      expect(
        uaDateTimeToDateTime(10),
        DateTime.utc(1601, 1, 1, 0, 0, 0, 0, 1),
        reason: 'ten ticks are one microsecond past the FILETIME epoch',
      );
      expect(
        uaDateTimeToDateTime(11644473600 * 10000000),
        DateTime.utc(1970, 1, 1),
        reason: 'the Unix epoch sits 11644473600 s after the FILETIME epoch',
      );
      // A tick value MEASURED off this server on 2026-09-01. Asserted to the
      // microsecond, which is DateTime's own resolution.
      expect(
        uaDateTimeToDateTime(134327675499800940),
        DateTime.fromMicrosecondsSinceEpoch(1788293949980094, isUtc: true),
        reason: 'a tick value measured off this server must land in 2026, not in 1601 and not in 2395',
      );
    });

    test('tick 0 is the null timestamp, not 1601-01-01', () {
      expect(uaDateTimeToDateTime(0), isNull, reason: 'tick 0 is the OPC UA null timestamp ("no time")');
    });
  });

  for (final clientType in monitoringClientTypes) {
    group('[$clientType]', () {
      late Server server;
      late Timer serverTimer;
      late ClientApi api;
      late DataValueMonitoringApi quality;
      var flakyRefuses = false;

      // One server and one client for the whole group: deleting a direct
      // client while its server shares the isolate costs seconds per test.
      setUpAll(() async {
        server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
        server.start();

        server.addVariableNode(goodNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
        server.addVariableNode(otherNodeId, DynamicValue(value: 1, typeId: NodeId.int32, name: "the.other"));
        server.addVariableNode(doomedNodeId, DynamicValue(value: 2, typeId: NodeId.int32, name: "the.doomed"));
        // A node the server itself answers Bad for: the data-source read
        // dispatcher turns a throwing `onRead` into BadInternalError. This is
        // the only way to get a REAL non-Good status onto the wire from the
        // in-process server — faking one in Dart would test the test.
        server.addDataSourceVariableNode(
          refusingNodeId,
          browseName: "the.refusing",
          typeId: NodeId.int32,
          onRead: () => throw StateError('this tag is unreadable on purpose'),
        );
        // A node that reads fine until the test says otherwise.
        server.addDataSourceVariableNode(
          flakyNodeId,
          browseName: "the.flaky",
          typeId: NodeId.int32,
          onRead: () {
            if (flakyRefuses) throw StateError('the device went quiet');
            return DynamicValue(value: 42, typeId: NodeId.int32);
          },
        );
        // A node whose source stamps its value with UA_DateTime tick 0: the
        // flag hasSourceTimestamp is SET on the wire and the field under it
        // is the OPC UA null timestamp.
        server.addDataSourceVariableNode(
          tickZeroNodeId,
          browseName: "the.tickZero",
          typeId: NodeId.int32,
          onReadValue: () => DataSourceValue(
            value: DynamicValue(value: 7, typeId: NodeId.int32),
            sourceTimestamp: DateTime.utc(1601, 1, 1),
          ),
        );
        // A node that answers Bad AND carries a value: the last-known reading
        // of a device that has gone quiet.
        server.addDataSourceVariableNode(
          lastKnownNodeId,
          browseName: "the.lastKnown",
          typeId: NodeId.int32,
          onReadValue: () => DataSourceValue(
            value: DynamicValue(value: 5, typeId: NodeId.int32),
            statusCode: badNoCommunication,
          ),
        );

        serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) => server.runIterate());

        api = await setupClientOfType(clientType, "opc.tcp://127.0.0.1:${server.port}");
        quality = api as DataValueMonitoringApi;
      });

      tearDownAll(() async {
        await api.delete();
        serverTimer.cancel();
        server.shutdown();
        server.delete();
      });

      /// Collects what [stream] emits and what it adds as errors, and gives
      /// the test a way to wait for the nth event or the first error.
      (List<T>, List<Object>, Future<void> Function(int)) collect<T>(Stream<T> stream) {
        final events = <T>[];
        final errors = <Object>[];
        final subscription = stream.listen(events.add, onError: errors.add);
        addTearDown(subscription.cancel);
        Future<void> untilEvents(int count) async {
          final deadline = DateTime.now().add(Duration(seconds: 10));
          while (events.length < count && errors.isEmpty) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for $count events; got ${events.length} and errors $errors');
            }
            await Future.delayed(Duration(milliseconds: 20));
          }
        }

        return (events, errors, untilEvents);
      }

      test('readValue reports a source timestamp of tick 0 as null', () async {
        final dataValue = await api.readValue(tickZeroNodeId);

        expect(dataValue.value.value, 7, reason: 'anti-vacuity: the read must have reached the data source');
        expect(dataValue.sourceTimestamp, isNull, reason: 'hasSourceTimestamp over tick 0 is "no timestamp"');
      });

      group('monitor / monitoredItems keep delivering the value alone', () {
        test('monitor drops a Bad sample and reports it as a typed error, exactly as before', () async {
          final subId = await api.subscriptionCreate();
          final (values, errors, _) = collect(api.monitor(refusingNodeId, subId));

          final deadline = DateTime.now().add(Duration(seconds: 10));
          while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future.delayed(Duration(milliseconds: 20));
          }
          // Give the stream a beat to prove nothing ALSO arrived as a value.
          await Future<void>.delayed(Duration(milliseconds: 500));

          expect(errors, isNotEmpty, reason: 'the refusing node must have produced a Bad sample');
          expect(
            errors.first,
            legacyBadStatusMatcher,
            reason:
                'a Bad sample on the default path is an error, and since 1.5.7+3 a TYPED one; the '
                'default must keep both the shape and the exact status code',
          );
          expect(values, isEmpty, reason: 'without opting in, a Bad sample is dropped: nothing arrives as a value');
        });

        // monitor() goes through monitoredItems(), but monitoredItems() is an
        // entry point of its own, so its behaviour is pinned separately.
        test('monitoredItems drops a Bad sample and reports it as a typed error, exactly as before', () async {
          final subId = await api.subscriptionCreate();
          final (delivered, errors, _) = collect(
            api.monitoredItems({
              refusingNodeId: [
                AttributeId.UA_ATTRIBUTEID_DATATYPE,
                AttributeId.UA_ATTRIBUTEID_VALUE,
                AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
                AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
              ],
            }, subId),
          );

          final deadline = DateTime.now().add(Duration(seconds: 10));
          while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future.delayed(Duration(milliseconds: 20));
          }
          await Future<void>.delayed(Duration(milliseconds: 500));

          expect(errors, isNotEmpty, reason: 'the refusing node must have produced a Bad sample');
          expect(errors.first, legacyBadStatusMatcher);
          expect(delivered, isEmpty, reason: 'anti-vacuity for the arm above: nothing may ALSO arrive as a value');
        });
      });

      group('monitorDataValue', () {
        test('a Good sample arrives with status Good and the server\'s timestamps', () async {
          final subId = await api.subscriptionCreate();

          final before = DateTime.now().toUtc();
          final value = await quality
              .monitorDataValue(goodNodeId, subId)
              .firstWhere((v) => v.value.value != null)
              .timeout(Duration(seconds: 10));
          final after = DateTime.now().toUtc();

          expect(value.value.asInt, 42, reason: 'anti-vacuity: the value itself must have arrived');
          expect(value.statusCode, UA_STATUSCODE_GOOD, reason: 'the server said Good (an absent status is Good)');
          expect(value.isGood, isTrue);
          // A window, never an instant: the timestamp is wall-clock-derived
          // and the server stamped it at some point between these two reads.
          expect(
            value.sourceTimestamp,
            isNotNull,
            reason: 'the in-process server stamps every Value sample with a source timestamp',
          );
          expect(
            value.sourceTimestamp!.isAfter(before.subtract(Duration(seconds: 30))),
            isTrue,
            reason: 'a sourceTimestamp at the year 1601 is the flag bug: the field was read without checking the flag',
          );
          expect(
            value.sourceTimestamp!.isBefore(after.add(Duration(seconds: 30))),
            isTrue,
            reason: 'a sourceTimestamp in the future means the FILETIME conversion overshot',
          );
          expect(value.serverTimestamp, isNotNull, reason: 'the in-process server stamps a server timestamp too');
          expect(value.serverTimestamp!.isAfter(before.subtract(Duration(seconds: 30))), isTrue);
          expect(value.serverTimestamp!.isBefore(after.add(Duration(seconds: 30))), isTrue);
        });

        test('a sample with a source timestamp of tick 0 carries a null sourceTimestamp', () async {
          final subId = await api.subscriptionCreate();

          final value = await quality
              .monitorDataValue(tickZeroNodeId, subId)
              .firstWhere((v) => v.value.value != null)
              .timeout(Duration(seconds: 10));

          expect(value.value.value, 7, reason: 'anti-vacuity: the sample must have reached the data source');
          expect(value.statusCode, UA_STATUSCODE_GOOD);
          expect(
            value.sourceTimestamp,
            isNull,
            reason: 'the monitor path must agree with readValue: tick 0 is no time',
          );
        });

        test('a Bad sample is delivered with the server\'s own code and no value', () async {
          final subId = await api.subscriptionCreate();
          final (values, errors, untilEvents) = collect(quality.monitorDataValue(refusingNodeId, subId));

          await untilEvents(1);

          expect(errors, isEmpty, reason: 'the quality travels on the value, not on the error channel');
          final bad = values.first;
          expect(
            bad.statusCode,
            badInternalError,
            reason: 'the server\'s numeric StatusCode, on the value it describes',
          );
          expect(bad.isBad, isTrue);
          expect(bad.value.isNull, isTrue, reason: 'the sample carries no value and there is no last known one');
          expect(
            bad.sourceTimestamp,
            isNotNull,
            reason: 'the measured Bad sample carries hasSourceTimestamp set: the server knows when it decided',
          );
        });

        test('a Bad sample that carries a value is delivered with that value', () async {
          final subId = await api.subscriptionCreate();

          final value = await quality.monitorDataValue(lastKnownNodeId, subId).first.timeout(Duration(seconds: 10));

          expect(
            (value.value.value, value.statusCode),
            (5, badNoCommunication),
            reason: 'a Bad sample that carries a value is decoded like any other',
          );
        });

        test('a Bad sample without a value keeps the last known value', () async {
          final subId = await api.subscriptionCreate();
          final (values, errors, untilEvents) = collect(quality.monitorDataValue(flakyNodeId, subId));

          await untilEvents(1);
          flakyRefuses = true;
          await untilEvents(2);

          expect(errors, isEmpty);
          expect((values[0].value.value, values[0].statusCode), (42, UA_STATUSCODE_GOOD));
          expect(
            (values[1].value.value, values[1].statusCode),
            (42, badInternalError),
            reason: 'the device went quiet: the last known value, marked with the Bad status the server sent',
          );
        });

        test('each event is a fresh DataValue over a fresh copy of the value', () async {
          final subId = await api.subscriptionCreate();
          final (values, _, untilEvents) = collect(quality.monitorDataValue(otherNodeId, subId));

          await untilEvents(1);
          server.write(otherNodeId, DynamicValue(value: 2, typeId: NodeId.int32));
          await untilEvents(2);

          expect(identical(values[0], values[1]), isFalse, reason: 'one object per event');
          expect(identical(values[0].value, values[1].value), isFalse, reason: 'one DynamicValue per event');
          expect(
            (values[0].value.value, values[1].value.value),
            (1, 2),
            reason: 'the first event still says 1 after the second arrived: it was not rewritten in place',
          );
          server.write(otherNodeId, DynamicValue(value: 1, typeId: NodeId.int32));
          await untilEvents(3);
        });
      });

      group('monitoredDataValues', () {
        test('one DataValue per node, each with its own quality', () async {
          final subId = await api.subscriptionCreate();
          final (events, errors, untilEvents) = collect(
            quality.monitoredDataValues({
              goodNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              lastKnownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            }, subId),
          );

          await untilEvents(1);

          expect(errors, isEmpty);
          final event = events.first;
          expect(event.keys.toSet(), {goodNodeId, lastKnownNodeId});
          expect((event[goodNodeId]!.value.value, event[goodNodeId]!.statusCode), (42, UA_STATUSCODE_GOOD));
          expect(
            (event[lastKnownNodeId]!.value.value, event[lastKnownNodeId]!.statusCode),
            (5, badNoCommunication),
            reason: 'one node\'s Bad status must not bleed into the other node\'s DataValue',
          );
        });

        test('a Bad notification of a non-Value attribute is reported as an error', () async {
          final subId = await api.subscriptionCreate();
          final (events, errors, untilEvents) = collect(
            quality.monitoredDataValues({
              doomedNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
            }, subId),
          );

          await untilEvents(1);
          // With the node gone, the DisplayName item samples BadNodeIdUnknown.
          server.deleteNode(doomedNodeId);
          final deadline = DateTime.now().add(Duration(seconds: 10));
          while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future.delayed(Duration(milliseconds: 20));
          }

          expect(
            errors,
            [isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', badNodeIdUnknown)],
            reason:
                'a DataValue has no field for the status of a DisplayName; swallowing it leaves the caller '
                'with neither a value nor an error',
          );
          expect(events.map((e) => e[doomedNodeId]?.value.displayName?.value).toSet(), {
            'the.doomed',
          }, reason: 'the Bad sample carries no DisplayName; the last known one stays');
        });

        group('through a rewriting proxy', () {
          late DataValueRewritingProxy proxy;
          late DataValueMonitoringApi proxied;

          setUp(() async {
            proxy = await DataValueRewritingProxy.start(server.port);
            proxied =
                await setupClientOfType(clientType, "opc.tcp://127.0.0.1:${proxy.port}") as DataValueMonitoringApi;
          });

          tearDown(() async {
            // The link goes first, so the delete does not wait on a server
            // that shares this isolate.
            await proxy.close();
            await (proxied as ClientApi).delete();
          });

          test('a sample without a source timestamp carries none, not the previous sample\'s', () async {
            // The in-process server stamps every Value sample, so the
            // timestamp is taken off the second notification on the wire.
            final subId = await (proxied as ClientApi).subscriptionCreate();
            final (events, _, untilEvents) = collect(
              proxied.monitoredDataValues({
                goodNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              }, subId),
            );

            await untilEvents(1);
            proxy.rewriteNotification = withoutSourceTimestamp;
            server.write(goodNodeId, DynamicValue(value: 43, typeId: NodeId.int32));
            await untilEvents(2);
            server.write(goodNodeId, DynamicValue(value: 42, typeId: NodeId.int32));

            expect(proxy.notificationRewrites, 1, reason: 'anti-vacuity: the second notification was rewritten');
            final first = events[0][goodNodeId]!;
            final second = events[1][goodNodeId]!;
            expect(first.value.value, 42);
            expect(
              first.sourceTimestamp,
              isNotNull,
              reason: 'anti-vacuity: the first sample has a timestamp to go stale',
            );
            expect((second.value.value, second.statusCode), (43, UA_STATUSCODE_GOOD));
            expect(
              second.sourceTimestamp,
              isNull,
              reason:
                  'this sample came without a source timestamp; keeping the previous sample\'s dates the new '
                  'value to the old value\'s instant',
            );
          });

          test('a sample the client cannot decode is an error event, and the stream goes on', () async {
            // A Guid (built-in type 14) is a value open62541 decodes and this
            // client has no conversion for: the sample reaches the monitor
            // callback and its conversion throws. Every notification is
            // rewritten until the first error has arrived, then the server
            // writes a value the proxy leaves alone.
            proxy.rewriteNotification = asGuid;
            final subId = await (proxied as ClientApi).subscriptionCreate();
            final events = <Map<NodeId, DataValue>>[];
            final errors = <Object>[];
            var done = false;
            final subscription = proxied
                .monitoredDataValues({
                  goodNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
                }, subId)
                .listen(events.add, onError: errors.add, onDone: () => done = true);
            addTearDown(subscription.cancel);

            Future<void> until(bool Function() condition, String what) async {
              final deadline = DateTime.now().add(Duration(seconds: 10));
              while (!condition()) {
                if (DateTime.now().isAfter(deadline)) {
                  fail('timed out waiting for $what; got events $events and errors $errors');
                }
                await Future.delayed(Duration(milliseconds: 20));
              }
            }

            await until(() => errors.isNotEmpty, 'the decode error');
            expect(proxy.notificationRewrites, greaterThan(0), reason: 'anti-vacuity: a notification was rewritten');
            expect(events, isEmpty, reason: 'the undecodable sample is not delivered as a value');
            expect(errors.first, isNot(isA<UaStatusException>()), reason: 'a decode error, not a Bad status');
            expect(done, isFalse, reason: 'the stream is not closed by one bad sample');

            // The next sample is left alone. (A second later the client may
            // also backfill the item it never saw a sample for with a read,
            // which is 42 or 44 depending on timing, so the wait is for 44.)
            proxy.rewriteNotification = null;
            server.write(goodNodeId, DynamicValue(value: 44, typeId: NodeId.int32));
            await until(
              () => events.any((event) => event[goodNodeId]?.value.value == 44),
              'the sample after the bad one',
            );
            server.write(goodNodeId, DynamicValue(value: 42, typeId: NodeId.int32));

            expect(done, isFalse, reason: 'the subscription survived the bad sample');
          });

          test('a Good sample without a value is delivered as a null value with status Good', () async {
            proxy.rewriteNotification = goodWithoutValue;
            final subId = await (proxied as ClientApi).subscriptionCreate();
            final (events, errors, untilEvents) = collect(
              proxied.monitoredDataValues({
                goodNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              }, subId),
            );

            await untilEvents(1);

            expect(proxy.notificationRewrites, greaterThan(0), reason: 'the notification must have been rewritten');
            expect(errors, isEmpty, reason: 'a Good empty sample is not an error');
            final sample = events.first[goodNodeId]!;
            expect(
              (sample.value.isNull, sample.statusCode),
              (true, UA_STATUSCODE_GOOD),
              reason: 'the server holds 42; the client was told "empty", with status Good',
            );
          });
        });
      });
    });
  }
}
