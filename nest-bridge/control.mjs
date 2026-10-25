// MILLS TV · Nest bridge: the rules for changing the thermostat, kept apart from Matter so they
// can be tested without the real Nest (test/control.test.mjs).
//
// Every write goes through here: who may ask (allowlist), how far (68-82°F clamp, heat/cool gap),
// how often (one change per 3 s, 30 per hour), and what was done (the change log). The Matter side
// only reads and writes raw values; it never decides anything.

import fs from "node:fs";

// ---- units ------------------------------------------------------------------------------------
// Matter carries temperatures as hundredths of °C (2389 = 23.89 °C = 75 °F).
export const c2f = (v) => (v === null || v === undefined ? null : Math.round((v / 100) * 9 / 5 + 32));
export const f2c = (f) => Math.round(((f - 32) * 5 / 9) * 100);

// ---- safety limits (in code, not config: JJ's rule) --------------------------------------------
export const SAFE_MIN_F = 68;
export const SAFE_MAX_F = 82;
// The Nest reports MinSetpointDeadBand = 0 over Matter, but its own app keeps heat and cool at least
// 3 °F apart in Heat·Cool. The bridge keeps whichever is larger, so it never asks for a pair the
// Nest's own rules would refuse.
export const NEST_GAP_F = 3;

/** The window a setpoint may be set to: JJ's 68-82 inside the device's own absolute limits. */
export function limits(dev = {}) {
    const lo = (v) => (v === null || v === undefined ? SAFE_MIN_F : Math.max(SAFE_MIN_F, Math.ceil((v / 100) * 9 / 5 + 32)));
    const hi = (v) => (v === null || v === undefined ? SAFE_MAX_F : Math.min(SAFE_MAX_F, Math.floor((v / 100) * 9 / 5 + 32)));
    // MinSetpointDeadBand is in tenths of °C (Matter 1.3+); 0 on this Nest.
    const deadF = dev.deadBand ? Math.ceil(dev.deadBand / 10 * 9 / 5) : 0;
    return {
        minF: SAFE_MIN_F, maxF: SAFE_MAX_F,
        heat: { minF: lo(dev.absMinHeat), maxF: hi(dev.absMaxHeat) },
        cool: { minF: lo(dev.absMinCool), maxF: hi(dev.absMaxCool) },
        device: {
            heatMinF: c2f(dev.absMinHeat), heatMaxF: c2f(dev.absMaxHeat),
            coolMinF: c2f(dev.absMinCool), coolMaxF: c2f(dev.absMaxCool),
            deadBandF: deadF,
        },
        gapF: Math.max(deadF, NEST_GAP_F),
        deadBandF: deadF,
    };
}

export function clamp(f, win) {
    const n = Math.round(Number(f));
    if (!Number.isFinite(n)) return null;
    return Math.min(win.maxF, Math.max(win.minF, n));
}

// ---- modes ------------------------------------------------------------------------------------
// SystemMode values (Matter Thermostat cluster). Labels are what GET /api/house has always said.
export const MODE_LABEL = { 0: "Off", 1: "Heat · Cool", 3: "Cool", 4: "Heat", 5: "Emergency heat", 6: "Precooling", 7: "Fan only", 8: "Dry", 9: "Sleep" };
export const MODE_KEY = { 0: "Off", 1: "Auto", 3: "Cool", 4: "Heat" };
const KEY_VALUE = { off: 0, auto: 1, "heat · cool": 1, "heat-cool": 1, heatcool: 1, cool: 3, heat: 4 };

/**
 * The modes this device accepts, from what it reports: Heating/Cooling/AutoMode feature bits and
 * ControlSequenceOfOperation (0/1 cooling only, 2/3 heating only, 4/5 both). Off is always valid.
 */
export function supportedModes(features = {}, controlSequence = null) {
    const cs = controlSequence;
    const canCool = !!features.cooling && (cs === null || [0, 1, 4, 5].includes(cs));
    const canHeat = !!features.heating && (cs === null || [2, 3, 4, 5].includes(cs));
    const out = ["Off"];
    if (canHeat) out.push("Heat");
    if (canCool) out.push("Cool");
    if (features.autoMode && canHeat && canCool) out.push("Auto");
    return out;
}

/** "Cool" / "auto" / "Heat · Cool" -> { key: "Cool", value: 3 } or null. */
export function parseMode(text) {
    const v = KEY_VALUE[String(text ?? "").trim().toLowerCase()];
    return v === undefined ? null : { key: MODE_KEY[v], value: v };
}

// ---- deadband ---------------------------------------------------------------------------------
/**
 * May the setpoint pair become (heatF, coolF)? Heat must sit below cool by the device's deadband
 * always (the Nest would otherwise quietly move the other setpoint), and by the 3 °F Nest gap when
 * both are in use (Auto). Returns null when fine, else the reason.
 */
export function checkPair(heatF, coolF, modeKey, win) {
    if (heatF === null || coolF === null) return null;
    const need = modeKey === "Auto" ? win.gapF : win.deadBandF;
    if (coolF - heatF < need) {
        return need > 0
            ? `heat ${heatF}° and cool ${coolF}° must stay ${need}° apart`
            : `heat ${heatF}° can't be above cool ${coolF}°`;
    }
    return null;
}

// ---- who may ask --------------------------------------------------------------------------------
export function normIp(ip) {
    let s = String(ip ?? "");
    if (s.startsWith("::ffff:")) s = s.slice(7);
    if (s === "::1") s = "127.0.0.1";
    return s;
}

export function parseAllow(text) {
    return new Set(String(text ?? "").split(",").map((a) => normIp(a.trim())).filter(Boolean));
}

/** "TV", "local" (HUB itself), or the address. */
export function who(ip, tvIp) {
    const s = normIp(ip);
    if (s === "127.0.0.1") return "local";
    if (s === normIp(tvIp)) return "TV";
    return s;
}

// ---- how often ----------------------------------------------------------------------------------
export class RateLimit {
    constructor({ minGapMs = 3000, perHour = 30, now = () => Date.now() } = {}) {
        Object.assign(this, { minGapMs, perHour, now, stamps: [] });
    }
    /** null if a change may go now, else { error, retryAfterSec }. Does not consume. */
    check() {
        const t = this.now();
        this.stamps = this.stamps.filter((s) => t - s < 3600_000);
        const last = this.stamps[this.stamps.length - 1];
        if (last !== undefined && t - last < this.minGapMs) {
            return { error: "one change every 3 seconds", retryAfterSec: Math.ceil((this.minGapMs - (t - last)) / 1000) };
        }
        if (this.stamps.length >= this.perHour) {
            return { error: `at most ${this.perHour} changes an hour`, retryAfterSec: Math.ceil((3600_000 - (t - this.stamps[0])) / 1000) };
        }
        return null;
    }
    take() { this.stamps.push(this.now()); }
}

// ---- what was done ----------------------------------------------------------------------------
/**
 * Append-only JSON-lines log of every change attempt that reached the thermostat. Only these
 * fields are ever written, so nothing secret (pairing codes, fabric keys) can end up in it.
 */
export class ChangeLog {
    constructor(file) { this.file = file; this.last = null; this.recent = []; this.load(); }
    load() {
        try {
            const lines = fs.readFileSync(this.file, "utf8").trim().split("\n").filter(Boolean).slice(-50);
            this.recent = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
            this.last = this.recent.findLast?.((e) => e.result === "ok") ?? null;
        } catch { this.recent = []; }
    }
    add({ who, what, old, requested, value, result }) {
        const e = { at: new Date().toISOString(), who: String(who), what: String(what), old: old ?? null, requested: requested ?? null, new: value ?? null, result: String(result).slice(0, 160) };
        try { fs.appendFileSync(this.file, JSON.stringify(e) + "\n"); } catch { /* the change still happened; GET shows it */ }
        this.recent.push(e);
        if (this.recent.length > 50) this.recent.shift();
        if (e.result === "ok") this.last = e;
        return e;
    }
}
