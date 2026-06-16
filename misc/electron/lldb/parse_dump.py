#!/usr/bin/env python3
"""Parse output of attach_and_dump.sh to extract:
   - Framework slide
   - x8, x9 (the args saved to error_and_abort_args)
   - Stack-vicinity pointer-as-string interpretations

Usage: parse_dump.py LDB_LOG_FILE
"""
import re, sys, struct

f = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()

# Find EXC_BREAKPOINT address (== brk PC, gives us slide)
m = re.search(r"EXC_BREAKPOINT.*?subcode=0x([0-9a-fA-F]+)", f)
brk_pc = int(m.group(1), 16) if m else None
slide = (brk_pc - 0x53408c8) if brk_pc else None
print(f"brk PC: {brk_pc:#x}" if brk_pc else "brk PC: not found")
print(f"slide:  {slide:#x}" if slide else "slide:  not found")

# Find register dumps (we may have multiple frames)
def parse_regs(text, near_marker):
    """Find a register dump after near_marker; return dict of name->int."""
    idx = text.find(near_marker)
    if idx < 0: return {}
    section = text[idx:idx + 3000]
    regs = {}
    for line in section.splitlines():
        m = re.match(r"\s+([xfwslprc][a-z0-9]*)\s*=\s*0x([0-9a-fA-F]+)", line)
        if m:
            regs[m.group(1)] = int(m.group(2), 16)
    return regs

# 1st reg dump: at the stp BP (before brk)
regs_at_stp = parse_regs(f, "register read x0 x1 x2 x3 x8 x9")
# 2nd reg dump: at the brk
regs_at_brk = parse_regs(f, "register read pc x0 x1 x2 x3")

print("\n=== Registers at STP (before abort) ===")
for r in ("x0","x1","x2","x3","x8","x9","x10","x19","x20","fp","sp","pc"):
    if r in regs_at_stp:
        v = regs_at_stp[r]
        print(f"  {r} = 0x{v:016x}")

# Find the file/line interpretations
def find_string_after(text, marker, maxlines=10):
    idx = text.find(marker)
    if idx < 0: return None
    chunk = text[idx:idx + 2000].splitlines()[:maxlines]
    out = []
    for ln in chunk:
        m = re.search(r"0x[0-9a-fA-F]+:\s*([ -~]+?)\s*$", ln)
        if m: out.append(m.group(1))
    return "\n".join(out).strip()

print("\n=== memory at $x8 (likely file or condition string) ===")
s = find_string_after(f, "memory read --format c --size 1 --count 200 `$x8`", 16)
print(s if s else "(empty or unreadable)")

print("\n=== memory at $x9 (likely msg or line indicator) ===")
s = find_string_after(f, "memory read --format c --size 1 --count 200 `$x9`", 16)
print(s if s else "(empty or unreadable)")

print("\n=== Crash backtrace ===")
m = re.search(r"thread backtrace --count 12(.*?)(?:quit|\(lldb\))", f, re.DOTALL)
if m: print(m.group(1).strip())
