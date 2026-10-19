# Converts H2O's H2O-Lightning-4B checkpoint into the decision-model folder Appears downloads:
#
#   model-0000N-of-0000M.safetensors   language_model.* tensors, MLX 4-bit affine (group size 64),
#                                      in shards of at most 256 MiB, so a failed checksum re-downloads one shard
#   config.json, tokenizer.json, tokenizer_config.json
#   LICENSE.txt, NOTICE.txt, appears-model.json (provenance and checksums)
#
# The vision encoder is left out: Appears asks only text questions. Quantization uses the
# pinned mlx-vlm on the CPU, so the same source gives the same bytes. Run from the repo root
# (mac/scripts/fetch-decider.sh does both steps):
#
#   uv run --python 3.12 --with 'mlx==0.32.4' --with 'mlx-vlm==0.7.8' --with 'transformers==5.20.1' \
#     python -I mac/scripts/prepare_decider.py --source mac/Models/h2o-lightning-4b --output mac/Models/h2o-lightning-4b-q4

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE_REPO = "h2oai/h2o-lightning-4b"
SOURCE_REVISION = "acaf0d4ea251e54de928c75ef4352670d33192d3"  # v1.2.3
SOURCE_SHA256 = "2d51561f221e1549d91bd1c38b3512a1435dd32950d454a9f040f1d4d11497b6"
TOOLS = {"mlx": "0.32.4", "mlx-vlm": "0.7.8"}
BITS, GROUP_SIZE = 4, 64
SHARD_BYTES = 256 * 1024 * 1024
SMALL_FILES = ["config.json", "tokenizer.json", "tokenizer_config.json"]
ROOT = Path(__file__).resolve().parents[2]
NOTICES = {
    "LICENSE.txt": ROOT / "mac/Packages/AppearsModel/ThirdParty/EmbeddingGemma2Swift/APACHE-2.0.txt",
    "NOTICE.txt": ROOT / "mac/ModelNotices/DECIDER-NOTICE.txt",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def text_shards(sources: list[Path], output: Path) -> int:
    """Copies the language model's tensors byte for byte into shards of at most SHARD_BYTES."""
    entries = []
    for source in sources:
        with source.open("rb") as f:
            length = struct.unpack("<Q", f.read(8))[0]
            header = json.loads(f.read(length))
        header.pop("__metadata__", None)
        for name, info in header.items():
            if name.startswith("language_model."):
                entries.append((name, info, source, 8 + length))
    entries.sort(key=lambda e: e[0])
    shards, current, size = [], [], 0
    for entry in entries:
        start, end = entry[1]["data_offsets"]
        if current and size + (end - start) > SHARD_BYTES:
            shards.append(current)
            current, size = [], 0
        current.append(entry)
        size += end - start
    if current:
        shards.append(current)
    for number, shard in enumerate(shards, 1):
        header, offset = {"__metadata__": {"format": "mlx"}}, 0
        for name, info, _, _ in shard:
            start, end = info["data_offsets"]
            header[name] = {"dtype": info["dtype"], "shape": info["shape"], "data_offsets": [offset, offset + end - start]}
            offset += end - start
        encoded = json.dumps(header, separators=(",", ":")).encode()
        encoded += b" " * (-len(encoded) % 8)
        with (output / f"model-{number:05d}-of-{len(shards):05d}.safetensors").open("wb") as dst:
            dst.write(struct.pack("<Q", len(encoded)))
            dst.write(encoded)
            for name, info, source, data_start in shard:
                start, end = info["data_offsets"]
                with source.open("rb") as src:
                    src.seek(data_start + start)
                    remaining = end - start
                    while remaining:
                        chunk = src.read(min(remaining, 1 << 24))
                        dst.write(chunk)
                        remaining -= len(chunk)
    return len(entries)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--converted", type=Path,
                        help="An existing MLX conversion (from this script) to repackage, instead of converting again.")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="appears-decider-") as temporary:
        if args.converted:
            converted = Path(temporary) / "mlx"
            shutil.copytree(args.converted, converted)
        else:
            import mlx.core as mx
            import mlx_vlm
            found = {"mlx": mx.__version__, "mlx-vlm": mlx_vlm.__version__}
            if found != TOOLS:
                raise SystemExit(f"Expected {TOOLS}, found {found}: other versions can quantize differently.")
            checkpoint = args.source / "model.safetensors"
            actual = sha256(checkpoint)
            if actual != SOURCE_SHA256:
                raise SystemExit(f"{checkpoint} has SHA-256 {actual}, expected {SOURCE_SHA256} ({SOURCE_REPO}@{SOURCE_REVISION})")
            converted = Path(temporary) / "mlx"
            subprocess.run([sys.executable, "-I", "-c",
                            "import mlx.core as mx, runpy, sys; mx.set_default_device(mx.cpu); "
                            "sys.argv = ['mlx_vlm.convert'] + sys.argv[1:]; runpy.run_module('mlx_vlm.convert', run_name='__main__')",
                            "--hf-path", str(args.source), "--mlx-path", str(converted),
                            "-q", "--q-bits", str(BITS), "--q-group-size", str(GROUP_SIZE)], check=True)
        if args.output.exists():
            shutil.rmtree(args.output)
        args.output.mkdir(parents=True)
        tensors = text_shards(sorted(converted.glob("model*.safetensors")), args.output)
        for name in SMALL_FILES:
            shutil.copy2(converted / name, args.output / name)
    for name, source in NOTICES.items():
        shutil.copy2(source, args.output / name)

    files = {p.name: sha256(p) for p in sorted(args.output.iterdir()) if p.is_file() and p.name != "appears-model.json"}
    (args.output / "appears-model.json").write_text(json.dumps({
        "source": SOURCE_REPO, "revision": SOURCE_REVISION, "source_sha256": SOURCE_SHA256, "license": "Apache-2.0",
        "contents": f"language model ({tensors} tensors), MLX {BITS}-bit affine, group size {GROUP_SIZE}; vision encoder omitted",
        "tools": TOOLS, "files": files,
    }, indent=2) + "\n")
    descriptor = [{"name": p.name, "size": p.stat().st_size, "sha256": sha256(p)} for p in sorted(args.output.iterdir()) if p.is_file()]
    total = sum(f["size"] for f in descriptor)
    print(f"wrote {args.output} ({total / 1e6:.0f} MB, {tensors} tensors). Pin these in decider-download.json:")
    print(json.dumps(descriptor, indent=1))


if __name__ == "__main__":
    main()
