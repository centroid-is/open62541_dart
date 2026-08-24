// Shared helpers for the HMI scenario tests. These mirror how a fish-farm
// control screen maps its on-screen tags to OPC UA nodes: it browses the
// address space once at start-up, then reads/writes/subscribes by NodeId.
//
// Not a test file (no `_test` suffix) so `dart test` ignores it.

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';

/// Live-updating sensors on every tank (see servers/fish_farm_asyncua.py).
const liveSensors = ['Temperature', 'DissolvedOxygen', 'PH', 'WaterLevel'];

/// Salinity is published once at start-up and never mutated by the server, so
/// its monitored item reports a single value and then stays quiet.
const staticSensors = ['Salinity'];

/// All sensor tags an HMI dashboard would show per tank.
const allSensors = [...liveSensors, ...staticSensors];

/// Plausible value window for each sensor, derived from the server's generator
/// formulas plus generous margin (the HMI only needs a sanity band).
const sensorRanges = <String, ({double min, double max})>{
  'Temperature': (min: 9.0, max: 15.0), // 12 +/- 1.5
  'DissolvedOxygen': (min: 7.0, max: 10.0), // 8.5 +/- 0.6
  'PH': (min: 6.5, max: 8.0), // 7.2 +/- 0.2
  'Salinity': (min: 33.0, max: 35.0), // constant 34.0
  'WaterLevel': (min: 90.0, max: 97.0), // 95 - [0,2]
};

/// A resolved dashboard tag: its NodeId and a human label like "Tank3/PH".
class TagRef {
  TagRef(this.label, this.tank, this.sensor, this.nodeId);
  final String label;
  final int tank;
  final String sensor;
  final NodeId nodeId;
}

/// Browse-resolves every [sensors] tag on tanks 1..[tanks].
Future<List<TagRef>> resolveSensorTags(
  ClientApi client, {
  required int tanks,
  List<String> sensors = allSensors,
}) async {
  final out = <TagRef>[];
  for (var t = 1; t <= tanks; t++) {
    for (final s in sensors) {
      final id = await tankVar(client, t, s);
      out.add(TagRef('Tank$t/$s', t, s, id));
    }
  }
  return out;
}

/// Builds the monitored-items request (VALUE attribute of every tag).
Map<NodeId, List<AttributeId>> valueParam(Iterable<TagRef> tags) => {
  for (final tag in tags) tag.nodeId: const [AttributeId.UA_ATTRIBUTEID_VALUE],
};

/// True when [v] is inside the sanity band for [sensor].
bool inRange(String sensor, double v) {
  final r = sensorRanges[sensor]!;
  return v >= r.min && v <= r.max;
}
