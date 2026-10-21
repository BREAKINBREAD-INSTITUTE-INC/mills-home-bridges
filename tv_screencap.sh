#!/usr/bin/env bash
# Capture whatever is on the TV right now to a PNG you can send to Claude.
#   bash tv_screencap.sh home     (or mission, house, network, system)
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
NAME="${1:-screen}"
F="$OUT/${NAME}_$(date +%H%M%S).png"
adb -s "$TV:5555" exec-out screencap -p > "$F"
SZ=$(wc -c < "$F" 2>/dev/null || echo 0)
if [ "$SZ" -lt 5000 ]; then echo "capture failed (TV asleep or adb dropped). Wake the TV and retry."; exit 1; fi
echo "saved: $F  ($SZ bytes)"
open "$OUT" 2>/dev/null || true
