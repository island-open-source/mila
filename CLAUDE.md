# IslandWhisper

A macOS (Swift/SwiftUI) local transcription app built on whisper.cpp, with optional speaker diarization via pyannote.audio.

## Architecture

- **Build system:** XcodeGen (`project.yml` is the source of truth, not the .xcodeproj)
- **Minimum deployment target:** macOS 14.0, Swift 5.10
- **Key dependencies:** WhisperBinary (local Swift package wrapping whisper.cpp), Sparkle (auto-updates)
- **Project layout:**
  - `IslandWhisper/Models/` — data models and settings (`Recording`, `DiarizationSettings`, etc.)
  - `IslandWhisper/Transcription/` — transcription engine, speaker diarizer, exporter
  - `IslandWhisper/Views/` — SwiftUI views (ContentView, SettingsView, SidebarView, etc.)
  - `IslandWhisper/Resources/` — Info.plist, entitlements, bundled diarization models
  - `IslandWhisper/Resources/DiarizationModels/` — bundled pyannote speaker diarization model weights (~31 MB)
  - `IslandWhisperTests/` — unit tests
  - `Packages/WhisperBinary/` — local Swift package for whisper.cpp C bindings
  - `scripts/` — release/build scripts (make-dmg.sh, etc.)

## Conventions

### Environment Objects
New app-wide settings (like `DiarizationSettings`) must be:
1. Instantiated in `IslandWhisperApp.init()` as a `@StateObject`
2. Injected via `.environmentObject()` on both the main window and the Settings scene
3. Accepted in tests via a custom `UserDefaults` suite (not `.standard`) to avoid polluting state

### Python Subprocess Integration
When calling Python ML pipelines from Swift via `Process`:
- Use inline Python scripts via `-c` argument (not bundled .py files) for the main pipeline -- this avoids path-resolution issues with app bundles
- Always separate stdout (JSON data) from stderr (diagnostic logs) -- pyannote and torch emit warnings to stderr that corrupt JSON parsing
- Run Python processes on `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Diarization models are bundled in the app (no HuggingFace token needed). The inline script receives the bundle models path as a CLI argument and loads the pipeline from a local config.yaml with `Pipeline.from_pretrained()`

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

## Release Process
See `.cursor/rules/release.mdc` for the full release SOP. Key points:
- Version is bumped only in `project.yml` (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`)
- Tags are `v`-prefixed: `v1.2.8`
- DMG is ad-hoc signed; internal distribution only
