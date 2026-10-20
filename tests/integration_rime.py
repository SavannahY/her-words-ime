#!/usr/bin/env python3
"""Run real Squirrel/librime integration tests in disposable userdata.

Requires Python 3 and the official macOS Squirrel bundle, including its Lua plugin
and bundled dictionaries. Default app lookup checks the user's and system's
Input Methods directories. Default config is this repository's rime directory.
No real Rime userdata is opened or modified. Reports and engine logs default to
an isolated system temporary directory, and --report sets a report destination.

The checked-in integration-cases.json contains the 150-case acceptance matrix.
--casesJSON can select an alternate list or an object containing cases,
additionalCases and forbidden. forbidden entries are substrings or {text, match}
objects; match=exact is applied only to a whole candidate. --print-cases works
without Squirrel. --include-candidates retains full candidate lists in reports.
"""

import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
import rime_api as api
Rime = api.Rime
FLAGS = ("her_original", "her_friendly", "her_community")
BASELINE_CACHE = {}
MODES = {
    "original": (True, False, False),
    "friendly": (False, True, False),
    "community": (False, False, True),
}
DEFAULT_FLAGS = dict(zip(FLAGS, MODES["friendly"]))
FORBIDDEN = ["他", "奸诈", "姦詐", "贪婪", "貪婪",
             {"text": "妇人之仁", "match": "exact"},
             {"text": "婦人之仁", "match": "exact"},
             {"text": "剩女", "match": "exact"},
             {"text": "嫉妒", "match": "exact"},
             {"text": "妒忌", "match": "exact"}]


def alternatives(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


def load_cases(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data, FORBIDDEN
    if isinstance(data, dict):
        return data.get("cases", []) + data.get("additionalCases", []), data.get("forbidden", FORBIDDEN)
    raise ValueError("--casesJSON must contain a list or object")


def source_hashes(config):
    return {str(path.relative_to(config)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(config.rglob("*")) if path.is_file()}


def find_squirrel():
    candidates = [Path.home() / "Library/Input Methods/Squirrel.app",
                  Path("/Library/Input Methods/Squirrel.app")]
    return next((path for path in candidates if path.is_dir()), None)


def get_flags(engine, sid):
    getter = engine.bind("get_option", C.c_int, C.c_size_t, C.c_char_p)
    return {flag: bool(getter(sid, flag.encode())) for flag in FLAGS}


def set_mode(engine, sid, mode):
    if mode == "default":
        return
    setter = engine.bind("set_option", None, C.c_size_t, C.c_char_p, C.c_int)
    for name, enabled in zip(FLAGS, MODES[mode]):
        setter(sid, name.encode(), enabled)


def enumerate_candidates(engine, sid, limit):
    iterator = api.CandidateIterator()
    result = []
    begin = engine.bind("candidate_list_begin", C.c_int, C.c_size_t, C.POINTER(api.CandidateIterator))
    advance = engine.bind("candidate_list_next", C.c_int, C.POINTER(api.CandidateIterator))
    end = engine.bind("candidate_list_end", None, C.POINTER(api.CandidateIterator))
    if not begin(sid, C.byref(iterator)):
        return result, False
    try:
        while advance(C.byref(iterator)):
            if len(result) == limit:
                return result, True
            result.append({"text": api.decode(iterator.candidate.text),
                           "comment": api.decode(iterator.candidate.comment)})
    finally:
        end(C.byref(iterator))
    return result, False


def enter(engine, sid, key_input):
    committed, failures = "", []
    for key in key_input:
        if not engine.key(sid, key):
            failures.append("unhandled key " + repr(key))
        committed += engine.commit(sid)
    return committed, failures


def select_first(engine, sid):
    failures = []
    if not engine.key(sid, " "):
        failures.append("Space was not handled")
    committed = engine.commit(sid)
    if engine.context(sid)["preedit"]:
        engine.bind("commit_composition", C.c_int, C.c_size_t)(sid)
        committed += engine.commit(sid)
    if not committed:
        failures.append("no committed text")
    return committed, failures


def banned_hits(candidates, forbidden):
    hits = []
    for candidate in candidates:
        for rule in forbidden:
            text = rule if isinstance(rule, str) else rule["text"]
            exact = isinstance(rule, dict) and rule.get("match") == "exact"
            if (candidate["text"] == text if exact else text in candidate["text"]):
                hit = {"candidate": candidate["text"], "forbidden": text,
                       "match": "exact" if exact else "phrase"}
                if hit not in hits:
                    hits.append(hit)
    return hits


def original_baseline(engine, schema, key_input):
    if key_input not in BASELINE_CACHE:
        sid = engine.session(schema)
        try:
            set_mode(engine, sid, "original")
            prefix, failures = enter(engine, sid, key_input)
            page = engine.context(sid)["pageCandidates"]
            BASELINE_CACHE[key_input] = {"firstCandidate": page[0] if page else None,
                                         "alreadyCommitted": prefix, "inputFailures": failures}
        finally:
            engine.destroy(sid)
    return BASELINE_CACHE[key_input]


def run_case(engine, args, case, mode, global_forbidden):
    sid = engine.session(args.schema)
    failures = []
    result = {"id": case["id"], "mode": mode, "input": case["input"]}
    try:
        baseline = None
        if case.get("preserveUnrewrittenBaseline"):
            baseline = original_baseline(engine, args.schema, case["input"])
            result["originalBaseline"] = baseline
        set_mode(engine, sid, mode)
        for option, enabled in case.get("options", {}).items():
            engine.bind("set_option", None, C.c_size_t, C.c_char_p, C.c_int)(sid, option.encode(), enabled)
        result["options"] = case.get("options", {})
        expected_flags = DEFAULT_FLAGS if mode == "default" else dict(zip(FLAGS, MODES[mode]))
        result["flags"] = get_flags(engine, sid)
        if result["flags"] != expected_flags:
            failures.append("mode flags differ: expected " + repr(expected_flags))
        committed, input_failures = enter(engine, sid, case["input"])
        failures.extend(input_failures)
        result["context"] = engine.context(sid)
        candidates, truncated = enumerate_candidates(engine, sid, args.candidate_limit)
        texts = [candidate["text"] for candidate in candidates]
        result.update(candidateCount=len(candidates), candidatesTruncated=truncated,
                      candidates=candidates, firstCandidate=texts[0] if texts else None)
        if not candidates:
            failures.append("no candidates")
        if truncated:
            failures.append("candidate enumeration truncated; increase --candidate-limit")
        duplicate_texts = {text: count for text, count in Counter(texts).items() if count > 1}
        result["duplicateCandidateTexts"] = duplicate_texts
        if duplicate_texts:
            failures.append("duplicate candidate text(s): " + repr(duplicate_texts))
        expected_first = alternatives(case.get("expectedFirst"))
        if expected_first and result["firstCandidate"] not in expected_first:
            failures.append("first candidate not among " + repr(expected_first))
        expected_any = alternatives(case.get("expectedAny"))
        if expected_any:
            found = [text for text in expected_any if text in texts]
            if not found or (case.get("requireAllExpected") and len(found) != len(expected_any)):
                failures.append("expected original/protected candidate missing: " + repr(expected_any))
        annotation_expected = case.get("annotationOnExpected")
        already_normal = bool(baseline and baseline["firstCandidate"] in expected_any
                              and result["firstCandidate"] == baseline["firstCandidate"])
        result["friendlyAlternativeAlreadyNormalFirst"] = already_normal
        if annotation_expected and not already_normal and not any(candidate["text"] in expected_any and
                                                                  annotation_expected in candidate["comment"]
                                                                  for candidate in candidates):
            failures.append("friendly alternative has no annotation " + repr(annotation_expected))
        annotation = case.get("annotation")
        if annotation and candidates and annotation not in candidates[0]["comment"]:
            failures.append("first candidate comment lacks " + repr(annotation))
        # Original mode disables rewrites while retaining the independent 她 preference.
        forbidden = (["他"] if mode == "original" else global_forbidden) + case.get("forbidden", [])
        if baseline and baseline["firstCandidate"]:
            baseline_matches_rule = bool(banned_hits([{"text": baseline["firstCandidate"]}], global_forbidden))
            result["baselineMatchesRewriteRule"] = baseline_matches_rule
            if not baseline_matches_rule and result["firstCandidate"] != baseline["firstCandidate"]:
                failures.append("ordinary homophone first candidate changed from original baseline " + repr(baseline["firstCandidate"]))
            elif baseline_matches_rule and expected_any and result["firstCandidate"] not in expected_any:
                failures.append("rewritten original first candidate was displaced")
        hits = banned_hits(candidates, forbidden)
        result["forbiddenCandidateHits"] = hits
        if hits:
            failures.append("banned original text leaked through candidates")
        selected, selection_failures = select_first(engine, sid)
        failures.extend(selection_failures)
        committed += selected
        result["committed"] = committed
        if banned_hits([{"text": committed}], forbidden):
            failures.append("banned original text leaked through commit")
        if expected_first and committed not in expected_first:
            failures.append("committed text not among " + repr(expected_first))
        preferred = alternatives(case.get("preferredObservation"))
        if preferred:
            result["preferredSentenceObserved"] = bool(set(preferred) & set(texts))
        result.update(passed=not failures, failures=failures)
        return result
    finally:
        engine.destroy(sid)


def segmented_case(engine, args, mode):
    sid = engine.session(args.schema)
    failures, chunks, combined = [], [], ""
    try:
        set_mode(engine, sid, mode)
        for key_input, expected in [("ta", "她"), ("jianzha", "狡诈" if mode == "friendly" else "仠诈")]:
            prefix, input_failures = enter(engine, sid, key_input)
            failures.extend(input_failures)
            candidates, truncated = enumerate_candidates(engine, sid, args.candidate_limit)
            if truncated:
                failures.append("segmented enumeration truncated")
            if not candidates or candidates[0]["text"] != expected:
                failures.append("segmented first candidate mismatch for " + key_input)
            if banned_hits(candidates, FORBIDDEN):
                failures.append("segmented candidate contains banned text")
            committed, selection_failures = select_first(engine, sid)
            failures.extend(selection_failures)
            combined += prefix + committed
            chunks.append({"input": key_input, "first": candidates[0] if candidates else None,
                           "candidateCount": len(candidates), "committed": committed})
        expected_final = "她狡诈" if mode == "friendly" else "她仠诈"
        if combined != expected_final:
            failures.append("segmented commit differs from " + expected_final)
        return {"id": "confirmed_segments", "mode": mode, "chunks": chunks,
                "committed": combined, "passed": not failures, "failures": failures}
    finally:
        engine.destroy(sid)


def worker(args):
    cases, forbidden = load_cases(args.casesJSON)
    report = {"phase": args.worker, "cases": []}
    engine = None
    started = time.monotonic()
    try:
        engine = Rime(args.app, args.shared_data or args.app / "Contents/SharedSupport", args.user_data)
        report["librimeVersion"] = engine.version()
        engine.deploy()
        if args.worker == "cases":
            for case in cases:
                for mode in case.get("modes", ["friendly"]):
                    report["cases"].append(run_case(engine, args, case, mode, forbidden))
            report["cases"].extend(segmented_case(engine, args, mode) for mode in ("friendly", "community"))
            sid = engine.session(args.schema)
            set_mode(engine, sid, "community")
            report["preRestartFlags"] = get_flags(engine, sid)
            engine.destroy(sid)
        else:
            report["cases"].append(run_case(engine, args, {
                "id": "restart_defaults_friendly", "input": "jianzha",
                "expectedFirst": ["狡诈", "狡詐"], "annotation": "友好表达"}, "default", forbidden))
        report["passed"] = all(case["passed"] for case in report["cases"])
    except Exception as error:
        report.update(passed=False, error=type(error).__name__ + ": " + str(error))
    finally:
        if engine:
            engine.close()
        report["elapsedSeconds"] = round(time.monotonic() - started, 3)
        if not args.include_candidates:
            for case in report["cases"]:
                case.pop("candidates", None)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return 0 if report["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=find_squirrel(), help="installed or extracted official Squirrel.app bundle")
    parser.add_argument("--shared-data", type=Path)
    parser.add_argument("--config", type=Path, default=REPO / "rime")
    parser.add_argument("--schema", default="her_words")
    parser.add_argument("--candidate-limit", type=int, default=100000)
    parser.add_argument("--casesJSON", type=Path, default=HERE / "integration-cases.json")
    parser.add_argument("--print-cases", action="store_true")
    parser.add_argument("--report", type=Path, help="JSON report destination; defaults to a system temporary directory")
    parser.add_argument("--include-candidates", action="store_true", help="include all enumerated candidates in the JSON report")
    parser.add_argument("--worker", choices=("cases", "restart"), help=argparse.SUPPRESS)
    parser.add_argument("--user-data", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.print_cases:
        cases, forbidden = load_cases(args.casesJSON)
        print(json.dumps({"cases": cases, "forbidden": forbidden}, ensure_ascii=False, indent=2))
        return 0
    if args.app is None:
        parser.error("Squirrel.app was not found; supply --app /path/to/Squirrel.app")
    args.app = args.app.expanduser().resolve()
    args.config = args.config.expanduser().resolve()
    args.casesJSON = args.casesJSON.expanduser().resolve()
    if not (args.app / "Contents/Frameworks/librime.1.dylib").is_file():
        parser.error("--app must contain Squirrel's librime.1.dylib")
    if args.user_data and args.user_data.resolve() == (Path.home() / "Library/Rime").resolve():
        parser.error("real Rime userdata must never be used for integration tests")
    work = None
    if not args.worker:
        work = Path(tempfile.mkdtemp(prefix="her-words-integration-"))
    if args.report is None:
        if args.worker:
            parser.error("internal worker requires --report")
        args.report = work / "integration-results.json"
    args.report = args.report.expanduser().resolve()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    if args.worker:
        return worker(args)
    if not (args.config / "lua/her_rewrite_rules.lua").exists():
        parser.error("configuration is not ready: lua/her_rewrite_rules.lua missing")
    user = work / "userdata"
    user.mkdir()
    shutil.copytree(args.config, user, dirs_exist_ok=True, ignore=shutil.ignore_patterns("build", ".DS_Store"))
    report = {"app": str(args.app.resolve()), "config": str(args.config.resolve()),
              "isolatedUserData": str(user), "apiReference": api.API_REFERENCE,
              "apiWrapper": "tests/rime_api.py", "phases": [], "cases": []}
    report["configSha256"] = source_hashes(args.config)
    started = time.monotonic()
    for phase in ("cases", "restart"):
        phase_report = user / (phase + "-results.json")
        command = [sys.executable, str(Path(__file__).resolve()), "--worker", phase,
                   "--app", str(args.app.resolve()), "--user-data", str(user),
                   "--config", str(args.config.resolve()),
                   "--schema", args.schema, "--candidate-limit", str(args.candidate_limit),
                   "--report", str(phase_report)]
        if args.include_candidates:
            command.append("--include-candidates")
        if args.shared_data:
            command.extend(["--shared-data", str(args.shared_data.resolve())])
        if args.casesJSON:
            command.extend(["--casesJSON", str(args.casesJSON.resolve())])
        completed = subprocess.run(command, text=True, capture_output=True)
        if phase_report.exists():
            part = json.loads(phase_report.read_text())
        else:
            part = {"phase": phase, "passed": False, "error": "worker produced no report"}
        part.update(returnCode=completed.returncode, stdout=completed.stdout, stderr=completed.stderr)
        report["phases"].append({key: value for key, value in part.items() if key != "cases"})
        report["cases"].extend(part.get("cases", []))
    report["configUnchangedAfterRun"] = report["configSha256"] == source_hashes(args.config)
    report["passed"] = all(phase["passed"] for phase in report["phases"]) and report["configUnchangedAfterRun"]
    report["caseCount"] = len(report["cases"])
    report["directCaseCandidateCount"] = sum(case.get("candidateCount", 0) for case in report["cases"])
    report["segmentedCandidateCount"] = sum(chunk.get("candidateCount", 0)
                                            for case in report["cases"] for chunk in case.get("chunks", []))
    report["totalEnumeratedCandidates"] = report["directCaseCandidateCount"] + report["segmentedCandidateCount"]
    report["truncatedCases"] = sum(case.get("candidatesTruncated", False) for case in report["cases"])
    if not args.include_candidates:
        for case in report["cases"]:
            case.pop("candidates", None)
    report["elapsedSeconds"] = round(time.monotonic() - started, 3)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for case in report["cases"]:
        print("PASS" if case["passed"] else "FAIL", case["mode"], case["id"], "->", case.get("committed", ""))
        for failure in case["failures"]:
            print(" ", failure)
    for phase in report["phases"]:
        if "error" in phase:
            print("ERROR", phase["phase"], phase["error"])
    print("report:", args.report.resolve())
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
