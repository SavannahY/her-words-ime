"""Contracts for original learning data, exact lookup codes and inert generation."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import compile_spanish_learning as compiler
from compile_packs import lua_quote
from validate_packs import ValidationError


def fixture():
    return {
        "version": 1,
        "language": "es",
        "sources": [{"id": "official", "title": "Grammar and word forms", "url": "https://example.org/grammar"}],
        "entries": [{
            "id": "es-nationality", "text": "Soy china.", "input": "soy china", "compact_input": "soychina",
            "meaning_zh": "我是中国人。〔女性说话者〕", "topic": "introductions", "level_hint": "A1",
            "source_ids": ["official"], "provenance": "original_example",
            "zh_queries": [{"text": "我是中国人", "pinyin": "wo shi zhong guo ren"}],
            "variants": [{"text": "Soy chino.", "input": "soy chino", "compact_input": "soychino",
                          "meaning_zh": "我是中国人。〔男性说话者〕", "grammatical_form": "masculine_speaker",
                          "source_ids": ["official"],
                          "zh_queries": [{"text": "我是中国男性", "pinyin": "wo shi zhong guo nan xing"}]}],
        }, {
            "id": "es-question", "text": "¿Cómo estás?", "input": "como estas", "compact_input": "comoestas",
            "meaning_zh": "你好吗？", "topic": "greetings", "level_hint": "A1", "source_ids": ["official"],
            "provenance": "common_expression_verified", "zh_queries": [{"text": "你好吗", "pinyin": "ni hao ma"}],
        }],
    }


def write_fixture(path, data=None):
    path.write_text(json.dumps(fixture() if data is None else data, ensure_ascii=False) + "\n", encoding="utf-8")


class SpanishLearningTests(unittest.TestCase):
    def test_real_catalog_covers_every_form_and_every_chinese_query(self):
        data, checksum = compiler.load_spanish_learning()
        rows = compiler.compile_data(data)
        expected = {item["text"] for entry in data["entries"] for item in [entry] + entry.get("variants", [])}
        self.assertEqual(len(data["entries"]), 69)
        self.assertEqual(len(expected), 76)
        self.assertEqual({row["text"] for row in rows["entries"]}, expected)
        self.assertEqual(len(rows["entries"]), 76)
        self.assertEqual(len(rows["chinese"]), 86)
        self.assertEqual(checksum, hashlib.sha256(compiler.DEFAULT_INPUT.read_bytes()).hexdigest())
        chinese = {(row["input"], row["text"]) for row in rows["chinese"]}
        for code, text in [("nihao", "Hola."), ("xiexie", "Gracias."),
                           ("wozhengzaixuexibanyayu", "Estoy aprendiendo español."),
                           ("woshizhongguoren", "Soy china."), ("woshizhongguonanxing", "Soy chino."),
                           ("qingninzaishuoyibian", "¿Puede repetir, por favor?"),
                           ("huanyingnvsheng", "¡Bienvenida!"), ("huanyingnansheng", "¡Bienvenido!")]:
            self.assertIn((code, text), chinese)
        self.assertNotIn(("suibianfanyiyijuhua", "Hola."), chinese)

    def test_checked_in_lua_is_reproducible_and_contains_only_expected_resource(self):
        resources = compiler.build_spanish_resources()
        self.assertEqual(set(resources), {"lua/her_spanish_data.lua"})
        self.assertEqual(resources, compiler.build_spanish_resources())
        for name, content in resources.items():
            self.assertEqual((compiler.DEFAULT_OUTPUT / name).read_bytes(), content)
        source, checksum = compiler.load_spanish_learning()
        lua = resources["lua/her_spanish_data.lua"].decode("utf-8")
        self.assertIn("-- SHA-256 of the exact source bytes: " + checksum, lua)
        self.assertIn("source_sha256 = " + lua_quote(checksum), lua)
        self.assertIn("text = " + lua_quote("¿Cómo estás?"), lua)
        self.assertIn("text = " + lua_quote("Tengo sueño."), lua)
        self.assertNotIn("cervantes.es", lua, "source metadata must not become candidate content")
        self.assertNotIn("https://", lua)

    def test_flattening_keeps_meaning_separate_and_includes_masculine_variants(self):
        data = fixture()
        self.assertIs(compiler.validate_spanish_learning(data), data)
        rows = compiler.compile_data(data)
        by_text = {row["text"]: row for row in rows["entries"]}
        self.assertEqual(by_text["Soy chino."]["input"], "soychino")
        self.assertEqual(by_text["Soy chino."]["meaning"], "我是中国人。〔男性说话者〕")
        self.assertEqual(by_text["Soy chino."]["form"], "masculine_speaker")
        self.assertEqual({row["text"] for row in rows["chinese"]}, set(by_text))
        self.assertTrue(all("meaning" in row and "query" in row for row in rows["chinese"]))
        self.assertTrue(all(row["text"] != row["meaning"] for row in rows["entries"]))

    def test_lookup_normalization_preserves_distinct_accented_outputs(self):
        self.assertEqual(compiler.ascii_input("¿Cómo estás?"), "como estas")
        self.assertEqual(compiler.ascii_input("¡PINGÜINO, mañana!"), "pinguino manana")
        data = fixture()
        data["entries"] = []
        for value, meaning, query, pinyin in [("sí", "是", "是", "shi"), ("si", "如果", "如果", "ru guo")]:
            data["entries"].append({"id": "es-" + query.encode().hex(), "text": value, "input": "si",
                                    "compact_input": "si", "meaning_zh": meaning, "topic": "responses",
                                    "level_hint": "A1", "source_ids": ["official"], "provenance": "lexical_fact",
                                    "zh_queries": [{"text": query, "pinyin": pinyin}]})
        compiler.validate_spanish_learning(data)
        rows = compiler.compile_data(data)["entries"]
        self.assertEqual({row["text"] for row in rows if row["input"] == "si"}, {"sí", "si"})

    def test_rejects_unknown_fields_wrong_types_unbounded_and_non_nfc_text(self):
        mutations = [
            lambda d: d.update(version=True), lambda d: d.update(language="zh"),
            lambda d: d.update(executable="return os.execute('bad')"),
            lambda d: d.update(entries=[]), lambda d: d.update(sources=[]),
            lambda d: d["entries"][0].update(weight=9999),
            lambda d: d["entries"][0].update(topic=[]),
            lambda d: d["entries"][0].update(level_hint=[]),
            lambda d: d["entries"][0].update(provenance=[]),
            lambda d: d["entries"][0].update(text="中国"),
            lambda d: d["entries"][0].update(text="Hola\u200b"),
            lambda d: d["entries"][0].update(text="Hola\n"),
            lambda d: d["entries"][0].update(text="hola" * 41),
            lambda d: d["entries"][1].update(text="¿Co\u0301mo estás?"),
            lambda d: d["entries"][0].update(meaning_zh="\ud800"),
            lambda d: d["entries"][0].update(note="备注" * 121),
            lambda d: d["sources"][0].update(checked_via=[]),
            lambda d: d["sources"][0].update(title="e\u0301"),
            lambda d: d["sources"][0].update(scope="说明\u202e"),
            lambda d: d["sources"][0].update(extra="unknown"),
            lambda d: d["entries"][0]["variants"][0].update(extra="unknown"),
            lambda d: d["entries"][0]["variants"][0].update(grammatical_form=[]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                data = fixture()
                mutate(data)
                with self.assertRaises(ValidationError):
                    compiler.validate_spanish_learning(data)

    def test_rejects_fake_pinyin_mismatched_codes_and_incomplete_punctuation(self):
        mutations = [
            lambda d: d["entries"][0].update(input="soyChina"),
            lambda d: d["entries"][0].update(input="soychina"),
            lambda d: d["entries"][0].update(input="soy chino"),
            lambda d: d["entries"][0].update(compact_input="soy china"),
            lambda d: d["entries"][0].update(compact_input=[]),
            lambda d: d["entries"][0]["zh_queries"][0].update(text="我是 Chinese"),
            lambda d: d["entries"][0]["zh_queries"][0].update(pinyin="woshizhongguoren"),
            lambda d: d["entries"][0]["zh_queries"][0].update(pinyin="wo shi github guo ren"),
            lambda d: d["entries"][0]["zh_queries"][0].update(pinyin="w s z g r"),
            lambda d: d["entries"][0]["zh_queries"][0].update(pinyin="wo shi"),
            lambda d: d["entries"][0]["zh_queries"][0].update(pinyin="wǒ shì zhōng guó rén"),
            lambda d: d["entries"][0]["zh_queries"][0].update(extra="unknown"),
            lambda d: d["entries"][0].update(zh_queries=[]),
            lambda d: d["entries"][1].update(text="Cómo estás?"),
            lambda d: d["entries"][1].update(text="¿Cómo estás?."),
            lambda d: d["entries"][1].update(text="?Cómo estás¿"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                data = fixture()
                mutate(data)
                with self.assertRaises(ValidationError):
                    compiler.validate_spanish_learning(data)

    def test_requires_traceable_unique_sources_ids_outputs_and_queries(self):
        mutations = [
            lambda d: d["sources"].append(deepcopy(d["sources"][0])),
            lambda d: d["sources"][0].update(id="Not-Lowercase"),
            lambda d: d["entries"][0].update(source_ids=["missing"]),
            lambda d: d["entries"][0].update(source_ids=["official", "official"]),
            lambda d: d["entries"][0]["variants"][0].update(source_ids=["missing"]),
            lambda d: d["entries"][1].update(id=d["entries"][0]["id"]),
            lambda d: d["entries"][1].update(id="es-nationality-masculine-speaker"),
            lambda d: d["entries"].append(deepcopy(d["entries"][0])),
            lambda d: d["entries"][0]["zh_queries"].append(deepcopy(d["entries"][0]["zh_queries"][0])),
            lambda d: d["entries"][0]["variants"].append(deepcopy(d["entries"][0]["variants"][0])),
            lambda d: d["sources"][0].update(url="javascript:bad"),
            lambda d: d["sources"][0].update(url="https://user:password@example.org/"),
            lambda d: d["sources"][0].update(url="https://example.org:bad/"),
            lambda d: d["sources"][0].update(url="https://[broken-ipv6/"),
            lambda d: d["sources"][0].update(url="https://example.org/bad space"),
            lambda d: d["sources"][0].update(checked_on="2026-02-31"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                data = fixture()
                mutate(data)
                with self.assertRaises(ValidationError):
                    compiler.validate_spanish_learning(data)

    def test_all_limits_are_enforced_before_rendering(self):
        for name, value in [("MAX_ENTRIES", 1), ("MAX_FORMS", 2), ("MAX_CHINESE", 2)]:
            with self.subTest(limit=name), patch.object(compiler, name, value), self.assertRaises(ValidationError):
                compiler.validate_spanish_learning(fixture())

    def test_source_bytes_are_bounded_regular_json_and_auditable(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "data.json"
            write_fixture(source)
            data, checksum = compiler.load_spanish_learning(source)
            self.assertEqual(checksum, hashlib.sha256(source.read_bytes()).hexdigest())
            source.write_bytes(source.read_bytes() + b"\n")
            data2, checksum2 = compiler.load_spanish_learning(source)
            self.assertEqual(data, data2)
            self.assertNotEqual(checksum, checksum2, "hash records exact reviewed bytes")
            link = Path(temporary) / "link.json"
            link.symlink_to(source)
            with self.assertRaises(ValidationError):
                compiler.load_spanish_learning(link)
            for raw in [b'{"version":1,"version":1}', b'{"x":NaN}', b'\xff', b'[' * 2000,
                        b" " * (compiler.MAX_SOURCE_BYTES + 1)]:
                source.write_bytes(raw)
                with self.assertRaises(ValidationError):
                    compiler.build_spanish_resources(source)
            with self.assertRaises(ValidationError):
                compiler.load_spanish_learning(Path(temporary))
            if hasattr(os, "mkfifo"):
                fifo = Path(temporary) / "fifo.json"
                os.mkfifo(fifo)
                with self.assertRaises(ValidationError):
                    compiler.load_spanish_learning(fifo)

    def test_dynamic_content_stays_inside_quoted_data(self):
        data = fixture()
        payload = '\"); os.execute("must stay inert"); -- [[ ]] 123'
        data["entries"][0]["note"] = payload
        data["entries"][0]["meaning_zh"] = payload
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "data.json"
            write_fixture(source, data)
            lua = compiler.build_spanish_resources(source)["lua/her_spanish_data.lua"].decode("utf-8")
        self.assertIn("hint = " + lua_quote(payload), lua)
        self.assertIn("meaning = " + lua_quote(payload), lua)
        self.assertNotIn("os.execute", lua)
        # Erase byte-escaped string literals and comments: only a fixed table
        # literal grammar remains, with no calls, long strings or expressions.
        syntax = re.sub(r'"(?:\\[0-9]{3})*"', '""', lua)
        syntax = re.sub(r"--[^\n]*", "", syntax)
        self.assertRegex(syntax, r'^\s*return \{')
        self.assertNotRegex(syntax, r"[()\[\].;:+*/]")
        self.assertNotIn(payload, syntax)

    def test_sort_order_is_independent_of_source_entry_order(self):
        data = fixture()
        expected = compiler.compile_data(data)
        data["entries"].reverse()
        self.assertEqual(expected, compiler.compile_data(data))

    def test_cli_check_detects_stale_output_without_overwriting_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / "data.json", root / "output"
            write_fixture(source)
            args = ["--input", str(source), "--output-dir", str(output)]
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(compiler.main(args), 0)
                self.assertEqual(compiler.main(args + ["--check"]), 0)
                generated = output / "lua/her_spanish_data.lua"
                generated.write_bytes(b"stale")
                self.assertEqual(compiler.main(args + ["--check"]), 1)
                self.assertEqual(generated.read_bytes(), b"stale")
                source.write_text('{"bad":true}', encoding="utf-8")
                self.assertEqual(compiler.main(args), 1)
                self.assertEqual(generated.read_bytes(), b"stale", "invalid source must not replace any artifact")


if __name__ == "__main__":
    unittest.main()
