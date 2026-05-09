# Island Whisper

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

## Requirements

- macOS 14 (Sonoma) or newer.
- Xcode 15.3 or newer (Command Line Tools alone are not enough).
- Homebrew (used to install [`xcodegen`](https://github.com/yonaskolb/XcodeGen)).
- ~4.6 GB of disk for both default ggml models.

## Build & run

From the project root:

```bash
make bootstrap   # one time: installs xcodegen via brew if missing
make project     # generates IslandWhisper.xcodeproj from project.yml
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
~/Library/Application Support/IslandWhisper/Models/
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
IslandWhisper/
├── App/IslandWhisperApp.swift          # SwiftUI @main entry + AppDelegate
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
    └── IslandWhisper.entitlements
Packages/WhisperBinary/                 # SPM wrapper for whisper.cpp xcframework
scripts/make-dmg.sh                     # Builds a release DMG for distribution
```

## Releasing a new version

See [`.cursor/rules/release.mdc`](./.cursor/rules/release.mdc) — the canonical
SOP for cutting a new release. TL;DR:

```bash
# 1. Bump the version in project.yml + Info.plist
# 2. make dmg                       # builds IslandWhisper-<version>.dmg
# 3. git tag v<version> && git push origin v<version>
# 4. gh release create v<version> IslandWhisper-<version>.dmg
```

## Code signing notes

`project.yml` sets `CODE_SIGN_IDENTITY: "-"` (ad-hoc) and disables sandbox so
the dev build can use `ScreenCaptureKit` without provisioning. For
distribution via the App Store you'd:

- Re-enable `com.apple.security.app-sandbox`
- Add the appropriate entitlements (`com.apple.security.device.screen-recording`,
  `com.apple.security.network.client`, etc.)
- Provide your team ID in `DEVELOPMENT_TEAM`.

## License & credits

- [ivrit.ai](https://www.ivrit.ai) for the Hebrew Whisper finetunes.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) for the local inference.
- [OpenAI Whisper](https://github.com/openai/whisper) for the English model
  weights (re-packaged as ggml by `ggerganov/whisper.cpp`).
- This project is internal to Island.
