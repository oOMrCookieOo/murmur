#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate so Murmur keeps a stable
# identity across rebuilds.
#
# WHY THIS MATTERS
#   macOS records Accessibility and Input Monitoring grants against an app's
#   code signature. An ad-hoc signature (`codesign -s -`) is different on every
#   build, so after each rebuild macOS sees a stranger: the app still appears
#   ticked in System Settings, but the permission silently does not apply and
#   pasting stops working. A self-signed certificate keeps the signature
#   constant, so you grant permission once.
#
# This needs no Apple Developer account and costs nothing. It is only trusted
# on this Mac, which is all a personal build needs.
#
set -euo pipefail

CERT_NAME="${MURMUR_CERT_NAME:-Murmur Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "==> '$CERT_NAME' already exists. Nothing to do."
    echo "    Rebuild with 'make build' and it will be used automatically."
    exit 0
fi

echo "==> Creating a self-signed code-signing certificate: $CERT_NAME"
echo

# Pinned to the system LibreSSL, NOT whatever `openssl` is first in PATH.
# Homebrew's OpenSSL 3.x defaults to PKCS#12 encryption algorithms that Apple's
# Security framework cannot read, and the import fails with a misleading
# "MAC verification failed ... (wrong password?)".
OPENSSL=/usr/bin/openssl

# A real passphrase rather than an empty one: empty-password PKCS#12 import is
# inconsistent across macOS versions. The file is deleted moments later.
P12_PASS="murmur-local-$$"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

"$OPENSSL" pkcs12 -export \
    -out "$TMP/bundle.p12" \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -passout "pass:$P12_PASS" \
    2>/dev/null

echo "==> Importing into your login keychain."
echo "    macOS will ask for your login password."
echo
security import "$TMP/bundle.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -A

echo
echo "==> Marking the certificate as trusted for code signing."
echo "    macOS will ask for your login password again. This is the step that"
echo "    makes codesign willing to use it."
echo
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "==> Done. '$CERT_NAME' is ready."
    echo
    echo "    Next:"
    echo "      1. make build        (now signs with the stable identity)"
    echo "      2. Remove Murmur from System Settings > Privacy & Security >"
    echo "         Accessibility and Input Monitoring, if it is already listed"
    echo "         under the old ad-hoc identity."
    echo "      3. make run, then grant the permissions once."
else
    echo "==> The certificate was created but codesign cannot see it yet."
    echo "    Open Keychain Access, find '$CERT_NAME', and set"
    echo "    'When using this certificate' to 'Always Trust'."
    exit 1
fi
