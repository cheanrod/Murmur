#!/bin/bash
# Builds Murmur.app (release) into ./build. Usage: Scripts/build-app.sh [debug|release]
#
# Signing: set MURMUR_SIGN_IDENTITY to a codesigning identity (name or SHA-1 hash), or "-" for ad-hoc.
# If unset, the first "Developer ID Application" identity is used, then "Apple Development", then ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Murmur
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Murmur"
eval "$(Scripts/version.sh)"
APP="build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Murmur</string>
    <key>CFBundleDisplayName</key><string>Murmur</string>
    <key>CFBundleIdentifier</key><string>app.murmur.Murmur</string>
    <key>CFBundleExecutable</key><string>Murmur</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${MURMUR_VERSION}</string>
    <key>CFBundleVersion</key><string>${MURMUR_BUILD}</string>
    <key>MurmurFullVersion</key><string>${MURMUR_FULL_VERSION}</string>
    <key>MurmurCommit</key><string>${MURMUR_COMMIT}</string>
    <key>NSHumanReadableCopyright</key><string>Murmur: from murmuration, a flock of starlings moving as one.</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
IDENTITY="${MURMUR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    IDENTITY="$(echo "$IDENTITIES" | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
    [ -z "$IDENTITY" ] && IDENTITY="$(echo "$IDENTITIES" | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)"
    [ -z "$IDENTITY" ] && IDENTITY="-"
fi

SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    # Hardened runtime + secure timestamp are required for notarization.
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP ${MURMUR_FULL_VERSION} (build ${MURMUR_BUILD}, ad-hoc signed)"
else
    echo "Built $APP ${MURMUR_FULL_VERSION} (build ${MURMUR_BUILD}, signed with: $IDENTITY)"
fi
