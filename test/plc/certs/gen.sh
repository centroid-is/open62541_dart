#!/usr/bin/env bash
# Generates a self-signed OPC UA *client* certificate + key for the encrypted
# PLC tests (Basic256Sha256 / SignAndEncrypt). Outputs DER for open62541 plus
# PEM for importing into a controller's trust list.
#
#   bash test/plc/certs/gen.sh [applicationUri] [extra-SAN-ip]
#
# The applicationUri MUST match the client's ApplicationDescription URI, or the
# server rejects the cert with BadSecurityChecksFailed. The library's current
# default is urn:open62541.unconfigured.application (used below).
set -euo pipefail
cd "$(dirname "$0")"

APP_URI="${1:-urn:open62541.unconfigured.application}"
SAN_IP="${2:-}"
SAN="URI:${APP_URI}"
[ -n "$SAN_IP" ] && SAN="${SAN},IP:${SAN_IP}"

cat > openssl.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = open62541-dart-client
O = Centroid
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage = critical,clientAuth,serverAuth
subjectAltName = ${SAN}
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config openssl.cnf
openssl x509 -in cert.pem -outform DER -out client_cert.der
openssl pkcs8 -topk8 -nocrypt -in key.pem -outform DER -out client_key.der

echo "Wrote client_cert.der / client_key.der (+ cert.pem/key.pem)."
echo "ApplicationUri (SAN): ${APP_URI}"
openssl x509 -in cert.pem -noout -fingerprint -sha1
