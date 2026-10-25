// MILLS TV · Nest bridge v2 (runs on Hub).
//
// Joins the Nest thermostat as a second Matter controller (Matter multi-admin: the Google Home
// fabric stays exactly as it is) and serves it as JSON on the LAN for the TV's House view. No
// cloud, no Google API key, no account password: pairing uses the one-time code the Google Home
// app generates under "Linked Matter apps & services".
//
//   node bridge.mjs pair <11-digit code>   once, while the Google Home share code is valid
//   node bridge.mjs serve                  keep running (launchd does this); see api.mjs for routes
//   node bridge.mjs status                 print one reading and what the Nest exposes, then exit
//
// v2 can change the cooling/heating setpoints and the mode, and nothing else. The rules for that
// (allowlist, 68-82 °F, heat/cool gap, rate limit, read-back, change log) live in control.mjs and
// api.mjs. What the Nest Learning Thermostat 4th gen (sw 2.4) exposes over Matter, read Oct 23:
//   endpoint 1: Descriptor, Identify, OnOff, Thermostat (rev 9), Thermostat UI Configuration
//   Thermostat features: Heating, Cooling, AutoMode. No Occupancy, Setback, Presets (so no Eco),
//   Schedules, Events. ControlSequenceOfOperation 4 (cooling and heating). Attributes: local
//   temperature, abs min/max heat and cool limits (50-90 °F), occupied heat/cool setpoints,
//   MinSetpointDeadBand (0), control sequence, SystemMode. Not exposed: running state, PI demand,
//   min/max setpoint limits, humidity, fan (no FanControl cluster), outdoor temperature.
//   Accepted commands: SetpointRaiseLower only.

import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Environment, StorageService, Logger } from "@matter/main";
import { ManualPairingCodeCodec, QrPairingCodeCodec } from "@matter/main/types";
import { Thermostat, RelativeHumidityMeasurement, FanControl, GeneralCommissioning } from "@matter/main/clusters";
import { CommissioningController } from "@project-chip/matter.js";
import { c2f, MODE_LABEL, parseAllow, RateLimit, ChangeLog } from "./control.mjs";
import { createHandler } from "./api.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.NEST_BRIDGE_PORT ?? 8778);
const POLL_MS = 60_000;
// Only these addresses may read or change anything: HUB itself and the TV (same rule as the board).
const TV_IP = process.env.NEST_TV_IP ?? "<tv-ip>";
const ALLOW = parseAllow(process.env.NEST_ALLOW ?? `127.0.0.1,${TV_IP}`);

Logger.level = process.env.MATTER_LOG ?? "warn";
const environment = Environment.default;
environment.vars.set("storage.path", path.join(HERE, ".matter-storage"));
environment.get(StorageService);

const controller = new CommissioningController({
    environment: { environment, id: "mills-nest-bridge" },
    autoConnect: false,
    adminFabricLabel: "MILLS TV",
});

const reading = {
    ok: false,            // a reading came back from the thermostat
    at: 0,                // when (ms since epoch)
    paired: false,
    name: null,
    indoorF: null, heatF: null, coolF: null, humidity: null,
    mode: null,           // Off / Heat / Cool / Heat · Cool ...
    running: null,        // idle / heating / cooling / fan (the Nest doesn't expose it: see runningExposed)
    error: null,
};
let modeValue = null;     // raw SystemMode, for modeKey in GET (kept out of the v1 fields)
let info = null;          // what the device reports about itself, read once per connection
let clients = null;       // { thermo, humid, fan }

function running(state) {
    if (!state) return "idle";
    if (state.heat || state.heatStage2 || state.auxHeat) return "heating";
    if (state.cool || state.coolStage2) return "cooling";
    if (state.fan || state.fanStage2 || state.fanStage3) return "fan";
    return "idle";
}

function findClients(node) {
    let thermo, humid, fan;
    for (const ep of node.getDevices()) {
        thermo ??= ep.getClusterClient(Thermostat.Complete);
        humid ??= ep.getClusterClient(RelativeHumidityMeasurement.Cluster);
        fan ??= ep.getClusterClient(FanControl.Complete);
    }
    if (!thermo) throw new Error("no thermostat cluster on this node");
    return { thermo, humid, fan };
}

const A = Thermostat.Complete.attributes;
async function readInfo(thermo, fan) {
    const get = (a) => thermo.attributes[a].get().catch(() => null);
    const [features, controlSequence, absMinHeat, absMaxHeat, absMinCool, absMaxCool, deadBand, list] = await Promise.all([
        get("featureMap"), get("controlSequenceOfOperation"), get("absMinHeatSetpointLimit"), get("absMaxHeatSetpointLimit"),
        get("absMinCoolSetpointLimit"), get("absMaxCoolSetpointLimit"), get("minSetpointDeadBand"), get("attributeList"),
    ]);
    const has = (a) => Array.isArray(list) && list.includes(A[a].id);
    return {
        features: features ?? {}, controlSequence, absMinHeat, absMaxHeat, absMinCool, absMaxCool, deadBand,
        exposes: { runningState: has("thermostatRunningState"), presets: !!features?.presets, fan: !!fan },
    };
}

async function readNode(node) {
    clients ??= findClients(node);
    const { thermo, humid, fan } = clients;
    info ??= await readInfo(thermo, fan);
    const get = (a) => thermo.attributes[a].get().catch(() => null);
    const [local, heat, cool, mode, state] = await Promise.all([
        thermo.attributes.localTemperature.get(),
        get("occupiedHeatingSetpoint"), get("occupiedCoolingSetpoint"), get("systemMode"),
        info.exposes.runningState ? get("thermostatRunningState") : null,
    ]);
    let rh = null;
    if (humid) rh = await humid.getMeasuredValueAttribute().catch(() => null);
    modeValue = mode;
    Object.assign(reading, {
        ok: true, at: Date.now(), error: null,
        indoorF: c2f(local), heatF: c2f(heat), coolF: c2f(cool),
        humidity: rh === null || rh === undefined ? null : Math.round(rh / 100),
        mode: mode === null ? null : (MODE_LABEL[mode] ?? `mode ${mode}`),
        running: running(state),
        name: node.basicInformation?.nodeLabel || node.basicInformation?.productName || "Nest thermostat",
    });
}

/** Setpoints and mode straight from the thermostat (not the subscription cache). */
async function readFresh() {
    if (!clients) throw new Error("thermostat not connected");
    const { thermo } = clients;
    const [heat, cool, mode] = await Promise.all([
        thermo.attributes.occupiedHeatingSetpoint.get(true),
        thermo.attributes.occupiedCoolingSetpoint.get(true),
        thermo.attributes.systemMode.get(true),
    ]);
    modeValue = mode;
    Object.assign(reading, { heatF: c2f(heat), coolF: c2f(cool), mode: MODE_LABEL[mode] ?? `mode ${mode}`, at: Date.now(), ok: true });
    return { heatF: c2f(heat), coolF: c2f(cool), mode };
}

async function write(what, value) {
    if (!clients) throw new Error("thermostat not connected");
    const a = { cool: "occupiedCoolingSetpoint", heat: "occupiedHeatingSetpoint", mode: "systemMode" }[what];
    if (!a) throw new Error("unknown setting");
    await clients.thermo.attributes[a].set(value);
}

async function pair(codeText) {
    const code = codeText.replace(/[^0-9A-Z:.-]/gi, "");
    let passcode, identifierData;
    if (code.startsWith("MT:")) {
        const qr = QrPairingCodeCodec.decode(code)[0];
        passcode = qr.passcode;
        identifierData = { longDiscriminator: qr.discriminator };
    } else {
        const m = ManualPairingCodeCodec.decode(code.replace(/\D/g, ""));
        passcode = m.passcode;
        identifierData = { shortDiscriminator: m.shortDiscriminator };
    }
    console.log("Looking for the thermostat's open sharing window on the network…");
    const nodeId = await controller.commissionNode({
        commissioning: {
            regulatoryLocation: GeneralCommissioning.RegulatoryLocationType.IndoorOutdoor,
            regulatoryCountryCode: "US",
        },
        discovery: { identifierData, discoveryCapabilities: { onIpNetwork: true }, timeout: 120_000 },
        passcode,
    });
    console.log(`Paired. The Nest is node ${nodeId} on the MILLS TV fabric (Google Home is untouched).`);
}

async function firstNode() {
    const ids = controller.getCommissionedNodes();
    if (ids.length === 0) return null;
    const node = await controller.getNode(ids[0]);
    if (!node.isConnected) node.connect();
    if (!node.initialized) await node.events.initialized;
    return node;
}

async function serve() {
    let node = null;
    const tick = async () => {
        try {
            node ??= await firstNode();
            reading.paired = !!node;
            if (!node) { reading.error = "not paired yet: run `node bridge.mjs pair <code>`"; return; }
            await readNode(node);
        } catch (e) {
            reading.ok = false;
            reading.error = String(e?.message ?? e).slice(0, 200);
        }
    };
    await tick();
    setInterval(tick, POLL_MS);

    const handle = createHandler({
        device: {
            snapshot: () => reading,
            modeValue: () => modeValue,
            info: () => (reading.paired && clients ? info : null),
            readFresh, write,
        },
        allow: ALLOW, tvIp: TV_IP,
        rate: new RateLimit({ minGapMs: 3000, perHour: 30 }),
        log: new ChangeLog(path.join(HERE, "changes.jsonl")),
    });
    http.createServer(handle).listen(PORT, "0.0.0.0", () => console.log(`Nest bridge v2 on http://0.0.0.0:${PORT}/api/house · allowed: ${[...ALLOW].join(", ")}`));
}

const [cmd, arg] = process.argv.slice(2);
await controller.start();
if (cmd === "pair" && arg) { await pair(arg); await controller.close(); process.exit(0); }
else if (cmd === "status") {
    const node = await firstNode();
    if (!node) console.log("Not paired yet.");
    else { await readNode(node); console.log(JSON.stringify({ ...reading, info }, null, 2)); }
    await controller.close(); process.exit(0);
}
else if (cmd === "serve") await serve();
else { console.log("usage: node bridge.mjs pair <code> | serve | status"); process.exit(1); }
