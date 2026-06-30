# Speaches Hebrew transcription image

A self-contained [speaches](https://github.com/speaches-ai/speaches)
(faster-whisper / CTranslate2) server that transcribes **Hebrew**, exposing the
OpenAI-compatible `/v1/audio/transcriptions` API on port **8000**.

It's the production "self-hosted server speaking the OpenAI protocol" that
Mila's remote backend (`RemoteWhisperEngine`) is designed to talk to — see
`Mila/Models/RemoteTranscriptionSettings.swift`.

## Model & licensing

- **Model:** [`ivrit-ai/whisper-large-v3-turbo-ct2`](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ct2)
  (`model.bin` ≈ 1.62 GB), CTranslate2 format.
- **License:** **Apache-2.0** — redistributable, so it's safe to bake into the
  public GHCR image. The speaches runtime itself is **MIT**. (Image label:
  `org.opencontainers.image.licenses="MIT AND Apache-2.0"`.)

The weights are downloaded into the image's HuggingFace cache **at build time**,
so the container needs no network at run time.

## Build

```bash
docker build -t mila-speaches-hebrew docker/speaches-hebrew
# Different model (must be a faster-whisper / CT2 repo):
docker build --build-arg MODEL_ID=ivrit-ai/whisper-large-v3-ct2 \
  -t mila-speaches-hebrew docker/speaches-hebrew
```

CI builds and publishes it to GHCR via `.github/workflows/build-speaches-image.yml`
(`ghcr.io/<owner>/mila-speaches-hebrew:latest`), only when this directory changes.

## Run

```bash
docker run --rm -p 8000:8000 ghcr.io/island-io/mila-speaches-hebrew:latest
# Wait for readiness (model preloads at startup):
curl --fail http://localhost:8000/health

# Transcribe Hebrew:
curl -s http://localhost:8000/v1/audio/transcriptions \
  -F "file=@Packages/TranscriptionCore/Fixtures/he_toda_raba.wav" \
  -F "model=ivrit-ai/whisper-large-v3-turbo-ct2" \
  -F "language=he" \
  -F "response_format=verbose_json"
```

Point Mila at it: Settings → Remote API → endpoint `http://localhost:8000/v1`,
model `ivrit-ai/whisper-large-v3-turbo-ct2` (no API key needed).

## Notes

- **CPU int8.** The image runs faster-whisper on CPU (`WHISPER__COMPUTE_TYPE=int8`)
  — no GPU on CI runners. A turbo model at int8 is the latency/quality sweet spot
  for a Hebrew CT2 model on CPU.
- **speaches' own VAD** (`vad_filter`) is faster-whisper's, *not* Mila's Silero
  VAD. Mila's VAD is a client-side gate that runs before any backend; the Hebrew
  E2E asserts it separately (`MilaTests/RemoteTranscriptionE2ETests.swift`).
