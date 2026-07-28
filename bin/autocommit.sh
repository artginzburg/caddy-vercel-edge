#!/usr/bin/env bash
# Auto-commit any change to the managed config and push it to GitHub.
# Driven by infra-autocommit.timer. No-ops on a clean tree. Never fails the unit
# just because the push didn't go through (e.g. before the deploy key exists on
# a fresh box) — the commit is still made locally and pushed next time.
#
# There may be two repositories in play, and they are mirrored on different
# terms:
#
#   etc/caddy/sites/ — your site configuration, the part that actually changes
#     day to day. If it is a git repository of its own (a plain clone, or a
#     submodule, of a private repo), it is mirrored automatically.
#
#   this repo — the machinery. NOT mirrored unless you opt in with
#     AUTOCOMMIT_SELF=1 in /etc/caddy/edge.env. A stock checkout's `origin` is
#     the upstream public repo, and a box that auto-pushes there would be a nasty
#     surprise. Set it to 1 once `origin` points somewhere you own — then the box
#     mirrors itself completely, machinery included, as a single-repo install
#     does.
#
# Each repo is pushed to whatever branch it has checked out, so a sites repo
# parked on `split` pushes to `split`.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -r /etc/caddy/edge.env ] && . /etc/caddy/edge.env
: "${AUTOCOMMIT_SELF:=0}"

mirror() {  # mirror <repo-dir> <label>
  ( set -uo pipefail
    cd "$1" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    [ -n "$(git status --porcelain)" ] || exit 0

    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$branch" = "HEAD" ]; then
      # Detached — `git submodule update` leaves submodules this way. A commit
      # here would be stranded on no branch, so refuse and say why.
      echo "infra-autocommit: $2 has changes but is on a detached HEAD;" \
           "check out a branch there (see README) — skipping" >&2
      exit 0
    fi

    git add -A
    git commit -q -m "auto: $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 0
    git push -q origin "HEAD:$branch" 2>/dev/null \
      || echo "infra-autocommit: $2 committed locally, push skipped (no remote/key yet)"
  )
}

# 1. Site configuration — mirrored whenever it is a repo of its own.
#    Inside a submodule `.git` is a file, not a directory, so test -e covers both.
[ -e "$REPO/etc/caddy/sites/.git" ] && mirror "$REPO/etc/caddy/sites" "sites"

# 2. The machinery — opt-in, see the header.
[ "$AUTOCOMMIT_SELF" = "1" ] && mirror "$REPO" "machinery"

exit 0
