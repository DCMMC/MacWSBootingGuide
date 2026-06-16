# VSCode/Electron — Root Cause Analysis

**Date:** 2026-06-15
**Goal:** Run VSCode (Electron / Chromium) in the macOS chroot

## Summary

VSCode crashes during dyld static initialization. The first failing CHECK is in
V8's **Oilpan CagedHeap** initialization, which tries to reserve **32 GB of
virtual address space** via `mmap(NULL, 0x800000000, PROT_NONE, MAP_PRIVATE|MAP_ANON, -1, 0)`.
iOS kernel denies this (per-process VM limit ≪ 32 GB), V8 calls
`FATAL("Oilpan: CagedHeap reservation.")` from `v8/src/heap/cppgc/caged-heap.cc`,
process aborts before `main()`.

**Source-binary verification (string in Electron Framework):**
```
0x91c800c: 'Oilpan: CagedHeap reservation.\x00../../v8/src/heap/cppgc/caged-heap.cc'
```

## Crash signature

- `EXC_BREAKPOINT (signal=SIGTRAP, ESR=brk #0)` at framework offset `0x53408c8`
- The brk is a Chromium `IMMEDIATE_CRASH()` macro expansion (brk #0; hlt; brk #1)
- Stack at fault:
  ```
  frame 0: Electron Framework + 0x53408c8   (abort helper)
  frame 1: Electron Framework + 0x12331b4   (CagedHeapBase init wrapper)
  frame 2: Electron Framework + 0x12328d4
  frame 3: Electron Framework + 0x1cdc0a0   (v8::V8::SetSnapshotDataBlob area)
  ...
  frame N: dyld4::Loader::runInitializersBottomUp
  ```
- Key static analysis confirming CagedHeap path:
  - At offset 0x12330d0 the function does `movz x0,#0x8,lsl#32` (size 0x800000000 = 32 GB)
  - Calls allocator helper at 0x12331d4 → tail-calls 0x11a0d18 (mmap wrapper)
  - On NULL return (alloc failed), branches to abort helper

## Why binary patches alone don't work

Iteratively patching each abort helper to `ret` cleanly is fragile because:
1. Helper functions are `[[noreturn]]`-designed with shared epilogue blocks
2. Patching one helper to return causes upstream callers (also `[[noreturn]]`) to
   "fall through" into the next function's prologue → unbounded tail-call chain → stack overflow
3. Even after fixing fall-throughs, V8 static inits expect CagedHeap to actually be
   initialized — skipping the init leads to PAC failures and bad pointer derefs
   downstream (e.g. crash at offset 0xed4d4 with fault addr `0x6c6e6f20657697cb`)

## The right fix: hook mmap to make the reservation succeed

Implementation in `libmachook/mac_hooks.m` (added 2026-06-15):

```c
static void *mmap_hook(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    void *r = mmap(addr, length, prot, flags, fd, offset);
    if (r == MAP_FAILED && addr == NULL && length >= (1ull << 30) &&
        (flags & MAP_ANON) && fd == -1) {
        // Big anonymous reservation failed -- substitute a smaller (256 MB)
        // mapping. V8 stores the pointer + computes derived offsets within the
        // claimed 32 GB range; works until V8 actually touches beyond 256 MB.
        void *r2 = mmap(NULL, 256 * 1024 * 1024, prot, flags, -1, 0);
        if (r2 != MAP_FAILED) {
            fprintf(stderr, "#### mmap SHIM: req=0x%zx -> %p\n", length, r2);
            return r2;
        }
    }
    return r;
}
DYLD_INTERPOSE(mmap_hook, mmap);
```

Status: built + deployed via `build_on_ios.sh`; device rebooted during deploy
(probably postinst's launchctl unload/load), waiting for it to come back up.

## Artifacts produced

- `misc/electron/launch_vscode.sh` — launch wrapper with `--no-sandbox --disable-gpu`
- `misc/electron/resign_vscode.sh` — re-sign + trustcache (post-reboot)
- `misc/electron/vscode_entitlements.plist` — JIT entitlements (`allow-jit`, `dynamic-codesigning`, etc.)
- `misc/electron/patch_brk.sh` — binary patch helper (`--restore` reverts)
- `misc/electron/lldb/dump_at_check.cmd` — lldb cmd file: attach --waitfor + dump @ brk
- `misc/electron/lldb/attach_and_dump.sh` — orchestrator (race lldb + Code launch)
- `misc/electron/lldb/parse_dump.py` — host-side lldb output parser
- `libmachook/mac_hooks.m` — added `mmap_hook` DYLD_INTERPOSE for V8 CagedHeap

## Next steps when device is back

1. Verify libmachook deployment: `strings /var/jb/usr/macOS/lib/libmachook.dylib | grep SHIM`
2. Resign + trustcache VSCode if trustcache wiped: `bash misc/electron/resign_vscode.sh`
3. Confirm `ls` works in chroot (sanity check libmachook isn't breaking exec)
4. Launch VSCode: `bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/launch_vscode.sh`
5. If still crashes: stage 2 might be needed — extend mmap_hook to also cover
   `mach_vm_allocate`/`vm_allocate` paths, OR add a SIGBUS handler that
   lazy-allocates pages as V8 touches them beyond the 256 MB shim.
