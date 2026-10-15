#!/bin/zsh
# The manual is written in one place, the A4 vault. This copies it into the repo (Manual/mail-manual.md) so the cloud
# build can bundle it inside the app. Run it, commit Manual/mail-manual.md, push.   --check: copies nothing, exits 1 if the copies differ.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${MANUAL_SOURCE:-$HOME/Projects/A4/03 WiP/2026-10-09-mac-email-app/mail-manual.md}"
DST="Manual/mail-manual.md"
[ -f "$SRC" ] || { echo "Manual source not found: $SRC"; exit 2; }
if [ "${1:-}" = "--check" ]; then
  cmp -s "$SRC" "$DST" && { echo "Manual copy is current."; exit 0; }
  echo "The repo copy of the manual differs from the vault. Run scripts/sync-manual.sh, commit Manual/mail-manual.md and push."; exit 1
fi
cp "$SRC" "$DST"
echo "Copied the manual to $DST"
