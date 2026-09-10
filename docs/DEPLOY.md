# Deploying osm-stack

Deploying to a VPS, and optionally exposing it to the internet. The stack runs
identically at home; this covers what changes when it lives on a server someone
else could reach.

The end state is a box with **no inbound ports open at all**: you reach it over
Tailscale, and the public path — if you want one — is an outbound-only
Cloudflare Tunnel.

1. [Choose a server](#1-choose-a-server)
2. [Base setup](#2-base-setup)
3. [Firewall](#3-firewall)
4. [Tailscale](#4-tailscale)
5. [Get the code](#5-get-the-code)
6. [Configure](#6-configure)
7. [Build the Overpass database](#7-build-the-overpass-database)
8. [Basemap](#8-basemap)
9. [Harden](#9-harden)
10. [Verify](#10-verify)
11. [Public access with a Cloudflare Tunnel](#11-public-access-with-a-cloudflare-tunnel)
12. [Team access: the Overpass endpoint](#12-team-access-the-overpass-endpoint)
13. [Operating notes](#13-operating-notes)

## 1. Choose a server

Steady state is small — the box is sized by two peaks, not by the running
service:

| | |
|---|---|
| Overpass database (Ohio, meta + areas) | ~6 GB |
| `basemap.pmtiles` | 108 MB |
| PBF cache | 322 MB |
| RAM, steady state | ~1.5 GB |
| CPU, steady state | ~0% |
| Inbound bandwidth | a few MB/day on a daily stream, ~100 MB/day on planet minutely |

- **The Overpass import** runs for the better part of an hour on 4 vCPU, area
  generation included, and is the one job that wants patience rather than RAM.
- **Planetiler** wants a 4 GB JVM heap on its own. It will not fit alongside
  Overpass on a 4 GB box — build the basemap elsewhere and copy the result in
  (step 8).

Anything with **4 GB RAM and ~40 GB disk** runs a state-sized extract. 8–16 GB
lets you build the basemap on the server rather than elsewhere. Cores only
affect the two one-time jobs:

| Job | 12 cores | 4 vCPU |
|---|---|---|
| Overpass import + areas (Ohio) | — | ~45–60 min |
| Planetiler basemap | 9m 26s | ~25–35 min |

Provider notes, both verified against current offerings at time of writing:

- **Hetzner** — use a US location (Ashburn is closest to Ohio). `CX`/`CAX`
  types are EU-only, so the frequently-quoted "CX22 for ~$5/mo" does not apply
  in the US; US locations run `CPX` (AMD) and `CCX` (dedicated). CPX21
  (3 vCPU / 4 GB / 80 GB) is the sweet spot; CPX11's 2 GB will thrash on
  import. Budget ~$15–20/mo plus a small IPv4 charge, and check current rates.
- **Hostinger** — KVM 4 (4 vCPU / 16 GB / 200 GB NVMe) is dedicated RAM, so
  Planetiler runs on the server rather than needing a build elsewhere. Install
  plain **Ubuntu 24.04 LTS**, not a panel image.

There is nothing here worth paying a managed-database price for: the whole
stack is reproducible from an OSM extract.

## 2. Base setup

Install Docker from Docker's own apt repository, not `apt install docker.io` —
you need the Compose **v2 plugin**, since this stack uses `profiles:`,
`depends_on.condition` and a top-level `name:`.

```bash
apt update && apt install -y ca-certificates curl git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

docker compose version      # must print v2.x
```

A normal user in the `docker` group (the group exists once Docker is installed):

```bash
adduser --gecos "" deploy
usermod -aG sudo,docker deploy
rsync -a --chown=deploy:deploy ~/.ssh/ /home/deploy/.ssh/
```

**Swap.** The import peak is large and a partial import is not resumable — it
restarts from the beginning. Swap is cheap insurance:

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swap.conf
```

Unattended security updates, which cover the Ubuntu security archive but
deliberately **not** the Docker repo — an unattended engine upgrade restarts
every container:

```bash
apt install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades

# patch Docker by hand, on whatever cadence you already use
apt update && apt install --only-upgrade docker-ce docker-ce-cli containerd.io
```

## 3. Firewall

**Nothing in this stack needs an inbound port**, including the parts that serve
traffic. Caddy joins the tailnet as its own node through userspace `tsnet`, and
Tailscale connects outbound. There is no listening socket on the public
interface to protect.

So the ruleset is one rule:

| Action | Protocol | Port | Source |
|---|---|---|---|
| `drop` | all | — | `0.0.0.0/0` |

Prefer **drop** over **reject** — a scanner gets a timeout rather than a reply
confirming the host is alive.

Two things that catch people out on provider firewalls:

- **A group with zero rules is inactive, not maximally strict.** It needs at
  least one rule to take effect, which is why "deny everything" is written as
  an explicit rule rather than an empty list.
- **Verify outbound still works immediately after enabling it.** The filter
  must be stateful or nothing on the box can download anything:

  ```bash
  apt update && curl -sSI https://download.docker.com | head -1
  ```

  If that hangs, detach the firewall and take it up with support before going
  further — every later step would fail confusingly.

Use the provider's firewall rather than `ufw` alone: a provider-level firewall
is edited from a browser tab, a host-level one from the shell it just cut off.
If you open port 22 to do the install over a real SSH client, **delete that
rule once Tailscale SSH works.** That is the step that quietly never gets done.

## 4. Tailscale

On the host, separate from the node the Caddy container registers. This one is
your shell.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh --hostname=osm-vps-host
```

`--ssh` hands SSH to Tailscale, authenticated by tailnet identity and governed
by your ACLs rather than a key file on the box. Once
`ssh deploy@osm-vps-host` works from another tailnet device, stop using the
provider's console.

## 5. Get the code

If the repo is private, give the server a **read-only deploy key** — scoped to
one repo, revocable on its own, no extra packages. Generate it as the user that
will own the checkout, not as root, or `git pull` fails later for the account
you actually log in as:

```bash
ssh-keygen -t ed25519 -C "osm-vps deploy key" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Paste it at **repo → Settings → Deploy keys → Add deploy key**, leaving *Allow
write access* unchecked. Then:

```bash
git clone git@github.com:<you>/osm-stack.git
cd osm-stack
```

Avoid `gh auth login` on a deployment target: it stores an OAuth token scoped
to your entire GitHub account, valid until revoked, on a box you may expose
later. That is a lot of blast radius for one `git clone`.
## 6. Configure

```bash
cp .env.example .env && chmod 600 .env
```

Only these differ from a local install:

```bash
# A DIFFERENT tailnet node name from any other instance. Two nodes claiming
# "osm" will fight over it and one silently becomes osm-1, which breaks
# TS_DOMAIN and the cert with it.
TS_HOSTNAME=osm-vps
TS_DOMAIN=osm-vps.your-tailnet.ts.net
TS_AUTHKEY=<fresh key; tag:container must exist in tagOwners>
TS_TAGS=tag:container
```

Check that `OVERPASS_DIFF_URL` matches `OSM_PBF_URL`. For a Geofabrik extract
that means replacing `-latest.osm.pbf` with `-updates/`:

```bash
OSM_PBF_URL=https://download.geofabrik.de/north-america/us/ohio-latest.osm.pbf
OVERPASS_DIFF_URL=https://download.geofabrik.de/north-america/us/ohio-updates/
```

A mismatch here does not fail loudly — updates simply stop.

## 7. Build the Overpass database

Fetch the extract first. This is its own one-shot service: nothing else
downloads it, and both Overpass and the basemap build from the same file.

```bash
docker compose --profile pbf run --rm pbf
docker compose --profile overpass up -d
docker compose logs -f overpass
```

The first start converts the PBF, imports it, applies diffs to catch up, and
builds areas. It serves nothing until `/db/init_done` appears, and area
generation is the long tail — expect the better part of an hour on 4 vCPU, and
around 6 GB in the `overpass_db` volume with metadata enabled.

> Two things in `OVERPASS_PLANET_PREPROCESS` are load-bearing. Both are already
> wired up; they matter only if you change that line.
>
> The image pipes whatever it reads straight into `bunzip2`, so pointing
> `OVERPASS_PLANET_URL` at a `.pbf` fails with `is not a bzip2 file` — and
> because of `restart: unless-stopped` it then restart-loops, re-reading the
> extract every cycle. `osmium` converts it first.
>
> And the image ships `/db` as mode `700` owned by the `overpass` user, while
> nginx and fcgiwrap — which execute the CGI that opens the dispatcher socket
> at `/db/db/osm3s_osm_base` — run as uid 101. Without `chmod 755 /db` every
> query returns **HTTP 200** carrying `runtime error: open64: 13 Permission
> denied`. A 200 with an error body inside is easy to mistake for the query
> being wrong rather than the deployment.

### Near-live data

The Geofabrik `-updates/` stream publishes **daily**, so no polling interval
beats a ~25 hour lag. For minutes instead, switch to OSM's own minutely
replication. Three changes plus one reset:

```yaml
OVERPASS_DIFF_URL: https://planet.openstreetmap.org/replication/minute/
OVERPASS_UPDATE_SLEEP: 60
OVERPASS_DIFF_PREPROCESS: >-
  osmium extract -b <the extract header bbox>
    -o /db/diffs/clipped.osc /db/diffs/changes.osc &&
  mv -f /db/diffs/clipped.osc /db/diffs/changes.osc
```

`OVERPASS_DIFF_PREPROCESS` runs against the downloaded change file before it is
applied. **The clip is not optional**: planet diffs are global, and applied
unclipped the database grows toward planet size. Get the bbox from the extract
itself:

```bash
docker run --rm -v osm_osmdata:/d:ro --entrypoint osmium wiktorn/overpass-api   fileinfo -e -g header.boxes /d/region.osm.pbf
```

Use that header box rather than a tighter one: clipping a change file can leave
ways referencing nodes outside the box, and the wider box makes that rarer.

**And reset the sequence.** `/db/replicate_id` holds a Geofabrik *extract*
sequence number; the planet stream is a different numbering space entirely.
Point the container at planet without resetting it and it will try to replay
from years ago. Geofabrik records the mapping in each per-sequence state file:

```
# original OSM minutely replication sequence number 7265697   <- the planet one
sequenceNumber=4896                                           <- the extract one
```

**Use the script rather than doing this by hand:**

```bash
./scripts/switch-to-minutely.sh            # check only, changes nothing
./scripts/switch-to-minutely.sh --apply
```

It refuses to run unless Overpass has caught up to the head of its current
stream, reads the planet sequence out of the state file for the sequence you
are actually on, backs up `.env` and `replicate_id`, and verifies both the new
value and its ownership before restarting. That last part matters: the updater
runs as uid 1000, and a root-owned `replicate_id` stops replication silently.

**Timing is most of the cost.** Catching up replays one diff per minute of gap,
so switching shortly after a daily lands replays tens of diffs where switching
just before one replays over a thousand — and each is a global diff downloaded
before it is clipped. The script prints the gap before it does anything.

## 8. Basemap

```bash
docker compose --profile basemap run --rm planetiler
docker compose --profile tiles up -d
```

On a 4 GB box Planetiler will not fit alongside the rest — build it elsewhere
and copy the archive in, it is identical output:

```bash
# on the machine that built it
docker run --rm -v osm_tiles:/t:ro -v "$PWD":/out alpine \
  cp /t/basemap.pmtiles /out/basemap.pmtiles
scp basemap.pmtiles deploy@osm-vps-host:/tmp/

# on the server
docker volume create osm_tiles
docker run --rm -v osm_tiles:/t -v /tmp:/in alpine \
  cp /in/basemap.pmtiles /t/basemap.pmtiles
docker compose --profile tiles up -d
rm /tmp/basemap.pmtiles
```

The basemap does not refresh on its own. Re-run Planetiler when you want it to
catch up, and remember it lags the Overpass data until you do.

## 9. Harden

There is no database role to lock down — Overpass is read-only by construction
and holds no credentials. What is worth bounding is query cost and reach.

**Overpass enforces its own limits**, and they are the only ones in this path:
`[timeout:]` and `[maxsize:]` in each query, with the server's ceilings set by
`OVERPASS_MAX_TIMEOUT` (default 1000s). There is no per-user quota, so a public
endpoint wants a rate limit at the edge — see [step 12c](#12c-rate-limit-it).

**Nothing needs an inbound port**, so the firewall in step 3 stays at
default-drop. Martin's debug port stays on loopback (`MARTIN_PORT`), and the
Overpass container publishes no port at all — Caddy reaches it over the compose
network.

**The credential files in `caddy/auth/` are the only secrets on the box** other
than `.env`. They are what stands between the internet and your Overpass
endpoint once the Access bypass in step 12c exists.

## 10. Verify

```bash
docker compose ps
curl https://osm-vps.your-tailnet.ts.net/tiles/catalog
curl -X POST https://osm-vps.your-tailnet.ts.net/api/interpreter \
     --data-urlencode 'data=[out:json];node(1);out ids;'
```

The second should return JSON whose `osm3s.timestamp_osm_base` is the vintage of
your data. The map is at `/map/`, and `/` redirects to it.

First request takes ~20 s while Tailscale issues the certificate; warm requests
are ~35 ms.

If the name does not resolve from a given device, check the tailnet ACLs for
`tag:container` before suspecting the Caddyfile — a device not granted
visibility of that tag sees neither this node nor any other tagged node.

## 11. Public access with a Cloudflare Tunnel

Optional and additive — the tailnet path keeps working unchanged. You get
reachability from any network with no inbound ports, Cloudflare Access in front
as the authentication this stack does not have of its own, and edge caching for
tiles.

**You need a domain Cloudflare manages.** Nothing here works without a zone.

### 11a. Give Caddy a listener the tunnel can reach

The tailnet site block uses `bind tailscale/...`, which means Caddy listens on
the tailnet interface **only** — `cloudflared` has no socket to talk to. A
second site block, already in `caddy/Caddyfile`, is a plain listener on `:8080`
that is not published to any host port, so it is unreachable except through the
tunnel:

```caddyfile
:8080 {
	encode zstd gzip

	handle /map/* {
		root * /srv
		file_server
		@mjs path *.mjs
		header @mjs Content-Type "text/javascript; charset=utf-8"
	}
	redir /map /map/

	handle /tiles/* {
		reverse_proxy martin:3000 {
			header_up X-Forwarded-Proto https
		}
	}

	redir / /map/ permanent
	respond 404
}
```

> **That `header_up` line is not optional.** Martin builds the absolute URLs
> inside its TileJSON — the `tiles[]` array the map actually fetches — from the
> request's `Host` and `X-Forwarded-Proto`. This block is a plain HTTP
> listener, so Caddy sets `X-Forwarded-Proto: http` from the connection it
> received and Martin advertises `http://` tile URLs, which the browser then
> blocks as mixed content. The symptom is a map that loads, paints its
> background and stays empty — style and glyphs are same-origin and come back
> fine, so it looks like a tile problem rather than a scheme problem.
>
> Setting the header on the *inbound* request does not work: Caddy discards
> inbound `X-Forwarded-*` from clients not in `trusted_proxies`. It has to be
> set on the way out to Martin. Watch the spelling — `X_Forwarded-Proto` is
> accepted without complaint and does nothing.

The Caddyfile is baked into the image, so this needs a rebuild:

```bash
docker compose build caddy && docker compose up -d caddy
```

### 11b. Create the tunnel

`cloudflared` is already in `docker-compose.yml` behind a `public` profile:

```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  profiles: ["public"]
  restart: unless-stopped
  command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
  depends_on: [caddy]
```

In the dashboard, **Zero Trust → Networks → Tunnels → Create**:

1. Name it, choose the **Docker** connector, copy the token into
   `CF_TUNNEL_TOKEN` in `.env`.
2. Add a **Public Hostname**: your subdomain, service **HTTP**, URL
   `caddy:8080`. That resolves over the compose network — cloudflared is a peer
   of Caddy, so the container name is the address. Not `localhost`.

```bash
docker compose --profile public up -d
```

Confirm the tunnel shows **HEALTHY** in the dashboard.

### 11c. Put Access in front

**Zero Trust → Access → Applications → Add a self-hosted application**, pointing
at your hostname. Add a policy — email OTP is the zero-setup option.

Access breaks programmatic clients: `curl`, the Python client and any script
gets an HTML login page instead of JSON. For those, create a **service token**
under Access → Service Auth and send its headers:

```bash
curl -H "CF-Access-Client-Id: <id>" -H "CF-Access-Client-Secret: <secret>" \
     https://osm.example.com/api/interpreter --data-urlencode 'data=[out:json];node(1);out ids;'
```

A token is not accepted just by existing — **the application needs a policy of
type Service Auth that admits it.** Without one, Access treats the request as
anonymous and bounces it to SSO. Keep the existing SSO policy alongside it;
browser users keep using that.

Store the credentials in `.env` as `CF_ACCESS_CLIENT_ID` and
`CF_ACCESS_CLIENT_SECRET`, and remember that the token then grants unattended
access to the whole hostname from anywhere.

### 11d. Cache the tiles

This is most of the practical value — basemap tiles never change between
Planetiler rebuilds.

**Caching → Cache Rules → Create rule** on your zone
(`dash.cloudflare.com/<account>/<domain>/caching/cache-rules`), with a custom
filter expression:

```
starts_with(http.request.uri.path, "/tiles/")
```

Set **Eligible for cache**, Edge TTL a few days, Browser TTL a day. Since the
origin sends no `Cache-Control`, use "Ignore cache-control header and use this
TTL".

Do **not** cache `/api/*` — Overpass answers live queries, and a cached answer
to one query would be served for a different one. Rate limit it instead; see
[step 12c](#12c-rate-limit-it).

Check it engages: `cf-cache-status: HIT` on a repeat tile request.

### 11e. Verify

```bash
docker compose --profile public ps
docker compose logs cloudflared | tail

curl -I https://osm.example.com/map/          # 302 to Access login = working
curl -H "CF-Access-Client-Id: ..." -H "CF-Access-Client-Secret: ..." \
     -X POST https://osm.example.com/api/interpreter \
     --data-urlencode 'data=[out:json];node(1);out ids;'

curl https://osm-vps.your-tailnet.ts.net/tiles/catalog       # tailnet, untouched
```

### Cost

| Item | Cost |
|---|---|
| Cloudflare Tunnel | free |
| Cloudflare Access | free up to 50 users |
| Cache Rules | free |
| Domain | ~$10/yr |
| Bandwidth | free (Cloudflare does not bill egress) |

## 12. Team access: the Overpass endpoint

For giving colleagues query access without SSH. The endpoint is a real Overpass
API, so their existing tooling works by changing one URL:

```
https://overpass-api.de/api/interpreter   ->   https://osm.example.com/api/interpreter
```

### 12a. Create a credential per person

Basic auth guards `/api/*` on the public listener. Every Overpass client speaks
`https://user:pass@host/...` natively, which is why this rather than Cloudflare
Access service tokens — those need two custom headers that QGIS QuickOSM and
`overpy` cannot easily send.

```bash
docker run --rm caddy:2.11.4-alpine caddy hash-password --plaintext 'their-password'
printf 'alice %s\n' '<the $2a$14$... hash>' >> caddy/auth/users.caddy
docker compose restart caddy
```

One `<username> <bcrypt-hash>` pair per line, in any `*.caddy` file under
`caddy/auth/`. Quote the hash in shell — it contains `$`. Revoke by deleting
the line and restarting Caddy.

The files are gitignored, like `.env`. **With no files there the endpoint
returns 401 to everyone** — an empty user list denies rather than allows, so a
missing file fails closed rather than open.

The tailnet listener leaves `/api/*` unauthenticated, matching every other
route on it. Anyone you put on the tailnet has unauthenticated access.

### 12b. Let it past Cloudflare Access

Access sits on the hostname and bounces these requests to an SSO login page,
which no Overpass client can follow. Every request arrives as a `302` no matter
what credentials it carries, because Cloudflare answers before Caddy ever sees
it.

**Access has no per-path policies within an application**, so there is nothing
to add to the existing app. Create a second, more specific application instead;
Cloudflare matches the most specific one by path.

**Zero Trust → Access → Applications → Add an application → Self-hosted**

1. Name it something like `osm overpass api`.
2. Application domain: subdomain `osm`, your domain, and **Path: `api`**. The
   path is the whole point — it is what makes this app more specific than the
   hostname-wide one.
3. Add one policy: **Action: Bypass**, Include: **Everyone**.

Leave the existing application untouched. It keeps protecting `/map/`,
`/map/`, `/tiles/*` and everything else with SSO.

Verify both halves — that `/api/` is through, and that nothing else opened up:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://osm.example.com/api/interpreter
#  302 -> still Access; the path did not match
#  401 -> correct: that is Caddy's basic auth challenge

for p in /map/ /tiles/catalog; do
    curl -s -o /dev/null -w "$p %{http_code}\n" "https://osm.example.com$p"
done
#  302 on each -> still SSO-protected, as intended
```

### 12c. Rate limit it

Bypass removes Access from this path only; the rest of Cloudflare still
applies, so WAF and rate limiting keep working. That matters more here than
elsewhere, because after the bypass an anonymous request reaches your origin
and gets Caddy's 401 rather than being turned away at the edge, and Overpass
enforces only its own `[timeout:]` and `[maxsize:]`. There is no per-user quota
behind it.

**Security → WAF → Rate limiting rules → Create rule**

| Field | Value |
|---|---|
| Name | `overpass api` |
| Custom filter expression | `starts_with(http.request.uri.path, "/api/")` |
| Rate | 60 requests per 1 minute |
| Counting characteristic | IP address |
| Action | Block |
| Duration | 10 seconds (or longer) |

60/minute is generous for interactive use and still bounds a runaway script.
An Overpass query is far more expensive than a tile request, so this should be
much tighter than anything you set on `/tiles/*`.

Two things worth knowing when you tune it:

- **Count by IP, not by JA3/JA4 fingerprint.** A team behind one office NAT
  shares an address, so set the rate for the whole team rather than one person.
  If that becomes the limiting factor, raise the rate rather than switching
  characteristic — fingerprint counting would let one misbehaving script per
  browser build slip through.
- **Rate limiting does not replace the credential.** It bounds volume from an
  address; it does nothing about who is calling. Basic auth is still the only
  thing deciding that, which is why `caddy/auth/*.caddy` is load-bearing once
  the bypass exists.

### 12d. What to tell a teammate

> Point your Overpass tool at `https://osm.example.com/api/interpreter` instead
> of `https://overpass-api.de/api/interpreter`, with the username and password
> you were given. Queries work unchanged. The data covers Ohio only, and is
> usually a day or so behind live OSM.

```bash
curl -u alice:their-password \
     -X POST https://osm.example.com/api/interpreter --data-urlencode 'data=
  [out:json][timeout:25];
  nwr["amenity"="cafe"](39.94,-83.02,39.98,-82.96);
  out geom;'
```

In QGIS QuickOSM the server is set under *Settings → Advanced → Overpass API*.
In `overpy`, `overpy.Overpass(url="https://alice:pw@osm.example.com/api/interpreter")`.

### 12e. Two things to expect

- **Overpass answers for the whole extract**, not for `CLIP_BBOX`. That setting
  restricts the basemap only, so a query can return features in parts of the
  extract the map does not draw in detail.
- **Freshness is set by the source.** On the Geofabrik daily stream the data is
  up to ~25 hours behind live OSM regardless of `OVERPASS_UPDATE_SLEEP`. Tell
  people the number, or switch to planet minutely (step 7) and tell them a
  different one.

## 13. Operating notes

**Updates are `git pull` plus a rebuild where images are involved.** Run git as
the user that owns the checkout — as root it fails on the deploy key, and a
failed fetch against a stale `origin/main` can leave you fast-forwarding to the
wrong place:

```bash
cd ~/osm-stack && git pull --ff-only
docker compose build caddy && docker compose up -d caddy
```

**Purge the Cloudflare cache after every basemap rebuild**, and after any
change to what Martin advertises — `/tiles/basemap` is the TileJSON itself and
matches the same cache rule, so a fix to the `tiles[]` URLs stays invisible
until it is purged. Purge by prefix is Enterprise-only; on Free/Pro/Business
the realistic option is Purge Everything.

**Rotate the tunnel token** by deleting and recreating the tunnel; there is no
in-place rotation.

**Keep using the tailnet for your own tooling.** No Access friction, no egress
through a third party, and no credential to carry — `/api/*` is open there.
