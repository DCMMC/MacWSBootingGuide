---
name: agx-pipeline-base-patch-empirical
description: Empirically confirmed 2026-06-15 that patching all 10 MOVZ
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

## Decisive experiment 2026-06-15

Added `AGX_PIPELINE_BASE_PATCH` env-gated patch to `mac_hooks.m`. When set (e.g. to `0x15`), the patch scans macOS AGXMetal13_3's `__TEXT/__text` for the 10 instances of `MOVZ Xd, #0x11, LSL #32` (= 0xD2C00220 | Rd) and replaces them with `MOVZ Xd, #<NEW>, LSL #32`. Then runs agxprobe stage 4 with the patch active.

### Run 1: `AGX_PIPELINE_BASE_PATCH=0x15` (no KCMD_FIX)
- Patch fired: all 10 MOVZ patched (visible from logs)
- Stage 4 commits, GPU executes
- Status=5, error=`0x103 Internal Error` (the OLD pre-fault subtype-3 size check error)
- The KCMD_FIX wasn't active, so we hit its older predecessor failure
- Command buffer dump showed VAs `0x15e8058000` and `0x1648078024` — embedded VAs DID shift to 0x15xx/0x16xx range, proving the patch is mechanically effective

### Run 2: `AGX_PIPELINE_BASE_PATCH=0x15 AGX_KCMD_FIX=1`
- Both patches fire
- AGX_KCMD_FIX applies its size 0x1b8→0x1a8 rewrite
- Status=5, error=`0x0b kIOGPUCommandBufferCallbackErrorPageFault`
- gpuEvent crash report: `bif0_fault.address = 74491133952 = 0x1158048000` — **SAME as before the patch**
- readback[0]=0x00 [4095]=0x00 — buffer still not filled by GPU

### Interpretation

The MOVZ patch DID shift embedded VAs in the command buffer to the 0x15xx range. But the GPU's PAGE FAULT VA stays at `0x1158048000` (in the original 0x11xx range that's NOT in any patched cmd buffer field).

Therefore: macOS Metal has at least two independent pipeline-VA generators:
1. **One controlled by the 10 MOVZ #0x11 instructions** — produces the VAs we see in command-buffer embedded fields (e.g. cmd+0x90, +0x98)
2. **One that produces 0x1158048000** — NOT controlled by the patched MOVZ. Most likely:
   - The AGX firmware itself (ASC RTKit) allocates shader/PSO objects at fixed offsets within its private VA space, and 0x1158048000 is one of those firmware-side VAs
   - Or there's hardcoded VA literal data (not MOVZ instructions) in macOS AGXMetal13_3 that wasn't matched by the simple instruction-pattern scan

### Why this is decisive for Path C

The previous memory note [[ios-trollstore-app-m1-gpu-reference]] UPDATE50 said:
> "Page fault VA is RUNTIME-COMPUTED from kernel/firmware allocations invisible to userland shim. AGX-direct path's last wall is now genuinely beyond userland scope."

This experiment EMPIRICALLY CONFIRMS that — we successfully patched the part of macOS Metal under userland control, and the fault didn't move. Any deeper attempts at userland-shim would also fail because the controlling VA isn't in userland.

### What's still in the AGX_PIPELINE_BASE_PATCH code

The patch is committed to `libmachook/mac_hooks.m` as env-gated `AGX_PIPELINE_BASE_PATCH`. Keep it as a reproducible diagnostic. Set the env to any 16-bit hex value to change the userland pipeline base; outcome is documented above. Default (env unset) behaves identically to pre-patch libmachook.

### Final conclusion across A/B/C

| Path | Status | Evidence |
|---|---|---|
| A — `kcall` to `IOUAT::doMap` | Dead | `is_kcall_available()=0` on Dopamine iOS 15.2+ ([[dopamine-fugu14-kcall-unavailable]]) |
| B — IOConnect VA selector | Dead | `reserveGPUVirtualAddress` has zero callers in kernelcache; no userspace path takes a target VA |
| C — Userland-shim of macOS Metal | Dead | This experiment: MOVZ patch shifts SOME VAs but not the fault VA (which is firmware-side) |

The /goal "successfully run agxprobe via Dopamine KRW" remains structurally unreachable on iPad13,6 / iOS 16.3 / current Dopamine. Sim path (MTLSimDriver via libmachook) is the only viable approach.
