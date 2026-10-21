#!/usr/bin/env python3
"""Sony Bravia REST (Bravia API) client. Official API, PSK auth.
Writes full JSON to --out and prints short summaries."""
import argparse, json, os, sys, urllib.request, urllib.error
TIMEOUT = 6

def rpc(host, psk, service, method, params=None, version="1.0"):
    url = f"http://{host}/sony/{service}"
    body = json.dumps({"method": method, "params": params or [], "id": 1, "version": version}).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("X-Auth-PSK", psk)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "detail": e.read().decode(errors='replace')}
    except Exception as e:
        return {"error": type(e).__name__, "detail": str(e)}

def ircc(host, psk, code):
    url = f"http://{host}/sony/IRCC"
    env = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
           's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
           '<u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">'
           f'<IRCCCode>{code}</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>').encode()
    req = urllib.request.Request(url, data=env, method="POST")
    req.add_header("X-Auth-PSK", psk)
    req.add_header("Content-Type", "text/xml; charset=UTF-8")
    req.add_header("SOAPACTION", '"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"')
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return {"ok": True, "status": r.status}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "detail": e.read().decode(errors='replace')}
    except Exception as e:
        return {"error": type(e).__name__, "detail": str(e)}

def dump(outdir, name, obj):
    if outdir:
        os.makedirs(outdir, exist_ok=True)
        with open(os.path.join(outdir, f"rest_{name}.json"), "w") as f:
            json.dump(obj, f, indent=2)

def summarize(name, res):
    if isinstance(res, dict) and "error" in res:
        print(f"[{name}] ERROR {res['error']}: {res.get('detail','')[:120]}")
        return
    r = res.get("result", res) if isinstance(res, dict) else res
    if name == "apps":
        try:
            apps = r[0]
            print(f"[apps] {len(apps)} installed:")
            for a in sorted(apps, key=lambda x: x.get('title','').lower()):
                print(f"   - {a.get('title','?')}  <{a.get('uri','')}>")
        except Exception:
            print(f"[apps] {json.dumps(res)[:300]}")
    else:
        print(f"[{name}] {json.dumps(r)[:400]}")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--psk", required=True)
    p.add_argument("--out", default="")
    sub = p.add_subparsers(dest="cmd", required=True)
    for c in ("info","power-status","apps","inputs","volume","remote-codes"):
        sub.add_parser(c)
    pw = sub.add_parser("power"); pw.add_argument("state", choices=["on","off"])
    k = sub.add_parser("key"); k.add_argument("name")
    a = p.parse_args()
    H, K, O = a.host, a.psk, a.out
    if a.cmd == "info":
        res = rpc(H,K,"system","getSystemInformation"); dump(O,"info",res); summarize("info",res)
    elif a.cmd == "power-status":
        res = rpc(H,K,"system","getPowerStatus"); dump(O,"power_status",res); summarize("power-status",res)
    elif a.cmd == "power":
        res = rpc(H,K,"system","setPowerStatus",[{"status": a.state=="on"}]); summarize("power",res)
    elif a.cmd == "apps":
        res = rpc(H,K,"appControl","getApplicationList"); dump(O,"apps",res); summarize("apps",res)
    elif a.cmd == "inputs":
        res = rpc(H,K,"avContent","getCurrentExternalInputsStatus"); dump(O,"inputs",res); summarize("inputs",res)
    elif a.cmd == "volume":
        res = rpc(H,K,"audio","getVolumeInformation"); dump(O,"volume",res); summarize("volume",res)
    elif a.cmd == "remote-codes":
        res = rpc(H,K,"system","getRemoteControllerInfo"); dump(O,"remote_codes",res); summarize("remote-codes",res)
    elif a.cmd == "key":
        codes = rpc(H,K,"system","getRemoteControllerInfo"); code=None
        try:
            for e in codes["result"][1]:
                if e.get("name","").lower()==a.name.lower(): code=e["value"]; break
        except Exception: pass
        if not code: print(f"no button named {a.name}; run remote-codes"); sys.exit(1)
        summarize("key", ircc(H,K,code))

if __name__ == "__main__":
    main()
