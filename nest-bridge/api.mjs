// MILLS TV · Nest bridge: the HTTP side. Kept apart from Matter so the tests can drive it with a
// fake thermostat (test/control.test.mjs). bridge.mjs passes in the real one.
//
//   GET  /api/house            the reading (same fields as v1) plus limits, modes, last change
//   GET  /api/house/changes    the last changes (newest last)
//   POST /api/house/cool       {"f": 76}            set the cooling setpoint
//   POST /api/house/heat       {"f": 70}            set the heating setpoint
//   POST /api/house/step       {"delta": 1|-1, "target"?: "cool"|"heat"}   one degree up or down
//   POST /api/house/mode       {"mode": "Off"|"Heat"|"Cool"|"Auto"}        only modes the Nest accepts
//
// Every request must come from an allowed address (403 otherwise). Every write is clamped to
// 68-82 °F, keeps heat below cool, is rate-limited, read back from the thermostat, and logged.

import { f2c, limits, clamp, parseMode, supportedModes, checkPair, normIp, who, MODE_KEY } from "./control.mjs";

const json = (res, code, body, extra = {}) => {
    res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store", ...extra });
    res.end(JSON.stringify(body));
};

function readBody(req) {
    return new Promise((resolve, reject) => {
        let s = "";
        req.on("data", (d) => { s += d; if (s.length > 1024) { reject(new Error("body too large")); req.destroy(); } });
        req.on("end", () => { try { resolve(s ? JSON.parse(s) : {}); } catch { reject(new Error("body is not JSON")); } });
        req.on("error", reject);
    });
}

/**
 * device: {
 *   snapshot()            -> the GET reading object (v1 fields)
 *   modeValue()           -> the raw SystemMode last read (or null)
 *   info()                -> { features, controlSequence, absMinHeat, absMaxHeat, absMinCool, absMaxCool, deadBand, exposes } | null
 *   readFresh()           -> Promise<{ heatF, coolF, mode }>   (mode: SystemMode number, read from the thermostat now)
 *   write(what, value)    -> Promise<void>   what: "cool"|"heat" (value in 0.01 °C) or "mode" (SystemMode)
 * }
 */
export function createHandler({ device, allow, tvIp, rate, log, readbackTries = 5, readbackGapMs = 800 }) {
    let chain = Promise.resolve();
    const serial = (fn) => { const p = chain.then(fn, fn); chain = p.catch(() => {}); return p; };

    const house = () => {
        const r = device.snapshot();
        const inf = device.info();
        const win = limits(inf ?? {});
        const ex = inf?.exposes ?? {};
        return {
            ...r,
            ageSec: r.at ? Math.round((Date.now() - r.at) / 1000) : null,
            // v2 additions (the TV's older builds ignore these)
            controls: !!inf,
            modeKey: MODE_KEY[device.modeValue?.()] ?? null,
            modes: inf ? supportedModes(inf.features, inf.controlSequence) : [],
            limits: { minF: win.minF, maxF: win.maxF, heat: win.heat, cool: win.cool, gapF: win.gapF, device: win.device },
            stepF: 1,
            runningExposed: !!ex.runningState,   // false on the Nest 4th gen: "running" is then a placeholder
            fan: ex.fan ? r.fan ?? null : null,  // no FanControl cluster on this Nest
            presets: ex.presets ? r.presets ?? null : null,  // no Presets feature (so no Eco) on this Nest
            lastChange: log.last,
        };
    };

    async function readback(what, wantF, wantMode) {
        let got = null;
        for (let i = 0; i < readbackTries; i++) {
            if (i) await new Promise((r) => setTimeout(r, readbackGapMs));
            got = await device.readFresh();
            if (what === "mode" ? got.mode === wantMode : got[what + "F"] === wantF) return { ok: true, got };
        }
        return { ok: false, got };
    }

    async function change(caller, what, body) {
        const inf = device.info();
        if (!inf) return [503, { ok: false, error: "thermostat not connected" }];
        const win = limits(inf);
        const now = await device.readFresh();
        const modeKey = MODE_KEY[now.mode] ?? null;

        let target, old, requested, clamped = false, value;
        if (what === "mode") {
            const m = parseMode(body.mode);
            const modes = supportedModes(inf.features, inf.controlSequence);
            if (!m || !modes.includes(m.key)) return [400, { ok: false, error: `mode must be one of ${modes.join(", ")}` }];
            requested = m.key; old = modeKey; target = m.value; value = m.key;
            if (now.mode === m.value) return [200, { ok: true, what, unchanged: true, confirmed: { mode: m.key }, house: house() }];
        } else {
            let which = what;
            if (what === "step") {
                const d = Number(body.delta);
                if (d !== 1 && d !== -1) return [400, { ok: false, error: "delta must be 1 or -1" }];
                which = body.target ?? (modeKey === "Cool" ? "cool" : modeKey === "Heat" ? "heat" : null);
                if (which !== "cool" && which !== "heat") {
                    return [409, { ok: false, error: modeKey === "Off" ? "the Nest is off: pick a mode first" : "say which setpoint: target cool or heat" }];
                }
                old = now[which + "F"];
                requested = old + d;
            } else {
                old = now[which + "F"];
                requested = Number(body.f);
            }
            target = clamp(requested, win[which]);
            if (target === null) return [400, { ok: false, error: "f must be a number (°F)" }];
            clamped = target !== Math.round(requested);
            if (target === old) {
                if (what === "step") return [409, { ok: false, error: `already at the ${d0(body.delta) > 0 ? "top" : "bottom"} limit (${old}°F)`, limits: win[which] }];
                return [200, { ok: true, what: which, unchanged: true, clamped, confirmed: { [which + "F"]: old }, house: house() }];
            }
            const heat = which === "heat" ? target : now.heatF, cool = which === "cool" ? target : now.coolF;
            const gap = checkPair(heat, cool, modeKey, win);
            if (gap) return [409, { ok: false, error: gap }];
            what = which; value = target;
        }

        const limited = rate.check();
        if (limited) return [429, { ok: false, ...limited }, { "retry-after": String(limited.retryAfterSec) }];
        rate.take();

        try {
            await device.write(what, what === "mode" ? target : f2c(target));
        } catch (e) {
            const err = "write failed: " + String(e?.message ?? e).slice(0, 120);
            log.add({ who: caller, what, old, requested, value: null, result: err });
            return [502, { ok: false, error: err }];
        }
        const rb = await readback(what, target, target);
        const got = what === "mode" ? (MODE_KEY[rb.got?.mode] ?? rb.got?.mode) : rb.got?.[what + "F"];
        if (!rb.ok) {
            const err = `read-back says ${got}${what === "mode" ? "" : "°F"}, asked ${value}${what === "mode" ? "" : "°F"}`;
            log.add({ who: caller, what, old, requested, value: got ?? null, result: err });
            return [502, { ok: false, error: err, confirmed: { [what === "mode" ? "mode" : what + "F"]: got } }];
        }
        log.add({ who: caller, what, old, requested, value: got, result: "ok" });
        return [200, { ok: true, what, old, requested, clamped, confirmed: { [what === "mode" ? "mode" : what + "F"]: got }, house: house() }];
    }

    return async function handle(req, res) {
        const ip = normIp(req.socket.remoteAddress);
        if (!allow.has(ip)) return json(res, 403, { ok: false, error: "not allowed" });
        const url = new URL(req.url, "http://x");
        const p = url.pathname.replace(/\/+$/, "");
        try {
            if (req.method === "GET" && p === "/api/house") return json(res, 200, house());
            if (req.method === "GET" && p === "/api/house/changes") return json(res, 200, { ok: true, changes: log.recent.slice(-20) });
            const m = req.method === "POST" && /^\/api\/house\/(cool|heat|step|mode)$/.exec(p);
            if (!m) return json(res, 404, { ok: false, error: "not found" });
            if (!String(req.headers["content-type"] ?? "").includes("application/json")) {
                return json(res, 415, { ok: false, error: "send JSON (content-type: application/json)" });
            }
            const body = await readBody(req);
            const [code, out, extra] = await serial(() => change(who(ip, tvIp), m[1], body));
            return json(res, code, out, extra);
        } catch (e) {
            return json(res, 500, { ok: false, error: String(e?.message ?? e).slice(0, 160) });
        }
    };
}

const d0 = (v) => Number(v) || 0;
