#!/usr/bin/env bash
# Creates a self-signed code signing identity in your login keychain for local builds.
# `make app` picks it up, so privacy grants (audio capture, Bluetooth, automation) survive
# rebuilds instead of being asked for again each time. Run it once per Mac.
set -euo pipefail

NAME="${CERT_NAME:-Gizmobar Local Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in your keychain"
  exit 0
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
PASSWORD="$(openssl rand -base64 24)"

cat > "$OUT/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$OUT/cert.cnf" \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" 2>/dev/null
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
    -name "$NAME" -out "$OUT/cert.p12" -passout "pass:$PASSWORD"

# -T lets codesign use the key without a prompt.
security import "$OUT/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -f pkcs12 -T /usr/bin/codesign >/dev/null
echo "added \"$NAME\" to your keychain; make app now signs with it"
