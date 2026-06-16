# VSCode on Jailbroken iOS — Final Status (2026-06-16)

## What worked

| Component | Status | Evidence |
|---|---|---|
| Device + signing infrastructure | ✅ | Node.js v18.18.2 (89 MB Mach-O) ran cleanly |
| VSCode binary install + sign | ✅ | 42 Mach-O files signed + trustcached |
| libmachook injection into Code | ✅ | DYLD_PRINT_INTERPOSING showed mmap/sysctlbyname hooked |
| V8 init partial progress | ✅ | Reached `v8::V8::Initialize` → `cppgc::IsInitialized` → `ThreadIsolation::Initialize` → `ElectronMain` |
| AppKit reachable (one lucky run) | ✅ | Crashed at `_RegisterApplication` → `NSApplication.sharedApplication` |
| Identifying root cause | ✅ | binary string `'Oilpan: CagedHeap reservation.\x00../../v8/src/heap/cppgc/caged-heap.cc'` + lldb-attached brk trace |

## What's blocked

**Fundamental:** iOS kernel rejects any single virtual-memory reservation ≥ ~32 GiB.

**V8's CagedHeap** uses an over-allocation pattern:
```
mmap(NULL, size + alignment, PROT_NONE, MAP_PRIVATE|MAP_ANON)
   where size = alignment = 32 GiB,  so size+alignment = 64 GiB
```

iOS denies it. The 32 GiB probes succeed (3× returning `0x280000000` each), but the
`size+alignment` request fails. V8 has no fallback path — it always FATALs.

## Userland workarounds attempted (all dead ends)

1. **`setrlimit(RLIMIT_AS, INFINITY)`** — limit was already `INT64_MAX`, not a userland resource cap.
2. **mmap shim (halve-and-retry)** — succeeds, but V8 internally trims the reservation; trim ops that fall outside the actual mapping trigger kernel `EXC_GUARD GUARD_TYPE_VIRT_MEMORY DEALLOC_GAP` → SIGKILL.
3. **munmap SWALLOW/PARTIAL/NOOP** for out-of-range trims — gets past the kernel guard but V8 sees inconsistent state when subsequent mmaps deterministically overlap the shim region → internal CHECK fails.
4. **MAP_FIXED at high VA** — iOS denies fixed mapping at `0x800000000000`.
5. **mach_vm_map / mach_vm_allocate / vm_allocate hooks** — also interposed; V8's specific allocator path didn't go through them as expected; no observed effect.
6. **task/thread_set_exception_ports block** + **sigaction(SIGTRAP) lock** + **SIGTRAP handler PC+=12 swallow** — works (199 successful swallows observed in one run!) but V8 just *re-enters* the same CHECK on the next codepath iteration → recursive handler invocations → stack overflow → SIGBUS.

## What would actually fix this

The only real fix: recompile V8/Chromium with `cppgc_enable_caged_heap=false`. That removes the 64 GiB reservation entirely. Multi-day Chromium build effort.

Alternatively: a much more complete VM virtualization layer in libmachook that simulates a 64 GiB VA region using less actual memory + intercepts every Mach VM and POSIX VM call to maintain consistency. Multi-week project.

## Concrete artifacts in this repo

```
libmachook/mac_hooks.m       ← +274 lines new hooks (mmap+munmap range tracking, mach_vm_*, task/thread_set_exception_ports, sigaction/signal SIGTRAP guard, SIGTRAP handler that PC+=12, RaiseVMLimit)
misc/electron/
  launch_vscode.sh           ← VSCode launcher (--no-sandbox --disable-gpu)
  resign_vscode.sh           ← Re-sign + trustcache after rebuild
  patch_brk.sh               ← Binary patcher (--restore reverts; v6 patches all abort helpers + skips CagedHeap init)
  vscode_entitlements.plist  ← JIT + library-validation + sandbox bypass entitlements
  resume_vscode.sh           ← One-shot post-reboot recovery orchestrator
  lldb/                      ← lldb attach + dump scripts (Procursus lldb16, no Python)
  findings/                  ← root-cause.md + this file
```

## Reproduction summary

```bash
# On the iPad (over SSH):
echo alpine | sudo -S /var/jb/usr/macOS/bin/run_bash.sh /tmp/launch_vscode.sh \
    > /var/jb/var/mobile/vscode.log 2>&1

# Expected: shim activity logged, then SIGTRAP loops, then Bus error / Trace BPT
grep -E "SHIM|swallow|BLOCKED" /var/jb/var/mobile/vscode.log
```

## Honest assessment

The /goal directive of "successfully run VSCode" was understood as "show a working VSCode window".
We did not achieve that. We *did* achieve substantial progress past the initial brk #0 abort,
into V8 internals, Node.js, Electron Main, AppKit. The final blocker is V8's fundamental
assumption about VA address space size on macOS, which is incompatible with iOS kernel limits.
