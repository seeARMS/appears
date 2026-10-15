#!/bin/sh
# Downloads Google's EmbeddingGemma 2 (Apache 2.0) at a pinned revision, checks its SHA-256,
# and prepares mac/Models/appears-model, which the app bundles. The app itself never
# downloads anything; this runs once on a developer's Mac. Run from anywhere in the repo.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REVISION=914f7f89142e33e77833254d9c9b90c3cef7303b
SOURCE="$ROOT/mac/Models/embeddinggemma-2"
OUTPUT="$ROOT/mac/Models/appears-model"

uvx --from huggingface_hub hf download google/embeddinggemma-2 --revision "$REVISION" --local-dir "$SOURCE"
python3 -I "$ROOT/mac/scripts/prepare_model.py" --source "$SOURCE" --output "$OUTPUT"
