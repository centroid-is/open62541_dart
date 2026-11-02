/*
   Endpoint discovery: what a server offers, and the thumbprint of its
   certificate, so the certificate can be confirmed out of band and saved as
   the trust list of the next, encrypted connection (trust on first use).

   Discovery itself is a SecurityPolicy None channel without a session: it
   needs no certificate, and it authenticates nothing. A machine in the
   middle at this moment would hand over its own certificate, which is why
   the thumbprint printed here has to match the one the server's operator
   gives you before the saved file is trusted.
*/

import 'dart:io';

import 'package:open62541/open62541.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: discover_endpoints <endpoint> [server_cert.der]');
    exit(1);
  }
  final endpoints = await Client.getEndpoints(args[0]);
  for (final endpoint in endpoints) {
    print(endpoint);
    print('  server: ${endpoint.applicationName} <${endpoint.applicationUri}>');
    print('  identity tokens: ${endpoint.userIdentityTokens.join(', ')}');
    if (endpoint.serverCertificate.isNotEmpty) {
      print('  server certificate SHA-1: ${endpoint.certificateThumbprint}');
    }
  }

  if (args.length < 2) return;
  final withCertificate = endpoints.where((e) => e.serverCertificate.isNotEmpty);
  if (withCertificate.isEmpty) {
    print('The server has no certificate (SecurityPolicy None only), nothing to save.');
    return;
  }
  await File(args[1]).writeAsBytes(withCertificate.first.serverCertificate);
  print(
    'Saved the server certificate to ${args[1]} (SHA-1 ${withCertificate.first.certificateThumbprint}).\n'
    'Confirm that thumbprint with the server\'s operator before trusting the file; then pass it as the\n'
    'trustList of an encrypted client, as resilient_client.dart does.',
  );
}
