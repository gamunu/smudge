#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Build the Smudge window app with a menu bar item and wrap it into
# build/app.noindex/Smudge.app, with Sparkle embedded and everything ad-hoc signed.
#
# Environment:
#   VERSION            override the version (see scripts/version.sh)
#   SPARKLE_PUBLIC_KEY EdDSA public key for update checks (base64). When unset,
#                      the app is built without SUPublicEDKey and cannot
#                      verify updates.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Smudge"
BUNDLE_ID="io.github.gamunu.smudge"
VERSION=$("$ROOT/scripts/version.sh")
FEED_URL="https://github.com/gamunu/smudge/releases/latest/download/appcast.xml"
OUT="$ROOT/build/app.noindex/$APP_NAME.app"

cd "$ROOT/app"
swift build -c release
swift build -c release --product smudge-scand
BIN_DIR=$(swift build -c release --show-bin-path)

SPARKLE_FW="$ROOT/app/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "missing $SPARKLE_FW" >&2; exit 1; }

# The scanner agent ships next to the app bundle, not inside it. build-pkg.sh installs it.
cp "$BIN_DIR/smudge-scand" "$ROOT/build/app.noindex/smudge-scand"
codesign -s - -f "$ROOT/build/app.noindex/smudge-scand"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
cp "$BIN_DIR/Smudge" "$OUT/Contents/MacOS/$APP_NAME"
# ditto keeps the symlinks inside the framework bundle.
ditto "$SPARKLE_FW" "$OUT/Contents/Frameworks/Sparkle.framework"

# Package.swift adds this rpath already. Add it only if missing.
if ! otool -l "$OUT/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/$APP_NAME"
fi

if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
    KEY_XML="<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>"
else
    KEY_XML=""
    echo "warning: SPARKLE_PUBLIC_KEY is not set. This build cannot verify updates." >&2
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>Copyright (C) 2026 Gamunu Balagalla. AGPL-3.0-or-later.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUEnableAutomaticChecks</key><true/>
    $KEY_XML
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
cp "$ROOT/app/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

# Sign inner to outer. No --deep, so every nested bundle gets its own signature.
FW="$OUT/Contents/Frameworks/Sparkle.framework/Versions/B"
for x in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
    [ -e "$x" ] && codesign --force -s - "$x"
done
codesign --force -s - "$OUT/Contents/Frameworks/Sparkle.framework"
codesign --force -s - "$OUT"
codesign --verify --strict "$OUT"
echo "Built $OUT ($VERSION)"
