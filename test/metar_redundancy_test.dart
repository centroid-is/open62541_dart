import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import '../example/metar_common.dart';
import '../example/metar_redundant_client.dart';
import '../example/metar_redundant_server.dart';
import 'common.dart';

/// The NS0 type nodes of Part 5 §6.3.7 / §6.3.10 without a `NodeId` static.
final serverRedundancyType = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVERREDUNDANCYTYPE);
final nonTransparentRedundancyType = NodeId.fromNumeric(0, raw.UA_NS0ID_NONTRANSPARENTREDUNDANCYTYPE);
final nonTransparentNetworkRedundancyType = NodeId.fromNumeric(0, raw.UA_NS0ID_NONTRANSPARENTNETWORKREDUNDANCYTYPE);

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
///   * discover the other members' endpoints from ONE seed endpoint through
///     `ServerNetworkGroups` (ns=0;i=14415, Part 5 §6.3.10),
///   * move when the active server's data feed degrades,
///   * stay put when the server it left dies outright,
///   * come back when the abandoned server returns as the healthier one, and
///   * move during a member's orderly shutdown (`Server.shutdown(delay:)`:
///     ServerStatus.State = Shutdown, ServiceLevel 0, data still Good), which
///     blocks the member's isolate, so that member runs on a spawned one.
///
/// A separate group pins the data-quality contract: a failing feed must still
/// serve the LAST KNOWN value, flagged `Bad_NoCommunication`, with the
/// ORIGINAL source timestamp; and the last group pins the node layout: one
/// struct node per station named by its ICAO id (`ns=1;s=BIRK`), every
/// struct field mirrored as a HasComponent child (`ns=1;s=BIRK.TemperatureC`)
/// with the struct's value, status and timestamp, a station that never
/// reported reading `Bad_NoData` and one gone quiet
/// `Uncertain_LastUsableValue`, neither touching the ServiceLevel.

/// A [MetarSource] with a switch on it. No HTTP, no timers, no clock reads.
class FakeMetarSource implements MetarSource {
  /// A single-station source.
  FakeMetarSource(String station, MetarObservation observation)
    : stations = [station],
      observations = {station: observation};

  /// A multi-station source: [stations] are published, [observations] is
  /// what the next [fetch] answers with. A station in [stations] but not in
  /// [observations] is silent — exactly what the feed does for a small
  /// airfield outside its opening hours.
  FakeMetarSource.stations(this.stations, this.observations);

  @override
  final List<String> stations;

  /// What the next [fetch] returns, by station. Mutable: remove a station to
  /// silence it, replace an entry to issue a new report.
  final Map<String, MetarObservation> observations;

  /// When true, [fetch] throws — the "upstream feed is down" case.
  bool failing = false;

  int fetches = 0;
  bool closed = false;

  @override
  Future<Map<String, MetarObservation>> fetch() async {
    fetches++;
    if (failing) throw StateError('fake METAR feed is down');
    return Map.of(observations);
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

/// A fresh observation: [ago] old, so it counts as current everywhere. Give
/// [station] for a report from somewhere other than BIRK (the raw report
/// then carries that identifier, which is what the struct's `Station` field
/// and the per-station nodes are keyed by).
MetarObservation recent({String? raw, Duration ago = const Duration(minutes: 5), String station = 'BIRK'}) {
  final at = DateTime.now().toUtc().subtract(ago);
  if (raw != null) return observedAt(at, raw: raw);
  if (station == 'BIRK') return observedAt(at);
  return observedAt(at, raw: 'METAR $station 011900Z 18012KT 9999 FEW020 BKN040 05/01 Q0998');
}

/// A [MetarRedundantServer] on its own isolate, for the orderly-shutdown
/// test: `Server.shutdown(delay:)` blocks the isolate it runs on for the
/// delay, and the observers (the failover client, a probe) live on the
/// test's. Args: `[SendPort reply, String instance, String applicationUri,
/// Map peers]` (peers: ApplicationUri to endpoint URLs). Reports
/// `['port', port, SendPort control]`; on `['peer', uri, urls]` calls
/// `setPeer`; on `['stop', ms]` calls `stop(delay:)` and reports
/// `['stopped', millisecondsBlocked]`.
void _isolatedServer(List<Object> args) {
  final reply = args[0] as SendPort;
  final instance = args[1] as String;
  final applicationUri = args[2] as String;
  final peers = args[3] as Map;
  final server = MetarRedundantServer(
    instance: instance,
    host: '127.0.0.1',
    port: 0,
    source: FakeMetarSource('BIRK', recent()),
    applicationUri: applicationUri,
    peers: {for (final e in peers.entries) e.key as String: (e.value as List).cast<String>()},
    pollInterval: const Duration(milliseconds: 200),
    log: (_) {},
  );
  final control = ReceivePort();
  () async {
    await server.start();
    reply.send(['port', server.listenPort, control.sendPort]);
    await for (final message in control) {
      switch (message) {
        case ['peer', String uri, List urls]:
          server.setPeer(uri, urls.cast<String>());
        case ['stop', int ms]:
          final clock = Stopwatch()..start();
          await server.stop(delay: Duration(milliseconds: ms));
          reply.send(['stopped', clock.elapsedMilliseconds]);
          control.close();
      }
    }
  }();
}

/// Polls [condition] until it holds or [timeout] elapses; returns whether it
/// held. Used instead of fixed sleeps so the test tracks real progress.
Future<bool> waitUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 50),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await condition()) return true;
    await Future.delayed(step);
  }
  return await condition();
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
      required Map<String, List<String>> peers,
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

      // The ports are OS-picked, so A starts knowing B only by URI, B starts
      // knowing A's endpoint, and A learns B's once B listens: what a
      // deployment does when a member's address changes.
      serverA = buildServer('metar-a', 0, fakeA, peers: {uriB: []});
      await serverA.start();
      portA = serverA.listenPort;
      cleanup.add(() => serverA.stop());
      serverB = buildServer(
        'metar-b',
        0,
        fakeB,
        peers: {
          uriA: [serverA.endpoint],
        },
      );
      await serverB.start();
      portB = serverB.listenPort;
      cleanup.add(() => serverB.stop());
      serverA.setPeer(uriB, [serverB.endpoint]);

      // Both endpoints are configured here; the single-seed discovery has
      // its own test.
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
        final restartedA = buildServer(
          'metar-a2',
          portA,
          fakeA,
          peers: {
            uriB: [serverB.endpoint],
          },
          applicationUri: uriA,
        );
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

    test('discovers the whole set from one seed endpoint through ServerNetworkGroups', () async {
      // Only A's endpoint is given. ServerUriArray names B by ApplicationUri,
      // which cannot be dialled; ServerNetworkGroups (Part 5 §6.3.10) maps
      // that URI to B's endpoint, which the client then connects to.
      final seeded = MetarFailoverClient(endpoints: [endpointOf(portA)], pollInterval: clientPoll, log: (_) {});
      cleanup.add(() => seeded.stop());
      await seeded.start();
      expect(seeded.activeEndpoint, endpointOf(portA));
      expect(
        await waitUntil(() => seeded.endpointOf(uriB) == endpointOf(portB)),
        isTrue,
        reason: 'B\'s endpoint is learned from A\'s ServerNetworkGroups and B answers as $uriB there',
      );
      expect(seeded.knownEndpoints, unorderedEquals([endpointOf(portA), endpointOf(portB)]));
      expect(seeded.membersWithoutEndpoint, isEmpty);
      expect(seeded.networkGroups, {
        uriA: [endpointOf(portA)],
        uriB: [endpointOf(portB)],
      }, reason: 'what the set advertises: ServerUris equal to ServerUriArray, each with its endpoint');
      expect(await waitUntil(() => seeded.serviceLevels[endpointOf(portB)] == 250), isTrue);
      expect(seeded.applicationUris, {endpointOf(portA): uriA, endpointOf(portB): uriB});
      expect(seeded.serviceLevels.keys.where((e) => e.startsWith('urn:')), isEmpty, reason: 'URIs are never dialled');

      // The discovered member is a full member: A degrades, the client moves.
      serverA.forceServiceLevel(100);
      expect(await waitUntil(() => seeded.activeEndpoint == endpointOf(portB)), isTrue);
      expect(seeded.activeApplicationUri, uriB);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a member whose network group has no path is reported, never dialled', () async {
      // A does not know where B is (its group for B has no network path).
      serverA.setPeer(uriB, []);
      final partial = MetarFailoverClient(endpoints: [endpointOf(portA)], pollInterval: clientPoll, log: (_) {});
      cleanup.add(() => partial.stop());
      await partial.start();
      expect(partial.activeEndpoint, endpointOf(portA));
      expect(await waitUntil(() => partial.applicationUris[endpointOf(portA)] == uriA), isTrue);
      expect(partial.serverUris, {uriA, uriB});
      expect(partial.networkGroups, {
        uriA: [endpointOf(portA)],
        uriB: <String>[],
      });
      expect(partial.membersWithoutEndpoint, [uriB], reason: 'B is a member, but no endpoint is known for it');
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

    test('a server in Maintenance (0) is disconnected, and reconnected only after the retry interval', () async {
      // Table 105 at 0: "clients shall not connect, connected clients shall
      // disconnect". The client leaves the member, drops its session, and
      // looks again only after a much longer interval; it comes back once
      // the level is above 0.
      const retry = Duration(seconds: 3);
      final patient = MetarFailoverClient(
        endpoints: [endpointOf(portA), endpointOf(portB)],
        pollInterval: clientPoll,
        maintenanceRetryInterval: retry,
        log: (_) {},
      );
      final patientEvents = <FailoverEvent>[];
      patient.failovers.listen(patientEvents.add);
      cleanup.add(() => patient.stop());
      await patient.start();
      expect(patient.activeEndpoint, endpointOf(portA));
      expect(await waitUntil(() => serverA.connectionCount == 1), isTrue);
      expect(patient.inMaintenance, {endpointOf(portA): false, endpointOf(portB): false});

      serverA.forceServiceLevel(0);
      expect(await waitUntil(() => patient.activeEndpoint == endpointOf(portB)), isTrue);
      expect(await waitUntil(() => serverA.connectionCount == 0), isTrue, reason: 'disconnected, not just abandoned');
      expect(patient.inMaintenance[endpointOf(portA)], isTrue);
      expect(patient.serviceLevels[endpointOf(portA)], 0, reason: 'the last reading stands while disconnected');
      final left = DateTime.now();

      // A is back in service, but the client does not know and must not
      // look before the retry interval.
      serverA.forceServiceLevel(null);
      expect(serverA.serviceLevel, 250);
      await Future.delayed(clientPoll * 4);
      expect(patient.serviceLevels[endpointOf(portA)], 0);
      expect(serverA.connectionCount, 0, reason: 'no reconnect before the interval');
      expect(patient.inMaintenance[endpointOf(portA)], isTrue);

      // After the interval it reconnects, reads 250, and stays supervised.
      expect(await waitUntil(() => patient.serviceLevels[endpointOf(portA)] == 250, timeout: retry * 3), isTrue);
      expect(DateTime.now().difference(left), greaterThanOrEqualTo(retry));
      expect(patient.inMaintenance[endpointOf(portA)], isFalse);
      expect(serverA.connectionCount, 1);
      expect(patient.activeEndpoint, endpointOf(portB), reason: 'B is Healthy: no fail-back');
      expect(patientEvents, hasLength(2));

      // Still at 0 at the retry: disconnected again for another interval.
      serverA.forceServiceLevel(0);
      expect(await waitUntil(() => serverA.connectionCount == 0), isTrue);
      expect(patient.inMaintenance[endpointOf(portA)], isTrue);
      await Future.delayed(retry + clientPoll * 3);
      expect(patient.inMaintenance[endpointOf(portA)], isTrue, reason: 'checked once, found 0, disconnected again');
      expect(await waitUntil(() => serverA.connectionCount == 0), isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a NoData (1) server is polled for ServiceLevel and ServerStatus but never chosen for data', () async {
      // Table 105: at 1 a server is "not operational; only ServiceLevel,
      // ServerStatus and diagnostics can be read". The client keeps polling
      // it (the session stays), and subscribes to data only on a server at
      // 2 or more.
      serverA.forceServiceLevel(1);
      serverB.forceServiceLevel(1);
      await client.start();
      expect(client.activeEndpoint, isNull, reason: 'no member qualifies for data');
      expect(events, isEmpty);
      expect(client.serviceLevels, {endpointOf(portA): 1, endpointOf(portB): 1}, reason: 'still polled');
      await Future.delayed(clientPoll * 3);
      expect(client.activeEndpoint, isNull);
      expect(serverA.connectionCount, 1, reason: 'NoData is not Maintenance: the connection stays for the polling');
      expect(serverB.connectionCount, 1);

      // 2 is the bottom of the Degraded band: data may be read from it.
      serverB.forceServiceLevel(2);
      expect(await waitUntil(() => client.activeEndpoint == endpointOf(portB)), isTrue);
      expect(events.single.from, isNull);
      expect(events.single.toLevel, 2);
      expect((await client.readActive())!.isGood, isTrue);

      // Back to NoData with no alternative: the data subscription goes, the
      // polling stays, and nothing is chosen.
      serverB.forceServiceLevel(1);
      expect(await waitUntil(() => client.activeEndpoint == null), isTrue);
      expect(events, hasLength(2));
      expect(events.last.from, endpointOf(portB));
      expect(events.last.to, isNull);
      expect(events.last.reason, contains('NoData'));
      await Future.delayed(clientPoll * 3);
      expect(client.serviceLevels[endpointOf(portB)], 1, reason: 'still polled');
      expect(serverB.connectionCount, 1, reason: 'not disconnected');

      // A member comes up Healthy: chosen.
      serverA.forceServiceLevel(null);
      expect(await waitUntil(() => client.activeEndpoint == endpointOf(portA)), isTrue);
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
      final level = await probe.read(NodeId.serviceLevel);
      expect(level.asInt, 250);
      expect(level.asInt, serverA.serviceLevel);

      // RedundancySupport = Hot (3), not open62541's default None (0).
      final support = await probe.read(NodeId.redundancySupport);
      expect(support.asInt, RedundancySupport.hot.value);
      expect(support.asInt, 3);

      // Part 5 §6.3.7: the base ServerRedundancyType (i=2034) is for
      // RedundancySupport None only; a server advertising Hot must type
      // Server/ServerRedundancy (i=2296) as NonTransparentRedundancyType
      // (i=2039), the subtype that declares ServerUriArray -- here its
      // subtype NonTransparentNetworkRedundancyType (i=11945, §6.3.10),
      // which adds ServerNetworkGroups.
      final typeRefs = await probe.browse(NodeId.serverRedundancy, referenceTypeId: NodeId.hasTypeDefinition);
      expect(typeRefs.map((r) => r.nodeId), [
        nonTransparentNetworkRedundancyType,
      ], reason: 'Hot on the base ServerRedundancyType is forbidden by Part 5 §6.3.7');
      Future<List<NodeId>> supertypeOf(NodeId type) async =>
          (await probe.browse(type, direction: 1, referenceTypeId: NodeId.hasSubtype)).map((r) => r.nodeId).toList();
      expect(await supertypeOf(nonTransparentNetworkRedundancyType), [nonTransparentRedundancyType]);
      expect(await supertypeOf(nonTransparentRedundancyType), [serverRedundancyType]);

      // Each member has its own ApplicationUri (OPC 10000-4 §6.6.2.4: the
      // members of a non-transparent set must be distinguishable by it), which
      // the server publishes as ServerArray[0] (ns=0;i=2254).
      final probeB = await setupClient(portB);
      addTearDown(probeB.delete);
      final uriA = (await probe.read(NodeId.serverArray))[0].asString;
      final uriB = (await probeB.read(NodeId.serverArray))[0].asString;
      expect(uriA, isNot('urn:open62541.unconfigured.application'), reason: 'open62541\'s default is not an identity');
      expect(uriA, isNot(uriB), reason: 'the members of a redundant set need unique ApplicationUris');
      expect(uriA, startsWith('urn:'));

      // ServerUriArray (OPC 10000-5 §6.3.9) lists the ServerUris -- the
      // ApplicationUris -- of BOTH members of the set, this server first. It
      // is not a list of endpoint URLs.
      final uris = await probe.read(NodeId.serverUriArray);
      expect(uris.isArray, isTrue);
      final listed = uris.asArray.map((v) => v.asString).toList();
      expect(listed, [uriA, uriB]);
      expect(listed.where((u) => u.startsWith('opc.tcp://')), isEmpty, reason: 'ServerUris, not endpoints');
      expect((await probeB.read(NodeId.serverUriArray)).asArray.map((v) => v.asString).toList(), [uriB, uriA]);

      // ServerNetworkGroups (OPC 10000-5 §6.3.10): one NetworkGroupDataType
      // per ServerUriArray entry, in its order, each with one network path
      // holding that member's endpoint. This is what lets a client find B
      // from A.
      final groups = await probe.read(NodeId.serverNetworkGroups);
      expect(groups.isArray, isTrue, reason: 'a NetworkGroupDataType[]; got ${groups.value}');
      expect(groups.asArray.map((g) => g['ServerUri'].asString), listed);
      List<List<String>> pathsOf(DynamicValue group) => [
        for (final path in group['NetworkPaths'].asArray)
          path['EndpointUrlList'].asArray.map((u) => u.asString).toList(),
      ];
      expect(pathsOf(groups[0]), [
        [endpointOf(portA)],
      ]);
      expect(pathsOf(groups[1]), [
        [endpointOf(portB)],
      ]);
      final groupsB = await probeB.read(NodeId.serverNetworkGroups);
      expect(groupsB.asArray.map((g) => g['ServerUri'].asString), [uriB, uriA]);
      expect(pathsOf(groupsB[1]), [
        [endpointOf(portA)],
      ]);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('orderly shutdown of a member (Server.shutdown(delay:))', () {
    const delay = Duration(seconds: 4);
    String endpointOf(int port) => 'opc.tcp://127.0.0.1:$port';
    final uriA = MetarRedundantServer.defaultApplicationUri('127.0.0.1', 'metar-a');
    final uriB = MetarRedundantServer.defaultApplicationUri('127.0.0.1', 'metar-b');

    late ReceivePort reply;
    late StreamIterator<dynamic> messages;
    late SendPort controlA;
    late int portA;
    late MetarRedundantServer serverB;
    late MetarFailoverClient client;
    final events = <FailoverEvent>[];

    setUp(() async {
      events.clear();
      // A on its own isolate; B here. A learns B's endpoint once B listens.
      reply = ReceivePort();
      messages = StreamIterator(reply);
      await Isolate.spawn(_isolatedServer, <Object>[
        reply.sendPort,
        'metar-a',
        uriA,
        <String, List<String>>{uriB: []},
      ]);
      expect(await messages.moveNext(), isTrue);
      final [_, int port, SendPort control] = messages.current as List;
      portA = port;
      controlA = control;
      serverB = MetarRedundantServer(
        instance: 'metar-b',
        host: '127.0.0.1',
        port: 0,
        source: FakeMetarSource('BIRK', recent()),
        peers: {
          uriA: [endpointOf(portA)],
        },
        pollInterval: serverPoll,
        log: (_) {},
      );
      await serverB.start();
      controlA.send([
        'peer',
        uriB,
        [serverB.endpoint],
      ]);

      client = MetarFailoverClient(
        endpoints: [endpointOf(portA), endpointOf(serverB.listenPort)],
        pollInterval: clientPoll,
        // A is left (Table 105: disconnect) and will not come back; a short
        // retry lets the test see it go unreachable.
        maintenanceRetryInterval: const Duration(seconds: 1),
        log: (_) {},
      );
      client.failovers.listen(events.add);
    });

    tearDown(() async {
      await client.stop().timeout(const Duration(seconds: 15));
      await serverB.stop().timeout(const Duration(seconds: 15));
      reply.close();
    });

    test(
      'during the delay a client sees State Shutdown, ServiceLevel 0 and still-Good data, and the client moves',
      () async {
        await client.start();
        expect(client.activeEndpoint, endpointOf(portA));
        expect(await waitUntil(() => client.serviceLevels[endpointOf(serverB.listenPort)] == 250), isTrue);
        expect(client.serverStates[endpointOf(portA)], 0, reason: 'Running');

        final probe = await setupClient(portA);
        addTearDown(probe.delete);
        expect((await probe.read(NodeId.serverStatusState)).asInt, 0);

        // A announces its shutdown and keeps serving for the delay.
        controlA.send(['stop', delay.inMilliseconds]);
        Future<bool> stateIsShutdown() async {
          try {
            return (await probe.read(NodeId.serverStatusState)).asInt == 4;
          } catch (_) {
            return false; // gone already: not an announcement
          }
        }

        expect(
          await waitUntil(stateIsShutdown, timeout: delay),
          isTrue,
          reason: 'ServerStatus.State = Shutdown (4) during the delay, Part 5 §12.6',
        );
        expect((await probe.read(NodeId.serviceLevel)).asInt, 0, reason: 'Table 105: 0 tells the clients to leave');
        final data = await probe.readValue(NodeId.fromString(1, 'BIRK'));
        expect(data.isGood, isTrue, reason: 'the hand-off happens while the data is still Good');
        expect(data.value['Station'].value, 'BIRK');

        // The failover client treats State != Running like ServiceLevel 0.
        expect(
          await waitUntil(() => client.activeEndpoint == endpointOf(serverB.listenPort), timeout: delay),
          isTrue,
          reason: 'the client must move to B before A goes away',
        );
        expect(events, hasLength(2));
        expect(events.last.from, endpointOf(portA));
        expect(events.last.fromLevel, 0);
        expect(events.last.toLevel, 250);
        expect(events.last.reason, contains('shutdown'));
        expect(client.serverStates[endpointOf(portA)], 4);
        expect(client.serviceLevels[endpointOf(portA)], 0);
        expect(
          await waitUntil(() => client.inMaintenance[endpointOf(portA)] == true),
          isTrue,
          reason: 'left and disconnected, Table 105',
        );
        final fromB = await client.readActive();
        expect(fromB!.isGood, isTrue);

        // Then A is gone, having held for the delay.
        expect(await messages.moveNext(), isTrue);
        final [_, int blocked] = messages.current as List;
        expect(blocked, greaterThanOrEqualTo(delay.inMilliseconds));
        expect(await waitUntil(() => client.serviceLevels[endpointOf(portA)] == -1), isTrue);
        expect(client.activeEndpoint, endpointOf(serverB.listenPort));
        expect(events, hasLength(2), reason: 'losing the server it already left is not a failover');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
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
      final good = await probe.readValue(server.stationNodeId('BIRK'));
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

      final bad = await probe.readValue(server.stationNodeId('BIRK'));
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

      // The field children under the struct node carry the same quality.
      final mirror = await probe.readValue(server.fieldNodeId('BIRK', 'TemperatureC'));
      expect(mirror.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect((mirror.value.value as num).toDouble(), 10.0);
      expect(mirror.sourceTimestamp, observationTime);

      // ServiceLevel fell with it, but not to 0: the server is still up and
      // still has a value, it just should not be preferred.
      final level = await probe.read(NodeId.serviceLevel);
      expect(level.asInt, lessThan(250));
      expect(level.asInt, greaterThan(0));

      // Recovery: the very next successful fetch flips the status back.
      fake.failing = false;
      expect(await waitUntil(() => server.consecutiveFailures == 0), isTrue);
      final recovered = await probe.readValue(server.stationNodeId('BIRK'));
      expect(recovered.statusCode, UA_STATUSCODE_GOOD);
      expect(recovered.sourceTimestamp, observationTime);
      expect((await probe.read(NodeId.serviceLevel)).asInt, 250);
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

      // The feed answers, so this is not a communication failure: the value
      // is the last usable one, served as such, with its own timestamp.
      final dv = await staleProbe.readValue(staleServer.stationNodeId('BIRK'));
      expect(dv.statusCode, UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE);
      expect(dv.isGood, isFalse);
      expect(dv.isBad, isFalse);
      expect(dv.value['Station'].value, 'BIRK');
      expect(dv.sourceTimestamp, staleFake.observations['BIRK']!.observationTime);
      // 6 h old with a 2 h threshold: past 2x staleAfter, so the lowest rung.
      expect((await staleProbe.read(NodeId.serviceLevel)).asInt, 5);
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
      expect((await probe.read(NodeId.serviceLevel)).asInt, 2);
      final dv = await probe.readValue(server.stationNodeId('BIRK'));
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
      expect((await coldProbe.read(NodeId.serviceLevel)).asInt, serviceLevelNoData);
      expect(coldServer.serviceLevel, 1);

      // With no last-known value there is nothing honest to serve, so the read
      // fails with Bad_NoCommunication and carries no value at all.
      final dv = await coldProbe.readValue(coldServer.stationNodeId('BIRK'));
      expect(dv.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(dv.value.value, isNull);
      await expectLater(coldProbe.read(coldServer.stationNodeId('BIRK')), throwsA(anything));
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

      final v = await probe.read(server.stationNodeId('BIRK'));
      expect(v.isObject, isTrue);
      expect(v.typeId, server.metarTypeId);
      expect(v.asObject.keys, hasLength(19));
      expect(v.asObject.keys.toList(), server.fieldNames, reason: 'the schema the child nodes are generated from');

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

      final v = await probe.read(server.stationNodeId('BIRK'));
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

      // The field children track the struct.
      expect((await probe.read(server.fieldNodeId('BIRK', 'TemperatureC'))).asDouble, -4.0);
      expect((await probe.read(server.fieldNodeId('BIRK', 'WindSpeedKt'))).asDouble, 25.0);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('station nodes: one struct per ICAO id, every field a child', () {
    late FakeMetarSource fake;
    late MetarRedundantServer server;
    late Client probe;
    late MetarObservation birk;
    late MetarObservation bikf;

    setUp(() async {
      // Three stations: two reporting, one (BIRG, Raufarhöfn) that the feed
      // knows but that never reports. BIKF's report is already old: the
      // airfield observed four hours ago and has been quiet since.
      birk = recent(ago: const Duration(minutes: 5));
      bikf = recent(station: 'BIKF', ago: const Duration(hours: 4));
      fake = FakeMetarSource.stations(['BIRK', 'BIKF', 'BIRG'], {'BIRK': birk, 'BIKF': bikf});
      server = MetarRedundantServer(
        instance: 'stations',
        port: 0,
        source: fake,
        pollInterval: const Duration(milliseconds: 200),
        staleAfter: const Duration(hours: 2),
        log: (_) {},
      );
      await server.start();
      probe = await setupClient(server.listenPort);
    });

    tearDown(() async {
      await probe.delete();
      await server.stop();
    });

    test('the struct node of a station is ns=1;s=<ICAO> under Objects, BrowseName and DisplayName <ICAO>', () async {
      expect(server.stations, ['BIRK', 'BIKF', 'BIRG']);
      expect(server.stationNodeId('BIRK'), NodeId.fromString(1, 'BIRK'));

      final objects = await probe.browse(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER));
      for (final station in server.stations) {
        final node = objects.singleWhere((r) => r.nodeId == NodeId.fromString(1, station));
        expect(node.browseName, station);
        expect(node.displayName, station);
        expect(node.referenceTypeId, NodeId.organizes);
        expect(node.nodeClass, NodeClass.UA_NODECLASS_VARIABLE);
      }

      // The struct's own Station field carries the same identifier.
      final v = await probe.readValue(server.stationNodeId('BIKF'));
      expect(v.value.typeId, server.metarTypeId);
      expect(v.value['Station'].value, 'BIKF');
      expect(v.value['RawText'].value, contains('METAR BIKF'));
      expect((v.value['TemperatureC'].value as num).toDouble(), 5.0);
      expect((await probe.readValue(server.stationNodeId('BIRK'))).value['Station'].value, 'BIRK');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('every schema field is a HasComponent child with the struct\'s value, status and timestamp', () async {
      for (final station in ['BIRK', 'BIKF']) {
        final struct = await probe.readValue(server.stationNodeId(station));
        final fields = struct.value.asObject.keys.toList();
        expect(fields, server.fieldNames);
        expect(fields, hasLength(19));

        // Browse: exactly the schema fields, as HasComponent (open62541
        // returns references in its own order, not insertion order), each at
        // ns=1;s=<ICAO>.<Field> with BrowseName <Field>.
        final children = await probe.browse(server.stationNodeId(station), referenceTypeId: NodeId.hasComponent);
        expect(children.map((c) => c.browseName), unorderedEquals(fields), reason: 'generated from the schema');
        expect(children, hasLength(fields.length));
        for (final child in children) {
          expect(child.nodeId, server.fieldNodeId(station, child.browseName));
          expect(child.nodeId, NodeId.fromString(1, '$station.${child.browseName}'));
          expect(child.displayName, child.browseName);
          expect(child.isForward, isTrue);
          expect(child.nodeClass, NodeClass.UA_NODECLASS_VARIABLE);
        }
        // And nothing else hangs off the struct node.
        final all = await probe.browse(server.stationNodeId(station), referenceTypeId: NodeId.hierarchicalReferences);
        expect(all.map((c) => c.nodeId).toSet(), children.map((c) => c.nodeId).toSet());

        // Read: the child's value is the struct member's; the status and the
        // source timestamp are the struct's, whatever they are.
        for (final field in fields) {
          final child = await probe.readValue(server.fieldNodeId(station, field));
          final member = struct.value[field];
          expect(child.statusCode, struct.statusCode, reason: '$station.$field status');
          expect(child.sourceTimestamp, struct.sourceTimestamp, reason: '$station.$field source timestamp');
          expect(child.value.typeId, member.typeId, reason: '$station.$field DataType');
          expect(child.value.isObject, isFalse);
          final actual = child.value.value, expected = member.value;
          if (expected is double && expected.isNaN) {
            expect((actual as num).toDouble().isNaN, isTrue, reason: '$station.$field');
          } else {
            expect(actual, expected, reason: '$station.$field');
          }
        }
        // The DataType attribute of a child is the field's scalar type.
        final types = await probe.readAttribute({
          server.fieldNodeId(station, 'TemperatureC'): [AttributeId.UA_ATTRIBUTEID_DATATYPE],
          server.fieldNodeId(station, 'ObservationTime'): [AttributeId.UA_ATTRIBUTEID_DATATYPE],
          server.fieldNodeId(station, 'WindDirectionDeg'): [AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expect(types[server.fieldNodeId(station, 'TemperatureC')]!.typeId, NodeId.double);
        expect(types[server.fieldNodeId(station, 'ObservationTime')]!.typeId, NodeId.datetime);
        expect(types[server.fieldNodeId(station, 'WindDirectionDeg')]!.typeId, NodeId.int32);
      }

      // Concretely, for the quiet station: Uncertain, four hours old, and the
      // children say exactly the same.
      final struct = await probe.readValue(server.stationNodeId('BIKF'));
      expect(struct.statusCode, UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE);
      expect(struct.sourceTimestamp, bikf.observationTime);
      final temperature = await probe.readValue(server.fieldNodeId('BIKF', 'TemperatureC'));
      expect(temperature.statusCode, UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE);
      expect(temperature.sourceTimestamp, bikf.observationTime);
      expect((temperature.value.value as num).toDouble(), 5.0);
      expect(
        (await probe.readValue(server.fieldNodeId('BIKF', 'ObservationTime'))).value.asDateTime,
        bikf.observationTime,
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the old node ids are gone', () async {
      for (final old in ['BIRK.Metar', 'BIKF.Metar']) {
        final dv = await probe.readValue(NodeId.fromString(1, old));
        expect(dv.statusCode, UA_STATUSCODE_BADNODEIDUNKNOWN, reason: 'ns=1;s=$old');
      }
      // `<ICAO>.TemperatureC` still exists, but as a child of the struct
      // node, not as a top-level node under Objects.
      final objects = await probe.browse(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER));
      expect(objects.map((r) => r.nodeId), isNot(contains(NodeId.fromString(1, 'BIRK.TemperatureC'))));
      expect(objects.map((r) => r.nodeId), isNot(contains(NodeId.fromString(1, 'BIRK.WindSpeedKt'))));
      expect(objects.map((r) => r.browseName), isNot(contains('BIRK METAR')));
      expect(objects.map((r) => r.browseName), contains('BIRK'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a station that never reported reads Bad_NoData, a quiet one Uncertain_LastUsableValue, '
        'and neither lowers the ServiceLevel', () async {
      expect(fake.fetches, greaterThan(0));
      expect(server.consecutiveFailures, 0);

      // BIRG: known, never reported. No last-known value exists, so the read
      // fails outright — with NoData, not NoCommunication: the feed answered.
      final never = await probe.readValue(server.stationNodeId('BIRG'));
      expect(never.statusCode, UA_STATUSCODE_BADNODATA);
      expect(never.value.value, isNull);
      expect((await probe.readValue(server.fieldNodeId('BIRG', 'TemperatureC'))).statusCode, UA_STATUSCODE_BADNODATA);
      expect(server.lastObservation('BIRG'), isNull);
      expect(server.stationDataAge('BIRG'), isNull);

      // BIKF: last report four hours ago with a two-hour threshold.
      final quiet = await probe.readValue(server.stationNodeId('BIKF'));
      expect(quiet.statusCode, UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE);
      expect(quiet.value['Station'].value, 'BIKF');
      expect(quiet.sourceTimestamp, bikf.observationTime);

      // BIRK: fresh.
      final fresh = await probe.readValue(server.stationNodeId('BIRK'));
      expect(fresh.statusCode, UA_STATUSCODE_GOOD);

      // ServiceLevel is the FEED's: fetches succeed and the newest report is
      // fresh, so the silent and the quiet station cost nothing.
      expect((await probe.read(NodeId.serviceLevel)).asInt, 250);
      expect(server.serviceLevel, 250);
      expect(server.dataAge, lessThan(const Duration(hours: 1)));

      // A station that falls silent AT A POLL keeps its last observation as
      // Good while it is fresh: BIRK stops reporting; the fetches go on
      // succeeding without it.
      fake.observations.remove('BIRK');
      final before = fake.fetches;
      expect(await waitUntil(() => fake.fetches > before + 1), isTrue);
      final kept = await probe.readValue(server.stationNodeId('BIRK'));
      expect(kept.statusCode, UA_STATUSCODE_GOOD, reason: 'silence is not a failure, and the value is still fresh');
      expect(kept.value['RawText'].value, birk.rawText);
      expect(kept.sourceTimestamp, birk.observationTime);
      expect(server.serviceLevel, 250);

      // A fresh report for the quiet station brings it back to Good at once.
      final late = recent(station: 'BIKF', ago: const Duration(minutes: 1));
      fake.observations['BIKF'] = late;
      // (Same raw text as before, a minute old: the observation time is what
      // distinguishes the new report.)
      expect(await waitUntil(() => server.lastObservation('BIKF')?.observationTime == late.observationTime), isTrue);
      final back = await probe.readValue(server.stationNodeId('BIKF'));
      expect(back.statusCode, UA_STATUSCODE_GOOD);
      expect(back.sourceTimestamp, late.observationTime);

      // Only the feed failing is Bad_NoCommunication, for every station that
      // has a value; the one that never had one stays NoData, and now the
      // ServiceLevel does fall.
      fake.failing = true;
      expect(await waitUntil(() => server.consecutiveFailures > 0), isTrue);
      expect((await probe.readValue(server.stationNodeId('BIRK'))).statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect((await probe.readValue(server.stationNodeId('BIKF'))).statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(
        (await probe.readValue(server.fieldNodeId('BIKF', 'WindSpeedKt'))).statusCode,
        UA_STATUSCODE_BADNOCOMMUNICATION,
      );
      expect((await probe.readValue(server.stationNodeId('BIRG'))).statusCode, UA_STATUSCODE_BADNODATA);
      expect(server.serviceLevel, lessThan(serviceLevelHealthyFloor));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('every station of the list is published when the source covers it', () async {
      final all = [for (final s in icelandMetarStations) s.icao];
      expect(all, hasLength(15));
      expect(all.toSet(), hasLength(15), reason: 'no duplicate ICAO ids');
      expect(all.where((s) => !RegExp(r'^BI[A-Z]{2}$').hasMatch(s)), isEmpty, reason: 'Icelandic indicators');
      expect(icelandMetarStations.where((s) => s.silent).map((s) => s.icao), ['BIRG', 'BIST']);
      expect(metarStationName('BIRK'), 'Reykjavík');
      expect(metarStationName('ZZZZ'), 'ZZZZ');

      // Default --station: the whole list; a comma list and repeats filter it.
      expect(parseStations(const []), all);
      expect(parseStations(['birk,BIKF', 'BIAR', 'bikf']), ['BIRK', 'BIKF', 'BIAR']);

      final wide = FakeMetarSource.stations(all, {
        for (final s in all)
          if (s != 'BIRG' && s != 'BIST') s: recent(station: s),
      });
      final wideServer = MetarRedundantServer(
        instance: 'iceland',
        port: 0,
        source: wide,
        pollInterval: const Duration(seconds: 30),
        log: (_) {},
      );
      await wideServer.start();
      final wideProbe = await setupClient(wideServer.listenPort);
      addTearDown(() async {
        await wideProbe.delete();
        await wideServer.stop();
      });

      final objects = await wideProbe.browse(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER));
      final published = objects.map((r) => r.browseName).where(all.contains).toList();
      expect(published, all, reason: 'one struct node per station, in list order');
      for (final station in all) {
        final dv = await wideProbe.readValue(wideServer.stationNodeId(station));
        if (station == 'BIRG' || station == 'BIST') {
          expect(dv.statusCode, UA_STATUSCODE_BADNODATA, reason: station);
        } else {
          expect(dv.statusCode, UA_STATUSCODE_GOOD, reason: station);
          expect(dv.value['Station'].value, station);
        }
        final children = await wideProbe.browse(
          wideServer.stationNodeId(station),
          referenceTypeId: NodeId.hasComponent,
        );
        expect(children.map((c) => c.browseName), unorderedEquals(wideServer.fieldNames), reason: station);
      }
      expect(wideServer.serviceLevel, 250, reason: 'two silent stations do not degrade the feed');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
