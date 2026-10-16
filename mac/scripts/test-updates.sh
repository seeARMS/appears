#!/bin/bash
# Network-free smoke test in a separate fixture bundle, never the installed app.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/mac/build/update-smoke"
APP="$OUT/UpdateSmoke.app"
mkdir -p "$APP/Contents/MacOS"
python3 -I - "$ROOT" "$APP" <<'PY'
import pathlib, plistlib, sys
root, app = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((root / "mac/build/DerivedData/Build/Products/Release/Appears.app/Contents/Info.plist").read_bytes())
info.update(CFBundleExecutable="UpdateSmoke", CFBundleIdentifier="rs.appea.appears.update-smoke",
            CFBundleShortVersionString="0.7.0", CFBundleVersion="70")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -parse-as-library -swift-version 6 \
  -F "$ROOT/mac/Vendor/Sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$ROOT/mac/Vendor/Sparkle" \
  "$ROOT/mac/App/Sources/Updater.swift" "$ROOT/mac/App/Sources/UpdatesPane.swift" \
  "$ROOT/mac/Tools/UpdateSmoke/main.swift" -o "$APP/Contents/MacOS/UpdateSmoke"
UPDATE_SMOKE_OUTPUT="$OUT" "$APP/Contents/MacOS/UpdateSmoke"
