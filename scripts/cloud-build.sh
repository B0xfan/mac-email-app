#!/bin/zsh
# Starts a cloud build on GitHub (workflow build.yml) and prints the run URL. Does not wait. Light: no compiling here.
# --core: only the quick check of the shared mail logic (MailCore), minutes instead of the full run.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/sync-manual.sh --check || [ $? -eq 2 ]   # the bundled manual must be the vault's; a missing vault file (exit 2, another Mac) is not a reason to stop
CORE=false; [ "${1:-}" = "--core" ] && { CORE=true; shift; }
BRANCH="${1:-$(git branch --show-current)}"
gh workflow run build.yml --ref "$BRANCH" -f core_only=$CORE
sleep 4   # the new run needs a moment to appear in the list
gh run list --workflow build.yml --branch "$BRANCH" --limit 1 --json url -q '.[0].url'
