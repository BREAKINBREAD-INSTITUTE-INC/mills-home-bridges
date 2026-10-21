#!/usr/bin/env bash
# Undo harden.sh — re-enable everything it disabled.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
for p in tv.samba.ssm tv.samba.ssm.ui com.sonyericsson.idd.agent com.sony.dtv.sonybugreportsys \
  com.sony.dtv.sonyloglevelsettingsys com.mediatek.dmagent com.mediatek.backgrounddetection \
  mtktvapi.agent com.sony.dtv.demosupport com.sony.dtv.demosystemsupport com.sony.dtv.promos \
  com.sony.dtv.sonyselect com.sony.dtv.systemupdate com.sony.dtv.otaurlprovisioning com.sony.dtv.upgradesetup; do
  $S shell pm enable "$p" </dev/null >/dev/null 2>&1 && echo "enabled $p"
done
$S shell settings put secure limit_ad_tracking 0 </dev/null 2>/dev/null
echo "done."
