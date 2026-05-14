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

## Known Compatibility Patches
These monkey-patches are required as of pyannote.audio 3.x + PyTorch >= 2.6 + speechbrain:

1. `torch.load` weights_only patch (PyTorch 2.6+ changed default)
2. speechbrain `LazyModule.ensure_module` patch (pytorch_lightning stack inspection triggers lazy imports)

If a future pyannote or speechbrain release fixes these, the patches can be removed. Check on each dependency upgrade.

## Dependency Installation
- Use `python3 -m pip install` (not bare `pip`) to ensure the correct Python environment
- Pin `huggingface_hub<1.0` to avoid breaking changes in the HF API
- The Settings UI handles dep installation via `SpeakerDiarizer.installDependencies()`
