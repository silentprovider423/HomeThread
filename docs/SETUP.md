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

## 8. Import from Threema (iMazing app extraction)

Threema for iOS keeps its history in a Core Data database inside the app group `group.ch.threema`. With [iMazing](https://imazing.com) you can export the app's data from an iPhone backup ("Export app data" → a `.imazingapp` file, which is a ZIP). The importer reads that file (or an unpacked folder that contains `ThreemaData.sqlite` and `.ThreemaData_SUPPORT/_EXTERNAL_DATA`) **on the server** and writes everything into one account through the server's own operations – the change log is written as usual and every device of that account receives the history with its next sync. No password or authenticator code is needed; it runs inside the container.

```bash
cd server
# 1. copy the export onto the server, readable only for the service user (UID 10001)
install -d -m 700 -o 10001 -g 10001 /srv/threema-import
install -m 600 -o 10001 -g 10001 Threema.imazingapp /srv/threema-import/
# 2. back up the database
docker compose exec app python -m homethread.admin backup /data/before-import.db
# 3. dry run: only counts, nothing is written
docker compose run --rm --no-deps -v /srv/threema-import:/import:ro app \
  python -m homethread.import_threema /import/Threema.imazingapp --user alice
# 4. import (stop the service meanwhile), then check what a freshly signed-in device would receive
docker compose stop app
docker compose run --rm --no-deps -v /srv/threema-import:/import:ro app \
  python -m homethread.import_threema /import/Threema.imazingapp --user alice --apply --verify
docker compose start app
# 5. remove the export again
rm -rf /srv/threema-import
```

`--device <id or name>` (see `admin devices alice`) attributes the imported entries to one of the account's devices, so they don't show up as "new from another device" there – useful when the history was written on that phone. A device that signs in for the first time marks the existing history as seen anyway.

| Threema | HomeThread |
|---|---|
| group, distribution list | group (name, picture, date of the first message) |
| 1:1 chat | chat; the other person's messages appear on the left (they get a fixed placeholder author, no account) |
| text | text with the original date; edited messages are marked as edited (the edit history is not kept) |
| file message: photo, video, voice message, other file | photo (with Threema's thumbnail), video, voice note, file – original file name, size, caption |
| photo whose original was never downloaded | photo made from the stored thumbnail (`preview_only`) |
| file whose data is gone / empty file | file entry without attachment ("No longer available") |
| quote | reply with a link to the quoted entry |
| star, reactions, 👍/👎 acknowledgements | star, reactions |
| poll | poll (options, single/multiple choice, closed; your own vote) |
| location | place |
| pinned / archived conversation | pinned / archived room |
| system messages, deleted messages, calls | skipped |

The importer prints counts only – never message contents, group or file names. All IDs are derived from Threema's IDs, so running it again adds only what is new, and entries you deleted in HomeThread are not brought back. Attachments above `HT_MAX_BLOB_MB` are skipped (counted as `attachment_too_large`).

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
