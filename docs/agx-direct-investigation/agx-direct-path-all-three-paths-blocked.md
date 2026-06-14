---
name: agx-direct-path-all-three-paths-blocked
description: "Final 2026-06-15 status for AGX-direct path on iPad13,6 / iOS 16.3 / Dopamine. All three viable approaches (A kcall, B IOConnect selector, C userland-shim) are independently blocked. C had already been extensively explored by prior work in this very codebase (AGX_STRIP_HEAP_OPT etc.) — fault VA unchanged because macOS AGXMetal and iOS AGX firmware diverge on GPU VA allocation in a way userland can't bridge. Recommend: pivot to sim path or wait for an iOS 15.2+ jailbreak that exposes kcall."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

## Final blocking analysis 2026-06-15

After Binary Ninja-level decompile of the kernelcache, ran through the three theoretically viable paths to make agxprobe stage 4 fill its buffer with 0xAB via the AGX-direct (not sim) path on iPad13,6 / iOS 16.3 / current Dopamine install:

### Path A — `kcall` to `IOUnifiedAddressTranslator::doMap`
- BN-decompile confirmed: `AGXSecureGart::mapWithAddress(gart, IOMemoryDescriptor*, virt, size, flag)` @ unslid `0xfffffe000873bee4` wraps `IOUAT::doMap` which calls `_pmap_iommu_map` — kernel does the ASC firmware handoff. Perfect for `kcall`.
- BLOCKED: this Dopamine install has `is_kcall_available() = 0` and `jbclient_get_fugu14_kcall() = -1`. Dopamine intentionally skips PAC bypass on iOS 15.2+ (`DOEnvironmentManager.m:602 isPACBypassRequired` returns NO for iOS 15.2+). See [[dopamine-fugu14-kcall-unavailable]].

### Path B — IOConnect selector that takes a user-controlled GPU VA
- `IOGPUMemoryMap::reserveGPUVirtualAddress(virt, len)` exists @ unslid `0xfffffe0009f13554` and would do exactly what we need — but **zero BL callers in the entire iOS kernelcache** (brute search of all __TEXT_EXEC). Compiled-in dead code.
- `AGXDeviceUserClient::kAGXDeviceMethods` table @ unslid `0xfffffe0007a039b8` has 11 entries (selectors 0x100..0x10a): all are INFO/QUERY (`getDeviceInfo`/`getDriverInfo`/etc.); none take a GPU VA.
- Inherited `IOGPUDeviceUserClient` selectors include `s_new_resource` / `s_create_shmem` / `s_create_resource_iosurface`: traced `new_resource → IOGPUDevice::new_resource → IOGPUResource::newResourceWith*` — `IOGPUNewResourceArgs` has no GPU-VA field.
- Strings `pinnedGPUAddress` / `requestedVA` / `gpuVirtualAddress` ALL ABSENT from the iOS 16.3 kernelcache. iOS deliberately does not expose user-VA control.

### Path C — Userland-shim of macOS Metal in libmachook
- **Already tried in this codebase.** `mac_hooks.m` has:
  - `AGX_STRIP_HEAP_OPT`: strip clientID 0x10000 args[+0x58] high u32 = 0xc (the heap-shift bit)
  - `FIX_LOW_HEAP`: rewrite OUT[0] returned VA via post-call patch to make macOS Metal's offset computation match its shader-baked VAs
  - Subresource VA aliasing (mapped iOS GIDs → macOS sub-VAs via parent-id rewriting)
  - All hooks that touch the AGX-Metal allocation path
- Per existing memory [[ios-trollstore-app-m1-gpu-reference]] UPDATE50: "AGX_STRIP_HEAP_OPT had no effect — fault VA unchanged" and "Page fault VA is RUNTIME-COMPUTED from kernel/firmware allocations invisible to userland shim. AGX-direct path's last wall is now genuinely beyond userland scope (kernel patching or AGX firmware RE territory)."

The reason: macOS AGXMetal and iOS AGX firmware track GPU VAs in INDEPENDENT allocators that diverge on the Pipelines region (0x1100000000+). Userland intercepts what flows through IOConnect, but the firmware-side allocator (ASC RTKit) maintains its own state for shader/pipeline objects, and the two views never converge without a kernel-side fix.

### Theoretical paths still open (but very expensive)

- D. Modified Dopamine: fork libjailbreak, write iOS 16+ PAC bypass, build new Dopamine. **Major engineering project.**
- E. Different jailbreak: switch to a jailbreak that does have kcall on iOS 15.2+ (none currently public for arm64e iOS 16).
- F. Wait for Dopamine update enabling kcall.
- G. AGX/ASC firmware RE: extract the firmware blob, reverse the GPU MMU allocator. Months.

### Recommended pivots

1. **Stick with sim path (MTLSimDriver)** — already works in this codebase (`Metal_hooks.x` MTLFakeDevice path). GUI apps function via the sim bridge even if AGX-direct doesn't. Not as fast as native, but functional.
2. **If a future Dopamine ships kcall**: go straight to the kcall plan in [[agx-dopamine-kcall-plan]]. All the decompile groundwork (object chain, mapWithAddress signature, IOUAT layout) is solid and reusable.

### Bottom line

The /goal "successfully run agxprobe via Dopamine KRW" is unreachable on the current device + jailbreak combination. The work is not wasted — Memory entries [[agx-dopamine-krw-uat-object-chain-found]], [[agx-dopamine-kcall-plan]], [[agx-page-tables-not-in-cpu-physread-range]], [[dopamine-fugu14-kcall-unavailable]] document everything for the next attempt with different prerequisites.
