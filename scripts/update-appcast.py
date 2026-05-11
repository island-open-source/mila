#!/usr/bin/env python3
"""
Append a release entry to a Sparkle appcast.xml.

Reads the current `--appcast-in` (creating an empty one if missing), prepends
a new `<item>` for the just-built release, writes back to `--appcast-out`.
The signature/length come from Sparkle's `sign_update` tool — we don't try to
re-implement EdDSA here, just slot the values into the right XML attributes.

We deliberately do not collapse, dedupe, or trim the existing items — old
versions are tiny, and keeping them lets a user on a much-older release jump
straight to the latest.
"""
import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY_APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>IslandWhisper</title>
    <link>https://island-whisper-updates.internal.island.io/appcast.xml</link>
    <description>IslandWhisper auto-update feed.</description>
    <language>en</language>
  </channel>
</rss>
"""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--version", required=True, help="Marketing version, e.g. 1.2.3")
    p.add_argument("--build", required=True, help="Build number, e.g. 6")
    p.add_argument("--dmg-name", required=True, help="DMG filename (no path)")
    p.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    p.add_argument("--length", required=True, help="DMG byte length from sign_update")
    p.add_argument("--minimum-system-version", default="14.0")
    p.add_argument("--feed-url-base", required=True,
                   help="Public base URL where DMGs live, e.g. https://island-whisper-updates.internal.island.io")
    p.add_argument("--appcast-in", required=True, type=Path)
    p.add_argument("--appcast-out", required=True, type=Path)
    return p.parse_args()


def load_or_init(path: Path) -> ET.ElementTree:
    if not path.exists() or path.stat().st_size == 0:
        path.write_text(EMPTY_APPCAST)
    try:
        return ET.parse(path)
    except ET.ParseError as exc:
        print(f"warning: existing appcast at {path} is malformed ({exc}); "
              "starting fresh", file=sys.stderr)
        path.write_text(EMPTY_APPCAST)
        return ET.parse(path)


def make_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    title = ET.SubElement(item, "title")
    title.text = f"Version {args.version}"
    pub = ET.SubElement(item, "pubDate")
    pub.text = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    sparkle_min = ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion")
    sparkle_min.text = args.minimum_system_version
    ET.SubElement(item, "enclosure", {
        "url": f"{args.feed_url_base.rstrip('/')}/{args.dmg_name}",
        f"{{{SPARKLE_NS}}}version": args.build,
        f"{{{SPARKLE_NS}}}shortVersionString": args.version,
        f"{{{SPARKLE_NS}}}edSignature": args.signature,
        "length": args.length,
        "type": "application/octet-stream",
    })
    return item


def main() -> int:
    args = parse_args()
    tree = load_or_init(args.appcast_in)
    channel = tree.getroot().find("channel")
    if channel is None:
        print(f"error: appcast at {args.appcast_in} has no <channel>",
              file=sys.stderr)
        return 1
    # Prepend the new item before any existing <item>s (Sparkle reads
    # newest-first but ordering is not strictly required; doing it explicitly
    # makes the file easier to read for humans).
    insert_idx = 0
    for i, child in enumerate(channel):
        if child.tag == "item":
            insert_idx = i
            break
        insert_idx = i + 1
    channel.insert(insert_idx, make_item(args))
    args.appcast_out.parent.mkdir(parents=True, exist_ok=True)
    tree.write(args.appcast_out, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
