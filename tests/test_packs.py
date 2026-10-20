"""Pack validation and compilation regressions; standard-library unittest only."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from compile_packs import compile_data, compile_project, lua_quote  # noqa: E402
from validate_packs import ValidationError, load_project, normalize_pinyin, rewrite_literals  # noqa: E402


def entry(source="原词", target="中性表达", reading="yuan ci", **extra):
    value = {
        "id": "entry-" + str(sum(ord(char) for char in source)),
        "from": source, "to": target, "match": "phrase",
        "note": "Explicit editorial preference with a documented source.",
        "source_ids": ["reference"],
        "tests": [{"input": source, "expected": target}],
    }
    if reading is not None:
        value["pinyin"] = reading
    value.update(extra)
    return value


def pack(kind="neutral", entries=None, identifier=None):
    return {
        "format": "her-words-language-pack", "version": 1,
        "id": identifier or kind + "-test", "name": "测试语言包",
        "language": "zh-CN", "kind": kind, "license": "MIT",
        "description": "A test pack.",
        "sources": [{"id": "reference", "title": "Editorial reference",
                     "url": "https://github.com/example/her-words-ime/blob/main/docs/wording.md"}],
        "entries": entries if entries is not None else [entry()],
    }


class PackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = self.root / "language-packs.json"
        self.neutral = pack()
        self.community = None
        self.write_project()

    def write(self, path, value):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def write_project(self):
        self.write("packs/neutral.json", self.neutral)
        manifest = {"version": 1, "neutral": ["packs/neutral.json"], "community": []}
        if self.community is not None:
            self.write("packs/community.json", self.community)
            manifest["community"] = ["packs/community.json"]
        self.write("language-packs.json", manifest)

    def reject(self, pattern=None):
        with self.assertRaisesRegex(ValidationError, pattern or "."):
            load_project(self.manifest)

    def test_repository_packs_validate_and_compile(self):
        project = load_project(ROOT / "language-packs.json")
        self.assertTrue(project.neutral)
        compiled = compile_data(project)
        self.assertTrue(compiled["rules"])
        self.assertTrue(compiled["exact_aliases"])
        self.assertEqual(compile_project(project), compile_project(project))

    def test_neutral_pack_and_optional_pinyin(self):
        self.neutral["entries"][0].pop("pinyin")
        self.write_project()
        data = compile_data(load_project(self.manifest))
        self.assertEqual(data["rules"][0]["to"], "中性表达")
        self.assertEqual(data["exact_aliases"], [])
        self.assertNotIn("community", data["rules"][0])

    def test_community_inherits_neutral_and_both_variant_sets(self):
        self.neutral["entries"] = [entry(variants=["異文"], to_traditional="中性表達")]
        self.community = pack("community", [entry(target="社群写法", variants=["别字"],
                                                 to_traditional="社群寫法")])
        self.write_project()
        data = compile_data(load_project(self.manifest))
        self.assertEqual({rule["from"] for rule in data["rules"]}, {"原词", "異文", "别字"})
        for rule in data["rules"]:
            self.assertEqual(rule["to"], "中性表达")
            self.assertEqual(rule["community"], "社群写法")
            self.assertEqual(rule["to_traditional"], "中性表達")
            self.assertEqual(rule["community_traditional"], "社群寫法")
        self.assertEqual(len(data["exact_aliases"]), 1)
        self.assertEqual(data["exact_aliases"][0]["community_note"], "借字或拆字写法")

    def test_missing_neutral_fallback_rejected(self):
        self.community = pack("community", [entry(source="新词")])
        self.write_project()
        self.reject("no neutral entry")

    def test_explicit_identity_fallback_allowed(self):
        self.neutral["entries"] = [entry(target="原词")]
        self.community = pack("community", [entry(target="社群词")])
        self.write_project()
        self.assertEqual(compile_data(load_project(self.manifest))["rules"][0]["to"], "原词")

    def test_override_match_must_agree(self):
        self.community = pack("community", [entry(match="exact")])
        self.write_project()
        self.reject("same match")

    def test_same_kind_conflicts_even_if_identical(self):
        self.write("packs/second.json", pack(identifier="second-pack"))
        self.write("language-packs.json", {
            "version": 1, "neutral": ["packs/neutral.json", "packs/second.json"], "community": []})
        self.reject("conflicting neutral literal")

    def test_same_kind_variants_conflict(self):
        self.neutral["entries"] = [entry(variants=["另一词"]), entry("另一词", reading=None)]
        self.write_project()
        self.reject("conflicting neutral literal")

    def test_community_variant_cannot_capture_another_neutral_entry(self):
        self.neutral["entries"] += [entry("另一词", reading=None)]
        self.community = pack("community", [entry(target="社群词", variants=["另一词"])])
        self.write_project()
        self.reject("conflicts with another neutral")

    def test_one_character_rules_or_variants_rejected(self):
        for field, value in (("from", "女"), ("variants", ["女"])):
            with self.subTest(field=field):
                self.neutral = pack()
                self.neutral["entries"][0][field] = value
                self.write_project()
                self.reject("at least 2")

    def test_strict_shape_and_nonblank_fields(self):
        mutations = [
            lambda p: p.update(unknown="os.execute('bad')"),
            lambda p: p.update(version=True),
            lambda p: p["entries"][0].update(note="  "),
            lambda p: p["entries"][0].update(to=""),
            lambda p: p["entries"][0].update(tests=[]),
            lambda p: p["entries"][0].update(match="pattern"),
            lambda p: p["entries"][0].update(from_regex=".*"),
            lambda p: p["entries"][0].update(variants=[None]),
            lambda p: p["entries"][0].update(to="\ud800"),
            lambda p: p["entries"][0]["tests"][0].update(expected=5),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                self.neutral = pack()
                mutate(self.neutral)
                # ensure_ascii=True can serialize an intentionally invalid surrogate.
                self.write("packs/neutral.json", pack())
                (self.root / "packs/neutral.json").write_text(
                    json.dumps(self.neutral, ensure_ascii=True), encoding="utf-8")
                self.reject()

    def test_source_reference_and_https_validation(self):
        self.neutral["entries"][0]["source_ids"] = ["missing"]
        self.write_project()
        self.reject("unknown source")
        for url in ("http://example.org", "https://", "https://user:pass@example.org",
                    "https://example.org/\ncode", "javascript:alert(1)"):
            with self.subTest(url=url):
                self.neutral = pack()
                self.neutral["sources"][0]["url"] = url
                self.write_project()
                self.reject("HTTPS")

    def test_duplicate_json_keys_and_non_json_numbers_rejected(self):
        for content in ('{"version":1,"version":1}', '{"version":NaN}'):
            with self.subTest(content=content):
                self.manifest.write_text(content, encoding="utf-8")
                self.reject("duplicate JSON key|non-JSON")

    def test_paths_cannot_escape_or_repeat(self):
        references = ["../outside.json", "/tmp/outside.json", "packs\\neutral.json",
                      "C:/outside.json", "https://example.org/pack.json", "packs/neutral.txt",
                      "packs/missing.json"]
        for reference in references:
            with self.subTest(reference=reference):
                self.write("language-packs.json", {"version": 1, "neutral": [reference], "community": []})
                self.reject("relative|missing|escapes")
        self.write("language-packs.json", {
            "version": 1, "neutral": ["packs/neutral.json", "packs/neutral.json"], "community": []})
        self.reject("more than once")

    def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            destination = Path(outside) / "outside.json"
            destination.write_text(json.dumps(pack()), encoding="utf-8")
            (self.root / "packs/escape.json").symlink_to(destination)
            self.write("language-packs.json", {
                "version": 1, "neutral": ["packs/escape.json"], "community": []})
            self.reject("escapes")

    def test_direct_case_required_and_all_cases_executed(self):
        self.neutral["entries"][0]["tests"] = [{"input": "正常词", "expected": "正常词"}]
        self.write_project()
        self.reject("direct from")
        self.neutral = pack()
        self.neutral["entries"][0]["tests"].append({"input": "正常词", "expected": "错误"})
        self.write_project()
        self.reject("expected.*错误")

    def test_longest_literal_single_pass_and_exact_boundaries(self):
        entries = [{"from": "甲甲", "to": "乙乙", "match": "phrase"},
                   {"from": "乙乙", "to": "丙丙", "match": "phrase"},
                   {"from": "甲甲甲甲", "to": "丁丁", "match": "phrase"}]
        self.assertEqual(rewrite_literals("甲甲甲甲甲甲", entries), "丁丁乙乙")
        self.assertEqual(rewrite_literals("甲甲乙乙", entries), "乙乙丙丙")
        exact = [{"from": "女神", "to": "榜样", "match": "exact"}]
        self.assertEqual(rewrite_literals("女神", exact), "榜样")
        self.assertEqual(rewrite_literals("女神像", exact), "女神像")
        self.assertEqual(rewrite_literals("a+b%[x]", [
            {"from": "a+b%[x]", "to": "100%好", "match": "phrase"}]), "100%好")

    def test_pinyin_has_explicit_syllable_boundaries(self):
        for reading, normalized in (("jian ren", "jianren"), ("xi an", "xian"),
                                    ("xian", "xian"), ("nv lv", "nvlv")):
            with self.subTest(reading=reading):
                self.assertEqual(normalize_pinyin(reading), normalized)
        for reading in ("jianren", "ji  du", " ji du", "ji du ", "ji\ndu", "ji\tdu",
                        "JI DU", "jí dù", "nü", "ji'du", "ji-du", 'ji"); os.execute("bad',
                        "ji du\0", "xxxx", "j d"):
            with self.subTest(reading=reading):
                with self.assertRaises(ValidationError):
                    normalize_pinyin(reading)

    def test_same_raw_pinyin_retains_distinct_suggestions(self):
        self.neutral["entries"] = [entry("西安", "第一", "xi an"),
                                    entry("先行", "第二", "xian")]
        self.write_project()
        aliases = compile_data(load_project(self.manifest))["exact_aliases"]
        self.assertEqual([(item["input"], item["friendly"]) for item in aliases],
                         [("xian", "第一"), ("xian", "第二")])
        self.neutral["entries"][1]["to"] = "第一"
        self.neutral["entries"][1]["tests"][0]["expected"] = "第一"
        self.write_project()
        self.assertEqual(len(compile_data(load_project(self.manifest))["exact_aliases"]), 1)

    def test_lua_payload_encoded_as_inert_utf8_data(self):
        payload = '"; os.execute("never execute") --\n\0\\2559 中文%'
        self.neutral["entries"] = [entry(target=payload)]
        self.write_project()
        output = compile_project(load_project(self.manifest))
        self.assertNotIn("os.execute", output)
        quoted = lua_quote(payload)
        self.assertRegex(quoted, r'^"(?:\\[0-9]{3})*"$')
        decoded = bytes(int(part) for part in re.findall(r"\\([0-9]{3})", quoted)).decode("utf-8")
        self.assertEqual(decoded, payload)
        self.assertIn(quoted, output)
        self.assertEqual(lua_quote("a9"), '"\\097\\057"')

    def test_cli_deterministic_and_does_not_overwrite_on_invalid_input(self):
        output = self.root / "build/rules.lua"
        command = [sys.executable, "-B", str(ROOT / "scripts/compile_packs.py"),
                   "--manifest", str(self.manifest), "--output", str(output)]
        subprocess.run(command, check=True, capture_output=True)
        first = output.read_bytes()
        subprocess.run(command, check=True, capture_output=True)
        self.assertEqual(output.read_bytes(), first)
        self.neutral["entries"][0]["from"] = "女"
        self.write_project()
        failed = subprocess.run(command, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(output.read_bytes(), first)

    def test_schema_is_draft_2020_and_rejects_unknown_fields(self):
        schema = json.loads((ROOT / "schemas/pack.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        for shape in (schema, schema["$defs"]["entry"], schema["$defs"]["source"],
                      schema["$defs"]["case"]):
            self.assertFalse(shape["additionalProperties"])
        pinyin_pattern = schema["$defs"]["entry"]["properties"]["pinyin"]["pattern"]
        self.assertIsNotNone(re.fullmatch(pinyin_pattern, "jian ren"))
        self.assertIsNone(re.fullmatch(pinyin_pattern, "jianren"))


if __name__ == "__main__":
    unittest.main()
