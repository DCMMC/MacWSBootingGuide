# Asahi/Mesa AGX (G13 / AGXMetal13_3) Findings — Detile, Formats, Descriptors, Compression

**Purpose.** Map the Asahi/Mesa AGX reverse-engineering (which targets the *same*
Apple G13 GPU this project runs on — `gpu/docs/Codenames.md` confirms M1 = `G13`
→ `AGXMetal13_3`) onto the concrete MacWSBootingGuide problems: detiling the
WindowServer composite IOSurface for VNC, the pixel-format table, the
`AGXTexture impl+0x190` (PBE) / `impl+0x40` (GPU VA) descriptor bake, and the
compression question.

**Authority hierarchy** (per the prompt and verified on-disk):
- `mesa/src/asahi/layout/{tiling.cc,layout.c,layout.h,formats.c}` +
  `genxml/cmdbuf.xml` + `tests/test-twiddling.cpp` = **the shipping conformant
  driver. AUTHORITATIVE.** Where it disagrees with anything, it wins.
- `asahi/tilecalc/` = original RE (good measured ground-truth cross-check, but
  its `results.txt` rows are *allocation-size* offsets, not per-pixel).
- All source paths below are under `/Users/dcmmcc/Downloads/agx-re/asahi/`.

**Companion artifact:** `/tmp/agx_detile_test.c` — standalone, compiles with
`cc -O2 -Wall`, contains `agx_twiddled_offset` + `agx_detile` + a self-check
that matches the Mesa reference byte-for-byte across `2000x1456`, `2388x1668`,
and edge cases, plus a small-grid dump for diffing against tilecalc.

---

## TL;DR for the detile wall (read this first)

1. **The composite is almost certainly losslessly COMPRESSED, not just tiled.**
   G13 enables lossless framebuffer compression by default for any renderable
   surface ≥16×16 px. **Raw CPU detile of a compressed surface produces
   garbage even with perfect tile math** — only the subtiles that happen to be
   in the "uncompressed" mode read correctly. This is the most likely reason
   the project's prior detile attempts produced "mostly-scrambled,
   partly-plausible" output.
2. **The robust fix is GPU-blit-to-linear, not CPU detile.** A single
   `MTLBlitCommandEncoder copyFromTexture:toTexture:` into a freshly-created
   **Linear, `MTLStorageModeShared`** destination IOSurface makes Metal
   decompress *and* detile in one step. Read that linear surface directly for
   VNC — no twiddle math at all. The project already has a "VNC-BLIT → mmap"
   path; this is the correct primitive to lean on.
3. **CPU `agx_detile` (in `/tmp/agx_detile_test.c`) is correct and sufficient
   ONLY for the uncompressed-twiddled case** (descriptor `Compressed` bit == 0).
   Use it as the fallback/diagnostic, gated on the compression check in §4.
4. **Why plain Morton-32 failed:** the Z-order is only *inside* a fixed-size
   tile (64×64 for 4 B/px, 64×32 for 8 B/px); tiles are laid out **row-major**
   with `tiles_per_row = ceil(width / tile_w)`. A whole-surface Morton over the
   full 2000-px width is guaranteed to scramble. See §1.

---

## 1. The detile algorithm (THE deliverable) — C + reconciliation

### 1.1 Three tilings on G13 — know which one you have

`ail_tiling` (`layout.h:22-38`) ↔ hardware `Layout` enum (`cmdbuf.xml` Layout):

| `ail_tiling` | HW `Layout` | Meaning | Detile |
|---|---|---|---|
| `AIL_TILING_LINEAR` | `Linear` = 0 | raster order, real byte stride | none — use stride directly |
| `AIL_TILING_TWIDDLED` | `Twiddled` = 1 | per-level square Z-curve | classic square Morton |
| `AIL_TILING_GPU` | `GPU` = 2 | Z-order **within fixed-size tiles**, tiles row-major | `agx_detile` (this doc) |

A WindowServer render target / composite is **`GPU` (2)**, not `Twiddled` (1).
The project already samples this exact selector from `impl+0x184` (1-byte mirror
of the descriptor `Layout` field, read in `Metal_hooks.x:227,325`). **Read
`impl+0x184` before detiling**: if it reports `2` and you used a symmetric
whole-surface Morton, that's the bug.

For a single-level non-mipmapped framebuffer, `GPU` and `Twiddled` in-tile order
are identical; the only difference is mip/level packing, which a framebuffer
doesn't have. So the `agx_detile` below covers both the composite (`GPU`) and any
single-level `Twiddled` surface.

### 1.2 Tile dimensions — keyed on bytes/pixel (each tile = one 16 KB page)

`ail_get_max_tile_size(blocksize_B)` (`layout.c:35-50`, verbatim, confirmed):

| bpp | tile W×H (elements) | W·H·bpp | project format |
|---|---|---|---|
| 1 | 128×128 | 16384 | — |
| 2 | 128×64 | 16384 | — |
| **4** | **64×64** | 16384 | **BGRA8 (pf80), BGRA10_XR/BGR10_XR (pf550/552)** |
| **8** | **64×32** | 16384 | **RGBA16Float (pf115)** |
| 16 | 32×32 | 16384 | RGBA32 |
| 32 | 32×16 | 16384 | — |
| 64 | 16×16 | 16384 | — |

The tile is always exactly one page (16384 B). Getting bpp right (→ tile dims)
is the entire game for the spatial layout.

### 1.3 The within-tile Z-order

`x` → even bits, `y` → odd bits (`tests/test-twiddling.cpp:18-34`, verbatim):

```
bit pattern: [y6][x6][y5][x5][y4][x4][y3][x3][y2][x2][y1][x1][y0][x0]
```

This is the part that "plain Morton" gets wrong if the axes are swapped: **x owns
bit 0**. The optimized production form (`tiling.cc:108,111`, the
`(v - mask) & mask` increment with `space_mask_x = ail_space_mask(tile_w)`,
`space_mask_y = ail_space_mask(tile_h) << 1`) is mathematically identical — and
because `tile_w ≠ tile_h` for 8 B/px (64×32), the X and Y masks differ, which a
symmetric Morton also gets wrong.

### 1.4 Tile → image mapping (row-major, padded row span)

`tiled_offset_el` (`tests/test-twiddling.cpp:38-58`, verbatim) is the reference:

```
offs_row_el = y_tl * align(stride_el, tile_w) * tile_h
offs_col_el = x_tl * tile_w * tile_h
final_el    = offs_row_el + offs_col_el + z_order(x % tile_w, y % tile_h)
```

Since `align(stride_el, tile_w) == DIV_ROUND_UP(stride_el, tile_w) * tile_w ==
tiles_per_row * tile_w`, this is **byte-for-byte identical** to the compact
`tile_idx` form used in the C below:

```
tiles_per_row = DIV_ROUND_UP(stride_el, tile_w)        // tiling.cc:76
tile_idx      = y_tl * tiles_per_row + x_tl            // row-major
final_el      = tile_idx * (tile_w * tile_h) + z_order(...)
```

**`stride_el` for level 0 GPU-tiled = the true width in pixels** (`layout.c:128`,
`width_px` for non-block formats); the per-row tile count rounds **up**.
**Using raw `width` instead of the tile-padded row stride is the classic detile
bug** — e.g. `2000×1456 @ 4 B/px` has `tiles_per_row = ceil(2000/64) = 32`
(padded from 31.25), NOT 31. The last tile column/row is allocated full and only
partially valid; read using the **allocated** width `tiles_per_row*tile_w`, then
crop to 2000.

There is **no linear tail and no partial tiles** — edge tiles are full 16 KB
tiles. (Mipmapped/POT-small levels add a padding accumulator in
`layout.c:108-175` / `tilecalc.py:121-155` and shrink tile size per level
`layout.c:164-169`, but composites are single-level so that is not in the hot
path.)

### 1.5 C reference (verified against the authoritative Mesa reference)

This is the exact code in `/tmp/agx_detile_test.c` (which self-checks every
pixel against the Mesa reference):

```c
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* mesa layout.c:35-50 — each tile is one 16 KB page. */
static void agx_tile_dims(uint32_t bpp, uint32_t *tw, uint32_t *th) {
    switch (bpp) {
    case  1: *tw = 128; *th = 128; break;
    case  2: *tw = 128; *th =  64; break;
    case  4: *tw =  64; *th =  64; break;   /* pf 80 / 550 / 552 */
    case  8: *tw =  64; *th =  32; break;   /* pf 115 (RGBA16Float) */
    case 16: *tw =  32; *th =  32; break;
    case 32: *tw =  32; *th =  16; break;
    case 64: *tw =  16; *th =  16; break;
    default: *tw = *th = 0; break;
    }
}

/* mesa tests/test-twiddling.cpp:18-34 — x->even bits, y->odd bits. */
static uint32_t agx_z_order(uint32_t x, uint32_t y) {
    uint32_t out = 0;
    for (uint32_t i = 0; i < 8; ++i) {
        uint32_t bit = 1u << (2 * i);
        if (x & (1u << i)) out |= bit;
        if (y & (1u << i)) out |= bit << 1;
    }
    return out;
}

/* Byte offset of pixel (x,y) in an UNCOMPRESSED twiddled (GPU, single-level)
 * surface of width w, bytes/pixel bpp. (h kept for API symmetry.) */
size_t agx_twiddled_offset(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t bpp) {
    uint32_t tw, th; agx_tile_dims(bpp, &tw, &th);
    (void)h;
    if (tw == 0) return 0;
    uint32_t tiles_per_row = (w + tw - 1) / tw;     /* DIV_ROUND_UP — NOT raw w */
    uint32_t x_tl = x / tw, y_tl = y / th;
    uint32_t in_tile  = agx_z_order(x % tw, y % th);
    uint32_t tile_idx = y_tl * tiles_per_row + x_tl;
    uint64_t off_el   = (uint64_t)tile_idx * tw * th + in_tile;
    return (size_t)off_el * bpp;
}

/* Detile a full uncompressed-twiddled surface into a linear w*h*bpp buffer.
 * VALID ONLY when Compressed == 0 (mesa asserts this, tiling.cc:151). */
void agx_detile(uint8_t *dst, const uint8_t *src, uint32_t w, uint32_t h, uint32_t bpp) {
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            memcpy(dst + ((size_t)y * w + x) * bpp,
                   src + agx_twiddled_offset(x, y, w, h, bpp), bpp);
}
```

### 1.6 Verification output (from `/tmp/agx_detile_test`)

```
== self-check vs Mesa authoritative reference ==
  MATCH (all px)  composite RGBA16F pf=115         2000x1456 bpp=8
  MATCH (all px)  composite BGRA8 pf=80/550/552    2000x1456 bpp=4
  MATCH (all px)  iPad panel BGRA8                 2388x1668 bpp=4
  MATCH (all px)  R8 / BGRA8 small / non-tile-multiple / tiny edge tile
== agx_detile round-trip 8x8 bpp=4: OK ==
ALL CHECKS PASSED
```

Small-grid (w=256) byte offsets — the Z-order signature. Note `(0,1)` lands at
`2*bpp`, NOT `width*bpp` (that's the giveaway a row-linear assumption is wrong):

```
bpp=4 (64x64 tile)        bpp=8 (64x32 tile)
y\x  0    1    2    3      y\x  0    1    2    3
0    0    4    16   20     0    0    8    32   40
1    8    12   24   28     1    16   24   48   56
2    32   36   48   52     2    64   72   96   104
3    40   44   56   60     3    80   88   112  120
tile boundaries:          tile boundaries:
(63,63)->16380            (63,31)->16376
(64,0) ->16384            (64,0) ->16384
(0,64) ->65536 (@w=256)   (0,32) ->65536 (@w=256)
```

### 1.7 Reconciliation note (tilecalc vs Mesa)

- **Per-pixel ground truth = the Mesa gtest `z_order` reference** (matched here
  byte-for-byte). The `tilecalc/results.txt` rows (e.g. `{R8,1,128,1,8,0x400}`)
  are mip **allocation-size** totals (format, bpp, w, h, levels, total_B), not
  per-pixel offsets — they validate the *level offset* math in `layout.c`, not
  the twiddle. They are consistent with this doc (e.g. a 128-wide R8 image's
  level-1 starts at one full 128×128 tile) but are not the right thing to diff
  the per-pixel detile against. Diff `/tmp/agx_detile_test`'s small-grid dump
  against `tiling.cc`/the gtest instead.
- **Width dependence is real.** At `w=128` the bpp=4 case gives `(0,64)->32768`;
  at `w=256` it gives `(0,64)->65536`. Both are correct — `tiles_per_row`
  changes from 2 to 4. Always pass the surface's true width.

---

## 2. Pixel-format table

Project `pf` codes are `MTLPixelFormat` / `IOSurfaceGetPixelFormat` integers
(Apple API constants), mapped to the AGX hardware `Channels`/`Type` enums
(`cmdbuf.xml` Channels:90, Texture Type:153). `bytes/px` drives the tile dims.

| pf | Metal/IOSurface format | bytes/px | AGX Channels | AGX Type | GPU tile | twiddled? | compressible? |
|---|---|---|---|---|---|---|---|
| **550** | `MTLPixelFormatBGRA10_XR` | **4** | R10G10B10A2 (0x26) | **XR (5)** | 64×64 | yes | yes |
| **552** | `MTLPixelFormatBGR10_XR` | **4** | R10G10B10A2 (0x26) | **XR (5)** | 64×64 | yes | yes |
| **115** | `MTLPixelFormatRGBA16Float` | **8** | R16G16B16A16 (0x32) | Float (4) | 64×32 | yes | yes |
| **80** (`'BGRA'`=0x42475241) | `MTLPixelFormatBGRA8Unorm` | **4** | R8G8B8A8 (0x28) + BGRA swizzle | Unorm (0) | 64×64 | yes | yes |
| **0x26623338** (`'&b38'`) | iPad scanout / display surface | ~4 | — (scanout) | — | display | GPU-tiled **+ almost certainly compressed** | special — §4/§5 |

**Critical: pf 550 AND 552 are BOTH 4 bytes/pixel.** They are 10-bit-per-channel
packed into one 32-bit word (10+10+10+2 for BGRA10_XR; 10+10+10 with 2 unused
for BGR10_XR). They detile **identically to BGRA8** (4 B/px → 64×64 tile). The
"XR" (extended range) part is the `Type=XR(5)` field — it changes the *numeric*
decode (scale+bias for HDR/wide-gamut, values slightly below 0 / above 1), **not
the byte layout**. For spatial detile, XR is irrelevant; you only need the XR
decode if you want correct color *values* after detiling.

Evidence the XR family exists in the project's exact binary
(`~/Downloads/agx-re/ios/AGXMetal13_3`): exports `supportsPublicXR10Formats`
@0x20cf29e4a, `supportsExtendedXR10Formats` @0x20cf29ec8.

**`pf 0x26623338` ('&b38') is the danger case.** It decodes ASCII as `& b 3 8`;
those bytes also coincide with AGX channel codes (`0x26`=R10G10B10A2). It is the
Apple DCP/scanout surface the iPad *panel* (2388×1668) consumes and is GPU-tiled
**and lossless-compressed**. Mesa does not model the scanout fourccs (Asahi drives
display through a different path). **Do not raw-detile a `'&b38'` surface.** Read
the WS *composite* surface (pf 550/80/115) upstream of scanout, or GPU-blit. This
matches the project memory note `type-0x80 is the iOS kernel SCANOUT path`.

Full `Channels` enum for reference (`cmdbuf.xml:90-151`): R8=0x00, R16=0x09,
R8G8=0x0A, R5G6B5=0x0B, R32=0x21, R16G16=0x23, R11G11B10=0x25, R10G10B10A2=0x26,
R9G9B9E5=0x27, R8G8B8A8=0x28, R32G32=0x31, R16G16B16A16=0x32, R32G32B32A32=0x38;
compressed PVRTC/ETC/EAC 0x50-0x5C, ASTC 0x60-0x6D, BC1-7 0x74-0x7B.

---

## 3. Texture + PBE descriptor layout → `impl+0x190` / `impl+0x40`

Both descriptors are 24 bytes (192 bits). Bit convention (`gen_pack.py:91-95`):
absolute bit = word*32 + bit; `shr(N)` = stored value is `actual >> N`;
`minus(1)` = stored = actual−1.

The project bakes the **PBE (render-target / writeable image) descriptor at
`AGXTexture impl+0x190`** and tracks the **GPU VA at `impl+0x40`**.

### 3.1 PBE descriptor (`cmdbuf.xml:224-281`) — the `impl+0x190` bake

| Field | bit start | size | encoding / notes |
|---|---|---|---|
| Dimension | 0 | 4 | texture dimension enum |
| **Layout** | 4 | 2 | 0=Linear 1=Twiddled **2=GPU** 3=Interchange |
| **Channels** | 6 | 7 | hw format (0x26 / 0x28 / 0x32) |
| **Type** | 13 | 3 | Unorm=0 … Float=4 **XR=5** |
| Swizzle R/G/B/A | 16/18/20/22 | 2 each | BGRA via swizzle (2-bit here, vs 3-bit in Texture) |
| **Width** | 24 | 14 | `minus(1)` |
| **Height** | 38 | 14 | `minus(1)` |
| Rotate90 / Flip vertical | 53/54 | 1 | render-only |
| Samples | 56 | 1 | 2→0, 4→1 |
| **Compressed** | **59** | **1** | **lossless-compression flag — check this** |
| Mode (Image Mode) | 60 | 2 | Normal=0 |
| **Buffer (body GPU VA)** | **64** | **36** | **`shr(4)` → actual VA = stored<<4. This is `impl+0x40`.** |
| Level | 100 | 4 | |
| Levels | 104 | 4 | `minus(1)` (non-linear) — 0 for single-level RT |
| Layers | 108 | 14 | `minus(1)` — 0 for non-array RT |
| sRGB | 125 | 1 | |
| **Extended** | **127** | **1** | if set, next word holds Acceleration buffer |
| Stride (linear) | 104 | 21 | overlaps Levels/Layers (linear only) |
| **Acceleration buffer** | **128** | 64 | `shr(4)` — DCC/compression metadata VA (descriptor byte **+16**) |

### 3.2 Texture descriptor (`cmdbuf.xml:283-325`) — the sampler-side mirror

| Field | bit start | size | encoding |
|---|---|---|---|
| Dimension | 0 | 4 | |
| **Layout** | 4 | 2 | as above |
| **Channels** | 6 | 7 | |
| **Type** | 13 | 3 | |
| Swizzle R/G/B/A | 16/19/22/25 | 3 each | (3-bit here) |
| **Width** | 28 | 14 | `minus(1)` |
| **Height** | 42 | 14 | `minus(1)` |
| Samples | 64 | 1 | |
| **Address (body GPU VA)** | **66** | **36** | `shr(4)` |
| **Compressed** | **103** | **1** | **lossless-compression flag** |
| Compression | 106 | 2 | 0 = uncompressed |
| sRGB | 108 | 1 | |
| Stride (linear) | 110 | 18 | `shr(4)` |
| **Extended** | **127** | 1 | next word = Acceleration buffer |
| **Acceleration buffer** | **128** | 64 | `shr(4)` (byte +16) |

### 3.3 Mapping to project fields

- **`impl+0x40` (GPU VA the project sets) = PBE `Buffer` (bit 64, 36-bit,
  `shr(4)`) / Texture `Address` (bit 66, `shr(4)`).** The driver's
  `texBaseAddressesUpdated<G13>` (`mac_hooks.m:2911`) packs the RT base VA into
  these fields **shifted right by 4**. **The VA must be 16-byte aligned** — the
  low 4 bits are dropped by the `shr(4)` encoding. If you ever write a raw VA
  without `>>4`, the descriptor points 16× too high. (Project IOSurface bases are
  page-aligned, so the alignment is satisfied.)
- **`impl+0x190` (PBE bake)** — load-bearing fields for a correct, detile-able RT:
  `Layout`=2 (GPU), `Channels`+`Type` matching the pf, `Width-1`/`Height-1`,
  `Buffer = VA>>4`, `Levels-1`=0, `Layers-1`=0, and `Compressed`. If you want raw
  CPU detile to be possible, you need `Compressed`=0; if the driver sets it to 1
  you MUST GPU-blit.
- **`impl+0x184`** = the live `Layout` byte the project already samples. Read it
  before detiling (0=Linear, 1=Twiddled, 2=GPU).
- **`impl+0xa0`** = the IOSurface object (project-confirmed). Its backing is the
  tiled/compressed bytes the descriptor describes.

---

## 4. Compression — YES, G13 framebuffers are compressed by default; how to detect/handle

This is the answer to "does G13 apply lossless framebuffer compression on top of
twiddling": **yes, and it WILL defeat raw detile.**

### 4.1 It's on by default

The Gallium driver enables compression unconditionally for anything
renderable/scanout/shared unless a debug flag is set
(`gallium/drivers/asahi/agx_pipe.c:400-429` `agx_compression_allowed`):

```c
if (dev->debug & AGX_DBG_NOCOMPRESS) return false;
if (bind & ~(SAMPLER_VIEW|RENDER_TARGET|DEPTH_STENCIL|SHARED|SCANOUT)) return false;
if (!ail_can_compress(...)) return false;
```

`ail_can_compress` (`layout.h:443-461`) returns true for any PBE-renderable
format with effective dims ≥ 16×16 px. A WS composite (≈2000×1456, BGRA8/
BGRA10_XR/RGBA16F) hits every condition → **compressed**. Apple's Metal does the
same: a color-attachment / scanout `MTLTexture` gets the compressed layout unless
explicitly opted out. Compression **requires** non-linear layout — you never get
linear+compressed (`layout.h:73-74`).

### 4.2 How it's physically stored (two buffers in one allocation)

`ail_initialize_compression` (`layout.c:268-314`):
1. **Body buffer** — the twiddled pixel data, offset 0. **`impl+0x40` points
   here.**
2. **Metadata (AUX) buffer** — appended after the body at
   `layout->metadata_offset_B`. **8 bytes of metadata per 16×16-px tile** (one
   byte per 8×4 subtile × 8 subtiles). The metadata buffer is **itself fully
   twiddled** (w/h padded to powers of two). Per metadata byte = a compression
   mode for that subtile:
   - `AIL_COMP_UNCOMPRESSED_4 = 0x7f` (4 B/px), `UNCOMPRESSED_8_16 = 0xff`
     (`layout.h:467-470`) — subtile body holds raw pixels.
   - `AIL_COMP_SOLID_4 = 0x03` etc. (`layout.h:473-476`) — solid color stored once.
   - anything else = delta-compressed bytes (NOT pixels).

**Implication:** after a correct body detile, any subtile whose metadata byte is
not the uncompressed sentinel holds compressed deltas → raw read = garbage there,
plausible elsewhere. This is exactly the "mostly-scrambled, partly-plausible"
symptom. **Raw detile alone cannot read a compressed surface.**

### 4.3 How to DETECT compression (pick one; #1 is most reliable in-chroot)

1. **Descriptor bit.** PBE `Compressed` = **bit 59** (byte `impl+0x190 + 7`,
   bit 3); Texture `Compressed` = bit 103. When set, `Extended` (bit 127) is set
   and the **Acceleration buffer** VA lives at **descriptor byte +16** (`shr(4)`,
   nonzero mapped VA). That bit + pointer pair is the definitive detector.
2. **Allocation size.** Compressed `size_B` exceeds the bare body by
   `compression_layer_stride_B * depth` (`layout.c:311-313`). If
   `IOSurfaceGetAllocSize` > `body_layer_stride * depth`, there's an AUX tail.
3. **IOSurface plane info** — a second plane / `BytesPerRowOfPlane` mismatch in
   some configs (less reliable than #1).

### 4.4 How to HANDLE it

- **Route A — GPU decompress/resolve (recommended).** Issue
  `MTLBlitCommandEncoder copyFromTexture:toTexture:` (or
  `optimizeContentsForCPUAccess:`) from the compressed composite into a freshly
  created **Linear, `MTLStorageModeShared`** destination IOSurface (set a
  rowBytes stride → forces `Layout=Linear` → cannot be compressed). Metal
  decompresses AND detiles in one step; read the destination linearly for VNC.
  Mesa's own primitive for this is the `libagx_decompress` CDM compute kernel
  (`libagx/compression.cl:75-143` — one 32-wide workgroup per 16×16 tile, reads
  via a compressed texture descriptor, writes via an uncompressed PBE
  descriptor, rewrites metadata to the uncompressed sentinel). The project
  already has a working GPU submission path
  (`agx-queue-heap-create-now-succeed`), so a single blit/dispatch is light.
- **Route B — never create the capture target compressed.** Allocate the VNC
  capture IOSurface **Linear + uncompressed** (give it a rowBytes stride) and
  have the compositor blit into it. This sidesteps both compression and twiddle.
  Apple-side this is the equivalent of Mesa's `AGX_DBG_NOCOMPRESS`. Note: the
  project's CPU-copy bridge fails today precisely because the *source* it
  memcpy's from is compressed-twiddled — a CPU memcpy can't linearize it; the
  copy must be a GPU blit.
- **Route C — CPU-only.** First run a GPU decompress pass, THEN CPU-detile the
  resulting body with `agx_detile`. Strictly more work than Route A; only do this
  if a GPU blit-to-linear is somehow unavailable.

**Bottom line:** raw CPU detile of the composite is a dead end while it's
compressed (the default). The correct pipeline is **GPU resolve/decompress →
Linear IOSurface → CPU/VNC read**, OR allocate the capture target linear and
GPU-blit into it.

---

## 5. What this unblocks for MacWSBootingGuide (prioritized)

1. **[P0] Detile the WS composite IOSurface for VNC — the long-standing wall.**
   - **Action:** at capture time read `impl+0x184` (Layout) and the PBE
     `Compressed` bit (`impl+0x190+7`, bit 3) and the pf.
   - If `Compressed==1` OR `pf==0x26623338`: **GPU-blit to a Linear Shared
     IOSurface** and read that (Route A/B). This is the path that will actually
     work for the full-screen composite — it's almost certainly compressed.
   - If `Compressed==0` and `Layout∈{1,2}`: use `agx_detile` from
     `/tmp/agx_detile_test.c` directly (4 B/px → 64×64; 8 B/px → 64×32).
   - This is the single highest-value item: it converts the project's
     "composite is real but unreadable" state (memory:
     `detile-read-correct-composite-empty`) into on-screen VNC pixels.
2. **[P0] Stop trying whole-surface Morton / CPU memcpy on the raw backing.**
   Both are now positively explained as wrong (Z-order is per-tile; the surface
   is compressed). Saves further dead-end cycles.
3. **[P1] Correct the PBE bake at `impl+0x190` / VA at `impl+0x40`.** Ensure the
   GPU VA is written `>>4` (16-byte aligned) into PBE `Buffer` (bits 64-99), and
   that `Layout=2`, `Channels`/`Type` match the pf, `Levels-1=Layers-1=0`. If the
   project wants CPU-detile-able RTs, force `Compressed=0` in the bake (then the
   surface is plain twiddled and `agx_detile` works without a GPU pass).
4. **[P1] Use the format table (§2) to pick bpp correctly.** pf 550/552 are 4
   B/px (not 8) — getting this wrong alone scrambles columns. pf 115 is 8 B/px
   (64×32 tile).
5. **[P2] XR color decode (only if VNC colors look washed/wrong after detile).**
   pf 550/552 are XR (extended-range) — spatial detile is identical to BGRA8, but
   the 10-bit values need a scale+bias to map to display sRGB. Defer until pixels
   are landing.
6. **[P3] Shader-IR renamer (already out-of-process, low priority).** AGX shader
   opcodes are scattered/variable-length (`isa/AGX2.xml`). Safe rewrites are
   **same-length opcode swaps** (e.g. `fadd`↔`fmul`, identical bit 0:5 + operand
   layout) and **modifier-bit flips** (saturate/negate/round-mode/`.fast`).
   Cross-length renames shift the whole downstream stream and are unsafe. The
   prior `fract.v3f16.fast` work is a modifier-bit flip class — cheapest/safest.
   The command-stream/USC/descriptor work is NOT in `isa/` (it's in `lib`,
   `genxml`, `layout`).

---

## Source index (all under `/Users/dcmmcc/Downloads/agx-re/asahi/`)

- Detile core: `mesa/src/asahi/layout/tiling.cc` (`ail_detile`/`memcpy_small`
  :58-175; `tiles_per_row` :76; masks :81-82), `tests/test-twiddling.cpp`
  (`z_order` :18-34, `tiled_offset_el` :38-58 — the authoritative per-pixel ref).
- Tile-size law + mip/compression metadata: `mesa/src/asahi/layout/layout.c`
  (`ail_get_max_tile_size` :35-50, `ail_initialize_gpu_tiled` :69-215,
  `ail_initialize_compression` :268-314).
- Tilings, `ail_space_bits` :253, compression modes :463-517, `ail_can_compress`
  :443-461, `ail_is_level_twiddled_uncompressed` :367, DRM modifiers :565-585:
  `mesa/src/asahi/layout/layout.h`.
- pf → Channels/Type: `mesa/src/asahi/layout/formats.c`.
- Descriptor bit layout (PBE :224-281, Texture :283-325, Layout/Channels/Type
  enums): `mesa/src/asahi/genxml/cmdbuf.xml`.
- Compression-on-by-default + descriptor fill: `gallium/drivers/asahi/agx_pipe.c:400`,
  `agx_state.c:708`. GPU decompress kernel: `libagx/compression.cl:75-143`.
- Shader ISA: `mesa/src/asahi/isa/AGX2.xml`, `isa.py`, `gen-disasm.py`.
- Chip confirmation: `gpu/docs/Codenames.md` (M1 = G13 → AGXMetal13_3).
- Measured ground-truth cross-check: `tilecalc/results.txt`, `tilecalc.py`.
- XR support in project binary: `~/Downloads/agx-re/ios/AGXMetal13_3`
  (`supportsPublicXR10Formats`, `supportsExtendedXR10Formats`).

**Companion test:** `/tmp/agx_detile_test.c` — `cc -O2 -Wall -o /tmp/agx_detile_test
/tmp/agx_detile_test.c && /tmp/agx_detile_test` → `ALL CHECKS PASSED`.
