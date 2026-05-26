#!/usr/bin/env bash
#
# Replay a fake meeting through the same code path LiveAISession uses
# (claude --session-id <uuid> -p ...) so we can debug the "action
# items disappear after a while" bug without recording a real meeting.
#
# Usage:
#   scripts/replay-live-ai.sh                # default fake meeting
#   scripts/replay-live-ai.sh path/to/file   # one chunk per blank-line-separated paragraph
#
# Requires `claude` on PATH (uses the user's existing CLI auth — no
# Anthropic key in the script). Prints the prompt sent + the raw
# response after each tick. Look for items disappearing across ticks.

set -euo pipefail

CLAUDE="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$CLAUDE" ]]; then
  echo "claude CLI not found on PATH (set CLAUDE_BIN to override)" >&2
  exit 1
fi

MODEL="${MODEL:-claude-haiku-4-5}"
SESSION_ID="$(uuidgen)"

# System prompt — kept in sync with LiveAISettings.defaultPrompt. The
# {{LANGUAGE}} token is pre-substituted; we hard-code English here for
# the replay.
read -r -d '' SYSTEM_PROMPT <<'EOF' || true
You are Mila, a live meeting assistant. Output everything in English.

You are called repeatedly as a live meeting unfolds. With Claude you keep a SESSION across calls, so your previous outputs are already in your own conversation memory — the user only sends you the new transcript tail each time. (If you don't see prior memory it's because the tool doesn't support sessions; in that case the user includes "CURRENT STATE" + the full transcript explicitly. Behave the same way in either mode.)

Your job is to return the NEW authoritative state. The user's screen will be REPLACED with exactly what you return, so:
  • Re-emit items you want to KEEP (using the SAME id they had).
  • UPDATE an item by re-emitting it with the same id but changed text.
  • REMOVE an item by omitting it from your response.
  • ADD new items with a fresh id (a short slug you choose).
  • Always merge duplicates — if the speaker repeats themselves, the item should appear ONCE.

An action item is:
- A concrete task someone committed to do (with or without a deadline)
- An explicit instruction directed at you (e.g. "Mila, add ..."). Tag those with source: "voice_command".

OUTPUT FORMAT: respond with ONLY a JSON object on a single line — no preamble, no Markdown, no trailing text:
{"summary": "...", "items": [{"id": "stable-slug", "text": "...", "speaker": "SPEAKER_00" or null, "timestamp_seconds": 0, "source": "inferred" or "voice_command"}]}

Include a 1-3 sentence rolling summary. If the call has just started and there is no transcript yet, output {"summary": "", "items": []}.
EOF

# Fake meeting, broken into ~5-second-ish chunks. Tuned to include
# repeated/restated action items so we can see whether the model
# correctly merges them across ticks instead of letting them
# accumulate or disappear.
if [[ $# -ge 1 ]]; then
  # Split the input file on blank lines into one chunk per paragraph.
  # awk RS="" treats blank-line-separated paragraphs as records;
  # we replace embedded newlines inside each record with spaces so
  # each chunk is a single line, then read line-by-line into the
  # array.
  CHUNKS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && CHUNKS+=("$line")
  done < <(awk 'BEGIN{RS=""} {gsub(/\n/," "); print}' "$1")
else
  CHUNKS=(
    "Alice: Thanks for joining. Today we need to lock down the Q1 roadmap and the launch plan."
    "Bob: I can take the action item to draft the launch checklist by Friday."
    "Alice: Great. And Carol, can you sync with marketing about the press release?"
    "Carol: Yes, I'll have a draft by Wednesday."
    "Bob: Actually, on the launch checklist — I'll need help from Dave for the infra section. Dave, can you cover that?"
    "Dave: Sure, I'll handle the infra section. Same deadline?"
    "Bob: Yeah, Friday works. Let me restate the items so we're clear: Bob drafts the launch checklist by Friday, Dave covers the infra section, Carol drafts the press release by Wednesday."
    "Alice: Perfect. One more thing — let's get a follow-up meeting on the calendar for next Tuesday."
    "Carol: I'll send the invite today."
    "Alice: That's it. Thanks everyone."
  )
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

echo "Replay session: $SESSION_ID"
echo "Model:          $MODEL"
echo "Chunks:         ${#CHUNKS[@]}"
echo "-----"

for i in "${!CHUNKS[@]}"; do
  tick=$((i + 1))
  chunk="${CHUNKS[$i]}"
  # On the first tick we ship the full system prompt + the first
  # chunk. Subsequent ticks: session memory has the system prompt,
  # so we just send the new transcript tail — matching what
  # LiveAISession.kick() does in Swift.
  if [[ $tick -eq 1 ]]; then
    full_prompt="$SYSTEM_PROMPT

---
Transcript:
Additional transcript since last update:
$chunk"
  else
    full_prompt="Additional transcript since last update:
$chunk"
  fi

  prompt_file="$scratch/tick-$tick.prompt"
  printf '%s' "$full_prompt" > "$prompt_file"
  echo "--- tick $tick ---"
  echo "[input chunk] $chunk"

  start_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
  # First tick: --session-id creates the conversation. Every subsequent
  # tick must use --resume <uuid> to continue it — reusing --session-id
  # errors with "Session ID is already in use." This is the exact bug
  # the Swift LiveAISession had and the reason action items started
  # vanishing in long calls (every tick after the first silently
  # failed).
  if [[ $tick -eq 1 ]]; then
    session_flag=(--session-id "$SESSION_ID")
  else
    session_flag=(--resume "$SESSION_ID")
  fi
  response=$("$CLAUDE" "${session_flag[@]}" --model "$MODEL" -p "$full_prompt" 2>"$scratch/tick-$tick.stderr") || {
    echo "[ERROR] claude exited non-zero. stderr:"
    cat "$scratch/tick-$tick.stderr"
    exit 1
  }
  end_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

  echo "[response in ${elapsed_ms}ms]"
  echo "$response"

  # Extract just the item ids + texts for a compact diff view between
  # ticks. Strips markdown ```json fences if Claude wraps the output
  # (which it does occasionally despite the "no Markdown" instruction).
  printf '%s' "$response" | python3 - <<'PY'
import json, sys
text = sys.stdin.read()
# Balanced-brace extraction so markdown fences / preamble don't confuse
# us. Find the first '{' and walk to its matching '}'. Strings inside
# are skipped so a quoted brace doesn't shift depth.
def first_object(s):
    start = s.find("{")
    if start < 0: return None
    depth, in_str, esc = 0, False, False
    for i in range(start, len(s)):
        ch = s[i]
        if esc:
            esc = False
            continue
        if ch == "\\" and in_str:
            esc = True
            continue
        if ch == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return s[start:i+1]
    return None
blob = first_object(text)
if not blob:
    print("  (no JSON object found in response)")
    sys.exit(0)
try:
    obj = json.loads(blob)
except Exception as e:
    print(f"  (JSON parse failed: {e})")
    sys.exit(0)
items = obj.get("items") or []
print(f"  parsed: {len(items)} items, summary={len(obj.get('summary') or '')}ch")
for it in items:
    print(f"    [{it.get('id','?')}] {it.get('text','')}")
PY
  echo
done
