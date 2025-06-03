// Instructions for getting this running on a windows machine:
// Step 1: Clone the repo and submodules to the windows machine
// git clone https://github.com/centroid-is/open62541_dart.git
// cd open62541_dart
// git submodule update --init --recursive

import 'package:open62541/open62541.dart';

void noop(dynamic noop) {}

void main() async {
  final c = Client(
    loadOpen62541Library(),
    securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE,
    logLevel: LogLevel.UA_LOGLEVEL_ERROR,
  );

  c.connect("opc.tcp://localhost:4840");

  var nodes = <List<NodeId>>[];
  final subscription = await c.subscriptionCreate();
  print("Subscription created: $subscription");
  for (var i = 3; i < 13; i++) {
    final parent_id = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi");
    final descriptions_id = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi.descriptions");
    final raw_state = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi.raw_state");
    final force_values = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi.force_values");
    final off_filters = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi.off_filters");
    final on_filters = NodeId.fromString(4, "GVL_BatchLines.Internal_Bus_$i.hmi.on_filters");

    nodes.add([parent_id, descriptions_id, raw_state, force_values, off_filters, on_filters]);
  }
  () async {
    for (int i = 0; i < 4; i++) {
      for (var node in nodes) {
        bool input = true;
        try {
          await c.readDataTypeAttribute(node[4]);
        } catch (e) {
          // Not an input type
          input = false;
        }
        await c.read(node[0]);
        await c.read(node[1]);
        await c.read(node[2]);
        await c.read(node[3]);
        if (input) {
          await c.read(node[4]);
          await c.read(node[5]);
        }
      }
    }
  }();
  for (var node in nodes) {
    bool input = true;
    try {
      await c.readDataTypeAttribute(node[4]);
    } catch (e) {
      // Not an input type
      input = false;
    }

    c.monitor(node[0], subscription).listen((value) => noop(value));
    c.monitor(node[1], subscription).listen((value) => noop(value));
    c.monitor(node[2], subscription).listen((value) => noop(value));
    c.monitor(node[3], subscription).listen((value) => noop(value));
    if (input) {
      c.monitor(node[4], subscription).listen((value) => noop(value));
      c.monitor(node[5], subscription).listen((value) => noop(value));
    }
  }
}
