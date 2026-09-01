/*
  One half of a redundant OPC UA server pair publishing live METAR weather.

  Run the same file twice to get the pair (see example/README.md):

    dart run example/metar_redundant_server.dart --instance metar-a --port 4840 \
        --peer opc.tcp://localhost:4841
    dart run example/metar_redundant_server.dart --instance metar-b --port 4841 \
        --peer opc.tcp://localhost:4840

  What each instance demonstrates:

   * A custom structured DataType (`addCustomType` + `addDataTypeNode`) holding
     the decoded observation, served from a DATA-SOURCE variable node through
     `onReadValue` so every read carries a real OPC UA StatusCode and the
     observation's own sourceTimestamp.
   * The Part 4 / Part 5 non-transparent redundancy surface published on the
     STANDARD NS0 nodes via `Server.setVariableValueSource`: ServiceLevel
     (i=2267) computed live from this instance's own health,
     RedundancySupport (i=3709) = Hot, and ServerUriArray listing both members
     of the set. No vendor-specific nodes: any standards-based client can
     discover and rank the set.
*/

import 'dart:async';
import 'dart:io';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

import 'metar_common.dart';

/// OPC UA Part 5 `RedundancySupport` enumeration value for Hot redundancy:
/// every member of the set runs and serves data continuously, and the client
/// picks one by ServiceLevel.
const int redundancySupportHot = 3;

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
    this.peerEndpoints = const [],
    this.pollInterval = const Duration(minutes: 5),
    this.staleAfter = const Duration(hours: 2),
    this.logLevel = LogLevel.UA_LOGLEVEL_ERROR,
    void Function(String message)? log,
  }) : _log = log ?? print;

  /// Human-readable name of this instance, used in log lines only.
  final String instance;

  final String host;
  final int port;

  /// Where the observation comes from. Injected so tests can supply a fake.
  final MetarSource source;

  /// The other members of the redundant set, as `opc.tcp://` endpoint URLs.
  final List<String> peerEndpoints;

  /// How often to re-fetch the observation.
  final Duration pollInterval;

  /// How old an observation may get before this server declares its data
  /// untrustworthy (Bad_NoCommunication + a falling ServiceLevel).
  final Duration staleAfter;

  final LogLevel logLevel;
  final void Function(String message) _log;

  /// `opc.tcp://` URL clients use to reach this instance.
  String get endpoint => 'opc.tcp://$host:$port';

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
  /// The ladder:
  ///  * `0`   — never fetched anything, or shutting down. Per Part 4 a
  ///            ServiceLevel of 0 means "do not use me".
  ///  * `250` — fresh data (younger than [staleAfter]) and the last fetch
  ///            succeeded. 250 rather than 255 leaves headroom above for an
  ///            operator-designated preferred server.
  ///  * `100` — data older than [staleAfter] but younger than twice that.
  ///  * `5`   — data older than that: still alive, but nearly useless.
  ///  * minus 60 per consecutive failed fetch, floored at 1 — a server that
  ///    still holds a value never drops to 0, because 0 is reserved for
  ///    "out of service".
  int get serviceLevel {
    if (_shuttingDown) return 0;
    final forced = _forcedServiceLevel;
    if (forced != null) return forced;
    if (_last == null || _lastObservedAt == null) return 0;

    final age = dataAge!;
    var level = age <= staleAfter
        ? 250
        : age <= staleAfter * 2
        ? 100
        : 5;
    level -= 60 * _consecutiveFailures;
    return level.clamp(1, 255);
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
    final server = Server(port: port, logLevel: logLevel);
    _server = server;
    server.start();

    _pumping = true;
    unawaited(_pump(server));

    _publishMetarNodes(server);
    _publishRedundancySurface(server);

    _log('[$instance] listening on $endpoint (set: ${_serverUriArray().join(', ')})');

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

  List<String> _serverUriArray() => [endpoint, ...peerEndpoints];

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

  /// Replaces the value source of the standard NS0 redundancy nodes.
  ///
  /// open62541 pins `ServiceLevel` at 255 through an internal callback and
  /// stores `RedundancySupport = None`; neither accepts a write.
  /// [Server.setVariableValueSource] swaps the value source of those existing
  /// nodes, which is the only way to publish a real service level.
  void _publishRedundancySurface(Server server) {
    server.setVariableValueSource(
      NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVICELEVEL),
      onRead: () => DynamicValue(value: serviceLevel, typeId: NodeId.byte, name: 'ServiceLevel'),
    );

    server.setVariableValueSource(
      NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_REDUNDANCYSUPPORT),
      onRead: () => DynamicValue(value: redundancySupportHot, typeId: NodeId.int32, name: 'RedundancySupport'),
    );

    // open62541 deletes the standard ServerUriArray property from NS0 at
    // startup ("Remove unused subtypes of ServerRedundancy"), so it has to be
    // re-added as a HasProperty child of ServerRedundancy.
    //
    // Note: OPC UA Part 5 says this array holds server *URIs* (the identities
    // you would resolve through a discovery server). This example publishes
    // `opc.tcp://` endpoint URLs instead so the demo is self-contained — a
    // client that reaches either instance learns how to reach the other one
    // without a discovery server and without both URLs on its command line.
    server.addVariableNode(
      NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_SERVERURIARRAY),
      DynamicValue.fromList(_serverUriArray(), typeId: NodeId.uastring, name: 'ServerUriArray'),
      accessLevel: const AccessLevelMask(read: true),
      parentNodeId: NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY),
      parentReferenceNodeId: NodeId.fromNumeric(0, raw.UA_NS0ID_HASPROPERTY),
      baseDataVariableType: NodeId.fromNumeric(0, raw.UA_NS0ID_PROPERTYTYPE),
      typeId: NodeId.uastring,
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
    peerEndpoints: options.peers,
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
  --host <name>         Host name published in this server's endpoint URL
                        (default: localhost)
  --peer <url>          Peer endpoint, repeatable. Published in ServerUriArray
                        together with this server's own endpoint.
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
  final List<String> peers;
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
      peers: flags['peer'] ?? const [],
      station: (flags['station']?.last ?? 'BIRK').toUpperCase(),
      pollInterval: Duration(seconds: int.parse(flags['poll']?.last ?? '300')),
      staleAfter: Duration(seconds: int.parse(flags['stale']?.last ?? '7200')),
      serviceLevel: flags['service-level'] == null ? null : int.parse(flags['service-level']!.last),
      useText: flags.containsKey('text'),
      help: flags.containsKey('help'),
    );
  }
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
