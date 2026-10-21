#!/usr/bin/env bash
# Round 2 debloat for JJ's BRAVIA. Reversible (pm disable-user). Run on the hub:
#   cd ~/Scripts/tv && bash debloat2.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"

adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
if ! $S shell true >/dev/null 2>&1; then echo "TV not reachable. Wake it, then: bash tv_connect.sh (accept the Allow box), then rerun."; exit 1; fi

# friendly name | package
NAMED="
Music|com.sony.dtv.osat.music
MediaPlayer|com.sony.dtv.smartmediaapp
Timers_Clock|com.sony.dtv.timers
LivingDecor|com.sony.dtv.livingfit
"
LEFTOVERS="
SambaTV_ACR|tv.samba.ssm
SambaTV_UI|tv.samba.ssm.ui
SonyPromos|com.sony.dtv.promos
SonySelect|com.sony.dtv.sonyselect
SonyIDDlogging|com.sonyericsson.idd.agent
GooglePlayGames|com.google.android.play.games
"

disable_one() {
  local name="$1" pkg="$2"
  # exists?
  if ! $S shell pm list packages </dev/null | tr -d '\r' | grep -q "package:$pkg$"; then
    printf "  %-18s %-36s  not installed, skipped\n" "$name" "$pkg"; return
  fi
  # was it a home tile?
  local tile="no"
  if $S shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER "$pkg" </dev/null 2>/dev/null | tr -d '\r' | grep -q "$pkg/"; then tile="HOME TILE"; fi
  $S shell pm disable-user --user 0 "$pkg" </dev/null >/dev/null 2>&1
  local state
  state=$($S shell pm list packages -d </dev/null | tr -d '\r' | grep -q "package:$pkg$" && echo "disabled" || echo "STILL ON")
  printf "  %-18s %-36s  %-10s -> %s\n" "$name" "$pkg" "$tile" "$state"
}

echo "== storage before =="; $S shell df /data | tr -d '\r' | awk 'NR==2{print "  /data used: "$5"  ("$3"/"$2")"}'

echo; echo "== apps you named =="
echo "$NAMED" | while IFS='|' read -r n p; do [ -n "$p" ] && disable_one "$n" "$p"; done

echo; echo "== leftovers that came back on =="
echo "$LEFTOVERS" | while IFS='|' read -r n p; do [ -n "$p" ] && disable_one "$n" "$p"; done

echo; echo "== storage after =="; $S shell df /data | tr -d '\r' | awk 'NR==2{print "  /data used: "$5"  ("$3"/"$2")"}'

# refresh inventory snapshots
$S shell pm list packages -e | sed 's/package://' | tr -d '\r' | sort > "$OUT/apps_enabled.txt"
$S shell pm list packages -d | sed 's/package://' | tr -d '\r' | sort > "$OUT/apps_disabled.txt"
echo; echo "== done. To undo any one:  adb -s $TV:5555 shell pm enable <package> =="
