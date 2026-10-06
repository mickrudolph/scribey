#!/bin/bash
cd "$(dirname "$0")"

# Ad-hoc signing ("-") works on any Mac with no certificate. Set
# SCRIBEY_SIGNING_IDENTITY to sign with a real identity instead; macOS keeps
# granted permissions across rebuilds for a real identity, not for ad-hoc.
SIGNING_IDENTITY="${SCRIBEY_SIGNING_IDENTITY:--}"
SCRATCH_PATH="/tmp/scribey-build"
APP="Scribey.app"

# The in-tree .build database intermittently throws "disk I/O error" under
# sandboxed shells; building to a /tmp scratch path avoids it entirely.
swift build -c release --scratch-path "$SCRATCH_PATH"
# Ask SwiftPM for the output dir rather than hardcoding it — the layout
# changed between toolchains (arm64-apple-macosx/release → out/Products/Release).
BINARY="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)/Scribey"
if [ ! -x "$BINARY" ]; then
    echo "Build failed: $BINARY not found" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Scribey"
cp Info.plist "$APP/Contents/Info.plist"

if ! codesign --sign "$SIGNING_IDENTITY" --entitlements entitlements.plist --force --options runtime "$APP"; then
    echo "Codesign failed — app is unsigned and will lack mic entitlement" >&2
    exit 1
fi
echo "Signed and ready: $APP"
