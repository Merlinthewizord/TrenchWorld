# Deploying Trench World on Render

> [!WARNING]
> Render **cannot** host the full platform. It has no inbound UDP, so LiveKit and
> Coturn must run elsewhere. See [Limitations](#limitations) before committing to this path.

`deploy.sh` creates the application tier on Render via the REST API, using the
prebuilt `thecodingmachine/workadventure-*` images so nothing has to build the
monorepo.

## Prerequisites

- **A payment method on the Render workspace.** `back` must be a private service,
  and [private services are not available on the free tier](https://render.com/docs/free).
  Without a card the API returns `402 Payment information is required`.
- `RENDER_API_KEY` and `RENDER_OWNER_ID` (`tea-…`, from `GET /v1/owners`).

## Usage

```console
$ export RENDER_API_KEY=rnd_xxx
$ export RENDER_OWNER_ID=tea-xxx
$ ./contrib/render/deploy.sh
```

Secrets are generated once into `.render-secrets.env` and reused on subsequent
runs. Keep that file: `SECRET_KEY` signs every JWT and keys stored player
variables, so rotating it logs everyone out and orphans their data.

## What it creates

| Service | Type | Plan | Notes |
|---|---|---|---|
| `trenchworld-redis` | Key Value | Starter | Persistent; the free tier is in-memory only |
| `trenchworld-back` | Private service | Starter | gRPC :50051, holds live room state |
| `trenchworld-map-storage` | Web service | Starter | 5GB disk at `/maps` |
| `trenchworld-uploader` | Web service | Starter | Redis-backed storage, no S3 needed |
| `trenchworld-icon` | Web service | Starter | Third-party favicon fetcher |
| `trenchworld-play` | Web service | Standard | Entry point; 512MB is not enough |

Roughly **$60/month**. A single small VPS runs the whole stack — including
Synapse and automatic TLS — from `contrib/docker/docker-compose.prod.yaml`
unmodified, for a fraction of that.

## How this differs from the Docker Compose install

The compose install is single-domain: Traefik routes `/api`, `/uploader`,
`/icon` and `/map-storage` to different containers and strips the prefix.

Render attaches a custom domain to exactly one service, and
[rewrites to internal URLs fail with 502](https://community.render.com/t/rewrite-rules-that-target-internal-urls/2940),
so that layout can't be reproduced. Instead each service gets its own
`*.onrender.com` subdomain and every cross-service URL is passed as an absolute
URL. This is a supported configuration — the development compose file already
runs a subdomain-per-service layout.

Two consequences:

- `PATH_PREFIX` on map-storage is empty. Nothing strips a prefix here, so
  setting it to `/map-storage` (as the compose file does) breaks routing.
- `ICON_URL` and `UPLOADER_URL` are absolute rather than the relative `/icon`
  and `/uploader`.

Services address each other over Render's private network by service name.

## Limitations

**No LiveKit, no Coturn.** Render accepts inbound HTTPS only;
[UDP is an open feature request](https://feedback.render.com/features/p/support-udp).
Both are WebRTC media servers that need UDP, so neither can run here. Use
**LiveKit Cloud** and point `LIVEKIT_HOST` / `LIVEKIT_API_KEY` /
`LIVEKIT_API_SECRET` at it — it provides TURN too, covering Coturn. Until then
video calls cap at 4 participants and roughly 15% of users fail to establish
audio/video at all.

**No Matrix.** Synapse needs Postgres plus a media disk and is not deployed.
Chat works within proximity bubbles but is not persisted, and there is no
offline messaging.

**`map-storage` binds two ports** — HTTP 3000 publicly and gRPC 50053 for
`back`. Render web services expose a single port. If `back` cannot reach
map-storage over gRPC, either drop map-storage (set `ENABLE_MAP_EDITOR=false`
and serve maps from a remote URL — `MAP_STORAGE_URL` is optional in `back`) or
move it to a private service and give up the web map editor.

**Deploys are not zero-downtime.** The disk on `map-storage`
[prevents both zero-downtime deploys and horizontal scaling](https://render.com/docs/disks).
Moving map storage to S3 (set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_BUCKET`, `AWS_DEFAULT_REGION`, and `AWS_URL` for a custom endpoint such as
Cloudflare R2) removes the disk and lifts both restrictions.

**These are upstream images.** The fork currently differs from upstream only in
`README.md`, so the published images are functionally identical. Once actual
code changes land, build and push your own images and set `VERSION`/`REGISTRY`
accordingly.
