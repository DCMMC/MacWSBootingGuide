// Freestanding launch stub for macOS XPC services inside the chroot.
//
// This executable deliberately has no libSystem dependency.  xpcproxy gives
// the service process a one-shot launchd receive right in XPC_FLAGS/XPC_*.
// Merely starting libSystem would initialize libxpc before main(), consume
// that context for the iOS stub, and leave the macOS executable created by a
// later execve() classified as an unmanaged process.  Enter the chroot and
// replace this image using raw BSD syscalls so the real service is the first
// runtime in this task to consume the XPC launch context.

#include <stddef.h>
#include <stdint.h>

#define MACWS_SYS_exit    1
#define MACWS_SYS_chdir  12
#define MACWS_SYS_execve 59
#define MACWS_SYS_chroot 61

#define MACWS_ROOTFS "/var/mnt/rootfs"
#define MACWS_MAX_ARGUMENTS 128
#define MACWS_MAX_ENVIRONMENT 256

static long MacWSSyscall1(long number, const void *argument0) {
    register long x0 __asm("x0") = (long)argument0;
    register long x16 __asm("x16") = number;
    __asm__ volatile("svc #0x80" : "+r"(x0) : "r"(x16) : "memory", "cc");
    return x0;
}

static long MacWSSyscall3(long number, const void *argument0,
                          const void *argument1, const void *argument2) {
    register long x0 __asm("x0") = (long)argument0;
    register long x1 __asm("x1") = (long)argument1;
    register long x2 __asm("x2") = (long)argument2;
    register long x16 __asm("x16") = number;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x16)
                     : "memory", "cc");
    return x0;
}

__attribute__((noreturn))
static void MacWSExit(long status) {
    (void)MacWSSyscall1(MACWS_SYS_exit, (const void *)status);
    __builtin_unreachable();
}

static int MacWSStringContains(const char *string, const char *needle) {
    if (!string || !needle || !*needle) return 0;
    for (const char *start = string; *start; start++) {
        const char *left = start;
        const char *right = needle;
        while (*left && *right && *left == *right) {
            left++;
            right++;
        }
        if (!*right) return 1;
    }
    return 0;
}

static int MacWSHasEnvironmentKey(const char *entry, const char *key) {
    if (!entry || !key) return 0;
    while (*key && *entry == *key) {
        entry++;
        key++;
    }
    return !*key && *entry == '=';
}

static const char *MacWSTargetForProxy(const char *program) {
    if (MacWSStringContains(program, "HIServicesProxy")) {
        return "/System/Library/Frameworks/ApplicationServices.framework/"
               "Versions/A/Frameworks/HIServices.framework/Versions/A/"
               "XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/"
               "MacOS/com.apple.hiservices-xpcservice";
    }
    if (MacWSStringContains(program, "OpenAndSavePanelProxy")) {
        return "/System/Library/Frameworks/AppKit.framework/Versions/C/"
               "XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/"
               "Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService";
    }
    return "/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/"
           "XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/"
           "ViewBridgeAuxiliary";
}

int main(int argc, char *argv[], char *envp[]) {
    static char *targetArguments[MACWS_MAX_ARGUMENTS];
    static char *targetEnvironment[MACWS_MAX_ENVIRONMENT];
    static char insertLibrary[] =
        "DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib";
    static char home[] = "HOME=/Users/root";
    static char temporaryDirectory[] = "TMPDIR=/tmp";
    static char nanoZone[] = "MallocNanoZone=0";

    const char *target = MacWSTargetForProxy(
        argc > 0 && argv ? argv[0] : (const char *)0);

    size_t argumentCount = 0;
    targetArguments[argumentCount++] = (char *)target;
    for (int index = 1; index < argc &&
         argumentCount + 1 < MACWS_MAX_ARGUMENTS; index++) {
        targetArguments[argumentCount++] = argv[index];
    }
    targetArguments[argumentCount] = (char *)0;

    size_t environmentCount = 0;
    for (char **entry = envp; entry && *entry &&
         environmentCount + 5 < MACWS_MAX_ENVIRONMENT; entry++) {
        // Replace only values that must describe the macOS process.  Preserve
        // XPC_FLAGS and every launchd-provided entry byte-for-byte.
        if (MacWSHasEnvironmentKey(*entry, "DYLD_INSERT_LIBRARIES") ||
            MacWSHasEnvironmentKey(*entry, "HOME") ||
            MacWSHasEnvironmentKey(*entry, "TMPDIR") ||
            MacWSHasEnvironmentKey(*entry, "MallocNanoZone")) continue;
        targetEnvironment[environmentCount++] = *entry;
    }
    targetEnvironment[environmentCount++] = insertLibrary;
    targetEnvironment[environmentCount++] = home;
    targetEnvironment[environmentCount++] = temporaryDirectory;
    targetEnvironment[environmentCount++] = nanoZone;
    targetEnvironment[environmentCount] = (char *)0;

    if (MacWSSyscall1(MACWS_SYS_chroot, MACWS_ROOTFS) != 0) MacWSExit(111);
    if (MacWSSyscall1(MACWS_SYS_chdir, "/") != 0) MacWSExit(112);
    (void)MacWSSyscall3(MACWS_SYS_execve, target, targetArguments,
                        targetEnvironment);
    MacWSExit(113);
}
