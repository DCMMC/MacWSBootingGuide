// autosignd — on-demand sign + trustcache daemon (runs on the iOS side).
//
// libmachook (injected into every macOS chroot process) interposes the
// exec/posix_spawn family and, before each exec, sends the target binary's
// (chroot-absolute) path to this daemon over a unix socket. The daemon
// translates the path into the rootfs, extracts the Mach-O CDHash with `ldid`
// (ad-hoc signing it first if unsigned), and registers the CDHash with the
// jailbreak trustcache via `jbctl` — the privileged operation that can only run
// in an iOS-platform process (the chroot's macOS dyld refuses to load
// libjailbreak.dylib, so the chroot cannot call jbclient_* directly).
//
// Protocol: client connects, sends "<chroot-path>\n", daemon replies "OK\n".

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>

extern char **environ;

// Socket path as seen from the iOS side (== chroot /tmp/autosignd.sock).
#define SOCK_PATH   "/var/mnt/rootfs/tmp/autosignd.sock"
#define ROOTFS      "/var/mnt/rootfs"
#define LDID        "/var/jb/usr/bin/ldid"
#define JBCTL       "/var/jb/usr/bin/jbctl"
#define ENT         "/var/jb/usr/macOS/bin/entitlements.plist"

static const char *kArches[] = { "arm64", "arm64e", "x86_64", NULL };

// ── simple in-memory set of already-processed rootfs paths ──────────────────
static char **g_seen = NULL;
static size_t g_seen_n = 0, g_seen_cap = 0;

static int seen(const char *p) {
    for (size_t i = 0; i < g_seen_n; i++)
        if (strcmp(g_seen[i], p) == 0) return 1;
    return 0;
}
static void mark_seen(const char *p) {
    if (g_seen_n == g_seen_cap) {
        g_seen_cap = g_seen_cap ? g_seen_cap * 2 : 64;
        g_seen = realloc(g_seen, g_seen_cap * sizeof(char *));
    }
    g_seen[g_seen_n++] = strdup(p);
}

static void logmsg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    fprintf(stderr, "[%s] ", ts);
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

// Run argv[], capture up to outsz-1 bytes of stdout. Returns child exit code,
// or -1 on spawn failure.
static int capture(char *const argv[], char *out, size_t outsz) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawn_file_actions_addclose(&fa, pipefd[1]);

    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);
    if (rc != 0) { close(pipefd[0]); return -1; }

    size_t off = 0;
    if (out && outsz) {
        ssize_t n;
        while (off < outsz - 1 && (n = read(pipefd[0], out + off, outsz - 1 - off)) > 0)
            off += (size_t)n;
        out[off] = '\0';
    }
    // drain anything left so the child doesn't block on a full pipe
    char junk[256];
    while (read(pipefd[0], junk, sizeof(junk)) > 0) {}
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// Extract the "CDHash=<hex>" value (if any) for one arch slice into hash[].
static int cdhash_for_arch(const char *path, const char *arch, char *hash, size_t hsz) {
    char buf[8192];
    char *const argv[] = { (char *)LDID, "-arch", (char *)arch, "-h", (char *)path, NULL };
    if (capture(argv, buf, sizeof(buf)) < 0) return 0;
    char *p = strstr(buf, "CDHash=");
    if (!p) return 0;
    p += 7;
    size_t i = 0;
    while (i < hsz - 1 && ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') ||
                           (*p >= 'A' && *p <= 'F'))) {
        hash[i++] = *p++;
    }
    hash[i] = '\0';
    return i > 0;
}

static void trustcache_add(const char *hash) {
    char *const argv[] = { (char *)JBCTL, "trustcache", "add", (char *)hash, NULL };
    capture(argv, NULL, 0);
}

static void adhoc_sign(const char *path) {
    char sflag[] = "-S" ENT;
    char *const argv[] = { (char *)LDID, sflag, "-M", (char *)path, NULL };
    capture(argv, NULL, 0);
}

// Ad-hoc re-sign + trustcache every Mach-O slice of one rootfs path.
static void process_path(const char *realpath) {
    if (seen(realpath)) return;

    struct stat st;
    if (stat(realpath, &st) != 0 || !S_ISREG(st.st_mode)) { mark_seen(realpath); return; }

    // ALWAYS ad-hoc re-sign first: AMFI SIGKILLs Apple-signed binaries even when
    // their CDHash is trustcached (platform-binary / library-validation flags in
    // the original signature). Re-signing ad-hoc with our entitlements strips
    // those flags; the resulting CDHash + trustcache is accepted and runnable.
    // (This mirrors postinst.sh's sign_and_trustcache.) ldid is a no-op on
    // non-Mach-O files, so the cdhash loop below simply finds nothing for those.
    adhoc_sign(realpath);

    char hash[128];
    int added = 0;
    for (const char **a = kArches; *a; a++) {
        if (cdhash_for_arch(realpath, *a, hash, sizeof(hash))) {
            trustcache_add(hash);
            added++;
        }
    }
    if (added) logmsg("signed+trusted (%d slice%s): %s", added, added == 1 ? "" : "s", realpath);
    mark_seen(realpath);
}

// Map a chroot-absolute path to its rootfs location and process it.
static void handle_request(const char *chroot_path) {
    if (chroot_path[0] != '/') return;          // only absolute paths
    char real[1024];
    int n = snprintf(real, sizeof(real), "%s%s", ROOTFS, chroot_path);
    if (n <= 0 || (size_t)n >= sizeof(real)) return;
    process_path(real);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_DFL);

    unlink(SOCK_PATH);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) { logmsg("socket: %s", strerror(errno)); return 1; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        logmsg("bind %s: %s", SOCK_PATH, strerror(errno));
        return 1;
    }
    chmod(SOCK_PATH, 0666);   // allow any chroot uid to connect
    if (listen(s, 64) != 0) { logmsg("listen: %s", strerror(errno)); return 1; }
    logmsg("autosignd listening on %s", SOCK_PATH);

    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }

        char buf[1024];
        size_t off = 0;
        ssize_t r;
        while (off < sizeof(buf) - 1 && (r = read(c, buf + off, sizeof(buf) - 1 - off)) > 0) {
            off += (size_t)r;
            if (memchr(buf, '\n', off)) break;
        }
        buf[off] = '\0';
        char *nl = strchr(buf, '\n');
        if (nl) *nl = '\0';

        if (buf[0]) handle_request(buf);

        write(c, "OK\n", 3);
        close(c);
    }
    close(s);
    return 0;
}
