"""Import aus Threema gegen eine kleine, selbst erzeugte Test-Datenbank (erfundene Inhalte, nachgebautes
Core-Data-Schema mit eingebetteten und externen Blobs)."""
import json
import os
import sqlite3
import tempfile
import time
import unittest
import uuid
import zipfile

os.environ.setdefault("HT_DATA", tempfile.mkdtemp())

from homethread import main, security as sec  # noqa: E402
from homethread import import_threema as it  # noqa: E402

T0 = 800000000.0  # Sekunden seit 2001-01-01


def make_user(name):
    uid = str(uuid.uuid4())
    main.db.x("INSERT INTO users(id, username, display_name, pw_hash, totp_secret, created) VALUES(?,?,?,?,?,?)",
              (uid, name, name.title(), sec.hash_pw("x" * 16), sec.new_totp_secret(), time.time()))
    return main.db.one("SELECT * FROM users WHERE id=?", (uid,))


ENTS = ["AudioData", "Ballot", "BallotChoice", "BallotResult", "Call", "Contact", "Conversation", "DistributionList",
        "FileData", "Group", "GroupCallEntity", "ImageData", "LastGroupSyncRequest", "Message", "AudioMessage",
        "BallotMessage", "FileMessage", "ImageMessage", "LocationMessage", "SystemMessage", "TextMessage",
        "VideoMessage", "MessageHistoryEntry", "MessageMarkers", "MessageReaction"]
E = {n: i + 1 for i, n in enumerate(ENTS)}

SCHEMA = """
CREATE TABLE Z_PRIMARYKEY(Z_ENT INTEGER, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
CREATE TABLE ZCONTACT(Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZFIRSTNAME VARCHAR, ZLASTNAME VARCHAR,
  ZPUBLICNICKNAME VARCHAR, ZIDENTITY VARCHAR, ZCONTACTIMAGE INTEGER, ZIMAGEDATA BLOB);
CREATE TABLE ZCONVERSATION(Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZCATEGORY INTEGER, ZMARKED INTEGER,
  ZVISIBILITY INTEGER, ZCONTACT INTEGER, ZDISTRIBUTIONLIST INTEGER, ZGROUPIMAGE INTEGER, ZLASTUPDATE TIMESTAMP,
  ZGROUPMYIDENTITY VARCHAR, ZGROUPNAME VARCHAR, ZGROUPID BLOB);
CREATE TABLE ZDISTRIBUTIONLIST(Z_PK INTEGER PRIMARY KEY, ZDISTRIBUTIONLISTID INTEGER, ZCONVERSATION INTEGER, ZNAME VARCHAR);
CREATE TABLE ZFILEDATA(Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZDATA BLOB);
CREATE TABLE ZIMAGEDATA(Z_PK INTEGER PRIMARY KEY, ZHEIGHT INTEGER, ZWIDTH INTEGER, ZMESSAGE INTEGER, ZDATA BLOB);
CREATE TABLE ZMESSAGE(Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZISOWN INTEGER, ZUSERACK INTEGER,
  ZCONVERSATION INTEGER, ZMESSAGEMARKERS INTEGER, ZSENDER INTEGER, ZBALLOT INTEGER, ZFILESIZE INTEGER,
  ZDATA INTEGER, ZTHUMBNAIL INTEGER, ZTYPE1 INTEGER, ZDATE TIMESTAMP, ZDELETEDAT TIMESTAMP, ZLASTEDITEDAT TIMESTAMP,
  ZUSERACKDATE TIMESTAMP, ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ZCAPTION VARCHAR, ZFILENAME VARCHAR, ZJSON VARCHAR,
  ZMIMETYPE VARCHAR, ZPOINAME VARCHAR, ZPOIADDRESS VARCHAR, ZTEXT VARCHAR, ZID BLOB, ZQUOTEDMESSAGEID BLOB);
CREATE TABLE ZMESSAGEMARKERS(Z_PK INTEGER PRIMARY KEY, ZSTAR INTEGER, ZMESSAGE INTEGER);
CREATE TABLE ZMESSAGEREACTION(Z_PK INTEGER PRIMARY KEY, ZCREATOR INTEGER, ZMESSAGE INTEGER, ZDATE TIMESTAMP, ZREACTION VARCHAR);
CREATE TABLE ZBALLOT(Z_PK INTEGER PRIMARY KEY, ZCHOICESTYPE INTEGER, ZSTATE INTEGER, ZCONVERSATION INTEGER, ZTITLE VARCHAR);
CREATE TABLE ZBALLOTCHOICE(Z_PK INTEGER PRIMARY KEY, ZID INTEGER, ZORDERPOSITION INTEGER, ZBALLOT INTEGER, ZNAME VARCHAR);
CREATE TABLE ZBALLOTRESULT(Z_PK INTEGER PRIMARY KEY, ZVALUE INTEGER, ZBALLOTCHOICE INTEGER, ZPARTICIPANTID VARCHAR);
"""

EXT_PHOTO = b"\xff\xd8" + b"photo-bytes" * 50
EXT_UUID = "0A1B2C3D-0000-4000-8000-00000000AAAA"
THUMB = b"\xff\xd8" + b"thumb" * 10


def zid(n):
    return n.to_bytes(8, "big")


def build(folder):
    """Kleine Threema-Datenbank mit erfundenen Inhalten (Ordnerstruktur wie in der iMazing-Extraktion)."""
    g = os.path.join(folder, "Container", "AppGroups", "group.ch.threema")
    os.makedirs(os.path.join(g, it.EXT_DIR))
    with open(os.path.join(g, it.EXT_DIR, EXT_UUID), "wb") as f:
        f.write(EXT_PHOTO)
    c = sqlite3.connect(os.path.join(g, it.DB_NAME))
    c.executescript(SCHEMA)
    c.executemany("INSERT INTO Z_PRIMARYKEY(Z_ENT, Z_NAME) VALUES(?,?)", [(v, k) for k, v in E.items()])
    c.execute("INSERT INTO ZCONTACT(Z_PK, ZPUBLICNICKNAME, ZIDENTITY) VALUES(1, 'Robin', 'ABCD1234')")
    c.execute("INSERT INTO ZCONVERSATION(Z_PK, ZVISIBILITY, ZLASTUPDATE, ZGROUPMYIDENTITY, ZGROUPNAME, ZGROUPID) "
              "VALUES(1, 2, ?, 'MYID0001', 'Einkauf', x'01020304')", (T0 + 900,))
    c.execute("INSERT INTO ZCONVERSATION(Z_PK, ZVISIBILITY, ZCONTACT, ZLASTUPDATE) VALUES(2, 0, 1, ?)", (T0 + 500,))
    c.execute("INSERT INTO ZCONVERSATION(Z_PK, ZVISIBILITY, ZLASTUPDATE, ZGROUPMYIDENTITY, ZGROUPNAME, ZGROUPID) "
              "VALUES(3, 0, ?, 'MYID0001', 'Leer', x'05060708')", (T0 + 50,))
    c.execute("INSERT INTO ZIMAGEDATA(Z_PK, ZWIDTH, ZHEIGHT, ZDATA) VALUES(1, 40, 30, ?)", (b"\x01" + THUMB,))
    c.execute("INSERT INTO ZIMAGEDATA(Z_PK, ZWIDTH, ZHEIGHT, ZDATA) VALUES(2, 40, 30, ?)", (b"\x01" + THUMB,))
    c.execute("INSERT INTO ZFILEDATA(Z_PK, ZDATA) VALUES(1, ?)", (b"\x02" + EXT_UUID.encode() + b"\x00",))
    c.execute("INSERT INTO ZFILEDATA(Z_PK, ZDATA) VALUES(2, ?)", (b"\x01" + b"AUDIO" * 20,))
    c.execute("INSERT INTO ZFILEDATA(Z_PK, ZDATA) VALUES(3, ?)", (b"\x01",))  # leere Datei
    c.execute("INSERT INTO ZMESSAGEMARKERS(Z_PK, ZSTAR, ZMESSAGE) VALUES(1, 1, 3)")
    c.execute("INSERT INTO ZBALLOT(Z_PK, ZCHOICESTYPE, ZSTATE, ZCONVERSATION, ZTITLE) VALUES(1, 0, 0, 1, 'Pizza?')")
    c.execute("INSERT INTO ZBALLOTCHOICE(Z_PK, ZID, ZORDERPOSITION, ZBALLOT, ZNAME) VALUES(1, 0, 0, 1, 'Ja'), (2, 1, 1, 1, 'Nein')")
    c.execute("INSERT INTO ZBALLOTRESULT(Z_PK, ZVALUE, ZBALLOTCHOICE, ZPARTICIPANTID) VALUES(1, 1, 2, 'MYID0001')")
    rows = [
        # pk, ent, conv, own, date, text, extra
        (1, "SystemMessage", 1, 1, 0, None, {}),
        (2, "TextMessage", 1, 1, 10, "Milch", {}),
        (3, "TextMessage", 1, 1, 20, "Brot", {"ZMESSAGEMARKERS": 1, "ZLASTEDITEDAT": T0 + 25}),
        (4, "TextMessage", 1, 1, 30, None, {"ZDELETEDAT": T0 + 31}),
        (5, "TextMessage", 1, 1, 40, "Antwort", {"ZQUOTEDMESSAGEID": zid(2)}),
        (6, "FileMessage", 1, 1, 50, None, {"ZDATA": 1, "ZTHUMBNAIL": 1, "ZMIMETYPE": "image/jpeg",
                                              "ZFILENAME": "a.jpg", "ZFILESIZE": len(EXT_PHOTO),
                                              "ZJSON": json.dumps({"j": 1, "d": "Bildtext", "x": {"w": 400, "h": 300}})}),
        (7, "FileMessage", 1, 1, 60, None, {"ZTHUMBNAIL": 2, "ZMIMETYPE": "image/jpeg", "ZFILENAME": "b.jpg",
                                              "ZFILESIZE": 99999, "ZJSON": json.dumps({"j": 1})}),
        (8, "FileMessage", 1, 1, 70, None, {"ZMIMETYPE": "application/pdf", "ZFILENAME": "c.pdf", "ZFILESIZE": 1234,
                                              "ZJSON": json.dumps({"j": 0})}),
        (9, "FileMessage", 1, 1, 80, None, {"ZDATA": 2, "ZMIMETYPE": "audio/aac", "ZFILENAME": "d.aac",
                                              "ZFILESIZE": 100, "ZJSON": json.dumps({"j": 1, "x": {"d": 3.5}})}),
        (10, "BallotMessage", 1, 1, 90, None, {"ZBALLOT": 1}),
        (11, "TextMessage", 2, 1, 100, "Hallo", {}),
        (12, "TextMessage", 2, 0, 110, "Hi zurück", {}),
        (13, "SystemMessage", 3, 1, 5, None, {}),
        (14, "FileMessage", 2, 1, 120, None, {"ZDATA": 3, "ZMIMETYPE": "text/plain", "ZFILENAME": "e.txt",
                                               "ZFILESIZE": 0, "ZJSON": "{}"}),
    ]
    for pk, ent, conv, own, d, text, extra in rows:
        cols = {"Z_PK": pk, "Z_ENT": E[ent], "ZCONVERSATION": conv, "ZISOWN": own, "ZUSERACK": 0,
                "ZDATE": T0 + d, "ZTEXT": text, "ZID": zid(pk), **extra}
        c.execute(f"INSERT INTO ZMESSAGE({','.join(cols)}) VALUES({','.join('?' * len(cols))})", list(cols.values()))
    c.execute("INSERT INTO ZMESSAGEREACTION(Z_PK, ZCREATOR, ZMESSAGE, ZREACTION) VALUES(1, NULL, 2, '❤️')")
    c.commit()
    c.close()
    return folder


def run(src_path, user, apply):
    src = it.Source(src_path)
    try:
        imp = it.Importer(src, main, user, None, apply=apply)
        return imp.run(), imp
    finally:
        src.close()


class ImportThreemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = build(tempfile.mkdtemp())
        cls.user = make_user("importer")

    def rooms(self, uid):
        return main.db.q("SELECT r.* FROM rooms r JOIN members m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.created_at",
                         (uid,))

    def test_1_dry_run_counts_without_writing(self):
        seq = main.db.max_seq()
        n, imp = run(self.folder, self.user, apply=False)
        self.assertEqual(main.db.max_seq(), seq)
        self.assertEqual(n["rooms_new"], 3)
        self.assertEqual(n["skip_system"], 2)
        self.assertEqual(n["skip_deleted"], 1)
        self.assertEqual(n["msg_new_text"], 5)
        self.assertEqual(n["msg_new_image"], 2)
        self.assertEqual(n["msg_new_file"], 2)
        self.assertEqual(n["att_file_empty"], 1)
        self.assertEqual(n["msg_new_voice"], 1)
        self.assertEqual(n["msg_new_poll"], 1)
        self.assertEqual(n["att_image_preview_only"], 1)
        self.assertEqual(n["att_file_missing"], 1)
        self.assertEqual(n["quote_linked"], 1)
        self.assertEqual(n["msg_from_other_person"], 1)
        self.assertFalse(self.rooms(self.user["id"]))

    def test_2_apply_maps_everything(self):
        uid = self.user["id"]
        n, _ = run(self.folder, self.user, apply=True)
        rooms = self.rooms(uid)
        self.assertEqual([r["kind"] for r in rooms], ["group", "group", "chat"])
        group = next(r for r in rooms if r["title"] == "Einkauf")
        chat = next(r for r in rooms if r["kind"] == "chat")
        self.assertEqual(chat["title"], "Robin")
        self.assertAlmostEqual(group["created_at"], T0 + it.EPOCH_2001)
        msgs = main.db.q("SELECT * FROM messages WHERE room_id=? ORDER BY created_at", (group["id"],))
        self.assertEqual([m["kind"] for m in msgs], ["text", "text", "text", "image", "image", "file", "voice", "poll"])
        self.assertAlmostEqual(msgs[0]["created_at"], T0 + 10 + it.EPOCH_2001)
        self.assertEqual(msgs[2]["reply_to"], msgs[0]["id"])
        self.assertIsNotNone(msgs[1]["edited_at"])
        # Foto aus externer Datei, mit Threema-Vorschau und Bildunterschrift
        photo = msgs[3]
        p = json.loads(photo["payload"])
        self.assertEqual(photo["body"], "Bildtext")
        self.assertEqual((p["w"], p["h"], p["size"]), (400, 300, len(EXT_PHOTO)))
        with open(main.blob_path(photo["attachment"]), "rb") as f:
            self.assertEqual(f.read(), EXT_PHOTO)
        self.assertIsNotNone(photo["thumb"])
        # Original fehlt → nur die Vorschau
        self.assertTrue(json.loads(msgs[4]["payload"])["preview_only"])
        self.assertEqual(msgs[4]["attachment"], msgs[4]["thumb"])
        # Datei ohne Daten → Eintrag ohne Anhang
        self.assertIsNone(msgs[5]["attachment"])
        self.assertTrue(json.loads(msgs[5]["payload"])["missing"])
        self.assertEqual(json.loads(msgs[6]["payload"])["duration"], 3.5)
        poll = json.loads(msgs[7]["payload"])
        self.assertEqual([o["text"] for o in poll["options"]], ["Ja", "Nein"])
        vote = main.db.one("SELECT choices FROM votes WHERE message_id=?", (msgs[7]["id"],))
        self.assertEqual(json.loads(vote["choices"]), [poll["options"][1]["id"]])
        self.assertTrue(main.db.one("SELECT active FROM stars WHERE message_id=? AND user_id=?", (msgs[1]["id"], uid))["active"])
        self.assertTrue(main.db.one("SELECT 1 FROM reactions WHERE message_id=? AND user_id=? AND emoji='❤️'", (msgs[0]["id"], uid)))
        self.assertEqual(main.db.one("SELECT pinned FROM roomstate WHERE room_id=? AND user_id=?", (group["id"], uid))["pinned"], 1)
        # Einzelchat: Eintrag der Gegenseite hat einen anderen Autor
        cm = main.db.q("SELECT author_id FROM messages WHERE room_id=? ORDER BY created_at", (chat["id"],))
        self.assertEqual(cm[0]["author_id"], uid)
        self.assertNotEqual(cm[1]["author_id"], uid)
        # Mitgliedschaft wird nach den Einträgen gemeldet (Geräte müssen den Raum nicht einzeln nachladen)
        mseq = main.db.one("SELECT seq FROM members WHERE room_id=? AND user_id=?", (group["id"], uid))["seq"]
        self.assertGreater(mseq, max(m["seq"] for m in msgs))

        # zweiter Lauf: nichts Neues
        seq = main.db.max_seq()
        n2, _ = run(self.folder, self.user, apply=True)
        self.assertEqual(main.db.max_seq(), seq)
        self.assertEqual(n2["rooms_existing"], 3)
        self.assertEqual(n2["msg_existing"], 11)
        self.assertFalse([k for k in n2 if k.startswith("msg_new")])

        # frisches Gerät bekommt alles per Sync
        k = it.verify_sync(main, uid)
        self.assertEqual(k["room"], 3)
        self.assertEqual(k["message_text"], 5)
        self.assertEqual(k["message_image"], 2)

    def test_3_deleted_in_target_stays_deleted(self):
        uid = self.user["id"]
        m = main.db.one("SELECT m.* FROM messages m JOIN members x ON x.room_id=m.room_id WHERE x.user_id=? AND m.body='Hallo'",
                        (uid,))
        main.op_msg_delete({"id": m["id"]}, {"id": uid, "device_id": None})
        run(self.folder, self.user, apply=True)
        self.assertEqual(main.db.one("SELECT deleted FROM messages WHERE id=?", (m["id"],))["deleted"], 1)

    def test_4_zip_source(self):
        z = os.path.join(tempfile.mkdtemp(), "Threema.imazingapp")
        with zipfile.ZipFile(z, "w") as f:
            for root, _, files in os.walk(self.folder):
                for name in files:
                    full = os.path.join(root, name)
                    f.write(full, os.path.relpath(full, self.folder))
        other = make_user("zipper")
        n, _ = run(z, other, apply=True)
        self.assertEqual(n["rooms_new"], 3)
        photo = main.db.one("SELECT m.attachment FROM messages m JOIN members x ON x.room_id=m.room_id "
                            "WHERE x.user_id=? AND m.kind='image' AND m.body='Bildtext'", (other["id"],))
        with open(main.blob_path(photo["attachment"]), "rb") as f:
            self.assertEqual(f.read(), EXT_PHOTO)


if __name__ == "__main__":
    unittest.main()
