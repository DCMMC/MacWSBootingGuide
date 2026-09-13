# Interoperation, Launchpad, command latency and Geekbench — 2026-09-13

Device: iPad13,6, iPadOS 16.3.1. This is a partial acceptance record, **not**
a claim that all requested tasks are complete. Raw logs, screenshots, the
downloaded application and benchmark claim credentials remain outside Git.

## Acceptance boundaries

| Request | Observed result |
| --- | --- |
| Files → Share → Open in Other App → macPad | Listed in the real share UI; a PDF opened and rendered in macOS Preview |
| Large-file Open-In import | 232,584,192-byte DMG staged with identical SHA-256; handler accepted it, but the encrypted image was not mounted |
| Files → Finder drag | Not accepted yet: synthetic drag picked up the file and entered Host, but UIKit never called `performDrop:` |
| Launchpad single-finger paging | Real touch swipe changed to page 2; reverse swipe returned to page 1; Preview scrolling still routed to Preview afterward |
| Terminal command latency | `neofetch`: 22.846 s baseline, 6.277 s first optimized run, 4.179 s warm run |
| Menu/Dock Quit | Normal menu Quit verified for owned Geekbench and Calculator sessions; original failing apps and Dock path not yet reproduced/accepted |
| Geekbench CPU | Official 6.7.1 completed: 2290 single-core, 8166 multi-core |
| Geekbench GPU | Official 6.7.1 Metal completed three consecutive post-fix runs with no validation failure; two diagnostics-off production runs scored 30,824 and 31,994 |

No iPad reboot, respring, SpringBoard, backboardd, WindowServer or Dock restart
was used for this acceptance work. Own Host/broker/display/input services were
updated. The four original system PIDs remained 3601, 429, 20382 and 20701.
This process check supplements, and does not replace, the visible/API witnesses.

## Open-In and large file integrity

The document registration uses Viewer/Alternate for `public.data` and
`public.content`, with in-place opening disabled. Cold/warm scene URL delivery
shares the same import path. A security-scoped, coordinated copy is completed
before resolving the real macOS default handler; AppKit open-document delivery
is acknowledged separately from process launch. No clipboard rewrite is needed.

Runtime-confirmed via `MacWSHost.log` / `MacWSHostd.log`:

```text
1789247742.215 launch-document process-ready ... pid=80177 ... endpoint=ready
1789247743.185 open-documents ... pid=80177 ... count=1 result=appkit-accepted
1789247746.142 runtime-confirmed native Metal present ... status=4 error=nil
```

The lines above omit document paths and unrelated fields with `...`; the
verbatim status fragments are `endpoint=ready`, `result=appkit-accepted` and
`status=4 error=nil`. Screenshot `tmp/open-in-pdf-final-20260913.png` shows
readable PDF content; `tmp/open-in-share-apps-bottom-20260913.png` shows macPad
in the native share application list. An offline WindowServer cold launch was
not tested because restarting that desktop is outside this acceptance boundary.

The provided DMG in On My iPad, the previous macOS copy and the new Open-In
copy all have SHA-256:

```text
22396b666f57df03c7143149583ea2aeabde7bd7cdd6df439ec28353115fc3bb
```

Its header is `encrcdsa`. This does **not** establish transfer corruption.
The official, signed Geekbench distribution was installed instead; no crack,
license bypass or modification of benchmark workloads was used.

Regular-file staging now uses a shared 128 KiB streaming copier, with exact
byte count, EINTR/partial-write handling, source metadata stability checks,
destination sync and SHA-256 readback. The inline-archive size limit is not a
file-size limit. Provider acquisition is serialized; callback-scoped URLs are
copied before returning. All requested items must be acquired, rather than
publishing a partial selection when a transaction-wide timer fires. Timeout
does not race a callback-owned copy. Failed unpublished copies are removed;
provider originals and previous exports are not cleanup targets.

`misc/test_file_import.py` compiles the actual C copy helper and tests empty
and binary files, an 80 MiB patterned file with a non-aligned tail, interrupted
reads/writes, short writes, source truncation/growth/mutation, destination
corruption and a write-only destination. Registration/batch tests are source
contracts, not substitutes for physical drop acceptance.

## Drag acceptance is still open

Both the large DMG and a small PDF showed a real pickup and Copy badge in
`tmp/large-drag-pickup2-sequence-20260913/`. The target owned test folder
remained empty. Runtime-confirmed via `tmp/drop-druid-session-20260913.log`:

```text
Observed touch up for touch 2567 detached 1 context 0 pid -1
Destination (0) and/or touch delivery observation (1) did not end in a reasonable amount of time; cancelling drag.
```

Host's native UIKit log (`tmp/drop-host-oslog-20260913.log`) transitions from
`Connecting` to `Dragging`, then from `Dragging` to `Failed`. Host's delegate
records session entry/end but no `interop-drop-received`. The provider copier
was not entered. **THEORY:** the global synthetic touch tool may not deliver
the destination drag-end event correctly. Physical input or a native-app
control must distinguish this from a Host-side defect. Do not force a drop
from `sessionDidEnd:`: cancellation is not permission to copy files.

Freshly constructing finger-up, changing parent range, and delaying client
release did not resolve it. Those probe changes were reverted. No production
UIKit or Druid check was bypassed. Touch diagnostics were disabled afterward.

## Launchpad and Quit

The display broker now advertises a bounded, input-only catalog of actual
visible Dock-owned `LPSpringboard` windows. Host uses that descriptor before
ordinary app routing; it is not a new capture surface or blanket Dock fallback.
Global scroll preserves pixel deltas, phase and momentum through the native
CGEvent route. Hidden Launchpad and unrelated Dock surfaces do not match.

Runtime-confirmed via Host log (selected fields):

```text
1789256469.810 fullscreen-layer-input runtime-confirmed pid=20701 target=20701 route=global-system window=14 flags=0x20
1789256845.825 fullscreen-layer-input runtime-confirmed pid=80177 target=80177 route=app window=1606 flags=0
```

Visible witnesses: `tmp/launchpad-visible-catalog-swipe-20260913.png`,
`tmp/launchpad-reverse-swipe-20260913.png`, and
`tmp/preview-scroll-after-launchpad-20260913.png`.

For Quit, a menu acknowledgement alone was not accepted. The owned Geekbench
test process exited normally:

```text
1789256945.402 launch-app reaped id=custom-path pid=96577 result=exit-0
1789256945.404 app-session exit id=custom-path pid=96577 witness=waitpid:exit-0
```

The owned Calculator process also disappeared after its menu Quit. These two
successes do not prove the user's unspecified failing applications are fixed.
No force-kill fallback or unsaved-document suppression was added.

## Command latency

The bounded autosignd cache stores only successful, complete `ldid -h` and
`otool -l/-L` metadata results, keyed by argv and file identity/version before
and after inspection. Dependency resolution and live trust membership remain
fresh; failed/truncated responses are never cached. Signature validation is
not bypassed. Capacity is 128 entries / 1 MiB.

Runtime captures: `tmp/neofetch-after-20260913.log`, warm-run and admission
logs. Admission fell from about 0.39 s to 0.021 s. These are measurements of
these runs, not a guaranteed latency for every terminal command.

## Geekbench: real CPU and Metal results

Official 6.7.1: [Primate Labs legacy downloads](https://www.geekbench.com/legacy/).
The default-device startup failure was reproduced and symbolicated to the
actual worker's `OSXSystem::gpu_models` at `+0x74`, binary offset `0x262ac4`:
the device-name lookup reached `fmt` with a null string. The app now receives
the established native Metal launch profile, selected using its actual bundle
identifier, not a fabricated device name. Live broker witness:

```text
1789254571.773 launch-metal-profile executable=/Applications/Geekbench 6.app/Contents/MacOS/Geekbench 6 bundle=com.primatelabs.Geekbench6 native=YES
```

[CPU result 19161547](https://browser.geekbench.com/v6/cpu/19161547):
2290 / 8166, verified in native iOS Safari because command-line retrieval was
blocked. `tmp/geekbench-result-ios-safari-20260913.png` records the result.
[M1 Air comparison 19131372](https://browser.geekbench.com/v6/cpu/19131372)
uses the same Geekbench 6.7.1 and macOS 13 generation: 2295 / 8189. Differences
are approximately -0.2% / -0.3%. This is a single-run comparison, not a
statistical distribution or a GPU-performance claim. Never publish the private
result claim URL from the raw CPU log.

GPU runtime-confirmed in the official worker and the new bounded
`misc/macws_mps_graph_probe.m`:

```text
MPS-GRAPH device=Apple M1 queue=0x13181d200
MPS-GRAPH run-begin
 (null) Target OS is incompatible.
```

Failure is at `MPSCore/Utility/MPSKernelDAG.mm:552`; the worker stack includes
MPSGraph and `BackgroundBlurComputeWorkload::worker`. The probe runs a real
16-element addition with a 30-second deadline and requires numerical readback;
it is not a benchmark, simulator fallback or fake completion.

Two candidate full-library translations passed static inventory checks
(MPSCore 4119/4119, MPSNDArray 148/148). Static translation was not enough.
The production specialization installer is gated to WindowServer/Stray;
the initial Geekbench GUI trials did not enable that installer. A probe-only
`MACWS_METAL2METAL_NON_WS_DIAGNOSTIC=1` trial confirmed companion loading and
changed the failure to `Compiler encountered an internal error`, but still
produced no readback. See `tmp/mps-graph-routing-enabled-20260913.log`.
No production gate change or assert bypass was made. The two candidate route
manifests were moved out of the active directory, recoverably, to
`/var/mobile/Media/macws-mps-candidates-20260913/`. Companion files are inert
without those manifests. No whole-IPSW extraction was needed.

### Late update: Metal accepted

The later root-cause work did not bypass Geekbench validation or fabricate a
score. It fixed two upstream compatibility boundaries:

1. Runtime command-buffer diagnostics correlated the first error getter to
   submit serial 678 and a complete 0x288-byte subtype-3 command record with
   resources `9/0x62`, mode 6 and the macOS-only zero window
   `[0x1d0,0x1e0)`. Enabling the already native-iOS-paired structured ABI
   translation removed all `00000103` errors. The production implementation
   admits the complete record only after the direct list, resource entry,
   range coverage, header, trailer, sentinel and mode invariants validate.
2. RE-confirmed in the exact Geekbench 6.7.1 worker (UUID
   `49124C96-2DB4-319D-B083-3B90C2074777`):
   `MetalImageBuffer::MetalImageBuffer` at image+`0x1a9618` and
   `MetalBuffer::MetalBuffer` at image+`0x1a8740` select
   `newBufferWithBytesNoCopy` when `hasUnifiedMemory` is true, while
   `MetalImageBuffer::read` at image+`0x1a9c48` deliberately skips readback
   for the original no-copy pointer. MacWS must redirect the macOS
   init-bytes resource request to an iOS-native allocation, so the original
   pointer is not an alias. The exact path-verified worker is now told the
   compatibility device requires explicit transfers and uses Geekbench's own
   managed/staging path.

The A/B run's unmodified numeric comparators passed all captured image and
particle outputs. The final production run then used only the standard
`MACWS_AGX_NATIVE=1`, `MACWS_AGX_REGISTER_CLASSES=1` and
`MACWS_PIN_FALLBACK=1` environment, with the A/B and diagnostic switches
absent. Verbatim terminal witness:

```text
Running Background Blur
Running Face Detection
Running Horizon Detection
Running Edge Detection
Running Gaussian Blur
Running Feature Matching
Running Stereo Matching
Running Particle Physics
Upload succeeded. Visit the following link and view your results online:
https://browser.geekbench.com/v6/compute/6880999
MACWS_GEEKBENCH_EXIT=0
```

[Metal result 6880999](https://browser.geekbench.com/v6/compute/6880999) is
32,094. A same-version Geekbench 6.7.1 result from the eight-GPU-core
[MacBook Air M1](https://browser.geekbench.com/v6/compute/6718146) is 33,899;
MacWS reaches 94.68% of that reference. The MacBook model summary currently
shows a Geekbench 7 Metal aggregate, which is not mixed into this Geekbench 6
comparison. The private result-claim URL remains outside Git.

### Stability correction and final acceptance

The first accepted run above was followed by an intermittent Face Detection
validation regression. It was not treated as stable acceptance. A bounded
command flight recorder then runtime-correlated the first real driver error:

```text
reason=iogpu-raw-callback-error pid=42191 command_buffer=0x11282cdc0 requested_serial=971 matched_serial=971 oldest=1 newest=971
serial=971 ... fixed=0 ... pre_commands=552 pre_segments=240 post_commands=552 post_segments=240
```

`misc/parse_agx_segment_list.py` independently decoded the retained buffers as
a complete direct one-segment list: KCMD `0x228`, list `0xf0`, exact range
`[0,0x228)`, thirteen resources in three groups. The command is subtype 3,
opcode 4, mode 2, resources `8/0x12`, with the already native-paired zero
window `[0x1d0,0x1e0)` and all-ones sentinel. Pre/post SHA-256 values were
identical because the dispatcher excluded every mode-2 topology except the
earlier `11/6` control. The immediately correlated runtime result was:

```text
MTLCommandBufferErrorDomain code=1
Internal Error (00000103:Internal Error)
```

The production fix removes that dispatcher exclusion while retaining opcode,
record framing, complete segment-list consumption, resource-group counts,
contiguous range coverage, mode bounds, zero-window and sentinel validation.
It only deletes the producer-version window and updates its owning span/range;
it does not modify command completion or Geekbench validation.

The first post-fix diagnostic run had zero command-error callbacks and passed
all unmodified validators. Face Detection's three output comparisons reported
zero mismatches, with maximum deltas `2.95639038e-05`, `3.57627869e-07` and
`2.70605087e-05` against the benchmark's `0.0001` tolerance. It uploaded
[Metal result 6881206](https://browser.geekbench.com/v6/compute/6881206),
31,906.

The diagnostic sentinels were then removed before two consecutive production
runs. Both used only `MACWS_AGX_NATIVE=1`, `MACWS_AGX_REGISTER_CLASSES=1` and
`MACWS_PIN_FALLBACK=1`, completed all eight workloads, exited zero and uploaded:

- [Metal result 6881213](https://browser.geekbench.com/v6/compute/6881213):
  30,824, or 90.93% of the same-version 33,899 M1 Air reference.
- [Metal result 6881217](https://browser.geekbench.com/v6/compute/6881217):
  31,994, or 94.38% of the reference.

No reboot, respring, benchmark binary change, validation bypass or result
substitution was used. Private result-claim credentials and binary captures
remain outside Git.

## Handoff

Final local regression: 176 tests passed in 6.952 seconds. The runtime-switch
audit passed with 248 environment names, 59 flag files and 378 recorded
entries; all modified shell scripts passed `bash -n`, and `git diff --check`
was clean. Standalone diagnostics are not aggregate-build targets. No debugger,
log-stream process or benchmark worker remained active.

Open-In, streaming-copy tests, Launchpad paging, command latency, CPU and Metal
measurement have witnesses. Physical Finder drop and broader failing-app
Quit/Dock coverage remain outside this record. Never push an undifferentiated
`tmp/`/download payload as code.
