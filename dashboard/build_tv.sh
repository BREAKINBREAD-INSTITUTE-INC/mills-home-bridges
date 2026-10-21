#!/usr/bin/env bash
# build_tv.sh v2.2. Renders the 10 MILLS OS TV boards in boards/ (TVR-*.dc.html) into tv-r-*.html and makes the TV rotator
# (tv.html) the page show_dashboard.sh opens. The boards in this repo hold SAMPLE DATA; replace them with your own.
# Run on the hub:  cd dashboard && bash build_tv.sh
# Then:  cd .. && bash show_dashboard.sh
# Undo:  bash build_tv.sh undo   (puts back the missioncontrol.html from before the first build)
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
KEEP="missioncontrol.before-tv.html"

if [ "${1:-}" = "undo" ]; then
  [ -f "$KEEP" ] || { echo "FAIL: no $KEEP to put back"; exit 1; }
  cp -p "$KEEP" missioncontrol.html
  echo "OK: missioncontrol.html is back to the version from before the TV build"
  exit 0
fi

PAIRS="TVR-Glance:tv-r-glance TVR-Waiting:tv-r-waiting TVR-Activity:tv-r-activity TVR-Leads:tv-r-leads TVR-Next:tv-r-next TVR-Fix:tv-r-fix TVR-Safety:tv-r-safety TVR-Machines:tv-r-machines TVR-Models:tv-r-models TVR-Log:tv-r-log"
LOOK="$(cat look.txt 2>/dev/null || echo roomy)"; case "$LOOK" in roomy|dense) ;; *) LOOK=roomy ;; esac
for f in tv.html tv-fit.snip dc_render.js; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
command -v node >/dev/null || { echo "FAIL: node not found"; exit 1; }

# Keep the first missioncontrol.html we ever replaced. Never overwrite that copy.
if [ -f missioncontrol.html ] && [ ! -f "$KEEP" ]; then
  cp -p missioncontrol.html "$KEEP"; echo "saved: $KEEP"
fi

OUTS=""
for pr in $PAIRS; do
  b="${pr%%:*}"; o="${pr##*:}.html"
  [ -f "boards/$b.dc.html" ] || { echo "FAIL: missing boards/$b.dc.html"; exit 1; }
  node dc_render.js "boards/$b.dc.html" "$o"
  OUTS="$OUTS $o"
done

# Board links point at canvas names. Point them at the rendered pages.
for f in $OUTS; do
  # Make each board fit the screen even when it is opened on its own (not through the rotator).
  perl -0pi -e 'BEGIN{local $/; open(F,"<","tv-fit.snip") or die "no tv-fit.snip\n"; $s=<F>; close F} s#</body>#$s</body>#' "$f"
  perl -pi -e 's/TVR-([A-Za-z-]+)\.dc\.html/"tv-r-".lc($1).".html"/ge; s#<title>MILLS OS .{1,4} Mission Control</title>#<title>MILLS OS TV</title>#' "$f"
done

bad=0
for f in $OUTS; do
  if grep -q '{{\|<sc-\|</sc-\|\.dc\.html' "$f"; then echo "FAIL: $f has unrendered parts"; bad=1; fi
  [ "$(wc -c < "$f")" -gt 5000 ] || { echo "FAIL: $f looks empty"; bad=1; }
done
[ "$bad" = 0 ] || exit 1

perl -pe 's/^var LOOK = "[a-z]+";/var LOOK = "'"$LOOK"'";/' tv.html > missioncontrol.html
grep -q "^var LOOK = \"$LOOK\";" missioncontrol.html || { echo "FAIL: look not set"; exit 1; }
for f in $OUTS; do echo "OK: $f $(wc -c < "$f") bytes"; done
echo "OK: missioncontrol.html is MILLS OS TV, look: $LOOK (switch: bash tv_look.sh roomy|dense)"
echo "Next: cd .. && bash show_dashboard.sh"
