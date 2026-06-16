@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
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
// WS never scans out to the panel -> no iOS/macOS flicker.  Gated to WindowServer + the runtime
// flag file /tmp/ws_headless (chroot path) so the default macOS-on-panel behavior is unchanged.
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
        
        // grant all permissions
        MSHookFunction(MSFindSymbol((MSImageRef)header, "_audit_token_check_tcc_access"), hooked_return_1, NULL);
            
        // NSLog(@"#### debugbydcmmc loadImageCallback before OFF_SkyLight_WSSystemCanCompositeWithMetal");
#if FORCE_SW_RENDER
        // skip Metal check (WSSystemCanCompositeWithMetal::once)
        int64_t *once = (int64_t *)(OFF_SkyLight_WSSystemCanCompositeWithMetal + (uintptr_t)header);
        *once = -1;
#endif

        // MACWS_AGX_NATIVE: in chroot under AGX-native userspace, multiple SkyLight
        // assertions in the compositor path fail because the AGX-native render targets
        // are set up differently than the sim wrapper. Auto-patch backward-BL calls
        // following an adrp+add that loads ONE OF a known list of file-basename strings
        // (so we only neuter __assert_rtn callsites in specific files, not random BL).
        if (getenv("MACWS_AGX_NATIVE")) {
            unsigned long text_sz = 0, cstr_sz = 0;
            uint8_t *text = getsectiondata((const struct mach_header_64 *)header, "__TEXT", "__text", &text_sz);
            uint8_t *cstr = getsectiondata((const struct mach_header_64 *)header, "__TEXT", "__cstring", &cstr_sz);
            fprintf(stderr, "#### MACWS_AGX_NATIVE SkyLight: text=%p sz=%lu cstr=%p sz=%lu\n",
                text, text_sz, cstr, cstr_sz);

            // File-basename strings whose assertions we target. Add more as new crashes
            // are diagnosed. Each string must be the EXACT filename token used in
            // __assert_rtn's file argument (no leading path, ends in .mm/.cpp/.cc).
            const char *target_files[] = {
                "CAWSBackend.mm",
                NULL
            };

            for (int n = 0; target_files[n]; n++) {
                size_t nlen = strlen(target_files[n]);
                uint64_t string_addr = 0;
                for (size_t p = 0; p + nlen < cstr_sz; p++) {
                    if (cstr[p] == target_files[n][0] && memcmp(cstr + p, target_files[n], nlen) == 0 &&
                        cstr[p + nlen] == '\x00' && (p == 0 || cstr[p - 1] == '\x00')) {
                        string_addr = (uint64_t)(cstr + p);
                        break;
                    }
                }
                if (!string_addr) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE filename '%s' not found\n", target_files[n]);
                    continue;
                }

                uint32_t *text32 = (uint32_t *)text;
                size_t text_n = text_sz / 4;
                int patched = 0;
                for (size_t i = 0; i + 12 < text_n; i++) {
                    uint32_t adrp = text32[i];
                    if ((adrp & 0x9F000000) != 0x90000000) continue;
                    int64_t immlo = (int64_t)((adrp >> 29) & 0x3);
                    int64_t immhi = (int64_t)((adrp >> 5) & 0x7FFFF);
                    int64_t imm = (immhi << 2) | immlo;
                    if (imm & (1LL << 20)) imm |= ~((1LL << 21) - 1);
                    imm <<= 12;
                    uint64_t pc = (uint64_t)&text32[i];
                    uint64_t page_target = (pc & ~0xFFFULL) + (uint64_t)imm;

                    uint32_t inst1 = text32[i + 1];
                    if ((inst1 & 0xFFC00000) != 0x91000000) continue;
                    uint32_t add_imm = (inst1 >> 10) & 0xFFF;
                    uint32_t shift = (inst1 >> 22) & 0x3;
                    uint64_t final_addr = page_target + ((uint64_t)add_imm << (shift * 12));
                    if (final_addr != string_addr) continue;

                    // Find backward BL within next 8 insns (assert calls are tight)
                    for (size_t j = i + 2; j < i + 10 && j < text_n; j++) {
                        uint32_t inst = text32[j];
                        if ((inst & 0xFC000000) == 0x94000000) {  // BL
                            int32_t imm26 = (int32_t)(inst & 0x03FFFFFF);
                            if (imm26 & 0x02000000) imm26 |= 0xFC000000;
                            int64_t bl_offset = (int64_t)imm26 * 4;
                            if (bl_offset >= 0) continue;  // forward
                            ModifyExecutableRegion(&text32[j], sizeof(uint32_t), ^{
                                text32[j] = 0xd503201f;  // NOP
                            });
                            fprintf(stderr, "#### MACWS_AGX_NATIVE %s assert NOP at text+%#zx\n", target_files[n], j * 4);
                            patched++;
                            break;
                        }
                    }
                }
                fprintf(stderr, "#### MACWS_AGX_NATIVE %s: patched %d sites\n", target_files[n], patched);
            }

            // NOTE: Removed previous PrepareForUse / WSComposite / CreateCompositeDestination
            // NOP-cascade patches per user direction. They let WS survive longer but produced
            // empty textures (no GPU content) — VNC would show blank. The correct fix is the
            // BSS pool allocator shim in the AGXMetal13_3 branch below (see MACWS_AGX_BSS_SHIM).
        }

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

        // COEXISTENCE (flicker fix): in WindowServer only, and only when the runtime flag file
        // /tmp/ws_headless exists, neutralize kern_SwapEnd's panel present so WS renders to its
        // framebuffer (VNC reads it) but never scans out to the physical iPad panel — iOS keeps
        // the panel, eliminating the iOS/macOS flicker.  Default OFF (no flag file) => original
        // macOS-on-panel behavior is untouched.  Toggle live by touch/rm /var/mnt/rootfs/tmp/ws_headless
        // then restarting WindowServer.
        {
            char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
            if(_NSGetExecutablePath(exe, &exelen) == 0 &&
               strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL &&
               access("/tmp/ws_headless", F_OK) == 0) {
                uint32_t *swapSubmit = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_submit + (uintptr_t)header);
                ModifyExecutableRegion(swapSubmit, sizeof(uint32_t), ^{
                    if (*swapSubmit == 0x94001f64) { // bl IOConnectCallStructMethod (panel present)
                        *swapSubmit = 0xd2800000;    // mov x0, #0  (skip present, return KERN_SUCCESS)
                    }
                });
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
    } else if(getenv("MACWS_AGX_NATIVE") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
        // CHROOT AGX-NATIVE: two-layer patch for the strict-AGX-native userspace path.
        //
        // ROOT CAUSE: when libmachook injected chroot processes dlopen AGXMetal13_3
        // standalone (not via macOS dyld_shared_cache, which isn't activated for chroot),
        // cross-image BSS function pointers stay null/zero (the IOGPU pool allocator at
        // 0x21f95bc90 etc.). Mempool<...>::grow then runs its inline freelist-init
        // believing the pool allocator populated [this+8]; *(NULL+8+0x18+0x18) faults
        // at addr 0x30 (KERN_INVALID_ADDRESS).
        //
        // FIX 1: Make -[setupDeferred] a no-op (skip the dispatch_once call that
        // initializes per-encoder mempools en masse). This unblocks newCommandQueue.
        // FIX 2: Patch each individual Mempool<...>::grow function — since textures
        // also lazily call grow on their own — to skip its broken inline freelist loop.
        // Both are pattern-based, version-stable signatures.

        unsigned long text_sz = 0;
        uint8_t *text = getsectiondata((const struct mach_header_64 *)header, "__TEXT", "__text", &text_sz);
        uint32_t *text32 = (uint32_t *)text;
        size_t n = text_sz / 4;

        // FIX 1: setupDeferred outer — patch b.ne at +0x64 to NOP so we fall through
        // to the epilogue without ever calling dispatch_once.
        int setup_patched = 0;
        for (size_t i = 0; i + 4 < n && setup_patched < 1; i++) {
            if (text32[i] == 0xb100051f && text32[i+1] == 0x54000081 &&
                text32[i+2] == 0xa9437bfd && text32[i+3] == 0x910103ff &&
                text32[i+4] == 0xd65f0fff) {
                ModifyExecutableRegion(&text32[i+1], sizeof(uint32_t), ^{
                    text32[i+1] = 0xd503201f; // NOP
                });
                fprintf(stderr, "#### MACWS_AGX_NATIVE setupDeferred dispatch_once skipped at text+%#zx\n", i*4);
                setup_patched++;
            }
        }

        // FIX 2: All 4 Mempool<...>::grow variants share a structural signature in
        // the entry path: a `cmp w8, w<X>` followed by `b.hs +<off>` that branches
        // PAST the broken init loop. We force the branch to be taken AND extend its
        // target to the function epilogue (which is at a fixed pattern of
        // ldp x29,x30 / [ldp x20,x19] / add sp,sp / retab).
        //
        // Simpler universal patch: at every `cmp w?, w?` followed by `b.hs +<off>`
        // inside __text that lies between specific markers (entry pattern of
        // Mempool::grow: `pacibsp / sub sp,sp,#0x40 / stp x20,x19,[sp,#0x20]`)
        // — make the b.hs unconditional and use its existing target.
        //
        // For now, hardcode the 4 known grow function addresses and patch each.
        uint64_t text_static_base = 0x1e53e321c;
        intptr_t slide = (intptr_t)text - (intptr_t)text_static_base;
        uint64_t grows_static[] = {
            0x1e57236cc, // Mempool<16,0,true, ImageStateEncoderGen6>::grow
            0x1e571c4f4, // Mempool<1024,28,false, SamplerStateEncoderGen4>::grow
            0x1e55d1ff0, // Mempool<16,0,true, uint64_t>::grow
            0x1e564d640, // Mempool<32,0,true, uint64_t>::grow
        };
        int grow_patched = 0;
        for (int g = 0; g < 4; g++) {
            uint32_t *grow = (uint32_t *)(grows_static[g] + slide);
            // Find the cmp/b.hs site first.
            int bhs_idx = -1;
            for (int i = 0; i < 64; i++) {
                uint32_t insn = grow[i];
                if ((insn & 0xFF00001F) == 0x54000002) {  // b.hs
                    bhs_idx = i;
                    break;
                }
            }
            if (bhs_idx < 0) continue;
            // Then scan forward for retab (d65f0fff) — the function epilogue.
            int retab_idx = -1;
            for (int i = bhs_idx + 1; i < 256; i++) {
                if (grow[i] == 0xd65f0fff) { retab_idx = i; break; }
            }
            if (retab_idx < 0) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE grow %d retab not found, skip\n", g);
                continue;
            }
            // The epilogue prologue (ldp x29,x30 / [ldp x20,x19] / add sp,sp) is the
            // 2-3 instructions before retab. Jump TARGET = retab_idx - 2 (typically
            // ldp x29,x30). For safety, scan backward from retab for the first
            // ldp x29,x30,[sp,#N] (0xA9?37BFD pattern matches stp/ldp X29,X30).
            int epi_idx = -1;
            for (int i = retab_idx - 1; i > bhs_idx && i > retab_idx - 8; i--) {
                if ((grow[i] & 0xFFC07FFF) == 0xA9407BFD || // ldp x29,x30,[sp,#X]
                    (grow[i] & 0xFFC07FFF) == 0xA9407BFD) {
                    epi_idx = i;
                    break;
                }
            }
            // Looser fallback: just use retab_idx - 2 if ldp pattern isn't matched.
            if (epi_idx < 0) epi_idx = retab_idx - 2;
            int64_t off_bytes = (int64_t)(epi_idx - bhs_idx) * 4;
            uint32_t b_insn = 0x14000000 | (((uint32_t)(off_bytes >> 2)) & 0x03FFFFFF);
            ModifyExecutableRegion(&grow[bhs_idx], sizeof(uint32_t), ^{
                grow[bhs_idx] = b_insn;
            });
            fprintf(stderr, "#### MACWS_AGX_NATIVE grow %d (%#llx) b.hs@+%#x → b epi@+%#x (off %lld)\n",
                g, (unsigned long long)grows_static[g], bhs_idx*4, epi_idx*4, (long long)off_bytes);
            grow_patched++;
        }
        fprintf(stderr, "#### MACWS_AGX_NATIVE patches: setupDeferred=%d grows=%d\n",
            setup_patched, grow_patched);
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
static struct { uint64_t clientID, iosGID, size; } g_agxIdMap[128];
static int g_agxIdMapCount;

IOReturn IOConnectCallMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) *outStructCnt = 0x70;
    unsigned char shadowbuf[256];
    uint8_t  agxType = 0; uint32_t agxClientID = 0; uint64_t agxHeapSz = 0;
    int agxIsRes = (IOConnectIsIOGPU(client) && selector == 0x9 && inStruct && inStructCnt >= 0x60 && inStructCnt <= sizeof(shadowbuf));
    if(agxIsRes) {
        const unsigned char *src = (const unsigned char *)inStruct;
        agxType = src[0];
        agxClientID = *(const uint32_t *)(src + 0x48);           // client-assigned id / parent-id
        uint64_t bc = *(const uint64_t *)(src + 0x40);           // iOS 32-bit IOByteCount
        uint64_t f30 = *(const uint64_t *)(src + 0x30);
        uint64_t va38 = *(const uint64_t *)(src + 0x38);
        int patched = 0;
        memcpy(shadowbuf, inStruct, inStructCnt);
        if(bc == 0) { uint32_t sz32 = *(const uint32_t *)(src + 0x58); uint64_t nb = sz32 ? sz32 : 0x1000; *(uint64_t *)(shadowbuf + 0x40) = nb; agxHeapSz = nb; patched = 1; }  // heap byte-count
        if(agxType == 0x80) {
            int mapped = 0;
            for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) {
                *(uint32_t *)(shadowbuf + 0x48) = (uint32_t)g_agxIdMap[i].iosGID;            // parent-id: client -> iOS GID
                if(f30 == 0 && va38) *(uint64_t *)(shadowbuf + 0x30) = va38 + g_agxIdMap[i].size;  // +0x30 = end-VA so size(=+0x30-+0x38) = parent size
                patched = 1; mapped = 1;
                fprintf(stderr, "#### AGXIOC subres parent %#x -> GID %#llx, +0x30=%#llx (sz %#llx)\n", agxClientID, (unsigned long long)g_agxIdMap[i].iosGID, (unsigned long long)(va38 + g_agxIdMap[i].size), (unsigned long long)g_agxIdMap[i].size);
                break;
            }
            if(!mapped && f30 == 0 && va38) { *(uint64_t *)(shadowbuf + 0x30) = va38; patched = 1; }  // fallback: nonzero
        }
        if(patched) inStruct = shadowbuf;
    }
    IOReturn r = IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if(agxIsRes && r == 0 && agxType == 0 && outStruct && outStructCnt && *outStructCnt >= 0x30) {
        const unsigned char *o = (const unsigned char *)outStruct;
        uint64_t gid = *(const uint64_t *)(o + 0x28);   // iOS GID: monotonic IOGPUObject counter, echoed at OUT+0x28
        int slot = -1;
        for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) { slot = i; break; }  // overwrite (clientID reused)
        if(slot < 0 && g_agxIdMapCount < 128) slot = g_agxIdMapCount++;
        if(slot >= 0) { g_agxIdMap[slot].clientID = agxClientID; g_agxIdMap[slot].iosGID = gid; g_agxIdMap[slot].size = agxHeapSz; }
        fprintf(stderr, "#### AGXIOC heap clientID %#x -> GID %#llx size %#llx\n", agxClientID, (unsigned long long)gid, (unsigned long long)agxHeapSz);
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
    IOReturn r = IOConnectCallStructMethod(client, selector, inStruct, inStructCnt, outStruct, outStructCnt);
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