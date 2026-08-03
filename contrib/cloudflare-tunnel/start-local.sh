#!/usr/bin/env bash
#
# Run Trench World locally, with no tunnel and nothing exposed off the machine.
#
#   ./contrib/cloudflare-tunnel/start-local.sh [port]
#
# Serves on http://localhost:8080 by default. Traefik is bound to 127.0.0.1, so
# only this machine can reach it.
#
# Note the split between DOMAIN and PUBLIC_HOST: Traefik's Host() matcher works
# on the hostname alone, but the browser-facing URLs baked into the app need the
# port too, or the front end tries to reach the wrong origin.

set -euo pipefail

cd "$(dirname "$0")"

PORT="${1:-8080}"
ENV_FILE=".env.local"

COMPOSE=(docker compose --env-file "$ENV_FILE"
         -f docker-compose.tunnel.yaml
         -f docker-compose.local.yaml)

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Generating $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
DOMAIN=localhost
PUBLIC_HOST=localhost:$PORT
SCHEME=http
LOCAL_PORT=$PORT
SECRET_KEY=$(openssl rand -hex 24)
MAP_STORAGE_AUTHENTICATION_USER=admin
MAP_STORAGE_AUTHENTICATION_PASSWORD=$(openssl rand -hex 12)
VERSION=master
LOG_LEVEL=WARN
RESTART_POLICY=unless-stopped
EOF
  chmod 600 "$ENV_FILE"
else
  # Keep the port consistent with whatever was passed in.
  sed -i.bak -e "s|^PUBLIC_HOST=.*|PUBLIC_HOST=localhost:$PORT|" \
             -e "s|^LOCAL_PORT=.*|LOCAL_PORT=$PORT|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
fi

echo "==> Pulling images (first run downloads ~6GB)"
"${COMPOSE[@]}" pull -q

echo "==> Starting"
"${COMPOSE[@]}" up -d

echo "==> Waiting for play to answer"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://localhost:$PORT/ping" >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 2
done

if [ -z "${ok:-}" ]; then
  echo "play did not come up. Recent logs:" >&2
  "${COMPOSE[@]}" logs --tail 30 play back >&2
  exit 1
fi

# /ping only proves play is alive; /ping-backs proves it reached back over gRPC.
backs=$(curl -fsS --max-time 5 "http://localhost:$PORT/ping-backs" 2>/dev/null || echo FAILED)

cat <<EOF

  Trench World is running at http://localhost:$PORT
  play -> back gRPC: $backs

  Map editor:  http://localhost:$PORT/map-storage
  Credentials: $ENV_FILE

  Logs:  docker compose --env-file $ENV_FILE -f docker-compose.tunnel.yaml -f docker-compose.local.yaml logs -f play
  Stop:  docker compose --env-file $ENV_FILE -f docker-compose.tunnel.yaml -f docker-compose.local.yaml down

Only this machine can reach it. To share it, use ./start-quick.sh instead.
EOF
