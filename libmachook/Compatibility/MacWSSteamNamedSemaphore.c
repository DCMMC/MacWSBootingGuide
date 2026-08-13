#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "interpose.h"
#include "macws_control_protocol.h"
#include "macws_steam_semaphore_protocol.h"

// Steam build 1785799196 implements CSharedMemStream events with several
// named POSIX semaphores per stream. iPadOS 16 returns ENOSPC once its much
// smaller global named-semaphore table is exhausted. Runtime witness:
//
//   Failed to create BinarySemaphore: ... - /BSem/83ace80d
//   errno: 28, bCreator: false
//
// macwshostd owns the POSIX name/generation lifetime, while each process maps
// that generation to one flock-protected state vnode. Blocking waits register
// EVFILT_VNODE before releasing the state lock, then re-check the predicate
// after wakeup. This avoids both polling and the lost-wakeup window. A small
// record preserves sem_getvalue and validates hash collisions. Broker
// generation IDs preserve sem_unlink lifetime until the final already-open
// handle closes.
//
// This replaces two diagnostics which were not production-safe:
//  * counter + FIFO: /BSem/7c42de60 was posted while Helper remained in read.
//  * process-shared pthread condition: /BSem/25a9c935 was incremented and
//    signaled while the real multithreaded CEF waiter remained in psynch_cvwait.
// Both failures were runtime-confirmed from the exact producer/consumer logs.

#define MACWS_STEAM_SEM_HANDLE_MAGIC 0x4d575348u /* MWSH */

typedef struct MacWSSteamSemaphoreHandle {
    uint32_t magic;
    int descriptor;
    uint64_t brokerGeneration;
    unsigned referenceCount;
    bool unlinked;
    char name[112];
    struct MacWSSteamSemaphoreHandle *next;
} MacWSSteamSemaphoreHandle;

static pthread_mutex_t gMacWSSteamSemaphoreHandlesLock =
    PTHREAD_MUTEX_INITIALIZER;
static MacWSSteamSemaphoreHandle *gMacWSSteamSemaphoreHandles;
static uint32_t gMacWSSteamSemaphoreDiagnosticCount;
static pthread_once_t gMacWSSteamBrokerResetOnce = PTHREAD_ONCE_INIT;
static int gMacWSSteamBrokerResetError;

extern xpc_connection_t MacWSXPCConnectionCreateMachServiceRaw(
    const char *, dispatch_queue_t, uint64_t)
    __asm("_xpc_connection_create_mach_service");

static bool MacWSIsSteamNamedSemaphore(const char *name) {
    if (!name) return false;
    const char *program = getprogname();
    bool steamProcess = program &&
        (!strcmp(program, "steam_osx") ||
         !strcmp(program, "Steam Helper"));
    if (!steamProcess) {
        char executable[PATH_MAX] = {0};
        extern int proc_pidpath(int, void *, uint32_t);
        steamProcess = proc_pidpath(
            getpid(), executable, sizeof(executable)) > 0 &&
            (strstr(executable, "/Applications/Steam.app/") != NULL ||
             strstr(executable,
                    "/Library/Application Support/Steam/") != NULL);
    }
    if (!steamProcess) return false;
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

static void MacWSSteamSemaphorePath(const char *name, uint64_t generation,
                                    char *path, size_t pathSize) {
    snprintf(path, pathSize, "/tmp/.macws-steam-sem-%016llx-%016llx",
             (unsigned long long)MacWSSteamSemaphoreHash(name),
             (unsigned long long)generation);
}

static void MacWSSteamSemaphoreDiagnose(const char *operation,
                                        const char *name, int result,
                                        unsigned value,
                                        const MacWSSteamSemaphoreHandle *handle) {
    if (!getenv("MACWS_STEAM_SEM_DIAGNOSTICS") ||
        __sync_fetch_and_add(&gMacWSSteamSemaphoreDiagnosticCount, 1) >=
            400) return;
    dprintf(STDERR_FILENO,
            "[MacWSSteamSem] pid=%d program=%s op=%s name=%s "
            "result=%d errno=%d value=%u handle=%p "
            "generation=%llu\n",
            getpid(), getprogname() ?: "?", operation, name ?: "?",
            result, result == 0 ? 0 : errno, value, handle,
            handle ? (unsigned long long)handle->brokerGeneration : 0);
}

static xpc_object_t MacWSSteamSemaphoreBrokerRequest(
        const char *operation, const char *name, int flags, unsigned value,
        uint64_t generation) {
    xpc_connection_t connection = MacWSXPCConnectionCreateMachServiceRaw(
        MACWS_CONTROL_SERVICE,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (!connection) {
        errno = ENOTCONN;
        return NULL;
    }
    xpc_connection_set_event_handler(connection,
        ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP, operation);
    if (name)
        xpc_dictionary_set_string(request, MACWS_STEAM_SEM_KEY_NAME, name);
    xpc_dictionary_set_int64(request, MACWS_STEAM_SEM_KEY_FLAGS, flags);
    xpc_dictionary_set_uint64(request, MACWS_STEAM_SEM_KEY_VALUE, value);
    xpc_dictionary_set_uint64(request, MACWS_STEAM_SEM_KEY_GENERATION,
                              generation);
    const char *epoch = getenv("MACWS_STEAM_LAUNCH_EPOCH");
    if (epoch && epoch[0])
        xpc_dictionary_set_string(request, MACWS_STEAM_SEM_KEY_EPOCH, epoch);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    xpc_release(request);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        if (reply) xpc_release(reply);
        errno = ENOTCONN;
        return NULL;
    }
    int brokerError = (int)xpc_dictionary_get_int64(
        reply, MACWS_STEAM_SEM_KEY_ERROR);
    if (brokerError != 0) {
        xpc_release(reply);
        errno = brokerError;
        return NULL;
    }
    return reply;
}

static void MacWSSteamSemaphoreResetBroker(void) {
    const char *epoch = getenv("MACWS_STEAM_LAUNCH_EPOCH");
    if (!epoch || !epoch[0]) return;
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        MACWS_STEAM_SEM_OP_RESET, NULL, 0, 0, 0);
    if (!reply) {
        gMacWSSteamBrokerResetError = errno ?: ENOTCONN;
        return;
    }
    xpc_release(reply);
}

static int MacWSSteamSemaphoreBrokerOpen(
        const char *name, int flags, unsigned value, uint64_t *generation,
        bool *created) {
    pthread_once(&gMacWSSteamBrokerResetOnce,
                 MacWSSteamSemaphoreResetBroker);
    if (gMacWSSteamBrokerResetError) {
        errno = gMacWSSteamBrokerResetError;
        return -1;
    }
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        MACWS_STEAM_SEM_OP_OPEN, name, flags, value, 0);
    if (!reply) return -1;
    uint64_t copiedGeneration = xpc_dictionary_get_uint64(
        reply, MACWS_STEAM_SEM_KEY_GENERATION);
    bool copiedCreated = xpc_dictionary_get_bool(
        reply, MACWS_STEAM_SEM_KEY_CREATED);
    xpc_release(reply);
    if (copiedGeneration == 0) {
        errno = EIO;
        return -1;
    }
    *generation = copiedGeneration;
    if (created) *created = copiedCreated;
    return 0;
}

static int MacWSSteamSemaphoreBrokerUnlink(const char *name,
                                            uint64_t *generation) {
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        MACWS_STEAM_SEM_OP_UNLINK, name, 0, 0, 0);
    if (!reply) return -1;
    uint64_t copiedGeneration = xpc_dictionary_get_uint64(
        reply, MACWS_STEAM_SEM_KEY_GENERATION);
    xpc_release(reply);
    if (copiedGeneration == 0) {
        errno = EIO;
        return -1;
    }
    *generation = copiedGeneration;
    return 0;
}

static int MacWSSteamSemaphoreBrokerSimple(const char *operation,
                                            const char *name,
                                            uint64_t generation) {
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        operation, name, 0, 0, generation);
    if (!reply) return -1;
    xpc_release(reply);
    return 0;
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
    state->revision++;
    if (pwrite(descriptor, state, sizeof(*state), 0) !=
            (ssize_t)sizeof(*state) ||
        ftruncate(descriptor, sizeof(*state)) != 0) return -1;
    return 0;
}

static MacWSSteamSemaphoreHandle *MacWSSteamSemaphoreFind(
        sem_t *semaphore) {
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

static MacWSSteamSemaphoreHandle *MacWSSteamSemaphoreFindReusableLocked(
        const char *name, uint64_t brokerGeneration) {
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if (candidate->unlinked || strcmp(candidate->name, name) ||
            candidate->brokerGeneration != brokerGeneration) continue;
        struct stat status = {0};
        if (fstat(candidate->descriptor, &status) != 0 ||
            status.st_nlink == 0) {
            candidate->unlinked = true;
            continue;
        }
        return candidate;
    }
    return NULL;
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
    if (strlen(name) >= sizeof(((MacWSSteamSemaphoreState *)0)->name)) {
        errno = ENAMETOOLONG;
        return SEM_FAILED;
    }
    if (value > MACWS_STEAM_SEM_VALUE_MAX) {
        errno = EINVAL;
        return SEM_FAILED;
    }

    uint64_t brokerGeneration = 0;
    bool brokerCreated = false;
    if (MacWSSteamSemaphoreBrokerOpen(
            name, flags, value, &brokerGeneration, &brokerCreated) != 0)
        return SEM_FAILED;

    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreHandle *existing =
        MacWSSteamSemaphoreFindReusableLocked(name, brokerGeneration);
    if (existing) existing->referenceCount++;
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    if (existing) {
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        MacWSSteamSemaphoreDiagnose("reuse", name, 0, 0, existing);
        return (sem_t *)existing;
    }

    char path[128];
    MacWSSteamSemaphorePath(name, brokerGeneration, path, sizeof(path));
    int openFlags = O_RDWR | O_CLOEXEC;
    int descriptor = open(path, openFlags, mode ? mode : 0600);
    if (descriptor < 0) {
        int savedError = errno;
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        errno = savedError;
        return SEM_FAILED;
    }
    if (flock(descriptor, LOCK_EX) != 0) {
        int savedError = errno;
        close(descriptor);
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        errno = savedError;
        return SEM_FAILED;
    }

    MacWSSteamSemaphoreState state = {0};
    int stateResult = MacWSSteamSemaphoreReadState(descriptor, &state);
    if (stateResult == 0 &&
        (strcmp(state.name, name) ||
         state.brokerGeneration != brokerGeneration)) {
        errno = EEXIST;
        stateResult = -1;
    }

    int savedError = errno;
    (void)flock(descriptor, LOCK_UN);
    if (stateResult != 0) {
        if (brokerGeneration != 0) {
            if (brokerCreated)
                (void)MacWSSteamSemaphoreBrokerSimple(
                    MACWS_STEAM_SEM_OP_UNLINK, name, 0);
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        }
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }

    MacWSSteamSemaphoreHandle *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        savedError = errno;
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }
    handle->magic = MACWS_STEAM_SEM_HANDLE_MAGIC;
    handle->descriptor = descriptor;
    handle->brokerGeneration = brokerGeneration;
    handle->referenceCount = 1;
    strlcpy(handle->name, name, sizeof(handle->name));

    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    existing = MacWSSteamSemaphoreFindReusableLocked(
        name, brokerGeneration);
    if (existing) {
        existing->referenceCount++;
    } else {
        handle->next = gMacWSSteamSemaphoreHandles;
        gMacWSSteamSemaphoreHandles = handle;
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    if (existing) {
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        close(descriptor);
        free(handle);
        return (sem_t *)existing;
    }

    MacWSSteamSemaphoreDiagnose(brokerCreated ? "create" : "open", name, 0,
                                state.value, handle);
    return (sem_t *)handle;
}

static int MacWSSteamSemClose(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = NULL;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreHandle **cursor = &gMacWSSteamSemaphoreHandles;
    while (*cursor) {
        if ((sem_t *)*cursor == semaphore &&
            (*cursor)->magic == MACWS_STEAM_SEM_HANDLE_MAGIC) {
            handle = *cursor;
            break;
        }
        cursor = &(*cursor)->next;
    }
    if (!handle) {
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        return sem_close(semaphore);
    }
    if (handle->referenceCount > 1) {
        handle->referenceCount--;
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        return 0;
    }
    if (handle->referenceCount != 1) {
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        errno = EINVAL;
        return -1;
    }
    *cursor = handle->next;
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);

    int brokerResult = MacWSSteamSemaphoreBrokerSimple(
        MACWS_STEAM_SEM_OP_CLOSE, NULL, handle->brokerGeneration);
    int savedError = errno;
    int descriptorResult = close(handle->descriptor);
    handle->magic = 0;
    free(handle);
    if (brokerResult != 0) {
        errno = savedError;
        return -1;
    }
    return descriptorResult;
}

static int MacWSSteamSemUnlink(const char *name) {
    if (!MacWSIsSteamNamedSemaphore(name)) return sem_unlink(name);
    uint64_t brokerGeneration = 0;
    if (MacWSSteamSemaphoreBrokerUnlink(name, &brokerGeneration) != 0)
        return -1;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if (!strcmp(candidate->name, name) &&
            candidate->brokerGeneration == brokerGeneration)
            candidate->unlinked = true;
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreDiagnose("unlink", name, 0, 0, NULL);
    return 0;
}

static int MacWSSteamSemaphoreLockState(MacWSSteamSemaphoreHandle *handle,
                                        MacWSSteamSemaphoreState *state) {
    if (flock(handle->descriptor, LOCK_EX) != 0) return -1;
    if (MacWSSteamSemaphoreReadState(handle->descriptor, state) != 0) {
        int savedError = errno;
        (void)flock(handle->descriptor, LOCK_UN);
        errno = savedError;
        return -1;
    }
    return 0;
}

static int MacWSSteamSemaphoreConsumeKernelToken(
        MacWSSteamSemaphoreHandle *handle, bool nonblocking) {
    MacWSSteamSemaphoreState state = {0};
    for (;;) {
        if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
        if (state.value != 0) {
            state.value--;
            int result = MacWSSteamSemaphoreWriteState(
                handle->descriptor, &state);
            int savedError = errno;
            (void)flock(handle->descriptor, LOCK_UN);
            errno = savedError;
            MacWSSteamSemaphoreDiagnose(
                nonblocking ? "trywait" : "wait", handle->name, result,
                state.value, handle);
            return result;
        }
        if (nonblocking) {
            (void)flock(handle->descriptor, LOCK_UN);
            errno = EAGAIN;
            return -1;
        }

        int queue = kqueue();
        if (queue < 0) {
            int savedError = errno;
            (void)flock(handle->descriptor, LOCK_UN);
            errno = savedError;
            return -1;
        }
        (void)fcntl(queue, F_SETFD, FD_CLOEXEC);
        struct kevent change;
        EV_SET(&change, handle->descriptor, EVFILT_VNODE,
               EV_ADD | EV_CLEAR, NOTE_WRITE | NOTE_DELETE | NOTE_RENAME,
               0, NULL);
        if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) {
            int savedError = errno;
            close(queue);
            (void)flock(handle->descriptor, LOCK_UN);
            errno = savedError;
            return -1;
        }
        MacWSSteamSemaphoreDiagnose("wait-block", handle->name, 0, 0,
                                    handle);
        (void)flock(handle->descriptor, LOCK_UN);
        int waitResult;
        do {
            struct kevent event;
            waitResult = kevent(queue, NULL, 0, &event, 1, NULL);
        } while (waitResult < 0 && errno == EINTR);
        int savedError = errno;
        close(queue);
        if (waitResult < 0) {
            errno = savedError;
            return -1;
        }
        // The writer may update an unrelated field or another waiter may
        // consume the token first. Re-acquire and re-check in all cases.
    }
}

static int MacWSSteamSemTryWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_trywait(semaphore);
    return MacWSSteamSemaphoreConsumeKernelToken(handle, true);
}

static int MacWSSteamSemWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_wait(semaphore);
    return MacWSSteamSemaphoreConsumeKernelToken(handle, false);
}

static int MacWSSteamSemPost(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_post(semaphore);
    MacWSSteamSemaphoreState state = {0};
    if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
    int result = 0;
    if (state.value == MACWS_STEAM_SEM_VALUE_MAX) {
        errno = EOVERFLOW;
        result = -1;
    } else {
        state.value++;
        result = MacWSSteamSemaphoreWriteState(handle->descriptor, &state);
    }
    int savedError = errno;
    (void)flock(handle->descriptor, LOCK_UN);
    errno = savedError;
    MacWSSteamSemaphoreDiagnose("post", handle->name, result, state.value,
                                handle);
    return result;
}

static int MacWSSteamSemGetValue(sem_t *semaphore, int *value) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_getvalue(semaphore, value);
    if (!value) {
        errno = EINVAL;
        return -1;
    }
    MacWSSteamSemaphoreState state = {0};
    if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
    *value = (int)state.value;
    (void)flock(handle->descriptor, LOCK_UN);
    return 0;
}

DYLD_INTERPOSE(MacWSSteamSemOpen, sem_open)
DYLD_INTERPOSE(MacWSSteamSemClose, sem_close)
DYLD_INTERPOSE(MacWSSteamSemUnlink, sem_unlink)
DYLD_INTERPOSE(MacWSSteamSemWait, sem_wait)
DYLD_INTERPOSE(MacWSSteamSemTryWait, sem_trywait)
DYLD_INTERPOSE(MacWSSteamSemPost, sem_post)
DYLD_INTERPOSE(MacWSSteamSemGetValue, sem_getvalue)
