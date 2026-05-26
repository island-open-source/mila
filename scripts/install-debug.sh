#!/usr/bin/env bash
# Install the Debug build into /Applications and re-sign it with a stable
# self-signed certificate ("Mila Local Dev") so macOS TCC keeps Microphone
# / Screen Recording / Accessibility grants across rebuilds instead of
# treating every fresh ad-hoc binary as a brand-new app.
#
# Usage:
#   ./scripts/install-debug.sh
#
# Run `make build` first (or the script will refuse with a clear error
# rather than installing stale bytes). The cert is created on first run
# in the login keychain; subsequent runs reuse it.

set -euo pipefail

CERT_CN="Mila Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
APP_SRC="$(cd "$(dirname "$0")/.." && pwd)/build/Build/Products/Debug/Mila.app"
APP_DST="/Applications/Mila.app"
ENT="$(cd "$(dirname "$0")/.." && pwd)/Mila/Resources/Mila.entitlements"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }
}
require codesign
require security
require openssl

if [[ ! -d "$APP_SRC" ]]; then
  echo "no Debug build at $APP_SRC — run \`make build\` first" >&2
  exit 1
fi

# 1. Make sure the signing cert exists. We identify it by SHA-1 hash so
#    we can sign without the cert being a "trusted code-signing identity"
#    — security find-identity only returns trusted certs and self-signed
#    ones never get there, but codesign happily takes a SHA-1 directly.
ensure_cert() {
  local sha
  sha=$(security find-certificate -c "$CERT_CN" -a -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/SHA-1 hash/ {print $NF}' | head -1 || true)
  if [[ -n "$sha" ]]; then
    echo "$sha"
    return 0
  fi

  echo "no $CERT_CN cert in $KEYCHAIN — creating one" >&2
  local work pw
  work=$(mktemp -d -t mila-cert)
  pw="milalocal"

  # CN-only self-signed 10-year cert with the keyUsage + extendedKeyUsage
  # bits codesign requires. macOS's `security import` is picky about the
  # PKCS#12 encoding — SHA-1 MAC + 3DES PBE is the combination that's
  # accepted by the keychain on macOS 14/15/26 alike.
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 3650 \
    -config <(cat <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = $CERT_CN
[v3_ca]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
) >/dev/null 2>&1

  openssl pkcs12 -export \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$CERT_CN" -out "$work/cert.p12" \
    -password "pass:$pw" \
    -macalg SHA1 \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1

  security import "$work/cert.p12" \
    -k "$KEYCHAIN" \
    -P "$pw" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

  rm -rf "$work"

  sha=$(security find-certificate -c "$CERT_CN" -a -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/SHA-1 hash/ {print $NF}' | head -1)
  if [[ -z "$sha" ]]; then
    echo "cert was imported but couldn't be re-read by SHA-1" >&2
    exit 1
  fi
  echo "$sha"
}

CERT_SHA="$(ensure_cert)"
echo "signing identity: $CERT_CN ($CERT_SHA)"

# 2. Quit a running instance so the bundle is replaceable. `osascript`
#    handles the AppleEvent-based clean quit; SIGTERM as a fallback for
#    edge cases where the app didn't have a window open to receive the
#    quit event.
osascript -e 'tell application "Mila" to quit' 2>/dev/null || true
sleep 1
pkill -TERM -f "Mila.app/Contents/MacOS/Mila" 2>/dev/null || true
sleep 1

# 3. Replace the installed bundle.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# 4. Re-sign. Pass the cert SHA-1 directly to avoid the trusted-identity
#    requirement of `--sign "Mila Local Dev"`. --force overwrites the
#    existing ad-hoc signature; --deep + the per-framework sweep would
#    matter if frameworks needed re-signing, but the Debug build already
#    has its frameworks signed and we only want to refresh the outer
#    bundle.
codesign --force --sign "$CERT_SHA" \
  --entitlements "$ENT" \
  "$APP_DST" >/dev/null

# 5. Verify the install and surface the Designated Requirement so the
#    user can confirm it's the same hash across runs (= same TCC entry).
echo "designated requirement:"
codesign --display --requirements - "$APP_DST" 2>&1 | grep -v Executable
codesign --verify --verbose "$APP_DST" 2>&1 | tail -2
echo "installed: $APP_DST"
