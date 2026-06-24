@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
#import <rootless.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <objc/runtime.h>
#import "utils.h"

#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <mach/vm_region.h>

extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef);
extern int IOSurfaceLock(IOSurfaceRef, uint32_t options, uint32_t *seed);
extern int IOSurfaceUnlock(IOSurfaceRef, uint32_t options, uint32_t *seed);

// MACWS_DISP_FILL_LOOP read-path probe (2026-06-20). Resolved once: enabled
// by env MACWS_DISP_FILL_LOOP or sentinel file /tmp/macws_disp_fill (chroot
// path; lets us toggle with a FAST libmachook-only build, no WS-plist edit
// that would trip the build guardrail). See
// [[vnc-read-path-is-cgdisplaycreateimage-compositor-black]]: CGDisplayCreateImage
// reads SkyLight's display surface; SURF_FILL_IOS filled it only at creation
// so WS's black composites overwrote it. This drives a continuous bg fill so
// the gray survives between composites — decisive for whether CreateImage
// reads the surface (CPU-copy bridge viable) or re-composites (need pinned VA).
extern size_t IOSurfaceGetWidth(IOSurfaceRef);
extern size_t IOSurfaceGetHeight(IOSurfaceRef);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef);
extern unsigned long IOSurfaceGetTypeID(void);
extern unsigned long CFGetTypeID(const void *);
extern uint32_t IOSurfaceGetPixelFormat(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerElement(IOSurfaceRef);
extern size_t IOSurfaceGetElementWidth(IOSurfaceRef);
extern size_t IOSurfaceGetElementHeight(IOSurfaceRef);
extern size_t IOSurfaceGetPlaneCount(IOSurfaceRef);
// Display-surface bridge mode. 0 = off, 1 = gray-fill (validation: proves
// CGDisplayCreateImage reads the surface), 2 = REAL copy (texture +0xa0
// backing -> IOSurface, the actual CPU-copy bridge). Resolved once via env
// or sentinel files so we can toggle with a FAST libmachook-only build
// (a WS-plist env edit would trip the build guardrail).
//   /tmp/macws_disp_copy  -> mode 2 (real content)
//   /tmp/macws_disp_fill  -> mode 1 (gray)
static int macws_disp_mode(void) {
    static int cached = -1;
    if (cached < 0) {
        if (getenv("MACWS_DISP_COPY") || access("/tmp/macws_disp_copy", F_OK) == 0)
            cached = 2;
        else if (getenv("MACWS_DISP_FILL_LOOP") || access("/tmp/macws_disp_fill", F_OK) == 0)
            cached = 1;
        else if (getenv("MACWS_TEX_SCAN") || access("/tmp/macws_tex_scan", F_OK) == 0)
            cached = 3;   // light density scan only (no copy/mirror) — stable
        else cached = 0;
    }
    return cached;
}
// Cross-process VNC share: WS mirrors the composite into a GLOBAL IOSurface that
// OSXvnc (a separate process) looks up by ID and blits into its frameBufferData
// (see mac_hooks.m macws_install_osxvnc_hooks / macws_vnc_fill). Gated by
// sentinel /tmp/macws_vnc_share. Content is still the tiled +0xa0 copy until the
// detile lands — this first proves the WS->OSXvnc->VNC pipeline with REAL bytes.
extern uint32_t IOSurfaceGetID(IOSurfaceRef);
static IOSurfaceRef g_vncSurf = NULL;
static id g_ws_cmdq = nil;   // WS's captured compositor command queue (WSQ-TEST: the only queue whose CBs submit)
static int macws_vnc_share_enabled(void) {
    static int c = -1;
    if (c < 0) c = (getenv("MACWS_VNC_SHARE") || access("/tmp/macws_vnc_share", F_OK) == 0) ? 1 : 0;
    return c;
}
static void macws_vnc_share_ensure(size_t w, size_t h) {
    if (g_vncSurf || w < 1000 || h < 600) return;
    NSDictionary *p = @{ @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
        @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
        @"IOSurfaceIsGlobal": @YES };
    g_vncSurf = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    if (g_vncSurf) {
        uint32_t sid = IOSurfaceGetID(g_vncSurf);
        FILE *f = fopen("/tmp/macws_vnc_surfid", "w");
        if (f) { fprintf(f, "%u\n", (unsigned)sid); fclose(f); }
        fprintf(stderr, "#### VNC-SHARE global surf id=%u %zux%zu\n", (unsigned)sid, w, h);
    }
}
// Mirror a filled display surface (base/sbpr/sh) into g_vncSurf for OSXvnc.
static void macws_vnc_share_mirror(void *base, size_t sbpr, size_t sh, size_t w) {
    if (!macws_vnc_share_enabled() || !base) return;
    // Skip empty/black surfaces so an empty frame doesn't CLOBBER a
    // content-bearing one (the bg loop mirrors every tracked surface,
    // last-writer-wins). Only mirror when this surface actually has content.
    size_t nz = 0, samp = 0, tot = sbpr * sh;
    for (size_t off = 0; off < tot; off += 4096) { if (((uint8_t *)base)[off]) nz++; samp++; }
    if (!samp || (double)nz / samp < 0.01) return;
    macws_vnc_share_ensure(w, sh);
    if (!g_vncSurf) return;
    if (IOSurfaceLock(g_vncSurf, 0, NULL) != 0) return;
    void *vb = IOSurfaceGetBaseAddress(g_vncSurf);
    size_t vbpr = IOSurfaceGetBytesPerRow(g_vncSurf);
    size_t vh = IOSurfaceGetHeight(g_vncSurf);
    if (vb) {
        size_t cw = sbpr < vbpr ? sbpr : vbpr;
        size_t rows = sh < vh ? sh : vh;
        for (size_t y = 0; y < rows; y++)
            memcpy((char *)vb + y * vbpr, (char *)base + y * sbpr, cw);
    }
    IOSurfaceUnlock(g_vncSurf, 0, NULL);
}
// Cross-process VNC channel via a MMAP'd file (IOSurfaceIsGlobal+Lookup(id)
// returns NULL across processes on this iOS — RE-confirmed). Both WS and OSXvnc
// are in the chroot and see /tmp/macws_vnc_fb. WS writes the detiled BGRA8 frame
// here; OSXvnc mmaps it read-only and blits into frameBufferData. Header (16B):
// [0]=magic 'VNCF', [1]=w, [2]=h, [3]=stride(=w*4); pixel data follows.
#import <sys/mman.h>
#import <fcntl.h>
static void *g_vnc_mmap = NULL;       // base (header + data)
static size_t g_vnc_mmap_w = 0, g_vnc_mmap_h = 0;
static void *macws_vnc_mmap_data(size_t w, size_t h) {
    if (g_vnc_mmap && g_vnc_mmap_w == w && g_vnc_mmap_h == h)
        return (char *)g_vnc_mmap + 16;
    size_t stride = w * 4, sz = 16 + stride * h;
    int fd = open("/tmp/macws_vnc_fb", O_RDWR | O_CREAT, 0666);
    if (fd < 0) return NULL;
    if (ftruncate(fd, sz) != 0) { close(fd); return NULL; }
    void *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return NULL;
    uint32_t *hdr = (uint32_t *)m;
    hdr[0] = 0x564E4346u; hdr[1] = (uint32_t)w; hdr[2] = (uint32_t)h; hdr[3] = (uint32_t)stride;
    g_vnc_mmap = m; g_vnc_mmap_w = w; g_vnc_mmap_h = h;
    fprintf(stderr, "#### VNC-MMAP /tmp/macws_vnc_fb %zux%zu sz=%zu\n", w, h, sz);
    return (char *)m + 16;
}
// Half (IEEE binary16) -> u8 [0,255], clamped to [0,1]. For RGBA16Float composites.
static inline uint8_t macws_half_to_u8(uint16_t h) {
    uint16_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff;
    float f;
    if (e == 0) f = ldexpf((float)m, -24);
    else if (e == 31) f = 1.0f;
    else f = ldexpf((float)(m + 1024), (int)e - 25);
    if (s) f = 0.0f;            // negatives clamp to 0
    if (f < 0) f = 0; if (f > 1) f = 1;
    return (uint8_t)(f * 255.0f + 0.5f);
}
// WS-RENDER-THREAD composite-completion capture. Called from the StartComposite
// hook (mac_hooks.m, WS thread) with the current frame's display destination.
// getBytes the PREVIOUS frame's dest (now GPU-complete) — Metal-native DETILE —
// convert to BGRA8 -> g_vncSurf (cross-process to OSXvnc). This is the reliable
// content source the bg-thread +0xa0 sampling could not be (the backing is only
// valid at completion). getBytes is SAFE on the WS thread between frames (it
// crashed only from the async bg thread racing active render). Throttled. ARC
// keeps the previous texture alive via the strong static.
// Composite-completion capture, SPLIT for safety:
//   - render thread (WSCD StartComposite hook): only STASH the dest texture
//     pointer (cheap, no read) — the big +0xa0 memcpy on the render thread
//     destabilized WS (A/B-confirmed).
//   - background thread: raw memcpy of the stashed dest's +0xa0 backing ->
//     g_vncSurf. A bg-thread raw +0xa0 read is SAFE (proven by the bridge);
//     reading the STASHED composite dest (not random tracked textures) makes
//     it RELIABLE. Concurrent GPU writes -> tearing, not a crash. getBytes is
//     unusable (hangs render / crashes bg). Backing is AGX-TILED -> g_vncSurf
//     holds tiled bytes (CPU twiddle-detile is the remaining TODO).
static id<MTLTexture> g_vnc_comp_tex = nil;   // stashed composite dest (ARC strong)
static id g_vnc_lock = nil;

// DETILE SELF-TEST (gated /tmp/macws_vnc_selftest, one-shot). Runs INSIDE WS —
// the only context where AGX GPU command submission actually executes (a
// standalone chroot CLI fails every clear/blit with Internal Error 0x102/0x103;
// misc/DetileTest/main.m runtime-confirmed 2026-06-21).
//
// Strategy: use the REAL composite `t0` as the (genuinely AGX-laid-out) source —
// NO synthetic fill, so NO -replaceRegion (which crashes: writeRegion ->
// memmove dst=NULL on the pooled wrapper). Blit t0 into the pipeline's idle dst,
// then read dst BOTH ways and compare them to each other:
//   G = getBytes(dst)         — the driver's canonical detiled/linear output
//   A = raw bytes at impl+0xa0 — EXACTLY what the VNC pipeline memcpy's (w*4)
// If A == G the pipeline read path is CORRECT. If A != G, +0xa0 is the wrong
// memory / wrong stride and that's the real bug. Also logs dst layout(+0x184)
// & stride(+0xa8), and whether dst aliases t0 (pool dedupe would void the test).
// Dumps both reads to /tmp/detile_getbytes.raw + /tmp/detile_a0.raw.
// Returns 1 when the test ran to a valid comparison (or hit an unrecoverable
// condition); 0 to ask the caller to RETRY (the GPU submission context needs a
// few frames to warm up — early blits fail Internal Error 0x103, like the
// production VNC-BLIT path does before it settles).
static int macws_vnc_selftest(id<MTLTexture> t0) {
    if (!t0) return 0;
    static int attempt = 0;
    attempt++;
    id<MTLDevice> dev = [t0 device];
    size_t w = [t0 width], h = [t0 height], bpr = w * 4, sz = bpr * h;
    unsigned long pf = (unsigned long)[t0 pixelFormat];
    if (!dev || pf != 80 /*BGRA8*/ || w < 100 || h < 100) {
        fprintf(stderr, "#### SELFTEST skip dev=%p pf=%lu %zux%zu (need BGRA8 >=100px)\n",
                (void*)dev, pf, w, h);
        return 1;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pf width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:d];   // pipeline's idle dst
    if (!dst) { fprintf(stderr, "#### SELFTEST dst nil\n"); return 1; }
    if (dst == t0) { fprintf(stderr, "#### SELFTEST dst==t0 (pool aliased src) — cannot test\n"); return 1; }

    // Reuse ONE command queue like the production VNC-BLIT path — a fresh
    // newCommandQueue per attempt fails submission (chroot AGX queue blocker).
    static id<MTLCommandQueue> q = nil;
    if (!q) q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:t0 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(w,h,1) toTexture:dst destinationSlice:0 destinationLevel:0
     destinationOrigin:MTLOriginMake(0,0,0)];
    [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if ([cb status] != MTLCommandBufferStatusCompleted) {
        if (attempt <= 3 || attempt % 40 == 0)
            fprintf(stderr, "#### SELFTEST detile blit FAILED (attempt %d) status=%ld err=%s\n",
                    attempt, (long)[cb status],
                    [cb error] ? [[[cb error] localizedDescription] UTF8String] : "none");
        return (attempt >= 400) ? 1 : 0;   // retry until warm; give up after ~20s
    }
    fprintf(stderr, "#### SELFTEST blit OK on attempt %d\n", attempt);

    // dst layout fields
    void *impl = *(void **)((char *)(__bridge void *)dst + 0x208);
    void *backing = ((uintptr_t)impl > 0x1000) ? *(void **)((char *)impl + 0xa0) : NULL;
    uint8_t layout = ((uintptr_t)impl > 0x1000) ? *(uint8_t  *)((char *)impl + 0x184) : 0xff;
    uint32_t stride = ((uintptr_t)impl > 0x1000) ? *(uint32_t *)((char *)impl + 0xa8) : 0;

    // G = getBytes (driver canonical) ; A = raw +0xa0 (pipeline read)
    uint8_t *gb = (uint8_t *)malloc(sz);
    int haveGB = 0;
    if (gb) {
        @try {
            [dst getBytes:gb bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            haveGB = 1;
        } @catch (NSException *e) { fprintf(stderr, "#### SELFTEST getBytes EXC %s\n", [[e reason] UTF8String]?:"?"); }
    }
    size_t diff = 0, samp = 0, nzG = 0, nzA = 0;
    if (haveGB && backing) {
        for (size_t i = 0; i < sz; i += 37) {
            samp++;
            uint8_t gv = gb[i], av = ((uint8_t*)backing)[i];
            if (gv != av) diff++;
            if (gv) nzG++;
            if (av) nzA++;
        }
    }
    fprintf(stderr, "#### SELFTEST dst=%p layout=%u stride=%u backing=%p  "
            "getBytes-vs-+0xa0 mismatch=%zu/%zu (%.1f%%)  nonzero getBytes=%zu +0xa0=%zu\n",
            (void*)dst, layout, stride, backing, diff, samp,
            samp ? 100.0*diff/samp : 0.0, nzG, nzA);

    if (haveGB) { FILE *f = fopen("/tmp/detile_getbytes.raw", "wb");
        if (f) { uint32_t hd[4]={(uint32_t)w,(uint32_t)h,80,(uint32_t)bpr}; fwrite(hd,4,4,f); fwrite(gb,1,sz,f); fclose(f); } }
    if (backing) { FILE *f = fopen("/tmp/detile_a0.raw", "wb");
        if (f) { uint32_t hd[4]={(uint32_t)w,(uint32_t)h,80,(uint32_t)bpr}; fwrite(hd,4,4,f); fwrite(backing,1,sz,f); fclose(f); } }
    if (gb) free(gb);
    return 1;
}
// Asahi-RE-informed VNC capture primitive (docs/asahi-agx-findings.md §1/§4):
// the composite is AGX GPU-tiled AND lossless-COMPRESSED by default, so a raw
// +0xa0 CPU read is scrambled garbage. copyFromTexture:toBuffer: makes Metal
// DECOMPRESS + DETILE into a LINEAR buffer in one GPU op (format-agnostic: copies
// bytes/pixel in row-major order; sidesteps the pf=550 buffer-backed-texture abort
// that macws_blit_detile hits). Caller CPU-decodes per pf -> BGRA8. Returns 1 +
// fills *base (=[buf contents], valid until next call) /*bpr/*w/*h; 0 on early/
// failed frames (the chroot AGX queue needs a few frames to warm).
static int macws_blit_to_linear(id<MTLTexture> src, void **out_base, size_t *out_bpr,
                                size_t *out_w, size_t *out_h) {
    @try {
        if (!src) return 0;
        size_t w = [src width], h = [src height];
        unsigned long spf = (unsigned long)[src pixelFormat];
        id<MTLDevice> dev = [src device];
        if (!dev || w == 0 || h == 0) return 0;
        // --- resolve the source's layout byte + its +0xa0 IOSurface (safe, guarded) ---
        void *impl = *(void **)((char *)(__bridge void *)src + 0x208);
        uint8_t layout = ((uintptr_t)impl > 0x1000) ? *(volatile uint8_t *)((char *)impl + 0x184) : 0xff;
        IOSurfaceRef s = NULL;
        if ((uintptr_t)impl > 0x1000) {
            void *cand = *(void **)((char *)impl + 0xa0);
            if (cand) {
                vm_address_t a = (vm_address_t)cand; vm_size_t rsz = 0;
                vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t mo = MACH_PORT_NULL;
                if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                                 (vm_region_info_t)&bi, &cnt, &mo) == KERN_SUCCESS &&
                    a <= (vm_address_t)cand && (bi.protection & VM_PROT_READ)) {
                    @try { if (CFGetTypeID(cand) == IOSurfaceGetTypeID()) s = (IOSurfaceRef)cand; }
                    @catch (__unused NSException *e) {}
                }
            }
        }
        // Per-distinct-surface content probe: find WHICH composite dest holds the macOS
        // pixels (nonzero%) and its layout — the pf=80 scanout is empty; the content is
        // elsewhere (likely pf=550 tiled). Sampled from the resolved IOSurface base.
        { static unsigned long seen[24]; static int ns = 0;
          unsigned long key = ((unsigned long)spf << 40) ^ ((unsigned long)w << 20) ^ (unsigned long)h;
          int dup = 0; for (int i = 0; i < ns; i++) if (seen[i] == key) { dup = 1; break; }
          if (!dup && ns < 24) { seen[ns++] = key;
            uint8_t pbe7 = ((uintptr_t)impl > 0x1000) ? *(uint8_t *)((char *)impl + 0x190 + 7) : 0;
            void *b = s ? IOSurfaceGetBaseAddress(s) : NULL;
            size_t lim = s ? IOSurfaceGetAllocSize(s) : 0; if (lim > (size_t)w * h * 8) lim = (size_t)w * h * 8;
            size_t nz = 0, sm = 0; if (b) for (size_t i = 0; i < lim; i += 997) { sm++; if (((uint8_t *)b)[i]) nz++; }
            fprintf(stderr, "#### VNC-SURF pf=%lu %zux%zu layout=%u compressed=%d iosurf=%p nonzero=%.1f%%\n",
                    spf, w, h, layout, (pbe7 >> 3) & 1, (void *)s, sm ? 100.0 * nz / sm : -1.0); } }
        // NOTE: do NOT direct-read +0xa0 even for layout==0 — that IOSurface is the WIRED-
        // but-empty one (AGX_WIRE_IOSURF: the GPU renders the real content into a SEPARATE
        // backing, the IOSurface stays zero — memory composite-iosurface-all-zero). The
        // GPU BLIT reads the texture's ACTUAL content (Apple logo / desktop). Always blit.
        // --- GPU blit into a buffer-backed LINEAR texture (reads the real GPU backing) ---
        if (spf == 550 || spf == 552) {   // pf550 buffer-backed readback aborts; no converter yet
            static int sk = 0; if (sk < 3) { sk++; fprintf(stderr, "#### VNC-BLIT pf=%lu tiled: no linear readback yet (skip)\n", spf); }
            return 0;
        }
        MTLPixelFormat dpf = (spf == 115) ? (MTLPixelFormat)115 : (MTLPixelFormat)80;
        size_t bpp = (spf == 115) ? 8 : 4;
        size_t align = 256;
        @try { NSUInteger al = [dev minimumLinearTextureAlignmentForPixelFormat:dpf]; if (al > align) align = al; } @catch (__unused NSException *e) {}
        size_t bpr = ((w * bpp + align - 1) / align) * align, sz = bpr * h;
        static id<MTLCommandQueue> q = nil; static id<MTLBuffer> buf = nil; static id<MTLTexture> lintex = nil;
        static size_t lw = 0, lh = 0; static MTLPixelFormat lpf = 0;
        if (!q) q = [dev newCommandQueue];
        if (!buf || lw != w || lh != h || lpf != dpf) {
            buf = [dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dpf width:w height:h mipmapped:NO];
            dd.storageMode = MTLStorageModeShared; dd.usage = MTLTextureUsageShaderRead;
            lintex = buf ? [buf newTextureWithDescriptor:dd offset:0 bytesPerRow:bpr] : nil;
            lw = w; lh = h; lpf = dpf;
        }
        { static int sl = 0; if (sl < 3) { sl++; fprintf(stderr, "#### VNC-BLIT setup q=%p buf=%p lintex=%p dpf=%lu bpr=%zu\n",
              (void *)q, (void *)buf, (void *)lintex, (unsigned long)dpf, bpr); } }
        if (!q || !buf || !lintex) return 0;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                 sourceSize:MTLSizeMake(w,h,1) toTexture:lintex destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0,0,0)];
        [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if ([cb status] != MTLCommandBufferStatusCompleted) {
            static int fl = 0; if (fl < 5) { fl++;
                fprintf(stderr, "#### VNC-BLIT toTexture status=%ld err=%s\n", (long)[cb status],
                        [cb error] ? [[[cb error] localizedDescription] UTF8String] : "none"); }
            return 0;
        }
        void *base = [buf contents];
        if (!base) return 0;
        // Proof for "the Apple logo composites, so +0xa0 was the wrong read": does the BLIT
        // surface content the wired +0xa0 IOSurface missed?
        { static int cl = 0; if (cl < 4) { cl++;
            size_t nzB = 0, smB = 0; for (size_t i = 0; i < sz; i += 4093) { smB++; if (((uint8_t *)base)[i]) nzB++; }
            void *a0 = s ? IOSurfaceGetBaseAddress(s) : NULL; size_t nzA = 0, smA = 0;
            if (a0) { size_t la = IOSurfaceGetAllocSize(s); if (la > sz) la = sz;
                      for (size_t i = 0; i < la; i += 4093) { smA++; if (((uint8_t *)a0)[i]) nzA++; } }
            fprintf(stderr, "#### VNC-CONTENT %zux%zu pf=%lu: BLIT nonzero=%.1f%%  vs  +0xa0 nonzero=%.1f%%\n",
                    w, h, spf, smB ? 100.0 * nzB / smB : -1.0, smA ? 100.0 * nzA / smA : -1.0); } }
        *out_base = base; *out_bpr = bpr; *out_w = w; *out_h = h;
        return 1;
    } @catch (NSException *e) {
        fprintf(stderr, "#### VNC-BLIT EXC %s\n", [[e reason] UTF8String] ?: "?");
        return 0;
    }
}
void macws_vnc_on_composite(id<MTLTexture> dest) {
    if (!macws_vnc_share_enabled() || !dest) return;
    // Cheap per-distinct-dest log (layout only, no content read = render-thread-safe): see
    // EVERY composite dest the 3 StartComposite hooks feed, to find which holds macOS pixels.
    { static unsigned long seen[32]; static int ns = 0;
      @try { size_t w = [dest width], h = [dest height]; unsigned long pf = (unsigned long)[dest pixelFormat];
        unsigned long key = ((unsigned long)pf << 40) ^ ((unsigned long)w << 20) ^ (unsigned long)h;
        int dup = 0; for (int i = 0; i < ns; i++) if (seen[i] == key) { dup = 1; break; }
        if (!dup && ns < 32) { seen[ns++] = key;
          void *impl = *(void **)((char *)(__bridge void *)dest + 0x208);
          uint8_t layout = ((uintptr_t)impl > 0x1000) ? *(volatile uint8_t *)((char *)impl + 0x184) : 0xff;
          IOSurfaceRef s = NULL;
          if ((uintptr_t)impl > 0x1000) { void *cand = *(void **)((char *)impl + 0xa0);
            if (cand) { vm_address_t a = (vm_address_t)cand; vm_size_t rsz = 0;
              vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t mo = MACH_PORT_NULL;
              if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &mo) == KERN_SUCCESS
                  && a <= (vm_address_t)cand && (bi.protection & VM_PROT_READ)) {
                @try { if (CFGetTypeID(cand) == IOSurfaceGetTypeID()) s = (IOSurfaceRef)cand; } @catch (__unused NSException *e) {} } } }
          void *b = s ? IOSurfaceGetBaseAddress(s) : NULL;
          size_t lim = s ? IOSurfaceGetAllocSize(s) : 0; if (lim > (size_t)w * h * 8) lim = (size_t)w * h * 8;
          size_t nz = 0, sm = 0; if (b) for (size_t i = 0; i < lim; i += 4093) { sm++; if (((uint8_t *)b)[i]) nz++; }
          fprintf(stderr, "#### VNC-DEST pf=%lu %zux%zu layout=%u iosurf=%p nonzero=%.1f%%\n",
                  pf, w, h, layout, (void *)s, sm ? 100.0 * nz / sm : -1.0); }
      } @catch (__unused NSException *e) {} }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_vnc_lock = [NSObject new];
        [NSThread detachNewThreadWithBlock:^{
            for (;;) {
                // (old separate-blit self-test retired — its standalone blit fails
                //  0x103 for reasons orthogonal to detile; the in-production SELFCHK
                //  below piggybacks the already-working VNC-BLIT instead.)
                (void)macws_vnc_selftest;
                id<MTLTexture> t = nil;
                @synchronized(g_vnc_lock) { t = g_vnc_comp_tex; }  // ARC retains into local
                if (t) {
                    size_t w = [t width], h = [t height];
                    unsigned long pf = (unsigned long)[t pixelFormat];
                    if (w >= 1000 && h >= 600 && (pf == 80 || pf == 550 || pf == 552 || pf == 115)) {
                        // Asahi RE (docs/asahi-agx-findings.md §4): the composite is AGX
                        // GPU-tiled AND lossless-COMPRESSED, so the old "blit to a default
                        // tiled dst + read +0xa0" produced scrambled garbage. copyFromTexture:
                        // toBuffer: makes Metal decompress+detile into a LINEAR buffer; then
                        // CPU-decode per pf -> BGRA8 -> VNC mmap. pf=550 (the real composite)
                        // is now accepted (toBuffer avoids the pf=550 texture-creation abort).
                        void *lin = NULL; size_t lbpr = 0, lw = 0, lh = 0;
                        if (macws_blit_to_linear(t, &lin, &lbpr, &lw, &lh)) {
                            void *vb = macws_vnc_mmap_data(lw, lh);
                            size_t vbpr = lw * 4;
                            if (vb) {
                                for (size_t y = 0; y < lh; y++) {
                                    uint8_t *d8 = (uint8_t *)vb + y * vbpr;
                                    char *row = (char *)lin + y * lbpr;
                                    if (pf == 115) {                       // RGBA16Float -> BGRA8
                                        uint16_t *s = (uint16_t *)row;
                                        for (size_t x = 0; x < lw; x++) {
                                            d8[x*4+0] = macws_half_to_u8(s[x*4+2]);
                                            d8[x*4+1] = macws_half_to_u8(s[x*4+1]);
                                            d8[x*4+2] = macws_half_to_u8(s[x*4+0]);
                                            d8[x*4+3] = 0xff;
                                        }
                                    } else if (pf == 550 || pf == 552) {   // BGRA10_XR packed 32b -> BGRA8 (10b>>2; exact XR color decode deferred, doc §5 P2)
                                        uint32_t *s = (uint32_t *)row;
                                        for (size_t x = 0; x < lw; x++) {
                                            uint32_t px = s[x];
                                            d8[x*4+0] = (uint8_t)(((px >>  0) & 0x3ff) >> 2);  // ch0
                                            d8[x*4+1] = (uint8_t)(((px >> 10) & 0x3ff) >> 2);  // ch1
                                            d8[x*4+2] = (uint8_t)(((px >> 20) & 0x3ff) >> 2);  // ch2
                                            d8[x*4+3] = 0xff;
                                        }
                                    } else {                               // pf 80 BGRA8 straight
                                        memcpy(d8, row, vbpr);
                                    }
                                }
                                static int lg = 0;
                                if (lg < 3) { fprintf(stderr, "#### VNC-BLIT(linear toBuffer) %zux%zu pf=%lu bpr=%zu -> mmap\n", lw, lh, pf, lbpr); lg++; }
                            }
                        }
                    }
                }
                usleep(50000);   // ~20 fps
            }
        }];
    });
    @synchronized(g_vnc_lock) { g_vnc_comp_tex = dest; }   // cheap stash, render thread
}

// 2026-06-22 — DEBUG composite capture (gated /tmp/macws_grab_png). Crash-safe:
// runs on the WS RENDER THREAD (called from the StartComposite hook). DIRECT
// +0xa0 CPU read of the composite dest's C++ AGX::Texture backing — NO getBytes
// (getBytes on any AGX tex hits NULL +0xa0 inside readRegion<layout3> →
// memmove(0) → WS SIGSEGV, runtime-confirmed WindowServer-2026-06-22-174347.ips).
// The +0xa0 backing read is LINEAR (RE-confirmed 2026-06-21
// [[detile-read-correct-composite-empty]]). memcpy is clamped to the mapped vm
// extent so a short backing can't fault.
//
// Two functions, both gated /tmp/macws_grab_png:
//   A. CONTENT PROBE — every full-screen composite, log pf + nonzero% of its
//      backing (cheap sampled scan). Tells which surface (pf=80 capture vs
//      pf=550 display) actually carries content, with no capture.
//   B. CAPTURE — when /tmp/macws_grab_now exists, dump that surface's backing to
//      /tmp/macws_grab.raw then unlink the trigger (re-armable: touch again to
//      grab a fresh frame AFTER the app is fully up). Header (24B): magic 'GRB1',
//      w, h, pf, layout, copied_bytes. stride = copied/h offline.
static ptrdiff_t macws_tex_impl_off(void) {
    static ptrdiff_t off = 0;
    if (!off) {
        Class cls = objc_getClass("AGXG13GFamilyTexture");
        Ivar iv = cls ? class_getInstanceVariable(cls, "_impl") : NULL;
        off = iv ? ivar_getOffset(iv) : 0x208;   // RE-fallback
    }
    return off;
}
// Resolve the linear CPU backing of a composite-dest AGX texture. Returns base
// (or NULL) and fills *layout + *ext (readable vm extent from base).
//
// 2026-06-22 CRITICAL FIX: for the compositor's OWN render-target
// AGXG13GFamilyTexture, `_impl+0xa0` is NOT a flat pixel pointer — it is an
// **IOSurface object** (lldb-confirmed: isa resolves to the IOSurface class;
// embedded label = pf550 fullscreen surface). The real pixels are reached via
// IOSurfaceGetBaseAddress(thatObject), NOT by reading +0xa0 as bytes. (The
// SYNTHESIZED pooled textures are different — macws_wire_iosurface_base_into_texture
// sets THEIR +0xa0 = raw IOSurface base. So detect which kind we have.)
static void *macws_tex_backing(id<MTLTexture> tex, uint8_t *layout_out, size_t *ext_out) {
    if (layout_out) *layout_out = 0xff;
    if (ext_out) *ext_out = 0;
    if (!tex) return NULL;
    void *impl = *(void **)((char *)(__bridge void *)tex + macws_tex_impl_off());
    if (!impl) return NULL;
    if (layout_out) *layout_out = *(volatile uint8_t *)((char *)impl + 0x184);
    void *backing = *(void **)((char *)impl + 0xa0);
    if (!backing) return NULL;
    // Is `backing` an IOSurface OBJECT (compositor render-target case) or a raw
    // pixel pointer (synthesized pooled case)? Check whether it's a valid objc
    // object whose class is IOSurface — if so, resolve its real base address.
    // Canonical IOSurface detection: CFGetTypeID(backing) == IOSurfaceGetTypeID().
    // (objc_getClass("IOSurface") returns nil in the chroot, so the old
    // object_getClass check never matched → we fell through to reading the
    // IOSurface OBJECT header as pixels = "noise". This is THE read bug behind
    // the bogus "composite empty" conclusion. The real pixels are
    // IOSurfaceGetBaseAddress(thatObject).) Guard the CFGetTypeID deref by first
    // confirming `backing` sits in a readable region.
    void *resolved = backing;
    int is_surf = 0;
    {
        vm_address_t a = (vm_address_t)backing; vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t mo = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&bi, &cnt, &mo) == KERN_SUCCESS &&
            a <= (vm_address_t)backing && (bi.protection & VM_PROT_READ)) {
            @try {
                if (CFGetTypeID(backing) == IOSurfaceGetTypeID()) {
                    IOSurfaceRef s = (IOSurfaceRef)backing;
                    IOSurfaceLock(s, 0x1 /*kIOSurfaceLockReadOnly*/, NULL);
                    void *b = IOSurfaceGetBaseAddress(s);
                    if (b) { resolved = b; is_surf = 1; }
                    // One-shot per (pf) METADATA dump — the exact layout params for
                    // offline de-tile (bpe disambiguates 4 vs 8 byte; bpr = stride;
                    // allocSize = full surface size; elem dims hint tiling).
                    static _Atomic int metalog = 0;
                    if (atomic_fetch_add(&metalog, 1) < 8) {
                        fprintf(stderr, "#### IOSURF-META surf=%p w=%zu h=%zu pf=0x%x bpe=%zu bpr=%zu alloc=%zu elem=%zux%zu planes=%zu\n",
                            (void*)s, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
                            IOSurfaceGetPixelFormat(s), IOSurfaceGetBytesPerElement(s),
                            IOSurfaceGetBytesPerRow(s), IOSurfaceGetAllocSize(s),
                            IOSurfaceGetElementWidth(s), IOSurfaceGetElementHeight(s),
                            IOSurfaceGetPlaneCount(s));
                    }
                }
            } @catch (__unused NSException *e) { }
        }
    }
    { static _Atomic int diaglog = 0; int n = atomic_fetch_add(&diaglog, 1);
      if (n < 6) fprintf(stderr, "#### TEX-BACKING +0xa0=%p is_iosurface=%d resolved=%p\n",
                         backing, is_surf, resolved); }
    size_t ext = 0; vm_address_t want = (vm_address_t)resolved;
    for (int i = 0; i < 4096; i++) {
        vm_address_t a = want; vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&bi, &cnt, &obj) != KERN_SUCCESS) break;
        if (a > want || !(bi.protection & VM_PROT_READ)) break;
        vm_address_t end = a + rsz; if (end <= want) break;
        ext += (size_t)(end - want); want = end;
    }
    if (ext_out) *ext_out = ext;
    if (ext == 0) return NULL;
    return resolved;
}
// GPU-blit DE-TILE: the composite dest IOSurface holds AGX-twiddled (Morton)
// pixels — a raw linear read is spatially scrambled. Blit the (twiddled) source
// texture into a LINEAR buffer-backed texture; the AGX blit engine de-twiddles
// into the buffer's linear layout. Read [buf contents] directly (NOT getBytes —
// that crashes on chroot AGX textures). Returns malloc'd linear pixels (caller
// frees) + sets *out_bpr/*out_sz, or NULL on any failure (caller falls back to
// the twiddled read). Same pixel format as src (pf=550 stays 10-bit).
static uint8_t *macws_blit_detile(id<MTLTexture> src, size_t *out_bpr, size_t *out_sz) {
    // OPT-IN ONLY (gate /tmp/macws_detile). For pf=550 the chroot texture-creation
    // path aborts (AGXTexture init → MTLReportFailure, runtime-confirmed
    // WindowServer-2026-06-22-204831.ips), so the blit-detile crashes WS. Default
    // OFF → the grab safely writes twiddled-raw. Only enable for pf=80 experiments.
    if (access("/tmp/macws_detile", F_OK) != 0) return NULL;
    @try {
        size_t w = [src width], h = [src height];
        id<MTLDevice> dev = [src device];
        if (!dev || w == 0 || h == 0) return NULL;
        // pf=550 has NO safe GPU-readback path in the chroot: a buffer-backed pf=550
        // texture ABORTS (_mtlValidateStrideTextureParameters) AND a BGRA8 reinterpret
        // VIEW of the pf=550 texture HARD-CRASHES WS (runtime-confirmed 2026-06-23,
        // WindowServer-...020254.ips — crash before any DETILE log). Skip it; the dest
        // GPU content stays unreadable via CPU/blit until a working readback exists.
        MTLPixelFormat pf = [src pixelFormat];
        if ((unsigned long)pf == 550) { fprintf(stderr, "#### DETILE: pf=550 has no safe readback path — skipping\n"); return NULL; }
        id<MTLTexture> bsrc = src;
        size_t bpp = 4;  // pf 80/70 are 4 bytes/pixel
        size_t align = 256;
        @try { NSUInteger a = [dev minimumLinearTextureAlignmentForPixelFormat:pf];
               if (a > align) align = a; } @catch (__unused NSException *e) {}
        size_t bpr = ((w * bpp + align - 1) / align) * align;
        size_t sz = bpr * h;
        fprintf(stderr, "#### DETILE: w=%zu h=%zu pf=%lu bpr=%zu sz=%#zx\n", w, h, (unsigned long)pf, bpr, sz);
        // BUFFER-BACKED linear dst (works for BGRA8/RGBA8 pf=80/70; returns nil for
        // pf=550 → safe fallback). The blit de-twiddles into the buffer's linear
        // layout; read [buf contents] directly (NOT getBytes).
        id<MTLBuffer> buf = [dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
        if (!buf) { fprintf(stderr, "#### DETILE: newBuffer nil\n"); return NULL; }
        MTLTextureDescriptor *dd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
        dd.storageMode = MTLStorageModeShared;
        dd.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> lintex = [buf newTextureWithDescriptor:dd offset:0 bytesPerRow:bpr];
        if (!lintex) { fprintf(stderr, "#### DETILE: buffer-backed lintex nil (pf=%lu unsupported)\n", (unsigned long)pf); return NULL; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:bsrc sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                 sourceSize:MTLSizeMake(w,h,1) toTexture:lintex destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if ([cb status] != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "#### DETILE: blit status=%ld\n", (long)[cb status]);
            return NULL;
        }
        void *base = [buf contents];
        if (!base) { fprintf(stderr, "#### DETILE: buf contents nil\n"); return NULL; }
        fprintf(stderr, "#### DETILE: OK linear bpr=%zu sz=%#zx\n", bpr, sz);
        uint8_t *res = (uint8_t *)malloc(sz);
        if (!res) return NULL;
        memcpy(res, base, sz);
        if (out_bpr) *out_bpr = bpr;
        if (out_sz) *out_sz = sz;
        return res;
    } @catch (NSException *e) {
        fprintf(stderr, "#### DETILE EXC %s\n", [[e reason] UTF8String] ?: "?");
        return NULL;
    }
}
// RAW +0xa0 backing (NO IOSurface resolution) + its readable vm extent. In
// coexist the GPU renders into this raw backing while the texture's IOSurface
// stays empty (AGX_WIRE_IOSURF "SEPARATE backing" pattern), so compare both.
static void *macws_tex_raw_backing(id<MTLTexture> tex, size_t *ext_out) {
    if (ext_out) *ext_out = 0;
    if (!tex) return NULL;
    void *impl = *(void **)((char *)(__bridge void *)tex + macws_tex_impl_off());
    if (!impl) return NULL;
    void *backing = *(void **)((char *)impl + 0xa0);
    if (!backing) return NULL;
    // GRAB BUG FIX (2026-06-23): in the compositor case +0xa0 is an IOSurface
    // OBJECT, not a raw pixel buffer. Reading it as bytes yields the object
    // header (~9% nonzero = noise) which falsely beat the (empty) resolved
    // IOSurface base and made the grab capture noise instead of reporting the
    // surface honestly empty. Only treat +0xa0 as a raw buffer when it is NOT
    // an IOSurface object (synthesized-pool case); IOSurface objects go through
    // macws_tex_backing's IOSurfaceGetBaseAddress path.
    {
        vm_address_t a = (vm_address_t)backing; vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t mo = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&bi, &cnt, &mo) == KERN_SUCCESS &&
            a <= (vm_address_t)backing && (bi.protection & VM_PROT_READ)) {
            @try { if (CFGetTypeID(backing) == IOSurfaceGetTypeID()) return NULL; }
            @catch (__unused NSException *e) {}
        }
    }
    size_t ext = 0; vm_address_t want = (vm_address_t)backing;
    for (int i = 0; i < 4096; i++) {
        vm_address_t a = want; vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t mo = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&bi, &cnt, &mo) != KERN_SUCCESS) break;
        if (a > want || !(bi.protection & VM_PROT_READ)) break;
        vm_address_t end = a + rsz; if (end <= want) break;
        ext += (size_t)(end - want); want = end;
    }
    if (ext_out) *ext_out = ext;
    if (ext == 0) return NULL;
    return backing;
}
// IMPL-STRUCT SCAN (gated /tmp/macws_impl_scan): the compositor dest texture's
// GPU-rendered pixels live in a SEPARATE backing (the +0xa0 IOSurface CPU base is
// EMPTY). Scan the AGX texture impl struct for ANY pointer to a ~surface-sized
// readable region + sample its content% to locate that separate backing — answers
// "is GlassDemo rendered-but-mis-routed (some offset has content) or never
// rendered (all empty)". Read-only; vm_region-guarded; no GPU ops.
static void macws_scan_impl_backings(id<MTLTexture> tex, size_t surf_sz) {
    void *impl = *(void **)((char *)(__bridge void *)tex + macws_tex_impl_off());
    if (!impl) return;
    fprintf(stderr, "#### IMPL-SCAN begin impl=%p surf_sz=%#zx\n", impl, surf_sz);
    for (size_t off = 0; off < 0x400; off += 8) {
        void *p = *(void **)((char *)impl + off);
        if ((uintptr_t)p < 0x10000 || ((uintptr_t)p & 7)) continue;
        vm_address_t a = (vm_address_t)p; vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t mo = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&bi, &cnt, &mo) != KERN_SUCCESS) continue;
        if (a > (vm_address_t)p || !(bi.protection & VM_PROT_READ)) continue;
        size_t ext = (size_t)((a + rsz) - (vm_address_t)p);
        if (ext < surf_sz / 2) continue;   // must be ~surface-sized
        int is_surf = 0;
        @try { if (CFGetTypeID(p) == IOSurfaceGetTypeID()) is_surf = 1; } @catch (__unused NSException *e) {}
        void *sample = p; size_t cap = ext;
        if (is_surf) { @try { IOSurfaceLock((IOSurfaceRef)p, 0x1, NULL);
            void *b = IOSurfaceGetBaseAddress((IOSurfaceRef)p); if (b) { sample = b; cap = surf_sz; } } @catch (__unused NSException *e) {} }
        if (cap > surf_sz) cap = surf_sz;
        size_t nz=0,samp=0;
        for (size_t o=0;o+4<=cap;o+=997*4){ if(*(volatile uint32_t*)((char*)sample+o)&0xffffff)nz++; samp++; }
        double pct = samp?100.0*nz/samp:0.0;
        fprintf(stderr, "#### IMPL-SCAN impl+%#zx ptr=%p ext=%#zx is_surf=%d content=%.1f%%\n",
                off, p, ext, is_surf, pct);
    }
    fprintf(stderr, "#### IMPL-SCAN end\n");
}
// ── 2026-06-23 TEXTURE-WALL FIX: IOSurface-backed compose dest ──
// RE-confirmed: the macOS compose dest is a PLAIN render target (no IOSurface) →
// GPU renders into a private backing, the scanout IOSurface stays empty. This helper
// builds (and caches by w×h×pf) an IOSurface-backed texture matching `orig`, so the
// StartComposite hook can SWAP it in → the GPU renders into readable IOSurface memory
// (the texture's GPU VA impl+0x40 becomes the IOSurface's). Keeps `orig`'s pixelFormat
// so the compositor's render-pipeline color-attachment format still matches. Gated by
// the caller (/tmp/macws_dest_iosurf); nil on failure → caller keeps the plain dest.
id macws_make_iosurf_dest(id orig) {
    if (!orig) return nil;
    @try {
        id<MTLTexture> t0 = (id<MTLTexture>)orig;
        NSUInteger w = [t0 width], h = [t0 height], pf = [t0 pixelFormat], usage = [t0 usage];
        id<MTLDevice> dev = [t0 device];
        if (!dev || w == 0 || h == 0) return nil;
        // SCOPE: ONLY the macOS virtual-display dest (w 1900..2300, e.g. 2000x1456).
        // Swapping the 2388-wide iOS-panel/strip dests crashed WS; swapping the small
        // (<1900) sub-composite dests disrupted the composite chain (the 2000x1456
        // macOS composite then didn't run). RE-confirmed via DEST-TRACE: the macOS app
        // content lives in the 2000x1456 surface that reaches WSCDcreate.
        if (w < 1900 || w >= 2300) return nil;
        // Skip only OUR OWN swapped textures on re-entry (prevents chaining/churn).
        // Do NOT skip "has an IOSurface" — the plain dest has a SEPARATE scanout
        // IOSurface at +0xa0 yet still renders into a private backing, so it must be
        // swapped. Track our created textures in a set and skip exactly those.
        static NSMutableSet *mine = nil;
        static dispatch_once_t mineOnce; dispatch_once(&mineOnce, ^{ mine = [NSMutableSet new]; });
        @synchronized(mine) { if ([mine containsObject:orig]) return orig; }
        static NSMutableDictionary *cache = nil;
        static dispatch_once_t once; dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
        NSString *key = [NSString stringWithFormat:@"%lux%lu-%lu", (unsigned long)w, (unsigned long)h, (unsigned long)pf];
        id<MTLTexture> hit = nil;
        @synchronized(cache) { hit = cache[key]; }
        if (hit) return hit;
        IOSurfaceRef surf = NULL;
        // 2a: prefer SkyLight's targetable-IOSurface helper (GPU-render metadata AGX
        // needs for aliasing) over plain IOSurfaceCreate. Raw addr resolved in the
        // SkyLight install; PAC-sign (arm64e) before the indirect call.
        extern void *g_ws_targetable_iosurf_raw;
        if (g_ws_targetable_iosurf_raw) {
#if __has_feature(ptrauth_calls)
            IOSurfaceRef (*tfn)(int, int, int, unsigned long long, const char *) =
                __builtin_ptrauth_sign_unauthenticated(g_ws_targetable_iosurf_raw, 0, 0);
#else
            IOSurfaceRef (*tfn)(int, int, int, unsigned long long, const char *) =
                (IOSurfaceRef (*)(int, int, int, unsigned long long, const char *))g_ws_targetable_iosurf_raw;
#endif
            @try { surf = tfn((int)w, (int)h, 4 /*'BGRA'*/, 0, "MacWSDest"); }
            @catch (__unused NSException *e) { surf = NULL; }
            if (surf) fprintf(stderr, "#### DEST-SWAP targetable IOSurface %lux%lu -> %p\n",
                (unsigned long)w, (unsigned long)h, (void *)surf);
        }
        if (!surf) {
            NSDictionary *props = @{
                @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
                @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
                @"IOSurfaceCacheMode": @1792, @"IOSurfaceMapCacheAttribute": @0,
                @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
            };
            surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (!surf) {
                NSDictionary *bp = @{ @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
                    @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA') };
                surf = IOSurfaceCreate((__bridge CFDictionaryRef)bp);
            }
        }
        if (!surf) return nil;
        MTLTextureDescriptor *d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pf width:w height:h mipmapped:NO];
        d.usage = usage; d.storageMode = MTLStorageModeShared;
        id<MTLTexture> nt = nil;
        @try { nt = [dev newTextureWithDescriptor:d iosurface:surf plane:0]; }
        @catch (__unused NSException *e) { nt = nil; }
        CFRelease(surf);   // texture holds its own ref
        if (nt) {
            @synchronized(cache) { cache[key] = nt; }
            @synchronized(mine) { [mine addObject:nt]; }
            fprintf(stderr, "#### DEST-SWAP made IOSurface-backed dest %lux%lu pf=%lu -> %p\n",
                (unsigned long)w, (unsigned long)h, (unsigned long)pf, (void *)nt);
        } else {
            fprintf(stderr, "#### DEST-SWAP iosurface wrap nil for %lux%lu pf=%lu\n",
                (unsigned long)w, (unsigned long)h, (unsigned long)pf);
        }
        return nt;
    } @catch (__unused NSException *e) { return nil; }
}
// Targetable IOSurface for the type-2 dest redirect (cached by w×h). g_dest_iosurf =
// the latest one, so the grab can read the type-2 dest's content directly.
IOSurfaceRef g_dest_iosurf = NULL;
IOSurfaceRef macws_dest_targetable_iosurf(int w, int h) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once; dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSString *key = [NSString stringWithFormat:@"%dx%d", w, h];
    @synchronized(cache) { NSValue *v = cache[key]; if (v) { g_dest_iosurf = (IOSurfaceRef)[v pointerValue]; return g_dest_iosurf; } }
    IOSurfaceRef surf = NULL;
    extern void *g_ws_targetable_iosurf_raw;
    if (g_ws_targetable_iosurf_raw) {
#if __has_feature(ptrauth_calls)
        IOSurfaceRef (*tfn)(int, int, int, unsigned long long, const char *) =
            __builtin_ptrauth_sign_unauthenticated(g_ws_targetable_iosurf_raw, 0, 0);
#else
        IOSurfaceRef (*tfn)(int, int, int, unsigned long long, const char *) =
            (IOSurfaceRef (*)(int, int, int, unsigned long long, const char *))g_ws_targetable_iosurf_raw;
#endif
        @try { surf = tfn(w, h, 4 /*'BGRA'*/, 0, "MacWSDestIOSurf"); } @catch (__unused NSException *e) { surf = NULL; }
    }
    if (!surf) {
        NSDictionary *p = @{ @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
            @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA') };
        surf = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    }
    if (surf) { @synchronized(cache) { cache[key] = [NSValue valueWithPointer:surf]; } g_dest_iosurf = surf; }
    return surf;
}
// DEST-PATH TRACE (gated /tmp/macws_dest_trace): log every macOS-sized (w>=1900)
// texture seen at each composite entry point, to map WHERE the 2000x1456 macOS
// virtual-display dest is created/used (its composite path is intermittent across
// the DS / WSCD-create / WSCD-start / MTLTex hooks). Read-only.
void macws_dest_trace(const char *site, id tex) {
    if (!tex || access("/tmp/macws_dest_trace", F_OK) != 0) return;
    @try {
        NSUInteger w = [tex width], h = [tex height], pf = [tex pixelFormat];
        if (w < 1900) return;
        IOSurfaceRef ios = NULL;
        if ([tex respondsToSelector:@selector(iosurface)]) {
            typedef IOSurfaceRef (*f)(id, SEL);
            ios = ((f)objc_msgSend)(tex, @selector(iosurface));
        }
        static _Atomic int n = 0;
        if (atomic_fetch_add(&n, 1) < 240)
            fprintf(stderr, "#### DEST-TRACE [%s] %lux%lu pf=%lu iosurf=%p tex=%p\n",
                site, (unsigned long)w, (unsigned long)h, (unsigned long)pf,
                (void *)ios, (void *)tex);
    } @catch (__unused NSException *e) {}
}
// 2b PROBE/FIX (gated /tmp/macws_2b): the macOS dest is IOSurface-backed (iosurf=SET) but its
// IOSurface is EMPTY — the GPU renders into a separate backing. AGX::Texture GPU render-target VA
// = impl+0x40 (getGPUVirtualAddress); impl=*(tex+0x208); CPU base = impl+0x130. Compare the dest's
// impl+0x40 to a REFERENCE texture freshly created from the SAME IOSurface: DIFFER => dest has a
// private backing not aliasing the IOSurface (patchable); same => IOSurface IS the backing (empty =
// no render, a different problem). When /tmp/macws_2b_fix exists AND they differ, set the dest's
// impl+0x40 := ref_va so the GPU renders into the IOSurface-aliased VA (re-push handled by the next
// frame's bind; texBaseAddressesUpdated re-push is a follow-up if the bare set doesn't take).
void macws_2b_alias_dest(id texture) {
    if (!texture || access("/tmp/macws_2b", F_OK) != 0) return;
    @try {
        NSUInteger w = [texture width], h = [texture height];
        if (w < 1900 || w >= 2300) return;   // macOS virtual-display dest only
        static _Atomic int n = 0;
        if (atomic_fetch_add(&n, 1) >= 6) return;   // limit AFTER the dims filter
        void *impl = *(void **)((char *)(__bridge void *)texture + 0x208);
        if (!impl) return;
        uint64_t dest_va = *(volatile uint64_t *)((char *)impl + 0x40);
        uint64_t cpu_base = *(volatile uint64_t *)((char *)impl + 0x130);
        typedef IOSurfaceRef (*iosf_t)(id, SEL);
        IOSurfaceRef ios = [texture respondsToSelector:@selector(iosurface)]
            ? ((iosf_t)objc_msgSend)(texture, @selector(iosurface)) : NULL;
        uint64_t ref_va = 0;
        if (ios) {
            id<MTLDevice> dev = [texture device];
            MTLTextureDescriptor *d = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:[texture pixelFormat] width:w height:h mipmapped:NO];
            d.usage = [texture usage]; d.storageMode = MTLStorageModeShared;
            id ref = nil;
            @try { ref = [dev newTextureWithDescriptor:d iosurface:ios plane:0]; } @catch (__unused NSException *e) {}
            void *rimpl = ref ? *(void **)((char *)(__bridge void *)ref + 0x208) : NULL;
            if (rimpl) ref_va = *(volatile uint64_t *)((char *)rimpl + 0x40);
        }
        int differ = (ref_va && ref_va != dest_va);
        fprintf(stderr, "#### 2B dest %lux%lu impl=%p +0x40=%#llx +0x130=%#llx ios=%p ref+0x40=%#llx %s\n",
            (unsigned long)w, (unsigned long)h, impl, dest_va, cpu_base, (void *)ios, ref_va,
            differ ? "DIFFER" : "same");
        if (differ && access("/tmp/macws_2b_fix", F_OK) == 0) {
            *(volatile uint64_t *)((char *)impl + 0x40) = ref_va;
            fprintf(stderr, "#### 2B FIX set dest impl+0x40 := ref_va %#llx\n", ref_va);
        }
    } @catch (__unused NSException *e) {}
}
static _Atomic int g_grab_busy = 0;
void macws_grab_composite(id<MTLTexture> tex) {
    // NEWBUF-TEST (self-contained, gated /tmp/macws_newbuf_test, one-shot): THE decisive question —
    // does -[device newBufferWithIOSurface:] yield a REAL GPU VA that ALIASES the IOSurface in the
    // chroot? Create our own 256x256 BGRA IOSurface, make a buffer from it, GPU fillBuffer 0xAB,
    // then read the IOSurface CPU base. 0xABABABAB => buffer truly aliases the IOSurface (the
    // texture-RT-via-buffer fix is viable). Unchanged => kernel doesn't alias IOSurface GPU
    // mappings from the chroot at all (userland fix dead; only full-Metal-proxy left).
    if (access("/tmp/macws_newbuf_test", F_OK) == 0) {
        static dispatch_once_t nbt_once;
        dispatch_once(&nbt_once, ^{
            @try {
                NSDictionary *props = @{ (id)kIOSurfaceWidth:@256, (id)kIOSurfaceHeight:@256,
                    (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@(256*4),
                    (id)kIOSurfacePixelFormat:@(0x42475241) /*'BGRA'*/ };
                IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
                id dev = MTLCreateSystemDefaultDevice();
                uint64_t va = 0; id buf = nil;
                if (s && dev) {
                    typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                    buf = ((nbi_t)objc_msgSend)(dev, sel_registerName("newBufferWithIOSurface:"), s);
                    if (buf) { typedef uint64_t (*ga_t)(id, SEL); va = ((ga_t)objc_msgSend)(buf, sel_registerName("gpuAddress")); }
                }
                if (s) { IOSurfaceLock(s,0,NULL); uint32_t *ip=(uint32_t*)IOSurfaceGetBaseAddress(s); if(ip){ip[0]=ip[1]=0x55555555;} IOSurfaceUnlock(s,0,NULL); }
                if (buf && dev) {
                    id q=[dev newCommandQueue];
                    id cb=((id(*)(id,SEL))objc_msgSend)(q,sel_registerName("commandBuffer"));
                    id be=((id(*)(id,SEL))objc_msgSend)(cb,sel_registerName("blitCommandEncoder"));
                    unsigned long blen=((unsigned long(*)(id,SEL))objc_msgSend)(buf,sel_registerName("length"));
                    unsigned long fl=blen<0x1000?blen:0x1000;
                    ((void(*)(id,SEL,id,NSRange,uint8_t))objc_msgSend)(be,sel_registerName("fillBuffer:range:value:"),buf,NSMakeRange(0,fl),0xAB);
                    ((void(*)(id,SEL))objc_msgSend)(be,sel_registerName("endEncoding"));
                    ((void(*)(id,SEL))objc_msgSend)(cb,sel_registerName("commit"));
                    ((void(*)(id,SEL))objc_msgSend)(cb,sel_registerName("waitUntilCompleted"));
                    long status=((long(*)(id,SEL))objc_msgSend)(cb,sel_registerName("status"));
                    uint32_t v0=0,v1=0;
                    IOSurfaceLock(s,0x1,NULL); uint32_t *ip=(uint32_t*)IOSurfaceGetBaseAddress(s); if(ip){v0=ip[0];v1=ip[1];} IOSurfaceUnlock(s,0x1,NULL);
                    fprintf(stderr,"#### NEWBUF-TEST gpuAddress=%#llx cb.status=%ld buf.len=%#lx ios[0,1]=%08x,%08x VERDICT=%s\n",
                        va,status,blen,v0,v1,
                        (v0==0xABABABAB)?"BUFFER-ALIASES-IOSURFACE ✓ (fix viable)"
                            :(status==5?"GPU-OP-ERRORED (inconclusive)":"IOSURFACE-NOT-ALIASED ✗ (kernel denies alias)"));
                } else fprintf(stderr,"#### NEWBUF-TEST setup failed s=%p dev=%p buf=%p gpuAddress=%#llx\n",(void*)s,(void*)dev,(void*)buf,va);
            } @catch(__unused NSException *e){ fprintf(stderr,"#### NEWBUF-TEST exception\n"); }
        });
    }
    // BLIT-TEST (Asahi Scheme B, gated /tmp/macws_blit_test, one-shot): read the composite dest
    // TEXTURE via copyFromTexture:toBuffer: — Metal decompresses+detiles into a LINEAR Shared
    // buffer. This reads where the GPU actually wrote (the texture's RT backing impl+0x40), NOT
    // the empty +0xa0 IOSurface the grab reads — so it bypasses BOTH the coherence wall and the
    // compression/AUX. Decisive: if status=Completed + nonzero, the texture HAS content + Metal
    // gave us a clean linear copy (the whole problem solved); writes /tmp/macws_blit.raw.
    if (tex && access("/tmp/macws_blit_test", F_OK) == 0) {
        static dispatch_once_t blt;
        size_t bw = [tex width], bh = [tex height]; unsigned long bpf = (unsigned long)[tex pixelFormat];
        if ((size_t)bw * bh >= 1000000 && (bpf == 80 || bpf == 550 || bpf == 552)) {
            dispatch_once(&blt, ^{
                unlink("/tmp/macws_blit_test");   // one-shot: never re-run even if WS restarts
                @try {
                    id<MTLDevice> dev = [tex device];
                    size_t bbpr = ((bw * 4 + 255) / 256) * 256, blen = bbpr * bh;  // 256-align for copyToBuffer
                    // newBufferWithLength gives gpuAddr=0 (no GPU resource) → texture-from-it is nil. Use a
                    // fresh LINEAR IOSurface + newBufferWithIOSurface (registers via sel=0x9 → real VA); read the IOSurface.
                    NSDictionary *sp = @{ (id)kIOSurfaceWidth:@((long)bw), (id)kIOSurfaceHeight:@((long)bh),
                        (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@((long)bbpr),
                        (id)kIOSurfacePixelFormat:@(0x42475241) /*BGRA*/ };
                    IOSurfaceRef osurf = IOSurfaceCreate((__bridge CFDictionaryRef)sp);
                    typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                    id<MTLBuffer> buf = osurf ? ((nbi_t)objc_msgSend)(dev, sel_registerName("newBufferWithIOSurface:"), osurf) : nil;
                    { uint64_t bva = 0; if (buf) { typedef uint64_t(*ga_t)(id,SEL); bva = ((ga_t)objc_msgSend)(buf, sel_registerName("gpuAddress")); }
                      fprintf(stderr, "#### BLIT-TEST destbuf osurf=%p buf=%p gpuAddr=%#llx\n", (void *)osurf, (void *)buf, bva); }
                    // AGXG13GFamilyBlitContext has NO copyFromTexture:toBuffer: (unrecognized selector).
                    // Use copyFromTexture:toTexture: into a BUFFER-BACKED LINEAR Shared texture (Asahi staging-blit):
                    // the blit decompresses+detiles into the linear texture, whose backing IS our CPU-readable buffer.
                    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)bpf width:bw height:bh mipmapped:NO];
                    dd.usage = MTLTextureUsageShaderRead; dd.storageMode = MTLStorageModeShared;
                    id<MTLTexture> lintex = buf ? [buf newTextureWithDescriptor:dd offset:0 bytesPerRow:bbpr] : nil;
                    if (!lintex) {
                        fprintf(stderr, "#### BLIT-TEST lintex nil: buf.len=%lu need(off0+%zu) bbpr=%zu pf=%lu — diagnosing...\n",
                            (unsigned long)[buf length], blen, bbpr, bpf);
                        id<MTLBuffer> pbuf = [dev newBufferWithLength:blen options:MTLResourceStorageModePrivate];
                        id<MTLTexture> plt = pbuf ? [pbuf newTextureWithDescriptor:dd offset:0 bytesPerRow:bbpr] : nil;
                        fprintf(stderr, "#### BLIT-TEST Private-buf lintex=%p pbuf=%p (len=%lu) => %s\n", (void *)plt, (void *)pbuf,
                            (unsigned long)[pbuf length], plt ? "PRIVATE WORKS (storageMode IS the gate)" : "Private ALSO nil (downstream: size/compression/resource)");
                        return;
                    }
                    id<MTLCommandQueue> q = [dev newCommandQueue];
                    id<MTLCommandBuffer> cb = [q commandBuffer];
                    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                    [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                         sourceSize:MTLSizeMake(bw,bh,1) toTexture:lintex destinationSlice:0 destinationLevel:0
                         destinationOrigin:MTLOriginMake(0,0,0)];
                    [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
                    long st = (long)[cb status]; id err = [cb error]; void *bc = osurf ? IOSurfaceGetBaseAddress(osurf) : NULL;
                    size_t nz = 0, sm = 0;
                    if (bc && st == 4) for (size_t i = 0; i + 4 <= blen; i += 997 * 4) { sm++; if (*(uint32_t *)((char *)bc + i) & 0xffffff) nz++; }
                    fprintf(stderr, "#### BLIT-TEST %zux%zu pf=%lu status=%ld err=%s contents=%p nonzero=%.1f%%\n",
                        bw, bh, bpf, st, err ? [[err localizedDescription] UTF8String] : "none", bc, sm ? 100.0 * nz / sm : -1.0);
                    if (st == 4 && bc) {
                        FILE *f = fopen("/tmp/macws_blit.raw", "wb");
                        if (f) { uint32_t hd[7] = {0x47524232u, (uint32_t)bw, (uint32_t)bh, (uint32_t)bpf, 0xD0, (uint32_t)blen, (uint32_t)bbpr};
                                 fwrite(hd, 4, 7, f); fwrite(bc, 1, blen, f); fclose(f);
                                 fprintf(stderr, "#### BLIT-TEST wrote /tmp/macws_blit.raw (%zu bytes)\n", blen); }
                    }
                } @catch (NSException *e) { fprintf(stderr, "#### BLIT-TEST exception: %s\n", [[e reason] UTF8String] ?: "?"); }
            });
        }
    }
    // WSQ-TEST (gated /tmp/macws_wsq_test, one-shot, BG thread): does MY command buffer submit on
    // WS's OWN compositor queue (g_ws_cmdq, captured at newCommandQueue)? This answers "why only WS
    // submits". Part A = trivial fillBuffer of my own buffer (no WS resources, safe). Part B = the
    // Scheme-B blit of the composite dest (only if A succeeds). Runs on a detached thread so the
    // waitUntilCompleted does NOT block WS's render thread (which would deadlock the in-flight composite).
    if (tex && g_ws_cmdq && access("/tmp/macws_wsq_test", F_OK) == 0) {
        static dispatch_once_t wsqo;
        size_t tw_ = [tex width], th_ = [tex height]; unsigned long tpf_ = (unsigned long)[tex pixelFormat];
        if ((size_t)tw_ * th_ >= 1000000 && (tpf_ == 80 || tpf_ == 550 || tpf_ == 552)) {
            id texR = tex;  // ARC retains into the block to keep the dest alive for the bg thread
            dispatch_once(&wsqo, ^{
                unlink("/tmp/macws_wsq_test");
                [NSThread detachNewThreadWithBlock:^{
                  @try {
                    id<MTLTexture> t = texR; id<MTLDevice> dev = [t device]; id<MTLCommandQueue> wq = g_ws_cmdq;
                    // Part A: trivial fillBuffer on WS's queue (no WS resources)
                    id<MTLBuffer> tb = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
                    id<MTLCommandBuffer> cbA = [wq commandBuffer];
                    id<MTLBlitCommandEncoder> blA = [cbA blitCommandEncoder];
                    [blA fillBuffer:tb range:NSMakeRange(0, 65536) value:0xAB];
                    [blA endEncoding]; [cbA commit]; [cbA waitUntilCompleted];
                    long sA = (long)[cbA status]; id eA = [cbA error]; uint8_t fb = ((uint8_t *)[tb contents])[0];
                    fprintf(stderr, "#### WSQ-TEST A(fillBuffer on WS queue) status=%ld err=%s firstByte=0x%02x => %s\n",
                        sA, eA ? [[eA localizedDescription] UTF8String] : "none", fb,
                        (sA == 4 && fb == 0xAB) ? "WS-QUEUE SUBMITS MY CB (wall is per-queue config!)" : "still fails on WS queue (deeper than queue)");
                    // Part C: render-encoder CLEAR on WS's queue (no shader) — does the RENDER encoder
                    // submit while the BLIT encoder (A) failed 0x103? If yes, blit-encoder is the broken path.
                    {
                        size_t bbpr = ((tw_ * 4 + 255) / 256) * 256;
                        NSDictionary *sp = @{ (id)kIOSurfaceWidth:@((long)tw_), (id)kIOSurfaceHeight:@((long)th_),
                            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@((long)bbpr), (id)kIOSurfacePixelFormat:@(0x42475241) };
                        IOSurfaceRef os2 = IOSurfaceCreate((__bridge CFDictionaryRef)sp);
                        typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                        id<MTLBuffer> buf2 = os2 ? ((nbi_t)objc_msgSend)(dev, sel_registerName("newBufferWithIOSurface:"), os2) : nil;
                        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)80 width:tw_ height:th_ mipmapped:NO];
                        dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModeShared;
                        id<MTLTexture> rt = buf2 ? [buf2 newTextureWithDescriptor:dd offset:0 bytesPerRow:bbpr] : nil;
                        if (rt) {
                            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                            rpd.colorAttachments[0].texture = rt;
                            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0); // blue
                            id<MTLCommandBuffer> cbC = [wq commandBuffer];
                            id<MTLRenderCommandEncoder> rce = [cbC renderCommandEncoderWithDescriptor:rpd];
                            [rce endEncoding]; [cbC commit]; [cbC waitUntilCompleted];
                            long sC = (long)[cbC status]; id eC = [cbC error];
                            void *b2 = os2 ? IOSurfaceGetBaseAddress(os2) : NULL; uint32_t px = b2 ? *(uint32_t *)b2 : 0;
                            fprintf(stderr, "#### WSQ-TEST C(render-clear on WS queue) status=%ld err=%s px0=0x%08x => %s\n",
                                sC, eC ? [[eC localizedDescription] UTF8String] : "none", px,
                                sC == 4 ? "RENDER SUBMITS (blit-encoder is the broken path!)" : "render ALSO fails (deeper than encoder)");
                        } else fprintf(stderr, "#### WSQ-TEST C rt nil (buf2=%p)\n", (void *)buf2);
                    }
                  } @catch (NSException *e) { fprintf(stderr, "#### WSQ-TEST exception: %s\n", [[e reason] UTF8String] ?: "?"); }
                }];
            });
        }
    }
    // BINDFIX-RECHECK (gated /tmp/macws_bindfix): re-read the LIVE composite dest's impl+0x40
    // AFTER frames executed. Still realVA => no encoder re-clobber (empty IOSurface = no-alias,
    // kernel-deep). 0/changed => encoder re-clobbers (durability fix = wrapper+0x48). Decisive.
    if (tex && access("/tmp/macws_bindfix", F_OK) == 0) {
        @try {
            size_t tw=[tex width], th=[tex height];
            if ((size_t)tw*th >= 1000000) {
                void *impl = *(void**)((char*)(__bridge void*)tex + macws_tex_impl_off());
                if ((uintptr_t)impl > 0x1000) {
                    static int rc=0; if (rc++ < 8)
                        fprintf(stderr,"#### BINDFIX-RECHECK dest %zux%zu impl+0x40=%#llx\n", tw,th,*(uint64_t*)((char*)impl+0x40));
                }
            }
        } @catch(__unused NSException*e){}
    }
    // DEST-IOSURF-CONTENT (gated /tmp/macws_wscd_iosurf): probe the type-2 dest's IOSurface
    // (g_dest_iosurf) for GPU-rendered content. Non-zero => the WithIOSurface redirect made
    // the GPU render into the readable IOSurface (THE FIX worked).
    if (g_dest_iosurf && access("/tmp/macws_wscd_iosurf", F_OK) == 0) {
        @try {
            // NEWBUF-PROBE (one-shot, decisive): does newBufferWithIOSurface yield a REAL GPU VA
            // in the chroot, or also the 0xeeee0000 placeholder? If real -> the IOSurface CAN be
            // GPU-bound and the bind-substitution fix is viable. If placeholder/0 -> the kernel
            // assigns no VA for IOSurface resources from the chroot -> IOSurface-RT dead at kernel.
            static dispatch_once_t nbp_once;
            dispatch_once(&nbp_once, ^{
                id dev = MTLCreateSystemDefaultDevice();
                uint64_t va = 0; id buf = nil;
                if (dev) {
                    typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                    buf = ((nbi_t)objc_msgSend)(dev, sel_registerName("newBufferWithIOSurface:"), g_dest_iosurf);
                    if (buf) { typedef uint64_t (*ga_t)(id, SEL); va = ((ga_t)objc_msgSend)(buf, sel_registerName("gpuAddress")); }
                }
                fprintf(stderr, "#### NEWBUF-PROBE dev=%s ios=%p buf=%p gpuAddress=%#llx\n",
                    dev ? class_getName([dev class]) : "nil", (void *)g_dest_iosurf, (void *)buf, va);
                // NEWBUF-FILL (decisive): GPU-blit fillBuffer the IOSurface-backed buffer with 0xAB,
                // then read the IOSurface CPU base. If it reads 0xABABABAB → the buffer TRULY aliases
                // the IOSurface (kernel mapping reaches where the chroot GPU writes) → only the texture
                // render-target path is broken (route through buffer). If it stays unchanged → the
                // chroot's IOSurface GPU mapping does NOT alias at all (kernel/vmspace issue).
                @try {
                    if (buf && dev) {
                        IOSurfaceLock(g_dest_iosurf, 0, NULL);
                        uint32_t *ip = (uint32_t *)IOSurfaceGetBaseAddress(g_dest_iosurf);
                        if (ip) { ip[0] = 0x55555555; ip[1] = 0x55555555; }
                        IOSurfaceUnlock(g_dest_iosurf, 0, NULL);
                        id q = [dev newCommandQueue];
                        typedef id (*cb_t)(id, SEL); id cb = ((cb_t)objc_msgSend)(q, sel_registerName("commandBuffer"));
                        id be = ((cb_t)objc_msgSend)(cb, sel_registerName("blitCommandEncoder"));
                        typedef unsigned long (*len_t)(id, SEL); unsigned long blen = ((len_t)objc_msgSend)(buf, sel_registerName("length"));
                        unsigned long fillLen = blen < 0x10000 ? blen : 0x10000;
                        typedef void (*fb_t)(id, SEL, id, NSRange, uint8_t);
                        ((fb_t)objc_msgSend)(be, sel_registerName("fillBuffer:range:value:"), buf, NSMakeRange(0, fillLen), 0xAB);
                        typedef void (*v_t)(id, SEL); ((v_t)objc_msgSend)(be, sel_registerName("endEncoding"));
                        ((v_t)objc_msgSend)(cb, sel_registerName("commit"));
                        ((v_t)objc_msgSend)(cb, sel_registerName("waitUntilCompleted"));
                        typedef long (*st_t)(id, SEL); long status = ((st_t)objc_msgSend)(cb, sel_registerName("status"));
                        id err = ((id (*)(id, SEL))objc_msgSend)(cb, sel_registerName("error"));
                        const char *errs = "none";
                        if (err) { id desc = ((id (*)(id, SEL))objc_msgSend)(err, sel_registerName("localizedDescription")); if (desc) errs = [desc UTF8String]; }
                        IOSurfaceLock(g_dest_iosurf, 0x1, NULL);
                        uint32_t v0 = ip ? ip[0] : 0, v1 = ip ? ip[1] : 0;
                        IOSurfaceUnlock(g_dest_iosurf, 0x1, NULL);
                        fprintf(stderr, "#### NEWBUF-FILL cb.status=%ld err=%s buf.len=%#lx ios[0,1]=%08x,%08x  VERDICT=%s\n",
                            status, errs, blen, v0, v1,
                            (v0 == 0xABABABAB) ? "BUFFER-ALIASES-IOSURFACE ✓ (only texture path broken)"
                                               : (status == 5 ? "GPU-OP-ERRORED (inconclusive — chroot cmdbuf fails)"
                                                              : "IOSURFACE-NOT-ALIASED ✗ (kernel/vmspace mapping issue)"));
                    }
                } @catch (__unused NSException *e) { fprintf(stderr, "#### NEWBUF-FILL exception\n"); }
            });
            IOSurfaceLock(g_dest_iosurf, 0x1 /*readonly*/, NULL);
            void *b = IOSurfaceGetBaseAddress(g_dest_iosurf);
            size_t sz = IOSurfaceGetAllocSize(g_dest_iosurf);
            if (b && sz) {
                size_t nz = 0, samp = 0;
                for (size_t o = 0; o + 4 <= sz; o += 997 * 4) { if (*(volatile uint32_t *)((char *)b + o) & 0xffffff) nz++; samp++; }
                static _Atomic int dn = 0;
                if (atomic_fetch_add(&dn, 1) < 12)
                    fprintf(stderr, "#### DEST-IOSURF-CONTENT base=%p sz=%#zx nonzero=%.1f%%\n",
                        b, sz, samp ? 100.0 * nz / samp : 0.0);
            }
        } @catch (__unused NSException *e) {}
    }
    if (!tex || access("/tmp/macws_grab_png", F_OK) != 0) return;
    size_t w = [tex width], h = [tex height];
    unsigned long pf = (unsigned long)[tex pixelFormat];
    if ((size_t)w * h < 1000000) return;     // full-screen surfaces only
    if (pf != 70 && pf != 80 && pf != 550) return;
    int want_capture = (access("/tmp/macws_grab_now", F_OK) == 0);
    // Serialize: one capture/probe at a time across composite threads.
    if (atomic_exchange(&g_grab_busy, 1)) return;
    @try {
        // The hook fires right after StartComposite returns — this frame's layer
        // draws + GPU exec happen AFTER, async. So `tex` (current dest) is read
        // PRE-draw → stale/uninit. To capture a GPU-COMPLETE frame, defer: keep a
        // ring of recent dest texs and snapshot the OLDEST (several composites of
        // slack ⇒ its render cmdbuf has long since completed). RE-confirmed the
        // +0xa0 backing read is linear [[detile-read-correct-composite-empty]].
        static NSMutableArray *ring = nil;
        if (!ring) ring = [[NSMutableArray alloc] init];
        // helper to probe one tex (content% of its +0xa0 backing)
        uint8_t cl = 0xff; size_t cext = 0;
        void *cbk = macws_tex_backing(tex, &cl, &cext);
        double cur_pct = -1.0;
        if (cbk) {
            size_t ccopy = w*h*4; if (cext < ccopy) ccopy = cext;
            size_t nz=0,samp=0;
            for (size_t o=0;o+4<=ccopy;o+=997*4){ if(*(volatile uint32_t*)((char*)cbk+o)&0xffffff)nz++; samp++; }
            cur_pct = samp?100.0*nz/samp:0.0;
        }
        static _Atomic int probe_n = 0;
        int pn = atomic_fetch_add(&probe_n, 1);
        if (pn < 40 || want_capture)
            fprintf(stderr, "#### GRAB-PROBE #%d %zux%zu pf=%lu layout=%d cur_content=%.1f%% ringN=%lu%s\n",
                pn, w, h, pf, cl, cur_pct, (unsigned long)[ring count], want_capture ? " [CAPTURE]" : "");
        // push current dest into the ring (cap 5)
        [ring addObject:tex];
        if ([ring count] > 5) [ring removeObjectAtIndex:0];
        // (B) capture on demand — pick the ring tex with the most CONTENT
        // (sample each backing's nonzero%; the empty pf=80 capture surfaces and
        // partial swapchain buffers lose to the real composited pf=550 display
        // surface). 2026-06-22: backing is now IOSurface-resolved, so content%
        // is meaningful.
        if (want_capture && [ring count] >= 1) {
            int detile_on = (access("/tmp/macws_detile", F_OK) == 0);
            id<MTLTexture> dtex = nil; double best_pct = -1.0, best_score = -1.0;
            for (id<MTLTexture> rt in ring) {
                uint8_t rl=0xff; size_t re=0;
                void *rb = macws_tex_backing(rt,&rl,&re);
                size_t rw=[rt width], rh=[rt height];
                unsigned long rpf=(unsigned long)[rt pixelFormat];
                double pct = 0.0;
                if (rb && re >= 0x10000) {
                    size_t rcopy = rw*rh*4; if (re < rcopy) rcopy = re;
                    size_t nz=0,samp=0;
                    for (size_t o=0;o+4<=rcopy;o+=997*4){ if(*(volatile uint32_t*)((char*)rb+o)&0xffffff)nz++; samp++; }
                    pct = samp?100.0*nz/samp:0.0;
                }
                // ALSO score the RAW +0xa0 backing (coexist content lands there,
                // not the IOSurface) — gate must pass if EITHER has content.
                size_t rre=0; void *rraw = macws_tex_raw_backing(rt,&rre);
                if (rraw && rraw!=rb && rre>=0x10000) {
                    size_t rc2=rw*rh*4; if(rre<rc2)rc2=rre;
                    size_t n2=0,s2=0;
                    for(size_t o=0;o+4<=rc2;o+=997*4){ if(*(volatile uint32_t*)((char*)rraw+o)&0xffffff)n2++; s2++; }
                    double rawp=s2?100.0*n2/s2:0.0;
                    if (rawp>pct) pct=rawp;
                }
                // When de-tiling, bias toward de-tileable BGRA8/RGBA8 (pf=80/70)
                // surfaces — pf=550 can't be blit-detiled. Only if they carry content.
                double score = pct;
                if (detile_on && (rpf==80||rpf==70) && pct>=5.0) score += 1000.0;
                if (score > best_score) { best_score=score; best_pct=pct; dtex=rt; }
            }
            // Don't consume the trigger on an all-empty frame — the real
            // composited display surface (pf=550, ~59% content) interleaves with
            // empty pf=80 capture surfaces across composite threads; wait for a
            // frame whose ring actually holds content (≥5%).
            // IMPL-SCAN: locate the separate GPU backing on the pf=550 dest even
            // when the readable IOSurface base is empty (runs before the 5% gate).
            if (access("/tmp/macws_impl_scan", F_OK) == 0) {
                for (id<MTLTexture> rt in ring) {
                    if ((unsigned long)[rt pixelFormat] == 550) {
                        macws_scan_impl_backings(rt, (size_t)[rt width]*[rt height]*4);
                        break;
                    }
                }
            }
            // When blit-detiling, capture the pf=550 dest's GPU backing even if its
            // IOSurface base reads empty — the blit reads GPU-PRIVATE content (the
            // decisive render-empty vs separate-backing test).
            if (detile_on) {
                for (id<MTLTexture> rt in ring)
                    if ((unsigned long)[rt pixelFormat] == 550) { dtex = rt; best_pct = 100.0; break; }
            }
            // 2B-POST (gated /tmp/macws_2b): read the ring's macOS-dest texture's
            // POST-RENDER VAs (ring tex is from a prior frame -> bound). BEFORE the
            // empty-content gate (the dest IOSurface is empty, so we'd never reach the
            // post-gate read). impl+0x40=GPU VA, +0x130=CPU base.
            if (access("/tmp/macws_2b", F_OK) == 0) {
                for (id<MTLTexture> rt in ring) {
                    NSUInteger rw = [rt width];
                    if (rw >= 1900 && rw < 2300) {
                        void *ri = *(void **)((char *)(__bridge void *)rt + 0x208);
                        if (ri) { static int pn; if (pn++ < 10)
                            fprintf(stderr, "#### 2B-POST %lux%lu impl=%p +0x40=%#llx +0x130=%#llx\n",
                                (unsigned long)rw, (unsigned long)[rt height], ri,
                                *(volatile uint64_t *)((char *)ri + 0x40),
                                *(volatile uint64_t *)((char *)ri + 0x130)); }
                        break;
                    }
                }
            }
            if (best_pct < 5.0) { atomic_store(&g_grab_busy, 0); return; }
            if (!dtex) dtex = [ring objectAtIndex:0];
            uint8_t layout = 0xff; size_t ext = 0;
            void *backing = macws_tex_backing(dtex, &layout, &ext);
            if (backing) {
                // 2B-POST (gated /tmp/macws_2b): read the POST-RENDER dest's GPU VA
                // (impl+0x40) + CPU base (impl+0x130) vs the resolved IOSurface base.
                // CPU==IOSURF => texture backing IS the IOSurface (aliased; empty = no
                // render). CPU!=IOSURF => separate backing (the coherence wall).
                if (access("/tmp/macws_2b", F_OK) == 0) {
                    void *dimpl = *(void **)((char *)(__bridge void *)dtex + 0x208);
                    if (dimpl) {
                        uint64_t va40 = *(volatile uint64_t *)((char *)dimpl + 0x40);
                        uint64_t va130 = *(volatile uint64_t *)((char *)dimpl + 0x130);
                        static int pn; if (pn++ < 10)
                            fprintf(stderr, "#### 2B-POST %lux%lu impl=%p +0x40=%#llx +0x130=%#llx iosurf_base=%p %s\n",
                                (unsigned long)[dtex width], (unsigned long)[dtex height], dimpl, va40, va130,
                                backing, (va130 == (uint64_t)backing) ? "CPU==IOSURF" : "CPU!=IOSURF");
                    }
                }
                size_t dw=[dtex width], dh=[dtex height];
                unsigned long dpf=(unsigned long)[dtex pixelFormat];
                size_t copy = dw*dh*4; if (ext < copy) copy = ext;
                if (copy > 64u*1024*1024) copy = 64u*1024*1024;
                // probe the deferred tex too
                size_t nz=0,samp=0;
                for (size_t o=0;o+4<=copy;o+=997*4){ if(*(volatile uint32_t*)((char*)backing+o)&0xffffff)nz++; samp++; }
                double dpct = samp?100.0*nz/samp:0.0;
                // COEXIST: content may be in the RAW +0xa0 backing (GPU writes
                // there; IOSurface stays empty). Compare and prefer whichever has
                // more content; capture its FULL extent.
                size_t rawext=0; void *raw=macws_tex_raw_backing(dtex,&rawext);
                double rawpct=-1.0;
                if (raw && raw!=backing && rawext>=0x10000) {
                    size_t rc=dw*dh*4; if(rawext<rc)rc=rawext;
                    size_t rn=0,rs=0;
                    for(size_t o=0;o+4<=rc;o+=997*4){ if(*(volatile uint32_t*)((char*)raw+o)&0xffffff)rn++; rs++; }
                    rawpct=rs?100.0*rn/rs:0.0;
                }
                fprintf(stderr,"#### GRAB-RAW: iosurf_pct=%.1f%% raw=%p rawpct=%.1f%% rawext=%#zx\n", dpct, raw, rawpct, rawext);
                if (rawpct > dpct + 1.0) {   // raw backing has the real content
                    backing = raw; ext = rawext;
                    copy = dw*dh*4; if (ext < copy) copy = ext;
                    if (copy > 64u*1024*1024) copy = 64u*1024*1024;
                    dpct = rawpct;
                    layout = 0xA0;  /* raw-backing marker */
                }
                // Try GPU-blit DE-TILE first → clean LINEAR pixels. On any failure
                // fall back to the raw (twiddled) IOSurface read so we always get
                // something. Marker layout=0xD0 = detiled-linear (offline stride=bpr),
                // else layout=the AGX layout (twiddled).
                size_t lin_bpr = 0, lin_sz = 0;
                uint8_t *lin = macws_blit_detile(dtex, &lin_bpr, &lin_sz);
                uint8_t *out = NULL; size_t out_sz = 0, out_bpr = 0; uint32_t out_layout = layout;
                if (lin && lin_sz) {
                    out = lin; out_sz = lin_sz; out_bpr = lin_bpr; out_layout = 0xD0;  /* detiled */
                } else {
                    out = (uint8_t *)malloc(copy);
                    if (out) { memcpy(out, backing, copy); out_sz = copy; out_bpr = dw*4; }
                }
                if (out) {
                    int fd = open("/tmp/macws_grab.raw", O_WRONLY | O_CREAT | O_TRUNC, 0644);
                    if (fd >= 0) {
                        // header (28B): magic 'GRB2', w, h, pf, layout, copied_bytes, bpr
                        uint32_t hd[7] = {0x47524232u, (uint32_t)dw, (uint32_t)dh,
                                          (uint32_t)dpf, out_layout, (uint32_t)out_sz, (uint32_t)out_bpr};
                        write(fd, hd, 28); write(fd, out, out_sz); fsync(fd); close(fd);
                    }
                    free(out);
                    unlink("/tmp/macws_grab_now");   // consume the trigger (re-armable)
                    fprintf(stderr, "#### GRAB-PNG: wrote %zux%zu pf=%lu layout=0x%x sz=%#zx bpr=%zu %s content=%.1f%% (cur=%.1f%%)\n",
                            dw, dh, dpf, out_layout, out_sz, out_bpr,
                            out_layout==0xD0?"DETILED-LINEAR":"twiddled-raw", dpct, cur_pct);
                }
            }
        }
    } @catch (NSException *e) {
        fprintf(stderr, "#### GRAB EXC %s\n", [[e reason] UTF8String] ?: "?");
    }
    atomic_store(&g_grab_busy, 0);
}
// Track a display-sized (tex, IOSurface) pair and spawn the single bg bridge
// thread on first use. The thread either fills the surface gray (mode 1) or
// copies the texture's CPU-mapped GPU backing (+0xa0, which holds the real
// GPU-rendered composite — see [[composite-iosurface-all-zero-gpu-not-writing]])
// into the IOSurface that CGDisplayCreateImage reads
// ([[vnc-read-path-is-cgdisplaycreateimage-compositor-black]]).
static NSMutableArray *g_dispTexs = nil;   // id<MTLTexture>, ARC-retained
static NSMutableArray *g_dispSurfs = nil;  // NSValue ptr, surface CFRetained
static void macws_disp_fill_track(id<MTLTexture> tex, IOSurfaceRef iosurface) {
    int mode = macws_disp_mode();
    if (!iosurface || mode == 0) return;
    size_t iw = IOSurfaceGetWidth(iosurface);
    size_t ih = IOSurfaceGetHeight(iosurface);
    if (iw < 1000 || ih < 600) return;
    static dispatch_once_t dispOnce;
    dispatch_once(&dispOnce, ^{
        g_dispTexs = [NSMutableArray new];
        g_dispSurfs = [NSMutableArray new];
        [NSThread detachNewThreadWithBlock:^{
            for (;;) {
                @synchronized(g_dispSurfs) {
                    NSUInteger n = g_dispSurfs.count;
                    for (NSUInteger i = 0; i < n; i++) {
                        IOSurfaceRef s = (IOSurfaceRef)[g_dispSurfs[i] pointerValue];
                        id<MTLTexture> t = (i < g_dispTexs.count) ? g_dispTexs[i] : nil;
                        if (IOSurfaceLock(s, 0, NULL) != 0) continue;
                        void *base = IOSurfaceGetBaseAddress(s);
                        size_t sbpr = IOSurfaceGetBytesPerRow(s);
                        size_t sh = IOSurfaceGetHeight(s);
                        if (mode == 1) {
                            size_t al = IOSurfaceGetAllocSize(s);
                            if (base && al) memset(base, 0xC0, al);
                        } else if (mode == 2 && t && base) {
                            // SAFE raw copy of the texture's GPU backing (+0xa0)
                            // into the surface. NOTE: backing is AGX-tiled so
                            // this is NOT display-correct yet — it's the input
                            // for CPU detiling (TODO). getBytes auto-detiles but
                            // CRASHES WS from a bg thread (races render). Raw
                            // memcpy is safe.
                            void *impl = *(void **)((char *)(__bridge void *)t + 0x208);
                            if ((uintptr_t)impl > 0x1000) {
                                void *backing = *(void **)((char *)impl + 0xa0);
                                if (backing)
                                    for (size_t y = 0; y < sh; y++)
                                        memcpy((char *)base + y * sbpr,
                                               (char *)backing + y * sbpr, sbpr);
                                // Mirror this filled display surface to the global
                                // VNC share surface (cross-process → OSXvnc).
                                if (backing)
                                    macws_vnc_share_mirror(base, sbpr, sh, iw);
                                // One-shot raw dumps for OFFLINE detile RE,
                                // gated by sentinel /tmp/macws_disp_dump. Two
                                // independent files so we learn which texture
                                // actually holds content:
                                //   /tmp/macws_back115.raw   = the pf=115 (16F)
                                //       composite (the surface CreateImage reads)
                                //   /tmp/macws_backdense.raw = densest of any pf
                                // Header: {w, h, pf, dens*1e6}.
                                if (backing && access("/tmp/macws_disp_dump", F_OK) == 0 &&
                                    [t width] >= 1000) {
                                    size_t tw = [t width], th = [t height];
                                    unsigned long pf = (unsigned long)[t pixelFormat];
                                    size_t bpe = (pf == 115) ? 8 : 4;
                                    size_t total = tw * th * bpe;
                                    // Denser nonzero sampler (every 256B, was 1024)
                                    // — 16F low-bytes are often 0 so coarse sampling
                                    // undercounted the real composite.
                                    size_t nzc = 0, samp = 0;
                                    for (size_t off = 0; off < total; off += 256) {
                                        if (((uint8_t *)backing)[off]) nzc++;
                                        samp++;
                                    }
                                    double dens = samp ? (double)nzc / samp : 0;
                                    static int s_d115 = 0;
                                    if (!s_d115 && pf == 115) {
                                        FILE *df = fopen("/tmp/macws_back115.raw", "wb");
                                        if (df) {
                                            uint32_t hdr[4] = { (uint32_t)tw, (uint32_t)th, (uint32_t)pf, (uint32_t)(dens*1e6) };
                                            fwrite(hdr, 4, 4, df); fwrite(backing, 1, total, df); fclose(df);
                                            s_d115 = 1;
                                            fprintf(stderr, "#### DUMP115 %zux%zu dens=%.3f\n", tw, th, dens);
                                        }
                                    }
                                    static int s_ddense = 0;
                                    if (!s_ddense && dens > 0.01) {
                                        FILE *df = fopen("/tmp/macws_backdense.raw", "wb");
                                        if (df) {
                                            uint32_t hdr[4] = { (uint32_t)tw, (uint32_t)th, (uint32_t)pf, (uint32_t)(dens*1e6) };
                                            fwrite(hdr, 4, 4, df); fwrite(backing, 1, total, df); fclose(df);
                                            s_ddense = 1;
                                            fprintf(stderr, "#### DUMPDENSE %zux%zu pf=%lu dens=%.3f\n", tw, th, pf, dens);
                                        }
                                    }
                                }
                            }
                        } else if (mode == 3 && t) {
                            // LIGHT density scan (no memcpy/mirror/dump) — find
                            // which tracked texture holds content + its pf. Read
                            // the texture's +0xa0 backing, sample every 4 KB.
                            void *impl = *(void **)((char *)(__bridge void *)t + 0x208);
                            if ((uintptr_t)impl > 0x1000) {
                                void *backing = *(void **)((char *)impl + 0xa0);
                                if (backing) {
                                    size_t tw = [t width], th = [t height];
                                    unsigned long pf = (unsigned long)[t pixelFormat];
                                    size_t bpe = (pf == 115) ? 8 : 4;
                                    size_t total = tw * th * bpe, nz = 0, samp = 0;
                                    for (size_t off = 0; off < total; off += 4096) { samp++; if (((uint8_t*)backing)[off]) nz++; }
                                    double dens = samp ? 100.0*nz/samp : 0;
                                    static int sc = 0;
                                    if ((sc++ % 8) == 0 || dens > 1.0)
                                        fprintf(stderr, "#### TEXSCAN tex=%p %zux%zu pf=%lu dens=%.2f%%\n",
                                                (void*)t, tw, th, pf, dens);
                                }
                            }
                        }
                        IOSurfaceUnlock(s, 0, NULL);
                    }
                }
                usleep(mode == 3 ? 250000 : (mode == 2 ? 16000 : 25000));
            }
        }];
    });
    @synchronized(g_dispSurfs) {
        for (NSValue *v in g_dispSurfs)
            if ((IOSurfaceRef)[v pointerValue] == iosurface) return;
        CFRetain(iosurface);
        [g_dispSurfs addObject:[NSValue valueWithPointer:iosurface]];
        [g_dispTexs addObject:(tex ?: (id)[NSNull null])];
        // Log layout once so we know if the backing is linear (flat copy OK)
        // or Morton-tiled (would need detiling).
        uint8_t layout = 0xff;
        if (tex) {
            void *impl = *(void **)((char *)(__bridge void *)tex + 0x208);
            if ((uintptr_t)impl > 0x1000) layout = *(uint8_t *)((char *)impl + 0x184);
        }
        uint32_t tstride = 0;
        if (tex) {
            void *impl = *(void **)((char *)(__bridge void *)tex + 0x208);
            if ((uintptr_t)impl > 0x1000) tstride = *(uint32_t *)((char *)impl + 0xa8);
        }
        fprintf(stderr, "#### DISP-BRIDGE mode=%d track surf=%p tex=%p %zux%zu layout=%u tstride=%u sbpr=%zu (n=%lu)\n",
                mode, (void*)iosurface, (void*)tex, iw, ih, layout, tstride,
                IOSurfaceGetBytesPerRow(iosurface), (unsigned long)g_dispSurfs.count);
        unsigned long tpf = tex ? (unsigned long)[tex pixelFormat] : 0;
        unsigned long tw = tex ? (unsigned long)[tex width] : 0;
        unsigned long th = tex ? (unsigned long)[tex height] : 0;
        FILE *lf = fopen("/tmp/macws_disp.log", "a");
        if (lf) {
            fprintf(lf, "DISP-BRIDGE mode=%d surf=%p tex=%p surf=%zux%zu tex=%lux%lu pf=%lu layout=%u tstride=%u sbpr=%zu n=%lu\n",
                    mode, (void*)iosurface, (void*)tex, iw, ih, tw, th, tpf, layout, tstride,
                    IOSurfaceGetBytesPerRow(iosurface), (unsigned long)g_dispSurfs.count);
            fclose(lf);
        }
    }
}

// 2026-06-20 — Wire IOSurface base address into AGX texture's writable
// backing pointer ivar.
//
// Root cause (RE'd from chroot WS crash WindowServer-2026-06-20-144645.ips):
//   CA's BackdropLayer renderer calls
//   CA::OGL::MetalContext::create_texture, which builds a Metal texture
//   then calls `-[IOGPUMetalTexture replaceRegion:mipmapLevel:withBytes:
//   bytesPerRow:]` to upload pixel data.  That forwards to
//   `-[AGXG13GFamilyTexture replaceRegion: ...]` which then calls
//   `AGX::Texture<...>::writeRegion(...)`.  writeRegion computes the
//   destination pointer as `[cpp+0xa0] + offset` and memmove's pixel
//   data there.  On real Apple HW `[cpp+0xa0]` is the CPU-mapped GPU
//   memory pointer set up by the AGX kernel driver during texture init.
//   In chroot, AGX kernel returns kIOReturnNoBandwidth for the scanout
//   path so the ivar stays NULL — writeRegion's memmove(dst=NULL, ...)
//   SIGSEGVs.
//
// RE evidence (from ~/Downloads/agx-re/AGXMetal13_3 arm64e):
//   - `-[AGXG13GFamilyTexture replaceRegion:...]` at +0x394a90 reads
//     `_impl` ivar offset (file_addr 0x21a8a9884 → ivar offset 0x208)
//     to dereference self → C++ AGX::Texture object.
//   - `fn @0x1e5770000` (called from writeRegion +0x6c4): reads
//     `[cpp+0x184]` (layout flag); if 0, returns `[cpp+0xa0]` (the
//     writable backing pointer); if != 0 and != 3, returns 0.
//   - `[cpp+0xa8]` is a 32-bit offset added to base for indexing.
//
// Fix: after our IOSurface-backed texture is created successfully,
// reach into the C++ implementation object and set:
//   - cpp+0xa0 = IOSurfaceGetBaseAddress(surface)  ← writable backing
//   - cpp+0xa8 = 0                                  ← offset
// This makes the texture's "linear backing" path point at the IOSurface
// CPU mapping — replaceRegion now writes pixel bytes into the IOSurface
// memory, which is the same memory the GPU later samples from.  Proper
// upstream fix mirroring what AGX kernel driver does on real HW.  NOT a
// NOP/return-bypass — it's the missing setup step.
//
// Layout sanity: only patches when `[cpp+0x184] == 0` (linear layout).
// Compressed/heap-paged textures (layout=3) use a different ivar layout
// we haven't RE'd — left untouched so they don't get corrupted.
//
// IOSurface lifetime: Metal's newTextureWithDescriptor:iosurface:
// retains the IOSurface internally; base address stays valid as long
// as the texture stays alive.  We lock the surface for
// kIOSurfaceLockAvoidSync at first use to ensure base address is
// mapped — IOSurfaceCreate without explicit cache mode may defer the
// mapping until first lock.
static void macws_wire_iosurface_base_into_texture(id<MTLTexture> tex,
                                                   IOSurfaceRef surf) {
    if (!tex || !surf) return;
    // Resolve _impl ivar offset dynamically (fallback to 0x208 from RE
    // if the class introspection fails — UUID-stable across 13.x).
    static ptrdiff_t s_impl_off = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("AGXG13GFamilyTexture");
        if (cls) {
            Ivar iv = class_getInstanceVariable(cls, "_impl");
            if (iv) {
                s_impl_off = ivar_getOffset(iv);
            }
        }
        if (s_impl_off == 0) s_impl_off = 0x208;  // RE-fallback
        fprintf(stderr,
            "#### AGX_WIRE_IOSURF: _impl ivar offset = %#tx\n", s_impl_off);
    });
    // Lock the IOSurface to ensure base address is mapped into our VM.
    // kIOSurfaceLockAvoidSync = no implicit GPU sync, just map.  Leave
    // it locked — texture's IOSurface retain keeps it alive; pages
    // unmap when surface is released (texture release path).
    int lock_rc = IOSurfaceLock(surf, /*kIOSurfaceLockAvoidSync*/0, NULL);
    void *base = IOSurfaceGetBaseAddress(surf);
    if (!base) {
        static int nolog = 0;
        if (nolog++ < 3) {
            fprintf(stderr,
                "#### AGX_WIRE_IOSURF: IOSurfaceGetBaseAddress=NULL (lock_rc=%d) tex=%p surf=%p\n",
                lock_rc, (void *)tex, (void *)surf);
        }
        return;
    }
    void *impl = *(void **)((char *)(__bridge void *)tex + s_impl_off);
    if (!impl) {
        static int impllog = 0;
        if (impllog++ < 3) {
            fprintf(stderr,
                "#### AGX_WIRE_IOSURF: _impl=NULL (uninit C++ obj) tex=%p\n",
                (void *)tex);
        }
        return;
    }
    uint8_t layout = *(volatile uint8_t *)((char *)impl + 0x184);
    // RE-confirmed 2026-06-21 (AGX::Texture<3>::getCPUPtr @ 0x1e576fb74): the
    // CPU backing base is read from `this->0xa0` for BOTH layout 0 (linear) AND
    // layout 3 (twiddled) — only the offset math differs (linear stride vs Z-order
    // twiddle). The connection-triggered WS crash (WindowServer-2026-06-21-154750.ips:
    // memmove(dst=NULL) <- AGX::Texture<3>::writeRegion <- replaceRegion <-
    // CA::OGL::MetalContext::create_texture <- BackdropLayer blur) is a layout=3
    // texture whose +0xa0 was left NULL because this function used to skip layout!=0.
    // Since these textures ARE IOSurface-backed (routed via the plain-newTexture
    // path) and AGX chose layout=3 to FIT that IOSurface, wiring 0xa0 = IOSurface
    // base is correct AND GPU-coherent. Only layouts 0 and 3 use the 0xa0 path;
    // skip anything else (un-RE'd ivar geometry).
    if (layout != 0 && layout != 3) {
        static int layoutlog = 0;
        if (layoutlog++ < 4) {
            fprintf(stderr,
                "#### AGX_WIRE_IOSURF: skip — layout=%d (not 0/3) tex=%p impl=%p\n",
                layout, (void *)tex, impl);
        }
        return;
    }
    // Apply the wire-up ONLY when the existing backing pointer is NULL.
    // RE evidence: on real Apple HW, AGX kernel driver populates +0xa0
    // during texture init with a CPU-mapped GPU memory address.  In
    // chroot, SOME textures get that init (prev_base non-NULL — leave
    // them alone), OTHERS hit the kIOReturnNoBandwidth gate before
    // init populates the ivar (prev_base NULL — these are the ones
    // that crash replaceRegion).  Only fill the NULL case so we don't
    // clobber AGX's legitimate setup.
    void *prev_base = *(void **)((char *)impl + 0xa0);
    if (prev_base != NULL) {
        static int skiplog = 0;
        if (skiplog++ < 16) {
            // 2026-06-20 — CONFIRMED SEPARATE-MEMORY: texture's CPU
            // backing (+0xa0) != IOSurface base.  Now sample the
            // backing's first 4 KB to see if the GPU rendered content
            // THERE (→ copy backing→IOSurface fixes VNC) or if it's
            // also zero (→ GPU truly not executing).  4 KB is safe for
            // any real texture backing.
            int nz = 0; uint64_t acc = 0;
            for (int i = 0; i < 4096; i++) {
                uint8_t v = ((volatile uint8_t *)prev_base)[i];
                if (v) nz++; acc += v;
            }
            fprintf(stderr,
                "#### AGX_WIRE_IOSURF: skip(AGX-set) tex=%p backing=%p IOSurf=%p "
                "SEPARATE backing[0:4K] nonzero=%d sum=%llu\n",
                (void *)tex, prev_base, base, nz, (unsigned long long)acc);
        }
        // VERIFY-DETILE (gated /tmp/macws_grab_now, one-shot): dump the largest CONTENT source
        // backing to /tmp/macws_src.raw for offline agx_detile — proves the Asahi algorithm on real
        // device content. SEPARATE trigger (macws_src_now) so it doesn't race the dest grab (macws_grab_now).
        if (access("/tmp/macws_src_now", F_OK) == 0) {
            size_t tw = [tex width], th = [tex height];
            unsigned long pf = (unsigned long)[tex pixelFormat];
            if (tw >= 256 && th >= 48) {
                int nzc = 0; for (int i = 0; i < 8192; i++) if (((volatile uint8_t *)prev_base)[i]) nzc++;
                if (nzc > 400) {
                    size_t ext = 0; { vm_address_t a = (vm_address_t)prev_base; vm_size_t rs = 0;
                        vm_region_basic_info_data_64_t bi2; mach_msg_type_number_t c2 = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o2 = MACH_PORT_NULL;
                        if (vm_region_64(mach_task_self(), &a, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi2, &c2, &o2) == KERN_SUCCESS && a <= (vm_address_t)prev_base) ext = (size_t)(a + rs - (vm_address_t)prev_base); }
                    size_t bpp = (pf == 115) ? 8 : 4;
                    size_t want = ((tw + 63) / 64 * 64) * ((th + 63) / 64 * 64) * bpp * 2;
                    if (want > ext) want = ext;
                    if (want > 96u * 1024 * 1024) want = 96u * 1024 * 1024;
                    uint32_t stride = *(volatile uint32_t *)((char *)impl + 0xa8);
                    FILE *f = fopen("/tmp/macws_src.raw", "wb");
                    if (f) { uint32_t hd[6] = { (uint32_t)tw, (uint32_t)th, (uint32_t)pf, layout, (uint32_t)want, stride };
                        fwrite(hd, 4, 6, f); fwrite(prev_base, 1, want, f); fclose(f);
                        fprintf(stderr, "#### VERIFY-DETILE dumped %zux%zu pf=%lu layout=%d bytes=%zu nz8k=%d -> /tmp/macws_src.raw\n", tw, th, pf, layout, want, nzc);
                        unlink("/tmp/macws_grab_now"); }
                }
            }
        }
        return;
    }
    *(void * volatile *)((char *)impl + 0xa0) = base;
    // layout=0 (linear) wants a tight stride at +0xa8; layout=3 (twiddled) keeps
    // AGX's own twiddle params at +0xa8 (getCPUPtr's twiddle math reads it) —
    // zeroing it would corrupt the layout-3 address computation.
    if (layout == 0)
        *(volatile uint32_t *)((char *)impl + 0xa8) = 0;
    static _Atomic int wired_count = 0;
    int n = atomic_fetch_add(&wired_count, 1);
    if (n < 16) {
        fprintf(stderr,
            "#### AGX_WIRE_IOSURF #%d: tex=%p impl=%p +0xa0: NULL→%p layout=%d (lock_rc=%d)\n",
            n, (void *)tex, impl, base, layout, lock_rc);
    }
}

// Process-wide stash of the current IOSurfaceID being wrapped as a texture.
// Was per-thread but the texture init dispatches the kernel call onto a
// worker thread that __thread doesn't reach. Set by
// `hooked_newTextureWithDescriptor:iosurface:plane:` before %orig is
// invoked, cleared after. Read by IOConnectCallMethod_new in mac_hooks.m
// to inject args[+0x30] = IOSurfaceID for sel=0xa type=0x82 — the iOS
// kernel AGX dispatcher requires this for IOSurface-backed textures.
//
// Race risk: WS may have concurrent texture creates from different
// threads. Mitigate by capturing the value just before %orig and restoring
// just after; concurrent creates would see each other's IDs, but in
// practice WS serialises scanout texture creation.
static _Atomic uint32_t s_current_iosurface_id = 0;

__attribute__((visibility("default")))
uint32_t macws_get_current_iosurface_id(void) {
    return s_current_iosurface_id;
}

__attribute__((visibility("default")))
void macws_set_current_iosurface_id(uint32_t id) {
    s_current_iosurface_id = id;
}

// FORCE_M1_DRIVER auto-enabled for the arm64e on-device slice only (see
// mac_hooks.m). arm64e -> real macOS AGX driver; arm64/x86_64 -> MTLSimDevice.
#if defined(__arm64e__) && defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    if(class_getInstanceMethod(class, originalAction) == NULL) {
        class_addMethod(class, originalAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
        method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
    }
}

@interface _MTLDevice : NSObject
- (uint32_t)acceleratorPort;
@end

// ─── Tile-pipeline → render-pipeline substitution ────────────────────────────
// (definition moved into the MTLFakeDevice category below as
// `hooked_newRenderPipelineStateWithTileDescriptor:...`, then runtime-swizzled
// onto MTLSimDevice in initHooks. Logos `%hook MTLSimDevice` doesn't apply
// here because MTLSimDevice has no compile-time interface declaration.)

// MTLSimRenderCommandEncoder forwarding helpers — BlurState issues
// setTileTexture:atIndex:, setTileBuffer:offset:atIndex:,
// setTileBytes:length:atIndex: on the regular render encoder (since the
// substitute pipeline isn't actually a tile pipeline, but BlurState doesn't
// know). Redirect each tile-* selector to its fragment-* equivalent.
// MACWS_BLUR_TRACE=1 dumps every tile-encoder selector forward with the
// actual arguments so we can reconstruct what BlurState is staging into the
// (substitute) fragment slots and align the shader IO accordingly.
static int macws_blur_trace(void) {
    static int v = -1;
    if (v < 0) v = getenv("MACWS_BLUR_TRACE") ? 1 : 0;
    return v;
}
// Associated-object keys for caching the source / destination textures
// captured on the render encoder so dispatchThreadsPerTile can hand them to
// the XPC blur forward.
static const void *MACWS_SRC_TEX_KEY = &MACWS_SRC_TEX_KEY;
static const void *MACWS_DST_TEX_KEY = &MACWS_DST_TEX_KEY;

static void macws_setTileTexture_impl(id self, SEL _cmd, id tex, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger w = 0, h = 0;
        @try { if (tex) { label = [[tex label] UTF8String] ?: "(nolabel)";
                          w = (NSUInteger)[tex width]; h = (NSUInteger)[tex height]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileTexture[%lu] = %p label=%s %lux%lu\n",
                (unsigned long)idx, (void *)tex, label, (unsigned long)w, (unsigned long)h);
    }
    // Cache source texture on the encoder so the dispatchThreadsPerTile→XPC
    // path can recover it.
    if (idx == 0 && tex) {
        objc_setAssociatedObject(self, MACWS_SRC_TEX_KEY, tex, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentTexture:atIndex:"), tex, idx);
}
static void macws_setTileBuffer_impl(id self, SEL _cmd, id buf, NSUInteger off, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger len = 0;
        @try { if (buf) { label = [[buf label] UTF8String] ?: "(nolabel)";
                          len = (NSUInteger)[buf length]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileBuffer[%lu] = %p label=%s len=%lu off=%lu\n",
                (unsigned long)idx, (void *)buf, label, (unsigned long)len, (unsigned long)off);
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBuffer:offset:atIndex:"), buf, off, idx);
}
static void macws_setTileBytes_impl(id self, SEL _cmd, const void *bytes, NSUInteger len, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileBytes[%lu] len=%lu", (unsigned long)idx, (unsigned long)len);
        const uint8_t *p = (const uint8_t *)bytes;
        size_t dump = len < 64 ? len : 64;
        fprintf(stderr, "  bytes=");
        for (size_t i = 0; i < dump; i++) fprintf(stderr, "%02x", p[i]);
        // Also interpret first 32 bytes as 8 floats (typical uniform layout).
        if (len >= 32) {
            const float *f = (const float *)bytes;
            fprintf(stderr, "\n####   floats=[%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]);
        }
        fprintf(stderr, "\n");
    }
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBytes:length:atIndex:"), bytes, len, idx);
}
static void macws_setTileSamplerState_impl(id self, SEL _cmd, id sampler, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileSampler[%lu] = %p\n", (unsigned long)idx, (void *)sampler);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentSamplerState:atIndex:"), sampler, idx);
}
// dispatchThreadsPerTile: dispatches the tile shader once per tile in the
// render target. For a regular render encoder we substitute a fullscreen
// triangle draw (3 vertices, MTLPrimitiveTypeTriangle) — the
// downsample_blur_vert_lpf passthrough writes positions covering NDC.
// 3-vertex fullscreen triangle layout (vertex shader fallback when XPC
// blur forward isn't available).
typedef struct {
    float pos[4];
    float tex[4];
    float col[4];
} macws_fs_vtx_t;
static const macws_fs_vtx_t macws_fs_triangle[3] = {
    {{-1.0f, -1.0f, 0.0f, 1.0f}, {0.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{ 3.0f, -1.0f, 0.0f, 1.0f}, {2.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{-1.0f,  3.0f, 0.0f, 1.0f}, {0.0f,-1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
};

// XPC blur forward to MTLSimDriverHost (iOS Metal + MPSImageGaussianBlur).
// Cached connection so we don't reconnect every frame.
static xpc_connection_t gBlurXpc = NULL;
static xpc_connection_t macws_blur_xpc(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            fprintf(stderr, "#### blur-xpc: createMach symbol missing\n");
            return;
        }
        gBlurXpc = createMach("com.macwsguide.blur", NULL, 0);
        if (!gBlurXpc) {
            fprintf(stderr, "#### blur-xpc: createMach returned NULL\n");
            return;
        }
        xpc_connection_set_event_handler(gBlurXpc, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(gBlurXpc);
        fprintf(stderr, "#### blur-xpc: opened connection to com.macwsguide.blur\n");
    });
    return gBlurXpc;
}

// Send the source+dest IOSurfaces over to the host, wait synchronously, and
// return YES on a successful blur. The caller then skips drawPrimitives so
// the existing render encoder doesn't overwrite the host's MPS output.
static BOOL macws_blur_forward(IOSurfaceRef src, IOSurfaceRef dst, double sigma) {
    xpc_connection_t conn = macws_blur_xpc();
    if (!conn || !src || !dst) return NO;
    mach_port_t srcPort = IOSurfaceCreateMachPort(src);
    mach_port_t dstPort = IOSurfaceCreateMachPort(dst);
    if (srcPort == MACH_PORT_NULL || dstPort == MACH_PORT_NULL) {
        if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
        if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
        return NO;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "blur");
    xpc_dictionary_set_mach_send(req, "source_port", srcPort);
    xpc_dictionary_set_mach_send(req, "dest_port", dstPort);
    xpc_dictionary_set_double(req, "radius", sigma);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    BOOL ok = NO;
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        const char *r = xpc_dictionary_get_string(reply, "result");
        ok = r && strcmp(r, "ok") == 0;
        if (macws_blur_trace()) {
            fprintf(stderr, "#### blur-xpc reply: %s\n", r ?: "(no result)");
        }
    } else if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-xpc no reply\n");
    }
    if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
    if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
    return ok;
}

static void macws_dispatchThreadsPerTile_impl(id self, SEL _cmd, void *sizeArg) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace dispatchThreadsPerTile\n");
    }

    // Try the XPC forward: pick up the source (cached in setTileTexture[0])
    // and destination (cached in newRenderCommandEncoderWithDescriptor hook).
    // MACWS_BLUR_XPC=1 enables — default off so the synchronous reply wait
    // can't hang WS if MTLSimDriverHost doesn't publish the listener.
    id<MTLTexture> srcTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_SRC_TEX_KEY) : nil;
    id<MTLTexture> dstTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_DST_TEX_KEY) : nil;
    if (srcTex && dstTex) {
        IOSurfaceRef srcSurf = NULL, dstSurf = NULL;
        @try { srcSurf = [srcTex iosurface]; } @catch (NSException *e) {}
        @try { dstSurf = [dstTex iosurface]; } @catch (NSException *e) {}
        if (srcSurf && dstSurf) {
            // sigma from setTileBytes[0] is BlurState's tap-count/level — we
            // map that to a fixed sigma for now (8 for the menu-bar feel).
            BOOL ok = macws_blur_forward(srcSurf, dstSurf, 8.0);
            if (ok) {
                if (macws_blur_trace()) {
                    fprintf(stderr, "#### blur-xpc: forward OK — skipping drawPrimitives\n");
                }
                // Host already wrote the destination IOSurface; don't run
                // the local substitute draw which would overwrite it.
                return;
            }
        }
    }

    // Fallback: substitute non-tile draw with QC blur shaders.
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setVertexBytes:length:atIndex:"),
        (const void *)macws_fs_triangle,
        (NSUInteger)sizeof(macws_fs_triangle),
        (NSUInteger)30);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
        (NSUInteger)3, (NSUInteger)0, (NSUInteger)3);
}
// setThreadgroupMemoryLength:offset:atIndex: is a tile-encoder API for
// declaring tile-local shared memory. Regular encoders don't need it.
static void macws_setThreadgroupMemoryLength_impl(id self, SEL _cmd, NSUInteger len, NSUInteger off, NSUInteger idx) {
    (void)self; (void)len; (void)off; (void)idx;
    // no-op for non-tile encoder
}
// Swizzle target on MTLSimCommandBuffer: captures the render-pass
// descriptor's color attachment[0] texture and associates it with the
// returned encoder so dispatchThreadsPerTile→XPC can read it back.
static id (*orig_renderCommandEncoderWithDescriptor)(id, SEL, id) = NULL;
static id macws_renderCommandEncoder_capture(id self, SEL _cmd, id passDesc) {
    id encoder = orig_renderCommandEncoderWithDescriptor(self, _cmd, passDesc);
    if (encoder && passDesc) {
        @try {
            id colorAtts = [passDesc valueForKey:@"colorAttachments"];
            id att0 = [colorAtts objectAtIndexedSubscript:0];
            id<MTLTexture> dst = [att0 valueForKey:@"texture"];
            if (dst) {
                objc_setAssociatedObject(encoder, MACWS_DST_TEX_KEY, dst, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (macws_blur_trace()) {
                    NSUInteger w = (NSUInteger)[dst width], h = (NSUInteger)[dst height];
                    const char *lab = [[dst label] UTF8String] ?: "(nolabel)";
                    fprintf(stderr, "#### blur-trace renderCommandEncoder colorAtt[0] = %p label=%s %lux%lu\n",
                            (void *)dst, lab, (unsigned long)w, (unsigned long)h);
                }
            }
        } @catch (NSException *e) {}
    }
    return encoder;
}

__attribute__((constructor)) static void macws_install_tile_encoder_forwards(void) {
    // Defer until MTLSimRenderCommandEncoder class is loaded.
    dispatch_async(dispatch_get_main_queue(), ^{
        Class enc = objc_getClass("MTLSimRenderCommandEncoder");
        if (!enc) {
            fprintf(stderr, "#### tile-encoder forwards: class MTLSimRenderCommandEncoder NOT found\n");
            return;
        }
        class_addMethod(enc, sel_registerName("setTileTexture:atIndex:"),
                        (IMP)macws_setTileTexture_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("setTileBuffer:offset:atIndex:"),
                        (IMP)macws_setTileBuffer_impl, "v@:@QQ");
        class_addMethod(enc, sel_registerName("setTileBytes:length:atIndex:"),
                        (IMP)macws_setTileBytes_impl, "v@:^vQQ");
        class_addMethod(enc, sel_registerName("setTileSamplerState:atIndex:"),
                        (IMP)macws_setTileSamplerState_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("dispatchThreadsPerTile:"),
                        (IMP)macws_dispatchThreadsPerTile_impl, "v@:^v");
        class_addMethod(enc, sel_registerName("setThreadgroupMemoryLength:offset:atIndex:"),
                        (IMP)macws_setThreadgroupMemoryLength_impl, "v@:QQQ");
        fprintf(stderr, "#### tile-encoder forwards installed on MTLSimRenderCommandEncoder\n");
        fflush(stderr);
        fprintf(stderr, "#### BLUR-DEBUG: about to look for MTLSim command buffer class\n");
        fflush(stderr);

        // Swizzle the MTLSim command-buffer class's
        // renderCommandEncoderWithDescriptor: to capture the render pass's
        // color attachment[0] texture (= the blur destination) so the XPC
        // forward can pass it across. Class name varies across MTLSimDriver
        // builds — try several candidates.
        const char *cb_names[] = {
            "MTLSimCommandBuffer",
            "MTLSimMainCommandBuffer",
            "MTLSimSecondaryCommandBuffer",
            "MTLSimulatorCommandBuffer",
            "MTLToolsCommandBuffer",
            "MTLDebugCommandBuffer",
            "MTLIGAccelCommandBuffer",
            NULL
        };
        Class cb = nil;
        for (int i = 0; cb_names[i]; i++) {
            Class c = objc_getClass(cb_names[i]);
            if (c) {
                cb = c;
                fprintf(stderr, "#### blur: found command-buffer class %s\n", cb_names[i]);
                break;
            }
        }
        if (!cb) {
            // Fall back: enumerate ALL classes, find any whose name has
            // "CommandBuffer" and "Sim" or implements renderCommandEncoder.
            unsigned int n = 0;
            Class *all = objc_copyClassList(&n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = class_getName(all[i]);
                if (!nm) continue;
                if (strstr(nm, "CommandBuffer") && (strstr(nm, "Sim") || strstr(nm, "MTL"))) {
                    Method mm = class_getInstanceMethod(all[i],
                        sel_registerName("renderCommandEncoderWithDescriptor:"));
                    if (mm) {
                        cb = all[i];
                        fprintf(stderr, "#### blur: located command-buffer class %s by scan\n", nm);
                        break;
                    }
                }
            }
            if (all) free(all);
        }
        if (cb) {
            SEL sel = sel_registerName("renderCommandEncoderWithDescriptor:");
            Method m = class_getInstanceMethod(cb, sel);
            if (m) {
                orig_renderCommandEncoderWithDescriptor =
                    (id (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)macws_renderCommandEncoder_capture);
                fprintf(stderr, "#### %s.renderCommandEncoderWithDescriptor swizzled\n",
                        class_getName(cb));
            } else {
                fprintf(stderr, "#### blur: cmd-buffer class %s has NO renderCommandEncoderWithDescriptor\n",
                        class_getName(cb));
            }
        } else {
            fprintf(stderr, "#### blur: no MTLSim command-buffer class found\n");
        }
    });
}

@implementation _MTLDevice(MetalXPC)
- (void)_setAcceleratorService:(id)arg1 {}

- (uint32_t)peerGroupID {
    return self.acceleratorPort;
}
@end

// MTLFakeDevice creates a new ObjC class.  On arm64e, on-device lld emits a
// plain (non-auth) chained-fixup rebase for class_t->data, but macOS libobjc
// expects an address-diversified autda pointer → EXC_BREAKPOINT (PAC trap DA)
// in readClass during map_images.  Exclude the entire class from arm64e so the
// arm64e slice has no class_t entries, letting the arm64 slice handle Metal.
// On-device builds (misc/build_on_ios.sh) pass -DLIBMACHOOK_ON_DEVICE_BUILD: lld
// uses -fixup_chains there, so arm64e can include this code.
#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
static id(*MTLCreateSimulatorDevice)(void);
@interface MTLFakeDevice : _MTLDevice
@end
@implementation MTLFakeDevice
- (BOOL)initHooks {
    if(%c(MTLSimDevice)) {
        return YES; // Already hooked
    }
    
    void *handle = dlopen("@loader_path/../Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MetalSerializer framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MetalSerializer successfully!");
    }
    
    handle = dlopen("@loader_path/../Frameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MTLSimDriver framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLSimDriver successfully!");
    }
    MTLCreateSimulatorDevice = dlsym(handle, "MTLCreateSimulatorDevice");
    NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    
    Class MTLSimDeviceClass = %c(MTLSimDevice);
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithLength:options:pointer:copyBytes:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(acceleratorPort), MTLFakeDevice.class, @selector(hooked_acceleratorPort));
    swizzle2(MTLSimDeviceClass, @selector(location), MTLFakeDevice.class, @selector(hooked_location));
    swizzle2(MTLSimDeviceClass, @selector(locationNumber), MTLFakeDevice.class, @selector(hooked_locationNumber));
    swizzle2(MTLSimDeviceClass, @selector(maxTransferRate), MTLFakeDevice.class, @selector(hooked_maxTransferRate));
    // MACWS_TEX_TRACE=1 enables full IOSurface→Metal texture descriptor logging.
    // Always-installed because the cold/abort path of MTLSimDriver's
    // sendXPCMessageWithReplySync hits abort() with no recovery — we MUST see
    // every descriptor right before the failure to know what to translate.
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:iosurface:plane:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
    // Tile-pipeline → render-pipeline substitution: MTLSimDevice's tile-
    // pipeline impl MTLReportFailure-aborts WS. Swizzle to our converter.
    swizzle2(MTLSimDeviceClass,
             @selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:),
             MTLFakeDevice.class,
             @selector(hooked_newRenderPipelineStateWithTileDescriptor:options:reflection:error:));
    fprintf(stderr, "#### MTLSimDevice tile-pipeline → MTLFakeDevice converter swizzled\n");

    // MTLSimDevice has SUBCLASSES (MTLSimGPU13MDevice, MTLSimGPU11Device, ...).
    // If the runtime class is a subclass that overrides our hooked selectors, the
    // base-class swizzle is shadowed and our hook never runs. Enumerate all
    // subclasses and apply the same swizzle to each one that has its own IMP.
    unsigned int numClasses = 0;
    Class *allClasses = objc_copyClassList(&numClasses);
    int subclassPatched = 0;
    for (unsigned int i = 0; i < numClasses; i++) {
        Class c = allClasses[i];
        // Walk superclasses to find MTLSimDevice ancestry
        Class p = c;
        while (p && p != MTLSimDeviceClass) {
            p = class_getSuperclass(p);
        }
        if (p != MTLSimDeviceClass || c == MTLSimDeviceClass) continue;
        // Only swizzle if THIS class itself implements the selector (not inherited)
        unsigned int nm = 0;
        Method *methods = class_copyMethodList(c, &nm);
        BOOL has_iosurf = NO;
        BOOL has_plain  = NO;
        SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
        SEL plain_sel  = @selector(newTextureWithDescriptor:);
        for (unsigned int j = 0; j < nm; j++) {
            SEL s = method_getName(methods[j]);
            if (s == iosurf_sel) has_iosurf = YES;
            if (s == plain_sel)  has_plain  = YES;
        }
        if (methods) free(methods);
        if (has_iosurf) {
            swizzle2(c, iosurf_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
            subclassPatched++;
        }
        if (has_plain) {
            swizzle2(c, plain_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
            subclassPatched++;
        }
        fprintf(stderr, "#### MTL_TEX subclass %s iosurf=%d plain=%d\n",
            class_getName(c), has_iosurf, has_plain);
    }
    if (allClasses) free(allClasses);
    fprintf(stderr, "#### MTL_TEX swizzled MTLSimDevice + %d subclass overrides\n", subclassPatched);
    NSLog(@"#### debugbydcmmc load swizzle2 successfully!");
    
    uint32_t *imp;
    // This check isn't present in iOS 14 simulator, maybe it was added in iOS 15?
    // Patch -[MTLSimTexture initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:] to bypass `IOSurface backed XR10 textures are not supported in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimTexture), @selector(initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0xfb7c] <+144>: bl     0x2e660        ; objc_msgSend$pixelFormat
        // -> MTLSimDriver[0xfb80] <+148>: and    x8, x0, #0xfffffffffffffffc
        // -> MTLSimDriver[0xfb84] <+152>: cmp    x8, #0x228
        // -> MTLSimDriver[0xfb88] <+156>: b.eq   0xfdf8         ; <+780>
        if(imp[i] == 0x927ef408 && imp[i+1] == 0xf108a11f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t[3]), ^{
                imp[i+1] = imp[i+2] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    // Patch -[MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:] to bypass `Linear texture can only be created on buffers with MTLStorageModePrivate in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimBuffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0x85bc] <+84>:  bl     0x2eda0        ; objc_msgSend$storageMode
        // -> MTLSimDriver[0x85c0] <+88>:  cmp    x0, #0x2
        //    MTLSimDriver[0x85c4] <+92>:  b.ne   0x8798         ; <+560>
        if(imp[i] == 0xf100081f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t), ^{
                imp[i] = imp[i+1] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    return YES;
}

- (id)initWithAcceleratorPort:(int)port {
    if(![self initHooks]) {
        return nil;
    }
    if(!MTLCreateSimulatorDevice) {
        NSLog(@"#### debugbydcmmc Failed to find MTLCreateSimulatorDevice: %s", dlerror());
        return nil;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    }
    // Class cls = NSClassFromString(@"MTLSimDevice");
    // NSLog(@"#### debugbydcmmc MTLSimDevice class %@", cls ? @"present" : @"missing");
    self = MTLCreateSimulatorDevice();
    // NSLog(@"#### debugbydcmmc MTLCreateSimulatorDevice done");
    // CRITICAL: use OBJC_ASSOCIATION_RETAIN (not ASSIGN). With ASSIGN the
    // autoreleased @(port) NSNumber is deallocated after the autorelease pool
    // drains, leaving a dangling pointer. -[hooked_acceleratorPort] then reads
    // garbage, WS thinks the GPU port is invalid → falls back to software
    // rendering, the SW renderer creates an IOSurface with FourCC '&b38'
    // (0x26623338) that MTLSim cannot wrap, and WS crash-loops in
    // WSCompositeDestinationCreateWithMetalTexture. Same root cause as the
    // upstream README "Unimplemented pixel format of 645346401" bug.
    objc_setAssociatedObject(self, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_RETAIN);
    fprintf(stderr, "#### MTLFakeDevice initWithAcceleratorPort:%d retained\n", port);
    return self;
}

- (uint32_t)hooked_acceleratorPort {
    NSNumber *n = (NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort));
    uint32_t port = n ? [n unsignedIntValue] : 0;
    static int trace_count = 0;
    if (trace_count < 10) {
        fprintf(stderr, "#### MTLFakeDevice acceleratorPort -> %u (NSNumber=%p)\n", port, n);
        trace_count++;
    }
    return port;
}

- (NSUInteger)hooked_location {
    return 0; // MTLDeviceLocationBuiltIn
}

- (NSUInteger)hooked_locationNumber {
    return 0;
}

- (NSUInteger)hooked_maxTransferRate {
    return 0; // The maximum transfer rate for built-in GPUs is 0.
}

- (id<MTLBuffer>)hooked_newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void * pointer, NSUInteger length)) deallocator {
    // NSLog(@"#### debugbydcmmc hooked_newBufferWithBytesNoCopy start");
    if(malloc_size(bytes) > 0) {
        // XPC doesn't like malloced buffers since they don't have MAP_SHARED flag, so we mirror it to a shared region here
        vm_address_t mirrored = 0;
        vm_prot_t cur_prot, max_prot;
        kern_return_t ret = vm_remap(mach_task_self(), &mirrored, length, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)bytes, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
        if(ret != KERN_SUCCESS) {
            NSLog(@"#### debugbydcmmc Failed to mirror memory: %s", mach_error_string(ret));
            return nil;
        }
        vm_protect(mach_task_self(), mirrored, length, NO,
                VM_PROT_READ | VM_PROT_WRITE);
        
        return [self hooked_newBufferWithBytesNoCopy:(void *)mirrored length:length options:options deallocator:^(void * _Nonnull pointer, NSUInteger length) {
            vm_deallocate(mach_task_self(), (vm_address_t)pointer, length);
            if(deallocator) deallocator(bytes, length);
        }];
    } else {
        return [self hooked_newBufferWithBytesNoCopy:bytes length:length options:options deallocator:deallocator];
    }
}

- (id<MTLBuffer>)hooked_newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options pointer:(void *)pointer copyBytes:(BOOL)copyBytes deallocator:(void (^)(void * pointer, NSUInteger length))deallocator {
    // Handle MTLResourceStorageModeManaged
    if(options & (1 << MTLResourceStorageModeShift)) {
        options &= ~(1 << MTLResourceStorageModeShift);
        options |= MTLResourceStorageModeShared;
    }
    return [self hooked_newBufferWithLength:length options:options pointer:pointer copyBytes:copyBytes deallocator:deallocator];
}

// IOSurface-backed texture creation: the SkyLight WSCompositeDestination /
// CAWindowServerDisplay surface path goes through here, and MTLSimDriver's
// sendXPCMessageWithReplySync cold path aborts on XPC reply errors with no
// recovery. Log every descriptor + IOSurface so we can characterize failures
// from the WindowServer.err / oslog stream BEFORE the abort kills the process.
static void macws_log_mtldesc(MTLTextureDescriptor *desc, IOSurfaceRef iosurface,
                              NSUInteger plane, const char *tag) {
    if (!desc) {
        fprintf(stderr, "#### MTL_TEX/%s desc=NIL\n", tag);
        return;
    }
    @try {
        fprintf(stderr, "#### MTL_TEX/%s pfmt=%lu type=%lu w=%lu h=%lu d=%lu mips=%lu arr=%lu samp=%lu storage=%lu cpu=%lu usage=%#lx swiz=%#x cs=%p plane=%lu ios=%p\n",
            tag,
            (unsigned long)desc.pixelFormat,
            (unsigned long)desc.textureType,
            (unsigned long)desc.width,
            (unsigned long)desc.height,
            (unsigned long)desc.depth,
            (unsigned long)desc.mipmapLevelCount,
            (unsigned long)desc.arrayLength,
            (unsigned long)desc.sampleCount,
            (unsigned long)desc.storageMode,
            (unsigned long)desc.cpuCacheMode,
            (unsigned long)desc.usage,
            0u, // swizzle placeholder (Metal 13+ only)
            (void*)0,
            (unsigned long)plane,
            (void*)iosurface);
    } @catch (NSException *e) {
        fprintf(stderr, "#### MTL_TEX/%s exception reading desc: %s\n", tag, [[e description] UTF8String] ?: "?");
    }
    if (iosurface) {
        uint32_t iosfmt = IOSurfaceGetPixelFormat(iosurface);
        char fmtstr[8] = {0};
        for (int i = 0; i < 4; i++) {
            char c = (char)((iosfmt >> (24 - i * 8)) & 0xff);
            fmtstr[i] = (c >= 0x20 && c < 0x7f) ? c : '.';
        }
        size_t npl = IOSurfaceGetPlaneCount(iosurface);
        fprintf(stderr, "####     ios: w=%zu h=%zu bpr=%zu fmt=%#x(%s) elemSz=%zu allocSz=%zu planes=%zu\n",
            IOSurfaceGetWidth(iosurface),
            IOSurfaceGetHeight(iosurface),
            IOSurfaceGetBytesPerRow(iosurface),
            (unsigned)iosfmt, fmtstr,
            IOSurfaceGetElementWidth(iosurface),
            IOSurfaceGetAllocSize(iosurface),
            npl);
        for (size_t p = 0; p < npl && p < 4; p++) {
            fprintf(stderr, "####       plane[%zu]: w=%zu h=%zu bpr=%zu bpe=%zu\n",
                p,
                IOSurfaceGetWidthOfPlane(iosurface, p),
                IOSurfaceGetHeightOfPlane(iosurface, p),
                IOSurfaceGetBytesPerRowOfPlane(iosurface, p),
                IOSurfaceGetBytesPerElementOfPlane(iosurface, p));
        }
        // Dump ALL IOSurface property keys (one-shot — only on NIL traces so we
        // don't flood per-frame). The dict reveals IOSurfacePlaneCompressionType
        // and other Apple-private flags that explain WHY iOS Metal rejects it.
        if (strstr(tag, ".NIL") || strstr(tag, ".IN")) {
            CFDictionaryRef d = (CFDictionaryRef)IOSurfaceCopyAllValues(iosurface);
            if (d) {
                NSDictionary *nd = (__bridge NSDictionary *)d;
                for (id k in [nd allKeys]) {
                    NSString *desc = [nd[k] description];
                    if ([desc length] > 200) desc = [desc substringToIndex:200];
                    fprintf(stderr, "####       prop[%s] = %s\n",
                        [[k description] UTF8String] ?: "?",
                        [desc UTF8String] ?: "?");
                }
                CFRelease(d);
            }
        }
    }
}

// Empirical: macOS SkyLight on iPad asks for MTLPixelFormat=550 wrapping an
// IOSurface with FourCC '&b38' (0x26623338) — Apple-private 40-bit BGRA10_XR-like
// format used for iPad display backbuffers (5.19 bytes/pixel). iOS Metal returns
// nil for unknown private formats, so we translate 550 → public BGRA10_XR (552),
// falling back to sRGB (553), RGB10A2 (90), BGRA8 (80). The first hit wins.
//
// Translation list ordered by closeness to the source layout. Add formats here
// as new IOSurface fourCCs surface in the trace.
static const NSUInteger kMacwsTexFmt550Fallbacks[] = {
    552,  // BGRA10_XR
    553,  // BGRA10_XR_sRGB
    94,   // BGR10A2Unorm (32-bit packed, lossy width)
    90,   // RGB10A2Unorm
    80,   // BGRA8Unorm (degraded SDR)
    81,   // BGRA8Unorm_sRGB
    0
};

// SIGABRT survival scope. MTLSimDriver's sendXPCMessageWithReplySync.cold.1
// calls abort() on any XPC reply error — there is NO return path. We install a
// thread-local SIGABRT handler around the %orig call so abort()-via-pthread_kill
// becomes a recoverable siglongjmp instead of a fatal process exit. Outside the
// protected scope, abort() reverts to the system default.
static __thread sigjmp_buf macws_abort_env;
static __thread int macws_in_protected = 0;
static void macws_sigabrt_trampoline(int sig) {
    if (macws_in_protected) {
        siglongjmp(macws_abort_env, 1);
    }
    // Not in our scope — re-raise with default to give the system its abort.
    signal(SIGABRT, SIG_DFL);
    raise(SIGABRT);
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc
                                        iosurface:(IOSurfaceRef)iosurface
                                            plane:(NSUInteger)plane {
    // NO-COMPRESS (gated /tmp/macws_no_compress): disable AGX lossless compression so a dumped
    // source backing reads UNCOMPRESSED → the verified Asahi detile yields clean real content
    // (proving detile on a real GlassDemo source layer). allowGPUOptimizedContents is public Metal API.
    if (desc && access("/tmp/macws_no_compress", F_OK) == 0 &&
        [desc respondsToSelector:@selector(setAllowGPUOptimizedContents:)]) {
        [desc setAllowGPUOptimizedContents:NO];
    }
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.IN");
    }
    // FMT-CHECK (gated /tmp/macws_fmt_check): verify the texture-descriptor format vs
    // the IOSurface format for every IOSurface-backed texture — confirms (a) whether
    // the composite DEST (2000x1456 / 2388x1668) is created through THIS path, and
    // (b) the desc.pf=550 vs iosurf 'BGRA' mismatch hypothesis. Evidence before fix.
    if (iosurface && desc && access("/tmp/macws_fmt_check", F_OK) == 0) {
        static int fcn = 0;
        if (fcn++ < 60) {
            unsigned int spf = IOSurfaceGetPixelFormat(iosurface);
            fprintf(stderr, "#### FMT-CHECK %lux%lu desc.pf=%lu iosurf.pf=0x%x('%c%c%c%c') plane=%lu storage=%lu usage=0x%lx cls=%s\n",
                (unsigned long)desc.width, (unsigned long)desc.height, (unsigned long)desc.pixelFormat,
                spf, (spf>>24)&0xff, (spf>>16)&0xff, (spf>>8)&0xff, spf&0xff,
                (unsigned long)plane, (unsigned long)desc.storageMode, (unsigned long)desc.usage,
                class_getName([self class]));
            // SRC-CONTENT: sample the SOURCE IOSurface's bytes at texture-creation time. This is the
            // client's delivered window content (e.g. GlassDemo's CG-rendered pixels). nonzero>0 ⟹ the
            // client delivered + WS HAS the pixels (drop-out = composite sampling, sub-hyp b); ~0 ⟹
            // content never reached WS's surface (CARenderServer/CA receipt gap, sub-hyp a).
            @try {
                IOSurfaceLock(iosurface, 0x1 /*readonly*/, NULL);
                void *b = IOSurfaceGetBaseAddress(iosurface);
                size_t sz = IOSurfaceGetAllocSize(iosurface);
                size_t nz = 0, samp = 0;
                if (b && sz) for (size_t o = 0; o + 4 <= sz; o += 1021 * 4) { if (*(volatile uint32_t *)((char *)b + o) & 0xffffff) nz++; samp++; }
                IOSurfaceUnlock(iosurface, 0x1, NULL);
                fprintf(stderr, "####   SRC-CONTENT %lux%lu sz=%#zx base=%p nonzero=%.1f%%\n",
                    (unsigned long)IOSurfaceGetWidth(iosurface), (unsigned long)IOSurfaceGetHeight(iosurface),
                    sz, b, samp ? 100.0 * nz / samp : 0.0);
            } @catch (__unused NSException *e) {}
        }
    }
    // DEST STORAGE FORCE (gated /tmp/macws_wscd_iosurf): the type-2 dest RT texture is
    // created Private (storage=2) -> the GPU writes a private alloc and the IOSurface stays
    // empty. Force Shared (Apple Silicon's host-coherent mode) for the 2000x1456 macOS dest so
    // the GPU renders into the IOSurface itself (CPU/VNC-readable).
    if (iosurface && desc && access("/tmp/macws_wscd_iosurf", F_OK) == 0) {
        NSUInteger dw = [desc width];
        if (dw >= 1900 && dw < 2300 && [desc storageMode] == MTLStorageModePrivate) {
            [desc setStorageMode:MTLStorageModeShared];
            static int sn; if (sn++ < 4)
                fprintf(stderr, "#### DEST-STORAGE forced Shared for %lux%lu\n", (unsigned long)dw, (unsigned long)[desc height]);
        }
    }
    static int classlog = 0;
    if (classlog < 3) {
        fprintf(stderr, "#### MTL_TEX entry self class=%s\n", class_getName([self class]));
        classlog++;
    }
    // 2026-06-22 — ROOT CHURN FIX (part 2): cache window-content textures by
    // (IOSurface,plane,format,dims).
    //
    // WS::Displays::CASurface::metal_texture() calls THIS hook directly to wrap
    // each window's backing IOSurface as a Metal texture for compositing — once
    // per composite, NOT cached by SkyLight in the chroot. Every fresh wrap runs
    // -[AGXTexture initWithDevice:desc:iosurface:plane:] →
    // AGX::TextureGen4IL<layout3> ctor → AGX::Mempool<…ImageStateEncoder…>::grow,
    // whose per-index entry array (heap "B", pool+0x10) is persistently smaller
    // than heap "A" (pool+0x8). As the live-texture count climbs, grow's memmove
    // (oldcount*24 bytes) overruns heap B's source region → SIGSEGV SEGV_ACCERR
    // in _platform_memmove (RE-confirmed crash-diag: memmove ← Mempool::grow
    // lambda ← TextureGen4IL<layout3> ctor ← initImpl ← THIS hook ←
    // CASurface::metal_texture). Same heap-B-undersize root as the
    // texBaseAddressesUpdated write overrun.
    //
    // A window's backing IOSurface is stable across frames (double/triple-
    // buffered), so wrapping it ONCE and reusing the texture is correct — and it
    // bounds the AGX descriptor/encoder pools to the LIVE texture count instead
    // of letting them grow per frame. "new"-family convention: +1 to the caller
    // on every return (cache holds its own strong ref). Opt-out:
    // MACWS_NO_IOSTEX_CACHE=1. (Recursive %orig calls from this hook's fallback
    // paths go to the original AGX IMP, not back through here, so they bypass the
    // cache — only external callers like CASurface::metal_texture hit it.)
    static NSMutableDictionary<NSString *, id<MTLTexture>> *iosTexCache = nil;
    static dispatch_once_t iosTexOnce;
    dispatch_once(&iosTexOnce, ^{ iosTexCache = [NSMutableDictionary new]; });
    NSString *iosTexKey = nil;
    if (iosurface && desc && !getenv("MACWS_NO_IOSTEX_CACHE")) {
        iosTexKey = [NSString stringWithFormat:@"%p-%lu-%lux%lu-pf%lu",
            (void *)iosurface, (unsigned long)plane,
            (unsigned long)desc.width, (unsigned long)desc.height,
            (unsigned long)desc.pixelFormat];
        id<MTLTexture> hit = nil;
        @synchronized(iosTexCache) { hit = iosTexCache[iosTexKey]; }
        if (hit) {
            CFRetain((__bridge CFTypeRef)hit);  // caller's +1
            static _Atomic int iosHitN = 0;
            int hn = atomic_fetch_add(&iosHitN, 1);
            if ((hn % 256) == 0)
                fprintf(stderr, "#### MTL_TEX IOSTEX-CACHE-HIT key=%s tex=%p (#%d)\n",
                    [iosTexKey UTF8String], (void *)hit, hn);
            return hit;
        }
    }
    // AGX gate probe: log the EXACT values the 3 entry-gate IOSurface APIs
    // return for THIS surface. If our prediction is right (compType=0,
    // heightInCompTiles=0, validateWithDevice=YES) and the texture is still
    // nil, then the failure must be inside `initImplWith...` (post-gate).
    // Logged once per unique (self_class, iosurface, plane) combo to avoid
    // spam.
    if (getenv("MACWS_AGX_TEX_BYPASS_GATE") && iosurface) {
        extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        static int probelog = 0;
        if (probelog < 8) {
            uint32_t ctype = IOSurfaceGetCompressionTypeOfPlane
                ? IOSurfaceGetCompressionTypeOfPlane(iosurface, plane) : 0xFFFFFFFF;
            size_t hct = IOSurfaceGetHeightInCompressedTilesOfPlane
                ? IOSurfaceGetHeightInCompressedTilesOfPlane(iosurface, plane) : (size_t)-1;
            BOOL validOK = NO;
            @try {
                validOK = [desc respondsToSelector:@selector(validateWithDevice:)]
                    ? ((BOOL (*)(id, SEL, id))objc_msgSend)(desc,
                          @selector(validateWithDevice:), self)
                    : NO;
            } @catch (NSException *e) {
                validOK = -1; // marker that it threw
            }
            fprintf(stderr,
                "#### AGX_GATE_PROBE class=%s ios=%p plane=%lu "
                "compressionType=%u heightInCompressedTiles=%zu validateWithDevice=%d "
                "desc=(w=%lu h=%lu pf=%lu storage=%lu usage=0x%lx)\n",
                class_getName([self class]),
                (void*)iosurface, (unsigned long)plane,
                ctype, hct, (int)validOK,
                (unsigned long)desc.width, (unsigned long)desc.height,
                (unsigned long)desc.pixelFormat,
                (unsigned long)desc.storageMode, (unsigned long)desc.usage);
            probelog++;
        }
    }
    // Stash the IOSurfaceID into TLS so IOConnectCallMethod_new can inject it
    // into args[+0x30] for the sel=0xa type=0x82 path. Save/restore the
    // previous value to handle re-entry (shadow IOSurface fallback path).
    uint32_t prev_iosurface_id = macws_get_current_iosurface_id();
    macws_set_current_iosurface_id(iosurface ? IOSurfaceGetID(iosurface) : 0);
    static int tls_log = 0;
    if (tls_log < 8) {
        fprintf(stderr,
            "#### MTL_TEX TLS set iosurface=%p id=%#x (thread=%p addr=%p)\n",
            iosurface, macws_get_current_iosurface_id(), (void*)pthread_self(),
            NULL);
        tls_log++;
    }

    id<MTLTexture> result = nil;
    struct sigaction old_sa, new_sa;
    memset(&new_sa, 0, sizeof(new_sa));
    new_sa.sa_handler = macws_sigabrt_trampoline;
    sigemptyset(&new_sa.sa_mask);
    new_sa.sa_flags = SA_NODEFER;
    sigaction(SIGABRT, &new_sa, &old_sa);
    macws_in_protected = 1;
    if (sigsetjmp(macws_abort_env, 1) == 0) {
        result = [self hooked_newTextureWithDescriptor:desc iosurface:iosurface plane:plane];
    } else {
        fprintf(stderr, "#### MTL_TEX/iosurf CAUGHT SIGABRT (XPC reply error) "
            "— recovered, will fall back (w=%lu h=%lu pf=%lu ios=%p)\n",
            (unsigned long)desc.width, (unsigned long)desc.height,
            (unsigned long)desc.pixelFormat, (void*)iosurface);
        result = nil;
    }
    macws_in_protected = 0;
    sigaction(SIGABRT, &old_sa, NULL);
    // ── BINDFIX-REBIND (gated /tmp/macws_bindfix) — THE driver-level AGX-native fix ──
    // RE + runtime proof: the chroot kernel DOES assign a real GPU VA for the IOSurface (the
    // NEWBUF-PROBE: newBufferWithIOSurface→gpuAddress=0x17398d8000), but the texture render-target
    // bind writes the 0xeeee0000 placeholder VA instead (23/24 textures bind 0xeeee0000) → GPU
    // fragment writes go to a scratch page, not the IOSurface → black dest. Re-bind the full-screen
    // dest texture to the IOSurface's REAL VA (obtained via newBufferWithIOSurface, cached+retained
    // so the resource/mapping stays alive) and re-bake the PBE descriptor via updateBindData.
    if (result && iosurface && access("/tmp/macws_bindfix", F_OK) == 0) {
        int w = (int)IOSurfaceGetWidth(iosurface);
        int hh = (int)IOSurfaceGetHeight(iosurface);
        if ((uint64_t)w * hh >= 1000000) {      // any full-screen dest (panel scanout 2388 + composite 2000)
            @try {
                static NSMutableDictionary *bufcache; static dispatch_once_t bc_once;
                dispatch_once(&bc_once, ^{ bufcache = [NSMutableDictionary new]; });
                NSValue *key = [NSValue valueWithPointer:(void *)iosurface];
                id buf; @synchronized(bufcache) { buf = bufcache[key]; }
                if (!buf) {
                    typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                    buf = ((nbi_t)objc_msgSend)(self, sel_registerName("newBufferWithIOSurface:"), iosurface);
                    if (buf) { @synchronized(bufcache) { bufcache[key] = buf; } }   // retain → VA stays valid
                }
                uint64_t realVA = 0;
                if (buf) { typedef uint64_t (*ga_t)(id, SEL); realVA = ((ga_t)objc_msgSend)(buf, sel_registerName("gpuAddress")); }
                void *impl = *(void **)((char *)(__bridge void *)result + 0x208);
                uint64_t oldVA = ((uintptr_t)impl > 0x1000) ? *(uint64_t *)((char *)impl + 0x40) : 0;
                if (realVA && (uintptr_t)impl > 0x1000) {
                    void *base = IOSurfaceGetBaseAddress(iosurface);
                    uint64_t pbe_before = *(uint64_t *)((char *)impl + 0x190);
                    typedef void (*ub_t)(id, SEL, uint64_t, uint64_t, uint64_t, bool, bool);
                    ((ub_t)objc_msgSend)(result,
                        sel_registerName("updateBindDataWithAddresses:cpuMetadataAddress:gpuVirtualAddress:isCompressible:shouldInitMetadata:"),
                        (uint64_t)base, 0, realVA, false, true);
                    uint64_t newVA = *(uint64_t *)((char *)impl + 0x40);
                    uint64_t pbe_after = *(uint64_t *)((char *)impl + 0x190);
                    void *bufcont = NULL; { typedef void *(*c_t)(id, SEL); bufcont = ((c_t)objc_msgSend)(buf, sel_registerName("contents")); }
                    static int rb; if (rb++ < 6)
                        fprintf(stderr, "#### BINDFIX-REBIND dest %dx%d oldVA=%#llx realVA=%#llx impl+0x40=%#llx pbe190 %#llx->%#llx bufcont=%p iosbase=%p alias=%d\n",
                            w, (int)IOSurfaceGetHeight(iosurface), oldVA, realVA, newVA, pbe_before, pbe_after, bufcont, base, (bufcont == base) ? 1 : 0);
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (!result && desc) {
        NSUInteger orig_fmt = desc.pixelFormat;
        // Try fallback translations only for the private 550 format (and nearby
        // private values in case Apple varies). Don't retry for known public
        // formats — their nil return means a real semantic error.
        BOOL is_private = (orig_fmt >= 548 && orig_fmt <= 551);
        if (is_private) {
            for (int i = 0; kMacwsTexFmt550Fallbacks[i] != 0; i++) {
                NSUInteger try_fmt = kMacwsTexFmt550Fallbacks[i];
                desc.pixelFormat = try_fmt;
                result = [self hooked_newTextureWithDescriptor:desc iosurface:iosurface plane:plane];
                if (result) {
                    fprintf(stderr,
                        "#### MTL_TEX/iosurf translated %lu->%lu OK (w=%lu h=%lu ios=%p tex=%p)\n",
                        (unsigned long)orig_fmt, (unsigned long)try_fmt,
                        (unsigned long)desc.width, (unsigned long)desc.height,
                        (void*)iosurface, (void*)result);
                    break;
                }
            }
            desc.pixelFormat = orig_fmt; // restore so caller sees original
        }
        // Shadow IOSurface substitution: when MTLSim/AGX-native cannot wrap
        // the iPad's compressed CA Framebuffer ('&b38' FourCC, 0x26-prefixed
        // Apple lossless-compressed format), allocate a SHADOW IOSurface in
        // plain BGRA8 with the same dimensions and wrap THAT in a Metal
        // texture. SkyLight + AGX both accept BGRA8 IOSurfaces fine; the
        // shadow stays in this process's address space so VNC's compositor
        // read path (which goes via the SkyLight display surface, not the
        // iPad's IOMFB scanout) sees the new content. The original iPad
        // scanout buffer stays untouched — coexistence mode (CA_VSYNC_OFF=1)
        // keeps the iPad panel on iOS anyway, so no visible artifact there.
        //
        // Pattern mirrors misc/TestMetalIOSurface and misc/agxprobe.m's
        // stage 5: minimal IOSurfaceCreate(width, height, bpe=4, pf='BGRA').
        //
        // Cache (original IOSurface ptr → shadow IOSurface ptr) so repeated
        // calls for the same scanout buffer reuse the same shadow.
        if (!result && iosurface && desc.width > 0 && desc.height > 0) {
            uint32_t fcc = IOSurfaceGetPixelFormat(iosurface);
            BOOL is_apple_compressed = ((fcc & 0xFF000000u) == 0x26000000u);
            if (is_apple_compressed) {
                static NSMutableDictionary *shadowCache = nil;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ shadowCache = [NSMutableDictionary new]; });
                NSValue *origKey = [NSValue valueWithPointer:(void *)iosurface];
                NSValue *shadowVal;
                @synchronized(shadowCache) {
                    shadowVal = shadowCache[origKey];
                }
                IOSurfaceRef shadow = (IOSurfaceRef)[shadowVal pointerValue];
                if (!shadow) {
                    // Match the iPad CA Framebuffer's kernel-side IOSurface
                    // properties so AGX accepts our shadow for
                    // newTextureWithDescriptor:iosurface:. Without these
                    // hints the userland IOSurface lacks IOGPU memory-region
                    // metadata and AGX rejects the wrap (verified: bare
                    // BGRA8 shadow at 2388x1668 returns nil; even h=48
                    // returns nil). The properties are mirrored from the
                    // original surface's reported "CreationProperties" dict:
                    //   IOSurfaceCacheMode      = 1792  (= 0x700, kIOMapWriteCombineCache)
                    //   IOSurfaceMapCacheAttribute = 0
                    //   IOSurfaceMemoryRegion   = "PurpleGfxMem"
                    NSDictionary *props = @{
                        @"IOSurfaceWidth":              @(desc.width),
                        @"IOSurfaceHeight":             @(desc.height),
                        @"IOSurfaceBytesPerElement":    @4,
                        @"IOSurfacePixelFormat":        @((uint32_t)'BGRA'),
                        @"IOSurfaceCacheMode":          @1792,
                        @"IOSurfaceMapCacheAttribute":  @0,
                        @"IOSurfaceMemoryRegion":       @"PurpleGfxMem",
                    };
                    shadow = IOSurfaceCreate((__bridge CFDictionaryRef)props);
                    // Fall back to bare BGRA8 if the kernel rejects
                    // PurpleGfxMem from userland.
                    if (!shadow) {
                        NSDictionary *bareprops = @{
                            @"IOSurfaceWidth":           @(desc.width),
                            @"IOSurfaceHeight":          @(desc.height),
                            @"IOSurfaceBytesPerElement": @4,
                            @"IOSurfacePixelFormat":     @((uint32_t)'BGRA'),
                        };
                        shadow = IOSurfaceCreate((__bridge CFDictionaryRef)bareprops);
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem rejected, fallback bare BGRA8 = %p\n",
                                (void *)shadow);
                    } else {
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem accepted = %p\n",
                                (void *)shadow);
                    }
                    if (shadow) {
                        @synchronized(shadowCache) {
                            shadowCache[origKey] = [NSValue valueWithPointer:(void *)shadow];
                        }
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW alloc'd BGRA8 (%lux%lu) %p for orig=%p (fcc=%#x)\n",
                            (unsigned long)desc.width, (unsigned long)desc.height,
                            (void *)shadow, (void *)iosurface, (unsigned)fcc);
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW IOSurfaceCreate FAILED for %lux%lu\n",
                            (unsigned long)desc.width, (unsigned long)desc.height);
                    }
                }
                if (shadow) {
                    MTLPixelFormat orig_fmt = desc.pixelFormat;
                    desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
                    result = [self hooked_newTextureWithDescriptor:desc iosurface:shadow plane:0];
                    desc.pixelFormat = orig_fmt;
                    if (result) {
                        static int logged = 0;
                        if (logged < 8) {
                            fprintf(stderr,
                                "#### MTL_TEX/iosurf SHADOW-backed texture %p (BGRA8) for orig surf=%p\n",
                                (void *)result, (void *)iosurface);
                            logged++;
                        }
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW newTexture STILL nil — giving up\n");
                    }
                }
            }
        }
    }
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/iosurf.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.NIL");
    }
    // 2026-06-20 — Wire IOSurface base address into texture's writable
    // backing pointer ivar (cpp+0xa0) ONLY when the AGX-set pointer is
    // NULL (the failing chroot-AGX case).  Most textures already have
    // a non-NULL +0xa0 set by AGX init — leave those alone (overwriting
    // would clobber AGX's legitimate setup).  See
    // macws_wire_iosurface_base_into_texture comment at top of file.
    if (result && iosurface) {
        macws_wire_iosurface_base_into_texture(result, iosurface);
    }
    // 2026-06-20 — VNC read-path test on the IOSURFACE VARIANT.  Filling
    // our pooled ROUTE-IOSURF surfaces with gray did NOT change VNC
    // (VNC reads SkyLight's own scanout surface, not our scratch
    // surfaces).  This variant is called directly by SkyLight for its
    // display/scanout surfaces (SkyLight-allocated IOSurface in the
    // `iosurface` arg).  Fill those large ones with gray (gated 1/240)
    // — if VNC turns gray, this IS the surface VNC reads → the fix is to
    // route GPU-rendered content here.  MACWS_SURF_FILL_IOS.
    if (getenv("MACWS_SURF_FILL_IOS") && iosurface) {
        size_t iw = IOSurfaceGetWidth(iosurface);
        size_t ih = IOSurfaceGetHeight(iosurface);
        if (iw >= 1000 && ih >= 600) {
            static _Atomic int fios = 0;
            if ((atomic_fetch_add(&fios, 1) % 240) == 0) {
                IOSurfaceLock(iosurface, 0, NULL);
                void *fb = IOSurfaceGetBaseAddress(iosurface);
                size_t al = IOSurfaceGetAllocSize(iosurface);
                if (fb && al) {
                    memset(fb, 0x80, al);
                    static int l = 0;
                    if (l++ < 4)
                        fprintf(stderr,
                            "#### SURF-FILL-IOS ios=%p %zux%zu allocSize=%zu filled 0x80\n",
                            (void*)iosurface, iw, ih, al);
                }
                IOSurfaceUnlock(iosurface, 0, NULL);
            }
        }
    }
    // 2026-06-20 — CONTINUOUS display-surface fill (read-path probe).
    // Tracks every display-sized IOSurface SkyLight passes here and a single
    // bg thread re-fills them all with solid gray every 25ms, so the fill
    // survives WS's intervening (black) composites. If VNC / a CLI
    // CGDisplayCreateImage then shows gray, THIS is the surface CreateImage
    // reads → the CPU-copy bridge (final-composite backing → this surface)
    // is the fix. If it stays black, CreateImage re-composites via GPU and
    // we need the pinnedGPULocation route. Diagnostic only; gated.
    macws_disp_fill_track(result, iosurface);
    // 2026-06-20 — FEASIBILITY TEST for the "iOS app displays macOS UI"
    // architecture.  The chroot AGX GPU renders real pixels into the
    // texture's private +0xa0 backing (proven: backing nonzero, IOSurface
    // zero).  If that backing is LINEAR (impl+0x184==0), a flat memcpy of
    // it yields a correct image — which an iOS app could display from a
    // shared IOSurface.  This one-shot dump captures the backing of the
    // largest texture to a file so we can convert it to PNG and visually
    // confirm it's recognizable GlassDemo/AM UI (the decisive proof that
    // the content is CPU-readable + linear).  MACWS_DUMP_BACKING.
    if (getenv("MACWS_DUMP_BACKING") && result && iosurface) {
        size_t iw = IOSurfaceGetWidth(iosurface);
        size_t ih = IOSurfaceGetHeight(iosurface);
        size_t bpe = IOSurfaceGetBytesPerElement(iosurface);
        // Dump the first large surface whose backing has content,
        // regardless of bpe (content turned out to land in the bpe=1
        // L008 macwsallocd buffers, not the RGBA pooled ones).  Logs
        // bpe so the reader picks grayscale vs RGBA interpretation.
        if (iw >= 1000 && ih >= 600 && bpe >= 1) {
            static _Atomic int dumped = 0;
            if (atomic_load(&dumped) == 0) {
                // _impl ivar offset (RE-confirmed 0x208), → C++ obj.
                void *impl = *(void **)((char *)(__bridge void *)result + 0x208);
                if (impl && (uintptr_t)impl > 0x1000) {
                    void *backing = *(void **)((char *)impl + 0xa0);
                    uint32_t stride = *(uint32_t *)((char *)impl + 0xa8);
                    uint8_t  layout = *(uint8_t  *)((char *)impl + 0x184);
                    // Only dump a backing that actually has content in its
                    // first 4 KB (skip cleared/staging textures).
                    int nz = 0;
                    if (backing && (uintptr_t)backing > 0x1000) {
                        for (int i = 0; i < 4096; i++)
                            if (((volatile uint8_t*)backing)[i]) { nz++; }
                    }
                    fprintf(stderr,
                        "#### DUMP-BACKING tex=%p impl=%p backing=%p stride=%u "
                        "layout=%u  %zux%zu bpe=%zu first4Knz=%d (linear iff layout==0)\n",
                        (void*)result, impl, backing, stride, layout,
                        iw, ih, bpe, nz);
                    if (backing && (uintptr_t)backing > 0x1000 && nz > 0) {
                        atomic_store(&dumped, 1);
                        size_t rowbytes = stride ? stride : iw * bpe;
                        size_t total = rowbytes * ih;
                        if (total > 64u*1024*1024) total = 64u*1024*1024; // cap
                        FILE *f = fopen("/tmp/composite_backing.raw", "wb");
                        if (f) {
                            // header line so the reader knows geometry
                            fprintf(f, "MACWSDUMP w=%zu h=%zu bpe=%zu stride=%zu layout=%u\n",
                                    iw, ih, bpe, rowbytes, layout);
                            size_t wrote = fwrite(backing, 1, total, f);
                            fclose(f);
                            fprintf(stderr,
                                "#### DUMP-BACKING wrote %zu/%zu bytes → /tmp/composite_backing.raw\n",
                                wrote, total);
                        } else {
                            fprintf(stderr, "#### DUMP-BACKING fopen failed errno=%d\n", errno);
                        }
                    }
                }
            }
        }
    }
    // Cache the freshly-wrapped texture by (IOSurface,plane,fmt,dims) so the
    // next composite reuses it instead of re-running AGXTexture init (which
    // grows the AGX encoder/descriptor pools per frame → eventual heap-B
    // overrun). The dictionary retains it (+1, held for process lifetime);
    // `result` keeps the +1 it came with for the caller. See the cache-check
    // block at the top of this method.
    if (result && iosTexKey) {
        @synchronized(iosTexCache) {
            if (!iosTexCache[iosTexKey]) {
                iosTexCache[iosTexKey] = result;
                static _Atomic int iosNewN = 0;
                int nn = atomic_fetch_add(&iosNewN, 1);
                if (nn < 16 || (nn % 64) == 0)
                    fprintf(stderr, "#### MTL_TEX IOSTEX-CACHE-NEW key=%s tex=%p (#%d)\n",
                        [iosTexKey UTF8String], (void *)result, nn);
            }
        }
    }
    macws_set_current_iosurface_id(prev_iosurface_id);
    return result;
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, NULL, 0, "plain.IN");
    }
    // FMT-CHECK-PLAIN (gated /tmp/macws_fmt_check): find where the pf=550 macOS
    // composite dest (2000x1456) is created — it's NOT in the iosurface swizzle, so
    // it's likely a PLAIN (no-IOSurface) creation. Dest-sized textures only.
    if (desc && access("/tmp/macws_fmt_check", F_OK) == 0) {
        static int pfcn = 0;
        NSUInteger w = [desc width], h = [desc height];
        if ((unsigned long)w * h > 500000 && pfcn++ < 40)
            fprintf(stderr, "#### FMT-CHECK-PLAIN %lux%lu desc.pf=%lu storage=%lu usage=0x%lx cls=%s\n",
                (unsigned long)w, (unsigned long)h, (unsigned long)[desc pixelFormat],
                (unsigned long)[desc storageMode], (unsigned long)[desc usage],
                class_getName([self class]));
    }
    // ── 2026-06-23 DEST-IOSURF FIX (the texture wall) ──
    // RE-confirmed (agent): the macOS compose-DEST is a PLAIN render target (no
    // IOSurface) created in WS::SurfacePool::Acquire@0x185135d7c via
    // -[newTextureWithDescriptor:]. The GPU renders into its private backing; the
    // scanout IOSurface (separate) stays empty → the display is black. Sources are
    // IOSurface-backed and render fine. Fix: back the full-screen dest render target
    // with an IOSurface so the GPU writes readable memory (the texture's GPU VA
    // impl+0x40 becomes the IOSurface's). Keep desc.pixelFormat so the compositor's
    // render-pipeline color-attachment format still matches. Gated /tmp/macws_dest_iosurf
    // for A/B; nil-fallback to the plain texture if the IOSurface wrap fails.
    if (desc && access("/tmp/macws_dest_iosurf", F_OK) == 0) {
        NSUInteger dw = [desc width], dh = [desc height];
        NSUInteger dusage = [desc usage], dsm = [desc storageMode];
        unsigned long dpf = (unsigned long)[desc pixelFormat];
        static int destn = 0;
        if (dw * dh >= 1000000 && (dusage & MTLTextureUsageRenderTarget) && dsm != 3 && destn < 12) {
            destn++;
            fprintf(stderr, "#### DEST-IOSURF candidate #%d %lux%lu pf=%lu usage=0x%lx sm=%lu cls=%s\n",
                destn, (unsigned long)dw, (unsigned long)dh, dpf, (unsigned long)dusage,
                (unsigned long)dsm, class_getName([self class]));
            NSDictionary *props = @{
                @"IOSurfaceWidth": @(dw), @"IOSurfaceHeight": @(dh),
                @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
                @"IOSurfaceCacheMode": @1792, @"IOSurfaceMapCacheAttribute": @0,
                @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
            };
            IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (!surf) {
                NSDictionary *bp = @{ @"IOSurfaceWidth": @(dw), @"IOSurfaceHeight": @(dh),
                    @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA') };
                surf = IOSurfaceCreate((__bridge CFDictionaryRef)bp);
            }
            if (surf) {
                id<MTLTexture> t = nil;
                @try { t = [self newTextureWithDescriptor:desc iosurface:surf plane:0]; }
                @catch (__unused NSException *e) { t = nil; }
                CFRelease(surf);   // texture holds its own ref
                if (t) {
                    fprintf(stderr, "#### DEST-IOSURF redirected -> IOSurface-backed tex=%p\n", (void *)t);
                    return t;
                }
                fprintf(stderr, "#### DEST-IOSURF iosurface wrap returned nil — falling back to plain\n");
            }
        }
    }
    // BLUR-PATH DIAG (gated /tmp/macws_textrace_file): does the CA::OGL backdrop-blur
    // create_texture reach THIS hook (→ routing gap, fixable) or bypass it via a cached
    // IMP (→ need a deterministic hook)? Log QuartzCore-caller plain-newTexture calls to
    // an append file (survives the crash) with descriptor + caller symbol.
    if (access("/tmp/macws_textrace_file", F_OK) == 0) {
        void *ra[4] = { __builtin_return_address(0), __builtin_return_address(1),
                        __builtin_return_address(2), __builtin_return_address(3) };
        const char *qcsym = NULL;
        for (int i = 0; i < 4; i++) {
            Dl_info di;
            if (ra[i] && dladdr(ra[i], &di) && di.dli_fname && strstr(di.dli_fname, "QuartzCore")) {
                qcsym = di.dli_sname ? di.dli_sname : "QuartzCore?"; break;
            }
        }
        if (qcsym) {
            NSUInteger w  = [desc respondsToSelector:@selector(width)] ? [desc width] : 0;
            NSUInteger h  = [desc respondsToSelector:@selector(height)] ? [desc height] : 0;
            NSUInteger pf = [desc respondsToSelector:@selector(pixelFormat)] ? [desc pixelFormat] : 0;
            NSUInteger tt = [desc respondsToSelector:@selector(textureType)] ? [desc textureType] : 0;
            NSUInteger sm = [desc respondsToSelector:@selector(storageMode)] ? [desc storageMode] : 0;
            int fd = open("/tmp/macws_qctex.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) { char b[224];
                int n = snprintf(b, sizeof b, "QCTEX w=%lu h=%lu pf=%lu type=%lu storage=%lu caller=%s\n",
                                 (unsigned long)w,(unsigned long)h,(unsigned long)pf,(unsigned long)tt,(unsigned long)sm,qcsym);
                if (n > 0) write(fd, b, (size_t)n); close(fd); }
        }
    }
    // 2026-06-20 — Block the plain newTextureWithDescriptor path from
    // entering AGX kernel. -[AGXTexture init...] has a cascade of
    // missing selectors (validateWithDevice:, isMemoryless,
    // protectionOptions, getCPUSizeBytes, getAlignment, descriptorPrivate,
    // getBytesPerRow, finalizeTextureCreation, updateBindData...,
    // allocBufferSubData..., initNewTextureData:) that chroot's loaded
    // class hierarchy doesn't fully implement. Even with 22 stubs added
    // via class_addMethod the cascade still cascades because some
    // receivers are internal subclasses. Plus the synth-buffer-as-texture
    // pattern triggers iOS kernel panics. Returning nil here is SAFER —
    // SkyLight's PrepareForUse tolerate-nil + WSCompositeDestination
    // CreateWithMetalTexture nil-tolerate hooks handle the nil cascade
    // gracefully; that composite layer is skipped instead of crashing WS.
    // The iosurface variant (hooked_newTextureWithDescriptor:iosurface:plane:)
    // still works because the descriptor + IOSurface together fully define
    // the texture and AGXTexture init's checks pass for that path.
    // Env opt-out via MACWS_AGX_KEEP_PLAIN_NEWTEX=1 for A/B testing.
    if (getenv("MACWS_AGX_NATIVE") &&
        !getenv("MACWS_AGX_KEEP_PLAIN_NEWTEX")) {
        if (access("/tmp/macws_plaintex_log", F_OK) == 0) { static int pl = 0; if (pl++ < 40) {
            NSUInteger pw = [desc respondsToSelector:@selector(width)] ? [desc width] : 0, ph = [desc respondsToSelector:@selector(height)] ? [desc height] : 0;
            NSUInteger pu = [desc respondsToSelector:@selector(usage)] ? [desc usage] : 0, ps = [desc respondsToSelector:@selector(storageMode)] ? [desc storageMode] : 0;
            NSUInteger pp = [desc respondsToSelector:@selector(pixelFormat)] ? [desc pixelFormat] : 0, pt = [desc respondsToSelector:@selector(textureType)] ? [desc textureType] : 2;
            fprintf(stderr, "#### PLAIN-NEWTEX #%d %lux%lu pf=%lu usage=%#lx sm=%lu tt=%lu\n", pl, (unsigned long)pw, (unsigned long)ph, (unsigned long)pp, (unsigned long)pu, (unsigned long)ps, (unsigned long)pt); } }
        // 2026-06-20 — Route plain newTextureWithDescriptor through the
        // iosurface variant (the known-working path). Create a chroot-
        // local IOSurface sized to the descriptor, then delegate to
        // hooked_newTextureWithDescriptor:iosurface:plane: which goes
        // through the iosurface-init code path (avoids the missing
        // selector cascade in -[AGXTexture initWithDevice:desc:
        // isSuballocDisabled:]).
        //
        // EXCEPTION: memoryless textures (storageMode = 3). SkyLight's
        // AddMemorylessTarget at MetalContext.mm:918 asserts that the
        // returned texture is a memoryless target; IOSurface-backed
        // textures have real memory, so the assert fails. For memoryless
        // requests, swap storageMode to Private (2) — same lifecycle
        // characteristics from SkyLight's POV (no CPU access), but
        // backed by real GPU memory (transparent to caller).
        // 2026-06-20 — Memoryless texture handling research notes:
        //
        // What memoryless IS (Apple TBDR architecture, Metal docs):
        //   storageMode = MTLStorageModeMemoryless (3): the texture has
        //   NO system memory backing.  Tile memory is allocated by the
        //   AGX scheduler at render-pass-encode time; tile SRAM is reused
        //   across passes.  Texture metadata (size, format, usage) lives
        //   in CPU memory; pixel storage lives ONLY in on-chip SRAM
        //   during one render pass.
        //
        // What goes wrong if we ROUTE-IOSURF a memoryless request:
        //   We allocate a 31 MB IOSurface for a 2388×1668 RGBA16Float
        //   "memoryless" texture — totally defeating the point.  CA::OGL::
        //   MetalContext::add_memoryless_textures requests one per composite
        //   cycle, cumulative 46+ GB → 5120 MB WS watermark trip.
        //
        // Correct fix: route memoryless requests THROUGH the native
        // AGX-side newTextureWithDescriptor (no IOSurface).  Post-swizzle,
        // [self hooked_newTextureWithDescriptor:desc] calls the original
        // AGXG13GFamilyDevice IMP.  That IMP eventually reaches AGXTexture
        // init which queries [super isMemoryless] on the IOGPUMetalTexture
        // instance; iff storageMode=3 in the descriptor, the texture
        // creation skips physical backing allocation and stays as pure
        // tile-memory metadata (handled by iOS AGX kernel at render time).
        NSUInteger storageMode = [desc respondsToSelector:@selector(storageMode)]
                                 ? [desc storageMode] : 0;
        // === COMPOSITE-DEST COMBINE FIX (regression 4382d8f, RE-confirmed 2026-06-24) ===
        // The SkyLight compositor combine DEST is a PLAIN, full-screen RENDER TARGET. In the
        // glass4.png era (58dd895) the plain hook passed it to the NATIVE AGX driver, so the GPU
        // combine wrote pixels the scanout/+0xa0 readback could see. 4382d8f rerouted ALL plain
        // textures (incl. the dest) through a synth chroot IOSurface -> the dest detached from the
        // scanout binding -> +0xa0 reads 0%. Route the DEST (large render target) back to NATIVE
        // AGX; keep ROUTE-IOSURF for the small intermediate textures. A/B opt-out: MACWS_NO_DEST_NATIVE.
        {
            NSUInteger dw = [desc respondsToSelector:@selector(width)]  ? [desc width]  : 0;
            NSUInteger dh = [desc respondsToSelector:@selector(height)] ? [desc height] : 0;
            NSUInteger du = [desc respondsToSelector:@selector(usage)]  ? [desc usage]  : 0;
            if (!getenv("MACWS_NO_DEST_NATIVE") && dw * dh >= 1000000 &&
                (du & MTLTextureUsageRenderTarget) && storageMode != 3) {
                id<MTLTexture> dtex = [self hooked_newTextureWithDescriptor:desc];   // native AGX dest (glass4.png path)
                static int dlog = 0;
                if (dlog++ < 8)
                    fprintf(stderr, "#### DEST-NATIVE %lux%lu usage=%#lx sm=%lu -> native AGX render target (combine fix) = %p\n",
                            (unsigned long)dw, (unsigned long)dh, (unsigned long)du, (unsigned long)storageMode, (void *)dtex);
                if (dtex) return dtex;   // native returned a usable dest; else fall through to ROUTE-IOSURF
            }
        }
        // 2026-06-20 — Texture-type gate: ROUTE-IOSURF can ONLY back
        // MTLTextureType2D or MTLTextureType2DArray (Metal's IOSurface
        // texture validation enforces this with assertion
        // _mtlValidateStrideTextureParameters:1843 'IOSurface texture:
        // must be of type MTLTextureType2D or linear MTLTextureType2DArray').
        // CA can request 3D / Cube / Multisample textures for compositor
        // intermediates — wrapping those in an IOSurface SIGABRTs WS.
        // For any non-2D/non-2DArray request, fall through to the native
        // AGXG13GFamilyDevice path (which handles the type correctly).
        NSUInteger texType = [desc respondsToSelector:@selector(textureType)]
                             ? [desc textureType] : 2 /* default 2D */;
        if (texType != 2 /* 2D */ && texType != 3 /* 2DArray */) {
            // 2026-06-20 evening — Native path attempt for non-2D textures.
            //
            // RE of -[AGXTexture initWithDevice:desc:isSuballocDisabled:]
            // (static 0x1e5a5b7a0) shows the cascade SHOULD work with our
            // existing stubs because:
            //   - validateWithDevice: → stubbed YES ✓
            //   - initImpl (10-arg) → AGXG13GFamilyTexture native ✓
            //   - initNewTextureData:, isMemoryless, getCPUSizeBytes,
            //     getAlignment, getBytesPerRow, finalizeTextureCreation,
            //     updateBindDataWithAddresses:... → AGXTexture has NATIVE
            //     impls (our stubs are added to IOGPUMetalTexture and are
            //     shadowed by AGXTexture's parent-class natives).
            //   - allocBufferSubDataWithLength:... → IOGPUMetalDevice native
            //     (iOS IOGPU framework, present in chroot).
            //
            // Try the native path FIRST.  If it returns a usable texture,
            // great.  If it returns nil or a corrupt object that crashes
            // in setFragmentTexture, fall back to the 2D-downgrade safe
            // path so WS stays up.
            //
            // We can't safely detect "corrupt object" at return time, so
            // env-gate this experiment behind MACWS_AGX_NATIVE_NON2D=1.
            // Default OFF until proven safe.
            if (getenv("MACWS_AGX_NATIVE_NON2D")) {
                static int native_log = 0;
                if (native_log++ < 6) {
                    fprintf(stderr,
                        "#### MTL_TEX plain NON-2D native attempt: texType=%lu\n",
                        (unsigned long)texType);
                }
                id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
                if (native_log < 8) {
                    fprintf(stderr,
                        "#### MTL_TEX plain NON-2D native result: %p class=%s\n",
                        (void *)tex, tex ? class_getName([tex class]) : "(nil)");
                }
                if (tex) return tex;
                // fall through to 2D downgrade if nil
            }
            // 2026-06-20 — Real implementation for non-2D textures (Cube, 3D, etc.).
            //
            // The chroot AGX framework's path for non-2D texture creation goes
            // through AGXTexture init with selectors that aren't all resolvable
            // in our stub cascade (returns a corrupt-but-non-nil texture that
            // SIGSEGVs in AGX::ResourceGroupUsage::setTexture).  IOSurface
            // backing is 2D-only per Metal validation, so we can't route the
            // original descriptor through ROUTE-IOSURF either.
            //
            // Solution: downgrade the descriptor to textureType=2 (2D) so the
            // existing ROUTE-IOSURF path (which IS proven to work end-to-end)
            // can build a real AGXG13GFamilyTexture instance.  The returned
            // texture is functionally 2D, but for CA's primary non-2D use case
            // — encode_placeholder_cube binding a 1×1×1 cube as a placeholder —
            // the texture is only BOUND (slot occupied), never SAMPLED with
            // 3D coordinates from a real shader path.  AGX::setTexture only
            // reads the texture's ivar layout (which is correct for a 2D
            // texture) and writes the binding slot.
            //
            // For sampled-from-shader non-2D textures (e.g. CA's actual cube
            // map for backdrop reflections, or genuine 3D LUTs), this still
            // hands back a valid object that responds to all MTLTexture
            // protocol queries — width / height / pixelFormat report what
            // the caller asked for; only depth/textureType are 2D-ish.
            // Sampling will read wrong data but won't crash.  That's the
            // right trade-off for chroot — visual correctness for non-2D
            // effects is a separate fix beyond plain texture creation.
            static int nontex2d_log = 0;
            if (nontex2d_log++ < 6) {
                fprintf(stderr,
                    "#### MTL_TEX plain NON-2D: texType=%lu → downgrading to 2D "
                    "(IOSurface backing is 2D-only; native AGXTexture init's "
                    "cascade returns a corrupt non-2D texture that SIGSEGVs in "
                    "setFragmentTexture). The result is a real bindable 2D "
                    "AGXG13GFamilyTexture; CA's placeholder bind needs a "
                    "non-nil tex but doesn't actually sample it.\n",
                    (unsigned long)texType);
            }
            if ([desc respondsToSelector:@selector(setTextureType:)]) {
                [desc setTextureType:2 /* MTLTextureType2D */];
            }
            // Continue down to the ROUTE-IOSURF path below.
        }
        if (storageMode == 3 /* MTLStorageModeMemoryless */) {
            // 2026-06-22 — ROOT FIX for the WS coexist crash-loop.
            //
            // Memoryless render targets were created FRESH on every composite
            // (this native AGX path has no cache, unlike the IOSurface path
            // below). Each fresh -[AGXTexture initWithDevice:desc:...] grabs a
            // new AGX descriptor-table slot (w9 = *(tex+0x1c0)). The per-frame
            // churn drove w9 monotonically to 682, which overflowed the
            // layout-3 device descriptor heap B (a single 16 KB page, capacity
            // 682 entries) inside
            //   AGX::TextureGen4IL<AGXTextureMemoryLayout3,…>::texBaseAddressesUpdated
            // → store across the page boundary into a read-only page →
            // SIGSEGV SEGV_ACCERR → WS dies (no .ips; ReportCrash is dead on
            // this device). RE-confirmed via the in-process crash-diag handler:
            //   texBaseAddressesUpdated ← AGXTexture init ← THIS native path
            //   ← MetalContext::StartComposite ← CompositorMetal::composite.
            //
            // Memoryless textures have NO persistent contents — their storage
            // is tile SRAM allocated by the AGX scheduler at render-pass-encode
            // time and reused across passes — so REUSING the same texture
            // object across passes is correct (the next pass fully overwrites
            // it; there is nothing to preserve). Pool a small ROUND-ROBIN set
            // per (w,h,pf,texType): this bounds the live texture count
            // (≈ MEMLESS_RING × unique dims) so w9 stops climbing and the
            // descriptor heap never overflows. Round-robin (vs a single cached
            // object) keeps consecutive requests distinct so a single pass that
            // binds two same-size memoryless attachments (e.g. blur ping-pong)
            // never gets the same object twice. This RECYCLES slots at the root
            // — it is not a nop of the overflowing store. Opt-out:
            // MACWS_NO_MEMLESS_POOL=1 (A/B back to per-call fresh creation).
            if (getenv("MACWS_NO_MEMLESS_POOL")) {
                return [self hooked_newTextureWithDescriptor:desc];
            }
            NSUInteger mw  = [desc respondsToSelector:@selector(width)]       ? [desc width]       : 0;
            NSUInteger mh  = [desc respondsToSelector:@selector(height)]      ? [desc height]      : 0;
            NSUInteger mpf = [desc respondsToSelector:@selector(pixelFormat)] ? [desc pixelFormat] : 0;
            NSUInteger mtt = [desc respondsToSelector:@selector(textureType)] ? [desc textureType] : 2;
            const NSUInteger MEMLESS_RING = 4;
            NSString *mkey = [NSString stringWithFormat:@"%lux%lu-pf%lu-tt%lu",
                (unsigned long)mw, (unsigned long)mh, (unsigned long)mpf, (unsigned long)mtt];
            static NSMutableDictionary<NSString *, NSMutableArray *> *memlessPool = nil;
            static NSMutableDictionary<NSString *, NSNumber *> *memlessIdx = nil;
            static dispatch_once_t memlessOnce;
            dispatch_once(&memlessOnce, ^{
                memlessPool = [NSMutableDictionary new];
                memlessIdx  = [NSMutableDictionary new];
            });
            id<MTLTexture> tex = nil;
            BOOL grew = NO;
            @synchronized(memlessPool) {
                NSMutableArray *ring = memlessPool[mkey];
                if (!ring) { ring = [NSMutableArray new]; memlessPool[mkey] = ring; }
                if (ring.count < MEMLESS_RING) {
                    // Grow the ring with a fresh native memoryless texture.
                    tex = [self hooked_newTextureWithDescriptor:desc];  // +1, ARC-owned local
                    if (tex) { [ring addObject:tex]; grew = YES; }       // pool keeps a strong ref
                } else {
                    NSUInteger i = [memlessIdx[mkey] unsignedIntegerValue];
                    tex = ring[i % ring.count];
                    memlessIdx[mkey] = @(i + 1);
                }
            }
            // "new"-family convention: hand the caller its own +1 it can release.
            if (tex) CFRetain((__bridge CFTypeRef)tex);
            static _Atomic int memlessN = 0;
            int mn = atomic_fetch_add(&memlessN, 1);
            if (grew || (mn % 128) == 0) {
                fprintf(stderr,
                    "#### MTL_TEX MEMLESS-POOL %s key=%s ring=%lu call#%d tex=%p\n",
                    grew ? "NEW" : "REUSE", [mkey UTF8String],
                    (unsigned long)[memlessPool[mkey] count], mn, (void *)tex);
            }
            return tex;
        }
        NSUInteger width  = [desc respondsToSelector:@selector(width)]
                            ? [desc width] : 0;
        NSUInteger height = [desc respondsToSelector:@selector(height)]
                            ? [desc height] : 0;
        NSUInteger pf     = [desc respondsToSelector:@selector(pixelFormat)]
                            ? [desc pixelFormat] : 80; // MTLPixelFormatBGRA8Unorm default
        if (width == 0 || height == 0) {
            static int bad_log = 0;
            if (bad_log++ < 4)
                fprintf(stderr,
                    "#### MTL_TEX plain ROUTE-IOSURF: bad descriptor "
                    "(w=%lu h=%lu) — returning nil\n",
                    (unsigned long)width, (unsigned long)height);
            return nil;
        }
        // Map MTLPixelFormat → IOSurface bytes-per-element + format4cc.
        // For now assume BGRA8/RGBA8 (4 bpp) which covers SkyLight's
        // composite path. More formats can be added as needed.
        uint32_t fmt4cc  = 'BGRA';
        NSUInteger bpe   = 4;
        // Common cases:
        //   MTLPixelFormatBGRA8Unorm        = 80   (default)
        //   MTLPixelFormatRGBA8Unorm        = 70
        //   MTLPixelFormatBGRA8Unorm_sRGB   = 81
        //   MTLPixelFormatRGBA16Float       = 115  (8 bpp)
        //   MTLPixelFormatR8Unorm           = 10   (1 bpp)
        if (pf == 115) { fmt4cc = 'RGhA'; bpe = 8; }
        else if (pf == 10) { fmt4cc = 'L008'; bpe = 1; }
        else if (pf == 70 || pf == 71) { fmt4cc = 'RGBA'; bpe = 4; }
        // 2026-06-21 — wide-color/extended-range formats CA uses for the
        // backdrop-blur path. BGRA10_XR (552) / BGRA10_XR_sRGB (553) are
        // 64-bit (8 bytes/pixel); without this they fell to the default
        // bpe=4 → IOSurface bytesPerRow = w*4, which is HALF what Metal
        // requires → `_mtlValidateStrideTextureParameters:1843 IOSurface
        // texture: bytesPerRow must be >= ...` assertion → WS abort
        // (runtime-confirmed: 64x64 pf552 gave bpr 256, needed 512).
        // BGR10_XR (554) / BGR10_XR_sRGB (555) are 32-bit packed (4 bytes,
        // the default is already correct).
        else if (pf == 552 || pf == 553) { fmt4cc = 'b3a8'; bpe = 8; }
        // 2026-06-20 — IOSurface pool keyed by (w,h,pf,fmt4cc,bpe) to
        // bound WS memory growth.  Previously ROUTE-IOSURF allocated a
        // fresh 31 MB IOSurface per newTextureWithDescriptor call,
        // accumulating ~25 MB/sec → 5 GB in ~3 min → iOS Jetsam fires
        // → WS killed.  Pool ensures repeated requests for same
        // (w,h,pf) reuse the same surface (bounded by # unique
        // dimensions, typically 10-30 for SkyLight compositor —
        // ~300-900 MB total cap).
        //
        // Aliasing concern: multiple textures wrapping the same
        // IOSurface alias its memory.  For SkyLight's compositor, the
        // SAME (w,h,pf) is the canonical scratch surface (one per layer
        // type) and textures are used serially — last-write-wins is
        // acceptable.  If concurrent access causes visual tearing, the
        // tradeoff (tearing vs OOM-kill) still favors pooling.
        //
        // Lifetime: IOSurfaces stay in pool forever (WS process
        // lifetime).  Metal retains them via texture-internal refs;
        // pool holds an extra retain to keep them stable across
        // texture release cycles.  CFBridgingRetain to make ObjC
        // retain the IOSurfaceRef in a NSValue wrapper.
        NSString *poolKey = [NSString stringWithFormat:@"%lux%lu-pf%lu-bpe%lu-fcc%u",
            (unsigned long)width, (unsigned long)height,
            (unsigned long)pf, (unsigned long)bpe, (unsigned)fmt4cc];
        static NSMutableDictionary<NSString *, NSValue *> *surfPool = nil;
        static dispatch_once_t surfPoolOnce;
        dispatch_once(&surfPoolOnce, ^{ surfPool = [NSMutableDictionary new]; });
        IOSurfaceRef surf = NULL;
        @synchronized(surfPool) {
            NSValue *v = surfPool[poolKey];
            if (v) {
                surf = (IOSurfaceRef)[v pointerValue];
            }
        }
        static int route_log = 0;
        if (!surf) {
            // 2026-06-20 17:16 — IOSurface props with NON-SCANOUT hints
            // to prevent DCP (Display Coprocessor) RTKit firmware OOM
            // panic (panic-full-2026-06-20-171622.000.ips: DCP PANIC
            // CXXnew:2208 - iomfb_ap_callee_0(21)).
            //
            // Each IOSurface registered via AGXIOC sel=0xa type=0x82
            // can be added to DCP's scanout-source registry — DCP's
            // bounded RTKit heap fills up with our chroot's IOSurfaces
            // and panics, rebooting the device.  IOSurfaceIsGlobal:NO
            // keeps the surface out of the cross-process / DCP path.
            //
            //   IOSurfaceIsGlobal: NO         — not cross-process; AGX
            //                                  doesn't need to share it
            //                                  with DCP for display
            //   IOSurfaceCacheMode: 0         — default cached (NOT
            //                                  WriteCombineCache 0x700,
            //                                  which signals "for display
            //                                  engine consumption")
            //
            // 2026-06-20 17:56 — REMOVED IOSurfaceNonPurgeable:YES.
            // RE'd from WindowServer-2026-06-20-175357.ips
            // (MTLPipelineDataCache::getElement → malloc → memmove(NULL)
            // crash with ktriageinfo "pmap_enter retried due to resource
            // shortage" x4).  vm_stat showed 1.76 GB free but 983 MB
            // WIRED — the NonPurgeable hint wired every pooled 31 MB
            // IOSurface permanently, exhausting pmap PTE-page resources
            // so a small Metal pipeline-cache malloc returned NULL and
            // Metal's getElement memmove'd into it unchecked.  The
            // surfaces don't need wiring; purgeable (default) lets the
            // kernel manage them and keeps pmap pressure down.  Also
            // removed the speculative ElementWidth/Height:1 hints (no
            // measured effect on DCP registration).
            NSDictionary *props = @{
                @"IOSurfaceWidth":           @(width),
                @"IOSurfaceHeight":          @(height),
                @"IOSurfaceBytesPerElement": @(bpe),
                @"IOSurfacePixelFormat":     @((uint32_t)fmt4cc),
                @"IOSurfaceIsGlobal":        @NO,
                @"IOSurfaceCacheMode":       @0,
            };
            surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (surf) {
                @synchronized(surfPool) {
                    // Re-check (double-checked locking) — another
                    // thread may have raced and inserted.
                    NSValue *vNow = surfPool[poolKey];
                    if (vNow) {
                        // Lost the race — release our surf and use the
                        // pooled one.
                        CFRelease(surf);
                        surf = (IOSurfaceRef)[vNow pointerValue];
                    } else {
                        // We're the inserter — surf already has +1 ref
                        // from IOSurfaceCreate; pool holds that ref for
                        // process lifetime.  Don't CFRelease later in
                        // this branch.
                        surfPool[poolKey] = [NSValue valueWithPointer:(const void *)surf];
                    }
                }
                if (route_log++ < 16) {
                    fprintf(stderr,
                        "#### MTL_TEX POOL-NEW: key=%s → IOSurface=%p (size~%lu KB)\n",
                        [poolKey UTF8String], (void *)surf,
                        (unsigned long)(width * height * bpe / 1024));
                }
                // DIAG (gated /tmp/macws_route_log): dump the ACTUAL IOSurface
                // geometry vs the requested descriptor, so we can derive the
                // stride rule _mtlValidateStrideTextureParameters enforces for
                // the AGX texture-over-IOSurface wrap (file-log survives abort).
                if (access("/tmp/macws_route_log", F_OK) == 0) {
                    size_t surfBpr = IOSurfaceGetBytesPerRow(surf);
                    size_t surfBpe = IOSurfaceGetBytesPerElement(surf);
                    size_t surfEw  = IOSurfaceGetElementWidth(surf);
                    size_t surfEh  = IOSurfaceGetElementHeight(surf);
                    size_t surfAlloc = IOSurfaceGetAllocSize(surf);
                    char rl[320];
                    int rn = snprintf(rl, sizeof rl,
                        "ROUTE pf=%lu w=%lu h=%lu reqBpe=%lu → surfBpr=%zu surfBpe=%zu "
                        "elemW=%zu elemH=%zu alloc=%zu (need w*reqBpe=%lu)\n",
                        (unsigned long)pf, (unsigned long)width, (unsigned long)height,
                        (unsigned long)bpe, surfBpr, surfBpe, surfEw, surfEh, surfAlloc,
                        (unsigned long)(width * bpe));
                    int rfd = open("/tmp/macws_route.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
                    if (rfd >= 0) { if (rn > 0) write(rfd, rl, (size_t)rn); close(rfd); }
                }
            }
        } else {
            if (route_log++ < 16) {
                fprintf(stderr,
                    "#### MTL_TEX POOL-HIT: key=%s → IOSurface=%p\n",
                    [poolKey UTF8String], (void *)surf);
            }
        }
        if (!surf) return nil;
        // 2026-06-20 17:20 — MTLTexture cache by IOSurface (DCP-OOM fix
        // companion).  Each newTextureWithDescriptor:iosurface:plane:
        // call triggers fresh AGXIOC sel=0x9/0xa type=0x82 — visible in
        // WindowServer.err: every POOL-HIT is still followed by another
        // AGXIOC type=0x82 patch + ResCreate.  Each sel=0xa registers
        // a fresh IOGPUMetalResource for the same IOSurface, which AGX
        // may forward to DCP's scanout-source registry (root cause of
        // panic-full-2026-06-20-171622.000.ips).
        //
        // Cache the MTLTexture by IOSurfaceRef.  Since pool guarantees
        // same surface → same dimensions, returning the cached texture
        // for the same surf is shape-safe.  Repeated creates → ZERO
        // additional AGXIOC sel=0xa → ZERO DCP-registry growth.
        //
        // 2026-06-20 17:46 — ARC-correct retain on cache HIT.  Naming
        // convention: methods starting with "new" return +1 retain.
        // Without explicit retain, callers ARC-release → texture
        // refcount drops past 0 → next [MTLResourceList
        // releaseAllObjectsAndReset] → objc_release on dangling ptr →
        // SIGSEGV (WindowServer-2026-06-20-174649.ips faultingThread
        // crash at FAR=0x20 inside objc_release+16, called from
        // MTLResourceListChunkFreeEntries).  Fix: CFRetain on cache
        // HIT so each caller still gets +1 it can release.  On
        // CACHE-NEW the texture comes from %orig at +1 already (Apple
        // ARC convention).
        static NSMutableDictionary<NSValue *, id<MTLTexture>> *texCache = nil;
        static dispatch_once_t texCacheOnce;
        dispatch_once(&texCacheOnce, ^{ texCache = [NSMutableDictionary new]; });
        NSValue *texKey = [NSValue valueWithPointer:(const void *)surf];
        id<MTLTexture> tex = nil;
        @synchronized(texCache) {
            tex = texCache[texKey];
        }
        static int texCacheLog = 0;
        if (tex) {
            // Cache hit — give caller its expected +1 ARC retain.  The
            // dictionary's retain keeps tex alive across the
            // CFRetain → ARC-balanced via CFBridgingRelease at autorelease
            // / explicit release sites downstream.
            CFRetain((__bridge CFTypeRef)tex);
            if (texCacheLog++ < 8) {
                fprintf(stderr,
                    "#### MTL_TEX TEX-CACHE-HIT: surf=%p → tex=%p (no sel=0xa, +1 retain)\n",
                    (void *)surf, (void *)tex);
            }
            // 2026-06-20 — GPU-execution decisive diagnostic.  VNC is
            // black despite WS alive + composites succeeding.  Either the
            // GPU isn't executing (composite produces no pixels) or the
            // VNC read path reads a different surface.  Sample this
            // pooled surface's center pixels: if they ever become
            // non-black, the GPU IS writing rendered content → black-VNC
            // is a read-path problem.  Gated MACWS_SURF_SAMPLE.
            // 2026-06-20 — VNC read-path test.  GPU renders to the
            // texture's separate backing (confirmed: backing has
            // content, IOSurface all-zero).  Before building a real
            // backing→IOSurface bridge, confirm VNC actually READS this
            // IOSurface by filling it with a solid pattern.  If VNC
            // turns white/gray, the read path is correct and the fix is
            // to route rendered content here.  Gated MACWS_SURF_FILL.
            // Only fill the large (display-sized) surfaces.
            if (getenv("MACWS_SURF_FILL") && width >= 1000 && height >= 600) {
                // Fill RARELY (every 240th hit).  GPU writes to the
                // texture's SEPARATE backing, never this IOSurface, so
                // the gray fill PERSISTS until we fill again — one fill
                // is enough for VNC to show it.  Filling every hit
                // (31 MB memset × hundreds/frame) thrashed the device.
                static _Atomic int fillN = 0;
                if ((atomic_fetch_add(&fillN, 1) % 240) == 0) {
                    IOSurfaceLock(surf, 0, NULL);
                    uint8_t *fb = (uint8_t *)IOSurfaceGetBaseAddress(surf);
                    if (fb) {
                        memset(fb, 0x80, (size_t)width * height * bpe);
                        static int filllog = 0;
                        if (filllog++ < 4)
                            fprintf(stderr,
                                "#### SURF-FILL surf=%p %lux%lu bpe=%lu filled 0x80\n",
                                (void*)surf,(unsigned long)width,
                                (unsigned long)height,(unsigned long)bpe);
                    }
                    IOSurfaceUnlock(surf, 0, NULL);
                }
            }
            if (getenv("MACWS_SURF_SAMPLE")) {
                static _Atomic int sampN = 0;
                int sn = atomic_fetch_add(&sampN, 1);
                if ((sn % 240) == 0 && width >= 64 && height >= 64) {
                    IOSurfaceLock(surf, 0x1 /*kIOSurfaceLockReadOnly*/, NULL);
                    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surf);
                    if (base) {
                        size_t bpr = width * bpe;
                        // Scan a sparse grid across the WHOLE surface:
                        // 32 rows × 32 cols = 1024 sample points.  If ANY
                        // is non-zero, the GPU wrote visible content
                        // somewhere → it's a VNC read-path issue, not a
                        // GPU-execution issue.  All-zero across the whole
                        // surface = GPU not writing to this IOSurface.
                        uint64_t acc = 0; int nz = 0; int total = 0;
                        size_t firstnz_off = (size_t)-1;
                        for (int ry = 0; ry < 32; ry++) {
                            size_t y = (size_t)ry * (height-1) / 31;
                            for (int rx = 0; rx < 32; rx++) {
                                size_t x = (size_t)rx * (width-1) / 31;
                                size_t off = y * bpr + x * bpe;
                                for (size_t b = 0; b < bpe; b++) {
                                    uint8_t v = base[off + b];
                                    acc += v; total++;
                                    if (v) { nz++; if (firstnz_off==(size_t)-1) firstnz_off=off+b; }
                                }
                            }
                        }
                        fprintf(stderr,
                            "#### SURF-SAMPLE surf=%p %lux%lu bpe=%lu GRID32x32: "
                            "nonzero=%d/%d sum=%llu firstNZ@%#zx\n",
                            (void *)surf, (unsigned long)width,
                            (unsigned long)height, (unsigned long)bpe,
                            nz, total, (unsigned long long)acc, firstnz_off);
                    } else {
                        fprintf(stderr, "#### SURF-SAMPLE surf=%p base=NULL\n", (void*)surf);
                    }
                    IOSurfaceUnlock(surf, 0x1, NULL);
                }
            }
        } else {
            tex = [self hooked_newTextureWithDescriptor:desc
                                              iosurface:surf
                                                  plane:0];
            if (tex) {
                @synchronized(texCache) {
                    id<MTLTexture> cached = texCache[texKey];
                    if (cached) {
                        // Lost the race — drop our fresh tex (let ARC
                        // release it via end-of-scope autorelease) and
                        // hand caller the cached one with +1.
                        CFRetain((__bridge CFTypeRef)cached);
                        tex = cached;
                    } else {
                        // Insert into dict.  Dict retains; %orig +1
                        // already belongs to caller.  Bump retain once
                        // more to keep dict's reference matched to the
                        // explicit retain we'll add on every HIT — this
                        // way dict ref == sum of (HITs we'll service).
                        // Without this extra retain, dict→tex link is
                        // the only thing holding tex; first HIT's
                        // CFRetain still works (refcount goes 1→2 then
                        // back to 1 on caller's release), but if dict
                        // is ever cleared, tex dies even though HITs
                        // were still expected.  Conservative: keep tex
                        // alive for process lifetime.
                        CFRetain((__bridge CFTypeRef)tex);
                        texCache[texKey] = tex;
                    }
                }
                if (texCacheLog++ < 8) {
                    fprintf(stderr,
                        "#### MTL_TEX TEX-CACHE-NEW: surf=%p → tex=%p\n",
                        (void *)surf, (void *)tex);
                }
            }
        }
        // 2026-06-20 — Wire IOSurface base into the texture's +0xa0
        // ivar so AGX::Texture::writeRegion's memmove has a valid
        // dest pointer for CA's replaceRegion pixel uploads.  The
        // `[self hooked_newTextureWithDescriptor:iosurface:plane:]`
        // call above goes through swizzle and lands in the ORIGINAL
        // Apple AGXG13GFamilyDevice impl (not our iosurface variant
        // hook epilogue), so we must wire here too — duplicating the
        // wire from the iosurface variant hook epilogue does NOT
        // double-write because wire is idempotent on the same
        // (impl+0xa0, base) pair.
        if (tex) {
            macws_wire_iosurface_base_into_texture(tex, surf);
        }
        // Read-path probe: also track surfaces arriving via the
        // AGXG13GFamilyDevice swizzle (different entry point than the
        // IOGPUMetalDevice iosurface variant). See macws_disp_fill_track.
        macws_disp_fill_track(tex, surf);
        // 2026-06-20 — DO NOT CFRelease(surf): the pool retains the
        // surface for process lifetime (see POOL-NEW/POOL-HIT branches
        // above).  Metal's internal IOSurface retain comes on top.
        // CFRelease here would over-balance for POOL-HIT (returned ref
        // from [v pointerValue] is borrowed, no +1) and also dropping
        // the pool's strong ref on POOL-NEW would cause the surface to
        // be freed once Metal releases it.
        if (route_log < 16) {
            fprintf(stderr,
                "#### MTL_TEX plain ROUTE-IOSURF result: %p\n",
                (void *)tex);
        }
        return tex;
    }
    id<MTLTexture> result = [self hooked_newTextureWithDescriptor:desc];
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/plain.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, NULL, 0, "plain.NIL");
    }
    return result;
}

// ─── Tile-pipeline → render-pipeline converter ──────────────────────────────
// MTLSimDevice's `newRenderPipelineStateWithTileDescriptor:options:reflection:
// error:` MTLReportFailure-aborts WS. Swizzled onto MTLSimDevice; converts
// the MTLTileRenderPipelineDescriptor into an MTLRenderPipelineDescriptor
// (tileFunction → fragmentFunction, copy color attachments + sample count)
// and creates a regular MTLRenderPipelineState. BlurState::tile_downsample
// stores this in PingPongState and the subsequent draw runs through a
// regular MTLRenderCommandEncoder. Tile-specific shader intrinsics will not
// behave the same way they would on a real tile pipeline, but the BlurState
// flow does NOT short-circuit on nil and the destination texture DOES get
// written, so vibrancy panels render with content instead of solid black.
- (id)hooked_newRenderPipelineStateWithTileDescriptor:(id)tileDesc
                                              options:(NSUInteger)opt
                                           reflection:(id *)refl
                                                error:(NSError **)err {
    static int log_count = 0;
    if (log_count < 4) {
        log_count++;
        fprintf(stderr, "#### MTLSim tile-pipeline req → converting to render-pipeline\n");
    }

    MTLRenderPipelineDescriptor *rdesc = [[MTLRenderPipelineDescriptor alloc] init];
    if ([tileDesc respondsToSelector:@selector(label)]) {
        rdesc.label = [tileDesc performSelector:@selector(label)] ?: @"TileFallback";
    }

    // Use QuartzCore's own non-tile downsample-blur shaders. Their default
    // .metallib at /System/Library/Frameworks/QuartzCore.framework/Versions/A/
    // Resources/default.metallib defines `downsample_blur_4_frag_lpf` and
    // `downsample_blur_vert_lpf` for exactly this purpose — the non-tile
    // fallback path that QuartzCore uses on devices without tile rendering.
    // These shaders are pre-compiled and DO compile in chroot (no source
    // compilation needed).
    static dispatch_once_t qc_lib_once;
    static id<MTLLibrary> qc_lib = nil;
    static id<MTLFunction> qc_frag = nil;
    dispatch_once(&qc_lib_once, ^{
        NSURL *qcurl = [NSURL fileURLWithPath:
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *lerr = nil;
        qc_lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
        if (qc_lib) {
            qc_frag = [qc_lib newFunctionWithName:@"downsample_blur_4_frag_lpf"];
            fprintf(stderr, "#### tile-pipeline: QC frag = %p (downsample_blur_4_frag_lpf)\n",
                    (void *)qc_frag);
        }
    });
    if (qc_frag) {
        rdesc.fragmentFunction = qc_frag;
    } else if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
        // Last-resort: use the tile function as fragment (will likely fail
        // to compile due to imageblock intrinsics, but we already log that).
        id tileFn = [tileDesc performSelector:@selector(tileFunction)];
        rdesc.fragmentFunction = (id<MTLFunction>)tileFn;
    }
    // Tile pipelines have no vertex stage but MTLRenderPipelineDescriptor
    // validation REQUIRES a vertex function. Source-level compilation fails
    // in chroot (`This library format is not supported on this platform`),
    // so try a pre-existing library route instead.
    //
    // Try device's default library + the tile descriptor's tileFunction's
    // own library (the same .metallib that contains the tile fragment also
    // usually has a vertex helper). If both fail, return nil + NSError.
    static dispatch_once_t vfn_once;
    static id<MTLFunction> cached_vfn = nil;
    static NSArray<NSString *> *cand_names = nil;
    dispatch_once(&vfn_once, ^{
        cand_names = @[
            @"vertex_passthrough", @"vertexPassthrough",
            @"passthrough_vertex", @"passthroughVertex",
            @"PassthroughVertex", @"passthrough",
            @"fs_vertex", @"fullscreen_vertex", @"fullscreenVertex",
            @"main_vertex", @"vert_main", @"main0",
        ];
    });
    if (!cached_vfn) {
        // First: try the tile function's own library (BlurState's tile
        // shader is in QuartzCore's default.metallib, which also exposes
        // std_vert0_lpf / std_vert1_lpf / upsample_vert_lpf / etc.).
        id tileFn = nil;
        if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
            tileFn = [tileDesc performSelector:@selector(tileFunction)];
        }
        // Order matters: downsample_blur_vert_lpf provides the texcoord0
        // output that downsample_blur_4_frag_lpf reads. std_vert0_lpf only
        // emits position and causes "Fragment input mismatching" errors.
        NSArray<NSString *> *qc_names = @[
            @"downsample_blur_vert_lpf",
            @"upsample_vert_lpf",
            @"std_vert1_lpf", @"std_vert0_lpf",
            @"read_surf_vert",
        ];
        if (tileFn && [tileFn respondsToSelector:@selector(library)]) {
            id lib = [tileFn performSelector:@selector(library)];
            for (NSString *nm in qc_names) {
                id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                if (f) { cached_vfn = f; break; }
            }
            if (!cached_vfn) {
                for (NSString *nm in cand_names) {
                    id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                    if (f) { cached_vfn = f; break; }
                }
            }
        }
        // Second: load QuartzCore's default.metallib directly by URL.
        if (!cached_vfn) {
            @try {
                NSURL *qcurl = [NSURL fileURLWithPath:
                    @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
                NSError *lerr = nil;
                id<MTLLibrary> lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
                if (lib) {
                    for (NSString *nm in qc_names) {
                        id<MTLFunction> f = [lib newFunctionWithName:nm];
                        if (f) { cached_vfn = f; break; }
                    }
                } else if (lerr) {
                    fprintf(stderr, "#### tile-pipeline: QC metallib load err: %s\n",
                            [[lerr localizedDescription] UTF8String]);
                }
            } @catch (NSException *e) {}
        }
        fprintf(stderr, "#### tile-pipeline: vertex fn lookup = %p (name=%s)\n",
                (void *)cached_vfn,
                cached_vfn ? [[cached_vfn name] UTF8String] : "(none)");
    }
    if (cached_vfn) {
        rdesc.vertexFunction = cached_vfn;
        NSArray *attrs = [cached_vfn performSelector:@selector(vertexAttributes)];
        if (attrs && [attrs count] > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            // Log all attributes so we know what to pre-populate for draw.
            for (id a in attrs) {
                NSUInteger idx = (NSUInteger)[[a valueForKey:@"attributeIndex"] unsignedLongValue];
                NSUInteger attrType = (NSUInteger)[[a valueForKey:@"attributeType"] unsignedLongValue];
                NSString *nm = [a valueForKey:@"name"];
                fprintf(stderr,
                    "#### blur-trace vertex attr[%lu]: name=%s type=%lu\n",
                    (unsigned long)idx,
                    nm ? [nm UTF8String] : "(no name)",
                    (unsigned long)attrType);
                // All attributes use buffer idx 0 (we'll populate one buffer
                // with all needed data per vertex in dispatchThreadsPerTile).
                vd.attributes[idx].format = MTLVertexFormatFloat4;
                vd.attributes[idx].offset = idx * 16;
                vd.attributes[idx].bufferIndex = 30;  // high slot to avoid clash
            }
            vd.layouts[30].stride = [attrs count] * 16;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[30].stepRate = 1;
            rdesc.vertexDescriptor = vd;
        }
    } else {
        if (err) *err = [NSError errorWithDomain:@"MTLDevice" code:0
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   @"No passthrough vertex function available"}];
        return nil;
    }

    if ([tileDesc respondsToSelector:@selector(colorAttachments)]) {
        id colAtts = [tileDesc performSelector:@selector(colorAttachments)];
        for (NSUInteger i = 0; i < 8; i++) {
            id src = nil;
            @try { src = [colAtts objectAtIndexedSubscript:i]; } @catch (NSException *e) { break; }
            if (!src) continue;
            MTLPixelFormat fmt = MTLPixelFormatInvalid;
            @try { fmt = (MTLPixelFormat)[[src valueForKey:@"pixelFormat"] unsignedLongValue]; } @catch (NSException *e) {}
            if (fmt == MTLPixelFormatInvalid) continue;
            rdesc.colorAttachments[i].pixelFormat = fmt;
        }
    }
    if ([tileDesc respondsToSelector:@selector(rasterSampleCount)]) {
        @try {
            rdesc.rasterSampleCount = (NSUInteger)[[tileDesc valueForKey:@"rasterSampleCount"] unsignedLongValue] ?: 1;
        } @catch (NSException *e) { rdesc.rasterSampleCount = 1; }
    }

    NSError *e2 = nil;
    id<MTLRenderPipelineState> result =
        [(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:rdesc
                                                          options:opt
                                                       reflection:nil
                                                            error:&e2];
    if (refl) *refl = nil;
    if (!result) {
        // Last resort: nil + NSError. WS stays alive; BlurState bails out
        // and the panel reverts to defensive solid color (still no abort).
        if (err) *err = e2 ?: [NSError errorWithDomain:@"MTLDevice" code:0
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Tile pipeline conversion failed"}];
        static int fail_count = 0;
        if (fail_count++ < 4) {
            fprintf(stderr, "#### tile-pipeline conversion FAILED: %s\n",
                    e2 ? [[e2 localizedDescription] UTF8String] : "(no error)");
        }
        return nil;
    }
    if (err) *err = nil;
    return result;
}
@end
#endif // MTLFakeDevice static class (off for arm64e on-device)

// Forward declarations for AGX init redirect (definitions below the hook).
static void install_agx_init_redirect(Class agx);

%hookf(Class, getMetalPluginClassForService, int service) {
    // MACWS_AGX_NATIVE=1: both slices return the real AGX device class.
    // dlopen the AGXMetal13_3 bundle on demand so its ObjC classes register,
    // then look up AGXG13GFamilyDevice.
    static int agx_once = 0;
    static Class agx_cls = Nil;
    if (getenv("MACWS_AGX_NATIVE")) {
        if (!agx_once) {
            agx_once = 1;
            // Pre-load IOGPU so its symbols are in the address space when
            // dyld binds AGXMetal13_3's cross-image references. AGXMetal13_3
            // calls IOGPU pool-allocator / IOGPUMetalCommonResource functions
            // through __got/__auth_got slots; if dyld can't resolve them at
            // bind time, the slots end up null and Mempool::grow's lambda
            // tail-jumps into garbage (see memory:
            // agx-mempool-grow-fault-decomposed and the lambda BL NOP fix in
            // mac_hooks.m). Force-loading IOGPU first lets the binder do its
            // job for those refs.
            const char *iogpuPaths[] = {
                "/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU",
                NULL
            };
            void *iogpu = NULL;
            for (int i = 0; iogpuPaths[i]; i++) {
                iogpu = dlopen(iogpuPaths[i], RTLD_GLOBAL | RTLD_NOW);
                if (iogpu) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE pre-loaded IOGPU via %s -> %p\n",
                        iogpuPaths[i], iogpu);
                    break;
                }
            }
            if (!iogpu) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE could NOT pre-load IOGPU: %s\n", dlerror());
            }
            // Verify some critical IOGPU symbols are resolvable
            const char *probeSyms[] = {
                "IOGPUResourceCreate",
                "IOGPUMetalCommonResourceCreate",
                "IOGPUDeviceCreateWithAPIProperty",
                "_IOGPUMetalAllocateResource",
                "IOGPUMetalAllocateResource",
                NULL
            };
            for (int i = 0; probeSyms[i]; i++) {
                void *p = dlsym(RTLD_DEFAULT, probeSyms[i]);
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlsym(%s) = %p\n", probeSyms[i], p);
            }

            void *h = dlopen("/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3", RTLD_NOW);
            if (!h) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 FAILED: %s\n", dlerror());
            } else {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 OK h=%p\n", h);
            }
            // dlopen on the inner binary does NOT register an NSBundle. AGX's
            // own getBundle() iterates [NSBundle allBundles] looking for one
            // whose identifier contains "AGXMetal13_3" — without an explicit
            // bundleWithPath: the list is empty, so getBundle returns nil and
            // setupCompiler:'s pathForResource:@"ds" ofType:@"g13g" fails
            // (FATAL: driver shader binary file not found), leaving
            // Device->0x318 (the Compiler wrapper) uninitialised → every
            // shader-variant lookup later crashes on null deref.
            NSBundle *agxBundle = [NSBundle bundleWithPath:
                @"/System/Library/Extensions/AGXMetal13_3.bundle"];
            fprintf(stderr, "#### MACWS_AGX_NATIVE +[NSBundle bundleWithPath:AGXMetal13_3.bundle] = %p id=%s\n",
                agxBundle, agxBundle ? [agxBundle.bundleIdentifier UTF8String] : "(nil)");
            if (agxBundle) {
                // [NSBundle load] forces principal class loading + registers
                // the bundle so it appears in +allBundles. We already loaded
                // the binary via dlopen so this is just the metadata side.
                NSError *err = nil;
                BOOL loaded = [agxBundle loadAndReturnError:&err];
                fprintf(stderr, "#### MACWS_AGX_NATIVE bundle loadAndReturnError: %d (err=%s) loaded=%d\n",
                    loaded, err ? [[err description] UTF8String] : "nil",
                    [agxBundle isLoaded]);
                NSString *dsPath = [agxBundle pathForResource:@"ds" ofType:@"g13g"];
                fprintf(stderr, "#### MACWS_AGX_NATIVE bundle pathForResource:ds.g13g = %s\n",
                    dsPath ? [dsPath UTF8String] : "(nil)");
            }
            agx_cls = objc_getClass("AGXG13GFamilyDevice");
            fprintf(stderr, "#### MACWS_AGX_NATIVE getMetalPluginClassForService: returning class %s = %p\n",
                agx_cls ? class_getName(agx_cls) : "(nil)", (void*)agx_cls);
            if (agx_cls) {
                install_agx_init_redirect(agx_cls);
            }
        }
        return agx_cls;
    }

#ifdef FORCE_M1_DRIVER
    // FORCE_M1_DRIVER on-device default (env unset): Nil = CPU/sim fallback for stability.
    return Nil;
#else
    return MTLFakeDevice.class;
#endif
}

// When Metal asks the plugin class to instantiate a device, it does:
//   id raw = [pluginClass alloc];
//   [raw initWithAcceleratorPort:port];
//
// MTLFakeDevice has -initWithAcceleratorPort:. AGXG13GFamilyDevice does NOT —
// it has -initWithAcceleratorPort:simultaneousInstances: (two-arg). So Metal's
// single-arg dispatch on AGXG13GFamilyDevice falls through to NSObject (no-op),
// leaving AGX-specific ivars (especially the AGX::G13::Device* at offset 0x3a8)
// uninitialized → crashes later in newBufferWithLength: at +132.
//
// We install the single-arg method on AGXG13GFamilyDevice at runtime via
// class_addMethod (Logos %hook can't add a previously-nonexistent method
// reliably) and have it forward to the 2-arg init.
static id agx_initWithAcceleratorPort_impl(id self, SEL _cmd, int port) {
    fprintf(stderr, "#### MACWS_AGX_NATIVE redirecting AGXG13GFamilyDevice init(port=%d) → 2-arg variant\n", port);
    SEL realSel = sel_registerName("initWithAcceleratorPort:simultaneousInstances:");
    typedef id (*RealInit)(id, SEL, int, uint64_t);
    id dev = ((RealInit)objc_msgSend)(self, realSel, port, 1);
    // AGXG13GDevice's own -initWithAcceleratorPort: calls super-init then
    // [self setupCompiler:0x30010] — the call that allocates Device->0x318
    // (the AGX::Compiler wrapper, used by every shader-variant lookup).
    // We instantiate the parent class directly, so setupCompiler: never
    // runs — Device->0x318 stays null and every find/tryFind*ProgramVariant
    // crashes. Call setupCompiler: explicitly here so the wrapper gets built.
    // Arg 0x30010 = same hardcoded value AGXG13GDevice's init passes.
    if (dev) {
        SEL setupCompilerSel = sel_registerName("setupCompiler:");
        if ([dev respondsToSelector:setupCompilerSel]) {
            ((void (*)(id, SEL, int))objc_msgSend)(dev, setupCompilerSel, 0x30010);
            fprintf(stderr, "#### MACWS_AGX_NATIVE setupCompiler:0x30010 fired (Device=%p)\n", dev);
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE setupCompiler: NOT FOUND on %s\n",
                class_getName([dev class]));
        }
    }
    return dev;
}

// Diag hook on `-[AGXG13GFamilyTexture initImplWithDevice:Descriptor:iosurface:plane:buffer:
//                bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:]`.
// Per-call log of (self_class, iosurface, descriptor.pixelFormat, return value).
// Identifies which calls return nil and correlates to the iosurface.
typedef id (*macws_initimpl_orig_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked);
static macws_initimpl_orig_t macws_orig_initimpl = NULL;

static id macws_hook_initimpl(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked) {
    id result = nil;
    if (macws_orig_initimpl) {
        result = macws_orig_initimpl(self, _cmd, device, descriptor, iosurface,
            plane, buffer, bytesPerRow, allowNPOT, sparsePageSize,
            isCompressedIOSurface, isHeapBacked);
    }
    // SEPARATE-BACKING PROOF (gated /tmp/macws_copy_ios_a0): +0xa0 is a separate alloc
    // from the client IOSurface (ALIAS=0, runtime-confirmed) → GPU samples empty. Copy
    // the client IOSurface content INTO +0xa0 so WS samples real pixels. Tiling-invariant
    // for solid colors (solidwin proof). PROOF/diagnostic, NOT a production fix.
    if (result && iosurface && access("/tmp/macws_copy_ios_a0", F_OK) == 0) {
        NSUInteger cw = descriptor ? ((NSUInteger(*)(id,SEL))objc_msgSend)(descriptor, @selector(width)) : 0;
        if (cw >= 500) {  // window-content sized; skip tiny (a0-overflow safety)
            void *impl = *(void **)((char *)(__bridge void *)self + 0x208);
            if ((uintptr_t)impl > 0x1000) {
                void *a0 = *(void **)((char *)impl + 0xa0);
                void *base = IOSurfaceGetBaseAddress(iosurface);
                size_t sz = IOSurfaceGetAllocSize(iosurface);
                if (a0 && base && a0 != base && sz > 0 && sz <= 64u*1024*1024) {
                    memcpy(a0, base, sz);
                    static int cc = 0; if (cc++ < 20)
                        fprintf(stderr, "#### COPY_IOS_A0 cw=%lu a0=%p base=%p sz=%zu\n",
                                (unsigned long)cw, a0, base, sz);
                }
            }
        }
    }
    // FORCE-LAYOUT0 (gated /tmp/macws_force_layout0): the connection-crash blur texture is
    // layout=3 (twiddled) but backed by a LINEAR chroot IOSurface — inconsistent; getCPUPtr's
    // twiddle translation returns 0 → writeRegion memmove(NULL) crash. The layout=0 path
    // (linear) maps fine over a linear IOSurface (proven by the 32x32). Correct AGX's wrong
    // layout choice: force impl layout(+0x184)=0, +0xa0=IOSurface base, +0xa8=0 (tight) so
    // getCPUPtr reads the IOSurface linearly. (Test: does WS survive the blur menu?)
    if (result && iosurface && access("/tmp/macws_force_layout0", F_OK) == 0) {
        void *impl = *(void **)((char *)(__bridge void *)self + 0x208);
        if ((uintptr_t)impl > 0x1000) {
            uint8_t *lay = (uint8_t *)((char *)impl + 0x184);
            if (*lay == 3) {
                void *base = IOSurfaceGetBaseAddress(iosurface);
                if (base) {
                    *lay = 0;
                    *(void * volatile *)((char *)impl + 0xa0) = base;
                    *(volatile uint32_t *)((char *)impl + 0xa8) = 0;
                    static int fl = 0; if (fl++ < 12) {
                        fprintf(stderr, "#### FORCE-L0 tex=%p impl=%p layout 3->0 +0xa0=%p ios=%p\n",
                                (void *)self, impl, base, iosurface); fflush(stderr);
                    }
                }
            }
        }
    }
    static int log_count = 0;
    if (log_count < 400) {
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        // SEPARATE-BACKING TEST: compare the texture's GPU backing (_impl+0xa0)
        // to the IOSurface base. alias=1 ⟹ GPU samples the real IOSurface pages;
        // alias=0 ⟹ separate backing (GPU samples empty → source content lost).
        void *ios_base = iosurface ? IOSurfaceGetBaseAddress(iosurface) : NULL;
        void *impl_a0 = NULL; uint32_t ios_id = 0;
        if (iosurface) ios_id = ((uint32_t (*)(IOSurfaceRef))IOSurfaceGetID)(iosurface);
        { void *impl = *(void **)((char *)(__bridge void *)self + 0x208);
          if ((uintptr_t)impl > 0x1000) impl_a0 = *(void **)((char *)impl + 0xa0); }
        fprintf(stderr,
            "#### INITIMPL_HOOK self=%p cls=%s ios=%p iosID=%u ios_fcc=%#x desc(pf=%lu w=%lu h=%lu) "
            "buf=%p bpr=%lu npot=%d sparse=%lu compIOS=%d heap=%d → result=%p "
            "ios_base=%p a0=%p ALIAS=%d\n",
            self, class_getName([self class]),
            iosurface, ios_id, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            buffer, (unsigned long)bytesPerRow,
            (int)allowNPOT, (unsigned long)sparsePageSize,
            (int)isCompressedIOSurface, (int)isHeapBacked,
            result, ios_base, impl_a0, (ios_base && ios_base == impl_a0) ? 1 : 0);
        fflush(stderr);   // crash follows soon — flush so the blur tex init survives
        log_count++;
    }
    return result;
}

static void install_agx_initimpl_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE") && access("/tmp/macws_initimpl_trace", F_OK) != 0) return;
    Class tex_cls = objc_getClass("AGXG13GFamilyTexture");
    if (!tex_cls) {
        fprintf(stderr, "#### INITIMPL_HOOK: AGXG13GFamilyTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:"
        "allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:");
    Method m = class_getInstanceMethod(tex_cls, sel);
    if (!m) {
        fprintf(stderr, "#### INITIMPL_HOOK: method not found\n");
        return;
    }
    macws_orig_initimpl = (macws_initimpl_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_initimpl);
    fprintf(stderr, "#### INITIMPL_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_initimpl);
}

// ── BINDFIX (gated /tmp/macws_bindfix) — THE driver-level AGX-native fix ──
// RE-confirmed root cause (macOS-vs-iOS AGXMetal13_3 diff): the IOSurface dest's GPU render-target
// VA flows -[AGXTexture initWithDevice:desc:iosurface:plane:]@0x1e5a5ae18 → IOGPUMetalResource →
// _res+0x48 (= _IOGPUResourceGetGPUVirtualAddress = kernel s_new_resource output[0]) →
// -[…updateBindDataWithAddresses:…gpuVirtualAddress:…]@0x1e57716b4 writes it to impl+0x40 and
// re-bakes the PBE descriptor (texBaseAddressesUpdated). In the chroot the kernel hands back GPU
// VA=0 for the type=0x82 IOSurface resource (or macOS IOGPU misparses the iOS-kernel output) → the
// dest binds VA 0 → GPU writes nowhere → black. Driver logic + offsets are IDENTICAL to iOS, so
// the only userland fix is at this single chokepoint: when gpuVirtualAddress==0 for the IOSurface
// full-screen dest, substitute the IOSurface's REAL GPU VA obtained independently via
// -[AGXG13GFamilyDevice newBufferWithIOSurface:]@0x1e574d858 (same IOGPUMetalResource path) →
// its gpuAddress. Diagnostic-first: logs in_gpuVA + newbuf_va so one run tells us whether the
// buffer path yields a non-0 VA (fix viable) or also 0 (kernel truly assigns none → fallback).
typedef void (*macws_updatebind_orig_t)(id, SEL, uint64_t, uint64_t, uint64_t, bool, bool);
static macws_updatebind_orig_t macws_orig_updatebind = NULL;
static void macws_hook_updatebind(id self, SEL _cmd, uint64_t addresses, uint64_t cpuMeta,
                                  uint64_t gpuVA, bool isComp, bool shouldInit) {
    uint64_t useVA = gpuVA;
    if (access("/tmp/macws_bindfix", F_OK) == 0) {
        { void *impl0 = *(void **)((char *)(__bridge void *)self + 0x208);
          uint64_t ios0 = ((uintptr_t)impl0 > 0x1000) ? *(uint64_t *)((char *)impl0 + 0xa0) : 0;
          static _Atomic int alln = 0; int n = atomic_fetch_add(&alln, 1);
          if (n < 24) fprintf(stderr, "#### BINDFIX-ALL #%d cls=%s impl=%p ios=%#llx gpuVA=%#llx cpuMeta=%#llx\n",
                n, class_getName([self class]), impl0, ios0, gpuVA, cpuMeta); }
        @try {
            void *impl = *(void **)((char *)(__bridge void *)self + 0x208);
            uint64_t ios = ((uintptr_t)impl > 0x1000) ? *(uint64_t *)((char *)impl + 0xa0) : 0;
            if (ios) {                            // IOSurface-backed (impl+0xa0 set by initImplWith before this)
                int w = (int)IOSurfaceGetWidth((IOSurfaceRef)ios);
                int h = (int)IOSurfaceGetHeight((IOSurfaceRef)ios);
                uint64_t newva = 0;
                if (w >= 1900 && w < 2300) {      // the macOS compositor full-screen dest
                    static NSMutableDictionary *cache; static dispatch_once_t once;
                    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
                    NSValue *key = [NSValue valueWithPointer:(void *)ios];
                    id buf; @synchronized(cache) { buf = cache[key]; }
                    if (!buf) {
                        id dev = [(id<MTLTexture>)self device];
                        typedef id (*nbi_t)(id, SEL, IOSurfaceRef);
                        buf = ((nbi_t)objc_msgSend)(dev, sel_registerName("newBufferWithIOSurface:"), (IOSurfaceRef)ios);
                        if (buf) { @synchronized(cache) { cache[key] = buf; } }   // retain so the VA stays valid
                    }
                    if (buf) { typedef uint64_t (*ga_t)(id, SEL); newva = ((ga_t)objc_msgSend)(buf, sel_registerName("gpuAddress")); }
                    if (gpuVA == 0 && newva) useVA = newva;          // SUBSTITUTE the real IOSurface GPU VA
                }
                static int bn; if (bn++ < 16)
                    fprintf(stderr, "#### BINDFIX ios-tex %dx%d in_gpuVA=%#llx ios=%#llx newbuf_va=%#llx -> useVA=%#llx\n",
                        w, h, gpuVA, ios, newva, useVA);
            }
        } @catch (__unused NSException *e) {}
    }
    if (macws_orig_updatebind) macws_orig_updatebind(self, _cmd, addresses, cpuMeta, useVA, isComp, shouldInit);
}
static void install_updatebind_hook(void) {
    if (!getenv("MACWS_AGX_NATIVE")) return;
    Class tex_cls = objc_getClass("AGXG13GFamilyTexture");
    if (!tex_cls) { fprintf(stderr, "#### BINDFIX: AGXG13GFamilyTexture class not found\n"); return; }
    SEL sel = sel_registerName("updateBindDataWithAddresses:cpuMetadataAddress:gpuVirtualAddress:isCompressible:shouldInitMetadata:");
    Method m = class_getInstanceMethod(tex_cls, sel);
    if (!m) { fprintf(stderr, "#### BINDFIX: updateBindData method not found\n"); return; }
    macws_orig_updatebind = (macws_updatebind_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_updatebind);
    fprintf(stderr, "#### BINDFIX: updateBindData hook installed (orig=%p)\n", (void *)macws_orig_updatebind);
}

// Probe -[IOGPUMetalCommandBuffer commandBufferResourceInfo].
// RenderContext init stores its result at renderContext->0x10. If nil,
// DataBufferAllocator::newCommand crashes 0x114 in dereferencing this->0x10.
// Hook this method to log every call's return; if it returns nil, the next
// step is figuring out why commandBufferStorage->0x300 is unset.
typedef id (*macws_cbri_orig_t)(id self, SEL _cmd);
static macws_cbri_orig_t macws_orig_cbri = NULL;
static id macws_hook_cbri(id self, SEL _cmd) {
    id result = macws_orig_cbri ? macws_orig_cbri(self, _cmd) : nil;
    static int log_count = 0;
    if (log_count < 10) {
        fprintf(stderr,
            "#### CBRI_HOOK self=%p cls=%s → resourceInfo=%p\n",
            self, class_getName([self class]), result);
        log_count++;
    }
    return result;
}

static void install_cbri_probe(void) {
    if (!getenv("MACWS_AGX_NATIVE")) return;
    // The method lives on IOGPUMetalCommandBuffer (super class). Hook there
    // — AGXG13GFamilyCommandBuffer doesn't override.
    Class cb_cls = objc_getClass("IOGPUMetalCommandBuffer");
    if (!cb_cls) {
        fprintf(stderr, "#### CBRI_HOOK: IOGPUMetalCommandBuffer class not found\n");
        return;
    }
    SEL sel = sel_registerName("commandBufferResourceInfo");
    Method m = class_getInstanceMethod(cb_cls, sel);
    if (!m) {
        fprintf(stderr, "#### CBRI_HOOK: method not found\n");
        return;
    }
    macws_orig_cbri = (macws_cbri_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_cbri);
    fprintf(stderr, "#### CBRI_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_cbri);
}

// Diag hook on `-[IOGPUMetalTexture initWithDevice:descriptor:iosurface:plane:
//                field:args:argsSize:]`. This is the SUPER-INIT dispatched by
// -[AGXTexture initWithDevice:desc:iosurface:plane:] via objc_msgSendSuper2.
// AGXG13GFamilyTexture's initImpl succeeds (verified by INITIMPL_HOOK), so the
// nil-exit happens here at the cbz x0 at static 0x1e5a5af3c. Per the static
// disasm there are only two nil-exit paths after initImpl: super-init returns
// 0 OR validate returns BIT0=0 (we already patched validate to always-YES).
// Therefore super-init MUST be returning 0 — log its args + return.
typedef id (*macws_iogpu_init_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize);
static macws_iogpu_init_t macws_orig_iogpu_init = NULL;

static id macws_hook_iogpu_init(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize) {
    static int log_count = 0;
    // Log BEFORE calling orig — IOGPUMetalTexture's init may zero out self
    // on failure (verified by lldb: self.isa = 0 after orig returns nil),
    // so any [self class] after orig will crash.
    const char *cls_name_before = "?";
    if (log_count < 30) {
        Class c = object_getClass(self);
        cls_name_before = c ? class_getName(c) : "(nil)";
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        // argsSize comes in via stack slot; the caller stores only the low
        // 32 bits (`str w8, [sp]`), so mask off the high garbage.
        NSUInteger argsSize_lo = argsSize & 0xFFFFFFFFu;
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [pre] self=%p cls=%s ios=%p ios_fcc=%#x "
            "desc(pf=%lu w=%lu h=%lu) plane=%lu field=%lu args=%p "
            "argsSize=%lu (raw=%#lx)\n",
            self, cls_name_before,
            iosurface, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            (unsigned long)plane, (unsigned long)field,
            args, (unsigned long)argsSize_lo, (unsigned long)argsSize);
    }
    // Save isa BEFORE calling orig — orig zeros the entire object on
    // failure, which makes any subsequent msgSend on `self` crash.
    uint64_t saved_isa = *(uint64_t *)self;
    id result = nil;
    if (macws_orig_iogpu_init) {
        result = macws_orig_iogpu_init(self, _cmd, device, descriptor,
            iosurface, plane, field, args, argsSize);
    }
    // If orig zeroed our isa, restore it so the caller's super-init bypass
    // hands a usable (if partially-init'd) object back to SkyLight. The
    // texture's IVAR area is uninitialised but its objc identity works:
    // [self class] / [self pixelFormat] / ARC retain/release all dispatch
    // correctly.
    uint64_t isa_after = *(uint64_t *)self;
    if (isa_after == 0 && saved_isa != 0) {
        *(uint64_t *)self = saved_isa;
    }
    if (log_count < 30) {
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [post] self=%p isa_was=%#llx isa_after=%#llx "
            "(restored=%d) → result=%p\n",
            self,
            (unsigned long long)saved_isa,
            (unsigned long long)isa_after,
            isa_after == 0 && saved_isa != 0,
            result);
        log_count++;
    }
    return result;
}

static void install_iogpu_init_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE")) return;
    Class iogpu_cls = objc_getClass("IOGPUMetalTexture");
    if (!iogpu_cls) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: IOGPUMetalTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initWithDevice:descriptor:iosurface:plane:field:args:argsSize:");
    Method m = class_getInstanceMethod(iogpu_cls, sel);
    if (!m) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: method not found\n");
        return;
    }
    macws_orig_iogpu_init = (macws_iogpu_init_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_iogpu_init);
    fprintf(stderr, "#### IOGPU_INIT_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_iogpu_init);
}

#if 0
// ─── REMOVED: render-pipeline shader-substitution fallback ──────────────
//
// Earlier iterations swizzled
// `-[AGXG13GFamilyDevice newRenderPipelineStateWithDescriptor:error:]`
// to retry a failed pipeline build with QuartzCore's
// `downsample_blur_vert_lpf` + `downsample_blur_4_frag_lpf` shader pair
// (loaded from QC's pre-compiled `default.metallib`). The pipeline did
// build — but every CA draw that used a failing spec got the blur
// downsample shaders instead of its intended composite/draw pair, so
// affected layers rendered the wrong content. That's not a fix, it's a
// graphical regression masquerading as one.
//
// The whole block is deleted. The correct path is to make AGXCompilerCore
// actually lower the renamed intrinsic — see the MTLCompilerService
// tweak (MTLCompilerBypassOSCheck/Tweak.x) and the dispatch-table /
// linkMetalRuntime RE writeup there.
typedef id (*macws_pip_orig_t)(id self, SEL _cmd,
    MTLRenderPipelineDescriptor *desc, NSError **err);
static macws_pip_orig_t macws_pip_orig = NULL;
static id<MTLFunction> macws_fb_vfn = nil;
static id<MTLFunction> macws_fb_ffn = nil;
static dispatch_once_t macws_fb_once;
static int macws_fb_logged = 0;

static void macws_build_fallback_shaders(id<MTLDevice> device) {
    dispatch_once(&macws_fb_once, ^{
        // `newLibraryWithSource:` invokes the same AGX compiler that fails
        // on CA's `fract.v3f16.fast` intrinsic, so it ALSO can't compile
        // any new MSL we'd hand it (Error 1 / "library format not
        // supported"). Use a pre-built metallib instead. QuartzCore's
        // own `default.metallib` is shipped with already-lowered AIR
        // and is the same source the tile-pipeline fallback uses; its
        // simple-passthrough pair (`std_vert0_lpf` /
        // `downsample_blur_4_frag_lpf`) is known to survive the
        // chroot AGXMetal13_3 compiler. We accept the visual mismatch.
        NSArray *candidate_paths = @[
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib",
            @"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/default.metallib",
        ];
        // Ordered pairs — each entry is {vertex, fragment} where the
        // vertex shader exposes the outputs the fragment shader reads.
        // The existing tile-pipeline hook discovered std_vert0_lpf only
        // emits position so "downsample_blur_4_frag_lpf" — which reads
        // texcoord0 — won't link against it. We have to pair every
        // fragment with a vertex that publishes its required varyings.
        NSArray *pairs = @[
            @[@"downsample_blur_vert_lpf", @"downsample_blur_4_frag_lpf"],
            @[@"upsample_vert_lpf",        @"upsample_blur_4_frag_lpf"],
            @[@"std_vert1_lpf",            @"std_frag1_lpf"],
            @[@"std_vert0_lpf",            @"std_frag0_lpf"],
        ];
        for (NSString *path in candidate_paths) {
            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *lerr = nil;
            id<MTLLibrary> lib = [device newLibraryWithURL:url
                                                     error:&lerr];
            if (!lib) {
                fprintf(stderr,
                    "#### MACWS_PIPELINE_FALLBACK lib %s load: %s\n",
                    [path UTF8String],
                    lerr ? [[lerr description] UTF8String] : "(no error)");
                continue;
            }
            for (NSArray *pair in pairs) {
                NSString *vn = pair[0];
                NSString *fn = pair[1];
                id<MTLFunction> v = [lib newFunctionWithName:vn];
                id<MTLFunction> f = [lib newFunctionWithName:fn];
                if (v && f) {
                    macws_fb_vfn = v;
                    macws_fb_ffn = f;
                    fprintf(stderr,
                        "#### MACWS_PIPELINE_FALLBACK pair loaded from %s "
                        "vs=%s fs=%s\n",
                        [path UTF8String],
                        [vn UTF8String], [fn UTF8String]);
                    break;
                }
            }
            if (macws_fb_vfn && macws_fb_ffn) break;
            // Reset partial matches and try the next library.
            macws_fb_vfn = nil; macws_fb_ffn = nil;
        }
        if (!macws_fb_vfn || !macws_fb_ffn) {
            fprintf(stderr,
                "#### MACWS_PIPELINE_FALLBACK: no compatible vfn/ffn pair found\n");
        }
    });
}

static id macws_hook_newRenderPipelineState(id self, SEL _cmd,
        MTLRenderPipelineDescriptor *desc, NSError **err) {
    NSError *real_err = nil;
    id result = macws_pip_orig
        ? macws_pip_orig(self, _cmd, desc, err ?: &real_err)
        : nil;
    if (result) return result;
    // Build fallback library the first time we need it.
    macws_build_fallback_shaders((id<MTLDevice>)self);
    if (!macws_fb_vfn || !macws_fb_ffn) {
        // Couldn't build the fallback either; propagate nil + original
        // NSError so the caller's abort_with_payload still has context.
        return nil;
    }
    // Clone the descriptor so we don't mutate the caller's instance.
    MTLRenderPipelineDescriptor *fb = [desc copy];
    fb.vertexFunction = macws_fb_vfn;
    fb.fragmentFunction = macws_fb_ffn;
    // The original descriptor's vertex descriptor was built for the
    // ORIGINAL vertex shader's attribute layout; replacing the shader
    // forces us to publish a matching layout for ours. Mirror what
    // the existing tile-pipeline fallback does: query the fallback
    // vertex function's vertexAttributes (Metal exposes them on the
    // function object), make every attribute a float4 at sequential
    // 16-byte offsets, and wire them all to a single buffer slot
    // (high index 30 to dodge whatever the caller binds).
    @try {
        NSArray *attrs = nil;
        if ([macws_fb_vfn respondsToSelector:@selector(vertexAttributes)]) {
            attrs = [(id)macws_fb_vfn performSelector:@selector(vertexAttributes)];
        }
        if (attrs && [attrs count] > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            for (id a in attrs) {
                NSUInteger idx = 0;
                @try {
                    idx = (NSUInteger)[[a valueForKey:@"attributeIndex"]
                        unsignedLongValue];
                } @catch (NSException *e) {}
                vd.attributes[idx].format = MTLVertexFormatFloat4;
                vd.attributes[idx].offset = idx * 16;
                vd.attributes[idx].bufferIndex = 30;
            }
            vd.layouts[30].stride = [attrs count] * 16;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[30].stepRate = 1;
            fb.vertexDescriptor = vd;
        } else {
            // Shader takes no vertex input — drop any descriptor the
            // caller had set so Metal validation doesn't complain about
            // unused attributes.
            fb.vertexDescriptor = nil;
        }
    } @catch (NSException *e) {
        fb.vertexDescriptor = nil;
    }
    NSError *fb_err = nil;
    id fb_result = macws_pip_orig
        ? macws_pip_orig(self, _cmd, fb, &fb_err) : nil;
    if (macws_fb_logged < 8) {
        macws_fb_logged++;
        const char *desc_lbl = "(no label)";
        @try {
            NSString *lbl = [desc label];
            if (lbl) desc_lbl = [lbl UTF8String];
        } @catch (NSException *e) {}
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK label=\"%s\" orig=nil "
            "fallback=%p err=%s\n",
            desc_lbl, (void*)fb_result,
            fb_err ? [[fb_err description] UTF8String] : "(none)");
    }
    if (err && !*err && real_err) *err = real_err;
    return fb_result;
}

static void macws_install_pipeline_fallback(Class agx) {
    // The fallback substitutes QC's `downsample_blur_vert_lpf` +
    // `downsample_blur_4_frag_lpf` for any pipeline the AGX compiler
    // can't build. That keeps WindowServer alive but draws the wrong
    // content for every affected layer (blur output instead of the
    // intended composite). Default off — the correct fix is the
    // AGCLLVMCtx::compile hook in mac_hooks.m (force AGCFastMathFlags=0
    // so the compiler uses the working buildFract path instead of
    // attempting the unimplemented `agx.air.fract.v3f16.fast` lowering).
    // Leave the substitution available for emergency fall-through via
    // `MACWS_PIPELINE_FALLBACK=1` so the device can be brought up if
    // the fast-math disable ever regresses.
    if (!getenv("MACWS_PIPELINE_FALLBACK")) {
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK off by default (set "
            "MACWS_PIPELINE_FALLBACK=1 to enable QC-shader substitution)\n");
        return;
    }
    SEL sel = @selector(newRenderPipelineStateWithDescriptor:error:);
    Method m = class_getInstanceMethod(agx, sel);
    if (!m) {
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK: AGX device has no %s, skip\n",
            sel_getName(sel));
        return;
    }
    macws_pip_orig = (macws_pip_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_newRenderPipelineState);
    fprintf(stderr,
        "#### MACWS_PIPELINE_FALLBACK installed on %s (orig=%p)\n",
        class_getName(agx), (void*)macws_pip_orig);
}
#endif // 0 — disabled shader-substitution fallback

// DIAGNOSTIC ISOLATION (gated /tmp/macws_skip_layout3 or MACWS_SKIP_LAYOUT3_WRITE).
// The window drop-shadow path (SkyLight WSWindowMaskGetMetalTexture ->
// -[IOGPUMetalTexture replaceRegion:] -> AGX::Texture<layout 3>::writeRegion)
// crashes memmove(dst=NULL): the chroot only wires CPU backing for layout=0
// textures, not layout=3 (twiddled) — lldb-confirmed 2026-06-21
// [[ws-window-shadow-layout3-null-backing-crash]]. To ISOLATE that wall and see
// what else blocks GlassDemo rendering, skip replaceRegion for layout!=0
// textures (the shadow mask stays empty; WS survives). NOT A FIX — a scaffold;
// the real fix RE's the layout=3 backing ivar and wires it.
static IMP s_orig_iogpu_replaceRegion = NULL;
static SEL s_replaceRegion_sel = NULL;
static void install_shadow_isolation(void) {
    if (!getenv("MACWS_SKIP_LAYOUT3_WRITE") && access("/tmp/macws_skip_layout3", F_OK) != 0) return;
    Class c = objc_getClass("IOGPUMetalTexture");
    if (!c) { fprintf(stderr, "#### SHADOW-ISO: no IOGPUMetalTexture class\n"); return; }
    s_replaceRegion_sel = sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    Method m = class_getInstanceMethod(c, s_replaceRegion_sel);
    if (!m) { fprintf(stderr, "#### SHADOW-ISO: no replaceRegion method\n"); return; }
    s_orig_iogpu_replaceRegion = method_getImplementation(m);
    IMP newimp = imp_implementationWithBlock(^void(id self, MTLRegion region,
                                                   NSUInteger level, const void *bytes, NSUInteger bpr) {
        void *impl = *(void **)((char *)(__bridge void *)self + 0x208);
        uint8_t layout = ((uintptr_t)impl > 0x1000) ? *(uint8_t *)((char *)impl + 0x184) : 0;
        if (layout != 0) {
            static int n = 0;
            if (n++ < 8)
                fprintf(stderr, "#### SHADOW-ISO skip replaceRegion layout=%u tex=%p %lux%lu\n",
                        layout, (void *)self,
                        (unsigned long)region.size.width, (unsigned long)region.size.height);
            return;  // skip the would-crash NULL-backing write
        }
        ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))s_orig_iogpu_replaceRegion)(
            self, s_replaceRegion_sel, region, level, bytes, bpr);
    });
    method_setImplementation(m, newimp);
    fprintf(stderr, "#### SHADOW-ISO installed: replaceRegion skips layout!=0 (orig=%p)\n",
            (void *)s_orig_iogpu_replaceRegion);
}

// REAL FIX (gated /tmp/macws_wire_backing or MACWS_WIRE_REPLACEREGION) for the
// connection-triggered WS crash. RE-confirmed from WindowServer-2026-06-21-154750.ips:
//   EXC_BAD_ACCESS write@0x0  _platform_memmove <- AGX::Texture<layout 3>::writeRegion
//   <- -[AGXG13GFamilyTexture replaceRegion:] <- -[IOGPUMetalTexture replaceRegion:
//      mipmapLevel:withBytes:bytesPerRow:] <- CA::OGL::MetalContext::create_texture
//   <- ... <- render_subclass::visit_subclass(CA::Render::BackdropLayer)  [NSVisualEffectView blur].
// QuartzCore creates a layout=3 (twiddled) texture for the backdrop-blur and uploads
// pixel data via replaceRegion, but the chroot's synthesized AGX texture has a NULL
// CPU-writable backing (impl+0xa0). RE of AGX::Texture<3>::getCPUPtr (0x1e576fb74):
// it returns `this->0xa0` as the twiddle base for BOTH layout 0 and 3; when 0xa0==NULL
// writeRegion memmoves to ~NULL → SIGSEGV → WS restart → (re-floods DCP → eventual panic).
// FIX: before the real write, if impl+0xa0 is NULL, allocate a real backing sized to the
// texture's twiddled allocation (256-tile-rounded upper bound) and wire it. The backing
// is attached as an associated NSMutableData so it is freed WITH the texture (no per-frame
// leak), NOT a static stub. This makes writeRegion write to real memory → no crash.
// (GPU-coherency of the blur sampling is a separate downstream wall; this only fixes the
// CPU upload crash so WS survives and the window renders.)
static const char kMacwsRRBackingKey;
static IMP s_orig_rr_wire = NULL;
static SEL s_rr_wire_sel = NULL;
static void install_replaceregion_backing_wire(void) {
    if (!getenv("MACWS_WIRE_REPLACEREGION") && access("/tmp/macws_wire_backing", F_OK) != 0) return;
    Class c = objc_getClass("IOGPUMetalTexture");
    if (!c) { fprintf(stderr, "#### RR-WIRE: no IOGPUMetalTexture class\n"); return; }
    s_rr_wire_sel = sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    Method m = class_getInstanceMethod(c, s_rr_wire_sel);
    if (!m) { fprintf(stderr, "#### RR-WIRE: no replaceRegion method\n"); return; }
    s_orig_rr_wire = method_getImplementation(m);
    // resolve _impl ivar offset dynamically (same as AGX_WIRE_IOSURF); fallback 0x208
    static ptrdiff_t rr_impl_off = 0;
    { Class tc = objc_getClass("AGXG13GFamilyTexture");
      Ivar iv = tc ? class_getInstanceVariable(tc, "_impl") : NULL;
      rr_impl_off = iv ? ivar_getOffset(iv) : 0x208;
      fprintf(stderr, "#### RR-WIRE: _impl ivar offset=%#tx\n", rr_impl_off); }
    IMP nimp = imp_implementationWithBlock(^void(id self, MTLRegion region,
                                                 NSUInteger level, const void *bytes, NSUInteger bpr) {
        void *impl = *(void **)((char *)(__bridge void *)self + rr_impl_off);
        if ((uintptr_t)impl > 0x1000) {
            void **slot    = (void **)((char *)impl + 0xa0);
            uint8_t layout = *(uint8_t *)((char *)impl + 0x184);
            void *back     = *slot;
            // Bulletproof per-call record (survives the crash; last write = the
            // crashing texture). stderr logs were lost to buffering on crash.
            { int fd = open("/tmp/macws_rr_last", O_WRONLY | O_CREAT | O_TRUNC, 0644);
              if (fd >= 0) { char b[192];
                int n = snprintf(b, sizeof b,
                    "impl=%p back=%p layout=%u dim=%lux%lu reg=%lux%lu lvl=%lu bpr=%lu cls=%s\n",
                    impl, back, layout, (unsigned long)[self width], (unsigned long)[self height],
                    (unsigned long)region.size.width, (unsigned long)region.size.height,
                    (unsigned long)level, (unsigned long)bpr, object_getClassName(self));
                if (n > 0) write(fd, b, (size_t)n); close(fd); } }
            // FIX-TEST: wire 0xa0 when NULL, AND force-wire layout-3 (the blur crash)
            // once per texture — tests whether +0xa0 is the field writeRegion reads.
            BOOL mine = objc_getAssociatedObject(self, &kMacwsRRBackingKey) != nil;
            if (back == NULL || (layout == 3 && !mine)) {
                NSUInteger tw = [self width], th = [self height];
                NSUInteger rw = region.size.width ? region.size.width : 1;
                NSUInteger bpe = bpr / rw; if (bpe == 0) bpe = 4;
                size_t W = ((size_t)tw + 255) & ~(size_t)255;
                size_t H = ((size_t)th + 255) & ~(size_t)255;
                size_t sz = W * H * bpe + (1u << 20);
                if (sz < (1u << 16)) sz = (1u << 16);
                if (sz > (128u << 20)) sz = (128u << 20);
                NSMutableData *d = [NSMutableData dataWithLength:sz];
                if (d) {
                    objc_setAssociatedObject(self, &kMacwsRRBackingKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    *(void * volatile *)slot = [d mutableBytes];
                    static int n = 0; if (n++ < 16) {
                        fprintf(stderr, "#### RR-WIRE WIRED impl=%p 0xa0:%p->%p layout=%u %lux%lu sz=%zu\n",
                                impl, back, [d mutableBytes], layout, (unsigned long)tw, (unsigned long)th, sz);
                        fflush(stderr);
                    }
                }
            }
        }
        ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))s_orig_rr_wire)(
            self, s_rr_wire_sel, region, level, bytes, bpr);
    });
    method_setImplementation(m, nimp);
    fprintf(stderr, "#### RR-WIRE installed: replaceRegion wires NULL +0xa0 backing (orig=%p)\n",
            (void *)s_orig_rr_wire);
}

// Actual mapped/writable extent of the VM region starting at-or-below p,
// measured from p (0 if p is unmapped). Used to expose the truncated CPU
// mapping of native AGX buffers in chroot.
static size_t macws_mapped_extent_from(void *p) {
    if (!p) return 0;
    // Walk CONTIGUOUS, writable VM regions starting at p. AGX may map a buffer
    // as several adjacent sub-regions, so a single vm_region undercounts; sum
    // them until the first gap or non-writable region.
    vm_address_t want = (vm_address_t)p;
    size_t total = 0;
    for (int i = 0; i < 4096; i++) {
        vm_address_t a = want;
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &a, &sz,
                                        VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS) break;
        if (a > want) break;                    // gap: `want` is unmapped
        if (!(info.protection & VM_PROT_WRITE)) break;  // not writable
        vm_address_t region_end = a + sz;
        if (region_end <= want) break;          // no forward progress
        total += (size_t)(region_end - want);
        want = region_end;                      // continue from this region's end
    }
    return total;
}

// WSQ capture: swizzle the AGX device's newCommandQueue* so we keep a reference to WS's OWN
// compositor command queue (the only one whose command buffers actually submit in the chroot).
// Installed from install_agx_init_redirect (when WS discovers the AGX device) — BEFORE SkyLight's
// compositor creates its queue, so we catch the first one. arm64e-safe (C IMP + method_setImplementation).
static id (*orig_newCommandQueue)(id, SEL) = NULL;
static id (*orig_newCommandQueueN)(id, SEL, NSUInteger) = NULL;
static id hooked_newCommandQueue(id self, SEL _cmd) {
    id q = orig_newCommandQueue ? orig_newCommandQueue(self, _cmd) : nil;
    if (!g_ws_cmdq && q) { g_ws_cmdq = q; fprintf(stderr, "#### WSQ captured newCommandQueue=%p dev=%s\n", (void *)q, class_getName([self class])); }
    return q;
}
static id hooked_newCommandQueueN(id self, SEL _cmd, NSUInteger n) {
    id q = orig_newCommandQueueN ? orig_newCommandQueueN(self, _cmd, n) : nil;
    if (!g_ws_cmdq && q) { g_ws_cmdq = q; fprintf(stderr, "#### WSQ captured newCommandQueueWithMax=%p n=%lu dev=%s\n", (void *)q, (unsigned long)n, class_getName([self class])); }
    return q;
}
static void install_wsqueue_capture(Class agx) {
    Method m1 = class_getInstanceMethod(agx, @selector(newCommandQueue));
    if (m1) { orig_newCommandQueue = (void *)method_getImplementation(m1); method_setImplementation(m1, (IMP)hooked_newCommandQueue); }
    Method m2 = class_getInstanceMethod(agx, @selector(newCommandQueueWithMaxCommandBufferCount:));
    if (m2) { orig_newCommandQueueN = (void *)method_getImplementation(m2); method_setImplementation(m2, (IMP)hooked_newCommandQueueN); }
    fprintf(stderr, "#### WSQ capture installed on %s (newCommandQueue=%p withMax=%p)\n", class_getName(agx), (void *)m1, (void *)m2);
}

static void install_agx_init_redirect(Class agx) {
    install_wsqueue_capture(agx);  // WSQ-TEST: keep WS's compositor command queue
    install_agx_initimpl_hook();  // install diag hook on texture class
    install_updatebind_hook();    // BINDFIX: substitute IOSurface GPU VA when bind gets 0 (gated)
    install_iogpu_init_hook();    // install diag hook on IOGPUMetalTexture super-init
    install_cbri_probe();         // log commandBufferResourceInfo returns
    install_shadow_isolation();   // diag: skip layout!=0 replaceRegion (gated)
    install_replaceregion_backing_wire();  // REAL FIX: wire NULL +0xa0 backing (gated)
    // (no pipeline fallback — see removed block above)

    SEL sel = @selector(initWithAcceleratorPort:);
    BOOL ok = class_addMethod(agx, sel, (IMP)agx_initWithAcceleratorPort_impl, "@@:i");
    fprintf(stderr, "#### MACWS_AGX_NATIVE class_addMethod(AGXG13GFamilyDevice, initWithAcceleratorPort:) = %d\n", (int)ok);

    // 2026-06-20 — supportsMemorylessRenderTargets: make our AGXG13GFamilyDevice
    // return YES so CA::OGL::MetalContext init sets bit 3 of [self+0xcb0] (the
    // memoryless-supported flag).  When that bit is set, CA::OGL::MetalContext::
    // add_memoryless_textures (QuartzCore 0x1897c0a28) passes a descriptor with
    // storageMode=MTLStorageModeMemoryless(3) instead of downgrading to Private(2)
    // up-front.  Then our hooked_newTextureWithDescriptor: detects storageMode==3
    // and routes via the native AGXG13GFamilyDevice path (no IOSurface alloc).
    //
    // The M1/A14+ hardware natively supports memoryless render targets; the
    // chroot's AGXG13GFamilyDevice may already implement this method
    // correctly, but if it returns NO (because some chroot-only fragile init
    // path failed), CA downgrades and we waste 31 MB per "memoryless" call.
    //
    // class_addMethod only adds when the class doesn't already implement.
    // If AGXG13GFamilyDevice already has supportsMemorylessRenderTargets,
    // class_addMethod fails and we trust the native value (which on iOS
    // hardware should be YES).  No swizzle / forced override — we let
    // the native impl run if present; only install our YES-stub as a
    // fallback for missing-selector case.
    {
        SEL smrt_sel = sel_registerName("supportsMemorylessRenderTargets");
        IMP smrtYes = imp_implementationWithBlock(^BOOL(id s) {
            static int smrt_call_log = 0;
            if (smrt_call_log++ < 6) {
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE supportsMemorylessRenderTargets CALLED on instance=%p class=%s -> YES\n",
                    (void *)s, s ? class_getName([s class]) : "(nil)");
            }
            return YES;
        });
        // Apply to AGXG13GFamilyDevice AND any subclasses (chroot may have
        // AGXG13GMobileFamilyDevice etc. that override supportsMemoryless to NO).
        unsigned int n = 0;
        Class *all = objc_copyClassList(&n);
        int applied = 0;
        for (unsigned int i = 0; i < n; i++) {
            Class c = all[i];
            // walk superclasses; if any ancestor == agx, this is a subclass (or itself)
            Class p = c;
            BOOL match = NO;
            while (p) {
                if (p == agx) { match = YES; break; }
                p = class_getSuperclass(p);
            }
            if (!match) continue;
            Method m = class_getInstanceMethod(c, smrt_sel);
            if (m) {
                method_setImplementation(m, smrtYes);
                applied++;
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE supportsMemorylessRenderTargets: overrode on %s\n",
                    class_getName(c));
            } else {
                BOOL added = class_addMethod(c, smrt_sel, smrtYes, "c@:");
                if (added) applied++;
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE supportsMemorylessRenderTargets: added on %s = %d\n",
                    class_getName(c), (int)added);
            }
        }
        free(all);
        fprintf(stderr,
            "#### MACWS_AGX_NATIVE supportsMemorylessRenderTargets: total class overrides=%d\n",
            applied);
    }

    // 2026-06-20 — Tile pipeline diagnostic for MACWS_AGX_NATIVE blur path.
    //
    // Backdrop blur on Apple Silicon TBDR uses tile shaders.  The chain is:
    //  CA::OGL::MetalContext::add_memoryless_textures  (creates intermediate target)
    //  CA::OGL::MetalContext::get_tile_pipeline        (QC 0x1897c10b0)
    //  → bl _objc_msgSend$newRenderPipelineStateWithTileDescriptor:options:reflection:error:
    //    at 0x1897c1274 — call routes through MTLDevice (= AGXG13GFamilyDevice
    //    under MACWS_AGX_NATIVE).  Returns nil + error on failure; CA's
    //    fallback is a pure-render-pipeline downsample (slower, more memory).
    //
    // Wrap AGXG13GFamilyDevice's newRenderPipelineStateWithTileDescriptor:
    // options:reflection:error: to log (a) descriptor properties on entry,
    // (b) returned pipeline state + error on exit.  This tells us whether
    // the native AGX path actually creates tile pipelines or fails internally.
    //
    // Wrapping via method_setImplementation + saved orig pointer (NOT swizzle —
    // swizzle is messy when we need to call %orig and the original might be
    // missing on chroot-loaded variant).
    {
        SEL tile_sel = sel_registerName("newRenderPipelineStateWithTileDescriptor:options:reflection:error:");
        typedef id (*tile_orig_t)(id, SEL, id, NSUInteger, void *_Nullable*, NSError **);
        // Per-class original IMP store (Apple Silicon has 2-4 device classes; map keyed by class).
        __block CFMutableDictionaryRef origMap = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        IMP wrap = imp_implementationWithBlock(^id(id self_, id desc, NSUInteger opts,
                                                   void *_Nullable* reflection, NSError **err) {
            static int log_n = 0;
            BOOL log_this = (log_n++ < 8);
            Class cls = [self_ class];
            tile_orig_t orig = (tile_orig_t)CFDictionaryGetValue(origMap, (__bridge const void *)cls);
            // Walk superclasses upward to find a stored orig if subclass missed
            for (Class c = cls; c && !orig; c = class_getSuperclass(c))
                orig = (tile_orig_t)CFDictionaryGetValue(origMap, (__bridge const void *)c);
            if (log_this) {
                NSUInteger raster_w = [desc respondsToSelector:@selector(rasterSampleCount)]
                                      ? (NSUInteger)[(id)desc rasterSampleCount] : 0;
                NSUInteger thgrp_mem = [desc respondsToSelector:@selector(threadgroupMemoryLength)]
                                       ? (NSUInteger)[(id)desc threadgroupMemoryLength] : 0;
                NSUInteger tile_w = [desc respondsToSelector:@selector(tileWidth)]
                                    ? (NSUInteger)[(id)desc tileWidth] : 0;
                NSUInteger tile_h = [desc respondsToSelector:@selector(tileHeight)]
                                    ? (NSUInteger)[(id)desc tileHeight] : 0;
                fprintf(stderr,
                    "#### TILE-PIPE in: dev=%s descClass=%s rasterSample=%lu thgrpMem=%lu tile=%lux%lu\n",
                    class_getName(cls),
                    class_getName([desc class]),
                    (unsigned long)raster_w, (unsigned long)thgrp_mem,
                    (unsigned long)tile_w, (unsigned long)tile_h);
            }
            NSError *local_err = nil;
            NSError **err_ptr = err ? err : &local_err;
            *err_ptr = nil;
            id ret = nil;
            if (orig) {
                ret = orig(self_, tile_sel, desc, opts, reflection, err_ptr);
            } else if (log_this) {
                fprintf(stderr, "#### TILE-PIPE: NO original IMP found for %s — returning nil\n",
                        class_getName(cls));
            }
            if (log_this) {
                fprintf(stderr,
                    "#### TILE-PIPE out: pipeline=%p class=%s err=%s\n",
                    (void *)ret,
                    ret ? class_getName([ret class]) : "(nil)",
                    (*err_ptr) ? [[(*err_ptr) localizedDescription] UTF8String] : "(nil)");
            }
            return ret;
        });
        // Walk subclasses + agx; for each that has the method, save orig + replace
        unsigned int nc = 0;
        Class *all = objc_copyClassList(&nc);
        int wrapped = 0;
        for (unsigned int i = 0; i < nc; i++) {
            Class c = all[i];
            Class p = c;
            BOOL match = NO;
            while (p) {
                if (p == agx) { match = YES; break; }
                p = class_getSuperclass(p);
            }
            if (!match) continue;
            Method m = class_getInstanceMethod(c, tile_sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == wrap) continue; // already wrapped (via inheritance from parent)
            CFDictionarySetValue(origMap, (__bridge const void *)c, (const void *)cur);
            method_setImplementation(m, wrap);
            wrapped++;
            fprintf(stderr,
                "#### MACWS_AGX_NATIVE tile-pipeline probe wrapped %s (orig=%p)\n",
                class_getName(c), (void *)cur);
        }
        free(all);
        fprintf(stderr,
            "#### MACWS_AGX_NATIVE tile-pipeline probe: %d class(es) wrapped\n", wrapped);
    }

    // 2026-06-22 — STORAGE-MODE FIX (always-on for AGX-native; the real blur
    // root cause). BUFDIAG runtime evidence (/tmp/macws_bufdiag.log) proved the
    // backdrop-blur / gamma-LUT buffers that crash WS are NATIVE AGX buffers
    // (synth=0: real distinct GPU VA, GPU-coherent, reslen==requested) created
    // with **opt=0x10 = MTLResourceStorageModeManaged**. Managed is a macOS-ONLY
    // storage mode (separate CPU+GPU copies synced via didModifyRange). iOS AGX
    // has no Managed mode → it builds the buffer but the CPU `-contents` mapping
    // is malformed/partial, so a full-length write overruns into unmapped/RO
    // pages → SIGSEGV (WS .ips: copy_image_to_texture, create_gamma_lut_buffer).
    //
    // Fix: translate Managed → Shared at the -newBufferWithLength:options:
    // boundary. On M1 unified memory a Shared buffer is a single physical
    // allocation mapped BOTH CPU-writable (full length, no overrun) AND
    // GPU-coherent (the GPU samples exactly what CA wrote) — so this fixes the
    // crash AND lets blur actually render. CA's didModifyRange: becomes a
    // harmless no-op on Shared. Only Managed is rewritten; Shared/Private/
    // Memoryless pass through untouched. Logging stays gated on
    // /tmp/macws_buf_diag.
    {
        SEL nbl_sel = sel_registerName("newBufferWithLength:options:");
        typedef id (*nbl_t)(id, SEL, NSUInteger, NSUInteger);
        __block CFMutableDictionaryRef nblMap = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        IMP nblWrap = imp_implementationWithBlock(^id(id self_, NSUInteger len, NSUInteger opt) {
            Class cls = [self_ class];
            nbl_t orig = (nbl_t)CFDictionaryGetValue(nblMap, (__bridge const void *)cls);
            for (Class c = cls; c && !orig; c = class_getSuperclass(c))
                orig = (nbl_t)CFDictionaryGetValue(nblMap, (__bridge const void *)c);
            // Managed (storage bits 4-7 == 0x10) → Shared (0x0). iOS has no
            // Managed mode; Shared is the coherent unified-memory equivalent.
            NSUInteger sopt = opt;
            if ((opt & 0xF0) == 0x10) sopt = opt & ~(NSUInteger)0xF0;
            // EXPERIMENT (gated /tmp/macws_no_suballoc): force standalone resource.
            // RE-confirmed (AGXG13GFamilyDevice -newBufferWithLength: @0x1e574dc24):
            // isSuballocDisabled = byte at device+0x7cd. With suballoc ON, a
            // sub-buffer's CPU contents = parentHeapCPU + offset, valid only as far
            // as the parent heap's KERNEL-TRUNCATED CPU mapping → large sub-buffers
            // overrun. Standalone resources may get a full CPU map (BUFDIAG #3
            // showed a 22MB contiguous mapping for a standalone buffer).
            uint8_t *suballoc_flag = (uint8_t *)((char *)(__bridge void *)self_ + 0x7cd);
            uint8_t saved_suballoc = *suballoc_flag;
            if (access("/tmp/macws_no_suballoc", F_OK) == 0 && len > 0x4000)
                *suballoc_flag = 1;
            id buf = orig ? orig(self_, nbl_sel, len, sopt) : nil;
            *suballoc_flag = saved_suballoc;
            if (access("/tmp/macws_buf_diag", F_OK) == 0) {
                static _Atomic int bn = 0;
                int n = atomic_fetch_add(&bn, 1);
                if (buf && n < 64) {
                    void *cont = [buf contents];
                    uint64_t gpu = [buf gpuAddress];
                    size_t ms = cont ? malloc_size(cont) : 0;
                    size_t vext = macws_mapped_extent_from(cont);
                    int synth = (cont && gpu == (uint64_t)(uintptr_t)cont);
                    char b[300];
                    int k = snprintf(b, sizeof b,
                        "BUFDIAG #%d req=%lu reslen=%lu opt=%#lx->%#lx contents=%p gpuAddr=%#llx malloc_size=%zu vm_extent=%#zx suballocDisabled=%d synth=%d cls=%s\n",
                        n, (unsigned long)len, (unsigned long)[buf length],
                        (unsigned long)opt, (unsigned long)sopt,
                        cont, (unsigned long long)gpu, ms, vext, (int)saved_suballoc, synth, class_getName([buf class]));
                    int fd = open("/tmp/macws_bufdiag.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
                    if (fd >= 0) { if (k > 0) write(fd, b, (size_t)k); fsync(fd); close(fd); }
                    // One-shot: for the first large (>16KB) buffer, scan the
                    // IOGPUMetalResource struct (embedded at buf+0x18) AND the
                    // AGX _impl C++ object (*(buf+0x208)) for any pointer field
                    // that holds a FULL-length CPU mapping. The kernel maps the
                    // resource full (createMappingInTask len=0=getLength); if a
                    // full mapping exists in this task it must be reachable from a
                    // resource/impl field — find it and we can repoint -contents.
                    static _Atomic int dumped_big = 0;
                    if (len > 0x4000 && atomic_fetch_add(&dumped_big, 1) == 0) {
                        int df = open("/tmp/macws_bufstruct.log", O_WRONLY|O_CREAT|O_TRUNC, 0644);
                        if (df >= 0) {
                            const char *bp = (const char *)(__bridge void *)buf;
                            void *impl = *(void * const *)(bp + 0x208);
                            char d[256];
                            int dk = snprintf(d, sizeof d,
                                "BUFSTRUCT buf=%p len=%lu contents=%p impl=%p — pointer fields w/ vm_extent:\n",
                                (void*)buf, (unsigned long)len, cont, impl);
                            write(df, d, dk);
                            for (int off = 0x18; off <= 0x160; off += 8) {
                                uint64_t v = *(const uint64_t *)(bp + off);
                                if (v >= 0x100000000ULL && v < 0x300000000000ULL) {
                                    size_t ext = macws_mapped_extent_from((void*)(uintptr_t)v);
                                    dk = snprintf(d, sizeof d, "  res+0x%x = %#llx  vm_extent=%#zx%s\n",
                                        off, (unsigned long long)v, ext, ext >= len ? "  <== FULL!" : "");
                                    write(df, d, dk);
                                }
                            }
                            if ((uintptr_t)impl > 0x100000000ULL) {
                                const char *ip = (const char *)impl;
                                for (int off = 0; off <= 0x200; off += 8) {
                                    uint64_t v = *(const uint64_t *)(ip + off);
                                    if (v >= 0x100000000ULL && v < 0x300000000000ULL) {
                                        size_t ext = macws_mapped_extent_from((void*)(uintptr_t)v);
                                        dk = snprintf(d, sizeof d, "  impl+0x%x = %#llx  vm_extent=%#zx%s\n",
                                            off, (unsigned long long)v, ext, ext >= len ? "  <== FULL!" : "");
                                        write(df, d, dk);
                                    }
                                }
                            }
                            fsync(df); close(df);
                        }
                    }
                }
            }
            return buf;
        });
        unsigned int nc = 0; Class *all = objc_copyClassList(&nc); int w = 0;
        for (unsigned int i = 0; i < nc; i++) {
            Class c = all[i]; Class p = c; BOOL match = NO;
            while (p) { if (p == agx) { match = YES; break; } p = class_getSuperclass(p); }
            if (!match) continue;
            Method m = class_getInstanceMethod(c, nbl_sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == nblWrap) continue;
            CFDictionarySetValue(nblMap, (__bridge const void *)c, (const void *)cur);
            method_setImplementation(m, nblWrap); w++;
        }
        free(all);
        fprintf(stderr, "#### MACWS_AGX_NATIVE newBufferWithLength: Managed→Shared translation installed on %d class(es)\n", w);
    }

    // 2026-06-20 — setFragmentTexture: / setVertexTexture: nil guard.
    //
    // CA::OGL::MetalContext::encode_placeholder_cube binds a "placeholder"
    // cube texture during backdrop-blur rendering (filter_backdrop path).
    // In chroot, cube textures fall through to the native AGX path which
    // can return nil (because AGXTexture init's cascade isn't complete for
    // non-2D types).  CA then passes nil into setFragmentTexture:, and
    // AGX::ResourceGroupUsage::setTexture dereferences the nil texture
    // pointer at offset 0x168 → EXC_BAD_ACCESS → WS dies before any
    // blur pixel reaches the framebuffer.
    //
    // Wrap [AGXG13GFamilyRenderContext setFragmentTexture:atIndex:] (and
    // setVertexTexture:atIndex: by symmetry) to NOP the call when the
    // texture argument is nil — i.e., skip the binding instead of
    // letting AGX deref nil.  This is a defensive guard, not a feature
    // patch: rendering proceeds with that texture slot UNBOUND, which
    // for placeholder bindings is exactly what we want (it's a
    // placeholder — there's no real environment map to sample).
    {
        unsigned int nc = 0;
        Class *all = objc_copyClassList(&nc);
        for (unsigned int side = 0; side < 2; side++) {
            const char *sel_name = side == 0
                ? "setFragmentTexture:atIndex:"
                : "setVertexTexture:atIndex:";
            SEL sel = sel_registerName(sel_name);
            typedef void (*set_tex_t)(id, SEL, id, NSUInteger);
            __block CFMutableDictionaryRef origMap2 =
                CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
            const char *sel_name_copy = sel_name;
            IMP wrap = imp_implementationWithBlock(^(id self_, id tex, NSUInteger idx) {
                Class cls = [self_ class];
                set_tex_t orig = (set_tex_t)CFDictionaryGetValue(origMap2,
                                                                 (__bridge const void *)cls);
                for (Class c = cls; c && !orig; c = class_getSuperclass(c))
                    orig = (set_tex_t)CFDictionaryGetValue(origMap2,
                                                           (__bridge const void *)c);
                if (!tex) {
                    static int nil_guard_log[2] = {0, 0};
                    int slot = (strstr(sel_name_copy, "Fragment") != NULL) ? 0 : 1;
                    if (nil_guard_log[slot]++ < 3) {
                        fprintf(stderr,
                            "#### NIL-TEX-GUARD: %s nil tex@%lu — skipping binding "
                            "(caller likely encode_placeholder_cube; CA tolerates unbound slot)\n",
                            sel_name_copy, (unsigned long)idx);
                    }
                    return;
                }
                if (orig) orig(self_, sel, tex, idx);
            });
            // Direct class lookup — classlist scan didn't fire previously.
            // The exact class names are AGXG13GFamilyRenderContext (and possibly
            // AGXG13GRenderContext as a parent).
            const char *rc_names[] = {
                "AGXG13GFamilyRenderContext",
                "AGXG13GRenderContext",
                "AGXRenderContext",
                "AGXG13GComputeContext",
                NULL,
            };
            int found = 0;
            for (int j = 0; rc_names[j]; j++) {
                Class c = objc_getClass(rc_names[j]);
                if (!c) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard: class %s NOT registered\n", rc_names[j]);
                    continue;
                }
                Method m = class_getInstanceMethod(c, sel);
                if (!m) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard: %s has no %s\n",
                            rc_names[j], sel_name);
                    continue;
                }
                IMP cur = method_getImplementation(m);
                if (cur == wrap) continue;
                CFDictionarySetValue(origMap2, (__bridge const void *)c, (const void *)cur);
                method_setImplementation(m, wrap);
                found++;
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE nil-guard wrapped %s on %s (orig=%p)\n",
                    sel_name, rc_names[j], (void *)cur);
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard %s: %d class(es) wrapped\n",
                    sel_name, found);
        }
        free(all);
    }

#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
    // Swizzle AGXG13GFamilyDevice's newTextureWithDescriptor variants so the
    // ROUTE-IOSURF + memoryless storageMode swap reach SkyLight's actual
    // device call (SkyLight's compositor goes [_device newTextureWithDescriptor:]
    // where _device is AGXG13GFamilyDevice, NOT MTLSimDevice/MTLFakeDevice).
    //
    // arm64e on-device gate: MTLFakeDevice is excluded from the arm64e slice
    // (see commit 7467630 — on-device lld emits a plain non-auth rebase for
    // class_t->data and macOS libobjc autda's PAC-trap on it).  Referencing
    // MTLFakeDevice.class on arm64e fails to compile.  The chroot WS process
    // is single-arch arm64 (`Non-fat file: WindowServer is architecture: arm64`),
    // so the arm64 build of libmachook is what dyld loads into WS — the arm64
    // swizzle is sufficient.  The arm64e slice ships for arm64e processes
    // (other chroot daemons / Apple binaries) that don't need this AGX hook.
    SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
    SEL iosurf_hook_sel = @selector(hooked_newTextureWithDescriptor:iosurface:plane:);
    if (class_getInstanceMethod(agx, iosurf_sel)) {
        swizzle2(agx, iosurf_sel, MTLFakeDevice.class, iosurf_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:\n");
    }
    SEL plain_sel = @selector(newTextureWithDescriptor:);
    SEL plain_hook_sel = @selector(hooked_newTextureWithDescriptor:);
    if (class_getInstanceMethod(agx, plain_sel)) {
        swizzle2(agx, plain_sel, MTLFakeDevice.class, plain_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:\n");
    }
#endif // !arm64e || !on-device — MTLFakeDevice unavailable on arm64e on-device

    // -[AGXBuffer initWithDevice:bytes:length:options:deallocator:
    //                pinnedGPUAddress:] is what SkyLight calls (caller chain
    // confirmed via backtrace in IOConnectCallMethod_new).  When `bytes` is
    // malloc'd CPU memory the iOS IOGPU kernel rejects the sel=0xa type=0x80
    // sub-resource — Apple's malloc returns pages with a private (non-MAP_
    // SHARED) backing that the GPU can't pin.  Same trick as the existing
    // MTLFakeDevice hooked_newBufferWithBytesNoCopy: vm_remap to a MAP_SHARED
    // mirror, pass that VA to %orig, and chain the deallocator to free both.
    Class agxbuf = objc_getClass("AGXBuffer");
    if (agxbuf) {
        SEL bytes_sel = sel_registerName(
            "initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress:");
        Method m = class_getInstanceMethod(agxbuf, bytes_sel);
        if (m) {
            typedef id (*orig_t)(id, SEL, id, void *, NSUInteger,
                                  NSUInteger, void (^)(void *, NSUInteger),
                                  uint64_t);
            static orig_t s_orig = NULL;
            s_orig = (orig_t)method_getImplementation(m);
            IMP shim = imp_implementationWithBlock(^id(
                    id self, id dev, void *bytes, NSUInteger length,
                    NSUInteger opt,
                    void (^deallocator)(void *, NSUInteger),
                    uint64_t pinnedGPUAddress) {
                static int rmap_log = 0;
                static int seen_log = 0;
                if (seen_log < 4) {
                    fprintf(stderr,
                        "#### AGXBuffer init-bytes ENTRY self=%p dev=%p bytes=%p len=%lu opt=%lu pin=%#llx malloc_size=%zu\n",
                        self, dev, bytes, (unsigned long)length, (unsigned long)opt,
                        (unsigned long long)pinnedGPUAddress,
                        bytes ? malloc_size(bytes) : 0);
                    seen_log++;
                }
                // 2026-06-19 — when pinnedGPUAddress != 0 the caller (e.g.
                // SkyLight MetalTiledBacking::PrepareForUse) wants the
                // buffer placed at a specific GPU VA. On macOS this maps
                // to kernel sel=0x9 type=0x80 scanout-class allocation,
                // which iOS kernel treats as a display-engine source —
                // wires our buffer to the physical LCD and corrupts iOS UI
                // (proven 2026-06-19). The kernel's NoMemory rejection is
                // the safe behavior. Short-circuit to nil here so we don't
                // call %orig (which would call IOGPUResourceCreate and try
                // sel=0x9 type=0x80). SkyLight's PrepareForUse already has
                // a tolerate-nil hook in mac_hooks.m, so nil should flow
                // through.
                // Env-gated MACWS_AGX_SKIP_PINNED_ALLOC (default ON when
                // MACWS_AGX_NATIVE=1) so we can A/B against the old
                // vm_remap path.
                // 2026-06-20 — Widened gate. Previously only fired when
                // pinnedGPUAddress != 0, but runtime traces show this init
                // is called with pinnedGPUAddress=0 from
                // MetalTiledBacking::PrepareForUse AND the internal code
                // path still goes to kernel sel=0x9 type=0x80 (which
                // iOS rejects). The init-bytes variant always routes
                // through that broken path. Redirect for any AGX-native
                // invocation.
                if (getenv("MACWS_AGX_NATIVE") &&
                    !getenv("MACWS_AGX_KEEP_PINNED_ALLOC")) {
                    // 2026-06-20 — REDIRECT-iOS-NATIVE.
                    // Previously this returned nil because the macOS-pattern
                    // pinnedGPUAddress: call routes through kernel sel=0x9
                    // type=0x80 (scanout class) which iOS structurally
                    // rejects from chroot. The "self-implement tile buffer"
                    // detour was overcomplicated.
                    //
                    // Real fix: just redirect to `[device newBufferWithLength:
                    // options:]` — iOS-native Metal's normal buffer alloc
                    // which goes through kernel sel=0x9 type=0 heap (known
                    // working, 3700+ successes per WS lifetime). The buffer
                    // gets a GPU VA from AGX (not the caller-requested
                    // pinned VA). SkyLight queries it via [buffer gpuAddress]
                    // at bind time, so the mismatch is transparent to
                    // downstream code. iOS Metal tile-pipeline support is
                    // native on M1 — blur/vibrancy should render properly
                    // once the buffer is alloc'd through this iOS-compatible
                    // path.
                    //
                    // If the caller supplied init `bytes`, memcpy them into
                    // the new buffer's CPU contents. Invoke their deallocator
                    // immediately since we no longer need the original
                    // pointer.
                    // 2026-06-22 — CRASH FIX (runtime-confirmed SEGV_ACCERR in
                    // _platform_memmove ← this block ← CA::OGL::MetalContext::
                    // copy_image_to_texture ← render_contents_background, i.e. the
                    // NSVisualEffectView backdrop-blur path; WindowServer.err exit
                    // 139). The caller (CoreAnimation, thinking it's on macOS)
                    // passes MTLResourceStorageModeManaged (storage bits 4-7 ==
                    // 0x10). iOS has NO Managed storage mode — feeding it to iOS
                    // -newBufferWithLength: returns a buffer whose CPU `contents`
                    // mapping is undersized / wrong-permission, so the unbounded
                    // memcpy below overran into a read-only page. This init-BYTES
                    // variant must produce CPU-writable storage to receive `bytes`
                    // anyway, so force Shared (fully GPU-accessible on M1 unified
                    // memory — no correctness loss). Keep the cache/hazard bits.
                    MTLResourceOptions safe_opt = opt & ~(MTLResourceOptions)0xF0;
                    static int redirect_log = 0;
                    if (redirect_log++ < 8) {
                        fprintf(stderr,
                            "#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE: "
                            "self=%p dev=%p len=%lu opt=%#lx pin=%#llx "
                            "-> [dev newBufferWithLength:%lu options:%#lx]\n",
                            self, dev, (unsigned long)length,
                            (unsigned long)opt,
                            (unsigned long long)pinnedGPUAddress,
                            (unsigned long)length, (unsigned long)safe_opt);
                    }
                    id<MTLBuffer> ios_buf = [(id<MTLDevice>)dev
                        newBufferWithLength:length options:safe_opt];
                    if (ios_buf) {
                        if (bytes && length > 0) {
                            void *contents = [ios_buf contents];
                            NSUInteger blen = [ios_buf length];
                            // Never copy more than the destination's CPU backing
                            // actually holds. RUNTIME-CONFIRMED (WS .ips
                            // 2026-06-22-131221: memmove dst+0x4000 fault): the
                            // chroot's synthesized AGXG13GFamilyBuffer reports the
                            // *requested* -length (e.g. 128KB) but backs -contents
                            // with only a small (16KB calloc) scratch, so a
                            // [length]-based clamp still overruns. malloc_size() on
                            // the contents pointer returns that scratch's true size;
                            // use it as the authoritative CPU-writable bound.
                            if (contents && blen > 0) {
                                size_t cap = (size_t)blen;
                                size_t ms  = malloc_size(contents);
                                if (ms > 0 && ms < cap) cap = ms;
                                size_t ncopy = (size_t)length < cap ? (size_t)length : cap;
                                memcpy(contents, bytes, ncopy);
                                if (ncopy < length) {
                                    fprintf(stderr,
                                        "#### AGXBuffer REDIRECT: UNDERSIZED dst (len=%lu malloc_size=%zu) < requested %lu — clamped memcpy to %zu (GPU will see truncated data)\n",
                                        (unsigned long)blen, ms, (unsigned long)length, ncopy);
                                }
                            }
                        }
                        if (deallocator) {
                            // Caller expects bytes to be freed eventually.
                            // We've copied; release them now.
                            deallocator(bytes, length);
                        }
                        if (redirect_log < 12) {
                            fprintf(stderr,
                                "#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE result: "
                                "%p class=%s len=%lu gpuAddr=%#llx\n",
                                (void *)ios_buf,
                                class_getName([(id)ios_buf class]),
                                (unsigned long)[ios_buf length],
                                (unsigned long long)0ULL);
                        }
                    }
                    return (id)ios_buf;
                }
                if (bytes && length > 0 && malloc_size(bytes) > 0) {
                    vm_address_t mirrored = 0;
                    vm_prot_t cur_p, max_p;
                    kern_return_t kr = vm_remap(
                        mach_task_self(), &mirrored, length, 0,
                        VM_FLAGS_ANYWHERE, mach_task_self(),
                        (vm_address_t)bytes, false, &cur_p, &max_p,
                        VM_INHERIT_SHARE);
                    if (kr == KERN_SUCCESS) {
                        vm_protect(mach_task_self(), mirrored, length,
                                   NO, VM_PROT_READ | VM_PROT_WRITE);
                        void *origBytes = bytes;
                        void (^origDealloc)(void *, NSUInteger) = deallocator;
                        deallocator = ^(void *p, NSUInteger l) {
                            vm_deallocate(mach_task_self(),
                                          (vm_address_t)p, l);
                            if (origDealloc) origDealloc(origBytes, l);
                        };
                        if (rmap_log < 4) {
                            fprintf(stderr,
                                "#### AGXBuffer bytes: vm_remap'd %p -> %p (len=%lu)\n",
                                origBytes, (void*)mirrored, (unsigned long)length);
                            rmap_log++;
                        }
                        bytes = (void *)mirrored;
                    } else {
                        if (rmap_log < 4) {
                            fprintf(stderr,
                                "#### AGXBuffer bytes: vm_remap FAILED %p len=%lu kr=%d\n",
                                bytes, (unsigned long)length, kr);
                            rmap_log++;
                        }
                    }
                }
                return s_orig(self, bytes_sel, dev, bytes, length, opt,
                              deallocator, pinnedGPUAddress);
            });
            method_setImplementation(m, shim);
            fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled -[AGXBuffer initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress:]\n");
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE AGXBuffer initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress: NOT FOUND\n");
        }
    }

    // No-op methods that crash in chroot because their setup dependencies
    // (timers, mempools, dispatch sources, etc.) require kernel state that
    // wasn't fully initialized. Downstream code may not actually need them.
    // setupDeferred: the dispatch_once block crashes in chroot; the AGXMetal13_3
    // binary cmp/b.hi patches in mac_hooks.m skip its mempool grow calls, but
    // post-grow code still reads uninitialized ivars. As a workaround, no-op
    // the ObjC method entirely — combined with proper init redirect this allows
    // newBuffer/newTexture/newCommandQueue/newCommandBuffer to succeed (probe7
    // stages 1-6+8). Texture/buffer creation reads OTHER ivars set by the 2-arg
    // init, not the deferred mempool ivars.
    // Note: setupDeferred is NOT noop'd here anymore. Texture init reads
    // mempool storage that setupDeferred populates (see crash in
    // AGX::Mempool<...ImageStateEncoderGen6...>::grow when WS creates an
    // IOSurface-backed texture). The alert* methods are still noop'd because
    // their dispatch_source setup fails in chroot but no other code uses them.
    const char *noopMethods[] = {
        "alertCommandBufferActivityStart",
        "alertCommandBufferActivityComplete",
        NULL
    };
    IMP noop = imp_implementationWithBlock(^void(id self) {
        // silently
    });
    for (int i = 0; noopMethods[i]; i++) {
        SEL s = sel_registerName(noopMethods[i]);
        Method m = class_getInstanceMethod(agx, s);
        if (m) {
            method_setImplementation(m, noop);
            fprintf(stderr, "#### MACWS_AGX_NATIVE noop'd %s\n", noopMethods[i]);
        }
    }
}

@interface MTLTextureDescriptorInternal : MTLTextureDescriptor
@end
%hook MTLTextureDescriptorInternal
- (MTLStorageMode)storageMode {
    MTLStorageMode mode = %orig;
    static int callCount = 0;
    if (getenv("MACWS_TEX_TRACE") && callCount < 100) {
        callCount++;
        fprintf(stderr, "#### MTL_TEX storageMode=%d fmt=%lu w=%lu h=%lu usage=%#lx\n",
            (int)mode, (unsigned long)self.pixelFormat,
            (unsigned long)self.width, (unsigned long)self.height,
            (unsigned long)self.usage);
    }
    if(mode == 1) { // MTLStorageModeManaged (macOS-discrete-GPU only) → Shared on
                    // iOS unified memory. iOS AGX has no Managed mode; Shared is the
                    // unified-memory equivalent. This rewrite is always correct.
        self.storageMode = MTLStorageModeShared;
        return MTLStorageModeShared;
    }
    // 2026-06-21 — Memoryless(3) is NO LONGER unconditionally downgraded to
    // Private(2) here. The old always-on 3→2 rewrite MUTATED the descriptor
    // (self.storageMode = Private), which DEFEATED two higher-layer memoryless
    // fixes that came later:
    //   1. supportsMemorylessRenderTargets→YES (Metal_hooks.x:~3181) — makes
    //      CA::OGL::MetalContext pass *real* memoryless descriptors instead of
    //      downgrading them up-front.
    //   2. hooked_newTextureWithDescriptor:'s `storageMode == 3` branch
    //      (Metal_hooks.x:~1902) routes memoryless to the NATIVE AGX path
    //      (tile-memory-only, NO IOSurface).
    // Because this accessor persisted the mutation, by the time
    // newTextureWithDescriptor: read [desc storageMode] it saw 2 (never 3), so
    // the native memoryless branch was dead code and EVERY memoryless request
    // fell into ROUTE-IOSURF → a 31 MB IOSurface per "memoryless" texture →
    // multi-GB growth → system Jetsam. A14+/M1 TBDR natively supports
    // memoryless render targets, so the original kIOReturnBadArgument/BLACK
    // concern is now handled correctly at the newTexture layer instead of by
    // this blunt accessor rewrite.
    //
    // A/B opt-out: MACWS_FORCE_MEMORYLESS_PRIVATE=1 restores the old downgrade.
    if(mode == 3 && getenv("MACWS_FORCE_MEMORYLESS_PRIVATE")) {
        self.storageMode = MTLStorageModePrivate;
        return MTLStorageModePrivate;
    }
    return mode;
}
%end

const char *metalSimService = "com.apple.metal.simulator";
xpc_connection_t (*orig_xpc_connection_create_mach_service)(const char * name, dispatch_queue_t targetq, uint64_t flags);
xpc_connection_t hooked_xpc_connection_create_mach_service(const char * name, dispatch_queue_t targetq, uint64_t flags) {
    flags &= ~XPC_CONNECTION_MACH_SERVICE_PRIVILEGED;
    // Log every mach-service connection attempt so we can spot the hiservices /
    // AppKit window-creation flow in chroot. Filter to Terminal process to limit noise.
    if (getenv("MACWS_XPC_DEBUG") || strstr(getprogname() ?: "", "Terminal")) {
        fprintf(stderr, "#### XPC_TRACE mach_service create: '%s' flags=%#llx\n",
            name ?: "(null)", (unsigned long long)flags);
    }
    if(!strncmp(name, metalSimService, strlen(metalSimService))) {
        return xpc_connection_create(metalSimService, 0);
    }
    return orig_xpc_connection_create_mach_service(name, targetq, flags);
}

// Also trace xpc_connection_create (the XPC service / bundle-name style)
xpc_connection_t (*orig_xpc_connection_create)(const char *name, dispatch_queue_t queue);
xpc_connection_t hooked_xpc_connection_create(const char *name, dispatch_queue_t queue) {
    if (name && (getenv("MACWS_XPC_DEBUG") || strstr(getprogname() ?: "", "Terminal"))) {
        fprintf(stderr, "#### XPC_TRACE service create: '%s'\n", name);
    }
    return orig_xpc_connection_create(name, queue);
}

extern int xpc_connection_enable_sim2host_4sim();
%hookf(int, xpc_connection_enable_sim2host_4sim) {
    return 0;
}

// Deferred install of NSXPCSharedListener swizzle.
// AppKit calls +[NSXPCSharedListener endpointForReply:withListenerName:replyErrorCode:]
// to obtain endpoints to ViewBridgeAuxiliary / hiservices. In chroot these XPC services
// can't be spawned (macOS-only frameworks; iOS launchd has no equivalent), so the call
// returns nil and AppKit logs "Connection invalid", skipping window content creation.
//
// We return a process-local NSXPCListener's endpoint so AppKit thinks it got one. The
// in-process listener doesn't actually serve the real protocol, but AppKit's "endpoint
// non-nil" check passes and downstream window creation proceeds.
//
// MUST run AFTER libSystem_initializer (constructor-time NSClassFromString causes
// libSystem PAC traps on arm64e). Install via dispatch_async-after-main-loop.
static IMP gOrigEndpointForReply = NULL;

static id hook_endpointForReply_replacement(Class self, SEL _cmd, id reply,
                                             id listenerName, int *replyErrorCode) {
    // listenerName is an OS_xpc_string (XPC string), not NSString. Extract cstring
    // via the OS_xpc_string instance method instead of NSString's UTF8String.
    const char *name_c = "(nil)";
    if (listenerName) {
        SEL utf8_sel = sel_registerName("UTF8String");
        if ([listenerName respondsToSelector:utf8_sel]) {
            // NSString-style — fine
            name_c = ((const char *(*)(id, SEL))objc_msgSend)(listenerName, utf8_sel);
        } else {
            // Assume xpc_string_t — try xpc_string_get_string_ptr
            extern const char *xpc_string_get_string_ptr(xpc_object_t xstring);
            name_c = xpc_string_get_string_ptr((xpc_object_t)listenerName);
            if (!name_c) name_c = "(xpc-string?)";
        }
    }
    fprintf(stderr, "#### NSXPCSharedListener intercept: listener=%s\n", name_c);

    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    if (!listenerName) {
        if (replyErrorCode) *replyErrorCode = 0;
        return nil;
    }
    NSString *key = [NSString stringWithUTF8String:name_c];
    @synchronized(cache) {
        NSXPCListenerEndpoint *ep = cache[key];
        if (!ep) {
            NSXPCListener *l = [NSXPCListener anonymousListener];
            [l resume];
            ep = l.endpoint;
            cache[key] = ep;
            fprintf(stderr, "#### NSXPCSharedListener: provided in-process endpoint %p for '%s'\n",
                ep, name_c);
        }
        if (replyErrorCode) *replyErrorCode = 0;
        return ep;
    }
}

// Replacement for +[NSXPCSharedListener connectToService:instanceIdentifier:listener:error:].
// Returning YES makes ViewBridge believe the connection is up; it then dereferences
// an expected proxy and crashes in __auxiliaryProxyFor_block_invoke. Returning NO
// makes ViewBridge bail with a graceful failure — auxiliaryProxyFor returns nil,
// NSRemoteView initialize finishes without crashing, AppKit continues to window
// creation (which doesn't strictly need NSRemoteView).
static BOOL hook_connectToService_replacement(Class self, SEL _cmd, id service,
                                                id instanceIdentifier, id listener,
                                                NSError **errorPtr) {
    fprintf(stderr, "#### NSXPCSharedListener connectToService intercepted (graceful fail)\n");
    // Don't set errorPtr; NSError instantiation triggers PAC autda fault in chroot arm64e.
    // Returning NO with *errorPtr untouched should be acceptable for ViewBridge's call site.
    return NO;
}

static void install_nsxpcsharedlistener_swizzle(void) {
    Class shl = objc_getClass("NSXPCSharedListener");
    fprintf(stderr, "#### NSXPCSharedListener class=%p\n", shl);
    if (!shl) return;
    SEL sel = sel_registerName("endpointForReply:withListenerName:replyErrorCode:");
    Method m = class_getClassMethod(shl, sel);
    if (m) {
        gOrigEndpointForReply = method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_endpointForReply_replacement);
        fprintf(stderr, "#### NSXPCSharedListener endpointForReply swizzle installed\n");
    }
    // Also swizzle connectToService:instanceIdentifier:listener:error: to silently succeed.
    SEL sel2 = sel_registerName("connectToService:instanceIdentifier:listener:error:");
    Method m2 = class_getClassMethod(shl, sel2);
    if (m2) {
        method_setImplementation(m2, (IMP)hook_connectToService_replacement);
        fprintf(stderr, "#### NSXPCSharedListener connectToService swizzle installed\n");
    }
}

__attribute__((constructor)) static void InitMetalHooks() {
    // Install plugin-class hook unconditionally — it inspects MACWS_AGX_NATIVE
    // at first invocation and decides whether to return AGXG13GFamilyDevice or Nil.
    MSImageRef sys = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Metal");
    %init(getMetalPluginClassForService = MSFindSymbol(sys, "_getMetalPluginClassForService"));

    // NOTE: we used to short-circuit out of all sim-related init when
    // MACWS_AGX_NATIVE=1, but Metal.framework still needs the EnableSimApple5
    // CFPref + MTLSimDriver registration paths so that fallback codepaths
    // resolve without nil-deref crashes when AGX-native paths exit early.
    // Leave the rest of init running unconditionally; the plugin-class hook
    // alone is enough to route the device choice.

    dispatch_async(dispatch_get_main_queue(), ^{
        // force Apple 5 profile.
        // NOTE: do NOT pass ObjC/CF constant literals (@"..." / @(YES)) here. On the
        // on-device lld arm64e build, the constant CFString's pointer still PAC-faults
        // when CoreFoundation reads it (autda DA trap in CFStringGetCharacterAtIndex
        // via _CFXPreferences withSearchListForIdentifier) -- even with -fixup_chains.
        // Build the strings at runtime (proper isa from the CF allocator) instead.
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, "EnableSimApple5", kCFStringEncodingUTF8);
        CFStringRef app = CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.Metal", kCFStringEncodingUTF8);
        CFPreferencesSetAppValue(key, kCFBooleanTrue, app);
        CFRelease(key);
        CFRelease(app);
    });

    MSImageRef xpc = MSGetImageByName("/usr/lib/system/libxpc.dylib");
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create_mach_service"), hooked_xpc_connection_create_mach_service, (void *)&orig_xpc_connection_create_mach_service);
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create"), hooked_xpc_connection_create, (void *)&orig_xpc_connection_create);

    // Defer NSXPCSharedListener swizzle install until after libSystem is fully up.
    // Constructor-time class lookup PAC-traps on arm64e (autda fault in libobjc class
    // realization). dispatch_async waits until the main runloop is active.
    dispatch_async(dispatch_get_main_queue(), ^{
        // (NOTE: tried calling MTLCreateSystemDefaultDevice here to force Metal load
        // for the black-tab fix — it DEADLOCKED chroot AppKit startup. Revisit via
        // a background queue load or hook on NSWindow display time.)

        install_nsxpcsharedlistener_swizzle();

        // If this is Terminal, force "New Window" via responder chain since AppKit's
        // automatic startup-window-creation depends on hiservices/launchservices which
        // are broken in chroot. Multiple selector attempts (Terminal uses
        // newWindowWithProfile: typically, but newWindow: also responds).
        const char *prog = getprogname();
        if (prog && strstr(prog, "Terminal")) {
            // Schedule slightly after main queue so app's didFinishLaunching has fired.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                fprintf(stderr, "#### Forcing Terminal new-window via sendAction:\n");
                SEL sels[] = {
                    sel_registerName("newWindow:"),
                    sel_registerName("newWindowWithProfile:"),
                    sel_registerName("newTerminal:"),
                    sel_registerName("newTerminalWithDefaultProfile:"),
                };
                Class app_cls = objc_getClass("NSApplication");
                id app = ((id (*)(Class, SEL))objc_msgSend)(app_cls, sel_registerName("sharedApplication"));
                fprintf(stderr, "#### NSApp=%p\n", app);
                if (app) {
                    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
                        BOOL ok = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                            app, sel_registerName("sendAction:to:from:"),
                            sels[i], nil, nil);
                        fprintf(stderr, "####   sendAction %s -> %d\n", sel_getName(sels[i]), ok);
                        if (ok) break;
                    }
                }
            });
        }
    });
    // register MTLSimDriverHost.xpc
    char frameworkPath[PATH_MAX];
    // NSLog(@"#### debugbydcmmc register MTLSimDriverHost.xpc");
    snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc", JBROOT_PATH("/usr/macOS/Frameworks"));
    xpc_add_bundle(frameworkPath, 2);

    // ViewBridgeAuxiliary.xpc & hiservices-xpcservice.xpc are now registered via
    // _xpc_bootstrap_services in mac_hooks.m's libxpc branch — pointing at the
    // FRAMEWORK BINARY paths, which lets xpc auto-discover bundled XPCServices/
    // children. xpc_add_bundle (the .xpc-path variant) didn't actually trigger
    // spawn; _xpc_bootstrap_services does. (Credit: user-suggested fix based on
    // their earlier MTLCompilerService shader recompile issue.)
}
