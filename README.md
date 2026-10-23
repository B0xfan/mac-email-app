# Audrey Mail

Native Mac email app (Gmail). Builds happen on GitHub, not on John's Mac: `scripts/cloud-build.sh` starts a run of
`.github/workflows/build.yml` (manual trigger only, free minutes are scarce; never add a push trigger, auto-commit.sh pushes
every ~10 minutes), then `taskpolicy -b nice -n 19 scripts/install-cloud-build.sh` downloads the latest good build, signs it
locally and installs it if Mail is closed. Local builds (`scripts/build.sh`, `scripts/safe`) only with John's say-so.

Updates for other people (James): Audrey Mail checks GitHub Releases through Sparkle (Audrey Mail > Check for Updates, Settings > Updates).
After a green cloud build, `scripts/release.sh "what is new"` makes the signed package and checks it (dry run); add `--publish` to release it.
The update signing key is a private file at `~/Library/Application Support/Audrey Mail/update-signing.key` (never in the Keychain, never in the repo; backup in Bitwarden).
If that key is lost, installed copies cannot be updated and must be reinstalled by hand.

Layout: `Sources/MailCore` is the screen-free mail logic (Gmail, sync, stored mail, to-do reading, search, Smart-tab sorting, block rules) shared with the
iPhone app; `Sources/MailApp` is the Mac app and uses it. Anything MailCore exposes is `public`; keep Mac-only code (AppKit, Keychain, the home folder) out of it.
