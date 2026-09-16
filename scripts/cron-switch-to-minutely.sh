#!/usr/bin/env bash
# Run switch-to-minutely.sh unattended, but only in the window where the
# switch is cheap.
#
# switch-to-minutely.sh refuses unless Overpass is at the head of its current
# stream. On a daily stream that is true ~23 hours out of 24, so that guard
# alone would fire at the worst moment: catch-up costs one global diff per
# minute of gap, and just before a daily lands the gap is ~1400 diffs.
#
# So gate on how recently the daily published. Fresh head + the script's own
# "at head" check together mean a new daily just landed AND Overpass has
# applied it -- the point where the gap is ~200-350 diffs instead.
#
# Note that state.txt's timestamp= is the diff's data cutoff, not when the file
# appeared: Geofabrik publishes ~3h10m after the cutoff it covers. So the age
# floor is that lag, never zero, and MAX_AGE has to clear it.
#
# Hourly from cron. Exits silently outside the window, and once the switch has
# happened switch-to-minutely.sh itself aborts with "already on the planet
# stream", so a stray run cannot do damage.
set -euo pipefail

STREAM=https://download.geofabrik.de/north-america/us/ohio-updates/
# 6h: the publication lag (~3h10m) plus the hourly cron granularity puts the
# first sighting of a fresh daily at ~3-4.5h old, and a switch-to-minutely.sh
# abort ("not caught up", if the updater has not applied the daily yet) needs
# another hour or two of retries inside the window.
MAX_AGE=21600

# MORPC 15-county region (REGION15), rounded outward from the county bounds.
export OVERPASS_DIFF_BBOX="-84.03,39.15,-82.01,40.73"

HEAD_TS=$(curl -fsSL "${STREAM}state.txt" | tr -d '\\' | sed -n 's/^timestamp=//p')
AGE=$(( $(date -u +%s) - $(date -u -d "$HEAD_TS" +%s) ))

if (( AGE >= MAX_AGE )); then
  echo "$(date -u +%FT%TZ) stream head is ${AGE}s old (>= ${MAX_AGE}s) -- not the window, skipping"
  exit 0
fi

echo "$(date -u +%FT%TZ) stream head is ${AGE}s old -- attempting switch"
exec /home/jordan/osm-stack/scripts/switch-to-minutely.sh --apply
