#!/bin/bash
# One-shot install: Python daemon + model, app build, launch-at-login agent.
# Safe to re-run; it rebuilds and reloads in place.
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
LABEL="com.mickrudolph.scribey"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/Scribey.app"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Scribey needs an Apple Silicon Mac (the model runs on MLX)." >&2
    exit 1
fi
if ! command -v swift >/dev/null; then
    echo "swift not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null; then
    echo "ffmpeg not found. Install it with: brew install ffmpeg" >&2
    exit 1
fi

[ -x daemon/.venv/bin/python3 ] || bash daemon/setup_venv.sh
bash build-release.sh

pkill -x Scribey 2>/dev/null || true
rm -rf "$APP"
mv Scribey.app "$APP"
# The app lives in /Applications but the daemon stays here; this is how it finds daemon/.
defaults write "$LABEL" checkoutPath "$ROOT"

# Generated rather than committed so it matches this machine's paths.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/Scribey</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/scribey.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/scribey.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

echo
echo "Scribey is running (mic icon in the menu bar) and starts at login."
echo "Grant Accessibility and Microphone access when macOS asks; the hotkey starts"
echo "working as soon as Accessibility is on. After a reinstall, remove Scribey from"
echo "Privacy & Security -> Accessibility with - and add /Applications/Scribey.app again."
