@import Darwin;
#include <assert.h> 
#include <sys/socket.h>
#include <sys/un.h>
#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int isJITEnabled() {
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}

// Ask the already-running iOS/root helper to mark this exact Unix-socket peer
// debugged.  This deliberately performs no fork in the injected process:
// libmachook constructors execute under dyld's image-initialization path, and
// a constructor-time fork previously left Steam CEF's later dlopen waiting on
// dyld's recursive API lock forever.  autosignd validates the request against
// LOCAL_PEERPID instead of trusting a client-supplied PID.
static int requestJITFromAutosignd(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,
                     &timeout, sizeof(timeout));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/tmp/autosignd.sock",
            sizeof(address.sun_path));
    int connected = connect(fd, (struct sockaddr *)&address,
                            sizeof(address)) == 0;
    char reply[8] = {0};
    int ok = connected && write(fd, "DEBUG\n", 6) == 6 &&
        read(fd, reply, sizeof(reply) - 1) > 0 &&
        strncmp(reply, "OK\n", 3) == 0;
    close(fd);
    return ok;
}

void EnableJIT() {
    if (!isJITEnabled()) {
        int requested = requestJITFromAutosignd();
        for (unsigned int attempt = 0;
             requested && attempt < 250 && !isJITEnabled(); attempt++) {
            usleep(1000);
        }
    }
    assert(isJITEnabled());
}
