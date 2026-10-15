#!/bin/zsh
# The manual is written in one place, the A4 vault. This copies it into the repo (Manual/mail-manual.md) so the cloud
# build can bundle it inside the app. Run it, commit Manual/mail-manual.md, push.   --check: copies nothing, exits 1 if the copies differ.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${MANUAL_SOURCE:-$HOME/Projects/A4/03 WiP/2026-10-09-mac-email-app/mail-manual.md}"
DST="Manual/mail-manual.md"
[ -f "$SRC" ] || { echo "Manual source not found: $SRC"; exit 2; }
if [ "${1:-}" = "--check" ]; then
  WITH="${2:-$DST}"   # --check [file]: compare the vault file with the repo copy, or with another copy (the one inside a built app)
  [ -f "$WITH" ] || { echo "Manual copy not found: $WITH"; exit 3; }   # 3, not 2: a missing copy is a failure, only a missing vault file is let through
  cmp -s "$SRC" "$WITH" && { echo "Manual copy is current."; exit 0; }
  if [ -n "${2:-}" ]; then echo "The manual inside $WITH differs from the vault. That build is out of date: run scripts/sync-manual.sh, commit Manual/mail-manual.md, push, start a new cloud build (scripts/cloud-build.sh) and install that one."
  else echo "The repo copy of the manual differs from the vault. Run scripts/sync-manual.sh, then commit Manual/mail-manual.md and push."; fi
  exit 1
fi
cp "$SRC" "$DST"
echo "Copied the manual to $DST"
