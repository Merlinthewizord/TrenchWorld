#!/usr/bin/env bash
#
# Bring up Trench World on a Cloudflare quick tunnel.
#
# Quick tunnels are chicken-and-egg: the hostname is assigned by Cloudflare at
# runtime, but the app needs to know it up front (it is baked into PUSHER_URL,
# the Traefik Host rules and the CORS origins). So this starts the tunnel
# first, reads the hostname out of the logs, writes it into .env, and only
# then starts the rest of the stack.
#
#   ./contrib/cloudflare-tunnel/start-quick.sh
#
# The hostname changes every time cloudflared restarts. Re-run this script
# after a restart, or switch to a named tunnel for a stable address.

set -euo pipefail

cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker-compose.tunnel.yaml --profile quick)

if [ ! -f .env ]; then
  echo "No .env here. Creating one from the template."
  cp .env.template .env
  SECRET=$(openssl rand -hex 24)
  MAPPW=$(openssl rand -hex 12)
  sed -i.bak "s|^SECRET_KEY=.*|SECRET_KEY=$SECRET|" .env
  sed -i.bak "s|^MAP_STORAGE_AUTHENTICATION_PASSWORD=.*|MAP_STORAGE_AUTHENTICATION_PASSWORD=$MAPPW|" .env
  rm -f .env.bak
  echo "Generated SECRET_KEY and map editor password into .env"
fi

# DOMAIN has to be non-empty for compose to interpolate, but its value does not
# matter yet — only reverse-proxy and cloudflared start in this first phase.
echo "==> Starting tunnel"
DOMAIN=placeholder.invalid "${COMPOSE[@]}" up -d reverse-proxy cloudflared-quick

echo "==> Waiting for Cloudflare to assign a hostname"
HOST=""
for _ in $(seq 1 30); do
  HOST=$("${COMPOSE[@]}" logs cloudflared-quick 2>&1 \
    | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  [ -n "$HOST" ] && break
  sleep 2
done

if [ -z "$HOST" ]; then
  echo "Timed out. Tunnel logs:" >&2
  "${COMPOSE[@]}" logs --tail 40 cloudflared-quick >&2
  exit 1
fi

DOMAIN=${HOST#https://}
sed -i.bak "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" .env && rm -f .env.bak
echo "==> Hostname: $DOMAIN"

echo "==> Starting the rest of the stack"
"${COMPOSE[@]}" up -d

cat <<EOF

Trench World is starting at $HOST

First load takes a minute or so while the containers settle. Check progress with:
  docker compose -f contrib/cloudflare-tunnel/docker-compose.tunnel.yaml --profile quick logs -f play

Map editor: $HOST/map-storage  (credentials are in contrib/cloudflare-tunnel/.env)

Stop with:
  docker compose -f contrib/cloudflare-tunnel/docker-compose.tunnel.yaml --profile quick down
EOF
