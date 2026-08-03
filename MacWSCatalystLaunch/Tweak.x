@import Foundation;

#import <xpc/xpc.h>

#include <limits.h>
#include <string.h>

// Runtime-confirmed on iPadOS 16.3.1 (RunningBoard 803.120.4):
// RBLaunchdInterface's ABI is @48@0:8@16@24@32o^@40 and System Settings
// submits the executable as __NSCFString, the overlay as OS_xpc_dictionary,
// and the launch domain as OSLaunchdDomain.  The stock Appearance overlay
// already carries the correct original RunningBoard extension identity,
// settings-extensions sandbox, ViewBridge/ExtensionKit subservices and
// _NSApplicationMain run-loop contract.  Preserve all of that data.
//
// iOS launchd cannot use a macOS Mach-O as the first image: an otherwise
// identical RootDirectory probe runs an iOS binary successfully but leaves a
// macOS binary at "spawn scheduled", last exit 78/EX_CONFIG.  Therefore only
// the launch image is translated to this registered iOS freestanding proxy.
// It enters the chroot with raw syscalls before libSystem/libxpc consumes the
// one-shot extension launch context, then execs the original macOS extension.

static const char *const MacWSAppearanceExecutable =
    "/System/Library/ExtensionKit/Extensions/Appearance.appex/Contents/"
    "MacOS/Appearance";
static const char *const MacWSSettingsExtensionProxyExecutable =
    "/var/jb/Applications/SettingsExtensionProxy.app/"
    "SettingsExtensionProxy";
static const char *const MacWSAppearanceMetadataSuffix =
    "/MacWSCatalystLauncher.app/PlugIns/SettingsExtensionProxy.appex/"
    "SettingsExtensionProxy";

static BOOL MacWSStringHasSuffix(const char *string, const char *suffix) {
    if (!string || !suffix) return NO;
    size_t stringLength = strlen(string);
    size_t suffixLength = strlen(suffix);
    return suffixLength <= stringLength &&
        memcmp(string + stringLength - suffixLength, suffix, suffixLength) == 0;
}

static BOOL MacWSIsAppearanceExecutable(const char *executable) {
    return executable &&
        (strcmp(executable, MacWSAppearanceExecutable) == 0 ||
         MacWSStringHasSuffix(executable, MacWSAppearanceMetadataSuffix));
}

static BOOL MacWSCopyCFString(id object, char output[PATH_MAX]) {
    if (!object || !output ||
        CFGetTypeID((__bridge CFTypeRef)object) != CFStringGetTypeID()) {
        return NO;
    }
    output[0] = '\0';
    return CFStringGetCString((__bridge CFStringRef)object, output, PATH_MAX,
                              kCFStringEncodingUTF8);
}

static BOOL MacWSPrepareAppearanceOverlay(xpc_object_t overlay) {
    if (!overlay || xpc_get_type(overlay) != XPC_TYPE_DICTIONARY) return NO;
    xpc_object_t service = xpc_dictionary_get_value(overlay, "XPCService");
    if (!service || xpc_get_type(service) != XPC_TYPE_DICTIONARY) return NO;

    // The first image is now an iOS executable.  Platform=1 in the stock
    // overlay describes the eventual macOS extension and would make launchd
    // reject the proxy before its raw main runs; Platform=2 describes the
    // proxy actually submitted to launchd.  The original target stays in the
    // environment for the proxy's validated post-chroot exec.
    xpc_dictionary_set_int64(service, "Platform", 2);
    xpc_dictionary_set_string(service, "Program",
                              MacWSSettingsExtensionProxyExecutable);
    // `settings-extensions` is a macOS launchd builtin profile.  Runtime on
    // iPadOS 16.3.1 rejected it before proxy main with sandbox err=22/EINVAL.
    // Remove only that cross-platform override.  The freestanding proxy is a
    // hidden APPL service-cache entry rather than an appex because iPadOS
    // forces its PluginKit `container` profile onto appex launches before
    // main; that profile denies file-chroot even with no-sandbox entitlement.
    xpc_dictionary_set_value(service, "_SandboxProfile", NULL);

    xpc_object_t arguments = xpc_array_create(NULL, 0);
    xpc_array_set_string(arguments, XPC_ARRAY_APPEND,
                         MacWSSettingsExtensionProxyExecutable);
    xpc_dictionary_set_value(service, "ProgramArguments", arguments);

    xpc_object_t environment =
        xpc_dictionary_get_value(service, "EnvironmentVariables");
    if (!environment ||
        xpc_get_type(environment) != XPC_TYPE_DICTIONARY) {
        environment = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_value(service, "EnvironmentVariables",
                                 environment);
    }
    xpc_dictionary_set_string(environment, "MACWS_EXTENSION_TARGET",
                              MacWSAppearanceExecutable);
    return YES;
}

%hook RBLaunchdInterface

- (id)submitExtension:(id)path
               overlay:(xpc_object_t)overlay
                domain:(id)domain
                 error:(NSError **)error {
    char executable[PATH_MAX];
    if (!MacWSCopyCFString(path, executable) ||
        !MacWSIsAppearanceExecutable(executable) ||
        !MacWSPrepareAppearanceOverlay(overlay)) {
        return %orig(path, overlay, domain, error);
    }

    NSString *proxyPath =
        [[NSString alloc] initWithUTF8String:
            MacWSSettingsExtensionProxyExecutable];
    return %orig(proxyPath, overlay, domain, error);
}

%end
