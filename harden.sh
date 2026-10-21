#!/usr/bin/env bash
# MILLS OS TV privacy hardening (inspired by dumbtv, mapped to Sony BRAVIA).
# Reversible. Run on the hub:  cd ~/Scripts/tv && bash harden.sh
#   Add OTA-blocking too:   HARDEN_OTA=1 bash harden.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it, run tv_connect.sh, retry."; exit 1; }

disable_one() {
  local name="$1" pkg="$2"
  $S shell pm list packages </dev/null | tr -d '\r' | grep -q "package:$pkg$" || { printf "  %-26s %-36s not installed\n" "$name" "$pkg"; return; }
  $S shell pm disable-user --user 0 "$pkg" </dev/null >/dev/null 2>&1
  local st; st=$($S shell pm list packages -d </dev/null | tr -d '\r' | grep -q "package:$pkg$" && echo disabled || echo "STILL ON")
  printf "  %-26s %-36s %s\n" "$name" "$pkg" "$st"
}

echo "== 1. Tracking / telemetry / ACR =="
disable_one "Samba ACR"            tv.samba.ssm
disable_one "Samba ACR UI"         tv.samba.ssm.ui
disable_one "Sony IDD logging"     com.sonyericsson.idd.agent
disable_one "Sony bug report sys"  com.sony.dtv.sonybugreportsys
disable_one "Sony log-level sys"   com.sony.dtv.sonyloglevelsettingsys
disable_one "MediaTek DM agent"    com.mediatek.dmagent
disable_one "MediaTek bg detect"   com.mediatek.backgrounddetection
disable_one "MediaTek agent"       mtktvapi.agent
disable_one "Sony demo support"    com.sony.dtv.demosupport
disable_one "Sony demo sys"        com.sony.dtv.demosystemsupport
disable_one "Sony promos"          com.sony.dtv.promos
disable_one "Sony Select ads"      com.sony.dtv.sonyselect

echo "== 2. Ad personalization / usage reporting =="
$S shell settings put secure limit_ad_tracking 1 </dev/null 2>/dev/null && echo "  limit_ad_tracking = 1"
$S shell settings put secure user_setup_complete 1 </dev/null 2>/dev/null
$S shell settings put global package_verifier_user_consent -1 </dev/null 2>/dev/null
$S shell settings put secure send_action_app_error 0 </dev/null 2>/dev/null && echo "  app error reporting off"
$S shell cmd appops set com.sonyericsson.idd.agent RUN_IN_BACKGROUND ignore </dev/null 2>/dev/null
$S shell cmd appops set tv.samba.ssm RUN_IN_BACKGROUND ignore </dev/null 2>/dev/null
echo "  background run denied for trackers"

if [ "${HARDEN_OTA:-0}" = "1" ]; then
  echo "== 3. Firmware auto-update (OTA) OFF =="
  disable_one "Sony system update"   com.sony.dtv.systemupdate
  disable_one "Sony OTA provisioning" com.sony.dtv.otaurlprovisioning
  disable_one "Sony upgrade setup"   com.sony.dtv.upgradesetup
else
  echo "== 3. OTA blocking SKIPPED (re-run with: HARDEN_OTA=1 bash harden.sh) =="
fi

# refresh inventory
$S shell pm list packages -d </dev/null | sed 's/package://' | tr -d '\r' | sort > "$OUT/apps_disabled.txt"
echo; echo "== done. Undo everything:  bash harden_restore.sh =="
