#!/bin/zsh
# Installs the latest successful cloud build: download, sign with the local identity (scripts/sign.sh, the same
# signing as build.sh), install to /Applications only if Mail is not running. Run as:
#   taskpolicy -b nice -n 19 scripts/install-cloud-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="Audrey Mail"
APP="build/$NAME.app"
DEST="/Applications/$NAME.app"
RUN=$(gh run list --workflow build.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')
[ -n "$RUN" ] || { echo "No successful cloud build yet."; exit 1; }
rm -rf build/cloud "$APP"; mkdir -p build/cloud
gh run download "$RUN" -n AudreyMail-app -D build/cloud
ditto -x -k build/cloud/AudreyMail.zip build
rm -rf build/cloud
scripts/sync-manual.sh --check "$APP/Contents/Resources/mail-manual.md" || [ $? -eq 2 ]   # never install an app whose built-in help differs from the vault manual
scripts/sign.sh "$APP"
codesign --verify --verbose=2 "$APP"
echo "Signed $APP (cloud run $RUN)"
if pgrep -x MailApp >/dev/null; then echo "Mail is running: NOT installed. The signed app is ready at $PWD/$APP; install when Mail is closed."; exit 0; fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/MailShare.appex" 2>/dev/null || true
pluginkit -e use -i com.johnhesch.mailapp.share 2>/dev/null || true
rm -rf "$APP"
echo "Installed $DEST"
