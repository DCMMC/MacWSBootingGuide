@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
#import "interpose.h"
#import "utils.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <pthread.h>
#import <limits.h>
#import <ptrauth.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#include <execinfo.h>
#import "macws_host_protocol.h"

// The iOS kernel cannot service macOS arm64's MAP_JIT/APRR contract for the
// chroot process, even though CS_DEBUGGED permits ordinary W^X mprotect
// transitions.  Keep this adapter opt-in and use it only for programs that
// were compiled with pthread_jit_write_protect_np support (currently the
// latest VS Code Electron framework).
//
// Unlike a check bypass, this preserves the executable-memory invariant:
// MAP_JIT reservations are retried as normal anonymous reservations, RWX
// requests become writable-only, and the existing V8 write-scope transitions
// flip the recorded ranges between RW and RX.  A mach_vm_remap optimization
// that loses execute permission on iOS is declined before it overwrites the
// writable destination, allowing V8's existing copy fallback to run.
typedef struct {
    uintptr_t base;
    size_t size;
} MacWSJITRange;

static MacWSJITRange g_macws_jit_ranges[32];
static _Atomic unsigned g_macws_jit_range_count = 0;
static pthread_mutex_t g_macws_jit_state_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned g_macws_jit_active_writers = 0;
static _Thread_local bool g_macws_jit_thread_writable = false;
static _Atomic unsigned g_macws_jit_remap_declines = 0;
static _Atomic unsigned g_macws_jit_permission_flips = 0;
static _Atomic unsigned g_macws_jit_mprotect_calls = 0;
static _Atomic unsigned g_macws_jit_exec_waits = 0;
static _Atomic unsigned g_macws_jit_late_fetch_retries = 0;
static _Atomic unsigned g_macws_jit_handler_checks = 0;
static pthread_mutex_t g_macws_jit_handler_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sigaction g_macws_jit_downstream_sigbus;
static bool g_macws_jit_downstream_sigbus_valid = false;

static void macws_jit_ensure_exec_barrier_handler(void);

static bool macws_jit_mprotect_compat_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_JIT_MPROTECT_COMPAT") ? 1 : 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

static bool macws_jit_range_overlaps(uintptr_t base, size_t size) {
    if (size == 0 || base > UINTPTR_MAX - size) return false;
    uintptr_t end = base + size;
    bool overlaps = false;
    pthread_mutex_lock(&g_macws_jit_state_lock);
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        uintptr_t range_base = g_macws_jit_ranges[i].base;
        size_t range_size = g_macws_jit_ranges[i].size;
        if (range_size == 0 || range_base > UINTPTR_MAX - range_size) continue;
        if (base < range_base + range_size && range_base < end) {
            overlaps = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_macws_jit_state_lock);
    return overlaps;
}

static void macws_jit_record_range(void *address, size_t size) {
    if (!address || address == MAP_FAILED || size == 0) return;
    pthread_mutex_lock(&g_macws_jit_state_lock);
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_relaxed);
    if (count < sizeof(g_macws_jit_ranges) / sizeof(g_macws_jit_ranges[0])) {
        g_macws_jit_ranges[count].base = (uintptr_t)address;
        g_macws_jit_ranges[count].size = size;
        atomic_store_explicit(&g_macws_jit_range_count, count + 1,
                              memory_order_release);
        fprintf(stderr,
            "#### JIT-MPROTECT range[%u]=[%p,%p) source=MAP_JIT-EINVAL\n",
            count, address, (void *)((uintptr_t)address + size));
    }
    pthread_mutex_unlock(&g_macws_jit_state_lock);
    macws_jit_ensure_exec_barrier_handler();
}

static void macws_jit_remove_range(void *address, size_t size) {
    if (!address || size == 0 || (uintptr_t)address > UINTPTR_MAX - size) return;
    uintptr_t removed_base = (uintptr_t)address;
    uintptr_t removed_end = removed_base + size;

    pthread_mutex_lock(&g_macws_jit_state_lock);
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_relaxed);
    for (unsigned i = 0; i < count;) {
        uintptr_t range_base = g_macws_jit_ranges[i].base;
        size_t range_size = g_macws_jit_ranges[i].size;
        uintptr_t range_end = range_base + range_size;
        if (range_size == 0 || removed_base >= range_end ||
            range_base >= removed_end) {
            i++;
            continue;
        }

        if (removed_base <= range_base && removed_end >= range_end) {
            memmove(&g_macws_jit_ranges[i], &g_macws_jit_ranges[i + 1],
                    (count - i - 1) * sizeof(g_macws_jit_ranges[0]));
            count--;
            continue;
        }
        if (removed_base <= range_base) {
            g_macws_jit_ranges[i].base = removed_end;
            g_macws_jit_ranges[i].size = range_end - removed_end;
            i++;
            continue;
        }
        if (removed_end >= range_end) {
            g_macws_jit_ranges[i].size = removed_base - range_base;
            i++;
            continue;
        }

        // A middle slice was unmapped.  Preserve both live pieces when the
        // fixed table has room; this path is not expected for V8 CodeRange,
        // whose reservation and release are both page-aligned whole ranges.
        if (count < sizeof(g_macws_jit_ranges) /
                        sizeof(g_macws_jit_ranges[0])) {
            memmove(&g_macws_jit_ranges[i + 2],
                    &g_macws_jit_ranges[i + 1],
                    (count - i - 1) * sizeof(g_macws_jit_ranges[0]));
            g_macws_jit_ranges[i].size = removed_base - range_base;
            g_macws_jit_ranges[i + 1].base = removed_end;
            g_macws_jit_ranges[i + 1].size = range_end - removed_end;
            count++;
            i += 2;
        } else {
            // Retain the larger live side rather than tracking an unmapped
            // hole that a future unrelated allocation could reuse.
            size_t left_size = removed_base - range_base;
            size_t right_size = range_end - removed_end;
            if (right_size > left_size) {
                g_macws_jit_ranges[i].base = removed_end;
                g_macws_jit_ranges[i].size = right_size;
            } else {
                g_macws_jit_ranges[i].size = left_size;
            }
            i++;
        }
    }
    atomic_store_explicit(&g_macws_jit_range_count, count,
                          memory_order_release);
    pthread_mutex_unlock(&g_macws_jit_state_lock);
}

static bool macws_jit_pc_in_recorded_range(uintptr_t pc) {
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_acquire);
    if (count > sizeof(g_macws_jit_ranges) / sizeof(g_macws_jit_ranges[0])) {
        count = sizeof(g_macws_jit_ranges) / sizeof(g_macws_jit_ranges[0]);
    }
    for (unsigned i = 0; i < count; i++) {
        uintptr_t base = g_macws_jit_ranges[i].base;
        size_t size = g_macws_jit_ranges[i].size;
        if (size && base <= pc && pc - base < size) return true;
    }
    return false;
}

static void macws_jit_forward_sigbus(int signo, siginfo_t *info,
                                     void *context) {
    if (g_macws_jit_downstream_sigbus_valid) {
        struct sigaction downstream = g_macws_jit_downstream_sigbus;
        if ((downstream.sa_flags & SA_SIGINFO) &&
            downstream.sa_sigaction &&
            downstream.sa_sigaction != (void *)SIG_DFL &&
            downstream.sa_sigaction != (void *)SIG_IGN) {
            downstream.sa_sigaction(signo, info, context);
            return;
        }
        if (!(downstream.sa_flags & SA_SIGINFO) &&
            downstream.sa_handler == SIG_IGN) {
            return;
        }
        if (!(downstream.sa_flags & SA_SIGINFO) &&
            downstream.sa_handler && downstream.sa_handler != SIG_DFL) {
            downstream.sa_handler(signo);
            return;
        }
    }

    // Preserve the ordinary crash path (CrashReporter/Mach exception handling)
    // for every SIGBUS that is not an instruction fetch temporarily blocked by
    // our W^X transition.
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    sigaction(SIGBUS, &default_action, NULL);
    raise(SIGBUS);
}

static void macws_jit_exec_barrier_sigbus(int signo, siginfo_t *info,
                                          void *context) {
    uintptr_t pc = 0;
#if defined(__arm64__) || defined(__arm64e__)
    ucontext_t *ucontext = (ucontext_t *)context;
    if (ucontext && ucontext->uc_mcontext) {
        pc = (uintptr_t)arm_thread_state64_get_pc(
            ucontext->uc_mcontext->__ss);
    }
#else
    (void)context;
#endif

    // A writer always executes this hook and V8's surrounding C++ from signed
    // __TEXT, never from CodeRange.  If it does try to execute JIT code while
    // its own write scope is open, waiting would self-deadlock, so preserve the
    // original fault instead of hiding that invariant violation.
    // The exception is raised when the fetch observes RW, but signal delivery
    // can occur after the last writer has already restored RX and published a
    // zero writer count.  Treat both states as retryable.  Requiring si_addr
    // to equal PC is important: a genuine data SIGBUS raised by JIT-generated
    // code must still follow Chromium's ordinary crash path.
    if (signo == SIGBUS && pc && info &&
        (uintptr_t)info->si_addr == pc && !g_macws_jit_thread_writable &&
        macws_jit_pc_in_recorded_range(pc)) {
        unsigned writers = atomic_load_explicit(
            &g_macws_jit_active_writers, memory_order_acquire);
        if (writers != 0) {
            atomic_fetch_add_explicit(&g_macws_jit_exec_waits, 1,
                                      memory_order_relaxed);
            while (atomic_load_explicit(&g_macws_jit_active_writers,
                                        memory_order_acquire) != 0) {
                __asm__ volatile("yield" ::: "memory");
            }
        } else {
            atomic_fetch_add_explicit(&g_macws_jit_late_fetch_retries, 1,
                                      memory_order_relaxed);
        }
        // Returning retries the same faulting PC after the last writer has
        // restored the complete CodeRange to RX.
        return;
    }

    macws_jit_forward_sigbus(signo, info, context);
}

static void macws_jit_ensure_exec_barrier_handler(void) {
    if (!macws_jit_mprotect_compat_enabled()) return;

    pthread_mutex_lock(&g_macws_jit_handler_lock);
    struct sigaction current;
    memset(&current, 0, sizeof(current));
    if (sigaction(SIGBUS, NULL, &current) != 0) {
        pthread_mutex_unlock(&g_macws_jit_handler_lock);
        return;
    }
    bool already_installed =
        (current.sa_flags & SA_SIGINFO) &&
        current.sa_sigaction == macws_jit_exec_barrier_sigbus;
    if (!already_installed) {
        g_macws_jit_downstream_sigbus = current;
        g_macws_jit_downstream_sigbus_valid = true;

        struct sigaction barrier;
        memset(&barrier, 0, sizeof(barrier));
        barrier.sa_sigaction = macws_jit_exec_barrier_sigbus;
        barrier.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&barrier.sa_mask);
        if (sigaction(SIGBUS, &barrier, NULL) == 0) {
            fprintf(stderr,
                "#### JIT-MPROTECT execution barrier installed "
                "(W^X fetch-wait compatibility)\n");
        }
    }
    pthread_mutex_unlock(&g_macws_jit_handler_lock);
}

static void macws_jit_set_all_permissions(int protection) {
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        void *base = (void *)g_macws_jit_ranges[i].base;
        size_t size = g_macws_jit_ranges[i].size;
        if (mprotect(base, size, protection) != 0) {
            fprintf(stderr,
                "#### JIT-MPROTECT flip FAIL range=%u base=%p size=%#zx "
                "prot=%#x errno=%d\n",
                i, base, size, protection, errno);
        }
    }
    unsigned sequence = atomic_fetch_add_explicit(
        &g_macws_jit_permission_flips, 1, memory_order_relaxed) + 1;
    if (sequence <= 32 || (sequence % 1024) == 0) {
        fprintf(stderr,
            "#### JIT-MPROTECT flip #%u ranges=%u prot=%s writers=%u "
            "exec_waits=%u late_retries=%u\n",
            sequence, count,
            protection == (PROT_READ | PROT_WRITE) ? "RW" : "RX",
            atomic_load_explicit(&g_macws_jit_active_writers,
                                 memory_order_relaxed),
            atomic_load_explicit(&g_macws_jit_exec_waits,
                                 memory_order_relaxed),
            atomic_load_explicit(&g_macws_jit_late_fetch_retries,
                                 memory_order_relaxed));
    }
}

// GlassDemo blur A/B fixture.  This is deliberately a render-input diagnostic,
// not a graphics-protocol patch: it inserts a high-frequency stripe view below
// the demo's existing material=13 / WithinWindow NSVisualEffectView.  The
// exposed margin and the covered center therefore carry the same source pattern
// through two paths in one window.  Nothing here changes the effect view's
// material, blending mode, state, or compositor implementation.
//
// Enabled only for the GlassDemo process by MACWS_GLASS_BLUR_AB=1.  AppKit is
// resolved dynamically because libmachook itself is built against the iOS SDK.
typedef CGRect (*macws_msg_rect_t)(id, SEL);
typedef id (*macws_msg_id_t)(id, SEL);
typedef id (*macws_msg_id_rect_t)(id, SEL, CGRect);
typedef id (*macws_msg_id_index_t)(id, SEL, NSUInteger);
typedef BOOL (*macws_msg_bool_id_t)(id, SEL, id);
typedef NSInteger (*macws_msg_integer_t)(id, SEL);
typedef NSUInteger (*macws_msg_count_t)(id, SEL);
typedef void (*macws_msg_void_bool_t)(id, SEL, BOOL);
typedef void (*macws_msg_void_uint_t)(id, SEL, NSUInteger);
typedef void (*macws_msg_void_view_order_t)(id, SEL, id, NSInteger, id);
typedef void (*macws_msg_void_rect_t)(id, SEL, CGRect);

// Diagnostic-only ObjC method/IMP map for comparing the real macOS 13.4 AGX
// command producer with the iOS 16.3 producer.  This does not swizzle or alter
// any method.  It is armed by MACWS_AGX_DUMP_METHODS=1 or the one-shot
// /private/tmp/macws_agx_dump_methods sentinel and writes inside the chroot.
static BOOL macws_agx_method_map_class(const char *name) {
    if (!name) return NO;
    static const char *const wanted[] = {
        "IOGPUMetalCommandBuffer",
        "AGXG13GFamilyCommandBuffer",
        "IOGPUMetalCommandQueue",
        "AGXG13GFamilyCommandQueue",
        "IOGPUMetalRenderCommandEncoder",
        "AGXG13GFamilyRenderContext",
    };
    for (size_t i = 0; i < sizeof(wanted) / sizeof(wanted[0]); i++) {
        if (!strcmp(name, wanted[i])) return YES;
    }
    return NO;
}

static void macws_agx_dump_method_list(int fd, Class cls, const char *kind) {
    if (fd < 0 || !cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    const char *class_name = class_getName(cls);
    Class superclass = class_getSuperclass(cls);
    dprintf(fd,
        "MACWS AGX-CLASS kind=%s class=%p name=%s super=%s methods=%u\n",
        kind, (void *)cls, class_name ?: "(null)",
        superclass ? class_getName(superclass) : "(none)", count);
    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        SEL selector = method_getName(method);
        IMP signed_imp = method_getImplementation(method);
        void *imp = ptrauth_strip((void *)signed_imp,
                                  ptrauth_key_function_pointer);
        Dl_info info = {0};
        dladdr(imp, &info);
        uintptr_t offset = info.dli_fbase
            ? (uintptr_t)imp - (uintptr_t)info.dli_fbase : 0;
        dprintf(fd,
            "MACWS AGX-METHOD kind=%s class=%s index=%u imp=%p "
            "image=%s base=%p offset=%#llx selector=%s types=%s\n",
            kind, class_name ?: "(null)", i, imp,
            info.dli_fname ?: "(unknown)", info.dli_fbase,
            (unsigned long long)offset,
            selector ? sel_getName(selector) : "(null)",
            method_getTypeEncoding(method) ?: "(null)");
    }
    free(methods);
}

static void macws_dump_agx_method_map(void) {
    int fd = open("/private/tmp/macws_agx_runtime_methods.log",
                  O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned int matched = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!macws_agx_method_map_class(name)) continue;
        matched++;
        macws_agx_dump_method_list(fd, classes[i], "instance");
        macws_agx_dump_method_list(fd, object_getClass(classes[i]), "class");
    }
    dprintf(fd, "MACWS AGX-RUNTIME classes=%u matched=%u complete=YES\n",
            count, matched);
    free(classes);
    close(fd);
}

// Diagnostic-only producer trace.  The submitted subtype-1 record is 0x20
// bytes larger under the macOS 13.4 AGX bundle than under native iOS 16.3.
// Trace the upstream AGX reservation API without changing its arguments or
// return value, so the actual caller offsets identify which encoder decides
// the record layout.  Armed only by /private/tmp/macws_agx_trace_reserve.
typedef void *(*macws_agx_reserve_fn)(id, SEL, uint64_t);
static macws_agx_reserve_fn g_macws_agx_orig_reserve = NULL;
static _Atomic unsigned g_macws_agx_reserve_sequence = 0;

static void *macws_agx_trace_reserve(id self, SEL cmd, uint64_t size) {
    unsigned sequence = atomic_fetch_add(&g_macws_agx_reserve_sequence, 1) + 1;
    if (sequence <= 256) {
        void *frames[8] = {0};
        int frame_count = backtrace(frames, 8);
        fprintf(stderr,
            "#### AGX-RESERVE-DIAG #%u self=%p size=%#llx frames=%d\n",
            sequence, self, (unsigned long long)size, frame_count);
        for (int i = 1; i < frame_count; i++) {
            void *pc = ptrauth_strip(frames[i],
                ptrauth_key_function_pointer);
            Dl_info info = {0};
            dladdr(pc, &info);
            fprintf(stderr,
                "#### AGX-RESERVE-DIAG #%u frame[%d]=%p image=%s "
                "base=%p offset=%#llx symbol=%s\n",
                sequence, i, pc, info.dli_fname ?: "(unknown)",
                info.dli_fbase,
                (unsigned long long)(info.dli_fbase
                    ? (uintptr_t)pc - (uintptr_t)info.dli_fbase : 0),
                info.dli_sname ?: "(unknown)");
        }
    }
    return g_macws_agx_orig_reserve(self, cmd, size);
}

static void macws_install_agx_reserve_trace(void) {
    Class cls = objc_getClass("AGXG13GFamilyCommandBuffer");
    SEL selector = sel_registerName("reserveKernelCommandBufferSpace:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) {
        fprintf(stderr,
            "#### AGX-RESERVE-DIAG install failed: method unavailable\n");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)macws_agx_trace_reserve) return;
    g_macws_agx_orig_reserve = (macws_agx_reserve_fn)current;
    method_setImplementation(method, (IMP)macws_agx_trace_reserve);
    fprintf(stderr,
        "#### AGX-RESERVE-DIAG installed class=%p original=%p trace=%p\n",
        (void *)cls, (void *)current, (void *)macws_agx_trace_reserve);
}

static BOOL macws_glass_blur_ab_is_opaque(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static void macws_glass_blur_ab_draw(id self, SEL _cmd, CGRect dirty) {
    (void)_cmd;
    (void)dirty;
    Class colorClass = objc_getClass("NSColor");
    Class pathClass = objc_getClass("NSBezierPath");
    if (!colorClass || !pathClass) return;

    CGRect bounds = ((macws_msg_rect_t)objc_msgSend)(self,
        sel_registerName("bounds"));
    id black = ((macws_msg_id_t)objc_msgSend)((id)colorClass,
        sel_registerName("blackColor"));
    id white = ((macws_msg_id_t)objc_msgSend)((id)colorClass,
        sel_registerName("whiteColor"));
    SEL setFill = sel_registerName("setFill");
    SEL fillRect = sel_registerName("fillRect:");

    // Three spatial frequencies in one source distinguish an opaque flat tint
    // from a real low-pass backdrop: 4pt bars should be strongly attenuated,
    // while 48pt bars should retain black/white influence with broadened edges.
    // The uncovered 28pt top/bottom margins are the sharp-input controls.
    const CGFloat stripeWidths[3] = { 4.0, 16.0, 48.0 };
    CGFloat minX = bounds.origin.x;
    CGFloat maxX = bounds.origin.x + bounds.size.width;
    CGFloat sectionWidth = bounds.size.width / 3.0;
    for (NSInteger section = 0; section < 3; section++) {
        CGFloat sectionMinX = minX + sectionWidth * section;
        CGFloat sectionMaxX = section == 2 ? maxX : sectionMinX + sectionWidth;
        CGFloat stripeWidth = stripeWidths[section];
        NSInteger stripe = 0;
        for (CGFloat x = sectionMinX; x < sectionMaxX;
             x += stripeWidth, stripe++) {
            id color = (stripe & 1) ? white : black;
            ((void (*)(id, SEL))objc_msgSend)(color, setFill);
            CGFloat width = x + stripeWidth > sectionMaxX
                ? sectionMaxX - x : stripeWidth;
            CGRect r = (CGRect){
                .origin = { x, bounds.origin.y },
                .size = { width, bounds.size.height },
            };
            ((macws_msg_void_rect_t)objc_msgSend)((id)pathClass, fillRect, r);
        }
    }
}

static void macws_glass_blur_ab_find_effect(id view, Class effectClass,
                                             id *target) {
    if (!view || *target) return;
    if (((macws_msg_bool_id_t)objc_msgSend)(view,
            sel_registerName("isKindOfClass:"), effectClass)) {
        NSInteger material = ((macws_msg_integer_t)objc_msgSend)(view,
            sel_registerName("material"));
        NSInteger blending = ((macws_msg_integer_t)objc_msgSend)(view,
            sel_registerName("blendingMode"));
        if (material == 13 && blending == 1) {
            *target = view;
            return;
        }
    }
    id children = ((macws_msg_id_t)objc_msgSend)(view,
        sel_registerName("subviews"));
    NSUInteger count = children ? ((macws_msg_count_t)objc_msgSend)(children,
        sel_registerName("count")) : 0;
    for (NSUInteger i = 0; i < count && !*target; i++) {
        id child = ((macws_msg_id_index_t)objc_msgSend)(children,
            sel_registerName("objectAtIndex:"), i);
        macws_glass_blur_ab_find_effect(child, effectClass, target);
    }
}

static Class macws_glass_blur_ab_stripe_class(void) {
    Class cls = objc_getClass("MACWSGlassBlurABStripeView");
    if (cls) return cls;
    Class superClass = objc_getClass("NSView");
    if (!superClass) return Nil;
    cls = objc_allocateClassPair(superClass, "MACWSGlassBlurABStripeView", 0);
    if (!cls) return objc_getClass("MACWSGlassBlurABStripeView");
    class_addMethod(cls, sel_registerName("drawRect:"),
                    (IMP)macws_glass_blur_ab_draw,
                    "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    class_addMethod(cls, sel_registerName("isOpaque"),
                    (IMP)macws_glass_blur_ab_is_opaque, "B@:");
    objc_registerClassPair(cls);
    return cls;
}

static void macws_glass_blur_ab_attempt(unsigned attempt) {
    Class appClass = objc_getClass("NSApplication");
    Class effectClass = objc_getClass("NSVisualEffectView");
    if (!appClass || !effectClass) goto retry;

    id app = ((macws_msg_id_t)objc_msgSend)((id)appClass,
        sel_registerName("sharedApplication"));
    id windows = app ? ((macws_msg_id_t)objc_msgSend)(app,
        sel_registerName("windows")) : nil;
    NSUInteger windowCount = windows ? ((macws_msg_count_t)objc_msgSend)(windows,
        sel_registerName("count")) : 0;
    id target = nil;
    for (NSUInteger i = 0; i < windowCount && !target; i++) {
        id window = ((macws_msg_id_index_t)objc_msgSend)(windows,
            sel_registerName("objectAtIndex:"), i);
        id content = ((macws_msg_id_t)objc_msgSend)(window,
            sel_registerName("contentView"));
        macws_glass_blur_ab_find_effect(content, effectClass, &target);
    }
    if (!target) goto retry;

    id parent = ((macws_msg_id_t)objc_msgSend)(target,
        sel_registerName("superview"));
    Class stripeClass = macws_glass_blur_ab_stripe_class();
    if (!parent || !stripeClass) goto retry;

    CGRect effectFrame = ((macws_msg_rect_t)objc_msgSend)(target,
        sel_registerName("frame"));
    CGRect parentBounds = ((macws_msg_rect_t)objc_msgSend)(parent,
        sel_registerName("bounds"));
    const CGFloat margin = 28.0;
    CGFloat stripeMinX = effectFrame.origin.x - margin;
    CGFloat stripeMinY = effectFrame.origin.y - margin;
    CGFloat stripeMaxX = effectFrame.origin.x + effectFrame.size.width + margin;
    CGFloat stripeMaxY = effectFrame.origin.y + effectFrame.size.height + margin;
    CGFloat parentMinX = parentBounds.origin.x;
    CGFloat parentMinY = parentBounds.origin.y;
    CGFloat parentMaxX = parentBounds.origin.x + parentBounds.size.width;
    CGFloat parentMaxY = parentBounds.origin.y + parentBounds.size.height;
    if (stripeMinX < parentMinX) stripeMinX = parentMinX;
    if (stripeMinY < parentMinY) stripeMinY = parentMinY;
    if (stripeMaxX > parentMaxX) stripeMaxX = parentMaxX;
    if (stripeMaxY > parentMaxY) stripeMaxY = parentMaxY;
    CGRect stripeFrame = (CGRect){
        .origin = { stripeMinX, stripeMinY },
        .size = { stripeMaxX - stripeMinX, stripeMaxY - stripeMinY },
    };
    if (stripeFrame.size.width <= 0 || stripeFrame.size.height <= 0) {
        fprintf(stderr,
            "#### GLASS-BLUR-AB invalid frame effect=(%.1f %.1f %.1f %.1f) parent=(%.1f %.1f %.1f %.1f)\n",
            effectFrame.origin.x, effectFrame.origin.y,
            effectFrame.size.width, effectFrame.size.height,
            parentBounds.origin.x, parentBounds.origin.y,
            parentBounds.size.width, parentBounds.size.height);
        return;
    }

    id stripe = ((macws_msg_id_rect_t)objc_msgSend)(
        ((macws_msg_id_t)objc_msgSend)((id)stripeClass, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), stripeFrame);
    if (!stripe) goto retry;
    ((macws_msg_void_uint_t)objc_msgSend)(stripe,
        sel_registerName("setAutoresizingMask:"), 0);
    ((macws_msg_void_view_order_t)objc_msgSend)(parent,
        sel_registerName("addSubview:positioned:relativeTo:"),
        stripe, -1 /* NSWindowBelow */, target);
    ((macws_msg_void_bool_t)objc_msgSend)(stripe,
        sel_registerName("setNeedsDisplay:"), YES);
    ((macws_msg_void_bool_t)objc_msgSend)(target,
        sel_registerName("setNeedsDisplay:"), YES);
    fprintf(stderr,
        "#### GLASS-BLUR-AB installed attempt=%u target=%s material=13 blending=1 effect=(%.1f %.1f %.1f %.1f) stripes=(%.1f %.1f %.1f %.1f) periods=8/32/96pt\n",
        attempt, object_getClassName(target),
        effectFrame.origin.x, effectFrame.origin.y,
        effectFrame.size.width, effectFrame.size.height,
        stripeFrame.origin.x, stripeFrame.origin.y,
        stripeFrame.size.width, stripeFrame.size.height);
    return;

retry:
    if (attempt >= 20) {
        fprintf(stderr,
            "#### GLASS-BLUR-AB failed: material=13 blending=1 view not found after %u attempts\n",
            attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        macws_glass_blur_ab_attempt(attempt + 1);
    });
}

static void macws_install_glass_blur_ab_if_requested(void) {
    if (!getenv("MACWS_GLASS_BLUR_AB")) return;
    const char *program = getprogname();
    if (!program || strcmp(program, "GlassDemo") != 0) {
        fprintf(stderr,
            "#### GLASS-BLUR-AB ignored for process=%s (GlassDemo only)\n",
            program ?: "(null)");
        return;
    }
    fprintf(stderr,
        "#### GLASS-BLUR-AB armed: preserve material/blending/state; insert stripes below existing WithinWindow view\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        macws_glass_blur_ab_attempt(1);
    });
}

// Exact logical length of the AGXBuffer currently being initialized on this
// thread.  The macOS AGX args layout used by initFull can encode a VA-shaped
// value at +0x58 (for example 0xc00000000 for a 24576-byte Mempool buffer),
// so truncating +0x58 to uint32_t in the iOS sel=0x9 translator loses the
// allocation size and used to fall back to 0x1000.
//
// Runtime-confirmed with project LLDB on 2026-07-23:
//   initUntracked len=24576 -> sel=0x9 type=0 args+0x40=0,
//   old translator sent +0x40=0x1000, kernel returned OUT+0x48=0x4000;
//   ImageStateEncoderGen6::grow then wrote item 684 at byte offset 0x4008
//   and faulted at +120.  This TLS bridge deliberately only applies when the
//   resource call remains on the initFull thread; its diagnostic log is the
//   runtime witness for that condition and it cannot race other WS threads.
static _Thread_local uint64_t g_macws_agx_initfull_len = 0;

// Armed only for WindowServer's coexistence mode after the exact macOS 13.4
// kern_SwapEnd callsite has been verified. IOConnectCallStructMethod_new uses
// this to translate physical-panel SwapEnd into SwapCancel while leaving the
// rest of Apple's kern_SwapEnd cleanup intact.
static _Atomic int g_macws_iomfb_coexist_swap_cancel = 0;
static void macws_install_quartzcore_frame_info_hook(
    const struct mach_header *header);
static IOReturn (*g_macws_orig_iomfb_swap_end)(void *framebuffer) = NULL;
static IOReturn MacwsIOMobileFramebufferSwapEnd_new(void *framebuffer);

// IOSurface
typedef id IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(NSDictionary* properties);
extern IOSurfaceRef IOSurfaceLookup(uint32_t surface_id);
extern CFDictionaryRef IOSurfaceCopyAllValues(IOSurfaceRef surface);
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerElement(IOSurfaceRef surface);
extern size_t IOSurfaceGetPlaneCount(IOSurfaceRef surface);
extern OSType IOSurfaceGetPixelFormat(IOSurfaceRef surface);
extern size_t IOSurfaceGetWidthOfPlane(IOSurfaceRef surface, size_t plane);
extern size_t IOSurfaceGetHeightOfPlane(IOSurfaceRef surface, size_t plane);
extern int IOSurfaceLock(IOSurfaceRef surface, uint32_t options,
                         uint32_t *seed);
extern int IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options,
                           uint32_t *seed);
extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef surface,
                                                    size_t plane);
extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);
extern size_t IOSurfaceGetWidthInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);
extern size_t IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef surface,
                                             size_t plane);
extern size_t IOSurfaceGetBytesPerTileDataOfPlane(IOSurfaceRef surface,
                                                  size_t plane);
extern size_t IOSurfaceGetOffsetOfPlane(IOSurfaceRef surface, size_t plane);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
extern void *IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef surface,
                                            size_t plane);
extern uint32_t IOSurfaceGetAddressFormatOfPlane(IOSurfaceRef surface,
                                                 size_t plane);
uint32_t macws_IOSurfaceGetCompressionTypeOfPlane(
    IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetWidthOfPlane(IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetHeightOfPlane(IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetHeightInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetWidthInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef surface,
                                            size_t plane);
size_t macws_IOSurfaceGetBytesPerTileDataOfPlane(IOSurfaceRef surface,
                                                 size_t plane);
size_t macws_IOSurfaceGetOffsetOfPlane(IOSurfaceRef surface, size_t plane);
void *macws_IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef surface,
                                           size_t plane);
uint32_t macws_IOSurfaceGetAddressFormatOfPlane(IOSurfaceRef surface,
                                                size_t plane);

// macws_make_mem_entry_xpc — ask iOS-native macwsallocd to allocate a
// CPU buffer + mach_make_memory_entry_64-wrap it, return entry port +
// mapped VA in our task. Used for type=0x80 standalone client-buffer
// path where iOS kernel rejects raw mmap'd CPU VAs (rejected even with
// pre-fault + mlock). Memory entry created by an iOS-native task with
// real task credentials passes the kernel's wire check.
//
// PoC verified 2026-06-19 via misc/test_mem_entry_xpc.c that mach
// memory entry mach ports DO cross XPC task boundaries (unlike
// io_connect_t which trips EXC_GUARD ILLEGAL_MOVE).
//
// Returns the mapped CPU VA in our task on success, 0 on failure.
// Caller writes this VA into args+0x30 before sel=0xa.
extern kern_return_t mach_vm_map(
    vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size,
    mach_vm_offset_t mask, int flags, mach_port_t object,
    memory_object_offset_t offset, boolean_t copy,
    vm_prot_t cur_protection, vm_prot_t max_protection,
    vm_inherit_t inheritance);

__attribute__((unused))
static uint64_t macws_make_mem_entry_xpc(uint64_t size, uint64_t *out_size) {
    static xpc_connection_t conn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) return;
        conn = createMach("com.macwsguide.alloc", NULL, 0);
        if (!conn) return;
        xpc_connection_set_event_handler(conn, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(conn);
    });
    if (!conn) return 0;

    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "make-mem-entry");
    xpc_dictionary_set_uint64(req, "size", size);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        static int log_once = 0;
        if (!log_once++) fprintf(stderr, "#### mem-entry-xpc: no reply\n");
        return 0;
    }
    const char *result = xpc_dictionary_get_string(reply, "result");
    if (!result || strcmp(result, "ok") != 0) {
        static int log_once = 0;
        if (log_once++ < 4) fprintf(stderr,
            "#### mem-entry-xpc: result=%s\n", result ?: "(null)");
        return 0;
    }
    mach_port_t entry = xpc_dictionary_copy_mach_send(reply, "entry");
    uint64_t actual = xpc_dictionary_get_uint64(reply, "size");
    if (entry == MACH_PORT_NULL || actual == 0) return 0;

    // Map the entry into THIS task (chroot WS). The mapped VA is what
    // the kernel will see when we put it in args+0x30.
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_map(
        mach_task_self(), &addr, (mach_vm_size_t)actual, 0,
        0x1 /* VM_FLAGS_ANYWHERE */, entry, 0, FALSE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE,
        VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), entry);
    if (kr != KERN_SUCCESS) {
        static int log_once = 0;
        if (log_once++ < 4) fprintf(stderr,
            "#### mem-entry-xpc: mach_vm_map kr=%#x\n", kr);
        return 0;
    }
    static int log_once = 0;
    if (log_once++ < 6) {
        fprintf(stderr,
            "#### mem-entry-xpc: req=%#llx → addr=%#llx size=%#llx (mapped from helper)\n",
            (unsigned long long)size, (unsigned long long)addr,
            (unsigned long long)actual);
    }
    if (out_size) *out_size = actual;
    return (uint64_t)addr;
}

extern au_asid_t audit_token_to_asid(audit_token_t atoken);
extern uid_t audit_token_to_auid(audit_token_t atoken);

// #define FORCE_SW_RENDER 1
BOOL hooked_return_1(void) { return YES; }
void EnableJIT(void);

// FORCE_M1_DRIVER: route Metal through the REAL macOS AGX (M1/G13G) GPU driver
// instead of the MTLSimDriver simulator bridge. Auto-enabled for both arm64e
// (Terminal, etc. — AGX-direct is their only Metal path) and arm64 (WS).
//
// HISTORY: f37b55e enabled for arm64 too, 5e89f2b reverted on the
// (incorrect) assumption that the raw sel=0xa hit a working path. Disasm
// of iOS sDeviceMethods table shows sel=0xa = s_delete_resource. macOS
// WS's create-shaped args sent to that selector get rejected at the
// IOExternalMethod arg-count check (checkScalarInputCount=1 mismatch
// with macOS's 0). Translation `sel=0xa → 0x9` IS the right thing; what
// went wrong was the type=0 args layout for s_new_resource. Re-enabled.
#if defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

// offsets hardcoded for macOS 13.4
// IOMobileFramebuffer`kern_SwapEnd + 36
#define OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt 0x4400 + 0x24
// IOMobileFramebuffer`kern_SwapEnd + 0x30: expected
// `bl IOConnectCallStructMethod` callsite. We only READ this instruction to
// validate the hardcoded ABI before arming the coexistence SwapCancel
// translation; it must not be NOPed because SwapBegin's DCP object then has no
// matching present/cancel operation.
#define OFF_IOMobileFramebuffer_kern_SwapEnd_submit 0x4400 + 0x30
// SkyLight`WS::Displays::CAWSManager::CAWSManager() + 560
#define OFF_SkyLight_CAWSManager_register_abort 0x18013c
#if FORCE_SW_RENDER
// SkyLight`WSSystemCanCompositeWithMetal::once
// #define OFF_SkyLight_WSSystemCanCompositeWithMetal 0x1d72b148
#define OFF_SkyLight_WSSystemCanCompositeWithMetal 0x53ae9028
#endif
// Metal`MTLFragmentReflectionReader::deserialize + 364
#define OFF_Metal_MTLFragmentReflectionReader_deserialize_extra 0x90ebc + 0x16c
// Metal`MTLInputStageReflectionReader::deserialize + 956
#define OFF_Metal_MTLInputStageReflectionReader_deserialize_extra 0x90678 + 0x3bc
// QuartzCore`CABackingStorePrepareUpdates_ + 812.  At this site the original
// `cbz w21, +852` sends every window backing store down the NON-accelerated path
// (w21==0 because the format/capability arg w23==2 has bit 8 clear): it allocates a
// CPU `CA::Render::Shmem::new_bitmap` instead of an IOSurface, so drawn content never
// becomes a GPU surface WindowServer can composite -> window CONTENT stays BLACK
// (chrome renders via a different path).  Forcing this branch to `b +840` takes the
// accelerated path (`mov w8,#1; str w8,[sp,#0x68]`), so create_iosurface() runs and an
// IOSurface-backed buffer is allocated -> content renders.  Verified live with lldb:
// patching this single instruction makes create_iosurface + IOSurfaceCreate fire.
#define OFF_QuartzCore_CABackingStore_force_accel 0x227cc

const char *IOMFBPath = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/Versions/A/IOMobileFramebuffer";
const char *MetalPath = "/System/Library/Frameworks/Metal.framework/Versions/A/Metal";
const char *SkyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
const char *QuartzCorePath = "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore";
const char *libxpcPath = "/usr/lib/system/libxpc.dylib";
const char *AGXMetalPath = "/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3";

// Private malloc zone for synth-buffer scratch (ivar+0x30) — Mempool freelist
// target. AGX driver writes its own sentinels (e.g. 0x1) into this buffer for
// its internal freelist tracking. When the synth AGXG13GFamilyBuffer is
// dealloc'd, free() routes the pointer to its zone. With this private zone,
// the corruption stays here — nothing else allocates from this zone, so
// tiny_malloc_from_free_list iterations in the DEFAULT zone never touch it.
// Without this isolation, AGX driver's `0x1` writes poison the default-zone
// free list and crash WS at the next NSString/CF object allocation.
static malloc_zone_t *macws_synth_scratch_zone(void) {
    static malloc_zone_t *zone = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zone = malloc_create_zone(0, 0);
        if (zone) malloc_set_zone_name(zone, "macws_synth_scratch");
        fprintf(stderr,
            "#### CODEHEAP-SHIM private scratch zone created: %p name=%s\n",
            zone, zone ? malloc_get_zone_name(zone) : "(nil)");
    });
    return zone;
}

// True if a process named `name` is currently running anywhere on the system.
// chroot shares the kernel proc table, so iOS-context processes (e.g.
// backboardd) are visible. Used to auto-detect coexistence mode: when iOS's
// backboardd is alive we share the device with iOS UI so WindowServer must
// not scan out to the panel. Cherry-picked from commit 0bba4a6 on stale
// branch feat/window-content-rendering.
static BOOL is_process_running(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    len += len / 8 + 0x4000;  // pad: proc table can grow between size + fetch
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t n = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
                found = YES;
                break;
            }
        }
    }
    free(procs);
    return found;
}

// ─── Chained-fixups walker for chroot-loaded AGXMetal13_3 ──────────────────
//
// In chroot, AGXMetal13_3.bundle is loaded from disk via dlopen, not from
// dyld_shared_cache. iOS dyld processes LC_DYLD_CHAINED_FIXUPS at image-load
// time. Cross-image bindings (especially to IOGPU.framework) fail silently
// when IOGPU isn't yet loaded → all 97 __got slots stay NULL → AGX::Mempool
// ::grow's lambda crashes on the null function pointers.
//
// This walker re-parses the chained-fixups load command and patches each null
// import bind by resolving the symbol via dlsym(RTLD_DEFAULT, name). The
// arm64e auth variants are PAC-signed with the embedded key + diversifier.

#include <mach-o/fixup-chains.h>

static inline uint64_t macws_ptr_blend(uint64_t addr, uint16_t div) {
    return (addr & 0x0000FFFFFFFFFFFFull) | ((uint64_t)div << 48);
}

#if __arm64e__
static inline uint64_t macws_pac_sign(uint64_t ptr, uint64_t mod, uint8_t key) {
    uint64_t r = ptr;
    switch (key) {
        case 0: asm("pacia %0, %1" : "+r"(r) : "r"(mod)); break;
        case 1: asm("pacib %0, %1" : "+r"(r) : "r"(mod)); break;
        case 2: asm("pacda %0, %1" : "+r"(r) : "r"(mod)); break;
        case 3: asm("pacdb %0, %1" : "+r"(r) : "r"(mod)); break;
    }
    return r;
}
#else
static inline uint64_t macws_pac_sign(uint64_t ptr, uint64_t mod, uint8_t key) {
    return ptr;  // no PAC on plain arm64
}
#endif

#include <mach-o/nlist.h>
#include <mach-o/reloc.h>

// Repair __got / __auth_got slots via indirect symbol table + LC_SYMTAB. Used
// for dlopen'd DSC-bound images that have no LC_DYLD_CHAINED_FIXUPS (because
// the cache builder removed it; cache pre-filled __got at cache-prep time).
// When loaded standalone, the pre-fill is gone — but the indirect symbol
// table still references LC_SYMTAB entries that name each slot's target.
static void macws_repair_got_via_symtab(const struct mach_header_64 *header,
                                        intptr_t slide,
                                        const char *image_name) {
    const struct symtab_command   *st = NULL;
    const struct dysymtab_command *dt = NULL;
    uint64_t linkedit_vmaddr = 0, linkedit_fileoff = 0;
    const struct segment_command_64 *segs[16] = {0};
    int seg_count = 0;

    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        switch (cmd->cmd) {
            case LC_SYMTAB:   st = (const struct symtab_command *)cmd; break;
            case LC_DYSYMTAB: dt = (const struct dysymtab_command *)cmd; break;
            case LC_SEGMENT_64: {
                const struct segment_command_64 *sc = (const struct segment_command_64 *)cmd;
                if (strcmp(sc->segname, "__LINKEDIT") == 0) {
                    linkedit_vmaddr  = sc->vmaddr;
                    linkedit_fileoff = sc->fileoff;
                }
                if (seg_count < 16) segs[seg_count++] = sc;
                break;
            }
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    if (!st || !dt || !linkedit_vmaddr) {
        fprintf(stderr, "#### MACWS_GOT %s: missing LC_SYMTAB/LC_DYSYMTAB/LC_SEGMENT\n", image_name);
        return;
    }
    int64_t linkedit_runtime_base = (int64_t)linkedit_vmaddr + slide - (int64_t)linkedit_fileoff;
    const struct nlist_64 *symtab    = (const struct nlist_64 *)(linkedit_runtime_base + st->symoff);
    const char            *strtab    = (const char           *)(linkedit_runtime_base + st->stroff);
    const uint32_t        *indirect  = (const uint32_t        *)(linkedit_runtime_base + dt->indirectsymoff);

    fprintf(stderr, "#### MACWS_GOT %s: symtab=%u syms, strtab=%u bytes, indirect=%u entries\n",
        image_name, st->nsyms, st->strsize, dt->nindirectsyms);

    int total_indirect_slots = 0, patched = 0, failed = 0;
    for (int s = 0; s < seg_count; s++) {
        const struct segment_command_64 *sc = segs[s];
        const struct section_64 *sect =
            (const struct section_64 *)((const uint8_t *)sc + sizeof(*sc));
        for (uint32_t k = 0; k < sc->nsects; k++) {
            const struct section_64 *sn = &sect[k];
            uint32_t type = sn->flags & SECTION_TYPE;
            // We want pointer-table sections that index into the indirect
            // symbol table. Per Mach-O spec, these are:
            //   S_NON_LAZY_SYMBOL_POINTERS (__got, __auth_got pointers)
            //   S_LAZY_SYMBOL_POINTERS     (__la_symbol_ptr — old style)
            //   S_SYMBOL_STUBS             (__stubs / __auth_stubs)
            // Match by sectname — DSC strips section type bits but preserves
            // the section NAME and reserved1 (indirect symbol table start).
            // Also accept ANY section in __DATA_CONST/__AUTH_CONST whose
            // reserved1 is non-zero AND whose name suggests pointer table
            // (`got`, `ptr`, `symbol`). Catches:
            //   __DATA_CONST,__got           (no-auth GOT)
            //   __AUTH_CONST,__auth_got      (PAC-auth GOT)
            //   __DATA,__la_symbol_ptr       (lazy stubs)
            //   __DATA,__nl_symbol_ptr       (non-lazy pointers)
            //   __DATA_CONST,__symbol_ptrs   (some images)
            //   __AUTH_CONST,__auth_ptr      (when reserved1 set)
            BOOL is_pointer_section = (strstr(sn->sectname, "got") != NULL ||
                                       strstr(sn->sectname, "ptr") != NULL ||
                                       strstr(sn->sectname, "symbol") != NULL);
            if (!is_pointer_section) continue;
            if (sn->reserved1 == 0) continue;
            uint32_t entries = (uint32_t)(sn->size / 8);
            uint32_t indirect_start = sn->reserved1;
            BOOL is_auth = (strstr(sn->sectname, "auth") != NULL);
            uint64_t *slots = (uint64_t *)(sn->addr + slide);
            fprintf(stderr, "####   sect[%u] %s,%s type=%u entries=%u indirect_start=%u auth=%d\n",
                k, sc->segname, sn->sectname, type, entries, indirect_start, is_auth);
            for (uint32_t e = 0; e < entries; e++) {
                if (indirect_start + e >= dt->nindirectsyms) break;
                total_indirect_slots++;
                uint32_t idx = indirect[indirect_start + e];
                if (idx == INDIRECT_SYMBOL_LOCAL ||
                    idx == INDIRECT_SYMBOL_ABS ||
                    idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
                    continue;
                }
                if (idx >= st->nsyms) {
                    failed++;
                    continue;
                }
                const struct nlist_64 *sym = &symtab[idx];
                const char *name = strtab + sym->n_un.n_strx;
                if (!name || !name[0]) { failed++; continue; }
                // Skip leading underscore for dlsym
                const char *lookup = name;
                if (lookup[0] == '_') lookup++;
                void *resolved = dlsym(RTLD_DEFAULT, lookup);
                if (!resolved) {
                    failed++;
                    if (failed < 6) {
                        fprintf(stderr, "####   bind FAIL %s\n", name);
                    }
                    continue;
                }
                // Force-redirect objc_alloc to our tracer regardless of current
                // slot value. The lambda in AGX::Mempool::grow calls objc_alloc
                // through this slot; we need to log its result and provide a
                // class_createInstance fallback when libobjc returns nil for an
                // under-realized AGX class.
                int force_override = 0;
                extern id objc_alloc_trace(Class);
                if (!strcmp(lookup, "objc_alloc")) {
                    resolved = (void *)objc_alloc_trace;
                    force_override = 1;
                }
                // macOS 13.4 IOSurfaceClient's per-plane fields are four bytes
                // later than iOS 16.3's kernel-populated layout.
                // AGXMetal13_3 is a standalone cache image here, so its
                // already-populated GOT bypasses ordinary DYLD_INTERPOSE.
                // Force only the RE-confirmed imports onto property-backed ABI
                // compatibility wrappers below; these are semantic field
                // recoveries, not constant check bypasses.
                if (strstr(image_name, "AGXMetal13_3") &&
                    !strcmp(lookup,
                        "IOSurfaceGetCompressionTypeOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetCompressionTypeOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetHeightInCompressedTilesOfPlane")) {
                    resolved = (void *)
                        macws_IOSurfaceGetHeightInCompressedTilesOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetWidthInCompressedTilesOfPlane")) {
                    resolved = (void *)
                        macws_IOSurfaceGetWidthInCompressedTilesOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetBytesPerRowOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetBytesPerRowOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetBytesPerTileDataOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetBytesPerTileDataOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup, "IOSurfaceGetOffsetOfPlane")) {
                    resolved = (void *)macws_IOSurfaceGetOffsetOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                                   "IOSurfaceGetBaseAddressOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetBaseAddressOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetAddressFormatOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetAddressFormatOfPlane;
                    force_override = 1;
                }
                uint64_t value = (uint64_t)resolved;
                // For __auth_got we'd need PAC signing — but without chained
                // fixup metadata we don't know diversifier/key. For non-auth
                // __got (which is what the diagnostic showed as 97 nulls), no
                // PAC needed.
                //
                // Most slot consumers expect a non-auth pointer for __got
                // and PAC-signed for __auth_got. If we patch __auth_got with
                // a raw pointer, the consuming code's autda/autia will fail
                // and trap. For now, skip __auth_got — we'll see how far we
                // get with __got alone.
                uint64_t *slot = &slots[e];
                uint64_t cur = *slot;
                // arm64e standard ABI for cross-image __auth_got slots:
                //   key=IA (0), addrDiv=1, diversity=0
                // The modifier becomes blend(slot_addr, 0) = slot_addr (low 48
                // bits). Consumer uses `ldraa x16, [slot]` which auths with
                // this exact modifier, then branches.
                if (is_auth) {
                    if (getenv("MACWS_GOT_SKIP_AUTH")) continue;
                    if (!getenv("MACWS_GOT_RAW_AUTH")) {
                        uint64_t mod = (uint64_t)slot & 0xFFFFFFFFFFFFull;
                        value = macws_pac_sign(value, mod, 0);  // key=IA
                    }
                }
                if (cur == 0 || force_override) {
                    ModifyExecutableRegion(slot, sizeof(uint64_t), ^{
                        *slot = value;
                    });
                    patched++;
                    if (patched < 12 || force_override) {
                        fprintf(stderr, "####   bind[%d] %s -> %p (slot=%p auth=%d%s)\n",
                            patched, name, resolved, slot, is_auth,
                            force_override ? " FORCE" : "");
                    }
                    // Dump IOGPU-related symbols specifically — these are the
                    // pool allocator helpers we need to know about.
                    if (strstr(name, "IOGPU") || strstr(name, "iogpu") ||
                        strstr(name, "MetalCommon") || strstr(name, "PoolAlloc") ||
                        strstr(name, "Pool") || strstr(name, "Heap")) {
                        fprintf(stderr, "####   IOGPU-CRITICAL %s = %p (slot=%p auth=%d)\n",
                            name, resolved, slot, is_auth);
                    }
                }
            }
        }
    }
    fprintf(stderr, "#### MACWS_GOT %s: indirect_slots=%d patched=%d failed=%d\n",
        image_name, total_indirect_slots, patched, failed);
}

static void macws_walk_chained_fixups(const struct mach_header_64 *header,
                                      intptr_t slide,
                                      const char *image_name) {
    // 1) Find LC_DYLD_CHAINED_FIXUPS load command and __LINKEDIT segment base
    const struct linkedit_data_command *fixups_cmd = NULL;
    uint64_t linkedit_vmaddr = 0;
    uint64_t linkedit_fileoff = 0;
    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_DYLD_CHAINED_FIXUPS) {
            fixups_cmd = (const struct linkedit_data_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cmd;
            if (strcmp(sc->segname, "__LINKEDIT") == 0) {
                linkedit_vmaddr  = sc->vmaddr;
                linkedit_fileoff = sc->fileoff;
            }
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    if (!fixups_cmd) {
        // No LC_DYLD_CHAINED_FIXUPS — the binary was loaded from
        // dyld_shared_cache, whose builder strips fixup info and pre-fills
        // the __got. When dlopen'd standalone, __got entries stay null.
        // Fall back to: walk indirect symbol table + LC_SYMTAB to recover
        // symbol names for each __got slot, dlsym, write back.
        macws_repair_got_via_symtab(header, slide, image_name);
        return;
    }
    if (!linkedit_vmaddr) {
        fprintf(stderr, "#### MACWS_FIXUP %s: no __LINKEDIT segment\n", image_name);
        return;
    }
    // dataoff is a FILE offset within __LINKEDIT; runtime addr = linkedit
    // vmaddr + slide + (dataoff - linkedit_fileoff).
    const uint8_t *fixups = (const uint8_t *)(linkedit_vmaddr + slide +
                                               ((int64_t)fixups_cmd->dataoff - (int64_t)linkedit_fileoff));
    const struct dyld_chained_fixups_header *fh =
        (const struct dyld_chained_fixups_header *)fixups;
    fprintf(stderr, "#### MACWS_FIXUP %s: header v=%u imports=%u fmt=%u sym_fmt=%u\n",
        image_name, fh->fixups_version, fh->imports_count,
        fh->imports_format, fh->symbols_format);

    const char *symbols = (const char *)(fixups + fh->symbols_offset);

    // Helper: resolve symbol name for an import index, given imports format.
    const void *imports_base = fixups + fh->imports_offset;
    __attribute__((unused))
    typedef const char *(*import_name_t)(const void *imports_base, uint32_t idx);
    const char *(^get_import_name)(uint32_t) = ^const char *(uint32_t idx) {
        switch (fh->imports_format) {
            case DYLD_CHAINED_IMPORT: {
                const struct dyld_chained_import *imp =
                    (const struct dyld_chained_import *)imports_base;
                return symbols + imp[idx].name_offset;
            }
            case DYLD_CHAINED_IMPORT_ADDEND: {
                const struct dyld_chained_import_addend *imp =
                    (const struct dyld_chained_import_addend *)imports_base;
                return symbols + imp[idx].name_offset;
            }
            case DYLD_CHAINED_IMPORT_ADDEND64: {
                const struct dyld_chained_import_addend64 *imp =
                    (const struct dyld_chained_import_addend64 *)imports_base;
                return symbols + imp[idx].name_offset;
            }
        }
        return "<unknown_format>";
    };

    // 2) Walk starts_in_image → starts_in_segment → chains
    const struct dyld_chained_starts_in_image *starts =
        (const struct dyld_chained_starts_in_image *)(fixups + fh->starts_offset);

    int total_binds = 0, patched_binds = 0, failed_binds = 0;
    int auth_binds = 0, non_auth_binds = 0;
    for (uint32_t s = 0; s < starts->seg_count; s++) {
        uint32_t seg_off = starts->seg_info_offset[s];
        if (!seg_off) continue;
        const struct dyld_chained_starts_in_segment *seg =
            (const struct dyld_chained_starts_in_segment *)((const uint8_t *)starts + seg_off);
        if (seg->pointer_format != DYLD_CHAINED_PTR_ARM64E &&
            seg->pointer_format != DYLD_CHAINED_PTR_ARM64E_USERLAND &&
            seg->pointer_format != DYLD_CHAINED_PTR_ARM64E_USERLAND24 &&
            seg->pointer_format != DYLD_CHAINED_PTR_64 &&
            seg->pointer_format != DYLD_CHAINED_PTR_64_OFFSET) {
            fprintf(stderr, "#### MACWS_FIXUP seg[%u] unsupported pointer_format=%u\n",
                s, seg->pointer_format);
            continue;
        }
        for (uint16_t p = 0; p < seg->page_count; p++) {
            uint16_t page_start = seg->page_start[p];
            if (page_start == DYLD_CHAINED_PTR_START_NONE) continue;
            uint64_t page_va = (uint64_t)header + seg->segment_offset + (uint64_t)p * seg->page_size;
            uint64_t chain_va = page_va + page_start;
            for (;;) {
                uint64_t *slot = (uint64_t *)chain_va;
                uint64_t raw = *slot;
                int is_bind = 0, is_auth = 0;
                uint32_t ordinal = 0;
                uint16_t diversity = 0;
                uint8_t key = 0;
                uint8_t addrDiv = 0;
                uint32_t next = 0;

                if (seg->pointer_format == DYLD_CHAINED_PTR_ARM64E ||
                    seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND ||
                    seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND24) {
                    is_bind = (raw >> 62) & 1;
                    is_auth = (raw >> 63) & 1;
                    if (seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND24 && is_bind) {
                        ordinal = raw & 0xFFFFFF;
                        next = (raw >> 51) & 0x7FF;
                    } else if (is_bind) {
                        ordinal = raw & 0xFFFF;
                        next = (raw >> 51) & 0x7FF;
                    } else {
                        next = (raw >> 51) & 0x7FF;
                    }
                    if (is_auth && is_bind) {
                        diversity = (raw >> 32) & 0xFFFF;
                        addrDiv = (raw >> 48) & 1;
                        key = (raw >> 49) & 3;
                    } else if (is_auth) {
                        diversity = (raw >> 32) & 0xFFFF;
                        addrDiv = (raw >> 48) & 1;
                        key = (raw >> 49) & 3;
                    }
                } else { // DYLD_CHAINED_PTR_64 / _64_OFFSET
                    is_bind = (raw >> 63) & 1;
                    next = (raw >> 51) & 0xFFF;
                    if (is_bind) {
                        ordinal = raw & 0xFFFFFF;
                    }
                }

                if (is_bind) {
                    total_binds++;
                    if (is_auth) auth_binds++; else non_auth_binds++;
                    if (ordinal < fh->imports_count) {
                        const char *name = get_import_name(ordinal);
                        if (name && name[0]) {
                            // dlsym wants the name without the leading underscore.
                            const char *lookup = name;
                            if (lookup[0] == '_') lookup++;
                            void *resolved = dlsym(RTLD_DEFAULT, lookup);
                            if (resolved) {
                                uint64_t value = (uint64_t)resolved;
                                if (is_auth) {
                                    uint64_t mod = addrDiv
                                        ? macws_ptr_blend((uint64_t)slot, diversity)
                                        : (uint64_t)diversity;
                                    value = macws_pac_sign(value, mod, key);
                                }
                                ModifyExecutableRegion(slot, sizeof(uint64_t), ^{
                                    *slot = value;
                                });
                                patched_binds++;
                                if (patched_binds < 6) {
                                    fprintf(stderr,
                                        "####   bind[%d] %s -> %p (auth=%d key=%d div=%#x addrDiv=%d)\n",
                                        patched_binds, name, resolved, is_auth, key,
                                        diversity, addrDiv);
                                }
                            } else {
                                failed_binds++;
                                if (failed_binds < 6) {
                                    fprintf(stderr,
                                        "####   bind FAIL %s — dlsym NULL\n", name);
                                }
                            }
                        }
                    }
                }

                if (next == 0) break;
                uint32_t stride = (seg->pointer_format == DYLD_CHAINED_PTR_64 ||
                                   seg->pointer_format == DYLD_CHAINED_PTR_64_OFFSET) ? 4 : 8;
                chain_va += (uint64_t)next * stride;
            }
        }
    }
    fprintf(stderr, "#### MACWS_FIXUP %s: walked binds=%d (auth=%d non-auth=%d) patched=%d failed=%d\n",
        image_name, total_binds, auth_binds, non_auth_binds, patched_binds, failed_binds);
}

// SkyLight `MetalIOSurfaceBacking::PrepareForUse(MetalContext*, unsigned long
// long)` tolerate-nil hook. See loadImageCallback for full rationale.
typedef int (*PrepareForUse_t)(void *self, void *ctx, unsigned long long arg);
static PrepareForUse_t orig_skylight_prepare_for_use = NULL;
static int hooked_skylight_prepare_for_use(void *self, void *ctx,
                                           unsigned long long arg) {
    if (ctx) {
        // MetalContext+0x1c0 is a single-byte "tolerate-nil-texture" flag
        // (ldrb w8 at the abort-decision site). SkyLight returns 0 from
        // PrepareForUse silently when the flag is set; aborts when it's 0.
        *((volatile uint8_t *)ctx + 0x1c0) = 1;
    }
    return orig_skylight_prepare_for_use(self, ctx, arg);
}

// SkyLight `MetalContext::StartCompositeForDisplayStream(id<MTLTexture>,
// id<MTLTexture>, MTLLoadAction, MTLStoreAction)` — asserts target_attachment_0
// != nil at MetalContext.mm:627. When the CA Framebuffer texture cascade from
// PrepareForUse leaves the display-stream target as nil, this asserts. Hook to
// early-return 0 (skip this composite frame) instead of aborting.
typedef int (*StartCompositeForDisplayStream_t)(void *self, id target0, id target1,
                                                 unsigned long load_action,
                                                 unsigned long store_action);
static StartCompositeForDisplayStream_t orig_skylight_start_composite_ds = NULL;
static int hooked_skylight_start_composite_ds(void *self, id target0, id target1,
                                              unsigned long load_action,
                                              unsigned long store_action) {
    if (!target0) {
        static int skipped = 0;
        if (skipped < 3) {
            fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream: target0=nil, skip\n");
            skipped++;
        }
        return 0;
    }
    int rv = orig_skylight_start_composite_ds(self, target0, target1, load_action, store_action);
    if (rv != 0) {
        extern void macws_vnc_stage_composite(void *, id);
        macws_vnc_stage_composite(self, target0);
    }
    return rv;
}

// SkyLight `MetalContext::StartComposite(WSCompositeDestination*,
// MTLLoadAction, MTLStoreAction)` at static 0x18522d358. Disasm
// (otool of SkyLight) confirms two assert sites inside this function:
//   line 589 — `state._target[0] && "Failed to obtain..."` (destination)
//   line 918 — `state->_target[1] && "Failed to add memoryless..."`
// Both protected by a tolerate-nil flag at MetalContext+0x1c0. The
// existing PrepareForUse-tolerate-nil sets the flag for IOSurface
// backing path, but THIS variant runs from CompositorMetal::composite
// with a different MetalContext. Hook to set the flag on the actual
// ctx (x0=self) being composited.
//
// 2026-06-20 — added pop-on-bail invariant restorer (see comments above
// `orig_skylight_state_stack_pop_back` below).
typedef int (*StartComposite_WSCD_t)(void *self, void *dest,
                                      unsigned long load_action,
                                      unsigned long store_action);
void *orig_skylight_start_composite_wscd_ref = NULL;
// SkyLight `MetalContext::StartComposite(MTLTexture*, MTLLoadAction,
// MTLStoreAction)` — texture variant, called from `SLCADisplay::
// render_update` (the path that drives the assert in MetalContext.mm:411).
//
// SAME pop-on-bail invariant restorer as the WSCD variant.
typedef int (*StartComposite_MTLTex_t)(void *self, id texture,
                                       unsigned long load_action,
                                       unsigned long store_action);
static StartComposite_MTLTex_t orig_skylight_start_composite_mtltex = NULL;

// SkyLight `std::deque<RenderState>::pop_back()` symbol at static 0x186637f84.
// `_state_stack` is the std::deque<RenderState> embedded as the FIRST member
// of MetalContext, so passing `MetalContext*` to pop_back is correct (same
// pointer the C++ symbol expects). MUST be resolved at runtime — the chroot
// SkyLight UUID differs from our static-analysis copy.
typedef void (*StateStack_pop_back_t)(void *deque);
static StateStack_pop_back_t orig_skylight_state_stack_pop_back = NULL;

// LEAK INVARIANT RESTORER — runs after MetalContext::StartComposite returns
// 0 (bail).
//
// Root cause RE'd 2026-06-20:
//   - MetalContext::StartComposite (BOTH the WSCD and MTLTex variants)
//     calls `_state_stack.emplace_back()` UNCONDITIONALLY at +0x12c, BEFORE
//     any inner resource allocation. The push grows [self+0x28] by 1.
//   - When the inner alloc fails (e.g. resolve-tex `_makeTextureFromSurface`
//     returns NULL on chroot because AGXIOC sel=0xa→0x9 ResCreate rejects
//     kIOReturnNoBandwidth), StartComposite returns 0 — WITHOUT popping the
//     just-pushed state.
//   - `SLCADisplay::render_update`'s SITE 2/3 cleanup paths
//     (render_update +0x16c8/+0x1738) handle `Start == 0` by jumping
//     STRAIGHT to `EndUpdate(_, 0, 0)` and SKIPPING the matching
//     `EndCurrentComposite`. They assume Apple's contract: rv==0 means no
//     push happened.
//   - On real Apple hardware the only `rv==0` path is P1 (degenerate rect,
//     checked BEFORE push), so the invariant holds. On our chroot the
//     post-push L3 path is the common case, so the invariant breaks — push
//     leaks, deque grows by one per failed composite, and the next frame's
//     `EndUpdate` trips `__assert_rtn(_state_stack.empty())` at
//     MetalContext.mm:411.
//
// Fix: at hook exit, if `%orig` returned 0 AND the deque size
// (`*((u64*)(self+0x28))`) is HIGHER than before %orig, call the deque's
// `pop_back` directly. That restores the invariant Apple's render_update
// is built on. NOT a NOP/return-bypass; the legitimate inverse of the push
// that StartComposite did.
// Compute the address of the last slot in the std::deque<RenderState> embedded
// in MetalContext. Mirrors the deque math at emplace_back +0x130-+0x170 and
// pop_back +0x14-+0x54 disassembly. Returns NULL on shape inconsistency.
//
// Layout:
//   deque+0x00: map_first    (allocation start)
//   deque+0x08: block_start  (pointer-to-pointer at start of in-use buckets)
//   deque+0x10: block_end    (pointer-to-pointer one past last in-use)
//   deque+0x18: map_last     (allocation end)
//   deque+0x20: start_offset (element index of first element from block 0)
//   deque+0x28: size         (element count)
//
// idx = start_offset + size - 1
// block_idx = idx / 23
// slot = block_start[block_idx] + (idx % 23) * 0xb0
static void *macws_deque_slot_ptr(void *self, uint64_t idx) {
    if (!self) return NULL;
    uintptr_t d = (uintptr_t)self;
    void **bucket = *(void ***)(d + 8);
    if (!bucket) return NULL;
    uint64_t block_idx = idx / 23;
    uint8_t *block = (uint8_t *)bucket[block_idx];
    if (!block || (uintptr_t)block < 0x1000) return NULL;
    return block + (idx % 23) * 0xb0;
}

static int macws_pop_on_startcomp_bail(void *self, uint64_t before, int rv) {
    if (rv != 0) return rv;
    if (!self || (uintptr_t)self < 0x1000) return rv;
    if (!orig_skylight_state_stack_pop_back) return rv;
    uint64_t after = *(volatile uint64_t *)((char *)self + 0x28);
    if (after <= before) return rv;
    // pop until we're back to the pre-call size. In practice that's a single
    // pop because StartComposite only pushes once, but a `while` guards us
    // against the (theoretical) case where it pushed twice before bailing.
    static _Atomic int leaks_observed = 0;
    int n = atomic_fetch_add(&leaks_observed, 1);
    if (n < 16) {
        dprintf(STDERR_FILENO,
            "#### SS BAIL-POP self=%p before=%llu after=%llu rv=%d (#%d)\n",
            self, (unsigned long long)before, (unsigned long long)after, rv, n);
    }
    while (after > before) {
        // Zero the just-pushed slot BEFORE pop_back's destructor runs.
        // RenderState::~RenderState (0x186637c0c) calls objc_release on
        // [slot+8], [slot+0x10], [slot+0x18], [slot+0x20] and another
        // cleanup on [slot+0x00]. After StartComposite L3 bailed, those
        // fields hold either: nil (for never-written), retained but
        // dangling refs (for L3 partial), or uninitialised stack-leftover.
        // Zero them — objc_release(nil) is a documented safe no-op, and
        // the [slot+0x00] cleanup is similarly nil-safe per the AppKit
        // convention. The OBJECTS the slot referenced are NOT released;
        // their owning code (CA backend) holds independent retains. We
        // skip releasing the slot's copies — equivalent to a one-frame
        // ObjC retain "leak" worth ≤4 refs per failed composite. The
        // alternative (allowing the destructor to chase the dangling
        // refs) was empirically SIGSEGV'ing on the first BAIL-POP fire.
        uint64_t start = *(volatile uint64_t *)((char *)self + 0x20);
        uint64_t cur_size = *(volatile uint64_t *)((char *)self + 0x28);
        if (cur_size == 0) break;
        void *slot = macws_deque_slot_ptr(self, start + cur_size - 1);
        if (slot) memset(slot, 0, 0xb0);
        orig_skylight_state_stack_pop_back(self);
        uint64_t new_after = *(volatile uint64_t *)((char *)self + 0x28);
        if (new_after >= after) break;  // safety: pop didn't shrink → stop
        after = new_after;
    }
    return rv;
}

int hooked_skylight_start_composite_wscd(void *self, void *dest,
                                          unsigned long load_action,
                                          unsigned long store_action) {
    if (self) {
        *((volatile uint8_t *)self + 0x1c0) = 1;
    }
    uint64_t before = (self && (uintptr_t)self >= 0x1000)
        ? *(volatile uint64_t *)((char *)self + 0x28) : 0;
    int rv = ((StartComposite_WSCD_t)orig_skylight_start_composite_wscd_ref)(
        self, dest, load_action, store_action);
    // Map only a successful StartComposite.  EndCurrentComposite performs
    // the matching pop and selects the destination after endEncoding.
    if (rv != 0) {
        extern NSMutableDictionary *g_wscd_tex;
        if (g_wscd_tex && dest) {
            id tex = nil;
            NSValue *key = [NSValue valueWithPointer:dest];
            @synchronized(g_wscd_tex) {
                tex = g_wscd_tex[key];
            }
            if (tex) {
                extern void macws_vnc_stage_composite(void *, id);
                macws_vnc_stage_composite(self, tex);

                // g_wscd_tex is only the hand-off from
                // WSCompositeDestinationCreateWithMetalTexture to the first
                // successful StartComposite.  The composite stack now owns
                // the texture for the matching EndCurrentComposite, so
                // retaining it in both places indefinitely leaks one pf550
                // AGX resource for nearly every display update.  Remove only
                // the exact value we consumed; an unsuccessful StartComposite
                // leaves its mapping available for a legitimate retry.
                NSUInteger before = 0, after = 0;
                BOOL consumed = NO;
                @synchronized(g_wscd_tex) {
                    before = g_wscd_tex.count;
                    if (g_wscd_tex[key] == tex) {
                        [g_wscd_tex removeObjectForKey:key];
                        consumed = YES;
                    }
                    after = g_wscd_tex.count;
                }
                if (consumed) {
                    static _Atomic unsigned long consume_count = 0;
                    unsigned long n =
                        atomic_fetch_add(&consume_count, 1) + 1;
                    if (n <= 24 || (n % 600) == 0) {
                        fprintf(stderr,
                            "#### WSCD-MAP consume #%lu dest=%p tex=%p "
                            "count=%lu->%lu\n",
                            n, dest, (void *)tex,
                            (unsigned long)before, (unsigned long)after);
                    }
                }
            }
        }
    }
    return macws_pop_on_startcomp_bail(self, before, rv);
}

static int hooked_skylight_start_composite_mtltex(void *self, id texture,
                                                  unsigned long load_action,
                                                  unsigned long store_action) {
    if (self) {
        *((volatile uint8_t *)self + 0x1c0) = 1;
    }
    uint64_t before = (self && (uintptr_t)self >= 0x1000)
        ? *(volatile uint64_t *)((char *)self + 0x28) : 0;
    int rv = orig_skylight_start_composite_mtltex(
        self, texture, load_action, store_action);
    if (rv != 0) {
        extern void macws_vnc_stage_composite(void *, id);
        macws_vnc_stage_composite(self, texture);
    }
    return macws_pop_on_startcomp_bail(self, before, rv);
}

// RE-confirmed via device-local LLDB against the running macOS 13.4
// SkyLight image (2026-07-25): MetalContext::EndCurrentComposite(bool) calls
// -endEncoding at +0x80, StopEncoding at +0x94, then pops _state_stack at
// +0x98.  Completing the VNC selection after %orig therefore observes the
// destination at the real composite boundary rather than allocation time.
typedef void (*EndCurrentComposite_t)(void *self, bool synchronize);
static EndCurrentComposite_t orig_skylight_end_current_composite = NULL;
static void hooked_skylight_end_current_composite(void *self, bool synchronize) {
    orig_skylight_end_current_composite(self, synchronize);
    extern void macws_vnc_complete_composite(void *);
    macws_vnc_complete_composite(self);
}

// RE-confirmed via the same live SkyLight image: EndUpdate(bool) reaches
// MetalContext::Flush at +0x78 only when _update_depth (self+0x178) drops from
// one to zero.  Flush ends encoders, commits the command buffer, retains that
// submitted buffer at self+0x68, and clears self+0x60.  The VNC observer keeps
// one submitted pair per context and polls that buffer's status off the render
// thread; it does not wait, commit, or add a post-commit completion handler.
typedef void (*EndUpdate_t)(void *self, bool waitUntilSubmitted);
static EndUpdate_t orig_skylight_end_update = NULL;
static void hooked_skylight_end_update(void *self, bool waitUntilSubmitted) {
    bool outermost = self &&
        *(volatile int32_t *)((char *)self + 0x178) == 1;
    orig_skylight_end_update(self, waitUntilSubmitted);
    if (outermost) {
        extern void macws_vnc_finish_update(void *);
        macws_vnc_finish_update(self);
    }
}

// SkyLight `WSCompositeDestinationCreateWithMetalTexture(MTLTexture*, MetalContext*, ...)`
// — asserts texture != nil at CompositeDestinationMetal.mm:165. BN disasm
// (SkyLight at 0x18523053c):
//   - first instr after prologue: `cbz x1, +0x344` → device assert (line 160)
//   - then `cbnz x19, +0x10` (x19 = x0) skips OK path if texture is set
//   - `cbz x19, +0x2e4` → texture assert (line 165)
// So x0 IS THE TEXTURE, x1 is the device/MetalContext. Earlier hook had the
// argument order REVERSED and was checking the wrong slot for nil, which is
// why the hook never absorbed the nil — the texture argument carrying the
// nil sat at x0 while the hook tested x1.
typedef void *(*WSCompositeDestinationCreateWithMetalTexture_t)(
    id texture, void *ctx, void *protectionOptions, void *colorspace, void *region);
static WSCompositeDestinationCreateWithMetalTexture_t orig_skylight_wsccd_with_tex = NULL;
static void *hooked_skylight_wsccd_with_tex(id texture, void *ctx, void *protectionOptions,
                                            void *colorspace, void *region) {
    if (!texture) {
        static int nil_count = 0;
        if (nil_count < 4) {
            fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture: texture=nil, return NULL\n");
            nil_count++;
        }
        return NULL;
    }
    void *wscd = orig_skylight_wsccd_with_tex(texture, ctx, protectionOptions, colorspace, region);
    // One-shot hand-off from WSCompositeDestination to its MTLTexture.  The
    // successful StartComposite hook transfers this value into the matching
    // composite stack and removes the dictionary entry.  Keeping every value
    // here forever was runtime-correlated with the second, render_update-side
    // 0x13bc000-byte type-0x82 resource for each pf550 IOSurface.
    if (wscd && texture) {
        static NSMutableDictionary *m = nil; static dispatch_once_t o;
        dispatch_once(&o, ^{ m = [NSMutableDictionary new]; });
        extern NSMutableDictionary *g_wscd_tex; g_wscd_tex = m;
        NSUInteger count = 0;
        @synchronized(m) {
            m[[NSValue valueWithPointer:wscd]] = texture;
            count = m.count;
        }
        static _Atomic unsigned long insert_count = 0;
        unsigned long n = atomic_fetch_add(&insert_count, 1) + 1;
        if (n <= 24 || (n % 600) == 0) {
            fprintf(stderr,
                "#### WSCD-MAP insert #%lu dest=%p tex=%p count=%lu\n",
                n, wscd, (void *)texture, (unsigned long)count);
        }
    }
    return wscd;
}
NSMutableDictionary *g_wscd_tex = nil;  // one-shot WSCD ptr -> MTLTexture hand-off

// MetalContext::StopCapture() guard — see install_skylight_prepare_for_use_tolerate_nil_hook()
// for the call-site explanation.
typedef void (*MetalContext_StopCapture_t)(void *this);
static MetalContext_StopCapture_t orig_metalcontext_stop_capture = NULL;
static void hooked_metalcontext_stop_capture(void *this) {
    if ((uintptr_t)this < 0x1000) {
        static int bad_count = 0;
        if (bad_count < 4) {
            fprintf(stderr, "#### MetalContext::StopCapture: invalid this=%p, skipping\n", this);
            bad_count++;
        }
        return;
    }
    orig_metalcontext_stop_capture(this);
}

static void install_skylight_prepare_for_use_tolerate_nil_hook(const void *header) {
    MSImageRef sl = MSGetImageByName(SkyLightPath);
    if (!sl) {
        fprintf(stderr, "#### SkyLight tolerate-nil hooks: image not loadable, skipped\n");
        return;
    }
    void *sym1 = MSFindSymbol(sl,
        "__ZN21MetalIOSurfaceBacking13PrepareForUseEP12MetalContexty");
    if (sym1) {
        MSHookFunction(sym1, (void *)hooked_skylight_prepare_for_use,
                       (void **)&orig_skylight_prepare_for_use);
        fprintf(stderr, "#### SkyLight PrepareForUse tolerate-nil hook installed at %p\n", sym1);
    } else {
        fprintf(stderr, "#### SkyLight PrepareForUse: symbol not found, skipped\n");
    }
    void *sym2 = MSFindSymbol(sl,
        "__ZN12MetalContext30StartCompositeForDisplayStreamEPU21objcproto10MTLTexture11objc_objectS1_13MTLLoadAction14MTLStoreAction");
    if (sym2) {
        MSHookFunction(sym2, (void *)hooked_skylight_start_composite_ds,
                       (void **)&orig_skylight_start_composite_ds);
        fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream nil-skip hook installed at %p\n", sym2);
    } else {
        fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream: symbol not found, skipped\n");
    }
    // 2026-06-20 — MetalContext::StartComposite(WSCompositeDestination*,
    // MTLLoadAction, MTLStoreAction) — hook installed below. Helper
    // function definitions are at top-level (see above this function).
    extern void *orig_skylight_start_composite_wscd_ref;
    void *sym_sc_wscd = MSFindSymbol(sl,
        "__ZN12MetalContext14StartCompositeEP22WSCompositeDestination13MTLLoadAction14MTLStoreAction");
    if (sym_sc_wscd) {
        extern int hooked_skylight_start_composite_wscd(void *, void *,
                                                        unsigned long,
                                                        unsigned long);
        MSHookFunction(sym_sc_wscd,
            (void *)hooked_skylight_start_composite_wscd,
            (void **)&orig_skylight_start_composite_wscd_ref);
        fprintf(stderr,
            "#### SkyLight StartComposite(WSCD) tolerate-nil + pop-on-bail hook installed at %p\n",
            sym_sc_wscd);
    } else {
        fprintf(stderr,
            "#### SkyLight StartComposite(WSCD): symbol not found\n");
    }

    // 2026-06-20 — StartComposite(MTLTexture*, …) hook (the variant
    // called from SLCADisplay::render_update). Same pop-on-bail invariant
    // restorer logic as WSCD — when %orig returns 0 after pushing onto
    // _state_stack, restore the invariant the caller assumes (rv==0
    // ⟹ no push).
    void *sym_sc_mtltex = MSFindSymbol(sl,
        "__ZN12MetalContext14StartCompositeEPU21objcproto10MTLTexture"
        "11objc_object13MTLLoadAction14MTLStoreAction");
    if (sym_sc_mtltex) {
        MSHookFunction(sym_sc_mtltex,
            (void *)hooked_skylight_start_composite_mtltex,
            (void **)&orig_skylight_start_composite_mtltex);
        fprintf(stderr,
            "#### SkyLight StartComposite(MTLTex) pop-on-bail hook installed at %p\n",
            sym_sc_mtltex);
    } else {
        fprintf(stderr,
            "#### SkyLight StartComposite(MTLTex): symbol not found\n");
    }

    // This symbol is present in LLDB's shared-cache symbol table but stripped
    // from the export table used by MSFindSymbol.  Prefer the symbol when it
    // is available; otherwise accept the macOS 13.4 image-relative offset
    // only when the exact first 12 instruction words captured from the live
    // process match.  A different SkyLight build fails closed.
    void *sym_end_composite = MSFindSymbol(sl,
        "__ZN12MetalContext19EndCurrentCompositeEb");
    if (!sym_end_composite && header) {
        uint32_t *candidate = (uint32_t *)((uintptr_t)header + 0x14753c);
        static const uint32_t expected[] = {
            0xd503237f, 0xa9bd57f6, 0xa9014ff4, 0xa9027bfd,
            0x910083fd, 0xf9401408, 0xb4000b28, 0xaa0003f3,
            0x340002c1, 0xaa1303e0, 0x9400005d, 0xa9422269,
        };
        if (memcmp(candidate, expected, sizeof(expected)) == 0) {
            sym_end_composite = candidate;
            fprintf(stderr,
                "#### SkyLight EndCurrentComposite(bool) RE-verified fallback at %p\n",
                sym_end_composite);
        } else {
            fprintf(stderr,
                "#### SkyLight EndCurrentComposite(bool) fallback rejected: "
                "instruction signature mismatch at %p\n", candidate);
        }
    }
    if (sym_end_composite) {
        MSHookFunction(sym_end_composite,
            (void *)hooked_skylight_end_current_composite,
            (void **)&orig_skylight_end_current_composite);
        fprintf(stderr,
            "#### SkyLight EndCurrentComposite(bool) completion hook installed at %p\n",
            sym_end_composite);
    } else {
        fprintf(stderr,
            "#### SkyLight EndCurrentComposite(bool): symbol not found, skipped\n");
    }

    void *sym_end_update = MSFindSymbol(sl,
        "__ZN12MetalContext9EndUpdateEb");
    if (!sym_end_update && header) {
        uint32_t *candidate = (uint32_t *)((uintptr_t)header + 0x1470b0);
        static const uint32_t expected[] = {
            0xd503237f, 0xa9be4ff4, 0xa9017bfd, 0x910043fd,
            0xb9417808, 0x7100011f, 0x5400048d, 0xaa0003f3,
            0x71000508, 0xb9017808, 0x540003a1, 0xaa0103f4,
        };
        if (memcmp(candidate, expected, sizeof(expected)) == 0) {
            sym_end_update = candidate;
            fprintf(stderr,
                "#### SkyLight EndUpdate(bool) RE-verified fallback at %p\n",
                sym_end_update);
        } else {
            fprintf(stderr,
                "#### SkyLight EndUpdate(bool) fallback rejected: "
                "instruction signature mismatch at %p\n", candidate);
        }
    }
    if (sym_end_update) {
        MSHookFunction(sym_end_update,
            (void *)hooked_skylight_end_update,
            (void **)&orig_skylight_end_update);
        fprintf(stderr,
            "#### SkyLight EndUpdate(bool) submission hook installed at %p\n",
            sym_end_update);
    } else {
        fprintf(stderr,
            "#### SkyLight EndUpdate(bool): symbol not found, skipped\n");
    }

    // 2026-06-20 — _state_stack pop_back resolution. MetalContext starts
    // with std::deque<RenderState>, so passing MetalContext* == passing
    // deque*. Required by `macws_pop_on_startcomp_bail` above.
    void *sym_pop = MSFindSymbol(sl,
        "__ZNSt3__15dequeI11RenderStateNS_9allocatorIS1_EEE8pop_backEv");
    if (sym_pop) {
        orig_skylight_state_stack_pop_back = (StateStack_pop_back_t)sym_pop;
        fprintf(stderr,
            "#### SkyLight _state_stack pop_back resolved at %p\n", sym_pop);
    } else {
        fprintf(stderr,
            "#### SkyLight _state_stack pop_back: symbol not found — "
            "pop-on-bail will NO-OP, expect Unbalanced Composites asserts\n");
    }

    void *sym3 = MSFindSymbol(sl, "_WSCompositeDestinationCreateWithMetalTexture");
    if (sym3) {
        MSHookFunction(sym3, (void *)hooked_skylight_wsccd_with_tex,
                       (void **)&orig_skylight_wsccd_with_tex);
        fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture nil-tolerate hook installed at %p\n", sym3);
    } else {
        fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture: symbol not found, skipped\n");
    }

    // MetalContext::StopCapture() — called from render_update when the GPU
    // capture-in-progress flag is set. Under AGX-native the WS::Updater
    // sometimes invokes this with an invalid `this` (observed x0 = 0x95 on
    // the crashing thread), which then SEGVs on `ldr x0, [x0, #0xb8]` at
    // StopCapture+0x38. We don't actually want any GPU-capture work
    // happening during the AGX-native bring-up, so just no-op the call
    // when this looks invalid (< 0x1000 = unmapped low-address page).
    void *sym4 = MSFindSymbol(sl, "__ZN12MetalContext11StopCaptureEv");
    if (sym4) {
        MSHookFunction(sym4, (void *)hooked_metalcontext_stop_capture,
                       (void **)&orig_metalcontext_stop_capture);
        fprintf(stderr, "#### SkyLight MetalContext::StopCapture invalid-this guard installed at %p\n", sym4);
    } else {
        fprintf(stderr, "#### SkyLight MetalContext::StopCapture: symbol not found, skipped\n");
    }
}

void loadImageCallback(const struct mach_header* header, intptr_t vmaddr_slide) {
    Dl_info info;
    dladdr(header, &info);
    if(!strncmp(info.dli_fname, SkyLightPath, strlen(SkyLightPath))) {
        // allow coexist with backboardd in WS::Displays::CAWSManager::CAWSManager() + 560
        // if backboardd is running, WindowServer switches to offscreen rendering
        uint32_t *check = (uint32_t *)(OFF_SkyLight_CAWSManager_register_abort + (uintptr_t)header);
        ModifyExecutableRegion(check, sizeof(uint32_t), ^{
            // TODO: has hardcoded instruction
            // NSLog(@"#### debugbydcmmc OFF_SkyLight_CAWSManager_register_abort ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) check, (unsigned long) *check, (unsigned long) 0xb4000588);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching SkyLight version/arch.
            if (*check == 0xb4000588) { // cbz    x8, do_abort
                *check = 0xd503201f; // nop
            }
        });
        
        // grant all permissions
        MSHookFunction(MSFindSymbol((MSImageRef)header, "_audit_token_check_tcc_access"), hooked_return_1, NULL);
            
        // NSLog(@"#### debugbydcmmc loadImageCallback before OFF_SkyLight_WSSystemCanCompositeWithMetal");
#if FORCE_SW_RENDER
        // skip Metal check (WSSystemCanCompositeWithMetal::once)
        int64_t *once = (int64_t *)(OFF_SkyLight_WSSystemCanCompositeWithMetal + (uintptr_t)header);
        *once = -1;
#endif

        // (Removed LAZY CAWSBackend.mm assert-NOP scanner — empirically
        // never fired in post-MACWS_AGX_REGISTER_CLASSES runs and was
        // masking real CA backend invariants. See AGENTS.md "Patch
        // Discipline".)

        // Tolerate-nil texture in MetalIOSurfaceBacking::PrepareForUse
        //
        // RE'd via live lldb on WS PID 4218: PrepareForUse calls
        // [device newTextureWithDescriptor:iosurface:plane:] at +340. If the
        // result is nil (cbz at +352 → +484), the function loads a flag from
        // MetalContext+0x1c0 (ldrb w8 at +484), and if w8 == 0 calls
        // MetalBacking::AbortWithTextureInfo at +512 — killing WS.
        //
        // SkyLight already ships a "tolerate-nil" code path at +492 (mov w0,#0;
        // ret 0) that fires when MetalContext+0x1c0 is non-zero. The hook here
        // sets that byte to 1 before %orig, so SkyLight's own fallback runs
        // instead of the abort. No instruction patching, no NOP cascade — we
        // just flip the flag SkyLight already checks.
        //
        // The CA Framebuffer 2388×1668 '&b38' compressed IOSurface returns nil
        // from MTLSim AND from AGXG13GFamilyDevice. Other surfaces (blur
        // scratchpads, normal app windows) wrap fine. Tolerating nil for the
        // specific failing surface keeps WS alive and lets blur scratchpad
        // textures (which DO succeed) run normally.
        install_skylight_prepare_for_use_tolerate_nil_hook((const void *)header);

        // (Removed LAZY render_update cbz/cbnz/assert-block retargets — 3
        // sites that flipped composite_destination-nil failures into
        // epilogue jumps. Never fired under MACWS_AGX_REGISTER_CLASSES;
        // even when AGX render targets fail, the upstream cause is the
        // ResCreate FAIL kernel rejection, not nil propagation through
        // render_update. See AGENTS.md "Patch Discipline".)
#if 0
        // Patch the `cbz x24, +0x660` at SkyLight 0x18525ec50 so that when
        // _WSCompositeDestinationCreateWithIOSurface (or its WithMetalTexture
        // inner call) returns NULL, render_update jumps STRAIGHT to its
        // epilogue at 0x18525f62c instead of falling into the assert block
        // at 0x18525f2b0. The assert block sets up arg strings and a `bl
        // sub_18547c20c` — we already NOP that BL via the CAWSBackend.mm
        // patcher, but the post-NOP code reads `[sp, #0x38]` which is an
        // uninitialized local var on the FAIL path (only the OK path writes
        // it earlier). x8 = 0x3ff... (NaN-shaped 1.0f from a prior d-reg
        // spill) then ldr x8, [x8, #0x10] faults.
        //
        // Re-targeting the cbz to the epilogue makes the FAIL path return
        // cleanly without touching sp+0x38. x0 = 0 from the failed
        // composite-destination call is harmless to the caller (UpdateDisplays
        // tolerates a 0 return — it just renders nothing for this frame).
        if (getenv("MACWS_KEEP_RENDER_UPDATE_CBZ")) {
            // LAZY (three sites): retargets cbz/cbnz/first-insn of
            // SkyLight's render_update assert block straight to its
            // epilogue. That kept WS alive when composite_destination
            // came back nil. Default off; the assert it dodges contains
            // the actual file/line of why composite_destination was nil,
            // which is what we need to see now. Opt-IN with
            // MACWS_KEEP_RENDER_UPDATE_CBZ=1.
            // Search for cbz x24 followed by an adrp+add+mov_w2+bl pattern
            // (the assert sequence). The cbz target is the assert block.
            const uint64_t expected_orig = 0xB4003318;  // cbz x24, +0x660
            const uint64_t expected_new  = 0xB4004EF8;  // cbz x24, +0x9DC
            uint64_t static_check_pc = 0x18525ec50;
            uint64_t sl_static_base  = 0x18523053c - 0; // anchor on the wsccd entry
            // Use the entry-symbol resolved address as the slide anchor.
            void *wsccd = MSFindSymbol((MSImageRef)header,
                "_WSCompositeDestinationCreateWithMetalTexture");
            if (wsccd) {
                // On arm64e MSFindSymbol returns a PAC-signed pointer.
                // Strip the auth bits before arithmetic so subsequent
                // pointer reads don't fault as `KERN_INVALID_ADDRESS at
                // 0xfc508001983dec50 (possible pointer authentication
                // failure)` when bash / other non-WS chroot processes
                // load SkyLight (e.g. via QuartzCore_hooks dlopen).
                uintptr_t wsccd_raw = ((uintptr_t)wsccd) & 0x0000007FFFFFFFFFULL;
                intptr_t slide_sl = (intptr_t)wsccd_raw - (intptr_t)sl_static_base;
                uint32_t *cbz_at = (uint32_t *)(static_check_pc + slide_sl);
                if (*cbz_at == expected_orig) {
                    ModifyExecutableRegion(cbz_at, sizeof(uint32_t), ^{
                        *cbz_at = (uint32_t)expected_new;
                    });
                    fprintf(stderr, "#### SkyLight render_update cbz retargeted to epilogue at %p\n",
                            cbz_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update cbz mismatch at %p (got %#x)\n",
                            cbz_at, *cbz_at);
                }

                // Second cbz at 0x18525f0a8: `cbz w0, 0x18525f2d0` — when
                // sub_18547aa0c returns 0 (rect-empty or similar), control
                // jumps DIRECTLY to the same `ldr x8, [sp,#0x38] / ldr x8,
                // [x8,#0x10]` crash sequence. Retarget the second cbz to the
                // epilogue too so this path also returns cleanly.
                const uint32_t orig2 = 0x34001140;  // cbz w0, +0x228
                const uint32_t new2  = 0x34002C20;  // cbz w0, +0x584
                uint32_t *cbz2_at = (uint32_t *)(0x18525f0a8 + slide_sl);
                if (*cbz2_at == orig2) {
                    ModifyExecutableRegion(cbz2_at, sizeof(uint32_t), ^{
                        *cbz2_at = new2;
                    });
                    fprintf(stderr, "#### SkyLight render_update second-cbz retargeted at %p\n",
                            cbz2_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update second-cbz mismatch at %p (got %#x)\n",
                            cbz2_at, *cbz2_at);
                }

                // THIRD entry to the assert/crash block: another
                // WithMetalTexture call at 0x18525f2a0 returns NULL → falls
                // through `cbnz x24, 0x18525ec54` at 0x18525f2ac into the
                // assert setup at 0x18525f2b0. The cleanest catch-all is to
                // overwrite the FIRST instruction of the assert block
                // (0x18525f2b0) with `b 0x18525f62c` (jump straight to
                // epilogue). This makes EVERY path into the assert block —
                // including the cbnz fall-through, cbz x24 jump (already
                // retargeted), and any future variants — exit render_update
                // cleanly instead of touching the post-NOP uninit-stack
                // sequence.
                //   imm26 = (0x18525f62c - 0x18525f2b0) / 4 = 0x37C/4 = 0xDF
                //   B encoding: 0x14000000 | imm26 = 0x140000DF
                const uint32_t orig3 = 0xb00012e0;  // adrp x0, 0x1854bc000
                const uint32_t new3  = 0x140000DF;  // b 0x18525f62c
                uint32_t *assert_block_at = (uint32_t *)(0x18525f2b0 + slide_sl);
                if (*assert_block_at == orig3) {
                    ModifyExecutableRegion(assert_block_at, sizeof(uint32_t), ^{
                        *assert_block_at = new3;
                    });
                    fprintf(stderr, "#### SkyLight render_update assert-block b-to-epilogue at %p\n",
                            assert_block_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update assert-block mismatch at %p (got %#x)\n",
                            assert_block_at, *assert_block_at);
                }
            }
        }
#endif

        // NSLog(@"#### debugbydcmmc loadImageCallback SkyLight modified");
    } else if(!strncmp(info.dli_fname, IOMFBPath, strlen(IOMFBPath))) {
        // patch kern_SwapEnd passing correct inputStructCnt
        uint32_t *swapEnd = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt + (uintptr_t)header);
        ModifyExecutableRegion(swapEnd, sizeof(uint32_t), ^{
            // NSLog(@"#### debugbydcmmc OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) swapEnd, (unsigned long) *swapEnd, (unsigned long) 0x52808d03);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching IOMobileFramebuffer version/arch.  The
            // arm64 slice differs from arm64e, and CLI tools that merely pull
            // IOMFB in via libmachook's deps must not crash here.
            if (*swapEnd == 0x52808d03) { // mov    w3, #0x468
                *swapEnd = 0x52808d83; // mov    w3, #0x46c
            }
        });
        // NSLog(@"#### debugbydcmmc loadImageCallback IOMobileFramebuffer modified");

        // Hook the complete exported protocol operation, not the nested
        // IOConnect call.  QuartzCore's chained binding is already fixed up by
        // the time libmachook's interpose tuple is considered, so the tuple did
        // not fire in the 2026-07-26 control run.  The actual image's wrapper
        // is only four instructions; require all four before installing a
        // Substrate trampoline.  A second libmachook slice sees the modified
        // prologue and safely skips instead of stacking another hook.
        {
            static const uint32_t expectedSwapEndWrapper[4] = {
                0xb4000080, // cbz x0, +0x10
                0xf9439401, // ldr x1, [x0, #0x728]
                0xb4000041, // cbz x1, +0x8
                0xd61f083f, // braaz x1
            };
            void *publicSwapEnd = (void *)((uintptr_t)header + 0x11cc);
            if (memcmp(publicSwapEnd, expectedSwapEndWrapper,
                       sizeof(expectedSwapEndWrapper)) == 0) {
                MSHookFunction(publicSwapEnd,
                    (void *)MacwsIOMobileFramebufferSwapEnd_new,
                    (void **)&g_macws_orig_iomfb_swap_end);
                fprintf(stderr,
                    "#### COEXIST API SwapEnd hook installed target=%p trampoline=%p\n",
                    publicSwapEnd, g_macws_orig_iomfb_swap_end);
            } else {
                const uint32_t *actual = (const uint32_t *)publicSwapEnd;
                fprintf(stderr,
                    "#### COEXIST API SwapEnd hook skipped: wrapper mismatch "
                    "%#x %#x %#x %#x\n",
                    actual[0], actual[1], actual[2], actual[3]);
            }
        }

        // COEXISTENCE: WindowServer must finish every SwapBegin without
        // presenting over iOS's physical panel. The old patch changed
        // kern_SwapEnd+0x30 from BL IOConnectCallStructMethod to `mov x0,#0`.
        // Runtime-confirmed on 2026-07-23: that patch was active immediately
        // before `DCP PANIC ... RTK_workloop_init:80000008 - additionThread`.
        // It also violated the protocol invariant by reporting success without
        // sending either SwapEnd or SwapCancel.
        //
        // RE-confirmed via project LLDB against the loaded macOS 13.4 binary:
        //   kern_SwapBegin+60  loads io_connect_t from conn+0x14;
        //   kern_SwapBegin+84  calls scalar selector 4;
        //   kern_SwapBegin+140 stores the returned swap ID at conn+0x68;
        //   kern_SwapEnd+48    calls struct selector 5 with conn+0x18, 0x46c;
        //   kern_SwapCancel+32 copies w1 (swap ID), then +48/+64 calls scalar
        //                       selector 0x34 with exactly one input scalar.
        //
        // Arm a narrow call-layer translation below. Unlike replacing the
        // whole kern_SwapEnd function, it returns the real kernel status and
        // lets kern_SwapEnd continue with its gain-map release/counters.
        {
            char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
            if(_NSGetExecutablePath(exe, &exelen) == 0 &&
               strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL &&
               (is_process_running("backboardd") || access("/tmp/ws_headless", F_OK) == 0)) {
                const uint32_t *swapSubmit = (const uint32_t *)(
                    OFF_IOMobileFramebuffer_kern_SwapEnd_submit + (uintptr_t)header);
                if (*swapSubmit == 0x94001f64) {
                    atomic_store(&g_macws_iomfb_coexist_swap_cancel, 1);
                    fprintf(stderr,
                        "#### COEXIST: verified kern_SwapEnd BL; SwapEnd(sel5) -> "
                        "SwapCancel(sel0x34) translation armed\n");
                } else {
                    fprintf(stderr,
                        "#### COEXIST: kern_SwapEnd callsite mismatch (%#x); "
                        "SwapCancel translation NOT armed\n", *swapSubmit);
                }
            }
        }
    } else if(!strncmp(info.dli_fname, libxpcPath, strlen(libxpcPath))) {
        // Register the bundled XPC services inside each framework. KEY here is
        // the FRAMEWORK BINARY path (not the .xpc bundle path) — _xpc_bootstrap_services
        // walks each framework, finds its XPCServices/ subdir, and registers every .xpc
        // inside. xpc_add_bundle (the .xpc-path variant) silently fails in this context;
        // _xpc_bootstrap_services is the working API.
        //
        // - Metal.framework → MTLCompilerService.xpc (existing, shader compile)
        // - ViewBridge.framework → ViewBridgeAuxiliary.xpc (NEW: AppKit window content
        //   render — without this, Terminal logs "Connection Invalid for
        //   com.apple.ViewBridgeAuxiliary" and window content never renders)
        // - HIServices.framework → com.apple.hiservices-xpcservice.xpc (NEW: AppKit's
        //   client-aux endpoint; previously: "Connection Invalid for
        //   com.apple.hiservices-xpcservice")
        xpc_object_t dict = (xpc_object_t)xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/Metal.framework/Metal", 2);
        // Framework binary path uses TLD symlink form (matches Metal pattern)
        xpc_dictionary_set_uint64(dict, "/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", 2);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices", 2);
        void(*_xpc_bootstrap_services_fn)(xpc_object_t) = MSFindSymbol((MSImageRef)header, "__xpc_bootstrap_services");
        fprintf(stderr, "#### XPC_BOOTSTRAP: fn=%p dict=%p (registering Metal/ViewBridge/HIServices)\n",
            _xpc_bootstrap_services_fn, dict);
        if (_xpc_bootstrap_services_fn) {
            _xpc_bootstrap_services_fn(dict);
            fprintf(stderr, "#### XPC_BOOTSTRAP: called OK\n");
        } else {
            fprintf(stderr, "#### XPC_BOOTSTRAP: SYMBOL NOT FOUND\n");
        }
    } else if(!strncmp(info.dli_fname, MetalPath, strlen(MetalPath))) {
        // patch MTL*ReflectionReader::deserialize to match iOS
        // on macOS, there are extra instructions
        
        // 0x18ae78a34 <+956>:  mov    w9, #0x2                  ; =2
        // 0x18ae78a38 <+960>:  movk   w9, #0x1, lsl #16
        // 0x18ae78a3c <+964>:  cmp    w8, w9
        // 0x18ae78a40 <+968>:  b.lo   0x18ae78a8c               ; <+1044>
        // 0x18ae78a44 <+972>:  add    x0, sp, #0x68
        // 0x18ae78a48 <+976>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a4c <+980>:  add    x0, sp, #0x68
        // 0x18ae78a50 <+984>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a54 <+988>:  add    x0, sp, #0x68
        // 0x18ae78a58 <+992>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a5c <+996>:  add    x0, sp, #0x68
        // 0x18ae78a60 <+1000>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a64 <+1004>: add    x0, sp, #0x68
        // 0x18ae78a68 <+1008>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a6c <+1012>: ldr    w8, [x20, #0x68]
        uint32_t *MTLInputStageReflectionReader_deserialize = (uint32_t *)(OFF_Metal_MTLInputStageReflectionReader_deserialize_extra + (uintptr_t)header);
        ModifyExecutableRegion(MTLInputStageReflectionReader_deserialize, sizeof(uint32_t[15]), ^{
            if (MTLInputStageReflectionReader_deserialize[0] == 0x52800049) { // mov w9, #0x2
                for(int i = 0; i < 15; ++i) {
                    MTLInputStageReflectionReader_deserialize[i] = 0xd503201f; // nop
                }
            }
        });
        
        // 0x18ae79028 <+364>: mov    w9, #0x2                  ; =2
        // 0x18ae7902c <+368>: movk   w9, #0x1, lsl #16
        // 0x18ae79030 <+372>: cmp    w8, w9
        // 0x18ae79034 <+376>: b.lo   0x18ae79080               ; <+452>
        // 0x18ae79038 <+380>: add    x0, sp, #0x8
        // 0x18ae7903c <+384>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79040 <+388>: add    x0, sp, #0x8
        // 0x18ae79044 <+392>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79048 <+396>: add    x0, sp, #0x8
        // 0x18ae7904c <+400>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79050 <+404>: add    x0, sp, #0x8
        // 0x18ae79054 <+408>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79058 <+412>: add    x0, sp, #0x8
        // 0x18ae7905c <+416>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79060 <+420>: ldr    w8, [x20, #0x68]
        uint32_t *MTLFragmentReflectionReader_deserialize = (uint32_t *)(OFF_Metal_MTLFragmentReflectionReader_deserialize_extra + (uintptr_t)header);
        ModifyExecutableRegion(MTLFragmentReflectionReader_deserialize, sizeof(uint32_t[15]), ^{
            if (MTLFragmentReflectionReader_deserialize[0] == 0x52800049) { // mov w9, #0x2
                for(int i = 0; i < 15; ++i) {
                    MTLFragmentReflectionReader_deserialize[i] = 0xd503201f; // nop
                }
            }
        });

        // 2026-06-19 — MallocScribble surfaced the real upstream bug:
        // -[AGXTexture initWithDevice:desc:isSuballocDisabled:] at static
        // 0x1e5a5b7d4 calls `_objc_msgSend$validateWithDevice:` on the
        // MTLTextureDescriptor; descriptor doesn't implement that selector
        // in chroot → forwarding raises doesNotRecognizeSelector exception
        // → uncaught → SIGTRAP. Add the selector as a class method
        // returning YES on MTLTextureDescriptor (and any subclass), so the
        // AGXTexture init's cbz w0 check (at 0x1e5a5b7d8) passes and the
        // init proceeds.
        if (getenv("MACWS_AGX_NATIVE")) {
            Class kDesc = objc_getClass("MTLTextureDescriptor");
            if (kDesc) {
                SEL valSel = sel_registerName("validateWithDevice:");
                if (!class_getInstanceMethod(kDesc, valSel)) {
                    IMP validStub = imp_implementationWithBlock(^BOOL(id self, id device) {
                        (void)self; (void)device;
                        return YES;
                    });
                    BOOL ok = class_addMethod(kDesc, valSel,
                                              validStub, "c@:@");
                    fprintf(stderr,
                        "#### MACWS_AGX_NATIVE class_addMethod(MTLTextureDescriptor, validateWithDevice:) = %d\n",
                        ok);
                } else {
                    fprintf(stderr,
                        "#### MACWS_AGX_NATIVE MTLTextureDescriptor already responds to validateWithDevice:\n");
                }
            } else {
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE objc_getClass(MTLTextureDescriptor) = nil\n");
            }
            // 2026-06-20 (lldb-confirmed) — AGXTexture init at static
            // 0x1e5a5b9cc calls `_objc_msgSend$isMemoryless` on the
            // result of super-init (x19 = IOGPUMetalTexture instance).
            // IOGPUMetalTexture in the iOS framework lacks this macOS-side
            // selector, so provide the descriptor-backed semantic query on
            // that superclass.  Do not add texture methods to AGXBuffer: a
            // buffer receiving texture selectors is evidence that an
            // initializer returned the wrong class and must fail visibly.
            // 2026-06-20 — Full cascade RE'd via otool on AGXTexture init.
            // Selectors AGXTexture init sends that need to resolve on the
            // synth buffer / chroot descriptor / texture:
            //   validateWithDevice:   (descriptor) [already added above]
            //   isMemoryless          (super-init result texture)
            //   protectionOptions     (descriptor)
            //   getCPUSizeBytes       (descriptor or buffer)
            //   getAlignment          (descriptor)
            //   descriptorPrivate     (descriptor)
            //   getBytesPerRow        (descriptor)
            //   finalizeTextureCreation (self; must use AGXTexture's real implementation)
            //   updateBindDataWithAddresses:gpuVirtualAddress:
            //   updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:
            //   allocBufferSubDataWithLength:options:alignment:heapIndex:bufferIndex:bufferOffset:
            //   initNewTextureData:
            //   initImplWithDevice:Descriptor:... (the real init — skip stubbing)
            // Pre-emptively stub the ones whose default value is well-defined.
            // Each returns a safe value (NO, 0, nil, self) so the call site
            // continues past doesNotRecognizeSelector.
            struct stub { const char *sel; const char *enc; IMP imp; };
            // 2026-06-20 — isMemoryless was previously stubbed to ALWAYS
            // return NO, breaking memoryless texture handling: AGXTexture
            // init at 0x1e5a5b9c0 sends `isMemoryless` to the IOGPUMetalTexture
            // super-init result; returning NO sends it down the "with
            // backing memory" path, which for a memoryless request meant
            // ROUTE-IOSURF allocated a 31 MB IOSurface per call → 5120 MB
            // WS watermark OOM in <60 composite cycles.  Replace with an
            // IMP that queries the texture's storageMode property (part
            // of MTLTexture protocol; natively implemented on IOGPUMetalTexture
            // / AGXG13GFamilyBuffer) and returns YES iff the texture was
            // requested as memoryless (storageMode == 3).
            IMP retIsMemoryless = imp_implementationWithBlock(^BOOL(id s) {
                if (s && [s respondsToSelector:@selector(storageMode)]) {
                    // storageMode returns NSUInteger; use objc_msgSend variant
                    // to avoid pulling in Metal headers here.
                    typedef NSUInteger (*sm_t)(id, SEL);
                    NSUInteger sm = ((sm_t)objc_msgSend)(s, @selector(storageMode));
                    return sm == 3 /* MTLStorageModeMemoryless */;
                }
                return NO;
            });
            // size_t stubs returning 0
            IMP retZeroSize = imp_implementationWithBlock(^NSUInteger(id s) { (void)s; return 0; });
            // NSUInteger stubs returning 0
            IMP retZeroNS = imp_implementationWithBlock(^NSUInteger(id s) { (void)s; return 0; });
            // id stub returning self (for descriptorPrivate / initNewTextureData:)
            IMP retSelf = imp_implementationWithBlock(^id(id s) { (void)s; return s; });
            IMP retSelfArg = imp_implementationWithBlock(^id(id s, id a) { (void)s; (void)a; return s; });
            // void compatibility shims for the two bind-data selectors.
            IMP retVoid3 = imp_implementationWithBlock(^(id s, void *p, uint64_t va) { (void)s; (void)p; (void)va; });
            IMP retVoid4 = imp_implementationWithBlock(^(id s, void *p, uint64_t va, BOOL b) { (void)s; (void)p; (void)va; (void)b; });
            // nil stub for allocBufferSubData…
            IMP retNil = imp_implementationWithBlock(^id(id s, NSUInteger l, NSUInteger o, NSUInteger a,
                                                          NSUInteger h, NSUInteger b, NSUInteger off) {
                (void)s; (void)l; (void)o; (void)a; (void)h; (void)b; (void)off; return nil;
            });
            struct stub stubs[] = {
                { "isMemoryless",                                  "c@:",                retIsMemoryless },
                { "protectionOptions",                             "Q@:",                retZeroNS },
                { "getCPUSizeBytes",                               "Q@:",                retZeroSize },
                { "getAlignment",                                  "Q@:",                retZeroSize },
                { "descriptorPrivate",                             "@@:",                retSelf },
                { "getBytesPerRow",                                "Q@:",                retZeroSize },
                { "updateBindDataWithAddresses:gpuVirtualAddress:", "v@:^vQ",            retVoid3 },
                { "updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:", "v@:^vQc", retVoid4 },
                { "allocBufferSubDataWithLength:options:alignment:heapIndex:bufferIndex:bufferOffset:",
                                                                    "@@:QQQQQQ",        retNil },
                { "initNewTextureData:",                           "@@:@",               retSelfArg },
                { NULL, NULL, NULL }
            };
            const char *targets[] = {
                "IOGPUMetalTexture",
                "AGXTexture",
                "MTLTextureDescriptor",
                "AGXG13GFamilyTexture",
                NULL
            };
            for (int t = 0; targets[t]; t++) {
                Class k = objc_getClass(targets[t]);
                if (!k) continue;
                for (int s = 0; stubs[s].sel; s++) {
                    SEL sel = sel_registerName(stubs[s].sel);
                    if (class_getInstanceMethod(k, sel)) continue;
                    BOOL ok = class_addMethod(k, sel, stubs[s].imp, stubs[s].enc);
                    if (ok) {
                        fprintf(stderr,
                            "#### MACWS_AGX_NATIVE class_addMethod(%s, %s) = 1\n",
                            targets[t], stubs[s].sel);
                    }
                }
            }
        }
    } else if(!strncmp(info.dli_fname, QuartzCorePath, strlen(QuartzCorePath))) {
        // The cancellation-completion experiment observes QuartzCore state
        // immediately after its real FrameInfo registration without changing
        // IOMFB's function or import slot.  Install that narrow observer only
        // when explicitly requested before this image loads; with no sentinel
        // the baseline is byte-for-byte untouched.
#ifdef FORCE_M1_DRIVER
        if (atomic_load(&g_macws_iomfb_coexist_swap_cancel) &&
            access("/tmp/macws_cancel_completion", F_OK) == 0) {
            macws_install_quartzcore_frame_info_hook(header);
        }
#endif
        // Force CABackingStorePrepareUpdates_ onto the accelerated/IOSurface path so window
        // content gets a GPU surface instead of a CPU bitmap (see OFF_ comment above).
        // Patch `cbz w21, +852` (0x34000155) -> `b +840` (0x14000007).
        //
        // Apply only in CLIENT apps, NOT in WindowServer itself: WindowServer also links
        // QuartzCore and uses CABackingStore for its own (menu bar / cursor) rendering, where
        // forcing the accelerated path breaks its UI (menus stop opening).  Detect WindowServer
        // by its main executable path and skip the patch there.
        char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
        BOOL isWindowServer = NO;
        if(_NSGetExecutablePath(exe, &exelen) == 0) {
            isWindowServer = (strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL);
        }
        if(!isWindowServer && getenv("MACWS_KEEP_FORCE_ACCEL")) {
            // LAZY: forces CABackingStorePrepareUpdates_ to take the
            // accelerated (IOSurface) branch unconditionally. Was hiding
            // the actual reason apps fell to the CPU bitmap path. Opt-IN
            // with MACWS_KEEP_FORCE_ACCEL=1; default off so the real
            // CPU-vs-GPU decision logic runs and we see why it picked CPU.
            uint32_t *forceAccel = (uint32_t *)(OFF_QuartzCore_CABackingStore_force_accel + (uintptr_t)header);
            ModifyExecutableRegion(forceAccel, sizeof(uint32_t), ^{
                if (*forceAccel == 0x34000155) { // cbz w21, #0x28 (+852)
                    *forceAccel = 0x14000007;    // b +840 (accelerated path)
                }
            });
        }
    } else if(getenv("MACWS_AGX_NATIVE") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
        // 2026-06-20 — One-shot guard.  AGXMetal13_3 is dlopen'd multiple
        // times across the WS lifetime (initial Metal load + chroot's
        // explicit re-dlopen + dyld notify on dependent-loads).  Re-running
        // the patches is idempotent BUT the diagnostic fprintf calls
        // accumulate stderr writes, and on the Nth invocation we've seen
        // KERN_PROTECTION_FAILURE in __write_nocancel (stderr's FILE buffer
        // gets corrupted somewhere — likely a stack overlap during the
        // dyld notify-load lock).  Make this block fire ONCE per process.
        static _Atomic int s_agxmetal_patched = 0;
        if (atomic_exchange(&s_agxmetal_patched, 1)) {
            return; // already patched in this process
        }
        // CHROOT AGX-NATIVE patches for the strict-AGX-native userspace path.
        //
        // Originally three layered binary patches lived here:
        //
        //   1. NOP setupDeferred's dispatch_once  (b.ne at +0x64 → NOP)
        //   2. NOP the first forward BL inside each Mempool<X>::grow (the lambda
        //      that tail-jumps to the IOGPU pool allocator BSS slot)
        //   3. Replace `b.hs +<off>` near grow's entry with an unconditional
        //      `b epilogue` so the broken inline freelist loop is skipped
        //
        // All three existed because cross-image IOGPU bindings stayed null in
        // chroot dyld — Mempool::grow's lambda then crashed dereferencing the
        // garbage function pointer at data_21f95bc90.
        //
        // Those root causes have since been fixed by the chained-fixups walker
        // (macws_walk_chained_fixups), the LC_SYMTAB-based GOT repair
        // (macws_repair_got_via_symtab), the IOGPU ctor preload, and the
        // sub_1e5a5dfc0 stub rewrite. Once IOGPU is bound, setupDeferred and
        // grow's lambda both have to run — they're the only place
        // _storageCreateParams.hwResourcePoolCount gets set, and without that
        // commandBufferResourceInfo returns nil and DataBufferAllocator::
        // newCommand crashes on a null base.
        //
        // Removed 2026-06-18 after auditing the patches.
        uint64_t text_static_base = 0x1e53e321c;
        unsigned long text_sz = 0;
        uint8_t *text = getsectiondata((const struct mach_header_64 *)header,
                                       "__TEXT", "__text", &text_sz);
        intptr_t slide = (intptr_t)text - (intptr_t)text_static_base;

        // ──────────────────────────────────────────────────────────────────
        // AGX texture wrap gate bypass (env-gated).
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] @ 0x1e5a5ae18 calls
        //   sub_1e5a5d5f0(iosurface, plane)   ; some IOSurface-type query
        //   cmp w0, #0x4
        //   ccmp w0, #0x1, #0x4, ls           ; flags = (w0==1 if w0<=4) else Z=1
        //   b.eq EXIT_NIL                     ; @ 0x1e5a5ae60, fires if w0==1 OR w0>4
        // In chroot the query returns a value that triggers the nil-exit even for
        // a perfectly valid BGRA8 IOSurface. NOP the b.eq so the function always
        // proceeds to the real init path (sub_1e5aad880 →
        // initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:...).
        // Gated by MACWS_AGX_TEX_BYPASS_GATE=1 so we can A/B with the original.
        // DIAG: identify the cross-image GOT bindings used by AGXTexture's
        // init chain. The stubs:
        //   sub_1e5a5d540 loads *0x21f934130 → gate-1 query (called from
        //     -[AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:])
        //   sub_1e5a5d5f0 loads *0x21f934200 → gate-1 of -[AGXTexture init...]
        //     (returns int; value 1 or >4 triggers immediate nil)
        //   sub_1e5a5d650 loads *0x21f934240 → gate-3 query (iosurface)
        //   sub_1e5a5d590 loads *0x21f934220 → property loader (no gate)
        // Resolve each via dladdr to identify the actual IOSurface/IOGPU
        // symbol so we can reason about what they SEMANTICALLY check
        // rather than blindly NOPing.
        if (getenv("MACWS_AGX_TEX_BYPASS_GATE")) {
            struct got_probe { uint64_t addr; const char *role; } probes[] = {
                { 0x21f934130, "newTexture:iosurface: gate query" },
                { 0x21f934200, "AGXTexture init gate-1 (returns int)" },
                { 0x21f934220, "AGXTexture init prop load" },
                { 0x21f934240, "AGXTexture init gate-3 (iosurface)" },
                // Stub @0x1e5a5dfc0 = adrp 0x21f95b000 + add #0xca8 + ldr [#0xca8].
                // (Earlier note had this as 0x21f934ca8 — wrong page; the
                // ADRP target for THIS stub is 0x21f95b000.)
                //
                // BN's macOS DSC view shows ALL __auth_stubs reference one of
                // ~15 cache-shared __got pages (0x21f927000..0x21f95b000). The
                // 0x21f95b000 page is the libobjc runtime-helper page; sub_
                // 1e5a5dfc0 specifically is `_objc_msgSendSuper2` (called from
                // every -[…super dealloc] / [super initWith…] in this image).
                //
                // In chroot the page is OUTSIDE the dlopen'd image's segments
                // → the slot reads whatever happens to be at that VA (e.g.
                // MTCapabilityIsAvailable from MediaToolbox), super-init
                // returns 0, -[AGXTexture init…] nil-exits.
                //
                // The MACWS_AGX_NATIVE block below patches the stub itself
                // (movz/movk/movk/br x16 to dlsym'd objc_msgSendSuper2),
                // bypassing the broken slot entirely.
                { 0x21f95bca8, "objc_msgSendSuper2 slot (via stub sub_1e5a5dfc0)" },
            };
            for (size_t pi = 0; pi < sizeof(probes)/sizeof(probes[0]); pi++) {
                void **slot = (void **)(probes[pi].addr + slide);
                void *fn = *slot;
                Dl_info di = {0};
                int ok = dladdr(fn, &di);
                dprintf(2,
                    "#### AGX_TEX_DIAG GOT@%p = %p  (slid %#llx + %#zx = %#llx)\n"
                    "####   role: %s\n"
                    "####   dladdr ok=%d sym=%s base=%p path=%s\n",
                    slot, fn,
                    (unsigned long long)probes[pi].addr, (size_t)slide,
                    (unsigned long long)(probes[pi].addr + slide),
                    probes[pi].role,
                    ok, di.dli_sname ?: "(none)", di.dli_fbase, di.dli_fname ?: "(none)");
            }
        }
        // ──────────────────────────────────────────────────────────────────
        // Historical texBaseAddressesUpdated crash reproducer (diagnostic only).
        //
        // Root cause (see memory [[agx-texbaseaddresses-nullderef]]):
        //   SkyLight's CompositorMetal::CreateShadowFromMask (window shadow
        //   texture for chrome rendering) calls -[AGXG13GFamilyDevice
        //   newTextureWithDescriptor:] (no-iosurface variant), which routes
        //   through -[AGXTexture initWithDevice:desc:isSuballocDisabled:].
        //   That init calls
        //     [self updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:]
        //   which internally calls AGX::TextureGen4<G13>::texBaseAddressesUpdated().
        //   In chroot, the texture's `(self->0x1c8)->0x8` is null, so
        //   texBaseAddressesUpdated +2932 (ldr x11,[x11,#0x18] after
        //   `add x11,x11,x10` where x10 is an ivar offset of 0x18) faults
        //   at addr 0x30. WS dies with SIGSEGV.
        //
        // Confirmed by iOS-side lldb runtime trace (see [[lldb-remote-
        // debugserver-setup]] + misc/ios_lldb_tmux.sh): the initImpl* path
        // I'd been investigating earlier runs fine (9/9 calls reach
        // epilogue); only this initWithDevice:desc:isSuballocDisabled:
        // path crashes. The crash is in a SHADOW texture path, not the
        // framebuffer-IOSurface path.
        //
        // The old shipped patch NOPed the BL @ 0x1e5a5ba10 inside
        //   `-[AGXTexture initWithDevice:desc:isSuballocDisabled:]`. That
        // BL targets objc_msgSend$updateBindDataWithAddresses:gpuVirtual\
        // Address:shouldInitMetadata: (the stub @ 0x1e5ab1bc0). Skipping
        // it means the AGX encoder bind tables don't get updated with this
        // texture's base address (so a draw using the texture might show
        // garbage), but the texture object itself is still created and
        // returned. AGXTexture's `finalizeTextureCreation` call right
        // after (at 0x1e5a5ba18, bl 0x1e5aacfa0) still runs.
        //
        // For SkyLight's shadow-mask use case the worst-case is window
        // chrome shadows render incorrectly — acceptable trade vs WS dying.
        //
        // 2026-07-23 project-LLDB correction: after the upstream AGXBuffer
        // initFull/resource-size fixes, Texture+0x1c8 now owns three real
        // AGXBuffer objects with non-NULL IOGPUMetalResource::_res fields.
        // Keeping the BLs enabled completes the real initializer and stores
        // Texture+0x130/+0x40.  The old default NOP directly caused
        // writeRegion to call memmove with dst=NULL.  Normal AGX-native runs
        // therefore never patch these calls.  MACWS_DIAG_SKIP_BIND_UPDATE is
        // retained solely to reproduce the historical failure under LLDB.

        // DIAG: what class is in __objc_classrefs at offset 0x298?
        // -[AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:]
        //   at 0x1e574d5ac (FAIL path): loads classref @ 0x21a8a9298 →
        //   objc_alloc(<class>) → ... initWithDevice:desc:iosurface:plane:.
        // The init's `[self initImplWith...]` dispatch goes to the alloc'd
        // class's impl. If the class is AGXTexture (base, returns 0) the
        // texture wrap fails. If it's AGXG13GFamilyTexture (subclass with
        // the real impl), the wrap should work. Log which one.
        if (getenv("MACWS_AGX_NATIVE")) {
            void **classref_slot = (void **)(0x21a8a9298 + slide);
            void *cls = *classref_slot;
            const char *clsname = cls ? class_getName((Class)cls) : "(nil)";
            dprintf(2,
                "#### AGX_CLASSREF_DIAG newTexture iosurface alloc class "
                "@%p = %p name=%s\n",
                classref_slot, cls, clsname);
            // Check critical method on the texture class — initImpl variants
            // The plain stub on AGXTexture base returns 0 (we saw at static
            // 0x1e5a5a880-884: mov w0,#0; ret). If dispatch resolves to that
            // base stub instead of AGXG13GFamilyTexture's real impl, every
            // texture creation returns nil. Compare imp address against
            // both static addresses (with slide):
            //   AGXTexture initImplWith... = 0x1e5a5a880 (base, stub)
            //   AGXG13GFamilyTexture initImplWith... = 0x1e5a4a284 (subclass, real)
            if (cls) {
                SEL sel = sel_registerName(
                    "initImplWithDevice:Descriptor:iosurface:plane:buffer:"
                    "bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:"
                    "isHeapBacked:");
                Method m = class_getInstanceMethod((Class)cls, sel);
                IMP imp = m ? method_getImplementation(m) : NULL;
                uintptr_t agxtex_stub = (uintptr_t)0x1e5a5a880 + slide;
                uintptr_t agxg13_real = (uintptr_t)0x1e5a4a284 + slide;
                const char *which = "UNKNOWN";
                if ((uintptr_t)imp == agxtex_stub) which = "AGXTexture-stub-returns-0";
                else if ((uintptr_t)imp == agxg13_real) which = "AGXG13GFamilyTexture-real";
                dprintf(2,
                    "#### AGX_CLASSREF_DIAG initImpl method m=%p imp=%p "
                    "expected stub=%p real=%p WHICH=%s\n",
                    m, imp, (void*)agxtex_stub, (void*)agxg13_real, which);
            }
        }

        if (getenv("MACWS_DIAG_SKIP_BIND_UPDATE")) {
            // Two BL sites both target objc_msgSend$updateBindDataWith…
            // which calls AGX::TextureGen4<G13>::texBaseAddressesUpdated()
            // — that function +2932 does `ldr x11, [x11, #0x18]` where
            // x11's prior load is null in chroot → SEGV at addr 0x30.
            // NOP both so neither texture-init path crashes:
            //
            //   0x1e5a5ba10 (3-arg variant)
            //     called from -[AGXTexture initWithDevice:desc:isSuballocDisabled:]
            //     dispatches objc_msgSend$updateBindDataWithAddresses:
            //                gpuVirtualAddress:shouldInitMetadata:
            //   0x1e5a5afc4 (5-arg variant) — IOSURFACE init path
            //     called from -[AGXTexture initWithDevice:desc:iosurface:plane:]
            //     dispatches objc_msgSend$updateBindDataWithAddresses:cpu
            //                MetadataAddress:gpuVirtualAddress:isCompressible:
            //                shouldInitMetadata:
            //
            // After the sel=0xa type=0x82 IOSurfaceID fix (2026-06-18),
            // texture init reaches the iosurface variant for the first
            // time and crashes there too — symptom-identical to the
            // pre-existing 3-arg crash this patch already handled. Same
            // fix applies.
            uint64_t bl_statics[] = { 0x1e5a5ba10, 0x1e5a5afc4 };
            const uint32_t NOP_INSN = 0xd503201f;
            for (size_t i = 0; i < sizeof(bl_statics)/sizeof(bl_statics[0]); i++) {
                uint64_t bl_static = bl_statics[i];
                uint32_t *bl_at = (uint32_t *)(bl_static + slide);
                ModifyExecutableRegion(bl_at, sizeof(uint32_t), ^{
                    uint32_t insn = *bl_at;
                    // BL opcode mask: top 6 bits = 100101 (0x94/0x97 with imm).
                    BOOL is_bl = ((insn & 0xFC000000) == 0x94000000);
                    if (is_bl) {
                        *bl_at = NOP_INSN;
                        dprintf(2,
                            "#### MACWS_DIAG_SKIP_BIND_UPDATE: NOPed BL @%p "
                            "(static %#llx + slide=%#zx)\n",
                            bl_at, (unsigned long long)bl_static,
                            (size_t)slide);
                    } else if (insn == NOP_INSN) {
                        /* already patched */
                    } else {
                        dprintf(2,
                            "#### MACWS_DIAG_SKIP_BIND_UPDATE: @%p got %#x "
                            "expected BL — SKIP\n",
                            bl_at, insn);
                    }
                });
            }
        }
        //
        // Need to read what each gate actually does before patching. The
        // stubs sub_1e5a5d5f0 / sub_1e5a5d650 are __auth_stub jump-thunks
        // into IOSurface/IOGPU framework via __got slots 0x21f934200 /
        // 0x21f934240 (etc.). Those slots' bound symbols can only be read
        // by attaching lldb to a running WS and dumping the slot contents
        // (or by decoding the dyld chained-fixups via otool -bind).
        //
        // TODO once symbols are identified:
        //   1. Understand what the IOSurface property check actually wants
        //   2. Either: (a) modify our IOSurface to satisfy the check, or
        //      (b) hook the IOSurface API itself to return the expected
        //      value for AGX's framebuffer surfaces in chroot.

        // ──────────────────────────────────────────────────────────────────
        // __objc_superrefs slot patcher for AGXTexture → IOGPUMetalTexture.
        //
        // Background discovered 2026-06-17:
        //   -[AGXTexture initWithDevice:desc:iosurface:plane:] at 0x1e5a5af00
        //   loads its [super …] receiver class from 0x21a8a96d0 (an entry in
        //   __objc_superrefs). In a normal binary, dyld would process the
        //   chained-fixup record at that slot and write the runtime class
        //   pointer. AGXMetal13_3 was extracted from the DSC and has NO
        //   LC_DYLD_CHAINED_FIXUPS / LC_DYLD_INFO_ONLY — so the slot keeps
        //   its raw cache-baked chained-fixup encoding (e.g. high-byte 0x01,
        //   0xf0 noise bits) and reads back as a pointer to garbage.
        //
        //   objc_msgSendSuper2 then class-looks-up the selector against the
        //   garbage receiver → no method found → 0 return → init nil-exit
        //   at the cbz x0 immediately after. Our IOGPU_INIT_HOOK never fires
        //   even though class_getSuperclass(AGXTexture)==IOGPUMetalTexture
        //   resolves correctly via libobjc's superClassName fallback — the
        //   ABI-level superref slot is unaffected by that fallback.
        //
        // Fix: at AGXMetal13_3 load time, write the LIVE IOGPUMetalTexture
        // class pointer into 0x21a8a96d0+slide. __objc_superrefs is in plain
        // __DATA (no PAC auth needed); a raw pointer write suffices.
        //
        // Slot is at the very END of __objc_superrefs (size 0x140 from
        // 0x21a8a9598; offset 0x6d0 from page 0x21a8a9000 → 0x21a8a96d0,
        // which is 0x138 from the start of __objc_superrefs == the 40th /
        // last superref entry). Other superref entries used by other AGX
        // classes are TODO — patch reactively as more nil-exits surface.
        if (getenv("MACWS_AGX_NATIVE")) {
            // 2026-06-17 lldb-confirmed root cause of texture-init nil-exit
            // (and the actual fix that worked):
            //
            // libobjc's objc_msgSendSuper2 does at +16:
            //     autda x16, x17     ; PAC-auth super_class->superclass
            //     ldr   x10, [x16, #0x10]    ; load cache buckets
            //
            // AGXTexture's runtime class_t.superclass holds a raw unsigned
            // 0x1fdfdcfb0 (= IOGPUMetalTexture) — the cache-baked PAC-signed
            // chained-fixup record at __DATA AGXTexture+0x8 isn't processed
            // by chroot dyld (DSC extraction strips chained fixups), so
            // libobjc's name-based class registration left the field as a
            // raw pointer. autda on a raw pointer fails → x16 becomes 0 (or
            // poisoned) → ldr [x16+0x10] segfaults at 0x10. WS dies.
            //
            // PAC-signing from libmachook is unavailable here — we're built
            // as arm64 (not arm64e), so macws_pac_sign is a no-op. Instead:
            // replace the autda inside libobjc with xpacd x16. xpacd just
            // STRIPS PAC bits without verification — works for both signed
            // (legit) and raw (our case) pointers. autda x16,x17 and
            // xpacd x16 are both 4 bytes, so it's a single-instruction patch.
            //
            // Patch is per-process (ModifyExecutableRegion does COW), other
            // processes' libobjc unaffected.

            // (The previous AGXTexture super-init bypass that lived here —
            // forcing -[AGXTexture initWithDevice:desc:iosurface:plane:] to
            // return self regardless of IOGPUMetalTexture's super-init result
            // — was removed 2026-06-18. The IOSurfaceID +0x30 swap on sel=0xa
            // type=0x82 made the super-init actually succeed, so the bypass
            // is no longer needed.)

            void *super2 = dlsym(RTLD_DEFAULT, "objc_msgSendSuper2");
            if (super2) {
                // dlsym returns a PAC-signed function pointer in an arm64e
                // process.  Using that value as a data pointer after adding
                // 0x10 faults with SEGV_ACCERR instead of reading the
                // instruction.  Runtime witness (agxprobe_e, 2026-07-24):
                // x0=0x132400019280de00 and loadImageCallback+0xf94 faulted
                // while reading 0x132400019280de10.  Strip only the pointer
                // authentication bits used for arithmetic; the instruction
                // value below still has to match before any patch is made.
                void *super2_code = ptrauth_strip(
                    super2, ptrauth_key_function_pointer);
                // autda is at msgSendSuper2 + 16 (verified by lldb).
                uint32_t *autda_at =
                    (uint32_t *)((uint8_t *)super2_code + 16);
                const uint32_t AUTDA_X16_X17 = 0xdac11a30u;
                const uint32_t XPACD_X16     = 0xdac147f0u;
                uint32_t cur = *autda_at;
                dprintf(2,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH msgSendSuper2=%p "
                    "code=%p autda@%p insn=%#x\n",
                    super2, super2_code, autda_at, cur);
                if (cur == XPACD_X16) {
                    dprintf(2, "####   already patched, skip\n");
                } else if (cur != AUTDA_X16_X17) {
                    dprintf(2,
                        "####   unexpected insn (expected %#x for autda x16,x17) — skip\n",
                        AUTDA_X16_X17);
                } else {
                    ModifyExecutableRegion(autda_at, 4, ^{
                        *autda_at = XPACD_X16;
                    });
                    dprintf(2,
                        "####   PATCHED autda x16,x17 → xpacd x16 (%#x → %#x)\n",
                        AUTDA_X16_X17, XPACD_X16);
                }
            } else {
                dprintf(2,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH: dlsym(objc_msgSendSuper2)=NULL\n");
            }

            // Diagnostic (read-only) — useful when triaging future variants.
            Class agx_tex = objc_getClass("AGXTexture");
            Class iogpu_tex = objc_getClass("IOGPUMetalTexture");
            if (agx_tex && iogpu_tex) {
                uint64_t *super_field = (uint64_t *)((uintptr_t)agx_tex + 8);
                dprintf(2,
                    "#### MACWS_AGX_SUPERCLASS_DIAG AGXTexture=%p field@%p=%#llx "
                    "IOGPUMetalTexture=%p\n",
                    (void*)agx_tex, super_field,
                    (unsigned long long)*super_field,
                    (void*)iogpu_tex);
            }
        }

        // ──────────────────────────────────────────────────────────────────
        // Runtime diagnostic: dump the cstring at the [super initWith…]
        // selector address used by -[AGXTexture initWithDevice:desc:iosurface\
        // :plane:].
        //
        // At static 0x1e5a5af08:
        //     adrp x8, 0x1cffc6000
        //     add  x1, x8, #0xf26    ; SEL @ 0x1cffc6f26
        //
        // 0x1cffc6f26 is OUTSIDE every segment of the extracted binary —
        // in the cache it points to libobjc's __objc_methname, which is
        // not part of the extracted image. After slide-relocation in chroot
        // it lands at some unrelated VA. objc_msgSendSuper2 sees a wrong
        // (or garbage) selector name → method lookup fails → returns 0 →
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] nil-exits at
        // cbz x0 (static 0x1e5a5af3c) before validate is ever reached.
        //
        // Print the first 96 bytes at the slid VA so we can see what
        // actually lives there.
        if (getenv("MACWS_AGX_NATIVE")) {
            uint64_t sel_static = 0x1cffc6f26;
            const char *sel_runtime = (const char *)(sel_static + slide);
            char preview[97] = {0};
            int readable = 0;
            @try {
                memcpy(preview, sel_runtime, 96);
                readable = 1;
            } @catch (id e) {
                readable = 0;
            }
            // Sanitize for printing
            for (size_t i = 0; i < sizeof(preview)-1; i++) {
                unsigned char c = (unsigned char)preview[i];
                if (c == 0) { preview[i] = 0; break; }
                if (c < 0x20 || c >= 0x7f) preview[i] = '.';
            }
            // 2026-06-20 — dprintf(2, ...) not dprintf(2, ...) here.
            // The latter writes to libsystem's _stderr FILE struct's
            // internal buffer; if the FILE struct's _p (current write
            // position) gets corrupted (we saw KERN_PROTECTION_FAILURE
            // in __write_nocancel writing to a shared-cache RO address),
            // every subsequent fprintf in any loadImageCallback re-entry
            // crashes WS.  dprintf does fresh-buffer-then-write(fd) — no
            // FILE* state involved, robust against the corruption.
            dprintf(2,
                "#### MACWS_AGX_SEL_DIAG super-init SEL static=%#llx slid=%p "
                "readable=%d\n"
                "####   bytes=\"%s\"\n",
                (unsigned long long)sel_static, sel_runtime, readable, preview);

            // Also: what does sel_registerName resolve THIS cstring to?
            if (readable && preview[0]) {
                SEL s = sel_registerName(sel_runtime);
                dprintf(2,
                    "####   sel_registerName(...) = %p name=\"%s\"\n",
                    s, sel_getName(s));
            }

            // And what selector does our AGXG13GFamilyTexture's superclass
            // actually expect for initWith…iosurface… ? Try the obvious
            // candidate names.
            const char *candidates[] = {
                "initWithDevice:desc:iosurface:plane:",
                "initWithDevice:descriptor:iosurface:plane:",
                "initWithDevice:descriptor:iosurface:plane:field:args:argsSize:",
                "initImplWithDevice:Descriptor:iosurface:plane:buffer:"
                  "bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:"
                  "isHeapBacked:",
                NULL
            };
            // Also peek at IOGPUMetalTexture class registration + method list count
            Class iogpu_tex = objc_getClass("IOGPUMetalTexture");
            fprintf(stderr,
                "####   objc_getClass(IOGPUMetalTexture) = %p\n", iogpu_tex);
            if (iogpu_tex) {
                unsigned int n = 0;
                Method *ml = class_copyMethodList(iogpu_tex, &n);
                fprintf(stderr, "####   IOGPUMetalTexture method count = %u\n", n);
                int shown = 0;
                for (unsigned int j = 0; j < n && shown < 32; j++) {
                    const char *mn = sel_getName(method_getName(ml[j]));
                    if (strstr(mn, "init") || strstr(mn, "Init")) {
                        fprintf(stderr, "####     - %s\n", mn);
                        shown++;
                    }
                }
                if (ml) free(ml);
            }
            Class agxtex_cls = objc_getClass("AGXTexture");
            Class super_cls  = agxtex_cls ? class_getSuperclass(agxtex_cls) : NULL;
            fprintf(stderr,
                "####   AGXTexture super class = %p (%s)\n",
                super_cls, super_cls ? class_getName(super_cls) : "(nil)");
            for (int c = 0; candidates[c]; c++) {
                SEL s = sel_registerName(candidates[c]);
                Method m = super_cls ? class_getInstanceMethod(super_cls, s) : NULL;
                fprintf(stderr,
                    "####   super responds to \"%s\" = %d (Method=%p)\n",
                    candidates[c], m != NULL, m);
            }
        }

        // (Removed LAZY -[AGXG13GFamilyTexture validateBufferTextureWithSize:]
        // → always-YES patch. The magic-footer check at this site never
        // fires when we get to it under MACWS_AGX_REGISTER_CLASSES: the
        // upstream AGXIOC ResCreate FAIL returns nil before validate is
        // reached, and when it IS reached it now returns its real result.
        // See AGENTS.md "Patch Discipline".)
#if 0
        // Discovered this session (2026-06-17) while chasing the
        // newTextureWithDescriptor:iosurface:plane: = nil failure mode:
        //
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] is reached. It
        // alloc's the texture and calls [AGXG13GFamilyTexture initImplWith…]
        // which we already verified returns 1 (success) for every format WS
        // tries (BGRA8 / depth / stencil / depth32f_s8 / 2-plane '&b38').
        //
        // Then init continues past initImpl and at static 0x1e5a5afdc does:
        //     ldr  x8, [x20, #0x28]
        //     and  x2, x8, #0xffffffffffffff
        //     mov  x0, x23
        //     bl   0x1e5ab1d00            ; objc_msgSend$validateBufferTexture\
        //                                 ; WithSize:
        //     tbnz w0, #0, return_self    ; if bit-0 set → success
        //     mov  x0, x23
        //     b    0x1e5a5e010            ; → -[AGXTexture dealloc] → nil
        //
        // i.e. if `validateBufferTextureWithSize:` returns 0 the init nil-
        // exits. AGXG13GFamilyTexture's impl at 0x1e576ef94 does:
        //     ivar_off = data_21a8a9884
        //     desc     = self->ivar
        //     if (!desc->0x18a)        return 1
        //     if (desc->0x168+0x10 > arg3) return 0    ; size check
        //     ptr      = desc->0x130
        //     if (!ptr)                return 1
        //     {a,b}    = *(ptr + desc->0x168)
        //     if ((a ^ 0x99b7d4010ce3ead3) | (b ^ 0x92482f97c0394fd0) == 0)
        //                              return 1        ; magic match
        //     return 0
        //
        // The two magic constants are a guard-word at the END of an internal
        // texture-metadata blob written by the AGX firmware/kernel after
        // creation. In chroot the blob is not initialised (firmware path
        // diverges) so the magic mismatches → validate returns 0 → init
        // nil-exits → newTextureWithDescriptor:iosurface:plane: = nil →
        // SkyLight gets nil texture → WSCompositeDestinationCreateWith\
        // MetalTexture: texture=nil → VNC stays black.
        //
        // Bypass: rewrite the function's first 2 instructions:
        //     movz w0, #1   (0x52800020)
        //     ret           (0xd65f03c0)
        // (Function has no PAC prologue; safe to overwrite from byte 0.)
        //
        // Risk: validate is checking that the texture metadata footer is
        // intact. Returning YES blindly means we accept textures whose
        // metadata is wrong; later GPU draws using them may render garbage.
        // For the SkyLight CaptureSurface path (a single 2-plane scanout
        // target) that's acceptable — VNC reads the IOSurface CPU side via
        // IOSurfaceLock and we don't need the GPU metadata at all.
        //
        // LAZY: validateBufferTextureWithSize: always-YES. This silenced
        // the magic-footer (0x99b7d4010ce3ead3 / 0x92482f97c0394fd0) check
        // failure that fires when AGX firmware-written texture metadata
        // diverges in chroot. Now opt-IN via MACWS_KEEP_VALIDATE_ALWAYS=1;
        // default is to let the real check return and expose downstream
        // failure (newTextureWithDescriptor:iosurface:plane: → nil).
        // See AGENTS.md "Patch Discipline".
        if (getenv("MACWS_AGX_NATIVE") &&
            !getenv("MACWS_AGX_KEEP_VALIDATE") &&
            getenv("MACWS_KEEP_VALIDATE_ALWAYS")) {
            uint64_t fn_static = 0x1e576ef94;
            uint32_t *fn_at = (uint32_t *)(fn_static + slide);
            const uint32_t MOVZ_W0_1 = 0x52800020u;   // movz w0, #1
            const uint32_t RET        = 0xd65f03c0u;  // ret
            uint32_t cur0 = fn_at[0], cur1 = fn_at[1];
            if (cur0 == MOVZ_W0_1 && cur1 == RET) {
                fprintf(stderr,
                    "#### MACWS_AGX_VALIDATE_ALWAYS: already patched @%p\n",
                    fn_at);
            } else {
                // Sanity: expected first instruction is ADRP (the ivar load).
                BOOL is_adrp = ((cur0 & 0x9F000000) == 0x90000000);
                if (!is_adrp) {
                    fprintf(stderr,
                        "#### MACWS_AGX_VALIDATE_ALWAYS: @%p got %#x expected"
                        " ADRP — skip\n",
                        fn_at, cur0);
                } else {
                    ModifyExecutableRegion(fn_at, 8, ^{
                        fn_at[0] = MOVZ_W0_1;
                        fn_at[1] = RET;
                    });
                    fprintf(stderr,
                        "#### MACWS_AGX_VALIDATE_ALWAYS: patched @%p "
                        "(static 0x1e576ef94 + slide=%#zx) → always YES\n",
                        fn_at, (size_t)slide);
                }
            }
        }
#endif

        // ──────────────────────────────────────────────────────────────────
        // External __auth_stub patcher (MACWS_AGX_NATIVE-gated).
        //
        // The chained-fixups walker above repairs slots INSIDE this image's
        // own __got / __auth_got sections. But AGXMetal13_3 was extracted
        // from the dyld_shared_cache, and the cache builder consolidated
        // cross-image function-pointer slots (objc_msgSend, objc_msgSend\
        // Super2, libc, libobjc helpers, …) into shared __got pages OUTSIDE
        // individual images. For this binary they live at:
        //     0x21f927000..0x21f95b000     (15 pages, ~228 slots total)
        // none of which are in any segment of the extracted file.
        //
        // 228 of AGXMetal13_3's __auth_stubs reference one of these external
        // pages — the only 4 that stay in-image use 0x21e807000 (the local
        // __auth_got). Walking chained-fixups can't reach the external slots:
        // they have no fixup record because they were inlined into the cache
        // at cache-build time.
        //
        // In chroot the pages are not mapped at the runtime VA the stubs
        // compute (or they land in whatever happens to be at that VA from a
        // neighboring mapping — e.g. MediaToolbox). `ldr x16, [x17] ; braa
        // x16, x17` then reads garbage and either auth-traps or tail-calls
        // the wrong function.
        //
        // Worked example confirmed via BN macOS DSC analysis this session:
        //   stub @ 0x1e5a5dfc0 = adrp 0x21f95b000 + #0xca8 = slot 0x21f95bca8
        //   slot in cache holds &_objc_msgSendSuper2
        //   xrefs to sub_1e5a5dfc0 confirm 100+ -[…super dealloc] /
        //     [super initWith…] call sites pass through this stub
        //   in chroot the slot is wrong → super-init returns 0 →
        //     -[AGXTexture initWithDevice:desc:iosurface:plane:] nil-exits →
        //     newTextureWithDescriptor:iosurface:plane: = nil →
        //     SkyLight's framebuffer wrap fails.
        //
        // Fix: rewrite the 4-instruction stub with a direct absolute jump:
        //     movz x16, #lo16
        //     movk x16, #mid16, lsl #16
        //     movk x16, #hi16, lsl #32          ; user-space VA is 48-bit
        //     br   x16                          ; unauthenticated br
        // Same byte count (16). No PAC modulus issues; br is not authed and
        // the stub itself lives in __TEXT which we already write through
        // ModifyExecutableRegion elsewhere.
        //
        // Bootstrap the slot-offset→symbol map with the highest-value entry
        // (msgSendSuper2). Extend as more broken paths are identified by
        // crash-log triage.
        if (getenv("MACWS_AGX_NATIVE")) {
            struct stub_repair {
                uint64_t    stub_static;
                uint64_t    slot_static;   // expected adrp(page)+add(off) for logging
                const char *symbol;
            };
            static const struct stub_repair repairs[] = {
                // sub_1e5a5dfc0 — adrp 0x21f95b000 + #0xca8 = slot 0x21f95bca8.
                // Slot holds _objc_msgSendSuper2 in the macOS DSC; the stub
                // is the super-init / super-dealloc dispatcher for every
                // class in this image.
                { 0x1e5a5dfc0, 0x21f95bca8, "objc_msgSendSuper2" },
            };
            for (size_t i = 0; i < sizeof(repairs)/sizeof(repairs[0]); i++) {
                const struct stub_repair *r = &repairs[i];
                void *fn = dlsym(RTLD_DEFAULT, r->symbol);
                if (!fn) {
                    fprintf(stderr, "#### MACWS_AGX_STUB_FIX dlsym(%s)=NULL skip\n",
                        r->symbol);
                    continue;
                }
                uint32_t *stub_at      = (uint32_t *)(r->stub_static + slide);
                void    **slot_runtime = (void **)   (r->slot_static + slide);

                uint32_t cur0 = stub_at[0], cur1 = stub_at[1];
                uint32_t cur2 = stub_at[2], cur3 = stub_at[3];

                // Read slot value defensively — VA may not be mapped.
                void *cur_slot = NULL;
                Dl_info di = {0};
                int dlinfo_ok = 0;
                @try {
                    cur_slot = *slot_runtime;
                    dlinfo_ok = dladdr(cur_slot, &di);
                } @catch (id e) {
                    cur_slot = (void *)-1;
                    dlinfo_ok = 0;
                }
                fprintf(stderr,
                    "#### MACWS_AGX_STUB_FIX %s\n"
                    "####   stub@%p insns=[%08x %08x %08x %08x]\n"
                    "####   slot@%p value=%p sym=%s base=%p path=%s\n",
                    r->symbol, stub_at, cur0, cur1, cur2, cur3,
                    slot_runtime, cur_slot,
                    dlinfo_ok ? (di.dli_sname ?: "(none)") : "(no-mapping)",
                    dlinfo_ok ? di.dli_fbase : NULL,
                    dlinfo_ok ? (di.dli_fname ?: "(none)") : "(none)");

                // Build movz/movk/movk/br x16 → fn. (4 named vars, not an
                // array — blocks can't capture C arrays directly.)
                uint64_t t  = (uint64_t)fn;
                uint16_t i0 = (uint16_t)( t        & 0xFFFF);
                uint16_t i1 = (uint16_t)((t >> 16) & 0xFFFF);
                uint16_t i2 = (uint16_t)((t >> 32) & 0xFFFF);
                const uint32_t Rd = 16;   // x16
                uint32_t insn0 = 0xD2800000u | ((uint32_t)i0 << 5) | Rd; // movz x16,#i0
                uint32_t insn1 = 0xF2A00000u | ((uint32_t)i1 << 5) | Rd; // movk x16,#i1,#16
                uint32_t insn2 = 0xF2C00000u | ((uint32_t)i2 << 5) | Rd; // movk x16,#i2,#32
                uint32_t insn3 = 0xD61F0200u;                            // br   x16

                BOOL already_patched = (cur0 == insn0 && cur1 == insn1 &&
                                        cur2 == insn2 && cur3 == insn3);
                if (already_patched) {
                    fprintf(stderr, "####   already patched, skipping\n");
                    continue;
                }
                // Sanity: top of original insn must look like ADRP.
                //   ADRP encoding: bit31=1, bits28:24=10000 → mask 0x9F000000 == 0x90000000
                BOOL is_adrp = ((cur0 & 0x9F000000) == 0x90000000);
                if (!is_adrp) {
                    fprintf(stderr, "####   first insn %#x not ADRP — skip\n", cur0);
                    continue;
                }
                ModifyExecutableRegion(stub_at, 16, ^{
                    stub_at[0] = insn0;
                    stub_at[1] = insn1;
                    stub_at[2] = insn2;
                    stub_at[3] = insn3;
                });
                fprintf(stderr,
                    "####   PATCHED → br %p (movz/movk/movk/br)\n"
                    "####   new=[%08x %08x %08x %08x]\n",
                    fn, insn0, insn1, insn2, insn3);
            }
        }

        // ──────────────────────────────────────────────────────────────────
        // EVERYTHING BELOW (class registration via objc_readClassPair, AGX
        // class-method swizzles, initFull subDis fix) is gated behind
        // MACWS_AGX_REGISTER_CLASSES=1. This is the still-experimental "full
        // strict AGX-native" path. Default off so the prior stable baseline
        // (MACWS_AGX_NATIVE=1 only → MTLSim path with stable nil-tolerate
        // hooks) keeps working without regressions.
        if (!getenv("MACWS_AGX_REGISTER_CLASSES")) {
            return;
        }
        // Diagnostic: check if AGXBuffer class is registered + __objc_classrefs
        // entries are populated. The Mempool::grow lambda calls
        // objc_alloc(AGXBuffer) — if the class ref slot at __objc_classrefs is
        // null, alloc returns nil and crashes downstream at addr 0x30 (the
        // *(this+0x28) deref).
        Class agxbuf = objc_getClass("AGXBuffer");
        fprintf(stderr, "#### MACWS_AGX_NATIVE objc_getClass(AGXBuffer) = %p\n", (void *)agxbuf);

        // Read __objc_classlist — list of pointers to OUR OWN classes. If
        // libobjc didn't process them (callback skipped due to dlopen path),
        // we can register them manually.
        unsigned long classlist_sz = 0;
        uint64_t *classlist = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__objc_classlist", &classlist_sz);
        if (!classlist) {
            classlist = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__objc_classlist", &classlist_sz);
        }
        if (classlist) {
            size_t n = classlist_sz / 8;
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classlist: %zu entries\n", n);
            // Dump first 6 with class name
            for (size_t i = 0; i < n && i < 6; i++) {
                if (classlist[i] == 0) continue;
                Class c = (Class)classlist[i];
                const char *name = class_getName(c);
                fprintf(stderr, "####   classlist[%zu] = %p name=%s registered=%p\n",
                    i, (void *)c, name ?: "?", (void *)objc_getClass(name ?: ""));
            }
            // Force registration by calling _objc_init-equivalent machinery:
            // libobjc's `_dyld_objc_register_callbacks` or `_objc_map_images`.
            // Alternatively: walk __objc_classlist, for each non-null class
            // pointer, call objc_registerClassPair() — but this fails on
            // already-registered classes. Try simpler: use the runtime's
            // class_addMethod/etc on each, which forces registration as a
            // side effect.
            //
            // Most reliable: directly call libobjc's `_objc_register_classes`
            // private API if exposed.
            // The classes are in classlist as RAW DATA but not in the
            // runtime's class table. dlsym a few possible APIs to register
            // them. Failing all those, use the runtime trick of allocating
            // a temporary class pair and then PIVOTING the existing class to
            // it via objc_setClass on instances — but that's incomplete.
            //
            // Most reliable: call `objc_duplicateClass(orig_cls, new_name)`
            // to register via class duplication. Or use the dyld objc
            // notification API by re-registering ourselves.
            void (*objc_duplicate)(Class, const char *, size_t) = dlsym(
                RTLD_DEFAULT, "objc_duplicateClass");
            fprintf(stderr, "#### MACWS_AGX_NATIVE objc_duplicateClass=%p\n",
                (void *)objc_duplicate);

            // Register each class with libobjc via objc_readClassPair.
            //
            // ROOT CAUSE of `objc_getClass("AGXBuffer") = 0x0`:
            //   AGXMetal13_3 is loaded by Metal.framework's eager constructor
            //   BEFORE libmachook's loadImageCallback can run. In a normal
            //   process flow, libobjc's _dyld_objc_notify_register callback
            //   processes __objc_classlist and adds each class to
            //   gdb_objc_realized_classes (the name → class hash). But in
            //   chroot, that processing never reached the AGXMetal13_3 entries
            //   (likely because Metal loads AGXMetal13_3 via a private dyld
            //   path that bypasses the notify hook, or because the load order
            //   races with libmachook's pre-load IOGPU dlopen).
            //
            //   Result: class STRUCT DATA is fully valid — class_getName,
            //   class_getSuperclass, class_isMetaClass all work — but
            //   objc_getClass(name) returns NULL because the name table was
            //   never populated.
            //
            // FIX: walk __objc_classlist, call objc_readClassPair on each
            //   entry. objc_readClassPair both calls readClass (which adds to
            //   gdb_objc_realized_classes) and realizeClassWithoutSwift (which
            //   sets up the cache / method tables). After this loop completes,
            //   objc_getClass("AGXBuffer") returns the right pointer and
            //   [AGXBuffer alloc] returns a real, usable instance.
            //
            // Get __objc_imageinfo (required arg to objc_readClassPair).
            typedef struct { uint32_t version; uint32_t flags; } objc_image_info_t;
            unsigned long iinfo_sz = 0;
            objc_image_info_t *iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__DATA_CONST", "__objc_imageinfo", &iinfo_sz);
            if (!iinfo) iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__DATA", "__objc_imageinfo", &iinfo_sz);
            if (!iinfo) iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__OBJC", "__image_info", &iinfo_sz);
            fprintf(stderr, "#### MACWS_AGX_NATIVE imageinfo=%p sz=%lu\n",
                (void *)iinfo, iinfo_sz);

            typedef Class (*readPair_t)(Class, const void *);
            readPair_t readPair = (readPair_t)dlsym(RTLD_DEFAULT, "objc_readClassPair");
            int realized = 0;
            // Cross-image preregistration: previously this loop only walked
            // AGXMetal13_3's own __objc_classlist, so a class whose superclass
            // lives in another framework (e.g. AGXBuffer -> IOGPUMetalBuffer in
            // IOGPU.framework) failed because readClassPair needs the super to
            // already be in libobjc's name table. In chroot, the libobjc
            // _dyld_objc_notify_register callback misses IOGPU's classlist for
            // the same reason it misses AGXMetal's — so we have to register
            // every loaded image's pending classes here, not just our own.
            // Walks _dyld_image_count() and, for any image carrying a
            // __objc_classlist + __objc_imageinfo, runs the same multi-pass
            // readPair loop. IOGPU goes first because it's a parent of
            // AGXBuffer/AGXG13GFamilyBuffer/AGXG13GFamilyCommandBuffer/…
            // Per-image cap of 8 passes catches deep super chains.
            if (readPair) {
                uint32_t img_count = _dyld_image_count();
                for (uint32_t img_i = 0; img_i < img_count; img_i++) {
                    const struct mach_header *imgh = _dyld_get_image_header(img_i);
                    if (!imgh) continue;
                    const char *imgname = _dyld_get_image_name(img_i);
                    unsigned long cl_sz = 0;
                    uint64_t *cl = (uint64_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA_CONST",
                        "__objc_classlist", &cl_sz);
                    if (!cl) cl = (uint64_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA",
                        "__objc_classlist", &cl_sz);
                    if (!cl || cl_sz == 0) continue;
                    unsigned long ii_sz = 0;
                    objc_image_info_t *ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA_CONST",
                        "__objc_imageinfo", &ii_sz);
                    if (!ii) ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA",
                        "__objc_imageinfo", &ii_sz);
                    if (!ii) ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__OBJC",
                        "__image_info", &ii_sz);
                    if (!ii) continue;
                    size_t nn = cl_sz / 8;
                    int img_realized = 0;
                    int img_pending = 0;
                    for (size_t i = 0; i < nn; i++) {
                        if (cl[i] == 0) continue;
                        Class cc = (Class)cl[i];
                        const char *nm = class_getName(cc);
                        if (nm && nm[0] && !objc_getClass(nm)) img_pending++;
                    }
                    if (img_pending == 0) continue;
                    for (int pass = 0; pass < 8; pass++) {
                        int tp = 0;
                        for (size_t i = 0; i < nn; i++) {
                            if (cl[i] == 0) continue;
                            Class cc = (Class)cl[i];
                            const char *nm = class_getName(cc);
                            if (!nm || !nm[0]) continue;
                            if (objc_getClass(nm)) continue;
                            Class rr = readPair(cc, ii);
                            if (rr && objc_getClass(nm)) { img_realized++; tp++; }
                        }
                        if (tp == 0) break;
                    }
                    realized += img_realized;
                    const char *bn = strrchr(imgname ? imgname : "", '/');
                    bn = bn ? bn + 1 : (imgname ? imgname : "?");
                    if (img_realized > 0) {
                        fprintf(stderr,
                            "#### PREREGISTER image[%u] %s: %d/%d realized\n",
                            img_i, bn, img_realized, img_pending);
                    }
                }
            }
            // Now also try AGXMetal13_3's own classlist (most should already be
            // realized by the loop above since this image is in img_count too,
            // but the original multi-pass below catches any leftover surface).
            if (readPair && iinfo) {
                // Multi-pass: re-iterate if any new classes registered, so a
                // class whose superclass got registered in pass N can register
                // in pass N+1.
                for (int pass = 0; pass < 3; pass++) {
                    int this_pass = 0;
                    for (size_t i = 0; i < n; i++) {
                        if (classlist[i] == 0) continue;
                        Class c = (Class)classlist[i];
                        const char *name = class_getName(c);
                        if (!name || !name[0]) continue;
                        if (objc_getClass(name)) continue;  // registered
                        Class result = readPair(c, iinfo);
                        if (result && objc_getClass(name)) {
                            realized++;
                            this_pass++;
                            if (realized < 6) {
                                fprintf(stderr, "####   registered %s -> %p\n",
                                    name, (void *)result);
                            }
                        } else {
                            if (i < 6 && pass == 0) {
                                fprintf(stderr, "####   FAILED %s: result=%p getClass=%p\n",
                                    name, (void *)result, (void *)objc_getClass(name));
                            }
                        }
                    }
                    fprintf(stderr, "#### MACWS_AGX_NATIVE register pass %d: %d new (total %d)\n",
                        pass, this_pass, realized);
                    if (this_pass == 0) break;
                }
            } else {
                fprintf(stderr, "#### MACWS_AGX_NATIVE readPair=%p iinfo=%p — CANNOT REGISTER\n",
                    (void *)readPair, (void *)iinfo);
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE realized %d/%zu classes\n", realized, n);
            Class agxbuf_after = objc_getClass("AGXBuffer");
            fprintf(stderr, "#### MACWS_AGX_NATIVE AGXBuffer after register: %p\n",
                (void *)agxbuf_after);
            if (getenv("MACWS_AGX_DUMP_METHODS") ||
                access("/private/tmp/macws_agx_dump_methods", F_OK) == 0) {
                macws_dump_agx_method_map();
            }
            if (access("/private/tmp/macws_agx_trace_reserve", F_OK) == 0) {
                macws_install_agx_reserve_trace();
            }
            // Also try sending +alloc to verify the registered class is usable.
            if (agxbuf_after) {
                @try {
                    id inst = ((id (*)(id, SEL))objc_msgSend)(
                        (id)agxbuf_after, sel_registerName("alloc"));
                    fprintf(stderr, "#### MACWS_AGX_NATIVE [AGXBuffer alloc] = %p\n",
                        (void *)inst);
                } @catch (NSException *e) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE [AGXBuffer alloc] threw: %s\n",
                        [[e description] UTF8String] ?: "?");
                }

                // Swizzle initUntrackedInternalBufferWithDevice:length:options:
                // and initWithDevice:length:alignment:options:isSuballocDisabled:
                // resourceInArgs:pinnedGPULocation: so we can trace what these
                // return in the AGX::Mempool::grow lambda hot path. If they
                // return nil, Mempool+0x8 stays NULL and setupDeferred crashes
                // dereferencing it at addr 0x30. Tracing tells us whether the
                // problem is alloc-side (class invalid) or IOGPU-side (kernel
                // resource creation fails).
                SEL initUntracked = sel_registerName("initUntrackedInternalBufferWithDevice:length:options:");
                Method m_unt = class_getInstanceMethod(agxbuf_after, initUntracked);
                if (m_unt) {
                    IMP orig_unt = method_getImplementation(m_unt);
                    IMP trace_unt = imp_implementationWithBlock(^id(id self, id dev, unsigned long len, unsigned long opt) {
                        id r = ((id (*)(id, SEL, id, unsigned long, unsigned long))orig_unt)(
                            self, initUntracked, dev, len, opt);
                        fprintf(stderr,
                            "#### TRACE -[AGXBuffer initUntracked] self=%p dev=%p len=%lu opt=%lu -> %p\n",
                            self, dev, len, opt, r);
                        return r;
                    });
                    method_setImplementation(m_unt, trace_unt);
                    fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled initUntrackedInternalBufferWithDevice:length:options:\n");
                }
                SEL initFull = sel_registerName("initWithDevice:length:alignment:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:");
                Method m_full = class_getInstanceMethod(agxbuf_after, initFull);
                if (m_full) {
                    IMP orig_full = method_getImplementation(m_full);
                    IMP trace_full = imp_implementationWithBlock(^id(id self, id dev, unsigned long len, unsigned long align, unsigned long opt, int subDis, void *resInArgs, void *pinned) {
                        // Capture class BEFORE orig in case it releases self.
                        Class pre_cls_full = object_getClass(self);
                        uint64_t previous_init_len = g_macws_agx_initfull_len;
                        g_macws_agx_initfull_len = len;
                        // iOS IOGPU's kernel sub-resource creation rejects
                        // align=1 with kIOReturnExclusiveAccess (0xe00002c2)
                        // for every length tier — Mempool::grow's freelist
                        // columns (len=64/384), QuartzCore staging buffers
                        // (len=8192), MetalContext scratch (len=131072), …
                        // all fail in chroot with align=1. Forcing align=64 +
                        // isSuballocDisabled=1 routes through the standalone-
                        // heap branch which the kernel accepts at any size.
                        // Confirmed 2026-06-18 by side-by-side trace.
                        //
                        // Side effect: the standalone branch creates a fresh
                        // heap, so each align=1 AGXBuffer now pays a heap-
                        // alloc syscall instead of a sub-resource slot from
                        // an existing heap. That's a slowdown but not a
                        // correctness issue for chroot WS.
                        int subDis_eff = subDis;
                        unsigned long align_eff = align;
                        if (align <= 1) {
                            align_eff = 64;
                            // isSuballocDisabled=1 routes through standalone-
                            // heap branch which the kernel accepts for any
                            // size when align=1 in chroot. BUT for medium-
                            // large lengths (>= 64KB) the standalone branch
                            // ends up using the device's small default heap
                            // (clientID 0x4000, 4KB) as parent and the
                            // sub-resource creation fails because the parent
                            // is too small. The medium/large align=1 callers
                            // (QuartzCore staging buffers) work fine with
                            // subDis=0 + align=64 because macOS's normal
                            // sub-resource path picks the right big heap.
                            // Cap the subDis=1 forcing at len<64KB.
                            if (len < 0x10000) subDis_eff = 1;
                        }
                        id r = ((id (*)(id, SEL, id, unsigned long, unsigned long, unsigned long, int, void *, void *))orig_full)(
                            self, initFull, dev, len, align_eff, opt, subDis_eff, resInArgs, pinned);
                        if (!r && (subDis_eff != subDis || align_eff != align)) {
                            // Forced path failed; retry with original args.
                            r = ((id (*)(id, SEL, id, unsigned long, unsigned long, unsigned long, int, void *, void *))orig_full)(
                                self, initFull, dev, len, align, opt, subDis, resInArgs, pinned);
                        }
                        // Mempool::grow's freelist-init loop reads
                        // `*(buf + global + 0x18)` (= *(buf+0x30) with the
                        // global symbol IOGPU.IOGPUMetalResource._res = 0x18)
                        // and writes sequential ints there. For our synth
                        // path we already populate that ivar from baseAddr.
                        // For the "orig-succeed" path (small buffers via
                        // align=64+subDis=1), the buf comes back with all
                        // ivars zero — including +0x30 — and Mempool's freelist
                        // init then null-derefs. Allocate a per-buf scratch
                        // (4 KB) and point +0x30 at it so the freelist init
                        // writes land in valid memory. Use malloc since the
                        // GPU never touches this region (it's freelist
                        // bookkeeping, not buffer contents).
                        if (r && ((void **)r)[6] == NULL) {
                            // 16 KB is enough for sequential-int freelist init
                            // (~15 entries) plus memcpy-grow expansion of the
                            // Mempool's internal counters. dealloc later free()s
                            // this pointer — AGX driver writes sentinel values
                            // (e.g. 0x1) into it for its own freelist tracking,
                            // which corrupts the default malloc free list on
                            // dealloc. Route through a private zone so the
                            // corruption stays isolated and the default zone's
                            // free list stays intact.
                            malloc_zone_t *zone = macws_synth_scratch_zone();
                            void *scratch = zone ?
                                malloc_zone_calloc(zone, 1, 16384) :
                                calloc(1, 16384);
                            if (scratch) {
                                ((void **)r)[6] = scratch;
                                static int fl_log = 0;
                                if (fl_log++ < 4) {
                                    fprintf(stderr,
                                        "#### initFull freelist-scratch: buf=%p ivar+0x30 ← %p (private-zone)\n",
                                        r, scratch);
                                }
                            }
                        }
                        // PIN-FALLBACK (MACWS_PIN_FALLBACK=1): when the 7-arg
                        // initFull returns nil (chroot kernel rejected the
                        // resInArgs-shaped IOConnect call), try the 6-arg
                        // `initWithDevice:length:options:isSuballocDisabled:
                        // pinnedGPULocation:` variant that PinnedVAProbe proved
                        // works in iOS-native userland end-to-end (alloc +
                        // compute write-through + blit roundtrip — see
                        // [[pinned-gpu-va-exists-in-ios-userland]]). The
                        // pinnedGPULocation: argument is a pointer to a u64
                        // holding the desired GPU VA; passing 0 lets the
                        // framework pick. Logs both empirical signal (does it
                        // work in chroot at all?) and wires up a real fallback
                        // if it does.
                        if (!r && getenv("MACWS_PIN_FALLBACK")) {
                            static SEL pin5_sel = NULL;
                            static int pin5_known_missing = 0;
                            if (!pin5_sel) {
                                pin5_sel = sel_registerName(
                                    "initWithDevice:length:options:isSuballocDisabled:pinnedGPULocation:");
                            }
                            // pre_cls_full was captured at block entry before
                            // orig consumed self (object_getClass(self) returns
                            // nil after orig freed self).
                            Class cls = pre_cls_full ?: object_getClass(self);
                            if (!pin5_known_missing && cls &&
                                class_getInstanceMethod(cls, pin5_sel)) {
                                // Fresh +alloc: the failed initFull consumed `self`.
                                id raw = ((id (*)(Class, SEL))objc_msgSend)(
                                    cls, sel_registerName("alloc"));
                                uint64_t pinVA = 0;  // framework picks
                                typedef id (*Pin5Fn)(id, SEL, id, unsigned long,
                                                      unsigned long, int, uint64_t *);
                                Pin5Fn pin5 = (Pin5Fn)objc_msgSend;
                                id pr = pin5(raw, pin5_sel, dev, len, opt, 1, &pinVA);
                                static int fb_log = 0;
                                if (fb_log++ < 12) {
                                    fprintf(stderr,
                                        "#### PIN_FALLBACK %s len=%lu opt=%lu -> %p (pinVA=%#llx)\n",
                                        class_getName(cls), len, opt,
                                        (void *)pr, (unsigned long long)pinVA);
                                }
                                if (pr) r = pr;
                            } else if (!pin5_known_missing) {
                                pin5_known_missing = 1;
                                fprintf(stderr,
                                    "#### PIN_FALLBACK: class %s does NOT respond to 5-colon pinnedGPULocation: selector\n",
                                    cls ? class_getName(cls) : "(nil)");
                            }
                        }
                        static int trace_cnt = 0;
                        if (trace_cnt++ < 12) {
                            fprintf(stderr,
                                "#### TRACE -[AGXBuffer initFull] self=%p dev=%p len=%lu align=%lu→%lu opt=%lu subDis=%d→%d resIn=%p pin=%p -> %p\n",
                                self, dev, len, align, align_eff, opt, subDis, subDis_eff, resInArgs, pinned, r);
                        }
                        g_macws_agx_initfull_len = previous_init_len;
                        return r;
                    });
                    method_setImplementation(m_full, trace_full);
                    fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled initWithDevice:length:alignment:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:\n");
                }

                // Observe the 4-argument IOGPU resource initializer without
                // changing its contract.  An older diagnostic fallback returned
                // a bare +alloc AGXG13GFamilyBuffer when this initializer failed.
                // Project-LLDB caught the resulting object in
                // IOGPUMetalCommandBufferStorageAllocResourceAtIndex: `_res`
                // (ivar +0x18) was NULL, so ResourceInfo remained zero and
                // RenderUSCStateLoader later wrote through address 0x7e0.  A
                // failed real initializer must therefore remain nil; the
                // upstream IOConnect failure is the boundary to diagnose.
                {
                    SEL initArgs = sel_registerName("initWithDevice:options:args:argsSize:");
                    Method m_args = class_getInstanceMethod(agxbuf_after, initArgs);
                    if (m_args && getenv("MACWS_PIN_FALLBACK")) {
                        IMP orig_args = method_getImplementation(m_args);
                        IMP trace_args = imp_implementationWithBlock(^id(
                                id self, id dev, unsigned long opt,
                                void *args, unsigned long argsSize) {
                            Class pre_cls = object_getClass(self);
                            id r = ((id (*)(id, SEL, id, unsigned long, void *, unsigned long))orig_args)(
                                self, initArgs, dev, opt, args, argsSize);
                            static _Atomic unsigned int calls = 0;
                            static _Atomic unsigned int failures = 0;
                            unsigned int call_n = atomic_fetch_add(&calls, 1) + 1;
                            if (!r) {
                                unsigned int fail_n = atomic_fetch_add(&failures, 1) + 1;
                                fprintf(stderr,
                                    "#### AGX_INITARGS FAIL #%u/%u cls=%s dev=%p opt=%#lx args=%p argsSize=%lu — preserving nil\n",
                                    fail_n, call_n,
                                    pre_cls ? class_getName(pre_cls) : "(nil)",
                                    dev, opt, args, argsSize);
                                if (fail_n <= 8 && args && argsSize <= 0x200) {
                                    const uint8_t *a = (const uint8_t *)args;
                                    for (size_t i = 0; i < argsSize; i += 16) {
                                        fprintf(stderr, "####   initargs+%#04zx:", i);
                                        for (size_t j = 0; j < 16 && i + j < argsSize; j++)
                                            fprintf(stderr, " %02x", a[i + j]);
                                        fprintf(stderr, "\n");
                                    }
                                }
                            }
                            return r;
                        });
                        method_setImplementation(m_args, trace_args);
                        fprintf(stderr,
                            "#### MACWS_AGX_NATIVE tracing -[AGXBuffer initWithDevice:options:args:argsSize:] (nil preserved)\n");
                    }
                }
            }

            // Probe what libobjc class-registration symbols are exposed in this
            // libobjc build. Goal: find a callable function that takes a
            // pre-existing class struct (from __objc_classlist) and adds it
            // to gdb_objc_realized_classes (name → class map). Without that
            // table entry, objc_getClass(name) returns NULL even though the
            // class data exists at a known pointer.
            const char *libobjc_apis[] = {
                "objc_addClass",
                "_objc_addClass",
                "_objc_addClass_quiet",
                "objc_constructInstance",
                "_dyld_objc_notify_register",
                "_dyld_objc_register_callbacks",
                "_objc_loadDebug",
                "objc_readClassPair",
                "objc_registerClassPair",
                "_objc_register_class",
                "_objc_realizeClassFromSwift",
                "objc_realizeClassFromSwift",
                "_objc_addLoadImageFunc",
                "objc_addLoadImageFunc",
                "_objc_swiftMetadataInitializer",
                "_objc_remappedClasses",
                "_read_images",
                "map_images",
                "map_images_nolock",
                "_objc_init",
                NULL
            };
            for (int i = 0; libobjc_apis[i]; i++) {
                void *p = dlsym(RTLD_DEFAULT, libobjc_apis[i]);
                if (p) fprintf(stderr, "#### LIBOBJC dlsym(%s) = %p\n",
                                libobjc_apis[i], p);
            }

            // For each AGX class we found, dump:
            //   class ptr, name, superclass ptr, superclass name (if reachable),
            //   isMeta flag, classref-target-name.
            // This pinpoints whether class structs are corrupt or whether it's
            // purely a name-table miss.
            for (size_t i = 0; i < n && i < 16; i++) {
                if (classlist[i] == 0) continue;
                Class c = (Class)classlist[i];
                const char *name = class_getName(c);
                Class sc = class_getSuperclass(c);
                const char *scname = sc ? class_getName(sc) : "(nil)";
                BOOL meta = class_isMetaClass(c);
                fprintf(stderr,
                    "#### CLASS_DETAIL [%zu] %p name=%s super=%p (%s) meta=%d\n",
                    i, (void *)c, name ?: "?", (void *)sc, scname ?: "?", meta);
            }
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classlist NOT FOUND\n");
        }
        // Walk __objc_classrefs section: read each pointer entry.
        unsigned long classrefs_sz = 0;
        uint64_t *classrefs = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA", "__objc_classrefs", &classrefs_sz);
        if (classrefs) {
            size_t n = classrefs_sz / 8;
            int nulls = 0;
            for (size_t i = 0; i < n; i++) {
                if (classrefs[i] == 0) nulls++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classrefs: %zu entries, %d null\n", n, nulls);
            // Try to fix nulls by reading class name from neighboring metadata
            // and replacing with objc_getClass result. We don't have direct
            // mapping from classref slot to class name in stripped binaries —
            // but we have ALL OUR OWN classes in __objc_classlist which IS
            // populated. So our best bet is: dlsym OBJC_CLASS_$_NAME for known
            // AGX classes and patch their slot.
            const char *known_agx_classes[] = {
                "AGXBuffer",
                "AGXCommandQueue",
                "AGXCommandBuffer",
                "AGXMetalCommandQueue",
                "AGXMetalCommandBuffer",
                "AGXMetalBuffer",
                "AGXMetalTexture",
                "AGXMetalHeap",
                "AGXMetalResource",
                "AGXMetalDevice",
                "AGXMetalFence",
                "AGXTexture",
                "IOGPUMetalBuffer",
                "IOGPUMetalCommandBuffer",
                "IOGPUMetalCommandQueue",
                "IOGPUMetalDevice",
                "IOGPUMetalHeap",
                "IOGPUMetalResource",
                "IOGPUMetalTexture",
                "IOGPUMetalFence",
                "IOGPUMTLLateEvalEvent",
                NULL
            };
            for (int i = 0; known_agx_classes[i]; i++) {
                Class c = objc_getClass(known_agx_classes[i]);
                fprintf(stderr, "####   class %s = %p\n", known_agx_classes[i], (void *)c);
            }
            // Dump first 16 classrefs: deref each pointer, get class_getName.
            // If class_getName returns valid AGX name → classref points to OUR
            // class data (the bind worked, the slot just isn't realized in
            // libobjc's name table). If name is junk or addr is bad → bind
            // never happened and the slot points to stale/null garbage.
            for (size_t i = 0; i < n && i < 24; i++) {
                uint64_t cp = classrefs[i];
                if (cp == 0) {
                    fprintf(stderr, "#### CLASSREF [%zu] @%p = NULL\n",
                        i, (void *)&classrefs[i]);
                    continue;
                }
                const char *nm = "?";
                @try {
                    nm = class_getName((Class)cp) ?: "?";
                } @catch (NSException *e) {
                    nm = "(crash)";
                }
                fprintf(stderr, "#### CLASSREF [%zu] @%p -> %p name=%s\n",
                    i, (void *)&classrefs[i], (void *)cp, nm);
            }
        }

        // Walk LC_DYLD_CHAINED_FIXUPS and patch each null import bind by
        // resolving the symbol via dlsym(RTLD_DEFAULT). This repairs the
        // cross-image bindings that chroot dyld failed to resolve at load
        // time (especially IOGPU symbols). After this runs, the lambda in
        // Mempool::grow can safely tail-call its target.
        macws_walk_chained_fixups((const struct mach_header_64 *)header, vmaddr_slide, "AGXMetal13_3");

        // Diagnostic: enumerate __auth_got entries and report how many are null.
        // If null entries are present → cross-image binding failed in chroot dyld
        // and we'd need the chained-fixup walker to repair. If all are populated
        // → binding worked and the lambda crash is from a different cause.
        unsigned long auth_got_sz = 0;
        uint64_t *auth_got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__auth_got", &auth_got_sz);
        if (!auth_got) {
            auth_got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__auth_got", &auth_got_sz);
        }
        if (auth_got) {
            size_t entries = auth_got_sz / 8;
            int nulls = 0, nonnull = 0;
            for (size_t i = 0; i < entries; i++) {
                if (auth_got[i] == 0) nulls++;
                else nonnull++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __auth_got: %zu entries, %d null, %d non-null\n",
                entries, nulls, nonnull);
            // Dump first 8 entries
            for (size_t i = 0; i < entries && i < 8; i++) {
                fprintf(stderr, "####   auth_got[%zu] @%p = 0x%016llx\n",
                    i, (void *)&auth_got[i], (unsigned long long)auth_got[i]);
            }
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __auth_got section NOT FOUND\n");
        }
        unsigned long got_sz = 0;
        uint64_t *got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__got", &got_sz);
        if (!got) {
            got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__got", &got_sz);
        }
        if (got) {
            size_t entries = got_sz / 8;
            int nulls = 0, nonnull = 0;
            for (size_t i = 0; i < entries; i++) {
                if (got[i] == 0) nulls++;
                else nonnull++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __got: %zu entries, %d null, %d non-null\n",
                entries, nulls, nonnull);
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __got section NOT FOUND\n");
        }

    }
}

// MACWS_AGX_CRASH_DIAG: install SIGSEGV/SIGBUS/SIGILL handlers so the faulting
// PC (slid + unslid) and backtrace land in stderr before the process exits.
// Faster than racing lldb against a short-lived crash. Gated by env var so
// production runs aren't affected.
#import <execinfo.h>
#import <dlfcn.h>
#import <unistd.h>
// mach_vm.h is marked unsupported in the iOS SDK; declare the one symbol
// we need so we can fail-safe read potentially-bad pointers.
extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size,
    mach_vm_address_t data, mach_vm_size_t *outsize);
extern kern_return_t mach_vm_allocate(
    vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_region(
    vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t *size,
    vm_region_flavor_t flavor, vm_region_info_t info,
    mach_msg_type_number_t *info_count, mach_port_t *object_name);

// Crash handler emits ALL diagnostic lines into a single static buffer then
// flushes via one write(2). Mixing fprintf calls from a signal handler with
// log lines from other threads scrambled the backtrace beyond use; an atomic
// write keeps the trace contiguous.
#define MACWS_CRASH_BUF_LEN 16384
static char macws_crash_buf[MACWS_CRASH_BUF_LEN];

static const char *macws_si_code_string(int signo, int code) {
    if (signo == SIGBUS) {
        if (code == BUS_ADRALN)  return "BUS_ADRALN (misaligned)";
        if (code == BUS_ADRERR)  return "BUS_ADRERR (nonexistent phys addr)";
        if (code == BUS_OBJERR)  return "BUS_OBJERR (hw object error)";
    } else if (signo == SIGSEGV) {
        if (code == SEGV_MAPERR) return "SEGV_MAPERR (unmapped)";
        if (code == SEGV_ACCERR) return "SEGV_ACCERR (permission)";
    } else if (signo == SIGILL) {
        if (code == ILL_ILLOPC)  return "ILL_ILLOPC (illegal opcode)";
        if (code == ILL_ILLTRP)  return "ILL_ILLTRP (illegal trap)";
        if (code == ILL_PRVOPC)  return "ILL_PRVOPC (priv opcode)";
        if (code == ILL_BADSTK)  return "ILL_BADSTK (bad stack)";
    }
    return "?";
}

static void macws_crash_diag_handler(int signo, siginfo_t *info, void *uctx_) {
    ucontext_t *uctx = (ucontext_t *)uctx_;
    uintptr_t pc = 0, lr = 0, fp = 0, sp = 0;
    uintptr_t fault_addr = (uintptr_t)(info ? info->si_addr : 0);
    int si_code = info ? info->si_code : 0;
#if defined(__arm64__) || defined(__arm64e__)
    if (uctx && uctx->uc_mcontext) {
        pc = (uintptr_t)arm_thread_state64_get_pc(uctx->uc_mcontext->__ss);
        lr = (uintptr_t)arm_thread_state64_get_lr(uctx->uc_mcontext->__ss);
        fp = (uintptr_t)arm_thread_state64_get_fp(uctx->uc_mcontext->__ss);
        sp = (uintptr_t)arm_thread_state64_get_sp(uctx->uc_mcontext->__ss);
    }
#endif
    char *p = macws_crash_buf;
    char *end = macws_crash_buf + MACWS_CRASH_BUF_LEN;
#define APPEND(...) do { \
        if (p < end) p += snprintf(p, (size_t)(end - p), __VA_ARGS__); \
    } while (0)

    Dl_info dli;
    APPEND("\n#### MACWS_CRASH_DIAG signo=%d si_code=%d (%s) "
           "fault_addr=%p pc=%p lr=%p fp=%p sp=%p\n",
        signo, si_code, macws_si_code_string(signo, si_code),
        (void*)fault_addr, (void*)pc, (void*)lr, (void*)fp, (void*)sp);
    if (pc && dladdr((void*)pc, &dli) && dli.dli_fname) {
        uintptr_t base = (uintptr_t)dli.dli_fbase;
        APPEND("####   pc image=%s base=%p pc-base=%#llx symbol=%s+%#llx\n",
            dli.dli_fname, (void*)base, (unsigned long long)(pc - base),
            dli.dli_sname ? dli.dli_sname : "?",
            (unsigned long long)(pc - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)));
    }
    if (lr && dladdr((void*)lr, &dli) && dli.dli_fname) {
        uintptr_t base = (uintptr_t)dli.dli_fbase;
        APPEND("####   lr image=%s base=%p lr-base=%#llx symbol=%s+%#llx\n",
            dli.dli_fname, (void*)base, (unsigned long long)(lr - base),
            dli.dli_sname ? dli.dli_sname : "?",
            (unsigned long long)(lr - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)));
    }
#if defined(__arm64__) || defined(__arm64e__)
    if (uctx && uctx->uc_mcontext) {
        APPEND("####   regs x0=%p x1=%p x2=%p x3=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[0],
            (void*)uctx->uc_mcontext->__ss.__x[1],
            (void*)uctx->uc_mcontext->__ss.__x[2],
            (void*)uctx->uc_mcontext->__ss.__x[3]);
        APPEND("####   regs x4=%p x5=%p x6=%p x7=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[4],
            (void*)uctx->uc_mcontext->__ss.__x[5],
            (void*)uctx->uc_mcontext->__ss.__x[6],
            (void*)uctx->uc_mcontext->__ss.__x[7]);
        APPEND("####   regs x8=%p x9=%p x10=%p x11=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[8],
            (void*)uctx->uc_mcontext->__ss.__x[9],
            (void*)uctx->uc_mcontext->__ss.__x[10],
            (void*)uctx->uc_mcontext->__ss.__x[11]);
        APPEND("####   regs x12=%p x13=%p x14=%p x15=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[12],
            (void*)uctx->uc_mcontext->__ss.__x[13],
            (void*)uctx->uc_mcontext->__ss.__x[14],
            (void*)uctx->uc_mcontext->__ss.__x[15]);
        APPEND("####   regs x16=%p x17=%p x19=%p x20=%p x21=%p x29(fp)=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[16],
            (void*)uctx->uc_mcontext->__ss.__x[17],
            (void*)uctx->uc_mcontext->__ss.__x[19],
            (void*)uctx->uc_mcontext->__ss.__x[20],
            (void*)uctx->uc_mcontext->__ss.__x[21],
            (void*)fp);
        // For Mempool::grow / similar init crashes, x19 is usually `this`.
        // Dump 8 qwords from x19 so we can see the layout (chunks, count,
        // and the *(this+0x28) field whose dereference faults).
        uintptr_t this_p = (uintptr_t)uctx->uc_mcontext->__ss.__x[19];
        if (this_p && this_p > 0x1000 && this_p < 0x800000000000ULL) {
            uint64_t mem[8] = {0};
            mach_vm_size_t mgot = 0;
            kern_return_t mkr = mach_vm_read_overwrite(
                mach_task_self(), (mach_vm_address_t)this_p, sizeof(mem),
                (mach_vm_address_t)mem, &mgot);
            if (mkr == KERN_SUCCESS) {
                APPEND("####   x19[0x00..0x38] = %016llx %016llx %016llx %016llx\n"
                       "####                    %016llx %016llx %016llx %016llx\n",
                    mem[0], mem[1], mem[2], mem[3],
                    mem[4], mem[5], mem[6], mem[7]);
                // mem[5] is *(this+0x28). If it's a real pointer, dump its first 8 qwords too.
                uintptr_t at28 = (uintptr_t)mem[5];
                if (at28 && at28 > 0x1000 && at28 < 0x800000000000ULL) {
                    uint64_t mem2[8] = {0};
                    mach_vm_size_t m2got = 0;
                    if (mach_vm_read_overwrite(mach_task_self(),
                            (mach_vm_address_t)at28, sizeof(mem2),
                            (mach_vm_address_t)mem2, &m2got) == KERN_SUCCESS) {
                        APPEND("####   *(x19+0x28)[0..7] = %016llx %016llx %016llx %016llx\n"
                               "####                       %016llx %016llx %016llx %016llx\n",
                            mem2[0], mem2[1], mem2[2], mem2[3],
                            mem2[4], mem2[5], mem2[6], mem2[7]);
                    } else {
                        APPEND("####   *(x19+0x28)=%p but vm_read failed (unmapped)\n",
                            (void*)at28);
                    }
                }
            } else {
                APPEND("####   vm_read(x19=%p) failed kr=%d\n", (void*)this_p, mkr);
            }
        }
        // If fault_addr == pc, this is an instruction-fetch fault. Try to
        // read the 16 bytes at pc to see whether the page is even readable.
        if (pc && fault_addr == pc) {
            uint32_t insn[4] = {0,0,0,0};
            mach_vm_size_t igot = 0;
            kern_return_t ikr = mach_vm_read_overwrite(
                mach_task_self(), (mach_vm_address_t)pc,
                sizeof(insn), (mach_vm_address_t)insn, &igot);
            APPEND("####   pc bytes (vm_read kr=%d got=%llu): %08x %08x %08x %08x\n",
                ikr, (unsigned long long)igot, insn[0], insn[1], insn[2], insn[3]);
        }
        // For an ObjC fault, x0 is usually the receiver. Try to dladdr its
        // isa to see what class it claims to be.
        uintptr_t obj = (uintptr_t)uctx->uc_mcontext->__ss.__x[0];
        if (obj && obj > 0x1000 && obj < 0x800000000000ULL) {
            uintptr_t isa = 0;
            Dl_info di2;
            if (dladdr((void*)obj, &di2) && di2.dli_fname) {
                APPEND("####   x0 dladdr: %s in %s\n",
                    di2.dli_sname ?: "?", di2.dli_fname);
            }
            mach_vm_size_t got = 0;
            kern_return_t kr = mach_vm_read_overwrite(
                mach_task_self(),
                (mach_vm_address_t)obj, sizeof(uintptr_t),
                (mach_vm_address_t)&isa, &got);
            if (kr == KERN_SUCCESS && got == sizeof(uintptr_t)) {
                uintptr_t stripped = isa & 0x0000007FFFFFFFFFULL;
                APPEND("####   x0->isa=%p stripped=%p\n",
                    (void*)isa, (void*)stripped);
                if (dladdr((void*)stripped, &di2) && di2.dli_fname) {
                    APPEND("####   x0->isa dladdr: %s in %s\n",
                        di2.dli_sname ?: "?", di2.dli_fname);
                }
            } else {
                APPEND("####   x0->isa: vm_read kr=%d (obj unmapped/freed)\n",
                    kr);
            }
        }
    }
#endif
    void *frames[32];
    int nf = backtrace(frames, 32);
    APPEND("####   backtrace (%d frames):\n", nf);
    for (int i = 0; i < nf; i++) {
        if (dladdr(frames[i], &dli) && dli.dli_fname) {
            APPEND("####     [%2d] %p %s+%#llx (%s)\n", i, frames[i],
                dli.dli_sname ? dli.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)),
                dli.dli_fname);
        } else {
            APPEND("####     [%2d] %p\n", i, frames[i]);
        }
    }
#undef APPEND
    // Atomic flush.
    size_t len = (size_t)(p - macws_crash_buf);
    if (len > MACWS_CRASH_BUF_LEN) len = MACWS_CRASH_BUF_LEN;
    (void)write(STDERR_FILENO, macws_crash_buf, len);
    _exit(128 + signo);
}

static void macws_install_crash_diag(void) {
    if (!getenv("MACWS_AGX_CRASH_DIAG")) return;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = macws_crash_diag_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    fprintf(stderr, "#### MACWS_AGX_CRASH_DIAG handlers installed\n");
}

// ─── Targeted IOKit-IOHIDUnserialize bypass ──────────────────────────────
//
// The minimal fix for the IOMFBServer thread BUS_ADRALN crash. macOS
// IOKit's `_IOHIDUnserializeAndVMDealloc` takes a raw mach buffer (a
// binary plist serialized by the kernel) and feeds it through
// `CFPropertyListCreateFromStream` →
// `__CFBinaryPlistCreateObjectFiltered`. In our chroot the kernel-side
// serializer is iOS 16.3's IOKit, and the macOS 13.4 CoreFoundation
// parser builds an NSCFString whose internal char pointer lands on an
// unaligned byte. When the parser's cleanup block_invoke releases that
// string, the destructor faults with SIGBUS BUS_ADRALN inside
// `_CFRelease+0x4a4` (verified via the in-process MACWS_AGX_CRASH_DIAG
// handler — full backtrace: IOMFBServer ctor block_invoke →
// IOHIDEventSystemClientCreateWithType → IOHIDEventSystemClientRefresh →
// IOHIDEventSystemClientSetMatchingMultiple → CacheMatchingServices →
// IOHIDUnserializeAndVMDealloc → CFPropertyListCreateFromStream →
// CFBinaryPlist parse → CFRelease → objc_destructInstance → BUS_ADRALN).
//
// Stubbing this single function to return NULL skips the iOS plist parse
// without touching any of the public `IOHIDEventSystem*` APIs — those
// keep dispatching normally on the real client object, just with empty
// property data. WindowServer keeps running; we lose HID property data
// for display-related devices, which we don't have parseable copies of
// anyway.
__attribute__((unused))
static CFTypeRef hooked_IOHIDUnserializeAndVMDealloc(
        const void *buffer, mach_vm_size_t length) {
    (void)buffer; (void)length;
    return NULL;
}

// The IOHIDUnserialize symbol is internal (non-exported), so MSFindSymbol
// can't reach it. Hook the nearest PUBLIC API frame above the crash:
// `IOHIDEventSystemClientSetMatchingMultiple`. The IOMFBServer ctor block
// is the only consumer that crashes; it stores the client at +0x358 and
// then chains through SetMatchingMultiple → RegisterDeviceMatchingBlock →
// CopyServices → RegisterEventBlock → ScheduleWithRunLoop. Only the first
// of these dives into property serialization. Returning 1 (success) lets
// the block continue with an empty matching set; everything else stays
// real, so we don't have to fake out RegisterEventBlock/Schedule/etc.
static int hooked_IOHIDEventSystemClientSetMatchingMultiple_skip(
        CFTypeRef client, CFArrayRef multiple) {
    (void)client; (void)multiple;
    return 1;
}

// ─── abort_with_payload diagnostic hook ──────────────────────────────────
//
// QuartzCore's CA::OGL::MetalContext methods call abort_with_payload(13, X)
// (namespace = OS_REASON_COREANIMATION = 13) when they can't create a
// pipeline state / tile pipeline / compute pipeline / vertex shader /
// fragment shader / Metal context. There are seven such sites in the
// chroot's macOS 13.4 QuartzCore. Without runtime instrumentation we
// can't tell which one is firing — launchd only reports the namespace,
// not the reason_code or call site.
//
// This hook is a NON-INTERCEPTING diagnostic: it logs (reason_namespace,
// reason_code, reason_string, caller backtrace) and then tail-calls the
// real abort_with_payload so the process exits exactly as it would
// without the hook. That lets us identify the failing site in one run.
//
// Once the site is known, the proper fix lives in libmachook (skip the
// failing pipeline build, return a known-good replacement, …) — this
// hook is just here to find the site, not to "fix" the assert.
typedef int (*macws_abort_t)(uint32_t reason_namespace, uint64_t reason_code,
    void *payload, uint32_t payload_size, const char *reason_string,
    uint64_t reason_flags);
static macws_abort_t macws_orig_abort_with_payload = NULL;

static int hooked_abort_with_payload(uint32_t reason_namespace,
        uint64_t reason_code, void *payload, uint32_t payload_size,
        const char *reason_string, uint64_t reason_flags) {
    // Trace mode only (no survival action). Hanging the dispatch worker
    // and bypassing __assert_rtn KEPT THE PROCESS UP but left CA's
    // _state_stack non-empty, so the next MetalContext::EndUpdate
    // SEGV'd at StopCapture+0x38 on a nil shader-state pointer. The
    // real fix lives elsewhere: we need to build a real fallback
    // RenderPipelineState (vertex passthrough + simple fragment) at WS
    // init time and return it from a hook on
    // -[MTLDevice newRenderPipelineStateWithDescriptor:error:] when the
    // AGX compiler refuses a CA shader (e.g. the
    // "Encountered unlowered function call to agx.air.fract.v3f16.fast"
    // case observed on the macOS-13.4 AGXMetal13_3 + iOS-16.3 chroot
    // combination). Without that, hanging the worker just defers the
    // crash by one frame.
    // Default: behave like a tracing hook — log and forward to the real
    // abort_with_payload so other namespaces/codes still terminate.
    char *p = macws_crash_buf;
    char *end = macws_crash_buf + MACWS_CRASH_BUF_LEN;
#define AP(...) do { if (p < end) p += snprintf(p, (size_t)(end - p), __VA_ARGS__); } while (0)
    AP("\n#### MACWS_ABORT_TRACE namespace=%u code=%llu string=\"%s\" "
       "payload=%p size=%u flags=%llu\n",
        reason_namespace, (unsigned long long)reason_code,
        reason_string ? reason_string : "(null)",
        payload, payload_size, (unsigned long long)reason_flags);
    // Payload is usually a CFString-ish buffer with the Metal error
    // description in the first ~size bytes. Print as both hex and as
    // raw text so we see exactly what reason came from the driver.
    if (payload && payload_size > 0 && payload_size < 4096) {
        AP("####   payload bytes (text): \"");
        const unsigned char *pl = (const unsigned char *)payload;
        for (uint32_t i = 0; i < payload_size && p + 4 < end; i++) {
            unsigned char c = pl[i];
            if (c == '\\' || c == '"') { AP("\\%c", c); }
            else if (c >= 0x20 && c < 0x7f) { AP("%c", c); }
            else if (c == 0) { AP("\\0"); }
            else { AP("\\x%02x", c); }
        }
        AP("\"\n");
    }
    void *frames[24];
    int nf = backtrace(frames, 24);
    for (int i = 0; i < nf; i++) {
        Dl_info dli;
        if (dladdr(frames[i], &dli) && dli.dli_fname) {
            AP("####     [%2d] %p %s+%#llx (%s)\n", i, frames[i],
                dli.dli_sname ? dli.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] -
                    (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)),
                dli.dli_fname);
        } else {
            AP("####     [%2d] %p\n", i, frames[i]);
        }
    }
#undef AP
    size_t len = (size_t)(p - macws_crash_buf);
    if (len > MACWS_CRASH_BUF_LEN) len = MACWS_CRASH_BUF_LEN;
    (void)write(STDERR_FILENO, macws_crash_buf, len);
    // Tail-call the real abort_with_payload so process exit + launchd's
    // reason reporting are unchanged.
    if (macws_orig_abort_with_payload) {
        return macws_orig_abort_with_payload(reason_namespace, reason_code,
            payload, payload_size, reason_string, reason_flags);
    }
    _exit(128 + 6); // SIGABRT fallback
    return 0;
}

// __assert_rtn is what `assert()` macro calls before abort(). CA's
// MetalContext.mm has classic-assert "Unbalanced Composites" / similar
// guards. When we park a pipeline-build worker on a pipeline failure
// (above), the CA state stack is left non-empty, and the *next* frame's
// EndUpdate hits assert(_state_stack.empty()). That triggers abort() on
// a DIFFERENT thread from the abort_with_payload hang. Catch it here too
// and just return; the assertion message is logged for diagnostics.
static void hooked_assert_rtn(const char *func, const char *file, int line,
                              const char *expr) {
    char buf[512];
    int len = snprintf(buf, sizeof(buf),
        "#### MACWS_ASSERT_BYPASS func=%s file=%s line=%d expr=%s — return, "
        "NOT aborting\n",
        func ?: "?", file ?: "?", line, expr ?: "?");
    (void)write(STDERR_FILENO, buf,
        (size_t)(len > 0 ? (size_t)len : 0));
    return;
}

static void macws_install_assert_bypass(void) {
    // LAZY-fix kill switch. Default behaviour is to skip — this hook
    // globally turns every __assert_rtn into log+return, which has
    // masked real composite-state-stack leaks (Unbalanced Composites at
    // MetalContext.mm:411). See AGENTS.md "Patch Discipline" + memory
    // [[feedback-no-lazy-nop-ret-bypass]]. Opt-IN by setting
    // MACWS_KEEP_ASSERT_BYPASS=1 in WS plist to restore the old bypass
    // while debugging upstream.
    if (!getenv("MACWS_KEEP_ASSERT_BYPASS")) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS DISABLED (set MACWS_KEEP_ASSERT_BYPASS=1 "
            "to restore lazy bypass) — real __assert_rtn now reaches abort\n");
        return;
    }
    MSImageRef libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_c.dylib");
    if (!libsys) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS: libsystem_c image not found, skip\n");
        return;
    }
    void *sym = MSFindSymbol(libsys, "___assert_rtn");
    if (!sym) sym = MSFindSymbol(libsys, "__assert_rtn");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS: __assert_rtn not found, skip\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_assert_rtn, NULL);
    fprintf(stderr,
        "#### MACWS_ASSERT_BYPASS __assert_rtn → log+return at %p\n", sym);
}

static void macws_install_abort_trace(void) {
    if (!getenv("MACWS_ABORT_TRACE")) return;
    MSImageRef libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_kernel.dylib");
    if (!libsys) libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_c.dylib");
    if (!libsys) {
        fprintf(stderr,
            "#### MACWS_ABORT_TRACE: libsystem image not found, skip\n");
        return;
    }
    void *sym = MSFindSymbol(libsys, "_abort_with_payload");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_ABORT_TRACE: _abort_with_payload symbol not found\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_abort_with_payload,
        (void **)&macws_orig_abort_with_payload);
    fprintf(stderr,
        "#### MACWS_ABORT_TRACE installed at %p (orig=%p)\n",
        sym, (void *)macws_orig_abort_with_payload);
}

// ─── AGX fast-math forcing (root-cause fix for fract.v3f16) ─────────────
//
// QC's `default.metallib` ships with AIR that uses `air.fract.v3f16`.
// AGXCompilerCore (macOS 13.4 build, the one we run under iOS 16.3) has
// a fast-math optimization pass that — when enabled — renames the
// intrinsic to its AGX-internal "fast" form `agx.air.fract.v3f16.fast`
// and registers it for the dedicated fast-fract lowerer. The fast-fract
// lowerer (`AGCLLVMAirBuiltins::buildFastFract`) is actually present
// and DOES handle v3f16 correctly (it returns `x - floor(x)` with no
// post-clamp, since the clamp is f32-only), BUT the dispatch table that
// runs after the rename pass has no entry for `agx.air.fract.v3f16.fast`
// → `AGCLLVMUserObject::verifyLoweredIR()` reports "Encountered
// unlowered function call to agx.air.fract.v3f16.fast" and
// `CA::OGL::MetalContext::create_pipeline_state` calls
// abort_with_payload(13, 4, …).
//
// The fast-math rename happens iff bit 0 of the third argument to
// `AGCLLVMCtx::compile(AGCLLVMObject*, llvm::Module&, AGCFastMathFlags,
// llvm::AGX::PipelineType, llvm::AGX::CodeGenOptions&, bool)` is set
// (verified via static disasm — the function does
// `and w8, w19, #0x1 ; strb w8, [x25]` at offset +0xc0, writing the bit
// into CodeGenOptions[0], from which downstream passes read it). If we
// force AGCFastMathFlags to 0 at the function entry, the rename pass
// stays in "regular fract" mode and `AGCLLVMAirBuiltins::buildFract` —
// which has all four v{2,3,4}f16 cases wired into the dispatch table —
// handles the intrinsic. Trade-off: shaders compile with strict math
// instead of fast math; correctness is preserved, performance loses
// the fast-math optimizer's reassociation opportunities.
//
// AGCFastMathFlags is value-typed (≤ 8 bytes — passed in x3); only its
// low bit is read here, so a forwarded compile call with the third arg
// cleared is safe regardless of what the caller actually set.
typedef void (*macws_agc_compile_t)(void *self, void *obj, void *module,
    uint64_t fastMath, uint64_t pipeType, void *opts, uint64_t safeMode);
static macws_agc_compile_t macws_orig_agc_compile = NULL;

static void hooked_agc_compile(void *self, void *obj, void *module,
        uint64_t fastMath, uint64_t pipeType, void *opts, uint64_t safeMode) {
    static int log_once = 0;
    if (!log_once) {
        log_once = 1;
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF first AGCLLVMCtx::compile() call "
            "— forcing AGCFastMathFlags 0x%llx → 0 (avoids unlowered "
            "agx.air.fract.v3f16.fast)\n",
            (unsigned long long)fastMath);
    }
    macws_orig_agc_compile(self, obj, module, 0, pipeType, opts, safeMode);
}

// ─── Experiment: bypass verifyLoweredIR ─────────────────────────────────
//
// `AGCLLVMUserObject::verifyLoweredIR()` iterates the module's function
// list looking for declarations whose name contains "air.". Each match
// is logged via `_os_log_fault_impl` with the format
//   "Encountered unlowered function call to %s"
// and that log output is captured by the surrounding compile pipeline
// into the abort_with_payload payload string the host sees as
// "Metal failed to build render pipeline".
//
// If we make verifyLoweredIR a no-op (RET on entry), no fault is logged,
// no payload is constructed, the compile pipeline reports success, and
// the downstream codegen tries to emit machine code for the as-yet-
// unlowered call. There are three possible outcomes:
//
//   1. Codegen succeeds — the AGX backend has a fallback for the
//      unlowered call (perhaps emits a stub that the GPU runtime
//      handles), pipeline state builds OK, GPU executes correctly.
//      Best case — we've found the real fix.
//   2. Codegen succeeds but the GPU traps at runtime when the
//      unlowered call is reached.
//   3. Codegen itself fails with a different error.
//
// This is gated behind MACWS_AGC_VERIFY_BYPASS=1 because the trade-off
// depends on which outcome we hit. The verifier is meant to catch real
// bugs, so silencing it in general is risky.
typedef void (*macws_verify_t)(void *self);
static macws_verify_t macws_orig_agc_verify = NULL;
static void hooked_agc_verify(void *self) {
    static int log_once = 0;
    if (!log_once) {
        log_once = 1;
        fprintf(stderr,
            "#### MACWS_AGC_VERIFY_BYPASS verifyLoweredIR called on %p "
            "→ skipping check\n", self);
    }
    // Just return — don't iterate the module, don't log faults.
}

static void macws_install_agc_verify_bypass(MSImageRef img) {
    void *sym = MSFindSymbol(img,
        "__ZN17AGCLLVMUserObject15verifyLoweredIREv");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_AGC_VERIFY_BYPASS: verifyLoweredIR symbol not "
            "found, skip\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_agc_verify,
        (void **)&macws_orig_agc_verify);
    fprintf(stderr,
        "#### MACWS_AGC_VERIFY_BYPASS installed at %p "
        "(verifyLoweredIR → no-op)\n", sym);
}

static void macws_install_agc_fastmath_disable(void) {
    static int once = 0;
    if (once) return;
    // AGXCompilerCore is loaded on-demand the first time Metal asks the
    // device's compiler to build a pipeline; dlopen it eagerly so the
    // symbol is reachable from MSFindSymbol now.
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore",
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        NULL,
    };
    void *h = NULL;
    for (int i = 0; paths[i]; i++) {
        h = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) break;
    }
    if (!h) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF dlopen AGXCompilerCore FAILED: %s\n",
            dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore");
    if (!img) {
        img = MSGetImageByName(
            "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    }
    if (!img) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF: AGXCompilerCore image not "
            "MSGetImageByName-able\n");
        return;
    }
    const char *sym_name =
        "__ZN10AGCLLVMCtx7compileEP13AGCLLVMObjectRN4llvm6ModuleE"
        "16AGCFastMathFlagsNS2_3AGX12PipelineTypeERNS6_14CodeGenOptionsEb";
    void *sym = MSFindSymbol(img, sym_name);
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF: AGCLLVMCtx::compile symbol not "
            "found in AGXCompilerCore\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_agc_compile,
        (void **)&macws_orig_agc_compile);
    once = 1;
    fprintf(stderr,
        "#### MACWS_AGC_FASTMATH_OFF installed at %p — every "
        "AGCLLVMCtx::compile() call will receive AGCFastMathFlags=0 "
        "regardless of caller intent\n", sym);
}

// ─── AGXCompilerCore linkMetalRuntime rename patch ───────────────────────
//
// CONTEXT: chroot WindowServer compiles CA shaders IN-PROCESS via
// AGXCompilerCore (loaded as a dependency of AGXMetal13_3). The earlier
// hypothesis that compile goes out-of-process to MTLCompilerService.xpc
// was WRONG — `ps aux` shows no MTLCompilerService process at the time
// the v3f16 abort fires, and the matching Substrate-tweak patch never
// logs (its %ctor never runs in the chroot WS process). So the patch
// has to live here in libmachook, which already injects into the WS
// process.
//
// PATCH SITE: In macOS-13.4 AGXCompilerCore (the version chroot loads
// from the bind-mounted rootfs DSC), `AGCLLVMUserObject::linkMetalRuntime(bool)`
// at 0x1a2591b90 builds a renamed Function name as
// `"agx." + originalName + ".fast"`. The "agx." prepend is done by
// `std::string::insert(0, "agx.")`, a single BL at 0x1a2591ca0. The
// downstream dispatcher `AGCLLVMAirBuiltins::replaceBuiltins` only
// matches Function names that start with "air."; the renamer's "agx."
// prepend makes the renamed declaration invisible to the dispatcher and
// the verifier then aborts with "Encountered unlowered function call to
// agx.air.fract.v3f16.fast".
//
// If we NOP the insert call, the renamer produces `air.fract.v3f16.fast`
// instead — still starts with "air.", findPrefix splits at the first
// dot of the remainder ("fract" / "v3f16.fast"), the dispatcher's
// StringMap lookup hits the "fract" key → `buildFract`, which reads the
// operand type from the LLVM Value (half3) and emits the regular
// `x - floor(x)` lowering. No more unlowered call → no verifier
// complaint → no abort.
//
// ANCHOR + SIGNATURE:
//   _AIRNTGetVersion is exported by AGXCompilerCore; BL site is at
//   anchor + delta. To make the patch self-validating under DSC drift,
//   we also require that the instruction IMMEDIATELY BEFORE the BL
//   matches `add x2, x2, #0xdf4` (encoding 0x9137d042). That's the
//   literal-pool prep for the "agx." string pointer — it's a unique
//   signature for this exact call site.
//
//   Known deltas:
//     - macOS-13.4 chroot DSC (this device): -0x7e470 (RE'd 2026-06-18
//       from /System/Volumes/Preboot/Cryptexes/OS/.../dyld_shared_cache_arm64e,
//       linkMetalRuntime @ 0x1a2591b90, BL @ 0x1a2591ca0,
//       _AIRNTGetVersion @ 0x1a2610110)
//
// If the delta-1 instruction isn't the expected ADD, we walk a small
// window around the anchor looking for the (ADD #0xdf4) + (BL) pair so
// minor DSC version drift still resolves the right site.
//
// Opt-in via env: set MACWS_AGX_RENAMER_PATCH=1 in the WindowServer
// plist EnvironmentVariables. Off by default until we've validated the
// fix doesn't regress something else.
static void macws_install_agx_renamer_patch(void) {
    if (!getenv("MACWS_AGX_RENAMER_PATCH")) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH: off (set "
            "MACWS_AGX_RENAMER_PATCH=1 to enable)\n");
        return;
    }
    // Force-load AGXCompilerCore. It's pulled in by AGXMetal13_3 the
    // first time Metal asks the device for a compiler, but doing it
    // here ensures the symbol table is reachable before our hooks run.
    const char *acc_paths[] = {
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore",
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        NULL,
    };
    void *h = NULL;
    for (int i = 0; acc_paths[i]; i++) {
        h = dlopen(acc_paths[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            fprintf(stderr,
                "#### MACWS_AGX_RENAMER_PATCH dlopen ok %s -> %p\n",
                acc_paths[i], h);
            break;
        }
    }
    if (!h) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH dlopen FAILED: %s\n",
            dlerror());
        return;
    }
    void *anchor = dlsym(h, "AIRNTGetVersion");
    if (!anchor) anchor = dlsym(h, "_AIRNTGetVersion");
    if (!anchor) anchor = dlsym(RTLD_DEFAULT, "AIRNTGetVersion");
    if (!anchor) anchor = dlsym(RTLD_DEFAULT, "_AIRNTGetVersion");
    if (!anchor) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH: AIRNTGetVersion not found "
            "via dlsym in AGXCompilerCore handle or RTLD_DEFAULT\n");
        return;
    }
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH anchor AIRNTGetVersion=%p\n",
        anchor);
    // Signature: the BL site is preceded by `add x2, x2, #0xdf4`
    // (encoding 0x9137d042) which loads the "agx." literal pointer.
    // Patch only if both the ADD signature matches AND the next insn
    // is a BL — that's the unambiguous call site.
    const uint32_t SIG_ADD_X2_DF4 = 0x9137d042u;  // add x2, x2, #0xdf4
    BOOL (^try_patch)(uint32_t *, const char *) =
        ^BOOL(uint32_t *bl_site, const char *label) {
        uint32_t prev = bl_site[-1];
        uint32_t cur  = bl_site[0];
        unsigned op   = (cur >> 26) & 0x3F;
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH probe %s: site=%p prev=%#x "
            "insn=%#x op6=%#x (sig %s, BL %s)\n",
            label, bl_site, prev, cur, op,
            prev == SIG_ADD_X2_DF4 ? "OK" : "MISMATCH",
            op == 0x25 ? "OK" : "MISMATCH");
        if (prev != SIG_ADD_X2_DF4 || op != 0x25) return NO;
        ModifyExecutableRegion(bl_site, sizeof(uint32_t), ^{
            *bl_site = 0xd503201fu; // nop
        });
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH installed at %p (variant=%s) "
            "BL %#x → NOP\n",
            bl_site, label, cur);
        return YES;
    };

    // Primary delta: macOS-13.4 chroot DSC (this device).
    struct { intptr_t delta; const char *label; } candidates[] = {
        { -0x7e470,  "macOS-13.4 chroot" },
        // Legacy probes kept for diagnostic comparison only:
        { -0xa721c,  "alt-A (old probe)" },
        { -0x1259a4, "alt-B (old probe)" },
    };
    for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
        uint32_t *site = (uint32_t *)((uintptr_t)anchor + candidates[i].delta);
        if (try_patch(site, candidates[i].label)) return;
    }

    // Fallback: small +/-2KB scan for (ADD x2,x2,#0xdf4 ; BL) pair.
    // Stops at the first match.
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH: candidates missed — scanning "
        "+/-2KB around primary site for ADD+BL signature\n");
    uint32_t *base = (uint32_t *)((uintptr_t)anchor + (-0x7e470));
    for (int off = -512; off <= 512; off++) {
        uint32_t *probe = base + off;
        if (probe[-1] == SIG_ADD_X2_DF4 && ((probe[0] >> 26) & 0x3F) == 0x25) {
            char label[64];
            snprintf(label, sizeof label, "scan off=%+d", off);
            if (try_patch(probe, label)) return;
        }
    }
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH: no (ADD x2,x2,#0xdf4 ; BL) pair "
        "found — AGXCompilerCore version drift, NOT patching\n");
}

static void macws_install_iohid_unserialize_bypass(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    MSImageRef iokit = MSGetImageByName(
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit");
    if (!iokit) {
        iokit = MSGetImageByName(
            "/System/Library/Frameworks/IOKit.framework/IOKit");
    }
    if (!iokit) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: IOKit image not loadable, skip\n");
        return;
    }
    void *sym = MSFindSymbol(iokit,
        "_IOHIDEventSystemClientSetMatchingMultiple");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: SetMatchingMultiple not found, skip\n");
        return;
    }
    MSHookFunction(sym,
        (void *)hooked_IOHIDEventSystemClientSetMatchingMultiple_skip, NULL);
    fprintf(stderr,
        "#### MACWS_HID_BYPASS installed SetMatchingMultiple → no-op (1) "
        "at %p — skips iOS-format CFBinaryPlist parse inside\n"
        "####   IOHIDEventSystemClientCacheMatchingServices → "
        "IOHIDUnserializeAndVMDealloc → CFPropertyListCreateFromStream\n"
        "####   that BUS_ADRALNs in the IOMFBServer thread.\n", sym);
}

// ─── (Disabled) bulk IOMFBServer HID-init bypass ─────────────────────────
//
// QuartzCore's `CA::WindowServer::IOMFBServer` constructor enqueues a
// block (block_invoke at +0x3c) onto its runloop that walks the IOKit HID
// event-system to wire up display-related HID notifications (orientation,
// ambient light, hotplug). The block calls — in order:
//
//     client = IOHIDEventSystemClientCreate(NULL)
//     IOHIDEventSystemClientSetMatchingMultiple(client, matchArray)
//     IOHIDEventSystemClientRegisterDeviceMatchingBlock(client, …)
//     services = IOHIDEventSystemClientCopyServices(client)
//     for s in services: invoke per-service block
//     IOHIDEventSystemClientRegisterEventBlock(client, …)
//     IOHIDEventSystemClientScheduleWithRunLoop(client, …)
//
// In our chroot, the kernel that backs these calls is iOS 16.3's IOKit,
// not macOS 13.4's. The `SetMatchingMultiple` step asks the kernel to
// pre-cache matched services; the kernel responds with each service's
// property dict serialized as a binary plist. macOS CoreFoundation's
// `__CFBinaryPlistCreateObjectFiltered` parses the buffer and ends up
// constructing an NSCFString whose internal char pointer lands on an
// unaligned byte — the recursive parser's cleanup block_invoke then
// `CFRelease()`s that NSCFString and the destructor faults with SIGBUS
// si_code=BUS_ADRALN inside `_CFRelease+0x4a4` (verified by the in-process
// CRASH_DIAG handler — full stack: block_invoke → CFRelease →
// CFBinaryPlist → CFTryParseBinaryPlist → CFPropertyListCreateFromStream
// → _IOHIDUnserializeAndVMDealloc → CacheMatchingServices → SetMatching).
//
// The mismatch is between the iOS-kernel binary-plist serializer and the
// macOS-userspace parser. We don't have iOS-style HID devices that WS can
// usefully drive anyway, so the cheapest correct fix is: take WS out of
// the entire HID notification path. We make `…ClientCreate*` return a
// real (refcounted) sentinel CF object so the block's `str x0,[x20,#0x358]`
// store + later CFRetain/CFRelease still work, and we no-op every
// `…Client*` function that would otherwise mach-msg the kernel.
static CFTypeRef macws_hid_sentinel = NULL;
static dispatch_once_t macws_hid_sentinel_once = 0;
static CFTypeRef macws_get_hid_sentinel(void) {
    dispatch_once(&macws_hid_sentinel_once, ^{
        macws_hid_sentinel = (CFTypeRef)CFArrayCreate(
            kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
        if (macws_hid_sentinel) {
            CFRetain(macws_hid_sentinel);  // pin forever
        }
    });
    return macws_hid_sentinel;
}

static CFTypeRef hooked_IOHIDEventSystemClientCreate(
        CFAllocatorRef allocator) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr, "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreate "
        "→ sentinel %p\n", s);
    if (s) CFRetain(s);
    return s;
}
static CFTypeRef hooked_IOHIDEventSystemClientCreateWithType(
        CFAllocatorRef allocator, int type, CFDictionaryRef attributes) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr,
        "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreateWithType(type=%d) "
        "→ sentinel %p\n", type, s);
    if (s) CFRetain(s);
    return s;
}
// Boolean-returning setter; return 1 for "success".
static int hooked_IOHIDEventSystemClientSetMatchingMultiple(
        CFTypeRef client, CFArrayRef multiple) {
    (void)client; (void)multiple;
    return 1;
}
static void hooked_IOHIDEventSystemClientRegisterDeviceMatchingBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
static void hooked_IOHIDEventSystemClientUnregisterDeviceMatchingBlock(
        CFTypeRef client) {
    (void)client;
}
static void hooked_IOHIDEventSystemClientRegisterEventBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
// Callback-pointer variant — same signature shape, also a no-op.
static void hooked_IOHIDEventSystemClientRegisterEventCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
static void hooked_IOHIDEventSystemClientRegisterPropertyChangedCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
static void hooked_IOHIDEventSystemClientScheduleWithRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
static void hooked_IOHIDEventSystemClientUnscheduleFromRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
static CFArrayRef hooked_IOHIDEventSystemClientCopyServices(
        CFTypeRef client) {
    (void)client;
    return NULL;  // block checks cbz x0 and skips iteration
}
// Generic no-op stub — used for every "set/register/schedule/activate/cancel"
// IOHIDEventSystem call that takes our sentinel and otherwise tries to
// dereference its non-CFArray internals.
static void hooked_IOHID_noop(void) {}
// Bool/int returning variant — return 1 (success) by convention.
static int hooked_IOHID_noop_ret1(void) { return 1; }

static void macws_hook_iokit_sym(MSImageRef img, const char *sym,
                                  void *replacement) {
    void *p = MSFindSymbol(img, sym);
    if (!p) {
        fprintf(stderr, "#### MACWS_HID_BYPASS: %s not found, skip\n", sym);
        return;
    }
    MSHookFunction(p, replacement, NULL);
    fprintf(stderr, "#### MACWS_HID_BYPASS hooked %s @ %p\n", sym, p);
}

static void macws_install_iomfb_hid_bypass(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    MSImageRef iokit = MSGetImageByName(
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit");
    if (!iokit) {
        iokit = MSGetImageByName(
            "/System/Library/Frameworks/IOKit.framework/IOKit");
    }
    if (!iokit) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: IOKit image not loadable, skip\n");
        return;
    }
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCreate",
        (void *)hooked_IOHIDEventSystemClientCreate);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCreateWithType",
        (void *)hooked_IOHIDEventSystemClientCreateWithType);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientSetMatchingMultiple",
        (void *)hooked_IOHIDEventSystemClientSetMatchingMultiple);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientRegisterDeviceMatchingBlock",
        (void *)hooked_IOHIDEventSystemClientRegisterDeviceMatchingBlock);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientUnregisterDeviceMatchingBlock",
        (void *)hooked_IOHIDEventSystemClientUnregisterDeviceMatchingBlock);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientRegisterEventBlock",
        (void *)hooked_IOHIDEventSystemClientRegisterEventBlock);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientRegisterEventCallback",
        (void *)hooked_IOHIDEventSystemClientRegisterEventCallback);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientRegisterPropertyChangedCallback",
        (void *)hooked_IOHIDEventSystemClientRegisterPropertyChangedCallback);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientScheduleWithRunLoop",
        (void *)hooked_IOHIDEventSystemClientScheduleWithRunLoop);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientUnscheduleFromRunLoop",
        (void *)hooked_IOHIDEventSystemClientUnscheduleFromRunLoop);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCopyServices",
        (void *)hooked_IOHIDEventSystemClientCopyServices);
    // All remaining client-side IOHIDEventSystem APIs that SkyLight /
    // QuartzCore call on our sentinel. Each one would otherwise read an
    // internal IOHID-object vtable from the sentinel (CFArray storage,
    // not an IOHID object) and SEGV. The no-op stubs absorb the call.
    static const char *noop_void_syms[] = {
        "_IOHIDEventSystemClientActivate",
        "_IOHIDEventSystemClientCancel",
        "_IOHIDEventSystemClientScheduleWithDispatchQueue",
        "_IOHIDEventSystemClientSetCancelHandler",
        "_IOHIDEventSystemClientSetDispatchQueue",
        "_IOHIDEventSystemClientUnregisterEventCallback",
        "_IOHIDEventSystemClientUnregisterPropertyChangedCallback",
        "_IOHIDEventSystemClientStop",
        "_IOHIDEventSystemRegisterServicesCallback",
        NULL
    };
    static const char *noop_ret1_syms[] = {
        "_IOHIDEventSystemClientSetMatching",
        "_IOHIDEventSystemClientSetMatchingMultiple",
        "_IOHIDEventSystemClientSetProperty",
        "_IOHIDEventSystemSetProperty",
        NULL
    };
    for (int i = 0; noop_void_syms[i]; i++) {
        void *p = MSFindSymbol(iokit, noop_void_syms[i]);
        if (p) {
            MSHookFunction(p, (void *)hooked_IOHID_noop, NULL);
            fprintf(stderr, "#### MACWS_HID_BYPASS noop %s @ %p\n",
                noop_void_syms[i], p);
        }
    }
    for (int i = 0; noop_ret1_syms[i]; i++) {
        void *p = MSFindSymbol(iokit, noop_ret1_syms[i]);
        if (p) {
            // Already hooked SetMatchingMultiple above with a specialised
            // 2-arg stub; the generic ret-1 works equivalently for it but
            // re-hooking is harmless. MSHook keeps the first install.
            MSHookFunction(p, (void *)hooked_IOHID_noop_ret1, NULL);
            fprintf(stderr, "#### MACWS_HID_BYPASS ret1 %s @ %p\n",
                noop_ret1_syms[i], p);
        }
    }
}

// ─── OSXvnc framebuffer delivery hook ────────────────────────────────────────
// OSXvnc-server captures via CGDisplayCreateImage(CGMainDisplayID()), but in its
// "off-screen user session" that returns BLACK (CGS session isolation — same
// displayID as a CLI capture that DOES see our composite). Source
// (github.com/stweil/OSXvnc, OSXvnc-server/main.c): rfbGetFramebuffer() caches
// frameBufferData and returns its .mutableBytes; rfbGetFramebufferUpdateInRect()
// re-captures per frame INTO it. We hook both and overwrite frameBufferData with
// OUR content, bypassing the black session-CreateImage.  WindowServer writes
// the native-AGX-detiled composite to /tmp/macws_vnc_fb; when that backend is
// requested, the per-rectangle hook must not call the original capture path.
// rfbScreenInfo (rfb.h): width@0 paddedWidthInBytes@+4 height@+8 depth@+12
//   bitsPerPixel@+16 (all int32). Offsets from base 0x100000000 (otool of the
//   device OSXvnc-server arm64): rfbGetFramebuffer @0xd9d4,
//   rfbGetFramebufferUpdateInRect @0xdc28, rfbScreenInit @0xf040,
//   rfbCheckForScreenResolutionChange @0xd668, rfbScreen @0x79bf8.
// Always installed inside OSXvnc; framebuffer replacement and Retina geometry
// stay inert unless the corresponding diagnostic sentinel is present.
static char *(*macws_orig_rfbGetFB)(void);
static void (*macws_orig_rfbGetFBRect)(int, int, int, int);
static size_t (*macws_orig_CGDisplayPixelsWide)(uint32_t);
static size_t (*macws_orig_CGDisplayPixelsHigh)(uint32_t);
static char *macws_vnc_fb = NULL;
static int  *macws_rfbScreen = NULL;
static double *macws_rfbBackingScale = NULL;
static int   macws_vnc_test_on = 0;
static int   macws_vnc_share_on = 0;

// RE-confirmed via the device OSXvnc-server arm64:
//   * _rfbScreenInit+0xa0/+0xb8 stores CGDisplayPixelsWide/High in rfbScreen.
//   * _rfbCheckForScreenResolutionChange+0x30/+0x48 calls those APIs again and
//     compares their result to rfbScreen; a post-init field edit therefore
//     caused an endless "Screen geometry changed - (1194,834)" loop that closed
//     active clients.
//   * backingScaleFactor is saved at image base+0x7a1e8 before the first width
//     query. LLDB runtime-confirmed rfbScreen={1194,9600,834,...,32}; the
//     9600-byte row safely contains 2388*4 bytes plus 48 bytes of alignment.
// Return the physical Retina dimensions at the two source APIs so both init and
// later change detection observe the same geometry. OSXvnc then allocates its
// cached framebuffer at the correct size through its ordinary path.
static int macws_vnc_integral_backing_scale(void) {
    if (!macws_vnc_share_on || !macws_rfbBackingScale) return 1;
    double savedScale = *macws_rfbBackingScale;
    int scale = (int)(savedScale + 0.5);
    if (scale < 2 || scale > 4 || savedScale < (double)scale - 0.01 ||
        savedScale > (double)scale + 0.01) return 1;
    return scale;
}

static size_t macws_new_CGDisplayPixelsWide(uint32_t display) {
    size_t logical = macws_orig_CGDisplayPixelsWide
        ? macws_orig_CGDisplayPixelsWide(display) : 0;
    int scale = macws_vnc_integral_backing_scale();
    if (logical == 0 || logical > 8192 || scale <= 1 ||
        logical > 8192u / (size_t)scale) return logical;
    size_t physical = logical * (size_t)scale;
    static int logged = 0;
    if (!logged++) fprintf(stderr,
        "#### OSXVNC RETINA width API logical=%zu scale=%d physical=%zu\n",
        logical, scale, physical);
    return physical;
}

static size_t macws_new_CGDisplayPixelsHigh(uint32_t display) {
    size_t logical = macws_orig_CGDisplayPixelsHigh
        ? macws_orig_CGDisplayPixelsHigh(display) : 0;
    int scale = macws_vnc_integral_backing_scale();
    if (logical == 0 || logical > 8192 || scale <= 1 ||
        logical > 8192u / (size_t)scale) return logical;
    size_t physical = logical * (size_t)scale;
    static int logged = 0;
    if (!logged++) fprintf(stderr,
        "#### OSXVNC RETINA height API logical=%zu scale=%d physical=%zu\n",
        logical, scale, physical);
    return physical;
}

// The exact arm64 OSXvnc binary installed on the device was disassembled on
// 2026-07-26. -[VNCServer handleMouseButtons:atPoint:forClient:] receives the
// button mask in x2, the RFB point in d0/d1, and the client in x3.  The
// non-scroll path stores the point at client+0x6e78/+0x6e80, derives all three
// button states directly from x2, then calls CGPostMouseEvent without applying
// backingScaleFactor.  There is no retained mouse-button state in this method.
//
// Runtime LLDB-confirmed on 2026-07-28 that CGPostMouseEvent DOES reach the
// chroot AppKit process despite CGPreflightPostEventAccess returning NO.  A
// Terminal text-selection drag then nested that native mouseDown underneath
// AppInputBridge.m:647's second mouseDown; the inner call hit AppKit's exact
// "Periodic events are already being generated" branch at NSEvent.m:4276.
// Under Retina sharing the unscaled native event also used a 2388x1668 RFB
// point in the logical 1194x834 Quartz space, explaining the visible cursor /
// AppInputBridge click displacement.
//
// Keep OSXvnc's original point bookkeeping, cursor motion, all buttons,
// dimming behavior, and scroll-wheel path, but supply logical Quartz
// coordinates. Runtime title-bar testing after the duplicate fix established
// that this native path is also the one that drives NSWindow's modal move
// tracker; AppInputBridge's synthetic title-bar sequence returned without
// moving the window. VNC must therefore have one owner per gesture, never two:
// stationary left taps use the process-targeted AppInput path, while drags,
// hover, other buttons, and cursor bookkeeping use OSXvnc's native path.
// AppInputBridge also remains the full fallback when the native implementation
// is unavailable and remains the input path for the native iPad host.
typedef void (*MacWSVNCHandleMouse)(id, SEL, unsigned int, CGPoint, id);
static MacWSVNCHandleMouse macws_orig_vnc_handle_mouse = NULL;
typedef void (*MacWSVNCHandleKeyboard)(id, SEL, BOOL, unsigned int, id);
static MacWSVNCHandleKeyboard macws_orig_vnc_handle_keyboard = NULL;
static BOOL macws_vnc_left_down = NO;
static CGPoint macws_vnc_last_point = {-1.0, -1.0};
static CGPoint macws_vnc_pending_down_point = {-1.0, -1.0};
static BOOL macws_vnc_pending_down = NO;
static BOOL macws_vnc_remote_down = NO;
static BOOL macws_vnc_release_pending = NO;
static uint32_t macws_vnc_gesture_id = 0;
static int macws_vnc_input_fd = -1;
static double macws_vnc_last_continuous_send = 0.0;
// System-wide route for the exact installed OSXvnc CGPostMouseEvent path. The
// split owner (AppInput taps, native drags/right buttons) cannot cover AppKit's
// global menu and drag state machine coherently. Runtime tests on 2026-07-29
// exercised menu open/hover/close, contextual menu, and NSWindow title drag
// through this single stream (13/13 region-change witnesses). The generated
// VNC launchd job enables this path; the file/env gate remains for controlled
// A/Bs and compatibility with manually launched OSXvnc.
static BOOL macws_vnc_native_all = NO;
static _Atomic uint64_t macws_vnc_keyboard_serial = 0;
static _Atomic uint64_t macws_vnc_keyboard_last_progress_ns = 0;
static _Atomic uint64_t macws_vnc_pointer_capture_serial = 0;
static _Atomic uint64_t macws_vnc_pointer_settle_serial = 0;
static _Atomic unsigned int macws_vnc_native_buttons = 0;

// RE-confirmed via the installed arm64 OSXvnc-server (2026-07-27):
//
//   refreshCallback+0xec unions each CoreGraphics refresh rectangle into
//   client->modifiedRegion at +0xf8 and signals client->updateCond at +0xc8.
//   clientOutput+0x154 intersects that region with requestedRegion (+0x108)
//   and passes only the intersection to rfbSendFramebufferUpdate.
//
// Our mmap publisher bypasses CoreGraphics, so a completed full frame did not
// enter modifiedRegion; a live VNC connection received only cursor-sized CG
// rectangles even though a reconnect could fetch the new full frame.  The
// producer now commits an even/nonzero sequence after its validated pixel
// copy. Watch that sequence and feed pixel-difference rectangles through
// OSXvnc's own refreshCallback, preserving its region locks and wakeup
// protocol.
typedef void (*MacWSVNCRefreshCallback)(uint32_t, const CGRect *, void *);
static MacWSVNCRefreshCallback macws_vnc_refresh_callback = NULL;

// OSXvnc registers refreshCallback directly with CoreGraphics.  RE-confirmed
// at refreshCallback+0xec: its incoming CGRects are copied verbatim into the
// RFB modifiedRegion.  Once the RFB framebuffer is promoted from logical
// 1194x834 to Retina 2388x1668, those ordinary CG damage rectangles cover only
// the upper-left quarter and, more importantly, describe a capture backend we
// deliberately bypass.  Shared mode defers them to the mmap generation
// watcher. The watcher calls the original trampoline with validated physical
// rectangles and therefore bypasses this wrapper.
static void macws_new_vnc_refresh_callback(uint32_t count,
        const CGRect *rectangles, void *context) {
    if (!macws_vnc_refresh_callback || !rectangles || count == 0) return;
    if (macws_vnc_share_on) {
        // The ordinary callback describes pixels in OSXvnc's disabled
        // CGDisplayCreateImage backend. rfbGetFBRect intentionally reads the
        // mmap producer instead, which has not necessarily committed that
        // frame yet. Let the generation watcher notify only after its seqlock
        // validates the matching mmap pixels; forwarding this callback sent
        // stale rectangles and duplicated every later mmap notification.
        static unsigned deferredLogs;
        if (deferredLogs++ < 8) {
            fprintf(stderr,
                "#### OSXVNC CG-DAMAGE deferred-to-mmap count=%u "
                "logical=%.0f,%.0f %.0fx%.0f\n",
                count, rectangles[0].origin.x, rectangles[0].origin.y,
                rectangles[0].size.width, rectangles[0].size.height);
        }
        return;
    }
    int scale = macws_vnc_integral_backing_scale();
    if (scale <= 1) {
        macws_vnc_refresh_callback(count, rectangles, context);
        return;
    }

    CGRect inlineRectangles[64];
    CGRect *scaled = count <= 64 ? inlineRectangles
                                 : calloc(count, sizeof(CGRect));
    if (!scaled) {
        macws_vnc_refresh_callback(count, rectangles, context);
        return;
    }
    for (uint32_t index = 0; index < count; index++) {
        scaled[index].origin.x = rectangles[index].origin.x * scale;
        scaled[index].origin.y = rectangles[index].origin.y * scale;
        scaled[index].size.width = rectangles[index].size.width * scale;
        scaled[index].size.height = rectangles[index].size.height * scale;
    }
    static unsigned scaleLogs;
    if (scaleLogs++ < 8) {
        fprintf(stderr,
            "#### OSXVNC CG-DAMAGE scale=%d count=%u "
            "logical=%.0f,%.0f %.0fx%.0f physical=%.0f,%.0f %.0fx%.0f\n",
            scale, count,
            rectangles[0].origin.x, rectangles[0].origin.y,
            rectangles[0].size.width, rectangles[0].size.height,
            scaled[0].origin.x, scaled[0].origin.y,
            scaled[0].size.width, scaled[0].size.height);
    }
    macws_vnc_refresh_callback(count, scaled, context);
    if (scaled != inlineRectangles) free(scaled);
}

static void *macws_vnc_generation_watcher(void *unused) {
    (void)unused;
    void *mapping = NULL;
    size_t mappingSize = 0;
    uint64_t observed = 0;
    uint8_t *previousPixels = NULL;
    uint8_t *currentPixels = NULL;
    size_t previousPixelsSize = 0;
    size_t previousWidth = 0;
    size_t previousHeight = 0;
    BOOL previousValid = NO;
    for (;;) {
        if (!mapping) {
            int fd = open("/tmp/macws_vnc_fb", O_RDONLY);
            if (fd >= 0) {
                struct stat st = {0};
                if (fstat(fd, &st) == 0 && st.st_size >= 24) {
                    void *candidate = mmap(NULL, (size_t)st.st_size, PROT_READ,
                                           MAP_SHARED, fd, 0);
                    if (candidate != MAP_FAILED) {
                        mapping = candidate;
                        mappingSize = (size_t)st.st_size;
                    }
                }
                close(fd);
            }
        }

        if (mapping && macws_vnc_refresh_callback && macws_rfbScreen) {
            const uint32_t *header = (const uint32_t *)mapping;
            size_t height = header[2];
            size_t stride = header[3];
            if (header[0] == 0x564E4346u && height > 0 && stride > 0 &&
                height <= (SIZE_MAX - 24) / stride) {
                size_t sequenceOffset = 16 + height * stride;
                if (sequenceOffset + sizeof(uint64_t) <= mappingSize) {
                    const _Atomic uint64_t *sequenceAddress =
                        (const _Atomic uint64_t *)
                        ((const char *)mapping + sequenceOffset);
                    uint64_t sequence = atomic_load_explicit(
                        sequenceAddress, memory_order_acquire);
                    if (sequence != 0 && !(sequence & 1u) &&
                        sequence != observed) {
                        int width = macws_rfbScreen[0];
                        int screenHeight = macws_rfbScreen[2];
                        if (width > 0 && screenHeight > 0 && width <= 8192 &&
                            screenHeight <= 8192) {
                            size_t sourceWidth = header[1];
                            size_t visibleRowBytes = sourceWidth <= SIZE_MAX / 4
                                ? sourceWidth * 4 : 0;
                            size_t pixelBytes = visibleRowBytes > 0 &&
                                height <= SIZE_MAX / visibleRowBytes
                                ? height * visibleRowBytes : 0;
                            BOOL geometryMatches =
                                sourceWidth == (size_t)width &&
                                height == (size_t)screenHeight &&
                                visibleRowBytes <= stride && pixelBytes > 0;
                            BOOL forceFull = !geometryMatches;
                            BOOL changed = forceFull;
                            size_t minX = sourceWidth;
                            size_t minY = height;
                            size_t maxX = 0;
                            size_t maxY = 0;
                            enum { MacWSDamageTile = 64,
                                   MacWSMaxTileAxis = 128,
                                   MacWSMaxDamageRects = 512 };
                            uint8_t dirtyTiles[
                                MacWSMaxTileAxis * MacWSMaxTileAxis] = {0};
                            size_t tileColumns = sourceWidth > 0
                                ? (sourceWidth + MacWSDamageTile - 1) /
                                    MacWSDamageTile : 0;
                            size_t tileRows = height > 0
                                ? (height + MacWSDamageTile - 1) /
                                    MacWSDamageTile : 0;
                            const uint8_t *sourcePixels =
                                (const uint8_t *)mapping + 16;

                            if (geometryMatches &&
                                (previousPixelsSize != pixelBytes ||
                                 previousWidth != sourceWidth ||
                                 previousHeight != height)) {
                                uint8_t *replacementPrevious =
                                    malloc(pixelBytes);
                                uint8_t *replacementCurrent =
                                    malloc(pixelBytes);
                                if (replacementPrevious &&
                                    replacementCurrent) {
                                    free(previousPixels);
                                    free(currentPixels);
                                    previousPixels = replacementPrevious;
                                    currentPixels = replacementCurrent;
                                    previousPixelsSize = pixelBytes;
                                    previousWidth = sourceWidth;
                                    previousHeight = height;
                                    previousValid = NO;
                                } else {
                                    free(replacementPrevious);
                                    free(replacementCurrent);
                                    forceFull = YES;
                                    changed = YES;
                                }
                            }

                            // Copy one seqlock-stable generation first, then
                            // diff private memory. The old code compared the
                            // live mmap row by row and mutated previousPixels
                            // at the same time. During interactive 10-60 Hz
                            // publication, a newer frame often arrived during
                            // that scan; it invalidated the snapshot and made
                            // the following generation a 15.2-MiB full-screen
                            // raw update. A bounded memcpy+validate retry keeps
                            // both the diff baseline and dirty rectangles
                            // coherent without slowing the producer.
                            BOOL snapshotStable = NO;
                            if (geometryMatches && previousPixels &&
                                currentPixels &&
                                previousPixelsSize == pixelBytes) {
                                for (unsigned attempt = 0; attempt < 4;
                                     attempt++) {
                                    uint64_t before = atomic_load_explicit(
                                        sequenceAddress,
                                        memory_order_acquire);
                                    if (before == 0 || (before & 1u)) {
                                        usleep(1000);
                                        continue;
                                    }
                                    for (size_t y = 0; y < height; y++) {
                                        memcpy(currentPixels +
                                                   y * visibleRowBytes,
                                               sourcePixels + y * stride,
                                               visibleRowBytes);
                                    }
                                    atomic_thread_fence(memory_order_acquire);
                                    uint64_t after = atomic_load_explicit(
                                        sequenceAddress,
                                        memory_order_acquire);
                                    if (before == after && !(after & 1u)) {
                                        sequence = after;
                                        snapshotStable = YES;
                                        break;
                                    }
                                    usleep(1000);
                                }
                                if (!snapshotStable) continue;

                                if (!previousValid) {
                                    memcpy(previousPixels, currentPixels,
                                           pixelBytes);
                                    forceFull = YES;
                                    changed = YES;
                                } else {
                                    for (size_t y = 0; y < height; y++) {
                                        const uint32_t *sourceRow =
                                            (const uint32_t *)(currentPixels +
                                                y * visibleRowBytes);
                                        uint32_t *previousRow =
                                            (uint32_t *)(previousPixels +
                                                y * visibleRowBytes);
                                        if (memcmp(sourceRow, previousRow,
                                                   visibleRowBytes) == 0) {
                                            continue;
                                        }
                                        size_t left = sourceWidth;
                                        size_t right = 0;
                                        for (size_t x = 0; x < sourceWidth;
                                             x++) {
                                            if (sourceRow[x] == previousRow[x])
                                                continue;
                                            if (left == sourceWidth) left = x;
                                            right = x + 1;
                                            if (tileColumns <=
                                                    MacWSMaxTileAxis &&
                                                tileRows <= MacWSMaxTileAxis) {
                                                dirtyTiles[
                                                    (y / MacWSDamageTile) *
                                                        tileColumns +
                                                    x / MacWSDamageTile] = 1;
                                            }
                                        }
                                        if (left < minX) minX = left;
                                        if (right > maxX) maxX = right;
                                        if (y < minY) minY = y;
                                        if (y + 1 > maxY) maxY = y + 1;
                                        memcpy(previousRow, sourceRow,
                                               visibleRowBytes);
                                        changed = YES;
                                    }
                                }
                            }
                            previousValid = geometryMatches && previousPixels &&
                                currentPixels && snapshotStable;
                            observed = sequence;

                            CGRect dirty = {
                                .origin = {0.0, 0.0},
                                .size = {(CGFloat)width,
                                         (CGFloat)screenHeight},
                            };
                            if (!forceFull && changed && minX < maxX &&
                                minY < maxY) {
                                dirty.origin.x = (CGFloat)minX;
                                dirty.origin.y = (CGFloat)minY;
                                dirty.size.width = (CGFloat)(maxX - minX);
                                dirty.size.height = (CGFloat)(maxY - minY);
                            }
                            CGRect damageRects[MacWSMaxDamageRects];
                            uint32_t damageCount = 0;
                            BOOL damageOverflow = NO;
                            if (!forceFull && changed &&
                                tileColumns <= MacWSMaxTileAxis &&
                                tileRows <= MacWSMaxTileAxis) {
                                for (size_t tileY = 0; tileY < tileRows;
                                     tileY++) {
                                    size_t tileX = 0;
                                    while (tileX < tileColumns) {
                                        while (tileX < tileColumns &&
                                               !dirtyTiles[
                                                   tileY * tileColumns + tileX])
                                            tileX++;
                                        if (tileX == tileColumns) break;
                                        size_t runStart = tileX;
                                        while (tileX < tileColumns &&
                                               dirtyTiles[
                                                   tileY * tileColumns + tileX])
                                            tileX++;
                                        if (damageCount >=
                                                MacWSMaxDamageRects) {
                                            damageOverflow = YES;
                                            break;
                                        }
                                        size_t x0 = runStart * MacWSDamageTile;
                                        size_t x1 = tileX * MacWSDamageTile;
                                        size_t y0 = tileY * MacWSDamageTile;
                                        size_t y1 = y0 + MacWSDamageTile;
                                        if (x1 > sourceWidth) x1 = sourceWidth;
                                        if (y1 > height) y1 = height;
                                        damageRects[damageCount++] = (CGRect){
                                            .origin = {(CGFloat)x0,
                                                       (CGFloat)y0},
                                            .size = {(CGFloat)(x1 - x0),
                                                     (CGFloat)(y1 - y0)},
                                        };
                                    }
                                    if (damageOverflow) break;
                                }
                            }
                            if (changed) {
                                if (forceFull || damageOverflow ||
                                    damageCount == 0) {
                                    macws_vnc_refresh_callback(1, &dirty, NULL);
                                    damageCount = 1;
                                } else {
                                    macws_vnc_refresh_callback(
                                        damageCount, damageRects, NULL);
                                }
                            }
                            static _Atomic uint64_t notified = 0;
                            uint64_t count = atomic_fetch_add(&notified, 1) + 1;
                            if (count <= 16 || (count % 600) == 0) {
                                fprintf(stderr,
                                    "#### OSXVNC mmap generation #%llu "
                                    "sequence=%llu changed=%s "
                                    "dirty=%.0f,%.0f %.0fx%.0f rects=%u "
                                    "overflow=%s\n",
                                    (unsigned long long)count,
                                    (unsigned long long)sequence,
                                    changed ? "YES" : "NO",
                                    dirty.origin.x, dirty.origin.y,
                                    dirty.size.width, dirty.size.height,
                                    damageCount,
                                    damageOverflow ? "YES" : "NO");
                            }
                        }
                    }
                }
            }
        }
        usleep(16000);
    }
    return NULL;
}

static double macws_vnc_monotonic_seconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

// Cross-process interaction hint for the cancelled-swap pacing diagnostic.
// OSXvnc writes one boot-relative timestamp (at most 120 Hz); WindowServer
// reads it at its existing SwapEnd boundary.  This does not fabricate a GPU
// completion or acknowledge work early.  It only selects the bounded sleep
// interval below so an idle VNC desktop can stay cool without imposing the
// same latency while a user is actively typing or dragging.
static int macws_vnc_activity_fd = -1;
static _Atomic uint64_t macws_vnc_last_activity_write_ns = 0;
static void macws_vnc_note_interaction(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return;
    uint64_t nanoseconds = (uint64_t)now.tv_sec * NSEC_PER_SEC +
        (uint64_t)now.tv_nsec;
    const uint64_t minimumInterval = 8ull * NSEC_PER_MSEC;
    uint64_t previous = atomic_load_explicit(
        &macws_vnc_last_activity_write_ns, memory_order_acquire);
    for (;;) {
        if (previous != 0 && nanoseconds > previous &&
            nanoseconds - previous < minimumInterval) return;
        if (atomic_compare_exchange_weak_explicit(
                &macws_vnc_last_activity_write_ns, &previous, nanoseconds,
                memory_order_acq_rel, memory_order_acquire)) break;
    }
    if (macws_vnc_activity_fd < 0) {
        macws_vnc_activity_fd = open(
            "/tmp/macws_vnc_activity", O_WRONLY | O_CREAT | O_TRUNC |
            O_CLOEXEC, 0644);
    }
    if (macws_vnc_activity_fd >= 0 &&
        pwrite(macws_vnc_activity_fd, &nanoseconds,
               sizeof(nanoseconds), 0) != sizeof(nanoseconds)) {
        close(macws_vnc_activity_fd);
        macws_vnc_activity_fd = -1;
    }
}

static uint64_t macws_vnc_realtime_nanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void macws_vnc_write_capture_request(const char *reason,
                                            uint64_t serial,
                                            unsigned int detail) {
    if (!macws_vnc_share_on) return;
    uint64_t generation = macws_vnc_realtime_nanoseconds();
    if (generation == 0) return;
    char value[48];
    int length = snprintf(value, sizeof(value), "%llu\n",
                          (unsigned long long)generation);
    int fd = open("/tmp/macws_capture_final",
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t written = write(fd, value, (size_t)length);
    close(fd);
    if (written == length) {
        fprintf(stderr,
            "#### OSXVNC %s-CAPTURE serial=%llu detail=%#x "
            "generation=%llu\n",
            reason, (unsigned long long)serial, detail,
            (unsigned long long)generation);
    }
}

static void macws_vnc_request_keyboard_progress_frame(uint64_t keySerial,
                                                      unsigned int keySym) {
    if (!macws_vnc_share_on) return;
    uint64_t now = macws_vnc_realtime_nanoseconds();
    if (now == 0) return;
    const uint64_t minimumInterval = 150ull * NSEC_PER_MSEC;
    uint64_t previous = atomic_load_explicit(
        &macws_vnc_keyboard_last_progress_ns, memory_order_acquire);
    for (;;) {
        if (previous != 0 && now > previous &&
            now - previous < minimumInterval) return;
        if (atomic_compare_exchange_weak_explicit(
                &macws_vnc_keyboard_last_progress_ns, &previous, now,
                memory_order_acq_rel, memory_order_acquire)) break;
    }
    macws_vnc_write_capture_request("KEY-PROGRESS", keySerial, keySym);
}

static void macws_vnc_request_keyboard_final_frame(uint64_t keySerial,
                                                   unsigned int keySym) {
    if (!macws_vnc_share_on ||
        atomic_load_explicit(&macws_vnc_keyboard_serial,
                             memory_order_acquire) != keySerial) return;
    macws_vnc_write_capture_request("KEY-FINAL", keySerial, keySym);
}

static void macws_vnc_request_keyboard_settled_frame(uint64_t keySerial,
                                                      unsigned int keySym) {
    if (!macws_vnc_share_on ||
        atomic_load_explicit(&macws_vnc_keyboard_serial,
                             memory_order_acquire) != keySerial) return;
    macws_vnc_write_capture_request("KEY-SETTLED", keySerial, keySym);
}

// The original OSXvnc pointer path posts a coherent system-wide mouse stream,
// but shared-VNC mode deliberately ignores CoreGraphics' display-refresh
// callback and publishes only WindowServer's stable mmap generations.  A menu
// or contextual-menu transition can therefore reach AppKit without producing
// a VNC-visible generation until the next pointer event.  Runtime evidence on
// 2026-07-29 showed exactly that boundary: VS Code received rightDown/rightUp
// (NSEvent 3/4, pressed=0x2), while the first menu-open framebuffer still had
// no menu and the following hover delivered the already-open menu.
//
// Request an early observation after the pointer becomes quiet, plus a later
// observation after button transitions.  This does not synthesize an event or
// fabricate a frame: Metal_hooks still accepts only a real, stable
// WindowServer composite and ACKs its generation.  Motion is debounced so a
// 120-Hz VNC client cannot create 120 full-display observations per second.
static void macws_vnc_schedule_native_pointer_frames(
        unsigned int buttons, BOOL buttonTransition) {
    if (!macws_vnc_share_on) return;
    uint64_t serial = atomic_fetch_add_explicit(
        &macws_vnc_pointer_capture_serial, 1,
        memory_order_acq_rel) + 1;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 24 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            if (atomic_load_explicit(&macws_vnc_pointer_capture_serial,
                                     memory_order_acquire) == serial) {
                macws_vnc_write_capture_request(
                    "POINTER-PROGRESS", serial, buttons);
            }
        });
    if (!buttonTransition) return;
    uint64_t settleSerial = atomic_fetch_add_explicit(
        &macws_vnc_pointer_settle_serial, 1,
        memory_order_acq_rel) + 1;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            if (atomic_load_explicit(&macws_vnc_pointer_settle_serial,
                                     memory_order_acquire) == settleSerial) {
                macws_vnc_write_capture_request(
                    "POINTER-SETTLED", settleSerial, buttons);
            }
        });
}

static void macws_new_vnc_handle_keyboard(id self, SEL command, BOOL down,
        unsigned int keySym, id client) {
    macws_vnc_note_interaction();
    double started = macws_vnc_monotonic_seconds();
    if (macws_orig_vnc_handle_keyboard)
        macws_orig_vnc_handle_keyboard(self, command, down, keySym, client);
    double elapsedMilliseconds =
        (macws_vnc_monotonic_seconds() - started) * 1000.0;
    static _Atomic uint64_t handlerCount = 0;
    uint64_t handled = atomic_fetch_add_explicit(
        &handlerCount, 1, memory_order_relaxed) + 1;
    if (handled <= 16 || elapsedMilliseconds >= 50.0) {
        fprintf(stderr,
            "#### OSXVNC KEY-HANDLER event=%llu down=%d sym=%#x "
            "at=%.6f elapsed=%.3fms\n",
            (unsigned long long)handled, down, keySym,
            started,
            elapsedMilliseconds);
    }
    if (!down || !macws_vnc_share_on) return;

    uint64_t serial = atomic_fetch_add_explicit(&macws_vnc_keyboard_serial, 1,
                                                 memory_order_acq_rel) + 1;
    // Publish progress while a user is still typing instead of treating every
    // newer key as a reason to cancel the preceding frame. Requests are
    // throttled to 150 ms and the producer naturally coalesces file updates,
    // bounding GPU work. A separate trailing request waits for AppKit to drain
    // a fast key burst: runtime boundary logs measured 14 events ("abcdef" +
    // Return) reaching Terminal over 188 ms after OSXvnc returned in 4.6 ms.
    // A separate 2026-07-28 retained-session trace then showed Terminal's
    // env-gated 750 ms display settle at monotonic 221589.493, after the old
    // 350 ms KEY-FINAL request. The complete command/output remained one
    // composite behind until the next key generated another capture request.
    // Keep the early request for responsive echo, and add one debounced request
    // after that observed application-settle boundary. This asks the existing
    // producer for a frame; it does not fabricate pixels or completion state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        macws_vnc_request_keyboard_progress_frame(serial, keySym);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        macws_vnc_request_keyboard_final_frame(serial, keySym);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1100 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        macws_vnc_request_keyboard_settled_frame(serial, keySym);
    });
}

static BOOL macws_vnc_forward_input(MacWSInputKind kind, CGPoint point,
                                    BOOL reliable) {
    if (!macws_rfbScreen) return NO;
    int width = macws_rfbScreen[0];
    int height = macws_rfbScreen[2];
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return NO;

    double now = macws_vnc_monotonic_seconds();
    BOOL continuous = kind == MacWSInputKindTouchMove ||
                      kind == MacWSInputKindHover;
    // libvncserver can deliver pointer motion much faster than an AppKit main
    // thread can dispatch it.  Preserve up to 120 Hz, but do not let redundant
    // motion fill both AF_UNIX receive queues ahead of a button transition.
    if (continuous && !reliable && macws_vnc_last_continuous_send > 0.0 &&
        now - macws_vnc_last_continuous_send < (1.0 / 120.0)) {
        return YES;
    }

    // The Retina hook makes RFB advertise physical coordinates (2388x1668 on
    // iPad13,6). Passing the point and its matching advertised dimensions
    // preserves the normalized location even if a non-Retina server is used.
    if (point.x < 0.0) point.x = 0.0;
    if (point.y < 0.0) point.y = 0.0;
    if (point.x >= width) point.x = width - 1;
    if (point.y >= height) point.y = height - 1;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = 0x564e430000000001ull,
        .timestamp = now,
        .x = (float)point.x,
        .y = (float)point.y,
        .pressure = (kind == MacWSInputKindTouchDown ||
                     kind == MacWSInputKindTouchMove) ? 1.0f : 0.0f,
        .contactID = macws_vnc_gesture_id,
        .frameWidth = (uint32_t)width,
        .frameHeight = (uint32_t)height,
        .targetPID = 0,
    };
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/private/tmp/macws_host_input.sock",
            sizeof(address.sun_path));
    ssize_t sent = -1;
    int saved_errno = 0;
    unsigned attempts = reliable ? 8 : 1;
    unsigned attempted = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        attempted = attempt + 1;
        if (macws_vnc_input_fd < 0)
            macws_vnc_input_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (macws_vnc_input_fd < 0) {
            saved_errno = errno;
        } else {
            sent = sendto(macws_vnc_input_fd, &record, sizeof(record),
                          MSG_DONTWAIT, (const struct sockaddr *)&address,
                          sizeof(address));
            if (sent == (ssize_t)sizeof(record)) break;
            saved_errno = sent < 0 ? errno : EMSGSIZE;
            if (saved_errno == EBADF || saved_errno == ECONNREFUSED) {
                close(macws_vnc_input_fd);
                macws_vnc_input_fd = -1;
            }
        }
        if (!reliable) break;
        // A WS recovery removes and recreates macwsinputd's socket.  Button
        // transitions can wait for that short namespace/queue race; motion is
        // deliberately lossy and never sleeps the VNC client thread.
        usleep((useconds_t)(1000u * (attempt + 1)));
    }
    BOOL ok = sent == (ssize_t)sizeof(record);
    if (ok && continuous) macws_vnc_last_continuous_send = now;
    static unsigned continuous_failures = 0;
    if (!continuous || !ok) {
        unsigned failure = !ok ? ++continuous_failures : continuous_failures;
        if (!continuous || failure <= 4 || (failure % 120) == 0) {
        fprintf(stderr,
            "#### OSXVNC INPUT kind=%u gesture=%u point=(%.1f,%.1f)/%dx%d "
            "sent=%zd errno=%d attempts=%u reliable=%s\n",
            kind, macws_vnc_gesture_id, point.x, point.y, width, height,
            sent, ok ? 0 : saved_errno, attempted, reliable ? "YES" : "NO");
        }
    }
    return ok;
}

static void macws_new_vnc_handle_mouse(id self, SEL command,
        unsigned int buttons, CGPoint point, id client) {
    macws_vnc_note_interaction();
    BOOL leftDown = (buttons & 1u) != 0;
    BOOL completedLeftGesture = !leftDown && macws_vnc_left_down;
    if (macws_orig_vnc_handle_mouse) {
        int scale = macws_vnc_integral_backing_scale();
        if (scale < 1) scale = 1;
        CGPoint quartzPoint = {
            point.x / (CGFloat)scale,
            point.y / (CGFloat)scale,
        };
        if (macws_vnc_native_all) {
            unsigned int previousButtons = atomic_load_explicit(
                &macws_vnc_native_buttons, memory_order_acquire);
            BOOL secondaryRelease = (previousButtons & 4u) != 0 &&
                                    (buttons & 4u) == 0;
            if (secondaryRelease) {
                // Runtime-confirmed on Terminal's real contextual menu: a
                // fast RFB secondary release could be queued before AppKit's
                // rightMouseDown handler entered its nested NSMenu tracker.
                // Failed sample: both NSEvent 3 and 4 returned through
                // -[NSApplication sendEvent:]. Successful samples: type 3
                // entered the tracker and type 4 was consumed there. Keep the
                // original system CGPostMouseEvent owner and serialize only
                // this transition long enough for the down to establish that
                // tracker. This is an input-transport compatibility delay,
                // not a menu action or state bypass.
                usleep(120000);
                static _Atomic uint64_t serializedRightUps;
                uint64_t serialized = atomic_fetch_add_explicit(
                    &serializedRightUps, 1,
                    memory_order_relaxed) + 1;
                if (serialized <= 24 || (serialized % 100) == 0) {
                    fprintf(stderr,
                        "#### OSXVNC RIGHT-UP-SERIALIZE event=%llu "
                        "delay=120ms rfb=(%.1f,%.1f)\n",
                        (unsigned long long)serialized, point.x, point.y);
                }
            }
            macws_orig_vnc_handle_mouse(self, command, buttons,
                                        quartzPoint, client);
            static _Atomic uint64_t nativeEvents;
            uint64_t nativeEvent = atomic_fetch_add_explicit(
                &nativeEvents, 1, memory_order_relaxed) + 1;
            if (nativeEvent <= 96 || (nativeEvent % 600) == 0) {
                fprintf(stderr,
                    "#### OSXVNC NATIVE-ALL event=%llu buttons=%#x "
                    "rfb=(%.1f,%.1f) quartz=(%.1f,%.1f) scale=%d\n",
                    (unsigned long long)nativeEvent, buttons,
                    point.x, point.y, quartzPoint.x, quartzPoint.y, scale);
            }
            atomic_store_explicit(&macws_vnc_native_buttons, buttons,
                                  memory_order_release);
            macws_vnc_schedule_native_pointer_frames(
                buttons, buttons != previousButtons);
            macws_vnc_left_down = leftDown;
            macws_vnc_last_point = point;
            return;
        }
        BOOL moved = point.x != macws_vnc_last_point.x ||
                     point.y != macws_vnc_last_point.y;
        BOOL otherButton = (buttons & ~1u) != 0;
        const double slop = 3.0 * (double)scale;

        // A stationary left click and a window drag have different proven
        // delivery owners on this system. Runtime evidence on 2026-07-28:
        // OSXvnc's CGPostMouseEvent path moved an NSWindow through AppKit's
        // modal move tracker, while a click at the exact Retina checkbox
        // coordinate reached this handler but left the checkbox unchanged.
        // The per-process AppInput tap path previously toggled that same real
        // NSButton. Buffer only the possible left-down until motion crosses a
        // small slop radius: then replay the down + moves through OSXvnc; on a
        // stationary release send one atomic AppInput tap. This also prevents
        // the duplicate nested mouseDown that AppKit rejected with "Periodic
        // events are already being generated" during the earlier dual-owner
        // implementation.
        if (otherButton) {
            macws_orig_vnc_handle_mouse(self, command, buttons,
                                        quartzPoint, client);
        } else if (leftDown && !macws_vnc_left_down) {
            macws_vnc_gesture_id++;
            if (macws_vnc_gesture_id == 0) macws_vnc_gesture_id++;
            macws_vnc_pending_down_point = point;
            macws_vnc_pending_down = YES;
            macws_vnc_remote_down = NO;
            // Preserve OSXvnc's cursor bookkeeping without posting a native
            // down that would duplicate the later AppInput tap.
            macws_orig_vnc_handle_mouse(self, command, 0,
                                        quartzPoint, client);
        } else if (leftDown && moved) {
            if (macws_vnc_pending_down) {
                double dx = point.x - macws_vnc_pending_down_point.x;
                double dy = point.y - macws_vnc_pending_down_point.y;
                if (dx * dx + dy * dy > slop * slop) {
                    CGPoint pendingQuartz = {
                        macws_vnc_pending_down_point.x / (CGFloat)scale,
                        macws_vnc_pending_down_point.y / (CGFloat)scale,
                    };
                    macws_orig_vnc_handle_mouse(self, command, 1,
                                                pendingQuartz, client);
                    macws_vnc_pending_down = NO;
                    macws_vnc_remote_down = YES;
                    macws_orig_vnc_handle_mouse(self, command, 1,
                                                quartzPoint, client);
                } else {
                    macws_orig_vnc_handle_mouse(self, command, 0,
                                                quartzPoint, client);
                }
            } else if (macws_vnc_remote_down) {
                macws_orig_vnc_handle_mouse(self, command, 1,
                                            quartzPoint, client);
            }
        } else if (!leftDown && macws_vnc_left_down) {
            if (macws_vnc_pending_down) {
                BOOL sent = macws_vnc_forward_input(
                    MacWSInputKindTap, macws_vnc_pending_down_point, YES);
                fprintf(stderr,
                    "#### OSXVNC CLICK-OWNER route=app-input gesture=%u "
                    "point=(%.1f,%.1f) sent=%s\n",
                    macws_vnc_gesture_id,
                    macws_vnc_pending_down_point.x,
                    macws_vnc_pending_down_point.y,
                    sent ? "YES" : "NO");
                macws_vnc_pending_down = NO;
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
            } else if (macws_vnc_remote_down) {
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
                macws_vnc_remote_down = NO;
                fprintf(stderr,
                    "#### OSXVNC DRAG-OWNER route=native gesture=%u "
                    "point=(%.1f,%.1f)\n",
                    macws_vnc_gesture_id, point.x, point.y);
            } else {
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
            }
        } else {
            macws_orig_vnc_handle_mouse(self, command, 0,
                                        quartzPoint, client);
        }
        static unsigned ownershipLogs;
        if (ownershipLogs++ < 8) {
            fprintf(stderr,
                "#### OSXVNC INPUT-OWNER rfb=(%.1f,%.1f) quartz=(%.1f,%.1f) "
                "buttons=%#x pending=%s drag=%s scale=%d\n",
                point.x, point.y, quartzPoint.x, quartzPoint.y,
                buttons, macws_vnc_pending_down ? "YES" : "NO",
                macws_vnc_remote_down ? "YES" : "NO", scale);
        }
        macws_vnc_left_down = leftDown;
        macws_vnc_last_point = point;
        if (completedLeftGesture && macws_vnc_share_on) {
            uint64_t serial = atomic_fetch_add_explicit(
                &macws_vnc_pointer_capture_serial, 1,
                memory_order_acq_rel) + 1;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    if (atomic_load_explicit(
                            &macws_vnc_pointer_capture_serial,
                            memory_order_acquire) == serial) {
                        macws_vnc_write_capture_request(
                            "POINTER", serial, buttons);
                    }
                });
        }
        return;
    }

    BOOL moved = point.x != macws_vnc_last_point.x ||
                 point.y != macws_vnc_last_point.y;
    if (leftDown && !macws_vnc_left_down) {
        // Hold a possible click until either movement crosses a small Retina-
        // scaled slop radius or button-up arrives.  A stationary click is then
        // one MacWSInputKindTap datagram, so down/up cannot be split by queue
        // pressure as observed at runtime (down sent=-1, up sent=52).
        macws_vnc_gesture_id++;
        if (macws_vnc_gesture_id == 0) macws_vnc_gesture_id++;
        macws_vnc_pending_down_point = point;
        macws_vnc_pending_down = YES;
        macws_vnc_remote_down = NO;
    } else if (leftDown && moved) {
        if (macws_vnc_pending_down) {
            double dx = point.x - macws_vnc_pending_down_point.x;
            double dy = point.y - macws_vnc_pending_down_point.y;
            double scale = (double)macws_vnc_integral_backing_scale();
            double slop = 3.0 * (scale > 0.0 ? scale : 1.0);
            if (dx * dx + dy * dy > slop * slop &&
                macws_vnc_forward_input(MacWSInputKindTouchDown,
                                        macws_vnc_pending_down_point, YES)) {
                macws_vnc_pending_down = NO;
                macws_vnc_remote_down = YES;
                (void)macws_vnc_forward_input(MacWSInputKindTouchMove,
                                              point, YES);
            }
        } else if (macws_vnc_remote_down) {
            (void)macws_vnc_forward_input(MacWSInputKindTouchMove, point, NO);
        }
    } else if (!leftDown && macws_vnc_left_down) {
        if (macws_vnc_pending_down) {
            (void)macws_vnc_forward_input(MacWSInputKindTap,
                                          macws_vnc_pending_down_point, YES);
            macws_vnc_pending_down = NO;
        } else if (macws_vnc_remote_down) {
            BOOL sent = macws_vnc_forward_input(MacWSInputKindTouchUp,
                                                point, YES);
            macws_vnc_release_pending = !sent;
            if (sent) macws_vnc_remote_down = NO;
        }
    } else if (moved) {
        if (macws_vnc_release_pending) {
            BOOL sent = macws_vnc_forward_input(MacWSInputKindTouchCancel,
                                                point, YES);
            if (sent) {
                macws_vnc_release_pending = NO;
                macws_vnc_remote_down = NO;
            }
        }
        (void)macws_vnc_forward_input(MacWSInputKindHover, point, NO);
    }
    macws_vnc_left_down = leftDown;
    macws_vnc_last_point = point;
}

static IOSurfaceRef macws_vnc_src = NULL;
// Returns true only when a complete mmap frame was copied.  A test gradient is
// diagnostic output and deliberately does not count as a real shared frame.
static bool macws_vnc_fill_test(int rectX, int rectY,
                                int rectWidth, int rectHeight) {
    if (!macws_vnc_fb || !macws_rfbScreen) return false;
    int padded = macws_rfbScreen[1];   // paddedWidthInBytes
    int height = macws_rfbScreen[2];   // height
    int bpp    = macws_rfbScreen[4];   // bitsPerPixel
    if (padded <= 0 || height <= 0 || height > 8192 || padded > (1 << 20)) return false;
    int bytespp = (bpp > 0 ? bpp / 8 : 4); if (bytespp < 1) bytespp = 4;
    // 1) Preferred: the detiled composite WS writes to the mmap'd file
    //    /tmp/macws_vnc_fb (IOSurfaceIsGlobal+Lookup is NULL cross-process on
    //    this iOS, so we use a shared mmap instead). Header (16B): magic 'VNCF',
    //    w, h, stride; BGRA8 data follows, then an atomic publication sequence.
    //    Gradient is the fallback.
    static void *rmap = NULL; static size_t rmap_sz = 0;
    if (!rmap) {
        int fd = open("/tmp/macws_vnc_fb", O_RDONLY);
        if (fd >= 0) {
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size >= 16) {
                void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
                if (m != MAP_FAILED) { rmap = m; rmap_sz = (size_t)st.st_size; }
            }
            close(fd);
        }
    }
    if (rmap && rmap_sz >= 16) {
        uint32_t *hdr = (uint32_t *)rmap;
        if (hdr[0] == 0x564E4346u) {
            size_t sh = hdr[2], sstride = hdr[3];
            char *data = (char *)rmap + 16;
            if (sstride > 0 && sh > 0 && sh <= (SIZE_MAX - 24) / sstride &&
                16 + sstride * sh + sizeof(uint64_t) <= rmap_sz) {
                const _Atomic uint64_t *sequenceAddress =
                    (const _Atomic uint64_t *)(data + sstride * sh);
                size_t sw = hdr[1];
                // paddedWidthInBytes is the server buffer stride, not its RFB
                // visible width. On the Retina iPad it is 2388*4 while the
                // advertised framebuffer is 1194 pixels wide. Treating the
                // stride as dw copied the physical frame 1:1, then libvncserver
                // transmitted only its left 1194 pixels: runtime input x=101
                // visibly landed at x~=203. Scale to screen.width while still
                // advancing destination rows by the padded stride.
                size_t capacityWidth = (size_t)padded / (size_t)bytespp;
                size_t dw = macws_rfbScreen[0] > 0
                    ? (size_t)macws_rfbScreen[0] : capacityWidth;
                if (dw > capacityWidth) return false;
                size_t x0 = 0, y0 = 0, x1 = dw, y1 = (size_t)height;
                if (rectWidth > 0 && rectHeight > 0) {
                    int64_t requestedX0 = rectX;
                    int64_t requestedY0 = rectY;
                    int64_t requestedX1 = requestedX0 + (int64_t)rectWidth;
                    int64_t requestedY1 = requestedY0 + (int64_t)rectHeight;
                    if (requestedX0 < 0) requestedX0 = 0;
                    if (requestedY0 < 0) requestedY0 = 0;
                    if (requestedX1 > (int64_t)dw) requestedX1 = (int64_t)dw;
                    if (requestedY1 > (int64_t)height)
                        requestedY1 = (int64_t)height;
                    if (requestedX1 <= requestedX0 ||
                        requestedY1 <= requestedY0) return false;
                    x0 = (size_t)requestedX0;
                    y0 = (size_t)requestedY0;
                    x1 = (size_t)requestedX1;
                    y1 = (size_t)requestedY1;
                }
                if (sw > SIZE_MAX / 4 || sw * 4 > sstride) return false;
                for (unsigned attempt = 0; attempt < 4; attempt++) {
                    uint64_t before = atomic_load_explicit(
                        sequenceAddress, memory_order_acquire);
                    if (before == 0 || (before & 1u)) {
                        usleep(1000);
                        continue;
                    }
                    if (bytespp == 4 && sw > 0 && sh > 0 && dw > 0 &&
                        height > 0 &&
                        (sw != dw || sh != (size_t)height)) {
                        for (size_t y = y0; y < y1; y++) {
                            size_t sy = y * sh / (size_t)height;
                            const uint32_t *src = (const uint32_t *)
                                (data + sy * sstride);
                            uint32_t *dst = (uint32_t *)
                                (macws_vnc_fb + y * (size_t)padded);
                            for (size_t x = x0; x < x1; x++) {
                                dst[x] = src[x * sw / dw];
                            }
                        }
                    } else {
                        size_t rows = ((size_t)height < sh)
                            ? (size_t)height : sh;
                        if (y1 > rows) y1 = rows;
                        size_t byteX = x0 * (size_t)bytespp;
                        size_t byteCount = (x1 - x0) * (size_t)bytespp;
                        if (byteX + byteCount > (size_t)padded ||
                            byteX + byteCount > sstride) return false;
                        for (size_t y = y0; y < y1; y++)
                            memcpy(macws_vnc_fb + y * (size_t)padded + byteX,
                                   data + y * sstride + byteX, byteCount);
                    }
                    atomic_thread_fence(memory_order_acquire);
                    uint64_t after = atomic_load_explicit(
                        sequenceAddress, memory_order_acquire);
                    if (after == before && !(after & 1u)) return true;
                    usleep(1000);
                }
                static _Atomic uint64_t unstable = 0;
                uint64_t count = atomic_fetch_add(&unstable, 1) + 1;
                if (count <= 8 || (count % 600) == 0) {
                    fprintf(stderr,
                        "#### OSXVNC mmap unstable #%llu rect=%d,%d %dx%d\n",
                        (unsigned long long)count,
                        rectX, rectY, rectWidth, rectHeight);
                }
                return false;
            }
        }
    }
    // 2) Fallback: test gradient (only when /tmp/macws_vnc_test exists).
    if (!macws_vnc_test_on) return false;
    int pxw = padded / bytespp;
    int x0 = rectWidth > 0 ? rectX : 0;
    int y0 = rectHeight > 0 ? rectY : 0;
    int x1 = rectWidth > 0 ? rectX + rectWidth : pxw;
    int y1 = rectHeight > 0 ? rectY + rectHeight : height;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > pxw) x1 = pxw;
    if (y1 > height) y1 = height;
    for (int y = y0; y < y1; y++) {
        unsigned char *row = (unsigned char *)macws_vnc_fb + (size_t)y * padded;
        for (int x = x0; x < x1; x++) {
            unsigned char *p = row + (size_t)x * bytespp;
            p[0] = (unsigned char)((x * 255) / (pxw ? pxw : 1)); // X ramp
            p[1] = (unsigned char)((y * 255) / height);          // Y ramp
            p[2] = 0x40;
            if (bytespp >= 4) p[3] = 0xff;
        }
    }
    return false;
}

static char *macws_new_rfbGetFB(void) {
    char *p = macws_orig_rfbGetFB ? macws_orig_rfbGetFB() : NULL;
    macws_vnc_fb = p;
    macws_vnc_fill_test(0, 0, 0, 0);
    return p;
}
static void macws_new_rfbGetFBRect(int x, int y, int w, int h) {
    // In shared-frame mode, rfbGetFramebuffer() has already allocated the
    // server buffer. Calling the original rectangle updater would enter
    // CGDisplayCreateImage/_XHWCaptureDesktop again. Runtime crash evidence:
    // WSIOSurfaceDebugTallyAndAbort -> CreateCaptureSurface ->
    // _XHWCaptureDesktop while a VNC update was in progress. The mmap is the
    // selected capture backend, so deliver it directly. If its first frame is
    // not ready yet, preserve the allocated buffer and wait for the next poll.
    if (macws_vnc_share_on) {
        bool copied = macws_vnc_fill_test(x, y, w, h);
        static int lg = 0;
        if (lg < 3) {
            fprintf(stderr, "#### OSXVNC mmap rect delivery copied=%d rect=%d,%d %dx%d\n",
                    copied ? 1 : 0, x, y, w, h);
            lg++;
        }
        return;
    }
    if (macws_orig_rfbGetFBRect) macws_orig_rfbGetFBRect(x, y, w, h);
    macws_vnc_fill_test(x, y, w, h);
}

static void macws_install_osxvnc_hooks(void) {
    const char *prog = getprogname();
    if (!prog || !strstr(prog, "OSXvnc")) return;
    macws_vnc_test_on = (access("/tmp/macws_vnc_test", F_OK) == 0);
    macws_vnc_share_on = (getenv("MACWS_VNC_SHARE") ||
                          access("/tmp/macws_vnc_share", F_OK) == 0);
    macws_vnc_native_all = getenv("MACWS_VNC_NATIVE_ALL") != NULL ||
        access("/tmp/macws_vnc_native_all", F_OK) == 0;
    const struct mach_header *mh = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "OSXvnc-server")) { mh = _dyld_get_image_header(i); break; }
    }
    if (!mh) mh = _dyld_get_image_header(0);
    if (!mh) return;
    char *base = (char *)mh;
    macws_rfbScreen = (int *)(base + 0x79bf8);
    macws_rfbBackingScale = (double *)(base + 0x7a1e8);
    MSHookFunction(base + 0xd114,
        (void *)macws_new_vnc_refresh_callback,
        (void **)&macws_vnc_refresh_callback);
    void *cgWidth = dlsym(RTLD_DEFAULT, "CGDisplayPixelsWide");
    void *cgHeight = dlsym(RTLD_DEFAULT, "CGDisplayPixelsHigh");
    if (cgWidth) MSHookFunction(cgWidth,
        (void *)macws_new_CGDisplayPixelsWide,
        (void **)&macws_orig_CGDisplayPixelsWide);
    if (cgHeight) MSHookFunction(cgHeight,
        (void *)macws_new_CGDisplayPixelsHigh,
        (void **)&macws_orig_CGDisplayPixelsHigh);
    MSHookFunction(base + 0xd9d4, (void *)macws_new_rfbGetFB,     (void **)&macws_orig_rfbGetFB);
    MSHookFunction(base + 0xdc28, (void *)macws_new_rfbGetFBRect, (void **)&macws_orig_rfbGetFBRect);
    Class serverClass = objc_getClass("VNCServer");
    Method mouseMethod = serverClass ? class_getInstanceMethod(serverClass,
        sel_registerName("handleMouseButtons:atPoint:forClient:")) : NULL;
    if (mouseMethod) {
        macws_orig_vnc_handle_mouse =
            (MacWSVNCHandleMouse)method_getImplementation(mouseMethod);
        method_setImplementation(mouseMethod, (IMP)macws_new_vnc_handle_mouse);
    }
    Method keyboardMethod = serverClass ? class_getInstanceMethod(serverClass,
        sel_registerName("handleKeyboard:forSym:forClient:")) : NULL;
    if (keyboardMethod) {
        macws_orig_vnc_handle_keyboard =
            (MacWSVNCHandleKeyboard)method_getImplementation(keyboardMethod);
        method_setImplementation(keyboardMethod,
                                 (IMP)macws_new_vnc_handle_keyboard);
    }
    if (macws_vnc_share_on && macws_vnc_refresh_callback) {
        pthread_t watcher;
        int watcherError = pthread_create(
            &watcher, NULL, macws_vnc_generation_watcher, NULL);
        if (watcherError == 0) pthread_detach(watcher);
        else fprintf(stderr,
            "#### OSXVNC mmap generation watcher failed error=%d\n",
            watcherError);
    }
    fprintf(stderr, "#### OSXVNC delivery hooks installed (test=%d share=%d native-all=%d input=%s keyboard=%s) base=%p rfbScreen=%p\n",
            macws_vnc_test_on, macws_vnc_share_on, macws_vnc_native_all,
            mouseMethod ? "YES" : "NO",
            keyboardMethod ? "YES" : "NO",
            (void *)mh, (void *)macws_rfbScreen);
}

__attribute__((constructor)) void InitStuff() {
    macws_install_glass_blur_ab_if_requested();
    EnableJIT();
    macws_install_crash_diag();
    macws_install_osxvnc_hooks();
    // HID bypass is OPT-IN. Whole-IOKit-symbol hooking creates a tower of
    // MSHook'd functions; if any one of them is itself called recursively
    // via PAC-signed pointers from elsewhere in IOKit, the bypass starts
    // cascading crashes. In practice, WindowServer survives the original
    // CFBinaryPlist BUS_ADRALN crash by itself most of the time once the
    // other AGX-native patches are in place, so don't install the bypass
    // by default. Re-enable with MACWS_HID_BYPASS=1 on a process whose
    // IOMFB/SkyLight HID setup is reliably crashing.
    // Targeted fix for the IOMFBServer thread BUS_ADRALN: skip just the
    // CFBinaryPlist deserialize step inside IOKit's HID-property cache.
    macws_install_iohid_unserialize_bypass();
    // AGX renamer patch — opt-in via MACWS_AGX_RENAMER_PATCH=1.
    macws_install_agx_renamer_patch();
    // (AGCLLVMCtx::compile fast-math hook attempt — VERIFIED NOT
    // CALLED for CA pipeline compiles. The fast-math AIR-intrinsic
    // rename happens in AGCLLVMUserObject::compile's optimization
    // passes which read FastMathFlags from each llvm::Instruction's
    // own metadata, NOT from the AGCFastMathFlags arg to
    // AGCLLVMCtx::compile. Env-level toggles
    // AGC_ENABLE_F16_FASTMATH_BUILTINS=0 and AGC_DISABLE_OPTIMIZATIONS
    // also fail to suppress the rename. Real fix requires either
    // patching the rename pass directly or rewriting the LLVM IR
    // before it reaches the AGX backend — open work. The
    // QC-metallib-substitute fallback in Metal_hooks.x stays available
    // via MACWS_PIPELINE_FALLBACK=1 as a temporary survival path while
    // the proper fix is being designed.)
    if (getenv("MACWS_AGC_FASTMATH_HOOK")) {
        macws_install_agc_fastmath_disable();
    }
    // Verify-bypass experiment: if the unlowered `agx.air.fract.v3f16.fast`
    // is benign (codegen has a fallback or never executes it on the
    // observed CA pipelines), bypassing the verifier is the simplest
    // viable elegant fix. Opt-in via env to keep the verifier honest
    // in normal operation.
    if (getenv("MACWS_AGC_VERIFY_BYPASS")) {
        const char *path =
            "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore";
        void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        (void)h;
        MSImageRef img = MSGetImageByName(path);
        if (img) {
            macws_install_agc_verify_bypass(img);
        } else {
            fprintf(stderr,
                "#### MACWS_AGC_VERIFY_BYPASS: AGXCompilerCore not in "
                "image table, skip\n");
        }
    }
    // Optional: trace which abort_with_payload site fires (opt-in via env).
    macws_install_abort_trace();
    // Assert bypass needs no env gate — it's strictly defensive against
    // CA::OGL::MetalContext assert() calls that fire as a downstream
    // consequence of a failed pipeline build.
    macws_install_assert_bypass();
    // Broader bulk hook (one stub per public `IOHIDEventSystem*` symbol)
    // is opt-in and currently unstable — see the comment block in
    // `macws_install_iomfb_hid_bypass`. Keep it accessible for debugging.
    if (getenv("MACWS_HID_BYPASS")) {
        macws_install_iomfb_hid_bypass();
    }

    // Pre-load IOGPU BEFORE Metal.framework speculatively loads AGXMetal13_3.
    // AGXMetal13_3 has cross-image GOT entries that reference IOGPU symbols
    // (the pool allocator, IOGPUMetalResource helpers, ...). If IOGPU is not
    // yet in the address space when dyld binds AGXMetal13_3, those slots
    // resolve to null/<unresolved>. A later dlopen of IOGPU does NOT trigger
    // a re-bind, so the slots stay broken and AGX::Mempool::grow's lambda
    // tail-jumps into garbage (SIGSEGV at addr 0x30, see memory note
    // agx-mempool-grow-fault-decomposed). Doing this in the constructor
    // (instead of in the getMetalPluginClassForService hook) guarantees IOGPU
    // is bound before Metal touches AGXMetal13_3.
    if (getenv("MACWS_AGX_NATIVE")) {
        const char *iogpuPaths[] = {
            "/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
            "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU",
            NULL
        };
        void *iogpu = NULL;
        for (int i = 0; iogpuPaths[i]; i++) {
            iogpu = dlopen(iogpuPaths[i], RTLD_GLOBAL | RTLD_NOW);
            if (iogpu) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE [ctor] pre-loaded IOGPU via %s -> %p\n",
                    iogpuPaths[i], iogpu);
                break;
            }
        }
        if (!iogpu) {
            fprintf(stderr, "#### MACWS_AGX_NATIVE [ctor] could NOT pre-load IOGPU: %s\n", dlerror());
        }
    }

    _dyld_register_func_for_add_image((void (*)(const struct mach_header *, intptr_t))loadImageCallback);
}

extern int gpu_bundle_find_trusted(const char *name, char *trusted_path, size_t trusted_path_len);

int sysctlbyname_new(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // printf("debugbydcmmc Calling interposed sysctlbyname\n");
    if (name && oldp) {
        if(!strcmp(name, "kern.osvariant_status")) {
            *(unsigned long long *)oldp = 0x70010000f388828b; // bit 0 = diagnostics enabled
            return 0;
        } else if(!strcmp(name, "kern.osproductversion")) {
            sysctlbyname(name, oldp, oldlenp, newp, newlen);
            char *version = (char *)oldp;
            assert(version[0] == '1');
            if(version[1] >= '4') {
                version[1] -= 3; // 16 -> 13
            } else {
                version[1] = '1'; // always macOS 11
            }
            return 0;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

extern int __mac_syscall(const char *policy, int operation, void *argument);
extern int csr_get_active_config(uint32_t *configuration);
int __mac_syscall_new(const char *policy, int operation, void *argument) {
    // Chromium 148 queries this macOS AMFI policy specifically to decide
    // whether child task-control ports are movable.  The iOS 16.3 kernel
    // returns ENOSYS for the macOS policy operation, while its task control
    // ports are in fact hard-immovable.  Chromium treats query failure as
    // "movable" and asks every helper to MOVE_SEND mach_task_self(), which the
    // kernel terminates with EXC_GUARD/ILLEGAL_MOVE.
    //
    // Report the equivalent `amfi_get_out_of_my_way` bit so Chromium uses its
    // own documented no-task-port fallback (crbug.com/1291789).  This is a
    // narrow system-policy compatibility result, not a mach_msg rewrite or a
    // guard bypass.  Keep it opt-in for macOS applications that need it.
    if (getenv("MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT") && policy && argument &&
        strcmp(policy, "AMFI") == 0 && operation == 0x60) {
        *(uint64_t *)argument = 1ULL << 2;
        static _Atomic bool logged = false;
        if (!atomic_exchange_explicit(&logged, true, memory_order_relaxed)) {
            fprintf(stderr,
                "#### AMFI-POLICY-COMPAT policy=AMFI op=0x60 status=0x4 "
                "(iOS task ports are hard-immovable)\n");
        }
        return 0;
    }
    return __mac_syscall(policy, operation, argument);
}

int csr_get_active_config_new(uint32_t *configuration) {
    // iOS has no macOS System Integrity Protection configuration and returns
    // ENOSYS from this compatibility symbol.  Chromium 148 queries it only for
    // its system-policy crash key immediately after the AMFI task-port query.
    // Expose the conservative macOS value (no CSR exceptions enabled) instead
    // of leaving the API absent.  Keeping all permission bits clear avoids
    // granting or advertising capabilities that this shim does not provide.
    if (getenv("MACWS_MACOS_SYSTEM_POLICY_COMPAT") && configuration) {
        *configuration = 0;
        static _Atomic bool logged = false;
        if (!atomic_exchange_explicit(&logged, true, memory_order_relaxed)) {
            fprintf(stderr,
                "#### CSR-POLICY-COMPAT active_config=0x0 "
                "(conservative iOS compatibility value)\n");
        }
        return 0;
    }
    return csr_get_active_config(configuration);
}

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char **params, char **errorbuf);
int sandbox_init_with_parameters_new(const char *profile, uint64_t flags, const char **params, char **errorbuf) {
    // printf("debugbydcmmc Calling interposed sandbox_init_with_parameters\n");
    if (errorbuf) *errorbuf = NULL;
    return 0;
}

extern int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
int sandbox_init_new(const char *profile, uint64_t flags, char **errorbuf) {
    // RE-confirmed via the actual macOS 13.4 /usr/libexec/pboard at
    // main+0x44: it calls sandbox_init("com.apple.pboard", 1, &error) and
    // exits 1 when the iOS host rejects that macOS named profile. The chroot
    // already cannot enforce macOS sandbox profiles (the parameterized entry
    // point above is the established compatibility boundary), so cover the
    // deprecated three-argument API as the same boundary and leave no stale
    // error object for the caller to free.
    if (errorbuf) *errorbuf = NULL;
    static _Atomic bool logged = false;
    if (!atomic_exchange_explicit(&logged, true, memory_order_relaxed)) {
        fprintf(stderr,
            "#### SANDBOX-COMPAT sandbox_init profile=%s flags=%#llx -> 0 "
            "(macOS named profiles unavailable on iOS host)\n",
            profile ?: "(null)", (unsigned long long)flags);
    }
    return 0;
}

kern_return_t mach_port_construct_new(ipc_space_t task, mach_port_options_ptr_t options, uint64_t context, mach_port_name_t *name) {
    options->flags &= ~MPO_TG_BLOCK_TRACKING;
    return mach_port_construct(task, options, context, name);
}

// Diagnostic only: Chromium's Mojo channel is being terminated by the iOS
// kernel with EXC_GUARD/ILLEGAL_MOVE while sending a complex `MOJO` message.
// The crash report preserves the disposition (MOVE_SEND), but not the message
// buffer itself.  Capture the exact descriptor and current right types before
// entering the kernel.  This deliberately does not rewrite the message or
// suppress the guard exception; enable it only with MACWS_MACH_MSG_TRACE=1.
static bool macws_mach_msg_trace_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_MACH_MSG_TRACE") ? 1 : 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

mach_msg_return_t mach_msg_new(mach_msg_header_t *message,
                               mach_msg_option_t option,
                               mach_msg_size_t send_size,
                               mach_msg_size_t receive_limit,
                               mach_port_name_t receive_name,
                               mach_msg_timeout_t timeout,
                               mach_port_name_t notify) {
    if (macws_mach_msg_trace_enabled() && message &&
        (option & MACH_SEND_MSG) &&
        (message->msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
        message->msgh_id == (mach_msg_id_t)'MOJO' &&
        send_size >= sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t)) {
        const mach_msg_body_t *body =
            (const mach_msg_body_t *)(message + 1);
        uint32_t count = body->msgh_descriptor_count;
        const mach_msg_port_descriptor_t *descriptors =
            (const mach_msg_port_descriptor_t *)(body + 1);
        size_t descriptor_bytes =
            (size_t)count * sizeof(mach_msg_port_descriptor_t);
        size_t required = sizeof(mach_msg_header_t) +
                          sizeof(mach_msg_body_t) + descriptor_bytes;
        if (count <= 64 && required <= send_size) {
            char line[768];
            int used = snprintf(line, sizeof(line),
                "#### MACH-MSG-SEND pid=%d id=0x%x bits=0x%x remote=%u "
                "local=%u size=%u descriptors=%u",
                getpid(), message->msgh_id, message->msgh_bits,
                message->msgh_remote_port, message->msgh_local_port,
                send_size, count);
            for (uint32_t i = 0; i < count && used > 0 &&
                 (size_t)used < sizeof(line); i++) {
                const mach_msg_port_descriptor_t *descriptor =
                    &descriptors[i];
                mach_port_type_t right_types = 0;
                kern_return_t type_kr = mach_port_type(
                    mach_task_self(), descriptor->name, &right_types);
                int appended = snprintf(line + used, sizeof(line) - used,
                    " d%u={name=%u,disp=%u,type=%u,rights=0x%x,type_kr=0x%x}",
                    i, descriptor->name, descriptor->disposition,
                    descriptor->type, right_types, type_kr);
                if (appended < 0) break;
                used += appended;
            }
            if (used > 0) {
                size_t length = (size_t)used < sizeof(line) ?
                    (size_t)used : sizeof(line) - 1;
                if (length + 1 < sizeof(line)) line[length++] = '\n';
                write(STDERR_FILENO, line, length);
            }
        }
    }
    // RE-confirmed via SkyLight`_SLSCopyWindowGroup: the failing request is a
    // 0x24-byte send whose header bits are 0x1513.  Query only this request so
    // the diagnostic does not add a mach_port_type() round trip to every IPC.
    bool trace_sls_window_group =
        macws_mach_msg_trace_enabled() && message &&
        (option & MACH_SEND_MSG) && message->msgh_bits == 0x1513 &&
        send_size == 0x24;
    mach_port_type_t destination_types = 0;
    kern_return_t destination_type_kr = KERN_INVALID_ARGUMENT;
    if (trace_sls_window_group) {
        destination_type_kr = mach_port_type(
            mach_task_self(), message->msgh_remote_port,
            &destination_types);
    }

    mach_msg_return_t result = mach_msg(
        message, option, send_size, receive_limit, receive_name,
        timeout, notify);
    if (trace_sls_window_group && result == MACH_SEND_INVALID_DEST) {
        char line[320];
        int length = snprintf(
            line, sizeof(line),
            "#### MACH-MSG-INVALID-DEST pid=%d id=0x%x bits=0x%x "
            "remote=%u local=%u send=%u option=0x%x "
            "rights_before=0x%x type_kr=0x%x result=0x%x\n",
            getpid(), message->msgh_id, message->msgh_bits,
            message->msgh_remote_port, message->msgh_local_port,
            send_size, option, destination_types,
            destination_type_kr, result);
        if (length > 0) {
            size_t write_length = (size_t)length < sizeof(line) ?
                (size_t)length : sizeof(line) - 1;
            write(STDERR_FILENO, line, write_length);
        }
    }
    return result;
}

// Simulate functions that are not implemented in iOS kernel
au_asid_t audit_token_to_asid_new(audit_token_t atoken) {
    // fake asid to pid
    return atoken.val[6] = atoken.val[5];
}
uid_t audit_token_to_auid_new(audit_token_t atoken) {
    return atoken.val[0] = 501;
}
void auditinfo_fill(auditinfo_addr_t *addr) {
    if(addr->ai_asid == 0) {
        addr->ai_asid = getpid();
    }
    addr->ai_auid = 501;
    if(getuid() == 0) {
        addr->ai_mask.am_success = 0;
        addr->ai_mask.am_failure = 0;
    } else {
        addr->ai_mask.am_success = -1;
        addr->ai_mask.am_failure = -1;
    }
    addr->ai_termid.at_port = 0x3000002;
    addr->ai_termid.at_type = 0x4;
    memset(addr->ai_termid.at_addr, 0, sizeof(addr->ai_termid.at_addr));
    addr->ai_flags = 0x6030;
}
void auditpinfo_fill(auditpinfo_addr_t *addr) {
    if(addr->ap_pid == 0) {
        addr->ap_pid = getpid();
    }
    addr->ap_auid = 501;
    if(getuid() == 0) {
        addr->ap_mask.am_success = 0;
        addr->ap_mask.am_failure = 0;
    } else {
        addr->ap_mask.am_success = -1;
        addr->ap_mask.am_failure = -1;
    }
    addr->ap_termid.at_port = 0x3000002;
    addr->ap_termid.at_type = 0x4;
    memset(addr->ap_termid.at_addr, 0, sizeof(addr->ap_termid.at_addr));
    addr->ap_asid = addr->ap_pid;
    addr->ap_flags = 0x6030;
}
int auditon_new(int cmd, void *data, uint32_t length) {
    if(!data) {
        errno = EINVAL;
        return -1;
    }
    switch(cmd) {
        case A_GETSINFO_ADDR: {
            auditinfo_addr_t *addr = (auditinfo_addr_t *)data;
            auditinfo_fill(addr);
        } return 0;
        case A_GETPINFO_ADDR: {
            auditpinfo_addr_t *addr = (auditpinfo_addr_t *)data;
            auditpinfo_fill(addr);
        } return 0;
        case A_GETCOND: {
            if(length < sizeof(int)) {
                errno = EINVAL;
                return -1;
            }
            int *cond = (int *)data;
            *cond = 2; // AUC_NOAUDIT
        } return 0;
        default:
            NSLog(@"auditon: unimplemented cmd: %d", cmd);
            abort();
    }
}
int getaudit_addr_new(auditinfo_addr_t *auditinfo_addr, u_int length) {
    if(auditinfo_addr == NULL || length < sizeof(auditinfo_addr_t)) {
        return EINVAL;
    }
    auditinfo_addr->ai_asid = getpid();
    auditinfo_fill(auditinfo_addr);
    return 0;
}

void *mmap_new(void *address, size_t size, int protection, int flags, int fd,
               off_t offset) {
    void *result = mmap(address, size, protection, flags, fd, offset);
    if (!macws_jit_mprotect_compat_enabled() ||
        (flags & MAP_JIT) == 0 || result != MAP_FAILED || errno != EINVAL) {
        return result;
    }

    // Runtime-confirmed on iOS 16.3: every MAP_JIT shape returns EINVAL,
    // including the first 16-KiB request from an iOS-platform probe carrying
    // dynamic-codesigning, allow-jit, unsigned-executable-memory, and
    // verified-jit entitlements.  The same process can perform RW -> RX
    // mprotect transitions after EnableJIT(), so retain that W^X model.
    result = mmap(address, size, protection, flags & ~MAP_JIT, fd, offset);
    if (result != MAP_FAILED) {
        macws_jit_record_range(result, size);
    }
    return result;
}

int mprotect_new(void *address, size_t size, int protection) {
    int effective = protection;
    bool jit_overlap = macws_jit_mprotect_compat_enabled() &&
        macws_jit_range_overlaps((uintptr_t)address, size);
    if (jit_overlap &&
        protection == (PROT_READ | PROT_WRITE | PROT_EXEC)) {
        // iOS's VM_MAP_POLICY_WX_STRIP_X performs this same reduction for a
        // normal mapping.  Make it explicit so V8 receives the writable half
        // of the contract; pthread_jit_write_protect_np_new supplies RX.
        effective = PROT_READ | PROT_WRITE;
    }
    int result = mprotect(address, size, effective);
    if (jit_overlap && getenv("MACWS_JIT_MPROTECT_TRACE")) {
        unsigned sequence = atomic_fetch_add_explicit(
            &g_macws_jit_mprotect_calls, 1, memory_order_relaxed) + 1;
        if (sequence <= 256 || (sequence % 1024) == 0) {
            void *caller = __builtin_return_address(0);
            Dl_info image = {0};
            dladdr(caller, &image);
            fprintf(stderr,
                "#### JIT-MPROTECT call #%u addr=%p size=%#zx "
                "requested=%#x effective=%#x result=%d errno=%d "
                "caller=%p image=%s offset=%#llx\n",
                sequence, address, size, protection, effective, result,
                result == 0 ? 0 : errno, caller,
                image.dli_fname ?: "(unknown)",
                (unsigned long long)(image.dli_fbase
                    ? (uintptr_t)caller - (uintptr_t)image.dli_fbase : 0));
        }
    }
    return result;
}

int munmap_new(void *address, size_t size) {
    int result = munmap(address, size);
    if (result == 0 && macws_jit_mprotect_compat_enabled()) {
        macws_jit_remove_range(address, size);
    }
    return result;
}

extern kern_return_t mach_vm_remap(
    vm_map_t target_task, mach_vm_address_t *target_address,
    mach_vm_size_t size, mach_vm_offset_t mask, int flags,
    vm_map_t source_task, mach_vm_address_t source_address, boolean_t copy,
    vm_prot_t *current_protection, vm_prot_t *maximum_protection,
    vm_inherit_t inheritance);

kern_return_t mach_vm_remap_new(
    vm_map_t target_task, mach_vm_address_t *target_address,
    mach_vm_size_t size, mach_vm_offset_t mask, int flags,
    vm_map_t source_task, mach_vm_address_t source_address, boolean_t copy,
    vm_prot_t *current_protection, vm_prot_t *maximum_protection,
    vm_inherit_t inheritance) {
    vm_prot_t requested = current_protection ? *current_protection : VM_PROT_NONE;
    if (macws_jit_mprotect_compat_enabled() && target_address &&
        (requested & VM_PROT_EXECUTE) != 0 &&
        macws_jit_range_overlaps((uintptr_t)*target_address, (size_t)size)) {
        // RE/runtime evidence: on this kernel a successful remap from an r-x
        // Electron __TEXT source changes both returned protections and the
        // destination to r--.  Decline the optional optimization before it
        // overwrites V8's writable destination; V8 then copies the blob under
        // its normal RwxMemoryWriteScope.
        unsigned sequence = atomic_fetch_add_explicit(
            &g_macws_jit_remap_declines, 1, memory_order_relaxed) + 1;
        fprintf(stderr,
            "#### JIT-MPROTECT remap decline #%u dst=%p size=%#llx "
            "src=%p requested=%#x -> V8 copy fallback\n",
            sequence, (void *)(uintptr_t)*target_address,
            (unsigned long long)size, (void *)(uintptr_t)source_address,
            requested);
        return KERN_NOT_SUPPORTED;
    }
    return mach_vm_remap(target_task, target_address, size, mask, flags,
                         source_task, source_address, copy,
                         current_protection, maximum_protection, inheritance);
}

// pthread.h marks this API unavailable for iOS even though the symbol is in
// libSystem and macOS Electron imports it.  Name the same Mach-O symbol through
// an undecorated declaration so the iOS SDK availability attribute does not
// prevent building the chroot compatibility interposer.
extern void macws_pthread_jit_write_protect_original(int enabled)
    __asm("_pthread_jit_write_protect_np");
void pthread_jit_write_protect_np_new(int enabled) {
    if (!macws_jit_mprotect_compat_enabled()) {
        macws_pthread_jit_write_protect_original(enabled);
        return;
    }

    // Runtime-confirmed by Code-2026-07-28-135327.ips: the iOS 16.3
    // libsystem_pthread symbol exists but ends in brk #1 (+516) when called by
    // this macOS process.  In compatibility mode the process-wide mprotect
    // transitions below are the complete W^X implementation; do not enter the
    // unavailable APRR/thread-local system stub.  Calls made before V8 records
    // its first MAP_JIT range have no pages to transition.
    if (atomic_load_explicit(&g_macws_jit_range_count,
                             memory_order_acquire) == 0) {
        return;
    }

    // Chromium installs and refreshes crash plumbing while its child
    // processes start.  Reassert the SIGBUS fetch barrier frequently during
    // startup, then only periodically once V8 is warm.  This is deliberately
    // outside g_macws_jit_state_lock: sigaction() may take libc locks and the
    // handler itself must never wait for our state mutex.
    unsigned handler_check = atomic_fetch_add_explicit(
        &g_macws_jit_handler_checks, 1, memory_order_relaxed) + 1;
    if (handler_check <= 64 || (handler_check % 1024) == 0) {
        macws_jit_ensure_exec_barrier_handler();
    }

    pthread_mutex_lock(&g_macws_jit_state_lock);
    if (!enabled) {
        if (!g_macws_jit_thread_writable) {
            unsigned writers = atomic_load_explicit(
                &g_macws_jit_active_writers, memory_order_relaxed);
            if (writers == 0) {
                // Publish the writer before removing execute permission.  A
                // racing fetch that faults after the mprotect must know it can
                // wait; publishing early is harmless while the range is RX.
                atomic_store_explicit(&g_macws_jit_active_writers, 1,
                                      memory_order_release);
                macws_jit_set_all_permissions(PROT_READ | PROT_WRITE);
            } else {
                atomic_store_explicit(&g_macws_jit_active_writers,
                                      writers + 1, memory_order_release);
            }
            g_macws_jit_thread_writable = true;
        }
    } else {
        if (g_macws_jit_thread_writable) {
            g_macws_jit_thread_writable = false;
            unsigned writers = atomic_load_explicit(
                &g_macws_jit_active_writers, memory_order_relaxed);
            if (writers == 1) {
                // Keep active_writers nonzero until every range is executable
                // again.  Waiting fetches retry only after the release store.
                macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
                atomic_store_explicit(&g_macws_jit_active_writers, 0,
                                      memory_order_release);
            } else if (writers > 1) {
                atomic_store_explicit(&g_macws_jit_active_writers,
                                      writers - 1, memory_order_release);
            }
        } else if (atomic_load_explicit(&g_macws_jit_active_writers,
                                        memory_order_acquire) == 0) {
            // Establish executable state for a newly recorded range even if
            // V8's first observed transition is an enable operation.
            macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
        }
    }
    pthread_mutex_unlock(&g_macws_jit_state_lock);
}

IOSurfaceRef IOSurfaceCreate_new(NSMutableDictionary *properties) {
    // WindowServer composites window content into Apple-GPU LOSSLESS-COMPRESSED / TILED
    // IOSurfaces (IOSurfacePlaneCompressionType != 0, pf 0x26425241, 16x16 tiles). The
    // MTLSimDevice simulator cannot read/write compressed-tiled textures, so the composited
    // CONTENT comes out BLACK (chrome, drawn uncompressed, is fine). Detect a compressed
    // surface and rebuild it as PLAIN UNCOMPRESSED BGRA (linear) so the sim Metal device can
    // write it. See memory agx-direct-path-kernel-abi-deadend UPDATE 12.
    int w = [[properties objectForKey:@"IOSurfaceWidth"] intValue];
    int h = [[properties objectForKey:@"IOSurfaceHeight"] intValue];
    NSArray *planes = [properties objectForKey:@"IOSurfacePlaneInfo"];
    BOOL compressed = NO;
    if([planes isKindOfClass:[NSArray class]]) {
        for(NSDictionary *pl in planes) {
            id ct = [pl objectForKey:@"IOSurfacePlaneCompressionType"];
            if(ct && [ct intValue] != 0) { compressed = YES; break; }
        }
    }
    NSDictionary *useProps = properties;
    if(compressed && w > 0 && h > 0) {
        const int bpe = 4;                 // BGRA8888
        size_t bytesPerRow = (size_t)w * bpe;
        size_t planeSize   = bytesPerRow * (size_t)h;
        NSMutableDictionary *np = [NSMutableDictionary dictionary];
        np[@"IOSurfaceWidth"]  = @(w);
        np[@"IOSurfaceHeight"] = @(h);
        np[@"IOSurfacePixelFormat"] = @((unsigned int)'BGRA');   // 0x42475241, uncompressed
        np[@"IOSurfaceBytesPerElement"] = @(bpe);
        np[@"IOSurfaceBytesPerRow"] = @(bytesPerRow);
        np[@"IOSurfaceAllocSize"] = @(planeSize);
        np[@"IOSurfaceCacheMode"] = [properties objectForKey:@"IOSurfaceCacheMode"] ?: @0;
        np[@"IOSurfacePixelSizeCastingAllowed"] = @0;
        // single linear plane, no compression keys
        np[@"IOSurfacePlaneInfo"] = @[ @{
            @"IOSurfacePlaneWidth": @(w),
            @"IOSurfacePlaneHeight": @(h),
            @"IOSurfacePlaneBytesPerRow": @(bytesPerRow),
            @"IOSurfacePlaneBytesPerElement": @(bpe),
            @"IOSurfacePlaneElementWidth": @1,
            @"IOSurfacePlaneElementHeight": @1,
            @"IOSurfacePlaneOffset": @0,
            @"IOSurfacePlaneSize": @(planeSize),
            @"IOSurfaceAddressFormat": @0,
        } ];
        useProps = np;
    }
    IOSurfaceRef result = IOSurfaceCreate((NSDictionary *)useProps);
    // Log EVERY surface (size + format + compression) to map the full topology — the per-window
    // content source surface (e.g. 500x350) vs the 1920x1080 display/composite surfaces.
    unsigned int pf = [[properties objectForKey:@"IOSurfacePixelFormat"] unsignedIntValue];
    char fcc[5] = { (char)(pf>>24), (char)(pf>>16), (char)(pf>>8), (char)pf, 0 };
    fprintf(stderr, "#### IOSURF %dx%d pf=0x%x('%s') comp=%d -> %p%s\n",
            w, h, pf, fcc, (int)compressed, (void*)result, compressed ? " [DECOMP]" : "");
    return result;
}

DYLD_INTERPOSE(sysctlbyname_new, sysctlbyname);
DYLD_INTERPOSE(__mac_syscall_new, __mac_syscall);
DYLD_INTERPOSE(csr_get_active_config_new, csr_get_active_config);
DYLD_INTERPOSE(sandbox_init_with_parameters_new, sandbox_init_with_parameters);
DYLD_INTERPOSE(sandbox_init_new, sandbox_init);
DYLD_INTERPOSE(mach_port_construct_new, mach_port_construct);
DYLD_INTERPOSE(mach_msg_new, mach_msg);
DYLD_INTERPOSE(audit_token_to_asid_new, audit_token_to_asid);
DYLD_INTERPOSE(audit_token_to_auid_new, audit_token_to_auid);
DYLD_INTERPOSE(auditon_new, auditon);
DYLD_INTERPOSE(getaudit_addr_new, getaudit_addr);
DYLD_INTERPOSE(mmap_new, mmap);
DYLD_INTERPOSE(mprotect_new, mprotect);
DYLD_INTERPOSE(munmap_new, munmap);
DYLD_INTERPOSE(mach_vm_remap_new, mach_vm_remap);
DYLD_INTERPOSE(pthread_jit_write_protect_np_new,
               macws_pthread_jit_write_protect_original);

// ─── objc_alloc tracer for AGX classes ──────────────────────────────────────
// When AGXMetal13_3's AGX::Mempool::grow lambda calls objc_alloc(AGXBuffer),
// the GOT slot for objc_alloc is resolved via our walker. If that slot still
// returns nil — either because the slot isn't bound or because libobjc's
// alloc dispatch fails on an under-realized class — Mempool gets nil buffers
// and setupDeferred crashes at +0x180 dereferencing the first buffer field.
// Interpose objc_alloc so every AGX-named class allocation gets logged AND
// gets a class_createInstance fallback if libobjc's alloc returns nil.
// objc_alloc trace: ONLY active when the experimental "register AGX classes"
// flag is set. Otherwise it's a pure passthrough (same behavior as no
// interpose) so the prior stable baseline stays unaffected.
extern id objc_alloc(Class);
id objc_alloc_trace(Class cls) {
    id r = objc_alloc(cls);
    if (!getenv("MACWS_AGX_REGISTER_CLASSES")) return r;
    if (cls) {
        const char *n = class_getName(cls);
        if (n && strncmp(n, "AGX", 3) == 0) {
            static int agx_alloc_count = 0;
            if (agx_alloc_count++ < 6) {
                fprintf(stderr, "#### objc_alloc(%s) -> %p\n", n, r);
            }
        }
    }
    return r;
}
DYLD_INTERPOSE(objc_alloc_trace, objc_alloc);

// ─── CARenderServer bootstrap-name rewrite ──────────────────────────────────
// The macOS window-content pipeline ships each app's rendered IOSurface to
// WindowServer over a CARenderServer connection.  WindowServer
// bootstrap_check_in("com.apple.CARenderServer") and clients
// bootstrap_look_up("com.apple.CARenderServer") (QuartzCore
// CARenderServerGetServerPort, hardcoded string).  But iOS launchd never
// publishes the com.apple.CARenderServer endpoint (it is declared in the WS
// plist yet dropped -- count 0 system-wide, not a name conflict; apparently a
// reserved iOS name).  So WS's check-in fails, clients' look-up fails, no remote
// context is formed, and window CONTENT never reaches WindowServer -> black
// (chrome still shows, drawn by WS from window geometry).
//
// Fix: rewrite the bootstrap name on BOTH sides to an unreserved name that our
// WindowServer LaunchDaemon plist declares (com.apple.macosbooter.CARenderServer),
// so check-in publishes a port and look-up resolves it.  Same DYLD_INSERT runs in
// WS and clients, so both rewrites are consistent.
#define CARENDER_ORIG "com.apple.CARenderServer"
#define CARENDER_NEW  "com.apple.macosbooter.CARenderServer"
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
kern_return_t bootstrap_look_up_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    if(name && !strcmp(name, CARENDER_ORIG)) name = CARENDER_NEW;
    return bootstrap_look_up(bp, name, sp);
}
kern_return_t bootstrap_check_in_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    if(name && !strcmp(name, CARENDER_ORIG)) name = CARENDER_NEW;
    return bootstrap_check_in(bp, name, sp);
}
DYLD_INTERPOSE(bootstrap_look_up_new, bootstrap_look_up);
DYLD_INTERPOSE(bootstrap_check_in_new, bootstrap_check_in);

// 2026-06-19 RE: chroot's texture super-init failure traces to
// `-[IOGPUMetalResource initWithDevice:remoteStorageResource:options:args:
// argsSize:]` returning nil at the GetClientShared cbz check. Original
// hypothesis was CF-type-id mismatch; runtime+disasm refined: macOS
// `_IOGPUResourceCreate` (unslid 0x19d156140..0x19d156248) builds a CF
// wrapper after kernel sel=0xa returns. On the success leg it copies
// fields out of `outStruct`:
//   wrapper[+0x40] = outStruct[+0x48]
//   wrapper[+0x48] = outStruct[+0x10]   ← what GetClientShared returns
// `_IOGPUResourceGetClientShared(wrapper)` returns wrapper[+0x48]. The
// orig init then `cbz x0, error` — if wrapper[+0x48] == 0, releases self
// and returns nil. So if iOS kernel doesn't populate outStruct[+0x10]
// for the chroot's texture-path call, the whole texture init dies.
//
// NOT FIXED YET — next step is to actually read outStruct[+0x10] at
// runtime for the failing call (via lldb at the wrapper-construction
// site, +0x19d1561d8 / +0x19d15621c) to confirm it's NULL, then dig into
// iOS userland's `_IOGPUResourceCreate` to see what args bit makes iOS
// kernel populate that field. Then patch our IOConnectCallMethod_new
// args swap so kernel returns a valid value there.
//
// The simplest hack (DYLD_INTERPOSE GetClientShared to fall back to the
// resource pointer when it returns NULL) was tried + reverted — user
// asked for structural understanding first, not whack-a-mole.

// IOSurface per-plane-layout compatibility.
//
// RE-confirmed against the exact shipped binaries:
//
//   iOS 16.3 IOSurfaceClientGetCompressionTypeOfPlane
//     client + plane*0x80 + 0x120
//   macOS 13.4 equivalent
//     client + plane*0x80 + 0x124
//
// HeightInCompressedTiles has the same four-byte drift (iOS +0x118 versus
// macOS +0x11c). WidthInCompressedTiles is iOS +0x114 versus macOS +0x118;
// BytesPerTileData is iOS +0x12c versus macOS +0x130. BytesPerRow has an
// equivalent drift: iOS reads +0xdc while macOS reads +0xe0. PlaneOffset is
// iOS +0xd8 versus macOS +0xdc. AddressFormat has the same drift: iOS reads
// +0xe9 while macOS reads +0xed. On the captured pf550 surface +0xe0 is
// PlaneSize, so the unmodified macOS BPR getter returned
// 16390144 instead of the explicit plane-0 BytesPerRow value 153600
// (runtime-confirmed at the real initImpl entry). The shifted AddressFormat
// read made TextureGen4 set its internal compression-kind byte to zero, so it
// never built Texture+0x1d8. The shifted width/tile-data reads later made the
// compression-offset helper calculate 105*105*153600 instead of
// 105*150*1024.
//
// Compression/height recover only a zero result. BytesPerRow must also repair
// a non-zero mismatch because the shifted field is itself a legitimate nonzero
// PlaneSize. In every case the replacement must come from the IOSurface's own
// explicit creation properties; no format or compressibility answer is
// synthesized here.
static bool macws_iosurface_plane_property_value(IOSurfaceRef surface,
                                                  size_t plane,
                                                  NSString *shortKey,
                                                  NSString *fullKey,
                                                  uint64_t *valueOut) {
    if (!surface || !valueOut) return false;
    CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
    if (!copied) return false;
    uint64_t value = 0;
    bool found = false;
    @try {
        NSDictionary *root = (__bridge NSDictionary *)copied;
        id creationValue = [root objectForKey:@"CreationProperties"];
        NSDictionary *creation =
            [creationValue isKindOfClass:[NSDictionary class]]
                ? (NSDictionary *)creationValue : root;
        id planeInfoValue = [creation objectForKey:@"IOSurfacePlaneInfo"];
        if ([planeInfoValue isKindOfClass:[NSArray class]] &&
            plane < [(NSArray *)planeInfoValue count]) {
            id planeValue = [(NSArray *)planeInfoValue objectAtIndex:plane];
            if ([planeValue isKindOfClass:[NSDictionary class]]) {
                id number = [(NSDictionary *)planeValue objectForKey:shortKey]
                    ?: [(NSDictionary *)planeValue objectForKey:fullKey];
                if ([number respondsToSelector:@selector(unsignedLongLongValue)]) {
                    value = [number unsignedLongLongValue];
                    found = true;
                }
            }
        }
    } @catch (NSException *exception) {
        static int exceptionLogs = 0;
        if (exceptionLogs++ < 4) {
            fprintf(stderr,
                "#### IOSURFACE-COMPAT property parse exception: %s\n",
                [[exception description] UTF8String] ?: "?");
        }
    }
    CFRelease(copied);
    if (found) *valueOut = value;
    return found;
}

static uint64_t macws_iosurface_plane_property(IOSurfaceRef surface,
                                                size_t plane,
                                                NSString *shortKey,
                                                NSString *fullKey) {
    uint64_t value = 0;
    (void)macws_iosurface_plane_property_value(
        surface, plane, shortKey, fullKey, &value);
    return value;
}

// Chromium 148.0.7778.280 validates both per-plane dimensions before it
// imports a VideoToolbox IOSurface.  Runtime logs from its exact
// bfe29217d60b6ee25ce4e4b2c0abcd6361ae6eb6 build reached
// iosurface_image_backing_factory.mm:501 while this compatibility layer was
// already recovering that same surface's BPR/offset from IOSurfacePlaneInfo.
// Width/height are adjacent members of the same iOS-vs-macOS IOSurfaceClient
// layout, but were missing from the original recovery set.  Recover their
// explicit creation-property values too; never infer dimensions from pixel
// format or return a constant merely to pass Chromium's bounds check.
size_t macws_IOSurfaceGetWidthOfPlane(IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetWidthOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"Width", @"IOSurfacePlaneWidth");
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT width plane=%zu original=%zu "
            "property=%llu surfaceID=%u recovery=%u\n",
            plane, original, (unsigned long long)property,
            IOSurfaceGetID(surface), count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetHeightOfPlane(IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetHeightOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"Height", @"IOSurfacePlaneHeight");
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT height plane=%zu original=%zu "
            "property=%llu surfaceID=%u recovery=%u\n",
            plane, original, (unsigned long long)property,
            IOSurfaceGetID(surface), count);
    }
    return (size_t)property;
}

uint32_t macws_IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef surface,
                                                   size_t plane) {
    uint32_t original = IOSurfaceGetCompressionTypeOfPlane(surface, plane);
    if (original != 0 || !getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"CompressionType", @"IOSurfacePlaneCompressionType");
    if (property == 0 || property > UINT32_MAX) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT compression plane=%zu original=%u "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (uint32_t)property;
}

size_t macws_IOSurfaceGetHeightInCompressedTilesOfPlane(
        IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetHeightInCompressedTilesOfPlane(
        surface, plane);
    if (original != 0 || !getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"HeightInCompressedTiles",
        @"IOSurfacePlaneHeightInCompressedTiles");
    if (property == 0 || property > SIZE_MAX) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT heightInTiles plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetWidthInCompressedTilesOfPlane(
        IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetWidthInCompressedTilesOfPlane(
        surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"WidthInCompressedTiles",
        @"IOSurfacePlaneWidthInCompressedTiles");
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT widthInTiles plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef surface,
                                            size_t plane) {
    size_t original = IOSurfaceGetBytesPerRowOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"BytesPerRow", @"IOSurfacePlaneBytesPerRow");
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT bytesPerRow plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetBytesPerTileDataOfPlane(IOSurfaceRef surface,
                                                 size_t plane) {
    size_t original = IOSurfaceGetBytesPerTileDataOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"BytesPerTileData", @"IOSurfacePlaneBytesPerTileData");
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT bytesPerTileData plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetOffsetOfPlane(IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetOffsetOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = 0;
    bool found = macws_iosurface_plane_property_value(surface, plane,
        @"Offset", @"IOSurfacePlaneOffset", &property);
    if (!found || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT offset plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

void *macws_IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef surface,
                                           size_t plane) {
    void *original = IOSurfaceGetBaseAddressOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t propertyOffset = 0;
    bool found = macws_iosurface_plane_property_value(surface, plane,
        @"Offset", @"IOSurfacePlaneOffset", &propertyOffset);
    void *base = IOSurfaceGetBaseAddress(surface);
    if (!found || !base || propertyOffset > UINTPTR_MAX - (uintptr_t)base)
        return original;
    void *corrected = (void *)((uintptr_t)base + (uintptr_t)propertyOffset);
    if (corrected == original) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT baseAddress plane=%zu original=%p "
            "base=%p propertyOffset=%llu corrected=%p recovery=%u\n",
            plane, original, base, (unsigned long long)propertyOffset,
            corrected, count);
    }
    return corrected;
}

uint32_t macws_IOSurfaceGetAddressFormatOfPlane(IOSurfaceRef surface,
                                                size_t plane) {
    uint32_t original = IOSurfaceGetAddressFormatOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(surface, plane,
        @"AddressFormat", @"IOSurfaceAddressFormat");
    if (property == 0 || property > UINT32_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = atomic_fetch_add(&recoveryCount, 1) + 1;
    if (count <= 16 || (count % 500) == 0) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT addressFormat plane=%zu original=%u "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (uint32_t)property;
}

DYLD_INTERPOSE(macws_IOSurfaceGetCompressionTypeOfPlane,
                IOSurfaceGetCompressionTypeOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetWidthOfPlane,
                IOSurfaceGetWidthOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetHeightOfPlane,
                IOSurfaceGetHeightOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetHeightInCompressedTilesOfPlane,
                IOSurfaceGetHeightInCompressedTilesOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetWidthInCompressedTilesOfPlane,
                IOSurfaceGetWidthInCompressedTilesOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetBytesPerRowOfPlane,
                IOSurfaceGetBytesPerRowOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetBytesPerTileDataOfPlane,
                IOSurfaceGetBytesPerTileDataOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetOffsetOfPlane,
                IOSurfaceGetOffsetOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetBaseAddressOfPlane,
                IOSurfaceGetBaseAddressOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetAddressFormatOfPlane,
                IOSurfaceGetAddressFormatOfPlane);

// Tightly-scoped IOSurfaceCreate interposer — only rewrites SkyLight's "CA
// Framebuffer" 2-plane Apple-GPU-compressed BGRA10_XR surface (FourCC '&b38' /
// 0x26623338). Without rewrite, MTLSimDriverHost cannot wrap this IOSurface in
// any iOS-Metal-accepted MTLPixelFormat (we tried 552/553/94/90/80/81 — all NIL),
// so SkyLight asserts on its compositor destination and WS dies on every frame.
//
// The previous wide-scope rewrite crashed CoreImage-using apps (Terminal) because
// IOSurfaceCreate_new called -objectForKey: on a dict that turned out to be a
// non-NSDictionary CFType — PAC fault. We now (a) typecheck the input via
// CFGetTypeID == CFDictionaryGetTypeID, and (b) gate the rewrite on the
// IOSurfaceName key being EXACTLY "CA Framebuffer" plus the FourCC's high byte
// being 0x26 (Apple compression marker), which excludes every other surface.
IOSurfaceRef IOSurfaceCreate_safe(CFDictionaryRef properties_cf) {
    if (getenv("MACWS_IOSURF_TRACE") != NULL) {
        fprintf(stderr, "#### IOSURF_HOOK call cf=%p\n", (void *)properties_cf);
    }
    if (!properties_cf) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    // This interposer's dictionary inspection is a WindowServer-only ABI
    // translation.  Keep the process gate ahead of *every* dictionary access,
    // including diagnostics.  CoreImage in arm64e applications such as Terminal
    // supplies a CFDictionary whose key hashing PAC-faults when macOS
    // CoreFoundation dispatches through the iOS-signed Objective-C runtime.
    {
        static int s_is_ws = -1;
        if (s_is_ws < 0) {
            const char *prog = getprogname();
            s_is_ws = (prog && strstr(prog, "WindowServer")) ? 1 : 0;
        }
        if (!s_is_ws) {
            return IOSurfaceCreate((NSDictionary *)properties_cf);
        }
    }
    // OOM leak diagnostic (2026-06-20): count creates + per-caller bytes.
    // Every 250 calls, dump caller+size attribution so we can find who's
    // accumulating IOSurfaces against the 5120 MB WS watermark.
    {
        static _Atomic unsigned long s_count = 0;
        static _Atomic unsigned long s_total_bytes = 0;
        unsigned long my_n = atomic_fetch_add(&s_count, 1) + 1;
        size_t my_bytes = 0;
        if (properties_cf && CFGetTypeID(properties_cf) == CFDictionaryGetTypeID()) {
            CFNumberRef w = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
            CFNumberRef h = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
            CFNumberRef bpe = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceBytesPerElement"));
            int wi = 0, hi = 0, bi = 4;
            if (w && CFGetTypeID(w) == CFNumberGetTypeID()) CFNumberGetValue(w, kCFNumberSInt32Type, &wi);
            if (h && CFGetTypeID(h) == CFNumberGetTypeID()) CFNumberGetValue(h, kCFNumberSInt32Type, &hi);
            if (bpe && CFGetTypeID(bpe) == CFNumberGetTypeID()) CFNumberGetValue(bpe, kCFNumberSInt32Type, &bi);
            my_bytes = (size_t)wi * (size_t)hi * (size_t)bi;
        }
        unsigned long my_total = atomic_fetch_add(&s_total_bytes, my_bytes) + my_bytes;
        if (my_n % 250 == 1 /* 1, 251, 501, ... — keep low under steady state */) {
            Dl_info di;
            void *ra1 = __builtin_return_address(0);
            void *ra2 = __builtin_return_address(1);
            const char *sym1 = "?", *sym2 = "?";
            if (dladdr(ra1, &di) && di.dli_sname) sym1 = di.dli_sname;
            if (dladdr(ra2, &di) && di.dli_sname) sym2 = di.dli_sname;
            fprintf(stderr,
                "#### IOSURF_STATS n=%lu cumulative_bytes=%lu MB this_size=%zu KB caller1=%s caller2=%s\n",
                my_n, my_total / (1024*1024), my_bytes / 1024, sym1, sym2);
        }
    }
    // CoreImage sometimes passes a CFDictionary whose -objectForKey: is not a
    // real NSDictionary bridge — fall back to the raw CFDictionaryGetValue.
    if (CFGetTypeID(properties_cf) != CFDictionaryGetTypeID()) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    CFNumberRef pfNum = (CFNumberRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("IOSurfacePixelFormat"));
    uint32_t pf = 0;
    if (pfNum && CFGetTypeID(pfNum) == CFNumberGetTypeID()) {
        CFNumberGetValue(pfNum, kCFNumberSInt32Type, &pf);
    }
    BOOL is_apple_compressed = ((pf & 0xFF000000u) == 0x26000000u);
    CFStringRef name = (CFStringRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("IOSurfaceName"));
    BOOL is_ca_fb = NO;
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
        is_ca_fb = (CFStringCompare(name, CFSTR("CA Framebuffer"), 0) == kCFCompareEqualTo);
    }
    if (!(is_apple_compressed && is_ca_fb)) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    // Rebuild as plain BGRA8 — drop the compression-metadata plane and the
    // private FourCC so MTLSimDriverHost can wrap it as MTLPixelFormatBGRA8Unorm.
    CFNumberRef wNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
    CFNumberRef hNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
    int w = 0, h = 0;
    if (wNum && CFGetTypeID(wNum) == CFNumberGetTypeID()) CFNumberGetValue(wNum, kCFNumberSInt32Type, &w);
    if (hNum && CFGetTypeID(hNum) == CFNumberGetTypeID()) CFNumberGetValue(hNum, kCFNumberSInt32Type, &h);
    if (w <= 0 || h <= 0) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    const int bpe = 4;                         // BGRA8 = 4 bytes/pixel
    size_t bytesPerRow = (size_t)w * (size_t)bpe;
    // Align to 64 bytes (typical Apple GPU stride alignment)
    bytesPerRow = (bytesPerRow + 63u) & ~63ul;
    size_t planeSize = bytesPerRow * (size_t)h;
    NSMutableDictionary *np = [NSMutableDictionary dictionary];
    np[@"IOSurfaceWidth"]  = @(w);
    np[@"IOSurfaceHeight"] = @(h);
    np[@"IOSurfacePixelFormat"] = @((unsigned int)'BGRA');   // 0x42475241
    np[@"IOSurfaceBytesPerElement"] = @(bpe);
    np[@"IOSurfaceBytesPerRow"] = @(bytesPerRow);
    np[@"IOSurfaceAllocSize"] = @(planeSize);
    np[@"IOSurfaceCacheMode"] = @0;
    np[@"IOSurfacePixelSizeCastingAllowed"] = @0;
    np[@"IOSurfaceName"] = @"CA Framebuffer";  // preserve identity
    // Carry CAWindowServerSurface so SkyLight still treats it as the compositor target.
    CFNumberRef wsFlag = (CFNumberRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("CAWindowServerSurface"));
    if (wsFlag) np[@"CAWindowServerSurface"] = (__bridge id)wsFlag;
    np[@"IOSurfacePlaneInfo"] = @[ @{
        @"IOSurfacePlaneWidth": @(w),
        @"IOSurfacePlaneHeight": @(h),
        @"IOSurfacePlaneBytesPerRow": @(bytesPerRow),
        @"IOSurfacePlaneBytesPerElement": @(bpe),
        @"IOSurfacePlaneElementWidth": @1,
        @"IOSurfacePlaneElementHeight": @1,
        @"IOSurfacePlaneOffset": @0,
        @"IOSurfacePlaneSize": @(planeSize),
        @"IOSurfaceAddressFormat": @0,
    } ];
    IOSurfaceRef result = IOSurfaceCreate(np);
    fprintf(stderr, "#### IOSURF/CA_FB rewrote %dx%d pf=0x%x->BGRA8 result=%p\n",
        w, h, pf, (void *)result);
    return result;
}
DYLD_INTERPOSE(IOSurfaceCreate_safe, IOSurfaceCreate);

// IOKit
CFMutableDictionaryRef IOServiceNameMatching_new(const char *name) {
    // printf("debugbydcmmc IOServiceNameMatching called with name: %s\n", name);
    if (strcmp("IOSurfaceRoot", name) == 0) {
        return IOServiceNameMatching("IOCoreSurfaceRoot");
    } else if (strcmp("IOAccelerator", name) == 0) {
        return IOServiceNameMatching("IOAcceleratorES");
    }
    CFMutableDictionaryRef service = IOServiceNameMatching(name);
    if(!service) {
        fprintf(stderr, "debugbydcmmc IOServiceNameMatching not found for name: %s\n", name);
    }
    return service;
}

CFDictionaryRef IOServiceMatching_new(const char *name) {
    // printf("debugbydcmmc IOServiceMatching called with name: %s\n", name);
    if (strcmp("IOSurfaceRoot", name) == 0) {
        return IOServiceMatching("IOCoreSurfaceRoot");
    } else if (strcmp("IOAccelerator", name) == 0) {
        return IOServiceMatching("IOAcceleratorES");
    }
    CFMutableDictionaryRef service = IOServiceMatching(name);
    if(!service) {
        fprintf(stderr, "debugbydcmmc IOServiceMatching not found for name: %s\n", name);
    }
    return service;
}
DYLD_INTERPOSE(IOServiceNameMatching_new, IOServiceNameMatching);
DYLD_INTERPOSE(IOServiceMatching_new, IOServiceMatching);

#ifndef FORCE_M1_DRIVER
kern_return_t IOServiceOpen_new(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect) {
    // clear flag 4 (FIXME: idk what is this)
    type &= ~4;
    kern_return_t result = IOServiceOpen(service, owningTask, type, connect);
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif

// don't discard our privilleges
int _libsecinit_initializer();
int _libsecinit_initializer_new() {
    return 0;
}
int setegid_new(gid_t gid) {
    return 0;
}
int seteuid_new(uid_t uid) {
    return 0;
}
DYLD_INTERPOSE(_libsecinit_initializer_new, _libsecinit_initializer);
DYLD_INTERPOSE(setegid_new, setegid);
DYLD_INTERPOSE(seteuid_new, seteuid);

// utilities
void ModifyExecutableRegion(void *addr, size_t size, void(^callback)(void)) {
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    callback();
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_EXEC);
}

#ifdef FORCE_M1_DRIVER
// IOKit
io_connect_t iogpuClients[10];
int iogpuClientsCount = 0;
static BOOL IOConnectIsIOGPU(io_connect_t client) {
    for(int i = 0; i < iogpuClientsCount; ++i) {
        if(iogpuClients[i] == client) {
            return YES;
        }
    }
    return NO;
}
static uint32_t IOConnectTranslateSelector(io_connect_t client, uint32_t selector) {
    if(IOConnectIsIOGPU(client)) {
        // translate selector to match iOS
        //NSLog(@"Translating selector 0x%x for IOGPU client %d", selector, client);
        // macOS -> iOS
        // 0x108 -> 0x108 (same)
        // 0x102 -> 0x102 (same)
        // 0x100 -> 0x100 (same)
        // 0x20 -> 0x20 (same)
        // 0x11 -> 0xf
        // 0xa -> 0x9
        //???
        // 0x8 -> 0x7
        // 0x7 -> 0x6
        // 0x5 -> 0x4
        // 0x2 -> 0x2 (same)
        // 0x0 -> 0x0 (same)
        switch(selector) {
            case 0x5: // IOGPUDeviceCreateWithAPIProperty + 672
                return 0x4;
            case 0x6: // IOGPUDeviceGetNextGlobalTraceID
                return 0x5;
            case 0x7: // IOGPUDeviceCreateWithAPIProperty + 172: sends "Metal"
                return 0x6;
            case 0x8: // IOGPUCommandQueueCreateWithQoS + 392
                return 0x7;
            case 0x9: // ioGPUCommandQueueFinalize
                return 0x8;
            case 0xa: // IOGPUResourceCreate
                return 0x9;
            case 0xb: // ioGPUResourceFinalize
                return 0xa;
            case 0xd: // IOGPUResourceSetPurgeable — function exists in both
                      // builds (macOS IOGPU at 0x19d156478, iOS IOGPU at
                      // 0x1eec60320). Byte-identical except `mov w1, #X`:
                      // macOS uses #0xd, iOS uses #0xc. Args identical:
                      // (resource->0x30, newState) → oldState; inCnt=2,
                      // outCnt=1. Confirmed by static disasm of both this
                      // session (2026-06-17). Without this, IOGPUMetal\
                      // Texture's super-init issues sel=0xd to set
                      // texture's heap purgeable state, iOS kernel returns
                      // 0xe00002c2 (kIOReturnNoMemory or kIOReturnBadArg),
                      // init returns nil + zeros self → texture wrap nil.
                return 0xc;
            case 0xf: // IOGPUDeviceCreateDeviceShmem
                return 0xd;
            case 0x10: // IOGPUDeviceDestroyDeviceShmem
                return 0xe;
            case 0x11: // IOGPUCommandQueueCreateWithQoS + 452
                return 0xf;
            case 0x12: // ioGPUNotificationQueueFinalize
                return 0x10;
            case 0x18: // IOGPUMTLEvent initWithDevice:
                       // RE-confirmed 2026-07-29 from the actual framework
                       // binaries and an iOS-native runtime byte dump. macOS
                       // 13.4 IOGPU UUID CE2B5551-857F-3EDD-9E4F-435215CC8C27
                       // calls IOConnectCallMethod with selector 0x18; iOS
                       // 16.3 IOGPU at runtime offset +0x170b0 uses 0x14.
                       // Both functions otherwise pass zero scalar/struct
                       // input, request exactly two scalar outputs, and store
                       // the returned event ID/value into the same object
                       // fields. Leaving 0x18 untranslated returns
                       // 0xe00002c2 and forced the incomplete newSharedEvent
                       // fallback on every Chromium frame.
                return 0x14;
            case 0x19: // IOGPUMTLEvent dealloc
                       // RE-confirmed 2026-07-29 from both live framework
                       // implementations. macOS 13.4 IOGPU UUID
                       // CE2B5551-857F-3EDD-9E4F-435215CC8C27 at
                       // IOGPU+0x15488 loads object+0x10 as the sole scalar
                       // input and executes `mov w1, #0x19`. iOS 16.3 at
                       // live IOGPU+0x17190 has the same call ABI but executes
                       // `mov w1, #0x15`. This is the destructor paired with
                       // the adjacent 0x18 -> 0x14 event constructor above;
                       // leaving it untranslated makes every attempted
                       // kernel-event destruction return 0xe00002c2.
                return 0x15;
            case 0x1d: // IOGPUCommandQueueCreateWithQoS + 516
                return 0x19;
            case 0x1e: // IOGPUCommandQueueSubmitCommandBuffers
                return 0x1a;
            case 0x1f: // IOGPUCommandQueueSetPriorityAndBackground
                return 0x1b;
            case 0x25: // IOGPUDeviceSetDisplayParams — confirmed by BN disasm of both
                       // macOS IOGPU.framework (file /Users/.../agx-re/IOGPU at func
                       // _IOGPUDeviceSetDisplayParams uses `mov w1, #0x25; mov w3, #0x2`)
                       // and iOS IOGPU.bndb (same function uses sel 0x21 with same
                       // inCnt=2). Without this, WS loops on sel 0x25 →
                       // kIOReturnBadArgument while trying to set up the compositor
                       // display params during NSVisualEffectView backdrop-blur init,
                       // resulting in opaque-black vibrancy and high autosignd load.
                return 0x21;
            case 0x2a: // IOGPUDeviceCreateVNIODesc
                return 0x26;
        }
    }
    return selector;
}

// Per-thread IOSurfaceID stash. Set by Metal_hooks.x's swizzled
// hooked_newTextureWithDescriptor:iosurface:plane: before %orig runs, read
// here by IOConnectCallMethod_new to inject args[+0x30] for sel=0xa
// type=0x82 — the iOS kernel AGX dispatcher requires the IOSurfaceID at
// that offset to call find_iosurface_for_id (without it, returns
// kIOReturnNoMemory).
extern uint32_t macws_get_current_iosurface_id(void);
extern uint64_t macws_get_current_iosurface_compression_header_span(void);

// AGX ID-translation shim. The iOS kernel AUTO-ASSIGNS resource GIDs (IOGPUObject
// atomic counter; getResource matches resource+0x28), but the macOS AGX driver uses
// CLIENT-ASSIGNED ids at IOGPUNewResourceArgs+0x48 (e.g. heap=0x20000, sub-resource
// parent-id=0x20000). libmachook is userspace-only (can't patch the kernel), so we
// bridge the two id-spaces here: record each created resource's clientID -> the
// iOS GID returned in its OUT struct, and rewrite parent-id references in 0x80
// sub-resources from clientID to the iOS GID so getResource() finds the parent.
static struct { uint64_t clientID, iosResourceID, size; } g_agxIdMap[128];
static int g_agxIdMapCount;

// Successful IOGPU resource lifecycle diagnostic.  The previous create-minus-
// destroy counter included failed creates and did not compare resource IDs, so
// it could not establish a leak.  This table is keyed by the iOS kernel GID
// returned at IOGPUNewResourceOutArgs+0x1c and is removed by the scalar passed
// to ioGPUResourceFinalize.  Logs report only kernel-accepted operations.
//
// RE-confirmed with the project LLDB on macOS 13.4 IOGPU:
//   IOGPUResourceCreate+324 loads w8 from out+0x1c and stores wrapper+0x30;
//   ioGPUResourceFinalize+24 loads wrapper+0x30 and passes it as selector 0xb's
//   sole scalar. out+0x28 is copied to wrapper+0x50 and is NOT the resource ID.
#define MACWS_AGX_LIFE_CAP 16384u
#define MACWS_AGX_CPU_DUMP_CAP 64u
#define MACWS_AGX_CPU_DUMP_BYTES 0x10000u
#define MACWS_AGX_T82_REQUEST_CAP 512u
#define MACWS_AGX_T82_REQUEST_BYTES 0x100u
#define MACWS_AGX_SURFACE_DUMP_CAP 16u
#define MACWS_AGX_SURFACE_DUMP_BYTES 0x100000u
struct macws_agx_life_entry {
    uint64_t gid;       // 0 = empty, UINT64_MAX = tombstone
    uint64_t gpu_address; // kernel-returned GPU VA (out+0x00)
    uint64_t data_bytes; // CPU mapping returned by GetDataBytes (out+0x08)
    uint64_t client_shared; // client-shared state returned from out+0x10
    uint64_t bytes;     // kernel-reported allocation size (out+0x48)
    uint64_t request_50; // translated request layout/arena word
    uint32_t client_id; // macOS client field (in+0x48), diagnostic only
    uint32_t surface_id;// type 0x82 IOSurface ID (translated in+0x30)
    uint32_t flags_14;  // translated request flags (in+0x14)
    uint8_t type;
};
static struct macws_agx_life_entry g_agxLife[MACWS_AGX_LIFE_CAP];
static pthread_mutex_t g_agxLifeLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_agxLifeLive[256], g_agxLifeBytes[256];
static uint64_t g_agxLifeCreateOK, g_agxLifeCreateFail;
static uint64_t g_agxLifeDestroyOK, g_agxLifeDestroyFail;
static uint64_t g_agxLifeUnmatchedDestroy, g_agxLifeTableFull;

// Resource flight recorder.  The live table proves bounded ownership, but a
// GPU page fault also needs the recently-destroyed ranges: a KCMD can retain a
// stale VA after its wrapper has already finalized.  Keep this diagnostic
// metadata in a fixed ring; it neither retains resources nor changes any
// create/finalize call.
#define MACWS_AGX_LIFE_EVENT_CAP 4096u
struct macws_agx_life_event {
    uint64_t serial;
    struct macws_agx_life_entry resource;
    uint8_t action; // 1=create, 2=destroy
};
static struct macws_agx_life_event
    g_agxLifeEvents[MACWS_AGX_LIFE_EVENT_CAP];
static uint64_t g_agxLifeEventSerial;

// Exact producer/kernel request bytes for recently-created type-0x82
// resources.  This is populated only while the raw IOGPU error sentinel is
// present.  The lifecycle table intentionally stores only compact metadata;
// a separate bounded ring avoids adding half a kilobyte to every one of its
// 16K slots during ordinary WindowServer runs.
struct macws_agx_t82_request {
    uint64_t sequence;
    uint64_t life_event_serial;
    uint64_t gid;
    uint64_t gpu_address;
    uint32_t surface_id;
    uint16_t raw_length;
    uint16_t sent_length;
    unsigned char raw[MACWS_AGX_T82_REQUEST_BYTES];
    unsigned char sent[MACWS_AGX_T82_REQUEST_BYTES];
};
static struct macws_agx_t82_request
    g_macwsAgxT82Requests[MACWS_AGX_T82_REQUEST_CAP];
static uint64_t g_macwsAgxT82RequestSequence;

// Read the resource-generation boundary without exposing the lifecycle
// table's lock ordering to the submit recorder.  The returned serial is the
// newest successful create/finalize event that completed before this call.
// A later error dump can therefore distinguish a resource that stayed in the
// same generation from a GID that was destroyed and reused while the GPU work
// was outstanding.  This is observation only; it does not retain a resource
// or delay its finalizer.
static uint64_t macws_agx_life_current_event_serial(void) {
    pthread_mutex_lock(&g_agxLifeLock);
    uint64_t serial = g_agxLifeEventSerial;
    pthread_mutex_unlock(&g_agxLifeLock);
    return serial;
}

static void macws_agx_life_record_locked(
    uint8_t action, const struct macws_agx_life_entry *resource) {
    if (!resource) return;
    uint64_t serial = ++g_agxLifeEventSerial;
    g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP] =
        (struct macws_agx_life_event){serial, *resource, action};
}

static unsigned macws_agx_life_hash(uint64_t gid) {
    return (unsigned)((gid * 11400714819323198485ull) >> 50) &
        (MACWS_AGX_LIFE_CAP - 1);
}

static void macws_agx_life_summary_locked(const char *event, uint64_t id,
                                          uint8_t type, uint32_t surface_id,
                                          uint64_t bytes,
                                          IOReturn kr) {
    uint64_t live_total = 0, bytes_total = 0;
    for (unsigned i = 0; i < 256; i++) {
        live_total += g_agxLifeLive[i];
        bytes_total += g_agxLifeBytes[i];
    }
    fprintf(stderr,
        "#### AGX_LIFE %s id=%#llx type=%#x surf=%#x bytes=%#llx kr=%#x "
        "okC=%llu failC=%llu okD=%llu failD=%llu unmatchedD=%llu full=%llu "
        "live=%llu/%lluMB [t0=%llu/%lluMB t80=%llu/%lluMB t82=%llu/%lluMB]\n",
        event, (unsigned long long)id, type, surface_id,
        (unsigned long long)bytes, kr,
        (unsigned long long)g_agxLifeCreateOK,
        (unsigned long long)g_agxLifeCreateFail,
        (unsigned long long)g_agxLifeDestroyOK,
        (unsigned long long)g_agxLifeDestroyFail,
        (unsigned long long)g_agxLifeUnmatchedDestroy,
        (unsigned long long)g_agxLifeTableFull,
        (unsigned long long)live_total,
        (unsigned long long)(bytes_total >> 20),
        (unsigned long long)g_agxLifeLive[0],
        (unsigned long long)(g_agxLifeBytes[0] >> 20),
        (unsigned long long)g_agxLifeLive[0x80],
        (unsigned long long)(g_agxLifeBytes[0x80] >> 20),
        (unsigned long long)g_agxLifeLive[0x82],
        (unsigned long long)(g_agxLifeBytes[0x82] >> 20));
}

static void macws_agx_life_create(uint64_t gid, uint8_t type,
                                  uint32_t client_id, uint32_t surface_id,
                                  uint64_t gpu_address, uint64_t data_bytes,
                                  uint64_t client_shared, uint64_t bytes,
                                  uint32_t flags_14, uint64_t request_50,
                                  const void *raw_request,
                                  size_t raw_request_length,
                                  const void *sent_request,
                                  size_t sent_request_length) {
    pthread_mutex_lock(&g_agxLifeLock);
    g_agxLifeCreateOK++;
    unsigned start = macws_agx_life_hash(gid), first_tomb = MACWS_AGX_LIFE_CAP;
    unsigned slot = MACWS_AGX_LIFE_CAP;
    for (unsigned probe = 0; probe < MACWS_AGX_LIFE_CAP; probe++) {
        unsigned i = (start + probe) & (MACWS_AGX_LIFE_CAP - 1);
        uint64_t here = g_agxLife[i].gid;
        if (here == gid) { slot = i; break; }
        if (here == UINT64_MAX && first_tomb == MACWS_AGX_LIFE_CAP)
            first_tomb = i;
        if (here == 0) {
            slot = first_tomb != MACWS_AGX_LIFE_CAP ? first_tomb : i;
            break;
        }
    }
    if (slot == MACWS_AGX_LIFE_CAP || gid == 0 || gid == UINT64_MAX) {
        g_agxLifeTableFull++;
        macws_agx_life_summary_locked("CREATE-UNTRACKED", gid, type,
                                      surface_id, bytes, 0);
    } else {
        if (g_agxLife[slot].gid == gid) {
            uint8_t old_type = g_agxLife[slot].type;
            g_agxLifeLive[old_type]--;
            g_agxLifeBytes[old_type] -= g_agxLife[slot].bytes;
        }
        g_agxLife[slot] = (struct macws_agx_life_entry){
            .gid = gid, .gpu_address = gpu_address,
            .data_bytes = data_bytes, .client_shared = client_shared,
            .bytes = bytes,
            .request_50 = request_50, .client_id = client_id,
            .surface_id = surface_id, .flags_14 = flags_14, .type = type
        };
        macws_agx_life_record_locked(1, &g_agxLife[slot]);
        if (type == 0x82 &&
            access("/tmp/macws_iogpu_error_diag", F_OK) == 0) {
            uint64_t request_sequence = ++g_macwsAgxT82RequestSequence;
            struct macws_agx_t82_request *request =
                &g_macwsAgxT82Requests[(request_sequence - 1) %
                                       MACWS_AGX_T82_REQUEST_CAP];
            memset(request, 0, sizeof(*request));
            request->sequence = request_sequence;
            request->life_event_serial = g_agxLifeEventSerial;
            request->gid = gid;
            request->gpu_address = gpu_address;
            request->surface_id = surface_id;
            request->raw_length = (uint16_t)MIN(raw_request_length,
                (size_t)MACWS_AGX_T82_REQUEST_BYTES);
            request->sent_length = (uint16_t)MIN(sent_request_length,
                (size_t)MACWS_AGX_T82_REQUEST_BYTES);
            if (raw_request && request->raw_length != 0) {
                memcpy(request->raw, raw_request, request->raw_length);
            }
            if (sent_request && request->sent_length != 0) {
                memcpy(request->sent, sent_request, request->sent_length);
            }
        }
        g_agxLifeLive[type]++;
        g_agxLifeBytes[type] += bytes;
        // The normal steady-state type-0x82 live set is only 4--6 entries, so
        // the old `live <= 96` condition logged every frame (hundreds of
        // create/destroy lines per second) and became its own load source.
        // Keep full per-operation output opt-in; ordinary runs retain startup
        // witnesses plus periodic lifecycle summaries.
        if (g_agxLifeCreateOK <= 16 ||
            getenv("MACWS_AGX_LIFE_VERBOSE") ||
            (g_agxLifeCreateOK % 250) == 0)
            macws_agx_life_summary_locked("CREATE", gid, type,
                                          surface_id, bytes, 0);
    }
    pthread_mutex_unlock(&g_agxLifeLock);
}

static void macws_agx_life_create_failed(uint8_t type, uint64_t bytes,
                                         IOReturn kr) {
    pthread_mutex_lock(&g_agxLifeLock);
    g_agxLifeCreateFail++;
    macws_agx_life_summary_locked("CREATE-FAIL", 0, type, 0, bytes, kr);
    pthread_mutex_unlock(&g_agxLifeLock);
}

static void macws_agx_life_destroy(uint64_t gid, IOReturn kr) {
    pthread_mutex_lock(&g_agxLifeLock);
    if (kr != 0) {
        g_agxLifeDestroyFail++;
        macws_agx_life_summary_locked("DESTROY-FAIL", gid, 0xff, 0, 0, kr);
        pthread_mutex_unlock(&g_agxLifeLock);
        return;
    }
    g_agxLifeDestroyOK++;
    unsigned start = macws_agx_life_hash(gid), slot = MACWS_AGX_LIFE_CAP;
    for (unsigned probe = 0; probe < MACWS_AGX_LIFE_CAP; probe++) {
        unsigned i = (start + probe) & (MACWS_AGX_LIFE_CAP - 1);
        uint64_t here = g_agxLife[i].gid;
        if (here == gid) { slot = i; break; }
        if (here == 0) break;
    }
    if (slot == MACWS_AGX_LIFE_CAP) {
        g_agxLifeUnmatchedDestroy++;
        if (g_agxLifeUnmatchedDestroy <= 32 ||
            (g_agxLifeUnmatchedDestroy % 250) == 0)
            macws_agx_life_summary_locked("DESTROY-UNMATCHED", gid, 0xff,
                                          0, 0, kr);
    } else {
        struct macws_agx_life_entry resource = g_agxLife[slot];
        uint8_t type = resource.type;
        uint32_t surface_id = resource.surface_id;
        uint64_t bytes = resource.bytes;
        g_agxLifeLive[type]--;
        g_agxLifeBytes[type] -= bytes;
        macws_agx_life_record_locked(2, &resource);
        g_agxLife[slot].gid = UINT64_MAX;
        if (g_agxLifeDestroyOK <= 16 ||
            getenv("MACWS_AGX_LIFE_VERBOSE") ||
            (g_agxLifeDestroyOK % 250) == 0)
            macws_agx_life_summary_locked("DESTROY", gid, type,
                                          surface_id, bytes, kr);
    }
    pthread_mutex_unlock(&g_agxLifeLock);
}

static const struct macws_agx_life_entry *
macws_agx_life_find_active_va_locked(uint64_t address) {
    for (unsigned i = 0; i < MACWS_AGX_LIFE_CAP; i++) {
        const struct macws_agx_life_entry *entry = &g_agxLife[i];
        if (entry->gid == 0 || entry->gid == UINT64_MAX ||
            entry->gpu_address == 0 || entry->bytes == 0) continue;
        if (address >= entry->gpu_address &&
            address - entry->gpu_address < entry->bytes) return entry;
    }
    return NULL;
}

static const struct macws_agx_life_event *
macws_agx_life_find_recent_destroyed_va_locked(uint64_t address) {
    uint64_t newest = g_agxLifeEventSerial;
    uint64_t oldest = newest > MACWS_AGX_LIFE_EVENT_CAP
        ? newest - MACWS_AGX_LIFE_EVENT_CAP + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        const struct macws_agx_life_event *event =
            &g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP];
        const struct macws_agx_life_entry *entry = &event->resource;
        if (event->serial != serial || event->action != 2 ||
            entry->gpu_address == 0 || entry->bytes == 0) continue;
        if (address >= entry->gpu_address &&
            address - entry->gpu_address < entry->bytes) return event;
    }
    return NULL;
}

static const struct macws_agx_t82_request *
macws_agx_find_t82_request_locked(
        const struct macws_agx_life_entry *resource) {
    if (!resource || resource->type != 0x82) return NULL;
    uint64_t newest = g_macwsAgxT82RequestSequence;
    uint64_t oldest = newest > MACWS_AGX_T82_REQUEST_CAP
        ? newest - MACWS_AGX_T82_REQUEST_CAP + 1 : 1;
    for (uint64_t sequence = newest;
         sequence >= oldest && sequence != 0; sequence--) {
        const struct macws_agx_t82_request *request =
            &g_macwsAgxT82Requests[(sequence - 1) %
                                   MACWS_AGX_T82_REQUEST_CAP];
        if (request->sequence != sequence ||
            request->gid != resource->gid ||
            request->gpu_address != resource->gpu_address ||
            request->surface_id != resource->surface_id) continue;
        return request;
    }
    return NULL;
}

struct macws_agx_surface_dump {
    struct macws_agx_life_entry resource;
    struct macws_agx_t82_request request;
    BOOL has_request;
};

// Read-only error artifact.  Correlate aligned 64-bit KCMD words against the
// kernel-returned VA ranges, and preserve the complete active/recent resource
// state.  A match is evidence; unmatched address-looking words remain opaque
// and are deliberately not labelled as broken.
static void macws_agx_life_dump_snapshot(const char *directory,
                                         const unsigned char *commands,
                                         size_t commands_length) {
    if (!directory) return;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/resources.txt", directory);
    FILE *output = fopen(path, "w");
    if (!output) return;

    // The actual macOS 13.4 IOGPU cache image establishes these meanings:
    // IOGPUResourceCreate+0x134 copies kernel output +0x08 to wrapper+0x18,
    // IOGPUResourceGetDataBytes returns wrapper+0x18, while output +0x10 is
    // copied to wrapper+0x48 and returned by GetClientShared.  Preserve both
    // fields, but only read DataBytes for directly referenced type-0 resources.
    // The fixed count and per-resource byte cap keep a PageFault storm bounded.
    struct macws_agx_life_entry cpu_dumps[MACWS_AGX_CPU_DUMP_CAP];
    unsigned cpu_dump_count = 0;
    struct macws_agx_surface_dump
        surface_dumps[MACWS_AGX_SURFACE_DUMP_CAP];
    unsigned surface_dump_count = 0;

    pthread_mutex_lock(&g_agxLifeLock);
    fprintf(output,
        "create_ok=%llu destroy_ok=%llu create_fail=%llu destroy_fail=%llu "
        "unmatched_destroy=%llu event_newest=%llu\n",
        (unsigned long long)g_agxLifeCreateOK,
        (unsigned long long)g_agxLifeDestroyOK,
        (unsigned long long)g_agxLifeCreateFail,
        (unsigned long long)g_agxLifeDestroyFail,
        (unsigned long long)g_agxLifeUnmatchedDestroy,
        (unsigned long long)g_agxLifeEventSerial);
    fprintf(output, "[active]\n");
    for (unsigned i = 0; i < MACWS_AGX_LIFE_CAP; i++) {
        const struct macws_agx_life_entry *entry = &g_agxLife[i];
        if (entry->gid == 0 || entry->gid == UINT64_MAX) continue;
        fprintf(output,
            "gid=%#llx va=%#llx data=%#llx shared=%#llx bytes=%#llx "
            "type=%#x surface=%#x "
            "client=%#x flags14=%#x request50=%#llx\n",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->client_shared,
            (unsigned long long)entry->bytes, entry->type,
            entry->surface_id, entry->client_id, entry->flags_14,
            (unsigned long long)entry->request_50);
    }
    fprintf(output, "[kcmd-va-matches]\n");
    for (size_t offset = 0; commands && offset + 8 <= commands_length;
         offset += 8) {
        uint64_t value = *(const uint64_t *)(commands + offset);
        const struct macws_agx_life_entry *active =
            macws_agx_life_find_active_va_locked(value);
        if (active) {
            fprintf(output,
                "offset=%#zx value=%#llx state=ACTIVE gid=%#llx base=%#llx "
                "delta=%#llx bytes=%#llx type=%#x surface=%#x\n",
                offset, (unsigned long long)value,
                (unsigned long long)active->gid,
                (unsigned long long)active->gpu_address,
                (unsigned long long)(value - active->gpu_address),
                (unsigned long long)active->bytes, active->type,
                active->surface_id);
            if (active->type == 0 && active->data_bytes != 0 &&
                cpu_dump_count < MACWS_AGX_CPU_DUMP_CAP) {
                BOOL duplicate = NO;
                for (unsigned i = 0; i < cpu_dump_count; i++) {
                    if (cpu_dumps[i].gid == active->gid) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) cpu_dumps[cpu_dump_count++] = *active;
            }
            if (active->type == 0x82 && active->surface_id != 0 &&
                surface_dump_count < MACWS_AGX_SURFACE_DUMP_CAP) {
                BOOL duplicate = NO;
                for (unsigned i = 0; i < surface_dump_count; i++) {
                    const struct macws_agx_life_entry *saved =
                        &surface_dumps[i].resource;
                    if (saved->gid == active->gid &&
                        saved->gpu_address == active->gpu_address &&
                        saved->surface_id == active->surface_id) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) {
                    struct macws_agx_surface_dump *selected =
                        &surface_dumps[surface_dump_count++];
                    memset(selected, 0, sizeof(*selected));
                    selected->resource = *active;
                    const struct macws_agx_t82_request *request =
                        macws_agx_find_t82_request_locked(active);
                    if (request) {
                        selected->request = *request;
                        selected->has_request = YES;
                    }
                }
            }
            continue;
        }
        const struct macws_agx_life_event *destroyed =
            macws_agx_life_find_recent_destroyed_va_locked(value);
        if (destroyed) {
            const struct macws_agx_life_entry *entry = &destroyed->resource;
            fprintf(output,
                "offset=%#zx value=%#llx state=DESTROYED event=%llu "
                "gid=%#llx base=%#llx delta=%#llx bytes=%#llx "
                "type=%#x surface=%#x\n",
                offset, (unsigned long long)value,
                (unsigned long long)destroyed->serial,
                (unsigned long long)entry->gid,
                (unsigned long long)entry->gpu_address,
                (unsigned long long)(value - entry->gpu_address),
                (unsigned long long)entry->bytes, entry->type,
                entry->surface_id);
        }
    }
    fprintf(output, "[recent-events]\n");
    uint64_t newest = g_agxLifeEventSerial;
    uint64_t oldest = newest > MACWS_AGX_LIFE_EVENT_CAP
        ? newest - MACWS_AGX_LIFE_EVENT_CAP + 1 : 1;
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        const struct macws_agx_life_event *event =
            &g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP];
        if (event->serial != serial) continue;
        const struct macws_agx_life_entry *entry = &event->resource;
        fprintf(output,
            "event=%llu action=%s gid=%#llx va=%#llx data=%#llx "
            "shared=%#llx bytes=%#llx type=%#x surface=%#x client=%#x "
            "flags14=%#x request50=%#llx\n",
            (unsigned long long)serial,
            event->action == 1 ? "CREATE" : "DESTROY",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->client_shared,
            (unsigned long long)entry->bytes, entry->type,
            entry->surface_id, entry->client_id, entry->flags_14,
            (unsigned long long)entry->request_50);
    }
    pthread_mutex_unlock(&g_agxLifeLock);

    fprintf(output,
        "[direct-type0-cpu-dumps] selected=%u max_resources=%u "
        "max_bytes_each=%#x\n",
        cpu_dump_count, MACWS_AGX_CPU_DUMP_CAP, MACWS_AGX_CPU_DUMP_BYTES);
    for (unsigned i = 0; i < cpu_dump_count; i++) {
        const struct macws_agx_life_entry *entry = &cpu_dumps[i];
        size_t wanted = entry->bytes < MACWS_AGX_CPU_DUMP_BYTES
            ? (size_t)entry->bytes : MACWS_AGX_CPU_DUMP_BYTES;
        unsigned char *copy = wanted ? malloc(wanted) : NULL;
        mach_vm_size_t received = 0;
        kern_return_t kr = copy ? mach_vm_read_overwrite(
            mach_task_self(), (mach_vm_address_t)entry->data_bytes,
            (mach_vm_size_t)wanted, (mach_vm_address_t)copy,
            &received) : KERN_RESOURCE_SHORTAGE;
        char dump_path[PATH_MAX];
        snprintf(dump_path, sizeof(dump_path),
            "%s/resource_gid%llx_va%llx_cpu%llx.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes);
        size_t written = 0;
        if (kr == KERN_SUCCESS && received != 0) {
            FILE *dump = fopen(dump_path, "wb");
            if (dump) {
                written = fwrite(copy, 1, (size_t)received, dump);
                fclose(dump);
            }
        }
        fprintf(output,
            "gid=%#llx va=%#llx data=%#llx bytes=%#llx wanted=%#zx "
            "vm_read_kr=%#x received=%#llx written=%#zx file=%s\n",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->bytes, wanted, kr,
            (unsigned long long)received, written,
            written ? dump_path : "(none)");
        free(copy);
    }

    fprintf(output,
        "[direct-type82-iosurface-dumps] selected=%u max_resources=%u "
        "max_head_bytes_each=%#x\n",
        surface_dump_count, MACWS_AGX_SURFACE_DUMP_CAP,
        MACWS_AGX_SURFACE_DUMP_BYTES);
    for (unsigned i = 0; i < surface_dump_count; i++) {
        const struct macws_agx_surface_dump *selected = &surface_dumps[i];
        const struct macws_agx_life_entry *entry = &selected->resource;
        char raw_path[PATH_MAX], sent_path[PATH_MAX];
        snprintf(raw_path, sizeof(raw_path),
            "%s/resource_gid%llx_va%llx_surf%x_request_raw.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        snprintf(sent_path, sizeof(sent_path),
            "%s/resource_gid%llx_va%llx_surf%x_request_sent.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t raw_written = 0, sent_written = 0;
        if (selected->has_request) {
            FILE *request_file = fopen(raw_path, "wb");
            if (request_file) {
                raw_written = fwrite(selected->request.raw, 1,
                    selected->request.raw_length, request_file);
                fclose(request_file);
            }
            request_file = fopen(sent_path, "wb");
            if (request_file) {
                sent_written = fwrite(selected->request.sent, 1,
                    selected->request.sent_length, request_file);
                fclose(request_file);
            }
        }

        IOSurfaceRef surface = IOSurfaceLookup(entry->surface_id);
        fprintf(output,
            "gid=%#llx va=%#llx bytes=%#llx surface=%#x request50=%#llx "
            "request_found=%s request_seq=%llu request_event=%llu "
            "raw=%u/%#zx sent=%u/%#zx lookup=%p",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->bytes, entry->surface_id,
            (unsigned long long)entry->request_50,
            selected->has_request ? "YES" : "NO",
            (unsigned long long)selected->request.sequence,
            (unsigned long long)selected->request.life_event_serial,
            selected->request.raw_length, raw_written,
            selected->request.sent_length, sent_written,
            (__bridge void *)surface);
        if (!surface) {
            fprintf(output, "\n");
            continue;
        }

        size_t width = IOSurfaceGetWidth(surface);
        size_t height = IOSurfaceGetHeight(surface);
        size_t alloc_size = IOSurfaceGetAllocSize(surface);
        size_t bytes_per_row = IOSurfaceGetBytesPerRow(surface);
        size_t bytes_per_element = IOSurfaceGetBytesPerElement(surface);
        size_t plane_count = IOSurfaceGetPlaneCount(surface);
        OSType pixel_format = IOSurfaceGetPixelFormat(surface);
        uint32_t actual_id = IOSurfaceGetID(surface);

        char properties_path[PATH_MAX];
        snprintf(properties_path, sizeof(properties_path),
            "%s/resource_gid%llx_va%llx_surf%x_properties.plist", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t properties_written = 0;
        CFDictionaryRef properties = IOSurfaceCopyAllValues(surface);
        if (properties) {
            CFErrorRef property_error = NULL;
            CFDataRef property_data = CFPropertyListCreateData(
                kCFAllocatorDefault, properties,
                kCFPropertyListXMLFormat_v1_0, 0, &property_error);
            if (property_data) {
                FILE *properties_file = fopen(properties_path, "wb");
                if (properties_file) {
                    properties_written = fwrite(CFDataGetBytePtr(property_data),
                        1, (size_t)CFDataGetLength(property_data),
                        properties_file);
                    fclose(properties_file);
                }
                CFRelease(property_data);
            }
            if (property_error) CFRelease(property_error);
            CFRelease(properties);
        }

        uint32_t seed = 0;
        int lock_result = IOSurfaceLock(surface, 1u, &seed);
        void *base = lock_result == 0 ? IOSurfaceGetBaseAddress(surface) : NULL;
        size_t head_wanted = alloc_size < MACWS_AGX_SURFACE_DUMP_BYTES
            ? alloc_size : MACWS_AGX_SURFACE_DUMP_BYTES;
        char head_path[PATH_MAX], tail_path[PATH_MAX];
        snprintf(head_path, sizeof(head_path),
            "%s/resource_gid%llx_va%llx_surf%x_surface_head.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        snprintf(tail_path, sizeof(tail_path),
            "%s/resource_gid%llx_va%llx_surf%x_surface_tail.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t head_written = 0, tail_written = 0;
        if (base && head_wanted != 0) {
            FILE *surface_file = fopen(head_path, "wb");
            if (surface_file) {
                head_written = fwrite(base, 1, head_wanted, surface_file);
                fclose(surface_file);
            }
            if (alloc_size > head_wanted) {
                size_t tail_wanted = alloc_size - head_wanted;
                if (tail_wanted > 0x10000) tail_wanted = 0x10000;
                surface_file = fopen(tail_path, "wb");
                if (surface_file) {
                    tail_written = fwrite((const unsigned char *)base +
                        alloc_size - tail_wanted, 1, tail_wanted,
                        surface_file);
                    fclose(surface_file);
                }
            }
        }
        int unlock_result = lock_result == 0
            ? IOSurfaceUnlock(surface, 1u, &seed) : -1;
        fprintf(output,
            " actual_id=%#x width=%#zx height=%#zx alloc=%#zx bpr=%#zx "
            "bpe=%#zx planes=%#zx pixel_format=%#x properties=%#zx "
            "lock=%d base=%p seed=%u head=%#zx/%#zx tail=%#zx "
            "unlock=%d\n",
            actual_id, width, height, alloc_size, bytes_per_row,
            bytes_per_element, plane_count, (unsigned)pixel_format,
            properties_written, lock_result, base, seed,
            head_written, head_wanted, tail_written, unlock_result);
        CFRelease((CFTypeRef)surface);
    }
    fclose(output);
}

// 2026-06-19 — sel=0xa double-translation root cause:
// `launchdchrootexec` DYLD_INSERTs BOTH `libmachook.dylib` (arm64e) and
// `libmachook_arm64.dylib` (arm64). For arm64 chroot binaries (bash, our
// test tools), macOS arm64e dyld actually loads BOTH dylibs side-by-side
// (the comment in launchdchrootexec/main.m's "silently skips" is wrong:
// the device's dyld loads both anyway). Both run their initializers, both
// register DYLD_INTERPOSE tuples for IOConnectCallMethod. The result is
// that EACH `IOConnectCallMethod_new` invocation is re-entered AGAIN by
// the OTHER dylib's interpose. With per-dylib static `g_skip_translate`,
// the inner re-entry sees a different variable address (proved by &g_skip
// dump: outer 0x10090c9c0, inner 0x10087c5f0). The selector gets
// translated TWICE — for sel=0xa: 0xa→0x9→0x8 (queue_finalize) — and the
// kernel returns kIOReturnNoBandwidth (0xe00002c2). EVERY chroot
// "sel=0xa fails" event traces back to this. Decisive fix: detect the
// re-entry by inspecting the immediate caller via __builtin_return_address;
// if the caller is inside ANY copy of libmachook, skip translation. Works
// regardless of how many libmachook arch variants are loaded.
static int caller_is_libmachook(void *ret) {
    Dl_info di;
    if (!dladdr(ret, &di) || !di.dli_fname) return 0;
    const char *base = strrchr(di.dli_fname, '/');
    base = base ? base + 1 : di.dli_fname;
    return strncmp(base, "libmachook", 10) == 0;
}

// Diagnostic protocol adapter for coexistence-mode IOMFB cancellation.
//
// Runtime-confirmed on 2026-07-25 with the exact QuartzCore image
// CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC:
//   * IOMobileFramebufferFrameInfo registration returned 0 and enabled the
//     display's frame-info bit;
//   * every successful SwapCancel ID (10759...) was subsequently retained in
//     IOMFBDisplay's pending FrameInfo vector at +0x510/+0x518;
//   * no frame_info_callback fired, so the vector and 15-MiB IOSurfaces grew
//     until Jetsam (792819 x 16-KiB resident pages).
// A cancelled swap has no physical-display completion notification.  Observe
// Apple's enabled registration state and exact callback/context so the opt-in
// diagnostic can synthesize the missing *cancellation completion* after the
// successful Cancel returns.
// This is deliberately gated by /tmp/macws_cancel_completion until runtime
// proves callback ordering, bounded ownership, and unchanged VNC pixels.
typedef void *MacwsIOMobileFramebufferRef;
typedef void (*MacwsIOMFBFrameInfoCallback)(
    MacwsIOMobileFramebufferRef framebuffer, uint32_t swap_id,
    CFDictionaryRef info, void *context);

struct macws_iomfb_frame_registration {
    MacwsIOMobileFramebufferRef framebuffer;
    io_connect_t client;
    MacwsIOMFBFrameInfoCallback callback;
    void *context;
    uint64_t last_presentation_time;
};

static pthread_mutex_t g_macws_iomfb_frame_lock = PTHREAD_MUTEX_INITIALIZER;
static struct macws_iomfb_frame_registration g_macws_iomfb_frame_regs[8];
static unsigned g_macws_iomfb_frame_reg_count = 0;

// Do not wrap IOMobileFramebufferFrameInfo itself.  Runtime control runs
// showed that adding a plain-arm64 forwarding frame makes its private callback
// registration return kIOReturnNoBandwidth, while the untouched QuartzCore
// call returns success.  Instead observe the immediately following
// IOMFBServer::enable_frame_info_tag_list call.  RE-confirmed call order at
// QuartzCore 0x187ac8d44..0x187ac8d70 is:
//   FrameInfo(...) -> set_frame_info_enabled(status == 0) -> enable_tag_list.
// The enabled bit written by set_frame_info_enabled is display+0x9a4 bit 35.
typedef void (*MacwsEnableFrameInfoTagListFunction)(
    void *server, const char *const *available_tags, size_t available_count,
    const char *const *requested_tags, size_t requested_count);
static MacwsEnableFrameInfoTagListFunction
    g_macws_orig_enable_frame_info_tag_list = NULL;
static uintptr_t g_macws_quartzcore_header = 0;

static void macws_enable_frame_info_tag_list(
    void *server, const char *const *available_tags, size_t available_count,
    const char *const *requested_tags, size_t requested_count) {
    g_macws_orig_enable_frame_info_tag_list(server, available_tags,
        available_count, requested_tags, requested_count);

    if (!server || !g_macws_quartzcore_header)
        return;
    void *display_holder = *(void **)((char *)server + 0x58);
    void *display = display_holder;
    MacwsIOMobileFramebufferRef framebuffer = display_holder
        ? *(MacwsIOMobileFramebufferRef *)((char *)display_holder + 0x300)
        : NULL;
    uint64_t flags = display
        ? *(const volatile uint64_t *)((const char *)display + 0x9a4)
        : 0;
    BOOL frame_info_enabled = (flags & 0x800000000ull) != 0;
    if (!frame_info_enabled || !framebuffer)
        return;

    // RE-confirmed via live iOS 16.3.1 kern_SwapEnd: the io_connect_t used for
    // selector 5 is the uint32_t at IOMobileFramebufferRef+0x14.  QuartzCore's
    // exact frame_info_callback is at image offset 0x29209c; call its raw code
    // address from the plain-arm64 WindowServer slice on the main queue.
    io_connect_t client =
        *(const volatile io_connect_t *)((const char *)framebuffer + 0x14);
    MacwsIOMFBFrameInfoCallback callback =
        (MacwsIOMFBFrameInfoCallback)(g_macws_quartzcore_header + 0x29209c);
    unsigned registration_slot = 0;
    pthread_mutex_lock(&g_macws_iomfb_frame_lock);
    for (; registration_slot < g_macws_iomfb_frame_reg_count;
         registration_slot++) {
        if (g_macws_iomfb_frame_regs[registration_slot].framebuffer ==
            framebuffer) {
            break;
        }
    }
    if (registration_slot == g_macws_iomfb_frame_reg_count &&
        registration_slot < sizeof(g_macws_iomfb_frame_regs) /
                                sizeof(g_macws_iomfb_frame_regs[0])) {
        g_macws_iomfb_frame_reg_count++;
    }
    if (registration_slot < sizeof(g_macws_iomfb_frame_regs) /
                                sizeof(g_macws_iomfb_frame_regs[0])) {
        uint64_t last_presentation_time =
            g_macws_iomfb_frame_regs[registration_slot]
                .last_presentation_time;
        g_macws_iomfb_frame_regs[registration_slot] =
            (struct macws_iomfb_frame_registration){
                framebuffer, client, callback, server,
                last_presentation_time};
    }
    pthread_mutex_unlock(&g_macws_iomfb_frame_lock);
    fprintf(stderr,
        "#### IOMFB CANCEL-COMPLETION observed enabled registration "
        "fb=%p client=%u callback=%p context=%p flags=%#llx slot=%u "
        "vsync=%#x source=%#x displayTimer=%p fallbackTimer=%p runLoop=%p\n",
        framebuffer, client, callback, server,
        (unsigned long long)flags, registration_slot,
        *(const volatile uint8_t *)((const char *)server + 0x324),
        *(const volatile uint8_t *)((const char *)server + 0x325),
        *(void *const volatile *)((const char *)server + 0x298),
        *(void *const volatile *)((const char *)server + 0x2a0),
        *(void *const volatile *)((const char *)server + 0x278));
}

static void macws_install_quartzcore_frame_info_hook(
    const struct mach_header *untyped_header) {
    // RE-confirmed via the exact macOS 13.4 QuartzCore image:
    //   UUID CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC
    //   __TEXT vmaddr                                  0x1879be000
    //   IOMFBServer::enable_frame_info_tag_list        0x187c5085c
    //   IOMFBServer::frame_info_callback               0x187c5009c
    static const uint8_t expected_uuid[16] = {
        0xcf, 0x85, 0x3b, 0xbd, 0x01, 0xb6, 0x3f, 0x46,
        0xad, 0xa1, 0xec, 0x70, 0xfd, 0x2d, 0xc9, 0xdc,
    };
    static const uint32_t expected_prologue[4] = {
        0xd503237f, // pacibsp
        0xd10243ff, // sub sp, sp, #0x90
        0xa9036ffc, // stp x28, x27, [sp, #0x30]
        0xa90467fa, // stp x26, x25, [sp, #0x40]
    };
    enum {
        kQuartzCoreEnableFrameInfoTagListOffset = 0x29285c,
    };

    static _Atomic int installed = 0;
    if (atomic_exchange(&installed, 1))
        return;

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!header || header->magic != MH_MAGIC_64) {
        atomic_store(&installed, 0);
        return;
    }
    const uint8_t *command_bytes = (const uint8_t *)(header + 1);
    BOOL uuid_matches = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)command_bytes;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            uuid_matches = memcmp(uuid->uuid, expected_uuid,
                                  sizeof(expected_uuid)) == 0;
            break;
        }
        if (command->cmdsize < sizeof(*command))
            break;
        command_bytes += command->cmdsize;
    }
    if (!uuid_matches) {
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION QuartzCore observer skipped: "
            "UUID mismatch\n");
        atomic_store(&installed, 0);
        return;
    }

    void *target = (void *)((uintptr_t)header +
        kQuartzCoreEnableFrameInfoTagListOffset);
    if (memcmp(target, expected_prologue, sizeof(expected_prologue)) != 0) {
        const uint32_t *actual = (const uint32_t *)target;
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION QuartzCore observer skipped: "
            "enable-tag-list prologue mismatch %#x %#x %#x %#x\n",
            actual[0], actual[1], actual[2], actual[3]);
        atomic_store(&installed, 0);
        return;
    }

    g_macws_quartzcore_header = (uintptr_t)header;
    MSHookFunction(target, (void *)macws_enable_frame_info_tag_list,
        (void **)&g_macws_orig_enable_frame_info_tag_list);
    fprintf(stderr,
        "#### IOMFB CANCEL-COMPLETION QuartzCore observer "
        "enable-tag-list=%p trampoline=%p callback=%p\n",
        target, g_macws_orig_enable_frame_info_tag_list,
        (void *)(g_macws_quartzcore_header + 0x29209c));
}

static void macws_iomfb_complete_cancelled_swap(
    io_connect_t client, uint32_t swap_id,
    uint64_t requested_presentation_time) {
    if (access("/tmp/macws_cancel_completion", F_OK) != 0)
        return;

    struct macws_iomfb_frame_registration registration = {0};
    pthread_mutex_lock(&g_macws_iomfb_frame_lock);
    for (unsigned i = 0; i < g_macws_iomfb_frame_reg_count; i++) {
        if (g_macws_iomfb_frame_regs[i].client == client) {
            registration = g_macws_iomfb_frame_regs[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_macws_iomfb_frame_lock);

    static _Atomic unsigned long scheduled_count = 0;
    unsigned long sequence = atomic_fetch_add(&scheduled_count, 1) + 1;
    if (!registration.callback) {
        if (sequence <= 16 || (sequence % 600) == 0) {
            fprintf(stderr,
                "#### IOMFB CANCEL-COMPLETION schedule #%lu swapID=%u "
                "client=%u FAIL no registration\n",
                sequence, swap_id, client);
        }
        return;
    }

    // A 200-ms FIFO experiment was runtime-disproved on 2026-07-26:
    // submissions were not completion-paced, so the FIFO grew without bound
    // while WindowServer stayed at 83-86% CPU.  Keep one completion per
    // successful cancellation and let the caller pace the ownership boundary.
    if (sequence <= 16 || (sequence % 600) == 0) {
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION schedule #%lu swapID=%u "
            "client=%u fb=%p\n",
            sequence, swap_id, client, registration.framebuffer);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // RE-confirmed from the exact macOS 13.4 QuartzCore image
        // CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC. frame_info_callback at
        // 0x187c5009c reads Presentation_time, Vbl_FrameTime (falling back to
        // Presentation_time only when zero), Requested_presentation,
        // Min_FrameTime, and Max_FrameTime.  It converts the first three raw
        // mach_absolute_time ticks and uses them in its presentation cadence
        // calculation.  The prior empty dictionary therefore did not merely
        // omit optional telemetry: it supplied zero scheduler timestamps.
        //
        // Runtime-confirmed in native iOS 16.3 backboardd at QuartzCore
        // 0x19d41717c: these keys are NSNumber values in raw absolute-time
        // ticks; Vbl_FrameTime was Presentation_time-3 in the captured real
        // frame, and Min/Max were zero.  A cancelled coexistence frame has no
        // physical scanout, so its paced delivery slot is the virtual vblank
        // and both presentation fields use that same honest delivery time.
        uint64_t presentation_time = mach_absolute_time();
        uint64_t presentation_delta = 0;
        pthread_mutex_lock(&g_macws_iomfb_frame_lock);
        for (unsigned i = 0; i < g_macws_iomfb_frame_reg_count; i++) {
            if (g_macws_iomfb_frame_regs[i].client == client) {
                uint64_t prior = g_macws_iomfb_frame_regs[i]
                    .last_presentation_time;
                if (prior && presentation_time >= prior)
                    presentation_delta = presentation_time - prior;
                g_macws_iomfb_frame_regs[i].last_presentation_time =
                    presentation_time;
                break;
            }
        }
        pthread_mutex_unlock(&g_macws_iomfb_frame_lock);
        if (!presentation_delta &&
            presentation_time >= requested_presentation_time) {
            presentation_delta =
                presentation_time - requested_presentation_time;
        }

        void *display_holder = registration.context
            ? *(void **)((char *)registration.context + 0x58) : NULL;
        uintptr_t pending_begin_before = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x510) : 0;
        uintptr_t pending_end_before = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x518) : 0;
        size_t pending_before = pending_end_before >= pending_begin_before
            ? (pending_end_before - pending_begin_before) / sizeof(void *) : 0;
        NSDictionary *cancelInfo = @{
            @"Presentation_delta": @(presentation_delta),
            @"Presentation_time": @(presentation_time),
            @"Requested_presentation": @(requested_presentation_time),
            @"Vbl_FrameTime": @(presentation_time),
            @"Min_FrameTime": @0ull,
            @"Max_FrameTime": @0ull,
        };
        registration.callback(registration.framebuffer, swap_id,
            (__bridge CFDictionaryRef)cancelInfo, registration.context);
        uintptr_t pending_begin_after = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x510) : 0;
        uintptr_t pending_end_after = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x518) : 0;
        size_t pending_after = pending_end_after >= pending_begin_after
            ? (pending_end_after - pending_begin_after) / sizeof(void *) : 0;
        static _Atomic unsigned long delivered_count = 0;
        unsigned long delivered = atomic_fetch_add(&delivered_count, 1) + 1;
        if (delivered <= 16 || (delivered % 600) == 0) {
            fprintf(stderr,
                "#### IOMFB CANCEL-COMPLETION delivered #%lu swapID=%u "
                "client=%u requested=%llu presentation=%llu delta=%llu "
                "pending=%zu->%zu\n",
                delivered, swap_id, client,
                (unsigned long long)requested_presentation_time,
                (unsigned long long)presentation_time,
                (unsigned long long)presentation_delta,
                pending_before, pending_after);
        }
    });
}

// Bounded command-submit diagnostics for the native-AGX VNC control pass.
//
// Enable read-only capture by creating /tmp/macws_submit_diag in the chroot.
// At most eight translated selector-0x1a submits are inspected per process,
// and at most 0x300 command bytes are printed for each descriptor.  Each
// structurally valid subtype-1 record is also copied verbatim to
// /tmp/macws_submit_type1_<sequence>_<record>.bin.  The binary artifact is
// needed for a byte-for-byte comparison with the native-iOS record; stderr's
// bounded prefix is insufficient to locate a trailing ABI insertion.  This
// is intentionally opt-in: ordinary WindowServer submits are far too frequent
// for an unconditional deep dump.
//
// /tmp/macws_kcmd_fix enables a SEPARATE TEMPORARY ABI-TRANSLATION
// EXPERIMENT.  It is not a production fix.  Historical native-iOS versus
// macOS-chroot byte captures found a subtype-3 record whose macOS form had a
// 16-byte zero pad before the same 12-byte terminal sentinel.  We only remove
// that pad when every structural field and every signature byte matches.  A
// successful IOConnect return is not evidence that this worked; the caller's
// exact clear/control pixel remains the required execution witness.
struct macws_submit_diag_result {
    unsigned sequence;
    unsigned records;
    unsigned candidates;
    unsigned fixed;
};

static _Atomic unsigned g_macws_submit_diag_sequence = 0;
// The compositor submits multi-segment KCMD storage continuously.  Preserve
// translation for every structurally validated submission (later frames are
// the actual GUI witness), while bounding the per-segment diagnostic output.
static _Atomic unsigned g_macws_multisegment_log_batches = 0;

// Completion errors are asynchronous: by the time Metal exposes an NSError,
// the selector-0x1a IOConnect call that supplied the offending bytes has long
// returned and its command-storage object may already be recycled.  The old
// "first eight submits" capture therefore missed the first Terminal workload
// that runtime-reported `00000102` after more than 500 successful submissions.
//
// `/tmp/macws_submit_ring` enables a read-only, process-local flight recorder.
// It retains the most recent 2048 descriptor snapshots in memory and writes them
// only when `macws_dump_recent_agx_submits` is called by the Metal completion
// observer.  This is diagnostic instrumentation, not an ABI patch: it neither
// changes submission order nor modifies any additional command bytes.
#define MACWS_SUBMIT_RING_COUNT 2048
#define MACWS_SUBMIT_RING_MAX_BYTES 0x10000

struct macws_submit_ring_entry {
    uint64_t serial;
    uint64_t life_event_serial;
    unsigned sequence;
    unsigned descriptor;
    unsigned fixed;
    uintptr_t descriptor_pointer;
    uintptr_t command_buffer;
    uintptr_t storage;
    size_t pre_commands_length;
    size_t pre_segments_length;
    size_t post_commands_length;
    size_t post_segments_length;
    unsigned char *pre_commands;
    unsigned char *pre_segments;
    unsigned char *post_commands;
    unsigned char *post_segments;
};

struct macws_submit_ring_token {
    uint64_t serial;
    unsigned slot;
    int active;
};

static pthread_mutex_t g_macws_submit_ring_lock = PTHREAD_MUTEX_INITIALIZER;
static struct macws_submit_ring_entry
    g_macws_submit_ring[MACWS_SUBMIT_RING_COUNT];
static _Atomic uint64_t g_macws_submit_ring_serial = 0;
static _Atomic unsigned g_macws_submit_ring_dump_count = 0;

// A diagnostic producer (currently the native tile-binding witness) can mark
// the exact Metal command-buffer objects whose KCMD bytes must survive an
// asynchronous error delay. Pointer values only: this does not retain or
// message the object and therefore cannot extend a resource lifetime.
#define MACWS_SUBMIT_MARK_COUNT 32u
static _Atomic uintptr_t g_macws_submit_marks[MACWS_SUBMIT_MARK_COUNT];
static _Atomic uint64_t g_macws_submit_mark_serial = 0;
static _Atomic uint64_t g_macws_submit_serial_marks[MACWS_SUBMIT_MARK_COUNT];

__attribute__((used, visibility("default")))
void macws_mark_agx_submit_for_error_dump(const void *command_buffer) {
    if (!command_buffer || access("/tmp/macws_submit_ring", F_OK) != 0)
        return;
    uint64_t serial = atomic_fetch_add(&g_macws_submit_mark_serial, 1) + 1;
    atomic_store(&g_macws_submit_marks[
        (serial - 1) % MACWS_SUBMIT_MARK_COUNT],
        (uintptr_t)command_buffer);
    if (serial <= 8) {
        fprintf(stderr,
            "#### AGX_SUBMIT_RING mark #%llu commandBuffer=%p "
            "(pointer only; no retain)\n",
            (unsigned long long)serial, command_buffer);
    }
}

__attribute__((used, visibility("default")))
void macws_mark_agx_submit_serial_for_error_dump(uint64_t submit_serial) {
    if (!submit_serial || access("/tmp/macws_submit_ring", F_OK) != 0)
        return;
    uint64_t mark = atomic_fetch_add(&g_macws_submit_mark_serial, 1) + 1;
    atomic_store(&g_macws_submit_serial_marks[
        (mark - 1) % MACWS_SUBMIT_MARK_COUNT], submit_serial);
}

static BOOL macws_submit_ring_is_marked(uintptr_t command_buffer) {
    if (!command_buffer) return NO;
    for (size_t i = 0; i < MACWS_SUBMIT_MARK_COUNT; i++) {
        if (atomic_load(&g_macws_submit_marks[i]) == command_buffer)
            return YES;
    }
    return NO;
}

static BOOL macws_submit_ring_serial_is_marked(uint64_t submit_serial) {
    if (!submit_serial) return NO;
    for (size_t i = 0; i < MACWS_SUBMIT_MARK_COUNT; i++) {
        if (atomic_load(&g_macws_submit_serial_marks[i]) == submit_serial)
            return YES;
    }
    return NO;
}

__attribute__((used, visibility("default")))
uint64_t macws_latest_agx_submit_serial(const void *command_buffer) {
    if (!command_buffer || access("/tmp/macws_submit_ring", F_OK) != 0)
        return 0;
    uint64_t result = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    uint64_t newest = atomic_load(&g_macws_submit_ring_serial);
    uint64_t oldest = newest > MACWS_SUBMIT_RING_COUNT
        ? newest - MACWS_SUBMIT_RING_COUNT + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == serial &&
            entry->command_buffer == (uintptr_t)command_buffer) {
            result = serial;
            break;
        }
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return result;
}

__attribute__((used, visibility("default")))
unsigned macws_agx_submit_fixed_count(uint64_t submit_serial) {
    if (!submit_serial || access("/tmp/macws_submit_ring", F_OK) != 0)
        return 0;
    unsigned result = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    unsigned slot = (unsigned)((submit_serial - 1) %
                               MACWS_SUBMIT_RING_COUNT);
    struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
    if (entry->serial == submit_serial)
        result = entry->fixed;
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return result;
}

__attribute__((used, visibility("default")))
int macws_agx_submit_dimensions(uint64_t submit_serial,
                                uint32_t *width_out,
                                uint32_t *height_out) {
    if (!submit_serial || access("/tmp/macws_submit_ring", F_OK) != 0)
        return 0;
    int result = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    unsigned slot = (unsigned)((submit_serial - 1) %
                               MACWS_SUBMIT_RING_COUNT);
    struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
    // The first translated render record stores its target dimensions at
    // record+0x3b0/+0x3b4 in both the pre- and post-normalized layouts.
    if (entry->serial == submit_serial && entry->post_commands &&
        entry->post_commands_length >= 0x3b8) {
        memcpy(&width, entry->post_commands + 0x3b0, sizeof(width));
        memcpy(&height, entry->post_commands + 0x3b4, sizeof(height));
        result = width != 0 && height != 0;
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    if (result) {
        if (width_out) *width_out = width;
        if (height_out) *height_out = height;
    }
    return result;
}

static void macws_submit_ring_replace(unsigned char **destination,
                                      size_t *destination_length,
                                      const unsigned char *source,
                                      size_t source_length) {
    free(*destination);
    *destination = NULL;
    *destination_length = 0;
    if (!source || source_length == 0 ||
        source_length > MACWS_SUBMIT_RING_MAX_BYTES)
        return;
    unsigned char *copy = malloc(source_length);
    if (!copy) return;
    memcpy(copy, source, source_length);
    *destination = copy;
    *destination_length = source_length;
}

static struct macws_submit_ring_token macws_submit_ring_begin(
        unsigned sequence, unsigned descriptor,
        uintptr_t descriptor_pointer, uintptr_t command_buffer,
        uintptr_t storage,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    struct macws_submit_ring_token token = {0};
    if (access("/tmp/macws_submit_ring", F_OK) != 0)
        return token;

    token.serial = atomic_fetch_add(&g_macws_submit_ring_serial, 1) + 1;
    token.slot = (unsigned)((token.serial - 1) % MACWS_SUBMIT_RING_COUNT);
    token.active = 1;

    // Take the lifecycle boundary before the ring lock.  Error dumping uses
    // ring -> lifecycle lock order; never invert that order here.  Other
    // threads may create resources after this point, but every event at or
    // below this serial was visible when the segment list was captured.
    uint64_t life_event_serial = macws_agx_life_current_event_serial();

    pthread_mutex_lock(&g_macws_submit_ring_lock);
    struct macws_submit_ring_entry *entry =
        &g_macws_submit_ring[token.slot];
    macws_submit_ring_replace(&entry->pre_commands,
        &entry->pre_commands_length, commands, commands_length);
    macws_submit_ring_replace(&entry->pre_segments,
        &entry->pre_segments_length, segments, segments_length);
    macws_submit_ring_replace(&entry->post_commands,
        &entry->post_commands_length, NULL, 0);
    macws_submit_ring_replace(&entry->post_segments,
        &entry->post_segments_length, NULL, 0);
    entry->sequence = sequence;
    entry->descriptor = descriptor;
    entry->fixed = 0;
    entry->descriptor_pointer = descriptor_pointer;
    entry->command_buffer = command_buffer;
    entry->storage = storage;
    entry->life_event_serial = life_event_serial;
    // Publish serial last while holding the lock.  A concurrent error dumper
    // can never observe new metadata paired with the overwritten slot's data.
    entry->serial = token.serial;
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return token;
}

static void macws_submit_ring_finish(
        struct macws_submit_ring_token token, unsigned fixed,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    if (!token.active) return;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    struct macws_submit_ring_entry *entry =
        &g_macws_submit_ring[token.slot];
    if (entry->serial == token.serial) {
        entry->fixed = fixed;
        macws_submit_ring_replace(&entry->post_commands,
            &entry->post_commands_length, commands, commands_length);
        macws_submit_ring_replace(&entry->post_segments,
            &entry->post_segments_length, segments, segments_length);
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
}

static size_t macws_submit_ring_write_file(const char *path,
                                           const unsigned char *bytes,
                                           size_t length) {
    if (!path || !bytes || !length) return 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 0;
    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, bytes + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    close(fd);
    return written;
}

static void macws_dump_recent_agx_submits_impl(
        const char *reason, const void *command_buffer,
        uint64_t requested_serial) {
    if (access("/tmp/macws_submit_ring", F_OK) != 0)
        return;
    unsigned dump = atomic_fetch_add(&g_macws_submit_ring_dump_count, 1) + 1;
    // Keep the first generic completion error, the first raw page-fault
    // callback, and one post-recovery clean control as separate witnesses.
    // WindowServer currently reports an
    // early Code=1/00000102 command-buffer error before the later Code=3
    // address fault; a one-dump process limit let that startup error consume
    // the only slot and hid the faulting submission.  The Metal observer uses
    // independent one-shot latches for those classes.  The existing public
    // Metal completion observer also consumes one slot immediately after the
    // raw PageFault callback, so four directories are required to retain the
    // later post-recovery clean control.  The bound still prevents a GPU
    // recovery storm from writing indefinitely.
    if (dump > 4) return;

    char directory[PATH_MAX];
    snprintf(directory, sizeof(directory),
        "/tmp/macws_submit_error_%d_%u", getpid(), dump);
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr,
            "#### AGX_SUBMIT_RING dump mkdir failed path=%s errno=%d\n",
            directory, errno);
        return;
    }

    char manifest_path[PATH_MAX];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.txt",
        directory);
    FILE *manifest = fopen(manifest_path, "w");
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    uint64_t newest = atomic_load(&g_macws_submit_ring_serial);
    uint64_t oldest = newest > MACWS_SUBMIT_RING_COUNT
        ? newest - MACWS_SUBMIT_RING_COUNT + 1 : 1;
    uint64_t matched_serial = 0;
    struct macws_submit_ring_entry *matched_entry = NULL;
    if (requested_serial >= oldest && requested_serial <= newest) {
        unsigned slot = (unsigned)((requested_serial - 1) %
                                   MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == requested_serial) {
            matched_serial = requested_serial;
            matched_entry = entry;
        }
    }
    for (uint64_t serial = oldest;
         !matched_entry && serial <= newest; serial++) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == serial &&
            entry->command_buffer == (uintptr_t)command_buffer) {
            matched_serial = serial;
            matched_entry = entry;
            break;
        }
    }
    unsigned saved = 0;
    if (manifest) fprintf(manifest,
        "reason=%s pid=%d command_buffer=%p requested_serial=%llu "
        "matched_serial=%llu "
        "oldest=%llu newest=%llu\n",
        reason ?: "(nil)", getpid(), command_buffer,
        (unsigned long long)requested_serial,
        (unsigned long long)matched_serial,
        (unsigned long long)oldest, (unsigned long long)newest);
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry =
            &g_macws_submit_ring[slot];
        if (entry->serial != serial) continue;
        if (manifest) fprintf(manifest,
            "serial=%llu life_event_serial=%llu "
            "sequence=%u descriptor=%u fixed=%u "
            "descriptor_pointer=%#llx command_buffer=%#llx storage=%#llx "
            "matched=%s marked=%s serial_marked=%s "
            "pre_commands=%zu pre_segments=%zu "
            "post_commands=%zu post_segments=%zu\n",
            (unsigned long long)entry->serial,
            (unsigned long long)entry->life_event_serial, entry->sequence,
            entry->descriptor, entry->fixed,
            (unsigned long long)entry->descriptor_pointer,
            (unsigned long long)entry->command_buffer,
            (unsigned long long)entry->storage,
            (requested_serial
                ? entry->serial == requested_serial
                : entry->command_buffer == (uintptr_t)command_buffer)
                ? "YES" : "NO",
            macws_submit_ring_is_marked(entry->command_buffer)
                ? "YES" : "NO",
            macws_submit_ring_serial_is_marked(entry->serial)
                ? "YES" : "NO",
            entry->pre_commands_length, entry->pre_segments_length,
            entry->post_commands_length, entry->post_segments_length);

        struct {
            const char *phase;
            const char *kind;
            const unsigned char *bytes;
            size_t length;
        } files[] = {
            {"pre", "kcmd", entry->pre_commands,
                entry->pre_commands_length},
            {"pre", "segments", entry->pre_segments,
                entry->pre_segments_length},
            {"post", "kcmd", entry->post_commands,
                entry->post_commands_length},
            {"post", "segments", entry->post_segments,
                entry->post_segments_length},
        };
        // Retain all metadata, but write bytes only for the exact matching
        // descriptor owner plus the most recent 64 submits.  A 2048-entry
        // in-memory window is needed because WindowServer can have roughly
        // 1000 producers outstanding before Metal reports the first error;
        // writing four files for every entry would distort that timing and
        // needlessly consume the chroot filesystem.
        BOOL write_bytes =
            (requested_serial && entry->serial == requested_serial) ||
            entry->command_buffer == (uintptr_t)command_buffer ||
            // Large translated compositor batches are rare, and an earlier
            // clean batch is the strongest control for a later batch of the
            // same shape that page-faults.  Save them directly instead of
            // relying on the shared 32-slot tile mark ring, whose entries can
            // be evicted during the roughly 100 submissions between control
            // and fault.
            entry->fixed >= 8 ||
            macws_submit_ring_is_marked(entry->command_buffer) ||
            macws_submit_ring_serial_is_marked(entry->serial) ||
            serial + 64 > newest;
        for (size_t i = 0; write_bytes &&
             i < sizeof(files) / sizeof(files[0]); i++) {
            if (!files[i].bytes || !files[i].length) continue;
            char path[PATH_MAX];
            snprintf(path, sizeof(path),
                "%s/s%llu_q%u_d%u_%s_%s.bin", directory,
                (unsigned long long)entry->serial, entry->sequence,
                entry->descriptor, files[i].phase, files[i].kind);
            macws_submit_ring_write_file(
                path, files[i].bytes, files[i].length);
        }
        saved++;
    }
    macws_agx_life_dump_snapshot(directory,
        matched_entry ? matched_entry->post_commands : NULL,
        matched_entry ? matched_entry->post_commands_length : 0);
    if (manifest) fclose(manifest);
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    fprintf(stderr,
        "#### AGX_SUBMIT_RING dumped reason=%s commandBuffer=%p entries=%u "
        "range=%llu..%llu path=%s\n",
        reason ?: "(nil)", command_buffer, saved,
        (unsigned long long)oldest,
        (unsigned long long)newest, directory);
}

__attribute__((used, visibility("default")))
void macws_dump_recent_agx_submits(const char *reason,
                                   const void *command_buffer) {
    macws_dump_recent_agx_submits_impl(reason, command_buffer, 0);
}

__attribute__((used, visibility("default")))
void macws_dump_recent_agx_submit_serial(const char *reason,
                                         const void *command_buffer,
                                         uint64_t submit_serial) {
    macws_dump_recent_agx_submits_impl(
        reason, command_buffer, submit_serial);
}

// Low-disturbance first-error flight recorder for high-rate Chromium submits.
//
// The older /tmp/macws_submit_ring recorder intentionally retains complete
// pre/post command and segment blobs, but it does so with four heap operations
// while holding one process-wide mutex for every descriptor.  A runtime CPU
// sample from the VS Code GPU process caught macws_submit_ring_begin on that
// hot path, and the first 0x102 error reproducibly disappeared when the deep
// ring was enabled.  That makes the deep ring unsuitable for finding a timing-
// sensitive high-concurrency failure.
//
// /tmp/macws_submit_fast_ring selects this separate recorder.  Its producer
// path has no allocation, file I/O, or mutex: a descriptor copies only its
// post-translation bytes into a preallocated slot.  The error observer freezes
// the recorder before reading it, waits for every in-flight producer to leave,
// and only then writes the first snapshot.  The bounded payload is deliberate:
// existing VS Code failure witnesses are 0x858-byte commands with 0x188-byte
// segment lists, while the larger multi-record batches remain represented by
// their full lengths and a truncated prefix.
#define MACWS_FAST_SUBMIT_RING_COUNT 1024u
#define MACWS_FAST_SUBMIT_COMMAND_CAP 0x3000u
#define MACWS_FAST_SUBMIT_SEGMENT_CAP 0x1000u

struct macws_fast_submit_entry {
    _Atomic uint64_t guard;
    _Atomic uint64_t serial;
    _Atomic uintptr_t command_buffer;
    uint64_t life_event_serial;
    unsigned sequence;
    unsigned descriptor;
    _Atomic unsigned fixed;
    uintptr_t descriptor_pointer;
    uintptr_t storage;
    size_t commands_length;
    size_t commands_saved;
    size_t segments_length;
    size_t segments_saved;
    unsigned char commands[MACWS_FAST_SUBMIT_COMMAND_CAP];
    unsigned char segments[MACWS_FAST_SUBMIT_SEGMENT_CAP];
};

struct macws_fast_submit_token {
    uint64_t serial;
    uint64_t life_event_serial;
    unsigned slot;
    unsigned sequence;
    unsigned descriptor;
    uintptr_t descriptor_pointer;
    uintptr_t command_buffer;
    uintptr_t storage;
    int active;
};

static struct macws_fast_submit_entry
    g_macws_fast_submit_ring[MACWS_FAST_SUBMIT_RING_COUNT];
static _Atomic int g_macws_fast_submit_enabled = -1;
static _Atomic int g_macws_fast_submit_frozen = 0;
static _Atomic unsigned g_macws_fast_submit_active = 0;
static _Atomic unsigned g_macws_fast_submit_dump_count = 0;
static _Atomic uint64_t g_macws_fast_submit_serial = 0;

static int macws_fast_submit_is_enabled(void) {
    int enabled = atomic_load_explicit(
        &g_macws_fast_submit_enabled, memory_order_acquire);
    if (enabled >= 0) return enabled;
    int detected = getenv("MACWS_SUBMIT_FAST_RING") != NULL ||
        access("/tmp/macws_submit_fast_ring", F_OK) == 0;
    int expected = -1;
    atomic_compare_exchange_strong_explicit(
        &g_macws_fast_submit_enabled, &expected, detected,
        memory_order_release, memory_order_relaxed);
    return atomic_load_explicit(
        &g_macws_fast_submit_enabled, memory_order_acquire);
}

static struct macws_fast_submit_token macws_fast_submit_begin(
        unsigned sequence, unsigned descriptor,
        uintptr_t descriptor_pointer, uintptr_t command_buffer,
        uintptr_t storage) {
    struct macws_fast_submit_token token = {0};
    if (!macws_fast_submit_is_enabled() ||
        atomic_load_explicit(&g_macws_fast_submit_frozen,
                             memory_order_acquire)) {
        return token;
    }

    atomic_fetch_add_explicit(&g_macws_fast_submit_active, 1,
                              memory_order_acq_rel);
    // Close the race with the error thread: once frozen is published, that
    // thread waits for this active count before touching any non-atomic slot
    // payload.  A producer that entered concurrently simply backs out.
    if (atomic_load_explicit(&g_macws_fast_submit_frozen,
                             memory_order_acquire)) {
        atomic_fetch_sub_explicit(&g_macws_fast_submit_active, 1,
                                  memory_order_acq_rel);
        return token;
    }

    token.serial = atomic_fetch_add_explicit(
        &g_macws_fast_submit_serial, 1, memory_order_relaxed) + 1;
    token.life_event_serial = macws_agx_life_current_event_serial();
    token.slot = (unsigned)((token.serial - 1) %
                            MACWS_FAST_SUBMIT_RING_COUNT);
    token.sequence = sequence;
    token.descriptor = descriptor;
    token.descriptor_pointer = descriptor_pointer;
    token.command_buffer = command_buffer;
    token.storage = storage;
    token.active = 1;
    return token;
}

static void macws_fast_submit_finish(
        struct macws_fast_submit_token token, unsigned fixed,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    if (!token.active) return;
    struct macws_fast_submit_entry *entry =
        &g_macws_fast_submit_ring[token.slot];
    uint64_t writing_guard = token.serial * 2 + 1;
    atomic_store_explicit(&entry->guard, writing_guard,
                          memory_order_release);

    entry->life_event_serial = token.life_event_serial;
    entry->sequence = token.sequence;
    entry->descriptor = token.descriptor;
    atomic_store_explicit(&entry->fixed, fixed, memory_order_relaxed);
    entry->descriptor_pointer = token.descriptor_pointer;
    entry->storage = token.storage;
    entry->commands_length = commands_length;
    entry->commands_saved = commands && commands_length
        ? (commands_length < MACWS_FAST_SUBMIT_COMMAND_CAP
            ? commands_length : MACWS_FAST_SUBMIT_COMMAND_CAP) : 0;
    entry->segments_length = segments_length;
    entry->segments_saved = segments && segments_length
        ? (segments_length < MACWS_FAST_SUBMIT_SEGMENT_CAP
            ? segments_length : MACWS_FAST_SUBMIT_SEGMENT_CAP) : 0;
    if (entry->commands_saved)
        memcpy(entry->commands, commands, entry->commands_saved);
    if (entry->segments_saved)
        memcpy(entry->segments, segments, entry->segments_saved);

    atomic_store_explicit(&entry->command_buffer, token.command_buffer,
                          memory_order_relaxed);
    atomic_store_explicit(&entry->serial, token.serial,
                          memory_order_relaxed);
    atomic_store_explicit(&entry->guard, token.serial * 2,
                          memory_order_release);
    atomic_fetch_sub_explicit(&g_macws_fast_submit_active, 1,
                              memory_order_acq_rel);
}

__attribute__((used, visibility("default")))
uint64_t macws_fast_latest_agx_submit_serial(const void *command_buffer) {
    if (!command_buffer || !macws_fast_submit_is_enabled()) return 0;
    uint64_t newest = atomic_load_explicit(
        &g_macws_fast_submit_serial, memory_order_acquire);
    uint64_t oldest = newest > MACWS_FAST_SUBMIT_RING_COUNT
        ? newest - MACWS_FAST_SUBMIT_RING_COUNT + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        struct macws_fast_submit_entry *entry =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        uint64_t guard_before = atomic_load_explicit(
            &entry->guard, memory_order_acquire);
        if (guard_before != serial * 2) continue;
        uint64_t entry_serial = atomic_load_explicit(
            &entry->serial, memory_order_relaxed);
        uintptr_t entry_command_buffer = atomic_load_explicit(
            &entry->command_buffer, memory_order_relaxed);
        uint64_t guard_after = atomic_load_explicit(
            &entry->guard, memory_order_acquire);
        if (guard_before == guard_after && entry_serial == serial &&
            entry_command_buffer == (uintptr_t)command_buffer) {
            return serial;
        }
    }
    return 0;
}

__attribute__((used, visibility("default")))
unsigned macws_fast_agx_submit_fixed_count(uint64_t submit_serial) {
    if (!submit_serial || !macws_fast_submit_is_enabled()) return 0;
    struct macws_fast_submit_entry *entry =
        &g_macws_fast_submit_ring[(submit_serial - 1) %
                                  MACWS_FAST_SUBMIT_RING_COUNT];
    uint64_t guard_before = atomic_load_explicit(
        &entry->guard, memory_order_acquire);
    if (guard_before != submit_serial * 2) return 0;
    unsigned fixed = atomic_load_explicit(&entry->fixed,
                                          memory_order_relaxed);
    uint64_t guard_after = atomic_load_explicit(
        &entry->guard, memory_order_acquire);
    return guard_before == guard_after ? fixed : 0;
}

__attribute__((used, visibility("default")))
void macws_dump_fast_agx_submit_serial(const char *reason,
                                       const void *command_buffer,
                                       uint64_t requested_serial) {
    if (!macws_fast_submit_is_enabled()) return;
    unsigned dump = atomic_fetch_add_explicit(
        &g_macws_fast_submit_dump_count, 1, memory_order_acq_rel) + 1;
    if (dump != 1) return;

    atomic_store_explicit(&g_macws_fast_submit_frozen, 1,
                          memory_order_release);
    unsigned waits = 0;
    while (atomic_load_explicit(&g_macws_fast_submit_active,
                                memory_order_acquire) != 0 && waits < 500) {
        usleep(1000);
        waits++;
    }
    unsigned active = atomic_load_explicit(
        &g_macws_fast_submit_active, memory_order_acquire);
    if (active != 0) {
        fprintf(stderr,
            "#### AGX_FAST_RING freeze timed out reason=%s active=%u "
            "waited_ms=%u; refusing a racy payload dump\n",
            reason ?: "(nil)", active, waits);
        return;
    }

    uint64_t newest = atomic_load_explicit(
        &g_macws_fast_submit_serial, memory_order_acquire);
    uint64_t oldest = newest > MACWS_FAST_SUBMIT_RING_COUNT
        ? newest - MACWS_FAST_SUBMIT_RING_COUNT + 1 : 1;
    uint64_t matched_serial = 0;
    struct macws_fast_submit_entry *matched_entry = NULL;
    if (requested_serial >= oldest && requested_serial <= newest) {
        struct macws_fast_submit_entry *candidate =
            &g_macws_fast_submit_ring[(requested_serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&candidate->serial,
                                 memory_order_relaxed) == requested_serial) {
            matched_serial = requested_serial;
            matched_entry = candidate;
        }
    }
    for (uint64_t serial = newest;
         !matched_entry && serial >= oldest && serial != 0; serial--) {
        struct macws_fast_submit_entry *candidate =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&candidate->serial,
                                 memory_order_relaxed) == serial &&
            atomic_load_explicit(&candidate->command_buffer,
                                 memory_order_relaxed) ==
                (uintptr_t)command_buffer) {
            matched_serial = serial;
            matched_entry = candidate;
            break;
        }
    }

    char directory[PATH_MAX];
    snprintf(directory, sizeof(directory),
             "/tmp/macws_fast_submit_error_%d_%u", getpid(), dump);
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr,
            "#### AGX_FAST_RING dump mkdir failed path=%s errno=%d\n",
            directory, errno);
        return;
    }
    char manifest_path[PATH_MAX];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.txt",
             directory);
    FILE *manifest = fopen(manifest_path, "w");
    if (manifest) {
        fprintf(manifest,
            "reason=%s pid=%d command_buffer=%p requested_serial=%llu "
            "matched_serial=%llu oldest=%llu newest=%llu "
            "freeze_wait_ms=%u\n",
            reason ?: "(nil)", getpid(), command_buffer,
            (unsigned long long)requested_serial,
            (unsigned long long)matched_serial,
            (unsigned long long)oldest, (unsigned long long)newest, waits);
    }

    unsigned entries = 0;
    unsigned byte_entries = 0;
    unsigned same_shape_controls = 0;
    size_t matched_commands_length = matched_entry
        ? matched_entry->commands_length : 0;
    size_t matched_segments_length = matched_entry
        ? matched_entry->segments_length : 0;
    unsigned matched_fixed = matched_entry ? atomic_load_explicit(
        &matched_entry->fixed, memory_order_relaxed) : 0;
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        struct macws_fast_submit_entry *entry =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&entry->serial,
                                 memory_order_relaxed) != serial) continue;
        entries++;
        BOOL exact = serial == matched_serial;
        BOOL same_shape = matched_entry && serial < matched_serial &&
            entry->commands_length == matched_commands_length &&
            entry->segments_length == matched_segments_length &&
            atomic_load_explicit(&entry->fixed, memory_order_relaxed) ==
                matched_fixed && same_shape_controls < 8;
        BOOL recent = serial + 16 > newest;
        BOOL write_bytes = exact || same_shape || recent;
        if (same_shape) same_shape_controls++;
        if (manifest) {
            fprintf(manifest,
                "serial=%llu life_event_serial=%llu sequence=%u "
                "descriptor=%u fixed=%u descriptor_pointer=%#llx "
                "command_buffer=%#llx storage=%#llx matched=%s "
                "same_shape=%s commands=%zu saved=%zu truncated=%s "
                "segments=%zu saved=%zu truncated=%s\n",
                (unsigned long long)serial,
                (unsigned long long)entry->life_event_serial,
                entry->sequence, entry->descriptor,
                atomic_load_explicit(&entry->fixed, memory_order_relaxed),
                (unsigned long long)entry->descriptor_pointer,
                (unsigned long long)atomic_load_explicit(
                    &entry->command_buffer, memory_order_relaxed),
                (unsigned long long)entry->storage,
                exact ? "YES" : "NO", same_shape ? "YES" : "NO",
                entry->commands_length, entry->commands_saved,
                entry->commands_saved < entry->commands_length ? "YES" : "NO",
                entry->segments_length, entry->segments_saved,
                entry->segments_saved < entry->segments_length ? "YES" : "NO");
        }
        if (!write_bytes) continue;
        char path[PATH_MAX];
        if (entry->commands_saved) {
            snprintf(path, sizeof(path), "%s/s%llu_q%u_d%u_post_kcmd.bin",
                directory, (unsigned long long)serial,
                entry->sequence, entry->descriptor);
            macws_submit_ring_write_file(
                path, entry->commands, entry->commands_saved);
        }
        if (entry->segments_saved) {
            snprintf(path, sizeof(path),
                "%s/s%llu_q%u_d%u_post_segments.bin",
                directory, (unsigned long long)serial,
                entry->sequence, entry->descriptor);
            macws_submit_ring_write_file(
                path, entry->segments, entry->segments_saved);
        }
        byte_entries++;
    }
    if (manifest) fclose(manifest);
    macws_agx_life_dump_snapshot(directory,
        matched_entry ? matched_entry->commands : NULL,
        matched_entry ? matched_entry->commands_saved : 0);
    fprintf(stderr,
        "#### AGX_FAST_RING dumped reason=%s commandBuffer=%p "
        "requested=%llu matched=%llu entries=%u byteEntries=%u "
        "range=%llu..%llu path=%s\n",
        reason ?: "(nil)", command_buffer,
        (unsigned long long)requested_serial,
        (unsigned long long)matched_serial, entries, byte_entries,
        (unsigned long long)oldest, (unsigned long long)newest, directory);
}

static uint64_t macws_strip_user_pointer(uint64_t raw) {
    return raw & 0x0000ffffffffffffULL;
}

static int macws_plausible_agx_pointer(uint64_t raw, size_t bytes) {
    uint64_t p = macws_strip_user_pointer(raw);
    // The previous upper bound (0x280000000) happened to cover
    // WindowServer's allocator zones, but it is not an IOGPU ABI boundary.
    // Runtime LLDB capture from VS Code 1.130 / Chromium 148 showed the live
    // selector-0x1e descriptor chain in readable GPU-process regions at
    // 0x601128040 -> command buffer 0x601be1c00 -> storage 0x6001adc00.
    // Rejecting those ordinary 0x600... heap addresses made the existing
    // structurally validated KCMD translator silently skip every Chromium
    // submission.  Keep a bounded process-user range and retain the overflow
    // and per-object size checks; downstream descriptor/self/storage anchors
    // still have to validate before any byte is inspected or translated.
    const uint64_t user_limit = 0x800000000ULL;
    return p >= 0x100000000ULL && p < user_limit &&
        bytes <= 0x10000 && p + bytes >= p && p + bytes <= user_limit;
}

static void macws_submit_hex(const char *what, unsigned sequence,
                             const unsigned char *p, size_t length) {
    fprintf(stderr, "#### AGX_SUBMIT_DIAG #%u %s bytes=%#zx\n",
        sequence, what, length);
    for (size_t off = 0; off < length; off += 32) {
        fprintf(stderr, "####   +%04zx:", off);
        for (size_t j = 0; j < 32 && off + j < length; j++)
            fprintf(stderr, " %02x", p[off + j]);
        fprintf(stderr, "\n");
    }
}

static void macws_submit_save_type1(unsigned sequence, unsigned record,
                                    const unsigned char *p, size_t length) {
    if (!p || length < 0x38 || length > 0x10000) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_type1_%u_%u.bin", sequence, record);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u record[%u] save %s failed errno=%d\n",
            sequence, record, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u record[%u] saved=%#zx/%#zx path=%s errno=%d\n",
        sequence, record, written, length, path,
        written == length ? 0 : saved_errno);
}

static void macws_submit_save_kcmd(unsigned sequence, unsigned descriptor,
                                   const char *phase,
                                   const unsigned char *p, size_t length) {
    if (!phase || !p || length < 0x38 || length > 0x10000) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_kcmd_%u_%u_%s.bin", sequence, descriptor, phase);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD-%s save %s "
            "failed errno=%d\n",
            sequence, descriptor, phase, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD-%s "
        "saved=%#zx/%#zx path=%s errno=%d\n",
        sequence, descriptor, phase, written, length, path,
        written == length ? 0 : saved_errno);
}

static void macws_submit_save_segment_list(unsigned sequence,
                                           unsigned descriptor,
                                           const unsigned char *p,
                                           size_t length) {
    if (!p || length < 0x10 || length > 0x10000) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_segment_%u_%u.bin", sequence, descriptor);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment save %s "
            "failed errno=%d\n",
            sequence, descriptor, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment saved=%#zx/%#zx "
        "path=%s errno=%d\n",
        sequence, descriptor, written, length, path,
        written == length ? 0 : saved_errno);
}

static int macws_submit_bytes_are_zero(const unsigned char *p,
                                       size_t length) {
    for (size_t i = 0; i < length; i++) {
        if (p[i] != 0) return 0;
    }
    return 1;
}

// DIAGNOSTIC-ONLY semantic-field A/B for the macOS-13.4 -> iOS-16.3
// subtype-1 command ABI.  This is deliberately not part of the default KCMD
// normalizer and is not a fix.
//
// Runtime hardware-watchpoint evidence from the exact 1140x798 PF550 control:
//
//   native iOS 16.3 AGX, normalized record+0x3a0:
//     0x221ac9618 ldr w9, [x20, #0xa4]   ; runtime value 4
//     0x221ac961c str w9, [x8]
//
//   macOS 13.4 AGX, original record+0x3b0 (normalized +0x3a0):
//     0x1ee0cf3a4 ldr x9, [x19, #0x570]
//     0x1ee0cf3a8 bfxil x9, x8, #1, #6
//     0x1ee0cf3b4 str x9, [x8, #0x378]   ; runtime value 8
//
// The macOS function has no counterpart to the following native iOS +0xa4
// store.  The experiment tests only whether this one proven producer-version
// delta explains the first multi-segment PageFault.  A positive result still
// requires locating/deriving the native field semantically before shipping.
static void macws_subtype1_field_a4_diagnostic(unsigned sequence,
                                                unsigned segment,
                                                unsigned char *record) {
    if (!record ||
        access("/tmp/macws_kcmd_field_a4_diag", F_OK) != 0)
        return;

    uint32_t old_value = *(uint32_t *)(record + 0x3a0);
    if (old_value != 8)
        return;

    uint32_t width = *(uint32_t *)(record + 0x3b0);
    uint32_t height = *(uint32_t *)(record + 0x3b4);
    *(uint32_t *)(record + 0x3a0) = 4;

    static _Atomic unsigned log_count = 0;
    unsigned observed = atomic_fetch_add(&log_count, 1) + 1;
    if (observed <= 32 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX-KCMD-FIELD-A4-DIAG #%u segment=%u "
            "normalized+0x3a0=%u->4 target=%ux%u observed=%u\n",
            sequence, segment, old_value, width, height, observed);
    }
}

// DIAGNOSTIC-ONLY A/B for two additional subtype-1 semantic fields.  These
// switches test causality; they are not ABI fixes and remain inert unless the
// matching sentinel exists.
//
// normalized record+0x5e3:
//   macOS 13.4 copies byte 8 of q0 from state+0xed0 through [sp+0x80], then
//   stores that byte at original record+0x603 (normalized +0x5e3).  Runtime
//   hardware-watchpoint evidence measured 1.  iOS 16.3 computes the
//   corresponding field from state+0xbc2 and the exact native PF550 control
//   contains zero.
//
// normalized record+0x6bc:
//   Both actual binaries compute state+0xbec identically as
//       (state_word_at_0x178 >> 16) & 0x1ff
//   and copy it into the command record.  Runtime captures measured 16 for
//   macOS and 8 for the exact native 1140x798 PF550 control.  Because this is
//   a real upstream state difference rather than a layout mismatch, forcing
//   it is especially unsuitable for production; the experiment only answers
//   whether that difference participates in the current PageFault.
static void macws_subtype1_semantic_field_diagnostic(
    unsigned sequence, unsigned segment, unsigned char *record) {
    macws_subtype1_field_a4_diagnostic(sequence, segment, record);
    if (!record)
        return;

    BOOL test5e3 =
        access("/tmp/macws_kcmd_field_5e3_diag", F_OK) == 0;
    BOOL test6bc =
        access("/tmp/macws_kcmd_field_6bc_diag", F_OK) == 0;
    unsigned char old5e3 = record[0x5e3];
    uint32_t old6bc = *(uint32_t *)(record + 0x6bc);
    BOOL changed5e3 = test5e3 && old5e3 == 1;
    BOOL changed6bc = test6bc && old6bc == 16;
    if (changed5e3)
        record[0x5e3] = 0;
    if (changed6bc)
        *(uint32_t *)(record + 0x6bc) = 8;
    if (!test5e3 && !test6bc)
        return;

    static _Atomic unsigned log_count = 0;
    unsigned observed = atomic_fetch_add(&log_count, 1) + 1;
    if (observed <= 32 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX-KCMD-SEMANTIC-FIELD-DIAG #%u segment=%u "
            "+0x5e3=%u%s +0x603=%u +0x6bc=%u%s +0x6dc=%u "
            "observed=%u\n",
            sequence, segment, old5e3, changed5e3 ? "->0" : "",
            record[0x603], old6bc, changed6bc ? "->8" : "",
            *(uint32_t *)(record + 0x6dc), observed);
    }
}

// Validated ABI translation for the wrapped single-segment form.  It remains
// behind the explicit /tmp/macws_kcmd_wrapped_fix experimental-mode gate.
//
// Project LLDB stopped at the first non-InnocentVictim IOGPU completion on
// 2026-07-26, before IOGPUMetalCommandBuffer released its storage.  The raw
// callback error was 0x102 and the submitted CoreAnimation command had:
//
//   KCMD 0x868 bytes:
//     +0x00 type=9, span=0x10, count=1       (wrapper)
//     +0x10 type=0x10000, span=0x858         (known subtype-1 segment)
//   segment list 0x148 bytes:
//     +0x08 count=1, +0x0c=0x40000001       (wrapper)
//     +0x14 nested-list offset=0x10
//     +0x20 count=1, +0x24=0x80000130       (known inner list)
//     +0x30 range=[0x10,0x868)
//
// Artifacts `/tmp/macws-raw102-{kcmd,segments}-20260726.bin` have SHA-256
// 486bd31db1f26b541bd40fb2b4b8eba4f33178ac8bb750ebf569646a2ec7fe87
// and 17c887655f3d4c649203f4a23a2182de7f45f716c8409a99ba481dca01887597.
// The old normalizer required the vendor record at KCMD offset zero and a
// top-level 0x130-byte list, so it skipped this command completely.  The first
// A/B normalized the nested record while retaining both wrappers: that
// removed parser error 0x102 but exposed a repeatable ProtectionViolation.
// The 2026-07-29 native-layout A/B below identified the retained macOS wrapper
// as the remaining mismatch and supplied output/completion/input witnesses.
static unsigned macws_translate_agx_wrapped_single_subtype1(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t *segment_length_io) {
    size_t segment_length = segment_length_io ? *segment_length_io : 0;
    if (!commands || !total_io || !segment_list ||
        *total_io != 0x868 || segment_length != 0x148)
        return 0;

    size_t total = *total_io;
    unsigned char *record = commands + 0x10;
    int wrapper_ok =
        *(uint32_t *)(commands + 0x00) == 9 &&
        *(uint32_t *)(commands + 0x04) == 0x10 &&
        *(uint32_t *)(commands + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x0c) == 0x40000001 &&
        *(uint32_t *)(segment_list + 0x14) == 0x10 &&
        *(uint32_t *)(segment_list + 0x20) == 1 &&
        *(uint32_t *)(segment_list + 0x24) == 0x80000130 &&
        *(uint32_t *)(segment_list + 0x30) == 0x10 &&
        *(uint32_t *)(segment_list + 0x34) == total;
    int subtype1_ok =
        *(uint32_t *)(record + 0x00) == 0x10000 &&
        *(uint32_t *)(record + 0x04) == 0x858 &&
        *(uint32_t *)(record + 0x28) == 0x818 &&
        *(uint32_t *)(record + 0x2c) == 0x7e8 &&
        *(uint32_t *)(record + 0x30) == 0x30 &&
        *(uint32_t *)(record + 0x34) == 1 &&
        memcmp(record + 0xd8,
            "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
        macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
        *(uint32_t *)(record + 0x1e0) == 1 &&
        *(uint32_t *)(record + 0x1e8) == 0x1c &&
        memcmp(record + 0x1f8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0 &&
        macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
        *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
        (*(uint32_t *)(record + 0x4d4) == 0x100 ||
         *(uint32_t *)(record + 0x4d4) == 0x300) &&
        memcmp(record + 0x4e8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0;
    if (!wrapper_ok || !subtype1_ok)
        return 0;

    // Delete the same two macOS-only windows proven for the unwrapped form.
    // First move the complete storage tail so no bytes are lost while the two
    // windows overlap; the wrapper-specific 0x18-byte suffix is removed only
    // by the independently validated flattening step below.  Work from the
    // higher original offset downward.
    memmove(record + 0x4c0, record + 0x4d0,
            total - (0x10 + 0x4d0));
    total -= 0x10;
    memmove(record + 0x1c0, record + 0x1d0,
            total - (0x10 + 0x1d0));
    total -= 0x10;
    memset(commands + total, 0, 0x20);

    *(uint32_t *)(record + 0x04) = 0x838;
    *(uint32_t *)(record + 0x28) = 0x7f8;
    *(uint32_t *)(record + 0x2c) = 0x7c8;
    macws_subtype1_semantic_field_diagnostic(sequence, 0, record);

    // The exact iOS-native PF550 control captured with the project LLDB on
    // 2026-07-29 is a direct subtype-1 KCMD of 0x820 bytes and a direct
    // 0x130-byte segment list
    // (SHA-256 b0e11e0d0177749a... / ffb991a1c94f9b4e...).  The failing
    // WindowServer submit has the same normalized record end (0x7f8), but
    // carries a 0x10 type-9 leading wrapper, a 0x18 larger record trailer,
    // and the matching 0x18 segment-list wrapper.  Runtime-confirmed A/B on
    // the actual arm64 WindowServer: retaining the wrappers produced 68
    // ProtectionViolation observations in the first bounded sample;
    // flattening exactly these three framing differences produced zero, then
    // delivered 4,200/4,200 clean PF80 VNC-copy completions, a full Retina
    // Terminal frame, and 16/16 visibly acknowledged keyboard events.  This
    // is protocol translation to the observed iOS-native layout, not an error
    // or completion bypass.
    memmove(commands, record, 0x820);
    memset(commands + 0x820, 0, total - 0x820);
    *(uint32_t *)(commands + 0x04) = 0x820;

    memmove(segment_list, segment_list + 0x18, 0x130);
    memset(segment_list + 0x130, 0, 0x18);
    *(uint32_t *)(segment_list + 0x18) = 0;
    *(uint32_t *)(segment_list + 0x1c) = 0x820;
    *segment_length_io = 0x130;
    total = 0x820;
    *total_io = total;

    // CA_VSYNC_OFF can submit this command continuously while a consumer is
    // connected.  Keep enough witnesses to prove the path remains active,
    // without turning the diagnostic itself into a stderr/CPU storm.
    static unsigned match_count;
    unsigned observed = __atomic_add_fetch(&match_count, 1, __ATOMIC_RELAXED);
    if (observed <= 4 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-WRAPPED-FIX match=%u "
            "type9=0x10 subtype1@0x10 span=0x858->0x838 "
            "range=0x10..0x868->0x848 storage=0x868->0x848 "
            "flatten=iOS-direct final=0x%zx\n",
            sequence, observed, total);
    }
    return 1;
}

// TEMPORARY ABI-TRANSLATION EXPERIMENT for Chromium's trailing-wrapper form.
//
// The raw IOGPU callback correlated VS Code submit serial 2 with
// MTLCommandBufferErrorDomain/1 and internal status 0x102.  Its retained
// pre-submit artifacts (SHA-256 KCMD
// 8df48a8ed24efd35bf27a4623d182214c303d6e983138159b37f58da9a060820,
// segment list
// 6ab4552a490b4eecfc5fca1456d18212deae23be580a9c91f185845d9f82189d)
// have a third framing variant:
//
//   KCMD 0x858 or 0x870 bytes:
//     +0x000 subtype-1 span 0x840 (known macOS record + trailer)
//     +0x840 one or two 0x18-byte type-3 wrapper records
//   segment list (captured sizes 0x148 and 0x188 bytes):
//     +0x008 inner count=1, encoded length=L, range=[0,0x840)
//     +L trailing wrapper, range=[0x840,total)
//
// A later Chromium GPU-process capture (submit serial 18, retained under
// docs/evidence/vscode-trailing-wrapper-fix-20260728-2105) has the exact
// same command framing with L=0x170 instead of 0x130.  The intervening bytes
// are resource-list payload, so validate L and the wrapper record rather than
// assuming one fixed resource count.
//
// The existing direct translator rejected it because the complete KCMD span
// is deliberately larger than the inner subtype-1 range.  Preserve the two
// wrapper records byte-for-byte, normalize only the same two RE-confirmed
// macOS-only subtype-1 padding windows, then shift both exact ranges.  This is
// diagnostic scaffolding under /tmp/macws_kcmd_wrapped_fix, not a claim that
// type-3 wrapper semantics have been fully reconstructed.
static unsigned macws_translate_agx_trailing_wrapped_subtype1(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t segment_length) {
    if (!commands || !total_io || !segment_list ||
        (*total_io != 0x858 && *total_io != 0x870) ||
        segment_length < 0x38)
        return 0;

    size_t total = *total_io;
    unsigned char *record = commands;
    uint32_t list_magic = *(uint32_t *)(segment_list + 0x00);
    uint32_t encoded_length = *(uint32_t *)(segment_list + 0x0c);
    if (encoded_length < 0x20 ||
        (size_t)encoded_length + 0x18 != segment_length)
        return 0;
    unsigned char *wrapper_list = segment_list + encoded_length;
    uint32_t wrapper_opcode = *(uint32_t *)(commands + 0x848);
    uint32_t list_generation = *(uint32_t *)(segment_list + 0x04);
    unsigned wrapper_count = (unsigned)((total - 0x840) / 0x18);
    int wrapper_records_ok = wrapper_count >= 1 && wrapper_count <= 2;
    for (unsigned i = 0; wrapper_records_ok && i < wrapper_count; i++) {
        size_t offset = 0x840 + (size_t)i * 0x18;
        wrapper_records_ok =
            *(uint32_t *)(commands + offset + 0x00) == 3 &&
            *(uint32_t *)(commands + offset + 0x04) == 0x18 &&
            *(uint32_t *)(commands + offset + 0x08) == wrapper_opcode;
    }
    int wrapper_ok =
        *(uint32_t *)(segment_list + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x18) == 0 &&
        *(uint32_t *)(segment_list + 0x1c) == 0x840 &&
        *(uint32_t *)(wrapper_list + 0x00) == list_magic &&
        // Runtime-confirmed 2026-07-29 from the exact first failing VS Code
        // submit after a clean restart (KCMD SHA-256 bf14ff937dcf789a...;
        // segment SHA-256 c4ba7fbea0b64f21...).  This dword is not a fixed
        // wrapper type: both the outer list and its trailing record changed
        // together from 2 in every earlier capture to 3 in this capture.
        // The remaining framing stayed identical and the actual blob was
        // 0x148 bytes while list+0x0c remained the base-list offset 0x130.
        // Validate the observed generation relationship rather than forcing
        // the historical value.  Keep the known 2/3 bound so an unrelated
        // list layout cannot enter this temporary translator.
        (list_generation == 2 || list_generation == 3) &&
        *(uint32_t *)(wrapper_list + 0x04) == list_generation &&
        *(uint32_t *)(wrapper_list + 0x08) == 1 &&
        *(uint32_t *)(wrapper_list + 0x0c) == 0xc0000001 &&
        *(uint32_t *)(wrapper_list + 0x10) == 0x840 &&
        *(uint32_t *)(wrapper_list + 0x14) == total &&
        wrapper_opcode < 0x10000 &&
        wrapper_records_ok;
    int subtype1_ok =
        *(uint32_t *)(record + 0x00) == 0x10000 &&
        *(uint32_t *)(record + 0x04) == 0x840 &&
        *(uint32_t *)(record + 0x28) == 0x818 &&
        *(uint32_t *)(record + 0x2c) == 0x7e8 &&
        *(uint32_t *)(record + 0x30) == 0x30 &&
        *(uint32_t *)(record + 0x34) == 1 &&
        memcmp(record + 0xd8,
            "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
        macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
        *(uint32_t *)(record + 0x1e0) == 1 &&
        *(uint32_t *)(record + 0x1e8) == 0x1c &&
        memcmp(record + 0x1f8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0 &&
        macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
        *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
        (*(uint32_t *)(record + 0x4d4) == 0x100 ||
         *(uint32_t *)(record + 0x4d4) == 0x300) &&
        memcmp(record + 0x4e8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0;
    if (!wrapper_ok || !subtype1_ok)
        return 0;

    // Delete from high to low so offsets still refer to the captured macOS
    // record. Both moves include the complete 0x30-byte wrapper tail.
    memmove(record + 0x4c0, record + 0x4d0, total - 0x4d0);
    total -= 0x10;
    memmove(record + 0x1c0, record + 0x1d0, total - 0x1d0);
    total -= 0x10;
    memset(commands + total, 0, 0x20);

    *(uint32_t *)(record + 0x04) = 0x820;
    *(uint32_t *)(record + 0x28) = 0x7f8;
    *(uint32_t *)(record + 0x2c) = 0x7c8;
    macws_subtype1_semantic_field_diagnostic(sequence, 0, record);
    *(uint32_t *)(segment_list + 0x1c) = 0x820;
    *(uint32_t *)(wrapper_list + 0x10) = 0x820;
    *(uint32_t *)(wrapper_list + 0x14) = (uint32_t)total;
    *total_io = total;

    static _Atomic unsigned match_count = 0;
    unsigned observed = atomic_fetch_add(&match_count, 1) + 1;
    if (observed <= 8 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-TRAILING-WRAPPER-FIX "
            "match=%u subtype1=0..0x840->0..0x820 "
            "wrappers=%u range=0x840..%#zx->0x820..%#zx\n",
            sequence, observed, wrapper_count, total + 0x20, total);
    }
    return 1;
}

// TEMPORARY ABI-TRANSLATION EXPERIMENT for a storage object containing more
// than one segment.  Runtime capture of WindowServer submit #9 established
// the segment-list framing on this exact iOS 16.3 device:
//
//   list+0x08 = segment count
//   list+0x0c = 0x80000000 | list byte length
//   every KCMD segment starts with type 0x10000 and carries its complete
//   segment span (vendor record plus trailer) at segment+0x04
//   the segment list contains one aligned {start,end} u32 pair per KCMD
//
// The captured two-segment list had ranges [0,0x858) and
// [0x858,0x10b0), and the KCMD storage contained a subtype-1 record at both
// exact starts.  The old linear walker stopped on the first record's trailer,
// so neither segment was translated and the command buffer completed with
// kernel parser error 0x102.  Validate the complete range table before
// changing anything, then work backwards so deleting 0x20 bytes from a later
// segment cannot invalidate an earlier segment's original coordinates.
//
// A later 28-segment compositor capture disproved the initial THEORY that
// every segment-list entry has a fixed 0x120 stride: resource-list payloads
// make the entries variable-sized.  Its header count was 28, the KCMD chain
// contained exactly 28 records, and each derived KCMD range occurred exactly
// once as an 8-byte-aligned {start,end} pair in the actual segment list.
// Use those cross-buffer invariants instead of assuming a C struct stride.
//
// This remains a diagnostic scaffold.  It deliberately handles only the
// already-observed subtype-1 and subtype-3 macOS layouts and is still gated
// by /tmp/macws_kcmd_fix at the caller.
static unsigned macws_translate_agx_multisegment_subtype1(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t segment_length) {
    if (!commands || !total_io || !segment_list || segment_length < 0x20)
        return 0;

    size_t total = *total_io;
    uint32_t count = *(uint32_t *)(segment_list + 0x08);
    uint32_t encoded_length = *(uint32_t *)(segment_list + 0x0c);
    BOOL direct_list =
        encoded_length == (0x80000000U | (uint32_t)segment_length);
    // Chromium also emits the same trailing type-3 wrapper already captured
    // for a single subtype-1 segment, but after a variable-length list of two
    // or more vendor segments.  In that framing list+0x0c is the byte offset
    // of a final 0x18-byte wrapper-list record, not the high-bit-tagged total
    // list size.  Exact runtime witnesses:
    //   error 0x102 serial 12: KCMD 0x1098, list 0x2a8, base list 0x290
    //   error 0x0a  serial 13: KCMD 0x0a68, list 0x268, base list 0x250
    BOOL trailing_wrapper_list =
        encoded_length >= 0x20 &&
        (size_t)encoded_length + 0x18 == segment_length;
    if (count < 2 || count > 64 ||
        (!direct_list && !trailing_wrapper_list))
        return 0;

    uint32_t pair_offsets[64] = {0};
    uint32_t cursor = 0;
    for (uint32_t i = 0; i < count; i++) {
        if ((size_t)cursor + 0x38 > total)
            return 0;
        unsigned char *record = commands + cursor;
        uint32_t type = *(uint32_t *)(record + 0x00);
        uint32_t span = *(uint32_t *)(record + 0x04);
        if ((type != 0x10000 && type != 0x10001) || span < 0x38 ||
            span > 0x2000 || (size_t)cursor + span > total)
            return 0;
        uint32_t end = cursor + span;

        unsigned matches = 0;
        for (size_t off = 0; off + 8 <= segment_length; off += 8) {
            if (*(uint32_t *)(segment_list + off) == cursor &&
                *(uint32_t *)(segment_list + off + 4) == end) {
                pair_offsets[i] = (uint32_t)off;
                matches++;
            }
        }
        if (matches != 1)
            return 0;
        cursor = end;
    }
    uint32_t wrapper_pair_offset = UINT32_MAX;
    if (direct_list) {
        if (cursor != total)
            return 0;
    } else {
        if (cursor > total)
            return 0;
        size_t wrapper_bytes = total - cursor;
        if (wrapper_bytes != 0x18 && wrapper_bytes != 0x30) {
            return 0;
        }
        unsigned wrapper_count = (unsigned)(wrapper_bytes / 0x18);
        uint32_t wrapper_opcode =
            *(uint32_t *)(commands + cursor + 0x08);
        // The wrapper record type is the dword at +0x00 (3); the opaque
        // operation token at +0x08 is not another type tag.  Chromium 148
        // Fish Tank runtime-captured two otherwise valid, identical wrapper
        // records with token 0x9207.  The former low-byte==3 requirement
        // rejected that list, after which the single-record fallback shifted
        // KCMD bytes without its multi-segment ranges and produced error 0x0a.
        BOOL wrapper_commands_ok = wrapper_opcode < 0x10000;
        for (unsigned i = 0; wrapper_commands_ok && i < wrapper_count; i++) {
            size_t offset = cursor + (size_t)i * 0x18;
            wrapper_commands_ok =
                *(uint32_t *)(commands + offset + 0x00) == 3 &&
                *(uint32_t *)(commands + offset + 0x04) == 0x18 &&
                *(uint32_t *)(commands + offset + 0x08) == wrapper_opcode;
        }
        unsigned char *wrapper_list = segment_list + encoded_length;
        uint32_t list_magic = *(uint32_t *)(segment_list + 0x00);
        uint32_t list_generation = *(uint32_t *)(segment_list + 0x04);
        BOOL wrapper_list_ok =
            *(uint32_t *)(wrapper_list + 0x00) == list_magic &&
            (list_generation == 2 || list_generation == 3) &&
            *(uint32_t *)(wrapper_list + 0x04) == list_generation &&
            *(uint32_t *)(wrapper_list + 0x08) == 1 &&
            *(uint32_t *)(wrapper_list + 0x0c) == 0xc0000001 &&
            *(uint32_t *)(wrapper_list + 0x10) == cursor &&
            *(uint32_t *)(wrapper_list + 0x14) == total;
        if (!wrapper_commands_ok || !wrapper_list_ok)
            return 0;
        wrapper_pair_offset = encoded_length + 0x10;
    }

    int log_segments = atomic_fetch_add(
        &g_macws_multisegment_log_batches, 1) < 4;

    unsigned fixed = 0;
    for (uint32_t reverse = count; reverse > 0; reverse--) {
        uint32_t i = reverse - 1;
        unsigned char *range = segment_list + pair_offsets[i];
        uint32_t start = *(uint32_t *)(range + 0x00);
        uint32_t end = *(uint32_t *)(range + 0x04);
        size_t span = (size_t)end - start;
        unsigned char *record = commands + start;

        int subtype1 = span >= 0x818 &&
            *(uint32_t *)(record + 0x00) == 0x10000 &&
            *(uint32_t *)(record + 0x04) == span &&
            *(uint32_t *)(record + 0x28) == 0x818 &&
            *(uint32_t *)(record + 0x2c) == 0x7e8 &&
            *(uint32_t *)(record + 0x30) == 0x30 &&
            *(uint32_t *)(record + 0x34) == 1;
        int subtype1_anchors = subtype1 && span <= 0x1000 &&
            memcmp(record + 0xd8,
                "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
            macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
            *(uint32_t *)(record + 0x1e0) == 1 &&
            *(uint32_t *)(record + 0x1e8) == 0x1c &&
            memcmp(record + 0x1f8,
                "\xff\xff\xff\xff\xff\xff\xff\xff"
                "\xff\xff\xff\xff", 12) == 0 &&
            macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
            *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
            (*(uint32_t *)(record + 0x4d4) == 0x100 ||
             *(uint32_t *)(record + 0x4d4) == 0x300) &&
            memcmp(record + 0x4e8,
                "\xff\xff\xff\xff\xff\xff\xff\xff"
                "\xff\xff\xff\xff", 12) == 0;

        static const unsigned char subtype3_sentinel[12] = {
            0x01, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff
        };
        int subtype3_anchors = span >= 0x1e8 && span <= 0x800 &&
            *(uint32_t *)(record + 0x00) == 0x10000 &&
            *(uint32_t *)(record + 0x04) == span &&
            *(uint32_t *)(record + 0x28) == 0x1e8 &&
            *(uint32_t *)(record + 0x2c) == 0x1b8 &&
            *(uint32_t *)(record + 0x30) == 0x30 &&
            *(uint32_t *)(record + 0x34) == 3 &&
            macws_submit_bytes_are_zero(record + 0x1cc, 0x10) &&
            memcmp(record + 0x1dc, subtype3_sentinel,
                   sizeof(subtype3_sentinel)) == 0;
        if (!subtype1_anchors && !subtype3_anchors)
            continue;

        uint32_t shrink = subtype1_anchors ? 0x20 : 0x10;
        if (subtype1_anchors) {
            // Delete both macOS-only zero windows from the complete remaining
            // storage tail.  Later segments have already been normalized and
            // are intentionally shifted together with that tail.
            memmove(record + 0x4c0, record + 0x4d0,
                    total - ((size_t)start + 0x4d0));
            total -= 0x10;
            memmove(record + 0x1c0, record + 0x1d0,
                    total - ((size_t)start + 0x1d0));
            total -= 0x10;
            *(uint32_t *)(record + 0x28) = 0x7f8;
            *(uint32_t *)(record + 0x2c) = 0x7c8;
            macws_subtype1_semantic_field_diagnostic(sequence, i, record);
        } else {
            memmove(record + 0x1cc, record + 0x1dc,
                    total - ((size_t)start + 0x1dc));
            total -= 0x10;
            *(uint32_t *)(record + 0x28) = 0x1d8;
            *(uint32_t *)(record + 0x2c) = 0x1a8;
        }
        memset(commands + total, 0, shrink);
        *(uint32_t *)(record + 0x04) = (uint32_t)(span - shrink);

        // This segment's end and every later segment's start/end are offsets
        // into the same compacted KCMD storage.
        *(uint32_t *)(range + 0x04) = end - shrink;
        for (uint32_t later = i + 1; later < count; later++) {
            unsigned char *later_range =
                segment_list + pair_offsets[later];
            *(uint32_t *)(later_range + 0x00) -= shrink;
            *(uint32_t *)(later_range + 0x04) -= shrink;
        }
        if (wrapper_pair_offset != UINT32_MAX) {
            unsigned char *wrapper_range =
                segment_list + wrapper_pair_offset;
            *(uint32_t *)(wrapper_range + 0x00) -= shrink;
            *(uint32_t *)(wrapper_range + 0x04) -= shrink;
        }
        fixed++;
        if (log_segments) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-MULTISEG-FIX "
                "segment=%u/%u subtype=%u range=%#x..%#x->%#x "
                "shrink=%#x storage=%#zx wrappedTail=%s\n",
                sequence, i, count, subtype1_anchors ? 1 : 3,
                start, end, end - shrink, shrink, total,
                wrapper_pair_offset == UINT32_MAX ? "NO" : "YES");
    }

    *total_io = total;
    return fixed;
}

static struct macws_submit_diag_result
macws_inspect_agx_submit(const uint64_t *in, uint32_t inCnt,
                         const void *inStruct, size_t inStructCnt,
                         int allow_fix, int verbose_requested) {
    struct macws_submit_diag_result result = {0};
    result.sequence = atomic_fetch_add(&g_macws_submit_diag_sequence, 1) + 1;
    if (!inStruct || inStructCnt < 0x20)
        return result;

    // Keep the expensive byte dumps bounded, but never let that diagnostic
    // limit disable an explicitly requested ABI translation.  The previous
    // `sequence > 8` early return meant WindowServer's later command buffers
    // silently skipped TEMP-KCMD-ABI-FIX altogether.  Runtime witness:
    // `VNC-FINAL clear-control` then completed with MTL internal error 0x102.
    int verbose = verbose_requested && result.sequence <= 8;

    const unsigned char *submit = (const unsigned char *)inStruct;
    if (verbose) {
        size_t submit_dump = inStructCnt < 0x40 ? inStructCnt : 0x40;
        macws_submit_hex("submit-struct", result.sequence, submit, submit_dump);
        fprintf(stderr, "#### AGX_SUBMIT_DIAG #%u scalars[%u]:",
            result.sequence, inCnt);
        for (uint32_t i = 0; in && i < inCnt && i < 8; i++)
            fprintf(stderr, " %#llx", (unsigned long long)in[i]);
        fprintf(stderr, " fix-requested=%s\n", allow_fix ? "YES" : "NO");
    }

    // IOGPUMetalDevice::cmdBufArgsSize returns 0x38 on this exact image, and
    // runtime selector-0x1e captures show inStructCnt=56/112/224 for batches
    // of 1/2/4 command buffers.  The previous parser inspected only offsets
    // +0x10/+0x18 of the first 0x38-byte entry.  Chromium's first 0x102
    // completion witnesses consequently had submitSerial=0 while another
    // command buffer from the same batch was present in the flight recorder.
    // Walk every complete args entry; the queue splits batches at 32 in
    // -[IOGPUMetalCommandQueue submitCommandBuffers:count:].
    const size_t command_buffer_args_size = 0x38;
    size_t submit_entry_count = inStructCnt / command_buffer_args_size;
    if (submit_entry_count == 0 ||
        inStructCnt % command_buffer_args_size != 0) {
        submit_entry_count = 1;
    }
    if (submit_entry_count > 32) submit_entry_count = 32;
    uint64_t seen_state[64] = {0};
    unsigned seen_state_count = 0;
    if (verbose) fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u argsSize=%#zx submitEntries=%zu\n",
            result.sequence, inStructCnt, submit_entry_count);
    for (size_t submit_entry = 0; submit_entry < submit_entry_count;
         submit_entry++) {
        const unsigned char *entry =
            submit + submit_entry * command_buffer_args_size;
        uint64_t descriptor_raw[2] = {
            *(const uint64_t *)(entry + 0x10),
            *(const uint64_t *)(entry + 0x18)
        };
        for (unsigned descriptor_slot = 0; descriptor_slot < 2;
             descriptor_slot++) {
        unsigned descriptor_index =
            (unsigned)(submit_entry * 2 + descriptor_slot);
        uint64_t descriptor = macws_strip_user_pointer(
            descriptor_raw[descriptor_slot]);
        if (!macws_plausible_agx_pointer(descriptor_raw[descriptor_slot],
                                          0x28)) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u]=%#llx invalid\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)descriptor_raw[descriptor_slot]);
            continue;
        }

        const unsigned char *descriptor_bytes =
            (const unsigned char *)(uintptr_t)descriptor;
        uint64_t self_raw = *(const uint64_t *)(descriptor_bytes + 0x20);
        uint64_t self = macws_strip_user_pointer(self_raw);
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u]=%#llx raw=%#llx "
                "self=%#llx rawSelf=%#llx\n",
                result.sequence, descriptor_index,
                (unsigned long long)descriptor,
                (unsigned long long)descriptor_raw[descriptor_slot],
                (unsigned long long)self, (unsigned long long)self_raw);
        if (!macws_plausible_agx_pointer(self_raw, 0x258))
            continue;

        uint64_t state_raw = *(const uint64_t *)(uintptr_t)(self + 0x250);
        uint64_t state = macws_strip_user_pointer(state_raw);
        if (!macws_plausible_agx_pointer(state_raw, 0x348)) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx invalid\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)state_raw);
            continue;
        }
        BOOL duplicate_state = NO;
        for (unsigned seen = 0; seen < seen_state_count; seen++) {
            if (seen_state[seen] == state) {
                duplicate_state = YES;
                break;
            }
        }
        if (duplicate_state) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx duplicate\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)state);
            continue;
        }
        if (seen_state_count < sizeof(seen_state) / sizeof(seen_state[0]))
            seen_state[seen_state_count++] = state;

        // RE-confirmed via the iOS 16.3 IOGPU implementations of
        // IOGPUMetalCommandBufferStorageCreateExt and
        // IOGPUMetalCommandBufferStorageFinalizeShmemHeader: +0x68 is the
        // segment/resource-list mapping base, +0x70 its limit, +0x328 the
        // finalized logical end, and +0x340 the active-header mode.  The
        // kernel's process_command_buffer parser writes submission error
        // 0x0a when this variable-length list fails its framing checks.  Dump
        // it read-only so native iOS and chroot layouts can be compared.
        uint64_t segment_start_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x68);
        uint64_t segment_limit_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x70);
        uint64_t segment_current_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x328);
        uint64_t segment_start = macws_strip_user_pointer(segment_start_raw);
        uint64_t segment_limit = macws_strip_user_pointer(segment_limit_raw);
        uint64_t segment_current =
            macws_strip_user_pointer(segment_current_raw);
        int32_t segment_mode =
            *(const int32_t *)(uintptr_t)(state + 0x340);
        size_t segment_length = 0;
        if (macws_plausible_agx_pointer(segment_start_raw, 1) &&
            segment_current >= segment_start &&
            segment_current <= segment_limit &&
            segment_current - segment_start <= 0x10000) {
            segment_length = (size_t)(segment_current - segment_start);
        }
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment "
                "start=%#llx current=%#llx limit=%#llx length=%#zx mode=%d\n",
                result.sequence, descriptor_index,
                (unsigned long long)segment_start,
                (unsigned long long)segment_current,
                (unsigned long long)segment_limit, segment_length, segment_mode);
        if (verbose && segment_length >= 0x10) {
            macws_submit_hex("segment-list", result.sequence,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length < 0x300 ? segment_length : 0x300);
            macws_submit_save_segment_list(result.sequence, descriptor_index,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
        }

        uint64_t start_raw = *(const uint64_t *)(uintptr_t)(state + 0x28);
        uint64_t current_raw = *(const uint64_t *)(uintptr_t)(state + 0x30);
        uint64_t end_raw = *(const uint64_t *)(uintptr_t)(state + 0x38);
        uint64_t start = macws_strip_user_pointer(start_raw);
        uint64_t current = macws_strip_user_pointer(current_raw);
        uint64_t end = macws_strip_user_pointer(end_raw);
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx "
                "start=%#llx current=%#llx end=%#llx\n",
                result.sequence, descriptor_index,
                (unsigned long long)state, (unsigned long long)start,
                (unsigned long long)current, (unsigned long long)end);
        if (!macws_plausible_agx_pointer(start_raw, 1) ||
            current <= start || current - start > 0x10000 || end < current) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD bounds invalid\n",
                    result.sequence, descriptor_index);
            continue;
        }

        unsigned char *commands = (unsigned char *)(uintptr_t)start;
        size_t total = (size_t)(current - start);
        unsigned fixed_before_descriptor = result.fixed;
        struct macws_fast_submit_token fast_ring_token =
            macws_fast_submit_begin(result.sequence, descriptor_index,
                (uintptr_t)descriptor, (uintptr_t)self, (uintptr_t)state);
        struct macws_submit_ring_token ring_token =
            macws_submit_ring_begin(result.sequence, descriptor_index,
                (uintptr_t)descriptor, (uintptr_t)self, (uintptr_t)state,
                commands, total,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
        size_t dump_length = total < 0x300 ? total : 0x300;
        if (verbose) macws_submit_hex("kernel-commands", result.sequence,
                                      commands, dump_length);
        // Read-only evidence capture.  The existing type-1 dump stops at the
        // AGX record's end_offset and therefore omits the 0x28-byte trailer
        // that follows the clear record.  iOS IOGPU parses that trailer after
        // the vendor command, so preserve the complete storage range before
        // any temporary ABI translation.
        if (verbose) macws_submit_save_kcmd(result.sequence, descriptor_index,
                                            "pre", commands, total);

        if (allow_fix && segment_length >= 0x38 &&
            access("/tmp/macws_kcmd_wrapped_fix", F_OK) == 0) {
            unsigned wrapped_fixed =
                macws_translate_agx_wrapped_single_subtype1(
                    result.sequence, commands, &total,
                    (unsigned char *)(uintptr_t)segment_start,
                    &segment_length);
            if (!wrapped_fixed) {
                wrapped_fixed =
                    macws_translate_agx_trailing_wrapped_subtype1(
                        result.sequence, commands, &total,
                        (unsigned char *)(uintptr_t)segment_start,
                        segment_length);
            }
            if (wrapped_fixed) {
                result.candidates += wrapped_fixed;
                result.fixed += wrapped_fixed;
                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                // Runtime-confirmed by the first clean-log VS Code-triggered
                // WindowServer 0x100 flight record (PID 17741, submit 1): the
                // leading-wrapper translator produced the native 0x820 KCMD
                // and moved the direct list bytes to a 0x130 layout, but the
                // finalized logical list end at state+0x328 still made the
                // submitted span 0x148.  The captured list consequently had
                // header length 0x80000130 inside an actual 0x148-byte span.
                // Keep the RE-confirmed IOGPU storage logical-end field in
                // lockstep with the list bytes, just as state+0x30 is updated
                // for the shortened KCMD above.
                uint64_t new_segment_current =
                    segment_start + segment_length;
                uint64_t new_segment_current_raw =
                    (segment_current_raw & 0xffff000000000000ULL) |
                    new_segment_current;
                *(uint64_t *)(uintptr_t)(state + 0x328) =
                    new_segment_current_raw;
                segment_current_raw = new_segment_current_raw;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index,
                    "wrapped-post", commands, total);
            }
        }

        if (allow_fix && segment_length >= 0x20) {
            unsigned multisegment_fixed =
                macws_translate_agx_multisegment_subtype1(
                    result.sequence, commands, &total,
                    (unsigned char *)(uintptr_t)segment_start,
                    segment_length);
            if (multisegment_fixed) {
                result.candidates += multisegment_fixed;
                result.fixed += multisegment_fixed;
                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index,
                    "multisegment-post", commands, total);
            }
        }

        BOOL single_direct_segment = segment_length >= 0x20 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                (0x80000000U | (uint32_t)segment_length) &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total;
        size_t off = 0;
        unsigned walked = 0;
        while (off + 0x38 <= total && walked++ < 16) {
            uint32_t type = *(uint32_t *)(commands + off);
            uint32_t end_offset = *(uint32_t *)(commands + off + 0x28);
            uint32_t size = *(uint32_t *)(commands + off + 0x2c);
            uint32_t inner = *(uint32_t *)(commands + off + 0x30);
            uint32_t subtype = *(uint32_t *)(commands + off + 0x34);
            unsigned record_index = result.records;
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u record[%u] off=%#zx type=%#x "
                    "end=%#x size=%#x inner=%#x subtype=%u\n",
                    result.sequence, record_index, off, type, end_offset,
                    size, inner, subtype);
            result.records++;

            if ((type != 0x10000 && type != 0x10001) ||
                end_offset < 0x38 || end_offset > total - off) {
                if (verbose) fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u record walk stopped: invalid framing\n",
                        result.sequence);
                break;
            }

            if (verbose && inner == 0x30 && subtype == 1)
                macws_submit_save_type1(result.sequence, record_index,
                                        commands + off, end_offset);

            // TEMPORARY ABI-TRANSLATION EXPERIMENT — native-iOS clear only.
            //
            // Runtime captures on this exact iPad/iOS 16.3 combination show:
            //
            //   iOS AGX clear:   total=0x820, end=0x7f8, size=0x7c8
            //   macOS AGX clear: total=0x840, end=0x818, size=0x7e8
            //
            // A byte alignment of the complete records found two independent
            // 0x10 all-zero insertions in the macOS layout.  Removing the
            // windows at original record offsets 0x1c0 and 0x4c0 and fixing
            // the three size fields makes the header byte-identical and 2005
            // of 2040 record bytes (98.28%) identical to the native capture.
            // The native reference was rerun at the exact same 2388x1668
            // dimensions, so there is no dimension mismatch.  The remaining
            // 35 differing bytes form runtime-varying GPU virtual addresses,
            // resource/segment identifiers, plus one opaque 32-bit token at
            // +0x610.  This classification is descriptive only; it is not
            // evidence that every remaining value is semantically valid.
            //
            // RE-confirmed against iPad13,6 com.apple.AGXG13G 227.2.43:
            // processRender treats record+0x38 as its payload and reads
            // payload+0x19c/+0x1a8/+0x1ae/+0x6a8.  All four windows become
            // byte-identical to native iOS after this normalization.
            //
            // Keep the gate deliberately narrower than the generic subtype-1
            // shape.  Runtime captures identify scalar[0]==3 for the VNC
            // clear-only control and scalar[0]==1 for agxprobe stage 5's
            // isolated IOSurface clear.  The enclosed record is the same
            // 0x818-byte subtype-1 macOS layout in every capture, but its
            // complete command-storage span and resource-list length vary
            // with the opaque trailer/resource count.  In particular, the
            // first exactly correlated WindowServer error (submit serial 194,
            // MTL error 00000102) was storage=0x870 and list=0x1f0.  Its list
            // still had the RE-confirmed one-segment framing: count=1,
            // encoded byte length, and range [0,total) at +0x18.  Validate
            // those invariants instead of hard-coding the resource count.
            // This remains a diagnostic ABI experiment, not a semantic
            // translation of scalar[0] or of the opaque trailer.
            if (off == 0 && type == 0x10000 && inner == 0x30 &&
                subtype == 1 && size == 0x7e8 && end_offset == 0x818 &&
                total >= 0x818 && segment_length >= 0x20) {
                uint64_t observed_scalar0 = in && inCnt >= 1
                    ? in[0] : UINT64_MAX;
                int check_scalar = in && inCnt >= 1 &&
                    (in[0] == 1 || in[0] == 3);
                int check_total = total >= 0x818 && total <= 0x1000;
                int check_segment_length = segment_length >= 0x20 &&
                    segment_length <= 0x10000;
                int check_segment_header =
                    *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                        (0x80000000U | (uint32_t)segment_length) &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total;
                int check_command_total =
                    *(uint32_t *)(commands + 0x04) == total;
                int check_d8 = memcmp(commands + 0xd8,
                    "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0;
                int check_pad_1 =
                    macws_submit_bytes_are_zero(commands + 0x1c0, 0x10);
                int check_1e0 = *(uint32_t *)(commands + 0x1e0) == 1 &&
                    *(uint32_t *)(commands + 0x1e8) == 0x1c;
                int check_1f8 = memcmp(commands + 0x1f8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0;
                int check_pad_2 =
                    macws_submit_bytes_are_zero(commands + 0x4c0, 0x10);
                // Runtime captures show the same ABI padding around two
                // legitimate operation-state values: 0x300 for a clear and
                // 0x100 for a textured draw/detile.  Preserve the value; it
                // is an operation field, not part of the layout delta.
                uint32_t operation_state =
                    *(uint32_t *)(commands + 0x4d4);
                int check_4d0 =
                    *(uint32_t *)(commands + 0x4d0) == 0x3f800000 &&
                    (operation_state == 0x100 || operation_state == 0x300);
                int check_4e8 = memcmp(commands + 0x4e8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0;
                static _Atomic unsigned subtype1_observed_count = 0;
                unsigned subtype1_observed = atomic_fetch_add(
                    &subtype1_observed_count, 1) + 1;
                if (subtype1_observed <= 8) {
                    fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u subtype1-predicate "
                        "scalar0=%#llx legacy-scalar-gate=%d "
                        "total=%#zx/%d seglen=%#zx/%d "
                        "seghdr=%d cmdtotal=%d d8=%d pad1=%d f1=%d "
                        "sent1=%d pad2=%d f2=%d sent2=%d\n",
                        result.sequence,
                        (unsigned long long)observed_scalar0, check_scalar,
                        total, check_total,
                        segment_length, check_segment_length,
                        check_segment_header, check_command_total, check_d8,
                        check_pad_1, check_1e0, check_1f8, check_pad_2,
                        check_4d0, check_4e8);
                    if (!verbose) {
                        macws_submit_save_kcmd(result.sequence,
                            descriptor_index, "type1-observed", commands, total);
                        macws_submit_save_segment_list(result.sequence,
                            descriptor_index,
                            (const unsigned char *)(uintptr_t)segment_start,
                            segment_length);
                    }
                }
            }
            // scalar[0] deliberately does not participate in this gate.  It
            // is outside the vendor record being translated, is not modified,
            // and runtime-confirmed values differ between otherwise
            // byte-identical stage-5 and WindowServer clear records.  Treating
            // {1,3} as a semantic requirement was an unsupported diagnostic
            // restriction; the parser-facing record and segment invariants
            // below remain mandatory.
            if (allow_fix && off == 0 &&
                type == 0x10000 && inner == 0x30 && subtype == 1 &&
                size == 0x7e8 && end_offset == 0x818 &&
                total >= 0x818 && total <= 0x1000 &&
                segment_length >= 0x20 && segment_length <= 0x10000 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                    (0x80000000U | (uint32_t)segment_length) &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total &&
                *(uint32_t *)(commands + 0x04) == total &&
                memcmp(commands + 0xd8,
                    "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
                macws_submit_bytes_are_zero(commands + 0x1c0, 0x10) &&
                *(uint32_t *)(commands + 0x1e0) == 1 &&
                *(uint32_t *)(commands + 0x1e8) == 0x1c &&
                memcmp(commands + 0x1f8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0 &&
                macws_submit_bytes_are_zero(commands + 0x4c0, 0x10) &&
                *(uint32_t *)(commands + 0x4d0) == 0x3f800000 &&
                (*(uint32_t *)(commands + 0x4d4) == 0x100 ||
                 *(uint32_t *)(commands + 0x4d4) == 0x300) &&
                memcmp(commands + 0x4e8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0) {
                result.candidates++;
                size_t original_total = total;

                // Work from the higher original offset downward so both
                // deletion coordinates continue to refer to the captured
                // macOS record.  Move the complete submit tail as well: the
                // native command has a 0x28-byte trailer after record end.
                memmove(commands + 0x4c0, commands + 0x4d0,
                        total - 0x4d0);
                total -= 0x10;
                memmove(commands + 0x1c0, commands + 0x1d0,
                        total - 0x1d0);
                total -= 0x10;
                memset(commands + total, 0, 0x20);

                *(uint32_t *)(commands + 0x04) = (uint32_t)total;
                *(uint32_t *)(commands + 0x28) = 0x7f8;
                *(uint32_t *)(commands + 0x2c) = 0x7c8;
                macws_subtype1_semantic_field_diagnostic(
                    result.sequence, 0, commands);

                // IOGPUMetalCommandBufferStorageEndSegment writes the KCMD
                // span into the first segment record at overall list+0x1c.
                // The native iOS capture has the shortened complete KCMD span
                // here, matching its storage current-start.  Leaving the
                // macOS value after the KCMD deletion breaks that cross-shmem
                // invariant.  The record shrinks by 0x20; its opaque trailer
                // is preserved byte-for-byte by the memmoves above.
                *(uint32_t *)(uintptr_t)(segment_start + 0x1c) =
                    (uint32_t)total;

                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                result.fixed++;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index, "post", commands, total);
                static _Atomic unsigned subtype1_fix_log_count = 0;
                unsigned subtype1_fix_log = atomic_fetch_add(
                    &subtype1_fix_log_count, 1) + 1;
                if (verbose || subtype1_fix_log <= 8) fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-ABI-FIX "
                        "subtype1-clear pads=0x1c0,0x4c0 total=%#zx->%#zx "
                        "size=0x7e8->0x7c8 end=0x818->0x7f8 "
                        "segment-span=%#zx\n",
                        result.sequence, original_total, total, total);
                off += 0x7f8;
                continue;
            }

            // The linear fallback updates only the one direct range at
            // list+0x18.  Never apply it to a multi-segment or trailing-
            // wrapper list: shifting its KCMD tail without updating every
            // later range is a malformed command, not a compatibility fix.
            if (single_direct_segment &&
                inner == 0x30 && subtype == 3 && size == 0x1b8 &&
                end_offset == 0x1e8 && off + 0x1e8 <= total) {
                static const unsigned char sentinel[12] = {
                    0x01, 0x00, 0x00, 0x00,
                    0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff
                };
                int zero_pad = 1;
                for (size_t i = 0x1cc; i < 0x1dc; i++) {
                    if (commands[off + i] != 0) {
                        zero_pad = 0;
                        break;
                    }
                }
                int sentinel_match = memcmp(commands + off + 0x1dc,
                                            sentinel, sizeof(sentinel)) == 0;
                result.candidates++;
                if (verbose) fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u subtype3-mac-layout off=%#zx "
                        "zero-pad=%s sentinel=%s\n",
                        result.sequence, off, zero_pad ? "YES" : "NO",
                        sentinel_match ? "YES" : "NO");
                if (allow_fix && zero_pad && sentinel_match) {
                    size_t move_length = total - (off + 0x1dc);
                    memmove(commands + off + 0x1cc,
                            commands + off + 0x1dc, move_length);
                    memset(commands + total - 0x10, 0, 0x10);
                    *(uint32_t *)(commands + off + 0x28) = 0x1d8;
                    *(uint32_t *)(commands + off + 0x2c) = 0x1a8;
                    total -= 0x10;
                    // Runtime-confirmed by the first Aquarium Internal Error
                    // flight recorder (GPU process 9392, submit 5936): the
                    // translated blob and its direct segment range were both
                    // 0x1e0 bytes, but this outer KCMD header still declared
                    // the pre-deletion 0x1f0 span.  The iOS parser therefore
                    // walked ten bytes beyond the submitted command.  Keep
                    // the command's own complete-span field synchronized with
                    // the storage current pointer and segment range, just as
                    // the subtype-1 normalization above already does.
                    *(uint32_t *)(commands + 0x04) = (uint32_t)total;
                    *(uint32_t *)(uintptr_t)(segment_start + 0x1c) =
                        (uint32_t)total;
                    uint64_t new_current = start + total;
                    uint64_t new_current_raw =
                        (current_raw & 0xffff000000000000ULL) | new_current;
                    *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                    current_raw = new_current_raw;
                    result.fixed++;
                    static _Atomic unsigned subtype3_fix_log_count = 0;
                    unsigned subtype3_fix_log = atomic_fetch_add(
                        &subtype3_fix_log_count, 1) + 1;
                    if (verbose || subtype3_fix_log <= 8) fprintf(stderr,
                            "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-ABI-FIX off=%#zx "
                            "size=0x1b8->0x1a8 end=0x1e8->0x1d8 "
                            "moved=%#zx new-total=%#zx\n",
                            result.sequence, off, move_length, total);
                    off += 0x1d8;
                    continue;
                }
            }
            off += end_offset;
        }
        macws_submit_ring_finish(ring_token,
            result.fixed - fixed_before_descriptor,
            commands, total,
            (const unsigned char *)(uintptr_t)segment_start,
            segment_length);
        macws_fast_submit_finish(fast_ring_token,
            result.fixed - fixed_before_descriptor,
            commands, total,
            (const unsigned char *)(uintptr_t)segment_start,
            segment_length);
        }
    }
    return result;
}

// macOS 13.4 and iOS 16.3 use different IOSurface user-client release ABIs.
// This is an exact two-call-to-one-call protocol adapter, not a generic trap
// bypass:
//
//   macOS IOSurface 2B44B850-7D19-34F3-AB8E-A3B93016A96D
//     IOSurfaceClientRelease+0xa0: IOConnectTrap1(conn, 4, surfaceID)
//     release client+0x60
//     IOSurfaceClientRelease+0x104: IOConnectTrap1(conn, 5, surfaceID)
//
//   iOS IOSurface DF041B53-4BAA-3668-8781-43DE39FA8905
//     release client+0x60
//     IOConnectCallMethod(conn, 1, &surfaceID, 1, ...)
//
// RE-confirmed from the exact framework binaries.  Runtime confirmation from
// misc/iosurface_release_probe.m is even more direct: 16 create/map/CFRelease
// pairs left exactly 16 IOSurface regions / 16384 16-KiB pages resident when
// the macOS trap ABI reached the iOS kernel.  Translate only the two verified
// call sites.  TLS pairing permits the replacement at the second call site
// only when trap 5 follows trap 4 with the same connection and surface ID on
// the same thread.
struct macws_iosurface_release_pair {
    io_connect_t connect;
    uintptr_t surface_id;
    BOOL armed;
};

static __thread struct macws_iosurface_release_pair
    g_macws_iosurface_release_pair;

static BOOL macws_macho_uuid_matches(const struct mach_header_64 *header,
                                     const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64)
        return NO;
    const uint8_t *command_bytes = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)command_bytes;
        if (command->cmdsize < sizeof(*command))
            return NO;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        command_bytes += command->cmdsize;
    }
    return NO;
}

// Metal 310.37 (macOS 13.4) chooses the target platform for source-built
// libraries by calling dyld_get_active_platform() from five call sites in
// MTLLibraryBuilder::newLibraryWithSource.  In the chroot that correctly
// reports macOS (1), but the resulting library is then loaded by the native
// iOS AGX driver, which rejects the macOS library format.  Translate only the
// five RE-confirmed calls in the exact Metal image below to iOS (2).  Every
// other caller, including the rest of Metal and all other frameworks, keeps
// the real chroot platform.
//
// RE-confirmed with misc/ios_lldb_tmux.sh against the loaded binary:
//   UUID 2BAB169C-42DA-36E3-955A-F30B709EC2AD
//   image base                         Metal[0x0000000189848000]
//   MTLLibraryBuilder::newLibrary...   Metal[0x000000018993572c]
//   dyld_get_active_platform LR offsets from image base:
//       0x0edf14 0x0edf28 0x0ee018 0x0ee654 0x0ee690
// Runtime success still has to be witnessed by a non-nil MTLLibrary and a
// rendered WebGL frame; this translator is not labelled a completed fix yet.
extern uint32_t dyld_get_active_platform(void);

static uint32_t dyld_get_active_platform_new(void) {
    uint32_t actual = dyld_get_active_platform();
    // Diagnostic A/B only.  The first runtime trial proved that forcing these
    // calls to iOS makes MTLCompilerService emit an iOS MTLB container
    // (0x0001/0x8200), which the macOS Metal loader rejects.  Keep it opt-in
    // while the unmodified macOS-platform request is measured with the now
    // working compiler cache path.
    if (!getenv("MACWS_AGX_NATIVE") ||
        !getenv("MACWS_METAL_SOURCE_FORCE_IOS"))
        return actual;

    void *signed_return_address = __builtin_return_address(0);
    void *return_address = ptrauth_strip(signed_return_address,
                                         ptrauth_key_return_address);
    Dl_info info = {0};
    if (!return_address || !dladdr(return_address, &info) ||
        !info.dli_fbase || !info.dli_fname)
        return actual;

    const char *basename = strrchr(info.dli_fname, '/');
    basename = basename ? basename + 1 : info.dli_fname;
    static const uint8_t metal_13_4_uuid[16] = {
        0x2b, 0xab, 0x16, 0x9c, 0x42, 0xda, 0x36, 0xe3,
        0x95, 0x5a, 0xf3, 0x0b, 0x70, 0x9e, 0xc2, 0xad,
    };
    if (strcmp(basename, "Metal") != 0 ||
        !macws_macho_uuid_matches(
            (const struct mach_header_64 *)info.dli_fbase,
            metal_13_4_uuid))
        return actual;

    uintptr_t offset = (uintptr_t)return_address - (uintptr_t)info.dli_fbase;
    static const uintptr_t source_builder_platform_returns[] = {
        0x0edf14, 0x0edf28, 0x0ee018, 0x0ee654, 0x0ee690,
    };
    BOOL exact_callsite = NO;
    for (size_t i = 0;
         i < sizeof(source_builder_platform_returns) /
             sizeof(source_builder_platform_returns[0]);
         i++) {
        if (offset == source_builder_platform_returns[i]) {
            exact_callsite = YES;
            break;
        }
    }
    if (!exact_callsite)
        return actual;

    static _Atomic unsigned long translation_count = 0;
    unsigned long sequence =
        atomic_fetch_add_explicit(&translation_count, 1,
                                  memory_order_relaxed) + 1;
    if (sequence <= 32 || (sequence % 500) == 0) {
        fprintf(stderr,
            "#### METAL-SOURCE-PLATFORM #%lu callerOffset=%#lx "
            "actual=%u -> ios=2\n",
            sequence, (unsigned long)offset, actual);
    }
    return 2; // PLATFORM_IOS
}

kern_return_t IOConnectTrap1_new(io_connect_t connect, uint32_t index,
                                  uintptr_t p1) {
    void *raw_return_address = __builtin_return_address(0);
    void *return_address = ptrauth_strip(raw_return_address,
                                         ptrauth_key_return_address);

    // launchdchrootexec can load both libmachook architecture variants.  Let
    // only the outer interpose inspect IOSurface's caller; an inner interpose
    // must forward rather than consume the pair a second time.
    if (caller_is_libmachook(return_address))
        return IOConnectTrap1(connect, index, p1);

    Dl_info info;
    static const uint8_t macos_iosurface_uuid[16] = {
        0x2b, 0x44, 0xb8, 0x50, 0x7d, 0x19, 0x34, 0xf3,
        0xab, 0x8e, 0xa3, 0xb9, 0x30, 0x16, 0xa9, 0x6d,
    };
    BOOL exact_image = NO;
    if (dladdr(return_address, &info) && info.dli_fbase && info.dli_fname) {
        const char *image_basename = strrchr(info.dli_fname, '/');
        image_basename = image_basename ? image_basename + 1 : info.dli_fname;
        exact_image = strcmp(image_basename, "IOSurface") == 0 &&
            macws_macho_uuid_matches(
                (const struct mach_header_64 *)info.dli_fbase,
                macos_iosurface_uuid);
    }
    uintptr_t return_offset = exact_image
        ? (uintptr_t)return_address - (uintptr_t)info.dli_fbase : 0;
    uint32_t call_instruction = exact_image
        ? *((const uint32_t *)return_address - 1) : 0;
    BOOL exact_first = exact_image && return_offset == 0x4b90 &&
        call_instruction == 0x94003617 && index == 4;
    BOOL exact_second = exact_image && return_offset == 0x4bf4 &&
        call_instruction == 0x940035fe && index == 5;

    if (exact_first) {
        g_macws_iosurface_release_pair =
            (struct macws_iosurface_release_pair){connect, p1, YES};
        // iOS has no first operation.  Its sole release selector belongs at
        // the second call site, after macOS has released client+0x60.
        return KERN_SUCCESS;
    }

    if (exact_second && g_macws_iosurface_release_pair.armed &&
        g_macws_iosurface_release_pair.connect == connect &&
        g_macws_iosurface_release_pair.surface_id == p1) {
        g_macws_iosurface_release_pair.armed = NO;
        uint64_t surface_id = p1;
        kern_return_t result = IOConnectCallScalarMethod(
            connect, 1, &surface_id, 1, NULL, NULL);
        static _Atomic unsigned long release_count = 0;
        unsigned long release_n = atomic_fetch_add(&release_count, 1) + 1;
        if (release_n <= 16 || (release_n % 250) == 0 ||
            result != KERN_SUCCESS) {
            fprintf(stderr,
                "#### IOSURFACE-RELEASE-ABI pair #%lu: conn=%u "
                "surfaceID=%llu sel=1 -> %#x\n",
                release_n, connect, (unsigned long long)p1, result);
        }
        return result;
    }

    // A mismatched second half must not inherit a stale pair later.  Preserve
    // the real trap for this call so an unexpected framework build/sequence
    // fails observably instead of silently changing semantics.
    if (exact_second)
        g_macws_iosurface_release_pair.armed = NO;
    return IOConnectTrap1(connect, index, p1);
}

IOReturn IOConnectCallMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int skip = caller_is_libmachook(__builtin_return_address(0));
    if (!skip) selector = IOConnectTranslateSelector(client, selector);
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) *outStructCnt = 0x70;
    // sel=0x9 (ResCreate): WAS bumping outStructCnt 0x50 → 0x10000 here based
    // on a misread of `IOGPUDevice::new_resource <+76>`. Standalone iOS-native
    // test (misc/agx_iogpu_probe.c + misc/sel9_test_macos.c) proves the OPPOSITE:
    //
    //   outSC=0x50   → SUCCESS (kernel-correct, what macOS userland sends)
    //   outSC=0x10000 → FAIL with kIOReturnNoBandwidth (0xe00002c2)
    //
    // The 0xe00002c2 reject IS the result of this bump. EVERY chroot sel=0xa
    // failure in this codebase traces back to this single line. Removed. See
    // [[cross-image-objc-class-register-and-ioconnect-heap-blocker]] LATE
    // UPDATE for the runtime evidence.
    //
    // (Set MACWS_RESTORE_OUTBUMP=1 to revive for A/B testing.)
    if(IOConnectIsIOGPU(client) && selector == 0x9 && outStructCnt && *outStructCnt == 0x50 &&
       getenv("MACWS_RESTORE_OUTBUMP")) {
        *outStructCnt = 0x10000;
    }
    // Preserve the translated selector-7 queue payload. RE-confirmed against
    // iOS 16.3 IOGPU::_IOGPUCommandQueueCreateWithQoS @ 0x1eec62a00 and
    // macOS 13.4 IOGPU::_IOGPUCommandQueueCreateWithQoS @ 0x19d1558b8: both
    // zero a 0x408-byte buffer, copy proc_pidpath into the first 0x400 bytes,
    // then store QoS at +0x400 and the background/priority byte at +0x404.
    // The iOS 16.3 kernel IOGPUCommandQueue initializer @
    // 0xfffffe0009f0c798 only bounds-checks +0x400 against 4 and copies the
    // leading bytes as the queue name; it does not reject a non-empty path.
    //
    // Keep zero substitution only as an explicitly requested A/B diagnostic.
    // It is a scaffold, not an ABI fix.
    unsigned char *qbuf = NULL;
    if (IOConnectIsIOGPU(client) && selector == 0x7 &&
        inStruct && inStructCnt == 0x408 &&
        getenv("MACWS_AGX_ZERO_QUEUE_ARGS")) {
        qbuf = (unsigned char *)calloc(1, inStructCnt);
        inStruct = qbuf;
        static int q_patched;
        if (!q_patched) {
            q_patched = 1;
            fprintf(stderr,
                "#### AGXIOC QueueArgs-DIAGNOSTIC sel=0x%x: MACWS_AGX_ZERO_QUEUE_ARGS replaced native-shaped path/QoS payload with zeroed 0x408 scaffold\n",
                selector);
        }
    }
    unsigned char shadowbuf[256];
    uint8_t  agxType = 0; uint32_t agxClientID = 0; uint64_t agxHeapSz = 0;
    const void *agxRawRequest = NULL;
    size_t agxRawRequestLength = 0;
    uint32_t resDiagSequence = 0;
    int resDiagActive = access("/tmp/macws_res_diag", F_OK) == 0;
    int agxIsRes = (IOConnectIsIOGPU(client) && selector == 0x9 && inStruct && inStructCnt >= 0x60 && inStructCnt <= sizeof(shadowbuf));
    if(agxIsRes) {
        const unsigned char *src = (const unsigned char *)inStruct;
        if (resDiagActive) {
            static _Atomic uint32_t sequence = 0;
            resDiagSequence = atomic_fetch_add(&sequence, 1) + 1;
            if (resDiagSequence <= 64) {
                fprintf(stderr,
                    "#### AGX_RES_DIAG #%u RAW type=%#x len=%zu:",
                    resDiagSequence, src[0], inStructCnt);
                for (size_t offset = 0; offset + 8 <= inStructCnt;
                     offset += 8) {
                    fprintf(stderr, " +%02zx=%#llx", offset,
                        (unsigned long long)*(const uint64_t *)(src + offset));
                }
                fprintf(stderr, "\n");
            }
        }
        agxType = src[0];
        if (agxType == 0x82 &&
            access("/tmp/macws_iogpu_error_diag", F_OK) == 0) {
            agxRawRequest = src;
            agxRawRequestLength = inStructCnt;
        }
        uint8_t  f15  = src[0x15];                                // flag byte; bit-3 = "has parent"
        uint64_t bc   = *(const uint64_t *)(src + 0x40);          // for type=0: heap byte-count
        uint64_t f30  = *(const uint64_t *)(src + 0x30);
        uint64_t va38 = *(const uint64_t *)(src + 0x38);
        uint64_t va48 = *(const uint64_t *)(src + 0x48);          // parent_id OR length depending on type/flags
        // RE confirms (iOS kernel IOGPUDevice::new_resource @
        // fffffe0009f03c1c): for type=0x80, args[0x48] is
        // parent_id only when args[0x15] bit-3 is set. Otherwise it's
        // the client buffer length and the kernel skips the parent
        // lookup, calling IOGPUResource::newResourceWithClientBuffer
        // with (args[0x40], args[0x30], args[0x38]) instead. The
        // previous translator unconditionally clobbered args[0x48]
        // which corrupted the length on every client-buffer path.
        BOOL t80_has_parent = (agxType == 0x80) && (f15 & 0x08);
        // type=0 owns a macOS client-assigned resource ID at +0x48.  type=0x80
        // uses the same field as a parent reference only when f15.bit3 is set.
        // The previous ternary accidentally forced every type=0 ID to zero,
        // collapsing g_agxIdMap to one entry and making every real parent-ID
        // translation miss. Runtime witness: thousands of lines read
        // `heap clientID 0 -> GID ...` while the paired ResCreate dump showed
        // `type=0 clientID=0x40000`.
        agxClientID = (agxType == 0 || t80_has_parent)
            ? *(const uint32_t *)(src + 0x48) : 0;
        int patched = 0;
        memcpy(shadowbuf, inStruct, inStructCnt);
        if(bc == 0 && agxType == 0) {
            // Heap byte-count fixup (only valid for type=0 heap creation;
            // type=0x80 client-buffer path uses args+0x40 as the end VA,
            // not a size). Prefer the exact length captured at the upstream
            // AGXBuffer initFull boundary. The old uint32_t(+0x58) fallback
            // truncated VA-shaped values and underallocated growing Mempools.
            uint32_t sz32 = *(const uint32_t *)(src + 0x58);
            uint64_t mac_span = *(const uint64_t *)(src + 0x48);
            // RE-confirmed in iOS 16.3 IOGPUDevice::new_resource at
            // 0xfffffe0009f0415c: type-0 allocation size is read from
            // args+0x40.  Runtime comparison of matching AGX internal
            // requests shows macOS leaves +0x40 zero and puts the intended
            // span at +0x48, while +0x58 can be a much larger VA-shaped
            // value (for example 0x48000000 beside a 0x8000 span).  The old
            // low32(+0x58) fallback inflated five 0x8000 native buffers into
            // 128 MiB--1.125 GiB allocations; the resulting resource VA
            // 0x1558080000 faulted in hardware as 0x1158080000.
            //
            // A bit-3 parent request gives +0x48 a different kernel meaning,
            // so only use it as the span on the no-parent type-0 path.  The
            // upstream initFull length remains more precise for ordinary
            // MTLBuffers whose allocation span is rounded to a larger page.
            uint64_t fallback_span = (!(f15 & 0x08) && mac_span > 0 &&
                mac_span <= 0x40000000ULL) ? mac_span :
                (sz32 ? sz32 : 0x1000);
            uint64_t nb = g_macws_agx_initfull_len ?
                g_macws_agx_initfull_len : fallback_span;
            *(uint64_t *)(shadowbuf + 0x40) = nb;
            if (!(f15 & 0x08)) {
                // Full 0x68-byte LLDB captures of the matching iOS 16.3
                // requests establish a tail-field ABI shift:
                //
                //   macOS: +0x48=span, +0x50=0, +0x58=arena<<24
                //   iOS:   +0x48=0,    +0x50=arena<<24, +0x58=0
                //
                // Only the low 32 bits carry the arena value.  For example,
                // f14=0x8430 uses 0x48000000 at iOS +0x50 and the kernel
                // returns the special 0x18000/0x28000 VA windows.  Sending
                // zero at +0x50 instead returned an ordinary 0x15... VA;
                // the GPU then consumed that address with bit 34 clear and
                // raised a BIF0 page fault.  Translate the request field at
                // its source; do not rewrite the returned GPU VA.
                uint32_t arena = *(const uint32_t *)(src + 0x58);
                *(uint64_t *)(shadowbuf + 0x48) = 0;
                *(uint64_t *)(shadowbuf + 0x50) = arena;
                *(uint64_t *)(shadowbuf + 0x58) = 0;
            }
            agxHeapSz = nb;
            patched = 1;
            if (g_macws_agx_initfull_len) {
                static _Atomic int exact_len_log_count = 0;
                int exact_n = atomic_fetch_add(&exact_len_log_count, 1);
                if (exact_n < 16) {
                    fprintf(stderr,
                        "#### AGXIOC type0 exact initFull length: +0x58=%#llx low32=%#x -> +0x40=%#llx\n",
                        (unsigned long long)*(const uint64_t *)(src + 0x58),
                        sz32, (unsigned long long)nb);
                }
            } else if (resDiagActive && resDiagSequence <= 64) {
                fprintf(stderr,
                    "#### AGX_RES_DIAG #%u type0 size source: "
                    "+0x48 span=%#llx +0x58 low32=%#x -> +0x40=%#llx\n",
                    resDiagSequence, (unsigned long long)mac_span, sz32,
                    (unsigned long long)nb);
            }
        }
        // type=0 with args+0x40 already set (high bit pattern = pinned-VA
        // shape — macOS used `pinnedGPULocation:` to request a specific
        // VA range; the kernel reads args+0x40 as IOByteCount and
        // rejects sizes that look like VAs). For SLCADisplay scanout
        // backing: args+0x40 = 0x80888f00 (= 2.15 GB, bit 31 set) and
        // args+0x48 = 0x1fb8000 (~33 MB, looks like a real length).
        // Substitute the length-shaped args+0x48 as the size.
        // Widened VA-shape detection (2026-06-19 part 2):
        //
        // Original condition `bc & 0x80000000` only caught SLCADisplay
        // scanout backing where args+0x40 = 0x80888f00 (bit-31 set).
        // For texture-backing requests SkyLight sends args+0x40 like
        // 0x108198000 or 0x1081f4000 — values > 4 GB whose bit-31 is
        // CLEAR (the high 33+ bits hold the VA). The previous condition
        // missed these → unpatched VA reaches kernel → rejected as
        // oversized IOByteCount → AGXTexture super-init returns nil →
        // downstream SkyLight Unbalanced Composites assert.
        //
        // Widened condition: any args+0x40 > 0x40000000 (1 GB) is treated
        // as a VA (no real allocation request is that big — IOGPU+0x108
        // cap is ~5 GB total, individual allocations rarely exceed
        // hundreds of MB). Use args+0x48 as the real length.
        // 2026-06-19 part 3 — type=0 heap with pinned-VA args+0x38 also
        // triggers kernel kIOReturnNoMemory. SkyLight texture path sends
        // args+0x38=0x102fec000 (high VA) AND args+0x40=0x4000 (already a
        // length, so previous VA-shape patch on +0x40 doesn't fire). The
        // VA at +0x38 tells the macOS kernel "place this heap at this
        // pinned GPU VA", iOS kernel rejects. Zero args+0x38 for ANY
        // type=0 heap call where it's >1GB — same logic as +0x40 swap.
        // 2026-06-20 — ONE-SHOT pre-patch dump for type=0x82 (IOSurface
        // texture).  RE of IOGPUDevice::new_resource (kernelcache
        // 0xfffffe0009f03b4c) shows the newResourceWithIOSurface (wrap)
        // path requires args+0x34 >= IOSurface-plane-dimension AND
        // args+0x15 bit3.  Our SURF diagnostics proved the resulting
        // texture has SEPARATE backing (GPU renders there, IOSurface
        // VNC reads stays black).  Hypothesis: our arg-mangling routes
        // the call away from the wrap path.  Dump the ORIGINAL macOS
        // args to see what +0x34 / +0x15 / +0x40 / +0x58 actually hold
        // before we touch them.
        if (agxType == 0x82) {
            static int t82_pre = 0;
            if (!t82_pre) {
                t82_pre = 1;
                fprintf(stderr,
                    "#### AGXIOC RAW DUMP sel=0x9 type=0x82 inStructCnt=%zu (PRE-patch):\n",
                    inStructCnt);
                for (size_t i = 0; i < inStructCnt && i < 0x70; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", src[i + j]);
                    fprintf(stderr, "\n");
                }
                fprintf(stderr,
                    "####   key fields: +0x14=%#x +0x15(byte)=%#x +0x30=%#x "
                    "+0x34=%#x +0x38=%#llx +0x40=%#llx +0x48=%#llx +0x58=%#llx\n",
                    *(const uint32_t *)(src + 0x14),
                    (unsigned)src[0x15],
                    *(const uint32_t *)(src + 0x30),
                    *(const uint32_t *)(src + 0x34),
                    (unsigned long long)*(const uint64_t *)(src + 0x38),
                    (unsigned long long)*(const uint64_t *)(src + 0x40),
                    (unsigned long long)*(const uint64_t *)(src + 0x48),
                    (unsigned long long)*(const uint64_t *)(src + 0x58));
            }
        }
        // Apply VA-shape + flag-strip to ALL types (was only type=0).
        // type=0x80 client-buffer path showed same pattern: args+0x38 has
        // pinned-VA, args+0x14=0x0c30 has bit 11 (macOS-only) set.
        {
            uint64_t va38 = *(const uint64_t *)(src + 0x38);
            if (va38 > 0x40000000ULL && agxType != 0x82) {
                static int log_once_38 = 0;
                if (log_once_38++ < 4) {
                    fprintf(stderr,
                        "#### AGXIOC sel=0x9 type=%#x VA-shape +0x38=%#llx → 0\n",
                        agxType, (unsigned long long)va38);
                }
                *(uint64_t *)(shadowbuf + 0x38) = 0;
                patched = 1;
            }
            // args+0x14 flag mask: known-good values are 0x470 / 0x430.
            // SkyLight texture path sends 0x2c30 (type=0) or 0x0c30
            // (type=0x80) — both add bit 11 (0x800), 0x2c30 also adds
            // bit 13 (0x2000). These are macOS-only options that iOS
            // kernel rejects. Strip 0x2800.
            uint32_t f14 = *(const uint32_t *)(src + 0x14);
            uint32_t f14_clean = f14 & ~0x2800u;
            if (f14_clean != f14) {
                static int log_once_14 = 0;
                if (log_once_14++ < 4) {
                    fprintf(stderr,
                        "#### AGXIOC sel=0x9 type=%#x args+0x14=%#x → %#x "
                        "(stripped macOS-only bits 0x2800)\n",
                        agxType, f14, f14_clean);
                }
                *(uint32_t *)(shadowbuf + 0x14) = f14_clean;
                patched = 1;
            }
        }
        if(agxType == 0 && bc != 0 && bc > 0x40000000ULL) {
            uint64_t len_field = *(const uint64_t *)(src + 0x48);
            uint64_t va58 = *(const uint64_t *)(src + 0x58);
            // Only swap if the length looks reasonable (<= 2 GB).
            if (len_field > 0 && len_field < 0x80000000ULL) {
                fprintf(stderr,
                    "#### AGXIOC sel=0x9 type=0 VA-shape detected: "
                    "args+0x40=%#llx (>1GB) → using args+0x48=%#llx as size, +0x58 %#llx → 0\n",
                    (unsigned long long)bc, (unsigned long long)len_field,
                    (unsigned long long)va58);
                *(uint64_t *)(shadowbuf + 0x40) = len_field;
                // SLCADisplay scanout: macOS leaves args+0x58 set to a tagged
                // GPU-VA (e.g. 0x380888f00). On iOS the kernel reads this as
                // a "pinned VA" request — a macOS-only fast path that doesn't
                // exist on iOS → kIOReturnNoMemory (0xe00002be). Zero it so
                // the kernel falls into the standard heap allocator (which
                // chooses its own VA), same as the type=0x82 IOSurface fix
                // a few blocks down. RE-runtime-confirmed: chroot WS WAS
                // failing every SLCADisplay scanout heap with 0xe00002be even
                // after the +0x40 swap; this companion zero is needed.
                *(uint64_t *)(shadowbuf + 0x58) = 0;
                agxHeapSz = len_field;
                patched = 1;
            }
        }
        // (Obsolete bc>cap check moved into the heap fixup above —
        // macOS leaves args+0x40 = 0; the size we cap is the one we
        // derive from src+0x58, not bc.)
        if(agxType == 0x80 && t80_has_parent) {
            // Sub-resource carved from a tracked parent heap.
            int mapped = 0;
            for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) {
                *(uint32_t *)(shadowbuf + 0x48) = (uint32_t)g_agxIdMap[i].iosResourceID;     // parent-id: client -> iOS resource ID
                if(f30 == 0 && va38) *(uint64_t *)(shadowbuf + 0x30) = va38 + g_agxIdMap[i].size;  // +0x30 = end-VA so size(=+0x30-+0x38) = parent size
                patched = 1; mapped = 1;
                fprintf(stderr, "#### AGXIOC subres parent %#x -> resourceID %#llx, +0x30=%#llx (sz %#llx)\n", agxClientID, (unsigned long long)g_agxIdMap[i].iosResourceID, (unsigned long long)(va38 + g_agxIdMap[i].size), (unsigned long long)g_agxIdMap[i].size);
                break;
            }
            if(!mapped && f30 == 0 && va38) { *(uint64_t *)(shadowbuf + 0x30) = va38; patched = 1; }  // fallback: nonzero
        } else if(agxType == 0x80) {
            // ONE-SHOT raw-bytes dump: capture the EXACT inStruct bytes
            // macOS WS sends for sel=0x9 type=0x80 BEFORE any libmachook
            // patching. Compare to iOS-native probe (agx_iogpu_probe.c)
            // args that also fail kr=0xe00002be. If bytes match → truly
            // structural; if they diverge, the differing field IS the
            // rejection trigger.
            static int t80_dumped = 0;
            if (!t80_dumped) {
                t80_dumped = 1;
                fprintf(stderr,
                    "#### AGXIOC RAW DUMP sel=0x9 type=0x80 inStructCnt=%zu (pre-patch):\n",
                    inStructCnt);
                for (size_t i = 0; i < inStructCnt; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", src[i + j]);
                    fprintf(stderr, "\n");
                }
                // Non-zero u64 scan past 0x60 in case macOS sends more.
                const uint64_t *u = (const uint64_t *)src;
                for (size_t i = 12; i * 8 < inStructCnt; i++) {
                    if (u[i]) fprintf(stderr, "    nz @ +%#zx: %#llx\n",
                        i * 8, (unsigned long long)u[i]);
                }
            }
            // Client-buffer path (type=0x80, no parent flag): iOS kernel
            // entry checks `args[0x40] <= limit` early (IOGPUDevice::
            // new_resource @ fffffe0009f03c4c: cmp x9, x10; b.ls). macOS
            // IOGPUMetalBuffer init writes args[0x40] = client pointer VA
            // (same as args[0x38]) which exceeds the limit (a kalloc-sized
            // value), so this fails before the actual newResourceWithClient-
            // Buffer call. iOS native userland writes args[0x40] = length
            // here. Length sits at args[0x48] (macOS IOGPUMetalBuffer
            // stores it there before this call).
            // 2026-06-19 — type=0x80 + args+0x30=0x1 + mach_vm VA at +0x38
            // is the macOS SCANOUT-buffer creation path. iOS kernel
            // accepts it (probe[5] proved kr=0) but treats the result as
            // a display-engine scanout source — wiring our garbage
            // buffer to the physical LCD framebuffer, corrupting iOS UI
            // (purple/pink screen). Reverted: keep kernel rejection.
            // The CODEHEAP-SHIM IOSurface synth path handles AGXBuffer
            // creates more safely (no scanout side-effect).
            uint64_t length = va48;
            uint64_t cur40 = *(const uint64_t *)(src + 0x40);
            if(length && (cur40 == va38 || cur40 > 0x40000000ULL)) {
                *(uint64_t *)(shadowbuf + 0x40) = length;
                patched = 1;
            }
            uint64_t cur30 = *(const uint64_t *)(src + 0x30);
            if (cur30 > 0x40000000ULL || cur30 == 0x1) {
                *(uint64_t *)(shadowbuf + 0x30) = 0;
                patched = 1;
            }
            uint64_t cur58 = *(const uint64_t *)(src + 0x58);
            if (cur58 != 0) {
                *(uint64_t *)(shadowbuf + 0x58) = 0;
                patched = 1;
            }
        }
        // type=0x82 is the iOS-NATIVE type byte for iosurface-backed textures
        // too — confirmed by static disasm of iOS IOGPUMetalTexture's
        // initWithDevice:descriptor:iosurface:plane:field:args:argsSize: at
        // 0x1eec5d33c: `ldr d0, [#0x1eec7e710]; str d0, [args]` loads the 8-
        // byte template `82 00 00 00 00 00 00 00` and writes it to args[0].
        //
        // Runtime-confirmed type=0x82 tail-field ABI shift (2026-07-24).
        // The exact same 2388x1668 BGRA8 IOSurface texture request was
        // captured from both userlands:
        //
        //   native iOS: +0x30=surfaceID, +0x38=0,
        //               +0x50=0x180888f00, +0x58=0
        //   macOS WS:   +0x30=0, +0x38=surfaceID,
        //               +0x50=0, +0x58=0x180888f00
        //
        // Evidence: /tmp/lldb-iosdraw-native-2388.log res #15 and
        // /tmp/ws-pf550-fault-20260724-190809/WindowServer.err res #16.
        // Therefore the macOS +0x58 value is not a pinned VA to discard; it
        // is the texture-layout word that iOS expects at +0x50.  BGRA8 happened
        // to render with a zero layout word, but the first pf=550 read then
        // faulted.  Translate the producer ABI before the request reaches the
        // kernel: move both shifted fields and clear their old macOS slots.
        // 2026-06-18 disasm of iOS AGXG13G + IOGPUFamily kexts located the
        // exact kernel check that rejects our chroot args. IOGPUDevice::
        // new_resource() at fffffe0009f03bb4:
        //   cmp w8, #0x82                 ; type word
        //   ldr w1, [x24, #0x30]          ; args+0x30 = IOSurfaceID
        //   ldr x2, [x22, #0x50]          ; this->0x50 = task
        //   bl  IOGPU::find_iosurface_for_id
        //   cbz x0, FAIL                  ; ← we hit this. IOSurfaceID=0 →
        //                                   no lookup hit → kIOReturnNoMemory
        // iOS userland's iOS IOGPUMetalTexture iosurface init writes
        //   stp w0, w21, [x24, #0x30]      ; +0x30 = IOSurfaceGetID(io)
        // before sel=0xa fires. macOS WS path leaves +0x30 = 0.
        //
        // Fix: read the IOSurfaceID and compression-header span stashed by
        // Metal_hooks.x's
        // swizzled newTextureWithDescriptor:iosurface:plane: (we're called
        // synchronously from inside that swizzle's %orig), and inject it
        // into args[+0x30]. Keep +0x40 zero and move the macOS texture-layout
        // word from +0x58 to iOS +0x50.
        // macOS chroot stores the IOSurfaceID at args+0x38 (where iOS puts
        // the plane index); iOS userland stores IOSurfaceID at args+0x30
        // (which macOS leaves zero). Swap them: write +0x38's value into
        // +0x30, and put the actual plane (always 0 in our path) at +0x38.
        // Project-LLDB RE of the successful native pf550 path subsequently
        // located the exact iOS producer, `-[AGXG13GFamilyDevice
        // initNewTextureData:]` at runtime 0x2260cf0e0:
        //   0x2260cf23c: orr x9, x9, #0x180000000
        //   0x2260cf250: bfi x9, x11, #33, #1  // compression object exists
        //   0x2260cf278: str x8, [x2, #0x58]   // aligned metadata span
        // For the CA Framebuffer, IOSurfaceCopyAllValues reports the same
        // per-plane reserved compression-header span (0x40000) that native
        // iOS sends at +0x58.  Therefore +0x58 must be reconstructed from the
        // current IOSurface's properties, not blindly zeroed.  Presence of
        // that span also supplies native layout-word bit 33.
        if(agxType == 0x82) {
            uint32_t f14 = *(const uint32_t *)(src + 0x14);
            uint64_t old_40 = *(const uint64_t *)(src + 0x40);
            uint64_t old_50 = *(const uint64_t *)(src + 0x50);
            uint64_t old_58 = *(const uint64_t *)(src + 0x58);
            uint32_t old_30 = *(const uint32_t *)(src + 0x30);
            uint32_t old_38 = *(const uint32_t *)(src + 0x38);
            uint64_t compression_header_span =
                macws_get_current_iosurface_compression_header_span();
            *(uint64_t *)(shadowbuf + 0x40) = 0;
            uint64_t translated_50 = old_50;
            if (old_50 == 0 && old_58 != 0) {
                translated_50 = old_58;
            }
            if (compression_header_span != 0) {
                translated_50 |= (1ULL << 33);
            }
            *(uint64_t *)(shadowbuf + 0x50) = translated_50;
            *(uint64_t *)(shadowbuf + 0x58) = compression_header_span;
            // If +0x30 is empty and +0x38 looks like an IOSurfaceID, swap.
            if (old_30 == 0 && old_38 != 0) {
                *(uint32_t *)(shadowbuf + 0x30) = old_38;
                *(uint32_t *)(shadowbuf + 0x38) = 0;
            }
            patched = 1;
            static _Atomic unsigned int t82_patch_count = 0;
            unsigned int t82_n = atomic_fetch_add(&t82_patch_count, 1) + 1;
            if (t82_n <= 16 || (t82_n % 500) == 0) {
                fprintf(stderr,
                    "#### AGXIOC type=0x82 patch #%u: f14=%#x +0x30 %#x→%#x +0x38 %#x→%#x "
                    "+0x40 %#llx→0 +0x50 %#llx→%#llx +0x58 %#llx→%#llx\n",
                    t82_n, f14,
                    old_30, *(const uint32_t *)(shadowbuf + 0x30),
                    old_38, *(const uint32_t *)(shadowbuf + 0x38),
                    (unsigned long long)old_40,
                    (unsigned long long)old_50,
                    (unsigned long long)*(const uint64_t *)(shadowbuf + 0x50),
                    (unsigned long long)old_58,
                    (unsigned long long)*(const uint64_t *)(shadowbuf + 0x58));
            }
        }
        if(patched) inStruct = shadowbuf;
        if (resDiagActive && resDiagSequence <= 64) {
            const unsigned char *sent = (const unsigned char *)inStruct;
            fprintf(stderr,
                "#### AGX_RES_DIAG #%u SENT type=%#x len=%zu:",
                resDiagSequence, sent[0], inStructCnt);
            for (size_t offset = 0; offset + 8 <= inStructCnt;
                 offset += 8) {
                fprintf(stderr, " +%02zx=%#llx", offset,
                    (unsigned long long)*(const uint64_t *)(sent + offset));
            }
            fprintf(stderr, "\n");
        }
        // POST-patch dump for sel=0x9 type=0x80: capture EXACT bytes that
        // hit the kernel — to compare against iOS-native probe args that
        // also fail kr=0xe00002be with all-zero-but-required-fields.
        if (agxType == 0x80) {
            static int t80_post_dumped = 0;
            if (!t80_post_dumped) {
                t80_post_dumped = 1;
                fprintf(stderr,
                    "#### AGXIOC POST-PATCH sel=0x9 type=0x80 inStructCnt=%zu (bytes that hit kernel):\n",
                    inStructCnt);
                const unsigned char *p = (const unsigned char *)inStruct;
                for (size_t i = 0; i < inStructCnt; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", p[i + j]);
                    fprintf(stderr, "\n");
                }
            }
        }
    }
    struct macws_submit_diag_result submit_diag = {0};
    int translated_agx_submit = !skip && IOConnectIsIOGPU(client) &&
        selector == 0x1a;
    int submit_diag_active = translated_agx_submit &&
        access("/tmp/macws_submit_diag", F_OK) == 0;
    int submit_fix_active = translated_agx_submit &&
        access("/tmp/macws_kcmd_fix", F_OK) == 0;
    // The ABI translator and the byte-dump diagnostic are independent gates.
    // Previously, macws_kcmd_fix was silently inert unless submit_diag also
    // existed, which made the same PF80 submit complete in exclusive tests but
    // fail with MTL 0x102 in an ordinary VNC run.  Inspection is still needed
    // to prove all structural anchors before translating, but deep dumps are
    // emitted only when their own sentinel is present.
    if (submit_diag_active || submit_fix_active) {
        submit_diag = macws_inspect_agx_submit(
            in, inCnt, inStruct, inStructCnt,
            submit_fix_active, submit_diag_active);
    }
    unsigned queue_qos_diag_sequence = 0;
    if (IOConnectIsIOGPU(client) &&
        access("/tmp/macws_queue_qos_diag", F_OK) == 0 &&
        ((orig == 0x8 && selector == 0x7 && inStruct &&
          inStructCnt == 0x408) ||
         (orig == 0x1f && selector == 0x1b))) {
        static _Atomic unsigned queue_qos_diag_count = 0;
        queue_qos_diag_sequence = atomic_fetch_add(
            &queue_qos_diag_count, 1) + 1;
        if (queue_qos_diag_sequence <= 8) {
            if (orig == 0x8) {
                const unsigned char *queue = inStruct;
                char path_prefix[65] = {0};
                size_t path_length = strnlen((const char *)queue, 64);
                memcpy(path_prefix, queue, path_length);
                fprintf(stderr,
                    "#### AGX_QUEUE_QOS #%u CREATE orig=%#x sent=%#x "
                    "path='%s' qos=%u flag404=%u tail405=%02x%02x%02x "
                    "inCnt=%u\n",
                    queue_qos_diag_sequence, orig, selector, path_prefix,
                    *(const uint32_t *)(queue + 0x400), queue[0x404],
                    queue[0x405], queue[0x406], queue[0x407], inCnt);
            } else {
                const unsigned char *bytes = inStruct;
                fprintf(stderr,
                    "#### AGX_QUEUE_QOS #%u SET orig=%#x sent=%#x "
                    "scalar0=%#llx inCnt=%u inSC=%zu bytes=%s%02x%02x%02x%02x"
                    "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                    queue_qos_diag_sequence, orig, selector,
                    (unsigned long long)(in && inCnt ? in[0] : 0),
                    inCnt, inStructCnt,
                    inStruct && inStructCnt >= 12 ? "" : "(short)",
                    inStruct && inStructCnt > 0 ? bytes[0] : 0,
                    inStruct && inStructCnt > 1 ? bytes[1] : 0,
                    inStruct && inStructCnt > 2 ? bytes[2] : 0,
                    inStruct && inStructCnt > 3 ? bytes[3] : 0,
                    inStruct && inStructCnt > 4 ? bytes[4] : 0,
                    inStruct && inStructCnt > 5 ? bytes[5] : 0,
                    inStruct && inStructCnt > 6 ? bytes[6] : 0,
                    inStruct && inStructCnt > 7 ? bytes[7] : 0,
                    inStruct && inStructCnt > 8 ? bytes[8] : 0,
                    inStruct && inStructCnt > 9 ? bytes[9] : 0,
                    inStruct && inStructCnt > 10 ? bytes[10] : 0,
                    inStruct && inStructCnt > 11 ? bytes[11] : 0);
            }
        }
    }
    IOReturn r = IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if (queue_qos_diag_sequence && queue_qos_diag_sequence <= 8) {
        uint32_t queue_id = 0;
        uint64_t queue_token = 0;
        if (r == 0 && orig == 0x8 && outStruct && outStructCnt &&
            *outStructCnt >= 0x10) {
            queue_id = *(const uint32_t *)outStruct;
            queue_token = *(const uint64_t *)((const unsigned char *)outStruct + 8);
        }
        fprintf(stderr,
            "#### AGX_QUEUE_QOS #%u RETURN kr=%#x outSC=%zu "
            "queueID=%#x token=%#llx\n",
            queue_qos_diag_sequence, r,
            outStructCnt ? *outStructCnt : 0, queue_id,
            (unsigned long long)queue_token);
    }
    if (agxIsRes && resDiagActive && resDiagSequence <= 64) {
        size_t returned = (outStructCnt ? *outStructCnt : 0);
        fprintf(stderr,
            "#### AGX_RES_DIAG #%u RETURN kr=%#x outLen=%zu:",
            resDiagSequence, r, returned);
        if (outStruct) {
            const unsigned char *bytes = (const unsigned char *)outStruct;
            for (size_t offset = 0; offset + 8 <= returned; offset += 8) {
                fprintf(stderr, " +%02zx=%#llx", offset,
                    (unsigned long long)*(const uint64_t *)(bytes + offset));
            }
        }
        fprintf(stderr, "\n");
    }
    if (submit_diag_active && submit_diag.sequence <= 8) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u result=%#x records=%u candidates=%u fixed=%u\n",
            submit_diag.sequence, r, submit_diag.records,
            submit_diag.candidates, submit_diag.fixed);
    }
    if (agxIsRes) {
        const unsigned char *sent = (const unsigned char *)inStruct;
        uint64_t requested = (sent && inStructCnt >= 0x48)
            ? *(const uint64_t *)(sent + 0x40) : 0;
        uint32_t client_id = (sent && inStructCnt >= 0x4c)
            ? *(const uint32_t *)(sent + 0x48) : 0;
        uint32_t surface_id = (agxType == 0x82 && sent && inStructCnt >= 0x34)
            ? *(const uint32_t *)(sent + 0x30) : 0;
        if (r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x50) {
            const unsigned char *o = (const unsigned char *)outStruct;
            uint64_t gpu_address = *(const uint64_t *)(o + 0x00);
            uint64_t data_bytes = *(const uint64_t *)(o + 0x08);
            uint64_t client_shared = *(const uint64_t *)(o + 0x10);
            uint64_t gid = *(const uint32_t *)(o + 0x1c);
            uint64_t bytes = *(const uint64_t *)(o + 0x48);
            uint32_t flags_14 = inStructCnt >= 0x18
                ? *(const uint32_t *)(sent + 0x14) : 0;
            uint64_t request_50 = inStructCnt >= 0x58
                ? *(const uint64_t *)(sent + 0x50) : 0;
            macws_agx_life_create(gid, agxType, client_id, surface_id,
                                  gpu_address, data_bytes, client_shared,
                                  bytes, flags_14, request_50,
                                  agxRawRequest, agxRawRequestLength,
                                  inStruct, inStructCnt);
            if (agxType == 0x82) {
                static _Atomic unsigned int t82_bt_count = 0;
                unsigned int bt_n = atomic_fetch_add(&t82_bt_count, 1);
                if (bt_n < 4) {
                    void *frames[16];
                    int nf = backtrace(frames, 16);
                    fprintf(stderr,
                        "#### AGX_LIFE type82 CREATE stack #%u resourceID=%#llx surf=%#x (%d frames):\n",
                        bt_n + 1, (unsigned long long)gid, surface_id, nf);
                    backtrace_symbols_fd(frames, nf, STDERR_FILENO);
                }

                // Opt-in diagnostic for the display-sized resources that
                // dominate long native-AGX sessions.  The first four type-82
                // calls above happen during compositor bootstrap and miss the
                // later ~20 MiB CAWindowServerSurface churn.  Record successful
                // creates only; do not alter the arguments, result, ownership,
                // or finalize path.  A bounded count keeps a failed experiment
                // from turning its stderr into another pressure source.
                if (getenv("MACWS_AGX_LIFE_STACK_LARGE") &&
                    bytes >= (8ull << 20)) {
                    static _Atomic unsigned int large_t82_bt_count = 0;
                    unsigned int large_n =
                        atomic_fetch_add(&large_t82_bt_count, 1);
                    if (large_n < 24) {
                        void *frames[24];
                        int nf = backtrace(frames, 24);
                        fprintf(stderr,
                            "#### AGX_LIFE LARGE-TYPE82 stack #%u "
                            "resourceID=%#llx surf=%#x bytes=%#llx "
                            "(%d frames):\n",
                            large_n + 1, (unsigned long long)gid,
                            surface_id, (unsigned long long)bytes, nf);
                        backtrace_symbols_fd(frames, nf, STDERR_FILENO);
                    }
                }
            }
        } else if (r != 0) {
            macws_agx_life_create_failed(agxType, requested, r);
        }
    }
    if (IOConnectIsIOGPU(client) && orig == 0xb && in && inCnt >= 1) {
        // Runtime-correlate finalize's scalar against create out+0x1c.  The
        // first matched AGX_LIFE DESTROY line is the direct ABI witness.
        macws_agx_life_destroy(in[0], r);
    }
    // Log the kr for sel=0x9 type=0x80 once so we can pair it with the
    // POST-PATCH dump above.
    if (agxIsRes && agxType == 0x80) {
        static int t80_kr_logged = 0;
        if (!t80_kr_logged) {
            t80_kr_logged = 1;
            fprintf(stderr,
                "#### AGXIOC POST-CALL sel=0x9 type=0x80 -> kr=%#x\n", r);
        }
    }
    // Parameter fuzz: if sel=0x9 ResCreate returned BadArgument, try a
    // handful of perturbations and report which ones the kernel accepts.
    // One-shot per process (static seen flag) and only for type=0 heap
    // creates, since those are what's broken.
    if (getenv("MACWS_AGXIOC_FUZZ") && IOConnectIsIOGPU(client) && selector == 0x9 &&
        r == 0xe00002c2 && inStruct && inStructCnt >= 0x60) {
        static int s_fuzz_done = 0;
        const unsigned char *src = (const unsigned char *)inStruct;
        if (!s_fuzz_done && src[0] == 0) {
            s_fuzz_done = 1;
            unsigned char buf[256];
            struct { const char *name; int ofs; int sz; uint64_t val; } perturbs[] = {
                {"zero args+0x40",     0x40, 8, 0},
                {"args+0x40 = 0x1000", 0x40, 8, 0x1000},
                {"args+0x40 = 0x4000", 0x40, 8, 0x4000},
                {"zero args+0x58",     0x58, 8, 0},
                {"args+0x14 = 0",      0x14, 4, 0},
                {"args+0x10..1f = 0",  0x10, 8, 0},
                {"args+0x48 = 0",      0x48, 8, 0},
                {"args+0x60 = 0",      0x60, 8, 0},
                {"args+0x08 = 0",      0x08, 8, 0},
                {NULL, 0, 0, 0}
            };
            for (int i = 0; perturbs[i].name; i++) {
                memcpy(buf, inStruct, inStructCnt);
                if (perturbs[i].sz == 8) {
                    *(uint64_t*)(buf + perturbs[i].ofs) = perturbs[i].val;
                } else {
                    *(uint32_t*)(buf + perturbs[i].ofs) = (uint32_t)perturbs[i].val;
                }
                size_t osc = outStructCnt ? *outStructCnt : 0;
                IOReturn rr = IOConnectCallMethod(client, selector, in, inCnt,
                    buf, inStructCnt, out, outCnt, outStruct, outStructCnt ? &osc : NULL);
                fprintf(stderr,
                    "#### AGXIOC FUZZ [%s]: outSC=%zu → 0x%x\n",
                    perturbs[i].name, osc, rr);
                // Restore for next iteration
                if (outStructCnt) *outStructCnt = osc;
            }
            // Also try with outStructCnt = 0
            if (outStructCnt) {
                size_t saved = *outStructCnt;
                *outStructCnt = 0;
                memcpy(buf, inStruct, inStructCnt);
                IOReturn rr = IOConnectCallMethod(client, selector, in, inCnt,
                    buf, inStructCnt, out, outCnt, outStruct, outStructCnt);
                fprintf(stderr, "#### AGXIOC FUZZ [outStructCnt=0]: → 0x%x\n", rr);
                *outStructCnt = saved;
            }
        }
    }
    if(agxIsRes && r == 0 && agxType == 0 && outStruct && outStructCnt && *outStructCnt >= 0x30) {
        const unsigned char *o = (const unsigned char *)outStruct;
        uint64_t gid = *(const uint32_t *)(o + 0x1c);   // RE-confirmed iOS resource ID; finalize uses this exact scalar
        int slot = -1;
        for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) { slot = i; break; }  // overwrite (clientID reused)
        if(slot < 0 && g_agxIdMapCount < 128) slot = g_agxIdMapCount++;
        if(slot >= 0) { g_agxIdMap[slot].clientID = agxClientID; g_agxIdMap[slot].iosResourceID = gid; g_agxIdMap[slot].size = agxHeapSz; }
        static _Atomic unsigned int heap_map_count = 0;
        unsigned int heap_n = atomic_fetch_add(&heap_map_count, 1) + 1;
        if (heap_n <= 16 || (heap_n % 500) == 0) {
            fprintf(stderr,
                "#### AGXIOC heap map #%u clientID %#x -> resourceID %#llx size %#llx\n",
                heap_n, agxClientID, (unsigned long long)gid,
                (unsigned long long)agxHeapSz);
        }
    }
    if(IOConnectIsIOGPU(client)) {
        // Resource create/destroy have their own structured AGX_LIFE logs.
        // Successful submit/finalize calls are also a per-frame hot path: the
        // previous unconditional line reached tens of thousands of writes in
        // a two-minute idle session. Keep startup + periodic witnesses and
        // every failure without turning stderr into part of the workload.
        static _Atomic unsigned long methodSuccessCount[256];
        unsigned index = orig < 256 ? orig : 255;
        unsigned long successSequence = r == 0
            ? atomic_fetch_add(&methodSuccessCount[index], 1) + 1 : 0;
        BOOL logMethod = r != 0 ||
            ((orig != 0xa && orig != 0xb) &&
             (successSequence <= 8 || (successSequence % 1000) == 0));
        if (logMethod) {
            fprintf(stderr,
                "#### AGXIOC Method sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n",
                orig, selector, inCnt, inStructCnt,
                outStructCnt ? *outStructCnt : 0, r);
        }
        // Diagnostic: dump the inStruct for sel=0x7/0x8 failures (queue
        // creation). 1032-byte args; the iOS kernel rejects with 0xe00002c2.
        // Dump first 128 bytes + scan for non-zero regions so we can RE the
        // macOS-vs-iOS field divergence.
        if (r == 0xe00002c2 && (orig == 0x7 || orig == 0x8) &&
            inStruct && inStructCnt >= 0x10) {
            const unsigned char *src = (const unsigned char *)inStruct;
            static int q_dump_done[2] = {0, 0};
            int slot = (orig == 0x7) ? 0 : 1;
            if (!q_dump_done[slot]) {
                q_dump_done[slot] = 1;
                fprintf(stderr,
                    "####   QueueCreate sel=0x%x inSC=%zu FAIL — full dump:\n",
                    orig, inStructCnt);
                // Hex dump head + every non-zero u64 chunk
                size_t max = inStructCnt;
                for (size_t i = 0; i < max && i < 256; i++) {
                    if (i % 16 == 0) fprintf(stderr, "\n####     %03zx:", i);
                    fprintf(stderr, " %02x", src[i]);
                }
                fprintf(stderr, "\n");
                // Scan for non-zero u64s past offset 256
                size_t step = 8;
                for (size_t i = 256; i + step <= inStructCnt; i += step) {
                    uint64_t v = *(const uint64_t *)(src + i);
                    if (v) {
                        fprintf(stderr,
                            "####     +%03zx: %016llx\n",
                            i, (unsigned long long)v);
                    }
                }
            }
        }
        // Diagnostic: dump the inStruct for ALL sel=0xa calls (resource
        // create). Compare successful heap (line A) vs failing texture
        // (line B) so we can identify what kernel rejects.
        static _Atomic unsigned int res_verbose_count = 0;
        unsigned int res_verbose_n = (orig == 0xa && selector == 0x9)
            ? atomic_fetch_add(&res_verbose_count, 1) : UINT_MAX;
        if (orig == 0xa && selector == 0x9 &&
            inStruct && inStructCnt >= 0x60 &&
            (r != 0 || res_verbose_n < 48)) {
            const unsigned char *src = (const unsigned char *)inStruct;
            uint8_t type = src[0];
            uint32_t clientID = *(const uint32_t *)(src + 0x48);
            uint64_t f30 = *(const uint64_t *)(src + 0x30);
            uint64_t va38 = *(const uint64_t *)(src + 0x38);
            uint64_t bc40 = *(const uint64_t *)(src + 0x40);
            uint64_t va58 = *(const uint64_t *)(src + 0x58);
            // RE-confirmed via the actual iOS 16.3 and macOS 13.4
            // IOGPUResourceCreate implementations: kernel output +0 is
            // copied to IOGPUResource+0x38. IOGPUResourceGetGPUVirtualAddress
            // returns that field, and IOGPUMetalResource init stores it in
            // the ivar returned by -gpuAddress. Output +0x1c is resourceID;
            // output +0x48 is the GPU-VA span. Keep +0x10 in the log because
            // it is a distinct client-shared field, not the GPU address.
            uint64_t out00 = 0, out08 = 0, out10 = 0, out48 = 0;
            if (r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x18) {
                const unsigned char *o = (const unsigned char *)outStruct;
                out00 = *(const uint64_t *)(o + 0x00);
                out08 = *(const uint64_t *)(o + 0x08);
                out10 = *(const uint64_t *)(o + 0x10);
                if (*outStructCnt >= 0x50)
                    out48 = *(const uint64_t *)(o + 0x48);
            }
            fprintf(stderr,
                "####   ResCreate %s type=%#x clientID=%#x "
                "+0x30=%#llx +0x38=%#llx +0x40=%#llx +0x58=%#llx "
                "OUT[+0]=%#llx OUT[+0x08]=%#llx OUT[+0x10]=%#llx "
                "OUT[+0x48]=%#llx\n",
                r ? "FAIL" : "OK",
                type, clientID,
                (unsigned long long)f30, (unsigned long long)va38,
                (unsigned long long)bc40,
                (unsigned long long)va58,
                (unsigned long long)out00, (unsigned long long)out08,
                (unsigned long long)out10, (unsigned long long)out48);
            // Hex dump first 0x70 bytes
            fprintf(stderr, "####   inStruct[0..%zu]:", inStructCnt);
            for (size_t i = 0; i < inStructCnt && i < 0x70; i++) {
                if (i % 16 == 0) fprintf(stderr, "\n####     %02zx:", i);
                fprintf(stderr, " %02x", src[i]);
            }
            fprintf(stderr, "\n");
            // For each FAILED type=0x80 sub-resource: dump the caller chain
            // so we know which AGXBuffer / IOGPUMetalBuffer path picked the
            // parent. Sometimes ties macOS's `allocBufferSubData` vs the
            // standalone init path.
            if (r != 0 && type == 0x80) {
                void *frames[12];
                int nf = backtrace(frames, 12);
                fprintf(stderr, "####   caller chain (%d frames):\n", nf);
                for (int i = 0; i < nf; i++) {
                    Dl_info di;
                    if (dladdr(frames[i], &di) && di.dli_fname) {
                        uintptr_t base = (uintptr_t)di.dli_fbase;
                        const char *fname = strrchr(di.dli_fname, '/');
                        fname = fname ? fname + 1 : di.dli_fname;
                        fprintf(stderr, "####     [%d] %p %s+%#llx (%s)\n",
                            i, frames[i],
                            di.dli_sname ? di.dli_sname : "?",
                            (unsigned long long)((uintptr_t)frames[i] -
                                (uintptr_t)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)),
                            fname);
                    } else {
                        fprintf(stderr, "####     [%d] %p (unmapped)\n", i, frames[i]);
                    }
                }
            }
        }
    }
    if (qbuf) free(qbuf);
    return r;
}
IOReturn IOConnectCallScalarMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    if (!caller_is_libmachook(__builtin_return_address(0)))
        selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallScalarMethod(client, selector, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client) && orig != selector) {
        static _Atomic unsigned long scalarSuccessCount[256];
        unsigned index = orig < 256 ? orig : 255;
        unsigned long successSequence = r == 0
            ? atomic_fetch_add(&scalarSuccessCount[index], 1) + 1 : 0;
        if (r != 0 || successSequence <= 8 || (successSequence % 1000) == 0) {
            fprintf(stderr,
                "#### AGXIOC Scalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n",
                orig, selector, inCnt, r);
        }
    }
    return r;
}

// RE-confirmed via the actual macOS 13.4 IOMobileFramebuffer image
// 9485C742-B91F-3C6C-897C-AB2C8ACF7625:
//
//   kern_SwapEnd    0x18b026400..0x18b0264e0
//     selector 5; then releases framebuffer+0xb00, increments +0x670, and
//     periodically reports underrun analytics.
//   kern_SwapCancel 0x18b026714..0x18b026778
//     selector 0x34 with the swap ID; then returns directly.
//
// Translating only SwapEnd's nested IOConnect call to selector 0x34 therefore
// ran the wrong user-space tail after a successful cancellation.  Interpose at
// the exported protocol boundary instead: pair SwapBegin with the complete
// public SwapCancel operation and never enter SwapEnd.  The narrow nested-call
// adapter below remains only as a fail-safe for any direct kern_SwapEnd caller
// that bypasses this exported API.
extern IOReturn IOMobileFramebufferSwapEnd(MacwsIOMobileFramebufferRef framebuffer);
extern IOReturn IOMobileFramebufferSwapCancel(
    MacwsIOMobileFramebufferRef framebuffer, uint32_t swap_id);

// Diagnostic-only pacing knob for the cancelled-swap completion scaffold.
// The production default stays at one 60-Hz interval. A bounded slower value
// lets an A/B test distinguish a producer/backpressure problem from a command
// ABI or resource-lifetime problem without changing either command bytes or
// completion semantics. This is intentionally not presented as a refresh-rate
// implementation: the synthetic completion is still not a real display/GPU
// completion signal.
static uint32_t macws_coexist_completion_pace_us(void) {
    enum {
        kDefaultPaceUS = 16667,
        kMinimumPaceUS = 8333,
        kMaximumPaceUS = 100000,
    };
    static dispatch_once_t once;
    static uint32_t pace_us = kDefaultPaceUS;
    dispatch_once(&once, ^{
        char file_value[32] = {0};
        const char *value = getenv("MACWS_COEXIST_PACE_US");
        const char *source = "default";
        if (value && *value) {
            source = "environment";
        } else {
            int fd = open("/private/tmp/macws_coexist_pace_us", O_RDONLY);
            if (fd >= 0) {
                ssize_t count = read(fd, file_value, sizeof(file_value) - 1);
                close(fd);
                if (count > 0) {
                    file_value[count] = '\0';
                    value = file_value;
                    source = "diagnostic-file";
                }
            }
        }

        if (value && *value) {
            char *end = NULL;
            errno = 0;
            unsigned long parsed = strtoul(value, &end, 10);
            while (end && (*end == ' ' || *end == '\t' ||
                           *end == '\r' || *end == '\n')) {
                end++;
            }
            if (errno == 0 && end && end != value && *end == '\0' &&
                parsed >= kMinimumPaceUS && parsed <= kMaximumPaceUS) {
                pace_us = (uint32_t)parsed;
            } else {
                fprintf(stderr,
                    "#### COEXIST DIAGNOSTIC pace rejected: source=%s "
                    "value='%s' valid=%u..%u us; using default=%u us\n",
                    source, value, kMinimumPaceUS, kMaximumPaceUS,
                    kDefaultPaceUS);
                source = "default-after-invalid-value";
            }
        }
        fprintf(stderr,
            "#### COEXIST DIAGNOSTIC completion pace: %u us source=%s "
            "(synthetic completion; not a refresh-rate implementation)\n",
            pace_us, source);
    });
    return pace_us;
}

static uint32_t macws_coexist_activity_pace_us(uint32_t idle_pace_us) {
    enum {
        kInteractivePaceUS = 16667,
        kInteractionWindowNS = 1000 * NSEC_PER_MSEC,
    };
    if (idle_pace_us <= kInteractivePaceUS) return idle_pace_us;

    static int activity_fd = -1;
    if (activity_fd < 0) {
        activity_fd = open("/private/tmp/macws_vnc_activity",
                           O_RDONLY | O_CLOEXEC);
    }
    uint64_t activity_ns = 0;
    BOOL interactive = NO;
    if (activity_fd >= 0 &&
        pread(activity_fd, &activity_ns,
              sizeof(activity_ns), 0) == sizeof(activity_ns)) {
        struct timespec now = {0};
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            uint64_t now_ns = (uint64_t)now.tv_sec * NSEC_PER_SEC +
                (uint64_t)now.tv_nsec;
            interactive = now_ns >= activity_ns &&
                now_ns - activity_ns <= kInteractionWindowNS;
        }
    }

    static _Atomic int prior_mode = -1;
    int mode = interactive ? 1 : 0;
    int prior = atomic_exchange_explicit(
        &prior_mode, mode, memory_order_acq_rel);
    if (prior != mode) {
        fprintf(stderr,
            "#### COEXIST DIAGNOSTIC activity pace: mode=%s "
            "pace=%u us idle=%u us window=1000ms\n",
            interactive ? "interactive" : "idle",
            interactive ? kInteractivePaceUS : idle_pace_us,
            idle_pace_us);
    }
    return interactive ? kInteractivePaceUS : idle_pace_us;
}

// Pace completion timestamps, not post-render delays.  The former fixed
// usleep(interval) below made the virtual frame period equal to
// render_time + interval; the 2026-07-28 Chromium 148 control consequently
// produced an average 55-ms rAF interval while each 100-draw issue took only
// 0.09 ms.  Keep one synchronous completion per swap (so no callback FIFO can
// accumulate), but subtract time already spent rendering since the preceding
// completion.  This remains a virtual-display timing scaffold, not a claim
// that a synthetic callback is a hardware vblank or GPU fence.
static uint32_t macws_coexist_wait_for_completion_slot(uint32_t interval_us) {
    static pthread_mutex_t pace_lock = PTHREAD_MUTEX_INITIALIZER;
    static uint64_t last_completion_ns = 0;
    const uint64_t interval_ns = (uint64_t)interval_us * 1000u;
    uint32_t slept_us = 0;

    pthread_mutex_lock(&pace_lock);
    struct timespec now_ts = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now_ts) == 0) {
        uint64_t now_ns = (uint64_t)now_ts.tv_sec * NSEC_PER_SEC +
            (uint64_t)now_ts.tv_nsec;
        uint64_t target_ns = last_completion_ns
            ? last_completion_ns + interval_ns : now_ns + interval_ns;
        if (target_ns > now_ns) {
            uint64_t remaining_us = (target_ns - now_ns + 999u) / 1000u;
            if (remaining_us > UINT32_MAX) remaining_us = UINT32_MAX;
            slept_us = (uint32_t)remaining_us;
            usleep((useconds_t)slept_us);
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now_ts) == 0) {
            last_completion_ns = (uint64_t)now_ts.tv_sec * NSEC_PER_SEC +
                (uint64_t)now_ts.tv_nsec;
        } else {
            last_completion_ns = target_ns;
        }
    } else {
        // Preserve the established bounded behavior if the monotonic clock is
        // unexpectedly unavailable on a future target.
        slept_us = interval_us;
        usleep((useconds_t)interval_us);
    }
    pthread_mutex_unlock(&pace_lock);
    return slept_us;
}

static IOReturn MacwsIOMobileFramebufferSwapEnd_new(void *framebuffer) {
    if (!atomic_load(&g_macws_iomfb_coexist_swap_cancel) || !framebuffer) {
        return g_macws_orig_iomfb_swap_end
            ? g_macws_orig_iomfb_swap_end(framebuffer)
            : IOMobileFramebufferSwapEnd(framebuffer);
    }

    uint32_t swap_id = *(const volatile uint32_t *)
        ((const char *)framebuffer + 0x68);
    uint64_t requested_presentation_time = mach_absolute_time();
    IOReturn result = IOMobileFramebufferSwapCancel(framebuffer, swap_id);
    static _Atomic unsigned long cancel_count = 0;
    unsigned long sequence = atomic_fetch_add(&cancel_count, 1) + 1;
    if (sequence <= 16 || (sequence % 600) == 0 || result != KERN_SUCCESS) {
        fprintf(stderr,
            "#### COEXIST API SwapCancel #%lu: fb=%p swapID=%u -> %#x "
            "(SwapEnd tail skipped)\n",
            sequence, framebuffer, swap_id, result);
    }
    if (result == KERN_SUCCESS) {
        // Runtime-confirmed 2026-07-26: immediate synthetic completion drove
        // 3,600 swaps/minute and held WindowServer at 98% CPU until the
        // thermal watchdog stopped it.  The earlier asynchronous 200-ms FIFO
        // did not pace submissions and grew without bound.  Block this exact
        // SwapEnd ownership boundary for one 60-Hz interval before queueing
        // its one matching completion.  Pace against the preceding completion
        // timestamp so render work counts toward (rather than being added to)
        // the requested interval.
        uint32_t pace_us = macws_coexist_activity_pace_us(
            macws_coexist_completion_pace_us());
        uint32_t slept_us =
            macws_coexist_wait_for_completion_slot(pace_us);
        io_connect_t client = *(const volatile io_connect_t *)
            ((const char *)framebuffer + 0x14);
        macws_iomfb_complete_cancelled_swap(
            client, swap_id, requested_presentation_time);
        if (sequence <= 4) {
            fprintf(stderr,
                "#### COEXIST completion pace #%lu: interval=%u us "
                "slept=%u us before swapID=%u\n",
                sequence, pace_us, slept_us, swap_id);
        }
    }
    return result;
}

IOReturn IOConnectCallStructMethod_new(io_connect_t client, uint32_t selector, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int struct_skip = caller_is_libmachook(__builtin_return_address(0));
    if (!struct_skip)
        selector = IOConnectTranslateSelector(client, selector);
    // macOS 13.4 kern_SwapEnd passes conn+0x18 as its 0x46c-byte selector-5
    // input. SwapBegin stored the active swap ID at conn+0x68, hence input+0x50.
    // In coexistence, cancel that exact swap through the RE-confirmed iOS ABI
    // instead of presenting to the panel. Return the real cancel status; the
    // caller then continues the remainder of kern_SwapEnd normally.
    // `/tmp/macws_real_swapend` is a short-lived A/B diagnostic only.  It
    // leaves the verified macOS selector-5 call entirely untouched so we can
    // measure whether the Cancel substitution itself breaks page ownership.
    // Do not ship the sentinel: a real SwapEnd can contend with backboardd for
    // the physical panel in coexistence mode.
    BOOL realSwapEndDiagnostic =
        access("/tmp/macws_real_swapend", F_OK) == 0;
    if (!struct_skip && !realSwapEndDiagnostic &&
        atomic_load(&g_macws_iomfb_coexist_swap_cancel) &&
        orig == 5 && selector == 5 && inStruct && inStructCnt == 0x46c) {
        uint32_t swap_id = *(const volatile uint32_t *)((const char *)inStruct + 0x50);
        uint64_t scalar = swap_id;
        uint64_t requested_presentation_time = mach_absolute_time();
        IOReturn cancel_r = IOConnectCallScalarMethod(
            client, 0x34, &scalar, 1, NULL, NULL);
        static _Atomic unsigned long cancel_count = 0;
        unsigned long cancel_n = atomic_fetch_add(&cancel_count, 1) + 1;
        if (cancel_n <= 8 || (cancel_n % 600) == 0 || cancel_r != KERN_SUCCESS) {
            fprintf(stderr,
                "#### COEXIST SwapCancel #%lu: conn=%u swapID=%u sel=0x34 -> %#x\n",
                cancel_n, client, swap_id, cancel_r);
        }

        if (cancel_r == KERN_SUCCESS) {
            // The public SwapEnd trampoline normally owns this pacing.  This
            // branch is its exact-call-shape fallback, so it must preserve the
            // same one-submit/one-paced-completion invariant.  Runtime-
            // confirmed 2026-07-29: the Mac cross-build had compiled the
            // public hook out, this unpaced path delivered 4,200 completions
            // in a bounded run and kept WindowServer hot even at an intended
            // 100-ms idle pace.
            uint32_t pace_us = macws_coexist_activity_pace_us(
                macws_coexist_completion_pace_us());
            uint32_t slept_us =
                macws_coexist_wait_for_completion_slot(pace_us);
            macws_iomfb_complete_cancelled_swap(
                client, swap_id, requested_presentation_time);
            if (cancel_n <= 4) {
                fprintf(stderr,
                    "#### COEXIST fallback completion pace #%lu: "
                    "interval=%u us slept=%u us before swapID=%u\n",
                    cancel_n, pace_us, slept_us, swap_id);
            }
        }

        return cancel_r;
    }
    // AGX GPU device-info query (method 256 / setupImmediate): macOS 13.4 asks for
    // a 0x78 (120-byte) output struct, but the iOS 16.x GPU userclient hard-checks
    // the output size at 0x70 (112). The 8-byte mismatch -> kIOReturnBadArgument and
    // AGX device init aborts. Clamp to what the iOS kernel accepts. (Found by diffing
    // macOS AGXMetal13_3 727C250E vs iOS BA327004 in Ghidra: both selector 0x100,
    // outStructCnt 0x78 vs 0x70.)
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) {
        *outStructCnt = 0x70;
    }
    IOReturn r = IOConnectCallStructMethod(client, selector, inStruct, inStructCnt, outStruct, outStructCnt);
    // Read-only witness for the exclusive-mode control experiment.  The exact
    // 0x46c-byte shape is the macOS 13.4 kern_SwapEnd call verified above;
    // coexistence returns from the narrow SwapCancel branch before reaching
    // this point.  Do not change the selector, payload, return code, or state.
    if ((getenv("MACWS_IOMFB_SWAP_TRACE") || realSwapEndDiagnostic) && !struct_skip &&
        orig == 5 && selector == 5 && inStruct && inStructCnt == 0x46c) {
        uint32_t swap_id =
            *(const volatile uint32_t *)((const char *)inStruct + 0x50);
        static _Atomic unsigned long real_swap_count = 0;
        unsigned long swap_n = atomic_fetch_add(&real_swap_count, 1) + 1;
        if (swap_n <= 16 || (swap_n % 600) == 0 || r != KERN_SUCCESS) {
            fprintf(stderr,
                "#### IOMFB REAL SwapEnd #%lu: conn=%u swapID=%u "
                "sel=5 bytes=0x46c -> %#x\n",
                swap_n, client, swap_id, r);
        }
    }
    if(IOConnectIsIOGPU(client) && orig != selector) fprintf(stderr, "#### AGXIOC Struct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncMethod(client, selector, wake_port, ref, refCnt, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncMethod sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inCnt, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncScalarMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    if (IOConnectIsIOGPU(client) && orig == 0x107 &&
        access("/tmp/macws_iogpu_error_diag", F_OK) == 0) {
        static _Atomic unsigned registration_count = 0;
        unsigned sequence = atomic_fetch_add(&registration_count, 1) + 1;
        if (sequence <= 8) {
            void *caller = __builtin_return_address(0);
            Dl_info caller_info = {0};
            (void)dladdr(caller, &caller_info);
            fprintf(stderr,
                "#### AGXIOC ASYNC-REGISTER #%u conn=%u sel=0x%x->0x%x "
                "wake=%u ref=%p refCnt=%u inCnt=%u caller=%p image=%s "
                "symbol=%s\n",
                sequence, client, orig, selector, wake_port, ref, refCnt,
                inCnt, caller,
                caller_info.dli_fname ?: "(unknown)",
                caller_info.dli_sname ?: "(unknown)");
            uint32_t limit = refCnt < 8 ? refCnt : 8;
            for (uint32_t index = 0; ref && index < limit; index++) {
                void *candidate = (void *)(uintptr_t)ref[index];
                Dl_info info = {0};
                int resolved = candidate ? dladdr(candidate, &info) : 0;
                fprintf(stderr,
                    "#### AGXIOC ASYNC-REFERENCE registration=%u index=%u "
                    "value=%#llx image=%s symbol=%s symbolAddress=%p\n",
                    sequence, index, (unsigned long long)ref[index],
                    resolved && info.dli_fname ? info.dli_fname : "(none)",
                    resolved && info.dli_sname ? info.dli_sname : "(none)",
                    resolved ? info.dli_saddr : NULL);
            }
        }
    }
    IOReturn r = IOConnectCallAsyncScalarMethod(client, selector, wake_port, ref, refCnt, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncScalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallAsyncStructMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncStructMethod(client, selector, wake_port, ref, refCnt, inStruct, inStructCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncStruct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}

// Read-only CVDisplayLink protocol witness for the Chromium/WebGL pacing
// investigation.  Chromium creates its link with an explicit
// CGDirectDisplayID, whereas the control probe that remains near 120 Hz uses
// CVDisplayLinkCreateWithActiveCGDisplays.  When the sentinel exists, retain
// Chromium's callback unchanged and log the exact requested/current display
// IDs plus the `now` and `outputTime` values delivered by CoreVideo.  This is
// deliberately not a timestamp correction: it establishes which layer first
// produces the negative callback_timebase_to_display value seen in Chromium's
// trace before an adapter is considered.
typedef int32_t MacwsCVReturn;
typedef void *MacwsCVDisplayLinkRef;
typedef uint32_t MacwsCGDirectDisplayID;
typedef uint64_t MacwsCVOptionFlags;
typedef struct {
    uint32_t version;
    int32_t videoTimeScale;
    int64_t videoTime;
    uint64_t hostTime;
    double rateScalar;
    int64_t videoRefreshPeriod;
} MacwsCVTimeStampPrefix;
typedef MacwsCVReturn (*MacwsCVDisplayLinkOutputCallback)(
    MacwsCVDisplayLinkRef display_link,
    const MacwsCVTimeStampPrefix *now,
    const MacwsCVTimeStampPrefix *output_time,
    MacwsCVOptionFlags flags_in,
    MacwsCVOptionFlags *flags_out,
    void *user_info);

extern MacwsCVReturn CVDisplayLinkCreateWithCGDisplay(
    MacwsCGDirectDisplayID display_id, MacwsCVDisplayLinkRef *display_link_out);
extern MacwsCVReturn CVDisplayLinkSetOutputCallback(
    MacwsCVDisplayLinkRef display_link,
    MacwsCVDisplayLinkOutputCallback callback,
    void *user_info);
extern MacwsCGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(
    MacwsCVDisplayLinkRef display_link);
extern uint64_t CVGetCurrentHostTime(void);

struct macws_cvdisplaylink_trace_slot {
    MacwsCVDisplayLinkRef display_link;
    MacwsCGDirectDisplayID requested_display_id;
    MacwsCVDisplayLinkOutputCallback callback;
    void *user_info;
    _Atomic unsigned long callback_count;
};

static pthread_mutex_t g_macws_cvdisplaylink_trace_lock =
    PTHREAD_MUTEX_INITIALIZER;
static struct macws_cvdisplaylink_trace_slot
    g_macws_cvdisplaylink_trace_slots[8];

static bool macws_cvdisplaylink_trace_enabled(void) {
    return access("/tmp/macws_cvdl_trace", F_OK) == 0;
}

static int64_t macws_cvdisplaylink_tick_delta(uint64_t later,
                                              uint64_t earlier) {
    return later >= earlier
        ? (int64_t)(later - earlier)
        : -(int64_t)(earlier - later);
}

static struct macws_cvdisplaylink_trace_slot *
macws_cvdisplaylink_trace_find_or_allocate(MacwsCVDisplayLinkRef display_link) {
    struct macws_cvdisplaylink_trace_slot *empty = NULL;
    for (unsigned index = 0;
         index < sizeof(g_macws_cvdisplaylink_trace_slots) /
                     sizeof(g_macws_cvdisplaylink_trace_slots[0]);
         index++) {
        struct macws_cvdisplaylink_trace_slot *slot =
            &g_macws_cvdisplaylink_trace_slots[index];
        if (slot->display_link == display_link) return slot;
        if (!slot->display_link && !empty) empty = slot;
    }
    if (empty) {
        empty->display_link = display_link;
        empty->requested_display_id = UINT32_MAX;
        atomic_store_explicit(&empty->callback_count, 0,
                              memory_order_relaxed);
    }
    return empty;
}

static MacwsCVReturn macws_cvdisplaylink_trace_callback(
    MacwsCVDisplayLinkRef display_link,
    const MacwsCVTimeStampPrefix *now,
    const MacwsCVTimeStampPrefix *output_time,
    MacwsCVOptionFlags flags_in,
    MacwsCVOptionFlags *flags_out,
    void *slot_context) {
    struct macws_cvdisplaylink_trace_slot *slot = slot_context;
    MacwsCVDisplayLinkOutputCallback callback = NULL;
    void *user_info = NULL;
    MacwsCGDirectDisplayID requested_display_id = UINT32_MAX;
    pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
    if (slot) {
        callback = slot->callback;
        user_info = slot->user_info;
        requested_display_id = slot->requested_display_id;
    }
    pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);

    unsigned long sequence = slot
        ? atomic_fetch_add_explicit(&slot->callback_count, 1,
                                    memory_order_relaxed) + 1
        : 0;
    const bool should_log = sequence <= 24 || (sequence % 600) == 0;
    const uint64_t callback_entry_host_time = should_log
        ? CVGetCurrentHostTime() : 0;
    if (should_log) {
        const uint64_t current_host_time = callback_entry_host_time;
        const uint64_t now_host_time = now ? now->hostTime : 0;
        const uint64_t output_host_time = output_time
            ? output_time->hostTime : 0;
        const MacwsCGDirectDisplayID current_display_id =
            CVDisplayLinkGetCurrentCGDisplay(display_link);
        fprintf(stderr,
            "#### CVDL-TRACE callback #%lu link=%p requested=%#x "
            "current=%#x now.host=%llu output.host=%llu current.host=%llu "
            "output-now=%lld output-current=%lld current-now=%lld "
            "now.video=%lld/%d output.video=%lld/%d refresh=%lld "
            "flags=%#llx\n",
            sequence, display_link, requested_display_id,
            current_display_id,
            (unsigned long long)now_host_time,
            (unsigned long long)output_host_time,
            (unsigned long long)current_host_time,
            (long long)macws_cvdisplaylink_tick_delta(
                output_host_time, now_host_time),
            (long long)macws_cvdisplaylink_tick_delta(
                output_host_time, current_host_time),
            (long long)macws_cvdisplaylink_tick_delta(
                current_host_time, now_host_time),
            (long long)(now ? now->videoTime : 0),
            now ? now->videoTimeScale : 0,
            (long long)(output_time ? output_time->videoTime : 0),
            output_time ? output_time->videoTimeScale : 0,
            (long long)(output_time ? output_time->videoRefreshPeriod : 0),
            (unsigned long long)flags_in);
    }

    MacwsCVReturn result = callback
        ? callback(display_link, now, output_time, flags_in, flags_out,
                   user_info)
        : 0;
    if (should_log) {
        const uint64_t callback_return_host_time = CVGetCurrentHostTime();
        fprintf(stderr,
            "#### CVDL-TRACE callback-return #%lu link=%p result=%d "
            "entry.host=%llu return.host=%llu duration.ticks=%lld\n",
            sequence, display_link, result,
            (unsigned long long)callback_entry_host_time,
            (unsigned long long)callback_return_host_time,
            (long long)macws_cvdisplaylink_tick_delta(
                callback_return_host_time, callback_entry_host_time));
    }
    return result;
}

static MacwsCVReturn CVDisplayLinkCreateWithCGDisplay_new(
    MacwsCGDirectDisplayID display_id,
    MacwsCVDisplayLinkRef *display_link_out) {
    MacwsCVReturn result = CVDisplayLinkCreateWithCGDisplay(
        display_id, display_link_out);
    if (!macws_cvdisplaylink_trace_enabled()) return result;

    MacwsCVDisplayLinkRef display_link =
        result == 0 && display_link_out ? *display_link_out : NULL;
    if (display_link) {
        pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
        struct macws_cvdisplaylink_trace_slot *slot =
            macws_cvdisplaylink_trace_find_or_allocate(display_link);
        if (slot) slot->requested_display_id = display_id;
        pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);
    }

    static _Atomic unsigned long create_count = 0;
    unsigned long sequence = atomic_fetch_add_explicit(
        &create_count, 1, memory_order_relaxed) + 1;
    void *caller = __builtin_return_address(0);
    Dl_info caller_info = {0};
    (void)dladdr(caller, &caller_info);
    MacwsCGDirectDisplayID current_display_id = display_link
        ? CVDisplayLinkGetCurrentCGDisplay(display_link) : UINT32_MAX;
    fprintf(stderr,
        "#### CVDL-TRACE create #%lu requested=%#x result=%d link=%p "
        "current=%#x caller=%p image=%s symbol=%s\n",
        sequence, display_id, result, display_link, current_display_id,
        caller, caller_info.dli_fname ?: "(unknown)",
        caller_info.dli_sname ?: "(unknown)");
    return result;
}

static MacwsCVReturn CVDisplayLinkSetOutputCallback_new(
    MacwsCVDisplayLinkRef display_link,
    MacwsCVDisplayLinkOutputCallback callback,
    void *user_info) {
    if (!macws_cvdisplaylink_trace_enabled() || !callback) {
        return CVDisplayLinkSetOutputCallback(
            display_link, callback, user_info);
    }

    pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
    struct macws_cvdisplaylink_trace_slot *slot =
        macws_cvdisplaylink_trace_find_or_allocate(display_link);
    if (slot) {
        slot->callback = callback;
        slot->user_info = user_info;
        atomic_store_explicit(&slot->callback_count, 0,
                              memory_order_relaxed);
    }
    pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);

    if (!slot) {
        fprintf(stderr,
            "#### CVDL-TRACE callback slot table full link=%p; pass-through\n",
            display_link);
        return CVDisplayLinkSetOutputCallback(
            display_link, callback, user_info);
    }

    MacwsCVReturn result = CVDisplayLinkSetOutputCallback(
        display_link, macws_cvdisplaylink_trace_callback, slot);
    fprintf(stderr,
        "#### CVDL-TRACE set-callback link=%p requested=%#x result=%d "
        "original=%p user=%p wrapper=%p\n",
        display_link, slot->requested_display_id, result,
        (void *)callback, user_info,
        (void *)macws_cvdisplaylink_trace_callback);
    if (result != 0) {
        pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
        slot->callback = NULL;
        slot->user_info = NULL;
        pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);
    }
    return result;
}

DYLD_INTERPOSE(IOConnectCallMethod_new, IOConnectCallMethod);
DYLD_INTERPOSE(IOConnectCallScalarMethod_new, IOConnectCallScalarMethod);
DYLD_INTERPOSE(IOConnectCallStructMethod_new, IOConnectCallStructMethod);
DYLD_INTERPOSE(IOConnectCallAsyncMethod_new, IOConnectCallAsyncMethod);
DYLD_INTERPOSE(IOConnectCallAsyncScalarMethod_new, IOConnectCallAsyncScalarMethod);
DYLD_INTERPOSE(IOConnectCallAsyncStructMethod_new, IOConnectCallAsyncStructMethod);
DYLD_INTERPOSE(IOConnectTrap1_new, IOConnectTrap1);
DYLD_INTERPOSE(dyld_get_active_platform_new, dyld_get_active_platform);
DYLD_INTERPOSE(CVDisplayLinkCreateWithCGDisplay_new,
               CVDisplayLinkCreateWithCGDisplay);
DYLD_INTERPOSE(CVDisplayLinkSetOutputCallback_new,
               CVDisplayLinkSetOutputCallback);

// XPC-borrow the AGX io_connect_t from macwsallocd. The helper is iOS-Apple-
// signed-equivalent so the kernel runs the full privileged UC-init (sets
// device->0x108, this->0x100, etc.) — which the chroot's macOS-userland
// IOServiceOpen can't trigger directly (RE-traced to per-UC size limit at
// IOGPUDevice::new_resource +0xff; see memory cross-image-objc-class-
// register-and-ioconnect-heap-blocker). Once borrowed, IOConnectCallMethod
// calls from the chroot run against the kernel-side UC state set by the
// helper — heap/queue/resource create all become available.
static mach_port_t macws_borrow_agx_conn_xpc(void) {
    static mach_port_t cached = MACH_PORT_NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) return;
        xpc_connection_t conn = createMach("com.macwsguide.alloc", NULL, 0);
        if (!conn) return;
        xpc_connection_set_event_handler(conn, ^(xpc_object_t e) { (void)e; });
        xpc_connection_resume(conn);
        xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(req, "op", "borrow-agx-conn");
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
        if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            const char *result = xpc_dictionary_get_string(reply, "result");
            if (result && strcmp(result, "ok") == 0) {
                cached = xpc_dictionary_copy_mach_send(reply, "connect");
            }
            fprintf(stderr, "#### borrow-agx-conn reply result=%s cached=%u\n",
                result ?: "(none)", cached);
        } else {
            fprintf(stderr, "#### borrow-agx-conn no reply\n");
        }
    });
    return cached;
}

kern_return_t IOServiceOpen_new(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect) {
    static io_service_t agxService;
    if(!agxService) {
        agxService = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
        assert(agxService != IO_OBJECT_NULL);
    }

    // BORROW path: when MACWS_AGX_BORROW_CONN=1 and the open is for the AGX
    // service, ask macwsallocd to open it on our behalf (the helper runs in
    // iOS-native context where the kernel does full UC privileged init) and
    // return the borrowed mach port as the io_connect_t. All subsequent
    // IOConnectCallMethod calls then run against the kernel-side UC state
    // set by the helper.
    if (getenv("MACWS_AGX_BORROW_CONN") && service == agxService) {
        mach_port_t borrowed = macws_borrow_agx_conn_xpc();
        if (borrowed != MACH_PORT_NULL) {
            *connect = (io_connect_t)borrowed;
            assert(iogpuClientsCount < sizeof(iogpuClients) / sizeof(iogpuClients[0]));
            iogpuClients[iogpuClientsCount++] = *connect;
            fprintf(stderr, "#### IOServiceOpen agx BORROWED connect=%u (type was %u)\n",
                *connect, type);
            return KERN_SUCCESS;
        }
        // Fallback to normal path if XPC borrow failed.
        fprintf(stderr, "#### IOServiceOpen agx BORROW failed — falling back to normal IOServiceOpen\n");
    }

    uint32_t requested_type = type;

    // RE-confirmed user-space ABI translation: macOS 13.4 IOGPU builds
    // 5|(options<<16), while iOS 16.3 accepts low type 1 or 0x21.  Remove
    // only macOS platform bit 4; preserve the caller's high-word options.
    // Native-reference LLDB captured options=0x10 and type=0x100001, and the
    // KRW probe runtime-confirmed those bits at UC+0x128 and Device+0xd8.
    type &= ~4;

    // Keep the former high-word mask as an explicit diagnostic A/B only.  It
    // is not a fix: queue-only probing shows both types can create equivalent
    // kernel queues, while the high word changes real device state.
    if (getenv("MACWS_AGX_NATIVE") && service == agxService) {
        if (getenv("MACWS_AGX_STRIP_OPEN_OPTIONS")) {
            type &= 0xFFFF;
        }
        const char *force = getenv("MACWS_AGX_FORCE_TYPE");
        if (force) {
            type = (uint32_t)strtoul(force, NULL, 0);
        }
    }

    kern_return_t result = IOServiceOpen(service, owningTask, type, connect);
    assert(iogpuClientsCount < sizeof(iogpuClients) / sizeof(iogpuClients[0]));
    if(result == KERN_SUCCESS && service == agxService) {
        iogpuClients[iogpuClientsCount++] = *connect;
        fprintf(stderr, "#### debugbydcmmc IOServiceOpen agx connect=%d type=%#x (requested=%#x)\n",
            *connect, type, requested_type);
    }
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif
