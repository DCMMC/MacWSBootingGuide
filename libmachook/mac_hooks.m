@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <ptrauth.h>
#import "interpose.h"
#import "utils.h"

// IOSurface
typedef id IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(NSDictionary* properties);

extern au_asid_t audit_token_to_asid(audit_token_t atoken);
extern uid_t audit_token_to_auid(audit_token_t atoken);

// #define FORCE_SW_RENDER 1
BOOL hooked_return_1(void) { return YES; }
void EnableJIT(void);

// FORCE_M1_DRIVER: route Metal through the REAL macOS AGX (M1/G13G) GPU driver
// instead of the MTLSimDriver simulator bridge. Auto-enabled ONLY for the arm64e
// on-device slice — arm64e GUI apps (Terminal, etc.) can't load the arm64-only
// MTLSimDriver frameworks, so AGX-direct is their only Metal path. arm64 (e.g.
// WindowServer) keeps the proven MTLSimDriver path. Needs the IOConnect selector
// translation + IOServiceOpen type fixup below (macOS GPU userclient ABI -> iOS).
#if defined(__arm64e__) && defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

// offsets hardcoded for macOS 13.4
// IOMobileFramebuffer`kern_SwapEnd + 36
#define OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt 0x4400 + 0x24
// IOMobileFramebuffer`kern_SwapEnd + 0x30: `bl IOConnectCallStructMethod` (sel=5) — the call
// that presents WindowServer's composited surface to the PHYSICAL iPad panel.  In coexistence
// mode (iOS backboardd owns the panel, macOS viewed via VNC off-screen) we neutralize this so
// WS never scans out to the panel -> no iOS/macOS flicker.  Gated to WindowServer + auto-detection
// of a running backboardd (coexistence); left intact in the original macOS-on-panel mode where
// backboardd is unloaded.  (/tmp/ws_headless still force-enables it for testing.)
#define OFF_IOMobileFramebuffer_kern_SwapEnd_submit 0x4400 + 0x30
// MTLSimDriver`sendXPCMessageWithReplySync + 0x58: `bl .cold.1` which abort()s when the XPC
// reply is an error object (i.e. the MTLSimDriverHost XPC service crashed — its
// newIOSurfaceTexture null-context bug fires under heavy compositing).  That abort kills
// WindowServer and launchd relaunches it on-demand, which can runaway-loop and wedge the
// device.  Patch the abort call site to `b +168` (the function's normal return) so it returns
// the error reply instead; the caller _MTLNewObject_Deprecated already handles a non-success
// reply (creates no object), so newTextureWithDescriptor just returns nil and WS survives the
// host crash (the host relaunches on the next request).  bl .cold.1 (0x9400606e) -> b (0x14000014).
#define OFF_MTLSimDriver_sendXPC_abort 0x25c8
// SkyLight`WS::Displays::CAWSManager::CAWSManager() + 560
#define OFF_SkyLight_CAWSManager_register_abort 0x18013c
// SkyLight`WSCompositeDestinationCreateWithMetalTexture (func at SkyLight+0x14b53c) asserts
// `texture != nil` at func+0x364.  When MTLSimDriverHost crashes, -[MTLSimDevice
// newTextureWithDescriptor:] returns nil (our MTLSimDriver patch returns the error reply
// instead of aborting WS), and WS then aborts on this assert -> launchd relaunch loop / wedge.
// Overwrite the texture-assert block (func+0x364: `adrp x0,648; add x0,x0,#0xd4d`) with
// `mov x0,#0 ; b func+0x318` (the function's epilogue, just after `mov x0,x23`), so the
// texture-nil path returns nil (WS skips that layer for the frame) instead of asserting.
#define OFF_SkyLight_WSCompositeDest_texAssert 0x14b8a0
// SkyLight`MetalContext::StartComposite(WSCompositeDestination*, MTLLoadAction, MTLStoreAction)
// (func at SkyLight+0x148358) asserts at func+0x510 ("state->_target[1] && \"Failed to add
// memoryless rendering target.\"", MetalContext.mm:918) when -[... newTextureWithDescriptor:]
// returns nil — which happens when MTLSimDriverHost crashes under heavy compositing (its
// newObjectCommand NULL-deref). WS then aborts -> launchd relaunch loop -> load runs away ->
// kernel panic. The function ALREADY has a graceful fallback at func+0x3b8 (StartComposite+952):
// `mov w0,#0 ; b func+0x308` (skip the memoryless target, return, continue to the epilogue),
// normally taken when [x19+0x1c0] is set. The guard at func+0x4f0 is
// `cbnz w8, +952` (0x35fff648); make it UNCONDITIONAL `b +952` (0x17ffffb2) so a nil texture
// also takes that existing skip-and-survive path instead of asserting. Same philosophy as the
// WSCompositeDest texAssert patch above.
#define OFF_SkyLight_MetalContext_memoryless_guard 0x148848
// SkyLight`MetalContext::EndUpdate(bool) contains 3 abort sites that fire under
// concurrent compositor pressure (Firefox software WebRender + many small
// content surfaces):
//   * +196: assert(_update_depth >= 1 && "Unbalanced Updates.")
//   * +264: assert(_state_stack.empty() && "Unbalanced Composites.")
//   * +408: a third bl __assert_rtn (less-common branch)
// EndUpdate is void; convert each `bl __assert_rtn` to `ret` so the function
// returns cleanly instead of abort()ing WindowServer. The cascading WS restart
// loop (which trips the watchdog) goes away.
//
// Image offsets verified against the live WindowServer process via lldb
// (image lookup --name _ZN12MetalContext9EndUpdateEb + section base).
#define OFF_SkyLight_MetalContext_EndUpdate_assert_1 0x147174
#define OFF_SkyLight_MetalContext_EndUpdate_assert_2 0x1471b8
#define OFF_SkyLight_MetalContext_EndUpdate_assert_3 0x1476d4
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
const char *IOGPUPath = "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU";  // dladdr returns the versioned path (not the flat install-name)
const char *libxpcPath = "/usr/lib/system/libxpc.dylib";
const char *MTLSimDriverPath = "/usr/local/Frameworks/MTLSimDriver.framework/MTLSimDriver";
const char *AGXMetalPath = "/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3";

// True if a process named `name` is currently running anywhere on the system.  The chroot
// shares the kernel proc table, so iOS-context processes (e.g. backboardd) are visible.
// Used to auto-detect "coexistence mode": when iOS's backboardd is alive we are sharing the
// device with the iOS UI, so WindowServer must not scan out to the physical panel.
static BOOL is_process_running(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    len += len / 8 + 0x4000;  // pad: the table can grow between the sizing and the fetch
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t n = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) { found = YES; break; }
        }
    }
    free(procs);
    return found;
}

void loadImageCallback(const struct mach_header* header, intptr_t vmaddr_slide) {
    Dl_info info;
    dladdr(header, &info);
    if(!strncmp(info.dli_fname, SkyLightPath, strlen(SkyLightPath))) {
        // allow coexist with backboardd in WS::Displays::CAWSManager::CAWSManager() + 560
        // if backboardd is running, WindowServer switches to offscreen rendering
        uint32_t *check = (uint32_t *)(OFF_SkyLight_CAWSManager_register_abort + (uintptr_t)header);
        ModifyExecutableRegion(check, sizeof(uint32_t), ^{
#warning TODO: has hardcoded instruction
            // NSLog(@"#### debugbydcmmc OFF_SkyLight_CAWSManager_register_abort ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) check, (unsigned long) *check, (unsigned long) 0xb4000588);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching SkyLight version/arch.
            if (*check == 0xb4000588) { // cbz    x8, do_abort
                *check = 0xd503201f; // nop
            }
        });

        // Make WSCompositeDestinationCreateWithMetalTexture survive a nil texture (from an
        // MTLSimDriverHost crash) by returning nil instead of asserting `texture != nil`.
        uint32_t *texAssert = (uint32_t *)(OFF_SkyLight_WSCompositeDest_texAssert + (uintptr_t)header);
        ModifyExecutableRegion(texAssert, sizeof(uint32_t[2]), ^{
            if (texAssert[0] == 0x90001440 && texAssert[1] == 0x91353400) { // adrp x0,648 ; add x0,x0,#0xd4d
                texAssert[0] = 0xd2800000; // mov x0, #0   (return nil)
                texAssert[1] = 0x17ffffec; // b func+0x318 (epilogue, after `mov x0,x23`)
            }
        });

        // Make MetalContext::StartComposite survive a nil memoryless render target (same
        // root cause: MTLSimDriverHost crash -> newTextureWithDescriptor: returns nil).
        // Force the assert-guard branch unconditional so the nil path takes the function's
        // own graceful "skip memoryless target" fallback (+952) instead of __assert_rtn.
        uint32_t *memGuard = (uint32_t *)(OFF_SkyLight_MetalContext_memoryless_guard + (uintptr_t)header);
        ModifyExecutableRegion(memGuard, sizeof(uint32_t), ^{
            if (*memGuard == 0x35fff648) { // cbnz w8, +952
                *memGuard = 0x17ffffb2;    // b    +952  (mov w0,#0 ; b epilogue — no assert)
            }
        });

        // Convert all three `bl __assert_rtn` sites in MetalContext::EndUpdate(bool)
        // to `ret`. EndUpdate is a void function; the assert fires under high
        // concurrent compositor load when _update_depth or _state_stack drift
        // (typical with software WebRender + many small Firefox content surfaces).
        // A clean `ret` skips the message-build setup just before the bl (which is
        // harmless dead code since we never reach __assert_rtn).
        const uintptr_t end_update_asserts[3] = {
            OFF_SkyLight_MetalContext_EndUpdate_assert_1,
            OFF_SkyLight_MetalContext_EndUpdate_assert_2,
            OFF_SkyLight_MetalContext_EndUpdate_assert_3,
        };
        for (int i = 0; i < 3; i++) {
            uint32_t *site = (uint32_t *)(end_update_asserts[i] + (uintptr_t)header);
            ModifyExecutableRegion(site, sizeof(uint32_t), ^{
                // `bl __assert_rtn` is `bl <imm26>` (opcode 0x94000000, low 26 bits = offset>>2).
                // Match the bl opcode (high 6 bits), ignore target since shared-cache slide changes it.
                if ((*site & 0xFC000000) == 0x94000000) {
                    *site = 0xd65f03c0;  // ret
                }
            });
        }

        // grant all permissions
        MSHookFunction(MSFindSymbol((MSImageRef)header, "_audit_token_check_tcc_access"), hooked_return_1, NULL);
            
        // NSLog(@"#### debugbydcmmc loadImageCallback before OFF_SkyLight_WSSystemCanCompositeWithMetal");
#if FORCE_SW_RENDER
        // skip Metal check (WSSystemCanCompositeWithMetal::once)
        int64_t *once = (int64_t *)(OFF_SkyLight_WSSystemCanCompositeWithMetal + (uintptr_t)header);
        *once = -1;
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

        // COEXISTENCE (flicker fix): in WindowServer only, when iOS's backboardd is running
        // (we're sharing the device with the iOS UI), neutralize kern_SwapEnd's panel present
        // so WS renders to its framebuffer (VNC reads it) but never scans out to the physical
        // iPad panel — iOS keeps the panel, eliminating the iOS/macOS flicker.  When backboardd
        // is NOT running (the original "unload SpringBoard+backboardd, macOS takes the panel"
        // mode) the present is left intact.  Auto-detecting backboardd makes this survive
        // reboots with no flag file; /tmp/ws_headless still force-enables it for testing.
        {
            char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
            if(_NSGetExecutablePath(exe, &exelen) == 0 &&
               strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL &&
               (is_process_running("backboardd") || access("/tmp/ws_headless", F_OK) == 0)) {
                uint32_t *swapSubmit = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_submit + (uintptr_t)header);
                ModifyExecutableRegion(swapSubmit, sizeof(uint32_t), ^{
                    if (*swapSubmit == 0x94001f64) { // bl IOConnectCallStructMethod (panel present)
                        *swapSubmit = 0xd2800000;    // mov x0, #0  (skip present, return KERN_SUCCESS)
                    }
                });
            }
        }
    } else if(!strncmp(info.dli_fname, libxpcPath, strlen(libxpcPath))) {
        // NSLog(@"#### debugbydcmmc loadImageCallback MTLCompilerService before _xpc_add_bundle");
        // register MTLCompilerService.xpc
        xpc_object_t dict = (xpc_object_t)xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/Metal.framework/Metal", 2);
        void(*_xpc_bootstrap_services)(xpc_object_t) = MSFindSymbol((MSImageRef)header, "__xpc_bootstrap_services");
        _xpc_bootstrap_services(dict);
        // NSLog(@"#### debugbydcmmc loadImageCallback MTLCompilerService after _xpc_add_bundle");
        // xpc_add_bundle("/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc", 2);
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
    } else if(!strncmp(info.dli_fname, QuartzCorePath, strlen(QuartzCorePath))) {
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
        if(!isWindowServer) {
            uint32_t *forceAccel = (uint32_t *)(OFF_QuartzCore_CABackingStore_force_accel + (uintptr_t)header);
            ModifyExecutableRegion(forceAccel, sizeof(uint32_t), ^{
                if (*forceAccel == 0x34000155) { // cbz w21, #0x28 (+852)
                    *forceAccel = 0x14000007;    // b +840 (accelerated path)
                }
            });
        }
    } else if(!strncmp(info.dli_fname, IOGPUPath, strlen(IOGPUPath))) {
        // Relax the IOGPUMetalBuffer.m:310 gpuAddress assert. The iOS kernel gives each 0x80
        // sub-resource its OWN (correctly-mapped) GPU VA, not aliased to the parent, so the macOS
        // driver's `sub._res.gpuAddress == primaryBuffer._res.gpuAddress + bufferOffset` assert fails
        // — but the kernel's VA is valid for GPU access, so skipping the abort lets the GPU use the
        // real buffer VA. Patch `b.ne .cold.1` (0x54000401) at -[IOGPUMetalBuffer initWithPrimaryBuffer:]
        // +0x134 (IOGPU __TEXT base 0x1eec5a000 -> offset 0x3cac) -> nop. macOS 13.4.
        // Find the assert by PATTERN (the cache splits __TEXT_EXEC from the mach_header, so a fixed
        // header+offset is unreliable). The gpuAddress check is: ldr x8,[x25,#0x48]; ldr x9,[x24,#0x48];
        // add x9,x9,x20; cmp x8,x9 — immediately followed by `b.ne .cold.1`. Nop that branch.
        unsigned long tsz = 0;
        uint8_t *txt = getsectiondata((const struct mach_header_64 *)header, "__TEXT_EXEC", "__text", &tsz);
        if(!txt) txt = getsectiondata((const struct mach_header_64 *)header, "__TEXT", "__text", &tsz);
        static const uint8_t pat[] = {0x28,0x27,0x40,0xf9, 0x09,0x27,0x40,0xf9, 0x29,0x01,0x14,0x8b, 0x1f,0x01,0x09,0xeb};
        int patched = 0;
        if(txt) for(unsigned long k = 0; k + sizeof(pat) + 4 <= tsz; k += 4) {
            if(memcmp(txt + k, pat, sizeof(pat)) == 0) {
                uint32_t *bne = (uint32_t *)(txt + k + sizeof(pat));
                if((*bne & 0xFF00001F) == 0x54000001) {  // b.ne <imm>
                    ModifyExecutableRegion(bne, sizeof(uint32_t), ^{ *bne = 0xd503201f; });  // -> nop
                    fprintf(stderr, "#### IOGPU gpuAddr assert nop'd @%p\n", (void *)bne);
                    patched = 1;
                }
                break;
            }
        }
        if(!patched) fprintf(stderr, "#### IOGPU gpuAddr assert pattern NOT FOUND (txt=%p sz=%lu)\n", (void *)txt, tsz);
    } else if(!strncmp(info.dli_fname, MTLSimDriverPath, strlen(MTLSimDriverPath))) {
        // Make WindowServer (and any Metal client using the sim driver) SURVIVE an
        // MTLSimDriverHost XPC-service crash instead of abort()ing into a launchd
        // relaunch loop.  sendXPCMessageWithReplySync calls .cold.1 -> abort() when the
        // reply is an XPC error object (host crashed).  Patch that call site to the
        // function's normal return so it returns the error reply; the caller
        // _MTLNewObject_Deprecated handles a non-success reply (creates no object), so
        // newTextureWithDescriptor returns nil and WS keeps running.  The byte guard makes
        // this a no-op on any slice/version where the expected instruction isn't present.
        uint32_t *abortSite = (uint32_t *)(OFF_MTLSimDriver_sendXPC_abort + (uintptr_t)header);
        ModifyExecutableRegion(abortSite, sizeof(uint32_t), ^{
            if (*abortSite == 0x9400606e) { // bl sendXPCMessageWithReplySync.cold.1 (abort)
                *abortSite = 0x14000014;    // b +168 (normal return; return the reply)
            }
        });
    } else if(getenv("AGX_OBJC_VA_FIX") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
        // POSTMORTEM: this code is left for documentation. The hypothesis behind it was wrong.
        // Earlier static analysis found 22 occurrences of the byte pattern "00 00 00 00 11 00 00 00"
        // in macOS AGXMetal13_3 __DATA_CONST,__objc_const, vs 0 occurrences in iOS, which I
        // interpreted as 22 hardcoded 0x1100000000 GPU VAs baked into AGXResource class metadata.
        // Verified at runtime via in-memory section dump: all 22 hits were UNALIGNED u64 reads
        // (offset%8 == 4) of an ObjC ivar-list-like struct that holds two adjacent u32 fields
        // 0x11 (= 17) and 0x28 (= 40). NOT a GPU VA at all.
        // Also separately: the EXACT fault VA 0x1158048000 is NOT literally present (as bytes)
        // in AGXMetal13_3, AGXG13G, IOGPUFamily, AGXFirmwareKextG13GRTBuddy, or RTBuddy. It is
        // a RUNTIME-COMPUTED value from kernel- or firmware-side allocations not visible to
        // any userland shim. Leaving this code as a "patched 0" diagnostic.
        unsigned long sz = 0;
        uint8_t *seg = getsectiondata((const struct mach_header_64 *)header, "__DATA_CONST", "__objc_const", &sz);
        if(seg && sz) {
            const uint64_t old_va = 0x1100000000ULL;
            int patched_count = 0, near_count = 0;
            for(unsigned long k = 0; k + 8 <= sz; k += 8) {
                uint64_t v = *(const uint64_t *)(seg + k);
                if(v == old_va) patched_count++;
                if((v >> 32) == 0x11) near_count++;
            }
            fprintf(stderr, "#### AGX_OBJC_VA_FIX diagnostic: aligned %#llx instances=%d, high32=0x11 candidates=%d (sz=%lu) — no real targets, hypothesis was wrong\n",
                    (unsigned long long)old_va, patched_count, near_count, sz);
        }
    } else if(getenv("AGX_PIPELINE_BASE_PATCH") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
        // EXPERIMENT (2026-06-15): patch macOS AGXMetal13_3 to load a different Pipelines base
        // than 0x1100000000. There are 10 `MOVZ Xd, #0x11, LSL #32` instructions in the
        // __TEXT/__text of AGXMetal13_3 that produce the immediate 0x1100000000. These are the
        // candidate source of macOS Metal's INTERNAL pipeline-base allocator (the part that
        // doesn't go through IOConnect, so the previous AGX_STRIP_HEAP_OPT / FIX_LOW_HEAP
        // patches couldn't reach it).
        //
        // MOVZ Xd, #imm16, LSL #32 encoding: 0xD2C00000 | (imm16 << 5) | Rd. For imm16=0x11
        // that's 0xD2C00220 | Rd (Rd ∈ 0..31, so low byte 0x20..0x3F).
        //
        // To change to MOVZ Xd, #<NEW_IMM>, LSL #32 we just OR the new imm16<<5 into the
        // template. NEW_IMM is read from AGX_PIPELINE_BASE_PATCH (hex, 16-bit max). E.g. 0x15
        // for 0x1500000000, 0x5b for 0x5b00000000.
        //
        // Outcome interpretation:
        //  (a) Fault VA shifts to <new_base>+0x58048000 → macOS Metal's userland MOVZ-loaded
        //      constant DOES control the embedded pipeline VA. C is viable; iterate to find a
        //      base in an iOS-mapped page range.
        //  (b) Fault VA stays at 0x1158048000 → these MOVZ instructions don't drive the
        //      pipeline allocator. The fault VA is purely firmware-determined. C dead-dead.
        unsigned long new_imm16 = strtoul(getenv("AGX_PIPELINE_BASE_PATCH"), NULL, 0) & 0xFFFFu;
        unsigned long sz = 0;
        uint8_t *seg = getsectiondata((const struct mach_header_64 *)header, "__TEXT", "__text", &sz);
        if(!seg || sz < 4) {
            fprintf(stderr, "#### AGX_PIPELINE_BASE_PATCH: __TEXT,__text not found\n");
        } else {
            uint32_t *insns = (uint32_t *)seg;
            size_t count = sz / 4;
            int patched = 0;
            // Match MOVZ Xd, #0x11, LSL #32 = 0xD2C00220 | Rd (Rd in low 5 bits = 0..31)
            uint32_t match_template = 0xD2C00220u;
            uint32_t match_mask     = 0xFFFFFFE0u; // keep all but low 5 bits (Rd)
            uint32_t replace_template = 0xD2C00000u | ((uint32_t)new_imm16 << 5);
            for(size_t i = 0; i < count; i++) {
                if((insns[i] & match_mask) == match_template) {
                    uint32_t Rd = insns[i] & 0x1Fu;
                    uint32_t new_insn = replace_template | Rd;
                    fprintf(stderr, "#### AGX_PIPELINE_BASE_PATCH @ %p (Xd=X%u): %#x -> %#x  (load #%#lx<<32)\n",
                            (void *)&insns[i], Rd, insns[i], new_insn, new_imm16);
                    uint32_t *target = &insns[i];
                    ModifyExecutableRegion(target, sizeof(uint32_t), ^{
                        *target = new_insn;
                    });
                    patched++;
                }
            }
            fprintf(stderr, "#### AGX_PIPELINE_BASE_PATCH: patched %d MOVZ instructions (new base = %#lx)\n",
                    patched, new_imm16 << 32);
        }
    }
}

__attribute__((constructor)) void InitStuff() {
    EnableJIT();
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

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char **params, char **errorbuf);
int sandbox_init_with_parameters_new(const char *profile, uint64_t flags, const char **params, char **errorbuf) {
    // printf("debugbydcmmc Calling interposed sandbox_init_with_parameters\n");
    return 0;
}

kern_return_t mach_port_construct_new(ipc_space_t task, mach_port_options_ptr_t options, uint64_t context, mach_port_name_t *name) {
    options->flags &= ~MPO_TG_BLOCK_TRACKING;
    return mach_port_construct(task, options, context, name);
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
DYLD_INTERPOSE(sandbox_init_with_parameters_new, sandbox_init_with_parameters);
DYLD_INTERPOSE(mach_port_construct_new, mach_port_construct);
DYLD_INTERPOSE(audit_token_to_asid_new, audit_token_to_asid);
DYLD_INTERPOSE(audit_token_to_auid_new, audit_token_to_auid);
DYLD_INTERPOSE(auditon_new, auditon);
DYLD_INTERPOSE(getaudit_addr_new, getaudit_addr);

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

// NOTE: IOSurfaceCreate is intentionally NOT interposed. The IOSurfaceCreate_new hook
// (compression-rewrite + property logging) was a diagnostic dead-end (compression was a
// red herring; the real window-content fix is the QuartzCore CABackingStorePrepareUpdates_
// +812 patch in loadImageCallback). Worse, it CRASHED CoreImage-using apps (Terminal):
// CoreImage calls IOSurfaceCreate with a properties dict whose objectForKey: access PAC-
// faulted in the hook (EXC_BAD_ACCESS in IOSurfaceCreate_new <- CIImage). Leave the real
// IOSurfaceCreate untouched.

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

// NOTE: Earlier we tried a global `__assert_rtn` interpose to swallow any
// SkyLight/CAWSBackend assert that we hadn't byte-patched yet. That caused
// the device to reboot — likely because libSystem's own internal asserts
// (e.g. in libdispatch / pthread teardown) MUST abort to keep the kernel
// world consistent; making them return left libSystem in undefined state.
// We rely on targeted byte patches in loadImageCallback instead (EndUpdate,
// MetalContext memoryless guard, WSCompositeDest tex assert).

// ─── mmap interpose for V8/cppgc CagedHeap on iOS ───────────────────────────
//
// V8's Oilpan CagedHeap reserves a 32 GB virtual address region at startup
// (`mmap(NULL, 0x800000000, PROT_NONE, MAP_PRIVATE|MAP_ANON, -1, 0)`). On
// macOS this just reserves VA space; iOS rejects allocations this large and
// V8 then calls `FATAL("Oilpan: CagedHeap reservation.")`. We shim the request
// to a much smaller actual mapping; V8 treats its pointer as if it owned the
// full range. Works until V8 actually touches memory beyond the shim (which
// happens after static init — at least we reach main()).
//
// Hot-path safety: the FIRST call delegates straight to real mmap, only
// substituting on FAILURE for the specific multi-GB anonymous-NULL pattern.
// Other mmap callers (libc, malloc, dyld, every other process touching this
// dylib) are unaffected.
#include <sys/mman.h>

// Track shimmed mappings: [base, base+real_size) is real; [base+real_size, base+claimed_size) is "fake".
// V8 will munmap sub-regions of the "claimed" range; we need to silently swallow
// out-of-range munmaps to avoid the kernel's DEALLOC_GAP guard SIGKILL.
#define MAX_SHIMS 16
static struct {
    uintptr_t base;       // returned to caller
    size_t    claimed;    // size V8 thinks it has
    size_t    real;       // size actually mapped
} g_shims[MAX_SHIMS];
static int g_shim_count = 0;
static pthread_mutex_t g_shim_lock = PTHREAD_MUTEX_INITIALIZER;

static int shim_lookup(uintptr_t addr, size_t len, uintptr_t *real_base, size_t *real_end) {
    pthread_mutex_lock(&g_shim_lock);
    for (int i = 0; i < g_shim_count; i++) {
        uintptr_t b = g_shims[i].base;
        uintptr_t claim_end = b + g_shims[i].claimed;
        if (addr >= b && addr < claim_end) {
            if (real_base) *real_base = b;
            if (real_end)  *real_end  = b + g_shims[i].real;
            pthread_mutex_unlock(&g_shim_lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&g_shim_lock);
    return 0;
}

static void shim_add(uintptr_t base, size_t claimed, size_t real) {
    pthread_mutex_lock(&g_shim_lock);
    if (g_shim_count < MAX_SHIMS) {
        g_shims[g_shim_count].base    = base;
        g_shims[g_shim_count].claimed = claimed;
        g_shims[g_shim_count].real    = real;
        g_shim_count++;
    }
    pthread_mutex_unlock(&g_shim_lock);
}

static void *mmap_hook(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    void *r = mmap(addr, length, prot, flags, fd, offset);
    if (length >= (64ull * 1024 * 1024)) {
        fprintf(stderr, "#### debugbydcmmc mmap: addr=%p len=0x%zx prot=0x%x flags=0x%x fd=%d -> %p\n",
                addr, length, prot, flags, fd, r);
    }
    // V8's CagedHeap over-allocation pattern fails for sizes ≥ 1 GiB.
    if (r == MAP_FAILED && length >= (1ull << 30) && (flags & MAP_ANON)) {
        int saved_errno = errno;
        size_t try_size = length / 2;
        while (try_size >= (1ull << 28)) {
            void *r2 = mmap(NULL, try_size, prot, flags, fd, offset);
            if (r2 != MAP_FAILED) {
                shim_add((uintptr_t)r2, length, try_size);
                fprintf(stderr, "#### debugbydcmmc mmap SHIM: req=0x%zx -> %p (real 0x%zx)\n",
                        length, r2, try_size);
                return r2;
            }
            try_size /= 2;
        }
        errno = saved_errno;
        return r;
    }
    // Detect collision: if kernel returned an addr inside an existing shim region,
    // V8 will see overlapping mappings and crash. Re-allocate elsewhere.
    if (r != MAP_FAILED && !(flags & MAP_FIXED) && length >= (1ull << 28)) {
        uintptr_t rb = 0, re = 0;
        if (shim_lookup((uintptr_t)r, length, &rb, &re)) {
            fprintf(stderr, "#### debugbydcmmc mmap COLLISION: kernel returned %p inside shim [%p,%p) — retrying\n",
                    r, (void*)rb, (void*)re);
            munmap(r, length);
            // try higher addresses by passing hints; some may stick
            for (uintptr_t h = 0x400000000000ULL; h < 0x800000000000ULL; h += 0x40000000000ULL) {
                void *r3 = mmap((void *)h, length, prot, flags, fd, offset);
                if (r3 != MAP_FAILED) {
                    uintptr_t cb=0, ce=0;
                    if (!shim_lookup((uintptr_t)r3, length, &cb, &ce)) {
                        fprintf(stderr, "#### debugbydcmmc mmap RETRY @ hint %p -> %p\n", (void*)h, r3);
                        return r3;
                    }
                    munmap(r3, length);
                }
            }
            // fallback: take the kernel's choice anyway
            r = mmap(NULL, length, prot, flags, fd, offset);
            fprintf(stderr, "#### debugbydcmmc mmap RETRY fallback -> %p\n", r);
        }
    }
    return r;
}
DYLD_INTERPOSE(mmap_hook, mmap);

static int munmap_hook(void *addr, size_t length) {
    uintptr_t real_base = 0, real_end = 0;
    if (shim_lookup((uintptr_t)addr, length, &real_base, &real_end)) {
        uintptr_t req_start = (uintptr_t)addr;
        uintptr_t req_end   = req_start + length;
        if (req_end <= real_end) {
            // fully within real mapping -- pass through
            return munmap(addr, length);
        }
        if (req_start >= real_end) {
            // fully outside real mapping -- pretend success (V8 thinks it owns
            // up to claimed_size; out-of-range trim is its bookkeeping cleanup).
            fprintf(stderr, "#### debugbydcmmc munmap SWALLOW: [%p, %p) outside real [%p,%p)\n",
                    (void*)req_start, (void*)req_end, (void*)real_base, (void*)real_end);
            return 0;
        }
        // partial: unmap only the in-range part, swallow the rest
        size_t in_range = real_end - req_start;
        fprintf(stderr, "#### debugbydcmmc munmap PARTIAL: req [%p,%p) trimmed to [%p,%p)\n",
                (void*)req_start, (void*)req_end, (void*)req_start, (void*)real_end);
        return munmap(addr, in_range);
    }
    return munmap(addr, length);
}
DYLD_INTERPOSE(munmap_hook, munmap);

#include <sys/resource.h>
__attribute__((constructor)) static void RaiseVMLimit(void) {
    // V8/cppgc needs ≥ 64 GiB virtual address space (32 GiB size + 32 GiB
    // alignment for the CagedHeap reservation). iOS default RLIMIT_AS may be
    // tight; bump to infinity before V8 init runs.
    struct rlimit rl;
    if (getrlimit(RLIMIT_AS, &rl) == 0) {
        fprintf(stderr, "#### debugbydcmmc RLIMIT_AS before: cur=%llu max=%llu\n",
                (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max);
        rl.rlim_cur = RLIM_INFINITY;
        rl.rlim_max = RLIM_INFINITY;
        int r1 = setrlimit(RLIMIT_AS, &rl);
        fprintf(stderr, "#### debugbydcmmc RLIMIT_AS setrlimit returned %d errno=%d\n", r1, errno);
    }
    if (getrlimit(RLIMIT_RSS, &rl) == 0) {
        fprintf(stderr, "#### debugbydcmmc RLIMIT_RSS before: cur=%llu max=%llu\n",
                (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max);
    }
}

// ─── SIGTRAP swallow for Chromium IMMEDIATE_CRASH ───────────────────────────
//
// Chromium emits `brk #0; hlt #0; brk #1` as its IMMEDIATE_CRASH() macro
// expansion. Every CHECK/CHECK_OP failure path ends in this 3-instruction
// poison. On iOS we hit these constantly during V8 init for invariants that
// don't apply on this kernel (e.g. iOS-stripped Mach VM API responses).
//
// Catch SIGTRAP, verify the current PC really points at `brk #0`, and advance
// PC past the 3-instruction poison block. Execution falls through into the
// next function's prologue — which may corrupt the stack frame, BUT in
// practice V8's tail-call abort patterns put each IMMEDIATE_CRASH at the end
// of a `[[noreturn]]` helper that no caller expects to return from anyway.
// The caller's frame is already preserved (x29/x30 in stack); skipping the
// brk lets control return up the stack normally.
//
// Strictly limited to brk #0 (insn = 0xd4200000). Other SIGTRAP causes
// (regular debugger breakpoints, hlt-only, brk with non-zero immediate) fall
// through to the default handler.
#include <signal.h>

static struct sigaction g_old_sigtrap = {0};

static void sigtrap_handler(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = (ucontext_t *)ctx;
    if (!uc || !uc->uc_mcontext) goto chain;
    uint64_t pc = (uint64_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    uint32_t insn = *(uint32_t *)pc;
    if (insn != 0xd4200000) {
        // not a brk #0; pass through to whatever was here before
        goto chain;
    }
    // Skip past the 3-instruction poison block (brk #0; hlt #0; brk #1).
    arm_thread_state64_set_pc_fptr(uc->uc_mcontext->__ss, (void *)(pc + 12));
    static int count = 0;
    if (++count < 200) {
        fprintf(stderr, "#### debugbydcmmc SIGTRAP swallowed brk #0 @ 0x%llx (count=%d)\n",
                (unsigned long long)pc, count);
    }
    return;
chain:
    if (g_old_sigtrap.sa_flags & SA_SIGINFO) {
        if (g_old_sigtrap.sa_sigaction) g_old_sigtrap.sa_sigaction(sig, si, ctx);
    } else if (g_old_sigtrap.sa_handler && g_old_sigtrap.sa_handler != SIG_DFL &&
               g_old_sigtrap.sa_handler != SIG_IGN) {
        g_old_sigtrap.sa_handler(sig);
    } else {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

__attribute__((constructor)) static void InstallSigtrapSwallow(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigtrap_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTRAP, &sa, &g_old_sigtrap) == 0) {
        fprintf(stderr, "#### debugbydcmmc SIGTRAP handler installed\n");
    }
}

// ─── Block Chromium's task_set_exception_ports for EXC_BREAKPOINT ────────────
// V8/Chromium installs a Mach exception handler for EXC_BREAKPOINT in
// `base::debug::EnableInProcessStackDumping` (or via crashpad). That handler
// catches every brk #0 from IMMEDIATE_CRASH() and aborts the process BEFORE
// the kernel converts EXC_BREAKPOINT into SIGTRAP, so our SIGTRAP handler
// never gets a chance. We intercept the registration call and mask off the
// EXC_MASK_BREAKPOINT bit, letting EXC_BREAKPOINT flow through to SIGTRAP.
extern kern_return_t task_set_exception_ports(task_t, exception_mask_t,
                                              mach_port_t, exception_behavior_t,
                                              thread_state_flavor_t);

static kern_return_t task_set_exception_ports_hook(task_t task,
                                                   exception_mask_t mask,
                                                   mach_port_t new_port,
                                                   exception_behavior_t behavior,
                                                   thread_state_flavor_t flavor) {
    exception_mask_t blocked = mask & EXC_MASK_BREAKPOINT;
    exception_mask_t passed  = mask & ~EXC_MASK_BREAKPOINT;
    if (blocked) {
        fprintf(stderr, "#### debugbydcmmc task_set_exception_ports: BLOCKED BREAKPOINT (orig mask=0x%x, pass=0x%x)\n",
                mask, passed);
    }
    if (passed == 0) {
        // Nothing left to register; pretend success.
        return KERN_SUCCESS;
    }
    return task_set_exception_ports(task, passed, new_port, behavior, flavor);
}
DYLD_INTERPOSE(task_set_exception_ports_hook, task_set_exception_ports);

extern kern_return_t task_swap_exception_ports(task_t, exception_mask_t,
                                               mach_port_t, exception_behavior_t,
                                               thread_state_flavor_t,
                                               exception_mask_array_t,
                                               mach_msg_type_number_t *,
                                               exception_handler_array_t,
                                               exception_behavior_array_t,
                                               exception_flavor_array_t);

static kern_return_t task_swap_exception_ports_hook(task_t task,
                                                    exception_mask_t mask,
                                                    mach_port_t new_port,
                                                    exception_behavior_t behavior,
                                                    thread_state_flavor_t flavor,
                                                    exception_mask_array_t masks,
                                                    mach_msg_type_number_t *count,
                                                    exception_handler_array_t old_handlers,
                                                    exception_behavior_array_t old_behaviors,
                                                    exception_flavor_array_t old_flavors) {
    exception_mask_t passed = mask & ~EXC_MASK_BREAKPOINT;
    if (mask & EXC_MASK_BREAKPOINT) {
        fprintf(stderr, "#### debugbydcmmc task_swap_exception_ports: BLOCKED BREAKPOINT (mask=0x%x)\n", mask);
    }
    if (passed == 0) {
        if (count) *count = 0;
        return KERN_SUCCESS;
    }
    return task_swap_exception_ports(task, passed, new_port, behavior, flavor,
                                     masks, count, old_handlers, old_behaviors, old_flavors);
}
DYLD_INTERPOSE(task_swap_exception_ports_hook, task_swap_exception_ports);

extern kern_return_t thread_set_exception_ports(thread_t, exception_mask_t,
                                                mach_port_t, exception_behavior_t,
                                                thread_state_flavor_t);

static kern_return_t thread_set_exception_ports_hook(thread_t thread,
                                                     exception_mask_t mask,
                                                     mach_port_t new_port,
                                                     exception_behavior_t behavior,
                                                     thread_state_flavor_t flavor) {
    exception_mask_t passed = mask & ~EXC_MASK_BREAKPOINT;
    if (mask & EXC_MASK_BREAKPOINT) {
        fprintf(stderr, "#### debugbydcmmc thread_set_exception_ports: BLOCKED BREAKPOINT (mask=0x%x)\n", mask);
    }
    if (passed == 0) {
        return KERN_SUCCESS;
    }
    return thread_set_exception_ports(thread, passed, new_port, behavior, flavor);
}
DYLD_INTERPOSE(thread_set_exception_ports_hook, thread_set_exception_ports);

// Also refuse for any sigaction() that would override our SIGTRAP handler.
extern int sigaction(int, const struct sigaction * __restrict, struct sigaction * __restrict);
static int sigaction_hook(int sig, const struct sigaction * __restrict act, struct sigaction * __restrict oact) {
    if (sig == SIGTRAP && act != NULL) {
        // Pretend we set their handler, but actually keep ours.
        if (oact) *oact = g_old_sigtrap;
        fprintf(stderr, "#### debugbydcmmc sigaction(SIGTRAP) overridden — keeping our handler\n");
        return 0;
    }
    return sigaction(sig, act, oact);
}
DYLD_INTERPOSE(sigaction_hook, sigaction);

extern sig_t signal(int, sig_t);
static sig_t signal_hook(int sig, sig_t handler) {
    if (sig == SIGTRAP) {
        fprintf(stderr, "#### debugbydcmmc signal(SIGTRAP, %p) IGNORED — keeping our handler\n", handler);
        return SIG_DFL;
    }
    return signal(sig, handler);
}
DYLD_INTERPOSE(signal_hook, signal);

// ─── mach_vm_map / mach_vm_allocate hooks ────────────────────────────────────
// On macOS, V8/cppgc CagedHeap actually uses Mach VM APIs (mach_vm_map +
// VM_FLAGS_ANYWHERE) for the 32 GB reservation, not POSIX mmap. We hook the
// Mach API too: if a huge ANYWHERE reservation fails (KERN_NO_SPACE / similar),
// substitute a small one and report it as succeeded at the requested size.
//
// iPhoneOS SDK lacks <mach/mach_vm.h> ("unsupported") so we declare the
// signatures manually. The 64-bit Mach VM types are uint64_t on arm64.
#include <mach/mach.h>
typedef uint64_t mach_vm_address_t_t;
typedef uint64_t mach_vm_size_t_t;
typedef uint64_t mach_vm_offset_t_t;
typedef uint64_t memory_object_offset_t_t;
extern kern_return_t mach_vm_map(vm_map_t, mach_vm_address_t_t *,
                                 mach_vm_size_t_t, mach_vm_offset_t_t, int,
                                 mem_entry_name_port_t,
                                 memory_object_offset_t_t, boolean_t,
                                 vm_prot_t, vm_prot_t, vm_inherit_t);

static kern_return_t mach_vm_map_hook(vm_map_t target, mach_vm_address_t_t *address,
                                      mach_vm_size_t_t size, mach_vm_offset_t_t mask,
                                      int flags, mem_entry_name_port_t object,
                                      memory_object_offset_t_t offset, boolean_t copy,
                                      vm_prot_t cur_protection, vm_prot_t max_protection,
                                      vm_inherit_t inheritance) {
    kern_return_t kr = mach_vm_map(target, address, size, mask, flags, object,
                                   offset, copy, cur_protection, max_protection,
                                   inheritance);
    // Log every large call (≥ 64 MiB) regardless of success — this is how V8/cppgc
    // reservations are detected in practice.
    if (size >= (64ull * 1024 * 1024)) {
        fprintf(stderr, "#### debugbydcmmc mach_vm_map: size=0x%llx flags=0x%x prot=0x%x kr=%d\n",
                (unsigned long long)size, flags, cur_protection, kr);
    }
    if (__builtin_expect(kr != KERN_SUCCESS, 0) && size >= (1ull << 30) &&
        (flags & VM_FLAGS_ANYWHERE)) {
        fprintf(stderr, "#### debugbydcmmc mach_vm_map BIG-FAIL: size=0x%llx flags=0x%x prot=0x%x kr=%d (%s)\n",
                (unsigned long long)size, flags, cur_protection, kr, mach_error_string(kr));
        const mach_vm_size_t_t SHIM_SIZE = 256ull * 1024 * 1024;
        mach_vm_address_t_t addr2 = 0;
        kern_return_t kr2 = mach_vm_map(target, &addr2, SHIM_SIZE, mask, flags, object,
                                        offset, copy, cur_protection, max_protection,
                                        inheritance);
        if (kr2 == KERN_SUCCESS) {
            fprintf(stderr, "#### debugbydcmmc mach_vm_map SHIM: req=0x%llx -> 0x%llx (real 0x%llx)\n",
                    (unsigned long long)size, (unsigned long long)addr2,
                    (unsigned long long)SHIM_SIZE);
            *address = addr2;
            return KERN_SUCCESS;
        }
    }
    return kr;
}
DYLD_INTERPOSE(mach_vm_map_hook, mach_vm_map);

extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t_t *,
                                      mach_vm_size_t_t, int);
static kern_return_t mach_vm_allocate_hook(vm_map_t target,
                                           mach_vm_address_t_t *address,
                                           mach_vm_size_t_t size, int flags) {
    kern_return_t kr = mach_vm_allocate(target, address, size, flags);
    if (__builtin_expect(kr != KERN_SUCCESS, 0) && size >= (1ull << 30) &&
        (flags & VM_FLAGS_ANYWHERE)) {
        fprintf(stderr, "#### debugbydcmmc mach_vm_allocate BIG-FAIL: size=0x%llx flags=0x%x kr=%d (%s)\n",
                (unsigned long long)size, flags, kr, mach_error_string(kr));
        const mach_vm_size_t_t SHIM_SIZE = 256ull * 1024 * 1024;
        mach_vm_address_t_t addr2 = 0;
        kern_return_t kr2 = mach_vm_allocate(target, &addr2, SHIM_SIZE, flags);
        if (kr2 == KERN_SUCCESS) {
            fprintf(stderr, "#### debugbydcmmc mach_vm_allocate SHIM: req=0x%llx -> 0x%llx (real 0x%llx)\n",
                    (unsigned long long)size, (unsigned long long)addr2,
                    (unsigned long long)SHIM_SIZE);
            *address = addr2;
            return KERN_SUCCESS;
        }
    }
    return kr;
}
DYLD_INTERPOSE(mach_vm_allocate_hook, mach_vm_allocate);

static kern_return_t vm_allocate_hook(vm_map_t target, vm_address_t *address,
                                      vm_size_t size, int flags) {
    kern_return_t kr = vm_allocate(target, address, size, flags);
    if (__builtin_expect(kr != KERN_SUCCESS, 0) && size >= (1ull << 30) &&
        (flags & VM_FLAGS_ANYWHERE)) {
        fprintf(stderr, "#### debugbydcmmc vm_allocate BIG-FAIL: size=0x%lx flags=0x%x kr=%d (%s)\n",
                (unsigned long)size, flags, kr, mach_error_string(kr));
        const vm_size_t SHIM_SIZE = 256 * 1024 * 1024;
        vm_address_t addr2 = 0;
        kern_return_t kr2 = vm_allocate(target, &addr2, SHIM_SIZE, flags);
        if (kr2 == KERN_SUCCESS) {
            fprintf(stderr, "#### debugbydcmmc vm_allocate SHIM: req=0x%lx -> 0x%lx (real 0x%lx)\n",
                    (unsigned long)size, (unsigned long)addr2, (unsigned long)SHIM_SIZE);
            *address = addr2;
            return KERN_SUCCESS;
        }
    }
    return kr;
}
DYLD_INTERPOSE(vm_allocate_hook, vm_allocate);

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
            case 0xf: // IOGPUDeviceCreateDeviceShmem
                return 0xd;
            case 0x10: // IOGPUDeviceDestroyDeviceShmem
                return 0xe;
            case 0x11: // IOGPUCommandQueueCreateWithQoS + 452
                return 0xf;
            case 0x12: // ioGPUNotificationQueueFinalize
                return 0x10;
            case 0x1d: // IOGPUCommandQueueCreateWithQoS + 516
                return 0x19;
            case 0x1e: // IOGPUCommandQueueSubmitCommandBuffers
                return 0x1a;
            case 0x1f: // IOGPUCommandQueueSetPriorityAndBackground
                return 0x1b;
            case 0x2a: // IOGPUDeviceCreateVNIODesc
                return 0x26;
        }
    }
    return selector;
}

// AGX ID-translation shim. The iOS kernel AUTO-ASSIGNS resource GIDs (IOGPUObject
// atomic counter; getResource matches resource+0x28), but the macOS AGX driver uses
// CLIENT-ASSIGNED ids at IOGPUNewResourceArgs+0x48 (e.g. heap=0x20000, sub-resource
// parent-id=0x20000). libmachook is userspace-only (can't patch the kernel), so we
// bridge the two id-spaces here: record each created resource's clientID -> the
// iOS GID returned in its OUT struct, and rewrite parent-id references in 0x80
// sub-resources from clientID to the iOS GID so getResource() finds the parent.
static struct { uint64_t clientID, iosGID, size, gpuva0, macosbase, subBaseGpu, subBaseCpu; } g_agxIdMap[128];
static int g_agxIdMapCount;

IOReturn IOConnectCallMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) *outStructCnt = 0x70;
    unsigned char shadowbuf[256];
    uint8_t  agxType = 0; uint32_t agxClientID = 0; uint64_t agxHeapSz = 0;
    uint64_t agxSubGpu0 = 0; int agxSubRW = 0; uint64_t agxVa38 = 0;
    int agxIsRes = (IOConnectIsIOGPU(client) && selector == 0x9 && inStruct && inStructCnt >= 0x60 && inStructCnt <= sizeof(shadowbuf));
    if(agxIsRes) {
        const unsigned char *src = (const unsigned char *)inStruct;
        agxType = src[0];
        {  // DIAGNOSTIC: dump the macOS-sent args struct (IOGPUNewResourceArgs) for heap(t=0)+sub(t=0x80)
            for(size_t _i = 0; _i < inStructCnt && _i <= 0x60; _i += 16) {
                fprintf(stderr, "#### AGXIOC res-IN[t=%#x] +%02zx:", agxType, _i);
                for(size_t _j = 0; _j < 16 && _i + _j < inStructCnt; _j++) fprintf(stderr, " %02x", src[_i + _j]);
                fprintf(stderr, "\n");
            }
        }
        agxClientID = *(const uint32_t *)(src + 0x48);           // client-assigned id / parent-id
        uint64_t bc = *(const uint64_t *)(src + 0x40);           // iOS 32-bit IOByteCount
        uint64_t f30 = *(const uint64_t *)(src + 0x30);
        uint64_t va38 = *(const uint64_t *)(src + 0x38);
        agxVa38 = va38;                                          // carry to post-call (heap macOS base)
        int patched = 0;
        memcpy(shadowbuf, inStruct, inStructCnt);
        if(bc == 0) { uint32_t sz32 = *(const uint32_t *)(src + 0x58); uint64_t _adflt = 0x8000; const char *_as = getenv("AGX_ARENA_SIZE"); if(_as) _adflt = strtoull(_as, NULL, 0); uint64_t nb = sz32 ? sz32 : (agxClientID == 0x20000 ? _adflt : 0x1000); *(uint64_t *)(shadowbuf + 0x40) = nb; agxHeapSz = nb; patched = 1; }  // heap byte-count; AGX_ARENA_SIZE overrides the 0x20000-arena default (0x8000) to test whether the shim shrink breaks the firmware heap view
        // 0x103-AFTER-FIX: macOS internal-heap (clientID 0x10000, args[+0x5c] high u32 = 0xc) is
        // allocated by AGXMetal with the assumption that the kernel SHIFTS the heap base by
        // 0x400000000 (bit 3 of the flags = bit 35 = 0x800000000 → shift). iOS does NOT honor
        // this shift, returning a normal 0x15xx VA, while macOS Metal compiles shaders with the
        // pre-shifted 0x11xx VA baked in → GPU page fault at 0x1158048000 (in the 0x11xx range).
        //
        // FIX_LOW_HEAP (env-gated): for clientID 0x10000 heaps with high-u32 of args[+0x58] = 0xc,
        // record the iOS heap base, then in libmachook also report a SHIFTED VA back to AGXMetal
        // via post-call OUT[0] patch — making macOS Metal compute offsets from 0x11xx, matching
        // its shader-baked VAs. This is fundamentally a userland-only fix attempt; if the kernel
        // also computes things from the OUT VA, this will desync. Currently EXPERIMENT-ONLY.
        // Also tries the inverse: STRIP the option bit pre-call so iOS allocs from same range.
        if(agxType == 0 && agxClientID == 0x10000 && getenv("AGX_STRIP_HEAP_OPT")) {
            uint64_t *opt = (uint64_t *)(shadowbuf + 0x58);
            if((*opt >> 32) & 0xc) {
                uint64_t old = *opt;
                *opt &= 0xffffffffULL;  // strip high u32 flags entirely
                fprintf(stderr, "#### AGXIOC HEAP_OPT_STRIP clientID %#x args[+0x58] %#llx -> %#llx\n",
                        agxClientID, (unsigned long long)old, (unsigned long long)*opt);
                patched = 1;
            }
        }
        if(agxType == 0x80) {
            int mapped = 0;
            for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) {
                *(uint32_t *)(shadowbuf + 0x48) = (uint32_t)g_agxIdMap[i].iosGID;            // parent-id: client -> iOS GID
                // Learn the parent CPU base (lowest sub VA = the offset-0 buffer), then this sub's offset.
                if(va38 && (g_agxIdMap[i].macosbase == 0 || va38 < g_agxIdMap[i].macosbase)) g_agxIdMap[i].macosbase = va38;
                uint64_t _off = (va38 >= g_agxIdMap[i].macosbase) ? (va38 - g_agxIdMap[i].macosbase) : 0;
                // The iOS kernel computes the returned sub gpuAddr = parent_base + (args[0x30]-args[0x38]).
                // Setting that delta = the REAL sub offset makes the KERNEL itself return a distinct VA =
                // parent_base+off AND map the sub there (driver & kernel stay consistent — no OUT[0] desync).
                // [Previously the shim set delta = parent.size, so every sub collapsed to parent_base+size.]
                if(f30 == 0 && va38) *(uint64_t *)(shadowbuf + 0x30) = va38 + _off;
                *(uint64_t *)(shadowbuf + 0x40) = g_agxIdMap[i].size;   // wire/size IOByteCount = arena size (≥ sub)
                agxSubGpu0 = g_agxIdMap[i].gpuva0 + _off;               // expected returned VA (verify post-call)
                agxSubRW = 1;
                patched = 1; mapped = 1;
                fprintf(stderr, "#### AGXIOC subres parent %#x GID %#llx off %#llx -> expect %#llx\n", agxClientID, (unsigned long long)g_agxIdMap[i].iosGID, (unsigned long long)_off, (unsigned long long)agxSubGpu0);
                break;
            }
            if(!mapped && f30 == 0 && va38) { *(uint64_t *)(shadowbuf + 0x30) = va38; patched = 1; }  // fallback: nonzero
        }
        if(patched) inStruct = shadowbuf;
    }
    // DIAGNOSTIC: CreateDeviceShmem (0xd) scalar inputs + submit (0x1a) 56-byte descriptor
    if(IOConnectIsIOGPU(client) && selector == 0xd && in && inCnt >= 2) {
        fprintf(stderr, "#### AGXIOC CreateDeviceShmem IN size=%#llx type=%#llx\n", (unsigned long long)in[0], (unsigned long long)in[1]);
    }
    // DIAGNOSTIC: queue-context create (macOS sel 0x8 -> iOS 0x7), 1032-byte (0x408) struct.
    // Suspected to carry the per-queue firmware context state; if the macOS driver writes
    // bytes the iOS firmware doesn't recognize, every later submit on this queue → 0x103.
    if(IOConnectIsIOGPU(client) && selector == 0x7 && inStruct && inStructCnt >= 0x100) {
        const unsigned char *s = (const unsigned char *)inStruct;
        fprintf(stderr, "#### AGXIOC QCTX IN[%zu]:\n", inStructCnt);
        for(size_t i = 0; i < inStructCnt; i += 32) {
            fprintf(stderr, "####   +%03zx:", i);
            for(size_t j = 0; j < 32 && (i + j) < inStructCnt; j++) fprintf(stderr, " %02x", s[i + j]);
            fprintf(stderr, "\n");
        }
    }
    if(IOConnectIsIOGPU(client) && selector == 0x1a && inStruct && inStructCnt >= 0x10) {
        const unsigned char *s = (const unsigned char *)inStruct;
        fprintf(stderr, "#### AGXIOC SUBMIT IN[%zu]:", inStructCnt);
        for(size_t i = 0; i < inStructCnt && i < 64; i++) fprintf(stderr, " %02x", s[i]);
        fprintf(stderr, "\n");
        // The submit is IOConnectCallMethod(sel 0x1a, 4 SCALARS + struct). Dump the scalar array too:
        // working iOS reference = [*(queue+0x18)=0x1, arg2=0x0, cmdbuf-count=0x1, per-cmdbuf-size=0x38].
        // scalar[0] (per-queue context handle) is the prime 0x103-divergence suspect.
        if(in && inCnt) {
            fprintf(stderr, "#### AGXIOC SUBMIT SCALARS[%u]:", inCnt);
            for(uint32_t _si = 0; _si < inCnt && _si < 8; _si++) fprintf(stderr, " %#llx", (unsigned long long)in[_si]);
            fprintf(stderr, "\n");
        }
        // Deref the two command-buffer descriptor pointers (+0x10,+0x18) the firmware reads, AND one level
        // deeper: each 8-byte slot that looks like a userland CPU VA is deref'd + 64 bytes dumped. This
        // surfaces the deeper AGX command-list structures (control list / pipeline / resource refs + the
        // GPU VAs embedded there) to byte-diff vs the working iosblit path. Range-guarded to avoid faults.
        //
        // DEEP DUMP: the Block at args+0x10/+0x18 captures self=IOGPUMetalCommandBuffer at cb+0x20.
        // The ObjC instance has a sub-object at +0x1f0 holding the kernel-cmd-buffer state, with
        // {start: sub+0x28, current: sub+0x30, end: sub+0x38} (RE'd from
        // -[IOGPUMetalCommandBuffer getCurrentKernelCommandBufferStart:current:end:]). The bytes from
        // start..current are exactly what `AGXCommandQueue::processSegmentKernelCommand` iterates +
        // validates (looking for type=0x30 + size=0x1a8 + end_offset=size+0x30). Dump them.
        if(inStructCnt >= 0x20) {
            uint64_t cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
            for(int pi = 0; pi < 2; pi++) if(cbp[pi] > 0x100000000ULL && cbp[pi] < 0x280000000ULL) {
                const unsigned char *cb = (const unsigned char *)cbp[pi];
                fprintf(stderr, "#### AGXIOC cmdbuf%d@%#llx:", pi, (unsigned long long)cbp[pi]);
                for(int j = 0; j < 0x60; j++) fprintf(stderr, " %02x", cb[j]);
                fprintf(stderr, "\n");
                // KERNEL-COMMAND DEEP DUMP: cb+0x20 = captures[0] = self pointer
                // The macOS IOGPUMetalCommandBuffer holds its kernel-cmd-buffer-state ptr at
                // ivar +0x250 (iOS uses +0x1f0; verified via __objc_ivar lookup in macOS IOGPU).
                uint64_t self_raw = *(const uint64_t *)(cb + 0x20);
                uint64_t self_p = self_raw & 0x0000ffffffffffffULL;
                if(self_p > 0x100000000ULL && self_p < 0x280000000ULL) {
                    uint64_t state_raw = *(const uint64_t *)(uintptr_t)(self_p + 0x250);
                    uint64_t state_p = state_raw & 0x0000ffffffffffffULL;
                    if(state_p > 0x100000000ULL && state_p < 0x280000000ULL) {
                        uint64_t start_raw  = *(const uint64_t *)(uintptr_t)(state_p + 0x28);
                        uint64_t curr_raw   = *(const uint64_t *)(uintptr_t)(state_p + 0x30);
                        uint64_t end_raw    = *(const uint64_t *)(uintptr_t)(state_p + 0x38);
                        uint64_t start = start_raw & 0x0000ffffffffffffULL;
                        uint64_t curr  = curr_raw  & 0x0000ffffffffffffULL;
                        uint64_t end   = end_raw   & 0x0000ffffffffffffULL;
                        fprintf(stderr, "#### AGXIOC cb%d KCMD self=%#llx state=%#llx start=%#llx curr=%#llx end=%#llx\n",
                                pi, (unsigned long long)self_p, (unsigned long long)state_p,
                                (unsigned long long)start, (unsigned long long)curr, (unsigned long long)end);
                        if(start && curr > start && (curr - start) < 0x10000) {
                            size_t len = curr - start;
                            const unsigned char *p = (const unsigned char *)(uintptr_t)start;
                            fprintf(stderr, "#### AGXIOC cb%d KCMD bytes (%zu = %#zx total):\n", pi, len, len);
                            for(size_t off = 0; off < len; off += 32) {
                                fprintf(stderr, "####   +%04zx:", off);
                                for(size_t j = 0; j < 32 && (off + j) < len; j++) fprintf(stderr, " %02x", p[off + j]);
                                fprintf(stderr, "\n");
                                // After every block, check if first 4 bytes look like an outer-cmd type
                                // (0x10000 / 0x10001) — log a marker so we can find OUTER CMD boundaries.
                                if((off & 0x1ff) == 0 && off + 4 <= len) {
                                    uint32_t v = *(const uint32_t *)(p + off);
                                    if(v == 0x10000 || v == 0x10001) {
                                        // also dump type/size/subtype/end_offset fields per the kernel's
                                        // validation: cmd+0x28=end_offset, +0x2c=size, +0x30=inner_type, +0x34=subtype
                                        if(off + 0x38 <= len) {
                                            uint32_t eo = *(const uint32_t *)(p + off + 0x28);
                                            uint32_t sz = *(const uint32_t *)(p + off + 0x2c);
                                            uint32_t it = *(const uint32_t *)(p + off + 0x30);
                                            uint32_t st = *(const uint32_t *)(p + off + 0x34);
                                            fprintf(stderr, "####   OUTER cmd@+%#zx type=%#x end_off=%#x size=%#x inner=%#x sub=%u\n",
                                                    off, v, eo, sz, it, st);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                for(int off = 0; off < 0x60; off += 8) {
                    // Strip PAC tag bits before deref (high 16 bits are signature, low 48 are VA)
                    uint64_t pv_raw = *(const uint64_t *)(cb + off);
                    uint64_t p = pv_raw & 0x0000ffffffffffffULL;
                    if(p > 0x100000000ULL && p < 0x280000000ULL) {
                        const unsigned char *t = (const unsigned char *)(uintptr_t)p;
                        fprintf(stderr, "####   cb%d+%#x -> %#llx (raw %#llx):", pi, off, (unsigned long long)p, (unsigned long long)pv_raw);
                        for(int j = 0; j < 64; j++) fprintf(stderr, " %02x", t[j]);
                        fprintf(stderr, "\n");
                        // BAD-VA HUNT: scan 0x1000 bytes here for any uint64 in the 0x11_xxxxxxxx
                        // range — the GPU page-faulted at 0x1158048000 (BIF0, Compute DM). If a
                        // bad VA was written, we'll see it.
                        for(int k = 0; k + 8 <= 0x1000; k += 8) {
                            uint64_t v = *(const uint64_t *)(t + k);
                            if(v >= 0x1100000000ULL && v < 0x1200000000ULL) {
                                fprintf(stderr, "####     BAD-VA HUNT cb%d+%#x[+%#x] = %#llx (sus, fault was 0x1158048000)\n",
                                        pi, off, k, (unsigned long long)v);
                            }
                            // Also dump VAs from kernel-returned 0x115x range that might be GPU-mapped
                            // surfaces / firmware control buffers (not heap-allocated by user)
                            if(v >= 0x1150000000ULL && v < 0x1160000000ULL) {
                                fprintf(stderr, "####     SUS-VA cb%d+%#x[+%#x] = %#llx (in fault range!)\n",
                                        pi, off, k, (unsigned long long)v);
                            }
                        }
                    }
                }
            }
        }
        // EXPERIMENTAL FIX (AGX_CB_FIX): the cmdbuf-descriptor header token at +0x08 is 0xc3000002 on
        // the macOS driver but 0xc1000002 on the WORKING iOS path (lldb-confirmed, consistent across
        // cmdbuf0+1). The spoofed-macOS driver sets an extra header flag bit (0x02000000) the iOS
        // firmware rejects -> 0x103. Clear it to match iOS, then let the REAL submit proceed.
        if(getenv("AGX_CB_FIX") && inStructCnt >= 0x20) {
            uint64_t _cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
            for(int _pi = 0; _pi < 2; _pi++) if(_cbp[_pi] > 0x100000000ULL && _cbp[_pi] < 0x300000000ULL) {
                uint32_t *_tok = (uint32_t *)(uintptr_t)(_cbp[_pi] + 8);
                uint32_t _old = *_tok; *_tok &= ~0x02000000u;
                fprintf(stderr, "#### AGXIOC CB_FIX cmdbuf%d +0x08 %#x -> %#x\n", _pi, _old, *_tok);
            }
        }
        // 0x103 FIX (AGX_KCMD_FIX): the macOS-chroot AGXMetal13_3 emits subtype-3 outer commands as
        // 0x1b8 bytes (16 bytes too big — iOS kernel's AGXCommandQueue::processSegmentKernelCommand
        // expects subtype-3 size == 0x1a8 exactly). The 16 extra bytes at offset cmd+0x1d8..0x1e7
        // look like an optional macOS extension field (00..00 01..00 ff..ff). Rewrite each
        // subtype-3 outer cmd in the KCMD buffer to size=0x1a8, end_offset=0x1d8, and shift any
        // bytes AFTER end_offset (e.g. trailer commands) DOWN by 16 to keep the kcmd-list
        // consistent. Update the cmdbuf's state.current pointer to reflect the new total.
        if(getenv("AGX_KCMD_FIX") && inStructCnt >= 0x20) {
            uint64_t _cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
            for(int _pi = 0; _pi < 2; _pi++) {
                uint64_t cb = _cbp[_pi];
                if(cb < 0x100000000ULL || cb >= 0x280000000ULL) continue;
                uint64_t self_raw = *(const uint64_t *)(cb + 0x20);
                uint64_t self_p = self_raw & 0x0000ffffffffffffULL;
                if(self_p < 0x100000000ULL || self_p >= 0x280000000ULL) continue;
                uint64_t state_raw = *(const uint64_t *)(uintptr_t)(self_p + 0x250);
                uint64_t state_p = state_raw & 0x0000ffffffffffffULL;
                if(state_p < 0x100000000ULL || state_p >= 0x280000000ULL) continue;
                uint64_t start = (*(const uint64_t *)(uintptr_t)(state_p + 0x28)) & 0x0000ffffffffffffULL;
                uint64_t curr  = (*(const uint64_t *)(uintptr_t)(state_p + 0x30)) & 0x0000ffffffffffffULL;
                if(start == 0 || curr <= start) continue;
                size_t total = curr - start;
                if(total > 0x10000) continue;
                unsigned char *p = (unsigned char *)(uintptr_t)start;
                // Walk outer commands. Each cmd@off has +0x00=type, +0x28=end_offset, +0x2c=size,
                // +0x30=inner_type, +0x34=subtype. For subtype 3 with size != 0x1a8, fix.
                size_t off = 0;
                while(off + 0x38 <= total) {
                    uint32_t *cmd = (uint32_t *)(p + off);
                    uint32_t type = cmd[0];
                    if(type != 0x10000 && type != 0x10001) break;
                    uint32_t end_off = *(uint32_t *)(p + off + 0x28);
                    uint32_t size    = *(uint32_t *)(p + off + 0x2c);
                    uint32_t inner   = *(uint32_t *)(p + off + 0x30);
                    uint32_t sub     = *(uint32_t *)(p + off + 0x34);
                    if(inner == 0x30 && sub == 3 && size == 0x1b8 && end_off == 0x1e8) {
                        // iOS native subtype-3 layout (RE'd from iosblit compute-dispatch capture):
                        // sentinel "01 00 00 00 ff ff ff ff ff ff ff ff" lives at cmd+0x1cc..0x1d7
                        // (12 bytes, ending at cmd+0x1d8 = end of cmd). macOS has the SAME sentinel
                        // but at cmd+0x1dc..0x1e7 — i.e. 16 extra ZERO PADDING bytes inserted at
                        // cmd+0x1cc..0x1db. Removing the wrong 16 bytes (the sentinel itself) makes
                        // the GPU read garbage at the event slot and page-fault (0x0b at VA 0x1158…).
                        // Correct fix: remove the 16 zeros at cmd+0x1cc..0x1db so the sentinel shifts
                        // into iOS-equivalent position 0x1cc..0x1d7.
                        unsigned char *cmd_base = p + off;
                        // Move bytes [0x1dc .. total_after_cmd] (sentinel + trailer) DOWN by 16:
                        size_t total_to_shift = (total - off) - 0x1dc;  // sentinel(0xc) + trailer(0x28) = 0x34, but
                                                                          // may also include any extra after; compute from total
                        memmove(cmd_base + 0x1cc, cmd_base + 0x1dc, total_to_shift);
                        // Zero the now-vacated tail
                        memset(p + (total - 0x10), 0, 0x10);
                        // Patch the size + end_offset fields
                        *(uint32_t *)(p + off + 0x28) = 0x1d8;  // end_offset
                        *(uint32_t *)(p + off + 0x2c) = 0x1a8;  // size
                        total -= 0x10;
                        fprintf(stderr, "#### AGXIOC KCMD_FIX cb%d cmd@+%#zx size 0x1b8->0x1a8 end 0x1e8->0x1d8 (deleted 16 zero pad at +0x1cc..0x1db, shifted %zu bytes) new_total=%#zx\n",
                                _pi, off, total_to_shift, total);
                        // Update the cmdbuf state's `current` ptr to reflect the new total
                        *(uint64_t *)(uintptr_t)(state_p + 0x30) = start + total;
                        // Continue iterating starting at the (now-correct) next cmd
                        off += 0x1d8;
                    } else {
                        off += end_off;
                        if(end_off == 0) break;
                    }
                }
            }
        }
        // EXPERIMENTAL FIX (AGX_PAC_FIX): the "cmdbuf descriptors" at submit+0x10/+0x18 are ObjC
        // Blocks (kernel-side completion callbacks). On the WORKING iOS path Block.isa (cb+0x00) and
        // Block.invoke (cb+0x10) are PAC-signed by the standard arm64e Block runtime (pacda + pacia,
        // disc = field_addr [| 0x6ae1<<48 for isa]; same instructions in macOS+iOS IOGPU builds). In
        // the macOS-chroot dump both fields are RAW (high 16 bits = 0) → the kernel's autda on the
        // submit fails → 0x103. Re-sign in-process here to test whether the process's DA/IA keys are
        // present (just unused by the unsigned-emit Block runtime) or genuinely zero.
        if(getenv("AGX_PAC_FIX") && inStructCnt >= 0x20) {
            uint64_t _cbp[2] = { *(const uint64_t *)(s + 0x10), *(const uint64_t *)(s + 0x18) };
            for(int _pi = 0; _pi < 2; _pi++) {
                uint64_t cb = _cbp[_pi];
                if(cb < 0x100000000ULL || cb >= 0x300000000ULL) continue;
                uint64_t *isa_p = (uint64_t *)(uintptr_t)cb;
                uint64_t *inv_p = (uint64_t *)(uintptr_t)(cb + 0x10);
                uint64_t old_isa = *isa_p, old_inv = *inv_p;
                if((old_isa >> 48) == 0) {  // currently unsigned high 16 bits
                    uint64_t disc = (uint64_t)isa_p | (0x6ae1ULL << 48);
                    uint64_t new_isa = (uint64_t)ptrauth_sign_unauthenticated((void *)old_isa, ptrauth_key_asda, disc);
                    *isa_p = new_isa;
                    fprintf(stderr, "#### AGXIOC PAC_FIX cb%d isa %#llx -> %#llx (disc=%#llx)\n",
                            _pi, (unsigned long long)old_isa, (unsigned long long)new_isa, (unsigned long long)disc);
                }
                if((old_inv >> 48) == 0) {
                    uint64_t disc = (uint64_t)inv_p;
                    uint64_t new_inv = (uint64_t)ptrauth_sign_unauthenticated((void *)old_inv, ptrauth_key_asia, disc);
                    *inv_p = new_inv;
                    fprintf(stderr, "#### AGXIOC PAC_FIX cb%d invoke %#llx -> %#llx (disc=%#llx)\n",
                            _pi, (unsigned long long)old_inv, (unsigned long long)new_inv, (unsigned long long)disc);
                }
            }
        }
        // SAFE MODE: dump only, do NOT submit to the GPU (avoids the cumulative GPU-wedge -> reboot).
        if(getenv("AGX_DUMP_ONLY")) { fprintf(stderr, "#### AGXIOC SUBMIT skipped (AGX_DUMP_ONLY) — no GPU exec\n"); return 0; }
    }
    // DIAGNOSTIC + gated FIX: set_api_property (macOS 0x7 -> iOS 0x6). The iOS kernel handler
    // (IOGPUDeviceUserClient::s_set_api_property) strlcpy's structInput AS A STRING and sets the
    // device "API" property (expects "Metal"). This is the ONLY IOConnect call that fails on the
    // M1-direct path (KERN_INVALID_ADDRESS=0x1); a failed Metal-client registration is a candidate
    // root-cause for the accepted command buffer being later nopped (status=5 / 0x103, no GPU fault).
    if(IOConnectIsIOGPU(client) && selector == 0x6 && inStruct) {
        const unsigned char *s = (const unsigned char *)inStruct;
        fprintf(stderr, "#### AGXIOC set_api IN[%zu]:", inStructCnt);
        for(size_t i = 0; i < inStructCnt && i < 32; i++) fprintf(stderr, " %02x", s[i]);
        fprintf(stderr, " ascii='");
        for(size_t i = 0; i < inStructCnt && i < 16; i++) fprintf(stderr, "%c", (s[i] >= 0x20 && s[i] < 0x7f) ? s[i] : '.');
        fprintf(stderr, "'\n");
        if(getenv("AGX_API_FIX")) {
            memset(shadowbuf, 0, 16); memcpy(shadowbuf, "Metal", 5);
            inStruct = shadowbuf; inStructCnt = 16;
            fprintf(stderr, "#### AGXIOC set_api -> rewrote structInput to inline \"Metal\" (16B)\n");
        }
    }
    IOReturn r = IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client) && selector == 0xd && r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x10) {
        const uint64_t *o64 = (const uint64_t *)outStruct;
        const uint32_t *o32 = (const uint32_t *)outStruct;
        fprintf(stderr, "#### AGXIOC CreateDeviceShmem OUT va=%#llx id=%#x sz=%#x\n", (unsigned long long)o64[0], o32[2], o32[3]);
    }
    if(agxIsRes && r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x30) {
        const unsigned char *o = (const unsigned char *)outStruct;
        if(agxType == 0) {  // parent HEAP: record namespace index (OUT+0x1c) + base GPU VA (OUT+0x00)
            // IOGPUNamespace is an ARRAY indexed by a SMALL id (getObjectLocked: id<count, array[id]);
            // OUT+0x1c is that small index. The GPU VA (resource[0x38] via IOGPUResourceCreate) = OUT+0x00.
            uint64_t gid = *(const uint32_t *)(o + 0x1c);
            int slot = -1;
            for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) { slot = i; break; }  // overwrite (clientID reused)
            if(slot < 0 && g_agxIdMapCount < 128) slot = g_agxIdMapCount++;
            if(slot >= 0) { g_agxIdMap[slot].clientID = agxClientID; g_agxIdMap[slot].iosGID = gid; g_agxIdMap[slot].size = agxHeapSz; g_agxIdMap[slot].gpuva0 = *(const uint64_t *)(o + 0x00); g_agxIdMap[slot].macosbase = agxVa38; g_agxIdMap[slot].subBaseGpu = 0; g_agxIdMap[slot].subBaseCpu = 0; }
            fprintf(stderr, "#### AGXIOC heap clientID %#x -> GID %#llx size %#llx gpuva0 %#llx macosbase %#llx\n", agxClientID, (unsigned long long)gid, (unsigned long long)agxHeapSz, (unsigned long long)*(const uint64_t *)(o + 0x00), (unsigned long long)agxVa38);
        }
        if(agxType == 0x80 && agxSubRW) {
            uint64_t oldg = *(uint64_t *)((unsigned char *)outStruct + 0x00);
            // The kernel should now return parent_base+off (we set args[0x30]-args[0x38]=off). If it does
            // (MATCH), the sub is mapped THERE -> leave it (driver & kernel consistent). If not (MISMATCH),
            // override OUT[0] to the expected VA as a fallback (kernel mapping may differ -> may still fault).
            int match = (oldg == agxSubGpu0);
            if(!match && agxSubGpu0) *(uint64_t *)((unsigned char *)outStruct + 0x00) = agxSubGpu0;
            fprintf(stderr, "#### AGXIOC subres OUT[0] kernel=%#llx expect=%#llx %s\n", (unsigned long long)oldg, (unsigned long long)agxSubGpu0, match ? "MATCH" : "MISMATCH(override)");
        }
    }
    if(IOConnectIsIOGPU(client)) {
        fprintf(stderr, "#### AGXIOC Method sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inCnt, inStructCnt, outStructCnt?*outStructCnt:0, r);
    }
    return r;
}
IOReturn IOConnectCallScalarMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallScalarMethod(client, selector, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC Scalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallStructMethod_new(io_connect_t client, uint32_t selector, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    // AGX GPU device-info query (method 256 / setupImmediate): macOS 13.4 asks for
    // a 0x78 (120-byte) output struct, but the iOS 16.x GPU userclient hard-checks
    // the output size at 0x70 (112). The 8-byte mismatch -> kIOReturnBadArgument and
    // AGX device init aborts. Clamp to what the iOS kernel accepts. (Found by diffing
    // macOS AGXMetal13_3 727C250E vs iOS BA327004 in Ghidra: both selector 0x100,
    // outStructCnt 0x78 vs 0x70.)
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) {
        *outStructCnt = 0x70;
    }
    // set_api_property (macOS 0x7 -> iOS 0x6): the iOS kernel handler strlcpy's structInput AS A
    // STRING and sets the device "API" property (expects "Metal"). This is the ONLY failing IOConnect
    // call on the M1-direct path (-> 0x1 KERN_INVALID_ADDRESS); a failed Metal-client registration is a
    // candidate root-cause for the accepted command buffer being nopped (status=5/0x103, no GPU fault).
    static unsigned char apibuf[16];
    if(IOConnectIsIOGPU(client) && selector == 0x6 && inStruct) {
        const unsigned char *s = (const unsigned char *)inStruct;
        fprintf(stderr, "#### AGXIOC set_api IN[%zu]:", inStructCnt);
        for(size_t i = 0; i < inStructCnt && i < 32; i++) fprintf(stderr, " %02x", s[i]);
        fprintf(stderr, " ascii='");
        for(size_t i = 0; i < inStructCnt && i < 16; i++) fprintf(stderr, "%c", (s[i] >= 0x20 && s[i] < 0x7f) ? s[i] : '.');
        fprintf(stderr, "'\n");
        if(getenv("AGX_API_FIX")) {
            memset(apibuf, 0, sizeof(apibuf)); memcpy(apibuf, "Metal", 5);
            inStruct = apibuf; inStructCnt = 16;
            fprintf(stderr, "#### AGXIOC set_api -> rewrote structInput to inline \"Metal\" (16B)\n");
        }
    }
    IOReturn r = IOConnectCallStructMethod(client, selector, inStruct, inStructCnt, outStruct, outStructCnt);
    // DIAGNOSTIC: device-info (sel 0x100) OUT — dump full 0x78 incl the +0x70..+0x78 field the iOS kernel
    // (0x70-byte struct) never fills but the macOS-13.4 driver (0x78 struct) reads. If that field is the
    // firmware-context divergence, the shim's size-clamp is incomplete and we must populate it here.
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStruct) {
        const unsigned char *o = (const unsigned char *)outStruct;
        fprintf(stderr, "#### AGXIOC devinfo OUT[0x78] (kernel filled 0x0..0x70; 0x70..0x78 is macOS-read):");
        for(int i = 0; i < 0x78; i++) { if(i == 0x70) fprintf(stderr, " |"); fprintf(stderr, " %02x", o[i]); }
        fprintf(stderr, "\n");
    }
    // FIX ATTEMPT: the macOS-13.4 driver reads device-info[+0x70..+0x78] which the iOS-16.3 kernel never
    // fills (its struct is 0x70). It reads its buffer's stale value (0x80000000) -> may build a wrong
    // firmware context -> every submit aborts (0x103). Write an env-chosen value there so the driver sees
    // a compatible value. AGX_DEVINFO_FIX=0 (zero/feature-absent), or =0x... to try a specific value.
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStruct) {
        const char *_df = getenv("AGX_DEVINFO_FIX");
        if(_df) {
            uint64_t _v = strtoull(_df, NULL, 0);
            *(uint64_t *)((unsigned char *)outStruct + 0x70) = _v;
            fprintf(stderr, "#### AGXIOC devinfo FIX: wrote +0x70 = %#llx\n", (unsigned long long)_v);
        }
    }
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC Struct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
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
DYLD_INTERPOSE(IOConnectCallMethod_new, IOConnectCallMethod);
DYLD_INTERPOSE(IOConnectCallScalarMethod_new, IOConnectCallScalarMethod);
DYLD_INTERPOSE(IOConnectCallStructMethod_new, IOConnectCallStructMethod);
DYLD_INTERPOSE(IOConnectCallAsyncMethod_new, IOConnectCallAsyncMethod);
DYLD_INTERPOSE(IOConnectCallAsyncScalarMethod_new, IOConnectCallAsyncScalarMethod);
DYLD_INTERPOSE(IOConnectCallAsyncStructMethod_new, IOConnectCallAsyncStructMethod);

kern_return_t IOServiceOpen_new(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect) {
    static io_service_t agxService;
    if(!agxService) {
        agxService = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
        assert(agxService != IO_OBJECT_NULL);
    }
    
    // clear flag 4 (FIXME: idk what is this)
    type &= ~4;
    
    kern_return_t result = IOServiceOpen(service, owningTask, type, connect);
    assert(iogpuClientsCount < sizeof(iogpuClients) / sizeof(iogpuClients[0]));
    if(result == KERN_SUCCESS && service == agxService) {
        iogpuClients[iogpuClientsCount++] = *connect;
        fprintf(stderr, "#### debugbydcmmc IOServiceOpen agx connect=%d type=%d\n", *connect, type);
    }
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif