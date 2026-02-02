import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';

void main() {
  group('ClientIsolate cleanup', () {
    test('delete() should cancel pending connect with clear error', () async {
      final client = await ClientIsolate.create(
        libraryPath: '', // Empty path uses DynamicLibrary.executable() for static linking
      );

      // Start connect to a non-routable IP (RFC 5737 TEST-NET), will hang
      final connectFuture = client.connect('opc.tcp://192.0.2.1:4840');

      // Attach error handler immediately to prevent unhandled async error
      Object? caughtError;
      unawaited(connectFuture.then((_) {}).catchError((e) {
        caughtError = e;
      }));

      // Give it a moment to start
      await Future.delayed(const Duration(milliseconds: 100));

      // Delete while connect is pending
      await client.delete();

      // Wait for error propagation
      await Future.delayed(const Duration(milliseconds: 50));

      expect(caughtError, isA<StateError>());
      expect(caughtError.toString(), contains('ClientIsolate closed'));
    });

    test('delete() should cancel pending read with clear error', () async {
      final client = await ClientIsolate.create(
        libraryPath: '',
      );

      // Start a read without connecting (will hang waiting for response)
      final readFuture = client.read(NodeId.fromNumeric(0, 2258));

      // Attach error handler immediately
      Object? caughtError;
      unawaited(readFuture.then((_) {}).catchError((e) {
        caughtError = e;
      }));

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      await Future.delayed(const Duration(milliseconds: 50));

      expect(caughtError, isA<StateError>());
      expect(caughtError.toString(), contains('ClientIsolate closed'));
    });

    test('delete() should close stream controllers', () async {
      final client = await ClientIsolate.create(
        libraryPath: '',
      );

      // Get a state stream (creates a stream controller)
      final stateStream = client.stateStream;
      final streamDone = Completer<void>();

      stateStream.listen(
        (_) {},
        onDone: () => streamDone.complete(),
        onError: (_) {},
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      // Stream should be closed
      await expectLater(
        streamDone.future.timeout(const Duration(seconds: 1)),
        completes,
      );
    });

    test('multiple pending operations should all be cancelled', () async {
      final client = await ClientIsolate.create(
        libraryPath: '',
      );

      // Start multiple operations and attach error handlers immediately
      final errors = <Object?>[];
      final futures = [
        client.connect('opc.tcp://192.0.2.1:4840'),
        client.read(NodeId.fromNumeric(0, 2258)),
        client.read(NodeId.fromNumeric(0, 2259)),
      ];

      for (final future in futures) {
        unawaited(future.then((_) {}).catchError((e) {
          errors.add(e);
        }));
      }

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      // Wait for error propagation
      await Future.delayed(const Duration(milliseconds: 50));

      // All futures should have thrown StateError
      expect(errors.length, 3);
      for (final error in errors) {
        expect(error, isA<StateError>());
        expect(error.toString(), contains('ClientIsolate closed'));
      }
    });
  });
}
