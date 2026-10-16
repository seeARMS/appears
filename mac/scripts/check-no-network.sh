#!/bin/bash
# Fails if the menu bar app's binary imports any networking API. The app can't be sandboxed
# (Accessibility isn't allowed there) and can't sandbox itself, so this is the guard that it
# stays free of networking code. The engine has no network entitlements. The separate
# downloader gets network.client only, and no access to user files.
#
#   mac/scripts/check-no-network.sh path/to/Appears.app
set -euo pipefail
APP=${1:?usage: check-no-network.sh Appears.app}
BINS=("$APP/Contents/MacOS/Appears")
[[ -f "${BINS[0]}" ]] || { echo "App binary not found." >&2; exit 1; }
if [[ -f "$APP/Contents/MacOS/Appears.debug.dylib" ]]; then BINS+=("$APP/Contents/MacOS/Appears.debug.dylib"); fi
status=0

# Undefined (imported) symbols that open connections or resolve hosts.
PATTERN='^_(socket|connect|getaddrinfo|gethostbyname|nw_[a-z_]+|CFSocket[A-Za-z]*|CFStreamCreatePairWithSocket[A-Za-z]*|CFReadStreamCreateWithFTPURL|SecureTransport|SSLCreateContext)$|NSURLSession|URLSession|NSURLConnection|WKWebView'
found=$(for b in "${BINS[@]}"; do nm -u "$b" 2>/dev/null; done | sed 's/^[[:space:]]*//' | grep -E "$PATTERN" | sort -u || true)
if [ -n "$found" ]; then
  echo "Networking symbols imported by the app:"; echo "$found"; status=1
fi

# Frameworks that exist only to talk to the network.
linked=$(for b in "${BINS[@]}"; do otool -L "$b"; done | grep -E "/Network.framework|/CFNetwork.framework|/WebKit.framework" || true)
if [ -n "$linked" ]; then
  echo "Networking frameworks linked directly:"; echo "$linked"; status=1
fi

ENGINE="$APP/Contents/XPCServices/AppearsEngine.xpc"
DOWNLOADER="$APP/Contents/XPCServices/AppearsDownloader.xpc"
python3 -I - "$ENGINE" "$DOWNLOADER" <<'PY'
import plistlib
import subprocess
import sys
for index, path in enumerate(sys.argv[1:]):
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    entitlements = plistlib.loads(result.stdout)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise SystemExit(f"Not sandboxed: {path}")
    network = {k: v for k, v in entitlements.items() if k.startswith("com.apple.security.network.")}
    if index == 0 and network:
        raise SystemExit("The engine must never have network entitlements.")
    if index == 1:
        if network != {"com.apple.security.network.client": True}:
            raise SystemExit("The downloader must have network.client only.")
        allowed = {"com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.get-task-allow"}
        if any(k.startswith("com.apple.security.") and k not in allowed for k in entitlements):
            raise SystemExit("The downloader must not get file, automation or other user-data access.")
PY

[ $status -eq 0 ] && echo "OK: no networking in the app; engine has no network; downloader is sandboxed without user-file access."
exit $status
