#!/usr/bin/env python3
"""Bundle notices from the exact resolved sources before Xcode signs the app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VENDORED = ROOT / "mac/Packages/AppearsModel/ThirdParty/EmbeddingGemma2Swift"
VENDORED_FILES = ["LICENSE", "NOTICE", "APACHE-2.0.txt", "UPSTREAM_MLX_VLM_LICENSE", "UPSTREAM_PILLOW_LICENSE"]


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_checkouts(build_dir):
    # Archive products sit deeper in DerivedData than regular build products.
    build_dir = build_dir.resolve()
    for ancestor in (build_dir, *build_dir.parents):
        checkouts = ancestor / "SourcePackages/checkouts"
        if checkouts.is_dir():
            return checkouts
    raise FileNotFoundError(f"No SourcePackages/checkouts found above {build_dir}")


def verify(folder):
    manifest = json.loads((folder / "manifest.json").read_text())
    if not manifest.get("files") or not manifest.get("dependencies"):
        raise ValueError("License manifest is empty")
    for name, digest in manifest["files"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid license path")
        if checksum(folder / relative) != digest:
            raise ValueError(f"Missing or changed bundled notice: {name}")
    print(f"Verified {len(manifest['files'])} bundled license and notice files.")


def bundle(checkouts, resolved, output, sparkle=None):
    pins = json.loads(resolved.read_text())["pins"]
    folders = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}
    sources = [(ROOT / "LICENSE", Path("Appears-LICENSE.txt"))]
    sources += [(VENDORED / name, Path("EmbeddingGemma2Swift") / name) for name in VENDORED_FILES]
    dependencies = []
    for pin in sorted(pins, key=lambda p: p["identity"]):
        name = pin["identity"]
        checkout = folders[name.lower()]
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if revision != pin["state"]["revision"]:
            raise ValueError(f"Dependency checkout differs from Package.resolved: {name}")
        notices = sorted(p for p in checkout.rglob("*") if p.is_file() and
                         ".git" not in p.relative_to(checkout).parts and
                         p.name.upper().startswith(("LICENSE", "NOTICE", "COPYING", "COPYRIGHT")))
        if not any(p.parent == checkout and p.name.upper().startswith("LICENSE") for p in notices):
            raise ValueError(f"No upstream license found for {name}")
        sources += [(p, Path("Dependencies") / name / p.relative_to(checkout)) for p in notices]
        dependencies.append({"name": name, "source": pin["location"], "revision": revision})
    if sparkle is not None:
        expected = re.search(r"^COMMIT=([a-f0-9]{40})$", (ROOT / "mac/scripts/build-sparkle.sh").read_text(), re.MULTILINE).group(1)
        revision = subprocess.check_output(["git", "-C", str(sparkle), "rev-parse", "HEAD"], text=True).strip()
        if revision != expected:
            raise ValueError("Sparkle checkout differs from the pinned build revision")
        sources.append((sparkle / "LICENSE", Path("Sparkle/LICENSE")))
        dependencies.append({"name": "Sparkle", "source": "https://github.com/sparkle-project/Sparkle", "revision": revision})
    # Resolve and validate all inputs before replacing the generated resource.
    contents = [(source.read_bytes(), relative) for source, relative in sources]
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    files = {}
    for data, relative in contents:
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        files[relative.as_posix()] = hashlib.sha256(data).hexdigest()
    (output / "manifest.json").write_text(json.dumps({"dependencies": dependencies, "files": files}, indent=2) + "\n")
    verify(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--resolved", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sparkle", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        verify(args.verify)
    else:
        if args.checkouts is None and args.build_dir is not None:
            args.checkouts = find_checkouts(args.build_dir)
        if not all((args.checkouts, args.resolved, args.output)):
            parser.error("--resolved, --output and either --checkouts or --build-dir are required")
        bundle(args.checkouts, args.resolved, args.output, args.sparkle)


if __name__ == "__main__":
    main()
