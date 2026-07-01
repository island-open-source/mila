# Mila

A macOS (Swift/SwiftUI) local transcription app built on whisper.cpp, with optional speaker diarization via pyannote.audio.

## Architecture

- **Build system:** XcodeGen (`project.yml` is the source of truth, not the .xcodeproj)
- **Minimum deployment target:** macOS 14.0, Swift 5.10
- **Key dependencies:** TranscriptionCore (local Swift package wrapping whisper.cpp), Sparkle (auto-updates)
- **Project layout:**
  - `Mila/Models/` — data models and settings (`Recording`, `DiarizationSettings`, etc.)
  - `Mila/Transcription/` — transcription engine, speaker diarizer, exporter
  - `Mila/Views/` — SwiftUI views (ContentView, SettingsView, SidebarView, etc.)
  - `Mila/Resources/` — Info.plist, entitlements, bundled diarization models
  - `Mila/Resources/DiarizationModels/` — bundled pyannote speaker diarization model weights (~31 MB)
  - `MilaTests/` — unit tests
  - `Packages/TranscriptionCore/` — cross-platform Swift package: WhisperEngine (whisper.cpp bindings), WAVReader, WER calculator, and E2E transcription test fixtures
  - `scripts/` — release/build scripts (make-dmg.sh, etc.)

## Conventions

### Environment Objects
New app-wide settings (like `DiarizationSettings`) must be:
1. Instantiated in `MilaApp.init()` as a `@StateObject`
2. Injected via `.environmentObject()` on both the main window and the Settings scene
3. Accepted in tests via a custom `UserDefaults` suite (not `.standard`) to avoid polluting state

### Python Subprocess Integration
When calling Python ML pipelines from Swift via `Process`:
- Use inline Python scripts via `-c` argument (not bundled .py files) for the main pipeline -- this avoids path-resolution issues with app bundles
- Always separate stdout (JSON data) from stderr (diagnostic logs) -- pyannote and torch emit warnings to stderr that corrupt JSON parsing
- **Drain both pipes concurrently BEFORE `waitUntilExit()`** -- macOS pipe buffers are ~64 KB; if the subprocess fills a pipe before the parent reads, both sides deadlock. Use `Task.detached` to read pipes, then await after `waitUntilExit()`. See `.claude/rules/python-subprocess.md` for the correct pattern.
- Run Python processes on `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Diarization models are bundled in the app (no HuggingFace token needed). The inline script receives the bundle models path as a CLI argument and loads the pipeline from a local config.yaml with `Pipeline.from_pretrained()`
- **Bundled model directory names must preserve the original HuggingFace model ID structure.** pyannote dispatches embedding backends via substring matching on the path (e.g., `"pyannote"` -> torch, `"wespeaker"` -> ONNX). See `.claude/rules/python-subprocess.md` for details.

### Python / PyTorch Compatibility Patches
The pyannote.audio + speechbrain stack requires two runtime monkey-patches (applied in the inline script):
1. **torch.load `weights_only` patch:** PyTorch >= 2.6 changed the default to `True`, breaking pyannote's checkpoint loading. Patch `torch.load` to force `weights_only=False`.
2. **speechbrain LazyModule patch:** pytorch_lightning stack inspection triggers speechbrain's lazy imports for optional packages (k2_fsa, nlp, huggingface.wordemb). Patch `LazyModule.ensure_module` to return a dummy module instead of raising `ImportError`.

These patches live in `SpeakerDiarizer.swift`'s inline diarize script. If upgrading pyannote.audio or speechbrain, check if these patches are still needed.

### Settings Persistence with UserDefaults
- Use namespaced keys: `"diarization.enabled"`, `"diarization.pythonPath"`, etc.
- For verification/setup state that should survive app restarts, persist a `verified` flag alongside the verified parameter values (path). On launch, restore only if current values match the persisted ones.
- Computed `status` properties must check `verificationStatus` before `lastVerifyResult` -- the persisted verified state should take precedence over nil in-memory verify results on launch.

### Tests
- `TranscriptionService` now requires a `diarizationSettings:` parameter. In tests, always pass `DiarizationSettings(defaults: .init(suiteName: "TestClassName.diarization")!)` to isolate from user defaults.
- Run tests with `make test` or via Xcode.

### Logging
- **Where:** the app writes a plain-text log to `~/Library/Logs/Mila/mila.log`.
  Tail it with `make logs`. It is truncated when it grows past ~5 MB.
- **When it's active:** file logging is set up by `redirectMilaLogsToFile()` (the
  first line of `MilaApp.init()`), which redirects `stdout`/`stderr` to the file.
  It is **skipped when the app is attached to a TTY** (`guard isatty(STDERR_FILENO) == 0`)
  so that running under Xcode or a terminal still prints to the console. Practical
  upshot: a **Finder/`open` launch logs to the file** (use `make reinstall`), but a
  terminal launch (e.g. `make run`, or running the binary directly) does **not** —
  it prints to the console instead.
- **Scope (what lands in the file):**
  1. Every `print(...)` in the app (most transcription-pipeline diagnostics).
  2. Every `MilaLog` call. `MilaLog` (see `Mila/App/MilaLog.swift`) is the
     app-wide logger that replaced raw `os.Logger`; it mirrors each entry to
     **both** the unified log (`os.Logger`, subsystem `io.island.whisper.IslandWhisper`)
     **and** stdout, so subsystem logs (VoiceMemos, ModelManager, MeetingDetector,
     RemoteWhisperEngine, etc.) appear in the file prefixed with `[Category]`.
- **New logging:** prefer `MilaLog` over `os.Logger`/`print` for new code so output
  reaches both sinks. It accepts the same interpolation as `os.Logger`, including
  `"\(value, privacy: .public)"`.
- **Unified log alternative:** os_log entries are also visible in Console.app or via
  `log show --predicate 'subsystem == "io.island.whisper.IslandWhisper"' --info`
  (note: `.info`/`.debug` levels are not persisted by default).

## Release Process
- **Release notes are REQUIRED, first.** Every release must add
  `RELEASE_NOTES/v<MARKETING_VERSION>.md` (Markdown, user-facing). This file
  becomes the Sparkle appcast `<description>` — i.e. the in-app "What's New"
  popup users see on update. Without it that popup is blank ("a new version is
  available" with no changelog). The signing pipeline runs
  `scripts/check-release-notes.sh <version>` **before building** and FAILS the
  release if the file is missing/empty/boilerplate, so this can't be skipped.
  Do NOT rely on the `project.yml` changelog comment or the GitHub Release body —
  neither feeds the appcast. See `RELEASE_NOTES/README.md`.
- Version is bumped only in `project.yml` (`MARKETING_VERSION` +
  `CURRENT_PROJECT_VERSION`). `Info.plist` inherits both via
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` — never hardcode
  literals there.
- Tags are `v`-prefixed: `v1.2.8`. `CURRENT_PROJECT_VERSION` (the build
  number) must increase monotonically — Sparkle keys updates on it.
- A local, unsigned DMG for testing: `make dmg` (ad-hoc signed; Gatekeeper
  shows the right-click → Open prompt on first launch).
- Notarized, signed release builds and Sparkle appcast publishing are produced
  by a separate, private signing pipeline maintained by the original authors;
  that toolchain is not part of this repository. Forks that want notarized
  builds should sign with their own Apple Developer ID and publish their own
  appcast (see `SUFeedURL` / `SUPublicEDKey` in `project.yml`).
