#!/usr/bin/env bash
# Undo apply.sh: restore removed apps and re-enable any that were disabled.
# Run on the hub:   cd ~/Scripts/tv && bash restore.sh
cd "$(dirname "$0")"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p out; LOG="out/restore_$(date +%Y%m%d_%H%M%S).log"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555 shell"
if ! $S true >/dev/null 2>&1; then echo "TV not reachable/authorized." | tee "$LOG"; exit 1; fi

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

echo "== RESTORE $(date) ==" | tee "$LOG"
for p in "${REMOVE[@]}"; do
  printf "  %-45s " "$p" | tee -a "$LOG"
  $S cmd package install-existing "$p" >/dev/null 2>&1
  $S pm enable "$p" >/dev/null 2>&1
  echo "restored/enabled" | tee -a "$LOG"
done
echo "Note: Tubi is third-party; if it doesn't come back, reinstall from the Play Store." | tee -a "$LOG"
echo "== DONE. Log: $LOG ==" | tee -a "$LOG"
