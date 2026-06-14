---
name: agx-uat-pointer-not-in-accelerator
description: "AGX UAT/Mux/Gart kernel pointers are NOT directly stored in AGXAcceleratorG13G_B0 instance (scanned +0x10..+0x8000, 1-level + 2-level vtable match: zero hits). Owned via opaque global/firmware controller chain; can't locate via nm + krwtest alone."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

When pursuing Dopamine-KRW + UAT-aliasing on iOS 16.3 / iPad13,6 T8103 M1, I assumed AGXAcceleratorG13G_B0 holds the AGXUATMux/AGXUnifiedAddressTranslator instance pointer somewhere in its kalloc instance memory. **Falsified by direct experiment.**

**Why:** The kernel UAT (page-table manager) is created at AGXSecureGart::init time per task. The only direct caller of `AGXUnifiedAddressTranslator::registerTaskForService` (sym `__ZN27AGXUnifiedAddressTranslator22registerTaskForServiceEP4taskP9IOServiceb @ unslid 0xfffffe000874ecf8`) is `AGXSecureGart::init(AGXAccelerator*, task*, ulong) +0x354`. The UAT pointer (x22 at the call site) is loaded EARLIER in the prologue via an adrp/add+ldr chain that resolves to something other than a simple field on the AGXAccelerator (which is x19=this passed in to AGXSecureGart::init).

**Evidence:**
- krwtest scanned `AGX kp +0x10..+0x8000` stride 8, dereferenced each kernel pointer, PAC-stripped its first 8 bytes, and compared against slid vtable addrs of AGXUATMux (0xfffffe002cdfb048), AGXUnifiedAddressTranslator (0xfffffe002cdfb7b8), AGXGartG13 (0xfffffe002cdf45e8), AGXLegacyGartG13 (0xfffffe002cdf4970), AGXSharedGartTableBackingG13 (0xfffffe002cdf4810). ZERO hits. 2-level scan (every L1 ptr, +0x10..+0x800 inside it) ZERO hits.
- Only 3 L1 pointers from AGX instance even had a kext-text-region vtable, and they were: IOSurfaceSharedEventReference, an unrelated _PAGE_SHIFT_CONST area, and AppleARMIODevice — NOT Gart/UAT/Mux.
- IOServiceMatching("AGXGartG13"|"AGXSecureGart"|"AGXGart"|"AGXSharedUserClient"|"AGXFirmwareCommandQueue"|"AGXFirmware"|"AGXFirmwareKextG13GRTBuddy") all return NULL — they are NOT registered IOServices in this iOS 16.3 build. They are heap-only objects.

**How to apply:** Do NOT spend further time hunting UAT via static scan of AGXAcceleratorG13G_B0 instance memory or via IOServiceMatching. To find the UAT live-instance pointer, the realistic paths are:
1. **Decompile in IDA/Ghidra** (with proper type info) AGXSecureGart::init + AGXAcceleratorG13G_B0::start to trace the adrp+ldr chain that produces the UAT pointer. Likely points to a global singleton in __DATA at a slid addr.
2. **Brute-force kernel-zone sweep** via libjailbreak.kread64 over kernel_map ranges (range obtainable from gSystemInfo + slid sym addresses) to find first 8 bytes == slid AGXUnifiedAddressTranslator vtable. Slow (millions of reads) but bypasses RE.
3. **Pivot to userland-shim path** instead (see related project memory [[agx-direct-path-kernel-abi-deadend]]): hook macOS Metal's pipeline-heap allocator in libmachook to redirect 0x1100000000+ allocations to the 0x1500000000+ GEM range the iOS kernel DOES map, and patch the GPU command list to use the relocated VA. Avoids the entire "find UAT, walk page tables, alias them" rabbit hole.

**Useful artifacts pinned:**
- AGX instance kp = 0xfffffe82f7cd4000 (varies per boot; obtained via `task_get_ipc_port_kobject(task_self(), IOServiceMatching("AGXAcceleratorG13G_B0"))`)
- Kernel slide for current boot: 0x253ec000
- UAT-related kext globals (unslid):
  - __ZN9AGXUATMux9sUseIOUATE @ 0xfffffe000aadbeb8 (bool — switches between IOUAT vs AGXUAT)
  - __ZN9AGXUATMux18sARMCodeRangeStartE @ 0xfffffe000aadbec0
  - __ZN9AGXUATMux17sARMCodeRangeSizeE @ 0xfffffe000aadbec8
  - __ZN27AGXUnifiedAddressTranslator12gHandoffDescE @ 0xfffffe000aadbff8
  - __ZN27AGXUnifiedAddressTranslator11gHandoffMapE @ 0xfffffe000aadc000
  - __ZN27AGXUnifiedAddressTranslator11gHandoffPtrE @ 0xfffffe000aadc008
  - AGXAcceleratorG13G_B0::setUATConfig(uint) @ 0xfffffe000871b250 (just stores u32 at this+0x16c4 — NOT a UAT pointer setter)
