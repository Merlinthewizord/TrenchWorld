# Running Trench World free, behind a Cloudflare Tunnel

Runs the whole stack on hardware you already own — a spare laptop, a mini PC, a
Raspberry Pi 4/5 — and publishes it over a free Cloudflare Tunnel. No cloud
bill, no credit card, no public IP, no port forwarding, and no router config.

All four WorkAdventure images publish `linux/amd64` and `linux/arm64`, so ARM
boards work natively.

## Requirements

- Docker with the Compose plugin
- 4GB RAM is comfortable; 2GB works for a handful of players
- A machine that stays on
- For the **named** tunnel only: a free Cloudflare account with a domain on it

## Quick start (no account, no domain)

```console
$ ./contrib/cloudflare-tunnel/start-quick.sh
```

That generates an `.env` with fresh secrets, starts the tunnel, reads the
hostname Cloudflare assigns, writes it back into `.env`, and brings up the rest
of the stack. It prints a `https://<random>.trycloudflare.com` URL you can hand
to anyone.

**The hostname changes every time cloudflared restarts.** Fine for trying it
out or a one-off session; re-run the script to get a new one. For anything
lasting, use a named tunnel.

## Named tunnel (stable hostname)

1. In the Cloudflare dashboard: **Zero Trust → Networks → Tunnels → Create a
   tunnel**, choose *Cloudflared*, and copy the token.
2. Add a **public hostname** to the tunnel pointing at `http://reverse-proxy:80`.
3. Fill in `.env`:

```console
$ cp contrib/cloudflare-tunnel/.env.template contrib/cloudflare-tunnel/.env
$ openssl rand -hex 24        # paste into SECRET_KEY
```

Set `DOMAIN` to your hostname and `CF_TUNNEL_TOKEN` to the token, then:

```console
$ docker compose -f contrib/cloudflare-tunnel/docker-compose.tunnel.yaml \
    --profile named up -d
```

## How this differs from the standard install

`contrib/docker/docker-compose.prod.yaml` terminates TLS itself with Traefik
and LetsEncrypt, which needs inbound 80/443 and a public IP. Here Cloudflare
terminates TLS at the edge and forwards plain HTTP down the tunnel, so:

- Traefik runs HTTP-only. No ACME, no `websecure` entrypoint, no `ACME_EMAIL`.
- Traefik publishes **no host ports at all**. The tunnel is the only way in,
  so nothing is exposed on your LAN or to your ISP.
- The single-hostname path-prefix routing (`/api`, `/uploader`, `/icon`,
  `/map-storage`) is kept exactly as upstream — a tunnel presents one hostname,
  so unlike the Render deployment none of it needs rewriting.

Application URLs stay `https://` because that is what the browser sees.

## What you give up

**Group video is capped at 4 people.** This is the real limitation. WorkAdventure
keeps conversations peer-to-peer up to `MAX_PER_GROUP`; above that it needs
LiveKit, an SFU that requires inbound UDP. Cloudflare Tunnel does not proxy UDP,
so LiveKit cannot run here. Leave `MAX_PER_GROUP=4`.

The upside of P2P: video never touches your machine or your upload bandwidth.
The server only carries game state and signalling, which is light — this is why
modest hardware is fine.

**No TURN server.** Coturn also needs UDP. Most peers connect fine over STUN
alone, but users behind restrictive NATs or corporate firewalls may fail to get
audio/video. Upstream estimates roughly 15% without TURN. If that bites, point
`TURN_SERVER` at a hosted TURN provider — several have free tiers.

**No Matrix.** Synapse is not included, so chat works inside proximity bubbles
but is not persisted and there is no offline messaging.

**Uploads are capped at 100MB** by Cloudflare's free plan, whatever
`UPLOAD_MAX_FILESIZE` says. Files go to Redis rather than S3; set the `AWS_*`
variables on the uploader service to move them to a bucket.

## If you outgrow it

Only the video cap is a hard ceiling, and it is not fixable behind a tunnel.
For unlimited group sizes you need inbound UDP, which means a real VM — an
Oracle Cloud Always Free ARM instance (2 OCPU / 12GB, permanent) runs
`docker-compose.prod.yaml` unmodified, LiveKit and Coturn included, still at no
cost. Alternatively keep this setup and point `LIVEKIT_HOST` at LiveKit Cloud,
whose free tier also provides TURN.

## Notes

`.env` holds your secrets and is gitignored. Keep `SECRET_KEY` stable —
rotating it invalidates every issued JWT and orphans stored player variables.

The images are upstream builds. The fork currently differs from upstream only
in `README.md`, so they are functionally identical; once real code changes land
you will need to build and push your own and set `VERSION`.
