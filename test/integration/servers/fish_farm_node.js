#!/usr/bin/env node
// Reference OPC UA server (node-opcua) exposing the same HMI fish-farm model as
// fish_farm_asyncua.py (namespace http://centroid.is/fishfarm). Nodes are
// addressed by BrowseName so tests resolve them by browsing.
//
// Usage: node fish_farm_node.js --port 4842 --tanks 3 [--no-live] [--update-ms 250]
// Prints "READY <endpoint>" to stdout once listening.
"use strict";

const {
  OPCUAServer,
  Variant,
  DataType,
  StatusCodes,
  standardUnits,
} = require("node-opcua");

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
}

async function main() {
  const port = parseInt(arg("port", "4842"), 10);
  const tanks = parseInt(arg("tanks", "3"), 10);
  const live = arg("no-live", false) === false;
  const updateMs = parseInt(arg("update-ms", "250"), 10);
  const resourcePath = "/fishfarm/server/";

  const server = new OPCUAServer({
    port,
    resourcePath,
    hostname: "127.0.0.1",
    alternateHostname: ["127.0.0.1"],
    serverInfo: { applicationName: { text: "Fish Farm Reference Server (node)" } },
  });

  await server.initialize();
  const addressSpace = server.engine.addressSpace;
  const ns = addressSpace.registerNamespace("http://centroid.is/fishfarm");
  const objects = addressSpace.rootFolder.objects;

  const plant = ns.addObject({ organizedBy: objects, browseName: "Plant" });

  const state = [];
  for (let i = 1; i <= tanks; i++) {
    const tank = ns.addObject({ componentOf: plant, browseName: `Tank${i}` });
    const s = {
      Temperature: 12.0,
      DissolvedOxygen: 8.5,
      PH: 7.2,
      Salinity: 34.0,
      WaterLevel: 95.0,
    };
    state.push(s);

    function sensor(name, dataType) {
      ns.addVariable({
        componentOf: tank,
        browseName: name,
        dataType,
        minimumSamplingInterval: 100,
        value: {
          get: () => new Variant({ dataType: DataType[dataType], value: s[name] }),
        },
      });
    }
    sensor("Temperature", "Double");
    sensor("DissolvedOxygen", "Double");
    sensor("PH", "Double");
    sensor("Salinity", "Double");
    sensor("WaterLevel", "Double");

    let setpoint = 12.0;
    ns.addVariable({
      componentOf: tank,
      browseName: "TempSetpoint",
      dataType: "Double",
      value: {
        get: () => new Variant({ dataType: DataType.Double, value: setpoint }),
        set: (v) => {
          setpoint = v.value;
          return StatusCodes.Good;
        },
      },
    });

    let pumpRunning = true;
    ns.addVariable({
      componentOf: tank,
      browseName: "PumpRunning",
      dataType: "Boolean",
      value: {
        get: () => new Variant({ dataType: DataType.Boolean, value: pumpRunning }),
        set: (v) => {
          pumpRunning = v.value;
          return StatusCodes.Good;
        },
      },
    });

    ns.addVariable({ componentOf: tank, browseName: "AlarmActive", dataType: "Boolean", value: { get: () => new Variant({ dataType: DataType.Boolean, value: false }) } });
    ns.addVariable({ componentOf: tank, browseName: "AlarmMessage", dataType: "String", value: { get: () => new Variant({ dataType: DataType.String, value: "" }) } });
    ns.addVariable({ componentOf: tank, browseName: "AlarmSeverity", dataType: "UInt16", value: { get: () => new Variant({ dataType: DataType.UInt16, value: 0 }) } });

    const feed = ns.addMethod(tank, {
      browseName: "FeedNow",
      inputArguments: [{ name: "grams", dataType: DataType.Double }],
      outputArguments: [{ name: "accepted", dataType: DataType.Boolean }],
    });
    feed.bindMethod((inputArguments, context, callback) => {
      const grams = inputArguments[0].value;
      callback(null, {
        statusCode: StatusCodes.Good,
        outputArguments: [new Variant({ dataType: DataType.Boolean, value: grams >= 0 })],
      });
    });

    const reset = ns.addMethod(tank, {
      browseName: "ResetAlarm",
      inputArguments: [],
      outputArguments: [{ name: "ok", dataType: DataType.Boolean }],
    });
    reset.bindMethod((inputArguments, context, callback) => {
      callback(null, {
        statusCode: StatusCodes.Good,
        outputArguments: [new Variant({ dataType: DataType.Boolean, value: true })],
      });
    });
  }

  await server.start();
  const endpoint = server.getEndpointUrl();
  console.log(`READY ${endpoint}`);

  if (live) {
    let t = 0;
    setInterval(() => {
      for (let k = 0; k < state.length; k++) {
        const phase = k + 1;
        state[k].Temperature = 12.0 + 1.5 * Math.sin(t + phase);
        state[k].DissolvedOxygen = 8.5 + 0.6 * Math.sin(0.7 * t + phase);
        state[k].PH = 7.2 + 0.2 * Math.sin(0.3 * t + phase);
        state[k].WaterLevel = 95.0 - 2.0 * Math.abs(Math.sin(0.1 * t + phase));
      }
      t += updateMs / 1000;
    }, updateMs);
  }

  process.on("SIGTERM", () => process.exit(0));
  process.on("SIGINT", () => process.exit(0));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
