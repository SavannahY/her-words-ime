import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from compile_web_rules import build_payload, render_payload
from compile_packs import compile_data
from serve_voice import create_server
from validate_packs import DEFAULT_MANIFEST, load_project


class WebRulesTests(unittest.TestCase):
    def test_same_manifest_and_deterministic_data(self):
        project = load_project(DEFAULT_MANIFEST)
        payload = build_payload()
        self.assertEqual(payload["rules"], compile_data(project)["rules"])
        self.assertEqual(render_payload(payload), render_payload(build_payload()))
        self.assertEqual(json.loads(render_payload(payload)), payload)
        self.assertNotIn("exact_aliases", payload)

    @unittest.skipUnless(shutil.which("node"), "Node.js is optional for browser module tests")
    def test_browser_engine_against_all_pack_examples(self):
        project = load_project(DEFAULT_MANIFEST)
        cases = []
        for mode, packs in (("friendly", project.neutral), ("community", project.community)):
            for pack in packs:
                for entry in pack.data["entries"]:
                    for example in entry["tests"]:
                        cases.append({"input": example["input"],
                                      "expected": example["expected"].replace("他", "她"),
                                      "options": {"mode": mode}})
        result = subprocess.run([shutil.which("node"), str(ROOT / "web/verify-rules.mjs")],
                                input=json.dumps({"payload": build_payload(), "cases": cases}),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node.js is optional for speech event tests")
    def test_original_voice_controller_lifecycle(self):
        result = subprocess.run([shutil.which("node"), str(ROOT / "web/verify-voice.mjs")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Verified 9 speech-controller checks", result.stdout)

    def test_server_loopback_read_only_and_no_traversal(self):
        server = create_server(0)
        self.assertEqual(server.server_address[0], "127.0.0.1")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = "http://127.0.0.1:{}".format(server.server_port)
        try:
            with urlopen(url + "/rules.json") as response:
                self.assertEqual(json.load(response), build_payload())
                self.assertEqual(response.headers["Cache-Control"], "no-store")
            with urlopen(url) as response:
                self.assertIn("语音书写", response.read().decode())
                self.assertIn("script-src 'self'", response.headers["Content-Security-Policy"])
            for request, status in ((Request(url + "/rules.json", data=b"private text", method="POST"), 405),
                                    (Request(url + "/../language-packs.json"), 404),
                                    (Request(url, headers={"Host": "remote.example"}), 403)):
                with self.assertRaises(HTTPError) as caught:
                    urlopen(request)
                self.assertEqual(caught.exception.code, status)
                caught.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
