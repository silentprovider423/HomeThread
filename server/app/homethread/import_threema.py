"""Threema-Verlauf (iOS, aus einer iMazing-App-Extraktion) in ein HomeThread-Konto übernehmen.

Läuft auf dem Server im Container und nutzt die internen Operationen des Dienstes – Änderungsprotokoll und
Sync-Nummern entstehen also genau wie bei Einträgen aus der App, und alle Geräte bekommen den Import per /api/sync.

  python -m homethread.import_threema QUELLE --user NAME [--device GERÄT] [--apply] [--verify]

QUELLE   die .imazingapp-Datei (ZIP) oder ein Ordner, in dem irgendwo ThreemaData.sqlite liegt
         (z. B. Container/AppGroups/group.ch.threema samt .ThreemaData_SUPPORT/_EXTERNAL_DATA).
--user   Zielkonto (muss existieren).
--device Geräte-ID oder -Name dieses Kontos, dem die Einträge zugeordnet werden (sie gelten dort dann nicht
         als „neu von anderem Gerät“). Ohne Angabe: keinem Gerät.
--apply  wirklich schreiben; ohne nur ein Probelauf mit Zählung.
--verify zählt danach, was ein frisch angemeldetes Gerät per /api/sync bekäme.

Ausgegeben werden NUR Anzahlen – nie Inhalte, Gruppen- oder Dateinamen.

Abbildung: Gruppe/Verteilerliste → Gruppe, Einzelchat → Chat; Text → Text; Datei-Nachrichten je nach Art → Foto,
Video, Sprachnotiz oder Datei (Original-Datum, Bildunterschrift); Zitate → Antwort-Verweis; Stern → Stern;
Reaktionen; Umfragen → Abstimmung; Standort → Ort; angeheftet/archiviert → Raum-Einstellung. Systemmeldungen und
gelöschte Nachrichten werden übersprungen. Einträge der Gegenseite eines Einzelchats bekommen eine feste
Platzhalter-ID als Autor (kein Konto) und erscheinen links.

Idempotent: alle IDs werden aus den Threema-IDs abgeleitet (UUIDv5). Ein zweiter Lauf legt nichts doppelt an,
und was im Ziel gelöscht wurde, kommt nicht wieder.
"""
import argparse
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
import uuid
import zipfile
from collections import Counter

EPOCH_2001 = 978307200.0
NS = uuid.UUID("5b7f3c2e-8d4a-4f0e-9a51-3c6b2d7e9f10")
DB_NAME = "ThreemaData.sqlite"
EXT_DIR = ".ThreemaData_SUPPORT/_EXTERNAL_DATA"
IMAGE_MIMES = ("image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/gif", "image/webp")


def sid(*parts):
    return str(uuid.uuid5(NS, "|".join(str(p) for p in parts)))


def ts(v):
    return None if v is None else float(v) + EPOCH_2001


# ---------------------------------------------------------------- Quelle lesen

class Source:
    """Öffnet ThreemaData.sqlite (Kopie im Temp-Ordner, Original bleibt unberührt) und liefert Core-Data-Blobs –
    eingebettet (erstes Byte 0x01 + Daten) oder extern (0x02 + UUID + 0x00 → Datei in _EXTERNAL_DATA)."""

    def __init__(self, path):
        self.tmp = tempfile.mkdtemp(prefix="threema-import-")
        self.zip = None
        self.ext_prefix = None
        self.ext_dir = None
        if os.path.isfile(path) and zipfile.is_zipfile(path):
            self.zip = zipfile.ZipFile(path)
            names = [n for n in self.zip.namelist() if n.endswith("/" + DB_NAME) or n == DB_NAME]
            if not names:
                raise SystemExit("keine ThreemaData.sqlite im Archiv")
            name = sorted(names, key=lambda n: ("group.ch.threema" not in n, len(n)))[0]
            base = name[: -len(DB_NAME)]
            for suffix in ("", "-wal", "-shm"):
                if base + DB_NAME + suffix in self.zip.namelist():
                    with self.zip.open(base + DB_NAME + suffix) as src, \
                            open(os.path.join(self.tmp, DB_NAME + suffix), "wb") as dst:
                        shutil.copyfileobj(src, dst)
            self.ext_prefix = base + EXT_DIR + "/"
        else:
            found = None
            for root, dirs, files in os.walk(path):
                if DB_NAME in files:
                    found = root
                    if "group.ch.threema" in root:
                        break
            if not found:
                raise SystemExit("keine ThreemaData.sqlite gefunden")
            for suffix in ("", "-wal", "-shm"):
                p = os.path.join(found, DB_NAME + suffix)
                if os.path.exists(p):
                    shutil.copyfile(p, os.path.join(self.tmp, DB_NAME + suffix))
            self.ext_dir = os.path.join(found, EXT_DIR)
        self.db = sqlite3.connect(os.path.join(self.tmp, DB_NAME))
        self.db.row_factory = sqlite3.Row
        self.ents = {r["Z_NAME"]: r["Z_ENT"] for r in self.db.execute("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")}
        self.cols = {}

    def close(self):
        self.db.close()
        if self.zip:
            self.zip.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def has(self, table, col=None):
        if table not in self.cols:
            try:
                self.cols[table] = {r[1] for r in self.db.execute(f'PRAGMA table_info("{table}")')}
            except sqlite3.Error:
                self.cols[table] = set()
        return bool(self.cols[table]) if col is None else col in self.cols[table]

    def q(self, sql, args=()):
        return self.db.execute(sql, args).fetchall()

    def one(self, sql, args=()):
        return self.db.execute(sql, args).fetchone()

    def blob(self, v):
        """Core-Data-Wert → Bytes (oder None, wenn die externe Datei fehlt)."""
        if v is None or len(v) == 0:
            return None
        if v[0] == 1:
            return bytes(v[1:])
        if v[0] == 2:
            ref = bytes(v[1:]).split(b"\0")[0].decode("ascii", "replace")
            if not ref or "/" in ref or ".." in ref:
                return None
            if self.zip:
                try:
                    return self.zip.read(self.ext_prefix + ref)
                except KeyError:
                    return None
            p = os.path.join(self.ext_dir, ref)
            if not os.path.exists(p):
                return None
            with open(p, "rb") as f:
                return f.read()
        return bytes(v)  # ältere Modelle ohne Kennbyte

    def data_row(self, table, pk):
        """(Bytes, Breite, Höhe) aus ZIMAGEDATA/ZFILEDATA/… per Primärschlüssel."""
        if pk is None or not self.has(table):
            return None, None, None
        wh = ", ZWIDTH, ZHEIGHT" if self.has(table, "ZWIDTH") else ", NULL, NULL"
        r = self.one(f"SELECT ZDATA{wh} FROM {table} WHERE Z_PK=?", (pk,))
        if not r:
            return None, None, None
        return self.blob(r[0]), r[1], r[2]


def col(row, name):
    return row[name] if name in row.keys() else None


# ---------------------------------------------------------------- Plan

class Importer:
    def __init__(self, src, main, user, device_id=None, apply=False):
        self.src = src
        self.main = main
        self.db = main.db
        self.user = user
        self.me = {"id": user["id"], "device_id": device_id}
        self.apply = apply
        self.n = Counter()
        self.bytes = 0
        self.max_blob = main.MAX_BLOB

    # -- Hilfen

    def ent(self, name):
        return self.src.ents.get(name)

    def contact(self, pk):
        if pk is None or not self.src.has("ZCONTACT"):
            return None
        return self.src.one("SELECT * FROM ZCONTACT WHERE Z_PK=?", (pk,))

    def contact_title(self, c):
        if not c:
            return "Chat"
        first, last = (col(c, "ZFIRSTNAME") or "").strip(), (col(c, "ZLASTNAME") or "").strip()
        name = (first + " " + last).strip()
        return name or (col(c, "ZPUBLICNICKNAME") or "").strip() or (col(c, "ZIDENTITY") or "Chat")

    def conv_info(self, cv):
        """(Schlüssel, Art, Titel, Bild-Bytes) einer Unterhaltung."""
        gid = col(cv, "ZGROUPID")
        if col(cv, "ZDISTRIBUTIONLIST") is not None and self.src.has("ZDISTRIBUTIONLIST"):
            d = self.src.one("SELECT * FROM ZDISTRIBUTIONLIST WHERE Z_PK=?", (cv["ZDISTRIBUTIONLIST"],))
            key = "dist:" + str(col(d, "ZDISTRIBUTIONLISTID") if d else cv["Z_PK"])
            return key, "group", ((col(d, "ZNAME") if d else None) or "Liste"), None
        if gid is not None:
            img, _, _ = self.src.data_row("ZIMAGEDATA", col(cv, "ZGROUPIMAGE"))
            return "group:" + bytes(gid).hex(), "group", (col(cv, "ZGROUPNAME") or "").strip() or "Gruppe", img
        c = self.contact(col(cv, "ZCONTACT"))
        if c is not None:
            img = None
            if col(c, "ZCONTACTIMAGE") is not None:
                img, _, _ = self.src.data_row("ZIMAGEDATA", c["ZCONTACTIMAGE"])
            if img is None and col(c, "ZIMAGEDATA") is not None:
                img = self.src.blob(c["ZIMAGEDATA"])
            return "contact:" + (col(c, "ZIDENTITY") or str(c["Z_PK"])), "chat", self.contact_title(c), img
        return "conv:" + str(cv["Z_PK"]), "chat", "Chat", None

    def put_blob(self, key, data, mime, filename):
        """Anhang ablegen (nur mit --apply); Rückgabe: Blob-ID oder None (zu groß / leer)."""
        if not data:
            return None
        if len(data) > self.max_blob:
            self.n["attachment_too_large"] += 1
            return None
        bid = sid(self.user["id"], "blob", key)
        if self.db.one("SELECT 1 FROM blobs WHERE id=?", (bid,)):
            return bid
        self.n["attachments_new"] += 1
        self.bytes += len(data)
        if self.apply:
            self.main.save_blob(bid, self.user["id"], data, mime, filename)
        return bid

    @staticmethod
    def make_thumb(data):
        """Vorschau (JPEG, max. 480 px) für Fotos ohne Threema-Vorschau – nur wenn Pillow da ist."""
        try:
            from PIL import Image
            im = Image.open(io.BytesIO(data))
            w, h = im.size
            im.thumbnail((480, 480))
            out = io.BytesIO()
            im.convert("RGB").save(out, "JPEG", quality=75)
            return out.getvalue(), w, h
        except Exception:
            return None, None, None

    # -- Nachrichten

    def file_message(self, m, mkey):
        """Datei-Nachricht (FileMessage; auch ältere Image/Video/Audio-Nachrichten) → (kind, body, payload, att, thumb)."""
        name = self.src.ents
        e = m["Z_ENT"]
        try:
            js = json.loads(col(m, "ZJSON") or "{}")
            if not isinstance(js, dict):
                js = {}
        except ValueError:
            js = {}
        x = js.get("x") if isinstance(js.get("x"), dict) else {}
        caption = (col(m, "ZCAPTION") or (js.get("d") if isinstance(js.get("d"), str) else "") or "").strip()
        p = {}
        data = thumb = None
        tw = th = None
        if e == name.get("FileMessage"):
            mime = (col(m, "ZMIMETYPE") or js.get("m") or "application/octet-stream").lower()
            filename = col(m, "ZFILENAME") or js.get("n") or "datei"
            size = col(m, "ZFILESIZE") or js.get("s")
            data, _, _ = self.src.data_row("ZFILEDATA", col(m, "ZDATA"))
            thumb, tw, th = self.src.data_row("ZIMAGEDATA", col(m, "ZTHUMBNAIL"))
            render = js.get("j", js.get("i"))
            if mime.startswith("image/") and render != 0 and mime in IMAGE_MIMES:
                kind = "image"
            elif mime.startswith("video/") and render != 0:
                kind = "video"
            elif mime.startswith("audio/") and render != 0:
                kind = "voice"
            else:
                kind = "file"
            if x.get("w") and x.get("h"):
                p["w"], p["h"] = int(x["w"]), int(x["h"])
            if isinstance(x.get("d"), (int, float)):
                p["duration"] = float(x["d"])
        elif e == name.get("ImageMessage"):
            kind, mime, filename = "image", "image/jpeg", "foto.jpg"
            data, w, h = self.src.data_row("ZIMAGEDATA", col(m, "ZIMAGE"))
            thumb, tw, th = self.src.data_row("ZIMAGEDATA", col(m, "ZTHUMBNAIL1") if self.src.has("ZMESSAGE", "ZTHUMBNAIL1")
                                              else col(m, "ZTHUMBNAIL"))
            if w and h:
                p["w"], p["h"] = int(w), int(h)
            size = len(data) if data else None
        elif e == name.get("VideoMessage"):
            kind, mime, filename = "video", "video/mp4", "video.mp4"
            data, _, _ = self.src.data_row("ZVIDEODATA", col(m, "ZVIDEO"))
            thumb, tw, th = self.src.data_row("ZIMAGEDATA", col(m, "ZTHUMBNAIL2") if self.src.has("ZMESSAGE", "ZTHUMBNAIL2")
                                              else col(m, "ZTHUMBNAIL"))
            d = col(m, "ZDURATION1") if self.src.has("ZMESSAGE", "ZDURATION1") else col(m, "ZDURATION")
            if d:
                p["duration"] = float(d)
            size = len(data) if data else None
        else:  # AudioMessage
            kind, mime, filename = "voice", "audio/mp4", "sprachnotiz.m4a"
            data, _, _ = self.src.data_row("ZAUDIODATA", col(m, "ZAUDIO"))
            if col(m, "ZDURATION"):
                p["duration"] = float(m["ZDURATION"])
            size = len(data) if data else None
        if kind == "voice" and not data:
            kind = "file"
        p["filename"] = os.path.basename(str(filename)).replace("/", "_")[:200] or "datei"
        p["mime"] = mime
        if "w" not in p and tw and th and kind in ("image", "video"):
            p["w"], p["h"] = int(tw), int(th)
        att = tid = None
        if data:
            if kind == "image" and not thumb:
                thumb, w, h = self.make_thumb(data)
                if w and h and "w" not in p:
                    p["w"], p["h"] = w, h
            att = self.put_blob(mkey + ":data", data, mime, p["filename"])
            p["size"] = len(data)
            self.n["att_" + kind] += 1
        elif kind == "image" and thumb:
            # Original nie heruntergeladen/abgelaufen: die Vorschau ist alles, was es noch gibt
            att = self.put_blob(mkey + ":thumb", thumb, "image/jpeg" if thumb[:2] == b"\xff\xd8" else "image/png",
                                "vorschau.jpg")
            p["size"] = len(thumb)
            p["preview_only"] = True
            if size:
                p["original_size"] = int(size)
            self.n["att_image_preview_only"] += 1
        elif data is not None:
            # leere Datei (0 Byte): Eintrag ohne Anhang
            kind = "file"
            p.pop("w", None), p.pop("h", None)
            p["size"] = 0
            self.n["att_file_empty"] += 1
        else:
            if kind != "file":
                p.pop("w", None), p.pop("h", None)
            kind = "file"
            p["missing"] = True
            if size:
                p["size"] = int(size)
            self.n["att_file_missing"] += 1
        if thumb and data and kind in ("image", "video", "file"):
            tid = self.put_blob(mkey + ":thumb", thumb, "image/jpeg" if thumb[:2] == b"\xff\xd8" else "image/png",
                                "thumb.jpg")
        if kind == "image" and att and not data:
            tid = att
        return kind, caption, p, att, tid

    def ballot(self, m):
        """Umfrage → (Frage, Optionen, multi, geschlossen, eigene Stimmen)."""
        b = self.src.one("SELECT * FROM ZBALLOT WHERE Z_PK=?", (col(m, "ZBALLOT"),)) if self.src.has("ZBALLOT") else None
        if not b:
            return None
        choices = self.src.q("SELECT * FROM ZBALLOTCHOICE WHERE ZBALLOT=? ORDER BY ZORDERPOSITION, ZID", (b["Z_PK"],))
        if not choices:
            return None
        opts = [{"id": sid("opt", b["Z_PK"], c["Z_PK"]), "text": (c["ZNAME"] or "")[:500]} for c in choices]
        mine = []
        ids = self.my_identities
        for c, o in zip(choices, opts):
            for r in self.src.q("SELECT * FROM ZBALLOTRESULT WHERE ZBALLOTCHOICE=?", (c["Z_PK"],)):
                if r["ZVALUE"] and (r["ZPARTICIPANTID"] in ids):
                    mine.append(o["id"])
        payload = {"question": (col(b, "ZTITLE") or "")[:2000], "options": opts,
                   "multi": col(b, "ZCHOICESTYPE") == 1, "closed": col(b, "ZSTATE") == 1, "show_interim": True}
        return payload, mine

    # -- Lauf

    def run(self):
        s = self.src
        E = s.ents
        skip_ents = {E.get("SystemMessage")}
        self.my_identities = {r[0] for r in s.q("SELECT DISTINCT ZGROUPMYIDENTITY FROM ZCONVERSATION "
                                                 "WHERE ZGROUPMYIDENTITY IS NOT NULL")} if s.has("ZCONVERSATION", "ZGROUPMYIDENTITY") else set()
        stars = set()
        if s.has("ZMESSAGEMARKERS"):
            for r in s.q("SELECT Z_PK, ZMESSAGE, ZSTAR FROM ZMESSAGEMARKERS WHERE ZSTAR=1"):
                stars.add(("pk", r["ZMESSAGE"]))
                stars.add(("marker", r["Z_PK"]))
        for cv in s.q("SELECT * FROM ZCONVERSATION ORDER BY Z_PK"):
            self.conversation(cv, stars, skip_ents)
        return self.n

    def conversation(self, cv, stars, skip_ents):
        s, main, me = self.src, self.main, self.me
        key, kind, title, avatar = self.conv_info(cv)
        rid = sid(self.user["id"], "room", key)
        msgs = s.q("SELECT * FROM ZMESSAGE WHERE ZCONVERSATION=? ORDER BY ZDATE, Z_PK", (cv["Z_PK"],))
        dates = [ts(m["ZDATE"]) for m in msgs if m["ZDATE"] is not None]
        created = min(dates) if dates else (ts(col(cv, "ZLASTUPDATE")) or time.time())
        existing = self.db.one("SELECT deleted FROM rooms WHERE id=?", (rid,))
        if existing and existing["deleted"]:
            self.n["rooms_deleted_in_target"] += 1
            return
        self.n["rooms_existing" if existing else "rooms_new"] += 1
        self.n["rooms_" + kind] += 1
        other = "contact:" + key.split(":", 1)[1] if kind == "chat" else None

        # Welche Threema-IDs werden Einträge? (für Zitate)
        importable = {}
        for m in msgs:
            if m["Z_ENT"] in skip_ents or col(m, "ZDELETEDAT") is not None or m["ZID"] is None:
                continue
            importable[bytes(m["ZID"])] = sid(self.user["id"], "msg", key, bytes(m["ZID"]).hex())

        jobs = []  # (msg-dict, author, edited_at, star, reactions, votes)
        for m in msgs:
            ent = m["Z_ENT"]
            if ent in skip_ents:
                self.n["skip_system"] += 1
                continue
            if col(m, "ZDELETEDAT") is not None:
                self.n["skip_deleted"] += 1
                continue
            if m["ZID"] is None:
                self.n["skip_no_id"] += 1
                continue
            zid = bytes(m["ZID"])
            mid = importable[zid]
            if self.db.one("SELECT 1 FROM messages WHERE id=?", (mid,)):
                self.n["msg_existing"] += 1
                continue
            mkey = key + ":" + zid.hex()
            body, payload, att, thumb, extra_votes = "", {}, None, None, []
            E = s.ents
            if ent == E.get("TextMessage"):
                k = "text"
                body = col(m, "ZTEXT") or ""
                if not body.strip():
                    self.n["skip_empty"] += 1
                    continue
            elif ent in (E.get("FileMessage"), E.get("ImageMessage"), E.get("VideoMessage"), E.get("AudioMessage")):
                k, body, payload, att, thumb = self.file_message(m, mkey)
            elif ent == E.get("LocationMessage"):
                k = "location"
                payload = {"lat": col(m, "ZLATITUDE") or 0.0, "lon": col(m, "ZLONGITUDE") or 0.0,
                           "name": (col(m, "ZPOINAME") or col(m, "ZPOIADDRESS") or "")[:500]}
            elif ent == E.get("BallotMessage"):
                b = self.ballot(m)
                if not b:
                    self.n["skip_ballot_empty"] += 1
                    continue
                k = "poll"
                payload, extra_votes = b
            else:
                self.n["skip_unknown_type"] += 1
                continue
            body = body[:65536]
            reply = None
            q = col(m, "ZQUOTEDMESSAGEID")
            if q is not None:
                reply = importable.get(bytes(q))
                self.n["quote_linked" if reply else "quote_target_missing"] += 1
            own = col(m, "ZISOWN")
            author = None
            if own == 0:
                c = self.contact(col(m, "ZSENDER"))
                ident = col(c, "ZIDENTITY") if c else None
                author_key = ("contact:" + ident) if ident else other
                if author_key:
                    author = sid(self.user["id"], "author", author_key)
                    self.n["msg_from_other_person"] += 1
            star = ("pk", m["Z_PK"]) in stars or ("marker", col(m, "ZMESSAGEMARKERS")) in stars
            reactions = []
            if s.has("ZMESSAGEREACTION"):
                for r in s.q("SELECT * FROM ZMESSAGEREACTION WHERE ZMESSAGE=?", (m["Z_PK"],)):
                    if r["ZREACTION"]:
                        c = self.contact(col(r, "ZCREATOR"))
                        who = sid(self.user["id"], "author", "contact:" + c["ZIDENTITY"]) if c else None
                        reactions.append((r["ZREACTION"][:16], who))
            if col(m, "ZUSERACKDATE") is not None:
                # alte Daumen-Bestätigung: bei fremden Einträgen meine, bei eigenen die der Gegenseite
                emoji = "👍" if col(m, "ZUSERACK") else "👎"
                if own == 0:
                    reactions.append((emoji, None))
                elif other:
                    reactions.append((emoji, sid(self.user["id"], "author", other)))
            msg = {"id": mid, "room_id": rid, "kind": k, "body": body, "payload": payload, "reply_to": reply,
                   "attachment": att, "thumb": thumb, "created_at": ts(m["ZDATE"])}
            jobs.append((msg, author, ts(col(m, "ZLASTEDITEDAT")), star, reactions, extra_votes))
            self.n["msg_new_" + k] += 1
            if star:
                self.n["star"] += 1
            self.n["reaction"] += len(reactions)

        vis = col(cv, "ZVISIBILITY") or 0
        pinned = vis == 2 or bool(col(cv, "ZMARKED"))
        archived = vis == 1
        if not existing:
            self.n["room_pinned"] += pinned
            self.n["room_archived"] += archived
        if not self.apply:
            return

        with self.db.tx():
            if not existing:
                av = self.put_blob(key + ":avatar", avatar, "image/jpeg", "avatar.jpg") if avatar else None
                main.op_room_create({"room": {"id": rid, "kind": kind, "title": title[:200], "avatar": av,
                                              "created_at": created}}, me)
            for msg, author, edited, star, reactions, votes in jobs:
                main.op_msg_create({"msg": msg}, me, author=author, touch=False)
                if edited:
                    self.db.x("UPDATE messages SET edited_at=? WHERE id=?", (edited, msg["id"]))
                if star:
                    main.op_star({"message_id": msg["id"], "on": True}, me)
                for emoji, who in reactions:
                    if who is None:
                        main.op_reaction({"message_id": msg["id"], "emoji": emoji, "on": True}, me)
                    else:
                        seq = self.db.change("reaction", f"{msg['id']}|{who}|{emoji}", rid)
                        self.db.x("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, active, room_id, seq) "
                                  "VALUES(?,?,?,1,?,?)", (msg["id"], who, emoji, rid, seq))
                if votes:
                    seq = self.db.change("vote", f"{msg['id']}|{me['id']}", rid)
                    self.db.x("INSERT OR REPLACE INTO votes(message_id, user_id, choices, room_id, seq) VALUES(?,?,?,?,?)",
                              (msg["id"], me["id"], json.dumps(votes), rid, seq))
            if not existing and (pinned or archived):
                main.op_roomstate({"room_id": rid, "pinned": pinned, "archived": archived}, me)
            if jobs or not existing:
                # Mitgliedschaft und Raum NACH den Einträgen neu melden: ein Gerät, das schon abgeglichen hat,
                # sieht den Raum dann erst, wenn seine Einträge schon da sind – und muss ihn nicht einzeln nachladen.
                main.set_member(rid, me["id"], "owner")
                main.touch_room(rid)
                last = self.db.one("SELECT MAX(created_at) AS t FROM messages WHERE room_id=? AND deleted=0", (rid,))
                upd = max(filter(None, [created, last["t"] if last else None, ts(col(cv, "ZLASTUPDATE"))]))
                self.db.x("UPDATE rooms SET updated_at=? WHERE id=?", (upd, rid))


def verify_sync(main, uid):
    """Was bekäme ein frisch angemeldetes Gerät dieses Kontos per /api/sync? (Zählung je Art)"""
    me = {"id": uid, "device_id": None}
    since, pages, kinds = 0, 0, Counter()
    while True:
        r = main.sync(since=since, limit=1000, room=None, me=me)
        pages += 1
        for c in r["changes"]:
            d = c["data"]
            if c["kind"] == "message":
                kinds["message_" + d["kind"] + ("_deleted" if d["deleted"] else "")] += 1
            elif c["kind"] == "room":
                kinds["room" + ("_deleted" if d["deleted"] else "")] += 1
            else:
                kinds[c["kind"]] += 1
        since = r["next"]
        if not r["more"]:
            break
    kinds["_pages"] = pages
    return kinds


def main_cli(argv=None):
    ap = argparse.ArgumentParser(description="Threema-Verlauf (iMazing-Extraktion) in ein HomeThread-Konto übernehmen")
    ap.add_argument("source")
    ap.add_argument("--user", required=True)
    ap.add_argument("--device")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args(argv)

    os.environ.setdefault("HT_DATA", "/data")
    from . import main
    u = main.db.one("SELECT * FROM users WHERE username=? AND disabled=0", (a.user.strip().lower(),))
    if not u:
        raise SystemExit("Konto nicht gefunden")
    dev = None
    if a.device:
        d = main.db.one("SELECT id FROM devices WHERE user_id=? AND revoked IS NULL AND (id=? OR name=?)",
                        (u["id"], a.device, a.device))
        if not d:
            raise SystemExit("Gerät nicht gefunden")
        dev = d["id"]
    src = Source(a.source)
    try:
        imp = Importer(src, main, u, dev, apply=a.apply)
        seq0 = main.db.max_seq()
        n = imp.run()
    finally:
        src.close()
    out = dict(sorted(n.items()))
    out["attachment_bytes_new"] = imp.bytes
    out["mode"] = "apply" if a.apply else "dry-run"
    out["changes_written"] = main.db.max_seq() - seq0
    print(json.dumps(out, indent=1))
    if a.verify:
        print(json.dumps({"sync_fresh_device": dict(sorted(verify_sync(main, u["id"]).items()))}, indent=1))


if __name__ == "__main__":
    main_cli(sys.argv[1:])
