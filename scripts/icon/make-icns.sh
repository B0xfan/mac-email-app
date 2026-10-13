#!/bin/zsh
# Rebuilds scripts/AppIcon.icns from AppIcon.svg (macOS only: Quick Look renders the SVG, iconutil packs it; ImageMagick's SVG renderer drops the strokes). Only when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")"
S=$(mktemp -d)/AppIcon.iconset; mkdir -p "$S"
qlmanage -t -s 1024 -o "$S" AppIcon.svg >/dev/null 2>&1; mv "$S/AppIcon.svg.png" "$S/big.png"
for p in 16 32 128 256 512; do
  sips -z $p $p "$S/big.png" --out "$S/icon_${p}x${p}.png" >/dev/null
  sips -z $((p*2)) $((p*2)) "$S/big.png" --out "$S/icon_${p}x${p}@2x.png" >/dev/null
done
rm "$S/big.png"; iconutil -c icns "$S" -o ../AppIcon.icns
