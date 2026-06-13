// iostrace.dylib — DYLD_INSERT-able IOConnect tracer. Logs every IOKit user-client call
// (which selector, in/out sizes, result) so the iOS-native Metal submit sequence can be
// diffed against the macOS-AGX (agxprobe/libmachook AGXIOC) sequence. Standalone (no deps
// on libmachook). Build: clang -arch arm64e -target arm64e-apple-ios16.0 -dynamiclib.
#import <stdio.h>
#import <stdint.h>
#import <stddef.h>
#import <mach/mach.h>
#import <IOKit/IOKitLib.h>

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

static IOReturn t_AsyncStruct(io_connect_t c, uint32_t sel, mach_port_t wp, uint64_t *ref, uint32_t refc, const void *is, size_t isc, void *os, size_t *osc) {
    IOReturn r = IOConnectCallAsyncStructMethod(c, sel, wp, ref, refc, is, isc, os, osc);
    fprintf(stderr, "IOSTRACE AsyncStruct conn=%u sel=0x%x wakePort=%u inSC=%zu -> 0x%x\n", c, sel, wp, isc, r);
    return r;
}
DYLD_INTERPOSE(t_AsyncStruct, IOConnectCallAsyncStructMethod)
