# Per-teammate credentials for the Overpass endpoint

Caddy imports every `*.caddy` file here into the `basic_auth` block guarding
`/api/*` on the public listener. The files are gitignored: they are per-host
secrets, like `.env`.

Add someone:

Pipe it straight in rather than copying the hash by hand — a bcrypt hash is 60
characters and wraps in most terminals, and a hash that arrives split across
two lines, or glued to the username with no space, makes the config invalid:

```bash
docker run --rm caddy:2.11.4-alpine caddy hash-password --plaintext 'their-password' \
  | sed 's/^/alice /' >> caddy/auth/users.caddy
docker compose restart caddy
```

One `<username> <bcrypt-hash>` pair per line, two fields, no line breaks
inside the hash. Check before restarting — `awk '{print NF}' users.caddy`
should print `2` on every line. Remove someone by deleting their line.

**A malformed file stops Caddy from starting at all**, which takes down the
map, tiles and the API on both listeners, not just `/api/*`. Validate first:

```bash
docker run --rm --entrypoint caddy -v "$PWD/caddy/auth:/etc/caddy/auth:ro" \
  -e TS_HOSTNAME=osm -e TS_DOMAIN=osm.example.ts.net -e TS_TAGS=tag:container \
  osm-caddy validate --config /etc/caddy/Caddyfile
```

With no files here the endpoint returns 401 to everyone, which is the safe
failure: an empty user list denies, it does not allow.
