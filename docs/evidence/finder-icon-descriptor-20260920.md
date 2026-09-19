# Finder large-icon display contract, 2026-09-20

## Scope and outcome

This is an investigation, **not a production fix or a passing Finder UI
acceptance**. No Finder/UI interaction, process attachment, service restart,
cache deletion, or production library change was performed for this control.
The only device writes were the standalone diagnostic executable in chroot
`/tmp` and its normal signing/trust registration. Both specified original files
were opened read-only.

The descriptor and CPU layer-consumer control passes all sixteen cases. This
disconfirms a universal failure of large IconServices rasters or AppKit image
layer-contents in a fresh process. It does not establish which objects the
already-running Finder actually holds, nor exercise WindowServer's on-screen
GPU composition of those objects. The separate QuickLook generation failure
remains real, but cannot by itself explain why the normal icon fallback is blank.

## Actual Finder binary

Read-only copy of the device's
`/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder`:

- Local evidence: `/tmp/macws-Finder-20260919`.
- arm64e UUID: `10D552E1-7ECE-31C9-94A2-6363AA269C11`.
- Whole fat-binary SHA-256:
  `18f51f37682b3e132166bca92e27237213303f18c8f6b3eaea2e0c72f31cab06`.
- RE commands: `xcrun dyld_info -arch arm64e -objc/-fixups/-disassemble`.
  Offsets below are relative to the executable's `0x100000000` preferred base.
  No IPSW or shared-cache extraction was needed.

## RE-confirmed branches

### QuickLook is a thumbnail-only request, not the previous all-representations probe

Request factory `+0x49b95c` contains:

```text
+0x49b998 cmp w21, #0
+0x49b99c mov w8, #4
+0x49b9a0 mov w9, #2
+0x49b9a4 csel x21, x9, x8, ne
+0x49ba18 mov x3, x21
+0x49ba1c bl objc_msgSend$initWithFileAtURL:size:scale:representationTypes:
+0x49ba44 bl objc_msgSend$setIconMode:
+0x49ba6c bl objc_msgSend$setContentTypeUTI:
+0x49ba78 bl objc_msgSend$setInterpolationQuality:
```

The request chooses mask `2` or `4`, not icon mask `1` or all mask `7`.
The queue submits through
`generateBestRepresentationForRequest:completionHandler:` at `+0x3716dc`
and `+0x372558`. Thus the earlier normal type-0 icon result from
`generateRepresentationsForRequest:updateHandler:` is not evidence that this
Finder thumbnail request receives an icon fallback.

### Finder nevertheless has its own non-QuickLook icon fallback

`-[TBaseBrowserViewController iconImageForNode:]` at `+0x6427ec`:

1. Reads `showIconPreview` at `+0x642860`.
2. If enabled, looks for a cached thumbnail via `+0x2104e4`.
3. At `+0x6428ec`, only a **non-nil** cached thumbnail skips fallback.
4. Otherwise examines pending icon fetchers and finally calls the normal icon
   factory `+0x355cdc` at `+0x642944`.

`+0x355cdc` reaches the IconRef-to-ISIcon adapter `+0x20ab68`, whose actual
sequence is `_LSBindingCreateWithIconRef` at `+0x20ab90`, allocation of
`ISIcon`, and `initWithBinding:` at `+0x20abac`. The upstream node/alias/provider
branches are not replaced in the probe: Finder has NodeRef-specific icon
selection, including `_NodeGetUnbadgedIconRef` at `+0x358488`. The standalone
probe uses the public `GetIconRefFromFileInfo` for the same file. Therefore it
tests the same downstream binding/descriptor protocol, not byte-identical
in-process Finder NodeRef state.

Descriptor constructor `+0x471ec0` allocates `ISImageDescriptor`, then sets:

| Field | Real setter location | Input |
| --- | --- | --- |
| size | `+0x471f08` | requested icon size |
| scale | `+0x471f14` | backing scale |
| variantOptions | `+0x471f20` | zero |
| badgeOptions | `+0x471f2c` | zero |
| selectedVariant | `+0x471f38` | `IconImageSpec + 0x12` |
| backgroundStyle | `+0x471f44` | `IconImageSpec + 0x10` |
| templateVariant | `+0x471f50` | `IconImageSpec + 0x11` |

For the base-browser path, `+0x642854` stores the background flag and
`+0x642858` explicitly zeroes the template/selected bytes.

The real image factory `+0x471ff8` calls `prepareImageForDescriptor:` and
`CGImageForDescriptor:` (`+0x4721dc`). A non-nil CGImage is wrapped in
`NSCGImageRep`, with logical size `pixel size / scale`. At
`+0x472288..+0x4722ac`, it creates an `NSImage` and adds the collected
representations even if the collection is empty. **THEORY:** a nil or pending
descriptor raster could therefore yield a non-nil empty NSImage. This is a
possible branch, not a runtime observation from the failing Finder.

There is also a real asynchronous completion path: `+0x472574` calls
`prepareImagesForImageDescriptors:`, retrieves each `imageForDescriptor:`,
examines its `placeholder` property, extracts `CGImage`, constructs an NSImage,
and dispatches the supplied update callback. Replacing this with a fake
success or constant image would hide the producer/notification contract.

### Large-icon display uses AppKit layer contents

`-[TIconCollectionViewController configureIconView:forNode:]` calls
`iconImageForNode:` at `+0x12d73c`, then `setIconImage:` at `+0x12d754`.
`-[TIconView setIconImage:]` (`+0x1a3f14`) forwards it to the child image view.
The actual child classref at `0x100a37898` is **TTrackingImageView**, subclass
of **TBasicImageView**. `TIconImageView` is a different property/Get Info view
and is not the correct large-icon drawing observation point.

`-[TBasicImageView updateLayer]` (`+0x5dd33c`) computes scale, calls
`recommendedLayerContentsScale:` (`+0x5dd450`),
`layerContentsForContentsScale:` (`+0x5dd478`), then passes that original
object to `CALayer setContents:` (`+0x5dd498`). The object need not be a
CGImage; AppKit's `_NSImageLayerContents` is valid here.

`-[TIconCollectionViewController setShowIconPreview:]` (`+0x13322c`) calls
`reloadIconsInView` and `updateInlinePreviewEnabledState` when changed. A
controlled, reversible UI toggle is consequently a useful next discriminator
without deleting any caches.

## Bounded actual descriptor control

Source: `misc/macws_finder_icon_contract_probe.m`, standalone diagnostic only.
Build:

```sh
xcrun clang -arch arm64e -mmacosx-version-min=13.0 -O1 -fobjc-arc -fblocks \
  -Wall -Wextra -Werror -Wno-deprecated-declarations \
  misc/macws_finder_icon_contract_probe.m \
  -framework Foundation -framework AppKit -framework CoreServices \
  -framework CoreGraphics -framework QuartzCore \
  -o /tmp/macws_finder_icon_contract_probe-20260920-v3
```

The probe checks every private method's actual type encoding before dispatch,
verifies the file is regular and at most 2 MiB, and has a 15-second process
alarm. Each file runs eight cases: 16/64 points × scale 1/2 × selected false/true.
It uses bounded 64×64 CPU pixel buffers, never submits its own GPU commands,
and does not open a window. The real `_NSImageLayerContents` is consumed through
an owned CALayer's public `renderInContext:` API, not interpreted as a CGImage
or accessed through guessed ivars.

Initial inspection correctly stopped before private calls: `ISIcon` itself
lacks `initWithBinding:`. Actual `[ISIcon alloc]` returns `ISIconFactory`, where
the method is present. The corrected probe validates this actual concrete
receiver, and observes `ISTypeIcon` after initialization. Actual encodings:

```text
ICON_ALLOCATION class=ISIconFactory
METHOD class=ISIcon selector=initWithBinding: types=@24@0:8^{_LSBinding=}16
METHOD class=ISIcon selector=prepareImageForDescriptor: types=@24@0:8@16
METHOD class=ISIcon selector=CGImageForDescriptor: types=^{CGImage=}24@0:8@16
METHOD class=ISImageDescriptor selector=setBackgroundStyle: types=v24@0:8Q16
METHOD class=NSCGImageRep selector=initWithCGImage: types=@24@0:8^{CGImage=}16
```

Runtime identities in both final probe processes:

```text
IMAGE path=/usr/local/lib/libmachook.dylib uuid=d25affeae2573921a845785a6012acba
IMAGE path=/System/Library/PrivateFrameworks/IconServices.framework/Versions/A/IconServices uuid=1d606610e39f3be7a402256e7d3fb765
```

Read-only input identities:

| Path | Size | Inode |
| --- | ---: | ---: |
| `/var/root/cs336_spring2025_assignment2_systems.pdf` | 1,488,763 | 53530665 |
| `/var/root/macws-internal-drag-probe.txt` | 5 | 49582190 |

Logs retained locally:
`/tmp/macws-finder-icon-descriptor-pdf-20260920.log` and
`/tmp/macws-finder-icon-descriptor-txt-20260920.log`.
Both returned exit 0, `COMPLETE cases=8`, approximately 1.3 seconds per final
process. All cases returned a non-nil raster, one valid NSImage representation,
and visible pixels after the final CALayer CPU render.

Representative PDF large-icon output:

```text
CASE size=64 scale=1 selected=0 descriptor-class=ISImageDescriptor
PREPARED class=IFCacheImage
PIXELS stage=ISIcon-CGImage present=1 size=128x128 visible=2500 colored=591 fnv=0e1450d4d2cc3327
NSIMAGE class=NSImage size=64x64 reps=1 valid=1
PIXELS stage=NSImage-bitmap present=1 size=64x64 visible=2500 colored=591 fnv=0e1450d4d2cc3327
LAYER requested=1.000 recommended=2.000 selected=1.000 class=_NSImageLayerContents cgimage=0
PIXELS stage=CALayer-CPU-render present=1 size=64x64 visible=2500 colored=591 fnv=0e1450d4d2cc3327
```

At 64pt/2× both files also render correctly: 2,499 visible pixels after CALayer;
PDF has 596/598 colored pixels for unselected/selected, TXT has zero colored
pixels (the expected grayscale document icon). Small 16pt cases render
3,604 visible pixels at 1× and 3,130 at 2×. Sampling/rescaling explains small
hash/pixel-edge differences; no image is blank.

## Probe-quality corrections and repeated control

Review identified three weaknesses in the initial diagnostic, not a Finder
repair. The probe now uses typed Objective-C `initWithBinding:` and
`initWithCGImage:` declarations, so ARC applies the real init-family ownership
rules even when the class cluster substitutes its result. It no longer casts
these initializers to plain `objc_msgSend` function pointers.

It now obtains and consumes **cold** `layerContentsForContentsScale:` before
`isValid` or `drawInRect:` can prepare NSImage backing, then compares the CPU
bitmap and warmed layer result. A nil/transparent image, empty representation,
or invisible cold/warm layer now increments the failed-case count and produces
exit 74, rather than merely printing an error while returning success.

The corrected arm64e v4 diagnostic was rebuilt with Apple clang and
`-Wall -Wextra -Werror`, then run against the same two unchanged files. Both
returned exit 0 and `COMPLETE cases=8 failed=0`; all sixteen cold layer results
were visible. Logs:

- `/tmp/macws-finder-icon-descriptor-txt-v4-20260920.log`
- `/tmp/macws-finder-icon-descriptor-pdf-v4-20260920.log`

Representative corrected PDF 64pt/2× selected result:

```text
PIXELS stage=CALayer-CPU-cold present=1 size=64x64 visible=2499 colored=598 fnv=9a210e82b1da30d8
PIXELS stage=NSImage-bitmap present=1 size=64x64 visible=2498 colored=591 fnv=d403587f43ea1385
PIXELS stage=CALayer-CPU-warm present=1 size=64x64 visible=2499 colored=598 fnv=9a210e82b1da30d8
CASE_RESULT passed=1
COMPLETE cases=8 failed=0
```

`python3 -m unittest misc.test_finder_icon_contract_probe -v` also passes. It
actually compiles the same probe on macOS and executes a nil-CGImage/empty-NSImage
negative control, requiring exit 74 and the cold-layer log before bitmap draw.
These controls still do not assert that the real Finder's cached image or
WindowServer GPU composition is correct.

## Remaining discriminator, not an assumed repair

1. Same real Finder folder, screenshot before/after **Show Icon Preview** off,
   then restore the setting. Blank even when disabled would prioritize the
   in-process icon fetch/cache/display path over the failing QL thumbnail.
2. If still blank, record the actual affected TIconView's `setIconImage:`
   parameter (class, size, representations) and its child layer contents,
   without substituting a result. Confirm whether a cached non-nil image is
   empty, the asynchronous callback fails to replace it, or correct pixels
   become lost only on GPU composition.
3. If QL-off restores icons, compare the actual Finder thumbnail cache image
   with the thumbnail-only `bestRepresentation` error, rather than changing
   AppKit's renderer globally.
