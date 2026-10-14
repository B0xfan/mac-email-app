#!/bin/zsh
# Signs a built Audrey Mail.app with the local identity. Usage: scripts/sign.sh <path to .app>
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"
EXT="$APP/Contents/PlugIns/MailShare.appex"
# Stable signing: a local self-signed identity in its own keychain, so the app keeps the same
# identity across rebuilds and the Keychain "Always Allow" grant for the refresh token sticks.
SUPPORT="$HOME/Library/Application Support/Audrey Mail"
SIGNKC="$SUPPORT/signing.keychain-db"
if [ ! -f "$SIGNKC" ]; then echo "Signing keychain missing: $SIGNKC - run scripts/setup-signing.sh"; exit 1; fi
security unlock-keychain -p "$(cat "$SUPPORT/signing.pw")" "$SIGNKC"
codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" -i com.johnhesch.mailapp.share --entitlements ShareExtension/MailShare.entitlements "$EXT"
HELPER="$APP/Contents/MacOS/AudreyMailClaude"
if [ -f "$HELPER" ]; then codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" -i com.johnhesch.mailapp.claude "$HELPER"; fi
codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" -i com.johnhesch.mailapp "$APP"
