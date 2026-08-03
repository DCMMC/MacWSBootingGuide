@import Darwin;
#include "macws_macho_arch.h"

#define CS_LAUNCH_TYPE_SYSTEM_SERVICE 1
int posix_spawnattr_set_launch_type_np(posix_spawnattr_t *attr, int launch_type);

int main(int argc, char *argv[], char *envp[]) {
    if(argc < 5) {
        fprintf(stderr, "Usage: %s uid gid /path/to/root /path/to/exec args\n", argv[0]);
        return 1;
    }
    int uid = atoi(argv[1]);
    int gid = atoi(argv[2]);
    const char *rootPath = argv[3];
    const char *execPath = argv[4];
    char **execArgs = &argv[4];

    // The kernel's file-ID-to-path APIs are not chroot-aware. Preserve the
    // canonical host path before entering the chroot so libmachook can map
    // fsgetpath(2) results back into the process-visible namespace. This is
    // data, not a feature flag: descendants inherit the same root invariant.
    char canonicalRootPath[PATH_MAX];
    if (realpath(rootPath, canonicalRootPath)) {
        setenv("MACWS_CHROOT_HOST_ROOT", canonicalRootPath, 1);
    } else {
        setenv("MACWS_CHROOT_HOST_ROOT", rootPath, 1);
    }
     
    char currentPath[PATH_MAX];
    if(getcwd(currentPath, sizeof(currentPath)) == NULL) {
        perror("getcwd");
        return 1;
    }

    // fprintf(stderr, "before chroot %s\n", rootPath);
    if(chroot(rootPath) < 0) {
        perror("chroot");
        return 1;
    }
    
    if(chdir(currentPath) < 0) {
        perror("chdir");
        chdir("/");
    }
    // fprintf(stderr, "after chdir %s\n", currentPath);
    
    if(setgid(gid) < 0) {
        perror("setgid");
        return 1;
    }
    
    if(setuid(uid) < 0) {
        perror("setuid");
        return 1;
    }
    
    // The iOS 16 dyld accepts BOTH thin ARM64/ALL and ARM64/E dylibs in an
    // ARM64/ALL process.  Inserting both therefore runs every constructor and
    // installs every hook twice.  Pick exactly one dylib from the executable's
    // Mach-O subtype; exec_hooks.c repeats this normalization for descendants.
    macws_macho_arch_t target_arch = macws_macho_arch_for_path(execPath);
    const char *insert = macws_insert_dylib_for_arch(target_arch);
    if (!insert) {
        // launchdchrootexec itself is arm64, so arm64 is the least-surprising
        // fallback for a malformed/non-Mach-O target.  Keep this visible.
        target_arch = MACWS_ARCH_ARM64;
        insert = macws_insert_dylib_for_arch(target_arch);
        fprintf(stderr, "[launchdchrootexec] unknown target Mach-O subtype: %s; fallback arm64\n",
                execPath);
    }
    setenv("DYLD_INSERT_LIBRARIES", insert, 1);
    fprintf(stderr, "[launchdchrootexec] target=%s arch=%s insert=%s\n",
            execPath, macws_arch_name(target_arch), insert);
    setenv("HOME", "/Users/root", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("MallocNanoZone", "0", 1);
    // setenv("DYLD_PRINT_SEARCHING", "1", 1);
    // setenv("DYLD_PRINT_LIBRARIES", "1", 1);
    // setenv("DYLD_PRINT_LIBRARIES_POST_LAUNCH", "1", 1);
    // setenv("DYLD_PRINT_WARNINGS", "1", 1);
    // setenv("DYLD_PRINT_INITIALIZERS", "1", 1);

    posix_spawnattr_t attr;
    if(posix_spawnattr_init(&attr) != 0) {
        perror("posix_spawnattr_init");
        return 1;
    }
    
    if(getppid() == 1) {
        fprintf(stderr, "getppid = 1\n");
        if(posix_spawnattr_set_launch_type_np(&attr, CS_LAUNCH_TYPE_SYSTEM_SERVICE) != 0) {
            perror("posix_spawnattr_set_launch_type_np");
            return 1;
        }
    }
    // if(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_START_SUSPENDED) != 0) {
    // env-gated suspend: set MACWS_SUSPEND_AT_EXEC=1 (in WS plist
    // EnvironmentVariables) to start the spawn'd macOS process in STOPPED
    // state. Lets us race-attach lldb before a single instruction runs.
    // Resume with `process continue` in lldb or `kill -CONT <pid>`.
    short spawn_flags = POSIX_SPAWN_SETEXEC;
    const char *suspendTarget = getenv("MACWS_SUSPEND_TARGET");
    const char *targetBasename = strrchr(execPath, '/');
    targetBasename = targetBasename ? targetBasename + 1 : execPath;
    int suspendRequested = getenv("MACWS_SUSPEND_AT_EXEC") != NULL;
    int suspendTargetMatches = !suspendTarget || !*suspendTarget ||
        !strcmp(suspendTarget, targetBasename) ||
        !strcmp(suspendTarget, execPath);
    if (suspendRequested && suspendTargetMatches) {
        spawn_flags |= POSIX_SPAWN_START_SUSPENDED;
        fprintf(stderr,
                "[launchdchrootexec] MACWS_SUSPEND_AT_EXEC target=%s — %s will start STOPPED\n",
                suspendTarget ?: "*", execPath);
    }
    if(posix_spawnattr_setflags(&attr, spawn_flags) != 0) {
        perror("posix_spawnattr_set_flags");
        return 1;
    }
    
    pid_t child_pid = 0;
    extern char **environ;
    // fprintf(stderr, "before posix_spawn %s\n", execPath);
    posix_spawn(&child_pid, execPath, NULL, &attr, execArgs, environ);
    // fprintf(stderr, "pid= %d\n", child_pid);
    perror("posix_spawn");
    return 1;
}
