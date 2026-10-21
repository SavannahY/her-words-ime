import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from compile_ios_data import merge_public_lexicon, parse_dictionary
from compile_public_lexicon import (DEFAULT_OUTPUT, PUBLIC_SEED_WEIGHT, build_public_resources,
                                    load_public_lexicon, validate_file)
from validate_packs import ValidationError


def fixture():
    return {
        "version": 1,
        "sources": [{"id": "test-official", "title": "Official name and spelling", "url": "https://example.org/names"}],
        "entries": [
            {"text": "屠呦呦", "pinyin": "tu you you", "category": "woman", "source_ids": ["test-official"], "tags": ["scientist"]},
            {"text": "西蒙娜·德·波伏瓦", "pinyin": "xi meng na de bo fu wa", "category": "woman", "source_ids": ["test-official"]},
            {"text": "自强不息", "pinyin": "zi qiang bu xi", "category": "idiom", "source_ids": ["test-official"]},
            {"text": "宜家", "pinyin": "yi jia", "category": "brand", "source_ids": ["test-official"], "aliases": ["ikea"],
             "note": "Official name, not a brand endorsement."},
        ],
    }


class PublicLexiconTests(unittest.TestCase):
    def test_checked_in_public_artifacts_are_reproducible(self):
        resources = build_public_resources()
        self.assertEqual(resources, build_public_resources())
        for name, data in resources.items():
            self.assertEqual((DEFAULT_OUTPUT / name).read_bytes(), data, name + " must be regenerated")

    def test_sources_are_referenced_and_notes_are_metadata_only(self):
        data = fixture()
        data["entries"][3]["note"] = 'os.execute("not executable") -- source context only'
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "fixture.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            catalog = load_public_lexicon(source)
            self.assertEqual(len(catalog["entries"]), 4)
            output = build_public_resources(source)
            self.assertNotIn(b"os.execute", output["lua/her_public_aliases.lua"])
            dictionary = output["her_public.dict.yaml"].decode()
            self.assertIn("宜家\tyi jia\t1\n", dictionary)
            self.assertIn("西蒙娜·德·波伏瓦\txi meng na de bo fu wa\t1\n", dictionary)
            self.assertNotIn("宜家\tikea", dictionary)
            before = output
            data["entries"].reverse()
            (source / "fixture.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            self.assertEqual(before, build_public_resources(source))

    def test_rejects_unknown_fields_and_fabricated_alias_pronunciations(self):
        mutations = [
            lambda value: value.update(version=True),
            lambda value: value.update(executable="forbidden"),
            lambda value: value["entries"][0].update(weight=1_000_000),
            lambda value: value["entries"][0].update(category=[]),
            lambda value: value["entries"][0].update(source_ids=["missing"]),
            lambda value: value["entries"][0].update(pinyin="tuyouyou"),
            lambda value: value["entries"][0].update(pinyin="tu you"),
            lambda value: value["entries"][0].update(pinyin="tu you github"),
            lambda value: value["entries"][0].update(text="屠\t呦呦"),
            lambda value: value["entries"][0].update(text="·屠呦呦"),
            lambda value: value["entries"][0].update(aliases=["tyy"]),
            lambda value: value["entries"][3].update(aliases=["IKEA"]),
            lambda value: value["entries"][3].update(aliases=["i-kea"]),
            lambda value: value["entries"][3].update(aliases=["ikea", "ikea"]),
            lambda value: value["entries"][3].update(tags=["unknown field"]),
            lambda value: value["entries"][3].update(note="长" * 241),
            lambda value: value["sources"][0].update(url="https://user:secret@example.org/names"),
            lambda value: value["sources"][0].update(url="https://[broken-ipv6/names"),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                value = fixture()
                mutation(value)
                with self.assertRaises(ValidationError):
                    validate_file(value, "fixture.json")

    def test_duplicate_json_and_cross_file_readings_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            path = source / "fixture.json"
            path.write_text('{"version":1,"version":1,"sources":[],"entries":[]}', encoding="utf-8")
            with self.assertRaises(ValidationError):
                load_public_lexicon(source)
            value = fixture()
            path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
            (source / "duplicate.json").write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(ValidationError):
                load_public_lexicon(source)

    def test_public_selection_preserves_frequencies_and_marks_only_new_supplements(self):
        baseline = [{"text": "一家", "pinyin": "yi jia", "weight": 900},
                    {"text": "宜家", "pinyin": "yi jia", "weight": 25}]
        upstream = baseline + [{"text": "自强不息", "pinyin": "zi qiang bu xi", "weight": 14}]
        public = {"entries": fixture()["entries"]}
        selected, counts = merge_public_lexicon(baseline, upstream, public)
        values = {(row["text"], row["pinyin"]): row for row in selected}
        self.assertEqual(values[("一家", "yi jia")], baseline[0])
        self.assertEqual(values[("宜家", "yi jia")]["weight"], 25)
        self.assertEqual(values[("宜家", "yi jia")]["aliases"], ["ikea"])
        self.assertNotIn("supplemental", values[("宜家", "yi jia")])
        self.assertEqual(values[("自强不息", "zi qiang bu xi")]["weight"], 14)
        self.assertTrue(values[("自强不息", "zi qiang bu xi")]["supplemental"])
        self.assertEqual(values[("屠呦呦", "tu you you")]["weight"], PUBLIC_SEED_WEIGHT)
        self.assertTrue(values[("屠呦呦", "tu you you")]["supplemental"])
        self.assertNotIn(("宜家", "ikea"), values)
        self.assertEqual(counts["public_added_new_readings"], 2)
        self.assertEqual(counts["public_restored_upstream_readings"], 1)
        self.assertEqual(baseline[1], {"text": "宜家", "pinyin": "yi jia", "weight": 25})

    def test_public_middle_dots_do_not_weaken_the_upstream_parser(self):
        validate_file(fixture(), "fixture.json")
        with self.assertRaises(ValueError):
            parse_dictionary("...\n西蒙娜·德·波伏瓦\txi meng na de bo fu wa\t1\n")


if __name__ == "__main__":
    unittest.main()
