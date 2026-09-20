#!/usr/bin/env bash
# Builds FrostFold.app into dist/. Needs Xcode Command Line Tools only —
# the Metal shaders are compiled at runtime, so no `metal` compiler is required.
#
#   Scripts/bundle.sh              native slice only (fast, for iterating)
#   Scripts/bundle.sh --universal  arm64 + x86_64 (for releases; the Intel
#                                  16" MacBook Pros also have the sensor)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/FrostFold.app"
ARCH_ARGS=()
LABEL="native"

if [ "${1:-}" = "--universal" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    LABEL="universal"
fi

echo "==> Building (release, $LABEL)"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}

BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/FrostFold"
[ -x "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrostFold"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f Resources/FrostFold.icns ]; then
    cp Resources/FrostFold.icns "$APP/Contents/Resources/FrostFold.icns"
else
    echo "    note: no icon yet — run Scripts/icon.sh" >&2
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer the self-signed identity if it exists: it makes the designated
# requirement key on the certificate rather than the code hash, so the Screen
# Recording grant survives source changes and, for anyone you ship to, updates.
# Run Scripts/signing-identity.sh once to create it.
SIGN_KEYCHAIN="$HOME/Library/Keychains/frostfold-signing.keychain-db"
SIGN_IDENTITY="FrostFold Self-Signed"

if [ -f "$SIGN_KEYCHAIN" ] && \
   security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "==> Signing as \"$SIGN_IDENTITY\""
    security unlock-keychain -p frostfold "$SIGN_KEYCHAIN"
    codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
             --timestamp=none "$APP"
else
    echo "==> Signing (ad-hoc — run Scripts/signing-identity.sh to stop macOS"
    echo "    re-asking for Screen Recording after every source change)"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# The bundle is rebuilt in place, so LaunchServices ends up holding a record
# for an inode that no longer exists and `open` quietly resolves to nothing.
# Re-registering the fresh bundle keeps `open -a FrostFold` working.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo
echo "Built $APP  ($(lipo -archs "$APP/Contents/MacOS/FrostFold"), $(du -sh "$APP" | cut -f1))"
echo "Run it with:  open $APP"
