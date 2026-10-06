#!/bin/bash
# Stops Scribey and removes what it put outside this folder. The downloaded
# model stays in ~/.cache/huggingface/hub; delete it there to reclaim ~2.5GB.
LABEL="com.mickrudolph.scribey"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
pkill -x Scribey 2>/dev/null || true
rm -rf /Applications/Scribey.app
rm -rf "$HOME/Library/Application Support/Scribey"
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
tccutil reset Microphone "$LABEL" >/dev/null 2>&1 || true
defaults delete "$LABEL" 2>/dev/null || true

echo "Scribey uninstalled. Delete this folder to finish."
