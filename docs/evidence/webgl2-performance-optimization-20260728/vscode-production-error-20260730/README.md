# VS Code large-KCMD limit and restored-tab ownership (2026-07-30)

This directory records two independent failures exposed after the latest
VS Code 1.130 / Chromium 148 WebGL2 path began submitting sustained native-AGX
work. The first was a project-side KCMD inspection/translation bound. The
second was excess renderer ownership from restored duplicate Aquarium tabs.
Neither was an iOS GPU protocol limit, and neither is treated as evidence that
all future resource-pressure failures are solved.

## Runtime-confirmed: our 64-KiB guard skipped a real Chromium submission

The first raw completion witness returned the real driver error `0x103`:

```text
#### IOGPU-ERROR-GETTER observation=1 ... submitSerial=0 fixed=0 ... description=Internal Error (00000103:Internal Error)
```

The same log's command-storage dump contains, at storage offsets `+0x28` and
`+0x30`, little-endian pointers `0x12958c000` and `0x1295a34c0`. Their
difference is `0x174c0`; the associated segment list was `0x8000` bytes. The
old `0x10000` KCMD guard rejected that descriptor before the existing
structurally validated macOS-to-iOS record translation and before the
flight recorder could associate a submit serial. This is runtime-confirmed by
[`raw-callback-103-run1/vscode.log`](count256-followup/raw-callback-103-run1/vscode.log).

A follow-up recorder run also shows why serial-zero observations must not
freeze the one-shot evidence ring: the first synthesized getter observation
had `submitSerial=0`, while the next mapped error was:

```text
#### IOGPU-ERROR-GETTER observation=2 ... submitSerial=94 fixed=8 ... description=Internal Error (00000103:Internal Error)
```

That exact transition is in
[`count256-followup/vscode.log`](count256-followup/vscode.log). The error is
still returned unchanged to Chromium; the diagnostic now waits for a mapped
submit before freezing its evidence.

## RE-confirmed: IOGPU grows well beyond 64 KiB

The exact iOS 16.3
`_IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer` implementation loads
the current shared-memory size, compares it with the required size, doubles it
while it is below 2 MiB, and then grows it in 1-MiB increments. See
[`ios16-iogpu-grow-kcmd.disasm`](ios16-iogpu-grow-kcmd.disasm), especially
`0x19d144820..0x19d144838`.

Therefore the 64-KiB boundary was project-local, not a native IOGPU protocol
limit. The bounded validator/fast recorder now accepts up to `0x40000` KCMD
bytes and `0x20000` segment bytes, with 48 preallocated slots. Its explicit
diagnostic footprint remains 18 MiB:

```text
48 * (0x40000 + 0x20000) = 0x1200000
```

This exchanges history depth for enough payload width. It does not change the
driver command format, invent command records, suppress completion errors, or
claim that `0x40000` is a protocol maximum.

After the correction, the diagnostic run translated large batches and kept
receiving clean native completions, including:

```text
#### IOGPU-CALLBACK-BUFFER-CLEAN ... submitSerial=291 fixed=142 ...
```

The full witness is
[`large-kcmd-cap-fix/diagnostic-run1/vscode.log`](large-kcmd-cap-fix/diagnostic-run1/vscode.log),
and [`diagnostic-vnc-run2.png`](large-kcmd-cap-fix/diagnostic-vnc-run2.png)
shows the corresponding rendered VS Code frame.

## Separate resource-pressure failure and ownership fix

With the KCMD limit removed, the next production run exposed a separate ANGLE
allocation failure:

```text
GL_OUT_OF_MEMORY ... mtl_resources.mm, MakeTexture:330. Failed to allocate host memory.
```

It is preserved in
[`large-kcmd-cap-fix/production-vnc-run1/vscode.log`](large-kcmd-cap-fix/production-vnc-run1/vscode.log).
The failure-only texture instrumentation did not observe the project allocator
returning nil in the next diagnostic run; its compatibility lease pool reached
about 64 MiB. At that time VS Code had restored five independent Aquarium
webviews, each owning a Chromium renderer and native-AGX resource graph. See
[`texture-oom-diagnostic-run1/vscode.log`](texture-oom-diagnostic-run1/vscode.log)
and [`before-dismiss.png`](texture-oom-diagnostic-run1/before-dismiss.png).

The benchmark extension now performs bounded convergence after workbench
restore and leaves exactly one tab named `WebGL Aquarium`, closing only its own
duplicates. [`after-convergence.png`](idempotent-aquarium-run2/after-convergence.png)
is the visual witness. Subsequent controlled one-tab 1,000- and 60,000-fish
production runs had no texture nil, `GL_OUT_OF_MEMORY`, IOGPU completion error,
or WebGL context loss. This closes the reproduced duplicate-owner case; it is
not a blanket proof that arbitrary workloads can never exhaust memory.
