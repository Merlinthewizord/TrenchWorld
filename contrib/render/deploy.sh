#!/usr/bin/env bash
#
# Deploy Trench World to Render via the Render REST API.
#
# Render has no equivalent of the Traefik path-prefix routing used by
# contrib/docker/docker-compose.prod.yaml, so this deploys one service per
# subdomain instead. Every cross-service URL is passed as an absolute URL,
# and PATH_PREFIX is left empty because nothing strips a prefix here.
#
# Usage:
#   export RENDER_API_KEY=rnd_xxx
#   export RENDER_OWNER_ID=tea-xxx
#   ./contrib/render/deploy.sh
#
# Requires a payment method on the Render workspace: the back service must be
# a private service, and private services are not available on the free tier.

set -euo pipefail

: "${RENDER_API_KEY:?set RENDER_API_KEY}"
: "${RENDER_OWNER_ID:?set RENDER_OWNER_ID}"

API="https://api.render.com/v1"
REGION="${REGION:-oregon}"
PREFIX="${PREFIX:-trenchworld}"

# Pin to a digest-tagged master build so redeploys are reproducible.
VERSION="${VERSION:-master-704fd11dda1312ebac6cc3afeef601624eb01d65}"
REGISTRY="docker.io/thecodingmachine"

SECRETS_FILE="${SECRETS_FILE:-.render-secrets.env}"

api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $RENDER_API_KEY" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $RENDER_API_KEY"
  fi
}

# ---------------------------------------------------------------- secrets ---
# Generated once and reused; SECRET_KEY must stay stable or every issued JWT
# (and every stored player variable keyed off it) is invalidated.
if [ ! -f "$SECRETS_FILE" ]; then
  echo "Generating $SECRETS_FILE"
  python3 - "$SECRETS_FILE" <<'PY'
import secrets, sys
with open(sys.argv[1], "w") as f:
    for k in ("SECRET_KEY", "ROOM_API_SECRET_KEY", "MAP_STORAGE_AUTH_PASSWORD"):
        f.write(f"export {k}={secrets.token_hex(24)}\n")
PY
  chmod 600 "$SECRETS_FILE"
fi
# shellcheck source=/dev/null
source "$SECRETS_FILE"

PLAY_HOST="https://$PREFIX-play.onrender.com"
ICON_HOST="https://$PREFIX-icon.onrender.com"
UPLOADER_HOST="https://$PREFIX-uploader.onrender.com"
MAPSTORAGE_HOST="https://$PREFIX-map-storage.onrender.com"

# Render private-network addressing: services reach each other by service name.
BACK_INTERNAL="$PREFIX-back:50051"
MAPSTORAGE_GRPC="$PREFIX-map-storage:50053"
MAPSTORAGE_INTERNAL="http://$PREFIX-map-storage:3000"

# ------------------------------------------------------------- key value ---
echo "==> Key Value (Redis)"
KV=$(api POST /key-value "$(cat <<JSON
{"name":"$PREFIX-redis","ownerId":"$RENDER_OWNER_ID","plan":"starter",
 "region":"$REGION","maxmemoryPolicy":"noeviction"}
JSON
)")
echo "$KV" | grep -q '"id"' || { echo "FAILED: $KV" >&2; exit 1; }
KV_ID=$(echo "$KV" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

CONN=$(api GET "/key-value/$KV_ID/connection-info")
REDIS_HOST=$(echo "$CONN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["internalConnectionString"])')
echo "    $KV_ID"

# ---------------------------------------------------------------- helpers ---
# $1 service type, $2 short name, $3 image path, $4 plan, $5 envVars JSON array
create_service() {
  local type=$1 name=$2 image=$3 plan=$4 envvars=$5 extra=${6:-}
  echo "==> $PREFIX-$name ($type, $plan)"
  local payload
  payload=$(python3 - <<PY
import json, os
d = {
  "type": "$type",
  "name": "$PREFIX-$name",
  "ownerId": "$RENDER_OWNER_ID",
  "image": {"ownerId": "$RENDER_OWNER_ID", "imagePath": "$image"},
  "serviceDetails": {
      "env": "image",
      "runtime": "image",
      "region": "$REGION",
      "plan": "$plan",
      "numInstances": 1,
      "envSpecificDetails": {},
  },
  "envVars": json.loads(r'''$envvars'''),
}
extra = r'''$extra'''.strip()
if extra:
    d["serviceDetails"].update(json.loads(extra))
print(json.dumps(d))
PY
)
  local out; out=$(api POST /services "$payload")
  echo "$out" | grep -q '"id"' || { echo "FAILED: $out" >&2; exit 1; }
}

# ------------------------------------------------------------------- back ---
# Private service: holds live room state over gRPC, never publicly exposed.
create_service private_service back "$REGISTRY/workadventure-back:$VERSION" starter "$(cat <<JSON
[{"key":"PLAY_URL","value":"$PLAY_HOST"},
 {"key":"SECRET_KEY","value":"$SECRET_KEY"},
 {"key":"REDIS_HOST","value":"$REDIS_HOST"},
 {"key":"HTTP_PORT","value":"8080"},
 {"key":"GRPC_PORT","value":"50051"},
 {"key":"ENABLE_MAP_EDITOR","value":"true"},
 {"key":"MAP_STORAGE_URL","value":"$MAPSTORAGE_GRPC"},
 {"key":"INTERNAL_MAP_STORAGE_URL","value":"$MAPSTORAGE_INTERNAL"},
 {"key":"PUBLIC_MAP_STORAGE_URL","value":"$MAPSTORAGE_HOST"},
 {"key":"STORE_VARIABLES_FOR_LOCAL_MAPS","value":"true"},
 {"key":"MAX_PER_GROUP","value":"4"},
 {"key":"ENABLE_CHAT","value":"true"}]
JSON
)"

# ----------------------------------------------------------- map-storage ---
# Disk rather than S3: single instance is fine at this scale, and it avoids
# standing up an external bucket. Swap to AWS_* vars to move to S3/R2 later.
create_service web_service map-storage "$REGISTRY/workadventure-map-storage:$VERSION" starter "$(cat <<JSON
[{"key":"API_URL","value":"$BACK_INTERNAL"},
 {"key":"SECRET_KEY","value":"$SECRET_KEY"},
 {"key":"MAP_STORAGE_API_TOKEN","value":"$SECRET_KEY"},
 {"key":"PUSHER_URL","value":"$PLAY_HOST/"},
 {"key":"STORAGE_DIRECTORY","value":"/maps"},
 {"key":"PATH_PREFIX","value":""},
 {"key":"ENABLE_BASIC_AUTHENTICATION","value":"true"},
 {"key":"AUTHENTICATION_USER","value":"admin"},
 {"key":"AUTHENTICATION_PASSWORD","value":"$MAP_STORAGE_AUTH_PASSWORD"}]
JSON
)" '{"disk":{"name":"maps","mountPath":"/maps","sizeGB":5}}'

# -------------------------------------------------------------- uploader ---
# No AWS_* set, so S3StorageProvider.isEnabled() is false and uploads fall
# back to Redis-backed storage.
create_service web_service uploader "$REGISTRY/workadventure-uploader:$VERSION" starter "$(cat <<JSON
[{"key":"UPLOADER_URL","value":"$UPLOADER_HOST"},
 {"key":"REDIS_HOST","value":"$REDIS_HOST"},
 {"key":"ENABLE_CHAT_UPLOAD","value":"true"},
 {"key":"UPLOAD_MAX_FILESIZE","value":"10485760"}]
JSON
)"

# ------------------------------------------------------------------ icon ---
create_service web_service icon "docker.io/matthiasluedtke/iconserver:v3.21.0" starter '[]'

# ------------------------------------------------------------------ play ---
# Standard plan: the front end bundle needs more than the 512MB a Starter gets.
create_service web_service play "$REGISTRY/workadventure-play:$VERSION" standard "$(cat <<JSON
[{"key":"PUSHER_URL","value":"$PLAY_HOST/"},
 {"key":"FRONT_URL","value":"$PLAY_HOST"},
 {"key":"API_URL","value":"$BACK_INTERNAL"},
 {"key":"SECRET_KEY","value":"$SECRET_KEY"},
 {"key":"ROOM_API_SECRET_KEY","value":"$ROOM_API_SECRET_KEY"},
 {"key":"MAP_STORAGE_API_TOKEN","value":"$SECRET_KEY"},
 {"key":"ICON_URL","value":"$ICON_HOST"},
 {"key":"UPLOADER_URL","value":"$UPLOADER_HOST"},
 {"key":"INTERNAL_MAP_STORAGE_URL","value":"$MAPSTORAGE_INTERNAL"},
 {"key":"PUBLIC_MAP_STORAGE_URL","value":"$MAPSTORAGE_HOST"},
 {"key":"START_ROOM_URL","value":"/_/global/workadventure.github.io/map-starter-kit/office.tmj"},
 {"key":"ENABLE_MAP_EDITOR","value":"true"},
 {"key":"DISABLE_ANONYMOUS","value":"false"},
 {"key":"MAX_PER_GROUP","value":"4"},
 {"key":"MAX_USERNAME_LENGTH","value":"10"},
 {"key":"ENABLE_CHAT","value":"true"},
 {"key":"ENABLE_CHAT_UPLOAD","value":"true"},
 {"key":"ENABLE_OPENAPI_ENDPOINT","value":"true"}]
JSON
)"

cat <<EOF

Done. Play: $PLAY_HOST

Secrets are in $SECRETS_FILE (gitignored) — keep them; SECRET_KEY must not change.

Not configured yet:
  * LiveKit  - video calls are capped at 4 people until LIVEKIT_HOST /
               LIVEKIT_API_KEY / LIVEKIT_API_SECRET are set on back.
  * TURN     - without it roughly 15% of users fail to connect A/V.
               LiveKit Cloud covers both; Render cannot host either (no UDP).
  * Matrix   - no Synapse, so chat is bubble-only and not persisted.
EOF
