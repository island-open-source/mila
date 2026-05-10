#!/bin/bash
# Build a distribution DMG from a Release-built IslandWhisper.app.
#
# Usage: scripts/make-dmg.sh path/to/IslandWhisper.app IslandWhisper-1.0.0.dmg 1.0.0
#
# Output: $DMG_PATH (relative or absolute) ready to upload as a GitHub release
# asset. The app is ad-hoc signed (no Apple Developer ID required) so on first
# launch macOS will Gatekeeper-prompt the user; right-click → Open works around
# it. Re-sign with `codesign -s "Developer ID Application: ..."` before
# distributing externally.

set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"
DMG_PATH="${2:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"
VERSION="${3:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist or is not a directory" >&2
    exit 1
fi

# Stage the DMG contents in a clean temp dir. Includes the .app and a symlink
# to /Applications so the standard "drag to install" UX works out of the box.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Re-sign the bundle to make sure the embedded `whisper.framework` and the
# wrapping app stay in sync after the cp -R above. Honors `CODESIGN_IDENTITY`
# so CI can sign with our self-signed Developer-ID-equivalent cert (its
# SHA1 fingerprint is the trust anchor for TCC permissions across releases —
# every build signed with the SAME cert keeps the user's previously-granted
# Accessibility / mic permissions). Defaults to ad-hoc ("-") for local
# builds where the cert isn't in keychain.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$STAGE/$(basename "$APP_PATH")"

VOLNAME="IslandWhisper $VERSION"
TMP_DMG="$(mktemp -t IslandWhisperDMG.XXXXXX).dmg"

rm -f "$DMG_PATH" "$TMP_DMG"

# UDZO = compressed read-only DMG, the standard format for distribution.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$TMP_DMG" >/dev/null

mv "$TMP_DMG" "$DMG_PATH"
echo "$DMG_PATH"
