#!/bin/bash
# Notarizes and staples a signed disk image so Gatekeeper opens it without warnings.
# Needs a Developer ID signed build and a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials "cpilot-notary" --apple-id YOU --team-id TEAMID --password APP_SPECIFIC_PASSWORD
# Usage: NOTARY_PROFILE=cpilot-notary scripts/notarize.sh dist/CPilot-0.1.0.dmg
set -euo pipefail

DMG="${1:?usage: scripts/notarize.sh path/to.dmg}"
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Notarized $DMG"
