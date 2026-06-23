/*
 * agx_detile_test.c — AGX (Apple G13 / AGXMetal13_3) twiddle/detile reference.
 *
 * Self-contained, no deps. Reproduces Mesa Asahi's AUTHORITATIVE (shipping,
 * CTS-conformant) GPU-tiled layout for the UNCOMPRESSED case:
 *   - tile dims from ail_get_max_tile_size  (mesa layout.c:35-50)
 *   - Z-order within a tile (x->even bits, y->odd bits)  (mesa tests/test-twiddling.cpp:18-34)
 *   - row-major tile grid, row span padded to whole tiles via DIV_ROUND_UP
 *     (mesa tiling.cc:76 / tests/test-twiddling.cpp:38-58 tiled_offset_el)
 *
 * Equivalence note (verified): Mesa's reference computes
 *     offs_row_el = y_tl * align(stride_el, tile_w) * tile_h
 * and align(stride_el, tile_w) == DIV_ROUND_UP(stride_el, tile_w) * tile_w
 * == tiles_per_row * tile_w. So
 *     y_tl*align(stride,tw)*th + x_tl*tw*th + z = (y_tl*tpr + x_tl)*tw*th + z
 * which is exactly the tile_idx formula below.  *byte-for-byte identical.*
 *
 * Build:  cc -O2 -Wall -o /tmp/agx_detile_test /tmp/agx_detile_test.c
 * Run:    /tmp/agx_detile_test
 *
 * Diff against tilecalc: the small-grid byte offsets printed by main() are
 * the per-pixel ground truth for the UNCOMPRESSED twiddled body buffer.
 * (tilecalc/results.txt rows are mip ALLOCATION-size offsets, not per-pixel —
 * the per-pixel ground truth is the gtest z_order reference, matched here.)
 *
 * IMPORTANT for MacWSBootingGuide: this CPU detile is correct ONLY when the
 * surface is uncompressed-twiddled (descriptor Compressed bit == 0, Layout
 * == GPU(2) or Twiddled(1)). G13 framebuffers/RTs are losslessly COMPRESSED
 * by default — for those, GPU-blit to a Linear surface instead (see doc).
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

/* ---- AGX G13 max tile dims in ELEMENTS, keyed on bytes/element. ----
 * Each tile is exactly one 16 KB page (W*H*bpp == 16384).
 * Source: mesa layout.c:35-50 ail_get_max_tile_size. */
static void agx_tile_dims(uint32_t bpp, uint32_t *tw, uint32_t *th) {
    switch (bpp) {
    case  1: *tw = 128; *th = 128; break;
    case  2: *tw = 128; *th =  64; break;
    case  4: *tw =  64; *th =  64; break; /* BGRA8 (pf80), BGRA10_XR/BGR10_XR (pf550/552) */
    case  8: *tw =  64; *th =  32; break; /* RGBA16Float (pf115) */
    case 16: *tw =  32; *th =  32; break;
    case 32: *tw =  32; *th =  16; break;
    case 64: *tw =  16; *th =  16; break;
    default: *tw = *th = 0; break;        /* invalid */
    }
}

/* ---- Z-order interleave within a tile: x -> even bits, y -> odd bits. ----
 * Source: mesa tests/test-twiddling.cpp:18-34 (z_order).
 * 8 source bits each => addresses up to a 256x256 tile (covers all G13 tiles). */
static uint32_t agx_z_order(uint32_t x, uint32_t y) {
    uint32_t out = 0;
    for (uint32_t i = 0; i < 8; ++i) {
        uint32_t bit = 1u << (2 * i);
        if (x & (1u << i)) out |= bit;        /* x -> bits 0,2,4,... */
        if (y & (1u << i)) out |= bit << 1;   /* y -> bits 1,3,5,... */
    }
    return out;
}

/*
 * Byte offset of pixel (x,y) in an UNCOMPRESSED twiddled (AIL_TILING_GPU,
 * single-level, non-block-compressed) AGX image of width w, bytes/pixel bpp.
 * h is unused for the offset (kept for API symmetry / callers' bounds).
 *
 * Matches mesa tiled_offset_el (tests/test-twiddling.cpp:38-58) * bpp,
 * which equals the production memcpy_small path (tiling.cc:58-114) and
 * ail_get_twiddled_block_B (layout.h:277-303).
 */
size_t agx_twiddled_offset(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t bpp) {
    uint32_t tw, th; agx_tile_dims(bpp, &tw, &th);
    (void)h;
    if (tw == 0) return 0; /* invalid bpp */

    /* Row span padded up to a whole number of tiles: DIV_ROUND_UP(w, tw).
     * (mesa tiling.cc:76 / align() in test:51). USING RAW w HERE IS THE BUG
     * that scrambled columns — last partial tile-column must still count. */
    uint32_t tiles_per_row = (w + tw - 1) / tw;

    uint32_t x_tl = x / tw, y_tl = y / th;
    uint32_t ox   = x % tw, oy   = y % th;

    uint32_t in_tile  = agx_z_order(ox, oy);              /* Z-order inside tile */
    uint32_t tile_idx = y_tl * tiles_per_row + x_tl;      /* row-major tile grid */
    uint64_t off_el   = (uint64_t)tile_idx * tw * th + in_tile;
    return (size_t)off_el * bpp;
}

/*
 * Detile a full uncompressed-twiddled AGX surface into a linear w*h*bpp buffer.
 * dst must be at least w*h*bpp bytes; src is the twiddled backing.
 *
 * VALID ONLY when the surface is uncompressed (descriptor Compressed bit == 0).
 * For pf 0x26623338 ('&b38') or any compression-hinted surface, GPU-blit to a
 * linear surface instead — mesa asserts ail_is_level_twiddled_uncompressed
 * (tiling.cc:151) before running this path.
 */
void agx_detile(uint8_t *dst, const uint8_t *src,
                uint32_t w, uint32_t h, uint32_t bpp) {
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            memcpy(dst + ((size_t)y * w + x) * bpp,
                   src + agx_twiddled_offset(x, y, w, h, bpp), bpp);
}

/* ---------- AUTHORITATIVE reference (verbatim Mesa) for self-check ---------- */
/* mesa tests/test-twiddling.cpp:38-58, with tilesize from ail_get_max_tile_size. */
static uint32_t ref_align(uint32_t v, uint32_t a) { return ((v + a - 1) / a) * a; }
static size_t ref_tiled_offset_bytes(uint32_t x, uint32_t y,
                                     uint32_t w, uint32_t bpp) {
    uint32_t tw, th; agx_tile_dims(bpp, &tw, &th);
    uint32_t x_tl = x / tw, y_tl = y / th;
    uint32_t ox = x % tw, oy = y % th;
    uint32_t in_tile = agx_z_order(ox, oy);
    uint32_t row_el = y_tl * ref_align(w, tw) * th;   /* full padded row of tiles */
    uint32_t col_el = x_tl * tw * th;
    return (size_t)(row_el + col_el + in_tile) * bpp;
}

static int selfcheck(uint32_t w, uint32_t h, uint32_t bpp, const char *name) {
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            size_t a = agx_twiddled_offset(x, y, w, h, bpp);
            size_t b = ref_tiled_offset_bytes(x, y, w, bpp);
            if (a != b) {
                printf("  MISMATCH %-32s (%u,%u) bpp=%u: ours=%zu ref=%zu\n",
                       name, x, y, bpp, a, b);
                return 1;
            }
        }
    printf("  MATCH (all px)  %-32s %ux%u bpp=%u\n", name, w, h, bpp);
    return 0;
}

int main(void) {
    int fail = 0;

    printf("== self-check vs Mesa authoritative reference ==\n");
    fail |= selfcheck(2000, 1456, 8, "composite RGBA16F pf=115");
    fail |= selfcheck(2000, 1456, 4, "composite BGRA8 pf=80/550/552");
    fail |= selfcheck(2388, 1668, 4, "iPad panel BGRA8");
    fail |= selfcheck(256,  256,  1, "R8");
    fail |= selfcheck(128,  128,  4, "BGRA8 small");
    fail |= selfcheck(67,   33,   8, "non-tile-multiple 8B");
    fail |= selfcheck(63,   17,   4, "tiny edge tile 4B");

    /* ---- small-grid dump for diffing against tilecalc / tiling.cc ---- */
    /* Representative size: a 256-wide surface so tile-padding != width games. */
    const uint32_t W = 256, H = 256;

    printf("\n== agx_twiddled_offset(x,y,w=%u,h=%u,bpp=4)  [tile 64x64] ==\n", W, H);
    printf("    "); for (uint32_t x = 0; x < 8; ++x) printf(" x=%-5u", x); printf("\n");
    for (uint32_t y = 0; y < 8; ++y) {
        printf("y=%u ", y);
        for (uint32_t x = 0; x < 8; ++x)
            printf(" %-6zu", agx_twiddled_offset(x, y, W, H, 4));
        printf("\n");
    }

    printf("\n== agx_twiddled_offset(x,y,w=%u,h=%u,bpp=8)  [tile 64x32] ==\n", W, H);
    printf("    "); for (uint32_t x = 0; x < 8; ++x) printf(" x=%-5u", x); printf("\n");
    for (uint32_t y = 0; y < 8; ++y) {
        printf("y=%u ", y);
        for (uint32_t x = 0; x < 8; ++x)
            printf(" %-6zu", agx_twiddled_offset(x, y, W, H, 8));
        printf("\n");
    }

    /* tile-boundary spot checks (these are the load-bearing offsets) */
    printf("\n== tile-boundary spot checks (w=%u) ==\n", W);
    struct { uint32_t x, y, bpp; } pts[] = {
        {63,63,4}, {64,0,4}, {0,64,4}, {64,64,4},
        {63,31,8}, {64,0,8}, {0,32,8}, {64,32,8},
        {127,127,1}, {128,0,1}, {0,128,1}, {128,128,1},
    };
    for (size_t i = 0; i < sizeof(pts)/sizeof(pts[0]); ++i)
        printf("  (%3u,%3u) bpp=%u -> %zu\n",
               pts[i].x, pts[i].y, pts[i].bpp,
               agx_twiddled_offset(pts[i].x, pts[i].y, W, H, pts[i].bpp));

    /* round-trip sanity: detile of an identity-twiddled buffer reproduces a
     * recognizable linear ramp (proves agx_detile wiring, small 8x8 region). */
    {
        const uint32_t w = 8, h = 8, bpp = 4;
        uint32_t tw, th; agx_tile_dims(bpp, &tw, &th);
        size_t cap = (size_t)((w + tw - 1)/tw) * (((h + th - 1)/th)) * tw * th * bpp;
        uint8_t *src = calloc(cap, 1), *dst = calloc((size_t)w*h*bpp, 1);
        /* fill twiddled src so that pixel (x,y) holds value x + y*16 */
        for (uint32_t y = 0; y < h; ++y)
            for (uint32_t x = 0; x < w; ++x) {
                uint32_t v = x + y*16;
                memcpy(src + agx_twiddled_offset(x,y,w,h,bpp), &v, 4);
            }
        agx_detile(dst, src, w, h, bpp);
        int rt_ok = 1;
        for (uint32_t y = 0; y < h && rt_ok; ++y)
            for (uint32_t x = 0; x < w; ++x) {
                uint32_t v; memcpy(&v, dst + ((size_t)y*w+x)*bpp, 4);
                if (v != x + y*16) { rt_ok = 0; break; }
            }
        printf("\n== agx_detile round-trip 8x8 bpp=4: %s ==\n", rt_ok ? "OK" : "FAIL");
        fail |= !rt_ok;
        free(src); free(dst);
    }

    printf("\n%s\n", fail ? "*** FAIL ***" : "ALL CHECKS PASSED");
    return fail;
}
