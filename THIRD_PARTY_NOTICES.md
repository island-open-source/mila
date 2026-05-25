# Third-Party Notices

Mila includes, depends on, or downloads at runtime the following third-party software. All notices are reproduced or summarized here in fulfillment of the attribution clauses in their respective licenses.

The list is split between (a) components bundled inside the `Mila.app` binary that we redistribute, and (b) components downloaded by the user from the upstream's own servers when a related feature is used.

---

## A. Bundled in the .app

### whisper.cpp xcframework (MIT)

Used as the on-device Whisper inference engine via TranscriptionCore's Swift binding. Pulled in as a binary Swift Package Manager target.

- Project: https://github.com/ggml-org/whisper.cpp
- License: MIT — https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE
- Copyright © Georgi Gerganov and whisper.cpp contributors.

### Sparkle (MIT)

Used for in-app auto-updates.

- Project: https://github.com/sparkle-project/Sparkle
- License: MIT — https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
- Copyright © Sparkle Project and contributors.

### pyannote/segmentation-3.0 model weights (MIT)

Bundled at `Mila/Resources/DiarizationModels/segmentation-3.0/pytorch_model.bin`. Loaded by the pyannote.audio speaker-diarization pipeline.

- Upstream: https://huggingface.co/pyannote/segmentation-3.0
- License: MIT (per upstream model card).
- Copyright © Hervé Bredin and the pyannote.audio authors.

### pyannote-wespeaker-voxceleb-resnet34-LM model weights

Bundled at `Mila/Resources/DiarizationModels/pyannote-wespeaker-voxceleb-resnet34-LM/pytorch_model.bin`. Loaded as the speaker-embedding model for the diarization pipeline.

- Upstream: https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
- Upstream WeSpeaker project: https://github.com/wenet-e2e/wespeaker (Apache-2.0)
- License: per the upstream model card; the WeSpeaker repository itself is Apache-2.0.

---

## B. Downloaded by the user from a third party at runtime

These components are fetched from the upstream's own CDN or package repository when the relevant feature is used. Mila orchestrates the download but does not redistribute the bytes — the upstream serves them directly. Each component's license attaches at the moment of installation; the upstream packages include their own license texts.

### Whisper model weights — OpenAI (MIT)

`large-v3-turbo` and any other OpenAI Whisper ggml repackagings fetched from `huggingface.co/ggerganov/whisper.cpp`.

- Original project: https://github.com/openai/whisper
- License: MIT — https://github.com/openai/whisper/blob/main/LICENSE
- Copyright © OpenAI.

### Whisper model weights — ivrit.ai (Apache-2.0)

`ivrit-ai/whisper-large-v3-ggml` Hebrew finetune, fetched from `huggingface.co/ivrit-ai`.

- Project: https://www.ivrit.ai / https://huggingface.co/ivrit-ai
- License: Apache-2.0 (per upstream model card).
- Copyright © ivrit.ai.

### PyTorch / torchaudio (BSD-3-Clause)

Wheels fetched on first launch from `download.pytorch.org`. Installed into a user-writable site-packages directory at `~/Library/Application Support/Mila/torch-site-packages/`.

- Project: https://pytorch.org
- License: BSD-3-Clause — https://github.com/pytorch/pytorch/blob/main/LICENSE
- Copyright © Meta Platforms and PyTorch contributors.

### pyannote.audio + transitive dependencies

Installed from PyPI via `pip install` into the bundled Python runtime when diarization is used.

| Package | License | Upstream |
|---|---|---|
| `pyannote.audio` | MIT | https://github.com/pyannote/pyannote-audio |
| `speechbrain` | Apache-2.0 | https://github.com/speechbrain/speechbrain |
| `pytorch-lightning` | Apache-2.0 | https://github.com/Lightning-AI/lightning |
| `huggingface_hub` | Apache-2.0 | https://github.com/huggingface/huggingface_hub |
| `soundfile` | BSD-3-Clause | https://github.com/bastibe/python-soundfile |
| `numpy` | BSD-3-Clause | https://github.com/numpy/numpy |

Each package ships its own license text in its installed distribution metadata; the texts above are included by reference rather than reproduced here.

---

## C. License texts

Full reproductions of the MIT, BSD-3-Clause, and Apache-2.0 license texts are available at their canonical sources:

- MIT: https://opensource.org/license/mit
- BSD-3-Clause: https://opensource.org/license/bsd-3-clause
- Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0

If any attribution above is incomplete or incorrect, please open an issue on the Mila repository — we'll fix it.
