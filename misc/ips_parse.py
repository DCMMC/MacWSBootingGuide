#!/usr/bin/env python3
# Parse an iOS CrashReporter .ips (JSON-lines) and print the faulting thread's
# backtrace with each frame resolved to its image path. Usage: ips_parse.py FILE [N]
import json, sys

path = sys.argv[1]
nframes = int(sys.argv[2]) if len(sys.argv) > 2 else 24
lines = open(path).read().splitlines()
# line 0 = one-line metadata header; the rest is the payload JSON (may be
# single-line or pretty-printed across many lines).
try:
    data = json.loads(lines[1])
except Exception:
    data = json.loads("\n".join(lines[1:]))

exc = data.get("exception", {})
print("exception:", exc.get("type"), exc.get("signal"), exc.get("subtype", ""))
print("termination:", data.get("termination", {}))
imgs = data.get("usedImages", [])

def imgname(idx):
    if idx is None or idx < 0 or idx >= len(imgs):
        return "?"
    p = imgs[idx].get("path", imgs[idx].get("name", "?"))
    return p.split("/")[-1]

threads = data.get("threads", [])
crashed = None
for i, t in enumerate(threads):
    if t.get("triggered"):
        crashed = i
        break
if crashed is None:
    crashed = 0
print("crashed thread:", crashed, threads[crashed].get("name", ""))
ts = threads[crashed].get("threadState", {})
if "esr" in ts:
    print("ESR:", ts["esr"].get("description", ts["esr"]))
for f in threads[crashed].get("frames", [])[:nframes]:
    print("  %-28s %s + %d" % (imgname(f.get("imageIndex")),
                               f.get("symbol", "?"), f.get("symbolLocation", 0)))
