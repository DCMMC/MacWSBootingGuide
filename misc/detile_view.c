// Offline detile + PNG for a dumped AGX source backing (/tmp/macws_src.raw).
// Header: u32[6] = {w, h, pf, layout, bytes, stride}; then `bytes` of raw backing.
// Applies the verified Asahi AIL detile (per-tile Z-order) for tiled layouts, then
// decodes the pixel format (BGRA8 / BGRA10_XR / RGBA16Float) -> RGBA8 -> PNG.
//   cc -O2 -o /tmp/detile_view misc/detile_view.c -lz -lm
//   /tmp/detile_view /tmp/macws_src.raw out.png
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <zlib.h>

static uint32_t zo(uint32_t x, uint32_t y) {          // Asahi AIL: x->even bits, y->odd bits
    uint32_t o = 0;
    for (uint32_t i = 0; i < 8; i++) { uint32_t b = 1u << (2 * i); if (x & (1u << i)) o |= b; if (y & (1u << i)) o |= b << 1; }
    return o;
}
static uint8_t h2u8(uint16_t hh) {                     // IEEE half -> u8, clamp [0,1]
    uint32_t s = (hh >> 15) & 1, e = (hh >> 10) & 0x1f, m = hh & 0x3ff; float f;
    if (e == 0) f = ldexpf((float)m, -24); else if (e == 31) f = 1.0f; else f = ldexpf((float)(m + 1024), (int)e - 25);
    if (s) f = 0; if (f < 0) f = 0; if (f > 1) f = 1; return (uint8_t)(f * 255.0f + 0.5f);
}
static void wr(FILE *f, const char *t, const uint8_t *d, uint32_t n) {
    uint8_t b[4] = { n >> 24, n >> 16, n >> 8, n }; fwrite(b, 1, 4, f); fwrite(t, 1, 4, f); if (n) fwrite(d, 1, n, f);
    uint32_t c = crc32(0, (const Bytef *)t, 4); if (n) c = crc32(c, d, n);
    b[0] = c >> 24; b[1] = c >> 16; b[2] = c >> 8; b[3] = c; fwrite(b, 1, 4, f);
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s in.raw out.png\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror("open"); return 1; }
    uint32_t hd[7]; if (fread(hd, 4, 1, f) != 1) { fprintf(stderr, "short\n"); return 1; }
    uint32_t w, h, pf, layout, bytes, stride;
    if (hd[0] == 0x47524232u || hd[0] == 0x47524231u) {   // GRB2/GRB1 dest grab: magic,w,h,pf,layout,sz,bpr
        if (fread(hd + 1, 4, 6, f) != 6) { fprintf(stderr, "short GRB2\n"); return 1; }
        w = hd[1]; h = hd[2]; pf = hd[3]; layout = hd[4]; bytes = hd[5]; stride = hd[6];
        if (layout == 0xD0) layout = 0;    // detiled-linear marker -> linear (use bpr)
        else if (layout == 0xA0) layout = 2;   // raw-backing marker -> treat as tiled
    } else {                               // VERIFY-DETILE src: w,h,pf,layout,bytes,stride
        if (fread(hd + 1, 4, 5, f) != 5) { fprintf(stderr, "short\n"); return 1; }
        w = hd[0]; h = hd[1]; pf = hd[2]; layout = hd[3]; bytes = hd[4]; stride = hd[5];
    }
    if (argc > 3 && argv[3][0] == 't') { layout = 2; fprintf(stderr, "[forced tiled]\n"); }   // override: force detile
    if (argc > 3 && argv[3][0] == 'l') { layout = 0; fprintf(stderr, "[forced linear]\n"); }
    uint32_t stride_override = (argc > 4) ? (uint32_t)strtoul(argv[4], 0, 0) : 0;   // e.g. 9600 (2400px padded)
    if (stride_override) fprintf(stderr, "[stride override %u]\n", stride_override);
    uint8_t *src = malloc(bytes); if (fread(src, 1, bytes, f) != bytes) fprintf(stderr, "short data\n"); fclose(f);
    uint32_t bpp = (pf == 115) ? 8 : 4, tw = 64, th = (bpp == 8) ? 32 : 64;
    fprintf(stderr, "in: %ux%u pf=%u layout=%u bytes=%u stride=%u bpp=%u tile=%ux%u\n", w, h, pf, layout, bytes, stride, bpp, tw, th);
    uint8_t *lin = calloc((size_t)w * h, bpp);
    if (layout == 0) {                                  // linear: honor stride
        uint32_t st = stride_override ? stride_override
                    : ((stride >= w * bpp && (size_t)stride <= (size_t)w * bpp * 4) ? stride : w * bpp);
        for (uint32_t y = 0; y < h; y++) if ((size_t)y * st + (size_t)w * bpp <= bytes) memcpy(lin + (size_t)y * w * bpp, src + (size_t)y * st, (size_t)w * bpp);
    } else {                                            // tiled (GPU/twiddled): Asahi detile
        uint32_t tpr = (w + tw - 1) / tw;
        for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
            uint32_t in = zo(x % tw, y % th); uint32_t ti = (y / th) * tpr + (x / tw);
            size_t off = ((size_t)ti * tw * th + in) * bpp;
            if (off + bpp <= bytes) memcpy(lin + ((size_t)y * w + x) * bpp, src + off, bpp);
        }
    }
    uint8_t *rgba = malloc((size_t)w * h * 4);
    for (size_t i = 0; i < (size_t)w * h; i++) {
        uint8_t r = 0, g = 0, b = 0;
        if (pf == 115) { uint16_t *s = (uint16_t *)(lin + i * 8); r = h2u8(s[0]); g = h2u8(s[1]); b = h2u8(s[2]); }
        else if (pf == 550 || pf == 552) { uint32_t px = *(uint32_t *)(lin + i * 4); b = ((px >> 0) & 0x3ff) >> 2; g = ((px >> 10) & 0x3ff) >> 2; r = ((px >> 20) & 0x3ff) >> 2; }
        else { b = lin[i * 4 + 0]; g = lin[i * 4 + 1]; r = lin[i * 4 + 2]; }   // pf80 BGRA8
        rgba[i * 4 + 0] = r; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = b; rgba[i * 4 + 3] = 255;
    }
    size_t rs = (size_t)h * (1 + (size_t)w * 4); uint8_t *raw = malloc(rs);
    for (uint32_t y = 0; y < h; y++) { raw[(size_t)y * (1 + (size_t)w * 4)] = 0; memcpy(raw + (size_t)y * (1 + (size_t)w * 4) + 1, rgba + (size_t)y * w * 4, (size_t)w * 4); }
    uLongf cl = compressBound(rs); uint8_t *cp = malloc(cl); compress2(cp, &cl, raw, rs, 6);
    FILE *o = fopen(argv[2], "wb"); fwrite("\x89PNG\r\n\x1a\n", 1, 8, o);
    uint8_t ih[13] = { w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h, 8, 6, 0, 0, 0 };
    wr(o, "IHDR", ih, 13); wr(o, "IDAT", cp, (uint32_t)cl); wr(o, "IEND", NULL, 0); fclose(o);
    fprintf(stderr, "wrote %s (%ux%u)\n", argv[2], w, h); return 0;
}
