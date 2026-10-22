# open62541 examples

Runnable examples for the `open62541` package. On the first run the native
open62541 library is built from source by the package's build hook, so allow
some extra time for the initial `dart pub get` / `dart run`.

## `example.dart` — minimal client

Connects to an OPC UA server and reads the current server time. Run it against
any OPC UA endpoint:

```bash
dart run example/example.dart opc.tcp://localhost:4840
```

## `browse_test.dart` — browsing the address space

Browses the `Objects` folder and walks the address-space tree:

```bash
dart run example/browse_test.dart opc.tcp://localhost:4840
```

## `server_example.dart` — running a server

Starts an OPC UA server exposing scalar, array and custom-structure variables:

```bash
dart run example/server_example.dart
```

The server speaks SecurityPolicy None with anonymous access and binds all
interfaces: anyone who can reach port 4840 can read and write its nodes. Run
it on a trusted network only.

## `resilient_client.dart` — encrypted, self-healing client

A client that connects with a certificate (`SignAndEncrypt`), verifies the
server against a trust list, recreates its subscriptions after a session
loss, and keeps a monitored item alive across reconnects. It expects
`client_cert.der`, `client_key.der` and `server_cert.der` (the server's
certificate, or the CA certificate that issued it) in the working directory:

```bash
dart run example/resilient_client.dart opc.tcp://localhost:4840 [username] [password]
```

## `discover_endpoints.dart` — endpoint discovery, trust on first use

Lists a server's endpoints (security policy and mode, identity tokens, who
the server says it is) and the SHA-1 thumbprint of its certificate, through
the GetEndpoints service, which needs no certificate and no trust list. With
a second argument it saves the server certificate (DER) to that file, to be
the `trustList` of `resilient_client.dart` once the thumbprint has been
confirmed with the server's operator (discovery authenticates nothing, so a
machine in the middle at that moment would be trusted otherwise):

```bash
dart run example/discover_endpoints.dart opc.tcp://localhost:4840 [server_cert.der]
```
