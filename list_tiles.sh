#!/usr/bin/env bash
# List every app that shows as a home-screen tile, clean package names. Run: bash list_tiles.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it, run tv_connect.sh, retry."; exit 1; }
echo "== apps that show as home tiles =="
$S shell cmd package query-activities --brief \
  -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER </dev/null \
  | tr -d '\r' \
  | grep -oE '[a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_.]+/[A-Za-z0-9_.$]+' \
  | cut -d/ -f1 | sort -u
echo "== paste all of the above back to Claude =="
