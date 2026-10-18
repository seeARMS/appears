#!/bin/bash
# A credential-free Release build. Ad-hoc signing preserves the XPC sandbox
# entitlements so the privacy check inspects what a real app would contain.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
"$ROOT/mac/scripts/build-sparkle.sh"
cd "$ROOT/mac"
xcodegen --quiet
# Reuse compiler results by input content, while still rebuilding and signing
# every app/resource bundle from scratch (incremental bundles can go unsigned).
xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release \
  -derivedDataPath build/CheckDerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= clean build -quiet
APP="$ROOT/mac/build/CheckDerivedData/Build/Products/Release/Appears.app"
codesign --verify --deep --strict "$APP"
"$ROOT/mac/scripts/check-no-network.sh" "$APP"
python3 -I "$ROOT/mac/scripts/bundle-licenses.py" --verify "$APP/Contents/Resources/Licenses"
