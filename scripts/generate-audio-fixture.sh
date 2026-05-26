#!/usr/bin/env bash
# Generate a multi-speaker WAV fixture for the audio loopback E2E.
#
# Uses macOS `say` (which has built-in voices) to synthesise distinct
# speakers, concatenates them, and emits a single 16 kHz mono WAV that
# matches the format Mila feeds whisper internally. ~30s total.
#
# Usage:
#   ./scripts/generate-audio-fixture.sh [output-path]
# Default output: /tmp/mila-audio-fixture.wav

set -euo pipefail

OUT="${1:-/tmp/mila-audio-fixture.wav}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two "speakers" via different `say` voices. Lines are short on purpose
# — whisper segments at sentence boundaries, and we want multiple
# discrete segments to land in the live pane so the test can count them.
say -v Allison -o "$WORK/a.aiff" \
  "Hello team, thanks for joining today. I wanted to walk through the roadmap for next quarter."
say -v Tom -o "$WORK/b.aiff" \
  "Sounds good. Where should we start?"
say -v Allison -o "$WORK/c.aiff" \
  "Three items: the auth rewrite, the search index migration, and the new billing dashboard."
say -v Tom -o "$WORK/d.aiff" \
  "I can take the search index. The migration tooling is already in place from last sprint."
say -v Allison -o "$WORK/e.aiff" \
  "Perfect. Let's regroup on Thursday and confirm the timeline."

# Convert each to 16 kHz mono WAV, then concatenate via Python's wave
# module. Naively cat-ing AIFFs produces a file with multiple headers
# that afconvert truncates to the first chunk — don't do that.
for f in a b c d e; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$f.aiff" "$WORK/$f.wav"
done
python3 - "$OUT" "$WORK" <<'EOF'
import wave, sys
out_path, work = sys.argv[1], sys.argv[2]
out = wave.open(out_path, "wb")
first = True
for n in ("a","b","c","d","e"):
    w = wave.open(f"{work}/{n}.wav", "rb")
    if first:
        out.setnchannels(w.getnchannels())
        out.setsampwidth(w.getsampwidth())
        out.setframerate(w.getframerate())
        first = False
    out.writeframes(w.readframes(w.getnframes()))
    w.close()
out.close()
EOF
echo "Wrote $OUT"
