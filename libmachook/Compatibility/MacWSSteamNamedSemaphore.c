#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "interpose.h"

// Steam build 1785799196 implements CSharedMemStream events with several
// named POSIX semaphores per stream.  iPadOS 16 returns ENOSPC once its much
// smaller global named-semaphore table is exhausted.  Runtime witness:
//
//   Failed to create BinarySemaphore: ... - /BSem/83ace80d
//   errno: 28, bCreator: false
//
// Keep the POSIX semaphore contract for Valve's private namespaces with a
// file-backed counter. flock provides the atomic decrement/increment and a
// vnode kqueue provides sleeping cross-process wakeups.  This is not a
// success stub: O_EXCL, unlink lifetime, blocking wait, trywait, timed wait,
// overflow and the shared counter all retain their original semantics.

#define MACWS_STEAM_SEM_MAGIC 0x4d575345u /* MWSE */
#define MACWS_STEAM_SEM_VERSION 1u
#define MACWS_STEAM_SEM_HANDLE_MAGIC 0x4d575348u /* MWSH */
#define MACWS_STEAM_SEM_VALUE_MAX 0x7fffffffU

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t value;
    uint32_t generation;
    char name[112];
} MacWSSteamSemaphoreState;

typedef struct MacWSSteamSemaphoreHandle {
    uint32_t magic;
    int descriptor;
    int queue;
    char name[112];
    struct MacWSSteamSemaphoreHandle *next;
} MacWSSteamSemaphoreHandle;

static pthread_mutex_t gMacWSSteamSemaphoreHandlesLock =
    PTHREAD_MUTEX_INITIALIZER;
static MacWSSteamSemaphoreHandle *gMacWSSteamSemaphoreHandles;
static uint32_t gMacWSSteamSemaphoreDiagnosticCount;

static void MacWSSteamSemaphoreDiagnose(const char *operation,
                                        const char *name, int result,
                                        unsigned value) {
    if (!getenv("MACWS_STEAM_SEM_DIAGNOSTICS") ||
        __sync_fetch_and_add(&gMacWSSteamSemaphoreDiagnosticCount, 1) >=
            2000) return;
    dprintf(STDERR_FILENO,
            "[MacWSSteamSem] pid=%d program=%s op=%s name=%s "
            "result=%d errno=%d value=%u\n",
            getpid(), getprogname() ?: "?", operation,
            name ?: "?", result, result == 0 ? 0 : errno, value);
}

static bool MacWSIsSteamNamedSemaphore(const char *name) {
    if (!name) return false;
    return strncmp(name, "/BSem/", 6) == 0 ||
        strncmp(name, "/Evt/", 5) == 0 ||
        strncmp(name, "/MTX/", 5) == 0;
}

static uint64_t MacWSSteamSemaphoreHash(const char *name) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const unsigned char *cursor = (const unsigned char *)name;
         *cursor; cursor++) {
        hash ^= *cursor;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void MacWSSteamSemaphorePath(const char *name, char *path,
                                    size_t pathSize) {
    snprintf(path, pathSize, "/tmp/.macws-steam-sem-%016llx",
             (unsigned long long)MacWSSteamSemaphoreHash(name));
}

static int MacWSSteamSemaphoreReadState(
        int descriptor, MacWSSteamSemaphoreState *state) {
    ssize_t amount = pread(descriptor, state, sizeof(*state), 0);
    if (amount != (ssize_t)sizeof(*state) ||
        state->magic != MACWS_STEAM_SEM_MAGIC ||
        state->version != MACWS_STEAM_SEM_VERSION) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

static int MacWSSteamSemaphoreWriteState(
        int descriptor, MacWSSteamSemaphoreState *state) {
    state->generation++;
    if (pwrite(descriptor, state, sizeof(*state), 0) !=
            (ssize_t)sizeof(*state) ||
        ftruncate(descriptor, sizeof(*state)) != 0) return -1;
    return 0;
}

static MacWSSteamSemaphoreHandle *MacWSSteamSemaphoreFind(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *result = NULL;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if ((sem_t *)candidate == semaphore &&
            candidate->magic == MACWS_STEAM_SEM_HANDLE_MAGIC) {
            result = candidate;
            break;
        }
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    return result;
}

static void MacWSSteamSemaphoreRegister(MacWSSteamSemaphoreHandle *handle) {
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    handle->next = gMacWSSteamSemaphoreHandles;
    gMacWSSteamSemaphoreHandles = handle;
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
}

static bool MacWSSteamSemaphoreUnregister(
        MacWSSteamSemaphoreHandle *handle) {
    bool found = false;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreHandle **cursor = &gMacWSSteamSemaphoreHandles;
    while (*cursor) {
        if (*cursor == handle) {
            *cursor = handle->next;
            found = true;
            break;
        }
        cursor = &(*cursor)->next;
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    return found;
}

static sem_t *MacWSSteamSemOpen(const char *name, int flags, ...) {
    mode_t mode = 0;
    unsigned value = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        value = va_arg(arguments, unsigned);
        va_end(arguments);
    }
    if (!MacWSIsSteamNamedSemaphore(name)) {
        return (flags & O_CREAT) ? sem_open(name, flags, mode, value) :
            sem_open(name, flags);
    }
    if (value > MACWS_STEAM_SEM_VALUE_MAX) {
        errno = EINVAL;
        return SEM_FAILED;
    }

    char path[96];
    MacWSSteamSemaphorePath(name, path, sizeof(path));
    int openFlags = O_RDWR | O_CLOEXEC;
    if (flags & O_CREAT) openFlags |= O_CREAT;
    if (flags & O_EXCL) openFlags |= O_EXCL;
    int descriptor = open(path, openFlags, mode);
    if (descriptor < 0) return SEM_FAILED;
    if (flock(descriptor, LOCK_EX) != 0) {
        int savedError = errno;
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }

    struct stat status = {0};
    bool created = fstat(descriptor, &status) == 0 && status.st_size == 0;
    MacWSSteamSemaphoreState state = {0};
    int stateResult = 0;
    if (created) {
        state.magic = MACWS_STEAM_SEM_MAGIC;
        state.version = MACWS_STEAM_SEM_VERSION;
        state.value = value;
        strlcpy(state.name, name, sizeof(state.name));
        stateResult = MacWSSteamSemaphoreWriteState(descriptor, &state);
    } else {
        stateResult = MacWSSteamSemaphoreReadState(descriptor, &state);
        if (stateResult == 0 && strcmp(state.name, name) != 0) {
            errno = EEXIST;
            stateResult = -1;
        }
    }
    int savedError = errno;
    (void)flock(descriptor, LOCK_UN);
    if (stateResult != 0) {
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }

    int queue = kqueue();
    if (queue < 0) {
        savedError = errno;
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }
    (void)fcntl(queue, F_SETFD, FD_CLOEXEC);
    struct kevent change;
    EV_SET(&change, descriptor, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_DELETE | NOTE_RENAME, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) {
        savedError = errno;
        close(queue);
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }

    MacWSSteamSemaphoreHandle *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        savedError = errno;
        close(queue);
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }
    handle->magic = MACWS_STEAM_SEM_HANDLE_MAGIC;
    handle->descriptor = descriptor;
    handle->queue = queue;
    strlcpy(handle->name, name, sizeof(handle->name));
    MacWSSteamSemaphoreRegister(handle);
    MacWSSteamSemaphoreDiagnose(created ? "create" : "open", name, 0,
                                state.value);
    return (sem_t *)handle;
}

static int MacWSSteamSemClose(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_close(semaphore);
    if (!MacWSSteamSemaphoreUnregister(handle)) {
        errno = EINVAL;
        return -1;
    }
    handle->magic = 0;
    int queueResult = close(handle->queue);
    int savedError = errno;
    int descriptorResult = close(handle->descriptor);
    if (queueResult == 0 && descriptorResult != 0) savedError = errno;
    free(handle);
    errno = savedError;
    return queueResult != 0 || descriptorResult != 0 ? -1 : 0;
}

static int MacWSSteamSemUnlink(const char *name) {
    if (!MacWSIsSteamNamedSemaphore(name)) return sem_unlink(name);
    char path[96];
    MacWSSteamSemaphorePath(name, path, sizeof(path));
    int result = unlink(path);
    MacWSSteamSemaphoreDiagnose("unlink", name, result, 0);
    return result;
}

static int MacWSSteamSemaphoreTryDecrement(
        MacWSSteamSemaphoreHandle *handle) {
    if (flock(handle->descriptor, LOCK_EX) != 0) return -1;
    MacWSSteamSemaphoreState state = {0};
    int result = MacWSSteamSemaphoreReadState(handle->descriptor, &state);
    if (result == 0) {
        if (state.value == 0) {
            errno = EAGAIN;
            result = -1;
        } else {
            state.value--;
            result = MacWSSteamSemaphoreWriteState(handle->descriptor,
                                                   &state);
        }
    }
    int savedError = errno;
    (void)flock(handle->descriptor, LOCK_UN);
    errno = savedError;
    return result;
}

static int MacWSSteamSemTryWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_trywait(semaphore);
    return MacWSSteamSemaphoreTryDecrement(handle);
}

static int MacWSSteamSemaphoreWaitInternal(
        MacWSSteamSemaphoreHandle *handle, const struct timespec *deadline) {
    bool reportedBlock = false;
    for (;;) {
        if (MacWSSteamSemaphoreTryDecrement(handle) == 0) {
            MacWSSteamSemaphoreDiagnose(
                reportedBlock ? "wait-woken" : "wait-ready",
                handle->name, 0, 0);
            return 0;
        }
        if (errno != EAGAIN) return -1;
        if (!reportedBlock) {
            MacWSSteamSemaphoreDiagnose("wait-block", handle->name, 0, 0);
            reportedBlock = true;
        }

        struct timespec timeout;
        struct timespec *timeoutPointer = NULL;
        if (deadline) {
            struct timespec now;
            if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
            timeout.tv_sec = deadline->tv_sec - now.tv_sec;
            timeout.tv_nsec = deadline->tv_nsec - now.tv_nsec;
            if (timeout.tv_nsec < 0) {
                timeout.tv_nsec += 1000000000L;
                timeout.tv_sec--;
            }
            if (timeout.tv_sec < 0 ||
                (timeout.tv_sec == 0 && timeout.tv_nsec <= 0)) {
                errno = ETIMEDOUT;
                return -1;
            }
            timeoutPointer = &timeout;
        }

        struct kevent event;
        int result = kevent(handle->queue, NULL, 0, &event, 1,
                            timeoutPointer);
        if (result > 0) continue;
        if (result == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (errno != EINTR) return -1;
    }
}

static int MacWSSteamSemWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_wait(semaphore);
    return MacWSSteamSemaphoreWaitInternal(handle, NULL);
}

static int MacWSSteamSemPost(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_post(semaphore);
    if (flock(handle->descriptor, LOCK_EX) != 0) return -1;
    MacWSSteamSemaphoreState state = {0};
    int result = MacWSSteamSemaphoreReadState(handle->descriptor, &state);
    if (result == 0) {
        if (state.value == MACWS_STEAM_SEM_VALUE_MAX) {
            errno = EOVERFLOW;
            result = -1;
        } else {
            state.value++;
            result = MacWSSteamSemaphoreWriteState(handle->descriptor,
                                                   &state);
        }
    }
    int savedError = errno;
    (void)flock(handle->descriptor, LOCK_UN);
    errno = savedError;
    MacWSSteamSemaphoreDiagnose("post", handle->name, result,
                                result == 0 ? state.value : 0);
    return result;
}

static int MacWSSteamSemGetValue(sem_t *semaphore, int *value) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_getvalue(semaphore, value);
    if (!value) {
        errno = EINVAL;
        return -1;
    }
    if (flock(handle->descriptor, LOCK_SH) != 0) return -1;
    MacWSSteamSemaphoreState state = {0};
    int result = MacWSSteamSemaphoreReadState(handle->descriptor, &state);
    if (result == 0) *value = (int)state.value;
    int savedError = errno;
    (void)flock(handle->descriptor, LOCK_UN);
    errno = savedError;
    return result;
}

DYLD_INTERPOSE(MacWSSteamSemOpen, sem_open)
DYLD_INTERPOSE(MacWSSteamSemClose, sem_close)
DYLD_INTERPOSE(MacWSSteamSemUnlink, sem_unlink)
DYLD_INTERPOSE(MacWSSteamSemWait, sem_wait)
DYLD_INTERPOSE(MacWSSteamSemTryWait, sem_trywait)
DYLD_INTERPOSE(MacWSSteamSemPost, sem_post)
DYLD_INTERPOSE(MacWSSteamSemGetValue, sem_getvalue)
