#!/bin/bash
# Auto backup: commit + push any changes. Secrets are kept out by .gitignore plus the guard below.
export PATH=/opt/homebrew/bin:/usr/bin:/bin
cd /Users/johnhesch/Projects/mac-email-app || exit 1
[ -z "$(git status --porcelain)" ] && { echo "$(date): nothing to commit"; exit 0; }
# Back up the branch that is checked out; never commit on a detached checkout (the commit would belong to no branch)
branch=$(git symbolic-ref --short -q HEAD) || { echo "$(date): SKIPPED, no branch checked out"; exit 1; }
git add -A
if git diff --cached --name-only | grep -Eiq '(\.pw$|\.env|\.p12$|\.pem$|\.keychain|client_secret|token|credential)'; then
  git reset -q; echo "$(date): REFUSED, secret-like file staged"; exit 1
fi
git commit -qm "auto backup: $(date '+%Y-%m-%d %H:%M:%S')" && git push -q origin "$branch" && echo "$(date): pushed $branch"
