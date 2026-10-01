// A monitored value's QUALITY and SOURCE TIME must reach Dart.
//
// Before this suite existed the monitored-item callback read `value.ref.status`
// only to throw the sample away: anything but Good became
// `controller.addError('Failed to read value: <english>')` and returned, and
// `value.ref.sourceTimestamp` was never read at all. A consumer could therefore
// only ever say "the moment I heard about it", and could not say
// BadOutOfRange at all.
//
// What UA_DataValue actually carries, MEASURED against the in-process server on
// 2026-09-01 (macOS arm64, open62541 as pinned by hook/build.dart) rather than
// assumed. ffigen does not emit the C bitfield members individually; the
// generated struct ends with a single `@UA_Byte() external int substitute`,
// which IS the packed storage unit for the six flags. Bit positions follow the
// C declaration order in `include/open62541/types.h`:
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
import 'common.dart' show clientTypes, freeTcpPort, setupClientOfType;

final goodNodeId = NodeId.fromString(1, "the.int");
final refusingNodeId = NodeId.fromString(1, "the.refusing");
final tickZeroNodeId = NodeId.fromString(1, "the.tickZero");

/// What the data-source read dispatcher returns when `onRead` throws.
/// `UA_STATUSCODE_BADINTERNALERROR`.
const badInternalError = 0x80020000;

/// What a monitored item samples once its node has been deleted.
/// `UA_STATUSCODE_BADNODEIDUNKNOWN`.
const badNodeIdUnknown = 0x80340000;

/// What the default path puts on the error channel: since 1.5.7+3 a typed
/// [UaStatusException] carrying the exact notification status (for two years
/// before that it was an English string). The opt-in flag must not move it —
/// a caller that never asked for qualities keeps getting the typed error.
final legacyBadStatusMatcher = isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', badInternalError);

void main() {
  late int port;

  late Server server;
  late Client client;
  late Timer serverTimer;
  late Timer clientTimer;

  setUp(() async {
    port = await freeTcpPort();
    server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    server.start();

    server.addVariableNode(goodNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
    // A node the server itself answers Bad for: the data-source read dispatcher
    // turns a throwing `onRead` into BadInternalError. This is the only way to
    // get a REAL non-Good status onto the wire from the in-process server —
    // faking one in Dart would test the test.
    server.addDataSourceVariableNode(
      refusingNodeId,
      browseName: "the.refusing",
      typeId: NodeId.int32,
      onRead: () => throw StateError('this tag is unreadable on purpose'),
    );

    // A node whose source stamps its value with UA_DateTime tick 0: the flag
    // hasSourceTimestamp is SET on the wire and the field under it is the OPC
    // UA null timestamp.
    server.addDataSourceVariableNode(
      tickZeroNodeId,
      browseName: "the.tickZero",
      typeId: NodeId.int32,
      onReadValue: () => DataSourceValue(
        value: DynamicValue(value: 7, typeId: NodeId.int32),
        sourceTimestamp: DateTime.utc(1601, 1, 1),
      ),
    );

    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) => server.runIterate());

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) => client.runIterate(Duration(milliseconds: 10)));

    await client.connect("opc.tcp://127.0.0.1:$port");
  });

  tearDown(() async {
    clientTimer.cancel();
    serverTimer.cancel();
    server.shutdown();
    await client.delete();
    server.delete();
  });

  group('UA_DateTime conversion', () {
    test('a known instant converts, so an off-by-369-years is caught', () {
      // UA_DateTime counts 100 ns ticks from the Windows FILETIME epoch
      // (1601-01-01T00:00:00Z), not the Unix one. The two are 11644473600
      // seconds apart, and getting that constant wrong is the classic failure
      // here — invisible without a fixed-value assertion.
      expect(
        uaDateTimeToDateTime(10),
        DateTime.utc(1601, 1, 1, 0, 0, 0, 0, 1),
        reason:
            'ten ticks are one microsecond past the FILETIME epoch; if this '
            'drifts, every plant timestamp the gateway publishes is wrong by a '
            'constant',
      );
      expect(
        uaDateTimeToDateTime(11644473600 * 10000000),
        DateTime.utc(1970, 1, 1),
        reason:
            'the Unix epoch sits 11644473600 s after the FILETIME epoch; a '
            'wrong constant here reads as "the value is 369 years stale"',
      );
      // A tick value MEASURED off this server on 2026-09-01. Asserted to the
      // microsecond, which is DateTime's own resolution: a 100 ns tick has a
      // sub-microsecond tail that Dart cannot hold, and rounding it away in the
      // helper to make a coarser expectation pass would throw away real
      // precision to flatter the test.
      expect(
        uaDateTimeToDateTime(134327675499800940),
        DateTime.fromMicrosecondsSinceEpoch(1788293949980094, isUtc: true),
        reason:
            'a tick value MEASURED off this server on 2026-09-01 must land '
            'in 2026, not in 1601 and not in 2395',
      );
    });
  });

  // Regression tests for the review of PR #118: the exported helper replaced
  // one that answered null for tick 0, and Client.readValue silently started
  // dating such values to the year 1601.
  group('UA_DateTime tick 0 is the null timestamp', () {
    test('uaDateTimeToDateTime(0) is null, not 1601-01-01', () {
      expect(
        uaDateTimeToDateTime(0),
        isNull,
        reason: 'tick 0 is the OPC UA null timestamp ("no time"), not an instant in the year 1601',
      );
    });

    for (final clientType in clientTypes) {
      group('[$clientType]', () {
        ClientApi? own;
        // The direct client is the one every test here already has; an
        // isolate-backed one is connected on demand and deleted afterwards.
        Future<ClientApi> clientOfType() async =>
            clientType == 'direct' ? client : own = await setupClientOfType(clientType, "opc.tcp://127.0.0.1:$port");

        tearDown(() async {
          await own?.delete();
          own = null;
        });

        test('readValue reports a source timestamp of tick 0 as null', () async {
          final api = await clientOfType();

          final dataValue = await api.readValue(tickZeroNodeId);

          expect(dataValue.value.value, 7, reason: 'anti-vacuity: the read must have reached the data source');
          expect(
            dataValue.sourceTimestamp,
            isNull,
            reason: 'hasSourceTimestamp over tick 0 is "no timestamp", as readValue reported before this branch',
          );
        });

        test('a monitored sample with a source timestamp of tick 0 carries a null sourceTimestamp', () async {
          final api = await clientOfType();
          final subId = await api.subscriptionCreate();

          final value = await api
              .monitor(tickZeroNodeId, subId)
              .firstWhere((v) => v.value != null)
              .timeout(Duration(seconds: 10));

          expect(value.value, 7, reason: 'anti-vacuity: the sample must have reached the data source');
          expect(value.statusCode, UA_STATUSCODE_GOOD);
          expect(
            value.sourceTimestamp,
            isNull,
            reason: 'the monitor path must agree with readValue: tick 0 is no timestamp, not 1601-01-01',
          );
        });
      });
    }
  });

  group('DynamicValue carries quality and source time', () {
    test('a value that was never monitored has neither', () {
      // Anti-vacuity: the fields must be genuinely absent by default, or every
      // assertion below could be passing on a hardcoded constant.
      final fresh = DynamicValue();
      expect(
        fresh.statusCode,
        isNull,
        reason:
            'a hand-built value has no quality from any server; claiming '
            'Good (0) here would be the gateway inventing a promise',
      );
      expect(
        fresh.sourceTimestamp,
        isNull,
        reason:
            'a hand-built value has no source time; a plausible instant '
            'here is worse than none',
      );
    });

    test('DynamicValue.from carries both through the copy', () {
      final original = DynamicValue(value: 7, typeId: NodeId.int32);
      original.statusCode = badInternalError;
      original.sourceTimestamp = DateTime.utc(2026, 9, 1, 12, 34, 56);

      final copy = DynamicValue.from(original);

      expect(
        copy.statusCode,
        badInternalError,
        reason:
            'the copy constructor is on every path a value takes through '
            'the binding; a field it drops is a quality silently upgraded to '
            'Good somewhere downstream',
      );
      expect(
        copy.sourceTimestamp,
        DateTime.utc(2026, 9, 1, 12, 34, 56),
        reason:
            'same for the source time: a dropped timestamp means the '
            'consumer substitutes arrival time and never knows it did',
      );
      expect(
        DynamicValue.from(DynamicValue()).statusCode,
        isNull,
        reason: 'copying a value that never had a quality must not mint one',
      );
    });
  });

  group('the monitor path', () {
    test('a Good sample arrives with statusCode 0 and a real sourceTimestamp', () async {
      final subId = await client.subscriptionCreate();
      final sub = client.monitor(goodNodeId, subId);

      final before = DateTime.now().toUtc();
      final value = await sub.firstWhere((v) => v.value != null).timeout(Duration(seconds: 10));
      final after = DateTime.now().toUtc();

      expect(
        value.asInt,
        42,
        reason:
            'anti-vacuity: if the value itself did not arrive, the quality '
            'assertions below are measuring an empty object',
      );
      expect(
        value.statusCode,
        UA_STATUSCODE_GOOD,
        reason:
            'the server said Good and the reading is trustworthy; a null '
            'here means the gateway cannot distinguish "healthy" from '
            '"never asked"',
      );
      // A window, never an instant: the timestamp is wall-clock-derived and the
      // server stamped it at some point between these two reads.
      expect(
        value.sourceTimestamp!.isAfter(before.subtract(Duration(seconds: 30))),
        isTrue,
        reason:
            'a sourceTimestamp at the year 1601 is the flag bug: the field '
            'was read without checking hasSourceTimestamp',
      );
      expect(
        value.sourceTimestamp!.isBefore(after.add(Duration(seconds: 30))),
        isTrue,
        reason:
            'a sourceTimestamp in the future means the FILETIME conversion '
            'overshot, and every freshness check downstream would read fresh '
            'forever',
      );
      // No teardown of `sub` here: firstWhere cancels the underlying
      // subscription when it completes, and this stream is single-subscription.
    });

    test('deliverBadStatus: false drops a Bad sample and says so, exactly as before', () async {
      final subId = await client.subscriptionCreate();

      final errors = <Object>[];
      final values = <DynamicValue>[];
      final gotError = Completer<void>();
      final sub = client
          .monitor(refusingNodeId, subId)
          .listen(
            values.add,
            onError: (Object e) {
              errors.add(e);
              if (!gotError.isCompleted) gotError.complete();
            },
          );

      await gotError.future.timeout(Duration(seconds: 10));
      // Give the stream a beat to prove nothing ALSO arrived as a value.
      await Future<void>.delayed(Duration(milliseconds: 500));
      await sub.cancel();

      expect(
        errors.first,
        legacyBadStatusMatcher,
        reason:
            'a Bad sample on the default path is an error, and since 1.5.7+3 '
            'a TYPED one — the default must keep both the shape and the exact '
            'status code or this branch changes production behaviour on every '
            'plant',
      );
      expect(
        values.where((v) => v.statusCode != null),
        isEmpty,
        reason:
            'without opting in, a Bad sample is still dropped — the caller '
            'that never asked for qualities must not start receiving them',
      );
    });

    // Added after mutation testing: flipping monitoredItems' OWN default to
    // true survived the suite, because monitor() forwards the flag explicitly
    // and every case above went through monitor(). ClientWrapper in the app
    // reaches this method too, so an unpinned default here is threat T-08-01
    // with no tripwire — a one-word edit that changes what every panel on the
    // plant receives.
    test('monitoredItems has the same default, and it is pinned separately', () async {
      final subId = await client.subscriptionCreate();

      final errors = <Object>[];
      final delivered = <Map<NodeId, DynamicValue>>[];
      final gotError = Completer<void>();
      final sub = client
          .monitoredItems({
            refusingNodeId: [
              AttributeId.UA_ATTRIBUTEID_DATATYPE,
              AttributeId.UA_ATTRIBUTEID_VALUE,
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
              AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
            ],
          }, subId)
          .listen(
            delivered.add,
            onError: (Object e) {
              errors.add(e);
              if (!gotError.isCompleted) gotError.complete();
            },
          );

      await gotError.future.timeout(Duration(seconds: 10));
      await Future<void>.delayed(Duration(milliseconds: 500));
      await sub.cancel();

      expect(
        errors.first,
        legacyBadStatusMatcher,
        reason:
            'this is the entry point ClientWrapper uses; its default must '
            'drop a Bad sample exactly as monitor() does, or the app starts '
            'receiving values it has never been written to interpret',
      );
      expect(
        delivered.expand((m) => m.values).where((v) => v.statusCode != null),
        isEmpty,
        reason:
            'anti-vacuity for the arm above: an error arriving is only half '
            'the promise — nothing may ALSO arrive as a value',
      );
    });

    test('deliverBadStatus: true delivers the Bad sample with the server\'s own code', () async {
      final subId = await client.subscriptionCreate();

      final errors = <Object>[];
      final values = <DynamicValue>[];
      final gotBad = Completer<DynamicValue>();
      final sub = client.monitor(refusingNodeId, subId, deliverBadStatus: true).listen((v) {
        values.add(v);
        if (v.statusCode != null && v.statusCode != UA_STATUSCODE_GOOD && !gotBad.isCompleted) {
          gotBad.complete(v);
        }
      }, onError: errors.add);

      final bad = await gotBad.future.timeout(Duration(seconds: 10));
      await sub.cancel();

      expect(
        bad.statusCode,
        badInternalError,
        reason:
            'the relay maps the server\'s numeric StatusCode onto a relay '
            'Quality; an English string on the error channel cannot say '
            'BadOutOfRange to an operator',
      );
      expect(
        values,
        isNotEmpty,
        reason:
            'anti-vacuity: the sample must arrive AS A VALUE, not merely '
            'not-as-an-error',
      );
      expect(
        bad.sourceTimestamp,
        isNotNull,
        reason:
            'the measured Bad sample carries hasSourceTimestamp set — the '
            'server knows when it decided the tag was unreadable, and that is '
            'the age the operator needs',
      );
    });
  });

  for (final clientType in clientTypes) {
    // Regression tests for the review of PR #118: two samples the monitor path
    // misreported, and that no test looked at.
    group('the monitor path [$clientType]', () {
      ClientApi? own;

      tearDown(() async {
        await own?.delete();
        own = null;
      });

      test('deliverBadStatus: true reports a Bad notification of a non-Value attribute as an error', () async {
        final api = clientType == 'direct'
            ? client
            : own = await setupClientOfType(clientType, "opc.tcp://127.0.0.1:$port");
        final subId = await api.subscriptionCreate();

        final names = <String?>[];
        final errors = <Object>[];
        final gotName = Completer<void>();
        final gotError = Completer<void>();
        final sub = api
            .monitoredItems(
              {
                goodNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
              },
              subId,
              deliverBadStatus: true,
            )
            .listen(
              (event) {
                names.add(event[goodNodeId]?.displayName?.value);
                if (!gotName.isCompleted) gotName.complete();
              },
              onError: (Object e) {
                errors.add(e);
                if (!gotError.isCompleted) gotError.complete();
              },
            );
        addTearDown(sub.cancel);

        await gotName.future.timeout(Duration(seconds: 10));
        // With the node gone, the DisplayName item samples BadNodeIdUnknown.
        server.deleteNode(goodNodeId);
        await gotError.future.timeout(Duration(seconds: 10), onTimeout: () {});

        expect(
          errors,
          [isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', badNodeIdUnknown)],
          reason:
              'a DynamicValue has no field for the status of a DisplayName, so '
              'deliverBadStatus cannot deliver it as a value; swallowing it '
              'leaves the caller with neither a value nor an error',
        );
        expect(names.toSet(), {'the.int'}, reason: 'the Bad sample carries no DisplayName; the last known one stays');
      });
    });
  }
}
