# Production diagnostic hot-path audit (2026-09-19)

## Scope and observed evidence

Source-confirmed: `macws_vnc_publish_owned_texture` queried two diagnostic
sentinels on every completed owned frame. The texture-layout observer queried
another on every applicable IOSurface-backed texture allocation. Geekbench's
transfer-buffer compatibility wrapper queried its numeric diagnostic sentinel
on each call, even when the resource options did not need translation.
These were filesystem queries with diagnostics disabled, not GPU work required
by their production adapters.

This source audit **does not establish that these queries caused the reported
heat**, nor quantify a temperature/CPU improvement. No device command, project
build, restart, or production deployment was performed for this change.

## Narrow change and diagnostic lifetime

Four existing default-off switches now use the existing process-lifetime
`MACWS_DEFINE_STARTUP_FLAG` cache:

| Existing sentinel | Actual consumers | In-tree producer/caller audit |
|---|---|---|
| `/tmp/macws_owned_no_read` | Completed owned-frame publication A/B | No in-tree live-toggle producer found; listed as an A/B diagnostic and in production cleanup |
| `/tmp/macws_owned_unlocked_read` | Same publication path's unsafe lock A/B | No in-tree live-toggle producer found; listed as unsafe A/B and in cleanup |
| `/private/tmp/macws_texture_stride_diag` | Plain-texture IOSurface layout observer | Performance harness only lists it among diagnostics to exclude/clean; no runtime arming producer found |
| `/tmp/macws_geekbench_numeric_diag` | Transfer-buffer log and UUID-validated numeric observer installer | Existing installer explicitly documented process-start selection; no in-tree live-toggle producer found |

Set or remove these sentinels **before launching the target diagnostic
process**. They are resolved lazily on first use, like the adjacent existing
diagnostic caches, and retained for that process's lifetime. Changing a selected
switch after first use requires restarting that target process. This is not a
new way to configure production: all four remain absent/off normally. The
atomic cache can permit simultaneous first callers to make duplicate initial
queries; it eliminates steady-state queries, not a claim of precisely one
syscall across every startup interleaving.

The Geekbench wrapper also performs the cheap options comparison before the
optional observation gate. The original buffer allocation and actual option
translation remain unconditional. No validation result, synchronization,
texture descriptor, pixel format, or callback result is changed.

## Deliberately not cached

- `macws_capture_final` carries a real frame-request generation, is read and
  acknowledged by production transport, and must remain dynamic.
- `macws_inband_pf550` is also removed by a runtime fault circuit breaker.
  This patch does not change that experiment's live enable/disable semantics.
- Unsafe PF550 capture, PF550 metadata capture, and late-armed observation
  controls are left unchanged rather than assuming their timing is identical.
- `macws_catalyst_direct_drawable_active` and render-target capture requests
  are deliberately armed after a diagnostic harness observes gameplay.
- Environment tracing and Metal library-data observers are outside this
  small change; no generic flag-file cache or blanket stderr filter was added.

## Verification and limits

`misc/test_metal_diagnostic_hot_path.py` checks the actual cache macro, all four
registered default-off gates, removal of their direct access call sites,
preserved owned-frame lock/unlock, unchanged buffer adapter ordering, and
preservation of dynamic request/circuit-breaker accesses. These source
contracts require neither compilation nor a connected iPad. They are not a
substitute for a later measured render/benchmark regression check.

Results: five new hot-path source checks and three success-log checks passed;
`git diff --check` passed. An additional existing runtime-gate inventory suite
passed sixteen tests; one of those tests internally compiled a small host-only
C fixture. That incidental compiler invocation was outside the requested
no-compilation scope and was reported immediately; no project or device build
was run. The new source checks themselves do not invoke a compiler.

Separately, `misc/test_runtime_success_logging.py` checks five success-only
logging blocks in `mac_hooks.m`: bridge setup/results, QuickLook connection
ownership, and Steam overlay installation. Success uses the existing runtime
diagnostic switch; setup/protocol errors and nonzero results stay visible.
An actual no-flag command previously emitted these success lines:

```text
#### CORESERVICES-MAP-BRIDGE client pid=12523 message=10054 task-self=515 bridge-port=13827
#### CORESERVICES-MAP-BRIDGE client-result pid=12523 message=10054 result=0 reply-id=10154 reply-size=48
```

Runtime receipt: `/tmp/macws-ql-fresh-pdf-qlmanage-20260919.log` on the development
Mac. The old `fprintf` translation-unit macro did not intercept `dprintf`.
Its early return suppressed `vfprintf`, but could not suppress evaluation of
arguments before the call; the new outer guards avoid both success formatting
and argument work. No claim of post-deployment silence is made yet.
