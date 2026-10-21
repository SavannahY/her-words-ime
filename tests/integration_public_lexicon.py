#!/usr/bin/env python3
"""Exercise public words in real librime using disposable data, never live Rime."""
import argparse
from collections import defaultdict
import ctypes as C
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from compile_public_lexicon import load_public_lexicon
from manage_word_memory import MemoryStore
from integration_rime import enter, find_squirrel, set_mode, source_hashes
import rime_api as api


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def worker(app, user, baseline_path, baseline):
    require(user.resolve() != (Path.home() / "Library/Rime").resolve(), "Refusing live userdata")
    catalog = load_public_lexicon()
    inputs = defaultdict(set)
    for entry in catalog["entries"]:
        inputs[entry["pinyin"].replace(" ", "")].add(entry["text"])
        for alias in entry.get("aliases", []):
            inputs[alias].add(entry["text"])
    engine = api.Rime(app, app / "Contents/SharedSupport", user)
    engine.deploy()
    checks = 0

    def query(code, mode="friendly", traditional=False, select=None):
        sid = engine.session("her_words")
        try:
            set_mode(engine, sid, mode)
            if traditional:
                engine.bind("set_option", None, C.c_size_t, C.c_char_p, C.c_int)(sid, b"zh_simp", 0)
            committed, failures = enter(engine, sid, code)
            require(not failures and not committed, "Input did not remain a composition: " + code)
            candidates, truncated = engine.candidates(sid, 100_000)
            require(not truncated, "Candidate enumeration truncated: " + code)
            if select is not None:
                require(select in candidates, "Missing selection: " + select)
                index = candidates.index(select)
                success = engine.bind("select_candidate", C.c_int, C.c_size_t, C.c_size_t)(sid, index)
                require(success, "Could not select: " + select)
                selected = engine.commit(sid)
                if not selected:
                    engine.bind("commit_composition", C.c_int, C.c_size_t)(sid)
                    selected = engine.commit(sid)
                require(selected == select, "Unexpected committed text: " + repr(selected))
            return candidates
        finally:
            engine.destroy(sid)

    try:
        if baseline:
            results = {mode: {code: (query(code, mode) or [None])[0] for code in inputs}
                       for mode in ("friendly", "community", "original")}
            baseline_path.write_text(json.dumps(results, ensure_ascii=False), encoding="utf-8")
            print("Captured ordinary-first baseline without public suggestions.")
            return
        prior = json.loads(baseline_path.read_text(encoding="utf-8"))
        for mode in ("friendly", "community", "original"):
            for code, words in inputs.items():
                candidates = query(code, mode)
                require(len(candidates) == len(set(candidates)), "Duplicate candidate text: " + code)
                for word in words:
                    require(word in candidates[:len(words) + 1], "Public word is not near front: " + mode + "/" + code + "/" + word)
                    checks += 1
                first = prior[mode][code]
                if first:
                    require(candidates[0] == first, "Ordinary first changed: " + mode + "/" + code)
                    checks += 1
        store = MemoryStore(user)
        for code, word in [("tuyouyou", "屠呦呦"), ("ziqiangbuxi", "自强不息"),
                           ("bobbibrown", "芭比波朗")]:
            query(code, select=word)
            checks += 1
            store.mutate("block", text=word)
            for mode in ("friendly", "community", "original"):
                require(all(word not in text for text in query(code, mode)), "Blocked public word leaked: " + code)
                checks += 1
            store.mutate("unblock", text=word)
            require(word in query(code), "Public word did not restore: " + code)
            checks += 1
        for code, simplified, traditional_word in [("yashilandai", "雅诗兰黛", "雅詩蘭黛"),
                                                    ("esteelauder", "雅诗兰黛", "雅詩蘭黛"),
                                                    ("mayiya", "玛伊娅", "瑪伊婭"),
                                                    ("maiaactive", "玛伊娅", "瑪伊婭")]:
            for mode in ("friendly", "community", "original"):
                traditional = query(code, mode, traditional=True)
                require(traditional_word in traditional[:2] and simplified not in traditional,
                        "Public word bypassed traditional conversion: " + code + "/" + mode)
                checks += 1
        store.mutate("block", text="雅诗兰黛")
        require("雅詩蘭黛" not in query("esteelauder", traditional=True), "Simplified block leaked through traditional alias")
        checks += 1
        store.mutate("unblock", text="雅诗兰黛")
        store.mutate("block", text="雅詩蘭黛")
        require("雅詩蘭黛" not in query("esteelauder", traditional=True), "Traditional block leaked through public alias")
        checks += 1
        print("Public real-Rime lexicon: {} checks passed ({} readings, {} input codes).".format(
            checks, len(catalog["entries"]), len(inputs)), flush=True)
    finally:
        engine.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=find_squirrel())
    parser.add_argument("--worker", choices=["baseline", "public"])
    parser.add_argument("--user", type=Path)
    parser.add_argument("--baseline-path", type=Path)
    args = parser.parse_args()
    if args.app is None:
        parser.error("Official Squirrel.app is required")
    if args.worker:
        worker(args.app, args.user, args.baseline_path, args.worker == "baseline")
        return
    before = source_hashes(ROOT / "rime")
    with tempfile.TemporaryDirectory(prefix="her-public-integration-") as temporary:
        temporary = Path(temporary).resolve()
        baseline_path = temporary / "baseline.json"
        for phase in ["baseline", "public"]:
            user = temporary / phase
            shutil.copytree(ROOT / "rime", user, ignore=shutil.ignore_patterns("build", ".DS_Store"))
            if phase == "baseline":
                (user / "lua/her_public_aliases.lua").write_text("return { readings = {}, aliases = {} }\n", encoding="utf-8")
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "--app", str(args.app),
                            "--worker", phase, "--user", str(user), "--baseline-path", str(baseline_path)], check=True)
    require(before == source_hashes(ROOT / "rime"), "Repository Rime configuration changed during tests")
    print("Public lexicon checks used only disposable userdata; source configuration unchanged.")


if __name__ == "__main__":
    main()
