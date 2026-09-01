import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import '../example/metar_common.dart';
import '../example/metar_redundant_client.dart';
import '../example/metar_redundant_server.dart';
import 'common.dart';

/// In-process integration test for the redundant-METAR example.
///
/// Two [MetarRedundantServer]s run on OS-allocated ports with a FAKE
/// [MetarSource], so the suite never touches the network. A
/// [MetarFailoverClient] then has to:
///
///   * pick the server with the highest `Server/ServiceLevel` (ns=0;i=2267),
///   * discover its peer from `ServerUriArray` (ns=0;i=11314) rather than
///     being told about it,
///   * move when the active server's data feed degrades,
///   * stay put when the server it left dies outright, and
///   * come back when the abandoned server returns as the healthier one.
///
/// A separate group pins the data-quality contract: a failing feed must still
/// serve the LAST KNOWN value, flagged `Bad_NoCommunication`, with the
/// ORIGINAL source timestamp.

/// A [MetarSource] with a switch on it. No HTTP, no timers, no clock reads.
class FakeMetarSource implements MetarSource {
  FakeMetarSource(this.station, this.observation);

  @override
  final String station;

  /// What the next [fetch] returns.
  MetarObservation observation;

  /// When true, [fetch] throws — the "upstream feed is down" case.
  bool failing = false;

  int fetches = 0;
  bool closed = false;

  @override
  Future<MetarObservation> fetch() async {
    fetches++;
    if (failing) throw StateError('fake METAR feed is down');
    return observation;
  }

  @override
  void close() => closed = true;
}

/// Decodes [raw] and re-stamps the result at [at].
///
/// The observation time has to be pinned explicitly: the servers judge
/// staleness against the wall clock, so a fixture with a hard-coded date would
/// pass or fail depending on when the suite happens to run.
MetarObservation observedAt(DateTime at, {String raw = 'METAR BIRK 011900Z 30003KT 250V350 CAVOK 10/02 Q1013'}) {
  final parsed = parseMetar(raw, referenceTime: at);
  return MetarObservation(
    station: parsed.station,
    rawText: parsed.rawText,
    observationTime: at,
    reportType: parsed.reportType,
    automatic: parsed.automatic,
    corrected: parsed.corrected,
    nil: parsed.nil,
    temperatureC: parsed.temperatureC,
    dewPointC: parsed.dewPointC,
    windDirectionDeg: parsed.windDirectionDeg,
    windVariable: parsed.windVariable,
    windVariableFromDeg: parsed.windVariableFromDeg,
    windVariableToDeg: parsed.windVariableToDeg,
    windSpeedKt: parsed.windSpeedKt,
    windGustKt: parsed.windGustKt,
    visibilityMeters: parsed.visibilityMeters,
    visibilityIsMinimum: parsed.visibilityIsMinimum,
    cavok: parsed.cavok,
    altimeterHPa: parsed.altimeterHPa,
    skyLayers: parsed.skyLayers,
    presentWeather: parsed.presentWeather,
    unparsedGroups: parsed.unparsedGroups,
  );
}

/// A fresh observation: [ago] old, so it counts as current everywhere.
MetarObservation recent({String? raw, Duration ago = const Duration(minutes: 5)}) {
  final at = DateTime.now().toUtc().subtract(ago);
  return raw == null ? observedAt(at) : observedAt(at, raw: raw);
}

/// Polls [condition] until it holds or [timeout] elapses; returns whether it
/// held. Used instead of fixed sleeps so the test tracks real progress.
Future<bool> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 50),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (condition()) return true;
    await Future.delayed(step);
  }
  return condition();
}

void main() {
  // The servers poll their (fake) feed fast so failure ladders play out in
  // seconds rather than minutes.
  const serverPoll = Duration(milliseconds: 200);
  const clientPoll = Duration(milliseconds: 300);

  group('ServiceLevel arbitration and failover', () {
    late int portA;
    late int portB;
    late FakeMetarSource fakeA;
    late FakeMetarSource fakeB;
    late MetarRedundantServer serverA;
    late MetarRedundantServer serverB;
    late MetarFailoverClient client;
    final events = <FailoverEvent>[];
    final cleanup = <Future<void> Function()>[];

    String endpointOf(int port) => 'opc.tcp://localhost:$port';

    MetarRedundantServer buildServer(String instance, int port, MetarSource source, int peerPort) =>
        MetarRedundantServer(
          instance: instance,
          port: port,
          source: source,
          peerEndpoints: [endpointOf(peerPort)],
          pollInterval: serverPoll,
          log: (_) {},
        );

    setUp(() async {
      events.clear();
      cleanup.clear();
      portA = await freeTcpPort();
      portB = await freeTcpPort();
      fakeA = FakeMetarSource('BIRK', recent());
      fakeB = FakeMetarSource('BIRK', recent());

      serverA = buildServer('metar-a', portA, fakeA, portB);
      serverB = buildServer('metar-b', portB, fakeB, portA);
      await serverA.start();
      await serverB.start();
      cleanup.add(() => serverA.stop());
      cleanup.add(() => serverB.stop());

      // Seeded with ONE endpoint on purpose: the peer has to be discovered
      // from ServerUriArray.
      client = MetarFailoverClient(
        endpoints: [endpointOf(portA)],
        pollInterval: clientPoll,
        hysteresis: 10,
        log: (_) {},
      );
      client.failovers.listen(events.add);
      cleanup.add(() => client.stop());
    });

    tearDown(() async {
      for (final dispose in cleanup.reversed) {
        try {
          await dispose().timeout(const Duration(seconds: 15));
        } catch (_) {
          // Best effort: a test may already have stopped a server itself.
        }
      }
    });

    test('picks the healthiest server, discovers its peer, fails over, stays after a kill, and comes back', () async {
      // --- 1. Initial selection: only A is known, so A is chosen. ---------
      await client.start();
      expect(client.activeEndpoint, endpointOf(portA));
      expect(events.single.from, isNull);
      expect(events.single.reason, 'initial selection');
      expect(events.single.toLevel, 250, reason: 'a fresh feed rates 250');

      // --- 2. Peer discovery from the standard NS0 array. -----------------
      expect(
        await waitUntil(() => client.knownEndpoints.length == 2),
        isTrue,
        reason: 'the peer must be discovered from ServerUriArray, not configured',
      );
      expect(client.knownEndpoints, containsAll([endpointOf(portA), endpointOf(portB)]));
      expect(
        await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 250),
        isTrue,
        reason: 'B is healthy too, but A is already active and B does not beat the hysteresis margin',
      );
      expect(client.activeEndpoint, endpointOf(portA));
      expect(events, hasLength(1), reason: 'two equally healthy servers must not cause a flap');

      // --- 3. A's feed degrades: the client must move to B. ---------------
      fakeA.failing = true;
      expect(
        await waitUntil(() => client.activeEndpoint == endpointOf(portB)),
        isTrue,
        reason: 'A loses ServiceLevel on every failed fetch and must lose the arbitration',
      );
      expect(events, hasLength(2));
      expect(events.last.from, endpointOf(portA));
      expect(events.last.to, endpointOf(portB));
      expect(events.last.reason, 'higher ServiceLevel available');
      expect(events.last.fromLevel, lessThan(events.last.toLevel));
      expect(serverA.serviceLevel, lessThan(serverB.serviceLevel));

      // Data still flows, now from B.
      final fromB = await client.readActive();
      expect(fromB, isNotNull);
      expect(fromB!.isGood, isTrue);
      expect(fromB.value['Station'].value, 'BIRK');

      // --- 4. A dies outright: the client must STAY on B. -----------------
      await serverA.stop();
      await Future.delayed(clientPoll * 6);
      expect(
        client.serviceLevels[endpointOf(portA)],
        -1,
        reason: 'an unreachable server reads as -1, below every reachable one',
      );
      expect(client.activeEndpoint, endpointOf(portB));
      expect(events, hasLength(2), reason: 'losing the server it already left is not a failover');

      // --- 5. A returns healthier than B: the client comes back. ---------
      //
      // DOCUMENTED BEHAVIOUR: this client does fail BACK, but only when the
      // returning server beats the active one by more than the hysteresis
      // margin. A tie (both at 250) keeps the current server, so a recovered
      // peer alone never causes a switch — see step 2.
      fakeB.failing = true;
      fakeA.failing = false;
      final restartedA = buildServer('metar-a2', portA, fakeA, portB);
      await restartedA.start();
      cleanup.add(() => restartedA.stop());

      expect(
        await waitUntil(() => client.activeEndpoint == endpointOf(portA), timeout: const Duration(seconds: 60)),
        isTrue,
        reason: 'the restarted A is healthy and B is now degraded, so the client must switch back',
      );
      expect(events.last.from, endpointOf(portB));
      expect(events.last.to, endpointOf(portA));
      expect(events.last.toLevel, greaterThan(events.last.fromLevel + client.hysteresis));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a server that declares ServiceLevel 0 is abandoned immediately', () async {
      await client.start();
      expect(client.activeEndpoint, endpointOf(portA));
      expect(await waitUntil(() => client.knownEndpoints.length == 2), isTrue);

      // `--service-level 0` is the "take me out of service" switch: it is
      // honoured without waiting for the hysteresis margin.
      serverA.forceServiceLevel(0);
      expect(await waitUntil(() => client.activeEndpoint == endpointOf(portB)), isTrue);
      expect(events.last.reason, 'server reported ServiceLevel 0 (out of service)');
      expect(events.last.fromLevel, 0);
      expect(events.last.toLevel, 250);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the redundancy surface sits on the standard NS0 nodes', () async {
      final probe = await setupClient(portA);
      addTearDown(probe.delete);

      // ServiceLevel: open62541 pins this node at 255 internally; the example
      // replaces its value source, so it must report the computed level.
      final level = await probe.read(serviceLevelNodeId);
      expect(level.asInt, 250);
      expect(level.asInt, serverA.serviceLevel);

      // RedundancySupport = Hot (3), not open62541's default None (0).
      final support = await probe.read(redundancySupportNodeId);
      expect(support.asInt, redundancySupportHot);
      expect(support.asInt, isNot(0));

      // ServerUriArray lists BOTH members of the set, this server first.
      final uris = await probe.read(serverUriArrayNodeId);
      expect(uris.isArray, isTrue);
      expect(uris.asArray.map((v) => v.asString).toList(), [endpointOf(portA), endpointOf(portB)]);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('data quality on the METAR data-source node', () {
    late int port;
    late FakeMetarSource fake;
    late MetarRedundantServer server;
    late Client probe;
    late DateTime observationTime;

    setUp(() async {
      port = await freeTcpPort();
      // Five minutes ago: comfortably inside the two-hour staleness window
      // whenever the suite runs.
      observationTime = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      fake = FakeMetarSource('BIRK', observedAt(observationTime));
      server = MetarRedundantServer(
        instance: 'quality',
        port: port,
        source: fake,
        pollInterval: const Duration(milliseconds: 200),
        log: (_) {},
      );
      await server.start();
      probe = await setupClient(port);
    });

    tearDown(() async {
      await probe.delete();
      await server.stop();
    });

    test('a failing feed keeps serving the last value with Bad_NoCommunication and its original timestamp', () async {
      // Healthy: Good, and the source timestamp is the OBSERVATION time, not
      // "now" — that is the whole point of onReadValue.
      final good = await probe.readValue(server.metarNodeId);
      expect(good.statusCode, UA_STATUSCODE_GOOD);
      expect(good.isGood, isTrue);
      expect(good.sourceTimestamp, observationTime);
      expect(good.value['Station'].value, 'BIRK');
      expect((good.value['TemperatureC'].value as num).toDouble(), 10.0);
      expect(good.value['FlightCategory'].value, 'VFR');
      expect(good.value['RawText'].value, contains('BIRK 011900Z'));

      // The upstream feed dies. The observation itself does not change.
      fake.failing = true;
      final failuresBefore = server.consecutiveFailures;
      expect(await waitUntil(() => server.consecutiveFailures > failuresBefore), isTrue);

      final bad = await probe.readValue(server.metarNodeId);
      expect(bad.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION, reason: 'exactly Bad_NoCommunication');
      expect(bad.isBad, isTrue);
      // The LAST KNOWN value is still delivered alongside the Bad status...
      expect(bad.value['Station'].value, 'BIRK');
      expect((bad.value['TemperatureC'].value as num).toDouble(), 10.0);
      expect(bad.value['RawText'].value, good.value['RawText'].value);
      // ...and it keeps the ORIGINAL source timestamp, so a consumer can see
      // exactly how stale the data it is holding has become.
      expect(bad.sourceTimestamp, observationTime);
      expect(bad.serverTimestamp, isNotNull);
      expect(bad.serverTimestamp!.isAfter(bad.sourceTimestamp!), isTrue);

      // The scalar mirrors carry the same quality.
      final mirror = await probe.readValue(server.temperatureNodeId);
      expect(mirror.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect((mirror.value.value as num).toDouble(), 10.0);
      expect(mirror.sourceTimestamp, observationTime);

      // ServiceLevel fell with it, but not to 0: the server is still up and
      // still has a value, it just should not be preferred.
      final level = await probe.read(serviceLevelNodeId);
      expect(level.asInt, lessThan(250));
      expect(level.asInt, greaterThan(0));

      // Recovery: the very next successful fetch flips the status back.
      fake.failing = false;
      expect(await waitUntil(() => server.consecutiveFailures == 0), isTrue);
      final recovered = await probe.readValue(server.metarNodeId);
      expect(recovered.statusCode, UA_STATUSCODE_GOOD);
      expect(recovered.sourceTimestamp, observationTime);
      expect((await probe.read(serviceLevelNodeId)).asInt, 250);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('data that ages past the staleness threshold goes Bad without any fetch failing', () async {
      // Same server, but the feed keeps returning an observation from six
      // hours ago: fetches succeed, yet the DATA is untrustworthy. The example
      // must report that honestly rather than serve stale numbers as Good.
      final stalePort = await freeTcpPort();
      final staleFake = FakeMetarSource('BIRK', recent(ago: const Duration(hours: 6)));
      final staleServer = MetarRedundantServer(
        instance: 'stale',
        port: stalePort,
        source: staleFake,
        pollInterval: const Duration(milliseconds: 200),
        staleAfter: const Duration(hours: 2),
        log: (_) {},
      );
      await staleServer.start();
      final staleProbe = await setupClient(stalePort);
      addTearDown(() async {
        await staleProbe.delete();
        await staleServer.stop();
      });

      expect(staleFake.fetches, greaterThan(0));
      expect(staleServer.consecutiveFailures, 0, reason: 'the fetch itself succeeded');

      final dv = await staleProbe.readValue(staleServer.metarNodeId);
      expect(dv.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(dv.value['Station'].value, 'BIRK');
      // 6 h old with a 2 h threshold: past 2x staleAfter, so the lowest rung.
      expect((await staleProbe.read(serviceLevelNodeId)).asInt, 5);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a server that has never fetched anything reports ServiceLevel 0 and no value', () async {
      final coldPort = await freeTcpPort();
      final coldFake = FakeMetarSource('BIRK', recent())..failing = true;
      final coldServer = MetarRedundantServer(
        instance: 'cold',
        port: coldPort,
        source: coldFake,
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await coldServer.start();
      final coldProbe = await setupClient(coldPort);
      addTearDown(() async {
        await coldProbe.delete();
        await coldServer.stop();
      });

      // ServiceLevel 0 is the OPC UA way of saying "do not use me".
      expect((await coldProbe.read(serviceLevelNodeId)).asInt, 0);

      // With no last-known value there is nothing honest to serve, so the read
      // fails with Bad_NoCommunication and carries no value at all.
      final dv = await coldProbe.readValue(coldServer.metarNodeId);
      expect(dv.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(dv.value.value, isNull);
      await expectLater(coldProbe.read(coldServer.metarNodeId), throwsA(anything));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('the custom METAR structure', () {
    test('every modelled field survives the round trip, including the missing-value sentinels', () async {
      final port = await freeTcpPort();
      // A report with plenty of holes: no wind reading, no visibility, no
      // cloud, no dew point. Those must arrive as the documented sentinels
      // (NaN for doubles, -1 for the integers), not as zeros.
      final sparse = recent(raw: 'METAR BIRK 011900Z AUTO /////KT //// ////// M04/// Q1001');
      final fake = FakeMetarSource('BIRK', sparse);
      final server = MetarRedundantServer(
        instance: 'struct',
        port: port,
        source: fake,
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await server.start();
      final probe = await setupClient(port);
      addTearDown(() async {
        await probe.delete();
        await server.stop();
      });

      final v = await probe.read(server.metarNodeId);
      expect(v.isObject, isTrue);
      expect(v.typeId, server.metarTypeId);
      expect(v.asObject.keys, hasLength(19));

      expect(v['Station'].value, 'BIRK');
      expect(v['ReportType'].value, 'METAR');
      expect(v['Automatic'].value, isTrue);
      expect(v['ObservationTime'].asDateTime, sparse.observationTime);
      expect((v['TemperatureC'].value as num).toDouble(), -4.0);
      expect((v['DewPointC'].value as double).isNaN, isTrue, reason: 'M04/// has no dew point');
      expect((v['RelativeHumidityPct'].value as double).isNaN, isTrue);
      expect(v['WindDirectionDeg'].value, -1, reason: '/////KT reports no direction');
      expect(v['WindVariable'].value, isFalse);
      expect((v['WindSpeedKt'].value as double).isNaN, isTrue);
      expect((v['WindGustKt'].value as double).isNaN, isTrue);
      expect((v['VisibilityMeters'].value as double).isNaN, isTrue);
      expect(v['Cavok'].value, isFalse);
      expect(v['CeilingFeet'].value, -1);
      expect((v['AltimeterHPa'].value as num).toDouble(), 1001.0);
      expect(v['SkyCondition'].value, '');
      expect(v['PresentWeather'].value, '');
      expect(v['FlightCategory'].value, 'UNKNOWN');
      expect(v['RawText'].value, contains('/////KT'));

      // The DataType node itself is published, which is what lets a generic
      // client discover the structure rather than guess at it.
      final typeNode = await probe.readAttribute({
        server.metarTypeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
      });
      expect(typeNode[server.metarTypeId]!.displayName?.value, 'METAR Observation');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a fully populated report maps every field', () async {
      final port = await freeTcpPort();
      final storm = recent(raw: 'METAR BIRK 011200Z 09025G40KT 1200 +SN BLSN VV005 M04/M06 Q0978');
      final server = MetarRedundantServer(
        instance: 'struct-full',
        port: port,
        source: FakeMetarSource('BIRK', storm),
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await server.start();
      final probe = await setupClient(port);
      addTearDown(() async {
        await probe.delete();
        await server.stop();
      });

      final v = await probe.read(server.metarNodeId);
      expect(v['WindDirectionDeg'].value, 90);
      expect((v['WindSpeedKt'].value as num).toDouble(), 25.0);
      expect((v['WindGustKt'].value as num).toDouble(), 40.0);
      expect((v['VisibilityMeters'].value as num).toDouble(), 1200.0);
      expect(v['CeilingFeet'].value, 500);
      expect(v['SkyCondition'].value, 'VV005');
      expect(v['PresentWeather'].value, '+SN BLSN');
      expect(v['FlightCategory'].value, 'LIFR');
      expect((v['RelativeHumidityPct'].value as num).toDouble(), closeTo(86.0, 0.5));
      expect((v['AltimeterHPa'].value as num).toDouble(), 978.0);

      // The scalar mirrors track the struct.
      expect((await probe.read(server.temperatureNodeId)).asDouble, -4.0);
      expect((await probe.read(server.windSpeedNodeId)).asDouble, 25.0);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
