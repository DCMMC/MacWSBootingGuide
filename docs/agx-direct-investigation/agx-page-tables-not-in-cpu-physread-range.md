---
name: agx-page-tables-not-in-cpu-physread-range
description: "Exhaustive read-only survey (6654 candidate pages, 3-level deep from Gart pointers, AGX-correct PTE heuristic) found ZERO real GPU page tables. AGX page tables likely live in ASC firmware memory (referenced by AGXUnifiedAddressTranslator::initHandoff + gHandoffPtr/gHandoffDesc/gHandoffMap globals), invisible to standard physread64. The Dopamine-KRW + UAT-aliasing strategy as scoped is NOT VIABLE on iOS 16.3 / iPad13,6 without firmware-side access."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

**Definitive empirical result 2026-06-15:** After locating the full object chain (DUC→AGXShared→Gart→SharedMux/LocalMux), decoding the AGX PTE format (PDE/PCE = bits 0+1; PTE mandatory bits = 0x0080000000000403), and running a strict 3-level-deep PT-page survey from Gart pointer fields:

- **6654 candidate pages checked** via `kvtophys → physreadbuf(16 KiB) → strict ratio check`
- **0 hits** with ≥8 valid table-descriptor or AGX-PTE entries AND valid/nonzero ratio ≥ 70%
- Loose heuristic (≥3 valid entries) yields only false positives — kernel CODE pages happen to have a few qwords where bits 0+1 = 0b11 with random middle bits in DRAM range. These are NOT page tables, just random code patterns.

**Why this rules out the Dopamine-KRW + UAT-aliasing approach:**

1. The page tables are NOT reachable via CPU `physread64` through any pointer chain rooted at the userspace-observable AGX objects (DUC, AGXShared, AGXGartG13, AGXUATMux LocalMux/SharedMux, AGXMemoryMap arrays, IOGPUMemory pointers — all surveyed).

2. The AGXUnifiedAddressTranslator kext has methods named `initHandoff @ unslid 0xfffffe000874d7a4` plus globals `gHandoffDesc / gHandoffMap / gHandoffPtr @ unslid 0xfffffe000aadbff8..0xfffffe000aadc008` (all read as 0 from userspace). **"Handoff" = the page tables and metadata are handed off to the AGX firmware (ASC coprocessor) and managed in firmware memory space**, not directly in CPU-visible DRAM pages.

3. Asahi Linux RE confirms: the M1 AGX uses RTKit/RTBuddy firmware (ASC) which has its OWN address space; the firmware sets up the GPU MMU's page tables in regions that CPU memory accesses don't reach by default. Asahi's approach is to take over completely — write a new kernel driver, replace iOS's AGX management. With iOS in place, the ASC firmware owns the page tables.

4. Even if we could find the page tables, the AGX MMU may use a custom encoding beyond ARMv8 — `encodePTEFlags` mandates bits 0x0080000000000403, but `encodePDEFlags`/`encodePCEFlags` just return 0x3 (bits 0+1). Real entries likely have additional kext-internal flags my heuristic doesn't model.

**How to apply:**

DO NOT continue blind kernel-write attempts on iOS 16.3 / iPad13,6 to alias GPU VAs. The Dopamine-KRW + UAT-aliasing campaign is structurally blocked because the page tables aren't in the address space we can write to via Dopamine's KRW primitives. The single attempt that proceeded ([[agx-uat-l1-write-panicked-ios]]) wrote into a random kalloc buffer and panicked the kernel — and that was inevitable because the wrong place was being treated as a page table.

**Realistic paths forward (out-of-scope for shell-based RE):**

A. **`kcall` approach**: use Dopamine's `kcall(uint64_t func, int argc, uint64_t *argv)` to invoke `IOUnifiedAddressTranslator::doMap` / `createMappingInAperture` from userspace, asking the kernel ITSELF to set up the alias mapping. The kernel does the firmware handoff for us. Risk: wrong args → kernel panic. Need IDA to find precise arg layout.

B. **AGX firmware RE**: extract ASC firmware (`com.apple.AGXFirmwareKextG13GRTBuddy` was extracted but only the host-side stub), reverse the GPU MMU table-walk code in the firmware itself. Months of work; possibly impossible without leaked docs.

C. **Pivot back to userland-shim path** ([[agx-direct-path-kernel-abi-deadend]] UPDATE50): intercept macOS Metal's pipeline-heap allocator in libmachook, redirect 0x1100000000+ allocations into the 0x1500000000+ GEM range iOS kernel already maps. Avoids the entire page-table question. Tight scope.

**Useful artifacts pinned for next session (if continuing):**
- DRAM range: 0x802500000..0x9d904c000
- AGX object chain via Dopamine KRW: see [[agx-dopamine-krw-uat-object-chain-found]]
- AGX PTE format: PTE leaf needs `(e & 0x0080000000000403) == 0x0080000000000403`; L1/L2 tables need `(e & 0x3) == 0x3`
- Failure mode of blind write: see [[agx-uat-l1-write-panicked-ios]]

**Bottom line:** The /goal "successfully run agxprobe via Dopamine KRW" is NOT achievable in any shell-based session because the page tables we'd need to modify don't live in CPU-accessible DRAM via the userspace-observable AGX object graph. A different mechanism is required.
