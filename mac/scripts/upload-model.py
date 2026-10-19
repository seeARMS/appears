#!/usr/bin/env python3
"""Upload only a model pinned in the app; no real user files or remote manifests.

    mac/scripts/upload-model.py            # the embedding model (mac/Models/appears-model)
    mac/scripts/upload-model.py --decider  # the decision model (mac/Models/h2o-lightning-4b-q4)

Credentials: a bucket-scoped R2 key, from AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or the
`appears-r2` profile (`aws configure --profile appears-r2`, region `auto`).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--decider", action="store_true", help="Upload the decision model instead of the embedder.")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
resource, folder = ("decider-download.json", "h2o-lightning-4b-q4") if args.decider else ("model-download.json", "appears-model")
descriptor_path = root / "mac/Packages/AppearsKit/Sources/AppearsCore/Resources" / resource
descriptor = json.loads(descriptor_path.read_text())
source = root / "mac/Models" / folder
# Same personal account and bucket as web/wrangler.jsonc and the release workflow.
bucket = os.environ.get("R2_BUCKET", "appears-downloads")
account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "68d615b353a7fe2663d3e7154366864a")
if not os.environ.get("AWS_ACCESS_KEY_ID") and not os.environ.get("AWS_PROFILE"):
    import configparser
    sections = set()
    for name in ("credentials", "config"):
        parser_ = configparser.ConfigParser()
        parser_.read(Path.home() / ".aws" / name)
        sections |= {section.removeprefix("profile ") for section in parser_.sections()}
    if "appears-r2" not in sections:
        raise SystemExit("No R2 credentials. Create a bucket-scoped R2 API token for appears-downloads, then run "
                         "`aws configure --profile appears-r2` (region `auto`), or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.")
    os.environ["AWS_PROFILE"] = "appears-r2"
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
