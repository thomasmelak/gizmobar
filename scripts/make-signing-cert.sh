#!/usr/bin/env bash
# Creates the self-signed certificate the Release workflow signs Gizmobar with, and stores it
# as the SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD repository secrets. Run it once.
#
# A stable certificate keeps macOS privacy grants (audio capture, automation) across updates.
# It is not trusted by Gatekeeper; Homebrew and install.sh clear the quarantine flag instead.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-thomasmelak/gizmobar}"
NAME="${CERT_NAME:-Gizmobar Release Signing}"
DAYS="${DAYS:-3650}"
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

openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -config "$OUT/cert.cnf" \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" 2>/dev/null

# OpenSSL 3 needs -legacy for a .p12 the macOS keychain can import; LibreSSL doesn't have it.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
    -name "$NAME" -out "$OUT/cert.p12" -passout "pass:$PASSWORD"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    base64 < "$OUT/cert.p12" | tr -d '\n' | gh secret set SIGNING_CERT_P12 --repo "$REPO"
    printf '%s' "$PASSWORD" | gh secret set SIGNING_CERT_PASSWORD --repo "$REPO"
    echo "Stored SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD on $REPO."
else
    KEEP="$HOME/Desktop/gizmobar-signing"
    mkdir -p "$KEEP"
    base64 < "$OUT/cert.p12" | tr -d '\n' > "$KEEP/SIGNING_CERT_P12.txt"
    printf '%s' "$PASSWORD" > "$KEEP/SIGNING_CERT_PASSWORD.txt"
    echo "gh isn't signed in. Add these two files as repository secrets of the same names at"
    echo "  https://github.com/$REPO/settings/secrets/actions"
    echo "then delete $KEEP."
fi
