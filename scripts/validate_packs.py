#!/usr/bin/env python3
"""Validate contributed language packs using only the Python standard library."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any, Dict, Tuple
from urllib.parse import urlsplit


DEFAULT_MANIFEST = Path(__file__).resolve().parents[1] / "language-packs.json"
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
# Canonical, unaccented full syllables. v represents ü for Rime input.
# Boundaries matter: xi an and xian are valid; jianren is not a syllable.
PINYIN_SYLLABLES = frozenset("""
a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi
chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du
duan dui dun duo e ei en eng er fa fan fang fei fen feng fo fou fu ga gai gan
gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han
hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia
jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke
kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao
le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun
luo lv lve m ma mai man mang mao me mei men meng mi mian miao mie min ming
miu mo mou mu n na nai nan nang nao ne nei nen neng ng ni nia nian niang niao
nie nin ning niu nong nou nu nuan nuo nv nve o ou pa pai pan pang pao pei pen
peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing
qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui
run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen
sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan
sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan
tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin
xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu
yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe
zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo
zi zong zou zu zuan zui zun zuo
""".split())


class ValidationError(ValueError):
    """A manifest or pack is invalid; no output should be installed."""


@dataclass(frozen=True)
class Pack:
    path: Path
    data: Dict[str, Any]


@dataclass(frozen=True)
class Project:
    manifest: Path
    neutral: Tuple[Pack, ...]
    community: Tuple[Pack, ...]


def _fail(location, message):
    raise ValidationError("{}: {}".format(location, message))


def _keys(value, required, optional, location):
    if not isinstance(value, dict):
        _fail(location, "must be an object")
    missing = required - value.keys()
    extra = value.keys() - required - optional
    if missing:
        _fail(location, "missing fields: " + ", ".join(sorted(missing)))
    if extra:
        _fail(location, "unknown fields: " + ", ".join(sorted(extra)))


def _text(value, location, minimum=1):
    if not isinstance(value, str) or len(value) < minimum or not value.strip():
        _fail(location, "must be a nonblank string of at least {} characters".format(minimum))
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        _fail(location, "invalid Unicode: unpaired surrogate")
    return value


def _identifier(value, location, slug=False):
    value = _text(value, location)
    if not (SLUG if slug else IDENTIFIER).fullmatch(value):
        _fail(location, "must be an ASCII " + ("lowercase slug" if slug else "identifier"))
    return value


def _array(value, location, minimum=0):
    if not isinstance(value, list) or len(value) < minimum:
        _fail(location, "must be an array with at least {} items".format(minimum))
    return value


def _version(value, location):
    if type(value) is not int or value != 1:
        _fail(location, "must be integer 1")


def _no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("duplicate JSON key: " + key)
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValidationError("non-JSON numeric constant: " + value)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"),
                          object_pairs_hook=_no_duplicate_keys,
                          parse_constant=_invalid_constant)
    except (OSError, UnicodeError, ValueError, RecursionError) as error:
        raise ValidationError("{}: {}".format(path, error)) from error


def normalize_pinyin(value, location="pinyin"):
    value = _text(value, location)
    if not re.fullmatch(r"[a-z]+(?: [a-z]+)*", value):
        _fail(location, "use lowercase ASCII syllables with single spaces; use v for ü")
    invalid = [part for part in value.split(" ") if part not in PINYIN_SYLLABLES]
    if invalid:
        _fail(location, "invalid pinyin syllable(s): " + ", ".join(invalid))
    return value.replace(" ", "")


def surfaces(entry):
    return [entry["from"]] + entry.get("variants", [])


def rewrite_literals(text, entries):
    """Match the runtime's leftmost/longest, noncascading literal semantics."""
    literals = [(source, entry["to"], entry["match"])
                for entry in entries for source in surfaces(entry)]
    literals.sort(key=lambda item: (-len(item[0].encode("utf-8")), item[0]))
    result, position = [], 0
    while position < len(text):
        selected = None
        for source, replacement, match in literals:
            if match == "exact" and text != source:
                continue
            index = text.find(source, position)
            if index != -1 and (selected is None or index < selected[0]):
                selected = (index, source, replacement)
        if selected is None:
            result.append(text[position:])
            break
        index, source, replacement = selected
        result.extend((text[position:index], replacement))
        position = index + len(source)
    return "".join(result)


def _validate_pack(path, kind):
    data, location = read_json(path), str(path)
    _keys(data, {"format", "version", "id", "name", "language", "kind", "license",
                 "description", "sources", "entries"}, set(), location)
    if data["format"] != "her-words-language-pack":
        _fail(location + ".format", "must be her-words-language-pack")
    _version(data["version"], location + ".version")
    _identifier(data["id"], location + ".id", slug=True)
    for field in ("name", "description"):
        _text(data[field], location + "." + field)
    if data["language"] != "zh-CN" or data["license"] != "MIT" or data["kind"] != kind:
        _fail(location, "language must be zh-CN, license MIT, and kind must match " + kind)
    source_ids = set()
    for index, source in enumerate(_array(data["sources"], location + ".sources", 1)):
        where = location + ".sources[{}]".format(index)
        _keys(source, {"id", "title", "url"}, set(), where)
        source_id = _identifier(source["id"], where + ".id")
        if source_id in source_ids:
            _fail(where, "duplicate source id: " + source_id)
        source_ids.add(source_id)
        _text(source["title"], where + ".title")
        url = _text(source["url"], where + ".url")
        try:
            parsed = urlsplit(url)
            valid = (parsed.scheme == "https" and parsed.hostname and not parsed.username
                     and not parsed.password and parsed.port != 0
                     and not any(char.isspace() or ord(char) < 32 for char in url))
        except ValueError:
            valid = False
        if not valid:
            _fail(where + ".url", "must be HTTPS with a host, no credentials or whitespace")
    entry_ids = set()
    entries = _array(data["entries"], location + ".entries", 1)
    for index, entry in enumerate(entries):
        where = location + ".entries[{}]".format(index)
        _keys(entry, {"id", "from", "to", "match", "note", "source_ids", "tests"},
              {"pinyin", "variants", "to_traditional"}, where)
        entry_id = _identifier(entry["id"], where + ".id")
        if entry_id in entry_ids:
            _fail(where, "duplicate entry id: " + entry_id)
        entry_ids.add(entry_id)
        _text(entry["from"], where + ".from", 2)
        _text(entry["to"], where + ".to")
        _text(entry["note"], where + ".note")
        if entry["match"] not in ("exact", "phrase"):
            _fail(where + ".match", "must be exact or phrase")
        if "to_traditional" in entry:
            _text(entry["to_traditional"], where + ".to_traditional")
        if "pinyin" in entry:
            normalize_pinyin(entry["pinyin"], where + ".pinyin")
        for variant in _array(entry.get("variants", []), where + ".variants"):
            _text(variant, where + ".variants", 2)
        if len(set(surfaces(entry))) != len(surfaces(entry)):
            _fail(where + ".variants", "duplicate source/variant literal")
        references = _array(entry["source_ids"], where + ".source_ids", 1)
        for source_id in references:
            _identifier(source_id, where + ".source_ids")
            if source_id not in source_ids:
                _fail(where + ".source_ids", "unknown source id: " + source_id)
        if len(set(references)) != len(references):
            _fail(where + ".source_ids", "duplicate source references")
        cases = _array(entry["tests"], where + ".tests", 1)
        for case in cases:
            _keys(case, {"input", "expected"}, set(), where + ".tests")
            for field in ("input", "expected"):
                if not isinstance(case[field], str):
                    _fail(where + ".tests." + field, "must be a string")
                try:
                    case[field].encode("utf-8")
                except UnicodeEncodeError:
                    _fail(where + ".tests." + field, "invalid Unicode")
        if not any(case["input"] == entry["from"] and case["expected"] == entry["to"] for case in cases):
            _fail(where + ".tests", "must include a direct from -> to case")
    return Pack(path, data)


def _resolve_reference(root, reference, location):
    reference = _text(reference, location)
    relative = PurePosixPath(reference)
    if (relative.is_absolute() or ".." in relative.parts or "\\" in reference
            or ":" in reference or relative.suffix != ".json"):
        _fail(location, "must reference a repository-contained relative .json file")
    try:
        resolved = (root / relative).resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError, RuntimeError):
        _fail(location, "reference is missing or escapes the repository, including via symlink")
    if not resolved.is_file():
        _fail(location, "must reference a regular JSON file")
    return resolved


def load_project(manifest=DEFAULT_MANIFEST):
    manifest = Path(manifest).resolve()
    root, data = manifest.parent, read_json(manifest)
    _keys(data, {"version", "neutral", "community"}, set(), str(manifest))
    _version(data["version"], str(manifest) + ".version")
    by_kind, paths, pack_ids = {}, set(), set()
    for kind in ("neutral", "community"):
        packs = []
        references = _array(data[kind], kind, 1 if kind == "neutral" else 0)
        for index, reference in enumerate(references):
            path = _resolve_reference(root, reference, kind + "[{}]".format(index))
            if path in paths:
                _fail(str(path), "pack referenced more than once")
            paths.add(path)
            pack = _validate_pack(path, kind)
            if pack.data["id"] in pack_ids:
                _fail(str(path), "duplicate pack id: " + pack.data["id"])
            pack_ids.add(pack.data["id"])
            packs.append(pack)
        by_kind[kind] = tuple(packs)
    canonical, literals = {}, {}
    for kind in ("neutral", "community"):
        canonical[kind], literals[kind] = {}, {}
        for pack in by_kind[kind]:
            for entry in pack.data["entries"]:
                for source in surfaces(entry):
                    if source in literals[kind]:
                        _fail(str(pack.path), "conflicting {} literal {!r}, also in {}".format(
                            kind, source, literals[kind][source]))
                    literals[kind][source] = str(pack.path) + "#" + entry["id"]
                canonical[kind][entry["from"]] = entry
    owners = {source: entry["from"] for pack in by_kind["neutral"]
              for entry in pack.data["entries"] for source in surfaces(entry)}
    for source, entry in canonical["community"].items():
        neutral = canonical["neutral"].get(source)
        if neutral is None:
            _fail("community", "override {!r} has no neutral entry with the same from".format(source))
        if neutral["match"] != entry["match"]:
            _fail("community", "override {!r} must have the same match mode as neutral".format(source))
        for variant in surfaces(entry):
            if variant in owners and owners[variant] != source:
                _fail("community", "variant {!r} conflicts with another neutral entry".format(variant))
            owners[variant] = source
    # Test each pack independently, without other packs or the pronoun preference.
    for packs in by_kind.values():
        for pack in packs:
            for entry in pack.data["entries"]:
                for case in entry["tests"]:
                    actual = rewrite_literals(case["input"], pack.data["entries"])
                    if actual != case["expected"]:
                        _fail(str(pack.path) + "#" + entry["id"],
                              "case {!r}: expected {!r}, got {!r}".format(
                                  case["input"], case["expected"], actual))
    return Project(manifest, by_kind["neutral"], by_kind["community"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    try:
        project = load_project(args.manifest)
    except ValidationError as error:
        print("Invalid language packs: " + str(error), file=sys.stderr)
        return 1
    packs = project.neutral + project.community
    print("Validated {} pack(s), {} entries and {} cases.".format(
        len(packs), sum(len(pack.data["entries"]) for pack in packs),
        sum(len(entry["tests"]) for pack in packs for entry in pack.data["entries"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
