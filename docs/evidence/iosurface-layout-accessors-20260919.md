# IOSurface layout accessor boundary, 2026-09-19

## Result and limits

**Runtime-confirmed:** the current canonical compatibility library corrects
public C per-plane accessors, but the Client C and Objective-C entry points
still return fields from the wrong private client layout. This is reproduced
with freshly created, self-owned 19×11 surfaces, without any GPU command,
Office process, imported surface, image decoder, old cache, or user document.
The native iOS controls pass on both slices. Both injected macOS slices fail
the same 18 comparisons. Whole-surface width, height, bytes-per-row, and
bytes-per-element pass all three entry points for these fixtures.

This is **not yet proof of the Office large-image/black-thumbnail cause**.
That attribution requires a real failing Office resource and caller route.
In particular, the earlier 19×11 BGRA Metal/CA tests remain valid positive
controls; they did not exercise these Objective-C planar accessors.

The initial investigation made no production change. The isolated candidate
described below subsequently repairs the verified API contract. The test
uses no diagnostic marker, GPU operation, global hook, service restart, or
UI input. Each process has a five-second alarm and releases its two owned
16 KiB surfaces sequentially.

## Actual images and offline RE

The existing extracted macOS image is:

```
/Users/dcmmc/Downloads/MacWSBootingGuide_files/IOSurface
UUID   2B44B850-7D19-34F3-AB8E-A3B93016A96D
SHA256 baa5e40360cbe802ab7fb4581ea5c765ee1b9a1e1b5c64a193d777a6d6d8e592
__TEXT VM base 0x189826000, file offset 0
```

Its extracted non-TEXT section offsets are not normalized, so stock `otool`
rejects the object. A bounded reader used the valid segment VM/file mappings,
LC_UUID, LC_SYMTAB, and actual __TEXT bytes. No IPSW/cache extraction was run.
The independently captured runtime load commands have the same UUID. Fresh
probe processes also report this exact mapped IOSurface UUID. Native controls
map `DF041B53-4BAA-3668-8781-43DE39FA8905`.

RE-confirmed direct branch targets (offsets relative to macOS __TEXT):

| Objective-C selector | Original IMP | Direct branch | Client C target | Client field for a valid plane |
| --- | ---: | ---: | ---: | --- |
| `widthOfPlaneAtIndex:` | `0x5dac` | `0x5e8c` | `0x424c` | `client + plane*0x80 + 0xd0` |
| `heightOfPlaneAtIndex:` | `0x5e90` | `0x5f70` | `0x429c` | `… + 0xd4` |
| `bytesPerRowOfPlaneAtIndex:` | `0x5f74` | `0x6054` | `0x41f0` | `… + 0xe0`, after compression check |
| `bytesPerElementOfPlaneAtIndex:` | `0x6058` | `0x6138` | `0x444c` | `… + 0xe8`, 16-bit |
| `elementWidthOfPlaneAtIndex:` | `0x613c` | `0x621c` | `0x449c` | `… + 0xea`, 8-bit |
| `elementHeightOfPlaneAtIndex:` | `0x6220` | `0x6300` | `0x6a78` | `… + 0xeb`, 8-bit |
| `baseAddressOfPlaneAtIndex:` | `0x6304` | `0x63e4` | `0x4574` | base `client+0x68` plus `…+0xdc`, after compression check |

For example, actual bytes disassemble as:

```text
IOSurface +0x6028: ldr x0, [x20, #8]       ; object's real _impl
          +0x602c: mov x1, x19             ; requested plane
          ... original epilogue/PAC authentication ...
          +0x6054: b #0x41f0               ; direct Client call, not imported C symbol
          +0x41f0: ldr w8, [x0, #0xa0]    ; plane count
          +0x4200: add x8, x0, x8, lsl #7
          +0x4204: ldrb w9, [x8, #0x124]  ; macOS compression byte
          +0x4208: cmp w9, #1
          +0x420c: b.eq #0x421c
          +0x4210: add x8, x8, #0xe0
          +0x4228: ldr w0, [x8]
```

Direct branches inside IOSurface do not traverse the public C dyld interpose
tuple or the separately repaired AGX GOT. The methods also retain genuine
zero-plane/out-of-range validation before their normal Client call; a future
adapter must not erase that behavior.

Public `IOSurfaceGetOffsetOfPlane` (`0xbe84`) and
`IOSurfaceGetSizeOfPlane` (`0xbea0`) call Client entries `0x6aac`/`0x6ae0`,
which read `…+0xdc`/`…+0xe4`. No corresponding Objective-C selector exists in
this image's IOSurface method list; that column is N/A, not an absent hook.

Whole-surface ObjC `width`/`height`/`bytesPerRow` at
`0x5d44`/`0x5d4c`/`0x5d54` directly call Client
`0x3c54`/`0x3c9c`/`0x3bfc`. Width/height read `+0x88`/`+0x8c`.
Whole BPR ultimately reads `+0x90`, but, on planar surfaces, first checks
each plane's `+0x124` compression byte. Its passing uncompressed fixtures
therefore do **not** certify all compressed-plane semantics. The existing
native-layout RE records compression at `+0x120` and BPR/offset at
`+0xdc`/`+0xd8` in `docs/agx-native-milestones.md`.

## Canonical production coverage before this candidate

| Property group | Public C | Client C | Objective-C |
| --- | --- | --- | --- |
| Protection options | Exact-ABI adapter | Exact-ABI adapter | Exact-ABI original-IMP-validated replacement |
| Whole width/height/BPR/BPE | Original API | Original API | Original direct Client call; these fixtures pass |
| Per-plane width/height/BPR/BPE/element width/element height/base | CreationProperties recovery + AGX GOT binding | No layout adapter | Original direct Client call; these fixtures fail |
| Per-plane offset/size | CreationProperties recovery + AGX GOT binding | No layout adapter; these fixtures fail | N/A in the measured class |
| Compression/tile width/tile height/tile bytes/component count/address format | Existing public C recovery + AGX GOT binding | No layout adapter | No equivalent scalar selector in measured class; not tested here |

Source observations: `libmachook/mac_hooks.m` contains public/Client
protection interposers and its narrowly validated ObjC installation around
lines 14605–14761. Its per-plane compatibility block around 14763–15440
registers 15 public C interposers, but no Client C interpose or per-plane
ObjC installation. `macws_repair_got_via_symtab` repairs the corresponding
public AGX imports. These are source observations, not runtime attribution
to a particular Office caller.

## Four actual, bounded runtime comparisons

Probe: `misc/macws_iosurface_layout_probe.m`, SHA-256
`d64bbab1bc8ae31170e0bc0edd5a022d2341702f55429f3726a799073dd463d8`.
It validates `_impl` offset 8 and actual method argument/return encodings
before invocation (`q`/`Q` scalar or pointer return as appropriate). Public
standard accessors are linked normally, not merely looked up through a
framework-specific `dlsym` handle. Private public offset/size pointers and all
Client pointers are printed with their actual owning images. This avoids
mistaking a diagnostic bypass of interposition for a missing production hook.

Both fixtures use width19, height11, whole BPR128, allocation16384. The
BGRA fixture has BPE4/no explicit planes. The b3a8 fixture has whole BPE5:

| Plane | Width×height | BPE | BPR | Offset | Size |
| --- | --- | ---: | ---: | ---: | ---: |
| 0 | 19×11 | 4 | 128 | 0 | 2048 |
| 1 | 19×11 | 1 | 64 | 4096 | 1024 |

The native producer accepts the fixtures unchanged; the full requested and
actual CreationProperties are in each log. No expected dimensions are
invented from a wrong getter. Each run also saves 384 bytes of its **own**
client metadata beginning at `+0x80` through checked `vm_read_overwrite`.

| Execution | PID | Actual mapped libmachook UUID | Result |
| --- | ---: | --- | --- |
| Native arm64 | 31528 | none | PASS, zero disagreements |
| Native arm64e | 31550 | none | PASS, zero disagreements |
| Chroot arm64 | 31557 | `DC73423C-A25A-3231-B3D5-E8F1A4F627FB` | FAIL, 18 per-plane disagreements |
| Chroot arm64e | 31588 | `C094E3E4-327A-349F-9282-BEA000E34766` | FAIL, same 18 disagreements |

Representative copied chroot log lines:

```text
plane=0 field=Width expected=19 public=19 client=11 objc=11 has-objc=1 base=0 address=0
plane=0 field=Height expected=11 public=11 client=0 objc=0 has-objc=1 base=0 address=0
plane=0 field=BytesPerRow expected=128 public=128 client=2048 objc=2048 has-objc=1 base=0 address=0
plane=0 field=Offset expected=0 public=0 client=128 objc=0 has-objc=0 base=0 address=0
plane=1 field=Height expected=11 public=11 client=4096 objc=4096 has-objc=1 base=0 address=0
plane=1 field=BytesPerRow expected=64 public=64 client=1024 objc=1024 has-objc=1 base=0 address=0
plane=1 field=Offset expected=4096 public=4096 client=64 objc=0 has-objc=0 base=0 address=0
layout-disagreements=18 result=FAIL
```

The shifted Client fields read the next native property: width becomes
height; height becomes offset; BPR becomes size; offset becomes BPR.
ObjC baseAddress likewise returns base+128/base+64 instead of base+0/base+4096.
Native C/Client/ObjC all agree with the requested and actual properties.

Local complete receipts, SHA-256:

```
/tmp/macws-iosurface-layout-native-arm64-20260919.log
0fdf9f68293184ff3a30cac1bdb9c6041b0bae9cf92ec0264f4abe3dcdd99def
/tmp/macws-iosurface-layout-native-arm64e-20260919.log
2df105d1083590f4913215c8f6b74c968b4ab550b21500eedda8bd619477487a
/tmp/macws-iosurface-layout-chroot-arm64-20260919.log
8d406a10515a4a0baebe59aad1e6d5fdb5fb7c3567e8198288a0ed55bcd0aa04
/tmp/macws-iosurface-layout-chroot-arm64e-20260919.log
31e66380f170b9ce85dab79ced263de4a2b4599c645288f0ac4dbf6c42f26d2f
```

## Design boundary

1. Cover real Client C layout entry points with the exact measured ABI,
   rather than expanding only public symbol rebinding. Client pointers are
   not IOSurface objects: casting one to `IOSurfaceRef` or fabricating a
   CreationProperties dictionary would be incorrect. A shared reader must
   follow verified native field offsets and preserve the genuine zero-plane,
   invalid-plane and compression-dependent return behavior.
2. Cover the seven real ObjC selectors separately because their same-image
   direct branches do not become interposed when Client symbols are merely
   rebound. Validate UUID, original IMP and type encoding. Preserve original
   exception/validation semantics for invalid plane indices. Do not patch
   executable pages (the prior global ObjC patch caused fork RX/R regressions).
3. Keep existing public CreationProperties checks as disconfirming witnesses;
   require C/Client/ObjC/native equality on both planes and architectures,
   preserving legitimate zero offset and nonzero offset rather than replacing
   incorrect values by constants. Add out-of-range/nonplanar behavior and
   compression controls before generalizing the reader.
4. Only after the API contract passes, re-run the existing BGRA upload/CA and
   fork controls and obtain a controlled Office large-image/thumbnail visual
   comparison. The shared accessor bug may be independent of Office's actual
   failing route; that remains explicitly unproven.

## Native code receipts and implemented candidate

One additional self-owned native process read exactly 96 bytes from each of
20 actual Client functions: 1920 bytes total, no GPU and no foreign task.
`/tmp/macws-iosurface-layout-native-code-20260919.log`, SHA-256
`49403288268d071b760f58ee45b1dd8a91a27e6d2f55b24654fcf202bd1aad5d`,
records image UUID, offset, and raw bytes for each symbol. The checked probe
now supports this explicit `--code` mode. Notable native RE:

```
WidthOfPlane +0x5f34: index in w1; count +0xa0; field +0xcc
HeightOfPlane +0x53a8: index in w1; field +0xd0
BytesPerRowOfPlane +0x477c: index in w1; compression byte +0x120;
                           type==1 returns 0, otherwise field +0xdc
BaseAddressOfPlane +0x3e30: same compression predicate;
                           base pointer +0x68 plus offset field +0xd8
NumberOfComponentsOfPlane +0x80f8: full x1 index, field byte +0xe8
```

Other captured native fields are BPE `+0xe4` (16-bit), element W/H `+0xe6/+0xe7`
(8-bit), size `+0xe0`, compression `+0x120` (8-bit), tile W/H `+0x114/+0x118`,
tile bytes `+0x12c`, and address format `+0xe9` (8-bit). Each indexed record
has stride `0x80`. All indices except component count use w1; this distinction
is retained, not generalized to an invented common private ABI.

Implemented in `include/macws_iosurface_layout_abi.h` plus the narrow
IOSurface block of `libmachook/mac_hooks.m`:

- The shared reader reads real immutable native metadata, without CF casts,
  cached fabricated objects, pixel-format guesses, allocation, logging,
  environment/file probes, or graphics work.
- Readiness reuses the previously tested exact kernel20D67 / IOSurface UUID /
  `_impl` verification, then checks 15 actual macOS Client layout instructions.
  Unknown pair or changed instruction retains the original path.
- Public15 and Client15 entries consult the same reader. Explicit zero is a
  valid result. Compression type1 returns zero BPR/base as native does; it is
  not repaired to nonzero from CreationProperties. Existing public fallback
  logic remains for cases the reader does not accept.
- The seven ObjC methods are validated together by selector, exact signed
  scalar/pointer signature, original IMP UUID and original offset. Their
  genuine nonplanar/out-of-range/exception handling delegates to the saved
  original. Method replacement uses the runtime API; no executable page is
  patched. Concurrent installation is serialized before original-IMP checks.
- No-plane and out-of-range client cases retain the stock call; the reader
  does not dereference an invented plane0 record to turn an invalid input into
  success. Component count retains size_t; other Client arguments retain their
  actual uint32_t ABI. ObjC bounds are checked before any such truncation.
- Same-image non-ObjC direct C branches remain a documented boundary. This
  candidate does not claim that symbol interposition rewrites those branches.
  Whole-surface compressed BPR/base behavior was not silently broadened.

`misc/test_iosurface_layout_contract.py` executes the actual production reader,
all15 Client wrapper bodies, all7 ObjC wrapper bodies, and all15 public early
reader paths. Cases cover different plane strides/sizes/offsets, valid zeros,
compression0/1/3, stale shifted compression bytes, nil, zero planes, out-of-range
and wide indices, unknown ABI fallbacks, and unchanged caller/client arguments.
The actual ABI readiness function is separately compiled and executed against
18 fresh-process cases: matching image, unavailable validated pair, wrong UUID,
and each of the15 independently corrupted instruction anchors. Together with
the existing protection tests, all6 tests pass. The pure fixture is in
`misc/test_iosurface_layout_abi.c`.

### Full isolated library and actual negative/positive/reverse

Apple-ld64 full libmachook cross-build, both arm64 and arm64e, completed in
separate object directory `libmachook/.theos/layout-reader-20260919`.
Base commit `c3c8ec221965122cbff2494e86be4e8d59492cf6`, uncommitted combined
source receipts (same hashes immediately after build and after runtime tests):

```
mac_hooks.m
744892ad785f53d51edba863f6fd2aae52381ea2425e0b585e9ec27099769f33
Metal_hooks.x (includes the independent frozen namespace initialization fix)
cf2dd68b525a498a6e1cb686ca5bfbb962c8cfe20d0b4782f3f9821ab8f8fdec
macws_iosurface_layout_abi.h
1f2e07f6f5c4fb88aaca7abd76a6f4670dd6831cc66dc8cf095defe0e9b06c20
```

The exact same already-tested metadata probe binaries were launched with a
single `/tmp` candidate through the existing isolated native chroot launcher
(no canonical lib insertion). They produce:

| Run | PID | Actual mapped candidate | Result |
| --- | ---: | --- | --- |
| Isolated arm64 | 33596 | `E32930CD-D470-3562-95E2-F2B458CD559C` | PASS, C/Client/ObjC all18 agree |
| Isolated arm64e | 33853 | `5CA350C6-01A9-34F2-A0DB-74B1A3AD66B2` | PASS, C/Client/ObjC all18 agree |
| Reverse, unchanged canonical arm64 | 33858 | `DC73423C-A25A-3231-B3D5-E8F1A4F627FB` | FAIL, same18 original mismatches |

This proves the API-contract fix against the same data and existing negative
binary, not merely a new-process uptime or changed expected value. Whole BGRA
and planar width/height/BPR/BPE remain correct. No canonical file, loaded app,
WindowServer, or service was modified. **Office image causality, real compressed
image rendering, and canonical production acceptance remain pending.**

Complete local logs and SHA-256:

```
/tmp/macws-layout-reader-build-20260919.log
/tmp/macws-iosurface-layout-candidate-arm64-20260919.log
7b35dd846fe13141fa53075fa1c4ffda129571166a9b78a73b18855d9cfa3a1c
/tmp/macws-iosurface-layout-candidate-arm64e-20260919.log
a49c094beb6fbf439901609fbadf28ff4641ee3da63db64b110bdc5a89d8a2e9
/tmp/macws-iosurface-layout-reverse-arm64-20260919.log
ff12b4fffafeebcff137df68a30df22172641eeddc54c38a5882c08df8abba87
```
