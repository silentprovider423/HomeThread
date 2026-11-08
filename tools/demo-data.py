#!/usr/bin/env python3
"""Füllt das Demokonto mit erfundenen englischen Inhalten für die README-Screenshots (nie echte Daten).
Löscht vorher alle Räume des Demokontos. Bilder/Sprachnotiz werden lokal erzeugt (tools/demo-media/).
  python3 tools/demo-data.py"""
import hashlib, json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
toks = dict(l.strip().split("=", 1) for l in open(os.path.join(root, ".test-tokens")) if "=" in l)
SERVER, TOKEN = toks["THREAD_SERVER"], toks["THREAD_DEMO_TOKEN"]
# Ein paar Einträge kommen vom „zweiten Gerät“, damit die App „neu von anderem Gerät“ zeigt
TOKEN2 = toks.get("THREAD_DEMO_TOKEN2", TOKEN)
media = os.path.join(root, "build", "demo-media")
os.makedirs(media, exist_ok=True)


def call(method, path, body=None, raw=None, headers=None, token=None):
    h = {"Authorization": "Bearer " + (token or TOKEN), **(headers or {})}
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if body is not None:
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(SERVER + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=60) as x:
        return json.loads(x.read() or b"{}")


def nid():
    return str(uuid.uuid4())


ops = []


def op(t, **f):
    ops.append({"op_id": nid(), "type": t, **f})
    return f


def flush(token=None):
    global ops
    for i in range(0, len(ops), 100):
        res = call("POST", "/api/ops", {"ops": ops[i:i + 100]}, token=token)["results"]
        bad = [r for r in res if not r.get("ok")]
        if bad:
            sys.exit(f"Fehler: {bad[:3]}")
    ops = []


def blob(path, mime):
    bid = nid()
    data = open(path, "rb").read()
    call("PUT", f"/api/blobs/{bid}", raw=data, headers={"Content-Type": mime, "X-Filename": os.path.basename(path)})
    return bid


def swift_image(name, kind, w, h):
    """Erfundenes Bild mit CoreGraphics (keine Metadaten)."""
    out = os.path.join(media, name)
    if os.path.exists(out):
        return out
    src = os.path.join(media, "img.swift")
    open(src, "w").write(r'''
import AppKit
let a = CommandLine.arguments; let kind = a[1]; let w = Int(a[2])!; let h = Int(a[3])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
func col(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
let W = CGFloat(w), H = CGFloat(h)
if kind == "sea" {
  c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [col(1, 0.62, 0.35), col(0.98, 0.84, 0.6)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.45), options: [])
  c.setFillColor(col(1, 0.93, 0.7)); c.fillEllipse(in: CGRect(x: W * 0.42, y: H * 0.42, width: W * 0.16, height: W * 0.16))
  c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [col(0.1, 0.45, 0.6), col(0.02, 0.2, 0.32)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: H * 0.45), end: CGPoint(x: 0, y: 0), options: [])
  c.setFillColor(col(0.12, 0.3, 0.25)); c.move(to: CGPoint(x: 0, y: H * 0.45)); c.addLine(to: CGPoint(x: W * 0.3, y: H * 0.58))
  c.addLine(to: CGPoint(x: W * 0.5, y: H * 0.45)); c.fillPath()
} else if kind == "garden" {
  c.setFillColor(col(0.55, 0.78, 0.95)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
  c.setFillColor(col(0.35, 0.62, 0.25)); c.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.42))
  for i in 0..<7 {
    let x = W * (0.08 + 0.13 * CGFloat(i))
    c.setStrokeColor(col(0.2, 0.45, 0.15)); c.setLineWidth(W * 0.012); c.move(to: CGPoint(x: x, y: H * 0.2)); c.addLine(to: CGPoint(x: x, y: H * 0.5)); c.strokePath()
    c.setFillColor(i % 2 == 0 ? col(0.9, 0.2, 0.25) : col(0.98, 0.75, 0.2))
    c.fillEllipse(in: CGRect(x: x - W * 0.04, y: H * 0.47, width: W * 0.08, height: W * 0.08))
  }
} else {
  c.setFillColor(col(0.96, 0.93, 0.87)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
  let cols = [col(0.8, 0.3, 0.25), col(0.2, 0.45, 0.6), col(0.3, 0.55, 0.35), col(0.85, 0.65, 0.2), col(0.45, 0.35, 0.6)]
  for i in 0..<9 { c.setFillColor(cols[i % 5]); c.fill(CGRect(x: W * (0.1 + 0.085 * CGFloat(i)), y: H * 0.2, width: W * 0.07, height: H * (0.45 + 0.05 * CGFloat(i % 3)))) }
  c.setFillColor(col(0.45, 0.3, 0.2)); c.fill(CGRect(x: W * 0.05, y: H * 0.15, width: W * 0.9, height: H * 0.05))
}
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: URL(fileURLWithPath: a[4]))
''')
    subprocess.run(["swift", src, kind, str(w), str(h), out], check=True)
    return out


def thumb(path):
    t = path.replace(".jpg", "-thumb.jpg")
    subprocess.run(["sips", "-Z", "480", path, "--out", t], check=True, capture_output=True)
    return t


def voice():
    out = os.path.join(media, "voice.m4a")
    if not os.path.exists(out):
        aiff = os.path.join(media, "voice.aiff")
        subprocess.run(["say", "-v", "Samantha", "-o", aiff, "Remember to book the ferry to Cacilhas for Saturday morning, "
                        "and ask about the tile workshop."], check=True)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", aiff, out], check=True)
    return out


# Alles Alte des Demokontos entfernen
cursor, rooms = 0, set()
while True:
    s = call("GET", f"/api/sync?since={cursor}&limit=1000")
    for c in s["changes"]:
        if c["kind"] == "room" and not c["data"]["deleted"]:
            rooms.add(c["data"]["id"])
        if c["kind"] == "room" and c["data"]["deleted"]:
            rooms.discard(c["data"]["id"])
    cursor = s["next"]
    if not s["more"]:
        break
for r in rooms:
    op("room.delete", room_id=r)
flush()

now = time.time()
day = 86400


def room(title, kind="chat", avatar=None, pinned=False, created=None):
    rid = nid()
    r = {"id": rid, "kind": kind, "title": title, "created_at": created or now - 20 * day}
    if avatar:
        r["avatar"] = avatar
    op("room.create", room=r)
    if pinned:
        op("roomstate.set", room_id=rid, pinned=True)
    return rid


def msg(rid, body="", kind="text", at=None, **extra):
    mid = nid()
    m = {"id": mid, "room_id": rid, "kind": kind, "body": body, "created_at": at, **extra}
    op("msg.create", msg=m)
    return mid


sea = swift_image("lisbon.jpg", "sea", 1600, 1200)
garden = swift_image("garden.jpg", "garden", 1200, 1200)
books = swift_image("books.jpg", "books", 1400, 1000)

# 1) Trip (Gruppe mit Bild, angeheftet)
trip_avatar = blob(thumb(sea), "image/jpeg")
trip = room("Trip to Lisbon", "group", avatar=trip_avatar, pinned=True)
t0 = now - 2 * day
msg(trip, "Flights booked Friday 07:40, back on Tuesday evening.", at=t0)
m_hotel = msg(trip, "Hotel: Casa do Largo, Alfama – check-in from 3 pm. Confirmation number is in the mail folder.", at=t0 + 600)
op("msg.pin", id=m_hotel, pinned=True)
op("star.set", message_id=m_hotel, on=True)
poll_id = msg(trip, kind="poll", at=t0 + 3600, payload={"question": "Dinner on Saturday?", "multi": False, "show_interim": True,
              "options": [{"id": "o1", "text": "Time Out Market"}, {"id": "o2", "text": "Seafood in Cais do Sodré"},
                          {"id": "o3", "text": "Cook at the apartment"}]})
op("vote.set", message_id=poll_id, choices=["o2"])
msg(trip, kind="location", at=now - day - 3000, payload={"lat": 38.711, "lon": -9.13, "name": "Miradouro da Graça"})
img = blob(sea, "image/jpeg")
th = blob(thumb(sea), "image/jpeg")
sunset = msg(trip, "Sunset from the viewpoint", kind="image", at=now - day - 2400, attachment=img, thumb=th,
    payload={"w": 1600, "h": 1200, "mime": "image/jpeg", "filename": "lisbon.jpg", "size": os.path.getsize(sea)})
op("reaction.set", message_id=sunset, emoji="❤️", on=True)
v = blob(voice(), "audio/mp4")
msg(trip, kind="voice", at=now - 3 * 3600, attachment=v,
    payload={"duration": 6.0, "mime": "audio/mp4", "filename": "voice.m4a",
             "wave": [0.2, 0.4, 0.7, 0.5, 0.8, 0.6, 0.3, 0.5, 0.9, 0.7, 0.4, 0.6, 0.8, 0.5, 0.3, 0.6, 0.7, 0.9, 0.6, 0.4,
                      0.5, 0.7, 0.3, 0.2, 0.5, 0.8, 0.6, 0.4, 0.3, 0.2]})
cl = msg(trip, "Packing list", kind="checklist", at=now - 2 * 3600,
         items=[{"id": nid(), "text": t, "position": i, "done": d} for i, (t, d) in enumerate(
             [("Passports", True), ("Travel adapter", True), ("Sunscreen", False), ("Comfortable shoes", False), ("Camera charger", False)])])
r1 = msg(trip, "Don't forget the tram 28 – early in the morning it's empty.", at=now - 40 * 60)
msg(trip, "Good idea, we go right after breakfast.", at=now - 35 * 60, reply_to=r1)

flush()
# die letzten zwei Einträge „vom Mac“
msg(trip, "Found a nice tile workshop near the cathedral – Saturday 11:00?", at=now - 20 * 60)
msg(trip, kind="location", at=now - 19 * 60, payload={"lat": 38.7099, "lon": -9.1335, "name": "Tile workshop"})
flush(TOKEN2)

# 2) Groceries
gro = room("Groceries", pinned=False)
msg(gro, "Weekly shop", kind="checklist", at=now - 5 * 3600,
    items=[{"id": nid(), "text": t, "position": i, "done": d} for i, (t, d) in enumerate(
        [("Oat milk", True), ("Tomatoes", False), ("Basil", False), ("Sourdough bread", True), ("Coffee beans", False), ("Lemons", False)])])
flush()
msg(gro, "The good olive oil is on offer at the market on Saturday", at=now - 70 * 60)
flush(TOKEN2)

# 3) Ideas
ideas = room("Ideas")
msg(ideas, "App idea: a plant watering reminder that reads the weather forecast.", at=now - 6 * day)
i2 = msg(ideas, "Blog post: **what I learned from self-hosting for a year** – backups first, then everything else.", at=now - 4 * day)
op("star.set", message_id=i2, on=True)
op("reaction.set", message_id=i2, emoji="💡", on=True)
msg(ideas, "Birthday gift for Sam: pottery class voucher?", at=now - 26 * 3600)

# 4) Garden
gar = room("Garden", "group", created=now - 30 * day)
gimg = blob(garden, "image/jpeg")
gth = blob(thumb(garden), "image/jpeg")
msg(gar, "Tulips are out!", kind="image", at=now - 3 * day, attachment=gimg, thumb=gth,
    payload={"w": 1200, "h": 1200, "mime": "image/jpeg", "filename": "garden.jpg", "size": os.path.getsize(garden)})
msg(gar, "Water the tomatoes every second day while it's this warm.", at=now - 3 * day + 900)

# 5) Reading list
rl = room("Reading list", created=now - 40 * day)
bimg = blob(books, "image/jpeg")
bth = blob(thumb(books), "image/jpeg")
msg(rl, kind="image", at=now - 9 * day, attachment=bimg, thumb=bth,
    payload={"w": 1400, "h": 1000, "mime": "image/jpeg", "filename": "shelf.jpg", "size": os.path.getsize(books)})
msg(rl, "Next up: “The Overstory”, then something light for the holidays.", at=now - 8 * day)

# 6) Archived example
arch = room("Old apartment", created=now - 90 * day)
msg(arch, "Keys handed over", at=now - 60 * day)
op("roomstate.set", room_id=arch, archived=True)

flush()
print("Demodaten angelegt")
