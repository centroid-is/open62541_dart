/*
  A non-transparent redundant client (OPC UA Part 4, §6.6.2) for the METAR
  server pair in `metar_redundant_server.dart`.

    dart run example/metar_redundant_client.dart --endpoint opc.tcp://localhost:4840

  Algorithm:

   1. Connect to every known endpoint and keep every connection alive
      (`ClientIsolate.keepConnected` — the supervisor and its run_iterate pump
      live inside the worker isolate, so a bare `connect()` with no pump can
      never wedge here).
   2. Read `Server/ServiceLevel` (ns=0;i=2267) from each connected server on
      every tick. An unreachable server ranks below every reachable one.
   3. Use the server with the HIGHEST ServiceLevel for data: subscribe to its
      METAR structure node. A switch happens when the ranking changes by more
      than a hysteresis margin, or when the active server drops to 0 (out of
      service) or becomes unreachable.
   4. Discover peers: the first server reached is asked for
      `Server/ServerRedundancy/ServerUriArray` (ns=0;i=11314) and every
      endpoint listed there is added to the set. Only one `--endpoint` is
      therefore required on the command line.
*/

import 'dart:async';
import 'dart:io';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

import 'metar_redundant_server.dart' show parseFlags;

/// `ns=0;i=2267` — Server/ServiceLevel.
final NodeId serviceLevelNodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVICELEVEL);

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
  });

  /// Endpoint left behind, or `null` for the initial selection.
  final String? from;

  /// Endpoint now serving data.
  final String to;

  /// ServiceLevel of [from] at the moment of the switch (`-1` = unreachable).
  final int fromLevel;

  /// ServiceLevel of [to] at the moment of the switch.
  final int toLevel;

  /// Why the client moved, e.g. `connection lost`.
  final String reason;

  @override
  String toString() =>
      'switched ${from ?? '(none)'} -> $to: '
      'ServiceLevel ${fromLevel < 0 ? 'unreachable' : fromLevel} -> $toLevel, reason: $reason';
}

/// One connection in the redundant set.
class _Link {
  _Link(this.endpoint);

  final String endpoint;
  ClientIsolate? client;

  /// Last ServiceLevel read, or `-1` when the server could not be reached.
  int serviceLevel = -1;

  /// True once ServerUriArray has been read from this server.
  bool discovered = false;

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
    this.discoverPeers = true,
    void Function(String message)? log,
  }) : _log = log ?? print,
       _seed = List.of(endpoints);

  /// Station whose METAR node is subscribed to (`ns=1;s=<station>.Metar`).
  final String station;

  /// How often every server's ServiceLevel is re-read.
  final Duration pollInterval;

  /// A rival server must beat the active one by more than this to win. Keeps
  /// two equally healthy servers from ping-ponging the subscription. A drop
  /// to 0 (out of service) or an unreachable active server always fails over,
  /// regardless of the margin.
  final int hysteresis;

  /// How long a single ServiceLevel / ServerUriArray read may take before the
  /// server counts as unreachable. Kept separate from [pollInterval] so a
  /// fast poll does not turn a merely slow server into a failover.
  final Duration readTimeout;

  final Duration publishingInterval;
  final LogLevel logLevel;

  /// Whether to read ServerUriArray and join the endpoints it advertises.
  final bool discoverPeers;

  final void Function(String message) _log;
  final List<String> _seed;

  final Map<String, _Link> _links = {};
  final StreamController<FailoverEvent> _failovers = StreamController<FailoverEvent>.broadcast();

  Timer? _timer;
  _Link? _active;
  bool _arbitrating = false;
  bool _stopped = false;

  /// The METAR structure node published by the servers.
  NodeId get metarNodeId => NodeId.fromString(1, '$station.Metar');

  /// Endpoint currently serving data, or `null` before the first selection.
  String? get activeEndpoint => _active?.endpoint;

  /// ServiceLevel of the active server (`-1` when unreachable).
  int get activeServiceLevel => _active?.serviceLevel ?? -1;

  /// Every endpoint known to the client (seeded plus discovered).
  List<String> get knownEndpoints => _links.keys.toList(growable: false);

  /// Last ServiceLevel read from each known endpoint.
  Map<String, int> get serviceLevels => {for (final e in _links.entries) e.key: e.value.serviceLevel};

  /// Fires on every failover, including the initial server selection.
  Stream<FailoverEvent> get failovers => _failovers.stream;

  /// Connects to all seeded endpoints and starts arbitrating.
  ///
  /// Returns once a server has been selected, or after [settleTimeout] if no
  /// seeded server could be reached — the client then keeps retrying in the
  /// background and selects one as soon as it answers.
  Future<void> start({Duration settleTimeout = const Duration(seconds: 15)}) async {
    for (final endpoint in _seed) {
      await _addEndpoint(endpoint);
    }
    // keepConnected establishes the sessions asynchronously, so an immediate
    // arbitration would see every server as unreachable. Keep arbitrating
    // until one is picked.
    final sw = Stopwatch()..start();
    while (!_stopped) {
      await _arbitrate();
      if (_active != null || sw.elapsed >= settleTimeout) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
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
    // data subscription has to be recreated whenever a link recovers.
    link.reconnectSubscription = client.reconnectStream.listen((_) async {
      _log('[client] $normalised: session recovered');
      if (identical(_active, link)) await _subscribe(link);
    });

    _log('[client] tracking $normalised');
  }

  Future<void> _arbitrate() async {
    if (_arbitrating || _stopped) return;
    _arbitrating = true;
    try {
      // Snapshot: a refresh can discover a peer and add a link, which would
      // otherwise mutate the map while it is being iterated.
      await Future.wait(_links.values.toList().map(_refresh));
      if (_stopped) return;

      final active = _active;
      final candidates = _links.values.where((l) => l.serviceLevel > 0).toList()
        ..sort((a, b) => b.serviceLevel.compareTo(a.serviceLevel));
      if (candidates.isEmpty) {
        if (active != null && !active.reachable) {
          _log('[client] every server in the set is unreachable or out of service');
        }
        return;
      }
      final best = candidates.first;

      if (active == null) {
        await _switchTo(best, 'initial selection', fromLevel: -1);
        return;
      }
      if (identical(active, best)) return;

      // An active server that is unreachable or has declared itself out of
      // service (ServiceLevel 0) is abandoned immediately; otherwise the
      // challenger has to clear the hysteresis margin.
      final String? reason;
      if (!active.reachable) {
        reason = 'connection lost';
      } else if (active.serviceLevel == 0) {
        reason = 'server reported ServiceLevel 0 (out of service)';
      } else if (best.serviceLevel > active.serviceLevel + hysteresis) {
        reason = 'higher ServiceLevel available';
      } else {
        reason = null;
      }
      if (reason != null) await _switchTo(best, reason, fromLevel: active.serviceLevel);
    } finally {
      _arbitrating = false;
    }
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
    if (discoverPeers && !link.discovered) {
      link.discovered = true;
      await _discoverFrom(link);
    }
  }

  /// Reads ServerUriArray from [link] and joins any endpoint not already known.
  Future<void> _discoverFrom(_Link link) async {
    final client = link.client;
    if (client == null) return;
    try {
      final uris = await client.read(serverUriArrayNodeId).timeout(readTimeout);
      final listed = uris.isArray
          ? uris.asArray.map((v) => v.asString).where((s) => s.startsWith('opc.tcp://')).toList()
          : const <String>[];
      final added = listed.where((u) => !_links.containsKey(u)).toList();
      for (final uri in added) {
        await _addEndpoint(uri);
      }
      if (added.isNotEmpty) {
        _log('[client] discovered ${added.length} peer(s) from ${link.endpoint}: ${added.join(', ')}');
      }
    } catch (e) {
      _log('[client] ${link.endpoint}: no ServerUriArray (${e.runtimeType}); staying with the configured endpoints');
    }
  }

  Future<void> _switchTo(_Link next, String reason, {required int fromLevel}) async {
    final previous = _active;
    if (previous != null) await _unsubscribe(previous);
    _active = next;
    final event = FailoverEvent(
      from: previous?.endpoint,
      to: next.endpoint,
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
  final endpoints = flags['endpoint'] ?? const ['opc.tcp://localhost:4840'];

  final client = MetarFailoverClient(
    endpoints: endpoints,
    station: (flags['station']?.last ?? 'BIRK').toUpperCase(),
    pollInterval: Duration(milliseconds: int.parse(flags['poll']?.last ?? '2000')),
    hysteresis: int.parse(flags['hysteresis']?.last ?? '10'),
    discoverPeers: !flags.containsKey('no-discovery'),
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
                     opc.tcp://localhost:4840. Peers are discovered from
                     ServerUriArray, so one endpoint is usually enough.
  --station <ICAO>   Station node to subscribe to (default: BIRK)
  --poll <ms>        ServiceLevel poll interval (default: 2000)
  --hysteresis <n>   Margin a rival server must beat the active one by
                     (default: 10)
  --no-discovery     Do not read ServerUriArray; use only --endpoint values
  --help
''';
