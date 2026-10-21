#!/usr/bin/env python3
"""Build and ad-hoc sign a local macOS speech app; never open its microphone."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "org.herwords.speech.mac"
APP_NAME = "她说语音.app"


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def build(configuration, skip_build=False):
    sdk_path = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                   capture_output=True, text=True).stdout.strip()
    environment = os.environ.copy()
    environment["SDKROOT"] = sdk_path
    swift_build = ["swift", "build", "--disable-keychain", "--disable-netrc"]
    if not skip_build:
        run(swift_build + ["-c", configuration, "--product", "her-speech-mac"], env=environment)
    binary_directory = Path(run(
        swift_build + ["-c", configuration, "--show-bin-path"],
        capture_output=True, text=True, env=environment).stdout.strip())
    binary = binary_directory / "her-speech-mac"
    if not binary.is_file():
        raise RuntimeError("SwiftPM did not produce her-speech-mac.")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    destination = dist / APP_NAME
    with tempfile.TemporaryDirectory(prefix=".her-speech-build-", dir=dist) as staging:
        app = Path(staging) / APP_NAME
        contents = app / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(binary, macos / "her-speech-mac")
        os.chmod(macos / "her-speech-mac", 0o755)
        for source in [ROOT / "ios/Keyboard/Resources/rules.json", ROOT / "speech/profiles.json",
                       ROOT / "speech/asr-model.json"]:
            if not source.is_file():
                raise RuntimeError("Missing canonical resource: " + str(source.relative_to(ROOT)))
            shutil.copy2(source, resources / source.name)
        for source in (ROOT / "ios/Keyboard/Resources").glob("*.txt"):
            shutil.copy2(source, resources / source.name)
        for source in (ROOT / "ios/App/Resources").glob("*.txt"):
            shutil.copy2(source, resources / source.name)
        # ModelStore first reads the pinned manifest from Bundle.main. Keep a standard
        # macOS app layout; do not rely on SwiftPM's absolute build-directory fallback.
        info = {
            "CFBundleDevelopmentRegion": "zh_CN", "CFBundleIdentifier": IDENTIFIER,
            "CFBundleExecutable": "her-speech-mac", "CFBundleName": "她说语音",
            "CFBundleDisplayName": "她说语音", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0", "LSUIElement": False,
            "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
            "NSMicrophoneUsageDescription": "仅在你点击开始录音后使用麦克风，在本机将中文和英文转成文字。",
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        run(["codesign", "--force", "--deep", "--sign", "-", str(app)])
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        run([str(macos / "her-speech-mac"), "--check-resources"])
        previous = dist / ("." + APP_NAME + ".previous")
        if previous.exists():
            raise RuntimeError("A previous backup already exists: " + str(previous))
        if destination.exists():
            try:
                with (destination / "Contents/Info.plist").open("rb") as stream:
                    existing = plistlib.load(stream)
            except (OSError, plistlib.InvalidFileException) as error:
                raise RuntimeError("Refusing to replace an unrecognized app: " + str(destination)) from error
            if existing.get("CFBundleIdentifier") != IDENTIFIER:
                raise RuntimeError("Refusing to replace an app with another identifier.")
            destination.rename(previous)
        try:
            app.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    print("Built and ad-hoc signed: " + str(destination))
    print("Open the app yourself to grant microphone permission; this script does not launch it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--skip-build", action="store_true", help="package an already-built executable")
    arguments = parser.parse_args()
    build(arguments.configuration, skip_build=arguments.skip_build)


if __name__ == "__main__":
    main()
