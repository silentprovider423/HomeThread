"""SQLite-Ablage für HomeThread: Räume, Mitglieder, Einträge, Anhänge, Reaktionen und ein Änderungsprotokoll.

Jede Änderung bekommt eine fortlaufende Nummer (seq) aus der Tabelle `changes`. Geräte holen mit
`/api/sync?since=<seq>` nur das, was seitdem passiert ist – auch Löschungen (als Grabstein `deleted=1`).
"""
import json
import os
import sqlite3
import threading
import time
from contextlib import contextmanager

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS users(
  id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL,
  pw_hash TEXT NOT NULL, totp_secret TEXT, totp_last INTEGER DEFAULT -1,
  hidden INTEGER DEFAULT 0, disabled INTEGER DEFAULT 0, color INTEGER DEFAULT 0, avatar TEXT, created REAL);
CREATE TABLE IF NOT EXISTS devices(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT, platform TEXT, token_hash TEXT UNIQUE NOT NULL,
  created REAL, last_seen REAL, last_ip TEXT, revoked REAL);
CREATE TABLE IF NOT EXISTS locks(
  key TEXT PRIMARY KEY, fails INTEGER DEFAULT 0, lock_count INTEGER DEFAULT 0,
  locked_until REAL DEFAULT 0, window TEXT DEFAULT '[]');
CREATE TABLE IF NOT EXISTS rooms(
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, avatar TEXT, about TEXT DEFAULT '',
  created_by TEXT, created_at REAL, updated_at REAL, deleted INTEGER DEFAULT 0, seq INTEGER);
CREATE TABLE IF NOT EXISTS members(
  room_id TEXT, user_id TEXT, role TEXT, added_at REAL, removed INTEGER DEFAULT 0, seq INTEGER,
  PRIMARY KEY(room_id, user_id));
CREATE TABLE IF NOT EXISTS messages(
  id TEXT PRIMARY KEY, room_id TEXT NOT NULL, author_id TEXT NOT NULL, device_id TEXT, kind TEXT NOT NULL,
  body TEXT DEFAULT '', payload TEXT DEFAULT '{}', reply_to TEXT, attachment TEXT, thumb TEXT,
  created_at REAL, server_at REAL, edited_at REAL, pinned INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, seq INTEGER);
CREATE INDEX IF NOT EXISTS messages_room ON messages(room_id);
CREATE TABLE IF NOT EXISTS blobs(
  id TEXT PRIMARY KEY, owner_id TEXT, mime TEXT, size INTEGER, sha256 TEXT, filename TEXT, created REAL);
CREATE TABLE IF NOT EXISTS reactions(
  message_id TEXT, user_id TEXT, emoji TEXT, active INTEGER, room_id TEXT, seq INTEGER,
  PRIMARY KEY(message_id, user_id, emoji));
CREATE TABLE IF NOT EXISTS stars(
  message_id TEXT, user_id TEXT, active INTEGER, room_id TEXT, seq INTEGER, PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS votes(
  message_id TEXT, user_id TEXT, choices TEXT, room_id TEXT, seq INTEGER, PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS items(
  id TEXT PRIMARY KEY, message_id TEXT, room_id TEXT, text TEXT, done INTEGER DEFAULT 0, done_by TEXT,
  position REAL, deleted INTEGER DEFAULT 0, seq INTEGER);
CREATE TABLE IF NOT EXISTS roomstate(
  room_id TEXT, user_id TEXT, pinned INTEGER DEFAULT 0, archived INTEGER DEFAULT 0, muted INTEGER DEFAULT 0,
  seq INTEGER, PRIMARY KEY(room_id, user_id));
CREATE TABLE IF NOT EXISTS ops(op_id TEXT, user_id TEXT, applied REAL, result TEXT, PRIMARY KEY(user_id, op_id));
-- scope_user: nur für diese Person sichtbar (Sternchen, Raum-Einstellungen)
-- about_user: Mitgliedschafts-Änderung, die diese Person auch dann sieht, wenn sie nicht (mehr) Mitglied ist
CREATE TABLE IF NOT EXISTS changes(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, ref TEXT NOT NULL, room_id TEXT,
  scope_user TEXT, about_user TEXT, at REAL);
CREATE INDEX IF NOT EXISTS changes_room ON changes(room_id, seq);
"""


class DB:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.path = path
        self.lock = threading.RLock()
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=OFF")
        self.conn.executescript(SCHEMA)
        os.chmod(path, 0o600)

    def q(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        with self.lock:
            r = self.conn.execute(sql, args).fetchone()
            return dict(r) if r else None

    def x(self, sql, args=()):
        with self.lock:
            return self.conn.execute(sql, args)

    @contextmanager
    def tx(self):
        """Schreib-Transaktion; alles innerhalb ist atomar."""
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                yield self
                self.conn.execute("COMMIT")
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise

    def change(self, kind, ref, room_id=None, scope_user=None, about_user=None):
        cur = self.conn.execute(
            "INSERT INTO changes(kind, ref, room_id, scope_user, about_user, at) VALUES(?,?,?,?,?,?)",
            (kind, ref, room_id, scope_user, about_user, time.time()))
        return cur.lastrowid

    def max_seq(self):
        r = self.one("SELECT COALESCE(MAX(seq), 0) AS s FROM changes")
        return r["s"]


def dumps(o):
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False)
