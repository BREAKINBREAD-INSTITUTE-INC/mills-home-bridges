#!/usr/bin/env bash
TV="${1:?usage: adb_inventory.sh TV_IP [outdir]}"; OUT="${2:-./out}"; mkdir -p "$OUT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v adb >/dev/null 2>&1; then
  echo "adb NOT installed. Install:  brew install android-platform-tools" | tee "$OUT/adb_status.txt"; exit 0
fi
echo "adb connect $TV:5555"; adb connect "$TV:5555" | tee "$OUT/adb_connect.txt"; sleep 2
adb devices -l | tee "$OUT/adb_devices.txt"
if ! adb -s "$TV:5555" shell true >/dev/null 2>&1; then
  echo "TV not authorized / Network debugging off. On the TV: turn on Developer options + Network debugging, accept 'Allow debugging?', then rerun." | tee "$OUT/adb_status.txt"; exit 0
fi
S="adb -s $TV:5555 shell"
{ echo "model:   $($S getprop ro.product.model)"
  echo "name:    $($S getprop ro.product.name)"
  echo "brand:   $($S getprop ro.product.brand)"
  echo "android: $($S getprop ro.build.version.release)"; } | tee "$OUT/model.txt"
$S pm list packages -3 -f 2>/dev/null | sed 's/package://' | sort > "$OUT/apps_thirdparty.txt"
$S pm list packages -s 2>/dev/null | sed 's/package://' | sort > "$OUT/apps_system.txt"
$S pm list packages -d 2>/dev/null | sed 's/package://' | sort > "$OUT/apps_disabled.txt"
$S pm list packages -e 2>/dev/null | sed 's/package://' | sort > "$OUT/apps_enabled.txt"
$S dumpsys diskstats 2>/dev/null > "$OUT/diskstats.txt"
$S df 2>/dev/null > "$OUT/storage.txt"
$S dumpsys meminfo 2>/dev/null | head -60 > "$OUT/meminfo.txt"
echo "third-party:$(wc -l < "$OUT/apps_thirdparty.txt") system:$(wc -l < "$OUT/apps_system.txt") disabled:$(wc -l < "$OUT/apps_disabled.txt")" | tee "$OUT/adb_status.txt"
echo "ADB inventory complete."
