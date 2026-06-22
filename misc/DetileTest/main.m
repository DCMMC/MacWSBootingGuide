// DetileTest — standalone chroot CLI that verifies the VNC capture/"detile"
// read path WITHOUT WindowServer, the compositor, or bg-thread/composite timing.
//
// WHAT WE LEARNED (runtime, this device):
//   * In the chroot, plain -newTextureWithDescriptor is intercepted by libmachook
//     and routed through an IOSurface-backed POOL that dedupes by (w,h,pf). Two
//     same-key creates return the SAME texture object. So distinct src/dst need
//     DIFFERENT sizes.
//   * Those pooled textures are layout(+0x184)=0 (LINEAR), stride(+0xa8)=0 (tight).
//   * -replaceRegion crashes (writeRegion -> memmove dst=NULL) — the wrapper's
//     writable backing differs from the patched +0xa0. So we CANNOT fill via CPU.
//   * MTLBuffer .contents is only a 16 KB calloc -> NO buffers as a data source.
//
// => The only safe way to put KNOWN content into a chroot texture is a GPU op.
//    Render-pass CLEAR is proven to work (agxprobe stage 5). This test:
//      A) clears texA (big) to RED, texB (small, different size) to BLUE,
//      B) blits texB into the CENTER of texA (sub-rect copy — spatial fidelity),
//      C) reads texA back THREE ways and compares at known pixel positions:
//           - getBytes               (driver ground truth)
//           - impl+0xa0 raw backing  (WHAT THE VNC PIPELINE READS, stride=w*4)
//           - the pool IOSurface base (the cross-process surface)
//    If +0xa0 matches getBytes at all probe points -> the pipeline read path is
//    correct. If it doesn't, +0xa0 is the wrong memory and that's the real bug.
//
// AGX C++ impl fields (RE'd in Metal_hooks.x): impl=*(tex+_impl_off)(0x208),
//   +0x184 u8 layout(0=linear), +0xa8 u32 stride(0=tight), +0xa0 ptr backing.
@import Foundation;
@import Metal;
@import IOSurface;
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static ptrdiff_t g_impl_off = 0;
static ptrdiff_t impl_off(id<MTLTexture> tex) {
    if (g_impl_off == 0) {
        Class c = object_getClass(tex);
        while (c && g_impl_off == 0) {
            Ivar iv = class_getInstanceVariable(c, "_impl");
            if (iv) g_impl_off = ivar_getOffset(iv);
            c = class_getSuperclass(c);
        }
        if (g_impl_off == 0) g_impl_off = 0x208;
        fprintf(stderr, "  _impl ivar offset = %#tx\n", g_impl_off);
    }
    return g_impl_off;
}
static void *agx_fields(id<MTLTexture> tex, uint8_t *layout, uint32_t *stride) {
    *layout = 0xff; *stride = 0;
    void *impl = *(void **)((char *)(__bridge void *)tex + impl_off(tex));
    if ((uintptr_t)impl <= 0x1000) return NULL;
    *layout = *(uint8_t  *)((char *)impl + 0x184);
    *stride = *(uint32_t *)((char *)impl + 0xa8);
    return *(void **)((char *)impl + 0xa0);
}

static id<MTLTexture> make_tex(id<MTLDevice> dev, uint32_t w, uint32_t h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:d];
}

static void clear_to(id<MTLCommandQueue> q, id<MTLTexture> t,
                     double r, double g, double b) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> rce = [cb renderCommandEncoderWithDescriptor:rp];
    [rce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if ([cb status] != MTLCommandBufferStatusCompleted)
        fprintf(stderr, "  clear status=%ld err=%s\n", (long)[cb status],
                [cb error]?[[[cb error] localizedDescription] UTF8String]:"none");
}

// BGRA8 pixel as a hex string from a tight-stride buffer.
static void px(const uint8_t *base, uint32_t w, uint32_t x, uint32_t y, char *out) {
    const uint8_t *p = base + ((size_t)y*w + x)*4;
    sprintf(out, "%02x%02x%02x%02x", p[0], p[1], p[2], p[3]);
}

int main(int argc, char **argv) {
    const char *arch =
#if defined(__arm64e__)
        "arm64e";
#else
        "arm64";
#endif
    fprintf(stderr, "DETILE-TEST(v3 clear+subrect) start arch=%s\n", arch);

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "FAIL: no device\n"); return 1; }
        fprintf(stderr, "device=%s\n", [[dev name] UTF8String]);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (!q) { fprintf(stderr, "FAIL: no queue\n"); return 4; }

        const uint32_t AW = (argc>1)?(uint32_t)atoi(argv[1]):512;
        const uint32_t AH = (argc>2)?(uint32_t)atoi(argv[2]):512;
        const uint32_t BW = 256, BH = 256;        // different size => distinct pool entry
        const uint32_t OX = 128, OY = 128;        // blit B into A here

        id<MTLTexture> A = make_tex(dev, AW, AH);
        id<MTLTexture> B = make_tex(dev, BW, BH);
        if (!A || !B) { fprintf(stderr, "FAIL: tex A=%p B=%p\n", (__bridge void*)A,(__bridge void*)B); return 3; }
        fprintf(stderr, "A=%p (%ux%u)  B=%p (%ux%u)  sameObj=%d\n",
                (__bridge void*)A, AW, AH, (__bridge void*)B, BW, BH, A==B);
        fprintf(stderr, "A class=%s\n", class_getName(object_getClass(A)));

        uint8_t aLay,bLay; uint32_t aStr,bStr;
        void *aBack = agx_fields(A,&aLay,&aStr);
        void *bBack = agx_fields(B,&bLay,&bStr);
        fprintf(stderr, "A: layout=%u stride=%u backing=%p\nB: layout=%u stride=%u backing=%p\n",
                aLay,aStr,aBack,bLay,bStr,bBack);

        // A) clears
        clear_to(q, A, 1.0, 0.0, 0.0);   // RED   -> BGRA bytes 00 00 ff ff
        clear_to(q, B, 0.0, 0.0, 1.0);   // BLUE  -> BGRA bytes ff 00 00 ff

        // B) sub-rect blit B -> A at (OX,OY)
        {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:B sourceSlice:0 sourceLevel:0
                   sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(BW,BH,1)
                      toTexture:A destinationSlice:0 destinationLevel:0
              destinationOrigin:MTLOriginMake(OX,OY,0)];
            [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
            if ([cb status] != MTLCommandBufferStatusCompleted)
                fprintf(stderr, "  subrect blit status=%ld err=%s\n", (long)[cb status],
                        [cb error]?[[[cb error] localizedDescription] UTF8String]:"none");
        }

        // Re-read A backing (may populate lazily)
        aBack = agx_fields(A,&aLay,&aStr);
        fprintf(stderr, "A post-blit: layout=%u stride=%u backing=%p\n", aLay,aStr,aBack);

        // C) read A three ways
        const size_t ASZ = (size_t)AW*AH*4;
        uint8_t *gb = (uint8_t*)malloc(ASZ);
        int haveGB = 0;
        if (gb) { @try {
            [A getBytes:gb bytesPerRow:AW*4 fromRegion:MTLRegionMake2D(0,0,AW,AH) mipmapLevel:0];
            haveGB = 1;
        } @catch (NSException *e) { fprintf(stderr,"  getBytes EXC %s\n",[[e reason] UTF8String]?:"?"); } }

        // pool IOSurface base for A (cross-process surface). The pool stores the
        // IOSurfaceRef; try to recover base via the texture's iosurface, if any.
        IOSurfaceRef aSurf = NULL;
        if ([A respondsToSelector:@selector(iosurface)]) aSurf = [A iosurface];
        void *surfBase = aSurf ? IOSurfaceGetBaseAddress(aSurf) : NULL;

        // Probe points: center(blue), corners(red), just outside the blue square(red).
        struct { const char *name; uint32_t x,y; const char *want; } pts[] = {
            { "TL(red)   ", 10,     10,      "0000ffff" },
            { "center(blu)", AW/2,  AH/2,    "ff0000ff" },
            { "inB-TL(blu)", OX+4,  OY+4,    "ff0000ff" },
            { "outB(red) ", OX-8,  OY-8,     "0000ffff" },
            { "BR(red)   ", AW-12,  AH-12,   "0000ffff" },
        };
        fprintf(stderr, "\n=== probe (want vs getBytes vs +0xa0 vs IOSurfBase) ===\n");
        int a0_ok = 1, a0_seen = 0;
        for (int i=0;i<5;i++) {
            char g[9]="--------", a[9]="--------", s[9]="--------";
            if (haveGB) px(gb, AW, pts[i].x, pts[i].y, g);
            if (aBack)  { px((const uint8_t*)aBack, AW, pts[i].x, pts[i].y, a); a0_seen=1;
                          if (strcmp(a, pts[i].want)!=0) a0_ok=0; }
            if (surfBase) px((const uint8_t*)surfBase, AW, pts[i].x, pts[i].y, s);
            fprintf(stderr, "  %-11s want=%s  getBytes=%s  +0xa0=%s  IOSurf=%s\n",
                    pts[i].name, pts[i].want, g, a, s);
        }

        // dump for visual inspection
        if (haveGB) {
            FILE *f=fopen("/tmp/detile_getbytes.raw","wb");
            if(f){uint32_t hdr[4]={AW,AH,80,AW*4};fwrite(hdr,4,4,f);fwrite(gb,1,ASZ,f);fclose(f);
                  fprintf(stderr,"  dumped /tmp/detile_getbytes.raw\n");}
        }
        if (aBack) {
            FILE *f=fopen("/tmp/detile_a0.raw","wb");
            if(f){uint32_t hdr[4]={AW,AH,80,AW*4};fwrite(hdr,4,4,f);fwrite(aBack,1,ASZ,f);fclose(f);
                  fprintf(stderr,"  dumped /tmp/detile_a0.raw\n");}
        }

        fprintf(stderr, "\n=== VERDICT ===\n");
        if (haveGB) {
            int gbRed = (memcmp(gb, (uint8_t[]){0,0,0xff,0xff}, 4)==0);
            fprintf(stderr, "getBytes TL is %s\n", gbRed?"RED (render+blit WORK)":"NOT red");
        }
        if (a0_seen)
            fprintf(stderr, "+0xa0 matches expected at ALL probe points: %s  (layout=%u stride=%u)\n",
                    a0_ok?"YES — PIPELINE READ PATH CORRECT":"NO — +0xa0 is the WRONG memory", aLay,aStr);
        else
            fprintf(stderr, "+0xa0 backing was NULL — pipeline would read nothing.\n");

        if (gb) free(gb);
    }
    return 0;
}
