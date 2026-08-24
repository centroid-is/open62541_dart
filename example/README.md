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

## `resilient_client.dart` — secure, self-healing client

A client that connects with certificates (`SignAndEncrypt`), recreates its
subscriptions after a session loss, and keeps a monitored item alive across
reconnects. It expects `client_cert.der` and `client_key.der` in the working
directory:

```bash
dart run example/resilient_client.dart opc.tcp://localhost:4840 [username] [password]
```
