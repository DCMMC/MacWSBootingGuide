---
name: dopamine-fugu14-kcall-unavailable
description: "This Dopamine install on iOS 16.3 / iPad13,6 does NOT have fugu14 kcall available. `is_kcall_available()` returns 0 and `jbclient_get_fugu14_kcall()` returns -1. The PAC-bypass primitive needed for arm64e kcall isn't initialized. Without kcall, the entire IOUnifiedAddressTranslator::doMap approach (and any \"call kernel function from userspace\" path) is blocked."
metadata: 
  node_type: memory
  type: project
  originSessionId: febc565b-8549-4f78-8467-b1ac57305225
---

**Confirmed empirically 2026-06-15.**

Built `/tmp/kcall_test` that:
1. dlopens `/var/jb/basebin/libjailbreak.dylib`
2. Calls `jbclient_initialize_primitives()` → succeeds (returns 0; kread/kwrite/physread/physwrite all work)
3. Calls `is_kcall_available()` → **returns 0**
4. Forces `jbclient_get_fugu14_kcall()` → **returns -1** (XPC to jailbreakd failed or PAC bypass not provisioned)
5. Re-checks `is_kcall_available()` → still 0

Per libjailbreak main.c:
```c
if (gPrimitives.kalloc_local) {  // requires kalloc_local primitive
#ifdef __arm64e__
    if (jbinfo(usesPACBypass)) {  // requires usesPACBypass flag
        jbclient_get_fugu14_kcall();
    }
#endif
}
```

One of `gPrimitives.kalloc_local` or `jbinfo(usesPACBypass)` is false on this device. Without one of those, fugu14_kcall is never initialized.

**Implication:**

The [[agx-dopamine-kcall-plan]] (kcall AGXSecureGart::mapWithAddress or IOUAT::doMap) **cannot execute on this device**. The decompile work that confirmed the call signature is still correct — it just can't be invoked from userspace via libjailbreak on this build.

**What still works:**
- kread64, kwrite64
- physread64, physwrite64 (would have to write into the page tables directly, but they're in firmware memory per [[agx-page-tables-not-in-cpu-physread-range]])
- kvtophys
- All IOReg / object-chain navigation

**What does NOT work:**
- kcall to any kernel function
- Invoking IOUnifiedAddressTranslator::doMap from userspace via Dopamine primitives

**Realistic paths forward:**

1. **Upgrade/reinstall Dopamine** to a version that ships fugu14_kcall provisioning enabled on this device. Some Dopamine builds enable it, some don't, depending on PAC-bypass status.
2. **IOConnect method dispatch**: AGXDeviceUserClient exposes external selectors. Some may internally invoke mapWithAddress with user-controlled args. Decompile `AGXDeviceUserClient::externalMethod` and its dispatch table to find a usable selector. This route uses ONLY existing userspace IOKit APIs + maybe field overrides via kwrite64, no kcall.
3. **Pivot to the userland-shim path** (see [[agx-direct-path-kernel-abi-deadend]] REFRAME) — hook macOS Metal's pipeline-heap allocator in libmachook to redirect 0x1100000000+ allocations into the 0x1500000000+ GEM range iOS kernel already maps. Avoids the entire kernel-side mapping question.

**Bottom line:**

The /goal "successfully run agxprobe via Dopamine KRW" is blocked on this device by (1) page tables in ASC firmware memory (so direct PT writes don't work — see [[agx-page-tables-not-in-cpu-physread-range]]) AND (2) no fugu14_kcall (so we can't ask the kernel to add the mapping for us). The decompile groundwork is solid for when one of these blockers is resolved.
