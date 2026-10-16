#!/bin/bash
# Build this checkout, verify it, then replace and reopen the local app.
# Uses an existing signing identity; never creates credentials or publishes.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALL_DIR=${APPEARS_INSTALL_DIR:-/Applications}
BUILD_ONLY=0
case "${1:-}" in
  --build-only) BUILD_ONLY=1 ;;
  --help|-h)
    echo "Usage: npm run rebuild [-- --build-only]"
    echo "Builds this checkout in Release, checks it, installs it and opens Appears."
    echo "APPEARS_INSTALL_DIR selects the install folder (default: /Applications)."
    echo "APPEARS_SIGN_IDENTITY selects an existing signing identity."
    exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1 (use --help)." >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "Too many arguments." >&2; exit 1; }

[[ $(uname -m) == arm64 ]] || { echo "Appears requires an Apple silicon Mac." >&2; exit 1; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || { echo "Set DEVELOPER_DIR to a full Xcode installation." >&2; exit 1; }
for tool in xcodegen python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool (see README.md)." >&2; exit 1; }
done
[[ -d "$INSTALL_DIR" ]] || { echo "Install folder does not exist: $INSTALL_DIR" >&2; exit 1; }
INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd -P)
APP="$INSTALL_DIR/Appears.app"
if [[ $BUILD_ONLY -eq 0 ]]; then
  [[ -w "$INSTALL_DIR" && ! -L "$APP" && ( ! -e "$APP" || -d "$APP" ) ]] || {
    echo "Install folder must be writable; Appears.app must be a directory, not a symlink." >&2
    echo 'For a per-user install: mkdir -p ~/Applications; APPEARS_INSTALL_DIR="$HOME/Applications" npm run rebuild' >&2
    exit 1
  }
fi

WORK=$(mktemp -d)
STAGING=""
cleanup() {
  local result=$?
  if [[ $result -ne 0 && -n "$STAGING" && -d "$STAGING/Previous.app" ]]; then
    rm -rf "$APP"
    if ! mv "$STAGING/Previous.app" "$APP"; then
      echo "Previous app retained at $STAGING/Previous.app; restore it manually." >&2
      rm -rf "$WORK"
      return "$result"
    fi
    echo "Restored the previous Appears.app." >&2
  fi
  [[ -z "$STAGING" ]] || rm -rf "$STAGING"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reuse the installed Apple identity. Self-signed certificates have no Team ID
# and cannot load embedded frameworks with hardened runtime's library validation.
IDENTITY=$(python3 -I - "$APP" "$WORK" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

app, work = map(Path, sys.argv[1:])
output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
identities = dict(re.findall(r'\b([A-F0-9]{40}) "([^"]+)"', output))
prefixes = ("Developer ID Application:", "Apple Development:", "Mac Developer:")
choice = os.environ.get("APPEARS_SIGN_IDENTITY", "")
if not choice and app.exists():
    result = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True)
    team = re.search(r"^TeamIdentifier=(.+)$", result.stderr, re.MULTILINE)
    if team and team[1] != "not set":
        result = subprocess.run(["codesign", "-d", f"--extract-certificates={work / 'cert-'}", str(app)],
                                capture_output=True)
        if result.returncode or not (work / "cert-0").is_file():
            sys.exit("Could not read the installed signing certificate. Set APPEARS_SIGN_IDENTITY explicitly.")
        choice = hashlib.sha1((work / "cert-0").read_bytes()).hexdigest().upper()
    else:
        print("Installed app has no Apple Team ID; selecting an Apple signing identity. Permissions may need granting again.", file=sys.stderr)
if choice:
    matches = [(key, name) for key, name in identities.items() if key == choice.upper() or name == choice]
else:
    matches = []
    for prefix in prefixes:
        matches = [(key, name) for key, name in identities.items() if name.startswith(prefix)]
        if matches:
            break
if len(matches) != 1 or not matches[0][1].startswith(prefixes):
    sys.exit("Select one existing Apple signing identity with APPEARS_SIGN_IDENTITY (full name or SHA-1). Self-signed and ad-hoc signatures are unsupported. See README.md; no certificates were created.")
print(f"Signing with {matches[0][1]}", file=sys.stderr)
print(matches[0][0])
PY
)

echo "Building checkout $(git -C "$ROOT" rev-parse --short HEAD) in Release…"
"$ROOT/mac/scripts/build-sparkle.sh"
cd "$ROOT/mac"
xcodegen --quiet
xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release \
  -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="$(cat "$ROOT/VERSION")" \
  CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-list --count HEAD)" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build -quiet

BUILT_APP="$ROOT/mac/build/DerivedData/Build/Products/Release/Appears.app"
# Xcode signs the framework, but its nested helpers also need our identity.
SPARKLE="$BUILT_APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$@"; }
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --preserve-metadata=entitlements "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
SIGNED_METADATA=$(codesign -dv "$BUILT_APP" 2>&1)
if ! grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<< "$SIGNED_METADATA"; then
  echo "The app must have an Apple Team ID for hardened-runtime library validation." >&2
  exit 1
fi
"$ROOT/mac/scripts/check-no-network.sh" "$BUILT_APP"
python3 -I "$ROOT/mac/scripts/bundle-licenses.py" --verify "$BUILT_APP/Contents/Resources/Licenses"

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "Verified build: $BUILT_APP"
  exit 0
fi

# Stage and verify the whole bundle before quitting or moving the installed app.
STAGING=$(mktemp -d "$INSTALL_DIR/.appears-rebuild.XXXXXX")
ditto "$BUILT_APP" "$STAGING/Appears.app"
codesign --verify --deep --strict "$STAGING/Appears.app"
if pgrep -x Appears >/dev/null; then
  osascript -e 'tell application id "rs.appea.appears" to quit'
  for ((attempt=0; attempt<20; attempt++)); do
    pgrep -x Appears >/dev/null || break
    sleep 0.5
  done
  if pgrep -x Appears >/dev/null; then
    echo "Appears is still running. Quit it and retry; the installed app has not been replaced." >&2
    exit 1
  fi
fi
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/Previous.app"; fi
mv "$STAGING/Appears.app" "$APP"
open "$APP"
# LaunchServices can accept an open request even when dyld immediately aborts.
sleep 2
if ! pgrep -x Appears >/dev/null; then
  echo "Appears exited during launch. Check its macOS crash report; restoring the previous app." >&2
  exit 1
fi
echo "Installed and opened: $APP"
