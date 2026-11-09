#!/usr/bin/env python3
"""Fasst einen Time-Profiler-Trace zusammen: Main-Thread-Anteile je Funktion (inklusiv), nur App-Code + große Blöcke."""
import subprocess, sys, collections, xml.etree.ElementTree as ET
trace = sys.argv[1]
xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                      '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], capture_output=True, text=True).stdout
root = ET.fromstring(xml)
ids = {}
for e in root.iter():
    if "id" in e.attrib: ids[e.attrib["id"]] = e
def res(e): return ids.get(e.attrib["ref"], e) if "ref" in e.attrib else e
incl = collections.Counter(); total = 0; main = 0; busy = 0
for row in root.iter("row"):
    th = res(row.find("thread")) if row.find("thread") is not None else None
    tname = th.attrib.get("fmt", "") if th is not None else ""
    total += 1
    if "Main Thread" not in tname and "main-thread" not in tname.lower(): continue
    main += 1
    bt = row.find("backtrace")
    if bt is None: continue
    bt = res(bt)
    frames = [res(f) for f in bt.findall("frame")]
    if frames and any(w in frames[0].attrib.get("name", "") for w in ("mach_msg", "semaphore_wait", "__workq_kernreturn", "kevent")):
        continue
    busy += 1
    seen = set()
    for f in frames:
        name = f.attrib.get("name", "?")
        b = f.find("binary")
        bname = res(b).attrib.get("name", "") if b is not None else ""
        key = (bname, name)
        if key in seen: continue
        seen.add(key)
        incl[key] += 1
print(f"Samples gesamt {total}, Main-Thread {main}, davon arbeitend {busy} (1 ms je Sample)")
generic = ("main", "start", "Run", "UIApplication", "GSEvent", "CFRunLoop", "__CF", "dyld", "entry_point", "$main", "runApp", "KitRenderer",
           "_UIUpdate", "CA::", "UpdateSequence", "UIScene", "_dispatch", "dispatch_", "_runRunLoop", "DoObservers", "ObserverCallout")
shown = 0
for (b, n), c in incl.most_common(400):
    if any(g in n for g in generic): continue
    if True:
        print(f"{c:6d}  {c*100/max(busy,1):5.1f}%  {b[:22]:22s} {n[:130]}")
        shown += 1
    if shown >= int(sys.argv[2] if len(sys.argv) > 2 else 45): break
