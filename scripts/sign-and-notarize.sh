#!/bin/bash
# Sign + notarize a Release-built Mila.app, producing $OUTPUT_DIR/Mila-<VERSION>.dmg.
#
# Env vars (all required unless SKIP_NOTARIZE=true):
#   CODESIGN_IDENTITY KEYCHAIN_PATH
#   NOTARIZE_APPLE_ID NOTARIZE_APP_PASSWORD NOTARIZE_TEAM_ID
#   OUTPUT_DIR (default: cwd)

set -euo pipefail

APP_PATH="${1:?usage: sign-and-notarize.sh APP_PATH VERSION}"
VERSION="${2:?usage: sign-and-notarize.sh APP_PATH VERSION}"

: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY env var required}"
: "${KEYCHAIN_PATH:?KEYCHAIN_PATH env var required}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-false}"
if [[ "$SKIP_NOTARIZE" != "true" ]]; then
  : "${NOTARIZE_APPLE_ID:?NOTARIZE_APPLE_ID env var required (or set SKIP_NOTARIZE=true)}"
  : "${NOTARIZE_APP_PASSWORD:?NOTARIZE_APP_PASSWORD env var required (or set SKIP_NOTARIZE=true)}"
  : "${NOTARIZE_TEAM_ID:?NOTARIZE_TEAM_ID env var required (or set SKIP_NOTARIZE=true)}"
fi
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH is not a directory" >&2
  exit 1
fi

ENTITLEMENTS="$(dirname "$0")/../Mila/Resources/Mila.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements not found at $ENTITLEMENTS" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
STAGED_APP="$STAGE/$(basename "$APP_PATH")"

echo "=== Removing inherited ad-hoc signatures"
find "$STAGED_APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} \;

echo "=== Codesigning nested code"
sign_one() {
  local target="$1"
  codesign --force --options runtime --timestamp \
    --keychain "$KEYCHAIN_PATH" \
    --sign "$CODESIGN_IDENTITY" \
    "$target"
}

# Apple notarization requires EVERY Mach-O binary to carry Developer ID +
# hardened runtime. Pass 1 catches loose binaries (.so, .dylib, bare
# executables — the PythonRuntime tree has hundreds); pass 2 wraps the
# bundles deepest-first so seals are consistent.
echo "--- Pass 1: Mach-O files"
while IFS= read -r -d '' f; do
  case "$f" in
    */_CodeSignature/*|*.dSYM/*) continue ;;
  esac
  if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
    sign_one "$f"
  fi
done < <(find "$STAGED_APP" -type f -print0)

echo "--- Pass 2: bundle wrappers"
while IFS= read -r -d '' f; do
  case "$f" in
    *.dSYM|*/_CodeSignature|*/_CodeSignature/*) continue ;;
  esac
  echo "  sign: $f"
  sign_one "$f"
done < <(find "$STAGED_APP" -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print0)

# The bundled Python interpreter loads pip-installed torch dylibs that are
# ad-hoc-signed at runtime (DiarizationBootstrap.signFreshDylibs). Under
# hardened runtime, library validation rejects any dylib whose Team ID
# differs from the loading process — and post-notarization that's EVERY
# torch dylib (Island-signed Python vs ad-hoc torch). Without disabling
# library validation on the interpreter, `import torch` dies with
# "different Team IDs" and diarization silently fails in every notarized
# build. Re-sign the interpreter(s) WITH that entitlement after the blanket
# passes above (so this signature wins) and before the outer bundle seal.
PYTHON_ENTITLEMENTS="$(dirname "$0")/python-runtime.entitlements"
if [[ -f "$PYTHON_ENTITLEMENTS" ]]; then
  echo "=== Re-signing bundled Python interpreter(s) with library validation disabled"
  signed_python=0
  while IFS= read -r -d '' py; do
    if file -b "$py" 2>/dev/null | grep -q "Mach-O"; then
      echo "  sign (lib-val disabled): $py"
      codesign --force --options runtime --timestamp \
        --entitlements "$PYTHON_ENTITLEMENTS" \
        --keychain "$KEYCHAIN_PATH" \
        --sign "$CODESIGN_IDENTITY" \
        "$py"
      signed_python=$((signed_python + 1))
    fi
  done < <(find "$STAGED_APP" -type f -path "*/PythonRuntime/*/bin/python3*" -print0)
  if [[ "$signed_python" -eq 0 ]]; then
    echo "  note: no bundled Python interpreter found (diarization runtime not bundled in this build)"
  fi
else
  echo "warning: $PYTHON_ENTITLEMENTS not found — bundled Python will lack disable-library-validation; diarization will fail post-notarize" >&2
fi

echo "=== Codesigning the main app bundle with hardened runtime + entitlements"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --keychain "$KEYCHAIN_PATH" \
  --sign "$CODESIGN_IDENTITY" \
  "$STAGED_APP"

echo "=== Verifying signature"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
spctl --assess --type execute --verbose=4 "$STAGED_APP" || {
  echo "  spctl assessment failed pre-notarize (expected before notarization)"
}

# Inline DMG build — make-dmg.sh would re-sign the .app with --force --deep
# without --options runtime, stripping hardened runtime and failing notary.
echo "=== Building DMG"
DMG_PATH="$OUTPUT_DIR/Mila-${VERSION}.dmg"
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$DMG_STAGE"' EXIT
cp -R "$STAGED_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
TMP_DMG="$(mktemp -t MilaDMG.XXXXXX).dmg"
rm -f "$DMG_PATH" "$TMP_DMG"
hdiutil create \
  -volname "Mila ${VERSION}" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$TMP_DMG" >/dev/null
mv "$TMP_DMG" "$DMG_PATH"

echo "=== Signing the DMG envelope"
codesign --force --timestamp \
  --keychain "$KEYCHAIN_PATH" \
  --sign "$CODESIGN_IDENTITY" \
  "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" == "true" ]]; then
  echo "=== SKIP_NOTARIZE=true — skipping notarytool + staple"
  echo "Note: this DMG is signed but NOT notarized — Gatekeeper will still warn."
else
  echo "=== Submitting to Apple notary service (notarytool, --wait)"
  # Capture stdout so we can extract the submission ID and dump the
  # per-issue log on rejection. Otherwise notarytool only prints "status:
  # Invalid" with no detail on WHY.
  NOTARY_OUTPUT="$(mktemp)"
  if xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$NOTARIZE_APPLE_ID" \
      --password "$NOTARIZE_APP_PASSWORD" \
      --team-id "$NOTARIZE_TEAM_ID" \
      --wait 2>&1 | tee "$NOTARY_OUTPUT"; then
    # `|| true` is required: pipefail + set -e would otherwise kill the
    # script if grep matches nothing (unexpected output shape), skipping
    # the diagnostic log fetch below.
    NOTARY_STATUS="$(grep -E '^[[:space:]]*status:' "$NOTARY_OUTPUT" | tail -1 | awk '{print $2}' || true)"
    NOTARY_STATUS="${NOTARY_STATUS:-Unknown}"
  else
    NOTARY_STATUS="Failed"
  fi
  echo "Notary status: $NOTARY_STATUS"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    SUBMISSION_ID="$(grep -E '^[[:space:]]*id:' "$NOTARY_OUTPUT" | head -1 | awk '{print $2}' || true)"
    if [[ -n "$SUBMISSION_ID" ]]; then
      echo "=== Notary rejected — fetching submission log for $SUBMISSION_ID"
      xcrun notarytool log "$SUBMISSION_ID" \
        --apple-id "$NOTARIZE_APPLE_ID" \
        --password "$NOTARIZE_APP_PASSWORD" \
        --team-id "$NOTARIZE_TEAM_ID" || true
    fi
    exit 1
  fi

  echo "=== Stapling the notary ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "=== Final spctl assessment"
  spctl --assess --type install --verbose=4 "$DMG_PATH"
fi

echo "=== Done — DMG at: $DMG_PATH"
