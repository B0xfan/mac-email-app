#!/bin/zsh
# Puts Sparkle.framework (self-update) into an assembled app, with English wording that matches Audrey Mail.
# Usage: scripts/embed-sparkle.sh "<path to .app>"   (run after `swift build -c release`, before signing)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"
FW=$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)
[ -n "$FW" ] || { echo "Sparkle.framework not found under .build/artifacts: build first"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$FW" "$APP/Contents/Frameworks/Sparkle.framework"   # ditto keeps the symlinks the signature depends on
# Audrey Mail is not sandboxed, so Sparkle's helper services are not needed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
python3 -I scripts/patch-sparkle-strings.py "$APP/Contents/Frameworks/Sparkle.framework"
