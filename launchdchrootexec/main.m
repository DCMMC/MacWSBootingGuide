@import Darwin;

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
    
    // Insert BOTH thin libmachook slices (colon-separated).  The device's dyld
    // won't load a fat insert into a chrooted macOS process, so libmachook ships
    // as two thin dylibs; each macOS process loads the slice matching its arch
    // (arm64e or arm64) and dyld silently skips the non-matching one.  Children
    // inherit this via the environment.  See misc/build_on_ios.sh.
    setenv("DYLD_INSERT_LIBRARIES",
           "/usr/local/lib/libmachook.dylib:/usr/local/lib/libmachook_arm64.dylib", 1);
    setenv("HOME", "/Users/root", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("MallocNanoZone", "0", 1);
    // setenv("DYLD_PRINT_SEARCHING", "1", 1);
    // setenv("DYLD_PRINT_LIBRARIES", "1", 1);
    // setenv("DYLD_PRINT_LIBRARIES_POST_LAUNCH", "1", 1);
    // setenv("DYLD_PRINT_WARNINGS", "1", 1);
    // setenv("DYLD_PRINT_INITIALIZERS", "1", 1);

    // EXPERIMENT (PAC keys): POSIX_SPAWN_SETEXEC replaces the current task in-place but the
    // resulting arm64e child has 3 of 4 PAC keys (DA/IA/DB) zeroed (only IB works because
    // pacibsp/retab need it). Use plain execve() instead — the standard exec syscall path
    // re-initializes ALL PAC keys for the new task on arm64e binaries.
    // (Old SETEXEC code commented out for reference.)
    // posix_spawnattr_t attr; ... posix_spawn(... POSIX_SPAWN_SETEXEC ...);
    extern char **environ;
    execve(execPath, execArgs, environ);
    perror("execve");
    return 1;
}
