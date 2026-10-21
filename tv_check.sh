#!/usr/bin/env bash
# Report the TV's real display metrics and grab a screenshot. Run: bash tv_check.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it and retry."; exit 1; }
echo "=== wm size ===";     $S shell wm size
echo "=== wm density ===";  $S shell wm density
echo "=== display real ==="; $S shell dumpsys display | grep -iE 'mBaseDisplayInfo|real [0-9]|density' | head -6
$S exec-out screencap -p > "$OUT/tv_shot.png" 2>/dev/null
echo "=== shot saved: $OUT/tv_shot.png ($(wc -c < "$OUT/tv_shot.png") bytes) ==="
