# Caddy with the Tailscale plugin, so the proxy joins the tailnet as its own
# node (own MagicDNS name, own automatic HTTPS cert) via userspace tsnet --
# no host networking, no published ports, no TUN device required.
# Same pattern as ~/hey-kitchen/caddy, on a newer pinned Caddy.
FROM caddy:2.11.4-builder-alpine AS builder
RUN xcaddy build --with github.com/tailscale/caddy-tailscale

FROM caddy:2.11.4-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
