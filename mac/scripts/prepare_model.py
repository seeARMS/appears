# Splits Google's EmbeddingGemma 2 checkpoint into the folder Appears bundles:
#
#   model.safetensors   language_model.* tensors (text encoder)
#   vision.safetensors  vision_tower.* and embed_vision.* tensors (image encoder)
#   config.json, tokenizer files, and appears-model.json (provenance and checksums)
#
# The audio encoder (about 600 MB) is left out: Appears doesn't index voice messages yet.
# Tensors are copied byte for byte, so nothing about the weights changes. Standard library
# only. Run from the repo root:
#
#   python3 -I mac/scripts/prepare_model.py --source mac/Models/embeddinggemma-2 --output mac/Models/appears-model

import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path

SOURCE_REPO = "google/embeddinggemma-2"
SOURCE_REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
SOURCE_SHA256 = "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"
SMALL_FILES = ["config.json", "tokenizer.json", "tokenizer_config.json", "tokenizer.model",
               "preprocessor_config.json", "processor_config.json", "chat_template.jinja"]
ROOT = Path(__file__).resolve().parents[2]
MODEL_NOTICES = {
    "LICENSE.txt": ROOT / "mac/Packages/AppearsModel/ThirdParty/EmbeddingGemma2Swift/APACHE-2.0.txt",
    "NOTICE.txt": ROOT / "mac/ModelNotices/NOTICE.txt",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_header(path: Path) -> tuple[dict, int]:
    with path.open("rb") as f:
        length = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(length)), 8 + length


def write_subset(source: Path, destination: Path, keep) -> int:
    header, data_start = read_header(source)
    header.pop("__metadata__", None)
    names = sorted(name for name in header if keep(name))
    out_header, offset = {"__metadata__": {"format": "pt"}}, 0
    for name in names:
        start, end = header[name]["data_offsets"]
        out_header[name] = {"dtype": header[name]["dtype"], "shape": header[name]["shape"],
                            "data_offsets": [offset, offset + end - start]}
        offset += end - start
    encoded = json.dumps(out_header, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)  # safetensors pads the header to 8 bytes
    with source.open("rb") as src, destination.open("wb") as dst:
        dst.write(struct.pack("<Q", len(encoded)))
        dst.write(encoded)
        for name in names:
            start, end = header[name]["data_offsets"]
            src.seek(data_start + start)
            remaining = end - start
            while remaining:
                chunk = src.read(min(remaining, 1 << 24))
                dst.write(chunk)
                remaining -= len(chunk)
    return len(names)


def write_manifest(output: Path, text: int, vision: int) -> None:
    for name, source in MODEL_NOTICES.items():
        shutil.copy2(source, output / name)
    files = {p.name: sha256(p) for p in sorted(output.iterdir()) if p.is_file() and p.name != "appears-model.json"}
    manifest = {
        "source": SOURCE_REPO,
        "revision": SOURCE_REVISION,
        "source_sha256": SOURCE_SHA256,
        "license": "Apache-2.0",
        "contents": f"text encoder ({text} tensors) and vision encoder ({vision} tensors), bf16, unchanged",
        "files": files,
    }
    (output / "appears-model.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    checkpoint = args.source / "model.safetensors"
    actual = sha256(checkpoint)
    if actual != SOURCE_SHA256:
        raise SystemExit(f"{checkpoint} has SHA-256 {actual}, expected {SOURCE_SHA256} ({SOURCE_REPO}@{SOURCE_REVISION})")

    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True)
    for name in SMALL_FILES:
        if (args.source / name).exists():
            shutil.copy2(args.source / name, args.output / name)

    text = write_subset(checkpoint, args.output / "model.safetensors", lambda n: n.startswith("language_model."))
    vision = write_subset(checkpoint, args.output / "vision.safetensors",
                          lambda n: n.startswith(("vision_tower.", "embed_vision.")))

    write_manifest(args.output, text, vision)
    total = sum(p.stat().st_size for p in args.output.iterdir())
    print(f"wrote {args.output} ({total / 1e6:.0f} MB): {text} text tensors, {vision} vision tensors")


if __name__ == "__main__":
    main()
