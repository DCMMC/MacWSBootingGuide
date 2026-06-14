# AGX-direct path investigation (2026-06)

This directory archives the multi-session investigation into running macOS Metal directly on the M1 GPU from inside the iOS chroot (the **AGX-direct** path), as opposed to the working but slower MTLSimDriver sim path.

The campaign reached the conclusion that **the AGX-direct path is structurally blocked on iPad13,6 (M1) / iOS 16.3.1 / current Dopamine** — across all four reasonable attack vectors. The notes here are an archive so that:

1. A future re-attempt under a different jailbreak / iOS version doesn't repeat the same dead ends
2. The decompile/object-chain/PTE-format work is preserved (this is non-trivial RE that takes hours to redo)
3. When kcall / KTRR bypass / a new exploit eventually surfaces, the bring-up plan is ready to execute

## How to read these notes

Read in roughly this order — each builds on the previous one's conclusion:

| # | Note | What it establishes |
|---|---|---|
| 1 | [agx-direct-path-kernel-abi-deadend](agx-direct-path-kernel-abi-deadend.md) | Earlier work: GPU executes our cmdbufs (status 2→5), but BIF0 page-faults at 0x1158048000 in the Pipelines region (0x1100000000+) |
| 2 | [ios-trollstore-app-m1-gpu-reference](ios-trollstore-app-m1-gpu-reference.md) | Reference working AGX path via TrollStore + key kernel kext / cmdbuf-layout facts |
| 3 | [agx-uat-pointer-not-in-accelerator](agx-uat-pointer-not-in-accelerator.md) | Failed approach: UAT pointer is not stored as a direct field in AGXAccelerator instance |
| 4 | [agx-dopamine-krw-uat-object-chain-found](agx-dopamine-krw-uat-object-chain-found.md) | **Object-chain breakthrough** — DUC(+0x120) → AGXShared(+0x58) → Gart(+0x288) → LocalMux(+0x10) reaches the per-task UAT context object |
| 5 | [agx-uat-l1-write-panicked-ios](agx-uat-l1-write-panicked-ios.md) | Cautionary tale: writing a guessed PT entry without validating the target page panicked the kernel & rebooted the device |
| 6 | [agx-page-tables-not-in-cpu-physread-range](agx-page-tables-not-in-cpu-physread-range.md) | After 6654-page survey: AGX page tables live in ASC firmware memory, not in CPU-physread-accessible DRAM. Direct PT writes are blocked |
| 7 | [agx-dopamine-kcall-plan](agx-dopamine-kcall-plan.md) | Detour around the PT wall: kcall `AGXSecureGart::mapWithAddress` to let the kernel do the firmware handoff. Plan is solid; needs kcall to execute |
| 8 | [dopamine-fugu14-kcall-unavailable](dopamine-fugu14-kcall-unavailable.md) | kcall blocked: `is_kcall_available()=0` because Dopamine deliberately skips PAC bypass on iOS 15.2+ |
| 9 | [agx-direct-path-all-three-paths-blocked](agx-direct-path-all-three-paths-blocked.md) | Mid-campaign summary across paths A/B/C; recommended pivots |
| 10 | [agx-pipeline-base-patch-empirical](agx-pipeline-base-patch-empirical.md) | Decisive empirical test of path C (userland MOVZ patch): some embedded VAs DO shift but the fault VA does NOT — proves macOS Metal has at least 2 independent VA sources |
| 11 | [dopamine-kwrite-text-blocked-by-ktrr](dopamine-kwrite-text-blocked-by-ktrr.md) | Empirical test of path Y (kernel `__TEXT` patch): kwrite32 to a `__TEXT` page HANGS indefinitely. KTRR (hardware memory-controller lock) blocks the write; PPL bypass doesn't help |

## Summary: every approach we tried

| Approach | Idea | Empirical result |
|---|---|---|
| Direct PT walk + alias | Find the L1 page table via kread, write L1[1]=L1[0] to alias 0x1100000000+ to 0x0+ | PT pages are in ASC firmware memory, not CPU-physread-reachable. One blind write attempt panicked the kernel |
| **A** `kcall(AGXSecureGart::mapWithAddress)` | Let kernel add the mapping via its own primitive | `is_kcall_available()=0` on Dopamine for iOS 15.2+ arm64e (no PAC bypass installed) |
| **B** IOConnect selector taking user VA | Dispatch table → mapWithAddress via existing kernel path | iOS kernel has zero such selectors (the strings `pinnedGPUAddress` etc. don't appear in the kernelcache; `reserveGPUVirtualAddress` has zero BL callers) |
| **C** userland-shim of macOS Metal | Patch macOS AGXMetal13_3 to use a different pipeline base | Patch works mechanically (cmdbuf-embedded VAs shift to 0x15xx) — but the GPU page fault stays at 0x1158048000 because the fault VA is produced by a different (firmware-side) allocator |
| **Y** patch kernel `__TEXT` to call our function | Use Dopamine's kwrite to splice a trampoline into an unused kernel function | kwrite to `__TEXT` HANGS; KTRR blocks writes at the memory-controller level. PPL bypass (dmaFail) bypasses PPL but not KTRR |
| **Z** kernel data-struct manipulation | Modify existing kernel objects so normal IOConnect flows do what we want | Not attempted — high risk, low expected payoff given path C's finding that the fault VA comes from a source userland can't influence |

## What's still committed in code

`libmachook/mac_hooks.m` keeps two env-gated diagnostic patches from this campaign:
- `AGX_PIPELINE_BASE_PATCH=0xNN` — replaces all 10 `MOVZ Xd, #0x11, LSL #32` in macOS AGXMetal13_3 with `MOVZ Xd, #0xNN, LSL #32`. See [agx-pipeline-base-patch-empirical](agx-pipeline-base-patch-empirical.md) for the reproducible test
- `AGX_OBJC_VA_FIX=1` — earlier postmortem diagnostic (kept for documentation)
- Plus the older `AGX_STRIP_HEAP_OPT`, `AGX_KCMD_FIX` (this one IS the 0x103 fix; broke the kernel-validation wall but exposed the fault VA wall)

## When to revisit this

Trigger to re-open the campaign:

1. **Dopamine gets `is_kcall_available() = 1` on iOS 16+ arm64e** — the kcall plan ([agx-dopamine-kcall-plan.md](agx-dopamine-kcall-plan.md)) is ready to execute as-is
2. **A KTRR bypass exploit lands for iOS 16+ arm64e** — path Y becomes viable
3. **A different jailbreak with full PAC + KTRR bypass appears** — both A and Y open up
4. **AGX firmware (ASC RTKit) RE makes meaningful progress** — the firmware-side allocator can be patched and the C path becomes viable

## What to use right now

The sim path (MTLSimDriver via libmachook's `MTLFakeDevice`) **works**. GUI apps render through it. The AGX-direct path is a performance optimization, not a functionality fix — sim path is the production option until any of the four triggers above arrives.

## Test programs

`diagnostic-tools/` contains the small C programs we used to empirically prove each finding:

- `kcall_test.c` — proves `is_kcall_available()=0` and `jbclient_get_fugu14_kcall()=-1`
- `text_write_test.c` / `test3.c` — proves kwrite to `__TEXT` hangs (KTRR)
- `survey.c` / `survey3.c` / `survey4.c` — page-table-page survey with various PTE heuristics (0 real hits)
- `krwtest.c` — early KRW navigation test, finds the object chain
- `patcher.c` — iOS-side patcher that walked all 22 DUC TTBs (the one that triggered the panic — DO NOT re-run without modifying the L1[1] write logic)

All are iOS-platform arm64e binaries that dlopen `/var/jb/basebin/libjailbreak.dylib`. Build with:
```
xcrun -sdk iphoneos clang -arch arm64e -Wl,-platform_version,ios,16.3,16.3 X.c -framework IOKit -o X
ldid -S<entitlements.plist> X
# trustcache + jbctl add the CDHash, then run as root
```
