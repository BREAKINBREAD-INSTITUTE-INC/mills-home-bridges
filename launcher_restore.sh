#!/usr/bin/env bash
# Put Sony's stock home screen back. Run on the hub:  cd ~/Scripts/tv && bash launcher_restore.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
OUT="$HOME/Scripts/tv/out"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
STOCK="$(cat "$OUT/stock_launcher.txt" 2>/dev/null || echo com.google.android.apps.tv.launcherx)"
echo "re-enabling setup wizard (needed before any factory reset)..."
$S shell pm enable com.google.android.tungsten.setupwraith 2>/dev/null || true
echo "re-enabling stock launcher: $STOCK"
$S shell pm enable "$STOCK"
echo "disabling our launcher so stock owns HOME again..."
$S shell pm disable-user --user 0 com.gathin.tvhome 2>/dev/null || true
$S shell cmd package set-home-activity --user 0 "$STOCK/.MainActivity" 2>/dev/null || true
echo "Done. Press HOME. Stock home is back."
echo "To remove our launcher entirely:  adb -s $TV:5555 uninstall com.gathin.tvhome"
