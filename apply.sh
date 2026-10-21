#!/usr/bin/env bash
# Applies JJ's keep/remove decisions to the TV. Reversible via restore.sh.
# Run on the hub:   cd ~/Scripts/tv && bash apply.sh
cd "$(dirname "$0")"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p out; LOG="out/apply_$(date +%Y%m%d_%H%M%S).log"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555 shell"
if ! $S true >/dev/null 2>&1; then echo "TV not reachable/authorized. Accept the debug prompt and retry." | tee "$LOG"; exit 1; fi

# Remove for this user; if the package refuses, fall back to disabling it.
REMOVE=(
  tv.samba.ssm
  tv.samba.ssm.ui
  com.sony.dtv.promos
  com.sony.dtv.sonyselect
  com.sonyericsson.idd.agent
  com.google.android.play.games
  com.tubitv
  com.xumo.xumo.tv
)

echo "== APPLY $(date) ==" | tee "$LOG"
echo "--- free space BEFORE ---" | tee -a "$LOG"; $S df /data | tee -a "$LOG"

echo "--- clearing caches (safe) ---" | tee -a "$LOG"
$S pm trim-caches 999999999999 2>&1 | tee -a "$LOG" || true

echo "--- removing (reversible; disables if uninstall is blocked) ---" | tee -a "$LOG"
for p in "${REMOVE[@]}"; do
  printf "  %-45s " "$p" | tee -a "$LOG"
  out=$($S pm uninstall --user 0 "$p" 2>&1)
  if echo "$out" | grep -qi success; then
    echo "REMOVED" | tee -a "$LOG"
  else
    d=$($S pm disable-user --user 0 "$p" 2>&1)
    if echo "$d" | grep -qi "new state"; then echo "DISABLED (uninstall blocked)" | tee -a "$LOG"
    else echo "FAILED: $out / $d" | tee -a "$LOG"; fi
  fi
done

echo "--- free space AFTER ---" | tee -a "$LOG"; $S df /data | tee -a "$LOG"
echo "== DONE. Log: $LOG ==" | tee -a "$LOG"
