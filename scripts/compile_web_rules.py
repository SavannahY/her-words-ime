#!/usr/bin/env python3
"""Compile the same validated language-pack manifest into inert browser JSON."""

import argparse
import json
from pathlib import Path
import sys

try:
    from .compile_packs import compile_data
    from .validate_packs import DEFAULT_MANIFEST, ValidationError, load_project
except ImportError:
    from compile_packs import compile_data
    from validate_packs import DEFAULT_MANIFEST, ValidationError, load_project


def build_payload(manifest=DEFAULT_MANIFEST):
    project = load_project(Path(manifest))
    return {
        "format": "her-words-web-rules",
        "version": 1,
        "generated_from": "language-packs.json",
        "packs": [pack.data["id"] for pack in project.neutral + project.community],
        "rules": compile_data(project)["rules"],
    }


def render_payload(payload):
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, help="write a JSON file; default prints JSON")
    args = parser.parse_args()
    try:
        encoded = render_payload(build_payload(args.manifest))
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded, encoding="utf-8")
        else:
            sys.stdout.write(encoded)
    except (ValidationError, OSError) as error:
        print("Could not compile web rules: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
