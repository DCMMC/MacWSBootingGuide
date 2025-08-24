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

    fprintf(stderr, "before chroot %s\n", rootPath);
    if(chroot(rootPath) < 0) {
        perror("chroot");
        return 1;
    }
    
    if(chdir(currentPath) < 0) {
        perror("chdir");
        chdir("/");
    }
    fprintf(stderr, "after chdir %s\n", currentPath);
    
    if(setgid(gid) < 0) {
        perror("setgid");
        return 1;
    }
    
    if(setuid(uid) < 0) {
        perror("setuid");
        return 1;
    }
    
    setenv("DYLD_INSERT_LIBRARIES", "/usr/local/lib/libmachook.dylib", 1);
    setenv("HOME", "/Users/root", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("MallocNanoZone", "0", 1);
    setenv("DYLD_PRINT_SEARCHING", "1", 1);
    setenv("DYLD_PRINT_LIBRARIES", "1", 1);
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
    if(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_START_SUSPENDED) != 0) {
    // if(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC) != 0) {
        perror("posix_spawnattr_set_flags");
        return 1;
    }
    
    pid_t child_pid = 0;
    extern char **environ;
    fprintf(stderr, "before posix_spawn %s\n", execPath);
    posix_spawn(&child_pid, execPath, NULL, &attr, execArgs, environ);
    fprintf(stderr, "pid= %d\n", child_pid);
    perror("posix_spawn");
    return 1;
}
