"""Validate bounded, inert ASR context profiles with the standard library."""

import copy
import json
from pathlib import Path
import tempfile
import unicodedata
import unittest
from unittest import mock


PROFILE_PATH = Path(__file__).resolve().parents[1] / "speech/profiles.json"
PROFILE_IDS = {"neutral", "contextual", "hotword"}
MAX_HINTS = 64
MAX_HINT_CHARACTERS = 64


def _keys(value, expected, where):
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(where + ": unexpected or missing fields")


def _text(value, where, maximum=MAX_HINT_CHARACTERS):
    if (not isinstance(value, str) or not value or value != value.strip()
            or len(value) > maximum
            or any(unicodedata.category(char).startswith("C") for char in value)):
        raise ValueError(where + ": expected bounded nonblank Unicode text without control characters")


def validate_profiles(data):
    """Check only data; never evaluate a hint as code, regex, path or command."""
    _keys(data, {"version", "default_profile", "profiles"}, "profiles document")
    if type(data["version"]) is not int or data["version"] != 1:
        raise ValueError("version must be integer 1")
    _keys(data["profiles"], PROFILE_IDS, "profile identifiers")
    if not isinstance(data["default_profile"], str) or data["default_profile"] not in PROFILE_IDS:
        raise ValueError("default_profile must name a declared profile")
    for identifier, profile in data["profiles"].items():
        _keys(profile, {"label", "contextual_strings", "hotwords"}, identifier)
        _text(profile["label"], identifier + ".label", maximum=32)
        hints = []
        for field in ("contextual_strings", "hotwords"):
            values = profile[field]
            if not isinstance(values, list) or len(values) > MAX_HINTS:
                raise ValueError(identifier + "." + field + ": too many hints or wrong type")
            for value in values:
                _text(value, identifier + "." + field)
            hints.extend(values)
        if len(hints) > MAX_HINTS:
            raise ValueError(identifier + ": combined context exceeds hint budget")
        if len({value.casefold() for value in hints}) != len(hints):
            raise ValueError(identifier + ": duplicate hints")
    return data


def load_profiles(path=PROFILE_PATH):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError("invalid JSON numeric constant: " + value)

    return validate_profiles(json.loads(
        Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique,
        parse_constant=invalid_constant))


class SpeechProfilesTests(unittest.TestCase):
    def setUp(self):
        self.data = load_profiles()

    def test_production_profiles_are_bounded_and_declared(self):
        self.assertEqual(self.data["default_profile"], "contextual")
        self.assertEqual(set(self.data["profiles"]), PROFILE_IDS)
        self.assertEqual(self.data["profiles"]["neutral"]["contextual_strings"], [])
        for profile in self.data["profiles"].values():
            self.assertLessEqual(len(profile["contextual_strings"]) + len(profile["hotwords"]), MAX_HINTS)

    def test_chinese_and_technical_hints_are_data(self):
        contextual = self.data["profiles"]["contextual"]
        self.assertTrue({"她", "她们", "女性互助"} <= set(contextual["contextual_strings"]))
        expected = {"GitHub", "API", "SwiftUI", "iPhone", "Mac", "Xcode"}
        self.assertTrue(expected <= set(contextual["hotwords"]))
        self.assertTrue(expected <= set(self.data["profiles"]["hotword"]["hotwords"]))

    def test_wrong_shapes_and_unknown_fields_rejected(self):
        mutations = [
            lambda value: value.update(version=True),
            lambda value: value.update(version=2),
            lambda value: value.update(default_profile="missing"),
            lambda value: value.update(script="eval(...)"),
            lambda value: value["profiles"].update(unknown={}),
            lambda value: value["profiles"]["neutral"].update(executable=True),
            lambda value: value["profiles"]["neutral"].update(hotwords="not a list"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                data = copy.deepcopy(self.data)
                mutate(data)
                with self.assertRaises(ValueError):
                    validate_profiles(data)

    def test_empty_control_or_oversized_hints_rejected(self):
        for value in ["", " ", " API", "API ", "API\n", "a\0b", "\ud800", "a\u200bb",
                      "x" * (MAX_HINT_CHARACTERS + 1), None, 7, {"text": "API"}]:
            with self.subTest(value=repr(value)):
                data = copy.deepcopy(self.data)
                data["profiles"]["neutral"]["hotwords"] = [value]
                with self.assertRaises(ValueError):
                    validate_profiles(data)

    def test_casefold_duplicates_and_cross_list_duplicates_rejected(self):
        for context, hotwords in [([], ["GitHub", "github"]), (["她"], ["她"])]:
            data = copy.deepcopy(self.data)
            data["profiles"]["neutral"].update(contextual_strings=context, hotwords=hotwords)
            with self.assertRaisesRegex(ValueError, "duplicate"):
                validate_profiles(data)

    def test_individual_and_combined_hint_budgets(self):
        data = copy.deepcopy(self.data)
        data["profiles"]["neutral"]["hotwords"] = ["word" + str(index) for index in range(65)]
        with self.assertRaises(ValueError):
            validate_profiles(data)
        data["profiles"]["neutral"].update(
            contextual_strings=["context" + str(index) for index in range(33)],
            hotwords=["word" + str(index) for index in range(32)])
        with self.assertRaisesRegex(ValueError, "combined"):
            validate_profiles(data)

    def test_code_shaped_string_is_never_executed(self):
        data = copy.deepcopy(self.data)
        data["profiles"]["neutral"]["hotwords"] = ["__import__('os').system('never run')"]
        with mock.patch("builtins.eval", side_effect=AssertionError("eval must not run")) as evaluate, \
                mock.patch("os.system", side_effect=AssertionError("shell must not run")) as execute:
            self.assertIs(validate_profiles(data), data)
            evaluate.assert_not_called()
            execute.assert_not_called()

    def test_duplicate_json_keys_and_nan_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profiles.json"
            for source in ['{"version":1,"version":1}', '{"version":NaN}']:
                path.write_text(source, encoding="utf-8")
                with self.assertRaises(ValueError):
                    load_profiles(path)


if __name__ == "__main__":
    unittest.main()
