#!/usr/bin/env python3
"""Emulates a PLC's OPC UA server for LOCAL verification of the PLC tests.

Mirrors the fixture in test/plc/plc_fixture.dart and mimics vendor traits:
  - username/password auth (like the real controllers)
  - a live CurrentSessionCount so tests can prove sessions are freed
  - complex types (struct) only for the twincat/m262 profiles (M240 = scalars)

Usage:
  python plc_emulator.py --port 4860 --profile twincat|m240|m262 \
      --user tester --password test-pass-1 [--tanks-uri ...]
Prints "READY <endpoint>" once listening.
"""
import argparse
import asyncio
import sys

from asyncua import Server, ua
from asyncua.server.user_managers import User, UserRole


class _PwUserManager:
    """Accept exactly one username/password; everyone else is rejected."""

    def __init__(self, username, password):
        self._u = username
        self._p = password

    def get_user(self, iserver, username=None, password=None, certificate=None):
        if username == self._u and password == self._p:
            return User(role=UserRole.User)
        return None


def _current_session_count(server) -> int:
    """Live count of external client sessions (asyncua 2.x internal registry)."""
    iserver = server.iserver
    for attr in ("_external_sessions", "sessions", "_sessions"):
        obj = getattr(iserver, attr, None)
        if isinstance(obj, dict):
            return len(obj)
    return -1  # unknown


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4860)
    ap.add_argument("--profile", choices=["twincat", "m240", "m262"], default="twincat")
    ap.add_argument("--user", default="tester")
    ap.add_argument("--password", default="test-pass-1")
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()
    complex_ok = args.profile in ("twincat", "m262")

    server = Server(user_manager=_PwUserManager(args.user, args.password))
    await server.init()
    endpoint = f"opc.tcp://{args.host}:{args.port}/"
    server.set_endpoint(endpoint)
    server.set_server_name(f"PLC Emulator ({args.profile})")
    # Username/password only, no anonymous -- like the controllers.
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])
    server.set_security_IDs(["Username"])

    idx = await server.register_namespace(f"http://centroid.is/plc/{args.profile}")
    objects = server.nodes.objects

    # Mimic a TwinCAT-ish path: PLC1 -> GVL_Test -> variables.
    plc = await objects.add_object(idx, "PLC1")
    gvl = await plc.add_object(idx, "GVL_Test")

    async def var(name, val, vtype, writable=True):
        v = await gvl.add_variable(idx, name, val, vtype)
        if writable:
            await v.set_writable()
        return v

    await var("TestBool", False, ua.VariantType.Boolean)
    await var("TestInt", 0, ua.VariantType.Int16)
    await var("TestDint", 0, ua.VariantType.Int32)
    await var("TestReal", 0.0, ua.VariantType.Float)
    await var("TestLreal", 0.0, ua.VariantType.Double)
    await var("TestString", "", ua.VariantType.String)
    await var("Setpoint", 0.0, ua.VariantType.Float)
    counter = await var("Counter", 0, ua.VariantType.Int32, writable=False)
    await var("TestArray", [0] * 10, ua.VariantType.Int32)

    if complex_ok:
        # A real OPC UA structure: TestStruct { Id:Int32, Value:Float,
        # Enabled:Bool, Label:String }.
        import asyncua.ua as uamod
        from asyncua.common.structures104 import new_struct, new_struct_field

        fields = [
            new_struct_field("Id", ua.VariantType.Int32),
            new_struct_field("Value", ua.VariantType.Float),
            new_struct_field("Enabled", ua.VariantType.Boolean),
            new_struct_field("Label", ua.VariantType.String),
        ]
        await new_struct(server, idx, "TestStructType", fields)
        await server.load_data_type_definitions()
        struct_cls = getattr(uamod, "TestStructType")
        inst = struct_cls()
        inst.Id = 0
        inst.Value = 0.0
        inst.Enabled = False
        inst.Label = ""
        sv = await gvl.add_variable(idx, "TestStruct", ua.Variant(inst, ua.VariantType.ExtensionObject))
        await sv.set_writable()

    # Live CurrentSessionCount (ns=0;i=2277) for the session tests.
    session_count_node = server.get_node(ua.NodeId(2277, 0))

    async with server:
        print(f"READY {endpoint}", flush=True)
        n = 0
        while True:
            n += 1
            await counter.write_value(ua.Variant(n, ua.VariantType.Int32))
            try:
                cnt = _current_session_count(server)
                if cnt >= 0:
                    await session_count_node.write_value(ua.Variant(cnt, ua.VariantType.UInt32))
            except Exception:
                pass
            await asyncio.sleep(0.2)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
