#!/bin/bash
# Upload an already signed/notarized release; promote only after verifying R2 bytes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=${1:?usage: upload-release.sh <version>}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected X.Y.Z." >&2; exit 1; }
: "${CLOUDFLARE_ACCOUNT_ID:?Set the personal Cloudflare account id}"
: "${R2_BUCKET:?Set R2_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?Set the bucket-scoped R2 access key id}"
: "${AWS_SECRET_ACCESS_KEY:?Set the R2 secret access key}"
OUT="$ROOT/mac/build/release"
KEY="releases/v$VERSION/Appears.dmg"
ENDPOINT="https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
export AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
aws_r2() { aws --endpoint-url "$ENDPOINT" "$@"; }

cd "$OUT"
shasum -a 256 -c Appears.dmg.sha256
SHA=$(shasum -a 256 Appears.dmg | cut -d' ' -f1)
# Listing must succeed; do not mistake a permission/network failure for a missing version.
EXISTING=$(aws_r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "$KEY" --query 'Contents[].Key' --output text)
if [[ -n "$EXISTING" && "$EXISTING" != None ]]; then
  echo "v$VERSION already exists. Use a new version; download URLs are immutable." >&2
  exit 1
fi
# The AWS CLI uses multipart uploads automatically when needed.
aws_r2 s3 cp Appears.dmg "s3://$R2_BUCKET/$KEY" --only-show-errors \
  --content-type application/x-apple-diskimage --content-disposition 'attachment; filename="Appears.dmg"' \
  --cache-control 'public, max-age=31536000, immutable' --metadata "version=$VERSION,sha256=$SHA"
REMOTE_SHA=$(aws_r2 s3 cp "s3://$R2_BUCKET/$KEY" - --only-show-errors | shasum -a 256 | cut -d' ' -f1)
[[ "$REMOTE_SHA" == "$SHA" ]] || { echo "R2 checksum mismatch; latest download was not changed." >&2; exit 1; }
aws_r2 s3 cp Appears.dmg.sha256 "s3://$R2_BUCKET/$KEY.sha256" --only-show-errors \
  --content-type text/plain --cache-control 'public, max-age=31536000, immutable'
# One small atomic write switches /app.dmg after both immutable objects are complete.
printf '{"version":"%s","sha256":"%s"}\n' "$VERSION" "$SHA" > latest.json
aws_r2 s3api put-object --bucket "$R2_BUCKET" --key latest.json --body latest.json \
  --content-type application/json --cache-control no-store >/dev/null
echo "Uploaded v$VERSION. Latest download: https://appea.rs/app.dmg"
