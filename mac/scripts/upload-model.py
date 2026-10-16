#!/usr/bin/env python3
"""Upload only the model pinned in the app; no real user files or remote manifests."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
descriptor_path = root / "mac/Packages/AppearsKit/Sources/AppearsCore/Resources/model-download.json"
descriptor = json.loads(descriptor_path.read_text())
source = root / "mac/Models/appears-model"
bucket = os.environ["R2_BUCKET"]
account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
prefix = f"models/{descriptor['id']}/"
os.environ.update(AWS_DEFAULT_REGION="auto", AWS_REQUEST_CHECKSUM_CALCULATION="when_required", AWS_RESPONSE_CHECKSUM_VALIDATION="when_required")

def aws(*args, **kwargs):
    return subprocess.run(["aws", "--endpoint-url", f"https://{account}.r2.cloudflarestorage.com", *args], check=True, **kwargs)

# Validate every file before uploading any of them. Bytes are pinned in source.
for file in descriptor["files"]:
    path = source / file["name"]
    with path.open("rb") as f:
        digest = hashlib.file_digest(f, "sha256").hexdigest()
    if path.stat().st_size != file["size"] or digest != file["sha256"]:
        raise SystemExit(f"Prepared model differs from the app's pinned descriptor: {file['name']}")

for file in descriptor["files"]:
    key = prefix + file["name"]
    # Re-uploading is safe: the local bytes were checked against immutable pins.
    aws("s3", "cp", str(source / file["name"]), f"s3://{bucket}/{key}", "--only-show-errors",
        "--content-type", "application/octet-stream", "--cache-control", "public, max-age=31536000, immutable",
        "--metadata", f"sha256={file['sha256']}")
    # Read back the uploaded bytes before making a new app version available.
    # Some AWS CLI versions stall multipart downloads to stdout. A direct GetObject
    # into a temporary file avoids that transfer path and still verifies every byte.
    with tempfile.TemporaryDirectory(prefix="appears-model-verify-") as temporary:
        downloaded = Path(temporary) / file["name"]
        aws("s3api", "get-object", "--bucket", bucket, "--key", key, str(downloaded),
            stdout=subprocess.DEVNULL)
        with downloaded.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if downloaded.stat().st_size != file["size"] or actual != file["sha256"]:
            raise SystemExit(f"R2 verification failed: {file['name']}")
print(f"Uploaded and verified {len(descriptor['files'])} pinned model files.")
