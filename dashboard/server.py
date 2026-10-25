#!/usr/bin/env python3
# MILLS OS TV board server. Run on hub:  python3 server.py
import json, os, subprocess, socket, threading, time, http.server, socketserver
HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8777
# Only these addresses may read the board (same rule as the Blink bridge): HUB itself and the TV.
ALLOW = {a.strip() for a in os.environ.get("DASH_ALLOW", "127.0.0.1,<tv-ip>").split(",") if a.strip()}

def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""

def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80)); return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()

TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"   # the Tailscale app; the Homebrew copy was removed Oct 22
SPARK_PORT = 8000            # each Spark's keyed model gate
_cache = {"at": 0, "peers": {}, "ports": {}}

def tailnet():
    """Tailscale's own view of each machine, read-only: online now, and whether it was ever seen."""
    peers = {}
    try:
        d = json.loads(sh(f"{TS} status --json") or "{}")
        for p in (d.get("Peer") or {}).values():
            seen = not (p.get("LastSeen") or "").startswith("0001") or bool(p.get("Online"))
            peers[(p.get("HostName") or "").lower()] = {
                "ip": (p.get("TailscaleIPs") or [""])[0], "online": bool(p.get("Online")), "seen": seen,
                "last_seen": "" if (p.get("LastSeen") or "").startswith("0001") else (p.get("LastSeen") or "")}
    except Exception:
        pass
    return peers

def port_open(ip, port):
    try:
        with socket.create_connection((ip, port), timeout=1.5): return True
    except Exception:
        return False

def health(ip):
    """The gate's /health without a key: 200 = the model serves, 502 = gate up but the model is not (starting or stuck)."""
    try:
        import urllib.request
        with urllib.request.urlopen(f"http://{ip}:{SPARK_PORT}/health", timeout=3) as r: return r.status
    except Exception as e:
        return getattr(e, "code", 0)

def disk(path):
    try:
        st = os.statvfs(path); tb = 1024 ** 4
        return round(st.f_blocks * st.f_frsize / tb, 1), round(st.f_bavail * st.f_frsize / tb, 1)
    except Exception:
        return None, None

_blink_idx = {"mtime": None, "clips": 0, "bytes": 0}

def stored(mount, s):
    """One thing kept on the NAS, read cheaply: a folder's file count, or the Blink archive's own index."""
    d = os.path.join(mount, s["dir"])
    out = {"name": s["name"], "present": os.path.isdir(d)}
    if not out["present"]: return out
    try:
        if s.get("index"):   # the bridge's index already holds every clip and its size; re-read only when it changes
            ip = os.path.join(d, s["index"]); mt = os.path.getmtime(ip)
            if mt != _blink_idx["mtime"]:
                idx = json.load(open(ip))
                _blink_idx.update(mtime=mt, clips=len(idx), bytes=sum(int(v.get("bytes") or 0) for v in idx.values()))
            out["clips"], out["bytes"] = _blink_idx["clips"], _blink_idx["bytes"]
        else:
            out["items"] = sum(1 for n in os.listdir(d) if not n.startswith("."))
        out["updated"] = int(os.path.getmtime(d))
    except Exception:
        pass
    return out

def infra(peers):
    """The Sparks and NAS for the TV: up, what they serve, how full (read-only)."""
    out = []
    try: items = json.load(open(os.path.join(HERE, "infra.json")))
    except Exception: items = []
    try: agents = json.load(open(os.path.join(HERE, "agents.json")))
    except Exception: agents = []
    for it in items:
        it = dict(it)
        if it.get("kind") == "spark":
            p = peers.get(it["machine"])
            it["online"] = bool(p and p["online"])
            it["last_seen"] = p["last_seen"] if p else ""
            it["agents"] = [a["name"] for a in agents if it["machine"] in (a.get("machine"), a.get("model"))]
            if not p or not p["seen"]: it["state"], it["why"] = "idle", "Never connected"
            elif not p["online"]: it["state"], it["why"] = "bad", "Offline on the tailnet"
            else:
                code = health(p["ip"])
                it["state"], it["why"] = (("ok", "Serving") if code == 200 else
                                          ("warn", "Gate up, model not answering") if code == 502 else
                                          ("bad", f"Model gate not answering ({code or 'no reply'})"))
        else:
            up = port_open(it["ip"], 445)
            total, free = disk(it["mount"]) if os.path.ismount(it["mount"]) else (None, None)
            it["state"] = "ok" if up and total else "warn" if up else "bad"
            it["why"] = (f"{free} TB free of {total} TB" if total else "online, not mounted on HUB") if up else "Not answering"
            if total: it["stores"] = [stored(it["mount"], s) for s in it.get("stores", [])]
            else: it.pop("stores", None)
        out.append(it)
    return out

CHECK_EVERY = 30             # the fleet is checked this often, in the background
_check_lock = threading.Lock()

def run_checks():
    """One pass over the fleet (tailnet, the Sparks' gates, NAS). Can take a few seconds."""
    peers = tailnet()
    ports = {h: port_open(peers[h]["ip"], SPARK_PORT) for h in ("core", "reactor", "dynamo")
             if h in peers and peers[h]["online"]}
    inf = infra(peers)
    with _check_lock:
        _cache.update(at=time.time(), peers=peers, ports=ports, infra=inf)

def checker():
    """Keeps the fleet reading fresh off the request path: a TV asking never waits on a slow Spark
    (its gate's /health can take 3 s, longer than the TV waits), it gets the reading at most 30 s old."""
    while True:
        try: run_checks()
        except Exception as e: print(f"checks failed: {e}", flush=True)
        time.sleep(CHECK_EVERY)

def checks():
    if not _cache["at"]:          # a request before the first background pass finished
        run_checks()
    with _check_lock:
        return _cache["peers"], _cache["ports"]

def checked(a, peers, ports):
    """JJ's colours (Oct 21): green good, orange not 100%, red down, grey never connected.
    Only what HUB can see without signing in anywhere: the machine on the tailnet and its model's port.
    Whether the agent itself is answering isn't visible yet; that waits on the heartbeat (guide 3.7d)."""
    built, mach, model = a.get("built", "no"), a.get("machine", ""), a.get("model", "")
    if built == "no":
        return "idle", "Not built yet"
    p = peers.get(mach)
    if p is None or not p["seen"]:
        return "idle", "Never connected"
    if not p["online"]:
        return "bad", f"{mach.upper()} offline"
    if model and not ports.get(model):
        return "bad", f"Model on {model.upper()} not answering"
    if built == "shadow":
        return "warn", "In shadow · no real jobs yet"
    if built == "monitor":
        return "warn", "Monitoring live · agent not built"
    return "ok", "Up · machine and model answering"

LAYOUT = os.path.join(HERE, "layout.json")   # JJ's card order, labels and notes (gitignored)
_layout_lock = threading.Lock()
MAX_LABEL, MAX_NOTE = 24, 80

def read_layout():
    try: d = json.load(open(LAYOUT))
    except Exception: d = {}
    return {"agents": d.get("agents") or [], "machines": d.get("machines") or [], "saved_at": d.get("saved_at", 0)}

def clean_layout(d):
    """What the TV's edit mode sends, kept to names, order and short text. None if it isn't that."""
    if not isinstance(d, dict): return None
    out = {}
    for group in ("agents", "machines"):
        rows = d.get(group, [])
        if not isinstance(rows, list) or len(rows) > 40: return None
        seen, keep = set(), []
        for r in rows:
            if not isinstance(r, dict) or not isinstance(r.get("name"), str): return None
            name = r["name"].strip().upper()
            if not name or len(name) > 32 or name in seen: return None
            seen.add(name)
            row = {"name": name}
            for k, n in (("label", MAX_LABEL), ("note", MAX_NOTE)):
                v = r.get(k, "")
                if not isinstance(v, str): return None
                v = " ".join(v.split())[:n]
                if v: row[k] = v            # empty = back to the default
            keep.append(row)
        out[group] = keep
    out["saved_at"] = int(time.time())
    return out

def save_layout(d):
    with _layout_lock:
        tmp = LAYOUT + ".tmp"
        with open(tmp, "w") as f: json.dump(d, f, indent=1)
        os.replace(tmp, LAYOUT)

def arranged(items, rows, note_key):
    """items in JJ's saved order (new ones keep their place at the end), with his label and note.
    The default text stays alongside (default_label / default_note) so the TV can offer Reset."""
    by = {r["name"]: r for r in rows}
    order = {r["name"]: i for i, r in enumerate(rows)}
    items = sorted(items, key=lambda it: order.get(it.get("name", "").upper(), len(order)))
    for it in items:
        r = by.get(it.get("name", "").upper(), {})
        it["default_label"], it["default_note"] = it.get("name", ""), it.get(note_key, "")
        it["label"] = r.get("label") or it.get("name", "")
        if r.get("note"): it[note_key] = r["note"]
    return items

# JJ's household bills, T1 private: read on HUB, served only to HUB and the TV, never committed.
BILLS = os.environ.get("BILLS_TSV", os.path.expanduser("~/private/household_bills.tsv"))
BUDGET_LINES = [   # label on the TV, which bill category it comes from
    ("Rent", lambda cat: cat == "rent"),
    ("Electric", lambda cat: cat.startswith("electric")),
    ("Water, trash, sewer", lambda cat: cat.startswith("water")),
    ("Internet", lambda cat: cat.startswith("internet")),
]

def budget():
    """Each bill's monthly amount, honestly: rent is fixed; the others are their latest real bill
    (one-time setup charges left out); a bill that comes every two months is halved and says so."""
    try:
        rows = [l.rstrip("\n").split("\t") for l in open(BILLS) if l.strip() and not l.startswith("#")][1:]
        mtime = int(os.path.getmtime(BILLS))
    except Exception:
        return {"ok": False, "why": "No bills file on HUB", "items": []}
    items = []
    for label, match in BUDGET_LINES:
        got = [r + [""] * (6 - len(r)) for r in rows if len(r) >= 4 and match(r[2].lower())
               and "setup" not in r[2].lower()]
        if not got: continue
        fixed = [r for r in got if r[0] == "monthly"]
        r = fixed[0] if fixed else max(got, key=lambda r: r[0])
        try: amt = float(r[3])
        except ValueError: continue
        every2 = "every 2 months" in r[5].lower()
        monthly = round(amt / 2, 2) if every2 else amt
        try: when = time.strftime("%b %-d", time.strptime(r[0], "%Y-%m-%d"))
        except ValueError: when = r[0]
        basis = ("fixed monthly" if fixed else
                 f"${amt:,.2f} every 2 months · bill of {when}" if every2 else f"latest bill · {when}")
        items.append({"label": label, "monthly": monthly, "basis": basis})
    return {"ok": True, "items": items, "total": round(sum(i["monthly"] for i in items), 2), "updated": mtime,
            "source": "bills on HUB"}

_fixed = {}                  # facts that never change while the server runs
_host = {"at": 0}            # HUB's own numbers, re-read at most every HOST_EVERY s
HOST_EVERY = 60

def uptime():
    """HUB's uptime as "3d 4h" or "20h 14m". (Parsing `uptime` missed "1 user", singular:
    the TV showed "20:14, 1 user".)"""
    import re
    m = re.search(r"sec = (\d+)", sh("sysctl -n kern.boottime"))
    if not m: return ""
    up = max(0, int(time.time()) - int(m.group(1)))
    d, h, mi = up // 86400, up % 86400 // 3600, up % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {mi}m" if h else f"{mi}m"

def host_facts():
    """Six shell calls used to run on every request (~90 ms); now the slow ones run once a minute."""
    if not _fixed:
        _fixed["ncpu"] = int(sh("sysctl -n hw.ncpu") or 1)
        memb = sh("sysctl -n hw.memsize"); _fixed["memb"] = int(memb) if memb.isdigit() else 0
        _fixed["host"] = sh("hostname -s") or "hub"
    if time.time() - _host["at"] > HOST_EVERY:
        df = sh("df -k / | tail -1").split()
        oll = sh("ollama list 2>/dev/null")
        _host.update(at=time.time(), disk_pct=df[4] if len(df) >= 5 else "?",
                     models=[l.split()[0] for l in oll.splitlines()[1:] if l.strip()],
                     up=uptime())
    return _fixed, _host

def status():
    try: la = os.getloadavg()
    except Exception: la = (0,0,0)
    fx, hs = host_facts()
    ncpu, memb, disk_pct, models, up = fx["ncpu"], fx["memb"], hs["disk_pct"], hs["models"], hs["up"]
    agents = []
    try: agents = json.load(open(os.path.join(HERE, "agents.json")))
    except Exception: pass
    peers, ports = checks()
    for a in agents:
        a["state"], a["why"] = checked(a, peers, ports)
        a["status"] = {"ok": "live", "warn": "partial", "bad": "down"}.get(a["state"], "planned")
        # A reviewed result (agents.json "review", from the latest tests) replaces the generic
        # "in shadow" line, but only while the live checks pass: a machine down still shows red.
        r = a.pop("review", None)
        if r and a["state"] in ("ok", "warn"):
            a["state"], a["why"] = r.get("state", a["state"]), r.get("why", a["why"])
            a["word"], a["detail"] = r.get("word", ""), r.get("detail", "")
            a["status"] = (r.get("word") or a["status"]).lower()
        a["host"] = a.get("machine", "").upper() or "—"
    # What serves each agent, from its own model key: the Spark in infra.json and its live check.
    # Never the dashboard host's own numbers (HUB's load and Ollama list have nothing to do with it).
    sparks = {x.get("machine"): x for x in _cache.get("infra", []) if x.get("kind") == "spark"}
    for a in agents:
        sp = sparks.get(a.get("model") or "")
        if a.get("built") == "no" or not sp:
            a["served_by"], a["served_state"], a["served_why"] = "", "idle", ""
            continue
        alt = sparks.get(a.get("standin") or "")
        a["served_by"] = f'{sp.get("model_short") or sp.get("model") or "model —"} · {sp["name"]}' + \
            (f' (stand-in {alt["name"]})' if alt else "")
        a["served_state"], a["served_why"] = sp.get("state", "idle"), f'{sp["name"]} · {sp.get("why", "not checked")}' + \
            (" · no fallback" if a.get("fallback") == "none" else "")
        a["cloud"] = "off"   # D-55: no agent calls a cloud model until the gateway exists
    lay = read_layout()
    agents = arranged(agents, lay["agents"], "note")
    infra_now = arranged([dict(x) for x in _cache.get("infra", [])], lay["machines"], "role")
    machines = []
    for h in ("friday", "forge", "scout", "grace", "sentinel", "core", "reactor", "dynamo"):
        p = peers.get(h)
        st = "idle" if not p or not p["seen"] else "bad" if not p["online"] else \
             ("ok" if ports.get(h, True) else "warn")
        machines.append({"name": h.upper(), "state": st})
    return {
        "host": fx["host"],
        "time": time.strftime("%I:%M %p"),
        "date": time.strftime("%A, %B %d"),
        "load": round(la[0], 2), "ncpu": ncpu,
        "load_pct": min(100, int(la[0] / max(ncpu,1) * 100)),
        "mem_gb": round(memb / 1073741824, 0),
        "disk_pct": disk_pct,
        "uptime": up.strip(),
        "models": models,
        "model_count": len(models),
        "agents": agents,
        "machines": machines,
        "infra": infra_now,
        "layout_saved_at": lay["saved_at"],
        "checked_at": int(_cache["at"]),
    }

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.client_address[0] not in ALLOW:
            self.send_response(403); self.end_headers(); return
        if self.path.startswith("/api/status"):
            self._send(json.dumps(status()).encode(), "application/json")
        elif self.path.startswith("/api/layout"):
            self._send(json.dumps(read_layout()).encode(), "application/json")
        elif self.path.startswith("/api/budget"):
            self._send(json.dumps(budget()).encode(), "application/json")
        else:
            name = self.path.split("?")[0].lstrip("/") or "index.html"
            if (not name.endswith(".html")) or ("/" in name): name = "index.html"
            fp = os.path.join(HERE, name)
            if not os.path.isfile(fp): fp = os.path.join(HERE, "index.html")
            try: body = open(fp, "rb").read()
            except Exception: body = b"<h1>missing</h1>"
            self._send(body, "text/html; charset=utf-8")

    def do_POST(self):
        """The one thing the TV may change here: the Mission Control layout (order, labels, notes)."""
        if self.client_address[0] not in ALLOW:
            self.send_response(403); self.end_headers(); return
        if not self.path.startswith("/api/layout"):
            self.send_response(404); self.end_headers(); return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            d = clean_layout(json.loads(self.rfile.read(n).decode())) if 0 < n <= 16384 else None
        except Exception:
            d = None
        if d is None:
            body = json.dumps({"ok": False, "why": "Not a layout"}).encode()
            self.send_response(400); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        save_layout(d)
        self._send(json.dumps({"ok": True, **d}).encode(), "application/json")

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    ip = lan_ip()
    print("=" * 48)
    print("  MILLS OS board is live.")
    print(f"  On hub:     http://localhost:{PORT}")
    print(f"  On the TV:   http://{ip}:{PORT}")
    print("  Ctrl-C to stop.")
    print("=" * 48)
    threading.Thread(target=checker, name="checks", daemon=True).start()
    Server(("0.0.0.0", PORT), H).serve_forever()
