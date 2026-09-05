# Terminal rapid-input render coherency (2026-09-06)

## Result

Rapid typing and deletion in macOS Terminal now reach the Host-visible frame in
order.  The production change is deliberately limited to the exact Ventura
QuartzCore build and the exact IOGPU client-storage texture shape observed on
the target; it does not bypass validation or synthesize a buffer.

## Root-cause evidence

The tested QuartzCore binary is UUID
`CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC`.  `otool -tvV` identifies
`CA::OGL::MetalContext::update_image` at `0x187a2d750`.  Its client-storage
branch is:

```text
0000000187a2d9c0 ldurh w8, [x19, #0x7b]
0000000187a2d9c4 tbnz  w8, #0x9, 0x187a2d9f0
...
0000000187a2d9f0 bl    _objc_msgSend$didModifyData
0000000187a2d9f4 b     0x187a2db88
0000000187a2d9f8 ldr   x6, [x20, #0xa0]
...
0000000187a2da2c bl    _objc_msgSend$replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:
```

This is **RE-confirmed via QuartzCore UUID
CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC, image offsets
`0x6f9c0..0x6fa2c`**: flag `0x200` selects `didModifyData`; the adjacent path
copies the Render::Image bytes with `replaceRegion`.

At the Terminal update breakpoint (`update_image+0x270`) LLDB observed:

```text
x0  (texture)       = 0x11d09afe0
w24 (width)         = 0x474  (1140)
w23 (height)        = 0x2ae  (686)
[x20+0xa0]          = 0x1200 (4608 bytes/row)
[x19+0x78, 4 bytes] = 01 00 01 0a
[x20+0x98, 2 bytes] = 01 01
```

`image lookup` resolved the texture's `didModifyData` implementation to IOGPU
address `0x1bfb0bde0`; disassembly was a single `ret`.  This is
**runtime-confirmed on iPad13,6**: the compatibility texture accepted the
coherency message but performed no upload.

The causal A/B used QuartzCore's own two branches.  With the normal branch, a
20-ms `testme` burst produced a Host frame containing only `t`.  At the next
identical breakpoint, moving PC from `0x1aa3e59f0` to `0x1aa3e59c8` executed
the complete existing plane/mip checks and `replaceRegion` path; the next Host
frame contained the complete model value `testmeabcdef`.  This is
**runtime-confirmed via the LLDB branch A/B and Host captures
`/tmp/macws-normal-20.png` and `/tmp/macws-after-correct-explicit.png`**.

An independent ordering witness showed why cancelled IOMFB presentation must
not retire a backing generation immediately:

```text
#### DISPLAY-COMMIT-WITNESS end-update=1800 context=0x120309dd0 commandBuffer=0x107fc89d0 status=2
#### DISPLAY-COMMIT-WITNESS swap-end=1800 context=0x120309dd0 commandBuffer=0x107fc89d0 status=3 swapID=4752897
```

Status 3 is Scheduled, not Completed.  The production completion path now
waits for the exact submitted command buffer to reach a terminal Metal status
on one serial queue, then delivers the existing frame-info callback on the
main queue.  Current-generation runtime output includes:

```text
#### IOMFB GPU-FENCE ready #12000 swapID=4792439 commandBuffer=0x123b5d1e0 status=4 polls=4
#### IOMFB CANCEL-COMPLETION delivered #12000 swapID=4792439 client=9487 requested=7336538518742 presentation=7336538555043 delta=2403922 pending=1->0 commandBuffer=0x123b5d1e0
```

This is **runtime-confirmed via `/var/jb/var/mobile/WindowServer.err`**.

## Production implementation

`libmachook/Metal_hooks.x` hooks `update_image` only when all of the following
hold:

- process is WindowServer and `MACWS_AGX_NATIVE=1`;
- QuartzCore UUID and the six-instruction function prologue match;
- QuartzCore reused the same texture across the original call;
- the image has one plane and one mip level and flag `0x200`;
- the texture is a one-slice, one-mip, 2D managed IOGPU texture whose
  `didModifyData` implementation is the observed no-op;
- source pointer, dimensions, stride, and texture dimensions are valid and
  agree.

The original function runs first, preserving all QuartzCore bookkeeping.  The
hook then performs the missing explicit `replaceRegion` upload using the real
Render::Image storage.  A UUID/prologue mismatch fails closed.

`libmachook/mac_hooks.m` associates each cancelled swap with the command buffer
submitted by the matching `EndUpdate`.  It waits for status 4 or a terminal
error before reporting completion; it has no timeout that can manufacture a
successful completion while GPU work is pending.

## Device verification

The final source was built and installed with:

```text
THEOS=/var/jb/var/mobile/theos bash misc/build_on_ios.sh --fast-force
```

The current generation loaded the versioned hook and exercised alternating
backing textures:

```text
#### MACWS_AGX_NATIVE hooked QuartzCore client-storage update target=0x1aa3e5750 trampoline=0x102fe4000
#### MACWS_AGX_NATIVE client-storage upload #21 texture=0x12144b900 size=1140x686 bpr=4608 source=0x15d4cc100
#### MACWS_AGX_NATIVE client-storage upload #22 texture=0x123b6fcd0 size=1140x686 bpr=4608 source=0x15f270100
```

Single-run Host captures showed full `testme` after 20, 45, 80, and 120 ms
input intervals.  Deleting three characters showed exactly `tes`.  Relevant
SHA-256 values were:

```text
67db0372b3f14014403225d472acf88a7216c134c770e4a4e99b2f305d3efe0c  final-020
0e5833303e526100dbe6bb8e1db011256daac2f66759fa31f2cea9032feec6d5  final-045/080/120
c13bfd709d20be287f9be4e49886be6d33b68f879acdbd4735ec479d9171353a  final-delete
```

Ten additional runs alternating 20 and 45 ms produced the same complete
`testme` frame byte-for-byte:

```text
314a6cd05f5e5ca49015f5e03f6424e32102aa90dcbf31d60212760caa05c427  loop-0 .. loop-9
```

After the loop, the original WindowServer PID 70593 and Terminal PID 71052
were still alive.  The installed dylib contains none of the temporary
shmem/texture/final-snapshot diagnostic strings.
