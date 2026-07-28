# caddy-vercel-edge

A **Caddy reverse proxy that puts a Russia-resident IP in front of your
Vercel-hosted projects**, so users inside Russia can reach them — while you keep
deploying to Vercel exactly as before.

One cheap VPS fronts any number of projects. `git clone` + `./install.sh` brings
up the whole box; the system files under `/etc` are symlinks into this repo, so
editing the live config *is* editing the repo.

This is a **template repository** — press *Use this template* to get your own
copy, public or private, rather than running off this one directly. Your box
commits back to whatever repo it was cloned from, so it needs to be yours.

---

## Why this exists

Vercel is not blocked in Russia as a platform. What happens is narrower and
messier: Roskomnadzor blocks individual sites on `*.vercel.app`, and because
Vercel serves them from shared anycast addresses, **the IP goes into the registry
and takes every other project on that address with it**. The usual symptom is
that `your-project.vercel.app` opens fine while your own custom domain does not.

Vercel offers no fix. Their own knowledge base answers country-level IP blocking
by suggesting the *visitor* use a VPN.

So you put a box with a Russian IP in front. Your domain resolves to that box,
Caddy terminates TLS there and forwards to an `origin.<domain>` hostname that
still points at Vercel. Russian users reach the box; the box reaches Vercel.

**Before you build anything, try the free fix first.** In several documented
cases only *one* of Vercel's addresses was blocked, and simply moving the A
record to a different one restored access. Check which IP your domain actually
resolves to before assuming you need a proxy.

## When this is the wrong tool

Be honest about the trade — it is a real one:

- **If your audience is not mostly Russian, do not do this.** Every request from
  everywhere is funnelled through one box. A US visitor goes
  US → Russia → Vercel → Russia → US. Measured from a Moscow VPS, the box→Vercel
  leg alone costs ~150 ms TTFB, and the visitor's own leg to Moscow is added on
  top. You are trading a global edge network for a single machine.
- **You lose the real client IP.** Every request reaches Vercel from the proxy,
  so `request.ip`, geolocation and anything keyed on IP see the box. Read
  `X-Forwarded-For` (**first** entry) instead. Do not enable Vercel's WAF rate
  limiting — it would count all your users as one address.
- **Vercel does not recommend it.** It is *not* a Terms of Service violation:
  Vercel detects proxies, shows a "Proxy Detected" banner, publishes a setup
  guide and sells a feature for it. But their firewall loses traffic visibility,
  and support may ask you to disable the proxy before helping.
- **It is one more thing that can go down**, and it does not survive Russian
  mobile-internet shutdowns, which use allowlists this box is not on.
- **Consider just moving.** For a static site, Russian object storage costs
  approximately nothing and removes the whole problem class.

## Requirements

- A VPS **inside Russia**, Ubuntu, root access. The cheapest tier does the job —
  1 vCPU and 1 GB is plenty, and this was written on a box costing 150 ₽/month.
  The spec worth checking is not CPU or RAM but the **traffic allowance**: the
  proxy carries every byte your sites serve, and the cheapest tiers often cap at
  1 TB/month.
- Control over your domain's DNS
- Your Vercel project reachable at `origin.<domain>`

## Install

```bash
git clone https://github.com/artginzburg/caddy-vercel-edge.git /opt/caddy-vercel-edge
sudo /opt/caddy-vercel-edge/install.sh
```

`install.sh` is idempotent — it is both the day-one bootstrap and the
"apply whatever changed" command. It installs Caddy, symlinks every managed file
into place, generates your edge marker, then validates and starts everything.

## Add a project

**1. Vercel** — add `origin.<domain>` to the project, so Caddy has something to
forward to. Add the public `<domain>` too if you need Server Actions.

**2. DNS**

| Record | Value |
|---|---|
| `origin.<domain>` | whatever Vercel shows when you add the domain |
| `<domain>` (apex) | `A` → your box IP |
| `www.<domain>` | `CNAME` → your box (or an apex `A`) |

Lower the TTL to 300 first for a clean cutover.

**3. Caddy** — one file per project in `etc/caddy/sites/`:

```caddyfile
# etc/caddy/sites/example.com.caddy — copy etc/caddy/sites.example.caddy to start
import vercel example.com
```

…or, if the project has no `www`:

```caddyfile
example.com {
    import logged
    import edge https://origin.example.com
}
```

Then:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

The certificate issues on its own once DNS points at the box.

**4. App side** — see below. Deploy this **after** step 3, never before.

## The `X-Edge-Proxy` marker

Someone who opens `origin.example.com` directly should bounce to your real
domain — but that redirect must not catch Caddy's own requests to that same
hostname, or you get a loop.

Caddy can't solve this alone, because `origin.*` points at Vercel and that
traffic never reaches the box. So it is split:

- Caddy stamps every proxied request with **`X-Edge-Proxy`** (the `(edge)`
  snippet). The value is generated per box by `install.sh` into
  `/etc/caddy/edge.env` and is never committed — yours will differ from anyone
  else's, which is the point.
- Your app redirects requests where `host == origin.*` **and the marker is
  missing**. Direct visits redirect; proxied traffic is served as-is.

**Order matters:** ship the Caddy marker *before* deploying the app redirect.
Deploy the redirect first and the proxy's own requests get bounced — that is the
loop.

### The app side, in full

This is the part you actually have to write. In Next.js it is one entry in
`redirects()`; the non-obvious bit is `missing`, which matches when the header is
**absent**:

```js
// next.config.js
module.exports = {
  async redirects() {
    return [
      {
        source: '/:path*',
        has:     [{ type: 'host',   value: 'origin.example.com' }],
        missing: [{ type: 'header', key: 'x-edge-proxy' }],
        destination: 'https://example.com/:path*',
        permanent: false,
      },
    ]
  },
  experimental: {
    serverActions: { allowedOrigins: ['example.com', 'www.example.com'] },
  },
}
```

Header names arrive lowercased — match `x-edge-proxy`, not `X-Edge-Proxy`.

Keep `permanent: false` until you have watched it work. A `308` gets cached hard
by browsers, and if you get the condition backwards, every visitor who saw the
bad redirect keeps following it long after you fix the config.

### Presence or value?

The rule above checks only that the header **exists**. That is enough for what
this is for — telling your own proxy's traffic apart from a direct hit — and it
is what has been running in production. It is *not* a security boundary: the
header name is public, so anyone can set it by hand and reach your origin host
directly.

If you want that closed, check the value too and give the app the same string:

```js
missing: [{ type: 'header', key: 'x-edge-proxy', value: process.env.EDGE_PROXY_MARKER }]
```

…with `EDGE_PROXY_MARKER` set to the contents of `/etc/caddy/edge.env` in your
Vercel project's environment variables. Verify this one before trusting it — the
matching semantics of `missing` with a `value` are easy to get backwards, and the
failure mode is a redirect loop. Presence-only is the field-tested path.

Either way, the real fix for "someone can reach my origin host" is Vercel's
firewall, not a header: restrict `origin.<domain>` to your box's IP.

### Why `allowedOrigins` is in that config too

Server Actions reject when `Origin` ≠ `x-forwarded-host`. Vercel sets
`x-forwarded-host` to `origin.<domain>`, so the browser's real `Origin` — your
apex — no longer matches and every action fails. Whitelisting your public
hostnames, as above, is the fix.

**Astro** — `security.checkOrigin` is the same trap by another name. If POSTs
start returning 403 after you cut over, that is what it is. Astro has no
`redirects()` equivalent for the marker check; do it in middleware, reading
`context.request.headers.get('x-edge-proxy')`.

**Do not rewrite the `Origin` header in Caddy to paper over this.** It works, and
it breaks every library that validates `Origin` — `better-auth` will 403 every
sign-in. Only reach for it when you genuinely cannot change the app's code.

## Per-host traffic & visitor stats

`caddy-stats` reports, per host, bytes served and unique human visitors, with
bots and your app's own server-side fetches filtered out.

```bash
caddy-stats                 # traffic + visitors
caddy-stats --json          # machine-readable
caddy-stats months [HOST]   # month-by-month traffic
caddy-stats visitors [HOST] # month-by-month unique visitors
caddy-stats roll            # finalize completed days (the timer does this daily)
```

All-time totals survive log rotation: completed days are folded into SQLite at
`/var/lib/caddy-stats`, and today is recomputed live and merged, with no double
counting. Run `python3 tests/test_caddy_stats.py` to verify the logic.

## Where your own config lives

`etc/caddy/sites/` holds the only genuinely private thing here — which hostnames
you proxy, and to which origins. It is gitignored out of the box, so a stray
`git push` can never publish it. Everything else is generic by construction.

That split is the point, and it is worth running as two repositories.

### Two repos — recommended

Your **private** repo syncs the thing that is actually yours: the host list, the
origins, the shape of your infrastructure. Your **public** repo — a fork of this
one, or a public copy from the template — holds the machinery, so when you change
how the proxy works you can rip it
apart, reconfigure it, and have that land in the open immediately. Those changes
are the ones you don't mind sharing; the other kind never leaves the private
side. Neither repo has to be sanitised before it moves, because they were never
mixed in the first place.

Clone the private one straight into `etc/caddy/sites`:

```bash
rm -rf etc/caddy/sites
git clone git@github.com:you/your-private-sites.git etc/caddy/sites
```

Everything under `etc/caddy/sites/` is gitignored here, including the nested
`.git`, so the two repositories stay completely unaware of each other. Nothing
about your private repo — not its URL, not its commit ids — is ever recorded on
the public side.

**A submodule would work too, and is worse for this.** `git submodule add` writes
your private repo's URL into `.gitmodules`, and every site edit moves the gitlink
in the parent, so with mirroring on, the public repo collects a commit per change
whose only content is a pointer to a private commit. Use a submodule only if you
actually want the machinery repo to pin which sites revision is deployed.

Whichever you pick, make sure `etc/caddy/sites` is **on a branch**. A detached
HEAD strands any commit made there; `autocommit.sh` detects it and refuses rather
than losing your work, but nothing is mirrored until you fix it.

Then turn on full mirroring (see below), since with the machinery in a repo you
own, publishing it automatically is the feature rather than the hazard:

```bash
echo 'AUTOCOMMIT_SELF=1' >> /etc/caddy/edge.env
```

Upgrading the machinery is `git pull` here; your sites are untouched, because
they are a different repository. A copy made from the template has no link back,
so add one once:

```bash
git remote add upstream https://github.com/artginzburg/caddy-vercel-edge.git
git pull upstream main
```

A fork already has that link and can send fixes back as pull requests, which is
the reason to prefer forking when the copy is going to be public anyway.
**Private copies must come from the template** — GitHub cannot make a fork of a
public repository private.

### One private copy — simpler, if you'd rather

Nothing forces the split. Take a **private** copy via *Use this template*, keep
sites in it, and let your site files be tracked:

```bash
sed -i '/^etc\/caddy\/sites\/\*\.caddy$/d;/^!etc\/caddy\/sites\//d' .gitignore
```

One repo, everything versioned, `AUTOCOMMIT_SELF=1`, done. You give up the
ability to share machinery changes without also exposing your host list — which
is exactly the trade the two-repo shape exists to avoid.

## Mirroring the box back to git

`infra-autocommit.timer` commits and pushes changes every ~10 minutes, so the
repository stays a faithful mirror of the live box and edits made over SSH land
in git on their own. It never fails the unit over a failed push — the commit is
made locally and goes out next time.

It treats the two repositories differently, on purpose:

| | Mirrored? |
|---|---|
| `etc/caddy/sites/`, when it is a repo of its own | **yes, always** — this is what changes day to day |
| this repo (the machinery) | **only with `AUTOCOMMIT_SELF=1`** |

`AUTOCOMMIT_SELF` starts off for one boring reason: a fresh checkout's `origin`
is *this* upstream, which you cannot push to. Point it at your own fork and turn
it on — that is the intended state, not an edge case:

```bash
echo 'AUTOCOMMIT_SELF=1' >> /etc/caddy/edge.env
```

Each repo is pushed to whatever branch it has checked out, so a submodule parked
on `split` pushes to `split`.

**Point `origin` at a repo you can write to first.** Cloned straight from here,
the push has nowhere to go (it fails harmlessly, and the commits still pile up
locally). It then needs a write deploy key:

```bash
ssh-keygen -t ed25519 -N '' -C "edge@$(hostname)" -f /root/.ssh/edge-deploy
cat /root/.ssh/edge-deploy.pub   # add as a *write* deploy key on your repo
cd /opt/caddy-vercel-edge
git config core.sshCommand "ssh -i /root/.ssh/edge-deploy -o IdentitiesOnly=yes"
```

Disable it with `systemctl disable --now infra-autocommit.timer` if you'd rather
commit by hand.

## Gotchas

- **`access.log` must be owned by `caddy`.** A `root:root 0600` log makes Caddy
  fail to reload with `permission denied`. Fix: `chown caddy:caddy
  /var/log/caddy/access.log`, then `systemctl restart caddy`.
- **A running Caddy keeps the systemd sandbox it started with.** After changing
  service hardening, `reload` is not enough — `systemctl restart caddy`.
- **Send the right SNI.** Caddy does this correctly for
  `reverse_proxy https://origin.example.com`; if you override `Host` or
  `tls_server_name` by hand you can trip Vercel's firewall rules.
- **Rate-limit at the proxy.** Vercel expects traffic mitigation to happen on
  your box. Without it, a flood against the proxy is forwarded to Vercel, and
  Vercel may ban the proxy IP for minutes to days — taking every site behind it
  down at once.
- **Keep the admin API on localhost** (`127.0.0.1:2019`).
- **Configs are symlinks into this repo.** Don't delete the checkout; if you do,
  re-clone and re-run `install.sh`.

## Migrating to a new box

1. Provision the new VPS and repoint DNS at its IP.
2. `git clone` + `sudo ./install.sh`.
3. Carry the TLS certificates and the stats database across, so HTTPS is instant
   and all-time counters keep going:
   ```bash
   ssh NEW 'systemctl stop caddy'
   ssh OLD 'tar -C /var/lib/caddy       -cf - .' | ssh NEW 'tar -C /var/lib/caddy       -xpf -'
   ssh OLD 'tar -C /var/lib/caddy-stats -cf - .' | ssh NEW 'tar -C /var/lib/caddy-stats -xpf -'
   ssh NEW 'chown -R caddy:caddy /var/lib/caddy && systemctl start caddy'
   ```
4. Copy `/etc/caddy/edge.env` across as well, or your app's marker check breaks.
5. Verify before flipping DNS:
   ```bash
   curl -sk --resolve example.com:443:NEW_IP https://example.com/ -o /dev/null -w '%{http_code}\n'
   ```

## License

MIT
