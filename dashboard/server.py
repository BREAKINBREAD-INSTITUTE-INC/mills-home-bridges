#!/usr/bin/env python3
# MILLS OS TV board server. Run on the hub:  python3 server.py
import json, os, subprocess, socket, time, http.server, socketserver
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

TS = "/opt/homebrew/bin/tailscale"
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
                "ip": (p.get("TailscaleIPs") or [""])[0], "online": bool(p.get("Online")), "seen": seen}
    except Exception:
        pass
    return peers

def port_open(ip, port):
    try:
        with socket.create_connection((ip, port), timeout=1.5): return True
    except Exception:
        return False

def checks():
    """Refresh at most every 30 s so a TV polling every few seconds doesn't hammer the fleet."""
    now = time.time()
    if now - _cache["at"] > 30:
        peers = tailnet()
        ports = {h: port_open(peers[h]["ip"], SPARK_PORT) for h in ("core", "reactor", "dynamo")
                 if h in peers and peers[h]["online"]}
        _cache.update(at=now, peers=peers, ports=ports)
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

def status():
    try: la = os.getloadavg()
    except Exception: la = (0,0,0)
    ncpu = int(sh("sysctl -n hw.ncpu") or 1)
    memb = sh("sysctl -n hw.memsize"); memb = int(memb) if memb.isdigit() else 0
    df = sh("df -k / | tail -1").split()
    disk_pct = df[4] if len(df) >= 5 else "?"
    oll = sh("ollama list 2>/dev/null")
    models = [l.split()[0] for l in oll.splitlines()[1:] if l.strip()]
    up = sh("uptime | sed 's/.*up //; s/,[^,]*users.*//; s/,  *load.*//'")
    agents = []
    try: agents = json.load(open(os.path.join(HERE, "agents.json")))
    except Exception: pass
    peers, ports = checks()
    for a in agents:
        a["state"], a["why"] = checked(a, peers, ports)
        a["status"] = {"ok": "live", "warn": "partial", "bad": "down"}.get(a["state"], "planned")
        a["host"] = a.get("machine", "").upper() or "—"
    machines = []
    for h in ("friday", "forge", "scout", "grace", "sentinel", "core", "reactor", "dynamo"):
        p = peers.get(h)
        st = "idle" if not p or not p["seen"] else "bad" if not p["online"] else \
             ("ok" if ports.get(h, True) else "warn")
        machines.append({"name": h.upper(), "state": st})
    return {
        "host": sh("hostname -s") or "hub",
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
        "checked_at": int(_cache["at"]),
    }

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.client_address[0] not in ALLOW:
            self.send_response(403); self.end_headers(); return
        if self.path.startswith("/api/status"):
            self._send(json.dumps(status()).encode(), "application/json")
        else:
            name = self.path.split("?")[0].lstrip("/") or "index.html"
            if (not name.endswith(".html")) or ("/" in name): name = "index.html"
            fp = os.path.join(HERE, name)
            if not os.path.isfile(fp): fp = os.path.join(HERE, "index.html")
            try: body = open(fp, "rb").read()
            except Exception: body = b"<h1>missing</h1>"
            self._send(body, "text/html; charset=utf-8")

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    ip = lan_ip()
    print("=" * 48)
    print("  MILLS OS board is live.")
    print(f"  On hub:     http://localhost:{PORT}")
    print(f"  On the TV:   http://{ip}:{PORT}")
    print("  Ctrl-C to stop.")
    print("=" * 48)
    Server(("0.0.0.0", PORT), H).serve_forever()
