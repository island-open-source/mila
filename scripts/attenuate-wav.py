#!/usr/bin/env python3
"""Attenuate a 16-bit PCM WAV by a linear scale factor.

Used by the audio-loopback E2E to manufacture a "quiet mic capture"
fixture (~-26 dBFS peak) from the louder canonical English fixture so
the AGC recovery test has a deterministic low-volume input. Lives in a
file (rather than inline in the workflow YAML) because macos-26 runners
ship neither `ffmpeg` nor `sox`, so we'd otherwise have to add a brew
install to the cold-path budget for a one-line audio op.

Usage:
    python3 scripts/attenuate-wav.py <in.wav> <out.wav> <scale>

`scale` is a linear multiplier in (0, 1]:
    0.05 -> ~20*log10(0.05) ~= -26 dB attenuation (sox gain -26 equivalent)
    0.1  -> ~-20 dB
    1.0  -> no-op (sanity-check identity)

Only 16-bit PCM mono/multi-channel sources are supported because that's
what `scripts/generate-audio-fixture.sh` produces. We deliberately keep
this script dependency-free (stdlib `wave`/`struct` only) so it runs on
any CI image without needing a Python package install.
"""

from __future__ import annotations

import math
import struct
import sys
import wave


def attenuate(src_path: str, dst_path: str, scale: float) -> None:
    if not (0.0 < scale <= 1.0):
        raise SystemExit(f"scale must be in (0, 1]; got {scale}")

    src = wave.open(src_path, "rb")
    try:
        if src.getsampwidth() != 2:
            raise SystemExit(
                f"only 16-bit PCM supported; {src_path} has "
                f"{src.getsampwidth() * 8}-bit samples"
            )
        frames = src.readframes(src.getnframes())
        # Sample width is 2 bytes, so the byte-count must be even.
        sample_count = len(frames) // 2
        samples = struct.unpack(f"<{sample_count}h", frames)

        # Clip into int16 range — for scales < 1 we won't actually clip,
        # but the clamp keeps this safe for scale == 1.0 (no-op) too.
        scaled = [
            max(-32768, min(32767, int(round(s * scale)))) for s in samples
        ]

        dst = wave.open(dst_path, "wb")
        try:
            dst.setnchannels(src.getnchannels())
            dst.setsampwidth(src.getsampwidth())
            dst.setframerate(src.getframerate())
            dst.writeframes(struct.pack(f"<{len(scaled)}h", *scaled))
        finally:
            dst.close()

        # Sanity readout — peak/RMS in dBFS so the workflow log shows
        # whether the attenuation actually lands near the target. A
        # zero-peak buffer would be silently broken so we guard against
        # log10(0) explicitly.
        peak = max((abs(s) for s in scaled), default=0)
        rms = math.sqrt(sum(s * s for s in scaled) / max(len(scaled), 1))
        peak_db = 20 * math.log10(peak / 32768.0) if peak else float("-inf")
        rms_db = 20 * math.log10(rms / 32768.0) if rms else float("-inf")
        print(
            f"attenuate-wav: in={src_path} out={dst_path} scale={scale} "
            f"samples={len(scaled)} channels={src.getnchannels()} "
            f"sr={src.getframerate()} peak={peak_db:.2f}dBFS rms={rms_db:.2f}dBFS"
        )
    finally:
        src.close()


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    _, src_path, dst_path, scale_arg = argv
    attenuate(src_path, dst_path, float(scale_arg))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
