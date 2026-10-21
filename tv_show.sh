#!/usr/bin/env bash
# Put the board up on the TV and keep the screen awake. Run on the hub anytime:
#   cd ~/Scripts/tv && bash tv_show.sh
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
IP="$(ipconfig getifaddr en0 2>/dev/null || echo "${HUB_IP:?set HUB_IP}")"
DASH="http://$IP:8777"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then echo "TV not reachable/authorized."; exit 1; fi
$S shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1
$S shell settings put secure screensaver_enabled 0 >/dev/null 2>&1
$S shell svc power stayon true >/dev/null 2>&1
$S shell am start -a android.intent.action.VIEW -d "$DASH" -p com.phlox.tvwebbrowser >/dev/null 2>&1
echo "Board is up on the TV ($DASH) and the screen is set to stay awake."
