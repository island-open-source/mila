---
name: build-mila-locally
description: Use when building, compiling, or running the Mila app locally from source on a Mac — debug build, release build, self-signed DMG, or installing a locally-built Mila into /Applications. Covers "build Mila", "run Mila locally", "make a DMG", "install my local build", and the common version/signing/PythonRuntime build failures.
---

# Build Mila Locally

## Overview

Mila builds via **XcodeGen** (`project.yml` is the source of truth, NOT the `.xcodeproj`) driven by a `Makefile`. Local builds are **ad-hoc signed** ("Sign to Run Locally") — that is the only "self-signed" path this repo supports. Notarized Developer-ID builds come from a separate private pipeline and are out of scope here.

All build commands run from the repo root (wherever your checkout lives).

## Quick Reference

| Goal | Command | Output |
|---|---|---|
| Generate Xcode project | `make project` | `Mila.xcodeproj` (regenerated from `project.yml`) |
| Debug build | `make build` | `build/Build/Products/Debug/Mila.app` |
| Build **and launch** | `make run` | builds Debug, then `open`s it |
| Release build | `make release-build` | `build-release/Build/Products/Release/Mila.app` |
| Self-signed DMG | `make dmg VERSION=<x.y.z>` | `Mila-<x.y.z>.dmg` (ad-hoc signed) |
| Run tests | `make test` | XCTest run |
| Clean | `make clean` | removes `Mila.xcodeproj`, `build`, `build-release`, `*.dmg` |

`make` targets chain: `dmg → release-build → project → bootstrap`, so a single command regenerates the project and builds.

## CRITICAL: `make dmg` needs an explicit VERSION

`make dmg` **fails on a clean checkout** with:

```text
/bin/sh: MARKETING_VERSION: command not found
./scripts/make-dmg.sh: ... usage: make-dmg.sh APP_PATH DMG_PATH VERSION
```

**Why:** the Makefile's `VERSION` fallback reads `CFBundleShortVersionString` from `Info.plist`, but that key stores the literal `$(MARKETING_VERSION)` (Xcode resolves it only at build time). Make passes that literal into the recipe, the shell tries to *command-substitute* `$(MARKETING_VERSION)` — hence the `MARKETING_VERSION: command not found` line — and `VERSION` collapses to an empty string. `scripts/make-dmg.sh` then aborts on its empty-`VERSION` guard (`${3:?usage…}`). The release build itself SUCCEEDS — only DMG packaging breaks.

**Fix:** the canonical version lives in `project.yml` (`MARKETING_VERSION`). Pass it explicitly:

```bash
VERSION=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/{print $2; exit}' project.yml)
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
make dmg VERSION="$VERSION"
```

## Other known build gotchas

- **PythonRuntime placeholder:** `Mila/Resources/PythonRuntime/` is a `.gitignored` folder reference. If missing, `xcodebuild` fails on the copy-resources phase. The `make project` target auto-creates an empty placeholder (the app falls back to system Python for diarization). For a *real* bundled diarization runtime, run `make bundle-diarization` first (~150-200 MB, slow, cached).
- **Models are NOT bundled.** Whisper weights download at first launch into `~/Library/Application Support/Mila/Models/` (or pre-fetch with `make models`, ~4.6 GB). A fresh build with no models will prompt/download on first transcription.
- **`xcodegen` must be installed.** `make bootstrap` installs it via Homebrew if missing.

## Verifying the signature

A correct local build is ad-hoc signed:
```bash
codesign -dv /Applications/Mila.app 2>&1 | grep -E "Identifier|Signature"
# Identifier=io.island.whisper.IslandWhisper
# Signature=adhoc
```

## Installing a local build into /Applications

A `make run`/`make dmg` build lives in the repo's `build/` folder — it runs fine but won't appear in the Applications folder. To install it like a normal app:

```bash
# from a DMG (preferred — matches the distributed artifact):
MNT=$(mktemp -d)
hdiutil attach Mila-<x.y.z>.dmg -nobrowse -mountpoint "$MNT" -quiet
[ -e /Applications/Mila.app ] && trash /Applications/Mila.app          # use trash, not rm
cp -R "$MNT/Mila.app" /Applications/
hdiutil detach "$MNT" -quiet
open -a /Applications/Mila.app    # verify it launches
```

Ad-hoc-signed apps copied (not downloaded) have no quarantine flag, so they launch without the Gatekeeper right-click dance. If the app WAS downloaded, Gatekeeper shows a "right-click → Open" prompt on first launch.

## Common Mistakes

- **Running `make dmg` without `VERSION=`** → the `MARKETING_VERSION: command not found` failure above. Always pass it.
- **Editing `Mila.xcodeproj` directly** → overwritten on next `make project`. Edit `project.yml` instead.
- **Hardcoding a version in `Info.plist`** → it must stay `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`; bump versions only in `project.yml`.
- **Expecting a Developer-ID / notarized build** → not available locally; this repo only ad-hoc signs.
- **`rm`-ing an old `/Applications/Mila.app`** → use `trash` so it's recoverable.
