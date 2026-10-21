#!/usr/bin/env bash
# Show the Mission Control dashboard on the TV. Run on the hub:  cd ~/Scripts/tv && bash show_dashboard.sh
cd "$(dirname "$0")/dashboard"
# If tv.html or a board changed since the last build, rebuild first (Oct 19: a new tv.html never reached the TV).
if [ tv.html -nt missioncontrol.html ] || [ -n "$(find boards -newer missioncontrol.html -name '*.dc.html' 2>/dev/null)" ]; then bash build_tv.sh >/dev/null || { echo "FAIL: build_tv.sh failed. TV unchanged."; exit 1; }; fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; IP="$(ipconfig getifaddr en0 2>/dev/null || echo "${HUB_IP:?set HUB_IP}")"
pkill -f "python3 server.py" 2>/dev/null; sleep 1
nohup python3 server.py >/tmp/millsboard.log 2>&1 &
sleep 2
URL="http://$IP:8777/missioncontrol.html?t=$(date +%s)"   # new address each time, so the TV never shows an old copy
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
# Use the MILLS OS TV app when it's installed (no pointer, the remote's arrows work). Else TVBro.
if adb -s "$TV:5555" shell pm path com.millsos.tv 2>/dev/null | grep -q package:; then
  adb -s "$TV:5555" shell am start -a android.intent.action.VIEW -d "'$URL'" -n com.millsos.tv/.MainActivity >/dev/null 2>&1
else
  adb -s "$TV:5555" shell am start -a android.intent.action.VIEW -d "'$URL'" -p com.phlox.tvwebbrowser >/dev/null 2>&1
fi
echo "Mission Control is up on the TV:  $URL"
echo "Your MILLS OS board is still at:  http://$IP:8777/"
