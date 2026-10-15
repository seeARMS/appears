#!/bin/sh
# Fails if the menu bar app's binary imports any networking API. The app can't be sandboxed
# (Accessibility isn't allowed there) and can't sandbox itself, so this is the guard that it
# stays free of networking code. The engine is checked by its entitlements: no network.*.
#
#   mac/scripts/check-no-network.sh path/to/Appears.app
set -eu
APP=${1:?usage: check-no-network.sh Appears.app}
BIN="$APP/Contents/MacOS/Appears"
[ -f "$APP/Contents/MacOS/Appears.debug.dylib" ] && BIN="$BIN $APP/Contents/MacOS/Appears.debug.dylib"
status=0

# Undefined (imported) symbols that open connections or resolve hosts.
PATTERN='^_(socket|connect|getaddrinfo|gethostbyname|nw_[a-z_]+|CFSocket[A-Za-z]*|CFStreamCreatePairWithSocket[A-Za-z]*|CFReadStreamCreateWithFTPURL|SecureTransport|SSLCreateContext)$|NSURLSession|URLSession|NSURLConnection|WKWebView'
found=$(for b in $BIN; do nm -u "$b" 2>/dev/null; done | grep -E "$PATTERN" | sort -u || true)
if [ -n "$found" ]; then
  echo "Networking symbols imported by the app:"; echo "$found"; status=1
fi

# Frameworks that exist only to talk to the network.
linked=$(for b in $BIN; do otool -L "$b"; done | grep -E "/Network.framework|/CFNetwork.framework|/WebKit.framework" || true)
if [ -n "$linked" ]; then
  echo "Networking frameworks linked directly:"; echo "$linked"; status=1
fi

# The engine must never get a network entitlement.
ENGINE="$APP/Contents/XPCServices/AppearsEngine.xpc"
if codesign -d --entitlements - "$ENGINE" 2>/dev/null | grep -q "com.apple.security.network"; then
  echo "The engine has a network entitlement."; status=1
fi
if ! codesign -d --entitlements - "$ENGINE" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "The engine isn't sandboxed."; status=1
fi

[ $status -eq 0 ] && echo "OK: the app imports no networking APIs; the engine is sandboxed without network."
exit $status
