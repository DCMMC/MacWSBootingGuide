// iosblit_tracer — ellekit/Substrate tweak injected into com.dcmmc.iosblit.
//
// The app's built-in __DATA,__interpose tracer does NOT catch Metal's IOConnect calls: Metal.framework
// lives in the dyld shared cache, and shared-cache-internal binds (Metal -> IOKit) bypass main-executable
// dyld interposing on iOS. MSHookFunction inline-patches the IOKit function prologues, so it DOES catch
// shared-cache callers. We log the WORKING iOS AGX IOConnect sequence (resource creation, queue setup,
// submit + a deep cmdbuf dump) to os_log (subsystem com.dcmmc.iosblit) so it can be byte-diffed against
// the failing macOS-AGX (agxprobe / libmachook) path that submits but never executes (status 5, 0x103).
#import <stdio.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <os/log.h>
#import <mach/mach.h>
#import <IOKit/IOKitLib.h>

// Resolved at load time by ellekit (built with -undefined dynamic_lookup; no link-time substrate needed).
extern void MSHookFunction(void *symbol, void *replace, void **result);

static os_log_t L;
#define LOG(...) os_log_error(L, __VA_ARGS__)

// hex one buffer onto a single line (space-separated bytes)
static void hexline(char *out, size_t outsz, const unsigned char *p, size_t n) {
    size_t k = 0;
    for (size_t i = 0; i < n && k + 4 < outsz; i++) k += (size_t)snprintf(out + k, outsz - k, "%02x ", p[i]);
    out[k < outsz ? k : outsz - 1] = 0;
}

static IOReturn (*o_Struct)(io_connect_t, uint32_t, const void *, size_t, void *, size_t *);
static IOReturn (*o_Method)(io_connect_t, uint32_t, const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
static IOReturn (*o_Async)(io_connect_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
static kern_return_t (*o_Open)(io_service_t, task_port_t, uint32_t, io_connect_t *);

// Deep-dump the submit descriptor (iOS IOGPUCommandQueue submit == selector 0x1a). Same format as the
// libmachook shim + iosblit.m tracer for direct diffing. Range-guarded derefs (GPU-shared VAs only).
static void dump_submit(uint32_t sel, const void *is, size_t isc) {
    if (sel != 0x1a || !is || isc < 0x20) return;
    const unsigned char *s = (const unsigned char *)is;
    char buf[256]; hexline(buf, sizeof buf, s, isc < 64 ? isc : 64);
    LOG("IOSTRACE SUBMIT sel=0x%x IN[%zu]: %{public}s", sel, isc, buf);
    uint64_t cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
    for (int pi = 0; pi < 2; pi++) if (cbp[pi] > 0x100000000ULL && cbp[pi] < 0x300000000ULL) {
        const unsigned char *cb = (const unsigned char *)cbp[pi];
        char cbuf[400]; hexline(cbuf, sizeof cbuf, cb, 0x60);
        LOG("IOSTRACE cmdbuf%d@%#llx: %{public}s", pi, (unsigned long long)cbp[pi], cbuf);
        for (int off = 0; off < 0x60; off += 8) {
            uint64_t pv = *(const uint64_t *)(cb + off);
            if (pv > 0x100000000ULL && pv < 0x300000000ULL) {
                char tbuf[256]; hexline(tbuf, sizeof tbuf, (const unsigned char *)pv, 64);
                LOG("IOSTRACE   cb%d+%#x -> %#llx: %{public}s", pi, off, (unsigned long long)pv, tbuf);
            }
        }
    }
}

static IOReturn h_Struct(io_connect_t c, uint32_t sel, const void *is, size_t isc, void *os, size_t *osc) {
    dump_submit(sel, is, isc);
    IOReturn r = o_Struct(c, sel, is, isc, os, osc);
    LOG("IOSTRACE Struct conn=%u sel=0x%x inSC=%zu outSC=%zu -> 0x%x", c, sel, isc, osc ? *osc : 0, r);
    return r;
}
static IOReturn h_Method(io_connect_t c, uint32_t sel, const uint64_t *in, uint32_t inc, const void *is, size_t isc, uint64_t *out, uint32_t *outc, void *os, size_t *osc) {
    dump_submit(sel, is, isc);
    IOReturn r = o_Method(c, sel, in, inc, is, isc, out, outc, os, osc);
    LOG("IOSTRACE Method conn=%u sel=0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x", c, sel, inc, isc, osc ? *osc : 0, r);
    return r;
}
static IOReturn h_Async(io_connect_t c, uint32_t sel, mach_port_t wp, uint64_t *ref, uint32_t refc, const uint64_t *in, uint32_t inc, const void *is, size_t isc, uint64_t *out, uint32_t *outc, void *os, size_t *osc) {
    dump_submit(sel, is, isc);
    IOReturn r = o_Async(c, sel, wp, ref, refc, in, inc, is, isc, out, outc, os, osc);
    LOG("IOSTRACE Async conn=%u sel=0x%x inCnt=%u inSC=%zu -> 0x%x", c, sel, inc, isc, r);
    return r;
}
static kern_return_t h_Open(io_service_t svc, task_port_t task, uint32_t type, io_connect_t *conn) {
    kern_return_t r = o_Open(svc, task, type, conn);
    LOG("IOSTRACE IOServiceOpen type=%u -> conn=%u rc=0x%x", type, conn ? *conn : 0, r);
    return r;
}

__attribute__((constructor))
static void tracer_init(void) {
    L = os_log_create("com.dcmmc.iosblit", "trace");
    LOG("IOSTRACE tweak loaded — installing inline hooks");
    MSHookFunction((void *)IOConnectCallStructMethod, (void *)h_Struct, (void **)&o_Struct);
    MSHookFunction((void *)IOConnectCallMethod,       (void *)h_Method, (void **)&o_Method);
    MSHookFunction((void *)IOConnectCallAsyncMethod,  (void *)h_Async,  (void **)&o_Async);
    MSHookFunction((void *)IOServiceOpen,             (void *)h_Open,   (void **)&o_Open);
    LOG("IOSTRACE hooks installed (Struct/Method/Async/Open)");
}
