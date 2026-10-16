import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "mac/scripts"
SIGNER = ROOT / "mac/Vendor/Sparkle/bin/sign_update"


@unittest.skipUnless(SIGNER.exists(), "Build the pinned Sparkle tools first")
class UpdateSigningTests(unittest.TestCase):
    def test_signed_release_and_feed_reject_tampering_and_mismatched_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            subprocess.run(["xcrun", "swift", str(SCRIPTS / "tests/signing-fixture.swift"), directory], check=True, capture_output=True)
            environment = dict(os.environ, SPARKLE_PRIVATE_KEY_PATH=str(path / "private.key"),
                               SPARKLE_PUBLIC_ED_KEY=(path / "public.key").read_text())
            validate = ["xcrun", "swift", str(SCRIPTS / "verify-update-key.swift")]
            subprocess.run(validate, check=True, env=environment, capture_output=True)
            mismatch = dict(environment, SPARKLE_PUBLIC_ED_KEY="A" * 43 + "=")
            self.assertNotEqual(subprocess.run(validate, env=mismatch, capture_output=True).returncode, 0)
            release = {"tag_name": "v0.8.0", "draft": False, "prerelease": False,
                       "html_url": "https://github.com/seeARMS/appears/releases/tag/v0.8.0",
                       "body": "- Faster indexing.", "published_at": "2026-10-15T20:00:00Z"}
            (path / "release.json").write_text(json.dumps(release))
            (path / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "80", "LSMinimumSystemVersion": "26.0"}))
            dmg = path / "Appears.dmg"
            dmg.write_bytes(b"Made-up release bytes")
            feed = path / "appcast.xml"
            subprocess.run(["python3", "-I", str(SCRIPTS / "make-appcast.py"), "0.8.0", str(path / "release.json"),
                            str(path / "Info.plist"), str(dmg), str(SIGNER), str(path / "private.key"), str(feed)], check=True, capture_output=True)
            signer = [str(SIGNER), "--ed-key-file", str(path / "private.key")]
            subprocess.run(signer + [str(feed)], check=True, capture_output=True)
            subprocess.run(signer + ["--verify", str(feed)], check=True, capture_output=True)
            feed.write_bytes(feed.read_bytes().replace(b"Faster indexing", b"Changed release notes"))
            self.assertNotEqual(subprocess.run(signer + ["--verify", str(feed)], capture_output=True).returncode, 0)
            signature = subprocess.check_output(signer + ["-p", str(dmg)], text=True).strip()
            dmg.write_bytes(b"Tampered release")
            self.assertNotEqual(subprocess.run(signer + ["--verify", str(dmg), signature], capture_output=True).returncode, 0)
