#!/usr/bin/env bash
# Auto-commit any change under the repo and push to GitHub.
# Driven by infra-autocommit.timer. No-ops on a clean tree. Never fails the unit
# just because the push didn't go through (e.g. before the deploy key exists on
# a fresh box) — the commit is still made locally and pushed next time.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 0
[ -n "$(git status --porcelain)" ] || exit 0
git add -A
git commit -q -m "auto: $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 0
git push -q origin HEAD:main 2>/dev/null \
  || echo "infra-autocommit: committed locally, push skipped (no remote/key yet)"
