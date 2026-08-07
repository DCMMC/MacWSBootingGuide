// mac_hooks.m — part 1 of the mac_hooks.m split.
// Shared preamble, types and externs live in mac_hooks_internal.h.

@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
#import <stdarg.h>
#import "interpose.h"
#import "utils.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <pthread.h>
#import <limits.h>
#import <math.h>
#import <crt_externs.h>
#import <ptrauth.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <poll.h>
#include <execinfo.h>
#import "macws_host_protocol.h"
#import "macws_control_protocol.h"
#include "mac_hooks_internal.h"

@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
#import <stdarg.h>
#import "interpose.h"
#import "utils.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <pthread.h>
#import <limits.h>
#import <math.h>
#import <crt_externs.h>
#import <ptrauth.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <poll.h>
#include <execinfo.h>
#import "macws_host_protocol.h"
#import "macws_control_protocol.h"


bool macws_jit_trace_enabled(void) {
    return macws_runtime_diagnostics_enabled() ||
        getenv("MACWS_JIT_MPROTECT_TRACE") != NULL;
}

bool macws_kcmd_fix_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = access("/tmp/macws_kcmd_fix", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

bool macws_kcmd_wrapped_fix_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = access("/tmp/macws_kcmd_wrapped_fix", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

bool macws_cancel_completion_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = access("/tmp/macws_cancel_completion", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

bool macws_real_swapend_diagnostic_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = access("/tmp/macws_real_swapend", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

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

MacWSJITRange g_macws_jit_ranges[32];
_Atomic unsigned g_macws_jit_range_count = 0;
pthread_mutex_t g_macws_jit_state_lock = PTHREAD_MUTEX_INITIALIZER;
_Atomic unsigned g_macws_jit_active_writers = 0;
_Thread_local bool g_macws_jit_thread_writable = false;
_Atomic unsigned g_macws_jit_remap_declines = 0;
_Atomic unsigned g_macws_jit_permission_flips = 0;
_Atomic unsigned g_macws_jit_mprotect_calls = 0;
_Atomic unsigned g_macws_jit_exec_waits = 0;
_Atomic unsigned g_macws_jit_late_fetch_retries = 0;
_Atomic unsigned g_macws_jit_handler_checks = 0;
_Atomic unsigned g_macws_jit_write_faults = 0;
_Atomic unsigned g_macws_jit_dirty_restores = 0;
_Atomic bool g_macws_jit_needs_initial_rx = false;
pthread_mutex_t g_macws_jit_handler_lock = PTHREAD_MUTEX_INITIALIZER;
struct sigaction g_macws_jit_downstream_sigbus;
bool g_macws_jit_downstream_sigbus_valid = false;

// V8 reserves one 256-MiB arm64 CodeRange (16,384 pages on this device).  A
// writer scope normally touches only a handful of those pages.  Keep enough
// slots for several ranges plus duplicate-fault headroom; overflow falls back
// to restoring every recorded range RX, so it cannot leave writable code.
uintptr_t g_macws_jit_dirty_pages[MACWS_JIT_DIRTY_PAGE_CAPACITY];
_Atomic unsigned g_macws_jit_dirty_page_count = 0;
_Atomic bool g_macws_jit_dirty_page_overflow = false;
_Atomic size_t g_macws_jit_page_size = 0;

void macws_jit_ensure_exec_barrier_handler(void);
void macws_jit_set_all_permissions(int protection);

bool macws_jit_mprotect_compat_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_JIT_MPROTECT_COMPAT") ? 1 : 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

bool macws_jit_fault_write_compat_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_JIT_FAULT_WRITE_COMPAT") ? 1 : 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

bool macws_jit_range_overlaps(uintptr_t base, size_t size) {
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

void macws_jit_record_range(void *address, size_t size) {
    if (!address || address == MAP_FAILED || size == 0) return;
    // The SIGBUS handler must never perform its first getenv/cache setup.
    (void)macws_jit_fault_write_compat_enabled();
    if (atomic_load_explicit(&g_macws_jit_page_size,
                             memory_order_relaxed) == 0) {
        atomic_store_explicit(&g_macws_jit_page_size, (size_t)getpagesize(),
                              memory_order_release);
    }
    atomic_store_explicit(&g_macws_jit_needs_initial_rx, true,
                          memory_order_release);
    pthread_mutex_lock(&g_macws_jit_state_lock);
    unsigned count = atomic_load_explicit(&g_macws_jit_range_count,
                                           memory_order_relaxed);
    if (count < sizeof(g_macws_jit_ranges) / sizeof(g_macws_jit_ranges[0])) {
        g_macws_jit_ranges[count].base = (uintptr_t)address;
        g_macws_jit_ranges[count].size = size;
        atomic_store_explicit(&g_macws_jit_range_count, count + 1,
                              memory_order_release);
        if (macws_jit_trace_enabled()) {
            fprintf(stderr,
                "#### JIT-MPROTECT range[%u]=[%p,%p) "
                "source=MAP_JIT-EINVAL\n",
                count, address, (void *)((uintptr_t)address + size));
        }
    }
    pthread_mutex_unlock(&g_macws_jit_state_lock);
    macws_jit_ensure_exec_barrier_handler();
}

void macws_jit_remove_range(void *address, size_t size) {
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

bool macws_jit_pc_in_recorded_range(uintptr_t pc) {
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

bool macws_jit_make_fault_page_writable(uintptr_t fault_address) {
    size_t page_size = atomic_load_explicit(&g_macws_jit_page_size,
                                            memory_order_acquire);
    if (page_size == 0 || (page_size & (page_size - 1)) != 0 ||
        !macws_jit_pc_in_recorded_range(fault_address)) {
        return false;
    }
    uintptr_t page = fault_address & ~(uintptr_t)(page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, page_size, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) return false;

    unsigned slot = atomic_fetch_add_explicit(&g_macws_jit_dirty_page_count,
                                               1, memory_order_relaxed);
    if (slot < MACWS_JIT_DIRTY_PAGE_CAPACITY) {
        g_macws_jit_dirty_pages[slot] = page;
        atomic_thread_fence(memory_order_release);
    } else {
        atomic_store_explicit(&g_macws_jit_dirty_page_overflow, true,
                              memory_order_release);
    }
    atomic_fetch_add_explicit(&g_macws_jit_write_faults, 1,
                              memory_order_relaxed);
    return true;
}

void macws_jit_restore_dirty_pages(void) {
    unsigned count = atomic_load_explicit(&g_macws_jit_dirty_page_count,
                                          memory_order_acquire);
    bool overflow = atomic_load_explicit(&g_macws_jit_dirty_page_overflow,
                                         memory_order_acquire);
    unsigned bounded = count < MACWS_JIT_DIRTY_PAGE_CAPACITY
        ? count : MACWS_JIT_DIRTY_PAGE_CAPACITY;
    size_t page_size = atomic_load_explicit(&g_macws_jit_page_size,
                                            memory_order_acquire);

    if (overflow || page_size == 0) {
        macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
    } else {
        atomic_thread_fence(memory_order_acquire);
        for (unsigned i = 0; i < bounded; i++) {
            uintptr_t page = g_macws_jit_dirty_pages[i];
            kern_return_t kr = vm_protect(mach_task_self(), page, page_size,
                                          false,
                                          VM_PROT_READ | VM_PROT_EXECUTE);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr,
                    "#### JIT-FAULT-WRITE restore FAIL page=%p kr=%#x\n",
                    (void *)page, kr);
                // A failed page restore is a W^X invariant failure.  Restore
                // every CodeRange rather than allowing that page to stay RW.
                macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
                break;
            }
        }
    }

    atomic_store_explicit(&g_macws_jit_dirty_page_count, 0,
                          memory_order_release);
    atomic_store_explicit(&g_macws_jit_dirty_page_overflow, false,
                          memory_order_release);
    unsigned restores = atomic_fetch_add_explicit(
        &g_macws_jit_dirty_restores, 1, memory_order_relaxed) + 1;
    if (macws_jit_trace_enabled() &&
        (restores <= 32 || (restores % 1024) == 0)) {
        fprintf(stderr,
            "#### JIT-FAULT-WRITE restore #%u pages=%u overflow=%d "
            "write_faults=%u exec_waits=%u late_retries=%u\n",
            restores, bounded, overflow,
            atomic_load_explicit(&g_macws_jit_write_faults,
                                 memory_order_relaxed),
            atomic_load_explicit(&g_macws_jit_exec_waits,
                                 memory_order_relaxed),
            atomic_load_explicit(&g_macws_jit_late_fetch_retries,
                                 memory_order_relaxed));
    }
}

void macws_jit_forward_sigbus(int signo, siginfo_t *info,
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

void macws_jit_exec_barrier_sigbus(int signo, siginfo_t *info,
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

    // iOS has no usable APRR/MAP_JIT contract for this macOS process.  In the
    // page-fault adapter an authorized V8 writer therefore starts with every
    // CodeRange page RX.  Its first store to a page lands here as a data abort;
    // make only that 16-KiB page RW and remember it for the last writer's RX
    // restore.  An instruction abort has si_addr == PC and must take the fetch
    // barrier below instead.  The writer executes this handler from signed
    // Electron __TEXT, so accepting a JIT-resident PC would hide a real fault.
    if (macws_jit_fault_write_compat_enabled() && signo == SIGBUS && info &&
        g_macws_jit_thread_writable && (uintptr_t)info->si_addr != pc &&
        !macws_jit_pc_in_recorded_range(pc) &&
        macws_jit_make_fault_page_writable((uintptr_t)info->si_addr)) {
        return;
    }

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

void macws_jit_ensure_exec_barrier_handler(void) {
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
        if (sigaction(SIGBUS, &barrier, NULL) == 0 &&
            macws_jit_trace_enabled()) {
            fprintf(stderr,
                "#### JIT-MPROTECT execution barrier installed "
                "(W^X fetch-wait compatibility)\n");
        }
    }
    pthread_mutex_unlock(&g_macws_jit_handler_lock);
}

void macws_jit_set_all_permissions(int protection) {
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
    if (macws_jit_trace_enabled()) {
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

// Diagnostic-only ObjC method/IMP map for comparing the real macOS 13.4 AGX
// command producer with the iOS 16.3 producer.  This does not swizzle or alter
// any method.  It is armed by MACWS_AGX_DUMP_METHODS=1 or the one-shot
// /private/tmp/macws_agx_dump_methods sentinel and writes inside the chroot.
BOOL macws_agx_method_map_class(const char *name) {
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

void macws_agx_dump_method_list(int fd, Class cls, const char *kind) {
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

void macws_dump_agx_method_map(void) {
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

// Diagnostic-only producer trace.  Trace both layers which can reserve KCMD
// storage without changing their arguments or return values.  The public AGX
// method does not cover Chromium's subtype-2 records: a runtime run reached
// repeated IOGPU 0x102/0x103 completions while that method recorded no target
// sized calls.  IOGPUMetalCommandBuffer's private underscored method is the
// base allocator observed in production samples, so hook it independently.
// Armed only by /private/tmp/macws_agx_trace_reserve.
macws_agx_reserve_fn g_macws_agx_orig_public_reserve = NULL;
macws_agx_reserve_fn g_macws_agx_orig_base_reserve = NULL;
_Atomic unsigned g_macws_agx_reserve_sequence = 0;

void macws_agx_log_reserve(const char *layer, id self, uint64_t size) {
    // The full Chromium trace reaches the first failing Aquarium submission
    // after hundreds of smaller compute/render reservations.  Counting those
    // first made the producer invisible before the old 256-entry cap.  The
    // submitted record is 0x418 bytes with a 0x3c0 payload-size field.  Include
    // a bounded margin around that family because the private allocator's
    // argument need not include the common header/padding.
    BOOL interesting = size >= 0x300 && size <= 0x500;
    unsigned sequence = interesting
        ? atomic_fetch_add(&g_macws_agx_reserve_sequence, 1) + 1 : 0;
    if (interesting && sequence <= 64) {
        void *frames[12] = {0};
        int frame_count = backtrace(frames, 12);
        fprintf(stderr,
            "#### AGX-RESERVE-DIAG #%u layer=%s self=%p size=%#llx "
            "frames=%d\n",
            sequence, layer, self, (unsigned long long)size, frame_count);
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
}

void *macws_agx_trace_public_reserve(id self, SEL cmd,
                                             uint64_t size) {
    macws_agx_log_reserve("AGX-public", self, size);
    return g_macws_agx_orig_public_reserve(self, cmd, size);
}

void *macws_agx_trace_base_reserve(id self, SEL cmd, uint64_t size) {
    macws_agx_log_reserve("IOGPU-base", self, size);
    return g_macws_agx_orig_base_reserve(self, cmd, size);
}

void macws_install_agx_reserve_trace(void) {
    Class public_cls = objc_getClass("AGXG13GFamilyCommandBuffer");
    SEL public_selector =
        sel_registerName("reserveKernelCommandBufferSpace:");
    Method public_method = public_cls
        ? class_getInstanceMethod(public_cls, public_selector) : NULL;
    if (public_method) {
        IMP current = method_getImplementation(public_method);
        if (current != (IMP)macws_agx_trace_public_reserve) {
            g_macws_agx_orig_public_reserve =
                (macws_agx_reserve_fn)current;
            method_setImplementation(public_method,
                (IMP)macws_agx_trace_public_reserve);
            fprintf(stderr,
                "#### AGX-RESERVE-DIAG installed layer=AGX-public "
                "class=%p original=%p trace=%p\n",
                (void *)public_cls, (void *)current,
                (void *)macws_agx_trace_public_reserve);
        }
    } else {
        fprintf(stderr,
            "#### AGX-RESERVE-DIAG install failed layer=AGX-public: "
            "method unavailable\n");
    }

    Class base_cls = objc_getClass("IOGPUMetalCommandBuffer");
    SEL base_selector =
        sel_registerName("_reserveKernelCommandBufferSpace:");
    Method base_method = base_cls
        ? class_getInstanceMethod(base_cls, base_selector) : NULL;
    if (base_method) {
        IMP current = method_getImplementation(base_method);
        if (current != (IMP)macws_agx_trace_base_reserve) {
            g_macws_agx_orig_base_reserve = (macws_agx_reserve_fn)current;
            method_setImplementation(base_method,
                (IMP)macws_agx_trace_base_reserve);
            fprintf(stderr,
                "#### AGX-RESERVE-DIAG installed layer=IOGPU-base "
                "class=%p original=%p trace=%p\n",
                (void *)base_cls, (void *)current,
                (void *)macws_agx_trace_base_reserve);
        }
    } else {
        fprintf(stderr,
            "#### AGX-RESERVE-DIAG install failed layer=IOGPU-base: "
            "method unavailable\n");
    }
}

BOOL macws_glass_blur_ab_is_opaque(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

void macws_glass_blur_ab_draw(id self, SEL _cmd, CGRect dirty) {
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

void macws_glass_blur_ab_find_effect(id view, Class effectClass,
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

Class macws_glass_blur_ab_stripe_class(void) {
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

void macws_glass_blur_ab_attempt(unsigned attempt) {
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

void macws_install_glass_blur_ab_if_requested(void) {
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
_Thread_local uint64_t g_macws_agx_initfull_len = 0;

// Armed only for WindowServer's coexistence mode after the exact macOS 13.4
// kern_SwapEnd callsite has been verified. IOConnectCallStructMethod_new uses
// this to translate physical-panel SwapEnd into SwapCancel while leaving the
// rest of Apple's kern_SwapEnd cleanup intact.
_Atomic int g_macws_iomfb_coexist_swap_cancel = 0;
void macws_install_quartzcore_frame_info_hook(
    const struct mach_header *header);
void macws_install_quartzcore_coexist_pacing_hooks(
    const struct mach_header *header);
uint32_t macws_coexist_completion_pace_us(void);
uint32_t macws_coexist_activity_pace_us(uint32_t idle_pace_us);
uint32_t macws_coexist_wait_for_completion_slot(uint32_t interval_us);
IOReturn (*g_macws_orig_iomfb_swap_end)(void *framebuffer) = NULL;
IOReturn MacwsIOMobileFramebufferSwapEnd_new(void *framebuffer);

// IOSurface
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
extern size_t IOSurfaceGetBytesPerElementOfPlane(IOSurfaceRef surface,
                                                 size_t plane);
extern size_t IOSurfaceGetElementWidthOfPlane(IOSurfaceRef surface,
                                              size_t plane);
extern size_t IOSurfaceGetElementHeightOfPlane(IOSurfaceRef surface,
                                               size_t plane);
extern size_t IOSurfaceGetSizeOfPlane(IOSurfaceRef surface, size_t plane);
extern size_t IOSurfaceGetNumberOfComponentsOfPlane(IOSurfaceRef surface,
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
size_t macws_IOSurfaceGetBytesPerElementOfPlane(IOSurfaceRef surface,
                                                size_t plane);
size_t macws_IOSurfaceGetElementWidthOfPlane(IOSurfaceRef surface,
                                             size_t plane);
size_t macws_IOSurfaceGetElementHeightOfPlane(IOSurfaceRef surface,
                                              size_t plane);
size_t macws_IOSurfaceGetSizeOfPlane(IOSurfaceRef surface, size_t plane);
size_t macws_IOSurfaceGetNumberOfComponentsOfPlane(IOSurfaceRef surface,
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
uint64_t macws_make_mem_entry_xpc(uint64_t size, uint64_t *out_size) {
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
int isJITEnabled(void);

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
#endif

// offsets hardcoded for macOS 13.4
// IOMobileFramebuffer`kern_SwapEnd + 36
// IOMobileFramebuffer`kern_SwapEnd + 0x30: expected
// `bl IOConnectCallStructMethod` callsite. We only READ this instruction to
// validate the hardcoded ABI before arming the coexistence SwapCancel
// translation; it must not be NOPed because SwapBegin's DCP object then has no
// matching present/cancel operation.
// SkyLight`WS::Displays::CAWSManager::CAWSManager() + 560
#if FORCE_SW_RENDER
// SkyLight`WSSystemCanCompositeWithMetal::once
// #define OFF_SkyLight_WSSystemCanCompositeWithMetal 0x1d72b148
#endif
// Metal`MTLFragmentReflectionReader::deserialize + 364
// Metal`MTLInputStageReflectionReader::deserialize + 956
// QuartzCore`CABackingStorePrepareUpdates_ + 812.  At this site the original
// `cbz w21, +852` sends every window backing store down the NON-accelerated path
// (w21==0 because the format/capability arg w23==2 has bit 8 clear): it allocates a
// CPU `CA::Render::Shmem::new_bitmap` instead of an IOSurface, so drawn content never
// becomes a GPU surface WindowServer can composite -> window CONTENT stays BLACK
// (chrome renders via a different path).  Forcing this branch to `b +840` takes the
// accelerated path (`mov w8,#1; str w8,[sp,#0x68]`), so create_iosurface() runs and an
// IOSurface-backed buffer is allocated -> content renders.  Verified live with lldb:
// patching this single instruction makes create_iosurface + IOSurfaceCreate fire.

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
malloc_zone_t *macws_synth_scratch_zone(void) {
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
BOOL is_process_running(const char *name) {
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


#if __arm64e__
#else
#endif

#include <mach-o/nlist.h>
#include <mach-o/reloc.h>

// Forward declaration for the targeted HIServices main-image import repair
// below. The ordinary DYLD_INTERPOSE tuple remains the preferred path; the
// authenticated GOT repair is needed only for Ventura's prebuilt arm64e XPC
// service executable, whose _xpc_main chained bind is not rewritten by the
// iPadOS 16 dyld.
void macws_xpc_main(xpc_connection_handler_t handler);

// Repair __got / __auth_got slots via indirect symbol table + LC_SYMTAB. Used
// for dlopen'd DSC-bound images that have no LC_DYLD_CHAINED_FIXUPS (because
// the cache builder removed it; cache pre-filled __got at cache-prep time).
// When loaded standalone, the pre-fill is gone — but the indirect symbol
// table still references LC_SYMTAB entries that name each slot's target.
void macws_repair_got_via_symtab(const struct mach_header_64 *header,
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
    BOOL diagnostics = macws_runtime_diagnostics_enabled();
    const char *program = getprogname();
    BOOL hiservicesMain = program &&
        strcmp(program, "com.apple.hiservices-xpcservice") == 0 &&
        header == (const struct mach_header_64 *)_dyld_get_image_header(0);
    int64_t linkedit_runtime_base = (int64_t)linkedit_vmaddr + slide - (int64_t)linkedit_fileoff;
    const struct nlist_64 *symtab    = (const struct nlist_64 *)(linkedit_runtime_base + st->symoff);
    const char            *strtab    = (const char           *)(linkedit_runtime_base + st->stroff);
    const uint32_t        *indirect  = (const uint32_t        *)(linkedit_runtime_base + dt->indirectsymoff);

    if (diagnostics) {
        fprintf(stderr, "#### MACWS_GOT %s: symtab=%u syms, strtab=%u bytes, indirect=%u entries\n",
            image_name, st->nsyms, st->strsize, dt->nindirectsyms);
    }

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
            if (diagnostics) {
                fprintf(stderr, "####   sect[%u] %s,%s type=%u entries=%u indirect_start=%u auth=%d\n",
                    k, sc->segname, sn->sectname, type, entries,
                    indirect_start, is_auth);
            }
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
                if (strstr(image_name, "AGXMetal13_3") &&
                    !strcmp(lookup, "objc_alloc")) {
                    resolved = (void *)objc_alloc_trace;
                    force_override = 1;
                }
                // RE-confirmed in Ventura 13.4's actual arm64e
                // com.apple.hiservices-xpcservice: main+0x4c14 calls the
                // _xpc_main auth stub, whose __DATA_CONST,__auth_got slot is
                // +0x3f8 (key=IA, addrDiv=1, diversity=0). iPadOS 16 dyld
                // leaves that slot bound to stock libxpc despite the static
                // interpose tuple. Stock xpc_main rejects this deliberately
                // freestanding root launchd job with "An XPC Service cannot
                // be run directly", so the service main thread exits and
                // AppKit clients receive Connection invalid. Rebind the
                // symbolically identified main-image slot to the same real
                // listener adapter; the generic auth-GOT signer below uses
                // the exact slot-address discriminator expected by braa.
                if (hiservicesMain && !strcmp(lookup, "xpc_main")) {
                    resolved = (void *)macws_xpc_main;
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
                            "IOSurfaceGetWidthOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetWidthOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetHeightOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetHeightOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetBytesPerRowOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetBytesPerRowOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetBytesPerElementOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetBytesPerElementOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetElementWidthOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetElementWidthOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetElementHeightOfPlane")) {
                    resolved =
                        (void *)macws_IOSurfaceGetElementHeightOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup, "IOSurfaceGetSizeOfPlane")) {
                    resolved = (void *)macws_IOSurfaceGetSizeOfPlane;
                    force_override = 1;
                } else if (strstr(image_name, "AGXMetal13_3") &&
                           !strcmp(lookup,
                            "IOSurfaceGetNumberOfComponentsOfPlane")) {
                    resolved = (void *)
                        macws_IOSurfaceGetNumberOfComponentsOfPlane;
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
                    if (diagnostics && (patched < 12 || force_override)) {
                        fprintf(stderr, "####   bind[%d] %s -> %p (slot=%p auth=%d%s)\n",
                            patched, name, resolved, slot, is_auth,
                            force_override ? " FORCE" : "");
                    }
                    // Dump IOGPU-related symbols specifically — these are the
                    // pool allocator helpers we need to know about.
                    if (diagnostics &&
                        (strstr(name, "IOGPU") || strstr(name, "iogpu") ||
                        strstr(name, "MetalCommon") || strstr(name, "PoolAlloc") ||
                        strstr(name, "Pool") || strstr(name, "Heap"))) {
                        fprintf(stderr, "####   IOGPU-CRITICAL %s = %p (slot=%p auth=%d)\n",
                            name, resolved, slot, is_auth);
                    }
                }
            }
        }
    }
    if (diagnostics) {
        fprintf(stderr, "#### MACWS_GOT %s: indirect_slots=%d patched=%d failed=%d\n",
            image_name, total_indirect_slots, patched, failed);
    }
}

void macws_walk_chained_fixups(const struct mach_header_64 *header,
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
PrepareForUse_t orig_skylight_prepare_for_use = NULL;
int hooked_skylight_prepare_for_use(void *self, void *ctx,
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
StartCompositeForDisplayStream_t orig_skylight_start_composite_ds = NULL;
int hooked_skylight_start_composite_ds(void *self, id target0, id target1,
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
void *orig_skylight_start_composite_wscd_ref = NULL;
// SkyLight `MetalContext::StartComposite(MTLTexture*, MTLLoadAction,
// MTLStoreAction)` — texture variant, called from `SLCADisplay::
// render_update` (the path that drives the assert in MetalContext.mm:411).
//
// SAME pop-on-bail invariant restorer as the WSCD variant.
StartComposite_MTLTex_t orig_skylight_start_composite_mtltex = NULL;

// SkyLight `std::deque<RenderState>::pop_back()` symbol at static 0x186637f84.
// `_state_stack` is the std::deque<RenderState> embedded as the FIRST member
// of MetalContext, so passing `MetalContext*` to pop_back is correct (same
// pointer the C++ symbol expects). MUST be resolved at runtime — the chroot
// SkyLight UUID differs from our static-analysis copy.
StateStack_pop_back_t orig_skylight_state_stack_pop_back = NULL;

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
void *macws_deque_slot_ptr(void *self, uint64_t idx) {
    if (!self) return NULL;
    uintptr_t d = (uintptr_t)self;
    void **bucket = *(void ***)(d + 8);
    if (!bucket) return NULL;
    uint64_t block_idx = idx / 23;
    uint8_t *block = (uint8_t *)bucket[block_idx];
    if (!block || (uintptr_t)block < 0x1000) return NULL;
    return block + (idx % 23) * 0xb0;
}

int macws_pop_on_startcomp_bail(void *self, uint64_t before, int rv) {
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
                BOOL diagnostics = macws_runtime_diagnostics_enabled();
                @synchronized(g_wscd_tex) {
                    if (diagnostics) before = g_wscd_tex.count;
                    if (g_wscd_tex[key] == tex) {
                        [g_wscd_tex removeObjectForKey:key];
                        consumed = YES;
                    }
                    if (diagnostics) after = g_wscd_tex.count;
                }
                if (consumed && diagnostics) {
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

int hooked_skylight_start_composite_mtltex(void *self, id texture,
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
EndCurrentComposite_t orig_skylight_end_current_composite = NULL;
void hooked_skylight_end_current_composite(void *self, bool synchronize) {
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
EndUpdate_t orig_skylight_end_update = NULL;
void hooked_skylight_end_update(void *self, bool waitUntilSubmitted) {
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
WSCompositeDestinationCreateWithMetalTexture_t orig_skylight_wsccd_with_tex = NULL;
void *hooked_skylight_wsccd_with_tex(id texture, void *ctx, void *protectionOptions,
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
        BOOL diagnostics = macws_runtime_diagnostics_enabled();
        @synchronized(m) {
            m[[NSValue valueWithPointer:wscd]] = texture;
            if (diagnostics) count = m.count;
        }
        static _Atomic unsigned long insert_count = 0;
        unsigned long n = diagnostics
            ? atomic_fetch_add(&insert_count, 1) + 1 : 0;
        if (n && (n <= 24 || (n % 600) == 0)) {
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
MetalContext_StopCapture_t orig_metalcontext_stop_capture = NULL;
void hooked_metalcontext_stop_capture(void *this) {
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

void install_skylight_prepare_for_use_tolerate_nil_hook(const void *header) {
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

// The macOS LaunchServices database cannot successfully seed CoreTypes.bundle
// while running inside the iOS-hosted chroot (`lsregister -f` returns -50).
// UniformTypeIdentifiers consequently returns nil for some types that are
// nevertheless declared by the installed macOS CoreTypes bundle.  Finder's
// VoiceShortcut provider requests three such declarations while constructing
// its quick-action list and NSArray then raises when one of those entries is
// nil.
//
// RE-confirmed on the installed macOS 13.4 frameworks:
//   +[UTType typeWithIdentifier:] tail-calls
//   _UTTypeGetForIdentifier(identifier, false).  The hidden true branch asks
//   +[UTTypeRecord typeRecordWithPotentiallyUndeclaredIdentifier:] and turns
//   the resulting real record into a UTType with
//   +[UTType _typeWithTypeRecord:detachTypeRecord:findConstant:].
//
// Preserve the normal lookup first.  The compatibility path is restricted to
// identifiers explicitly present in the installed CoreTypes Info.plist, then
// follows that framework-owned record/conversion path.  Unknown identifiers
// remain nil; this is not a blanket non-nil stub.
MacWSUTTypeWithIdentifierFn g_macws_orig_uttype_with_identifier;
MacWSCoreTypesIdentifierTable *g_macws_coretypes_identifiers;
_Thread_local bool g_macws_uttype_fallback_active;

void macws_destroy_coretypes_identifiers(
        MacWSCoreTypesIdentifierTable *table) {
    if (!table) return;
    for (size_t index = 0; index < table->count; index++)
        free(table->values[index]);
    free(table->values);
    free(table);
}

bool macws_append_coretypes_identifier(
        MacWSCoreTypesIdentifierTable *table, CFStringRef identifier) {
    if (!table || !identifier) return false;
    CFIndex length = CFStringGetLength(identifier);
    CFIndex maximum = CFStringGetMaximumSizeForEncoding(
        length, kCFStringEncodingUTF8);
    if (maximum < 0 || maximum > 4095) return false;
    char *bytes = calloc((size_t)maximum + 1, 1);
    if (!bytes || !CFStringGetCString(identifier, bytes,
                                       maximum + 1,
                                       kCFStringEncodingUTF8)) {
        free(bytes);
        return false;
    }
    for (size_t index = 0; index < table->count; index++) {
        if (strcmp(table->values[index], bytes) == 0) {
            free(bytes);
            return true;
        }
    }
    if (table->count == table->capacity) {
        size_t capacity = table->capacity ? table->capacity * 2 : 64;
        char **values = realloc(table->values,
                                capacity * sizeof(*values));
        if (!values) {
            free(bytes);
            return false;
        }
        table->values = values;
        table->capacity = capacity;
    }
    table->values[table->count++] = bytes;
    return true;
}

bool macws_coretypes_contains_identifier(NSString *identifier) {
    MacWSCoreTypesIdentifierTable *table = g_macws_coretypes_identifiers;
    if (!table || !identifier) return false;
    CFStringRef value = (__bridge CFStringRef)identifier;
    CFIndex maximum = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(value), kCFStringEncodingUTF8);
    if (maximum < 0 || maximum > 4095) return false;
    char stackBytes[256] = {0};
    char *bytes = maximum < (CFIndex)sizeof(stackBytes)
        ? stackBytes : calloc((size_t)maximum + 1, 1);
    if (!bytes) return false;
    bool converted = CFStringGetCString(value, bytes, maximum + 1,
                                         kCFStringEncodingUTF8);
    bool found = false;
    if (converted) {
        for (size_t index = 0; index < table->count; index++) {
            if (strcmp(table->values[index], bytes) == 0) {
                found = true;
                break;
            }
        }
    }
    if (bytes != stackBytes) free(bytes);
    return found;
}

id macws_uttype_with_identifier(id cls, SEL cmd,
                                        NSString *identifier) {
    id result = g_macws_orig_uttype_with_identifier
        ? g_macws_orig_uttype_with_identifier(cls, cmd, identifier) : nil;
    if (result || !identifier || g_macws_uttype_fallback_active ||
        !g_macws_coretypes_identifiers ||
        !macws_coretypes_contains_identifier(identifier)) {
        return result;
    }

    Class recordClass = objc_getClass("UTTypeRecord");
    Class typeClass = objc_getClass("UTType");
    SEL recordSelector =
        sel_registerName("typeRecordWithPotentiallyUndeclaredIdentifier:");
    SEL typeSelector =
        sel_registerName("_typeWithTypeRecord:detachTypeRecord:findConstant:");
    if (!recordClass || !typeClass ||
        !class_respondsToSelector(object_getClass(recordClass),
                                  recordSelector) ||
        !class_respondsToSelector(object_getClass(typeClass), typeSelector)) {
        return nil;
    }

    g_macws_uttype_fallback_active = true;
    id record = ((id (*)(id, SEL, id))objc_msgSend)(
        recordClass, recordSelector, identifier);
    if (record) {
        result = ((id (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(
            typeClass, typeSelector, record, YES, NO);
    }
    g_macws_uttype_fallback_active = false;

    if (result && macws_runtime_diagnostics_enabled()) {
        char identifierBytes[256] = {0};
        CFStringGetCString((__bridge CFStringRef)identifier,
                           identifierBytes, sizeof(identifierBytes),
                           kCFStringEncodingUTF8);
        fprintf(stderr,
                "#### MACWS_UTTYPE restored CoreTypes declaration '%s'\n",
                identifierBytes[0] ? identifierBytes : "(non-UTF8)");
    }
    return result;
}

MacWSCoreTypesIdentifierTable *
macws_copy_coretypes_identifiers(void) {
    static const char path[] =
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist";
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat status = {0};
    if (fstat(fd, &status) != 0 || status.st_size <= 0 ||
        status.st_size > 1024 * 1024) {
        close(fd);
        return NULL;
    }
    size_t length = (size_t)status.st_size;
    UInt8 *bytes = malloc(length);
    if (!bytes) {
        close(fd);
        return NULL;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, bytes + offset, length - offset);
        if (count > 0) {
            offset += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    close(fd);
    if (offset != length) {
        free(bytes);
        return NULL;
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes,
                                  (CFIndex)length);
    free(bytes);
    if (!data) return NULL;
    CFErrorRef error = NULL;
    CFPropertyListRef root = CFPropertyListCreateWithData(
        kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, &error);
    CFRelease(data);
    if (error) CFRelease(error);
    if (!root || CFGetTypeID(root) != CFDictionaryGetTypeID()) {
        if (root) CFRelease(root);
        return NULL;
    }

    // Do not retain the parsed CFString objects in a CFSet. Runtime-confirmed
    // in Ventura locationd PID 23350 (locationd-2026-08-05-115107.ips):
    // CFSetAddValue reached CFHash and faulted with SIGBUS while hashing one of
    // these cross-image property-list strings. Convert declarations to owned
    // UTF-8 bytes while the plist is alive; exact strcmp lookup preserves the
    // allow-list invariant without crossing CoreFoundation hash callbacks.
    MacWSCoreTypesIdentifierTable *identifiers =
        calloc(1, sizeof(*identifiers));
    CFStringRef identifierKey = CFStringCreateWithCString(
        kCFAllocatorDefault, "UTTypeIdentifier", kCFStringEncodingUTF8);
    static const char *declarationNames[] = {
        "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
    };
    if (!identifiers || !identifierKey) {
        macws_destroy_coretypes_identifiers(identifiers);
        if (identifierKey) CFRelease(identifierKey);
        CFRelease(root);
        return NULL;
    }
    for (size_t nameIndex = 0;
         nameIndex < sizeof(declarationNames) / sizeof(declarationNames[0]);
         nameIndex++) {
        CFStringRef declarationKey = CFStringCreateWithCString(
            kCFAllocatorDefault, declarationNames[nameIndex],
            kCFStringEncodingUTF8);
        CFTypeRef value = declarationKey
            ? CFDictionaryGetValue((CFDictionaryRef)root, declarationKey)
            : NULL;
        if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
            CFArrayRef declarations = (CFArrayRef)value;
            CFIndex declarationCount = CFArrayGetCount(declarations);
            for (CFIndex index = 0; index < declarationCount; index++) {
                CFTypeRef declaration = CFArrayGetValueAtIndex(
                    declarations, index);
                if (!declaration ||
                    CFGetTypeID(declaration) != CFDictionaryGetTypeID())
                    continue;
                CFTypeRef identifier = CFDictionaryGetValue(
                    (CFDictionaryRef)declaration, identifierKey);
                if (identifier &&
                    CFGetTypeID(identifier) == CFStringGetTypeID()) {
                    if (!macws_append_coretypes_identifier(
                            identifiers, (CFStringRef)identifier)) {
                        CFRelease(declarationKey);
                        CFRelease(identifierKey);
                        CFRelease(root);
                        macws_destroy_coretypes_identifiers(identifiers);
                        return NULL;
                    }
                }
            }
        }
        if (declarationKey) CFRelease(declarationKey);
    }
    CFRelease(identifierKey);
    CFRelease(root);
    if (identifiers->count == 0) {
        macws_destroy_coretypes_identifiers(identifiers);
        return NULL;
    }
    return identifiers;
}

void macws_install_uttype_coretypes_compatibility(void) {
    static _Atomic bool installed = false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&installed, &expected, true)) return;

    MacWSCoreTypesIdentifierTable *identifiers =
        macws_copy_coretypes_identifiers();

    Class typeClass = objc_getClass("UTType");
    Method method = typeClass
        ? class_getClassMethod(typeClass, sel_registerName("typeWithIdentifier:"))
        : NULL;
    if (!method || !identifiers) {
        macws_destroy_coretypes_identifiers(identifiers);
        atomic_store(&installed, false);
        return;
    }

    g_macws_coretypes_identifiers = identifiers;
    g_macws_orig_uttype_with_identifier =
        (MacWSUTTypeWithIdentifierFn)method_getImplementation(method);
    method_setImplementation(method, (IMP)macws_uttype_with_identifier);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS_UTTYPE installed CoreTypes compatibility (%lu IDs)\n",
                (unsigned long)g_macws_coretypes_identifiers->count);
    }
}

// dyld invokes add-image callbacks while Objective-C realization for the new
// image is still in flight.  Runtime-confirmed on the device by
// bash-2026-07-31-110902.ips: parsing the plist synchronously from that
// callback reached _NSIsNSString -> object_getMethodImplementation and trapped
// with a PAC DA fault before bash main().  The compatibility is only consumed
// by GUI applications, so enqueue the real Foundation/UTType work onto the
// application main queue after image initialization has unwound. The deferred
// worker intentionally uses POSIX I/O plus CoreFoundation's C property-list
// APIs: pbs-2026-07-31-112112.ips proved that even a later
// +[NSDictionary dictionaryWithContentsOfFile:] still authenticates a broken
// arm64e constant-NSString bridge in this chroot. This fixes both invariants;
// it does not bypass the UTType lookup.
void macws_schedule_uttype_coretypes_compatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            macws_install_uttype_coretypes_compatibility();
        });
    });
}

// Ventura Maps opts the shared MKLocationManager into Mac CoreWLAN monitoring
// immediately before creating the singleton:
//
//   RE-confirmed in Maps arm64e at +0x378d94..+0x378da8:
//     ldr class_MKLocationManager
//     mov w2, #1
//     objc_msgSend("setCanMonitorWiFiStatus:")
//     objc_msgSend("sharedLocationManager")
//
// That platform declaration is invalid inside the iPad chroot: there is no
// macOS CWFInterface even though macwslocationd supplies real iPad CoreLocation
// fixes to Ventura locationd. Runtime-confirmed in Maps PID 7109: the
// MKLocationManager at the availability check had _wifiObserver (ivar +0x148)
// == nil. MapKit then treated the absent observer as Wi-Fi disabled and emitted
// MKLocationErrorDomain code 4 before Maps registered as a location client.
//
// Use MapKit's own platform-capability setter to declare that this process
// cannot monitor *Mac CoreWLAN*. This is deliberately upstream of the
// availability check: authorization, restricted/denied status, provider
// readiness, and location delivery all continue through unmodified MapKit and
// CoreLocation paths. It does not fabricate Wi-Fi state or force an availability
// result.
MacWSMKSetCanMonitorWiFiFn g_macws_mk_set_can_monitor_wifi = NULL;

void macws_mk_set_can_monitor_wifi(id self, SEL command,
                                          BOOL requested) {
    (void)requested;
    MacWSMKSetCanMonitorWiFiFn original = g_macws_mk_set_can_monitor_wifi;
    if (original) original(self, command, NO);
}

bool macws_install_maps_location_capability_adapter(void) {
    static _Atomic bool installed = false;
    if (atomic_load_explicit(&installed, memory_order_acquire)) return true;
    const char *program = getprogname();
    if (!program || strcmp(program, "Maps") != 0) return true;

    Class managerClass = objc_getClass("MKLocationManager");
    SEL selector = sel_registerName("setCanMonitorWiFiStatus:");
    Method method = managerClass
        ? class_getClassMethod(managerClass, selector) : NULL;
    if (!method) return false;

    IMP current = method_getImplementation(method);
    if (current != (IMP)macws_mk_set_can_monitor_wifi) {
        g_macws_mk_set_can_monitor_wifi =
            (MacWSMKSetCanMonitorWiFiFn)current;
        method_setImplementation(method,
                                 (IMP)macws_mk_set_can_monitor_wifi);
    }
    atomic_store_explicit(&installed, true, memory_order_release);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS MAPS location capability: CoreWLAN monitoring "
                "disabled; Ventura CoreLocation provider remains authoritative\n");
    }
    return true;
}

void macws_schedule_maps_location_capability_adapter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (macws_install_maps_location_capability_adapter()) return;
            // The add-image callback precedes Objective-C realization on some
            // Ventura images. One bounded retry runs after that notification
            // has unwound, still before normal application interaction.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                (void)macws_install_maps_location_capability_adapter();
            });
        });
    });
}

BOOL macws_macho_uuid_matches(const struct mach_header_64 *header,
                                     const uint8_t expected[16]);

// Diagnostic only. Finder and iconservicesagent currently terminate after a
// real CoreServicesInternal FileCache/CFURL ownership cycle recursively enters
// _FileCacheFinalize until the stack guard. The crash report loses the object
// identity that created the cycle, and LLDB cannot install the shared-cache
// breakpoint before the first finalize call on this dyld build. Hook the exact
// Ventura 13.4 function only under an explicit per-process environment flag,
// preserving its behavior while recording the cache identities and contents.
// This is evidence collection, not a release/abort bypass or a production fix.
MacWSFileCacheFinalizeFn macws_filecache_finalize_original = NULL;
_Thread_local unsigned macws_filecache_finalize_depth = 0;

void macws_filecache_finalize_diagnostic(const void *cache) {
    unsigned depth = ++macws_filecache_finalize_depth;
    if (depth <= 64) {
        uintptr_t words[12] = {};
        size_t allocation = cache ? malloc_size(cache) : 0;
        size_t readable = allocation < sizeof(words) ? allocation
                                                      : sizeof(words);
        if (cache && readable) memcpy(words, cache, readable);
        dprintf(STDERR_FILENO,
            "MACWS-FILECACHE depth=%u cache=%p malloc=%zu caller=%p "
            "q0=%#lx q1=%#lx q2=%#lx q3=%#lx q4=%#lx q5=%#lx "
            "q6=%#lx q7=%#lx q8=%#lx q9=%#lx q10=%#lx q11=%#lx\n",
            depth, cache, allocation, __builtin_return_address(0),
            (unsigned long)words[0], (unsigned long)words[1],
            (unsigned long)words[2], (unsigned long)words[3],
            (unsigned long)words[4], (unsigned long)words[5],
            (unsigned long)words[6], (unsigned long)words[7],
            (unsigned long)words[8], (unsigned long)words[9],
            (unsigned long)words[10], (unsigned long)words[11]);
    }
    if (macws_filecache_finalize_original)
        macws_filecache_finalize_original(cache);
    --macws_filecache_finalize_depth;
}

void macws_install_filecache_diagnostic(
    const struct mach_header *untyped_header) {
    if (!getenv("MACWS_FILECACHE_DIAG")) return;
    static _Atomic int installed = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &installed, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return;

    // CrashReporter UUID and offsets from the actual iPad macOS 13.4 shared
    // cache: CoreServicesInternal dc429505-f838-3d6d-9b03-5a826efe86a4;
    // _FileCacheFinalize crash frame image+0x8d00 at symbol+0x4c, therefore
    // the function entry is image+0x8cb4.
    static const uint8_t expectedUUID[16] = {
        0xdc, 0x42, 0x95, 0x05, 0xf8, 0x38, 0x3d, 0x6d,
        0x9b, 0x03, 0x5a, 0x82, 0x6e, 0xfe, 0x86, 0xa4,
    };
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!macws_macho_uuid_matches(header, expectedUUID)) {
        dprintf(STDERR_FILENO,
                "MACWS-FILECACHE install skipped: UUID mismatch\n");
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }
    void *target = (void *)((uintptr_t)header + 0x8cb4);
    MSHookFunction(target, (void *)macws_filecache_finalize_diagnostic,
                   (void **)&macws_filecache_finalize_original);
    dprintf(STDERR_FILENO,
            "MACWS-FILECACHE installed target=%p original=%p\n",
            target, macws_filecache_finalize_original);
}

// Diagnostic-only probe for Finder's DesktopServices volume registry.  The
// actual Ventura 13.4 crash at DesktopServicesPriv+0xe8f50 dereferences
// `this+0x200` with x0 == NULL.  RE of the caller at +0xe8374 shows that x0 is
// the object returned through a shared_ptr by +0xe9648; +0xe9648 in turn calls
// the map lookup at +0xef968 and emits an empty shared_ptr when it returns nil.
// Observe that real boundary without fabricating a map node or changing the
// native failure path.
MacWSDesktopVolumeMapFindFn
    macws_desktop_volume_map_find_original = NULL;
MacWSSamePhysicalDeviceFn
    macws_same_physical_device_original = NULL;

void *macws_desktop_volume_map_find_diagnostic(void *map,
                                                       const void *key) {
    void *result = macws_desktop_volume_map_find_original
        ? macws_desktop_volume_map_find_original(map, key) : NULL;
    uintptr_t mapWords[6] = {};
    uintptr_t keyWords[8] = {};
    uintptr_t resultWords[12] = {};
    if (map) memcpy(mapWords, map, sizeof(mapWords));
    if (key) memcpy(keyWords, key, sizeof(keyWords));
    if (result) memcpy(resultWords, result, sizeof(resultWords));
    dprintf(STDERR_FILENO,
        "MACWS-DESKTOP-VOLUME find map=%p result=%p "
        "map=[%#lx,%#lx,%#lx,%#lx,%#lx,%#lx] "
        "key=[%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx] "
        "node=[%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx]\n",
        map, result,
        (unsigned long)mapWords[0], (unsigned long)mapWords[1],
        (unsigned long)mapWords[2], (unsigned long)mapWords[3],
        (unsigned long)mapWords[4], (unsigned long)mapWords[5],
        (unsigned long)keyWords[0], (unsigned long)keyWords[1],
        (unsigned long)keyWords[2], (unsigned long)keyWords[3],
        (unsigned long)keyWords[4], (unsigned long)keyWords[5],
        (unsigned long)keyWords[6], (unsigned long)keyWords[7],
        (unsigned long)resultWords[0], (unsigned long)resultWords[1],
        (unsigned long)resultWords[2], (unsigned long)resultWords[3],
        (unsigned long)resultWords[4], (unsigned long)resultWords[5],
        (unsigned long)resultWords[6], (unsigned long)resultWords[7],
        (unsigned long)resultWords[8], (unsigned long)resultWords[9],
        (unsigned long)resultWords[10], (unsigned long)resultWords[11]);
    // libc++ __hash_table layout, RE-confirmed at the actual +0xef968 lookup:
    // map q2 is the sentinel's next pointer and q3 is element count. Follow
    // only the recorded number of nodes (capped at four) so the stored key can
    // be compared with the failed query without an unbounded traversal.
    uintptr_t node = map ? mapWords[2] : 0;
    uintptr_t count = map ? mapWords[3] : 0;
    if (count > 4) count = 4;
    for (uintptr_t index = 0; node && index < count; index++) {
        uintptr_t nodeWords[16] = {};
        memcpy(nodeWords, (const void *)node, sizeof(nodeWords));
        dprintf(STDERR_FILENO,
            "MACWS-DESKTOP-VOLUME node index=%lu address=%p "
            "words=[%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,"
            "%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx,%#lx]\n",
            (unsigned long)index, (void *)node,
            (unsigned long)nodeWords[0], (unsigned long)nodeWords[1],
            (unsigned long)nodeWords[2], (unsigned long)nodeWords[3],
            (unsigned long)nodeWords[4], (unsigned long)nodeWords[5],
            (unsigned long)nodeWords[6], (unsigned long)nodeWords[7],
            (unsigned long)nodeWords[8], (unsigned long)nodeWords[9],
            (unsigned long)nodeWords[10], (unsigned long)nodeWords[11],
            (unsigned long)nodeWords[12], (unsigned long)nodeWords[13],
            (unsigned long)nodeWords[14], (unsigned long)nodeWords[15]);
        node = nodeWords[0];
    }
    return result;
}

bool macws_same_physical_device_diagnostic(const void *lhs,
                                                   const void *rhs) {
    dprintf(STDERR_FILENO,
            "MACWS-DESKTOP-VOLUME SamePhysicalDevice lhs=%p rhs=%p\n",
            lhs, rhs);
    return macws_same_physical_device_original
        ? macws_same_physical_device_original(lhs, rhs) : false;
}

void macws_install_desktop_volume_diagnostic(
    const struct mach_header *untyped_header) {
    if (!getenv("MACWS_DESKTOPSERVICES_DIAG")) return;
    static _Atomic int installed = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &installed, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return;

    static const uint8_t expectedUUID[16] = {
        0xc7, 0x6a, 0xb2, 0x8e, 0x02, 0xa7, 0x3d, 0x20,
        0xa2, 0x94, 0x9d, 0xab, 0xb9, 0x4c, 0x43, 0x13,
    };
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!macws_macho_uuid_matches(header, expectedUUID)) {
        dprintf(STDERR_FILENO,
                "MACWS-DESKTOP-VOLUME install skipped: UUID mismatch\n");
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    void *mapFind = (void *)((uintptr_t)header + 0xef968);
    void *samePhysical = (void *)((uintptr_t)header + 0xe8f3c);
    MSHookFunction(mapFind,
                   (void *)macws_desktop_volume_map_find_diagnostic,
                   (void **)&macws_desktop_volume_map_find_original);
    MSHookFunction(samePhysical,
                   (void *)macws_same_physical_device_diagnostic,
                   (void **)&macws_same_physical_device_original);
    dprintf(STDERR_FILENO,
            "MACWS-DESKTOP-VOLUME installed mapFind=%p samePhysical=%p\n",
            mapFind, samePhysical);
}

// Chromium's Apple display path normally promotes the complete root render
// pass to process-local CALayers. MacWS/VNC captures the WindowServer primary
// scanout, so a video promoted outside that scanout is visible in Chromium's
// DevTools capture but is a black rectangle in the real VNC frame.
//
// Chromium already has the required invariant: when an AggregatedRenderPass
// has `video_capture_enabled`, CALayerOverlayProcessor returns
// kCALayerFailedVideoCaptureEnabled. OverlayProcessorMac then follows its
// normal fallback, preserves the quads in the root render pass, and appends a
// real primary-plane candidate. Tell that existing path that MacWS is a
// continuous capture consumer. Do not replace OverlayProcessorMac with the
// Stub: runtime VNC evidence showed that the Stub omits the Mac primary-plane
// fallback and turns the whole Chromium client area black.
//
// RE-confirmed from the VS Code 1.130.0 Electron Framework actually installed
// on the device, and source-confirmed against Chromium 148.0.7778.280
// components/viz/service/display/{overlay_processor_mac,ca_layer_overlay}.cc:
//   Chrome/Electron                         148.0.7778.280 / 42.6.0
//   UUID                                    4C4C4442-5555-3144-A1A8-564169F3FF00
//   OverlayProcessorMac::ProcessForOverlays image + 0x0ca10b8
//   ProcessForCALayerOverlays               image + 0x0ca1254
//   AggregatedRenderPass capture byte       render_pass + 0x0e2
//   capture load/branch                     image + 0x0ca12a8 / +0x0ca12ac
//   capture result                          w20 = 0x21 at image + 0x0ca17f0
// The UUID, normal C++ function prologue, and complete field-read sequence are
// checked before installing the adapter. A different Electron build is left
// untouched instead of guessing at a private class layout.
//
// At +0xca1298 Chromium loads `enable_ca_renderer_`, compares it with 1, and
// reaches +0xca12a4 only when w8 is therefore exactly 1. Reuse that proven
// value to store the real capture bool, then move x1 into x23 in the following
// slot. The original tbnz, error selection, function body, return value, and
// OverlayProcessorMac fallback remain byte-for-byte intact. This avoids a
// whole-function trampoline on Chromium's frame hot path.

void macws_install_chromium_composite_overlays(
        const struct mach_header *untyped_header) {
    if (!getenv("MACWS_CHROMIUM_COMPOSITE_OVERLAYS"))
        return;

    // Viz owns OverlayProcessorMac in Chromium's dedicated GPU helper. Do not
    // modify the Electron main process: runtime LLDB caught its early
    // fork/exec child faulting on instruction fetch at Electron Framework
    // +0x3cd5fe0 after inheriting a parent COW text patch. Restricting the
    // private-text hook to --type=gpu-process both matches the real owner and
    // keeps the main process's pre-spawn text mapping pristine.
    BOOL is_gpu_process = NO;
    int *argc_pointer = _NSGetArgc();
    char ***argv_pointer = _NSGetArgv();
    if (argc_pointer && argv_pointer && *argv_pointer) {
        for (int index = 1; index < *argc_pointer; index++) {
            const char *argument = (*argv_pointer)[index];
            if (argument && strcmp(argument, "--type=gpu-process") == 0) {
                is_gpu_process = YES;
                break;
            }
        }
    }
    if (!is_gpu_process)
        return;

    static _Atomic int installed = 0;
    if (atomic_exchange_explicit(&installed, 1, memory_order_acq_rel))
        return;

    static const uint8_t expected_uuid[16] = {
        0x4c, 0x4c, 0x44, 0x42, 0x55, 0x55, 0x31, 0x44,
        0xa1, 0xa8, 0x56, 0x41, 0x69, 0xf3, 0xff, 0x00,
    };
    static const uint32_t expected_prologue[] = {
        0x6db923e9, // stp d9, d8, [sp, #-0x70]!
        0xa9016ffc, // stp x28, x27, [sp, #0x10]
        0xa90267fa, // stp x26, x25, [sp, #0x20]
        0xa9035ff8, // stp x24, x23, [sp, #0x30]
        0xa90457f6, // stp x22, x21, [sp, #0x40]
        0xa9054ff4, // stp x20, x19, [sp, #0x50]
        0xa9067bfd, // stp x29, x30, [sp, #0x60]
        0x910183fd, // add x29, sp, #0x60
    };
    static const uint32_t expected_capture_adapter[] = {
        0x39402408, // ldrb w8, [x0, #0x9] (enable_ca_renderer_)
        0x7100051f, // cmp w8, #1
        0x54002b21, // b.ne disabled-CALayer result
        0xaa0103f7, // mov x23, x1 (AggregatedRenderPass *)
        0x39438828, // ldrb w8, [x1, #0xe2] (video_capture_enabled)
        0x37002a08, // tbnz w8, #0, capture-disabled-CALayer result
        0xa94b26e8, // ldp x8, x9, [x23, #0xb0] (copy_requests)
        0xeb09011f, // cmp x8, x9
    };
    enum { kProcessForCALayerOverlaysOffset = 0x0ca1254 };
    enum { kCaptureAdapterOffset = 0x44 };
    enum { kCaptureStoreIndex = 3 };
    enum { kRenderPassMoveIndex = 4 };

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!macws_macho_uuid_matches(header, expected_uuid)) {
        fprintf(stderr,
            "#### MACWS_CHROMIUM_COMPOSITE_OVERLAYS skipped: "
            "Electron Framework UUID mismatch\n");
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    void *process_for_ca_layers = (void *)((uintptr_t)header +
        kProcessForCALayerOverlaysOffset);
    uint32_t *capture_adapter = (uint32_t *)(
        (uintptr_t)process_for_ca_layers + kCaptureAdapterOffset);
    if (memcmp(process_for_ca_layers, expected_prologue,
               sizeof(expected_prologue)) != 0) {
        const uint32_t *actual = (const uint32_t *)process_for_ca_layers;
        fprintf(stderr,
            "#### MACWS_CHROMIUM_COMPOSITE_OVERLAYS skipped: "
            "ProcessForCALayerOverlays prologue mismatch "
            "%#x %#x %#x %#x %#x %#x %#x %#x\n",
            actual[0], actual[1], actual[2], actual[3], actual[4],
            actual[5], actual[6], actual[7]);
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }
    if (memcmp(capture_adapter, expected_capture_adapter,
               sizeof(expected_capture_adapter)) != 0) {
        fprintf(stderr,
            "#### MACWS_CHROMIUM_COMPOSITE_OVERLAYS skipped: capture "
            "field sequence mismatch %#x %#x %#x %#x %#x %#x %#x %#x\n",
            capture_adapter[0], capture_adapter[1], capture_adapter[2],
            capture_adapter[3], capture_adapter[4], capture_adapter[5],
            capture_adapter[6], capture_adapter[7]);
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    ModifyExecutableRegion(capture_adapter + kCaptureStoreIndex,
                           2 * sizeof(uint32_t), ^{
        // Before: mov x23,x1; ldrb w8,[x1,#0xe2]
        // After:  strb w8,[x1,#0xe2]; mov x23,x1
        // w8 is exactly 1 on this fallthrough from the checked cmp above.
        capture_adapter[kCaptureStoreIndex] = 0x39038828;
        capture_adapter[kRenderPassMoveIndex] = 0xaa0103f7;
    });
    fprintf(stderr,
        "#### MACWS_CHROMIUM_COMPOSITE_OVERLAYS installed "
        "ProcessForCALayerOverlays=%p capture-adapter=%p "
        "capture-field=render-pass+0xe2 "
        "(Chromium keeps its native primary-plane fallback)\n",
        process_for_ca_layers, capture_adapter + kCaptureStoreIndex);
}

// AGXMetal13_3 was extracted from the macOS dyld shared cache. Its external
// authenticated stub at static 0x1e5a5dfc0 reaches a cache-global GOT page
// which is not part of the standalone image. Every AGX super-init routes
// through this stub. Maps runtime-confirmed that its Metal DeviceDispatch
// thread can enter -[AGXG13GFamilyDevice initWithAcceleratorPort:...] before
// the old, late repair point ran: objc_msgSendSuper2's branch target was PAC-
// poisoned at the call's return address. Repair this exact stub immediately
// after deriving the image slide, before invoking any ObjC/Metal operation.
bool macws_repair_agx_objc_msgsend_super2_stub(intptr_t slide) {
    static const uintptr_t kStubStatic = 0x1e5a5dfc0;
    static const uint32_t kOriginal[4] = {
        0xd01cf7f1, 0x9132a231, 0xf9400230, 0xd71f0a11,
    };

    void *resolved = dlsym(RTLD_DEFAULT, "objc_msgSendSuper2");
    if (!resolved) {
        fprintf(stderr,
                "#### MACWS_AGX_STUB_FIX dlsym(objc_msgSendSuper2)=NULL\n");
        return false;
    }
    uintptr_t target = (uintptr_t)ptrauth_strip(
        resolved, ptrauth_key_function_pointer);
    const uint32_t Rd = 16;
    uint32_t replacement[4] = {
        0xD2800000u | ((uint32_t)(target & 0xffffu) << 5) | Rd,
        0xF2A00000u | ((uint32_t)((target >> 16) & 0xffffu) << 5) | Rd,
        0xF2C00000u | ((uint32_t)((target >> 32) & 0xffffu) << 5) | Rd,
        0xD61F0200u,
    };
    uint32_t *stub = (uint32_t *)(kStubStatic + slide);
    if (memcmp(stub, replacement, sizeof(replacement)) == 0) return true;
    if (memcmp(stub, kOriginal, sizeof(kOriginal)) != 0) {
        fprintf(stderr,
                "#### MACWS_AGX_STUB_FIX exact-precondition-failed stub=%p "
                "actual=[%08x %08x %08x %08x]\n",
                stub, stub[0], stub[1], stub[2], stub[3]);
        return false;
    }

    uint32_t insn0 = replacement[0];
    uint32_t insn1 = replacement[1];
    uint32_t insn2 = replacement[2];
    uint32_t insn3 = replacement[3];
    ModifyExecutableRegion(stub, sizeof(replacement), ^{
        stub[0] = insn0;
        stub[1] = insn1;
        stub[2] = insn2;
        stub[3] = insn3;
    });
    bool repaired = memcmp(stub, replacement, sizeof(replacement)) == 0;
    fprintf(stderr,
            "#### MACWS_AGX_STUB_FIX objc_msgSendSuper2 %s stub=%p "
            "target=%p new=[%08x %08x %08x %08x]\n",
            repaired ? "repaired-early" : "write-verification-failed",
            stub, (void *)target, stub[0], stub[1], stub[2], stub[3]);
    return repaired;
}

// Ventura locationd gives an otherwise idle daemon only three seconds after
// startRun before scheduling shutdown, even though its AutoShutdownDelay
// preference has already been read as 15 seconds.  That is normally enough
// on macOS, but the first MacWS launch must finish the chroot service graph
// (including GeoServices) before CoreLocationAgent's synchronous requirement
// request can be answered.  Runtime LLDB captured the client-side MIG result
// as MIG_SERVER_DIED (-308): locationd completed startRun, logged "no more
// clients, 3 second(s) to auto-shutdown", and exited while the real request
// was still pending.
//
// Preserve the stock lifecycle and client accounting.  Only extend the first
// idle window to the configured default of 15 seconds; a registered client
// still cancels the timer through Apple's original code, while a genuinely
// idle daemon still exits.  The exact Ventura 13.4 UUID and the surrounding
// five instructions are mandatory preconditions so this cannot drift onto a
// different locationd build.
void macws_extend_locationd_initial_idle_window(
    const struct mach_header *untyped_header) {
    static const uint8_t expected_uuid[16] = {
        0xda, 0x33, 0x4e, 0x85, 0x02, 0xce, 0x30, 0x6b,
        0xa7, 0xb3, 0x7a, 0x9d, 0xb0, 0x96, 0x6e, 0xa1,
    };
    static const uint32_t expected[5] = {
        0x97ef019e, // bl  internal activity predicate
        0x35002420, // cbnz w0, diagnostic path
        0xaa1303e0, // mov x0, x19 (CLDaemonCore *)
        0x52800061, // mov w1, #3
        0x94000176, // bl  CLDaemonCore::scheduleShutdown(int)
    };
    static const uint32_t repaired_delay = 0x528001e1; // mov w1, #15
    enum { kInitialDelayCallsiteOffset = 0x46579c };

    const char *program = getprogname();
    if (!program || strcmp(program, "locationd") != 0) return;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!macws_macho_uuid_matches(header, expected_uuid)) return;

    uint32_t *callsite = (uint32_t *)((uintptr_t)header +
                                      kInitialDelayCallsiteOffset);
    if (callsite[3] == repaired_delay) return;
    if (memcmp(callsite, expected, sizeof(expected)) != 0) {
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                    "#### MACWS LOCATIOND idle-window precondition mismatch "
                    "at %p: %08x %08x %08x %08x %08x\n",
                    callsite, callsite[0], callsite[1], callsite[2],
                    callsite[3], callsite[4]);
        }
        return;
    }

    ModifyExecutableRegion(&callsite[3], sizeof(callsite[3]), ^{
        callsite[3] = repaired_delay;
    });
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS LOCATIOND initial idle window %s at %p "
                "(3s -> 15s)\n",
                callsite[3] == repaired_delay ? "extended" : "write-failed",
                &callsite[3]);
    }
}

void loadImageCallback(const struct mach_header* header, intptr_t vmaddr_slide) {
    Dl_info info;
    dladdr(header, &info);
    if (info.dli_fname &&
        strcmp(info.dli_fname, "/usr/libexec/locationd") == 0) {
        macws_extend_locationd_initial_idle_window(header);
    }
    if (info.dli_fname &&
        strstr(info.dli_fname,
               "/UniformTypeIdentifiers.framework/") != NULL) {
        macws_schedule_uttype_coretypes_compatibility();
    }
    if (info.dli_fname &&
        strstr(info.dli_fname, "/MapKit.framework/") != NULL) {
        macws_schedule_maps_location_capability_adapter();
    }
    if (info.dli_fname &&
        strstr(info.dli_fname,
               "/CoreServicesInternal.framework/") != NULL) {
        macws_install_filecache_diagnostic(header);
    }
    if (info.dli_fname &&
        strstr(info.dli_fname,
               "/DesktopServicesPriv.framework/") != NULL) {
        macws_install_desktop_volume_diagnostic(header);
    }
    if (info.dli_fname &&
        strstr(info.dli_fname, "/LaunchServices.framework/") != NULL) {
        macws_install_fsnode_root_volume_repair();
        macws_install_lsd_session_store_isolation();
    }
    if (info.dli_fname &&
        strstr(info.dli_fname,
               "/Electron Framework.framework/Versions/A/Electron Framework")) {
        macws_install_chromium_composite_overlays(header);
    }
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
        // Register the Metal framework before libxpc uncorks this task's PID
        // domain.  Concrete XPC bundles are added later through xpc_add_bundle
        // after CoreFoundation can parse their metadata.
        xpc_object_t dict = (xpc_object_t)xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/Metal.framework/Metal", 2);
        int(*_xpc_bootstrap_services_fn)(xpc_object_t) =
            MSFindSymbol((MSImageRef)header, "__xpc_bootstrap_services");
        fprintf(stderr, "#### XPC_BOOTSTRAP: fn=%p dict=%p "
            "(registering Metal compiler service)\n",
            _xpc_bootstrap_services_fn, dict);
        if (_xpc_bootstrap_services_fn) {
            int result = _xpc_bootstrap_services_fn(dict);
            fprintf(stderr, "#### XPC_BOOTSTRAP: result=%d\n", result);
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
        if (getenv("MACWS_AGX_NATIVE") &&
            macws_runtime_diagnostics_enabled()) {
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
            macws_cancel_completion_enabled()) {
            macws_install_quartzcore_frame_info_hook(header);
            macws_install_quartzcore_coexist_pacing_hooks(header);
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

        // Fail closed: continuing into AGX class realization with this known-
        // invalid external stub recreates the Maps PAC crash and can leave a
        // partially initialized MTLDevice behind for later callers.
        if (!macws_repair_agx_objc_msgsend_super2_stub(slide)) {
            return;
        }

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
        // the real impl), the wrap should work. Log which one only when the
        // explicit runtime diagnostics profile is armed.
        if (getenv("MACWS_AGX_NATIVE") &&
            macws_runtime_diagnostics_enabled()) {
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
                if (m_unt && macws_runtime_diagnostics_enabled()) {
                    IMP orig_unt = method_getImplementation(m_unt);
                    IMP trace_unt = imp_implementationWithBlock(^id(id self, id dev, unsigned long len, unsigned long opt) {
                        id r = ((id (*)(id, SEL, id, unsigned long, unsigned long))orig_unt)(
                            self, initUntracked, dev, len, opt);
                        if (macws_runtime_diagnostics_enabled()) {
                            fprintf(stderr,
                                "#### TRACE -[AGXBuffer initUntracked] self=%p dev=%p len=%lu opt=%lu -> %p\n",
                                self, dev, len, opt, r);
                        }
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
                                if (macws_runtime_diagnostics_enabled() &&
                                    fb_log++ < 12) {
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
                        if (macws_runtime_diagnostics_enabled() &&
                            trace_cnt++ < 12) {
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
                    if (m_args && getenv("MACWS_PIN_FALLBACK") &&
                        macws_runtime_diagnostics_enabled()) {
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
            if (macws_runtime_diagnostics_enabled()) {
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
            }
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classlist NOT FOUND\n");
        }
        // Walk __objc_classrefs section: read each pointer entry.
        if (macws_runtime_diagnostics_enabled()) {
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
        if (macws_runtime_diagnostics_enabled()) {
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
