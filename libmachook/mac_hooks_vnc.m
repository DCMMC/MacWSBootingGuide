// mac_hooks_vnc.m — part 2 of the mac_hooks.m split.
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
char macws_crash_buf[MACWS_CRASH_BUF_LEN];

const char *macws_si_code_string(int signo, int code) {
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

void macws_crash_diag_handler(int signo, siginfo_t *info, void *uctx_) {
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

void macws_install_crash_diag(void) {
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
CFTypeRef hooked_IOHIDUnserializeAndVMDealloc(
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
int hooked_IOHIDEventSystemClientSetMatchingMultiple_skip(
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
macws_abort_t macws_orig_abort_with_payload = NULL;

int hooked_abort_with_payload(uint32_t reason_namespace,
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
void hooked_assert_rtn(const char *func, const char *file, int line,
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

void macws_install_assert_bypass(void) {
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

void macws_install_abort_trace(void) {
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
macws_agc_compile_t macws_orig_agc_compile = NULL;

void hooked_agc_compile(void *self, void *obj, void *module,
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
macws_verify_t macws_orig_agc_verify = NULL;
void hooked_agc_verify(void *self) {
    static int log_once = 0;
    if (!log_once) {
        log_once = 1;
        fprintf(stderr,
            "#### MACWS_AGC_VERIFY_BYPASS verifyLoweredIR called on %p "
            "→ skipping check\n", self);
    }
    // Just return — don't iterate the module, don't log faults.
}

void macws_install_agc_verify_bypass(MSImageRef img) {
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

void macws_install_agc_fastmath_disable(void) {
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
void macws_install_agx_renamer_patch(void) {
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

void macws_install_iohid_unserialize_bypass(void) {
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
CFTypeRef macws_hid_sentinel = NULL;
dispatch_once_t macws_hid_sentinel_once = 0;
CFTypeRef macws_get_hid_sentinel(void) {
    dispatch_once(&macws_hid_sentinel_once, ^{
        macws_hid_sentinel = (CFTypeRef)CFArrayCreate(
            kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
        if (macws_hid_sentinel) {
            CFRetain(macws_hid_sentinel);  // pin forever
        }
    });
    return macws_hid_sentinel;
}

CFTypeRef hooked_IOHIDEventSystemClientCreate(
        CFAllocatorRef allocator) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr, "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreate "
        "→ sentinel %p\n", s);
    if (s) CFRetain(s);
    return s;
}
CFTypeRef hooked_IOHIDEventSystemClientCreateWithType(
        CFAllocatorRef allocator, int type, CFDictionaryRef attributes) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr,
        "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreateWithType(type=%d) "
        "→ sentinel %p\n", type, s);
    if (s) CFRetain(s);
    return s;
}
// Boolean-returning setter; return 1 for "success".
int hooked_IOHIDEventSystemClientSetMatchingMultiple(
        CFTypeRef client, CFArrayRef multiple) {
    (void)client; (void)multiple;
    return 1;
}
void hooked_IOHIDEventSystemClientRegisterDeviceMatchingBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
void hooked_IOHIDEventSystemClientUnregisterDeviceMatchingBlock(
        CFTypeRef client) {
    (void)client;
}
void hooked_IOHIDEventSystemClientRegisterEventBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
// Callback-pointer variant — same signature shape, also a no-op.
void hooked_IOHIDEventSystemClientRegisterEventCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
void hooked_IOHIDEventSystemClientRegisterPropertyChangedCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
void hooked_IOHIDEventSystemClientScheduleWithRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
void hooked_IOHIDEventSystemClientUnscheduleFromRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
CFArrayRef hooked_IOHIDEventSystemClientCopyServices(
        CFTypeRef client) {
    (void)client;
    return NULL;  // block checks cbz x0 and skips iteration
}
// Generic no-op stub — used for every "set/register/schedule/activate/cancel"
// IOHIDEventSystem call that takes our sentinel and otherwise tries to
// dereference its non-CFArray internals.
void hooked_IOHID_noop(void) {}
// Bool/int returning variant — return 1 (success) by convention.
int hooked_IOHID_noop_ret1(void) { return 1; }

void macws_hook_iokit_sym(MSImageRef img, const char *sym,
                                  void *replacement) {
    void *p = MSFindSymbol(img, sym);
    if (!p) {
        fprintf(stderr, "#### MACWS_HID_BYPASS: %s not found, skip\n", sym);
        return;
    }
    MSHookFunction(p, replacement, NULL);
    fprintf(stderr, "#### MACWS_HID_BYPASS hooked %s @ %p\n", sym, p);
}

void macws_install_iomfb_hid_bypass(void) {
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
char *(*macws_orig_rfbGetFB)(void);
void (*macws_orig_rfbGetFBRect)(int, int, int, int);
size_t (*macws_orig_CGDisplayPixelsWide)(uint32_t);
size_t (*macws_orig_CGDisplayPixelsHigh)(uint32_t);
char *macws_vnc_fb = NULL;
int  *macws_rfbScreen = NULL;
double *macws_rfbBackingScale = NULL;
int   macws_vnc_test_on = 0;
int   macws_vnc_share_on = 0;

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
int macws_vnc_integral_backing_scale(void) {
    if (!macws_vnc_share_on || !macws_rfbBackingScale) return 1;
    double savedScale = *macws_rfbBackingScale;
    int scale = (int)(savedScale + 0.5);
    if (scale < 2 || scale > 4 || savedScale < (double)scale - 0.01 ||
        savedScale > (double)scale + 0.01) return 1;
    return scale;
}

size_t macws_new_CGDisplayPixelsWide(uint32_t display) {
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

size_t macws_new_CGDisplayPixelsHigh(uint32_t display) {
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
// moving the window. The generated VNC job therefore gives every VNC pointer
// gesture one system owner through MACWS_VNC_NATIVE_ALL. AppInputBridge remains
// the full fallback when the native implementation is unavailable and remains
// the input path for the native iPad host.
MacWSVNCHandleMouse macws_orig_vnc_handle_mouse = NULL;
MacWSVNCHandleKeyboard macws_orig_vnc_handle_keyboard = NULL;
MacWSVNCSendKeyEvent macws_orig_vnc_send_key_event = NULL;
MacWSVNCSetKeyModifiers macws_orig_vnc_set_key_modifiers = NULL;
ptrdiff_t macws_vnc_current_modifiers_offset = -1;
// handleKeyboard owns one libvncserver client thread at a time. Preserve its
// original keysym while OSXvnc's own key table calls sendKeyEvent with the
// translated keycode and modifier flags.
__thread unsigned int macws_vnc_current_keysym;
BOOL macws_vnc_left_down = NO;
CGPoint macws_vnc_last_point = {-1.0, -1.0};
CGPoint macws_vnc_pending_down_point = {-1.0, -1.0};
BOOL macws_vnc_pending_down = NO;
BOOL macws_vnc_remote_down = NO;
BOOL macws_vnc_release_pending = NO;
uint32_t macws_vnc_gesture_id = 0;
int macws_vnc_input_fd = -1;
int macws_vnc_activation_fd = -1;
_Atomic uint32_t macws_vnc_activation_sequence = 0;
double macws_vnc_last_continuous_send = 0.0;
// System-wide route for the exact installed OSXvnc CGPostMouseEvent path. The
// split owner (AppInput taps, native drags/right buttons) cannot cover AppKit's
// global menu and drag state machine coherently. Runtime tests on 2026-07-29
// exercised menu open/hover/close, contextual menu, and NSWindow title drag
// through this single stream (13/13 region-change witnesses). The generated
// VNC launchd job enables this path; the file/env gate remains for controlled
// A/Bs and compatibility with manually launched OSXvnc.
BOOL macws_vnc_native_all = NO;
// Input A/B mode is deliberately independent from the mmap framebuffer and
// native-AGX presentation hooks.  "stock" leaves every OSXvnc input method
// untouched; "scale-only" corrects Retina RFB pixels to Quartz points and
// immediately calls the original mouse method; "hybrid" retains the current
// AppInput/target/menu compatibility path.  This lets one running AGX desktop
// distinguish an input regression from a rendering/session regression.
MacWSVNCInputMode macws_vnc_input_mode = MacWSVNCInputModeStock;
_Atomic uint64_t macws_vnc_keyboard_serial = 0;
_Atomic uint64_t macws_vnc_keyboard_last_progress_ns = 0;
_Atomic uint64_t macws_vnc_pointer_capture_serial = 0;
_Atomic uint64_t macws_vnc_pointer_last_progress_ns = 0;
_Atomic uint64_t macws_vnc_pointer_settle_serial = 0;
_Atomic unsigned int macws_vnc_native_buttons = 0;
_Atomic BOOL macws_vnc_caps_lock_active = NO;
double macws_vnc_last_hover_target_probe = 0.0;
BOOL macws_vnc_secondary_pending = NO;
CGPoint macws_vnc_secondary_down_point;
// VNC's native CGPostMouseEvent remains the sole button owner.  Remember only
// the bounded interval in which that real down opened a system menu so
// button-free motion can also enter a Carbon menu tracker when required.
double macws_vnc_menu_hover_until = 0.0;

BOOL macws_vnc_forward_key(unsigned short keyCode, BOOL down,
                                  uint64_t modifiers, unsigned int keySym);

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
MacWSVNCRefreshCallback macws_vnc_refresh_callback = NULL;
MacWSRFBSendFramebufferUpdate
    macws_orig_rfb_send_framebuffer_update = NULL;
__thread double macws_vnc_rfb_copy_milliseconds = 0.0;
__thread uint64_t macws_vnc_rfb_copy_pixels = 0;
__thread uint32_t macws_vnc_rfb_copy_calls = 0;
__thread BOOL macws_vnc_rfb_prefetched = NO;
double macws_vnc_monotonic_seconds(void);
double macws_vnc_event_timestamp_seconds(void);
bool macws_vnc_fill_test(int rectX, int rectY,
                                int rectWidth, int rectHeight);
MacWSVNCReadExact macws_orig_vnc_read_exact = NULL;
MacWSVNCProcessNormalMessage
    macws_orig_vnc_process_normal_message = NULL;
__thread BOOL macws_vnc_tracing_normal_message = NO;
__thread BOOL macws_vnc_awaiting_message_type = NO;
__thread uint8_t macws_vnc_normal_message_type = UINT8_MAX;

// RE-confirmed via the installed OSXvnc-server arm64 at __TEXT+0x14380:
// clientInput calls rfbProcessClientNormalMessage once per wire message. Its
// first ReadExact is exactly one byte (the RFB type); type 3 later unions the
// requested rectangle at +0x14968 and signals client+0xc8, while type 5 calls
// PtrAddEvent at +0x147a0 on the same serial thread. Trace this boundary so a
// delayed update can be attributed to input-queue latency or output wakeup
// from runtime timestamps instead of inference. No message bytes or return
// values are changed.
int macws_new_vnc_read_exact(void *client, void *bytes, int length) {
    int result = macws_orig_vnc_read_exact
        ? macws_orig_vnc_read_exact(client, bytes, length) : -1;
    if (result > 0 && bytes && length == 1 &&
        macws_vnc_tracing_normal_message &&
        macws_vnc_awaiting_message_type) {
        macws_vnc_normal_message_type = *(const uint8_t *)bytes;
        macws_vnc_awaiting_message_type = NO;
    }
    return result;
}

void macws_new_vnc_process_normal_message(void *client) {
    macws_vnc_tracing_normal_message = YES;
    macws_vnc_awaiting_message_type = YES;
    macws_vnc_normal_message_type = UINT8_MAX;
    double started = macws_vnc_monotonic_seconds();
    if (macws_orig_vnc_process_normal_message)
        macws_orig_vnc_process_normal_message(client);
    double finished = macws_vnc_monotonic_seconds();
    uint8_t type = macws_vnc_normal_message_type;
    macws_vnc_tracing_normal_message = NO;
    macws_vnc_awaiting_message_type = NO;
    static _Atomic uint64_t tracedMessages = 0;
    uint64_t count = atomic_fetch_add_explicit(
        &tracedMessages, 1, memory_order_relaxed) + 1;
    double elapsedMilliseconds = (finished - started) * 1000.0;
    if ((type == 3 || type == 5) &&
        (count <= 400 || elapsedMilliseconds >= 50.0 ||
         (count % 600) == 0)) {
        fprintf(stderr,
            "#### OSXVNC CLIENT-MESSAGE event=%llu type=%u "
            "finished=%.6f elapsed=%.3fms\n",
            (unsigned long long)count, type, finished,
            elapsedMilliseconds);
    }
}


// Published only after the producer-derived rectangle has been handed to
// OSXvnc's original refresh callback.  The generation watcher uses this as an
// acknowledgement that it need not copy/diff the same 15.2-MiB generation a
// second time.  It is deliberately process-local: loss of the datagram leaves
// the sequence behind and the mmap watcher remains the fallback.
_Atomic uint64_t macws_vnc_damage_notified_sequence = 0;
_Atomic uint64_t macws_vnc_damage_received_sequence = 0;
_Atomic BOOL macws_vnc_damage_callback_busy = NO;

// WindowServer already compares the completed owned scanout against the mmap
// before committing it. Receive that producer-derived bounding damage here so
// OSXvnc does not have to rediscover the same information with a second full
// 15.2-MiB snapshot/diff. The mmap remains the only pixel source; this socket
// carries no pixels and cannot acknowledge or fabricate a frame.
void *macws_vnc_damage_listener(void *unused) {
    (void)unused;
    const char *path = "/tmp/macws_vnc_damage.sock";
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) {
        fprintf(stderr,
            "#### OSXVNC DAMAGE socket failed errno=%d\n", errno);
        return NULL;
    }
    int receiveBuffer = 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF,
                     &receiveBuffer, sizeof(receiveBuffer));
    (void)unlink(path);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        fprintf(stderr,
            "#### OSXVNC DAMAGE bind failed errno=%d\n", errno);
        close(fd);
        return NULL;
    }
    (void)chmod(path, 0666);
    fprintf(stderr, "#### OSXVNC DAMAGE listener ready path=%s\n", path);
    uint64_t priorSequence = 0;
    for (;;) {
        MacWSVNCDamageMessage message = {0};
        ssize_t received = recv(fd, &message, sizeof(message), 0);
        if (received < 0 && errno == EINTR) continue;
        if (received < 0) { usleep(10000); continue; }
        int screenWidth = macws_rfbScreen ? macws_rfbScreen[0] : 0;
        int screenHeight = macws_rfbScreen ? macws_rfbScreen[2] : 0;
        size_t headerBytes = offsetof(MacWSVNCDamageMessage, rectangles);
        size_t expectedBytes = message.rectCount <=
            MacWSVNCDamageMaxRectangles
            ? headerBytes + (size_t)message.rectCount *
                sizeof(message.rectangles[0])
            : SIZE_MAX;
        BOOL valid = message.magic == MacWSVNCDamageMagic &&
            message.sequence > priorSequence &&
            message.width == (uint32_t)screenWidth &&
            message.height == (uint32_t)screenHeight &&
            message.rectCount > 0 &&
            message.rectCount <= MacWSVNCDamageMaxRectangles &&
            received == (ssize_t)expectedBytes;
        CGRect rectangles[MacWSVNCDamageMaxRectangles];
        for (uint32_t index = 0; valid && index < message.rectCount;
             index++) {
            const MacWSVNCDamageRect *source = &message.rectangles[index];
            uint64_t x1 = (uint64_t)source->x + source->rectWidth;
            uint64_t y1 = (uint64_t)source->y + source->rectHeight;
            valid = source->rectWidth > 0 && source->rectHeight > 0 &&
                x1 <= message.width && y1 <= message.height;
            rectangles[index] = (CGRect){
                .origin = {(CGFloat)source->x, (CGFloat)source->y},
                .size = {(CGFloat)source->rectWidth,
                         (CGFloat)source->rectHeight},
            };
        }
        if (!valid || !macws_vnc_refresh_callback) continue;
        priorSequence = message.sequence;
        atomic_store_explicit(&macws_vnc_damage_received_sequence,
                              message.sequence, memory_order_release);
        atomic_store_explicit(&macws_vnc_damage_callback_busy, YES,
                              memory_order_release);
        macws_vnc_refresh_callback(message.rectCount, rectangles, NULL);
        atomic_store_explicit(&macws_vnc_damage_notified_sequence,
                              message.sequence, memory_order_release);
        atomic_store_explicit(&macws_vnc_damage_callback_busy, NO,
                              memory_order_release);
        if (macws_runtime_diagnostics_enabled()) {
            static _Atomic uint64_t notificationCount = 0;
            uint64_t count = atomic_fetch_add_explicit(
                &notificationCount, 1, memory_order_relaxed) + 1;
            if (count <= 16 || (count % 60) == 0) {
            fprintf(stderr,
                "#### OSXVNC DAMAGE notify #%llu sequence=%llu "
                "rects=%u tiles=%u changed=%llu first=%u,%u %ux%u "
                "overflow=%s\n",
                (unsigned long long)count,
                (unsigned long long)message.sequence,
                message.rectCount, message.dirtyTileCount,
                (unsigned long long)message.changedPixels,
                message.rectangles[0].x, message.rectangles[0].y,
                message.rectangles[0].rectWidth,
                message.rectangles[0].rectHeight,
                (message.flags & 1u) ? "YES" : "NO");
            }
        }
    }
    return NULL;
}

// RE-confirmed via the installed arm64 OSXvnc-server at
// __TEXT+0x14e38 (2026-07-29): rfbSendFramebufferUpdate receives the client in
// x0 and the RegionRec pair in x1/x2, increments client+0x1e4, reads the
// selected encoding at client+0x580, encodes each region, then flushes the
// update buffer. Time this exact boundary so capture/notification latency can
// be separated from server encoding/socket backpressure. Observation only;
// every argument and the original return value are preserved.
int macws_new_rfb_send_framebuffer_update(
        void *client, void *regionExtents, void *regionData) {
    typedef struct {
        int16_t x1;
        int16_t y1;
        int16_t x2;
        int16_t y2;
    } MacWSRFBBox;
    uint64_t regionCount = regionData
        ? *(const uint64_t *)((const char *)regionData + 0x8) : 1;
    // RE-confirmed at installed OSXvnc-server __TEXT+0x14e38: when the region
    // data pointer is NULL, x1 itself contains the one 8-byte BoxRec by value
    // and the function spills x1/x2 to sp+0x40 before iterating. It is not a
    // pointer. Preserve that ABI here by viewing our local x1-sized argument.
    const MacWSRFBBox *boxes = regionData
        ? (const MacWSRFBBox *)((const char *)regionData + 0x10)
        : (const MacWSRFBBox *)&regionExtents;
    uint64_t regionPixels = 0;
    int32_t boundsX1 = INT32_MAX, boundsY1 = INT32_MAX;
    int32_t boundsX2 = INT32_MIN, boundsY2 = INT32_MIN;
    if (boxes && regionCount > 0 && regionCount <= 32768) {
        for (uint64_t index = 0; index < regionCount; index++) {
            int32_t width = (int32_t)boxes[index].x2 - boxes[index].x1;
            int32_t height = (int32_t)boxes[index].y2 - boxes[index].y1;
            if (width <= 0 || height <= 0) continue;
            regionPixels += (uint64_t)width * (uint64_t)height;
            if (boxes[index].x1 < boundsX1) boundsX1 = boxes[index].x1;
            if (boxes[index].y1 < boundsY1) boundsY1 = boxes[index].y1;
            if (boxes[index].x2 > boundsX2) boundsX2 = boxes[index].x2;
            if (boxes[index].y2 > boundsY2) boundsY2 = boxes[index].y2;
        }
    }
    macws_vnc_rfb_copy_milliseconds = 0.0;
    macws_vnc_rfb_copy_pixels = 0;
    macws_vnc_rfb_copy_calls = 0;
    macws_vnc_rfb_prefetched = NO;
    // rfbSendFramebufferUpdate asks rfbGetFramebufferUpdateInRect for every
    // RegionRec.  With producer damage this is commonly 40-100 rectangles.
    // Taking and dropping the mmap flock for each rectangle lets the producer
    // begin a new publication between pieces of one RFB update, and a blocked
    // piece was runtime-observed to stretch one send past eight seconds.
    // Snapshot the complete bounding box once while the producer is excluded;
    // the per-rectangle callbacks below then encode that same coherent frame.
    // This preserves all RFB regions and pixels; it changes only the lock
    // lifetime of the selected mmap capture backend.
    BOOL diagnostics = macws_runtime_diagnostics_enabled();
    if (macws_vnc_share_on && boundsX1 != INT32_MAX &&
        boundsX2 > boundsX1 && boundsY2 > boundsY1) {
        double copyStarted = diagnostics
            ? macws_vnc_monotonic_seconds() : 0.0;
        macws_vnc_rfb_prefetched = macws_vnc_fill_test(
            boundsX1, boundsY1, boundsX2 - boundsX1, boundsY2 - boundsY1);
        if (diagnostics) {
            macws_vnc_rfb_copy_milliseconds +=
                (macws_vnc_monotonic_seconds() - copyStarted) * 1000.0;
            macws_vnc_rfb_copy_calls = 1;
            macws_vnc_rfb_copy_pixels =
                (uint64_t)(boundsX2 - boundsX1) *
                (uint64_t)(boundsY2 - boundsY1);
        }
    }
    int encoding = client
        ? *(const int *)((const char *)client + 0x580) : INT_MIN;
    if (client && getenv("MACWS_VNC_LOW_LATENCY_COMPRESSION")) {
        // RE-confirmed via the installed arm64 OSXvnc-server
        // rfbProcessClientNormalMessage+0x63c/+0x84c: compression-level
        // pseudo-encodings are stored at client+0x26c (Zlib) and
        // client+0x558 (Tight). rfbSendOneRectEncodingZlib+0x248 consumes
        // +0x26c at deflateInit2_, while rfbSendRectEncodingTight+0x34
        // snapshots +0x558 for every rectangle.
        //
        // On the real 2388x1668 Terminal frame, controlled full-frame Tight
        // requests measured level 1 at 343 ms versus level 6 at 544 ms and
        // level 9 at 1184 ms.  A moved-window Zlib frame at the default level
        // took 1584 ms while framebuffer copy took 1.87 ms.  Clamp only the
        // compression work factor; the negotiated encoding, pixels, region,
        // and protocol stream remain unchanged.
        int *zlibLevel = (int *)((char *)client + 0x26c);
        int *tightLevel = (int *)((char *)client + 0x558);
        int *selectedLevel = encoding == 6 ? zlibLevel
                              : encoding == 7 ? tightLevel : NULL;
        if (selectedLevel && *selectedLevel != 1) {
            int requestedLevel = *selectedLevel;
            *selectedLevel = 1;
            fprintf(stderr,
                "#### OSXVNC LOW-LATENCY-COMPRESSION encoding=%d "
                "requested=%d effective=1\n",
                encoding, requestedLevel);
        }
    }
    double started = diagnostics ? macws_vnc_monotonic_seconds() : 0.0;
    int result = macws_orig_rfb_send_framebuffer_update
        ? macws_orig_rfb_send_framebuffer_update(
            client, regionExtents, regionData) : 0;
    macws_vnc_rfb_prefetched = NO;
    if (diagnostics) {
        double elapsedMilliseconds =
            (macws_vnc_monotonic_seconds() - started) * 1000.0;
        static _Atomic uint64_t sendCount = 0;
        uint64_t count = atomic_fetch_add_explicit(
            &sendCount, 1, memory_order_relaxed) + 1;
        if (count <= 32 || elapsedMilliseconds >= 20.0 ||
            (count % 600) == 0) {
        fprintf(stderr,
            "#### OSXVNC RFB-SEND #%llu encoding=%d regions=%llu "
            "pixels=%llu bounds=%d,%d %dx%d copy=%u/%llu/%.3fms "
            "elapsed=%.3fms result=%d\n",
            (unsigned long long)count, encoding,
            (unsigned long long)regionCount,
            (unsigned long long)regionPixels,
            boundsX1 == INT32_MAX ? 0 : boundsX1,
            boundsY1 == INT32_MAX ? 0 : boundsY1,
            boundsX1 == INT32_MAX ? 0 : boundsX2 - boundsX1,
            boundsY1 == INT32_MAX ? 0 : boundsY2 - boundsY1,
            macws_vnc_rfb_copy_calls,
            (unsigned long long)macws_vnc_rfb_copy_pixels,
            macws_vnc_rfb_copy_milliseconds,
            elapsedMilliseconds, result);
        }
    }
    return result;
}

// OSXvnc registers refreshCallback directly with CoreGraphics.  RE-confirmed
// at refreshCallback+0xec: its incoming CGRects are copied verbatim into the
// RFB modifiedRegion.  Once the RFB framebuffer is promoted from logical
// 1194x834 to Retina 2388x1668, those ordinary CG damage rectangles cover only
// the upper-left quarter and, more importantly, describe a capture backend we
// deliberately bypass.  Shared mode defers them to the mmap generation
// watcher. The watcher calls the original trampoline with validated physical
// rectangles and therefore bypasses this wrapper.
void macws_new_vnc_refresh_callback(uint32_t count,
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
        if (macws_runtime_diagnostics_enabled() && deferredLogs++ < 8) {
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
    if (macws_runtime_diagnostics_enabled() && scaleLogs++ < 8) {
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

void *macws_vnc_generation_watcher(void *unused) {
    (void)unused;
    void *mapping = NULL;
    int mappingFD = -1;
    size_t mappingSize = 0;
    uint64_t observed = 0;
    uint8_t *previousPixels = NULL;
    uint8_t *currentPixels = NULL;
    size_t previousPixelsSize = 0;
    size_t previousWidth = 0;
    size_t previousHeight = 0;
    BOOL previousValid = NO;
    uint64_t pendingFallbackSequence = 0;
    double pendingFallbackSince = 0.0;
    for (;;) {
        if (!mapping) {
            int fd = open("/tmp/macws_vnc_fb", O_RDONLY);
            if (fd >= 0) {
                BOOL retainedFD = NO;
                struct stat st = {0};
                if (fstat(fd, &st) == 0 && st.st_size >= 24) {
                    void *candidate = mmap(NULL, (size_t)st.st_size, PROT_READ,
                                           MAP_SHARED, fd, 0);
                    if (candidate != MAP_FAILED) {
                        mapping = candidate;
                        mappingFD = fd;
                        retainedFD = YES;
                        mappingSize = (size_t)st.st_size;
                    }
                }
                if (!retainedFD) close(fd);
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
                        uint64_t producerNotified = atomic_load_explicit(
                            &macws_vnc_damage_notified_sequence,
                            memory_order_acquire);
                        uint64_t producerReceived = atomic_load_explicit(
                            &macws_vnc_damage_received_sequence,
                            memory_order_acquire);
                        BOOL damageCallbackBusy = atomic_load_explicit(
                            &macws_vnc_damage_callback_busy,
                            memory_order_acquire);
                        if (producerNotified >= sequence ||
                            producerReceived >= sequence ||
                            damageCallbackBusy) {
                            // The listener has already inserted this exact
                            // committed generation's producer-derived damage
                            // into modifiedRegion.  Keeping the old snapshot
                            // as a diff baseline would be unsafe if the socket
                            // later disappears, so invalidate it; the first
                            // fallback generation will conservatively publish
                            // a full frame.
                            observed = sequence;
                            previousValid = NO;
                            pendingFallbackSequence = 0;
                            pendingFallbackSince = 0.0;
                            if (macws_runtime_diagnostics_enabled()) {
                                static _Atomic uint64_t skippedScans = 0;
                                uint64_t skipped = atomic_fetch_add_explicit(
                                    &skippedScans, 1,
                                    memory_order_relaxed) + 1;
                                if (skipped <= 16 ||
                                    (skipped % 600) == 0) {
                                fprintf(stderr,
                                    "#### OSXVNC mmap scan skipped #%llu "
                                    "sequence=%llu producer-received=%llu "
                                    "producer-notified=%llu busy=%s\n",
                                    (unsigned long long)skipped,
                                    (unsigned long long)sequence,
                                    (unsigned long long)producerReceived,
                                    (unsigned long long)producerNotified,
                                    damageCallbackBusy ? "YES" : "NO");
                                }
                            }
                            usleep(16000);
                            continue;
                        }
                        // The datagram listener and this polling thread can
                        // observe the same commit in either order.  Scanning
                        // immediately when the poll wins that race produced a
                        // conservative full-frame fallback (and multi-second
                        // Hextile encode) even though the real damage message
                        // arrived a few milliseconds later. Give the local
                        // socket four poll intervals to catch up. Preserve the
                        // first-miss timestamp while newer generations arrive
                        // so a genuinely absent producer still falls back.
                        double fallbackNow = macws_vnc_monotonic_seconds();
                        if (pendingFallbackSequence == 0) {
                            pendingFallbackSince = fallbackNow;
                        }
                        pendingFallbackSequence = sequence;
                        if (pendingFallbackSince > 0.0 &&
                            fallbackNow - pendingFallbackSince < 0.064) {
                            usleep(16000);
                            continue;
                        }
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

                            // Copy one coherent generation before diffing
                            // private memory. Runtime counts on 2026-07-29
                            // measured 112 producer commits but only 8 RFB
                            // updates during one continuous four-second menu
                            // trajectory: the former seqlock-only copy was
                            // repeatedly invalidated by the next 60-Hz writer.
                            // The producer now holds LOCK_EX while updating the
                            // mmap; take LOCK_SH for the 15.2-MiB copy. Keep the
                            // bounded seqlock retry as compatibility fallback
                            // when an older producer does not expose a usable
                            // file descriptor/lock.
                            BOOL snapshotStable = NO;
                            if (geometryMatches && previousPixels &&
                                currentPixels &&
                                previousPixelsSize == pixelBytes) {
                                BOOL sharedLocked = mappingFD >= 0 &&
                                    flock(mappingFD, LOCK_SH) == 0;
                                unsigned attempts = sharedLocked ? 1 : 4;
                                for (unsigned attempt = 0; attempt < attempts;
                                     attempt++) {
                                    uint64_t before = atomic_load_explicit(
                                        sequenceAddress,
                                        memory_order_acquire);
                                    if (before == 0 || (before & 1u)) {
                                        if (!sharedLocked) usleep(1000);
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
                                    if (!sharedLocked) usleep(1000);
                                }
                                if (sharedLocked)
                                    (void)flock(mappingFD, LOCK_UN);
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
                            pendingFallbackSequence = 0;
                            pendingFallbackSince = 0.0;

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
                            if (macws_runtime_diagnostics_enabled()) {
                                static _Atomic uint64_t notified = 0;
                                uint64_t count = atomic_fetch_add(
                                    &notified, 1) + 1;
                                if (count <= 16 || (count % 60) == 0) {
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
        }
        // The producer-derived damage socket is the low-latency path. Keep the
        // mmap generation scan as a conservative 16-ms fallback for an older
        // producer or a transient socket failure.
        usleep(16000);
    }
    return NULL;
}

double macws_vnc_monotonic_seconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

// NSEvent.timestamp and UIKit's CACurrentMediaTime use boot uptime, while
// Darwin CLOCK_MONOTONIC on this iOS build includes suspended time.  Runtime
// InputLab evidence measured the two clocks 6,080 seconds apart; placing the
// latter in an NSEvent made every synthetic right/key/scroll latency invalid.
// Keep CLOCK_MONOTONIC for cross-process activity pacing, but use the same
// public uptime clock as the native Host for input records.
double macws_vnc_event_timestamp_seconds(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

// Cross-process interaction hint for the cancelled-swap pacing diagnostic.
// OSXvnc writes one boot-relative timestamp (at most 120 Hz); WindowServer
// reads it at its existing SwapEnd boundary.  This does not fabricate a GPU
// completion or acknowledge work early.  It only selects the bounded sleep
// interval below so an idle VNC desktop can stay cool without imposing the
// same latency while a user is actively typing or dragging.
int macws_vnc_activity_fd = -1;
_Atomic uint64_t macws_vnc_last_activity_write_ns = 0;
int macws_vnc_interaction_wake_fd = -1;

void macws_vnc_signal_interaction_wake(void) {
    if (macws_vnc_interaction_wake_fd < 0) {
        macws_vnc_interaction_wake_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (macws_vnc_interaction_wake_fd >= 0) {
            (void)fcntl(macws_vnc_interaction_wake_fd, F_SETFD, FD_CLOEXEC);
            int flags = fcntl(macws_vnc_interaction_wake_fd, F_GETFL, 0);
            if (flags >= 0) {
                (void)fcntl(macws_vnc_interaction_wake_fd, F_SETFL,
                            flags | O_NONBLOCK);
            }
        }
    }
    if (macws_vnc_interaction_wake_fd < 0) return;

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, MACWS_INTERACTION_WAKE_SOCKET_PATH,
            sizeof(address.sun_path));
    const uint8_t token = 1;
    if (sendto(macws_vnc_interaction_wake_fd, &token, sizeof(token),
               MSG_DONTWAIT, (const struct sockaddr *)&address,
               sizeof(address)) < 0 &&
        (errno == EBADF || errno == ENOTSOCK)) {
        close(macws_vnc_interaction_wake_fd);
        macws_vnc_interaction_wake_fd = -1;
    }
}

void macws_vnc_note_interaction(void) {
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
    macws_vnc_signal_interaction_wake();
}

uint64_t macws_vnc_realtime_nanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

void macws_vnc_write_capture_request(const char *reason,
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
    if (written == length && macws_runtime_diagnostics_enabled()) {
        BOOL pointerProgress = strcmp(reason, "POINTER-PROGRESS") == 0;
        static _Atomic uint64_t pointerProgressLogs;
        uint64_t progressLog = pointerProgress
            ? atomic_fetch_add_explicit(&pointerProgressLogs, 1,
                                        memory_order_relaxed) + 1
            : 0;
        if (pointerProgress && progressLog > 16 &&
            (progressLog % 600) != 0) return;
        fprintf(stderr,
            "#### OSXVNC %s-CAPTURE serial=%llu detail=%#x "
            "generation=%llu\n",
            reason, (unsigned long long)serial, detail,
            (unsigned long long)generation);
    }
}

void macws_vnc_request_keyboard_progress_frame(uint64_t keySerial,
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

void macws_vnc_request_keyboard_final_frame(uint64_t keySerial,
                                                   unsigned int keySym) {
    if (!macws_vnc_share_on ||
        atomic_load_explicit(&macws_vnc_keyboard_serial,
                             memory_order_acquire) != keySerial) return;
    macws_vnc_write_capture_request("KEY-FINAL", keySerial, keySym);
}

void macws_vnc_request_keyboard_settled_frame(uint64_t keySerial,
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
// Request rate-limited observations while the pointer is moving, plus a
// trailing observation when it becomes quiet and a later observation after
// button transitions.  This does not synthesize an event or fabricate a
// frame: Metal_hooks still accepts only a real, stable WindowServer composite
// and ACKs its generation.
//
// The old implementation debounced every progress request by 24 ms and
// discarded it whenever a newer pointer event arrived.  A normal 60/120-Hz
// menu sweep or title drag therefore cancelled every request until motion
// stopped. Runtime OSXVNC logs contained only the final POINTER-PROGRESS for a
// continuous trajectory even though NATIVE-ALL recorded every input event.
// Throttle admission instead of cancelling admitted work: at most one leading
// observation per 16 ms can be queued, independent of subsequent events.  A
// serial-checked 48-ms quiet observation preserves the final state.
void macws_vnc_schedule_native_pointer_frames(
        unsigned int buttons, BOOL buttonTransition) {
    if (!macws_vnc_share_on) return;
    uint64_t serial = atomic_fetch_add_explicit(
        &macws_vnc_pointer_capture_serial, 1,
        memory_order_acq_rel) + 1;
    uint64_t now = macws_vnc_realtime_nanoseconds();
    if (now != 0) {
        const uint64_t minimumInterval = 16ull * NSEC_PER_MSEC;
        uint64_t previous = atomic_load_explicit(
            &macws_vnc_pointer_last_progress_ns, memory_order_acquire);
        BOOL admitted = NO;
        for (;;) {
            if (previous != 0 && now > previous &&
                now - previous < minimumInterval) break;
            if (atomic_compare_exchange_weak_explicit(
                    &macws_vnc_pointer_last_progress_ns, &previous, now,
                    memory_order_acq_rel, memory_order_acquire)) {
                admitted = YES;
                break;
            }
        }
        if (admitted) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_MSEC),
                dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    macws_vnc_write_capture_request(
                        "POINTER-PROGRESS", serial, buttons);
                });
        }
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 48 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            if (atomic_load_explicit(&macws_vnc_pointer_capture_serial,
                                     memory_order_acquire) == serial) {
                macws_vnc_write_capture_request(
                    "POINTER-QUIET", serial, buttons);
            }
        });
    if (!buttonTransition) return;
    uint64_t settleSerial = atomic_fetch_add_explicit(
        &macws_vnc_pointer_settle_serial, 1,
        memory_order_acq_rel) + 1;
    dispatch_after(
        // Observe the post-transition state after the immediate pointer
        // progress frame. Secondary clicks now use one atomic AppInput record;
        // their menu-specific trailing observations are scheduled below.
        dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            if (atomic_load_explicit(&macws_vnc_pointer_settle_serial,
                                     memory_order_acquire) == settleSerial) {
                macws_vnc_write_capture_request(
                    "POINTER-SETTLED", settleSerial, buttons);
            }
        });
}

// Runtime-confirmed on 2026-07-29: with the atomic secondary transport, the
// target process entered its real NSCarbonMenuImpl tracker immediately, but
// the generic 80-ms pointer observation sometimes preceded the first menu
// composite. The retained framebuffer then showed no menu until a later hover
// requested another observation.  A threshold-aware 2026-07-30 timing run
// measured AppInput delivery 34 ms after the RFB down and a valid contextual
// frame at 324 ms with the old 180/360-ms pair. Move the same two bounded
// observations to 120/240 ms; this is an observation-cadence A/B, not an input
// event or fabricated frame. Metal_hooks still publishes only a completed,
// stable WindowServer generation.
void macws_vnc_schedule_secondary_tap_frames(uint64_t gesture) {
    if (!macws_vnc_share_on) return;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            macws_vnc_write_capture_request(
                "SECONDARY-OPEN", gesture, 0);
        });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 240 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            macws_vnc_write_capture_request(
                "SECONDARY-FINAL", gesture, 0);
        });
}

void macws_new_vnc_handle_keyboard(id self, SEL command, BOOL down,
        unsigned int keySym, id client) {
    macws_vnc_note_interaction();
    if (down && keySym == 0xffe5u) {
        BOOL active = atomic_load_explicit(
            &macws_vnc_caps_lock_active, memory_order_acquire);
        atomic_store_explicit(
            &macws_vnc_caps_lock_active, !active, memory_order_release);
    }
    BOOL diagnostics = macws_runtime_diagnostics_enabled();
    double started = diagnostics ? macws_vnc_monotonic_seconds() : 0.0;
    unsigned int previousKeySym = macws_vnc_current_keysym;
    macws_vnc_current_keysym = keySym;
    if (macws_orig_vnc_handle_keyboard)
        macws_orig_vnc_handle_keyboard(self, command, down, keySym, client);
    macws_vnc_current_keysym = previousKeySym;
    if (diagnostics) {
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

void macws_new_vnc_send_key_event(id self, SEL command,
        unsigned short keyCode, BOOL down, uint64_t modifiers) {
    unsigned int keySym = macws_vnc_current_keysym;
    BOOL routed = macws_vnc_native_all &&
        macws_vnc_forward_key(keyCode, down, modifiers, keySym);
    if (macws_runtime_diagnostics_enabled()) {
        static _Atomic uint64_t routedKeys;
        uint64_t serial = atomic_fetch_add_explicit(
            &routedKeys, 1, memory_order_relaxed) + 1;
        if (serial <= 64 || !routed || (serial % 600) == 0) {
        fprintf(stderr,
            "#### OSXVNC KEY-ROUTE event=%llu down=%d keycode=%u "
            "keysym=%#x modifiers=%#llx route=%s\n",
            (unsigned long long)serial, down, keyCode, keySym,
            (unsigned long long)modifiers,
            routed ? "app-input" : "native-fallback");
        fflush(stderr);
        }
    }
    if (!routed && macws_orig_vnc_send_key_event) {
        macws_orig_vnc_send_key_event(
            self, command, keyCode, down, modifiers);
    }
}

void macws_new_vnc_set_key_modifiers(id self, SEL command,
                                            uint64_t modifiers) {
    if (!macws_vnc_native_all || macws_vnc_current_modifiers_offset < 0) {
        if (macws_orig_vnc_set_key_modifiers)
            macws_orig_vnc_set_key_modifiers(self, command, modifiers);
        return;
    }

    // RE-confirmed via installed arm64 OSXvnc-server
    // -[VNCServer setKeyModifiers:] at __TEXT+0xa2e8: after reconciling its
    // modifier key events through sendKeyEvent, it unconditionally calls
    // usleep(self->modifierDelay) at +0xa420 before storing currentModifiers.
    // That synchronization is required only because the stock downstream
    // path posts into the asynchronous global CGEvent state. Native-all sends
    // one NSEvent containing the already-computed modifierFlags directly to
    // the selected application's queue, so waiting for a global state that we
    // deliberately do not mutate adds 20-210 ms to every RFB key. Preserve
    // OSXvnc's upstream state machine by committing its real ivar here; the
    // original implementation remains the fallback for the stock CG path.
    uint64_t *current = (uint64_t *)((char *)(__bridge void *)self +
                                     macws_vnc_current_modifiers_offset);
    *current = modifiers;
    if (macws_runtime_diagnostics_enabled()) {
        static _Atomic uint64_t syncCount;
        uint64_t serial = atomic_fetch_add_explicit(
            &syncCount, 1, memory_order_relaxed) + 1;
        if (serial <= 16) {
        fprintf(stderr,
            "#### OSXVNC KEY-MODIFIERS event=%llu value=%#llx "
            "route=app-input-state\n",
            (unsigned long long)serial,
            (unsigned long long)modifiers);
        fflush(stderr);
        }
    }
}

BOOL macws_vnc_send_input_record(const MacWSInputRecord *record,
                                        BOOL reliable, int *errorOut,
                                        unsigned *attemptedOut) {
    if (!record) return NO;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/private/tmp/macws_host_input.sock",
            sizeof(address.sun_path));
    ssize_t sent = -1;
    int savedError = 0;
    unsigned attempts = reliable ? 2 : 1;
    unsigned attempted = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        attempted = attempt + 1;
        if (macws_vnc_input_fd < 0)
            macws_vnc_input_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (macws_vnc_input_fd < 0) {
            savedError = errno;
        } else {
            sent = sendto(macws_vnc_input_fd, record, sizeof(*record),
                          MSG_DONTWAIT, (const struct sockaddr *)&address,
                          sizeof(address));
            if (sent == (ssize_t)sizeof(*record)) break;
            savedError = sent < 0 ? errno : EMSGSIZE;
            if (savedError == EBADF || savedError == ECONNREFUSED) {
                close(macws_vnc_input_fd);
                macws_vnc_input_fd = -1;
            }
        }
        if (!reliable || (savedError != EAGAIN && savedError != ENOBUFS &&
                          savedError != ENOENT &&
                          savedError != ECONNREFUSED)) break;
        usleep(2000);
    }
    if (errorOut) *errorOut = savedError;
    if (attemptedOut) *attemptedOut = attempted;
    return sent == (ssize_t)sizeof(*record);
}

int macws_vnc_activation_reply_socket(void) {
    if (macws_vnc_activation_fd >= 0) return macws_vnc_activation_fd;
    int candidate = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (candidate < 0) return -1;
    (void)fcntl(candidate, F_SETFD, FD_CLOEXEC);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, MACWS_VNC_ACTIVATION_REPLY_SOCKET_PATH,
            sizeof(address.sun_path));
    (void)unlink(MACWS_VNC_ACTIVATION_REPLY_SOCKET_PATH);
    if (bind(candidate, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        close(candidate);
        return -1;
    }
    (void)chmod(MACWS_VNC_ACTIVATION_REPLY_SOCKET_PATH, 0600);
    macws_vnc_activation_fd = candidate;
    return candidate;
}

// Coordinate only the control-plane ownership transaction. The real button
// event remains OSXvnc's original CG/AppKit route. A ready acknowledgement
// lets an already-active target proceed immediately; repair/timeout preserves
// the historical 20-ms upper bound instead of sleeping blindly on every
// click. sampleSequence prevents a late reply from satisfying a newer down.
BOOL macws_vnc_coordinate_activation(CGPoint point) {
    const double maximumWaitSeconds = 0.020;
    double started = macws_vnc_monotonic_seconds();
    BOOL targetReady = NO;
    uint32_t replyFlags = 0;
    if (!macws_rfbScreen) goto finish;
    int width = macws_rfbScreen[0];
    int height = macws_rfbScreen[2];
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        goto finish;
    if (point.x < 0.0) point.x = 0.0;
    if (point.y < 0.0) point.y = 0.0;
    if (point.x >= width) point.x = width - 1;
    if (point.y >= height) point.y = height - 1;

    uint32_t sequence = atomic_fetch_add_explicit(
        &macws_vnc_activation_sequence, 1, memory_order_relaxed) + 1;
    if (sequence == 0) {
        sequence = atomic_fetch_add_explicit(
            &macws_vnc_activation_sequence, 1, memory_order_relaxed) + 1;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = 0x564e430000000001ull,
        .timestamp = macws_vnc_event_timestamp_seconds(),
        .x = (float)point.x,
        .y = (float)point.y,
        .contactID = macws_vnc_gesture_id,
        .frameWidth = (uint32_t)width,
        .frameHeight = (uint32_t)height,
        .source = MacWSInputSourceVNC,
        .sampleSequence = sequence,
    };
    int socketFD = macws_vnc_activation_reply_socket();
    if (socketFD < 0) goto finish;
    MacWSInputAck stale = {0};
    while (recv(socketFD, &stale, sizeof(stale), MSG_DONTWAIT) > 0) {
    }
    struct sockaddr_un broker = {0};
    broker.sun_family = AF_UNIX;
    broker.sun_len = sizeof(broker);
    strlcpy(broker.sun_path, "/private/tmp/macws_host_input.sock",
            sizeof(broker.sun_path));
    if (sendto(socketFD, &record, sizeof(record), MSG_DONTWAIT,
               (const struct sockaddr *)&broker, sizeof(broker)) !=
        (ssize_t)sizeof(record)) goto finish;

    for (;;) {
        double elapsed = macws_vnc_monotonic_seconds() - started;
        double remaining = maximumWaitSeconds - elapsed;
        if (remaining <= 0.0) break;
        struct pollfd descriptor = {.fd = socketFD, .events = POLLIN};
        int timeoutMS = (int)ceil(remaining * 1000.0);
        int pollResult;
        do {
            pollResult = poll(&descriptor, 1, timeoutMS);
        } while (pollResult < 0 && errno == EINTR);
        if (pollResult <= 0) break;
        MacWSInputAck acknowledgement = {0};
        ssize_t received = recv(socketFD, &acknowledgement,
                                sizeof(acknowledgement), 0);
        if (received != sizeof(acknowledgement) ||
            acknowledgement.magic != MACWS_INPUT_ACK_MAGIC ||
            acknowledgement.version != MACWS_INPUT_ACK_VERSION ||
            acknowledgement.size != sizeof(acknowledgement) ||
            acknowledgement.sampleSequence != sequence) continue;
        replyFlags = acknowledgement.flags;
        targetReady = (replyFlags & MacWSInputAckTargetReady) != 0;
        break;
    }

finish:;
    double elapsed = macws_vnc_monotonic_seconds() - started;
    if (!targetReady && elapsed < maximumWaitSeconds) {
        usleep((useconds_t)((maximumWaitSeconds - elapsed) * 1000000.0));
        elapsed = macws_vnc_monotonic_seconds() - started;
    }
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### OSXVNC ACTIVATE-ACK ready=%s flags=%#x elapsed=%.3fms\n",
            targetReady ? "YES" : "NO", replyFlags, elapsed * 1000.0);
    }
    return targetReady;
}

BOOL macws_vnc_forward_input(MacWSInputKind kind, CGPoint point,
                                    BOOL reliable) {
    if (!macws_rfbScreen) return NO;
    int width = macws_rfbScreen[0];
    int height = macws_rfbScreen[2];
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return NO;

    double now = macws_vnc_monotonic_seconds();
    BOOL continuous = kind == MacWSInputKindTouchMove ||
                      kind == MacWSInputKindHover ||
                      kind == MacWSInputKindMenuHover;
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
        .timestamp = macws_vnc_event_timestamp_seconds(),
        .x = (float)point.x,
        .y = (float)point.y,
        .pressure = (kind == MacWSInputKindTouchDown ||
                     kind == MacWSInputKindTouchMove) ? 1.0f : 0.0f,
        .contactID = macws_vnc_gesture_id,
        .frameWidth = (uint32_t)width,
        .frameHeight = (uint32_t)height,
        .targetPID = 0,
        .source = MacWSInputSourceVNC,
    };
    int saved_errno = 0;
    unsigned attempted = 0;
    BOOL ok = macws_vnc_send_input_record(
        &record, reliable, &saved_errno, &attempted);
    if (ok && continuous) macws_vnc_last_continuous_send = now;
    if (!ok) {
        static _Atomic unsigned failures = 0;
        unsigned failure = atomic_fetch_add_explicit(
            &failures, 1, memory_order_relaxed) + 1;
        if (failure <= 4 || (failure % 120) == 0) {
        fprintf(stderr,
            "#### OSXVNC INPUT kind=%u gesture=%u point=(%.1f,%.1f)/%dx%d "
            "sent=%s errno=%d attempts=%u reliable=%s\n",
            kind, macws_vnc_gesture_id, point.x, point.y, width, height,
            ok ? "YES" : "NO", ok ? 0 : saved_errno, attempted,
            reliable ? "YES" : "NO");
        }
    } else if (!continuous && macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### OSXVNC INPUT kind=%u gesture=%u point=(%.1f,%.1f)/%dx%d "
            "sent=YES errno=0 attempts=%u reliable=%s\n",
            kind, macws_vnc_gesture_id, point.x, point.y, width, height,
            attempted, reliable ? "YES" : "NO");
    }
    return ok;
}

BOOL macws_vnc_forward_key(unsigned short keyCode, BOOL down,
                                  uint64_t modifiers, unsigned int keySym) {
    if (!macws_rfbScreen) return NO;
    int width = macws_rfbScreen[0];
    int height = macws_rfbScreen[2];
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return NO;
    CGPoint point = macws_vnc_last_point;
    if (point.x < 0.0 || point.x >= width ||
        point.y < 0.0 || point.y >= height) {
        point = (CGPoint){width * 0.5, height * 0.5};
    }
    // OSXvnc KEY-ROUTE runtime evidence shows private/non-coalesced bit 0x100
    // on every ordinary key; it is not Caps Lock. The server sends Caps with
    // keyCode 57 but modifiers=0, so preserve its real key translation and add
    // only the state toggled by the raw XK_Caps_Lock down edge above.
    if (atomic_load_explicit(
            &macws_vnc_caps_lock_active, memory_order_acquire))
        modifiers |= 0x10000ull;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = down ? MacWSInputKindKeyDown : MacWSInputKindKeyUp,
        // "VNCK" distinguishes this union encoding from the pointer scene;
        // AppInput reads only the low 32 flag bits for a key record.
        .sceneID = 0x564e434b00000000ull |
                   (modifiers & 0xffffffffull),
        .timestamp = macws_vnc_event_timestamp_seconds(),
        .x = (float)point.x,
        .y = (float)point.y,
        .pressure = (float)keyCode,
        .contactID = keySym,
        .frameWidth = (uint32_t)width,
        .frameHeight = (uint32_t)height,
        .targetPID = 0,
        .source = MacWSInputSourceVNC,
    };
    int savedError = 0;
    unsigned attempted = 0;
    BOOL ok = macws_vnc_send_input_record(
        &record, YES, &savedError, &attempted);
    if (!ok) {
        fprintf(stderr,
            "#### OSXVNC KEY-INPUT down=%d keycode=%u keysym=%#x "
            "modifiers=%#llx sent=NO errno=%d attempts=%u\n",
            down, keyCode, keySym, (unsigned long long)modifiers,
            savedError, attempted);
        fflush(stderr);
    }
    return ok;
}

BOOL macws_vnc_forward_scroll(CGPoint point, float horizontal,
                                     float vertical) {
    if (!macws_rfbScreen || (!isfinite(horizontal) || !isfinite(vertical)))
        return NO;
    int width = macws_rfbScreen[0];
    int height = macws_rfbScreen[2];
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return NO;
    if (point.x < 0.0 || point.x >= width ||
        point.y < 0.0 || point.y >= height)
        point = (CGPoint){width * 0.5, height * 0.5};
    uint32_t horizontalBits = 0;
    memcpy(&horizontalBits, &horizontal, sizeof(horizontalBits));
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindScroll,
        .sceneID = 0x564e430000000001ull,
        .timestamp = macws_vnc_event_timestamp_seconds(),
        .x = (float)point.x,
        .y = (float)point.y,
        .pressure = vertical,
        .contactID = horizontalBits,
        .frameWidth = (uint32_t)width,
        .frameHeight = (uint32_t)height,
        .targetPID = 0,
        .source = MacWSInputSourceVNC,
    };
    int savedError = 0;
    unsigned attempted = 0;
    BOOL ok = macws_vnc_send_input_record(
        &record, YES, &savedError, &attempted);
    if (!ok) {
        fprintf(stderr,
            "#### OSXVNC SCROLL-INPUT delta=(%.1f,%.1f) sent=NO "
            "errno=%d attempts=%u\n",
            horizontal, vertical, savedError, attempted);
    }
    return ok;
}

void macws_new_vnc_handle_mouse(id self, SEL command,
        unsigned int buttons, CGPoint point, id client) {
    macws_vnc_note_interaction();
    if (macws_vnc_input_mode == MacWSVNCInputModeScaleOnly) {
        int scale = macws_vnc_integral_backing_scale();
        if (scale < 1) scale = 1;
        CGPoint quartzPoint = {
            point.x / (CGFloat)scale,
            point.y / (CGFloat)scale,
        };
        if (macws_orig_vnc_handle_mouse) {
            macws_orig_vnc_handle_mouse(self, command, buttons,
                                        quartzPoint, client);
        }
        return;
    }
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
            const unsigned int wheelMask = 8u | 16u | 32u | 64u;
            unsigned int pointerButtons = buttons & ~wheelMask;
            unsigned int previousPointerButtons =
                previousButtons & ~wheelMask;
            unsigned int wheelPressed =
                (buttons & ~previousButtons) & wheelMask;
            BOOL buttonTransition =
                pointerButtons != previousPointerButtons;
            double now = macws_vnc_monotonic_seconds();
            BOOL secondaryDown = previousPointerButtons == 0 &&
                                 (pointerButtons & 4u) != 0;
            BOOL primaryDown = previousPointerButtons == 0 &&
                               (pointerButtons & 1u) != 0;
            BOOL topBarDown = primaryDown && macws_rfbScreen[2] > 0 &&
                point.y <= (CGFloat)macws_rfbScreen[2] * 0.04;
            if (secondaryDown || topBarDown) {
                if (secondaryDown) {
                    macws_vnc_secondary_pending = YES;
                    macws_vnc_secondary_down_point = point;
                }
                macws_vnc_menu_hover_until = now + 12.0;
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### OSXVNC MENU-HOVER-ARM source=%s "
                        "now=%.6f until=%.6f point=(%.1f,%.1f)\n",
                        secondaryDown ? "secondary" : "top-bar",
                        now, macws_vnc_menu_hover_until, point.x, point.y);
                }
            } else if (primaryDown &&
                       now < macws_vnc_menu_hover_until) {
                // The next primary down selects or dismisses the already
                // tracked menu. Its native CG event is authoritative; stop
                // supplementing subsequent ordinary-window motion.
                macws_vnc_menu_hover_until = 0.0;
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### OSXVNC MENU-HOVER-DISARM source=primary "
                        "now=%.6f point=(%.1f,%.1f)\n",
                        now, point.x, point.y);
                }
            }
            if (buttonTransition && previousPointerButtons == 0 &&
                pointerButtons != 0) {
                // Coordinate the target before OSXvnc posts the native down.
                // RE-confirmed in AppKit 13.4: activateIgnoringOtherApps:
                // tail-calls _NXActivateSelf, whose effective operation is
                // SetFrontProcessWithOptions. Runtime evidence from Electron
                // showed that doing this after its native down was too late:
                // the process already owned the global front/menu state but
                // never received _handleActivatedEvent: and stayed inactive.
                // The RFB button packet is already a real user action here;
                // this control record creates no NSEvent. A short bounded
                // handoff lets macwsinputd query the still-responsive target
                // before a synchronous contextual-menu tracker can occupy its
                // main thread. The original OSXvnc path below remains the sole
                // owner and dispatcher of the actual down event.
                (void)macws_vnc_coordinate_activation(point);
            }
            BOOL secondaryRelease =
                (previousPointerButtons & 4u) != 0 &&
                (pointerButtons & 4u) == 0;
            if (secondaryRelease) {
                // Runtime-confirmed on 2026-07-29: separate OSXvnc CG right-
                // down/up posts were scheduler-dependent. Some clicks entered
                // rightMouseDown after release and tracked; others returned in
                // under 1 ms without a menu. Emit one SecondaryTap record on
                // release so the selected process constructs the complete
                // AppKit pair atomically, matching the proven primary Tap
                // transport instead of tuning an arbitrary sleep.
                if (macws_runtime_diagnostics_enabled()) {
                    static _Atomic uint64_t serializedRightUps;
                    uint64_t serialized = atomic_fetch_add_explicit(
                        &serializedRightUps, 1,
                        memory_order_relaxed) + 1;
                    if (serialized <= 24 || (serialized % 100) == 0) {
                    fprintf(stderr,
                        "#### OSXVNC RIGHT-UP-SERIALIZE event=%llu "
                        "route=app-input-secondary-tap rfb=(%.1f,%.1f)\n",
                        (unsigned long long)serialized, point.x, point.y);
                    }
                }
            }
            BOOL secondaryGesture =
                ((previousPointerButtons | pointerButtons) & 4u) != 0;
            if (secondaryGesture) {
                // Keep OSXvnc's cursor/client bookkeeping but leave the right
                // button out of its asynchronous global CG stream.
                macws_orig_vnc_handle_mouse(
                    self, command, pointerButtons & ~4u,
                                            quartzPoint, client);
                if (secondaryRelease && macws_vnc_secondary_pending) {
                    macws_vnc_gesture_id++;
                    if (macws_vnc_gesture_id == 0) macws_vnc_gesture_id++;
                    BOOL sent = macws_vnc_forward_input(
                        MacWSInputKindSecondaryTap,
                        macws_vnc_secondary_down_point, YES);
                    if (macws_runtime_diagnostics_enabled()) {
                        fprintf(stderr,
                            "#### OSXVNC CLICK-OWNER "
                            "route=app-input-secondary gesture=%u "
                            "point=(%.1f,%.1f) sent=%s\n",
                            macws_vnc_gesture_id,
                            macws_vnc_secondary_down_point.x,
                            macws_vnc_secondary_down_point.y,
                            sent ? "YES" : "NO");
                    }
                    if (sent)
                        macws_vnc_schedule_secondary_tap_frames(
                            macws_vnc_gesture_id);
                    macws_vnc_secondary_pending = NO;
                }
            } else {
                // RFB buttons 4..7 are wheel impulses, not persistent mouse
                // buttons. The stock CG route receives them but, runtime-
                // confirmed by InputLab, produces zero scrollWheel events in
                // this coexist session. Keep cursor/primary state native and
                // give each wheel impulse one AppInput semantic owner below.
                macws_orig_vnc_handle_mouse(self, command, pointerButtons,
                                            quartzPoint, client);
            }
            if (wheelPressed != 0) {
                float horizontal = 0.0f;
                float vertical = 0.0f;
                if (wheelPressed & 8u) vertical += 40.0f;
                if (wheelPressed & 16u) vertical -= 40.0f;
                if (wheelPressed & 32u) horizontal += 40.0f;
                if (wheelPressed & 64u) horizontal -= 40.0f;
                (void)macws_vnc_forward_scroll(
                    point, horizontal, vertical);
            }
            // OSXvnc remains the owner of cursor state and primary native
            // drags; an atomic AppInput record owns secondary clicks. After
            // the cursor bookkeeping update, send a query-only target refresh
            // and then a button-free AppKit hover.
            // This reproduces the runtime-confirmed native-move + scoped
            // NSEvent.mouseLocation sequence required by macOS 13.4 menu
            // presentation without duplicating a button event.
            // A secondary gesture already resolves and stores menuTarget via
            // ActivateTarget before the atomic SecondaryTap is delivered.
            // Do not queue another query after either right-button edge.
            // Runtime-confirmed on 2026-07-30: immediately after Terminal
            // accepted SecondaryTap and entered its real synchronous menu
            // tracker, the redundant TargetProbe received 0/1 replies and
            // blocked macwsinputd's single routing loop for its full 150-ms
            // deadline. Menu hover and Escape were therefore delayed behind
            // a query whose authoritative answer was already cached. The
            // actual right-click event and activation transaction are
            // unchanged; this only removes the duplicate control-plane query.
            BOOL targetRefreshDue = !secondaryGesture &&
                (buttonTransition ||
                 macws_vnc_last_hover_target_probe <= 0.0 ||
                 now - macws_vnc_last_hover_target_probe >= 2.0);
            if (targetRefreshDue && macws_vnc_forward_input(
                    MacWSInputKindTargetProbe, point, YES)) {
                macws_vnc_last_hover_target_probe = now;
            }
            if (pointerButtons == 0 && wheelPressed == 0) {
                MacWSInputKind hoverKind =
                    now < macws_vnc_menu_hover_until
                        ? MacWSInputKindMenuHover
                        : MacWSInputKindHover;
                (void)macws_vnc_forward_input(
                    hoverKind, point, NO);
                if (hoverKind == MacWSInputKindMenuHover &&
                    macws_runtime_diagnostics_enabled()) {
                    static _Atomic uint64_t menuHoverRoutes;
                    uint64_t route = atomic_fetch_add_explicit(
                        &menuHoverRoutes, 1, memory_order_relaxed) + 1;
                    if (route <= 64 || (route % 600) == 0) {
                        fprintf(stderr,
                            "#### OSXVNC MENU-HOVER-ROUTE event=%llu "
                            "now=%.6f until=%.6f point=(%.1f,%.1f)\n",
                            (unsigned long long)route, now,
                            macws_vnc_menu_hover_until,
                            point.x, point.y);
                    }
                }
            }
            if (macws_runtime_diagnostics_enabled()) {
                static _Atomic uint64_t nativeEvents;
                uint64_t nativeEvent = atomic_fetch_add_explicit(
                    &nativeEvents, 1, memory_order_relaxed) + 1;
                if (nativeEvent <= 96 || (nativeEvent % 600) == 0) {
                fprintf(stderr,
                    "#### OSXVNC NATIVE-ALL event=%llu buttons=%#x "
                    "pointer=%#x wheel=%#x rfb=(%.1f,%.1f) "
                    "quartz=(%.1f,%.1f) scale=%d\n",
                    (unsigned long long)nativeEvent, buttons,
                    pointerButtons, wheelPressed,
                    point.x, point.y, quartzPoint.x, quartzPoint.y, scale);
                }
            }
            atomic_store_explicit(&macws_vnc_native_buttons, buttons,
                                  memory_order_release);
            // The producer-completion bridge now keeps a bounded latest-state
            // slot, so a final static composite cannot be dropped behind an
            // older observer.  The historical 12/48/80-ms capture-file burst
            // never caused AppKit to draw; it merely sampled whichever frame
            // happened to exist and added six file/GPU-observation races to a
            // simple click. Retain it only as an explicit diagnostic A/B.
            // Contextual menus keep their separate bounded open/final probes
            // until their nested tracking lifecycle has its own test witness.
            if (macws_runtime_diagnostics_enabled()) {
                macws_vnc_schedule_native_pointer_frames(
                    pointerButtons, buttonTransition || wheelPressed != 0);
            }
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
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### OSXVNC CLICK-OWNER route=app-input gesture=%u "
                        "point=(%.1f,%.1f) sent=%s\n",
                        macws_vnc_gesture_id,
                        macws_vnc_pending_down_point.x,
                        macws_vnc_pending_down_point.y,
                        sent ? "YES" : "NO");
                }
                macws_vnc_pending_down = NO;
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
            } else if (macws_vnc_remote_down) {
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
                macws_vnc_remote_down = NO;
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### OSXVNC DRAG-OWNER route=native gesture=%u "
                        "point=(%.1f,%.1f)\n",
                        macws_vnc_gesture_id, point.x, point.y);
                }
            } else {
                macws_orig_vnc_handle_mouse(self, command, 0,
                                            quartzPoint, client);
            }
        } else {
            macws_orig_vnc_handle_mouse(self, command, 0,
                                        quartzPoint, client);
        }
        static unsigned ownershipLogs;
        if (macws_runtime_diagnostics_enabled() && ownershipLogs++ < 8) {
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

IOSurfaceRef macws_vnc_src = NULL;
// Returns true only when a complete mmap frame was copied.  A test gradient is
// diagnostic output and deliberately does not count as a real shared frame.
bool macws_vnc_fill_test(int rectX, int rectY,
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
    static int rmap_fd = -1;
    if (!rmap) {
        int fd = open("/tmp/macws_vnc_fb", O_RDONLY);
        if (fd >= 0) {
            BOOL retainedFD = NO;
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size >= 16) {
                void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
                if (m != MAP_FAILED) {
                    rmap = m;
                    rmap_fd = fd;
                    retainedFD = YES;
                    rmap_sz = (size_t)st.st_size;
                }
            }
            if (!retainedFD) close(fd);
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
                BOOL scaleCopy = bytespp == 4 && sw > 0 && sh > 0 &&
                    dw > 0 && height > 0 &&
                    (sw != dw || sh != (size_t)height);
                size_t rows = ((size_t)height < sh)
                    ? (size_t)height : sh;
                size_t byteX = x0 * (size_t)bytespp;
                size_t byteCount = (x1 - x0) * (size_t)bytespp;
                if (!scaleCopy &&
                    (byteX + byteCount > (size_t)padded ||
                     byteX + byteCount > sstride)) return false;

                BOOL sharedLocked = rmap_fd >= 0 &&
                    flock(rmap_fd, LOCK_SH) == 0;
                unsigned attempts = sharedLocked ? 1 : 4;
                for (unsigned attempt = 0; attempt < attempts; attempt++) {
                    uint64_t before = atomic_load_explicit(
                        sequenceAddress, memory_order_acquire);
                    if (before == 0 || (before & 1u)) {
                        if (!sharedLocked) usleep(1000);
                        continue;
                    }
                    if (scaleCopy) {
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
                        if (y1 > rows) y1 = rows;
                        for (size_t y = y0; y < y1; y++)
                            memcpy(macws_vnc_fb + y * (size_t)padded + byteX,
                                   data + y * sstride + byteX, byteCount);
                    }
                    atomic_thread_fence(memory_order_acquire);
                    uint64_t after = atomic_load_explicit(
                        sequenceAddress, memory_order_acquire);
                    if (after == before && !(after & 1u)) {
                        if (sharedLocked)
                            (void)flock(rmap_fd, LOCK_UN);
                        return true;
                    }
                    if (!sharedLocked) usleep(1000);
                }
                if (sharedLocked) (void)flock(rmap_fd, LOCK_UN);
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

char *macws_new_rfbGetFB(void) {
    char *p = macws_orig_rfbGetFB ? macws_orig_rfbGetFB() : NULL;
    macws_vnc_fb = p;
    macws_vnc_fill_test(0, 0, 0, 0);
    return p;
}
void macws_new_rfbGetFBRect(int x, int y, int w, int h) {
    // In shared-frame mode, rfbGetFramebuffer() has already allocated the
    // server buffer. Calling the original rectangle updater would enter
    // CGDisplayCreateImage/_XHWCaptureDesktop again. Runtime crash evidence:
    // WSIOSurfaceDebugTallyAndAbort -> CreateCaptureSurface ->
    // _XHWCaptureDesktop while a VNC update was in progress. The mmap is the
    // selected capture backend, so deliver it directly. If its first frame is
    // not ready yet, preserve the allocated buffer and wait for the next poll.
    if (macws_vnc_share_on) {
        if (macws_vnc_rfb_prefetched) return;
        double started = macws_vnc_monotonic_seconds();
        bool copied = macws_vnc_fill_test(x, y, w, h);
        macws_vnc_rfb_copy_milliseconds +=
            (macws_vnc_monotonic_seconds() - started) * 1000.0;
        macws_vnc_rfb_copy_calls++;
        if (w > 0 && h > 0)
            macws_vnc_rfb_copy_pixels += (uint64_t)w * (uint64_t)h;
        static int lg = 0;
        if (macws_runtime_diagnostics_enabled() && lg < 3) {
            fprintf(stderr, "#### OSXVNC mmap rect delivery copied=%d rect=%d,%d %dx%d\n",
                    copied ? 1 : 0, x, y, w, h);
            lg++;
        }
        return;
    }
    if (macws_orig_rfbGetFBRect) macws_orig_rfbGetFBRect(x, y, w, h);
    macws_vnc_fill_test(x, y, w, h);
}

void macws_install_osxvnc_hooks(void) {
    const char *prog = getprogname();
    if (!prog || !strstr(prog, "OSXvnc")) return;
    macws_vnc_test_on = (access("/tmp/macws_vnc_test", F_OK) == 0);
    macws_vnc_share_on = (getenv("MACWS_VNC_SHARE") ||
                          access("/tmp/macws_vnc_share", F_OK) == 0);
    const char *inputMode = getenv("MACWS_VNC_INPUT_MODE");
    macws_vnc_native_all = getenv("MACWS_VNC_NATIVE_ALL") != NULL ||
        access("/tmp/macws_vnc_native_all", F_OK) == 0;
    if (inputMode && strcmp(inputMode, "stock") == 0) {
        macws_vnc_input_mode = MacWSVNCInputModeStock;
        macws_vnc_native_all = NO;
    } else if (inputMode && strcmp(inputMode, "scale-only") == 0) {
        macws_vnc_input_mode = MacWSVNCInputModeScaleOnly;
        macws_vnc_native_all = NO;
    } else if ((inputMode && strcmp(inputMode, "hybrid") == 0) ||
               macws_vnc_native_all) {
        macws_vnc_input_mode = MacWSVNCInputModeHybrid;
        macws_vnc_native_all = YES;
    } else {
        // Preserve the pre-input-hook baseline when no input policy was
        // requested. Framebuffer delivery remains installed below.
        macws_vnc_input_mode = MacWSVNCInputModeStock;
    }
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
    BOOL traceClientMessages =
        getenv("MACWS_VNC_TRACE_CLIENT_MESSAGES") != NULL;
    if (traceClientMessages) {
        MSHookFunction(base + 0x169d8,
            (void *)macws_new_vnc_read_exact,
            (void **)&macws_orig_vnc_read_exact);
        MSHookFunction(base + 0x14380,
            (void *)macws_new_vnc_process_normal_message,
            (void **)&macws_orig_vnc_process_normal_message);
    }
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
    MSHookFunction(base + 0x14e38,
        (void *)macws_new_rfb_send_framebuffer_update,
        (void **)&macws_orig_rfb_send_framebuffer_update);
    Class serverClass = objc_getClass("VNCServer");
    Method mouseMethod = serverClass ? class_getInstanceMethod(serverClass,
        sel_registerName("handleMouseButtons:atPoint:forClient:")) : NULL;
    if (mouseMethod && macws_vnc_input_mode != MacWSVNCInputModeStock) {
        macws_orig_vnc_handle_mouse =
            (MacWSVNCHandleMouse)method_getImplementation(mouseMethod);
        method_setImplementation(mouseMethod, (IMP)macws_new_vnc_handle_mouse);
    }
    Method sendKeyMethod = serverClass ? class_getInstanceMethod(serverClass,
        sel_registerName("sendKeyEvent:down:modifiers:")) : NULL;
    if (sendKeyMethod && macws_vnc_input_mode == MacWSVNCInputModeHybrid) {
        macws_orig_vnc_send_key_event =
            (MacWSVNCSendKeyEvent)method_getImplementation(sendKeyMethod);
        method_setImplementation(sendKeyMethod,
                                 (IMP)macws_new_vnc_send_key_event);
    }
    Method setKeyModifiersMethod = serverClass ? class_getInstanceMethod(
        serverClass, sel_registerName("setKeyModifiers:")) : NULL;
    Ivar currentModifiersIvar = serverClass ? class_getInstanceVariable(
        serverClass, "currentModifiers") : NULL;
    if (setKeyModifiersMethod && currentModifiersIvar &&
        macws_vnc_input_mode == MacWSVNCInputModeHybrid) {
        macws_vnc_current_modifiers_offset =
            ivar_getOffset(currentModifiersIvar);
        macws_orig_vnc_set_key_modifiers =
            (MacWSVNCSetKeyModifiers)method_getImplementation(
                setKeyModifiersMethod);
        method_setImplementation(setKeyModifiersMethod,
                                 (IMP)macws_new_vnc_set_key_modifiers);
    }
    Method keyboardMethod = serverClass ? class_getInstanceMethod(serverClass,
        sel_registerName("handleKeyboard:forSym:forClient:")) : NULL;
    if (keyboardMethod && macws_vnc_input_mode == MacWSVNCInputModeHybrid) {
        macws_orig_vnc_handle_keyboard =
            (MacWSVNCHandleKeyboard)method_getImplementation(keyboardMethod);
        method_setImplementation(keyboardMethod,
                                 (IMP)macws_new_vnc_handle_keyboard);
    }
    if (macws_vnc_share_on && macws_vnc_refresh_callback) {
        pthread_t damageListener;
        int damageError = pthread_create(
            &damageListener, NULL, macws_vnc_damage_listener, NULL);
        if (damageError == 0) pthread_detach(damageListener);
        else fprintf(stderr,
            "#### OSXVNC DAMAGE listener thread failed error=%d\n",
            damageError);
        pthread_t watcher;
        int watcherError = pthread_create(
            &watcher, NULL, macws_vnc_generation_watcher, NULL);
        if (watcherError == 0) pthread_detach(watcher);
        else fprintf(stderr,
            "#### OSXVNC mmap generation watcher failed error=%d\n",
            watcherError);
    }
    const char *inputModeName = macws_vnc_input_mode == MacWSVNCInputModeStock
        ? "stock" : (macws_vnc_input_mode == MacWSVNCInputModeScaleOnly
            ? "scale-only" : "hybrid");
    fprintf(stderr, "#### OSXVNC delivery hooks installed (test=%d share=%d input-mode=%s native-all=%d client-trace=%d input=%s keyboard=%s key-map=%s key-modifiers=%s modifiers-offset=%td) base=%p rfbScreen=%p\n",
            macws_vnc_test_on, macws_vnc_share_on, inputModeName,
            macws_vnc_native_all,
            traceClientMessages,
            mouseMethod && macws_vnc_input_mode != MacWSVNCInputModeStock
                ? "YES" : "NO",
            keyboardMethod && macws_vnc_input_mode == MacWSVNCInputModeHybrid
                ? "YES" : "NO",
            sendKeyMethod && macws_vnc_input_mode == MacWSVNCInputModeHybrid
                ? "YES" : "NO",
            setKeyModifiersMethod && currentModifiersIvar &&
                macws_vnc_input_mode == MacWSVNCInputModeHybrid ? "YES" : "NO",
            macws_vnc_current_modifiers_offset,
            (void *)mh, (void *)macws_rfbScreen);
}

extern void MacWSInstallExtensionRuntimeCompatibility(void);

// Ventura 13.4 has no ExtensionKit feature-flag domain.  The chrooted image
// nevertheless resolves libsystem_featureflags against iPadOS's already-live
// feature state, whose /System/Library/FeatureFlags/Domain/ExtensionKit.plist
// enables `automatically_sandbox_extensions` and
// `prefer_inprocess_discovery`.  Runtime evidence from the real Ventura
// ExtensionFoundation boundary is exact:
//
//   _EXDefaults.forceSandbox = 1
//   _EXDiscoveryController canRunQuery:error: = 0
//   _LSApplicationExtensionRecordEnumerator recordCount=1 matchCount=1
//
// The corresponding macOS rootfs originally has no ExtensionKit.plist at all,
// while the outer iPadOS file explicitly sets these flags true.  Restore the
// target OS's absent-domain/default-false semantics at the feature provider,
// before ExtensionFoundation decides whether its legitimate LS records are
// admissible.  This is not a query/check bypass: every stock query, extension
// entitlement, LS match, and ExtensionKit launch remains responsible for its
// own normal validation.
macws_os_feature_enabled_impl_fn
    macws_os_feature_enabled_impl_orig = NULL;
bool macws_os_feature_enabled_impl_compat(const char *domain,
                                                  const char *feature) {
    if (domain && strcmp(domain, "ExtensionKit") == 0) {
        if (getenv("MACWS_RUNTIME_DIAGNOSTICS")) {
            fprintf(stderr,
                    "#### FEATUREFLAGS target-macos domain=%s feature=%s "
                    "enabled=0\n", domain, feature ?: "<nil>");
        }
        return false;
    }
    return macws_os_feature_enabled_impl_orig
        ? macws_os_feature_enabled_impl_orig(domain, feature) : false;
}

void macws_install_target_feature_flag_compatibility(void) {
    if (macws_os_feature_enabled_impl_orig) return;
    void *provider = dlsym(RTLD_DEFAULT, "_os_feature_enabled_impl");
    if (!provider) return;
    MSHookFunction(provider,
                   (void *)macws_os_feature_enabled_impl_compat,
                   (void **)&macws_os_feature_enabled_impl_orig);
}

__attribute__((constructor)) void InitStuff() {
    // VS Code 1.130 marks both its login shell and the Electron-as-Node
    // environment printer with this exact value.  Runtime-confirmed: running
    // the normal GUI/JIT initialization in the printer aborts while reserving
    // Oilpan's CagedHeap; skipping only this constructor leaves Metal's
    // constructor to SIGBUS in libroot.  All four heavy constructors honor the
    // same narrow marker, while this dylib's dyld interposes (notably
    // os_variant) remain active.  VS Code deletes the marker from the parsed
    // result before launching its real main/render/GPU processes.
    const char *shell_env = getenv("VSCODE_RESOLVING_ENVIRONMENT");
    if (shell_env && strcmp(shell_env, "1") == 0) {
        fprintf(stderr,
            "#### VSCODE-SHELL-ENV minimal compatibility mode: "
            "GUI/JIT/AGX constructors disabled\n");
        return;
    }
    macws_install_glass_blur_ab_if_requested();
    // A tiny root child retained by the settings-extension launch proxy marks
    // the final post-exec process through `jbctl proc_set_debugged`.  Wait only
    // for that explicitly identified process class; ordinary applications
    // continue through EnableJIT with no launch delay.
    const char *appExtension = getenv("MACWS_APP_EXTENSION");
    if (appExtension && strcmp(appExtension, "1") == 0) {
        for (unsigned int attempt = 0;
             attempt < 2000 && !isJITEnabled(); attempt++) {
            usleep(1000);
        }
    }
    EnableJIT();
    macws_install_target_feature_flag_compatibility();
    // Settings extensions carry libmachook through a bundle-local load command.
    // Retry their ExtensionFoundation/LaunchServices boundary only after the
    // post-exec process has CS_DEBUGGED, so both Objective-C class availability
    // and executable replacement-code admission are established.
    MacWSInstallExtensionRuntimeCompatibility();
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

    // Existing-image callbacks may have queued the Maps adapter while ObjC
    // registration was still unwinding. At constructor time the dependency
    // images are normally realized already, so make one synchronous,
    // idempotent attempt before UIApplicationMain can create the shared
    // MKLocationManager. The queued worker remains only as a fallback.
    (void)macws_install_maps_location_capability_adapter();

    // POSIX_SPAWN_START_SUSPENDED stops before dyld has initialized the
    // macOS image.  Maps exits during that debugger path before its normal
    // framework bootstrap completes, so service tracing needs a later,
    // explicit attach point.  This diagnostic gate stops only after
    // libmachook has installed its compatibility interposes and image
    // callback; no protocol result or application state is fabricated.
    const char *lateLLDBHold = getenv("MACWS_LLDB_HOLD_AFTER_INIT");
    if (lateLLDBHold && strcmp(lateLLDBHold, "1") == 0) {
        const char *holdTarget = getenv("MACWS_SUSPEND_TARGET");
        const char *program = getprogname();
        if (!holdTarget || !*holdTarget ||
            (program && strcmp(holdTarget, program) == 0)) {
            fprintf(stderr,
                    "#### MACWS_LLDB_HOLD_AFTER_INIT target=%s pid=%d "
                    "stopping after compatibility init\n",
                    program ?: "(unknown)", getpid());
            fflush(stderr);
            raise(SIGSTOP);
        }
    }
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
bool macws_mach_msg_trace_enabled(void) {
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

// Diagnostic-only observer for Ventura locationd's MIG receive boundary.
// Apple's open-source libdispatch declares this callback ABI as
// boolean_t (*)(mach_msg_header_t *, mach_msg_header_t *) and invokes the
// callback synchronously inside dispatch_mig_server().  Keep the active
// callback thread-local so concurrent dispatch sources retain their exact
// original demux routine.  The wrapper records only headers; it neither
// changes a request/reply byte nor fabricates a successful result.
extern mach_msg_return_t dispatch_mig_server(
    dispatch_source_t source, size_t max_message_size,
    macws_dispatch_mig_callback_t callback);

_Thread_local macws_dispatch_mig_callback_t
    g_macws_locationd_mig_callback;
_Atomic unsigned g_macws_locationd_mig_record_count;

boolean_t macws_locationd_mig_callback(
    mach_msg_header_t *request, mach_msg_header_t *reply) {
    macws_dispatch_mig_callback_t callback =
        g_macws_locationd_mig_callback;
    if (!callback) return FALSE;

    unsigned record = atomic_fetch_add_explicit(
        &g_macws_locationd_mig_record_count, 1, memory_order_relaxed);
    if (record < 256 && request) {
        dprintf(STDERR_FILENO,
                "#### MACWS LOCATIOND-MIG receive #%u id=%#x size=%u "
                "bits=%#x remote=%u local=%u\n",
                record + 1, request->msgh_id, request->msgh_size,
                request->msgh_bits, request->msgh_remote_port,
                request->msgh_local_port);
    }
    boolean_t handled = callback(request, reply);
    if (record < 256) {
        dprintf(STDERR_FILENO,
                "#### MACWS LOCATIOND-MIG demux #%u handled=%d "
                "reply_id=%#x reply_size=%u\n",
                record + 1, handled, reply ? reply->msgh_id : 0,
                reply ? reply->msgh_size : 0);
    }
    return handled;
}

mach_msg_return_t macws_dispatch_mig_server(
    dispatch_source_t source, size_t max_message_size,
    macws_dispatch_mig_callback_t callback) {
    const char *program = getprogname();
    if (!program || strcmp(program, "locationd") != 0 ||
        !getenv("MACWS_LOCATIOND_MIG_TRACE") || !callback) {
        return dispatch_mig_server(source, max_message_size, callback);
    }
    macws_dispatch_mig_callback_t previous =
        g_macws_locationd_mig_callback;
    g_macws_locationd_mig_callback = callback;
    mach_msg_return_t result = dispatch_mig_server(
        source, max_message_size, macws_locationd_mig_callback);
    g_macws_locationd_mig_callback = previous;
    return result;
}

// Simulate functions that are not implemented in iOS kernel.
//
// A macOS GUI login session has one audit-session ID shared by WindowServer,
// LaunchServices, and every application in that session.  iOS leaves
// audit_token_t.val[6] at zero for these chroot processes.  The historical
// fallback copied val[5] (pid), which silently created one LaunchServices
// session per process.  Runtime watchpoints then showed WindowServer writing
// Terminal as CGXSessionProcessData::frontProcess, followed by
// GetFrontProcessRecCheckingEligibility replacing it with Code after
// _LSCopyFrontApplication consulted the pid-scoped session.  Use one stable,
// positive synthetic ASID for the entire chroot instead.  Preserve a real
// non-zero ASID if a future kernel supplies one.
const au_asid_t MacWSSharedAuditSessionID =
    (au_asid_t)0x004d5753; // "MWS"

au_asid_t audit_token_to_asid_new(audit_token_t atoken) {
    return atoken.val[6] != 0
        ? (au_asid_t)atoken.val[6] : MacWSSharedAuditSessionID;
}
uid_t audit_token_to_auid_new(audit_token_t atoken) {
    return atoken.val[0] = 501;
}
void auditinfo_fill(auditinfo_addr_t *addr) {
    if(addr->ai_asid == 0) {
        addr->ai_asid = MacWSSharedAuditSessionID;
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
    addr->ap_asid = MacWSSharedAuditSessionID;
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
    auditinfo_addr->ai_asid = MacWSSharedAuditSessionID;
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
        if (macws_jit_fault_write_compat_enabled()) {
            // Start executable.  A scoped writer receives RW only on the
            // individual pages it actually touches via the SIGBUS data-fault
            // path, preserving W^X without invalidating the full CodeRange.
            effective = PROT_READ | PROT_EXEC;
        } else {
            // Legacy whole-range adapter: iOS's VM_MAP_POLICY_WX_STRIP_X
            // performs this same reduction for a normal mapping.  Make it
            // explicit so V8 receives the writable half of the contract;
            // pthread_jit_write_protect_np_new supplies RX.
            effective = PROT_READ | PROT_WRITE;
        }
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
        if (macws_jit_trace_enabled()) {
            unsigned sequence = atomic_fetch_add_explicit(
                &g_macws_jit_remap_declines, 1, memory_order_relaxed) + 1;
            fprintf(stderr,
                "#### JIT-MPROTECT remap decline #%u dst=%p size=%#llx "
                "src=%p requested=%#x -> V8 copy fallback\n",
                sequence, (void *)(uintptr_t)*target_address,
                (unsigned long long)size, (void *)(uintptr_t)source_address,
                requested);
        }
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

    if (macws_jit_fault_write_compat_enabled()) {
        pthread_mutex_lock(&g_macws_jit_state_lock);
        if (!enabled) {
            if (!g_macws_jit_thread_writable) {
                // The fallback mmap can initially be RW because iOS strips X
                // from a requested RWX mapping.  Establish RX exactly once
                // before the first scoped write so that touched pages fault
                // into the dirty-page list.
                if (atomic_exchange_explicit(&g_macws_jit_needs_initial_rx,
                                             false,
                                             memory_order_acq_rel)) {
                    macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
                }
                unsigned writers = atomic_load_explicit(
                    &g_macws_jit_active_writers, memory_order_relaxed);
                atomic_store_explicit(&g_macws_jit_active_writers,
                                      writers + 1, memory_order_release);
                g_macws_jit_thread_writable = true;
            }
        } else if (g_macws_jit_thread_writable) {
            g_macws_jit_thread_writable = false;
            unsigned writers = atomic_load_explicit(
                &g_macws_jit_active_writers, memory_order_relaxed);
            if (writers == 1) {
                // Keep the writer published until every dirtied page is RX;
                // an instruction fetch on one of those pages waits in the
                // SIGBUS barrier and retries only after the release store.
                if (atomic_exchange_explicit(&g_macws_jit_needs_initial_rx,
                                             false,
                                             memory_order_acq_rel)) {
                    macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
                    atomic_store_explicit(&g_macws_jit_dirty_page_count, 0,
                                          memory_order_release);
                    atomic_store_explicit(
                        &g_macws_jit_dirty_page_overflow, false,
                        memory_order_release);
                } else {
                    macws_jit_restore_dirty_pages();
                }
                atomic_store_explicit(&g_macws_jit_active_writers, 0,
                                      memory_order_release);
            } else if (writers > 1) {
                atomic_store_explicit(&g_macws_jit_active_writers,
                                      writers - 1, memory_order_release);
            }
        } else if (atomic_load_explicit(&g_macws_jit_active_writers,
                                        memory_order_acquire) == 0 &&
                   atomic_exchange_explicit(&g_macws_jit_needs_initial_rx,
                                            false,
                                            memory_order_acq_rel)) {
            macws_jit_set_all_permissions(PROT_READ | PROT_EXEC);
        }
        pthread_mutex_unlock(&g_macws_jit_state_lock);
        return;
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

