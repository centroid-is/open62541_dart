#!/usr/bin/env python3
"""Reference OPC UA *client* (asyncua) used to prove the Dart `Server`
interoperates outward with an independent stack.

Connects to a Dart-hosted server (built with the Dart `Server` +
`addBasicVariables`, exposing ns=1 string-id nodes the.bool / the.int /
the.double / the.string), reads each value, writes a new value, reads it
back, and prints one JSON object per step to stdout so the driving Dart test
can assert on the results via Process. Exits non-zero on any failure.

Usage: python reference_client_asyncua.py --endpoint opc.tcp://127.0.0.1:PORT
"""
import argparse
import asyncio
import json
import sys

from asyncua import Client, ua


def emit(obj) -> None:
    print(json.dumps(obj), flush=True)


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    args = ap.parse_args()

    client = Client(url=args.endpoint)
    await client.connect()
    try:
        the_double = client.get_node("ns=1;s=the.double")
        the_bool = client.get_node("ns=1;s=the.bool")
        the_int = client.get_node("ns=1;s=the.int")
        the_string = client.get_node("ns=1;s=the.string")

        # --- Read the initial values the Dart server seeded. ---
        emit({
            "step": "read_initial",
            "double": await the_double.read_value(),
            "bool": await the_bool.read_value(),
            "int": await the_int.read_value(),
            "string": await the_string.read_value(),
        })

        # --- Also resolve a node by BrowseName to prove browsing works. ---
        objects = client.nodes.objects
        found = None
        for child in await objects.get_children():
            bn = await child.read_browse_name()
            if bn.Name == "the.double":
                found = child.nodeid.to_string()
                break
        emit({"step": "browse", "found_the_double": found})

        # --- Write new values (outward interop: independent client mutates
        #     the Dart server's address space). We write the Value attribute
        #     with a timestamp-free DataValue: open62541 servers reject writes
        #     that carry a SourceTimestamp (BadWriteNotSupported), which is what
        #     asyncua's convenience write_value() attaches by default. ---
        async def write_value_only(node, variant):
            dv = ua.DataValue(Value=variant)
            dv.SourceTimestamp = None
            dv.ServerTimestamp = None
            await node.write_attribute(ua.AttributeIds.Value, dv)

        await write_value_only(the_double, ua.Variant(42.5, ua.VariantType.Double))
        await write_value_only(the_bool, ua.Variant(False, ua.VariantType.Boolean))
        await write_value_only(the_int, ua.Variant(1234, ua.VariantType.Int32))
        await write_value_only(the_string, ua.Variant("from-asyncua", ua.VariantType.String))
        emit({"step": "wrote"})

        # --- Read the values back through the same client. ---
        emit({
            "step": "read_back",
            "double": await the_double.read_value(),
            "bool": await the_bool.read_value(),
            "int": await the_int.read_value(),
            "string": await the_string.read_value(),
        })
    finally:
        await client.disconnect()

    emit({"step": "done"})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as exc:  # noqa: BLE001
        emit({"step": "error", "message": repr(exc)})
        sys.exit(1)
