# Setting up the HomeThread server

The server is small: one Python service (FastAPI + SQLite) for sign-in and sync, and a Caddy in front of it that only lets `/api/…` and `/auth/…` through. Everything runs with Docker Compose from the [`server/`](../server) folder.

## 1. What you need

- A Linux machine or VM/container with Docker and the Compose plugin (1 CPU, 512 MB RAM and a few GB of disk are plenty; attachments need as much space as you store)
- For access from outside your home: a domain and **one** of
  - a tunnel (e.g. Cloudflare Tunnel) – no open ports, TLS at the edge, or
  - a reverse proxy with HTTPS (Caddy, nginx, Traefik) and a forwarded port
- An authenticator app on your phone (e.g. 2FAS, Aegis, Bitwarden, Google Authenticator)

## 2. Start the server

```bash
git clone https://github.com/<you>/homethread.git
cd homethread/server
cp .env.example .env
mkdir -p data && sudo chown 10001:10001 data && chmod 700 data   # the service runs as UID 10001
docker compose up -d --build
curl http://127.0.0.1/api/health          # → {"ok":true,"version":"1.0"}
curl -i http://127.0.0.1/                 # → 404, only /api and /auth exist
```

`.env`:

| Variable | Meaning |
|---|---|
| `HT_TRUSTED_PROXIES` | IP addresses of your tunnel/proxy machine(s), comma separated. Only for requests from these addresses the `Cf-Connecting-Ip` header is trusted as the real visitor address (needed for the per-address lock). Leave empty if nothing sits in front. |
| `HT_MAX_BLOB_MB` | Largest attachment in MB (default 95; Cloudflare's free plan allows 100 MB per request). |
| `HT_LISTEN` | Address Caddy listens on (default `:80`). |

Caddy runs with `network_mode: host` so it sees the real client address; the API container is only published on `127.0.0.1:8080`.

## 3. Create your account

```bash
docker compose exec app python -m homethread.admin add-user alex --display "Alex" --out /data/secrets/alex.json
```

This writes the generated password, the authenticator secret and a QR code (`/data/secrets/alex-totp.png`) **only** into these files (mode 600) – nothing is printed. Copy them somewhere safe, scan the QR code with your authenticator app and then delete them from the server:

```bash
docker compose cp app:/data/secrets/alex.json ./alex.json      # or read them from ./data/secrets/
rm -f data/secrets/*
```

Test or demo accounts that should not appear in the people picker get `--hidden`.

Other admin commands:

```bash
docker compose exec app python -m homethread.admin list-users
docker compose exec app python -m homethread.admin devices alex        # signed-in devices
docker compose exec app python -m homethread.admin revoke-all alex     # sign out every device
docker compose exec app python -m homethread.admin unlock              # lift all sign-in locks
docker compose exec app python -m homethread.admin new-totp alex --out /data/secrets/alex-new.json
docker compose exec app python -m homethread.admin backup /data/backup.db
docker compose exec app python -m homethread.admin gc                  # remove unreferenced uploads older than 7 days
```

## 4. Access from outside

**Cloudflare Tunnel** (no open port): add a public hostname, e.g. `thread.example.org` → `http://<server-ip>:80`, put the IP of the machine running `cloudflared` into `HT_TRUSTED_PROXIES`. Recommended extra rules for this hostname (Security → WAF):

- *Custom rule, Block*: `http.host eq "thread.example.org" and not (starts_with(http.request.uri.path, "/api/") or starts_with(http.request.uri.path, "/auth/"))`
- *Rate limiting*: `/auth/` paths, e.g. 8 requests per 10 s per IP
- Do **not** enable challenges (Bot Fight Mode, JS challenge) for this hostname – the app cannot solve them.

**Own reverse proxy with HTTPS**: forward `https://thread.example.org` to `http://<server-ip>:80` and set `HT_TRUSTED_PROXIES` to the proxy's address only if it sets `Cf-Connecting-Ip`; otherwise leave it empty (Caddy passes the real peer address on its own). Alternatively let the bundled Caddy do HTTPS itself: set `HT_LISTEN=thread.example.org`, remove `auto_https off` from the `Caddyfile` and forward ports 80/443.

Plain `http://` is accepted by the app only for home-network addresses (192.168.x.x, 10.x.x.x, `*.local` …).

## 5. What the server protects against

- Passwords: Argon2id, at least 12 characters; sign-in always needs the authenticator code (one-time, replays rejected)
- 3 failed sign-ins from one address (IPv6: per /64 network) → locked 10 min, doubling up to 24 h
- 10 failed sign-ins within 15 min from **any** addresses → sign-in locked for everyone for 15 min (doubling, max 24 h); devices that are already signed in keep working
- Password reset with the authenticator code: 3 wrong codes → locked 10 min (doubling); a successful reset signs out every device
- Device tokens: 256 bit random, only their SHA-256 is stored; each device can be signed out on its own
- Rate limits per address for `/auth/` and `/api/`, extra limit for invalid tokens
- Only `/api/` and `/auth/` are served, no web interface; security headers, `no-store`, request size limit
- The container runs read-only as an unprivileged user without capabilities

## 6. Backup

Everything lives in `server/data/` (SQLite database `homethread.db` and the uploads in `blobs/`). For a consistent copy of the database while the server runs:

```bash
docker compose exec app python -m homethread.admin backup /data/backup-$(date +%F).db
```

Back up `data/` together with your other backups (the uploads are write-once files).

## 7. Server tests

```bash
cd server && ./run-tests.sh          # starts a throw-away container with a fresh database
```

## API in short

| Method | Path | |
|---|---|---|
| POST | `/auth/login` | `{username, password, code, device_name, platform}` → `{token, device_id, user}` |
| POST | `/auth/reset` | `{username, code, new_password}` |
| POST | `/auth/logout` | sign out this device |
| GET | `/api/me`, `/api/users`, `/api/devices` | account, people on the server, own devices |
| PATCH/DELETE | `/api/devices/{id}` | rename / sign out a device |
| POST | `/api/account/password` | `{current, new, code}` |
| POST | `/api/ops` | `{ops:[{op_id, type, …}]}` – idempotent operations (`room.create`, `msg.create`, `reaction.set`, `vote.set`, `item.update`, …) |
| GET | `/api/sync?since=<seq>&limit=500[&room=<id>]` | changes since a sequence number, tombstones included |
| PUT/GET | `/api/blobs/{id}` | upload/download an attachment |
