"""Server-Tests mit einer frischen Datenbank (ohne Netz):
  docker run --rm -v "$PWD:/w" -w /w python:3.12-slim sh -c \
    "pip -q install -r app/requirements.txt httpx && PYTHONPATH=app python -m unittest discover -s tests -v"
"""
import os
import sys
import tempfile
import time
import unittest
import uuid

TMP = tempfile.mkdtemp()
os.environ["HT_DATA"] = TMP
os.environ["HT_TRUSTED_PROXIES"] = "10.9.9.9"

from fastapi.testclient import TestClient  # noqa: E402
from homethread import main, security as sec  # noqa: E402
from homethread import admin  # noqa: E402

PW = "Test-Passwort-1234"


def make_user(name, hidden=False):
    secret = sec.new_totp_secret()
    uid = str(uuid.uuid4())
    main.db.x("INSERT INTO users(id, username, display_name, pw_hash, totp_secret, hidden, created) VALUES(?,?,?,?,?,?,?)",
              (uid, name, name.title(), sec.hash_pw(PW), secret, 1 if hidden else 0, time.time()))
    return uid, secret


def code(secret, offset=0):
    return sec.totp_at(secret, int(time.time() // 30) + offset)


def ident():
    return str(uuid.uuid4())


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        main._private = lambda ip: True  # der Testclient heißt "testclient", gilt hier als Caddy davor
        cls.c = TestClient(main.app)
        cls.uid, cls.secret = make_user("alice")
        cls.uid2, cls.secret2 = make_user("bob")
        cls.used = {}

    def setUp(self):
        main.db.x("DELETE FROM locks")
        main.limiter.b.clear()

    def login(self, name="alice", secret=None, ip="1.2.3.4"):
        secret = secret or (self.secret if name == "alice" else self.secret2)
        # jeder Code gilt nur einmal (eigener Test); für die übrigen Tests den Zähler zurücksetzen statt zu warten
        main.db.x("UPDATE users SET totp_last=-1 WHERE username=?", (name,))
        cnt = int(time.time() // 30)
        r = self.c.post("/auth/login", json={"username": name, "password": PW, "code": sec.totp_at(secret, cnt),
                                             "device_name": "Test", "platform": "test"},
                        headers={"x-real-peer": ip})
        self.assertEqual(r.status_code, 200, r.text)
        return {"Authorization": "Bearer " + r.json()["token"]}, r.json()

    def ops(self, h, *ops):
        body = {"ops": [dict(o, op_id=o.get("op_id") or ident()) for o in ops]}
        r = self.c.post("/api/ops", json=body, headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["results"]

    def test_01_paths_and_auth(self):
        self.assertEqual(self.c.get("/").status_code, 404)
        self.assertEqual(self.c.get("/admin").status_code, 404)
        self.assertEqual(self.c.get("/api/sync").status_code, 401)
        self.assertEqual(self.c.get("/api/sync", headers={"Authorization": "Bearer ht_falsch"}).status_code, 401)
        self.assertEqual(self.c.get("/api/health").json()["ok"], True)

    def test_02_lockout_per_address(self):
        bad = {"username": "alice", "password": "falsch", "code": "000000"}
        h = {"x-real-peer": "5.5.5.5"}
        self.assertEqual(self.c.post("/auth/login", json=bad, headers=h).status_code, 401)
        self.assertEqual(self.c.post("/auth/login", json=bad, headers=h).json()["left"], 1)
        r = self.c.post("/auth/login", json=bad, headers=h)
        self.assertEqual(r.status_code, 429)
        self.assertGreaterEqual(r.json()["retry_after"], 590)
        # auch das richtige Passwort hilft während der Sperre nicht
        good = {"username": "alice", "password": PW, "code": code(self.secret)}
        self.assertEqual(self.c.post("/auth/login", json=good, headers=h).status_code, 429)
        # andere Adresse ist nicht betroffen
        self.login(ip="6.6.6.6")

    def test_03_global_lock(self):
        bad = {"username": "alice", "password": "falsch", "code": "000000"}
        for i in range(10):
            self.c.post("/auth/login", json=bad, headers={"x-real-peer": f"7.7.{i}.1"})
        r = self.c.post("/auth/login", json=bad, headers={"x-real-peer": "8.8.8.8"})
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["scope"], "global")

    def test_04_spoofed_cf_header_ignored(self):
        bad = {"username": "alice", "password": "falsch", "code": "000000"}
        # nicht vertrauenswürdige Gegenstelle: Cf-Connecting-Ip zählt nicht, alles landet bei 9.9.9.9
        for i in range(3):
            self.c.post("/auth/login", json=bad, headers={"x-real-peer": "9.9.9.9", "cf-connecting-ip": f"1.1.1.{i}"})
        self.assertGreater(main.locks.remain("ip:9.9.9.9"), 0)
        # vertrauenswürdiger Tunnel-Rechner: echte Besucher-Adresse zählt
        self.c.post("/auth/login", json=bad, headers={"x-real-peer": "10.9.9.9", "cf-connecting-ip": "2.2.2.2"})
        self.assertEqual(main.db.one("SELECT fails FROM locks WHERE key='ip:2.2.2.2'")["fails"], 1)

    def test_05_ipv6_counts_per_64(self):
        self.assertEqual(sec.ip_key("2001:db8:1:2:aaaa::1"), sec.ip_key("2001:db8:1:2:bbbb::2"))

    def test_06_totp_replay(self):
        h, _ = self.login()
        last = main.db.one("SELECT totp_last FROM users WHERE username='alice'")["totp_last"]
        r = self.c.post("/auth/login", json={"username": "alice", "password": PW, "code": sec.totp_at(self.secret, last)},
                        headers={"x-real-peer": "3.3.3.3"})
        self.assertEqual(r.status_code, 401)

    def test_07_rooms_messages_sync(self):
        h, info = self.login()
        h2, _ = self.login()
        room = ident()
        res = self.ops(h, {"type": "room.create", "room": {"id": room, "kind": "group", "title": "Garten"}})
        self.assertTrue(res[0]["ok"], res)
        m1, m2, poll, cl = ident(), ident(), ident(), ident()
        it1, it2 = ident(), ident()
        res = self.ops(h,
                       {"type": "msg.create", "msg": {"id": m1, "room_id": room, "body": "Tomaten giessen"}},
                       {"type": "msg.create", "msg": {"id": m2, "room_id": room, "body": "Antwort", "reply_to": m1}},
                       {"type": "msg.create", "msg": {"id": poll, "room_id": room, "kind": "poll",
                                                      "payload": {"question": "Wann?", "multi": False,
                                                                  "options": [{"id": "a", "text": "Sa"}, {"id": "b", "text": "So"}]}}},
                       {"type": "msg.create", "msg": {"id": cl, "room_id": room, "kind": "checklist", "body": "Einkauf",
                                                      "items": [{"id": it1, "text": "Erde"}, {"id": it2, "text": "Samen"}]}},
                       {"type": "reaction.set", "message_id": m1, "emoji": "👍"},
                       {"type": "star.set", "message_id": m1, "on": True},
                       {"type": "msg.pin", "id": m1, "pinned": True},
                       {"type": "vote.set", "message_id": poll, "choices": ["b"]},
                       {"type": "item.update", "id": it1, "done": True},
                       {"type": "roomstate.set", "room_id": room, "pinned": True},
                       {"type": "msg.create", "msg": {"id": ident(), "room_id": room, "kind": "location",
                                                      "payload": {"lat": 48.1, "lon": 9.7, "name": "Beet"}}})
        self.assertTrue(all(r["ok"] for r in res), res)
        # falsche Abstimmung (zwei Antworten, aber keine Mehrfachauswahl)
        self.assertEqual(self.ops(h, {"type": "vote.set", "message_id": poll, "choices": ["a", "b"]})[0]["error"],
                         "single_choice")
        # zweites Gerät sieht alles
        s = self.c.get("/api/sync?since=0", headers=h2).json()
        kinds = [c["kind"] for c in s["changes"]]
        for k in ("room", "member", "message", "reaction", "star", "vote", "item", "roomstate"):
            self.assertIn(k, kinds)
        msgs = {c["data"]["id"]: c["data"] for c in s["changes"] if c["kind"] == "message"}
        self.assertEqual(msgs[m2]["reply_to"], m1)
        self.assertEqual(msgs[m1]["pinned"], 1)
        self.assertEqual(msgs[m1]["device_id"], info["device_id"])
        cur = s["next"]
        # nichts Neues
        self.assertEqual(self.c.get(f"/api/sync?since={cur}", headers=h2).json()["changes"], [])
        # Löschen kommt als Grabstein an
        self.ops(h, {"type": "msg.delete", "id": m2})
        s2 = self.c.get(f"/api/sync?since={cur}", headers=h2).json()
        d = [c["data"] for c in s2["changes"] if c["kind"] == "message"]
        self.assertEqual(d[0]["deleted"], 1)
        self.assertEqual(d[0]["body"], "")
        # Abstimmung beenden, danach keine Stimmen mehr
        self.ops(h, {"type": "poll.close", "message_id": poll})
        self.assertEqual(self.ops(h, {"type": "vote.set", "message_id": poll, "choices": ["a"]})[0]["error"], "poll_closed")

    def test_08_idempotent_ops(self):
        h, _ = self.login()
        room, op = ident(), ident()
        o = {"op_id": op, "type": "room.create", "room": {"id": room, "title": "Einmal"}}
        self.assertTrue(self.ops(h, o)[0]["ok"])
        self.assertTrue(self.ops(h, o)[0]["ok"])  # Wiederholung = gleiches Ergebnis, kein Fehler
        self.assertEqual(main.db.one("SELECT COUNT(*) AS n FROM rooms WHERE id=?", (room,))["n"], 1)

    def test_09_paging(self):
        h, _ = self.login()
        room = ident()
        self.ops(h, {"type": "room.create", "room": {"id": room, "title": "Viele"}})
        self.ops(h, *[{"type": "msg.create", "msg": {"id": ident(), "room_id": room, "body": f"n{i}"}} for i in range(30)])
        seen, since, rounds = set(), 0, 0
        while True:
            s = self.c.get(f"/api/sync?since={since}&limit=7", headers=h).json()
            seen |= {c["data"]["id"] for c in s["changes"] if c["kind"] == "message" and c["data"]["room_id"] == room}
            since = s["next"]
            rounds += 1
            if not s["more"]:
                break
        self.assertEqual(len(seen), 30)
        self.assertGreater(rounds, 3)

    def test_10_membership_and_isolation(self):
        ha, _ = self.login("alice")
        hb, _ = self.login("bob")
        room = ident()
        self.ops(ha, {"type": "room.create", "room": {"id": room, "title": "Privat"}},
                 {"type": "msg.create", "msg": {"id": ident(), "room_id": room, "body": "geheim"}})
        s = self.c.get("/api/sync?since=0", headers=hb).json()
        self.assertFalse(any(c["data"].get("room_id") == room or c["data"].get("id") == room for c in s["changes"]))
        self.assertEqual(self.ops(hb, {"type": "msg.create", "msg": {"id": ident(), "room_id": room, "body": "x"}})[0]["error"],
                         "not_member")
        # Bob wird Mitglied: er sieht die Mitgliedschaft und holt den Raum nach
        self.ops(ha, {"type": "member.add", "room_id": room, "user_id": self.uid2})
        s = self.c.get(f"/api/sync?since={s['next']}", headers=hb).json()
        self.assertTrue(any(c["kind"] == "member" and c["data"]["user_id"] == self.uid2 for c in s["changes"]))
        full = self.c.get(f"/api/sync?since=0&room={room}", headers=hb).json()
        self.assertTrue(any(c["kind"] == "message" and c["data"]["body"] == "geheim" for c in full["changes"]))
        # Sternchen sind privat
        mid = [c["data"]["id"] for c in full["changes"] if c["kind"] == "message"][0]
        self.ops(ha, {"type": "star.set", "message_id": mid, "on": True})
        s = self.c.get("/api/sync?since=0", headers=hb).json()
        self.assertFalse(any(c["kind"] == "star" for c in s["changes"] if c["data"].get("user_id") == self.uid))

    def test_11_blobs(self):
        h, _ = self.login()
        bid = ident()
        data = os.urandom(5000)
        r = self.c.put(f"/api/blobs/{bid}", content=data, headers={**h, "Content-Type": "image/jpeg", "X-Filename": "a.jpg"})
        self.assertEqual(r.status_code, 200, r.text)
        room, mid = ident(), ident()
        res = self.ops(h, {"type": "room.create", "room": {"id": room, "title": "Fotos"}},
                       {"type": "msg.create", "msg": {"id": mid, "room_id": room, "kind": "image", "attachment": bid}})
        self.assertTrue(all(x["ok"] for x in res), res)
        g = self.c.get(f"/api/blobs/{bid}", headers=h)
        self.assertEqual(g.content, data)
        hb, _ = self.login("bob")
        self.assertEqual(self.c.get(f"/api/blobs/{bid}", headers=hb).status_code, 404)
        # fehlender Anhang wird nicht dauerhaft als Fehler gemerkt
        miss = ident()
        op = ident()
        o = {"op_id": op, "type": "msg.create", "msg": {"id": ident(), "room_id": room, "kind": "file", "attachment": miss}}
        self.assertEqual(self.ops(h, o)[0]["error"], "blob_missing")
        self.c.put(f"/api/blobs/{miss}", content=b"x", headers=h)
        self.assertTrue(self.ops(h, o)[0]["ok"])
        # Löschen gibt die Datei frei
        self.ops(h, {"type": "msg.delete", "id": mid})
        self.assertEqual(self.c.get(f"/api/blobs/{bid}", headers=h).status_code, 404)

    def test_12_devices_revoke(self):
        h1, i1 = self.login()
        h2, i2 = self.login()
        devs = self.c.get("/api/devices", headers=h1).json()["devices"]
        self.assertTrue(any(d["id"] == i2["device_id"] for d in devs))
        self.assertEqual(self.c.delete(f"/api/devices/{i2['device_id']}", headers=h1).status_code, 200)
        self.assertEqual(self.c.get("/api/me", headers=h2).status_code, 401)
        self.assertEqual(self.c.post("/auth/logout", headers=h1).status_code, 200)
        self.assertEqual(self.c.get("/api/me", headers=h1).status_code, 401)

    def test_13_reset_with_authenticator(self):
        uid, secret = make_user("carol")
        hc, _ = self.login("carol", secret)
        bad = {"username": "carol", "code": "000000", "new_password": "Neues-Passwort-5678"}
        self.assertEqual(self.c.post("/auth/reset", json=bad).status_code, 401)
        self.assertEqual(self.c.post("/auth/reset", json=bad).status_code, 401)
        self.assertEqual(self.c.post("/auth/reset", json=bad).status_code, 429)
        main.db.x("DELETE FROM locks")
        main.db.x("UPDATE users SET totp_last=-1 WHERE id=?", (uid,))
        cnt = int(time.time() // 30)
        ok = dict(bad, code=sec.totp_at(secret, cnt))
        self.assertEqual(self.c.post("/auth/reset", json=ok).status_code, 200)
        self.assertEqual(self.c.get("/api/me", headers=hc).status_code, 401)  # alle Geräte abgemeldet

    def test_14_rate_limit_auth(self):
        codes = [self.c.post("/auth/login", json={"username": "x", "password": "y"},
                             headers={"x-real-peer": "4.4.4.4"}).status_code for _ in range(10)]
        self.assertIn(429, codes)

    def test_15_admin_add_user_writes_only_file(self):
        out = os.path.join(TMP, "secrets", "dave.json")
        sys.argv = ["admin", "add-user", "dave", "--display", "Dave", "--out", out]
        admin.main()
        self.assertEqual(oct(os.stat(out).st_mode & 0o777), "0o600")
        self.assertTrue(os.path.exists(out.replace(".json", "-totp.png")))


if __name__ == "__main__":
    unittest.main()
