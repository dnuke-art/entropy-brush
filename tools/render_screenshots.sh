#!/usr/bin/env bash
# Render App Store screenshots locally from the real UI (no simulator).
#   tools/render_screenshots.sh iphone   -> ios/appstore/screenshots/iphone-6.9/
#   tools/render_screenshots.sh ipad     -> ios/appstore/screenshots/ipad-13/ (2732x2048 landscape)
# One flutter test process per scene (the headless rasteriser hangs on a 2nd toImage).
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=${1:-iphone}
case "$DEV" in iphone) DIR=ios/appstore/screenshots/iphone-6.9;; ipad|ipad-portrait) DIR=ios/appstore/screenshots/ipad-13;; *) echo "usage: $0 iphone|ipad"; exit 1;; esac
FLUTTER_ROOT=$(flutter --version --machine | python3 -c 'import sys,json;print(json.load(sys.stdin)["flutterRoot"])')
MI="$FLUTTER_ROOT/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
OUT=$(mktemp -d)
SCENES=$(grep -oE "^\s*'[0-9]{2}-[a-z]+':" lib/screenshot_seed.dart | tr -d " ':")
for sc in $SCENES; do
  SCREENSHOT_OUT="$OUT" SCREENSHOT_DEVICE="$DEV" SCREENSHOT_SCENE="$sc" MATERIAL_ICONS="$MI" \
    flutter test test/screenshot_render_test.dart --tags screenshots 2>&1 | grep -E "WROTE|failed|Exception" || true
done
mkdir -p "$DIR"
for f in "$OUT"/*.png; do
  b=$(basename "$f" .png)
  convert "$f" -alpha off "$DIR/$b.png"   # ASC silently fails PNGs with alpha
  identify -format "%f %wx%h\n" "$DIR/$b.png"
done
