// exec_hooks.c — auto-sign-on-exec (client side, runs inside the chroot).
//
// AMFI kills any exec of a Mach-O whose CDHash is not in the jailbreak
// trustcache (EBADEXEC / "Operation not permitted"). The privileged trustcache
// add can only happen in an iOS-platform process, so before every exec we ask
// the iOS-side `autosignd` daemon (over a unix socket) to sign + trustcache the
// target binary, then proceed with the real exec.
//
// Interposes the array/spawn exec forms (posix_spawn[p], execve, execv,
// execvp). The varargs forms (execl*) are not covered — they are rare and call
// the array forms internally within libsystem (not interposable here).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/time.h>
#include "interpose.h"

#define SOCK_PATH "/tmp/autosignd.sock"   // as seen from inside the chroot

// ── in-process cache of paths already sent to the daemon ────────────────────
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char **g_cache = NULL;
static size_t g_cache_n = 0, g_cache_cap = 0;

static int cache_check_and_add(const char *p) {
    int present = 0;
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < g_cache_n; i++) {
        if (strcmp(g_cache[i], p) == 0) { present = 1; break; }
    }
    if (!present) {
        if (g_cache_n == g_cache_cap) {
            g_cache_cap = g_cache_cap ? g_cache_cap * 2 : 64;
            g_cache = realloc(g_cache, g_cache_cap * sizeof(char *));
        }
        g_cache[g_cache_n++] = strdup(p);
    }
    pthread_mutex_unlock(&g_lock);
    return present;
}

// Ask the daemon to sign + trustcache one absolute (chroot) path. Fail-open:
// any error (daemon down, timeout) just returns so the real exec still runs.
static void request_sign(const char *path) {
    if (!path || path[0] != '/') return;
    if (cache_check_and_add(path)) return;   // already requested this boot

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        char line[1100];
        int n = snprintf(line, sizeof(line), "%s\n", path);
        if (n > 0 && (size_t)n < sizeof(line)) {
            if (write(fd, line, (size_t)n) == n) {
                char ack[8];
                (void)read(fd, ack, sizeof(ack));   // wait for "OK\n" before exec
            }
        }
    }
    close(fd);
}

// Resolve a bare command name via $PATH to an absolute path (malloc'd), or NULL.
// Absolute / relative-with-slash names are returned as a copy unchanged.
static char *resolve(const char *file) {
    if (!file || !*file) return NULL;
    if (strchr(file, '/')) return strdup(file);

    const char *path = getenv("PATH");
    if (!path) path = "/usr/bin:/bin:/usr/sbin:/sbin";
    char *dup = strdup(path);
    if (!dup) return NULL;
    char *out = NULL;
    for (char *dir = strtok(dup, ":"); dir; dir = strtok(NULL, ":")) {
        char cand[1024];
        if (snprintf(cand, sizeof(cand), "%s/%s", dir, file) >= (int)sizeof(cand)) continue;
        struct stat st;
        if (stat(cand, &st) == 0 && (st.st_mode & S_IXUSR)) { out = strdup(cand); break; }
    }
    free(dup);
    return out;
}

static void ensure_signed(const char *file) {
    char *abs = resolve(file);
    if (abs) { request_sign(abs); free(abs); }
}

// ── interposed exec family ──────────────────────────────────────────────────
// Under DYLD_INTERPOSE, a call to the original symbol from within this image is
// NOT re-interposed by dyld, so calling e.g. execve() here invokes the real one
// (matching the project's existing os_log_hooks pattern). Do not use dlsym here.

static int my_posix_spawn(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *fa,
                          const posix_spawnattr_t *attr,
                          char *const argv[], char *const envp[]) {
    ensure_signed(path);
    return posix_spawn(pid, path, fa, attr, argv, envp);
}

static int my_posix_spawnp(pid_t *pid, const char *file,
                           const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr,
                           char *const argv[], char *const envp[]) {
    ensure_signed(file);
    return posix_spawnp(pid, file, fa, attr, argv, envp);
}

static int my_execve(const char *path, char *const argv[], char *const envp[]) {
    ensure_signed(path);
    return execve(path, argv, envp);
}

static int my_execv(const char *path, char *const argv[]) {
    ensure_signed(path);
    return execv(path, argv);
}

static int my_execvp(const char *file, char *const argv[]) {
    ensure_signed(file);
    return execvp(file, argv);
}

DYLD_INTERPOSE(my_posix_spawn, posix_spawn);
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp);
DYLD_INTERPOSE(my_execve, execve);
DYLD_INTERPOSE(my_execv, execv);
DYLD_INTERPOSE(my_execvp, execvp);
