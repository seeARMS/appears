#!/bin/sh
# Downloads H2O's H2O-Lightning-4B (Apache 2.0) at a pinned revision, checks its SHA-256, and
# prepares mac/Models/h2o-lightning-4b-q4 (text only, MLX 4-bit) for separate R2 hosting or a
# developer's local tests. The app and engine never download anything; the restricted
# downloader helper installs these files after the embedding model. Run from anywhere in the repo.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REVISION=acaf0d4ea251e54de928c75ef4352670d33192d3
SOURCE="$ROOT/mac/Models/h2o-lightning-4b"
OUTPUT="$ROOT/mac/Models/h2o-lightning-4b-q4"

uvx --from huggingface_hub hf download h2oai/h2o-lightning-4b --revision "$REVISION" --local-dir "$SOURCE" \
  --exclude "adapter/*" --exclude "assets/*"
uv run --python 3.12 --with 'mlx==0.32.4' --with 'mlx-vlm==0.7.8' --with 'transformers==5.20.1' \
  python -I "$ROOT/mac/scripts/prepare_decider.py" --source "$SOURCE" --output "$OUTPUT"
