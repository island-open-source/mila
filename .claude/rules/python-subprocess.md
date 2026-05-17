# Python Subprocess Integration in Swift

When integrating Python ML pipelines (pyannote.audio, torch, speechbrain) into this macOS app:

## Process Setup
- Use `Process` with `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Pass the Python script inline via `-c` argument, not as a file path -- app bundle path resolution is fragile
- Diarization models are bundled in the app — the models directory path is passed as a CLI argument to the inline script
- Always capture stdout and stderr into separate Pipes

## stdout/stderr Separation
Python ML libraries (torch, speechbrain, pyannote) emit copious warnings and progress info to stderr. The diarization script outputs structured JSON to stdout. If you mix them (or read only one), JSON parsing breaks silently. Always:
1. Read stdout for data (JSON)
2. Read stderr for diagnostics/error messages
3. Log stderr content for debugging but never try to parse it as data

## Pipe Drain Ordering (Deadlock Prevention)
**Always drain stdout and stderr pipes BEFORE calling `process.waitUntilExit()`.** On macOS (and POSIX generally), pipe buffers are ~64 KB. If a subprocess fills a pipe buffer before the parent reads from it, the subprocess blocks on `write()`. If the parent is blocked on `waitUntilExit()`, neither side can make progress -- classic deadlock.

This is not theoretical: it caused transcription to hang at 100% on files longer than ~25 minutes (PR #15), because pyannote's stderr logging exceeded the buffer on long runs.

**Correct pattern:**
```swift
let stdoutRead = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
let stderrRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

process.waitUntilExit()

let stdoutData = await stdoutRead.value
let stderrData = await stderrRead.value
```

**Why `Task.detached` instead of `DispatchGroup`:** In Swift 6 strict concurrency, calling `DispatchGroup.wait()` inside an async context triggers a warning (blocking a cooperative thread). `Task.detached` with `await` is the idiomatic async-safe alternative.

**Wrong pattern (will deadlock on large output):**
```swift
process.waitUntilExit()
let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()  // too late
let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
```

## Known Compatibility Patches
These monkey-patches are required as of pyannote.audio 3.x + PyTorch >= 2.6 + speechbrain:

1. `torch.load` weights_only patch (PyTorch 2.6+ changed default)
2. speechbrain `LazyModule.ensure_module` patch (pytorch_lightning stack inspection triggers lazy imports)

If a future pyannote or speechbrain release fixes these, the patches can be removed. Check on each dependency upgrade.

## Bundled Model Path Naming
When bundling ML models that are normally loaded via HuggingFace model IDs (e.g., `pyannote/wespeaker-voxceleb-resnet34-LM`), the local directory names must preserve the original model ID structure. ML frameworks like pyannote use **substring matching on the file path** to dispatch to different backends:
- A path containing `"pyannote"` routes to the **torch** backend
- A path containing `"wespeaker"` (without `"pyannote"`) routes to the **ONNX** backend (requires onnxruntime)

The bundled directory must be named to match the same substring the framework expects. For example, `pyannote-wespeaker-voxceleb-resnet34-LM` (preserving the `pyannote` prefix) -- not just `wespeaker-voxceleb-resnet34-LM`. This applies to any model where the framework infers behavior from the path string rather than from metadata inside the model files.

**Why:** This caused a production bug (PR #14) where diarization silently failed because the wrong embedding backend was selected based on the directory name.

## Dependency Installation
- Use `python3 -m pip install` (not bare `pip`) to ensure the correct Python environment
- Pin `huggingface_hub<1.0` to avoid breaking changes in the HF API
- The Settings UI handles dep installation via `SpeakerDiarizer.installDependencies()`
