#!/usr/bin/env python3
"""Validate independently edited Spanish learning material and emit inert Lua.

ASCII codes are lookup aids, never automatic spelling corrections. Chinese
queries cover only the explicitly curated phrases, not arbitrary translation.
The compiler reads one bounded local JSON file and never fetches source URLs.
"""
import argparse
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import unicodedata
from urllib.parse import urlsplit

try:
    from .compile_packs import lua_quote
    from .validate_packs import ValidationError, normalize_pinyin
except ImportError:
    from compile_packs import lua_quote
    from validate_packs import ValidationError, normalize_pinyin


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "data/spanish-learning.json"
DEFAULT_OUTPUT = ROOT / "rime"
MAX_SOURCE_BYTES = 1_000_000
MAX_ENTRIES = 500
MAX_FORMS = 2_000
MAX_CHINESE = 4_000
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}\Z")
ASCII_WORDS = re.compile(r"[a-z]+(?: [a-z]+)*\Z")
SPANISH_LETTERS = frozenset("abcdefghijklmnopqrstuvwxyzáéíóúüñABCDEFGHIJKLMNOPQRSTUVWXYZÁÉÍÓÚÜÑ")
SPANISH_PUNCTUATION = frozenset(" .,;:'¿?¡!-()")
TOPICS = frozenset({"greetings", "courtesy", "introductions", "learning", "food",
                    "shopping", "feelings", "travel", "responses", "plans", "time"})
PROVENANCE = frozenset({"common_expression_verified", "lexical_fact", "original_example"})
FORMS = frozenset({"masculine_speaker", "feminine_speaker", "masculine_addressee",
                   "feminine_addressee", "formal_usted"})
SOURCE_FIELDS = {"id", "title", "url"}
SOURCE_OPTIONAL = {"checked_on", "checked_via", "scope"}
ENTRY_FIELDS = {"id", "text", "input", "compact_input", "meaning_zh", "topic",
                "level_hint", "source_ids", "provenance", "zh_queries"}
VARIANT_FIELDS = {"text", "input", "compact_input", "meaning_zh", "grammatical_form",
                  "source_ids", "zh_queries"}


def fail(location, message):
    raise ValidationError(location + ": " + message)


def keys(value, required, optional, location):
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - optional:
        fail(location, "missing or unknown fields")


def plain_text(value, maximum, location):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or value != value.strip():
        fail(location, "must be bounded nonblank plain text")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        fail(location, "invalid Unicode")
    if unicodedata.normalize("NFC", value) != value:
        fail(location, "text must already use NFC Unicode")
    if any(unicodedata.category(char).startswith("C") or (char.isspace() and char != " ") for char in value):
        fail(location, "control, hidden and non-space whitespace characters are not allowed")
    return value


def bounded_array(value, minimum, maximum, location):
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        fail(location, "must be a bounded array")
    return value


def identifier(value, location):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        fail(location, "must be a bounded lowercase ASCII identifier")
    return value


def ascii_input(value):
    """Match the source's explicit accent-insensitive query policy only."""
    stripped = "".join(char for char in unicodedata.normalize("NFD", value.lower())
                       if unicodedata.category(char) != "Mn")
    return " ".join(re.sub(r"[^a-z ]", " ", stripped).split())


def spanish_text(value, location):
    value = plain_text(value, 160, location)
    if len(value.encode("utf-8")) > 512 or not any(char in SPANISH_LETTERS for char in value):
        fail(location, "require a bounded Spanish word or short sentence")
    if any(char not in SPANISH_LETTERS and char not in SPANISH_PUNCTUATION for char in value):
        fail(location, "only Spanish letters and simple sentence punctuation are supported")
    for opening, closing in (("¿", "?"), ("¡", "!")):
        if value.count(opening) != value.count(closing) or value.count(opening) > 1:
            fail(location, "question and exclamation marks must form a single matching pair")
        if opening in value and (value.index(opening) > value.index(closing) or not value.endswith(closing)):
            fail(location, "the matching closing mark must end the sentence without a following period")
    return value


def han(char):
    point = ord(char)
    return 0x3400 <= point <= 0x9FFF or 0xF900 <= point <= 0xFAFF or 0x20000 <= point <= 0x323AF


def references(value, source_ids, location):
    bounded_array(value, 1, 12, location)
    if any(not isinstance(item, str) or item not in source_ids for item in value) or len(set(value)) != len(value):
        fail(location, "must refer to unique sources in this file")


def validate_queries(value, location):
    bounded_array(value, 1, 4, location)
    seen = set()
    for index, query in enumerate(value):
        where = location + "[{}]".format(index)
        keys(query, {"text", "pinyin"}, set(), where)
        query_text = plain_text(query["text"], 48, where + ".text")
        if not all(han(char) for char in query_text):
            fail(where, "Chinese query text must contain only Han characters")
        pinyin = plain_text(query["pinyin"], 288, where + ".pinyin")
        normalize_pinyin(pinyin, where + ".pinyin")
        if len(pinyin.split()) != len(query_text):
            fail(where, "require one real full-pinyin syllable per Han character")
        identity = (query_text, pinyin)
        if identity in seen:
            fail(where, "duplicate Chinese query")
        seen.add(identity)


def validate_form(item, source_ids, location):
    value = spanish_text(item["text"], location + ".text")
    reading = plain_text(item["input"], 192, location + ".input")
    if not ASCII_WORDS.fullmatch(reading) or reading != ascii_input(value):
        fail(location, "input must equal the lowercase ASCII lookup form derived from text")
    if item["compact_input"] != reading.replace(" ", ""):
        fail(location, "compact_input must equal input without spaces")
    plain_text(item["meaning_zh"], 160, location + ".meaning_zh")
    if "note" in item:
        plain_text(item["note"], 240, location + ".note")
    references(item["source_ids"], source_ids, location + ".source_ids")
    validate_queries(item["zh_queries"], location + ".zh_queries")


def validate_spanish_learning(data, location="spanish-learning.json"):
    keys(data, {"version", "language", "sources", "entries"},
         {"description", "editorial_policy", "code_policy"}, location)
    if type(data["version"]) is not int or data["version"] != 1 or data["language"] != "es":
        fail(location, "version must be integer 1 and language must be es")
    if "description" in data:
        plain_text(data["description"], 500, location + ".description")
    if "editorial_policy" in data:
        policy = data["editorial_policy"]
        keys(policy, {"selection", "level_hints", "gender", "authorship"}, set(), location + ".editorial_policy")
        for field, value in policy.items():
            plain_text(value, 500, location + ".editorial_policy." + field)
    if "code_policy" in data:
        policy = data["code_policy"]
        keys(policy, {"input", "compact_input", "behavior", "ambiguity_examples"}, set(), location + ".code_policy")
        for field in ("input", "compact_input", "behavior"):
            plain_text(policy[field], 500, location + ".code_policy." + field)
        bounded_array(policy["ambiguity_examples"], 1, 8, location + ".code_policy.ambiguity_examples")
        for value in policy["ambiguity_examples"]:
            plain_text(value, 240, location + ".code_policy.ambiguity_examples")
    source_ids = set()
    for index, source in enumerate(bounded_array(data["sources"], 1, 512, location + ".sources")):
        where = location + ".sources[{}]".format(index)
        keys(source, SOURCE_FIELDS, SOURCE_OPTIONAL, where)
        source_id = identifier(source["id"], where + ".id")
        if source_id in source_ids:
            fail(where, "duplicate source id")
        source_ids.add(source_id)
        plain_text(source["title"], 180, where + ".title")
        url = plain_text(source["url"], 1_024, where + ".url")
        try:
            parsed = urlsplit(url)
            hostname = parsed.hostname
            _ = parsed.port
        except ValueError:
            fail(where, "malformed source URL")
        if parsed.scheme != "https" or not hostname or parsed.username or parsed.password or any(char.isspace() for char in url):
            fail(where, "source URL must be HTTPS without credentials or whitespace")
        if "checked_on" in source:
            checked_on = plain_text(source["checked_on"], 10, where + ".checked_on")
            try:
                if date.fromisoformat(checked_on).isoformat() != checked_on:
                    raise ValueError()
            except ValueError:
                fail(where, "checked_on must use a real YYYY-MM-DD date")
        if "checked_via" in source and (not isinstance(source["checked_via"], str) or
                                       source["checked_via"] not in {"opened_page", "indexed_official_excerpt"}):
            fail(where, "unsupported source verification method")
        if "scope" in source:
            plain_text(source["scope"], 500, where + ".scope")
    entry_ids, row_ids, texts, query_rows = set(), set(), set(), set()
    total_forms, total_queries = 0, 0
    for index, entry in enumerate(bounded_array(data["entries"], 1, MAX_ENTRIES, location + ".entries")):
        where = location + ".entries[{}]".format(index)
        keys(entry, ENTRY_FIELDS, {"note", "variants"}, where)
        entry_id = identifier(entry["id"], where + ".id")
        if entry_id in entry_ids:
            fail(where, "duplicate entry id")
        entry_ids.add(entry_id)
        if not isinstance(entry["topic"], str) or entry["topic"] not in TOPICS:
            fail(where, "unsupported learning topic")
        if not isinstance(entry["level_hint"], str) or entry["level_hint"] not in {"A1", "A2"}:
            fail(where, "level_hint must be A1 or A2")
        if not isinstance(entry["provenance"], str) or entry["provenance"] not in PROVENANCE:
            fail(where, "unsupported provenance")
        variants = bounded_array(entry.get("variants", []), 0, 8, where + ".variants")
        variant_forms = set()
        for form_index, item in enumerate([entry] + variants):
            item_where = where if form_index == 0 else where + ".variants[{}]".format(form_index - 1)
            if form_index:
                keys(item, VARIANT_FIELDS, {"note"}, item_where)
                form = item["grammatical_form"]
                if not isinstance(form, str) or form not in FORMS or form in variant_forms:
                    fail(item_where, "variant form must be supported and unique within this entry")
                variant_forms.add(form)
            row_id = entry_id + ("-" + item["grammatical_form"].replace("_", "-") if form_index else "")
            if row_id in row_ids:
                fail(item_where, "flattened entry id collides with another output")
            row_ids.add(row_id)
            validate_form(item, source_ids, item_where)
            if item["text"].casefold() in texts:
                fail(item_where, "duplicate Spanish output")
            texts.add(item["text"].casefold())
            for query in item["zh_queries"]:
                identity = (query["text"], query["pinyin"], item["text"])
                if identity in query_rows:
                    fail(item_where, "duplicate Chinese query and Spanish output")
                query_rows.add(identity)
            total_forms += 1
            total_queries += len(item["zh_queries"])
    if total_forms > MAX_FORMS or total_queries > MAX_CHINESE:
        fail(location, "too many flattened forms or Chinese queries")
    return data


def _object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("duplicate JSON key: " + key)
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValidationError("non-JSON constant: " + value)


def load_spanish_learning(source=DEFAULT_INPUT):
    path = Path(source)
    try:
        if path.is_symlink():
            fail(str(path), "source must not be a symlink")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        with os.fdopen(descriptor, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_SOURCE_BYTES:
                fail(str(path), "source must be a bounded regular JSON file")
            raw = stream.read(MAX_SOURCE_BYTES + 1)
        if len(raw) > MAX_SOURCE_BYTES:
            fail(str(path), "source is too large")
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_object_without_duplicates,
                          parse_constant=_invalid_constant)
    except (OSError, UnicodeError, ValueError, RecursionError) as error:
        raise ValidationError(str(path) + ": " + str(error)) from error
    return validate_spanish_learning(data, str(path)), hashlib.sha256(raw).hexdigest()


def compile_data(data):
    """Flatten only reviewed outputs and exact curated Chinese queries."""
    spanish, chinese = [], []
    for entry in data["entries"]:
        for item in [entry] + entry.get("variants", []):
            form = item.get("grammatical_form")
            row_id = entry["id"] + ("-" + form.replace("_", "-") if form else "")
            row = {"id": row_id, "input": item["compact_input"], "text": item["text"],
                   "meaning": item["meaning_zh"], "topic": entry["topic"], "level": entry["level_hint"]}
            hint = item.get("note", entry.get("note"))
            if hint:
                row["hint"] = hint
            if form:
                row["form"] = form
            spanish.append(row)
            for query in item["zh_queries"]:
                translated = dict(row)
                translated["input"] = normalize_pinyin(query["pinyin"])
                translated["query"] = query["text"]
                chinese.append(translated)
    spanish.sort(key=lambda item: (item["input"], item["text"], item["id"]))
    chinese.sort(key=lambda item: (item["input"], item["text"], item["query"], item["id"]))
    # Distinct Han homophones can yield the same code and same Spanish output.
    seen, unique_chinese = set(), []
    for row in chinese:
        identity = (row["input"], row["text"])
        if identity not in seen:
            seen.add(identity)
            unique_chinese.append(row)
    return {"entries": spanish, "chinese": unique_chinese}


def render_lua(data, source_sha256):
    lines = ["-- Generated by scripts/compile_spanish_learning.py; edit data/spanish-learning.json.",
             "-- Strings are decimal UTF-8 byte escapes. Data only; no source text is executed.",
             "-- SHA-256 of the exact source bytes: " + source_sha256,
             "return {", "  version = 1,", "  source_sha256 = " + lua_quote(source_sha256) + ","]
    fields = ("id", "input", "text", "meaning", "topic", "level", "query", "hint", "form")
    for section in ("entries", "chinese"):
        lines.append("  " + section + " = {")
        for row in data[section]:
            values = [field + " = " + lua_quote(row[field]) for field in fields if field in row]
            lines.append("    { " + ", ".join(values) + " },")
        lines.append("  },")
    return ("\n".join(lines) + "\n}\n").encode("utf-8")


def build_spanish_resources(source=DEFAULT_INPUT):
    data, checksum = load_spanish_learning(source)
    return {"lua/her_spanish_data.lua": render_lua(compile_data(data), checksum)}


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".spanish-learning-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        resources = build_spanish_resources(arguments.input)
        for name, content in resources.items():
            path = arguments.output_dir / name
            if arguments.check:
                if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
                    raise ValidationError("stale Spanish learning artifact: " + name)
            else:
                atomic_write(path, content)
    except (OSError, ValueError) as error:
        print("Could not compile Spanish learning data: " + str(error), file=sys.stderr)
        return 1
    print(("Checked" if arguments.check else "Compiled") + " Spanish learning table and curated Chinese queries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
