# Native NoCopy producer: 2026-09-19

This is evidence for an upstream ABI adapter, not a completed production fix.
Only an owned native iOS process was observed. It mapped one page, made one
normal `newBufferWithBytesNoCopy:`, and released it. No user app was attached,
no macOS request was replayed to the kernel, and no persistent flag changed.

## Successful native producer (runtime-confirmed)

Raw receipt: `/tmp/macws-native-nocopy-layout-post-20260919.log`.
Actual IOGPU UUID: `02649166-8067-384C-820F-CE1C5EA0709E`.
The real `IOGPUMetalResource` method is image + `0x3d30`, with encoding:

```text
@44@0:8@16Q24^{IOGPUNewResourceArgs={IOGPUNewResourceData=IISSSSCCCCIQQQ(?={?=QQQI}{?=IIII[2Q]})}}32I40
```

In particular, `argsSize:` is a **32-bit unsigned integer**, not `NSUInteger`.
The probe validates this encoding before substituting its own process's method
table entry. The wrapper calls the original once, preserves the result and
`errno`, and restores the method in `@finally`.

Native buffer creation reported:

```text
NATIVE-RESOURCE sample=1 class=AGXG13GFamilyBuffer options=0 argsSize=96 snapshotSize=96 result=0x10450ff90
NATIVE-NOCOPY original=0x1042e4000 length=16384 buffer=0x10450ff90 contents=0x1042e4000 alias=1 callbacks-before-release=0 observations=1
NATIVE-DEALLOC pointer=0x1042e4000 size=16384 expected=1
```

The exact observed qwords, before and after the original initializer:

| Offset | Before | After |
|---|---:|---:|
| `00` | `0000000000000080` | unchanged |
| `08` | `0000000100010001` | unchanged |
| `10` | `0000004001000101` | `0000047001000101` |
| `18` | `0000000000000000` | unchanged |
| `20` | `0000000000000000` | unchanged |
| `28` | `0000000000000000` | unchanged |
| `30` | `00000001042e4000` | unchanged |
| `38` | `00000001042e4000` | unchanged |
| `40` | `0000000000004000` | unchanged |
| `48` | `0000000000000000` | unchanged |
| `50` | `0000000000000000` | unchanged |
| `58` | `0000000000000000` | unchanged |

This is type `0x80` with **no parent-resource bit** (`flags+0x15 & 8 == 0`).
Both `+0x30` and `+0x38` contain the original client address. Clearing either
is not the shape produced by this successful native NoCopy call.

The independent native full contract probe additionally passed late CPU
writes, a real GPU copy, alias identity, and deferred exactly-once deallocation:

```text
NOCOPY length=16384 original=0x100850000 contents=0x100850000 alias=1 cpu-late-write=1 premature-callbacks=0
NOCOPY status=4 error=none gpu-original-mismatch=0/16384 gpu-buffer-mismatch=0/16384 callbacks-before-release=0
NOCOPY callbacks-after-drain=1 callback-mismatch=0
NOCOPY contract=PASS
```

The initializer-only probe does not itself establish GPU correctness; the
separate full contract probe supplies that evidence.

## Producer-to-resource call (RE-confirmed)

The same actual native image's copied executable bytes are in
`/tmp/macws-native-nocopy-layout-post-20260919.log` and
`/tmp/macws-native-nocopy-resource-create-20260919.log`. Only 2048 bytes per
selected function were read, not a full shared-cache extraction.

`IOGPUMetalResource` common initializer preserves the input pointer in `x21`
and 32-bit size in `w22`. It updates flags, then forwards the same allocation
request to `IOGPUResourceCreate`:

```text
3e88 ldr w8, [x21, #0x14]
3e8c tst x23, #0x40000
3e90 mov w9, #0x430
3e94 movk w9, #1, lsl #16
3e98 mov w10, #0x430
3e9c csel w9, w10, w9, eq
3ea0 orr w8, w8, w9
3ea4 str w8, [x21, #0x14]
3eb0 mov w2, w22
3eb4 mov x1, x21
3eb8 bl IOGPU+0x6040
...
3f2c ldr x8, [x21, #0x30]
3f30 str x8, [x24, #0x80]
```

The last two instructions show that the native caller itself consumes `+0x30`
after resource creation. It is not an ignored padding slot.

`IOGPUResourceCreate` was resolved by `dlsym`, checked to belong to this same
image at `+0x6040`, and inspected without invoking it separately:

```text
605c mov x23, x2       ; preserve original input size
6060 mov x19, x1       ; preserve original input pointer
...
6100 ldr w0, [x24, #0x14]
6104 sub x8, x29, #0x40
6108 stp x21, x8, [sp, #-0x10]!
610c mov w1, #9
6110 mov x2, #0
6114 mov w3, #0
6118 mov x4, x19
611c mov x5, x23
6120 mov x6, #0
6124 mov x7, #0
6128 bl IOGPU-base+0x43cdae0
```

There are no input-argument writes in this function before that call. Thus the
successful producer forwards the same 96-byte request and selector 9, with an
`IOConnectCallMethod`-shaped ABI. **This is not a kernel breakpoint capture.**
The actual target is a shared-cache address not identified by `dladdr`, and is
not equal to public `dlsym("IOConnectCallMethod")`. The guarded diagnostic
declined to read the unresolved target because it did not satisfy its readable
and executable region checks. Raw result:
`/tmp/macws-native-nocopy-resource-call2-20260919.log`.

The separate static interpose observer for `IOConnectCallMethod` and
`IOConnectCallStructMethod` recorded no calls while the native contract passed.
That is observer coverage failure, **not evidence that type 0x80 is absent**.

## Comparison with macOS producer

The independent actual macOS IOGPU producer inspection is recorded in
`/tmp/macws-macos-buffer-producer-metadata-20260919.log` and
`/tmp/macws-buffer-{alignment,original}-metadata-20260919.log`.
Actual macOS IOGPU UUID: `CE2B5551-857F-3EDD-9E4F-435215CC8C27`.

That 104-byte producer contains an extra alignment/padding slot at `+0x30`:

| Meaning | macOS 104-byte request | Native iOS 96-byte request |
|---|---|---|
| Alignment and padding | `+30` | not present |
| Original address | `+38` | `+30` |
| Address alias | `+40` | `+38` |
| Backing span | `+48` | `+40` |
| Remaining tail | `+50..+67` | `+48..+5f` |

The macOS common initializer subsequently reads its original `+0x38` into the
object's `+0x80`, whereas native code reads `+0x30`. This supports translating
a **separate wire copy**, preserving the caller-owned macOS request unchanged.
The final macOS tail's semantics are not established; deleting the alignment
slot must preserve the remaining bytes rather than inventing zeros.

No production translation was changed by this investigation. Acceptance for a
future adapter still requires the actual full alias/late-write/GPU/deallocator
contract in both architecture slices, followed by real Office visible output.

## Diagnostic validation

`misc/test_nocopy_native_layout_probe.py`: two tests pass. The executable host
test calls the actual wrapper with an owned CPU-only fixture and checks all
original arguments, original return value, original `errno`, no additional
argument mutations, and exactly eight recorded calls despite ten invocations.
The native source builds with `-Wall -Wextra -Werror`, explicit iPhoneOS 16.5
SDK, and an iOS 16.3 deployment target. All device probes exited; there is no
daemon, persistent flag, production target dependency, or user-app attachment.
