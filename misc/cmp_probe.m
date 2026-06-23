// cmp_probe.m — dual-target behavior comparison probe.
//
// One source, built for BOTH iOS-native (real AGX / iOS frameworks) and
// macOS-chroot (run under libmachook). Run the same mode on both sides and diff
// the output to pin down where chroot-macOS diverges from iOS-native.
//
// Build + run via misc/cmp_run.sh <mode>. Modes:
//   env       OS/hw/process identity (confirm which environment we're in)
//   metal     MTLCreateSystemDefaultDevice — name, class, key capabilities
//   gpu       IOSurface → Metal texture → GPU clear → CPU read-back (the
//             decisive "does GPU render reach the IOSurface" test)
//   window    CGWindowListCopyWindowInfo — every window WS knows about
//             (pid/owner/name/layer/onscreen/bounds). For the loginwindow vs
//             desktop-session question. Needs a running WS to be meaningful.
//   space     CGS connection + active space + space list (private SkyLight) —
//             is loginwindow the space owner? is there a user space?
//   all       run them all
//
// Everything is read-only / self-contained; safe to run repeatedly.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static int streq(const char *a, const char *b) { return a && b && strcmp(a, b) == 0; }

static uint64_t msg_u64(id o, const char *s) { if (!o) return 0; typedef uint64_t (*f)(id, SEL); return ((f)objc_msgSend)(o, sel_registerName(s)); }
static void   *msg_ptr(id o, const char *s) { if (!o) return NULL; typedef void *(*f)(id, SEL); return ((f)objc_msgSend)(o, sel_registerName(s)); }
static BOOL    msg_bool(id o, const char *s){ if (!o) return NO; typedef BOOL (*f)(id, SEL); return ((f)objc_msgSend)(o, sel_registerName(s)); }

// ───────────────────────────── env ─────────────────────────────
static void probe_env(void) {
    printf("-- env --\n");
    char buf[256]; size_t len;
    const char *keys[] = { "kern.osversion", "kern.osproductversion", "kern.ostype",
                           "hw.model", "hw.machine", "kern.bootargs", NULL };
    for (int i = 0; keys[i]; i++) {
        len = sizeof(buf); buf[0] = 0;
        if (sysctlbyname(keys[i], buf, &len, NULL, 0) == 0) printf("  %-22s = %s\n", keys[i], buf);
        else printf("  %-22s = (sysctl failed)\n", keys[i]);
    }
    struct utsname u; if (uname(&u) == 0)
        printf("  uname               = %s %s %s (%s)\n", u.sysname, u.release, u.machine, u.version);
    printf("  pid=%d euid=%d uid=%d\n", getpid(), geteuid(), getuid());
    printf("  NSProcessInfo.os    = %s\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
}

// ──────────────────────────── metal ────────────────────────────
static void probe_metal(void) {
    printf("-- metal --\n");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("  MTLCreateSystemDefaultDevice = nil\n"); return; }
    printf("  device.name  = %s\n", dev.name.UTF8String);
    printf("  device.class = %s\n", class_getName([(id)dev class]));
    printf("  registryID   = %#llx\n", (unsigned long long)dev.registryID);
    printf("  hasUnifiedMemory = %d\n", dev.hasUnifiedMemory);
    printf("  maxBufferLength  = %#lx\n", (unsigned long)dev.maxBufferLength);
    printf("  recommendedMaxWorkingSetSize = %#llx\n", (unsigned long long)dev.recommendedMaxWorkingSetSize);
    // a couple of GPU family checks (Apple7 = M1/A14)
    typedef BOOL (*sf_t)(id, SEL, NSInteger);
    SEL sf = sel_registerName("supportsFamily:");
    for (NSInteger fam = 1001; fam <= 1009; fam++)  // MTLGPUFamilyApple1..9 = 1001..1009
        if (((sf_t)objc_msgSend)((id)dev, sf, fam)) printf("  supportsFamily Apple%ld = YES\n", fam - 1000);
}

// ───────────────────────────── gpu ─────────────────────────────
// IOSurface → texture → GPU render-clear green → read IOSurface. The decisive
// "does a GPU render land in the IOSurface's CPU pages" test (iOS-native: yes).
static void probe_gpu(void) {
    printf("-- gpu --\n");
    const int W = 256, H = 256;
    NSDictionary *props = @{ (id)kIOSurfaceWidth:@(W), (id)kIOSurfaceHeight:@(H),
                             (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA') };
    IOSurfaceRef ios = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!ios) { printf("  IOSurfaceCreate FAILED\n"); return; }
    uint32_t *base = (uint32_t *)IOSurfaceGetBaseAddress(ios);
    printf("  IOSurface base=%p bpr=%zu id=%u\n", base, IOSurfaceGetBytesPerRow(ios), IOSurfaceGetID(ios));

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("  no device\n"); CFRelease(ios); return; }

    id buf = ((id (*)(id, SEL, IOSurfaceRef))objc_msgSend)((id)dev, sel_registerName("newBufferWithIOSurface:"), ios);
    printf("  newBufferWithIOSurface: gpuAddress=%#llx contents=%p\n",
           buf ? msg_u64(buf, "gpuAddress") : 0, buf ? msg_ptr(buf, "contents") : NULL);

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:d iosurface:ios plane:0];
    if (!tex) { printf("  newTextureWithDescriptor:iosurface: = nil\n"); CFRelease(ios); return; }

    for (int i = 0; i < W * H; i++) base[i] = 0x55555555;          // marker
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);   // green
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    int green = 0, marker = 0;
    IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
    for (int i = 0; i < W * H; i++) { uint32_t p = base[i]; if ((p & 0xFFFFFF) == 0xFF00 || p == 0xFF00FF00) green++; else if (p == 0x55555555) marker++; }
    IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
    printf("  render-clear cb.status=%ld err=%s\n", (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "none");
    printf("  IOSurface after GPU green: green=%d marker=%d  VERDICT=%s\n", green, marker,
           green > W * H / 2 ? "GPU-WRITE-REACHED-IOSURFACE ✓"
                            : (marker > W * H / 2 ? "IOSURFACE-UNTOUCHED ✗" : "PARTIAL"));
    CFRelease(ios);
}

// ──────────────────────────── window ───────────────────────────
static void probe_window(void) {
    printf("-- window (CGWindowListCopyWindowInfo) --\n");
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    typedef CFArrayRef (*lst_t)(uint32_t, uint32_t);
    lst_t lst = (lst_t)dlsym(cg ? cg : RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
    if (!lst) { printf("  CGWindowListCopyWindowInfo unavailable (%s)\n", dlerror()); return; }
    // option 0 = all on-screen+off; 1<<4 = kCGWindowListOptionAll-ish; use 0 and (1<<0|1<<4)
    const struct { const char *name; uint32_t opt; } passes[] = {
        { "ALL",      (1u << 4) /*OptionAll*/ },
        { "ONSCREEN", (1u << 0) /*OnScreenOnly*/ },
    };
    for (int pi = 0; pi < 2; pi++) {
        CFArrayRef arr = lst(passes[pi].opt, 0 /*kCGNullWindowID*/);
        long n = arr ? CFArrayGetCount(arr) : -1;
        printf("  [%s] count=%ld\n", passes[pi].name, n);
        for (long i = 0; i < n && i < 40; i++) {
            CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            long wid = 0, pid = 0, layer = 0, onscr = 0, x = 0, y = 0, ww = 0, hh = 0;
            CFNumberRef num;
            if ((num = CFDictionaryGetValue(w, CFSTR("kCGWindowNumber"))))   CFNumberGetValue(num, kCFNumberLongType, &wid);
            if ((num = CFDictionaryGetValue(w, CFSTR("kCGWindowOwnerPID")))) CFNumberGetValue(num, kCFNumberLongType, &pid);
            if ((num = CFDictionaryGetValue(w, CFSTR("kCGWindowLayer"))))    CFNumberGetValue(num, kCFNumberLongType, &layer);
            if ((num = CFDictionaryGetValue(w, CFSTR("kCGWindowIsOnscreen"))))CFNumberGetValue(num, kCFNumberLongType, &onscr);
            CFDictionaryRef b = CFDictionaryGetValue(w, CFSTR("kCGWindowBounds"));
            if (b) { CFNumberRef t;
                if ((t = CFDictionaryGetValue(b, CFSTR("X")))) CFNumberGetValue(t, kCFNumberLongType, &x);
                if ((t = CFDictionaryGetValue(b, CFSTR("Y")))) CFNumberGetValue(t, kCFNumberLongType, &y);
                if ((t = CFDictionaryGetValue(b, CFSTR("Width")))) CFNumberGetValue(t, kCFNumberLongType, &ww);
                if ((t = CFDictionaryGetValue(b, CFSTR("Height")))) CFNumberGetValue(t, kCFNumberLongType, &hh); }
            CFStringRef owner = CFDictionaryGetValue(w, CFSTR("kCGWindowOwnerName"));
            CFStringRef name  = CFDictionaryGetValue(w, CFSTR("kCGWindowName"));
            char ob[128] = "?", nb[128] = "";
            if (owner) CFStringGetCString(owner, ob, sizeof(ob), kCFStringEncodingUTF8);
            if (name)  CFStringGetCString(name, nb, sizeof(nb), kCFStringEncodingUTF8);
            printf("    wid=%ld pid=%ld layer=%ld on=%ld %ldx%ld@(%ld,%ld) owner='%s' name='%s'\n",
                   wid, pid, layer, onscr, ww, hh, x, y, ob, nb);
        }
        if (arr) CFRelease(arr);
    }
}

// ──────────────────────────── space ────────────────────────────
// Private SkyLight CGS APIs — is loginwindow the active-space owner, and is
// there any user (desktop) space at all?
static void probe_space(void) {
    printf("-- space (CGS private) --\n");
    void *sl = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    void *h = sl ? sl : RTLD_DEFAULT;
    typedef int (*conn_t)(void);
    conn_t mainConn = (conn_t)dlsym(h, "CGSMainConnectionID");
    if (!mainConn) mainConn = (conn_t)dlsym(h, "_CGSDefaultConnection");
    if (!mainConn) { printf("  CGSMainConnectionID unavailable\n"); return; }
    int cid = mainConn();
    printf("  CGSMainConnectionID = %d\n", cid);
    typedef uint64_t (*aspace_t)(int);
    aspace_t getActive = (aspace_t)dlsym(h, "CGSGetActiveSpace");
    if (getActive) printf("  CGSGetActiveSpace   = %llu\n", (unsigned long long)getActive(cid));
    typedef CFArrayRef (*spaces_t)(int);
    spaces_t copySpaces = (spaces_t)dlsym(h, "CGSCopyManagedDisplaySpaces");
    if (copySpaces) { CFArrayRef sp = copySpaces(cid); printf("  CGSCopyManagedDisplaySpaces count=%ld\n", sp ? CFArrayGetCount(sp) : -1); if (sp) CFRelease(sp); }
    typedef int (*wc_t)(int, int *);
    wc_t wcount = (wc_t)dlsym(h, "CGSGetWindowCount");
    if (wcount) { int c = 0; wcount(cid, &c); printf("  CGSGetWindowCount   = %d\n", c); }
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *mode = argc > 1 ? argv[1] : "all";
    char host[256] = ""; size_t hl = sizeof(host); sysctlbyname("hw.model", host, &hl, NULL, 0);
    printf("==================== cmp_probe mode=%s pid=%d ====================\n", mode, getpid());
    if (streq(mode, "env")    || streq(mode, "all")) probe_env();
    if (streq(mode, "metal")  || streq(mode, "all")) probe_metal();
    if (streq(mode, "gpu")    || streq(mode, "all")) probe_gpu();
    if (streq(mode, "window") || streq(mode, "all")) probe_window();
    if (streq(mode, "space")  || streq(mode, "all")) probe_space();
    printf("==================== cmp_probe done ====================\n");
    return 0;
} }
