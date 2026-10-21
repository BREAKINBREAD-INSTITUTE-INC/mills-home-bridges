#!/usr/bin/env bash
# Open Play Store pages for free, legal live-TV / movie apps so you can install them.
# Run on the hub:  cd ~/Scripts/tv && bash free_tv.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555 shell"
APPS=(
  "Pluto TV|tv.pluto.android|250+ free live channels + on-demand"
  "Plex|com.plexapp.android|free movies/shows + live FAST channels"
  "Tubi|com.tubitv|free movies/shows + live TV"
  "Haystack News|com.haystack.android|free live local + national news"
)
echo "Opening each app's Play page on the TV. Install with the remote, then come back."
for a in "${APPS[@]}"; do
  name="${a%%|*}"; rest="${a#*|}"; pkg="${rest%%|*}"; desc="${rest#*|}"
  echo; echo ">> $name  —  $desc"
  $S am start -a android.intent.action.VIEW -d "market://details?id=$pkg" >/dev/null 2>&1 || true
  read -r -p "   Installed $name? Press Enter for the next... " _
done
echo "Done. They'll appear as tiles on your MILLS OS launcher."
