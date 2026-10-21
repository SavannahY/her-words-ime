#!/usr/bin/env python3
"""Build the offline word manager using only Command Line Tools; never launch it."""
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAME = "她说词库.app"
IDENTIFIER = "org.herwords.memory.mac"


def main():
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                         check=True, capture_output=True, text=True).stdout.strip()
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    destination = dist / NAME
    with tempfile.TemporaryDirectory(prefix=".her-memory-build-", dir=dist) as staging:
        app = Path(staging) / NAME
        executable = app / "Contents/MacOS/her-word-memory"
        executable.parent.mkdir(parents=True)
        sources = [ROOT / "native/Sources/HerSpeechMac/MacWordMemoryStore.swift",
                   ROOT / "native/Sources/HerSpeechMac/MacWordMemoryView.swift",
                   ROOT / "native/Tools/WordMemoryApp.swift"]
        # Compile a frozen snapshot while other platform work may continue.
        source_directory = Path(staging) / "sources"
        source_directory.mkdir()
        for source in sources:
            shutil.copy2(source, source_directory / source.name)
        sources = sorted(source_directory.glob("*.swift"))
        architecture = platform.machine()
        if architecture not in ("arm64", "x86_64"):
            raise RuntimeError("Unsupported Mac architecture: " + architecture)
        subprocess.run(["swiftc", "-swift-version", "5", "-O", "-sdk", sdk,
                        "-target", architecture + "-apple-macosx13.0",
                        *map(str, sources), "-o", str(executable)], check=True, cwd=ROOT)
        info = {
            "CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": executable.name,
            "CFBundleName": "她说词库", "CFBundleDisplayName": "她说词库",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        }
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        if destination.exists():
            with (destination / "Contents/Info.plist").open("rb") as stream:
                if plistlib.load(stream).get("CFBundleIdentifier") != IDENTIFIER:
                    raise RuntimeError("Refusing to replace another app.")
            shutil.rmtree(destination)
        app.rename(destination)
    print("Built and verified: " + str(destination))


if __name__ == "__main__":
    main()
