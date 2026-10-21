"""Native product boundaries, resources and pinned dependencies; no model download."""

import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import unittest
from unittest import mock
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ios/HerWords.xcodeproj/project.pbxproj"
sys.path.insert(0, str(ROOT / "scripts"))
import generate_ios_project  # noqa: E402


def project_graph():
    """Read the real OpenStep artifact on macOS; inspect generator objects on CI.

    The non-macOS route captures the object graph before serialization instead
    of matching Swift/Python source substrings or reimplementing the generator.
    Project freshness is independently checked by generate_ios_project --check.
    """
    plutil = shutil.which("plutil")
    if platform.system() == "Darwin" and plutil:
        result = subprocess.run(
            [plutil, "-convert", "json", "-o", "-", str(PROJECT)],
            check=True, capture_output=True, text=True)
        return json.loads(result.stdout)
    with mock.patch.object(generate_ios_project, "serialize", side_effect=json.dumps):
        generated = generate_ios_project.build_project()
    return json.loads(generated.partition("\n")[2])


class NativeProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = project_graph()
        cls.objects = cls.project["objects"]
        targets = [value for value in cls.objects.values() if value.get("isa") == "PBXNativeTarget"]
        cls.app = next(value for value in targets
                       if value["productType"] == "com.apple.product-type.application")
        cls.keyboard = next(value for value in targets
                            if value["productType"] == "com.apple.product-type.app-extension")

    def phase_files(self, target, kind):
        result = []
        for identifier in target["buildPhases"]:
            phase = self.objects[identifier]
            if phase["isa"] == kind:
                result.extend(self.objects[file_id] for file_id in phase["files"])
        return result

    def resource_paths(self, target):
        return {self.objects[item["fileRef"]]["path"]
                for item in self.phase_files(target, "PBXResourcesBuildPhase")}

    def linked_products(self, target):
        return {self.objects[item["productRef"]]["productName"]
                for item in self.phase_files(target, "PBXFrameworksBuildPhase")
                if "productRef" in item}

    def test_only_host_app_links_bilingual_asr(self):
        self.assertEqual(self.linked_products(self.app), {"HerBilingualASR"})
        self.assertEqual(
            {self.objects[identifier]["productName"]
             for identifier in self.app.get("packageProductDependencies", [])},
            {"HerBilingualASR"})
        self.assertEqual(self.linked_products(self.keyboard), set())
        self.assertEqual(self.keyboard.get("packageProductDependencies", []), [])
        # The app embeds/depends on the keyboard, never the reverse.
        self.assertEqual(self.keyboard.get("dependencies", []), [])
        for identifier in self.app.get("packageProductDependencies", []):
            package = self.objects[self.objects[identifier]["package"]]
            self.assertEqual(package["isa"], "XCLocalSwiftPackageReference")
            self.assertEqual((ROOT / "ios" / package["relativePath"]).resolve(), ROOT)

    def test_host_resources_include_profiles_rules_and_asr_licenses(self):
        app_resources = self.resource_paths(self.app)
        required = {
            "../speech/profiles.json",
            "Keyboard/Resources/rules.json",
            "App/Resources/Sherpa-LICENSE.txt",
            "App/Resources/ONNXRuntime-LICENSE.txt",
            "App/Resources/ONNXRuntime-ThirdPartyNotices.txt",
            "App/Resources/Speech-Notice.txt",
        }
        self.assertTrue(required <= app_resources, required - app_resources)
        for relative in required:
            path = (ROOT / "ios" / relative).resolve()
            self.assertTrue(path.is_file(), str(path))
            self.assertGreater(path.stat().st_size, 0)
        self.assertNotIn("Keyboard/Resources/lexicon.json", app_resources,
                         "Voice host should not bundle the large keyboard dictionary")
        profiles = [relative for relative in app_resources if Path(relative).name == "profiles.json"]
        self.assertEqual(len(profiles), 1)
        self.assertEqual((ROOT / "ios" / profiles[0]).resolve(), ROOT / "speech/profiles.json")

    def test_keyboard_resources_and_sources_keep_asr_out(self):
        resources = self.resource_paths(self.keyboard)
        self.assertTrue({"Keyboard/Resources/lexicon.json", "Keyboard/Resources/rules.json"} <= resources)
        self.assertTrue(resources.isdisjoint({
            "../speech/profiles.json", "App/Resources/Sherpa-LICENSE.txt",
            "App/Resources/ONNXRuntime-LICENSE.txt",
            "App/Resources/ONNXRuntime-ThirdPartyNotices.txt",
            "App/Resources/Speech-Notice.txt",
        }))
        sources = {self.objects[item["fileRef"]]["path"]
                   for item in self.phase_files(self.keyboard, "PBXSourcesBuildPhase")}
        self.assertTrue(sources.isdisjoint({
            "App/BilingualAudioTranscriber.swift", "App/SpeechTranscriber.swift",
            "App/SpeechProfiles.swift", "App/AppViewController.swift",
        }))

    def test_canonical_model_manifest_matches_native_resource_and_is_pinned(self):
        canonical = json.loads((ROOT / "speech/asr-model.json").read_text(encoding="utf-8"))
        native = json.loads((ROOT / "native/Sources/HerBilingualASR/Resources/asr-model.json")
                            .read_text(encoding="utf-8"))
        self.assertEqual(native, canonical)
        self.assertRegex(canonical["revision"], r"^[0-9a-f]{40}$")
        self.assertEqual(canonical["license"], "Apache-2.0")
        self.assertEqual(canonical["sampleRate"], 16000)
        roles = {item["role"] for item in canonical["files"]}
        self.assertEqual(roles, {"encoder", "decoder", "joiner", "tokens", "bpeVocab"})
        self.assertEqual(len(canonical["files"]), len(roles))
        self.assertEqual(canonical["totalBytes"], sum(item["bytes"] for item in canonical["files"]))
        for item in canonical["files"]:
            with self.subTest(role=item["role"]):
                self.assertEqual(Path(item["filename"]).name, item["filename"])
                self.assertGreater(item["bytes"], 0)
                self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")
                url = urlsplit(item["url"])
                self.assertEqual(url.scheme, "https")
                self.assertIn(canonical["revision"], url.path.split("/"))

    def test_resolved_native_dependencies_are_fixed_revisions(self):
        resolved = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
        self.assertEqual(resolved["version"], 2)
        pins = {item["identity"]: item for item in resolved["pins"]}
        expected = {
            "sherpa-onnx": ("https://github.com/k2-fsa/sherpa-onnx", "1.13.8",
                            "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"),
            "onnxruntime-libs": ("https://github.com/csukuangfj/onnxruntime-libs", "1.28.2",
                                "8ebc5ebf92190903c274a7621ba4c96a732335ec"),
        }
        self.assertEqual(set(pins), set(expected))
        self.assertEqual(len(resolved["pins"]), len(expected), "Duplicate lockfile identities")
        for name, (location, version, revision) in expected.items():
            with self.subTest(dependency=name):
                self.assertEqual(pins[name]["kind"], "remoteSourceControl")
                self.assertEqual(pins[name]["location"], location)
                self.assertEqual(pins[name]["state"], {"version": version, "revision": revision})


if __name__ == "__main__":
    unittest.main()
