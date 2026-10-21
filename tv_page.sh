#!/usr/bin/env bash
# tv_page.sh v1.1 (Oct 19 2026; v1.1 knows both looks). Pick a MILLS OS TV page from HUB, or turn auto on or off.
#   bash tv_page.sh list            show the pages
#   bash tv_page.sh activity        go to Activity and stay there (auto off)
#   bash tv_page.sh auto            loop the pages on their own
#   bash tv_page.sh off             stay on the page that's showing
#   bash tv_page.sh 3               page 3, auto off
# Run from ~/Scripts/tv. Uses the same TV and hub address as show_dashboard.sh.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; IP="$(ipconfig getifaddr en0 2>/dev/null || echo "${HUB_IP:?set HUB_IP}")"
LOOK="$(cat dashboard/look.txt 2>/dev/null || echo roomy)"
if [ "$LOOK" = dense ]; then
  PAGES=(glance activity leads fix safety machines models log)
  NAMES=("Glance" "Activity" "Leads" "FORGE fix" "Safety" "Machines" "Models" "Log")
else
  PAGES=(glance waiting activity leads next fix safety machines models log)
  NAMES=("Glance" "Waiting" "Activity" "Leads" "Coming up" "FORGE fix" "Safety" "Machines" "Models" "Log")
fi
a="${1:-list}"
case "$a" in
  list|-h|--help)
    echo "Look: $LOOK"; for i in "${!PAGES[@]}"; do echo "  $((i+1))  ${PAGES[$i]}  (${NAMES[$i]})"; done
    echo "  auto · off"; exit 0 ;;
  auto) Q="auto=on" ;;
  off)  Q="auto=off" ;;
  [1-9]|10) [ "$a" -le "${#PAGES[@]}" ] || { echo "No page $a in the $LOOK look"; exit 1; }; Q="page=${PAGES[$((a-1))]}&auto=off" ;;
  *) ok=0; for p in "${PAGES[@]}"; do [ "$p" = "$a" ] && ok=1; done
     [ "$ok" = 1 ] || { echo "Unknown page: $a"; bash "$0" list; exit 1; }
     Q="page=$a&auto=off" ;;
esac
URL="http://$IP:8777/missioncontrol.html?$Q&t=$(date +%s)"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
if ! adb -s "$TV:5555" shell true >/dev/null 2>&1; then echo "TV not reachable or not authorized."; exit 1; fi
# Use the MILLS OS TV app when it's installed (no pointer, the remote's arrows work). Else TVBro.
if adb -s "$TV:5555" shell pm path com.millsos.tv 2>/dev/null | grep -q package:; then
  adb -s "$TV:5555" shell am start -a android.intent.action.VIEW -d "'$URL'" -n com.millsos.tv/.MainActivity >/dev/null 2>&1
else
  adb -s "$TV:5555" shell am start -a android.intent.action.VIEW -d "'$URL'" -p com.phlox.tvwebbrowser >/dev/null 2>&1
fi
echo "TV: $Q"
