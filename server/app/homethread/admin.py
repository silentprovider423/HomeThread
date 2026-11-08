"""Verwaltung auf dem Server (nur per `docker compose exec`, nie über das Netz).

  python -m homethread.admin add-user <name> --display "Name" --out /data/secrets/<name>.json [--hidden]
      legt ein Konto mit zufälligem Passwort und Authenticator-Geheimnis an. Zugangsdaten und QR-Code
      landen NUR in der Ausgabedatei (chmod 600) – nie auf dem Bildschirm oder im Log.
  python -m homethread.admin list-users
  python -m homethread.admin devices <name>
  python -m homethread.admin revoke-all <name>
  python -m homethread.admin unlock                (alle Anmelde-Sperren aufheben)
  python -m homethread.admin new-totp <name> --out FILE   (neues Authenticator-Geheimnis)
  python -m homethread.admin backup <ziel.db>      (konsistente Kopie der Datenbank)
  python -m homethread.admin gc                    (verwaiste Anhänge älter als 7 Tage löschen)
"""
import argparse
import json
import os
import secrets
import sqlite3
import string
import sys
import time
import uuid

os.environ.setdefault("HT_DATA", "/data")
from .db import DB  # noqa: E402
from . import security as sec  # noqa: E402

DATA = os.environ["HT_DATA"]


def db():
    return DB(os.path.join(DATA, "homethread.db"))


def strong_password(n=24):
    abc = string.ascii_letters + string.digits + "-_.!?"
    while True:
        pw = "".join(secrets.choice(abc) for _ in range(n))
        if any(c.isdigit() for c in pw) and any(c.isupper() for c in pw) and any(c.islower() for c in pw):
            return pw


def write_secret(out, data):
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    try:
        import qrcode
        png = os.path.splitext(out)[0] + "-totp.png"
        qrcode.make(data["otpauth"], box_size=10, border=3).save(png)
        os.chmod(png, 0o600)
    except Exception as e:  # QR ist Komfort, das Geheimnis steht ohnehin in der Datei
        print("QR-Code nicht erzeugt:", type(e).__name__, file=sys.stderr)


def cmd_add_user(a):
    d = db()
    name = a.username.strip().lower()
    if d.one("SELECT 1 FROM users WHERE username=?", (name,)):
        sys.exit("Konto existiert schon")
    pw = strong_password()
    totp = sec.new_totp_secret()
    uid = str(uuid.uuid4())
    d.x("INSERT INTO users(id, username, display_name, pw_hash, totp_secret, hidden, color, created) VALUES(?,?,?,?,?,?,?,?)",
        (uid, name, a.display or name, sec.hash_pw(pw), totp, 1 if a.hidden else 0, secrets.randbelow(12), time.time()))
    write_secret(a.out, {"username": name, "password": pw, "totp_secret": totp,
                         "otpauth": sec.otpauth_uri(totp, name, a.issuer)})
    print(f"Konto {name} angelegt, Zugang in {a.out}")


def cmd_new_totp(a):
    d = db()
    u = d.one("SELECT * FROM users WHERE username=?", (a.username,))
    if not u:
        sys.exit("unbekannt")
    totp = sec.new_totp_secret()
    d.x("UPDATE users SET totp_secret=?, totp_last=-1 WHERE id=?", (totp, u["id"]))
    write_secret(a.out, {"username": u["username"], "totp_secret": totp,
                         "otpauth": sec.otpauth_uri(totp, u["username"], a.issuer)})
    print(f"Neues Authenticator-Geheimnis in {a.out}")


def cmd_list(a):
    for u in db().q("SELECT username, display_name, hidden, disabled, totp_secret IS NOT NULL AS totp FROM users"):
        print(f"{u['username']:20} {u['display_name']:24} versteckt={u['hidden']} aus={u['disabled']} totp={u['totp']}")


def cmd_devices(a):
    d = db()
    for r in d.q("SELECT d.id, d.name, d.platform, d.last_seen, d.revoked FROM devices d JOIN users u ON u.id=d.user_id "
                 "WHERE u.username=? ORDER BY d.last_seen DESC", (a.username,)):
        seen = time.strftime("%d.%m.%Y %H:%M", time.localtime(r["last_seen"] or 0))
        print(f"{r['id']}  {r['name'][:30]:30} {r['platform']:8} zuletzt {seen} {'(abgemeldet)' if r['revoked'] else ''}")


def cmd_revoke_all(a):
    d = db()
    u = d.one("SELECT id FROM users WHERE username=?", (a.username,))
    n = d.x("UPDATE devices SET revoked=? WHERE user_id=? AND revoked IS NULL", (time.time(), u["id"])).rowcount
    print(f"{n} Geräte abgemeldet")


def cmd_unlock(a):
    n = db().x("DELETE FROM locks").rowcount
    print(f"{n} Sperren aufgehoben")


def cmd_backup(a):
    src = sqlite3.connect(os.path.join(DATA, "homethread.db"))
    dst = sqlite3.connect(a.target)
    with dst:
        src.backup(dst)
    dst.close()
    src.close()
    os.chmod(a.target, 0o600)
    print("Sicherung", a.target)


def cmd_gc(a):
    d = db()
    old = time.time() - 7 * 86400
    n = 0
    for b in d.q("SELECT id FROM blobs WHERE created<?", (old,)):
        bid = b["id"]
        if d.one("SELECT 1 FROM messages WHERE attachment=? OR thumb=?", (bid, bid)) or \
                d.one("SELECT 1 FROM rooms WHERE avatar=?", (bid,)) or d.one("SELECT 1 FROM users WHERE avatar=?", (bid,)):
            continue
        try:
            os.remove(os.path.join(DATA, "blobs", bid[:2], bid))
        except FileNotFoundError:
            pass
        d.x("DELETE FROM blobs WHERE id=?", (bid,))
        n += 1
    d.x("DELETE FROM ops WHERE applied<?", (time.time() - 90 * 86400,))
    print(f"{n} verwaiste Anhänge gelöscht")


def main():
    p = argparse.ArgumentParser(prog="homethread.admin")
    s = p.add_subparsers(dest="cmd", required=True)
    x = s.add_parser("add-user")
    x.add_argument("username")
    x.add_argument("--display")
    x.add_argument("--hidden", action="store_true")
    x.add_argument("--issuer", default="HomeThread")
    x.add_argument("--out", required=True)
    x.set_defaults(f=cmd_add_user)
    x = s.add_parser("new-totp")
    x.add_argument("username")
    x.add_argument("--issuer", default="HomeThread")
    x.add_argument("--out", required=True)
    x.set_defaults(f=cmd_new_totp)
    s.add_parser("list-users").set_defaults(f=cmd_list)
    x = s.add_parser("devices")
    x.add_argument("username")
    x.set_defaults(f=cmd_devices)
    x = s.add_parser("revoke-all")
    x.add_argument("username")
    x.set_defaults(f=cmd_revoke_all)
    s.add_parser("unlock").set_defaults(f=cmd_unlock)
    x = s.add_parser("backup")
    x.add_argument("target")
    x.set_defaults(f=cmd_backup)
    s.add_parser("gc").set_defaults(f=cmd_gc)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
