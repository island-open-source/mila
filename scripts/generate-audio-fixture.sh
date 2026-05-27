#!/usr/bin/env bash
# Generate a multi-speaker WAV fixture for the audio loopback E2E.
#
# Uses macOS `say` (built-in TTS voices) to synthesise distinct speakers
# with a deliberate mix of utterance lengths:
#   * very-short single-word responses (~300ms) — exercise the
#     `minUtteranceMs` floor in the VAD detector
#   * medium 2-4 word phrases (~1s) — typical conversational rhythm
#   * long sentences (~4-6s) — exercise the max-utterance cap and
#     the hysteresis path (intra-sentence dips)
# Output is a single 16 kHz mono WAV that matches the format Mila feeds
# whisper internally. Total length ~55-65s — enough to test "works over
# a long period" while keeping CI under the 30-min job budget.
#
# Usage:
#   ./scripts/generate-audio-fixture.sh [output-path]
# Default output: /tmp/mila-audio-fixture.wav

set -euo pipefail

OUT="${1:-/tmp/mila-audio-fixture.wav}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Each entry is "<voice>|<text>". Order matters — speakers alternate
# realistically. Lines are designed so the resulting audio mixes very
# short responses (yes, go, OK) with longer thought units.
LINES=(
  "Allison|Hello team, thanks for joining today's roadmap review."
  "Tom|Hi."
  "Allison|I want to walk through three items: the auth rewrite, the search index migration, and the new billing dashboard."
  "Tom|Sounds good."
  "Allison|For the auth rewrite, the goal is to be done before the end of the quarter, including the legacy session token migration."
  "Tom|Yes."
  "Allison|Who's owning the search index?"
  "Tom|I can take it. The migration tooling from last sprint should still work."
  "Allison|Great."
  "Tom|When do we need to ship?"
  "Allison|Mid March is the target, but the auth rewrite is the hard dependency. The billing dashboard can slip a week."
  "Tom|OK."
  "Allison|Let's regroup Thursday and confirm the timeline."
  "Tom|Done."
)

i=0
for entry in "${LINES[@]}"; do
  voice="${entry%%|*}"
  text="${entry#*|}"
  say -v "$voice" -o "$WORK/$i.aiff" "$text"
  i=$((i + 1))
done
TOTAL=$i

# Convert each to 16 kHz mono WAV.
for ((n = 0; n < TOTAL; n++)); do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$n.aiff" "$WORK/$n.wav"
done

# Concatenate, inserting ~600ms of trailing silence after each clip so
# the VAD has a real pause to detect between utterances. (Without this
# the speech runs are back-to-back and would all merge into one
# max-cap-cut emit, which doesn't exercise the utterance boundaries.)
python3 - "$OUT" "$WORK" "$TOTAL" <<'EOF'
import wave, sys, struct
out_path, work, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
SR = 16000
SILENCE_MS = 600
silence_samples = SR * SILENCE_MS // 1000
silence_bytes = struct.pack("<%dh" % silence_samples, *([0] * silence_samples))
out = wave.open(out_path, "wb")
first = True
total_dur = 0.0
for n in range(total):
    w = wave.open(f"{work}/{n}.wav", "rb")
    if first:
        out.setnchannels(w.getnchannels())
        out.setsampwidth(w.getsampwidth())
        out.setframerate(w.getframerate())
        first = False
    data = w.readframes(w.getnframes())
    out.writeframes(data)
    out.writeframes(silence_bytes)
    total_dur += w.getnframes() / w.getframerate() + SILENCE_MS / 1000
    w.close()
out.close()
print(f"Wrote {out_path} ({total_dur:.1f}s, {total} speech segments)")
EOF
