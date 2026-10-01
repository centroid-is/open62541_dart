// Regression test for a VM abort found in the PR #119 review: a notification
// delivered after a DeleteMonitoredItems response was lost.
//
// cancel() sends DeleteMonitoredItems and used to close the stream's native
// callback as soon as that request was answered, whatever the answer. When
// the response is lost with the secure channel, open62541 answers the request
// locally with BadSecureChannelClosed and keeps its monitored item, and so
// does the server, because the session outlives the channel. After the
// reconnect the item publishes again, into the closed callback, and the VM
// aborts with "Callback invoked after it has been deleted". A frozen link
// that recovers does exactly this to every stream cancelled during the
// freeze.
//
// The scenario lives in test/scenarios/monitor_delete_response_lost.dart and
// runs as a child process, so that an abort is reported here as a failed
// test and does not take the test runner down.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  // Guards the VM abort described above (PR #119 review).
  test('a notification after a lost DeleteMonitoredItems response is dropped, and the VM does not abort', () async {
    // `dart test` runs with the package root as the current directory.
    final scenario = await Process.start(Platform.resolvedExecutable, [
      'test/scenarios/monitor_delete_response_lost.dart',
    ]);
    final output = StringBuffer();
    final errors = StringBuffer();
    final outputDone = scenario.stdout.transform(utf8.decoder).forEach(output.write);
    final errorsDone = scenario.stderr.transform(utf8.decoder).forEach(errors.write);

    var timedOut = false;
    final exitCode = await scenario.exitCode.timeout(
      Duration(seconds: 90),
      onTimeout: () {
        timedOut = true;
        scenario.kill(ProcessSignal.sigkill);
        return scenario.exitCode;
      },
    );
    await outputDone;
    await errorsDone;

    if (errors.toString().contains('Callback invoked after it has been deleted')) {
      fail(
        'the VM aborted with "Callback invoked after it has been deleted": the monitor callback was closed '
        'although the DeleteMonitoredItems response was lost and the item still published.\n'
        'Scenario output:\n$output',
      );
    }
    if (timedOut) {
      fail(
        'the scenario never exited: it hung, or a native callback is still open after Client.delete().\n'
        'Scenario output:\n$output',
      );
    }
    expect(exitCode, 0, reason: 'Scenario output:\n$output\n$errors');
    expect(output.toString(), contains('survived'));
  }, timeout: Timeout(Duration(seconds: 120)));
}
