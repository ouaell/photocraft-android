#!/usr/bin/env bash
# setup-android-cli.sh — the ONLY reviewed installer in this repository.
# Installs the official Android CLI (stable 1.0) exactly as documented at
# https://developer.android.com/tools/agents/android-cli/download
# (Linux x86_64, local/user install, curl | bash). Approved once by the user
# (2026-10-20, START-HERE.md "قراراتك المطلوبة").
#
# Rules (AGENTS.md R17): this script runs ONLY inside GitHub Actions; never
# ad hoc, never locally, and it installs nothing else.
set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "setup-android-cli.sh: REFUSED (runs only in GitHub Actions — AGENTS.md R17)" >&2
  exit 2
fi

curl -fsSL https://dl.google.com/android/cli/latest/linux_x86_64/install.sh | bash

if ! command -v android >/dev/null 2>&1; then
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    if [ -x "$d/android" ]; then export PATH="$d:$PATH"; echo "$d" >> "${GITHUB_PATH:-/dev/null}"; break; fi
  done
fi

android --version
