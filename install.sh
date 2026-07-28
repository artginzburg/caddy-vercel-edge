#!/usr/bin/env bash
# install.sh — bring a box to the desired reverse-proxy state from this repo.
#
# Idempotent: safe to re-run. Run as root from the repo checkout. This is both
# the day-one bootstrap (fresh VPS) and the "apply whatever changed" command.
#
#   git clone https://github.com/artginzburg/caddy-vercel-edge.git /opt/caddy-vercel-edge
#   sudo /opt/caddy-vercel-edge/install.sh
#
# What it does: installs Caddy if missing, symlinks every managed file from this
# repo into its system location (so editing the live file == editing the repo),
# then validates and (re)starts the services. See README.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
echo "==> repo: $REPO"

# 1. Caddy (official apt repo) ------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
  echo "==> installing Caddy"
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
else
  echo "==> Caddy present: $(caddy version)"
fi

# 1b. DNS provider module (GeoDNS sites) --------------------------------------
# Sites imported through (vercel-geo) get certificates via DNS-01, which needs
# the Gcore provider module compiled into Caddy. It is not on caddyserver.com's
# build server, so the binary has to be built with xcaddy. dpkg-divert keeps the
# apt package from clobbering the custom binary on upgrades — the flip side is
# that Caddy version bumps now mean re-running this build (delete the divert to
# go back to stock). Skipped entirely until a site actually uses vercel-geo.
if grep -qs 'vercel-geo' "$REPO"/etc/caddy/sites/*.caddy 2>/dev/null \
   && ! caddy list-modules 2>/dev/null | grep -q 'dns.providers.gcore'; then
  echo "==> vercel-geo in use: building Caddy with the gcore DNS module"
  # Distro Go is usually too old for current Caddy; keep our own in /usr/local/go.
  GO_VER="$(curl -sfL 'https://go.dev/VERSION?m=text' | head -1)"
  ARCH="$(dpkg --print-architecture)"  # amd64 / arm64
  if [ ! -x /usr/local/go/bin/go ] || [ "$(/usr/local/go/bin/go version | awk '{print $3}')" != "$GO_VER" ]; then
    echo "    fetching $GO_VER ($ARCH)"
    rm -rf /usr/local/go
    curl -sfL "https://go.dev/dl/${GO_VER}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xzf -
  fi
  export PATH="/usr/local/go/bin:$PATH"
  CADDY_VER="$(caddy version | awk '{print $1}')"
  GOBIN=/usr/local/bin go install "github.com/caddyserver/xcaddy/cmd/xcaddy@latest"
  xcaddy build "$CADDY_VER" --with github.com/caddy-dns/gcore --output /tmp/caddy-gcore
  /tmp/caddy-gcore list-modules | grep -q 'dns.providers.gcore'  # refuse a bad build
  dpkg-divert --list caddy | grep -q /usr/bin/caddy \
    || dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
  install -m 0755 /tmp/caddy-gcore /usr/bin/caddy
  echo "    now: $(caddy version) + gcore (stock binary kept as /usr/bin/caddy.default)"
fi

# 1c. sqlite3 CLI — operator convenience for inspecting the stats DB by hand.
#     (caddy-stats itself uses Python's built-in sqlite3; this is just for the
#     manual queries documented in the README.)
command -v sqlite3 >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y sqlite3; }

# 2. Directories & ownership --------------------------------------------------
install -d -o caddy -g caddy -m 0755 /var/log/caddy
install -d -m 0755 /var/lib/caddy-stats

# 3. Symlink every managed file into place ------------------------------------
link() {  # link <repo-relative-src> <system-dest>
  local src="$REPO/$1" dest="$2"
  install -d "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
  printf '    %-52s -> %s\n' "$dest" "$src"
}
echo "==> linking managed files"
link etc/caddy/Caddyfile                              /etc/caddy/Caddyfile
link usr/local/bin/caddy-stats                        /usr/local/bin/caddy-stats
link etc/systemd/system/caddy-stats-rollup.service    /etc/systemd/system/caddy-stats-rollup.service
link etc/systemd/system/caddy-stats-rollup.timer      /etc/systemd/system/caddy-stats-rollup.timer
link etc/systemd/system/infra-autocommit.service      /etc/systemd/system/infra-autocommit.service
link etc/systemd/system/infra-autocommit.timer        /etc/systemd/system/infra-autocommit.timer
link etc/systemd/system/caddy.service.d/override.conf /etc/systemd/system/caddy.service.d/override.conf
ln -sfn "$REPO/README.md" /root/README.md
chmod +x "$REPO/usr/local/bin/caddy-stats" "$REPO/bin/autocommit.sh"

# sites/ holds your per-project Caddy config, typically a clone of a private repo.
# Symlinking it next to /etc/caddy/Caddyfile makes `import sites/*.caddy` resolve
# no matter which path Caddy reads the config through.
mkdir -p "$REPO/etc/caddy/sites"   # nothing is tracked in it, so it may not exist yet
ln -sfn "$REPO/etc/caddy/sites" /etc/caddy/sites
printf '    %-52s -> %s\n' /etc/caddy/sites "$REPO/etc/caddy/sites"

# 3b. Edge marker ---------------------------------------------------------------
# The (edge) snippet stamps proxied requests with X-Edge-Proxy so the app can tell
# "came through the proxy" from "someone hit the origin host directly". The value
# is a per-box secret: it never enters git, and it is generated once here.
if [ ! -s /etc/caddy/edge.env ]; then
  echo "==> generating edge marker -> /etc/caddy/edge.env"
  printf 'EDGE_PROXY_MARKER=%s\n' "$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
    > /etc/caddy/edge.env
  chmod 0640 /etc/caddy/edge.env
  chown root:caddy /etc/caddy/edge.env
else
  echo "==> edge marker present: /etc/caddy/edge.env"
fi

# 4. Validate & apply ---------------------------------------------------------
echo "==> validating Caddyfile"
caddy validate --config /etc/caddy/Caddyfile

echo "==> reloading systemd & (re)starting services"

# Drop stale enablement symlinks first. systemd points timers.target.wants/ at
# the unit's *resolved* path — i.e. into whatever checkout was current when the
# timer was enabled — so after moving the repo they still aim at the old one.
# `systemctl reenable` looks like the fix and is not: it calls disable, which
# deletes the unit symlink in /etc/systemd/system that we just created and leaves
# the unit not-found. Removing only the wants/ link is what we actually want.
for t in caddy-stats-rollup infra-autocommit; do
  rm -f "/etc/systemd/system/timers.target.wants/$t.timer"
done
systemctl daemon-reload
systemctl enable --now caddy

# Caddy resolves {env.*} from its own process environment, and a reload does NOT
# re-read EnvironmentFile. Any variable that was added to edge.env after the
# process started (the edge marker on a fresh box, GCORE_API_TOKEN when a geo
# site is added later) therefore needs a real restart: with a stale environment
# the marker goes out empty (the app reads that as a direct visit and the
# origin->apex redirect turns into a loop) and DNS-01 fails with a 401. Reload
# only when every variable named in edge.env is already in the process.
pid="$(systemctl show -p MainPID --value caddy 2>/dev/null || echo 0)"
if [ "${pid:-0}" -gt 0 ] && [ -r "/proc/$pid/environ" ] \
   && ! comm -23 <(grep -o '^[A-Za-z_][A-Za-z0-9_]*' /etc/caddy/edge.env | sort -u) \
                 <(tr '\0' '\n' < "/proc/$pid/environ" | cut -d= -f1 | sort -u) | grep -q .; then
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
else
  echo "    edge.env has variables Caddy's process hasn't loaded — restarting, not reloading"
  systemctl restart caddy
fi

systemctl enable --now caddy-stats-rollup.timer infra-autocommit.timer

echo "==> done. caddy=$(systemctl is-active caddy)  rollup-timer=$(systemctl is-active caddy-stats-rollup.timer)  autocommit-timer=$(systemctl is-active infra-autocommit.timer)"
echo "    If this is a fresh box, set up push for auto-commit — see README.md > Auto-sync."
