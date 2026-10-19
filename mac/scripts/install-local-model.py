#!/usr/bin/env python3
"""Seed a developer's model cache from verified local weights; no network or publishing.

    mac/scripts/install-local-model.py            # the embedding model (mac/Models/appears-model)
    mac/scripts/install-local-model.py --decider  # the answer model (mac/Models/h2o-lightning-4b-q4)
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("--decider", action="store_true", help="Install the answer model instead of the embedder.")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
resource, folder = ("decider-download.json", "h2o-lightning-4b-q4") if args.decider else ("model-download.json", "appears-model")
descriptor = json.loads((repo / "mac/Packages/AppearsKit/Sources/AppearsCore/Resources" / resource).read_text())
source = repo / "mac/Models" / folder
for file in descriptor["files"]:
    path = source / file["name"]
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if path.stat().st_size != file["size"] or digest != file["sha256"]:
        raise SystemExit(f"Model integrity check failed: {file['name']}")
root = Path.home() / "Library/Containers/rs.appea.appears.downloader/Data/Library/Application Support/Appears/Models"
staging = root / f".{descriptor['id']}-local"
destination = root / descriptor["id"]
if destination.exists():
    raise SystemExit("The model cache already exists. No files were changed.")
staging.mkdir(parents=True, exist_ok=True)
for file in descriptor["files"]:
    shutil.copy2(source / file["name"], staging / file["name"])
(staging / "verified.json").write_text(json.dumps(descriptor))
staging.rename(destination)
print("Installed the verified model in the downloader's local cache.")
