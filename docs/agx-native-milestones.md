# AGX-native GUI milestones

This file is the durable hand-off log for the native-AGX path. It deliberately
separates runtime evidence, reverse-engineering evidence, and theories. A
process that merely remains alive is not a success witness; the final witness
is a VNC capture of GlassDemo with non-black content and a visibly rendered
`NSVisualEffectView` blur.

## Target

- Device: iPad13,6, iOS 16.3, arm64.
- Guest: macOS 13.4 chroot.
- Driver path: the real iOS AGX kernel driver (`MACWS_AGX_NATIVE=1`), not the
  MTLSim fallback.
- Final witness: GlassDemo title bar, controls, and backdrop blur visible in a
  captured VNC frame.

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

The one-argument `createUserGPUTask` implementation makes several calls and
never materializes an allocator-array value in `x4` before calling the task
initializer. That is static evidence that the count should be zero on this
specific iOS AGX path, but the exact native runtime value is still required:
the claim remains THEORY until LLDB captures it. Forcing options to zero
before that capture remains a diagnostic ABI translation, not a root-cause
fix.

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
The value is computed once and may still evaluate to zero on iPad13,6, but
that is THEORY pending the prepared LLDB trace. This correction is important
because it prevents treating the current high-word mask in
`IOServiceOpen_new` as a proven production fix.

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

## Native trace prepared

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
`/tmp/iosclear-native-iogpu` on the device and stops at the first render submit.
`misc/lldb_trace_iosclear_iogpu.lldb` drives the trace and emits a summary.

Local validation: the ObjC method, API-property function, and queue-create
function each resolve to one breakpoint location in the actual iOS 16.3
binaries. IOKit import breakpoints remain pending until IOKit loads, as
expected. Python bytecode compilation succeeds.

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

## Next runtime experiment

The device was unreachable at the end of this milestone (`No route to host` /
`Host is down`), so no new kernel log could be collected.

When it reconnects:

1. Run `misc/cleanup_all.sh` before restarting WindowServer and collect the
   existing AGX kernel log. Search specifically for `Failed to init work
   queue`, `create GTP`, `init GTP`, `create PM`, and `Render Target Memory`.
2. Run the early-held native `iosclear_ref` under the project LLDB trace and
   capture the exact service-open type/options, API property, queue QoS,
   priority byte, resource sequence, and first submit.
3. Compare those values to the chroot path. Change the earliest confirmed
   mismatch that feeds the failing work-queue stage; do not patch the raw-8
   exit or force a success return.
4. Use `/tmp/macws_stop_after_clear` for a single bounded WindowServer frame.
   Require `clear-control executed=YES`, a non-black control pixel, then run
   GlassDemo and capture the VNC blur witness.

## Success criteria

Intermediate control witness:

```text
VNC-FINAL clear-control executed=YES pixel=OK center=804020ff
```

Final witness: a saved VNC image showing GlassDemo's title bar and controls,
with background content visibly blurred through `NSVisualEffectView`. The
image path, checksum, WindowServer log, and the exact build commit must be
recorded here when achieved.
