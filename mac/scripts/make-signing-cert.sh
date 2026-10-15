#!/bin/sh
# Makes a self-signed code-signing certificate for local builds of Appears, so macOS keeps
# Accessibility and Full Disk Access across rebuilds (it ties them to the signature, and an
# ad-hoc signature changes on every build). Run it yourself; it changes your login keychain:
#
#   1. creates a key and a 10-year certificate named "Appears Dev" (Code Signing only),
#   2. imports them into your login keychain, letting codesign use the key,
#   3. trusts the certificate for code signing only (macOS asks for your password),
#   4. writes mac/Config/Local.xcconfig so Xcode signs with it.
#
#   mac/scripts/make-signing-cert.sh            # do it
#   mac/scripts/make-signing-cert.sh --dry-run  # everything except the keychain
#
# To undo: delete "Appears Dev" in Keychain Access (both the certificate and its private key)
# and remove mac/Config/Local.xcconfig.
set -eu

NAME="Appears Dev"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl  # macOS's LibreSSL writes a PKCS#12 that `security import` accepts.

if [ $DRY_RUN -eq 0 ] && security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in your login keychain; writing Local.xcconfig only."
else
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  # A throwaway password: the file exists only for the import and is deleted on exit.
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:appears-import
  "$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate

  if [ $DRY_RUN -eq 1 ]; then
    echo "Dry run: made the certificate and the import file; didn't touch the keychain or Local.xcconfig."
    exit 0
  fi

  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P appears-import -T /usr/bin/codesign
  echo "Trusting \"$NAME\" for code signing only. macOS will ask for your password."
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
fi

cat > "$ROOT/mac/Config/Local.xcconfig" <<EOF
// Written by mac/scripts/make-signing-cert.sh. Git-ignored.
CODE_SIGN_IDENTITY = $NAME
EOF

echo
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$NAME" || {
  echo "\"$NAME\" isn't listed as a valid code-signing identity. Check it in Keychain Access."
  exit 1
}
echo
echo "Done. Rebuild and reinstall Appears, then grant Accessibility and Full Disk Access once more;"
echo "after that they'll survive rebuilds."
