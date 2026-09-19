# Office image geometry: bounded discriminator, not a repair

## Visible failure

Main-agent screenshot `/tmp/macws-powerpoint-black-thumbnails-20260919.png`
was independently inspected. The main slide's orange band, white background,
and text render; an image-like region in the middle-right is reduced to a very
thin horizontal strip. The left slide thumbnails have black backgrounds while
text remains visible. This suggests testing geometry/upload/image consumption,
but a screenshot alone does not identify a row-stride or shader root cause.

The simultaneously observed Weather magenta region has a separate concrete
runtime error: `RBDevice: command buffer error: Error
Domain=MTLCommandBufferErrorDomain Code=1 "Internal Error
(00000102:Internal Error)"`. The parent investigation owns the captured failing
command submission. Do not conflate these two symptoms without a matching
request or rendering primitive.

## Source scope

The existing `MacWSOfficeMultiplyFilter.m` is unchanged from `a7b6f6b` and
only matches Microsoft Word's `ASInternalLayer` plus `CIMultiplyBlendMode`.
It does not run for PowerPoint or Weather. Its selection-highlight acceptance
does not establish image rendering correctness.

The new IOSurface protection adapter reads the real native shared-state value;
it does not rewrite texture dimensions, strides, formats, or command buffers.
Its earlier 16x16 uniform-color surface/CA tests do not cover arbitrary raster
uploads, padded rows, subrectangle writes, mipmaps, or Office's actual resources.

Existing per-plane C getters recover explicit IOSurface CreationProperties.
The static C interposers and AGX import adaptations do not, by themselves,
establish coverage of direct Objective-C per-plane getters. That remains an
untested API-boundary hypothesis, not the explanation for the Office failure.

## Exact bounded experiment

`misc/macws_texture_stride_probe.m` creates one owned 19x11 BGRA image and a
single Metal queue. Rows and columns have distinct values. Upload rows are 128
bytes; GPU-to-buffer readback rows are 256 bytes. Plain/surface modes also write
a 7x5 subrectangle with different content through the six-argument upload API.
Both GPU-readback and public `getBytes` must match all 209 pixels; untouched
CPU destination padding must remain intact. The CGImage-to-CARenderer mode
additionally exercises the image consumer and uses the vertical ordering
measured in the stock macOS control. There is no window, foreign surface,
global diagnostic flag, remote context, or application state modification.
An alarm bounds each process to ten seconds.

Stock macOS local controls passed all three modes. With the parent's explicit
authorization, six device tests ran serially: native iOS and the current
canonical chroot library, each in `plain`, `surface`, and `ca-image` mode.
Every test exited zero with:

```
phase=gpu-copy status=4 error=none
phase=gpu mismatched-pixels=0/209
phase=getBytes mismatched-pixels=0/209
getBytes-modified-padding=0
```

The CA modes also completed their own queue fence before readback. The first
chroot test mapped `/usr/local/lib/libmachook.dylib` UUID
`a2f517de9c6d3d45afe3458f72e58929` (arm64e). Its initial `main-subtype` print
incorrectly treated dyld image index zero as the executable; that index can
instead identify an injected library. This was caught before attributing it
to a file conversion. The revised observer selects `MH_EXECUTE` explicitly.

A second authorized six-test set selected the real canonical arm64 dylib:

```
library=/usr/local/lib/libmachook_arm64.dylib subtype=0
uuid=60605e6423c8384ba884bc0b20d4ce52
main-executable=/private/tmp/macws_texture_stride_probe_mac_arm64-v2-20260919
main-subtype=0
```

All three modes passed with shared and requested-managed storage. For the
latter, the real runtime reported `requested-storage=1 actual-storage=0`, as
expected from the existing final AGX storage translation. This verifies that
translation for the tested APIs, **not** QuartzCore's separate managed
client-storage/no-copy path.

Device raw chroot logs:

- `/tmp/macws-stride-mac-plain-20260919.log`
- `/tmp/macws-stride-mac-surface-20260919.log`
- `/tmp/macws-stride-mac-ca-image-20260919.log`
- `/tmp/macws-stride-arm64-{plain,surface,ca-image}-{shared,managed}-20260919.log`

All twelve processes exited. No canonical library or launch job was changed.

## Actual PowerPoint binary entry points

A bounded read of the installed arm64 Mach-O symbol tables and
`__objc_methname` sections, not an attachment to the user's document, shows:

- The PowerPoint executable imports CGContext/CGImage/ImageIO and CVPixelBuffer
  APIs, plus `ARC::Metal::IMetalPlatformSharableTexture::Create` and
  `ARC::Quartz::IQuartzPlatformBitmap::Create`.
- Gfx.framework's ARC imports have ordinal 10, corresponding to its actual
  `mso40ui.framework` dependency.
- mso40ui contains `replaceRegion:mipmapLevel:withBytes:bytesPerRow:`,
  `newTextureWithDescriptor:offset:bytesPerRow:`, GPU buffer-to-texture and
  texture-to-buffer copy selectors, CGImage/NSImage bitmap APIs, and MPS.

This identifies candidate paths, not which call produced the failing image.
Two additional probe modes model the buffer-backed texture view and padded
buffer-to-texture copy, with a nonzero 256-byte offset. Both pass on the local
stock Mac. The parent then authorized four serial device controls: both modes
on iOS native and macOS arm64 with canonical UUID `60605e64...`. All four exited
zero, returned 209/209 matching pixels through GPU and CPU readback, and
preserved CPU destination padding. The copy mode completed its upload command
as well as its readback command. Logs for the chroot cases are:

- `/tmp/macws-stride-arm64-buffer-view-shared-20260919.log`
- `/tmp/macws-stride-arm64-buffer-copy-shared-20260919.log`

These four probes also exited; none remain running. This brings the total
bounded device runs in this investigation to sixteen, not a sustained loop.

## What this does and does not establish

Ordinary BGRA non-square CPU uploads, padded row strides, subrectangle writes,
GPU copies, and one CGImage-to-CA path are not universally broken in the
current tested arm64/arm64e libraries. The Office screenshot remains a failure. The experiment
does not cover the app's exact format, mip levels, alpha/storage flags, managed
client-storage updates, planar/Objective-C metadata, or its actual draw command.
The next useful observation is the failing Office resource/descriptor or draw,
not expanding a uniform-color test into a claim that the application is fixed.

## First actual application trace: no factory hit, inconclusive

The parent authorized a read-only LLDB observation of the existing unsaved
PowerPoint process 19000. The copied installed mso40ui arm64 image has UUID
`08F30267-C97A-30FB-A4BB-43186407CDB2`. Bounded disassembly confirms:

- `+0x19c0d4`: raw bitmap factory, `x0` points to two uint32 dimensions,
  `w1` is **ARC SurfaceFormat, not MTLPixelFormat**, `w2` is signed stride,
  `x3` is pixel-data pointer, `x4` points to DPI floats. The called constructor
  at `+0x199ccc` reads `[x26]`/`[x26+4]` as width/height and multiplies height
  by the absolute stride (`+0x199e24..+0x199e30`).
- `+0x13bea0`: Metal shared-texture wrapper, `x0` is texture, `x1` points to
  the two dimensions, `x2` points to DPI floats, and `w3` is ARC SurfaceFormat.
- `+0x3a6e0`: CGImage wrapper, `x0` is the image. Its initializer calls the
  actual CGImageRetain import at `+0x3a768`.

The observer validated the live module UUID and all six eight-byte
entry/result instruction sequences before setting breakpoints. It requested
at most two events per factory, read registers and at most 16 bytes of argument
metadata, executed no target expressions/getters, and automatically continued.
The initial remote-module handshake was slow. After ARMED, the twenty-second
observation reported zero factory hits, then deleted breakpoints and detached
successfully. The process remained alive with original parent 8928 and state S;
the dedicated debugserver exited. No document was closed or modified by the
observer. The parent subsequently confirmed that the UI actions missed the
first sampling window because ARMED and DETACHED messages arrived together.
That first zero-hit trace is therefore invalid as an API-coverage observation.

A second authorized pass drove the exact three approved slide-selection taps
from the observer after Continue: `(185,910)`, `(185,475)`, `(185,910)` in the
2388x1668 desktop, spaced two seconds apart. The CGImage factory and its result
point both hit twice:

```
cgimage=0x15445f840 result=0x1323831c0 caller=mso40ui+0x113c4c
cgimage=0x1501f55b0 result=0x132218f60 caller=mso40ui+0x113c4c
```

Raw-bitmap and shared-Metal-texture factories did not hit in that window. The
CGImage-to-ARC object factories returned non-null objects, but this does not
yet identify their pixel geometry or prove correct draw output. The observer
again detached successfully, and PowerPoint remained PID 19000, parent 8928,
state S. No debugger remained attached. Actual disassembly of the caller at
`+0x113c3c..+0x113c4c` confirms that it obtains a CGImage from `+0x1176f0` and
then calls the observed factory.

The actual copied universal mso40ui file SHA-256 is
`f80b329ad469bfad34ce5578404737068c024a68aeeaa285603fc2b705c3950f`.
Three more precise observer sites were RE-confirmed in that binary:

```
+0x3ab9c  bl _CGImageGetWidth
+0x3aba0  mov x19,x0
+0x3aba4  ldr x0,[x20,#0x18]
+0x3aba8  bl _CGImageGetHeight
+0x3abac  bfi x19,x0,#32,#32       // width=x19, height=x0 before this

+0x3b250  ldr x0,[x20,#0x68]
+0x3b254  bl _CGImageGetBytesPerRow
+0x3b258  cmp w23,#8              // bpr=x0, ARC-format=w23

+0x3b1ac  ldr x0,[x20,#0x68]
+0x3b1b0  bl _CGImageGetBitmapInfo
+0x3b1b4  and w8,w0,#0x1f         // bitmapInfo=w0 before this
```

A first metadata attempt reached the width/height result breakpoint, but its
Python callback was incorrectly registered under the reused module name.
It therefore produced **no valid metadata sample**. The observer's finally
block still removed breakpoints and detached within its twenty-second window;
PowerPoint remained alive with the original parent. This is a diagnostic
harness failure, not an application failure. The callback registration was
subsequently corrected locally; a new target attachment needs coordination.
The callback name now derives from its actual module `__name__`, and the
runner checks that it resolves to a callable before installing any breakpoint.
Beyond import/static checks, a local four-line owned C test process exercised
that exact LLDB metadata callback: it fired once, automatically continued,
and the test process exited zero. No device/application was involved in this
observer self-test.

After the parent released the UI following its Weather acceptance, one final
authorized metadata pass used the same three slide-selection taps and the
corrected callback. The actual callback output was:

```
PPTIMAGE {"cgimage":"0x1502d0630","height":12,"hit":1,"site":"cg-dimensions","tid":384023,"width":12}
PPTIMAGE {"cgimage":"0x151ae36c0","height":12,"hit":2,"site":"cg-dimensions","tid":384023,"width":12}
PPTIMAGE {"counts":{"cg-dimensions":2},"error":"success","state":"DETACHED"}
```

There were no bytes-per-row or bitmap-info samples from the other two sites.
These are two **12x12 images**, not an identified failing slide image. They
therefore neither validate nor refute the large picture's stride/format.
At cleanup LLDB printed `error reading data from section __text` while showing
its deliberate SIGSTOP; detach then succeeded and debugserver exited zero.
A separate post-detach `ps` confirmed the original PowerPoint PID 19000,
parent 8928, state S. That observer diagnostic is not evidence of an app crash.
No further attachment was started, and the UI was released back to the parent.

## Fresh candidate PowerPoint: actual visual failure remains

After that handoff, the parent authorized exactly one new, owned PowerPoint
test instance, preserving user PID 19000 and its unsaved document. The existing
trusted namespace launcher directly executed PowerPoint with
`-ApplePersistenceIgnoreState YES`, the normal root home, and the canonical
arm64 library. No alternate profile, global LaunchServices open, production
flag, or user-document save/reset was used. The existing Office DTS template
was copied only to `/private/tmp/macws-ppt-owned-welcome-20260919.potx`.
Its SHA-256 was checked before and after copying:
`4734751a9b76f2f2fcbe5315d7b7f6abd6260c1c0b1f5da8cb5e98fb9b7b04a5`.
Independent template inspection found seven slides, sixteen PNG assets, and
valid ZIP CRCs. Its third slide really contains four pictures; not all of the
template's images are thin horizontal strips.

The new process was PID **28445**. A no-suspend runtime identity read proved:

```
image=libmachook_arm64.dylib base=0x106c24000 cpu=16777228 subtype=0
uuid=dc73423ca25a3231b3d5e8f1a4f627fb
text-sha256=4081a79893e538e1202932e4bfcf223afe19829db003eae169f8e0c18bfd773c
```

The on-disk candidate SHA-256 was
`e4d0ec89d5e8737059593725f22a91d4c2641a4e0d98f73ce2c883de67c3e6cd`.
This is the combined IOSurface/zero-depth candidate, not the old library
still mapped by user PowerPoint 19000.

The first planned new-process metadata observation performed its UUID/byte
checks and detached safely after twenty seconds, but sent **no document
transaction**: its action script rejected an invalid lifecycle receipt. The
Python parent observer had reported `returncode=0` during debugger attachment,
although the very same PowerPoint PID remained alive and was reparented to PID
1. Therefore that receipt is **not a valid application-exit witness**. No
image samples were collected in that attempted window. No further attach was
performed. The action was then guarded by the exact owned PID, real live
executable identity, and mapped candidate UUID instead of that invalid exit
field.

The production ABI-6 open-documents transaction was delivered directly to
PID 28445, with a mode-0600 nonce/path sidecar and the real AppKit delegate
acknowledgement:

```
{"state":"APPKIT_ACCEPTED","target_pid":28445,"nonce":"c35e112acb0b3b9f"}
```

PowerPoint created `Presentation1`, window **134**, from the test-copy template.
Native iPadOS screenshots were actually inspected:

- `/tmp/macws-ppt-candidate-welcome-initial-20260919.png`: main slide 1 has
  the expected orange background and white text, but every visible left
  thumbnail has a black background and only text.
- `/tmp/macws-ppt-candidate-welcome-slide3-20260919.png`: after activating
  exact PID 28445/window 134, verifying the focused-window guard, and selecting
  slide 3, the main slide has normal background/body text but all four template
  pictures are absent. The thumbnail problem remains.

This is a **failed visual acceptance** for Office rendering under the fresh
combined candidate. Correct tiny texture pixels, a fixed Weather frame, and
the non-null CGImage wrappers do not establish that Office is fixed. The
owned PID 28445 was deliberately left available for inspection; original
PID 19000 was not closed, saved, or sent a document event. Debugserver exited,
no observer remained attached, and UI ownership was returned to the parent.

## Actual-template-size primitive control: 309x250

The existing Office DTS template was identified without reading or saving the
user's unsaved presentation. Its package SHA-256 is
`4734751a9b76f2f2fcbe5315d7b7f6abd6260c1c0b1f5da8cb5e98fb9b7b04a5`.
Slide 3's `rId4` references `ppt/media/image5.png`: PNG IHDR width 309,
height 250, bit depth 8, color type 2 (RGB), non-interlaced. Its DrawingML
extent is 2540925 by 2055765 EMU (200.07 by 161.87 points), with no additional
ancestor-group scaling or crop. Other pictures are 284x102 RGBA, 282x28 RGBA,
and 471x56 RGB; the last two really are horizontal strips in the source.
The package thumbnail is a 256x144, 8-bit, three-component JPEG. Metadata is
retained in `/tmp/macws-ppt-template-slide3-geometry-20260919.json`.

**THEORY tested:** the previously passing 19x11/16x16 probes might miss a
dimension-dependent allocation/upload/CA branch used by the larger picture.
This is not a claim that the template's PNG enters the same CGImage path as
the observed 12x12 controls; the actual large-image path remains unproven.

The standalone stride diagnostic now accepts one explicit `--actual-size`
preset, 309x250, for plain/surface/ca-image only. It retains `alarm(10)`, one
Metal queue, one frame, no arbitrary size input, no remote surfaces, and no
benchmark loop. Source and GPU-readback row strides are aligned to 1280 bytes;
the surface allocation is aligned to 327680 bytes. The GPU readback buffer is
reused for CPU `getBytes`, retaining the separate expected pattern. The
explicit pixel-storage budget is 967680 bytes; framework-internal allocations
are not included in that number. Pixels vary across both coordinates, and
plain/surface still exercise the padded subrectangle update.

The local stock macOS control passed all three larger modes. Three source/
executable-shape tests passed; default 19x11 buffer-view, buffer-copy, and
ca-image modes also passed locally after the readback-buffer reuse.

Six serial device tests then ran, each a new bounded owned process: native
iPadOS and real macOS arm64, each in plain, surface, and ca-image shared modes.
The macOS tests actually mapped canonical libmachook UUID
`DC73423C-A25A-3231-B3D5-E8F1A4F627FB` (whole signed file SHA-256
`e4d0ec89d5e8737059593725f22a91d4c2641a4e0d98f73ce2c883de67c3e6cd`).
Every command completed with status 4/no error. All six produced:

```
phase=gpu mismatched-pixels=0/77250
phase=getBytes mismatched-pixels=0/77250
getBytes-modified-padding=0
```

Plain/surface compare all four bytes exactly; CA retains the existing
stock-confirmed vertical origin and per-channel tolerance of two. Both real
surface controls reported width309, height250, bpr1280, alloc327680. Full raw
output is `/tmp/macws-stride-309x250-device-controls-20260919.log`.
All six exited normally within seconds; no UI, user document, production
library, service, or user process was changed.

This rejects a simple explanation that this size alone universally breaks
ordinary opaque BGRA uploads or this CGImage-to-CA path. It does **not** clear
Office's actual image format, decoder, caches, mip/alpha/storage flags, custom
draw pipeline, or missing final composition. Fresh Office visual acceptance
above remains failed; no production workaround was added from this control.

## Separate CGImage observer: local harness validation, not an Office fix

`misc/macws_cgimage_observer.c` is a standalone diagnostic dylib and is not in
any production build target. It statically interposes `CGImageCreate`,
`CGImageSourceCreateImageAtIndex`, and `CGContextDrawImage`, always calling the
original API with the original arguments and returning its original result.
It reads image metadata only, never pixel data. Draw observations also record
the caller's supplied rectangle and the real context CTM. A shared atomic
limit permits at most 32 observations with width or height greater than 100;
TLS prevents recursive observation. It does not read environment flags/files,
modify code pages, run a background loop, or access another process.

The local stock-macOS test creates only owned CPU bitmap pixels, encodes and
decodes its own PNG, and performs 64 draws. Real interpose output included:

```
sample=1/32 api=CGImageCreate width=17 height=131 bpr=128 bpc=8 bpp=32 alpha=1 bitmap=0x4001
sample=2/32 api=CGImageSourceCreateImageAtIndex width=17 height=131 bpr=68 bpc=8 bpp=32 alpha=3 bitmap=0x3
sample=3/32 api=CGContextDrawImage width=17 height=131 bpr=68 rect=[3,5,17,131] ctm=[1,0,0,1,2,3] caller=probe+0x7c8
```

The separate 12x12 image generated no observation. Exactly 32 lines were
emitted despite 64 large draws. Stock and observer-injected executions both
returned `colored=2291 hash=0bac4748bdd99df9` for the complete output buffer.
The two executable/source tests in `misc/test_cgimage_observer.py` passed.
These results validate the diagnostic's local call-through, geometry logging,
and budget; they are not proof of its coverage in Office or of a device fix.

The same owned 17x131 CPU fixture then ran on the device, once with canonical
DC734 alone and once with DC734 plus the extra observer. Both exited zero and
returned the same `colored=2291 hash=0bac4748bdd99df9`. The extra library's
arm64 UUID was `4CBE33FD-04B4-3E45-832F-1BFB59151428`, with signed file SHA-256
`ec6b007feb8898ee810160efe7b120d297f280dbf3f78c47fb2002c0031f1853`.
All three hooks actually logged in the device fixture, and logging stopped at
32 observations.

The parent next authorized normal Quit of only owned PowerPoint 28445. Its
real Quit menu item was accepted and that PID disappeared, while original
user PID 19000 remained. Because the earlier lifecycle observer had already
been invalidated by debugger reparenting, no clean exit code is claimed for
28445. One new isolated PowerPoint, **30588**, was then started with DC734 and
the extra diagnostic library. There was no debugger. A no-suspend identity
read confirmed actual DC734 mapping and the same `4081a798...` text hash.

That observation's 32-entry budget was exhausted **before opening the test
template**, by sixteen repeated startup decode/draw pairs:

```
api=CGImageSourceCreateImageAtIndex width=230 height=20 bpr=920 bpc=8 bpp=32 alpha=3 bitmap=0x3 caller=mso99+0x72b568
api=CGContextDrawImage width=230 height=20 bpr=920 rect=[0,0,230,20] ctm=[1,0,-0,1,0,0] caller=mso40ui+0x15d05c
```

These startup images do not identify a failing slide image. The observer was
not restarted to replenish its budget. The test-copy template was nevertheless
opened through the real PID-specific ABI-6 transaction, acknowledged with
nonce `397e2d332ee820a1`, and created window 141. The actually inspected native
screenshot `/tmp/macws-ppt-cgimage-observed-slide3-20260919.png` again shows
all four slide-3 pictures absent and black thumbnail backgrounds. Full raw
output is `/tmp/macws-ppt-observed-launch-20260919.log` on both device and Mac.

This process had only `MACWS_COMMAND_ERROR_DIAGNOSTICS=1` in its child
environment. Parent review then found that the installer/logging path also
requires runtime diagnostics. No command-error lines appeared, but that is
**no effective GPU-error observation**, not evidence of zero GPU errors.
No global flag was created. PID 30588 was left available and UI was released.

A subsequent local-only diagnostic build mode,
`MACWS_CGIMAGE_PPT_WELCOME_FIXTURE`, selects exactly the four known test PNG
dimensions: 284x102, 309x250, 282x28, and 471x56. The generic build remains
unchanged. Its executable test performs 64 actual 230x20 ribbon draws and
another non-target large image before the target image; these do not spend
the budget, and the later 309x250 create/decode/draw observations still work.
Stock versus injected full-buffer hashes remain equal. All three observer
tests pass. This is improved diagnostic coverage, not a production patch.

## Exact fixture observation: all four decoded and drawn at valid geometry

After parent review, only owned PID 30588 was normally asked to quit. Original
user PowerPoint 19000 was preserved. One new process, **31427**, loaded actual
canonical DC734 and the fixture-only observer (arm64 UUID
`2FD88C9A-E432-3B44-8B5E-892F47A7297F`, signed file SHA-256
`cf3301bcccea0d54a936b4bfe053ebbc16cdd9ab1e0248d6a52442b0784f2a99`).
Both runtime and command-error diagnostics were enabled in this child alone.
No global flag or production library was changed. Before document opening,
the real log confirmed the diagnostic installation:

```
#### IOGPU-CALLBACK-DIAG installed queueClass=0x23f016208 method=0x0 orig=0x0 bufferClass=0x23f015830 method=0x1bf3239a5 orig=0x1bf306be8 errorMethod=0x1abb5fe01 errorOrig=0x1aba31dcc (file-gated)
```

The real ABI-6 open transaction acknowledged target PID 31427, nonce
`f2cf5fac5d958981`, creating window 147. This time the filter did not spend its
budget on startup ribbon images. It captured twelve observations, including
all four template pictures decoded at `mso40ui+0x1a191c`:

| Source dimensions | Bytes/row | Bits/component and pixel | Alpha / bitmap info | Full-size draw rectangle |
|---|---:|---|---|---|
| 284x102 | 1136 | 8 / 32 | 3 / 0x3 | [0,0,284,102] |
| 309x250 | 1236 | 8 / 32 | 5 / 0x5 | [0,0,309,250] |
| 282x28 | 1128 | 8 / 32 | 3 / 0x3 | [0,0,282,28] |
| 471x56 | 1884 | 8 / 32 | 5 / 0x5 | [0,0,471,56] |

After selecting slide 3, all four full-size `CGContextDrawImage` calls above
came from **mso40ui+0x11c734**, each with CTM `[1,0,0,1,0,0]`. Earlier bounded
intermediate draws were 142x51 and 78x63 at `+0x19bc80`, then 256x28 and 256x56
at `+0x11c734`. Actual binary disassembly confirms `+0x11c730` calls the real
CGContextDrawImage import after saving state, inverting the context CTM, and
setting blend mode 0x11. `+0x19bc7c` is the other actual draw call.

The inspected native screenshot
`/tmp/macws-ppt-exact-fixture-slide3-20260919.png` still shows four missing
pictures and black thumbnails. This rules out a simple zero/one-row source
dimension or caller rectangle/CTM explanation for these observed four calls;
it does not establish that the decode pixels, bitmap destination storage,
subsequent texture upload, or composition are correct. The observer reads no
pixel bytes. No `IOGPU-ERROR-GETTER` observation appeared; because the program
may not query every command's error accessor, this is not an all-commands
GPU-success witness.

The same log also confirms the existing native buffer-copy redirection:

```
#### AGXBuffer init-bytes ENTRY self=0x12f718e80 dev=0x14b040c00 bytes=0x14ad04000 len=262144 opt=16 pin=0 malloc_size=0
#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE: self=0x12f718e80 dev=0x14b040c00 len=262144 opt=0x10 pin=0 -> [dev newBufferWithLength:262144 options:0x10]
#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE result: 0x12f7c99b0 class=AGXG13GFamilyBuffer len=262144 gpuAddr=0 queried=NO
```

However, its eight entry-log slots were already spent at log lines 531, 548,
923, 945, 949, 958, 981 and 993; the first exact picture decode is line 1038.
This is real process-level evidence of that path, **not** a correlation of one
redirected buffer to a particular slide image. `gpuAddr=0 queried=NO` is not
evidence of a zero GPU address. The real value was deliberately not queried.

Source review of `Metal_hooks.x` confirms that the redirect allocates separate
storage, copies the initial bytes once, then immediately invokes the supplied
deallocator. It has no original-pointer alias or later original-pointer-write
synchronization. `git blame` dates that implementation to `f82492c` (June 20),
whereas `fa39433` changed the native-default gate. Its violation of a no-copy
alias/lifetime contract therefore predates this flag migration; its causality
for these particular missing images still requires a discriminating test.

Complete raw log: `/tmp/macws-ppt-fixture-observed-launch-20260919.log`, copied
to the Mac as well. The parent then authorized ordinary Quit of owned 31427
to end the process-only diagnostic overhead; its real menu action was accepted
and `ps` confirmed it gone while 19000 remained. No debugger was used in this
run, no user document was saved/discarded, and UI ownership was released.
## Read-only stock Word / Excel acceptance candidates

Two existing Office DTS welcome templates were identified without launching
an app, copying a template, opening a user document, or traversing a user
Documents directory. Inspection was limited to the immediate files in two
known product cache directories (at most 32 templates per product), ZIP entry
names, bounded metadata XML, and PNG/JPEG headers. The selected file hashes
cover their full small files. Source mtimes did not change during inspection.

The detailed read-only receipt is
`/tmp/macws-office-stock-acceptance-candidates-20260919.json`; it retains exact
iOS-host and chroot paths, every image's header dimensions/format and stored
ZIP CRC field, and document/drawing relationships. Stored CRC metadata is not
claimed as an independent full decompression/CRC validation. These are
**candidate fixtures, not completed visual acceptance results**.

Common chroot path prefix:

```text
/private/var/root/Library/Application Support/Microsoft/Office/16.0/DTS/
```

The iOS-side absolute paths prepend `/var/mnt/rootfs` to that prefix.

### Word: Welcome to Word

```text
en-US{36A5E21D-0690-874F-A58C-9855AF49162B}/{F38EE5EE-493F-194B-A0A3-FE02E725721D}TF41a41aae-3824-4886-9479-348becc8f5a0da5ec917-e3d6198f82b9.dotx
```

- Bytes: `1373417`.
- SHA-256: `3e03a7c04d53482a424676f503c65897d2b420ad8e25e1703252981417825870`.
- Opening text in `word/document.xml`: `Welcome to Word`,
  `6 tips for a simpler way to work`, then `Quick access to commands`.
- Cached `docProps/app.xml` reports six pages and 430 words. This is not a
  promise that current Word layout must paginate identically.
- Fourteen PNG images; document image order begins `rId8 → image1.png`, then
  `rId9 → image2.png`. A pre-existing `~$` lock file beside this stock template
  was not opened or changed; future app tests must use a separate owned copy.

All image names below are under `word/media/`, all 8 bits per component.

| Part | Dimensions | PNG color type |
| --- | --- | --- |
| image1.png | 1050×304 | 2 (RGB) |
| image2.png | 1146×559 | 2 |
| image3.png | 1964×736 | 2 |
| image4.png | 1964×747 | 2 |
| image5.png | 657×151 | 6 (RGBA) |
| image6.png | 509×360 | 6 |
| image7.png | 1795×947 | 2 |
| image8.png | 1328×612 | 2 |
| image9.png | 837×698 | 6 |
| image10.png | 284×241 | 2 |
| image11.png | 323×187 | 6 |
| image12.png | 1049×415 | 6 |
| image13.png | 821×473 | 6 |
| image14.png | 600×600 | 2 |

### Excel: Take a tour

```text
en-US{494EB375-2093-E441-886A-A226AB3A5696}/{DEA1EEF2-1046-B54F-A96E-8CC46310DE6B}TFd3ffed48-aaae-4e26-be16-2228e68ce2b3240fe036-19b6aa125334.xltx
```

- Bytes: `451167`.
- SHA-256: `63cb85241ba579a94953f19121a7ed6e1e8b7f21c167cc43e50b135ca505ed69`.
- Twelve sheets: `Start`, `1. Add`, `2. Fill`, `3. Split`, `4. Transpose`,
  `5. Sort & filter`, `6. Tables`, `7. Slicers`, `8. Drop-downs`, `9. Charts`,
  `10. PivotTables`, and `Learn more`.
- `Start` has the title `Take a tour` in A2, followed by an introduction to
  ten steps in Excel. Its first-sheet drawing relationships include
  `image1.png` (506×267), `image2.png` (384×384), and `image3.svg`. The SVG is
  recorded as a vector relationship, not confused with a missing PNG.

All sixteen PNG images are under `xl/media/`, 8 bits/component, color type 6
(RGBA). Grouped only where the header dimensions are identical:

| Part(s) | Dimensions |
| --- | --- |
| image1.png | 506×267 |
| image2, image4, image6, image8, image10, image13, image15, image18, image20 (.png) | 384×384 each |
| image12.png | 178×39 |
| image17.png | 126×53 |
| image22.png | 118×116 |
| image23.png | 102×76 |
| image24.png | 68×78 |
| image25.png | 90×82 |

Expected text and image presence here are derived from the exact stock XML
and image headers. Actual colors, positioning, current layout, successful
decoding, and visible app output still require the subsequent controlled
visual test; metadata alone cannot establish those results.

## Linear NoCopy texture descriptor: bounded native/candidate control

This later control is allocation-only, not a shader or Office rendering test.
Three owned processes each used one 16384-byte NoCopy allocation and created
one 19×11 RGBA8Unorm (`pixelFormat=70`) buffer texture with row stride 128,
offset zero, shader-read usage 1, one sample, and one mip level. Each process
had a ten-second alarm, no command queue, no GPU submission, no UI, and no
user-app attachment. Their only modes were native Shared, candidate Shared,
and candidate Managed.

Probe source: `/tmp/macws_linear_texture_descriptor_probe_20260919.m`,
SHA-256 `652c1895bba65dda1ee78b8ba9b4a60b77432705fa86544dc93ef0dfa6cead7c`.
Raw receipts:

- `/tmp/macws-linear-descriptor-native-shared-v2-20260919.log`
- `/tmp/macws-linear-descriptor-candidate-shared-v2-20260919.log`
- `/tmp/macws-linear-descriptor-candidate-managed-v2-20260919.log`

The actual injected arm64 candidate UUID was
`92820A6A-B26E-391F-899C-786575CEE126`, not inferred from a canonical filename.
The native AGX image UUID was `BA327004-18CF-309D-9084-FC0C18C87809`; the macOS
AGX image UUID was `727C250E-554D-3921-A5B3-48DAE6195B79`.

The probe obtains `_impl` from the real Objective-C ivar metadata, requires its
pointer type and instance-size bounds, checks its actual malloc allocation,
and reads at most `min(allocation, 0x280)` through a verified readable VM
region. It has no hardcoded ivar fallback. The first implementation required
all 640 bytes and correctly refused the smaller allocations with exit 77;
those original non-v2 receipts remain intact. This was an observer limitation,
not failed texture creation. The corrected v2 never reads beyond the proven
allocation.

| Mode | Actual `_impl` ivar offset | Actual impl allocation/read | Matching 24-byte candidate offset |
| --- | --- | --- | --- |
| Native Shared | `0x208` | 512 bytes | `0x180` |
| Candidate Shared | `0x208` | 528 bytes | `0x190` |
| Candidate Managed | `0x208` | 528 bytes | `0x190` |

Exactly one 19×11 encoding matched in each bounded allocation. Its full 24
bytes were **identical in all three cases**:

```text
020a8826012800000000004005c001000000000000000000
words=0000280126880a02,0001c00540000000,0000000000000000
```

Using the existing `MacWSDumpTextureDescriptor` bitfield interpretation from
`misc/ios_agx_texture_re_probe.m`, these bytes decode as 19×11, address
`0x1500000000`, layout 0, compressed 0, and extended 0. The address independently
matched the actual public `buffer.gpuAddress` in all three processes. The
dimension/address match supports this interpretation, but does not establish
all unknown fields of every linear texture format.

All three public texture metadata sets matched their requested geometry;
Shared remained storage 0 and Managed remained storage 1. Each buffer retained
the original CPU pointer (`alias=1`), each texture referenced that buffer, and
each original allocation's deallocator fired exactly once at teardown. All
three v2 processes exited zero.

The different internal descriptor **positions** are observed structure-layout
differences, not evidence that a consumer reads the wrong offset. For this
small fixture there is no descriptor-content difference to explain failed
sampling. The result does not test actual shader execution, 309×250 Office
pictures, or the application's current texture contents.

### Independently observed method dispatch ABI

Bounded metadata/code inspection of the same native/macOS AGX generations
also found identical Objective-C signatures and unchanged argument forwarding:

```text
newTextureWithDescriptor:offset:bytesPerRow:       @40@0:8@16Q24Q32
initWithBuffer:desc:offset:bytesPerRow:             @48@0:8@16@24Q32Q40
initWithBuffer:descriptor:offset:bytesPerRow:       @48@0:8@16@24Q32Q40
```

Actual selref and superclass selector reads confirmed that precise dispatch
chain. Native offsets are AGX `1ffd54 → 56a73c`, then IOGPU `1f88`; macOS
offsets are AGX `22c8d4 → 67e128`, then IOGPU `132b4`. Original buffer,
descriptor, offset, and row stride are forwarded without reordering. Raw
method signatures, UUIDs, selected 2-KiB instruction blocks and selector text
are in `/tmp/macws-buffer-texture-{native,macos}-v3-20260919.log`.

The separate complicated IOGPU initializer accepting a resource argument
struct still has the known macOS 104-byte/native 96-byte difference, but it is
not the simple superclass selector observed in this call chain. That adjacent
method's ABI must not be promoted to the cause of this path without actual
runtime coverage.

## Owned Word stock-template visual acceptance: images still missing

The same isolated NoCopy candidate was tested in a new **Word** process,
without runtime diagnostics, an observation library, LLDB, or global flags.
No Word was running before this test. The stock `.dotx` identified above was
copied to `/private/tmp/macws-word-owned-welcome-20260919.dotx`; its SHA-256
was verified as
`3e03a7c04d53482a424676f503c65897d2b420ad8e25e1703252981417825870`.
The source template and user documents were not opened for writing.

The actual test process was Word PID 41362, document window 222. A separate
Word-only, no-suspend image identity helper verified the mapped candidate,
not just its on-disk filename:

```text
image=libmachook-nocopy-arm64-20260919.dylib
cpu=16777228 subtype=0 uuid=92820a6ab26e391f899c786575cee126
text-bytes=643380
text-sha256=12280a7b28ffd4bdbda4c97e80995275ffa4eae314238f07bc82cb0dbcd9475f
image-count=765 matched=1 requested=1 no-suspend=yes
APPKIT_ACCEPTED pid=41362
```

The signed candidate's whole-file SHA-256 was
`2449aef4211ef2597f8a479d17d6c6ed549f47651f6fb842317cf6c3826c0a72`.
Only the owned copy was delivered through the target-PID open-documents
protocol. Its acknowledgement establishes delivery, **not visual success**.

Actual full iPadOS screenshots were captured and inspected:

- `/tmp/macws-word-nocopy-welcome-initial-20260919.png`: the Word document,
  welcome heading, toolbar, and text render.
- `/tmp/macws-word-nocopy-welcome-scroll1-20260919.png`: the first page has
  large blank areas where the first two stock images belong; surrounding
  text remains legible.
- `/tmp/macws-word-nocopy-welcome-scroll2-20260919.png`: the bottom of that
  page remains blank and the next section, “Look professional, your way”,
  renders normally as text.

This is not inferred only from a white screenshot. Read-only inspection of
the owned copy's `word/document.xml` shows that the paragraph immediately
after “just one click away” contains `rId8` (1050×304 RGB PNG, drawing extent
4397403×1273153 EMU), followed by the visible “If the commands currently
shown…” paragraph. After the visible “Select the Customize Quick Access
Toolbar…” paragraph, `rId9` is a 1146×559 RGB PNG with drawing extent
4923155×2401434 EMU. The screenshot shows the corresponding reserved spaces
but no image content. Therefore **Word image visual acceptance FAILS** with
this candidate despite successful NoCopy aliasing and independent tiny
texture controls. No cause is assigned by this visual test alone.

Raw identity/open log: `/tmp/macws-word-owned-open-20260919.log`; launch log
and receipt: `/tmp/macws-word-nocopy-acceptance-20260919.{log,json}`. The
bounded parent observer expired after 300 seconds and deliberately did not
kill Word; its `still-running-not-killed` state is not a final exit status.
Subsequently the actual `Quit Word` menu item (item 9, generation 4) returned
`action-accepted status=1`, and a process-list check confirmed PID 41362 was
gone. No save/discard prompt appeared. User PowerPoint PID 19000 and Terminal
PID 17280 remained alive with their original executable paths. No numeric
exit status was collected after that normal menu request, so normal exit
code zero is not claimed. UI ownership was then returned to the parent;
Excel was not started.

## Exact target-OS error producer: original iOS MTLCompiler

The separate actual Office shader probe recorded successful admission of the
155074-byte stock library (SHA-256
`9eac296d60f976a0ef4e1cfe90b440101045b4eaed437af3a6dd803997959a02`),
followed by failures of both `bitmapVS` and `bitmapPS` function-constant
specialization:

```text
shader-library=non-NIL error=none
office-function-constant name=hasStencil index=0 type=53 required=1
office-specialize name=bitmapVS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible."
office-specialize name=bitmapPS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible."
```

Raw source: `/tmp/macws-office-actual-bitmap-shader-20260919.log`. This is a
specialization failure, not failed texture allocation or initial library
admission. It does not by itself identify which process generated the error.

To locate the producer without attaching any app or unpacking a shared cache,
owned ten-second-bounded metadata probes inspected only their own loaded
images. They made no command queue, submitted no GPU work, and did not call
the compiler entry point. The macOS-side probe admitted that same library and
obtained an ordinary `bitmapVS` object. It identified macOS Metal UUID
`2BAB169C-42DA-36E3-955A-F30B709EC2AD`; the unwrapped async library entry is
at image `+0xeacd0`. The searched macOS Metal/AGX/GPUCompilerUtils/flatbuffers
`__cstring` sections did not contain the exact error literal (136499 bytes
searched). That negative search is limited to those sections, not proof that
the framework can never propagate this error.

The iOS-native metadata probe loaded the existing compiler libraries without
invoking them. It found the exact literal in the original
`/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler`, UUID
`482EE528-9D70-3ED7-A746-D19BB741245B`, at `+0x9698a`. A bounded real-code
xref scan found the error-producing function starting at `+0x4bc4`:

```text
4df4 ldrb w8, [x22, #0x40]
4df8 cbz w8, #0x4e48
4dfc add x1, x19, #0xd8
4e04 add x0, sp, #0x28
4e08 bl <external helper>
4e18 add x0, sp, #0x60
4e1c add x1, sp, #0x10
4e20 bl <external helper>
4e24 ldr w8, [sp, #0x84]
4e28 cmp w8, #7
4e2c b.ne #0x4ea0
...
4ea0 add x0, x21, #0x58
4ea4 adrp x1, <literal page>
4ea8 add x1, x1, #0x98a
4eac bl #0x25c34
...
4ef4 mov x19, #0
4f10 mov x0, x19
```

RE-confirmed behavior: an input-record byte at `+0x40` enables this validation;
the parsed module supplies data at `+0xd8`; an external constructor fills a
temporary object whose `+0x24` field must equal 7. Otherwise the function
records the exact incompatibility message, frees its module, and returns
null. Earlier in that same function, a non-null input-record field `+0x38`
provides an optional string handled at `+0x8284` and applied to the module
through `+0x76aa4`. This is consistent with target-triple processing, but
the external helpers' symbols and the enumeration name for 7 were not
resolved by this bounded probe, so those interpretations are not asserted as
additional runtime facts.

Receipts with image identities and original instruction bytes:
`/tmp/macws-metal-target-error-metadata-20260919.log` and
`/tmp/macws-metal-target-error-compiler-metadata-v{3,4}-20260919.log`.
The original checks were not patched, bypassed, or executed with invented
arguments. The exact error producer is now located in **iOS MTLCompiler**;
correlating this Office specialization with a fresh compiler request/reply
is still required to prove the dynamic route and exclude a client-cached
prior failure. The repository's current compiler adapter handles source
request discriminator `0xd` and recognized DAG discriminator 14; this source
inspection alone does not establish the Office specialization discriminator.

## Later exact-route candidate: Word, Excel, PowerPoint visual PASS

The later cross-built candidate included the NoCopy ABI/lifetime repair and
the exact-byte data-library routing described above, plus the complete
validated Office companion library. This is distinct from the earlier
NoCopy-only candidate that failed the Word image test.

```text
isolated path: /private/tmp/libmachook-office-contract-arm64-20260919.dylib
signed SHA256: 2fed14312c3dff2089c9eb87cffff82c8df74c14d18a44525a4a5d5a3e4f9586
actual mapped arm64 UUID: 03558D10-1BA7-3C07-A680-761E6281E60E
mapped __text bytes: 645220
mapped __text SHA256: 7078b6aedbf37a07e30934179ac775028b7acc65bfeb360c9d25f175729a782c
```

Each application was launched once with this exact isolated library and no
extra observation dylib or diagnostic environment/flag. No Word or Excel was
running before launch. The existing user PowerPoint PID 19000 and Terminal
PID 17280 were checked and preserved throughout; the extra PowerPoint was
explicitly owned by this acceptance test. Each stock template was copied to a
separate `/private/tmp/macws-*-contract-owned-welcome-20260919` file and
verified against the source SHA-256 recorded above. Target-PID open-documents
delivery was followed by actual full-iPadOS screenshots, not treated as
visual success by itself.

| Owned application | PID / document window | Actual visible result |
| --- | --- | --- |
| Word | 46877 / 283 | The previously blank first-page regions now show the full `rId8` toolbar image and `rId9` menu screenshot, including readable image labels. |
| Excel | 47766 / 299 | The stock `Start` sheet renders its green welcome panel, white Excel logo, orange owl illustration, text, cells, and sheet tabs. |
| PowerPoint | 48246 / 306 | All visible slide thumbnails have their correct backgrounds and image content; slide 3 shows the toolbar image, comments panel, reply field, and status-bar image at normal geometry. |

Inspected screenshots:

- `/tmp/macws-word-contract-initial-20260919.png`
- `/tmp/macws-word-contract-images-20260919.png`
- `/tmp/macws-excel-contract-initial-20260919.png`
- `/tmp/macws-ppt-contract-initial-20260919.png`
- `/tmp/macws-ppt-contract-slide3-20260919.png`

All three mapped identities were checked independently by bounded,
no-suspend helpers. The raw output is in
`/tmp/macws-{word,excel,ppt}-contract-open-20260919.log`. All three were
subsequently closed through their real application Quit menu. Excel asked
to save the newly instantiated owned template; the captured prompt named
that exact test document, and only that document's **Don't Save** button was
selected. Word and PowerPoint did not present a save prompt. Their detached
parent launchers recorded **returncode 0 for all three** in
`/tmp/macws-{word,excel,ppt}-contract-acceptance-20260919.json`; post-test
process checks retained user PIDs 19000 and 17280. The raw launch logs use
the same names with `.log`. No production library or service was changed by
these tests.

Reusable acceptance machinery (local and device `/tmp`, not production):

- `macws_office_contract_acceptance_20260919.py Word|Excel launch|open`
- `macws_ppt_contract_acceptance_20260919.py launch|open`
- `macws_office_contract_identity_20260919` (only Word/Excel and this exact
  candidate basename permitted)
- `macws_ppt_contract_identity_20260919` (only PowerPoint and this basename)

The scripts pin the artifact SHA, mapped UUID, stock-template SHA, owned
receipt names, and protected user PIDs. They intentionally cannot be blindly
reused after installing a different binary or after a reboot: a later
acceptance run must use fresh receipt paths and the newly verified artifact
identity/PID inventory. This PASS applies to **03558D10…**. A subsequently
tightened manifest provenance policy was not yet in this tested binary and
requires its own final-artifact acceptance; it is not implicitly covered by
these screenshots.

## On-device package: isolated PowerPoint visual acceptance

The subsequent on-device-built package was tested separately with the
production-generated route requiring exact source identity. The owned
PowerPoint PID 63261 loaded this exact artifact, confirmed with a bounded
no-suspend mapped-image reader before opening the copied stock template:

```text
isolated path: /private/tmp/libmachook-release-acceptance-arm64-20260919.dylib
signed SHA256: be9b20c1be4164bbf5996ee363e04a7bb05b0ef9376bd9166c2eb9bbaf979c8b
actual mapped arm64 UUID: 5EC31E06-F7D0-38CE-9989-34862E420C21
mapped __text bytes: 668868
mapped __text SHA256: 7f9c6e06380acedd01f8bc2758e473d4f92e340dfc40c774185c7f4f005769f1
```

No observation dylib, diagnostic environment, or flag was used. The owned
template SHA remained `4734751a9b76f2f2fcbe5315d7b7f6abd6260c1c0b1f5da8cb5e98fb9b7b04a5`.
The real document window was 316. Both native screenshots were inspected:

- `/tmp/macws-office-ondevice-release-20260919-ppt-initial.png`: normal
  orange cover, logo, and populated nonblack slide thumbnails.
- `/tmp/macws-office-ondevice-release-20260919-ppt-slide3.png`: toolbar,
  comments panel, reply field, and status-bar images all visible at normal
  geometry, with correct white/orange thumbnail backgrounds.

The real `Quit PowerPoint` menu item 9 was delivered to this owned window;
the following process inventory confirmed PID 63261 had exited and user
PowerPoint 19000 and Terminal 17280 were unchanged. The detached observer's
300-second observation period had already expired before Quit, so its
receipt says `still-running-not-killed`; **a numeric exit status was not
captured and is not asserted**. Receipt and launch log are preserved at
`/tmp/macws-office-ondevice-release-20260919-ppt.{json,log}` on the device
and the local machine. Word and Excel were deliberately deferred to the
post-install canonical-library check, rather than counted as covered by
this PowerPoint-only package test.

The reusable test-only entry point is
`/tmp/macws_office_release_acceptance_20260919.py`, taking explicit product,
operation, candidate path, expected signed SHA, expected mapped UUID, fresh
receipt prefix, and the two protected user PIDs. Its separate read-only
identity helper is `/tmp/macws_office_release_identity_20260919`. Neither
tool is installed into production startup or changes application behavior.

## Installed package: canonical Word and Excel visual acceptance

After the package installation, Word and Excel were tested sequentially
against the **installed canonical** arm64 library, not a `/tmp` substitute:

```text
chroot path: /usr/local/lib/libmachook_arm64.dylib
installed signed SHA256: 273edeca9604272d4305b6c7f9b630d011367ce8c530701ca95ca8084454a141
actual mapped UUID in both applications: 5EC31E06-F7D0-38CE-9989-34862E420C21
mapped __text bytes: 668868
mapped __text SHA256: 7f9c6e06380acedd01f8bc2758e473d4f92e340dfc40c774185c7f4f005769f1
```

Both launches had no observer dylib and no diagnostic environment/flag.
The same stock source hashes were checked before copying and before target-PID
delivery. Word PID 67368/window 322 showed the previously missing blue
Quick Access Toolbar image and the menu screenshot on page 1. The actual
native screenshot is
`/tmp/macws-office-installed-release-20260919-word-images.png`.
The old user PowerPoint visible **behind** Word still showed its old black
thumbnails; that process was deliberately preserved and still used its old
library mapping. It is not a failure of this new Word process.

Excel PID 67644/window 329 showed the stock Start sheet with its green
welcome panel, complete white Excel logo, and orange owl illustration in
`/tmp/macws-office-installed-release-20260919-excel-images.png`.
Both images were inspected, rather than accepted from the document-open ACK.

Each owned application was closed using its real Quit menu. Excel's prompt
was first captured and checked to name only the newly instantiated owned
template (`...excel-owned1`), then its **Don't Save** button was selected;
that screenshot is
`/tmp/macws-office-installed-release-20260919-excel-quit.png`.
The detached launchers recorded `state=exited, returncode=0` for **both**
applications. Receipts and logs are
`/tmp/macws-office-installed-release-20260919-{word,excel}.{json,log}`
on the local machine and device. Final process checks retained user
PowerPoint 19000 and Terminal 17280 unchanged. No production service,
library, or user document was modified by these acceptance steps.
