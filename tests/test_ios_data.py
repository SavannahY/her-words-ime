import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from compile_ios_data import (DEFAULT_OUTPUT, DEFAULT_PROJECT_DICTIONARY, DEFAULT_SOURCE,
                              MULTI_WORD_LIMIT, PINNED_SHA256, PROJECT_SEED_WEIGHT,
                              build_resources, digest, parse_dictionary, select_lexicon,
                              verify_source)
from compile_packs import compile_data
from validate_packs import DEFAULT_MANIFEST, load_project


class IOSDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = build_resources()
        cls.lexicon = json.loads(cls.resources["lexicon.json"])
        cls.entries = {(item["text"], item["pinyin"]): item for item in cls.lexicon}
        cls.upstream = parse_dictionary((DEFAULT_SOURCE / "pinyin_simp.dict.yaml").read_text(encoding="utf-8"))

    def test_checked_in_resources_are_reproducible_offline(self):
        self.assertEqual(self.resources, build_resources())
        for name, data in self.resources.items():
            self.assertEqual((DEFAULT_OUTPUT / name).read_bytes(), data, name + " requires regeneration")

    def test_all_upstream_single_character_readings_are_preserved(self):
        singles = {(entry["text"], entry["pinyin"]) for entry in self.upstream if len(entry["text"]) == 1}
        self.assertEqual(len(singles), 17_047)
        self.assertTrue(singles <= self.entries.keys())
        self.assertEqual(len({term for term, _reading in singles}), 16_472)

    def test_high_frequency_word_selection_is_complete_and_bounded(self):
        expected = sorted((entry for entry in self.upstream if len(entry["text"]) > 1),
                          key=lambda entry: (-entry["weight"], entry["text"], entry["pinyin"]))[:MULTI_WORD_LIMIT]
        self.assertEqual(len(expected), 30_000)
        for entry in expected:
            self.assertEqual(self.entries[(entry["text"], entry["pinyin"])]["weight"], entry["weight"])
        self.assertGreater(len(self.lexicon), 45_000)
        self.assertLess(len(self.lexicon), 50_000)
        self.assertLess(len(self.resources["lexicon.json"]), 3_000_000)

    def test_daily_words_polyphones_and_real_pinyin_are_usable(self):
        for term, reading in [("你好", "ni hao"), ("我们", "wo men"), ("谢谢", "xie xie"),
                              ("今天", "jin tian"), ("明天", "ming tian"), ("工作", "gong zuo"),
                              ("电脑", "dian nao"), ("妈妈", "ma ma"), ("北京", "bei jing"),
                              ("女本位", "nv ben wei"), ("女性友谊", "nv xing you yi"),
                              ("忮忌", "zhi ji"), ("圣女", "sheng nv"), ("季度", "ji du"),
                              ("行", "xing"), ("行", "hang"),
                              ("长", "chang"), ("长", "zhang")]:
            self.assertIn((term, reading), self.entries)
        self.assertNotIn(("忮忌", "ji du"), self.entries, "aliases must not masquerade as word pronunciations")
        self.assertEqual(len(self.entries), len(self.lexicon))
        for entry in self.lexicon:
            self.assertEqual(set(entry), {"text", "pinyin", "weight"})
            self.assertGreaterEqual(entry["weight"], 0)
            self.assertIsInstance(entry["weight"], int)
            self.assertEqual(len(entry["text"]), len(entry["pinyin"].split()))

    def test_all_existing_upstream_alias_homophones_survive_the_frequency_cutoff(self):
        rules = json.loads(self.resources["rules.json"])
        alias_inputs = {alias["input"] for alias in rules["exact_aliases"]}
        matched = [entry for entry in self.upstream if entry["pinyin"].replace(" ", "") in alias_inputs]
        self.assertEqual(len(matched), 36)
        for entry in matched:
            self.assertEqual(self.entries[(entry["text"], entry["pinyin"])], entry)
        self.assertEqual(self.entries[("圣女", "sheng nv")]["weight"], 189)
        # Do not fabricate a corpus frequency for a word absent upstream.
        self.assertNotIn(("剩女", "sheng nv"), self.entries)

    def test_brand_words_do_not_overwrite_public_homophone_frequencies(self):
        original = {(entry["text"], entry["pinyin"]): entry for entry in self.upstream}
        for key, entry in self.entries.items():
            if key in original:
                self.assertEqual(entry["weight"], original[key]["weight"])
        self.assertEqual(self.entries[("妳", "ni")]["weight"], original[("妳", "ni")]["weight"])
        self.assertGreater(self.entries[("你", "ni")]["weight"], self.entries[("妳", "ni")]["weight"])
        self.assertGreater(self.entries[("极度", "ji du")]["weight"], self.entries[("嫉妒", "ji du")]["weight"])
        for entry in parse_dictionary(DEFAULT_PROJECT_DICTIONARY.read_text(encoding="utf-8")):
            key = (entry["text"], entry["pinyin"])
            self.assertIn(key, self.entries)
            if key not in original:
                self.assertEqual(self.entries[key]["weight"], PROJECT_SEED_WEIGHT)

    def test_shared_rules_and_aliases_are_compiled_without_handwritten_copy(self):
        rules = json.loads(self.resources["rules.json"])
        self.assertEqual(rules, compile_data(load_project(DEFAULT_MANIFEST)))
        self.assertTrue(any(alias["input"] == "jidu" and alias["friendly"] == "忮忌"
                            for alias in rules["exact_aliases"]))
        self.assertTrue(any(rule["from"] == "剩女" and rule["match"] == "exact"
                            for rule in rules["rules"]))

    def test_source_lock_and_distributed_license_are_checked(self):
        metadata = verify_source(DEFAULT_SOURCE)
        self.assertEqual(metadata["license"], "Apache-2.0")
        for name, checksum in PINNED_SHA256.items():
            self.assertEqual(digest((DEFAULT_SOURCE / name).read_bytes()), checksum)
        self.assertEqual(self.resources["Rime-Pinyin-Simp-LICENSE.txt"], (DEFAULT_SOURCE / "LICENSE").read_bytes())
        self.assertEqual(self.resources["Rime-Pinyin-Simp-AUTHORS.txt"], (DEFAULT_SOURCE / "AUTHORS").read_bytes())
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            shutil.copytree(DEFAULT_SOURCE, source)
            with (source / "pinyin_simp.dict.yaml").open("ab") as stream:
                stream.write(b"\n# tampered source\n")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                verify_source(source)

    def test_parser_rejects_malformed_data_and_normalizes_umlaut(self):
        self.assertEqual(parse_dictionary("---\n...\n女\tnü\t12\n")[0]["pinyin"], "nv")
        for body in ("no data", "...\n女\tnv\t-1", "...\n女\tnv\t1;code",
                     "...\n女人\tnv\t1", "...\n女\tnv\t1\textra"):
            with self.assertRaises(ValueError):
                parse_dictionary(body)

    def test_selection_preserves_polyphones_and_has_deterministic_ties(self):
        source = [{"text": "行", "pinyin": "hang", "weight": 2},
                  {"text": "行", "pinyin": "xing", "weight": 9},
                  {"text": "你好", "pinyin": "ni hao", "weight": 8},
                  {"text": "你好", "pinyin": "ni hao", "weight": 3},
                  {"text": "妈妈", "pinyin": "ma ma", "weight": 7}]
        brand = [{"text": "你好", "pinyin": "ni hao", "weight": 1_000_000},
                 {"text": "女力", "pinyin": "nv li", "weight": 1_000_000}]
        lexicon, counts = select_lexicon(source, brand, multi_limit=1)
        entries = {(entry["text"], entry["pinyin"]): entry["weight"] for entry in lexicon}
        self.assertEqual(entries, {("行", "hang"): 2, ("行", "xing"): 9,
                                   ("你好", "ni hao"): 8, ("女力", "nv li"): PROJECT_SEED_WEIGHT})
        self.assertEqual(counts["selected_upstream_multi_character_readings"], 1)
        lexicon, counts = select_lexicon(source, brand, multi_limit=0, alias_inputs=["nihao"])
        entries = {(entry["text"], entry["pinyin"]): entry["weight"] for entry in lexicon}
        self.assertEqual(entries[("你好", "ni hao")], 8)
        self.assertEqual(counts["alias_restored_upstream_readings"], 1)


if __name__ == "__main__":
    unittest.main()
