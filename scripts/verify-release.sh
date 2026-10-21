#!/bin/bash
# Downloads a published release and checks checksum, version, signature, Gatekeeper and notarization.
# Usage: scripts/verify-release.sh v0.1.1 [repo]
set -uo pipefail
TAG="${1:?usage: scripts/verify-release.sh vX.Y.Z [repo]}"
REPO="${2:-kalahroudi/cpilot}"
WORK="$(mktemp -d)"; MNT="$WORK/mnt"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$WORK"' EXIT
fail=0
check() { if eval "$2" >"$WORK/out" 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; sed 's/^/        /' "$WORK/out" | head -5; fail=1; fi; }
info() { echo "INFO  $1: $(eval "$2" 2>&1 | head -3 | tr '\n' ' ')"; }

cd "$WORK" && gh release download "$TAG" --repo "$REPO" --pattern '*.dmg' --pattern SHA256SUMS || { echo "FAIL  download"; exit 1; }
DMG="$(ls "$WORK"/*.dmg)"
check "checksum matches SHA256SUMS" "cd '$WORK' && shasum -a 256 -c SHA256SUMS"
mkdir -p "$MNT" && hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet
APP="$MNT/CPilot.app"
check "app is in the image" "test -d '$APP'"
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
check "bundle version $V matches tag $TAG" "[ '$V' = '${TAG#v}' ]"
info "commit" "/usr/libexec/PlistBuddy -c 'Print CPilotCommit' '$APP/Contents/Info.plist'"
check "arm64 binary" "lipo -archs '$APP/Contents/MacOS/CPilot' | grep -q arm64"
check "signature valid (deep, strict)" "codesign --verify --deep --strict -vv '$APP'"
info "signing authority" "codesign -dvv '$APP' 2>&1 | grep -E 'Authority|Signature=|TeamIdentifier'"
check "MCP binary signed" "codesign --verify --strict '$APP/Contents/MacOS/cpilot-mcp'"
if spctl -a -vvv -t exec "$APP" >"$WORK/out" 2>&1; then echo "PASS  Gatekeeper accepts the app"; else echo "NOTE  Gatekeeper rejects the app: $(head -2 "$WORK/out" | tr '\n' ' ')"; fi
if xcrun stapler validate "$DMG" >"$WORK/out" 2>&1; then echo "PASS  notarization ticket stapled"; else echo "NOTE  not notarized (no stapled ticket)"; fi
exit $fail
