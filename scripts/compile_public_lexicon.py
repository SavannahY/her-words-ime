#!/usr/bin/env python3
"""Validate independently curated public words and compile inert Rime data.

No network or user dictionary is read. Public words are offered after the first
ordinary candidate rather than imported into the upstream ranking dictionary.
The generated dictionary is a reviewable/exportable full-pinyin representation;
runtime full-pinyin and official English aliases use the same generated table.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlsplit

try:
    from .compile_packs import lua_quote
    from .validate_packs import ValidationError, normalize_pinyin, read_json
except ImportError:
    from compile_packs import lua_quote
    from validate_packs import ValidationError, normalize_pinyin, read_json


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "data/public-lexicon"
DEFAULT_OUTPUT = ROOT / "rime"
PUBLIC_SEED_WEIGHT = 1
CATEGORIES = {"woman", "idiom", "brand", "internet"}
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}\Z")
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
ALIAS = re.compile(r"[a-z]{1,64}\Z")
MIDDLE_DOTS = {"·", "・"}


def fail(location, message):
    raise ValidationError(location + ": " + message)


def keys(value, required, optional, location):
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - optional:
        fail(location, "missing or unknown fields")


def text(value, maximum, location):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or value != value.strip():
        fail(location, "must be bounded nonblank plain text")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        fail(location, "invalid Unicode")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail(location, "control characters are not allowed")
    return value


def han(char):
    point = ord(char)
    return 0x3400 <= point <= 0x9FFF or 0xF900 <= point <= 0xFAFF or 0x20000 <= point <= 0x323AF


def validate_file(data, filename):
    keys(data, {"version", "sources", "entries"}, {"description"}, filename)
    if type(data["version"]) is not int or data["version"] != 1:
        fail(filename, "version must be 1")
    if "description" in data:
        text(data["description"], 500, filename + ".description")
    if not isinstance(data["sources"], list) or not 1 <= len(data["sources"]) <= 2_000:
        fail(filename, "sources must be a nonempty bounded array")
    source_ids = set()
    for index, source in enumerate(data["sources"]):
        where = filename + ".sources[{}]".format(index)
        keys(source, {"id", "title", "url"}, set(), where)
        if not isinstance(source["id"], str) or not IDENTIFIER.fullmatch(source["id"]) or source["id"] in source_ids:
            fail(where, "source id must be unique lowercase ASCII")
        source_ids.add(source["id"])
        text(source["title"], 180, where + ".title")
        url = text(source["url"], 1_024, where + ".url")
        try:
            parts = urlsplit(url)
        except ValueError:
            fail(where, "source URL is malformed")
        if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or any(char.isspace() for char in url):
            fail(where, "source URL must be an HTTPS page without credentials or whitespace")
    if not isinstance(data["entries"], list) or not 1 <= len(data["entries"]) <= 5_000:
        fail(filename, "entries must be a nonempty bounded array")
    seen = set()
    for index, entry in enumerate(data["entries"]):
        where = filename + ".entries[{}]".format(index)
        keys(entry, {"text", "pinyin", "category", "source_ids"}, {"aliases", "tags", "note"}, where)
        value = text(entry["text"], 32, where + ".text")
        if len(value.encode("utf-8")) > 128 or not all(han(char) or char in MIDDLE_DOTS for char in value):
            fail(where, "text must be a Chinese word/name; English spelling belongs in aliases")
        if value[0] in MIDDLE_DOTS or value[-1] in MIDDLE_DOTS or any(
                left in MIDDLE_DOTS and right in MIDDLE_DOTS for left, right in zip(value, value[1:])):
            fail(where, "middle dots may only separate name components")
        if not isinstance(entry["category"], str) or entry["category"] not in CATEGORIES:
            fail(where, "category must be woman, idiom, brand or internet")
        if any(char in MIDDLE_DOTS for char in value) and entry["category"] != "woman":
            fail(where, "middle dots are only supported for person names")
        normalize_pinyin(entry["pinyin"], where + ".pinyin")
        if len(entry["pinyin"]) > 256 or len(entry["pinyin"].split()) != sum(han(char) for char in value):
            fail(where, "require one real full-pinyin syllable per Han character; middle dots have no syllable")
        identity = (entry["text"], entry["pinyin"])
        if identity in seen:
            fail(where, "duplicate word/reading")
        seen.add(identity)
        references = entry["source_ids"]
        if not isinstance(references, list) or not 1 <= len(references) <= 12 or any(
                not isinstance(item, str) or item not in source_ids for item in references) or len(set(references)) != len(references):
            fail(where, "source_ids must refer to unique sources in this same file")
        aliases = entry.get("aliases", [])
        if not isinstance(aliases, list) or len(aliases) > 8 or any(
                not isinstance(item, str) or not ALIAS.fullmatch(item) for item in aliases) or len(set(aliases)) != len(aliases):
            fail(where, "aliases must be unique lowercase ASCII letter spellings, not fake pinyin")
        if aliases and entry["category"] != "brand":
            fail(where, "only official English brand spellings are supported as public aliases")
        tags = entry.get("tags", [])
        if not isinstance(tags, list) or len(tags) > 12 or any(
                not isinstance(item, str) or len(item) > 48 or not SLUG.fullmatch(item) for item in tags) or len(set(tags)) != len(tags):
            fail(where, "tags must be unique bounded lowercase slugs")
        if "note" in entry:
            text(entry["note"], 240, where + ".note")
    return data


def load_public_lexicon(directory=DEFAULT_INPUT):
    directory = Path(directory)
    paths = sorted(directory.glob("*.json"))
    if not paths:
        fail(str(directory), "no public lexicon files")
    entries, sources, files, seen = [], {}, {}, set()
    for path in paths:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_000_000:
            fail(str(path), "source must be a bounded regular JSON file")
        data = validate_file(read_json(path), path.name)
        files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        for source in data["sources"]:
            if source["id"] in sources and sources[source["id"]] != source:
                fail(path.name, "global source id has conflicting metadata: " + source["id"])
            sources[source["id"]] = source
        for entry in data["entries"]:
            identity = (entry["text"], entry["pinyin"])
            if identity in seen:
                fail(path.name, "word/reading occurs in more than one public file")
            seen.add(identity)
            entries.append(entry)
        if len(entries) > 10_000:
            fail(str(directory), "public lexicon exceeds 10,000 readings")
    return {"version": 1, "sources": sorted(sources.values(), key=lambda item: item["id"]),
            "entries": sorted(entries, key=lambda item: (item["pinyin"], item["text"])), "files": files}


def render_dictionary(data):
    lines = ["# Generated by scripts/compile_public_lexicon.py; edit data/public-lexicon/*.json.",
             "# Inclusion is factual vocabulary, not a ranking of people or an endorsement of brands.",
             "# Review/export only: runtime offers these after the first ordinary candidate.",
             "# Weight 1 is a seed, not an invented corpus frequency.",
             "---", "name: her_public", 'version: "1"', "sort: by_weight", "..."]
    lines += ["{}\t{}\t{}".format(entry["text"], entry["pinyin"], PUBLIC_SEED_WEIGHT) for entry in data["entries"]]
    return ("\n".join(lines) + "\n").encode("utf-8")


def render_aliases(data):
    lines = ["-- Generated public facts/word heads; metadata notes never become candidate code.", "return {"]
    for section in ("readings", "aliases"):
        lines.append("  " + section + " = {")
        rows = []
        for entry in data["entries"]:
            codes = [entry["pinyin"].replace(" ", "")] if section == "readings" else entry.get("aliases", [])
            for code in codes:
                rows.append((code, entry["text"], entry["category"]))
        for code, value, category in sorted(set(rows)):
            lines.append("    { input = " + lua_quote(code) + ", text = " + lua_quote(value) + ", category = " + lua_quote(category) + " },")
        lines.append("  },")
    lines.append("}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_public_resources(directory=DEFAULT_INPUT):
    data = load_public_lexicon(directory)
    return {"her_public.dict.yaml": render_dictionary(data),
            "lua/her_public_aliases.lua": render_aliases(data)}


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".public-lexicon-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    try:
        resources = build_public_resources(arguments.input_dir)
        for name, content in resources.items():
            path = arguments.output_dir / name
            if arguments.check:
                if not path.is_file() or path.read_bytes() != content:
                    raise ValidationError("stale public lexicon artifact: " + name)
            else:
                atomic_write(path, content)
    except (OSError, ValueError) as error:
        print("Could not compile public lexicon: " + str(error), file=sys.stderr)
        return 1
    print(("Checked" if arguments.check else "Compiled") + " public full-pinyin dictionary and separate alias table")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
