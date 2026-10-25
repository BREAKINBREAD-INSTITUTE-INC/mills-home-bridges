// node --test test/   (no Nest needed: a fake thermostat stands in)
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { c2f, f2c, limits, clamp, supportedModes, parseMode, checkPair, parseAllow, normIp, who, RateLimit, ChangeLog } from "../control.mjs";
import { createHandler } from "../api.mjs";

// what this Nest really reports (bridge.mjs status, Oct 23)
const NEST = {
    features: { heating: true, cooling: true, autoMode: true, presets: false },
    controlSequence: 4, absMinHeat: 1000, absMaxHeat: 3222, absMinCool: 1000, absMaxCool: 3222, deadBand: 0,
    exposes: { runningState: false, presets: false, fan: false },
};

test("°F <-> 0.01 °C round-trips for every safe setpoint", () => {
    for (let f = 50; f <= 90; f++) assert.equal(c2f(f2c(f)), f);
    assert.equal(c2f(2389), 75);
    assert.equal(c2f(2277), 73);
});

test("clamps to 68-82 inside the device's own limits", () => {
    const w = limits(NEST);
    assert.deepEqual(w.cool, { minF: 68, maxF: 82 });
    assert.deepEqual(w.heat, { minF: 68, maxF: 82 });
    assert.equal(clamp(60, w.cool), 68);
    assert.equal(clamp(95, w.cool), 82);
    assert.equal(clamp(76.4, w.cool), 76);
    assert.equal(clamp("x", w.cool), null);
    // a device with tighter limits wins
    const tight = limits({ ...NEST, absMaxCool: f2c(80) });
    assert.equal(clamp(82, tight.cool), 80);
});

test("modes come from the features and control sequence", () => {
    assert.deepEqual(supportedModes(NEST.features, 4), ["Off", "Heat", "Cool", "Auto"]);
    assert.deepEqual(supportedModes(NEST.features, 0), ["Off", "Cool"]);
    assert.deepEqual(supportedModes({ heating: true }, 2), ["Off", "Heat"]);
    assert.deepEqual(parseMode("heat · cool"), { key: "Auto", value: 1 });
    assert.equal(parseMode("Eco"), null);
});

test("heat stays below cool; 3° apart in Auto", () => {
    const w = limits(NEST);
    assert.equal(checkPair(73, 75, "Cool", w), null);
    assert.match(checkPair(76, 75, "Cool", w), /can't be above/);
    assert.match(checkPair(73, 75, "Auto", w), /3° apart/);
    assert.equal(checkPair(72, 75, "Auto", w), null);
});

test("allowlist and caller names", () => {
    const a = parseAllow("127.0.0.1, <tv-ip>");
    assert.ok(a.has(normIp("::ffff:<tv-ip>")));
    assert.ok(a.has(normIp("::1")));
    assert.ok(!a.has(normIp("192.168.1.x")));
    assert.equal(who("::ffff:<tv-ip>", "<tv-ip>"), "TV");
    assert.equal(who("127.0.0.1", "<tv-ip>"), "local");
});

test("rate limit: one per 3 s, 30 per hour", () => {
    let t = 0;
    const r = new RateLimit({ now: () => t });
    assert.equal(r.check(), null); r.take();
    t = 2000; assert.match(r.check().error, /3 seconds/);
    t = 3000; assert.equal(r.check(), null);
    for (let i = 1; i < 30; i++) { t = i * 3000; assert.equal(r.check(), null, `change ${i}`); r.take(); }
    t = 30 * 3000; assert.match(r.check().error, /30 changes an hour/);
    t = 3600_000 + 1; assert.equal(r.check(), null);
});

// ---- the HTTP side against a fake Nest -----------------------------------------------------------

function fakeNest({ stuck = false } = {}) {
    const s = { heat: 2277, cool: 2389, mode: 3, writes: [] };
    return {
        s,
        snapshot: () => ({ ok: true, at: Date.now(), paired: true, name: "Fake Nest", indoorF: 75, heatF: c2f(s.heat), coolF: c2f(s.cool), humidity: null, mode: "Cool", running: "idle", error: null }),
        modeValue: () => s.mode,
        info: () => NEST,
        readFresh: async () => ({ heatF: c2f(s.heat), coolF: c2f(s.cool), mode: s.mode }),
        write: async (what, v) => { s.writes.push([what, v]); if (!stuck) s[what] = v; },
    };
}

async function serve(opts) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nest-test-"));
    let t = 1_000_000;
    const rate = new RateLimit({ now: () => t });
    const log = new ChangeLog(path.join(dir, "changes.jsonl"));
    const srv = http.createServer(createHandler({ rate, log, tvIp: "<tv-ip>", readbackTries: 2, readbackGapMs: 1, ...opts }));
    await new Promise((r) => srv.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${srv.address().port}`;
    const call = async (method, p, body) => {
        const r = await fetch(base + p, { method, headers: body ? { "content-type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
        return { status: r.status, body: await r.json() };
    };
    return { call, log, dir, advance: (ms) => { t += ms; }, close: () => srv.close() };
}

test("a caller that isn't allowed gets 403 on GET and POST, and nothing is written", async () => {
    const dev = fakeNest();
    const s = await serve({ device: dev, allow: parseAllow("<tv-ip>") });   // 127.0.0.1 left out on purpose
    assert.equal((await s.call("GET", "/api/house")).status, 403);
    assert.equal((await s.call("POST", "/api/house/cool", { f: 76 })).status, 403);
    assert.equal(dev.s.writes.length, 0);
    s.close();
});

test("GET keeps every v1 field and adds limits, modes, last change", async () => {
    const s = await serve({ device: fakeNest(), allow: parseAllow("127.0.0.1") });
    const { status, body } = await s.call("GET", "/api/house");
    assert.equal(status, 200);
    for (const k of ["ok", "at", "paired", "name", "indoorF", "heatF", "coolF", "humidity", "mode", "running", "error", "ageSec"]) assert.ok(k in body, k);
    assert.deepEqual(body.modes, ["Off", "Heat", "Cool", "Auto"]);
    assert.equal(body.limits.minF, 68); assert.equal(body.limits.maxF, 82);
    assert.equal(body.modeKey, "Cool");
    assert.equal(body.runningExposed, false);
    assert.equal(body.fan, null); assert.equal(body.presets, null);
    s.close();
});

test("set cool: clamped, read back, logged; rate-limited; step; mismatch is an error", async () => {
    const dev = fakeNest();
    const s = await serve({ device: dev, allow: parseAllow("127.0.0.1") });
    let r = await s.call("POST", "/api/house/cool", { f: 99 });
    assert.equal(r.status, 200); assert.equal(r.body.confirmed.coolF, 82); assert.equal(r.body.clamped, true);
    assert.equal(dev.s.cool, f2c(82));

    r = await s.call("POST", "/api/house/cool", { f: 80 });
    assert.equal(r.status, 429);                                   // within 3 s
    s.advance(3000);
    r = await s.call("POST", "/api/house/step", { delta: -1 });     // Cool mode: steps the cooling setpoint
    assert.equal(r.status, 200); assert.equal(r.body.confirmed.coolF, 81);
    s.advance(3000);
    r = await s.call("POST", "/api/house/cool", { f: 72 });         // below heat 73: refused, not written
    assert.equal(r.status, 409);
    r = await s.call("POST", "/api/house/mode", { mode: "Eco" });
    assert.equal(r.status, 400);
    r = await s.call("POST", "/api/house/cool", { f: 81 });         // already there: no write
    assert.equal(r.body.unchanged, true);
    assert.equal(dev.s.writes.length, 2);

    const lines = fs.readFileSync(path.join(s.dir, "changes.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.equal(lines.length, 2);
    assert.deepEqual(Object.keys(lines[0]).sort(), ["at", "new", "old", "requested", "result", "what", "who"]);
    assert.equal(lines[0].who, "local"); assert.equal(lines[0].old, 75); assert.equal(lines[0].new, 82); assert.equal(lines[0].result, "ok");
    assert.equal((await s.call("GET", "/api/house")).body.lastChange.new, 81);
    s.close();

    const stuck = await serve({ device: fakeNest({ stuck: true }), allow: parseAllow("127.0.0.1") });
    r = await stuck.call("POST", "/api/house/cool", { f: 76 });
    assert.equal(r.status, 502); assert.match(r.body.error, /read-back says 75°F, asked 76°F/);
    assert.match(stuck.log.recent[0].result, /read-back/);
    stuck.close();
});

test("POST without JSON content-type is refused (no form-post from a browser)", async () => {
    const dev = fakeNest();
    const s = await serve({ device: dev, allow: parseAllow("127.0.0.1") });
    const r = await s.call("POST", "/api/house/cool");
    assert.equal(r.status, 415);
    assert.equal(dev.s.writes.length, 0);
    s.close();
});
