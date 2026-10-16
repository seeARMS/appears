import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


licenses = load("bundle-licenses")
model = load("prepare_model")


class PackagingTests(unittest.TestCase):
    def test_dependency_checkouts_resolve_for_builds_and_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            checkouts = root / "DerivedData/SourcePackages/checkouts"
            checkouts.mkdir(parents=True)
            for relative in ["Build/Products", "Build/Intermediates.noindex/ArchiveIntermediates/Appears/BuildProductsPath"]:
                build = root / "DerivedData" / relative
                build.mkdir(parents=True)
                self.assertEqual(licenses.find_checkouts(build), checkouts)
            with self.assertRaises(FileNotFoundError):
                licenses.find_checkouts(root / "without-packages/Build/Products")

    def test_exact_dependency_notices_and_tamper_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / "checkouts/example"
            checkout.mkdir(parents=True)
            (checkout / "LICENSE").write_text("upstream license")
            nested = checkout / "Sources/vendor"
            nested.mkdir(parents=True)
            (nested / "NOTICE.txt").write_text("nested attribution")
            resolved = root / "Package.resolved"
            resolved.write_text(json.dumps({"pins": [{"identity": "example", "location": "https://example.invalid/source", "state": {"revision": "abc123"}}]}))
            output = root / "Licenses"
            with patch.object(licenses.subprocess, "check_output", return_value="abc123\n"):
                licenses.bundle(checkout.parent, resolved, output)
            self.assertEqual((output / "Dependencies/example/Sources/vendor/NOTICE.txt").read_text(), "nested attribution")
            self.assertTrue((output / "EmbeddingGemma2Swift/UPSTREAM_PILLOW_LICENSE").is_file())
            (output / "Dependencies/example/LICENSE").write_text("changed")
            with self.assertRaises(ValueError):
                licenses.verify(output)
            with patch.object(licenses.subprocess, "check_output", return_value="wrong-revision\n"):
                with self.assertRaises(ValueError):
                    licenses.bundle(checkout.parent, resolved, output)
            self.assertEqual((output / "Dependencies/example/LICENSE").read_text(), "changed")

    def test_model_split_keeps_notices_and_original_tensor_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.mkdir()
            header = {name: {"dtype": "BF16", "shape": [1], "data_offsets": [i * 2, i * 2 + 2]}
                      for i, name in enumerate(["language_model.test", "vision_tower.test", "audio_tower.test"])}
            encoded = json.dumps(header).encode()
            checkpoint = source / "model.safetensors"
            checkpoint.write_bytes(struct.pack("<Q", len(encoded)) + encoded + b"aabbcc")
            output = Path(temporary) / "prepared"
            with patch.object(model, "SOURCE_SHA256", model.sha256(checkpoint)), patch.object(sys, "argv", ["prepare_model.py", "--source", str(source), "--output", str(output)]):
                model.main()
            for name, expected in [("model.safetensors", b"aa"), ("vision.safetensors", b"bb")]:
                _, start = model.read_header(output / name)
                self.assertEqual((output / name).read_bytes()[start:], expected)
            manifest = json.loads((output / "appears-model.json").read_text())
            self.assertEqual(manifest["license"], "Apache-2.0")
            for name, notice in model.MODEL_NOTICES.items():
                self.assertEqual((output / name).read_bytes(), notice.read_bytes())
                self.assertEqual(manifest["files"][name], model.sha256(notice))

    def test_bundled_model_notice_pins_match_distributed_sources(self):
        descriptor = json.loads((ROOT / "mac/Packages/AppearsKit/Sources/AppearsCore/Resources/model-download.json").read_text())
        pins = {file["name"]: file for file in descriptor["files"]}
        for name, source in model.MODEL_NOTICES.items():
            self.assertEqual(pins[name]["size"], source.stat().st_size)
            self.assertEqual(pins[name]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
