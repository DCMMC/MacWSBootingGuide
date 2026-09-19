# Weather: Mission Control transformed-window capture investigation

Status: **Weather's solid-black Mission Control card is fixed and visually
accepted in a fresh rendering generation**. The upstream IOSurface metadata
fault was reproduced, the complete candidate passed native CA pixel and
protection-preservation controls on both CPU slices, and the actual full
iPadOS before/after images were independently inspected. No Host thumbnail
overlay or native-AGX disabling was introduced. The earlier negative results
below are retained to distinguish evidence from disproved theories. This does
not claim that all Weather color/background rendering is correct.

## Runtime and bounded method

Device iPad13,6 / iPadOS 16.3, 2026-09-19. WindowServer PID 99427, Dock 773,
UIKitSystem 9915, Weather 9917, Weather CGWindow 235. Existing processes were
not restarted or attached/suspended by a debugger. Live metadata was read with
`task_for_pid` / `mach_vm_read_overwrite`; each offscreen CA request used one
256×256 IOSurface and a 12-second process alarm. The ordinary public window
capture used nominal resolution, at most 2.54 MB for this window. No frame loop
or stress test was run.

Actual loaded images:

- QuartzCore UUID `CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC`, base `0x19b906000`.
- UIKitMacHelper UUID `12B49997-148D-3998-B7C1-EE853FCD7562`, base `0x1aba7f000`.
- SkyLight UUID `96676A53-B1E0-3D7E-B98B-B73873CD1880`, base `0x19902d000`.

Full iPadOS screenshots were manually inspected before, during and after the
native kind-21 vertical system gesture. Mission Control showed normal Finder,
Terminal and Activity Monitor windows, but an entirely black Weather rectangle.
Escape was delivered to Dock after each bounded witness. Screenshots remain
outside Git because they include the user's desktop.

## The real app-owned CA hierarchy exists and renders

Runtime-confirmed chain, reconstructed from actual class/ivar metadata:

```
Weather NSWindow 235
  UINSSceneContainerView -> UINSSceneView
  CALayerHost contextId 0x621e0552, shouldHostContent=1
    UIKitSystem aggregate context 0x621e0552
      CALayerHost contextId 0x5d2a4394
        Weather UIWindow context 0x5d2a4394
          UIWindowLayer -> ... -> CAMetalLayer
```

The AppKit backing context is `0x2e8deb36`. The Weather UIWindow context's
restricted-host PID is 9915; the aggregate context's restricted-host PID is
9917. These match the actual hosting processes, rather than an unrelated PID.

RE-confirmed UIKitMacHelper `-[UINSSceneView _setHostedContextId:]` at `+0xb71c`
creates `USSLayerHost layerHostForContextID:`, installs geometry/transform and
adds it to the zoom layer in a disabled-actions CA transaction. The factory at
`+0xb900` returns an actual **CALayerHost**. Assuming it has USSLayerHost's ivar
layout would be wrong. QuartzCore `-[CAContext restrictedHostProcessId]` at
`+0x2e9688` reads `*(uint32_t *)(impl + 0xa4)`.

The existing direct-drawable publication wrappers in `Metal_hooks.x` observe
completion/presentation and still forward to their saved original present
methods. This investigation found no replacement of the normal present call.

Using the stock
`CARenderServerRenderDisplayLayerWithTransformTimeOffsetAndFlags` entry at
QuartzCore `+0x1dc5d8`, `defaultDisplay`, raw-layer flag `0x10`, and scale 0.25:

```
# During visually confirmed Mission Control, while Weather's thumbnail is black:
render-begin context=2e8deb36 raw-layer=93b38d02bfa6c39c port=7171 surface=342
render-end result=1 sentinel=0 nonzero=39356 opaque=39356 colored=39245 hash=6acd833bfb804f4a first=0,0,0,0
render-begin context=621e0552 raw-layer=e4a9619205f2ce07 port=6659 surface=1003
render-end result=1 sentinel=0 nonzero=39360 opaque=39360 colored=39251 hash=3dafb7e89b017908 first=116,80,76,255
render-begin context=5d2a4394 raw-layer=93b38d02bfb6558c port=6659 surface=952
render-end result=1 sentinel=0 nonzero=39360 opaque=39360 colored=39251 hash=3dafb7e89b017908 first=116,80,76,255
```

All PNGs were inspected: actual application controls and graphics, not just
nonzero title-bar pixels. Aggregate and UIWindow have the same rendered hash.
The raw AppKit-root request has flipped nested geometry; this bounded probe
does not synthesize the AppKit coordinate correction. That observation alone
is not promoted to a cause.

The probe's CA server port was checked against the explicitly named macOS
endpoint in the same task, not inferred from a symbol name:

```
server-port=6915 bootstrap-macos-port=6915 kr=0 same=1
```

Therefore absent client publication, wrong host-process restriction, and loss
of the provider content during Mission Control are disproven for this runtime.

## The transformed WindowServer capture is already black

The decisive discriminator does **not** use Host's drawable overlay or its
final-composite transport: `CGWindowListCreateImage` with including-window 235,
bounds-ignore-framing, and nominal resolution. Runtime excerpts:

```
# Before Mission Control:
window-transform window=235 connection=156611 result=0 a=1 b=0 c=0 d=1 tx=-148 ty=-34
window=235 owner=9917 layer=0 bounds=148.0,34.0,985.0,640.0 onscreen=1
image=985x640 row=3968
image-data size=2539520 nonzero-bytes=2521149 hash=d521bc1c473f980c

# During visually confirmed Mission Control:
window-transform window=235 connection=307723 result=0 a=1 b=0 c=0 d=1 tx=-148 ty=-34
window=235 owner=9917 layer=0 bounds=653.0,412.0,523.0,340.0 onscreen=1
image=523x340 row=2176
image-data size=739840 nonzero-bytes=544 hash=9edc4dace3788d9f

# After Escape, same app/window, no restart:
window-transform window=235 connection=517547 result=0 a=1 b=0 c=0 d=1 tx=-148 ty=-34
window=235 owner=9917 layer=0 bounds=148.0,34.0,985.0,640.0 onscreen=1
image=985x640 row=3968
image-data size=2539520 nonzero-bytes=2521149 hash=ffd473f8c42ef2e8
```

The during-MC image was manually inspected: black with a few small stray
pixels. The normal image has the complete application and colored background.
Thus the failure exists at WindowServer's transformed-window capture, before
Host's final-composite copy or overlay. A final-composite-copy failure alone
cannot explain this independent image result.

RE-confirmed `SLSGetWindowTransform` at SkyLight `+0xb7f48` forwards arguments
to `+0xb4e94`, with placement arguments zero; the latter writes six doubles to
the output pointer. This **default** transform remains unchanged while the
reported window bounds shrink. Do not claim the Mission Control transform is
identity: this query does not expose the transform reflected in those bounds.
Actual Dock arm64e imports and calls `SLSTransactionSetWindowTransform` and
`CGSSetWindowTransformAtPlacement`. Connecting a specific live call to Weather
remains an evidence gap.

A subsequent read-only query of exported `SLSGetWindowTransformAtPlacement`
(`+0xb4e94`, five-argument ABI confirmed in its real implementation) used
placement `0x20000000`, observed as a constant in one actual Dock transaction
wrapper. It returned identity both before and during MC, despite the same
985×640 → 523×340 bounds change. Therefore this placement is **not** evidence
of the effective Mission Control transform; no other guessed placement values
were swept and no transform was modified.

```
window-placement window=235 placement=20000000 result=0 tag=0 a=1 b=0 c=0 d=1 tx=0 ty=0
```

### AppKit control and effective transform

The first attempted Terminal control incorrectly selected hidden tab window
294 from the app's metrics array and got no CGWindow entry. That attempt is
**inconclusive**, not a black-image result. An actual on-screen window query
identified Terminal's current window 300, which was then captured during the
same MC state as Weather. Terminal's image was manually inspected and is fully
correct. Weather remains corrupt with both default image options and nominal
resolution **without** `BoundsIgnoreFraming`:

```
window-catenated window=300 result=0 a=1.88160682 b=0 c=0 d=1.88036811 tx=-319.873138 ty=-148.549072
window=300 owner=13515 layer=0 bounds=170.0,79.0,473.0,326.0 onscreen=1
capture-options=17
image=473x326 row=1920
image-data size=625920 nonzero-bytes=613915 hash=531467c614803b79

window-catenated window=235 result=0 a=1.88336515 b=0 c=0 d=1.88235295 tx=-1229.83752 ty=-775.529419
window=235 owner=9917 layer=0 bounds=653.0,412.0,523.0,340.0 onscreen=1
capture-options=0
image=1166x802 row=4736
image-data size=3798272 nonzero-bytes=259281 hash=2d1a7799fc781b8d

window-catenated window=235 result=0 a=1.88336515 b=0 c=0 d=1.88235295 tx=-1229.83752 ty=-775.529419
capture-options=16
image=583x401 row=2432
image-data size=975232 nonzero-bytes=92408 hash=874a125936adec0
```

Weather's two images have a black client and small rectangular white/cyan
artifacts near edges; no actual application content is present. The larger
dimensions include native shadow/framing. This control rules out a generic
inability of the CGWindow capture API to capture any transformed MC window.

The effective transform above uses exported
`SLSGetCatenatedWindowTransform`, discovered by reading only the actual live
SkyLight 48,896-byte export trie. Its implementation at `+0xb5da0` calls the
placement getter with `0x7fffff00` and writes six doubles. It is the inverse
mapping (scale greater than one) for the smaller destination bounds; it is not
an app resize. No transform was set by the probe.

Dock's transient CA contexts inspected during MC contained material/text roots
and one empty root, not a Weather CALayerHost. Their tiny renders did not
provide a separate Weather thumbnail buffer. That is not proof that Dock never
uses another snapshot mechanism.

### The equivalent stock-CA affine render succeeds

An additional isolated 256×256 CA request applied the inverse of the observed
effective MC transform, followed by a 0.2 whole-desktop scale. Its matrix used
`sx=0.106192893207, sy=0.106249999502, tx=130.599999, ty=82.4`.
This reproduces both the MC shrinking and destination translation, rather than
only an identity or origin-aligned render. No window transform was changed.

```
# AppKit context 2e8deb36:
render-end result=1 sentinel=0 nonzero=7072 opaque=7071 colored=7048 hash=8bb437526f213922
# Aggregate context 621e0552:
render-end result=1 sentinel=0 nonzero=7821 opaque=7820 colored=7801 hash=be777b2aeb861d58
```

Both images were inspected and contain the actual small Weather UI at the
translated location, not an empty background. General CA affine sampling of
the published hierarchy therefore works. The remaining distinction is the
CGXWindow / SkyLight backing-composition path.

## Exact WindowServer capture and flattening boundary

RE-confirmed from the **running** SkyLight UUID above, with no debugger attach
or process suspension. Only its 322,000-byte nlist, a 917,504-byte local-symbol
name range, and individual small functions were read; the large shared cache
was not extracted.

- `CGWindowListCreateImage` / `SLWindowListCreateImage` at `+0xf9b38`
  constructs MIG request `0x7495`.
- Its actual server handler `__XWindowListCreateImage`, `+0x35a97c`, resolves
  the requested window array and calls `captureWindowList`, `+0xbd32c`.
- `runCapturePass`, `+0xb8fe8`, calls `CaptureSurfacePopulateWithArray`.
- `CaptureSurfaceMetal::Populate(array)`, `+0x311b88`, obtains the real Metal
  compositor and calls `WSRedrawWindowsToDestinationAndRegion`, `+0x2ae4d0`.
  That function prepares Core Animation backing and generates the window's
  composite layers. It is not a Host thumbnail implementation.
- `WSCAWindowBacking::PopulateFlattenedContent`, `+0x2037d0`, uses the backing's
  `+0x2e8` flattened bit and publishes the flattened representation's actual
  surface into the backing's `+0x2e0` contents slot. The representation getter
  `WSCALayerBacking::GetFlattenedRepresentation`, `+0x234ee8`, reads `+0x1c8`.

The exact `CGXWindowByID` / session hash lookup was reproduced by a bounded
read-only metadata reader (at most 100 small reads, eight-second alarm). One
normal-state observation, **not a failing-MC witness**, was:

```
window=235 CGX=13ec8f000 type=5 visible=1 backing=13fadfa00 scale-bits=40000000
backing=13fadfa00 vtable=1f1407980 window=235 host-context=2e8deb36 flattened=0 layer-backing=16a8c4210 flattened-content=0 field1d8=13de2d630 field1e0=13de2d630 filter=1
representation=12aff0470 capture=160015330 state=101
capture=160015330 vtable=1f140d210 IOSurface=13f2476b0 metal-backing=178e11b40 format=11 scaleBits=40000000
IOSurface=13f2476b0 client=287e8a780 id=962 width=1970 height=1280 row=9856 pf=62336138 planes=2 base=0
```

The associated real AGX texture's inherited IOGPUMetalTexture ivars, verified
against the actual class metadata, report pixel format 550, width 1970,
height 1280 and the same IOSurface pointer. The surface is `b3a8`, the
uncompressed two-plane RGB10-plus-alpha format, not the compressed `&b38`
format. These dimensions agree with the normal 985×640 logical window at 2×;
they do not establish the failing MC backing or prove the sampled pixels.
The normal flattened bit can change as backing is refreshed; stale pointers
from separate snapshots must not be treated as one atomic observation.

The working Terminal control is **not** evidence of a BGRA-only path. Its
normal backing uses the same WSPixelFormat 11 / AGX format 550, but a different
storage producer:

```
# Terminal 300:
layer=28494e280 vtable=1f14098e0 flattened-rep=13f42b520 field88=4d flags1f0=0
capture=13f42d010 vtable=1f140d210 IOSurface=0 metal-backing=13f429960 format=11 scaleBits=40000000
metal-backing=13f429960 vtable=1f140d618 format=11 dimensions=1780x1226 contexts=1
texture=284fded20 class=230d9a5f0 IOSurface=13f43c5c0 plane=0 type=2 pf=550 usage=5 width=1780 height=1226 depth=1 mips=1 sample=1 row=114688 impl=284fc99b0
```

The real class metadata identifies the ivars used for these reads. Terminal's
CaptureSurface uses plain `MetalBacking`; Weather's uses
`MetalIOSurfaceBacking`, with `WSCALayerBacking +0x1f0` set to one. The actual
`WSCALayerBacking::Flatten` implementation at `+0x237654` branches on this byte
before creating the capture surface. The difference is real, but has not yet
been shown to violate a storage/layout invariant. No format was forced and no
private pf550 surface was sampled by an unrelated GPU queue.

### Isolated fresh-producer storage control

A standalone, non-GUI test using the then-current canonical libmachook UUID
`7C247FAD-482D-31F4-9008-04B4D4FC060C` allocated **only its own** 16×16 inputs
and BGRA output. Each ten-second-bounded process used one GPU queue, one command
buffer, a clear pass followed by a fragment sampling pass, and completion before
reading the owned BGRA result. It did not import any WindowServer surface.
The fragment/vertex library was created from Metal source through the current
compiler, not either old cached Core Image library above.

All three controls passed:

```
device=Apple M1 kind=bgra
input=0x11e60b210 pf=80 width=16 height=16 surface=0x0
command-status=4 error=none
result-bgra=191,128,64,255 mismatched-pixels=0/256

device=Apple M1 kind=b3a8
surface=321 pf=62336138 planes=2 width=16 height=16
input=0x160013860 pf=550 width=16 height=16 surface=0x16000c310
command-status=4 error=none
result-bgra=191,128,64,255 mismatched-pixels=0/256

device=Apple M1 kind=scratch
input=0x155840e80 pf=550 width=16 height=16 surface=0x0
command-status=4 error=none
result-bgra=191,128,64,255 mismatched-pixels=0/256
```

Thus the new canonical runtime supports this ordinary `b3a8`/pf550
clear-and-sample contract. The `scratch` control is a non-WS native allocation,
not proof that it follows WindowServer's scoped scratch allocation hook.
Neither successful control explains the old live WS's transformed backing.

The same bounded `b3a8` clear-and-sample control was then run with the **exact
arm64 libmachook generation still mapped by WS**, not an arbitrary older build.
A separate native test launcher set the candidate dylib before directly spawning
the isolated test. No canonical library was replaced:

```
library=/private/tmp/libmachook-ws21383704-test.dylib uuid=213837045f0a31229cad6069105f913a
device=Apple M1 kind=b3a8
surface=637 pf=62336138 planes=2 width=16 height=16
input=0x11de5ed10 pf=550 width=16 height=16 surface=0x11de58190
command-status=4 error=none
result-bgra=191,128,64,255 mismatched-pixels=0/256
```

The current canonical control also returned the same pixels with zero
mismatches. This excludes a general inability of either generation to clear
and sample an ordinary owned two-plane `b3a8` Metal texture. It does not validate
the actual Weather flatten producer or its later Core Animation consumer.

### Paired live MC backing and private capture control

A later 6.7-second MC witness captured the actual iPadOS display, both live
backing records, and two native private captures, then sent Escape. Weather
remained black and the AppKit controls visible. During that witness:

```
# Weather 235:
backing=13fadfa00 host-context=2e8deb36 flattened=1 layer-backing=16a8c4210 flattened-content=13f2476b0
layer=16a8c4210 flags1f0=1 representation=12aff0470 capture=160015330
capture=160015330 IOSurface=13f2476b0 metal-backing=178e11b40 format=11
texture=2b58cc1d0 IOSurface=13f2476b0 plane=0 pf=550 width=1970 height=1280 row=7936

# Terminal 300, in the same MC interval:
layer=28494e280 flags1f0=0 representation=13f42b520 capture=13f42d010
capture=13f42d010 IOSurface=0 metal-backing=13f429960 format=11
texture=284fded20 IOSurface=13f43c5c0 plane=0 pf=550 width=1780 height=1226 row=114688
```

This establishes the storage-producer difference in the actual failing state,
not just at rest. Independent reads are not an atomic frame snapshot.

The real `SLSCaptureWindowsContentsToRectWithOptions` implementation at
SkyLight `+0xfa584` was decoded before calling its six-argument ABI. Flags
`1` and `0x80001` both returned success and a black 926×624 image with the same
small edge artifacts. The actual exported
`kSLSWindowCaptureIgnoreDeformingTransforms` value is `0x80000`. It did **not**
remove the MC affine transform: the queried window bounds remained shrunken.
Therefore this test is only a negative result for that private option, not
proof that an untransformed backing capture is black.

### Actual flatten producer versus the successful standalone CA request

Additional RE of the same live SkyLight maps the flatten producer through:

```
WSCALayerBacking::Flatten (+0x237654)
  create_source_layer_for_flatten (+0x136448)
  CaptureSurfaceMetal::Populate(WSCompositeSourceLayer*) (+0x311e54)
  CompositorMetal::CompositeLayersToDestination (+0x32cdc4)
  MetalCompositeCoreAnimation (+0x91a14)
```

`create_source_layer_for_flatten` supplies the backing's existing CARenderUpdate
(`+0xa8`); the destination is its actual capture Metal texture. The compositor
passes its current Metal state using `CARenderMTLSetState`, and the capture
destination flags select `CARenderOGLRender` rather than the ordinary display
render entry. The historical OGL API name does **not** mean CPU/OpenGL rendering:
the passed renderer/state are Metal. These imports were resolved from the real
live stubs and QuartzCore export trie, not guessed from function names.

This is a distinct producer from the independently successful
CARenderServer request. The distinction needs an actual failing invariant or
pixel witness before changing either path. Stock `RunUpdate` also calls
`CARenderUpdateSetAllowsHostedContexts(update, true)` for its isolated branch;
there is no evidence yet that simply enabling a missing hosting flag is the fix.

### A minimal Core Animation surface-consumer discriminator

`misc/macws_ca_surface_probe.m` is a standalone optional diagnostic, not part of
startup. It clears an owned 16×16 IOSurface with Metal, sets that surface as a
CALayer's contents, shrinks the layer to 8×8, and uses stock CARenderer with the
same Metal queue to render into an owned BGRA output. A subsequent same-queue
command completes before the result is read. Both bounded processes exited;
no UI or external app context was used.

With the same canonical UUID `7c247fad482d31f4900804b4d4fc060c`:

```
kind=bgra surface=369 clear-status=4 error=none
ca-fence-status=4 error=none
ca-center-bgra=191,128,64,255 colored=64/64 opaque=64/64

kind=b3a8 surface=165 clear-status=4 error=none
ca-fence-status=4 error=none
ca-center-bgra=0,0,0,255 colored=0/64 opaque=64/64
```

This is a reproducible discriminator at the **Core Animation consumer**, while
ordinary Metal direct sampling of the same minimal `b3a8` property layout works.
It removes Mission Control, old WS state and user-window contents from this
particular failure. It does not yet establish the production root cause:
the minimal two-plane surface's component metadata and actual CA texture-import
arguments must be compared with the stock producer. In particular, successful
Metal sampling alone does not prove that all metadata required by CA is present.
These two calls preceded the final compiler-package installation; the old
compiler generation had been restored after the sibling agent's isolated
compiler test. Repeat after installation and compare the same source built
as an iOS-native, non-injected control before attributing the cause to layout.
No production ABI/format fallback has been added on this evidence.

### Native control, post-install repeat and a bounded consumer trace

The same source was compiled for native iOS, without injection. Its `b3a8`
surface has the same plane sizes/strides/offsets as the macOS probe. The native
consumer imports pixel format 550 and renders the expected pixels; the macOS
consumer makes no observed IOSurface texture import and renders black. The
repeat used the installed on-device LLVM libmachook UUID
`2be0ad84-7995-373f-84f4-d38fb0583ae1`; the actual main and injected-library Mach
headers both reported CPU subtype `0x80000002`, independently of the compiler's
command-line architecture spelling. These are not old-WindowServer-only results.

```
macOS b3a8: clear-status=4; ca-fence-status=4
ca-center-bgra=0,0,0,255 colored=0/64 opaque=64/64; exit=9

native iOS b3a8:
ca-import[1] caller=/System/Library/Frameworks/QuartzCore.framework/QuartzCore pf=550 size=16x16 plane=0 usage=1 storage=0 surface-pf=62336138 planes=2
ca-center-bgra=191,128,65,255 colored=64/64 opaque=64/64; exit=0

macOS BGRA:
ca-import[1] caller=/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore pf=80 size=16x16 plane=0 usage=1 storage=1 surface-pf=42475241 planes=0
ca-center-bgra=191,128,64,255 colored=64/64 opaque=64/64; exit=0
```

The trace wrappers are confined to this diagnostic's process and forward every
original argument and return value unchanged. There is no live app swizzle.

RE-confirmed in the captured macOS QuartzCore UUID above:
`four_cc_to_mtl_format` tests `MetalLimits` bit `0x100` before converting `b3a8`
to Metal format 550. The constructor obtains that bit from
`-[MTLDevice supportsFamily:1003]` (Apple3). This tempting explanation was
**disproved**, not patched: both native and macOS CA call that selector and
receive `1`. Native Apple8 reports `0`, showing the observer did not replace
capabilities with an unconditional success result.

A final old-generation trace attached only to the self-owned 16×16 probe,
with three hardware breakpoints and a 25-second external deadline. The
`CA::Render::Surface` constructor completed with format `0x23` and FourCC
`0x62336138`. Neither the Metal FourCC conversion nor Metal `update_surface`
breakpoint fired before the probe naturally exited `9`. Its constructor field
at `Surface+0x98` was `0x1000000000`. The meaning/source of that unexpected value
needs confirmation against the actual IOSurface import before any fix. The
debugger did not attach to WindowServer or a user app and left no stopped probe.

All PIDs/absolute addresses in these records belong to the pre-reboot generation.
After the subsequent device reboot they must not be reused.

## WindowServer still holds two pre-fix Core Image libraries

A native read-only `proc_pidfdinfo` query confirms the current WS has open:

```
fd=11 inode=24121256 path=/private/var/mnt/rootfs/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/WindowServer/com.apple.WindowServer/com.apple.metal/31001/libraries.data
```

The same inode was verified with `stat`; its size is 2,211,840 bytes. A bounded
64-KiB streaming scan identified 259 valid MTLB records: 257 desktop-compatible
`0x8001` records and two old `0x0001` iOS-only records. Only those two small
records were copied for analysis:

| Record offset | Length | Header prefix | Name / target | SHA-256 |
| --- | ---: | --- | --- | --- |
| 1637280 | 6804 | `4d544c42010002000700008210000300` | `ciKernelMain`, `air64-apple-ios16.3.0` | `4ace918c99c3dd4ca92c429c7aa917206e0a172f429a2ca352ee6820cbd2d94c` |
| 1795744 | 6788 | `4d544c42010002000700008210000300` | `ciKernelMain`, `air64-apple-ios16.3.0` | `cfe64da5592f171045120b2cbacce760f881d3bd5ac0dbce5b8ad79c0a88b1ad` |

This establishes retained pre-fix CI artifacts in the live WS generation. It
does **not** connect either generic `ciKernelMain` library to Weather flattening;
that causal association still needs evidence. Absence of new compiler errors
cannot exclude a cache hit. Removing a file while the process retains decoded
objects would not itself prove a live fix. No WS cache was changed or service
restarted by this investigation.

## Remaining work / excluded inferences

- Trace the placement-specific window transform and its WindowServer backing
  render/scaled sampling contract; keep the existing app-owned CA publication.
- Check whether the same transformed capture failure affects other Catalyst
  windows. This investigation establishes Weather only.
- `FINAL-COMPOSITE snapshot-failed stage=copy-completion` exists in the WS log,
  but those bounded lines lack timestamps and have no established causal link
  to the MC failure. Recent Dock/WS log tails had no new Metal library-platform
  or CI-DAG error. Neither fact proves shaders are correct.
- VNC captured the normal Weather desktop during one actual MC state, so VNC
  alone is not a valid MC acceptance witness in this configuration.
- Normal Host display has a black upper Weather background whereas the normal
  public CGWindow capture has a colored background. This is a separate
  presentation difference; do not silently combine it with the MC root cause.

No actual Weather Mission Control acceptance or performance improvement is
claimed by the preceding observations alone.

## Confirmed upstream cause: protection-options ABI mismatch

After reboot, the native kernel reports `kern.osversion: 20D67` and
`kern.osproductversion: 16.3.1`. New self-owned surfaces reproduce the failure
without WindowServer, Weather, Host overlays, or an old WS Metal cache.

RE-confirmed from the actual loaded IOSurface images:

| Consumer | Framework UUID | Client getter offset / actual instructions |
| --- | --- | --- |
| macOS 13.4 | `2B44B850-7D19-34F3-AB8E-A3B93016A96D` | `+0x3df8`: `f9406400` (`ldr x0,[x0,#0xc8]`), `d65f03c0` (`ret`) |
| iOS 16.3.1 | `DF041B53-4BAA-3668-8781-43DE39FA8905` | `+0x2aac`: `f9403808` (`ldr x8,[x0,#0x70]`), `f9401900` (`ldr x0,[x8,#0x30]`), `d65f03c0` (`ret`) |

The public C getter resolves the `_impl` client at object offset 8 in both
images. The macOS Objective-C `-[IOSurface protectionOptions]` implementation
at `+0x6564` directly tailcalls its own Client getter, so a C interpose alone
does not cover that entry point.

Runtime-confirmed via `/tmp/macws-iosurface-protection-{native,mac}-fields-20260919.log`:

| Self-owned 16×16 surface | Requested / shared-header value | Native C getter | Unadapted macOS C getter |
| --- | ---: | ---: | ---: |
| BGRA | 0 | 0 | 0 |
| b3a8 | 0 | 0 | `0x1000000000` |
| BGRA | 1 | 1 | 0 |
| b3a8 | 1 | 1 | `0x1000000000` |

For example, these are verbatim adjacent lines for the unadapted macOS
protected BGRA case:

```
kind=BGRA protection=0 surface=0x152f05b90
ivar=_impl offset=8
client=0x152e53740 +b0=000000000000000000000000000000007520000000000001000000000000000000000000000000000000000000000000
shared=0x10241d140 options=0x1
```

The macOS cached field `client+0xc8` does not contain the iOS protocol's current
protection options. On the planar control it overlaps the plane-0 width and
reports `16<<32`. This feeds the already-captured CA Surface protection field
and causes CA's genuine protection check to reject normal content *before*
Metal import. Masking off high bits or returning zero would be wrong: it also
silently loses genuine protection bit 1 on BGRA.

### Candidate implementation and strict scope

`libmachook/mac_hooks.m` adapts Public C, Client C, AGX symbol imports, and the
framework-internal ObjC entry point to read the **current full 64-bit value**
from `client->shared(+0x70)->protectionOptions(+0x30)`, matching the measured
native getter. It changes no creation property, pixel format, compression
setting, shader, QuartzCore protection decision, or executable text page.

The adapter is enabled by default only for the measured pair: kernel build
`20D67`, exact macOS IOSurface UUID above, exact Client getter instructions,
and `_impl` offset 8. The ObjC replacement additionally validates its original
IMP owner UUID, offset, and type encoding. Unknown ABI, nil client, or absent
shared metadata delegates to the original API/IMP behavior, never to a
synthetic unprotected result. This is not an arbitrary-invalid-pointer guard.

Early absent ObjC registration leaves initialization retryable; concurrent
first callers wait until the complete ABI decision is published. The cached
hot path does not do filesystem probes, environment lookups, logging, or GPU
work. No production flag is required.

### Complete-candidate runtime witnesses (no auxiliary shim)

Isolated local Apple-ld64 build, source `mac_hooks.m` SHA-256
`6cd9cd344d48b3603314c7ca4499f6002fd9b7063d28e36cf8108d6db30e00bb`, helper header
SHA-256 `3c2113e3013dd241f7a037fe070a667fb6f49024a0ab79fbeaf575db27cf9bb4`.
Actual mapped candidate UUIDs:

- arm64e `A2F517DE-9C6D-3D45-AFE3-458F72E58929`;
- arm64 `60605E64-23C8-384B-A884-BC0B20D4CE52`.

`misc/macws_ca_surface_probe.m` uses only its own 16×16 surface, one queue, one
clear and one stock CARenderer render, with a ten-second deadline. Both slices
now report the real QuartzCore pf550 import and these verbatim results:

```
surface-protection-options=0
ca-import[1] caller=/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore pf=550 size=16x16 plane=0 usage=1 storage=1 surface-pf=62336138 planes=2
ca-fence-status=4 error=none
ca-center-bgra=191,128,65,255 colored=64/64 opaque=64/64
```

The unadapted same-source b3a8 control produced black, `colored=0/64`, exit 9;
the native iOS positive control produced `colored=64/64`. The BGRA full
candidate control remains `191,128,64,255`, `colored=64/64`.

`misc/macws_iosurface_protection_probe.m` additionally verifies all three entry
points on both CPU slices; both BGRA and b3a8 retain actual protection 1:

```
format=BGRA expected=0x1 public=0x1 client=0x1 objc=0x1
format=b3a8 expected=0x1 public=0x1 client=0x1 objc=0x1
```

Both tiny native-Metal/fork tests preserve stock `objc_msgSendSuper2` AUTDA
`0xdac11a30`, produce `gpu-clear-bgra=191,128,64,255`, reach
`fork-child-reached-main`, and reap child exit 0. No user process was paused,
closed, or modified. All these isolated test processes naturally exited.

Host tests exercise all 64 protection bits, current-value rereads, missing
metadata fallback, and the **actual extracted production readiness function**
under concurrent initial calls and initially absent ObjC registration. These
tests and source guards do not substitute for the actual pixel witnesses.

## Controlled publication and actual baseline

The post-reboot unadapted production generation reproduced the same visible
fault after selecting a real city: the complete iPadOS Mission Control image
`/tmp/macws-weather-newboot-selected-mc-before.png` shows a solid black Weather
rectangle while Terminal remains fully rendered. An initially empty Weather
detail view was not a valid like-for-like control and was excluded.

Only the test Terminal and test Weather were normally quit. After verifying
no WindowServer remained, the four canonical thin-library paths were published
using separately created new inodes and atomic renames, never in-place writes.
Each old inode has a same-filesystem hardlink backup. The durable receipt is
`/tmp/macws-iosurface-canonical-install-20260919.json`, final status
`installed-four-paths-verified`. Signed candidate hashes are:

- arm64e `461df2bb29c20d2737590dba0302345a3c7de9fbcbcd5e45917a8302d111b857`;
- arm64 `1b4cbfa2e3cdff579c6d065c99df05ca222901cc8185ddd202a006ec7c91c2b4`.

The transaction does not control services and includes interruption-safe
rollback using actual current hashes and the original inode backups.

## Actual full-iPadOS Mission Control acceptance

The main agent restarted the GUI through the normal startup path after the
controlled library publication, selected the same city with real forecast
content, and entered actual Mission Control. No diagnostic flag was needed.
Both the main agent and this investigating agent independently opened these
complete native iPadOS captures (not VNC, not the isolated CA probe):

- Before: `/tmp/macws-weather-newboot-selected-mc-before.png` — the Weather
  rectangle is entirely black; the neighboring Terminal window renders.
- After: `/tmp/macws-weather-candidate-mc-after.png` — the same Weather card
  visibly contains Beijing's `81°` title, city sidebar, `49 - Excellent` AQI
  display and colored AQI map, hourly forecast, and visible 10-day forecast;
  Terminal still renders normally.
- Repeat: `/tmp/macws-weather-candidate-mc-second.png` again contains the full
  Weather card; `/tmp/macws-weather-candidate-returned.png` confirms the
  ordinary window still renders after leaving Mission Control. Both repeat
  images were independently inspected too.

The freshly running WindowServer is PID 16900, using the arm64 candidate
`60605E64-23C8-384B-A884-BC0B20D4CE52`; Weather PID 17270 uses arm64e candidate
`A2F517DE-9C6D-3D45-AFE3-458F72E58929`. This closes the gap between the small
causal ABI reproduction and the original user-visible MC black-card failure.
The non-suspending live-image receipt
`/tmp/macws-weather-candidate-mapped-20260919.log` records verbatim:

```
pid=16900 process=WindowServer task-for-pid=0
image=libmachook_arm64.dylib base=0x1006ec000 cpu=16777228 subtype=0 uuid=60605e6423c8384ba884bc0b20d4ce52 text-address=0x1006f0000 text-bytes=633912 text-sha256=e896416471393fb6268576170bf35fc5b7df92466fd3a8e55938131e054ac14f
image-count=479 matched=1 requested=1 no-suspend=yes
pid=17270 process=Weather task-for-pid=0
image=libmachook.dylib base=0x103c6c000 cpu=16777228 subtype=2147483650 uuid=a2f517de9c6d3d45afe3458f72e58929 text-address=0x103c70000 text-bytes=616528 text-sha256=2626650d87e2c0103e216c3badf57beb83e9721aeb4e1000703d5d126b9b1394
image-count=895 matched=1 requested=1 no-suspend=yes
```

Acceptance scope is deliberately narrow. A gray Weather background is visible
both inside MC and after returning to ordinary presentation, so it is not an
MC-only difference. The earlier blue appearance and this gray one are not a
controlled color experiment; they establish neither a separate color bug nor
a color fix. This evidence does not establish that all Weather graphics,
every Catalyst app, or animation/thermal behavior is perfect. The
captures stay outside Git because they contain the user's desktop.
