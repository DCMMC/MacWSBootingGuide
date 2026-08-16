@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
@import CoreGraphics;
#import <rootless.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <stdatomic.h>
#import <stdarg.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/task_info.h>
#import <ptrauth.h>
#import "utils.h"

#import <IOSurface/IOSurfaceRef.h>
#import <sys/file.h>
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sysdir.h>

#include "macws_catalyst_drawable_protocol.h"
#import "MacWSFinalCompositePublisher.h"

typedef void (*macws_present_drawable_fn)(id, SEL, id);
static macws_present_drawable_fn macws_present_drawable_orig = NULL;
static _Atomic uint64_t macws_catalyst_drawable_sequence = 0;
static pthread_mutex_t macws_catalyst_drawable_service_lock =
    PTHREAD_MUTEX_INITIALIZER;
static mach_port_t macws_catalyst_drawable_service = MACH_PORT_NULL;

static uint64_t macws_resident_memory_bytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(
        mach_task_self(), MACH_TASK_BASIC_INFO,
        (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? info.resident_size : 0;
}

static BOOL macws_is_owned_scanout_texture(id<MTLTexture> texture);
static IOSurfaceRef macws_vnc_bound_surface(id<MTLTexture> texture);
static mach_port_t macws_catalyst_drawable_service_port(void) {
    pthread_mutex_lock(&macws_catalyst_drawable_service_lock);
    if (!MACH_PORT_VALID(macws_catalyst_drawable_service)) {
        mach_port_t service = MACH_PORT_NULL;
        if (bootstrap_look_up(bootstrap_port,
                MACWS_CATALYST_DRAWABLE_MACH_SERVICE, &service) ==
            BOOTSTRAP_SUCCESS)
            macws_catalyst_drawable_service = service;
    }
    mach_port_t result = macws_catalyst_drawable_service;
    pthread_mutex_unlock(&macws_catalyst_drawable_service_lock);
    return result;
}

static void macws_invalidate_catalyst_drawable_service(
        mach_port_t failedService) {
    pthread_mutex_lock(&macws_catalyst_drawable_service_lock);
    if (macws_catalyst_drawable_service == failedService) {
        (void)mach_port_deallocate(mach_task_self(), failedService);
        macws_catalyst_drawable_service = MACH_PORT_NULL;
    }
    pthread_mutex_unlock(&macws_catalyst_drawable_service_lock);
}

static void macws_publish_completed_catalyst_drawable(
        MacWSCatalystDrawableRecord record, IOSurfaceRef retainedSurface) {
    if (!retainedSurface) return;
    record.completionTime = mach_absolute_time();
    mach_port_t surfacePort = IOSurfaceCreateMachPort(retainedSurface);
    CFRelease(retainedSurface);
    mach_port_t service = macws_catalyst_drawable_service_port();
    if (!MACH_PORT_VALID(surfacePort) || !MACH_PORT_VALID(service)) {
        if (MACH_PORT_VALID(surfacePort))
            (void)mach_port_deallocate(mach_task_self(), surfacePort);
        return;
    }
    MacWSCatalystDrawableMachMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(
        MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = service;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = MACWS_CATALYST_DRAWABLE_MACH_MESSAGE_ID;
    message.body.msgh_descriptor_count = 1;
    message.surfacePort.name = surfacePort;
    // Keep the producer's ownership deterministic across every mach_msg
    // result.  A MOVE_SEND descriptor can consume the right even when the
    // send reports an error; the old failure path then deallocated that
    // already-consumed name and the kernel terminated Asphalt with
    // EXC_GUARD INVALID_NAME.  COPY_SEND gives the receiver its own right and
    // leaves this one owned by the producer until the single release below.
    message.surfacePort.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.surfacePort.type = MACH_MSG_PORT_DESCRIPTOR;
    message.record = record;
    mach_msg_return_t result = mach_msg(
        &message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        sizeof(message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    (void)mach_port_deallocate(mach_task_self(), surfacePort);
    if (result != MACH_MSG_SUCCESS) {
        if (result == MACH_SEND_INVALID_DEST)
            macws_invalidate_catalyst_drawable_service(service);
    }
}

static void macws_present_drawable_with_host_publish(
        id commandBuffer, SEL selector, id drawable) {
    IOSurfaceRef retainedSurface = NULL;
    MacWSCatalystDrawableRecord record = {0};
    @try {
        id texture = drawable &&
                [drawable respondsToSelector:@selector(texture)]
            ? [drawable texture] : nil;
        IOSurfaceRef surface = texture &&
                [texture respondsToSelector:@selector(iosurface)]
            ? (IOSurfaceRef)[texture iosurface] : NULL;
        uint32_t surfaceID = surface ? IOSurfaceGetID(surface) : 0;
        if (surface && surfaceID != 0) {
            retainedSurface = (IOSurfaceRef)CFRetain(surface);
            record = (MacWSCatalystDrawableRecord){
                .magic = MACWS_CATALYST_DRAWABLE_MAGIC,
                .version = MACWS_CATALYST_DRAWABLE_VERSION,
                .size = sizeof(record),
                .ownerPID = getpid(),
                .surfaceID = surfaceID,
                .sequence = atomic_fetch_add_explicit(
                    &macws_catalyst_drawable_sequence, 1,
                    memory_order_relaxed) + 1,
                .width = (uint32_t)[texture width],
                .height = (uint32_t)[texture height],
                .bytesPerRow = (uint32_t)IOSurfaceGetBytesPerRow(surface),
                .ioSurfacePixelFormat = IOSurfaceGetPixelFormat(surface),
                .metalPixelFormat = (uint32_t)[texture pixelFormat],
            };
            if (!MacWSCatalystDrawableRecordIsValid(&record, sizeof(record))) {
                CFRelease(retainedSurface);
                retainedSurface = NULL;
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
        if (retainedSurface) CFRelease(retainedSurface);
        retainedSurface = NULL;
    }

    if (retainedSurface &&
        [commandBuffer respondsToSelector:@selector(addCompletedHandler:)]) {
        IOSurfaceRef surfaceForCompletion = retainedSurface;
        MacWSCatalystDrawableRecord recordForCompletion = record;
        [commandBuffer addCompletedHandler:^(__unused id completed) {
            macws_publish_completed_catalyst_drawable(
                recordForCompletion, surfaceForCompletion);
        }];
    } else if (retainedSurface) {
        CFRelease(retainedSurface);
    }
    if (macws_present_drawable_orig)
        macws_present_drawable_orig(commandBuffer, selector, drawable);
}

static void macws_install_catalyst_drawable_publisher(void) {
    const char *enabled = getenv("MACWS_CATALYST_DIRECT_DRAWABLE");
    if (!enabled || strcmp(enabled, "1") != 0) return;
    Class commandBufferClass = objc_getClass("_MTLCommandBuffer");
    SEL selector = sel_registerName("presentDrawable:");
    Method method = commandBufferClass
        ? class_getInstanceMethod(commandBufferClass, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)macws_present_drawable_with_host_publish) return;
    macws_present_drawable_orig = (macws_present_drawable_fn)current;
    method_setImplementation(
        method, (IMP)macws_present_drawable_with_host_publish);
}

// Match mac_hooks.m's production/diagnostic boundary. This is intentionally
// process-start state: enabling method swizzles or flight recorders halfway
// through a frame would itself make a performance trace incoherent.
static BOOL macws_runtime_diagnostics_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_runtime_diagnostics", F_OK) == 0 ||
            access("/tmp/macws_submit_diag", F_OK) == 0 ||
            access("/tmp/macws_submit_ring", F_OK) == 0 ||
            access("/tmp/macws_submit_fast_ring", F_OK) == 0 ||
            access("/tmp/macws_iogpu_error_diag", F_OK) == 0 ||
            access("/tmp/macws_command_error_diag", F_OK) == 0 ||
            access("/tmp/macws_observe_pf550", F_OK) == 0 ||
            access("/tmp/macws_probe_small_pf550", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

// ExtensionFoundation obtains the identity for the executable it is hosting
// from +[LSBundleRecord bundleRecordForCurrentProcess].  On stock macOS the
// process audit token leads back to the LaunchServices entry created for that
// app extension.  Here RunningBoard launches the iOS proxy first and then the
// proxy execs the macOS image inside the chroot, so the preserved audit-token
// identity describes the proxy while NSBundle describes the real Settings
// extension bundle.
// Runtime evidence in appearance-inline-ls-oslog.txt is exact:
// _LSPluginFindWithPlatformInfo:699 returns -10814 and the provider returns
// nil.  ExtensionFoundation then exits at EXRunningExtension.m:149.
//
// Repair that missing audit-token -> bundle-URL association at the provider
// boundary.  This is deliberately not a success/check bypass: the stock
// result wins, the fallback is restricted to a real system Settings appex,
// and LSApplicationExtensionRecord must independently accept the exact bundle
// URL and return a platform-1 record with the same identifier.
static id (*macws_bundle_record_for_current_process_orig)(id, SEL) = NULL;

static id macws_bundle_record_for_current_process_compat(id receiver,
                                                          SEL selector) {
    id record = macws_bundle_record_for_current_process_orig
        ? macws_bundle_record_for_current_process_orig(receiver, selector)
        : nil;
    if (record) return record;

    NSBundle *bundle = [NSBundle mainBundle];
    NSString *identifier = [bundle bundleIdentifier];
    const char *identifierBytes = [identifier UTF8String];
    NSURL *bundleURL = [bundle bundleURL];
    NSString *bundlePath = [[bundleURL path] stringByStandardizingPath];
    NSDictionary *extensionAttributes =
        [[bundle infoDictionary] objectForKey:@"EXAppExtensionAttributes"];
    NSString *extensionPoint =
        [extensionAttributes isKindOfClass:[NSDictionary class]]
            ? [extensionAttributes objectForKey:@"EXExtensionPointIdentifier"]
            : nil;
    if (!identifierBytes ||
        ![bundlePath hasPrefix:
            @"/System/Library/ExtensionKit/Extensions/"] ||
        [bundlePath rangeOfString:@".appex"].location == NSNotFound ||
        ![extensionPoint isEqualToString:
            @"com.apple.Settings.extension.ui"]) return nil;

    Class extensionRecordClass = objc_getClass("LSApplicationExtensionRecord");
    if (!bundleURL || !extensionRecordClass) return nil;

    NSError *error = nil;
    id candidate = ((id (*)(id, SEL))objc_msgSend)(
        (id)extensionRecordClass, sel_registerName("alloc"));
    candidate = ((id (*)(id, SEL, id, id *))objc_msgSend)(
        candidate, sel_registerName("initWithURL:error:"), bundleURL, &error);
    id candidateIdentifier = candidate
        ? ((id (*)(id, SEL))objc_msgSend)(
              candidate, sel_registerName("bundleIdentifier"))
        : nil;
    unsigned candidatePlatform = candidate
        ? ((unsigned (*)(id, SEL))objc_msgSend)(
              candidate, sel_registerName("platform"))
        : 0;
    NSURL *candidateURL = candidate
        ? ((id (*)(id, SEL))objc_msgSend)(
              candidate, sel_registerName("URL"))
        : nil;
    BOOL validClass = candidate && ((BOOL (*)(id, SEL, id))objc_msgSend)(
        candidate, sel_registerName("isKindOfClass:"), extensionRecordClass);
    BOOL validIdentifier = validClass && candidateIdentifier &&
        ((BOOL (*)(id, SEL, id))objc_msgSend)(
            candidateIdentifier, sel_registerName("isEqualToString:"),
            identifier) && candidatePlatform == 1 &&
        [[[candidateURL path] stringByStandardizingPath]
            isEqualToString:bundlePath];
    fprintf(stderr,
            "#### EXTENSION-LS-IDENTITY original=nil bundle=%s url=%s "
            "candidate=%s candidate-id=%s platform=%u candidate-url=%s "
            "error=%s accepted=%s\n",
            identifierBytes,
            [bundlePath UTF8String] ?: "<nil>",
            candidate ? object_getClassName(candidate) : "nil",
            candidateIdentifier
                ? [[candidateIdentifier description] UTF8String] : "nil",
            candidatePlatform,
            [[[candidateURL absoluteURL] path] UTF8String] ?: "<nil>",
            error ? [[error description] UTF8String] : "nil",
            validIdentifier ? "YES" : "NO");
    fflush(stderr);
    return validIdentifier ? candidate : nil;
}

static void macws_install_extension_bundle_identity_compatibility(void) {
    const char *appExtension = getenv("MACWS_APP_EXTENSION");
    if (!appExtension || strcmp(appExtension, "1") != 0) return;
    Class recordClass = objc_getClass("LSBundleRecord");
    if (!recordClass) {
        fprintf(stderr,
                "#### EXTENSION-LS-IDENTITY LSBundleRecord unavailable\n");
        return;
    }
    Method method = class_getClassMethod(
        recordClass, sel_registerName("bundleRecordForCurrentProcess"));
    if (!method) {
        fprintf(stderr,
                "#### EXTENSION-LS-IDENTITY provider method unavailable\n");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)macws_bundle_record_for_current_process_compat) return;
    macws_bundle_record_for_current_process_orig =
        (id (*)(id, SEL))current;
    method_setImplementation(
        method, (IMP)macws_bundle_record_for_current_process_compat);
    fprintf(stderr,
            "#### EXTENSION-LS-IDENTITY provider compatibility installed\n");
}

// Runtime-confirmed by misc/ExtensionRecordProbe against the loaded Ventura
// 13.4 ExtensionFoundation image:
//
//   -[_EXRunningExtension _startWithArguments:count:]
//       types=i28@0:8r^*16i24
//
// The corresponding disassembly at +160 sends
// +[LSBundleRecord bundleRecordForCurrentProcess].  Installing the provider
// replacement from libmachook's constructor was too early on this launch
// path: LaunchServices can finish registering its Objective-C classes only
// when ExtensionFoundation enters this method.  Wrap the actual lifecycle
// boundary and install the narrow provider compatibility immediately before
// the original lookup.  The original implementation, arguments, and return
// value remain intact.
static int (*macws_running_extension_start_orig)(
    id, SEL, const char *const *, int) = NULL;

static int macws_running_extension_start_compat(
    id receiver, SEL selector, const char *const *arguments, int count) {
    macws_install_extension_bundle_identity_compatibility();
    return macws_running_extension_start_orig
        ? macws_running_extension_start_orig(
              receiver, selector, arguments, count)
        : -1;
}

static void macws_install_running_extension_identity_boundary(void) {
    const char *appExtension = getenv("MACWS_APP_EXTENSION");
    if (!appExtension || strcmp(appExtension, "1") != 0) return;
    Class runningExtensionClass = objc_getClass("_EXRunningExtension");
    if (!runningExtensionClass) return;
    Method startMethod = class_getInstanceMethod(
        runningExtensionClass,
        sel_registerName("_startWithArguments:count:"));
    if (!startMethod) return;
    IMP current = method_getImplementation(startMethod);
    if (current == (IMP)macws_running_extension_start_compat) return;
    macws_running_extension_start_orig =
        (int (*)(id, SEL, const char *const *, int))current;
    method_setImplementation(
        startMethod, (IMP)macws_running_extension_start_compat);
    fprintf(stderr,
            "#### EXTENSION-LS-IDENTITY lifecycle boundary installed\n");
}

// InitStuff in mac_hooks.m calls this again after EnableJIT.  That second
// installation point is intentional: the bundle-local dylib can be initialized
// before the extension proxy's post-exec debug marker lands, while the method
// implementations execute only after ExtensionFoundation starts its listener.
void MacWSInstallExtensionRuntimeCompatibility(void) {
    macws_install_extension_bundle_identity_compatibility();
    macws_install_running_extension_identity_boundary();
}

// Focused launch-context probe for ViewBridge/HIServices/OpenPanel.  These
// services must retain libxpc's private per-instance dictionary across the
// proxy chroot+exec boundary.  The probe records the real dictionary from the
// target process; it never changes listener results or protocol behavior.
static void macws_record_xpc_service_context_if_requested(void) {
    if (access("/private/tmp/macws_xpc_proxy_trace", F_OK) != 0) return;
    const char *program = getprogname();
    if (!program || (!strstr(program, "ViewBridgeAuxiliary") &&
                     !strstr(program, "hiservices-xpcservice") &&
                     !strstr(program, "openAndSavePanelService"))) return;
    typedef xpc_object_t (*copy_service_dictionary_fn)(void);
    copy_service_dictionary_fn copyDictionary =
        (copy_service_dictionary_fn)dlsym(
            RTLD_DEFAULT, "_xpc_copy_xpcservice_dictionary");
    xpc_object_t dictionary = copyDictionary ? copyDictionary() : NULL;
    char *description = dictionary ? xpc_copy_description(dictionary) : NULL;
    int fd = open("/private/tmp/macws_xpc_context.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        dprintf(fd,
                "stage=target-constructor program=%s pid=%d ppid=%d uid=%d "
                "service=%s dictionary=%s\n",
                program, getpid(), getppid(), getuid(),
                getenv("XPC_SERVICE_NAME") ?: "<unset>",
                description ?: "<unavailable>");
        extern char **environ;
        for (char **entry = environ; entry && *entry; entry++) {
            if (strstr(*entry, "XPC") || strstr(*entry, "xpc"))
                dprintf(fd, "stage=target-constructor env=%s\n", *entry);
        }
        close(fd);
    }
    free(description);
}

// macOS normally completes this state transition in loginwindow.  MacWS has
// a real WindowServer session but intentionally no loginwindow process, so
// Ventura reports the pre-login placeholder (uid 88, user "unknown",
// on-console=true, login-done=false) forever.  This is not merely cosmetic:
// RE-confirmed in Ventura System Settings at 0x1000afba0..0x1000afcdc, the
// application skips SwiftUI.App.main entirely unless this provider returns a
// true kCGSessionLoginDoneKey.  loginwindow itself updates the provider with
// CGSSessionSetCurrentSessionProperties, but that path requires macOS audit
// SessionCreate; runtime on iOS returns 100078 and CGS then rejects the
// loginwindow connection with error 1000.
//
// Complete the absent provider handoff at the provider boundary, not in each
// consumer. Preserve every WindowServer-owned value and only change the one
// login-completion bit for MacWS's exact shared synthetic audit session and
// exact pre-login placeholder identity. A future real loginwindow session, a
// different audit session, or an already-complete login remains untouched.
typedef CFDictionaryRef (*macws_copy_cgsession_fn)(void);
static macws_copy_cgsession_fn macws_cgsession_private_orig = NULL;
static macws_copy_cgsession_fn macws_cgsession_public_orig = NULL;

static BOOL macws_cgsession_is_prelogin_placeholder(CFDictionaryRef session) {
    if (!session || CFGetTypeID(session) != CFDictionaryGetTypeID()) return NO;
    // Do not use CFSTR constants emitted into the injected dylib as keys in a
    // macOS arm64e CoreFoundation collection.  Maps-2026-08-03-163221.ips
    // runtime-confirmed a PAC fault in -[__NSFrozenDictionaryM objectForKey:]
    // while hashing such a cross-image constant.  Strings created by the live
    // process's CoreFoundation runtime carry the correct authentication state.
    const char *keyNames[] = {
        "kCGSSessionAuditIDKey",
        "kCGSSessionUserIDKey",
        "kCGSSessionUserNameKey",
        "kCGSSessionOnConsoleKey",
        "kCGSessionLoginDoneKey",
        "unknown",
    };
    CFStringRef strings[sizeof(keyNames) / sizeof(keyNames[0])] = {};
    BOOL allStringsCreated = YES;
    for (size_t index = 0;
         index < sizeof(strings) / sizeof(strings[0]); index++) {
        strings[index] = CFStringCreateWithCString(
            kCFAllocatorDefault, keyNames[index], kCFStringEncodingUTF8);
        if (!strings[index]) allStringsCreated = NO;
    }
    if (!allStringsCreated) {
        for (size_t index = 0;
             index < sizeof(strings) / sizeof(strings[0]); index++) {
            if (strings[index]) CFRelease(strings[index]);
        }
        return NO;
    }

    CFTypeRef audit = CFDictionaryGetValue(session, strings[0]);
    CFTypeRef userID = CFDictionaryGetValue(session, strings[1]);
    CFTypeRef userName = CFDictionaryGetValue(session, strings[2]);
    CFTypeRef onConsole = CFDictionaryGetValue(session, strings[3]);
    CFTypeRef loginDone = CFDictionaryGetValue(session, strings[4]);
    BOOL matchesTypes = audit && CFGetTypeID(audit) == CFNumberGetTypeID() &&
        userID && CFGetTypeID(userID) == CFNumberGetTypeID() &&
        userName && CFGetTypeID(userName) == CFStringGetTypeID() &&
        onConsole == kCFBooleanTrue && loginDone == kCFBooleanFalse;
    if (!matchesTypes) {
        for (size_t index = 0;
             index < sizeof(strings) / sizeof(strings[0]); index++)
            CFRelease(strings[index]);
        return NO;
    }

    int64_t auditValue = 0;
    int64_t userIDValue = 0;
    BOOL readNumbers =
        CFNumberGetValue((CFNumberRef)audit, kCFNumberSInt64Type,
                         &auditValue) &&
        CFNumberGetValue((CFNumberRef)userID, kCFNumberSInt64Type,
                         &userIDValue);
    BOOL result = readNumbers && auditValue == 0x004d5753 &&
        userIDValue == 88 &&
        CFStringCompare((CFStringRef)userName, strings[5], 0) ==
            kCFCompareEqualTo;
    for (size_t index = 0;
         index < sizeof(strings) / sizeof(strings[0]); index++)
        CFRelease(strings[index]);
    return result;
}

static CFDictionaryRef macws_cgsession_complete_login_handoff(
    CFDictionaryRef session) {
    if (!macws_cgsession_is_prelogin_placeholder(session)) return session;
    CFMutableDictionaryRef completed = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault, 0, session);
    if (!completed) return session;
    CFStringRef loginDoneKey = CFStringCreateWithCString(
        kCFAllocatorDefault, "kCGSessionLoginDoneKey",
        kCFStringEncodingUTF8);
    if (!loginDoneKey) {
        CFRelease(completed);
        return session;
    }
    CFDictionarySetValue(completed, loginDoneKey, kCFBooleanTrue);
    CFRelease(loginDoneKey);
    CFRelease(session);
    return completed;
}

static CFDictionaryRef macws_cgsession_private_compat(void) {
    return macws_cgsession_complete_login_handoff(
        macws_cgsession_private_orig
            ? macws_cgsession_private_orig() : NULL);
}

static CFDictionaryRef macws_cgsession_public_compat(void) {
    return macws_cgsession_complete_login_handoff(
        macws_cgsession_public_orig
            ? macws_cgsession_public_orig() : NULL);
}

static void macws_install_cgsession_login_handoff_compatibility(void) {
    void *privateProvider = dlsym(
        RTLD_DEFAULT, "CGSSessionCopyCurrentSessionProperties");
    void *publicProvider = dlsym(
        RTLD_DEFAULT, "CGSessionCopyCurrentDictionary");
    if (privateProvider) {
        MSHookFunction(privateProvider,
                       (void *)macws_cgsession_private_compat,
                       (void **)&macws_cgsession_private_orig);
    }
    if (publicProvider && publicProvider != privateProvider) {
        MSHookFunction(publicProvider,
                       (void *)macws_cgsession_public_compat,
                       (void **)&macws_cgsession_public_orig);
    }
}

// Focused Launchpad source-import diagnostic.  Ventura's Dock owns the
// LPAppManager/LPAppSource implementation, so observing these real method
// boundaries tells us whether an empty Launchpad database comes from source
// validation, source bring-up, or directory scanning.  This is deliberately
// opt-in: production Dock processes pay no swizzle or logging cost unless the
// launchd job starts with MACWS_LAUNCHPAD_TRACE=1.
static BOOL (*macws_lp_path_valid_orig)(id, SEL, id) = NULL;
static void (*macws_lp_source_common_init_orig)(id, SEL) = NULL;
static void (*macws_lp_source_bring_online_orig)(id, SEL) = NULL;
static void (*macws_lp_source_rescan_orig)(id, SEL) = NULL;
static BOOL (*macws_lp_source_start_watching_orig)(id, SEL, BOOL *) = NULL;
static void (*macws_lp_scan_path_orig)(id, SEL, id, id, NSUInteger, id) = NULL;
static int (*macws_lp_fstatfs_orig)(int, struct statfs *) = NULL;
static int (*macws_lp_statfs_orig)(const char *, struct statfs *) = NULL;
static ssize_t (*macws_fsgetpath_orig)(char *, size_t, fsid_t *, uint64_t) = NULL;
static BOOL macws_chroot_root_mount_needs_rebase = NO;
static fsid_t macws_chroot_root_fsid = {};
static char macws_chroot_root_host_mount[MAXPATHLEN] = {};
static char macws_chroot_host_root[MAXPATHLEN] = {};
typedef Boolean (*macws_cfurl_copy_resource_property_fn)(
    CFURLRef, CFStringRef, void *, CFErrorRef *);
static macws_cfurl_copy_resource_property_fn
    macws_cfurl_copy_resource_property_orig = NULL;

static BOOL macws_needs_application_mount_namespace_compatibility(void) {
    // Third-party AppKit executables launched through macwshostd's validated
    // custom-path transaction may become LaunchServices/CoreServices catalog
    // consumers while decoding a document NIB or resolving an icon.  The
    // launcher opts those processes into the same complete logical-root mount
    // contract as the catalog owners below.  Do not infer this from "GUI":
    // Terminal's fork path must continue to avoid the fsgetpath trampoline.
    const char *production = getenv("MACWS_APP_MOUNT_COMPAT");
    if (production && strcmp(production, "1") == 0) return YES;
    // Diagnostic escape hatch for one isolated consumer. It is never set by a
    // shipped launch plist or the production launcher.
    if (getenv("MACWS_APP_MOUNT_COMPAT_DIAGNOSTIC")) return YES;
    const char *program = getprogname();
    // The stock application scan is executed by lsregister itself, while the
    // standalone System Settings extensions are registered by the narrowly
    // scoped macwsworkspacectl transaction below.  Both are catalog owners,
    // but macwsworkspacectl's other commands (notably show-launchpad) can
    // spawn children and must not inherit the fsgetpath trampoline.  Admit
    // only the explicit one-shot registration environment.
    if (program && strcmp(program, "macwsworkspacectl") == 0 &&
        getenv("MACWS_CATALOG_REGISTRATION") &&
        strcmp(getenv("MACWS_CATALOG_REGISTRATION"), "1") == 0)
        return YES;
    return program &&
        (strcmp(program, "Dock") == 0 ||
         strcmp(program, "Finder") == 0 ||
         strcmp(program, "iconservicesagent") == 0 ||
         strcmp(program, "iconservicesd") == 0 ||
         // Runtime-confirmed in sharedfilelistd-2026-08-13-073755.ips:
         // Ventura's SharedFileList worker hit the same four-node
         // CoreServicesInternal FileCache/CFURL finalization recursion as
         // Finder when the host mount namespace escaped the chroot.  Steam's
         // startup synchronously queries this service, so it is a filesystem
         // catalog consumer and needs the identical root-volume contract.
         strcmp(program, "sharedfilelistd") == 0 ||
         // Runtime-confirmed in locationd-2026-08-05-115330.ips: the
         // Ventura daemon's CLInternalServiceSilo recursively finalized 511
         // CoreServicesInternal FileCache/CFURL frames after the host mount
         // escaped its chroot. It consumes the same logical-root filesystem
         // contract as Finder, while iPadOS locationd never loads libmachook.
         strcmp(program, "locationd") == 0 ||
         strcmp(program, "lsregister") == 0 ||
         strcmp(program, "launchservicesd") == 0 ||
         strcmp(program, "lsd") == 0);
}

// Darwin's statfs/fstatfs expose the host mount namespace even after chroot(2).
// On this iPad, every path backed by the chroot root filesystem reports that it
// is mounted at `/private/var`, although the process-visible mount point is `/`.
// This is a filesystem invariant rather than an application-directory special
// case:
//
//   * Dock's stock LPAppSource rejects /System/Applications when the returned
//     mount point is not a prefix of the process-visible path.
//   * Runtime LLDB on the stock Ventura lsd showed
//     -[NSFileManager getRelationship:ofDirectoryAtURL:toItemAtURL:error:]
//     walking `/private -> / -> /private/var/mnt -> /private/var -> /private`
//     forever while _LSDatabaseClean registers a required bundle. The parent
//     of the chroot root escaped into the host namespace because `/` was not
//     recognized as the volume root.
//
// Capture the real root filesystem ID before interposing, then report `/` as
// the mount point for every statfs result on exactly that filesystem. Separate
// bind mounts (devfs, dyld cache, etc.) retain their own filesystem identity and
// mount point. This models a real chroot mount namespace; it neither fabricates
// LaunchServices records nor bypasses its validation.
static void macws_rebase_application_mount_namespace(
    const char *path, struct statfs *buffer) {
    if (!buffer || !macws_needs_application_mount_namespace_compatibility() ||
        !macws_chroot_root_mount_needs_rebase ||
        buffer->f_fsid.val[0] != macws_chroot_root_fsid.val[0] ||
        buffer->f_fsid.val[1] != macws_chroot_root_fsid.val[1]) return;

    if (strcmp(buffer->f_mntonname, "/") == 0) return;

    char hostMount[MAXPATHLEN] = {};
    strlcpy(hostMount, buffer->f_mntonname, sizeof(hostMount));
    strlcpy(buffer->f_mntonname, "/", sizeof(buffer->f_mntonname));
    if (getenv("MACWS_LAUNCHPAD_TRACE") ||
        getenv("MACWS_APP_MOUNT_TRACE")) {
        fprintf(stderr,
                "#### APP-MOUNT namespace rebase process=%s path=%s "
                "hostMnton=%s visibleMnton=/ fsid=(%d,%d)\n",
                getprogname() ?: "unknown", path, hostMount,
                buffer->f_fsid.val[0], buffer->f_fsid.val[1]);
    }
}

static int macws_lp_fstatfs_namespace_compat(int descriptor,
                                            struct statfs *buffer) {
    int result = macws_lp_fstatfs_orig(descriptor, buffer);
    if (result != 0 || !buffer) return result;

    char path[MAXPATHLEN] = {};
    if (fcntl(descriptor, F_GETPATH, path) == 0)
        macws_rebase_application_mount_namespace(path, buffer);
    return result;
}

static int macws_lp_statfs_namespace_compat(const char *path,
                                           struct statfs *buffer) {
    int result = macws_lp_statfs_orig(path, buffer);
    if (result == 0 && buffer)
        macws_rebase_application_mount_namespace(path, buffer);
    return result;
}

// CFURL's resource-property provider is where NSURLParentDirectoryURLKey and
// NSURLVolumeURLKey cross from a process-visible URL into the kernel's host
// mount namespace.
// Runtime LLDB on Ventura 13.4 captured createURLParentageArray repeatedly
// asking this API for exactly NSURLParentDirectoryURLKey while its URL chain
// cycled `/private/ -> / -> /private/var/mnt/ -> /private/var -> /private`.
// The same trace showed that the local createVolumeParentURL provider is not
// used by this query, so hooking that provider would only hide a nearby
// symptom and is intentionally avoided.
//
// Runtime-confirmed on lsd PID 83632: asking NSURLVolumeURLKey for
// /System/Library/CoreServices/CoreTypes.bundle returned `/private/var`, the
// host mount point. FSNode then constructed that host URL in the chroot, where
// it names an ordinary directory; -isVolume returned false and
// _LSIsNodeTranslocatedMountPoint rejected every plugin with OSStatus -50.
//
// Restore the standard filesystem invariants at the public provider boundary:
// the process-visible root URL has no parent, and the volume URL for any node
// on the chroot root filesystem is `/`. This is deliberately limited to
// lsd/Dock/launchservicesd instances whose real root statfs reports the exact
// chroot filesystem mounted elsewhere in the host namespace. Every separate
// filesystem, unrelated resource key, and normal process uses CoreFoundation
// unchanged.
static Boolean macws_cfurl_copy_resource_property_compat(
    CFURLRef url, CFStringRef key, void *value, CFErrorRef *error) {
    char keyName[64] = {};
    char visiblePath[MAXPATHLEN] = {};
    BOOL hasKeyName = key && CFGetTypeID(key) == CFStringGetTypeID() &&
        CFStringGetCString(key, keyName, sizeof(keyName),
                           kCFStringEncodingUTF8);
    BOOL hasVisiblePath = url && CFURLGetFileSystemRepresentation(
        url, true, (UInt8 *)visiblePath, sizeof(visiblePath));
    if (url && key && macws_chroot_root_mount_needs_rebase &&
        hasKeyName && hasVisiblePath) {
        if (
            strcmp(keyName, "NSURLParentDirectoryURLKey") == 0 &&
            strcmp(visiblePath, "/") == 0) {
            if (value) *(CFTypeRef *)value = NULL;
            if (error) *error = NULL;
            if (getenv("MACWS_APP_MOUNT_TRACE")) {
                fprintf(stderr,
                        "#### APP-MOUNT process root has no parent "
                        "process=%s fsid=(%d,%d)\n",
                        getprogname() ?: "unknown",
                        macws_chroot_root_fsid.val[0],
                        macws_chroot_root_fsid.val[1]);
            }
            return true;
        }
    }
    Boolean result = macws_cfurl_copy_resource_property_orig
        ? macws_cfurl_copy_resource_property_orig(url, key, value, error)
        : false;
    BOOL isVolumeQuery = hasKeyName && hasVisiblePath &&
        strcmp(keyName, "NSURLVolumeURLKey") == 0;
    if (result && isVolumeQuery && value &&
        macws_chroot_root_mount_needs_rebase) {
        CFTypeRef property = *(CFTypeRef *)value;
        char volumePath[MAXPATHLEN] = {};
        struct statfs inputFileSystem = {};
        BOOL isRootFileSystem = macws_lp_statfs_orig &&
            macws_lp_statfs_orig(visiblePath, &inputFileSystem) == 0 &&
            inputFileSystem.f_fsid.val[0] == macws_chroot_root_fsid.val[0] &&
            inputFileSystem.f_fsid.val[1] == macws_chroot_root_fsid.val[1];
        BOOL isLeakedHostMount = property &&
            CFGetTypeID(property) == CFURLGetTypeID() &&
            CFURLGetFileSystemRepresentation(
                (CFURLRef)property, true, (UInt8 *)volumePath,
                sizeof(volumePath)) &&
            strcmp(volumePath, macws_chroot_root_host_mount) == 0;
        if (isRootFileSystem && isLeakedHostMount) {
            static const UInt8 rootPath[] = "/";
            CFURLRef visibleRoot = CFURLCreateFromFileSystemRepresentation(
                kCFAllocatorDefault, rootPath, 1, true);
            if (visibleRoot) {
                CFRelease(property);
                *(CFTypeRef *)value = visibleRoot;
                if (getenv("MACWS_APP_MOUNT_TRACE")) {
                    fprintf(stderr,
                            "#### APP-MOUNT volume namespace rebase "
                            "process=%s input=%s hostVolume=%s "
                            "visibleVolume=/ fsid=(%d,%d)\n",
                            getprogname() ?: "unknown", visiblePath,
                            volumePath, inputFileSystem.f_fsid.val[0],
                            inputFileSystem.f_fsid.val[1]);
                }
            }
        }
    }
    if (getenv("MACWS_APP_MOUNT_TRACE") && isVolumeQuery) {
        char volumePath[MAXPATHLEN] = "<none>";
        CFTypeRef property = value ? *(CFTypeRef *)value : NULL;
        if (result && property && CFGetTypeID(property) == CFURLGetTypeID()) {
            if (!CFURLGetFileSystemRepresentation(
                    (CFURLRef)property, true, (UInt8 *)volumePath,
                    sizeof(volumePath))) {
                strlcpy(volumePath, "<unrepresentable>", sizeof(volumePath));
            }
        }
        fprintf(stderr,
                "#### APP-MOUNT volume provider process=%s input=%s "
                "result=%d volume=%s\n",
                getprogname() ?: "unknown", visiblePath, result, volumePath);
    }
    return result;
}

static void macws_install_root_parent_namespace_compatibility(void) {
    void *target = dlsym(RTLD_DEFAULT,
                         "CFURLCopyResourcePropertyForKey");
    if (!target) return;
    MSHookFunction(target,
                   (void *)macws_cfurl_copy_resource_property_compat,
                   (void **)&macws_cfurl_copy_resource_property_orig);
    if (getenv("MACWS_APP_MOUNT_TRACE")) {
        fprintf(stderr,
                "#### APP-MOUNT root parent provider installed "
                "target=%p original=%p\n",
                target, macws_cfurl_copy_resource_property_orig);
    }
}

// statfs fixes volume identity, while fsgetpath fixes the other half of the
// same namespace contract. CoreServices asks the kernel to turn a file ID back
// into a path when producing NSURLParentDirectoryURLKey. The iOS kernel returns
// `/private/var/mnt/rootfs/...`; exposing that string to a chrooted process lets
// the parent of `/` escape the chroot. Rebase only the canonical host root
// supplied by launchdchrootexec, preserving every path from other filesystems.
static ssize_t macws_fsgetpath_namespace_compat(char *buffer, size_t capacity,
                                                fsid_t *fsid,
                                                uint64_t objectID) {
    ssize_t result = macws_fsgetpath_orig(buffer, capacity, fsid, objectID);
    if (result < 0 || !buffer || !macws_chroot_host_root[0]) return result;

    size_t hostRootLength = strlen(macws_chroot_host_root);
    if (strncmp(buffer, macws_chroot_host_root, hostRootLength) != 0 ||
        (buffer[hostRootLength] != '\0' &&
         buffer[hostRootLength] != '/')) return result;

    char hostPath[MAXPATHLEN] = {};
    if (getenv("MACWS_APP_MOUNT_TRACE"))
        strlcpy(hostPath, buffer, sizeof(hostPath));

    const char *visibleSuffix = buffer + hostRootLength;
    if (*visibleSuffix == '\0') {
        if (capacity < 2) {
            errno = ERANGE;
            return -1;
        }
        buffer[0] = '/';
        buffer[1] = '\0';
    } else {
        size_t visibleLength = strlen(visibleSuffix) + 1;
        memmove(buffer, visibleSuffix, visibleLength);
    }
    result = (ssize_t)strlen(buffer) + 1;

    if (getenv("MACWS_APP_MOUNT_TRACE")) {
        fprintf(stderr,
                "#### APP-MOUNT fsgetpath process=%s host=%s visible=%s "
                "fsid=(%d,%d) object=%llu\n",
                getprogname() ?: "unknown", hostPath, buffer,
                fsid ? fsid->val[0] : 0, fsid ? fsid->val[1] : 0,
                (unsigned long long)objectID);
    }
    return result;
}

static void macws_install_launchpad_mount_namespace_compatibility(void) {
    // This compatibility belongs to application-catalog owners and to the
    // validated third-party AppKit launch transaction only.
    // Installing the fsgetpath trampoline in every AppKit process dirties the
    // libsystem_kernel __TEXT page that also contains mach_port_construct.
    // Runtime-confirmed on iPadOS 16.3: Terminal's fork child inherited that
    // COW page as r--/rw- and faulted at mach_port_construct+0 during
    // _pthread_main_thread_postfork_init.  Keep both halves of the namespace
    // model in the same narrowly-scoped filesystem-metadata consumers (Dock,
    // Finder, IconServices, lsd, launchservicesd, and Ventura locationd);
    // ordinary applications retain the stock kernel entry.
    if (!macws_needs_application_mount_namespace_compatibility()) return;

    const char *hostRoot = getenv("MACWS_CHROOT_HOST_ROOT");
    if (hostRoot && hostRoot[0] == '/' && strcmp(hostRoot, "/") != 0) {
        strlcpy(macws_chroot_host_root, hostRoot,
                sizeof(macws_chroot_host_root));
        void *fsgetpathSymbol = dlsym(RTLD_DEFAULT, "fsgetpath");
        if (fsgetpathSymbol) {
            MSHookFunction(fsgetpathSymbol,
                           (void *)macws_fsgetpath_namespace_compat,
                           (void **)&macws_fsgetpath_orig);
        }
    }

    void *statSymbol = dlsym(RTLD_DEFAULT, "statfs");
    if (!statSymbol) return;

    macws_lp_statfs_orig = (int (*)(const char *, struct statfs *))statSymbol;
    struct statfs rootFileSystem = {};
    if (macws_lp_statfs_orig("/", &rootFileSystem) != 0 ||
        strcmp(rootFileSystem.f_mntonname, "/") == 0) return;

    macws_chroot_root_mount_needs_rebase = YES;
    macws_chroot_root_fsid = rootFileSystem.f_fsid;
    strlcpy(macws_chroot_root_host_mount, rootFileSystem.f_mntonname,
            sizeof(macws_chroot_root_host_mount));

    void *fstatSymbol = dlsym(RTLD_DEFAULT, "fstatfs");
    if (fstatSymbol) {
        MSHookFunction(fstatSymbol, (void *)macws_lp_fstatfs_namespace_compat,
                       (void **)&macws_lp_fstatfs_orig);
    }
    MSHookFunction(statSymbol, (void *)macws_lp_statfs_namespace_compat,
                       (void **)&macws_lp_statfs_orig);

    macws_install_root_parent_namespace_compatibility();

    if (getenv("MACWS_LAUNCHPAD_TRACE") ||
        getenv("MACWS_APP_MOUNT_TRACE")) {
        fprintf(stderr,
                "#### APP-MOUNT chroot root process=%s hostMnton=%s "
                "visibleMnton=/ fsid=(%d,%d)\n",
                getprogname() ?: "unknown",
                macws_chroot_root_host_mount,
                macws_chroot_root_fsid.val[0],
                macws_chroot_root_fsid.val[1]);
    }
}

static const char *macws_lp_utf8(id value) {
    if (!value) return "<nil>";
    id description = ((id (*)(id, SEL))objc_msgSend)(
        value, sel_registerName("description"));
    if (!description) return "<no-description>";
    const char *text = ((const char *(*)(id, SEL))objc_msgSend)(
        description, sel_registerName("UTF8String"));
    return text ?: "<invalid-utf8>";
}

static NSInteger macws_lp_source_location(id source) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(
        source, sel_registerName("location"));
}

static id macws_lp_source_path(id source) {
    return ((id (*)(id, SEL))objc_msgSend)(
        source, sel_registerName("path"));
}

static BOOL macws_lp_source_online(id source) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(
        source, sel_registerName("online"));
}

static BOOL macws_lp_path_valid_trace(id self, SEL selector, id path) {
    BOOL valid = macws_lp_path_valid_orig(self, selector, path);
    fprintf(stderr, "#### LAUNCHPAD pathValid path=%s result=%s\n",
            macws_lp_utf8(path), valid ? "YES" : "NO");
    return valid;
}

static void macws_lp_source_common_init_trace(id self, SEL selector) {
    macws_lp_source_common_init_orig(self, selector);
    fprintf(stderr,
            "#### LAUNCHPAD source commonInit location=%ld path=%s online=%s\n",
            (long)macws_lp_source_location(self),
            macws_lp_utf8(macws_lp_source_path(self)),
            macws_lp_source_online(self) ? "YES" : "NO");
}

static void macws_lp_source_bring_online_trace(id self, SEL selector) {
    fprintf(stderr,
            "#### LAUNCHPAD source bringOnline enter location=%ld path=%s online=%s\n",
            (long)macws_lp_source_location(self),
            macws_lp_utf8(macws_lp_source_path(self)),
            macws_lp_source_online(self) ? "YES" : "NO");
    macws_lp_source_bring_online_orig(self, selector);
    fprintf(stderr,
            "#### LAUNCHPAD source bringOnline return location=%ld path=%s online=%s\n",
            (long)macws_lp_source_location(self),
            macws_lp_utf8(macws_lp_source_path(self)),
            macws_lp_source_online(self) ? "YES" : "NO");
}

static void macws_lp_source_rescan_trace(id self, SEL selector) {
    fprintf(stderr,
            "#### LAUNCHPAD source rescan location=%ld path=%s online=%s\n",
            (long)macws_lp_source_location(self),
            macws_lp_utf8(macws_lp_source_path(self)),
            macws_lp_source_online(self) ? "YES" : "NO");
    macws_lp_source_rescan_orig(self, selector);
}

static BOOL macws_lp_source_start_watching_trace(id self, SEL selector,
                                                 BOOL *newVolume) {
    id path = macws_lp_source_path(self);
    const char *fileSystemPath = path
        ? ((const char *(*)(id, SEL))objc_msgSend)(
              path, sel_registerName("fileSystemRepresentation"))
        : NULL;
    int descriptor = -1;
    int openError = 0;
    int statResult = -1;
    int statError = 0;
    struct statfs fs = {};
    char descriptorPath[MAXPATHLEN] = {};
    if (fileSystemPath) {
        descriptor = open(fileSystemPath, O_EVTONLY | O_CLOEXEC);
        openError = descriptor < 0 ? errno : 0;
        if (descriptor >= 0) {
            statResult = fstatfs(descriptor, &fs);
            statError = statResult < 0 ? errno : 0;
            (void)fcntl(descriptor, F_GETPATH, descriptorPath);
            close(descriptor);
        }
    }
    fprintf(stderr,
            "#### LAUNCHPAD watch preflight path=%s fdPath=%s open=%d "
            "openErr=%d stat=%d statErr=%d fsid=(%d,%d) mnton=%s "
            "mntfrom=%s fstype=%s\n",
            macws_lp_utf8(path), descriptorPath[0] ? descriptorPath : "<none>",
            descriptor, openError, statResult, statError,
            fs.f_fsid.val[0], fs.f_fsid.val[1],
            statResult == 0 ? fs.f_mntonname : "<none>",
            statResult == 0 ? fs.f_mntfromname : "<none>",
            statResult == 0 ? fs.f_fstypename : "<none>");

    BOOL result = macws_lp_source_start_watching_orig(
        self, selector, newVolume);
    fprintf(stderr,
            "#### LAUNCHPAD watch result path=%s result=%s newVolume=%s "
            "online=%s\n",
            macws_lp_utf8(path), result ? "YES" : "NO",
            newVolume ? (*newVolume ? "YES" : "NO") : "<null>",
            macws_lp_source_online(self) ? "YES" : "NO");
    return result;
}

static void macws_lp_scan_path_trace(id self, SEL selector, id path,
                                     id source, NSUInteger options,
                                     id completion) {
    fprintf(stderr,
            "#### LAUNCHPAD scan enter path=%s sourceLocation=%ld "
            "sourcePath=%s options=0x%lx completion=%p\n",
            macws_lp_utf8(path), (long)macws_lp_source_location(source),
            macws_lp_utf8(macws_lp_source_path(source)),
            (unsigned long)options, completion);
    macws_lp_scan_path_orig(self, selector, path, source, options, completion);
}

static BOOL macws_lp_replace_instance_method(Class cls, const char *name,
                                             IMP replacement, IMP *original) {
    BOOL traceInstall = getenv("MACWS_LAUNCHPAD_TRACE") != NULL ||
        getenv("MACWS_APP_LIFECYCLE_TRACE") != NULL ||
        getenv("MACWS_CATALYST_TRACE") != NULL;
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) {
        if (traceInstall) {
            fprintf(stderr, "#### MACWS-DIAG hook missing %s[%s %s]\n",
                    class_isMetaClass(cls) ? "+" : "-",
                    class_getName(cls), name);
        }
        return NO;
    }
    *original = method_setImplementation(method, replacement);
    if (traceInstall) {
        fprintf(stderr, "#### MACWS-DIAG hook installed %s[%s %s] original=%p\n",
                class_isMetaClass(cls) ? "+" : "-", class_getName(cls),
                name, *original);
    }
    return YES;
}

static void macws_install_launchpad_source_diagnostics(void) {
    const char *program = getprogname();
    if (!getenv("MACWS_LAUNCHPAD_TRACE") ||
        !program || strcmp(program, "Dock") != 0) return;

    Class manager = objc_getClass("LPAppManager");
    Class source = objc_getClass("LPAppSource");
    if (!manager || !source) {
        fprintf(stderr,
                "#### LAUNCHPAD trace classes unavailable manager=%p source=%p\n",
                manager, source);
        return;
    }

    macws_lp_replace_instance_method(
        manager, "pathValidForApplications:",
        (IMP)macws_lp_path_valid_trace, (IMP *)&macws_lp_path_valid_orig);
    macws_lp_replace_instance_method(
        source, "commonInit", (IMP)macws_lp_source_common_init_trace,
        (IMP *)&macws_lp_source_common_init_orig);
    macws_lp_replace_instance_method(
        source, "_bringOnlineIfPossible",
        (IMP)macws_lp_source_bring_online_trace,
        (IMP *)&macws_lp_source_bring_online_orig);
    macws_lp_replace_instance_method(
        source, "rescan", (IMP)macws_lp_source_rescan_trace,
        (IMP *)&macws_lp_source_rescan_orig);
    macws_lp_replace_instance_method(
        source, "_startWatchingForChanges:",
        (IMP)macws_lp_source_start_watching_trace,
        (IMP *)&macws_lp_source_start_watching_orig);
    macws_lp_replace_instance_method(
        manager, "scanForApplicationsAtPath:fromSource:options:completion:",
        (IMP)macws_lp_scan_path_trace, (IMP *)&macws_lp_scan_path_orig);
}

// Short-lived AppKit/SwiftUI lifecycle probe for applications that return
// cleanly before publishing a window.  It records real framework boundaries;
// it does not keep the process alive or alter delegate answers.
static void (*macws_app_run_orig)(id, SEL) = NULL;
static void (*macws_app_finish_launching_orig)(id, SEL) = NULL;
static void (*macws_app_terminate_orig)(id, SEL, id) = NULL;
static void (*macws_app_stop_orig)(id, SEL, id) = NULL;
static void (*macws_app_delegate_did_finish_orig)(id, SEL, id) = NULL;

static NSUInteger macws_app_window_count(id application) {
    id windows = ((id (*)(id, SEL))objc_msgSend)(
        application, sel_registerName("windows"));
    return windows ? ((NSUInteger (*)(id, SEL))objc_msgSend)(
        windows, sel_registerName("count")) : 0;
}

static void macws_app_run_trace(id self, SEL selector) {
    fprintf(stderr, "#### APP-LIFECYCLE NSApplication.run enter windows=%lu\n",
            (unsigned long)macws_app_window_count(self));
    macws_app_run_orig(self, selector);
    fprintf(stderr, "#### APP-LIFECYCLE NSApplication.run return windows=%lu\n",
            (unsigned long)macws_app_window_count(self));
}

static void macws_app_finish_launching_trace(id self, SEL selector) {
    fprintf(stderr,
            "#### APP-LIFECYCLE NSApplication.finishLaunching enter windows=%lu\n",
            (unsigned long)macws_app_window_count(self));
    macws_app_finish_launching_orig(self, selector);
    fprintf(stderr,
            "#### APP-LIFECYCLE NSApplication.finishLaunching return windows=%lu "
            "delegate=%s\n",
            (unsigned long)macws_app_window_count(self),
            macws_lp_utf8(((id (*)(id, SEL))objc_msgSend)(
                self, sel_registerName("delegate"))));
}

static void macws_app_log_termination(const char *method, id self) {
    fprintf(stderr, "#### APP-LIFECYCLE NSApplication.%s windows=%lu\n",
            method, (unsigned long)macws_app_window_count(self));
    void *frames[48] = {};
    int count = backtrace(frames, 48);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
}

static void macws_app_terminate_trace(id self, SEL selector, id sender) {
    macws_app_log_termination("terminate:", self);
    macws_app_terminate_orig(self, selector, sender);
}

static void macws_app_stop_trace(id self, SEL selector, id sender) {
    macws_app_log_termination("stop:", self);
    macws_app_stop_orig(self, selector, sender);
}

static void macws_app_delegate_did_finish_trace(id self, SEL selector,
                                                id notification) {
    fprintf(stderr,
            "#### APP-LIFECYCLE delegate didFinish enter class=%s\n",
            object_getClassName(self));
    macws_app_delegate_did_finish_orig(self, selector, notification);
    id applicationClass = objc_getClass("NSApplication");
    id application = applicationClass
        ? ((id (*)(id, SEL))objc_msgSend)(
              applicationClass, sel_registerName("sharedApplication"))
        : nil;
    fprintf(stderr,
            "#### APP-LIFECYCLE delegate didFinish return class=%s windows=%lu\n",
            object_getClassName(self),
            (unsigned long)macws_app_window_count(application));
}

static void macws_install_app_lifecycle_diagnostics(void) {
    if (!getenv("MACWS_APP_LIFECYCLE_TRACE")) return;
    const char *program = getprogname();
    if (!program || (strcmp(program, "System Settings") != 0 &&
                     strcmp(program, "Maps") != 0)) return;

    Class application = objc_getClass("NSApplication");
    if (application) {
        macws_lp_replace_instance_method(
            application, "run", (IMP)macws_app_run_trace,
            (IMP *)&macws_app_run_orig);
        macws_lp_replace_instance_method(
            application, "finishLaunching",
            (IMP)macws_app_finish_launching_trace,
            (IMP *)&macws_app_finish_launching_orig);
        macws_lp_replace_instance_method(
            application, "terminate:", (IMP)macws_app_terminate_trace,
            (IMP *)&macws_app_terminate_orig);
        macws_lp_replace_instance_method(
            application, "stop:", (IMP)macws_app_stop_trace,
            (IMP *)&macws_app_stop_orig);
    }

    const char *delegateName = strcmp(program, "System Settings") == 0
        ? "_TtC15System_Settings11AppDelegate" : "AppDelegate";
    Class delegate = objc_getClass(delegateName);
    if (delegate) {
        macws_lp_replace_instance_method(
            delegate, "applicationDidFinishLaunching:",
            (IMP)macws_app_delegate_did_finish_trace,
            (IMP *)&macws_app_delegate_did_finish_orig);
    } else {
        fprintf(stderr,
                "#### APP-LIFECYCLE delegate class unavailable program=%s "
                "class=%s\n", program, delegateName);
    }
}

// Focused Catalyst launch probe.  A direct Ventura Maps exec currently enters
// UIApplicationMain and then aborts in +[UIScreen mainScreen] while
// -_compellApplicationLaunchToCompleteUnconditionally is completing a nil
// FBSScene.  Observe the real UIKitMacHelper lifecycle immediately upstream;
// no return value, scene, screen, or delegate state is changed by this probe.
// It is opt-in because these framework-private boundaries are not on the
// production path once LaunchServices supplies a complete scene transaction.
static void (*macws_catalyst_compell_orig)(id, SEL) = NULL;
static id (*macws_catalyst_main_screen_orig)(id, SEL) = NULL;
static void (*macws_catalyst_uins_finish_orig)(id, SEL) = NULL;
static void (*macws_catalyst_uins_did_finish_orig)(id, SEL, id) = NULL;
static void (*macws_catalyst_request_scene_orig)(id, SEL, id, id) = NULL;
static _Atomic int macws_catalyst_initial_scene_request_state = 0;
static id (*macws_catalyst_endpoint_for_system_orig)(
    id, SEL, id, id, id) = NULL;
static id (*macws_catalyst_endpoint_for_mach_orig)(
    id, SEL, id, id, id) = NULL;
static id (*macws_weather_configuration_orig)(id, SEL, id, id, id) = NULL;
static void (*macws_weather_did_request_scene_orig)(
    id, SEL, id, id, id) = NULL;
static void (*macws_weather_uins_finish_launching_orig)(id, SEL) = NULL;
static sysdir_search_path_enumeration_state
    (*macws_weather_sysdir_start_private_orig)(
        sysdir_search_path_directory_t,
        sysdir_search_path_domain_mask_t) = NULL;
static char macws_weather_app_launch_delivered_key;
static char macws_weather_main_scene_identifier_key;
static char macws_weather_bootstrap_window_key;
static char macws_weather_bootstrap_delegate_key;
static char macws_weather_replaced_scene_delegate_key;
static _Atomic bool macws_weather_bootstrap_request_completed = false;
static _Atomic int macws_weather_uins_finish_state = 0;
static _Atomic unsigned macws_weather_uins_finish_attempts = 0;
static id macws_weather_pending_uins_finish_delegate = nil;
static SEL macws_weather_pending_uins_finish_selector = NULL;
static NSUInteger macws_catalyst_collection_count(id value);
static id macws_catalyst_send_id(id receiver, const char *selector);
static BOOL macws_weather_prepare_application_launch(id application,
                                                      id *delegateOut);
static BOOL macws_weather_adopt_bootstrap_scene(id application);
static BOOL macws_install_weather_uins_completion_hook(void);
static BOOL macws_install_weather_uins_finish_hook(void);
static void macws_weather_uins_finish_launching_compat(
    id self, SEL selector);
static void macws_weather_retry_uins_finish(void *context);

static void macws_weather_bootstrap_will_connect(
        id self, SEL selector, id scene, id session, id options) {
    (void)selector;
    (void)session;
    (void)options;
    Class windowClass = objc_getClass("UIWindow");
    Class controllerClass = objc_getClass("UIViewController");
    id window = windowClass
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              ((id (*)(id, SEL))objc_msgSend)(
                  (id)windowClass, sel_registerName("alloc")),
              sel_registerName("initWithWindowScene:"), scene)
        : nil;
    id controller = controllerClass
        ? ((id (*)(id, SEL))objc_msgSend)(
              ((id (*)(id, SEL))objc_msgSend)(
                  (id)controllerClass, sel_registerName("alloc")),
              sel_registerName("init"))
        : nil;
    if (window && controller) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            window, sel_registerName("setRootViewController:"), controller);
        ((void (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("makeKeyAndVisible"));
        objc_setAssociatedObject(
            self, &macws_weather_bootstrap_window_key, window,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fprintf(stderr,
            "#### WEATHER-SCENE bootstrap connected scene=%s window=%s "
            "controller=%s\n", scene ? object_getClassName(scene) : "nil",
            window ? object_getClassName(window) : "nil",
            controller ? object_getClassName(controller) : "nil");
    fflush(stderr);
}


static sysdir_search_path_enumeration_state
macws_weather_sysdir_start_private_compat(
    sysdir_search_path_directory_t directory,
    sysdir_search_path_domain_mask_t domainMask) {
    // Runtime-confirmed on iPadOS 16.3: the private entry point is a literal
    // `brk #1`. UIKit calls it for its scene-restoration Library search with
    // (directory=5, domain=1), while WeatherDaemon calls it with the macOS
    // private system-domain bit 0x10. The public sysdir ABI is implemented on
    // this same image and accepts the standard 1/2/4/8 domain mask. Route the
    // private ABI through that implementation, translating only the extra
    // macOS system-domain spelling.
    sysdir_search_path_domain_mask_t publicDomain = domainMask == 0x10
        ? SYSDIR_DOMAIN_MASK_SYSTEM : domainMask;
    sysdir_search_path_enumeration_state state =
        sysdir_start_search_path_enumeration(directory, publicDomain);
    fprintf(stderr,
            "#### WEATHER-SYSDIR translated directory=%u "
            "privateDomain=%#x publicDomain=%#x publicState=%#x\n",
            (unsigned)directory, (unsigned)domainMask,
            (unsigned)publicDomain, (unsigned)state);
    fflush(stderr);
    return state;
}

static NSArray *(*macws_weather_search_paths_orig)(NSUInteger, NSUInteger,
                                                    BOOL) = NULL;

static NSArray *macws_weather_search_paths_compat(NSUInteger directory,
                                                   NSUInteger domainMask,
                                                   BOOL expandTilde) {
    NSMutableArray *paths = [NSMutableArray array];
    sysdir_search_path_enumeration_state state =
        sysdir_start_search_path_enumeration(
            (sysdir_search_path_directory_t)directory,
            (sysdir_search_path_domain_mask_t)domainMask);
    while (state != 0) {
        char path[PATH_MAX] = {0};
        state = sysdir_get_next_search_path_enumeration(state, path);
        if (!path[0]) continue;
        NSString *value = [NSString stringWithUTF8String:path];
        if (expandTilde) value = [value stringByExpandingTildeInPath];
        if (value) [paths addObject:value];
    }
    return paths;
}

static id macws_catalyst_private_frontboard_name(id machName) {
    if (!machName || !((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            machName, sel_registerName("respondsToSelector:"),
            sel_registerName("UTF8String"))) return machName;
    const char *value = ((const char *(*)(id, SEL))objc_msgSend)(
        machName, sel_registerName("UTF8String"));
    if (!value || strcmp(value,
                         "com.apple.frontboard.systemappservices") != 0)
        return machName;
    Class stringClass = objc_getClass("NSString");
    return stringClass
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              "com.apple.macosbooter.frontboard.systemappservices")
        : machName;
}

static Class macws_weather_bootstrap_scene_delegate_class(void) {
    Class existing = objc_getClass("MacWSWeatherBootstrapSceneDelegate");
    if (existing) return existing;
    Class base = objc_getClass("NSObject");
    if (!base) return Nil;
    Class created = objc_allocateClassPair(
        base, "MacWSWeatherBootstrapSceneDelegate", 0);
    if (!created) return objc_getClass(
        "MacWSWeatherBootstrapSceneDelegate");
    class_addMethod(
        created,
        sel_registerName("scene:willConnectToSession:options:"),
        (IMP)macws_weather_bootstrap_will_connect, "v@:@@@");
    objc_registerClassPair(created);
    return created;
}

// Retain the later configuration hook as a second, causally equivalent entry
// point for OS builds that do ask Weather for a replacement configuration.
static id macws_weather_configuration_compat(id self, SEL selector,
                                              id application, id session,
                                              id options) {
    BOOL needsBootstrap = !objc_getAssociatedObject(
        self, &macws_weather_app_launch_delivered_key);
    id result = nil;
    Class bootstrapDelegateClass = needsBootstrap
        ? macws_weather_bootstrap_scene_delegate_class() : Nil;
    if (!needsBootstrap) {
        result = macws_weather_configuration_orig(
            self, selector, application, session, options);
    } else {
        Class configurationClass = objc_getClass("UISceneConfiguration");
        Class windowSceneClass = objc_getClass("UIWindowScene");
        id role = macws_catalyst_send_id(session, "role");
        id name = ((id (*)(id, SEL, const char *))objc_msgSend)(
            (id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"),
            "MacWS Catalyst Bootstrap");
        SEL initializer = sel_registerName("initWithName:sessionRole:");
        id bootstrap = configurationClass
            ? ((id (*)(id, SEL, id, id))objc_msgSend)(
                  ((id (*)(id, SEL))objc_msgSend)(
                      (id)configurationClass, sel_registerName("alloc")),
                  initializer, name, role)
            : nil;
        if (bootstrap && windowSceneClass && bootstrapDelegateClass) {
            ((void (*)(id, SEL, Class))objc_msgSend)(
                bootstrap, sel_registerName("setSceneClass:"),
                windowSceneClass);
            // A nil delegate falls back to SwiftUI.AppSceneDelegate, which
            // evaluates Weather's root view while the AppDelegate resolver is
            // still uninitialized and runtime-confirmed traps at Weather
            // +0x538e34. Use a runtime-created inert delegate instead. This
            // first scene exists only to let UIKit establish UIScreen;
            // Weather.SceneDelegate takes ownership immediately afterward.
            ((void (*)(id, SEL, Class))objc_msgSend)(
                bootstrap, sel_registerName("setDelegateClass:"),
                bootstrapDelegateClass);
            result = bootstrap;
        }
    }
    id name = macws_catalyst_send_id(result, "name");
    id scenes = macws_catalyst_send_id(application, "connectedScenes");
    id scene = macws_catalyst_send_id(scenes, "anyObject");
    id existingDelegate = macws_catalyst_send_id(scene, "delegate");
    id delegateClass = macws_catalyst_send_id(result, "delegateClass");
    if (needsBootstrap && scene && bootstrapDelegateClass &&
        (!existingDelegate || !((BOOL (*)(id, SEL, Class))objc_msgSend)(
            existingDelegate, sel_registerName("isKindOfClass:"),
            bootstrapDelegateClass))) {
        id bootstrapDelegate = ((id (*)(id, SEL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(
                (id)bootstrapDelegateClass, sel_registerName("alloc")),
            sel_registerName("init"));
        SEL setDelegate = sel_registerName("setDelegate:");
        if (bootstrapDelegate && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
                scene, sel_registerName("respondsToSelector:"),
                setDelegate)) {
            // Runtime-confirmed in Weather pid 92995: UIKit asked the
            // AppDelegate for our bootstrap configuration while the already
            // connected scene still owned SwiftUI.AppSceneDelegate, then
            // exited without ever invoking the returned delegate class.
            // Complete that real scene's requested configuration through
            // UIScene's native strong setter and standard willConnect callback.
            fprintf(stderr,
                    "#### WEATHER-SCENE replacing initial delegate old=%s@%p "
                    "new=%s@%p scene=%p\n",
                    existingDelegate ? object_getClassName(existingDelegate)
                                     : "nil",
                    existingDelegate,
                    object_getClassName(bootstrapDelegate),
                    bootstrapDelegate, scene);
            fflush(stderr);
            // UIKit created this SwiftUI delegate as the scene-lifetime owner
            // before it asked the late Weather AppDelegate for a corrected
            // configuration. Replacing UIScene.delegate releases that owner,
            // while its already-scheduled AttributeGraph update still holds
            // unowned references into the graph. Keep the native owner tied
            // to the same scene lifetime while Weather.SceneDelegate assumes
            // callback responsibility below. This is a bounded ownership
            // transfer, not a per-frame or process-global retention.
            if (existingDelegate) {
                objc_setAssociatedObject(
                    scene, &macws_weather_replaced_scene_delegate_key,
                    existingDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            ((void (*)(id, SEL, id))objc_msgSend)(
                scene, setDelegate, bootstrapDelegate);
            objc_setAssociatedObject(
                scene, &macws_weather_bootstrap_delegate_key,
                bootstrapDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            macws_weather_bootstrap_will_connect(
                bootstrapDelegate,
                sel_registerName("scene:willConnectToSession:options:"),
                scene, session, options);
            existingDelegate = bootstrapDelegate;

            // The scene-create transaction does not yield back to the main
            // queue before AppKit evaluates launch completion; pid 93274
            // exited after this callback while the scheduled 10 ms adoption
            // never ran. At this point UIWindowScene, its FUScene identifier
            // and a real bootstrap UIWindow all exist, so complete the held
            // UINS launch synchronously at the same configuration boundary.
            if (atomic_load_explicit(
                    &macws_weather_uins_finish_state,
                    memory_order_acquire) == 1 &&
                macws_weather_pending_uins_finish_delegate &&
                macws_weather_pending_uins_finish_selector) {
                macws_weather_uins_finish_launching_compat(
                    macws_weather_pending_uins_finish_delegate,
                    macws_weather_pending_uins_finish_selector);
                existingDelegate = macws_catalyst_send_id(
                    scene, "delegate");
            }
        }
    }
    fprintf(stderr,
            "#### WEATHER-SCENE configuration result=%s name=%s "
            "delegate=%s connected=%lu existing=%s adopted=%s windows=%lu\n",
            result ? object_getClassName(result) : "nil",
            name ? ((const char *(*)(id, SEL))objc_msgSend)(
                name, sel_registerName("UTF8String")) : "<nil>",
            delegateClass ? class_getName((Class)delegateClass) : "<nil>",
            (unsigned long)macws_catalyst_collection_count(scenes),
            existingDelegate ? object_getClassName(existingDelegate) : "nil",
            "deferred",
            (unsigned long)macws_catalyst_collection_count(
                macws_catalyst_send_id(application, "windows")));
    fflush(stderr);
    return result;
}

static void macws_weather_did_request_scene_compat(
        id self, SEL selector, id options, id sceneIdentifier, id error) {
    macws_weather_did_request_scene_orig(
        self, selector, options, sceneIdentifier, error);
    // Runtime-confirmed in Weather PID 68870: UIApplication.connectedScenes
    // became non-empty before UINS completed this callback. Adopting the scene
    // at that earlier observation caused UINS to open a second creation
    // transaction with a different persistent ID. This native callback is the
    // transaction boundary at which UINS has logged didRequestSceneWithOptions
    // and removed the first request from its creation tracker.
    bool first = !atomic_exchange_explicit(
        &macws_weather_bootstrap_request_completed, true,
        memory_order_acq_rel);
    if (first) {
        fprintf(stderr,
                "#### WEATHER-SCENE bootstrap request completed "
                "identifier=%s error=%s\n",
                sceneIdentifier ? object_getClassName(sceneIdentifier) : "nil",
                error ? object_getClassName(error) : "nil");
        fflush(stderr);
    }
}

static BOOL macws_install_weather_uins_completion_hook(void) {
    if (macws_weather_did_request_scene_orig) return YES;
    Class uinsDelegate = objc_getClass("UINSApplicationDelegate");
    if (!uinsDelegate) return NO;
    BOOL installed = macws_lp_replace_instance_method(
        uinsDelegate,
        "didRequestSceneWithOptions:sceneIdentifier:orError:",
        (IMP)macws_weather_did_request_scene_compat,
        (IMP *)&macws_weather_did_request_scene_orig);
    fprintf(stderr,
            "#### WEATHER-SCENE completion-hook installed=%d class=%s "
            "original=%p\n", installed,
            class_getName(uinsDelegate),
            macws_weather_did_request_scene_orig);
    fflush(stderr);
    return installed;
}

static void macws_weather_uins_finish_launching_compat(
        id self, SEL selector) {
    Class applicationClass = objc_getClass("UIApplication");
    id application = applicationClass
        ? macws_catalyst_send_id((id)applicationClass,
                                  "sharedApplication") : nil;
    id scenes = macws_catalyst_send_id(application, "connectedScenes");
    id bootstrapScene = macws_catalyst_send_id(scenes, "anyObject");
    id sceneIdentifier = macws_catalyst_send_id(
        bootstrapScene, "_sceneIdentifier");
    if (!sceneIdentifier) {
        int state = atomic_load_explicit(
            &macws_weather_uins_finish_state, memory_order_acquire);
        if (state == 0) {
            int expected = 0;
            if (atomic_compare_exchange_strong_explicit(
                    &macws_weather_uins_finish_state, &expected, 1,
                    memory_order_acq_rel, memory_order_acquire)) {
                macws_weather_pending_uins_finish_delegate = self;
                macws_weather_pending_uins_finish_selector = selector;
                atomic_store_explicit(
                    &macws_weather_uins_finish_attempts, 0,
                    memory_order_release);
                dispatch_after_f(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  10 * NSEC_PER_MSEC),
                    dispatch_get_main_queue(), NULL,
                    macws_weather_retry_uins_finish);
                fprintf(stderr,
                        "#### WEATHER-SCENE finish-launch deferred "
                        "reason=bootstrap-not-connected\n");
                fflush(stderr);
            }
        }
        return;
    }
    Ivar mainSceneIdentifier = class_getInstanceVariable(
        object_getClass(self), "_mainSceneIdentifier");
    id oldIdentifier = mainSceneIdentifier
        ? object_getIvar(self, mainSceneIdentifier) : nil;
    BOOL synchronized = NO;
    if (!oldIdentifier && sceneIdentifier && mainSceneIdentifier) {
        // RE-confirmed via the target Ventura 13.4 UIKitMacHelper:
        // UINSApplicationDelegate's runtime ivar table names offset +0x40
        // `_mainSceneIdentifier`; -_finishLaunching at image +0x4fd4 loads
        // that exact field and requests a second initial scene only when it is
        // nil. The FUScene identifier below comes from the already registered
        // UIWindowScene, so this restores UINS's missing bookkeeping rather
        // than fabricating a scene or bypassing its launch work.
        object_setIvar(self, mainSceneIdentifier, sceneIdentifier);
        objc_setAssociatedObject(
            self, &macws_weather_main_scene_identifier_key,
            sceneIdentifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        synchronized = object_getIvar(self, mainSceneIdentifier) ==
            sceneIdentifier;
    } else if (oldIdentifier) {
        synchronized = YES;
    }

    BOOL adopted = synchronized && application &&
        macws_weather_adopt_bootstrap_scene(application);
    const char *identifierString = sceneIdentifier &&
        ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            sceneIdentifier, sel_registerName("respondsToSelector:"),
            sel_registerName("UTF8String"))
        ? ((const char *(*)(id, SEL))objc_msgSend)(
              sceneIdentifier, sel_registerName("UTF8String")) : NULL;
    fprintf(stderr,
            "#### WEATHER-SCENE finish-launch synchronize=%d adopted=%d "
            "scene=%s connected=%lu old=%s\n",
            synchronized, adopted, identifierString ?: "nil",
            (unsigned long)macws_catalyst_collection_count(scenes),
            oldIdentifier ? object_getClassName(oldIdentifier) : "nil");
    fflush(stderr);

    // Preserve UIKitMacHelper's complete launch finalization. With its real
    // main-scene invariant restored, the original follows its native existing
    // scene branch instead of opening a conflicting second transaction.
    atomic_store_explicit(
        &macws_weather_uins_finish_state, 2, memory_order_release);
    macws_weather_uins_finish_launching_orig(self, selector);
    macws_weather_pending_uins_finish_delegate = nil;
    macws_weather_pending_uins_finish_selector = NULL;
}

static void macws_weather_retry_uins_finish(void *context) {
    (void)context;
    id delegate = macws_weather_pending_uins_finish_delegate;
    SEL selector = macws_weather_pending_uins_finish_selector;
    if (!delegate || !selector || atomic_load_explicit(
            &macws_weather_uins_finish_state,
            memory_order_acquire) != 1) return;
    unsigned attempt = atomic_fetch_add_explicit(
        &macws_weather_uins_finish_attempts, 1,
        memory_order_acq_rel) + 1;
    Class applicationClass = objc_getClass("UIApplication");
    id application = applicationClass
        ? macws_catalyst_send_id((id)applicationClass,
                                  "sharedApplication") : nil;
    BOOL connected = macws_catalyst_collection_count(
        macws_catalyst_send_id(application, "connectedScenes")) > 0;
    if (connected) {
        macws_weather_uins_finish_launching_compat(delegate, selector);
        return;
    }
    if (attempt < 200) {
        dispatch_after_f(
            dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), NULL,
            macws_weather_retry_uins_finish);
        return;
    }

    // A missing bootstrap after two seconds is a distinct failure. Run the
    // original launch method unchanged so UIKit reports its native error; do
    // not leave the application silently suspended behind this compatibility
    // transaction.
    fprintf(stderr,
            "#### WEATHER-SCENE finish-launch bootstrap timeout polls=%u\n",
            attempt);
    fflush(stderr);
    atomic_store_explicit(
        &macws_weather_uins_finish_state, 2, memory_order_release);
    macws_weather_uins_finish_launching_orig(delegate, selector);
    macws_weather_pending_uins_finish_delegate = nil;
    macws_weather_pending_uins_finish_selector = NULL;
}

static BOOL macws_install_weather_uins_finish_hook(void) {
    if (macws_weather_uins_finish_launching_orig) return YES;
    Class uinsDelegate = objc_getClass("UINSApplicationDelegate");
    if (!uinsDelegate) return NO;
    BOOL installed = macws_lp_replace_instance_method(
        uinsDelegate, "_finishLaunching",
        (IMP)macws_weather_uins_finish_launching_compat,
        (IMP *)&macws_weather_uins_finish_launching_orig);
    fprintf(stderr,
            "#### WEATHER-SCENE finish-hook installed=%d class=%s "
            "original=%p\n", installed, class_getName(uinsDelegate),
            macws_weather_uins_finish_launching_orig);
    fflush(stderr);
    return installed;
}

static void macws_install_weather_scene_compatibility(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "Weather") != 0) return;
    void *privateSysdir = dlsym(
        RTLD_DEFAULT, "sysdir_start_search_path_enumeration_private");
    if (privateSysdir) {
        MSHookFunction(
            privateSysdir,
            (void *)macws_weather_sysdir_start_private_compat,
            (void **)&macws_weather_sysdir_start_private_orig);
    }
    void *searchPaths = dlsym(
        RTLD_DEFAULT, "NSSearchPathForDirectoriesInDomains");
    if (searchPaths) {
        MSHookFunction(searchPaths,
                       (void *)macws_weather_search_paths_compat,
                       (void **)&macws_weather_search_paths_orig);
    }
    Class appDelegate = objc_getClass("_TtC7Weather11AppDelegate");
    if (appDelegate) {
        macws_lp_replace_instance_method(
            appDelegate,
            "application:configurationForConnectingSceneSession:options:",
            (IMP)macws_weather_configuration_compat,
            (IMP *)&macws_weather_configuration_orig);
    }
    // UIKitMacHelper may not have registered UINSApplicationDelegate when
    // this constructor first runs. Retry at the actual scene-request boundary
    // below, where the class is necessarily available to the caller.
    (void)macws_install_weather_uins_completion_hook();
    (void)macws_install_weather_uins_finish_hook();
}

static id macws_catalyst_endpoint_for_system_route(
    id self, SEL selector, id machName, id service, id instance) {
    id routedName = macws_catalyst_private_frontboard_name(machName);
    if (routedName != machName && getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-FRONTBOARD endpoint system route=%s "
                "service=%s\n",
                ((const char *(*)(id, SEL))objc_msgSend)(
                    routedName, sel_registerName("UTF8String")),
                service ? ((const char *(*)(id, SEL))objc_msgSend)(
                    service, sel_registerName("UTF8String")) : "<nil>");
    }
    return macws_catalyst_endpoint_for_system_orig(
        self, selector, routedName, service, instance);
}

static id macws_catalyst_endpoint_for_mach_route(
    id self, SEL selector, id machName, id service, id instance) {
    id routedName = macws_catalyst_private_frontboard_name(machName);
    if (routedName != machName && getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-FRONTBOARD endpoint route=%s service=%s\n",
                ((const char *(*)(id, SEL))objc_msgSend)(
                    routedName, sel_registerName("UTF8String")),
                service ? ((const char *(*)(id, SEL))objc_msgSend)(
                    service, sel_registerName("UTF8String")) : "<nil>");
    }
    return macws_catalyst_endpoint_for_mach_orig(
        self, selector, routedName, service, instance);
}

static void macws_install_catalyst_frontboard_route(void) {
    // UINSWorkspace is the macOS Catalyst workspace.  Install for every
    // Catalyst process, not just Maps, at the endpoint-construction boundary
    // identified by the actual BoardServices runtime method list.  Ordinary
    // AppKit and iOS processes do not realize UINSWorkspace and are untouched.
    if (!objc_getClass("UINSWorkspace") ||
        !objc_getClass("UIApplication")) return;
    Class endpointClass = objc_getClass("BSServiceConnectionEndpoint");
    if (!endpointClass) return;
    Class metaClass = object_getClass(endpointClass);
    macws_lp_replace_instance_method(
        metaClass, "endpointForSystemMachName:service:instance:",
        (IMP)macws_catalyst_endpoint_for_system_route,
        (IMP *)&macws_catalyst_endpoint_for_system_orig);
    macws_lp_replace_instance_method(
        metaClass, "endpointForMachName:service:instance:",
        (IMP)macws_catalyst_endpoint_for_mach_route,
        (IMP *)&macws_catalyst_endpoint_for_mach_orig);
}

// A UIKit application carrier enters UIApplicationMain before SETEXEC replaces
// its image with a Mac Catalyst executable.  The numeric PID and launchd job
// survive, but the kernel's versioned PID (pid + exec generation) changes.
//
// RE-confirmed in Ventura 13.4 FrontBoard on the target iPad:
//   -[FBProcessManager processForVersionedPID:] first looks in the exact-vpid
//   map at self+0x58, then falls back to the bare-pid map at self+0x50 and
//   returns that stale process while logging
//   "Returning ..., even though it does not match provided vpid ...".
//   -[FBProcessManager registerProcessForAuditToken:] treats any non-nil result
//   as registered and returns early.  Even after an exact miss is forced,
//   +[RBSProcessHandle handleForIdentifier:error:] reuses UIKitSystem's cached
//   pre-SETEXEC handle and _bootstrapProcessWithHandle: recreates the old vpid.
//
// RBS itself deliberately keeps the launcher's application identity across
// SETEXEC, so asking runningboardd for the bare PID again cannot manufacture a
// new exec generation.  Deleting that FBProcess is also wrong: _removeProcess:
// broadcasts an exit and RunningBoard terminates the still-live carrier.
//
// Runtime-confirmed on the target iPad: the post-SETEXEC handle returned for
// Maps contains the base RBSProcessIdentity class, whose -isApplication method
// is literally `mov w0, #0; ret`.  RunningBoard's own
// +identityForEmbeddedApplicationIdentifier: factory instead returns an
// RBSEmbeddedAppProcessIdentity for com.apple.Maps with isApplication=YES,
// isEmbeddedApplication=YES and platform=0.  Build the new process instance
// from that framework-created identity and replace only the stale audit-token
// snapshot.  Ventura's real RBSProcessHandle initializer accepts an
// RBSProcessInstance plus an RBSAuditToken and derives its PID/euid from the
// latter.  We make a non-cached handle for the exact audit token, then pass it
// through FrontBoard's own _reallyRegisterProcessForHandle: bootstrap path.
// The refresh hook itself checks the exact generation before returning early;
// processForVersionedPID: otherwise retains FrontBoard's stock bare-PID
// fallback.  That fallback is required after SETEXEC because the already-open
// UIKit workspace transports still identify the carrier's preceding exec
// generation while the refreshed FBProcess owns the current generation.  No
// process is deleted and no UIKit/RBS predicate is forced true.
typedef uint64_t (*macws_bs_versioned_pid_for_audit_token_fn)(
    const audit_token_t *token);
typedef id (*macws_fb_register_process_for_audit_token_fn)(
    id self, SEL selector, const audit_token_t *token);
typedef id (*macws_fb_process_for_versioned_pid_fn)(
    id self, SEL selector, uint64_t versionedPID);
typedef id (*macws_rbs_handle_for_identifier_fn)(
    id self, SEL selector, id identifier, NSError **error);
typedef id (*macws_rbs_fu_handle_for_identifier_fn)(
    id self, SEL selector, id identifier);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static macws_bs_versioned_pid_for_audit_token_fn
    macws_bs_versioned_pid_for_audit_token = NULL;
static macws_fb_register_process_for_audit_token_fn
    macws_fb_register_process_for_audit_token_orig = NULL;
static macws_fb_process_for_versioned_pid_fn
    macws_fb_process_for_versioned_pid_orig = NULL;
static macws_rbs_handle_for_identifier_fn
    macws_rbs_handle_for_identifier_orig = NULL;
static macws_rbs_fu_handle_for_identifier_fn
    macws_rbs_fu_handle_for_identifier_orig = NULL;
static _Atomic BOOL macws_uikitsystem_exec_identity_hook_installed = NO;
static _Atomic BOOL macws_uikitsystem_fu_handle_hook_installed = NO;
static pthread_mutex_t macws_catalyst_rbs_handle_lock =
    PTHREAD_MUTEX_INITIALIZER;
// UIKitSystem processes one foreground Catalyst bootstrap at a time.  Keep
// the original, proven single-handle lifetime contract.  THEORY under A/B:
// retaining several private RBS handles may extend stale CoreServices bundle
// graphs; the generalized-table build repeatedly crashed in
// _FileCacheFinalize, while the pre-table build stayed alive.  Preserve the
// old ownership shape while separately testing the marker/identity changes.
// A new exact audit-token generation atomically replaces the prior snapshot.
static id macws_catalyst_current_rbs_handle = nil;
static pid_t macws_catalyst_current_rbs_pid = -1;
static uint64_t macws_catalyst_current_rbs_versioned_pid = UINT64_MAX;

static BOOL macws_valid_catalyst_bundle_identifier(const char *identifier) {
    if (!identifier || !*identifier || strlen(identifier) > 255) return NO;
    for (const unsigned char *cursor =
             (const unsigned char *)identifier; *cursor; cursor++) {
        if ((*cursor >= 'a' && *cursor <= 'z') ||
            (*cursor >= 'A' && *cursor <= 'Z') ||
            (*cursor >= '0' && *cursor <= '9') ||
            *cursor == '.' || *cursor == '-') continue;
        return NO;
    }
    return YES;
}

static BOOL macws_valid_catalyst_executable_path(const char *path) {
    if (!path ||
        (strncmp(path, "/Applications/", 14) != 0 &&
         strncmp(path, "/System/Applications/", 21) != 0) ||
        !strstr(path, ".app/Contents/MacOS/") ||
        strstr(path, "/../") || strchr(path, '\n')) return NO;
    return YES;
}

// A generic Catalyst child is admitted only when the setuid launcher wrote a
// root-owned, PID-scoped marker before replacing itself with launchdchrootexec.
// The marker's path must exactly equal proc_pidpath for the live audit-token
// PID. Maps keeps its historical exact-path admission so upgrades do not make
// the already-proven production route depend on a new marker format.
static BOOL macws_live_chroot_catalyst_identity(
        pid_t pid, char *path, size_t pathCapacity,
        char *bundleIdentifier, size_t bundleCapacity) {
    if (pid <= 0 || !path || pathCapacity == 0) return NO;
    path[0] = '\0';
    int length = proc_pidpath(pid, path, (uint32_t)pathCapacity);
    if (length <= 0 || (size_t)length >= pathCapacity) return NO;
    path[pathCapacity - 1] = '\0';
    if (strcmp(path,
               "/System/Applications/Maps.app/Contents/MacOS/Maps") == 0) {
        if (!bundleIdentifier || bundleCapacity <= strlen("com.apple.Maps"))
            return NO;
        strlcpy(bundleIdentifier, "com.apple.Maps", bundleCapacity);
        return YES;
    }
    if (!macws_valid_catalyst_executable_path(path) ||
        !bundleIdentifier || bundleCapacity == 0) return NO;

    char markerPath[PATH_MAX] = {0};
    int markerLength = snprintf(
        markerPath, sizeof(markerPath),
        "/private/tmp/macws_catalyst_child.%d.info", pid);
    if (markerLength <= 0 || (size_t)markerLength >= sizeof(markerPath))
        return NO;
    int marker = open(markerPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (marker < 0) return NO;
    struct stat markerStatus = {0};
    char payload[PATH_MAX + 512] = {0};
    ssize_t count = read(marker, payload, sizeof(payload) - 1);
    int statusResult = fstat(marker, &markerStatus);
    close(marker);
    if (count <= 0 || (size_t)count >= sizeof(payload) ||
        statusResult != 0 || !S_ISREG(markerStatus.st_mode) ||
        markerStatus.st_uid != 0 || (markerStatus.st_mode & 022) != 0 ||
        markerStatus.st_nlink != 1) return NO;
    payload[count] = '\0';
    if (strncmp(payload, "v1\n", 3) != 0) return NO;
    char *recordedPath = payload + 3;
    char *pathEnd = strchr(recordedPath, '\n');
    if (!pathEnd) return NO;
    *pathEnd = '\0';
    char *recordedBundle = pathEnd + 1;
    char *bundleEnd = strchr(recordedBundle, '\n');
    if (!bundleEnd || bundleEnd[1] != '\0') return NO;
    *bundleEnd = '\0';
    if (strcmp(recordedPath, path) != 0 ||
        !macws_valid_catalyst_bundle_identifier(recordedBundle) ||
        strlen(recordedBundle) >= bundleCapacity) return NO;
    strlcpy(bundleIdentifier, recordedBundle, bundleCapacity);
    return YES;
}

static uint64_t macws_fb_process_versioned_pid(id process) {
    if (!process) return UINT64_MAX;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(
        process, sel_registerName("versionedPID"));
}

static uint64_t macws_rbs_handle_versioned_pid(id handle) {
    if (!handle) return UINT64_MAX;
    SEL selector = sel_registerName("fu_versionedPID");
    if (!((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            handle, sel_registerName("respondsToSelector:"), selector))
        selector = sel_registerName("versionedPID");
    if (!((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            handle, sel_registerName("respondsToSelector:"), selector))
        return UINT64_MAX;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(handle, selector);
}

static void macws_publish_catalyst_rbs_handle(id handle, pid_t pid) {
    if (!handle || pid <= 0) return;
    id retainedHandle = ((id (*)(id, SEL))objc_msgSend)(
        handle, sel_registerName("retain"));
    uint64_t versionedPID = macws_rbs_handle_versioned_pid(handle);
    pthread_mutex_lock(&macws_catalyst_rbs_handle_lock);
    id previousHandle = macws_catalyst_current_rbs_handle;
    macws_catalyst_current_rbs_handle = retainedHandle;
    macws_catalyst_current_rbs_pid = pid;
    macws_catalyst_current_rbs_versioned_pid = versionedPID;
    pthread_mutex_unlock(&macws_catalyst_rbs_handle_lock);
    if (previousHandle) {
        ((void (*)(id, SEL))objc_msgSend)(
            previousHandle, sel_registerName("release"));
    }
}

// Returns an autoreleased strong snapshot so replacement of the process-wide
// cache on a later Maps launch cannot race a current FuseBoard lookup.
static id macws_copy_exact_catalyst_rbs_handle(
    pid_t pid, uint64_t requestedVersionedPID) {
    pthread_mutex_lock(&macws_catalyst_rbs_handle_lock);
    id handle = nil;
    if (macws_catalyst_current_rbs_handle &&
        macws_catalyst_current_rbs_pid == pid &&
        macws_catalyst_current_rbs_versioned_pid == requestedVersionedPID) {
        handle = ((id (*)(id, SEL))objc_msgSend)(
            macws_catalyst_current_rbs_handle, sel_registerName("retain"));
    }
    pthread_mutex_unlock(&macws_catalyst_rbs_handle_lock);
    return handle
        ? ((id (*)(id, SEL))objc_msgSend)(
              handle, sel_registerName("autorelease"))
        : nil;
}

// RE-confirmed in Ventura 13.4 RunningBoardServices:
// -[RBSProcessHandle initWithInstance:auditToken:bundleData:...]+432 passes
// bundleData to +[RBSProcessBundle bundleWithDataSource:].  That factory then
// immediately sends bundleIdentifier, bundlePath, executablePath and
// extensionPointIdentifier to the data source and stores strong snapshots of
// the returned strings.  Runtime tracing of the first generic Asphalt launch
// showed bundleData=0x0 immediately before FrontBoard's repository manager
// repeatedly died in _FileCacheFinalize.  Supply the real bundle metadata at
// the constructor boundary instead of asking the repository to infer a chroot
// bundle from an empty RBSProcessBundle.
static char macws_catalyst_bundle_identifier_key;
static char macws_catalyst_bundle_path_key;
static char macws_catalyst_executable_path_key;
static char macws_catalyst_bundle_data_source_owner_key;

static id macws_catalyst_bundle_identifier_value(id self, SEL selector) {
    (void)selector;
    return objc_getAssociatedObject(
        self, &macws_catalyst_bundle_identifier_key);
}

static id macws_catalyst_bundle_path_value(id self, SEL selector) {
    (void)selector;
    return objc_getAssociatedObject(self, &macws_catalyst_bundle_path_key);
}

static id macws_catalyst_executable_path_value(id self, SEL selector) {
    (void)selector;
    return objc_getAssociatedObject(
        self, &macws_catalyst_executable_path_key);
}

static id macws_catalyst_no_extension_point(id self, SEL selector) {
    (void)self;
    (void)selector;
    return nil;
}

static id macws_catalyst_no_bundle_info_value(
        id self, SEL selector, id key) {
    (void)self;
    (void)selector;
    (void)key;
    return nil;
}

// Returns a retained object. RBSProcessBundle keeps only a weak reference to
// its source, so the resulting RBSProcessHandle owns it through an associated
// object for exactly the handle's lifetime.
static id macws_create_catalyst_bundle_data_source(
        const char *executablePath, const char *bundleIdentifier) {
    if (!executablePath || !bundleIdentifier) return nil;
    const char *contents = strstr(
        executablePath, ".app/Contents/MacOS/");
    if (!contents) return nil;
    size_t bundlePathLength = (size_t)(contents - executablePath) + 4;
    if (bundlePathLength == 0 || bundlePathLength >= PATH_MAX) return nil;
    char bundlePath[PATH_MAX] = {0};
    memcpy(bundlePath, executablePath, bundlePathLength);
    bundlePath[bundlePathLength] = '\0';

    static Class dataSourceClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superclass = objc_getClass("NSObject");
        Class created = superclass
            ? objc_allocateClassPair(
                  superclass, "MacWSCatalystBundleDataSource", 0)
            : Nil;
        if (!created) {
            dataSourceClass = objc_getClass(
                "MacWSCatalystBundleDataSource");
            return;
        }
        class_addMethod(created, sel_registerName("bundleIdentifier"),
                        (IMP)macws_catalyst_bundle_identifier_value, "@@:");
        class_addMethod(created, sel_registerName("bundlePath"),
                        (IMP)macws_catalyst_bundle_path_value, "@@:");
        class_addMethod(created, sel_registerName("executablePath"),
                        (IMP)macws_catalyst_executable_path_value, "@@:");
        class_addMethod(created,
                        sel_registerName("extensionPointIdentifier"),
                        (IMP)macws_catalyst_no_extension_point, "@@:");
        class_addMethod(created, sel_registerName("bundleInfoValueForKey:"),
                        (IMP)macws_catalyst_no_bundle_info_value, "@@:@");
        objc_registerClassPair(created);
        dataSourceClass = created;
    });
    if (!dataSourceClass) return nil;

    id source = ((id (*)(id, SEL))objc_msgSend)(
        (id)dataSourceClass, sel_registerName("alloc"));
    source = ((id (*)(id, SEL))objc_msgSend)(
        source, sel_registerName("init"));
    Class stringClass = objc_getClass("NSString");
    id identifier = stringClass
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              bundleIdentifier)
        : nil;
    id path = stringClass
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              bundlePath)
        : nil;
    id executable = stringClass
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              executablePath)
        : nil;
    if (!source || !identifier || !path || !executable) {
        if (source) ((void (*)(id, SEL))objc_msgSend)(
            source, sel_registerName("release"));
        return nil;
    }
    objc_setAssociatedObject(
        source, &macws_catalyst_bundle_identifier_key, identifier,
        OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(
        source, &macws_catalyst_bundle_path_key, path,
        OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(
        source, &macws_catalyst_executable_path_key, executable,
        OBJC_ASSOCIATION_COPY_NONATOMIC);
    return source;
}

// RE-confirmed in Ventura 13.4 FuseBoard:
// +[RBSProcessHandle(FuseBoard) fu_handleForIdentifier:] converts the incoming
// scene's fu_versionedPID to NSNumber, calls this RunningBoard factory, then
// rejects the result unless both versioned PIDs are byte-for-byte equal.
// Runtime-confirmed after the identity refresh: the scene requested the
// current generation while RunningBoard's global factory still returned the
// carrier's preceding cached generation.  Resolve only to the fresh handle
// that this process constructed from the real current audit token, and only
// when its complete versioned PID exactly equals the request after validating
// the kernel's exact Maps path.  FuseBoard still performs its native strict
// generation comparison, application predicate and FUApplication lookup.
static id macws_catalyst_rbs_handle_for_identifier(
    id self, SEL selector, id identifier, NSError **error) {
    id handle = macws_rbs_handle_for_identifier_orig(
        self, selector, identifier, error);
    Class numberClass = objc_getClass("NSNumber");
    if (!identifier || !numberClass ||
        !((BOOL (*)(id, SEL, Class))objc_msgSend)(
            identifier, sel_registerName("isKindOfClass:"), numberClass))
        return handle;

    uint64_t requestedVersionedPID =
        ((uint64_t (*)(id, SEL))objc_msgSend)(
            identifier, sel_registerName("unsignedLongLongValue"));
    uint64_t returnedVersionedPID = macws_rbs_handle_versioned_pid(handle);
    if (returnedVersionedPID == requestedVersionedPID) return handle;

    pid_t pid = (pid_t)(uint32_t)requestedVersionedPID;
    char executablePath[4096];
    char bundleIdentifier[256];
    if (!macws_live_chroot_catalyst_identity(
            pid, executablePath, sizeof(executablePath),
            bundleIdentifier, sizeof(bundleIdentifier))) return handle;

    id exactHandle = macws_copy_exact_catalyst_rbs_handle(
        pid, requestedVersionedPID);
    if (!exactHandle) return handle;
    uint64_t exactVersionedPID =
        macws_rbs_handle_versioned_pid(exactHandle);

    if (getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-IDENTITY resolved scene pid=%d bundle=%s "
                "requested=%#llx stale=%#llx exact=%#llx\n",
                pid, bundleIdentifier,
                (unsigned long long)requestedVersionedPID,
                (unsigned long long)returnedVersionedPID,
                (unsigned long long)exactVersionedPID);
        fflush(stderr);
    }
    return exactHandle;
}

// RE-confirmed in Ventura 13.4 FuseBoard at
// +[RBSProcessHandle(FuseBoard) fu_handleForIdentifier:]+52..184: the method
// reads the caller's fu_versionedPID, resolves a global RBS handle, and returns
// it only when the complete versioned PID matches.  A separately spawned
// chroot Maps process is intentionally anonymous to the iOS runningboardd, so
// that globally resolved handle remains [anon<Maps>] even after UIKitSystem's
// FBProcessManager has natively bootstrapped the exact audit-token generation.
// Resolve at this category boundary to that already-registered, exact handle;
// retain all native PID/generation/application checks and preserve the stock
// result for every other process.
static id macws_catalyst_fu_handle_for_identifier(
    id self, SEL selector, id identifier) {
    id handle = macws_rbs_fu_handle_for_identifier_orig(
        self, selector, identifier);
    uint64_t requestedVersionedPID =
        macws_rbs_handle_versioned_pid(identifier);
    if (requestedVersionedPID == UINT64_MAX) return handle;

    SEL applicationSelector = sel_registerName("fu_isApplication");
    BOOL returnedIsApplication =
        handle &&
        ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            handle, sel_registerName("respondsToSelector:"),
            applicationSelector) &&
        ((BOOL (*)(id, SEL))objc_msgSend)(handle, applicationSelector);
    if (returnedIsApplication &&
        macws_rbs_handle_versioned_pid(handle) == requestedVersionedPID)
        return handle;

    pid_t pid = (pid_t)(uint32_t)requestedVersionedPID;
    char executablePath[4096];
    char bundleIdentifier[256];
    if (!macws_live_chroot_catalyst_identity(
            pid, executablePath, sizeof(executablePath),
            bundleIdentifier, sizeof(bundleIdentifier))) return handle;

    id exactHandle = macws_copy_exact_catalyst_rbs_handle(
        pid, requestedVersionedPID);
    if (!exactHandle) return handle;
    BOOL exactIsApplication =
        ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            exactHandle, sel_registerName("respondsToSelector:"),
            applicationSelector) &&
        ((BOOL (*)(id, SEL))objc_msgSend)(
            exactHandle, applicationSelector);
    if (!exactIsApplication) return handle;

    if (getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-IDENTITY FuseBoard resolved pid=%d bundle=%s "
                "requested=%#llx global=%p exact=%p\n",
                pid, bundleIdentifier,
                (unsigned long long)requestedVersionedPID,
                handle, exactHandle);
        fflush(stderr);
    }
    return exactHandle;
}

static id macws_catalyst_rbs_handle_for_audit_token(
    const audit_token_t *token, pid_t pid, const char *executablePath,
    const char *bundleIdentifier) {
    Class identifierClass = objc_getClass("RBSProcessIdentifier");
    Class handleClass = objc_getClass("RBSProcessHandle");
    Class instanceClass = objc_getClass("RBSProcessInstance");
    Class auditTokenClass = objc_getClass("RBSAuditToken");
    Class identityClass = objc_getClass("RBSProcessIdentity");
    if (!identifierClass || !handleClass || !instanceClass ||
        !auditTokenClass || !identityClass || !token || !executablePath)
        return nil;

    id identifier = ((id (*)(id, SEL, pid_t))objc_msgSend)(
        (id)identifierClass, sel_registerName("identifierWithPid:"), pid);
    NSError *error = nil;
    id staleHandle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        (id)handleClass, sel_registerName("handleForIdentifier:error:"),
        identifier, &error);
    // Do not pass an Objective-C constant string emitted into libmachook here.
    // UIKitSystem-2026-08-03-160935.ips runtime-confirmed that the macOS
    // arm64e RunningBoard factory faults while retaining that cross-image
    // constant (invalid PAC on __CFConstantStringClassReference).  A string
    // instantiated by the process's live Foundation/CoreFoundation runtime
    // carries the correct image/runtime authentication state.
    Class stringClass = objc_getClass("NSString");
    id catalystBundleIdentifier = stringClass && bundleIdentifier
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              bundleIdentifier)
        : nil;
    id launcherJobLabel = stringClass
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              "UIKitApplication:com.macwsguide.catalystlauncher")
        : nil;
    const char *identityFactory = "embedded-identifier";
    id identity = catalystBundleIdentifier
        ? ((id (*)(id, SEL, id))objc_msgSend)(
        (id)identityClass,
        sel_registerName("identityForEmbeddedApplicationIdentifier:"),
        catalystBundleIdentifier)
        : nil;
    // The short factory consults the host application's registration state
    // and runtime-confirmed returns nil inside the chroot UIKitSystem.  The
    // complete factory is the RunningBoard API for constructing that same
    // application identity from its launchd job and bundle identity; the
    // iOS-native runtime probe confirms it returns
    // RBSEmbeddedAppProcessIdentity with both application predicates true.
    if (!identity && launcherJobLabel && catalystBundleIdentifier) {
        identityFactory = "job-label";
        identity = ((id (*)(id, SEL, id, id, int))objc_msgSend)(
            (id)identityClass,
            sel_registerName(
                "identityForApplicationJobLabel:bundleID:platform:"),
            launcherJobLabel, catalystBundleIdentifier, 0);
    }
    if (getenv("MACWS_CATALYST_TRACE")) {
        BOOL isApplication = identity
            ? ((BOOL (*)(id, SEL))objc_msgSend)(
                  identity, sel_registerName("isApplication"))
            : NO;
        BOOL isEmbeddedApplication = identity
            ? ((BOOL (*)(id, SEL))objc_msgSend)(
                  identity, sel_registerName("isEmbeddedApplication"))
            : NO;
        int platform = identity
            ? ((int (*)(id, SEL))objc_msgSend)(
                  identity, sel_registerName("platform"))
            : -1;
        fprintf(stderr,
                "#### CATALYST-IDENTITY construct pid=%d bundle=%s identifier=%p "
                "staleHandle=%p factory=%s identity=%p class=%s app=%s "
                "embedded=%s platform=%d\n",
                pid, bundleIdentifier ?: "<nil>", identifier, staleHandle,
                identityFactory, identity,
                identity ? object_getClassName(identity) : "<nil>",
                isApplication ? "YES" : "NO",
                isEmbeddedApplication ? "YES" : "NO", platform);
        fflush(stderr);
    }
    if (!identifier || !identity) return nil;

    id freshInstance = ((id (*)(id, SEL, id, id))objc_msgSend)(
        (id)instanceClass,
        sel_registerName("instanceWithIdentifier:identity:"),
        identifier, identity);
    id freshAuditToken = ((id (*)(id, SEL, const audit_token_t *))objc_msgSend)(
        (id)auditTokenClass, sel_registerName("tokenFromAuditTokenRef:"),
        token);
    if (!freshInstance || !freshAuditToken) {
        if (getenv("MACWS_CATALYST_TRACE")) {
            fprintf(stderr,
                    "#### CATALYST-IDENTITY instance/token failed pid=%d "
                    "instance=%p auditToken=%p\n",
                    pid, freshInstance, freshAuditToken);
            fflush(stderr);
        }
        return nil;
    }

    // Use the concrete identity's native policy (255 for the Maps embedded-app
    // identity on this OS) instead of carrying the generic process handle's
    // two lifecycle bits across the exec-generation boundary.
    unsigned char manageFlags =
        ((unsigned char (*)(id, SEL))objc_msgSend)(
            identity, sel_registerName("defaultManageFlags"));
    id beforeTranslocationPath = staleHandle
        ? ((id (*)(id, SEL))objc_msgSend)(
              staleHandle,
              sel_registerName("beforeTranslocationBundlePath"))
        : nil;
    id bundleData = nil;
    id staleBundle = staleHandle
        ? ((id (*)(id, SEL))objc_msgSend)(
              staleHandle, sel_registerName("bundle"))
        : nil;
    if (staleBundle) {
        Ivar dataSourceIvar = class_getInstanceVariable(
            object_getClass(staleBundle), "_dataSource");
        if (dataSourceIvar) bundleData = object_getIvar(
            staleBundle, dataSourceIvar);
    }
    id ownedBundleData = nil;
    if (!bundleData) {
        ownedBundleData = macws_create_catalyst_bundle_data_source(
            executablePath, bundleIdentifier);
        bundleData = ownedBundleData;
    }
    id path = [NSString stringWithUTF8String:executablePath];

    id allocated = ((id (*)(id, SEL))objc_msgSend)(
        (id)handleClass, sel_registerName("alloc"));
    // RE-confirmed at
    // -[RBSProcessHandle initWithInstance:...]+432: it is passed to
    // +[RBSProcessBundle bundleWithDataSource:] and the result is stored
    // independently of identity/audit token. Preserve the stale handle's real
    // bundle data source when that private ivar exists; nil remains a supported
    // optional value on builds without it.
    id freshHandle =
        ((id (*)(id, SEL, id, id, id, unsigned char, id, id, BOOL))
             objc_msgSend)(
        allocated,
        sel_registerName(
            "initWithInstance:auditToken:bundleData:manageFlags:"
            "beforeTranslocationBundlePath:executablePath:cache:"),
        freshInstance, freshAuditToken, bundleData, manageFlags,
        beforeTranslocationPath, path, NO);
    if (freshHandle && ownedBundleData) {
        objc_setAssociatedObject(
            freshHandle, &macws_catalyst_bundle_data_source_owner_key,
            ownedBundleData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ownedBundleData) {
        ((void (*)(id, SEL))objc_msgSend)(
            ownedBundleData, sel_registerName("release"));
    }
    if (getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-IDENTITY handle pid=%d instance=%p "
                "auditToken=%p flags=%u bundleData=%p handle=%p class=%s\n",
                pid, freshInstance, freshAuditToken, manageFlags, bundleData,
                freshHandle,
                freshHandle ? object_getClassName(freshHandle) : "<nil>");
        fflush(stderr);
    }
    macws_publish_catalyst_rbs_handle(freshHandle, pid);
    return ((id (*)(id, SEL))objc_msgSend)(
        freshHandle, sel_registerName("autorelease"));
}

static id macws_fb_register_process_for_audit_token(
    id self, SEL selector, const audit_token_t *token) {
    if (!token || !macws_bs_versioned_pid_for_audit_token)
        return macws_fb_register_process_for_audit_token_orig(
            self, selector, token);

    uint64_t requestedVersionedPID =
        macws_bs_versioned_pid_for_audit_token(token);
    pid_t pid = (pid_t)(uint32_t)requestedVersionedPID;
    char executablePath[4096];
    char bundleIdentifier[256];
    if (!macws_live_chroot_catalyst_identity(
            pid, executablePath, sizeof(executablePath),
            bundleIdentifier, sizeof(bundleIdentifier)))
        return macws_fb_register_process_for_audit_token_orig(
            self, selector, token);

    id exactProcess = macws_fb_process_for_versioned_pid_orig(
        self, sel_registerName("processForVersionedPID:"),
        requestedVersionedPID);
    if (exactProcess &&
        macws_fb_process_versioned_pid(exactProcess) == requestedVersionedPID)
        return exactProcess;

    id freshHandle = macws_catalyst_rbs_handle_for_audit_token(
        token, pid, executablePath, bundleIdentifier);
    SEL registerSelector = sel_registerName("_reallyRegisterProcessForHandle:");
    BOOL canReallyRegister = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
        self, sel_registerName("respondsToSelector:"), registerSelector);
    if (!freshHandle || !canReallyRegister) {
        if (getenv("MACWS_CATALYST_TRACE")) {
            fprintf(stderr,
                    "#### CATALYST-IDENTITY bootstrap unavailable pid=%d "
                    "handle=%p selector=%s\n",
                    pid, freshHandle, canReallyRegister ? "YES" : "NO");
            fflush(stderr);
        }
        return macws_fb_register_process_for_audit_token_orig(
            self, selector, token);
    }

    id process = ((id (*)(id, SEL, id))objc_msgSend)(
        self, registerSelector, freshHandle);
    if (process &&
        macws_fb_process_versioned_pid(process) == requestedVersionedPID) {
        if (getenv("MACWS_CATALYST_TRACE")) {
            fprintf(stderr,
                    "#### CATALYST-IDENTITY registered pid=%d bundle=%s "
                    "vpid=%#llx through native FrontBoard bootstrap\n",
                    pid, bundleIdentifier,
                    (unsigned long long)requestedVersionedPID);
            fflush(stderr);
        }
        return process;
    }

    if (getenv("MACWS_CATALYST_TRACE")) {
        fprintf(stderr,
                "#### CATALYST-IDENTITY bootstrap mismatch pid=%d "
                "requested=%#llx process=%p actual=%#llx\n",
                pid, (unsigned long long)requestedVersionedPID, process,
                (unsigned long long)macws_fb_process_versioned_pid(process));
        fflush(stderr);
    }

    // Preserve stock failure behavior if the private constructor/bootstrap
    // contract changes on another OS build.
    return macws_fb_register_process_for_audit_token_orig(
        self, selector, token);
}

static void macws_install_uikitsystem_exec_identity_refresh(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "UIKitSystem") != 0) return;

    Class handleClass = objc_getClass("RBSProcessHandle");
    if (!handleClass) return;
    if (!atomic_load_explicit(
            &macws_uikitsystem_exec_identity_hook_installed,
            memory_order_acquire)) {
        Class managerClass = objc_getClass("FBProcessManager");
        if (!managerClass) return;
        SEL processSelector = sel_registerName("processForVersionedPID:");
        SEL registerSelector = sel_registerName("registerProcessForAuditToken:");
        Method processMethod = class_getInstanceMethod(
            managerClass, processSelector);
        Method registerMethod = class_getInstanceMethod(
            managerClass, registerSelector);
        SEL handleSelector = sel_registerName("handleForIdentifier:error:");
        Method handleMethod = class_getClassMethod(
            handleClass, handleSelector);
        if (!processMethod || !registerMethod || !handleMethod) return;

        macws_bs_versioned_pid_for_audit_token =
            (macws_bs_versioned_pid_for_audit_token_fn)dlsym(
                RTLD_DEFAULT, "BSVersionedPIDForAuditToken");
        if (!macws_bs_versioned_pid_for_audit_token) return;

        macws_fb_process_for_versioned_pid_orig =
            (macws_fb_process_for_versioned_pid_fn)
                method_getImplementation(processMethod);
        if (!macws_fb_process_for_versioned_pid_orig) return;

        macws_rbs_handle_for_identifier_orig =
            (macws_rbs_handle_for_identifier_fn)method_setImplementation(
                handleMethod, (IMP)macws_catalyst_rbs_handle_for_identifier);
        if (!macws_rbs_handle_for_identifier_orig) return;

        macws_fb_register_process_for_audit_token_orig =
            (macws_fb_register_process_for_audit_token_fn)
                method_setImplementation(
                    registerMethod,
                    (IMP)macws_fb_register_process_for_audit_token);
        if (!macws_fb_register_process_for_audit_token_orig) return;
        atomic_store_explicit(
            &macws_uikitsystem_exec_identity_hook_installed, YES,
            memory_order_release);
    }

    // FuseBoard is loaded after RunningBoardServices on this build.  Install
    // this independently from the base identity refresh so the dyld image
    // callback can pick it up when the category method becomes available.
    if (atomic_load_explicit(
            &macws_uikitsystem_fu_handle_hook_installed,
            memory_order_acquire)) return;
    SEL fuseHandleSelector = sel_registerName("fu_handleForIdentifier:");
    Method fuseHandleMethod = class_getClassMethod(
        handleClass, fuseHandleSelector);
    if (!fuseHandleMethod) return;
    macws_rbs_fu_handle_for_identifier_orig =
        (macws_rbs_fu_handle_for_identifier_fn)method_setImplementation(
            fuseHandleMethod, (IMP)macws_catalyst_fu_handle_for_identifier);
    if (!macws_rbs_fu_handle_for_identifier_orig) return;
    atomic_store_explicit(
        &macws_uikitsystem_fu_handle_hook_installed, YES,
        memory_order_release);
}

static void macws_uikitsystem_exec_identity_image_added(
    const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    macws_install_uikitsystem_exec_identity_refresh();
}

static id macws_catalyst_application_support_client;
static id macws_catalyst_application_initialization_context;
static _Atomic int macws_catalyst_application_registration_attempts;

static void macws_register_catalyst_application_with_fuseboard(void) {
    if (!getenv("MACWS_CATALYST_REGISTER_APPLICATION")) return;
    BOOL trace = getenv("MACWS_CATALYST_TRACE") != NULL;
    int attempt = atomic_fetch_add_explicit(
        &macws_catalyst_application_registration_attempts, 1,
        memory_order_acq_rel) + 1;
    // Attempt 1 runs in the injected-library constructor.  SETEXEC has already
    // changed pid-version there, but the app has not necessarily completed its
    // RBS/workspace bootstrap.  Attempt 2 runs at UIApplication's launch
    // completion boundary, after that bootstrap and immediately before the
    // first scene request.  More calls would only duplicate a live service
    // connection.
    if (attempt > 2) return;

    // RE-confirmed via UIKitServices on Ventura 13.4:
    // -[UISApplicationSupportClient
    // applicationInitializationContextWithParameters:] obtains the official
    // UISApplicationSupportService endpoint and synchronously calls
    // initializeClientWithParameters:completion:.  FuseBoard's
    // -[FUApplicationManager service:initializeClient:withParameters:] then
    // resolves the real audit-token-backed RBSProcessHandle and registers the
    // live versioned PID before returning its initialization context.  Direct
    // chroot launch skipped this normal client handshake, leaving the scene
    // request with no FUApplication entry.
    Class clientClass = objc_getClass("UISApplicationSupportClient");
    Class parametersClass =
        objc_getClass("UISApplicationInitializationContextParameters");
    if (!clientClass || !parametersClass) {
        if (trace) {
            fprintf(stderr,
                    "#### CATALYST-SUPPORT classes client=%s parameters=%s\n",
                    clientClass ? "YES" : "NO",
                    parametersClass ? "YES" : "NO");
            fflush(stderr);
        }
        return;
    }

    id parameters = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(
            (id)parametersClass, sel_registerName("alloc")),
        sel_registerName("init"));
    id client = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(
            (id)clientClass, sel_registerName("alloc")),
        sel_registerName("init"));
    id context = nil;
    SEL initializeSelector = sel_registerName(
        "applicationInitializationContextWithParameters:");
    if (client && parameters &&
        ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            client, sel_registerName("respondsToSelector:"),
            initializeSelector)) {
        @try {
            context = ((id (*)(id, SEL, id))objc_msgSend)(
                client, initializeSelector, parameters);
        } @catch (NSException *exception) {
            if (trace) {
                fprintf(stderr,
                        "#### CATALYST-SUPPORT initialization throw=%s "
                        "reason=%s\n",
                        exception.name.UTF8String ?: "<nil>",
                        exception.reason.UTF8String ?: "<nil>");
                fflush(stderr);
            }
        }
    }

    if (client) {
        macws_catalyst_application_support_client = client;
    }
    if (context) {
        macws_catalyst_application_initialization_context =
            ((id (*)(id, SEL))objc_msgSend)(
                context, sel_registerName("retain"));
    }
    if (parameters) {
        ((void (*)(id, SEL))objc_msgSend)(
            parameters, sel_registerName("release"));
    }
    if (trace) {
        fprintf(stderr,
                "#### CATALYST-SUPPORT registration attempt=%d client=%s "
                "context=%s\n",
                attempt,
                client ? object_getClassName(client) : "nil",
                context ? object_getClassName(context) : "nil");
        fflush(stderr);
    }
}

static NSUInteger macws_catalyst_collection_count(id value) {
    if (!value || !((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            value, sel_registerName("respondsToSelector:"),
            sel_registerName("count"))) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(
        value, sel_registerName("count"));
}

static id macws_catalyst_send_id(id receiver, const char *selector) {
    if (!receiver) return nil;
    SEL sel = sel_registerName(selector);
    if (!((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            receiver, sel_registerName("respondsToSelector:"), sel))
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, sel);
}

static BOOL macws_catalyst_send_bool(id receiver, const char *selector,
                                     BOOL *supported) {
    if (supported) *supported = NO;
    if (!receiver) return NO;
    SEL sel = sel_registerName(selector);
    if (!((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            receiver, sel_registerName("respondsToSelector:"), sel))
        return NO;
    if (supported) *supported = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, sel);
}

static void macws_catalyst_log_state(const char *stage, id application) {
    Class delegateClass = objc_getClass("UINSApplicationDelegate");
    id delegate = delegateClass
        ? macws_catalyst_send_id((id)delegateClass, "sharedDelegate") : nil;
    Class workspaceClass = objc_getClass("UINSWorkspace");
    id workspace = workspaceClass
        ? macws_catalyst_send_id((id)workspaceClass, "sharedInstance") : nil;
    id initialScreen = macws_catalyst_send_id(workspace, "initialScreen");
    id scenes = macws_catalyst_send_id(application, "connectedScenes");
    id windows = macws_catalyst_send_id(
        objc_getClass("NSApplication")
            ? macws_catalyst_send_id(
                  (id)objc_getClass("NSApplication"), "sharedApplication")
            : nil,
        "windows");
    BOOL wantsSupported = NO;
    BOOL wantsInitialScene = macws_catalyst_send_bool(
        delegate, "_wantsInitialScene", &wantsSupported);
    BOOL configuredSupported = NO;
    BOOL didConfigureWindow = macws_catalyst_send_bool(
        delegate, "didConfigureWindow", &configuredSupported);
    id requestCallback = macws_catalyst_send_id(
        delegate,
        "requestHostingSceneCreationWithPersistentIdentifierCallback");
    fprintf(stderr,
        "#### CATALYST-LAUNCH stage=%s app=%s delegate=%s workspace=%s "
        "initialScreen=%s connectedScenes=%lu nsWindows=%lu "
        "wantsInitial=%s/%s configured=%s/%s requestCallback=%s\n",
        stage ?: "<unknown>",
        application ? object_getClassName(application) : "nil",
        delegate ? object_getClassName(delegate) : "nil",
        workspace ? object_getClassName(workspace) : "nil",
        initialScreen ? object_getClassName(initialScreen) : "nil",
        (unsigned long)macws_catalyst_collection_count(scenes),
        (unsigned long)macws_catalyst_collection_count(windows),
        wantsSupported ? "supported" : "missing",
        wantsInitialScene ? "YES" : "NO",
        configuredSupported ? "supported" : "missing",
        didConfigureWindow ? "YES" : "NO",
        requestCallback ? object_getClassName(requestCallback) : "nil");
    fflush(stderr);
}

static id macws_catalyst_pending_application;
static SEL macws_catalyst_pending_compell_selector;
static _Atomic unsigned macws_catalyst_scene_poll_attempts;

// RE-confirmed in Ventura 13.4 UIKitMacHelper:
// -[UINSApplicationDelegate willRequestSceneWithOptions:] is exactly an ADRP
// + ADD that loads __block_literal_global.123, followed by a tail call to
// _willRequestSceneWithOptions:withCompletion:. Its block invoke is a single
// RET. Reuse that Apple-framework-owned, correctly arm64e-signed no-op block
// instead of creating a block in the on-device-built injected dylib. The
// latter's _NSConcreteStackBlock isa trapped PAC in
// Maps-2026-08-03-152724.ips.
static id macws_uins_framework_noop_scene_completion(Class delegateClass) {
    if (!delegateClass) return nil;
    Method method = class_getInstanceMethod(
        delegateClass, sel_registerName("willRequestSceneWithOptions:"));
    if (!method) return nil;
    uintptr_t pc = (uintptr_t)ptrauth_strip(
        method_getImplementation(method), ptrauth_key_function_pointer);
    uint32_t adrp = 0;
    uint32_t add = 0;
    memcpy(&adrp, (const void *)pc, sizeof(adrp));
    memcpy(&add, (const void *)(pc + sizeof(adrp)), sizeof(add));
    if ((adrp & 0x9f000000u) != 0x90000000u ||
        (add & 0xffc00000u) != 0x91000000u) return nil;
    unsigned destination = adrp & 0x1fu;
    if ((add & 0x1fu) != destination ||
        ((add >> 5) & 0x1fu) != destination) return nil;

    int64_t pages = (int64_t)((((adrp >> 5) & 0x7ffffu) << 2) |
                              ((adrp >> 29) & 0x3u));
    if (pages & (1ll << 20)) pages -= 1ll << 21;
    uintptr_t blockAddress = (pc & ~(uintptr_t)0xfff) +
        (uintptr_t)(pages << 12);
    uintptr_t addImmediate = (uintptr_t)((add >> 10) & 0xfffu);
    if ((add >> 22) & 1u) addImmediate <<= 12;
    blockAddress += addImmediate;

    id block = (__bridge id)(void *)blockAddress;
    const char *className = block ? object_getClassName(block) : NULL;
    return className && strstr(className, "Block") ? block : nil;
}

static BOOL macws_weather_has_configured_scene(id application) {
    Class weatherSceneDelegateClass =
        objc_getClass("_TtC7Weather13SceneDelegate");
    id scenes = macws_catalyst_send_id(application, "connectedScenes");
    if (!weatherSceneDelegateClass || !scenes) return NO;
    for (id scene in scenes) {
        id delegate = macws_catalyst_send_id(scene, "delegate");
        if (delegate && ((BOOL (*)(id, SEL, Class))objc_msgSend)(
                delegate, sel_registerName("isKindOfClass:"),
                weatherSceneDelegateClass))
            return YES;
    }
    return NO;
}

static void macws_catalyst_finish_after_scene(void *context) {
    (void)context;
    @autoreleasepool {
        id application = macws_catalyst_pending_application;
        if (!application || !macws_catalyst_compell_orig) return;
        NSUInteger sceneCount = macws_catalyst_collection_count(
            macws_catalyst_send_id(application, "connectedScenes"));
        const char *program = getprogname();
        BOOL isWeather = program && strcmp(program, "Weather") == 0;
        BOOL sceneReady = sceneCount > 0;
        if (sceneReady && isWeather &&
            !macws_weather_has_configured_scene(application)) {
            if (!atomic_load_explicit(
                    &macws_weather_bootstrap_request_completed,
                    memory_order_acquire)) {
                // connectedScenes is published before UINS closes the request
                // transaction. Keep polling until the native completion hook
                // above records that stronger lifecycle boundary.
                sceneReady = NO;
                goto poll_scene;
            }
            // The generic UINS bootstrap is intentionally first: the current
            // iPadOS UIKit runtime publishes UIScreen only after that scene is
            // connected. Runtime capture on the target showed Weather's
            // AppDelegate reaching +[UIScreen mainScreen] before this boundary
            // and aborting with "returning nil screen ... is not allowed".
            // Once UIScreen is real, run Weather's ordinary launch callbacks
            // and hand this already-registered scene to Weather's stock
            // SceneDelegate. A second activation is not equivalent here:
            // runtime logs showed UINS tracking a new persistent ID while
            // FuseBoard reused the bootstrap scene's old persistent ID, after
            // which UINS rejected the real window as an untracked scene.
            if (!macws_weather_prepare_application_launch(application, NULL)) {
                atomic_store_explicit(
                    &macws_catalyst_initial_scene_request_state, 3,
                    memory_order_release);
                fprintf(stderr,
                        "#### WEATHER-LIFECYCLE AppDelegate launch failed "
                        "after UINS bootstrap scene\n");
                fflush(stderr);
                return;
            }
            if (!macws_weather_adopt_bootstrap_scene(application)) {
                atomic_store_explicit(
                    &macws_catalyst_initial_scene_request_state, 3,
                    memory_order_release);
                fprintf(stderr,
                        "#### WEATHER-SCENE bootstrap adoption failed\n");
                fflush(stderr);
                return;
            }
            sceneReady = macws_weather_has_configured_scene(application);
        }
        if (sceneReady) {
            atomic_store_explicit(
                &macws_catalyst_initial_scene_request_state, 2,
                memory_order_release);
            SEL selector = macws_catalyst_pending_compell_selector;
            macws_catalyst_pending_application = nil;
            macws_catalyst_pending_compell_selector = NULL;
            macws_catalyst_compell_orig(application, selector);
            if (macws_runtime_diagnostics_enabled())
                macws_catalyst_log_state(
                    "UIApplication.compell-scene-ready", application);
            return;
        }

poll_scene:
        ;
        unsigned attempt = atomic_fetch_add_explicit(
            &macws_catalyst_scene_poll_attempts, 1,
            memory_order_acq_rel) + 1;
        if (attempt < 100) {
            dispatch_after_f(
                dispatch_time(DISPATCH_TIME_NOW,
                              50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), NULL,
                macws_catalyst_finish_after_scene);
            return;
        }
        atomic_store_explicit(
            &macws_catalyst_initial_scene_request_state, 3,
            memory_order_release);
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                    "#### CATALYST-LAUNCH initial scene timed out after "
                    "%u polls\n", attempt);
            fflush(stderr);
        }
    }
}

static BOOL macws_weather_prepare_application_launch(id application,
                                                      id *delegateOut) {
    const char *program = getprogname();
    if (!program || strcmp(program, "Weather") != 0 || !application)
        return NO;
    Class weatherAppDelegateClass = objc_getClass("_TtC7Weather11AppDelegate");
    id currentDelegate = macws_catalyst_send_id(application, "delegate");
    BOOL usesWeatherAppDelegate = currentDelegate && weatherAppDelegateClass &&
        ((BOOL (*)(id, SEL, Class))objc_msgSend)(
            currentDelegate, sel_registerName("isKindOfClass:"),
            weatherAppDelegateClass);
    if (!usesWeatherAppDelegate && weatherAppDelegateClass &&
        ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            sel_registerName("setDelegate:"))) {
        id weatherAppDelegate = ((id (*)(id, SEL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)weatherAppDelegateClass,
                                             sel_registerName("alloc")),
            sel_registerName("init"));
        ((void (*)(id, SEL, id))objc_msgSend)(
            application, sel_registerName("setDelegate:"),
            weatherAppDelegate);
        objc_setAssociatedObject(application, @selector(delegate),
                                 weatherAppDelegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        currentDelegate = weatherAppDelegate;
    }
    if (!currentDelegate || !weatherAppDelegateClass ||
        !((BOOL (*)(id, SEL, Class))objc_msgSend)(
            currentDelegate, sel_registerName("isKindOfClass:"),
            weatherAppDelegateClass)) return NO;
    if (!objc_getAssociatedObject(
            currentDelegate, &macws_weather_app_launch_delivered_key)) {
        id launchOptions = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSDictionary"), sel_registerName("dictionary"));
        SEL willFinish = sel_registerName(
            "application:willFinishLaunchingWithOptions:");
        SEL didFinish = sel_registerName(
            "application:didFinishLaunchingWithOptions:");
        BOOL willFinishResult = YES;
        BOOL didFinishResult = YES;
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(
                currentDelegate, sel_registerName("respondsToSelector:"),
                willFinish)) {
            willFinishResult = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
                currentDelegate, willFinish, application, launchOptions);
        }
        if (willFinishResult &&
            ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
                currentDelegate, sel_registerName("respondsToSelector:"),
                didFinish)) {
            didFinishResult = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
                currentDelegate, didFinish, application, launchOptions);
        }
        fprintf(stderr,
                "#### WEATHER-LIFECYCLE appDelegate launch "
                "willFinish=%d didFinish=%d\n",
                willFinishResult, didFinishResult);
        fflush(stderr);
        if (!willFinishResult || !didFinishResult) return NO;
        objc_setAssociatedObject(
            currentDelegate, &macws_weather_app_launch_delivered_key, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (delegateOut) *delegateOut = currentDelegate;
    return YES;
}

static BOOL macws_weather_adopt_bootstrap_scene(id application) {
    id currentDelegate = nil;
    if (!macws_weather_prepare_application_launch(application,
                                                  &currentDelegate))
        return NO;

    Class weatherSceneDelegateClass =
        objc_getClass("_TtC7Weather13SceneDelegate");
    Class windowSceneClass = objc_getClass("UIWindowScene");
    id scenes = macws_catalyst_send_id(application, "connectedScenes");
    id bootstrapScene = nil;
    for (id scene in scenes) {
        id delegate = macws_catalyst_send_id(scene, "delegate");
        BOOL isWindowScene = windowSceneClass &&
            ((BOOL (*)(id, SEL, Class))objc_msgSend)(
                scene, sel_registerName("isKindOfClass:"), windowSceneClass);
        BOOL alreadyWeather = delegate && weatherSceneDelegateClass &&
            ((BOOL (*)(id, SEL, Class))objc_msgSend)(
                delegate, sel_registerName("isKindOfClass:"),
                weatherSceneDelegateClass);
        if (isWindowScene && !alreadyWeather) {
            bootstrapScene = scene;
            break;
        }
    }
    if (!bootstrapScene || !weatherSceneDelegateClass) return NO;

    id session = macws_catalyst_send_id(bootstrapScene, "session");
    Class optionsClass = objc_getClass("UISceneConnectionOptions");
    id options = optionsClass
        ? ((id (*)(id, SEL))objc_msgSend)(
              ((id (*)(id, SEL))objc_msgSend)((id)optionsClass,
                                               sel_registerName("alloc")),
              sel_registerName("init"))
        : nil;
    SEL configurationSelector = sel_registerName(
        "application:configurationForConnectingSceneSession:options:");
    id stockConfiguration = nil;
    if (session && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            currentDelegate, sel_registerName("respondsToSelector:"),
            configurationSelector)) {
        stockConfiguration = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            currentDelegate, configurationSelector, application, session,
            options);
    }
    Class delegateClass = stockConfiguration
        ? (Class)macws_catalyst_send_id(stockConfiguration, "delegateClass")
        : Nil;
    if (!delegateClass ||
        !((BOOL (*)(id, SEL, Class))objc_msgSend)(
            (id)delegateClass, sel_registerName("isSubclassOfClass:"),
            weatherSceneDelegateClass)) {
        delegateClass = weatherSceneDelegateClass;
    }
    id sceneDelegate = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)delegateClass,
                                        sel_registerName("alloc")),
        sel_registerName("init"));
    SEL setDelegateSelector = sel_registerName("setDelegate:");
    if (!sceneDelegate || !((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            bootstrapScene, sel_registerName("respondsToSelector:"),
            setDelegateSelector)) return NO;

    // RE-confirmed via the target's Ventura 13.4 UIKitCore at
    // -[UIScene setDelegate:] +0x3c..+0x5c: UIKit stores the delegate strongly
    // and calls _UISceneInspectDelegateSuport to rebuild its callback flags.
    // This adopts the real scene through UIKit's own lifecycle state rather
    // than mutating SkyLight window or Space membership.
    ((void (*)(id, SEL, id))objc_msgSend)(
        bootstrapScene, setDelegateSelector, sceneDelegate);
    SEL willConnect = sel_registerName(
        "scene:willConnectToSession:options:");
    if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            sceneDelegate, sel_registerName("respondsToSelector:"),
            willConnect)) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            sceneDelegate, willConnect, bootstrapScene, session, options);
    }

    NSInteger activationState = ((NSInteger (*)(id, SEL))objc_msgSend)(
        bootstrapScene, sel_registerName("activationState"));
    SEL willEnterForeground = sel_registerName("sceneWillEnterForeground:");
    if (activationState <= 1 && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            sceneDelegate, sel_registerName("respondsToSelector:"),
            willEnterForeground)) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            sceneDelegate, willEnterForeground, bootstrapScene);
    }
    SEL didBecomeActive = sel_registerName("sceneDidBecomeActive:");
    if (activationState == 0 && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            sceneDelegate, sel_registerName("respondsToSelector:"),
            didBecomeActive)) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            sceneDelegate, didBecomeActive, bootstrapScene);
    }
    fprintf(stderr,
            "#### WEATHER-SCENE adopted bootstrap scene=%s session=%s "
            "delegate=%s@%p activation=%ld windows=%lu\n",
            object_getClassName(bootstrapScene),
            session ? object_getClassName(session) : "nil",
            object_getClassName(sceneDelegate), sceneDelegate,
            (long)activationState,
            (unsigned long)macws_catalyst_collection_count(
                macws_catalyst_send_id(application, "windows")));
    fflush(stderr);
    return macws_weather_has_configured_scene(application);
}

static void macws_catalyst_compell_compat(id self, SEL selector) {
    macws_register_catalyst_application_with_fuseboard();
    if (macws_runtime_diagnostics_enabled())
        macws_catalyst_log_state("UIApplication.compell-enter", self);
    if (getenv("MACWS_CATALYST_REQUEST_INITIAL_SCENE") &&
        macws_catalyst_collection_count(
            macws_catalyst_send_id(self, "connectedScenes")) == 0) {
        const char *program = getprogname();
        if (program && strcmp(program, "Weather") == 0) {
            (void)macws_install_weather_uins_completion_hook();
            (void)macws_install_weather_uins_finish_hook();
        }
        int expected = 0;
        if (atomic_compare_exchange_strong_explicit(
                &macws_catalyst_initial_scene_request_state, &expected, 1,
                memory_order_acq_rel, memory_order_acquire)) {
            Class delegateClass = objc_getClass("UINSApplicationDelegate");
            id delegate = delegateClass
                ? macws_catalyst_send_id(
                      (id)delegateClass, "sharedDelegate") : nil;
            SEL createSelector = sel_registerName(
                "_createNewSceneInForegroundWithCompletionHandler:");
            BOOL supported = delegate &&
                ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
                    delegate, sel_registerName("respondsToSelector:"),
                    createSelector);
            id completion = supported
                ? macws_uins_framework_noop_scene_completion(delegateClass)
                : nil;
            if (supported && completion) {
                macws_catalyst_pending_application = self;
                macws_catalyst_pending_compell_selector = selector;
                atomic_store_explicit(
                    &macws_catalyst_scene_poll_attempts, 0,
                    memory_order_release);
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        delegate, createSelector, completion);
                } @catch (NSException *exception) {
                    atomic_store_explicit(
                        &macws_catalyst_initial_scene_request_state, 3,
                        memory_order_release);
                    fprintf(stderr,
                        "#### CATALYST-LAUNCH stage=initial-scene-request "
                        "throw=%s reason=%s\n",
                        exception.name.UTF8String ?: "<nil>",
                        exception.reason.UTF8String ?: "<nil>");
                    fflush(stderr);
                }
                if (atomic_load_explicit(
                        &macws_catalyst_initial_scene_request_state,
                        memory_order_acquire) == 1) {
                    dispatch_after_f(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      50 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(), NULL,
                        macws_catalyst_finish_after_scene);
                }
                return;
            }
            atomic_store_explicit(
                &macws_catalyst_initial_scene_request_state, 3,
                memory_order_release);
        } else if (expected == 1) {
            return;
        }
    }
    macws_catalyst_compell_orig(self, selector);
    if (macws_runtime_diagnostics_enabled())
        macws_catalyst_log_state("UIApplication.compell-return", self);
}

static void macws_install_catalyst_launch_compatibility(void) {
    if (!getenv("MACWS_CATALYST_REQUEST_INITIAL_SCENE")) return;
    macws_install_weather_scene_compatibility();
    Class application = objc_getClass("UIApplication");
    if (!application) return;
    macws_lp_replace_instance_method(
        application, "_compellApplicationLaunchToCompleteUnconditionally",
        (IMP)macws_catalyst_compell_compat,
        (IMP *)&macws_catalyst_compell_orig);
}

static id macws_catalyst_main_screen_trace(id self, SEL selector) {
    fprintf(stderr, "#### CATALYST-LAUNCH stage=UIScreen.mainScreen-enter\n");
    fflush(stderr);
    @try {
        id screen = macws_catalyst_main_screen_orig(self, selector);
        fprintf(stderr,
                "#### CATALYST-LAUNCH stage=UIScreen.mainScreen-return "
                "screen=%s\n",
                screen ? object_getClassName(screen) : "nil");
        fflush(stderr);
        return screen;
    } @catch (NSException *exception) {
        fprintf(stderr,
                "#### CATALYST-LAUNCH stage=UIScreen.mainScreen-throw "
                "name=%s reason=%s\n",
                exception.name.UTF8String ?: "<nil>",
                exception.reason.UTF8String ?: "<nil>");
        fflush(stderr);
        @throw exception;
    }
}

static void macws_catalyst_uins_finish_trace(id self, SEL selector) {
    macws_catalyst_log_state("UINS.finish-enter", nil);
    macws_catalyst_uins_finish_orig(self, selector);
    macws_catalyst_log_state("UINS.finish-return", nil);
}

static void macws_catalyst_uins_did_finish_trace(id self, SEL selector,
                                                 id notification) {
    macws_catalyst_log_state("UINS.didFinish-enter", nil);
    macws_catalyst_uins_did_finish_orig(self, selector, notification);
    macws_catalyst_log_state("UINS.didFinish-return", nil);
}

static void macws_catalyst_request_scene_trace(id self, SEL selector,
                                               id options, id completion) {
    fprintf(stderr,
            "#### CATALYST-LAUNCH stage=UINSWorkspace.requestScene "
            "options=%s completion=%s\n",
            options ? object_getClassName(options) : "nil",
            completion ? object_getClassName(completion) : "nil");
    fflush(stderr);
    macws_catalyst_request_scene_orig(self, selector, options, completion);
}

static void macws_catalyst_dump_service_class(const char *className) {
    Class cls = objc_getClass(className);
    fprintf(stderr, "#### CATALYST-SERVICE class=%s available=%s\n",
            className, cls ? "YES" : "NO");
    if (!cls) return;
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int index = 0; index < ivarCount; index++) {
        fprintf(stderr,
                "#### CATALYST-SERVICE ivar class=%s name=%s type=%s "
                "offset=%td\n",
                className, ivar_getName(ivars[index]) ?: "<nil>",
                ivar_getTypeEncoding(ivars[index]) ?: "<nil>",
                ivar_getOffset(ivars[index]));
    }
    free(ivars);
    for (int meta = 0; meta <= 1; meta++) {
        Class owner = meta ? object_getClass(cls) : cls;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(owner, &methodCount);
        for (unsigned int index = 0; index < methodCount; index++) {
            fprintf(stderr,
                    "#### CATALYST-SERVICE method class=%s scope=%c "
                    "selector=%s types=%s\n",
                    className, meta ? '+' : '-',
                    sel_getName(method_getName(methods[index])) ?: "<nil>",
                    method_getTypeEncoding(methods[index]) ?: "<nil>");
        }
        free(methods);
    }
}

static void macws_install_catalyst_launch_diagnostics(void) {
    // MACWS_CATALYST_TRACE may be inherited from an older launcher build.
    // Installing these invasive lifecycle swizzles in production caused an
    // arm64e PAC fault while UIKitMacHelper retained the diagnostic stack
    // block (Maps-2026-08-03-152724.ips, main thread, this file:1112).
    // Require the repository-wide diagnostics master gate as well.
    if (!getenv("MACWS_CATALYST_TRACE") ||
        !macws_runtime_diagnostics_enabled()) return;
    const char *program = getprogname();
    if (!program || strcmp(program, "Maps") != 0) return;

    Class application = objc_getClass("UIApplication");
    Class screen = objc_getClass("UIScreen");
    Class delegate = objc_getClass("UINSApplicationDelegate");
    Class workspace = objc_getClass("UINSWorkspace");
    macws_catalyst_dump_service_class("BSServiceDomain");
    macws_catalyst_dump_service_class("BSServiceConnectionEndpoint");
    macws_catalyst_dump_service_class("BSServiceConnection");
    if (screen) {
        macws_lp_replace_instance_method(
            object_getClass(screen), "mainScreen",
            (IMP)macws_catalyst_main_screen_trace,
            (IMP *)&macws_catalyst_main_screen_orig);
    }
    if (delegate) {
        macws_lp_replace_instance_method(
            delegate, "_finishLaunching",
            (IMP)macws_catalyst_uins_finish_trace,
            (IMP *)&macws_catalyst_uins_finish_orig);
        macws_lp_replace_instance_method(
            delegate, "applicationDidFinishLaunching:",
            (IMP)macws_catalyst_uins_did_finish_trace,
            (IMP *)&macws_catalyst_uins_did_finish_orig);
    }
    if (workspace) {
        macws_lp_replace_instance_method(
            workspace, "requestSceneWithOptions:completion:",
            (IMP)macws_catalyst_request_scene_trace,
            (IMP *)&macws_catalyst_request_scene_orig);
    }
    fprintf(stderr,
            "#### CATALYST-LAUNCH diagnostics installed app=%s screen=%s "
            "delegate=%s workspace=%s\n",
            application ? "YES" : "NO", screen ? "YES" : "NO",
            delegate ? "YES" : "NO", workspace ? "YES" : "NO");
    fflush(stderr);
}

static int macws_filtered_fprintf(FILE *stream, const char *format, ...)
    __attribute__((format(printf, 2, 3)));
static int macws_filtered_fprintf(FILE *stream, const char *format, ...) {
    if (stream == stderr && !macws_runtime_diagnostics_enabled()) return 0;
    va_list args;
    va_start(args, format);
    int result = vfprintf(stream, format, args);
    va_end(args);
    return result;
}
#define fprintf macws_filtered_fprintf

// These diagnostics are selected before process launch.  Cache their exact
// state once so command-buffer completion and resource creation never perform
// filesystem probes in production.
#define MACWS_DEFINE_STARTUP_FLAG(function_name, path_literal) \
    static BOOL function_name(void) { \
        static _Atomic int cached = -1; \
        int value = atomic_load_explicit(&cached, memory_order_acquire); \
        if (value < 0) { \
            value = access(path_literal, F_OK) == 0; \
            atomic_store_explicit(&cached, value, memory_order_release); \
        } \
        return value != 0; \
    }

MACWS_DEFINE_STARTUP_FLAG(macws_iogpu_error_diag_enabled,
                          "/tmp/macws_iogpu_error_diag")
MACWS_DEFINE_STARTUP_FLAG(macws_command_error_diag_enabled,
                          "/tmp/macws_command_error_diag")
MACWS_DEFINE_STARTUP_FLAG(macws_submit_ring_enabled,
                          "/tmp/macws_submit_ring")
MACWS_DEFINE_STARTUP_FLAG(macws_res_diag_enabled,
                          "/tmp/macws_res_diag")
MACWS_DEFINE_STARTUP_FLAG(macws_trace_small_pf550_bind_enabled,
                          "/tmp/macws_trace_small_pf550_bind")
MACWS_DEFINE_STARTUP_FLAG(macws_video_diag_enabled,
                          "/tmp/macws_video_diag")
MACWS_DEFINE_STARTUP_FLAG(macws_pipeline_diag_enabled,
                          "/tmp/macws_pipeline_diag")

#undef MACWS_DEFINE_STARTUP_FLAG

static BOOL macws_owned_scanout_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = access("/tmp/macws_owned_scanout", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

// Production readiness must not depend on a diagnostic stderr line. Publish
// one tiny process-owned witness after the first actually completed display
// producer. The launcher validates the PID and removes the file whenever the
// producer is stopped, so a stale frame from an earlier WindowServer cannot
// satisfy the next session.
static void macws_publish_graphics_ready_once(void) {
    static _Atomic int published = 0;
    if (atomic_exchange_explicit(&published, 1, memory_order_acq_rel)) return;
    int fd = open("/tmp/macws_graphics_ready",
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) {
        atomic_store_explicit(&published, 0, memory_order_release);
        return;
    }
    dprintf(fd, "%d\n", getpid());
    close(fd);
}

extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef);
// Present in the iOS 16 IOSurface binary but omitted from this Theos SDK's
// public header. mac_hooks.m interposes it with the cross-image field adapter.
extern size_t IOSurfaceGetOffsetOfPlane(IOSurfaceRef, size_t);
extern int IOSurfaceLock(IOSurfaceRef, uint32_t options, uint32_t *seed);
extern int IOSurfaceUnlock(IOSurfaceRef, uint32_t options, uint32_t *seed);
// These property-backed adapters live in mac_hooks.m. Calls originating in
// libmachook itself are not rewritten by DYLD_INTERPOSE, so focused evidence
// must name the adapters directly instead of re-reading macOS field offsets.
extern size_t macws_IOSurfaceGetWidthOfPlane(IOSurfaceRef, size_t);
extern size_t macws_IOSurfaceGetHeightOfPlane(IOSurfaceRef, size_t);
extern size_t macws_IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef, size_t);
extern size_t macws_IOSurfaceGetOffsetOfPlane(IOSurfaceRef, size_t);
extern void *macws_IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef, size_t);

// MACWS_DISP_FILL_LOOP read-path probe (2026-06-20). Resolved once: enabled
// by env MACWS_DISP_FILL_LOOP or sentinel file /tmp/macws_disp_fill (chroot
// path; lets us toggle with a FAST libmachook-only build, no WS-plist edit
// that would trip the build guardrail). See
// [[vnc-read-path-is-cgdisplaycreateimage-compositor-black]]: CGDisplayCreateImage
// reads SkyLight's display surface; SURF_FILL_IOS filled it only at creation
// so WS's black composites overwrote it. This drives a continuous bg fill so
// the gray survives between composites — decisive for whether CreateImage
// reads the surface (CPU-copy bridge viable) or re-composites (need pinned VA).
extern size_t IOSurfaceGetWidth(IOSurfaceRef);
extern size_t IOSurfaceGetHeight(IOSurfaceRef);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef);
// Display-surface bridge mode. 0 = off, 1 = gray-fill (validation: proves
// CGDisplayCreateImage reads the surface), 2 = REAL copy (texture +0xa0
// backing -> IOSurface, the actual CPU-copy bridge). Resolved once via env
// or sentinel files so we can toggle with a FAST libmachook-only build
// (a WS-plist env edit would trip the build guardrail).
//   /tmp/macws_disp_copy  -> mode 2 (real content)
//   /tmp/macws_disp_fill  -> mode 1 (gray)
static int macws_disp_mode(void) {
    static int cached = -1;
    if (cached < 0) {
        if (getenv("MACWS_DISP_COPY") || access("/tmp/macws_disp_copy", F_OK) == 0)
            cached = 2;
        else if (getenv("MACWS_DISP_FILL_LOOP") || access("/tmp/macws_disp_fill", F_OK) == 0)
            cached = 1;
        else cached = 0;
    }
    return cached;
}
// Cross-process VNC share: WS mirrors the composite into a GLOBAL IOSurface that
// OSXvnc (a separate process) looks up by ID and blits into its frameBufferData
// (see mac_hooks.m macws_install_osxvnc_hooks / macws_vnc_fill). Gated by
// sentinel /tmp/macws_vnc_share.
extern uint32_t IOSurfaceGetID(IOSurfaceRef);
extern uint32_t macws_IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef,
                                                          size_t);
extern size_t macws_IOSurfaceGetHeightInCompressedTilesOfPlane(IOSurfaceRef,
                                                                size_t);
static uint64_t macws_vnc_capture_generation(void);
static void macws_vnc_ack_capture(uint64_t generation);
extern void macws_dump_recent_agx_submits(const char *reason,
                                          const void *command_buffer);
extern uint64_t macws_latest_agx_submit_serial(const void *command_buffer);
extern unsigned macws_agx_submit_fixed_count(uint64_t submit_serial);
extern int macws_agx_submit_dimensions(uint64_t submit_serial,
                                       uint32_t *width_out,
                                       uint32_t *height_out);
extern void macws_dump_recent_agx_submit_serial(
    const char *reason, const void *command_buffer, uint64_t submit_serial);
extern uint64_t macws_fast_latest_agx_submit_serial(
    const void *command_buffer);
extern unsigned macws_fast_agx_submit_fixed_count(uint64_t submit_serial);
extern void macws_dump_fast_agx_submit_serial(
    const char *reason, const void *command_buffer, uint64_t submit_serial);
extern void macws_mark_agx_submit_for_error_dump(const void *command_buffer);
extern void macws_mark_agx_submit_serial_for_error_dump(
    uint64_t submit_serial);
static void macws_log_failed_texture_descriptor(
    id texture, const void *command_buffer, uint64_t submit_serial);
static void macws_observe_pf550_metadata(id texture, uint64_t submit_serial,
                                         BOOL completed_cleanly);
static void macws_tile_dump_command_buffer_targets(
    const void *command_buffer);

// Read-only completion callback diagnostic.  Runtime ObjC method enumeration
// on the device established these exact private entry points and signatures:
//
//   -[IOGPUMetalCommandQueue didComplete:withStatus:]       v32@0:8@16q24
//   -[IOGPUMetalCommandBuffer
//       didCompleteWithStartTime:endTime:error:]            v40@0:8Q16Q24@32
//
// The queue hook observes the callback before IOGPU turns it into Metal's
// public NSError and before the command buffer's `_storage` ivar is cleared.
// No field is changed and both original implementations are always invoked.
// Enable only with /tmp/macws_iogpu_error_diag.
static void (*g_macws_orig_iogpu_queue_complete)(id, SEL, id, NSInteger) = NULL;
static void (*g_macws_orig_iogpu_buffer_complete)(id, SEL, uint64_t, uint64_t,
                                                  id) = NULL;
static id (*g_macws_orig_iogpu_command_buffer_error)(id, SEL) = NULL;
static _Atomic int64_t g_macws_iogpu_clean_callback_status = INT64_MIN;
static _Atomic uint64_t g_macws_iogpu_callback_count = 0;
static _Atomic int g_macws_iogpu_error_dumped = 0;
static _Atomic int g_macws_iogpu_buffer_error_dumped = 0;
static _Atomic int g_macws_iogpu_buffer_page_fault_dumped = 0;
static _Atomic int g_macws_iogpu_page_fault_seen = 0;
static _Atomic int g_macws_iogpu_post_fault_clean_dumped = 0;
static _Atomic uint32_t g_macws_iogpu_page_fault_width = 0;
static _Atomic uint32_t g_macws_iogpu_page_fault_height = 0;

static BOOL macws_iogpu_callback_diag_enabled(void) {
    return macws_iogpu_error_diag_enabled();
}

static void macws_iogpu_dump_bytes(const char *role, const void *pointer,
                                   size_t length) {
    if (!pointer || (uintptr_t)pointer < 0x1000 || length == 0) return;
    if (length > 0x300) length = 0x300;
    const uint8_t *bytes = pointer;
    for (size_t offset = 0; offset < length; offset += 32) {
        char hex[65] = {0};
        size_t count = length - offset < 32 ? length - offset : 32;
        for (size_t i = 0; i < count; i++)
            snprintf(hex + i * 2, 3, "%02x", bytes[offset + i]);
        fprintf(stderr,
            "#### IOGPU-CALLBACK-BYTES role=%s base=%p offset=%#zx "
            "bytes=%s\n",
            role, pointer, offset, hex);
    }
}

static void macws_iogpu_dump_object(const char *role, id object) {
    if (!object) {
        fprintf(stderr, "#### IOGPU-CALLBACK-OBJECT role=%s object=nil\n",
                role);
        return;
    }
    Class dynamic_class = object_getClass(object);
    size_t instance_size = dynamic_class
        ? class_getInstanceSize(dynamic_class) : 0;
    fprintf(stderr,
        "#### IOGPU-CALLBACK-OBJECT role=%s object=%p dynamicClass=%s "
        "instanceSize=%#zx\n",
        role, (__bridge void *)object,
        dynamic_class ? class_getName(dynamic_class) : "(nil)",
        instance_size);
    Class cls = dynamic_class;
    for (unsigned depth = 0; cls && depth < 8;
         depth++, cls = class_getSuperclass(cls)) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        fprintf(stderr,
            "#### IOGPU-CALLBACK-CLASS role=%s depth=%u class=%s "
            "ivars=%u\n",
            role, depth, class_getName(cls), count);
        for (unsigned i = 0; ivars && i < count; i++) {
            ptrdiff_t offset = ivar_getOffset(ivars[i]);
            uint64_t raw = 0;
            if (offset >= 0 && (size_t)offset + sizeof(raw) <= instance_size)
                memcpy(&raw, (const char *)(__bridge void *)object + offset,
                       sizeof(raw));
            fprintf(stderr,
                "#### IOGPU-CALLBACK-IVAR role=%s class=%s offset=%#tx "
                "name=%s type=%s raw64=%#llx\n",
                role, class_getName(cls), offset,
                ivar_getName(ivars[i]) ?: "(nil)",
                ivar_getTypeEncoding(ivars[i]) ?: "(nil)",
                (unsigned long long)raw);
        }
        free(ivars);
    }
    size_t raw_length = instance_size < 0x100 ? instance_size : 0x100;
    macws_iogpu_dump_bytes(role, (__bridge const void *)object, raw_length);
}

static void macws_iogpu_dump_command_storage(id command_buffer,
                                             const char *role) {
    if (!command_buffer) return;
    Ivar storage_ivar = class_getInstanceVariable(
        [command_buffer class], "_storage");
    if (!storage_ivar) {
        fprintf(stderr,
            "#### IOGPU-CALLBACK-STORAGE role=%s commandBuffer=%p "
            "storageIvar=missing\n",
            role, (__bridge void *)command_buffer);
        return;
    }
    ptrdiff_t offset = ivar_getOffset(storage_ivar);
    void *storage = *(void **)((char *)(__bridge void *)command_buffer +
                              offset);
    fprintf(stderr,
        "#### IOGPU-CALLBACK-STORAGE role=%s commandBuffer=%p class=%s "
        "ivarOffset=%#tx storage=%p\n",
        role, (__bridge void *)command_buffer,
        class_getName([command_buffer class]), offset, storage);
    macws_iogpu_dump_bytes("command-storage", storage, 0x300);
}

static void macws_iogpu_dump_error_user_info(id error) {
    if (!error) return;
    NSString *domain = nil;
    NSDictionary *user_info = nil;
    NSInteger code = 0;
    @try {
        domain = [error respondsToSelector:@selector(domain)]
            ? [error domain] : nil;
        code = [error respondsToSelector:@selector(code)]
            ? (NSInteger)[error code] : 0;
        user_info = [error respondsToSelector:@selector(userInfo)]
            ? [error userInfo] : nil;
    } @catch (NSException *exception) {
        (void)exception;
    }
    fprintf(stderr,
        "#### IOGPU-CALLBACK-ERROR domain=%s code=%ld userInfo=%p "
        "userInfoClass=%s\n",
        domain ? [domain UTF8String] : "(nil)", (long)code,
        (__bridge void *)user_info,
        user_info ? class_getName([user_info class]) : "(nil)");
    macws_iogpu_dump_object("buffer-error-user-info", user_info);
    @try {
        NSArray *keys = [user_info allKeys];
        NSUInteger count = [keys count];
        NSUInteger limit = count < 16 ? count : 16;
        fprintf(stderr,
            "#### IOGPU-CALLBACK-USERINFO count=%lu limit=%lu\n",
            (unsigned long)count, (unsigned long)limit);
        for (NSUInteger i = 0; i < limit; i++) {
            id key = [keys objectAtIndex:i];
            id value = [user_info objectForKey:key];
            const char *key_text = [key isKindOfClass:[NSString class]]
                ? [key UTF8String] : "(non-string)";
            const char *value_class = value
                ? class_getName([value class]) : "(nil)";
            if ([value isKindOfClass:[NSNumber class]]) {
                fprintf(stderr,
                    "#### IOGPU-CALLBACK-USERINFO-ENTRY index=%lu key=%s "
                    "value=%p class=%s uint64=%#llx\n",
                    (unsigned long)i, key_text, (__bridge void *)value,
                    value_class,
                    (unsigned long long)[value unsignedLongLongValue]);
            } else if ([value isKindOfClass:[NSString class]]) {
                fprintf(stderr,
                    "#### IOGPU-CALLBACK-USERINFO-ENTRY index=%lu key=%s "
                    "value=%p class=%s string=%s\n",
                    (unsigned long)i, key_text, (__bridge void *)value,
                    value_class, [value UTF8String] ?: "(nil)");
            } else if ([value isKindOfClass:[NSData class]]) {
                fprintf(stderr,
                    "#### IOGPU-CALLBACK-USERINFO-ENTRY index=%lu key=%s "
                    "value=%p class=%s length=%lu\n",
                    (unsigned long)i, key_text, (__bridge void *)value,
                    value_class, (unsigned long)[value length]);
                macws_iogpu_dump_bytes("buffer-error-user-info-data",
                    [value bytes], [value length]);
            } else {
                fprintf(stderr,
                    "#### IOGPU-CALLBACK-USERINFO-ENTRY index=%lu key=%s "
                    "value=%p class=%s\n",
                    (unsigned long)i, key_text, (__bridge void *)value,
                    value_class);
            }
        }
    } @catch (NSException *exception) {
        fprintf(stderr,
            "#### IOGPU-CALLBACK-USERINFO exception=%s\n",
            [[exception description] UTF8String] ?: "(nil)");
    }
}

static void macws_iogpu_queue_complete(id self, SEL selector,
                                       id command_buffer, NSInteger status) {
    if (macws_iogpu_callback_diag_enabled()) {
        uint64_t count = atomic_fetch_add(&g_macws_iogpu_callback_count, 1) + 1;
        int64_t expected = INT64_MIN;
        (void)atomic_compare_exchange_strong(
            &g_macws_iogpu_clean_callback_status, &expected,
            (int64_t)status);
        int64_t baseline = atomic_load(&g_macws_iogpu_clean_callback_status);
        if (count <= 32 || (int64_t)status != baseline) {
            fprintf(stderr,
                "#### IOGPU-CALLBACK-QUEUE count=%llu queue=%p "
                "commandBuffer=%p class=%s status=%ld baseline=%lld\n",
                (unsigned long long)count, (__bridge void *)self,
                (__bridge void *)command_buffer,
                command_buffer ? class_getName([command_buffer class]) : "(nil)",
                (long)status, (long long)baseline);
        }
        if ((int64_t)status != baseline) {
            int expected_dump = 0;
            if (atomic_compare_exchange_strong(
                    &g_macws_iogpu_error_dumped, &expected_dump, 1)) {
                macws_iogpu_dump_object("queue-error-command-buffer",
                                        command_buffer);
                macws_iogpu_dump_command_storage(command_buffer,
                                                  "queue-before-original");
            }
        }
    }
    g_macws_orig_iogpu_queue_complete(self, selector, command_buffer, status);
}

static void macws_iogpu_buffer_complete(id self, SEL selector,
                                        uint64_t start_time,
                                        uint64_t end_time, id error) {
    NSInteger error_code = 0;
    if (error) {
        @try {
            if ([error respondsToSelector:@selector(code)])
                error_code = (NSInteger)[error code];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    _Atomic int *dump_latch = error_code == 3
        ? &g_macws_iogpu_buffer_page_fault_dumped
        : &g_macws_iogpu_buffer_error_dumped;
    uint64_t submit_serial = 0;
    unsigned fixed_count = 0;
    uint32_t submit_width = 0;
    uint32_t submit_height = 0;
    if (macws_iogpu_callback_diag_enabled()) {
        submit_serial = macws_fast_latest_agx_submit_serial(
            (__bridge const void *)self);
        if (submit_serial) {
            fixed_count = macws_fast_agx_submit_fixed_count(submit_serial);
        } else {
            submit_serial = macws_latest_agx_submit_serial(
                (__bridge const void *)self);
            fixed_count = macws_agx_submit_fixed_count(submit_serial);
            (void)macws_agx_submit_dimensions(
                submit_serial, &submit_width, &submit_height);
        }
        if (!error && fixed_count >= 8) {
            fprintf(stderr,
                "#### IOGPU-CALLBACK-BUFFER-CLEAN commandBuffer=%p "
                "class=%s submitSerial=%llu fixed=%u target=%ux%u "
                "start=%#llx end=%#llx\n",
                (__bridge void *)self, class_getName([self class]),
                (unsigned long long)submit_serial, fixed_count,
                submit_width, submit_height,
                (unsigned long long)start_time,
                (unsigned long long)end_time);
            int expected_clean_dump = 0;
            uint32_t fault_width = atomic_load(
                &g_macws_iogpu_page_fault_width);
            uint32_t fault_height = atomic_load(
                &g_macws_iogpu_page_fault_height);
            if (atomic_load(&g_macws_iogpu_page_fault_seen) == 1 &&
                submit_width == fault_width &&
                submit_height == fault_height &&
                atomic_compare_exchange_strong(
                    &g_macws_iogpu_post_fault_clean_dumped,
                    &expected_clean_dump, 1)) {
                macws_dump_recent_agx_submit_serial(
                    "iogpu-post-page-fault-clean",
                    (__bridge const void *)self, submit_serial);
            }
        }
    }
    if (error && error_code == 3) {
        int expected_fault_state = 0;
        if (atomic_compare_exchange_strong(
                &g_macws_iogpu_page_fault_seen,
                &expected_fault_state, -1)) {
            atomic_store(&g_macws_iogpu_page_fault_width, submit_width);
            atomic_store(&g_macws_iogpu_page_fault_height, submit_height);
            atomic_store(&g_macws_iogpu_page_fault_seen, 1);
        }
    }
    int expected_dump = 0;
    if (macws_iogpu_callback_diag_enabled() && error &&
        atomic_compare_exchange_strong(
            dump_latch, &expected_dump, 1)) {
        fprintf(stderr,
            "#### IOGPU-CALLBACK-BUFFER commandBuffer=%p class=%s "
            "submitSerial=%llu fixed=%u target=%ux%u errorCode=%ld "
            "start=%#llx end=%#llx error=%p "
            "errorClass=%s\n",
            (__bridge void *)self, class_getName([self class]),
            (unsigned long long)submit_serial,
            fixed_count,
            submit_width, submit_height,
            (long)error_code,
            (unsigned long long)start_time, (unsigned long long)end_time,
            (__bridge void *)error, class_getName([error class]));
        macws_iogpu_dump_object("buffer-error", error);
        macws_iogpu_dump_error_user_info(error);
        macws_iogpu_dump_command_storage(self, "buffer-before-original");
        if (error_code == 3) {
            macws_tile_dump_command_buffer_targets(
                (__bridge const void *)self);
        }
        if (submit_serial) {
            macws_dump_fast_agx_submit_serial(
                error_code == 3 ? "iogpu-raw-callback-page-fault"
                                : "iogpu-raw-callback-error",
                (__bridge const void *)self, submit_serial);
            macws_dump_recent_agx_submit_serial(
                error_code == 3 ? "iogpu-raw-callback-page-fault"
                                : "iogpu-raw-callback-error",
                (__bridge const void *)self, submit_serial);
        }
    }
    g_macws_orig_iogpu_buffer_complete(
        self, selector, start_time, end_time, error);
}

// The raw IOGPU completion callback is not the final source of every NSError
// exposed by an AGX command buffer.  Chromium 148 receives repeated
// `Internal Error (00000102:Internal Error)` objects even when
// -didCompleteWithStartTime:endTime:error: was called with error=nil.  Observe
// the public/private command-buffer error getter at the point ANGLE reads it,
// then join that exact object to the selector-0x1a flight recorder.  This is a
// read-only diagnostic: it returns the original NSError unchanged and is
// inert unless /tmp/macws_command_error_diag exists.
static id macws_iogpu_command_buffer_error(id self, SEL selector) {
    id error = g_macws_orig_iogpu_command_buffer_error
        ? g_macws_orig_iogpu_command_buffer_error(self, selector) : nil;
    if (!error ||
        !macws_command_error_diag_enabled()) {
        return error;
    }

    static _Atomic unsigned observation_count = 0;
    static _Atomic int dumped_102 = 0;
    static _Atomic int dumped_103 = 0;
    static _Atomic int dumped_other = 0;
    unsigned observation = atomic_fetch_add(&observation_count, 1) + 1;
    uint64_t fast_submit_serial = macws_fast_latest_agx_submit_serial(
        (__bridge const void *)self);
    uint64_t submit_serial = fast_submit_serial ?: macws_latest_agx_submit_serial(
        (__bridge const void *)self);
    unsigned fixed = fast_submit_serial
        ? macws_fast_agx_submit_fixed_count(fast_submit_serial)
        : macws_agx_submit_fixed_count(submit_serial);
    NSString *description = nil;
    NSString *domain = nil;
    NSInteger code = 0;
    @try {
        description = [error localizedDescription];
        domain = [error domain];
        code = [error code];
    } @catch (NSException *exception) {
        (void)exception;
    }
    const char *description_text = description
        ? [description UTF8String] : "(nil)";
    if (observation <= 64 || (observation & (observation - 1)) == 0) {
        fprintf(stderr,
            "#### IOGPU-ERROR-GETTER observation=%u commandBuffer=%p "
            "class=%s submitSerial=%llu fixed=%u domain=%s code=%ld "
            "description=%s\n",
            observation, (__bridge void *)self, class_getName([self class]),
            (unsigned long long)submit_serial, fixed,
            domain ? [domain UTF8String] : "(nil)", (long)code,
            description_text);
    }

    _Atomic int *dump_latch = &dumped_other;
    const char *reason = "iogpu-error-getter-other";
    if (description_text && strstr(description_text, "00000102")) {
        dump_latch = &dumped_102;
        reason = "iogpu-error-getter-102";
    } else if (description_text && strstr(description_text, "00000103")) {
        dump_latch = &dumped_103;
        reason = "iogpu-error-getter-103";
    }
    // Chromium can expose an NSError for a command-buffer object before the
    // selector-0x1a submit observer has joined that object to a flight-recorder
    // serial.  Freezing the one-shot ring for submitSerial=0 captured no exact
    // payload and prevented the next, runtime-confirmed mapped 0x103 from being
    // recorded (2026-07-30: observation 1 serial=0, then observation 2
    // serial=94 fixed=8).  An unmapped observation remains logged above, but it
    // cannot be the evidence-bearing one-shot: wait for a nonzero serial whose
    // bytes can be matched and validated.  This changes diagnostics only; the
    // NSError and command submission are untouched.
    if (!submit_serial) return error;
    int expected = 0;
    if (atomic_compare_exchange_strong(dump_latch, &expected, 1)) {
        // The command-buffer getter can synthesize an NSError even when the
        // earlier raw IOGPU completion callback received error=nil.  Preserve
        // the actual getter-side object, userInfo and still-readable storage
        // before the flight recorder freezes; this is read-only evidence for
        // distinguishing parser status 0x100 from a stale public NSError.
        macws_iogpu_dump_object("getter-error", error);
        macws_iogpu_dump_error_user_info(error);
        macws_iogpu_dump_command_storage(self, "getter-error");
        macws_dump_fast_agx_submit_serial(
            reason, (__bridge const void *)self, fast_submit_serial);
        if (submit_serial) {
            macws_dump_recent_agx_submit_serial(
                reason, (__bridge const void *)self, submit_serial);
        } else {
            macws_dump_recent_agx_submits(
                reason, (__bridge const void *)self);
        }
    }
    return error;
}

static void macws_install_iogpu_callback_diagnostics(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class queue_class = objc_getClass("IOGPUMetalCommandQueue");
        SEL queue_selector = sel_registerName("didComplete:withStatus:");
        Method queue_method = queue_class
            ? class_getInstanceMethod(queue_class, queue_selector) : NULL;
        Class buffer_class = objc_getClass("IOGPUMetalCommandBuffer");
        SEL buffer_selector = sel_registerName(
            "didCompleteWithStartTime:endTime:error:");
        Method buffer_method = buffer_class
            ? class_getInstanceMethod(buffer_class, buffer_selector) : NULL;
        SEL error_selector = @selector(error);
        Method error_method = buffer_class
            ? class_getInstanceMethod(buffer_class, error_selector) : NULL;
        if (queue_method) {
            g_macws_orig_iogpu_queue_complete =
                (void *)method_setImplementation(
                    queue_method, (IMP)macws_iogpu_queue_complete);
        }
        if (buffer_method) {
            g_macws_orig_iogpu_buffer_complete =
                (void *)method_setImplementation(
                    buffer_method, (IMP)macws_iogpu_buffer_complete);
        }
        if (error_method) {
            g_macws_orig_iogpu_command_buffer_error =
                (void *)method_setImplementation(
                    error_method, (IMP)macws_iogpu_command_buffer_error);
        }
        fprintf(stderr,
            "#### IOGPU-CALLBACK-DIAG installed queueClass=%p method=%p "
            "orig=%p bufferClass=%p method=%p orig=%p errorMethod=%p "
            "errorOrig=%p (file-gated)\n",
            queue_class, queue_method, g_macws_orig_iogpu_queue_complete,
            buffer_class, buffer_method, g_macws_orig_iogpu_buffer_complete,
            error_method, g_macws_orig_iogpu_command_buffer_error);
    });
}

static void macws_log_command_buffer_ivars(id commandBuffer) {
    if (!commandBuffer || !macws_submit_ring_enabled())
        return;
    Class cls = object_getClass(commandBuffer);
    fprintf(stderr,
        "#### AGX_SUBMIT_RING error-object=%p dynamicClass=%s\n",
        (__bridge void *)commandBuffer, cls ? class_getName(cls) : "(nil)");
    for (unsigned depth = 0; cls && depth < 8; depth++, cls = class_getSuperclass(cls)) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        size_t instanceSize = class_getInstanceSize(cls);
        fprintf(stderr,
            "#### AGX_SUBMIT_RING class[%u]=%s instanceSize=%#zx ivars=%u\n",
            depth, class_getName(cls), instanceSize, count);
        for (unsigned i = 0; ivars && i < count; i++) {
            ptrdiff_t offset = ivar_getOffset(ivars[i]);
            uint64_t raw = 0;
            if (offset >= 0 && (size_t)offset + sizeof(raw) <= instanceSize)
                memcpy(&raw, (const char *)(__bridge void *)commandBuffer + offset,
                       sizeof(raw));
            fprintf(stderr,
                "####   ivar +%#tx name=%s type=%s raw64=%#llx\n",
                offset, ivar_getName(ivars[i]) ?: "(nil)",
                ivar_getTypeEncoding(ivars[i]) ?: "(nil)",
                (unsigned long long)raw);
        }
        free(ivars);
    }
}

// These registries must exist in both library slices. The code that creates
// owned AGX textures is arm64-only on the on-device build, while VNC/AppKit
// helpers are compiled in arm64e processes too and must safely observe an
// empty registry there.
static NSObject *g_macws_owned_scanout_lock = nil;
static NSMutableDictionary *g_macws_owned_scanout_pool = nil;
static NSUInteger g_macws_owned_scanout_pool_bytes = 0;
static uint64_t g_macws_owned_scanout_clock = 0;
static char g_macws_owned_texture_association_key;
static BOOL macws_is_owned_scanout_texture(id<MTLTexture> texture) {
    return texture && objc_getAssociatedObject(
        texture, &g_macws_owned_texture_association_key) != nil;
}
static IOSurfaceRef g_vncSurf = NULL;
static int macws_vnc_share_enabled(void) {
    static int c = -1;
    if (c < 0) c = (getenv("MACWS_VNC_SHARE") || access("/tmp/macws_vnc_share", F_OK) == 0) ? 1 : 0;
    return c;
}
static int macws_final_composite_enabled(void) {
    static int c = -1;
    if (c < 0) c = (getenv("MACWS_FINAL_COMPOSITE") ||
                    access("/tmp/macws_final_composite", F_OK) == 0) ? 1 : 0;
    return c;
}
static int macws_composite_capture_enabled(void) {
    return macws_vnc_share_enabled() || macws_final_composite_enabled();
}
static void macws_vnc_share_ensure(size_t w, size_t h) {
    if (g_vncSurf || w < 1000 || h < 600) return;
    NSDictionary *p = @{ @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
        @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
        @"IOSurfaceIsGlobal": @YES };
    g_vncSurf = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    if (g_vncSurf) {
        uint32_t sid = IOSurfaceGetID(g_vncSurf);
        FILE *f = fopen("/tmp/macws_vnc_surfid", "w");
        if (f) { fprintf(f, "%u\n", (unsigned)sid); fclose(f); }
        fprintf(stderr, "#### VNC-SHARE global surf id=%u %zux%zu\n", (unsigned)sid, w, h);
    }
}
// Mirror a filled display surface (base/sbpr/sh) into g_vncSurf for OSXvnc.
static void macws_vnc_share_mirror(void *base, size_t sbpr, size_t sh, size_t w) {
    if (!macws_vnc_share_enabled() || !base) return;
    // Skip empty/black surfaces so an empty frame doesn't CLOBBER a
    // content-bearing one (the bg loop mirrors every tracked surface,
    // last-writer-wins). Only mirror when this surface actually has content.
    size_t nz = 0, samp = 0, tot = sbpr * sh;
    for (size_t off = 0; off < tot; off += 4096) { if (((uint8_t *)base)[off]) nz++; samp++; }
    if (!samp || (double)nz / samp < 0.01) return;
    macws_vnc_share_ensure(w, sh);
    if (!g_vncSurf) return;
    if (IOSurfaceLock(g_vncSurf, 0, NULL) != 0) return;
    void *vb = IOSurfaceGetBaseAddress(g_vncSurf);
    size_t vbpr = IOSurfaceGetBytesPerRow(g_vncSurf);
    size_t vh = IOSurfaceGetHeight(g_vncSurf);
    if (vb) {
        size_t cw = sbpr < vbpr ? sbpr : vbpr;
        size_t rows = sh < vh ? sh : vh;
        for (size_t y = 0; y < rows; y++)
            memcpy((char *)vb + y * vbpr, (char *)base + y * sbpr, cw);
    }
    IOSurfaceUnlock(g_vncSurf, 0, NULL);
}
// Cross-process VNC channel via a MMAP'd file (IOSurfaceIsGlobal+Lookup(id)
// returns NULL across processes on this iOS — RE-confirmed). Both WS and OSXvnc
// are in the chroot and see /tmp/macws_vnc_fb. WS writes the detiled BGRA8 frame
// here; OSXvnc mmaps it read-only and blits into frameBufferData. Header (16B):
// [0]=magic 'VNCF', [1]=w, [2]=h, [3]=stride(=w*4); pixel data follows and an
// atomic uint64_t publication sequence follows the pixels. Odd means a writer
// owns the frame; even/nonzero means a complete frame. The file descriptor is
// retained so producer writes can also hold an advisory exclusive flock.
// OSXvnc takes the matching shared lock while copying a snapshot; this avoids
// repeatedly discarding a 15.2-MiB copy merely because the next 60-Hz frame
// began before its sequence validation. The sequence remains the corruption
// witness and generation notification protocol.
#import <sys/mman.h>
#import <fcntl.h>
static void *g_vnc_mmap = NULL;       // base (header + data)
static size_t g_vnc_mmap_w = 0, g_vnc_mmap_h = 0;
static _Atomic uint64_t *g_vnc_mmap_sequence = NULL;
static int g_vnc_mmap_fd = -1;
static pthread_mutex_t g_vnc_mmap_write_lock = PTHREAD_MUTEX_INITIALIZER;
// Protected by g_vnc_mmap_write_lock. 8192/16 = 512 tiles per dimension,
// matching the validated maximum framebuffer geometry below.
static uint8_t g_vnc_dirty_tiles[512 * 512];

enum {
    MacWSVNCDamageMagic = 0x564E444Du,
    MacWSVNCDamageTile = 16,
    MacWSVNCDamageMaxRectangles = 256,
    MacWSVNCDamageMaxTileColumns = 512,
    MacWSVNCDamageMaxTileRows = 512,
};
typedef struct {
    uint32_t x;
    uint32_t y;
    uint32_t rectWidth;
    uint32_t rectHeight;
} MacWSVNCDamageRect;
typedef struct {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t rectCount;
    uint64_t sequence;
    uint64_t changedPixels;
    uint32_t dirtyTileCount;
    uint32_t flags; // bit 0: rectangle-cap overflow, bounding fallback used
    MacWSVNCDamageRect rectangles[MacWSVNCDamageMaxRectangles];
} MacWSVNCDamageMessage;

// RFB Zlib owns one deflate operation per rectangle. Runtime InputLab capture
// measured a 95-Kpixel button update split into 57 sixteen-pixel-high runs;
// the update took 99-224 ms even though the pixel payload itself was small.
// Coalesce nearby horizontal runs into vertical bands only when a cost model
// predicts that the extra pixels are cheaper than the eliminated encoders.
// Widely separated bands remain independent, so a cursor and a distant
// control never force a full-desktop rectangle.
// The mmap remains the pixel transport. This datagram is only a committed
// generation's damage notification, replacing the lossy need for OSXvnc to
// rediscover damage by copying/diffing 15.2 MiB after every producer frame.
// sendto is nonblocking; the existing mmap generation watcher remains the
// fallback when the VNC process has not bound its socket yet.
static void macws_vnc_notify_damage(uint64_t sequence, size_t width,
        size_t height, size_t minX, size_t minY, size_t maxX, size_t maxY,
        const uint8_t *dirtyTiles, size_t tileColumns, size_t tileRows,
        uint64_t changedPixels) {
    if (sequence == 0 || minX >= maxX || minY >= maxY ||
        width > UINT32_MAX || height > UINT32_MAX ||
        maxX > width || maxY > height) return;
    static int damageFD = -1;
    if (damageFD < 0) damageFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (damageFD < 0) return;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/tmp/macws_vnc_damage.sock",
            sizeof(address.sun_path));
    MacWSVNCDamageMessage message = {
        .magic = MacWSVNCDamageMagic,
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .sequence = sequence,
        .changedPixels = changedPixels,
    };
    int16_t active[MacWSVNCDamageMaxTileColumns];
    int16_t nextActive[MacWSVNCDamageMaxTileColumns];
    BOOL overflow = !dirtyTiles || tileColumns == 0 || tileRows == 0 ||
        tileColumns > MacWSVNCDamageMaxTileColumns ||
        tileRows > MacWSVNCDamageMaxTileRows;
    uint32_t dirtyTileCount = 0;
    if (!overflow) {
        memset(active, 0xff, sizeof(active));
        for (size_t tileY = 0; tileY < tileRows && !overflow; tileY++) {
            memset(nextActive, 0xff, sizeof(nextActive));
            size_t tileX = 0;
            while (tileX < tileColumns) {
                if (!dirtyTiles[tileY * tileColumns + tileX]) {
                    tileX++;
                    continue;
                }
                size_t runStart = tileX;
                while (tileX < tileColumns &&
                       dirtyTiles[tileY * tileColumns + tileX]) {
                    dirtyTileCount++;
                    tileX++;
                }
                size_t runEnd = tileX;
                uint32_t x = (uint32_t)(runStart * MacWSVNCDamageTile);
                uint32_t y = (uint32_t)(tileY * MacWSVNCDamageTile);
                uint32_t rectWidth = (uint32_t)MIN(
                    width - x, (runEnd - runStart) * MacWSVNCDamageTile);
                uint32_t rectHeight = (uint32_t)MIN(
                    height - y, (size_t)MacWSVNCDamageTile);
                int rectangleIndex = active[runStart];
                if (rectangleIndex >= 0 &&
                    (uint32_t)rectangleIndex < message.rectCount) {
                    MacWSVNCDamageRect *existing =
                        &message.rectangles[rectangleIndex];
                    if (existing->x != x || existing->rectWidth != rectWidth ||
                        existing->y + existing->rectHeight != y) {
                        rectangleIndex = -1;
                    }
                }
                if (rectangleIndex < 0) {
                    if (message.rectCount >=
                        MacWSVNCDamageMaxRectangles) {
                        overflow = YES;
                        break;
                    }
                    rectangleIndex = (int)message.rectCount++;
                    message.rectangles[rectangleIndex] =
                        (MacWSVNCDamageRect){x, y, rectWidth, rectHeight};
                } else {
                    message.rectangles[rectangleIndex].rectHeight +=
                        rectHeight;
                }
                nextActive[runStart] = (int16_t)rectangleIndex;
            }
            memcpy(active, nextActive, sizeof(active));
        }
    }
    if (overflow || message.rectCount == 0) {
        message.flags |= 1u;
        message.rectCount = 1;
        message.rectangles[0] = (MacWSVNCDamageRect){
            (uint32_t)minX, (uint32_t)minY,
            (uint32_t)(maxX - minX), (uint32_t)(maxY - minY),
        };
    }
    message.dirtyTileCount = dirtyTileCount;
    size_t messageBytes = offsetof(MacWSVNCDamageMessage, rectangles) +
        (size_t)message.rectCount * sizeof(message.rectangles[0]);
    ssize_t sent = sendto(damageFD, &message, messageBytes, MSG_DONTWAIT,
                          (const struct sockaddr *)&address, sizeof(address));
    static _Atomic uint64_t sentCount = 0;
    static _Atomic uint64_t failureCount = 0;
    uint64_t count = 0;
    if (macws_runtime_diagnostics_enabled()) {
        count = sent == (ssize_t)messageBytes
            ? atomic_fetch_add(&sentCount, 1) + 1
            : atomic_fetch_add(&failureCount, 1) + 1;
    }
    if (count && ((sent == (ssize_t)messageBytes &&
         (count <= 16 || (count % 600) == 0)) ||
        (sent != (ssize_t)messageBytes && count <= 4))) {
        fprintf(stderr,
            "#### VNC-DAMAGE %s #%llu sequence=%llu rects=%u "
            "tiles=%u changed=%llu bounds=%zu,%zu %zux%zu "
            "overflow=%s errno=%d\n",
            sent == (ssize_t)messageBytes ? "sent" : "miss",
            (unsigned long long)count, (unsigned long long)sequence,
            message.rectCount, message.dirtyTileCount,
            (unsigned long long)message.changedPixels,
            minX, minY, maxX - minX, maxY - minY,
            (message.flags & 1u) ? "YES" : "NO",
            sent == (ssize_t)messageBytes ? 0 : errno);
    }
}
static void *macws_vnc_mmap_data(size_t w, size_t h) {
    if (g_vnc_mmap && g_vnc_mmap_w == w && g_vnc_mmap_h == h)
        return (char *)g_vnc_mmap + 16;
    size_t stride = w * 4, pixelBytes = stride * h;
    size_t sz = 16 + pixelBytes + sizeof(uint64_t);
    // This is the first mapping made by this WindowServer producer.  Truncate
    // even when the dimensions match the previous session: same-size
    // ftruncate alone preserves all old pixel pages and allowed OSXvnc to show
    // a stale GlassDemo while the current Terminal session had no valid frame.
    int fd = open("/tmp/macws_vnc_fb", O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) return NULL;
    if (ftruncate(fd, sz) != 0) { close(fd); return NULL; }
    void *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return NULL; }
    uint32_t *hdr = (uint32_t *)m;
    hdr[0] = 0x564E4346u; hdr[1] = (uint32_t)w; hdr[2] = (uint32_t)h; hdr[3] = (uint32_t)stride;
    g_vnc_mmap_sequence = (_Atomic uint64_t *)((char *)m + 16 + pixelBytes);
    atomic_store_explicit(g_vnc_mmap_sequence, 0, memory_order_relaxed);
    g_vnc_mmap_fd = fd;
    g_vnc_mmap = m; g_vnc_mmap_w = w; g_vnc_mmap_h = h;
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr, "#### VNC-MMAP /tmp/macws_vnc_fb %zux%zu sz=%zu\n", w, h, sz);
    }
    return (char *)m + 16;
}

static void *macws_vnc_mmap_begin_frame(size_t w, size_t h) {
    pthread_mutex_lock(&g_vnc_mmap_write_lock);
    void *data = macws_vnc_mmap_data(w, h);
    if (!data || !g_vnc_mmap_sequence) {
        pthread_mutex_unlock(&g_vnc_mmap_write_lock);
        return NULL;
    }
    if (g_vnc_mmap_fd >= 0 && flock(g_vnc_mmap_fd, LOCK_EX) != 0) {
        static _Atomic uint64_t lockFailures = 0;
        uint64_t count = atomic_fetch_add(&lockFailures, 1) + 1;
        if (count && (count <= 8 || (count % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-MMAP producer flock failed #%llu errno=%d\n",
                (unsigned long long)count, errno);
        }
    }
    uint64_t sequence = atomic_load_explicit(g_vnc_mmap_sequence,
                                             memory_order_relaxed);
    if (sequence & 1u) sequence++;
    atomic_store_explicit(g_vnc_mmap_sequence, sequence + 1,
                          memory_order_release);
    return data;
}

static uint64_t macws_vnc_mmap_commit_frame(void) {
    uint64_t sequence = 0;
    if (g_vnc_mmap_sequence) {
        atomic_thread_fence(memory_order_release);
        sequence = atomic_fetch_add_explicit(g_vnc_mmap_sequence, 1,
                                             memory_order_release) + 1;
    }
    if (g_vnc_mmap_fd >= 0) (void)flock(g_vnc_mmap_fd, LOCK_UN);
    pthread_mutex_unlock(&g_vnc_mmap_write_lock);
    static _Atomic uint64_t committed = 0;
    uint64_t count = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&committed, 1) + 1 : 0;
    if (count && (count <= 16 || (count % 600) == 0)) {
        fprintf(stderr,
            "#### VNC-MMAP committed #%llu sequence=%llu %zux%zu\n",
            (unsigned long long)count, (unsigned long long)sequence,
            g_vnc_mmap_w, g_vnc_mmap_h);
    }
    return sequence;
}

// Producer-side unchanged-frame suppression for the linear owned scanout.
// Runtime evidence on 2026-07-28 showed OSXvnc reaching mmap generation #600
// with changed=NO while WindowServer still copied all 15.2 MiB and advanced
// the seqlock for every synthetic completion.  Besides wasting unified-memory
// bandwidth, those no-op publications can overtake OSXvnc's local 15.2-MiB
// comparison and make it invalidate its snapshot, forcing a later full-screen
// raw update.  Compare before making the sequence odd; an identical frame is
// left completely unpublished.  A changed frame retains the established
// odd/copy/even seqlock protocol and copies the full coherent snapshot.
static BOOL macws_vnc_mmap_publish_bgra_if_changed(
        const void *source, size_t sourceBytesPerRow,
        size_t width, size_t height, BOOL *didCommit) {
    if (didCommit) *didCommit = NO;
    if (!source || width == 0 || height == 0 ||
        width > SIZE_MAX / 4 || sourceBytesPerRow < width * 4) return NO;

    pthread_mutex_lock(&g_vnc_mmap_write_lock);
    void *shared = macws_vnc_mmap_data(width, height);
    if (!shared || !g_vnc_mmap_sequence) {
        pthread_mutex_unlock(&g_vnc_mmap_write_lock);
        return NO;
    }
    if (g_vnc_mmap_fd >= 0 && flock(g_vnc_mmap_fd, LOCK_EX) != 0) {
        static _Atomic uint64_t lockFailures = 0;
        uint64_t count = atomic_fetch_add(&lockFailures, 1) + 1;
        if (count && (count <= 8 || (count % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-MMAP publish flock failed #%llu errno=%d\n",
                (unsigned long long)count, errno);
        }
    }

    size_t visibleRowBytes = width * 4;
    uint64_t sequence = atomic_load_explicit(
        g_vnc_mmap_sequence, memory_order_acquire);
    BOOL changed = sequence == 0 || (sequence & 1u) != 0;
    size_t minX = changed ? 0 : width;
    size_t minY = changed ? 0 : height;
    size_t maxX = changed ? width : 0;
    size_t maxY = changed ? height : 0;
    size_t tileColumns = (width + MacWSVNCDamageTile - 1u) /
        MacWSVNCDamageTile;
    size_t tileRows = (height + MacWSVNCDamageTile - 1u) /
        MacWSVNCDamageTile;
    size_t tileCount = tileColumns * tileRows;
    uint64_t changedPixels = changed ? (uint64_t)width * height : 0;
    if (tileColumns > MacWSVNCDamageMaxTileColumns ||
        tileRows > MacWSVNCDamageMaxTileRows ||
        tileCount > sizeof(g_vnc_dirty_tiles)) {
        if (g_vnc_mmap_fd >= 0) (void)flock(g_vnc_mmap_fd, LOCK_UN);
        pthread_mutex_unlock(&g_vnc_mmap_write_lock);
        return NO;
    }
    memset(g_vnc_dirty_tiles, changed ? 1 : 0, tileCount);
    if (!changed) {
        for (size_t y = 0; y < height; y++) {
            const uint32_t *sourceRow = (const uint32_t *)
                ((const char *)source + y * sourceBytesPerRow);
            const uint32_t *sharedRow = (const uint32_t *)
                ((const char *)shared + y * visibleRowBytes);
            if (memcmp(sourceRow, sharedRow, visibleRowBytes) == 0) continue;
            for (size_t x = 0; x < width; x++) {
                if (sourceRow[x] == sharedRow[x]) continue;
                g_vnc_dirty_tiles[(y / MacWSVNCDamageTile) * tileColumns +
                                  x / MacWSVNCDamageTile] = 1;
                if (x < minX) minX = x;
                if (x + 1 > maxX) maxX = x + 1;
                if (y < minY) minY = y;
                if (y + 1 > maxY) maxY = y + 1;
                changedPixels++;
                changed = YES;
            }
        }
    }
    if (!changed) {
        if (g_vnc_mmap_fd >= 0) (void)flock(g_vnc_mmap_fd, LOCK_UN);
        pthread_mutex_unlock(&g_vnc_mmap_write_lock);
        static _Atomic uint64_t unchangedCount = 0;
        uint64_t count = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&unchangedCount, 1) + 1 : 0;
        if (count && (count <= 8 || (count % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-MMAP unchanged skip #%llu sequence=%llu "
                "%zux%zu\n",
                (unsigned long long)count,
                (unsigned long long)sequence, width, height);
        }
        return YES;
    }

    if (sequence & 1u) sequence++;
    atomic_store_explicit(g_vnc_mmap_sequence, sequence + 1,
                          memory_order_release);
    for (size_t y = 0; y < height; y++) {
        memcpy((char *)shared + y * visibleRowBytes,
               (const char *)source + y * sourceBytesPerRow,
               visibleRowBytes);
    }
    // Publish the even sequence before the datagram, but keep both the local
    // writer mutex and file lock until the compact rectangle message has been
    // built from g_vnc_dirty_tiles. This preserves the seqlock invariant and
    // prevents a second publisher from replacing the shared scratch map while
    // the notification is being serialized.
    uint64_t committedSequence = atomic_fetch_add_explicit(
        g_vnc_mmap_sequence, 1, memory_order_release) + 1;
    macws_vnc_notify_damage(committedSequence, width, height,
                            minX, minY, maxX, maxY,
                            g_vnc_dirty_tiles, tileColumns, tileRows,
                            changedPixels);
    if (g_vnc_mmap_fd >= 0) (void)flock(g_vnc_mmap_fd, LOCK_UN);
    pthread_mutex_unlock(&g_vnc_mmap_write_lock);
    static _Atomic uint64_t committedCount = 0;
    uint64_t committed = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&committedCount, 1) + 1 : 0;
    if (committed && (committed <= 8 || (committed % 600) == 0)) {
        fprintf(stderr,
            "#### VNC-MMAP sparse committed #%llu sequence=%llu "
            "%zux%zu changed=%llu\n",
            (unsigned long long)committed,
            (unsigned long long)committedSequence,
            width, height, (unsigned long long)changedPixels);
    }
    if (didCommit) *didCommit = YES;
    return YES;
}
// Half (IEEE binary16) -> u8 [0,255], clamped to [0,1]. For RGBA16Float composites.
static inline uint8_t macws_half_to_u8(uint16_t h) {
    uint16_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff;
    float f;
    if (e == 0) f = ldexpf((float)m, -24);
    else if (e == 31) f = 1.0f;
    else f = ldexpf((float)(m + 1024), (int)e - 25);
    if (s) f = 0.0f;            // negatives clamp to 0
    if (f < 0) f = 0; if (f > 1) f = 1;
    return (uint8_t)(f * 255.0f + 0.5f);
}
// WS-RENDER-THREAD composite-completion capture. Called from the StartComposite
// hook (mac_hooks.m, WS thread) with the current frame's display destination.
// getBytes the PREVIOUS frame's dest (now GPU-complete) — Metal-native DETILE —
// convert to BGRA8 -> g_vncSurf (cross-process to OSXvnc). This is the reliable
// content source the bg-thread +0xa0 sampling could not be (the backing is only
// valid at completion). getBytes is SAFE on the WS thread between frames (it
// crashed only from the async bg thread racing active render). Throttled. ARC
// keeps the previous texture alive via the strong static.
// Composite-completion capture, SPLIT for safety:
//   - render thread (WSCD StartComposite hook): only STASH the dest texture
//     pointer (cheap, no read) — the big +0xa0 memcpy on the render thread
//     destabilized WS (A/B-confirmed).
//   - background thread: GPU-blit the stashed destination into a Shared texture,
//     wait for completion, then read that destination's IOSurface mapping.
//
// LLDB/RE-confirmed for AGXG13GFamilyTexture on this image:
//   impl+0xa0 = IOSurfaceRef, impl+0xa8 = plane,
//   impl+0x130 = CPU mapping, impl+0x40 = GPU address.
// updateBindDataWithAddresses:... writes +0x130/+0x40 before calling
// texBaseAddressesUpdated.  Do not treat +0xa0 as a byte pointer.
// libmachook is built under MRC.  Keep an explicit ownership reference: the
// StartComposite argument may be released as soon as its hook returns.
static id<MTLTexture> g_vnc_comp_tex = nil;
static id g_vnc_lock = nil;
static _Atomic uint64_t g_vnc_comp_max_area = 0;
static id macws_vnc_retain(id obj) {
#if __has_feature(objc_arc)
    return obj;
#else
    return [obj retain];
#endif
}
static void macws_vnc_release(id obj) {
#if !__has_feature(objc_arc)
    [obj release];
#else
    (void)obj;
#endif
}

static IOSurfaceRef macws_vnc_bound_surface(id<MTLTexture> texture) {
    if (!texture) return NULL;
    void *implementation =
        *(void **)((char *)(__bridge void *)texture + 0x208);
    return (uintptr_t)implementation > 0x1000
        ? *(IOSurfaceRef *)((char *)implementation + 0xa0) : NULL;
}

// Content-backed first-frame classifier. Percentage coverage rejected a
// legitimate 150x105-point Terminal because its complete Retina backing covers
// only ~1.6% of the desktop. Runtime A/B on 2026-07-27 produced two exact
// 2388x1668 GPU readbacks:
//
//   offscreen/title-only: 231 RGB samples, 4 dense rows below the menu bar
//   clamped/full Terminal: 392 RGB samples, 13 dense rows below the menu bar
//
// A dense row has at least four RGB samples (64 physical pixels at this 16px
// sampling interval). Requiring six such non-menu rows admits a small real
// window but rejects a title bar or thin window outline. The diversity check
// independently rejects AGX's spatially constant recovery image.
static BOOL macws_vnc_content_ready(size_t sampled, size_t different,
                                    size_t denseContentRows) {
    return sampled > 0 && different >= 4 && denseContentRows >= 6;
}

// The owned scanout is already an uncompressed, linear BGRA IOSurface. Once
// the producer command buffer has completed, copy its CPU mapping directly.
// Submitting another GPU command buffer here would reintroduce the exact
// cross-queue lifetime bug this path is designed to remove.
static BOOL macws_vnc_publish_owned_texture(id<MTLTexture> texture) {
    IOSurfaceRef surface = macws_vnc_bound_surface(texture);
    if (!surface || !macws_is_owned_scanout_texture(texture)) return NO;
    size_t width = [texture width], height = [texture height];

    // Two narrow A/B probes isolate the first-frame-only failure without
    // changing the producer command stream.  no_read proves whether texture
    // substitution itself remains reusable; unlocked_read distinguishes an
    // IOSurfaceLock coherency transition from a plain unified-memory read.
    // Neither probe is a production synchronization policy.
    if (access("/tmp/macws_owned_no_read", F_OK) == 0) {
        static _Atomic uint64_t noReadCount = 0;
        uint64_t n = atomic_fetch_add(&noReadCount, 1) + 1;
        if (n <= 32 || (n % 600) == 0) {
            fprintf(stderr,
                "#### VNC-OWNED no-read #%llu tex=%p surface=%p id=%u\n",
                (unsigned long long)n, (void *)texture, (void *)surface,
                (unsigned)IOSurfaceGetID(surface));
        }
        return YES;
    }
    BOOL unlockedRead =
        access("/tmp/macws_owned_unlocked_read", F_OK) == 0;
    if ([texture pixelFormat] != MTLPixelFormatBGRA8Unorm ||
        width < 1000 || height < 600 ||
        (!unlockedRead &&
         IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != 0)) {
        return YES; // owned target: never fall back to a cross-queue GPU read
    }
    void *base = IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    BOOL readable = base && bytesPerRow >= width * 4 &&
        surfaceHeight >= height;
    size_t sampled = 0, rgbNonzero = 0, different = 0;
    size_t denseContentRows = 0;
    uint32_t first = 0;
    BOOL haveFirst = NO;
    if (readable) {
        for (size_t y = 0; y < height; y += 16) {
            const uint32_t *row = (const uint32_t *)
                ((const char *)base + y * bytesPerRow);
            size_t rowRGB = 0;
            for (size_t x = 0; x < width; x += 16) {
                uint32_t pixel = row[x];
                sampled++;
                if ((pixel & 0x00ffffffu) != 0) {
                    rgbNonzero++;
                    rowRGB++;
                }
                if (!haveFirst) { first = pixel; haveFirst = YES; }
                else if (pixel != first) different++;
            }
            if (y >= 64 && rowRGB >= 4) denseContentRows++;
        }
    }
    BOOL valid = readable && macws_vnc_content_ready(
        sampled, different, denseContentRows);
    if (valid) {
        MacWSFinalCompositePublisherMarkContentValidated();
    }
    BOOL committed = NO;
    if (valid && macws_vnc_share_enabled()) {
        if (!macws_vnc_mmap_publish_bgra_if_changed(
                base, bytesPerRow, width, height, &committed)) {
            valid = NO;
        }
    }
    if (!unlockedRead)
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    // Runtime-confirmed source boundary: this is the completed, process-owned
    // BGRA target whose mmap copy drives OSXvnc. The initial validated frame
    // is also the admission witness for the direct final-composite publisher.
    // Later producer completions publish before this CPU damage scan, so this
    // block only supplies the first frame and a five-second service-recovery
    // replay. The receiver owns backpressure; no RFB encoding is introduced.
    if (valid) {
        // Damage-driven publication preserves the mmap path's proven idle
        // suppression.  A five-second replay opportunity makes displayd
        // recovery deterministic if it was relaunched while the desktop was
        // static; failed sends do not advance this timestamp.
        static _Atomic uint64_t lastFinalCompositePublication = 0;
        uint64_t now = mach_absolute_time();
        uint64_t last = atomic_load_explicit(
            &lastFinalCompositePublication, memory_order_relaxed);
        static mach_timebase_info_data_t timebase;
        static dispatch_once_t timebaseOnce;
        dispatch_once(&timebaseOnce, ^{
            (void)mach_timebase_info(&timebase);
        });
        BOOL replayDue = last == 0;
        if (!replayDue && timebase.denom && now >= last) {
            long double elapsedNS = (long double)(now - last) *
                timebase.numer / timebase.denom;
            replayDue = elapsedNS >= 5.0e9L;
        }
        if ((MacWSFinalCompositePublisherPublishedSequence() == 0 ||
             replayDue) &&
            MacWSFinalCompositePublisherPublishSurface(
                surface, (uint32_t)[texture pixelFormat])) {
            atomic_store_explicit(&lastFinalCompositePublication, now,
                                  memory_order_relaxed);
        }
    }

    static _Atomic uint64_t publishCount = 0;
    static _Atomic uint64_t rejectCount = 0;
    uint64_t sequence = 0;
    if (macws_runtime_diagnostics_enabled()) {
        sequence = valid
            ? atomic_fetch_add(&publishCount, 1) + 1
            : atomic_fetch_add(&rejectCount, 1) + 1;
    }
    if (sequence && (sequence <= 32 || (sequence % 600) == 0)) {
        fprintf(stderr,
            "#### VNC-OWNED %s #%llu tex=%p surface=%p id=%u "
            "%zux%zu rgb=%zu/%zu different=%zu denseRows=%zu "
            "unlocked=%d committed=%d\n",
            valid ? "published" : "reject-output",
            (unsigned long long)sequence, (void *)texture, (void *)surface,
            (unsigned)IOSurfaceGetID(surface), width, height,
            rgbNonzero, sampled, different, denseContentRows, unlockedRead,
            committed);
    }
    if (valid) {
        uint64_t generation = macws_vnc_capture_generation();
        if (generation != 0) {
            if (macws_vnc_capture_generation() == generation)
                (void)unlink("/tmp/macws_capture_final");
            macws_vnc_ack_capture(generation);
        }
    }
    return YES;
}

void macws_vnc_on_composite(id<MTLTexture> dest) {
    if (!macws_vnc_share_enabled() || !dest) return;

    // Strict A/B boundary for the owned-scanout experiment.  The first
    // WindowServer display composite can be an ordinary PF80 texture before
    // QuartzCore starts wrapping the compressed IOMFB page.  Letting that one
    // frame enter the legacy worker still submits a second command queue and
    // destroys its temporary AGX resources after owned rendering has begun,
    // so a later producer error cannot be attributed to either path.  When
    // owned scanout is requested, no texture at all may enter the legacy GPU
    // capture path; owned textures are published at producer completion by
    // macws_vnc_publish_owned_texture().
    if (macws_owned_scanout_enabled()) {
        static _Atomic uint64_t ownedModeSkipCount = 0;
        uint64_t n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&ownedModeSkipCount, 1) + 1 : 0;
        if (n && (n <= 8 || (n % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-OWNED legacy-blit blocked #%llu tex=%p\n",
                (unsigned long long)n, (void *)dest);
        }
        return;
    }
    size_t candidateWidth = [dest width];
    size_t candidateHeight = [dest height];
    unsigned long candidatePixelFormat = (unsigned long)[dest pixelFormat];
    if (candidateWidth < 1000 || candidateHeight < 600 ||
        candidateWidth > UINT32_MAX || candidateHeight > UINT32_MAX ||
        (candidatePixelFormat != 80 && candidatePixelFormat != 115)) return;

    // Owned scanouts are published directly after their producer completes in
    // macws_vnc_finish_update. Runtime A/B showed that feeding one into this
    // legacy second-queue blit made the following WindowServer submissions
    // fail with MTLCommandBuffer status=Error/code=1.
    if (macws_is_owned_scanout_texture(dest)) return;

    // StartComposite is used for both the display destination and intermediate
    // per-window composites.  Runtime evidence on iPad13,6 showed the correct
    // 2388x1668 display target being replaced by Terminal's 1140x798 target;
    // that also shrank /tmp/macws_vnc_fb and made RFB alternate between a full
    // desktop and a magnified/cropped child surface.  The display target is the
    // largest composite in a WindowServer lifetime.  Permit a larger target to
    // establish/update that invariant, but never let a smaller intermediate
    // target overwrite it.  Equal-area dimensions remain valid for rotation.
    uint64_t candidateArea = (uint64_t)candidateWidth * candidateHeight;
    uint64_t maxArea = atomic_load(&g_vnc_comp_max_area);
    while (candidateArea > maxArea &&
           !atomic_compare_exchange_weak(&g_vnc_comp_max_area,
                                         &maxArea, candidateArea)) {}
    maxArea = atomic_load(&g_vnc_comp_max_area);
    if (candidateArea < maxArea) {
        static _Atomic unsigned int rejected = 0;
        unsigned int n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&rejected, 1) + 1 : 0;
        if (n && (n <= 8 || (n % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-BLIT reject intermediate #%u %zux%zu area=%llu "
                "displayArea=%llu\n",
                n, candidateWidth, candidateHeight,
                (unsigned long long)candidateArea,
                (unsigned long long)maxArea);
        }
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_vnc_lock = [NSObject new];
        [NSThread detachNewThreadWithBlock:^{
            for (;;) {
                @autoreleasepool {
                    id<MTLTexture> t = nil;
                    @synchronized(g_vnc_lock) {
                        t = macws_vnc_retain(g_vnc_comp_tex);
                        // Consume each completed composite once.  The old
                        // loop retained and re-blitted the same texture at
                        // 20 fps forever; runtime lifecycle logs showed
                        // that this eventually advanced IOMFB into a
                        // PF550 SwapCancel/replacement-surface storm even
                        // though no new VNC frame existed.  A later frame
                        // replaces this slot in macws_vnc_on_composite,
                        // naturally coalescing producers faster than the
                        // background copy without dropping ownership.
                        id consumed = g_vnc_comp_tex;
                        g_vnc_comp_tex = nil;
                        macws_vnc_release(consumed);
                    }
                    if (t) {
                    size_t w = [t width], h = [t height];
                    unsigned long pf = (unsigned long)[t pixelFormat];
                    static _Atomic int targetlog = 0;
                    int targetn = macws_runtime_diagnostics_enabled()
                        ? atomic_fetch_add(&targetlog, 1) : INT_MAX;
                    if (targetn < 24) {
                        fprintf(stderr,
                            "#### VNC-BLIT candidate #%d tex=%p class=%s %zux%zu pf=%lu\n",
                            targetn, (void *)t, object_getClassName(t), w, h, pf);
                    }
                    uint64_t area = (uint64_t)w * h;
                    if (w >= 1000 && h >= 600 && (pf == 80 || pf == 115) &&
                        area >= atomic_load(&g_vnc_comp_max_area)) {
                        // GPU blit the (AGX-tiled) LIVE composite into an IDLE
                        // linear texture on our OWN queue (GPU detiles), then
                        // CPU-read the idle dst's IOSurface mapping -> mmap.
                        // Avoids CPU-reading the live target (perturbs WS) and
                        // getBytes (hangs/crashes). The blit READS the live
                        // target on the GPU (tearing at worst, not a crash).
                        static id<MTLDevice> dev = nil;
                        static id<MTLCommandQueue> q = nil;
                        static id<MTLTexture> dst = nil;
                        static unsigned long dstpf = 0; static size_t dstw = 0, dsth = 0;
                        if (!dev) { dev = [t device]; q = [dev newCommandQueue]; }
                        if (dev && q && (!dst || dstpf != pf || dstw != w || dsth != h)) {
                            MTLTextureDescriptor *d = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pf
                                width:w height:h mipmapped:NO];
                            d.storageMode = MTLStorageModeShared;
                            d.usage = MTLTextureUsageShaderRead;
                            dst = [dev newTextureWithDescriptor:d];
                            dstpf = pf; dstw = w; dsth = h;
                            if (macws_runtime_diagnostics_enabled()) {
                                fprintf(stderr, "#### VNC-BLIT dst=%p %zux%zu pf=%lu\n", (void*)dst, w, h, pf);
                            }
                        }
                        if (dst && q) {
                            id<MTLCommandBuffer> cb = [q commandBuffer];
                            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                            [bl copyFromTexture:t sourceSlice:0 sourceLevel:0
                                   sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
                                      toTexture:dst destinationSlice:0 destinationLevel:0
                              destinationOrigin:MTLOriginMake(0,0,0)];
                            [bl endEncoding];
                            [cb commit];
                            [cb waitUntilCompleted];
                            BOOL commandClean =
                                [cb status] == MTLCommandBufferStatusCompleted &&
                                [cb error] == nil;
                            void *impl = *(void **)((char *)(__bridge void *)dst + 0x208);
                            if (commandClean && (uintptr_t)impl > 0x1000) {
                                IOSurfaceRef boundSurface =
                                    *(IOSurfaceRef *)((char *)impl + 0xa0);
                                void *cpuMapping = *(void **)((char *)impl + 0x130);
                                if (boundSurface && cpuMapping &&
                                    IOSurfaceLock(boundSurface, kIOSurfaceLockReadOnly, NULL) == 0) {
                                    void *surfaceBase = IOSurfaceGetBaseAddress(boundSurface);
                                    size_t srcbpr = IOSurfaceGetBytesPerRow(boundSurface);
                                    size_t surfaceHeight = IOSurfaceGetHeight(boundSurface);
                                    static int maplog = 0;
                                    if (maplog < 3) {
                                        fprintf(stderr,
                                            "#### VNC-BLIT mapping tex=%p impl=%p surface=%p "
                                            "cpu130=%p base=%p bpr=%zu h=%zu%s\n",
                                            (void *)dst, impl, (void *)boundSurface,
                                            cpuMapping, surfaceBase, srcbpr, surfaceHeight,
                                            cpuMapping == surfaceBase ? "" : " MISMATCH");
                                        maplog++;
                                    }
                                    size_t vbpr = w * 4;
                                    BOOL readable = surfaceBase &&
                                        surfaceHeight >= h &&
                                        ((pf == 80 && srcbpr >= vbpr) ||
                                         (pf == 115 && srcbpr >= w * 8));
                                    size_t sampled = 0, rgbNonzero = 0,
                                        different = 0, denseContentRows = 0;
                                    uint32_t firstSample = 0;
                                    BOOL haveFirstSample = NO;
                                    if (readable) {
                                        for (size_t y = 0; y < h; y += 16) {
                                            size_t rowRGB = 0;
                                            for (size_t x = 0; x < w; x += 16) {
                                                uint32_t pixel = 0;
                                                if (pf == 80) {
                                                    const uint32_t *row =
                                                        (const uint32_t *)
                                                        ((const char *)surfaceBase +
                                                         y * srcbpr);
                                                    pixel = row[x];
                                                } else {
                                                    const uint16_t *row =
                                                        (const uint16_t *)
                                                        ((const char *)surfaceBase +
                                                         y * srcbpr);
                                                    const uint16_t *source = row + x * 4;
                                                    uint32_t blue =
                                                        macws_half_to_u8(source[2]);
                                                    uint32_t green =
                                                        macws_half_to_u8(source[1]);
                                                    uint32_t red =
                                                        macws_half_to_u8(source[0]);
                                                    pixel = blue | (green << 8) |
                                                        (red << 16) | 0xff000000u;
                                                }
                                                sampled++;
                                                if ((pixel & 0x00ffffffu) != 0) {
                                                    rgbNonzero++;
                                                    rowRGB++;
                                                }
                                                if (!haveFirstSample) {
                                                    firstSample = pixel;
                                                    haveFirstSample = YES;
                                                } else if (pixel != firstSample) {
                                                    different++;
                                                }
                                            }
                                            if (y >= 64 && rowRGB >= 4)
                                                denseContentRows++;
                                        }
                                    }
                                    BOOL contentVisible =
                                        macws_vnc_content_ready(
                                            sampled, different,
                                            denseContentRows);
                                    void *vb = contentVisible
                                        ? macws_vnc_mmap_begin_frame(w, h) : NULL;
                                    BOOL published = NO;
                                    if (vb && pf == 80) {
                                        for (size_t y = 0; y < h; y++)
                                            memcpy((char *)vb + y*vbpr,
                                                   (char *)surfaceBase + y*srcbpr, vbpr);
                                        macws_vnc_mmap_commit_frame();
                                        published = YES;
                                    } else if (vb && pf == 115) { // RGBA16F -> BGRA8
                                        for (size_t y = 0; y < h; y++) {
                                            uint16_t *src = (uint16_t *)((char *)surfaceBase + y*srcbpr);
                                            uint8_t  *d8  = (uint8_t  *)((char *)vb + y*vbpr);
                                            for (size_t x = 0; x < w; x++) {
                                                d8[x*4+0] = macws_half_to_u8(src[x*4+2]);
                                                d8[x*4+1] = macws_half_to_u8(src[x*4+1]);
                                                d8[x*4+2] = macws_half_to_u8(src[x*4+0]);
                                                d8[x*4+3] = 0xff;
                                            }
                                        }
                                        macws_vnc_mmap_commit_frame();
                                        published = YES;
                                    }
                                    static _Atomic uint64_t publishLog = 0;
                                    static _Atomic uint64_t rejectLog = 0;
                                    uint64_t sequence = 0;
                                    if (macws_runtime_diagnostics_enabled()) {
                                        sequence = published
                                            ? atomic_fetch_add(&publishLog, 1) + 1
                                            : atomic_fetch_add(&rejectLog, 1) + 1;
                                    }
                                    if (sequence &&
                                        (sequence <= 16 || (sequence % 600) == 0)) {
                                        fprintf(stderr,
                                            "#### VNC-BLIT %s #%llu %zux%zu "
                                            "pf=%lu rgb=%zu/%zu different=%zu "
                                            "denseRows=%zu\n",
                                            published ? "published" : "reject-output",
                                            (unsigned long long)sequence, w, h, pf,
                                            rgbNonzero, sampled, different,
                                            denseContentRows);
                                    }
                                    if (published) {
                                        uint64_t generation =
                                            macws_vnc_capture_generation();
                                        if (generation != 0) {
                                            if (macws_vnc_capture_generation() ==
                                                generation) {
                                                (void)unlink(
                                                    "/tmp/macws_capture_final");
                                            }
                                            macws_vnc_ack_capture(generation);
                                        }
                                    }
                                    IOSurfaceUnlock(boundSurface, kIOSurfaceLockReadOnly, NULL);
                                }
                            }
                        }
                    }
                    }
                    macws_vnc_release(t);
                }
                usleep(50000);   // poll for a newly completed/coalesced frame
            }
        }];
    });
    @synchronized(g_vnc_lock) {
        id old = g_vnc_comp_tex;
        g_vnc_comp_tex = macws_vnc_retain(dest);
        macws_vnc_release(old);
    }
}

// Final-scanout capture. Runtime-confirmed in WindowServer: the textures
// wrapped by CAWindowServerDisplay::currentSurface are 2388x1668, private
// pixel format 550, backed by the 15.2 MiB compressed display IOSurfaces.
// Their IOSurface rows are compressed (bpr=2432), so CPU copying is invalid.
// Instead, a texture read lets AGX apply the texture descriptor's compression
// metadata in hardware and writes ordinary BGRA8 into a Shared texture. Mesa's
// Asahi libagx uses the same architectural primitive in libagx_decompress:
// image-load the compressed descriptor, image-store an uncompressed
// descriptor, then update metadata.
//
// Do not compile source here.  In this chroot `newLibraryWithSource:` returns a
// macOS-format library that the iOS AGX device rejects.  QuartzCore's shipped
// default.metallib is already loadable by this device and contains an exact
// surface-copy pair.  llvm-dis of the actual macOS 13.4 blobs confirms:
//
//   read_surf_vert(ushort [[vertex_id]])
//     vertex IDs 0..3 -> (-1,-1), (1,-1), (-1,1), (1,1)
//   read_surf_frag(float4 [[position]], texture2d<half> [[texture(0)]])
//     read_texture_2d(uint2(position.xy)) -> color(0)
//
// Consequently this is a four-vertex triangle strip, with no vertex buffers,
// samplers, or uniforms.  The fragment coordinates are pixel coordinates, so
// render at the source's full physical size. The VNC server now advertises the
// same Retina dimensions (2388x1668 on this iPad); rendering directly to the
// logical 1194x834 size would only crop the source's upper-left quarter.
static id g_vnc_final_lock = nil;
static id<MTLTexture> g_vnc_final_tex = nil;
static IOSurfaceRef g_vnc_final_surface = NULL;
static _Atomic uint64_t g_vnc_final_serial = 0;

// Experimental producer-ordered PF550 bridge.  The old screenshot path read
// WindowServer's compressed, hazard-untracked scanout from a second command
// queue after the compositor submission completed.  Runtime A/B on 2026-07-27
// observed 4,200/4,200 clean PF550 submissions before that cross-queue read,
// then 176 failed WindowServer submissions immediately after one otherwise
// successful readback.  The first same-command-buffer attempt also failed:
// this texture is hazard-untracked and no producer fence was available after
// EndCurrentComposite.  The current experiment submits a separate read buffer
// immediately after the producer on that producer's own queue, where Metal's
// queue-ordering contract supplies the missing dependency before SkyLight can
// recycle the scanout. Gated by /tmp/macws_inband_pf550 until device-proven.
static id g_vnc_inband_lock = nil;
static id<MTLRenderPipelineState> g_vnc_inband_pipeline = nil;
static id<MTLTexture> g_vnc_inband_destination = nil;
static _Atomic int g_vnc_inband_busy = 0;
static _Atomic int g_vnc_inband_faulted = 0;
static _Atomic uint64_t g_vnc_inband_encoded_count = 0;
static _Atomic uint64_t g_vnc_inband_skipped_count = 0;
static _Atomic uint64_t g_vnc_inband_published_count = 0;

static uint64_t macws_vnc_capture_generation(void) {
    char value[64] = {0};
    int fd = open("/tmp/macws_capture_final", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return 0;
    char *end = NULL;
    unsigned long long generation = strtoull(value, &end, 10);
    return end != value && generation != 0 ? (uint64_t)generation : 0;
}

static void macws_vnc_ack_capture(uint64_t generation) {
    char value[96];
    int length = snprintf(value, sizeof(value), "%d %llu\n", getpid(),
                          (unsigned long long)generation);
    int fd = open("/tmp/macws_capture_done",
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t written = write(fd, value, (size_t)length);
    close(fd);
    if (written == length && macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### VNC-FINAL acknowledged pid=%d generation=%llu\n",
            getpid(), (unsigned long long)generation);
    }
}

static id<MTLRenderPipelineState> macws_vnc_get_inband_pipeline(
        id<MTLDevice> device) {
    if (!device) return nil;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ g_vnc_inband_lock = [NSObject new]; });
    @synchronized(g_vnc_inband_lock) {
        if (g_vnc_inband_pipeline) return g_vnc_inband_pipeline;

        NSURL *url = [NSURL fileURLWithPath:
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:url error:&error];
        id<MTLFunction> vertex = library
            ? [library newFunctionWithName:@"read_surf_vert"] : nil;
        id<MTLFunction> fragment = library
            ? [library newFunctionWithName:@"read_surf_frag"] : nil;
        MTLRenderPipelineReflection *reflection = nil;
        id<MTLRenderPipelineState> built = nil;
        BOOL contractOK = NO;
        if (vertex && fragment) {
            MTLRenderPipelineDescriptor *descriptor =
                [[MTLRenderPipelineDescriptor alloc] init];
            descriptor.label = @"MACWS in-band PF550 conversion";
            descriptor.vertexFunction = vertex;
            descriptor.fragmentFunction = fragment;
            descriptor.colorAttachments[0].pixelFormat =
                MTLPixelFormatBGRA8Unorm;
            built = [device newRenderPipelineStateWithDescriptor:descriptor
                options:MTLPipelineOptionArgumentInfo
                reflection:&reflection error:&error];
            macws_vnc_release(descriptor);
        }
        if (built && reflection) {
            BOOL sawTexture0 = NO;
            BOOL unexpected = NO;
            for (MTLArgument *argument in [reflection vertexArguments]) {
                if ([argument isActive]) unexpected = YES;
            }
            for (MTLArgument *argument in [reflection fragmentArguments]) {
                if (![argument isActive]) continue;
                if ([argument type] == MTLArgumentTypeTexture &&
                    [argument index] == 0 && !sawTexture0) {
                    sawTexture0 = YES;
                } else {
                    unexpected = YES;
                }
            }
            contractOK = sawTexture0 && !unexpected;
        }
        if (built && contractOK) {
            g_vnc_inband_pipeline = built;
        } else {
            macws_vnc_release(built);
        }
        fprintf(stderr,
            "#### VNC-INBAND pipeline library=%p vertex=%p fragment=%p "
            "pipeline=%p reflection=%p contract=%s error=%s\n",
            (void *)library, (void *)vertex, (void *)fragment,
            (void *)g_vnc_inband_pipeline, (void *)reflection,
            contractOK ? "OK" : "REJECT",
            error ? [[error description] UTF8String] : "nil");
        macws_vnc_release(fragment);
        macws_vnc_release(vertex);
        macws_vnc_release(library);
        return g_vnc_inband_pipeline;
    }
}

static void macws_vnc_clear_inband_busy(void) {
    atomic_store(&g_vnc_inband_busy, 0);
}

// Submit the read immediately after SkyLight's producer on the producer's own
// MTLCommandQueue. Metal command queues execute their command buffers in
// submission order, which supplies the resource ordering missing from both the
// cross-queue screenshot and the failed same-buffer/untracked-hazard attempt.
// Returns an owned read command buffer and an owned destination snapshot.
static id<MTLCommandBuffer> macws_vnc_submit_pf550_ordered(
        id<MTLTexture> source, id<MTLCommandBuffer> producer,
        id<MTLTexture> *destinationOut) {
    if (destinationOut) *destinationOut = nil;
    if (access("/tmp/macws_inband_pf550", F_OK) != 0 || !source || !producer ||
        atomic_load(&g_vnc_inband_faulted) ||
        [source pixelFormat] != (MTLPixelFormat)550 ||
        [source width] < 1000 || [source height] < 600 ||
        (([source usage] & MTLTextureUsageShaderRead) == 0)) {
        return nil;
    }
    if (atomic_exchange(&g_vnc_inband_busy, 1)) {
        uint64_t skipped = atomic_fetch_add(&g_vnc_inband_skipped_count, 1) + 1;
        if (skipped <= 16 || (skipped % 600) == 0) {
            fprintf(stderr,
                "#### VNC-INBAND skip busy #%llu encoded=%llu published=%llu\n",
                (unsigned long long)skipped,
                (unsigned long long)atomic_load(&g_vnc_inband_encoded_count),
                (unsigned long long)atomic_load(&g_vnc_inband_published_count));
        }
        return nil;
    }

    id<MTLCommandQueue> commandQueue = [producer commandQueue];
    id<MTLDevice> device = [source device];
    id<MTLRenderPipelineState> pipeline =
        macws_vnc_get_inband_pipeline(device);
    size_t width = [source width], height = [source height];
    if (!commandQueue || !pipeline) {
        fprintf(stderr,
            "#### VNC-INBAND reject source=%p producer=%p queue=%p "
            "pipeline=%p reason=precondition\n",
            (void *)source, (void *)producer, (void *)commandQueue,
            (void *)pipeline);
        macws_vnc_clear_inband_busy();
        return nil;
    }

    @synchronized(g_vnc_inband_lock) {
        if (!g_vnc_inband_destination ||
            [g_vnc_inband_destination width] != width ||
            [g_vnc_inband_destination height] != height) {
            macws_vnc_share_ensure(width, height);
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:width height:height mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageRenderTarget |
                MTLTextureUsageShaderRead;
            id<MTLTexture> replacement = g_vncSurf
                ? [device newTextureWithDescriptor:descriptor
                    iosurface:g_vncSurf plane:0]
                : nil;
            macws_vnc_release(g_vnc_inband_destination);
            g_vnc_inband_destination = replacement;
            fprintf(stderr,
                "#### VNC-INBAND destination=%p surface=%p %zux%zu\n",
                (void *)g_vnc_inband_destination, (void *)g_vncSurf,
                width, height);
        }
    }
    if (!g_vnc_inband_destination) {
        macws_vnc_clear_inband_busy();
        return nil;
    }

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    MTLRenderPassDescriptor *renderPass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = g_vnc_inband_destination;
    renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    if (!encoder) {
        fprintf(stderr,
            "#### VNC-INBAND reject source=%p producer=%p read=%p "
            "reason=encoder\n", (void *)source, (void *)producer,
            (void *)commandBuffer);
        macws_vnc_clear_inband_busy();
        return nil;
    }
    encoder.label = @"MACWS in-band PF550 conversion";
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer commit];
    if (destinationOut)
        *destinationOut = macws_vnc_retain(g_vnc_inband_destination);
    uint64_t encoded = atomic_fetch_add(&g_vnc_inband_encoded_count, 1) + 1;
    if (encoded <= 16 || (encoded % 600) == 0) {
        fprintf(stderr,
            "#### VNC-INBAND ordered #%llu source=%p producer=%p read=%p "
            "queue=%p %zux%zu skipped=%llu\n",
            (unsigned long long)encoded, (void *)source, (void *)producer,
            (void *)commandBuffer, (void *)commandQueue, width, height,
            (unsigned long long)atomic_load(&g_vnc_inband_skipped_count));
    }
    return macws_vnc_retain(commandBuffer);
}

static BOOL macws_vnc_publish_inband_destination(id<MTLTexture> destination) {
    if (!destination || [destination pixelFormat] != MTLPixelFormatBGRA8Unorm)
        return NO;
    size_t width = [destination width], height = [destination height];
    void *implementation =
        *(void **)((char *)(__bridge void *)destination + 0x208);
    IOSurfaceRef surface = (uintptr_t)implementation > 0x1000
        ? *(IOSurfaceRef *)((char *)implementation + 0xa0) : NULL;
    void *cpuMapping = (uintptr_t)implementation > 0x1000
        ? *(void **)((char *)implementation + 0x130) : NULL;
    if (!surface || !cpuMapping ||
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != 0) {
        return NO;
    }
    void *base = IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    BOOL readable = base && bytesPerRow >= width * 4 &&
        surfaceHeight >= height;
    size_t sampled = 0, rgbNonzero = 0, different = 0;
    size_t denseContentRows = 0;
    uint32_t first = 0;
    BOOL haveFirst = NO;
    if (readable) {
        for (size_t y = 0; y < height; y += 16) {
            const uint32_t *row = (const uint32_t *)
                ((const char *)base + y * bytesPerRow);
            size_t rowRGB = 0;
            for (size_t x = 0; x < width; x += 16) {
                uint32_t pixel = row[x];
                sampled++;
                if ((pixel & 0x00ffffffu) != 0) {
                    rgbNonzero++;
                    rowRGB++;
                }
                if (!haveFirst) { first = pixel; haveFirst = YES; }
                else if (pixel != first) different++;
            }
            if (y >= 64 && rowRGB >= 4) denseContentRows++;
        }
        // The AGX recovery image is a spatially constant error colour. A
        // completed command buffer is therefore necessary but not sufficient:
        // never let that diagnostic colour overwrite the last real desktop.
        // A valid blank macOS desktop still has a non-uniform menu bar/cursor.
        if (different >= 4) {
            void *shared = macws_vnc_mmap_begin_frame(width, height);
            if (shared) {
                for (size_t y = 0; y < height; y++) {
                    memcpy((char *)shared + y * width * 4,
                           (const char *)base + y * bytesPerRow, width * 4);
                }
                macws_vnc_mmap_commit_frame();
            } else {
                readable = NO;
            }
        } else {
            readable = NO;
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    if (!readable) {
        static _Atomic uint64_t rejected = 0;
        uint64_t sequence = atomic_fetch_add(&rejected, 1) + 1;
        if (sequence <= 16 || (sequence % 600) == 0) {
            fprintf(stderr,
                "#### VNC-INBAND reject-output #%llu dst=%p rgb=%zu/%zu "
                "different=%zu denseRows=%zu\n",
                (unsigned long long)sequence, (void *)destination,
                rgbNonzero, sampled, different, denseContentRows);
        }
        return NO;
    }

    uint64_t published =
        atomic_fetch_add(&g_vnc_inband_published_count, 1) + 1;
    if (published <= 32 || (published % 600) == 0) {
        fprintf(stderr,
            "#### VNC-INBAND published #%llu dst=%p %zux%zu "
            "rgb=%zu/%zu different=%zu denseRows=%zu "
            "encoded=%llu skipped=%llu\n",
            (unsigned long long)published, (void *)destination,
            width, height, rgbNonzero, sampled, different,
            denseContentRows,
            (unsigned long long)atomic_load(&g_vnc_inband_encoded_count),
            (unsigned long long)atomic_load(&g_vnc_inband_skipped_count));
    }

    uint64_t generation = macws_vnc_capture_generation();
    BOOL contentVisible = macws_vnc_content_ready(
        sampled, different, denseContentRows);
    if (generation && contentVisible) {
        if (macws_vnc_capture_generation() == generation)
            (void)unlink("/tmp/macws_capture_final");
        macws_vnc_ack_capture(generation);
    }
    return YES;
}

static BOOL macws_vnc_submit_read_pass(id<MTLCommandQueue> queue,
        id<MTLRenderPipelineState> pipeline, id<MTLTexture> src,
        id<MTLTexture> dst, NSString *label, BOOL draw) {
    MTLCommandBufferDescriptor *cbDescriptor =
        [[MTLCommandBufferDescriptor alloc] init];
    cbDescriptor.retainedReferences = YES;
    cbDescriptor.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
    id<MTLCommandBuffer> commandBuffer =
        [queue commandBufferWithDescriptor:cbDescriptor];
    macws_vnc_release(cbDescriptor);
    commandBuffer.label = label;

    MTLRenderPassDescriptor *renderPass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = dst;
    renderPass.colorAttachments[0].loadAction = draw
        ? MTLLoadActionDontCare : MTLLoadActionClear;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0.125, 0.25, 0.5, 1.0);
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    encoder.label = label;
    if (draw) {
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:src atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    NSError *error = [commandBuffer error];
    if (!error) return YES;

    fprintf(stderr, "#### VNC-FINAL pass %s error: %s\n",
        [label UTF8String], [[error description] UTF8String]);
    NSArray *encoderInfos = [[error userInfo]
        objectForKey:MTLCommandBufferEncoderInfoErrorKey];
    BOOL allCompleted = [encoderInfos count] > 0;
    for (id<MTLCommandBufferEncoderInfo> info in encoderInfos) {
        fprintf(stderr,
            "#### VNC-FINAL encoder label=%s state=%ld signposts=%s\n",
            [[info label] UTF8String], (long)[info errorState],
            [[[info debugSignposts] description] UTF8String]);
        if ([info errorState] != MTLCommandEncoderErrorStateCompleted)
            allCompleted = NO;
    }
    // A command-buffer-level bookkeeping error is not proof that GPU work
    // failed.  Return the explicitly requested per-encoder execution result;
    // callers still validate the destination bytes before using any output.
    return allCompleted;
}

// Diagnostic only: determine whether Terminal's completed 300x210 pf550
// intermediate contains pixels before the full-display compositor consumes
// it.  The source is retained and sampled once, ten seconds after creation,
// through QuartzCore's already runtime-validated read_surf shader.  This does
// not publish a VNC frame and does not alter the producer command stream.
//
// The probe deliberately lives behind an explicit sentinel because it creates
// a second Metal queue and reads a resource owned by SkyLight.  That queue
// topology is not a production fix; the result only distinguishes an empty
// upstream render target from a later compositor/drop problem.
static void macws_schedule_small_pf550_probe(id<MTLTexture> source) {
    if (!source || access("/tmp/macws_probe_small_pf550", F_OK) != 0)
        return;
    if ([source pixelFormat] != 550 || [source width] != 300 ||
        [source height] != 210)
        return;
    static _Atomic int scheduled = 0;
    if (atomic_exchange(&scheduled, 1)) return;

    id<MTLTexture> retainedSource = macws_vnc_retain(source);
    fprintf(stderr,
        "#### PF550-SMALL-PROBE scheduled source=%p 300x210 usage=%#lx "
        "storage=%lu delay=10s\n",
        (void *)source, (unsigned long)[source usage],
        (unsigned long)[source storageMode]);
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            sleep(10);
            id<MTLDevice> device = (id<MTLDevice>)
                macws_vnc_retain([retainedSource device]);
            id<MTLCommandQueue> queue = device ? [device newCommandQueue] : nil;
            NSURL *url = [NSURL fileURLWithPath:
                @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
            NSError *pipelineError = nil;
            id<MTLLibrary> library = device
                ? [device newLibraryWithURL:url error:&pipelineError] : nil;
            id<MTLFunction> vertex = library
                ? [library newFunctionWithName:@"read_surf_vert"] : nil;
            id<MTLFunction> fragment = library
                ? [library newFunctionWithName:@"read_surf_frag"] : nil;
            id<MTLRenderPipelineState> pipeline = nil;
            if (vertex && fragment) {
                MTLRenderPipelineDescriptor *descriptor =
                    [[MTLRenderPipelineDescriptor alloc] init];
                descriptor.label = @"MACWS small pf550 diagnostic";
                descriptor.vertexFunction = vertex;
                descriptor.fragmentFunction = fragment;
                descriptor.colorAttachments[0].pixelFormat =
                    MTLPixelFormatBGRA8Unorm;
                pipeline = [device
                    newRenderPipelineStateWithDescriptor:descriptor
                    error:&pipelineError];
                macws_vnc_release(descriptor);
            }

            NSDictionary *properties = @{
                @"IOSurfaceWidth": @300,
                @"IOSurfaceHeight": @210,
                @"IOSurfaceBytesPerElement": @4,
                @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
                @"IOSurfaceName": @"MacWS pf550 diagnostic destination",
            };
            IOSurfaceRef destinationSurface = IOSurfaceCreate(
                (__bridge CFDictionaryRef)properties);
            MTLTextureDescriptor *destinationDescriptor =
                [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:
                        MTLPixelFormatBGRA8Unorm
                    width:300 height:210 mipmapped:NO];
            destinationDescriptor.storageMode = MTLStorageModeShared;
            destinationDescriptor.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> destination = destinationSurface && device
                ? [device newTextureWithDescriptor:destinationDescriptor
                    iosurface:destinationSurface plane:0]
                : nil;
            BOOL executed = queue && pipeline && destination &&
                macws_vnc_submit_read_pass(queue, pipeline, retainedSource,
                    destination, @"MACWS small pf550 diagnostic read", YES);

            size_t sampled = 0, rgbNonzero = 0, different = 0;
            uint32_t first = 0;
            BOOL haveFirst = NO;
            BOOL readable = NO;
            size_t bytesPerRow = 0;
            if (executed && destinationSurface &&
                IOSurfaceLock(destinationSurface,
                    kIOSurfaceLockReadOnly, NULL) == 0) {
                uint8_t *base = IOSurfaceGetBaseAddress(destinationSurface);
                bytesPerRow = IOSurfaceGetBytesPerRow(destinationSurface);
                readable = base && bytesPerRow >= 300 * 4;
                if (readable) {
                    for (size_t y = 0; y < 210; y += 2) {
                        const uint32_t *row = (const uint32_t *)
                            (base + y * bytesPerRow);
                        for (size_t x = 0; x < 300; x += 2) {
                            uint32_t pixel = row[x];
                            sampled++;
                            if ((pixel & 0x00ffffffu) != 0) rgbNonzero++;
                            if (!haveFirst) {
                                first = pixel;
                                haveFirst = YES;
                            } else if (pixel != first) {
                                different++;
                            }
                        }
                    }
                    int output = open("/tmp/macws_pf550_small_probe.bgra",
                        O_WRONLY | O_CREAT | O_TRUNC, 0644);
                    if (output >= 0) {
                        for (size_t y = 0; y < 210; y++) {
                            const uint8_t *row = base + y * bytesPerRow;
                            size_t remaining = 300 * 4;
                            while (remaining) {
                                ssize_t wrote = write(output, row, remaining);
                                if (wrote <= 0) break;
                                row += wrote;
                                remaining -= (size_t)wrote;
                            }
                        }
                        close(output);
                    }
                }
                IOSurfaceUnlock(destinationSurface,
                    kIOSurfaceLockReadOnly, NULL);
            }
            fprintf(stderr,
                "#### PF550-SMALL-PROBE result source=%p executed=%s "
                "readable=%s bpr=%zu rgb=%zu/%zu different=%zu "
                "first=%#x pipelineError=%s\n",
                (void *)retainedSource, executed ? "YES" : "NO",
                readable ? "YES" : "NO", bytesPerRow, rgbNonzero, sampled,
                different, first,
                pipelineError ? [[pipelineError description] UTF8String]
                              : "nil");

            macws_vnc_release(destination);
            if (destinationSurface) CFRelease(destinationSurface);
            macws_vnc_release(pipeline);
            macws_vnc_release(fragment);
            macws_vnc_release(vertex);
            macws_vnc_release(library);
            macws_vnc_release(queue);
            macws_vnc_release(device);
            macws_vnc_release(retainedSource);
        }
    }];
}

static void macws_vnc_capture_final(id<MTLTexture> src) {
    // Each request carries a unique generation.  It remains armed until one
    // validated frame is published, with the bounded retry budget below
    // preventing a failed private-PF550 read from becoming an unbounded loop.
    uint64_t generation = macws_vnc_capture_generation();
    if (generation == 0) return;
    if (!src) return;
    size_t srcw = [src width], srch = [src height];
    unsigned long srcpf = (unsigned long)[src pixelFormat];
    unsigned long usage = (unsigned long)[src usage];
    if (srcw < 1000 || srch < 600 || srcpf != 550) return;

    static int usageLog = 0;
    if (usageLog < 3) {
        fprintf(stderr,
            "#### VNC-FINAL source tex=%p %zux%zu pf=%lu usage=%#lx "
            "storage=%lu hazard=%lu\n",
            (void *)src, srcw, srch, srcpf, usage,
            (unsigned long)[src storageMode],
            (unsigned long)[src hazardTrackingMode]);
        usageLog++;
    }
    if ((usage & MTLTextureUsageShaderRead) == 0) {
        static int noReadLog = 0;
        if (noReadLog++ < 3) {
            fprintf(stderr,
                "#### VNC-FINAL source lacks MTLTextureUsageShaderRead; "
                "capture dispatch not submitted\n");
        }
        return;
    }

    // A request is complete only when a validated frame is published and ACKed.
    // The old one-attempt state unlinked the request before GPU work; one
    // transient InnocentVictim completion then left VNC black forever. Keep a
    // strict per-generation retry budget. The tracking thread runs at 5 Hz and
    // may retry the same completed scanout while this generation stays armed;
    // four attempts are therefore bounded in both rate and resource use.
    static uint64_t activeGeneration = 0;
    static unsigned activeAttempts = 0;
    static uint64_t exhaustedGeneration = 0;
    if (activeGeneration != generation) {
        activeGeneration = generation;
        activeAttempts = 0;
    }
    if (activeAttempts >= 4) {
        if (exhaustedGeneration != generation) {
            exhaustedGeneration = generation;
            fprintf(stderr,
                "#### VNC-FINAL generation=%llu exhausted 4 attempts "
                "without a validated frame\n",
                (unsigned long long)generation);
        }
        return;
    }
    unsigned captureAttempt = ++activeAttempts;
    fprintf(stderr, "#### VNC-FINAL consuming generation=%llu attempt=%u/4\n",
            (unsigned long long)generation, captureAttempt);

    static id<MTLDevice> dev = nil;
    static id<MTLCommandQueue> queue = nil;
    static id<MTLRenderPipelineState> pipeline = nil;
    static id<MTLTexture> dst = nil;
    static size_t dstw = 0, dsth = 0;
    static int pipelineAttempted = 0;

    if (!dev) {
        dev = (id<MTLDevice>)macws_vnc_retain([src device]);
        queue = [dev newCommandQueue];
    }
    if (dev && !pipeline && !pipelineAttempted) {
        pipelineAttempted = 1;
        NSURL *url = [NSURL fileURLWithPath:
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *error = nil;
        id<MTLLibrary> library = [dev newLibraryWithURL:url error:&error];
        id<MTLFunction> vertex =
            library ? [library newFunctionWithName:@"read_surf_vert"] : nil;
        id<MTLFunction> fragment =
            library ? [library newFunctionWithName:@"read_surf_frag"] : nil;
        MTLRenderPipelineReflection *reflection = nil;
        id<MTLRenderPipelineState> built = nil;
        BOOL contractOK = NO;
        if (vertex && fragment) {
            MTLRenderPipelineDescriptor *descriptor =
                [[MTLRenderPipelineDescriptor alloc] init];
            descriptor.label = @"MACWS final scanout read";
            descriptor.vertexFunction = vertex;
            descriptor.fragmentFunction = fragment;
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            built = [dev newRenderPipelineStateWithDescriptor:descriptor
                options:MTLPipelineOptionArgumentInfo
                reflection:&reflection error:&error];
            macws_vnc_release(descriptor);
        }

        // Runtime reflection is a second check on the AIR metadata above.  Do
        // not draw unless the only active shader resource is texture slot 0.
        if (built && reflection) {
            BOOL sawTexture0 = NO;
            BOOL unexpected = NO;
            NSArray *vertexArguments = [reflection vertexArguments];
            NSArray *fragmentArguments = [reflection fragmentArguments];
            for (MTLArgument *arg in vertexArguments) {
                if (![arg isActive]) continue;
                unexpected = YES;
                fprintf(stderr,
                    "#### VNC-FINAL reflect vertex name=%s type=%lu index=%lu access=%lu\n",
                    [[arg name] UTF8String], (unsigned long)[arg type],
                    (unsigned long)[arg index], (unsigned long)[arg access]);
            }
            for (MTLArgument *arg in fragmentArguments) {
                if (![arg isActive]) continue;
                fprintf(stderr,
                    "#### VNC-FINAL reflect fragment name=%s type=%lu index=%lu access=%lu\n",
                    [[arg name] UTF8String], (unsigned long)[arg type],
                    (unsigned long)[arg index], (unsigned long)[arg access]);
                if ([arg type] == MTLArgumentTypeTexture && [arg index] == 0 &&
                    !sawTexture0) {
                    sawTexture0 = YES;
                } else {
                    unexpected = YES;
                }
            }
            contractOK = sawTexture0 && !unexpected;
        }
        if (built && contractOK) {
            pipeline = built;
        } else {
            macws_vnc_release(built);
        }
        fprintf(stderr,
            "#### VNC-FINAL pipeline library=%p vertex=%p fragment=%p "
            "pipeline=%p reflection=%p contract=%s error=%s\n",
            (void *)library, (void *)vertex, (void *)fragment, (void *)pipeline,
            (void *)reflection, contractOK ? "OK" : "REJECT",
            error ? [[error description] UTF8String] : "nil");
    }
    if (!dev || !queue || !pipeline) return;

    size_t outw = srcw;
    size_t outh = srch;
    if (!dst || dstw != outw || dsth != outh) {
        macws_vnc_share_ensure(outw, outh);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:outw height:outh mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> newDst = g_vncSurf
            ? [dev newTextureWithDescriptor:descriptor iosurface:g_vncSurf plane:0]
            : nil;
        macws_vnc_release(dst);
        dst = newDst;
        dstw = outw;
        dsth = outh;
        fprintf(stderr,
            "#### VNC-FINAL dst=%p surface=%p %zux%zu pf=%lu storage=%lu\n",
            (void *)dst, (void *)g_vncSurf, outw, outh,
            (unsigned long)[dst pixelFormat],
            (unsigned long)[dst storageMode]);
    }
    if (!dst) return;

    // TEMPORARY DIAGNOSTIC, not a rendering fix: prove independently whether
    // this queue/destination and this precompiled shader can execute before
    // attributing an error to private pf550.  The known-color control is never
    // copied into the VNC mmap and therefore cannot masquerade as a screenshot.
    static int controlAttempts = 0;
    static BOOL controlOK = NO;
    static IOSurfaceRef controlSurface = NULL;
    static id<MTLTexture> controlTexture = nil;
    if (!controlOK && controlAttempts < 4) {
        controlAttempts++;
        BOOL clearExecuted = macws_vnc_submit_read_pass(queue, pipeline, nil, dst,
            @"MACWS VNC clear-only control", NO);
        BOOL clearPixelsOK = NO;
        uint8_t clearPixel[4] = {0, 0, 0, 0};
        if (clearExecuted &&
            IOSurfaceLock(g_vncSurf, kIOSurfaceLockReadOnly, NULL) == 0) {
            uint8_t *base = IOSurfaceGetBaseAddress(g_vncSurf);
            size_t bpr = IOSurfaceGetBytesPerRow(g_vncSurf);
            uint8_t *pixel = base ? base + (outh / 2) * bpr + (outw / 2) * 4 : NULL;
            if (pixel) memcpy(clearPixel, pixel, sizeof(clearPixel));
            // MTLClearColorMake(.125, .25, .5, 1) stored in BGRA8.
            clearPixelsOK = pixel && pixel[0] >= 0x7f && pixel[0] <= 0x80 &&
                pixel[1] >= 0x3f && pixel[1] <= 0x40 &&
                pixel[2] >= 0x1f && pixel[2] <= 0x20 && pixel[3] == 0xff;
            IOSurfaceUnlock(g_vncSurf, kIOSurfaceLockReadOnly, NULL);
        }
        fprintf(stderr,
            "#### VNC-FINAL clear-control executed=%s pixel=%s "
            "center=%02x%02x%02x%02x\n",
            clearExecuted ? "YES" : "NO", clearPixelsOK ? "OK" : "FAIL",
            clearPixel[0], clearPixel[1], clearPixel[2], clearPixel[3]);

        // TEMPORARY DIAGNOSTIC CIRCUIT BREAKER, not a rendering fix.  A
        // failed WindowServer frame currently keeps allocating replacement
        // IOSurface resources (runtime capture reached tens of GB of virtual
        // resource accounting).  When the one-shot test harness creates this
        // sentinel, stop at the exact post-completion point so LLDB can inspect
        // the process and the harness can copy evidence before cleanup.  This
        // does not change the command result or pretend that pixels rendered.
        if (access("/tmp/macws_stop_after_clear", F_OK) == 0) {
            fprintf(stderr,
                "#### VNC-FINAL DIAGNOSTIC-STOP after clear-control result\n");
            raise(SIGSTOP);
        }
        NSDictionary *properties = @{
            @"IOSurfaceWidth": @(outw),
            @"IOSurfaceHeight": @(outh),
            @"IOSurfaceBytesPerElement": @4,
            @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
        };
        macws_vnc_release(controlTexture);
        controlTexture = nil;
        if (controlSurface) {
            CFRelease(controlSurface);
            controlSurface = NULL;
        }
        controlSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (controlSurface &&
            IOSurfaceLock(controlSurface, 0, NULL) == 0) {
            uint8_t *controlBase = IOSurfaceGetBaseAddress(controlSurface);
            size_t controlBpr = IOSurfaceGetBytesPerRow(controlSurface);
            for (size_t y = 0; controlBase && y < outh; y++) {
                uint8_t *row = controlBase + y * controlBpr;
                for (size_t x = 0; x < outw; x++) {
                    row[x * 4 + 0] = 0x21;
                    row[x * 4 + 1] = 0x43;
                    row[x * 4 + 2] = 0x65;
                    row[x * 4 + 3] = 0xff;
                }
            }
            IOSurfaceUnlock(controlSurface, 0, NULL);
        }
        MTLTextureDescriptor *controlDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:outw height:outh mipmapped:NO];
        controlDescriptor.storageMode = MTLStorageModeShared;
        controlDescriptor.usage = MTLTextureUsageShaderRead;
        controlTexture = controlSurface
            ? [dev newTextureWithDescriptor:controlDescriptor
                iosurface:controlSurface plane:0]
            : nil;
        BOOL drawExecuted = clearPixelsOK && controlTexture &&
            macws_vnc_submit_read_pass(queue, pipeline, controlTexture, dst,
                @"MACWS VNC BGRA8 shader control", YES);
        BOOL pixelsOK = NO;
        if (drawExecuted &&
            IOSurfaceLock(g_vncSurf, kIOSurfaceLockReadOnly, NULL) == 0) {
            uint8_t *base = IOSurfaceGetBaseAddress(g_vncSurf);
            size_t bpr = IOSurfaceGetBytesPerRow(g_vncSurf);
            uint8_t *pixel = base ? base + (outh / 2) * bpr + (outw / 2) * 4 : NULL;
            pixelsOK = pixel && pixel[0] == 0x21 && pixel[1] == 0x43 &&
                pixel[2] == 0x65 && pixel[3] == 0xff;
            fprintf(stderr,
                "#### VNC-FINAL control clear=%s draw=%s pixel=%s "
                "center=%02x%02x%02x%02x\n",
                clearPixelsOK ? "OK" : "FAIL",
                drawExecuted ? "EXECUTED" : "FAIL",
                pixelsOK ? "OK" : "FAIL",
                pixel ? pixel[0] : 0, pixel ? pixel[1] : 0,
                pixel ? pixel[2] : 0, pixel ? pixel[3] : 0);
            IOSurfaceUnlock(g_vncSurf, kIOSurfaceLockReadOnly, NULL);
        } else {
            fprintf(stderr,
                "#### VNC-FINAL control clear=%s texture=%p draw=%s pixel=UNREAD\n",
                clearPixelsOK ? "OK" : "FAIL", (void *)controlTexture,
                drawExecuted ? "EXECUTED" : "FAIL");
        }
        controlOK = drawExecuted && pixelsOK;
    }
    if (!controlOK) return;

    if (!macws_vnc_submit_read_pass(queue, pipeline, src, dst,
            @"MACWS VNC pf550 scanout read", YES)) {
        static int commandErrorLog = 0;
        if (commandErrorLog++ == 0) {
            fprintf(stderr,
                "#### VNC-FINAL pf550 read rejected after BGRA8 control passed\n");
        }
        return;
    }

    void *impl = *(void **)((char *)(__bridge void *)dst + 0x208);
    IOSurfaceRef boundSurface = (uintptr_t)impl > 0x1000
        ? *(IOSurfaceRef *)((char *)impl + 0xa0) : NULL;
    void *cpuMapping = (uintptr_t)impl > 0x1000
        ? *(void **)((char *)impl + 0x130) : NULL;
    if (!boundSurface || boundSurface != g_vncSurf || !cpuMapping ||
        IOSurfaceLock(g_vncSurf, kIOSurfaceLockReadOnly, NULL) != 0) return;
    void *base = IOSurfaceGetBaseAddress(g_vncSurf);
    size_t bpr = IOSurfaceGetBytesPerRow(g_vncSurf);
    size_t bh = IOSurfaceGetHeight(g_vncSurf);
    BOOL copied = NO;
    size_t nonzero = 0;
    size_t rgbNonzero = 0;
    size_t different = 0;
    size_t sampled = 0;
    size_t denseContentRows = 0;
    uint32_t firstSample = 0;
    BOOL haveFirstSample = NO;
    if (base && bpr >= outw * 4 && bh >= outh) {
        // Validate the GPU result before publishing it. Runtime capture on
        // 2026-07-26 proved that a failed PF550 source can still complete this
        // diagnostic shader pass with every output pixel set to solid magenta.
        // Merely requiring nonzero bytes acknowledged that error color as a
        // desktop frame. A real desktop may be mostly dark, but display-sized
        // menu/window content must produce more than one sampled BGRA value.
        for (size_t y = 0; y < outh; y += 16) {
            const uint32_t *row = (const uint32_t *)((const char *)base + y * bpr);
            size_t rowRGB = 0;
            for (size_t x = 0; x < outw; x += 16) {
                uint32_t pixel = row[x];
                sampled++;
                if (pixel != 0) nonzero++;
                if ((pixel & 0x00ffffffu) != 0) {
                    rgbNonzero++;
                    rowRGB++;
                }
                if (!haveFirstSample) {
                    firstSample = pixel;
                    haveFirstSample = YES;
                } else if (pixel != firstSample) {
                    different++;
                }
            }
            if (y >= 64 && rowRGB >= 4) denseContentRows++;
        }
        // Use spatial content structure rather than total area. A complete
        // small Terminal is below the old 5% threshold, while a title-only or
        // outline-only frame does not span enough dense non-menu rows.
        BOOL contentVisible = macws_vnc_content_ready(
            sampled, different, denseContentRows);
        if (contentVisible) {
            void *shared = macws_vnc_mmap_begin_frame(outw, outh);
            if (shared) {
                for (size_t y = 0; y < outh; y++) {
                    memcpy((char *)shared + y * outw * 4,
                           (char *)base + y * bpr, outw * 4);
                }
                macws_vnc_mmap_commit_frame();
                copied = YES;
            }
        }
        static int capturedLog = 0;
        if (capturedLog++ < 8) {
            fprintf(stderr,
                "#### VNC-FINAL captured %zux%zu BGRA8 cpu130=%p base=%p "
                "bpr=%zu sampled_nonzero=%zu sampled_rgb_nonzero=%zu/%zu "
                "sampled_different=%zu denseRows=%zu "
                "publish=%s\n",
                outw, outh, cpuMapping, base, bpr, nonzero, rgbNonzero,
                sampled, different, denseContentRows,
                copied ? "YES" : "REJECT-NO-CONTENT");
        }
        // One-shot visual witness for tuning the readiness classifier.  A
        // 300x210 Terminal occupies only ~1.6% of the 2388x1668 display, so
        // the historical 5% RGB threshold may reject a real small window.
        // Dump the exact GPU-read destination before publication while the
        // explicit diagnostic sentinel is armed; never copy it into VNC or
        // acknowledge readiness from this path.
        if (!copied &&
            access("/tmp/macws_dump_rejected_vnc", F_OK) == 0) {
            static _Atomic int rejectedDumped = 0;
            if (!atomic_exchange(&rejectedDumped, 1)) {
                int output = open("/tmp/macws_vnc_rejected.bgra",
                    O_WRONLY | O_CREAT | O_TRUNC, 0644);
                size_t totalWritten = 0;
                if (output >= 0) {
                    for (size_t y = 0; y < outh; y++) {
                        const uint8_t *row = (const uint8_t *)base + y * bpr;
                        size_t remaining = outw * 4;
                        while (remaining) {
                            ssize_t wrote = write(output, row, remaining);
                            if (wrote <= 0) break;
                            row += wrote;
                            remaining -= (size_t)wrote;
                            totalWritten += (size_t)wrote;
                        }
                    }
                    close(output);
                }
                fprintf(stderr,
                    "#### VNC-FINAL rejected-dump path="
                    "/tmp/macws_vnc_rejected.bgra bytes=%zu geometry=%zux%zu "
                    "rgb=%zu/%zu different=%zu denseRows=%zu\n",
                    totalWritten, outw, outh, rgbNonzero, sampled,
                    different, denseContentRows);
            }
        }
    }
    IOSurfaceUnlock(g_vncSurf, kIOSurfaceLockReadOnly, NULL);
    if (copied && nonzero != 0) {
        // PF550 is a one-shot high-quality snapshot, not a terminal state for
        // the streaming bridge.  Runtime input testing on 2026-07-26 proved
        // that turning the PF80/115 publisher off here permanently froze VNC
        // on this frame even though the click reached Terminal and generated
        // later composites.  Drop any already-queued older PF80 frame so it
        // cannot immediately overwrite this snapshot, but keep accepting new
        // completed PF80/115 frames after the next UI update.
        if (g_vnc_lock) {
            @synchronized(g_vnc_lock) {
                id oldComposite = g_vnc_comp_tex;
                g_vnc_comp_tex = nil;
                macws_vnc_release(oldComposite);
            }
        }
        // Do not remove a newer request that may have arrived while this GPU
        // work was in flight.
        if (macws_vnc_capture_generation() == generation)
            (void)unlink("/tmp/macws_capture_final");
        macws_vnc_ack_capture(generation);
    }
}

static void macws_vnc_track_final(id<MTLTexture> tex, IOSurfaceRef surface) {
    if (!tex || !surface || !macws_vnc_share_enabled()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_vnc_final_lock = [NSObject new];
        [NSThread detachNewThreadWithBlock:^{
            uint64_t observedSerial = 0;
            for (;;) {
                @autoreleasepool {
                    id<MTLTexture> snapshot = nil;
                    IOSurfaceRef snapshotSurface = NULL;
                    uint64_t serial = atomic_load(&g_vnc_final_serial);
                    @synchronized(g_vnc_final_lock) {
                        snapshot = macws_vnc_retain(g_vnc_final_tex);
                        if (g_vnc_final_surface) {
                            snapshotSurface = (IOSurfaceRef)CFRetain(g_vnc_final_surface);
                        }
                    }
                    // A completed command can be discarded as an
                    // InnocentVictim during GPU recovery. Runtime evidence on
                    // 2026-07-26 showed attempt 1/4 failing that way, followed
                    // by no later attempt because the scanout serial stayed
                    // unchanged. Once at least one completed scanout exists,
                    // keep invoking the bounded per-generation retry state
                    // machine while a request remains armed. A successful ACK
                    // removes the request; an exhausted generation returns
                    // immediately without submitting more GPU work.
                    BOOL newSerial = serial != observedSerial;
                    BOOL captureArmed = macws_vnc_capture_generation() != 0;
                    if (snapshot && snapshotSurface &&
                        (newSerial || captureArmed)) {
                        if (newSerial) observedSerial = serial;
                        macws_vnc_capture_final(snapshot);
                    }
                    macws_vnc_release(snapshot);
                    if (snapshotSurface) CFRelease(snapshotSurface);
                }
                usleep(200000); // static screenshot path: 5 fps avoids WS pressure
            }
        }];
    });

    @synchronized(g_vnc_final_lock) {
        id oldTexture = g_vnc_final_tex;
        IOSurfaceRef oldSurface = g_vnc_final_surface;
        g_vnc_final_tex = macws_vnc_retain(tex);
        g_vnc_final_surface = (IOSurfaceRef)CFRetain(surface);
        macws_vnc_release(oldTexture);
        if (oldSurface) CFRelease(oldSurface);
    }
    atomic_fetch_add(&g_vnc_final_serial, 1);
}

// Pair a successful MetalContext::StartComposite* with the matching
// EndCurrentComposite(bool).  A creation-time pf550 candidate is not a
// completed frame: the iOS-native iosclear reference reads the same solid
// ff00ffff value from a newly-created pf550 surface.  Keep a per-context
// stack because SkyLight permits nested composites; selecting at the end of
// the matching composite preserves that nesting instead of using the most
// recently allocated display texture.
static NSMutableDictionary *g_vnc_composite_stages = nil;
static NSMutableDictionary *g_vnc_composite_pending = nil;
static _Atomic uint64_t g_vnc_completed_display_count = 0;
static _Atomic uint64_t g_vnc_pending_replace_count = 0;
static _Atomic uint64_t g_vnc_finish_count = 0;
static _Atomic uint64_t g_vnc_finish_without_texture_count = 0;
static _Atomic uint64_t g_vnc_poll_accept_count = 0;
static _Atomic uint64_t g_vnc_poll_drop_count = 0;
static _Atomic uint64_t g_vnc_poll_clean_count = 0;
static _Atomic uint64_t g_vnc_poll_error_count = 0;
void macws_vnc_stage_composite(void *context, id<MTLTexture> texture) {
    if (!macws_composite_capture_enabled() || !context || !texture) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_vnc_composite_stages = [NSMutableDictionary new];
        g_vnc_composite_pending = [NSMutableDictionary new];
    });
    NSValue *key = [NSValue valueWithPointer:context];
    @synchronized(g_vnc_composite_stages) {
        NSMutableArray *stack = g_vnc_composite_stages[key];
        if (!stack) {
            stack = [NSMutableArray array];
            g_vnc_composite_stages[key] = stack;
        }
        [stack addObject:texture];
    }
}

void macws_vnc_complete_composite(void *context) {
    if (!macws_composite_capture_enabled() || !context ||
        !g_vnc_composite_stages)
        return;
    id<MTLTexture> texture = nil;
    NSValue *key = [NSValue valueWithPointer:context];
    @synchronized(g_vnc_composite_stages) {
        NSMutableArray *stack = g_vnc_composite_stages[key];
        texture = macws_vnc_retain([stack lastObject]);
        if (texture) [stack removeLastObject];
        if ([stack count] == 0) [g_vnc_composite_stages removeObjectForKey:key];
    }
    if (!texture) return;

    size_t width = [texture width], height = [texture height];
    unsigned long pixelFormat = (unsigned long)[texture pixelFormat];
    static _Atomic int completionLog = 0;
    int n = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&completionLog, 1) : INT_MAX;
    if (n < 32) {
        fprintf(stderr,
            "#### VNC-ENDCOMPOSITE #%d context=%p tex=%p class=%s "
            "%zux%zu pf=%lu\n",
            n, context, (void *)texture, object_getClassName(texture),
            width, height, pixelFormat);
    }

    // EndCurrentComposite has ended the encoder but has not submitted the
    // MetalContext command buffer.  Preserve only the latest display-sized
    // destination for this update.  EndUpdate/Flush will publish it after the
    // matching command buffer at MetalContext+0x68 has actually completed.
    if (width >= 1000 && height >= 600 &&
        (pixelFormat == 550 || pixelFormat == 80 || pixelFormat == 115)) {
        // The same MetalContext also completes per-window intermediates. Keep
        // the largest display-sized target invariant for PF550 as well as the
        // PF80 blit path; otherwise a later 1140x798 Terminal composite can
        // replace the completed 2388x1668 scanout before EndUpdate publishes
        // it, producing the magnified/cropped VNC frame seen at runtime.
        uint64_t candidateArea = (uint64_t)width * height;
        uint64_t maxArea = atomic_load(&g_vnc_comp_max_area);
        while (candidateArea > maxArea &&
               !atomic_compare_exchange_weak(&g_vnc_comp_max_area,
                                             &maxArea, candidateArea)) {}
        maxArea = atomic_load(&g_vnc_comp_max_area);
        if (candidateArea >= maxArea) {
            BOOL replacedPending = NO;
            @synchronized(g_vnc_composite_stages) {
                replacedPending = g_vnc_composite_pending[key] != nil;
                g_vnc_composite_pending[key] = texture;
            }
            uint64_t completed = 0, replaced = 0;
            if (macws_runtime_diagnostics_enabled()) {
                completed =
                    atomic_fetch_add(&g_vnc_completed_display_count, 1) + 1;
                replaced = replacedPending
                    ? atomic_fetch_add(&g_vnc_pending_replace_count, 1) + 1
                    : atomic_load(&g_vnc_pending_replace_count);
            }
            if (completed &&
                (completed <= 32 || (completed % 600) == 0)) {
                fprintf(stderr,
                    "#### VNC-FLOW staged #%llu context=%p tex=%p "
                    "%zux%zu pf=%lu replaced=%s replaceTotal=%llu\n",
                    (unsigned long long)completed, context, (void *)texture,
                    width, height, pixelFormat,
                    replacedPending ? "YES" : "NO",
                    (unsigned long long)replaced);
            }
        } else {
            static _Atomic unsigned int rejectedFinal = 0;
            unsigned int rejected = macws_runtime_diagnostics_enabled()
                ? atomic_fetch_add(&rejectedFinal, 1) + 1 : 0;
            if (rejected &&
                (rejected <= 8 || (rejected % 600) == 0)) {
                fprintf(stderr,
                    "#### VNC-ENDCOMPOSITE reject intermediate #%u "
                    "%zux%zu pf=%lu area=%llu displayArea=%llu\n",
                    rejected, width, height, pixelFormat,
                    (unsigned long long)candidateArea,
                    (unsigned long long)maxArea);
            }
        }
    }
    macws_vnc_release(texture);
}

// Producer completions arrive continuously, including for an unchanged
// desktop.  The old code called +detachNewThreadWithBlock: for every admitted
// completion.  A 10-second production sample accumulated 69 short-lived
// __macws_vnc_finish_update_block_invoke threads, most sleeping/pixel-scanning
// for only one or two samples before exit. A serial libdispatch queue preserves
// the single-observer invariant while reusing the process worker pool instead
// of creating ~10
// NSThreads per second. The one-deep latest-state queue below now provides the
// ownership/in-flight invariant.
static dispatch_queue_t macws_vnc_completion_observer_queue(void) {
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create(
            "com.macwsguide.vnc-completion-observer",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Completion observation is a latest-state stream, not a FIFO.  A static UI
// action can submit its final display composite while the preceding source is
// still being polled.  The former pollInFlight branch dropped that final
// source outright; if no animation followed, VNC could remain on the old
// pixels indefinitely even though AppKit had already handled the click.
// Keep exactly one retained pending pair and replace it with newer state.
// The serial worker samples at most once per 16 ms, bounding CPU/memory while
// guaranteeing that the latest quiescent composite is eventually observed.
static NSObject *g_vnc_completion_pending_lock = nil;
static id<MTLCommandBuffer> g_vnc_completion_pending_command = nil;
static id<MTLTexture> g_vnc_completion_pending_texture = nil;
static void *g_vnc_completion_pending_context = NULL;
static BOOL g_vnc_completion_pending_deep_capture = NO;
static BOOL g_vnc_completion_pending_diagnostics = NO;
static uint64_t g_vnc_completion_pending_submit_serial = 0;
static _Atomic int g_vnc_completion_worker_running = 0;

static void macws_vnc_process_completion_observation(
        id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture,
        void *context, BOOL deepCapture, BOOL diagnostics,
        uint64_t submitSerial) {
    MTLCommandBufferStatus status = [commandBuffer status];
    unsigned polls = 0;
    while (status != MTLCommandBufferStatusCompleted &&
           status != MTLCommandBufferStatusError && polls < 400) {
        usleep(5000);
        status = [commandBuffer status];
        polls++;
    }
    NSError *error = status == MTLCommandBufferStatusError
        ? [commandBuffer error] : nil;
    NSInteger errorCode = error ? [error code] : 0;
    NSString *errorDomain = error ? [error domain] : nil;
    unsigned long completedPF = (unsigned long)[texture pixelFormat];
    static _Atomic int pollLog = 0;
    int n = diagnostics ? atomic_fetch_add(&pollLog, 1) : INT_MAX;
    if (n < 16) {
        // Runtime-confirmed by WindowServer-2026-07-26-161536.ips:
        // formatting one private Metal NSError walked a damaged userInfo
        // graph.  The observer only needs completion status.
        fprintf(stderr,
            "#### VNC-ENDUPDATE-POLL #%d context=%p tex=%p pf=%lu "
            "cb=%p status=%ld polls=%u error=%p domain=%p code=%ld\n",
            n, context, (void *)texture, completedPF,
            (void *)commandBuffer, (long)status, polls,
            (void *)error, (void *)errorDomain, (long)errorCode);
    }
    BOOL completedCleanly =
        status == MTLCommandBufferStatusCompleted && !error;
    if (completedCleanly) macws_publish_graphics_ready_once();
    if (completedPF == 550) {
        macws_observe_pf550_metadata(texture, submitSerial,
                                     completedCleanly);
    }
    if (completedCleanly && completedPF == 550 && submitSerial) {
        macws_mark_agx_submit_serial_for_error_dump(submitSerial);
    }
    uint64_t cleanTotal = diagnostics && completedCleanly
        ? atomic_fetch_add(&g_vnc_poll_clean_count, 1) + 1
        : (diagnostics ? atomic_load(&g_vnc_poll_clean_count) : 0);
    uint64_t errorTotal = diagnostics && !completedCleanly
        ? atomic_fetch_add(&g_vnc_poll_error_count, 1) + 1
        : (diagnostics ? atomic_load(&g_vnc_poll_error_count) : 0);
    uint64_t observedTotal = cleanTotal + errorTotal;
    if (observedTotal &&
        (observedTotal <= 32 || (observedTotal % 600) == 0)) {
        fprintf(stderr,
            "#### VNC-FLOW poll-result observed=%llu clean=%llu "
            "error=%llu pf=%lu submitSerial=%llu status=%ld "
            "code=%ld polls=%u\n",
            (unsigned long long)observedTotal,
            (unsigned long long)cleanTotal,
            (unsigned long long)errorTotal, completedPF,
            (unsigned long long)submitSerial,
            (long)status, (long)errorCode, polls);
    }
    if (diagnostics && !completedCleanly && error && errorTotal <= 4) {
        macws_log_failed_texture_descriptor(
            texture, (__bridge const void *)commandBuffer, submitSerial);
        NSString *errorDescription = [error description];
        NSDictionary *errorUserInfo = [error userInfo];
        fprintf(stderr,
            "#### VNC-FLOW command-error #%llu description=%s "
            "userInfo=%s\n",
            (unsigned long long)errorTotal,
            [errorDescription UTF8String] ?: "(nil)",
            [[errorUserInfo description] UTF8String] ?: "(nil)");
        if (errorTotal == 1)
            macws_log_command_buffer_ivars(commandBuffer);
        if (errorTotal == 1)
            macws_dump_recent_agx_submit_serial(
                "first-Metal-command-buffer-error",
                (__bridge const void *)commandBuffer, submitSerial);
    }
    BOOL inspectFailedPF550 = deepCapture && completedPF == 550 &&
        status == MTLCommandBufferStatusError &&
        access("/tmp/macws_inspect_failed_pf550", F_OK) == 0;
    if (completedCleanly || inspectFailedPF550) {
        if (completedPF == 550) {
            void *implementation =
                *(void **)((char *)(__bridge void *)texture + 0x208);
            IOSurfaceRef surface = (uintptr_t)implementation > 0x1000
                ? *(IOSurfaceRef *)((char *)implementation + 0xa0) : NULL;
            if (surface) {
                if (inspectFailedPF550) {
                    fprintf(stderr,
                        "#### VNC-DIAGNOSTIC inspecting failed PF550 "
                        "tex=%p cb=%p error=%p\n",
                        (void *)texture, (void *)commandBuffer,
                        (void *)error);
                }
                macws_vnc_track_final(texture, surface);
            }
        } else if (completedCleanly &&
                   (completedPF == 80 || completedPF == 115)) {
            if (!macws_vnc_publish_owned_texture(texture))
                macws_vnc_on_composite(texture);
        }
    }
    macws_vnc_release(commandBuffer);
    macws_vnc_release(texture);
}

static void macws_vnc_enqueue_completion_observation(
        id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture,
        void *context, BOOL deepCapture, BOOL diagnostics,
        uint64_t submitSerial) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_vnc_completion_pending_lock = [NSObject new];
    });

    BOOL replaced = NO;
    @synchronized(g_vnc_completion_pending_lock) {
        id oldCommand = g_vnc_completion_pending_command;
        id oldTexture = g_vnc_completion_pending_texture;
        replaced = oldCommand != nil || oldTexture != nil;
        g_vnc_completion_pending_command = commandBuffer;
        g_vnc_completion_pending_texture = texture;
        g_vnc_completion_pending_context = context;
        g_vnc_completion_pending_deep_capture = deepCapture;
        g_vnc_completion_pending_diagnostics = diagnostics;
        g_vnc_completion_pending_submit_serial = submitSerial;
        macws_vnc_release(oldCommand);
        macws_vnc_release(oldTexture);
    }
    if (diagnostics && replaced) {
        uint64_t coalesced = atomic_fetch_add(&g_vnc_poll_drop_count, 1) + 1;
        if (coalesced <= 32 || (coalesced % 600) == 0) {
            fprintf(stderr,
                "#### VNC-FLOW coalesced-latest #%llu context=%p "
                "tex=%p\n",
                (unsigned long long)coalesced, context, (void *)texture);
        }
    }
    if (atomic_exchange(&g_vnc_completion_worker_running, 1)) return;

    dispatch_async(macws_vnc_completion_observer_queue(), ^{
        uint64_t lastObservationNS = 0;
        for (;;) {
            @autoreleasepool {
                if (lastObservationNS != 0) {
                    struct timespec now = {0};
                    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
                        uint64_t nowNS = (uint64_t)now.tv_sec * NSEC_PER_SEC +
                            (uint64_t)now.tv_nsec;
                        uint64_t nextNS =
                            lastObservationNS + 16ull * NSEC_PER_MSEC;
                        if (nextNS > nowNS) {
                            usleep((useconds_t)((nextNS - nowNS + 999u) /
                                               1000u));
                        }
                    }
                }

                id<MTLCommandBuffer> pendingCommand = nil;
                id<MTLTexture> pendingTexture = nil;
                void *pendingContext = NULL;
                BOOL pendingDeepCapture = NO;
                BOOL pendingDiagnostics = NO;
                uint64_t pendingSubmitSerial = 0;
                @synchronized(g_vnc_completion_pending_lock) {
                    if (!g_vnc_completion_pending_command ||
                        !g_vnc_completion_pending_texture) {
                        atomic_store(&g_vnc_completion_worker_running, 0);
                        return;
                    }
                    pendingCommand = g_vnc_completion_pending_command;
                    pendingTexture = g_vnc_completion_pending_texture;
                    pendingContext = g_vnc_completion_pending_context;
                    pendingDeepCapture =
                        g_vnc_completion_pending_deep_capture;
                    pendingDiagnostics =
                        g_vnc_completion_pending_diagnostics;
                    pendingSubmitSerial =
                        g_vnc_completion_pending_submit_serial;
                    g_vnc_completion_pending_command = nil;
                    g_vnc_completion_pending_texture = nil;
                }
                struct timespec started = {0};
                if (clock_gettime(CLOCK_MONOTONIC, &started) == 0) {
                    lastObservationNS =
                        (uint64_t)started.tv_sec * NSEC_PER_SEC +
                        (uint64_t)started.tv_nsec;
                }
                macws_vnc_process_completion_observation(
                    pendingCommand, pendingTexture, pendingContext,
                    pendingDeepCapture, pendingDiagnostics,
                    pendingSubmitSerial);
            }
        }
    });
}

void macws_vnc_finish_update(void *context) {
    if (!macws_composite_capture_enabled() || !context ||
        !g_vnc_composite_pending)
        return;
    BOOL diagnostics = macws_runtime_diagnostics_enabled();
    uint64_t finish = diagnostics
        ? atomic_fetch_add(&g_vnc_finish_count, 1) + 1 : 0;
    NSValue *key = [NSValue valueWithPointer:context];
    id<MTLTexture> texture = nil;
    @synchronized(g_vnc_composite_stages) {
        texture = macws_vnc_retain(g_vnc_composite_pending[key]);
        [g_vnc_composite_pending removeObjectForKey:key];
    }
    if (!texture) {
        uint64_t missing = diagnostics
            ? atomic_fetch_add(&g_vnc_finish_without_texture_count, 1) + 1 : 0;
        if (finish && (finish <= 32 || (finish % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-FLOW finish #%llu context=%p texture=NONE "
                "missingTotal=%llu stagedTotal=%llu pollAccepted=%llu "
                "pollDropped=%llu\n",
                (unsigned long long)finish, context,
                (unsigned long long)missing,
                (unsigned long long)atomic_load(&g_vnc_completed_display_count),
                (unsigned long long)atomic_load(&g_vnc_poll_accept_count),
                (unsigned long long)atomic_load(&g_vnc_poll_drop_count));
        }
        return;
    }

    id<MTLCommandBuffer> commandBuffer = macws_vnc_retain(
        *(id<MTLCommandBuffer> *)((char *)context + 0x68));
    unsigned long pixelFormat = (unsigned long)[texture pixelFormat];

    // Runtime-confirmed by the 2026-07-27 PF550 A/B run: the legacy
    // macws_vnc_capture_final path submits its shader read on a second Metal
    // queue. WindowServer completed 4,200/4,200 producer submissions before
    // one such read, then immediately accumulated 176 producer errors. A
    // normal input event creates /tmp/macws_capture_final, so allowing that
    // request to reach the legacy path makes an ordinary click capable of
    // destabilising the compositor. Never use it implicitly. Keep the old
    // implementation available only behind an explicitly named unsafe RE
    // sentinel. A suppressed request must remain armed and unacknowledged:
    // only a content-validated PF80/115 or ordered PF550 publication may ACK
    // readiness. This is a safety fix, not a working PF550 streamer.
    BOOL captureRequested =
        access("/tmp/macws_capture_final", F_OK) == 0;
    BOOL unsafePF550Capture = pixelFormat == 550 && captureRequested &&
        access("/tmp/macws_allow_unsafe_pf550_capture", F_OK) == 0;
    if (pixelFormat == 550 && captureRequested && !unsafePF550Capture) {
        uint64_t generation = macws_vnc_capture_generation();
        static _Atomic uint64_t suppressedPF550CaptureCount = 0;
        uint64_t suppressed = diagnostics
            ? atomic_fetch_add(&suppressedPF550CaptureCount, 1) + 1 : 0;
        if (suppressed &&
            (suppressed <= 8 || (suppressed % 600) == 0)) {
            fprintf(stderr,
                "#### VNC-FINAL suppressed unsafe cross-queue PF550 "
                "capture #%llu generation=%llu\n",
                (unsigned long long)suppressed,
                (unsigned long long)generation);
        }
    }

    // Once the ordered PF550 experiment has rejected a frame, do not let a
    // later input request fall through to the already-disproved legacy path.
    // Preserve the last validated mmap frame and leave the producer alone for
    // the rest of this WindowServer lifetime.
    if (pixelFormat == 550 && atomic_load(&g_vnc_inband_faulted)) {
        macws_vnc_release(commandBuffer);
        macws_vnc_release(texture);
        return;
    }
    if (pixelFormat == 550 &&
        access("/tmp/macws_inband_pf550", F_OK) == 0) {
        id<MTLTexture> orderedDestination = nil;
        id<MTLCommandBuffer> orderedRead =
            macws_vnc_submit_pf550_ordered(texture, commandBuffer,
                                           &orderedDestination);
        // The read was synchronously enqueued on the producer's exact queue
        // before this EndUpdate hook returns. Retaining the source until that
        // read completes prevents SkyLight from destroying its wrapper early;
        // queue ordering prevents the next producer from recycling it early.
        macws_vnc_release(commandBuffer);
        if (!orderedRead || !orderedDestination) {
            macws_vnc_release(orderedRead);
            macws_vnc_release(orderedDestination);
            macws_vnc_release(texture);
            return;
        }
        // Do not return through EndUpdate while the compressed source is still
        // being read. Runtime showed IOMFB can recycle/remap that scanout as
        // soon as this hook returns, even though the wrapper remains retained.
        // A bounded poll here owns the protocol lifetime; the ordinary case is
        // 1-10 ms. This is intentionally not an uptime-masking wait: any error,
        // timeout, or constant recovery image permanently trips the diagnostic
        // circuit breaker for this WindowServer lifetime.
        MTLCommandBufferStatus status = [orderedRead status];
        unsigned polls = 0;
        while (status != MTLCommandBufferStatusCompleted &&
               status != MTLCommandBufferStatusError && polls < 200) {
            usleep(500);
            status = [orderedRead status];
            polls++;
        }
        NSError *error = status == MTLCommandBufferStatusError
            ? [orderedRead error] : nil;
        NSInteger errorCode = error ? [error code] : 0;
        BOOL clean = status == MTLCommandBufferStatusCompleted && !error;
        static _Atomic uint64_t orderedCompletionCount = 0;
        uint64_t completed =
            atomic_fetch_add(&orderedCompletionCount, 1) + 1;
        if (completed <= 32 || (completed % 600) == 0 || !clean) {
            fprintf(stderr,
                "#### VNC-INBAND completion #%llu context=%p source=%p "
                "dst=%p read=%p status=%ld polls=%u error=%p code=%ld\n",
                (unsigned long long)completed, context, (void *)texture,
                (void *)orderedDestination, (void *)orderedRead,
                (long)status, polls, (void *)error, (long)errorCode);
        }
        macws_vnc_release(orderedRead);
        macws_vnc_release(texture);
        if (!clean) {
            atomic_store(&g_vnc_inband_faulted, 1);
            (void)unlink("/tmp/macws_inband_pf550");
            fprintf(stderr,
                "#### VNC-INBAND CIRCUIT-BREAKER status=%ld code=%ld "
                "after=%llu (stream disabled; last valid mmap preserved)\n",
                (long)status, (long)errorCode,
                (unsigned long long)completed);
            macws_vnc_release(orderedDestination);
            macws_vnc_clear_inband_busy();
            return;
        }
        dispatch_async(macws_vnc_completion_observer_queue(), ^{
            @autoreleasepool {
                BOOL published = macws_vnc_publish_inband_destination(
                    orderedDestination);
                if (!published) {
                    atomic_store(&g_vnc_inband_faulted, 1);
                    (void)unlink("/tmp/macws_inband_pf550");
                    fprintf(stderr,
                        "#### VNC-INBAND CIRCUIT-BREAKER invalid output "
                        "after=%llu (stream disabled; last valid mmap preserved)\n",
                        (unsigned long long)completed);
                }
                macws_vnc_release(orderedDestination);
                macws_vnc_clear_inband_busy();
            }
        });
        return;
    }

    BOOL deepCapture = unsafePF550Capture;

    // The ordinary VNC bridge consumes the completed, uncompressed PF80/115
    // composite and never needs physical-display scanout.  PF550 remains an
    // explicitly armed deep diagnostic: without the sentinel, do not retain
    // or wait on compressed IOMFB page surfaces.  Runtime A/B on 2026-07-25
    // captured the complete blurred GlassDemo from PF80 with no VNC-FINAL
    // capture and a stable ~65 MiB type-82 footprint.
    // Diagnostic only: /tmp/macws_observe_pf550 observes every completed
    // display-sized PF550 submission without issuing a readback command.  It
    // distinguishes a broken WindowServer submission from interference caused
    // by the one-shot PF550 shader capture itself.  Production still observes
    // PF550 only while an explicit capture generation is armed.
    BOOL observePF550 = pixelFormat == 550 &&
        access("/tmp/macws_observe_pf550", F_OK) == 0;
    BOOL observeCurrent = deepCapture || observePF550 ||
        pixelFormat == 80 || pixelFormat == 115;
    if (!observeCurrent) {
        macws_vnc_release(commandBuffer);
        macws_vnc_release(texture);
        return;
    }

    if (!commandBuffer || ![commandBuffer respondsToSelector:@selector(status)]) {
        static int missingLog = 0;
        if (diagnostics && missingLog++ < 4) {
            fprintf(stderr,
                "#### VNC-ENDUPDATE no submitted command buffer context=%p "
                "tex=%p cb=%p\n", context, (void *)texture,
                (void *)commandBuffer);
        }
        macws_vnc_release(commandBuffer);
        macws_vnc_release(texture);
        return;
    }

    // EndUpdate/Flush has already committed this buffer.  Metal aborts if an
    // addCompletedHandler: is added here (runtime-confirmed by the assertion
    // "Completed handler provided after commit call" and the matching crash
    // frame at Metal_hooks.x:856).  A background wait is also not purely
    // observational: it changes the timing of the PF550/SwapCancel transition
    // (a no-wait control proved the transition also occurs naturally).  Instead,
    // One read-only observer is enough: it polls status for at most two
    // seconds, but never waits, commits, or registers a post-commit handler.
    // This lets the initial PF80 frame reach the mmap before the VNC-only
    // session would otherwise enter its IOMFB PF550 capture cycle.
    uint64_t accepted = diagnostics
        ? atomic_fetch_add(&g_vnc_poll_accept_count, 1) + 1 : 0;
    uint64_t submitSerial = diagnostics
        ? macws_latest_agx_submit_serial(
            (__bridge const void *)commandBuffer) : 0;
    if (accepted && (accepted <= 32 || (accepted % 600) == 0)) {
        fprintf(stderr,
            "#### VNC-FLOW poll-accept #%llu finish=%llu context=%p "
            "tex=%p pf=%lu submitSerial=%llu dropped=%llu\n",
            (unsigned long long)accepted, (unsigned long long)finish,
            context, (void *)texture, pixelFormat,
            (unsigned long long)submitSerial,
            (unsigned long long)atomic_load(&g_vnc_poll_drop_count));
    }
    // Ownership of both retained objects transfers to the one-deep latest
    // queue.  Replacing a pending source releases it immediately; the worker
    // releases the selected pair after observing producer completion.
    // The Host branch takes its own bounded retains and runs independently of
    // the CPU damage scanner below.
    // Only the process-owned display target can contain the coherent final
    // SkyLight frame.  Enqueuing every unrelated PF80 render target allowed a
    // later small/intermediate texture to replace that final target in the
    // one-deep slot before the observer ran, even though the slower VNC worker
    // eventually sampled the owned target.  Filter at the ownership boundary
    // instead of teaching the consumer to guess which PF80 was intended.
    if (macws_final_composite_enabled() && pixelFormat == 80 &&
        macws_is_owned_scanout_texture(texture)) {
        IOSurfaceRef finalSurface = macws_vnc_bound_surface(texture);
        if (finalSurface) {
            MacWSFinalCompositePublisherEnqueueCompletion(
                commandBuffer, texture, finalSurface,
                (uint32_t)pixelFormat);
        }
    }
    // Final-composite-only sessions need the CPU classifier once to establish
    // that the owned display target contains real desktop pixels. After that
    // the completed AGX snapshot path is authoritative and performs no RFB
    // mmap copy or per-frame CPU scan. VNC keeps the existing observer for
    // damage publication and screenshot requests.
    if (macws_vnc_share_enabled() || deepCapture ||
        !MacWSFinalCompositePublisherCanPublish()) {
        macws_vnc_enqueue_completion_observation(
            commandBuffer, texture, context, deepCapture, diagnostics,
            submitSerial);
    } else {
        macws_vnc_release(commandBuffer);
        macws_vnc_release(texture);
    }
}

// Track a display-sized (tex, IOSurface) pair and spawn the single bg bridge
// thread on first use. The thread either fills the surface gray (mode 1) or
// copies the texture's CPU-mapped GPU backing (+0xa0, which holds the real
// GPU-rendered composite — see [[composite-iosurface-all-zero-gpu-not-writing]])
// into the IOSurface that CGDisplayCreateImage reads
// ([[vnc-read-path-is-cgdisplaycreateimage-compositor-black]]).
static NSMutableArray *g_dispTexs = nil;   // id<MTLTexture>, ARC-retained
static NSMutableArray *g_dispSurfs = nil;  // NSValue ptr, surface CFRetained
static void macws_disp_fill_track(id<MTLTexture> tex, IOSurfaceRef iosurface) {
    int mode = macws_disp_mode();
    if (!iosurface) return;
    size_t iw = IOSurfaceGetWidth(iosurface);
    size_t ih = IOSurfaceGetHeight(iosurface);
    unsigned long pf = tex ? (unsigned long)[tex pixelFormat] : 0;
    if (macws_vnc_share_enabled() && tex && iw >= 1000 && ih >= 600) {
        if (pf == 550 && macws_runtime_diagnostics_enabled()) {
            static _Atomic int pf550SurfaceDumped = 0;
            if (!atomic_exchange(&pf550SurfaceDumped, 1)) {
                OSType fourcc = IOSurfaceGetPixelFormat(iosurface);
                size_t planes = IOSurfaceGetPlaneCount(iosurface);
                CFDictionaryRef values = IOSurfaceCopyAllValues(iosurface);
                NSString *description = values
                    ? [(__bridge NSDictionary *)values
                        descriptionWithLocale:nil indent:0]
                    : @"(null)";
                fprintf(stderr,
                    "#### VNC-FINAL IOSURFACE pf550 id=%u alloc=%zu bpr=%zu "
                    "bpe=%zu fourcc=%#x planes=%zu values=%s\n",
                    IOSurfaceGetID(iosurface),
                    IOSurfaceGetAllocSize(iosurface),
                    IOSurfaceGetBytesPerRow(iosurface),
                    IOSurfaceGetBytesPerElement(iosurface),
                    (unsigned)fourcc, planes, [description UTF8String]);
                if (values) CFRelease(values);
            }
        }
        static _Atomic int finalLog = 0;
        int n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&finalLog, 1) : INT_MAX;
        if (n < 24) {
            fprintf(stderr,
                "#### VNC-FINAL candidate #%d tex=%p class=%s tex=%zux%zu pf=%lu "
                "usage=%#lx storage=%lu hazard=%lu surface=%p %zux%zu bpr=%zu\n",
                n, (void *)tex, object_getClassName(tex),
                [tex width], [tex height], pf, (unsigned long)[tex usage],
                (unsigned long)[tex storageMode],
                (unsigned long)[tex hazardTrackingMode],
                (void *)iosurface, iw, ih, IOSurfaceGetBytesPerRow(iosurface));
        }
        // Do not select pf550 here.  This callback runs when the texture is
        // created/bound, before SkyLight has encoded its composite.  The
        // matching EndCurrentComposite hook selects the completed target.
    }
    if (mode == 0) return;
    if (iw < 1000 || ih < 600) return;
    static dispatch_once_t dispOnce;
    dispatch_once(&dispOnce, ^{
        g_dispTexs = [NSMutableArray new];
        g_dispSurfs = [NSMutableArray new];
        [NSThread detachNewThreadWithBlock:^{
            for (;;) {
                @synchronized(g_dispSurfs) {
                    NSUInteger n = g_dispSurfs.count;
                    for (NSUInteger i = 0; i < n; i++) {
                        IOSurfaceRef s = (IOSurfaceRef)[g_dispSurfs[i] pointerValue];
                        id<MTLTexture> t = (i < g_dispTexs.count) ? g_dispTexs[i] : nil;
                        if (IOSurfaceLock(s, 0, NULL) != 0) continue;
                        void *base = IOSurfaceGetBaseAddress(s);
                        size_t sbpr = IOSurfaceGetBytesPerRow(s);
                        size_t sh = IOSurfaceGetHeight(s);
                        if (mode == 1) {
                            size_t al = IOSurfaceGetAllocSize(s);
                            if (base && al) memset(base, 0xC0, al);
                        } else if (mode == 2 && t && base) {
                            // SAFE raw copy of the texture's GPU backing (+0xa0)
                            // into the surface. NOTE: backing is AGX-tiled so
                            // this is NOT display-correct yet — it's the input
                            // for CPU detiling (TODO). getBytes auto-detiles but
                            // CRASHES WS from a bg thread (races render). Raw
                            // memcpy is safe.
                            void *impl = *(void **)((char *)(__bridge void *)t + 0x208);
                            if ((uintptr_t)impl > 0x1000) {
                                void *backing = *(void **)((char *)impl + 0xa0);
                                if (backing)
                                    for (size_t y = 0; y < sh; y++)
                                        memcpy((char *)base + y * sbpr,
                                               (char *)backing + y * sbpr, sbpr);
                                // Mirror this filled display surface to the global
                                // VNC share surface (cross-process → OSXvnc).
                                if (backing)
                                    macws_vnc_share_mirror(base, sbpr, sh, iw);
                                // One-shot raw dumps for OFFLINE detile RE,
                                // gated by sentinel /tmp/macws_disp_dump. Two
                                // independent files so we learn which texture
                                // actually holds content:
                                //   /tmp/macws_back115.raw   = the pf=115 (16F)
                                //       composite (the surface CreateImage reads)
                                //   /tmp/macws_backdense.raw = densest of any pf
                                // Header: {w, h, pf, dens*1e6}.
                                if (backing && access("/tmp/macws_disp_dump", F_OK) == 0 &&
                                    [t width] >= 1000) {
                                    size_t tw = [t width], th = [t height];
                                    unsigned long pf = (unsigned long)[t pixelFormat];
                                    size_t bpe = (pf == 115) ? 8 : 4;
                                    size_t total = tw * th * bpe;
                                    // Denser nonzero sampler (every 256B, was 1024)
                                    // — 16F low-bytes are often 0 so coarse sampling
                                    // undercounted the real composite.
                                    size_t nzc = 0, samp = 0;
                                    for (size_t off = 0; off < total; off += 256) {
                                        if (((uint8_t *)backing)[off]) nzc++;
                                        samp++;
                                    }
                                    double dens = samp ? (double)nzc / samp : 0;
                                    static int s_d115 = 0;
                                    if (!s_d115 && pf == 115) {
                                        FILE *df = fopen("/tmp/macws_back115.raw", "wb");
                                        if (df) {
                                            uint32_t hdr[4] = { (uint32_t)tw, (uint32_t)th, (uint32_t)pf, (uint32_t)(dens*1e6) };
                                            fwrite(hdr, 4, 4, df); fwrite(backing, 1, total, df); fclose(df);
                                            s_d115 = 1;
                                            fprintf(stderr, "#### DUMP115 %zux%zu dens=%.3f\n", tw, th, dens);
                                        }
                                    }
                                    static int s_ddense = 0;
                                    if (!s_ddense && dens > 0.01) {
                                        FILE *df = fopen("/tmp/macws_backdense.raw", "wb");
                                        if (df) {
                                            uint32_t hdr[4] = { (uint32_t)tw, (uint32_t)th, (uint32_t)pf, (uint32_t)(dens*1e6) };
                                            fwrite(hdr, 4, 4, df); fwrite(backing, 1, total, df); fclose(df);
                                            s_ddense = 1;
                                            fprintf(stderr, "#### DUMPDENSE %zux%zu pf=%lu dens=%.3f\n", tw, th, pf, dens);
                                        }
                                    }
                                }
                            }
                        }
                        IOSurfaceUnlock(s, 0, NULL);
                    }
                }
                usleep(mode == 2 ? 16000 : 25000);
            }
        }];
    });
    @synchronized(g_dispSurfs) {
        for (NSValue *v in g_dispSurfs)
            if ((IOSurfaceRef)[v pointerValue] == iosurface) return;
        CFRetain(iosurface);
        [g_dispSurfs addObject:[NSValue valueWithPointer:iosurface]];
        [g_dispTexs addObject:(tex ?: (id)[NSNull null])];
        // Log layout once so we know if the backing is linear (flat copy OK)
        // or Morton-tiled (would need detiling).
        uint8_t layout = 0xff;
        if (tex) {
            void *impl = *(void **)((char *)(__bridge void *)tex + 0x208);
            if ((uintptr_t)impl > 0x1000) layout = *(uint8_t *)((char *)impl + 0x184);
        }
        uint32_t tstride = 0;
        if (tex) {
            void *impl = *(void **)((char *)(__bridge void *)tex + 0x208);
            if ((uintptr_t)impl > 0x1000) tstride = *(uint32_t *)((char *)impl + 0xa8);
        }
        fprintf(stderr, "#### DISP-BRIDGE mode=%d track surf=%p tex=%p %zux%zu layout=%u tstride=%u sbpr=%zu (n=%lu)\n",
                mode, (void*)iosurface, (void*)tex, iw, ih, layout, tstride,
                IOSurfaceGetBytesPerRow(iosurface), (unsigned long)g_dispSurfs.count);
        unsigned long tpf = tex ? (unsigned long)[tex pixelFormat] : 0;
        unsigned long tw = tex ? (unsigned long)[tex width] : 0;
        unsigned long th = tex ? (unsigned long)[tex height] : 0;
        FILE *lf = fopen("/tmp/macws_disp.log", "a");
        if (lf) {
            fprintf(lf, "DISP-BRIDGE mode=%d surf=%p tex=%p surf=%zux%zu tex=%lux%lu pf=%lu layout=%u tstride=%u sbpr=%zu n=%lu\n",
                    mode, (void*)iosurface, (void*)tex, iw, ih, tw, th, tpf, layout, tstride,
                    IOSurfaceGetBytesPerRow(iosurface), (unsigned long)g_dispSurfs.count);
            fclose(lf);
        }
    }
}

typedef struct {
    ptrdiff_t offset;
    uint8_t bytes[24];
    uint64_t address;
    // The extended word is a conditional union.  It carries an acceleration
    // buffer only for compressed layouts; linear layouts reuse these bits for
    // depth/layer-stride fields (Mesa Asahi cmdbuf.xml, audited 2026-07-27).
    uint64_t extended_raw;
    uint64_t extended_low36;
    unsigned layout;
    unsigned compressed;
    unsigned extended;
} macws_texture_descriptor_witness;

// The iOS 16.3 AGX object placed the hardware descriptor at impl+0x180, while
// the macOS 13.4 AGX object running in chroot placed the matching width/height
// encoding later.  Locate it by invariant descriptor fields instead of
// treating either private C++ offset as cross-OS ABI.
static bool macws_find_texture_descriptor(void *impl, size_t width,
                                          size_t height,
                                          macws_texture_descriptor_witness *out) {
    if (!impl || !out || width == 0 || height == 0) return false;
    for (ptrdiff_t offset = 0x140; offset <= 0x240; offset++) {
        uint64_t word0 = 0, word1 = 0, extended_raw = 0;
        memcpy(&word0, (char *)impl + offset, sizeof(word0));
        memcpy(&word1, (char *)impl + offset + 8, sizeof(word1));
        size_t encoded_width = (size_t)((word0 >> 28) & 0x3fff) + 1;
        size_t encoded_height = (size_t)((word0 >> 42) & 0x3fff) + 1;
        if (encoded_width != width || encoded_height != height) continue;
        memcpy(out->bytes, (char *)impl + offset, sizeof(out->bytes));
        memcpy(&extended_raw, out->bytes + 16, sizeof(extended_raw));
        out->offset = offset;
        out->address = ((word1 >> 2) & 0xfffffffffULL) << 4;
        out->extended_raw = extended_raw;
        out->extended_low36 = (extended_raw & 0xfffffffffULL) << 4;
        out->layout = (unsigned)((word0 >> 4) & 0x3);
        out->compressed = (unsigned)((word1 >> 39) & 1);
        out->extended = (unsigned)((word1 >> 63) & 1);
        return true;
    }
    return false;
}

// Diagnostic-only PF550 compression metadata witness.  The GPU mapping and
// IOSurface property recovery have already been established upstream by the
// real AGX initializer; this code never modifies or retains either object.  It
// copies a bounded sample only after Metal reports the producer command buffer
// completed (or failed), then compares the first failure with the most recent
// clean PF550 submission.  Enable with /tmp/macws_pf550_metadata_diag.
typedef struct {
    BOOL valid;
    uint64_t submit_serial;
    uint32_t surface_id;
    uint32_t width;
    uint32_t height;
    uint64_t alloc_size;
    uintptr_t cpu_mapping;
    uint64_t gpu_mapping;
    uint64_t descriptor_address;
    uint64_t acceleration_address;
    uint64_t acceleration_offset;
    uint64_t plane_offset;
    uint64_t plane_size;
    uint64_t bytes_per_row;
    uint64_t compression_type;
    uint64_t width_in_tiles;
    uint64_t height_in_tiles;
    uint64_t bytes_per_tile_data;
    uint64_t address_format;
    uint64_t header_offset;
    uint64_t header_span;
    uint64_t acceleration_hash;
    uint64_t header_hash;
    uint32_t acceleration_nonzero;
    uint32_t header_nonzero;
    uint8_t acceleration_head[64];
    uint8_t acceleration_tail[64];
    uint8_t header_head[64];
} macws_pf550_metadata_snapshot;

static pthread_mutex_t g_macws_pf550_metadata_lock = PTHREAD_MUTEX_INITIALIZER;
static macws_pf550_metadata_snapshot g_macws_pf550_last_clean_metadata;

static uint64_t macws_pf550_dict_uint64(NSDictionary *dictionary,
                                        NSString *short_key,
                                        NSString *full_key) {
    if (!dictionary) return 0;
    id value = dictionary[short_key] ?: dictionary[full_key];
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue] : 0;
}

static void macws_pf550_sample_region(const uint8_t *base, uint64_t alloc_size,
                                      uint64_t offset, uint64_t span,
                                      uint64_t *hash_out,
                                      uint32_t *nonzero_out,
                                      uint8_t head[64], uint8_t tail[64]) {
    if (!base || offset >= alloc_size || span == 0) return;
    uint64_t available = alloc_size - offset;
    if (span > available) span = available;
    size_t sampled = (size_t)(span > 4096 ? 4096 : span);
    const uint8_t *source = base + offset;
    uint64_t hash = 1469598103934665603ULL;
    uint32_t nonzero = 0;
    for (size_t i = 0; i < sampled; i++) {
        uint8_t byte = source[i];
        hash ^= byte;
        hash *= 1099511628211ULL;
        if (byte) nonzero++;
    }
    size_t head_size = span < 64 ? (size_t)span : 64;
    if (head && head_size) memcpy(head, source, head_size);
    if (tail && head_size) memcpy(tail, source + span - head_size, head_size);
    if (hash_out) *hash_out = hash;
    if (nonzero_out) *nonzero_out = nonzero;
}

static macws_pf550_metadata_snapshot macws_pf550_capture_metadata(
        id texture, uint64_t submit_serial) {
    macws_pf550_metadata_snapshot snapshot = {0};
    if (!texture) return snapshot;

    NSUInteger width = 0, height = 0, pixel_format = 0;
    IOSurfaceRef surface = NULL;
    @try {
        width = [texture respondsToSelector:@selector(width)]
            ? (NSUInteger)[texture width] : 0;
        height = [texture respondsToSelector:@selector(height)]
            ? (NSUInteger)[texture height] : 0;
        pixel_format = [texture respondsToSelector:@selector(pixelFormat)]
            ? (NSUInteger)[texture pixelFormat] : 0;
        if ([texture respondsToSelector:@selector(iosurface)])
            surface = (IOSurfaceRef)[texture iosurface];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (!surface || pixel_format != 550) return snapshot;

    ptrdiff_t impl_offset = 0x208;
    Ivar ivar = class_getInstanceVariable([texture class], "_impl");
    if (ivar) impl_offset = ivar_getOffset(ivar);
    void *impl = *(void **)((char *)(__bridge void *)texture + impl_offset);
    if (!impl) return snapshot;

    macws_texture_descriptor_witness descriptor = {0};
    if (!macws_find_texture_descriptor(impl, width, height, &descriptor))
        return snapshot;

    snapshot.submit_serial = submit_serial;
    snapshot.surface_id = IOSurfaceGetID(surface);
    snapshot.width = (uint32_t)width;
    snapshot.height = (uint32_t)height;
    snapshot.alloc_size = IOSurfaceGetAllocSize(surface);
    snapshot.cpu_mapping =
        (uintptr_t)*(void * volatile *)((char *)impl + 0x130);
    snapshot.gpu_mapping =
        *(const volatile uint64_t *)((const char *)impl + 0x40);
    snapshot.descriptor_address = descriptor.address;
    snapshot.acceleration_address = descriptor.compressed
        ? descriptor.extended_low36 : 0;
    if (descriptor.compressed &&
        descriptor.extended_low36 >= descriptor.address) {
        snapshot.acceleration_offset =
            descriptor.extended_low36 - descriptor.address;
    }

    CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
    if (copied) {
        @try {
            NSDictionary *root = (__bridge NSDictionary *)copied;
            id creation_value = root[@"CreationProperties"];
            NSDictionary *creation =
                [creation_value isKindOfClass:[NSDictionary class]]
                    ? (NSDictionary *)creation_value : root;
            id plane_info_value = creation[@"IOSurfacePlaneInfo"];
            if ([plane_info_value isKindOfClass:[NSArray class]] &&
                [(NSArray *)plane_info_value count] != 0) {
                id plane_value = [(NSArray *)plane_info_value objectAtIndex:0];
                if ([plane_value isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *plane = (NSDictionary *)plane_value;
                    snapshot.plane_offset = macws_pf550_dict_uint64(
                        plane, @"Offset", @"IOSurfacePlaneOffset");
                    snapshot.plane_size = macws_pf550_dict_uint64(
                        plane, @"Size", @"IOSurfacePlaneSize");
                    snapshot.bytes_per_row = macws_pf550_dict_uint64(
                        plane, @"BytesPerRow", @"IOSurfacePlaneBytesPerRow");
                    snapshot.compression_type = macws_pf550_dict_uint64(
                        plane, @"CompressionType",
                        @"IOSurfacePlaneCompressionType");
                    snapshot.width_in_tiles = macws_pf550_dict_uint64(
                        plane, @"WidthInCompressedTiles",
                        @"IOSurfacePlaneWidthInCompressedTiles");
                    snapshot.height_in_tiles = macws_pf550_dict_uint64(
                        plane, @"HeightInCompressedTiles",
                        @"IOSurfacePlaneHeightInCompressedTiles");
                    snapshot.bytes_per_tile_data = macws_pf550_dict_uint64(
                        plane, @"BytesPerTileData",
                        @"IOSurfacePlaneBytesPerTileData");
                    snapshot.address_format = macws_pf550_dict_uint64(
                        plane, @"AddressFormat",
                        @"IOSurfaceAddressFormat");
                    snapshot.header_offset = macws_pf550_dict_uint64(
                        plane, @"CompressedTileHeaderRegionOffset",
                        @"IOSurfacePlaneCompressedTileHeaderRegionOffset");
                    uint64_t plane_end = snapshot.plane_offset +
                        snapshot.plane_size;
                    if (plane_end >= snapshot.plane_offset &&
                        snapshot.header_offset >= snapshot.plane_offset &&
                        snapshot.header_offset < plane_end) {
                        snapshot.header_span =
                            plane_end - snapshot.header_offset;
                    }
                }
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
        CFRelease(copied);
    }

    const uint8_t *cpu = (const uint8_t *)snapshot.cpu_mapping;
    macws_pf550_sample_region(cpu, snapshot.alloc_size,
        snapshot.acceleration_offset,
        snapshot.header_span ? snapshot.header_span : 4096,
        &snapshot.acceleration_hash, &snapshot.acceleration_nonzero,
        snapshot.acceleration_head, snapshot.acceleration_tail);
    macws_pf550_sample_region(cpu, snapshot.alloc_size,
        snapshot.header_offset,
        snapshot.header_span ? snapshot.header_span : 4096,
        &snapshot.header_hash, &snapshot.header_nonzero,
        snapshot.header_head, NULL);
    snapshot.valid = snapshot.cpu_mapping != 0 && snapshot.alloc_size != 0;
    return snapshot;
}

static void macws_pf550_hex64(const uint8_t bytes[64], char output[129]) {
    for (size_t i = 0; i < 64; i++)
        snprintf(output + i * 2, 3, "%02x", bytes[i]);
}

static void macws_pf550_log_metadata(const char *role,
                                     const macws_pf550_metadata_snapshot *s) {
    if (!s || !s->valid) {
        fprintf(stderr, "#### PF550-META role=%s valid=0\n", role);
        return;
    }
    char acceleration_head[129], acceleration_tail[129], header_head[129];
    macws_pf550_hex64(s->acceleration_head, acceleration_head);
    macws_pf550_hex64(s->acceleration_tail, acceleration_tail);
    macws_pf550_hex64(s->header_head, header_head);
    fprintf(stderr,
        "#### PF550-META role=%s serial=%llu surface=%u %ux%u alloc=%#llx "
        "cpu=%#llx gpu=%#llx address=%#llx acceleration=%#llx "
        "accelerationOffset=%#llx planeOffset=%#llx planeSize=%#llx "
        "headerOffset=%#llx headerSpan=%#llx bpr=%#llx compression=%#llx "
        "tiles=%llux%llu bytesPerTile=%#llx addressFormat=%#llx\n",
        role, (unsigned long long)s->submit_serial, s->surface_id,
        s->width, s->height, (unsigned long long)s->alloc_size,
        (unsigned long long)s->cpu_mapping,
        (unsigned long long)s->gpu_mapping,
        (unsigned long long)s->descriptor_address,
        (unsigned long long)s->acceleration_address,
        (unsigned long long)s->acceleration_offset,
        (unsigned long long)s->plane_offset,
        (unsigned long long)s->plane_size,
        (unsigned long long)s->header_offset,
        (unsigned long long)s->header_span,
        (unsigned long long)s->bytes_per_row,
        (unsigned long long)s->compression_type,
        (unsigned long long)s->width_in_tiles,
        (unsigned long long)s->height_in_tiles,
        (unsigned long long)s->bytes_per_tile_data,
        (unsigned long long)s->address_format);
    fprintf(stderr,
        "#### PF550-META-BYTES role=%s accelerationHash=%#llx "
        "accelerationNZ4K=%u headerHash=%#llx headerNZ4K=%u "
        "accelerationHead=%s accelerationTail=%s headerHead=%s\n",
        role, (unsigned long long)s->acceleration_hash,
        s->acceleration_nonzero, (unsigned long long)s->header_hash,
        s->header_nonzero, acceleration_head, acceleration_tail, header_head);
}

static void macws_observe_pf550_metadata(id texture, uint64_t submit_serial,
                                         BOOL completed_cleanly) {
    if (!texture || access("/tmp/macws_pf550_metadata_diag", F_OK) != 0)
        return;
    macws_pf550_metadata_snapshot current =
        macws_pf550_capture_metadata(texture, submit_serial);
    if (!current.valid) return;
    if (completed_cleanly) {
        static _Atomic uint64_t clean_count = 0;
        uint64_t count = atomic_fetch_add(&clean_count, 1) + 1;
        pthread_mutex_lock(&g_macws_pf550_metadata_lock);
        g_macws_pf550_last_clean_metadata = current;
        pthread_mutex_unlock(&g_macws_pf550_metadata_lock);
        if (count == 1) macws_pf550_log_metadata("first-clean", &current);
        return;
    }

    macws_pf550_metadata_snapshot previous = {0};
    pthread_mutex_lock(&g_macws_pf550_metadata_lock);
    previous = g_macws_pf550_last_clean_metadata;
    pthread_mutex_unlock(&g_macws_pf550_metadata_lock);
    macws_pf550_log_metadata("last-clean", &previous);
    macws_pf550_log_metadata("error", &current);
    fprintf(stderr,
        "#### PF550-META-COMPARE cleanSerial=%llu errorSerial=%llu "
        "sameGeometry=%d sameLayout=%d sameAccelerationOffset=%d "
        "samePropertyHeaderOffset=%d sameAccelerationSample=%d "
        "sameHeaderSample=%d\n",
        (unsigned long long)previous.submit_serial,
        (unsigned long long)current.submit_serial,
        previous.width == current.width && previous.height == current.height,
        previous.plane_offset == current.plane_offset &&
            previous.plane_size == current.plane_size &&
            previous.header_span == current.header_span,
        previous.acceleration_offset == current.acceleration_offset,
        previous.header_offset == current.header_offset,
        previous.acceleration_hash == current.acceleration_hash &&
            previous.acceleration_nonzero == current.acceleration_nonzero,
        previous.header_hash == current.header_hash &&
            previous.header_nonzero == current.header_nonzero);
}

// Read-only snapshot at the exact command-buffer error observation boundary.
// Unlike the creation-time PF550 witness, this records the descriptor after
// all updateBindData/metadata initialization has run and correlates it with the
// submission serial captured before the background status poll began.
static void macws_log_failed_texture_descriptor(
        id texture, const void *command_buffer, uint64_t submit_serial) {
    if (!texture) return;
    NSUInteger width = 0, height = 0, pixel_format = 0;
    IOSurfaceRef surface = NULL;
    @try {
        width = [texture respondsToSelector:@selector(width)]
            ? (NSUInteger)[texture width] : 0;
        height = [texture respondsToSelector:@selector(height)]
            ? (NSUInteger)[texture height] : 0;
        pixel_format = [texture respondsToSelector:@selector(pixelFormat)]
            ? (NSUInteger)[texture pixelFormat] : 0;
        if ([texture respondsToSelector:@selector(iosurface)])
            surface = (IOSurfaceRef)[texture iosurface];
    } @catch (NSException *exception) {
        (void)exception;
    }
    ptrdiff_t impl_offset = 0x208;
    Ivar ivar = class_getInstanceVariable([texture class], "_impl");
    if (ivar) impl_offset = ivar_getOffset(ivar);
    void *impl = *(void **)((char *)(__bridge void *)texture + impl_offset);
    macws_texture_descriptor_witness descriptor = {0};
    BOOL found = impl && macws_find_texture_descriptor(
        impl, width, height, &descriptor);
    char hex[sizeof(descriptor.bytes) * 2 + 1];
    for (size_t i = 0; i < sizeof(descriptor.bytes); i++)
        snprintf(hex + i * 2, 3, "%02x", descriptor.bytes[i]);
    fprintf(stderr,
        "#### VNC-FAULT-TEX commandBuffer=%p submitSerial=%llu tex=%p "
        "class=%s impl=%p implOff=%#tx %lux%lu pf=%lu surface=%u "
        "cpu130=%p gpu40=%#llx found=%d descOff=%#tx layout=%u "
        "compressed=%u extended=%u address=%#llx "
        "extendedLow36=%#llx extendedRaw=%#llx bytes=%s\n",
        command_buffer, (unsigned long long)submit_serial,
        (__bridge void *)texture, class_getName([texture class]), impl,
        impl_offset, (unsigned long)width, (unsigned long)height,
        (unsigned long)pixel_format,
        surface ? IOSurfaceGetID(surface) : 0,
        impl ? *(void **)((char *)impl + 0x130) : NULL,
        (unsigned long long)(impl
            ? *(const volatile uint64_t *)((const char *)impl + 0x40) : 0),
        found, found ? descriptor.offset : (ptrdiff_t)-1,
        found ? descriptor.layout : 0,
        found ? descriptor.compressed : 0,
        found ? descriptor.extended : 0,
        (unsigned long long)(found ? descriptor.address : 0),
        (unsigned long long)(found ? descriptor.extended_low36 : 0),
        (unsigned long long)(found ? descriptor.extended_raw : 0), hex);
}

// Read-only audit of the AGX texture mapping established by Apple's real
// initializer.  Project LLDB RE on AGXMetal13_3 UUID
// 727C250E-554D-3921-A5B3-48DAE6195B79 corrected the old field attribution:
//
//   Texture+0xa0  = IOSurfaceRef
//   Texture+0xa8  = IOSurface plane
//   Texture+0x130 = CPU mapping consumed by getCPUPtr/writeRegion
//
// The old implementation wrote IOSurfaceGetBaseAddress() to +0xa0, corrupting
// the IOSurfaceRef, and never populated +0x130.  Do not synthesize either
// field here.  `updateBindDataWithAddresses:...` is the upstream owner and
// stores the CPU/GPU mappings at +0x130/+0x40 before calling
// texBaseAddressesUpdated().  This helper now only records the postcondition.
static void macws_audit_iosurface_texture_mapping(id<MTLTexture> tex,
                                                  IOSurfaceRef surf,
                                                  NSUInteger requested_plane,
                                                  NSUInteger requested_width,
                                                  NSUInteger requested_height,
                                                  NSUInteger requested_format) {
    // The focused video witness must also see the constructor-side descriptor
    // for the exact VideoToolbox surface.  Keep every other texture behind the
    // broader runtime recorder so this sentinel remains bounded to two 420v
    // plane views per decoded-frame surface.
    BOOL focused_video = macws_video_diag_enabled() && surf &&
        IOSurfaceGetPixelFormat(surf) == (uint32_t)'420v';
    if (!macws_runtime_diagnostics_enabled() && !focused_video) return;
    if (!tex || !surf) return;
    // This witness describes the private AGXG13GFamilyTexture layout below;
    // it is not a generic MTLTexture ABI.  The MTLSim path returns an
    // MTLSimTexture whose object is only 0x58 bytes in the Chromium 148 GPU
    // process.  Treating its bytes at +0x208 as AGX's `_impl` produced a PAC-
    // shaped value and made this read-only diagnostic itself crash at
    // impl+0xa0.  Runtime-confirmed by LLDB on Code Helper PID 13662, with the
    // caller `-[MTLFakeDevice hooked_newTextureWithDescriptor:iosurface:plane:]`.
    Class agx_texture_class = objc_getClass("AGXG13GFamilyTexture");
    if (!agx_texture_class ||
        ![(id)tex isKindOfClass:agx_texture_class]) {
        return;
    }
    // Resolve _impl ivar offset dynamically (fallback to 0x208 from RE
    // if the class introspection fails — UUID-stable across 13.x).
    static ptrdiff_t s_impl_off = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("AGXG13GFamilyTexture");
        if (cls) {
            Ivar iv = class_getInstanceVariable(cls, "_impl");
            if (iv) {
                s_impl_off = ivar_getOffset(iv);
            }
        }
        if (s_impl_off == 0) s_impl_off = 0x208;  // RE-fallback
        dprintf(STDERR_FILENO,
            "#### AGX_MAP_AUDIT: _impl ivar offset = %#tx\n", s_impl_off);
    });
    void *impl = *(void **)((char *)(__bridge void *)tex + s_impl_off);
    if (!impl) {
        static int impllog = 0;
        if (impllog++ < 3) {
            dprintf(STDERR_FILENO,
                "#### AGX_MAP_AUDIT: _impl=NULL tex=%p surf=%p\n",
                (void *)tex, (void *)surf);
        }
        return;
    }
    IOSurfaceRef bound_surface =
        *(IOSurfaceRef volatile *)((char *)impl + 0xa0);
    uint32_t bound_plane = *(volatile uint32_t *)((char *)impl + 0xa8);
    void *cpu_mapping = *(void * volatile *)((char *)impl + 0x130);
    uint64_t gpu_mapping = *(volatile uint64_t *)((char *)impl + 0x40);
    macws_texture_descriptor_witness descriptor = {0};
    bool has_descriptor = macws_find_texture_descriptor(
        impl, requested_width, requested_height, &descriptor);
    static _Atomic int audit_count = 0;
    int n = atomic_fetch_add(&audit_count, 1);
    BOOL video_plane = requested_plane != 0 || requested_format == 10 ||
        requested_format == 30;
    if (n < 32 || video_plane || bound_surface != surf ||
        bound_plane != requested_plane || cpu_mapping == NULL) {
        dprintf(STDERR_FILENO,
            "#### AGX_MAP_AUDIT #%d tex=%p impl=%p iosurface(arg=%p bound=%p) "
            "requested=%lux%lu pf=%lu plane(arg=%lu bound=%u) "
            "cpu130=%p gpu40=%#llx descriptorOff=%#tx address=%#llx "
            "descriptorLayout=%u compressed=%u extended=%u match=%d\n",
            n, (void *)tex, impl, (void *)surf, (void *)bound_surface,
            (unsigned long)requested_width, (unsigned long)requested_height,
            (unsigned long)requested_format, (unsigned long)requested_plane,
            bound_plane, cpu_mapping, (unsigned long long)gpu_mapping,
            has_descriptor ? descriptor.offset : (ptrdiff_t)-1,
            (unsigned long long)(has_descriptor ? descriptor.address : 0),
            has_descriptor ? descriptor.layout : 0,
            has_descriptor ? descriptor.compressed : 0,
            has_descriptor ? descriptor.extended : 0,
            bound_surface == surf);
        if (cpu_mapping == NULL) {
            dprintf(STDERR_FILENO,
                "#### AGX_MAP_AUDIT INVARIANT FAIL: real initializer left "
                "Texture+0x130 NULL; no field synthesis performed\n");
        }
        if (bound_surface != surf) {
            dprintf(STDERR_FILENO,
                "#### AGX_MAP_AUDIT INVARIANT FAIL: Texture+0xa0 does not "
                "match constructor IOSurfaceRef; no field synthesis performed\n");
        }
        if (bound_plane != requested_plane) {
            dprintf(STDERR_FILENO,
                "#### AGX_MAP_AUDIT INVARIANT FAIL: Texture+0xa8 plane=%u "
                "does not match constructor plane=%lu; no field synthesis "
                "performed\n",
                bound_plane, (unsigned long)requested_plane);
        }
    }
}

// Diagnostic-only native-AGX sampler control.  It runs after both plane views
// for one decoded surface have reached the render-encoder boundary, samples
// them through a minimal independent Metal pipeline, and writes GPU-produced
// RGBA8 bytes.  Correct output here isolates the remaining fault to ANGLE;
// incorrect output isolates it to AGX texture sampling or command submission.
static void macws_schedule_video_gpu_sample(id<MTLTexture> y_texture,
                                            id<MTLTexture> uv_texture,
                                            uint32_t surface_id) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.macwsguide.video-gpu-sample",
                                      DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        @autoreleasepool {
            id<MTLDevice> device = y_texture.device;
            NSUInteger width = y_texture.width;
            NSUInteger height = y_texture.height;
            NSError *error = nil;
            NSString *source =
                @"#include <metal_stdlib>\n"
                 "using namespace metal;\n"
                 "struct V { float4 position [[position]]; float2 uv; };\n"
                 "vertex V macws_nv12_v(uint n [[vertex_id]]) {\n"
                 "  const float2 p[3] = {float2(-1,-1), float2(3,-1), "
                 "float2(-1,3)};\n"
                 "  V o; o.position=float4(p[n],0,1); "
                 "o.uv=float2((p[n].x+1)*0.5,1-(p[n].y+1)*0.5); return o;\n"
                 "}\n"
                 "fragment float4 macws_nv12_f(V i [[stage_in]], "
                 "texture2d<float> yt [[texture(0)]], "
                 "texture2d<float> uvt [[texture(1)]]) {\n"
                 "  constexpr sampler s(coord::normalized, "
                 "address::clamp_to_edge, filter::nearest);\n"
                 "  float yc=yt.sample(s,i.uv).r; "
                 "float2 uvc=uvt.sample(s,i.uv).rg;\n"
                 "  float y=max(0.0,(yc-16.0/255.0)*(255.0/219.0)); "
                 "float u=(uvc.x-128.0/255.0)*(255.0/224.0); "
                 "float v=(uvc.y-128.0/255.0)*(255.0/224.0);\n"
                 "  float3 rgb=float3(y+1.5748*v, "
                 "y-0.1873*u-0.4681*v, y+1.8556*u);\n"
                 "  return float4(clamp(rgb,0.0,1.0),1.0);\n"
                 "}\n";
            id<MTLLibrary> library =
                [device newLibraryWithSource:source options:nil error:&error];
            if (!library) {
                dprintf(STDERR_FILENO,
                    "#### VIDEO-GPU-SAMPLE library failed surface=%u %s\n",
                    surface_id, error.description.UTF8String ?: "(nil)");
                goto done;
            }
            MTLRenderPipelineDescriptor *pipeline_descriptor =
                [[MTLRenderPipelineDescriptor alloc] init];
            pipeline_descriptor.vertexFunction =
                [library newFunctionWithName:@"macws_nv12_v"];
            pipeline_descriptor.fragmentFunction =
                [library newFunctionWithName:@"macws_nv12_f"];
            pipeline_descriptor.colorAttachments[0].pixelFormat =
                MTLPixelFormatRGBA8Unorm;
            id<MTLRenderPipelineState> pipeline =
                [device newRenderPipelineStateWithDescriptor:
                    pipeline_descriptor error:&error];
            if (!pipeline) {
                dprintf(STDERR_FILENO,
                    "#### VIDEO-GPU-SAMPLE pipeline failed surface=%u %s\n",
                    surface_id, error.description.UTF8String ?: "(nil)");
                [pipeline_descriptor release];
                goto done;
            }
            MTLTextureDescriptor *output_descriptor =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                    MTLPixelFormatRGBA8Unorm width:width height:height
                    mipmapped:NO];
            output_descriptor.storageMode = MTLStorageModeShared;
            output_descriptor.usage = MTLTextureUsageRenderTarget |
                MTLTextureUsageShaderRead;
            id<MTLTexture> iosurface_output =
                [device newTextureWithDescriptor:output_descriptor];
            id<MTLTexture> cpuclone_output =
                [device newTextureWithDescriptor:output_descriptor];

            // A/B control for the external-texture boundary.  Public
            // -getBytes: has already shown that the logical R8/RG8 texture
            // views contain the same bytes as their decoded IOSurface planes.
            // Re-upload those exact bytes into ordinary shared Metal textures,
            // then sample both pairs through the same pipeline and command
            // buffer.  This distinguishes an IOSurface GPU mapping/coherency
            // defect from shader compilation, color conversion, or the rest
            // of command submission without changing production rendering.
            NSUInteger y_width = y_texture.width;
            NSUInteger y_height = y_texture.height;
            NSUInteger uv_width = uv_texture.width;
            NSUInteger uv_height = uv_texture.height;
            size_t y_bytes_per_row = y_width;
            size_t uv_bytes_per_row = uv_width * 2;
            size_t y_length = y_bytes_per_row * y_height;
            size_t uv_length = uv_bytes_per_row * uv_height;
            void *y_bytes = malloc(y_length);
            void *uv_bytes = malloc(uv_length);
            MTLTextureDescriptor *y_clone_descriptor =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                    y_texture.pixelFormat width:y_width height:y_height
                    mipmapped:NO];
            y_clone_descriptor.storageMode = MTLStorageModeShared;
            y_clone_descriptor.usage = MTLTextureUsageShaderRead;
            MTLTextureDescriptor *uv_clone_descriptor =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                    uv_texture.pixelFormat width:uv_width height:uv_height
                    mipmapped:NO];
            uv_clone_descriptor.storageMode = MTLStorageModeShared;
            uv_clone_descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> y_clone =
                [device newTextureWithDescriptor:y_clone_descriptor];
            id<MTLTexture> uv_clone =
                [device newTextureWithDescriptor:uv_clone_descriptor];
            BOOL clone_ready = y_bytes && uv_bytes && y_clone && uv_clone;
            if (clone_ready) {
                [y_texture getBytes:y_bytes bytesPerRow:y_bytes_per_row
                      fromRegion:MTLRegionMake2D(0, 0, y_width, y_height)
                     mipmapLevel:0];
                [uv_texture getBytes:uv_bytes bytesPerRow:uv_bytes_per_row
                       fromRegion:MTLRegionMake2D(0, 0, uv_width, uv_height)
                      mipmapLevel:0];
                [y_clone replaceRegion:MTLRegionMake2D(
                            0, 0, y_width, y_height)
                              mipmapLevel:0 withBytes:y_bytes
                            bytesPerRow:y_bytes_per_row];
                [uv_clone replaceRegion:MTLRegionMake2D(
                             0, 0, uv_width, uv_height)
                               mipmapLevel:0 withBytes:uv_bytes
                             bytesPerRow:uv_bytes_per_row];
            }
            free(y_bytes);
            free(uv_bytes);
            id<MTLCommandQueue> command_queue = [device newCommandQueue];
            id<MTLCommandBuffer> command_buffer =
                [command_queue commandBuffer];
            void (^encode_sample)(id<MTLTexture>, id<MTLTexture>,
                                  id<MTLTexture>) =
                ^(id<MTLTexture> sample_y, id<MTLTexture> sample_uv,
                  id<MTLTexture> destination) {
                    MTLRenderPassDescriptor *pass =
                        [MTLRenderPassDescriptor renderPassDescriptor];
                    pass.colorAttachments[0].texture = destination;
                    pass.colorAttachments[0].loadAction =
                        MTLLoadActionDontCare;
                    pass.colorAttachments[0].storeAction =
                        MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> encoder =
                        [command_buffer
                            renderCommandEncoderWithDescriptor:pass];
                    [encoder setRenderPipelineState:pipeline];
                    [encoder setFragmentTexture:sample_y atIndex:0];
                    [encoder setFragmentTexture:sample_uv atIndex:1];
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0 vertexCount:3];
                    [encoder endEncoding];
                };
            encode_sample(y_texture, uv_texture, iosurface_output);
            if (clone_ready)
                encode_sample(y_clone, uv_clone, cpuclone_output);
            [command_buffer commit];
            [command_buffer waitUntilCompleted];
            if (command_buffer.status != MTLCommandBufferStatusCompleted) {
                dprintf(STDERR_FILENO,
                    "#### VIDEO-GPU-SAMPLE command failed surface=%u "
                    "status=%lu error=%s\n",
                    surface_id, (unsigned long)command_buffer.status,
                    command_buffer.error.description.UTF8String ?: "(nil)");
                [pipeline_descriptor release];
                goto done;
            }
            void (^dump_output)(id<MTLTexture>, const char *) =
                ^(id<MTLTexture> output, const char *variant) {
                    size_t bytes_per_row = width * 4;
                    size_t length = bytes_per_row * height;
                    void *rgba = malloc(length);
                    if (rgba) {
                        [output getBytes:rgba bytesPerRow:bytes_per_row
                              fromRegion:MTLRegionMake2D(
                                  0, 0, width, height)
                             mipmapLevel:0];
                    }
                    char output_path[PATH_MAX];
                    snprintf(output_path, sizeof(output_path),
                             "/tmp/macws_video_gpu_sample_%u_%s.rgba",
                             surface_id, variant);
                    int output_fd = rgba
                        ? open(output_path, O_WRONLY | O_CREAT | O_TRUNC |
                              O_CLOEXEC, 0600) : -1;
                    size_t written_total = 0;
                    while (output_fd >= 0 && written_total < length) {
                        ssize_t written = write(
                            output_fd,
                            (const uint8_t *)rgba + written_total,
                            length - written_total);
                        if (written <= 0) break;
                        written_total += (size_t)written;
                    }
                    if (output_fd >= 0) close(output_fd);
                    free(rgba);
                    dprintf(STDERR_FILENO,
                        "#### VIDEO-GPU-SAMPLE completed surface=%u "
                        "variant=%s shape=%lux%lu bytes=%zu written=%zu "
                        "path=%s\n",
                        surface_id, variant, (unsigned long)width,
                        (unsigned long)height, length, written_total,
                        output_path);
                };
            dump_output(iosurface_output, "iosurface");
            if (clone_ready)
                dump_output(cpuclone_output, "cpuclone");
            [pipeline_descriptor release];
        done:
            CFRelease((CFTypeRef)y_texture);
            CFRelease((CFTypeRef)uv_texture);
        }
    });
}

static void macws_collect_video_gpu_sample(id<MTLTexture> texture,
                                           uint32_t surface_id,
                                           uint32_t plane) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static uint32_t pending_surface_id = 0;
    static id<MTLTexture> pending_y = nil;
    static id<MTLTexture> pending_uv = nil;
    static _Atomic uint32_t scheduled = 0;
    if (atomic_load(&scheduled) || surface_id == 0 || plane > 1) return;
    pthread_mutex_lock(&lock);
    if (pending_surface_id != 0 && pending_surface_id != surface_id) {
        if (pending_y) CFRelease((CFTypeRef)pending_y);
        if (pending_uv) CFRelease((CFTypeRef)pending_uv);
        pending_y = nil;
        pending_uv = nil;
    }
    pending_surface_id = surface_id;
    id<MTLTexture> *slot = plane == 0 ? &pending_y : &pending_uv;
    if (!*slot) {
        *slot = texture;
        CFRetain((CFTypeRef)texture);
    }
    if (pending_y && pending_uv && !atomic_exchange(&scheduled, 1)) {
        id<MTLTexture> y = pending_y;
        id<MTLTexture> uv = pending_uv;
        pending_y = nil;
        pending_uv = nil;
        pthread_mutex_unlock(&lock);
        macws_schedule_video_gpu_sample(y, uv, surface_id);
        return;
    }
    pthread_mutex_unlock(&lock);
}

// Diagnostic-only witness at the final render-encoder binding boundary.  The
// IOSurface constructor trace proves what was requested; this records whether
// ANGLE/Skia later binds that same NV12 plane and hardware descriptor to the
// fragment slot.  It forwards the original setFragmentTexture arguments
// unchanged and never retains or mutates the texture.
static void macws_log_video_texture_binding(id encoder, id texture,
                                            NSUInteger index) {
    if (!macws_video_diag_enabled() || !texture) return;
    Class agx_texture_class = objc_getClass("AGXG13GFamilyTexture");
    if (!agx_texture_class || ![texture isKindOfClass:agx_texture_class]) return;

    NSUInteger width = 0, height = 0, pixel_format = 0;
    IOSurfaceRef surface = NULL;
    id parent = nil;
    @try {
        width = [texture respondsToSelector:@selector(width)]
            ? (NSUInteger)[texture width] : 0;
        height = [texture respondsToSelector:@selector(height)]
            ? (NSUInteger)[texture height] : 0;
        pixel_format = [texture respondsToSelector:@selector(pixelFormat)]
            ? (NSUInteger)[texture pixelFormat] : 0;
        if ([texture respondsToSelector:@selector(iosurface)])
            surface = (IOSurfaceRef)[texture iosurface];
        SEL parent_selector = sel_registerName("parentTexture");
        if ([texture respondsToSelector:parent_selector])
            parent = ((id (*)(id, SEL))objc_msgSend)(texture, parent_selector);
    } @catch (NSException *exception) {
        (void)exception;
    }
    uint32_t fourcc = surface ? IOSurfaceGetPixelFormat(surface) : 0;
    // R8/RG8 are common for masks, glyph atlases and other unrelated Skia
    // resources.  The backing IOSurface fourcc is the exact VideoToolbox NV12
    // provenance witness; filtering on pixel format alone exhausted the bounded
    // recorder before the first decoded frame reached ANGLE.
    if (fourcc != (uint32_t)'420v') return;

    // Focused one-surface capture used to locate the remaining video-colour
    // fault.  Dumping the decoder's two NV12 planes before ANGLE samples them
    // distinguishes damaged VideoToolbox/IOSurface contents from a later AGX
    // sampler or YUV-conversion failure.  This is intentionally sentinel-only,
    // bounded to one surface per process and read-only; production never locks
    // or copies video frames here.
    static _Atomic uint32_t dumped_surface_id = 0;
    uint32_t surface_id = IOSurfaceGetID(surface);
    uint32_t expected_surface_id = 0;
    if (surface_id != 0 && atomic_compare_exchange_strong(
            &dumped_surface_id, &expected_surface_id, surface_id)) {
        uint32_t seed = 0;
        int lock_result = IOSurfaceLock(surface, 1 /* read-only */, &seed);
        size_t plane_count = IOSurfaceGetPlaneCount(surface);
        dprintf(STDERR_FILENO,
            "#### VIDEO-NV12-DUMP surface=%u lock=%#x seed=%u planes=%zu "
            "alloc=%zu\n",
            surface_id, lock_result, seed, plane_count,
            IOSurfaceGetAllocSize(surface));
        if (lock_result == 0 && plane_count >= 2) {
            char metadata_path[PATH_MAX];
            snprintf(metadata_path, sizeof(metadata_path),
                     "/tmp/macws_video_nv12_%u.meta", surface_id);
            int metadata_fd = open(metadata_path,
                                   O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                                   0600);
            if (metadata_fd >= 0) {
                dprintf(metadata_fd,
                    "surface=%u fourcc=%08x alloc=%zu seed=%u\n",
                    surface_id, fourcc, IOSurfaceGetAllocSize(surface), seed);
            }
            for (size_t plane = 0; plane < 2; plane++) {
                void *base = macws_IOSurfaceGetBaseAddressOfPlane(
                    surface, plane);
                size_t width = macws_IOSurfaceGetWidthOfPlane(surface, plane);
                size_t height = macws_IOSurfaceGetHeightOfPlane(
                    surface, plane);
                size_t bytes_per_row =
                    macws_IOSurfaceGetBytesPerRowOfPlane(surface, plane);
                size_t length = 0;
                if (height != 0 && bytes_per_row <= SIZE_MAX / height)
                    length = bytes_per_row * height;
                if (metadata_fd >= 0) {
                    dprintf(metadata_fd,
                        "plane=%zu width=%zu height=%zu bytesPerRow=%zu "
                        "offset=%zu size=%zu base=%p\n",
                        plane, width, height, bytes_per_row,
                        macws_IOSurfaceGetOffsetOfPlane(surface, plane), length,
                        base);
                }
                char plane_path[PATH_MAX];
                snprintf(plane_path, sizeof(plane_path),
                         "/tmp/macws_video_nv12_%u_p%zu.raw",
                         surface_id, plane);
                int plane_fd = open(plane_path,
                                    O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                                    0600);
                size_t written_total = 0;
                while (plane_fd >= 0 && base && written_total < length) {
                    ssize_t written = write(
                        plane_fd, (const uint8_t *)base + written_total,
                        length - written_total);
                    if (written <= 0) break;
                    written_total += (size_t)written;
                }
                if (plane_fd >= 0) close(plane_fd);
                dprintf(STDERR_FILENO,
                    "#### VIDEO-NV12-DUMP plane=%zu shape=%zux%zu "
                    "bytesPerRow=%zu requested=%zu written=%zu path=%s\n",
                    plane, width, height, bytes_per_row, length,
                    written_total, plane_path);
            }
            if (metadata_fd >= 0) close(metadata_fd);
            IOSurfaceUnlock(surface, 1 /* read-only */, &seed);
        } else {
            if (lock_result == 0)
                IOSurfaceUnlock(surface, 1 /* read-only */, &seed);
            atomic_store(&dumped_surface_id, 0);
        }
    }

    ptrdiff_t impl_offset = 0x208;
    Ivar ivar = class_getInstanceVariable([texture class], "_impl");
    if (ivar) impl_offset = ivar_getOffset(ivar);
    void *impl = *(void **)((char *)(__bridge void *)texture + impl_offset);
    uint32_t bound_plane = impl
        ? *(volatile uint32_t *)((char *)impl + 0xa8) : UINT32_MAX;
    void *cpu_mapping = impl
        ? *(void * volatile *)((char *)impl + 0x130) : NULL;
    uint64_t gpu_mapping = impl
        ? *(volatile uint64_t *)((char *)impl + 0x40) : 0;
    macws_texture_descriptor_witness descriptor = {0};
    BOOL has_descriptor = impl && macws_find_texture_descriptor(
        impl, width, height, &descriptor);

    // Read the exact logical MTLTexture view once per plane as a second
    // boundary witness.  IOSurface raw bytes were runtime-confirmed correct;
    // if this public texture read differs, the defect is in resource import.
    // If it matches, the remaining fault is strictly after texture creation
    // (sampler/pipeline/command submission).  This call exists only under the
    // focused video sentinel and never substitutes bytes or a return value.
    if (surface_id == atomic_load(&dumped_surface_id) && bound_plane < 2) {
        static _Atomic uint32_t texture_dump_mask = 0;
        uint32_t bit = 1u << bound_plane;
        uint32_t previous = atomic_fetch_or(&texture_dump_mask, bit);
        if ((previous & bit) == 0) {
            size_t bytes_per_pixel = pixel_format == MTLPixelFormatR8Unorm
                ? 1 : (pixel_format == MTLPixelFormatRG8Unorm ? 2 : 0);
            size_t bytes_per_row = 0, length = 0;
            if (bytes_per_pixel != 0 && width <= SIZE_MAX / bytes_per_pixel) {
                bytes_per_row = width * bytes_per_pixel;
                if (height <= SIZE_MAX / bytes_per_row)
                    length = bytes_per_row * height;
            }
            void *copy = length ? malloc(length) : NULL;
            BOOL copied = NO;
            if (copy) {
                @try {
                    [texture getBytes:copy bytesPerRow:bytes_per_row
                        fromRegion:MTLRegionMake2D(0, 0, width, height)
                        mipmapLevel:0];
                    copied = YES;
                } @catch (NSException *exception) {
                    dprintf(STDERR_FILENO,
                        "#### VIDEO-TEXTURE-DUMP exception plane=%u %s\n",
                        bound_plane,
                        exception.description.UTF8String ?: "(nil)");
                }
            }
            char texture_path[PATH_MAX];
            snprintf(texture_path, sizeof(texture_path),
                     "/tmp/macws_video_texture_%u_p%u.raw",
                     surface_id, bound_plane);
            size_t written_total = 0;
            int texture_fd = copied
                ? open(texture_path,
                       O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600) : -1;
            while (texture_fd >= 0 && written_total < length) {
                ssize_t written = write(
                    texture_fd, (const uint8_t *)copy + written_total,
                    length - written_total);
                if (written <= 0) break;
                written_total += (size_t)written;
            }
            if (texture_fd >= 0) close(texture_fd);
            free(copy);
            dprintf(STDERR_FILENO,
                "#### VIDEO-TEXTURE-DUMP surface=%u plane=%u shape=%lux%lu "
                "pixelFormat=%lu bytesPerRow=%zu requested=%zu written=%zu "
                "path=%s\n",
                surface_id, bound_plane, (unsigned long)width,
                (unsigned long)height, (unsigned long)pixel_format,
                bytes_per_row, length, written_total, texture_path);
        }
        macws_collect_video_gpu_sample(texture, surface_id, bound_plane);
    }
    char descriptor_hex[49] = {0};
    if (has_descriptor) {
        for (size_t i = 0; i < sizeof(descriptor.bytes); i++)
            snprintf(descriptor_hex + i * 2, 3, "%02x", descriptor.bytes[i]);
    }
    static _Atomic uint32_t binding_count = 0;
    uint32_t sequence = atomic_fetch_add(&binding_count, 1) + 1;
    if (sequence > 256) return;
    dprintf(STDERR_FILENO,
        "#### VIDEO-TEX-BIND #%u encoder=%p index=%lu tex=%p class=%s "
        "parent=%p surface=%u fourcc=%#x shape=%lux%lu pf=%lu "
        "impl=%p plane=%u cpu130=%p gpu40=%#llx descriptorOff=%#tx "
        "address=%#llx layout=%u compressed=%u extended=%u bytes=%s\n",
        sequence, (void *)encoder, (unsigned long)index, (void *)texture,
        class_getName([texture class]), (void *)parent,
        surface ? IOSurfaceGetID(surface) : 0, fourcc,
        (unsigned long)width, (unsigned long)height,
        (unsigned long)pixel_format, impl, bound_plane, cpu_mapping,
        (unsigned long long)gpu_mapping,
        has_descriptor ? descriptor.offset : (ptrdiff_t)-1,
        (unsigned long long)(has_descriptor ? descriptor.address : 0),
        has_descriptor ? descriptor.layout : 0,
        has_descriptor ? descriptor.compressed : 0,
        has_descriptor ? descriptor.extended : 0,
        has_descriptor ? descriptor_hex : "(not-found)");
}

// One-shot, read-only witness for the hardware Texture descriptor produced by
// Apple's real initializer.  Either texture diagnostic sentinel gates the
// controlled native-AGX test, so this cannot add per-frame production log
// traffic.  No descriptor field is modified here.  The runtime type encoding
// is recorded with the IMP so later argument tracing does not guess a private
// Objective-C ABI.
static void macws_diag_pf550_texture_descriptor(id<MTLTexture> tex,
                                                MTLTextureDescriptor *desc,
                                                IOSurfaceRef surf,
                                                id device) {
    if (!tex || !desc || !surf || !device ||
        desc.pixelFormat != (MTLPixelFormat)550 ||
        (!macws_res_diag_enabled() &&
         access("/private/tmp/macws_tile_descriptor_diag", F_OK) != 0)) {
        return;
    }
    static _Atomic int dumped = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&dumped, &expected, 1)) return;

    ptrdiff_t impl_offset = 0x208;
    Ivar iv = class_getInstanceVariable([tex class], "_impl");
    if (iv) impl_offset = ivar_getOffset(iv);
    void *impl = *(void **)((char *)(__bridge void *)tex + impl_offset);
    if (!impl) {
        fprintf(stderr,
            "#### AGX_TEX_DESC pf550 impl=NULL tex=%p implOff=%#tx\n",
            (void *)tex, impl_offset);
        return;
    }

    macws_texture_descriptor_witness descriptor = {0};
    if (!macws_find_texture_descriptor(impl, desc.width, desc.height,
                                       &descriptor)) {
        fprintf(stderr,
            "#### AGX_TEX_DESC pf550 NOT-FOUND tex=%p impl=%p "
            "implOff=%#tx scan=[0x140,0x240]\n",
            (void *)tex, impl, impl_offset);
        return;
    }
    char hex[sizeof(descriptor.bytes) * 2 + 1];
    for (size_t i = 0; i < sizeof(descriptor.bytes); i++) {
        snprintf(hex + i * 2, 3, "%02x", descriptor.bytes[i]);
    }
    fprintf(stderr,
        "#### AGX_TEX_DESC pf550 tex=%p impl=%p implOff=%#tx descOff=%#tx "
        "gpu40=%#llx layout=%u compressed=%u extended=%u "
        "address=%#llx extendedLow36=%#llx "
        "extendedRaw=%#llx bytes=%s\n",
        (void *)tex, impl, impl_offset, descriptor.offset,
        (unsigned long long)*(volatile uint64_t *)((char *)impl + 0x40),
        descriptor.layout, descriptor.compressed, descriptor.extended,
        (unsigned long long)descriptor.address,
        (unsigned long long)descriptor.extended_low36,
        (unsigned long long)descriptor.extended_raw, hex);

    // Runtime-to-static anchors for the exact macOS 13.4 AGX image.  dladdr
    // establishes the loaded image base; subtracting it and adding the
    // text-cache __TEXT base makes the ensuing capstone disassembly
    // reproducible without depending on one process's ASLR slide.
    struct {
        id receiver;
        const char *selector;
    } methods[] = {
        { device, "initNewTextureData:" },
        { tex, "updateBindDataWithAddresses:cpuMetadataAddress:gpuVirtualAddress:isCompressible:shouldInitMetadata:" },
        { tex, "updateBindDataWithAddresses:gpuVirtualAddress:" },
        { tex, "updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:" },
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        Class cls = [methods[i].receiver class];
        SEL sel = sel_registerName(methods[i].selector);
        Method method = class_getInstanceMethod(cls, sel);
        IMP imp = method ? method_getImplementation(method) : NULL;
        const char *types = method ? method_getTypeEncoding(method) : NULL;
        Dl_info image = {0};
        bool located = imp && dladdr((const void *)imp, &image) != 0;
        uintptr_t static_address = located
            ? (uintptr_t)imp - (uintptr_t)image.dli_fbase + 0x1e53dd000ULL
            : 0;
        fprintf(stderr,
            "#### AGX_TEX_METHOD class=%s selector=%s imp=%p imageBase=%p "
            "static=%#llx types=%s image=%s\n",
            class_getName(cls), methods[i].selector, (void *)imp,
            located ? image.dli_fbase : NULL,
            (unsigned long long)static_address,
            types ? types : "(missing)",
            located && image.dli_fname ? image.dli_fname : "(unresolved)");
    }
}

// Process-wide stash of the current IOSurfaceID being wrapped as a texture.
// Was per-thread but the texture init dispatches the kernel call onto a
// worker thread that __thread doesn't reach. Set by
// `hooked_newTextureWithDescriptor:iosurface:plane:` before %orig is
// invoked, cleared after. Read by IOConnectCallMethod_new in mac_hooks.m
// to inject args[+0x30] = IOSurfaceID for sel=0xa type=0x82 — the iOS
// kernel AGX dispatcher requires this for IOSurface-backed textures.
//
// The three values form one semantic tuple.  The underlying initializer may
// issue its IOKit call from a worker thread, so thread-local storage cannot
// carry the tuple.  Serialize the complete wrapper scope with a recursive
// mutex instead: worker threads can read the atomics without taking the lock,
// concurrent texture imports cannot overwrite the tuple, and the owned-
// scanout fallback may re-enter this method on the same caller thread.
static _Atomic uint32_t s_current_iosurface_id = 0;
static _Atomic uint32_t s_current_iosurface_plane = 0;
static _Atomic uint64_t s_current_iosurface_compression_header_span = 0;
static pthread_mutex_t s_current_iosurface_scope_lock;
static dispatch_once_t s_current_iosurface_scope_lock_once;

static void macws_lock_current_iosurface_scope(void) {
    dispatch_once(&s_current_iosurface_scope_lock_once, ^{
        pthread_mutexattr_t attributes;
        pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&s_current_iosurface_scope_lock, &attributes);
        pthread_mutexattr_destroy(&attributes);
    });
    pthread_mutex_lock(&s_current_iosurface_scope_lock);
}

static void macws_unlock_current_iosurface_scope(void) {
    pthread_mutex_unlock(&s_current_iosurface_scope_lock);
}

__attribute__((visibility("default")))
uint32_t macws_get_current_iosurface_id(void) {
    return s_current_iosurface_id;
}

__attribute__((visibility("default")))
void macws_set_current_iosurface_id(uint32_t id) {
    s_current_iosurface_id = id;
}

__attribute__((visibility("default")))
uint32_t macws_get_current_iosurface_plane(void) {
    return s_current_iosurface_plane;
}

__attribute__((visibility("default")))
void macws_set_current_iosurface_plane(uint32_t plane) {
    s_current_iosurface_plane = plane;
}

__attribute__((visibility("default")))
uint64_t macws_get_current_iosurface_compression_header_span(void) {
    return s_current_iosurface_compression_header_span;
}

__attribute__((visibility("default")))
void macws_set_current_iosurface_compression_header_span(uint64_t span) {
    s_current_iosurface_compression_header_span = span;
}

// iOS 16.3 AGX `-[AGXG13GFamilyDevice initNewTextureData:]` writes
// args+0x58 as align_up(compressionMetadata+0x160, textureData+0x138).
// For IOSurface-backed compressed planes, the observable equivalent is the
// reserved header tail of that plane: (plane Offset + Size) minus
// CompressedTileHeaderRegionOffset.  The iPad CA Framebuffer reports
// 0x40000 for both planes, exactly matching native iOS's args+0x58.
//
// Keep this property-driven: private display formats may use a different
// header reservation, and a hard-coded 0x40000 would merely hide the ABI
// mismatch for this one surface geometry.
static uint64_t macws_iosurface_compression_header_span(
    IOSurfaceRef surface, NSUInteger plane) {
    if (!surface) return 0;
    uint64_t span = 0;
    CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
    if (!copied) return 0;
    @try {
        NSDictionary *root = (__bridge NSDictionary *)copied;
        id creationValue = root[@"CreationProperties"];
        NSDictionary *creation =
            [creationValue isKindOfClass:[NSDictionary class]]
                ? (NSDictionary *)creationValue : root;
        id planeInfoValue = creation[@"IOSurfacePlaneInfo"];
        if ([planeInfoValue isKindOfClass:[NSArray class]]) {
            NSArray *planeInfo = (NSArray *)planeInfoValue;
            if (plane < [planeInfo count]) {
                id planeValue = planeInfo[plane];
                if ([planeValue isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *info = (NSDictionary *)planeValue;
                    uint64_t compressionType =
                        [(info[@"CompressionType"] ?:
                           info[@"IOSurfacePlaneCompressionType"])
                            unsignedLongLongValue];
                    uint64_t offset =
                        [(info[@"Offset"] ?: info[@"IOSurfacePlaneOffset"])
                            unsignedLongLongValue];
                    uint64_t size =
                        [(info[@"Size"] ?: info[@"IOSurfacePlaneSize"])
                            unsignedLongLongValue];
                    uint64_t headerOffset =
                        [(info[@"CompressedTileHeaderRegionOffset"] ?:
                           info[@"IOSurfacePlaneCompressedTileHeaderRegionOffset"])
                            unsignedLongLongValue];
                    uint64_t end = offset + size;
                    if (compressionType != 0 && end >= offset &&
                        headerOffset >= offset && headerOffset < end) {
                        span = end - headerOffset;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        fprintf(stderr,
            "#### MTL_TEX compression metadata parse exception: %s\n",
            [[exception description] UTF8String] ?: "?");
        span = 0;
    }
    CFRelease(copied);
    return span;
}

// FORCE_M1_DRIVER auto-enabled for the arm64e on-device slice only (see
// mac_hooks.m). arm64e -> real macOS AGX driver; arm64/x86_64 -> MTLSimDevice.
#if defined(__arm64e__) && defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    if(class_getInstanceMethod(class, originalAction) == NULL) {
        class_addMethod(class, originalAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
        method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
    }
}

@interface _MTLDevice : NSObject
- (uint32_t)acceleratorPort;
@end

// ─── Tile-pipeline → render-pipeline substitution ────────────────────────────
// (definition moved into the MTLFakeDevice category below as
// `hooked_newRenderPipelineStateWithTileDescriptor:...`, then runtime-swizzled
// onto MTLSimDevice in initHooks. Logos `%hook MTLSimDevice` doesn't apply
// here because MTLSimDevice has no compile-time interface declaration.)

// MTLSimRenderCommandEncoder forwarding helpers — BlurState issues
// setTileTexture:atIndex:, setTileBuffer:offset:atIndex:,
// setTileBytes:length:atIndex: on the regular render encoder (since the
// substitute pipeline isn't actually a tile pipeline, but BlurState doesn't
// know). Redirect each tile-* selector to its fragment-* equivalent.
// MACWS_BLUR_TRACE=1 dumps every tile-encoder selector forward with the
// actual arguments so we can reconstruct what BlurState is staging into the
// (substitute) fragment slots and align the shader IO accordingly.
static int macws_blur_trace(void) {
    static int v = -1;
    if (v < 0) v = getenv("MACWS_BLUR_TRACE") ? 1 : 0;
    return v;
}
// Associated-object keys for caching the source / destination textures
// captured on the render encoder so dispatchThreadsPerTile can hand them to
// the XPC blur forward.
static const void *MACWS_SRC_TEX_KEY = &MACWS_SRC_TEX_KEY;
static const void *MACWS_DST_TEX_KEY = &MACWS_DST_TEX_KEY;

static void macws_setTileTexture_impl(id self, SEL _cmd, id tex, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger w = 0, h = 0;
        @try { if (tex) { label = [[tex label] UTF8String] ?: "(nolabel)";
                          w = (NSUInteger)[tex width]; h = (NSUInteger)[tex height]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileTexture[%lu] = %p label=%s %lux%lu\n",
                (unsigned long)idx, (void *)tex, label, (unsigned long)w, (unsigned long)h);
    }
    // Cache source texture on the encoder so the dispatchThreadsPerTile→XPC
    // path can recover it.
    if (idx == 0 && tex) {
        objc_setAssociatedObject(self, MACWS_SRC_TEX_KEY, tex, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentTexture:atIndex:"), tex, idx);
}
static void macws_setTileBuffer_impl(id self, SEL _cmd, id buf, NSUInteger off, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger len = 0;
        @try { if (buf) { label = [[buf label] UTF8String] ?: "(nolabel)";
                          len = (NSUInteger)[buf length]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileBuffer[%lu] = %p label=%s len=%lu off=%lu\n",
                (unsigned long)idx, (void *)buf, label, (unsigned long)len, (unsigned long)off);
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBuffer:offset:atIndex:"), buf, off, idx);
}
static void macws_setTileBytes_impl(id self, SEL _cmd, const void *bytes, NSUInteger len, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileBytes[%lu] len=%lu", (unsigned long)idx, (unsigned long)len);
        const uint8_t *p = (const uint8_t *)bytes;
        size_t dump = len < 64 ? len : 64;
        fprintf(stderr, "  bytes=");
        for (size_t i = 0; i < dump; i++) fprintf(stderr, "%02x", p[i]);
        // Also interpret first 32 bytes as 8 floats (typical uniform layout).
        if (len >= 32) {
            const float *f = (const float *)bytes;
            fprintf(stderr, "\n####   floats=[%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]);
        }
        fprintf(stderr, "\n");
    }
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBytes:length:atIndex:"), bytes, len, idx);
}
static void macws_setTileSamplerState_impl(id self, SEL _cmd, id sampler, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileSampler[%lu] = %p\n", (unsigned long)idx, (void *)sampler);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentSamplerState:atIndex:"), sampler, idx);
}
// dispatchThreadsPerTile: dispatches the tile shader once per tile in the
// render target. For a regular render encoder we substitute a fullscreen
// triangle draw (3 vertices, MTLPrimitiveTypeTriangle) — the
// downsample_blur_vert_lpf passthrough writes positions covering NDC.
// 3-vertex fullscreen triangle layout (vertex shader fallback when XPC
// blur forward isn't available).
typedef struct {
    float pos[4];
    float tex[4];
    float col[4];
} macws_fs_vtx_t;
static const macws_fs_vtx_t macws_fs_triangle[3] = {
    {{-1.0f, -1.0f, 0.0f, 1.0f}, {0.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{ 3.0f, -1.0f, 0.0f, 1.0f}, {2.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{-1.0f,  3.0f, 0.0f, 1.0f}, {0.0f,-1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
};

// XPC blur forward to MTLSimDriverHost (iOS Metal + MPSImageGaussianBlur).
// Cached connection so we don't reconnect every frame.
static xpc_connection_t gBlurXpc = NULL;
static xpc_connection_t macws_blur_xpc(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            fprintf(stderr, "#### blur-xpc: createMach symbol missing\n");
            return;
        }
        gBlurXpc = createMach("com.macwsguide.blur", NULL, 0);
        if (!gBlurXpc) {
            fprintf(stderr, "#### blur-xpc: createMach returned NULL\n");
            return;
        }
        xpc_connection_set_event_handler(gBlurXpc, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(gBlurXpc);
        fprintf(stderr, "#### blur-xpc: opened connection to com.macwsguide.blur\n");
    });
    return gBlurXpc;
}

// Send the source+dest IOSurfaces over to the host, wait synchronously, and
// return YES on a successful blur. The caller then skips drawPrimitives so
// the existing render encoder doesn't overwrite the host's MPS output.
static BOOL macws_blur_forward(IOSurfaceRef src, IOSurfaceRef dst, double sigma) {
    xpc_connection_t conn = macws_blur_xpc();
    if (!conn || !src || !dst) return NO;
    mach_port_t srcPort = IOSurfaceCreateMachPort(src);
    mach_port_t dstPort = IOSurfaceCreateMachPort(dst);
    if (srcPort == MACH_PORT_NULL || dstPort == MACH_PORT_NULL) {
        if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
        if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
        return NO;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "blur");
    xpc_dictionary_set_mach_send(req, "source_port", srcPort);
    xpc_dictionary_set_mach_send(req, "dest_port", dstPort);
    xpc_dictionary_set_double(req, "radius", sigma);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    BOOL ok = NO;
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        const char *r = xpc_dictionary_get_string(reply, "result");
        ok = r && strcmp(r, "ok") == 0;
        if (macws_blur_trace()) {
            fprintf(stderr, "#### blur-xpc reply: %s\n", r ?: "(no result)");
        }
    } else if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-xpc no reply\n");
    }
    if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
    if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
    return ok;
}

static void macws_dispatchThreadsPerTile_impl(id self, SEL _cmd, void *sizeArg) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace dispatchThreadsPerTile\n");
    }

    // Try the XPC forward: pick up the source (cached in setTileTexture[0])
    // and destination (cached in newRenderCommandEncoderWithDescriptor hook).
    // MACWS_BLUR_XPC=1 enables — default off so the synchronous reply wait
    // can't hang WS if MTLSimDriverHost doesn't publish the listener.
    id<MTLTexture> srcTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_SRC_TEX_KEY) : nil;
    id<MTLTexture> dstTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_DST_TEX_KEY) : nil;
    if (srcTex && dstTex) {
        IOSurfaceRef srcSurf = NULL, dstSurf = NULL;
        @try { srcSurf = [srcTex iosurface]; } @catch (NSException *e) {}
        @try { dstSurf = [dstTex iosurface]; } @catch (NSException *e) {}
        if (srcSurf && dstSurf) {
            // sigma from setTileBytes[0] is BlurState's tap-count/level — we
            // map that to a fixed sigma for now (8 for the menu-bar feel).
            BOOL ok = macws_blur_forward(srcSurf, dstSurf, 8.0);
            if (ok) {
                if (macws_blur_trace()) {
                    fprintf(stderr, "#### blur-xpc: forward OK — skipping drawPrimitives\n");
                }
                // Host already wrote the destination IOSurface; don't run
                // the local substitute draw which would overwrite it.
                return;
            }
        }
    }

    // Fallback: substitute non-tile draw with QC blur shaders.
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setVertexBytes:length:atIndex:"),
        (const void *)macws_fs_triangle,
        (NSUInteger)sizeof(macws_fs_triangle),
        (NSUInteger)30);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
        (NSUInteger)3, (NSUInteger)0, (NSUInteger)3);
}
// setThreadgroupMemoryLength:offset:atIndex: is a tile-encoder API for
// declaring tile-local shared memory. Regular encoders don't need it.
static void macws_setThreadgroupMemoryLength_impl(id self, SEL _cmd, NSUInteger len, NSUInteger off, NSUInteger idx) {
    (void)self; (void)len; (void)off; (void)idx;
    // no-op for non-tile encoder
}
// Swizzle target on MTLSimCommandBuffer: captures the render-pass
// descriptor's color attachment[0] texture and associates it with the
// returned encoder so dispatchThreadsPerTile→XPC can read it back.
static id (*orig_renderCommandEncoderWithDescriptor)(id, SEL, id) = NULL;
static id macws_renderCommandEncoder_capture(id self, SEL _cmd, id passDesc) {
    id encoder = orig_renderCommandEncoderWithDescriptor(self, _cmd, passDesc);
    if (encoder && passDesc) {
        @try {
            id colorAtts = [passDesc valueForKey:@"colorAttachments"];
            id att0 = [colorAtts objectAtIndexedSubscript:0];
            id<MTLTexture> dst = [att0 valueForKey:@"texture"];
            if (dst) {
                objc_setAssociatedObject(encoder, MACWS_DST_TEX_KEY, dst, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (macws_blur_trace()) {
                    NSUInteger w = (NSUInteger)[dst width], h = (NSUInteger)[dst height];
                    const char *lab = [[dst label] UTF8String] ?: "(nolabel)";
                    fprintf(stderr, "#### blur-trace renderCommandEncoder colorAtt[0] = %p label=%s %lux%lu\n",
                            (void *)dst, lab, (unsigned long)w, (unsigned long)h);
                }
            }
        } @catch (NSException *e) {}
    }
    return encoder;
}

__attribute__((constructor)) static void macws_install_tile_encoder_forwards(void) {
    // Defer until MTLSimRenderCommandEncoder class is loaded.
    dispatch_async(dispatch_get_main_queue(), ^{
        Class enc = objc_getClass("MTLSimRenderCommandEncoder");
        if (!enc) {
            fprintf(stderr, "#### tile-encoder forwards: class MTLSimRenderCommandEncoder NOT found\n");
            return;
        }
        class_addMethod(enc, sel_registerName("setTileTexture:atIndex:"),
                        (IMP)macws_setTileTexture_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("setTileBuffer:offset:atIndex:"),
                        (IMP)macws_setTileBuffer_impl, "v@:@QQ");
        class_addMethod(enc, sel_registerName("setTileBytes:length:atIndex:"),
                        (IMP)macws_setTileBytes_impl, "v@:^vQQ");
        class_addMethod(enc, sel_registerName("setTileSamplerState:atIndex:"),
                        (IMP)macws_setTileSamplerState_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("dispatchThreadsPerTile:"),
                        (IMP)macws_dispatchThreadsPerTile_impl, "v@:^v");
        class_addMethod(enc, sel_registerName("setThreadgroupMemoryLength:offset:atIndex:"),
                        (IMP)macws_setThreadgroupMemoryLength_impl, "v@:QQQ");
        fprintf(stderr, "#### tile-encoder forwards installed on MTLSimRenderCommandEncoder\n");
        fflush(stderr);
        fprintf(stderr, "#### BLUR-DEBUG: about to look for MTLSim command buffer class\n");
        fflush(stderr);

        // Swizzle the MTLSim command-buffer class's
        // renderCommandEncoderWithDescriptor: to capture the render pass's
        // color attachment[0] texture (= the blur destination) so the XPC
        // forward can pass it across. Class name varies across MTLSimDriver
        // builds — try several candidates.
        const char *cb_names[] = {
            "MTLSimCommandBuffer",
            "MTLSimMainCommandBuffer",
            "MTLSimSecondaryCommandBuffer",
            "MTLSimulatorCommandBuffer",
            "MTLToolsCommandBuffer",
            "MTLDebugCommandBuffer",
            "MTLIGAccelCommandBuffer",
            NULL
        };
        Class cb = nil;
        for (int i = 0; cb_names[i]; i++) {
            Class c = objc_getClass(cb_names[i]);
            if (c) {
                cb = c;
                fprintf(stderr, "#### blur: found command-buffer class %s\n", cb_names[i]);
                break;
            }
        }
        if (!cb) {
            // Fall back: enumerate ALL classes, find any whose name has
            // "CommandBuffer" and "Sim" or implements renderCommandEncoder.
            unsigned int n = 0;
            Class *all = objc_copyClassList(&n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = class_getName(all[i]);
                if (!nm) continue;
                if (strstr(nm, "CommandBuffer") && (strstr(nm, "Sim") || strstr(nm, "MTL"))) {
                    Method mm = class_getInstanceMethod(all[i],
                        sel_registerName("renderCommandEncoderWithDescriptor:"));
                    if (mm) {
                        cb = all[i];
                        fprintf(stderr, "#### blur: located command-buffer class %s by scan\n", nm);
                        break;
                    }
                }
            }
            if (all) free(all);
        }
        if (cb) {
            SEL sel = sel_registerName("renderCommandEncoderWithDescriptor:");
            Method m = class_getInstanceMethod(cb, sel);
            if (m) {
                orig_renderCommandEncoderWithDescriptor =
                    (id (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)macws_renderCommandEncoder_capture);
                fprintf(stderr, "#### %s.renderCommandEncoderWithDescriptor swizzled\n",
                        class_getName(cb));
            } else {
                fprintf(stderr, "#### blur: cmd-buffer class %s has NO renderCommandEncoderWithDescriptor\n",
                        class_getName(cb));
            }
        } else {
            fprintf(stderr, "#### blur: no MTLSim command-buffer class found\n");
        }
    });
}

@implementation _MTLDevice(MetalXPC)
- (void)_setAcceleratorService:(id)arg1 {}

- (uint32_t)peerGroupID {
    return self.acceleratorPort;
}
@end

// MTLFakeDevice creates a new ObjC class.  On arm64e, on-device lld emits a
// plain (non-auth) chained-fixup rebase for class_t->data, but macOS libobjc
// expects an address-diversified autda pointer → EXC_BREAKPOINT (PAC trap DA)
// in readClass during map_images.  Exclude the entire class from arm64e so the
// arm64e slice has no class_t entries, letting the arm64 slice handle Metal.
// On-device builds (misc/build_on_ios.sh) pass -DLIBMACHOOK_ON_DEVICE_BUILD: lld
// uses -fixup_chains there, so arm64e can include this code.
#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
static id(*MTLCreateSimulatorDevice)(void);
@interface MTLFakeDevice : _MTLDevice
@end
@implementation MTLFakeDevice
- (BOOL)initHooks {
    if(%c(MTLSimDevice)) {
        return YES; // Already hooked
    }
    
    void *handle = dlopen("@loader_path/../Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MetalSerializer framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MetalSerializer successfully!");
    }
    
    handle = dlopen("@loader_path/../Frameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MTLSimDriver framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLSimDriver successfully!");
    }
    MTLCreateSimulatorDevice = dlsym(handle, "MTLCreateSimulatorDevice");
    NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    
    Class MTLSimDeviceClass = %c(MTLSimDevice);
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithLength:options:pointer:copyBytes:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(acceleratorPort), MTLFakeDevice.class, @selector(hooked_acceleratorPort));
    swizzle2(MTLSimDeviceClass, @selector(location), MTLFakeDevice.class, @selector(hooked_location));
    swizzle2(MTLSimDeviceClass, @selector(locationNumber), MTLFakeDevice.class, @selector(hooked_locationNumber));
    swizzle2(MTLSimDeviceClass, @selector(maxTransferRate), MTLFakeDevice.class, @selector(hooked_maxTransferRate));
    // MACWS_TEX_TRACE=1 enables full IOSurface→Metal texture descriptor logging.
    // Always-installed because the cold/abort path of MTLSimDriver's
    // sendXPCMessageWithReplySync hits abort() with no recovery — we MUST see
    // every descriptor right before the failure to know what to translate.
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:iosurface:plane:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
    // Tile-pipeline → render-pipeline substitution: MTLSimDevice's tile-
    // pipeline impl MTLReportFailure-aborts WS. Swizzle to our converter.
    swizzle2(MTLSimDeviceClass,
             @selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:),
             MTLFakeDevice.class,
             @selector(hooked_newRenderPipelineStateWithTileDescriptor:options:reflection:error:));
    fprintf(stderr, "#### MTLSimDevice tile-pipeline → MTLFakeDevice converter swizzled\n");

    // MTLSimDevice has SUBCLASSES (MTLSimGPU13MDevice, MTLSimGPU11Device, ...).
    // If the runtime class is a subclass that overrides our hooked selectors, the
    // base-class swizzle is shadowed and our hook never runs. Enumerate all
    // subclasses and apply the same swizzle to each one that has its own IMP.
    unsigned int numClasses = 0;
    Class *allClasses = objc_copyClassList(&numClasses);
    int subclassPatched = 0;
    for (unsigned int i = 0; i < numClasses; i++) {
        Class c = allClasses[i];
        // Walk superclasses to find MTLSimDevice ancestry
        Class p = c;
        while (p && p != MTLSimDeviceClass) {
            p = class_getSuperclass(p);
        }
        if (p != MTLSimDeviceClass || c == MTLSimDeviceClass) continue;
        // Only swizzle if THIS class itself implements the selector (not inherited)
        unsigned int nm = 0;
        Method *methods = class_copyMethodList(c, &nm);
        BOOL has_iosurf = NO;
        BOOL has_plain  = NO;
        SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
        SEL plain_sel  = @selector(newTextureWithDescriptor:);
        for (unsigned int j = 0; j < nm; j++) {
            SEL s = method_getName(methods[j]);
            if (s == iosurf_sel) has_iosurf = YES;
            if (s == plain_sel)  has_plain  = YES;
        }
        if (methods) free(methods);
        if (has_iosurf) {
            swizzle2(c, iosurf_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
            subclassPatched++;
        }
        if (has_plain) {
            swizzle2(c, plain_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
            subclassPatched++;
        }
        fprintf(stderr, "#### MTL_TEX subclass %s iosurf=%d plain=%d\n",
            class_getName(c), has_iosurf, has_plain);
    }
    if (allClasses) free(allClasses);
    fprintf(stderr, "#### MTL_TEX swizzled MTLSimDevice + %d subclass overrides\n", subclassPatched);
    NSLog(@"#### debugbydcmmc load swizzle2 successfully!");
    
    uint32_t *imp;
    // This check isn't present in iOS 14 simulator, maybe it was added in iOS 15?
    // Patch -[MTLSimTexture initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:] to bypass `IOSurface backed XR10 textures are not supported in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimTexture), @selector(initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0xfb7c] <+144>: bl     0x2e660        ; objc_msgSend$pixelFormat
        // -> MTLSimDriver[0xfb80] <+148>: and    x8, x0, #0xfffffffffffffffc
        // -> MTLSimDriver[0xfb84] <+152>: cmp    x8, #0x228
        // -> MTLSimDriver[0xfb88] <+156>: b.eq   0xfdf8         ; <+780>
        if(imp[i] == 0x927ef408 && imp[i+1] == 0xf108a11f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t[3]), ^{
                imp[i+1] = imp[i+2] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    // Patch -[MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:] to bypass `Linear texture can only be created on buffers with MTLStorageModePrivate in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimBuffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0x85bc] <+84>:  bl     0x2eda0        ; objc_msgSend$storageMode
        // -> MTLSimDriver[0x85c0] <+88>:  cmp    x0, #0x2
        //    MTLSimDriver[0x85c4] <+92>:  b.ne   0x8798         ; <+560>
        if(imp[i] == 0xf100081f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t), ^{
                imp[i] = imp[i+1] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    return YES;
}

- (id)initWithAcceleratorPort:(int)port {
    if(![self initHooks]) {
        return nil;
    }
    if(!MTLCreateSimulatorDevice) {
        NSLog(@"#### debugbydcmmc Failed to find MTLCreateSimulatorDevice: %s", dlerror());
        return nil;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    }
    // Class cls = NSClassFromString(@"MTLSimDevice");
    // NSLog(@"#### debugbydcmmc MTLSimDevice class %@", cls ? @"present" : @"missing");
    self = MTLCreateSimulatorDevice();
    // NSLog(@"#### debugbydcmmc MTLCreateSimulatorDevice done");
    // CRITICAL: use OBJC_ASSOCIATION_RETAIN (not ASSIGN). With ASSIGN the
    // autoreleased @(port) NSNumber is deallocated after the autorelease pool
    // drains, leaving a dangling pointer. -[hooked_acceleratorPort] then reads
    // garbage, WS thinks the GPU port is invalid → falls back to software
    // rendering, the SW renderer creates an IOSurface with FourCC '&b38'
    // (0x26623338) that MTLSim cannot wrap, and WS crash-loops in
    // WSCompositeDestinationCreateWithMetalTexture. Same root cause as the
    // upstream README "Unimplemented pixel format of 645346401" bug.
    objc_setAssociatedObject(self, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_RETAIN);
    fprintf(stderr, "#### MTLFakeDevice initWithAcceleratorPort:%d retained\n", port);
    return self;
}

- (uint32_t)hooked_acceleratorPort {
    NSNumber *n = (NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort));
    uint32_t port = n ? [n unsignedIntValue] : 0;
    static int trace_count = 0;
    if (trace_count < 10) {
        fprintf(stderr, "#### MTLFakeDevice acceleratorPort -> %u (NSNumber=%p)\n", port, n);
        trace_count++;
    }
    return port;
}

- (NSUInteger)hooked_location {
    return 0; // MTLDeviceLocationBuiltIn
}

- (NSUInteger)hooked_locationNumber {
    return 0;
}

- (NSUInteger)hooked_maxTransferRate {
    return 0; // The maximum transfer rate for built-in GPUs is 0.
}

- (id<MTLBuffer>)hooked_newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void * pointer, NSUInteger length)) deallocator {
    // NSLog(@"#### debugbydcmmc hooked_newBufferWithBytesNoCopy start");
    if(malloc_size(bytes) > 0) {
        // XPC doesn't like malloced buffers since they don't have MAP_SHARED flag, so we mirror it to a shared region here
        vm_address_t mirrored = 0;
        vm_prot_t cur_prot, max_prot;
        kern_return_t ret = vm_remap(mach_task_self(), &mirrored, length, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)bytes, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
        if(ret != KERN_SUCCESS) {
            NSLog(@"#### debugbydcmmc Failed to mirror memory: %s", mach_error_string(ret));
            return nil;
        }
        vm_protect(mach_task_self(), mirrored, length, NO,
                VM_PROT_READ | VM_PROT_WRITE);
        
        return [self hooked_newBufferWithBytesNoCopy:(void *)mirrored length:length options:options deallocator:^(void * _Nonnull pointer, NSUInteger length) {
            vm_deallocate(mach_task_self(), (vm_address_t)pointer, length);
            if(deallocator) deallocator(bytes, length);
        }];
    } else {
        return [self hooked_newBufferWithBytesNoCopy:bytes length:length options:options deallocator:deallocator];
    }
}

- (id<MTLBuffer>)hooked_newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options pointer:(void *)pointer copyBytes:(BOOL)copyBytes deallocator:(void (^)(void * pointer, NSUInteger length))deallocator {
    // Handle MTLResourceStorageModeManaged
    if(options & (1 << MTLResourceStorageModeShift)) {
        options &= ~(1 << MTLResourceStorageModeShift);
        options |= MTLResourceStorageModeShared;
    }
    return [self hooked_newBufferWithLength:length options:options pointer:pointer copyBytes:copyBytes deallocator:deallocator];
}

// IOSurface-backed texture creation: the SkyLight WSCompositeDestination /
// CAWindowServerDisplay surface path goes through here, and MTLSimDriver's
// sendXPCMessageWithReplySync cold path aborts on XPC reply errors with no
// recovery. Log every descriptor + IOSurface so we can characterize failures
// from the WindowServer.err / oslog stream BEFORE the abort kills the process.
static void macws_log_mtldesc(MTLTextureDescriptor *desc, IOSurfaceRef iosurface,
                              NSUInteger plane, const char *tag) {
    if (!desc) {
        fprintf(stderr, "#### MTL_TEX/%s desc=NIL\n", tag);
        return;
    }
    @try {
        fprintf(stderr, "#### MTL_TEX/%s pfmt=%lu type=%lu w=%lu h=%lu d=%lu mips=%lu arr=%lu samp=%lu storage=%lu cpu=%lu usage=%#lx swiz=%#x cs=%p plane=%lu ios=%p\n",
            tag,
            (unsigned long)desc.pixelFormat,
            (unsigned long)desc.textureType,
            (unsigned long)desc.width,
            (unsigned long)desc.height,
            (unsigned long)desc.depth,
            (unsigned long)desc.mipmapLevelCount,
            (unsigned long)desc.arrayLength,
            (unsigned long)desc.sampleCount,
            (unsigned long)desc.storageMode,
            (unsigned long)desc.cpuCacheMode,
            (unsigned long)desc.usage,
            0u, // swizzle placeholder (Metal 13+ only)
            (void*)0,
            (unsigned long)plane,
            (void*)iosurface);
    } @catch (NSException *e) {
        fprintf(stderr, "#### MTL_TEX/%s exception reading desc: %s\n", tag, [[e description] UTF8String] ?: "?");
    }
    if (iosurface) {
        uint32_t iosfmt = IOSurfaceGetPixelFormat(iosurface);
        char fmtstr[8] = {0};
        for (int i = 0; i < 4; i++) {
            char c = (char)((iosfmt >> (24 - i * 8)) & 0xff);
            fmtstr[i] = (c >= 0x20 && c < 0x7f) ? c : '.';
        }
        size_t npl = IOSurfaceGetPlaneCount(iosurface);
        fprintf(stderr, "####     ios: w=%zu h=%zu bpr=%zu fmt=%#x(%s) elemSz=%zu allocSz=%zu planes=%zu\n",
            IOSurfaceGetWidth(iosurface),
            IOSurfaceGetHeight(iosurface),
            IOSurfaceGetBytesPerRow(iosurface),
            (unsigned)iosfmt, fmtstr,
            IOSurfaceGetElementWidth(iosurface),
            IOSurfaceGetAllocSize(iosurface),
            npl);
        for (size_t p = 0; p < npl && p < 4; p++) {
            fprintf(stderr, "####       plane[%zu]: w=%zu h=%zu bpr=%zu bpe=%zu\n",
                p,
                IOSurfaceGetWidthOfPlane(iosurface, p),
                IOSurfaceGetHeightOfPlane(iosurface, p),
                IOSurfaceGetBytesPerRowOfPlane(iosurface, p),
                IOSurfaceGetBytesPerElementOfPlane(iosurface, p));
        }
        // Dump ALL IOSurface property keys (one-shot — only on NIL traces so we
        // don't flood per-frame). The dict reveals IOSurfacePlaneCompressionType
        // and other Apple-private flags that explain WHY iOS Metal rejects it.
        if (strstr(tag, ".NIL") || strstr(tag, ".IN")) {
            CFDictionaryRef d = (CFDictionaryRef)IOSurfaceCopyAllValues(iosurface);
            if (d) {
                NSDictionary *nd = (__bridge NSDictionary *)d;
                for (id k in [nd allKeys]) {
                    NSString *desc = [nd[k] description];
                    if ([desc length] > 200) desc = [desc substringToIndex:200];
                    fprintf(stderr, "####       prop[%s] = %s\n",
                        [[k description] UTF8String] ?: "?",
                        [desc UTF8String] ?: "?");
                }
                CFRelease(d);
            }
        }
    }
}

// Empirical: macOS SkyLight on iPad asks for MTLPixelFormat=550 wrapping an
// IOSurface with FourCC '&b38' (0x26623338) — Apple-private 40-bit BGRA10_XR-like
// format used for iPad display backbuffers (5.19 bytes/pixel). iOS Metal returns
// nil for unknown private formats, so we translate 550 → public BGRA10_XR (552),
// falling back to sRGB (553), RGB10A2 (90), BGRA8 (80). The first hit wins.
//
// Translation list ordered by closeness to the source layout. Add formats here
// as new IOSurface fourCCs surface in the trace.
static const NSUInteger kMacwsTexFmt550Fallbacks[] = {
    552,  // BGRA10_XR
    553,  // BGRA10_XR_sRGB
    94,   // BGR10A2Unorm (32-bit packed, lossy width)
    90,   // RGB10A2Unorm
    80,   // BGRA8Unorm (degraded SDR)
    81,   // BGRA8Unorm_sRGB
    0
};

// Coexistence does not present the macOS frame to DCP: SwapEnd is paired with
// SwapCancel so iPadOS keeps ownership of the panel.  Rendering the virtual
// desktop into DCP's compressed '&b38' page anyway leaves VNC with a resource
// that cannot be read safely after the page is recycled.  The gated owned-
// scanout experiment substitutes one ordinary BGRA IOSurface for each IOMFB
// page at texture-wrap time.  It preserves QuartzCore's real page/swap state
// (the original IOSurface is still returned by currentSurface and cancelled),
// but makes the Metal render destination process-owned and CPU-readable.
//
// The returned IOSurface carries a temporary reservation retain.  The caller
// must release that retain only after the native AGX texture initializer has
// either retained the surface or failed.  Without that reservation, a second
// wrapping thread can observe the pool-only retain in the gap between this
// function returning and Metal retaining the surface, then lease the same
// render target concurrently.
//
// This is diagnostic until the full render/present lifecycle and memory bound
// are runtime-proven.  It does not bypass a validation check: Apple's native
// AGX initializer must successfully construct the replacement texture.
static IOSurfaceRef macws_owned_scanout_for_original(IOSurfaceRef original,
                                                      size_t width,
                                                      size_t height) {
    if (!original || width < 1000 || height < 600 ||
        !macws_owned_scanout_enabled()) {
        return NULL;
    }
    uint32_t format = IOSurfaceGetPixelFormat(original);
    if ((format & 0xff000000u) != 0x26000000u) return NULL;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_macws_owned_scanout_lock = [NSObject new];
        g_macws_owned_scanout_pool = [NSMutableDictionary new];
    });
    uint32_t originalID = IOSurfaceGetID(original);
    NSString *key = [NSString stringWithFormat:@"%zux%zu", width, height];
    @synchronized(g_macws_owned_scanout_lock) {
        g_macws_owned_scanout_clock++;
        NSMutableArray *shapeEntries = g_macws_owned_scanout_pool[key];
        for (NSMutableDictionary *entry in shapeEntries) {
            IOSurfaceRef existing = (IOSurfaceRef)
                [entry[@"surface"] pointerValue];
            CFIndex baseline = [entry[@"baseline"] longLongValue];
            CFIndex retainCount = existing
                ? CFGetRetainCount(existing) : 0;
            if (existing && retainCount <= baseline) {
                // Reserve before dropping the lock.  Metal takes its own
                // retain in hooked_newTextureWithDescriptor:iosurface:plane:.
                CFRetain(existing);
                entry[@"last"] = @(g_macws_owned_scanout_clock);
                static _Atomic uint64_t hits = 0;
                uint64_t hit = macws_runtime_diagnostics_enabled()
                    ? atomic_fetch_add(&hits, 1) + 1 : 0;
                if (hit && (hit <= 32 || (hit % 600) == 0)) {
                    fprintf(stderr,
                        "#### VNC-OWNED lease-hit #%llu key=%s "
                        "originalID=%u surface=%p id=%u retain=%ld "
                        "baseline=%ld entries=%lu pool=%luMB\n",
                        (unsigned long long)hit, [key UTF8String], originalID,
                        (void *)existing, (unsigned)IOSurfaceGetID(existing),
                        (long)retainCount, (long)baseline,
                        (unsigned long)[shapeEntries count],
                        (unsigned long)(g_macws_owned_scanout_pool_bytes /
                                        (1024 * 1024)));
                }
                return existing;
            }
        }

        NSDictionary *properties = @{
            @"IOSurfaceWidth": @(width),
            @"IOSurfaceHeight": @(height),
            @"IOSurfaceBytesPerElement": @4,
            @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
            // This target is consumed by WindowServer itself and copied to the
            // VNC mmap in the same process; it never needs a global IOSurface
            // namespace entry.  The project's established AGX scratch-surface
            // path uses the same non-global/default-cache policy because
            // global/display-like surfaces can enter DCP bookkeeping even
            // though coexist mode cancels the physical swap.
            @"IOSurfaceIsGlobal": @NO,
            @"IOSurfaceCacheMode": @0,
        };
        IOSurfaceRef owned = IOSurfaceCreate(
            (__bridge CFDictionaryRef)properties);
        if (!owned) {
            fprintf(stderr,
                "#### VNC-OWNED IOSurfaceCreate FAILED original=%p "
                "%zux%zu format=%#x\n",
                (void *)original, width, height, format);
            return NULL;
        }

        if (!shapeEntries) {
            shapeEntries = [NSMutableArray array];
            g_macws_owned_scanout_pool[key] = shapeEntries;
        }
        NSUInteger allocation = IOSurfaceGetAllocSize(owned);
        CFIndex baseline = CFGetRetainCount(owned);
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"surface"] = [NSValue valueWithPointer:(void *)owned];
        entry[@"baseline"] = @(baseline);
        entry[@"bytes"] = @(allocation);
        entry[@"last"] = @(g_macws_owned_scanout_clock);
        [shapeEntries addObject:entry];
        g_macws_owned_scanout_pool_bytes += allocation;
        static NSUInteger lastScanoutWitnessBucket = 0;
        NSUInteger scanoutWitnessBucket =
            g_macws_owned_scanout_pool_bytes / (64U * 1024U * 1024U);
        if (scanoutWitnessBucket > lastScanoutWitnessBucket) {
            lastScanoutWitnessBucket = scanoutWitnessBucket;
            dprintf(STDERR_FILENO,
                "#### MACWS-MEMORY-WITNESS pool=owned-scanout "
                "idle-and-live=%luMB rss=%lluMB entries=%lu\n",
                (unsigned long)(g_macws_owned_scanout_pool_bytes /
                                (1024U * 1024U)),
                (unsigned long long)(macws_resident_memory_bytes() /
                                     (1024U * 1024U)),
                (unsigned long)[shapeEntries count]);
        }

        // This retain is the caller's reservation, separate from the create
        // retain owned by the pool entry.
        CFRetain(owned);
        static _Atomic uint64_t allocations = 0;
        uint64_t allocated = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&allocations, 1) + 1 : 0;
        if (allocated) {
            fprintf(stderr,
                "#### VNC-OWNED lease-new #%llu key=%s original=%p id=%u "
                "-> owned=%p id=%u %zux%zu bpr=%zu alloc=%zu "
                "entries=%lu pool=%luMB baseline=%ld reserved-retain=%ld\n",
                (unsigned long long)allocated, [key UTF8String],
                (void *)original, originalID,
                (void *)owned, (unsigned)IOSurfaceGetID(owned), width, height,
                IOSurfaceGetBytesPerRow(owned), allocation,
                (unsigned long)[shapeEntries count],
                (unsigned long)(g_macws_owned_scanout_pool_bytes /
                                (1024 * 1024)),
                (long)baseline,
                (long)CFGetRetainCount(owned));
        }

        // Evict only idle older entries.  Live textures may temporarily push
        // the pool over budget; freeing or aliasing one would violate the
        // render-target lifetime contract.
        // Four Retina BGRA scanouts occupy roughly 61 MiB on the target.
        // Retaining 256 MiB of *idle* generations kept obsolete orientation,
        // Scene and display-shape targets resident long after their GPU users
        // completed.  A 128-MiB idle LRU preserves ample double/triple-buffer
        // headroom; busy entries remain protected and may exceed this budget
        // until their real texture retain counts return to baseline.
        const NSUInteger budget = 128U * 1024U * 1024U;
        while (g_macws_owned_scanout_pool_bytes > budget) {
            NSString *oldestKey = nil;
            NSMutableArray *oldestArray = nil;
            NSMutableDictionary *oldestEntry = nil;
            uint64_t oldestUse = UINT64_MAX;
            for (NSString *candidateKey in g_macws_owned_scanout_pool) {
                NSMutableArray *candidateArray =
                    g_macws_owned_scanout_pool[candidateKey];
                for (NSMutableDictionary *candidateEntry in candidateArray) {
                    if (candidateEntry == entry) continue;
                    IOSurfaceRef candidate = (IOSurfaceRef)
                        [candidateEntry[@"surface"] pointerValue];
                    CFIndex candidateBaseline =
                        [candidateEntry[@"baseline"] longLongValue];
                    CFIndex candidateRetain = candidate
                        ? CFGetRetainCount(candidate) : 0;
                    uint64_t candidateUse =
                        [candidateEntry[@"last"] unsignedLongLongValue];
                    if (candidate && candidateRetain <= candidateBaseline &&
                        candidateUse < oldestUse) {
                        oldestUse = candidateUse;
                        oldestKey = candidateKey;
                        oldestArray = candidateArray;
                        oldestEntry = candidateEntry;
                    }
                }
            }
            if (!oldestEntry) {
                static _Atomic uint64_t overBudget = 0;
                uint64_t count = macws_runtime_diagnostics_enabled()
                    ? atomic_fetch_add(&overBudget, 1) + 1 : 0;
                if (count && (count <= 8 || (count % 300) == 0)) {
                    fprintf(stderr,
                        "#### VNC-OWNED lease-over-budget #%llu pool=%luMB "
                        "all older surfaces busy\n",
                        (unsigned long long)count,
                        (unsigned long)(g_macws_owned_scanout_pool_bytes /
                                        (1024 * 1024)));
                }
                break;
            }
            IOSurfaceRef evicted = (IOSurfaceRef)
                [oldestEntry[@"surface"] pointerValue];
            NSUInteger evictedBytes =
                [oldestEntry[@"bytes"] unsignedIntegerValue];
            [oldestArray removeObjectIdenticalTo:oldestEntry];
            if ([oldestArray count] == 0)
                [g_macws_owned_scanout_pool removeObjectForKey:oldestKey];
            g_macws_owned_scanout_pool_bytes =
                evictedBytes > g_macws_owned_scanout_pool_bytes
                    ? 0 : g_macws_owned_scanout_pool_bytes - evictedBytes;
            static _Atomic uint64_t evictions = 0;
            uint64_t eviction = macws_runtime_diagnostics_enabled()
                ? atomic_fetch_add(&evictions, 1) + 1 : 0;
            if (eviction &&
                (eviction <= 16 || (eviction % 600) == 0)) {
                fprintf(stderr,
                    "#### VNC-OWNED lease-evict #%llu key=%s surface=%p "
                    "id=%u bytes=%luKB pool=%luMB\n",
                    (unsigned long long)eviction,
                    [oldestKey UTF8String], (void *)evicted,
                    evicted ? (unsigned)IOSurfaceGetID(evicted) : 0,
                    (unsigned long)(evictedBytes / 1024),
                    (unsigned long)(g_macws_owned_scanout_pool_bytes /
                                    (1024 * 1024)));
            }
            if (evicted) CFRelease(evicted);
        }
        return owned;
    }
}

// Create the private two-plane surface required by MTLPixelFormat 550.
//
// Runtime evidence, 2026-07-27:
//   - WindowServer's first Terminal PageFault target was the plain-texture
//     pool entry 300x210-pf550-bpe4-fcc'BGRA'.  The corresponding raw type
//     0x82 resource request had byte +0x13 == 2, while the synthesized
//     IOSurface reported BGRA / 4 bytes per element.
//   - An iOS-native control using this exact property layout emitted a
//     pf550 type-0x82 request with f14=0x430 and completed with status=4 and
//     error=nil at 1140x798.  IOSurfaceCopyAllValues on WindowServer's native
//     display surface established the same 16x16 tile geometry and 1024/256
//     bytes of tile data for planes 0/1.
//
// Keep this fix at the resource-creation layer: the AGX request and command
// stream must describe the surface that actually exists.  In particular, do
// not make the later resource translator or PageFault callback pretend that a
// linear BGRA allocation is a compressed pf550 allocation.
static IOSurfaceRef macws_create_pf550_scratch_surface(size_t width,
                                                        size_t height) {
    size_t widthInTiles = (width + 15) / 16;
    size_t heightInTiles = (height + 15) / 16;
    size_t plane0BytesPerRow = widthInTiles * 1024;
    size_t plane1BytesPerRow = widthInTiles * 256;
    size_t plane0DataSize = plane0BytesPerRow * heightInTiles;
    size_t plane1DataSize = plane1BytesPerRow * heightInTiles;
    size_t plane0Size = plane0DataSize + 0x40000;
    size_t plane1Offset = plane0Size;
    size_t plane1HeaderOffset = plane1Offset + plane1DataSize;
    size_t plane1Size = plane1DataSize + 0x40000;
    size_t allocSize = plane0Size + plane1Size;

    NSDictionary *plane0 = @{
        @"IOSurfaceAddressFormat": @5,
        @"IOSurfacePlaneBytesPerCompressedTileHeader": @8,
        @"IOSurfacePlaneBytesPerElement": @1024,
        @"IOSurfacePlaneBytesPerRow": @(plane0BytesPerRow),
        @"IOSurfacePlaneBytesPerRowOfTileData": @(plane0BytesPerRow),
        @"IOSurfacePlaneBytesPerTileData": @1024,
        @"IOSurfacePlaneCompressedTileDataRegionOffset": @0,
        @"IOSurfacePlaneCompressedTileHeaderRegionOffset": @(plane0DataSize),
        @"IOSurfacePlaneCompressedTileHeight": @16,
        @"IOSurfacePlaneCompressedTileWidth": @16,
        @"IOSurfacePlaneCompressionFootprint": @0,
        @"IOSurfacePlaneCompressionType": @3,
        @"IOSurfacePlaneElementHeight": @16,
        @"IOSurfacePlaneElementWidth": @16,
        @"IOSurfacePlaneHeight": @(height),
        @"IOSurfacePlaneHeightInCompressedTiles": @(heightInTiles),
        @"IOSurfacePlaneOffset": @0,
        @"IOSurfacePlaneSize": @(plane0Size),
        @"IOSurfacePlaneWidth": @(width),
        @"IOSurfacePlaneWidthInCompressedTiles": @(widthInTiles),
    };
    NSDictionary *plane1 = @{
        @"IOSurfaceAddressFormat": @5,
        @"IOSurfacePlaneBytesPerCompressedTileHeader": @8,
        @"IOSurfacePlaneBytesPerElement": @256,
        @"IOSurfacePlaneBytesPerRow": @(plane1BytesPerRow),
        @"IOSurfacePlaneBytesPerRowOfTileData": @(plane1BytesPerRow),
        @"IOSurfacePlaneBytesPerTileData": @256,
        @"IOSurfacePlaneCompressedTileDataRegionOffset": @(plane1Offset),
        @"IOSurfacePlaneCompressedTileHeaderRegionOffset": @(plane1HeaderOffset),
        @"IOSurfacePlaneCompressedTileHeight": @16,
        @"IOSurfacePlaneCompressedTileWidth": @16,
        @"IOSurfacePlaneCompressionFootprint": @0,
        @"IOSurfacePlaneCompressionType": @3,
        @"IOSurfacePlaneElementHeight": @16,
        @"IOSurfacePlaneElementWidth": @16,
        @"IOSurfacePlaneHeight": @(height),
        @"IOSurfacePlaneHeightInCompressedTiles": @(heightInTiles),
        @"IOSurfacePlaneOffset": @(plane1Offset),
        @"IOSurfacePlaneSize": @(plane1Size),
        @"IOSurfacePlaneWidth": @(width),
        @"IOSurfacePlaneWidthInCompressedTiles": @(widthInTiles),
    };
    NSDictionary *properties = @{
        @"IOSurfaceAllocSize": @(allocSize),
        @"IOSurfaceCacheMode": @1792,
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceMapCacheAttribute": @0,
        @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
        // IOSurfaceCreate_safe only rewrites the exact name "CA Framebuffer".
        // This is a native-AGX scratch resource, not a physical scanout.
        @"IOSurfaceName": @"MacWS native pf550 scratch",
        @"IOSurfacePixelFormat": @643969848, // private '&b38' surface format
        @"IOSurfacePixelSizeCastingAllowed": @0,
        @"IOSurfacePlaneInfo": @[plane0, plane1],
        @"IOSurfaceWidth": @(width),
    };
    IOSurfaceRef surface = IOSurfaceCreate(
        (__bridge CFDictionaryRef)properties);

    if (macws_iogpu_error_diag_enabled()) {
        extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(
            IOSurfaceRef, size_t) __attribute__((weak_import));
        uint32_t rawCompressionType =
            surface && IOSurfaceGetCompressionTypeOfPlane
            ? IOSurfaceGetCompressionTypeOfPlane(surface, 0) : UINT32_MAX;
        size_t rawHeightInTiles =
            surface && IOSurfaceGetHeightInCompressedTilesOfPlane
                ? IOSurfaceGetHeightInCompressedTilesOfPlane(surface, 0)
                : SIZE_MAX;
        uint32_t compatibleCompressionType = surface
            ? macws_IOSurfaceGetCompressionTypeOfPlane(surface, 0)
            : UINT32_MAX;
        size_t compatibleHeightInTiles = surface
            ? macws_IOSurfaceGetHeightInCompressedTilesOfPlane(surface, 0)
            : SIZE_MAX;
        fprintf(stderr,
            "#### MTL_TEX PF550-SURFACE: %zux%zu tiles=%zux%zu "
            "surface=%p id=%u alloc=%#zx actualAlloc=%#zx "
            "rawCompressionType=%u rawHeightInTiles=%zu "
            "compatibleCompressionType=%u compatibleHeightInTiles=%zu\n",
            width, height, widthInTiles, heightInTiles, (void *)surface,
            surface ? IOSurfaceGetID(surface) : 0, allocSize,
            surface ? IOSurfaceGetAllocSize(surface) : 0,
            rawCompressionType, rawHeightInTiles,
            compatibleCompressionType, compatibleHeightInTiles);
    }
    return surface;
}

// SIGABRT survival scope. MTLSimDriver's sendXPCMessageWithReplySync.cold.1
// calls abort() on any XPC reply error — there is NO return path. We install a
// thread-local SIGABRT handler around the %orig call so abort()-via-pthread_kill
// becomes a recoverable siglongjmp instead of a fatal process exit. Outside the
// protected scope, abort() reverts to the system default.
static __thread sigjmp_buf macws_abort_env;
static __thread int macws_in_protected = 0;
static void macws_sigabrt_trampoline(int sig) {
    if (macws_in_protected) {
        siglongjmp(macws_abort_env, 1);
    }
    // Not in our scope — re-raise with default to give the system its abort.
    signal(SIGABRT, SIG_DFL);
    raise(SIGABRT);
}

// Preserve macOS descriptor semantics until the request reaches the native
// iOS AGX device.  The old MTLTextureDescriptorInternal -storageMode hook
// changed Managed to Shared inside the getter itself, permanently mutating the
// caller's object.  Metal Validation runtime-confirmed that QuartzCore's
// CAMetalLayer IOSurface request then failed in the outer macOS Metal layer:
//
//   IOSurface textures must use MTLStorageModeManaged
//
// iOS AGX cannot consume Managed, so the ABI translation is still necessary,
// but it belongs at this device boundary.  Copy the descriptor and translate
// only the copy that is passed to the real iOS driver; QuartzCore/UE4 and an
// outer MTLDebugDevice continue to observe their original Managed contract.
static MTLTextureDescriptor *macws_native_agx_texture_descriptor(
        MTLTextureDescriptor *descriptor, const char *site) {
    if (!descriptor || !getenv("MACWS_AGX_NATIVE") ||
        descriptor.storageMode != (MTLStorageMode)1 /* Managed on macOS */) {
        return descriptor;
    }

    MTLTextureDescriptor *native = [[descriptor copy] autorelease];
    if (!native) return descriptor;
    native.storageMode = MTLStorageModeShared;

    static _Atomic uint64_t translationCount = 0;
    uint64_t sequence = atomic_fetch_add_explicit(
        &translationCount, 1, memory_order_relaxed) + 1;
    if (macws_runtime_diagnostics_enabled() && sequence <= 24) {
        fprintf(stderr,
            "#### MTL_TEX MANAGED-BOUNDARY #%llu site=%s "
            "caller=%p storage=Managed native=%p storage=Shared "
            "pf=%lu w=%lu h=%lu usage=%#lx\n",
            (unsigned long long)sequence, site ? site : "(unknown)",
            (void *)descriptor, (void *)native,
            (unsigned long)native.pixelFormat,
            (unsigned long)native.width, (unsigned long)native.height,
            (unsigned long)native.usage);
    }
    return native;
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc
                                        iosurface:(IOSurfaceRef)iosurface
                                            plane:(NSUInteger)plane {
    desc = macws_native_agx_texture_descriptor(desc, "iosurface");
    macws_lock_current_iosurface_scope();
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.IN");
    }
    static int classlog = 0;
    if (macws_runtime_diagnostics_enabled() && classlog < 3) {
        fprintf(stderr, "#### MTL_TEX entry self class=%s\n", class_getName([self class]));
        classlog++;
    }
    // AGX gate probe: log the EXACT values the 3 entry-gate IOSurface APIs
    // return for THIS surface. If our prediction is right (compType=0,
    // heightInCompTiles=0, validateWithDevice=YES) and the texture is still
    // nil, then the failure must be inside `initImplWith...` (post-gate).
    // Logged once per unique (self_class, iosurface, plane) combo to avoid
    // spam.
    if (getenv("MACWS_AGX_TEX_BYPASS_GATE") && iosurface) {
        extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        static int probelog = 0;
        if (probelog < 8) {
            uint32_t ctype = IOSurfaceGetCompressionTypeOfPlane
                ? IOSurfaceGetCompressionTypeOfPlane(iosurface, plane) : 0xFFFFFFFF;
            size_t hct = IOSurfaceGetHeightInCompressedTilesOfPlane
                ? IOSurfaceGetHeightInCompressedTilesOfPlane(iosurface, plane) : (size_t)-1;
            BOOL validOK = NO;
            @try {
                validOK = [desc respondsToSelector:@selector(validateWithDevice:)]
                    ? ((BOOL (*)(id, SEL, id))objc_msgSend)(desc,
                          @selector(validateWithDevice:), self)
                    : NO;
            } @catch (NSException *e) {
                validOK = -1; // marker that it threw
            }
            fprintf(stderr,
                "#### AGX_GATE_PROBE class=%s ios=%p plane=%lu "
                "compressionType=%u heightInCompressedTiles=%zu validateWithDevice=%d "
                "desc=(w=%lu h=%lu pf=%lu storage=%lu usage=0x%lx)\n",
                class_getName([self class]),
                (void*)iosurface, (unsigned long)plane,
                ctype, hct, (int)validOK,
                (unsigned long)desc.width, (unsigned long)desc.height,
                (unsigned long)desc.pixelFormat,
                (unsigned long)desc.storageMode, (unsigned long)desc.usage);
            probelog++;
        }
    }
    // Stash one lock-protected process-wide IOSurface tuple so
    // IOConnectCallMethod_new can inject it
    // into args[+0x30] for the sel=0xa type=0x82 path. Save/restore the
    // previous value to handle re-entry (shadow IOSurface fallback path).
    uint32_t prev_iosurface_id = macws_get_current_iosurface_id();
    uint32_t prev_iosurface_plane = macws_get_current_iosurface_plane();
    uint64_t prev_compression_header_span =
        macws_get_current_iosurface_compression_header_span();
    uint64_t compression_header_span =
        macws_iosurface_compression_header_span(iosurface, plane);
    macws_set_current_iosurface_id(iosurface ? IOSurfaceGetID(iosurface) : 0);
    macws_set_current_iosurface_plane((uint32_t)plane);
    macws_set_current_iosurface_compression_header_span(
        compression_header_span);
    static int tls_log = 0;
    if (macws_runtime_diagnostics_enabled() && tls_log < 8) {
        fprintf(stderr,
            "#### MTL_TEX TLS set iosurface=%p id=%#x plane=%lu "
            "compressionHeaderSpan=%#llx (thread=%p addr=%p)\n",
            iosurface, macws_get_current_iosurface_id(),
            (unsigned long)plane,
            (unsigned long long)compression_header_span,
            (void*)pthread_self(), NULL);
        tls_log++;
    }

    id<MTLTexture> result = nil;
    IOSurfaceRef auditSurface = iosurface;
    // macws_owned_scanout_for_original returns a temporary reservation retain
    // which spans the gap until Metal has either retained the IOSurface or
    // failed.  Volatile keeps the value defined across the SIGABRT siglongjmp.
    volatile IOSurfaceRef ownedReservation = NULL;
    struct sigaction old_sa, new_sa;
    memset(&new_sa, 0, sizeof(new_sa));
    new_sa.sa_handler = macws_sigabrt_trampoline;
    sigemptyset(&new_sa.sa_mask);
    new_sa.sa_flags = SA_NODEFER;
    sigaction(SIGABRT, &new_sa, &old_sa);
    macws_in_protected = 1;
    if (sigsetjmp(macws_abort_env, 1) == 0) {
        IOSurfaceRef owned = desc && iosurface
            ? macws_owned_scanout_for_original(iosurface, desc.width,
                                                desc.height)
            : NULL;
        ownedReservation = owned;
        if (owned) {
            auditSurface = owned;
            MTLPixelFormat originalFormat = desc.pixelFormat;
            uint32_t originalCurrentID = macws_get_current_iosurface_id();
            uint32_t originalCurrentPlane =
                macws_get_current_iosurface_plane();
            uint64_t originalCompressionSpan =
                macws_get_current_iosurface_compression_header_span();
            desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
            macws_set_current_iosurface_id(IOSurfaceGetID(owned));
            macws_set_current_iosurface_plane(0);
            macws_set_current_iosurface_compression_header_span(0);
            CFIndex retainBeforeTexture = CFGetRetainCount(owned);
            result = [self hooked_newTextureWithDescriptor:desc
                                                  iosurface:owned plane:0];
            CFIndex retainAfterTexture = CFGetRetainCount(owned);
            if (result) {
                objc_setAssociatedObject(
                    result, &g_macws_owned_texture_association_key,
                    @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            macws_set_current_iosurface_id(originalCurrentID);
            macws_set_current_iosurface_plane(originalCurrentPlane);
            macws_set_current_iosurface_compression_header_span(
                originalCompressionSpan);
            desc.pixelFormat = originalFormat;
            static _Atomic uint64_t ownedWrapCount = 0;
            uint64_t wrapped = macws_runtime_diagnostics_enabled()
                ? atomic_fetch_add(&ownedWrapCount, 1) + 1 : 0;
            if ((wrapped &&
                 (wrapped <= 24 || (wrapped % 600) == 0)) || !result) {
                fprintf(stderr,
                    "#### VNC-OWNED wrap #%llu original=%p id=%u "
                    "owned=%p id=%u texture=%p result=%s retain=%ld->%ld\n",
                    (unsigned long long)wrapped, (void *)iosurface,
                    (unsigned)IOSurfaceGetID(iosurface), (void *)owned,
                    (unsigned)IOSurfaceGetID(owned), (void *)result,
                    result ? "OK" : "NIL", (long)retainBeforeTexture,
                    (long)retainAfterTexture);
            }
        } else {
            result = [self hooked_newTextureWithDescriptor:desc
                                                  iosurface:iosurface
                                                      plane:plane];
        }
    } else {
        fprintf(stderr, "#### MTL_TEX/iosurf CAUGHT SIGABRT (XPC reply error) "
            "— recovered, will fall back (w=%lu h=%lu pf=%lu ios=%p)\n",
            (unsigned long)desc.width, (unsigned long)desc.height,
            (unsigned long)desc.pixelFormat, (void*)iosurface);
        result = nil;
    }
    macws_in_protected = 0;
    sigaction(SIGABRT, &old_sa, NULL);
    if (ownedReservation) {
        CFRelease((IOSurfaceRef)ownedReservation);
        ownedReservation = NULL;
    }
    if (!result && desc) {
        NSUInteger orig_fmt = desc.pixelFormat;
        // Try fallback translations only for the private 550 format (and nearby
        // private values in case Apple varies). Don't retry for known public
        // formats — their nil return means a real semantic error.
        BOOL is_private = (orig_fmt >= 548 && orig_fmt <= 551);
        if (is_private) {
            for (int i = 0; kMacwsTexFmt550Fallbacks[i] != 0; i++) {
                NSUInteger try_fmt = kMacwsTexFmt550Fallbacks[i];
                desc.pixelFormat = try_fmt;
                result = [self hooked_newTextureWithDescriptor:desc iosurface:iosurface plane:plane];
                if (result) {
                    fprintf(stderr,
                        "#### MTL_TEX/iosurf translated %lu->%lu OK (w=%lu h=%lu ios=%p tex=%p)\n",
                        (unsigned long)orig_fmt, (unsigned long)try_fmt,
                        (unsigned long)desc.width, (unsigned long)desc.height,
                        (void*)iosurface, (void*)result);
                    break;
                }
            }
            desc.pixelFormat = orig_fmt; // restore so caller sees original
        }
        // Shadow IOSurface substitution: when MTLSim/AGX-native cannot wrap
        // the iPad's compressed CA Framebuffer ('&b38' FourCC, 0x26-prefixed
        // Apple lossless-compressed format), allocate a SHADOW IOSurface in
        // plain BGRA8 with the same dimensions and wrap THAT in a Metal
        // texture. SkyLight + AGX both accept BGRA8 IOSurfaces fine; the
        // shadow stays in this process's address space so VNC's compositor
        // read path (which goes via the SkyLight display surface, not the
        // iPad's IOMFB scanout) sees the new content. The original iPad
        // scanout buffer stays untouched — coexistence mode (CA_VSYNC_OFF=1)
        // keeps the iPad panel on iOS anyway, so no visible artifact there.
        //
        // Pattern mirrors misc/TestMetalIOSurface and misc/agxprobe.m's
        // stage 5: minimal IOSurfaceCreate(width, height, bpe=4, pf='BGRA').
        //
        // Cache (original IOSurface ptr → shadow IOSurface ptr) so repeated
        // calls for the same scanout buffer reuse the same shadow.
        if (!result && iosurface && desc.width > 0 && desc.height > 0) {
            uint32_t fcc = IOSurfaceGetPixelFormat(iosurface);
            BOOL is_apple_compressed = ((fcc & 0xFF000000u) == 0x26000000u);
            if (is_apple_compressed) {
                static NSMutableDictionary *shadowCache = nil;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ shadowCache = [NSMutableDictionary new]; });
                NSValue *origKey = [NSValue valueWithPointer:(void *)iosurface];
                NSValue *shadowVal;
                @synchronized(shadowCache) {
                    shadowVal = shadowCache[origKey];
                }
                IOSurfaceRef shadow = (IOSurfaceRef)[shadowVal pointerValue];
                if (!shadow) {
                    // Match the iPad CA Framebuffer's kernel-side IOSurface
                    // properties so AGX accepts our shadow for
                    // newTextureWithDescriptor:iosurface:. Without these
                    // hints the userland IOSurface lacks IOGPU memory-region
                    // metadata and AGX rejects the wrap (verified: bare
                    // BGRA8 shadow at 2388x1668 returns nil; even h=48
                    // returns nil). The properties are mirrored from the
                    // original surface's reported "CreationProperties" dict:
                    //   IOSurfaceCacheMode      = 1792  (= 0x700, kIOMapWriteCombineCache)
                    //   IOSurfaceMapCacheAttribute = 0
                    //   IOSurfaceMemoryRegion   = "PurpleGfxMem"
                    NSDictionary *props = @{
                        @"IOSurfaceWidth":              @(desc.width),
                        @"IOSurfaceHeight":             @(desc.height),
                        @"IOSurfaceBytesPerElement":    @4,
                        @"IOSurfacePixelFormat":        @((uint32_t)'BGRA'),
                        @"IOSurfaceCacheMode":          @1792,
                        @"IOSurfaceMapCacheAttribute":  @0,
                        @"IOSurfaceMemoryRegion":       @"PurpleGfxMem",
                    };
                    shadow = IOSurfaceCreate((__bridge CFDictionaryRef)props);
                    // Fall back to bare BGRA8 if the kernel rejects
                    // PurpleGfxMem from userland.
                    if (!shadow) {
                        NSDictionary *bareprops = @{
                            @"IOSurfaceWidth":           @(desc.width),
                            @"IOSurfaceHeight":          @(desc.height),
                            @"IOSurfaceBytesPerElement": @4,
                            @"IOSurfacePixelFormat":     @((uint32_t)'BGRA'),
                        };
                        shadow = IOSurfaceCreate((__bridge CFDictionaryRef)bareprops);
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem rejected, fallback bare BGRA8 = %p\n",
                                (void *)shadow);
                    } else {
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem accepted = %p\n",
                                (void *)shadow);
                    }
                    if (shadow) {
                        @synchronized(shadowCache) {
                            shadowCache[origKey] = [NSValue valueWithPointer:(void *)shadow];
                        }
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW alloc'd BGRA8 (%lux%lu) %p for orig=%p (fcc=%#x)\n",
                            (unsigned long)desc.width, (unsigned long)desc.height,
                            (void *)shadow, (void *)iosurface, (unsigned)fcc);
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW IOSurfaceCreate FAILED for %lux%lu\n",
                            (unsigned long)desc.width, (unsigned long)desc.height);
                    }
                }
                if (shadow) {
                    MTLPixelFormat orig_fmt = desc.pixelFormat;
                    desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
                    result = [self hooked_newTextureWithDescriptor:desc iosurface:shadow plane:0];
                    desc.pixelFormat = orig_fmt;
                    if (result) {
                        static int logged = 0;
                        if (logged < 8) {
                            fprintf(stderr,
                                "#### MTL_TEX/iosurf SHADOW-backed texture %p (BGRA8) for orig surf=%p\n",
                                (void *)result, (void *)iosurface);
                            logged++;
                        }
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW newTexture STILL nil — giving up\n");
                    }
                }
            }
        }
    }
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/iosurf.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.NIL");
    }
    // Verify the real initializer established its IOSurface and CPU/GPU
    // mappings.  This is read-only; field ownership stays inside AGX.
    if (result && iosurface) {
        NSUInteger audit_plane = auditSurface == iosurface ? plane : 0;
        macws_audit_iosurface_texture_mapping(
            result, auditSurface, audit_plane, desc.width, desc.height,
            desc.pixelFormat);
        macws_diag_pf550_texture_descriptor(result, desc, iosurface, self);
    }
    // 2026-06-20 — VNC read-path test on the IOSURFACE VARIANT.  Filling
    // our pooled ROUTE-IOSURF surfaces with gray did NOT change VNC
    // (VNC reads SkyLight's own scanout surface, not our scratch
    // surfaces).  This variant is called directly by SkyLight for its
    // display/scanout surfaces (SkyLight-allocated IOSurface in the
    // `iosurface` arg).  Fill those large ones with gray (gated 1/240)
    // — if VNC turns gray, this IS the surface VNC reads → the fix is to
    // route GPU-rendered content here.  MACWS_SURF_FILL_IOS.
    if (getenv("MACWS_SURF_FILL_IOS") && iosurface) {
        size_t iw = IOSurfaceGetWidth(iosurface);
        size_t ih = IOSurfaceGetHeight(iosurface);
        if (iw >= 1000 && ih >= 600) {
            static _Atomic int fios = 0;
            if ((atomic_fetch_add(&fios, 1) % 240) == 0) {
                IOSurfaceLock(iosurface, 0, NULL);
                void *fb = IOSurfaceGetBaseAddress(iosurface);
                size_t al = IOSurfaceGetAllocSize(iosurface);
                if (fb && al) {
                    memset(fb, 0x80, al);
                    static int l = 0;
                    if (l++ < 4)
                        fprintf(stderr,
                            "#### SURF-FILL-IOS ios=%p %zux%zu allocSize=%zu filled 0x80\n",
                            (void*)iosurface, iw, ih, al);
                }
                IOSurfaceUnlock(iosurface, 0, NULL);
            }
        }
    }
    // 2026-06-20 — CONTINUOUS display-surface fill (read-path probe).
    // Tracks every display-sized IOSurface SkyLight passes here and a single
    // bg thread re-fills them all with solid gray every 25ms, so the fill
    // survives WS's intervening (black) composites. If VNC / a CLI
    // CGDisplayCreateImage then shows gray, THIS is the surface CreateImage
    // reads → the CPU-copy bridge (final-composite backing → this surface)
    // is the fix. If it stays black, CreateImage re-composites via GPU and
    // we need the pinnedGPULocation route. Diagnostic only; gated.
    macws_disp_fill_track(result, iosurface);
    // 2026-06-20 — FEASIBILITY TEST for the "iOS app displays macOS UI"
    // architecture.  The chroot AGX GPU renders real pixels into the
    // texture's private +0xa0 backing (proven: backing nonzero, IOSurface
    // zero).  If that backing is LINEAR (impl+0x184==0), a flat memcpy of
    // it yields a correct image — which an iOS app could display from a
    // shared IOSurface.  This one-shot dump captures the backing of the
    // largest texture to a file so we can convert it to PNG and visually
    // confirm it's recognizable GlassDemo/AM UI (the decisive proof that
    // the content is CPU-readable + linear).  MACWS_DUMP_BACKING.
    if (getenv("MACWS_DUMP_BACKING") && result && iosurface) {
        size_t iw = IOSurfaceGetWidth(iosurface);
        size_t ih = IOSurfaceGetHeight(iosurface);
        size_t bpe = IOSurfaceGetBytesPerElement(iosurface);
        // Dump the first large surface whose backing has content,
        // regardless of bpe (content turned out to land in the bpe=1
        // L008 macwsallocd buffers, not the RGBA pooled ones).  Logs
        // bpe so the reader picks grayscale vs RGBA interpretation.
        if (iw >= 1000 && ih >= 600 && bpe >= 1) {
            static _Atomic int dumped = 0;
            if (atomic_load(&dumped) == 0) {
                // _impl ivar offset (RE-confirmed 0x208), → C++ obj.
                void *impl = *(void **)((char *)(__bridge void *)result + 0x208);
                if (impl && (uintptr_t)impl > 0x1000) {
                    void *backing = *(void **)((char *)impl + 0xa0);
                    uint32_t stride = *(uint32_t *)((char *)impl + 0xa8);
                    uint8_t  layout = *(uint8_t  *)((char *)impl + 0x184);
                    // Only dump a backing that actually has content in its
                    // first 4 KB (skip cleared/staging textures).
                    int nz = 0;
                    if (backing && (uintptr_t)backing > 0x1000) {
                        for (int i = 0; i < 4096; i++)
                            if (((volatile uint8_t*)backing)[i]) { nz++; }
                    }
                    fprintf(stderr,
                        "#### DUMP-BACKING tex=%p impl=%p backing=%p stride=%u "
                        "layout=%u  %zux%zu bpe=%zu first4Knz=%d (linear iff layout==0)\n",
                        (void*)result, impl, backing, stride, layout,
                        iw, ih, bpe, nz);
                    if (backing && (uintptr_t)backing > 0x1000 && nz > 0) {
                        atomic_store(&dumped, 1);
                        size_t rowbytes = stride ? stride : iw * bpe;
                        size_t total = rowbytes * ih;
                        if (total > 64u*1024*1024) total = 64u*1024*1024; // cap
                        FILE *f = fopen("/tmp/composite_backing.raw", "wb");
                        if (f) {
                            // header line so the reader knows geometry
                            fprintf(f, "MACWSDUMP w=%zu h=%zu bpe=%zu stride=%zu layout=%u\n",
                                    iw, ih, bpe, rowbytes, layout);
                            size_t wrote = fwrite(backing, 1, total, f);
                            fclose(f);
                            fprintf(stderr,
                                "#### DUMP-BACKING wrote %zu/%zu bytes → /tmp/composite_backing.raw\n",
                                wrote, total);
                        } else {
                            fprintf(stderr, "#### DUMP-BACKING fopen failed errno=%d\n", errno);
                        }
                    }
                }
            }
        }
    }
    macws_set_current_iosurface_id(prev_iosurface_id);
    macws_set_current_iosurface_plane(prev_iosurface_plane);
    macws_set_current_iosurface_compression_header_span(
        prev_compression_header_span);
    macws_unlock_current_iosurface_scope();
    return result;
}

// Block-compressed Metal textures are not byte-addressable linear images and
// therefore cannot be represented by the generic IOSurface compatibility
// allocator below.  Keep this as an exact enum set instead of a broad numeric
// range: the gaps in Metal's compressed-format ranges are real, and treating a
// future uncompressed enum as compressed would silently change its allocator.
static BOOL macws_pixel_format_is_block_compressed(NSUInteger pf) {
    switch (pf) {
        // BC1-BC7 (S3TC/RGTC/BPTC).
        case 130: case 131: case 132: case 133: case 134: case 135:
        case 140: case 141: case 142: case 143:
        case 150: case 151: case 152: case 153:
        // PVRTC.
        case 160: case 161: case 162: case 163:
        case 164: case 165: case 166: case 167:
        // EAC / ETC2.
        case 170: case 172: case 174: case 176: case 178: case 179:
        case 180: case 181: case 182: case 183:
        // ASTC sRGB, LDR and HDR.  Metal intentionally leaves holes between
        // some block-size encodings (191, 201-203, 209, 219-221, 227).
        case 186: case 187: case 188: case 189: case 190:
        case 192: case 193: case 194: case 195: case 196:
        case 197: case 198: case 199: case 200:
        case 204: case 205: case 206: case 207: case 208:
        case 210: case 211: case 212: case 213: case 214:
        case 215: case 216: case 217: case 218:
        case 222: case 223: case 224: case 225: case 226:
        case 228: case 229: case 230: case 231: case 232:
        case 233: case 234: case 235: case 236:
            return YES;
        default:
            return NO;
    }
}

// Opt-in evidence for plain-texture IOSurface layout failures.  Keep this
// independent of the broad MACWS_TEX_TRACE environment switch: launchers may
// intentionally sanitize diagnostic environment variables, while the chroot
// sentinel remains visible at the exact allocator boundary.  This observer
// never changes the descriptor or the IOSurface.
static BOOL macws_texture_stride_diag_enabled(void) {
    return access("/private/tmp/macws_texture_stride_diag", F_OK) == 0;
}

static void macws_log_plain_texture_surface_layout(
        MTLTextureDescriptor *desc, IOSurfaceRef surface,
        NSUInteger selectedBytesPerElement, uint32_t selectedPixelFormat) {
    if (!macws_texture_stride_diag_enabled()) return;
    static _Atomic uint64_t sequence = 0;
    uint64_t current =
        atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed) + 1;
    dprintf(STDERR_FILENO,
        "#### MTL_TEX STRIDE-DIAG #%llu "
        "desc=(pf=%lu type=%lu w=%lu h=%lu d=%lu mips=%lu arr=%lu "
        "samples=%lu storage=%lu usage=%#lx) "
        "selected=(bpe=%lu fcc=%#x) "
        "surface=(%p id=%u w=%zu h=%zu bpr=%zu bpe=%zu fcc=%#x "
        "planes=%zu alloc=%zu)\n",
        (unsigned long long)current,
        (unsigned long)desc.pixelFormat,
        (unsigned long)desc.textureType,
        (unsigned long)desc.width,
        (unsigned long)desc.height,
        (unsigned long)desc.depth,
        (unsigned long)desc.mipmapLevelCount,
        (unsigned long)desc.arrayLength,
        (unsigned long)desc.sampleCount,
        (unsigned long)desc.storageMode,
        (unsigned long)desc.usage,
        (unsigned long)selectedBytesPerElement,
        (unsigned)selectedPixelFormat,
        (void *)surface, surface ? IOSurfaceGetID(surface) : 0,
        surface ? IOSurfaceGetWidth(surface) : 0,
        surface ? IOSurfaceGetHeight(surface) : 0,
        surface ? IOSurfaceGetBytesPerRow(surface) : 0,
        surface ? IOSurfaceGetBytesPerElement(surface) : 0,
        surface ? IOSurfaceGetPixelFormat(surface) : 0,
        surface ? IOSurfaceGetPlaneCount(surface) : 0,
        surface ? IOSurfaceGetAllocSize(surface) : 0);
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    desc = macws_native_agx_texture_descriptor(desc, "plain");
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, NULL, 0, "plain.IN");
    }
    // Ordinary plain textures use the IOSurface compatibility initializer on
    // every native-AGX process.  The cross-image native initializer still
    // rejects common descriptors (runtime: repeated AGX_INITARGS FAIL and a
    // Chromium 128x16 R8 Skia OOM).  The historical compatibility allocator
    // was also incorrect because it returned exactly one texture per shape:
    // concurrent equal-shape menu/backdrop intermediates aliased each other.
    // The implementation below now leases distinct cached entries according
    // to their real retain lifetime, so compatibility no longer implies
    // aliasing.  MACWS_AGX_NATIVE_PLAIN remains a controlled A/B escape hatch,
    // not the production policy.
    BOOL use_lease_plain_texture_pool =
        getenv("MACWS_AGX_NATIVE") != NULL &&
        getenv("MACWS_AGX_NATIVE_PLAIN") == NULL;
    if (use_lease_plain_texture_pool) {
        // 2026-06-20 — Route plain newTextureWithDescriptor through the
        // iosurface variant (the known-working path). Create a chroot-
        // local IOSurface sized to the descriptor, then delegate to
        // hooked_newTextureWithDescriptor:iosurface:plane: which goes
        // through the iosurface-init code path (avoids the missing
        // selector cascade in -[AGXTexture initWithDevice:desc:
        // isSuballocDisabled:]).
        //
        // EXCEPTION: memoryless textures (storageMode = 3). SkyLight's
        // AddMemorylessTarget at MetalContext.mm:918 asserts that the
        // returned texture is a memoryless target; IOSurface-backed
        // textures have real memory, so the assert fails. For memoryless
        // requests, swap storageMode to Private (2) — same lifecycle
        // characteristics from SkyLight's POV (no CPU access), but
        // backed by real GPU memory (transparent to caller).
        // 2026-06-20 — Memoryless texture handling research notes:
        //
        // What memoryless IS (Apple TBDR architecture, Metal docs):
        //   storageMode = MTLStorageModeMemoryless (3): the texture has
        //   NO system memory backing.  Tile memory is allocated by the
        //   AGX scheduler at render-pass-encode time; tile SRAM is reused
        //   across passes.  Texture metadata (size, format, usage) lives
        //   in CPU memory; pixel storage lives ONLY in on-chip SRAM
        //   during one render pass.
        //
        // What goes wrong if we ROUTE-IOSURF a memoryless request:
        //   We allocate a 31 MB IOSurface for a 2388×1668 RGBA16Float
        //   "memoryless" texture — totally defeating the point.  CA::OGL::
        //   MetalContext::add_memoryless_textures requests one per composite
        //   cycle, cumulative 46+ GB → 5120 MB WS watermark trip.
        //
        // Correct fix: route memoryless requests THROUGH the native
        // AGX-side newTextureWithDescriptor (no IOSurface).  Post-swizzle,
        // [self hooked_newTextureWithDescriptor:desc] calls the original
        // AGXG13GFamilyDevice IMP.  That IMP eventually reaches AGXTexture
        // init which queries [super isMemoryless] on the IOGPUMetalTexture
        // instance; iff storageMode=3 in the descriptor, the texture
        // creation skips physical backing allocation and stays as pure
        // tile-memory metadata (handled by iOS AGX kernel at render time).
        NSUInteger storageMode = [desc respondsToSelector:@selector(storageMode)]
                                 ? [desc storageMode] : 0;
        NSUInteger pf = [desc respondsToSelector:@selector(pixelFormat)]
                        ? [desc pixelFormat] : 80; // MTLPixelFormatBGRA8Unorm default

        // A compressed texture cannot use the byte-per-pixel IOSurface path.
        // Try the driver's real block layout before the mipmap gate below.
        // The ordering matters: a mipmapped BC texture is still compressed,
        // so classifying it merely as "mipmapped" loses the evidence needed
        // to distinguish an unsupported block format from a generic mip
        // allocation failure.
        if (macws_pixel_format_is_block_compressed(pf)) {
            id<MTLTexture> tex =
                [self hooked_newTextureWithDescriptor:desc];
            if (!tex && storageMode == MTLStorageModeShared) {
                // macOS permits CPU-visible block-compressed resources on
                // unified memory, while this iOS 16.3 AGX image rejects that
                // storage combination. Runtime A/B with Asphalt preserved the
                // exact BC format, dimensions, mip topology and usage: Shared
                // returned nil repeatedly, Private succeeded for BC1/3/5, and
                // the game completed texture prewarming plus its network/UI
                // initialization without an upload validation failure. Keep
                // all content semantics and translate only the unsupported
                // storage contract at the device boundary.
                MTLTextureDescriptor *native = [desc copy];
                native.storageMode = MTLStorageModePrivate;
                tex = [self hooked_newTextureWithDescriptor:native];
            }
            if (!tex) {
                macws_log_mtldesc(desc, NULL, 0,
                                  "plain.COMPRESSED-NATIVE.NIL");
            }
            return tex;
        }

        // Metal's IOSurface initializer structurally forbids mipmapped
        // textures.  Chromium/Skia requests a 2048x2048 R8 texture with 12
        // levels on the Apple iPad page; sending that descriptor into the
        // compatibility initializer aborts the entire GPU process in
        // _mtlValidateStrideTextureParameters.  Preserve the descriptor and
        // try the real AGX plain allocator instead.  This is not a mip-count
        // bypass: a nil result is propagated so the caller can take its own
        // fallback rather than receiving an object with a false layout.
        NSUInteger mipmapLevelCount =
            [desc respondsToSelector:@selector(mipmapLevelCount)]
                ? [desc mipmapLevelCount] : 1;
        if (mipmapLevelCount > 1) {
            static _Atomic uint64_t mipNativeAttempts = 0;
            BOOL diagnostics = macws_runtime_diagnostics_enabled();
            uint64_t attempt = diagnostics
                ? atomic_fetch_add_explicit(
                    &mipNativeAttempts, 1, memory_order_relaxed) + 1 : 0;
            if (attempt && attempt <= 12) {
                fprintf(stderr,
                    "#### MTL_TEX MIP-NATIVE attempt=%llu w=%lu h=%lu "
                    "pf=%lu mips=%lu storage=%lu usage=%#lx\n",
                    (unsigned long long)attempt,
                    (unsigned long)([desc respondsToSelector:@selector(width)]
                        ? [desc width] : 0),
                    (unsigned long)([desc respondsToSelector:@selector(height)]
                        ? [desc height] : 0),
                    (unsigned long)pf, (unsigned long)mipmapLevelCount,
                    (unsigned long)storageMode,
                    (unsigned long)([desc respondsToSelector:@selector(usage)]
                        ? [desc usage] : 0));
                void *frames[20] = {0};
                int count = backtrace(frames, 20);
                backtrace_symbols_fd(frames, count, STDERR_FILENO);
            }
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (diagnostics) {
                fprintf(stderr,
                    "#### MTL_TEX MIP-NATIVE result attempt=%llu tex=%p class=%s\n",
                    (unsigned long long)attempt, (void *)tex,
                    tex ? class_getName([tex class]) : "(nil)");
            }
            if (!tex) {
                // Failure-only in production: Chromium reports this as the
                // generic GL_OUT_OF_MEMORY/MakeTexture error, which otherwise
                // loses the descriptor that selected this native path.
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.MIP-NATIVE.NIL");
            }
            return tex;
        }

        // Memoryless textures are tile-memory allocations and cannot have an
        // IOSurface backing.  Route them before the non-2D compatibility gate
        // so a multisample descriptor keeps its required texture type and
        // sampleCount pairing intact.
        if (storageMode == 3 /* MTLStorageModeMemoryless */) {
            static int memless_native_log = 0;
            BOOL diagnostics = macws_runtime_diagnostics_enabled();
            if (diagnostics && memless_native_log++ < 4) {
                fprintf(stderr,
                    "#### MTL_TEX plain MEMORYLESS: routing to native AGX path "
                    "(no IOSurface — tile-memory-only) w=%lu h=%lu pf=%lu\n",
                    (unsigned long)([desc respondsToSelector:@selector(width)] ? [desc width] : 0),
                    (unsigned long)([desc respondsToSelector:@selector(height)] ? [desc height] : 0),
                    (unsigned long)pf);
            }
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (diagnostics && memless_native_log < 6) {
                fprintf(stderr,
                    "#### MTL_TEX plain MEMORYLESS native result: %p "
                    "(class=%s storageMode=%lu length=%lu)\n",
                    (void *)tex,
                    tex ? class_getName([tex class]) : "(nil)",
                    tex && [tex respondsToSelector:@selector(storageMode)]
                        ? (unsigned long)[tex storageMode] : 999UL,
                    tex && [tex respondsToSelector:@selector(length)]
                        ? (unsigned long)[(id)tex length] : 999UL);
            }
            if (!tex) {
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.MEMORYLESS.NIL");
            }
            return tex;
        }

        // Metal forbids IOSurface-backed depth and stencil textures.  ANGLE
        // requests these for WebGL framebuffer attachments, so preserve the
        // caller's descriptor and let the real AGX device allocate them.
        // Values are the public MTLPixelFormat depth/stencil family.
        BOOL depthOrStencil =
            (pf == 250 || pf == 252 || pf == 253 || pf == 255 ||
             pf == 260 || pf == 261 || pf == 262);
        if (depthOrStencil) {
            static int depth_stencil_log = 0;
            BOOL diagnostics = macws_runtime_diagnostics_enabled();
            if (diagnostics && depth_stencil_log++ < 8) {
                fprintf(stderr,
                    "#### MTL_TEX plain DEPTH-STENCIL: pf=%lu routing to "
                    "native AGX path (IOSurface backing is invalid)\n",
                    (unsigned long)pf);
            }
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (diagnostics && depth_stencil_log < 10) {
                fprintf(stderr,
                    "#### MTL_TEX plain DEPTH-STENCIL native result: %p class=%s\n",
                    (void *)tex, tex ? class_getName([tex class]) : "(nil)");
            }
            if (!tex) {
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.DEPTH-STENCIL.NIL");
            }
            return tex;
        }
        // Texture-type gate: this compatibility allocator creates one
        // ordinary 2D IOSurface plane.  It therefore represents only a 2D
        // texture, not an array of independently addressable slices.  Metal's
        // real IOSurface validator permits only a specially constructed
        // *linear* 2DArray; routing an ordinary Chromium 2DArray through our
        // one-plane allocation aborts the GPU process at
        // _mtlValidateStrideTextureParameters:1843 with
        // "textureType (MTLTextureType2DArray) disallowed".  Preserve every
        // array descriptor field and let the native AGX plain allocator own
        // the array storage instead.
        // CA can request 3D / Cube / Multisample textures for compositor
        // intermediates — wrapping those in an IOSurface SIGABRTs WS.
        // For any non-2D/non-2DArray request, fall through to the native
        // AGXG13GFamilyDevice path (which handles the type correctly).
        NSUInteger texType = [desc respondsToSelector:@selector(textureType)]
                             ? [desc textureType] : 2 /* default 2D */;
        if (texType == 3 /* MTLTextureType2DArray */) {
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (!tex) {
                // Failure-only production evidence.  Returning nil preserves
                // the Metal contract and lets Chromium choose its fallback;
                // fabricating a one-slice IOSurface texture would corrupt the
                // descriptor's array semantics.
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.2D-ARRAY-NATIVE.NIL");
            }
            return tex;
        }
        // MTLTextureType2DMultisample (4) and
        // MTLTextureType2DMultisampleArray (8) have a hard semantic link to
        // sampleCount > 1.  Downgrading either descriptor to plain 2D while
        // retaining sampleCount creates an invalid descriptor and aborts in
        // -[MTLTextureDescriptorInternal validateWithDevice:].  These are
        // render-target allocations rather than shareable display surfaces,
        // so preserve the descriptor verbatim and let the native AGX device
        // allocate the multisample storage.
        if (texType == 4 /* MTLTextureType2DMultisample */ ||
            texType == 8 /* MTLTextureType2DMultisampleArray */) {
            static int multisample_native_log = 0;
            BOOL diagnostics = macws_runtime_diagnostics_enabled();
            if (diagnostics && multisample_native_log++ < 8) {
                fprintf(stderr,
                    "#### MTL_TEX plain MULTISAMPLE: texType=%lu sampleCount=%lu "
                    "routing to native AGX path (descriptor preserved)\n",
                    (unsigned long)texType,
                    (unsigned long)([desc respondsToSelector:@selector(sampleCount)]
                        ? [desc sampleCount] : 0));
            }
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (diagnostics && multisample_native_log < 10) {
                fprintf(stderr,
                    "#### MTL_TEX plain MULTISAMPLE native result: %p class=%s\n",
                    (void *)tex, tex ? class_getName([tex class]) : "(nil)");
            }
            if (!tex) {
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.MULTISAMPLE.NIL");
            }
            return tex;
        }
        if (texType != 2 /* 2D */) {
            // Runtime-confirmed by WindowServer-2026-08-09-225014.ips plus
            // WindowServer.err: the historical fallback changed a legitimate
            // six-face descriptor to MTLTextureType2D while retaining
            // arrayLength=6. Metal rejected that internally inconsistent
            // descriptor in validateWithDevice: from
            // MetalContext::GetColorConverter. IOSurface compatibility is
            // structurally 2D-only, so Cube/3D/MSAA semantics cannot be
            // represented by changing one enum. Preserve the caller's exact
            // descriptor and use the real AGX plain allocator; a nil result is
            // propagated rather than returning a texture with false shape and
            // sampling semantics.
            id<MTLTexture> tex = [self hooked_newTextureWithDescriptor:desc];
            if (!tex)
                macws_log_mtldesc(desc, NULL, 0,
                    "plain.NON-2D-NATIVE.NIL");
            return tex;
        }
        NSUInteger width  = [desc respondsToSelector:@selector(width)]
                            ? [desc width] : 0;
        NSUInteger height = [desc respondsToSelector:@selector(height)]
                            ? [desc height] : 0;
        if (width == 0 || height == 0) {
            static int bad_log = 0;
            if (bad_log++ < 4)
                fprintf(stderr,
                    "#### MTL_TEX plain ROUTE-IOSURF: bad descriptor "
                    "(w=%lu h=%lu) — returning nil\n",
                    (unsigned long)width, (unsigned long)height);
            return nil;
        }
        // Map MTLPixelFormat → IOSurface layout.  Unknown ordinary formats
        // retain the historical BGRA8 fallback, but private pf550 must use its
        // real two-plane compressed layout: a linear BGRA allocation produces
        // a resource request whose format metadata disagrees with its backing.
        uint32_t fmt4cc  = 'BGRA';
        NSUInteger bpe   = 4;
        BOOL compressedPF550 = (pf == 550);
        // Common cases:
        //   MTLPixelFormatBGRA8Unorm        = 80   (default)
        //   MTLPixelFormatRGBA8Unorm        = 70
        //   MTLPixelFormatBGRA8Unorm_sRGB   = 81
        //   MTLPixelFormatRGBA16Float       = 115  (8 bpp)
        //   MTLPixelFormatRGBA32Float       = 125  (16 bpp)
        //   MTLPixelFormatR8Unorm           = 10   (1 bpp)
        if (compressedPF550) {
            fmt4cc = 643969848; // private '&b38' IOSurface format
            // Used only to make the pool key reflect the captured type-0x82
            // request's +0x13 field.  The actual allocation is plane/tile
            // based and is constructed by macws_create_pf550_scratch_surface.
            bpe = 2;
        }
        else if (pf == 552 || pf == 553) {
            // MTLPixelFormatBGRA10_XR[_sRGB] is a 64-bit extended-range
            // format (four 10-bit values stored in the MSBs of 16-bit
            // little-endian components).  Apple's SDK pairs that layout
            // with kCVPixelFormatType_40ARGBLEWideGamut ('w40a').
            // Runtime validation requires bytesPerRow >= width * 8; the
            // old unknown-format default used 4 B/px and aborted at
            // _mtlValidateStrideTextureParameters for 64x64 (256 < 512).
            fmt4cc = 'w40a'; bpe = 8;
        }
        else if (pf == 110) {
            // MTLPixelFormatRGBA16Unorm is eight bytes per pixel.  The former
            // BGRA8 default allocated a 512-byte row for Stray's 98x64
            // subsurface-profile texture, while Metal correctly required
            // 98*8 = 784 bytes and aborted.  CoreVideo's 'l64r' is the exact
            // little-endian 64-bit RGBA/full-range-16-bit layout.  A native
            // iOS control using this same descriptor produced bpr=896 and a
            // real AGXG13GFamilyTexture.
            fmt4cc = 'l64r'; bpe = 8;
        }
        else if (pf == 115) { fmt4cc = 'RGhA'; bpe = 8; }
        else if (pf == 125) {
            // Chromium 148 creates a 16x16 RGBA32Float Viz texture during
            // GPU-process initialization.  Treating this as the historical
            // BGRA8 fallback gives the IOSurface a 128-byte stride, while
            // Metal correctly requires 16 pixels * 16 B/px = 256 bytes and
            // aborts in _mtlValidateStrideTextureParameters.  'RGfA' is the
            // CoreVideo/IOSurface 128-bit RGBA-float layout.
            fmt4cc = 'RGfA'; bpe = 16;
        }
        else if (pf == 10) { fmt4cc = 'L008'; bpe = 1; }
        else if (pf == 70 || pf == 71) { fmt4cc = 'RGBA'; bpe = 4; }
        // Lifetime-aware compatibility pool.  The former implementation
        // cached one surface and one texture per key forever.  Runtime A/B
        // proved that equal-shaped SkyLight/AppKit intermediates overlap in
        // time; returning the same object gave two independent render passes
        // one storage allocation and produced deterministic 64-pixel holes.
        //
        // Each entry below owns one IOSurface and one Metal texture.  The
        // dictionary is the texture's stable pool retain.  At insertion the
        // `new...` result also has exactly one caller-owned retain, so
        // baseline = current retain count - 1.  An entry is reusable only
        // after its count returns to that measured baseline.  A cache hit adds
        // one CFRetain, preserving the Objective-C `new` ownership contract.
        // If all entries are busy we allocate another entry; aliasing is never
        // used as a memory-pressure fallback.
        //
        // Idle entries are globally LRU-evicted above 256 MiB.  Busy entries
        // may temporarily exceed the budget because destroying or aliasing a
        // live Metal object would violate the caller's lifetime contract.
        NSString *poolKey = [NSString stringWithFormat:@"%lux%lu-pf%lu-bpe%lu-fcc%u",
            (unsigned long)width, (unsigned long)height,
            (unsigned long)pf, (unsigned long)bpe, (unsigned)fmt4cc];
        static NSMutableDictionary<NSString *, NSMutableArray *> *leasePool = nil;
        static dispatch_once_t leasePoolOnce;
        static NSUInteger leasePoolBytes = 0;
        static uint64_t leaseClock = 0;
        static uint64_t leaseHitCount = 0;
        static uint64_t leaseNewCount = 0;
        static uint64_t leaseEvictCount = 0;
        dispatch_once(&leasePoolOnce, ^{
            leasePool = [NSMutableDictionary new];
        });

        IOSurfaceRef surf = NULL;
        id<MTLTexture> tex = nil;
        @synchronized(leasePool) {
            leaseClock++;
            NSMutableArray *shapeEntries = leasePool[poolKey];
            for (NSMutableDictionary *entry in shapeEntries) {
                id<MTLTexture> candidate = entry[@"texture"];
                CFIndex baseline = [entry[@"baseline"] longLongValue];
                CFIndex current = candidate
                    ? CFGetRetainCount((__bridge CFTypeRef)candidate) : 0;
                if (candidate && current <= baseline) {
                    // Give this invocation the +1 promised by the `new`
                    // method family before another thread can inspect it.
                    CFRetain((__bridge CFTypeRef)candidate);
                    entry[@"last"] = @(leaseClock);
                    tex = candidate;
                    surf = (IOSurfaceRef)[entry[@"surface"] pointerValue];
                    if (macws_runtime_diagnostics_enabled()) leaseHitCount++;
                    if (leaseHitCount &&
                        (leaseHitCount <= 48 ||
                         (leaseHitCount % 1200) == 0)) {
                        fprintf(stderr,
                            "#### MTL_TEX LEASE-HIT #%llu key=%s entry=%p "
                            "surf=%p tex=%p retain=%ld baseline=%ld "
                            "shapeEntries=%lu pool=%luMB\n",
                            (unsigned long long)leaseHitCount,
                            [poolKey UTF8String], (void *)entry, (void *)surf,
                            (void *)tex, (long)current, (long)baseline,
                            (unsigned long)[shapeEntries count],
                            (unsigned long)(leasePoolBytes / (1024 * 1024)));
                    }
                    break;
                }
            }
            if (!tex) {
                // Preserve the proven non-scanout IOSurface properties.  The
                // surface's create retain becomes the pool entry's ownership;
                // Metal takes its own independent retain while wrapping it.
                if (compressedPF550) {
                    surf = macws_create_pf550_scratch_surface(width, height);
                } else {
                    NSDictionary *props = @{
                        @"IOSurfaceWidth":           @(width),
                        @"IOSurfaceHeight":          @(height),
                        @"IOSurfaceBytesPerElement": @(bpe),
                        @"IOSurfacePixelFormat":     @((uint32_t)fmt4cc),
                        @"IOSurfaceIsGlobal":        @NO,
                        @"IOSurfaceCacheMode":       @0,
                    };
                    surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
                }
                if (surf) {
                    macws_log_plain_texture_surface_layout(
                        desc, surf, bpe, fmt4cc);
                    tex = [self hooked_newTextureWithDescriptor:desc
                                                      iosurface:surf
                                                          plane:0];
                }
                if (!tex) {
                    // Failure-only evidence for the compatibility allocator.
                    // Keep it before CFRelease so the IOSurface geometry and
                    // properties remain readable.  This does not substitute a
                    // resource or suppress the caller-visible nil.
                    fprintf(stderr,
                        "#### MTL_TEX LEASE-ALLOC-NIL key=%s stage=%s "
                        "shapeEntries=%lu pool=%luMB\n",
                        [poolKey UTF8String],
                        surf ? "metal-wrap" : "iosurface-create",
                        (unsigned long)[shapeEntries count],
                        (unsigned long)(leasePoolBytes / (1024 * 1024)));
                    macws_log_mtldesc(desc, surf, 0,
                        "plain.LEASE-ALLOC.NIL");
                    if (surf) CFRelease(surf);
                    surf = NULL;
                } else {
                    if (!shapeEntries) {
                        shapeEntries = [NSMutableArray array];
                        leasePool[poolKey] = shapeEntries;
                    }
                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"surface"] = [NSValue valueWithPointer:(void *)surf];
                    entry[@"texture"] = tex; // stable pool retain
                    CFIndex measured =
                        CFGetRetainCount((__bridge CFTypeRef)tex);
                    CFIndex baseline = measured > 1 ? measured - 1 : 1;
                    NSUInteger allocation = IOSurfaceGetAllocSize(surf);
                    entry[@"baseline"] = @(baseline);
                    entry[@"bytes"] = @(allocation);
                    entry[@"last"] = @(leaseClock);
                    [shapeEntries addObject:entry];
                    leasePoolBytes += allocation;
                    static NSUInteger lastPlainWitnessBucket = 0;
                    NSUInteger plainWitnessBucket =
                        leasePoolBytes / (64U * 1024U * 1024U);
                    if (plainWitnessBucket > lastPlainWitnessBucket) {
                        lastPlainWitnessBucket = plainWitnessBucket;
                        dprintf(STDERR_FILENO,
                            "#### MACWS-MEMORY-WITNESS pool=plain-texture "
                            "idle-and-live=%luMB rss=%lluMB shapes=%lu\n",
                            (unsigned long)(leasePoolBytes /
                                            (1024U * 1024U)),
                            (unsigned long long)(
                                macws_resident_memory_bytes() /
                                (1024U * 1024U)),
                            (unsigned long)[leasePool count]);
                    }
                    if (macws_runtime_diagnostics_enabled()) leaseNewCount++;
                    if (leaseNewCount &&
                        (leaseNewCount <= 64 ||
                         (leaseNewCount % 600) == 0)) {
                        fprintf(stderr,
                            "#### MTL_TEX LEASE-NEW #%llu key=%s entry=%p "
                            "surf=%p tex=%p retain=%ld baseline=%ld bpr=%zu "
                            "alloc=%luKB shapeEntries=%lu pool=%luMB map=%s\n",
                            (unsigned long long)leaseNewCount,
                            [poolKey UTF8String], (void *)entry, (void *)surf,
                            (void *)tex, (long)measured, (long)baseline,
                            IOSurfaceGetBytesPerRow(surf),
                            (unsigned long)(allocation / 1024),
                            (unsigned long)[shapeEntries count],
                            (unsigned long)(leasePoolBytes / (1024 * 1024)),
                            compressedPF550 ? "PF550-COMPRESSED" : "LINEAR");
                    }

                    // This is an idle compatibility cache, not an ownership
                    // budget for live render targets.  Keep the lifetime-safe
                    // retain-count gate but stop holding half a gigabyte of
                    // superseded blur/menu intermediates after their users
                    // finish.  Live entries are never evicted or aliased.
                    const NSUInteger budget = 256U * 1024U * 1024U;
                    while (leasePoolBytes > budget) {
                        NSString *oldestKey = nil;
                        NSMutableArray *oldestArray = nil;
                        NSMutableDictionary *oldestEntry = nil;
                        uint64_t oldestUse = UINT64_MAX;
                        for (NSString *candidateKey in leasePool) {
                            NSMutableArray *candidateArray = leasePool[candidateKey];
                            for (NSMutableDictionary *candidateEntry in candidateArray) {
                                if (candidateEntry == entry) continue;
                                id candidateTexture = candidateEntry[@"texture"];
                                CFIndex candidateBaseline =
                                    [candidateEntry[@"baseline"] longLongValue];
                                CFIndex candidateCount = candidateTexture
                                    ? CFGetRetainCount((__bridge CFTypeRef)
                                                       candidateTexture) : 0;
                                uint64_t candidateUse =
                                    [candidateEntry[@"last"] unsignedLongLongValue];
                                if (candidateTexture &&
                                    candidateCount <= candidateBaseline &&
                                    candidateUse < oldestUse) {
                                    oldestUse = candidateUse;
                                    oldestKey = candidateKey;
                                    oldestArray = candidateArray;
                                    oldestEntry = candidateEntry;
                                }
                            }
                        }
                        if (!oldestEntry) {
                            static uint64_t overBudgetCount = 0;
                            if (macws_runtime_diagnostics_enabled())
                                overBudgetCount++;
                            if (overBudgetCount &&
                                (overBudgetCount <= 12 ||
                                 (overBudgetCount % 300) == 0)) {
                                fprintf(stderr,
                                    "#### MTL_TEX LEASE-OVER-BUDGET #%llu "
                                    "pool=%luMB: every older entry is busy; "
                                    "preserving lifetime correctness\n",
                                    (unsigned long long)overBudgetCount,
                                    (unsigned long)(leasePoolBytes /
                                                    (1024 * 1024)));
                            }
                            break;
                        }
                        IOSurfaceRef evictedSurface = (IOSurfaceRef)
                            [oldestEntry[@"surface"] pointerValue];
                        NSUInteger evictedBytes =
                            [oldestEntry[@"bytes"] unsignedIntegerValue];
                        if (macws_runtime_diagnostics_enabled())
                            leaseEvictCount++;
                        if (leaseEvictCount &&
                            (leaseEvictCount <= 32 ||
                             (leaseEvictCount % 600) == 0)) {
                            fprintf(stderr,
                                "#### MTL_TEX LEASE-EVICT #%llu key=%s "
                                "entry=%p surf=%p bytes=%luKB pool-before=%luMB\n",
                                (unsigned long long)leaseEvictCount,
                                [oldestKey UTF8String], (void *)oldestEntry,
                                (void *)evictedSurface,
                                (unsigned long)(evictedBytes / 1024),
                                (unsigned long)(leasePoolBytes / (1024 * 1024)));
                        }
                        [oldestArray removeObjectIdenticalTo:oldestEntry];
                        if ([oldestArray count] == 0)
                            [leasePool removeObjectForKey:oldestKey];
                        leasePoolBytes = evictedBytes > leasePoolBytes
                            ? 0 : leasePoolBytes - evictedBytes;
                        if (evictedSurface) CFRelease(evictedSurface);
                    }
                }
            }
        }
        if (!surf || !tex) return nil;

        // Read-only postcondition audit for the original Apple initializer.
        if (tex) {
            macws_audit_iosurface_texture_mapping(
                tex, surf, 0, desc.width, desc.height, desc.pixelFormat);
            if (compressedPF550)
                macws_schedule_small_pf550_probe(tex);
        }
        // Read-path probe: also track surfaces arriving via the
        // AGXG13GFamilyDevice swizzle (different entry point than the
        // IOGPUMetalDevice iosurface variant). See macws_disp_fill_track.
        macws_disp_fill_track(tex, surf);
        // Do not release `surf` here.  Its create retain is owned by the pool
        // entry and released exactly once when that idle entry is evicted.
        return tex;
    }
    id<MTLTexture> result = [self hooked_newTextureWithDescriptor:desc];
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/plain.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, NULL, 0, "plain.NIL");
    }
    return result;
}

// ─── Tile-pipeline → render-pipeline converter ──────────────────────────────
// MTLSimDevice's `newRenderPipelineStateWithTileDescriptor:options:reflection:
// error:` MTLReportFailure-aborts WS. Swizzled onto MTLSimDevice; converts
// the MTLTileRenderPipelineDescriptor into an MTLRenderPipelineDescriptor
// (tileFunction → fragmentFunction, copy color attachments + sample count)
// and creates a regular MTLRenderPipelineState. BlurState::tile_downsample
// stores this in PingPongState and the subsequent draw runs through a
// regular MTLRenderCommandEncoder. Tile-specific shader intrinsics will not
// behave the same way they would on a real tile pipeline, but the BlurState
// flow does NOT short-circuit on nil and the destination texture DOES get
// written, so vibrancy panels render with content instead of solid black.
- (id)hooked_newRenderPipelineStateWithTileDescriptor:(id)tileDesc
                                              options:(NSUInteger)opt
                                           reflection:(id *)refl
                                                error:(NSError **)err {
    static int log_count = 0;
    if (log_count < 4) {
        log_count++;
        fprintf(stderr, "#### MTLSim tile-pipeline req → converting to render-pipeline\n");
    }

    MTLRenderPipelineDescriptor *rdesc = [[MTLRenderPipelineDescriptor alloc] init];
    if ([tileDesc respondsToSelector:@selector(label)]) {
        rdesc.label = [tileDesc performSelector:@selector(label)] ?: @"TileFallback";
    }

    // Use QuartzCore's own non-tile downsample-blur shaders. Their default
    // .metallib at /System/Library/Frameworks/QuartzCore.framework/Versions/A/
    // Resources/default.metallib defines `downsample_blur_4_frag_lpf` and
    // `downsample_blur_vert_lpf` for exactly this purpose — the non-tile
    // fallback path that QuartzCore uses on devices without tile rendering.
    // These shaders are pre-compiled and DO compile in chroot (no source
    // compilation needed).
    static dispatch_once_t qc_lib_once;
    static id<MTLLibrary> qc_lib = nil;
    static id<MTLFunction> qc_frag = nil;
    dispatch_once(&qc_lib_once, ^{
        NSURL *qcurl = [NSURL fileURLWithPath:
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *lerr = nil;
        qc_lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
        if (qc_lib) {
            qc_frag = [qc_lib newFunctionWithName:@"downsample_blur_4_frag_lpf"];
            fprintf(stderr, "#### tile-pipeline: QC frag = %p (downsample_blur_4_frag_lpf)\n",
                    (void *)qc_frag);
        }
    });
    if (qc_frag) {
        rdesc.fragmentFunction = qc_frag;
    } else if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
        // Last-resort: use the tile function as fragment (will likely fail
        // to compile due to imageblock intrinsics, but we already log that).
        id tileFn = [tileDesc performSelector:@selector(tileFunction)];
        rdesc.fragmentFunction = (id<MTLFunction>)tileFn;
    }
    // Tile pipelines have no vertex stage but MTLRenderPipelineDescriptor
    // validation REQUIRES a vertex function. Source-level compilation fails
    // in chroot (`This library format is not supported on this platform`),
    // so try a pre-existing library route instead.
    //
    // Try device's default library + the tile descriptor's tileFunction's
    // own library (the same .metallib that contains the tile fragment also
    // usually has a vertex helper). If both fail, return nil + NSError.
    static dispatch_once_t vfn_once;
    static id<MTLFunction> cached_vfn = nil;
    static NSArray<NSString *> *cand_names = nil;
    dispatch_once(&vfn_once, ^{
        cand_names = @[
            @"vertex_passthrough", @"vertexPassthrough",
            @"passthrough_vertex", @"passthroughVertex",
            @"PassthroughVertex", @"passthrough",
            @"fs_vertex", @"fullscreen_vertex", @"fullscreenVertex",
            @"main_vertex", @"vert_main", @"main0",
        ];
    });
    if (!cached_vfn) {
        // First: try the tile function's own library (BlurState's tile
        // shader is in QuartzCore's default.metallib, which also exposes
        // std_vert0_lpf / std_vert1_lpf / upsample_vert_lpf / etc.).
        id tileFn = nil;
        if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
            tileFn = [tileDesc performSelector:@selector(tileFunction)];
        }
        // Order matters: downsample_blur_vert_lpf provides the texcoord0
        // output that downsample_blur_4_frag_lpf reads. std_vert0_lpf only
        // emits position and causes "Fragment input mismatching" errors.
        NSArray<NSString *> *qc_names = @[
            @"downsample_blur_vert_lpf",
            @"upsample_vert_lpf",
            @"std_vert1_lpf", @"std_vert0_lpf",
            @"read_surf_vert",
        ];
        if (tileFn && [tileFn respondsToSelector:@selector(library)]) {
            id lib = [tileFn performSelector:@selector(library)];
            for (NSString *nm in qc_names) {
                id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                if (f) { cached_vfn = f; break; }
            }
            if (!cached_vfn) {
                for (NSString *nm in cand_names) {
                    id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                    if (f) { cached_vfn = f; break; }
                }
            }
        }
        // Second: load QuartzCore's default.metallib directly by URL.
        if (!cached_vfn) {
            @try {
                NSURL *qcurl = [NSURL fileURLWithPath:
                    @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
                NSError *lerr = nil;
                id<MTLLibrary> lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
                if (lib) {
                    for (NSString *nm in qc_names) {
                        id<MTLFunction> f = [lib newFunctionWithName:nm];
                        if (f) { cached_vfn = f; break; }
                    }
                } else if (lerr) {
                    fprintf(stderr, "#### tile-pipeline: QC metallib load err: %s\n",
                            [[lerr localizedDescription] UTF8String]);
                }
            } @catch (NSException *e) {}
        }
        fprintf(stderr, "#### tile-pipeline: vertex fn lookup = %p (name=%s)\n",
                (void *)cached_vfn,
                cached_vfn ? [[cached_vfn name] UTF8String] : "(none)");
    }
    if (cached_vfn) {
        rdesc.vertexFunction = cached_vfn;
        NSArray *attrs = [cached_vfn performSelector:@selector(vertexAttributes)];
        if (attrs && [attrs count] > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            // Log all attributes so we know what to pre-populate for draw.
            for (id a in attrs) {
                NSUInteger idx = (NSUInteger)[[a valueForKey:@"attributeIndex"] unsignedLongValue];
                NSUInteger attrType = (NSUInteger)[[a valueForKey:@"attributeType"] unsignedLongValue];
                NSString *nm = [a valueForKey:@"name"];
                fprintf(stderr,
                    "#### blur-trace vertex attr[%lu]: name=%s type=%lu\n",
                    (unsigned long)idx,
                    nm ? [nm UTF8String] : "(no name)",
                    (unsigned long)attrType);
                // All attributes use buffer idx 0 (we'll populate one buffer
                // with all needed data per vertex in dispatchThreadsPerTile).
                vd.attributes[idx].format = MTLVertexFormatFloat4;
                vd.attributes[idx].offset = idx * 16;
                vd.attributes[idx].bufferIndex = 30;  // high slot to avoid clash
            }
            vd.layouts[30].stride = [attrs count] * 16;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[30].stepRate = 1;
            rdesc.vertexDescriptor = vd;
        }
    } else {
        if (err) *err = [NSError errorWithDomain:@"MTLDevice" code:0
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   @"No passthrough vertex function available"}];
        return nil;
    }

    if ([tileDesc respondsToSelector:@selector(colorAttachments)]) {
        id colAtts = [tileDesc performSelector:@selector(colorAttachments)];
        for (NSUInteger i = 0; i < 8; i++) {
            id src = nil;
            @try { src = [colAtts objectAtIndexedSubscript:i]; } @catch (NSException *e) { break; }
            if (!src) continue;
            MTLPixelFormat fmt = MTLPixelFormatInvalid;
            @try { fmt = (MTLPixelFormat)[[src valueForKey:@"pixelFormat"] unsignedLongValue]; } @catch (NSException *e) {}
            if (fmt == MTLPixelFormatInvalid) continue;
            rdesc.colorAttachments[i].pixelFormat = fmt;
        }
    }
    if ([tileDesc respondsToSelector:@selector(rasterSampleCount)]) {
        @try {
            rdesc.rasterSampleCount = (NSUInteger)[[tileDesc valueForKey:@"rasterSampleCount"] unsignedLongValue] ?: 1;
        } @catch (NSException *e) { rdesc.rasterSampleCount = 1; }
    }

    NSError *e2 = nil;
    id<MTLRenderPipelineState> result =
        [(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:rdesc
                                                          options:opt
                                                       reflection:nil
                                                            error:&e2];
    if (refl) *refl = nil;
    if (!result) {
        // Last resort: nil + NSError. WS stays alive; BlurState bails out
        // and the panel reverts to defensive solid color (still no abort).
        if (err) *err = e2 ?: [NSError errorWithDomain:@"MTLDevice" code:0
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Tile pipeline conversion failed"}];
        static int fail_count = 0;
        if (fail_count++ < 4) {
            fprintf(stderr, "#### tile-pipeline conversion FAILED: %s\n",
                    e2 ? [[e2 localizedDescription] UTF8String] : "(no error)");
        }
        return nil;
    }
    if (err) *err = nil;
    return result;
}
@end
#endif // MTLFakeDevice static class (off for arm64e on-device)

// Forward declarations for AGX init redirect (definitions below the hook).
static void install_agx_init_redirect(Class agx);

%hookf(Class, getMetalPluginClassForService, int service) {
    // MACWS_AGX_NATIVE=1: both slices return the real AGX device class.
    // dlopen the AGXMetal13_3 bundle on demand so its ObjC classes register,
    // then look up AGXG13GFamilyDevice.
    static int agx_once = 0;
    static Class agx_cls = Nil;
    if (getenv("MACWS_AGX_NATIVE")) {
        if (!agx_once) {
            agx_once = 1;
            // Pre-load IOGPU so its symbols are in the address space when
            // dyld binds AGXMetal13_3's cross-image references. AGXMetal13_3
            // calls IOGPU pool-allocator / IOGPUMetalCommonResource functions
            // through __got/__auth_got slots; if dyld can't resolve them at
            // bind time, the slots end up null and Mempool::grow's lambda
            // tail-jumps into garbage (see memory:
            // agx-mempool-grow-fault-decomposed and the lambda BL NOP fix in
            // mac_hooks.m). Force-loading IOGPU first lets the binder do its
            // job for those refs.
            const char *iogpuPaths[] = {
                "/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU",
                NULL
            };
            void *iogpu = NULL;
            for (int i = 0; iogpuPaths[i]; i++) {
                iogpu = dlopen(iogpuPaths[i], RTLD_GLOBAL | RTLD_NOW);
                if (iogpu) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE pre-loaded IOGPU via %s -> %p\n",
                        iogpuPaths[i], iogpu);
                    break;
                }
            }
            if (!iogpu) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE could NOT pre-load IOGPU: %s\n", dlerror());
            }
            // Verify some critical IOGPU symbols are resolvable
            const char *probeSyms[] = {
                "IOGPUResourceCreate",
                "IOGPUMetalCommonResourceCreate",
                "IOGPUDeviceCreateWithAPIProperty",
                "_IOGPUMetalAllocateResource",
                "IOGPUMetalAllocateResource",
                NULL
            };
            for (int i = 0; probeSyms[i]; i++) {
                void *p = dlsym(RTLD_DEFAULT, probeSyms[i]);
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlsym(%s) = %p\n", probeSyms[i], p);
            }

            void *h = dlopen("/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3", RTLD_NOW);
            if (!h) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 FAILED: %s\n", dlerror());
            } else {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 OK h=%p\n", h);
            }
            // dlopen on the inner binary does NOT register an NSBundle. AGX's
            // own getBundle() iterates [NSBundle allBundles] looking for one
            // whose identifier contains "AGXMetal13_3" — without an explicit
            // bundleWithPath: the list is empty, so getBundle returns nil and
            // setupCompiler:'s pathForResource:@"ds" ofType:@"g13g" fails
            // (FATAL: driver shader binary file not found), leaving
            // Device->0x318 (the Compiler wrapper) uninitialised → every
            // shader-variant lookup later crashes on null deref.
            // Do not pass an on-device-linked Objective-C constant string
            // across this arm64e Foundation boundary.  Maps runtime-confirmed
            // that __CFConstantStringClassReference was not authenticated for
            // the macOS cache context and PAC-faulted inside
            // -[NSBundle initWithPath:].  Construct the same immutable values
            // through Foundation at runtime, so their isa comes from the live
            // process rather than this injected image's broken constant-
            // string relocation.
            NSString *agxBundlePath = [NSString stringWithUTF8String:
                "/System/Library/Extensions/AGXMetal13_3.bundle"];
            NSBundle *agxBundle = [NSBundle bundleWithPath:agxBundlePath];
            fprintf(stderr, "#### MACWS_AGX_NATIVE +[NSBundle bundleWithPath:AGXMetal13_3.bundle] = %p id=%s\n",
                agxBundle, agxBundle ? [agxBundle.bundleIdentifier UTF8String] : "(nil)");
            if (agxBundle) {
                // [NSBundle load] forces principal class loading + registers
                // the bundle so it appears in +allBundles. We already loaded
                // the binary via dlopen so this is just the metadata side.
                NSError *err = nil;
                BOOL loaded = [agxBundle loadAndReturnError:&err];
                fprintf(stderr, "#### MACWS_AGX_NATIVE bundle loadAndReturnError: %d (err=%s) loaded=%d\n",
                    loaded, err ? [[err description] UTF8String] : "nil",
                    [agxBundle isLoaded]);
                NSString *dsName = [NSString stringWithUTF8String:"ds"];
                NSString *dsType = [NSString stringWithUTF8String:"g13g"];
                NSString *dsPath = [agxBundle pathForResource:dsName
                                                       ofType:dsType];
                fprintf(stderr, "#### MACWS_AGX_NATIVE bundle pathForResource:ds.g13g = %s\n",
                    dsPath ? [dsPath UTF8String] : "(nil)");
            }
            agx_cls = objc_getClass("AGXG13GFamilyDevice");
            fprintf(stderr, "#### MACWS_AGX_NATIVE getMetalPluginClassForService: returning class %s = %p\n",
                agx_cls ? class_getName(agx_cls) : "(nil)", (void*)agx_cls);
            if (agx_cls) {
                install_agx_init_redirect(agx_cls);
            }
        }
        return agx_cls;
    }

#ifdef FORCE_M1_DRIVER
    // FORCE_M1_DRIVER on-device default (env unset): Nil = CPU/sim fallback for stability.
    return Nil;
#else
    return MTLFakeDevice.class;
#endif
}

// When Metal asks the plugin class to instantiate a device, it does:
//   id raw = [pluginClass alloc];
//   [raw initWithAcceleratorPort:port];
//
// MTLFakeDevice has -initWithAcceleratorPort:. AGXG13GFamilyDevice does NOT —
// it has -initWithAcceleratorPort:simultaneousInstances: (two-arg). So Metal's
// single-arg dispatch on AGXG13GFamilyDevice falls through to NSObject (no-op),
// leaving AGX-specific ivars (especially the AGX::G13::Device* at offset 0x3a8)
// uninitialized → crashes later in newBufferWithLength: at +132.
//
// We install the single-arg method on AGXG13GFamilyDevice at runtime via
// class_addMethod (Logos %hook can't add a previously-nonexistent method
// reliably) and have it forward to the 2-arg init.
static id agx_initWithAcceleratorPort_impl(id self, SEL _cmd, int port) {
    fprintf(stderr, "#### MACWS_AGX_NATIVE redirecting AGXG13GFamilyDevice init(port=%d) → 2-arg variant\n", port);
    SEL realSel = sel_registerName("initWithAcceleratorPort:simultaneousInstances:");
    typedef id (*RealInit)(id, SEL, int, uint64_t);
    id dev = ((RealInit)objc_msgSend)(self, realSel, port, 1);
    // AGXG13GDevice's own -initWithAcceleratorPort: calls super-init then
    // [self setupCompiler:0x30010] — the call that allocates Device->0x318
    // (the AGX::Compiler wrapper, used by every shader-variant lookup).
    // We instantiate the parent class directly, so setupCompiler: never
    // runs — Device->0x318 stays null and every find/tryFind*ProgramVariant
    // crashes. Call setupCompiler: explicitly here so the wrapper gets built.
    // Arg 0x30010 = same hardcoded value AGXG13GDevice's init passes.
    if (dev) {
        SEL setupCompilerSel = sel_registerName("setupCompiler:");
        if ([dev respondsToSelector:setupCompilerSel]) {
            ((void (*)(id, SEL, int))objc_msgSend)(dev, setupCompilerSel, 0x30010);
            fprintf(stderr, "#### MACWS_AGX_NATIVE setupCompiler:0x30010 fired (Device=%p)\n", dev);
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE setupCompiler: NOT FOUND on %s\n",
                class_getName([dev class]));
        }
    }
    return dev;
}

// Diag hook on `-[AGXG13GFamilyTexture initImplWithDevice:Descriptor:iosurface:plane:buffer:
//                bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:]`.
// Per-call log of (self_class, iosurface, descriptor.pixelFormat, return value).
// Identifies which calls return nil and correlates to the iosurface.
typedef id (*macws_initimpl_orig_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked);
static macws_initimpl_orig_t macws_orig_initimpl = NULL;

static id macws_hook_initimpl(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked) {
    id result = nil;
    if (macws_orig_initimpl) {
        result = macws_orig_initimpl(self, _cmd, device, descriptor, iosurface,
            plane, buffer, bytesPerRow, allowNPOT, sparsePageSize,
            isCompressedIOSurface, isHeapBacked);
    }
    static int log_count = 0;
    if (log_count < 30) {
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        fprintf(stderr,
            "#### INITIMPL_HOOK self=%p cls=%s ios=%p ios_fcc=%#x desc(pf=%lu w=%lu h=%lu) "
            "buf=%p bpr=%lu npot=%d sparse=%lu compIOS=%d heap=%d → result=%p\n",
            self, class_getName([self class]),
            iosurface, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            buffer, (unsigned long)bytesPerRow,
            (int)allowNPOT, (unsigned long)sparsePageSize,
            (int)isCompressedIOSurface, (int)isHeapBacked,
            result);
        log_count++;
    }
    return result;
}

static void install_agx_initimpl_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE")) return;
    Class tex_cls = objc_getClass("AGXG13GFamilyTexture");
    if (!tex_cls) {
        fprintf(stderr, "#### INITIMPL_HOOK: AGXG13GFamilyTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:"
        "allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:");
    Method m = class_getInstanceMethod(tex_cls, sel);
    if (!m) {
        fprintf(stderr, "#### INITIMPL_HOOK: method not found\n");
        return;
    }
    macws_orig_initimpl = (macws_initimpl_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_initimpl);
    fprintf(stderr, "#### INITIMPL_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_initimpl);
}

// Probe -[IOGPUMetalCommandBuffer commandBufferResourceInfo].
// RenderContext init stores its result at renderContext->0x10. If nil,
// DataBufferAllocator::newCommand crashes 0x114 in dereferencing this->0x10.
// Hook this method to log every call's return; if it returns nil, the next
// step is figuring out why commandBufferStorage->0x300 is unset.
typedef id (*macws_cbri_orig_t)(id self, SEL _cmd);
static macws_cbri_orig_t macws_orig_cbri = NULL;
static id macws_hook_cbri(id self, SEL _cmd) {
    id result = macws_orig_cbri ? macws_orig_cbri(self, _cmd) : nil;
    static int log_count = 0;
    if (log_count < 10) {
        fprintf(stderr,
            "#### CBRI_HOOK self=%p cls=%s → resourceInfo=%p\n",
            self, class_getName([self class]), result);
        log_count++;
    }
    return result;
}

static void install_cbri_probe(void) {
    if (!getenv("MACWS_AGX_NATIVE") ||
        !macws_runtime_diagnostics_enabled()) return;
    // The method lives on IOGPUMetalCommandBuffer (super class). Hook there
    // — AGXG13GFamilyCommandBuffer doesn't override.
    Class cb_cls = objc_getClass("IOGPUMetalCommandBuffer");
    if (!cb_cls) {
        fprintf(stderr, "#### CBRI_HOOK: IOGPUMetalCommandBuffer class not found\n");
        return;
    }
    SEL sel = sel_registerName("commandBufferResourceInfo");
    Method m = class_getInstanceMethod(cb_cls, sel);
    if (!m) {
        fprintf(stderr, "#### CBRI_HOOK: method not found\n");
        return;
    }
    macws_orig_cbri = (macws_cbri_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_cbri);
    fprintf(stderr, "#### CBRI_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_cbri);
}

// Diag hook on `-[IOGPUMetalTexture initWithDevice:descriptor:iosurface:plane:
//                field:args:argsSize:]`. This is the SUPER-INIT dispatched by
// -[AGXTexture initWithDevice:desc:iosurface:plane:] via objc_msgSendSuper2.
// AGXG13GFamilyTexture's initImpl succeeds (verified by INITIMPL_HOOK), so the
// nil-exit happens here at the cbz x0 at static 0x1e5a5af3c. Per the static
// disasm there are only two nil-exit paths after initImpl: super-init returns
// 0 OR validate returns BIT0=0 (we already patched validate to always-YES).
// Therefore super-init MUST be returning 0 — log its args + return.
typedef id (*macws_iogpu_init_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize);
static macws_iogpu_init_t macws_orig_iogpu_init = NULL;

static id macws_hook_iogpu_init(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize) {
    static int log_count = 0;
    // Log BEFORE calling orig — IOGPUMetalTexture's init may zero out self
    // on failure (verified by lldb: self.isa = 0 after orig returns nil),
    // so any [self class] after orig will crash.
    const char *cls_name_before = "?";
    if (log_count < 30) {
        Class c = object_getClass(self);
        cls_name_before = c ? class_getName(c) : "(nil)";
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        // argsSize comes in via stack slot; the caller stores only the low
        // 32 bits (`str w8, [sp]`), so mask off the high garbage.
        NSUInteger argsSize_lo = argsSize & 0xFFFFFFFFu;
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [pre] self=%p cls=%s ios=%p ios_fcc=%#x "
            "desc(pf=%lu w=%lu h=%lu) plane=%lu field=%lu args=%p "
            "argsSize=%lu (raw=%#lx)\n",
            self, cls_name_before,
            iosurface, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            (unsigned long)plane, (unsigned long)field,
            args, (unsigned long)argsSize_lo, (unsigned long)argsSize);
    }
    // Save isa BEFORE calling orig — orig zeros the entire object on
    // failure, which makes any subsequent msgSend on `self` crash.
    uint64_t saved_isa = *(uint64_t *)self;
    id result = nil;
    if (macws_orig_iogpu_init) {
        result = macws_orig_iogpu_init(self, _cmd, device, descriptor,
            iosurface, plane, field, args, argsSize);
    }
    // If orig zeroed our isa, restore it so the caller's super-init bypass
    // hands a usable (if partially-init'd) object back to SkyLight. The
    // texture's IVAR area is uninitialised but its objc identity works:
    // [self class] / [self pixelFormat] / ARC retain/release all dispatch
    // correctly.
    uint64_t isa_after = *(uint64_t *)self;
    if (isa_after == 0 && saved_isa != 0) {
        *(uint64_t *)self = saved_isa;
    }
    if (log_count < 30) {
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [post] self=%p isa_was=%#llx isa_after=%#llx "
            "(restored=%d) → result=%p\n",
            self,
            (unsigned long long)saved_isa,
            (unsigned long long)isa_after,
            isa_after == 0 && saved_isa != 0,
            result);
        log_count++;
    }
    return result;
}

static void install_iogpu_init_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE")) return;
    Class iogpu_cls = objc_getClass("IOGPUMetalTexture");
    if (!iogpu_cls) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: IOGPUMetalTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initWithDevice:descriptor:iosurface:plane:field:args:argsSize:");
    Method m = class_getInstanceMethod(iogpu_cls, sel);
    if (!m) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: method not found\n");
        return;
    }
    macws_orig_iogpu_init = (macws_iogpu_init_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_iogpu_init);
    fprintf(stderr, "#### IOGPU_INIT_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_iogpu_init);
}

#if 0
// ─── REMOVED: render-pipeline shader-substitution fallback ──────────────
//
// Earlier iterations swizzled
// `-[AGXG13GFamilyDevice newRenderPipelineStateWithDescriptor:error:]`
// to retry a failed pipeline build with QuartzCore's
// `downsample_blur_vert_lpf` + `downsample_blur_4_frag_lpf` shader pair
// (loaded from QC's pre-compiled `default.metallib`). The pipeline did
// build — but every CA draw that used a failing spec got the blur
// downsample shaders instead of its intended composite/draw pair, so
// affected layers rendered the wrong content. That's not a fix, it's a
// graphical regression masquerading as one.
//
// The whole block is deleted. The correct path is to make AGXCompilerCore
// actually lower the renamed intrinsic — see the MTLCompilerService
// tweak (MTLCompilerBypassOSCheck/Tweak.x) and the dispatch-table /
// linkMetalRuntime RE writeup there.
typedef id (*macws_pip_orig_t)(id self, SEL _cmd,
    MTLRenderPipelineDescriptor *desc, NSError **err);
static macws_pip_orig_t macws_pip_orig = NULL;
static id<MTLFunction> macws_fb_vfn = nil;
static id<MTLFunction> macws_fb_ffn = nil;
static dispatch_once_t macws_fb_once;
static int macws_fb_logged = 0;

static void macws_build_fallback_shaders(id<MTLDevice> device) {
    dispatch_once(&macws_fb_once, ^{
        // `newLibraryWithSource:` invokes the same AGX compiler that fails
        // on CA's `fract.v3f16.fast` intrinsic, so it ALSO can't compile
        // any new MSL we'd hand it (Error 1 / "library format not
        // supported"). Use a pre-built metallib instead. QuartzCore's
        // own `default.metallib` is shipped with already-lowered AIR
        // and is the same source the tile-pipeline fallback uses; its
        // simple-passthrough pair (`std_vert0_lpf` /
        // `downsample_blur_4_frag_lpf`) is known to survive the
        // chroot AGXMetal13_3 compiler. We accept the visual mismatch.
        NSArray *candidate_paths = @[
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib",
            @"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/default.metallib",
        ];
        // Ordered pairs — each entry is {vertex, fragment} where the
        // vertex shader exposes the outputs the fragment shader reads.
        // The existing tile-pipeline hook discovered std_vert0_lpf only
        // emits position so "downsample_blur_4_frag_lpf" — which reads
        // texcoord0 — won't link against it. We have to pair every
        // fragment with a vertex that publishes its required varyings.
        NSArray *pairs = @[
            @[@"downsample_blur_vert_lpf", @"downsample_blur_4_frag_lpf"],
            @[@"upsample_vert_lpf",        @"upsample_blur_4_frag_lpf"],
            @[@"std_vert1_lpf",            @"std_frag1_lpf"],
            @[@"std_vert0_lpf",            @"std_frag0_lpf"],
        ];
        for (NSString *path in candidate_paths) {
            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *lerr = nil;
            id<MTLLibrary> lib = [device newLibraryWithURL:url
                                                     error:&lerr];
            if (!lib) {
                fprintf(stderr,
                    "#### MACWS_PIPELINE_FALLBACK lib %s load: %s\n",
                    [path UTF8String],
                    lerr ? [[lerr description] UTF8String] : "(no error)");
                continue;
            }
            for (NSArray *pair in pairs) {
                NSString *vn = pair[0];
                NSString *fn = pair[1];
                id<MTLFunction> v = [lib newFunctionWithName:vn];
                id<MTLFunction> f = [lib newFunctionWithName:fn];
                if (v && f) {
                    macws_fb_vfn = v;
                    macws_fb_ffn = f;
                    fprintf(stderr,
                        "#### MACWS_PIPELINE_FALLBACK pair loaded from %s "
                        "vs=%s fs=%s\n",
                        [path UTF8String],
                        [vn UTF8String], [fn UTF8String]);
                    break;
                }
            }
            if (macws_fb_vfn && macws_fb_ffn) break;
            // Reset partial matches and try the next library.
            macws_fb_vfn = nil; macws_fb_ffn = nil;
        }
        if (!macws_fb_vfn || !macws_fb_ffn) {
            fprintf(stderr,
                "#### MACWS_PIPELINE_FALLBACK: no compatible vfn/ffn pair found\n");
        }
    });
}

static id macws_hook_newRenderPipelineState(id self, SEL _cmd,
        MTLRenderPipelineDescriptor *desc, NSError **err) {
    NSError *real_err = nil;
    id result = macws_pip_orig
        ? macws_pip_orig(self, _cmd, desc, err ?: &real_err)
        : nil;
    if (result) return result;
    // Build fallback library the first time we need it.
    macws_build_fallback_shaders((id<MTLDevice>)self);
    if (!macws_fb_vfn || !macws_fb_ffn) {
        // Couldn't build the fallback either; propagate nil + original
        // NSError so the caller's abort_with_payload still has context.
        return nil;
    }
    // Clone the descriptor so we don't mutate the caller's instance.
    MTLRenderPipelineDescriptor *fb = [desc copy];
    fb.vertexFunction = macws_fb_vfn;
    fb.fragmentFunction = macws_fb_ffn;
    // The original descriptor's vertex descriptor was built for the
    // ORIGINAL vertex shader's attribute layout; replacing the shader
    // forces us to publish a matching layout for ours. Mirror what
    // the existing tile-pipeline fallback does: query the fallback
    // vertex function's vertexAttributes (Metal exposes them on the
    // function object), make every attribute a float4 at sequential
    // 16-byte offsets, and wire them all to a single buffer slot
    // (high index 30 to dodge whatever the caller binds).
    @try {
        NSArray *attrs = nil;
        if ([macws_fb_vfn respondsToSelector:@selector(vertexAttributes)]) {
            attrs = [(id)macws_fb_vfn performSelector:@selector(vertexAttributes)];
        }
        if (attrs && [attrs count] > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            for (id a in attrs) {
                NSUInteger idx = 0;
                @try {
                    idx = (NSUInteger)[[a valueForKey:@"attributeIndex"]
                        unsignedLongValue];
                } @catch (NSException *e) {}
                vd.attributes[idx].format = MTLVertexFormatFloat4;
                vd.attributes[idx].offset = idx * 16;
                vd.attributes[idx].bufferIndex = 30;
            }
            vd.layouts[30].stride = [attrs count] * 16;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[30].stepRate = 1;
            fb.vertexDescriptor = vd;
        } else {
            // Shader takes no vertex input — drop any descriptor the
            // caller had set so Metal validation doesn't complain about
            // unused attributes.
            fb.vertexDescriptor = nil;
        }
    } @catch (NSException *e) {
        fb.vertexDescriptor = nil;
    }
    NSError *fb_err = nil;
    id fb_result = macws_pip_orig
        ? macws_pip_orig(self, _cmd, fb, &fb_err) : nil;
    if (macws_fb_logged < 8) {
        macws_fb_logged++;
        const char *desc_lbl = "(no label)";
        @try {
            NSString *lbl = [desc label];
            if (lbl) desc_lbl = [lbl UTF8String];
        } @catch (NSException *e) {}
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK label=\"%s\" orig=nil "
            "fallback=%p err=%s\n",
            desc_lbl, (void*)fb_result,
            fb_err ? [[fb_err description] UTF8String] : "(none)");
    }
    if (err && !*err && real_err) *err = real_err;
    return fb_result;
}

static void macws_install_pipeline_fallback(Class agx) {
    // The fallback substitutes QC's `downsample_blur_vert_lpf` +
    // `downsample_blur_4_frag_lpf` for any pipeline the AGX compiler
    // can't build. That keeps WindowServer alive but draws the wrong
    // content for every affected layer (blur output instead of the
    // intended composite). Default off — the correct fix is the
    // AGCLLVMCtx::compile hook in mac_hooks.m (force AGCFastMathFlags=0
    // so the compiler uses the working buildFract path instead of
    // attempting the unimplemented `agx.air.fract.v3f16.fast` lowering).
    // Leave the substitution available for emergency fall-through via
    // `MACWS_PIPELINE_FALLBACK=1` so the device can be brought up if
    // the fast-math disable ever regresses.
    if (!getenv("MACWS_PIPELINE_FALLBACK")) {
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK off by default (set "
            "MACWS_PIPELINE_FALLBACK=1 to enable QC-shader substitution)\n");
        return;
    }
    SEL sel = @selector(newRenderPipelineStateWithDescriptor:error:);
    Method m = class_getInstanceMethod(agx, sel);
    if (!m) {
        fprintf(stderr,
            "#### MACWS_PIPELINE_FALLBACK: AGX device has no %s, skip\n",
            sel_getName(sel));
        return;
    }
    macws_pip_orig = (macws_pip_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_newRenderPipelineState);
    fprintf(stderr,
        "#### MACWS_PIPELINE_FALLBACK installed on %s (orig=%p)\n",
        class_getName(agx), (void*)macws_pip_orig);
}
#endif // 0 — disabled shader-substitution fallback

// Read-only tile/blur descriptor witness. Runtime method-map evidence from the
// actual macOS 13.4 AGXMetal13_3 image (UUID
// 727C250E-554D-3921-A5B3-48DAE6195B79) anchors the observed entry points:
//
//   AGXG13GFamilyCommandBuffer::renderCommandEncoderWithDescriptor: +0x23008c
//   AGXG13GFamilyRenderContext::setTileTexture:atIndex:              +0x3025a8
//   AGXG13GFamilyRenderContext::setTileTextures:withRange:           +0x302294
//
// The diagnostic is armed only by /private/tmp/macws_tile_descriptor_diag.
// It copies metadata into a fixed ring and calls every original IMP with the
// original arguments. It does not retain textures, mutate descriptors, or
// substitute any protocol result.
typedef struct {
    uintptr_t texture;
    uintptr_t impl;
    uint64_t gpu_mapping;
    uint64_t address;
    uint64_t extended_raw;
    uint64_t extended_low36;
    uint64_t alloc_size;
    uint64_t plane_offset;
    uint64_t plane_size;
    uint64_t header_offset;
    uint64_t header_span;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    uint32_t surface_id;
    int32_t descriptor_offset;
    uint8_t layout;
    uint8_t compressed;
    uint8_t extended;
    uint8_t found;
    uint8_t descriptor_bytes[24];
} macws_tile_texture_snapshot;

typedef struct {
    uint64_t serial;
    uintptr_t encoder;
    uintptr_t command_buffer;
    macws_tile_texture_snapshot target;
} macws_tile_target_entry;

#define MACWS_TILE_TARGET_CAP 512u
static macws_tile_target_entry g_macws_tile_targets[MACWS_TILE_TARGET_CAP];
static pthread_mutex_t g_macws_tile_target_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_macws_tile_target_serial = 0;
static _Atomic uint32_t g_macws_tile_binding_sequence = 0;
static _Atomic uintptr_t g_macws_tile_observed_command_buffers[32];
static _Atomic uint64_t g_macws_tile_observer_serial = 0;

typedef id (*macws_native_render_encoder_fn)(id, SEL, id);
typedef void (*macws_native_set_tile_texture_fn)(id, SEL, id, NSUInteger);
typedef void (*macws_native_set_tile_textures_fn)(id, SEL, const id *, NSRange);
typedef void (*macws_native_update_bind_five_fn)(id, SEL, void *, void *,
                                                 uint64_t, BOOL, BOOL);
static macws_native_render_encoder_fn g_macws_native_render_encoder_orig = NULL;
static macws_native_set_tile_texture_fn g_macws_native_set_tile_texture_orig = NULL;
static macws_native_set_tile_textures_fn g_macws_native_set_tile_textures_orig = NULL;
static macws_native_update_bind_five_fn g_macws_native_update_bind_five_orig = NULL;

static void macws_tile_log_private_texture_methods_once(id texture) {
    if (!texture) return;
    static _Atomic int logged = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&logged, &expected, 1)) return;

    id device = nil;
    @try {
        if ([texture respondsToSelector:@selector(device)]) {
            device = [texture device];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    struct {
        id receiver;
        const char *selector;
    } methods[] = {
        { device, "initNewTextureData:" },
        { texture, "updateBindDataWithAddresses:cpuMetadataAddress:gpuVirtualAddress:isCompressible:shouldInitMetadata:" },
        { texture, "updateBindDataWithAddresses:gpuVirtualAddress:" },
        { texture, "updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:" },
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        Class cls = methods[i].receiver ? [methods[i].receiver class] : Nil;
        SEL selector = sel_registerName(methods[i].selector);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        IMP imp = method ? method_getImplementation(method) : NULL;
        const char *types = method ? method_getTypeEncoding(method) : NULL;
        Dl_info image = {0};
        bool located = imp && dladdr((const void *)imp, &image) != 0;
        uintptr_t static_address = located
            ? (uintptr_t)imp - (uintptr_t)image.dli_fbase + 0x1e53dd000ULL
            : 0;
        fprintf(stderr,
            "#### TILE-PRIVATE-METHOD class=%s selector=%s imp=%p "
            "imageBase=%p static=%#llx types=%s image=%s\n",
            cls ? class_getName(cls) : "(nil)", methods[i].selector,
            (void *)imp, located ? image.dli_fbase : NULL,
            (unsigned long long)static_address,
            types ? types : "(missing)",
            located && image.dli_fname ? image.dli_fname : "(unresolved)");
    }
}

static macws_tile_texture_snapshot macws_tile_snapshot_texture(id texture) {
    macws_tile_texture_snapshot snapshot = {0};
    snapshot.texture = (uintptr_t)(__bridge void *)texture;
    snapshot.descriptor_offset = -1;
    if (!texture) return snapshot;

    NSUInteger width = 0, height = 0, pixel_format = 0;
    IOSurfaceRef surface = NULL;
    @try {
        width = [texture respondsToSelector:@selector(width)]
            ? (NSUInteger)[texture width] : 0;
        height = [texture respondsToSelector:@selector(height)]
            ? (NSUInteger)[texture height] : 0;
        pixel_format = [texture respondsToSelector:@selector(pixelFormat)]
            ? (NSUInteger)[texture pixelFormat] : 0;
        if ([texture respondsToSelector:@selector(iosurface)]) {
            surface = (IOSurfaceRef)[texture iosurface];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    snapshot.width = (uint32_t)width;
    snapshot.height = (uint32_t)height;
    snapshot.pixel_format = (uint32_t)pixel_format;
    snapshot.surface_id = surface ? IOSurfaceGetID(surface) : 0;
    snapshot.alloc_size = surface ? IOSurfaceGetAllocSize(surface) : 0;

    if (pixel_format == 550) {
        macws_tile_log_private_texture_methods_once(texture);
    }
    if (surface && pixel_format == 550) {
        CFDictionaryRef copied = IOSurfaceCopyAllValues(surface);
        if (copied) {
            @try {
                NSDictionary *root = (__bridge NSDictionary *)copied;
                id creation_value = root[@"CreationProperties"];
                NSDictionary *creation =
                    [creation_value isKindOfClass:[NSDictionary class]]
                        ? (NSDictionary *)creation_value : root;
                id planes_value = creation[@"IOSurfacePlaneInfo"];
                if ([planes_value isKindOfClass:[NSArray class]] &&
                    [(NSArray *)planes_value count] != 0) {
                    id plane_value = [(NSArray *)planes_value objectAtIndex:0];
                    if ([plane_value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *plane = (NSDictionary *)plane_value;
                        snapshot.plane_offset = macws_pf550_dict_uint64(
                            plane, @"Offset", @"IOSurfacePlaneOffset");
                        snapshot.plane_size = macws_pf550_dict_uint64(
                            plane, @"Size", @"IOSurfacePlaneSize");
                        snapshot.header_offset = macws_pf550_dict_uint64(
                            plane, @"CompressedTileHeaderRegionOffset",
                            @"IOSurfacePlaneCompressedTileHeaderRegionOffset");
                        uint64_t plane_end = snapshot.plane_offset +
                            snapshot.plane_size;
                        if (plane_end >= snapshot.plane_offset &&
                            snapshot.header_offset >= snapshot.plane_offset &&
                            snapshot.header_offset < plane_end) {
                            snapshot.header_span =
                                plane_end - snapshot.header_offset;
                        }
                    }
                }
            } @catch (NSException *exception) {
                (void)exception;
            }
            CFRelease(copied);
        }
    }

    ptrdiff_t impl_offset = 0x208;
    Ivar ivar = class_getInstanceVariable([texture class], "_impl");
    if (ivar) impl_offset = ivar_getOffset(ivar);
    void *impl = *(void **)((char *)(__bridge void *)texture + impl_offset);
    snapshot.impl = (uintptr_t)impl;
    if (!impl) return snapshot;
    snapshot.gpu_mapping = *(const volatile uint64_t *)((const char *)impl + 0x40);

    macws_texture_descriptor_witness descriptor = {0};
    if (macws_find_texture_descriptor(impl, width, height, &descriptor)) {
        snapshot.found = 1;
        snapshot.descriptor_offset = (int32_t)descriptor.offset;
        snapshot.address = descriptor.address;
        snapshot.extended_raw = descriptor.extended_raw;
        snapshot.extended_low36 = descriptor.extended_low36;
        snapshot.layout = (uint8_t)descriptor.layout;
        snapshot.compressed = (uint8_t)descriptor.compressed;
        snapshot.extended = (uint8_t)descriptor.extended;
        memcpy(snapshot.descriptor_bytes, descriptor.bytes,
               sizeof(snapshot.descriptor_bytes));
    }
    return snapshot;
}

// Observe the actual private producer ABI established by
// method_getTypeEncoding (`v48@0:8^v16^v24Q32B40B44`).  This wrapper forwards
// every original argument unchanged, then copies the finished descriptor.  It
// is installed only with macws_tile_descriptor_diag and is therefore a
// diagnostic witness, not a protocol fix.
static void macws_native_update_bind_five_diag(
        id self, SEL selector, void *cpu_address, void *cpu_metadata_address,
        uint64_t gpu_virtual_address, BOOL is_compressible,
        BOOL should_init_metadata) {
    void *caller = __builtin_return_address(0);
    macws_tile_texture_snapshot before = macws_tile_snapshot_texture(self);
    if (g_macws_native_update_bind_five_orig) {
        g_macws_native_update_bind_five_orig(
            self, selector, cpu_address, cpu_metadata_address,
            gpu_virtual_address, is_compressible, should_init_metadata);
    }

    macws_tile_texture_snapshot snapshot = macws_tile_snapshot_texture(self);
    if (snapshot.pixel_format != 550 ||
        !((snapshot.width == 1140 && snapshot.height == 798) ||
          (snapshot.width == 2388 && snapshot.height == 1668))) {
        return;
    }
    BOOL target_geometry = snapshot.width == 1140 && snapshot.height == 798;
    static _Atomic uint32_t target_logged = 0;
    static _Atomic uint32_t control_logged = 0;
    uint32_t sequence = target_geometry
        ? atomic_fetch_add(&target_logged, 1) + 1
        : atomic_fetch_add(&control_logged, 1) + 1;
    if ((target_geometry && sequence > 32) ||
        (!target_geometry && sequence > 4)) {
        return;
    }

    Dl_info image = {0};
    bool located = caller && dladdr(caller, &image) != 0;
    uintptr_t caller_static = located && image.dli_fname &&
            strstr(image.dli_fname, "AGXMetal13_3")
        ? (uintptr_t)caller - (uintptr_t)image.dli_fbase + 0x1e53dd000ULL
        : 0;
    fprintf(stderr,
        "#### UPDATEBIND-FIVE role=%s #%u tex=%p %ux%u pf=%u surface=%u "
        "cpuAddress=%p cpuMetadata=%p gpuVA=%#llx compressible=%u "
        "initMetadata=%u caller=%p callerStatic=%#llx "
        "gpu40=%#llx address=%#llx extendedLow36=%#llx extendedRaw=%#llx "
        "layout=%u compressed=%u extended=%u alloc=%#llx "
        "headerOffset=%#llx headerSpan=%#llx "
        "beforeFound=%u beforeAddress=%#llx beforeExtendedLow36=%#llx "
        "beforeExtendedRaw=%#llx beforeLayout=%u beforeCompressed=%u "
        "beforeExtended=%u\n",
        target_geometry ? "target-1140" : "control-2388", sequence,
        (__bridge void *)self, snapshot.width, snapshot.height,
        snapshot.pixel_format, snapshot.surface_id, cpu_address,
        cpu_metadata_address, (unsigned long long)gpu_virtual_address,
        (unsigned)is_compressible, (unsigned)should_init_metadata, caller,
        (unsigned long long)caller_static,
        (unsigned long long)snapshot.gpu_mapping,
        (unsigned long long)snapshot.address,
        (unsigned long long)snapshot.extended_low36,
        (unsigned long long)snapshot.extended_raw,
        snapshot.layout, snapshot.compressed, snapshot.extended,
        (unsigned long long)snapshot.alloc_size,
        (unsigned long long)snapshot.header_offset,
        (unsigned long long)snapshot.header_span, before.found,
        (unsigned long long)before.address,
        (unsigned long long)before.extended_low36,
        (unsigned long long)before.extended_raw,
        before.layout, before.compressed, before.extended);
}

static void macws_tile_log_snapshot(uint32_t sequence, const char *role,
                                    uintptr_t encoder, NSUInteger index,
                                    macws_tile_texture_snapshot snapshot,
                                    uint64_t target_serial,
                                    uintptr_t command_buffer) {
    char hex[sizeof(snapshot.descriptor_bytes) * 2 + 1];
    for (size_t i = 0; i < sizeof(snapshot.descriptor_bytes); i++) {
        snprintf(hex + i * 2, 3, "%02x", snapshot.descriptor_bytes[i]);
    }
    fprintf(stderr,
        "#### TILE-DESC #%u role=%s encoder=%#llx index=%lu "
        "targetSerial=%llu commandBuffer=%#llx tex=%#llx impl=%#llx "
        "%ux%u pf=%u surface=%u "
        "gpu40=%#llx found=%u descOff=%#x layout=%u compressed=%u "
        "extended=%u address=%#llx extendedLow36=%#llx "
        "extendedRaw=%#llx alloc=%#llx planeOffset=%#llx "
        "planeSize=%#llx headerOffset=%#llx headerSpan=%#llx bytes=%s\n",
        sequence, role, (unsigned long long)encoder, (unsigned long)index,
        (unsigned long long)target_serial,
        (unsigned long long)command_buffer,
        (unsigned long long)snapshot.texture,
        (unsigned long long)snapshot.impl,
        snapshot.width, snapshot.height, snapshot.pixel_format,
        snapshot.surface_id, (unsigned long long)snapshot.gpu_mapping,
        snapshot.found, snapshot.descriptor_offset,
        snapshot.layout, snapshot.compressed, snapshot.extended,
        (unsigned long long)snapshot.address,
        (unsigned long long)snapshot.extended_low36,
        (unsigned long long)snapshot.extended_raw,
        (unsigned long long)snapshot.alloc_size,
        (unsigned long long)snapshot.plane_offset,
        (unsigned long long)snapshot.plane_size,
        (unsigned long long)snapshot.header_offset,
        (unsigned long long)snapshot.header_span, hex);
}

static void macws_tile_store_target(id command_buffer, id encoder,
                                    id pass_descriptor) {
    if (!command_buffer || !encoder || !pass_descriptor) return;
    id texture = nil;
    NSUInteger load_action = NSUIntegerMax;
    NSUInteger store_action = NSUIntegerMax;
    MTLClearColor clear_color = MTLClearColorMake(0, 0, 0, 0);
    @try {
        id attachments = [pass_descriptor valueForKey:@"colorAttachments"];
        id attachment = [attachments objectAtIndexedSubscript:0];
        texture = [attachment valueForKey:@"texture"];
        load_action = (NSUInteger)[attachment loadAction];
        store_action = (NSUInteger)[attachment storeAction];
        clear_color = [attachment clearColor];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (!texture) return;

    uint64_t serial = atomic_fetch_add(&g_macws_tile_target_serial, 1) + 1;
    macws_tile_target_entry entry = {
        .serial = serial,
        .encoder = (uintptr_t)(__bridge void *)encoder,
        .command_buffer = (uintptr_t)(__bridge void *)command_buffer,
        .target = macws_tile_snapshot_texture(texture),
    };
    pthread_mutex_lock(&g_macws_tile_target_lock);
    g_macws_tile_targets[serial % MACWS_TILE_TARGET_CAP] = entry;
    pthread_mutex_unlock(&g_macws_tile_target_lock);

    // Read-only witness for the actual persistence contract SkyLight gives
    // the substituted full-display IOSurface.  A loadAction of DontCare would
    // permit AGX to discard untouched tiles, while Load requires the prior
    // pixels to survive.  Log the real descriptor instead of forcing either
    // behavior; the latter would only hide an upstream lifecycle mismatch.
    if (macws_is_owned_scanout_texture(texture)) {
        static _Atomic uint64_t owned_passes = 0;
        uint64_t owned_pass = atomic_fetch_add(&owned_passes, 1) + 1;
        if (owned_pass <= 64 || (owned_pass % 600) == 0) {
            fprintf(stderr,
                "#### VNC-OWNED render-pass #%llu serial=%llu command=%p "
                "encoder=%p target=%p %lux%lu loadAction=%lu "
                "storeAction=%lu clear=(%.6f,%.6f,%.6f,%.6f)\n",
                (unsigned long long)owned_pass,
                (unsigned long long)serial,
                (__bridge void *)command_buffer,
                (__bridge void *)encoder, (__bridge void *)texture,
                (unsigned long)[texture width],
                (unsigned long)[texture height],
                (unsigned long)load_action,
                (unsigned long)store_action,
                clear_color.red, clear_color.green, clear_color.blue,
                clear_color.alpha);
        }
    }
}

// Join the render-target metadata captured at encoder creation to the exact
// private IOGPU command buffer that later reports PageFault.  Snapshots contain
// only copied scalar/descriptor bytes; neither the texture nor encoder is
// retained, messaged, or dereferenced from the completion callback.  Keep the
// ring walk bounded and copy matches out before logging so the producer is not
// blocked behind stderr while holding the target lock.
static void macws_tile_dump_command_buffer_targets(
        const void *command_buffer) {
    if (!command_buffer ||
        access("/private/tmp/macws_tile_descriptor_diag", F_OK) != 0) {
        return;
    }
    macws_tile_target_entry matches[64] = {0};
    size_t match_count = 0;
    pthread_mutex_lock(&g_macws_tile_target_lock);
    for (size_t i = 0; i < MACWS_TILE_TARGET_CAP; i++) {
        macws_tile_target_entry entry = g_macws_tile_targets[i];
        if (entry.serial == 0 ||
            entry.command_buffer != (uintptr_t)command_buffer) {
            continue;
        }
        if (match_count < sizeof(matches) / sizeof(matches[0])) {
            matches[match_count++] = entry;
        }
    }
    pthread_mutex_unlock(&g_macws_tile_target_lock);

    // The fixed ring is indexed by serial modulo its capacity, so sort the
    // small copied set into encoder-creation order for direct comparison with
    // the KCMD segment chain.
    for (size_t i = 1; i < match_count; i++) {
        macws_tile_target_entry value = matches[i];
        size_t j = i;
        while (j > 0 && matches[j - 1].serial > value.serial) {
            matches[j] = matches[j - 1];
            j--;
        }
        matches[j] = value;
    }
    fprintf(stderr,
        "#### TILE-PAGEFAULT commandBuffer=%p renderTargets=%zu "
        "ringCapacity=%u\n",
        command_buffer, match_count, MACWS_TILE_TARGET_CAP);
    for (size_t i = 0; i < match_count; i++) {
        macws_tile_log_snapshot((uint32_t)(i + 1), "pagefault-target",
            matches[i].encoder, i, matches[i].target,
            matches[i].serial, matches[i].command_buffer);
    }
}

static BOOL macws_tile_find_target(uintptr_t encoder,
                                   macws_tile_target_entry *result) {
    if (!encoder || !result) return NO;
    BOOL found = NO;
    uint64_t best_serial = 0;
    pthread_mutex_lock(&g_macws_tile_target_lock);
    for (size_t i = 0; i < MACWS_TILE_TARGET_CAP; i++) {
        macws_tile_target_entry entry = g_macws_tile_targets[i];
        if (entry.encoder == encoder && entry.serial >= best_serial) {
            *result = entry;
            best_serial = entry.serial;
            found = YES;
        }
    }
    pthread_mutex_unlock(&g_macws_tile_target_lock);
    return found;
}

// Completion witness for the exact tile command buffer. Adding a handler is
// diagnostic-only and is installed only under macws_tile_descriptor_diag. The
// block captures no texture/encoder/command-buffer object; Metal supplies the
// completed object as its argument. On error it triggers the existing bounded
// flight dump immediately, before later PF550 work can reuse ObjC pointers.
static void macws_tile_observe_command_buffer(uintptr_t command_buffer) {
    if (!command_buffer) return;
    for (size_t i = 0;
         i < sizeof(g_macws_tile_observed_command_buffers) /
             sizeof(g_macws_tile_observed_command_buffers[0]);
         i++) {
        if (atomic_load(&g_macws_tile_observed_command_buffers[i]) ==
            command_buffer) {
            return;
        }
    }
    uint64_t serial = atomic_fetch_add(&g_macws_tile_observer_serial, 1) + 1;
    atomic_store(&g_macws_tile_observed_command_buffers[
        (serial - 1) % 32], command_buffer);

    id<MTLCommandBuffer> object =
        (__bridge id<MTLCommandBuffer>)((void *)command_buffer);
    [object addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        NSError *error = [completed error];
        fprintf(stderr,
            "#### TILE-CB-COMPLETE observer=%llu commandBuffer=%p "
            "status=%lu errorDomain=%s errorCode=%ld description=%s "
            "userInfo=%s\n",
            (unsigned long long)serial, (__bridge void *)completed,
            (unsigned long)[completed status],
            error ? [[error domain] UTF8String] : "(nil)",
            error ? (long)[error code] : 0L,
            error ? [[error localizedDescription] UTF8String] : "(nil)",
            error ? [[[error userInfo] description] UTF8String] : "(nil)");
        if (error) {
            macws_dump_recent_agx_submits(
                "tile-command-buffer-error", (__bridge const void *)completed);
        }
    }];
    fprintf(stderr,
        "#### TILE-CB observer installed #%llu commandBuffer=%#llx "
        "(completion-only; captures no Metal objects)\n",
        (unsigned long long)serial,
        (unsigned long long)command_buffer);
}

static void macws_tile_record_binding(id encoder, id texture,
                                      NSUInteger index) {
    uint32_t sequence = atomic_fetch_add(&g_macws_tile_binding_sequence, 1) + 1;
    if (sequence > 128) return;
    uintptr_t encoder_pointer = (uintptr_t)(__bridge void *)encoder;
    macws_tile_target_entry target = {0};
    BOOL has_target = macws_tile_find_target(encoder_pointer, &target);
    if (has_target) {
        macws_mark_agx_submit_for_error_dump(
            (const void *)target.command_buffer);
        macws_tile_observe_command_buffer(target.command_buffer);
        macws_tile_log_snapshot(sequence, "target", encoder_pointer, 0,
                                target.target, target.serial,
                                target.command_buffer);
    } else {
        fprintf(stderr,
            "#### TILE-DESC #%u role=target encoder=%#llx NOT-MAPPED\n",
            sequence, (unsigned long long)encoder_pointer);
    }
    macws_tile_log_snapshot(sequence, "source", encoder_pointer, index,
                            macws_tile_snapshot_texture(texture),
                            has_target ? target.serial : 0,
                            has_target ? target.command_buffer : 0);
}

static id macws_native_render_encoder_diag(id self, SEL selector,
                                           id descriptor) {
    id encoder = g_macws_native_render_encoder_orig
        ? g_macws_native_render_encoder_orig(self, selector, descriptor) : nil;
    macws_tile_store_target(self, encoder, descriptor);
    return encoder;
}

static void macws_native_set_tile_texture_diag(id self, SEL selector,
                                               id texture,
                                               NSUInteger index) {
    macws_tile_record_binding(self, texture, index);
    if (g_macws_native_set_tile_texture_orig) {
        g_macws_native_set_tile_texture_orig(self, selector, texture, index);
    }
}

static void macws_native_set_tile_textures_diag(id self, SEL selector,
                                                const id *textures,
                                                NSRange range) {
    if (textures) {
        for (NSUInteger i = 0; i < range.length; i++) {
            macws_tile_record_binding(self, textures[i], range.location + i);
        }
    }
    if (g_macws_native_set_tile_textures_orig) {
        g_macws_native_set_tile_textures_orig(self, selector, textures, range);
    }
}

static void macws_install_tile_descriptor_diagnostic(void) {
    if (access("/private/tmp/macws_tile_descriptor_diag", F_OK) != 0) return;
    Class command_buffer = objc_getClass("AGXG13GFamilyCommandBuffer");
    SEL render_selector = sel_registerName("renderCommandEncoderWithDescriptor:");
    Method render_method = command_buffer
        ? class_getInstanceMethod(command_buffer, render_selector) : NULL;
    if (render_method && !g_macws_native_render_encoder_orig) {
        g_macws_native_render_encoder_orig =
            (macws_native_render_encoder_fn)
                method_getImplementation(render_method);
        method_setImplementation(render_method,
                                 (IMP)macws_native_render_encoder_diag);
        fprintf(stderr,
            "#### TILE-DESC render descriptor hook installed class=%s "
            "original=%p\n",
            class_getName(command_buffer),
            (void *)g_macws_native_render_encoder_orig);
    }

    Class render_context = objc_getClass("AGXG13GFamilyRenderContext");
    SEL texture_selector = sel_registerName("setTileTexture:atIndex:");
    SEL textures_selector = sel_registerName("setTileTextures:withRange:");
    Method texture_method = render_context
        ? class_getInstanceMethod(render_context, texture_selector) : NULL;
    Method textures_method = render_context
        ? class_getInstanceMethod(render_context, textures_selector) : NULL;
    Class texture_class = objc_getClass("AGXG13GFamilyTexture");
    SEL update_bind_selector = sel_registerName(
        "updateBindDataWithAddresses:cpuMetadataAddress:gpuVirtualAddress:"
        "isCompressible:shouldInitMetadata:");
    Method update_bind_method = texture_class
        ? class_getInstanceMethod(texture_class, update_bind_selector) : NULL;
    if (texture_method) {
        g_macws_native_set_tile_texture_orig =
            (macws_native_set_tile_texture_fn)method_getImplementation(texture_method);
        method_setImplementation(texture_method,
                                 (IMP)macws_native_set_tile_texture_diag);
    }
    if (textures_method) {
        g_macws_native_set_tile_textures_orig =
            (macws_native_set_tile_textures_fn)method_getImplementation(textures_method);
        method_setImplementation(textures_method,
                                 (IMP)macws_native_set_tile_textures_diag);
    }
    if (update_bind_method && !g_macws_native_update_bind_five_orig) {
        g_macws_native_update_bind_five_orig =
            (macws_native_update_bind_five_fn)
                method_getImplementation(update_bind_method);
        method_setImplementation(update_bind_method,
                                 (IMP)macws_native_update_bind_five_diag);
    }
    fprintf(stderr,
        "#### TILE-DESC diagnostic installed render=%d texture=%d textures=%d "
        "updateBindFive=%d "
        "(read-only fixed ring; original IMPs preserved)\n",
        render_method != NULL, texture_method != NULL,
        textures_method != NULL, update_bind_method != NULL);
}

// Read-only source-library compilation witness. Chromium/ANGLE reports
// "This library format is not supported on this platform" after handing MSL
// to the real AGX device.  Capture the public compile options and the NSError
// returned by the actual device method so the compiler-target mismatch can be
// fixed upstream in MTLCompilerService rather than hidden by a retry or a
// validation bypass. Enable with /private/tmp/macws_mtl_library_diag.
typedef id (*macws_new_library_source_fn)(id, SEL, NSString *, id, NSError **);
static macws_new_library_source_fn g_macws_new_library_source_orig = NULL;
static _Atomic uint32_t g_macws_new_library_source_count = 0;

// Narrow compatibility/observer boundary for precompiled libraries. ANGLE's
// internal render utilities use -newLibraryWithData:error: instead of the
// dynamic MSL source path above. The validated exact-library substitution is
// production; its optional blob/caller logging has a separate sentinel so it
// does not enable the much heavier private Metal cache instrumentation.
typedef id (*macws_new_library_data_fn)(id, SEL, dispatch_data_t, NSError **)
    __attribute__((ns_returns_retained));
static macws_new_library_data_fn g_macws_new_library_data_orig = NULL;
static _Atomic uint32_t g_macws_new_library_data_count = 0;

static uint64_t macws_source_fnv1a64(const void *data, size_t length) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

// Chromium 148.0.7778.280 embeds ANGLE revision
// 1ba8ec3afdee39c6b8d5c7268598b4beca530d07's default shader library as
// air64-apple-macosx10.14.0. Runtime capture from the exact libGLESv2 image
// showed that the container loads, but specialization of its function
// constants through the iOS MTLCompilerService fails with "Target OS is
// incompatible". The package carries the same generated ANGLE source compiled
// by that real service through MacWS's macabi target adapter. Substitute only
// the byte-exact upstream library; a different Electron build keeps its own
// data and cannot accidentally receive a mismatched function set.
static const size_t kMacWSANGLEDefaultMacOSBytes = 361943;
static const uint64_t kMacWSANGLEDefaultMacOSHash =
    UINT64_C(0x4a17e801057d2e72);
static const size_t kMacWSANGLEDefaultMacABIBytes = 714152;
static const uint64_t kMacWSANGLEDefaultMacABIHash =
    UINT64_C(0x2b19e550c422772a);
static const char *kMacWSANGLEDefaultMacABIPath =
    "/usr/local/share/macws/angle/angle-default-1ba8ec3-macabi.metallib";
static dispatch_data_t g_macws_angle_default_macabi = NULL;

// Steam build 1785799196 embeds Chromium 126.0.6478.183 and ANGLE revision
// 5d4df51d1d7d6a290d54111527a4798f10c7ca3c.  Its generated default library
// has a different function set and must never receive Chromium 148's blob.
// Runtime capture from Steam Helper's real libGLESv2 image established the
// exact source container identity below.  The replacement was compiled from
// that revision's official mtl_internal_shaders_src_autogen.h through the
// same real MTLCompilerService macabi adapter.
static const size_t kMacWSSteamANGLEDefaultMacOSBytes = 368459;
static const uint64_t kMacWSSteamANGLEDefaultMacOSHash =
    UINT64_C(0xd3e757cc4a31c3c0);
static const size_t kMacWSSteamANGLEDefaultMacABIBytes = 711592;
static const uint64_t kMacWSSteamANGLEDefaultMacABIHash =
    UINT64_C(0x49a40eb36303a603);
static const char *kMacWSSteamANGLEDefaultMacABIPath =
    "/usr/local/share/macws/angle/angle-default-5d4df51-macabi.metallib";
static dispatch_data_t g_macws_steam_angle_default_macabi = NULL;

// Stray 1.5.0 (Steam app 1332010) carries Metal 902.1 MTLB 2.3
// containers.  The macOS Metal loader accepts those archives, but the real
// iOS AGX compiler rejects their macOS 10.14 AIR modules when UE4 creates the
// Bink render pipelines and Main_0000155a_0f9e5cf5 compute pipeline.  Each
// secondary archive is rebuilt from the captured byte-exact input with every
// AIR module retargeted to macabi; the legacy container layout is preserved so
// Ventura's loader still supplies the original function/reflection metadata.
// Selection is an exact length+FNV identity, never an application-name guess.
typedef struct {
    size_t source_length;
    uint64_t source_hash;
    size_t replacement_length;
    uint64_t replacement_hash;
    const char *replacement_path;
} MacWSStrayMetalLibrary;

static const MacWSStrayMetalLibrary kMacWSStrayMetalLibraries[] = {
    { 3569, UINT64_C(0xaa9ab924907db665),
      4033, UINT64_C(0x024a2ac48e9cb521),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0001_aa9ab924907db665-macabi.metallib" },
    { 16384, UINT64_C(0x104af2d3aa14effe),
      18352, UINT64_C(0xa62a9191a1825fc4),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0002_104af2d3aa14effe-macabi.metallib" },
    { 38944, UINT64_C(0x754e9354d2bed1ce),
      43120, UINT64_C(0xd91dfc54464816a8),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0003_754e9354d2bed1ce-macabi.metallib" },
    { 6476, UINT64_C(0x1af3f820eb9c9879),
      6636, UINT64_C(0x85f3a29ef89f20b6),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0004_1af3f820eb9c9879-macabi.metallib" },
    { 4684, UINT64_C(0xe49cbc464de177a6),
      4812, UINT64_C(0xbe6d5c99b52cea6a),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0005_e49cbc464de177a6-macabi.metallib" },
    { 3974, UINT64_C(0x11d01f9d5be484ce),
      4102, UINT64_C(0xdc8edcd819b692e5),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0006_11d01f9d5be484ce-macabi.metallib" },
    { 4092, UINT64_C(0xa0aee2ed34c7cc82),
      4188, UINT64_C(0x905ea6d6d43ac505),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0007_a0aee2ed34c7cc82-macabi.metallib" },
    { 3537, UINT64_C(0xadf0091eede46178),
      3649, UINT64_C(0xd85f854ab1e98001),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0008_adf0091eede46178-macabi.metallib" },
    { 3452, UINT64_C(0x8b08bdaa4b23b8d6),
      3564, UINT64_C(0xa1a63337c3f2eea8),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0009_8b08bdaa4b23b8d6-macabi.metallib" },
    { 3740, UINT64_C(0x1c7d92340be4c066),
      3852, UINT64_C(0x0587c85e8f62b77c),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0010_1c7d92340be4c066-macabi.metallib" },
    { 9580, UINT64_C(0xbc43fb96825c1eeb),
      9804, UINT64_C(0xc5b0e9972beaec2d),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0010_bc43fb96825c1eeb-macabi.metallib" },
    { 5852, UINT64_C(0xdcd983a35ebe5747),
      5964, UINT64_C(0x9ceb4ffe2a0f3d1c),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0012_dcd983a35ebe5747-macabi.metallib" },
    { 3921, UINT64_C(0x57e3ed02b867ab23),
      4033, UINT64_C(0x313d6a59882adb2e),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0013_57e3ed02b867ab23-macabi.metallib" },
    { 5724, UINT64_C(0x29e91caa2c4db3e4),
      5852, UINT64_C(0x19ec70da76ba1542),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0014_29e91caa2c4db3e4-macabi.metallib" },
    { 3548, UINT64_C(0x77a6bcce69bd35dd),
      3660, UINT64_C(0x5ed333cb01dd1eff),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0015_77a6bcce69bd35dd-macabi.metallib" },
    { 3958, UINT64_C(0xfece7c6d28318ea6),
      4086, UINT64_C(0x057c4c2d79ab8bb7),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0016_fece7c6d28318ea6-macabi.metallib" },
    { 7884, UINT64_C(0x20009904c48f7940),
      8092, UINT64_C(0x2d7ac7077756260e),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0017_20009904c48f7940-macabi.metallib" },
    { 3137, UINT64_C(0xae19226a867a96dd),
      3233, UINT64_C(0xf726e01fdf69638b),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0018_ae19226a867a96dd-macabi.metallib" },
    { 4748, UINT64_C(0x48516180d56afb8b),
      4876, UINT64_C(0xbd76365f15a35cec),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0019_48516180d56afb8b-macabi.metallib" },
    { 3981, UINT64_C(0xe816a1ceebad3994),
      4093, UINT64_C(0x6e953e6fd1d80efd),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0020_e816a1ceebad3994-macabi.metallib" },
    { 5068, UINT64_C(0x0bd6c85cc3c02312),
      5180, UINT64_C(0x972e073e0e238b9d),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0021_0bd6c85cc3c02312-macabi.metallib" },
    { 10924, UINT64_C(0x89bd0750856f176a),
      11180, UINT64_C(0x791eed7a8729df3f),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0022_89bd0750856f176a-macabi.metallib" },
    { 9756, UINT64_C(0x9dd7f1a79a393b47),
      9980, UINT64_C(0x3baf8452b34b2d3d),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0023_9dd7f1a79a393b47-macabi.metallib" },
    { 10620, UINT64_C(0x6dd18b5165d70e7d),
      10844, UINT64_C(0xfbc182bb2ac11c09),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0024_6dd18b5165d70e7d-macabi.metallib" },
    { 4572, UINT64_C(0xdb18c0a5a9621796),
      4684, UINT64_C(0xa88619215c2d700b),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0025_db18c0a5a9621796-macabi.metallib" },
    { 13420, UINT64_C(0x8726b5069e53decc),
      13724, UINT64_C(0xb011e362988677e4),
      "/usr/local/share/macws/stray/"
      "macws_mtl_data_0026_8726b5069e53decc-macabi.metallib" },
};
static dispatch_once_t g_macws_stray_metal_once[
    sizeof(kMacWSStrayMetalLibraries) / sizeof(kMacWSStrayMetalLibraries[0])];
static dispatch_data_t g_macws_stray_metal_data[
    sizeof(kMacWSStrayMetalLibraries) / sizeof(kMacWSStrayMetalLibraries[0])];

static dispatch_data_t macws_load_exact_metal_library(
    const char *path, size_t expected_length, uint64_t expected_hash) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat metadata = {0};
    if (fstat(fd, &metadata) != 0 || metadata.st_size <= 0 ||
        (size_t)metadata.st_size != expected_length) {
        close(fd);
        return NULL;
    }
    uint8_t *bytes = malloc(expected_length);
    if (!bytes) {
        close(fd);
        return NULL;
    }
    size_t consumed = 0;
    while (consumed < expected_length) {
        ssize_t count = read(fd, bytes + consumed,
                             expected_length - consumed);
        if (count <= 0) break;
        consumed += (size_t)count;
    }
    close(fd);
    uint32_t magic = 0;
    uint64_t container_length = 0;
    if (consumed >= 24) {
        memcpy(&magic, bytes, sizeof(magic));
        memcpy(&container_length, bytes + 16, sizeof(container_length));
    }
    dispatch_data_t result = NULL;
    if (consumed == expected_length && magic == UINT32_C(0x424c544d) &&
        container_length == expected_length &&
        macws_source_fnv1a64(bytes, expected_length) == expected_hash) {
        result = dispatch_data_create(bytes, expected_length, NULL,
                                      DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    }
    free(bytes);
    return result;
}

static dispatch_data_t macws_angle_default_macabi_library(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_macws_angle_default_macabi = macws_load_exact_metal_library(
            kMacWSANGLEDefaultMacABIPath,
            kMacWSANGLEDefaultMacABIBytes,
            kMacWSANGLEDefaultMacABIHash);
    });
    return g_macws_angle_default_macabi;
}

static dispatch_data_t macws_steam_angle_default_macabi_library(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_macws_steam_angle_default_macabi = macws_load_exact_metal_library(
            kMacWSSteamANGLEDefaultMacABIPath,
            kMacWSSteamANGLEDefaultMacABIBytes,
            kMacWSSteamANGLEDefaultMacABIHash);
    });
    return g_macws_steam_angle_default_macabi;
}

static BOOL macws_is_stray_metal_library_length(size_t length) {
    for (size_t index = 0;
         index < sizeof(kMacWSStrayMetalLibraries) /
                     sizeof(kMacWSStrayMetalLibraries[0]);
         index++) {
        if (kMacWSStrayMetalLibraries[index].source_length == length)
            return YES;
    }
    return NO;
}

static dispatch_data_t macws_stray_macabi_library(size_t index) {
    const size_t count = sizeof(kMacWSStrayMetalLibraries) /
                         sizeof(kMacWSStrayMetalLibraries[0]);
    if (index >= count) return NULL;
    dispatch_once(&g_macws_stray_metal_once[index], ^{
        const MacWSStrayMetalLibrary *entry =
            &kMacWSStrayMetalLibraries[index];
        g_macws_stray_metal_data[index] = macws_load_exact_metal_library(
            entry->replacement_path, entry->replacement_length,
            entry->replacement_hash);
    });
    return g_macws_stray_metal_data[index];
}

// UE4 streams hundreds of small, one-function legacy MTLB archives as levels
// load.  Recompiling libmachook merely to append every exact fingerprint makes
// the compatibility data depend on build timing.  Allow post-install to place
// additional byte-exact conversions in a root-owned directory instead:
//
//   exact/<source-length>-<source-fnv>.metallib
//   exact/<source-length>-<source-fnv>.meta  -> <output-length> <output-fnv>
//
// Both files must be owned by root and not group/world writable.  The source
// still has to match length+FNV before this function is called, and the output
// is validated again by macws_load_exact_metal_library (size, MTLB magic,
// container length and FNV).  This is an exact data replacement, not an
// application-name or function-name heuristic.
typedef struct {
    size_t source_length;
    uint64_t source_hash;
    dispatch_data_t replacement;
} MacWSDynamicMetalLibrary;

static pthread_mutex_t g_macws_dynamic_metal_lock =
    PTHREAD_MUTEX_INITIALIZER;
static MacWSDynamicMetalLibrary g_macws_dynamic_metal_libraries[512];
static size_t g_macws_dynamic_metal_library_count = 0;

static BOOL macws_root_owned_readonly_file(const char *path) {
    struct stat metadata = {0};
    return path && stat(path, &metadata) == 0 &&
           metadata.st_uid == 0 && S_ISREG(metadata.st_mode) &&
           (metadata.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static dispatch_data_t macws_dynamic_stray_macabi_library(
        size_t source_length, uint64_t source_hash) {
    pthread_mutex_lock(&g_macws_dynamic_metal_lock);
    for (size_t index = 0; index < g_macws_dynamic_metal_library_count;
         index++) {
        MacWSDynamicMetalLibrary *entry =
            &g_macws_dynamic_metal_libraries[index];
        if (entry->source_length == source_length &&
            entry->source_hash == source_hash) {
            dispatch_data_t cached = entry->replacement;
            pthread_mutex_unlock(&g_macws_dynamic_metal_lock);
            return cached;
        }
    }
    pthread_mutex_unlock(&g_macws_dynamic_metal_lock);

    char library_path[PATH_MAX] = {0};
    char metadata_path[PATH_MAX] = {0};
    snprintf(library_path, sizeof(library_path),
             "/usr/local/share/macws/stray/exact/%zu-%016llx.metallib",
             source_length, (unsigned long long)source_hash);
    snprintf(metadata_path, sizeof(metadata_path),
             "/usr/local/share/macws/stray/exact/%zu-%016llx.meta",
             source_length, (unsigned long long)source_hash);
    if (!macws_root_owned_readonly_file(library_path) ||
        !macws_root_owned_readonly_file(metadata_path))
        return NULL;

    FILE *metadata_file = fopen(metadata_path, "r");
    if (!metadata_file) return NULL;
    size_t replacement_length = 0;
    unsigned long long replacement_hash = 0;
    char trailing = 0;
    int fields = fscanf(metadata_file, "%zu %llx %c", &replacement_length,
                        &replacement_hash, &trailing);
    fclose(metadata_file);
    if (fields != 2 || replacement_length < 24 ||
        replacement_length > 64U * 1024U * 1024U)
        return NULL;

    dispatch_data_t replacement = macws_load_exact_metal_library(
        library_path, replacement_length, (uint64_t)replacement_hash);
    if (!replacement) return NULL;

    pthread_mutex_lock(&g_macws_dynamic_metal_lock);
    // A competing library-creation thread may have populated this fingerprint
    // while the file was read.  Prefer that stable object.  The redundant
    // dispatch object remains process-scoped; this path occurs at most once per
    // racing fingerprint and avoids an unsafe release under mixed libdispatch
    // Objective-C ownership ABIs.
    for (size_t index = 0; index < g_macws_dynamic_metal_library_count;
         index++) {
        MacWSDynamicMetalLibrary *entry =
            &g_macws_dynamic_metal_libraries[index];
        if (entry->source_length == source_length &&
            entry->source_hash == source_hash) {
            replacement = entry->replacement;
            pthread_mutex_unlock(&g_macws_dynamic_metal_lock);
            return replacement;
        }
    }
    if (g_macws_dynamic_metal_library_count <
        sizeof(g_macws_dynamic_metal_libraries) /
            sizeof(g_macws_dynamic_metal_libraries[0])) {
        MacWSDynamicMetalLibrary *entry =
            &g_macws_dynamic_metal_libraries[
                g_macws_dynamic_metal_library_count++];
        entry->source_length = source_length;
        entry->source_hash = source_hash;
        entry->replacement = replacement;
    }
    pthread_mutex_unlock(&g_macws_dynamic_metal_lock);
    if (macws_runtime_diagnostics_enabled()) {
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-DYNAMIC source=%zu/%016llx "
            "replacement=%zu/%016llx path=%s\n",
            source_length, (unsigned long long)source_hash,
            replacement_length, replacement_hash, library_path);
    }
    return replacement;
}

// Read-only observers at the private Metal library-cache/compiler boundary.
// RE-confirmed against macOS 13.4 Metal UUID
// 2BAB169C-42DA-36E3-955A-F30B709EC2AD:
//
//   image+0x0ec430  MultiLevelPipelineCache::getElement
//   image+0x023d6c  MTLLibraryCache::findLibraryData
//   image+0x0ec530  processCompiledLibrary
//
// MTLLibraryBuilder::initLibraryContainerWithRequestData first asks the two
// cache layers for a compiled dispatch-data blob.  Only a miss reaches the
// real MTLCompilerRequest connection.  processCompiledLibrary is the common
// validation boundary for a returned blob.  Capturing all three results is
// therefore sufficient to distinguish a stale cache hit from a newly built
// but incompatible container without changing either result.  These hooks are
// installed only when /private/tmp/macws_mtl_library_diag exists before the
// process starts; production never pays their cost.
typedef dispatch_data_t (*macws_multilevel_get_element_fn)(
    void *, const void *, bool);
typedef dispatch_data_t (*macws_multilevel_get_archives_fn)(
    void *, const void *, id);
typedef id (*macws_binary_archive_cache_get_fn)(void *, const void *);
typedef dispatch_data_t (*macws_multilevel_get_legacy_fn)(
    void *, const void *);
typedef int (*macws_fscache_open_with_key_fn)(
    const char *, void *, void *, void *);
typedef void *(*macws_library_cache_find_fn)(void *, const void *);
typedef void (*macws_process_compiled_library_fn)(
    dispatch_data_t, id, uint32_t, const void *, const void *, bool, uint64_t,
    id, id, void **, NSError **, void *, uint64_t);

static macws_multilevel_get_element_fn
    g_macws_multilevel_get_element_orig = NULL;
static macws_multilevel_get_archives_fn
    g_macws_multilevel_get_archives_orig = NULL;
static macws_binary_archive_cache_get_fn
    g_macws_binary_archive_cache_get_orig = NULL;
static macws_multilevel_get_legacy_fn
    g_macws_multilevel_get_legacy_orig = NULL;
static macws_fscache_open_with_key_fn
    g_macws_fscache_open_with_key_orig = NULL;
static macws_library_cache_find_fn g_macws_library_cache_find_orig = NULL;
static macws_process_compiled_library_fn
    g_macws_process_compiled_library_orig = NULL;
static _Atomic uint32_t g_macws_metal_cache_sequence = 0;
static _Atomic uint32_t g_macws_compiled_blob_sequence = 0;

static dispatch_data_t macws_multilevel_get_archives_diag(
    void *cache, const void *key, id archives) {
    dispatch_data_t result = g_macws_multilevel_get_archives_orig
        ? g_macws_multilevel_get_archives_orig(cache, key, archives) : NULL;
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE tier=binary-archives cache=%p key=%p archives=%p "
        "count=%lu result=%p bytes=%zu\n",
        cache, key, (__bridge void *)archives,
        archives && [archives respondsToSelector:@selector(count)]
            ? (unsigned long)[archives count] : 0,
        result, result ? dispatch_data_get_size(result) : 0);
    return result;
}

static id macws_binary_archive_cache_get_diag(
    void *cache, const void *key) {
    id result = g_macws_binary_archive_cache_get_orig
        ? g_macws_binary_archive_cache_get_orig(cache, key) : nil;
    id path = cache ? *(id *)((uint8_t *)cache + 0xd0) : nil;
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE tier=managed-binary-archive cache=%p key=%p "
        "path=%s result=%p class=%s\n",
        cache, key,
        path && [path respondsToSelector:@selector(UTF8String)]
            ? [path UTF8String] : "(nil)",
        (__bridge void *)result,
        result ? class_getName([result class]) : "(nil)");
    return result;
}

static dispatch_data_t macws_multilevel_get_legacy_diag(
    void *cache, const void *key) {
    dispatch_data_t result = g_macws_multilevel_get_legacy_orig
        ? g_macws_multilevel_get_legacy_orig(cache, key) : NULL;
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE tier=legacy cache=%p key=%p result=%p bytes=%zu\n",
        cache, key, result, result ? dispatch_data_get_size(result) : 0);
    return result;
}

static int macws_fscache_open_with_key_diag(
    const char *path, void *handle, void *config, void *key) {
    int result = g_macws_fscache_open_with_key_orig
        ? g_macws_fscache_open_with_key_orig(path, handle, config, key) : -1;
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE fscache-open path=%s handle=%p config=%p key=%p "
        "result=%d\n",
        path ?: "(nil)", handle, config, key, result);
    return result;
}

static dispatch_data_t macws_multilevel_get_element_diag(
    void *cache, const void *key, bool flag) {
    dispatch_data_t result = g_macws_multilevel_get_element_orig
        ? g_macws_multilevel_get_element_orig(cache, key, flag) : NULL;
    uint32_t sequence =
        atomic_fetch_add(&g_macws_metal_cache_sequence, 1) + 1;
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t mapped = result
        ? dispatch_data_create_map(result, &bytes, &length) : NULL;
    uint64_t blob_hash = bytes && length
        ? macws_source_fnv1a64(bytes, length) : 0;
    uint32_t magic = 0;
    if (bytes && length >= sizeof(magic)) memcpy(&magic, bytes, sizeof(magic));
    char path[PATH_MAX] = {0};
    size_t written_total = 0;
    // A Chromium GPU process asks this shared cache for hundreds of unrelated
    // Mach-O/pipeline records before its first ANGLE source library.  Persist
    // only actual MTLB containers, but allow enough requests to reach media
    // shaders without turning the observer into a general cache dumper.
    if (bytes && length && magic == UINT32_C(0x424c544d) &&
        length <= 64 * 1024 * 1024 && sequence <= 4096) {
        snprintf(path, sizeof(path),
                 "/private/tmp/macws_cached_library_%04u_%016llx.bin",
                 sequence, (unsigned long long)blob_hash);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)bytes;
            size_t remaining = length;
            while (remaining) {
                ssize_t count = write(fd, cursor, remaining);
                if (count <= 0) break;
                cursor += count;
                remaining -= (size_t)count;
            }
            written_total = length - remaining;
            close(fd);
        }
    }
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE multilevel #%u cache=%p key=%p flag=%d "
        "result=%p bytes=%zu magic=%#x hash=%016llx path=%s written=%zu\n",
        sequence, cache, key, flag, result,
        length, magic, (unsigned long long)blob_hash,
        path[0] ? path : "(none)", written_total);
    if (mapped) dispatch_release(mapped);
    return result;
}

static void *macws_library_cache_find_diag(void *cache, const void *key) {
    void *result = g_macws_library_cache_find_orig
        ? g_macws_library_cache_find_orig(cache, key) : NULL;
    uint32_t sequence =
        atomic_fetch_add(&g_macws_metal_cache_sequence, 1) + 1;
    dprintf(STDERR_FILENO,
        "#### MTL-CACHE library #%u cache=%p key=%p result=%p\n",
        sequence, cache, key, result);
    return result;
}

static void macws_process_compiled_library_diag(
    dispatch_data_t data, id device, uint32_t request_type,
    const void *pipeline_cache, const void *key, bool flag,
    uint64_t library_type, id functions, id function_list,
    void **library_data, NSError **error, void *outputs,
    uint64_t compiler_option) {
    uint32_t sequence =
        atomic_fetch_add(&g_macws_compiled_blob_sequence, 1) + 1;
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t mapped = data
        ? dispatch_data_create_map(data, &bytes, &length) : NULL;
    uint64_t blob_hash = bytes && length
        ? macws_source_fnv1a64(bytes, length) : 0;
    uint32_t magic = 0;
    if (bytes && length >= sizeof(magic)) memcpy(&magic, bytes, sizeof(magic));

    char path[PATH_MAX] = {0};
    size_t written_total = 0;
    if (bytes && length && length <= 64 * 1024 * 1024 && sequence <= 512) {
        snprintf(path, sizeof(path),
                 "/private/tmp/macws_compiled_library_%04u_%016llx.bin",
                 sequence, (unsigned long long)blob_hash);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)bytes;
            size_t remaining = length;
            while (remaining) {
                ssize_t count = write(fd, cursor, remaining);
                if (count <= 0) break;
                cursor += count;
                remaining -= (size_t)count;
            }
            written_total = length - remaining;
            close(fd);
        }
    }
    dprintf(STDERR_FILENO,
        "#### MTL-COMPILED-BLOB in #%u data=%p bytes=%zu magic=%#x "
        "hash=%016llx requestType=%u device=%s libraryType=%llu flag=%d "
        "compilerOption=%llu path=%s written=%zu\n",
        sequence, data, length, magic, (unsigned long long)blob_hash,
        request_type, device ? class_getName([device class]) : "(nil)",
        (unsigned long long)library_type, flag,
        (unsigned long long)compiler_option, path[0] ? path : "(none)",
        written_total);

    if (g_macws_process_compiled_library_orig) {
        g_macws_process_compiled_library_orig(
            data, device, request_type, pipeline_cache, key, flag,
            library_type, functions, function_list, library_data, error,
            outputs, compiler_option);
    }
    dprintf(STDERR_FILENO,
        "#### MTL-COMPILED-BLOB out #%u libraryData=%p error=%s\n",
        sequence, library_data ? *library_data : NULL,
        error && *error ? (*error).localizedDescription.UTF8String : "(nil)");
    if (mapped) dispatch_release(mapped);
}

static BOOL macws_macho_has_uuid(const struct mach_header *header,
                                 const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *header64 =
        (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)(header64 + 1);
    const uint8_t *limit = cursor + header64->sizeofcmds;
    for (uint32_t index = 0; index < header64->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > limit) return NO;
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize > limit)
            return NO;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        cursor += command->cmdsize;
    }
    return NO;
}

static void macws_install_metal_library_boundary_diagnostics(
    const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (access("/private/tmp/macws_mtl_library_diag", F_OK) != 0) return;
    static const uint8_t metal_13_4_uuid[16] = {
        0x2b, 0xab, 0x16, 0x9c, 0x42, 0xda, 0x36, 0xe3,
        0x95, 0x5a, 0xf3, 0x0b, 0x70, 0x9e, 0xc2, 0xad,
    };
    if (!macws_macho_has_uuid(header, metal_13_4_uuid)) return;
    static _Atomic bool installed = false;
    if (atomic_exchange(&installed, true)) return;

    uint8_t *base = (uint8_t *)header;
    MSHookFunction(base + 0x0ec430,
                   (void *)macws_multilevel_get_element_diag,
                   (void **)&g_macws_multilevel_get_element_orig);
    MSHookFunction(base + 0x104e1c,
                   (void *)macws_multilevel_get_archives_diag,
                   (void **)&g_macws_multilevel_get_archives_orig);
    MSHookFunction(base + 0x04a67c,
                   (void *)macws_binary_archive_cache_get_diag,
                   (void **)&g_macws_binary_archive_cache_get_orig);
    MSHookFunction(base + 0x0f6ff8,
                   (void *)macws_multilevel_get_legacy_diag,
                   (void **)&g_macws_multilevel_get_legacy_orig);
    void *fscache_open = dlsym(RTLD_DEFAULT, "fscache_open_with_key");
    if (fscache_open) {
        MSHookFunction(fscache_open,
                       (void *)macws_fscache_open_with_key_diag,
                       (void **)&g_macws_fscache_open_with_key_orig);
    }
    MSHookFunction(base + 0x023d6c,
                   (void *)macws_library_cache_find_diag,
                   (void **)&g_macws_library_cache_find_orig);
    MSHookFunction(base + 0x0ec530,
                   (void *)macws_process_compiled_library_diag,
                   (void **)&g_macws_process_compiled_library_orig);
    dprintf(STDERR_FILENO,
        "#### MTL-LIB-BOUNDARY diagnostics installed Metal=%p "
        "multi=%p library=%p process=%p fscacheOpen=%p\n",
        base, base + 0x0ec430, base + 0x023d6c, base + 0x0ec530,
        fscache_open);
}

static unsigned long long macws_objc_unsigned_property(id object,
                                                       const char *name,
                                                       BOOL *present) {
    if (present) *present = NO;
    if (!object) return 0;
    SEL selector = sel_registerName(name);
    if (![object respondsToSelector:selector]) return 0;
    if (present) *present = YES;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
}

static id macws_new_library_source_diag(id self, SEL selector,
                                        NSString *source, id options,
                                        NSError **error) {
    uint32_t sequence =
        atomic_fetch_add(&g_macws_new_library_source_count, 1) + 1;
    // Chromium creates dozens of UI libraries before the first media shader.
    // Keep this bounded, but large enough that a post-navigation ANGLE failure
    // cannot fall past the recorder as it did with the former 32-call limit.
    BOOL log_this = sequence <= 256;
    const char *source_utf8 = source.UTF8String ?: "";
    size_t source_utf8_length = strlen(source_utf8);
    uint64_t source_hash = macws_source_fnv1a64(source_utf8,
                                                source_utf8_length);
    if (log_this) {
        BOOL has_language = NO, has_library_type = NO;
        BOOL has_fast_math = NO, has_optimization = NO;
        unsigned long long language = macws_objc_unsigned_property(
            options, "languageVersion", &has_language);
        unsigned long long library_type = macws_objc_unsigned_property(
            options, "libraryType", &has_library_type);
        unsigned long long fast_math = macws_objc_unsigned_property(
            options, "fastMathEnabled", &has_fast_math);
        unsigned long long optimization = macws_objc_unsigned_property(
            options, "optimizationLevel", &has_optimization);
        NSString *prefix = source.length
            ? [source substringToIndex:MIN((NSUInteger)240, source.length)] : @"";
        prefix = [[prefix stringByReplacingOccurrencesOfString:@"\n"
                                                   withString:@"\\n"]
                       stringByReplacingOccurrencesOfString:@"\r"
                                                   withString:@"\\r"];
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-SOURCE in #%u pid=%d device=%s sourceLength=%lu "
            "sourceUTF8Length=%zu sourceHash=%016llx "
            "optionsClass=%s languageVersion=%s%llu libraryType=%s%llu "
            "fastMath=%s%llu optimizationLevel=%s%llu prefix=%s\n",
            sequence, getpid(), class_getName([self class]),
            (unsigned long)source.length,
            source_utf8_length, (unsigned long long)source_hash,
            options ? class_getName([options class]) : "(nil)",
            has_language ? "" : "NA/", language,
            has_library_type ? "" : "NA/", library_type,
            has_fast_math ? "" : "NA/", fast_math,
            has_optimization ? "" : "NA/", optimization,
            prefix.UTF8String ?: "");
    }

    id result = g_macws_new_library_source_orig
        ? g_macws_new_library_source_orig(self, selector, source, options,
                                          error)
        : nil;
    if (log_this) {
        NSError *returned_error = error ? *error : nil;
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-SOURCE out #%u sourceHash=%016llx library=%p class=%s "
            "errorDomain=%s errorCode=%ld description=%s userInfo=%s\n",
            sequence, (unsigned long long)source_hash, (void *)result,
            result ? class_getName([result class]) : "(nil)",
            returned_error ? returned_error.domain.UTF8String : "(nil)",
            returned_error ? (long)returned_error.code : 0L,
            returned_error ? returned_error.localizedDescription.UTF8String
                           : "(nil)",
            returned_error ? returned_error.userInfo.description.UTF8String
                           : "(nil)");
    }
    if (!result && source_utf8_length && sequence <= 256) {
        char failure_path[PATH_MAX];
        snprintf(failure_path, sizeof(failure_path),
                 "/private/tmp/macws_mtl_source_failure_%016llx.metal",
                 (unsigned long long)source_hash);
        int fd = open(failure_path,
                      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)source_utf8;
            size_t remaining = source_utf8_length;
            while (remaining) {
                ssize_t written = write(fd, cursor, remaining);
                if (written <= 0) break;
                cursor += written;
                remaining -= (size_t)written;
            }
            close(fd);
            dprintf(STDERR_FILENO,
                "#### MTL-LIB-SOURCE failureDump #%u sourceHash=%016llx "
                "path=%s written=%zu/%zu\n",
                sequence, (unsigned long long)source_hash, failure_path,
                source_utf8_length - remaining, source_utf8_length);
        }
    }
    return result;
}

static id macws_new_library_data_compat(id self, SEL selector,
                                        dispatch_data_t data,
                                        NSError **error)
    __attribute__((ns_returns_retained));
static id macws_new_library_data_compat(id self, SEL selector,
                                        dispatch_data_t data,
                                        NSError **error) {
    uint32_t sequence =
        atomic_fetch_add(&g_macws_new_library_data_count, 1) + 1;
    BOOL diagnostic =
        access("/private/tmp/macws_mtl_data_diag", F_OK) == 0;
    const void *bytes = NULL;
    size_t length = data ? dispatch_data_get_size(data) : 0;
    dispatch_data_t mapped = NULL;
    if (data && (diagnostic ||
                 (getenv("MACWS_AGX_NATIVE") &&
                  (length == kMacWSANGLEDefaultMacOSBytes ||
                   length == kMacWSSteamANGLEDefaultMacOSBytes ||
                   macws_is_stray_metal_library_length(length) ||
                   (length >= 24 && length <= 256U * 1024U))))) {
        mapped = dispatch_data_create_map(data, &bytes, &length);
    }
    uint32_t magic = 0;
    if (bytes && length >= sizeof(magic)) memcpy(&magic, bytes, sizeof(magic));
    uint64_t hash = bytes && length
        ? macws_source_fnv1a64(bytes, length) : 0;
    dispatch_data_t selected_data = data;
    BOOL substituted = NO;
    if (getenv("MACWS_AGX_NATIVE") &&
        length == kMacWSANGLEDefaultMacOSBytes &&
        hash == kMacWSANGLEDefaultMacOSHash) {
        dispatch_data_t replacement = macws_angle_default_macabi_library();
        if (replacement) {
            selected_data = replacement;
            substituted = YES;
        }
    } else if (getenv("MACWS_AGX_NATIVE") &&
               length == kMacWSSteamANGLEDefaultMacOSBytes &&
               hash == kMacWSSteamANGLEDefaultMacOSHash) {
        dispatch_data_t replacement =
            macws_steam_angle_default_macabi_library();
        if (replacement) {
            selected_data = replacement;
            substituted = YES;
        }
    } else if (getenv("MACWS_AGX_NATIVE")) {
        const size_t count = sizeof(kMacWSStrayMetalLibraries) /
                             sizeof(kMacWSStrayMetalLibraries[0]);
        for (size_t index = 0; index < count; index++) {
            const MacWSStrayMetalLibrary *entry =
                &kMacWSStrayMetalLibraries[index];
            if (length != entry->source_length ||
                hash != entry->source_hash)
                continue;
            dispatch_data_t replacement =
                macws_stray_macabi_library(index);
            if (replacement) {
                selected_data = replacement;
                substituted = YES;
            }
            break;
        }
        if (!substituted && magic == UINT32_C(0x424c544d) && hash &&
            length >= 24 && length <= 256U * 1024U) {
            dispatch_data_t replacement =
                macws_dynamic_stray_macabi_library(length, hash);
            if (replacement) {
                selected_data = replacement;
                substituted = YES;
            }
        }
    }

    id result = g_macws_new_library_data_orig
        ? g_macws_new_library_data_orig(self, selector, selected_data, error)
        : nil;
    NSError *returned_error = error ? *error : nil;

    char path[PATH_MAX] = {0};
    size_t written_total = 0;
    // UE4 loads many one-function MTLB blobs concurrently after engine init.
    // Keep the recorder opt-in and size-bounded, but retain enough identities
    // to correlate every pipeline failure in one bounded startup instead of
    // repeatedly relaunching a thermally expensive game. Stray reaches more
    // than 128 unique libraries before the first level, so retain one further
    // bounded wave while this explicit diagnostic flag is present.
    if (diagnostic && bytes && length && length <= 64 * 1024 * 1024 &&
        sequence <= 256) {
        snprintf(path, sizeof(path),
                 "/private/tmp/macws_mtl_data_%04u_%016llx.bin",
                 sequence, (unsigned long long)hash);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)bytes;
            size_t remaining = length;
            while (remaining) {
                ssize_t written = write(fd, cursor, remaining);
                if (written <= 0) break;
                cursor += written;
                remaining -= (size_t)written;
            }
            written_total = length - remaining;
            close(fd);
        }
    }
    if (diagnostic) {
        void *return_address = ptrauth_strip(__builtin_return_address(0),
                                            ptrauth_key_return_address);
        Dl_info caller = {0};
        dladdr(return_address, &caller);
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-DATA #%u pid=%d device=%s data=%p bytes=%zu "
            "magic=%#x hash=%016llx substituted=%d selectedBytes=%zu "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s caller=%s+%#llx path=%s written=%zu\n",
            sequence, getpid(), class_getName([self class]), data, length,
            magic, (unsigned long long)hash, substituted,
            selected_data ? dispatch_data_get_size(selected_data) : 0,
            (void *)result, result ? class_getName([result class]) : "(nil)",
            returned_error ? returned_error.domain.UTF8String : "(nil)",
            returned_error ? (long)returned_error.code : 0L,
            returned_error ? returned_error.localizedDescription.UTF8String
                           : "(nil)",
            caller.dli_fname ?: "(unknown)",
            caller.dli_fbase
                ? (unsigned long long)((uintptr_t)return_address -
                                       (uintptr_t)caller.dli_fbase) : 0,
            path[0] ? path : "(none)", written_total);
    }
    if (mapped) dispatch_release(mapped);
    return result;
}

typedef id (*macws_render_pipeline_error_fn)(
    id, SEL, MTLRenderPipelineDescriptor *, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*macws_render_pipeline_options_fn)(
    id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption,
    MTLAutoreleasedRenderPipelineReflection **, NSError **)
    __attribute__((ns_returns_retained));
typedef void (^macws_render_pipeline_completion_block)(
    id<MTLRenderPipelineState>, NSError *);
typedef void (^macws_render_pipeline_reflection_completion_block)(
    id<MTLRenderPipelineState>, MTLRenderPipelineReflection *, NSError *);
typedef void (*macws_render_pipeline_async_fn)(
    id, SEL, MTLRenderPipelineDescriptor *,
    macws_render_pipeline_completion_block);
typedef void (*macws_render_pipeline_async_options_fn)(
    id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption,
    macws_render_pipeline_reflection_completion_block);
static macws_render_pipeline_error_fn g_macws_pipeline_error_orig = NULL;
static macws_render_pipeline_options_fn g_macws_pipeline_options_orig = NULL;
static macws_render_pipeline_async_fn g_macws_pipeline_async_orig = NULL;
static macws_render_pipeline_async_options_fn
    g_macws_pipeline_async_options_orig = NULL;
static _Atomic uint32_t g_macws_pipeline_diag_count = 0;

typedef id (*macws_compute_pipeline_function_fn)(
    id, SEL, id<MTLFunction>, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*macws_compute_pipeline_descriptor_fn)(
    id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption,
    MTLAutoreleasedComputePipelineReflection *, NSError **)
    __attribute__((ns_returns_retained));
static macws_compute_pipeline_function_fn
    g_macws_compute_pipeline_function_orig = NULL;
static macws_compute_pipeline_descriptor_fn
    g_macws_compute_pipeline_descriptor_orig = NULL;
static _Atomic uint32_t g_macws_compute_pipeline_diag_count = 0;

static id macws_compute_pipeline_function_diag(
        id self, SEL selector, id<MTLFunction> function, NSError **error)
    __attribute__((ns_returns_retained));
static id macws_compute_pipeline_function_diag(
        id self, SEL selector, id<MTLFunction> function, NSError **error) {
    uint32_t sequence =
        atomic_fetch_add(&g_macws_compute_pipeline_diag_count, 1) + 1;
    void *return_address = ptrauth_strip(__builtin_return_address(0),
                                        ptrauth_key_return_address);
    Dl_info caller = {0};
    dladdr(return_address, &caller);
    id result = g_macws_compute_pipeline_function_orig
        ? g_macws_compute_pipeline_function_orig(self, selector, function,
                                                  error) : nil;
    NSError *returned_error = error ? *error : nil;
    dprintf(STDERR_FILENO,
        "#### COMPUTE-PIPELINE #%u device=%s function=%s result=%p "
        "class=%s errorDomain=%s errorCode=%ld description=%s userInfo=%s "
        "caller=%s+%#llx\n",
        sequence, class_getName([self class]),
        function.name.UTF8String ?: "(nil)", (void *)result,
        result ? class_getName([result class]) : "(nil)",
        returned_error ? returned_error.domain.UTF8String : "(nil)",
        returned_error ? (long)returned_error.code : 0L,
        returned_error ? returned_error.localizedDescription.UTF8String
                       : "(nil)",
        returned_error ? returned_error.userInfo.description.UTF8String
                       : "(nil)",
        caller.dli_fname ?: "(unknown)",
        caller.dli_fbase
            ? (unsigned long long)((uintptr_t)return_address -
                                   (uintptr_t)caller.dli_fbase) : 0);
    return result;
}

static id macws_compute_pipeline_descriptor_diag(
        id self, SEL selector, MTLComputePipelineDescriptor *descriptor,
        MTLPipelineOption options,
        MTLAutoreleasedComputePipelineReflection *reflection,
        NSError **error) __attribute__((ns_returns_retained));
static id macws_compute_pipeline_descriptor_diag(
        id self, SEL selector, MTLComputePipelineDescriptor *descriptor,
        MTLPipelineOption options,
        MTLAutoreleasedComputePipelineReflection *reflection,
        NSError **error) {
    uint32_t sequence =
        atomic_fetch_add(&g_macws_compute_pipeline_diag_count, 1) + 1;
    void *return_address = ptrauth_strip(__builtin_return_address(0),
                                        ptrauth_key_return_address);
    Dl_info caller = {0};
    dladdr(return_address, &caller);
    id result = g_macws_compute_pipeline_descriptor_orig
        ? g_macws_compute_pipeline_descriptor_orig(
              self, selector, descriptor, options, reflection, error) : nil;
    NSError *returned_error = error ? *error : nil;
    NSString *label = nil;
    NSString *function_name = nil;
    @try {
        label = descriptor.label;
        function_name = descriptor.computeFunction.name;
    } @catch (NSException *exception) {
        (void)exception;
    }
    dprintf(STDERR_FILENO,
        "#### COMPUTE-PIPELINE #%u variant=descriptor device=%s "
        "options=%#llx label=%s function=%s result=%p class=%s "
        "errorDomain=%s errorCode=%ld description=%s userInfo=%s "
        "caller=%s+%#llx\n",
        sequence, class_getName([self class]),
        (unsigned long long)options, label.UTF8String ?: "(nil)",
        function_name.UTF8String ?: "(nil)", (void *)result,
        result ? class_getName([result class]) : "(nil)",
        returned_error ? returned_error.domain.UTF8String : "(nil)",
        returned_error ? (long)returned_error.code : 0L,
        returned_error ? returned_error.localizedDescription.UTF8String
                       : "(nil)",
        returned_error ? returned_error.userInfo.description.UTF8String
                       : "(nil)",
        caller.dli_fname ?: "(unknown)",
        caller.dli_fbase
            ? (unsigned long long)((uintptr_t)return_address -
                                   (uintptr_t)caller.dli_fbase) : 0);
    return result;
}

static void macws_log_pipeline_result(uint32_t sequence, id device,
                                      MTLRenderPipelineDescriptor *descriptor,
                                      id result, NSError *error,
                                      const char *variant,
                                      unsigned long long options) {
    BOOL log_this = sequence <= 192 || (!result && sequence <= 512);
    if (!log_this) return;
    NSString *label = nil, *vertex_name = nil, *fragment_name = nil;
    NSUInteger color_formats[4] = {0, 0, 0, 0};
    NSUInteger depth_format = 0, stencil_format = 0, sample_count = 0;
    @try {
        label = descriptor.label;
        vertex_name = descriptor.vertexFunction.name;
        fragment_name = descriptor.fragmentFunction.name;
        for (NSUInteger i = 0; i < 4; i++)
            color_formats[i] = descriptor.colorAttachments[i].pixelFormat;
        depth_format = descriptor.depthAttachmentPixelFormat;
        stencil_format = descriptor.stencilAttachmentPixelFormat;
        sample_count = descriptor.sampleCount;
    } @catch (NSException *exception) {
        (void)exception;
    }
    dprintf(STDERR_FILENO,
        "#### RENDER-PIPELINE #%u variant=%s device=%s options=%#llx "
        "label=%s vertex=%s fragment=%s colors=%lu,%lu,%lu,%lu "
        "depth=%lu stencil=%lu samples=%lu result=%p class=%s "
        "errorDomain=%s errorCode=%ld description=%s userInfo=%s\n",
        sequence, variant, class_getName([device class]), options,
        label.UTF8String ?: "(nil)", vertex_name.UTF8String ?: "(nil)",
        fragment_name.UTF8String ?: "(nil)",
        (unsigned long)color_formats[0], (unsigned long)color_formats[1],
        (unsigned long)color_formats[2], (unsigned long)color_formats[3],
        (unsigned long)depth_format, (unsigned long)stencil_format,
        (unsigned long)sample_count, (void *)result,
        result ? class_getName([result class]) : "(nil)",
        error ? error.domain.UTF8String : "(not-requested-or-nil)",
        error ? (long)error.code : 0L,
        error ? error.localizedDescription.UTF8String : "(nil)",
        error ? error.userInfo.description.UTF8String : "(nil)");
}

static void macws_log_vertex_descriptor(
        uint32_t sequence, MTLRenderPipelineDescriptor *descriptor) {
    MTLVertexDescriptor *vertex_descriptor = descriptor.vertexDescriptor;
    if (!vertex_descriptor) {
        dprintf(STDERR_FILENO,
            "#### RENDER-VERTEX-DESCRIPTOR #%u value=(nil)\n", sequence);
        return;
    }
    for (NSUInteger index = 0; index < 31; index++) {
        MTLVertexAttributeDescriptor *attribute =
            vertex_descriptor.attributes[index];
        if (attribute.format == MTLVertexFormatInvalid) continue;
        dprintf(STDERR_FILENO,
            "#### RENDER-VERTEX-ATTRIBUTE #%u index=%lu format=%lu "
            "offset=%lu buffer=%lu\n",
            sequence, (unsigned long)index,
            (unsigned long)attribute.format,
            (unsigned long)attribute.offset,
            (unsigned long)attribute.bufferIndex);
    }
    for (NSUInteger index = 0; index < 31; index++) {
        MTLVertexBufferLayoutDescriptor *layout =
            vertex_descriptor.layouts[index];
        if (layout.stride == 0) continue;
        dprintf(STDERR_FILENO,
            "#### RENDER-VERTEX-LAYOUT #%u index=%lu stride=%lu "
            "stepFunction=%lu stepRate=%lu\n",
            sequence, (unsigned long)index,
            (unsigned long)layout.stride,
            (unsigned long)layout.stepFunction,
            (unsigned long)layout.stepRate);
    }
}

static id macws_render_pipeline_error_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        NSError **error) __attribute__((ns_returns_retained));
static id macws_render_pipeline_error_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        NSError **error) {
    uint32_t sequence = atomic_fetch_add(&g_macws_pipeline_diag_count, 1) + 1;
    id result = g_macws_pipeline_error_orig
        ? g_macws_pipeline_error_orig(self, selector, descriptor, error) : nil;
    NSError *returned_error = error ? *error : nil;
    macws_log_pipeline_result(sequence, self, descriptor, result,
                              returned_error, "error", 0);
    return result;
}

static id macws_render_pipeline_options_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        MTLPipelineOption options,
        MTLAutoreleasedRenderPipelineReflection **reflection,
        NSError **error) __attribute__((ns_returns_retained));
static id macws_render_pipeline_options_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        MTLPipelineOption options,
        MTLAutoreleasedRenderPipelineReflection **reflection,
        NSError **error) {
    uint32_t sequence = atomic_fetch_add(&g_macws_pipeline_diag_count, 1) + 1;
    id result = g_macws_pipeline_options_orig
        ? g_macws_pipeline_options_orig(self, selector, descriptor, options,
                                        reflection, error) : nil;
    NSError *returned_error = error ? *error : nil;
    macws_log_pipeline_result(sequence, self, descriptor, result,
                              returned_error, "options", options);
    // A failed pipeline may depend on a non-obvious vertex layout even when
    // it is not a depth pass (for example Stray's color-format-115 pipeline).
    // Capture the caller's real descriptor for every failure so the exact
    // pipeline can be replayed without guessing.  This is diagnostic-only:
    // the original result and error are returned unchanged.
    if (!result) {
        macws_log_vertex_descriptor(sequence, descriptor);
    }
    // DIAGNOSTIC-ONLY A/B for the exact Stray depth-pass pair that reaches
    // the iOS 16.3 AGX compiler but returns "Compiler encountered an internal
    // error" after structural macabi retargeting.  Keep the caller's result
    // untouched.  The two private compiles distinguish a vertex-stage issue
    // from the valid macOS depth-only pattern in which a fragment function
    // retains an unused color-0 output solely while performing alpha discard.
    NSString *vertex_name = descriptor.vertexFunction.name;
    NSString *fragment_name = descriptor.fragmentFunction.name;
    BOOL exact_stray_depth_pair =
        !result &&
        [vertex_name isEqualToString:@"Main_00002957_93a803ef"] &&
        [fragment_name isEqualToString:@"Main_0000134f_d2096084"] &&
        descriptor.colorAttachments[0].pixelFormat == MTLPixelFormatInvalid &&
        descriptor.depthAttachmentPixelFormat ==
            MTLPixelFormatDepth32Float_Stencil8 &&
        descriptor.stencilAttachmentPixelFormat ==
            MTLPixelFormatDepth32Float_Stencil8;
    if (exact_stray_depth_pair && g_macws_pipeline_options_orig) {
        MTLRenderPipelineDescriptor *vertex_only = [descriptor copy];
        vertex_only.fragmentFunction = nil;
        NSError *vertex_error = nil;
        id vertex_result = g_macws_pipeline_options_orig(
            self, selector, vertex_only, options, NULL, &vertex_error);
        dprintf(STDERR_FILENO,
            "#### RENDER-PIPELINE-AB exact=stray-depth94 case=vertex-only "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s\n",
            (void *)vertex_result,
            vertex_result ? class_getName([vertex_result class]) : "(nil)",
            vertex_error ? vertex_error.domain.UTF8String : "(nil)",
            vertex_error ? (long)vertex_error.code : 0L,
            vertex_error ? vertex_error.localizedDescription.UTF8String
                         : "(nil)");
        [vertex_result release];
        [vertex_only release];

        MTLRenderPipelineDescriptor *color_control = [descriptor copy];
        color_control.colorAttachments[0].pixelFormat =
            MTLPixelFormatBGRA8Unorm;
        NSError *color_error = nil;
        id color_result = g_macws_pipeline_options_orig(
            self, selector, color_control, options, NULL, &color_error);
        dprintf(STDERR_FILENO,
            "#### RENDER-PIPELINE-AB exact=stray-depth94 case=color0-bgra8 "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s\n",
            (void *)color_result,
            color_result ? class_getName([color_result class]) : "(nil)",
            color_error ? color_error.domain.UTF8String : "(nil)",
            color_error ? (long)color_error.code : 0L,
            color_error ? color_error.localizedDescription.UTF8String
                        : "(nil)");
        [color_result release];
        [color_control release];
    }

    // DIAGNOSTIC-ONLY A/B for the next two Stray shadow-depth pipelines.
    // Both use Depth16Unorm, no color attachment, and a fragment function
    // that declares both a dead color-0 output and [[depth(any)]].  Ventura's
    // AIR loads after exact macabi retargeting, but the iOS 16.3 G13 compiler
    // returns Code=3.  These controls keep the caller-visible failure intact
    // while separating a stage compile failure from a depth-format/backend
    // combination failure.  The descriptor shape is the runtime-confirmed
    // four-pipeline Stray family (#98..#101 in stray-depth16-ab2.log); this
    // entire hook is additionally gated by the pipeline-diagnostic flag.
    BOOL exact_stray_depth16_pair =
        !result &&
        descriptor.colorAttachments[0].pixelFormat == MTLPixelFormatInvalid &&
        descriptor.depthAttachmentPixelFormat == MTLPixelFormatDepth16Unorm &&
        descriptor.stencilAttachmentPixelFormat == MTLPixelFormatInvalid;
    if (exact_stray_depth16_pair && g_macws_pipeline_options_orig &&
        access("/private/tmp/macws_pipeline_ab_diag", F_OK) == 0) {
        const char *pair_name = vertex_name.UTF8String ?: "stray-depth16";

        MTLRenderPipelineDescriptor *vertex_only = [descriptor copy];
        vertex_only.fragmentFunction = nil;
        NSError *vertex_error = nil;
        id vertex_result = g_macws_pipeline_options_orig(
            self, selector, vertex_only, options, NULL, &vertex_error);
        dprintf(STDERR_FILENO,
            "#### RENDER-PIPELINE-AB exact=%s case=vertex-only "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s\n",
            pair_name, (void *)vertex_result,
            vertex_result ? class_getName([vertex_result class]) : "(nil)",
            vertex_error ? vertex_error.domain.UTF8String : "(nil)",
            vertex_error ? (long)vertex_error.code : 0L,
            vertex_error ? vertex_error.localizedDescription.UTF8String
                         : "(nil)");
        [vertex_result release];
        [vertex_only release];

        MTLRenderPipelineDescriptor *color_control = [descriptor copy];
        color_control.colorAttachments[0].pixelFormat =
            MTLPixelFormatBGRA8Unorm;
        NSError *color_error = nil;
        id color_result = g_macws_pipeline_options_orig(
            self, selector, color_control, options, NULL, &color_error);
        dprintf(STDERR_FILENO,
            "#### RENDER-PIPELINE-AB exact=%s case=color0-bgra8 "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s\n",
            pair_name, (void *)color_result,
            color_result ? class_getName([color_result class]) : "(nil)",
            color_error ? color_error.domain.UTF8String : "(nil)",
            color_error ? (long)color_error.code : 0L,
            color_error ? color_error.localizedDescription.UTF8String
                        : "(nil)");
        [color_result release];
        [color_control release];

        MTLRenderPipelineDescriptor *depth32_control = [descriptor copy];
        depth32_control.depthAttachmentPixelFormat =
            MTLPixelFormatDepth32Float;
        NSError *depth32_error = nil;
        id depth32_result = g_macws_pipeline_options_orig(
            self, selector, depth32_control, options, NULL, &depth32_error);
        dprintf(STDERR_FILENO,
            "#### RENDER-PIPELINE-AB exact=%s case=depth32 "
            "result=%p class=%s errorDomain=%s errorCode=%ld "
            "description=%s\n",
            pair_name, (void *)depth32_result,
            depth32_result ? class_getName([depth32_result class]) : "(nil)",
            depth32_error ? depth32_error.domain.UTF8String : "(nil)",
            depth32_error ? (long)depth32_error.code : 0L,
            depth32_error ? depth32_error.localizedDescription.UTF8String
                          : "(nil)");
        [depth32_result release];
        [depth32_control release];
    }
    return result;
}

static void macws_render_pipeline_async_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        macws_render_pipeline_completion_block completion) {
    uint32_t sequence = atomic_fetch_add(&g_macws_pipeline_diag_count, 1) + 1;
    if (!g_macws_pipeline_async_orig) return;
    if (!completion) {
        // Preserve the caller's nil completion exactly.  The diagnostic must
        // not turn an invalid call into a different API contract.
        g_macws_pipeline_async_orig(self, selector, descriptor, completion);
        return;
    }
    g_macws_pipeline_async_orig(
        self, selector, descriptor,
        ^(id<MTLRenderPipelineState> pipeline, NSError *error) {
            macws_log_pipeline_result(sequence, self, descriptor, pipeline,
                                      error, "async", 0);
            completion(pipeline, error);
        });
}

static void macws_render_pipeline_async_options_diag(
        id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
        MTLPipelineOption options,
        macws_render_pipeline_reflection_completion_block completion) {
    uint32_t sequence = atomic_fetch_add(&g_macws_pipeline_diag_count, 1) + 1;
    if (!g_macws_pipeline_async_options_orig) return;
    if (!completion) {
        g_macws_pipeline_async_options_orig(self, selector, descriptor,
                                            options, completion);
        return;
    }
    g_macws_pipeline_async_options_orig(
        self, selector, descriptor, options,
        ^(id<MTLRenderPipelineState> pipeline,
          MTLRenderPipelineReflection *reflection, NSError *error) {
            macws_log_pipeline_result(sequence, self, descriptor, pipeline,
                                      error, "async-options", options);
            completion(pipeline, reflection, error);
        });
}

// Install subclass-local read-only overrides. class_addMethod is deliberate:
// if Metal inherits the implementation from IOGPUMetalDevice, changing that
// Method would affect unrelated device classes in the process. The saved IMP
// is the exact implementation that ordinary dispatch selected before the
// override, and every caller argument is forwarded unchanged.
static void macws_install_render_pipeline_diagnostic(Class agx) {
    if (!macws_pipeline_diag_enabled()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct {
            const char *name;
            IMP replacement;
            IMP *original;
        } entries[] = {
            { "newRenderPipelineStateWithDescriptor:error:",
              (IMP)macws_render_pipeline_error_diag,
              (IMP *)&g_macws_pipeline_error_orig },
            { "newRenderPipelineStateWithDescriptor:options:reflection:error:",
              (IMP)macws_render_pipeline_options_diag,
              (IMP *)&g_macws_pipeline_options_orig },
            { "newRenderPipelineStateWithDescriptor:completionHandler:",
              (IMP)macws_render_pipeline_async_diag,
              (IMP *)&g_macws_pipeline_async_orig },
            { "newRenderPipelineStateWithDescriptor:options:completionHandler:",
              (IMP)macws_render_pipeline_async_options_diag,
              (IMP *)&g_macws_pipeline_async_options_orig },
            { "newComputePipelineStateWithFunction:error:",
              (IMP)macws_compute_pipeline_function_diag,
              (IMP *)&g_macws_compute_pipeline_function_orig },
            { "newComputePipelineStateWithDescriptor:options:reflection:error:",
              (IMP)macws_compute_pipeline_descriptor_diag,
              (IMP *)&g_macws_compute_pipeline_descriptor_orig },
        };
        for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
            SEL selector = sel_registerName(entries[i].name);
            Method inherited = class_getInstanceMethod(agx, selector);
            if (!inherited) {
                dprintf(STDERR_FILENO,
                    "#### RENDER-PIPELINE diagnostic missing %s on %s\n",
                    entries[i].name, class_getName(agx));
                continue;
            }
            IMP original = method_getImplementation(inherited);
            *entries[i].original = original;
            const char *types = method_getTypeEncoding(inherited);
            BOOL added = class_addMethod(agx, selector,
                                         entries[i].replacement, types);
            if (!added) {
                Method own = class_getInstanceMethod(agx, selector);
                method_setImplementation(own, entries[i].replacement);
            }
            dprintf(STDERR_FILENO,
                "#### RENDER-PIPELINE diagnostic installed selector=%s "
                "class=%s original=%p subclassOverride=%s types=%s\n",
                entries[i].name, class_getName(agx), (void *)original,
                added ? "YES" : "NO", types ?: "(nil)");
        }
    });
}

static void macws_install_source_library_diagnostic(Class agx) {
    if (access("/private/tmp/macws_mtl_library_diag", F_OK) != 0) return;
    SEL selector = sel_registerName("newLibraryWithSource:options:error:");
    Method method = class_getInstanceMethod(agx, selector);
    if (!method) {
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-SOURCE diagnostic missing selector on %s\n",
            class_getName(agx));
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)macws_new_library_source_diag) return;
    g_macws_new_library_source_orig =
        (macws_new_library_source_fn)current;
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(agx, selector, (IMP)macws_new_library_source_diag,
                         types)) {
        Method own_method = class_getInstanceMethod(agx, selector);
        method_setImplementation(own_method,
                                 (IMP)macws_new_library_source_diag);
    }
    dprintf(STDERR_FILENO,
        "#### MTL-LIB-SOURCE diagnostic installed on %s orig=%p\n",
        class_getName(agx), (void *)current);
}

static void macws_install_data_library_compatibility(Class agx) {
    SEL selector = sel_registerName("newLibraryWithData:error:");
    Method method = class_getInstanceMethod(agx, selector);
    if (!method) {
        if (access("/private/tmp/macws_mtl_data_diag", F_OK) == 0) {
            dprintf(STDERR_FILENO,
                "#### MTL-LIB-DATA compatibility missing selector on %s\n",
                class_getName(agx));
        }
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)macws_new_library_data_compat) return;
    g_macws_new_library_data_orig = (macws_new_library_data_fn)current;
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(agx, selector, (IMP)macws_new_library_data_compat,
                         types)) {
        Method own_method = class_getInstanceMethod(agx, selector);
        method_setImplementation(own_method,
                                 (IMP)macws_new_library_data_compat);
    }
    if (access("/private/tmp/macws_mtl_data_diag", F_OK) == 0) {
        dprintf(STDERR_FILENO,
            "#### MTL-LIB-DATA compatibility installed on %s orig=%p "
            "types=%s replacement=%s steamReplacement=%s\n",
            class_getName(agx), (void *)current, types ?: "(nil)",
            kMacWSANGLEDefaultMacABIPath,
            kMacWSSteamANGLEDefaultMacABIPath);
    }
}

// Ventura QuartzCore's desktop-window-effects pipeline specializes its fixed
// shaders successfully, then the iOS AGX driver rejects the resulting
// macOS-target AIR at pipeline creation with "Target OS is incompatible".
// The same rejection occurs on the first Terminal generation for the
// unspecialized path_blit_vert_lph + attachment_clear_frag_lph pair, and in
// Dock's fluid Mission Control transition for std_vert1_lph +
// inplace_copy_lph. The fluid transition's blurred-overview variant also
// specializes downsample_blur_vert_lph + downsample_8_frag_lph; the original
// functions reached AGXMetal13_3 code=3 even after the copy pass succeeded.
// Mission Control's initial overview shadow reaches downsample_blur_vert_lph
// + downsample_4_frag_lph, while creating a Desktop from the expanded Spaces
// strip first reaches downsample_blur_vert_lph + single_pass_blur_3_lph and
// its native insertion transition later reaches
// downsample_blur_vert_lph + narrow_blur_27_frag_lph. Opening
// Maps' route chrome then reached the separate tile_downsample_4 AIR module;
// crash report 944AFB88-2054-46E9-8506-8F102F2388AD records the exact
// COREANIMATION payload `tile_pipeline=...tile_downsample_4` and AGX's
// `Target OS is incompatible` result. Creating a new Mission Control Space
// then reached `tile_pipeline=MTLPixelFormatBGRA8Unorm_tile_downsample_8`;
// WindowServer-2026-08-09-220237.ips records the same compiler-target failure
// from MetalContext::get_tile_pipeline. WindowServer-2026-08-11-001717.ips
// later recorded `spec=Pw40aXm_Tn11A2Xhf_Isrc` from BlurState::narrow_blur;
// the exact Ventura metallib maps that `Tn11` variant to
// narrow_blur_11_frag_lph. Binary inspection shows the complete narrow-blur
// family consists only of the 7/11/15/19/23/27 variants and that every member
// carries the same macOS 13.4 AIR target. Adapt the family as one compiler-
// target invariant rather than waiting for every blur radius to crash.
// WindowServer-2026-08-11-003026.ips independently records
// MTLPixelFormatBGRA10_XR_tile_downsample_2 failing from get_tile_pipeline.
// The exact library contains only tile_downsample_1/2/4/8 and all four carry
// that same desktop target, so the tile family follows the same invariant.
// The package generates a byte-validated secondary library from the device's
// own Ventura default.metallib: only these twenty-one RE- or runtime-confirmed
// AIR modules receive a macabi target triple; all other
// module bytes and every public function signature remain unchanged.
//
// Do not replace QuartzCore's default library.  A mixed-target MTLB used as the
// process-wide default makes unrelated early CoreAnimation pipelines fail.
// Instead, forward the original function name and the caller's real constant
// values to the secondary library at the specialization boundary.  This keeps
// the shader semantics and descriptor contract intact; no compiler or pipeline
// validation result is bypassed.
typedef id (*macws_library_specialize_fn)(
    id, SEL, NSString *, MTLFunctionConstantValues *, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*macws_library_function_fn)(id, SEL, NSString *)
    __attribute__((ns_returns_retained));
typedef id (*macws_library_specialize_cache_fn)(
    id, SEL, NSString *, MTLFunctionConstantValues *, id, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*macws_library_specialize_named_fn)(
    id, SEL, NSString *, MTLFunctionConstantValues *, id, NSString *,
    NSError **) __attribute__((ns_returns_retained));
static macws_library_specialize_fn g_macws_qc_specialize_basic_orig = NULL;
static macws_library_function_fn g_macws_skylight_function_orig = NULL;
static macws_library_specialize_cache_fn
    g_macws_qc_specialize_cache_orig = NULL;
static macws_library_specialize_cache_fn
    g_macws_qc_specialize_pipeline_orig = NULL;
static macws_library_specialize_named_fn
    g_macws_qc_specialize_named_orig = NULL;
static id<MTLLibrary> g_macws_qc_desktop_library = nil;
static id<MTLLibrary> g_macws_skylight_desktop_library = nil;
static id<MTLLibrary> g_macws_mpsimage_desktop_library = nil;
typedef id (*macws_function_specialize_fn)(
    id, SEL, id, id, id, NSError **) __attribute__((ns_returns_retained));
static macws_function_specialize_fn
    g_macws_desktop_function_specialize_orig = NULL;
typedef void (*macws_function_specialize_async_fn)(
    id, SEL, id, id, id, BOOL, id);
static macws_function_specialize_async_fn
    g_macws_desktop_function_specialize_async_orig = NULL;
static const char *kMacWSQCDesktopLibraryPath =
    "/usr/local/share/macws/quartzcore/"
    "default-desktop-effects-macabi.metallib";
static const size_t kMacWSQCDesktopLibraryBytes = 1052160;
static const uint64_t kMacWSQCDesktopLibraryHash =
    // macws_source_fnv1a64 intentionally retains this project's historical
    // non-standard offset basis. Runtime validation of the exact artifact
    // produces this value.
    UINT64_C(0x022d2a0179b8c898);
static const char *kMacWSSkyLightDesktopLibraryPath =
    "/usr/local/share/macws/skylight/"
    "SkyLightShaders-desktop-effects-macabi.metallib";
static const size_t kMacWSSkyLightDesktopLibraryBytes = 736944;
static const uint64_t kMacWSSkyLightDesktopLibraryHash =
    UINT64_C(0xed46648d355bb00e);
static const char *kMacWSMPSImageDesktopLibraryPath =
    "/usr/local/share/macws/mpsimage/"
    "default-desktop-effects-macabi.metallib";
static const size_t kMacWSMPSImageDesktopLibraryBytes = 16449764;
static const uint64_t kMacWSMPSImageDesktopLibraryHash =
    UINT64_C(0x117d8d75f7cff1f4);

static BOOL macws_qc_desktop_function_name(NSString *name) {
    return [name isEqualToString:@"fixed_vert_lph_spc"] ||
           [name isEqualToString:@"fixed_vert_lph_gen"] ||
           [name isEqualToString:@"fixed_frag_lph_cpf"] ||
           [name isEqualToString:@"path_blit_vert_lph"] ||
           [name isEqualToString:@"attachment_clear_frag_lph"] ||
           [name isEqualToString:@"std_vert1_lph"] ||
           [name isEqualToString:@"inplace_copy_lph"] ||
           [name isEqualToString:@"downsample_blur_vert_lph"] ||
           [name isEqualToString:@"downsample_8_frag_lph"] ||
           [name isEqualToString:@"downsample_4_frag_lph"] ||
           [name isEqualToString:@"single_pass_blur_3_lph"] ||
           [name isEqualToString:@"tile_downsample_1"] ||
           [name isEqualToString:@"tile_downsample_2"] ||
           [name isEqualToString:@"tile_downsample_4"] ||
           [name isEqualToString:@"tile_downsample_8"] ||
           [name isEqualToString:@"narrow_blur_7_frag_lph"] ||
           [name isEqualToString:@"narrow_blur_11_frag_lph"] ||
           [name isEqualToString:@"narrow_blur_15_frag_lph"] ||
           [name isEqualToString:@"narrow_blur_19_frag_lph"] ||
           [name isEqualToString:@"narrow_blur_23_frag_lph"] ||
           [name isEqualToString:@"narrow_blur_27_frag_lph"];
}

static BOOL macws_qc_desktop_base_function_name(NSString *name) {
    // Runtime-confirmed against the exact Ventura 13.4 library: these are
    // requested as ordinary base functions. CoreAnimation pairs the first two
    // for Pw40aXm_TatcA2S1Xhf and the latter two for the Mission Control
    // transition's Pw40aXm_TipcA2Xhf_Isrc copy pass.
    return [name isEqualToString:@"path_blit_vert_lph"] ||
           [name isEqualToString:@"attachment_clear_frag_lph"] ||
           [name isEqualToString:@"std_vert1_lph"] ||
           [name isEqualToString:@"inplace_copy_lph"] ||
           [name isEqualToString:@"tile_downsample_1"] ||
           [name isEqualToString:@"tile_downsample_2"] ||
           [name isEqualToString:@"tile_downsample_4"] ||
           [name isEqualToString:@"tile_downsample_8"];
}

static BOOL macws_skylight_desktop_function_name(NSString *name) {
    // Runtime metal_source_probe enumerated the exact Ventura 13.4 library:
    // all 54 functions carry the desktop AIR target, so every function must
    // come from the coherently retargeted companion library.
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Metal_hooks.x is compiled without ARC; the process-lifetime set
        // must own its storage instead of retaining an autoreleased object in
        // a static pointer.
        names = [[NSSet alloc] initWithArray:@[
            @"RippleFragment", @"GroupFadeTextureFragment",
            @"SimpleVertex", @"Backdrop_Clear_PlusL",
            @"DownsampleBloody4x", @"UberCompositeVertex",
            @"Backdrop_Clear_PlusD", @"Backdrop_Inactive_Sover",
            @"Backdrop_Clear_Sover", @"BackdropVBlur1x",
            @"SimpleTextureLightingVertex", @"BackdropVBlur2x",
            @"Downsample2x", @"Downsample4x",
            @"SimpleTextureScaleToSDRFragment", @"SimpleColorFragment",
            @"SimpleTextureLightingFragment", @"SimpleColorVertex",
            @"ColorFillYCbCr_ChromaOnly", @"UberCompositeFragment",
            @"BackdropFreezeFragment", @"SimpleTextureFragmentUV",
            @"BackdropFreezeVertex", @"ShadowCompositeFragment",
            @"InPlaceAlphaUnpremultiply", @"SimpleTextureFragment",
            @"SimpleGrayscale", @"Backdrop_Inactive_PlusL",
            @"UberResampleLanczosFragmentBGRA", @"BackdropHBlur1x",
            @"ColorFillYCbCr", @"DownsampleClampedBloody4x",
            @"DownsampleClamped4x", @"UberBackdropFragment",
            @"Backdrop_Inactive_Masked_PlusL", @"BlurCompositeVertex",
            @"Backdrop_Inactive_PlusD",
            @"Backdrop_Inactive_Masked_PlusD", @"UberBackdropVertex",
            @"BackdropHBlur2x", @"BlurUpsampleVertex",
            @"BackdropInactiveVertex", @"InPlaceSover",
            @"SimpleTextureTintFragment", @"ShadowVerticalBlurFragment",
            @"AlphaTextureFragment", @"BlurComposite",
            @"SimpleMeshVertex", @"ShadowHorizontalBlurFragment",
            @"UberResampleLanczosFragmentYCbCr", @"BlurUpsample",
            @"ShadowVerticalBlurRGBAFragment",
            @"Backdrop_Inactive_Masked_Sover", @"SimpleVertexShadow"
        ]];
    });
    return [names containsObject:name];
}

static BOOL macws_skylight_desktop_base_function_name(NSString *name) {
    // Runtime-confirmed requirements for all 54 functions: these eleven use
    // function constants and must preserve the caller's specialization path;
    // every other SkyLight function is an ordinary base request.
    if (!macws_skylight_desktop_function_name(name)) return NO;
    return !([name isEqualToString:@"UberCompositeVertex"] ||
             [name isEqualToString:@"UberCompositeFragment"] ||
             [name isEqualToString:@"BackdropFreezeFragment"] ||
             [name isEqualToString:@"ShadowCompositeFragment"] ||
             [name isEqualToString:@"UberResampleLanczosFragmentBGRA"] ||
             [name isEqualToString:@"UberBackdropFragment"] ||
             [name isEqualToString:@"ShadowVerticalBlurFragment"] ||
             [name isEqualToString:@"BlurComposite"] ||
             [name isEqualToString:@"ShadowHorizontalBlurFragment"] ||
             [name isEqualToString:@"UberResampleLanczosFragmentYCbCr"] ||
             [name isEqualToString:@"ShadowVerticalBlurRGBAFragment"]);
}

static BOOL macws_mpsimage_desktop_function_name(NSString *name) {
    return [name isEqualToString:@"sum_rgba_columns"] ||
           [name isEqualToString:@"sum_rgba_rows"];
}

static id<MTLLibrary> macws_qc_desktop_library(id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:kMacWSQCDesktopLibraryPath]
                                               options:NSDataReadingMappedIfSafe
                                                 error:nil];
        uint64_t observed_hash = data.length
            ? macws_source_fnv1a64(data.bytes, data.length) : 0;
        if (data.length != kMacWSQCDesktopLibraryBytes ||
            observed_hash != kMacWSQCDesktopLibraryHash) {
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### QC-DESKTOP-TARGET invalid-library path=%s "
                    "bytes=%lu hash=%016llx expected=%016llx\n",
                    kMacWSQCDesktopLibraryPath,
                    (unsigned long)data.length,
                    (unsigned long long)observed_hash,
                    (unsigned long long)kMacWSQCDesktopLibraryHash);
            }
            return;
        }
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:kMacWSQCDesktopLibraryPath]];
        g_macws_qc_desktop_library = [device newLibraryWithURL:url
                                                         error:&error];
        if (macws_runtime_diagnostics_enabled()) {
            dprintf(STDERR_FILENO,
                "#### QC-DESKTOP-TARGET library=%p class=%s error=%s\n",
                (void *)g_macws_qc_desktop_library,
                g_macws_qc_desktop_library
                    ? class_getName([g_macws_qc_desktop_library class])
                    : "(nil)",
                error ? error.localizedDescription.UTF8String : "(nil)");
        }
    });
    return g_macws_qc_desktop_library;
}

static id<MTLLibrary> macws_skylight_desktop_library(
        id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:kMacWSSkyLightDesktopLibraryPath]
                                               options:NSDataReadingMappedIfSafe
                                                 error:nil];
        if (data.length != kMacWSSkyLightDesktopLibraryBytes ||
            macws_source_fnv1a64(data.bytes, data.length) !=
                kMacWSSkyLightDesktopLibraryHash) {
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET invalid-library path=%s "
                    "bytes=%lu\n",
                    kMacWSSkyLightDesktopLibraryPath,
                    (unsigned long)data.length);
            }
            return;
        }
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:kMacWSSkyLightDesktopLibraryPath]];
        g_macws_skylight_desktop_library =
            [device newLibraryWithURL:url error:&error];
        if (macws_runtime_diagnostics_enabled()) {
            dprintf(STDERR_FILENO,
                "#### MACWS-METAL-TARGET library=%p path=%s error=%s\n",
                (void *)g_macws_skylight_desktop_library,
                kMacWSSkyLightDesktopLibraryPath,
                error ? error.localizedDescription.UTF8String : "(nil)");
        }
    });
    return g_macws_skylight_desktop_library;
}

static id<MTLLibrary> macws_mpsimage_desktop_library(
        id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:kMacWSMPSImageDesktopLibraryPath]
                                               options:NSDataReadingMappedIfSafe
                                                 error:nil];
        if (data.length != kMacWSMPSImageDesktopLibraryBytes ||
            macws_source_fnv1a64(data.bytes, data.length) !=
                kMacWSMPSImageDesktopLibraryHash) {
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET invalid-library path=%s "
                    "bytes=%lu\n", kMacWSMPSImageDesktopLibraryPath,
                    (unsigned long)data.length);
            }
            return;
        }
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:kMacWSMPSImageDesktopLibraryPath]];
        g_macws_mpsimage_desktop_library =
            [device newLibraryWithURL:url error:&error];
        if (macws_runtime_diagnostics_enabled()) {
            dprintf(STDERR_FILENO,
                "#### MACWS-METAL-TARGET library=%p path=%s error=%s\n",
                (void *)g_macws_mpsimage_desktop_library,
                kMacWSMPSImageDesktopLibraryPath,
                error ? error.localizedDescription.UTF8String : "(nil)");
        }
    });
    return g_macws_mpsimage_desktop_library;
}

static id<MTLLibrary> macws_qc_desktop_library_for_request(
        id self, NSString *name) {
    if (!getenv("MACWS_AGX_NATIVE")) return nil;
    BOOL quartzcore_function = macws_qc_desktop_function_name(name);
    BOOL skylight_function = macws_skylight_desktop_function_name(name);
    BOOL mpsimage_function = macws_mpsimage_desktop_function_name(name);
    if ((!quartzcore_function && !skylight_function && !mpsimage_function) ||
        self == g_macws_qc_desktop_library ||
        self == g_macws_skylight_desktop_library ||
        self == g_macws_mpsimage_desktop_library) return nil;
    id<MTLDevice> device = nil;
    @try { device = [(id<MTLLibrary>)self device]; }
    @catch (NSException *exception) { (void)exception; }
    if (!device) return nil;
    if (quartzcore_function) return macws_qc_desktop_library(device);
    if (skylight_function) return macws_skylight_desktop_library(device);
    return macws_mpsimage_desktop_library(device);
}

static id macws_skylight_function_compat(
        id self, SEL selector, NSString *name)
    __attribute__((ns_returns_retained));
static id macws_skylight_function_compat(
        id self, SEL selector, NSString *name) {
    // Runtime-confirmed by metal_source_probe against every function in the
    // exact Ventura SkyLightShaders library: redirect the 43 functions with
    // needsFunctionConstantValues=NO here, and leave the other eleven to the
    // specialization hooks below. MPSImage's runtime-confirmed reduction
    // functions have the same zero-constant contract.
    // QuartzCore's fixed_* functions are intentionally excluded because all
    // three require specialization.
    BOOL base_function_target =
        macws_qc_desktop_base_function_name(name) ||
        macws_skylight_desktop_base_function_name(name) ||
        macws_mpsimage_desktop_function_name(name);
    id<MTLLibrary> library = base_function_target
        ? macws_qc_desktop_library_for_request(self, name) : nil;
    if (library && g_macws_skylight_function_orig) {
        id function = g_macws_skylight_function_orig(
            library, selector, name);
        if (function) {
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET base-function selector=%s "
                    "name=%s function=%p\n",
                    sel_getName(selector), name.UTF8String,
                    (void *)function);
            }
            return function;
        }
    }
    return g_macws_skylight_function_orig
        ? g_macws_skylight_function_orig(self, selector, name) : nil;
}

static id macws_qc_specialization_result(
        id function, NSString *name, SEL selector,
        MTLFunctionConstantValues *constant_values, NSError **error,
        NSError *compatibility_error) {
    if (function) {
        if (error) *error = nil;
        if (macws_runtime_diagnostics_enabled()) {
            dprintf(STDERR_FILENO,
                "#### QC-DESKTOP-TARGET specialized selector=%s name=%s "
                "function=%p constantValues=%p\n",
                sel_getName(selector), name.UTF8String, (void *)function,
                (void *)constant_values);
        }
        return function;
    }
    if (macws_runtime_diagnostics_enabled()) {
        dprintf(STDERR_FILENO,
            "#### QC-DESKTOP-TARGET specialization-failed selector=%s "
            "name=%s error=%s; preserving original library path\n",
            sel_getName(selector), name.UTF8String,
            compatibility_error
                ? compatibility_error.localizedDescription.UTF8String
                : "(nil)");
    }
    return nil;
}

static id macws_desktop_specialized_function_compat(
        id self, SEL selector, id descriptor, id destination_archive,
        id function_cache, NSError **error)
    __attribute__((ns_returns_retained));
static id macws_desktop_specialized_function_compat(
        id self, SEL selector, id descriptor, id destination_archive,
        id function_cache, NSError **error) {
    NSString *name = nil;
    id<MTLDevice> device = nil;
    @try {
        name = [(id<MTLFunction>)self name];
        device = [(id<MTLFunction>)self device];
    } @catch (NSException *exception) {
        (void)exception;
    }

    BOOL quartzcore_function = macws_qc_desktop_function_name(name);
    BOOL skylight_function = macws_skylight_desktop_function_name(name);
    if (getenv("MACWS_AGX_NATIVE") && device &&
        (quartzcore_function || skylight_function) &&
        g_macws_desktop_function_specialize_orig) {
        id<MTLLibrary> library = quartzcore_function
            ? macws_qc_desktop_library(device)
            : macws_skylight_desktop_library(device);
        id base_function = library
            ? [library newFunctionWithName:name] : nil;
        if (base_function && base_function != self) {
            NSError *compatibility_error = nil;
            id specialized = g_macws_desktop_function_specialize_orig(
                base_function, selector, descriptor, destination_archive,
                function_cache, &compatibility_error);
            if (specialized) {
                if (error) *error = nil;
                if (macws_runtime_diagnostics_enabled()) {
                    dprintf(STDERR_FILENO,
                        "#### MACWS-METAL-TARGET specialized-internal "
                        "selector=%s name=%s descriptor=%p archive=%p "
                        "cache=%p function=%p\n",
                        sel_getName(selector), name.UTF8String,
                        (void *)descriptor, (void *)destination_archive,
                        (void *)function_cache, (void *)specialized);
                }
                return specialized;
            }
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET specialization-internal-failed "
                    "selector=%s name=%s descriptor=%p error=%s; "
                    "preserving original function path\n",
                    sel_getName(selector), name.UTF8String,
                    (void *)descriptor,
                    compatibility_error
                        ? compatibility_error.localizedDescription.UTF8String
                        : "(nil)");
            }
        }
    }
    return g_macws_desktop_function_specialize_orig
        ? g_macws_desktop_function_specialize_orig(
              self, selector, descriptor, destination_archive,
              function_cache, error)
        : nil;
}

static void macws_desktop_specialized_function_async_compat(
        id self, SEL selector, id descriptor, id destination_archive,
        id function_cache, BOOL synchronous, id completion_handler) {
    NSString *name = nil;
    id<MTLDevice> device = nil;
    @try {
        name = [(id<MTLFunction>)self name];
        device = [(id<MTLFunction>)self device];
    } @catch (NSException *exception) {
        (void)exception;
    }

    BOOL quartzcore_function = macws_qc_desktop_function_name(name);
    BOOL skylight_function = macws_skylight_desktop_function_name(name);
    if (getenv("MACWS_AGX_NATIVE") && device &&
        (quartzcore_function || skylight_function) &&
        g_macws_desktop_function_specialize_async_orig) {
        id<MTLLibrary> library = quartzcore_function
            ? macws_qc_desktop_library(device)
            : macws_skylight_desktop_library(device);
        id base_function = library
            ? [library newFunctionWithName:name] : nil;
        if (base_function && base_function != self) {
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET specialize-internal-async "
                    "selector=%s name=%s descriptor=%p archive=%p "
                    "cache=%p sync=%d completion=%p\n",
                    sel_getName(selector), name.UTF8String,
                    (void *)descriptor, (void *)destination_archive,
                    (void *)function_cache, synchronous,
                    (void *)completion_handler);
            }
            g_macws_desktop_function_specialize_async_orig(
                base_function, selector, descriptor, destination_archive,
                function_cache, synchronous, completion_handler);
            return;
        }
    }
    if (g_macws_desktop_function_specialize_async_orig) {
        g_macws_desktop_function_specialize_async_orig(
            self, selector, descriptor, destination_archive,
            function_cache, synchronous, completion_handler);
    }
}

static id macws_qc_specialize_basic_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, NSError **error)
    __attribute__((ns_returns_retained));
static id macws_qc_specialize_basic_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, NSError **error) {
    id<MTLLibrary> library =
        macws_qc_desktop_library_for_request(self, name);
    if (library && g_macws_qc_specialize_basic_orig) {
        NSError *compatibility_error = nil;
        id function = g_macws_qc_specialize_basic_orig(
            library, selector, name, constant_values, &compatibility_error);
        function = macws_qc_specialization_result(
            function, name, selector, constant_values, error,
            compatibility_error);
        if (function) return function;
    }
    id original_function = g_macws_qc_specialize_basic_orig
        ? g_macws_qc_specialize_basic_orig(
              self, selector, name, constant_values, error) : nil;
    // ShaderComposer::UberComposite stores the result of this call directly
    // in its unordered-map cache.  Runtime crash evidence from the native
    // three-finger Mission Control transition showed that one previously
    // unseen key stored nil, after which MetalBacking passed that nil
    // MetalShader to CopyPipelineState and faulted at this+0x28.  Record the
    // actual Metal specialization result/error here, at the upstream failure
    // boundary.  Do not replace the nil result or alter the cache contract.
    if (macws_runtime_diagnostics_enabled() &&
        ([name isEqualToString:@"UberCompositeVertex"] ||
         [name isEqualToString:@"UberCompositeFragment"] ||
         [name isEqualToString:@"UberResampleLanczosFragmentBGRA"])) {
        NSError *specialization_error = error ? *error : nil;
        dprintf(STDERR_FILENO,
            "#### SKYLIGHT-UBER-SPECIALIZE selector=%s name=%s "
            "constants=%p function=%p errorDomain=%s errorCode=%ld "
            "description=%s\n",
            sel_getName(selector), name.UTF8String,
            (void *)constant_values, (void *)original_function,
            specialization_error
                ? specialization_error.domain.UTF8String : "(nil)",
            specialization_error ? (long)specialization_error.code : 0L,
            specialization_error
                ? specialization_error.localizedDescription.UTF8String
                : "(nil)");
    }
    return original_function;
}

static id macws_qc_specialize_cache_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id function_cache,
        NSError **error) __attribute__((ns_returns_retained));
static id macws_qc_specialize_cache_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id function_cache,
        NSError **error) {
    id<MTLLibrary> library =
        macws_qc_desktop_library_for_request(self, name);
    if (library && g_macws_qc_specialize_cache_orig) {
        NSError *compatibility_error = nil;
        id function = g_macws_qc_specialize_cache_orig(
            library, selector, name, constant_values, function_cache,
            &compatibility_error);
        function = macws_qc_specialization_result(
            function, name, selector, constant_values, error,
            compatibility_error);
        if (function) return function;
    }
    return g_macws_qc_specialize_cache_orig
        ? g_macws_qc_specialize_cache_orig(
              self, selector, name, constant_values, function_cache, error)
        : nil;
}

static id macws_qc_specialize_pipeline_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id pipeline_library,
        NSError **error) __attribute__((ns_returns_retained));
static id macws_qc_specialize_pipeline_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id pipeline_library,
        NSError **error) {
    id<MTLLibrary> library =
        macws_qc_desktop_library_for_request(self, name);
    if (library && g_macws_qc_specialize_pipeline_orig) {
        NSError *compatibility_error = nil;
        id function = g_macws_qc_specialize_pipeline_orig(
            library, selector, name, constant_values, pipeline_library,
            &compatibility_error);
        function = macws_qc_specialization_result(
            function, name, selector, constant_values, error,
            compatibility_error);
        if (function) return function;
    }
    return g_macws_qc_specialize_pipeline_orig
        ? g_macws_qc_specialize_pipeline_orig(
              self, selector, name, constant_values, pipeline_library, error)
        : nil;
}

static id macws_qc_specialize_named_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id function_cache,
        NSString *specialized_name, NSError **error)
    __attribute__((ns_returns_retained));
static id macws_qc_specialize_named_compat(
        id self, SEL selector, NSString *name,
        MTLFunctionConstantValues *constant_values, id function_cache,
        NSString *specialized_name, NSError **error) {
    id<MTLLibrary> library =
        macws_qc_desktop_library_for_request(self, name);
    if (library && g_macws_qc_specialize_named_orig) {
        NSError *compatibility_error = nil;
        id function = g_macws_qc_specialize_named_orig(
            library, selector, name, constant_values, function_cache,
            specialized_name, &compatibility_error);
        function = macws_qc_specialization_result(
            function, name, selector, constant_values, error,
            compatibility_error);
        if (function) return function;
    }
    return g_macws_qc_specialize_named_orig
        ? g_macws_qc_specialize_named_orig(
              self, selector, name, constant_values, function_cache,
              specialized_name, error)
        : nil;
}

static void macws_install_qc_desktop_function_compatibility(void) {
    if (!getenv("MACWS_AGX_NATIVE")) return;
    const char *program = getprogname();
    if (!program || strcmp(program, "WindowServer") != 0) return;
    Class library_class = objc_getClass("_MTLLibrary");
    if (!library_class) return;
    struct {
        const char *selector_name;
        IMP replacement;
        IMP *original;
    } entries[] = {
        { "newFunctionWithName:",
          (IMP)macws_skylight_function_compat,
          (IMP *)&g_macws_skylight_function_orig },
        { "newFunctionWithName:constantValues:error:",
          (IMP)macws_qc_specialize_basic_compat,
          (IMP *)&g_macws_qc_specialize_basic_orig },
        { "newFunctionWithName:constantValues:functionCache:error:",
          (IMP)macws_qc_specialize_cache_compat,
          (IMP *)&g_macws_qc_specialize_cache_orig },
        { "newFunctionWithName:constantValues:pipelineLibrary:error:",
          (IMP)macws_qc_specialize_pipeline_compat,
          (IMP *)&g_macws_qc_specialize_pipeline_orig },
        { "newFunctionWithName:constantValues:functionCache:"
          "specializedName:error:",
          (IMP)macws_qc_specialize_named_compat,
          (IMP *)&g_macws_qc_specialize_named_orig },
    };
    for (size_t index = 0;
         index < sizeof(entries) / sizeof(entries[0]); index++) {
        SEL selector = sel_registerName(entries[index].selector_name);
        Method method = class_getInstanceMethod(library_class, selector);
        if (!method) {
            if (macws_runtime_diagnostics_enabled())
                dprintf(STDERR_FILENO,
                    "#### QC-DESKTOP-TARGET missing selector=%s\n",
                    entries[index].selector_name);
            continue;
        }
        IMP current = method_getImplementation(method);
        if (current == entries[index].replacement) continue;
        *entries[index].original = current;
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(library_class, selector,
                             entries[index].replacement, types)) {
            Method own_method =
                class_getInstanceMethod(library_class, selector);
            method_setImplementation(own_method,
                                     entries[index].replacement);
        }
        if (macws_runtime_diagnostics_enabled()) {
            dprintf(STDERR_FILENO,
                "#### QC-DESKTOP-TARGET installed class=%s selector=%s "
                "original=%p\n",
                class_getName(library_class), entries[index].selector_name,
                (void *)current);
        }
    }

    Class function_class = objc_getClass("_MTLFunctionInternal");
    SEL function_selector = sel_registerName(
        "newSpecializedFunctionWithDescriptor:destinationArchive:"
        "functionCache:error:");
    Method function_method = function_class
        ? class_getInstanceMethod(function_class, function_selector) : NULL;
    if (function_method) {
        IMP replacement =
            (IMP)macws_desktop_specialized_function_compat;
        IMP current = method_getImplementation(function_method);
        if (current != replacement) {
            g_macws_desktop_function_specialize_orig =
                (macws_function_specialize_fn)current;
            const char *types = method_getTypeEncoding(function_method);
            if (!class_addMethod(function_class, function_selector,
                                 replacement, types)) {
                method_setImplementation(function_method, replacement);
            }
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET installed class=%s "
                    "selector=%s original=%p types=%s\n",
                    class_getName(function_class),
                    sel_getName(function_selector), (void *)current, types);
            }
        }
    } else if (macws_runtime_diagnostics_enabled()) {
        dprintf(STDERR_FILENO,
            "#### MACWS-METAL-TARGET missing class/selector class=%p "
            "selector=%s\n", (void *)function_class,
            sel_getName(function_selector));
    }

    SEL async_selector = sel_registerName(
        "newSpecializedFunctionWithDescriptor:destinationArchive:"
        "functionCache:sync:completionHandler:");
    Method async_method = function_class
        ? class_getInstanceMethod(function_class, async_selector) : NULL;
    if (async_method) {
        IMP replacement =
            (IMP)macws_desktop_specialized_function_async_compat;
        IMP current = method_getImplementation(async_method);
        if (current != replacement) {
            g_macws_desktop_function_specialize_async_orig =
                (macws_function_specialize_async_fn)current;
            const char *types = method_getTypeEncoding(async_method);
            if (!class_addMethod(function_class, async_selector,
                                 replacement, types)) {
                method_setImplementation(async_method, replacement);
            }
            if (macws_runtime_diagnostics_enabled()) {
                dprintf(STDERR_FILENO,
                    "#### MACWS-METAL-TARGET installed class=%s "
                    "selector=%s original=%p types=%s\n",
                    class_getName(function_class),
                    sel_getName(async_selector), (void *)current, types);
            }
        }
    } else if (macws_runtime_diagnostics_enabled()) {
        dprintf(STDERR_FILENO,
            "#### MACWS-METAL-TARGET missing class/selector class=%p "
            "selector=%s\n", (void *)function_class,
            sel_getName(async_selector));
    }
}

// macOS Metal's private -[MTLDevice newEvent] contract is still used by
// Chromium 148's ANGLE Metal backend.  The exact VS Code 1.130 libGLESv2
// binary calls -newEvent at arm64 __TEXT+0x2db888, retains the result, then
// passes it to encodeSignalEvent:value: without a nil check.  On the chroot's
// iOS AGXG13GFamilyDevice the inherited method exists but returns nil, while
// public -newSharedEvent returns a working native _MTLSharedEvent.  The same
// probe on real M1 macOS returns _IOGPUMetalMTLEvent from -newEvent.
//
// Both event objects implement the operations ANGLE uses: signaledValue,
// encodeSignalEvent:value:, and encodeWaitForEvent:value:.  The standalone
// probe submits a signal-then-wait pair through the native AGX queue before
// this adapter is installed.  Adapt only this device subclass and only after
// the original method returned nil; no event validation or command is
// skipped.
typedef id (*macws_new_event_fn)(id, SEL)
    __attribute__((ns_returns_retained));
static macws_new_event_fn g_macws_new_event_orig = NULL;
static _Atomic uint32_t g_macws_new_event_fallback_count = 0;

static id macws_new_event_compat(id self, SEL selector)
    __attribute__((ns_returns_retained));
static id macws_new_event_compat(id self, SEL selector) {
    id event = g_macws_new_event_orig
        ? g_macws_new_event_orig(self, selector) : nil;
    if (event || !getenv("MACWS_AGX_NATIVE")) return event;

    id<MTLSharedEvent> shared_event = nil;
    if ([self respondsToSelector:@selector(newSharedEvent)])
        shared_event = [(id<MTLDevice>)self newSharedEvent];
    uint32_t sequence = 0;
    if (macws_runtime_diagnostics_enabled()) {
        sequence = atomic_fetch_add(&g_macws_new_event_fallback_count, 1) + 1;
    }
    if (sequence != 0 && (sequence <= 32 || (sequence % 500) == 0)) {
        fprintf(stderr,
            "#### MACWS-NEW-EVENT #%u original=nil sharedEvent=%p class=%s "
            "device=%p deviceClass=%s\n",
            sequence, (__bridge void *)shared_event,
            shared_event ? class_getName([shared_event class]) : "(nil)",
            (__bridge void *)self, class_getName([self class]));
    }
    return shared_event;
}

static void macws_install_new_event_compat(Class agx) {
    SEL selector = sel_registerName("newEvent");
    Method inherited_method = class_getInstanceMethod(agx, selector);
    IMP current = inherited_method
        ? method_getImplementation(inherited_method) : NULL;
    const char *types = inherited_method
        ? method_getTypeEncoding(inherited_method) : "@@:";
    if (current == (IMP)macws_new_event_compat) return;

    Class owner = Nil;
    for (Class candidate = agx; candidate && !owner;
         candidate = class_getSuperclass(candidate)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(candidate, &count);
        for (unsigned i = 0; methods && i < count; i++) {
            if (method_getName(methods[i]) == selector) {
                owner = candidate;
                break;
            }
        }
        free(methods);
    }

    g_macws_new_event_orig = (macws_new_event_fn)current;
    BOOL added = class_addMethod(agx, selector,
                                 (IMP)macws_new_event_compat, types);
    if (!added) {
        Method own_method = class_getInstanceMethod(agx, selector);
        method_setImplementation(own_method, (IMP)macws_new_event_compat);
    }
    fprintf(stderr,
        "#### MACWS-NEW-EVENT adapter installed deviceClass=%s owner=%s "
        "orig=%p added=%d\n",
        class_getName(agx), owner ? class_getName(owner) : "(none)",
        (void *)current, added);
}

static void install_agx_init_redirect(Class agx) {
    install_agx_initimpl_hook();  // install diag hook on texture class
    install_iogpu_init_hook();    // install diag hook on IOGPUMetalTexture super-init
    install_cbri_probe();         // log commandBufferResourceInfo returns
    macws_install_tile_descriptor_diagnostic();
    macws_install_source_library_diagnostic(agx);
    macws_install_data_library_compatibility(agx);
    macws_install_qc_desktop_function_compatibility();
    macws_install_render_pipeline_diagnostic(agx);
    macws_install_new_event_compat(agx);
    // (no pipeline fallback — see removed block above)

    SEL sel = @selector(initWithAcceleratorPort:);
    BOOL ok = class_addMethod(agx, sel, (IMP)agx_initWithAcceleratorPort_impl, "@@:i");
    fprintf(stderr, "#### MACWS_AGX_NATIVE class_addMethod(AGXG13GFamilyDevice, initWithAcceleratorPort:) = %d\n", (int)ok);

    // Preserve the driver's real memoryless capability result. The previous
    // implementation replaced every AGX implementation with `return YES`,
    // even though its own comment claimed it only supplied a missing method.
    // That is a protocol-check bypass: QuartzCore uses this result to choose
    // its tile/backdrop resource topology. Wrap only methods implemented by
    // the class itself, call their original IMP unchanged, and log the result
    // needed to correlate menu/blur rendering. Do not add a missing method.
    static dispatch_once_t smrtOnce;
    if (macws_runtime_diagnostics_enabled()) dispatch_once(&smrtOnce, ^{
        SEL smrt_sel = sel_registerName("supportsMemorylessRenderTargets");
        typedef BOOL (*smrt_fn)(id, SEL);
        __block CFMutableDictionaryRef origMap =
            CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        IMP witness = imp_implementationWithBlock(^BOOL(id instance) {
            smrt_fn original = NULL;
            for (Class c = object_getClass(instance); c && !original;
                 c = class_getSuperclass(c)) {
                original = (smrt_fn)CFDictionaryGetValue(
                    origMap, (__bridge const void *)c);
            }
            BOOL supported = original
                ? original(instance, smrt_sel) : NO;
            static _Atomic uint32_t callCount = 0;
            uint32_t call = atomic_fetch_add(&callCount, 1) + 1;
            if (call <= 16 || (call % 600) == 0) {
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE memoryless witness #%u "
                    "instance=%p class=%s original=%p -> %s\n",
                    call, (void *)instance,
                    instance ? class_getName([instance class]) : "(nil)",
                    (void *)original, supported ? "YES" : "NO");
            }
            return supported;
        });
        unsigned int n = 0;
        Class *all = objc_copyClassList(&n);
        int wrapped = 0;
        for (unsigned int i = 0; i < n; i++) {
            Class c = all[i];
            Class p = c;
            BOOL match = NO;
            while (p) {
                if (p == agx) { match = YES; break; }
                p = class_getSuperclass(p);
            }
            if (!match) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(c, &methodCount);
            Method ownMethod = NULL;
            for (unsigned int methodIndex = 0;
                 methodIndex < methodCount; methodIndex++) {
                if (method_getName(methods[methodIndex]) == smrt_sel) {
                    ownMethod = methods[methodIndex];
                    break;
                }
            }
            free(methods);
            if (!ownMethod) continue;
            IMP original = method_getImplementation(ownMethod);
            CFDictionarySetValue(origMap, (__bridge const void *)c,
                                 (const void *)original);
            method_setImplementation(ownMethod, witness);
            wrapped++;
            fprintf(stderr,
                "#### MACWS_AGX_NATIVE memoryless witness installed "
                "class=%s original=%p\n",
                class_getName(c), (void *)original);
        }
        free(all);
        fprintf(stderr,
            "#### MACWS_AGX_NATIVE memoryless witness total=%d "
            "(original results preserved)\n", wrapped);
    });

    // 2026-06-20 — Tile pipeline diagnostic for MACWS_AGX_NATIVE blur path.
    //
    // Backdrop blur on Apple Silicon TBDR uses tile shaders.  The chain is:
    //  CA::OGL::MetalContext::add_memoryless_textures  (creates intermediate target)
    //  CA::OGL::MetalContext::get_tile_pipeline        (QC 0x1897c10b0)
    //  → bl _objc_msgSend$newRenderPipelineStateWithTileDescriptor:options:reflection:error:
    //    at 0x1897c1274 — call routes through MTLDevice (= AGXG13GFamilyDevice
    //    under MACWS_AGX_NATIVE).  Returns nil + error on failure; CA's
    //    fallback is a pure-render-pipeline downsample (slower, more memory).
    //
    // Wrap AGXG13GFamilyDevice's newRenderPipelineStateWithTileDescriptor:
    // options:reflection:error: to log (a) descriptor properties on entry,
    // (b) returned pipeline state + error on exit.  This tells us whether
    // the native AGX path actually creates tile pipelines or fails internally.
    //
    // Wrapping via method_setImplementation + saved orig pointer (NOT swizzle —
    // swizzle is messy when we need to call %orig and the original might be
    // missing on chroot-loaded variant).
    {
        SEL tile_sel = sel_registerName("newRenderPipelineStateWithTileDescriptor:options:reflection:error:");
        typedef id (*tile_orig_t)(id, SEL, id, NSUInteger, void *_Nullable*, NSError **);
        // Per-class original IMP store (Apple Silicon has 2-4 device classes; map keyed by class).
        __block CFMutableDictionaryRef origMap = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        IMP wrap = imp_implementationWithBlock(^id(id self_, id desc, NSUInteger opts,
                                                   void *_Nullable* reflection, NSError **err) {
            static int log_n = 0;
            BOOL log_this = (log_n++ < 8);
            Class cls = [self_ class];
            tile_orig_t orig = (tile_orig_t)CFDictionaryGetValue(origMap, (__bridge const void *)cls);
            // Walk superclasses upward to find a stored orig if subclass missed
            for (Class c = cls; c && !orig; c = class_getSuperclass(c))
                orig = (tile_orig_t)CFDictionaryGetValue(origMap, (__bridge const void *)c);
            if (log_this) {
                NSUInteger raster_w = [desc respondsToSelector:@selector(rasterSampleCount)]
                                      ? (NSUInteger)[(id)desc rasterSampleCount] : 0;
                NSUInteger thgrp_mem = [desc respondsToSelector:@selector(threadgroupMemoryLength)]
                                       ? (NSUInteger)[(id)desc threadgroupMemoryLength] : 0;
                NSUInteger tile_w = [desc respondsToSelector:@selector(tileWidth)]
                                    ? (NSUInteger)[(id)desc tileWidth] : 0;
                NSUInteger tile_h = [desc respondsToSelector:@selector(tileHeight)]
                                    ? (NSUInteger)[(id)desc tileHeight] : 0;
                fprintf(stderr,
                    "#### TILE-PIPE in: dev=%s descClass=%s rasterSample=%lu thgrpMem=%lu tile=%lux%lu\n",
                    class_getName(cls),
                    class_getName([desc class]),
                    (unsigned long)raster_w, (unsigned long)thgrp_mem,
                    (unsigned long)tile_w, (unsigned long)tile_h);
            }
            NSError *local_err = nil;
            NSError **err_ptr = err ? err : &local_err;
            *err_ptr = nil;
            id ret = nil;
            if (orig) {
                ret = orig(self_, tile_sel, desc, opts, reflection, err_ptr);
            } else if (log_this) {
                fprintf(stderr, "#### TILE-PIPE: NO original IMP found for %s — returning nil\n",
                        class_getName(cls));
            }
            if (log_this) {
                fprintf(stderr,
                    "#### TILE-PIPE out: pipeline=%p class=%s err=%s\n",
                    (void *)ret,
                    ret ? class_getName([ret class]) : "(nil)",
                    (*err_ptr) ? [[(*err_ptr) localizedDescription] UTF8String] : "(nil)");
            }
            return ret;
        });
        // Walk subclasses + agx; for each that has the method, save orig + replace
        unsigned int nc = 0;
        Class *all = objc_copyClassList(&nc);
        int wrapped = 0;
        for (unsigned int i = 0; i < nc; i++) {
            Class c = all[i];
            Class p = c;
            BOOL match = NO;
            while (p) {
                if (p == agx) { match = YES; break; }
                p = class_getSuperclass(p);
            }
            if (!match) continue;
            Method m = class_getInstanceMethod(c, tile_sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == wrap) continue; // already wrapped (via inheritance from parent)
            CFDictionarySetValue(origMap, (__bridge const void *)c, (const void *)cur);
            method_setImplementation(m, wrap);
            wrapped++;
            fprintf(stderr,
                "#### MACWS_AGX_NATIVE tile-pipeline probe wrapped %s (orig=%p)\n",
                class_getName(c), (void *)cur);
        }
        free(all);
        fprintf(stderr,
            "#### MACWS_AGX_NATIVE tile-pipeline probe: %d class(es) wrapped\n", wrapped);
    }

    // 2026-06-20 — setFragmentTexture: / setVertexTexture: nil guard.
    //
    // CA::OGL::MetalContext::encode_placeholder_cube binds a "placeholder"
    // cube texture during backdrop-blur rendering (filter_backdrop path).
    // In chroot, cube textures fall through to the native AGX path which
    // can return nil (because AGXTexture init's cascade isn't complete for
    // non-2D types).  CA then passes nil into setFragmentTexture:, and
    // AGX::ResourceGroupUsage::setTexture dereferences the nil texture
    // pointer at offset 0x168 → EXC_BAD_ACCESS → WS dies before any
    // blur pixel reaches the framebuffer.
    //
    // Wrap [AGXG13GFamilyRenderContext setFragmentTexture:atIndex:] (and
    // setVertexTexture:atIndex: by symmetry) to NOP the call when the
    // texture argument is nil — i.e., skip the binding instead of
    // letting AGX deref nil.  This is a defensive guard, not a feature
    // patch: rendering proceeds with that texture slot UNBOUND, which
    // for placeholder bindings is exactly what we want (it's a
    // placeholder — there's no real environment map to sample).
    {
        unsigned int nc = 0;
        Class *all = objc_copyClassList(&nc);
        for (unsigned int side = 0; side < 2; side++) {
            const char *sel_name = side == 0
                ? "setFragmentTexture:atIndex:"
                : "setVertexTexture:atIndex:";
            SEL sel = sel_registerName(sel_name);
            typedef void (*set_tex_t)(id, SEL, id, NSUInteger);
            __block CFMutableDictionaryRef origMap2 =
                CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
            const char *sel_name_copy = sel_name;
            IMP wrap = imp_implementationWithBlock(^(id self_, id tex, NSUInteger idx) {
                Class cls = [self_ class];
                set_tex_t orig = (set_tex_t)CFDictionaryGetValue(origMap2,
                                                                 (__bridge const void *)cls);
                for (Class c = cls; c && !orig; c = class_getSuperclass(c))
                    orig = (set_tex_t)CFDictionaryGetValue(origMap2,
                                                           (__bridge const void *)c);
                // Read-only compositor-binding witness.  The delayed GPU
                // probe proved that the 300x210 pf550 texture contains a
                // complete Terminal window, while the display-sized result
                // contains only chrome.  Record whether that exact geometry
                // enters a fragment binding, and join it to the render target
                // captured by renderCommandEncoderWithDescriptor:.  Every
                // original argument is forwarded unchanged below.
                if (side == 0 && tex &&
                    macws_trace_small_pf550_bind_enabled()) {
                    macws_tile_texture_snapshot source =
                        macws_tile_snapshot_texture(tex);
                    if (source.width == 300 && source.height == 210 &&
                        source.pixel_format == 550) {
                        static _Atomic uint32_t bindSequence = 0;
                        uint32_t sequence =
                            atomic_fetch_add(&bindSequence, 1) + 1;
                        if (sequence <= 64) {
                            uintptr_t encoder = (uintptr_t)
                                (__bridge void *)self_;
                            macws_tile_target_entry target = {0};
                            BOOL hasTarget =
                                macws_tile_find_target(encoder, &target);
                            fprintf(stderr,
                                "#### PF550-SMALL-BIND #%u encoder=%#llx "
                                "index=%lu source=%p targetMapped=%s "
                                "targetSerial=%llu commandBuffer=%#llx\n",
                                sequence, (unsigned long long)encoder,
                                (unsigned long)idx, (void *)tex,
                                hasTarget ? "YES" : "NO",
                                (unsigned long long)
                                    (hasTarget ? target.serial : 0),
                                (unsigned long long)
                                    (hasTarget ? target.command_buffer : 0));
                            if (hasTarget) {
                                macws_tile_log_snapshot(sequence,
                                    "fragment-target", encoder, 0,
                                    target.target, target.serial,
                                    target.command_buffer);
                            }
                            macws_tile_log_snapshot(sequence,
                                "fragment-source", encoder, idx, source,
                                hasTarget ? target.serial : 0,
                                hasTarget ? target.command_buffer : 0);
                        }
                    }
                }
                if (side == 0 && tex) {
                    macws_log_video_texture_binding(self_, tex, idx);
                }
                if (!tex) {
                    static int nil_guard_log[2] = {0, 0};
                    int slot = (strstr(sel_name_copy, "Fragment") != NULL) ? 0 : 1;
                    if (nil_guard_log[slot]++ < 3) {
                        fprintf(stderr,
                            "#### NIL-TEX-GUARD: %s nil tex@%lu — skipping binding "
                            "(caller likely encode_placeholder_cube; CA tolerates unbound slot)\n",
                            sel_name_copy, (unsigned long)idx);
                    }
                    return;
                }
                if (orig) orig(self_, sel, tex, idx);
            });
            // Direct class lookup — classlist scan didn't fire previously.
            // The exact class names are AGXG13GFamilyRenderContext (and possibly
            // AGXG13GRenderContext as a parent).
            const char *rc_names[] = {
                "AGXG13GFamilyRenderContext",
                "AGXG13GRenderContext",
                "AGXRenderContext",
                "AGXG13GComputeContext",
                NULL,
            };
            int found = 0;
            for (int j = 0; rc_names[j]; j++) {
                Class c = objc_getClass(rc_names[j]);
                if (!c) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard: class %s NOT registered\n", rc_names[j]);
                    continue;
                }
                Method m = class_getInstanceMethod(c, sel);
                if (!m) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard: %s has no %s\n",
                            rc_names[j], sel_name);
                    continue;
                }
                IMP cur = method_getImplementation(m);
                if (cur == wrap) continue;
                CFDictionarySetValue(origMap2, (__bridge const void *)c, (const void *)cur);
                method_setImplementation(m, wrap);
                found++;
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE nil-guard wrapped %s on %s (orig=%p)\n",
                    sel_name, rc_names[j], (void *)cur);
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE nil-guard %s: %d class(es) wrapped\n",
                    sel_name, found);
        }
        free(all);
    }

#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
    // Swizzle AGXG13GFamilyDevice's newTextureWithDescriptor variants so the
    // ROUTE-IOSURF + memoryless storageMode swap reach SkyLight's actual
    // device call (SkyLight's compositor goes [_device newTextureWithDescriptor:]
    // where _device is AGXG13GFamilyDevice, NOT MTLSimDevice/MTLFakeDevice).
    //
    // arm64e on-device gate: MTLFakeDevice is excluded from the arm64e slice
    // (see commit 7467630 — on-device lld emits a plain non-auth rebase for
    // class_t->data and macOS libobjc autda's PAC-trap on it).  Referencing
    // MTLFakeDevice.class on arm64e fails to compile.  The chroot WS process
    // is single-arch arm64 (`Non-fat file: WindowServer is architecture: arm64`),
    // so the arm64 build of libmachook is what dyld loads into WS — the arm64
    // swizzle is sufficient.  The arm64e slice ships for arm64e processes
    // (other chroot daemons / Apple binaries) that don't need this AGX hook.
    SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
    SEL iosurf_hook_sel = @selector(hooked_newTextureWithDescriptor:iosurface:plane:);
    if (class_getInstanceMethod(agx, iosurf_sel)) {
        swizzle2(agx, iosurf_sel, MTLFakeDevice.class, iosurf_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:\n");
    }
    SEL plain_sel = @selector(newTextureWithDescriptor:);
    SEL plain_hook_sel = @selector(hooked_newTextureWithDescriptor:);
    if (class_getInstanceMethod(agx, plain_sel)) {
        swizzle2(agx, plain_sel, MTLFakeDevice.class, plain_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:\n");
    }
#endif // !arm64e || !on-device — MTLFakeDevice unavailable on arm64e on-device

    // -[AGXBuffer initWithDevice:bytes:length:options:deallocator:
    //                pinnedGPUAddress:] is what SkyLight calls (caller chain
    // confirmed via backtrace in IOConnectCallMethod_new).  When `bytes` is
    // malloc'd CPU memory the iOS IOGPU kernel rejects the sel=0xa type=0x80
    // sub-resource — Apple's malloc returns pages with a private (non-MAP_
    // SHARED) backing that the GPU can't pin.  Same trick as the existing
    // MTLFakeDevice hooked_newBufferWithBytesNoCopy: vm_remap to a MAP_SHARED
    // mirror, pass that VA to %orig, and chain the deallocator to free both.
    Class agxbuf = objc_getClass("AGXBuffer");
    if (agxbuf) {
        SEL bytes_sel = sel_registerName(
            "initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress:");
        Method m = class_getInstanceMethod(agxbuf, bytes_sel);
        if (m) {
            typedef id (*orig_t)(id, SEL, id, void *, NSUInteger,
                                  NSUInteger, void (^)(void *, NSUInteger),
                                  uint64_t);
            static orig_t s_orig = NULL;
            s_orig = (orig_t)method_getImplementation(m);
            IMP shim = imp_implementationWithBlock(^id(
                    id self, id dev, void *bytes, NSUInteger length,
                    NSUInteger opt,
                    void (^deallocator)(void *, NSUInteger),
                    uint64_t pinnedGPUAddress) {
                static int rmap_log = 0;
                static int seen_log = 0;
                BOOL diagnostics = macws_runtime_diagnostics_enabled();
                if (diagnostics && seen_log < 4) {
                    fprintf(stderr,
                        "#### AGXBuffer init-bytes ENTRY self=%p dev=%p bytes=%p len=%lu opt=%lu pin=%#llx malloc_size=%zu\n",
                        self, dev, bytes, (unsigned long)length, (unsigned long)opt,
                        (unsigned long long)pinnedGPUAddress,
                        bytes ? malloc_size(bytes) : 0);
                    seen_log++;
                }
                // 2026-06-19 — when pinnedGPUAddress != 0 the caller (e.g.
                // SkyLight MetalTiledBacking::PrepareForUse) wants the
                // buffer placed at a specific GPU VA. On macOS this maps
                // to kernel sel=0x9 type=0x80 scanout-class allocation,
                // which iOS kernel treats as a display-engine source —
                // wires our buffer to the physical LCD and corrupts iOS UI
                // (proven 2026-06-19). The kernel's NoMemory rejection is
                // the safe behavior. Short-circuit to nil here so we don't
                // call %orig (which would call IOGPUResourceCreate and try
                // sel=0x9 type=0x80). SkyLight's PrepareForUse already has
                // a tolerate-nil hook in mac_hooks.m, so nil should flow
                // through.
                // Env-gated MACWS_AGX_SKIP_PINNED_ALLOC (default ON when
                // MACWS_AGX_NATIVE=1) so we can A/B against the old
                // vm_remap path.
                // 2026-06-20 — Widened gate. Previously only fired when
                // pinnedGPUAddress != 0, but runtime traces show this init
                // is called with pinnedGPUAddress=0 from
                // MetalTiledBacking::PrepareForUse AND the internal code
                // path still goes to kernel sel=0x9 type=0x80 (which
                // iOS rejects). The init-bytes variant always routes
                // through that broken path. Redirect for any AGX-native
                // invocation.
                if (getenv("MACWS_AGX_NATIVE") &&
                    !getenv("MACWS_AGX_KEEP_PINNED_ALLOC")) {
                    // 2026-06-20 — REDIRECT-iOS-NATIVE.
                    // Previously this returned nil because the macOS-pattern
                    // pinnedGPUAddress: call routes through kernel sel=0x9
                    // type=0x80 (scanout class) which iOS structurally
                    // rejects from chroot. The "self-implement tile buffer"
                    // detour was overcomplicated.
                    //
                    // Real fix: just redirect to `[device newBufferWithLength:
                    // options:]` — iOS-native Metal's normal buffer alloc
                    // which goes through kernel sel=0x9 type=0 heap (known
                    // working, 3700+ successes per WS lifetime). The buffer
                    // gets a GPU VA from AGX (not the caller-requested
                    // pinned VA). SkyLight queries it via [buffer gpuAddress]
                    // at bind time, so the mismatch is transparent to
                    // downstream code. iOS Metal tile-pipeline support is
                    // native on M1 — blur/vibrancy should render properly
                    // once the buffer is alloc'd through this iOS-compatible
                    // path.
                    //
                    // If the caller supplied init `bytes`, memcpy them into
                    // the new buffer's CPU contents. Invoke their deallocator
                    // immediately since we no longer need the original
                    // pointer.
                    static int redirect_log = 0;
                    if (diagnostics && redirect_log++ < 8) {
                        fprintf(stderr,
                            "#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE: "
                            "self=%p dev=%p len=%lu opt=%#lx pin=%#llx "
                            "-> [dev newBufferWithLength:%lu options:%#lx]\n",
                            self, dev, (unsigned long)length,
                            (unsigned long)opt,
                            (unsigned long long)pinnedGPUAddress,
                            (unsigned long)length, (unsigned long)opt);
                    }
                    id<MTLBuffer> ios_buf = [(id<MTLDevice>)dev
                        newBufferWithLength:length options:opt];
                    if (ios_buf) {
                        if (bytes && length > 0) {
                            void *contents = [ios_buf contents];
                            if (contents) memcpy(contents, bytes, length);
                        }
                        if (deallocator) {
                            // Caller expects bytes to be freed eventually.
                            // We've copied; release them now.
                            deallocator(bytes, length);
                        }
                        if (diagnostics && redirect_log < 12) {
                            SEL gpu_address_sel =
                                sel_registerName("gpuAddress");
                            uint64_t gpu_address = 0;
                            BOOL queried_gpu_address =
                                macws_iogpu_error_diag_enabled() &&
                                [(id)ios_buf respondsToSelector:
                                    gpu_address_sel];
                            if (queried_gpu_address) {
                                typedef uint64_t (*gpu_address_fn)(id, SEL);
                                gpu_address_fn fn = (gpu_address_fn)
                                    [(id)ios_buf methodForSelector:
                                        gpu_address_sel];
                                if (fn) gpu_address =
                                    fn((id)ios_buf, gpu_address_sel);
                            }
                            fprintf(stderr,
                                "#### AGXBuffer init-bytes REDIRECT-iOS-NATIVE result: "
                                "%p class=%s len=%lu gpuAddr=%#llx "
                                "queried=%s\n",
                                (void *)ios_buf,
                                class_getName([(id)ios_buf class]),
                                (unsigned long)[ios_buf length],
                                (unsigned long long)gpu_address,
                                queried_gpu_address ? "YES" : "NO");
                        }
                    }
                    return (id)ios_buf;
                }
                if (bytes && length > 0 && malloc_size(bytes) > 0) {
                    vm_address_t mirrored = 0;
                    vm_prot_t cur_p, max_p;
                    kern_return_t kr = vm_remap(
                        mach_task_self(), &mirrored, length, 0,
                        VM_FLAGS_ANYWHERE, mach_task_self(),
                        (vm_address_t)bytes, false, &cur_p, &max_p,
                        VM_INHERIT_SHARE);
                    if (kr == KERN_SUCCESS) {
                        vm_protect(mach_task_self(), mirrored, length,
                                   NO, VM_PROT_READ | VM_PROT_WRITE);
                        void *origBytes = bytes;
                        void (^origDealloc)(void *, NSUInteger) = deallocator;
                        deallocator = ^(void *p, NSUInteger l) {
                            vm_deallocate(mach_task_self(),
                                          (vm_address_t)p, l);
                            if (origDealloc) origDealloc(origBytes, l);
                        };
                        if (rmap_log < 4) {
                            fprintf(stderr,
                                "#### AGXBuffer bytes: vm_remap'd %p -> %p (len=%lu)\n",
                                origBytes, (void*)mirrored, (unsigned long)length);
                            rmap_log++;
                        }
                        bytes = (void *)mirrored;
                    } else {
                        if (rmap_log < 4) {
                            fprintf(stderr,
                                "#### AGXBuffer bytes: vm_remap FAILED %p len=%lu kr=%d\n",
                                bytes, (unsigned long)length, kr);
                            rmap_log++;
                        }
                    }
                }
                return s_orig(self, bytes_sel, dev, bytes, length, opt,
                              deallocator, pinnedGPUAddress);
            });
            method_setImplementation(m, shim);
            fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled -[AGXBuffer initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress:]\n");
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE AGXBuffer initWithDevice:bytes:length:options:deallocator:pinnedGPUAddress: NOT FOUND\n");
        }
    }

    // No-op methods that crash in chroot because their setup dependencies
    // (timers, mempools, dispatch sources, etc.) require kernel state that
    // wasn't fully initialized. Downstream code may not actually need them.
    // setupDeferred: the dispatch_once block crashes in chroot; the AGXMetal13_3
    // binary cmp/b.hi patches in mac_hooks.m skip its mempool grow calls, but
    // post-grow code still reads uninitialized ivars. As a workaround, no-op
    // the ObjC method entirely — combined with proper init redirect this allows
    // newBuffer/newTexture/newCommandQueue/newCommandBuffer to succeed (probe7
    // stages 1-6+8). Texture/buffer creation reads OTHER ivars set by the 2-arg
    // init, not the deferred mempool ivars.
    // Note: setupDeferred is NOT noop'd here anymore. Texture init reads
    // mempool storage that setupDeferred populates (see crash in
    // AGX::Mempool<...ImageStateEncoderGen6...>::grow when WS creates an
    // IOSurface-backed texture). The alert* methods are still noop'd because
    // their dispatch_source setup fails in chroot but no other code uses them.
    const char *noopMethods[] = {
        "alertCommandBufferActivityStart",
        "alertCommandBufferActivityComplete",
        NULL
    };
    IMP noop = imp_implementationWithBlock(^void(id self) {
        // silently
    });
    for (int i = 0; noopMethods[i]; i++) {
        SEL s = sel_registerName(noopMethods[i]);
        Method m = class_getInstanceMethod(agx, s);
        if (m) {
            method_setImplementation(m, noop);
            fprintf(stderr, "#### MACWS_AGX_NATIVE noop'd %s\n", noopMethods[i]);
        }
    }
}

@interface MTLTextureDescriptorInternal : MTLTextureDescriptor
@end
%hook MTLTextureDescriptorInternal
- (MTLStorageMode)storageMode {
    MTLStorageMode mode = %orig;
    static int callCount = 0;
    if (getenv("MACWS_TEX_TRACE") && callCount < 100) {
        callCount++;
        fprintf(stderr, "#### MTL_TEX storageMode=%d fmt=%lu w=%lu h=%lu usage=%#lx\n",
            (int)mode, (unsigned long)self.pixelFormat,
            (unsigned long)self.width, (unsigned long)self.height,
            (unsigned long)self.usage);
    }
    if(mode == 1) { // MTLStorageModeManaged (macOS only) → Shared on iOS
        if (getenv("MACWS_AGX_NATIVE")) {
            // Keep the macOS-side descriptor truthful. The native AGX device
            // hooks clone and translate it at the final driver boundary.
            return mode;
        }
        self.storageMode = MTLStorageModeShared;
        return MTLStorageModeShared;
    }
    if(mode == 3 && getenv("MACWS_AGX_NATIVE")) {
        // Preserve the descriptor's real memoryless semantics for native AGX.
        //
        // Runtime-confirmed via device-side LLDB (2026-07-23): this getter
        // received MTLStorageModeMemoryless from MetalContext::StartComposite,
        // then the old code mutated the descriptor to Private.  The subsequent
        // hooked_newTextureWithDescriptor: call therefore missed its
        // storageMode==Memoryless branch and wrapped a fresh 2388x1668 RGBA16F
        // IOSurface from CA::OGL::MetalContext::add_memoryless_textures on every
        // update.  1500 such type=0x82 resources represented 28.9 GiB of create
        // traffic before WindowServer hit the 5120 MB EXC_RESOURCE watermark.
        // Native AGX on this device advertises memoryless render-target support;
        // leave mode 3 intact so the native texture path can allocate tile-memory
        // metadata rather than system-memory backing.
        static int native_memoryless_log = 0;
        if (macws_runtime_diagnostics_enabled() &&
            native_memoryless_log++ < 4) {
            fprintf(stderr,
                "#### MTL_TEX storageMode=Memoryless preserved for AGX-native descriptor=%p\n",
                (void *)self);
        }
        return mode;
    }
    if(mode == 3) { // MTLSim's memoryless support is narrower than native AGX.
                    // Keep the legacy simulator compatibility translation.
        self.storageMode = MTLStorageModePrivate;
        return MTLStorageModePrivate;
    }
    return mode;
}
%end

const char *metalSimService = "com.apple.metal.simulator";

static const char *macws_settings_extension_endpoint_name(
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

// macOS and iOS publish several identically named bootstrap services with
// different protocol/data contracts. Runtime-confirmed on iPadOS 16.3:
// SystemStatus's three original names remain active in user/501, and
// LaunchServices has the same collision: lsregister runtime-confirmed that a
// chroot client opened iOS's container csstore, whose Bundle table was empty,
// instead of a macOS database. Both chroot server listeners (flags=0x1) and
// clients enter this hook, so isolate their names symmetrically.
static const char *macws_private_lsd_service_name(const char *name) {
    if (!name) return name;
    static const char lsdPrefix[] = "com.apple.lsd.";
    BOOL isLsdService = !strncmp(name, lsdPrefix, sizeof(lsdPrefix) - 1);
    BOOL isTranslocation = !strcmp(name, "com.apple.security.translocation");
    if (!isLsdService && !isTranslocation) return name;

    // Ventura publishes two lsd jobs in different bootstrap domains.  The
    // system daemon owns the durable store and the session agent owns the
    // application-facing catalog.  iPadOS gives MacWS only one usable launchd
    // domain, so preserve that split with two private name families.  The
    // session agent is the sole client of the system dissemination/encryption
    // endpoints; ordinary GUI clients always stay on the session family.
    const char *role = getenv("MACWS_LSD_ROLE");
    BOOL systemFamily = role && !strcmp(role, "system");
    const char *suffix = isLsdService
        ? name + sizeof(lsdPrefix) - 1 : "security.translocation";
    if (role && !strcmp(role, "session") &&
        (!strcmp(suffix, "dissemination") || !strcmp(suffix, "encryption")))
        systemFamily = YES;
    if (isTranslocation && !systemFamily)
        return "com.apple.macosbooter.security.translocation";

    static __thread char rewritten[192];
    int length = snprintf(rewritten, sizeof(rewritten),
                          systemFamily
                              ? "com.apple.macosbooter.lsd.system.%s"
                              : "com.apple.macosbooter.lsd.%s",
                          suffix);
    return length > 0 && (size_t)length < sizeof(rewritten)
        ? rewritten : name;
}

static const char *macws_private_chroot_service_name(const char *name) {
    if (!name) return name;
    // RunningBoard names the launchd endpoints from the registered iOS first
    // image, while Ventura's ExtensionFoundation names them from the real
    // application-extension record.  `launchctl procinfo` runtime-confirmed
    // these carrier endpoints in the System Settings host's per-process
    // bootstrap domain. Translate both peers at the service boundary; the
    // launchd-managed ports and stock ExtensionKit protocols stay untouched.
    const char *settingsEndpoint =
        macws_settings_extension_endpoint_name(name);
    if (settingsEndpoint != name) return settingsEndpoint;
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
    if (!strcmp(name, "com.apple.dock.helper"))
        return "com.apple.macosbooter.dock.helper";
    const char *lsdEndpoint = macws_private_lsd_service_name(name);
    if (lsdEndpoint != name) return lsdEndpoint;
    if (!strcmp(name, "com.apple.locationd.desktop.agent"))
        return "com.apple.macosbooter.locationd.desktop.agent";
    if (!strcmp(name, "com.apple.locationd.desktop.registration"))
        return "com.apple.macosbooter.locationd.desktop.registration";
    if (!strcmp(name, "com.apple.locationd.desktop.spi"))
        return "com.apple.macosbooter.locationd.desktop.spi";
    if (!strcmp(name, "com.apple.locationd.desktop.synchronous"))
        return "com.apple.macosbooter.locationd.desktop.synchronous";
    if (!strcmp(name, "com.apple.locationd.simulation"))
        return "com.apple.macosbooter.locationd.simulation";
    if (!strcmp(name, "com.apple.geod"))
        return "com.apple.macosbooter.geod";
    // Mac Catalyst clients and Ventura's UIKitSystem publish the same
    // FrontBoard workspace Mach service name that iPadOS SpringBoard owns.
    // Runtime-confirmed on 2026-08-03: an unisolated chroot Maps request went
    // to SpringBoard, which rejected it with "requested scene creation but is
    // not a daemon or lacks the entitlement".  Ventura's stock
    // com.apple.uikitsystemapp.plist identifies UIKitSystem as the owner of
    // this exact service.  Rewrite both the UIKitSystem listener and chroot
    // clients symmetrically to the private launchd endpoint; the real
    // FrontBoard workspace protocol remains unchanged.  RunningBoard is
    // deliberately *not* isolated: a runtime sample of Maps on 2026-08-03
    // showed UIApplication waiting in RBSConnection's synchronous handshake,
    // while Ventura runningboardd repeatedly asserted in
    // -[RBSEmbeddedAppProcessIdentity _initEmbeddedAppWithBundleID:] when it
    // inspected the surrounding iOS launchd namespace.  iOS runningboardd
    // already owns the real process identity; only the scene workspace needs
    // to cross into Ventura UIKitSystem.
    if (!strcmp(name, "com.apple.frontboard.systemappservices"))
        return "com.apple.macosbooter.frontboard.systemappservices";
    if (!strcmp(name, "com.apple.ViewBridgeAuxiliary"))
        return "com.apple.macosbooter.ViewBridgeAuxiliary";
    if (!strcmp(name, "com.apple.extensionkitservice"))
        return "com.apple.macosbooter.extensionkitservice";
    if (!strcmp(name, "com.apple.hiservices-xpcservice"))
        return "com.apple.macosbooter.hiservices-xpcservice";
    return name;
}

typedef int (*macws_qtn_proc_init_with_self_fn)(void *process);
typedef int (*macws_qtn_proc_init_fn)(void *process);
typedef int (*macws_qtn_proc_set_flags_fn)(void *process, uint32_t flags);
typedef int (*macws_qtn_proc_apply_to_self_fn)(void *process);
typedef uint32_t (*macws_qtn_proc_get_flags_fn)(void *process);
static macws_qtn_proc_init_with_self_fn
    g_macws_orig_qtn_proc_init_with_self = NULL;
static macws_qtn_proc_init_fn g_macws_orig_qtn_proc_init = NULL;
static macws_qtn_proc_set_flags_fn g_macws_orig_qtn_proc_set_flags = NULL;
static macws_qtn_proc_apply_to_self_fn
    g_macws_orig_qtn_proc_apply_to_self = NULL;
static macws_qtn_proc_get_flags_fn g_macws_qtn_proc_get_flags = NULL;
static uint32_t g_macws_iconservices_emulated_qtn_flags = 0;

static int macws_qtn_proc_init_with_self(void *process) {
    int result = g_macws_orig_qtn_proc_init_with_self
        ? g_macws_orig_qtn_proc_init_with_self(process) : -1;
    int originalError = errno;
    if (result != 0 && originalError == 103 /* ENOPOLICY */ &&
        g_macws_iconservices_emulated_qtn_flags != 0 &&
        g_macws_orig_qtn_proc_init && g_macws_orig_qtn_proc_set_flags &&
        g_macws_orig_qtn_proc_init(process) == 0 &&
        g_macws_orig_qtn_proc_set_flags(
            process, g_macws_iconservices_emulated_qtn_flags) == 0) {
        // macOS's Quarantine sandbox extension does not exist in the iOS
        // kernel.  Once the exact startup state below has been accepted,
        // preserve the observable qtn_proc_init_with_self contract for later
        // in-process readers instead of merely hiding the kernel error.
        errno = 0;
        return 0;
    }
    // RE-confirmed via iconservicesagent arm64e +0x3494..+0x34b0: the stock
    // process first calls _qtn_proc_init_with_self and, on failure, performs
    // its supported _qtn_proc_init fallback only for ENOATTR (93).  The same
    // call in this cross-OS chroot returns ENOPOLICY (103): iOS has no macOS
    // quarantine policy for the chroot executable.  Translate only that
    // foreign-policy errno so the original binary takes its own fallback;
    // retain every other result/error and never manufacture qtn success.
    if (result != 0 && originalError == 103 /* ENOPOLICY */) {
        // macws_runtime_diagnostics_enabled() probes diagnostic sentinels
        // with access(2) in a quiet production process.  That probe sets
        // errno=ENOENT, so it must run before the caller-visible translation.
        // Restore ENOATTR last, after optional logging, because the target's
        // arm64e main explicitly compares errno with 93 at +0x34a4.
        BOOL diagnostics = macws_runtime_diagnostics_enabled();
        if (diagnostics) {
            fprintf(stderr,
                "#### ICONSERVICES qtn self errno ENOPOLICY -> ENOATTR; "
                "stock _qtn_proc_init fallback remains authoritative\n");
        }
        errno = 93; /* ENOATTR */
    } else {
        errno = originalError;
    }
    return result;
}

static int macws_qtn_proc_apply_to_self(void *process) {
    int result = g_macws_orig_qtn_proc_apply_to_self
        ? g_macws_orig_qtn_proc_apply_to_self(process) : -1;
    int savedError = errno;
    uint32_t flags = g_macws_qtn_proc_get_flags
        ? g_macws_qtn_proc_get_flags(process) : 0;
    // RE-confirmed via live LLDB against iOS 16.3 libquarantine:
    //   _qtn_proc_apply_to_self -> _qtn_proc_apply_to_pid(process, 0)
    //   -> __sandbox_ms("Quarantine", 0x57, ...)
    // and the kernel returns ENOPOLICY because iOS has no macOS Quarantine
    // named policy.  The stock iconservicesagent initializes a fresh process
    // object, sets exactly flags 0x6, and treats this unavailable security
    // hardening as fatal before publishing its XPC service.  Accept only that
    // exact cross-OS state and retain it for init_with_self readers above;
    // all other qtn errors and flag sets remain authoritative.
    if (result == -2 && savedError == 103 /* ENOPOLICY */ && flags == 0x6) {
        g_macws_iconservices_emulated_qtn_flags = flags;
        fprintf(stderr,
                "[macws] iconservicesagent: emulating qtn self-state flags=%#x; "
                "iOS kernel has no macOS Quarantine policy\n", flags);
        errno = 0;
        return 0;
    }
    errno = savedError;
    return result;
}

static void macws_install_iconservices_quarantine_fallback(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "iconservicesagent") != 0) return;
    void *symbol = dlsym(RTLD_DEFAULT, "_qtn_proc_init_with_self");
    if (!symbol) return;
    MSHookFunction(symbol, (void *)macws_qtn_proc_init_with_self,
                   (void **)&g_macws_orig_qtn_proc_init_with_self);
    symbol = dlsym(RTLD_DEFAULT, "_qtn_proc_init");
    if (symbol) g_macws_orig_qtn_proc_init = (macws_qtn_proc_init_fn)symbol;
    symbol = dlsym(RTLD_DEFAULT, "_qtn_proc_set_flags");
    if (symbol)
        g_macws_orig_qtn_proc_set_flags = (macws_qtn_proc_set_flags_fn)symbol;
    symbol = dlsym(RTLD_DEFAULT, "_qtn_proc_get_flags");
    if (symbol)
        g_macws_qtn_proc_get_flags = (macws_qtn_proc_get_flags_fn)symbol;
    symbol = dlsym(RTLD_DEFAULT, "_qtn_proc_apply_to_self");
    if (symbol) {
        MSHookFunction(symbol, (void *)macws_qtn_proc_apply_to_self,
                       (void **)&g_macws_orig_qtn_proc_apply_to_self);
    }
}

xpc_connection_t (*orig_xpc_connection_create_mach_service)(const char * name, dispatch_queue_t targetq, uint64_t flags);
xpc_connection_t hooked_xpc_connection_create_mach_service(const char * name, dispatch_queue_t targetq, uint64_t flags) {
    flags &= ~XPC_CONNECTION_MACH_SERVICE_PRIVILEGED;
    const char *originalName = name;
    name = macws_private_chroot_service_name(name);
    // Connection tracing is a diagnostic flight recorder.  Terminal used to
    // enable it implicitly, making an ordinary production shell write every
    // XPC lookup to stderr.  Keep the functional privileged-flag translation
    // below, but emit the trace only under the explicit debug environment.
    if (getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr,
            "#### XPC_TRACE mach_service create: '%s'%s%s%s flags=%#llx\n",
            originalName ?: "(null)",
            name != originalName ? " -> '" : "",
            name != originalName ? name : "",
            name != originalName ? "'" : "",
            (unsigned long long)flags);
    }
    if(name && !strncmp(name, metalSimService, strlen(metalSimService))) {
        return xpc_connection_create(metalSimService, 0);
    }
    // macOS Foundation's NSProgress registrar is provided by the native iOS
    // filecoordinationd through a byte-for-byte relay XPC bundle.  The chroot
    // process cannot resolve the user/501 endpoint directly from its root
    // application domain; routing this one name through bundle activation
    // keeps the real NSProgress protocol and replies intact.
    if (name && !strcmp(name, "com.apple.ProgressReporting")) {
        return xpc_connection_create("com.apple.ProgressReporting", targetq);
    }
    return orig_xpc_connection_create_mach_service(name, targetq, flags);
}

// Also trace xpc_connection_create (the XPC service / bundle-name style)
xpc_connection_t (*orig_xpc_connection_create)(const char *name, dispatch_queue_t queue);
xpc_connection_t hooked_xpc_connection_create(const char *name, dispatch_queue_t queue) {
    const char *originalName = name;
    name = macws_private_chroot_service_name(name);
    if (originalName && getenv("MACWS_XPC_DEBUG")) {
        fprintf(stderr, "#### XPC_TRACE service create: '%s'%s%s%s\n",
                originalName,
                name != originalName ? " -> '" : "",
                name != originalName ? name : "",
                name != originalName ? "'" : "");
    }

    return orig_xpc_connection_create(name, queue);
}

extern int xpc_connection_enable_sim2host_4sim();
%hookf(int, xpc_connection_enable_sim2host_4sim) {
    return 0;
}

// Direct Terminal launches restore saved NSWindow state without the normal
// LaunchServices display-reconfiguration pass.  A runtime VNC dump on
// 2026-07-27 showed the reused 300x210 window with only its title bar at the
// physical display's bottom edge; a GPU read of its backing simultaneously
// showed the complete Terminal contents.  Keep a normally positioned restored
// window untouched, but clamp a mostly-offscreen one into NSScreen.visibleFrame
// before asking AppKit to order and redraw it.
static void macws_terminal_order_window_onscreen(id app, id target,
                                                  id keyWindow) {
    if (!app || !target) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        app, sel_registerName("activateIgnoringOtherApps:"), YES);

    id screen = nil;
    if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(
            target, sel_registerName("respondsToSelector:"),
            sel_registerName("screen"))) {
        screen = ((id (*)(id, SEL))objc_msgSend)(
            target, sel_registerName("screen"));
    }
    if (!screen) {
        Class screenClass = objc_getClass("NSScreen");
        if (screenClass) {
            screen = ((id (*)(Class, SEL))objc_msgSend)(
                screenClass, sel_registerName("mainScreen"));
        }
    }

    BOOL moved = NO;
    CGRect frame = CGRectZero;
    CGRect visibleFrame = CGRectZero;
    double intersectionArea = 0;
    double frameArea = 0;
    if (screen) {
        frame = ((CGRect (*)(id, SEL))objc_msgSend)(
            target, sel_registerName("frame"));
        visibleFrame = ((CGRect (*)(id, SEL))objc_msgSend)(
            screen, sel_registerName("visibleFrame"));
        double left = frame.origin.x > visibleFrame.origin.x
            ? frame.origin.x : visibleFrame.origin.x;
        double bottom = frame.origin.y > visibleFrame.origin.y
            ? frame.origin.y : visibleFrame.origin.y;
        double frameRight = frame.origin.x + frame.size.width;
        double visibleRight = visibleFrame.origin.x + visibleFrame.size.width;
        double right = frameRight < visibleRight ? frameRight : visibleRight;
        double frameTop = frame.origin.y + frame.size.height;
        double visibleTop = visibleFrame.origin.y + visibleFrame.size.height;
        double top = frameTop < visibleTop ? frameTop : visibleTop;
        double intersectionWidth = right > left ? right - left : 0;
        double intersectionHeight = top > bottom ? top - bottom : 0;
        intersectionArea = intersectionWidth * intersectionHeight;
        frameArea = frame.size.width > 0 && frame.size.height > 0
            ? frame.size.width * frame.size.height : 0;

        // Reposition only when less than half of a valid window is visible.
        // This preserves ordinary user placement, including intentionally
        // partial windows, while repairing the runtime-confirmed restored
        // state whose title bar alone intersected the display.
        if (frameArea > 0 && visibleFrame.size.width > 0 &&
            visibleFrame.size.height > 0 &&
            intersectionArea * 2 < frameArea) {
            CGPoint origin = frame.origin;
            double maxX = visibleFrame.origin.x + visibleFrame.size.width -
                frame.size.width;
            double maxY = visibleFrame.origin.y + visibleFrame.size.height -
                frame.size.height;
            if (maxX < visibleFrame.origin.x) maxX = visibleFrame.origin.x;
            if (maxY < visibleFrame.origin.y) maxY = visibleFrame.origin.y;
            if (origin.x < visibleFrame.origin.x)
                origin.x = visibleFrame.origin.x;
            if (origin.x > maxX) origin.x = maxX;
            if (origin.y < visibleFrame.origin.y)
                origin.y = visibleFrame.origin.y;
            if (origin.y > maxY) origin.y = maxY;
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(
                target, sel_registerName("setFrameOrigin:"), origin);
            moved = YES;
            fprintf(stderr,
                "#### Terminal geometry: repositioned target=%p "
                "origin=(%.1f,%.1f)->(%.1f,%.1f)\n",
                target, frame.origin.x, frame.origin.y,
                origin.x, origin.y);
        }
    }
    fprintf(stderr,
        "#### Terminal geometry: target=%p key=%p frame=(%.1f,%.1f "
        "%.1fx%.1f) visible=(%.1f,%.1f %.1fx%.1f) "
        "intersection=%.1f/%.1f moved=%s\n",
        target, keyWindow, frame.origin.x, frame.origin.y,
        frame.size.width, frame.size.height, visibleFrame.origin.x,
        visibleFrame.origin.y, visibleFrame.size.width,
        visibleFrame.size.height, intersectionArea, frameArea,
        moved ? "YES" : "NO");

    ((void (*)(id, SEL, id))objc_msgSend)(
        target, sel_registerName("makeKeyAndOrderFront:"), nil);
    id content = ((id (*)(id, SEL))objc_msgSend)(
        target, sel_registerName("contentView"));
    if (content) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            content, sel_registerName("setNeedsDisplay:"), YES);
        ((void (*)(id, SEL))objc_msgSend)(
            content, sel_registerName("displayIfNeeded"));
    }
    ((void (*)(id, SEL))objc_msgSend)(
        target, sel_registerName("displayIfNeeded"));
}

__attribute__((constructor)) static void InitMetalHooks() {
    macws_record_xpc_service_context_if_requested();
    const char *initialProgram = getprogname();
    if (initialProgram &&
        (strcmp(initialProgram, "com.apple.hiservices-xpcservice") == 0 ||
         strcmp(initialProgram, "fontd") == 0 ||
         strcmp(initialProgram, "fontworker") == 0)) {
        // These are headless request brokers. Their bootstrap/XPC adaptation
        // is implemented by static interposes in mac_hooks.m; none creates a
        // Metal device or presents UI.
        //
        // Runtime-confirmed on 2026-08-06: Terminal pid 95025 was permanently
        // blocked in HIS_XPC_GetCapsLockLanguageSwitch while the corresponding
        // HIServices pid 86010 had never reached xpc_main. A two-second sample
        // placed every main-thread sample in InitMetalHooks -> MSHookFunction
        // -> CydiaSubstrate stopAllThreads, specifically at the return from
        // the unnecessary CGSSessionCopyCurrentSessionProperties hook. Keep
        // Keep each service on its real protocol and skip only hook families
        // it cannot consume, so its listener becomes available before clients
        // issue synchronous requests. Runtime fontd sampling on 2026-08-06
        // likewise showed no UI work: after its missing FontWorker dependency
        // made main return, only an injected exception thread kept the
        // otherwise-dead PID visible.
        return;
    }
    macws_install_iconservices_quarantine_fallback();
    macws_install_cgsession_login_handoff_compatibility();
    macws_install_launchpad_mount_namespace_compatibility();
    macws_install_launchpad_source_diagnostics();
    macws_install_app_lifecycle_diagnostics();
    macws_install_catalyst_frontboard_route();
    macws_install_uikitsystem_exec_identity_refresh();
    _dyld_register_func_for_add_image(
        macws_uikitsystem_exec_identity_image_added);
    macws_register_catalyst_application_with_fuseboard();
    macws_install_catalyst_launch_compatibility();
    macws_install_catalyst_launch_diagnostics();
    macws_install_catalyst_drawable_publisher();
    const char *utility_process = getenv("MACWS_UTILITY_PROCESS");
    if (utility_process && strcmp(utility_process, "1") == 0) return;
    const char *shell_env = getenv("VSCODE_RESOLVING_ENVIRONMENT");
    if (shell_env && strcmp(shell_env, "1") == 0) return;
    const char *appExtension = getenv("MACWS_APP_EXTENSION");
    const BOOL isHostedAppExtension =
        appExtension && strcmp(appExtension, "1") == 0;
    MacWSInstallExtensionRuntimeCompatibility();
    if (isHostedAppExtension) {
        // LaunchServices is not a direct dependency of libmachook.  In the
        // ExtensionKit executable it can be mapped after this constructor,
        // so retry on the listener's main queue before the first inbound host
        // request is handled.  The installer is idempotent.
        dispatch_async(dispatch_get_main_queue(), ^{
            MacWSInstallExtensionRuntimeCompatibility();
        });
    }

    // The callback is inert unless the focused source-library diagnostic
    // sentinel existed at process start. dyld also invokes it immediately for
    // already-loaded images, so it is race-free for Metal-linked clients.
    _dyld_register_func_for_add_image(
        macws_install_metal_library_boundary_diagnostics);

    // QuartzCore and SkyLight specialize their base MTLFunction objects as
    // soon as the first AGX device becomes available. Installing this adapter
    // from install_agx_init_redirect() was therefore too late on a clean
    // launch. Metal.framework is a load dependency of this image, so its
    // concrete library/function classes are registered by the time this
    // constructor runs. Keep the AGX-init call as an idempotent fallback for
    // unusual dyld ordering, but wrap the specialization boundary first.
    macws_install_qc_desktop_function_compatibility();

    // Install plugin-class hook unconditionally — it inspects MACWS_AGX_NATIVE
    // at first invocation and decides whether to return AGXG13GFamilyDevice or Nil.
    MSImageRef sys = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Metal");
    %init(getMetalPluginClassForService = MSFindSymbol(sys, "_getMetalPluginClassForService"));

    // NOTE: we used to short-circuit out of all sim-related init when
    // MACWS_AGX_NATIVE=1, but Metal.framework still needs the EnableSimApple5
    // CFPref + MTLSimDriver registration paths so that fallback codepaths
    // resolve without nil-deref crashes when AGX-native paths exit early.
    // Leave the rest of init running unconditionally; the plugin-class hook
    // alone is enough to route the device choice.

    dispatch_async(dispatch_get_main_queue(), ^{
        // force Apple 5 profile.
        // NOTE: do NOT pass ObjC/CF constant literals (@"..." / @(YES)) here. On the
        // on-device lld arm64e build, the constant CFString's pointer still PAC-faults
        // when CoreFoundation reads it (autda DA trap in CFStringGetCharacterAtIndex
        // via _CFXPreferences withSearchListForIdentifier) -- even with -fixup_chains.
        // Build the strings at runtime (proper isa from the CF allocator) instead.
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, "EnableSimApple5", kCFStringEncodingUTF8);
        CFStringRef app = CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.Metal", kCFStringEncodingUTF8);
        CFPreferencesSetAppValue(key, kCFBooleanTrue, app);
        CFRelease(key);
        CFRelease(app);
    });

    // libxpc calls these entry points from within the dyld shared cache, so a
    // client dylib's static interpose cannot see every lookup.  This matters
    // for ExtensionKit: appearance-static-route-oslog.txt runtime-confirmed
    // that Appearance's com.apple.lsd.modifydb requests still reached the
    // original iPadOS name and were rejected by its settings-extension
    // sandbox, ending in _LSPluginFindWithPlatformInfo:699 / -10814.
    //
    // MSHookFunction dirties the containing executable page.  The launch
    // proxy now marks the final post-exec extension process CS_DEBUGGED before
    // InitStuff returns (and EnableJIT asserts that state), so the same two
    // narrow hooks used by ordinary MacWS clients are valid here too.  Do not
    // broaden this to any of libxpc's protocol or object functions.
    MSImageRef xpc =
        MSGetImageByName("/usr/lib/system/libxpc.dylib");
    MSHookFunction(
        MSFindSymbol(xpc, "_xpc_connection_create_mach_service"),
        hooked_xpc_connection_create_mach_service,
        (void *)&orig_xpc_connection_create_mach_service);
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create"),
                   hooked_xpc_connection_create,
                   (void *)&orig_xpc_connection_create);

    dispatch_async(dispatch_get_main_queue(), ^{
        // (NOTE: tried calling MTLCreateSystemDefaultDevice here to force Metal load
        // for the black-tab fix — it DEADLOCKED chroot AppKit startup. Revisit via
        // a background queue load or hook on NSWindow display time.)

        if (macws_runtime_diagnostics_enabled() ||
            macws_iogpu_callback_diag_enabled()) {
            macws_install_iogpu_callback_diagnostics();
        }
        // A direct executable launch does not carry LaunchServices' normal
        // open-application AppleEvent.  This Terminal image also deliberately
        // returns NO from -applicationShouldOpenUntitledFile:.  Its real user
        // action is -[TTApplication newShell:] (RE-confirmed in the arm64e
        // binary by dyld_info at VM offset 0x10006e6dc), so invoke that actual
        // application method after didFinishLaunching instead of guessing
        // responder-chain selectors that this image does not implement.
        const char *prog = getprogname();
        if (prog && strstr(prog, "Terminal")) {
            // Schedule slightly after main queue so app's didFinishLaunching has fired.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                fprintf(stderr, "#### Terminal direct newShell: request\n");
                Class app_cls = objc_getClass("NSApplication");
                id app = ((id (*)(Class, SEL))objc_msgSend)(app_cls, sel_registerName("sharedApplication"));
                SEL newShell = sel_registerName("newShell:");
                BOOL responds = app && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
                    app, sel_registerName("respondsToSelector:"), newShell);
                fprintf(stderr, "#### NSApp=%p class=%s responds(newShell:)=%d\n",
                    app, app ? object_getClassName(app) : "nil", responds);
                id windows = app ? ((id (*)(id, SEL))objc_msgSend)(
                    app, sel_registerName("windows")) : nil;
                NSUInteger count = windows
                    ? ((NSUInteger (*)(id, SEL))objc_msgSend)(
                        windows, sel_registerName("count")) : 0;
                NSUInteger visible = 0;
                id visibleWindow = nil;
                for (NSUInteger i = 0; i < count; i++) {
                    id window = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
                        windows, sel_registerName("objectAtIndex:"), i);
                    if (window && ((BOOL (*)(id, SEL))objc_msgSend)(
                            window, sel_registerName("isVisible"))) {
                        visible++;
                        if (!visibleWindow) visibleWindow = window;
                    }
                }
                fprintf(stderr,
                    "#### Terminal direct newShell: existing windows=%lu visible=%lu\n",
                    (unsigned long)count, (unsigned long)visible);
                if (responds && visible == 0) {
                    ((void (*)(id, SEL, id))objc_msgSend)(app, newShell, nil);
                    windows = ((id (*)(id, SEL))objc_msgSend)(
                        app, sel_registerName("windows"));
                    count = windows
                        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(
                            windows, sel_registerName("count")) : 0;
                    fprintf(stderr,
                        "#### Terminal newShell: returned windows=%lu\n",
                        (unsigned long)count);
                    id keyWindow = ((id (*)(id, SEL))objc_msgSend)(
                        app, sel_registerName("keyWindow"));
                    id target = keyWindow;
                    if (!target && count != 0) {
                        target = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
                            windows, sel_registerName("objectAtIndex:"), 0);
                    }
                    macws_terminal_order_window_onscreen(
                        app, target, keyWindow);
                } else if (responds) {
                    // Terminal restores its saved windows before this block.
                    // Starting another shell on every launch accumulated 29
                    // visible windows during repeated WS recovery tests. Keep
                    // the restored session, but use ordinary AppKit ordering
                    // and display APIs to generate a legitimate front-window
                    // transaction for the first shared frame.
                    id keyWindow = ((id (*)(id, SEL))objc_msgSend)(
                        app, sel_registerName("keyWindow"));
                    id target = keyWindow ?: visibleWindow;
                    macws_terminal_order_window_onscreen(
                        app, target, keyWindow);
                    fprintf(stderr,
                        "#### Terminal direct newShell: reused visible window=%p key=%p\n",
                        target, keyWindow);
                }
            });
        }
    });
    // xpc_add_bundle mutates the current process's pid-domain registration.
    // A RunningBoard-hosted ExtensionKit process already receives every
    // endpoint in its launch overlay and must not uncork/rebuild that domain.
    // Runtime evidence: Appearance's first call below reached
    // _xpc_init_pid_domain and instruction-faulted in _xpc_uint64_create_tagged
    // (Appearance-2026-08-04-030014.ips).  Preserve Metal and connection hooks
    // above, but leave service registration to the host/private launchd jobs.
    if (isHostedAppExtension) {
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                "#### XPC bundle registration skipped: hosted app extension\n");
        }
        return;
    }
    // register MTLSimDriverHost.xpc
    char frameworkPath[PATH_MAX];
    // NSLog(@"#### debugbydcmmc register MTLSimDriverHost.xpc");
    snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc", JBROOT_PATH("/usr/macOS/Frameworks"));
    xpc_add_bundle(frameworkPath, 2);

    // Register iOS-platform launch proxies only after libxpc and the ObjC/CF
    // runtime have completed initialization.  Calling the private bootstrap
    // routine from dyld's libxpc add-image callback is too early: it returned
    // zero but later xpc_connection_create still received Connection Invalid
    // and launchd never created an xpcproxy instance.  xpc_add_bundle is the
    // public wrapper used by the already-working MTLSim service above; target
    // disassembly confirms flag 2 maps to path value 0x1001 and calls the same
    // routine after `_xpc_uncork_domain`.  The real macOS SETEXEC targets are
    // signed/trusted by postinst before any client can request them.
    static const char *const proxyRelativePaths[] = {
        "/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc",
        "/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc",
        "/AppKit.framework/Versions/C/XPCServices/OpenAndSavePanelProxy.xpc",
        "/Dock.framework/Versions/A/XPCServices/DockHelperProxy.xpc",
        "/ExtensionFoundation.framework/Versions/A/XPCServices/ExtensionKitProxy.xpc",
        "/FileCoordination.framework/Versions/A/XPCServices/FileCoordinationProxy.xpc",
        NULL,
    };
    for (const char *const *relative = proxyRelativePaths; *relative; relative++) {
        snprintf(frameworkPath, sizeof(frameworkPath), "%s%s",
                 JBROOT_PATH("/usr/macOS/Frameworks"), *relative);
        xpc_add_bundle(frameworkPath, 2);
    }
    snprintf(frameworkPath, sizeof(frameworkPath), "%s",
             JBROOT_PATH("/Applications/MacWSCatalystLauncher.app/PlugIns/SettingsExtensionProxy.appex"));
    xpc_add_bundle(frameworkPath, 2);
}
