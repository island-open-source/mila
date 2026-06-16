# Mila

A native macOS app that records, dictates, and transcribes locally on your Mac
— no audio leaves the device. Hebrew transcription is powered by the
[ivrit.ai `large-v3` finetune](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml)
of Whisper, English by
[OpenAI's `large-v3-turbo`](https://huggingface.co/ggerganov/whisper.cpp), both
running through `whisper.cpp` (GPU via Metal).

## Features

- **Record from the microphone** at any time.
- **Record system audio** from a single app (Zoom, Google Meet in Chrome,
  Slack, etc.) via `ScreenCaptureKit` — no virtual audio device required.
- **Record meetings** = mic + system audio mixed into one mono 16 kHz WAV file.
- **Dictate in two languages** with separate global hotkeys:
    - `⌘2` — English dictation (OpenAI `large-v3-turbo`)
    - `⌘3` — Hebrew dictation (ivrit.ai `large-v3`)
  Both hotkeys are user-configurable in **Settings → Hotkeys**.
- **Transcribe locally**: ivrit.ai `large-v3` (Hebrew) or OpenAI
  `large-v3-turbo` (English / multilingual). Audio never leaves your Mac.
- Per-segment timestamps, click to seek, copy/share transcript, RTL rendering
  for Hebrew.

## System requirements

To **run** Mila:

- **macOS 14 (Sonoma) or later.**
- **Apple Silicon (M-series) strongly recommended.** Transcription runs on the
  Metal GPU (`whisper.cpp`) and speaker diarization on MPS/CPU (pyannote). Intel
  Macs fall back to CPU and are much slower.
- **Disk:** ~4.6 GB for the two default Whisper models, downloaded on first
  launch (ivrit.ai `large-v3` ~3.0 GB + OpenAI `large-v3-turbo` ~1.6 GB). Add
  ~1 GB more if you enable speaker diarization (bundled Python runtime plus a
  torch download on first enable).
- **Memory (approximate):** 16 GB unified memory recommended. 8 GB is workable
  for plain transcription but tight with diarization. Rough working set: Hebrew
  `large-v3` ~3.5–4 GB, English `large-v3-turbo` ~1.5–2 GB, speaker diarization
  adds ~1–2 GB. (RAM figures are approximate guidance, not a hard spec.)
- **Live (real-time) mode** — running transcription and diarization concurrently
  in real time is the heaviest path. It's **automatically disabled on MacBook
  Air–class chips** (they can't keep up in real time) and recommended on M-series
  Pro/Max, or M2 and newer. Recording plus after-the-fact transcription still
  works on Air.

To **build** Mila:

- Xcode 15.3 or newer (Command Line Tools alone are not enough).
- Homebrew (used to install [`xcodegen`](https://github.com/yonaskolb/XcodeGen)).

## Build & run

From the project root:

```bash
make bootstrap   # one time: installs xcodegen via brew if missing
make project     # generates Mila.xcodeproj from project.yml
make open        # opens Xcode
```

Or do it all from the CLI:

```bash
make run
```

The first build will resolve `Packages/WhisperBinary`, which downloads the
`whisper.xcframework` (~65 MB) from the official `ggml-org/whisper.cpp` v1.8.4
release. The checksum is pinned in `Packages/WhisperBinary/Package.swift`.

## Models

On first launch the app downloads both default models in the background:

- `ivrit-ai/whisper-large-v3-ggml` — Hebrew (~3.0 GB). Empirically more
  accurate on Hebrew speech than the smaller `large-v3-turbo` finetune,
  which is why we ship the larger one despite the size and ~2× inference
  cost.
- `openai whisper-large-v3-turbo` (the `ggerganov/whisper.cpp` build) —
  English / multilingual (~1.6 GB).

You can monitor progress in the in-app banner or pre-download from the CLI:

```bash
make models
```

Models live at:

```
~/Library/Application Support/Mila/Models/
    ivrit-ai-whisper-large-v3.bin
    openai-whisper-large-v3-turbo.bin
```

The app picks them up from that directory automatically.

## Required permissions

On first use macOS will prompt for the following — all are required for the
relevant feature to work:

| Feature                   | System Settings panel                     |
|---------------------------|-------------------------------------------|
| Microphone recording      | Privacy & Security → Microphone           |
| System / app audio        | Privacy & Security → Screen Recording     |
| Dictation paste-at-cursor | Privacy & Security → Accessibility        |

## How meeting capture works

`ScreenCaptureKit` allows audio capture per-application. When you pick *Zoom*
in the **New recording** sheet, only Zoom's audio output is captured (not your
own mic; not other apps). The mic is captured separately via `AVAudioEngine`
and the two streams are downmixed (averaged) into a single mono 16 kHz WAV file
that's fed into Whisper. SCK requires a video stream to function, so a 2×2
placeholder is configured and discarded.

## Project layout

```
Mila/
├── App/MilaApp.swift          # SwiftUI @main entry + AppDelegate
├── Audio/
│   ├── AudioUtilities.swift            # Conversion to 16k mono Float32
│   ├── MicrophoneRecorder.swift        # AVAudioEngine input tap
│   ├── SystemAudioRecorder.swift       # ScreenCaptureKit per-app audio
│   └── RecordingSession.swift          # Mix mic + system → WAV
├── Transcription/
│   ├── ModelManager.swift              # Download / select ggml models
│   ├── WhisperEngine.swift             # whisper.cpp C bridge
│   └── TranscriptionService.swift      # Orchestrates jobs
├── Dictation/
│   ├── HotkeyManager.swift             # Carbon global hotkeys (multi-binding)
│   └── DictationController.swift       # Mic → Whisper → paste
├── Views/                              # SwiftUI screens incl. Settings
├── Models/Recording*.swift             # Persisted recording metadata
└── Resources/
    ├── Info.plist
    └── Mila.entitlements
Packages/WhisperBinary/                 # SPM wrapper for whisper.cpp xcframework
scripts/make-dmg.sh                     # Builds a release DMG for distribution
```

## Building a release DMG

```bash
# 1. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml
# 2. make dmg                       # builds an ad-hoc-signed Mila-<version>.dmg
```

`make dmg` produces an **ad-hoc-signed** DMG suitable for local testing and
self-distribution. macOS Gatekeeper will show the standard prompt on first
launch (right-click → Open). To ship a notarized build, sign the app with your
own Apple Developer ID and run it through Apple's `notarytool` — see the code
signing notes below.

## Code signing notes

`project.yml` sets `CODE_SIGN_IDENTITY: "-"` (ad-hoc) and disables sandbox so
the dev build can use `ScreenCaptureKit` without provisioning. For
distribution via the App Store you'd:

- Re-enable `com.apple.security.app-sandbox`
- Add the appropriate entitlements (`com.apple.security.device.screen-recording`,
  `com.apple.security.network.client`, etc.)
- Provide your team ID in `DEVELOPMENT_TEAM`.

## Changelog

Newest first. Dates are release dates.

- **1.8.5** (2026-06-09) — Independent mic / app-audio capture toggles, AAC (`.m4a`) recordings, and a configurable recording-storage cap.
- **1.8.4** (2026-06-09) — Fixed speaker diarization silently breaking in notarized builds (the bundled Python couldn't load torch's dylibs).
- **1.8.3** (2026-06-08) — Mic-capture diagnostics, automatic language detection, and a post-recording sheet fix.
- **1.8.2** (2026-06-04) — Live transcription of app audio, screen-lock guard, recording-screen CPU fix, diarization improvements.
- **1.8.1** (2026-06-03) — Reverted automatic silence-dropping for app recordings.
- **1.8.0** (2026-06-01) — Five post-1.7 fixes: AGC-aware VAD, instant stop dialog, background recording mode, audio-context tuning.
- **1.7.0** (2026-05-28) — Automatic gain control, summary backfill, post-recording popup, and more.
- **1.6.5** (2026-05-28) — Removed a hardcoded email address from the default action prompt.
- **1.6.4** (2026-05-27) — Live speaker labels and instant save.
- **1.6.3** (2026-05-27) — Voice-activity-detection tuning for real conversations.
- **1.6.2** (2026-05-27) — VAD-driven live transcription, Claude Sonnet 4.6, rename sheet always shown.
- **1.6.1** (2026-05-27) — Live AI chunk size 5s → 30s to stop word-cutting.
- **1.6.0** (2026-05-26) — Live AI mode plus LLM/UI end-to-end test infrastructure.
- **1.5.0** (2026-05-25) — Speaker diarization on by default; added license and attributions.
- **1.4.3** (2026-05-23) — Build/CI maintenance (macOS 26 "Tahoe" runners).
- **1.4.2** (2026-05-23) — Restored the floating sidebar card and froze its material.
- **1.4.1** (2026-05-23) — In-place-update bundle relocator and UI polish.
- **1.4.0** (2026-05-23) — Stabilized the app bundle identifier.
- **1.3.11** (2026-05-20) — Speaker labels included in copied transcripts and LLM prompts.
- **1.3.10** (2026-05-19) — Diarization availability re-checked at launch to match what's on disk.
- **1.3.9** (2026-05-18) — Diarization self-heal: nuclear-repair fallback and matplotlib pre-install.
- **1.3.8** (2026-05-18) — Diarization self-heal: recover from missing Python modules; install numpy<2.
- **1.3.7** (2026-05-17) — Bundle torch dependencies; self-heal missing transitive deps.
- **1.3.6** (2026-05-17) — Release-packaging fix.
- **1.3.5** (2026-05-17) — Bundled diarization runtime (Python 3.11 + pyannote.audio) inside the app; manual rename and flat folders for organizing transcriptions.
- **1.3.1** (2026-05-13) — Maintenance release (version bump for auto-update).
- **1.3.0** (2026-05-13) — Initial speaker diarization and transcript (SRT) export.
- **1.2.8** (2026-05-13) — Security: pin and verify the SHA-256 of Whisper models downloaded from Hugging Face.
- **1.2.7** (2026-05-12) — Pick a specific input device; shell out to a local Claude/Cursor CLI to auto-name recordings.
- **1.2.6** (2026-05-11) — Fixed a Sparkle auto-update loop.
- **1.2.4 / 1.2.5** (2026-05-11) — Internal auto-update pipeline verification (no user-facing changes).
- **1.2.3** (2026-05-11) — Hardened the release DMG mount-path parsing.
- **1.2.2** (2026-05-10) — Stable code signing so in-place updates keep macOS permission grants.
- **1.2.1** (2026-05-10) — Fixed dictation pasting into the wrong window and a main-thread freeze with wireless mics.
- **1.2.0** (2026-05-09) — Switched the Hebrew default to the ivrit.ai large-v3 model (~3 GB).
- **1.1.0** (2026-05-09) — New app icon, per-language voice memos, hotkeys card, hide-recents toggle.
- **1.0.0** (2026-05-09) — Initial release.

## License

Mila is licensed under the [Apache License 2.0](./LICENSE). See [`NOTICE`](./NOTICE)
for required attribution.

Originally developed by Uri Harduf at Island Technology, Inc.

## Credits

- [ivrit.ai](https://www.ivrit.ai) for the Hebrew Whisper finetunes.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) for the local inference.
- [OpenAI Whisper](https://github.com/openai/whisper) for the English model
  weights (re-packaged as ggml by `ggerganov/whisper.cpp`).
- [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT) for auto-updates.
