// INTEROP: Dart client <-> node-opcua reference server (independent JS stack).
//
// Runs the same client-side interop matrix as the asyncua file against the
// node-opcua server, over both ClientKind.direct and ClientKind.isolate. This
// is the less-validated stack; if a case fails, triage whether it's the node
// server script or a genuine Dart-library interop bug (see findings).
@Tags(['integration'])
library;

import 'package:test/test.dart';

import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'matrix.dart';

void main() {
  registerInteropMatrix(
    stack: 'node-opcua',
    tanks: 2,
    makeServer: (port) => ReferenceServer.nodeOpcuaFishFarm(port: port, tanks: 2, updateMs: 150),
    skip: nodeOpcuaAvailable() ? false : 'run test/integration/setup_local.sh first',
  );
}
