# Self-hosting a transcription server for Mila (ivrit.ai & other models)

Mila can offload transcription to any server that implements OpenAI's
[`POST /v1/audio/transcriptions`](https://platform.openai.com/docs/api-reference/audio/createTranscription)
endpoint. This guide shows how to stand up such a server with an **[ivrit.ai](https://www.ivrit.ai/)**
Hebrew model — but the same setup works for any Whisper model.

Once it's running, point Mila at it under **Settings → Models → Backend → Remote API**.

---

## Background: what ivrit.ai ships

ivrit.ai is a non-profit project providing high-quality **Hebrew** speech models.
It publishes **model weights**, not a turnkey API. The fine-tuned models are
distributed in [CTranslate2](https://github.com/OpenNMT/CTranslate2) form — the
format the [faster-whisper](https://github.com/SYSTRAN/faster-whisper) runtime
consumes:

- [`ivrit-ai/whisper-large-v3-ct2`](https://huggingface.co/ivrit-ai/whisper-large-v3-ct2) — most accurate
- [`ivrit-ai/whisper-large-v3-turbo-ct2`](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ct2) — faster, smaller

> **Note.** ivrit.ai's own serving project,
> [`ivrit-ai/runpod-serverless`](https://github.com/ivrit-ai/runpod-serverless),
> speaks RunPod's job protocol — **not** the OpenAI API. So you don't use it
> directly with Mila; instead you put an OpenAI-compatible server in front of
> the same weights, as below.

---

## Option A — `speaches` (recommended)

[`speaches`](https://github.com/speaches-ai/speaches) (formerly
`faster-whisper-server`) is an OpenAI-compatible server built on faster-whisper.
It can load **any** HuggingFace CTranslate2 model by ID, including ivrit.ai's.

### 1. Run the server (Docker)

GPU (NVIDIA/CUDA — strongly recommended for `large-v3`):

```bash
docker run --rm -d --gpus=all \
  -p 8000:8000 \
  -e WHISPER__MODEL=ivrit-ai/whisper-large-v3-turbo-ct2 \
  -v hf-hub-cache:/home/ubuntu/.cache/huggingface/hub \
  ghcr.io/speaches-ai/speaches:latest-cuda
```

CPU-only (fine for the `turbo` model on short clips; slow for `large-v3`):

```bash
docker run --rm -d \
  -p 8000:8000 \
  -e WHISPER__MODEL=ivrit-ai/whisper-large-v3-turbo-ct2 \
  -v hf-hub-cache:/home/ubuntu/.cache/huggingface/hub \
  ghcr.io/speaches-ai/speaches:latest-cpu
```

The first request downloads the model into the mounted cache volume; subsequent
runs reuse it.

> Check the [speaches docs](https://speaches-ai.github.io/speaches/) for the
> current image tags and env-var names — the project moves quickly.

### 2. Verify it's up

```bash
# Lists available models — Mila's "Test connection" button hits this too.
curl http://localhost:8000/v1/models

# Transcribe a sample file end-to-end.
curl http://localhost:8000/v1/audio/transcriptions \
  -F file=@sample-he.m4a \
  -F model=ivrit-ai/whisper-large-v3-turbo-ct2 \
  -F language=he \
  -F response_format=verbose_json
```

### 3. Point Mila at it

In **Settings → Models**:

| Field      | Value                                          |
|------------|------------------------------------------------|
| Backend    | **Remote API**                                 |
| Endpoint   | `http://localhost:8000/v1`                     |
| Model      | `ivrit-ai/whisper-large-v3-turbo-ct2`          |
| API key    | *(leave blank — speaches doesn't require auth)* |

Click **Test connection**, then record. Mila uploads each recording as a compact
`.m4a` and asks for `verbose_json`, so per-segment timestamps (and therefore
SRT export + speaker diarization) keep working exactly as with the local engine.

---

## Option B — OpenAI's hosted Whisper API

No server to run. In **Settings → Models**:

| Field      | Value                          |
|------------|--------------------------------|
| Backend    | **Remote API**                 |
| Endpoint   | `https://api.openai.com/v1`    |
| Model      | `whisper-1`                    |
| API key    | your OpenAI API key            |

This uses OpenAI's general-purpose Whisper model (not the ivrit.ai Hebrew
finetune). Note OpenAI's per-request file-size limit (25 MB at time of writing);
Mila's `.m4a` encoding keeps roughly 1.5 hours of audio under that.

---

## Notes & caveats

- **Privacy.** With the remote backend active, audio is uploaded off-device.
  Mila flags this in the UI. For a privacy-preserving setup, self-host
  (Option A) on a machine you control rather than using a third-party API.
- **Exposing the server beyond localhost.** If you run the server on another
  host, terminate TLS (e.g. behind a reverse proxy) and require an API key —
  then set that key in Mila. Don't send audio over plaintext HTTP across a
  network you don't trust.
- **Language.** Mila forwards the recording language (`he` / `en`); on
  "Auto-detect" it omits the field and lets the server detect it.
- **Diarization** still runs locally (it reads the on-disk audio), so speaker
  labels work regardless of which transcription backend you choose.
