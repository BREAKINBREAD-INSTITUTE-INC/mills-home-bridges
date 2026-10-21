#!/bin/bash
# MILLS TV guard — blueprint D6 "self-management", run from Hub instead of inside the launcher.
#
# Every 15 minutes (launchd: com.mills.tvguard) it checks the BRAVIA over ADB and puts back what a
# TV update may have undone, using the baseline recorded when the guard was installed:
#   - MILLS TV is the default home          -> set-home-activity again
#   - the MILLS clock is the screensaver    -> screensaver_components again
#   - apps the cleanup turned off stay off  -> pm disable-user again, EXCEPT anything on the
#     protected list (setup, launchers, inputs/tuner, System UI, Google services, Play, keyboards,
#     WebView): those are only reported, never touched, because turning them off can stop the
#     TV from starting.
# It never uninstalls anything and never touches an app that wasn't in the baseline.
#
#   bash tv_guard.sh --init     record the baseline from the TV as it is now
#   bash tv_guard.sh            check once (what launchd runs)
#   bash tv_guard.sh --status   show the baseline and the last log lines
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TV="${TV:?set TV to the TV address, e.g. TV=192.168.1.x:5555}"
DIR="$HOME/Scripts/tv/guard"; mkdir -p "$DIR"
BASE="$DIR/baseline.txt"; LOG="$DIR/guard.log"
ME="com.gathin.tvhome"
PROTECTED='setup|wraith|provision|launcher|tvinput|tv.framework|tvx|systemui|android.gms|vending|inputmethod|webview|tuner|cec|bluetooth|remote|settings'

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
S() { adb -s "$TV" shell "$@" 2>/dev/null | tr -d '\r'; }

adb connect "$TV" >/dev/null 2>&1
if [ "$(adb -s "$TV" get-state 2>/dev/null)" != "device" ]; then
  [ "${1:-}" = "--init" ] && { echo "TV not reachable at $TV"; exit 1; }
  log "TV not reachable (off or asleep) - nothing to check"; exit 0
fi

home_now() { S cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

if [ "${1:-}" = "--init" ]; then
  {
    echo "home=$(home_now)"
    echo "screensaver=$(S settings get secure screensaver_components)"
    echo "disabled=$(S pm list packages -d | sed 's/package://' | tr '\n' ' ')"
  } > "$BASE"
  log "baseline recorded"; cat "$BASE"; exit 0
fi
if [ "${1:-}" = "--status" ]; then cat "$BASE" 2>/dev/null; echo; tail -n 15 "$LOG" 2>/dev/null; exit 0; fi
[ -f "$BASE" ] || { log "no baseline yet: run tv_guard.sh --init"; exit 1; }

want_home=$(sed -n 's/^home=//p' "$BASE")
want_saver=$(sed -n 's/^screensaver=//p' "$BASE")
want_off=$(sed -n 's/^disabled=//p' "$BASE")
changed=0

# 1. home: only if MILLS is still installed, so a missing launcher can never strand the TV
if S pm list packages "$ME" | grep -qx "package:$ME"; then
  if [ "$(home_now)" != "$want_home" ] && [ "${want_home%%/*}" = "$ME" ]; then
    S cmd package set-home-activity --user 0 "$want_home" >/dev/null
    log "home was $(home_now | head -c 80) - set back to $want_home"; changed=1
  fi
else
  log "MILLS TV isn't installed - leaving the home alone"
fi

# 2. screensaver
if [ -n "$want_saver" ] && [ "$want_saver" != "null" ] && [ "$(S settings get secure screensaver_components)" != "$want_saver" ]; then
  S settings put secure screensaver_components "$want_saver"
  S settings put secure screensaver_enabled 1
  log "screensaver set back to $want_saver"; changed=1
fi

# 3. apps the cleanup turned off
now_off=" $(S pm list packages -d | sed 's/package://' | tr '\n' ' ') "
for p in $want_off; do
  case "$now_off" in *" $p "*) continue ;; esac
  S pm list packages "$p" | grep -qx "package:$p" || continue           # gone entirely: nothing to do
  if echo "$p" | grep -qiE "$PROTECTED"; then
    log "$p is back on (an update?) - protected, NOT turning it off; check by hand"; changed=1; continue
  fi
  S pm disable-user --user 0 "$p" >/dev/null
  log "$p came back on - turned it off again"; changed=1
done

[ "$changed" = 0 ] && log "all as set: home, screensaver, $(echo $want_off | wc -w | tr -d ' ') apps off"
exit 0
