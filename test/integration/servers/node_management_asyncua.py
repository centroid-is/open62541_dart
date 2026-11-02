"""Reference client (asyncua) that tries to reshape a server's address space.

Connects anonymously over SecurityPolicy#None, adds an object under the
Objects folder and deletes it again. Prints one JSON object per step with the
OPC UA status code of what the server answered (0 = Good).

    python node_management_asyncua.py --endpoint opc.tcp://127.0.0.1:4840
"""

import argparse
import asyncio
import json

from asyncua import Client, ua


def emit(step, **fields):
    print(json.dumps({"step": step, **fields}), flush=True)


def code_of(error):
    # asyncua raises UaStatusCodeError (or a subclass per code) with .code.
    return getattr(error, "code", None)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    args = parser.parse_args()

    async with Client(url=args.endpoint) as client:
        objects = client.nodes.objects
        try:
            node = await objects.add_object(1, "asyncua_added")
            emit("add_object", code=0, node=node.nodeid.to_string())
        except ua.UaStatusCodeError as error:
            emit("add_object", code=code_of(error))
            emit("done")
            return
        try:
            await node.delete()
            emit("delete_node", code=0)
        except ua.UaStatusCodeError as error:
            emit("delete_node", code=code_of(error))
        emit("done")


if __name__ == "__main__":
    asyncio.run(main())
