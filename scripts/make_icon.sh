#!/usr/bin/env bash
# Renders assets/icon.svg into assets/icon-1024.png and assets/AppIcon.icns.
# Needs Google Chrome (to rasterize the SVG with its filters) plus the built-in sips and iconutil.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/icon.html" <<HTML
<!doctype html><html><body style="margin:0;background:transparent">
<img src="file://$PWD/assets/icon.svg" width="1024" height="1024" style="display:block"></body></html>
HTML
"$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$TMP/icon-1024.png" "file://$TMP/icon.html" 2>/dev/null
cp "$TMP/icon-1024.png" assets/icon-1024.png

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/icon-1024.png and assets/AppIcon.icns"
