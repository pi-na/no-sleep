#!/bin/bash
# Prints the SHA-1 of a stable local code-signing identity, creating it on first use.
#
# Why: ad-hoc signatures change with every build, and macOS ties Login Items (SMAppService)
# to the code signature — so each update looked like a brand-new app ("Login Item Added" again,
# "Open at login" showing off). A self-signed certificate keeps the designated requirement stable.
#
# The identity lives in its own keychain outside the repo (never commit the private key):
#   ~/Library/Application Support/NoSleep Dev/signing.keychain-db
# Output line 1: identity hash, line 2: keychain path.
set -euo pipefail

NAME="NoSleep Local Signing"
DIR="$HOME/Library/Application Support/NoSleep Dev"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD_FILE="$DIR/keychain-password"
OPENSSL=/usr/bin/openssl

if [ ! -f "$KEYCHAIN" ]; then
  mkdir -p "$DIR" && chmod 700 "$DIR"
  "$OPENSSL" rand -hex 24 > "$PASSWORD_FILE" && chmod 600 "$PASSWORD_FILE"
  PASSWORD=$(cat "$PASSWORD_FILE")
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" -extensions ext \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASSWORD"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # never auto-lock
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
# codesign only finds identities in the user's keychain search list: add ours (keeping the rest).
if ! security list-keychains -d user | grep -qF "$KEYCHAIN"; then
  CURRENT=()
  while IFS= read -r line; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
    [ -n "$line" ] && CURRENT+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${CURRENT[@]}" "$KEYCHAIN"
fi
HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')
[ -n "$HASH" ] || { echo "Could not find signing identity" >&2; exit 1; }
echo "$HASH"
echo "$KEYCHAIN"
