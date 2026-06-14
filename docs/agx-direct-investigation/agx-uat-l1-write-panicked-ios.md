---
name: agx-uat-l1-write-panicked-ios
description: "Writing L1[1]=L1[0] (value 0x800000f122000000) into kvtophys(uat+0x28)+8 = 0x898cf12c0+8 across all 22 AGXDeviceUserClient TTBs panicked iOS 16.3 kernel and force-rebooted the device. The \"TTB\" the disasm of `AGXUAT::getPageTablePhysicalBaseAddress` points to is NOT the actual page table for the AGX MMU — it's an unrelated kernel buffer (the previous dump found ASCII strings like \"group4018\"/\"Unigrams\" inside)."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

**Confirmed 2026-06-15:** Writing L1[1] = 0x800000f122000000 (the read-back "L1[0]" value) into PA `kvtophys(uat+0x28)+8` for all 22 AGXDeviceUserClient TTBs caused iOS 16.3 kernel panic and force-reboot.

**Root cause of the mistake:** The disasm of `AGXUnifiedAddressTranslator::getPageTablePhysicalBaseAddress @ unslid 0xfffffe000874de48` looked like it returned the TTB PA as `*(this + ctx*0x90 + 0x28)`. But:

1. The "per-task UAT" object I located at `LocalMux+0x10` is only **0x30 bytes**, NOT the 2*0x90 = 0x120 byte layout an actual AGXUAT instance should have.
2. Its vtable (unslid 0xfffffe00079de698) does NOT match `__ZTV27AGXUnifiedAddressTranslator` (unslid 0xfffffe0007a0f7b8). It's a DIFFERENT class — likely the small "context handle" object that `IOUnifiedAddressTranslator::registerTaskForService` returns.
3. The PA 0x898cf12c0 (kvtophys of uat+0x28) is in DRAM range (DRAM = 0x802500000..0x9d904c000) but CONTAINS PLAIN DATA (ASCII strings) — not page-table entries. The earlier dump showed: +0x20 = `0x38313470756f7267` ("g r o u p 4 1 0 8"), +0x40 = `0x736d617267696e55` ("U n i g r a m s"). These are property/text data, NOT PTEs.
4. The value `0x800000f122000000` (which I thought was an AGX-custom PTE) does NOT have a valid ARMv8 PTE bit 0/1 set, and its "PA field" 0xf122000000 is 60 GiB — far outside DRAM. It's just a quadword in a heap buffer.

**Why the L1[0]=`0x800000f122000000` matched across 3 different process TTBs was a coincidence/artifact:** All processes happen to point to similar-position kernel kalloc buffers; the buffer at offset 0 happens to commonly hold this specific value (likely a constant header in some kalloc-typed-allocation pattern).

**How to apply:**
- Do NOT trust `getPageTablePhysicalBaseAddress` disasm naively → the small object at LocalMux+0x10 is NOT an AGXUAT instance.
- Need to find the ACTUAL AGXUAT instance. Per kext analysis: `__ZN9AGXUATMux9sUseIOUATE=1` → live UAT is `IOUnifiedAddressTranslator` (IOKit base class), not the AGX-derived subclass; their layouts differ.
- The AGXSecureGart::init disasm shows registerTaskForService is called with x0=SharedMux (Gart+0x28, value 0xfffffe1219bca9f8), and its return value is stored at LocalMux+0x10. The SharedMux is more likely to hold the actual L1 PT pointer, but THAT object's "vtable" reads as 0xc22000000 (PAC strip didn't yield a kernel ptr) — its first 8 bytes aren't a vtable at all. Likely it's not even an OSObject — maybe a raw struct allocated via kalloc_type.
- DO NOT issue physwrite64 to candidate TTB PAs without first VERIFYING the target memory looks like a page table (e.g., by sanity-checking that all PTE values have valid bit set, PA fields point within DRAM, etc.). My panic would have been avoided by this safety check.
- For future agxprobe-via-Dopamine-KRW work: locate the ACTUAL page table by finding `IOUnifiedAddressTranslator::createMappingInAperture` and tracing what physical memory it walks/modifies, OR `AGXUnifiedAddressTranslator::allocPageTables`'s output — which kalloc_type_view it uses and what zone hosts page-table allocations.
- For RISKY page-table writes: ALWAYS test first on a single non-critical DUC (e.g. spawn a sacrificial process and patch only IT), never the whole 22-DUC set. Bulk-patch caused total system death.

Side-effects of the reboot: lost any unflushed work; SSH session resumed normally after device came back up. Verified panic via `uptime` showing 1 min uptime.
