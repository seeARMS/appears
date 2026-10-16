#!/bin/bash
# Pinned Sparkle with a network-only sandboxed downloader, native Markdown notes,
# and NO network implementation linked into the app's copy of the framework.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TAG=2.10.0
COMMIT=eef1a539a373c1f1a320624b1130fc5de7b2e100
SRC="$ROOT/mac/build/sparkle-src"
DERIVED="$ROOT/mac/build/sparkle-derived"
OUT="$ROOT/mac/Vendor/Sparkle"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/sparkle-project/Sparkle.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$COMMIT" ]] || { echo "Unexpected Sparkle revision." >&2; exit 1; }
python3 -I "$ROOT/mac/scripts/prepare-sparkle.py" "$SRC"
build() {
  xcodebuild -project "$SRC/Sparkle.xcodeproj" -scheme "$1" -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    DOWNLOADER_SANDBOXED_ENTITLEMENTS=Downloader/Downloader.entitlements \
    XPC_SERVICE_BUNDLE_ID_PREFIX=rs.appea.appears \
    SPARKLE_EMBED_INSTALLER_LAUNCHER_XPC_SERVICE=0 \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build -quiet
}
build Sparkle
build sign_update
build generate_keys
mkdir -p "$OUT/bin"
ditto "$DERIVED/Build/Products/Release/Sparkle.framework" "$OUT/Sparkle.framework"
for tool in sign_update generate_keys; do cp "$DERIVED/Build/Products/Release/$tool" "$OUT/bin/"; done
echo "Built isolated Sparkle $TAG."
