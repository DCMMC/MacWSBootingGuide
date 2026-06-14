---
name: dopamine-kwrite-text-blocked-by-ktrr
description: "Empirically tested 2026-06-15 — Dopamine on iOS 16.3.1 arm64e (iPad13,6) CANNOT write to kernel __TEXT pages. kread/physread work; kwrite32 to a __TEXT VA HANGS the calling thread indefinitely (no panic, no return). PPL bypass (dmaFail) is loaded but does not grant writes to KTRR-locked __TEXT regions. Approach Y (patch AGXSecureGart::mapWithAddress) is structurally blocked."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

## Test 2026-06-15

Wrote a minimal test binary that:
1. dlopens libjailbreak, jbclient_initialize_primitives
2. Targets `AGXSecureGart::deallocate @ unslid 0xfffffe000873ba44`, slid = `va = unslid + slide`
3. Calls `kread32(va)` → returns `0xd503237f` = `pacibsp` (correct first instruction) ✓
4. Calls `kvtophys(va)` → returns PA in DRAM range 0x802500000..0x9d904c000 ✓
5. Calls `physread32(pa)` → returns same `0xd503237f`, matches kread ✓
6. Calls `kwrite32(va, origK)` — **identity write (no value change)** → **HANGS forever**, no return, no kernel panic

Killed the hung test process with `killall -9`; device stayed up (`uptime` showed 3h continuous uptime, no reboot).

## Interpretation

iOS 16+ kernel `__TEXT` is protected by **KTRR (Kernel Text Read-Only Region)** — a hardware memory controller lock that survives PPL bypass. Dopamine's dmaFail bypasses PPL (logical write protection) but doesn't / can't bypass KTRR (physical lock at the memory controller level).

Write attempt path likely flow:
- physwrite/kwrite issues a write request through Dopamine's PPL-bypass primitive
- KTRR memory controller silently rejects writes to the locked range
- The bypass primitive waits for write completion that never happens
- Caller thread hangs

No panic because no invalid memory access occurs — the write just goes nowhere.

## Implications

**Approach Y (patch AGXSecureGart::mapWithAddress / any kernel function in __TEXT) is blocked.** The kwrite primitive available via Dopamine on iOS 16.3.1 arm64e is restricted to kernel DATA pages (kalloc, BSS, DATA_CONST after some conditions). KTRR-locked __TEXT pages cannot be modified.

To overcome this would need:
- A KTRR bypass exploit (none currently public for iOS 16+)
- OR run the patch from a context that has KTRR-disabled access (only iBoot / SecureROM, requires more privileged execution context)

## What writes DO work via Dopamine on this device

- kalloc/kallocPT pages (RW heap)
- IOSurface-backed pages
- Userspace pages (via task_for_pid)
- Probably kernel BSS / __DATA_CONST after the __DATA_CONST unlock that Dopamine applies for hooking

## Final summary across approaches

| Approach | Status |
|---|---|
| A — kcall via fugu14 | ❌ no PAC bypass on iOS 15.2+ Dopamine |
| B — userspace IOConnect selector with VA | ❌ iOS kernel has no such selector |
| C — userland-shim of macOS Metal | ❌ MOVZ patch shifts some VAs, fault VA from another source ([[agx-pipeline-base-patch-empirical]]) |
| Y — kernel __TEXT patch | ❌ KTRR blocks __TEXT writes (this note) |
| Z — kernel DATA-struct manipulation | Not yet tested; the only remaining theoretical path |

Approach Z would require finding kernel objects whose fields, when modified, trick existing code paths into doing what we want. High complexity, fragile (any consistency check kills us). Possible but unlikely to be worth the engineering cost.

**The AGX-direct path is genuinely exhausted on this device + jailbreak.**
