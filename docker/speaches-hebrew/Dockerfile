# Speaches (faster-whisper / CTranslate2) serving a Hebrew whisper model,
# OpenAI-compatible at /v1/audio/transcriptions on port 8000.
#
# WHY THIS IMAGE EXISTS
# ---------------------
# Mila's remote-transcription backend (`RemoteWhisperEngine`) speaks the OpenAI
# `/v1/audio/transcriptions` protocol. Its E2E test normally runs against the
# stdlib echo mock (scripts/mock-openai-transcription-server.py), which proves
# the request *contract* but never actually transcribes. This image stands up a
# REAL self-hosted server with a REAL Hebrew model so the Hebrew E2E can prove
# Mila gets correct Hebrew text back over HTTP — the production "speaches serving
# an ivrit.ai model" path the app's own docs describe
# (Mila/Models/RemoteTranscriptionSettings.swift).
#
# It's also a standalone deliverable: `docker run -p 8000:8000 <image>` gives you
# a local Hebrew transcription endpoint for manual testing.
#
# MODEL
# -----
# ivrit-ai/whisper-large-v3-turbo-ct2 — Apache-2.0 (redistributable), CTranslate2
# format, model.bin ~1.62 GB. Baked into the image's HuggingFace hub cache at
# build time so the container is fully self-contained and needs no network at
# run time (important for hermetic CI). Override with --build-arg MODEL_ID=... .

ARG SPEACHES_TAG=latest-cpu
FROM ghcr.io/speaches-ai/speaches:${SPEACHES_TAG}

# Redeclare after FROM so it's visible in the build stage.
ARG MODEL_ID=ivrit-ai/whisper-large-v3-turbo-ct2

LABEL org.opencontainers.image.source="https://github.com/island-io/mila"
LABEL org.opencontainers.image.description="Speaches serving the Apache-2.0 ivrit.ai Hebrew whisper model (CT2), OpenAI-compatible on :8000. Used by Mila's Hebrew remote-transcription E2E."
LABEL org.opencontainers.image.licenses="MIT AND Apache-2.0"
LABEL io.island.mila.model="${MODEL_ID}"

# Bake the model weights into the image's HF cache. The base image runs as the
# non-root `ubuntu` user with HOME=/home/ubuntu and pre-creates
# ~/.cache/huggingface/hub, so the download lands exactly where faster-whisper
# looks for it at run time — no network needed once the image is built.
ENV HF_HUB_DISABLE_TELEMETRY=1
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download(repo_id='${MODEL_ID}')"

# Server config (speaches reads these env vars; see src/speaches/config.py).
#   - PRELOAD_MODELS: a JSON list. Load the model into memory at startup so the
#     very first transcription request doesn't pay the load cost (CI health-gates
#     on it). DERIVED from MODEL_ID (expanded at build time) so a custom
#     `--build-arg MODEL_ID=...` build preloads the model it actually baked into
#     the HF cache above — never a stale hard-coded repo.
#   - WHISPER__INFERENCE_DEVICE/COMPUTE_TYPE: CPU int8 — the GitHub runner has no
#     GPU, and int8 keeps the turbo model's latency tolerable.
#   - ENABLE_UI=false: no gradio UI; this is an API-only server.
#   - ALLOW_ORIGINS: the E2E client reaches it through a tunnel hostname.
#
# NOTE on the JSON-list vars (PRELOAD_MODELS, ALLOW_ORIGINS): speaches parses
# these with pydantic-settings as JSON, so the value must be a valid JSON list —
# `["*"]`, with the inner double-quotes intact. Docker's `ENV KEY=value` parser
# STRIPS surrounding double-quotes, so a bare `ALLOW_ORIGINS=["*"]` reaches the
# app as `[*]`, which pydantic rejects (`Input should be a valid list`) and the
# container crashes on boot. Escape the inner quotes (`\"`) so the env value is
# literally `["*"]`.
ENV PRELOAD_MODELS=["\"${MODEL_ID}\""] \
    WHISPER__INFERENCE_DEVICE=cpu \
    WHISPER__COMPUTE_TYPE=int8 \
    ENABLE_UI=false \
    ALLOW_ORIGINS=["\"*\""] \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8000

EXPOSE 8000

# Healthcheck so `docker run --health-*` / compose can gate on readiness. The
# base image installs curl. /health returns 200 once the app is up; we give it a
# long start period because PRELOAD_MODELS warms the ~1.6 GB model first.
HEALTHCHECK --interval=10s --timeout=5s --start-period=180s --retries=12 \
    CMD curl --fail http://localhost:8000/health || exit 1

# Inherit the base image's entrypoint/CMD (uvicorn serving the speaches app).
