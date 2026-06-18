@import CydiaSubstrate;
@import Foundation;
@import Darwin;

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
static void PatchAGXRenamerSkipAgxPrefix(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSLog(@"#### MTLCompilerBypassOSCheck renamer-patch dlopen: %s",
              dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        NSLog(@"#### MTLCompilerBypassOSCheck renamer-patch: image not "
              "MSGetImageByName-able");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        NSLog(@"#### MTLCompilerBypassOSCheck renamer-patch: anchor "
              "_AIRNTGetVersion not found");
        return;
    }
    intptr_t delta = -0x1259a4;
    uint32_t *bl_site = (uint32_t *)((uintptr_t)anchor + delta);
    uint32_t cur = bl_site[0];
    // BL opcode: bits 31..26 == 100101
    if (((cur >> 26) & 0x3F) != 0x25) {
        NSLog(@"#### MTLCompilerBypassOSCheck renamer-patch site@%p "
              "insn=%#x — NOT a BL, refusing to patch (DSC drift?)",
              bl_site, cur);
        return;
    }
    PatchInstruction(bl_site, 0xd503201fu); // NOP
    NSLog(@"#### MTLCompilerBypassOSCheck renamer-patch installed: "
          "BL std::string::insert @%p NOPed (no more 'agx.' prefix on "
          "AIR-builtin rename) — was %#x", bl_site, cur);
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
    if (getenv("MTLCOMPILER_PATCH_RENAMER")) {
        PatchAGXRenamerSkipAgxPrefix();
    }
}
