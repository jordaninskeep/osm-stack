# osm-stack

A self-hosted Overpass API for a region, with a map on top of it.

Overpass holds the data and answers the queries; Planetiler builds a basemap
from the same extract; Caddy serves both, on your tailnet and optionally to the
internet behind per-person credentials. Existing Overpass tooling works against
it by changing one URL.

Nothing is fetched from the internet at runtime — the basemap, fonts and map
client are all built and served in-house.

| | |
|---|---|
| Map | `https://<host>/map/` |
| Overpass API | `https://<host>/api/interpreter` |
| Basemap tiles | `https://<host>/tiles/basemap/{z}/{x}/{y}` |

Deploying to a server, and exposing it publicly, is in
**[docs/DEPLOY.md](docs/DEPLOY.md)**.

## Requirements

Docker with the Compose v2 plugin, and disk proportional to the region. Roughly,
for a state-sized extract:

| | |
|---|---|
| Overpass database | ~6 GB (with metadata and areas) |
| `basemap.pmtiles` | ~110 MB |
| PBF cache | ~320 MB |
| RAM, steady state | ~1.5 GB |

The two one-time jobs are what size the box: the Overpass import wants an hour
or so on 4 vCPU, and Planetiler wants a 4 GB JVM heap of its own.

## Quick start

```bash
cp .env.example .env
# set OSM_PBF_URL to your region, and OVERPASS_DIFF_URL to the matching stream

docker compose --profile pbf run --rm pbf                # fetch the extract
docker compose --profile overpass up -d                  # build + serve Overpass
docker compose logs -f overpass                          # first run imports; be patient

docker compose --profile basemap run --rm planetiler     # build basemap.pmtiles
docker compose --profile tiles up -d                     # serve tiles + the map
```

Pick any extract from <https://download.geofabrik.de/>. `OVERPASS_DIFF_URL` must
match it — for Geofabrik, replace `-latest.osm.pbf` with `-updates/`. A wrong
value there stops updates silently.

## Configuration

All of it lives in `.env`; `.env.example` is the annotated version.

| Variable | Purpose |
|---|---|
| `OSM_PBF_URL` | The extract. Both Overpass and the basemap are built from it. |
| `OVERPASS_DIFF_URL` | Replication stream. Must match the extract. |
| `OVERPASS_UPDATE_SLEEP` | Seconds between diff runs. Match the source: 3600 for a daily stream, 60 for planet minutely. |
| `OVERPASS_META` | `yes` keeps version/timestamp/user, which `out meta;` needs. |
| `CLIP_BBOX` | Restricts the **basemap** to a sub-region. Overpass is not clipped by it. |
| `TS_AUTHKEY` / `TS_HOSTNAME` / `TS_DOMAIN` / `TS_TAGS` | The tailnet node Caddy registers. `TS_TAGS` is required when the auth key is an OAuth client secret. |
| `MARTIN_PORT` | Loopback debug port for the tile server. |
| `CF_TUNNEL_TOKEN`, `CF_ACCESS_CLIENT_*` | Public deployment only; see docs/DEPLOY.md. |

## Querying

The endpoint is Overpass API, unmodified. Anything Overpass QL expresses works,
and any client that speaks Overpass works by changing its base URL:

```
https://overpass-api.de/api/interpreter   ->   https://<host>/api/interpreter
```

```bash
curl -X POST https://<host>/api/interpreter --data-urlencode 'data=
  [out:json][timeout:25];
  nwr["amenity"="cafe"](39.94,-83.02,39.98,-82.96);
  out geom;'
```

QGIS QuickOSM sets the server under *Settings → Advanced → Overpass API*.
`overpy` takes it as `overpy.Overpass(url=...)`.

Areas are built, so `area[name="..."]` and `is_in` work. Metadata is kept, so
`out meta;` returns versions and timestamps — Geofabrik extracts strip
usernames, so `user` comes back empty.

Two things worth knowing about `out`:

- **`out tags geom` suppresses a relation's members**, and a relation's geometry
  lives in its members. Use `out geom` when you want relation geometry.
- **Elements come back nodes, then ways, then relations.** A low `out` limit
  truncates before reaching ways, so cap generously or query one type at a time.

On the public listener `/api/*` is behind HTTP basic auth, one credential per
person — see [docs/DEPLOY.md](docs/DEPLOY.md). On the tailnet it is open, like
every other route there.

## The map

`https://<host>/map/` — MapLibre over the Planetiler basemap, with everything
above the basemap answered by Overpass.

**Click anywhere** and the sidebar lists what is there: enclosing areas
innermost-outward, then nearby objects by distance. The enclosing set comes from
`is_in`, which finds a county or a park whose vertices are nowhere near the
click; nearby objects come from `nwr(around:)`, and any polygon among them that
actually contains the point is promoted to enclosing by a point-in-polygon test
in the browser. The radius scales with zoom.

Large administrative areas are listed from their bounding box rather than their
true outline — downloading 565 member ways to draw a city boundary is not worth
it — and are labelled *approximate extent*.

**Search by tag** builds Overpass QL from the panel: any number of key/value
rows, matched `any` or `all`, across Nodes, Ways and Relations, over the current
view or the whole region. **Export** writes the results as `.geojson` with tags
flattened into properties, ready for QGIS.

The subtitle shows how far behind live OSM the data is, read from
`osm3s.timestamp_osm_base` — which every Overpass response carries, so it
describes the data that answered your query rather than a separate status call.

## Basemap tiles

`basemap.pmtiles` is built by Planetiler from the same extract Overpass uses,
with the Protomaps basemap schema:

```bash
docker compose --profile basemap run --rm planetiler   # ~9 min on 12 cores
```

It does **not** refresh on its own. Re-run it when you want the basemap to catch
up; Martin picks up the new archive on restart. The style is `web/style.json`,
generated from `protomaps-themes-base`:

```bash
docker run --rm -v "$PWD/web:/w" -w /w node:22-alpine \
  sh -c "npm i -s protomaps-themes-base@4.5.0 && node style.gen.js"
```

## Updating

Overpass polls `OVERPASS_DIFF_URL` every `OVERPASS_UPDATE_SLEEP` seconds and
applies what it finds. **Freshness is set by the source, not the interval.**

| Source | Publishes | Data is |
|---|---|---|
| Geofabrik `<extract>-updates/` | daily | up to ~25 h behind |
| OSM planet minutely | every minute | ~1–2 min behind |

The planet stream is global, so it must be clipped to the extract before being
applied or the database grows toward planet size. That, and the sequence-number
reset the switch requires, are in [docs/DEPLOY.md](docs/DEPLOY.md).

```bash
docker exec osm-overpass-1 cat /db/replicate_id     # current position
```

## Operations

| Task | Command |
|---|---|
| Check replication position | `docker exec osm-overpass-1 cat /db/replicate_id` |
| Refresh the extract | `docker compose --profile pbf run --rm pbf` |
| Rebuild the basemap | `docker compose --profile basemap run --rm planetiler` |
| Add an API credential | see `caddy/auth/README.md` |
| Pause updates | unset `OVERPASS_DIFF_URL`, then `docker compose up -d overpass` |
| Move to minutely updates | `./scripts/switch-to-minutely.sh` (check), then `--apply` |

**Editing the Caddyfile needs a rebuild.** It is `COPY`'d into the image, so
`docker compose up -d` alone keeps the old config and a route will 404:

```bash
docker compose build caddy && docker compose up -d caddy
```

**Backups.** Everything is reproducible from OSM. Back up `.env` and
`caddy/auth/*.caddy`, which are the only things you cannot regenerate.

## Repository layout

```
caddy/                     Caddyfile and image (tailnet + tunnel listeners)
caddy/auth/                per-teammate API credentials (gitignored)
planetiler/                basemap build job
fonts/                     vendored Noto Sans, served as glyphs by Martin
web/                       the map: index.html, style.json, vendored MapLibre
scripts/                   one-off operational scripts
docs/DEPLOY.md             server deployment, public exposure, team access
docs/architecture.drawio   architecture and data-flow diagrams
```

## Design notes

- **Overpass is the only datastore.** The basemap is prebuilt and needs no
  database, and click-query and tag search are both things Overpass answers
  natively, so nothing else has to hold a copy of the data.
- **Overpass QL is the ceiling.** Spatial joins, aggregation and
  nearest-neighbour queries cannot be expressed in it. If you need those, run a
  spatial database alongside this rather than trying to bend the API.
- **No vector tiles of the data.** Overpass returns features, not tiles, so the
  map draws query results as GeoJSON. There is no "show me everything" overlay;
  that needed tiles generated from a database.
- **The basemap is prebuilt**, not rendered on demand, and lags the Overpass
  data until you rebuild it.
