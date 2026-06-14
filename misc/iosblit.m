// iosblit — a NATIVE iOS Metal blit (device/buffer/queue/fillBuffer/commit/readback).
// This is the WORKING reference path: it uses the iOS AGX driver directly (same one iOS
// apps + MTLSimDriverHost use), so its command buffer DOES execute on the GPU. Run it
// with DYLD_INSERT_LIBRARIES=iostrace.dylib and diff its IOConnect sequence against
// agxprobe's (the macOS-AGX path that submits but never executes) to find the difference.
@import Foundation;
@import Metal;
@import UIKit;
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <mach/mach.h>
#import <IOKit/IOKitLib.h>
#import <os/log.h>
#import <sys/sysctl.h>

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
    // submit (iOS sel 0x1a) — deep-dump the IOGPUCommandQueueCommandBufferArgs descriptor + one
    // level of deref, in the SAME format as the agxprobe libmachook shim, so the WORKING iOS
    // command stream can be byte-diffed vs the rejected macOS-AGX one.
    if(sel == 0x1a && is && isc >= 0x20) {
        const unsigned char *s = (const unsigned char *)is;
        fprintf(stderr, "IOSTRACE SUBMIT IN[%zu]:", isc);
        for(size_t i = 0; i < isc && i < 64; i++) fprintf(stderr, " %02x", s[i]);
        fprintf(stderr, "\n");
        uint64_t cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
        for(int pi = 0; pi < 2; pi++) if(cbp[pi] > 0x100000000ULL && cbp[pi] < 0x300000000ULL) {
            const unsigned char *cb = (const unsigned char *)cbp[pi];
            fprintf(stderr, "IOSTRACE cmdbuf%d@%#llx:", pi, (unsigned long long)cbp[pi]);
            for(int j = 0; j < 0x60; j++) fprintf(stderr, " %02x", cb[j]);
            fprintf(stderr, "\n");
            for(int off = 0; off < 0x60; off += 8) {
                uint64_t p = *(const uint64_t *)(cb + off);
                if(p > 0x100000000ULL && p < 0x300000000ULL) {
                    const unsigned char *t = (const unsigned char *)p;
                    fprintf(stderr, "IOSTRACE   cb%d+%#x -> %#llx:", pi, off, (unsigned long long)p);
                    for(int j = 0; j < 64; j++) fprintf(stderr, " %02x", t[j]);
                    fprintf(stderr, "\n");
                }
            }
        }
    }
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

// When launched as an .app by SpringBoard there is no terminal stderr AND the app sandbox
// blocks writing /var/mobile, so a log file never appears. Route ALL stderr (including the
// interpose-tracer dump above) into the unified log via a funopen custom stream; read it back
// with `oslog | grep com.dcmmc.iosblit`. Each newline-terminated line becomes one os_log entry.
static os_log_t g_oslog;
static int oslog_writefn(void *cookie, const char *buf, int n) {
    static char line[2048]; static int len = 0;
    for (int i = 0; i < n; i++) {
        char c = buf[i];
        if (c == '\n' || len >= (int)sizeof(line) - 1) {
            line[len] = 0;
            if (len > 0) os_log_error(g_oslog, "%{public}s", line);
            len = 0;
            if (c != '\n') line[len++] = c;
        } else line[len++] = c;
    }
    return n;
}

// The actual Metal blit + IOConnect-traced submit. Returns 0 on success. Called after the app
// is foreground (so it holds the GPU sandbox extension a real app gets).
//
// After commit, walk the IOGPUMetalCommandBuffer's kernel-command buffer state (private SPI
// at runtime) and dump start..current. These are the bytes the iOS kernel
// `AGXCommandQueue::processSegmentKernelCommand` iterates + validates (looking for outer cmd
// type 0x10000/0x10001, inner type=0x30, size in {0x7c8, 0x3b0, 0x1a8, ...} per subtype 1..5).
// macOS-chroot agxprobe gets status=5 0x103 here; iOS native gets status=4. This dump is the
// REFERENCE for diffing against libmachook's macOS-chroot KCMD dump.
static void kcmd_dump_cb(id cb) {
    SEL sel = NSSelectorFromString(@"getCurrentKernelCommandBufferStart:current:end:");
    if (![cb respondsToSelector:sel]) { fprintf(stderr, "KCMD cb does not respond to selector\n"); return; }
    void *start=NULL, *cur=NULL, *end=NULL;
    void (*imp)(id, SEL, void**, void**, void**) = (void *)[cb methodForSelector:sel];
    imp(cb, sel, &start, &cur, &end);
    fprintf(stderr, "KCMD start=%p current=%p end=%p\n", start, cur, end);
    if (!start || !cur || cur <= start) return;
    size_t len = (uintptr_t)cur - (uintptr_t)start;
    if (len > 0x10000) len = 0x10000; // safety cap
    const unsigned char *p = (const unsigned char *)start;
    fprintf(stderr, "KCMD bytes (%zu = %#zx total):\n", len, len);
    for (size_t off = 0; off < len; off += 32) {
        char line[256]; int n = snprintf(line, sizeof line, "  +%04zx:", off);
        for (size_t j = 0; j < 32 && (off + j) < len && n < (int)sizeof(line) - 4; j++)
            n += snprintf(line + n, sizeof line - n, " %02x", p[off + j]);
        fprintf(stderr, "%s\n", line);
        // Mark outer-cmd boundaries by checking +0x00 against the kernel's expected outer types.
        if (off + 0x38 <= len) {
            uint32_t v = *(const uint32_t *)(p + off);
            if (v == 0x10000 || v == 0x10001) {
                uint32_t eo = *(const uint32_t *)(p + off + 0x28);
                uint32_t sz = *(const uint32_t *)(p + off + 0x2c);
                uint32_t it = *(const uint32_t *)(p + off + 0x30);
                uint32_t st = *(const uint32_t *)(p + off + 0x34);
                fprintf(stderr, "  OUTER@+%#zx type=%#x end_off=%#x size=%#x inner=%#x sub=%u\n",
                        off, v, eo, sz, it, st);
            }
        }
    }
}

static int run_blit(int maxStage) {
    fprintf(stderr, "IOSBLIT START maxStage=%d\n", maxStage);
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
        // Dump after commit+wait — at this point the kernel has read the cmd buffer; the
        // userland VA still maps to the same region, so the bytes are visible to us.
        kcmd_dump_cb(cb);
        fprintf(stderr, "IOSBLIT [4d] status=%ld readback[0]=0x%02x [4095]=0x%02x (expect 0xab)\n",
                (long)[cb status], p[0], p[4095]);
    }
    return 0;
}

// Minimal UIKit app: create a real foreground window, then run the blit once. A foreground
// UIApplication gets the GPU IOKit sandbox extension that a headless process is denied.
@interface BlitAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation BlitAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    fprintf(stderr, "IOSBLIT didFinishLaunching\n");
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    // Repeat the blit on a background thread (every 5s, bounded) so a debugger can attach mid-run
    // and catch a later iteration's IOConnect resource-creation/submit calls — LSEnvironment-based
    // delay proved unreliable on this app. Clean iOS submits complete (status 4); repeating a
    // bounded count is safe.
    int iters = 20;
    const char *is = getenv("IOSBLIT_ITERS"); if (is) iters = atoi(is);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < iters; i++) {
            fprintf(stderr, "IOSBLIT iter %d/%d\n", i, iters);
            run_blit(4);
            sleep(5);
        }
        fprintf(stderr, "IOSBLIT loop done\n");
    });
    return YES;
}
@end

static int being_debugged(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info; size_t sz = sizeof(info);
    info.kp_proc.p_flag = 0;
    if (sysctl(mib, 4, &info, &sz, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int main(int argc, char **argv) {
    // IOSBLIT_LOG set (terminal runs) -> write to that file; else (app) -> route stderr to oslog.
    const char *logp = getenv("IOSBLIT_LOG");
    if (logp) {
        if (freopen(logp, "w", stderr)) setbuf(stderr, NULL);
    } else {
        g_oslog = os_log_create("com.dcmmc.iosblit", "trace");
        FILE *lf = funopen(NULL, NULL, oslog_writefn, NULL, NULL);
        if (lf) { setvbuf(lf, NULL, _IONBF, 0); stderr = lf; }
    }
    // Native iOS Metal sets up the GPU connection (open AGXDeviceUserClient, map the submit ring,
    // establish the resource/VA model) ONCE at first device init, via IOConnect calls that happen
    // before a late-attaching debugger can see them. Wait (up to 20s) for lldb to attach BEFORE any
    // GPU work so the full setup sequence is captured. Proceeds immediately once traced.
    fprintf(stderr, "IOSBLIT main — waiting up to 20s for debugger before GPU init\n");
    for (int i = 0; i < 200 && !being_debugged(); i++) usleep(100000);
    fprintf(stderr, "IOSBLIT proceeding (debugger=%d) -> UIApplicationMain\n", being_debugged());
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([BlitAppDelegate class]));
    }
}
