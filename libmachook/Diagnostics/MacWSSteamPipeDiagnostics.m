@import Darwin;
@import CydiaSubstrate;

#import "interpose.h"

#include <fcntl.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <mach/exception_types.h>

// One-launch evidence collector for Steam's bootstrap FIFO. This deliberately
// preserves every syscall result and errno; it is not a compatibility shim.
// Enable only on the Steam process being investigated with
// MACWS_STEAM_PIPE_DIAGNOSTICS=1.
static bool MacWSSteamPipeDiagnosticsEnabled(void) {
    return getenv("MACWS_STEAM_PIPE_DIAGNOSTICS") != NULL;
}

static bool MacWSIsSteamPipePath(const char *path) {
    return path && strstr(path, "steam.pipe") != NULL;
}

static void MacWSLogSteamPipeCall(const char *api, const char *path,
                                  long argument, int result,
                                  int savedError) {
    if (!MacWSSteamPipeDiagnosticsEnabled() ||
        !MacWSIsSteamPipePath(path)) return;
    fprintf(stderr,
            "[MacWSSteamPipeDiagnostics] api=%s pid=%d program=%s "
            "path=%s argument=%#lx result=%d errno=%d return=%p\n",
            api, getpid(), getprogname() ?: "(unknown)", path, argument,
            result, result < 0 ? savedError : 0,
            __builtin_return_address(0));
    fflush(stderr);
}

static int MacWSSteamPipeOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    int result = (flags & O_CREAT) ? open(path, flags, mode) :
        open(path, flags);
    int savedError = errno;
    MacWSLogSteamPipeCall("open", path, flags, result, savedError);
    errno = savedError;
    return result;
}

static int MacWSSteamPipeMkfifo(const char *path, mode_t mode) {
    int result = mkfifo(path, mode);
    int savedError = errno;
    MacWSLogSteamPipeCall("mkfifo", path, mode, result, savedError);
    errno = savedError;
    return result;
}

static int MacWSSteamPipeUnlink(const char *path) {
    int result = unlink(path);
    int savedError = errno;
    MacWSLogSteamPipeCall("unlink", path, 0, result, savedError);
    errno = savedError;
    return result;
}

DYLD_INTERPOSE(MacWSSteamPipeOpen, open)
DYLD_INTERPOSE(MacWSSteamPipeMkfifo, mkfifo)
DYLD_INTERPOSE(MacWSSteamPipeUnlink, unlink)

// Diagnostic-only: ElleKit installs a task exception port the first time its
// JIT-less hook machinery is used. For Steam Helper this converts the original
// startup exception into exit(1), so neither CrashReporter nor LLDB receives
// the faulting state. Refuse only CydiaSubstrate's exact installation call
// under an explicit one-shot flag; every other task_set_exception_ports call
// and all production runs preserve the native kernel result.
static bool MacWSIsTopLevelSteamHelperForNativeException(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "Steam Helper")) return false;
    char ***argumentsPointer = _NSGetArgv();
    char **arguments = argumentsPointer ? *argumentsPointer : NULL;
    for (size_t index = 1; arguments && arguments[index]; index++) {
        if (!strncmp(arguments[index], "--type=", 7)) return false;
    }
    return true;
}

static bool MacWSIsAnySteamHelper(void) {
    const char *program = getprogname();
    return program && strcmp(program, "Steam Helper") == 0;
}

static kern_return_t MacWSSteamDiagnosticTaskSetExceptionPorts(
    task_t task, exception_mask_t mask, mach_port_t newPort,
    exception_behavior_t behavior, thread_state_flavor_t flavor) {
    if (getenv("MACWS_STEAM_NATIVE_EXCEPTION_DIAGNOSTICS") &&
        MacWSIsTopLevelSteamHelperForNativeException()) {
        Dl_info caller = {0};
        void *returnAddress = __builtin_return_address(0);
        if (dladdr(returnAddress, &caller) && caller.dli_fname &&
            strstr(caller.dli_fname, "/CydiaSubstrate.framework/")) {
            fprintf(stderr,
                    "[MacWSSteamNativeException] refused ElleKit exception "
                    "port caller=%p mask=%#x behavior=%#x flavor=%d\n",
                    returnAddress, mask, behavior, flavor);
            fflush(stderr);
            return KERN_FAILURE;
        }
    }
    return task_set_exception_ports(task, mask, newPort, behavior, flavor);
}

DYLD_INTERPOSE(MacWSSteamDiagnosticTaskSetExceptionPorts,
               task_set_exception_ports)

static void MacWSSteamExitDiagnostics(void) {
    if (!getenv("MACWS_STEAM_EXIT_DIAGNOSTICS")) return;
    void *frames[96];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    fprintf(stderr,
            "[MacWSSteamExitDiagnostics] atexit pid=%d program=%s frames=%d\n",
            getpid(), getprogname() ?: "(unknown)", count);
    for (int index = 0; index < count; index++) {
        Dl_info image = {0};
        if (dladdr(frames[index], &image) && image.dli_fbase) {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p %s+%#lx %s\n",
                    index, frames[index], image.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                                    (uintptr_t)image.dli_fbase),
                    image.dli_sname ?: "(unknown)");
        } else {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p\n",
                    index, frames[index]);
        }
    }
    fflush(stderr);
}

typedef void (*MacWSNoreturnStatusFunction)(int);
static MacWSNoreturnStatusFunction gMacWSOriginalExit;
static MacWSNoreturnStatusFunction gMacWSOriginalUnderscoreExit;
static MacWSNoreturnStatusFunction gMacWSOriginalCapitalExit;

static void MacWSLogSteamTermination(const char *api, int status) {
    // The ElleKit exception-port worker converts an unhandled Mach exception
    // into exit(1), obscuring the original faulting thread from CrashReporter
    // and LLDB's signal handlers. An explicitly requested one-shot diagnostic
    // stops the task before the worker destroys that evidence; attaching LLDB
    // can then inspect every thread without changing the production outcome.
    if (getenv("MACWS_STEAM_EXIT_STOP")) raise(SIGSTOP);
    void *frames[96];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    fprintf(stderr,
            "[MacWSSteamExitDiagnostics] api=%s pid=%d program=%s "
            "status=%d frames=%d\n",
            api, getpid(), getprogname() ?: "(unknown)", status, count);
    for (int index = 0; index < count; index++) {
        Dl_info image = {0};
        if (dladdr(frames[index], &image) && image.dli_fbase) {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p %s+%#lx %s\n",
                    index, frames[index], image.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                                    (uintptr_t)image.dli_fbase),
                    image.dli_sname ?: "(unknown)");
        }
    }
    fflush(stderr);
}

__attribute__((noreturn))
static void MacWSSteamExit(int status) {
    MacWSLogSteamTermination("exit", status);
    gMacWSOriginalExit(status);
    __builtin_unreachable();
}

__attribute__((noreturn))
static void MacWSSteamUnderscoreExit(int status) {
    MacWSLogSteamTermination("_exit", status);
    gMacWSOriginalUnderscoreExit(status);
    __builtin_unreachable();
}

__attribute__((noreturn))
static void MacWSSteamCapitalExit(int status) {
    MacWSLogSteamTermination("_Exit", status);
    gMacWSOriginalCapitalExit(status);
    __builtin_unreachable();
}

__attribute__((constructor))
static void MacWSInstallSteamExitDiagnostics(void) {
    if (!getenv("MACWS_STEAM_EXIT_DIAGNOSTICS") ||
        !MacWSIsAnySteamHelper()) return;
    atexit(MacWSSteamExitDiagnostics);
    void *exitTarget = dlsym(RTLD_DEFAULT, "exit");
    void *underscoreExitTarget = dlsym(RTLD_DEFAULT, "_exit");
    void *capitalExitTarget = dlsym(RTLD_DEFAULT, "_Exit");
    if (exitTarget)
        MSHookFunction(exitTarget, (void *)MacWSSteamExit,
                       (void **)&gMacWSOriginalExit);
    if (underscoreExitTarget)
        MSHookFunction(underscoreExitTarget, (void *)MacWSSteamUnderscoreExit,
                       (void **)&gMacWSOriginalUnderscoreExit);
    if (capitalExitTarget && capitalExitTarget != underscoreExitTarget)
        MSHookFunction(capitalExitTarget, (void *)MacWSSteamCapitalExit,
                       (void **)&gMacWSOriginalCapitalExit);
}
