/*
  A non-transparent redundant client (OPC UA Part 4, §6.6.2) for the METAR
  server pair in `metar_redundant_server.dart`.

    dart run example/metar_redundant_client.dart \
        --endpoint opc.tcp://localhost:4840 --endpoint opc.tcp://localhost:4841

  Algorithm:

   1. Connect to every configured endpoint and keep every connection alive
      (`ClientIsolate.keepConnected` — the supervisor and its run_iterate pump
      live inside the worker isolate, so a bare `connect()` with no pump can
      never wedge here).
   2. Identify each server: read `Server/ServerArray[0]` (ns=0;i=2254), its
      ApplicationUri, and `Server/ServerRedundancy/ServerUriArray`
      (ns=0;i=11314), the ApplicationUris of the members of the redundant set
      it belongs to. ServerUris are identities, not addresses, so a client
      cannot dial them: the standard way to map one to endpoints is the
      `ServerNetworkGroups` property (Part 5, §6.3.10) or FindServers. This
      example is handed the endpoints on the command line and matches them to
      the set's members by ApplicationUri, reporting any member it has no
      endpoint for.
   3. Read `Server/ServiceLevel` (ns=0;i=2267) from each connected server on
      every tick. An unreachable server ranks below every reachable one.
   4. Subscribe to the METAR structure node of the server chosen by the
      band-aware rule of Part 4 §6.6.2.4.2 (Table 105): the initial selection
      is the highest ServiceLevel; while the active server is Healthy
      (200-255) the client stays with it, switching only when it becomes
      unreachable, reports 0 (Maintenance) or leaves the Healthy band; from
      Degraded (2-199) or NoData (1) it moves to the best Healthy server if
      there is one, otherwise to a higher Degraded one that clears a
      hysteresis margin.
*/

import 'dart:async';
import 'dart:io';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

import 'metar_redundant_server.dart' show isHealthyServiceLevel, parseFlags, serviceLevelMaintenance;

/// `ns=0;i=2267` — Server/ServiceLevel.
final NodeId serviceLevelNodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVICELEVEL);

/// `ns=0;i=2254` — Server/ServerArray; `[0]` is the server's own ApplicationUri.
final NodeId serverArrayNodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERARRAY);

/// `ns=0;i=11314` — Server/ServerRedundancy/ServerUriArray.
final NodeId serverUriArrayNodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_SERVERURIARRAY);

/// `ns=0;i=3709` — Server/ServerRedundancy/RedundancySupport.
final NodeId redundancySupportNodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_REDUNDANCYSUPPORT);

/// Emitted every time the client moves its data subscription to another server.
class FailoverEvent {
  FailoverEvent({
    required this.from,
    required this.to,
    required this.fromLevel,
    required this.toLevel,
    required this.reason,
    this.fromUri,
    this.toUri,
  });

  /// Endpoint left behind, or `null` for the initial selection.
  final String? from;

  /// Endpoint now serving data.
  final String to;

  /// ApplicationUri of the server at [from], when it had been identified.
  final String? fromUri;

  /// ApplicationUri of the server at [to], when it has been identified.
  final String? toUri;

  /// ServiceLevel of [from] at the moment of the switch (`-1` = unreachable).
  final int fromLevel;

  /// ServiceLevel of [to] at the moment of the switch.
  final int toLevel;

  /// Why the client moved, e.g. `connection lost`.
  final String reason;

  @override
  String toString() =>
      'switched ${from == null ? '(none)' : _describe(from!, fromUri)} -> ${_describe(to, toUri)}: '
      'ServiceLevel ${fromLevel < 0 ? 'unreachable' : fromLevel} -> $toLevel, reason: $reason';

  static String _describe(String endpoint, String? uri) => uri == null ? endpoint : '$uri ($endpoint)';
}

/// One connection in the redundant set.
class _Link {
  _Link(this.endpoint);

  final String endpoint;
  ClientIsolate? client;

  /// Last ServiceLevel read, or `-1` when the server could not be reached.
  int serviceLevel = -1;

  /// The server's ApplicationUri (`ServerArray[0]`), once identified.
  String? applicationUri;

  /// The set this server advertises in `ServerUriArray`, once identified.
  List<String> serverUris = const [];

  StreamSubscription<Map<NodeId, DynamicValue>>? dataSubscription;
  StreamSubscription<void>? reconnectSubscription;

  bool get reachable => serviceLevel >= 0;
}

/// Follows the healthiest member of a redundant OPC UA server set.
class MetarFailoverClient {
  MetarFailoverClient({
    required List<String> endpoints,
    this.station = 'BIRK',
    this.pollInterval = const Duration(seconds: 2),
    this.hysteresis = 10,
    this.readTimeout = const Duration(seconds: 2),
    this.publishingInterval = const Duration(milliseconds: 500),
    this.logLevel = LogLevel.UA_LOGLEVEL_FATAL,
    this.identifyMembers = true,
    void Function(String message)? log,
  }) : _log = log ?? print,
       _seed = List.of(endpoints);

  /// Station whose METAR node is subscribed to (`ns=1;s=<station>.Metar`).
  final String station;

  /// How often every server's ServiceLevel is re-read.
  final Duration pollInterval;

  /// Between two servers outside the Healthy band, a rival must beat the
  /// active one by more than this to win, so two similarly degraded servers
  /// do not ping-pong the subscription. The margin plays no part while the
  /// active server is Healthy (the client stays regardless) or when a Healthy
  /// server is available to a Degraded one (the client switches regardless).
  final int hysteresis;

  /// How long a single ServiceLevel / ServerArray / ServerUriArray read may
  /// take before the server counts as unreachable. Kept separate from
  /// [pollInterval] so a fast poll does not turn a merely slow server into a
  /// failover.
  final Duration readTimeout;

  final Duration publishingInterval;
  final LogLevel logLevel;

  /// Whether to read each server's ApplicationUri and ServerUriArray, so the
  /// configured endpoints can be matched to the members of the set and a
  /// member without an endpoint reported. Ranking works without it.
  final bool identifyMembers;

  final void Function(String message) _log;
  final List<String> _seed;

  final Map<String, _Link> _links = {};
  final Set<String> _reportedMissing = {};
  final StreamController<FailoverEvent> _failovers = StreamController<FailoverEvent>.broadcast();

  Timer? _timer;
  _Link? _active;
  bool _arbitrating = false;
  bool _stopped = false;

  /// The METAR structure node published by the servers.
  NodeId get metarNodeId => NodeId.fromString(1, '$station.Metar');

  /// Endpoint currently serving data, or `null` before the first selection.
  String? get activeEndpoint => _active?.endpoint;

  /// ApplicationUri of the server currently serving data, once identified.
  String? get activeApplicationUri => _active?.applicationUri;

  /// ServiceLevel of the active server (`-1` when unreachable).
  int get activeServiceLevel => _active?.serviceLevel ?? -1;

  /// Every endpoint the client connects to. Only configured endpoints are
  /// ever dialled: the entries of `ServerUriArray` are identities, not
  /// addresses.
  List<String> get knownEndpoints => _links.keys.toList(growable: false);

  /// Last ServiceLevel read from each known endpoint.
  Map<String, int> get serviceLevels => {for (final e in _links.entries) e.key: e.value.serviceLevel};

  /// The ApplicationUri read from each endpoint (`null` until identified).
  Map<String, String?> get applicationUris => {for (final e in _links.entries) e.key: e.value.applicationUri};

  /// The members of the redundant set, as the reached servers advertise them
  /// in `ServerUriArray` (the union, in case the servers disagree).
  Set<String> get serverUris => {for (final l in _links.values) ...l.serverUris};

  /// The configured endpoint of the member with [applicationUri], if any.
  String? endpointOf(String applicationUri) {
    for (final link in _links.values) {
      if (link.applicationUri == applicationUri) return link.endpoint;
    }
    return null;
  }

  /// Members of the set (see [serverUris]) that none of the configured
  /// endpoints answers for. The client cannot reach them until it is given
  /// their endpoint.
  List<String> get membersWithoutEndpoint => serverUris.where((uri) => endpointOf(uri) == null).toList(growable: false);

  /// Fires on every failover, including the initial server selection.
  Stream<FailoverEvent> get failovers => _failovers.stream;

  /// Connects to all configured endpoints and starts arbitrating.
  ///
  /// The initial selection is the highest ServiceLevel in the set, so it waits
  /// (at most [settleTimeout]) for every configured server to answer before
  /// choosing, rather than taking the first one to come up. A server that is
  /// still down at [settleTimeout] is left out; the client keeps retrying it
  /// in the background and selects one as soon as any answers.
  Future<void> start({Duration settleTimeout = const Duration(seconds: 15)}) async {
    for (final endpoint in _seed) {
      await _addEndpoint(endpoint);
    }
    // keepConnected establishes the sessions asynchronously, so an immediate
    // read would see every server as unreachable.
    final sw = Stopwatch()..start();
    while (!_stopped) {
      await Future.wait(_links.values.toList().map(_refresh));
      if (_links.values.every((l) => l.reachable) || sw.elapsed >= settleTimeout) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await _arbitrate();
    _timer = Timer.periodic(pollInterval, (_) => _arbitrate());
  }

  Future<void> _addEndpoint(String endpoint) async {
    final normalised = endpoint.trim();
    if (normalised.isEmpty || _links.containsKey(normalised)) return;
    final link = _Link(normalised);
    _links[normalised] = link;

    final client = await ClientIsolate.create(logLevel: logLevel);
    link.client = client;

    // keepConnected owns the run_iterate pump inside the worker isolate, so
    // the client keeps retrying while the server is down and recovers on its
    // own when it comes back. Its future only completes once the session is
    // ACTIVATED, which never happens for a server that is not up yet — so it
    // is deliberately not awaited.
    unawaited(
      client.keepConnected(normalised).catchError((Object e) => _log('[client] $normalised: keepConnected: $e')),
    );

    // open62541 drops client-side subscriptions across a reconnect, so the
    // data subscription has to be recreated whenever a link recovers. The
    // server behind the endpoint may also be a different application now (a
    // restart under another identity), so it is identified again.
    link.reconnectSubscription = client.reconnectStream.listen((_) async {
      _log('[client] $normalised: session recovered');
      link.applicationUri = null;
      link.serverUris = const [];
      if (identical(_active, link)) await _subscribe(link);
    });

    _log('[client] tracking $normalised');
  }

  Future<void> _arbitrate() async {
    if (_arbitrating || _stopped) return;
    _arbitrating = true;
    try {
      await Future.wait(_links.values.toList().map(_refresh));
      if (_stopped) return;

      final active = _active;
      // The highest ServiceLevel; on a tie the first configured endpoint, so
      // the choice is deterministic.
      _Link? best;
      for (final link in _links.values) {
        if (link.serviceLevel > 0 && (best == null || link.serviceLevel > best.serviceLevel)) best = link;
      }
      if (best == null) {
        if (active != null && !active.reachable) {
          _log('[client] every server in the set is unreachable or out of service');
        }
        return;
      }

      if (active == null) {
        await _switchTo(best, 'initial selection', fromLevel: -1);
        return;
      }
      if (identical(active, best)) return;

      // OPC 10000-4 §6.6.2.4.2, Table 105. An active server that is
      // unreachable or has declared Maintenance (ServiceLevel 0) is abandoned
      // at once. A Healthy one is kept whatever the others report. A Degraded
      // or NoData one is left for any Healthy server; failing that, for a
      // higher Degraded one that clears the hysteresis margin.
      final String? reason;
      if (!active.reachable) {
        reason = 'connection lost';
      } else if (active.serviceLevel == serviceLevelMaintenance) {
        reason = 'server reported ServiceLevel 0 (out of service)';
      } else if (isHealthyServiceLevel(active.serviceLevel)) {
        reason = null;
      } else if (isHealthyServiceLevel(best.serviceLevel)) {
        reason = 'active server is ${_band(active.serviceLevel)}; Healthy server available';
      } else if (best.serviceLevel > active.serviceLevel + hysteresis) {
        reason = 'no Healthy server; higher ServiceLevel available';
      } else {
        reason = null;
      }
      if (reason != null) await _switchTo(best, reason, fromLevel: active.serviceLevel);
    } finally {
      _arbitrating = false;
    }
  }

  /// The Table 105 band of a ServiceLevel, for log lines.
  static String _band(int level) {
    if (level == serviceLevelMaintenance) return 'Maintenance';
    if (level == 1) return 'NoData';
    return isHealthyServiceLevel(level) ? 'Healthy' : 'Degraded';
  }

  Future<void> _refresh(_Link link) async {
    final client = link.client;
    if (client == null) return;
    try {
      final dv = await client.readValue(serviceLevelNodeId).timeout(readTimeout);
      link.serviceLevel = (dv.value.value as num?)?.toInt() ?? -1;
    } catch (_) {
      link.serviceLevel = -1;
      return;
    }
    if (identifyMembers && link.applicationUri == null) await _identify(link);
  }

  /// Reads the server's ApplicationUri and the set it advertises, then
  /// matches the set's members against the configured endpoints.
  Future<void> _identify(_Link link) async {
    final client = link.client;
    if (client == null) return;
    try {
      final serverArray = await client.read(serverArrayNodeId).timeout(readTimeout);
      final uri = serverArray.isArray && serverArray.asArray.isNotEmpty ? serverArray[0].asString : '';
      if (uri.isEmpty) {
        _log('[client] ${link.endpoint}: empty ServerArray; cannot identify this server');
        return;
      }
      link.applicationUri = uri;
    } catch (e) {
      _log('[client] ${link.endpoint}: no ServerArray (${e.runtimeType}); cannot identify this server');
      return;
    }
    try {
      final uris = await client.read(serverUriArrayNodeId).timeout(readTimeout);
      link.serverUris = uris.isArray ? uris.asArray.map((v) => v.asString).toList(growable: false) : const [];
    } catch (e) {
      link.serverUris = const [];
      _log('[client] ${link.endpoint}: no ServerUriArray (${e.runtimeType}); it advertises no redundant set');
    }
    _reportMembership(link);
  }

  void _reportMembership(_Link link) {
    final uri = link.applicationUri;
    _log('[client] ${link.endpoint} is $uri, set: ${link.serverUris.isEmpty ? '(none)' : link.serverUris.join(', ')}');
    if (link.serverUris.isNotEmpty && !link.serverUris.contains(uri)) {
      _log('[client] ${link.endpoint}: $uri is missing from its own ServerUriArray; the set is misconfigured');
    }
    // The ServerUris are identities: a member nobody answers for can only be
    // reported, it cannot be dialled.
    for (final member in membersWithoutEndpoint) {
      if (_reportedMissing.add(member)) {
        _log('[client] no endpoint configured for set member $member; pass --endpoint for it');
      }
    }
    final duplicate = _links.values.where((l) => l.applicationUri == uri && !identical(l, link));
    for (final other in duplicate) {
      _log('[client] ${link.endpoint} and ${other.endpoint} both answer as $uri: the same server twice');
    }
  }

  Future<void> _switchTo(_Link next, String reason, {required int fromLevel}) async {
    final previous = _active;
    if (previous != null) await _unsubscribe(previous);
    _active = next;
    final event = FailoverEvent(
      from: previous?.endpoint,
      to: next.endpoint,
      fromUri: previous?.applicationUri,
      toUri: next.applicationUri,
      fromLevel: fromLevel,
      toLevel: next.serviceLevel,
      reason: reason,
    );
    _log('[client] $event');
    if (!_failovers.isClosed) _failovers.add(event);
    await _subscribe(next);
  }

  Future<void> _unsubscribe(_Link link) async {
    final sub = link.dataSubscription;
    link.dataSubscription = null;
    // A dead link's cancel can hang on the isolate round-trip; do not let it
    // block the failover.
    if (sub != null) await sub.cancel().timeout(readTimeout, onTimeout: () {});
  }

  Future<void> _subscribe(_Link link) async {
    final client = link.client;
    if (client == null || _stopped) return;
    await _unsubscribe(link);
    try {
      final subscriptionId = await client
          .subscriptionCreate(requestedPublishingInterval: publishingInterval)
          .timeout(const Duration(seconds: 5));
      link.dataSubscription = client
          .monitoredItems(
            {
              metarNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            },
            subscriptionId,
            samplingInterval: publishingInterval,
          )
          .listen(
            (values) {
              final v = values[metarNodeId];
              if (v != null) _log('[${link.endpoint}] ${_format(v)}');
            },
            // A notification with a non-Good status arrives as a STREAM ERROR
            // and its value/timestamps are dropped (see the package's known
            // limitations). Fall back to readValue, which does surface the
            // stale value together with its status and source timestamp.
            onError: (Object error) => unawaited(_reportQuality(link, error)),
          );
    } catch (e) {
      _log('[client] ${link.endpoint}: could not subscribe: $e');
    }
  }

  Future<void> _reportQuality(_Link link, Object error) async {
    final client = link.client;
    if (client == null) return;
    try {
      final dv = await client.readValue(metarNodeId).timeout(readTimeout);
      final age = dv.sourceTimestamp == null
          ? 'unknown age'
          : '${DateTime.now().toUtc().difference(dv.sourceTimestamp!).inMinutes} min old';
      _log(
        '[${link.endpoint}] quality ${statusCodeToString(dv.statusCode)}: '
        'last known value ($age, sourceTimestamp ${dv.sourceTimestamp?.toIso8601String()})'
        '${dv.value.isObject ? ' -> ${_format(dv.value)}' : ''}',
      );
    } catch (_) {
      _log('[${link.endpoint}] subscription error: $error');
    }
  }

  /// Reads the METAR node from the active server as a full [DataValue] —
  /// value plus status plus timestamps.
  Future<DataValue?> readActive() async {
    final client = _active?.client;
    if (client == null) return null;
    return client.readValue(metarNodeId);
  }

  String _format(DynamicValue v) {
    if (!v.isObject) return v.value.toString();
    String fmt(String key) {
      final d = (v[key].value as num?)?.toDouble();
      return d == null || d.isNaN ? '--' : d.toStringAsFixed(1);
    }

    final direction = v['WindVariable'].value == true
        ? 'VRB'
        : (v['WindDirectionDeg'].value as num?)?.toInt() == -1
        ? '---'
        : '${v['WindDirectionDeg'].value}'.padLeft(3, '0');
    final gust = (v['WindGustKt'].value as num?)?.toDouble();
    return '${v['Station'].value} ${v['ObservationTime'].asDateTime?.toIso8601String() ?? '?'} '
        '${fmt('TemperatureC')}/${fmt('DewPointC')} C  '
        'wind $direction@${fmt('WindSpeedKt')}kt${gust == null || gust.isNaN ? '' : ' G${gust.toStringAsFixed(0)}'}  '
        'QNH ${fmt('AltimeterHPa')}  ${v['FlightCategory'].value}';
  }

  /// Cancels everything and closes all connections.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    for (final link in _links.values) {
      await _unsubscribe(link);
      await link.reconnectSubscription?.cancel();
      final client = link.client;
      link.client = null;
      if (client != null) {
        await client.stopKeepConnected().timeout(const Duration(seconds: 2), onTimeout: () {});
        await client.delete().timeout(const Duration(seconds: 5), onTimeout: () {});
      }
    }
    _links.clear();
    _active = null;
    await _failovers.close();
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final flags = parseFlags(args);
  if (flags.containsKey('help')) {
    stdout.write(_usage);
    return;
  }
  final endpoints = flags['endpoint'] ?? const ['opc.tcp://localhost:4840', 'opc.tcp://localhost:4841'];

  final client = MetarFailoverClient(
    endpoints: endpoints,
    station: (flags['station']?.last ?? 'BIRK').toUpperCase(),
    pollInterval: Duration(milliseconds: int.parse(flags['poll']?.last ?? '2000')),
    hysteresis: int.parse(flags['hysteresis']?.last ?? '10'),
    identifyMembers: !flags.containsKey('no-identify'),
  );

  await client.start();

  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  await client.stop();
  exit(0);
}

const String _usage = '''
Usage: dart run example/metar_redundant_client.dart [options]

  --endpoint <url>   Server endpoint, repeatable. Defaults to
                     opc.tcp://localhost:4840 and opc.tcp://localhost:4841.
                     Every member of the set needs one: ServerUriArray names
                     the members by ApplicationUri, which cannot be dialled.
  --station <ICAO>   Station node to subscribe to (default: BIRK)
  --poll <ms>        ServiceLevel poll interval (default: 2000)
  --hysteresis <n>   Margin a Degraded rival must beat a Degraded active
                     server by (default: 10). Not used while the active
                     server is Healthy, nor when a Healthy one is available.
  --no-identify      Do not read ServerArray / ServerUriArray; rank the
                     --endpoint servers without matching them to the set
  --help
''';
