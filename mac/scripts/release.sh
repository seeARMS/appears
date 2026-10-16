#!/bin/bash
# Build, sign, notarize and package Appears. Does not publish anything.
# Used by .github/workflows/release.yml; see README.md for credentials.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=${1:?usage: release.sh <version>}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a version such as 0.1.0." >&2; exit 1; }
[[ "$VERSION" == "$(cat "$ROOT/VERSION")" ]] || { echo "Update VERSION to $VERSION first." >&2; exit 1; }
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application signing identity}"
: "${TEAM_ID:?Set TEAM_ID to your Apple developer team id}"
: "${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to the App Store Connect API private key file}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to the App Store Connect API key id}"
[[ "$DEVELOPER_ID" == "Developer ID Application: "* ]] || { echo "A Developer ID Application identity is required." >&2; exit 1; }
[[ -f "$NOTARY_KEY_PATH" ]] || { echo "Notarization key file not found." >&2; exit 1; }
: "${SPARKLE_PUBLIC_ED_KEY:?Set SPARKLE_PUBLIC_ED_KEY to the release public key}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH to the private key file}"
: "${GITHUB_RELEASE_PATH:?Set GITHUB_RELEASE_PATH to the matching published GitHub release JSON}"
[[ -f "$SPARKLE_PRIVATE_KEY_PATH" && -f "$GITHUB_RELEASE_PATH" ]] || { echo "Update signing key or GitHub release metadata missing." >&2; exit 1; }
[[ -d "$ROOT/mac/Vendor/Sparkle/Sparkle.framework" ]] || { echo "Run mac/scripts/build-sparkle.sh first." >&2; exit 1; }
xcrun swift "$ROOT/mac/scripts/verify-update-key.swift"

OUT="$ROOT/mac/build/release"
BUILD=${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "BUILD_NUMBER must be a positive integer." >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT/mac"
xcodegen --quiet
xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release \
  -archivePath "$OUT/Appears.xcarchive" -derivedDataPath "$ROOT/mac/build/ReleaseDerivedData" \
  archive -quiet ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS=--timestamp

APP="$OUT/Appears.app"
ditto "$OUT/Appears.xcarchive/Products/Applications/Appears.app" "$APP"
# Sign nested Sparkle helpers inside out; preserve the downloader's strict sandbox.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$@"; }
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP"
if find "$APP" -name '*.safetensors' -print -quit | grep -q .; then
  echo "The lightweight app must not bundle model weights." >&2; exit 1
fi
"$ROOT/mac/scripts/check-no-network.sh" "$APP"

# Check the actual signed entitlements, including Release builds accidentally signed
# for debugging. The engine must have sandbox=true, not merely an entitlement key.
for bundle in "$APP" "$APP/Contents/XPCServices/AppearsEngine.xpc" "$APP/Contents/XPCServices/AppearsDownloader.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"; do
  codesign -d --entitlements - --xml "$bundle" 2>/dev/null > "$OUT/entitlements.plist"
  python3 -I - "$OUT/entitlements.plist" "$bundle" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as f:
    entitlements = plistlib.load(f)
for key in entitlements:
    allowed_download = sys.argv[2].endswith(("AppearsDownloader.xpc", "/Downloader.xpc")) and key == "com.apple.security.network.client" and entitlements[key] is True
    if (key.startswith("com.apple.security.network.") and not allowed_download) or key == "com.apple.security.get-task-allow":
        raise SystemExit(f"Refusing to release {sys.argv[2]} with {key}")
if sys.argv[2].endswith(".xpc") and entitlements.get("com.apple.security.app-sandbox") is not True:
    raise SystemExit("The engine must be sandboxed.")
PY
done
rm "$OUT/entitlements.plist"

notarize() {
  local auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
  # Individual API keys have no issuer. Team API keys require one.
  if [[ -n "${NOTARY_ISSUER:-}" ]]; then auth+=(--issuer "$NOTARY_ISSUER"); fi
  xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json > "$OUT/notarization.json"
  python3 -I - "$OUT/notarization.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    result = json.load(f)
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization failed: {result.get('status')} (submission {result.get('id')})")
PY
  xcrun stapler staple "$2"
  xcrun stapler validate "$2"
}

ditto -c -k --keepParent "$APP" "$OUT/Appears.zip"
notarize "$OUT/Appears.zip" "$APP"
spctl --assess --type execute --verbose "$APP"

STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Appears.app"
ln -s /Applications "$STAGING/Applications"
# Every version uses the same filename, under its own immutable R2 prefix.
hdiutil create -quiet -volname Appears -srcfolder "$STAGING" -ov -format ULFO "$OUT/Appears.dmg"
codesign --sign "$DEVELOPER_ID" --timestamp "$OUT/Appears.dmg"
notarize "$OUT/Appears.dmg" "$OUT/Appears.dmg"
spctl --assess --type open --context context:primary-signature --verbose "$OUT/Appears.dmg"
cd "$OUT"
shasum -a 256 Appears.dmg > Appears.dmg.sha256
python3 -I "$ROOT/mac/scripts/make-appcast.py" "$VERSION" "$GITHUB_RELEASE_PATH" \
  "$APP/Contents/Info.plist" "$OUT/Appears.dmg" "$ROOT/mac/Vendor/Sparkle/bin/sign_update" \
  "$SPARKLE_PRIVATE_KEY_PATH" "$OUT/appcast.xml"
"$ROOT/mac/Vendor/Sparkle/bin/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" "$OUT/appcast.xml" >/dev/null 2>&1 || {
  echo "Could not sign the update feed." >&2; exit 1;
}
"$ROOT/mac/Vendor/Sparkle/bin/sign_update" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" "$OUT/appcast.xml" >/dev/null 2>&1 || {
  echo "Update feed signature did not verify." >&2; exit 1;
}
shasum -a 256 appcast.xml > appcast.xml.sha256
echo "Built, signed and notarized: $OUT/Appears.dmg"
