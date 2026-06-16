#!/usr/bin/env bash
# patch_brk.sh v6 — neutralize the entire abort-helper region by force-returning
# every detected function start, except for the few that have a real `ret` in
# their body (those are real dispatchers / utility functions).
set -eu
EF="/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
[ "${1:-}" = "--restore" ] && { cp -f "${EF}.orig" "$EF" && echo restored; exit 0; }
[ -f "${EF}.orig" ] || cp -p "$EF" "${EF}.orig"
python3 <<'PY'
import struct
EF = "/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
ORIG = EF + ".orig"
with open(ORIG, "rb") as f: data = bytearray(f.read())

BRK0 = 0xd4200000
HLT0 = 0xd4400000
BRK1 = 0xd4200020
NOP  = 0xd503201f
RET  = 0xd65f03c0

def is_prologue(insn):
    # stp x29,x30,[sp,#-N]! preindex
    if (insn & 0xFFC003FF) == 0xa98003FD: return True
    # stp x20,x19,[sp,#-N]! preindex
    if (insn & 0xFFC003FF) == 0xa9805013: return True
    # stp x22,x21,[sp,#-N]! preindex
    if (insn & 0xFFC003FF) == 0xa9805BF6: return True   # Rt=22 Rt2=21
    if (insn & 0xFFC003FF) == 0xa98057F6: return True   # other variants - approximate
    # sub sp,sp,#imm12 (Rd=Rn=sp)
    if (insn & 0xFF8003FF) == 0xD10003FF: return True
    return False

start, end = 0x5340000, 0x5350000

# Find all function-start candidates: any prologue at aligned offset whose previous
# instruction is `ret`, `brk`, or unreachable (b unconditional).
def is_terminal(insn):
    if insn == RET: return True
    if insn == BRK0: return True
    if (insn & 0xFC000000) == 0x14000000:  # unconditional b
        return True
    if insn == 0xd61f0000 or (insn & 0xFFFFFC1F) == 0xd61f0000: return True   # br Xn
    if insn == 0xd65f0000 or (insn & 0xFFFFFC1F) == 0xd65f0000: return True   # ret Xn (any reg)
    return False

starts = []
for off in range(start, end, 4):
    insn = struct.unpack_from("<I", data, off)[0]
    if is_prologue(insn):  # ANY prologue, regardless of preceding context
        starts.append(off)
print(f"function-start candidates in region: {len(starts)}")

# Within each function, check if it has a clean `ret` (NOT in poison) within 200
# insns. If yes -> real dispatcher, leave alone. If NO -> abort helper, patch.
patched = 0
spared = []
for i, s in enumerate(starts):
    e = starts[i+1] if i+1 < len(starts) else min(end, s + 0x400)
    has_clean_ret = False
    for off in range(s + 4, min(e, s + 0x200), 4):  # skip the prologue at s itself
        insn = struct.unpack_from("<I", data, off)[0]
        if insn == RET:
            # not adjacent to brk poison (which we'd already turn into ret in v4)
            has_clean_ret = True
            break
        if insn == BRK0:
            # If we hit brk before ret -> [[noreturn]]
            break
    if has_clean_ret:
        spared.append(s)
        continue
    # Patch first instruction to ret (LR is still the caller's PC)
    struct.pack_into("<I", data, s, RET)
    patched += 1

print(f"patched {patched} no-ret function starts -> ret")
print(f"spared {len(spared)} functions with clean ret (samples: {[hex(x) for x in spared[:8]]})")

# Defensive: NOP every brk #0 + hlt + brk #1 poison left
nopped = 0
for off in range(start, end, 4):
    insn = struct.unpack_from("<I", data, off)[0]
    if insn == BRK0:
        struct.pack_into("<I", data, off, NOP)
        nopped += 1
        for k in (1, 2):
            no = off + k*4
            ni = struct.unpack_from("<I", data, no)[0]
            if ni in (HLT0, BRK1):
                struct.pack_into("<I", data, no, NOP)
print(f"NOP'd remaining brk #0 poison: {nopped}")

# Keep the CagedHeap skip
CAGED = 0x12330bc
if struct.unpack_from("<I", data, CAGED)[0] == 0x540000a0:
    struct.pack_into("<I", data, CAGED, NOP)
    print("NOP'd CagedHeap b.eq at 0x12330bc")

# Patch broken-epilogue static init at 0xed4e8: its noreturn-design has a
# pseudo-epilogue at 0xee3f0 that DOESN'T restore x30 first, so when an
# upstream patched-to-ret abort helper returns, LR stays at 0xee3e8 and we get
# an infinite loop: 0xee3e8 -> adrp -> add -> ret -> 0xee3e8.
# Make the entire init a no-op return.
INIT_LOOP = 0xed4e8
if struct.unpack_from("<I", data, INIT_LOOP)[0] != RET:
    orig = struct.unpack_from("<I", data, INIT_LOOP)[0]
    struct.pack_into("<I", data, INIT_LOOP, RET)
    print(f"patched broken-epilogue static init at 0x{INIT_LOOP:x}: 0x{orig:08x} -> ret")

with open(EF, "wb") as f: f.write(data)
print("done.")
PY
