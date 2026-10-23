#!/bin/zsh
# The one local step for the iPhone app: sign the release build with John's free Apple development team and install it on his paired phone.
# Runs capped (scripts/safe: background priority, one job, 20 minute limit). Usage: scripts/install-iphone.sh <Google iOS client prefix>
# The prefix is the first part of the Google iOS client id (before ".apps.googleusercontent.com"); it is not a secret.
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX="${1:?give the Google iOS client prefix}"
DD="${TMPDIR:-/tmp}/audreymail-iphone-dd"
scripts/safe exec 1200 -- xcodebuild build -project iPhone/AudreyMail.xcodeproj -scheme AudreyMail -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates -jobs 1 GOOGLE_IOS_CLIENT_PREFIX="$PREFIX"
APP="$DD/Build/Products/Release-iphoneos/AudreyMail.app"
J="$(mktemp)"; xcrun devicectl list devices --json-output "$J" >/dev/null
DEVICE="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["result"]["devices"]; print(d[0]["identifier"])' "$J")"; rm -f "$J"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed. Open Audrey Mail on the phone."
