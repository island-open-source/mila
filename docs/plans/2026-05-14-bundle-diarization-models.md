# Bundle Pyannote Diarization Models Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bundle the pyannote speaker diarization model weights (~31 MB) into the app bundle so users no longer need a HuggingFace token or internet access for diarization.

**Architecture:** Ship the three model artifacts (config.yaml, segmentation pytorch_model.bin, wespeaker embedding pytorch_model.bin) as app Resources. Modify the config.yaml to reference the sub-models by local file path instead of HF model ID. The inline Python diarize script receives the bundle path as a CLI argument and calls `Pipeline.from_pretrained(local_config_path)`. The HF token is removed from the settings flow entirely — the only prerequisites become Python + pyannote.audio installed.

**Tech Stack:** Swift/SwiftUI, XcodeGen (project.yml), pyannote.audio Pipeline (Python)

---

### Task 1: Copy model files into Resources

**Files:**
- Create: `IslandWhisper/Resources/DiarizationModels/config.yaml`
- Create: `IslandWhisper/Resources/DiarizationModels/segmentation-3.0/pytorch_model.bin`
- Create: `IslandWhisper/Resources/DiarizationModels/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin`

**Step 1: Create the directory structure and copy files**

```bash
mkdir -p IslandWhisper/Resources/DiarizationModels/segmentation-3.0
mkdir -p IslandWhisper/Resources/DiarizationModels/wespeaker-voxceleb-resnet34-LM

# Copy model weights from HF cache
cp ~/.cache/huggingface/hub/models--pyannote--segmentation-3.0/snapshots/*/pytorch_model.bin \
   IslandWhisper/Resources/DiarizationModels/segmentation-3.0/

cp ~/.cache/huggingface/hub/models--pyannote--wespeaker-voxceleb-resnet34-LM/snapshots/*/pytorch_model.bin \
   IslandWhisper/Resources/DiarizationModels/wespeaker-voxceleb-resnet34-LM/
```

**Step 2: Create modified config.yaml**

The original config.yaml references sub-models by HF ID (`pyannote/segmentation-3.0`, `pyannote/wespeaker-voxceleb-resnet34-LM`). We need placeholders that the Python script will replace at runtime with the actual bundle paths.

Write `IslandWhisper/Resources/DiarizationModels/config.yaml`:

```yaml
version: 3.1.0

pipeline:
  name: pyannote.audio.pipelines.SpeakerDiarization
  params:
    clustering: AgglomerativeClustering
    embedding: __MODELS_DIR__/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin
    embedding_batch_size: 32
    embedding_exclude_overlap: true
    segmentation: __MODELS_DIR__/segmentation-3.0/pytorch_model.bin
    segmentation_batch_size: 32

params:
  clustering:
    method: centroid
    min_cluster_size: 12
    threshold: 0.7045654963945799
  segmentation:
    min_duration_off: 0.0
```

**Step 3: Commit**

```bash
git add IslandWhisper/Resources/DiarizationModels/
git commit -m "feat: add bundled pyannote diarization model weights"
```

---

### Task 2: Update project.yml to include model resources

**Files:**
- Modify: `project.yml:40-41`

**Step 1: Add the DiarizationModels resource path**

In `project.yml`, under the `resources:` key for the IslandWhisper target, add:

```yaml
    resources:
      - path: IslandWhisper/Assets.xcassets
      - path: IslandWhisper/Resources/DiarizationModels
```

**Step 2: Regenerate the Xcode project**

```bash
xcodegen generate
```

**Step 3: Verify the models appear in the generated project**

```bash
grep -r "DiarizationModels" IslandWhisper.xcodeproj/project.pbxproj | head -5
```

Expected: lines showing DiarizationModels files in the build resources.

**Step 4: Commit**

```bash
git add project.yml IslandWhisper.xcodeproj/
git commit -m "build: include diarization models in app bundle resources"
```

---

### Task 3: Update SpeakerDiarizer.diarize to load from bundle

**Files:**
- Modify: `IslandWhisper/Transcription/SpeakerDiarizer.swift:79-138`

**Step 1: Add a helper to resolve the bundle models path**

Add to `SpeakerDiarizer` enum:

```swift
private static var bundledModelsPath: String? {
    Bundle.main.path(forResource: "DiarizationModels", ofType: nil)
}
```

**Step 2: Update the `diarize` method signature**

Remove the `hfToken` parameter — it's no longer needed. Add `modelsPath` instead:

```swift
static func diarize(wavURL: URL, pythonPath: String) async throws -> [SpeakerTurn] {
    guard let modelsPath = bundledModelsPath else {
        throw Error.diarizationFailed("Bundled diarization models not found in app")
    }
```

**Step 3: Update the inline Python script**

The script should:
1. Read the models directory path from `sys.argv[2]`
2. Read config.yaml, replace `__MODELS_DIR__` with the actual path
3. Write a temp config, load the pipeline from it

Replace the current diarize script with:

```python
import json, sys, os, types, tempfile

try:
    import speechbrain.utils.importutils as _sbiu
    _orig_ensure = _sbiu.LazyModule.ensure_module
    def _safe_ensure(self, *a, **kw):
        try:
            return _orig_ensure(self, *a, **kw)
        except ImportError:
            self.lazy_module = types.ModuleType(self.target)
            return self.lazy_module
    _sbiu.LazyModule.ensure_module = _safe_ensure
except Exception:
    pass

import torch
_orig_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    kwargs["weights_only"] = False
    return _orig_torch_load(*args, **kwargs)
torch.load = _patched_torch_load

from pyannote.audio import Pipeline

wav_path = sys.argv[1]
models_dir = sys.argv[2]

config_path = os.path.join(models_dir, "config.yaml")
with open(config_path) as f:
    config_text = f.read().replace("__MODELS_DIR__", models_dir)

tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
tmp.write(config_text)
tmp.close()

try:
    print(f"diarize: loading pipeline from {models_dir}", file=sys.stderr)
    pipeline = Pipeline.from_pretrained(tmp.name)
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
        print(f"diarize: using MPS", file=sys.stderr)

    print(f"diarize: running on {wav_path}", file=sys.stderr)
    diar = pipeline(wav_path)
    annotation = getattr(diar, "speaker_diarization", diar)

    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({
            "start": round(turn.start, 3),
            "end": round(turn.end, 3),
            "speaker": speaker,
        })

    print(f"diarize: found {len(set(t['speaker'] for t in turns))} speakers, {len(turns)} turns", file=sys.stderr)
    json.dump(turns, sys.stdout)
finally:
    os.unlink(tmp.name)
```

**Step 4: Update the Python invocation to pass modelsPath**

```swift
let result = try await runPython(
    path: pythonPath,
    arguments: ["-c", script, wavURL.path, modelsPath],
    environment: [:]
)
```

Note: no `HF_TOKEN` in environment any more.

**Step 5: Commit**

```bash
git add IslandWhisper/Transcription/SpeakerDiarizer.swift
git commit -m "feat: load diarization pipeline from bundled models"
```

---

### Task 4: Remove HF token from DiarizationSettings

**Files:**
- Modify: `IslandWhisper/Models/DiarizationSettings.swift`

**Step 1: Remove the hfToken property and all token-related logic**

Remove:
- The `hfToken` published property (line 14-18)
- The `KeychainHelper.load/save` for `diarization.hfToken` in init (lines 34-41)
- `KeychainHelper.save/delete` for `diarization.verifiedToken` in `persistVerified`/`clearVerified` (lines 54, 61)
- Token comparison in `invalidateIfChanged` (line 66)
- Token comparison in `restoreVerifiedState` (lines 76-78)

Update:
- `isConfigured` (line 84): change from `isEnabled && !hfToken.isEmpty` to just `isEnabled`
- `canVerify` (line 181): remove `!hfToken.isEmpty` check
- `checkDeps` and `verify` methods: remove `hfToken:` from `verifySetup` calls

**Step 2: Simplify verification state**

The verified state no longer depends on a token match. Simplify `invalidateIfChanged` to only check `pythonPath`:

```swift
private func invalidateIfChanged() {
    let savedPath = defaults.string(forKey: "diarization.verifiedPythonPath") ?? ""
    if pythonPath != savedPath {
        clearVerified()
        verificationStatus = .disabled
        lastVerifyResult = nil
    }
}
```

Simplify `persistVerified`:

```swift
private func persistVerified() {
    defaults.set(true, forKey: "diarization.verified")
    defaults.set(pythonPath, forKey: "diarization.verifiedPythonPath")
}
```

Simplify `clearVerified`:

```swift
private func clearVerified() {
    defaults.set(false, forKey: "diarization.verified")
    defaults.removeObject(forKey: "diarization.verifiedPythonPath")
}
```

Simplify `restoreVerifiedState`:

```swift
private func restoreVerifiedState() {
    guard isEnabled && isVerified else { return }
    let savedPath = defaults.string(forKey: "diarization.verifiedPythonPath") ?? ""
    if pythonPath == savedPath && pythonFound {
        verificationStatus = .verified
    }
}
```

**Step 3: Commit**

```bash
git add IslandWhisper/Models/DiarizationSettings.swift
git commit -m "refactor: remove HF token from diarization settings"
```

---

### Task 5: Update SpeakerDiarizer.verifySetup to skip model access checks

**Files:**
- Modify: `IslandWhisper/Transcription/SpeakerDiarizer.swift:140-210`

**Step 1: Remove hfToken parameter and model access checks**

Since models are bundled, `verifySetup` only needs to check:
1. pyannote.audio is installed
2. torch is installed

Update `verifySetup`:

```swift
static func verifySetup(pythonPath: String) async throws -> VerifyResult {
    let script = """
    import json, sys

    result = {
        "pyannoteInstalled": False,
        "torchInstalled": False,
        "models": [],
    }

    try:
        import pyannote.audio
        result["pyannoteInstalled"] = True
    except ImportError:
        pass

    try:
        import torch
        result["torchInstalled"] = True
    except ImportError:
        pass

    json.dump(result, sys.stdout)
    """

    let result = try await runPython(
        path: pythonPath,
        arguments: ["-c", script]
    )
    guard !result.stdout.isEmpty else {
        let errMsg = String(data: result.stderr, encoding: .utf8) ?? "no output"
        throw Error.diarizationFailed(errMsg)
    }
    return try JSONDecoder().decode(VerifyResult.self, from: result.stdout)
}
```

**Step 2: Update VerifyResult.allGood**

Since there are no model checks, `allGood` simplifies to:

```swift
var allGood: Bool {
    pyannoteInstalled && torchInstalled
}
```

**Step 3: Update callers in DiarizationSettings**

In `checkDeps()` and `verify()`, remove `hfToken:` parameter:

```swift
let result = try await SpeakerDiarizer.verifySetup(pythonPath: pythonPath)
```

**Step 4: Commit**

```bash
git add IslandWhisper/Transcription/SpeakerDiarizer.swift IslandWhisper/Models/DiarizationSettings.swift
git commit -m "refactor: simplify verifySetup — models are bundled"
```

---

### Task 6: Remove token UI from SettingsView

**Files:**
- Modify: `IslandWhisper/Views/SettingsView.swift:479-748`

**Step 1: Remove the entire tokenSection view**

Delete the `tokenSection` computed property (lines 621-651).

**Step 2: Remove tokenSection reference from body**

In `DiarizationSettingsTab.body`, remove the block that conditionally shows `tokenSection` (lines 505-511):

```swift
// Step 2: token + model access — only after deps are OK
if !diarization.needsDepsInstall,
   let result = diarization.lastVerifyResult,
   result.pyannoteInstalled && result.torchInstalled {
    Divider()
    tokenSection
}
```

**Step 3: Simplify the verify section gate**

Change the `canVerify` gate (line 514) — with no token requirement, verify should show after deps are OK:

```swift
if !diarization.needsDepsInstall,
   let result = diarization.lastVerifyResult,
   result.pyannoteInstalled && result.torchInstalled {
    Divider()
    verifySection
}
```

**Step 4: Remove model checklist from verify results**

In `verifyResultChecklist` (lines 713-733), the `result.models` list will now always be empty, so that `ForEach` becomes dead code. Replace the verify result display with a simple success/fail indicator:

```swift
@ViewBuilder
private func verifyResultChecklist(_ result: SpeakerDiarizer.VerifyResult) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        verifyCheckRow("pyannote.audio", ok: result.pyannoteInstalled,
                       detail: result.pyannoteInstalled ? nil : "Run 'Install dependencies' above")
        verifyCheckRow("torch", ok: result.torchInstalled,
                       detail: result.torchInstalled ? nil : "Run 'Install dependencies' above")
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(result.allGood ? .green.opacity(0.08) : .red.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6))
}
```

**Step 5: Remove the "terms not accepted" error handling**

In `verifySection` (around line 700-708), remove the `.verificationFailed` check for "not accepted":

```swift
// DELETE this block:
} else if case .verificationFailed(let msg) = status, msg.contains("not accepted") {
    Text("Open the model links above...")
    ...
}
```

**Step 6: Update the description text**

Update the intro text (line 494) — remove "no audio leaves your machine" since that's about whisper, not diarization. The key message is that models are now built-in:

```swift
Text("Identify who is speaking in your recordings. Speaker models are included — just install Python dependencies to get started.")
```

**Step 7: Commit**

```bash
git add IslandWhisper/Views/SettingsView.swift
git commit -m "ui: remove HF token from diarization settings, simplify setup flow"
```

---

### Task 7: Update TranscriptionService caller

**Files:**
- Modify: `IslandWhisper/Transcription/TranscriptionService.swift:236-248`

**Step 1: Remove hfToken from the diarize call**

Change:

```swift
let shouldDiarize = diarizationSettings.isConfigured
let diarHfToken = diarizationSettings.hfToken
let diarPythonPath = diarizationSettings.pythonPath
```

To:

```swift
let shouldDiarize = diarizationSettings.isConfigured
let diarPythonPath = diarizationSettings.pythonPath
```

And change the diarize call:

```swift
let turns = try await SpeakerDiarizer.diarize(
    wavURL: audioURL,
    hfToken: diarHfToken,
    pythonPath: diarPythonPath
)
```

To:

```swift
let turns = try await SpeakerDiarizer.diarize(
    wavURL: audioURL,
    pythonPath: diarPythonPath
)
```

**Step 2: Commit**

```bash
git add IslandWhisper/Transcription/TranscriptionService.swift
git commit -m "refactor: remove hfToken from diarize call"
```

---

### Task 8: Update tests

**Files:**
- Modify: `IslandWhisperTests/` — any tests referencing `hfToken`

**Step 1: Find and update test references**

```bash
grep -rn "hfToken\|hf_token\|HF_TOKEN" IslandWhisperTests/
```

Update any test that passes `hfToken` to `DiarizationSettings` or `SpeakerDiarizer` methods to remove that parameter.

**Step 2: Run tests**

```bash
make test
```

Expected: all tests pass.

**Step 3: Commit**

```bash
git add IslandWhisperTests/
git commit -m "test: update tests for token-free diarization"
```

---

### Task 9: Clean up KeychainHelper token references

**Files:**
- Modify: `IslandWhisper/Models/DiarizationSettings.swift` (already done in Task 4)
- Check: Any other files referencing `diarization.hfToken` or `diarization.verifiedToken` keychain keys

**Step 1: Search for remaining token references**

```bash
grep -rn "hfToken\|hf_token\|HF_TOKEN\|verifiedToken" IslandWhisper/
```

Remove any remaining references not caught in earlier tasks.

**Step 2: Build and run**

```bash
xcodegen generate && xcodebuild -scheme IslandWhisper build
```

**Step 3: Commit if changes**

```bash
git add -A && git commit -m "chore: clean up remaining HF token references"
```

---

### Task 10: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update conventions**

- Remove mention of `HF_TOKEN` env var in Python Subprocess Integration section
- Update the Python / PyTorch Compatibility Patches section if needed
- Note that diarization models are bundled in `IslandWhisper/Resources/DiarizationModels/`

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for bundled diarization models"
```
