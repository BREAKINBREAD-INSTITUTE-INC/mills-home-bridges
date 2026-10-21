#!/usr/bin/env bash
# Sideload TVBro (FOSS Android TV browser) and point it at the MILLS OS board.
# Run on the hub (keep the dashboard server running in another terminal):
#   cd ~/Scripts/tv && bash tv_install_browser.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
IP="$(ipconfig getifaddr en0 2>/dev/null || echo "${HUB_IP:?set HUB_IP}")"
PORT="${PORT:-8777}"
DASH="http://$IP:$PORT"
mkdir -p out dl; LOG="out/tvbro_$(date +%Y%m%d_%H%M%S).log"
echo "== TVBro install $(date) ==" | tee "$LOG"
echo "dashboard target: $DASH" | tee -a "$LOG"

API="https://api.github.com/repos/truefedex/tv-bro/releases/latest"
echo "resolving TVBro release (preferring the light WebView build)..." | tee -a "$LOG"
curl -fsSL "$API" > dl/rel.json
URL="$(python3 -c '
import json
d=json.load(open("dl/rel.json"))
apks=[a["browser_download_url"] for a in d.get("assets",[]) if a["name"].lower().endswith(".apk")]
pick=(next((u for u in apks if "geckoexcluded" in u.lower()),None)      # tiny, no ABI dependency
      or next((u for u in apks if "armeabi-v7a" in u.lower()),None)     # 32-bit ARM (MediaTek TVs)
      or next((u for u in apks if "arm64" in u.lower()),None)
      or (apks[0] if apks else ""))
print(pick)
')"
if [ -z "$URL" ]; then echo "Could not resolve an APK URL." | tee -a "$LOG"; exit 1; fi
echo "APK: $URL" | tee -a "$LOG"

echo "downloading..." | tee -a "$LOG"
curl -fL -o dl/tvbro.apk "$URL"
echo "downloaded $(wc -c < dl/tvbro.apk) bytes" | tee -a "$LOG"

adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then echo "TV not authorized. Accept the debug prompt and retry." | tee -a "$LOG"; exit 1; fi

echo "TV ABI: $($S shell getprop ro.product.cpu.abi) / $($S shell getprop ro.product.cpu.abilist)" | tee -a "$LOG"
echo "installing on TV..." | tee -a "$LOG"
$S install -r dl/tvbro.apk 2>&1 | tee -a "$LOG"
echo "verify:" | tee -a "$LOG"
$S shell pm list packages | grep -i phlox | tee -a "$LOG" || echo "(package not found)" | tee -a "$LOG"

echo "launching TVBro at $DASH ..." | tee -a "$LOG"
$S shell am start -a android.intent.action.VIEW -d "$DASH" -p com.phlox.tvwebbrowser 2>&1 | tee -a "$LOG"
echo "== DONE. Log: $LOG ==" | tee -a "$LOG"
