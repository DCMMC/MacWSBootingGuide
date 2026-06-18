@import CydiaSubstrate;
@import Foundation;
@import Darwin;
#include <stdarg.h>
#include <time.h>
#include <syslog.h>
#include <mach-o/dyld.h>

// NOTE: do NOT take an ObjC block here. Under -fobjc-arc the on-device lld
// arm64e build mis-signs the block's metadata pointer, so ARC's objc_storeStrong
// on the block parameter PAC-faults in this dylib's %ctor (crashes MTLCompilerService
// on inject -> deadlocks the whole Metal/WindowServer path). Patch the word directly.
static void PatchInstruction(uint32_t *addr, uint32_t value) {
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    *addr = value;
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_EXEC);
}

// ─── AGXCompilerCore verifyLoweredIR bypass ─────────────────────────────
//
// The macOS-13.4 AIR that chroot WindowServer hands to MTLCompilerService
// uses `air.fract.v3f16` (fract on half3). Inside AGXCompilerCore an
// optimisation pass renames it to the AGX-internal name
// `agx.air.fract.v3f16.fast` (the same rename that exists for
// `air.fast_fract.v2f32` etc.). But the dispatch table built by
// `AGCLLVMAirBuiltinsMap::insertBuiltinReplacementsBase` only has keys
// `"fract"` and `"fast_fract"` — there's no entry for the typed-suffix
// `fract.v3f16.fast` form. `AGCLLVMUserObject::verifyLoweredIR()` then
// iterates the module's function list, finds the unlowered declaration
// whose name still contains "air.", logs
//   "Encountered unlowered function call to agx.air.fract.v3f16.fast"
// via _os_log_fault_impl, and the surrounding compile pipeline captures
// that log into the abort_with_payload(13, 4, …) reason string that CA
// turns into "Metal failed to build render pipeline" → WindowServer dies.
//
// Crucially: `AGCLLVMAirBuiltins::buildFastFract` IS implemented (and
// the v3f16 path inside it is the trivial `x - floor(x)` lowering — the
// f32-specific post-clamp is skipped by `cmp w10, #0x2 ; b.ne epilogue`
// at the start of its body). So if we silence the verifier's complaint
// about the rename, downstream codegen will either emit a working
// lowering itself or carry the call as a declaration the GPU runtime
// resolves via builtin tables — either way, the host-side abort goes
// away and we get to observe the actual GPU behaviour.
//
// The verifier function's symbol is stripped from the iOS-side
// AGXCompilerCore so MSFindSymbol can't locate it directly. Instead we
// anchor on the exported `_AIRNTGetVersion` (one of 33 surviving public
// `AIRNT*` symbols) and use the static delta measured against the
// iPad13,6 16.3.1 (20D67) Symbols build:
//
//   verifier = AIRNTGetVersion - 0x5fb78
//
// (verifier @ 0x1be30999c, AIRNTGetVersion @ 0x1be369514 in that build).
//
// Patch is one instruction: `pacibsp` at function entry → `ret`. The
// caller's BL set LR to the next instruction in the caller; no stack
// frame has been built yet, so simply returning to LR is correct and
// avoids the verifier's iteration over the module's function list.
//
// If the byte at the computed address is not `pacibsp` (0xd503237f),
// the iOS AGXCompilerCore has changed and the anchor needs re-checking;
// we abort instead of silently corrupting an unknown instruction.
// ─── AGX renamer fix: skip the "agx." prepend ─────────────────────────────
//
// `AGCLLVMUserObject::linkMetalRuntime(bool)` walks the module's
// runtime-shim function list and for each function builds a renamed
// declaration `"agx." + originalName + ".fast"`, replaces uses, and
// hands the new declaration to the next pass. For an originalName like
// `air.fract.v3f16` the produced name `agx.air.fract.v3f16.fast` is
// never matched by `AGCLLVMAirBuiltins::replaceBuiltins`'s dispatcher
// (which only accepts the "air." prefix), so the call survives into
// `AGCLLVMUserObject::verifyLoweredIR` as an unlowered declaration and
// the compile aborts.
//
// The rename is implemented as a `std::string::insert(0, "agx.")` call
// — instruction `bl __ZNSt3__112basic_string…::insert(pos, str)` that
// follows the `add x2, x2, #… ; "agx."` adrp pair. If we NOP that one
// BL the agx-prefix step is skipped: the rename becomes
// `"" + originalName + ".fast" = "air.fract.v3f16.fast"`, the
// dispatcher's findPrefix accepts the "air." prefix, splits at the
// first dot of the remainder into ("fract", "v3f16.fast"), and the
// "fract" key already resolves to `AGCLLVMAirBuiltins::buildFract`,
// which lowers via the operand's runtime LLVM type — the trailing
// ".fast" in the name is just a suffix on the Function name and is
// ignored by buildFract (it reads the actual Value type, not the
// Function name).
//
// The patch site is found by anchoring on the surviving export
// `_AIRNTGetVersion` (one of the 33 public AIRNT* symbols). Delta
// measured against the iPad13,6 16.3.1 (20D67) DSC:
//   bl insert @ 0x1be243b70
//   _AIRNTGetVersion @ 0x1be369514
//   delta = -0x1259a4
//
// Validation: the instruction at the patch site must be a BL (opcode
// bits 26..31 == 0b100101 == 0x25). If the iOS AGXCompilerCore has
// changed and the byte is not a BL, we leave the original behaviour
// alone instead of corrupting some unknown instruction.
// Sandboxed XPC services (like MTLCompilerService under its
// `seatbelt-profiles=[MTLCompilerService]` profile) cannot create files
// outside /private/var/mobile, so the old fopen("/tmp/...") path silently
// failed. Try multiple destinations: a file under /var/mobile (writable
// by the XPC service's sandbox), syslog (tagged "MTLBypass"), and stderr.
static void MTLPatchLog(const char *fmt, ...) {
    static int once = 0;
    if (!once) { openlog("MTLBypass", LOG_PID | LOG_NDELAY, LOG_USER); once = 1; }
    char buf[512];
    pid_t pid = getpid();
    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    int hdr = snprintf(buf, sizeof(buf),
        "[%04d-%02d-%02d %02d:%02d:%02d pid=%d] ",
        tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, pid);
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf + hdr, sizeof(buf) - hdr, fmt, ap);
    va_end(ap);
    syslog(LOG_NOTICE, "%s", buf + hdr);
    fprintf(stderr, "#### MTLBypass %s\n", buf + hdr);
    fflush(stderr);
    // Try several paths until one is writable from the sandbox.
    static const char *paths[] = {
        "/var/mobile/Library/Logs/mtl_compiler_patch.log",
        "/var/mobile/mtl_compiler_patch.log",
        "/var/jb/var/mobile/mtl_compiler_patch.log",
        "/tmp/mtl_compiler_patch.log",
        NULL,
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "a");
        if (f) {
            fputs(buf, f);
            fputc('\n', f);
            fclose(f);
            return;
        }
    }
}

// Strip arm64e PAC bits from a pointer. dlsym/MSFindSymbol on arm64e
// returns PAC-signed pointers for code symbols; doing pointer arithmetic
// on them carries the PAC bits into the result and the dereference faults.
// Mask the lower 48 bits — arm64e iOS uses 47-bit virtual addresses so
// bits 47..63 hold the PAC tag.
static uintptr_t StripPAC(const void *p) {
    return (uintptr_t)p & 0x0000FFFFFFFFFFFFull;
}

// Scan a window around (anchor + delta_hint) for the BL site preceded by
// `add x2, x2, #<imm12>` where the imm12 is the offset of the "agx."
// literal within its __cstring page. Two known imm12 values across the
// AGXCompilerCore variants we run against:
//   - iOS-16.3 DSC:        add x2, x2, #0x44e (encoding 0x91113842)
//   - macOS-13.4 chroot DSC: add x2, x2, #0xdf4 (encoding 0x9137d042)
// The MTLCompilerBypassOSCheck tweak runs in iOS-side MTLCompilerService
// only, so the iOS signature is what we actually need. But scanning for
// either makes the code robust if the DSC version shifts.
// Returns the BL site pointer or NULL if not found in the search window.
//
// `image_lo`/`image_hi` bound the scan to the AGXCompilerCore image —
// passing 0/0 lets the scan run unrestrained. We also wrap each
// dereference in a SIGBUS/SIGSEGV-tolerant sigsetjmp so an off-image
// probe just stops the scan instead of crashing the whole tweak.
#include <setjmp.h>
#include <signal.h>
static sigjmp_buf g_renamer_scan_jmp;
static volatile sig_atomic_t g_renamer_scan_in_probe = 0;
static void RenamerScanSignalHandler(int sig) {
    (void)sig;
    if (g_renamer_scan_in_probe) {
        siglongjmp(g_renamer_scan_jmp, 1);
    }
}
static uint32_t *FindRenamerBLSite(void *anchor_raw, intptr_t delta_hint,
                                   int window_bytes,
                                   uintptr_t image_lo, uintptr_t image_hi) {
    // `add x2, x2, #imm12` encoding with imm12 specific to each DSC variant.
    // iOS-16.3 sees the "agx." literal at __cstring offset 0x44e; macOS-13.4
    // chroot at 0xdf4. Match either so the patch is portable.
    const uint32_t SIG_ADD_X2_44E = 0x91113842u; // add x2, x2, #0x44e (iOS)
    const uint32_t SIG_ADD_X2_DF4 = 0x9137d042u; // add x2, x2, #0xdf4 (chroot)
    uintptr_t anchor = StripPAC(anchor_raw);
    uint32_t *base = (uint32_t *)(anchor + delta_hint);
    int max_words = window_bytes / 4;

    struct sigaction sa_old_segv, sa_old_bus, sa = {0};
    sa.sa_handler = RenamerScanSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &sa_old_segv);
    sigaction(SIGBUS,  &sa, &sa_old_bus);

    uint32_t *found = NULL;
    for (int off = -max_words; off <= max_words; off++) {
        uint32_t *probe = base + off;
        if (image_hi && ((uintptr_t)probe < image_lo + 4 ||
                         (uintptr_t)probe >= image_hi)) continue;
        uint32_t prev_insn, cur_insn;
        if (sigsetjmp(g_renamer_scan_jmp, 1) != 0) continue;
        g_renamer_scan_in_probe = 1;
        prev_insn = probe[-1];
        cur_insn  = probe[0];
        g_renamer_scan_in_probe = 0;
        if ((prev_insn == SIG_ADD_X2_44E ||
             prev_insn == SIG_ADD_X2_DF4) &&
            ((cur_insn >> 26) & 0x3F) == 0x25) {
            found = probe;
            break;
        }
    }
    sigaction(SIGSEGV, &sa_old_segv, NULL);
    sigaction(SIGBUS,  &sa_old_bus,  NULL);
    return found;
}

// Walk dyld's image list to get the AGXCompilerCore binary's mapped
// __TEXT range. We use this to bound the scan so an off-end probe
// doesn't dereference unmapped memory.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
static void GetAGXCompilerCoreTextRange(uintptr_t *lo_out, uintptr_t *hi_out) {
    *lo_out = 0; *hi_out = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "AGXCompilerCore")) continue;
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc =
            (const struct load_command *)((const char *)mh + sizeof(*mh));
        for (uint32_t j = 0; j < mh->ncmds; j++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sc =
                    (const struct segment_command_64 *)lc;
                if (strncmp(sc->segname, "__TEXT", 16) == 0) {
                    *lo_out = (uintptr_t)sc->vmaddr + slide;
                    *hi_out = *lo_out + sc->vmsize;
                    return;
                }
            }
            lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
        }
    }
}

static void PatchAGXRenamerSkipAgxPrefix(void) {
    MTLPatchLog("renamer-patch: ENTER pid=%d", getpid());
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        MTLPatchLog("renamer-patch: dlopen FAILED: %s",
                    dlerror() ?: "(no dlerror)");
        return;
    }
    MTLPatchLog("renamer-patch: dlopen ok (h=%p)", h);
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        MTLPatchLog("renamer-patch: MSGetImageByName returned NULL");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        MTLPatchLog("renamer-patch: MSFindSymbol _AIRNTGetVersion NULL");
        return;
    }
    uintptr_t anchor_stripped = StripPAC(anchor);
    MTLPatchLog("renamer-patch: anchor _AIRNTGetVersion=%p (stripped=%#lx)",
                anchor, (long)anchor_stripped);

    uintptr_t image_lo = 0, image_hi = 0;
    GetAGXCompilerCoreTextRange(&image_lo, &image_hi);
    MTLPatchLog("renamer-patch: AGXCompilerCore __TEXT range %#lx-%#lx",
                (long)image_lo, (long)image_hi);

    // Known iOS-16.3 delta from prior RE. May be stale — the scan below
    // handles drift by walking +/-16KB around the hint for the
    // (ADD x2,x2,#0xdf4 ; BL) pair.
    intptr_t delta_hint = -0x1259a4;
    uint32_t *bl_site = FindRenamerBLSite(anchor, delta_hint,
                                          16 * 1024,
                                          image_lo, image_hi);
    if (!bl_site) {
        MTLPatchLog("renamer-patch: ADD+BL signature NOT found within "
                    "+/-16KB of anchor+delta_hint=%#lx — scanning whole "
                    "__text for fallback", (unsigned long)delta_hint);
        // Broader fallback: scan from the image base offset, bounded by
        // __TEXT range. AGXCompilerCore's __text is roughly 1.7MB.
        if (image_hi) {
            // window = entire __TEXT size, centred at anchor
            int win = (int)(image_hi - image_lo);
            bl_site = FindRenamerBLSite(anchor, 0, win,
                                        image_lo, image_hi);
        }
        if (!bl_site) {
            MTLPatchLog("renamer-patch: FAILED — no ADD+BL pair found "
                        "within AGXCompilerCore __TEXT");
            return;
        }
    }
    intptr_t actual_delta = (intptr_t)((uintptr_t)bl_site - anchor_stripped);
    uint32_t cur = bl_site[0];
    MTLPatchLog("renamer-patch: found BL site=%p actual_delta=%#lx insn=%#x",
                bl_site, (long)actual_delta, cur);
    PatchInstruction(bl_site, 0xd503201fu);  // NOP
    uint32_t after = bl_site[0];
    MTLPatchLog("renamer-patch: NOPed BL site=%p was=%#x now=%#x %s",
                bl_site, cur, after,
                after == 0xd503201fu ? "OK" : "FAIL");
}

static void PatchAGXVerifyLoweredIR(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSLog(@"#### MTLCompilerBypassOSCheck dlopen AGXCompilerCore: %s",
              dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        NSLog(@"#### MTLCompilerBypassOSCheck AGXCompilerCore not in image table");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        NSLog(@"#### MTLCompilerBypassOSCheck _AIRNTGetVersion not found");
        return;
    }
    // verifier = anchor + delta. Measured on iPad13,6 16.3.1 (20D67) DSC.
    intptr_t delta = -0x5fb78;
    uint32_t *verifier = (uint32_t *)((uintptr_t)anchor + delta);
    const uint32_t kPacibsp = 0xd503237fu;
    const uint32_t kRet     = 0xd65f03c0u;
    if (verifier[0] != kPacibsp) {
        NSLog(@"#### MTLCompilerBypassOSCheck verifier@%p first insn=%#x "
              "expected %#x — DSC version drift, NOT patching",
              verifier, verifier[0], kPacibsp);
        return;
    }
    PatchInstruction(verifier, kRet);
    NSLog(@"#### MTLCompilerBypassOSCheck verifyLoweredIR @%p patched "
          "pacibsp → ret (AGX shader verify now permissive)", verifier);
}

%ctor {
    // NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck start");
    dlopen("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler", RTLD_GLOBAL);
    MSImageRef image = MSGetImageByName("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler");
    assert(image);
    uint32_t *symbol = MSFindSymbol(image, "__ZN17MTLCompilerObject27readModuleFromBinaryRequestERK20ReadModuleParametersRN4llvm11LLVMContextEP15MTLFunctionTypePPvPmb");
    assert(symbol);
    // NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck find symbol");

    // 0x1eaaa17c4 <+608>:  ldr    w8, [sp, #0x84]
    // 0x1eaaa17c8 <+612>:  cmp    w8, #0x7
    // 0x1eaaa17cc <+616>:  b.ne   0x1eaaa1840 (throws "Target OS is incompatible.")
    while(symbol[0] != 0xb94087e8) {
        symbol++;
    }
    assert(symbol[1] == 0x71001d1f);
    //assert(symbol[2] == 0x540003a1);
    PatchInstruction(symbol + 2, 0xd503201f); // nop
    // NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck modify successfully!");

    // Originally tried: PatchAGXVerifyLoweredIR() — bypass the
    // AGCLLVMUserObject::verifyLoweredIR check that surfaces the
    // `agx.air.fract.v3f16.fast` unlowered-call error. That moved the
    // crash into libLLVM (NULL Function metadata at offset 0x30 in
    // codegen) — see commit message. Kept for reference only.
    (void)PatchAGXVerifyLoweredIR;
    // Actual fix: disable the rename inside AGCLLVMUserObject::
    // linkMetalRuntime that produces `agx.air.fract.v3f16.fast` from
    // an existing `air.fract.v3f16`. The dispatcher
    // AGCLLVMAirBuiltins::replaceBuiltins requires the function name
    // to start with "air." (it calls findPrefix(name, "air.", 4) and
    // bails if the prefix doesn't match), so the renamer's "agx."
    // prepend hides the function from the dispatcher and leaves it
    // unlowered. If we skip the prepend, the result is
    // `air.fract.v3f16.fast` — still starts with "air.", findPrefix
    // splits at the first '.' after the prefix so the dispatcher
    // gets out1="fract" and looks up buildFract, which reads the
    // actual operand type (half3) from the LLVM Value and emits the
    // valid `x - floor(x)` lowering. No more unlowered call → no
    // verifier complaint → no abort.
    //
    // Opt-in: set MTLCOMPILER_PATCH_RENAMER=1 in the LaunchAgent
    // environment to enable. Disabled by default until we can
    // confirm it doesn't regress WindowServer startup (current
    // observation: when enabled, WindowServer dies before reaching
    // pipeline build, suggesting the patched MTLCompilerService is
    // returning compiled binaries that fail differently — possible
    // ordering issue, possible findPrefix split mismatch we haven't
    // RE'd yet).
    // Opt-in via env (set MTLCOMPILER_PATCH_RENAMER=1 in MTLCompilerService's
    // launchd environment to enable). Verified-correct patch site by static RE
    // — anchor `_AIRNTGetVersion` minus delta `-0x1259a4` lands on `bl
    // std::string::insert(0, "agx.")` in
    // `AGCLLVMUserObject::linkMetalRuntime`. Empirically, however, enabling
    // the patch on this iOS-16.3 build did NOT prevent the
    // `agx.air.fract.v3f16.fast` abort — same payload still fires. Two
    // most likely explanations to investigate next:
    //   (a) Substrate's MTLCompilerService filter on this Dopamine install
    //       is loading the tweak too late (after AGCLLVMUserObject has
    //       already cached the renamed Function declarations from a prior
    //       MetalRuntime warm-up). lldb verification was inconclusive
    //       because the per-request MTLCompilerService spawn lifetime is
    //       too short to attach without altering timing.
    //   (b) the iOS-16.3 AGXCompilerCore has a SECOND `agx.` prepend
    //       path I haven't located yet. Only one `"agx."` literal xref
    //       exists in the iOS binary (chroot has 5, four of which are in
    //       raytracing accessors), and we patched the matching one, so
    //       this would have to be a Twine concatenation that doesn't
    //       reuse the standalone literal — feasible if the renamer
    //       constructs `Twine("agx.air.") + …` directly off the longer
    //       agx.air.indirect literal at iOS 0x199a891 (sliding 8 chars
    //       earlier into "agx.air." would give a usable prefix).
    // Always run the renamer patch — no env gate. XPC services don't
    // inherit env vars from the WS launchd plist and modifying the
    // service's own Info.plist would require re-signing the bundle.
    // The patch is signature-validated (only fires when both the ADD
    // x2,x2,#0xdf4 AND BL opcode match within the search window), so
    // an unknown DSC version safely no-ops instead of corrupting code.
    MTLPatchLog("%%ctor: OS-check patched; running renamer patch now");
    PatchAGXRenamerSkipAgxPrefix();
}
