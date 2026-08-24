// INTEROP: Dart client <-> asyncua reference server (independent Python stack).
//
// Runs the full client-side interop matrix (browse, read, write+readback,
// method calls incl. argument/return fidelity, live subscription, data-type
// fidelity) over both ClientKind.direct and ClientKind.isolate.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'matrix.dart';

void main() {
  registerInteropMatrix(
    stack: 'asyncua',
    tanks: 2,
    makeServer: (port) => ReferenceServer.asyncuaFishFarm(port: port, tanks: 2, updateMs: 150),
    skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first',
  );
}
