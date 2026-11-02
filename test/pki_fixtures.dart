import 'dart:io';
import 'dart:typed_data';

import 'package:open62541/open62541.dart';

/// The openssl-made fixtures of test/fixtures/pki (see gen.sh there).
Uint8List pkiBytes(String name) => File('test/fixtures/pki/$name').readAsBytesSync();

Certificate pkiCertificate(String name) => Certificate.fromDer(pkiBytes('$name.der'));

CertificateAndKey pkiCertificateAndKey(String name) =>
    CertificateAndKey(pkiCertificate(name), pkiBytes('${name}_key.der'));

const fixtureServerUri = 'urn:open62541.dart.test.server';
const fixtureClientUri = 'urn:open62541.dart.test.client';
const fixtureKeyPassword = 'open62541-dart';
