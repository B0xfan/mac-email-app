# Audrey Mail

Native Mac email app (Gmail). Builds happen on GitHub, not on John's Mac: `scripts/cloud-build.sh` starts a run of
`.github/workflows/build.yml` (manual trigger only, free minutes are scarce; never add a push trigger, auto-commit.sh pushes
every ~10 minutes), then `taskpolicy -b nice -n 19 scripts/install-cloud-build.sh` downloads the latest good build, signs it
locally and installs it if Mail is closed. Local builds (`scripts/build.sh`, `scripts/safe`) only with John's say-so.
