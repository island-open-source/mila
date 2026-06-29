---
name: uninstall-mila
description: Use when uninstalling, removing, or deleting the Mila transcription app from a Mac — clearing the app bundle, Dock tile, and system caches/preferences while protecting the user's recordings and transcripts. Covers "uninstall Mila", "remove Mila", "delete Mila but keep my recordings".
---

# Uninstall Mila

## Overview

Mila stores user recordings/transcripts and large regenerable assets in the SAME folder (`~/Library/Application Support/Mila`). A naive "delete everything Mila" destroys irreplaceable transcripts. This skill removes the app cleanly while **protecting user data by default** and **never deleting the keep-by-default assets without explicit user confirmation**.

Mila's bundle identifier is **`io.island.whisper.IslandWhisper`** (Island.io origin) — system caches/prefs are filed under that ID, NOT under "Mila". A search for "Mila" alone misses them.

## The Iron Rules

1. **Back up recordings BEFORE deleting anything.** Copy `Recordings/` + `recordings.json` + `folders.json` to a safe location outside Application Support (e.g. `~/Desktop/Mila-Recordings-Backup-<date>`). Verify file counts match before proceeding.
2. **Use `trash`, never `rm`.** Every removal must be reversible.
3. **Keep-by-default items are NOT deleted unless the user says so.** You MUST ASK the user about each one (see below). Default = keep. This includes the **settings/preferences plist** — never wipe the user's configuration as part of a routine uninstall; preserving it means a reinstall comes back with the same model, language, and settings.
4. **Never touch the source repo** (your `mila` checkout, wherever it lives) — only its `build/` output is an app artifact.

## What is what (map before you touch)

| Path | Class | Default action |
|---|---|---|
| `~/Library/Application Support/Mila/Recordings/` | **User data — irreplaceable** | **Always keep + back up** |
| `~/Library/Application Support/Mila/recordings.json` | **User data — the index** | **Always keep + back up** |
| `~/Library/Application Support/Mila/folders.json` | **User data — folder organization** | **Always keep + back up** |
| `~/Library/Application Support/Mila/Models/` (~6.8 GB) | Regenerable (whisper weights, re-downloaded) | **Keep — ASK before deleting** |
| `~/Library/Application Support/Mila/torch-site-packages/` (~444 MB) | Regenerable (Python runtime, re-installed) | **Keep — ASK before deleting** |
| App bundle in `/Applications/Mila.app` | App | Remove |
| Repo `build/` + `~/Library/Developer/Xcode/DerivedData/Mila-*` | Build artifacts (Dock dev build lives here) | Remove |
| `~/Library/Preferences/io.island.whisper.IslandWhisper.plist` | **App settings / UserDefaults** (selected model, language, diarization, LLM config, window state) | **Keep — ASK before deleting** |
| `~/Library/Caches/io.island.whisper.IslandWhisper` | Cache (no user settings) | Remove |
| `~/Library/HTTPStorages/io.island.whisper.IslandWhisper` | HTTP cache | Remove |
| `~/Library/WebKit/io.island.whisper.IslandWhisper` | WebKit data | Remove |
| Dock tile pointing at any `Mila.app` | Dock entry | Remove |

`recordings.json` is the index that ties the audio/transcript files together — it MUST be kept alongside `Recordings/`, or a reinstalled Mila shows an empty library.

## MANDATORY: Ask before deleting keep-by-default items

Before removing the regenerable assets, ask the user explicitly. Default to KEEP if they don't clearly opt in. Recommended question:

> "Mila keeps ~7.2 GB of regenerable data — `Models/` (6.8 GB whisper weights) and `torch-site-packages/` (444 MB Python runtime). Your recordings + `recordings.json` are kept either way. Delete the regenerable data to reclaim space, or keep it so a future reinstall is instant?"

Only delete `Models/` / `torch-site-packages/` if the user chooses to reclaim the space.

**Settings/preferences are also keep-by-default.** Do NOT delete the preferences plist as part of a routine uninstall — it holds the user's configuration (selected model, language, diarization, LLM settings). Only delete it if the user explicitly asks for a **full reset / wipe everything**. If they do, also run `defaults delete io.island.whisper.IslandWhisper` + `killall cfprefsd`, because `cfprefsd` caches prefs in memory and will rewrite the plist on next launch otherwise.

## Procedure

```bash
# 0. Locate the app & confirm bundle id (sanity check before deleting)
mdfind -name "Mila.app" 2>/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /Applications/Mila.app/Contents/Info.plist   # -> io.island.whisper.IslandWhisper

# 1. BACK UP user data first (always). Fail fast: an incomplete backup must
#    NEVER let the uninstall proceed.
set -euo pipefail
SRC="$HOME/Library/Application Support/Mila"
DST="$HOME/Desktop/Mila-Recordings-Backup-$(date +%Y-%m-%d)"
mkdir -p "$DST"
cp -Rp "$SRC/Recordings" "$DST/"
cp -p "$SRC/recordings.json" "$DST/"
[[ -f "$SRC/folders.json" ]] && cp -p "$SRC/folders.json" "$DST/"   # folder map — optional, may not exist yet
# verify before continuing — counts must match, and the index (plus any
# existing folder map) must have copied, or the script aborts here:
echo "src=$(find "$SRC/Recordings" -type f | wc -l)  bak=$(find "$DST/Recordings" -type f | wc -l)"
test -f "$DST/recordings.json"
test ! -e "$SRC/folders.json" || test -f "$DST/folders.json"

# 2. Quit the app if running
pgrep -f "Mila.app/Contents/MacOS" && osascript -e 'quit app "Mila"' || true

# 3. Remove app bundles + build artifacts (to Trash)
trash /Applications/Mila.app 2>/dev/null || true
# Build artifacts — only relevant if Mila was built from source. Point REPO at
# your checkout (or `export MILA_REPO=...`); the project.yml check guards against
# trashing an unrelated build/ tree if REPO is wrong.
REPO="${MILA_REPO:-$HOME/ClonedProjects/mila}"
if [ -f "$REPO/project.yml" ]; then
  trash "$REPO/build" 2>/dev/null || true   # only the build/ output, NOT the repo itself
fi
for d in "$HOME/Library/Developer/Xcode/DerivedData/"Mila-*; do [ -d "$d" ] && trash "$d"; done

# 4. Remove system footprint (bundle id, NOT "Mila").
#    NOTE: the Preferences plist is intentionally EXCLUDED here — it holds the
#    user's settings/configuration and is keep-by-default. Caches/HTTPStorages/
#    WebKit hold no settings and are safe to remove.
BID="io.island.whisper.IslandWhisper"
for p in \
  "$HOME/Library/Caches/$BID" \
  "$HOME/Library/HTTPStorages/$BID" \
  "$HOME/Library/WebKit/$BID" ; do
  [ -e "$p" ] && trash "$p"
done
# NOTE: also reset cfprefsd's in-memory cache if you DID delete the plist, or it
# may be rewritten on next launch: `defaults delete $BID` + `killall cfprefsd`.

# 5. (ONLY IF USER EXPLICITLY OPTED IN) reclaim regenerable data
# trash "$SRC/Models" "$SRC/torch-site-packages"

# 6. (ONLY IF USER WANTS A FULL RESET, incl. settings) remove preferences
# trash "$HOME/Library/Preferences/$BID.plist"
# defaults delete "$BID" 2>/dev/null; killall cfprefsd 2>/dev/null
```

### Remove the Dock tile

`dockutil` is usually not installed; edit the Dock plist directly (filters out any tile whose label is "Mila" or whose URL contains `Mila.app`):

```bash
python3 - <<'PY'
import subprocess, plistlib
pl = plistlib.loads(subprocess.run(["defaults","export","com.apple.dock","-"],capture_output=True).stdout)
apps = pl.get("persistent-apps", [])
def is_mila(e):
    try:
        td = e["tile-data"]
        return td.get("file-label","") == "Mila" or "Mila.app" in td["file-data"].get("_CFURLString","")
    except Exception:
        return False
pl["persistent-apps"] = [e for e in apps if not is_mila(e)]
subprocess.run(["defaults","import","com.apple.dock","-"],input=plistlib.dumps(pl),check=True)
print(f"persistent-apps: {len(apps)} -> {len(pl['persistent-apps'])}")
PY
killall Dock
```

## Verify

```bash
mdfind -name "Mila.app" 2>/dev/null | grep -v "/.Trash/" || echo "(no app outside Trash)"
# Removable footprint should be gone. The Preferences plist is kept by default,
# so it's checked separately below — don't list it here or a routine uninstall
# looks like it failed.
ls -d ~/Library/{Caches/io.island.whisper.IslandWhisper,HTTPStorages/io.island.whisper.IslandWhisper,WebKit/io.island.whisper.IslandWhisper} 2>/dev/null || echo "(removable footprint gone)"
# Preferences plist: present on a routine uninstall (kept), absent only after a full reset.
ls -d ~/Library/Preferences/io.island.whisper.IslandWhisper.plist 2>/dev/null && echo "(prefs kept — routine)" || echo "(prefs removed — full reset)"
defaults read com.apple.dock persistent-apps 2>/dev/null | grep -i mila || echo "(no Mila in Dock)"
# user data intact:
ls "$HOME/Library/Application Support/Mila/Recordings" | wc -l
```

## Common Mistakes

- **Deleting the whole `~/Library/Application Support/Mila` folder.** It contains the irreplaceable `Recordings/` + `recordings.json`. Never blanket-delete it.
- **Searching only for "Mila".** The prefs/caches are under `io.island.whisper.IslandWhisper`. Search the bundle id too.
- **Forgetting `recordings.json` / `folders.json`.** Backing up `Recordings/` without the index leaves a reinstall with an empty library; dropping `folders.json` loses the user's folder organization.
- **Using `rm`.** Always `trash` so the user can recover.
- **Deleting `Models/`/`torch-site-packages/` without asking.** These are keep-by-default; deleting them forces multi-GB re-downloads on reinstall.
- **Wiping the preferences plist on a routine uninstall.** That destroys the user's settings (model, language, diarization, LLM config). Keep it unless the user explicitly wants a full reset — and if they do, clear `cfprefsd` too or it gets rewritten.
- **Trashing the source repo.** Only `build/` inside your `mila` checkout is an artifact; the rest is source.
