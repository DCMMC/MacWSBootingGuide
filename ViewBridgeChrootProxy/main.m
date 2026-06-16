// ViewBridgeChrootProxy.xpc — a tiny XPC service that chroots into /var/mnt/rootfs
// then exec's the real macOS ViewBridgeAuxiliary binary inside chroot.
//
// Why: macOS AppKit (running in chroot) calls xpc_connection_create("com.apple.ViewBridgeAuxiliary").
// xpc subsystem spawns the bundle's binary via the SYSTEM launchd, which is NOT in chroot, so
// it can't find /System/Library/PrivateFrameworks/ViewBridge.framework/... (macOS-only path).
//
// We register THIS proxy as the bundle for "com.apple.ViewBridgeAuxiliary" via xpc_add_bundle from
// libmachook. launchd posix_spawn's this proxy (visible to launchd at /var/jb/...). Proxy chroots
// + exec's into the real macOS ViewBridgeAuxiliary. mach ports (incl. XPC bootstrap) survive exec,
// so the chroot binary picks up the same connection and serves the XPC request normally.
//
// Approach mirrors launchdchrootexec but with hardcoded target path.
@import Darwin;
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>

#define CS_LAUNCH_TYPE_SYSTEM_SERVICE 1
int posix_spawnattr_set_launch_type_np(posix_spawnattr_t *attr, int launch_type);

#define ROOTFS "/var/mnt/rootfs"
#define TARGET "/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary"

int main(int argc, char *argv[], char *envp[]) {
    fprintf(stderr, "[ViewBridgeChrootProxy] starting, argc=%d argv[0]=%s\n", argc, argv[0]);

    if (chroot(ROOTFS) < 0) { perror("chroot"); return 1; }
    if (chdir("/") < 0) { perror("chdir"); }

    setenv("DYLD_INSERT_LIBRARIES",
           "/usr/local/lib/libmachook.dylib:/usr/local/lib/libmachook_arm64.dylib", 1);
    setenv("HOME", "/Users/root", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("MallocNanoZone", "0", 1);

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) { perror("posix_spawnattr_init"); return 1; }
    if (getppid() == 1) {
        posix_spawnattr_set_launch_type_np(&attr, CS_LAUNCH_TYPE_SYSTEM_SERVICE);
    }
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);

    // Re-use original argv (incl. XPC env via envp).
    extern char **environ;
    pid_t pid = 0;
    posix_spawn(&pid, TARGET, NULL, &attr, argv, environ);
    perror("posix_spawn");
    return 1;
}
