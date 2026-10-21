#!/bin/bash
# Installs CPilot into /Applications from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/kalahroudi/cpilot/main/scripts/install.sh | bash
# Options (environment): APP_VERSION=v0.1.0 to pin a version, APP_DEST=~/Applications to change the folder.
# If no release exists yet, it builds from source (needs the Xcode command line tools).
set -euo pipefail

REPO="kalahroudi/cpilot"
DEST="${APP_DEST:-/Applications}"
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "CPilot is a macOS app."
[ "$(uname -m)" = "arm64" ] || say "Note: CPilot is built for Apple silicon. Intel Macs should build from source."
mkdir -p "$DEST" || die "Can't create $DEST"
[ -w "$DEST" ] || die "No permission to write to $DEST. Try APP_DEST=\$HOME/Applications"

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

API="https://api.github.com/repos/$REPO/releases/${APP_VERSION:+tags/$APP_VERSION}"
[ -n "${APP_VERSION:-}" ] || API="https://api.github.com/repos/$REPO/releases/latest"

say "Looking for the latest release"
if JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null)"; then
  DMG_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*: *"//; s/"$//')"
  SUMS_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS"' | head -1 | sed 's/.*: *"//; s/"$//')"
fi

if [ -n "${DMG_URL:-}" ]; then
  NAME="$(basename "$DMG_URL")"
  say "Downloading $NAME"
  curl -fL --progress-bar -o "$TMP/$NAME" "$DMG_URL"
  if [ -n "${SUMS_URL:-}" ]; then
    curl -fsSL -o "$TMP/SHA256SUMS" "$SUMS_URL"
    EXPECT="$(grep " \*\?$NAME\$" "$TMP/SHA256SUMS" | awk '{print $1}')"
    ACTUAL="$(shasum -a 256 "$TMP/$NAME" | awk '{print $1}')"
    [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ] || die "Checksum mismatch. The download may be damaged."
    say "Checksum OK"
  fi
  mkdir -p "$TMP/mnt"
  hdiutil attach "$TMP/$NAME" -nobrowse -readonly -mountpoint "$TMP/mnt" -quiet
  SRC="$TMP/mnt/CPilot.app"
else
  say "No release found. Building from source (a few minutes)"
  command -v swift >/dev/null || die "Install the Xcode command line tools first: xcode-select --install"
  git clone --depth 1 "https://github.com/$REPO.git" "$TMP/src"
  (cd "$TMP/src" && scripts/bundle.sh)
  SRC="$TMP/src/dist/CPilot.app"
fi

if pgrep -x CPilot >/dev/null; then say "Quitting the running CPilot"; osascript -e 'tell application "CPilot" to quit' 2>/dev/null || pkill -x CPilot || true; sleep 1; fi
rm -rf "$DEST/CPilot.app"
ditto "$SRC" "$DEST/CPilot.app"
say "Installed $DEST/CPilot.app"

# Add prerequisite hints here if the app needs tools. The app itself detects and installs them on first launch (see references/setup-wizard.md).
open "$DEST/CPilot.app"
say "Done. Look for the cube icon in your menu bar."
