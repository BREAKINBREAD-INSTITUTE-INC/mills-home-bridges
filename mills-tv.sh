#!/usr/bin/env bash
# MILLS OS TV - Phase 0: brand, speed up, round-2 debloat, ad-block DNS. All reversible.
# Run on the hub:  cd ~/Scripts/tv && bash mills-tv.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
LOG="$OUT/millstv_$(date +%Y%m%d_%H%M%S).log"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555 shell"
$S true >/dev/null 2>&1 || { echo "TV not reachable/authorized."; exit 1; }
log(){ echo "$@" | tee -a "$LOG"; }

log "== MILLS OS TV Phase 0  $(date) =="

log "-- branding: device name --"
$S "settings put global device_name 'MILLS OS TV'"
$S "settings put secure bluetooth_name 'MILLS OS TV'"
log "   device name -> MILLS OS TV"

log "-- screensaver: our ClockDream + timeouts --"
$S settings put secure screensaver_components com.gathin.tvhome/.ClockDream
$S settings put secure screensaver_enabled 1
$S settings put secure screensaver_activate_on_sleep 1
$S settings put system screen_off_timeout 600000
$S settings put secure sleep_timeout 7200000

log "-- speed tweaks --"
$S settings put global window_animation_scale 0.5
$S settings put global transition_animation_scale 0.5
$S settings put global animator_duration_scale 0.5
$S device_config put activity_manager max_cached_processes 12 2>/dev/null || true
$S settings put secure user_setup_complete 1
$S settings put secure tv_user_setup_complete 1

log "-- ad-block DNS (AdGuard DNS over TLS) --"
$S settings put global private_dns_mode hostname
$S settings put global private_dns_specifier dns.adguard-dns.com
log "   private DNS -> dns.adguard-dns.com   (undo: settings put global private_dns_mode automatic)"

log "-- stop streaming apps squatting in RAM --"
for p in com.netflix.ninja com.amazon.amazonvideo.livingroom com.peacocktv.peacockandroid com.cbs.ott com.hulu.livingroomplus com.disney.disneyplus; do
  if $S pm list packages | grep -q "$p"; then
    $S cmd appops set "$p" RUN_IN_BACKGROUND ignore 2>/dev/null || true
    $S cmd appops set "$p" RUN_ANY_IN_BACKGROUND ignore 2>/dev/null || true
    log "   bg-limited $p"
  fi
done

log "-- round-2 debloat (reversible: cmd package install-existing <pkg>) --"
RM2=( com.google.android.tvrecommendations com.google.android.backdrop com.google.android.apps.tv.dreamx com.google.android.videos com.google.android.feedback com.google.android.partnersetup com.sony.dtv.demosupport com.sony.dtv.demosystemsupport com.sony.dtv.multiscreendemo )
: > "$OUT/debloat2.txt"
for p in "${RM2[@]}"; do
  if $S pm list packages | grep -q "^package:$p$"; then
    out=$($S pm uninstall -k --user 0 "$p" 2>&1)
    if echo "$out" | grep -qi success; then echo "$p" >> "$OUT/debloat2.txt"; log "   removed $p"; else log "   skip $p ($out)"; fi
  else
    log "   not present $p"
  fi
done

log "-- AOT compile launcher + trim --"
$S cmd package compile -m speed -f com.gathin.tvhome >/dev/null 2>&1 || true
$S cmd package bg-dexopt-job >/dev/null 2>&1 || true
$S pm trim-caches 999G >/dev/null 2>&1 || true

log "-- free space --"; $S df /data | tail -1 | tee -a "$LOG"
log "== DONE. Reboot the TV to see the new name and full effect. =="
log "Undo DNS:    adb -s $TV:5555 shell settings put global private_dns_mode automatic"
log "Restore app: adb -s $TV:5555 shell cmd package install-existing <pkg>  (removed list: out/debloat2.txt)"
