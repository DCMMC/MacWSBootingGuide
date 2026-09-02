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
// Protocol:
//   "<chroot-path>\n"  sign/trustcache that chroot-absolute path
//   "DEBUG\n"         mark the connecting process CS_DEBUGGED
//   "PING\n"          verify that the published socket has a live server
//
// The second operation replaces libmachook's historical constructor-time
// fork()+ptrace JIT bootstrap.  Forking while dyld is still running image
// initializers leaves dyld's atfork lock lifecycle exposed to the macOS/iOS
// libSystem boundary; Steam CEF runtime-confirmed the resulting permanent
// wait in dlopen_from().  The daemon obtains the peer PID from the Unix socket,
// so a client cannot nominate an unrelated process.

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
#include <sys/file.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>

extern char **environ;

// Socket path as seen from the iOS side (== chroot /tmp/autosignd.sock).
#define SOCK_PATH   "/var/mnt/rootfs/tmp/autosignd.sock"
#define LOCK_PATH   "/var/mnt/rootfs/tmp/autosignd.lock"
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

// A current CDHash in Dopamine's dynamic trustcache is a byte-level witness
// that this exact Mach-O has already completed the project's signing policy.
// Preserve it verbatim. Re-running ldid is not semantically idempotent for all
// vendor signatures: Steam 1785799196 runtime-confirmed that a second pass
// grew three child executables by 64 bytes after sign_installed.sh had already
// synchronized package/*.installed, causing the updater to restore them and
// enter a verify/update loop.
static int current_hashes_are_trusted(const char *path) {
    char hashes[3][128] = {{0}};
    size_t hash_count = 0;
    for (const char **arch = kArches; *arch; arch++) {
        if (cdhash_for_arch(path, *arch, hashes[hash_count],
                            sizeof(hashes[hash_count]))) {
            hash_count++;
        }
    }
    if (hash_count == 0) return 0;

    // 3,500 entries occupy well below this bound on the target. If the
    // inventory ever grows past it, capture() drains the command and the
    // conservative result is a re-sign, never a false trusted decision.
    size_t inventory_size = 1024 * 1024;
    char *inventory = calloc(1, inventory_size);
    if (!inventory) return 0;
    char *const argv[] = {
        (char *)JBCTL, "trustcache", "info", NULL
    };
    int status = capture(argv, inventory, inventory_size);
    if (status != 0) {
        free(inventory);
        return 0;
    }
    for (char *cursor = inventory; *cursor; cursor++) {
        if (*cursor >= 'A' && *cursor <= 'Z')
            *cursor = (char)(*cursor - 'A' + 'a');
    }
    int trusted = 1;
    for (size_t index = 0; index < hash_count; index++) {
        for (char *cursor = hashes[index]; *cursor; cursor++) {
            if (*cursor >= 'A' && *cursor <= 'Z')
                *cursor = (char)(*cursor - 'A' + 'a');
        }
        if (!strstr(inventory, hashes[index])) {
            trusted = 0;
            break;
        }
    }
    free(inventory);
    return trusted;
}

// Ad-hoc re-sign + trustcache every Mach-O slice of one rootfs path.
static void process_path(const char *realpath) {
    if (seen(realpath)) return;

    struct stat st;
    if (stat(realpath, &st) != 0 || !S_ISREG(st.st_mode)) { mark_seen(realpath); return; }

    if (current_hashes_are_trusted(realpath)) {
        logmsg("preserved already-trusted signature: %s", realpath);
        mark_seen(realpath);
        return;
    }

    // An untrusted Apple/vendor signature still needs conversion: iOS AMFI can
    // reject it despite a newly added stock CDHash because its platform and
    // library-validation policy is not the MacWS chroot policy. Re-sign once,
    // then register the resulting hashes. Subsequent requests take the exact
    // trusted-byte fast path above.
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

static int mark_peer_debugged(pid_t peer_pid) {
    if (peer_pid <= 1) return 0;
    char pid_string[32];
    int length = snprintf(pid_string, sizeof(pid_string), "%d", peer_pid);
    if (length <= 0 || (size_t)length >= sizeof(pid_string)) return 0;
    char output[512] = {0};
    char *const argv[] = {
        (char *)JBCTL, "proc_set_debugged", pid_string, NULL
    };
    int status = capture(argv, output, sizeof(output));
    if (status != 0) {
        logmsg("proc_set_debugged pid=%d failed status=%d output=%s",
               peer_pid, status, output[0] ? output : "(empty)");
        return 0;
    }
    return 1;
}

static int probe_server(void) {
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) return 1;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, SOCK_PATH, sizeof(address.sun_path) - 1);
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socket_fd);
        return 1;
    }
    static const char request[] = "PING\n";
    if (write(socket_fd, request, sizeof(request) - 1) !=
        (ssize_t)(sizeof(request) - 1)) {
        close(socket_fd);
        return 1;
    }
    char reply[4] = {0};
    size_t offset = 0;
    while (offset < 3) {
        ssize_t count = read(socket_fd, reply + offset, 3 - offset);
        if (count > 0) {
            offset += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        close(socket_fd);
        return 1;
    }
    close(socket_fd);
    return memcmp(reply, "OK\n", 3) == 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_DFL);

    if (argc == 2 && strcmp(argv[1], "--probe") == 0)
        return probe_server();

    // The lifecycle helper is the normal owner, but package configuration and
    // GUI recovery can overlap. Runtime on 2026-08-30 found one live autosignd
    // whose pathname had disappeared; every ViewBridge child then failed its
    // JIT handshake with connect_errno=61. Source inspection confirms that a
    // second daemon unconditionally unlinked SOCK_PATH before binding. Hold a
    // process-lifetime lock before touching that name so no concurrent direct
    // launch can detach the active listener from the filesystem namespace.
    int lock_fd = open(LOCK_PATH, O_CREAT | O_RDWR, 0600);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        logmsg("singleton lock %s: %s", LOCK_PATH, strerror(errno));
        if (lock_fd >= 0) close(lock_fd);
        return 2;
    }
    (void)ftruncate(lock_fd, 0);
    dprintf(lock_fd, "%d\n", getpid());

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

        int ok = 1;
        if (strcmp(buf, "DEBUG") == 0) {
            pid_t peer_pid = -1;
            socklen_t peer_length = sizeof(peer_pid);
            if (getsockopt(c, SOL_LOCAL, LOCAL_PEERPID,
                           &peer_pid, &peer_length) != 0 ||
                peer_length != sizeof(peer_pid)) {
                logmsg("LOCAL_PEERPID failed: %s", strerror(errno));
                ok = 0;
            } else {
                ok = mark_peer_debugged(peer_pid);
            }
        } else if (strcmp(buf, "PING") == 0) {
            // The reply below is the complete liveness contract.
        } else if (buf[0]) {
            handle_request(buf);
        }

        write(c, ok ? "OK\n" : "ERR\n", ok ? 3 : 4);
        close(c);
    }
    close(s);
    unlink(SOCK_PATH);
    close(lock_fd);
    return 0;
}
