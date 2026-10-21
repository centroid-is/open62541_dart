/*
  One half of a redundant OPC UA server pair publishing live METAR weather.

  Run the same file twice to get the pair (see example/README.md):

    dart run example/metar_redundant_server.dart --instance metar-a --port 4840 \
        --peer urn:localhost:metar:metar-b=opc.tcp://localhost:4841
    dart run example/metar_redundant_server.dart --instance metar-b --port 4841 \
        --peer urn:localhost:metar:metar-a=opc.tcp://localhost:4840

  What each instance demonstrates:

   * A custom structured DataType (`addCustomType` + `addDataTypeNode`) holding
     the decoded observation, served from a DATA-SOURCE variable node through
     `onReadValue` so every read carries a real OPC UA StatusCode and the
     observation's own sourceTimestamp.
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

  /// Where the observation comes from. Injected so tests can supply a fake.
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

  /// How often to re-fetch the observation.
  final Duration pollInterval;

  /// How old an observation may get before this server declares its data
  /// untrustworthy (Bad_NoCommunication + a falling ServiceLevel).
  final Duration staleAfter;

  final LogLevel logLevel;
  final void Function(String message) _log;

  /// The port the server listens on: [port], or, for `port: 0`, the one the
  /// OS picked once [start] has returned.
  int get listenPort => _server?.port ?? port;

  /// `opc.tcp://` URL clients use to reach this instance.
  String get endpoint => 'opc.tcp://$host:$listenPort';

  /// DataType node of the published structure.
  NodeId get metarTypeId => NodeId.fromString(1, 'MetarObservationType');

  /// The struct-valued data-source node carrying the whole observation.
  NodeId get metarNodeId => NodeId.fromString(1, '${source.station}.Metar');

  /// Plain scalar mirrors, for clients (and UaExpert sessions) without custom
  /// struct support.
  NodeId get temperatureNodeId => NodeId.fromString(1, '${source.station}.TemperatureC');
  NodeId get windSpeedNodeId => NodeId.fromString(1, '${source.station}.WindSpeedKt');

  Server? _server;
  Timer? _pollTimer;
  bool _pumping = false;

  MetarObservation? _last;
  DateTime? _lastObservedAt;
  int _consecutiveFailures = 0;
  bool _shuttingDown = false;
  int? _forcedServiceLevel;

  /// The most recent successfully decoded observation, if any.
  MetarObservation? get lastObservation => _last;

  /// Number of consecutive failed fetches since the last success.
  int get consecutiveFailures => _consecutiveFailures;

  /// Overrides [serviceLevel] with a fixed value (or `null` to go back to the
  /// computed one). This is what `--service-level` drives, so a failover can
  /// be demonstrated without killing a process.
  void forceServiceLevel(int? level) {
    _forcedServiceLevel = level?.clamp(0, 255);
    _log('[$instance] ServiceLevel override: ${_forcedServiceLevel ?? 'cleared'} (now $serviceLevel)');
  }

  /// Age of the newest observation this server holds, or `null` if it has none.
  Duration? get dataAge {
    final at = _lastObservedAt;
    return at == null ? null : DateTime.now().toUtc().difference(at);
  }

  /// This instance's OPC UA ServiceLevel (0-255), computed honestly from its
  /// own state — this is the number the failover client ranks servers by.
  ///
  /// The ladder, within the bands of OPC 10000-4 §6.6.2.4.2 (Table 105):
  ///  * `0`   — Maintenance: shutting down. Clients shall disconnect and not
  ///            come back.
  ///  * `1`   — NoData: never fetched anything. The server is up and will
  ///            have data on its next poll, so it must not claim Maintenance;
  ///            it has nothing to serve yet, so it is not Degraded either.
  ///  * `250` — Healthy: fresh data (younger than [staleAfter]) and the last
  ///            fetch succeeded. 250 rather than 255 leaves headroom above for
  ///            an operator-designated preferred server.
  ///  * `100` — Degraded: data older than [staleAfter] but younger than twice
  ///            that.
  ///  * `5`   — Degraded: data older than that: still alive, nearly useless.
  ///  * minus 60 per consecutive failed fetch, floored at 2 — the bottom of
  ///    the Degraded band. A server that still serves its last-known value
  ///    (flagged `Bad_NoCommunication`) is still exchanging data, so it never
  ///    reports NoData, let alone Maintenance.
  int get serviceLevel {
    if (_shuttingDown) return serviceLevelMaintenance;
    final forced = _forcedServiceLevel;
    if (forced != null) return forced;
    if (_last == null || _lastObservedAt == null) return serviceLevelNoData;

    final age = dataAge!;
    var level = age <= staleAfter
        ? 250
        : age <= staleAfter * 2
        ? 100
        : 5;
    level -= 60 * _consecutiveFailures;
    return level.clamp(serviceLevelDegradedFloor, 255);
  }

  /// True when the value this server serves should be flagged Bad.
  bool get _dataIsBad {
    if (_consecutiveFailures > 0) return true;
    final age = dataAge;
    return age == null || age > staleAfter;
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

    _log('[$instance] listening on $endpoint as $applicationUri (set: ${_serverUriArray().join(', ')})');

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

    // The flagship node. `onReadValue` (rather than `onRead`) is what lets the
    // server answer with a value AND a status AND the observation's own
    // source timestamp — so a client can tell "this is 3 minutes old and
    // Good" from "this is the same number, but it is 4 hours old and the
    // upstream feed is down".
    server.addDataSourceVariableNode(
      metarNodeId,
      browseName: '${source.station} METAR',
      typeId: metarTypeId,
      onReadValue: _readObservation,
    );

    // Scalar mirrors so the example is browsable without custom-struct
    // support. They carry the same quality as the struct.
    server.addDataSourceVariableNode(
      temperatureNodeId,
      browseName: '${source.station} Temperature',
      typeId: NodeId.double,
      onReadValue: () => _mirror('TemperatureC', NodeId.double, (o) => o.temperatureC ?? double.nan),
    );
    server.addDataSourceVariableNode(
      windSpeedNodeId,
      browseName: '${source.station} Wind Speed',
      typeId: NodeId.double,
      onReadValue: () => _mirror('WindSpeedKt', NodeId.double, (o) => o.windSpeedKt ?? double.nan),
    );
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

  /// The data-source read for the struct node.
  ///
  /// This is the behaviour PR #99 made possible and the whole reason the node
  /// uses `onReadValue`: when the upstream feed is unreachable, or the newest
  /// observation has aged past [staleAfter], the server keeps serving the LAST
  /// KNOWN value but flags it `Bad_NoCommunication` and keeps its ORIGINAL
  /// source timestamp. A client therefore sees stale-but-useful data with
  /// honest quality, instead of either a hole or a silent lie.
  DataSourceValue _readObservation() {
    final last = _last;
    if (last == null) {
      // Nothing was ever fetched: there is no last-known value to serve, so
      // fail the read outright rather than inventing a zeroed struct.
      throw const UaStatusException(UA_STATUSCODE_BADNOCOMMUNICATION);
    }
    return DataSourceValue(
      value: _project(last),
      statusCode: _dataIsBad ? UA_STATUSCODE_BADNOCOMMUNICATION : UA_STATUSCODE_GOOD,
      sourceTimestamp: _lastObservedAt,
    );
  }

  DataSourceValue _mirror(String name, NodeId typeId, double Function(MetarObservation) pick) {
    final last = _last;
    if (last == null) throw const UaStatusException(UA_STATUSCODE_BADNOCOMMUNICATION);
    return DataSourceValue(
      value: DynamicValue(value: pick(last), typeId: typeId, name: name),
      statusCode: _dataIsBad ? UA_STATUSCODE_BADNOCOMMUNICATION : UA_STATUSCODE_GOOD,
      sourceTimestamp: _lastObservedAt,
    );
  }

  Future<void> _poll() async {
    try {
      final observation = await source.fetch();
      _last = observation;
      _lastObservedAt = (observation.observationTime ?? DateTime.now()).toUtc();
      _consecutiveFailures = 0;
      _log(
        '[$instance] ${observation.rawText.split(RegExp(r"\s+")).take(12).join(" ")} '
        '-> ServiceLevel $serviceLevel',
      );
    } catch (error) {
      _consecutiveFailures++;
      _log(
        '[$instance] fetch failed ($_consecutiveFailures in a row): $error '
        '-> serving last known value with Bad_NoCommunication, ServiceLevel $serviceLevel',
      );
    }
  }

  /// Field schema of the published structure.
  ///
  /// OPC UA struct members cannot be null, so "not reported" is encoded with
  /// documented sentinels: `NaN` for the doubles and `-1` for the integers.
  /// Consumers should test for them rather than treating -1 as a heading.
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
    s['ObservationTime'].value = (o.observationTime ?? _lastObservedAt ?? DateTime.utc(1970)).toUtc();
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

  /// Stops polling, drops the ServiceLevel to 0 and shuts the server down.
  ///
  /// [gracePeriod] keeps the server answering for a moment *after* the service
  /// level has gone to 0, so a connected redundant client can observe the
  /// hand-off instead of just losing the socket.
  Future<void> stop({Duration gracePeriod = Duration.zero}) async {
    final server = _server;
    if (server == null) return;
    _shuttingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (gracePeriod > Duration.zero) {
      _log('[$instance] going out of service: ServiceLevel 0 for $gracePeriod before shutdown');
      await Future.delayed(gracePeriod);
    }
    _pumping = false;
    // Let the pump loop observe _pumping == false and return before the
    // native server is deleted underneath it.
    await Future.delayed(const Duration(milliseconds: 50));
    server.shutdown();
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
    source: AviationWeatherMetarSource(options.station, useRawTextEndpoint: options.useText),
  );
  if (options.serviceLevel != null) server.forceServiceLevel(options.serviceLevel);

  await server.start();

  // Ctrl-C: drop ServiceLevel to 0, hold briefly so a connected client sees
  // the hand-off, then shut down.
  final signals = StreamController<void>();
  ProcessSignal.sigint.watch().listen((_) => signals.add(null));
  await signals.stream.first;
  await server.stop(gracePeriod: const Duration(seconds: 2));
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
  --station <ICAO>      Station to publish (default: BIRK, Reykjavik Airport)
  --poll <seconds>      Fetch interval (default: 300)
  --stale <seconds>     Age at which data is flagged Bad_NoCommunication
                        (default: 7200)
  --service-level <n>   Force ServiceLevel to a fixed 0-255 value instead of
                        computing it. Use this to demonstrate failover without
                        killing a process.
  --text                Use the NOAA plain-text endpoint instead of the JSON API
  --help
''';

class _Options {
  _Options({
    required this.instance,
    required this.port,
    required this.host,
    required this.applicationUri,
    required this.peers,
    required this.station,
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
  final String station;
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
      station: (flags['station']?.last ?? 'BIRK').toUpperCase(),
      pollInterval: Duration(seconds: int.parse(flags['poll']?.last ?? '300')),
      staleAfter: Duration(seconds: int.parse(flags['stale']?.last ?? '7200')),
      serviceLevel: flags['service-level'] == null ? null : int.parse(flags['service-level']!.last),
      useText: flags.containsKey('text'),
      help: flags.containsKey('help'),
    );
  }
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
