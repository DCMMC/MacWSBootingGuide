---
name: agx-dopamine-kcall-plan
description: "BN-confirmed kcall plan to skip page-table writes. AGXSecureGart::mapWithAddress(this, IOMemoryDescriptor*, GPU_VA, size, flags) wraps IOUnifiedAddressTranslator::doMap which calls _pmap_iommu_map → kernel handles firmware-side page-table updates. No direct PT writes needed. Build a kcall-based patcher."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

**Binary Ninja decomp confirmed the kcall path 2026-06-15.**

## Key function: `AGXSecureGart::mapWithAddress` @ unslid `0xfffffe000873bee4`

Decompile:
```c
int8_t AGXSecureGart::mapWithAddress(this, IOMemoryDescriptor* desc, uint64_t virt, uint64_t size, uint8_t flag):
    AGXAccelerator* x24 = *(this + 0x10)
    IORWLockRead(x24+0x1d78); IORWLockRead(x24+0x1d80)
    AGXUATMux* localMux = *(this + 0x288)
    int32_t r
    if (AGXUATMux::sUseIOUAT == 0):
        r = AGXUnifiedAddressTranslator::doMap(*(localMux+0x18), desc, virt, size)
    else:
        r = IOUnifiedAddressTranslator::doMap(*(localMux+0x10), desc, virt, size)  // <-- iOS 16.3 path
    IORWLockUnlock(x24+0x1d80); IORWLockUnlock(x24+0x1d78)
    return (r == 0)  // 1 = success
```

## IOUnifiedAddressTranslator instance size: 0x578 bytes

`IOUAT::registerTaskForService(task, IOService)` decompile (@ unslid 0xfffffe0008631980) confirms:
- `_OSObject_typed_operator_new(&data_fffffe00079f72d0, 0x578)` — allocates 0x578 bytes
- `*result = &data_fffffe00079de698` — sets vtable
- Calls virtual init at `vtable+0xa8` with `(result, task, IOService)`. If init returns nonzero, returns result; else NULL.

The object at LocalMux+0x10 we observed earlier is this 0x578-byte instance — my prior 0x30-byte assumption was wrong, just dumped too shallow.

## `IOUAT::doMap(this, desc, virt, size, options)` @ unslid `0xfffffe0008631c44`

Critical line: `_pmap_iommu_map(*(this + 0x20), x0_3, x26_1, x22)` — kernel pmap call.
- Pre-conditions: `desc != NULL`, `virt & 0x3FFF == 0`, `size & 0x3FFF == 0`
- Walks the descriptor's pages via virtual `(desc->vtable[0x98/8])(desc, offset, &len, 0)`
- Allocates a scatter-list via `sub_fffffe0007f7695c(&data_fffffe00079e83d1, ...)`
- Calls `_pmap_iommu_map` to add the mapping — this is where the kernel hands off to AGX firmware

So calling `IOUAT::doMap(uat, descriptor, 0x1100000000, mapping_size, 0)` does the firmware page-table update for us. No direct PT writes.

## Wrapped form (preferred for kcall — handles locking + dispatch):

`AGXSecureGart::mapWithAddress(gart, descriptor, virt, size, flag)` is the public entry. It:
1. Takes the AGXAccelerator's read locks
2. Dispatches to IOUAT or AGXUAT doMap based on sUseIOUAT
3. Returns 1 on success

5 args, all fit in x0-x4. Perfect for libjailbreak kcall.

## libjailbreak kcall API (confirmed available):
```c
int kcall(uint64_t *result, uint64_t func, int argc, const uint64_t *argv);
bool is_kcall_available(void);  // _is_kcall_available exported
```

The fugu14_kcall mechanism is used on iOS 16. Symbol `_kcall @ libjailbreak.dylib`.

## CONCRETE EXPERIMENT PLAN (safer methodology):

```c
// iOS-side patcher (single sacrificial process)
1. jbclient_initialize_primitives()
2. assert(is_kcall_available())
3. Find target process's DUC via IOReg matching by task_t (we know own task_self())
   - DUC+0x120 = AGXShared*
   - AGXShared+0x58 = AGXGartG13*  (this is THE Gart for kcall)
4. Find a small backing IOMemoryDescriptor to map:
   Option A: read Gart's existing AGXMemoryMap array at Gart+0x1f0..+0x248
            → AGXMemoryMap*[N] (vt unslid 0xfffffe00079a6d90)
            → call IOGPUMemoryMap virtual at vtable+0x110 to get IOMemoryDescriptor*
   Option B: kcall IOBufferMemoryDescriptor::inTaskWithOptions to alloc a fresh one
5. resolved_func = slid_unslid(0xfffffe000873bee4) // AGXSecureGart::mapWithAddress
6. uint64_t argv[5] = { gart_kp, desc_kp, 0x1100000000ULL, size, 0 };
   uint64_t result;
   kcall(&result, resolved_func, 5, argv);
7. result should be 1 (success)
8. Run agxprobe stage 4 — GPU walks PT, finds 0x1100000000 → mapped → no fault
9. agxprobe readback verifies whatever the GPU wrote

## Risk mitigation (vs. prior panicked write):
- Only writes happen INSIDE the kernel via proper kpis (with locking, validation)
- kcall failure returns nonzero — won't panic on bad args (validated via decompile)
- Single sacrificial process — if it panics, only that one dies, not the whole device

## Useful slid addresses (for slide=0x253ec000):
- AGXSecureGart::mapWithAddress = 0xfffffe000873bee4 + 0x253ec000 = 0xfffffe002cb27ee4
- IOUnifiedAddressTranslator::doMap = 0xfffffe0008631c44 + 0x253ec000 = 0xfffffe002ca1dc44
- AGXSecureGart::unmapWithAddress = 0xfffffe000873bc0c + 0x253ec000 = 0xfffffe002cb27c0c (for cleanup)

Slide will be different per boot — read from gSystemInfo[0] at runtime.

## What I didn't get to (next session):
- Find the IOMemoryDescriptor pointer offset within IOGPUMemoryMap (virtual method at vtable+0x110)
- Test kcall with a benign function first (e.g. kalloc/free) to confirm it works on this build
- Build + run the patcher
