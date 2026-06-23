// iosurf_gputest.m — IOSurface ⇄ GPU aliasing + render comparison test.
//
// Purpose: pin down WHY an IOSurface-backed Metal texture rendered by the GPU
// does NOT show up in the IOSurface's CPU-readable pages in the chroot, while it
// works iOS-native. Build the SAME source for both targets:
//
//   iOS-native (real AGX, the WORKING baseline):
//     xcrun --sdk iphoneos clang -arch arm64e -fobjc-arc -framework Metal \
//       -framework IOSurface -framework Foundation misc/iosurf_gputest.m -o iosurf_gputest_ios
//
//   macOS-chroot (the broken path; run via run_bash.sh so libmachook is injected):
//     xcrun --sdk macosx clang -arch arm64e -fobjc-arc -framework Metal \
//       -framework IOSurface -framework Foundation misc/iosurf_gputest.m -o iosurf_gputest_mac
//
// It performs four checks and prints a verdict for each:
//   [A] newBufferWithIOSurface: → gpuAddress + contents, and whether contents
//       aliases IOSurfaceGetBaseAddress (CPU-level alias).
//   [B] CPU-alias: write a sentinel to the IOSurface CPU base, read it back via
//       the buffer's contents (proves the buffer maps the SAME physical pages).
//   [C] newTextureWithDescriptor:iosurface: → GPU render-pass CLEAR to green →
//       read the IOSurface CPU base: does the GPU write reach the IOSurface?
//   [D] same via a blit (clear a scratch, blit into the IOSurface texture).
//
// The chroot is expected to FAIL [C]/[D] (and maybe [A]/[B]); the iOS-native run
// is the reference for what "correct" looks like.

#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>

static uint64_t msg_u64(id obj, const char *sel) {
    if (!obj) return 0;
    typedef uint64_t (*fn)(id, SEL);
    return ((fn)objc_msgSend)(obj, sel_registerName(sel));
}
static void *msg_ptr(id obj, const char *sel) {
    if (!obj) return NULL;
    typedef void *(*fn)(id, SEL);
    return ((fn)objc_msgSend)(obj, sel_registerName(sel));
}
static id msg_ios(id obj, const char *sel, IOSurfaceRef s) {
    if (!obj) return nil;
    typedef id (*fn)(id, SEL, IOSurfaceRef);
    return ((fn)objc_msgSend)(obj, sel_registerName(sel), s);
}

int main(int argc, char **argv) { @autoreleasepool {
    const int W = 256, H = 256;
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(W),
        (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    IOSurfaceRef ios = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!ios) { printf("FATAL: IOSurfaceCreate failed\n"); return 1; }
    uint32_t *iosbase = (uint32_t *)IOSurfaceGetBaseAddress(ios);
    size_t bpr = IOSurfaceGetBytesPerRow(ios);
    printf("== IOSurface=%p base=%p bpr=%zu allocSize=%zu id=%u ==\n",
           (void *)ios, iosbase, bpr, IOSurfaceGetAllocSize(ios), IOSurfaceGetID(ios));

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("FATAL: no Metal device\n"); return 1; }
    printf("device=%s class=%s\n", dev.name.UTF8String, class_getName([(id)dev class]));

    // [A] newBufferWithIOSurface: — gpuAddress + contents alias
    id buf = msg_ios((id)dev, "newBufferWithIOSurface:", ios);
    void *bufcont = msg_ptr(buf, "contents");
    uint64_t bufva = msg_u64(buf, "gpuAddress");
    printf("[A] newBufferWithIOSurface: buf=%p gpuAddress=%#llx contents=%p (==base? %d)\n",
           (__bridge void *)buf, bufva, bufcont, (bufcont == (void *)iosbase));

    // [B] CPU-alias: write sentinel to IOSurface base, read via buffer contents
    IOSurfaceLock(ios, 0, NULL);
    iosbase[0] = 0xAABBCCDD;
    iosbase[1] = 0x11223344;
    IOSurfaceUnlock(ios, 0, NULL);
    if (bufcont) {
        uint32_t *bp = (uint32_t *)bufcont;
        printf("[B] CPU-alias: ios[0,1]=%08x,%08x  buf[0,1]=%08x,%08x  match=%d\n",
               iosbase[0], iosbase[1], bp[0], bp[1],
               (bp[0] == 0xAABBCCDD && bp[1] == 0x11223344));
    } else {
        printf("[B] CPU-alias: buffer has NO contents pointer (cannot CPU-compare)\n");
    }

    // texture from IOSurface
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d iosurface:ios plane:0];
    printf("    texture=%p\n", (__bridge void *)tex);
    if (!tex) { printf("FATAL: newTextureWithDescriptor:iosurface: returned nil\n"); }

    id<MTLCommandQueue> q = [dev newCommandQueue];

    // [C] GPU render-pass CLEAR to GREEN (BGRA green = 0xFF00FF00)
    if (tex) {
        // pre-fill IOSurface with a marker so we can tell "GPU wrote" from "left as-is"
        IOSurfaceLock(ios, 0, NULL);
        for (int i = 0; i < W * H; i++) iosbase[i] = 0x55555555;
        IOSurfaceUnlock(ios, 0, NULL);

        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 1.0, 0.0, 1.0); // green
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        printf("[C] render-clear cb.status=%ld err=%s\n",
               (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "none");

        IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
        uint32_t px = iosbase[(H/2) * (bpr/4) + (W/2)];
        int green = 0, marker = 0, other = 0;
        for (int i = 0; i < W * H; i++) {
            uint32_t p = iosbase[i];
            if ((p & 0x00FFFFFF) == 0x0000FF00 || p == 0xFF00FF00) green++;
            else if (p == 0x55555555) marker++;
            else other++;
        }
        IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
        printf("[C] after GPU green-clear: IOSurface[ctr]=%08x  green=%d marker(unchanged)=%d other=%d  VERDICT=%s\n",
               px, green, marker, other,
               green > W * H / 2 ? "GPU-WRITE-REACHED-IOSURFACE ✓"
                                 : (marker > W * H / 2 ? "IOSURFACE-UNTOUCHED (GPU wrote elsewhere) ✗"
                                                       : "PARTIAL/UNKNOWN"));
    }

    // [D] blit: clear a private scratch to BLUE, blit into the IOSurface texture
    if (tex) {
        IOSurfaceLock(ios, 0, NULL);
        for (int i = 0; i < W * H; i++) iosbase[i] = 0x55555555;
        IOSurfaceUnlock(ios, 0, NULL);

        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:W height:H mipmapped:NO];
        sd.usage = MTLTextureUsageRenderTarget;
        sd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> scratch = [dev newTextureWithDescriptor:sd];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = scratch;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0); // blue
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:scratch sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                 sourceSize:MTLSizeMake(W,H,1) toTexture:tex destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0,0,0)];
        [bl endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        printf("[D] blit cb.status=%ld err=%s\n",
               (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "none");

        IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
        int blue = 0, marker = 0;
        for (int i = 0; i < W * H; i++) {
            uint32_t p = iosbase[i];
            if ((p & 0x00FFFFFF) == 0x000000FF || p == 0xFFFF0000) blue++;
            else if (p == 0x55555555) marker++;
        }
        IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
        printf("[D] after blit-blue: blue=%d marker(unchanged)=%d VERDICT=%s\n",
               blue, marker,
               blue > W * H / 2 ? "BLIT-REACHED-IOSURFACE ✓" : "IOSURFACE-UNTOUCHED ✗");
    }

    printf("== done ==\n");
    return 0;
} }
