# Client certificate for encrypted PLC connections

Some controllers advertise **only** encrypted OPC UA endpoints
(`Basic256Sha256` / `SignAndEncrypt`) and refuse a username/password over a
plain `None` channel — the **Schneider M241** is one. For those, connect with
`PLC_<X>_SECURE=1`; the harness presents the client certificate here.

## Generate the cert/key

```bash
bash test/plc/certs/gen.sh
```

This writes `client_cert.der` + `client_key.der` (used by the tests) and
`cert.pem` (import this into the controller's trust list). These files are
git-ignored — regenerate locally.

The cert's SAN URI must equal the client's ApplicationUri
(`urn:open62541.unconfigured.application` by default), or the server rejects the
channel with `BadSecurityChecksFailed`.

## One-time controller setup

An encrypted channel is **mutual**: the controller must trust our client cert.

1. **Trust the client certificate.** Attempt one connection (it will be
   rejected); the controller moves our cert into its *rejected/untrusted*
   list. In EcoStruxure Machine Expert (or the controller's web certificate
   page), move it to *trusted* — or import `cert.pem` directly.
2. **Check the controller clock.** Encrypted channels validate message
   timestamps. If the PLC clock is skewed from real time the server rejects the
   channel (`BadSecurityChecksFailed`). Enable NTP or set the clock to within a
   couple of minutes of UTC. (open62541 logs a *"CreatedAt timestamp ... does
   not match the local system clock"* warning when this skew is present.)

Once both are done:

```bash
PLC_M240_URL=opc.tcp://10.50.10.235:4840 PLC_M240_SECURE=1 \
  dart test --run-skipped test/plc
```
