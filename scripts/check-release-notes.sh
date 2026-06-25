#!/usr/bin/env bash
#
# Release-notes gate.
#
# Asserts that RELEASE_NOTES/v<version>.md exists and contains real,
# user-facing notes — NOT empty and NOT the auto-generated boilerplate.
#
# WHY THIS EXISTS: the signing/publish pipeline turns RELEASE_NOTES/v<version>.md
# into the Sparkle appcast <description> for the release, which is exactly what
# Mila's in-app "What's New" popup shows on update. When that file is missing,
# the popup degrades to a bare "a new version is available" with no changelog.
# The pipeline runs this check BEFORE the (long) build so a release can never
# silently ship empty release notes.
#
# Usage:
#   scripts/check-release-notes.sh <marketing-version>
#   e.g. scripts/check-release-notes.sh 1.8.14
#
# Exits 0 when the notes are present and real; non-zero (with guidance) otherwise.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/check-release-notes.sh <marketing-version>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES="$ROOT/RELEASE_NOTES/v${VERSION}.md"

if [[ ! -f "$NOTES" ]]; then
  cat >&2 <<EOF
ERROR: missing release notes for v${VERSION}.

  Create:  RELEASE_NOTES/v${VERSION}.md   (Markdown, user-facing)

It becomes the Sparkle appcast <description> — the in-app "What's New" shown
when users update. See RELEASE_NOTES/README.md.
EOF
  exit 1
fi

# Real content = everything that isn't blank, an HTML comment, or a heading.
CONTENT="$(grep -vE '^[[:space:]]*(<!--.*-->|#|$)' "$NOTES" | tr -d '[:space:]' || true)"
if [[ -z "$CONTENT" ]]; then
  echo "ERROR: RELEASE_NOTES/v${VERSION}.md is empty / has no real notes." >&2
  exit 1
fi

# Reject leftover stubs / the known auto-created GitHub Release boilerplate so a
# half-filled template can't slip through.
if grep -qiE 'Notarized; auto-updates via Sparkle|TODO|FIXME|REPLACE ?ME|<fill[ -]?in>|XXX' "$NOTES"; then
  echo "ERROR: RELEASE_NOTES/v${VERSION}.md still contains boilerplate / TODO text." >&2
  echo "       Write the actual user-facing changes for ${VERSION}." >&2
  exit 1
fi

echo "OK: RELEASE_NOTES/v${VERSION}.md present with real notes."
