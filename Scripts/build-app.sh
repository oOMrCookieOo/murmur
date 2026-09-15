#!/usr/bin/env bash
#
# Builds Murmur.app with swiftc, no Xcode required.
#
# Xcode is the normal way to build this project; this script exists so the app
# can be built and run on a machine that only has Command Line Tools.
#
set -euo pipefail

APP_NAME="Murmur"
BUNDLE_ID="com.mrcookie.Murmur"
DEPLOYMENT_TARGET="27.0"
CERT_NAME="${MURMUR_CERT_NAME:-Murmur Local Signing}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

CONFIG="${CONFIG:-release}"
if [[ "$CONFIG" == "debug" ]]; then
    OPT_FLAGS=(-Onone -g)
else
    OPT_FLAGS=(-O -whole-module-optimization)
fi

echo "==> Building $APP_NAME ($CONFIG, $ARCH, macOS $DEPLOYMENT_TARGET)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

mapfile -t SOURCES < <(find "$ROOT/Murmur" -name '*.swift' | sort)
echo "    ${#SOURCES[@]} source files"

swiftc \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    -module-name "$APP_NAME" \
    -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
    -sdk "$SDK" \
    -swift-version 6 \
    "${OPT_FLAGS[@]}" \
    "${SOURCES[@]}"

cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Code signing -----------------------------------------------------------
#
# The signature is the app's identity as far as TCC is concerned. An ad-hoc
# signature changes every build, so macOS treats each build as a new app and
# the Accessibility grant stops applying. A self-signed certificate keeps the
# identity stable; see Scripts/make-signing-cert.sh.
#
if [[ -n "${MURMUR_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$MURMUR_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    IDENTITY="$CERT_NAME"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/')"
else
    IDENTITY="-"
fi

if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Signing ad-hoc (no stable identity found)"
    echo "    WARNING: macOS may forget Accessibility permission after each rebuild."
    echo "    Run 'make sign-cert' once to fix this permanently."
else
    echo "==> Signing as: $IDENTITY"
fi

codesign --force \
    --sign "$IDENTITY" \
    --entitlements "$ROOT/Config/Murmur.entitlements" \
    --options runtime \
    --timestamp=none \
    "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/    /' || true
