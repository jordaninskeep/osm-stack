#!/usr/bin/env bash
# Switch the Overpass container from a daily regional diff stream to OSM's
# minutely planet stream, which takes the data from ~25 hours behind live to
# ~1-2 minutes.
#
# Run it from the repo root on the host running the stack:
#
#     ./scripts/switch-to-minutely.sh            # check only, changes nothing
#     ./scripts/switch-to-minutely.sh --apply
#
# It refuses to run unless Overpass has caught up to the head of its current
# stream. That is not fussiness: catching up costs one download per minute of
# gap, so switching just after a daily lands replays tens of diffs where
# switching just before replays hundreds.
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

CONTAINER=osm-overpass-1
BBOX_DEFAULT="-84.8219,38.09861,-79.89951,43.48236"
PLANET_URL="https://planet.openstreetmap.org/replication/minute/"

die() { echo "  ABORT: $*" >&2; exit 1; }

[[ -f .env ]] || die "no .env here -- run this from the repo root on the server"
CURRENT_URL=$(grep -E '^OVERPASS_DIFF_URL=' .env | cut -d= -f2- || true)
[[ -n "$CURRENT_URL" ]] || die "OVERPASS_DIFF_URL is not set in .env"

case "$CURRENT_URL" in
  *planet.openstreetmap.org*) die "already on the planet stream -- nothing to do" ;;
esac

docker inspect "$CONTAINER" >/dev/null 2>&1 || die "$CONTAINER is not running"

# --- 1. are we at the head of the current stream? ------------------------
LOCAL=$(docker exec "$CONTAINER" cat /db/replicate_id | tr -d '[:space:]')
HEAD=$(curl -fsSL "${CURRENT_URL%/}/state.txt" \
        | tr -d '\\' | grep -E '^sequenceNumber=' | cut -d= -f2 | tr -d '[:space:]')
echo "  current stream : $CURRENT_URL"
echo "  local sequence : $LOCAL"
echo "  stream head    : $HEAD"
[[ "$LOCAL" == "$HEAD" ]] || die "not caught up ($LOCAL vs $HEAD) -- let the updater finish first"

# --- 2. what planet sequence does that correspond to? --------------------
# Geofabrik records it in the per-sequence state file, which is the only
# reliable mapping between the two numbering spaces.
PADDED=$(printf '%09d' "$LOCAL")
STATE_PATH="${PADDED:0:3}/${PADDED:3:3}/${PADDED:6:3}.state.txt"
PLANET_SEQ=$(curl -fsSL "${CURRENT_URL%/}/${STATE_PATH}" \
             | grep -oE 'sequence number[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)
[[ -n "${PLANET_SEQ:-}" ]] || die "could not read the planet sequence from ${STATE_PATH}"

PLANET_HEAD=$(curl -fsSL "${PLANET_URL}state.txt" \
              | tr -d '\\' | grep -E '^sequenceNumber=' | cut -d= -f2 | tr -d '[:space:]')
GAP=$(( PLANET_HEAD - PLANET_SEQ ))
echo "  planet equivalent : $PLANET_SEQ"
echo "  planet head       : $PLANET_HEAD"
echo "  catch-up          : $GAP diffs (~$(( GAP / 60 )) h)"

BBOX="${OVERPASS_DIFF_BBOX:-$BBOX_DEFAULT}"
echo "  clip bbox         : $BBOX"

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "  Check only. Re-run with --apply to switch."
  exit 0
fi

# --- 3. apply ------------------------------------------------------------
cp .env ".env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
docker exec "$CONTAINER" cp /db/replicate_id /db/replicate_id.preswitch

python3 - "$PLANET_URL" "$BBOX" <<'PY'
import sys, re, pathlib
url, bbox = sys.argv[1], sys.argv[2]
p = pathlib.Path('.env'); s = p.read_text()
clip = ("osmium extract -b " + bbox
        + " -o /db/diffs/clipped.osc /db/diffs/changes.osc"
        + " && mv -f /db/diffs/clipped.osc /db/diffs/changes.osc")
def setkv(s, k, v):
    if re.search(rf'^{k}=.*$', s, re.M):
        return re.sub(rf'^{k}=.*$', f'{k}={v}', s, flags=re.M)
    return s.rstrip('\n') + f'\n{k}={v}\n'
s = setkv(s, 'OVERPASS_DIFF_URL', url)
s = setkv(s, 'OVERPASS_UPDATE_SLEEP', '60')
s = setkv(s, 'OVERPASS_DIFF_PREPROCESS', clip)
p.write_text(s)
print("  .env updated")
PY

docker compose stop overpass >/dev/null

# Shell truncation preserves the inode and so the owner, but the updater runs
# as uid 1000 and a root-owned replicate_id would break it silently on the
# next cycle. Set it explicitly rather than depend on that.
docker run --rm -v osm_overpass_db:/db alpine sh -c \
  "echo $PLANET_SEQ > /db/replicate_id && chown 1000:1000 /db/replicate_id"

WROTE=$(docker run --rm -v osm_overpass_db:/db alpine sh -c 'cat /db/replicate_id; ls -ln /db/replicate_id')
echo "  replicate_id now: $WROTE"
case "$WROTE" in
  "$PLANET_SEQ"*1000*1000*) : ;;
  *) die "replicate_id did not take -- restore /db/replicate_id.preswitch and investigate" ;;
esac

docker compose --profile overpass up -d overpass >/dev/null

echo "  switched. watch it catch up with:"
echo "    docker compose logs -f overpass"
echo "    docker exec $CONTAINER cat /db/replicate_id"
