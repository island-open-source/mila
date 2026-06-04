#!/bin/bash
# Publish a notarized Mila release to the Sparkle auto-update channel:
# extract the notarized app from the DMG, build the update ZIP, EdDSA-sign it,
# update appcast.xml, and upload ZIP + DMG + appcast to the S3 update bucket.
#
# Run AFTER scripts/sign-and-notarize.sh has produced a notarized+stapled DMG.
# This is the Jenkins replacement for the Sparkle-publish steps the old
# GitHub Actions release.yml performed.
#
# Args:
#   $1  path to the notarized, stapled DMG (Mila-<version>.dmg)
#   $2  MARKETING_VERSION         (e.g. 1.8.2)
#   $3  CURRENT_PROJECT_VERSION   (build number, e.g. 39)
#
# Required env:
#   SPARKLE_PRIVATE_KEY  the EdDSA private key VALUE (not a path). MUST be the
#                        same key whose public counterpart (SUPublicEDKey) is
#                        baked into shipped Mila builds, or clients reject the
#                        update.
#   SPARKLE_BIN          directory containing Sparkle's `sign_update` tool
#                        (resolved by SPM during the Release build, under
#                        build-release/SourcePackages/artifacts/sparkle/Sparkle/bin)
# Optional env:
#   BUCKET               S3 bucket (default: island-whisper-updates)
#   FEED_URL_BASE        appcast <enclosure> URL base
#                        (default: https://island-whisper-updates.internal.island.io)
#   OUTPUT_DIR           scratch dir for the ZIP/appcast (default: cwd)
#
# AWS auth: relies on the ambient credentials of the runner (the mac-builder
# Jenkins agent's IAM principal, granted s3:Get/Put/ListBucket on the bucket).
set -euo pipefail

# `:?` rejects both unset AND empty, so an empty VERSION/BUILD (e.g. caller
# passed a blank arg because project.yml parsing failed upstream) aborts here
# rather than flowing into update-appcast.py and emitting an empty
# sparkle:version — which previously broke the feed for every client.
DMG_PATH="${1:?usage: publish-sparkle.sh <dmg-path> <version> <build>}"
VERSION="${2:?usage: publish-sparkle.sh <dmg-path> <version> <build> (version is empty)}"
BUILD="${3:?usage: publish-sparkle.sh <dmg-path> <version> <build> (build is empty)}"

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY (EdDSA private key value) is required}"
: "${SPARKLE_BIN:?SPARKLE_BIN (dir containing sign_update) is required}"
BUCKET="${BUCKET:-island-whisper-updates}"
FEED_URL_BASE="${FEED_URL_BASE:-https://island-whisper-updates.internal.island.io}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIP="$OUTPUT_DIR/Mila-${VERSION}.zip"
APPCAST="$OUTPUT_DIR/appcast.xml"

[[ -f "$DMG_PATH" ]]            || { echo "error: DMG not found: $DMG_PATH" >&2; exit 1; }
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "error: sign_update not found in $SPARKLE_BIN" >&2; exit 1; }

echo "=== Extracting the notarized app from $DMG_PATH"
MOUNT="$(mktemp -d)"
APP_STAGE="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$MOUNT" "$APP_STAGE"' EXIT
hdiutil attach -nobrowse -mountpoint "$MOUNT" "$DMG_PATH" >/dev/null
cp -R "$MOUNT/Mila.app" "$APP_STAGE/"
hdiutil detach "$MOUNT" -quiet
APP="$APP_STAGE/Mila.app"

# The DMG submission notarized the app's cdhash; staple the ticket onto the
# app itself so the extracted update validates offline (Gatekeeper on the
# user's machine after Sparkle unarchives the ZIP).
echo "=== Stapling the notary ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# `ditto -c -k --keepParent` is the macOS-aware archiver — preserves xattrs,
# symlinks, and code signatures that plain `zip` silently drops. Sparkle 2.x
# extracts ZIPs in-process (libarchive), avoiding the DMG-mount path that
# failed for some users on the ~150 MB bundled-Python builds.
echo "=== Building the Sparkle update ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ls -la "$ZIP"

echo "=== EdDSA-signing the ZIP"
SIG_LINE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP")"
SIG="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LEN="$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$SIG" || -z "$LEN" ]]; then
  echo "error: could not parse signature/length from sign_update output: $SIG_LINE" >&2
  exit 1
fi

echo "=== Updating appcast.xml (pulling existing feed if present)"
# CRITICAL: distinguish "the feed doesn't exist yet" (fine — start fresh) from
# "the feed exists but we failed to fetch it" (transient network/credential
# error). A blanket `|| echo ...` here would swallow the latter, and since
# update-appcast.py initializes an empty feed when --appcast-in is missing, we
# would then upload a single-item appcast over the populated one in S3 —
# silently wiping every prior update entry.
#
# head-object exits non-zero for BOTH "object not found" (404) AND transient
# failures (network, 5xx, throttling, expired creds). We must NOT collapse
# those two into "start fresh" — only a genuine 404 is safe to treat that way.
# So: capture head-object's stderr + exit code, and branch three ways:
#   exit 0            -> feed exists; the download MUST succeed (abort on fail)
#   404 / Not Found   -> feed genuinely absent; start a fresh feed
#   any other failure -> transient/unknown; ABORT rather than risk clobbering
rm -f "$APPCAST"
HEAD_ERR="$(aws s3api head-object --bucket "$BUCKET" --key appcast.xml 2>&1 >/dev/null)" && HEAD_RC=0 || HEAD_RC=$?
if [[ "$HEAD_RC" -eq 0 ]]; then
  echo "existing appcast found — fetching it (must succeed to avoid clobbering the feed)"
  aws s3 cp "s3://${BUCKET}/appcast.xml" "$APPCAST"
elif printf '%s' "$HEAD_ERR" | grep -Eq '(404|Not Found)'; then
  echo "no existing appcast in s3://${BUCKET}/appcast.xml — starting a fresh feed"
else
  echo "error: could not determine whether s3://${BUCKET}/appcast.xml exists" >&2
  echo "       (head-object exit $HEAD_RC: ${HEAD_ERR})" >&2
  echo "       refusing to proceed — a fresh feed here would clobber existing update history" >&2
  exit 1
fi
python3 "$SCRIPT_DIR/update-appcast.py" \
  --version "$VERSION" \
  --build "$BUILD" \
  --artifact-name "Mila-${VERSION}.zip" \
  --signature "$SIG" \
  --length "$LEN" \
  --feed-url-base "$FEED_URL_BASE" \
  --appcast-in "$APPCAST" \
  --appcast-out "$APPCAST"

echo "=== Uploading to s3://${BUCKET}/"
# Upload the ZIP (the asset the appcast references) BEFORE the appcast, so a
# client polling the feed never sees an enclosure URL that 404s.
aws s3 cp "$ZIP" "s3://${BUCKET}/Mila-${VERSION}.zip" --content-type application/zip
aws s3 cp "$DMG_PATH" "s3://${BUCKET}/Mila-${VERSION}.dmg" --content-type application/octet-stream
# Stable "latest" alias for direct download links (server-side copy).
aws s3 cp "s3://${BUCKET}/Mila-${VERSION}.dmg" "s3://${BUCKET}/Mila-latest.dmg" \
  --content-type application/octet-stream \
  --cache-control "max-age=300, must-revalidate" \
  --metadata "source-version=${VERSION}" \
  --metadata-directive REPLACE
aws s3 cp "$APPCAST" "s3://${BUCKET}/appcast.xml" \
  --content-type "application/xml; charset=utf-8" \
  --cache-control "max-age=300"

echo "=== Published Mila ${VERSION} (build ${BUILD}) to the Sparkle channel: ${FEED_URL_BASE}/appcast.xml"
