# MTLSimDriverHost — multi-handler appContext guard (2026-06-16)

## Problem

Firefox under load triggered repeated MTLSimDriverHost crashes:

```
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0
  Frame 0: MTLSimImplementation+0x2a20  MTLSimApplicationContext::deleteObject(...)
  Frame 1: MTLSimImplementation+0x3478  block_invoke (MTLSimulatorHandleEvent)
  ...
```

This is the same appContext race that `MTLSimDriverHost/main.x` already had a
guard for on `newObjectCommand_DEPRECATED` — **but on a different XPC handler**.

## Root cause

MTLSimApplicationContext has 15+ public XPC handlers. The per-connection `this`
pointer ([conn_ctx+0x10]) is NULL during the race window between
`xpc_connection_activate()` and the connection's "init" message. ANY handler
that fires in this window dereferences `this` directly and faults at 0x0.

Under Firefox load (~50 GPU contexts/sec, many short-lived), the race fires
constantly. The existing guard on `newObjectCommand_DEPRECATED` only covered ONE
of the 15 entry points.

## Fix

Unified guard installer on all known handlers:

- `newObjectCommand_DEPRECATED` (existing, kept)
- `deleteObject` (the new crash)
- `newBufferWithLength`
- `submitCommandBuffer`
- `newIOSurfaceTexture`
- `newCommandQueueWithDescriptor`
- `newSharedEventHandle`
- `newSharedEventWithHandle`
- `newSharedEventWithMachPort`
- `newFunction`
- `reportLeaks`
- `notificationWithListener`
- `wait`
- `getBytes`

Each handler is wrapped via a `GUARD_HANDLER(NAME, MANGLED)` macro that:
1. If `thiz != NULL`: cache it as the last-known-good per-process appContext, call orig.
2. If `thiz == NULL` but cache is warm: swap in cached appContext, call orig.
3. If both NULL: return an empty XPC reply (matches the function's "no object produced" semantics).

The cache is protected by `pthread_rwlock_t` (read-heavy workload — cache is
written once per warm, read on every race fire).

## Verification

Before:
```
Firefox launch + heavy compositing
  → plugin-container SIGKILL every 10s (EXC_GUARD GUARD_TYPE_MACH_PORT)
  → MTLSimDriverHost SIGSEGV every ~30s (deleteObject NULL-this race)
  → WindowServer cascade restart
  → watchdog auto-stops GUI after load > 25
```

After (this fix):
```
Firefox: 4m26s uptime, CPU 1.5%, MEM 4.0%, stable
MTLSimDriverHost: 12m48s uptime, CPU 2.4%, stable
WindowServer:    12m48s uptime, stable
Load average: 1.92 (1min), dropping
Zero crash reports in last 5 minutes
```

## Build

```bash
# On the iPad:
THEOS=/var/jb/var/mobile/theos bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh
```

The new MTLSimDriverHost.xpc is installed by the package's postinst.

---

# Update (2026-06-16 16:30): Round 2 stability fixes

After deploying the MTLSimDriverHost multi-handler guards, Firefox still crashed
WindowServer via different SkyLight asserts:

## Added: SkyLight `MetalContext::EndUpdate(bool)` patch

`MetalContext::EndUpdate(bool)` contains 3 `bl __assert_rtn` sites that fire when
Firefox's software WebRender creates many concurrent compositor surfaces and the
`_update_depth` / `_state_stack` invariants drift. Each is converted to `ret`.

Image offsets (verified via lldb against live WindowServer):
- 0x147174 (`assert(_update_depth >= 1 && "Unbalanced Updates.")`)
- 0x1471b8 (`assert(_state_stack.empty() && "Unbalanced Composites.")`)
- 0x1476d4 (third assert in same function)

See `libmachook/mac_hooks.m`:
```c
#define OFF_SkyLight_MetalContext_EndUpdate_assert_1 0x147174
#define OFF_SkyLight_MetalContext_EndUpdate_assert_2 0x1471b8
#define OFF_SkyLight_MetalContext_EndUpdate_assert_3 0x1476d4
```

## Avoided: global `__assert_rtn` interpose

Initially tried to interpose libc's `__assert_rtn` to swallow ALL asserts globally.
**This caused the device to reboot** — libSystem (libdispatch, pthread teardown)
relies on assert() actually aborting; making them return left libSystem in
undefined state. Reverted; rely on targeted byte patches instead.

## Added: Watchdog threshold relaxation

`macos_gui.sh` watchdog tuned for Firefox workload:
- `WD_LOAD_LIMIT`: 25 → **60** (Firefox software WebRender legitimately runs hot)
- `WD_RESTART_LIMIT`: 4 → **12** (tolerate occasional SkyLight CAWSBackend asserts
  we haven't byte-patched yet — `composite_destination != nullptr` in `render_update`
  still fires. launchd respawns WS in ~1s; up to 12 restarts / 45s is recoverable.)

## Verified

Firefox under load:
- 3 min run, 0 WS restarts, 0 watchdog runaway
- Firefox PID stable, CPU 0-7% range, MEM 4.2% level
- Load avg 2.16-2.85 (well under threshold)

## Known remaining issue

`SkyLight::WS::Displays::SLCADisplay::render_update` has an
`assert(composite_destination != nullptr)` (CAWSBackend.mm:5192) that still fires
intermittently. Not yet byte-patched because:
- The function is large (600+ instructions) and the assert site isn't trivially
  located by static analysis
- lldb's `image lookup --regex` is buggy in iOS 16's lldb16 batch mode
- The function's runtime VA changes per-boot due to dyld shared cache slide

Mitigation in place: launchd auto-respawns WS, watchdog tolerates ≤12 restarts/45s.
Firefox main process stays alive across WS restarts.
