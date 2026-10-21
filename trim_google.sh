#!/usr/bin/env bash
# MILLS OS · trim generic Google background apps (phone-home + recommendations).
# Reversible: uses pm disable-user, nothing is uninstalled.
#   Disable:  bash trim_google.sh
#   Restore:  bash trim_google.sh restore
# Only touches generic Google packages that apply to a Sony BRAVIA. Skips anything
# not present. Does NOT touch systemui, gms, or framework.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable."; exit 1; }

# why each: all reversible, all background/clutter, none required to run the TV.
PKGS=(
  com.google.android.tvrecommendations            # recommendation engine (phone-home)
  com.google.android.leanbacklauncher.recommendations
  com.google.android.backdrop                      # AOSP ambient/screensaver host
  com.google.android.play.games                    # Play Games background svc
  com.google.android.feedback                      # usage/feedback reporter
  com.google.android.partnersetup                  # partner/telemetry setup
  com.android.egg                                  # android easter egg
)

MODE="${1:-disable}"
if [ "$MODE" = "restore" ]; then VERB="enable"; CMD="enable"; else VERB="disable"; CMD="disable-user --user 0"; fi
echo "== trim_google: $VERB =="
for p in "${PKGS[@]}"; do
  if $S shell pm list packages </dev/null 2>/dev/null | grep -q "package:$p$"; then
    out=$($S shell pm $CMD "$p" </dev/null 2>&1 | tr -d '\r')
    echo "  $p -> $out"
  else
    echo "  $p -> not present, skipped"
  fi
done
echo "Done. Reboot not required. Undo: bash trim_google.sh restore"
