#!/usr/bin/env bash
# Regenerates the PKI fixtures the security tests load. open62541's
# UA_CreateCertificate (createSelfSignedCertificate) makes self-signed leaves
# only, so the CA, CA-issued leaves, CRLs, an expired leaf, a CA used as a
# leaf and an encrypted key come from openssl (3.4+ for -not_before/-not_after).
#
#   bash test/fixtures/pki/gen.sh
#
# Outputs (DER unless noted), valid for 20 years from generation:
#   ca.der                      CA (CA:TRUE, keyCertSign, cRLSign)
#   server.der / server_key.der CA-issued, URI urn:open62541.dart.test.server,
#                               DNS localhost, IP 127.0.0.1
#   client.der / client_key.der CA-issued, URI urn:open62541.dart.test.client
#   client_key_encrypted.pem    client_key as encrypted PKCS#8 PEM,
#                               password "open62541-dart"
#   expired.der / expired_key.der
#                               self-signed client leaf, valid only in 2020
#   ca_leaf.der / ca_leaf_key.der
#                               self-signed CA certificate carrying the client
#                               URI, to be (mis)used as a leaf
#   ca.crl                      the CA's CRL, nothing revoked
#   ca_revoked_client.crl       the CA's CRL revoking client.der
#   ca_revoked_server.crl       the CA's CRL revoking server.der
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
days=7300

leaf_cnf() { # <CN> <SAN>
  cat <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $1
O = open62541_dart tests
[v3_leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = $2
subjectKeyIdentifier = hash
CNF
}

cat > "$work/ca.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = open62541-dart test CA
O = open62541_dart tests
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[ca]
default_ca = testca
[testca]
database = $work/index.txt
crlnumber = $work/crlnumber
default_md = sha256
default_crl_days = $days
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca_key.pem" -out "$work/ca.pem" -days $days \
  -config "$work/ca.cnf" -extensions v3_ca
openssl x509 -in "$work/ca.pem" -outform DER -out ca.der

issue() { # <name> <CN> <SAN> <serial>
  leaf_cnf "$2" "$3" > "$work/$1.cnf"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$work/$1_key.pem" -out "$work/$1.csr" -config "$work/$1.cnf"
  openssl x509 -req -in "$work/$1.csr" -CA "$work/ca.pem" -CAkey "$work/ca_key.pem" -set_serial "$4" -days $days \
    -extfile "$work/$1.cnf" -extensions v3_leaf -out "$work/$1.pem"
  openssl x509 -in "$work/$1.pem" -outform DER -out "$1.der"
  openssl pkcs8 -topk8 -nocrypt -in "$work/$1_key.pem" -outform DER -out "$1_key.der"
}
issue server 'open62541-dart test server' 'URI:urn:open62541.dart.test.server,DNS:localhost,IP:127.0.0.1' 0x1001
issue client 'open62541-dart test client' 'URI:urn:open62541.dart.test.client' 0x1002

openssl pkcs8 -topk8 -in "$work/client_key.pem" -v2 aes-256-cbc -passout pass:open62541-dart -out client_key_encrypted.pem

leaf_cnf 'open62541-dart expired client' 'URI:urn:open62541.dart.test.client' > "$work/expired.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/expired_key.pem" -out "$work/expired.pem" \
  -not_before 20200101000000Z -not_after 20201231000000Z -config "$work/expired.cnf" -extensions v3_leaf
openssl x509 -in "$work/expired.pem" -outform DER -out expired.der
openssl pkcs8 -topk8 -nocrypt -in "$work/expired_key.pem" -outform DER -out expired_key.der

cat > "$work/ca_leaf.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = open62541-dart CA as leaf
O = open62541_dart tests
[v3_ca_leaf]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment,keyCertSign,cRLSign
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = URI:urn:open62541.dart.test.client
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca_leaf_key.pem" -out "$work/ca_leaf.pem" -days $days \
  -config "$work/ca_leaf.cnf" -extensions v3_ca_leaf
openssl x509 -in "$work/ca_leaf.pem" -outform DER -out ca_leaf.der
openssl pkcs8 -topk8 -nocrypt -in "$work/ca_leaf_key.pem" -outform DER -out ca_leaf_key.der

crl() { # <out> [cert to revoke]
  : > "$work/index.txt"
  echo 01 > "$work/crlnumber"
  if [ $# -gt 1 ]; then
    openssl ca -config "$work/ca.cnf" -revoke "$work/$2.pem" -keyfile "$work/ca_key.pem" -cert "$work/ca.pem"
  fi
  openssl ca -config "$work/ca.cnf" -gencrl -keyfile "$work/ca_key.pem" -cert "$work/ca.pem" -out "$work/crl.pem"
  openssl crl -in "$work/crl.pem" -outform DER -out "$1"
}
crl ca.crl
crl ca_revoked_client.crl client
crl ca_revoked_server.crl server
