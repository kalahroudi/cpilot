#!/bin/bash
# Builds CPilot.app into ./dist (or $DIST_DIR). Usage: scripts/bundle.sh [version]
# INSTALL=1 also replaces /Applications/CPilot.app (or $APP_DEST/CPilot.app) with the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="${DIST_DIR:-dist}/CPilot.app"
REPO="${APP_REPO:-kalahroudi/cpilot}"
BRANCH="${APP_BRANCH:-main}"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi

swift build -c release --product CPilot
swift build -c release --product cpilot-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CPilot" "$APP/Contents/MacOS/CPilot"
cp "$BIN/cpilot-mcp" "$APP/Contents/MacOS/cpilot-mcp"

# App icon, drawn by the app itself so no image tools are needed.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN/CPilot" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CPilot</string>
  <key>CFBundleDisplayName</key><string>CPilot</string>
  <key>CFBundleIdentifier</key><string>com.kalahroudi.cpilot</string>
  <key>CFBundleExecutable</key><string>CPilot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>CPilotCommit</key><string>$COMMIT</string>
  <key>CPilotRepo</key><string>$REPO</string>
  <key>CPilotBranch</key><string>$BRANCH</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc signed by default. With SIGN_IDENTITY set to a "Developer ID Application: ..." identity it is signed
# for distribution with the hardened runtime. An "Apple Development" identity (picked automatically for INSTALL=1)
# signs without it, which keeps the signature stable so macOS keeps Screen Recording and other grants across rebuilds.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ "${INSTALL:-0}" = "1" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN_FLAGS=(--force --sign -)
elif [[ "$SIGN_IDENTITY" == "Apple Development:"* ]]; then
  SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
else
  SIGN_FLAGS=(--force --timestamp --options runtime --entitlements scripts/CPilot.entitlements --sign "$SIGN_IDENTITY")
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/cpilot-mcp"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"

if [ "${INSTALL:-0}" = "1" ]; then
  DEST="${APP_DEST:-/Applications}/CPilot.app"
  if pgrep -f "$DEST/Contents/MacOS/CPilot" >/dev/null; then
    osascript -e 'tell application id "com.kalahroudi.cpilot" to quit' 2>/dev/null || true
    sleep 1
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
