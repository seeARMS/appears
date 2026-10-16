#!/usr/bin/env python3
"""Seed a developer's model cache from verified local weights; no network or publishing."""
import hashlib
import json
from pathlib import Path
import shutil

repo = Path(__file__).resolve().parents[2]
descriptor = json.loads((repo / "mac/Packages/AppearsKit/Sources/AppearsCore/Resources/model-download.json").read_text())
source = repo / "mac/Models/appears-model"
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
