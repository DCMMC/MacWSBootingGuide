// iosblit — a NATIVE iOS Metal blit (device/buffer/queue/fillBuffer/commit/readback).
// This is the WORKING reference path: it uses the iOS AGX driver directly (same one iOS
// apps + MTLSimDriverHost use), so its command buffer DOES execute on the GPU. Run it
// with DYLD_INSERT_LIBRARIES=iostrace.dylib and diff its IOConnect sequence against
// agxprobe's (the macOS-AGX path that submits but never executes) to find the difference.
@import Foundation;
@import Metal;
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <mach/mach.h>
#import <IOKit/IOKitLib.h>

// IOConnect tracer built INTO the binary (DYLD_INSERT is blocked for native iOS bins, but a
// __DATA,__interpose section in the main executable is honored by dyld globally — incl. Metal's
// internal IOConnect calls). Logs the iOS-native submit sequence to diff vs the macOS-AGX path.
#define DYLD_INTERPOSE(_repl, _orig) \
  __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##_orig \
  __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig };

static kern_return_t t_IOServiceOpen(io_service_t svc, task_port_t task, uint32_t type, io_connect_t *conn) {
    kern_return_t r = IOServiceOpen(svc, task, type, conn);
    fprintf(stderr, "IOSTRACE IOServiceOpen type=%u -> conn=%u rc=0x%x\n", type, conn ? *conn : 0, r);
    return r;
}
DYLD_INTERPOSE(t_IOServiceOpen, IOServiceOpen)
static IOReturn t_Method(io_connect_t c, uint32_t sel, const uint64_t *in, uint32_t inc, const void *is, size_t isc, uint64_t *out, uint32_t *outc, void *os, size_t *osc) {
    IOReturn r = IOConnectCallMethod(c, sel, in, inc, is, isc, out, outc, os, osc);
    fprintf(stderr, "IOSTRACE Method conn=%u sel=0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", c, sel, inc, isc, osc ? *osc : 0, r);
    return r;
}
DYLD_INTERPOSE(t_Method, IOConnectCallMethod)
static IOReturn t_Scalar(io_connect_t c, uint32_t sel, const uint64_t *in, uint32_t inc, uint64_t *out, uint32_t *outc) {
    IOReturn r = IOConnectCallScalarMethod(c, sel, in, inc, out, outc);
    fprintf(stderr, "IOSTRACE Scalar conn=%u sel=0x%x inCnt=%u -> 0x%x\n", c, sel, inc, r);
    return r;
}
DYLD_INTERPOSE(t_Scalar, IOConnectCallScalarMethod)
static IOReturn t_Struct(io_connect_t c, uint32_t sel, const void *is, size_t isc, void *os, size_t *osc) {
    IOReturn r = IOConnectCallStructMethod(c, sel, is, isc, os, osc);
    fprintf(stderr, "IOSTRACE Struct conn=%u sel=0x%x inSC=%zu outSC=%zu -> 0x%x\n", c, sel, isc, osc ? *osc : 0, r);
    return r;
}
DYLD_INTERPOSE(t_Struct, IOConnectCallStructMethod)
static IOReturn t_AsyncMethod(io_connect_t c, uint32_t sel, mach_port_t wp, uint64_t *ref, uint32_t refc, const uint64_t *in, uint32_t inc, const void *is, size_t isc, uint64_t *out, uint32_t *outc, void *os, size_t *osc) {
    IOReturn r = IOConnectCallAsyncMethod(c, sel, wp, ref, refc, in, inc, is, isc, out, outc, os, osc);
    fprintf(stderr, "IOSTRACE AsyncMethod conn=%u sel=0x%x wakePort=%u inCnt=%u inSC=%zu -> 0x%x\n", c, sel, wp, inc, isc, r);
    return r;
}
DYLD_INTERPOSE(t_AsyncMethod, IOConnectCallAsyncMethod)
static IOReturn t_AsyncScalar(io_connect_t c, uint32_t sel, mach_port_t wp, uint64_t *ref, uint32_t refc, const uint64_t *in, uint32_t inc, uint64_t *out, uint32_t *outc) {
    IOReturn r = IOConnectCallAsyncScalarMethod(c, sel, wp, ref, refc, in, inc, out, outc);
    fprintf(stderr, "IOSTRACE AsyncScalar conn=%u sel=0x%x wakePort=%u inCnt=%u -> 0x%x\n", c, sel, wp, inc, r);
    return r;
}
DYLD_INTERPOSE(t_AsyncScalar, IOConnectCallAsyncScalarMethod)

int main(int argc, char **argv) {
    int maxStage = (argc > 1) ? atoi(argv[1]) : 4;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "IOSBLIT [1] device=%p name=%s\n", (void *)dev, dev ? [[dev name] UTF8String] : "NIL");
        if (!dev) { fprintf(stderr, "IOSBLIT FAIL (no device)\n"); return 1; }
        if (maxStage < 2) return 0;
        id<MTLBuffer> buf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        fprintf(stderr, "IOSBLIT [2] buffer=%p\n", (void *)buf);
        if (!buf) return 2;
        unsigned char *p = (unsigned char *)[buf contents]; p[0] = 0; p[4095] = 0;
        if (maxStage < 3) return 0;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        fprintf(stderr, "IOSBLIT [3] queue=%p\n", (void *)q);
        if (!q) return 3;
        if (maxStage < 4) return 0;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit fillBuffer:buf range:NSMakeRange(0, 4096) value:0xAB];
        [blit endEncoding];
        fprintf(stderr, "IOSBLIT [4c] committing...\n");
        [cb commit];
        [cb waitUntilCompleted];
        fprintf(stderr, "IOSBLIT [4d] status=%ld readback[0]=0x%02x [4095]=0x%02x (expect 0xab)\n",
                (long)[cb status], p[0], p[4095]);
    }
    return 0;
}
