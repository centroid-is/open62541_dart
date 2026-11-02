#!/usr/bin/env python3
"""Reference OPC UA *client* (asyncua) that resolves a custom structured
DataType published by the Dart `Server` the OPC UA 1.04 way: it fetches the
DataTypeDefinitions (`load_data_type_definitions`, what UaExpert does),
reads the struct value, and decodes it only if the ExtensionObject on the
wire carries the `defaultEncodingId` the definition advertises. It then
writes a modified instance back and reads it again.

Prints one JSON object per step to stdout so the driving Dart test can
assert on the results via Process. Exits non-zero on any failure.

Usage: python custom_struct_asyncua.py --endpoint opc.tcp://127.0.0.1:PORT
         --node "ns=1;s=..." --type "ns=1;s=..."
"""
import argparse
import asyncio
import json
import sys

from asyncua import Client, ua


def emit(obj) -> None:
    print(json.dumps(obj), flush=True)


def fields(obj):
    """A decoded struct as plain JSON (nested structs recursively)."""
    if hasattr(obj, "__dataclass_fields__"):
        return {name: fields(getattr(obj, name)) for name in obj.__dataclass_fields__}
    return obj


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--node", required=True)
    ap.add_argument("--type", required=True)
    args = ap.parse_args()

    client = Client(url=args.endpoint)
    await client.connect()
    try:
        var = client.get_node(args.node)
        dt = client.get_node(args.type)

        # --- What the address space says about the type (no decoding yet). ---
        definition = (await dt.read_attribute(ua.AttributeIds.DataTypeDefinition)).Value.Value
        encodings = await dt.get_referenced_nodes(refs=ua.ObjectIds.HasEncoding, direction=ua.BrowseDirection.Forward)
        raw = (await var.read_data_value()).Value.Value
        emit({
            "step": "address_space",
            "data_type": (await var.read_data_type()).to_string(),
            "default_encoding_id": definition.DefaultEncodingId.to_string(),
            "fields": [f.Name for f in definition.Fields],
            "has_encoding_targets": [n.nodeid.to_string() for n in encodings],
            "encoding_browse_names": [(await n.read_browse_name()).to_string() for n in encodings],
            "wire_type_id": raw.TypeId.to_string() if isinstance(raw, ua.ExtensionObject) else None,
        })

        # --- The 1.04 path: definitions -> Python class -> decoded value. ---
        await client.load_data_type_definitions()
        value = await var.read_value()
        emit({
            "step": "read",
            "python_type": type(value).__name__,
            "fields": fields(value) if not isinstance(value, ua.ExtensionObject) else None,
        })
        if isinstance(value, ua.ExtensionObject):
            emit({"step": "error", "message": "value stayed an opaque ExtensionObject"})
            return 1

        # --- Write a modified instance back (a bare DataValue: open62541 refuses
        # a client-sent timestamp with BadWriteNotSupported) and read it again. ---
        value.Id = 42
        value.Label = "from-asyncua"
        value.Inner.Flag = False
        await var.write_attribute(ua.AttributeIds.Value, ua.DataValue(ua.Variant(value, ua.VariantType.ExtensionObject)))
        back = await var.read_value()
        emit({
            "step": "read_back",
            "python_type": type(back).__name__,
            "fields": fields(back) if not isinstance(back, ua.ExtensionObject) else None,
        })
        emit({"step": "done"})
        return 0
    except Exception as e:  # noqa: BLE001
        emit({"step": "error", "message": f"{type(e).__name__}: {e}"})
        return 1
    finally:
        await client.disconnect()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
