#!/usr/bin/env python3
"""Holt Geräte-Token für Tests (Gerät A + B) mit dem Testkonto aus .test-account und legt sie in .test-tokens ab.
Vorhandene, noch gültige Token werden wiederverwendet (jeder Authenticator-Code gilt nur einmal, ein neuer kommt alle 30 s).
  python3 tools/test-tokens.py [demo]     → THREAD_TOKEN, THREAD_TOKEN2 (bzw. THREAD_DEMO_TOKEN)"""
import base64, hashlib, hmac, json, os, struct, sys, time, urllib.error, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(l.strip().split("=", 1) for l in open(os.path.join(root, ".test-account")) if "=" in l and not l.startswith("#"))
tokfile = os.path.join(root, ".test-tokens")
toks = dict(l.strip().split("=", 1) for l in open(tokfile) if "=" in l) if os.path.exists(tokfile) else {}
server = env["THREAD_SERVER"]


def call(path, body=None, tok=None):
    r = urllib.request.Request(server + path, data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + tok} if tok else {})})
    try:
        with urllib.request.urlopen(r, timeout=20) as x:
            return x.status, json.loads(x.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def totp(sec):
    k = base64.b32decode(sec + "=" * (-len(sec) % 8))
    c = int(time.time() // 30)
    h = hmac.new(k, struct.pack(">Q", c), hashlib.sha1).digest()
    o = h[-1] & 15
    return c, "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000)


last = [None]


def login(user, pw, sec, name, platform="test"):
    c, code = totp(sec)
    if last[0] is not None and c <= last[0]:
        time.sleep(30 - time.time() % 30 + 1)
        c, code = totp(sec)
    st, j = call("/auth/login", {"username": user, "password": pw, "code": code, "device_name": name, "platform": platform})
    if st != 200:
        sys.exit(f"Anmeldung fehlgeschlagen: {st} {j}")
    last[0] = c
    return j["token"]


demo = len(sys.argv) > 1 and sys.argv[1] == "demo"
want = [("THREAD_DEMO_TOKEN", "THREAD_DEMO", "Alex's iPhone", "ios"), ("THREAD_DEMO_TOKEN2", "THREAD_DEMO", "Alex's MacBook", "mac")] if demo else \
    [("THREAD_TOKEN", "THREAD", "Test-Gerät A", "test"), ("THREAD_TOKEN2", "THREAD", "Test-Gerät B", "test")]
for key, prefix, name, platform in want:
    if key in toks and call("/api/me", tok=toks[key])[0] == 200:
        continue
    toks[key] = login(env[prefix + "_USER"], env[prefix + "_PASSWORD"], env[prefix + "_TOTP_SECRET"], name, platform)
toks["THREAD_SERVER"] = server
toks["THREAD_PUBLIC_SERVER"] = env.get("THREAD_PUBLIC_SERVER", "")
fd = os.open(tokfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, "".join(f"{k}={v}\n" for k, v in toks.items()).encode())
os.close(fd)
print("Token bereit:", ", ".join(k for k in toks if "TOKEN" in k))
