#!/bin/bash
# Regenerates Resources/AppIcon.icns (and Resources/AppIcon.png) from Scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET" Resources
swift Scripts/make-icon.swift "$TMP/icon-1024.png" 1024 >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$TMP/icon-1024.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon.png"
