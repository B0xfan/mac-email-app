#!/bin/zsh
# LOCAL build, only with John's say-so: normal builds run on GitHub (scripts/cloud-build.sh, then scripts/install-cloud-build.sh).
# Builds "Audrey Mail.app" from the Swift package, signs it with the local self-signed identity (scripts/sign.sh; no Xcode needed),
# and replaces the installed copy in /Applications so there is never a stale one.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/sync-manual.sh --check || [ $? -eq 2 ]   # the manual that goes into the app must be the vault's (exit 2 = no vault on this Mac)
scripts/safe build -c release   # capped: background priority, 1 job, lock (taken once, also when this script runs under safe exec), timeout. Never a bare swift build.
NAME="Audrey Mail"
APP="build/$NAME.app"
DEST="/Applications/$NAME.app"
rm -rf "$APP" build/Mail.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MailApp" "$APP/Contents/MacOS/MailApp"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Manual/mail-manual.md "$APP/Contents/Resources/mail-manual.md"   # the in-app help (copy of the vault manual, scripts/sync-manual.sh)
# The "Mail" item in other apps' Share menu: a small sandboxed extension that hands what was shared to this app.
EXT="$APP/Contents/PlugIns/MailShare.appex"
mkdir -p "$EXT/Contents/MacOS"
scripts/safe exec 300 -- swiftc -O -parse-as-library -application-extension -target arm64-apple-macos14.0 -framework Cocoa -Xlinker -e -Xlinker _NSExtensionMain ShareExtension/ShareViewController.swift -o "$EXT/Contents/MacOS/MailShare"
cp ShareExtension/Info.plist "$EXT/Contents/Info.plist"
scripts/safe exec 300 -- swiftc -O -target arm64-apple-macos14.0 ClaudeBridge/main.swift Sources/MailApp/MCP.swift -o "$APP/Contents/MacOS/AudreyMailClaude"   # the helper the Claude app starts
scripts/sign.sh "$APP"   # stable local signing, shared with install-cloud-build.sh
codesign --verify --verbose=2 "$APP"
echo "Built $APP"
if [ -n "${NO_INSTALL:-}" ]; then echo "NO_INSTALL set: not installed"; exit 0; fi
# Install: quit a running copy, replace, re-register with Launch Services.
if pgrep -x MailApp >/dev/null; then osascript -e 'tell application id "com.johnhesch.mailapp" to quit' >/dev/null 2>&1 || true; fi   # never starts a closed app
sleep 1
pkill -x MailApp 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
# The Share menu item: register it and switch it on (the same switch as System Settings, Extensions, Sharing).
pluginkit -a "$DEST/Contents/PlugIns/MailShare.appex" 2>/dev/null || true
pluginkit -e use -i com.johnhesch.mailapp.share 2>/dev/null || true
rm -rf "$APP"   # keep only one copy of the app on the Mac
echo "Installed $DEST"
