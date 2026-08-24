// HMI "Alarm handling" scenario.
//
// Exercises the alarm block an HMI would render for each tank
// (AlarmActive / AlarmMessage / AlarmSeverity) and the ResetAlarm method.
//
// NOTE ON THE REFERENCE SERVER: the asyncua fish-farm server exposes the alarm
// variables as read-only and provides no path to *raise* an alarm, so a genuine
// inactive->active->inactive transition cannot be driven from the client. What
// we can assert meaningfully: the acknowledged baseline (cleared), that an
// operator cannot fake an alarm by writing the flag (read-only enforcement),
// and that ResetAlarm returns ok and leaves the block cleared.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';

void main() {
  group('HMI alarm handling', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('reads the alarm block and ResetAlarm keeps it cleared ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        try {
          final activeId = await tankVar(dc.client, 1, 'AlarmActive');
          final msgId = await tankVar(dc.client, 1, 'AlarmMessage');
          final sevId = await tankVar(dc.client, 1, 'AlarmSeverity');
          final tankId = await resolvePath(dc.client, ['Plant', 'Tank1']);
          final resetId = await tankMethod(dc.client, 1, 'ResetAlarm');

          // HMI reads the whole alarm block in one service call.
          Future<({bool active, String msg, int sev})> readBlock() async {
            final block = await dc.client.readAttribute({
              activeId: const [AttributeId.UA_ATTRIBUTEID_VALUE],
              msgId: const [AttributeId.UA_ATTRIBUTEID_VALUE],
              sevId: const [AttributeId.UA_ATTRIBUTEID_VALUE],
            });
            return (active: block[activeId]!.asBool, msg: block[msgId]!.asString, sev: block[sevId]!.asInt);
          }

          // Baseline: cleared.
          final before = await readBlock();
          expect(before.active, isFalse);
          expect(before.msg, isEmpty);
          expect(before.sev, 0);

          // Operator cannot fake an alarm: the flag is read-only.
          await expectLater(
            dc.client.write(activeId, DynamicValue(value: true, typeId: NodeId.boolean)),
            throwsA(predicate((e) => e.toString().contains('AccessDenied'), 'a BadUserAccessDenied error')),
          );

          // The write was rejected, so the block is still cleared.
          expect((await readBlock()).active, isFalse);

          // ResetAlarm acknowledges and returns ok.
          final result = await dc.client.call(tankId, resetId, const []);
          expect(result, hasLength(1));
          expect(result.first.asBool, isTrue);

          // Post-reset the block is (still) cleared.
          final after = await readBlock();
          expect(after.active, isFalse);
          expect(after.msg, isEmpty);
          expect(after.sev, 0);
        } finally {
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
