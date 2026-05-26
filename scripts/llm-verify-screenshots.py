#!/usr/bin/env python3
"""
Visual regression check using Claude's vision API.

Reads PNGs from `--dir` (default `/tmp/mila-ui-screenshots/` — the
location Mila's UI tests write to), sends each to Claude with a
focused prompt about Mila's expected layout, and fails if the model
reports a layout regression.

What the LLM is told to look for
--------------------------------
For HOME shots (filename contains "home" or "launch"):
  * Left sidebar list visible with rows: Home, Queue, More, Folders,
    All Transcriptions, Trash, Settings.
  * Main pane shows a "Mila / by Island" wordmark and a Record button.
  * No visibly-empty main pane.

For DETAIL shots (filename contains "detail"):
  * Sidebar list still visible (same rows as above).
  * Main pane shows the recording's title at the TOP, a transcript
    or progress indicator in the middle, and a playback bar at the
    bottom.
  * Nothing collapsed / nothing pushed off-screen.

For LIST shots (filename contains "transcriptions" or "list"):
  * Sidebar list visible.
  * Main pane shows a list header + at least one recording row.

The script exits non-zero if Claude reports ANY of: sidebar items
missing, main pane visibly empty, content overflowing or cut off,
extreme misalignment that suggests a layout bug.

Usage
-----
    scripts/llm-verify-screenshots.py
    scripts/llm-verify-screenshots.py --dir /path/to/pngs

Env
---
    ANTHROPIC_API_KEY  — required (the same secret used by the
                         live-AI E2E workflow)
    MILA_VISION_MODEL  — override the model (default: claude-haiku-4-5)
"""

from __future__ import annotations
import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


DEFAULT_DIR = Path("/tmp/mila-ui-screenshots")
DEFAULT_MODEL = "claude-haiku-4-5"


def classify(name: str) -> str:
    """Map a filename to one of our expectation profiles.

    XCUITest screenshots are named like
    `-[DetailLayoutUITests test_xxx]-NN-actual-shot-name.png`
    — the leading bracket contains the *test* identifier, which has
    its own words ("Detail", "Layout", …) that would otherwise hijack
    classification. Strip everything up to and including the closing
    `]-` and classify on the explicit shot-name suffix the test
    author chose.
    """
    suffix = name
    bracket_end = name.rfind("]-")
    if bracket_end >= 0:
        suffix = name[bracket_end + 2:]
    lower = suffix.lower()
    if "detail" in lower:
        return "detail"
    if "transcription" in lower or "list" in lower:
        return "list"
    return "home"


EXPECTATIONS = {
    "home": (
        "This should be Mila's HOME view. Expected layout:\n"
        "  - LEFT SIDEBAR shows a list of rows: at minimum Home, Queue, More, "
        "Folders, All Transcriptions, Settings, Trash. The sidebar should NOT "
        "be empty.\n"
        "  - MAIN PANE shows a centered 'Mila / by Island' wordmark and a "
        "primary Record button (or 'Transcribe' / 'Transcribe and Summarize' "
        "label).\n"
        "  - No content should be cut off, overflowing the window, or "
        "displaced to one tiny corner."
    ),
    "list": (
        "This should be Mila's RECORDINGS LIST view (e.g. All "
        "Transcriptions, a folder). Expected layout:\n"
        "  - LEFT SIDEBAR with the standard rows (Home, Queue, More, Folders, "
        "Settings, Trash).\n"
        "  - MAIN PANE shows a header (e.g. 'All Transcriptions') and at "
        "least one recording row beneath it. The main pane should NOT be "
        "empty when there is a seeded recording.\n"
        "  - Layout should not be overflowing or misaligned."
    ),
    "detail": (
        "This should be Mila's RECORDING DETAIL view. Expected layout:\n"
        "  - LEFT SIDEBAR with the standard rows (Home, Queue, More, Folders, "
        "Settings, Trash) — these MUST still be visible; the sidebar going "
        "empty is the bug we are looking for.\n"
        "  - MAIN PANE shows: a title strip at the top with the recording's "
        "name, a transcript area or 'No transcript yet' placeholder in the "
        "middle, and a playback bar with a play button + slider at the "
        "bottom.\n"
        "  - Nothing should be pushed off-screen, no large empty areas, the "
        "title strip must NOT be missing."
    ),
}


SYSTEM = (
    "You are a visual regression QA assistant. You will see a "
    "screenshot of the macOS app 'Mila' and a description of the "
    "expected layout. Your job is to compare the two and decide if the "
    "layout is broken.\n"
    "\n"
    "Respond with ONLY a JSON object on a single line, no preamble, no "
    "Markdown:\n"
    '{"ok": true|false, "issues": ["..."], "notes": "..."}\n'
    "\n"
    "- Set ok=false if any required element is missing, empty, or "
    "visibly misplaced.\n"
    "- Cosmetic differences (slight padding, font weight, etc.) are NOT "
    "regressions; only flag structural problems.\n"
    "- The 'issues' array lists concrete defects, one per entry.\n"
    "- The 'notes' field is a one-sentence summary."
)


def call_vision(client: Any, model: str, png_bytes: bytes, expectation: str) -> dict[str, Any]:
    b64 = base64.b64encode(png_bytes).decode("ascii")
    resp = client.messages.create(
        model=model,
        max_tokens=512,
        system=SYSTEM,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": b64,
                    },
                },
                {
                    "type": "text",
                    "text": expectation + "\n\nReturn the JSON verdict.",
                },
            ],
        }],
    )
    text = "".join(
        block.text for block in resp.content if getattr(block, "type", "") == "text"
    ).strip()
    # Strip markdown fences if any.
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as e:
        raise AssertionError(
            f"vision response wasn't valid JSON ({e}):\n{text[:400]}"
        ) from e
    if "ok" not in obj:
        raise AssertionError(f"vision response missing 'ok' field: {text[:400]}")
    return obj


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default=str(DEFAULT_DIR),
                        help=f"directory of screenshots to verify (default {DEFAULT_DIR})")
    parser.add_argument("--model", default=os.environ.get("MILA_VISION_MODEL", DEFAULT_MODEL),
                        help="Anthropic model with vision support")
    args = parser.parse_args()

    try:
        import anthropic  # type: ignore
    except ImportError:
        print("error: pip install anthropic", file=sys.stderr)
        sys.exit(2)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("error: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(2)

    shots = sorted(Path(args.dir).glob("*.png"))
    if not shots:
        print(f"no PNGs found under {args.dir} — did UI tests run first?",
              file=sys.stderr)
        sys.exit(2)

    client = anthropic.Anthropic(api_key=api_key)
    print(f"verifying {len(shots)} screenshot(s) against model {args.model}\n")

    bad = 0
    for path in shots:
        kind = classify(path.name)
        expectation = EXPECTATIONS[kind]
        png = path.read_bytes()
        try:
            verdict = call_vision(client, args.model, png, expectation)
        except Exception as e:
            print(f"[{path.name}] vision call failed: {e}")
            bad += 1
            continue
        ok = bool(verdict.get("ok"))
        marker = "✓" if ok else "✗"
        notes = verdict.get("notes") or ""
        issues = verdict.get("issues") or []
        print(f"{marker} {path.name}  ({kind})")
        if notes:
            print(f"     notes: {notes}")
        for issue in issues:
            print(f"     - {issue}")
        if not ok:
            bad += 1

    print()
    if bad > 0:
        print(f"FAIL: {bad}/{len(shots)} screenshot(s) failed visual check")
        sys.exit(1)
    print(f"OK: {len(shots)} screenshot(s) look correctly rendered")


if __name__ == "__main__":
    main()
