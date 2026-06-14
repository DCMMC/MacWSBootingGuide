---
name: agx-dopamine-krw-uat-object-chain-found
description: "Dopamine-KRW UAT-aliasing campaign — solved the navigation problem. The per-task UAT context object IS reachable from user-space via DUC→AGXShared→Gart→LocalMux→LocalMux+0x10. Still stuck on actual TTB walk: the +0x10 object is a 0x30-byte \"context handle\" not the AGXUAT, and its +0x28 leads to non-PT data. Need to dereference SharedMux (Gart+0x28) instead."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

**Status 2026-06-14 (campaign milestone log):**

After many false starts (see [[agx-uat-pointer-not-in-accelerator]]), the per-task UAT context object IS reachable from user-space. The earlier walls were caused by:

1. **C++ ABI vptr offset:** in-memory vptr equals `__ZTV<class>_symbol + 0x10` (skips offset-to-top + RTTI prefix). My earlier exact-match scans were off by 0x10 → zero hits everywhere.
2. **Wrong IOReg planes:** `IOServiceMatching("AGXGart…")` returns NULL because Gart/Mux/SharedUC are heap-only objects, NOT registered IOServices. Children of AGXAccelerator on the `IOService` plane ARE iterable though — 22 AGXDeviceUserClient instances live there.
3. **Wrong UAT subclass assumption:** `__ZN9AGXUATMux9sUseIOUATE = 1` on iOS 16.3 → Mux uses the IOKit-base `IOUnifiedAddressTranslator`, NOT the AGX-derived subclass. The kernel kext shows AGXUAT vtable but the LIVE objects use a different (IOKit-base) vtable.

**Confirmed object navigation chain (from agxprobe equivalent process):**

```
IOServiceMatching("AGXAcceleratorG13G_B0")
→ AGX kp = 0xfffffe82f7cd4000 (varies per boot)
→ IORegistryEntryGetChildIterator(agx, "IOService", &it)
  → first DUC: 0xfffffe1300653260 (vt unslid 0xfffffe0007a03308 = AGXDeviceUserClient)
    → DUC+0x120 = AGXShared* @ 0xfffffe14cc7558e0 (vt unslid 0xfffffe0007a0e3e8)
      → AGXShared+0x58 = AGXGartG13* @ 0xfffffe1300525c00 (vt unslid 0xfffffe0007a085f8)
        → Gart+0x28  = SharedMux*    @ 0xfffffe1219bca9f8 (vt 0xc22000000 — looks garbage, but logic confirms via AGXSecureGart::init+0x1f8/+0x274 disasm)
        → Gart+0x288 = LocalMux*    @ 0xfffffe13e7548540 (vt unslid 0xfffffe0007a0f058 = AGXUATMux confirmed)
          → LocalMux+0x10 = per-task context obj @ 0xfffffe14cba32b80 (vt unslid 0xfffffe00079de698 — UNKNOWN class, only 0x30 bytes; NOT AGXUAT)
```

The per-task context at LocalMux+0x10 is small (0x30 bytes) — definitely not the AGXUAT 2*0x90=0x120-byte structure. Layout observed:
- +0x00: vtable
- +0x08: refcount (1)
- +0x10: ptr → SharedMux back-ref (0xfffffe1219bca9f8)
- +0x18: ptr → AGXAccelerator (back-ref)
- +0x20: ptr → task_t (0xfffffdf02b6ac1b8)
- +0x28: ptr → some misc object containing ASCII string data ("group4018", "Unigrams", "-en.idx") — NOT a page table

**Conclusion:** This object is the "registerTaskForService" return value (a context handle), not the AGXUAT instance itself. The actual page tables live in the SharedMux at 0xfffffe1219bca9f8 (Gart+0x28). The SharedMux's vtable read as 0xc22000000 which looks corrupted (kalloc.large vtable? wrong PAC strip?) — needs proper interpretation.

**Confirmed kext-level facts:**
- `AGXSecureGart::init(this=Gart, AGX*, task*, ulong)` at unslid 0xfffffe000873bfcc
- At +0x1f8: `ldr x22, [x19, #0x28]` ; x22 = SharedMux
- At +0x274: `bl IOUnifiedAddressTranslator::registerTaskForService(x0=SharedMux, x1=task)` — registers this task's GPU context
- At +0x278: stores return at LocalMux+0x10 (LocalMux was just alloc'd via AGXUATMux gMetaClass)
- `__ZN27AGXUnifiedAddressTranslator15allocPageTablesEyy @ unslid 0xfffffe000874b9d4`:
  - Receives VA range (x1=base, x2=size)
  - Computes ctx index: `ubfx x9, x1, #39, #1` ; ctx = (VA >> 39) & 1 — so only 2 contexts (TTBR0/TTBR1 split at bit 39)
  - Slot pointer: `madd x9, x9, #0x90, x0` ; slot = this + ctx*0x90
  - **slot+0x30 is a pointer to the L1 page-table** (`ldr x8, [slot+0x30]; ldr x8, [x8]` = read pointer, then deref to get L1 base — so slot+0x30 stores POINTER TO POINTER to L1 PT, suggesting the L1 PT pointer can be reallocated/updated)
- `__ZN27AGXUnifiedAddressTranslator31getPageTablePhysicalBaseAddressEj` @ unslid 0xfffffe000874de48: `ctx*0x90 + 0x28` — returns the value at +0x28 of the slot (a kernel VA, likely the L1 PT's IOMemoryDescriptor-backed VA; caller does kvtophys)
- AGXUAT instance layout: 2 contexts of 0x90 bytes each (indexed by bit 39 of GPU VA)
- AGXUATMux singleton globals at unslid 0xfffffe000aadbeb8..0xfffffe000aadc010

**Concrete next-step experiment** (M6 unblock):
1. Read SharedMux at 0xfffffe1219bca9f8 with proper PAC strip + dump first 0x200 bytes — find its actual vtable + which kalloc zone it's in
2. The SharedMux is the actual AGXUAT singleton (or wraps it). Its instance has the 2-context-of-0x90 layout. Read SharedMux+0x30 (or similar offset of one of the 2 contexts) to find the L1 PT pointer-to-pointer
3. Walk L1 PT via physread, find entry for our task's context
4. Insert PTE aliasing L1[1] (which covers 0x1000000000-0x1fffffffff including the macOS-Metal-expected Pipelines range at 0x1100000000) to point to the same L2 table as L1[0]
