#!/usr/bin/env python3
"""Rebuild iOS keyboard JSON from pinned public text and shared language packs.

Standard library only; no network, installed input method or user dictionary is
read. Upstream spelling/frequency data remains Apache-2.0, not the app's MIT.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    from .compile_packs import compile_data
    from .compile_public_lexicon import DEFAULT_INPUT as DEFAULT_PUBLIC_LEXICON, PUBLIC_SEED_WEIGHT, load_public_lexicon
    from .validate_packs import DEFAULT_MANIFEST, ValidationError, load_project
except ImportError:
    from compile_packs import compile_data
    from compile_public_lexicon import DEFAULT_INPUT as DEFAULT_PUBLIC_LEXICON, PUBLIC_SEED_WEIGHT, load_public_lexicon
    from validate_packs import DEFAULT_MANIFEST, ValidationError, load_project


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "ios/third_party/rime-pinyin-simp"
DEFAULT_OUTPUT = ROOT / "ios/Keyboard/Resources"
DEFAULT_PROJECT_DICTIONARY = ROOT / "rime/her_words.dict.yaml"
UPSTREAM_COMMIT = "0c6861ef7420ee780270ca6d993d18d4101049d0"
PINNED_SHA256 = {
    "pinyin_simp.dict.yaml": "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b",
    "LICENSE": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    "AUTHORS": "f4cff0fcbca4668ac449c24a53be547e162bc60cce63fdc5d5906801a452edc4",
    "README.md": "bc51038baf2408cc5ec9eba680634cfd4ec07f905a636644839daff1a94055c9",
}
MULTI_WORD_LIMIT = 30_000
PROJECT_SEED_WEIGHT = 200
PINYIN = re.compile(r"[a-z]+(?: [a-z]+)*\Z")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_write(path, data):
    # A complete new inode avoids partial resources and does not require reading
    # an old cloud-placeholder file before truncating it.
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".ios-data-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def encode_json(data, compact=False):
    # No dates, platform paths, bytecode or executable contributor data.
    options = {"separators": (",", ":")} if compact else {"indent": 2}
    return (json.dumps(data, ensure_ascii=False, sort_keys=True, **options) + "\n").encode("utf-8")


def verify_source(directory):
    directory = Path(directory)
    metadata = json.loads((directory / "SOURCE.json").read_text(encoding="utf-8"))
    if metadata.get("commit") != UPSTREAM_COMMIT or metadata.get("license") != "Apache-2.0":
        raise ValueError("upstream commit or license differs from the pinned source")
    for name, checksum in PINNED_SHA256.items():
        raw = (directory / name).read_bytes()
        if digest(raw) != checksum or metadata["files"][name]["sha256"] != checksum:
            raise ValueError("upstream SHA-256 mismatch: " + name)
    return metadata


def parse_dictionary(text):
    """Read the literal three-column Rime TSV section, not arbitrary YAML."""
    started = False
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        if not started:
            started = line.strip() == "..."
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError("expected text, pinyin and integer frequency at line " + str(number))
        term, reading, weight = fields
        reading = " ".join(reading.lower().replace("u:", "v").replace("ü", "v").split())
        if not term or not PINYIN.fullmatch(reading) or len(term) != len(reading.split()):
            raise ValueError("invalid spelling or character/syllable alignment at line " + str(number))
        try:
            frequency = int(weight)
        except ValueError:
            raise ValueError("invalid integer frequency at line " + str(number)) from None
        if frequency < 0:
            raise ValueError("negative frequency at line " + str(number))
        rows.append({"text": term, "pinyin": reading, "weight": frequency})
    if not started or not rows:
        raise ValueError("dictionary has no TSV data section")
    return rows


def select_lexicon(upstream, project_entries, multi_limit=MULTI_WORD_LIMIT, alias_inputs=()):
    if multi_limit < 0:
        raise ValueError("multi-word limit must be nonnegative")
    all_entries = {}
    for entry in upstream:
        key = (entry["text"], entry["pinyin"])
        if key not in all_entries or all_entries[key]["weight"] < entry["weight"]:
            all_entries[key] = dict(entry)
    single = [entry for entry in all_entries.values() if len(entry["text"]) == 1]
    multi = sorted((entry for entry in all_entries.values() if len(entry["text"]) > 1),
                   key=lambda entry: (-entry["weight"], entry["text"], entry["pinyin"]))[:multi_limit]
    selected = {(entry["text"], entry["pinyin"]): entry for entry in single + multi}
    # A frequency cutoff must not erase the normal whole-word baseline for a
    # configured alias. Keep every existing upstream homophone, including low
    # frequency words such as 圣女. Never invent a missing upstream frequency.
    alias_codes = set(alias_inputs)
    alias_matches = [entry for entry in all_entries.values()
                     if entry["pinyin"].replace(" ", "") in alias_codes]
    restored_aliases = 0
    for entry in alias_matches:
        key = (entry["text"], entry["pinyin"])
        if key not in selected:
            selected[key] = entry
            restored_aliases += 1
    added_new = added_upstream = 0
    for entry in project_entries:
        key = (entry["text"], entry["pinyin"])
        if key in selected:
            continue
        if key in all_entries:
            # Preserve genuine source frequencies, even for a brand word that
            # fell below the multi-word cutoff. Do not turn every word into 1M.
            selected[key] = all_entries[key]
            added_upstream += 1
        else:
            selected[key] = {"text": entry["text"], "pinyin": entry["pinyin"],
                             "weight": PROJECT_SEED_WEIGHT}
            added_new += 1
    lexicon = sorted(selected.values(), key=lambda entry: (entry["pinyin"], -entry["weight"], entry["text"]))
    return lexicon, {
        "upstream_readings": len(all_entries),
        "upstream_single_character_readings": len(single),
        "upstream_unique_single_characters": len({entry["text"] for entry in single}),
        "selected_upstream_multi_character_readings": len(multi),
        "alias_input_codes": len(alias_codes),
        "upstream_alias_readings": len(alias_matches),
        "alias_restored_upstream_readings": restored_aliases,
        "project_dictionary_readings": len(project_entries),
        "project_added_new_readings": added_new,
        "project_restored_upstream_readings": added_upstream,
        "lexicon_readings": len(lexicon),
        "lexicon_unique_texts": len({entry["text"] for entry in lexicon}),
        "maximum_weight": max(entry["weight"] for entry in lexicon),
    }


def merge_public_lexicon(lexicon, upstream, public):
    """Preserve baseline frequencies/ranking; new public words are supplements.

    Aliases are explicit metadata, never dictionary pronunciations. A word that
    was already selected stays ordinary; restored/new public words are offered
    after the first ordinary candidate by the native input engine.
    """
    selected = {(entry["text"], entry["pinyin"]): dict(entry) for entry in lexicon}
    originals = {(entry["text"], entry["pinyin"]): entry for entry in upstream}
    added = restored = aliases = 0
    for item in public["entries"]:
        key = (item["text"], item["pinyin"])
        if key not in selected:
            if key in originals:
                selected[key] = dict(originals[key])
                restored += 1
            else:
                selected[key] = {"text": item["text"], "pinyin": item["pinyin"], "weight": PUBLIC_SEED_WEIGHT}
                added += 1
            selected[key]["supplemental"] = True
        selected[key]["category"] = item["category"]
        if item.get("aliases"):
            selected[key]["aliases"] = sorted(item["aliases"])
            aliases += len(item["aliases"])
    return sorted(selected.values(), key=lambda entry: (entry["pinyin"], -entry["weight"], entry["text"])), {
        "public_readings": len(public["entries"]), "public_added_new_readings": added,
        "public_restored_upstream_readings": restored, "public_english_aliases": aliases,
    }


def build_resources(manifest=DEFAULT_MANIFEST, source_dir=DEFAULT_SOURCE,
                    project_dictionary=DEFAULT_PROJECT_DICTIONARY, multi_limit=MULTI_WORD_LIMIT,
                    public_directory=DEFAULT_PUBLIC_LEXICON):
    source_dir, project_dictionary = Path(source_dir), Path(project_dictionary)
    upstream = verify_source(source_dir)
    raw = (source_dir / "pinyin_simp.dict.yaml").read_text(encoding="utf-8")
    project_text = project_dictionary.read_text(encoding="utf-8")
    project = load_project(Path(manifest))
    rules = compile_data(project)
    parsed_upstream = parse_dictionary(raw)
    lexicon, counts = select_lexicon(parsed_upstream, parse_dictionary(project_text), multi_limit,
                                   [alias["input"] for alias in rules["exact_aliases"]])
    public = load_public_lexicon(public_directory)
    lexicon, public_counts = merge_public_lexicon(lexicon, parsed_upstream, public)
    counts.update(public_counts)
    counts["lexicon_readings"] = len(lexicon)
    counts["lexicon_unique_texts"] = len({entry["text"] for entry in lexicon})
    payloads = {
        "lexicon.json": encode_json(lexicon, compact=True),
        # Keep exact_aliases separate: e.g. 忮忌 has real pinyin zhi ji;
        # jidu is an optional spelling alias, never its dictionary pronunciation.
        "rules.json": encode_json(rules, compact=True),
        "Rime-Pinyin-Simp-LICENSE.txt": (source_dir / "LICENSE").read_bytes(),
        "Rime-Pinyin-Simp-AUTHORS.txt": (source_dir / "AUTHORS").read_bytes(),
    }
    info = {
        "format": "her-words-ios-data", "version": 1,
        "upstream": upstream,
        "selection": {"multi_word_limit": multi_limit,
                      "all_upstream_single_character_readings": True,
                      "all_upstream_whole_word_alias_homophones": True,
                      "project_new_reading_seed_weight": PROJECT_SEED_WEIGHT,
                      "public_new_reading_seed_weight": PUBLIC_SEED_WEIGHT,
                      "public_supplements_follow_ordinary_first_candidate": True,
                      "upstream_frequency_preserved": True},
        "counts": counts,
        "public_lexicon": {"version": public["version"], "sources": public["sources"], "files": public["files"]},
        "source_sha256": {"project_dictionary": digest(project_text.encode("utf-8")),
                          "manifest": digest(project.manifest.read_bytes()),
                          "packs": {pack.data["id"]: digest(pack.path.read_bytes())
                                    for pack in project.neutral + project.community}},
        "files": {name: {"bytes": len(value), "sha256": digest(value)}
                  for name, value in sorted(payloads.items())},
    }
    payloads["data-info.json"] = encode_json(info)
    return payloads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--project-dictionary", type=Path, default=DEFAULT_PROJECT_DICTIONARY)
    parser.add_argument("--public-directory", type=Path, default=DEFAULT_PUBLIC_LEXICON)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--multi-word-limit", type=int, default=MULTI_WORD_LIMIT)
    parser.add_argument("--check", action="store_true", help="verify committed resources without writing")
    args = parser.parse_args()
    try:
        resources = build_resources(args.manifest, args.source_dir, args.project_dictionary, args.multi_word_limit, args.public_directory)
        if args.check:
            stale = [name for name, data in resources.items()
                     if not (args.output_dir / name).is_file() or (args.output_dir / name).read_bytes() != data]
            if stale:
                raise ValueError("iOS resources are stale: " + ", ".join(stale))
        else:
            args.output_dir.mkdir(parents=True, exist_ok=True)
            for name, data in resources.items():
                atomic_write(args.output_dir / name, data)
    except (ValidationError, OSError, ValueError, KeyError) as error:
        print("Could not compile iOS data: " + str(error), file=sys.stderr)
        return 1
    info = json.loads(resources["data-info.json"])
    print("{} {} offline readings, {} bytes of lexicon JSON".format(
        "Checked" if args.check else "Compiled", info["counts"]["lexicon_readings"],
        len(resources["lexicon.json"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
