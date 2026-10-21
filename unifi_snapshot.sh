#!/usr/bin/env bash
# UniFi read-only SNAPSHOT (GET only, changes nothing). Uses the LOCAL key.
# Run on the hub:  cd ~/Scripts/tv && bash unifi_snapshot.sh   (paste local key when asked)
set -uo pipefail
cd "$(dirname "$0")"
GW="${GW:?set GW to the gateway IP, e.g. GW=192.168.1.x}"
BASE="https://$GW/proxy/network/integration/v1"
if [ -z "${UNIFI_API_KEY:-}" ]; then read -rs -p "Paste LOCAL UniFi API key (hidden): " UNIFI_API_KEY; echo; fi
AUTH=(-H "X-API-KEY: $UNIFI_API_KEY" -H "Accept: application/json")
TS=$(date +%Y%m%d_%H%M%S)
DIR="$HOME/Scripts/tv/out/unifi_snapshot_$TS"; mkdir -p "$DIR"
IDX="$DIR/INDEX.txt"
curl -sk "${AUTH[@]}" "$BASE/sites?limit=200" -o "$DIR/sites.json"
SID=$(python3 -c "import json;print(json.load(open('$DIR/sites.json'))['data'][0]['id'])" 2>/dev/null || echo "")
echo "snapshot $TS   site id: $SID" | tee "$IDX"
[ -z "$SID" ] && { echo "Could not read site id (key wrong?). Aborting."; exit 1; }
get(){ local name="$1" path="$2" code
  code=$(curl -sk -o "$DIR/$name.json" -w '%{http_code}' --max-time 15 "${AUTH[@]}" "$BASE/$path")
  printf '%-26s %s  %s\n' "$name" "$code" "$path" | tee -a "$IDX"
}
S="sites/$SID"
get info "info"
get devices "$S/devices?limit=200"
get clients "$S/clients?limit=200"
get networks "$S/networks?limit=200"
get wifi_broadcasts "$S/wifi/broadcasts?limit=200"
get firewall_zones "$S/firewall/zones?limit=200"
get firewall_policies "$S/firewall/policies?limit=200"
get firewall_acl_rules "$S/firewall/acl-rules?limit=200"
get traffic_matching_lists "$S/traffic-matching-lists?limit=200"
get dns_policies "$S/dns/policies?limit=200"
get vpn_servers "$S/vpn/servers?limit=200"
get vpn_s2s "$S/vpn/site-to-site-tunnels?limit=200"
get wans "$S/wans?limit=200"
get device_tags "$S/device-tags?limit=200"
get radius_profiles "$S/radius/profiles?limit=200"
get dpi_applications "dpi/applications?limit=50"
python3 - "$DIR" <<'PY' | tee "$DIR/SUMMARY.txt"
import json,os,glob,sys
d=sys.argv[1]
print("== UniFi snapshot summary (read-only) ==")
for f in sorted(glob.glob(os.path.join(d,"*.json"))):
    n=os.path.basename(f)[:-5]
    if n in ("INDEX","SUMMARY"): continue
    try: j=json.load(open(f))
    except Exception: print(f"{n:26} (non-json)"); continue
    if isinstance(j,dict) and isinstance(j.get("data"),list): print(f"{n:26} {len(j['data'])} item(s)")
    elif isinstance(j,dict) and j.get("error"): print(f"{n:26} ERROR {j['error'].get('code')}")
    else: print(f"{n:26} ok")
PY
echo ""; echo "Snapshot folder: $DIR"
