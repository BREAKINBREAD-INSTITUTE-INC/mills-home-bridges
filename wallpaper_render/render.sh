#!/usr/bin/env bash
# Renders the MILLS TV blueprint wallpaper + its pre-blurred dock frost (blueprint D2/D3)
# straight from the concept's own CSS, then writes WebP into the launcher's drawable-nodpi.
#   bash ~/Scripts/tv/wallpaper_render/render.sh
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
RES="$HOME/Scripts/tv-vibehack/launcher/app/src/main/res/drawable-nodpi"
mkdir -p out "$RES"
shot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1920,1080 --virtual-time-budget=2000 \
  --screenshot="$PWD/out/$1.png" "file://$PWD/wallpaper.html?$2" >/dev/null 2>&1; }
shot wp_dusk        "v=dark"
shot wp_day         "v=light"
shot wp_ridge       "v=ridge"
shot wp_coast       "v=coast"
fshot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --allow-file-access-from-files --default-background-color=00000000 --window-size=1920,1080 \
  --virtual-time-budget=4000 --screenshot="$PWD/out/$1.png" "file://$PWD/frost.html?src=out/$2.png" >/dev/null 2>&1; }
fshot frost_dusk wp_dusk
fshot frost_day  wp_day
fshot frost_ridge wp_ridge
fshot frost_coast wp_coast
# Wallpapers full size, lossy q88 (D3). Frost is pure low-frequency: quarter size is invisible
# once scaled back up, and keeps it ~0.5 MB in memory.
cwebp -quiet -q 88 out/wp_dusk.png  -o "$RES/wp_dusk.webp"
cwebp -quiet -q 88 out/wp_day.png   -o "$RES/wp_day.webp"
cwebp -quiet -q 88 out/wp_ridge.png -o "$RES/wp_ridge.webp"
cwebp -quiet -q 88 out/wp_coast.png -o "$RES/wp_coast.webp"
cwebp -quiet -q 88 -resize 480 270 out/frost_dusk.png -o "$RES/dock_frost_dusk.webp"
cwebp -quiet -q 88 -resize 480 270 out/frost_day.png  -o "$RES/dock_frost_day.webp"
cwebp -quiet -q 88 -resize 480 270 out/frost_ridge.png -o "$RES/dock_frost_ridge.webp"
cwebp -quiet -q 88 -resize 480 270 out/frost_coast.png -o "$RES/dock_frost_coast.webp"
ls -la "$RES"/wp_*.webp "$RES"/dock_frost_*.webp
