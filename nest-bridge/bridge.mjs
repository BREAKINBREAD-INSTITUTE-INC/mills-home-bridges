// MILLS TV · Nest bridge (runs on Hub).
//
// Joins the Nest thermostat as a second, READ-ONLY Matter controller (Matter multi-admin: the
// Google Home fabric stays exactly as it is) and serves what it reads as JSON on the LAN, for the
// TV's House view. No cloud, no Google API key, no account password: pairing uses the one-time
// code the Google Home app generates under "Linked Matter apps & services".
//
//   node bridge.mjs pair <11-digit code>   once, while the Google Home share code is valid
//   node bridge.mjs serve                  keep running (launchd does this); GET /api/house
//   node bridge.mjs status                 print one reading and exit
//
// The bridge never writes to the thermostat: the TV reads, the phone changes things.

import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Environment, StorageService, Logger } from "@matter/main";
import { ManualPairingCodeCodec, QrPairingCodeCodec, NodeId } from "@matter/main/types";
import { Thermostat, RelativeHumidityMeasurement, GeneralCommissioning } from "@matter/main/clusters";
import { CommissioningController } from "@project-chip/matter.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.NEST_BRIDGE_PORT ?? 8778);
const POLL_MS = 60_000;

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
    mode: null,           // Off / Heat / Cool / Heat·Cool / Eco ...
    running: null,        // idle / heating / cooling / fan
    error: null,
};

const c2f = (v) => (v === null || v === undefined ? null : Math.round((v / 100) * 9 / 5 + 32));
const MODES = { 0: "Off", 1: "Heat · Cool", 3: "Cool", 4: "Heat", 5: "Emergency heat", 6: "Precooling", 7: "Fan only", 8: "Dry", 9: "Sleep" };

function running(state) {
    if (!state) return "idle";
    if (state.heat || state.heatStage2 || state.auxHeat) return "heating";
    if (state.cool || state.coolStage2) return "cooling";
    if (state.fan || state.fanStage2 || state.fanStage3) return "fan";
    return "idle";
}

async function readNode(node) {
    let thermo, humid;
    for (const ep of node.getDevices()) {
        thermo ??= ep.getClusterClient(Thermostat.Cluster);
        humid ??= ep.getClusterClient(RelativeHumidityMeasurement.Cluster);
    }
    if (!thermo) throw new Error("no thermostat cluster on this node");
    const [local, heat, cool, mode, state] = await Promise.all([
        thermo.getLocalTemperatureAttribute(),
        thermo.getOccupiedHeatingSetpointAttribute().catch(() => null),
        thermo.getOccupiedCoolingSetpointAttribute().catch(() => null),
        thermo.getSystemModeAttribute().catch(() => null),
        thermo.getThermostatRunningStateAttribute().catch(() => null),
    ]);
    let rh = null;
    if (humid) rh = await humid.getMeasuredValueAttribute().catch(() => null);
    Object.assign(reading, {
        ok: true, at: Date.now(), error: null,
        indoorF: c2f(local), heatF: c2f(heat), coolF: c2f(cool),
        humidity: rh === null ? null : Math.round(rh / 100),
        mode: mode === null ? null : (MODES[mode] ?? `mode ${mode}`),
        running: running(state),
        name: node.basicInformation?.nodeLabel || node.basicInformation?.productName || "Nest thermostat",
    });
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

    http.createServer((req, res) => {
        if (req.method !== "GET" || !req.url.startsWith("/api/house")) { res.writeHead(404); res.end(); return; }
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        res.end(JSON.stringify({ ...reading, ageSec: reading.at ? Math.round((Date.now() - reading.at) / 1000) : null }));
    }).listen(PORT, "0.0.0.0", () => console.log(`Nest bridge on http://0.0.0.0:${PORT}/api/house`));
}

const [cmd, arg] = process.argv.slice(2);
await controller.start();
if (cmd === "pair" && arg) { await pair(arg); await controller.close(); process.exit(0); }
else if (cmd === "status") {
    const node = await firstNode();
    if (!node) console.log("Not paired yet.");
    else { await readNode(node); console.log(JSON.stringify(reading, null, 2)); }
    await controller.close(); process.exit(0);
}
else if (cmd === "serve") await serve();
else { console.log("usage: node bridge.mjs pair <code> | serve | status"); process.exit(1); }
