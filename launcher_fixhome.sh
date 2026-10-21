#!/usr/bin/env bash
# Google TV fix: disable the setup wizard that hijacks HOME, so the new launcher owns it.
# Run on the hub:  cd ~/Scripts/tv && bash launcher_fixhome.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then echo "TV not reachable/authorized."; exit 1; fi
echo "disabling HOME-hijacking setup wizard (com.google.android.tungsten.setupwraith)..."
$S shell pm disable-user --user 0 com.google.android.tungsten.setupwraith
$S shell cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity
echo -n "HOME now resolves to: "
$S shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n1
$S shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
echo "Done. Press HOME on the remote."
