#!/bin/sh
# Generate a basemap .pmtiles from the extract the importer already downloaded.
set -eu

PBF=${PBF:-/data/region.osm.pbf}
OUT=${OUT:-/tiles/out/basemap.pmtiles}
SRC=${SRC:-/tiles/sources}
: "${JAVA_HEAP:=4g}"

log() { printf '%s  %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [ ! -f "$PBF" ]; then
  log "ERROR: $PBF not found - run: docker compose --profile pbf run --rm pbf"
  exit 1
fi

# Planetiler wipes its tmpdir on exit, so it must be a directory INSIDE the
# mount rather than the mount point itself (deleting that fails "Resource busy").
TMP=/tiles/tmp/work
mkdir -p "$(dirname "$OUT")" "$TMP" "$SRC"

# CLIP_BBOX (minlon,minlat,maxlon,maxlat) maps onto planetiler's --bounds, so the
# basemap covers the same region as the queryable data instead of the whole state.
BOUNDS=""
if [ -n "${CLIP_BBOX:-}" ]; then
  BOUNDS="--bounds=${CLIP_BBOX}"
  log "restricting basemap to ${CLIP_BBOX}"
fi

# The Protomaps profile blends OSM with Natural Earth (low-zoom land, ocean and
# country outlines). --download fetches whatever is missing into $SRC, which is
# a persistent volume, so this is a one-time ~700MB cost, not a per-run one.
# The OSM input is NOT downloaded: --osm_path already satisfies it.
log "building ${OUT} from ${PBF} (heap ${JAVA_HEAP}, sources cached in ${SRC})"
exec java -Xmx"${JAVA_HEAP}" -jar /tiles/protomaps-basemap.jar \
  --osm_path="$PBF" \
  --output="$OUT" \
  --download \
  --download_dir="$SRC" \
  --tmpdir="$TMP" \
  --force \
  ${BOUNDS} \
  ${PLANETILER_ARGS:-}
