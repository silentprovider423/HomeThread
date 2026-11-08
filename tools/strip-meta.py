#!/usr/bin/env python3
"""Entfernt Metadaten aus PNGs (EXIF, Text, Zeit) – nur Bilddaten und Farbprofil bleiben:
  python3 tools/strip-meta.py a.png b.png …"""
import sys

KEEP = {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"sRGB", b"iCCP", b"gAMA", b"cHRM", b"sBIT", b"pHYs"}
for path in sys.argv[1:]:
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", path
    out, i = [d[:8]], 8
    while i < len(d):
        n = int.from_bytes(d[i:i + 4], "big")
        if d[i + 4:i + 8] in KEEP:
            out.append(d[i:i + 12 + n])
        i += 12 + n
    open(path, "wb").write(b"".join(out))
print("Metadaten entfernt")
