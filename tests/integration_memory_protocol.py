#!/usr/bin/env python3
"""Exercise the real Python and Swift Mac memory stores against shared fixtures.

Runs only in fresh temporary directories. No live Rime directory, user word,
microphone, browser, or application is opened. Requires macOS/Swift unless a
prebuilt fixture driver is supplied with --binary.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("her_memory_protocol_manager", ROOT / "scripts/manage_word_memory.py")
MANAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANAGER)
EXTERNAL_BINARY = None


def normalized(state):
    """Compare semantics, not the two UIs' intentional display ordering."""
    entries = sorted((item["input"], item["text"], item["count"], item["lastUsed"], item["manual"])
                     for item in state["entries"])
    blocked = sorted(item if isinstance(item, str) else item["text"] for item in state["blocked"])
    return {"entries": entries, "blocked": blocked, "learning": state["learning"]}


def letters(number):
    result = ""
    while True:
        result = chr(97 + number % 26) + result
        number = number // 26 - 1
        if number < 0:
            return result


class MemoryProtocolIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="her-memory-protocol-build-")
        if EXTERNAL_BINARY:
            cls.binary = EXTERNAL_BINARY.resolve(strict=True)
            if not os.access(cls.binary, os.X_OK):
                raise RuntimeError("--binary must name an executable fixture driver")
            return
        if sys.platform != "darwin":
            cls.build.cleanup()
            raise unittest.SkipTest("Mac memory protocol integration requires macOS/Swift")
        cls.binary = Path(cls.build.name).resolve() / "MemoryProtocolTool"
        sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True,
                             capture_output=True, text=True, timeout=30).stdout.strip()
        command = ["swiftc", "-sdk", sdk,
                   str(ROOT / "native/Sources/HerSpeechMac/MacWordMemoryStore.swift"),
                   str(ROOT / "native/Tests/MemoryProtocolTool.swift"), "-o", str(cls.binary)]
        subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="her-memory-protocol-data-")
        self.directory = Path(self.fixture.name).resolve() / "store"
        self.store = MANAGER.MemoryStore(self.directory)

    def tearDown(self):
        self.fixture.cleanup()

    def swift(self, action="read", *arguments, ok=True, directory=None):
        result = subprocess.run([str(self.binary), str(directory or self.directory), action, *arguments],
                                cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, "Swift unexpectedly accepted malformed fixture")
        self.assertIn("error", json.loads(result.stderr))
        return result

    def assert_interoperable(self):
        python = self.store.state()
        swift = self.swift()
        self.assertEqual(normalized(swift), normalized(python))
        return python

    def learned(self, rows):
        text = MANAGER.HEADER + "\n" + "".join("L\t{}\t{}\t{}\t{}\n".format(*row) for row in rows)
        self.store.learned_path.write_text(text, encoding="utf-8")

    def test_python_and_swift_update_each_others_manual_words_and_settings(self):
        self.assert_interoperable()
        self.store.mutate("remember", text="张小芳", input="zhang'xiao fang")
        self.store.mutate("remember", text="GitHub", input="gh")
        self.store.mutate("learning", enabled=False)
        self.assert_interoperable()
        self.swift("remember", "API", "a' p i")
        self.swift("learning", "1")
        state = self.assert_interoperable()
        self.assertTrue(state["learning"])
        self.assertEqual({item["input"] for item in state["entries"]}, {"zhangxiaofang", "gh", "api"})
        self.swift("remember", "GITHUB", "git")
        state = self.assert_interoperable()
        github = [item for item in state["entries"] if MANAGER.fold(item["text"]) == "github"]
        self.assertEqual([(item["input"], item["text"]) for item in github], [("git", "GITHUB")])
        self.store.mutate("remember", text="GitHub", input="github")
        self.assert_interoperable()
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.policy_path.stat().st_mode & 0o777, 0o600)

    def test_forget_tombstone_survives_explicit_readdition_under_new_code(self):
        old = int(time.time()) - 60
        self.learned([("zhangxiaofang", "张小芳", 9, old), ("api", "API", 3, old)])
        self.store.mutate("forget", text="张小芳")
        state = self.assert_interoperable()
        self.assertEqual([item["text"] for item in state["entries"]], ["API"])
        self.swift("remember", "张小芳", "zxf")
        state = self.assert_interoperable()
        matches = [item for item in state["entries"] if item["text"] == "张小芳"]
        self.assertEqual([(item["input"], item["count"], item["manual"]) for item in matches], [("zxf", 1, True)])
        self.assertIn("张小芳", MANAGER.read_policy(self.store.policy_path)["forgotten"])
        self.swift("forget", "张小芳")
        state = self.assert_interoperable()
        self.assertFalse(any(item["text"] == "张小芳" for item in state["entries"]))
        self.assertEqual(state["blocked"], [])

    def test_block_and_restore_do_not_restore_old_compound_memories(self):
        old = int(time.time()) - 60
        self.learned([("zxf", "张小芳", 4, old), ("zxfhao", "张小芳好", 3, old),
                      ("annsmith", "Ann-Smith", 3, old), ("planning", "planning", 2, old)])
        self.store.mutate("remember", text="张小芳老师", input="zxflaoshi")
        self.store.mutate("block", text="张小芳")
        self.assert_interoperable()
        self.swift("unblock", "张小芳")
        state = self.assert_interoperable()
        self.assertFalse(any("张小芳" in item["text"] for item in state["entries"]))
        self.swift("block", "ANN")
        self.assert_interoperable()
        self.store.mutate("unblock", text="ann")
        state = self.assert_interoperable()
        self.assertFalse(any(item["text"] == "Ann-Smith" for item in state["entries"]))
        self.assertTrue(any(item["text"] == "planning" for item in state["entries"]))

    def test_clear_preserves_blocks_and_allows_new_manual_word(self):
        self.learned([("old", "OldName", 4, int(time.time()) - 60)])
        self.store.mutate("remember", text="GitHub", input="gh")
        self.swift("block", "Alex")
        self.store.mutate("clear")
        state = self.assert_interoperable()
        self.assertEqual(state["entries"], [])
        self.assertEqual([item["text"] for item in state["blocked"]], ["Alex"])
        self.swift("remember", "NewName", "nn")
        self.assertEqual([item["text"] for item in self.assert_interoperable()["entries"]], ["NewName"])
        self.swift("clear")
        state = self.assert_interoperable()
        self.assertEqual(state["entries"], [])
        self.assertEqual([item["text"] for item in state["blocked"]], ["Alex"])

    def test_future_learned_timestamps_are_forgotten_and_cleared(self):
        future = int(time.time()) + 3_600
        self.learned([("name", "FutureName", 5, future)])
        self.swift("forget", "FutureName")
        self.assertEqual(self.assert_interoperable()["entries"], [])
        policy = MANAGER.read_policy(self.store.policy_path)
        self.assertGreaterEqual(policy["forgotten"]["futurename"]["lastUsed"], future)
        self.swift("remember", "FutureName", "fn")
        matches = [item for item in self.assert_interoperable()["entries"] if item["text"] == "FutureName"]
        self.assertEqual([(item["input"], item["manual"]) for item in matches], [("fn", True)])
        self.store.mutate("forget", text="FutureName")
        self.assertEqual(self.assert_interoperable()["entries"], [])
        self.learned([("first", "FirstFuture", 4, future), ("later", "LaterFuture", 4, future + 100)])
        self.swift("clear")
        self.assertEqual(self.assert_interoperable()["entries"], [])
        self.assertGreaterEqual(MANAGER.read_policy(self.store.policy_path)["clear_before"], future + 100)
        self.store.mutate("clear")
        self.assertEqual(self.assert_interoperable()["entries"], [])

    def test_forget_cutoff_does_not_move_backwards_after_learned_file_is_pruned(self):
        future = int(time.time()) + 3_600
        self.learned([("name", "FutureName", 5, future)])
        self.store.mutate("forget", text="FutureName")
        self.learned([])  # Rime may prune these rows before the next manager opens.
        self.swift("forget", "FutureName")
        policy = MANAGER.read_policy(self.store.policy_path)
        self.assertGreaterEqual(policy["forgotten"]["futurename"]["lastUsed"], future)
        self.learned([("name", "FutureName", 5, future)])
        self.assertEqual(self.assert_interoperable()["entries"], [])

    def test_ascii_case_and_symbol_boundaries_match_python(self):
        for term in ["Ann", "C++", "张小芳"]:
            self.store.mutate("block", text=term)
        samples = {
            "ANN": True, "Ann's": True, "给Ann发信": True, "planning": False,
            "annual": False, "Annabelle": False, "Ann1": False,
            "C++": True, "Use C++!": True, "C++的": True, "ABC++def": False, "C++17": False,
            "给张小芳留言": True, "张晓芳": False,
        }
        self.assert_interoperable()
        for text, expected in samples.items():
            with self.subTest(text=text):
                self.assertEqual(MANAGER.blocked(text, ["Ann", "C++", "张小芳"]), expected)
                self.assertEqual(self.swift("is-blocked", text)["blocked"], expected)

    def test_unicode_scalar_and_utf8_limits_are_interoperable(self):
        valid = ["名" * 32, "e\u0301" * 16, "🙂" * 32, "Node.js", "C++"]
        for index, text in enumerate(valid):
            if index % 2:
                self.swift("remember", text, "key" + letters(index))
            else:
                self.store.mutate("remember", text=text, input="key" + letters(index))
            self.assert_interoperable()
        for text in ["名" * 33, "e\u0301" * 17, "🙂" * 33, "two words", "bad\nword", "name@example"]:
            with self.subTest(text=repr(text)):
                with self.assertRaises((ValueError, UnicodeError)):
                    self.store.mutate("remember", text=text, input="invalid")
                self.swift("remember", text, "invalid", ok=False)

    def assert_damaged_files_preserved(self, policy_bytes, learned_bytes=None):
        self.store.policy_path.write_bytes(policy_bytes)
        if learned_bytes is None:
            self.store.learned_path.unlink(missing_ok=True)
        else:
            self.store.learned_path.write_bytes(learned_bytes)
        with self.assertRaises((ValueError, UnicodeError, OSError)):
            self.store.state()
        self.swift(ok=False)
        with self.assertRaises((ValueError, UnicodeError, OSError)):
            self.store.mutate("learning", enabled=False)
        self.swift("learning", "0", ok=False)
        self.assertEqual(self.store.policy_path.read_bytes(), policy_bytes)
        if learned_bytes is not None:
            self.assertEqual(self.store.learned_path.read_bytes(), learned_bytes)

    def test_bad_policy_is_rejected_without_overwrite_by_either_writer(self):
        header = MANAGER.HEADER + "\n"
        malformed = [
            b"damaged\n", b"\xff\n", (header + "S\tlearning\t2\n").encode(),
            (header + "S\tlearning\t1\nS\tlearning\t0\n").encode(),
            (header + "M\tg h\tGitHub\t1\n").encode(),
            (header + "M\tgh\t GitHub\t1\n").encode(),
            (header + "M\tgh\tGitHub\t-1\n").encode(),
            (header + "M\tgh\tGitHub\t1\nM\tgh\tGITHUB\t2\n").encode(),
            (header + "B\tAnn\t1\nB\tANN\t2\n").encode(),
            (header + "F\tName\t+2\n").encode(),
            (header + "X\tunknown\t1\n").encode(),
            (header + "M\tname\t" + "e\u0301" * 17 + "\t1\n").encode(),
            b"X" * 2_000_001,
        ]
        for index, payload in enumerate(malformed):
            with self.subTest(case=index):
                self.assert_damaged_files_preserved(payload)

    def test_bad_learned_file_prevents_either_writer_overwriting_policy(self):
        self.store.mutate("remember", text="SavedName", input="saved")
        policy = self.store.policy_path.read_bytes()
        header = MANAGER.HEADER + "\n"
        malformed = [
            b"damaged\n", (header + "L\tname\tName\t0\t1\n").encode(),
            (header + "L\tname\tName\t1000001\t1\n").encode(),
            (header + "L\tname\tName\t1\t-1\n").encode(),
            (header + "L\tNa me\tName\t1\t1\n").encode(),
            (header + "L\tname\tName\t1\t1\nL\tname\tNAME\t2\t2\n").encode(),
        ]
        for index, payload in enumerate(malformed):
            with self.subTest(case=index):
                self.assert_damaged_files_preserved(policy, payload)

    def test_per_kind_capacity_bounds_are_shared(self):
        header = MANAGER.HEADER + "\n"
        for kind in ["M", "B", "F", "L"]:
            rows = []
            for index in range(2_001):
                code = "key" + letters(index)
                text = "Word" + str(index)
                if kind == "M": rows.append(f"M\t{code}\t{text}\t1\n")
                elif kind == "L": rows.append(f"L\t{code}\t{text}\t1\t1\n")
                else: rows.append(f"{kind}\t{text}\t1\n")
            payload = (header + "".join(rows)).encode()
            with self.subTest(kind=kind):
                if kind == "L": self.assert_damaged_files_preserved(header.encode(), payload)
                else: self.assert_damaged_files_preserved(payload)

    def test_concurrent_python_and_swift_managers_do_not_lose_additions(self):
        def add(index):
            text, code = "Person" + str(index), "person" + letters(index)
            if index % 2:
                self.swift("remember", text, code)
            else:
                self.store.mutate("remember", text=text, input=code)
        with ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(add, range(16)))
        state = self.assert_interoperable()
        self.assertEqual({item["text"] for item in state["entries"]}, {"Person" + str(index) for index in range(16)})


def main():
    global EXTERNAL_BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="prebuilt native/Tests/MemoryProtocolTool.swift driver")
    parser.add_argument("--quiet", action="store_true")
    arguments = parser.parse_args()
    EXTERNAL_BINARY = arguments.binary
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(MemoryProtocolIntegration)
    result = unittest.TextTestRunner(verbosity=1 if arguments.quiet else 2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
