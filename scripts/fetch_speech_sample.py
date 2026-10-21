#!/usr/bin/env python3
"""Download only the pinned public ASR test WAV and verify its bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sample = json.loads((ROOT / "speech/test-audio.json").read_text())
    with urllib.request.urlopen(sample["url"], timeout=60) as response:
        content = response.read(sample["bytes"] + 1)
    if len(content) != sample["bytes"] or hashlib.sha256(content).hexdigest() != sample["sha256"]:
        raise ValueError("Public ASR fixture failed size/SHA-256 verification")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(content)
    print("Verified public Chinese/English fixture: " + str(args.output))


if __name__ == "__main__":
    main()
