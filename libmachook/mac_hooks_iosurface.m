// mac_hooks_iosurface.m — part 3 of the mac_hooks.m split.
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

// CarbonCore's LMGetBootDrive still backs DesktopServices' boot-volume
// identity on macOS 13. In the iOS-hosted chroot it reports the host boot
// volume, while CFURL's volume resource property correctly reports the mounted
// root's signed 16-bit vRefNum. Finder consequently fails to mark the root
// TFSVolumeInfo as the boot volume and asks the not-yet-populated global volume
// map for it during that same object's initialization.
//
// CarbonCore is not chroot-aware: runtime-confirmed in Finder on this iPad,
// LMGetBootDrive returned the host boot volume -100 while `/` reported -101.
// RE-confirmed at DesktopServicesPriv+0xe8280..+0xe829c: the result is compared
// directly with the volume being initialized; the mismatch leaves isBootVolume
// false and later makes +0xe8374 look up a nonexistent physical-volume peer.
// Derive the logical boot volume through the exact _kCFURLVolumeRefNumKey
// mechanism used by DesktopServicesPriv::TCFURLInfo::GetVRefNum(CFURLRef).
// Preserve CarbonCore only when the process-visible root cannot provide one.
extern int16_t LMGetBootDrive(void);
extern const CFStringRef _kCFURLVolumeRefNumKey;

int16_t macws_root_volume_refnum(void) {
    static _Atomic int32_t cached = 0;
    static _Thread_local bool resolving = false;
    int32_t previous = atomic_load_explicit(&cached, memory_order_acquire);
    if (previous != 0) return (int16_t)previous;
    // CFURL is the authoritative provider, but preserve CarbonCore's native
    // value if a future OS revision asks LMGetBootDrive while constructing the
    // root resource cache itself.
    if (resolving) return 0;
    resolving = true;

    // Finder's 2026-08-01 SIGTRAP is runtime-confirmed at
    // CFStringGetLength -> _CFURLCreateWithFileSystemPath from this hook, with
    // this hook's CFSTR argument as the only CFString input. Avoid that
    // cross-image CFString construction boundary and create the same root URL
    // from stable POSIX bytes; the volume refnum still comes from the native
    // CFURL resource property.
    static const UInt8 rootPath[] = {'/'};
    CFURLRef rootURL = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, rootPath, sizeof(rootPath), true);
    if (!rootURL) {
        resolving = false;
        return 0;
    }

    CFTypeRef value = NULL;
    CFErrorRef error = NULL;
    Boolean copied = CFURLCopyResourcePropertyForKey(rootURL,
                                                      _kCFURLVolumeRefNumKey,
                                                      &value,
                                                      &error);
    int16_t result = 0;
    if (copied && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        (void)CFNumberGetValue((CFNumberRef)value,
                               kCFNumberSInt16Type,
                               &result);
    }
    if (value) CFRelease(value);
    if (error) CFRelease(error);
    CFRelease(rootURL);
    if (result != 0) {
        atomic_store_explicit(&cached, (int32_t)result,
                              memory_order_release);
    }
    resolving = false;
    return result;
}

int16_t LMGetBootDrive_new(void) {
    int16_t native = LMGetBootDrive();
    int16_t repaired = macws_root_volume_refnum();
    int16_t effective = repaired != 0 ? repaired : native;
    if (macws_runtime_diagnostics_enabled() ||
        getenv("MACWS_DESKTOPSERVICES_DIAG")) {
        dprintf(STDERR_FILENO,
                "MACWS-DESKTOP-VOLUME LMGetBootDrive native=%d "
                "root-CFURL=%d effective=%d\n",
                (int)native, (int)repaired, (int)effective);
    }
    return effective;
}

// A chroot changes pathname lookup's process root but does not turn that vnode
// into the APFS mount's kernel-level root.  CoreServices therefore reports the
// chroot's "/" with a valid file ID but without its is-volume bit.  The macOS
// DesktopServices consumer maps bit 3 of the second flags result directly to
// TFSInfo's no-parent/volume-root flag.  Without it, walking the parent of "/"
// repeatedly resolves the same file-reference URL and Finder spins forever in
// THFSPlusPropertyStore::IsInPackage.
//
// Recognize only the process root.  CFURLGetString is side-effect free and the
// file-reference form carries the inode (runtime example:
// file:///.file/id=6684248.22434439/); matching it to stat("/") avoids calling
// back into resource-property resolution from this interposer.
extern Boolean _CFURLCopyResourcePropertyValuesAndFlags(
    CFURLRef url,
    uint64_t requestedValues,
    uint64_t *returnedValues,
    void *filePropertyValues,
    uint64_t requestedFlags,
    uint64_t *returnedFlags,
    CFErrorRef *error);

bool macws_cfurl_is_process_root(CFURLRef url) {
    if (!url) return false;
    CFStringRef string = CFURLGetString(url);
    if (!string) return false;

    char text[PATH_MAX];
    if (!CFStringGetCString(string, text, sizeof(text),
                            kCFStringEncodingUTF8)) {
        return false;
    }
    if (strcmp(text, "file:///") == 0 ||
        strcmp(text, "file://localhost/") == 0) {
        return true;
    }

    static _Atomic uint64_t cachedRootInode = 0;
    static _Atomic uint64_t cachedRootDevice = 0;
    uint64_t rootInode = atomic_load_explicit(&cachedRootInode,
                                               memory_order_acquire);
    uint64_t rootDevice = atomic_load_explicit(&cachedRootDevice,
                                               memory_order_acquire);
    if (rootInode == 0) {
        struct stat st = {0};
        if (stat("/", &st) != 0 || st.st_ino == 0) return false;
        rootInode = (uint64_t)st.st_ino;
        rootDevice = (uint64_t)st.st_dev;
        atomic_store_explicit(&cachedRootDevice, rootDevice,
                              memory_order_release);
        atomic_store_explicit(&cachedRootInode, rootInode,
                              memory_order_release);
    }

    static const char prefix[] = "file:///.file/id=";
    if (strncmp(text, prefix, sizeof(prefix) - 1) != 0) {
        // LaunchServices persists the macOS volume under its kernel-visible
        // mount name (`/rootfs` on this device). postinst provides only that
        // exact symlink to `/`; following it and comparing vnode identity lets
        // FSNode preserve the logical-volume invariant without blessing any
        // unrelated path string.
        UInt8 path[PATH_MAX];
        struct stat st = {0};
        return CFURLGetFileSystemRepresentation(url, true,
                                                 path, sizeof(path)) &&
            stat((const char *)path, &st) == 0 &&
            (uint64_t)st.st_dev == rootDevice &&
            (uint64_t)st.st_ino == rootInode;
    }
    char *dot = strrchr(text, '.');
    if (!dot || dot[1] == '\0') return false;
    char *end = NULL;
    errno = 0;
    unsigned long long inode = strtoull(dot + 1, &end, 10);
    return errno == 0 && inode == rootInode && end &&
        strcmp(end, "/") == 0;
}

// LaunchServices does not reach the exported
// _CFURLCopyResourcePropertyValuesAndFlags interpose above when it classifies
// an FSNode.  Runtime LLDB against macOS 13.4 LaunchServices on 2026-08-02
// confirmed this exact private implementation:
//
//   -[FSNode isVolume] 0x19e38637c
//     isDirectory
//     _FSNodeCopyResourceProperty(NSURLIsVolumeKey, flag 1 << 3)
//     isMountTrigger                         (fallback)
//
// For the chroot's logical root the actual object printed as
// `<FSNode ...> { isDir = y, path = '/' }`, while NSURLIsVolumeKey was false
// and isMountTrigger was false.  _LSIsNodeTranslocatedMountPoint therefore
// created NSOSStatusErrorDomain/-50 at its source line 117, before lsd saw a
// registration request.  The same runtime probe enumerated FSNode's exact
// `URL` (`@16@0:8`) and `isVolume` (`B16@0:8`) methods.
//
// Preserve every native positive result.  Only restore the missing logical
// chroot-root invariant, using the same exact URL/inode predicate as the
// lower-level CFURL repair.  This is intentionally not a registration/check
// bypass: non-root nodes and every native error remain untouched.
BOOL (*macws_FSNode_isVolume_original)(id, SEL) = NULL;

BOOL macws_FSNode_isVolume(id self, SEL selector) {
    BOOL native = macws_FSNode_isVolume_original
        ? macws_FSNode_isVolume_original(self, selector) : NO;
    if (native || !self) return native;

    SEL urlSelector = sel_registerName("URL");
    Method urlMethod = class_getInstanceMethod(object_getClass(self),
                                                urlSelector);
    if (!urlMethod || strcmp(method_getTypeEncoding(urlMethod), "@16@0:8") != 0) {
        return native;
    }
    CFURLRef url = ((CFURLRef (*)(id, SEL))objc_msgSend)(self, urlSelector);
    if (!macws_cfurl_is_process_root(url)) return native;

    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS_CHROOT_ROOT marked exact FSNode root as volume\n");
    }
    return YES;
}

void macws_install_fsnode_root_volume_repair(void) {
    static _Atomic int installed = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &installed, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }

    Class fsNode = objc_getClass("FSNode");
    SEL selector = sel_registerName("isVolume");
    Method method = fsNode ? class_getInstanceMethod(fsNode, selector) : NULL;
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    if (!method || !types || strcmp(types, "B16@0:8") != 0) {
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                    "#### MACWS_CHROOT_ROOT FSNode hook skipped class=%p "
                    "method=%p types=%s\n",
                    fsNode, method, types ?: "(null)");
        }
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    IMP original = method_getImplementation(method);
    if (!original || original == (IMP)macws_FSNode_isVolume) {
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }
    macws_FSNode_isVolume_original = (BOOL (*)(id, SEL))original;
    method_setImplementation(method, (IMP)macws_FSNode_isVolume);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS_CHROOT_ROOT installed FSNode isVolume repair "
                "class=%p original=%p\n", fsNode, original);
    }
}

Boolean macws_CFURLCopyResourcePropertyValuesAndFlags(
    CFURLRef url,
    uint64_t requestedValues,
    uint64_t *returnedValues,
    void *filePropertyValues,
    uint64_t requestedFlags,
    uint64_t *returnedFlags,
    CFErrorRef *error) {
    Boolean result = _CFURLCopyResourcePropertyValuesAndFlags(
        url, requestedValues, returnedValues, filePropertyValues,
        requestedFlags, returnedFlags, error);
    const uint64_t isVolumeFlag = 1ULL << 3;
    if (result && returnedFlags &&
        (requestedFlags & isVolumeFlag) != 0 &&
        ((*returnedFlags & isVolumeFlag) == 0) &&
        macws_cfurl_is_process_root(url)) {
        *returnedFlags |= isVolumeFlag;
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                    "#### MACWS_CHROOT_ROOT marked CFURL as volume root\n");
        }
    }
    return result;
}

// Ventura CoreLocationAgent receives a textual designated requirement from a
// registering desktop client and compiles it before calling
// SecCodeCheckValidity.  In the actual Ventura binary, the decision is at
// CoreLocationAgent+0x7234..0x727c: verified is written only when both the
// requirement compilation and the subsequent live-code validation succeed.
//
// The iPadOS 16 Security implementation behind the shared-cache symbol does
// not implement macOS's text compiler. Runtime LLDB evidence for Maps:
//
//   SecRequirementCreateWithString("identifier \"com.apple.Maps\"") = -50
//   SecRequirementCreateWithData(the equivalent requirement blob)     = 0
//   SecCodeCheckValidity(live Maps, that requirement)                  = 0
//
// Restore that missing compiler operation for the single requirement form
// emitted by MacWS's ldid signing contract. This creates a real
// SecRequirement; CoreLocationAgent still performs the original
// SecCodeCheckValidity and remains solely responsible for setting verified.
void macws_requirement_put_be32(uint8_t *where, uint32_t value) {
    value = CFSwapInt32HostToBig(value);
    memcpy(where, &value, sizeof(value));
}

OSStatus macws_SecRequirementCreateWithString(
    CFStringRef text,
    SecCSFlags flags,
    SecRequirementRef *requirement) {
    OSStatus status = SecRequirementCreateWithString(text, flags, requirement);
    const char *program = getprogname();
    if (macws_runtime_diagnostics_enabled()) {
        char diagnosticExpression[1024] = {0};
        if (text) {
            (void)CFStringGetCString(text, diagnosticExpression,
                                     sizeof(diagnosticExpression),
                                     kCFStringEncodingUTF8);
        }
        fprintf(stderr,
                "#### MACWS SECURITY requirement text entry program=%s "
                "status=%d output=%p expression=%s\n",
                program ?: "(null)", (int)status,
                requirement ? (void *)*requirement : NULL,
                diagnosticExpression[0] ? diagnosticExpression : "(unavailable)");
    }
    if (status != -50 || !text || !requirement || *requirement != NULL ||
        !program || strcmp(program, "CoreLocationAgent") != 0) {
        return status;
    }

    char expression[1024];
    if (!CFStringGetCString(text, expression, sizeof(expression),
                            kCFStringEncodingUTF8)) {
        return status;
    }

    static const char prefix[] = "identifier \"";
    size_t expressionLength = strlen(expression);
    size_t prefixLength = sizeof(prefix) - 1;
    if (expressionLength <= prefixLength + 1 ||
        memcmp(expression, prefix, prefixLength) != 0 ||
        expression[expressionLength - 1] != '"') {
        return status;
    }

    size_t identifierLength = expressionLength - prefixLength - 1;
    const char *identifier = expression + prefixLength;
    for (size_t i = 0; i < identifierLength; i++) {
        unsigned char c = (unsigned char)identifier[i];
        bool allowed = (c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '-' || c == '_';
        if (!allowed) return status;
    }

    size_t paddedIdentifierLength = (identifierLength + 3u) & ~3u;
    size_t blobLength = 20u + paddedIdentifierLength;
    if (identifierLength > UINT32_MAX || blobLength > UINT32_MAX) {
        return status;
    }

    uint8_t *blob = calloc(1, blobLength);
    if (!blob) return status;
    // CSMAGIC_REQUIREMENT, length, kSecRequirementKindExplicit,
    // requirement-language opIdent, then the length-prefixed identifier.
    macws_requirement_put_be32(blob + 0, 0xfade0c00u);
    macws_requirement_put_be32(blob + 4, (uint32_t)blobLength);
    macws_requirement_put_be32(blob + 8, 1u);
    macws_requirement_put_be32(blob + 12, 2u);
    macws_requirement_put_be32(blob + 16, (uint32_t)identifierLength);
    memcpy(blob + 20, identifier, identifierLength);

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, blob,
                                  (CFIndex)blobLength);
    free(blob);
    if (!data) return status;
    OSStatus compiledStatus = SecRequirementCreateWithData(
        data, flags, requirement);
    CFRelease(data);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS SECURITY requirement text fallback id=%.*s "
                "status=%d\n",
                (int)identifierLength, identifier, (int)compiledStatus);
    }
    return compiledStatus;
}

// CoreLocationAgent's Ventura arm64e executable uses an authenticated chained
// bind in __DATA_CONST,__auth_got for SecRequirementCreateWithString. Runtime
// diagnostics show that dyld applies libmachook's static interpose to an
// ordinary arm64e probe with the same bind shape, but not to this prebuilt
// Apple executable: the call at CoreLocationAgent+0x7234 reaches Security
// directly and the interposer's entry witness never fires.
//
// iPadOS 16 dyld also does not export _dyld_dynamic_interpose. Rebind only the
// Agent slot whose PAC-stripped runtime target is symbolicated as Security's
// SecRequirementCreateWithString. dyld_info confirms these chained entries use
// key=IA, addrDiv=1, diversity=0, so sign the replacement with that exact
// contract. The Agent's subsequent SecStaticCodeCheckValidity call remains
// untouched and solely determines whether verified becomes true.
__attribute__((constructor))
void macws_install_corelocation_requirement_interpose(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "CoreLocationAgent") != 0) return;

    const struct mach_header *agentHeader = NULL;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName ||
            !strstr(imageName,
                    "/CoreLocationAgent.app/Contents/MacOS/CoreLocationAgent")) {
            continue;
        }
        agentHeader = _dyld_get_image_header(index);
        break;
    }
    if (!agentHeader) return;

    unsigned long authGotSize = 0;
    uint64_t *authGot = (uint64_t *)getsectiondata(
        (const struct mach_header_64 *)agentHeader,
        "__DATA_CONST", "__auth_got", &authGotSize);
    uint64_t *candidate = NULL;
    size_t candidateCount = 0;
    for (size_t index = 0;
         authGot && index < authGotSize / sizeof(*authGot); index++) {
        uintptr_t currentTarget = (uintptr_t)ptrauth_strip(
            (void *)authGot[index], ptrauth_key_function_pointer);
        Dl_info targetInfo = {0};
        bool hasTargetInfo = currentTarget &&
            dladdr((void *)currentTarget, &targetInfo);
        // RE-confirmed via `dyld_info -arch arm64e -fixups`: in Ventura
        // 13.4's CoreLocationAgent the section is 0x410 bytes and the
        // SecRequirementCreateWithString bind is __auth_got+0xe0. Keep this
        // exact offset only as a symbolication fallback for the stripped
        // shared-cache Security image, and still require dladdr to identify
        // Security.framework before touching the slot.
        bool exactVenturaSlot = authGotSize == 0x410 &&
            index == 0xe0 / sizeof(*authGot);
        if (macws_runtime_diagnostics_enabled() && exactVenturaSlot) {
            fprintf(stderr,
                    "#### MACWS SECURITY expected auth GOT slot=%p "
                    "target=%p image=%s symbol=%s\n",
                    &authGot[index], (void *)currentTarget,
                    hasTargetInfo && targetInfo.dli_fname
                        ? targetInfo.dli_fname : "(unknown)",
                    hasTargetInfo && targetInfo.dli_sname
                        ? targetInfo.dli_sname : "(unknown)");
        }
        if (!currentTarget ||
            !hasTargetInfo || !targetInfo.dli_fname ||
            !strstr(targetInfo.dli_fname, "/Security.framework/") ||
            (!exactVenturaSlot &&
             (!targetInfo.dli_sname ||
              (strcmp(targetInfo.dli_sname,
                      "SecRequirementCreateWithString") != 0 &&
               strcmp(targetInfo.dli_sname,
                      "_SecRequirementCreateWithString") != 0)))) {
            continue;
        }
        candidate = &authGot[index];
        candidateCount++;
    }

    size_t patched = 0;
    uintptr_t replacementTarget = (uintptr_t)ptrauth_strip(
        (void *)macws_SecRequirementCreateWithString,
        ptrauth_key_function_pointer);
    if (candidateCount == 1 && candidate) {
        uint64_t modifier = (uint64_t)candidate & 0x0000FFFFFFFFFFFFull;
        uint64_t signedReplacement = macws_pac_sign(
            replacementTarget, modifier, 0);
        ModifyExecutableRegion(candidate, sizeof(*candidate), ^{
            *candidate = signedReplacement;
        });
        if ((uintptr_t)ptrauth_strip(
                (void *)*candidate, ptrauth_key_function_pointer) ==
            replacementTarget) {
            patched = 1;
        }
    }
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
                "#### MACWS SECURITY authenticated GOT interpose "
                "agent=%p slots=%lu candidates=%zu replacement=%p "
                "patched=%zu\n",
                agentHeader, authGotSize / sizeof(*authGot), candidateCount,
                (void *)replacementTarget, patched);
    }
}

// Ventura Dock opens an application tile with LSOpenFromURLSpec on a worker
// queue.  In this chroot, LaunchServices can resolve the real bundle URL but
// its final RunningBoard request belongs to iPadOS and cannot describe a
// macOS executable.  Runtime evidence from the installed Dock 2207.3 is
// exact: Dock+0x8aadc calls LSOpenFromURLSpec with appURL=NULL, one .app item
// URL and flags 0x45; the function returns -10810.  The independent `/usr/bin
// /open -a Finder` witness reaches the same boundary and reports
// RBSAssertionErrorDomain Code=2 (missing domain-plist attribute).
//
// Preserve LaunchServices as the first owner.  Only its exact failed
// application-bundle transaction is handed to macwshostd, which already owns
// the validated chroot spawn/reopen/readiness lifecycle used by Control
// Center.  Documents, folders, successful LS requests and multi-item opens
// never enter this adapter.

extern OSStatus LSOpenFromURLSpec(const MacWSLSLaunchURLSpec *launchSpec,
                                  CFURLRef *outLaunchedURL);
extern xpc_connection_t macws_xpc_connection_create_mach_service_raw(
    const char *, dispatch_queue_t, uint64_t)
    __asm("_xpc_connection_create_mach_service");

CFURLRef macws_failed_application_url(
        const MacWSLSLaunchURLSpec *launchSpec) {
    if (!launchSpec) return NULL;
    CFURLRef candidate = NULL;
    if (launchSpec->appURL &&
        (!launchSpec->itemURLs ||
         CFArrayGetCount(launchSpec->itemURLs) == 0)) {
        candidate = launchSpec->appURL;
    } else if (!launchSpec->appURL && launchSpec->itemURLs &&
               CFGetTypeID(launchSpec->itemURLs) == CFArrayGetTypeID() &&
               CFArrayGetCount(launchSpec->itemURLs) == 1) {
        CFTypeRef item = CFArrayGetValueAtIndex(launchSpec->itemURLs, 0);
        if (item && CFGetTypeID(item) == CFURLGetTypeID())
            candidate = (CFURLRef)item;
    }
    if (!candidate || CFGetTypeID(candidate) != CFURLGetTypeID()) return NULL;

    // Runtime-confirmed in Ventura Dock 2207.3 on 2026-08-06: evaluating
    // `-[NSString caseInsensitiveCompare:]` against an Objective-C constant
    // from this arm64e interposer faults in CFStringGetLength with a pointer-
    // authentication failure immediately after the real LSOpenFromURLSpec
    // returns -10810.  This boundary only needs a POSIX bundle suffix, so keep
    // it in CoreFoundation/C storage and do an exact ASCII comparison.  It
    // also avoids turning URL parsing into another cross-image ObjC dispatch.
    UInt8 pathBytes[PATH_MAX] = {0};
    if (!CFURLGetFileSystemRepresentation(candidate, true, pathBytes,
                                           sizeof(pathBytes))) return NULL;
    size_t pathLength = strlen((const char *)pathBytes);
    if (pathLength < 4) return NULL;
    const char *suffix = (const char *)pathBytes + pathLength - 4;
    BOOL application = suffix[0] == '.' &&
        (suffix[1] == 'a' || suffix[1] == 'A') &&
        (suffix[2] == 'p' || suffix[2] == 'P') &&
        (suffix[3] == 'p' || suffix[3] == 'P');
    return application ? candidate : NULL;
}

BOOL macws_launch_application_path_via_host(CFURLRef applicationURL) {
    if (!applicationURL) return NO;
    UInt8 pathStorage[PATH_MAX] = {0};
    if (!CFURLGetFileSystemRepresentation(applicationURL, true, pathStorage,
                                           sizeof(pathStorage))) return NO;
    const char *pathBytes = (const char *)pathStorage;
    BOOL launched = NO;
    xpc_connection_t connection =
        macws_xpc_connection_create_mach_service_raw(
        MACWS_CONTROL_SERVICE,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (connection && pathBytes && pathBytes[0] == '/') {
        xpc_connection_set_event_handler(connection,
            ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(connection);
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP,
                                  MACWS_CONTROL_OP_LAUNCH_PATH);
        xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_APP_PATH,
                                  pathBytes);
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
            connection, request);
        launched = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
            xpc_dictionary_get_bool(reply, "ok");
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                    "#### MACWS LS-APP-FALLBACK path=%s launched=%s "
                    "reply=%s\n",
                    pathBytes, launched ? "YES" : "NO",
                    reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
                        ? (xpc_dictionary_get_string(reply, "message") ?: "")
                        : "invalid");
        }
        if (reply) xpc_release(reply);
        xpc_release(request);
        xpc_connection_cancel(connection);
    }
    if (connection) xpc_release(connection);
    return launched;
}

OSStatus macws_LSOpenFromURLSpec(
        const MacWSLSLaunchURLSpec *launchSpec,
        CFURLRef *outLaunchedURL) {
    OSStatus status = LSOpenFromURLSpec(launchSpec, outLaunchedURL);
    // -10810 is the exact kLSUnknownErr returned after LaunchServices has
    // resolved the application but its foreign-platform RBS launch failed.
    // Do not turn unrelated LS failures into success.
    if (status != -10810) return status;
    CFURLRef applicationURL = macws_failed_application_url(launchSpec);
    if (!applicationURL ||
        !macws_launch_application_path_via_host(applicationURL)) return status;
    if (outLaunchedURL && !*outLaunchedURL)
        *outLaunchedURL = (CFURLRef)CFRetain(applicationURL);
    return noErr;
}

DYLD_INTERPOSE(sysctlbyname_new, sysctlbyname);
DYLD_INTERPOSE(LMGetBootDrive_new, LMGetBootDrive);
DYLD_INTERPOSE(macws_CFURLCopyResourcePropertyValuesAndFlags,
               _CFURLCopyResourcePropertyValuesAndFlags);
DYLD_INTERPOSE(macws_SecRequirementCreateWithString,
               SecRequirementCreateWithString);
DYLD_INTERPOSE(macws_LSOpenFromURLSpec, LSOpenFromURLSpec);
DYLD_INTERPOSE(__mac_syscall_new, __mac_syscall);
DYLD_INTERPOSE(csr_get_active_config_new, csr_get_active_config);
DYLD_INTERPOSE(sandbox_init_with_parameters_new, sandbox_init_with_parameters);
DYLD_INTERPOSE(sandbox_init_new, sandbox_init);
DYLD_INTERPOSE(mach_port_construct_new, mach_port_construct);
DYLD_INTERPOSE(mach_msg_new, mach_msg);
DYLD_INTERPOSE(macws_dispatch_mig_server, dispatch_mig_server);
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
    if (!getenv("MACWS_AGX_REGISTER_CLASSES") ||
        !macws_runtime_diagnostics_enabled()) return r;
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
const char *macws_settings_extension_bootstrap_name(
    const char *name) {
    if (!name) return name;
    const char *program = getprogname();
    const char *appExtension = getenv("MACWS_APP_EXTENSION");
    BOOL isSettingsHost = program && !strcmp(program, "System Settings");
    BOOL isSettingsExtension = appExtension && !strcmp(appExtension, "1");
    if (!isSettingsHost && !isSettingsExtension) return name;

    static const char extensionKitSuffix[] = ".extensionkit.internal";
    static const char viewBridgeSuffix[] = ".viewbridge";
    const char *suffix = NULL;
    size_t nameLength = strlen(name);
    size_t suffixLength = sizeof(extensionKitSuffix) - 1;
    if (nameLength > suffixLength &&
        !strcmp(name + nameLength - suffixLength, extensionKitSuffix)) {
        suffix = extensionKitSuffix;
    } else {
        suffixLength = sizeof(viewBridgeSuffix) - 1;
        if (nameLength > suffixLength &&
            !strcmp(name + nameLength - suffixLength, viewBridgeSuffix))
            suffix = viewBridgeSuffix;
    }
    if (!suffix) return name;

    size_t identifierLength = nameLength - suffixLength;
    if (identifierLength <= strlen("com.apple.") ||
        strncmp(name, "com.apple.", strlen("com.apple.")) != 0)
        return name;
    for (size_t index = 0; index < identifierLength; index++) {
        char character = name[index];
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              character == '.' || character == '-')) return name;
    }
    static __thread char rewritten[512];
    int length = snprintf(
        rewritten, sizeof(rewritten),
        "com.macwsguide.settings-extension-carrier.%.*s%s",
        (int)identifierLength, name, suffix);
    return length > 0 && (size_t)length < sizeof(rewritten)
        ? rewritten : name;
}

const char *macws_private_bootstrap_lsd_service_name(const char *name) {
    if (!name) return name;
    static const char lsdPrefix[] = "com.apple.lsd.";
    bool isLsdService = !strncmp(name, lsdPrefix, sizeof(lsdPrefix) - 1);
    bool isTranslocation = !strcmp(name, "com.apple.security.translocation");
    if (!isLsdService && !isTranslocation) return name;

    const char *role = getenv("MACWS_LSD_ROLE");
    bool systemFamily = role && !strcmp(role, "system");
    const char *suffix = isLsdService
        ? name + sizeof(lsdPrefix) - 1 : "security.translocation";
    if (role && !strcmp(role, "session") &&
        (!strcmp(suffix, "dissemination") || !strcmp(suffix, "encryption")))
        systemFamily = true;
    if (isTranslocation && !systemFamily)
        return "com.apple.macosbooter.security.translocation";

    static _Thread_local char rewritten[192];
    int length = snprintf(rewritten, sizeof(rewritten),
                          systemFamily
                              ? "com.apple.macosbooter.lsd.system.%s"
                              : "com.apple.macosbooter.lsd.%s",
                          suffix);
    return length > 0 && (size_t)length < sizeof(rewritten)
        ? rewritten : name;
}

const char *macws_private_bootstrap_service_name(const char *name) {
    if (!name) return name;
    // The settings-extension launch proxy is the first iOS image submitted to
    // RunningBoard, so launchd allocates its managed endpoints under the proxy
    // unique bundle identifier. Ventura derives each peer name from the real
    // pane's LSApplicationExtensionRecord. Runtime `launchctl procinfo` showed
    // the corresponding carrier endpoint pair; map names only, preserving the
    // original managed ports and ExtensionKit/ViewBridge wire protocols.
    const char *settingsEndpoint =
        macws_settings_extension_bootstrap_name(name);
    if (settingsEndpoint != name) return settingsEndpoint;
    if (!strcmp(name, CARENDER_ORIG))
        return CARENDER_NEW;
    // Keep the static-interpose route complete.  Most clients also pass
    // through Metal_hooks.x's libxpc hooks, but hosted ExtensionKit processes
    // deliberately cannot dirty libxpc text after their sandbox is installed.
    // Runtime-confirmed by appearance-debug-marker-oslog.txt (2026-08-04):
    // Appearance issued 243 lookups for com.apple.lsd.modifydb which the
    // extension sandbox rejected with error 159, followed by
    // +[LSBundleRecord bundleRecordForCurrentProcess] returning nil.  These
    // names are the exact MachServices published by MacWS's Ventura daemons;
    // rewriting at dyld's bootstrap/xpc interpose boundary keeps the stock LS,
    // preferences, IconServices and SystemStatus protocols intact.
    if (!strcmp(name, "com.apple.systemstatus"))
        return "com.apple.macosbooter.systemstatus";
    if (!strcmp(name, "com.apple.systemstatus.publisher"))
        return "com.apple.macosbooter.systemstatus.publisher";
    if (!strcmp(name, "com.apple.systemstatus.activityattribution"))
        return "com.apple.macosbooter.systemstatus.activityattribution";
    if (!strcmp(name, "com.apple.coreservices.launchservicesd"))
        return "com.apple.macosbooter.coreservices.launchservicesd";
    if (!strcmp(name, "com.apple.cfprefsd.daemon"))
        return "com.apple.macosbooter.cfprefsd.daemon";
    if (!strcmp(name, "com.apple.cfprefsd.agent"))
        return "com.apple.macosbooter.cfprefsd.agent";
    if (!strcmp(name, "com.apple.iconservices"))
        return "com.apple.macosbooter.iconservices";
    if (!strcmp(name, "com.apple.iconservices.store"))
        return "com.apple.macosbooter.iconservices.store";
    if (!strcmp(name, "com.apple.carboncore.csnameddata"))
        return "com.apple.macosbooter.carboncore.csnameddata";
    if (!strcmp(name, DOCK_HELPER_SERVICE_ORIG))
        return DOCK_HELPER_SERVICE_NEW;
    const char *lsdEndpoint = macws_private_bootstrap_lsd_service_name(name);
    if (lsdEndpoint != name) return lsdEndpoint;
    // Ventura's four desktop CoreLocation endpoints are a different protocol
    // surface from iPadOS 16's similarly named services.  Runtime logs on the
    // target first showed `getLocationServicesCapableWithReplyBlock:` rejected
    // by the iOS synchronous NSXPC interface.  A subsequent run of Ventura's
    // real locationd reached CLLocationController only after its uid-205
    // cache tree existed, but then exited cleanly because this interposer also
    // rewrote the daemon's own desktop check-ins to the already-owned iOS
    // names.  Give all four desktop endpoints collision-free names and apply
    // the mapping symmetrically to the stock daemon and its stock clients.
    if (!strcmp(name, LOCATIOND_DESKTOP_AGENT_ORIG))
        return LOCATIOND_DESKTOP_AGENT_NEW;
    if (!strcmp(name, LOCATIOND_DESKTOP_REGISTRATION_ORIG))
        return LOCATIOND_DESKTOP_REGISTRATION_NEW;
    if (!strcmp(name, LOCATIOND_DESKTOP_SPI_ORIG))
        return LOCATIOND_DESKTOP_SPI_NEW;
    if (!strcmp(name, LOCATIOND_DESKTOP_SYNCHRONOUS_ORIG))
        return LOCATIOND_DESKTOP_SYNCHRONOUS_NEW;
    // Ventura's simulation controller is the stock, typed ingestion point for
    // CLLocation objects.  Keep it separate from iPadOS locationd's endpoint
    // so the native MacWS provider can feed the real iPad location into the
    // Ventura provider graph without replacing CLLocationManager results.
    if (!strcmp(name, LOCATIOND_SIMULATION_ORIG))
        return LOCATIOND_SIMULATION_NEW;
    // GeoServices wire formats are release-specific.  Runtime-confirmed on
    // iPadOS 16.3: Ventura Maps reached iOS geod but received GEOErrorDomain
    // Code=-10 ("No resources in request") and rendered only the empty tile
    // grid.  Route both the stock Ventura listener and its clients to a
    // collision-free endpoint; payloads still terminate in Ventura's real
    // com.apple.geod executable.
    if (!strcmp(name, GEOD_XPC_SERVICE))
        return GEOD_XPC_SERVICE_NEW;
    // FrontBoard's BSServiceConnection resolves its domain endpoint with raw
    // bootstrap_look_up rather than xpc_connection_create_mach_service.
    // Keep this mapping identical to macws_private_chroot_service_name() so
    // Maps reaches Ventura UIKitSystem instead of iPadOS SpringBoard regardless
    // of which public transport wrapper the framework selects.
    if (!strcmp(name, FRONTBOARD_SYSTEM_ORIG))
        return FRONTBOARD_SYSTEM_NEW;
    if (!strcmp(name, VIEWBRIDGE_AUXILIARY_ORIG))
        return VIEWBRIDGE_AUXILIARY_NEW;
    if (!strcmp(name, EXTENSIONKIT_SERVICE_ORIG))
        return EXTENSIONKIT_SERVICE_NEW;
    if (!strcmp(name, HISERVICES_SERVICE_ORIG))
        return HISERVICES_SERVICE_NEW;
    return name;
}

// Ventura cfprefsd selects its daemon/agent role from the launchd session when
// initWithRole: receives the automatic role (0).  RE-confirmed in the target
// CoreFoundation:
//   initWithRole:testMode: +0x080..+0x0f4 calls vproc_swap_string key 6,
//   compares the result with "System", then stores role 2 for System or role 1
//   for a login/background session.  iOS has no per-user launchd domains at
//   all (`launchctl help` states this explicitly), so the private agent job is
//   unavoidably classified as a second daemon and never executes checkIn.
//
// Preserve the stock role-selection code and translate only the missing
// launchd-session value for our dedicated private cfprefsd `agent` invocation.
// The original vproc call, errors, all other keys/processes, and daemon
// launches remain authoritative. strdup keeps the documented caller-owned
// result contract after releasing the original vproc string.
extern void *vproc_swap_string(void *vproc, int key,
                               const char *input, char **output);
bool macws_is_private_cfprefsd_agent(void) {
    const char *program = getprogname();
    int *argc_pointer = _NSGetArgc();
    char ***argv_pointer = _NSGetArgv();
    return program && strcmp(program, "macws-cfprefsd") == 0 &&
        argc_pointer && *argc_pointer >= 2 && argv_pointer && *argv_pointer &&
        (*argv_pointer)[1] && strcmp((*argv_pointer)[1], "agent") == 0;
}

void *vproc_swap_string_new(void *vproc, int key,
                                   const char *input, char **output) {
    void *error = vproc_swap_string(vproc, key, input, output);
    if (!error && key == 6 && input == NULL && output && *output &&
        strcmp(*output, "System") == 0 &&
        macws_is_private_cfprefsd_agent()) {
        char *background = strdup("Background");
        if (background) {
            free(*output);
            *output = background;
        }
    }
    return error;
}

// A normal macOS system bootstrap and login bootstrap never share
// _CS_DARWIN_USER_DIR: root lsd owns the system store while the login lsd owns
// a per-user store. MacWS has to submit both jobs to one outer launchd domain
// and currently runs GUI clients as uid 0, so uid alone would make both lsd
// roles clean/recover the same csstore concurrently. Preserve the stock
// confstr contract, but give only the explicitly tagged session lsd the
// dedicated user directory prepared by macos_gui.sh. All other confstr keys,
// processes, errors and buffer-size semantics remain native.
size_t macws_confstr_new(int name, char *buffer, size_t length) {
    const char *role = getenv("MACWS_LSD_ROLE");
    const char *sessionDirectory = getenv("MACWS_LSD_SESSION_USER_DIR");
    if (name == _CS_DARWIN_USER_DIR && role && sessionDirectory &&
        !strcmp(role, "session") && sessionDirectory[0] == '/') {
        size_t required = strlen(sessionDirectory) + 1;
        if (buffer && length > 0) strlcpy(buffer, sessionDirectory, length);
        return required;
    }
    return confstr(name, buffer, length);
}

id (*macws_lsd_database_store_url_orig)(id, SEL) = NULL;
id (*macws_lsd_database_store_url_uid_orig)(id, SEL, uid_t) = NULL;

id macws_lsd_relocated_store_url(id originalURL) {
    const char *directory = getenv("MACWS_LSD_SESSION_USER_DIR");
    if (!originalURL || !directory || directory[0] != '/') return originalURL;
    NSString *directoryPath = [NSString stringWithUTF8String:directory];
    NSString *filename = [originalURL lastPathComponent];
    if (!directoryPath || !filename) return originalURL;
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath
                                     isDirectory:YES];
    return [directoryURL URLByAppendingPathComponent:filename
                                         isDirectory:NO];
}

id macws_lsd_database_store_url(id self, SEL command) {
    id originalURL = macws_lsd_database_store_url_orig
        ? macws_lsd_database_store_url_orig(self, command) : nil;
    return macws_lsd_relocated_store_url(originalURL);
}

id macws_lsd_database_store_url_uid(id self, SEL command, uid_t uid) {
    id originalURL = macws_lsd_database_store_url_uid_orig
        ? macws_lsd_database_store_url_uid_orig(self, command, uid) : nil;
    return macws_lsd_relocated_store_url(originalURL);
}

void macws_install_lsd_session_store_isolation(void) {
    const char *role = getenv("MACWS_LSD_ROLE");
    const char *directory = getenv("MACWS_LSD_SESSION_USER_DIR");
    if (!role || strcmp(role, "session") != 0 || !directory ||
        directory[0] != '/') return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class defaultsClass = objc_getClass("_LSDefaults");
        if (!defaultsClass) return;
        SEL selector = sel_registerName("databaseStoreFileURL");
        Method method = class_getInstanceMethod(defaultsClass, selector);
        if (method) {
            MSHookMessageEx(defaultsClass, selector,
                            (IMP)macws_lsd_database_store_url,
                            (IMP *)&macws_lsd_database_store_url_orig);
        }
        selector = sel_registerName("databaseStoreFileURLWithUID:");
        method = class_getInstanceMethod(defaultsClass, selector);
        if (method) {
            MSHookMessageEx(defaultsClass, selector,
                            (IMP)macws_lsd_database_store_url_uid,
                            (IMP *)&macws_lsd_database_store_url_uid_orig);
        }
    });
}
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_look_up2(mach_port_t bp, const char *name,
                                        mach_port_t *sp, pid_t target_pid,
                                        uint64_t flags);
extern kern_return_t bootstrap_look_up3(mach_port_t bp, const char *name,
                                        mach_port_t *sp, pid_t target_pid,
                                        const unsigned char instance[16],
                                        uint64_t flags);
extern kern_return_t bootstrap_check_in2(mach_port_t bp, const char *name,
                                         mach_port_t *sp, uint64_t flags);
extern kern_return_t bootstrap_check_in3(mach_port_t bp, const char *name,
                                         mach_port_t *sp,
                                         unsigned char instance[16],
                                         uint64_t flags);

// Bounded, allocation-free cold-start service recorder.  Using fprintf from
// the static XPC interpose is not safe this early: the stdio path can re-enter
// framework initialization before Maps reaches NSApplicationMain.  This
// diagnostic writes at most 512 short records directly to the inherited log
// descriptor and never changes the requested service or its result.
void macws_trace_xpc_name(const char *transport, const char *name) {
    if (!name || !getenv("MACWS_XPC_NAME_TRACE")) return;
    static _Thread_local bool tracing = false;
    static _Atomic unsigned int recordCount = 0;
    if (tracing) return;
    unsigned int record = atomic_fetch_add_explicit(
        &recordCount, 1, memory_order_relaxed);
    if (record >= 512) return;

    tracing = true;
    char line[768];
    size_t used = 0;
    static const char prefix[] = "#### XPC-NAME ";
    size_t prefixLength = sizeof(prefix) - 1;
    memcpy(line + used, prefix, prefixLength);
    used += prefixLength;
    size_t transportLength = strnlen(transport ?: "unknown", 64);
    memcpy(line + used, transport ?: "unknown", transportLength);
    used += transportLength;
    line[used++] = ' ';
    line[used++] = '\'';
    size_t nameLength = strnlen(name, sizeof(line) - used - 3);
    memcpy(line + used, name, nameLength);
    used += nameLength;
    line[used++] = '\'';
    line[used++] = '\n';
    (void)write(STDERR_FILENO, line, used);
    tracing = false;
}

kern_return_t bootstrap_look_up_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("bootstrap_look_up", originalName);
    if (name != originalName)
        macws_trace_xpc_name("bootstrap_look_up.mapped", name);
    kern_return_t result = bootstrap_look_up(bp, name, sp);
    if (getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr,
                "#### BOOTSTRAP look_up '%s'%s%s%s -> %#x port=%#x\n",
                originalName ?: "(null)", name != originalName ? " -> '" : "",
                name != originalName ? name : "", name != originalName ? "'" : "",
                result, sp ? *sp : MACH_PORT_NULL);
    }
    return result;
}
kern_return_t bootstrap_look_up2_new(mach_port_t bp, const char *name,
                                      mach_port_t *sp, pid_t target_pid,
                                      uint64_t flags) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("bootstrap_look_up2", originalName);
    if (name != originalName)
        macws_trace_xpc_name("bootstrap_look_up2.mapped", name);
    kern_return_t result = bootstrap_look_up2(
        bp, name, sp, target_pid, flags);
    if (getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr,
                "#### BOOTSTRAP look_up2 '%s'%s%s%s -> %#x port=%#x\n",
                originalName ?: "(null)", name != originalName ? " -> '" : "",
                name != originalName ? name : "", name != originalName ? "'" : "",
                result, sp ? *sp : MACH_PORT_NULL);
    }
    return result;
}
kern_return_t bootstrap_look_up3_new(mach_port_t bp, const char *name,
                                      mach_port_t *sp, pid_t target_pid,
                                      const unsigned char instance[16],
                                      uint64_t flags) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("bootstrap_look_up3", originalName);
    if (name != originalName)
        macws_trace_xpc_name("bootstrap_look_up3.mapped", name);
    kern_return_t result = bootstrap_look_up3(
        bp, name, sp, target_pid, instance, flags);
    if (getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr,
                "#### BOOTSTRAP look_up3 '%s'%s%s%s -> %#x port=%#x\n",
                originalName ?: "(null)", name != originalName ? " -> '" : "",
                name != originalName ? name : "", name != originalName ? "'" : "",
                result, sp ? *sp : MACH_PORT_NULL);
    }
    return result;
}
kern_return_t bootstrap_check_in_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("bootstrap_check_in", originalName);
    if (name != originalName)
        macws_trace_xpc_name("bootstrap_check_in.mapped", name);
    kern_return_t result = bootstrap_check_in(bp, name, sp);
    if (getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr,
                "#### BOOTSTRAP check_in '%s'%s%s%s -> %#x port=%#x\n",
                originalName ?: "(null)", name != originalName ? " -> '" : "",
                name != originalName ? name : "", name != originalName ? "'" : "",
                result, sp ? *sp : MACH_PORT_NULL);
    }
    return result;
}
kern_return_t bootstrap_check_in2_new(mach_port_t bp, const char *name,
                                       mach_port_t *sp, uint64_t flags) {
    name = macws_private_bootstrap_service_name(name);
    return bootstrap_check_in2(bp, name, sp, flags);
}
kern_return_t bootstrap_check_in3_new(mach_port_t bp, const char *name,
                                       mach_port_t *sp,
                                       unsigned char instance[16],
                                       uint64_t flags) {
    name = macws_private_bootstrap_service_name(name);
    return bootstrap_check_in3(bp, name, sp, instance, flags);
}

// UIKit/FrontBoard initializes its BSService endpoint from framework
// initializers that may run before libmachook's constructors.  Static dyld
// interposition is active while dependency initializers run, so route this one
// colliding service at the earliest transport boundary.  All other XPC names,
// connection flags, queues, handlers, and messages are passed through.
extern xpc_connection_t macws_xpc_connection_create_mach_service_raw(
    const char *, dispatch_queue_t, uint64_t)
    __asm("_xpc_connection_create_mach_service");
xpc_connection_t macws_xpc_connection_create_mach_service_early(
    const char *name, dispatch_queue_t targetq, uint64_t flags) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("xpc_mach_service", originalName);
    if (name != originalName)
        macws_trace_xpc_name("xpc_mach_service.mapped", name);
    return macws_xpc_connection_create_mach_service_raw(
        name, targetq, flags);
}

// GeoServices does not create its daemon listener through xpc_main or
// xpc_connection_create_mach_service.  RE-confirmed against Ventura 13.4's
// GeoServices (UUID represented by the installed shared cache):
//
//   -[GEODaemon initPrimaryDaemon] +0x34
//       -> -[GEODaemon initWithPort:createXPCListenerBlock:]
//   __30-[GEODaemon initPrimaryDaemon]_block_invoke +0x10
//       -> xpc_connection_create_listener("com.apple.geod", targetq)
//
// The public name is already owned by iPadOS geod, while MacWS publishes the
// unmodified Ventura protocol on GEOD_XPC_SERVICE_NEW.  Apply the same
// collision-free name translation used by every other bootstrap/XPC entry
// point; listener queue, handler, activation and all request/reply objects stay
// under stock GEODaemon control.
// RE-confirmed on the actual iPadOS 16.3.1 libxpc image at
// xpc_connection_create_listener+0x10: `mov x2, x1; mov x1, x0; mov w0, #0`
// before entering the common constructor. The private ABI has two arguments.
// The former one-argument declaration let tracing calls clobber x1 and crashed
// in _dispatch_mach_create at address 0x15a on every geod activation.
extern xpc_connection_t macws_xpc_connection_create_listener_raw(
    const char *, dispatch_queue_t)
    __asm("_xpc_connection_create_listener");
xpc_connection_t macws_xpc_connection_create_listener_early(
    const char *name, dispatch_queue_t targetq) {
    const char *originalName = name;
    name = macws_private_bootstrap_service_name(name);
    macws_trace_xpc_name("xpc_listener", originalName);
    if (name != originalName)
        macws_trace_xpc_name("xpc_listener.mapped", name);
    return macws_xpc_connection_create_listener_raw(name, targetq);
}

xpc_connection_t macws_xpc_connection_create_early(
    const char *name, dispatch_queue_t targetq) {
    macws_trace_xpc_name("xpc_service", name);
    if (name && !strcmp(name, FRONTBOARD_SYSTEM_ORIG)) {
        return macws_xpc_connection_create_mach_service_raw(
            FRONTBOARD_SYSTEM_NEW, targetq, 0);
    }
    // Ventura normally runs ViewBridgeAuxiliary as a per-user XPC service.
    // MacWS cannot launch that service through a setuid chroot proxy:
    // runtime oslog on 2026-08-04 recorded libxpc terminating it with
    // "running setugid(), which is not allowed".  A root launchd job starts
    // the identical proxy without any credential transition and publishes
    // this private Mach endpoint.  Preserve the ViewBridge wire protocol and
    // change only how the endpoint is resolved.
    if (name && !strcmp(name, VIEWBRIDGE_AUXILIARY_ORIG)) {
        return macws_xpc_connection_create_mach_service_raw(
            VIEWBRIDGE_AUXILIARY_NEW, targetq, 0);
    }
    // ExtensionFoundation normally activates extensionkitservice by its XPC
    // bundle identifier.  Runtime routing evidence on 2026-08-04 showed that
    // this unqualified request reached the already-running iPadOS service and
    // returned zero identities even though Ventura LaunchServices could
    // resolve Appearance's platform-1 record by identifier.  Route only this
    // colliding service to the root Ventura listener; query objects and reply
    // payloads remain the stock ExtensionFoundation protocol.
    if (name && !strcmp(name, EXTENSIONKIT_SERVICE_ORIG)) {
        return macws_xpc_connection_create_mach_service_raw(
            EXTENSIONKIT_SERVICE_NEW, targetq, 0);
    }
    // HIServices is shipped as an XPCService, but a freestanding chroot
    // proxy cannot preserve its per-process XPC domain across exec.  Starting
    // that proxy as an ordinary launchd job without adapting xpc_main is also
    // rejected verbatim by libxpc: "An XPC Service cannot be run directly."
    // Route the unchanged HIServices wire protocol to the same root-owned
    // private Mach-listener shape already used for ViewBridge/ExtensionKit.
    if (name && !strcmp(name, HISERVICES_SERVICE_ORIG)) {
        return macws_xpc_connection_create_mach_service_raw(
            HISERVICES_SERVICE_NEW, targetq, 0);
    }
    // CarbonCore resolves its named-data helper with xpc_connection_create,
    // not the Mach-service constructor used by lsd/IconServices. Route this
    // early static-interpose entry point explicitly so Dock cannot cache a
    // failed public XPC-bundle lookup before Metal_hooks installs its broader
    // runtime name mapper.
    if (name && !strcmp(name, "com.apple.carboncore.csnameddata")) {
        return macws_xpc_connection_create_mach_service_raw(
            "com.apple.macosbooter.carboncore.csnameddata", targetq, 0);
    }
    // Dock's DockHelperConnection uses -[NSXPCConnection initWithServiceName:]
    // for the embedded Application-type XPC bundle.  The custom root launchd
    // domain cannot perform bundle activation, so route that one service-name
    // constructor to the stock DockHelper listener published by
    // macos_gui.sh.  RE-confirmed against Ventura Dock 2207.3: the real
    // popupWithMenu:...withReply: call goes through this connection, and the
    // missing reply leaves Dock's MenuGroup non-null so all later mouse events
    // intentionally take the early-exit path.
    if (name && !strcmp(name, DOCK_HELPER_SERVICE_ORIG)) {
        // Preserve XPC bundle activation here. DockHelper is an Application
        // service whose NSXPCListener main-queue contract is established by
        // xpcproxy; treating it as a freestanding Mach service delivers the
        // request but runs menu tracking on a worker after the true main
        // thread has exited. The registered DockHelperProxy performs only the
        // raw chroot+exec transition, so the stock service consumes the
        // launchd-provided XPC context in the original task.
        return xpc_connection_create(DOCK_HELPER_SERVICE_NEW, targetq);
    }
    // Ventura's GeoServices client resolves geod as a per-user XPC service.
    // MacWS publishes the matching Ventura executable as a private launchd
    // Mach service because the public name is already owned by iPadOS geod.
    if (name && !strcmp(name, GEOD_XPC_SERVICE)) {
        return macws_xpc_connection_create_mach_service_raw(
            GEOD_XPC_SERVICE_NEW, targetq, 0);
    }
    return xpc_connection_create(name, targetq);
}

extern void macws_xpc_main_raw(xpc_connection_handler_t handler)
    __asm("_xpc_main") __attribute__((noreturn));

// xpc_main only accepts a process born as an XPCService.  The root ViewBridge
// and ExtensionKit jobs are deliberately launchd Mach services so their
// freestanding proxies can chroot without a setuid transition; runtime oslog
// showed stock xpc_main otherwise exits with XPC_EXIT_REASON_UNMANAGED.  Adapt
// only those two launch contexts to libxpc's supported Mach-listener API and
// pass each connection to the original service handler.  Listener-name
// requests, anonymous sublisteners, replies and protocol delegates remain the
// unmodified Ventura implementations.
void macws_xpc_main(xpc_connection_handler_t handler) {
    const char *program = getprogname();
    const char *service = getenv("XPC_SERVICE_NAME");
    const char *privateMachService = NULL;
    if (program && strcmp(program, "ViewBridgeAuxiliary") == 0 &&
        service && strcmp(service, "com.macwsguide.viewbridge") == 0) {
        privateMachService = VIEWBRIDGE_AUXILIARY_NEW;
    } else if (program && strcmp(program, "extensionkitservice") == 0 &&
               service &&
               strcmp(service, "com.macwsguide.extensionkit") == 0) {
        privateMachService = EXTENSIONKIT_SERVICE_NEW;
    } else if (program &&
               strcmp(program, "com.apple.hiservices-xpcservice") == 0 &&
               service && strcmp(service, "com.macwsguide.hiservices") == 0) {
        privateMachService = HISERVICES_SERVICE_NEW;
    } else if (program && strcmp(program, "csnameddatad") == 0 &&
               service &&
               strcmp(service, "com.macwsguide.csnameddatad") == 0) {
        privateMachService =
            "com.apple.macosbooter.carboncore.csnameddata";
    }
    if (privateMachService && getuid() == 0 && geteuid() == 0) {
        xpc_connection_t listener =
            macws_xpc_connection_create_mach_service_raw(
                privateMachService, dispatch_get_main_queue(),
                XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (listener) {
            xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
                if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                    handler((xpc_connection_t)event);
            });
            xpc_connection_resume(listener);
            dispatch_main();
        }
    }
    macws_xpc_main_raw(handler);
}

__attribute__((constructor))
void macws_install_hiservices_xpc_main_import(void) {
    const char *program = getprogname();
    if (!program ||
        strcmp(program, "com.apple.hiservices-xpcservice") != 0) return;

    const struct mach_header *mainHeader = _dyld_get_image_header(0);
    if (!mainHeader || mainHeader->magic != MH_MAGIC_64) return;
    // Do not hook libxpc or suspend any threads here. Repair only the target
    // executable's symbol-table-identified authenticated import before main
    // reaches its single xpc_main call. This preserves the stock HIServices
    // request handler and wire protocol while changing only the launch-context
    // adapter required by the chroot proxy.
    macws_repair_got_via_symtab(
        (const struct mach_header_64 *)mainHeader,
        _dyld_get_image_vmaddr_slide(0),
        "com.apple.hiservices-xpcservice(main)");
}
DYLD_INTERPOSE(bootstrap_look_up_new, bootstrap_look_up);
DYLD_INTERPOSE(bootstrap_check_in_new, bootstrap_check_in);
DYLD_INTERPOSE(bootstrap_look_up2_new, bootstrap_look_up2);
DYLD_INTERPOSE(bootstrap_look_up3_new, bootstrap_look_up3);
DYLD_INTERPOSE(bootstrap_check_in2_new, bootstrap_check_in2);
DYLD_INTERPOSE(bootstrap_check_in3_new, bootstrap_check_in3);
DYLD_INTERPOSE(macws_xpc_connection_create_mach_service_early,
               macws_xpc_connection_create_mach_service_raw);
DYLD_INTERPOSE(macws_xpc_connection_create_listener_early,
               macws_xpc_connection_create_listener_raw);
DYLD_INTERPOSE(macws_xpc_connection_create_early, xpc_connection_create);
DYLD_INTERPOSE(macws_xpc_main, macws_xpc_main_raw);

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


const MacWSIOSurfacePropertyKeys *macws_iosurface_property_keys(void) {
    static MacWSIOSurfacePropertyKeys keys = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char *const shortNames[] = {
            "Width", "Height", "CompressionType",
            "HeightInCompressedTiles", "WidthInCompressedTiles",
            "BytesPerRow", "BytesPerElement", "ElementWidth",
            "ElementHeight", "Size", "NumberOfComponents",
            "BytesPerTileData", "Offset", "AddressFormat",
        };
        static const char *const fullNames[] = {
            "IOSurfacePlaneWidth", "IOSurfacePlaneHeight",
            "IOSurfacePlaneCompressionType",
            "IOSurfacePlaneHeightInCompressedTiles",
            "IOSurfacePlaneWidthInCompressedTiles",
            "IOSurfacePlaneBytesPerRow", "IOSurfacePlaneBytesPerElement",
            "IOSurfacePlaneElementWidth", "IOSurfacePlaneElementHeight",
            "IOSurfacePlaneSize", "IOSurfacePlaneNumberOfComponents",
            "IOSurfacePlaneBytesPerTileData", "IOSurfacePlaneOffset",
            "IOSurfaceAddressFormat",
        };
        keys.creationProperties = CFStringCreateWithCString(
            kCFAllocatorDefault, "CreationProperties", kCFStringEncodingUTF8);
        keys.planeInfo = CFStringCreateWithCString(
            kCFAllocatorDefault, "IOSurfacePlaneInfo", kCFStringEncodingUTF8);
        keys.componentInfo = CFStringCreateWithCString(
            kCFAllocatorDefault, "ComponentInfo", kCFStringEncodingUTF8);
        keys.fullComponentInfo = CFStringCreateWithCString(
            kCFAllocatorDefault, "IOSurfacePlaneComponentInfo",
            kCFStringEncodingUTF8);
        for (size_t index = 0;
             index < MacWSIOSurfacePlanePropertyCount; index++) {
            keys.shortKeys[index] = CFStringCreateWithCString(
                kCFAllocatorDefault, shortNames[index],
                kCFStringEncodingUTF8);
            keys.fullKeys[index] = CFStringCreateWithCString(
                kCFAllocatorDefault, fullNames[index],
                kCFStringEncodingUTF8);
        }
    });
    return &keys;
}

// arm64e runtime-confirmed on 2026-08-04: using an on-device-linked
// Objective-C constant string here put the unauthenticated
// __CFConstantStringClassReference (0x00200001eed885d8) into
// -[__NSFrozenDictionaryM objectForKey:] and crashed in objc_msgSend while
// CoreUI rendered Terminal's toolbar.  Read the CF property-list graph with
// runtime-created CFStrings and CF collection APIs.  This preserves the exact
// IOSurface values and removes the broken constant-string ABI boundary rather
// than suppressing the CoreImage render.
bool macws_iosurface_plane_property_value(
        IOSurfaceRef surface, size_t plane,
        MacWSIOSurfacePlaneProperty property, uint64_t *valueOut) {
    if (!surface || !valueOut) return false;
    if (property < 0 || property >= MacWSIOSurfacePlanePropertyCount)
        return false;
    const MacWSIOSurfacePropertyKeys *keys = macws_iosurface_property_keys();
    if (!keys->creationProperties || !keys->planeInfo ||
        !keys->shortKeys[property] || !keys->fullKeys[property]) return false;
    CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
    if (!copied) return false;
    uint64_t value = 0;
    bool found = false;
    if (CFGetTypeID(copied) == CFDictionaryGetTypeID()) {
        CFTypeRef creationValue = CFDictionaryGetValue(
            copied, keys->creationProperties);
        CFDictionaryRef creation = creationValue &&
            CFGetTypeID(creationValue) == CFDictionaryGetTypeID()
                ? (CFDictionaryRef)creationValue : copied;
        CFTypeRef planeInfoValue = CFDictionaryGetValue(
            creation, keys->planeInfo);
        if (planeInfoValue &&
            CFGetTypeID(planeInfoValue) == CFArrayGetTypeID() &&
            plane < (size_t)CFArrayGetCount((CFArrayRef)planeInfoValue)) {
            CFTypeRef planeValue = CFArrayGetValueAtIndex(
                (CFArrayRef)planeInfoValue, (CFIndex)plane);
            if (planeValue &&
                CFGetTypeID(planeValue) == CFDictionaryGetTypeID()) {
                CFTypeRef number = CFDictionaryGetValue(
                    (CFDictionaryRef)planeValue, keys->shortKeys[property]);
                if (!number) {
                    number = CFDictionaryGetValue(
                        (CFDictionaryRef)planeValue,
                        keys->fullKeys[property]);
                }
                int64_t signedValue = 0;
                if (number && CFGetTypeID(number) == CFNumberGetTypeID() &&
                    CFNumberGetValue((CFNumberRef)number,
                                     kCFNumberSInt64Type, &signedValue) &&
                    signedValue >= 0) {
                    value = (uint64_t)signedValue;
                    found = true;
                }
            }
        }
    }
    CFRelease(copied);
    if (found) *valueOut = value;
    return found;
}

bool macws_iosurface_plane_component_count(IOSurfaceRef surface,
                                                   size_t plane,
                                                   uint64_t *valueOut) {
    if (macws_iosurface_plane_property_value(
            surface, plane, MacWSIOSurfacePlaneNumberOfComponents,
            valueOut)) return true;

    const MacWSIOSurfacePropertyKeys *keys = macws_iosurface_property_keys();
    if (!surface || !valueOut || !keys->creationProperties ||
        !keys->planeInfo || !keys->componentInfo ||
        !keys->fullComponentInfo) return false;
    CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
    if (!copied) return false;
    bool found = false;
    if (CFGetTypeID(copied) == CFDictionaryGetTypeID()) {
        CFTypeRef creationValue = CFDictionaryGetValue(
            copied, keys->creationProperties);
        CFDictionaryRef creation = creationValue &&
            CFGetTypeID(creationValue) == CFDictionaryGetTypeID()
                ? (CFDictionaryRef)creationValue : copied;
        CFTypeRef planes = CFDictionaryGetValue(creation, keys->planeInfo);
        if (planes && CFGetTypeID(planes) == CFArrayGetTypeID() &&
            plane < (size_t)CFArrayGetCount((CFArrayRef)planes)) {
            CFTypeRef planeValue = CFArrayGetValueAtIndex(
                (CFArrayRef)planes, (CFIndex)plane);
            if (planeValue &&
                CFGetTypeID(planeValue) == CFDictionaryGetTypeID()) {
                CFTypeRef components = CFDictionaryGetValue(
                    (CFDictionaryRef)planeValue, keys->componentInfo);
                if (!components) {
                    components = CFDictionaryGetValue(
                        (CFDictionaryRef)planeValue,
                        keys->fullComponentInfo);
                }
                if (components &&
                    CFGetTypeID(components) == CFArrayGetTypeID()) {
                    CFIndex count = CFArrayGetCount((CFArrayRef)components);
                    if (count > 0) {
                        *valueOut = (uint64_t)count;
                        found = true;
                    }
                }
            }
        }
    }
    CFRelease(copied);
    return found;
}

uint64_t macws_iosurface_plane_property(IOSurfaceRef surface,
                                                size_t plane,
                                                MacWSIOSurfacePlaneProperty property) {
    uint64_t value = 0;
    (void)macws_iosurface_plane_property_value(
        surface, plane, property, &value);
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneWidth);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneHeight);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneCompressionType);
    if (property == 0 || property > UINT32_MAX) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneHeightInCompressedTiles);
    if (property == 0 || property > SIZE_MAX) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneWidthInCompressedTiles);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneBytesPerRow);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT bytesPerRow plane=%zu original=%zu "
            "property=%llu recovery=%u\n",
            plane, original, (unsigned long long)property, count);
    }
    return (size_t)property;
}

// The adjacent non-compression plane fields have the same ABI drift. Exact
// shipped-binary disassembly (macOS 13.4 / iOS 16.3) shows:
//
//   field                 macOS offset   iOS offset
//   BytesPerElement       +0xe8          +0xe4
//   ElementWidth          +0xea          +0xe6
//   ElementHeight         +0xeb          +0xe7
//   PlaneSize             +0xe4          +0xe0
//   NumberOfComponents    +0xec          +0xe8
//
// This matters for VideoToolbox's two-plane NV12 IOSurfaces: reading the next
// field as BPE/element geometry creates a texture with a valid allocation but
// the wrong texel layout. Recover only values explicitly recorded in that
// IOSurface's own CreationProperties.
size_t macws_iosurface_explicit_plane_size(
        IOSurfaceRef surface, size_t plane, size_t original,
        MacWSIOSurfacePlaneProperty propertyKey, const char *field) {
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, propertyKey);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 24 || (count % 500) == 0)) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT %s plane=%zu original=%zu "
            "property=%llu surfaceID=%u recovery=%u\n",
            field, plane, original, (unsigned long long)property,
            IOSurfaceGetID(surface), count);
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetBytesPerElementOfPlane(IOSurfaceRef surface,
                                                size_t plane) {
    size_t original = IOSurfaceGetBytesPerElementOfPlane(surface, plane);
    return macws_iosurface_explicit_plane_size(surface, plane, original,
        MacWSIOSurfacePlaneBytesPerElement,
        "bytesPerElement");
}

size_t macws_IOSurfaceGetElementWidthOfPlane(IOSurfaceRef surface,
                                             size_t plane) {
    size_t original = IOSurfaceGetElementWidthOfPlane(surface, plane);
    return macws_iosurface_explicit_plane_size(surface, plane, original,
        MacWSIOSurfacePlaneElementWidth, "elementWidth");
}

size_t macws_IOSurfaceGetElementHeightOfPlane(IOSurfaceRef surface,
                                              size_t plane) {
    size_t original = IOSurfaceGetElementHeightOfPlane(surface, plane);
    return macws_iosurface_explicit_plane_size(surface, plane, original,
        MacWSIOSurfacePlaneElementHeight, "elementHeight");
}

size_t macws_IOSurfaceGetSizeOfPlane(IOSurfaceRef surface, size_t plane) {
    size_t original = IOSurfaceGetSizeOfPlane(surface, plane);
    return macws_iosurface_explicit_plane_size(surface, plane, original,
        MacWSIOSurfacePlaneSize, "size");
}

size_t macws_IOSurfaceGetNumberOfComponentsOfPlane(IOSurfaceRef surface,
                                                    size_t plane) {
    size_t original = IOSurfaceGetNumberOfComponentsOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = 0;
    if (!macws_iosurface_plane_component_count(surface, plane, &property) ||
        property == 0 || property > SIZE_MAX || property == original)
        return original;
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### IOSURFACE-COMPAT componentCount plane=%zu original=%zu "
            "property=%llu surfaceID=%u\n",
            plane, original, (unsigned long long)property,
            IOSurfaceGetID(surface));
    }
    return (size_t)property;
}

size_t macws_IOSurfaceGetBytesPerTileDataOfPlane(IOSurfaceRef surface,
                                                 size_t plane) {
    size_t original = IOSurfaceGetBytesPerTileDataOfPlane(surface, plane);
    if (!getenv("MACWS_AGX_NATIVE")) return original;
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneBytesPerTileData);
    if (property == 0 || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    bool found = macws_iosurface_plane_property_value(
        surface, plane, MacWSIOSurfacePlaneOffset, &property);
    if (!found || property > SIZE_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    bool found = macws_iosurface_plane_property_value(
        surface, plane, MacWSIOSurfacePlaneOffset, &propertyOffset);
    void *base = IOSurfaceGetBaseAddress(surface);
    if (!found || !base || propertyOffset > UINTPTR_MAX - (uintptr_t)base)
        return original;
    void *corrected = (void *)((uintptr_t)base + (uintptr_t)propertyOffset);
    if (corrected == original) return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
    uint64_t property = macws_iosurface_plane_property(
        surface, plane, MacWSIOSurfacePlaneAddressFormat);
    if (property == 0 || property > UINT32_MAX || property == original)
        return original;
    static _Atomic unsigned int recoveryCount = 0;
    unsigned int count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&recoveryCount, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 500) == 0)) {
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
DYLD_INTERPOSE(macws_IOSurfaceGetBytesPerElementOfPlane,
                IOSurfaceGetBytesPerElementOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetElementWidthOfPlane,
                IOSurfaceGetElementWidthOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetElementHeightOfPlane,
                IOSurfaceGetElementHeightOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetSizeOfPlane,
                IOSurfaceGetSizeOfPlane);
DYLD_INTERPOSE(macws_IOSurfaceGetNumberOfComponentsOfPlane,
                IOSurfaceGetNumberOfComponentsOfPlane);
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
    if (macws_runtime_diagnostics_enabled()) {
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
//
// vm_protect applies at page granularity.  The old implementation therefore
// made every function sharing the target's 16-KiB page non-executable while
// the callback wrote a four-byte instruction.  That is not safe after a
// process has started worker threads.  Runtime witness:
//
//   WindowServer-2026-07-30-013455.ips
//   faulting queue: com.apple.NSXPCConnection.m-user.com.apple.systemstatus
//   PC/FAR: objc_msgSend (0x188341c00), KERN_PROTECTION_FAILURE
//
// The AGX class-registration callback was patching objc_msgSendSuper2+0x10 on
// that same libobjc page at the time.  Suspend peer threads across the W^X
// transition so no peer can fetch from the temporarily RW/non-X page.  This
// fixes the patching invariant; it does not bypass the faulting ObjC call.
pthread_mutex_t g_macws_executable_patch_lock =
    PTHREAD_MUTEX_INITIALIZER;

bool macws_same_thread_id(thread_t candidate,
                                 const thread_identifier_info_data_t *current) {
    thread_identifier_info_data_t info = {0};
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t kr = thread_info(candidate, THREAD_IDENTIFIER_INFO,
        (thread_info_t)&info, &count);
    return kr == KERN_SUCCESS && info.thread_id == current->thread_id;
}

vm_prot_t macws_macho_execute_protection_for_address(void *address) {
    Dl_info image = {0};
    if (!dladdr(address, &image) || !image.dli_fbase) return 0;

    const struct mach_header_64 *header = image.dli_fbase;
    if (header->magic != MH_MAGIC_64) return 0;

    const uint8_t *commands = (const uint8_t *)(header + 1);
    const struct segment_command_64 *text = NULL;
    const uint8_t *cursor = commands;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize < cursor) return 0;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (!strncmp(segment->segname, SEG_TEXT,
                         sizeof(segment->segname))) {
                text = segment;
                break;
            }
        }
        cursor += command->cmdsize;
    }
    if (!text) return 0;

    intptr_t slide = (intptr_t)header - (intptr_t)text->vmaddr;
    uintptr_t target = (uintptr_t)address;
    cursor = commands;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize < cursor) return 0;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            uintptr_t start = (uintptr_t)((intptr_t)segment->vmaddr + slide);
            uintptr_t end = start + (uintptr_t)segment->vmsize;
            if (end >= start && target >= start && target < end)
                return segment->initprot & VM_PROT_EXECUTE;
        }
        cursor += command->cmdsize;
    }
    return 0;
}

void ModifyExecutableRegion(void *addr, size_t size, void(^callback)(void)) {
    if (!addr || !size || !callback) return;

    pthread_mutex_lock(&g_macws_executable_patch_lock);

    // This helper also patches authenticated GOT/class-reference slots in
    // __DATA_CONST.  Preserve the actual region permission instead of the old
    // unconditional RX "restore" (which the kernel rejects for non-X data
    // regions).  All current patches are smaller than one page; refuse a
    // future cross-region write until it is split by its caller.
    mach_vm_address_t region_address = (mach_vm_address_t)addr;
    mach_vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t region_info = {0};
    mach_msg_type_number_t region_info_count =
        VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t region_object = MACH_PORT_NULL;
    kern_return_t region_kr = mach_vm_region(mach_task_self(),
        &region_address, &region_size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&region_info, &region_info_count, &region_object);
    if (region_object != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), region_object);
    if (region_kr != KERN_SUCCESS ||
        (mach_vm_address_t)addr < region_address ||
        (mach_vm_address_t)addr > UINT64_MAX - size ||
        (mach_vm_address_t)addr + size > region_address + region_size) {
        fprintf(stderr,
            "#### ModifyExecutableRegion refused unknown/cross-region patch "
            "addr=%p size=%zu region=%#llx+%#llx kr=%#x\n",
            addr, size, (unsigned long long)region_address,
            (unsigned long long)region_size, region_kr);
        pthread_mutex_unlock(&g_macws_executable_patch_lock);
        return;
    }
    vm_prot_t original_protection = region_info.protection;
    // The macOS shared cache mapped by this iOS kernel can report its __TEXT
    // region as read-only even while instruction fetch is allowed by the
    // original mapping.  Calling vm_protect(R) on that page removes execute:
    // the validation run then faulted at IOMobileFramebufferOpen with an
    // instruction-abort permission failure.  Recover X from the actual loaded
    // Mach-O segment and restore it after the write; __DATA_CONST remains R.
    original_protection |=
        macws_macho_execute_protection_for_address(addr);

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t thread_count = 0;
    kern_return_t threads_kr = task_threads(mach_task_self(), &threads,
                                             &thread_count);
    uint8_t *suspended = threads_kr == KERN_SUCCESS && thread_count
        ? calloc(thread_count, sizeof(*suspended)) : NULL;

    thread_identifier_info_data_t current_info = {0};
    mach_msg_type_number_t current_info_count = THREAD_IDENTIFIER_INFO_COUNT;
    thread_t current = mach_thread_self();
    kern_return_t current_kr = thread_info(current, THREAD_IDENTIFIER_INFO,
        (thread_info_t)&current_info, &current_info_count);
    mach_port_deallocate(mach_task_self(), current);

    if (threads_kr != KERN_SUCCESS || !suspended ||
        current_kr != KERN_SUCCESS) {
        fprintf(stderr,
            "#### ModifyExecutableRegion refused unsafe patch addr=%p "
            "size=%zu task_threads=%#x current_info=%#x\n",
            addr, size, threads_kr, current_kr);
        goto cleanup;
    }

    bool found_current = false;
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        if (macws_same_thread_id(threads[i], &current_info)) {
            found_current = true;
            continue;
        }
        if (thread_suspend(threads[i]) == KERN_SUCCESS)
            suspended[i] = 1;
    }
    if (!found_current) {
        fprintf(stderr,
            "#### ModifyExecutableRegion refused patch: current thread "
            "missing from task_threads (addr=%p size=%zu)\n", addr, size);
        goto resume;
    }

    kern_return_t writable_kr = vm_protect(mach_task_self(),
        (vm_address_t)addr, size, false,
        PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if (writable_kr != KERN_SUCCESS) {
        fprintf(stderr,
            "#### ModifyExecutableRegion vm_protect RW failed addr=%p "
            "size=%zu kr=%#x\n", addr, size, writable_kr);
        goto resume;
    }

    callback();
    __builtin___clear_cache((char *)addr, (char *)addr + size);

    kern_return_t restore_kr = vm_protect(mach_task_self(),
        (vm_address_t)addr, size, false, original_protection);
    if (restore_kr != KERN_SUCCESS) {
        // Keep peers suspended: resuming them onto a non-executable code page
        // would recreate the exact production crash this function prevents.
        fprintf(stderr,
            "#### ModifyExecutableRegion FATAL vm_protect restore failed "
            "addr=%p size=%zu protection=%#x kr=%#x\n",
            addr, size, original_protection, restore_kr);
        abort();
    }

resume:
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        if (suspended[i]) thread_resume(threads[i]);
    }

cleanup:
    free(suspended);
    if (threads_kr == KERN_SUCCESS && threads) {
        for (mach_msg_type_number_t i = 0; i < thread_count; i++)
            mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads,
            (vm_size_t)thread_count * sizeof(*threads));
    }
    pthread_mutex_unlock(&g_macws_executable_patch_lock);
}

