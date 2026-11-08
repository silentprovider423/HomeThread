"""Passwörter (Argon2id), Authenticator-Codes (TOTP, RFC 6238), Geräte-Token und Sperren.

Sperr-Regeln (wie beim Vorbild-Gate):
- pro Adresse: 3 Fehlversuche → 10 Min gesperrt, jede weitere Sperre doppelt so lang (max. 24 h)
- über alle Adressen: 10 Fehlversuche in 15 Min → Anmelden 15 Min gesperrt, verdoppelt sich (max. 24 h)
- Zurücksetzen per Authenticator: 3 falsche Codes (egal von wo) → 10 Min, verdoppelt sich (max. 24 h)
- nach 24 h Ruhe beginnt die Eskalation wieder von vorn
IPv6-Adressen zählen pro /64-Netz, sonst könnte man mit jeder neuen Adresse weiterraten.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import secrets
import struct
import threading
import time
from urllib.parse import quote

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

_ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=2)
_DUMMY = _ph.hash(secrets.token_hex(16))
# Argon2 braucht 64 MB je Prüfung: höchstens zwei gleichzeitig, damit Anfragefluten den Speicher nicht sprengen
_sem = threading.BoundedSemaphore(2)

IP_MAX = 3
IP_LOCK = 600
GLOBAL_WINDOW = 900
GLOBAL_MAX = 10
GLOBAL_LOCK = 900
RESET_MAX = 3
RESET_LOCK = 600
LOCK_MAX = 86400
MIN_PASSWORD = 12


def hash_pw(pw):
    with _sem:
        return _ph.hash(pw)


def verify_pw(pw, stored):
    """Prüft immer einen Hash (auch für unbekannte Namen), damit die Antwortzeit nichts verrät."""
    with _sem:
        try:
            return _ph.verify(stored or _DUMMY, pw or "") and bool(stored)
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False


def new_totp_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _b32(sec):
    return base64.b32decode(sec + "=" * (-len(sec) % 8))


def totp_at(sec, counter):
    h = hmac.new(_b32(sec), struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    return f"{(struct.unpack('>I', h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000:06d}"


def totp_check(sec, code, last=-1, now=None):
    """Gibt den Zähler des passenden Codes zurück (±30 s), sonst None. Ein Code gilt nur einmal (Replay-Schutz)."""
    code = "".join(c for c in (code or "") if c.isdigit())
    if not sec or len(code) != 6:
        return None
    t = int((now or time.time()) // 30)
    for c in (t - 1, t, t + 1):
        if c > last and hmac.compare_digest(totp_at(sec, c), code):
            return c
    return None


def otpauth_uri(secret, username, issuer="HomeThread"):
    return (f"otpauth://totp/{quote(issuer)}:{quote(username)}?secret={secret}"
            f"&issuer={quote(issuer)}&digits=6&period=30&algorithm=SHA1")


def new_token():
    return "ht_" + secrets.token_urlsafe(32)


def token_hash(tok):
    return hashlib.sha256(tok.encode()).hexdigest()


def ip_key(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return ip[:64]
    if a.version == 6:
        if a.ipv4_mapped:
            return str(a.ipv4_mapped)
        return str(ipaddress.ip_network(f"{a}/64", strict=False))
    return str(a)


class Locks:
    """Sperren liegen in der Datenbank, damit ein Neustart sie nicht aufhebt."""

    def __init__(self, db):
        self.db = db

    def _get(self, key):
        r = self.db.one("SELECT * FROM locks WHERE key=?", (key,))
        return r or {"key": key, "fails": 0, "lock_count": 0, "locked_until": 0, "window": "[]"}

    def _put(self, e):
        self.db.x("INSERT OR REPLACE INTO locks(key, fails, lock_count, locked_until, window) VALUES(?,?,?,?,?)",
                  (e["key"], e["fails"], e["lock_count"], e["locked_until"], e["window"]))

    def remain(self, key):
        return max(0, int(self._get(key)["locked_until"] - time.time() + 0.999))

    def fail(self, key, max_fails, base):
        """Fehlversuch zählen. Rückgabe (verbleibende Versuche, Sperrdauer in s)."""
        with self.db.lock:
            e = self._get(key)
            now = time.time()
            if e["locked_until"] > now:
                return 0, int(e["locked_until"] - now)
            if e["locked_until"] and now - e["locked_until"] > LOCK_MAX:
                e["lock_count"] = 0
            e["fails"] += 1
            if e["fails"] >= max_fails:
                e["lock_count"] += 1
                e["fails"] = 0
                e["locked_until"] = now + min(base * 2 ** (e["lock_count"] - 1), LOCK_MAX)
                self._put(e)
                return 0, int(e["locked_until"] - now)
            self._put(e)
            return max_fails - e["fails"], 0

    def fail_window(self, key, window, max_fails, base):
        """Fehlversuche in einem gleitenden Zeitfenster (für die Sperre über alle Adressen)."""
        with self.db.lock:
            e = self._get(key)
            now = time.time()
            if e["locked_until"] and now - e["locked_until"] > LOCK_MAX:
                e["lock_count"] = 0
            w = [t for t in json.loads(e["window"] or "[]") if now - t < window] + [now]
            if len(w) >= max_fails and e["locked_until"] < now:
                e["lock_count"] += 1
                e["locked_until"] = now + min(base * 2 ** (e["lock_count"] - 1), LOCK_MAX)
                w = []
            e["window"] = json.dumps(w)
            self._put(e)

    def clear(self, key):
        self.db.x("DELETE FROM locks WHERE key=?", (key,))

    def clear_window(self, key):
        """Erfolg setzt das Zeitfenster zurück, eine laufende Sperre bleibt."""
        self.db.x("UPDATE locks SET window='[]' WHERE key=?", (key,))


class RateLimiter:
    """Einfacher Token-Eimer je Schlüssel (im Speicher)."""

    def __init__(self):
        self.b = {}
        self.m = threading.Lock()

    def allow(self, key, rate_per_min, burst):
        now = time.monotonic()
        with self.m:
            tokens, last = self.b.get(key, (burst, now))
            tokens = min(burst, tokens + (now - last) * rate_per_min / 60.0)
            if tokens < 1:
                self.b[key] = (tokens, now)
                return False
            self.b[key] = (tokens - 1, now)
            if len(self.b) > 50000:
                self.b.clear()
            return True
