/*
  One half of a redundant OPC UA server pair publishing live METAR weather
  for the Icelandic aerodromes.

  Run the same file twice to get the pair (see example/README.md):

    dart run example/metar_redundant_server.dart --instance metar-a --port 4840 \
        --peer urn:localhost:metar:metar-b=opc.tcp://localhost:4841
    dart run example/metar_redundant_server.dart --instance metar-b --port 4841 \
        --peer urn:localhost:metar:metar-a=opc.tcp://localhost:4840

  What each instance demonstrates:

   * A custom structured DataType (`addCustomType` + `addDataTypeNode`) holding
     a decoded observation, served for every station from a DATA-SOURCE
     variable node named by the station's ICAO identifier (`ns=1;s=BIRK`)
     through `onReadValue`, so every read carries a real OPC UA StatusCode and
     the observation's own sourceTimestamp. Under each struct node, one
     HasComponent child per struct field (`ns=1;s=BIRK.TemperatureC`, ...),
     generated from the schema, carries the same value, status and
     timestamp for clients without custom-struct support.
   * Per-station quality: a station the feed has no current report for keeps
     its last observation, `Uncertain_LastUsableValue` once it is older than
     the staleness threshold, and `Bad_NoData` if it never reported. Only a
     failure of the feed itself makes the data `Bad_NoCommunication` and
     lowers the ServiceLevel.
   * The Part 4 / Part 5 non-transparent redundancy surface on the STANDARD
     NS0 nodes: ServiceLevel (i=2267) computed live from this instance's own
     health and reported in the Part 4 bands (Maintenance / NoData / Degraded
     / Healthy) through `Server.setVariableValueSource`, and the set itself
     through `Server.setRedundancy`: Server/ServerRedundancy typed
     NonTransparentNetworkRedundancyType (Part 5 §6.3.7 forbids a non-None
     RedundancySupport on the base type), RedundancySupport (i=3709) = Hot,
     ServerUriArray listing the ApplicationUris of both members and
     ServerNetworkGroups (§6.3.10) mapping each of those URIs to the member's
     endpoint, so a client given ONE endpoint finds the rest. Each instance
     announces its own ApplicationUri (`urn:<host>:metar:<instance>` by
     default), as Part 4 requires of the members of a non-transparent set.
     No vendor-specific nodes: any standards-based client can discover and
     rank the set.
*/

import 'dart:async';
import 'dart:io';

import 'package:open62541/open62541.dart';

import 'metar_common.dart';

/// The ServiceLevel bands of OPC 10000-4 §6.6.2.4.2, Table 105.
///
/// * `0` Maintenance: clients shall not connect, connected clients disconnect.
/// * `1` NoData: not operational; only ServiceLevel, ServerStatus and the
///   diagnostics can be read.
/// * `2`-`199` Degraded: the server works, partly.
/// * `200`-`255` Healthy.
const int serviceLevelMaintenance = 0;
const int serviceLevelNoData = 1;
const int serviceLevelDegradedFloor = 2;
const int serviceLevelHealthyFloor = 200;

/// Whether [level] is in the Healthy band (200-255).
bool isHealthyServiceLevel(int level) => level >= serviceLevelHealthyFloor;

/// A METAR-publishing OPC UA server that advertises itself as one member of a
/// hot-redundant set.
///
/// Exposed as a class (rather than living inside `main`) so the integration
/// test can run two of them in-process with a fake [MetarSource] and no
/// network.
class MetarRedundantServer {
  MetarRedundantServer({
    required this.instance,
    required this.port,
    required this.source,
    this.host = 'localhost',
    String? applicationUri,
    Map<String, List<String>> peers = const {},
    this.pollInterval = const Duration(minutes: 5),
    this.staleAfter = const Duration(hours: 2),
    this.logLevel = LogLevel.UA_LOGLEVEL_ERROR,
    void Function(String message)? log,
  }) : applicationUri = applicationUri ?? defaultApplicationUri(host, instance),
       _peers = {for (final e in peers.entries) e.key: List.unmodifiable(e.value)},
       _log = log ?? print;

  /// The ApplicationUri an instance announces unless one is given:
  /// `urn:<host>:metar:<instance>`.
  static String defaultApplicationUri(String host, String instance) => 'urn:$host:metar:$instance';

  /// Human-readable name of this instance, used in log lines and as the
  /// ApplicationName.
  final String instance;

  final String host;

  /// The port to listen on; `0` lets the OS pick one (see [listenPort]).
  final int port;

  /// Where the observations come from. Injected so tests can supply a fake.
  final MetarSource source;

  /// This instance's ApplicationUri: its identity as a member of the redundant
  /// set. OPC 10000-4 §6.6.2.4 requires the members of a non-transparent set
  /// to have unique ApplicationUris; the server announces it in its
  /// ApplicationDescription (GetEndpoints / FindServers) and as
  /// `Server/ServerArray[0]` (ns=0;i=2254), and lists it first in
  /// `ServerUriArray`.
  final String applicationUri;

  /// The other members of the redundant set: ApplicationUri to the endpoint
  /// URLs it can be reached at (an empty list for a member whose address is
  /// not known; it is still listed in `ServerUriArray`). See [setPeer].
  Map<String, List<String>> get peers => Map.unmodifiable(_peers);
  final Map<String, List<String>> _peers;

  /// How often to re-fetch the observations.
  final Duration pollInterval;

  /// How old a station's observation may get before it is served as
  /// `Uncertain_LastUsableValue`, and how old the newest observation of the
  /// whole feed may get before this server's ServiceLevel starts falling.
  final Duration staleAfter;

  final LogLevel logLevel;
  final void Function(String message) _log;

  /// The port the server listens on: [port], or, for `port: 0`, the one the
  /// OS picked once [start] has returned.
  int get listenPort => _server?.port ?? port;

  /// `opc.tcp://` URL clients use to reach this instance.
  String get endpoint => 'opc.tcp://$host:$listenPort';

  /// Secure channels (connections) open on this instance right now (`null`
  /// before [start]): what a redundant client's disconnect on Maintenance
  /// looks like from here. Channels, not sessions: a client's reconnect can
  /// leave a superseded session on the server until it times out, while a
  /// disconnect closes the channel at once.
  int? get connectionCount => _server?.statistics.currentChannelCount;

  /// The stations this server publishes, in the order of their nodes.
  List<String> get stations => source.stations;

  /// DataType node of the published structure.
  NodeId get metarTypeId => NodeId.fromString(1, 'MetarObservationType');

  /// The struct-valued data-source node carrying a station's whole
  /// observation: `ns=1;s=<ICAO>`, BrowseName `<ICAO>`.
  NodeId stationNodeId(String station) => NodeId.fromString(1, station);

  /// The scalar child of a station's struct node that mirrors one field:
  /// `ns=1;s=<ICAO>.<Field>`, BrowseName `<Field>`, a HasComponent of
  /// [stationNodeId]. There is one per entry of [fieldNames].
  NodeId fieldNodeId(String station, String field) => NodeId.fromString(1, '$station.$field');

  /// The field names of the structure, in declaration order — the same
  /// list the child nodes are generated from, so the two cannot drift apart.
  List<String> get fieldNames => [for (final e in _metarSchema().entries) e.key];

  Server? _server;
  Timer? _pollTimer;
  bool _pumping = false;

  final Map<String, MetarObservation> _last = {};
  final Map<String, DateTime> _lastObservedAt = {};
  DateTime? _lastFeedSuccess;
  int _consecutiveFailures = 0;
  bool _shuttingDown = false;
  int? _forcedServiceLevel;

  /// The most recent successfully decoded observation of [station], if any.
  MetarObservation? lastObservation(String station) => _last[station];

  /// Every station that has reported at least once, with its newest
  /// observation.
  Map<String, MetarObservation> get lastObservations => Map.unmodifiable(_last);

  /// Number of consecutive failed fetches since the last success.
  int get consecutiveFailures => _consecutiveFailures;

  /// Overrides [serviceLevel] with a fixed value (or `null` to go back to the
  /// computed one). This is what `--service-level` drives, so a failover can
  /// be demonstrated without killing a process.
  void forceServiceLevel(int? level) {
    _forcedServiceLevel = level?.clamp(0, 255);
    _log('[$instance] ServiceLevel override: ${_forcedServiceLevel ?? 'cleared'} (now $serviceLevel)');
  }

  /// Age of the newest observation this server holds, over all stations, or
  /// `null` if it has none. This is the feed's age: one station that has
  /// gone quiet for the night does not make the feed stale, a feed whose
  /// newest report is hours old does.
  Duration? get dataAge {
    DateTime? newest;
    for (final at in _lastObservedAt.values) {
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return newest == null ? null : DateTime.now().toUtc().difference(newest);
  }

  /// Age of [station]'s newest observation, or `null` if it never reported.
  Duration? stationDataAge(String station) {
    final at = _lastObservedAt[station];
    return at == null ? null : DateTime.now().toUtc().difference(at);
  }

  /// This instance's OPC UA ServiceLevel (0-255), computed honestly from its
  /// own state — this is the number the failover client ranks servers by.
  ///
  /// It describes the FEED, not any one station: a small airfield that
  /// reports only in opening hours is silent most of the day, and that
  /// silence is not a fault of this server. The ladder, within the bands of
  /// OPC 10000-4 §6.6.2.4.2 (Table 105):
  ///  * `0`   — Maintenance: shutting down. Clients shall disconnect and not
  ///            come back.
  ///  * `1`   — NoData: no station has ever reported. The server is up and
  ///            will have data on its next poll, so it must not claim
  ///            Maintenance; it has nothing to serve yet, so it is not
  ///            Degraded either.
  ///  * `250` — Healthy: the newest observation is younger than [staleAfter]
  ///            and the last fetch succeeded. 250 rather than 255 leaves
  ///            headroom above for an operator-designated preferred server.
  ///  * `100` — Degraded: the newest observation is older than [staleAfter]
  ///            but younger than twice that.
  ///  * `5`   — Degraded: older than that: still alive, nearly useless.
  ///  * minus 60 per consecutive failed fetch, floored at 2 — the bottom of
  ///    the Degraded band. A server that still serves its last-known values
  ///    (flagged `Bad_NoCommunication`) is still exchanging data, so it never
  ///    reports NoData, let alone Maintenance.
  int get serviceLevel {
    if (_shuttingDown) return serviceLevelMaintenance;
    final forced = _forcedServiceLevel;
    if (forced != null) return forced;
    final age = dataAge;
    if (age == null) return serviceLevelNoData;

    var level = age <= staleAfter
        ? 250
        : age <= staleAfter * 2
        ? 100
        : 5;
    level -= 60 * _consecutiveFailures;
    return level.clamp(serviceLevelDegradedFloor, 255);
  }

  /// Starts the server, publishes the address space and performs the first
  /// fetch. Completes once the server is serving (even if that first fetch
  /// failed — it then serves Bad_NoCommunication, which is the point).
  Future<void> start() async {
    if (_server != null) throw StateError('already started');
    // The identity goes in through the constructor: open62541 copies the
    // ApplicationUri into ServerArray[0] and NamespaceArray[1] at creation.
    final server = Server(
      port: port,
      logLevel: logLevel,
      applicationName: 'METAR $instance',
      applicationUri: applicationUri,
    );
    _server = server;
    server.start();

    _pumping = true;
    unawaited(_pump(server));

    _publishMetarNodes(server);
    _publishRedundancySurface(server);

    _log(
      '[$instance] listening on $endpoint as $applicationUri (set: ${_serverUriArray().join(', ')}); '
      'publishing ${stations.length} stations: ${stations.map((s) => '$s ${metarStationName(s)}').join(', ')}',
    );

    await _poll();
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
  }

  Future<void> _pump(Server server) async {
    // runIterate() defaults to a non-blocking poll; the delay throttles the
    // loop so several servers/clients can share one isolate without spinning.
    while (_pumping && server.runIterate()) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The ServerUris of the set, this member first (OPC 10000-5 §6.3.9).
  List<String> _serverUriArray() => [applicationUri, ..._peers.keys];

  void _publishMetarNodes(Server server) {
    server.addCustomType(metarTypeId, _metarSchema());
    server.addDataTypeNode(
      metarTypeId,
      'MetarObservationType',
      displayName: LocalizedText('METAR Observation', 'en-US'),
    );

    for (final station in stations) {
      // The flagship node, one per station, named by its ICAO identifier.
      // `onReadValue` (rather than `onRead`) is what lets the server answer
      // with a value AND a status AND the observation's own source timestamp
      // — so a client can tell "this is 3 minutes old and Good" from "this
      // is the same number, but it is 4 hours old and the station has not
      // reported since".
      server.addDataSourceVariableNode(
        stationNodeId(station),
        browseName: station,
        typeId: metarTypeId,
        onReadValue: () => _readObservation(station),
      );

      // One scalar child per struct field, so the example is browsable
      // without custom-struct support. Generated from the schema: a field
      // added to the structure gets its child node for free, and the two can
      // never list different fields. Each child carries the same status and
      // source timestamp as the struct it mirrors.
      for (final field in _metarSchema().entries) {
        server.addDataSourceVariableNode(
          fieldNodeId(station, field.key),
          browseName: field.key,
          typeId: field.value.typeId,
          parentNodeId: stationNodeId(station),
          parentReferenceNodeId: NodeId.hasComponent,
          onReadValue: () => _mirror(station, field.key),
        );
      }
    }
  }

  /// Publishes this instance's health and its place in the set on the
  /// standard NS0 nodes.
  ///
  /// open62541 pins `ServiceLevel` at 255 through an internal callback that
  /// accepts no write; [Server.setVariableValueSource] swaps the value source
  /// of that existing node, which is the only way to publish a real service
  /// level. The set itself is [_publishSet]'s job.
  void _publishRedundancySurface(Server server) {
    server.setVariableValueSource(
      NodeId.serviceLevel,
      onRead: () => DynamicValue(value: serviceLevel, typeId: NodeId.byte, name: 'ServiceLevel'),
    );
    _publishSet(server);
  }

  /// [Server.setRedundancy] with the members and their endpoints: it retypes
  /// `Server/ServerRedundancy` to `NonTransparentNetworkRedundancyType`
  /// (creating the types and DataType nodes the reduced NS0 lacks), serves
  /// `RedundancySupport`, adds `ServerUriArray` (OPC 10000-5 §6.3.9: the
  /// ServerUris, i.e. the ApplicationUris, of the members, the local one
  /// first -- identities, not addresses) and `ServerNetworkGroups` (§6.3.10:
  /// for each of those URIs the endpoints it answers at, which is how a
  /// client seeded with one member's endpoint finds the others). Every
  /// member of the set runs and serves data continuously and the client
  /// picks one by ServiceLevel, which is what `Hot` means. Called again
  /// whenever the set changes ([setPeer]); the arrays update in place.
  void _publishSet(Server server) {
    server.setRedundancy(
      RedundancySupport.hot,
      serverUris: _serverUriArray(),
      networkGroups: {
        applicationUri: [endpoint],
        ..._peers,
      },
    );
  }

  /// The status a read of [station] carries, given that it has an
  /// observation.
  ///
  /// * `Bad_NoCommunication` while the feed itself is failing: the value is
  ///   the last one received before the feed went down, and nothing newer
  ///   can be known until it is back.
  /// * `Uncertain_LastUsableValue` when the feed is fine but this station's
  ///   newest report is older than [staleAfter]: the station has not
  ///   reported since (closed for the night, sensor out), the value is the
  ///   last usable one and is served with its original timestamp so the
  ///   client can judge for itself.
  /// * `Good` otherwise.
  int _statusOf(String station) {
    if (_consecutiveFailures > 0) return UA_STATUSCODE_BADNOCOMMUNICATION;
    final age = stationDataAge(station);
    if (age == null || age > staleAfter) return UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE;
    return UA_STATUSCODE_GOOD;
  }

  /// What a read of a station that has never reported fails with: there is
  /// no last-known value to serve, so the read fails outright rather than
  /// inventing a zeroed struct. `Bad_NoData` when the feed answers and simply
  /// has nothing for this station (a station closed for the season, or one
  /// that is listed but does not observe); `Bad_NoCommunication` when the
  /// feed has never answered at all, so nothing is known about anything.
  UaStatusException _neverReported() =>
      UaStatusException(_lastFeedSuccess == null ? UA_STATUSCODE_BADNOCOMMUNICATION : UA_STATUSCODE_BADNODATA);

  /// The data-source read for a station's struct node.
  ///
  /// This is the behaviour PR #99 made possible and the whole reason the node
  /// uses `onReadValue`: when the upstream feed is unreachable, or the
  /// station's newest observation has aged past [staleAfter], the server
  /// keeps serving the LAST KNOWN value but flags it ([_statusOf]) and keeps
  /// its ORIGINAL source timestamp. A client therefore sees stale-but-useful
  /// data with honest quality, instead of either a hole or a silent lie.
  DataSourceValue _readObservation(String station) {
    final last = _last[station];
    if (last == null) throw _neverReported();
    return DataSourceValue(
      value: _project(last),
      statusCode: _statusOf(station),
      sourceTimestamp: _lastObservedAt[station],
    );
  }

  /// The data-source read for one field child of a station: the matching
  /// member of the projected struct, with the struct's status and timestamp.
  DataSourceValue _mirror(String station, String field) {
    final last = _last[station];
    if (last == null) throw _neverReported();
    return DataSourceValue(
      value: _project(last)[field],
      statusCode: _statusOf(station),
      sourceTimestamp: _lastObservedAt[station],
    );
  }

  Future<void> _poll() async {
    try {
      final observations = await source.fetch();
      final now = DateTime.now().toUtc();
      _consecutiveFailures = 0;
      _lastFeedSuccess = now;
      final reported = <String>[];
      for (final station in stations) {
        final observation = observations[station];
        if (observation == null) continue;
        _last[station] = observation;
        _lastObservedAt[station] = (observation.observationTime ?? now).toUtc();
        reported.add('$station ${_hhmm(_lastObservedAt[station]!)}');
      }
      final silent = stations.where((s) => !observations.containsKey(s));
      _log(
        '[$instance] feed ok: ${reported.length} of ${stations.length} stations reported'
        '${reported.isEmpty ? '' : ' (${reported.join(', ')})'}'
        '${silent.isEmpty ? '' : '; silent: ${silent.join(', ')}'}'
        ' -> ServiceLevel $serviceLevel',
      );
    } catch (error) {
      _consecutiveFailures++;
      _log(
        '[$instance] fetch failed ($_consecutiveFailures in a row): $error '
        '-> serving last known values with Bad_NoCommunication, ServiceLevel $serviceLevel',
      );
    }
  }

  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}Z';

  /// Field schema of the published structure.
  ///
  /// OPC UA struct members cannot be null, so "not reported" is encoded with
  /// documented sentinels: `NaN` for the doubles and `-1` for the integers.
  /// Consumers should test for them rather than treating -1 as a heading.
  /// The child nodes under each station are generated from this very list.
  DynamicValue _metarSchema() {
    final s = DynamicValue(name: 'MetarObservationType', typeId: metarTypeId);
    s['Station'] = DynamicValue(value: '', typeId: NodeId.uastring);
    s['ObservationTime'] = DynamicValue(value: DateTime.utc(1970), typeId: NodeId.datetime);
    s['ReportType'] = DynamicValue(value: '', typeId: NodeId.uastring);
    s['Automatic'] = DynamicValue(value: false, typeId: NodeId.boolean);
    s['TemperatureC'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['DewPointC'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['RelativeHumidityPct'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['WindDirectionDeg'] = DynamicValue(value: -1, typeId: NodeId.int32);
    s['WindVariable'] = DynamicValue(value: false, typeId: NodeId.boolean);
    s['WindSpeedKt'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['WindGustKt'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['VisibilityMeters'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['Cavok'] = DynamicValue(value: false, typeId: NodeId.boolean);
    s['CeilingFeet'] = DynamicValue(value: -1, typeId: NodeId.int32);
    s['AltimeterHPa'] = DynamicValue(value: double.nan, typeId: NodeId.double);
    s['SkyCondition'] = DynamicValue(value: '', typeId: NodeId.uastring);
    s['PresentWeather'] = DynamicValue(value: '', typeId: NodeId.uastring);
    s['FlightCategory'] = DynamicValue(value: '', typeId: NodeId.uastring);
    s['RawText'] = DynamicValue(value: '', typeId: NodeId.uastring);
    return s;
  }

  DynamicValue _project(MetarObservation o) {
    final s = _metarSchema();
    s['Station'].value = o.station;
    s['ObservationTime'].value = (o.observationTime ?? _lastObservedAt[o.station] ?? DateTime.utc(1970)).toUtc();
    s['ReportType'].value = o.reportType;
    s['Automatic'].value = o.automatic;
    s['TemperatureC'].value = o.temperatureC ?? double.nan;
    s['DewPointC'].value = o.dewPointC ?? double.nan;
    s['RelativeHumidityPct'].value = o.relativeHumidityPercent ?? double.nan;
    s['WindDirectionDeg'].value = o.windDirectionDeg ?? -1;
    s['WindVariable'].value = o.windVariable;
    s['WindSpeedKt'].value = o.windSpeedKt ?? double.nan;
    s['WindGustKt'].value = o.windGustKt ?? double.nan;
    s['VisibilityMeters'].value = o.visibilityMeters ?? double.nan;
    s['Cavok'].value = o.cavok;
    s['CeilingFeet'].value = o.ceilingFeet ?? -1;
    s['AltimeterHPa'].value = o.altimeterHPa ?? double.nan;
    s['SkyCondition'].value = o.skyConditionText;
    s['PresentWeather'].value = o.presentWeather.join(' ');
    s['FlightCategory'].value = o.flightCategory.code;
    s['RawText'].value = o.rawText;
    return s;
  }

  /// Adds or updates the peer [uri] with the endpoints it answers at, and
  /// republishes `ServerUriArray` / `ServerNetworkGroups` when the server is
  /// running: a member whose address changed, or one that was started after
  /// this instance on an OS-picked port.
  void setPeer(String uri, List<String> endpoints) {
    _peers[uri] = List.unmodifiable(endpoints);
    final server = _server;
    if (server != null) {
      _publishSet(server);
      _log(
        '[$instance] set: ${_serverUriArray().join(', ')}; $uri at ${endpoints.isEmpty ? '(unknown)' : endpoints.join(', ')}',
      );
    }
  }

  /// Stops polling and shuts the server down, orderly when given a [delay].
  ///
  /// With a delay the hand-off is the one Part 5 §12.6 and Part 4 Table 105
  /// describe, done by [Server.shutdown]: the server announces the shutdown
  /// (`ServerStatus.State` = Shutdown, `SecondsTillShutdown` counting down)
  /// and, with `announceServiceLevel`, serves `ServiceLevel` 0, the signal
  /// for the clients of a redundant set to leave, while every read, write
  /// and subscription is still served for the whole delay. A redundant
  /// client therefore moves on while the data is still Good, instead of
  /// just losing the socket. The call blocks this isolate for the delay
  /// (open62541 is pumped by the shutdown itself), which is fine for a
  /// server process; a test observes it from another isolate.
  Future<void> stop({Duration delay = Duration.zero}) async {
    final server = _server;
    if (server == null) return;
    _shuttingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pumping = false;
    // Let the pump loop observe _pumping == false and return: the shutdown
    // pumps the server itself and then deletes it.
    await Future.delayed(const Duration(milliseconds: 50));
    if (delay > Duration.zero) {
      _log('[$instance] going out of service: State = Shutdown, ServiceLevel 0 for $delay, then shutdown');
    }
    server.shutdown(delay: delay, announceServiceLevel: true);
    server.delete();
    _server = null;
    source.close();
    _log('[$instance] stopped');
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    stdout.write(_usage);
    return;
  }

  final server = MetarRedundantServer(
    instance: options.instance,
    port: options.port,
    host: options.host,
    applicationUri: options.applicationUri,
    peers: options.peers,
    pollInterval: options.pollInterval,
    staleAfter: options.staleAfter,
    source: AviationWeatherMetarSource(options.stations, useRawTextEndpoint: options.useText),
  );
  if (options.serviceLevel != null) server.forceServiceLevel(options.serviceLevel);

  await server.start();

  // Ctrl-C: announce the shutdown (State = Shutdown, ServiceLevel 0), keep
  // serving for the delay so a connected client moves to the other member,
  // then shut down.
  final signals = StreamController<void>();
  ProcessSignal.sigint.watch().listen((_) => signals.add(null));
  await signals.stream.first;
  await server.stop(delay: const Duration(seconds: 2));
  exit(0);
}

const String _usage = '''
Usage: dart run example/metar_redundant_server.dart [options]

  --instance <name>     Instance name used in log lines (default: metar-a)
  --port <n>            TCP port to listen on (default: 4840)
  --host <name>         Host name published in this server's endpoint URL and
                        used in the default ApplicationUri (default: localhost)
  --uri <uri>           This server's ApplicationUri, its identity in the
                        redundant set (default: urn:<host>:metar:<instance>)
  --peer <uri>[=<url>]  A peer: its ApplicationUri and, after `=`, an
                        endpoint URL it answers at. Repeatable (also for a
                        second URL of the same peer). Published in
                        ServerUriArray after this server's own, and in
                        ServerNetworkGroups, which is where a client seeded
                        with this server's endpoint learns the peer's.
  --station <ICAO>      Publish only these stations: repeatable, or a comma
                        list (`--station BIRK,BIKF`). Default: every Icelandic
                        METAR station (see icelandMetarStations in
                        metar_common.dart). An identifier outside that list is
                        accepted and fetched from the same feed.
  --poll <seconds>      Fetch interval (default: 300)
  --stale <seconds>     Age at which a station's observation is served as
                        Uncertain_LastUsableValue, and at which the feed's
                        newest observation starts lowering the ServiceLevel
                        (default: 7200)
  --service-level <n>   Force ServiceLevel to a fixed 0-255 value instead of
                        computing it. Use this to demonstrate failover without
                        killing a process.
  --text                Use the NOAA plain-text endpoint (one request per
                        station) instead of the JSON API (one for all)
  --help
''';

class _Options {
  _Options({
    required this.instance,
    required this.port,
    required this.host,
    required this.applicationUri,
    required this.peers,
    required this.stations,
    required this.pollInterval,
    required this.staleAfter,
    required this.serviceLevel,
    required this.useText,
    required this.help,
  });

  final String instance;
  final int port;
  final String host;
  final String? applicationUri;
  final Map<String, List<String>> peers;
  final List<String> stations;
  final Duration pollInterval;
  final Duration staleAfter;
  final int? serviceLevel;
  final bool useText;
  final bool help;

  static _Options parse(List<String> args) {
    final flags = parseFlags(args);
    return _Options(
      instance: flags['instance']?.last ?? 'metar-a',
      port: int.parse(flags['port']?.last ?? '4840'),
      host: flags['host']?.last ?? 'localhost',
      applicationUri: flags['uri']?.last,
      peers: parsePeers(flags['peer'] ?? const []),
      stations: parseStations(flags['station'] ?? const []),
      pollInterval: Duration(seconds: int.parse(flags['poll']?.last ?? '300')),
      staleAfter: Duration(seconds: int.parse(flags['stale']?.last ?? '7200')),
      serviceLevel: flags['service-level'] == null ? null : int.parse(flags['service-level']!.last),
      useText: flags.containsKey('text'),
      help: flags.containsKey('help'),
    );
  }
}

/// `--station` values — each one an ICAO identifier or a comma-separated
/// list of them, in any case — as an upper-cased, de-duplicated list in the
/// order given. With no value at all: every station of [icelandMetarStations].
List<String> parseStations(List<String> values) {
  final out = <String>[];
  for (final value in values) {
    for (final id in value.split(',')) {
      final station = id.trim().toUpperCase();
      if (station.isNotEmpty && !out.contains(station)) out.add(station);
    }
  }
  return out.isEmpty ? [for (final s in icelandMetarStations) s.icao] : out;
}

/// `--peer` values, `<uri>` or `<uri>=<endpoint url>`, as a map from the
/// peer's ApplicationUri to its endpoint URLs (several entries for one URI
/// accumulate; a bare URI contributes no URL).
Map<String, List<String>> parsePeers(List<String> values) {
  final peers = <String, List<String>>{};
  for (final value in values) {
    final eq = value.indexOf('=');
    final uri = (eq < 0 ? value : value.substring(0, eq)).trim();
    if (uri.isEmpty) continue;
    final urls = peers.putIfAbsent(uri, () => []);
    if (eq >= 0 && value.substring(eq + 1).trim().isNotEmpty) urls.add(value.substring(eq + 1).trim());
  }
  return peers;
}

/// Tiny `--key value` / `--key=value` parser, so the examples stay free of
/// extra dependencies. Repeated keys accumulate (used by `--peer`); a bare
/// `--flag` maps to an empty list.
Map<String, List<String>> parseFlags(List<String> args) {
  final out = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    if (eq >= 0) {
      out.putIfAbsent(body.substring(0, eq), () => []).add(body.substring(eq + 1));
    } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out.putIfAbsent(body, () => []).add(args[++i]);
    } else {
      out.putIfAbsent(body, () => []);
    }
  }
  return out;
}
