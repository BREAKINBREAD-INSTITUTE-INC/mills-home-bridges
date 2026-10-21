#!/usr/bin/env bash
# build_tv.sh v2.1 (Oct 19 2026; v2.1 adds the roomy look, chosen in look.txt). Renders the 8 MILLS OS TV pages (and the old v3 pair). Renders the two TV boards and makes the TV rotator the page
# show_dashboard.sh opens. Run on the hub:  cd ~/Scripts/tv/dashboard && bash build_tv.sh
# Then:  cd ~/Scripts/tv && bash show_dashboard.sh
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

PAIRS="v3-TV:tv-glance v3-TV-Rotate:tv-models v4-TV:tv-v4-tv v4-TV-Activity:tv-v4-tv-activity v4-TV-Leads:tv-v4-tv-leads v4-TV-Claims:tv-v4-tv-claims v4-TV-Safety:tv-v4-tv-safety v4-TV-Machines:tv-v4-tv-machines v4-TV-Models:tv-v4-tv-models v4-TV-Log:tv-v4-tv-log TVR-Glance:tv-r-glance TVR-Waiting:tv-r-waiting TVR-Activity:tv-r-activity TVR-Leads:tv-r-leads TVR-Next:tv-r-next TVR-Fix:tv-r-fix TVR-Safety:tv-r-safety TVR-Machines:tv-r-machines TVR-Models:tv-r-models TVR-Log:tv-r-log"
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
  perl -pi -e 's/v3-TV-Rotate\.dc\.html/tv-models.html/g; s/v3-TV\.dc\.html/tv-glance.html/g; s/v4-([A-Za-z-]+)\.dc\.html/"tv-v4-".lc($1).".html"/ge; s/TVR-([A-Za-z-]+)\.dc\.html/"tv-r-".lc($1).".html"/ge; s#<title>MILLS OS .{1,4} Mission Control</title>#<title>MILLS OS TV</title>#' "$f"
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
echo "Next: cd ~/Scripts/tv && bash show_dashboard.sh"
