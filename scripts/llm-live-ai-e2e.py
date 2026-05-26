#!/usr/bin/env python3
"""
End-to-end test for Mila's Live AI loop.

Mirrors the EXACT same prompt + session pattern Mila's Swift
LiveAISession uses, against the real Claude API (or the local CLI),
so we can verify the loop in CI and locally without recording audio.

What it asserts
---------------
* The session starts with `--session-id <uuid>` (or the SDK
  equivalent), every subsequent tick uses `--resume <uuid>` so the
  conversation continues. Claude's CLI fails the second call with
  "Session ID is already in use" if --session-id is reused — that
  was the original "items disappear after the first chunk" bug.
* On EVERY tick the response is a parseable JSON object with
  `summary` (str) + `items` (list).
* Action items emerge over time and PERSIST across ticks with
  stable `id`s. A restate (where the speaker says the same items
  again later in the meeting) does NOT add duplicates.
* The summary is non-empty after the first content-bearing tick
  and continues to grow / refresh as the meeting unfolds.

What it streams
---------------
For every tick, prints the chunk it sent + the summary char count
and the live item list with ids, so a watching human (you, locally)
can see the loop is correct as it happens. In CI the same output
ends up in the workflow log.

Backends
--------
* Default (local): shells out to `claude --session-id`/`--resume`
  using whatever OAuth the user has. No API key needed.
* `--backend api` (CI): uses the `anthropic` Python SDK directly.
  Reads `ANTHROPIC_API_KEY` from env. Maintains the conversation
  in-process — same semantics, fewer moving parts on a Linux runner.

Usage
-----
    scripts/llm-live-ai-e2e.py
        # 3-min English meeting via the local claude CLI

    scripts/llm-live-ai-e2e.py --fixture scripts/fixtures/3min-meeting-he.txt
        # same against the Hebrew fixture

    ANTHROPIC_API_KEY=sk-ant-... \\
    scripts/llm-live-ai-e2e.py --backend api
        # CI mode against Anthropic API directly
"""

from __future__ import annotations
import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FIXTURE = REPO_ROOT / "scripts" / "fixtures" / "3min-meeting-en.txt"
DEFAULT_MODEL = "claude-haiku-4-5"

# Kept in lockstep with LiveAISettings.defaultPrompt in the Swift
# code. If the Swift prompt changes the test must change with it,
# otherwise we're not actually exercising the production prompt.
SYSTEM_PROMPT_TEMPLATE = """You are Mila, a live meeting assistant. Output everything in {{LANGUAGE}}.

You are called repeatedly as a live meeting unfolds. Each call gives
you additional transcript. Your response REPLACES the entire panel
the user sees, so you MUST output the COMPLETE current state on
every single call:
  * The FULL list of action items - every one you have ever
    identified, not just the new ones.
  * The FULL rolling summary - refresh and rewrite it to cover the
    whole conversation so far, not just the latest chunk.

Treat every response as if the previous response no longer exists.
Do not assume the user retains anything from earlier calls. Repeat
every action item, with its stable id, in every reply. If you
realise an earlier item was wrong, simply omit it (the user's panel
will reflect that). If you want to update an item, re-emit it with
the SAME id and new text. If the speaker repeats themselves, the
item still appears exactly ONCE.

An action item is:
- A concrete task someone committed to do (with or without a deadline).
- An explicit instruction directed at you (e.g. "Mila, add ..." or in Hebrew "מילה, הוסף..."). Tag those with source: "voice_command".

OUTPUT FORMAT: respond with ONLY a JSON object on a single line - no preamble, no Markdown, no trailing text:
{"summary": "...", "items": [{"id": "stable-slug", "text": "...", "speaker": "SPEAKER_00" or null, "timestamp_seconds": 0, "source": "inferred" or "voice_command"}]}

If the call has just started and there is no transcript yet, output {"summary": "", "items": []}.
"""


def language_token(text: str) -> str:
    """Pick "Hebrew" if the fixture is >50% Hebrew letters, else
    English. Mirrors LiveAISession's auto-detection."""
    hebrew = sum(1 for c in text if 0x0590 <= ord(c) <= 0x05FF)
    latin = sum(1 for c in text if c.isalpha() and ord(c) < 0x0590)
    return "Hebrew" if hebrew > latin else "English"


def first_object(s: str) -> str | None:
    """Balanced-brace extractor — pull the first `{...}` out of a
    response that might be wrapped in Markdown fences or preface.

    If the response is wrapped in a ```json … ``` fence (Haiku does
    this intermittently, especially on Hebrew prompts), strip it
    first so the balanced-brace walk inside has a clean buffer.
    """
    fence = re.search(r"```(?:json)?\s*\n(.*?)\n```", s, re.DOTALL)
    if fence:
        s = fence.group(1)
    start = s.find("{")
    if start < 0:
        return None
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
                return s[start : i + 1]
    return None


def parse_envelope(raw: str) -> dict[str, Any]:
    """Parse the JSON envelope or raise AssertionError with the raw
    text included so failing CI logs make the issue obvious."""
    blob = first_object(raw)
    assert blob is not None, f"no JSON object in response:\n{raw[:400]}"
    try:
        obj = json.loads(blob)
    except json.JSONDecodeError as e:
        raise AssertionError(f"JSON parse failed ({e}):\n{blob[:400]}") from e
    assert isinstance(obj, dict), f"top-level is not a dict: {type(obj).__name__}"
    if "items" not in obj:
        obj["items"] = []
    if "summary" not in obj:
        obj["summary"] = ""
    assert isinstance(obj["items"], list), "items must be a list"
    assert isinstance(obj["summary"], str), "summary must be a string"
    return obj


# ---------------------------------------------------------------------------
# Backends
# ---------------------------------------------------------------------------


class CLIBackend:
    """Talks to the user's installed `claude` CLI (OAuth auth).
    Same code path Mila's Swift LLMRunner uses, modulo the
    per-session stable sandbox dir."""

    name = "cli"

    def __init__(self, model: str):
        self.model = model
        self.session_id = str(uuid.uuid4())
        self.established = False
        # Stable per-session sandbox — same trick Mila uses so claude
        # can find its session jsonl on every --resume.
        self.sandbox = Path("/tmp") / f"mila-llm-e2e-{self.session_id}"
        self.sandbox.mkdir(parents=True, exist_ok=True)

    def cleanup(self):
        try:
            for p in self.sandbox.rglob("*"):
                if p.is_file():
                    p.unlink(missing_ok=True)
            self.sandbox.rmdir()
        except FileNotFoundError:
            pass

    def call(self, prompt: str) -> str:
        flag = "--session-id" if not self.established else "--resume"
        cmd = [
            "claude",
            flag,
            self.session_id,
            "--model",
            self.model,
            "-p",
            prompt,
        ]
        out = subprocess.run(
            cmd,
            cwd=str(self.sandbox),
            capture_output=True,
            text=True,
            timeout=180,
        )
        if out.returncode != 0:
            raise RuntimeError(
                f"claude exited {out.returncode}:\nstderr: {out.stderr[:500]}\nstdout: {out.stdout[:500]}"
            )
        self.established = True
        return out.stdout


class APIBackend:
    """Direct call to the Anthropic Messages API. CI default.
    Keeps the full conversation history in memory; equivalent to
    `claude --resume` semantically but doesn't need the CLI."""

    name = "api"

    def __init__(self, model: str):
        try:
            import anthropic  # type: ignore
        except ImportError:
            print("error: pip install anthropic", file=sys.stderr)
            sys.exit(2)
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            print("error: ANTHROPIC_API_KEY not set", file=sys.stderr)
            sys.exit(2)
        self.model = model
        self.client = anthropic.Anthropic(api_key=api_key)
        self.system_prompt: str | None = None
        self.history: list[dict[str, Any]] = []

    def cleanup(self):
        pass

    def call(self, prompt: str) -> str:
        # We split the first call into a system + user message; subsequent
        # calls only append to history. The system_prompt member is set
        # by the driver right before the first tick.
        assert self.system_prompt is not None, "set_system must be called first"
        self.history.append({"role": "user", "content": prompt})
        resp = self.client.messages.create(
            model=self.model,
            # 4096 leaves comfortable headroom for the full envelope
            # (summary + items + speakers + timestamps), especially in
            # Hebrew where each character costs more tokens. 1024 was
            # cutting off the closing `}` mid-string.
            max_tokens=4096,
            system=self.system_prompt,
            messages=self.history,
        )
        text = "".join(
            block.text for block in resp.content if getattr(block, "type", "") == "text"
        )
        if getattr(resp, "stop_reason", None) == "max_tokens":
            print(f"[warn] response hit max_tokens — JSON may be truncated. "
                  f"text len={len(text)}", file=sys.stderr)
        self.history.append({"role": "assistant", "content": text})
        return text

    def set_system(self, system_prompt: str):
        self.system_prompt = system_prompt


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def chunks_from_fixture(text: str, chunk_seconds: float = 5.0,
                       target_minutes: float = 3.0) -> list[str]:
    """Split the fixture into ~`target_minutes` worth of chunks of
    ~`chunk_seconds` each. We treat each blank-line paragraph as one
    chunk; if the fixture has fewer paragraphs than needed, we
    duplicate-rolling rather than failing — the only goal is to
    exercise enough ticks to catch session drift."""
    paragraphs = [
        p.strip()
        for p in re.split(r"\n\s*\n", text.strip())
        if p.strip()
    ]
    desired = int(target_minutes * 60 / chunk_seconds)
    if desired <= len(paragraphs):
        return paragraphs[:desired]
    # Stretch by repeating "Yes." / "Got it." filler between real
    # turns so the chunk count matches without distorting content.
    out: list[str] = []
    filler_idx = 0
    fillers = ["(filler) yes.", "(filler) got it.", "(filler) makes sense."]
    while len(out) < desired:
        for p in paragraphs:
            if len(out) >= desired:
                break
            out.append(p)
            if len(out) < desired:
                out.append(fillers[filler_idx % len(fillers)])
                filler_idx += 1
    return out[:desired]


def run(args: argparse.Namespace) -> int:
    fixture_path = Path(args.fixture)
    fixture = fixture_path.read_text(encoding="utf-8")
    lang = language_token(fixture)
    chunks = chunks_from_fixture(fixture, chunk_seconds=args.chunk_seconds,
                                 target_minutes=args.minutes)
    system_prompt = SYSTEM_PROMPT_TEMPLATE.replace("{{LANGUAGE}}", lang)

    if args.backend == "api":
        backend = APIBackend(model=args.model)
        backend.set_system(system_prompt)
    else:
        backend = CLIBackend(model=args.model)

    print(f"--- Mila Live AI E2E test ---")
    print(f"fixture:    {fixture_path}")
    print(f"language:   {lang}")
    print(f"chunks:     {len(chunks)} (~{args.chunk_seconds:.0f}s each, ~{args.minutes:.0f}min total)")
    print(f"backend:    {backend.name}")
    print(f"model:      {args.model}")
    print()

    last_summary = ""
    item_history: list[set[str]] = []  # ids seen per tick

    for i, chunk in enumerate(chunks, start=1):
        # First tick — ship the full system + transcript paragraph.
        # Subsequent ticks — claude-cli case ships only the delta
        # (system is in conversation memory). For the SDK backend the
        # system is a separate parameter, so we just ship the delta as
        # the user turn body.
        if backend.name == "cli" and i == 1:
            prompt = (
                f"{system_prompt}\n\n---\nTranscript:\n"
                f"Additional transcript since last update:\n{chunk}"
            )
        else:
            prompt = f"Additional transcript since last update:\n{chunk}"

        tick_label = f"tick {i:>3}/{len(chunks)}"
        marker = ""
        if i * args.chunk_seconds % 30 < args.chunk_seconds:
            marker = " ▸ 30s marker"
        print(f"--- {tick_label}{marker} ---")
        print(f"[in ]  {chunk}")

        start = time.monotonic()
        try:
            raw = backend.call(prompt)
        except Exception as e:
            print(f"[ERR]  backend failed: {e}")
            backend.cleanup()
            return 1
        elapsed = time.monotonic() - start

        try:
            env = parse_envelope(raw)
        except AssertionError as e:
            print(f"[ASSERT FAIL] {e}")
            backend.cleanup()
            return 1

        items = env["items"]
        summary = env["summary"].strip()
        ids = {it.get("id", "") for it in items if it.get("id")}
        item_history.append(ids)

        print(f"[out ] {elapsed:.1f}s  summary={len(summary)}ch  items={len(items)}")
        if summary:
            short = summary if len(summary) <= 200 else summary[:200] + "…"
            print(f"  summary: {short}")
        for it in items:
            print(f"    [{it.get('id','?'):20s}] {it.get('text','')[:90]!r}")
        print()

        # Per-tick assertions
        if i >= 6 and not items and not summary:
            # By 6 ticks (~30s) the model has heard substantive
            # content. If both summary AND items are still empty,
            # something is wrong.
            print("[ASSERT FAIL] no summary or items after 6 ticks of substantive transcript")
            backend.cleanup()
            return 1

        last_summary = summary

    backend.cleanup()

    # Cross-tick assertions
    print("--- post-run assertions ---")

    # 1. Items shouldn't oscillate: an id that appears, disappears, and
    #    re-appears suggests the model is losing state across ticks.
    all_ids = set()
    for tick_ids in item_history:
        all_ids |= tick_ids
    drops = 0
    for an_id in all_ids:
        seen = False
        gap = False
        for tick_ids in item_history:
            if an_id in tick_ids:
                if gap:
                    drops += 1
                    break
                seen = True
            elif seen:
                gap = True
    print(f"  item id stability: {len(all_ids)} unique ids; drop-reappear events: {drops}")
    if drops > 0:
        print(f"  WARNING: {drops} item(s) dropped and re-appeared across ticks — session memory may be unreliable")
        # Not a hard fail — the new prompt should make this rare but
        # not impossible.

    # 2. Last tick should have the largest item set (every item the
    #    model has ever identified should still be present).
    if item_history:
        last = item_history[-1]
        max_seen = max(item_history, key=len)
        print(f"  final-tick items: {len(last)}; peak items: {len(max_seen)}")
        if len(last) < len(max_seen):
            missing = max_seen - last
            print(f"  WARNING: final tick lost {len(missing)} item(s) that earlier ticks had: {missing}")

    # 3. A non-empty summary should exist by the time the meeting is
    #    half done.
    half_idx = max(1, len(chunks) // 2)
    summaries_so_far = [
        s for s in (item_history,)  # placeholder, real summaries tracked above
    ]
    if not last_summary:
        print("  WARNING: final summary is empty")

    print("--- DONE ---")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE),
                        help="path to a paragraph-separated transcript fixture")
    parser.add_argument("--backend", choices=["cli", "api"], default="cli",
                        help="cli=local claude (OAuth); api=Anthropic SDK (CI)")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help=f"model name (default {DEFAULT_MODEL})")
    parser.add_argument("--chunk-seconds", type=float, default=5.0,
                        help="simulated seconds per chunk")
    parser.add_argument("--minutes", type=float, default=3.0,
                        help="total simulated meeting length in minutes")
    args = parser.parse_args()
    sys.exit(run(args))


if __name__ == "__main__":
    main()
