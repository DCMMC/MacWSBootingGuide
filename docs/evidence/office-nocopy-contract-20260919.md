# Office pictures: CPU bitmap to Metal no-copy contract

## Latest status: real PowerPoint and Word image acceptance PASS

Two independent upstream contracts were broken: normal NoCopy allocation
lost its original CPU alias/lifetime, and Office's bundled macOS-target AIR
failed real function specialization with `Target OS is incompatible`.
The NoCopy-only result below was correctly recorded as insufficient. After
adding the complete, verified AIR translation, actual application output—not
just a primitive probe—now passes the following owned-document checks:

- PowerPoint **46376**, mapped candidate
  `92820A6A-B26E-391F-899C-786575CEE126`: the actual Welcome slide3 shows its
  pictures and the thumbnail pane shows orange backgrounds and picture
  content. `/tmp/macws-ppt-shader-routed-slide3-20260919.png` was visually
  inspected. The bounded real shader observer shows eight non-nil bitmap
  specializations with no error, including `bitmapVS`, `bitmapPS`,
  `bitmapIgnoreSrcAlphaPS`, `bitmapCubicPS`, and `bitmapIgnoreSrcAlphaCubicPS`.
  Receipts: `/tmp/macws-ppt-shader-routed-20260919.log` and
  `/tmp/macws-ppt-shader-routed-open-20260919.log`.
- Word **46877**, newer exact-Data-routing candidate
  `03558D10-1BA7-3C07-A680-761E6281E60E`, `__text` SHA-256
  `7078b6aedbf37a07e30934179ac775028b7acc65bfeb360c9d25f175729a782c`:
  the owned document's illustrated toolbar and menu pictures are visible at
  162% zoom in `/tmp/macws-word-contract-images-20260919.png`, visually
  inspected. This instance did **not** load the diagnostic shader observer.
  Its mapped-image/open receipt is
  `/tmp/macws-word-contract-open-20260919.log`.

Excel acceptance is still pending at this checkpoint. The original unsaved
PowerPoint19000 remains on its older loaded generation; its black thumbnails
visible behind the new Word window are not evidence about the new Word/PPT
test generation, nor a reason to close the user's document. These are bounded
picture/thumbnail checks, not a claim that every Office drawing mode or a
full production cold-start package has already been verified.

See [the exact library-target failure and correction](office-metal-library-target-20260919.md)
for original/transformed artifact hashes, all28-module IR comparison, and
actual GPU pixel results.

## Historical 20:33 checkpoint: primitive repaired, Office acceptance still FAIL

The isolated candidate preserves the original initializer, pointer, options and
deallocator. A stack-linked TLS scope limits the separate 104 -> 96 byte wire
translation to the verified normal, unpinned Shared/Managed NoCopy producer.
The version guard matches AGX `727C250E...` initializer `+0x1f4bb4`, IOGPU
`CE2B5551...` initializer `+0x1c24`, and actual kernel build `20D67`.
The original record is never changed. Native request fields retain both CPU
addresses, the real span and all unknown tail bytes. The legacy resource
heuristics are skipped for this request, but the real call, result and resource
accounting are not bypassed. Failure does not fall back to a detached copy.

Runtime-confirmed via `/tmp/macws-nocopy-isolated-validation-20260919.log`
and `/tmp/macws-nocopy-isolated-gpu-20260919.log`:

- arm64 candidate UUID `92820A6A-B26E-391F-899C-786575CEE126`, signed SHA-256
  `2449aef4211ef2597f8a479d17d6c6ed549f47651f6fb842317cf6c3826c0a72`;
- arm64e candidate UUID `D9FC93CB-734C-3906-8162-D10F4AB85B0E`, signed SHA-256
  `5aa79380d7d9571c85e8701ae24327cbf29c49cb99e4e9a64155b32353772f05`;
- both slices, Shared and Managed: allocation-only alias/lifetime checks PASS
  first, without creating a command queue;
- then both slices, Shared and Managed: full GPU fill checks PASS, actual
  storage mode unchanged, alias=1, late CPU write=1, original and buffer pixel
  mismatches=0/16384, real command status=4, callback before release=0, after
  release=1. No flags, retries, respring, or production library replacement.

Example from the real Managed run:

```text
NOCOPY length=16384 original=0x1004c8000 contents=0x1004c8000 alias=1 cpu-late-write=1 premature-callbacks=0 requested=managed actual=1 storage-match=1
NOCOPY status=4 error=none gpu-original-mismatch=0/16384 gpu-buffer-mismatch=0/16384 callbacks-before-release=0
NOCOPY callbacks-after-drain=1 callback-mismatch=0
NOCOPY contract=PASS
```

**At this checkpoint this was not a completed Office repair.** Owned PowerPoint PID **36001** was
launched without extra diagnostics using the arm64 candidate above. The
read-only mapped-image helper confirmed its UUID and `__text` SHA-256
`12280a7b28ffd4bdbda4c97e80995275ffa4eae314238f07bc82cb0dbcd9475f`.
Its exact ABI6 AppKit transaction accepted the unchanged Welcome fixture and
created window **148**. Actual native iPadOS captures were inspected:

- `/tmp/macws-ppt-nocopy-initial-20260919.png`: slide 1's main orange
  background/text are present, but its thumbnail is blank white;
- `/tmp/macws-ppt-nocopy-slide3-20260919.png`: all four pictures still absent.
  Thumbnails are now white instead of black but lack background shapes/images.

Thus the shared-memory contract repair is necessary on its own merits but
insufficient for the observed Office rendering failure. The next measurement
must join actual CPU draw pixels to the upload and real GPU completion; it must
not declare success from a non-null image, a primitive PASS, or changed colors.
Original user PowerPoint PID19000 and Terminal PID17280 were not closed or
sent document/quit events. Canonical installed libraries remain unchanged.

The pure-header overlap guard/extern-C portability edits were added after this
candidate build; the exercised production wire copy never overlaps its source.
They require inclusion in the next candidate, not a claim that this UUID
contains later source edits.

## Earlier investigation

### Actual Office shader specialization fails independently

The tiny control was extended to load the **exact unmodified Office resource**,
155074 bytes, SHA-256
`9eac296d60f976a0ef4e1cfe90b440101045b4eaed437af3a6dd803997959a02`.
The embedded `bitmapVS`/`bitmapPS` AIR defines the actual buffer/texture layout;
the control sets the required `hasStencil` function constant at index0 to
false, with valid independent geometry, opacity1 and a NoCopy image texture.
The same control renders correctly on the local native Mac. On the device's
isolated candidate the actual run reports:

```text
shader-library=non-NIL error=none
office-function-constant name=hasStencil index=0 type=53 required=1
office-specialize name=bitmapVS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible." UserInfo={NSLocalizedDescription=Target OS is incompatible.}
office-specialize name=bitmapPS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible." UserInfo={NSLocalizedDescription=Target OS is incompatible.}
shader-render-contract=FAIL
```

Runtime receipt: `/tmp/macws-office-actual-bitmap-shader-20260919.log`.
This is a real upstream failure **before pipeline creation**, unlike the
successful small source-shader controls. It does not yet identify the exact
internal error producer or prove every Office picture uses the same failed
specialization. The next check is an actual app-library specialization witness
and a correctly translated complete-library control, not a bypass of the check.

The v4 owned PowerPoint42950/window225 run provides complementary negative
coverage: all four real full-size CPU images/views were created, but the
installed render/pipeline observers saw no matching bitmap pipeline or image
fragment binding. The inspected capture
`/tmp/macws-ppt-upload-v4-slide3-20260919.png` still lacks all four pictures and
thumbnail shapes. That absence alone cannot prove specialization failure in
the app. Its log is `/tmp/macws-ppt-upload-v4-observed-20260919.log`.
The process was normally quit and its PID disappeared; user PowerPoint19000
and Terminal17280 remained alive.

### Subsequent direct-view and shader controls

Runtime-confirmed via `/tmp/macws-ppt-upload-v3-observed-20260919.log`:
owned PowerPoint PID39633 actually uses the direct buffer-texture alternative.
For the full 309x250 picture, the returned texture has format70 (RGBA8Unorm),
type2, storage1 (Managed), usage1, one mip/sample, offset0 and row1248. Its
parent buffer is the observed 327680-byte NoCopy allocation. All four full-size
views have the expected geometry. No corresponding image-buffer blit was
observed. This resolves the earlier v2 coverage gap; it does not establish the
final raster output. This owned process was normally quit, preserving user
PowerPoint19000 and Terminal17280.

The independent `misc/macws_texture_sampling_probe.m` then exercised both true
GPU compute sampling and a separate quad/fragment-render path, not just texture
`getBytes` or a blit. Source format70/type2/usage1 and the observed 309x250,
1248-byte rows were used. Original mmap bytes were written **after** NoCopy
creation; Managed used its real `didModifyRange:`. Native Shared and candidate
Managed both reported:

```text
phase=read status=4 error=none
phase=read mismatched-pixels=0/77250 mismatched-bytes=0/309000
phase=sample status=4 error=none
phase=sample mismatched-pixels=0/77250 mismatched-bytes=0/309000
phase=render status=4 error=none
phase=render mismatched-pixels=0/77250 mismatched-bytes=0/309000
render-modified-padding=0
callbacks-after-drain=1 callback-mismatch=0
```

The pixel comparison includes varied alpha and unchanged row padding. The
render control uses a Shared RGBA8 target, explicit viewport/scissor, no
blending, one queue/one submission, at most 983040 bytes of explicitly owned
pixel storage and a ten-second process alarm. It uses a small source shader,
**not Office's actual precompiled bitmap shader or its complete render state**.
The real Office screenshot failure therefore remains unresolved.

Receipts: `/tmp/macws-nocopy-office-shader-sampling-20260919.log` and
`/tmp/macws-nocopy-office-fragment-render-20260919.log`. Candidate UUID remains
`92820A6A-B26E-391F-899C-786575CEE126`. The plain Managed compute control also
passed, but its current adapter returned storage0; do not report that control
as preserving Managed storage. The NoCopy controls did preserve storage1.

### Subsequent actual-image join and stride negative control

Owned diagnostic PowerPoint **37718**, window186, loaded the same verified
candidate plus the process-only `macws_office_upload_observer` v1. It was
normally quit afterward; user19000 remains untouched. The actual full-size
draw in `/tmp/macws-ppt-upload-observed-20260919.log` joins to its NoCopy call:

```text
OFFICE-BITMAP pid=37718 sample=6/8 image=309x250 context=0x113a09e40 data=0x113d00000 size=309x250 stride=1248 bpc=8 bpp=32 bitmap=0x4005 alpha=5 span=312000 read=312000 fnv64=e11cc54decd496aa prefix16=ffffffffffffffffffffffffffffffff nonzero=309000 alpha-offset=4294967295 alpha-samples=0 alpha-nonzero=0 rect=[0,0,309,250]
OFFICE-UPLOAD phase=before pid=37718 sample=4/8 draw=6 device=0x145894800 bytes=0x113d00000 length=327680 options=0x10 deallocator=0x16bbd3d70
OFFICE-UPLOAD phase=after pid=37718 sample=4/8 draw=6 result=0x142089df0 contents=0x113d00000 storage=1 alias=1 errno=3
```

All four full-size CPU draws have nonzero pixels. The two premultiplied-alpha
images have nonzero alpha at every sampled pixel. Full-size 284x102, 309x250,
471x56 allocations are joined to real alias=1 Managed Metal buffers. The
282x28 allocation reused a buffer seen during its earlier scaled draw, so no
second construction was required/observed. This is evidence of correct CPU
draw and matching buffer identity, not yet of their GPU texture contents.

The first eight completed-command callbacks reported status4/error=nil, but
their budget was consumed during scaled startup drawings, **before** the
full-size images. They are not attributed to all four full-size uploads.
The inspected `/tmp/macws-ppt-upload-observed-slide3-20260919.png` still has
missing pictures/thumbnail shapes: acceptance remains FAIL.

**THEORY tested and not reproduced:** actual row alignment might distinguish
the failing Office path from the padded synthetic control. Office's 309x250
bitmap uses 1248-byte rows, while the original control used 1280. The strict
`nocopy-buffer-copy ... --office-row-stride` diagnostic now uses the actual
1248-byte source stride and 312000-byte image span, page-rounded327680-byte
NoCopy allocation, and independent1280-byte output stride. It writes only
the original mmap after creating NoCopy, then blits to a texture and back.

Runtime-confirmed in `/tmp/macws-nocopy-office-row-control-20260919.log`:
native iOS Shared and candidate macOS Managed both completed upload/readback
with status4, GPU and getBytes mismatch0/77250, untouched output padding and
one correctly timed deallocator. Stock macOS Shared/Managed controls pass too.
The previously tested1280-row candidate also passes. Therefore no production
row-alignment workaround was added; the actual Office blit/texture shape and
its downstream sampling still need observation.

Status at this checkpoint: **actual Office call chain identified and a separate
no-copy primitive contract failure reproduced; not yet an accepted Office
repair**. No production code or running
application was changed by this review. A buffer-identity experiment is a
separate test, not a substitute for the four missing pictures and thumbnails.

## Provenance and change boundary

The examined installed Office 16.91 `mso40ui` arm64 image has UUID
`08F30267-C97A-30FB-A4BB-43186407CDB2`. Offsets below are relative to that image,
not guessed symbol names from an adjacent stripped export. The retained local
image is `/tmp/macws_mso40ui_arm64`; the complete original universal capture is
`/tmp/macws-ppt-mso40ui-20260919.bin`. Capstone disassembly resolves Objective-C
selectors through this image's actual `__objc_selrefs` and `__objc_stubs`.

`a7b6f6b` widened ordinary GUI launching from a native-Metal allowlist to actual
application bundles and installed the complete-manifest QuartzCore shader
router for their native AGX devices. `fa39433` subsequently made the shared
native-AGX policy default-on without an enable environment variable. These
changes expose Office to existing native buffer adapters; they did not add an
Office-specific picture decoder.

The init-bytes allocation redirect dates to `f82492c`, before those changes.
In the current `libmachook/Metal_hooks.x`,
`initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress:` allocates a
different buffer with `newBufferWithLength:options:`, copies initial data, and
calls the supplied deallocator immediately. The code itself already documents
the non-aliasing consequence for Geekbench. Its current options conversion and
`hasUnifiedMemory` override are confined to a verified Geekbench worker; they
do not make Office's original memory alias the new buffer. This is a concrete
source contract violation candidate, not evidence that every Office image uses
the affected allocation at the failing moment.

## Actual missing-picture path, not a selector-name search

Runtime-confirmed via
`/tmp/macws-ppt-fixture-observed-launch-20260919.log`, owned diagnostic
PowerPoint PID 31427:

```text
CGIMAGE-OBS diagnostic=1 pid=31427 tid=447418 sample=10/32 api=CGContextDrawImage image=0x12ea57140 width=309 height=250 bpr=1236 bpc=8 bpp=32 alpha=5 bitmap=0x5 context=0x12e0f0340 has-destination=1 rect=[0,0,309,250] ctm=[1,0,0,1,0,0] caller=mso40ui+0x11c734
```

The other three original fixture sizes, 284x102, 282x28 and 471x56, have the
same caller `+0x11c734` after selecting slide 3. Their PNG decode observations
are non-nil and have the expected dimensions. The observer records entry to
the real draw and forwards it; it does not establish the eventual CPU pixel
contents or GPU upload by itself.

RE-confirmed in the same image:

| Stage | Actual image offsets and behavior |
| --- | --- |
| Missing-picture draw | `+0x11c6cc` calls `+0x117570` for its CGContext; `+0x11c6e4..0x11c704` obtains/inverts/concatenates the CTM; `+0x11c730` calls `CGContextDrawImage`. The return PC is the observed `+0x11c734`. |
| CPU bitmap allocation | `+0x117598` calls `+0x117000`, which allocates `rowBytes * height` through `+0x126b94` and stores the shared-buffer object at bitmap `+0x28`. |
| CGContext data | `+0x1175e0..0x1175f0` calls that shared object's vtable `+0x20` for its raw CPU pointer. `+0x117628` passes the returned pointer to `CGBitmapContextCreateWithData`. |
| Lazy Metal view | `+0x116f38..0x116f58` obtains the same bitmap `+0x28` object and calls its vtable `+0x30`, returning the Metal buffer wrapper. |
| CPU-to-GPU update | `+0x11712c` calls `+0x116f24`; `+0x117148` calls the `didModifyRange:` wrapper. **Only if bitmap+0x50 is zero**, `+0x117234` encodes `copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:`; `+0x11714c..150` otherwise skips the blit. |
| Direct buffer texture alternative | `+0x116dbc` calls the eligibility helper `+0x1166a4`; if true, `+0x116dd0` obtains the same NoCopy buffer, then vtable+0x28 calls `+0x128940`. This forwards the descriptor, offset0 and the real row stride to `newTextureWithDescriptor:offset:bytesPerRow:` (`+0x128968` -> ObjC stub `+0x6012c0`, selref `+0xac7810`). `+0x116e34` sets bitmap+0x50 to1. |

Thus the **actual observed image draw** is connected in the original binary
to a shared CPU bitmap and either a direct buffer-backed texture or a later
Metal buffer upload. This is substantially
stronger than noting that the library contains `newBufferWithBytesNoCopy:`.
The original trace did not join the exact image context, exact buffer identity,
and allocation order; the subsequent 37718 trace above now does. The earlier
investigation omitted the direct-view branch and therefore overstated that a
blit necessarily follows NoCopy creation. The corrected RE includes both paths.
In the v2 observer's actual PID38733 run, the real AGX blit-encoder hook installed
but reported no matching image-buffer blits; eight completions after full-size
draw5 were status4/error=nil. Absence of an observer hit alone is not proof of
the alternative path; direct-view metadata observation is the next check.

## Shared-buffer implementation and lifetime

The two relevant concrete vtables at image `+0x8b78b0` and `+0x8b7a38` identify
themselves through RTTI as:

```text
ARC::Metal2D::SharedBufferAllocator::TValidatedBuffer<DirectSharedBuffer>
ARC::Metal2D::SharedBufferAllocator::TUnvalidatedBuffer<DirectSharedBuffer>
```

Both contain these same function pointers:

| Vtable offset | Implementation | Original behavior |
| --- | --- | --- |
| `+0x20` | `+0x128608` | Return the original allocation pointer `[[this+0x10]+8]`; does **not** call Metal `contents`. |
| `+0x28` | `+0x128620` | Return the original allocation length `[[this+0x10]+0x18]`. |
| `+0x30` | `+0x128638` | Return the cached Metal wrapper at `this+0x18`, or lazily create it from that original allocation. |

The lazy creation call's exact arguments are visible in the binary:

```text
+0x128680  ldr x21, [x20, #0x10]
+0x128698  bl  #0x1bf14                 ; ARC::Metal::GetMTLDevice
+0x12869c  ldr x2, [x21, #8]            ; original CPU pointer
+0x1286a8  ldr x3, [x21, #0x18]         ; original allocation length
+0x1286d4  add x5, sp, #0x10            ; deallocator block
+0x1286d8  mov w4, #0x10                ; macOS Managed resource options
+0x1286dc  bl  #0x601120                ; newBufferWithBytesNoCopy:length:options:deallocator:
```

Its deallocator block at `+0x128850` releases the captured original allocation
through its virtual release method. The earlier `+0x128688..0x128694` retains
that object for the Metal lifetime. Calling this block at initialization, as
the compatibility redirect currently does, removes that lifetime reference
early even if another caller currently keeps the allocation alive. It is not
proof of an immediate use-after-free: other ownership references matter.

A second pooled allocation path at `+0x1283b0` invokes the same no-copy selector
with options `0x10`, pointer `[x19+0x10]`, and a corresponding captured-owner
deallocator at `+0x1283e0`.

## Synchronization and unified-memory checks

RE-confirmed at `+0x126c34..0x126c7c`: the update helper asks the actual Metal
buffer for `storageMode`, and calls `didModifyRange:` only when it equals
macOS Managed (`1`). At `+0x126c84..0x126cbc`, the helper similarly encodes
`synchronizeResource:` only for mode `1`.

`+0x1a2e8` calls `hasUnifiedMemory` and caches the result at capability-structure
`+0x18`. **This review has not established that the failing picture allocation
is selected by that byte.** Both concrete no-copy call sites above explicitly
pass `0x10`; changing Office's capability getter to `NO` is neither justified
by this evidence nor an implementation of the lost alias contract.

Other readback methods (`+0x13edbc` and `+0x1410e0`) explicitly synchronize a
texture before `getBytes:bytesPerRow:fromRegion:mipmapLevel:`. The binary does
not support a blanket claim that all Office readback skips synchronization.

## Minimum discriminating evidence still required

The parent agent subsequently ran the independent owned 16-KiB Shared-buffer
test `misc/macws_nocopy_contract_probe.m`. These are the actual returned
counters reported from that run, not an inferred Office screenshot result:

| Witness | Native iOS | Canonical arm64 `DC73423C...` |
| --- | --- | --- |
| Original pointer aliases returned contents | `alias=1` | `alias=0` |
| Later CPU writes visible through buffer | `cpu-late-write=1` | `cpu-late-write=0` |
| Deallocator callbacks before buffer release | `0` | `1` |
| Original allocation mismatches after GPU fill | `0/16384` | `16384/16384` |
| Returned buffer contents mismatches after GPU fill | `0/16384` | `0/16384` |
| Real completed command status | `4` | `4` |

This reproduces the shared-memory/lifetime invariant failure independently of
Office: GPU completion and the buffer's own contents can be correct while the
caller's original allocation remains stale. It does not by itself establish
the exact moment Office first creates each Managed no-copy buffer.

### Managed control and executable regression coverage

`python3 -m unittest misc/test_nocopy_contract_probe.py -v` completed **6 tests
successfully**, including real stock-macOS Shared and Managed runs. Each
requires original-memory aliasing, later CPU mutation, zero GPU mismatches,
real completed command status, no early deallocator callback, and exactly one
callback after release. Additional tests enforce one owned page (4–64 KiB),
one command queue/submission, the 10-second alarm, rejection of unsupported
arguments before allocation, no native-iOS Managed request, and no production
build/startup linkage. These are diagnostic controls, not a shipping workload.

Exactly one additional on-device run used the macOS Managed argument, without
any flag or application interaction. The original helper was not overwritten:
the copied probe was separately staged as
`/private/tmp/macws_nocopy_managed_contract_mac_20260919` inside the chroot.
Its arm64 executable UUID is `D0BAC71C-68DE-3254-9F63-2AE33F320AEF`, admitted
CDHash `06f1fbc8f2974441ac6af756b9b76650b3e34fc9`. The canonical library's
on-disk SHA-256 was checked immediately before this invocation:
`e4d0ec89d5e8737059593725f22a91d4c2641a4e0d98f73ce2c883de67c3e6cd`.

Actual command (existing namespace-correct isolated launcher):

```sh
/tmp/macws_isolated_namespace_launch /var/mnt/rootfs \
  /usr/local/lib/libmachook_arm64.dylib \
  /private/tmp/macws_nocopy_managed_contract_mac_20260919 managed
```

Verbatim returned output, normal exit **1**, about **0.59 seconds** including
SSH and admission; no crash, retry, benchmark loop, or service restart:

```text
library=/usr/local/lib/libmachook_arm64.dylib subtype=0 uuid=dc73423ca25a3231b3d5e8f1a4f627fb
NOCOPY length=16384 original=0x1006f8000 contents=0x100848000 alias=0 cpu-late-write=0 premature-callbacks=1 requested=managed actual=1
NOCOPY status=4 error=none gpu-original-mismatch=16384/16384 gpu-buffer-mismatch=0/16384 callbacks-before-release=1
NOCOPY callbacks-after-drain=1 callback-mismatch=0
NOCOPY contract=FAIL
```

This specifically refutes the theory that Office's `0x10` request merely
returns a nil buffer or a public Shared mode: it returned **Managed mode 1**
and completed the actual GPU fill, yet the original memory was detached and
the callback had already run. Native iOS was not given unsupported Managed
options. Both architectures and a repaired candidate still require subsequent
acceptance.

Remaining work:

1. Join one of the already-observed original picture
   CGContext data pointers to its lazy buffer, actual storage mode and the
   subsequent upload. Compare bytes or bounded hashes before the upload,
   after CPU drawing, and after real GPU completion. This separates a genuine
   stale copy from a subsequent texture/shader failure.
2. Repair the upstream mapping/lifetime/transfer ABI, then re-open the owned
   Welcome fixture and inspect all four pictures plus colored thumbnails.
   The user's unsaved PowerPoint instance must not be closed to perform this.

## Lower-priority independent candidate and excluded explanations

- QuartzCore's known client-storage `didModifyData` path is repaired only in
  WindowServer (`1879ebd`, 2026-09-06). Its original exact binary/no-op-driver
  evidence is documented beside `macws_quartzcore_update_image`. It remains a
  possible app-owned reused-surface gap, but the actual Office draw above uses
  ARC's explicit shared-buffer upload. Do not widen that hook without proving
  Office reaches the same guarded shape; a one-time original `update_image`
  argument/flags/texture witness could refute it.
- `MacWSOfficeMultiplyFilter.m` is explicitly limited to the process name
  `Microsoft Word`, `ASInternalLayer`, and `CIMultiplyBlendMode`; it cannot
  directly explain PowerPoint's missing pictures. The native shader router
  still requires validated source path/bytes and complete manifests; absence
  of a shader error alone does not prove a cached library correct.
- The ordinary 19x11 and 309x250 texture controls passed. They used ordinary
  uploads, not Office's no-copy original-memory lifetime, and therefore do not
  settle this contract. No further repetition of those controls is proposed.
