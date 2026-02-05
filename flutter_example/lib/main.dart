import 'package:flutter/material.dart';
import 'package:open62541/open62541.dart';

void main() {
  final result = testLibrarySymbols();

  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('open62541 Test')),
        body: Center(child: Text(result ? 'Library loaded OK\nVersion: $UA_OPEN62541_VERSION' : 'Library load FAILED')),
      ),
    ),
  );
}

bool testLibrarySymbols() {
  try {
    // Test version constant is accessible
    if (UA_OPEN62541_VERSION.isEmpty) return false;

    // Create a server to verify core library works
    final server = Server();
    server.delete();

    return true;
  } catch (_) {
    return false;
  }
}
