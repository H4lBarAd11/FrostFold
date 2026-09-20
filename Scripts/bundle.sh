#!/usr/bin/env bash
# Builds Clamshell.app into dist/. Needs Xcode Command Line Tools only —
# the Metal shaders are compiled at runtime, so no `metal` compiler is required.
#
#   Scripts/bundle.sh              native slice only (fast, for iterating)
#   Scripts/bundle.sh --universal  arm64 + x86_64 (for releases; the Intel
#                                  16" MacBook Pros also have the sensor)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Clamshell.app"
ARCH_ARGS=()
LABEL="native"

if [ "${1:-}" = "--universal" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    LABEL="universal"
fi

echo "==> Building (release, $LABEL)"
swift build -c release "${ARCH_ARGS[@]}"

BIN="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)/Clamshell"
[ -x "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clamshell"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# An ad-hoc signature gives the bundle a stable identity, which is what the
# Screen Recording permission is remembered against. Without it macOS forgets
# the grant on every rebuild.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP  ($(lipo -archs "$APP/Contents/MacOS/Clamshell"), $(du -sh "$APP" | cut -f1))"
echo "Run it with:  open $APP"
