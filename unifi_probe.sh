#!/usr/bin/env bash
# UniFi read-only probe. GET only, changes nothing. Run on the hub:
#   export UNIFI_API_KEY="$(op read 'op://<vault>/<item>/credential')"
#   cd ~/Scripts/tv && bash unifi_probe.sh
# (If 1Password CLI isn't set up, just run it and paste the key when prompted.)
set -uo pipefail
cd "$(dirname "$0")"
GW="${GW:?set GW to the gateway IP, e.g. GW=192.168.1.x}"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
TS=$(date +%Y%m%d_%H%M%S); LOG="$OUT/unifi_probe_$TS.txt"
if [ -z "${UNIFI_API_KEY:-}" ]; then read -rs -p "Paste UniFi API key (hidden): " UNIFI_API_KEY; echo; fi
log(){ echo "$@" | tee -a "$LOG"; }
hit(){ # name url [extra curl args]
  local name="$1" url="$2"; shift 2
  local code
  code=$(curl -s -o "$OUT/.body" -w '%{http_code}' --max-time 12 \
        -H "X-API-KEY: $UNIFI_API_KEY" -H "Accept: application/json" "$@" "$url" 2>/dev/null || echo "ERR")
  log ""; log "### $name  ->  HTTP $code"; log "    $url"
  if [ "$code" = "200" ]; then
    cp "$OUT/.body" "$OUT/${name}.json"
    python3 -c "import json;d=json.load(open('$OUT/.body'));print(json.dumps(d,indent=2)[:1200])" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG" || head -c 600 "$OUT/.body" | tee -a "$LOG"
  else
    head -c 400 "$OUT/.body" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
  fi
}
log "== UniFi read-only probe $TS  (GET only, no changes) =="
log ""
log "## CLOUD Site Manager API (api.ui.com)"
hit cloud_hosts "https://api.ui.com/v1/hosts"
hit cloud_sites "https://api.ui.com/v1/sites"
log ""
log "## LOCAL Network Integration API (gateway $GW)"
hit local_info  "https://$GW/proxy/network/integration/v1/info"  -k
hit local_sites "https://$GW/proxy/network/integration/v1/sites" -k
rm -f "$OUT/.body"
log ""
log "== Read it like this =="
log "  LOCAL 200  -> your key does local config (DNS / VLAN / firewall). We proceed from the hub."
log "  CLOUD 200 only -> key is cloud-scoped; generate a LOCAL key at:"
log "                    Network app > Settings > Control Plane > Integrations > Create API Key"
log "  401/403    -> wrong scope or key; check the API key's permissions."
log "Full JSON saved next to this log in: $OUT/"
