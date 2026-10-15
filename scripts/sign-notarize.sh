#!/bin/zsh
# Runs on the GitHub build machine only (needs the Developer ID secrets in the environment; never run on John's Mac).
# Signs with Developer ID + hardened runtime, notarizes with Apple, staples, and writes AudreyMail-notarized.zip.
# Usage: scripts/sign-notarize.sh "<path to .app>"
# Needs: DEVID_P12_BASE64, DEVID_P12_PASSWORD, ASC_KEY_P8_BASE64, ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail
[ -n "${CI:-}" ] || { echo "Refusing to run outside CI (it rewrites the keychain list)"; exit 1; }
cd "$(dirname "$0")/.."
APP="$1"
EXT="$APP/Contents/PlugIns/MailShare.appex"
HELPER="$APP/Contents/MacOS/AudreyMailClaude"
T=$(mktemp -d); trap 'security delete-keychain "$T/ci.keychain-db" 2>/dev/null || true; rm -rf "$T"' EXIT
KC="$T/ci.keychain-db"; KCPW=$(uuidgen)
echo "$DEVID_P12_BASE64" | base64 --decode > "$T/id.p12"
echo "$ASC_KEY_P8_BASE64" | base64 --decode > "$T/key.p8"
security create-keychain -p "$KCPW" "$KC"; security set-keychain-settings -lut 3600 "$KC"; security unlock-keychain -p "$KCPW" "$KC"
security import "$T/id.p12" -k "$KC" -P "$DEVID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC"
ID=$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[ -n "$ID" ] || { echo "No Developer ID Application identity in the .p12"; exit 1; }
SIGN=(codesign --force --timestamp --options runtime --keychain "$KC" --sign "$ID")
# Inside out, same identifiers as scripts/sign.sh. No --deep.
"${SIGN[@]}" -i com.johnhesch.mailapp.share --entitlements ShareExtension/MailShare.entitlements "$EXT"
"${SIGN[@]}" -i com.johnhesch.mailapp.claude "$HELPER"
"${SIGN[@]}" -i com.johnhesch.mailapp --entitlements scripts/MailApp.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$T/submit.zip"
xcrun notarytool submit "$T/submit.zip" --key "$T/key.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m | tee "$T/notary.log" || true   # keep going so Apple's log is fetched below
if ! grep -q "status: Accepted" "$T/notary.log"; then
  xcrun notarytool log "$(awk '/id:/ {print $2; exit}' "$T/notary.log")" --key "$T/key.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true   # Apple's reason
  echo "Notarization was not accepted"; exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -v "$APP"
ditto -c -k --keepParent "$APP" AudreyMail-notarized.zip
