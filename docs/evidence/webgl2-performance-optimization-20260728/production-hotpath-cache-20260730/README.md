# Production hot-path cleanup and cold-start readiness (2026-07-30)

This run separates a measurable project-side diagnostic cost from the still
open VS Code Aquarium performance gap. It also fixes an independent one-click
startup reliability problem without weakening the graphics-ready invariant.

## Runtime-confirmed: diagnostic filesystem probes were in the GPU hot path

The initial six-second production sample at 60,000 fish contained 39
top-of-stack `access(2)` samples. Its call graph attributed the surviving
per-draw probes to libmachook diagnostic gates, including the
`macws_trace_small_pf550_bind` check under `setFragmentTexture:atIndex:`. See
[`gpu-before.sample.txt`](gpu-before.sample.txt).

All affected flags are process-start contracts: `macos_gui.sh` creates or
removes them before launching a client, and production preflight rejects any
diagnostic survivor. The exact individual gates are now cached once per
process. This changes neither the functional native-AGX KCMD translators nor
the real command-buffer error returned to Chromium.

The final same-duration 60,000-fish sample contains no `access(2)` frame at
all. The active stacks remain in the actual workload: 1,152 top-of-stack
samples in `glStartTilingQCOM`, 100 in
`AGX::RenderContext::encodeAndEmitRenderState`, and only seven recursive
samples in `-[_MTLCommandBuffer waitUntilScheduled]`. See
[`gpu-after.sample.txt`](gpu-after.sample.txt). This runtime-confirms that the
filesystem probes were removed and that ANGLE/AGX command encoding, not the
diagnostic flags, remains the dominant executable hotspot.

## Performance result: useful hygiene, not the root fix

The final official VS Code 1.130.0 / Electron 42.6.0 / Chromium 148 run used
the visible WebGL2 Aquarium target, 60,000 model fish, a fixed 1024x1024
canvas, eight seconds of warm-up, and 15 seconds of `g_fpsTimer.update`
timestamps. It produced 12.289 FPS, p50 80.0 ms and p95 93.8 ms, with
`contextLost=false`; the complete result is
[`aquarium-60000-after.json`](aquarium-60000-after.json).

The preceding production milestone was 12.056 FPS. The new value is about
1.9% higher, too small to distinguish confidently from run-to-run variation.
Therefore this change is not claimed as the WebGL performance solution. The
remaining evidence still points to CPU work in Chromium ANGLE and the macOS
13.4 AGX argument/render-state encoder for this draw-heavy workload.

## Runtime-confirmed: strict one-click cold start now completes

Under the old 45-second readiness window, WindowServer remained alive and its
sample showed active SkyLight updates, native IOGPU submissions and the
cancelled-swap completion pace, but the launcher returned before the first
clean-producer file appeared. The captured process sample is
[`windowserver-before-old-deadline.sample.txt`](windowserver-before-old-deadline.sample.txt).

The timeout is now 90 seconds. The condition itself is unchanged: a stable
current WindowServer PID must match the PID written by an actually completed,
error-free display producer. The final cold production command reached that
witness, launched VNC and Terminal, and validated a 2388x1668 Retina first
frame. The exact console and RFB hashes are in
[`production-start-result.txt`](production-start-result.txt); the corresponding
frame is [`retina-vnc-terminal.png`](retina-vnc-terminal.png).

At handoff, VS Code was unloaded to recover memory, while the validated
coexistence WindowServer, Retina VNC server and Terminal were intentionally
left running for interactive use.
