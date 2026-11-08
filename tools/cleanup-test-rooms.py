#!/usr/bin/env python3
"""Löscht Räume, die UI-/Gerätetests im TESTKONTO hinterlassen haben (Titel „UI …“, „Von Gerät B …“, „iPhone Testgruppe“, „Sync-Test …“).
Nur mit dem Testkonto-Token aus .test-tokens (tools/test-tokens.py); bricht ab, wenn das Konto nicht das Testkonto ist.
  python3 tools/cleanup-test-rooms.py [--dry-run]"""
import json, os, re, sys, urllib.request, uuid

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
acc = dict(l.strip().split("=", 1) for l in open(os.path.join(root, ".test-account")) if "=" in l and not l.startswith("#"))
toks = dict(l.strip().split("=", 1) for l in open(os.path.join(root, ".test-tokens")) if "=" in l)
server, token = toks["THREAD_SERVER"], toks["THREAD_TOKEN"]
PATTERN = re.compile(r"^(UI .*|Von Gerät B.*|iPhone Testgruppe.*|Sync-Test \d+|Unit-Test)$")


def call(path, body=None):
    r = urllib.request.Request(server + path, data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(r, timeout=60) as x:
        return json.loads(x.read())


me = call("/api/me")
user = (me.get("user") or me).get("username")
if not user or user != acc.get("THREAD_USER"):
    sys.exit(f"Abbruch: Token gehört nicht zum Testkonto ({user!r})")

rooms, since = {}, 0
while True:
    page = call(f"/api/sync?since={since}&limit=1000")
    for c in page["changes"]:
        if c["kind"] == "room":
            rooms[c["data"]["id"]] = c["data"]
    since = page["next"]
    if not page["more"]:
        break

victims = [r for r in rooms.values() if not r.get("deleted") and PATTERN.match(r.get("title") or "")]
print(f"Konto {user}: {len(rooms)} Räume, davon {len(victims)} aus Tests")
for r in sorted(victims, key=lambda r: r["title"]):
    print("  -", r["title"])
if "--dry-run" in sys.argv or not victims:
    sys.exit(0)
for i in range(0, len(victims), 50):
    res = call("/api/ops", {"ops": [{"op_id": str(uuid.uuid4()), "type": "room.delete", "room_id": r["id"]} for r in victims[i:i + 50]]})
    bad = [x for x in res.get("results", []) if not x.get("ok", True) or x.get("error")]
    if bad:
        print("Fehler:", bad[:3])
print(f"gelöscht: {len(victims)}")
