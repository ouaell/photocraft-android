#!/usr/bin/env bash
# setup.sh — one-time repository setup. Pins the upstream PhotoCraft source (read-only submodule)
# at the exact release recorded in UPSTREAM_PIN, then runs both integrity guards.
# Safe to run again. Needs: git, bash, network access to github.com.
set -euo pipefail
cd "$(dirname "$0")"
TAG=$(sed -n 's/^tag=//p' UPSTREAM_PIN | head -1)
COMMIT=$(sed -n 's/^commit=//p' UPSTREAM_PIN | head -1)
[ -n "$TAG" ] && [ -n "$COMMIT" ] || { echo "UPSTREAM_PIN is missing tag= or commit=" >&2; exit 2; }
[ -d .git ] || git init -q
if [ ! -e upstream/.git ]; then
  git submodule add --depth 1 https://github.com/storytold/photocraft.git upstream
fi
git -C upstream fetch -q --depth 1 origin tag "$TAG"
git -C upstream checkout -q "$COMMIT"
# record the pinned commit as the submodule link in this repository (the guard compares against it)
git add -- .gitmodules upstream
bash scripts/guard-upstream.sh
bash scripts/skills-integrity.sh
echo
echo "Setup complete. upstream/ is pinned to $TAG ($COMMIT) and untouched."
echo "Next: git add -A && git commit -m 'Import plan bundle and pin upstream', push to GitHub,"
echo "enable branch protection + CODEOWNERS (see START-HERE.md), then give the agent the first prompt."
