"""HomeThread-Server: Anmelde-Gate (Passwort + Authenticator → Geräte-Token) und Sync-API.

Öffentlich sind nur /auth/… und /api/…; alles andere beantwortet schon der vorgeschaltete Caddy mit 404.
Alle Änderungen kommen als Operationen über POST /api/ops (idempotent per op-ID, damit eine
Offline-Warteschlange gefahrlos wiederholen darf). Abholen per GET /api/sync?since=<seq>.
"""
import hashlib
import ipaddress
import json
import logging
import os
import re
import time
import uuid

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from .db import DB, dumps
from . import security as sec

VERSION = "1.0"
DATA = os.environ.get("HT_DATA", "/data")
BLOBS = os.path.join(DATA, "blobs")
MAX_BLOB = int(os.environ.get("HT_MAX_BLOB_MB", "95")) * 1024 * 1024
TRUSTED_PROXIES = {p.strip() for p in os.environ.get("HT_TRUSTED_PROXIES", "").split(",") if p.strip()}
KINDS = {"text", "voice", "image", "video", "file", "location", "poll", "checklist"}
ROOM_KINDS = {"chat", "group"}
ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")

log = logging.getLogger("homethread")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

os.makedirs(BLOBS, exist_ok=True)
db = DB(os.path.join(DATA, "homethread.db"))
locks = sec.Locks(db)
limiter = sec.RateLimiter()

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


# ---------------------------------------------------------------- Hilfen

def err(status, code, **extra):
    headers = {"WWW-Authenticate": "Bearer"} if status == 401 else None
    if "retry_after" in extra:
        headers = {"Retry-After": str(extra["retry_after"])}
    return JSONResponse({"error": code, **extra}, status_code=status, headers=headers)


class ApiError(Exception):
    def __init__(self, status, code, **extra):
        self.status, self.code, self.extra = status, code, extra


@app.exception_handler(ApiError)
def _api_error(_req, e: ApiError):
    return err(e.status, e.code, **e.extra)


def _private(ip):
    try:
        a = ipaddress.ip_address(ip)
        return a.is_private or a.is_loopback
    except ValueError:
        return False


def client_ip(req: Request):
    """Echte Gegenstelle: Caddy setzt X-Real-Peer (fremde Werte überschreibt er). Nur wenn diese Gegenstelle
    ein eingetragener Tunnel-Rechner ist, wird Cf-Connecting-Ip geglaubt – sonst könnte sich jeder eine
    neue Adresse pro Versuch ausdenken."""
    peer = req.client.host if req.client else "?"
    if _private(peer):
        peer = req.headers.get("x-real-peer", peer).strip() or peer
    if peer in TRUSTED_PROXIES:
        cf = req.headers.get("cf-connecting-ip", "").strip()
        if cf:
            return cf
    return peer


def now():
    return time.time()


def new_id():
    return str(uuid.uuid4())


def check_id(v, what="id"):
    if not isinstance(v, str) or not ID_RE.match(v):
        raise ApiError(400, "bad_" + what)
    return v.lower()


def text(v, maxlen, what):
    if v is None:
        return None
    if not isinstance(v, str) or len(v) > maxlen:
        raise ApiError(400, "bad_" + what)
    return v


# ---------------------------------------------------------------- Ratenbegrenzung

@app.middleware("http")
async def _rate(request: Request, call_next):
    path = request.url.path
    if not (path.startswith("/api/") or path.startswith("/auth/")):
        return err(404, "not_found")
    ip = sec.ip_key(client_ip(request))
    if path.startswith("/auth/"):
        ok = limiter.allow("auth:" + ip, 12, 6)
    else:
        ok = limiter.allow("api:" + ip, 600, 120)
    if not ok:
        return err(429, "rate_limited", retry_after=10)
    resp = await call_next(request)
    resp.headers["Cache-Control"] = "no-store"
    return resp


# ---------------------------------------------------------------- Anmeldung

class LoginIn(BaseModel):
    username: str = Field(max_length=64)
    password: str = Field(max_length=256)
    code: str = Field(default="", max_length=12)
    device_name: str = Field(default="Gerät", max_length=80)
    platform: str = Field(default="", max_length=20)


class ResetIn(BaseModel):
    username: str = Field(max_length=64)
    code: str = Field(max_length=12)
    new_password: str = Field(max_length=256)


class PasswordIn(BaseModel):
    current: str = Field(max_length=256)
    new: str = Field(max_length=256)
    code: str = Field(max_length=12)


def user_public(u):
    return {"id": u["id"], "username": u["username"], "display_name": u["display_name"],
            "color": u["color"], "avatar": u["avatar"]}


@app.get("/api/health")
def health():
    return {"ok": True, "version": VERSION}


@app.post("/auth/login")
def login(body: LoginIn, request: Request):
    ip = client_ip(request)
    key = "ip:" + sec.ip_key(ip)
    g = locks.remain("global:login")
    if g:
        return err(429, "locked", retry_after=g, scope="global")
    r = locks.remain(key)
    if r:
        return err(429, "locked", retry_after=r, scope="address")
    u = db.one("SELECT * FROM users WHERE username=? AND disabled=0", (body.username.strip().lower(),))
    ok = sec.verify_pw(body.password, u["pw_hash"] if u else None)
    if ok:
        # Ohne eingerichteten Authenticator gibt es keine Anmeldung von außen
        c = sec.totp_check(u["totp_secret"], body.code, u["totp_last"]) if u["totp_secret"] else None
        if c is None:
            ok = False
        else:
            db.x("UPDATE users SET totp_last=? WHERE id=?", (c, u["id"]))
    if not ok:
        locks.fail_window("global:login", sec.GLOBAL_WINDOW, sec.GLOBAL_MAX, sec.GLOBAL_LOCK)
        left, lock = locks.fail(key, sec.IP_MAX, sec.IP_LOCK)
        log.warning("login fehlgeschlagen von %s (noch %s, Sperre %s s)", ip, left, lock)
        if lock:
            return err(429, "locked", retry_after=lock, scope="address")
        return err(401, "invalid", left=left)
    locks.clear(key)
    locks.clear_window("global:login")
    tok = sec.new_token()
    did = new_id()
    db.x("INSERT INTO devices(id, user_id, name, platform, token_hash, created, last_seen, last_ip) VALUES(?,?,?,?,?,?,?,?)",
         (did, u["id"], body.device_name.strip() or "Gerät", body.platform, sec.token_hash(tok), now(), now(), ip))
    log.info("login ok %s Gerät %s von %s", u["username"], did, ip)
    return {"token": tok, "device_id": did, "user": user_public(u)}


@app.post("/auth/reset")
def reset(body: ResetIn, request: Request):
    """Passwort mit dem Authenticator-Code neu setzen. Danach sind alle Geräte abgemeldet."""
    ip = client_ip(request)
    r = locks.remain("global:reset")
    if r:
        return err(429, "locked", retry_after=r, scope="global")
    if len(body.new_password) < sec.MIN_PASSWORD:
        return err(400, "weak_password", min=sec.MIN_PASSWORD)
    with db.lock:
        u = db.one("SELECT * FROM users WHERE username=? AND disabled=0", (body.username.strip().lower(),))
        c = sec.totp_check(u["totp_secret"], body.code, u["totp_last"]) if u and u["totp_secret"] else None
        if c is None:
            left, lock = locks.fail("global:reset", sec.RESET_MAX, sec.RESET_LOCK)
            log.warning("reset fehlgeschlagen von %s", ip)
            if lock:
                return err(429, "locked", retry_after=lock, scope="global")
            return err(401, "invalid", left=left)
        db.x("UPDATE users SET pw_hash=?, totp_last=? WHERE id=?", (sec.hash_pw(body.new_password), c, u["id"]))
        db.x("UPDATE devices SET revoked=? WHERE user_id=? AND revoked IS NULL", (now(), u["id"]))
        locks.clear("global:reset")
        locks.clear("ip:" + sec.ip_key(ip))
        locks.clear("global:login")
    log.info("reset ok %s von %s", u["username"], ip)
    return {"ok": True}


def auth(request: Request):
    h = request.headers.get("authorization", "")
    tok = h[7:].strip() if h.lower().startswith("bearer ") else ""
    ip = client_ip(request)
    if tok:
        d = db.one("""SELECT d.id AS device_id, d.last_seen, u.* FROM devices d JOIN users u ON u.id=d.user_id
                      WHERE d.token_hash=? AND d.revoked IS NULL AND u.disabled=0""", (sec.token_hash(tok),))
        if d:
            if now() - (d["last_seen"] or 0) > 60:
                db.x("UPDATE devices SET last_seen=?, last_ip=? WHERE id=?", (now(), ip, d["device_id"]))
            return d
    # Falsche Token kosten zusätzlich: 30 je 10 Min und Adresse, danach 429
    if not limiter.allow("badtoken:" + sec.ip_key(ip), 3, 30):
        raise ApiError(429, "rate_limited", retry_after=60)
    raise ApiError(401, "unauthorized")


@app.post("/auth/logout")
def logout(me=Depends(auth)):
    db.x("UPDATE devices SET revoked=? WHERE id=?", (now(), me["device_id"]))
    return {"ok": True}


@app.get("/api/me")
def me_get(me=Depends(auth)):
    return {"user": user_public(me), "device_id": me["device_id"], "server_seq": db.max_seq(), "version": VERSION}


@app.post("/api/account/password")
def change_password(body: PasswordIn, request: Request, me=Depends(auth)):
    key = "pw:" + me["id"]
    r = locks.remain(key)
    if r:
        return err(429, "locked", retry_after=r)
    if len(body.new) < sec.MIN_PASSWORD:
        return err(400, "weak_password", min=sec.MIN_PASSWORD)
    u = db.one("SELECT * FROM users WHERE id=?", (me["id"],))
    c = sec.totp_check(u["totp_secret"], body.code, u["totp_last"])
    if not sec.verify_pw(body.current, u["pw_hash"]) or c is None:
        left, lock = locks.fail(key, sec.IP_MAX, sec.IP_LOCK)
        return err(429, "locked", retry_after=lock) if lock else err(401, "invalid", left=left)
    db.x("UPDATE users SET pw_hash=?, totp_last=? WHERE id=?", (sec.hash_pw(body.new), c, me["id"]))
    # Alle anderen Geräte abmelden, dieses bleibt angemeldet
    db.x("UPDATE devices SET revoked=? WHERE user_id=? AND id<>? AND revoked IS NULL", (now(), me["id"], me["device_id"]))
    locks.clear(key)
    return {"ok": True}


@app.get("/api/devices")
def devices(me=Depends(auth)):
    rows = db.q("SELECT id, name, platform, created, last_seen, last_ip FROM devices WHERE user_id=? AND revoked IS NULL "
                "ORDER BY last_seen DESC", (me["id"],))
    for r in rows:
        r["current"] = r["id"] == me["device_id"]
    return {"devices": rows}


class DeviceIn(BaseModel):
    name: str = Field(max_length=80)


@app.patch("/api/devices/{did}")
def device_rename(did: str, body: DeviceIn, me=Depends(auth)):
    cur = db.x("UPDATE devices SET name=? WHERE id=? AND user_id=? AND revoked IS NULL", (body.name.strip(), did, me["id"]))
    if not cur.rowcount:
        raise ApiError(404, "not_found")
    return {"ok": True}


@app.delete("/api/devices/{did}")
def device_revoke(did: str, me=Depends(auth)):
    cur = db.x("UPDATE devices SET revoked=? WHERE id=? AND user_id=? AND revoked IS NULL", (now(), did, me["id"]))
    if not cur.rowcount:
        raise ApiError(404, "not_found")
    return {"ok": True}


@app.get("/api/users")
def users(me=Depends(auth)):
    rows = db.q("SELECT * FROM users WHERE disabled=0 AND (hidden=0 OR id=?) ORDER BY display_name", (me["id"],))
    return {"users": [user_public(u) for u in rows]}


# ---------------------------------------------------------------- Anhänge

def blob_path(bid):
    return os.path.join(BLOBS, bid[:2], bid)


@app.put("/api/blobs/{bid}")
async def blob_put(bid: str, request: Request, me=Depends(auth)):
    bid = check_id(bid)
    ex = db.one("SELECT * FROM blobs WHERE id=?", (bid,))
    if ex:
        if ex["owner_id"] != me["id"]:
            raise ApiError(409, "exists")
        return {"id": bid, "size": ex["size"], "sha256": ex["sha256"]}
    mime = (request.headers.get("content-type") or "application/octet-stream")[:100]
    from urllib.parse import unquote
    filename = unquote(request.headers.get("x-filename", ""))[:200].replace("/", "_")
    p = blob_path(bid)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".part"
    h = hashlib.sha256()
    size = 0
    with open(tmp, "wb") as f:
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_BLOB:
                f.close()
                os.remove(tmp)
                raise ApiError(413, "too_large", max=MAX_BLOB)
            h.update(chunk)
            f.write(chunk)
    want = request.headers.get("x-sha256", "").lower()
    if want and want != h.hexdigest():
        os.remove(tmp)
        raise ApiError(422, "checksum")
    os.replace(tmp, p)
    db.x("INSERT INTO blobs(id, owner_id, mime, size, sha256, filename, created) VALUES(?,?,?,?,?,?,?)",
         (bid, me["id"], mime, size, h.hexdigest(), filename, now()))
    return {"id": bid, "size": size, "sha256": h.hexdigest()}


def save_blob(bid, owner_id, data, mime, filename=""):
    """Anhang direkt auf dem Server ablegen (Importe); gleiche Ablage wie PUT /api/blobs. Gibt es die ID schon,
    bleibt alles, wie es ist."""
    bid = check_id(bid)
    if db.one("SELECT 1 FROM blobs WHERE id=?", (bid,)):
        return bid
    p = blob_path(bid)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".part", "wb") as f:
        f.write(data)
    os.replace(p + ".part", p)
    db.x("INSERT INTO blobs(id, owner_id, mime, size, sha256, filename, created) VALUES(?,?,?,?,?,?,?)",
         (bid, owner_id, (mime or "application/octet-stream")[:100], len(data), hashlib.sha256(data).hexdigest(),
          (filename or "")[:200].replace("/", "_"), now()))
    return bid


def my_room_ids(uid):
    return {r["room_id"] for r in db.q("SELECT room_id FROM members WHERE user_id=? AND removed=0", (uid,))}


@app.get("/api/blobs/{bid}")
def blob_get(bid: str, me=Depends(auth)):
    bid = check_id(bid)
    b = db.one("SELECT * FROM blobs WHERE id=?", (bid,))
    if not b or not os.path.exists(blob_path(bid)):
        raise ApiError(404, "not_found")
    if b["owner_id"] != me["id"]:
        rooms = my_room_ids(me["id"])
        refs = db.q("SELECT room_id FROM messages WHERE (attachment=? OR thumb=?) AND deleted=0", (bid, bid)) + \
            db.q("SELECT id AS room_id FROM rooms WHERE avatar=? AND deleted=0", (bid,))
        if not any(r["room_id"] in rooms for r in refs) and \
                not db.one("SELECT 1 FROM users WHERE avatar=?", (bid,)):
            raise ApiError(404, "not_found")
    return FileResponse(blob_path(bid), media_type=b["mime"], headers={"Cache-Control": "private, max-age=31536000"})


def blob_ok(bid, uid):
    if bid is None:
        return None
    bid = check_id(bid, "blob")
    b = db.one("SELECT owner_id FROM blobs WHERE id=?", (bid,))
    if not b:
        raise ApiError(409, "blob_missing", blob=bid)
    return bid


def drop_blob(bid):
    """Datei weg, wenn nichts mehr darauf zeigt (gelöschte Einträge geben ihren Anhang sofort frei)."""
    if not bid:
        return
    if db.one("SELECT 1 FROM messages WHERE (attachment=? OR thumb=?) AND deleted=0", (bid, bid)) or \
            db.one("SELECT 1 FROM rooms WHERE avatar=? AND deleted=0", (bid,)) or \
            db.one("SELECT 1 FROM users WHERE avatar=?", (bid,)):
        return
    try:
        os.remove(blob_path(bid))
    except FileNotFoundError:
        pass
    db.x("DELETE FROM blobs WHERE id=?", (bid,))


# ---------------------------------------------------------------- Operationen

class OpsIn(BaseModel):
    ops: list[dict] = Field(max_length=200)


def member(room_id, uid):
    m = db.one("SELECT m.role FROM members m JOIN rooms r ON r.id=m.room_id "
               "WHERE m.room_id=? AND m.user_id=? AND m.removed=0 AND r.deleted=0", (room_id, uid))
    if not m:
        raise ApiError(403, "not_member")
    return m["role"]


def message_for(mid, uid):
    m = db.one("SELECT * FROM messages WHERE id=?", (check_id(mid, "message"),))
    if not m:
        raise ApiError(404, "message_missing")
    member(m["room_id"], uid)
    return m


def set_member(room_id, uid, role, removed=0):
    seq = db.change("member", f"{room_id}|{uid}", room_id, about_user=uid)
    db.x("INSERT INTO members(room_id, user_id, role, added_at, removed, seq) VALUES(?,?,?,?,?,?) "
         "ON CONFLICT(room_id, user_id) DO UPDATE SET role=excluded.role, removed=excluded.removed, seq=excluded.seq",
         (room_id, uid, role, now(), removed, seq))


def touch_room(room_id):
    seq = db.change("room", room_id, room_id)
    db.x("UPDATE rooms SET updated_at=?, seq=? WHERE id=?", (now(), seq, room_id))


def op_room_create(o, me):
    r = o.get("room") or {}
    rid = check_id(r.get("id"), "room")
    if db.one("SELECT 1 FROM rooms WHERE id=?", (rid,)):
        raise ApiError(409, "exists")
    kind = r.get("kind", "chat")
    if kind not in ROOM_KINDS:
        raise ApiError(400, "bad_kind")
    title = (text(r.get("title"), 200, "title") or "").strip()
    if not title:
        raise ApiError(400, "bad_title")
    avatar = blob_ok(r.get("avatar"), me["id"])
    about = text(r.get("about", ""), 2000, "about") or ""
    seq = db.change("room", rid, rid)
    t = float(r.get("created_at") or now())
    db.x("INSERT INTO rooms(id, kind, title, avatar, about, created_by, created_at, updated_at, seq) VALUES(?,?,?,?,?,?,?,?,?)",
         (rid, kind, title, avatar, about, me["id"], t, now(), seq))
    set_member(rid, me["id"], "owner")
    for uid in r.get("members") or []:
        if uid != me["id"] and db.one("SELECT 1 FROM users WHERE id=? AND disabled=0", (uid,)):
            set_member(rid, uid, "member")


def op_room_update(o, me):
    rid = check_id(o.get("room_id"), "room")
    member(rid, me["id"])
    room = db.one("SELECT * FROM rooms WHERE id=?", (rid,))
    title = room["title"]
    if "title" in o:
        title = (text(o["title"], 200, "title") or "").strip() or title
    avatar = room["avatar"]
    if "avatar" in o:
        avatar = blob_ok(o["avatar"], me["id"]) if o["avatar"] else None
    about = text(o["about"], 2000, "about") if "about" in o else room["about"]
    kind = o.get("kind", room["kind"])
    if kind not in ROOM_KINDS:
        raise ApiError(400, "bad_kind")
    db.x("UPDATE rooms SET title=?, avatar=?, about=?, kind=? WHERE id=?", (title, avatar, about, kind, rid))
    touch_room(rid)
    if room["avatar"] and room["avatar"] != avatar:
        drop_blob(room["avatar"])


def op_room_delete(o, me):
    rid = check_id(o.get("room_id"), "room")
    if member(rid, me["id"]) != "owner":
        raise ApiError(403, "not_owner")
    room = db.one("SELECT avatar FROM rooms WHERE id=?", (rid,))
    msgs = db.q("SELECT id, attachment, thumb FROM messages WHERE room_id=? AND deleted=0", (rid,))
    db.x("UPDATE rooms SET deleted=1, title='', about='', avatar=NULL WHERE id=?", (rid,))
    touch_room(rid)
    # Inhalte wirklich entfernen (Grabsteine bleiben für den Abgleich)
    for m in msgs:
        delete_message(m)
    drop_blob(room["avatar"])


def op_room_clear(o, me):
    """Alle Einträge des Raums löschen, der Raum bleibt."""
    rid = check_id(o.get("room_id"), "room")
    member(rid, me["id"])
    for m in db.q("SELECT id, attachment, thumb FROM messages WHERE room_id=? AND deleted=0", (rid,)):
        delete_message(m)
    touch_room(rid)


def op_member_add(o, me):
    rid = check_id(o.get("room_id"), "room")
    if member(rid, me["id"]) != "owner":
        raise ApiError(403, "not_owner")
    uid = o.get("user_id")
    if not db.one("SELECT 1 FROM users WHERE id=? AND disabled=0", (uid,)):
        raise ApiError(404, "user_missing")
    if uid != me["id"]:
        set_member(rid, uid, "member")


def op_member_remove(o, me):
    rid = check_id(o.get("room_id"), "room")
    role = member(rid, me["id"])
    uid = o.get("user_id")
    if uid != me["id"] and role != "owner":
        raise ApiError(403, "not_owner")
    if uid == me["id"] and role == "owner":
        raise ApiError(400, "owner_cannot_leave")
    if db.one("SELECT 1 FROM members WHERE room_id=? AND user_id=? AND removed=0", (rid, uid)):
        set_member(rid, uid, "member", removed=1)


def clean_payload(kind, p):
    if not isinstance(p, dict):
        raise ApiError(400, "bad_payload")
    if len(dumps(p)) > 32768:
        raise ApiError(413, "payload_too_large")
    if kind == "poll":
        opts = p.get("options")
        if not isinstance(opts, list) or not (1 <= len(opts) <= 50):
            raise ApiError(400, "bad_poll")
        ids = set()
        for x in opts:
            if not isinstance(x, dict) or not isinstance(x.get("id"), str) or not isinstance(x.get("text"), str):
                raise ApiError(400, "bad_poll")
            ids.add(x["id"])
        if len(ids) != len(opts):
            raise ApiError(400, "bad_poll")
        p["closed"] = bool(p.get("closed", False))
    if kind == "location":
        try:
            lat, lon = float(p["lat"]), float(p["lon"])
        except (KeyError, TypeError, ValueError):
            raise ApiError(400, "bad_location")
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ApiError(400, "bad_location")
    return p


def op_msg_create(o, me, *, author=None, touch=True):
    """author/touch nur für Importe auf dem Server: Eintrag einer anderen Person zuordnen (z. B. die Gegenseite
    eines importierten Einzelchats) bzw. den Raum erst nach dem letzten Eintrag einmal anstoßen."""
    m = o.get("msg") or {}
    mid = check_id(m.get("id"), "message")
    if db.one("SELECT 1 FROM messages WHERE id=?", (mid,)):
        raise ApiError(409, "exists")
    rid = check_id(m.get("room_id"), "room")
    member(rid, me["id"])
    kind = m.get("kind", "text")
    if kind not in KINDS:
        raise ApiError(400, "bad_kind")
    body = text(m.get("body", ""), 65536, "body") or ""
    payload = clean_payload(kind, m.get("payload") or {})
    reply = check_id(m["reply_to"], "reply") if m.get("reply_to") else None
    att = blob_ok(m.get("attachment"), me["id"])
    thumb = blob_ok(m.get("thumb"), me["id"])
    seq = db.change("message", mid, rid)
    db.x("INSERT INTO messages(id, room_id, author_id, device_id, kind, body, payload, reply_to, attachment, thumb, "
         "created_at, server_at, seq) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
         (mid, rid, author or me["id"], me["device_id"], kind, body, dumps(payload), reply, att, thumb,
          float(m.get("created_at") or now()), now(), seq))
    for i, it in enumerate(m.get("items") or []):
        add_item({"id": it.get("id"), "message_id": mid, "text": it.get("text", ""),
                  "position": it.get("position", i), "done": it.get("done", False)}, me, rid)
    if touch:
        touch_room(rid)


def op_msg_edit(o, me):
    m = message_for(o.get("id"), me["id"])
    if m["author_id"] != me["id"]:
        raise ApiError(403, "not_author")
    if m["deleted"]:
        raise ApiError(410, "deleted")
    body = text(o["body"], 65536, "body") if "body" in o else m["body"]
    payload = json.loads(m["payload"])
    if "payload" in o:
        payload = clean_payload(m["kind"], o["payload"] or {})
        if m["kind"] == "poll":
            payload["closed"] = json.loads(m["payload"]).get("closed", False) or payload["closed"]
    seq = db.change("message", m["id"], m["room_id"])
    db.x("UPDATE messages SET body=?, payload=?, edited_at=?, seq=? WHERE id=?",
         (body, dumps(payload), now(), seq, m["id"]))


def delete_message(m):
    full = db.one("SELECT * FROM messages WHERE id=?", (m["id"],))
    seq = db.change("message", m["id"], full["room_id"])
    db.x("UPDATE messages SET deleted=1, body='', payload='{}', attachment=NULL, thumb=NULL, pinned=0, seq=? WHERE id=?",
         (seq, m["id"]))
    for it in db.q("SELECT id FROM items WHERE message_id=? AND deleted=0", (m["id"],)):
        s2 = db.change("item", it["id"], full["room_id"])
        db.x("UPDATE items SET deleted=1, text='', seq=? WHERE id=?", (s2, it["id"]))
    drop_blob(full["attachment"])
    drop_blob(full["thumb"])


def op_msg_delete(o, me):
    m = message_for(o.get("id"), me["id"])
    if m["deleted"]:
        return
    if m["author_id"] != me["id"] and member(m["room_id"], me["id"]) != "owner":
        raise ApiError(403, "not_author")
    delete_message(m)
    touch_room(m["room_id"])


def op_msg_pin(o, me):
    m = message_for(o.get("id"), me["id"])
    if m["deleted"]:
        return
    seq = db.change("message", m["id"], m["room_id"])
    db.x("UPDATE messages SET pinned=?, seq=? WHERE id=?", (1 if o.get("pinned") else 0, seq, m["id"]))


def op_reaction(o, me):
    m = message_for(o.get("message_id"), me["id"])
    emoji = text(o.get("emoji"), 16, "emoji")
    if not emoji:
        raise ApiError(400, "bad_emoji")
    seq = db.change("reaction", f"{m['id']}|{me['id']}|{emoji}", m["room_id"])
    db.x("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, active, room_id, seq) VALUES(?,?,?,?,?,?)",
         (m["id"], me["id"], emoji, 1 if o.get("on", True) else 0, m["room_id"], seq))


def op_star(o, me):
    m = message_for(o.get("message_id"), me["id"])
    seq = db.change("star", f"{m['id']}|{me['id']}", m["room_id"], scope_user=me["id"])
    db.x("INSERT OR REPLACE INTO stars(message_id, user_id, active, room_id, seq) VALUES(?,?,?,?,?)",
         (m["id"], me["id"], 1 if o.get("on", True) else 0, m["room_id"], seq))


def op_vote(o, me):
    m = message_for(o.get("message_id"), me["id"])
    if m["kind"] != "poll" or m["deleted"]:
        raise ApiError(400, "not_poll")
    p = json.loads(m["payload"])
    if p.get("closed"):
        raise ApiError(409, "poll_closed")
    valid = {x["id"] for x in p.get("options", [])}
    ch = o.get("choices") or []
    if not isinstance(ch, list) or any(c not in valid for c in ch) or len(set(ch)) != len(ch):
        raise ApiError(400, "bad_choice")
    if not p.get("multi") and len(ch) > 1:
        raise ApiError(400, "single_choice")
    seq = db.change("vote", f"{m['id']}|{me['id']}", m["room_id"])
    db.x("INSERT OR REPLACE INTO votes(message_id, user_id, choices, room_id, seq) VALUES(?,?,?,?,?)",
         (m["id"], me["id"], dumps(ch), m["room_id"], seq))


def op_poll_close(o, me):
    m = message_for(o.get("message_id"), me["id"])
    if m["kind"] != "poll":
        raise ApiError(400, "not_poll")
    if m["author_id"] != me["id"] and member(m["room_id"], me["id"]) != "owner":
        raise ApiError(403, "not_author")
    p = json.loads(m["payload"])
    p["closed"] = True
    p["closed_at"] = now()
    seq = db.change("message", m["id"], m["room_id"])
    db.x("UPDATE messages SET payload=?, seq=? WHERE id=?", (dumps(p), seq, m["id"]))


def add_item(o, me, room_id=None):
    iid = check_id(o.get("id"), "item")
    if db.one("SELECT 1 FROM items WHERE id=?", (iid,)):
        raise ApiError(409, "exists")
    if room_id is None:
        m = message_for(o.get("message_id"), me["id"])
        if m["kind"] != "checklist" or m["deleted"]:
            raise ApiError(400, "not_checklist")
        room_id = m["room_id"]
    seq = db.change("item", iid, room_id)
    db.x("INSERT INTO items(id, message_id, room_id, text, done, done_by, position, seq) VALUES(?,?,?,?,?,?,?,?)",
         (iid, o.get("message_id"), room_id, text(o.get("text", ""), 2000, "text") or "", 1 if o.get("done") else 0,
          me["id"] if o.get("done") else None, float(o.get("position") or 0), seq))


def op_item_add(o, me):
    add_item(o, me)


def op_item_update(o, me):
    it = db.one("SELECT * FROM items WHERE id=?", (check_id(o.get("id"), "item"),))
    if not it:
        raise ApiError(404, "item_missing")
    member(it["room_id"], me["id"])
    if it["deleted"]:
        return
    t = text(o["text"], 2000, "text") if "text" in o else it["text"]
    done = (1 if o["done"] else 0) if "done" in o else it["done"]
    done_by = (me["id"] if done else None) if "done" in o else it["done_by"]
    pos = float(o["position"]) if "position" in o else it["position"]
    deleted = 1 if o.get("deleted") else 0
    seq = db.change("item", it["id"], it["room_id"])
    db.x("UPDATE items SET text=?, done=?, done_by=?, position=?, deleted=?, seq=? WHERE id=?",
         ("" if deleted else t, done, done_by, pos, deleted, seq, it["id"]))


def op_roomstate(o, me):
    rid = check_id(o.get("room_id"), "room")
    member(rid, me["id"])
    cur = db.one("SELECT * FROM roomstate WHERE room_id=? AND user_id=?", (rid, me["id"])) or \
        {"pinned": 0, "archived": 0, "muted": 0}
    vals = {k: (1 if o[k] else 0) if k in o else cur[k] for k in ("pinned", "archived", "muted")}
    seq = db.change("roomstate", f"{rid}|{me['id']}", rid, scope_user=me["id"])
    db.x("INSERT OR REPLACE INTO roomstate(room_id, user_id, pinned, archived, muted, seq) VALUES(?,?,?,?,?,?)",
         (rid, me["id"], vals["pinned"], vals["archived"], vals["muted"], seq))


OPS = {
    "room.create": op_room_create, "room.update": op_room_update, "room.delete": op_room_delete,
    "room.clear": op_room_clear, "member.add": op_member_add, "member.remove": op_member_remove,
    "msg.create": op_msg_create, "msg.edit": op_msg_edit, "msg.delete": op_msg_delete, "msg.pin": op_msg_pin,
    "reaction.set": op_reaction, "star.set": op_star, "vote.set": op_vote, "poll.close": op_poll_close,
    "item.add": op_item_add, "item.update": op_item_update, "roomstate.set": op_roomstate,
}


@app.post("/api/ops")
def ops(body: OpsIn, me=Depends(auth)):
    """Wendet die Operationen der Reihe nach an. Jede ist einzeln atomar; eine schon bekannte op-ID liefert
    das gespeicherte Ergebnis (Wiederholung nach Verbindungsabbruch ist ungefährlich)."""
    results = []
    for o in body.ops:
        oid = o.get("op_id")
        if not isinstance(oid, str) or not ID_RE.match(oid):
            results.append({"op_id": oid, "ok": False, "error": "bad_op_id"})
            continue
        prev = db.one("SELECT result FROM ops WHERE user_id=? AND op_id=?", (me["id"], oid))
        if prev:
            results.append(json.loads(prev["result"]))
            continue
        fn = OPS.get(o.get("type"))
        try:
            if not fn:
                raise ApiError(400, "bad_type")
            with db.tx():
                fn(o, me)
                res = {"op_id": oid, "ok": True}
                db.x("INSERT INTO ops(op_id, user_id, applied, result) VALUES(?,?,?,?)", (oid, me["id"], now(), dumps(res)))
        except ApiError as e:
            res = {"op_id": oid, "ok": False, "error": e.code, **e.extra}
            # Dauerhafte Fehler merken, damit das Gerät sie nicht endlos wiederholt; fehlender Anhang ist vorübergehend
            if e.code != "blob_missing":
                db.x("INSERT OR REPLACE INTO ops(op_id, user_id, applied, result) VALUES(?,?,?,?)",
                     (oid, me["id"], now(), dumps(res)))
        results.append(res)
    return {"results": results, "seq": db.max_seq()}


# ---------------------------------------------------------------- Abgleich

def load(kind, ref):
    if kind == "room":
        r = db.one("SELECT * FROM rooms WHERE id=?", (ref,))
    elif kind == "member":
        a, b = ref.split("|")
        r = db.one("SELECT m.*, u.display_name, u.username, u.color, u.avatar AS user_avatar FROM members m "
                   "LEFT JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id=?", (a, b))
    elif kind == "message":
        r = db.one("SELECT * FROM messages WHERE id=?", (ref,))
        if r:
            r["payload"] = json.loads(r["payload"] or "{}")
    elif kind == "reaction":
        a, b, c = ref.split("|", 2)
        r = db.one("SELECT * FROM reactions WHERE message_id=? AND user_id=? AND emoji=?", (a, b, c))
    elif kind == "star":
        a, b = ref.split("|")
        r = db.one("SELECT * FROM stars WHERE message_id=? AND user_id=?", (a, b))
    elif kind == "vote":
        a, b = ref.split("|")
        r = db.one("SELECT * FROM votes WHERE message_id=? AND user_id=?", (a, b))
        if r:
            r["choices"] = json.loads(r["choices"] or "[]")
    elif kind == "item":
        r = db.one("SELECT * FROM items WHERE id=?", (ref,))
    elif kind == "roomstate":
        a, b = ref.split("|")
        r = db.one("SELECT * FROM roomstate WHERE room_id=? AND user_id=?", (a, b))
    else:
        r = None
    return r


@app.get("/api/sync")
def sync(since: int = 0, limit: int = 500, room: str | None = None, me=Depends(auth)):
    limit = max(1, min(limit, 1000))
    top = db.max_seq()
    uid = me["id"]
    if room:
        rid = check_id(room, "room")
        member(rid, uid)
        rows = db.q("SELECT * FROM changes WHERE seq>? AND seq<=? AND room_id=? AND (scope_user IS NULL OR scope_user=?) "
                    "ORDER BY seq LIMIT ?", (since, top, rid, uid, limit + 1))
    else:
        rows = db.q(
            "SELECT * FROM changes WHERE seq>? AND seq<=? AND ("
            " scope_user=? OR (scope_user IS NULL AND (about_user=? OR room_id IN "
            "  (SELECT room_id FROM members WHERE user_id=? AND removed=0))))"
            " ORDER BY seq LIMIT ?", (since, top, uid, uid, uid, limit + 1))
    more = len(rows) > limit
    rows = rows[:limit]
    out = []
    for c in rows:
        e = load(c["kind"], c["ref"])
        # Nur den neuesten Stand schicken; ältere Zeilen desselben Objekts überspringen
        if e is None or e.get("seq") != c["seq"]:
            continue
        out.append({"seq": c["seq"], "kind": c["kind"], "data": e})
    nxt = rows[-1]["seq"] if more else max(top, since)
    return {"changes": out, "next": nxt, "more": more, "server_time": now()}
