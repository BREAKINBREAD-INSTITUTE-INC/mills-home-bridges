#!/usr/bin/env bash
# Grab a crisp screenshot straight off the TV. Run: bash tv_shot.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it, run tv_connect.sh, retry."; exit 1; }
sleep 3   # let the home settle and weather load
$S exec-out screencap -p > "$OUT/tv_shot.png" 2>/dev/null
echo "saved $OUT/tv_shot.png ($(wc -c < "$OUT/tv_shot.png") bytes)"
echo "done — Claude can read it from the mounted folder."
