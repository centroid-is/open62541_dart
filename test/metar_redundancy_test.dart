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
///   * identify the members of the set by ApplicationUri (`ServerArray[0]`,
///     ns=0;i=2254) and match them against `ServerUriArray` (ns=0;i=11314),
///     which lists ServerUris -- identities, never dialled as endpoints,
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

    // 127.0.0.1, not localhost: the servers start on port 0 and it is the
    // IPv4 listen socket that owns the OS-picked port (see test/common.dart).
    String endpointOf(int port) => 'opc.tcp://127.0.0.1:$port';

    // The members know each other by ApplicationUri, which does not depend
    // on the OS-picked ports, so the set is wired up before anything starts.
    String uriOf(String instance) => MetarRedundantServer.defaultApplicationUri('127.0.0.1', instance);
    final uriA = uriOf('metar-a');
    final uriB = uriOf('metar-b');

    MetarRedundantServer buildServer(
      String instance,
      int port,
      MetarSource source, {
      required List<String> peers,
      String? applicationUri,
    }) => MetarRedundantServer(
      instance: instance,
      host: '127.0.0.1',
      port: port,
      source: source,
      applicationUri: applicationUri,
      peers: peers,
      pollInterval: serverPoll,
      log: (_) {},
    );

    setUp(() async {
      events.clear();
      cleanup.clear();
      fakeA = FakeMetarSource('BIRK', recent());
      fakeB = FakeMetarSource('BIRK', recent());

      serverA = buildServer('metar-a', 0, fakeA, peers: [uriB]);
      serverB = buildServer('metar-b', 0, fakeB, peers: [uriA]);
      await serverA.start();
      await serverB.start();
      portA = serverA.listenPort;
      portB = serverB.listenPort;
      cleanup.add(() => serverA.stop());
      cleanup.add(() => serverB.stop());

      // Both endpoints are configured: ServerUriArray names the members by
      // ApplicationUri, which a client cannot dial.
      client = MetarFailoverClient(
        endpoints: [endpointOf(portA), endpointOf(portB)],
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

    test(
      'picks the healthiest server, identifies the members, fails over, stays after a kill, and comes back',
      () async {
        // --- 1. Initial selection: both are equally healthy, so one of them
        // is chosen and the other must not displace it. ----------------------
        await client.start();
        expect(client.activeEndpoint, endpointOf(portA));
        expect(events.single.from, isNull);
        expect(events.single.reason, 'initial selection');
        expect(events.single.toLevel, 250, reason: 'a fresh feed rates 250');

        // --- 2. Membership by ApplicationUri, from the standard NS0 nodes. --
        expect(
          await waitUntil(() => client.applicationUris.values.every((uri) => uri != null)),
          isTrue,
          reason: 'every endpoint is identified by its ServerArray[0]',
        );
        expect(client.applicationUris, {endpointOf(portA): uriA, endpointOf(portB): uriB});
        expect(client.serverUris, {uriA, uriB}, reason: 'the set is what ServerUriArray advertises');
        expect(client.endpointOf(uriB), endpointOf(portB));
        expect(client.membersWithoutEndpoint, isEmpty);
        expect(
          client.knownEndpoints,
          unorderedEquals([endpointOf(portA), endpointOf(portB)]),
          reason: 'only configured endpoints are dialled; ServerUris are identities',
        );
        expect(
          await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 250),
          isTrue,
          reason: 'B is Healthy too, but A is active and Healthy, so there is no failover',
        );
        expect(client.activeEndpoint, endpointOf(portA));
        expect(client.activeApplicationUri, uriA);
        expect(events, hasLength(1), reason: 'two equally healthy servers must not cause a flap');

        // --- 3. A's feed degrades: the client must move to B. ---------------
        fakeA.failing = true;
        expect(
          await waitUntil(() => client.activeEndpoint == endpointOf(portB)),
          isTrue,
          reason: 'one failed fetch takes A to 190, out of the Healthy band, and B is Healthy',
        );
        expect(events, hasLength(2));
        expect(events.last.from, endpointOf(portA));
        expect(events.last.to, endpointOf(portB));
        expect(events.last.fromUri, uriA);
        expect(events.last.toUri, uriB);
        expect(events.last.reason, contains('Healthy'));
        expect(isHealthyServiceLevel(events.last.fromLevel), isFalse);
        expect(isHealthyServiceLevel(events.last.toLevel), isTrue);
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

        // --- 5. A returns Healthy while B degrades: the client comes back. --
        //
        // DOCUMENTED BEHAVIOUR: this client does fail BACK, but only because
        // B has left the Healthy band. A recovered peer alone never causes a
        // switch: while the active server is Healthy the client stays, even
        // if the returning one rates higher — see step 2 and the band-aware
        // switching group.
        fakeB.failing = true;
        fakeA.failing = false;
        // Restarted on the port A had, under A's identity: that is the
        // endpoint the client is configured with (see test/common.dart) and
        // the member B advertises.
        final restartedA = buildServer('metar-a2', portA, fakeA, peers: [uriB], applicationUri: uriA);
        await restartedA.start();
        cleanup.add(() => restartedA.stop());

        expect(
          await waitUntil(() => client.activeEndpoint == endpointOf(portA), timeout: const Duration(seconds: 60)),
          isTrue,
          reason: 'B is Degraded and the restarted A is Healthy, so the client must switch back',
        );
        expect(events.last.from, endpointOf(portB));
        expect(events.last.to, endpointOf(portA));
        expect(isHealthyServiceLevel(events.last.fromLevel), isFalse);
        expect(isHealthyServiceLevel(events.last.toLevel), isTrue);
        expect(events.last.reason, contains('Healthy'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('a member with no configured endpoint is reported, never dialled', () async {
      // Only A is configured. The old discovery would have joined every
      // ServerUriArray entry as an endpoint; those are ApplicationUris.
      final partial = MetarFailoverClient(endpoints: [endpointOf(portA)], pollInterval: clientPoll, log: (_) {});
      cleanup.add(() => partial.stop());
      await partial.start();
      expect(partial.activeEndpoint, endpointOf(portA));
      expect(await waitUntil(() => partial.applicationUris[endpointOf(portA)] == uriA), isTrue);
      expect(partial.serverUris, {uriA, uriB});
      expect(partial.membersWithoutEndpoint, [uriB], reason: 'B is a member, but the client has no endpoint for it');
      expect(partial.endpointOf(uriB), isNull);
      await Future.delayed(clientPoll * 3);
      expect(partial.knownEndpoints, [endpointOf(portA)], reason: 'a ServerUri is not an address to dial');
      expect(partial.serviceLevels.keys.where((e) => e.startsWith('urn:')), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a server that declares ServiceLevel 0 is abandoned immediately', () async {
      await client.start();
      expect(client.activeEndpoint, endpointOf(portA));
      expect(await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 250), isTrue);

      // `--service-level 0` is the "take me out of service" switch: it is
      // honoured without waiting for the hysteresis margin.
      serverA.forceServiceLevel(0);
      expect(await waitUntil(() => client.activeEndpoint == endpointOf(portB)), isTrue);
      expect(events.last.reason, 'server reported ServiceLevel 0 (out of service)');
      expect(events.last.fromLevel, 0);
      expect(events.last.toLevel, 250);
    }, timeout: const Timeout(Duration(minutes: 2)));

    // Table 105 (OPC 10000-4 §6.6.2.4.2) prescribes the client's behaviour
    // per band: while the active server is Healthy (200-255) the client
    // shall not fail over; a Degraded (2-199) or NoData (1) server is left
    // for any Healthy one; otherwise the hysteresis margin applies.
    group('band-aware switching', () {
      test('the initial selection is the highest ServiceLevel in the set', () async {
        serverA.forceServiceLevel(100);
        await client.start();
        expect(client.activeEndpoint, endpointOf(portB), reason: 'B (250) beats A (100) even though A is listed first');
        expect(events.single.toLevel, 250);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('stays on a Healthy server while a higher Healthy one appears', () async {
        await client.start();
        expect(client.activeEndpoint, endpointOf(portA));
        expect(await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 250), isTrue);

        // 240 -> 255 clears the hysteresis margin, but both are Healthy.
        serverA.forceServiceLevel(240);
        serverB.forceServiceLevel(255);
        expect(await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 255), isTrue);
        await Future.delayed(clientPoll * 6);
        expect(client.activeEndpoint, endpointOf(portA), reason: 'no failover from a Healthy server');
        expect(client.activeServiceLevel, 240);
        expect(events, hasLength(1));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('leaves a Degraded server for a Healthy one without the hysteresis margin', () async {
        await client.start();
        expect(client.activeEndpoint, endpointOf(portA));
        serverB.forceServiceLevel(200);
        expect(await waitUntil(() => client.serviceLevels[endpointOf(portB)] == 200), isTrue);
        expect(client.activeEndpoint, endpointOf(portA), reason: 'A is still Healthy');

        // 195 -> 200 is within the margin of 10, but 195 is Degraded and 200
        // is Healthy: Table 105 says switch.
        serverA.forceServiceLevel(195);
        expect(await waitUntil(() => client.activeEndpoint == endpointOf(portB)), isTrue);
        expect(events.last.fromLevel, 195);
        expect(events.last.toLevel, 200);
        expect(events.last.reason, contains('Healthy'));
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('between Degraded servers the hysteresis margin still applies', () async {
        await client.start();
        expect(client.activeEndpoint, endpointOf(portA));
        serverB.forceServiceLevel(105);
        serverA.forceServiceLevel(100);
        expect(await waitUntil(() => client.serviceLevels[endpointOf(portA)] == 100), isTrue);
        await Future.delayed(clientPoll * 6);
        expect(client.activeEndpoint, endpointOf(portA), reason: '105 does not beat 100 by more than 10');
        expect(events, hasLength(1));

        serverB.forceServiceLevel(150);
        expect(await waitUntil(() => client.activeEndpoint == endpointOf(portB)), isTrue);
        expect(events.last.fromLevel, 100);
        expect(events.last.toLevel, 150);
        expect(events.last.reason, contains('higher ServiceLevel'));
      }, timeout: const Timeout(Duration(minutes: 2)));
    });

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

      // Each member has its own ApplicationUri (OPC 10000-4 §6.6.2.4: the
      // members of a non-transparent set must be distinguishable by it), which
      // the server publishes as ServerArray[0] (ns=0;i=2254).
      final probeB = await setupClient(portB);
      addTearDown(probeB.delete);
      final uriA = (await probe.read(serverArrayNodeId))[0].asString;
      final uriB = (await probeB.read(serverArrayNodeId))[0].asString;
      expect(uriA, isNot('urn:open62541.unconfigured.application'), reason: 'open62541\'s default is not an identity');
      expect(uriA, isNot(uriB), reason: 'the members of a redundant set need unique ApplicationUris');
      expect(uriA, startsWith('urn:'));

      // ServerUriArray (OPC 10000-5 §6.3.9) lists the ServerUris -- the
      // ApplicationUris -- of BOTH members of the set, this server first. It
      // is not a list of endpoint URLs.
      final uris = await probe.read(serverUriArrayNodeId);
      expect(uris.isArray, isTrue);
      final listed = uris.asArray.map((v) => v.asString).toList();
      expect(listed, [uriA, uriB]);
      expect(listed.where((u) => u.startsWith('opc.tcp://')), isEmpty, reason: 'ServerUris, not endpoints');
      expect((await probeB.read(serverUriArrayNodeId)).asArray.map((v) => v.asString).toList(), [uriB, uriA]);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('data quality on the METAR data-source node', () {
    late int port;
    late FakeMetarSource fake;
    late MetarRedundantServer server;
    late Client probe;
    late DateTime observationTime;

    setUp(() async {
      // Five minutes ago: comfortably inside the two-hour staleness window
      // whenever the suite runs.
      observationTime = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      fake = FakeMetarSource('BIRK', observedAt(observationTime));
      server = MetarRedundantServer(
        instance: 'quality',
        port: 0,
        source: fake,
        pollInterval: const Duration(milliseconds: 200),
        log: (_) {},
      );
      await server.start();
      port = server.listenPort;
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
      final staleFake = FakeMetarSource('BIRK', recent(ago: const Duration(hours: 6)));
      final staleServer = MetarRedundantServer(
        instance: 'stale',
        port: 0,
        source: staleFake,
        pollInterval: const Duration(milliseconds: 200),
        staleAfter: const Duration(hours: 2),
        log: (_) {},
      );
      await staleServer.start();
      final staleProbe = await setupClient(staleServer.listenPort);
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

    test('the failed-fetch floor is Degraded (2) while a last-known value is still served', () async {
      // OPC 10000-4 §6.6.2.4.2, Table 105: 1 is NoData ("not operational,
      // only ServiceLevel / ServerStatus available"). A server that still
      // answers reads with its last-known value, even flagged Bad, is
      // exchanging data and belongs in the Degraded range (2-199).
      fake.failing = true;
      expect(
        await waitUntil(() => server.consecutiveFailures >= 5),
        isTrue,
        reason: 'five failures take 250 below the floor whatever its value',
      );
      expect(server.serviceLevel, serviceLevelDegradedFloor);
      expect((await probe.read(serviceLevelNodeId)).asInt, 2);
      final dv = await probe.readValue(server.metarNodeId);
      expect(dv.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(dv.value['Station'].value, 'BIRK', reason: 'still serving the last-known value');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a server that has never fetched anything reports ServiceLevel 1 (NoData) and no value', () async {
      final coldFake = FakeMetarSource('BIRK', recent())..failing = true;
      final coldServer = MetarRedundantServer(
        instance: 'cold',
        port: 0,
        source: coldFake,
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await coldServer.start();
      final coldProbe = await setupClient(coldServer.listenPort);
      addTearDown(() async {
        await coldProbe.delete();
        await coldServer.stop();
      });

      // Table 105: 0 is Maintenance ("clients shall disconnect and not
      // reconnect"), which is wrong for a server that is up and will have
      // data on its next poll. 1, NoData, is the band for "nothing to serve
      // yet".
      expect((await coldProbe.read(serviceLevelNodeId)).asInt, serviceLevelNoData);
      expect(coldServer.serviceLevel, 1);

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
      // A report with plenty of holes: no wind reading, no visibility, no
      // cloud, no dew point. Those must arrive as the documented sentinels
      // (NaN for doubles, -1 for the integers), not as zeros.
      final sparse = recent(raw: 'METAR BIRK 011900Z AUTO /////KT //// ////// M04/// Q1001');
      final fake = FakeMetarSource('BIRK', sparse);
      final server = MetarRedundantServer(
        instance: 'struct',
        port: 0,
        source: fake,
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await server.start();
      final probe = await setupClient(server.listenPort);
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
      final storm = recent(raw: 'METAR BIRK 011200Z 09025G40KT 1200 +SN BLSN VV005 M04/M06 Q0978');
      final server = MetarRedundantServer(
        instance: 'struct-full',
        port: 0,
        source: FakeMetarSource('BIRK', storm),
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await server.start();
      final probe = await setupClient(server.listenPort);
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
