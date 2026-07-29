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
shifted by four, compressed is bit 103, and extended is bit 127.  A later
2026-07-27 audit corrected one important overstatement here: the low 36 bits
of the extended word encode an acceleration-buffer address only when the
descriptor is compressed.  For a linear descriptor the same union contains
linear depth/layer-stride fields; it must not be decoded as a GPU VA.

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
extendedRawLow36=0x1500053e00 (not an acceleration address for layout=linear)
bytes=02b30a36950c1a0000c0014005c05fa8e0530050f1850100
```

The former attribution of the previous GPU fault at `0x150006c500` to a
"malformed acceleration address" is therefore retracted.  The descriptor is
linear (`layout=0`, `compressed=0`), so that numerical comparison decoded the
wrong member of a conditional hardware union and is not fault evidence.

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

The background behind the main material is mostly uniform, so that first
screenshot alone did not independently measure a blur radius.  The multiscale
A/B below closes that evidence gap without changing GlassDemo's material.

### Runtime/quantitative-confirmed: the native effect performs backdrop blur

Source commit `4a42d6d4ac59798e1339f8a2ca6a386b109a5367` adds an
opt-in `MACWS_GLASS_BLUR_AB=1` diagnostic.  It recursively locates the existing
material-13, blending-mode-1 `NSVisualEffectView` and inserts a three-frequency
black/white source immediately below it.  It does not change the target's
material, blending mode, state, or class.  The normal GlassDemo plist leaves
the diagnostic disabled.

The runtime target record is exact:

```text
#### GLASS-BLUR-AB installed attempt=1 target=NSVisualEffectView material=13 blending=1 effect=(60.0 60.0 820.0 100.0) stripes=(32.0 32.0 876.0 156.0) periods=8/32/96pt
```

The top and bottom 28-point margins expose the unfiltered source; the existing
effect view covers the center.  In the 2x raw VNC framebuffer, the three full
periods are 16, 64, and 192 physical pixels.  The native pf550 read completed
with `contract=OK error=nil`, both independent control pixels matched, and the
2388x1668 BGRA frame contained 2,844,662 non-black pixels.

The committed A/B witness is
[`docs/evidence/native-agx-glassdemo-blur-ab-20260725.png`](evidence/native-agx-glassdemo-blur-ab-20260725.png),
SHA-256
`f33d7f152e0894cd03148910022431f36ddf24f0ee9aae7ebbddce4fabd31197`.
Its raw VNC framebuffer SHA-256 is
`de72e367ddd903269047cd69875ec8637d98d49fdf11c25da18b8353d37dbc00`.

Measured from the frozen raw BGRA pixels:

| Source bars | Sharp fundamental | Effect fundamental | Effect range |
|---|---:|---:|---:|
| 4 pt (16 px period) | 163.386 | 0.207 | 173..191 |
| 16 pt (64 px period) | 162.403 | 0.287 | 173..185 |
| 48 pt (192 px period) | 162.345 | 18.414 | 157..201 |

The 4-point frequency is attenuated by about 57.9 dB.  In the 48-point region,
the covered output still has distinct black/white plateaus (160.660 vs
197.396), while the input's one-pixel hard edge becomes a 54.58-pixel 10–90%
transition.  This rules out both an unfiltered copy and a flat opaque tint:
the backdrop influences the output, edges spread, and higher frequencies are
suppressed.  Full coordinates, formulas, verbatim runtime excerpts, and hashes
are in
[`docs/evidence/native-agx-glassdemo-blur-ab-20260725.txt`](evidence/native-agx-glassdemo-blur-ab-20260725.txt).

### Stability boundary: screenshot success is not production stability

The successful original log later shows rapid type-`0x82` resource growth and
a second WindowServer constructor.  A later blur-A/B run made the resource
boundary concrete: a memory-pressure event names WindowServer as
`largestProcess`, with PID 9056 at 743,169 resident 16-KiB pages and reason
`vm-compressor-space-shortage`.  The final automated witness therefore copied
the VNC mmap and stopped the GUI immediately; it produced no newer crash report
and restored the iOS GUI at load average 1.59.  This is a bounded proof, not a
long-run fix.

Three later striped-background experiments produced real WindowServer crash
reports with `EXC_BAD_ACCESS/SIGBUS` at `libobjc.A.dylib objc_msgSend`; their
triggered threads were SystemStatus/NSXPC queues, not AGX command-completion
threads.  This is runtime-confirmed, but its cause remains THEORY.  No new
gpuEvent or panic was emitted.

Full excerpts, artifact hashes, and the three crash-report hashes are in
[`docs/evidence/native-agx-glassdemo-20260725.txt`](evidence/native-agx-glassdemo-20260725.txt).

## 2026-07-25: IOSurface release ABI fixed; native GlassDemo remains bounded

The long-run pressure root cause was the cross-OS IOSurface release ABI, not
the CA page vector or a missing AGX destroy.  RE of the exact frameworks shows
macOS 13.4 issuing `IOConnectTrap1` indices 4 then 5, while iOS 16.3.1 releases
with one selector-1 scalar method after dropping client+0x60.

The new UUID/callsite/instruction/TLS-pair-validated adapter maps those two
macOS calls to the one real iOS operation.  A Metal-free 16 x 16-MiB probe went
from 16 surviving IOSurface regions (256 MiB) after balanced `CFRelease`s to no
IOSurface regions and a 7.6-MiB total footprint.  Under active WindowServer,
more than 30,000 AGX resource operations left a 43-resource / 78-MiB live set
and a 165-MiB process footprint instead of the previous multi-gigabyte growth.

A final normal GlassDemo + VNC run held 53--54 IOSurface regions while
WindowServer footprint decreased from 213 MiB to 189 MiB across about 54 seconds.
The selector-1 release witness reached 4,250, GlassDemo stayed alive, and RFB
captured the title bar, controls, and frosted/vibrancy regions.  No new crash
or Jetsam report appeared.  Full disassembly excerpts, runtime samples, and
artifact hashes are in
[`docs/evidence/iosurface-release-abi-20260725.txt`](evidence/iosurface-release-abi-20260725.txt).

## 2026-07-25: native iPadOS host has Apple M1 Metal + first input bridge

The new `MacWSHost` is an arm64 iPadOS multi-scene application that reads the
existing no-VNC shared BGRA frame. Its first dedicated entitlement build saw
the AGX service/plugin/class but `MTLCreateSystemDefaultDevice()` returned nil.
Live unified logs identified exact MACF denials for `AGXDeviceUserClient` and
`IOSurfaceRootUserClient`. Adding only those two entries to the host's
`com.apple.security.iokit-user-client-class` produced `Apple M1 GPU` and a
completed render/present command buffer (`status=4 error=nil`). The broad
WindowServer entitlement set and `platform-application` are not used.

M2 adds `macwsinputd`, a macOS chroot receiver for a packed Unix-datagram
input ABI. ABI v2 carries source frame dimensions because runtime showed a
2388x1668 producer but 1194x834 Quartz display. Two no-VNC diagnostics mapped
source `(240,300)` and `(1900,1300)` to Quartz `(120,150)` and `(950,650)`;
`CGEventGetLocation` observed both posted cursor states. The LaunchDaemon path,
single-instance lock, display startup refresh, package staging, and one-click
cleanup were also runtime-tested.

Multiple simultaneous UIKit scenes are not yet working. SpringBoard accepts
the first scene but rejects the second with
`SBSceneManagerCoordinatorDomain Code=1`; public request parameter variants
and a `platform-application` A/B do not change it. The exact SpringBoard
failure path and all verbatim evidence are in
[`docs/evidence/ipados-native-host-m0-20260725.txt`](evidence/ipados-native-host-m0-20260725.txt)
and
[`docs/evidence/ipados-native-host-input-m2-20260725.txt`](evidence/ipados-native-host-input-m2-20260725.txt).

## 2026-07-26: M3 App control center owns cold start, repair, capture, and recovery

`MacWSHost` 0.3 now talks to the root `com.macwsguide.host.control` XPC service
through a typed, fixed-operation protocol. The matching `macwshostd`
LaunchDaemon starts at bootstrap load and is the only component allowed to run
the fixed GUI/recovery scripts or launch four compiled-in macOS application
paths. The UIKit glass panel exposes live rootfs, WindowServer, input, and frame
state plus start/stop, app launch, repair, safe recovery, log, screenshot, and
diagnostic-export controls. VNC is not started.

The first end-to-end package test caught two real cold-install bugs. The deb's
fat hook still carried `platform IOS`, causing an arm64e bash SIGTRAP in
`os_variant_has_internal_diagnostics`; after correcting the platform, dyld
then exposed an asymmetric native-only declaration/call. The production fix
puts the native call under its actual compile condition and makes package
postinst/App repair perform platform conversion, thin arm64e+arm64 extraction,
double signing, and trust registration at the upstream install boundary. A
fresh package install emitted the thin-split witness before the build helper
ran, and the helper correctly kept those already-installed slices.

After a userspace reboot, only hostd was initially present. Cold-launching the
App brought up WindowServer and `macwsinputd`, reported `ws=YES input=YES`, and
presented a completed nonzero 2388x1668 frame on `Apple M1 GPU`. The App's
version-2 input diagnostic mapped `(400,300)` to Quartz `(200,150)` and observed
the posted cursor location. App-launched GlassDemo then produced a native tile
pipeline with `contract=OK error=nil`, correct independent control pixels, and
a 2388x1668 capture with 2,861 sampled nonzero pixels.

The default-on compatibility switch remains explicitly labelled diagnostic
scaffolding; M3 is a usable full-display host, not the final per-window native
iPadOS architecture. Verbatim runtime lines, package hashes, and the reboot
boundary are in
[`docs/evidence/ipados-native-host-control-m3-20260726.txt`](evidence/ipados-native-host-control-m3-20260726.txt).

## 2026-07-26: M4 target-process touch and visible Terminal

The M2 CGEvent result was corrected after a frozen-frame A/B: global and
per-PID posts changed the receiver's observable cursor state but did not
change a GlassDemo checkbox, and the runtime permission probe returned
`CGPreflightPostEventAccess=NO`. Input ABI v3 now includes the exact active
application PID. `macwsinputd` forwards each validated record to a per-PID
socket owned by the target AppKit process, where libmachook creates and posts
an `NSEvent` on the main CFRunLoop's common modes.

The project LLDB helper showed GlassDemo's main thread in its programmatically
opened context-menu tracking loop. The first tap correctly dismisses that
menu; the following tap changed 760 pixels in the checkbox's 28x28 region.
This is the first visible control-state witness for iPadOS-hosted input.

Testing non-demo apps also found two independent issues. A WindowServer crash
report placed the fault in the observer's diagnostic
`-[NSError description]` call, so error logging now treats the private object
as opaque. RE of the actual Terminal image then showed that
`-[TTApplication applicationShouldOpenUntitledFile:]` returns `NO` and its
real action is `-[TTApplication newShell:]`. Invoking that application action
after direct launch runtime-created three windows and produced an acknowledged
shared frame containing a visible Terminal shell. No assertion/check or
startup branch was bypassed.

Continuous move/hover logging is now sampled while every down/up/cancel is
kept, and cleanup closes the receiver socket from SIGTERM so it cannot remain
as a restart-conflicting orphan. Verbatim logs, disassembly, pixel bounds, and
artifact hashes are in
[`docs/evidence/ipados-native-host-input-m4-20260726.txt`](evidence/ipados-native-host-input-m4-20260726.txt).

## 2026-07-26: coexistence VNC pacing, Terminal survival, and stable source selection

The apparent one-click startup failure was three independent runtime-confirmed
faults. Immediate synthetic cancelled-swap completion produced about 3,600
completions per minute and held WindowServer at 98% CPU until the thermal
watchdog stopped the whole stack. Pacing the one matching completion at the
SwapEnd ownership boundary reduced the observed WindowServer load to 55.7%
without changing the 70% safety threshold.

Terminal then exposed a process-scope regression: its crash report faulted at
`IOSurfaceCreate_safe` line 5076 while the diagnostic statistics block called
`CFDictionaryGetValue`. The interposer already had a WindowServer-only
contract, but the statistics block had been added before that gate. Moving the
gate ahead of every dictionary access kept Terminal alive, invoked the
RE-confirmed `-[TTApplication newShell:]` action, and returned eight windows
in the final packaged run.

Finally, the shared-frame publisher accepted every large composite. Runtime
logs showed a correct 2388x1668 PF80 display destination followed by a
1140x798 Terminal intermediate; the latter shrank the mmap and caused the VNC
viewer to alternate between black/full/cropped frames. The publisher now
allows its display-size maximum to grow but rejects smaller intermediates.
Ten consecutive RFB captures were byte-identical, each with 488,707 non-black
pixels, while the mmap header remained 2388x1668. `--experimental` now owns the
VNC-share sentinel as well as the command/completion sentinels, and `stop` or
the watchdog removes all three.

Verbatim reports, logs, hashes, and the before/after mmap headers are in
[`docs/evidence/coexist-vnc-stability-20260726.txt`](evidence/coexist-vnc-stability-20260726.txt).

## 2026-07-26: undistorted VNC, dynamic refresh, and real AppKit control input

The stretched image was an RFB metadata bug: the delivery hook used
`paddedWidthInBytes / 4` (2400) as the visible width instead of rfbScreen's
1194-pixel width.  The bridge now preserves the 1194x834 logical desktop while
sampling the 2388x1668 Retina frame.  Largest-area source selection also keeps
1140x798 Terminal intermediates from replacing the display composite.

The apparent input failure had three independent, runtime-confirmed causes.
`macwsinputd` originally forwarded targetPID zero even after resolving a live
application; the AppKit bridge then rejected the record.  Separately queued
CFRunLoop blocks reversed down/up on the device.  Finally, a synchronous
mouse-down could enter AppKit control tracking before mouse-up was available.
The route now writes the resolved PID, the application endpoint maintains an
explicit FIFO, and complete RFB taps enter normal AppKit tracking with the
matching up already queued.

A non-destructive click on Terminal's top-right tab area changed the RFB raw
frame SHA-256 from `cc00b054...` to `3dfa9dbb...`, activated the target window,
and returned through `APP-INPUT POST kind=3`; Terminal stayed responsive.
Clicking a close button also reached `NSControlTrackMouse → sendAction: →
NSWindow __close`, but LLDB then found Terminal waiting in its own close
cleanup at `objc_sync_enter`.  That application-specific deadlock remains an
open issue and is not masked by invoking the close action directly.

Dynamic refresh was independently frozen by a permanent
`g_vnc_final_available` latch after the first PF550 screenshot.  The one-shot
capture no longer disables the PF80/115 stream.  Failed PF550 command buffers
are excluded from normal capture-source selection, and a diversity check
rejects the driver's solid error colour.  The final post-input frame logged
`sampled_different=15609 publish=YES` and acknowledged the exact input capture
generation.  Full log excerpts, hashes, LLDB frames, and safety boundary are
in
[`docs/evidence/coexist-vnc-input-refresh-20260726.txt`](evidence/coexist-vnc-input-refresh-20260726.txt).

## 2026-07-26: Retina RFB geometry and content-backed first-frame readiness

The low-resolution VNC report was real rather than cosmetic. The known-good
native-host PNG is 2388x1668, but LLDB read OSXvnc's `rfbScreen` as 1194x834
with backing scale 2.0. Arm64 disassembly of the exact device binary showed
that both `rfbScreenInit` and the later resolution checker call
`CGDisplayPixelsWide/High`. Hooking those two APIs only in shared-frame OSXvnc
mode makes both paths consistently observe 2388x1668; editing `rfbScreen`
after init had instead caused a resolution-change/reconnect loop.

The black first connection was a readiness race. OSXvnc could send its cached
all-zero framebuffer before WindowServer published and ACKed the requested
native-GPU frame. `macos_gui.sh` now waits up to the runtime-observed 60-second
tail for the exact capture generation before reporting the session ready. The
capture tracker also makes its advertised four retries reachable on a static
scanout after an `InnocentVictim` completion.

Readiness is now content-backed: opaque black no longer counts as a nonzero
pixel, and a frame needs at least 5% sampled RGB coverage plus spatial
diversity. The final generation logged 8,475/15,750 RGB-nonblack samples and an
immediate RFB client received 2388x1668 with 2,186,992/3,983,184 (54.906%)
non-black pixels. Existing Terminal windows are activated and redrawn through
ordinary AppKit APIs instead of accumulating another `newShell:` per restart.

WindowServer restart detection now also reconnects its VNC, Terminal, and
input dependents; a single fault-injection recovery produced a 2388x1668 frame
with 54.891% non-black pixels. A deliberately overlapping double restart
exposed a remaining content-recovery edge case (window outlines without client
content); the stricter RGB gate now refuses to label that state ready.

Verbatim disassembly, LLDB memory, runtime logs, hashes, and build witnesses are
in
[`docs/evidence/coexist-vnc-retina-ready-20260726.txt`](evidence/coexist-vnc-retina-ready-20260726.txt).

## 2026-07-27: first native-AGX PageFault is an earlier 8-pass batch, not PF550

A file-gated hook on the runtime-enumerated
`-[IOGPUMetalCommandBuffer didCompleteWithStartTime:endTime:error:]` now
correlates the private raw completion with the exact bounded submit-ring
serial before IOGPU clears command-buffer storage.  It showed that serial 1's
`Code=1 / 00000102` startup error and the later `Code=3 / PageFault` are
different failures.  In a controlled Terminal run, the first PageFault was
serial 390; the PF550 observer did not report its first failed display command
until serial 392.  The earlier attribution to PF550 was therefore corrected.

The exact serial-390 payload is an eight-segment subtype-1 batch translated
from 17,112 to 16,856 bytes (`fixed=8`).  Every translated segment span,
record size, and variable-list `{start,end}` pair is internally consistent.
More importantly, serials 261 (`fixed=9`) and 277 (`fixed=8`) reached the same
raw callback with no NSError, and later recovered `fixed=8` serials also
completed cleanly.  This disproves the theory that every large multi-segment
translation necessarily faults.

The fault batch targets the first 1140x798 Terminal intermediate rather than
the 2388x1668 display.  Its `0x384000` output allocation is large enough for
BGRA8.  Every direct high GPU VA in its KCMD lands in an active resource, and
each corresponding gid appears in that segment's resource list.  No direct
dangling VA, missing high-VA resource, or outer-length mismatch was found.
The remaining candidates—an indirect texture address, resource-generation
timing, or an untranslated semantic field—remain explicitly THEORY pending a
fault-VA witness or a post-recovery clean 1140x798 capture.

The first post-recovery recorder incorrectly accepted a 2388x1668 full-screen
success after a 1140x798 fault.  Runtime logs exposed that later Code=3
callbacks could overwrite the stored dimensions even though their verbose log
was one-shot.  The diagnostic now atomically publishes only the first
PageFault dimensions.  In the corrected bounded run, serial 382 faulted at
1140x798 while recovered serials 742 and 744 succeeded at 2388x1668; neither
created the same-geometry dump.  No clean 1140x798 control appeared within 40
seconds, so the comparison remains pending rather than being inferred from a
different render path.

Verbatim callback lines, parsed layouts, scope limitations, and all retained
artifact hashes are in
[`docs/evidence/coexist-native-agx-first-pagefault-20260727.txt`](evidence/coexist-native-agx-first-pagefault-20260727.txt).

## 2026-07-27: completion-path RE and a true libmachook-only FAST loop

Runtime type encodings established the exact private PF550 producer ABI, and a
forwarding-only observer captured the first 1140x798 texture call with
`cpuMetadata=0`, `gpuVA=0x1500070000`, `compressible=0`, and
`initMetadata=0`.  Project-LLDB disassembly then followed the original
five-argument implementation through its primary-object stores and
`texBaseAddressesUpdated` virtual call.

This pass also corrected a false lead. Current Mesa Asahi source makes the
last texture-descriptor word conditional: it is an acceleration-buffer
address for compressed layouts, but overlapping linear depth/layer-stride
fields for `layout=0`.  The earlier interpretation of the 1140x798 raw low 36
bits as an unmapped metadata VA was therefore wrong and has been retracted;
the descriptor is not patched.

The actual IOGPU userspace completion pipeline was disassembled at a Code=3
breakpoint. Selector `0x107` is a separate device-notification callback and
does not carry command fault data. The command queue itself consumes a
0x20-byte record containing a callback object, two timestamps, and a 32-bit
status; IOGPU creates NSError from that status and has no userspace fault-VA
field. A fresh crash-report reset reproduced the 1140x798 PageFault but emitted
no new gpuEvent report, so the fault address remains unresolved rather than
guessed. Every aligned direct VA in the retained fault KCMD still maps to an
active resource; the next boundary is second-level data inside those
resources.

Finally, `build_on_ios.sh --fast-force` now invokes only the `libmachook`
subproject while retaining the root Theos project/build directories. A real
device run completed compile, merge, platform conversion, signing, trustcache,
postinst, and rootfs deployment in 5.998 seconds.

Full runtime excerpts, disassembly, negative-result scope, and artifact hashes
are in
[`docs/evidence/coexist-native-agx-completion-re-20260727.txt`](evidence/coexist-native-agx-completion-re-20260727.txt).

## 2026-07-27: native-AGX GlassDemo passes Retina VNC, input, and blur acceptance

The requested final witness is now runtime-confirmed through VNC without
MacWS Host. The real GlassDemo reported `AGXG13GFamilyDevice / Apple M1`, and
the RFB client negotiated the full 2388x1668 desktop. Consecutive captures
around two VNC clicks had distinct raw hashes; GlassDemo's real NSButton state
changed `0→1→0`. The native PF550 completion counter reached 12,000 with
`clean=12000 error=0 status=4 code=0` and no raw IOGPU error callback.

Before that success, exact macOS cache disassembly traced two remaining
semantic differences upstream. Normalized record `+0x5e3` comes from a byte
in the macOS encoder state copied from `state+0xed8`; normalized `+0x6bc`
comes from `state+0xbec`, which both macOS and iOS compute as
`(state[0x178] >> 16) & 0x1ff`. A file-gated diagnostic changed the observed
macOS values `+0x5e3 1→0`, `+0x6bc 16→8`, and the older `+0x3a0 8→4` in one
run. All three changes hit, but the same PageFault and frozen VNC hash
remained. They are therefore retained only as diagnostics; the combined known
deltas are not sufficient and are not shipped as a field-forcing fix.

The resource recorder was extended at the correct CPU mapping boundary.
RE of the actual IOGPU image proves kernel output `+0x08` feeds
`IOGPUResourceGetDataBytes`, while output `+0x10` feeds the distinct
`IOGPUResourceGetClientShared`. A live bounded dump read all eight selected
type-0 resources successfully with `mach_vm_read_overwrite`; it neither
retains nor modifies the resources.

The decisive blur test left GlassDemo's real material-13 WithinWindow
NSVisualEffectView untouched and inserted three stripe frequencies below it.
The on-wire BGRX analysis measured 58.21 dB suppression at 4pt, 55.94 dB at
16pt, and 19.52 dB at 48pt. The 48pt component remained measurable
(`fundamental=17.162`, output range 158..201), proving backdrop influence;
the high-frequency components were almost eliminated, proving spatial blur
rather than unfiltered passthrough or an opaque flat tint.

Committed full-Retina witnesses:

- [`docs/evidence/native-agx-vnc-glassdemo-20260727.png`](evidence/native-agx-vnc-glassdemo-20260727.png)
- [`docs/evidence/native-agx-vnc-glassdemo-blur-ab-20260727.png`](evidence/native-agx-vnc-glassdemo-blur-ab-20260727.png)
- [`docs/evidence/native-agx-vnc-glassdemo-20260727.txt`](evidence/native-agx-vnc-glassdemo-20260727.txt)

The run ended with `misc/cleanup_all.sh`; no WindowServer, VNC, GlassDemo,
Terminal, or debugger process remained. This closes the stated final target.

## 2026-07-28: Terminal PF550 invariant and live VNC incremental refresh

The separate Terminal hardening failure is now fixed in a bounded VNC run.
The first 300x210 PF550 resource had been allocated through the generic
four-byte BGRA fallback; the exact producer callback then failed with Code=3
at `target=300x210`. Plain pixel format 550 now receives the same two-plane,
16x16-tiled compressed IOSurface layout used by native AGX. A delayed GPU probe
read 15,006/15,750 RGB samples with 15,688 spatial differences and produced a
complete Terminal PNG. The same texture was runtime-observed at fragment slot
3 of clean, full-screen PF550 compositor submissions.

The first valid full-screen readback then revealed an upstream AppKit state
issue: Terminal's saved 150x105-point window began at y=-77 with only
4,200/15,750 square points intersecting the visible screen. Startup now clamps
only windows with less than 50% visible intersection into `visibleFrame`.
Readiness moved from an area percentage to a spatial row classifier: the
title-only frame had four dense rows, while the complete small Terminal had
thirteen, so a real small window passes without admitting an outline-only
frame.

Finally, same-connection RFB testing exposed why reconnecting appeared healthy
while a live viewer froze. RE of the exact device OSXvnc arm64 slice shows
`_refreshCallback+0xec` unions CoreGraphics rectangles into each client's
`modifiedRegion(+0xf8)`; `_clientOutput+0x11c` intersects that state with
`requestedRegion(+0x108)`. The mmap publisher bypassed this notification and
only cursor-sized rectangles reached an incremental client.

The shared file now appends an atomic odd/even publication sequence. A
validated WindowServer writer serializes and release-commits a complete frame;
OSXvnc acquire-checks reads and passes one full Retina CGRect through its own
RE-confirmed `_refreshCallback` for every new even generation. On one
persistent connection, the green-button click traversed
`OSXVNC INPUT → APP-INPUT RX/MAIN/HIT/TAP-COMPLETE`; the same client then
received a 2388x1668 raw incremental rectangle. Its accumulated BGRX hash
changed from `a8c23045...` to `2312254b...`, and the final image was a sharp,
correctly oriented full-screen Terminal. The isolated current WindowServer
segment contained no new PageFault or `AGX_SUBMIT_ERROR`.

The persistent regression client and full RE/runtime record are in
[`misc/vnc_live_click.py`](../misc/vnc_live_click.py) and
[`docs/evidence/native-agx-terminal-vnc-refresh-20260728.txt`](evidence/native-agx-terminal-vnc-refresh-20260728.txt).
The test ended with `misc/cleanup_all.sh` and restored iOS.

## 2026-07-28: multi-application VNC target resolution and 20-click soak

A longer persistent-client run exposed a separate input invariant. With both
Terminal and GlassDemo alive, macwsinputd's launchd session still returned
`CGWindowListCopyWindowInfo = NULL`; the sole-endpoint fallback therefore had
no legal target, and logs showed `route=global-fallback pid=0` even though
OSXvnc had sent the complete record.

The broker now broadcasts only a nonce-bound, versioned hit-test query to live
AppKit endpoints. Each application answers from its main thread with the first
visible local window containing the point plus active/key flags. The original
input event is then sent to exactly one uniquely ranked PID; it is never
broadcast, and equal-ranked overlaps remain unresolved. Runtime with Terminal
behind GlassDemo produced two replies (`flags=0` versus `flags=0x7`) and
selected only GlassDemo's real window.

On one retained 2388x1668 RFB connection, twenty checkbox taps completed in
224.9 seconds. All twenty target probes selected GlassDemo, all twenty events
used the AppKit socket, and the real NSButton value alternated exactly ten
times `0→1` and ten times `1→0`. Every iteration received a changed full Retina
dirty frame. Native PF550 reached `clean=12000 error=0`; the isolated run
segment contained no PageFault, `AGX_SUBMIT_ERROR`, or raw IOGPU error callback.
WindowServer stayed on one PID. Its RSS spot samples increased by about 15 MiB,
so the result is a bounded interaction soak, not a long-term leak/thermal
claim.

The reusable client can now optionally require a changed crop around the click
to reject unrelated animation updates. Full wire protocol, runtime excerpts,
hashes, resource samples, the corrected preview-coordinate false lead, and
cleanup proof are in
[`misc/vnc_interactive_soak.py`](../misc/vnc_interactive_soak.py) and
[`docs/evidence/native-agx-vnc-multiapp-soak-20260728.txt`](evidence/native-agx-vnc-multiapp-soak-20260728.txt).

## 2026-07-28: VNC click/drag ownership, dynamic pacing, and Terminal final frames

The remaining VNC usability failures were independent. First, WindowServer
published a full 2388x1668 BGRA mmap generation for identical frames; the
producer now compares before opening the seqlock and skips both the 15.2-MiB
copy and sequence advance. A static run reached `unchanged skip #600` while
the shared sequence remained 48. Second, a 100-ms completion interval was
cooler but imposed idle latency on interaction. OSXvnc now writes a throttled
monotonic activity timestamp, selecting 16.667 ms for one second of activity
and returning to the explicit 100-ms idle interval without changing command
bytes or completion semantics.

Pointer delivery now has exactly one owner per gesture. A possible left down
is held within a three-logical-point slop radius. A stationary release becomes
one per-process AppInput tap; crossing the radius replays the down and drag
through OSXvnc's RE/runtime-confirmed native NSWindow move path. The real
GlassDemo NSButton logged `before=0 after=1`, while a title drag remained
native and delivered its first changed tile in 0.450 seconds. This avoids the
previous duplicate mouseDown that entered AppKit's `Periodic events are
already being generated` branch.

Terminal's last stale frame was a measured ordering error rather than lost
keys. All 36 events for `echo settledproof` reached its TTView; the 750-ms
Terminal-only AppKit display settle ran after OSXvnc's old 350-ms final capture
request. A second debounced request at 1100 ms produced an acknowledged native
frame containing the complete command, output, and prompt without another
input. The first changed keyboard tile arrived in 0.274 seconds.

Finally, `start coexist --experimental` now creates the owned BGRA scanout
sentinel and uses the tested dynamic 100-ms-idle/16.667-ms-interactive pair by
default. A clean stop proved both sentinels absent; the following one-command
start reached a validated Retina first frame. The path remains explicitly
diagnostic, and a 40-52% WindowServer CPU / 350-430 MiB RSS sample prevents any
thermal or long-term leak claim. Full logs and classification are in
[`docs/evidence/native-agx-vnc-interactive-pacing-20260728.txt`](evidence/native-agx-vnc-interactive-pacing-20260728.txt).

## 2026-07-28: Chrome 150 startup isolated from AGX at PartitionAlloc VA geometry

The first official arm64 Chrome launch now has a causal startup diagnosis. It
traps in Chrome Framework static initialization before ANGLE or Metal device
creation. LLDB captured a 32-GiB `mmap` aligned to 32 GiB: the kernel returned
an unaligned range at `0x280000000`, Chrome discarded it, and its near-64-GiB
fallback failed with `ENOMEM`. The exact binary's failure handler then reached
the observed `BRK` with error value 12.

One source file was compiled for both native iOS and macOS-chroot execution.
Both contexts reject a 32-GiB/32-GiB-aligned `mach_vm_map`, while 8-GiB and
16-GiB aligned reservations succeed. Two adjacent 16-GiB ranges also succeed,
but start at 16 GiB and therefore do not meet Chrome macOS's encoded 32-GiB
pool-base invariant. This runtime comparison rules out chroot translation,
AGX, and a missing macOS-binary entitlement as causes of this first failure.

A scan of the exact arm64 framework found thousands of 16-GiB immediate-mask
uses, so patching only the allocation call would knowingly break inline pool
address calculations. The next application-coverage experiment is an official
native-arm64 Chromium build from before macOS PartitionAlloc-Everywhere, not a
forced-success allocator patch. Exact crash offsets, disassembly, LLDB mmap
arguments, identical dual-context probe output, and source links are retained
in [`misc/va_alignment_probe.c`](../misc/va_alignment_probe.c) and
[`docs/evidence/chrome-partitionalloc-va-limit-20260728.txt`](evidence/chrome-partitionalloc-va-limit-20260728.txt).

## 2026-07-28: latest VS Code Chromium renders WebGL2 Aquarium on native AGX

### Runtime-confirmed: current Chromium and full WebGL2 pixels

The current native-arm64 Visual Studio Code build now gets through its real
Chromium/ANGLE Metal path. CDP reported the exact versions below; this is not
the older Chrome binary whose PartitionAlloc geometry failed before Metal:

```text
Browser: Chrome/148.0.7778.280
User-Agent: Code/1.130.0 Chrome/148.0.7778.280 Electron/42.6.0
V8-Version: 14.8.178.38
```

The formal page-side probe found the already-created Aquarium context to be
`WebGL2RenderingContext` with a 1024x1024 drawing buffer. A 2388x1668 macOS
capture visibly contains the complete textured aquarium, fish, water, plants,
bubbles, and controls at the selected 1000-fish setting. This is the required
pixel witness: process uptime and an empty canvas are not counted.

The process log independently proves that the execution path is the real
AGXG13G stack rather than MTLSim:

```text
#### PREREGISTER image[627] AGXMetal13_3: 52/52 realized
#### MACWS_AGX_NATIVE setupCompiler:0x30010 fired (Device=0x600282000)
```

Immediately before the bounded run was stopped, the read-only command-buffer
error observer had zero occurrences of all three previously correlated parser
statuses:

```text
FORMAL_AGX_ERRORS
00000102=0
00000103=0
0000000a=0
```

This is runtime-confirmed by
[`docs/evidence/webgl-aquarium-native-agx-20260728/`](evidence/webgl-aquarium-native-agx-20260728/).
It is a bounded application-coverage result, not a thermal or long-soak claim.

### RE/runtime-confirmed blockers and the upstream adaptations

Chromium's exact `libGLESv2.dylib` uses private `-[MTLDevice newEvent]`.
Disassembly of macOS 13.4 IOGPU (UUID
`CE2B5551-857F-3EDD-9E4F-435215CC8C27`) showed that
`-[IOGPUMetalDevice newEvent]` selects `_IOGPUMetalMTLEvent`, whose
`-[IOGPUMTLEvent initWithDevice:]` calls IOConnect selector `0x18` and returns
nil on failure. The pre-fix runtime log recorded the same kernel result and
the diagnostic fallback:

```text
#### AGXIOC Method sel=0x18->0x18 inCnt=0 inSC=0 outSC=0 -> 0xe00002c2
#### MACWS-NEW-EVENT #1 original=nil sharedEvent=... class=_MTLSharedEvent ... deviceClass=AGXG13GFamilyDevice
```

The actual iOS 16.3 implementation was then located in the live shared cache
at image offset `+0x170b0`. Its runtime bytes decode to the same zero-input,
two-scalar-output ABI but `mov w1, #0x14`. The translation table now maps only
this macOS selector `0x18` to iOS selector `0x14`. A native event-only probe
and a fresh chroot probe both exited 0 with real `_IOGPUMetalMTLEvent`
instances and completed signal/wait command buffers. The chroot log now says:

```text
#### AGXIOC Method sel=0x18->0x14 inCnt=0 inSC=0 outSC=0 -> 0x0
METAL_SOURCE_PROBE newEvent responds=1 event=... class=_IOGPUMetalMTLEvent
METAL_SOURCE_PROBE sharedEventCommands signalStatus=4 waitStatus=4 eventValue=1 signalError=(nil) waitError=(nil)
```

The nil-result shared-event adapter remains a diagnostic safety net, but a
post-fix VS Code run had zero fallback invocations. Exact evidence is in
[`private-metal-event-selector-20260729.txt`](evidence/webgl2-performance-optimization-20260728/private-metal-event-selector-20260729.txt).

The shader compiler had a separate cross-platform request mismatch.
LLDB/runtime captures of `MTLCodeGenServiceBuildRequest` proved that the chroot
request omitted the macOS active-platform argument, causing the iOS-hosted
service to emit an iOS MTLB rejected by the real macOS loader. The adapter now
requires both the chroot-only module-cache argument and working-directory
argument, replaces only the latter with a length-preserving
`-active-platform=macos`, and calls the real compiler. Both observed request
serializations and both authenticated service call sites are covered; compiler
results and loader validation are not bypassed. The MetalFE cache path is
translated to the service's runtime-confirmed writable rootless cache while
preserving each real libc operation and errno.

Finally, the command-error observer correlated Chromium errors with exact
retained submit serials. Selector `0x1e→0x1a` accepts an array of 0x38-byte
descriptor entries; inspecting only entry zero left later batched descriptors
untranslated. Walking every complete entry removed `0x103` and exposed two
strictly validated trailing-wrapper forms:

- a single subtype-1 command whose variable resource list ends with one
  0x18-byte wrapper-list record;
- two or more subtype-1/subtype-3 vendor segments followed by the same wrapper,
  including observed segment-list lengths below the former hard-coded 0x250
  threshold.

The retained pre-submit KCMD and segment lists prove the ranges and list magic;
the translator validates those complete invariants and updates every affected
range after compaction. The formal run reached more than 18,000 submit
observations without a command-error getter entry. These subtype-1/subtype-3
deletions remain **temporary ABI-translation scaffolding**, not a field-level
semantic fix.

### Formal performance comparison

Both devices ran the same URL, 1000-fish preset, 1024x1024 drawing buffer,
five-second warm-up, and fifteen one-second samples of Aquarium's own
`g_fpsTimer.averageFPS`:

| Environment | Average FPS | Median | Min | Max |
|---|---:|---:|---:|---:|
| iPad13,6, chroot VS Code/Chromium 148, native AGX | 14.4 | 14 | 11 | 18 |
| MacBook Air M1, local browser | 60.07 | 60 | 60 | 61 |

The measured iPad rate is 23.97% of the M1 rate; M1 is 4.17x faster in this
comparison. The M1 result is display-refresh capped, so the ratio is a lower
bound on the uncapped performance gap. The iPad's render loop also starved
ordinary timers/CDP work while continuing to draw at 11-18 FPS. The reusable
harness therefore samples from the page's actual per-frame `g_fpsTimer.update`
callback and publishes only after the full interval; it does not count the
post-measurement stopped frame.

The initial blank VS Code workbench was not an AGX failure. A one-second system
sample found Electron's main thread in
`OptimizingCompileTaskExecutor::WaitUntilCompilationJobsDoneForIsolate` for
every sample while the launch plist forced three `--no-concurrent-*` V8
switches. Removing those diagnostic switches restored the renderer, GPU and
CDP processes while retaining production JIT and the existing W^X adapter.
The exact samples, screenshots, CDP version, complete iPad log, and clean-stop
record are in the evidence directory above; the harness is
[`misc/cdp_aquarium_benchmark.mjs`](../misc/cdp_aquarium_benchmark.mjs).

## 2026-07-28: uncapped M1 curve and Chromium presentation-backpressure attribution

The old M1 1,000-fish result was refresh capped and materially understated the
gap.  A new five-second-warm-up/ten-sample sweep stayed at 60 FPS through
10,000 fish, then measured 47.0/33.9/26.6/21.5 FPS at
15,000/20,000/25,000/30,000 fish.  The 15,000-fish point is the first fair,
non-refresh-capped M1 comparison workload.

On the iPad, reduced-diagnostic 1,000- and 5,000-fish runs measured 15.2 and
15.47 FPS, while a clean 100-fish control measured 13.0 FPS.  The selected
fish index and per-species draw-table counts were read directly from the page;
the 15,000-fish control summed to exactly 15,000.  Fixing the cancelled-swap
pace at 16.667 ms did not improve 1,000 fish (14.6 FPS).  A native chroot
CoreVideo probe separately reported 119.952 Hz nominal and 114.74 measured
callbacks/s, ruling out both tested clocks as the fixed approximately 15-FPS
limit.

An eight-second sample of Chromium's actual GPU process found its main thread
in the run loop for roughly half the samples; the active path was principally
`GL_DrawElements`/AGX state encoding.  Selector translation appeared on the
Metal submit queue but was not the dominant sampled CPU path.  This is direct
runtime evidence that normal Chromium presentation/backpressure, not a
15-Hz CoreVideo source or a fully saturated KCMD translator, is pacing the
low-load result.

The exact Chromium 148 framework contains its diagnostic
`disable-frame-rate-limit` and `disable-gpu-vsync` switches.  With both enabled,
a bounded 100-fish run completed 999 rAF callbacks in about five seconds
(199.13 callbacks/s, page average 220 FPS) without 0x102/0x103 in that run.
That proves the page and native AGX are not intrinsically capped at 15 FPS.
It is not a shippable fix: a separate run produced repeated real
`00000102:Internal Error` completions, GPU-process CPU exceeded one core, and a
15,000-fish diagnostic still measured only 12.6 FPS.  Both switches and all
error/flight-recorder sentinels were removed, VS Code was unloaded, and the
device was returned to iOS.

Full samples, the CoreVideo probe, the GPU-process sample, and verbatim 0x102
lines are in
[`docs/evidence/webgl2-performance-optimization-20260728/`](evidence/webgl2-performance-optimization-20260728/).
The next optimization must fix the presentation/in-flight-work and temporary
KCMD/resource-lifetime interaction rather than bypass Chromium's limiter.

## 2026-07-28: validated submit wrapper, cold thermal control, and same-VS-Code M1 baseline

The retained low-disturbance submit ring captured Chromium's first unthrottled
failure. Submit serial 2 returned Metal command error `0x102` when its validated
KCMD contained a subtype-1 span plus two 0x18-byte wrapper records and the
segment's trailing wrapper was not translated. Enabling the already-bounded
wrapper translator removed observed `0x102`, `0x103`, and `0x0a` errors during
the benchmark run. It improved 15,000-fish rAF throughput from approximately
23.6 to 32.7 callback/s, about 39%. The byte deletion remains explicitly
diagnostic ABI scaffolding until the producer and kernel parser fields are
semantically named.

The recorder now uses a fixed 1024-entry memory ring and performs no producer
allocation, mutex acquisition, or file I/O. It freezes and writes evidence only
after the first observed completion error. The experimental start path enables
this recorder and the validated direct/wrapper KCMD sentinels, while leaving
the old heap-allocating deep recorder off the hot path.

A new CDP runner then measured a genuinely GPU-heavy control: Aquarium at
60,000 fish, fixed 1024x1024, eight-second warm-up, and fifteen-second wall-time
sampling. The cold, unlocked iPad reached 8.828 rAF callbacks/s. The M1 reached
36.722 in Chrome 150 and 37.679 in the official VS Code 1.130.0 build, which
uses the exact Electron 42.6.0 / Chromium 148.0.7778.280 version present on the
iPad. The same-version gap is therefore 4.27x, and browser-version mismatch is
runtime-disproved as the principal cause.

The iPad thermal sampler stayed `Nominal`. Its GPU requested and entered bins
through 1278 MHz, while active residency remained only about 15-21%. This
runtime-disproves heat, screen lock, and a fixed minimum-frequency request as
the primary cause of the controlled gap. The GPU-process sample instead shows
the command-generation path consuming roughly one CPU core while the GPU is
underfed. An identical one-billion-iteration native integer probe measured
348.926 million iterations/s on the M1 and 355.029 million/s on the iPad, so gross
single-core integer throughput is also ruled out.

There is one remaining correlated user-driver difference. The identical
Chromium/ANGLE `libGLESv2` offsets feed the macOS 13.4
`AGX::ArgumentTable` render-state encoder on the iPad, while macOS 26.3.1 uses
`AGX::G13::CommandEncoding` and `FixedLayoutUserArgumentTable` on the M1.
Actual iOS 16.3 AGXG13G disassembly also confirms that the effective queue
priority at `AGXCommandQueue+0x44c` is propagated into its channels and
firmware state, so treating the observed foreground queue as a silently
ignored background priority is not supported. Neither observation yet proves
the encoding path is causal; the next experiment must isolate per-draw CPU
cost or test a kernel-matched iOS AGX user driver without bypassing protocol
validation.

The exact benchmark values, thermal/DVFS lines, AGX symbols, and priority
disassembly are in
[`docs/evidence/webgl2-performance-optimization-20260728/`](evidence/webgl2-performance-optimization-20260728/).

## Next milestones

The final GlassDemo/native-AGX/VNC/blur target above is complete. Remaining
items are hardening and application-coverage work:

1. Extend the completed 225-second, 20-click GlassDemo soak to a substantially
   longer thermal/resource run. If the historical 1140x798 fault
   reappears, recover its actual GPU fault VA from a kernel gpuEvent or capture
   the second-level descriptor/buffer contents referenced by that KCMD;
   selector 0x107 and the 0x20-byte userspace completion record are ruled out.
   Keep the exact-dimension recorder and do not substitute a recovered
   2388x1668 display composite for a 1140x798 control.
2. Replace subtype-1/subtype-3 byte deletion with a field-level translator
   backed by disassembly of both macOS producers and the iOS kernel parser;
   reproduce the VNC frame without `/tmp/macws_kcmd_fix`.
3. RE the SystemStatus/NSXPC `objc_msgSend` SIGBUS using the saved reports and
   the project's early-attach LLDB tooling; do not globally bypass XPC or
   Objective-C release/encoding.
4. Replace the opt-in cancelled-swap completion shim with a production-quality
   coexistence completion model, then repeat a substantially longer VNC/blur
   soak.  The catastrophic IOSurface accumulation is fixed; the remaining
   requirement is protocol confidence rather than process-uptime evidence.
5. RE Terminal's close-cleanup lock from the captured `__close` stack, then
   add scroll/right-click semantics to the target-process input route. The
   retained native VNC text-entry witness is now complete.
6. RE Activity Monitor and Finder's actual startup actions before adding any
   launch hook; do not guess selectors or force startup-success branches.
7. Replace the full-display snapshot with a window registry and
   producer-owned IOSurface ring so each macOS window can become an independent
   iPadOS scene.
8. Close the remaining 4.27x same-VS-Code WebGL2 gap. The low-load
   presentation ceiling and first unthrottled `0x102` are now isolated; the
   validated wrapper translator removes the observed command errors and gives
   a 39% 15,000-fish gain. The corrected private event path now completes
   explicit GPU queries with a 0.377-ms median while rAF remains tens of
   milliseconds, so trace Chromium in-flight/presentation waits and correlate
   them with WindowServer completion timestamps. Then compare the current
   macOS 13.4 AGXMetal producer with the kernel-matched iOS 16.3 producer before
   considering a user-driver substitution. Do not ship the byte-deletion
   translator, frame-limit flags, or forced priority as a production fix.
9. Extend the completed Chromium 148 WebGL2 result to additional modern
   WebGL/WebGPU feature probes. Fix the synchronous `gl.getParameter`/CDP
   starvation path before treating browser developer tooling as usable, and
   keep the still-temporary KCMD translation visible in every browser
   stability claim.

## 2026-07-29: complex source compiler path fixed; event/presentation split

RE of the actual iOS 16.3 `MTLCompilerService` binary found that Chromium's
complex WebGL2 MSL took `_compileRequestMain` at `__TEXT+0x20e8`, not either of
the two previously covered XPC-handler calls. All three load the same real
service-vtable +0x18 build function. The UUID-locked patch now validates and
redirects those three authenticated indirect calls into one target adapter;
it does not replace compiler results or loader validation. A standalone probe
returned a real `_MTLLibrary`, and VS Code/Chromium's 7,366-byte source built
an accepted 9,184-byte `air64-apple-ios19.0.0-macabi` reply instead of the
rejected `air64-apple-ios16.3.0` library.

The presentation limit was then retested with a fresh WindowServer log, VNC
disabled, the device unlocked, Thermal pressure `Nominal`, and both the
sentinel and completion-hook log proving `interval=16667 us`. The 512x512 fill
control still reached only 16.756 callbacks/s with a 62.012-ms average rAF
interval, so neither a stale 100-ms pace nor current thermal throttling is the
cause of the 15–17-FPS ceiling.

The private event contract is now reconstructed rather than bypassed. macOS
13.4 uses selector 0x18; live iOS 16.3 code uses 0x14 with the same
zero-input/two-output ABI and object-field stores. Translating only that
selector returns real `_IOGPUMetalMTLEvent` instances. A post-fix VS Code run
completed 64/64 explicit GPU timer queries, left zero pending, and measured a
0.377-ms GPU-time median without invoking the shared-event fallback. Its rAF
median was still 39.8 ms, so the active blocker is now presentation/in-flight
scheduling rather than event creation or fragment execution. This is a
bounded run; a deferred external debug command stopped the GUI after the JSON
had returned, so it is not a long-soak witness.

## 2026-07-29: raw VS Code WebGL2 reaches 94.9% of M1; presentation isolated

The event fix enabled a same-build, same-workload GPU-timed comparison between
the iPad and M1. Official VS Code 1.130.0 / Electron 42.6.0 / Chromium
148.0.7778.280 issued 1,000 WebGL2 draws per batch. With setTimeout(0) driving
the next batch instead of requestAnimationFrame, the iPad completed 391/391
queries at 191,788.885 draws/s; the M1 completed 409/409 at 202,055.133
draws/s. The iPad therefore reached 94.919% of M1 wall throughput and 91.063%
of its CPU issue throughput. Its GPU timer p50 was 0.321750 ms versus 0.375375
ms on M1. The iPad log had zero event fallbacks and zero command errors, and
its post-test thermal state was `Nominal`.

Under the real visible-frame rAF path, the iPad reached only 20,345.233
draws/s versus M1's 48,805.883, or 41.686%. Median callback intervals were
49.3 ms and 16.7 ms respectively. Changing only the producer to timeout made
the iPad 9.43x faster, while every GPU query still completed. This
runtime-confirms that native AGX command generation/execution is now close to
the M1 target for this microbenchmark; the large remaining user-visible gap is
in Chromium/WindowServer visible-frame and in-flight presentation scheduling.
Exact inputs, distributions and bounded-test limitations are recorded in
[`presentation-scheduler-split-20260729.txt`](evidence/webgl2-performance-optimization-20260728/presentation-scheduler-split-20260729.txt).

## 2026-07-29: generation-3 Chromium and native-layout WindowServer wrapper

The first failing latest-VS-Code submit proved that its trailing segment-list
wrapper generation is not fixed at 2: both the outer and trailing records were
3 while all other framing remained unchanged.  Replacing the literal check
with a bounded 2/3 equality invariant restored a controlled 1,539/1,539-query
WebGL2 run at 191,456.011 draws/s with zero command errors.

WindowServer had a separate leading-wrapper failure.  The project LLDB saved
an iOS-native PF550 command as direct 0x820-byte subtype-1 plus a direct
0x130-byte segment list.  WindowServer's failing normalized command retained a
0x10 type-9 wrapper, a wrapper-specific 0x18 suffix, and a matching 0x18 list
wrapper, then returned real IOGPU ProtectionViolation completions.  Translating
that exact validated form to the captured iOS layout produced zero protection
errors, 6,600 clean VNC-copy completions, a full 2388x1668 Terminal frame, and
visible acknowledgement of all 16 VNC keyboard events.

This is also the strongest current thermal attribution.  The error loop drove
roughly 75-88% WindowServer CPU; after removing it, CPU declined to 43.4% by
bounded cleanup and battery temperature was 29.59 C.  Remaining compositor
cost is still material.  Screen lock remains an unmeasured confounder, but it
cannot explain the whole rAF gap because the earlier unlocked,
Thermal-Nominal control still had a 49.3-ms median.  Full evidence is in
[`windowserver-wrapper-generation3-20260729.txt`](evidence/webgl2-performance-optimization-20260728/windowserver-wrapper-generation3-20260729.txt).

## 2026-07-29: current Chrome 150 launches, renders WebGL2, and accepts VNC input

The target was moved from the earlier Chromium 148/VS Code coverage to the
current broad-stable official Google Chrome 150.0.7871.187 arm64 build.  Its
main Framework and independently embedded optimization-guide PartitionAlloc
copies both required complete UUID-locked pool-geometry ports; neither failure
trap was bypassed.  The secondary 1-GiB-core port removed the real
`HandlePoolAllocFailure` BRK at library +0xb4a7a8 (x2=12/ENOMEM after the
primary allocator had reserved 24 GiB).

A fixed-PID experimental coexistence run then produced a full 2388x1668 Chrome
window over VNC.  CDP identified the exact build, WebGL2 visibly rendered a
Metal canvas, and two controls completed 205/205 and 115/115 real GPU timer
queries.  The final control's log window had native AGX command translations,
eight event selector 0x18 -> 0x14 calls, and no command-buffer error or
ProtectionViolation.  Repeated selector 0x19 -> 0xe00002c2 returns remain an
explicit unresolved RE item; the test also remains dependent on the labelled
experimental WindowServer command/completion scaffolds.

VNC input initially failed for a separate, runtime-confirmed reason:
AppInputBridge only created per-process endpoints for four older test apps, so
Chrome fell through to a global CGEvent route even though macwsinputd had
measured postAccess=NO.  Registering only the main `Google Chrome` process and
restoring AppKit's normal make-key/activate actions before the NSEvent pair
made a controlled DOM probe change from clicks=0/text empty to clicks=1,
text=`vncinput150187`, active element=`field`.  Renderer and GPU helpers remain
excluded to avoid ambiguous endpoint selection.  Full hashes, counters, A/B
logs, and bounded-test limitations are in
[`chrome150-secondary-partitionalloc-20260729.txt`](evidence/chrome150-secondary-partitionalloc-20260729.txt).

## 2026-07-29: Chrome 150 event destruction uses the native iOS selector

The remaining repeated Chrome 150 `IOConnectCallMethod` selector 0x19 failure
was resolved at the protocol boundary.  Live method bytes from the exact
macOS 13.4 and iOS 16.3 IOGPU images prove that
`-[IOGPUMTLEvent dealloc]` uses the same one-scalar ABI but selector 0x19 on
macOS and 0x15 on iOS.  The adjacent constructor pair is 0x18 and 0x14.  The
new 0x19 -> 0x15 mapping therefore completes the event lifecycle instead of
suppressing destructor errors.

A forced-release standalone chroot probe logged the translated destroy call
returning zero.  The current broad-stable Chrome 150.0.7871.187 then completed
91/91 WebGL2 timer queries and 9,100 draws; the isolated log window had eight
sampled create successes, eight sampled destroy successes, zero selector 0x19
failures, and no command-buffer or protection error.  Raw GPU time remained
sub-millisecond while median rAF interval remained 78.5 ms, so presentation
pacing—not event lifetime—is still the next performance target.  Exact bytes,
hashes, counters, and the external-test-interference boundary are in
[`chrome150-event-lifecycle-selector-20260729.txt`](evidence/chrome150-event-lifecycle-selector-20260729.txt).

## 2026-07-29: system menus close the input-to-frame loop

The system-wide OSXvnc path was already delivering correct AppKit event types,
but the native-all branch returned before requesting a shared-frame
observation.  Runtime captured VS Code receiving secondary NSEvent types 3/4
with `pressed=0x2` while the VNC client remained on the pre-menu framebuffer;
the next hover exposed the already-open menu.  Pointer activity now requests
an early real WindowServer observation plus a settled observation after button
transitions.  The producer still publishes only stable compositor output.

A stricter client-side test also corrected the earlier arbitrary-region-change
criterion: it now synchronizes a post-Escape full baseline and retains later
incremental updates before judging the screenshot.  Terminal then completed a
menu open, four distinct hover states and close (6/6), with complete menu rows
and blue hover output in the retained 2388x1668 frames.

That test exposed one separate right-click race.  Failed runs returned both
rightDown/rightUp through ordinary `NSApplication sendEvent:`; successful
runs entered NSMenu's nested tracker on rightDown and consumed rightUp there.
Serializing only the RFB secondary release by 120 ms retained the original
system `CGPostMouseEvent` owner and produced five visibly complete contextual
menus in five isolated rounds.  Open latency was still 0.290-1.021 seconds and
WindowServer remained around 48% CPU in a live sample, so responsiveness and
presentation cost remain open.  Exact logs, screenshots, JSON and the
per-process-vs-system input ownership boundary are recorded in
[`vnc-usability-stability-20260729/README.md`](evidence/vnc-usability-stability-20260729/README.md#7-system-input-is-not-complete-until-its-windowserver-frame-is-published).

A cross-process control restarted the real VS Code 1.130.0 workbench and
visually confirmed both its WindowServer-owned File menu (open/hover/close
3/3) and its Electron editor-tab contextual menu (open/close 2/2).  Their
first-change latencies were 0.251-0.626 seconds.  This validates the single
system-event owner across AppKit and Electron.  A repeat after the final
OSXvnc rebuild remained visually correct but required 1.037 seconds, leaving
the latency/WindowServer CPU milestone explicit.

The next input-timing pass split a 1.314-second raw contextual-menu result into
0.521 seconds before first readable RFB data and 0.790 seconds in receive/decode
for 3.64 MiB of rectangles.  It also found an ordering error in the new
transition observations: a 180-ms right-down observation was cancelled by the
serialized 120-ms right-up.  Moving it to 80 ms produced an actual down-state
observation before release and five visibly complete VS Code contextual menus
in five repetitions.  Open latency remained 0.580–1.293 seconds (median
0.781), so this fixes ordering but not the transport tail.

A proposed wakeup for the historical 200-ms PF550 retry thread was removed
after runtime disproved its relevance: the current session continuously used
the owned-BGRA publisher, never created the PF550 wake socket, and emitted no
successful wake datagram.  Full lifecycle testing also reconfirmed that plain
`start coexist` is currently non-Retina `share=0`; native 2388x1668 VNC still
requires `start coexist --experimental`.  These timing distributions and the
productization boundary are recorded in
[`vnc-usability-stability-20260729/README.md`](evidence/vnc-usability-stability-20260729/README.md#9-secondary-down-observation-and-remaining-rfb-latency).

## 2026-07-29: one system input owner covers menu bar, nested menus and drag

VNC input is now deliberately owned by one system-wide CoreGraphics stream,
not broadcast through every process-local AppInputBridge endpoint. This
ownership boundary is required for WindowServer's menu bar, nested NSMenu
trackers, cross-process contextual menus and NSWindow title drag. AppInputBridge
remains the native-host/process fallback and now provides observational mouse
entry/return timing even in Electron processes that realize NSApplication
after injection. The GUI lifecycle also starts the real macOS pboard and pbs;
launchd runtime-confirmed an active `com.apple.pbs.fetch_services` endpoint.

The current deployed build visually completed a Terminal contextual menu in
0.295 seconds, opened Shell in 0.298 seconds, switched Shell to Edit in 0.028
seconds, and opened the nested New Window profile submenu. VS Code completed
three consecutive contextual-menu opens, its menu bar switched correctly, and
a Terminal keyboard burst visibly completed its command and output.

The remaining drag delay was independently traced to the real RFB encoder: one
pre-fix Zlib frame spent 1583.618 ms sending while copying the 3,983,184 pixels
took 1.868 ms. RE of the installed encoder established the Zlib/Tight
compression fields. Clamping only their work factor to level 1 reduced the
same visible title-drag completion from 1.949 to 0.485 seconds; the rendered
pixels, negotiated encoding and native-AGX path are unchanged. Live
intermediate title motion and occasional full-frame socket backpressure remain
open. Exact runtime logs and screenshots are in
[`system-wide-input-current/results.md`](evidence/vnc-usability-stability-20260729/system-wide-input-current/results.md).

## 2026-07-29: production runs no longer carry the RE flight recorders

The retained-symbol on-device build was unexpectedly compiling libmachook at
`-O0`: Theos selects that default whenever `STRIP=0`, even with
`FINALPACKAGE=1`.  Full and FAST builds now explicitly use `-O2` while keeping
LLDB symbols.  High-frequency AGX lifecycle, submit-ring, method-trace,
AppInputBridge and VNC flow instrumentation is also disabled by default and
can only be armed with `--experimental --diagnostics`.  Functional native-AGX
command/completion and owned-scanout compatibility remains enabled by
`--experimental` alone.

Startup readiness now uses a one-shot, PID-validated producer-completion file
instead of depending on a removed diagnostic log line.  A bounded production
smoke produced a nonblack 2388x1668 Terminal frame with zero submit artifacts
and zero diagnostic sentinels.  iOS reported `thermal-state=nominal` before
and after both validation runs.  This establishes the measurement boundary;
the remaining short-run WindowServer CPU cost is explicitly still open.  The
exact runtime lines, codegen evidence and thermal rule are recorded in
[`debug-overhead-removal-20260729/README.md`](evidence/debug-overhead-removal-20260729/README.md).
