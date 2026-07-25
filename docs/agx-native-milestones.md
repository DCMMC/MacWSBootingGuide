# AGX-native GUI milestones

This file is the durable hand-off log for the native-AGX path. It deliberately
separates runtime evidence, reverse-engineering evidence, and theories. A
process that merely remains alive is not a success witness; the final witness
is a VNC capture of GlassDemo with non-black content and a visibly rendered
`NSVisualEffectView` blur.

## Target

- Device: iPad13,6, iOS 16.3.1 (20D67), arm64.
- Guest: macOS 13.4 chroot.
- Driver path: the real iOS AGX kernel driver (`MACWS_AGX_NATIVE=1`), not the
  MTLSim fallback.
- Final witness: GlassDemo title bar, controls, and backdrop blur visible in a
  captured VNC frame.

## 2026-07-24: native open options and bounded queue A/B

### Runtime-confirmed: the native reference uses option `0x10`

The project LLDB trace attached to the early-held iOS-native `iosclear_ref`
and recorded the actual iPad13,6 values before the first render submit:

```text
IOSCLEAR_IOGPU DEVICE-INIT accelerator-port=0x2503 options=0x10
IOSCLEAR_IOGPU API-CREATE accelerator-port=0x2503 options=0x10 expected-open-type=0x100001 api=b'Metal'
IOSCLEAR_IOGPU AGX-OPEN service=0x2503 task=0x203 type=0x100001 connect-out=0x16d046bbc
IOSCLEAR_IOGPU API-PROPERTY sel=0x6 len=0x10 bytes=4d 65 74 61 6c 00 00 00 00 00 00 00 00 00 00 00
IOSCLEAR_IOGPU QUEUE-FUNCTION device=0xe3a8058b0 qos=0x2 priority=0x0
IOSCLEAR_IOGPU QUEUE #1 sel=0x7 len=0x408 qos=0x2 priority=0x0 nonzero-bytes=199
```

Runtime artifact: `/tmp/lldb-iosclear-headless-fallback.log` on the
development Mac. The trace also captured 33 successful resource-create
entries before selector `0x1a`: 22 type-0 resources, 10 type-`0x80`
resources, and one type-`0x82` resource. It stopped at the first submit and
saved a `0x820`-byte native subtype-1 command.

Command Line Tools LLDB had no local dyld shared-cache symbols and a full
remote module load did not finish in four minutes. The trace runner now uses
`target.memory-module-load-level=partial` and exact iOS 20D67 unslid function
addresses as a fallback. The shared-cache slide is derived at runtime from
the loaded IOKit image; symbol-name breakpoints remain preferred when they
resolve. This is debugger instrumentation only.

### Runtime-confirmed: open options change device state, not queue creation

`misc/agx_iogpu_probe.c` was run in a bounded `queue` mode. It performs one
API-property call, one selector-`0x7` queue create using the native
QoS/priority values, and one device-info query; it skips all resource-shape
fuzzing. Exact A/B results:

```text
type=1:
  UC+0x128 options= 0
  Device/AGXShared+0xd8 options = 0
  sel=0x7 (queue-create) -> kr=0x0 (SUCCESS)
  AGXCommandQueue ... +0x80c=0 +0x820=80 priority=3 qos=2

type=0x100001:
  UC+0x128 options= 0x10
  Device/AGXShared+0xd8 options = 0x10
  sel=0x7 (queue-create) -> kr=0x0 (SUCCESS)
  AGXCommandQueue ... +0x80c=0 +0x820=80 priority=3 qos=2
```

Runtime artifact: `/tmp/agx-probe-queue-options-ab-v2.log`. Both runs used
the same IOGPU singleton and reported all 16 IOGPUTask allocator slots as
zero. The direct selector-`0x6` call returned `1` in both runs; because the
native user-space function does not branch on that return before continuing,
this probe result is not evidence of a missing prerequisite.

This disproves the historical generalization that type 1 necessarily creates
a degraded user client which cannot create a queue. It also proves that
clearing the high word discards real native device state. It does **not**
prove that preserving option `0x10` will fix first submit: the created queue
fields are identical in this bounded comparison.

Production `IOServiceOpen_new` now removes only macOS low-word platform bit 4,
converting the macOS builder's `0x100005` to the native `0x100001`. The old
high-word removal remains available only as the diagnostic
`MACWS_AGX_STRIP_OPEN_OPTIONS`; `MACWS_AGX_FORCE_TYPE` remains an explicit A/B
override. This is an upstream ABI correction, not a claim that GUI rendering
is fixed.

## 2026-07-24: first render reaches the kernel, then returns raw `0x08`

### Runtime-confirmed

After applying the current **temporary diagnostic KCMD normalization**, the
clear-only control command reaches AGX submission and completes with raw error
`0x08`. The framebuffer remains black:

```text
#### AGX_SUBMIT_DIAG #2 TEMP-KCMD-ABI-FIX subtype1-clear pads=0x1c0,0x4c0 total=0x840->0x820 size=0x7e8->0x7c8 end=0x818->0x7f8 segment-span=0x840->0x820
#### VNC-FINAL pass MACWS VNC clear-only control error: Error Domain=MTLCommandBufferErrorDomain Code=8 "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"
#### VNC-FINAL clear-control executed=NO pixel=FAIL center=00000000
```

Source artifact: `/tmp/WindowServer-segment-span-fix.err` on the development
Mac. The byte deletion and span rewrite are diagnostic scaffolding, not a fix:
their purpose is to make the next kernel failure observable. They have not been
shown to preserve every semantic field in a general command buffer.

The previous two transitions are useful boundary evidence:

1. The unmodified macOS subtype-1 buffer failed before the synchronization
   stage.
2. Removing two 16-byte zero pads moved the failure past synchronization but
   produced raw `0x0a`.
3. Correcting the segment-list KCMD span from `0x840` to `0x820` moved the
   result to raw `0x08`.

The latest failed frame loop also grew the live allocation tracker from roughly
98 objects / 13.4 GB to 1704 objects / 45.1 GB. `Metal_hooks.x` therefore has a
file-gated `SIGSTOP` circuit breaker (`/tmp/macws_stop_after_clear`). It is a
diagnostic safety mechanism, not a stability fix.

### RE-confirmed: raw `0x08` can precede substantive KCMD consumption

Actual binary: iOS 16.3 `com.apple.AGXG13G`, version 227.2.43, extracted from
the iPad13,6 kernelcache. Development artifact:
`/tmp/ipad13_6-kexts/com.apple.AGXG13G`.

In `AGXCommandQueue::processRender` at `0xfffffe00086e434c`, the function loads
one command field from `[x3+0x28]`, checks the queue's work-queue count at
`[x19+0x80c]`, and, when it is zero, calls
`allocate3DWorkQueue(false)` at `0xfffffe00086e43a8`. A false return branches
directly to the common raw-8 exit at `0xfffffe00086e4adc`, which stores 8 into
`[x19+0x520]` at `0xfffffe00086e4ae4`.

This path is reached before the function consumes substantive fields from the
submitted KCMD. Therefore the remaining 35 differing bytes between the native
iOS and normalized macOS subtype-1 captures are not yet evidence of the raw-8
cause. This narrows the next investigation to queue/device work-queue setup;
it does **not** identify which setup substep failed.

Other RE-confirmed branches that converge on the same early raw-8 exit are:

- `allocTAChannel` call at `0xfffffe00086e4a94` returning false.
- `allocParameterManagement` call at `0xfffffe00086e4ab4` returning false.
- A later render-target-memory failure logs through the string at
  `0xfffffe000701e23d` and reaches raw 8 through
  `0xfffffe00086e52c8..0xfffffe00086e52d0`.

Disassembly artifacts:

- `/tmp/agx-processRender-full.disasm`
- `/tmp/agx-allocate3DWorkQueue.disasm`
- `/tmp/agx-allocTA-PM.disasm`
- `/tmp/agx-PM-init.disasm`
- `/tmp/agx-PMConfig-init.disasm`

### RE-confirmed: `allocate3DWorkQueue` failure stages have distinct logs

Actual function: `0xfffffe00086e1a2c` in the same iOS 16.3 AGX kext.

- The work-queue virtual initializer is called at `0xfffffe00086e1acc`; false
  reaches the string at `0xfffffe000701e0e3`, `Failed to init work queue`.
- The non-FRG path calls `allocTAChannel` at `0xfffffe00086e1bd4`.
- Render-target-memory creation is called at `0xfffffe00086e1c40`; null or
  failed initialization reaches `Failed to create Render Target Memory` at
  string address `0xfffffe000701e23d`.
- Parameter management is allocated at `0xfffffe00086e1c94`.
- Work-queue initialization receives values derived from queue/device fields,
  including `[queue+0x530]`, `[queue+0x820]`, and `[queue+0x80c]`.

Consequently, the next required runtime evidence is the matching kernel log
line. Until that log is captured, statements such as “GTP creation failed” or
“parameter-management allocation failed” are THEORY only.

### RE-confirmed: the 0x408-byte queue payload layout

Actual binary: iOS 16.3 `com.apple.iokit.IOGPUFamily`, development artifact
`/tmp/ipad13_6-iogpu-kext/com.apple.iokit.IOGPUFamily`.

`IOGPUCommandQueue` initialization at `0xfffffe0009f0c798`:

- reads QoS from payload `+0x400` and rejects values greater than 4;
- copies the first `0x400` bytes as the queue name/process path;
- reads byte `+0x404` and stores its boolean form at queue `+0x439`;
- stores QoS at queue `+0x450`;
- initializes queue `+0x44c` to 3.

The leading path is copied but is not inspected by this initializer. The
production translator therefore preserves the caller's payload. A zero-filled
replacement remains available only through the diagnostic
`MACWS_AGX_ZERO_QUEUE_ARGS` A/B switch. This removes an RE-disproved
translation; it does not establish that queue creation or first submit is
fixed, and the native caller's runtime values still need to be captured.

Disassembly artifact: `/tmp/iogpufamily-text.disasm`.

### RE-confirmed: native and macOS user-space queue builders share the layout

The following actual functions both zero `0x408` bytes, write a process path
into the first `0x400`, QoS at `+0x400`, and priority/boolean data at `+0x404`:

- iOS 16.3 IOGPU: `_IOGPUCommandQueueCreateWithQoS` at `0x1eec62a00`.
- macOS 13.4 IOGPU: `_IOGPUCommandQueueCreateWithQoS` at `0x19d1558b8`.

This disproves the earlier idea that iOS and macOS use wholly different queue
argument structures. It does not prove the values selected by the two callers
are the same.

### RE-confirmed: device-create options reach IOGPUTask initialization

The actual iOS 16.3 user-space builder
`_IOGPUDeviceCreateWithAPIProperty` at `0x1eec63a18` constructs the
`IOServiceOpen` type as `1 | ((options & 0xffff) << 16)`. The macOS 13.4
builder at `0x19d1540fc` uses the same high-word encoding but a low word of 5.

The iOS 16.3 kernel path preserves that high word:

1. `IOGPU::newUserClient` at `0xfffffe0009f0a390` accepts low type 1 or
   `0x21`, extracts `type >> 16` at `0xfffffe0009f0a420`, and passes it to
   `IOGPUDeviceUserClient::init` at `0xfffffe0009f0a458`.
2. `IOGPUDeviceUserClient::init` at `0xfffffe0009eeac54` stores the value at
   user-client `+0x128` (`0xfffffe0009eeacc0`).
3. `deviceUserClientStart` at `0xfffffe0009eeced4` reloads it at
   `0xfffffe0009eecf88` and passes it to the IOGPU device factory at
   `0xfffffe0009eecfb4`.
4. `IOGPU::createDevice` at `0xfffffe0009f0aaa4` passes the value as the
   fourth argument to the new device's virtual initializer at
   `0xfffffe0009f0ab28`.
5. `AGXShared::init` at `0xfffffe000873e594` saves that value at AGXShared
   `+0xd8` (`0xfffffe000873e5d8`).
6. `AGXShared::createUserGPUTask` at `0xfffffe000873d668` reloads `+0xd8`
   and passes it as the fourth argument to the task initializer at
   `0xfffffe000873d6e0..0xfffffe000873d6ec`.
7. The target implementation, `IOGPUTask::init` at
   `0xfffffe0009f074c0`, treats that argument as a range-allocator count. If
   nonzero, it walks the allocator-pointer array in its fifth argument and
   retains each non-null allocator (`0xfffffe0009f07524..0xfffffe0009f075a4`).

Thus the options field is not an inert credential or entitlement flag: it
participates in GPU task address-space setup. Kernel symbols strengthen the
type attribution:

```text
fffffe000873d668 AGXShared::createUserGPUTask(task*)
fffffe0009f074c0 IOGPUTask::init(IOGPU*, task*, unsigned int,
                                 IORangeAllocator**)
```

The earlier inference that the count “should therefore be zero” is
runtime-disproved. Native LLDB captured option `0x10`, and the KRW probe read
that same value from both UC `+0x128` and Device/AGXShared `+0xd8`; all 16
IOGPUTask allocator slots were nevertheless zero. The exact relation between
this option/count and the null allocator array still needs RE. What is already
established is narrower: zero allocator slots are not evidence that the
native option must be zero, and clearing it is not a valid production
translation.

Disassembly artifacts: `/tmp/ios-iogpu.disasm`,
`/tmp/macos-iogpu.disasm`, `/tmp/iogpufamily-text.disasm`, and
`/tmp/agxg13g-text.disasm`.

### RE-confirmed correction: iOS AGX computes the options value

iOS 16.3 `AGXMetal13_3` function
`-[AGXG13GFamilyDevice initWithAcceleratorPort:simultaneousInstances:]` starts
at `0x20ccc1de4`. At `0x20ccc1e40..0x20ccc1e68` it loads a 16-bit value from
`0x214430030` in `__DATA,__bss` and passes it to the superclass initializer
`-[IOGPUMetalDevice initWithAcceleratorPort:options:]`. The
`simultaneousInstances` argument is saved separately.

The earlier static search that found no writer was incomplete. Immediately
before the read, this initializer checks a `dispatch_once` token at
`0x214430038`. Its block literal at `0x2178b1aa0` invokes
`0x20ccc52f0`, which combines hardware/configuration bits and stores the
resulting halfword to `0x214430030` at `0x20ccc53dc`.

Therefore zero-initialized BSS is not evidence that native uses options zero.
Runtime LLDB has now resolved the value as `0x10` on this iPad13,6; the former
production high-word mask was an actual divergence from the native ABI.

The new field-dump portion of `misc/agx_iogpu_probe.c` uses only KRW reads for
UC `+0x128`, AGXShared `+0xd8`, IOGPUDevice `+0x58`, and the 16 fixed
IOGPUTask allocator slots at `+0x138`. The probe now defaults to that bounded
field-only mode and no longer tries open types 0 and 2, both of which
previously hung on this device. A non-default type or the existing
resource/queue call suite must be requested explicitly (`exercise`).

In explicit `exercise` mode, a successful selector-`0x7` queue creation is
also resolved through the command-queue `IOGPUNamespace`. RE-confirmed via
`IOGPUDevice::retainCommandQueue(unsigned int)` at
`0xfffffe0009f02f50`: device `+0x88` is the namespace passed to
`IOGPUNamespace::retainObject`, whose implementation at
`0xfffffe0009eea1d0` indexes the pointer array at namespace `+0x10` after
checking the capacity at `+0x28`. The probe can therefore read the actual
kernel queue's accelerator pointer, `+0x80c`, `+0x820`, priority/QoS, and the
accelerator configuration fields `+0x1870/+0x56c`. This is diagnostic
instrumentation; no queue field is changed.

### RE-confirmed: the first work-queue initializer has only narrow failures

The first `allocate3DWorkQueue(false)` call passes AGX queue fields
`[queue+0x530]`, `[queue+0x820]`, and `[queue+0x80c]` into the work-queue
initializer. The subclass chain is:

- `AGX3DWorkQueue::init` at `0xfffffe00087499d0`;
- `AGXWorkQueue::init` at `0xfffffe000874934c`;
- `IOGPUWorkQueue::init` at `0xfffffe0009efa63c`.

The base initializer returns false only when its OSObject superclass init
fails, the command-queue pointer is null, or allocation of `count * 8` bytes
fails (`0xfffffe0009efa674..0xfffffe0009efa6ac`). It then stores the queue,
creates a recursive lock, and allocates a stamp index; this tail has no false
branch before the function returns true at `0xfffffe0009efa6f0`.

`AGXCommandQueue::init` at `0xfffffe00086defc4` sources the count stored at
queue `+0x820` from the device/config field `+0x1870`, falling back to `+0x56c`
when zero (`0xfffffe00086df018..0xfffffe00086df028`). It immediately performs
larger allocations proportional to that count and only completes queue
construction if they succeed. This makes a malformed count less likely, but
does not rule it out. A fresh, bounded run is required because the previous
failed frame loop accumulated tens of gigabytes of live resource accounting;
raw 8 from a small allocation after that loop could be secondary memory
pressure rather than the original defect. That is THEORY until the kernel log
from a clean run identifies the failing stage.

Disassembly artifacts: `/tmp/agx-allocate3DWorkQueue.disasm`,
`/tmp/agxg13g-text.disasm`, and `/tmp/iogpufamily-text.disasm`.

## Native trace completed

`misc/iosclear_ref.m` now supports an early hold before
`MTLCreateSystemDefaultDevice`, armed by `IOSCLEAR_EARLY_HOLD` or the sentinel
`/var/mobile/iosclear_early_hold`.

`misc/lldb_trace_iosclear_iogpu.py` installs read-only LLDB callbacks for:

- `IOServiceOpen` and its return status;
- `-[IOGPUMetalDevice initWithAcceleratorPort:options:]`;
- `IOGPUDeviceCreateWithAPIProperty` and its returned device pointer;
- `IOGPUCommandQueueCreateWithQoS` and its returned queue pointer;
- `IOConnectCallStructMethod` selector 6 (`"Metal"` API property);
- `IOConnectCallMethod` queue creation, resource creation, and the first
  selector-`0x1a` submit.

It saves bounded native queue/resource/KCMD payloads under
`/tmp/iosclear-native-iogpu` and stops at the first render submit.
`misc/lldb_trace_iosclear_iogpu.lldb` drives the trace and emits a summary.
The completed run recorded 51 IOGPU calls, one queue, 33 resources, and the
first selector-`0x1a` submit. Entry arguments and copied payloads are reliable;
the current per-call return-breakpoint implementation can collide when several
calls share one return address, so pointer-shaped `RETURN status=` lines are
not used as evidence.

## Native/macOS subtype-1 comparison

The exact 2388x1668 native clear capture is `0x820` bytes total; its AGX
subtype-1 command has size `0x7c8` and ends at `0x7f8`. After the temporary
normalization, 2005 of the first 2040 bytes match the native capture (98.28%).
The 35 differing bytes occur in 13 ranges, mostly addresses and resource IDs;
offset `+0x610` remains opaque. Similarity is evidence that the framing is
closer, not proof of semantic validity.

Artifacts on the development Mac:

- `/tmp/iosclear-native-kcmd.bin`
- `/tmp/macws-type1-latest.bin`
- `/tmp/macws-type1-normalized-reconstructed.bin`
- `/tmp/iosclear-native-segment-list.bin`
- `/tmp/macws-segment-list-spanfix.bin`

## 2026-07-24: isolated blit fault and pinned-VA control

### Runtime-confirmed: the page fault reproduces without WindowServer

The arm64 macOS `agxprobe` was run inside the chroot from a clean GUI state.
Stages 1 through 3 created an Apple M1 device, a 4096-byte shared buffer, and a
command queue. Stage 4 submitted only one blit fill. With the current
**temporary diagnostic** subtype-3 KCMD normalization enabled, the parser
accepted the command and the GPU reported a BIF0 page fault:

```text
#### AGX_SUBMIT_DIAG #1 TEMP-KCMD-ABI-FIX subtype=3 size 0x1b8->0x1a8 end 0x1e8->0x1d8 total 0x210->0x200
AGXPROBE [4d] status=5 error=Caused GPU Address Fault (0000000b:kIOGPUCommandBufferCallbackErrorPageFault)
AGXPROBE [4e] readback[0]=0x00 [4095]=0x00 (expect 0xab if GPU ran)
```

The matching GPU report contains:

```text
"restart_reason":3
"bif0_fault":{"is_read":true,"sideband":68,"level":1,
              "requestor":1,"address":74491363328}
"guilty_dm":3
"signature":563
```

`74491363328` is `0x1158080000`. Without the diagnostic normalization, the
same test returned `Internal Error (00000103)` and emitted no GPU event. This
establishes that the 16-byte deletion advances the iOS parser far enough to
execute hardware, but it remains a scaffold: deleting bytes has not been
proved semantically correct.

Artifacts and SHA-256:

- `/tmp/macws-agxprobe-isolated-d04a3e8/arm64-stage4.log` —
  `4e02be0d148162cbe9e32b8dde230441c76389eb2c38ac4ea69cfa4a045b7a9f`
- `/tmp/macws-agxprobe-isolated-d04a3e8/gpuEvent-agxprobe_arm64-2026-07-24-065502.ips` —
  `2f60db455f7cf5adaf9b334f790aa13abc92e2e97fff18b9a8b558e69ee46578`
- `/tmp/macws-agxprobe-isolated-d04a3e8/macws_submit_kcmd_1_0_pre.bin` —
  `5851f14a47539378d6955afa3fe731385bcf1269b6862b1b4673e2d9cdd24fbc`

This moves the first failing invariant below SkyLight and the compositor: a
generic chroot Metal blit has the same failure class.

### Runtime-confirmed: iOS can map and execute at the exact fault VA

The iOS-native `PinnedVAProbe` requested `0x1158080000` and then exercised the
mapping with compute and blit operations in both directions. The exact run
reported:

```text
requested=0x1158080000 reported=0x1158080000 match=YES
PINPROBE stage2 cb.status = 4
PINPROBE stage2 result: [0]=0xdeadbeef [1]=0xcafebabe
PINPROBE stage2c blit status=4 sink[0]=0xdeadbeef sink[1]=0xcafebabe
PINPROBE stage2d status=4 roundtrip[0]=0xfeedface roundtrip[1]=0xbaddcafe
PINPROBE stage2b CONTROL OK: shader ran correctly on plain buffer
PINPROBE FINAL: PINNED VA HAS A REAL GPU PAGE TABLE ENTRY
```

There was no GPU fault report. Artifact:
`/tmp/macws-agxprobe-isolated-d04a3e8/pinnedva-1158080000.log`, SHA-256
`d02715bb83d44eb997ef266671e99f620d6e4e2880666f64c3ee57c1263eae47`.
This runtime-disproves the historical conclusion that
`pinnedGPULocation:` is merely symbolic on this device.

The project LLDB tracer then captured the exact native selector-`0x9`
resource request. `res-001.bin` has SHA-256
`62c6918d1f405bcef6d95e82cbd7dbe52ef34c98b4b2676ddc1fe49723ec2dbf`
and these relevant fields:

```text
+0x00 type=0
+0x10 0x0000047001000101
+0x20 0x0000001158080000    requested GPU VA
+0x28 0x0000000000004000    allocation span
+0x40 0x0000000000004000
```

Its first native compute KCMD is exactly `0x200` bytes, contains a subtype-3
record with `size=0x1a8` and `end=0x1d8`, and references
`0x1158080000` at KCMD `+0x1e8`. Artifact
`/tmp/pintrace-1158080000-held-20260724/pinned-native-kcmd.bin`, SHA-256
`d0c5d2898b40fb9b59c8fc6b352ec0996c92279c576c23e8ca1ee64c8f642906`.

The narrow evidence-backed conclusion is that iOS's resource ABI places an
explicit pinned VA at request `+0x20`, and the resulting native command uses
that same VA successfully. In the isolated chroot probe, the translated
type-0 resource requests observed so far had zero at `+0x20/+0x28`, while its
KCMD contained GPU-address-looking values. **THEORY:** macOS user space and
the iOS kernel are assigning different GPU VAs. The next experiment must
correlate the chroot buffer's `gpuAddress`, the unmodified resource request,
the translated request, and the resource-create output before this theory can
be promoted to fact.

### Runtime-confirmed: strip PAC before arithmetic on `dlsym` results

An arm64e diagnostic host crashed in `loadImageCallback` while reading
`objc_msgSendSuper2 + 0x10`. The crash register was a PAC-signed function
pointer (`x0=0x132400019280de00`), and the installed instruction sequence
performed a raw `add x8, x8, #0x10` followed by `ldr w8, [x8]`. The hook now
uses `ptrauth_strip(..., ptrauth_key_function_pointer)` before instruction
address arithmetic. The rebuilt runtime logged:

```text
MACWS_AGX_OBJC_AUTDA_PATCH msgSendSuper2=0xdc5e80018a721e00
code=0x18a721e00 autda@0x18a721e10 insn=0xdac11a30
```

This fixes the hook's own pointer invariant; it is not a GPU fix and does not
change the status of the arm64e host's separate constant-NSString ABI crash.

### Runtime-confirmed: resource tail ABI translation fixes the native AGX page fault

The earlier pinned-VA theory was incomplete.  RE of the actual wrappers shows
that the kernel resource-create output at `+0x00` is the GPU address:

- iOS 16.3 `_IOGPUResourceCreate` at `0x1eec60040` copies kernel output
  `+0x00` into `IOGPUResource+0x38`; `IOGPUResourceGetGPUVirtualAddress` at
  `0x1eec652a4` returns that field, and `-[IOGPUMetalResource gpuAddress]` at
  `0x1eec6f110` returns the value subsequently stored in its `+0x48` ivar.
- macOS 13.4 has the same output flow in `_IOGPUResourceCreate` at
  `0x19d1560a0` and `-[IOGPUMetalResource gpuAddress]` at `0x19d15068c`.
- RE-confirmed in the iOS kernel at
  `IOGPUDevice::new_resource+0x610` (`0xfffffe0009f0415c`): a no-parent
  type-0 allocation reads its byte count from request `+0x40` before calling
  the resource allocator at `0xfffffe0009f04180`.

The project LLDB return tracer then captured complete 104-byte native iOS
requests.  Matching internal allocations differ from the macOS 13.4 request
by a tail-field shift:

```text
                       +0x40      +0x48      +0x50       +0x58
macOS f14=0x8430       0          0x8000     0           0x48000000
iOS   f14=0x8430       0x8000     0          0x48000000  0
```

The native calls returned `0x18000`, `0x28000`, and `0x1100038000` for the
three `f14=0x8430` resources.  With only the size translated and `+0x50`
left zero, the chroot instead received ordinary addresses such as
`0x15000b8000`; its GPU fault was exactly `0x11000b8000`, the same value with
bit 34 clear.  The matching report is
`/tmp/gpuEvent-agxprobe_arm64-2026-07-24-104713.ips`, SHA-256
`9fa98c5d9a74d49e80821efcd7abc973151bb03b3061862e6385a102e9f175e8`.

The translator now performs the upstream request conversion for no-parent
type-0 resources:

```text
iOS +0x40 = macOS allocation span from +0x48
iOS +0x48 = 0
iOS +0x50 = low 32 bits of macOS +0x58 (the address arena)
iOS +0x58 = 0
```

This is not a returned-address rewrite or a nil/zero-object scaffold.  The
iOS kernel now allocates the resource in the address arena requested by the
macOS AGX userland.  Runtime-confirmed after rebuilding:

```text
f14=0x8430 SENT +40=0x8000 +48=0 +50=0x48000000 +58=0
f14=0x8430 RETURN +00=0x18000
f14=0x8430 RETURN +00=0x28000
f14=0x8430 SENT +40=0x8000 +48=0 +50=0x28000000 +58=0
f14=0x8430 RETURN +00=0x1100038000
AGXPROBE [4d] status=4 error=none
AGXPROBE [4e] readback[0]=0xab [4095]=0xab
```

Artifact `/tmp/agxprobe-arena-shift-stage4-real.log`, SHA-256
`b9202c91ce0efea36eb1de18a43fcd4cb19bf55ffbc1b36401f7e4ce3b9213e9`.
The full native request trace is
`/tmp/lldb-pin-native-fulltype0.log`, SHA-256
`710330858d59b48426c5850d4bfdbe68266c9fef67272b92eb55ec4117f75b5a`.
No new GPU event was emitted by the successful run.

This closes the isolated BIF0 page-fault blocker.  The stage-4 submission
still uses the explicitly labelled `TEMP-KCMD-ABI-FIX` to normalize the
macOS subtype-3 command record from `0x210` to the native iOS `0x200` shape;
that remaining diagnostic scaffold must be replaced by a semantic command
ABI translation before the native path can be called production-ready.

### Runtime-confirmed: native render pass writes the expected IOSurface pixel

The first isolated stage-5 run, with the resource-tail fix but without the
subtype-1 diagnostic normalization, created a real IOSurface-backed texture
and render encoder but ended with:

```text
AGX_SUBMIT_DIAG #2 scalars[4]: 0x1 0 0x1 0x38 fix-requested=YES
AGX_SUBMIT_DIAG #2 record[0] off=0 type=0x10000 end=0x818 size=0x7e8 inner=0x30 subtype=1
AGX_SUBMIT_DIAG #2 result=0 records=1 candidates=0 fixed=0
AGXPROBE [5d] render status=5 error=Internal Error (00000102:Internal Error)
AGXPROBE [5e] pixel[0] BGRA = 00 00 00 00
```

Artifact `/tmp/agxprobe-arena-shift-stage5.log`, SHA-256
`2bf6c4481bf646bd674daf08223ca6d5b5ea4f80c3ba3ac2e8bbc731d203c9b1`.
The record has the same complete `0x840 / 0x818 / 0x7e8` macOS subtype-1
layout and structural anchors as the earlier VNC clear control, but its
submit scalar `[0]` is `1` rather than `3`.  The diagnostic gate was expanded
only to accept scalar `[0]` in `{1,3}`; all framing fields, both zero-pad
windows, and every stable surrounding-byte anchor remain mandatory.  This is
an A/B experiment, not evidence that scalar values 1 and 3 are semantically
equivalent.

After rebuilding, the same stage-5 probe completed on the real iOS AGX
driver and wrote the exact clear color into the IOSurface:

```text
AGX_SUBMIT_DIAG #2 record[0] off=0 type=0x10000 end=0x818 size=0x7e8 inner=0x30 subtype=1
AGX_SUBMIT_DIAG #2 TEMP-KCMD-ABI-FIX subtype1-clear pads=0x1c0,0x4c0 total=0x840->0x820 size=0x7e8->0x7c8 end=0x818->0x7f8 segment-span=0x840->0x820
AGX_SUBMIT_DIAG #2 result=0 records=1 candidates=1 fixed=1
AGXIOC Method sel=0x1e->0x1a inCnt=4 inSC=56 outSC=0 -> 0x0
AGXPROBE [5d] render status=4 error=none
AGXPROBE [5e] pixel[0] BGRA = 00 00 ff ff (expect red: 00 00 ff ff)
AGXPROBE OK — IOSurface RENDER PATH WORKS (content rendering is fine!)
```

Artifact `/tmp/agxprobe-stage5-subtype1-ab.log`, SHA-256
`e2562b6c0b0ff1372a9873dd73dae1b64a6ce2b9f74a104da50e9668a896216e`.
The normalized `0x820` KCMD is
`/tmp/agxprobe-stage5-kcmd-post.bin`, SHA-256
`fa0a44db42a8381fd230d370420d7d75b9dd0947e5535ae454df0a4387226b31`.
At device time 11:18, the latest GPU event remained the older 10:59 report;
this successful run emitted no new GPU fault.

The narrow conclusion is that a macOS process in the chroot can now create an
IOSurface-backed AGX texture, submit a native render pass through the iOS AGX
kernel driver, wait for completion, and observe the GPU-written pixel from
the CPU.  This does not yet prove WindowServer compositing, tile pipelines,
or blur, and the subtype-1 plus subtype-3 byte-deletion normalizers remain
explicitly diagnostic scaffolds.

### Runtime-confirmed: WindowServer high-resolution clear passes; textured draw reaches GPU recovery

The same subtype-1 diagnostic normalizer was then exercised by WindowServer
against its real 2388x1668 BGRA8 IOSurface.  The final clear-control command
used submit scalar `[0] = 4`; all subtype-1 structural anchors matched and the
normalizer converted its record from `0x840` to `0x820`.  The native AGX GPU
wrote the expected center pixel:

```text
#520 scalar0=0x4 ...
TEMP-KCMD-ABI-FIX subtype1-clear pads=0x1c0,0x4c0 total=0x840->0x820
VNC-FINAL clear-control executed=YES pixel=OK center=804020ff
```

Runtime artifact `/tmp/windowserver-native-clear-pass-20260724.log`, SHA-256
`35b8de4e02fd6307080d331b2563d150353cbbdee40ca02411c4a3fd67db6161`.
This disproves the earlier diagnostic gate's assumption that only scalar
values 1 and 3 can carry this record shape.  The scalar is outside the record
being transformed, so it was removed from the gate; the complete record,
segment, zero-pad, and sentinel predicates remain mandatory.

WindowServer's shader draw has the same framing but preserves operation state
`0x100` at record offset `+0x4d4`, whereas the clear control carries `0x300`.
Accepting those two observed states allowed both draw records to reach the
kernel parser.  The clear still completed, but the subsequent draw command
buffer was discarded during GPU recovery:

```text
#510/#513 clear normalized, clear-control pixel OK center=804020ff
#515/#516 shader draw records normalized
VNC-FINAL pass MACWS VNC BGRA8 shader control error:
Discarded (victim of GPU error/recovery) (00000005 InnocentVictim)
encoder state=2
VNC-FINAL control clear=OK texture=... draw=FAIL pixel=UNREAD
```

Runtime artifact `/tmp/windowserver-native-draw-fault-20260724.log`, SHA-256
`6e0c9e07307962fed3c558401551bab8b2bb978575f1424a99ea41672bac2c87`.
No new `.ips` was emitted for that run.  The reports still on disk had older
13:45 timestamps, so none is attributed to this command.  On 2026-07-24 the
device's 51 project-related `gpuEvent`, WindowServer, agxprobe, and GlassDemo
reports were cleared after archiving the 46 WindowServer/GPU reports locally
at `/tmp/macws-device-crash-archive-20260724-1400`; this resets the report set
for a one-run/one-fault correlation.

The next evidence target is an iOS-native textured-draw reference captured at
the same IOGPU submit boundary with the project's LLDB tooling.  Its resource
requests, subtype-1 record, and referenced GPU addresses will be compared
field-by-field with the chroot draw before any further translator change.

### Runtime-confirmed: pf550 descriptor divergence is owned by the compression gate

The project LLDB tooling captured the same 2388x1668 private pixel-format-550
IOSurface texture in an iOS-native reference and in chroot WindowServer.  Mesa
Asahi's generated texture XML provides the independent field map for the
24-byte hardware descriptor: layout is bits 4..5, address is bits 66..101
shifted by four, compressed is bit 103, extended is bit 127, and the low 36
bits of the final word encode the acceleration/metadata address shifted by
four.

The native iOS texture finished initialization with:

```text
descriptor offset in native impl = +0x180
layout=3 compressed=1 extended=1
address=0x1500068000
accelerationLow36=0x1501009800
acceleration = address + 0xfa1800 (the IOSurface pixel-plane span)
bytes=32b30a36950c1a0000a00140854025808009105051090000
```

Runtime artifact `/tmp/lldb-native-pf550-texture.log`, SHA-256
`1740e33be288d0ccd729f59d765a11dd9122ff0d5899af4973ecc2ac4f51372f`.
The raw native object/implementation dumps have SHA-256
`db5cda5aca5fec8c426cd25909c0d435c8c8644440fdfea88ea84671479d9527`
and `9abb3d1020f5a3bce1f8a61855d7bf5874a1ae557aa6727d5669c7d53b227994`.

The corresponding chroot texture finished initialization with a different
private-object layout and, more importantly, different descriptor semantics:

```text
descriptor offset in macOS impl = +0x190
layout=0 compressed=0 extended=1
address=0x1500070000
accelerationLow36=0x1500053e00
bytes=02b30a36950c1a0000c0014005c05fa8e0530050f1850100
```

The previous GPU fault at `0x150006c500` is below the primary base by
`0x3b00`; the malformed acceleration address is below that same base by
`0x1c200`.  This numerical relationship explains why the descriptor is the
immediate read-fault boundary, but it does not by itself identify the owner.

The upstream owner was then observed at the actual five-argument macOS AGX
method, static `0x1e57716b4`.  At entry for this exact texture, its 24-byte
hardware descriptor was still zero and LLDB recorded:

```text
PF550-UPDATEBIND SEEN count=1 texture=0x146f49430 impl=0x146f49640
candidate=1x1 layout=0 compressed=0 extended=0
gpuVA(x4)=0x1500070000 isCompressible(x5)=0
raw=000000000000000000000000000000000000000000000000
```

After the method returned, the same texture/impl pair was logged with the
`layout=0 compressed=0` descriptor above.  This is runtime-confirmed evidence
that `texBaseAddressesUpdated` is consuming an explicit
`isCompressible=0`; directly rewriting the completed descriptor would only
mask the broken upstream invariant.

RE-confirmed in the actual macOS 13.4 AGX image: the three-argument wrapper at
static `0x1e5770c1c` computes the five-argument call.  It loads an internal
device pointer, tests `internal+0x1d8`, then tests `*(internal+0x1d8)+0x418`.
Either zero branch supplies `metadataAddress=0` and `isCompressible=0`; only
the nonzero path computes a metadata address and sets `isCompressible=1`
before dispatching the five-argument selector.

The exact iPad13,6 iOS 16.3.1 DeviceSupport image, SHA-256
`6ef447b91de58f0049c8813a14a431a279abad6a1d0883a04335e768b1540eb6`,
contains the same methods at static `0x20ccd76bc` (three-argument) and
`0x20ccd8234` (five-argument).  Its equivalent gate reads `internal+0x1c8`
and `*(internal+0x1c8)+0x3f8`, then sets `w5=1` on the nonzero path.  Thus the
two builds have concrete private-layout deltas of `+0x10` and `+0x20` at this
decision.  This is RE-confirmed via the relative Objective-C method list for
`AGXG13GFamilyTexture` plus capstone disassembly of the actual iOS binary.
It is not yet proof that macOS is using the wrong offsets: its C++ texture
object also legitimately places the hardware descriptor at `+0x190` instead
of iOS's `+0x180`.  **THEORY:** either the macOS feature state was never
initialized, or one of these reads crosses into an iOS-layout object.  The
next LLDB stop at static `0x1e5770c50` will dump both the macOS-expected and
iOS-native alternate offsets, distinguish the cases, and must precede any
fix.

Chroot artifacts are archived under
`/tmp/macws-pf550-updatebind-20260724-2316`: `WindowServer.err` SHA-256
`697693a8eca340dd3c9c9971e624b07adfc2690b38a31196776dc70c1f15a484`
and LLDB session SHA-256
`a2d21bb34d00f9baa23eb041f7b83961172ef7b056129261e5dca05910494224`.

### RE/runtime-confirmed: IOSurface per-plane ABI recovery makes the real pf550 initializer succeed

The suspected `internal+0x1d8` gate was not a macOS/iOS C++ object-layout
mix-up. A read-only project-LLDB trace of the exact macOS 13.4 outer texture
initializer (`0x1e5a5ae18`) showed that its compression query and descriptor
validation passed, but the real family `initImpl` returned zero. After tracing
the inner method and its `TextureGen4` constructor, the failure was moved
upstream to IOSurface per-plane metadata.

The first confirmed ABI mismatch was BytesPerRow. The exact IOSurface clients
read these offsets:

```text
macOS 13.4 IOSurfaceClientGetBytesPerRowOfPlane: +0xe0
iOS 16.3 IOSurfaceClientGetBytesPerRowOfPlane:   +0xdc
```

For pf550 plane 0, the iOS object has explicit `BytesPerRow=153600`, while the
macOS getter's shifted read lands on `PlaneSize=16390144`. Before recovery the
real `initImpl` therefore received `x7=0xfa1800`; after recovery it received
`x7=0x25800`. The native iOS probe independently returned the creation
property and API values below for both planes:

```text
plane=0 propertyBytesPerRow=153600 apiBytesPerRow=153600
plane=1 propertyBytesPerRow=38400  apiBytesPerRow=38400
```

Correcting BPR exposed, rather than hid, the next invariant: the C++ Texture
was allocated and constructed, but `Texture+0x1d8` remained zero. The exact
macOS constructor is static `0x1e5a46868`; its metadata object is 0x450 bytes
and is installed at `0x1e5a4805c`. A native-iOS runtime locator stripped PAC
from the corresponding ObjC IMP and found image offset `0x55bffc`, static
`0x20ceeaffc`; its constructor call targets `0x20cee7358`. That iOS constructor
uses the same decision tree, with a 0x430-byte metadata object and the expected
iOS-private layout deltas.

The macOS constructor trace then located the first failing branch exactly:

```text
0x1e5a47320  ldr  w10, [x25, #0x48]
0x1e5a47324  ands w9, w10, #0xff
0x1e5a47328  b.eq 0x1e5a47354

runtime before fix:
settings+0x48 = 0x05000200, low byte = 0
next stage       = metadata-fallback
Texture+0x1d8   = 0
```

The byte is derived from `IOSurfaceGetAddressFormatOfPlane`. Disassembly of
the exact IOSurface binaries found another four-byte drift:

```text
macOS 13.4 IOSurfaceClientGetAddressFormatOfPlane:
    client + plane*0x80 + 0xed
iOS 16.3 IOSurfaceClientGetAddressFormatOfPlane:
    client + plane*0x80 + 0xe9
```

The iOS-native probe returned `propertyAddressFormat=5 apiAddressFormat=5`
for both pf550 planes. In chroot the unmodified macOS getter returned zero.
The compatibility layer now recovers CompressionType,
HeightInCompressedTiles, BytesPerRow, and AddressFormat from the IOSurface's
own explicit creation properties when the exact macOS getter disagrees. It
does not synthesize a format or force a validation result. Because the
standalone AGX cache image has pre-populated GOT slots, only those four
RE-confirmed imports are force-bound to the wrappers.

The AddressFormat A/B run produced the expected causal chain:

```text
IOSURFACE-COMPAT addressFormat plane=0 original=0 property=5 recovery=1
settings+0x48 = 0x05000203, low byte = 3
PF550-CTOR stage=metadata-allocation
PF550-CTOR stage=metadata-install
Texture+0x1d8 = 0x15303c000
PF550-INNER stage=inner-epilogue x0=0x1
PF550-INIT stage=initImpl-return x0=0x1
PF550-INIT stage=super-init-return x0=<real texture>
PF550-INIT stage=footer-validation-return x0=0x1
```

This is the first runtime witness that macOS AGX accepted the real
2388x1668 private-pixel-format-550 compressed IOSurface texture all the way
through its outer initializer. It does not yet prove a completed shader read,
WindowServer frame, or blur.

Pre-fix constructor artifact
`/tmp/macws-pf550-ctor-20260725-0240/lldb.log` has SHA-256
`1cda714c721692ab2233ff022b9a65532db0058eb4f748062773faf666bf3fc2`.
Its WindowServer log has SHA-256
`3da7ce62abfceda43a0800f54b90f7d9c2d5e499a343b19375919cb005a321a3`.
Post-fix artifacts under
`/tmp/macws-pf550-address-fix-20260725-0255` have SHA-256
`8a12309aff6bb0ece6cd269af6f5a85581f3cc96c6670d8d5fe3f8d2df84d3f4`
(LLDB) and
`7facd03b8bdeea50be352717b6953b8da94a66a99cbfcb26f340ec4f34400ba8`
(WindowServer).

## 2026-07-25: native AGX WindowServer renders GlassDemo through VNC

Milestone source commit:
`5fb13b8a5204c4b8710fa080b18be2597718661e`.

### Runtime-confirmed: multi-segment KCMD storage was the `0x102` boundary

The previous command walker treated the trailer after the first vendor record
as the next record.  Frozen two-segment and 28-segment WindowServer captures
showed a different framing:

- segment-list `+0x08` is the count and `+0x0c` is
  `0x80000000 | listByteLength`;
- each KCMD segment begins with type `0x10000` and carries its complete span at
  record `+0x04`;
- every derived `{start,end}` range occurs exactly once at an aligned location
  in the actual segment list;
- entries are variable-sized.  The initial fixed-`0x120` entry-stride THEORY
  was disproved by the 28-segment capture.

The complete 28-segment KCMD capture is 58,344 bytes with SHA-256
`18d50b9b969b88d4024725495679da122347c62b6a1f20bf91249bcccd72a725`;
its associated segment list is 9,232 bytes.  The new walker validates the
entire contiguous record chain and all unique range pairs before changing any
byte, then translates observed subtype-1/subtype-3 records from the end toward
the beginning and shifts all later ranges.

This is still explicitly named `TEMP-KCMD-MULTISEG-FIX` and gated by
`/tmp/macws_kcmd_fix`.  It is a diagnostic ABI scaffold, not a production fix:
byte deletion is only justified by the captured macOS/iOS layouts, not yet by
a complete semantic producer/parser model.

The A/B boundary is nevertheless exact.  Before multi-segment handling, every
full-frame command completed as status 5 with
`Internal Error (00000102)`.  With the validated multi-segment translation,
the 28-segment main composite and at least 16 consecutive full-display command
buffers completed as:

```text
#### VNC-ENDUPDATE-WAIT #0 ... pf=550 ... status=4 error=nil
...
#### VNC-ENDUPDATE-WAIT #15 ... pf=550 ... status=4 error=nil
```

Per-segment logs are now limited to the first four validated batches, but the
translation itself remains enabled for every matching frame.  A previous
one-shot throttle was removed because later frames are the GUI witness.

### Runtime-confirmed: native control, pf550 read, mmap, and RFB all complete

The scanout-read pipeline reflected exactly one fragment texture at slot zero,
both independent BGRA8 controls produced their expected pixels, and the real
pf550 frame was copied to the shared VNC mmap:

```text
#### VNC-FINAL pipeline ... contract=OK error=nil
#### VNC-FINAL clear-control executed=YES pixel=OK center=804020ff
#### VNC-FINAL control clear=OK draw=EXECUTED pixel=OK center=214365ff
#### VNC-FINAL captured 2388x1668 BGRA8 ... bpr=9600 sampled_nonzero=2864
```

The dependency-free RFB client then reported:

```text
captured 1194x834 from 'macOS-iPad' in 1 raw rectangle(s)
```

The committed witness is
[`docs/evidence/native-agx-glassdemo-20260725.png`](evidence/native-agx-glassdemo-20260725.png),
SHA-256
`2a1ef4b7897a4245385a982788c618d2d15f7f9cfcaad0009ebafbd127ae08e5`.
It visibly contains GlassDemo's title bar, standard controls, rounded frosted
material, and the inner HUD/vibrancy region.  It is neither the synthetic VNC
gradient nor either known-color control texture.

### RE-confirmed: the visible material comes from the actual test binary

`otool -ov` identifies `VFXBox` as an `NSVisualEffectView` subclass.  Disassembly
of the actual `/tmp/GlassDemo` binary (SHA-256
`d8fb6da1192eda00ec1f9ecad0e54a0f387866b36deb150f92ec9bd349b6b1f3`)
shows its main view setting material 7, blending mode 0, and state 1 at
`0x100001134..0x100001160`.  A second effect sets material 13, blending mode 1,
and state 1 at `0x100001f98..0x100001fc0`.  Thus the non-black frosted regions
in the RFB frame are output from real `NSVisualEffectView` configurations, not
labels drawn by a fake demo.

The background behind the main material is mostly uniform, so this screenshot
does not independently measure a blur radius or provide a high-frequency edge
A/B.  Several attempts to add a striped background did not reach another pf550
frame and therefore are not counted as success.

### Stability boundary: screenshot success is not production stability

The successful log later shows rapid type-`0x82` resource growth and a second
WindowServer constructor.  The reason for that restart was not captured.
Three later striped-background experiments produced real WindowServer crash
reports with `EXC_BAD_ACCESS/SIGBUS` at `libobjc.A.dylib objc_msgSend`; their
triggered threads were SystemStatus/NSXPC queues, not AGX command-completion
threads.  This is runtime-confirmed, but its cause remains THEORY.  No new
gpuEvent or panic was emitted.

Full excerpts, artifact hashes, and the three crash-report hashes are in
[`docs/evidence/native-agx-glassdemo-20260725.txt`](evidence/native-agx-glassdemo-20260725.txt).

## Next milestones

1. Replace subtype-1/subtype-3 byte deletion with a field-level translator
   backed by disassembly of both macOS producers and the iOS kernel parser;
   reproduce the VNC frame without `/tmp/macws_kcmd_fix`.
2. RE the SystemStatus/NSXPC `objc_msgSend` SIGBUS using the saved reports and
   the project's early-attach LLDB tooling; do not globally bypass XPC or
   Objective-C release/encoding.
3. Pair type-`0x82` creates/destroys and stop the long-run allocation growth;
   require stable counters and repeated VNC frames, not process uptime.
4. Obtain a high-frequency-background A/B that reaches pf550 and visibly
   measures blur spread without changing GlassDemo's material implementation.
