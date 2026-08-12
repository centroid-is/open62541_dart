#!/usr/bin/env python3
"""Reference OPC UA server (asyncua) exposing an HMI-style fish-farm node model.

Shared model used across the integration suite so the same scenarios can run
against multiple stacks. Browse structure (namespace: http://centroid.is/fishfarm):

  Objects/
    Plant/
      Tank1/ .. TankN/
        Temperature      Double  (read-only sensor, live-updating)
        DissolvedOxygen  Double  (read-only sensor, live-updating)
        PH               Double  (read-only sensor, live-updating)
        Salinity         Double  (read-only sensor)
        WaterLevel       Double  (read-only sensor, live-updating)
        TempSetpoint     Double  (writable)
        PumpRunning      Boolean (writable)
        AlarmActive      Boolean
        AlarmMessage     String
        AlarmSeverity    UInt16
        FeedNow(grams: Double) -> accepted: Boolean   (method)
        ResetAlarm() -> ok: Boolean                   (method)

Nodes are addressed by BrowseName so tests resolve them by browsing (namespace
indices differ between server implementations).

Usage: python fish_farm_asyncua.py --port 4841 --tanks 3 [--no-live] [--uri opc.tcp://0.0.0.0:PORT]
Prints a line "READY <endpoint>" to stdout once listening.
"""
import argparse
import asyncio
import math
import sys

from asyncua import Server, ua


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4841)
    ap.add_argument("--tanks", type=int, default=3)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--no-live", action="store_true", help="do not mutate sensor values")
    ap.add_argument("--update-ms", type=int, default=250)
    args = ap.parse_args()

    server = Server()
    await server.init()
    endpoint = f"opc.tcp://{args.host}:{args.port}/fishfarm/server/"
    server.set_endpoint(endpoint)
    server.set_server_name("Fish Farm Reference Server")
    # Anonymous access, no encryption -- matches the Dart client's default path.
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])

    idx = await server.register_namespace("http://centroid.is/fishfarm")
    objects = server.nodes.objects
    plant = await objects.add_object(idx, "Plant")

    tanks = []
    for i in range(1, args.tanks + 1):
        tank = await plant.add_object(idx, f"Tank{i}")
        temperature = await tank.add_variable(idx, "Temperature", 12.0, ua.VariantType.Double)
        oxygen = await tank.add_variable(idx, "DissolvedOxygen", 8.5, ua.VariantType.Double)
        ph = await tank.add_variable(idx, "PH", 7.2, ua.VariantType.Double)
        salinity = await tank.add_variable(idx, "Salinity", 34.0, ua.VariantType.Double)
        level = await tank.add_variable(idx, "WaterLevel", 95.0, ua.VariantType.Double)

        setpoint = await tank.add_variable(idx, "TempSetpoint", 12.0, ua.VariantType.Double)
        await setpoint.set_writable()
        pump = await tank.add_variable(idx, "PumpRunning", True, ua.VariantType.Boolean)
        await pump.set_writable()

        alarm_active = await tank.add_variable(idx, "AlarmActive", False, ua.VariantType.Boolean)
        alarm_msg = await tank.add_variable(idx, "AlarmMessage", "", ua.VariantType.String)
        alarm_sev = await tank.add_variable(idx, "AlarmSeverity", 0, ua.VariantType.UInt16)

        async def feed_now(parent, grams, _alarm=alarm_active):  # noqa: ANN001
            # Accept any non-negative feed amount.
            val = grams.Value if isinstance(grams, ua.Variant) else grams
            return [ua.Variant(bool(val is not None and float(val) >= 0.0), ua.VariantType.Boolean)]

        await tank.add_method(idx, "FeedNow", feed_now, [ua.VariantType.Double], [ua.VariantType.Boolean])

        async def reset_alarm(parent, _active=alarm_active, _msg=alarm_msg, _sev=alarm_sev):  # noqa: ANN001
            await _active.write_value(False)
            await _msg.write_value("")
            await _sev.write_value(ua.UInt16(0))
            return [ua.Variant(True, ua.VariantType.Boolean)]

        await tank.add_method(idx, "ResetAlarm", reset_alarm, [], [ua.VariantType.Boolean])

        tanks.append(
            dict(temperature=temperature, oxygen=oxygen, ph=ph, level=level, i=i)
        )

    async with server:
        print(f"READY {endpoint}", flush=True)
        t = 0.0
        while True:
            if not args.no_live:
                for tk in tanks:
                    phase = tk["i"]
                    await tk["temperature"].write_value(12.0 + 1.5 * math.sin(t + phase))
                    await tk["oxygen"].write_value(8.5 + 0.6 * math.sin(0.7 * t + phase))
                    await tk["ph"].write_value(7.2 + 0.2 * math.sin(0.3 * t + phase))
                    await tk["level"].write_value(95.0 - 2.0 * abs(math.sin(0.1 * t + phase)))
            t += args.update_ms / 1000.0
            await asyncio.sleep(args.update_ms / 1000.0)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
