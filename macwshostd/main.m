// macwshostd — root-side, typed control plane for the native iPadOS host.
//
// This service intentionally exposes no shell strings and no arbitrary paths.
// Every request maps to a fixed operation and fixed argv/path allowlist.  The
// existing macos_gui.sh remains the single source of truth for chroot repair,
// GUI lifecycle, and crash-loop protection.

@import Foundation;
@import Darwin;

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "macws_control_protocol.h"
#include "macws_host_protocol.h"
#include "macws_stream_protocol.h"

extern char **environ;

// Darwin's public spawn.h does not expose this Apple-private declaration,
// although libsystem has shipped it since iOS 6.  XNU 8792 maps process type
// 0x100 to TASK_APPTYPE_APP_DEFAULT.  macOS AppKit's concurrent scrolling
// creates a CA_CLIENT work interval; the iOS kernel deliberately rejects that
// work-interval type with KERN_NOT_SUPPORTED when task_is_app() is false.
// Mark the child at its real spawn boundary instead of translating the work
// interval or suppressing AppKit's invariant.
extern int posix_spawnattr_setprocesstype_np(posix_spawnattr_t *attr,
                                              int processType);
#define MACWS_POSIX_SPAWN_PROC_TYPE_APP_DEFAULT 0x00000100

static const char *const kLogPath = "/var/mobile/Library/Logs/MacWSHostd.log";
static const char *const kRootFS = "/var/mnt/rootfs";
static const char *const kGUI = "/var/jb/usr/macOS/bin/macos_gui.sh";
static const char *const kBash = "/var/jb/usr/bin/bash";
static const char *const kLaunchctl = "/var/jb/usr/bin/launchctl";
static const char *const kKillall = "/var/jb/usr/bin/killall";
static const char *const kChrootExec = "/var/jb/usr/macOS/bin/launchdchrootexec";
static const char *const kWorkspaceCtl = "/usr/local/bin/macwsworkspacectl";
static const char *const kPostinst = "/var/jb/usr/macOS/bin/postinst.sh";
static const char *const kFrame = "/var/mnt/rootfs/private/tmp/macws_vnc_fb";
static const char *const kInputSocket = "/var/mnt/rootfs/private/tmp/macws_host_input.sock";
static const char *const kShareFlag = "/var/mnt/rootfs/private/tmp/macws_vnc_share";
static const char *const kCaptureFlag = "/var/mnt/rootfs/tmp/macws_capture_final";
static const char *const kCaptureAck = "/var/mnt/rootfs/tmp/macws_capture_done";
static const char *const kExperimentalKCmd = "/var/mnt/rootfs/private/tmp/macws_kcmd_fix";
static const char *const kExperimentalCompletion = "/var/mnt/rootfs/private/tmp/macws_cancel_completion";
static const char *const kWindowServerLog = "/var/jb/var/mobile/WindowServer.err";
static const char *const kSafetyTrip = "/var/jb/var/mobile/macws_safety_trip";
static const char *const kWindowServerLabel =
    "UIKitApplication:com.macwsguide.windowserver";
static const char *const kInputLabel =
    "UIKitApplication:com.macwsguide.input";
static const char *const kDisplayLabel =
    "UIKitApplication:com.macwsguide.display";
static const char *const kVSCodeLabel =
    "UIKitApplication:com.macwsguide.vscode";
static const char *const kVSCodePlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist";
static const char *const kVSCodeLog = "/var/jb/var/mobile/vscode.log";
static const char *const kVSCodeHealthMarker =
    "/var/jb/var/mobile/vscode-health-marker";
static const char *const kVSCodeExecutable =
    "/Applications/Visual Studio Code.app/Contents/MacOS/Electron";
// Current VS Code's bundle metadata names the thin launcher `Code`, while the
// production launchd job intentionally runs the equivalent `Electron` entry
// with MacWS's JIT/environment contract. Dock resolves CFBundleExecutable and
// therefore presents this path to the generic launch boundary.
static const char *const kVSCodeBundleExecutable =
    "/Applications/Visual Studio Code.app/Contents/MacOS/Code";
static const char *const kUIKitSystemPlist =
    "/var/jb/usr/macOS/LaunchDaemons/com.apple.uikitsystemapp.plist";
static const char *const kUIKitSystemExecutable =
    "/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem";
static const char *const kMapsExecutable =
    "/System/Applications/Maps.app/Contents/MacOS/Maps";
static const char *const kMapsHostCarrierMarker =
    "/var/jb/var/mobile/macws-maps-host-carrier.pid";
static const char *const kAsphaltExecutable =
    "/Applications/Asphalt.app/Contents/MacOS/Asphalt";
static const char *const kAsphaltBundleIdentifier =
    "com.gameloft.asphalt9mac";
static const char *const kAsphaltContainerHome =
    "/Users/mobile/Library/Containers/com.gameloft.asphalt9mac/Data";
static const char *const kCatalystRequestPath =
    "/var/jb/var/mobile/macws-catalyst-launch-request.plist";
static CFStringRef const kMapsHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-maps");
static CFStringRef const kCatalystHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-catalyst");
static pid_t WaitForRunningRootExecutable(NSString *rootPath,
                                          NSTimeInterval timeout);

static dispatch_queue_t gControlQueue;
static dispatch_queue_t gLogQueue;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static BOOL gBusy;
static NSString *gPhase = @"就绪";
static NSString *gLastError = @"";
static pid_t gActiveAppPID;
static NSString *gActiveAppID = @"";

static void HostLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void HostLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", message);
    dispatch_async(gLogQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
            if (fd < 0) return;
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                              NSDate.date.timeIntervalSince1970, message];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            (void)write(fd, data.bytes, data.length);
            close(fd);
        }
    });
}

static void SetState(BOOL busy, NSString *phase, NSString *error) {
    os_unfair_lock_lock(&gStateLock);
    gBusy = busy;
    if (phase) gPhase = [phase copy];
    if (error) gLastError = [error copy];
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"state busy=%@ phase=%@ error=%@", busy ? @"YES" : @"NO",
            phase ?: gPhase, error ?: gLastError);
}

static BOOL TouchPath(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

static BOOL HasExecutableFileMode(const char *path) {
    struct stat status = {0};
    return path && stat(path, &status) == 0 && S_ISREG(status.st_mode) &&
        (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}

// Build a private, deterministic envp for one child. posix_spawn consumes the
// strings synchronously, so the caller frees it immediately after the call.
// Existing entries with the same key are replaced instead of relying on the
// undefined first/last behavior of duplicate environment variables.
static char **CopyEnvironmentAdding(const char *const *additions,
                                    size_t additionCount) {
    size_t inheritedCount = 0;
    for (char **cursor = environ; cursor && *cursor; cursor++) {
        BOOL replaced = NO;
        for (size_t index = 0; index < additionCount; index++) {
            const char *equals = additions[index]
                ? strchr(additions[index], '=') : NULL;
            size_t keyLength = equals
                ? (size_t)(equals - additions[index]) : 0;
            if (keyLength != 0 &&
                strncmp(*cursor, additions[index], keyLength) == 0 &&
                (*cursor)[keyLength] == '=') {
                replaced = YES;
                break;
            }
        }
        if (!replaced) inheritedCount++;
    }

    char **result = calloc(inheritedCount + additionCount + 1,
                           sizeof(*result));
    if (!result) return NULL;
    size_t output = 0;
    for (char **cursor = environ; cursor && *cursor; cursor++) {
        BOOL replaced = NO;
        for (size_t index = 0; index < additionCount; index++) {
            const char *equals = additions[index]
                ? strchr(additions[index], '=') : NULL;
            size_t keyLength = equals
                ? (size_t)(equals - additions[index]) : 0;
            if (keyLength != 0 &&
                strncmp(*cursor, additions[index], keyLength) == 0 &&
                (*cursor)[keyLength] == '=') {
                replaced = YES;
                break;
            }
        }
        if (!replaced) result[output++] = strdup(*cursor);
    }
    for (size_t index = 0; index < additionCount; index++)
        result[output++] = strdup(additions[index]);
    for (size_t index = 0; index < output; index++) {
        if (!result[index]) {
            for (size_t cleanup = 0; cleanup < output; cleanup++)
                free(result[cleanup]);
            free(result);
            return NULL;
        }
    }
    return result;
}

static void FreeCopiedEnvironment(char **environment) {
    if (!environment) return;
    for (char **cursor = environment; *cursor; cursor++) free(*cursor);
    free(environment);
}

static uint64_t ArmCapture(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    static _Atomic uint64_t lastGeneration = 0;
    uint64_t generation = (uint64_t)now.tv_sec * 1000000000ull +
                          (uint64_t)now.tv_nsec;
    uint64_t previous = atomic_load(&lastGeneration);
    while (generation <= previous) generation = previous + 1;
    atomic_store(&lastGeneration, generation);

    char value[48];
    int length = snprintf(value, sizeof(value), "%llu\n",
                          (unsigned long long)generation);
    int fd = open(kCaptureFlag,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    ssize_t written = write(fd, value, (size_t)length);
    int savedErrno = errno;
    close(fd);
    if (written != length) {
        errno = written < 0 ? savedErrno : EIO;
        (void)unlink(kCaptureFlag);
        return 0;
    }
    HostLog(@"capture armed generation=%llu",
            (unsigned long long)generation);
    return generation;
}

static void RemovePath(const char *path) {
    if (unlink(path) != 0 && errno != ENOENT)
        HostLog(@"unlink failed path=%s errno=%d (%s)", path, errno, strerror(errno));
}

static int RunCommandWithEnvironment(const char *const argv[],
                                     char *const environment[],
                                     BOOL waitForExit) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, argv[0], &actions, NULL,
                                 (char *const *)argv,
                                 environment ? environment : environ);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (spawnError != 0) {
        HostLog(@"spawn failed executable=%s error=%d (%s)", argv[0],
                spawnError, strerror(spawnError));
        return 128 + spawnError;
    }
    HostLog(@"spawned pid=%d executable=%s wait=%@", pid, argv[0],
            waitForExit ? @"YES" : @"NO");
    if (!waitForExit) return 0;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        HostLog(@"waitpid failed pid=%d errno=%d", pid, errno);
        return 127;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 126;
}

static int RunCommand(const char *const argv[], BOOL waitForExit) {
    return RunCommandWithEnvironment(argv, environ, waitForExit);
}

static int SpawnMacOSApplication(pid_t *pid,
                                 const char *path,
                                 const posix_spawn_file_actions_t *actions,
                                 char *const argv[],
                                 char *const environment[]) {
    posix_spawnattr_t attributes;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0) return error;
    error = posix_spawnattr_setprocesstype_np(
        &attributes, MACWS_POSIX_SPAWN_PROC_TYPE_APP_DEFAULT);
    if (error == 0) {
        error = posix_spawn(pid, path, actions, &attributes, argv,
                            environment ? environment : environ);
    }
    posix_spawnattr_destroy(&attributes);
    return error;
}

static NSString *CaptureCommand(const char *const argv[], NSUInteger limit) {
    int pipes[2];
    if (pipe(pipes) != 0) return @"";
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);
    pid_t pid = 0;
    int error = posix_spawn(&pid, argv[0], &actions, NULL,
                            (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (error != 0) {
        close(pipes[0]);
        return [NSString stringWithFormat:@"spawn %s: %s", argv[0], strerror(error)];
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    for (;;) {
        ssize_t count = read(pipes[0], buffer, sizeof(buffer));
        if (count > 0) {
            if (data.length + (NSUInteger)count > limit) {
                NSUInteger skip = data.length + (NSUInteger)count - limit;
                if (skip < data.length)
                    [data replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
                else
                    [data setLength:0];
            }
            NSUInteger room = limit - data.length;
            [data appendBytes:buffer length:MIN((NSUInteger)count, room)];
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(pipes[0]);
    (void)waitpid(pid, NULL, 0);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static BOOL InspectJob(const char *label, int *pidOut, BOOL *loadedOut) {
    const char *argv[] = {kLaunchctl, "list", label, NULL};
    NSString *output = CaptureCommand(argv, 32768);
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\\"PID\\\"\\s*=\\s*([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0
                                                     range:NSMakeRange(0, output.length)];
    int pid = 0;
    if (match.numberOfRanges > 1)
        pid = [[output substringWithRange:[match rangeAtIndex:1]] intValue];
    if (loadedOut) {
        NSString *marker = [NSString stringWithFormat:@"\"Label\" = \"%s\"",
                            label];
        *loadedOut = [output containsString:marker];
    }
    if (pidOut) *pidOut = pid;
    return pid > 0;
}

static BOOL JobHasPID(const char *label, int *pidOut) {
    return InspectJob(label, pidOut, NULL);
}

static BOOL WaitForJobPID(const char *label, NSTimeInterval timeout,
                          int *pidOut) {
    int pid = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (JobHasPID(label, &pid)) {
            if (pidOut) *pidOut = pid;
            return YES;
        }
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    if (pidOut) *pidOut = 0;
    return NO;
}

static BOOL RootFSReady(void) {
    return access("/var/mnt/rootfs/bin/bash", X_OK) == 0 &&
           access("/var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", X_OK) == 0 &&
           access(kGUI, R_OK) == 0 && access(kChrootExec, X_OK) == 0;
}

static BOOL ReadFrame(uint32_t *width, uint32_t *height) {
    uint32_t header[4] = {0};
    int fd = open(kFrame, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat st = {0};
    if (fstat(fd, &st) != 0) {
        close(fd);
        return NO;
    }
    ssize_t count = read(fd, header, sizeof(header));
    close(fd);
    if (count != sizeof(header) || header[0] != MACWS_FRAME_MAGIC ||
        header[1] == 0 || header[2] == 0 || header[1] > 16384 ||
        header[2] > 16384 || header[3] != header[1] * 4u)
        return NO;
    uint64_t required = sizeof(header) + (uint64_t)header[3] * header[2];
    if ((uint64_t)st.st_size < required) return NO;
    if (width) *width = header[1];
    if (height) *height = header[2];
    return YES;
}

static BOOL ReadCaptureAck(int expectedPID, uint64_t expectedGeneration,
                           uint64_t *generationOut) {
    char value[96] = {0};
    int fd = open(kCaptureAck, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return NO;
    int pid = 0;
    unsigned long long generation = 0;
    if (sscanf(value, "%d %llu", &pid, &generation) != 2 ||
        pid != expectedPID || generation == 0 ||
        (expectedGeneration != 0 && generation != expectedGeneration))
        return NO;
    if (generationOut) *generationOut = (uint64_t)generation;
    return YES;
}

static BOOL IsSocket(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISSOCK(st.st_mode);
}

static BOOL IsAppInputSocket(pid_t pid) {
    if (pid <= 1) return NO;
    char path[128];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    return IsSocket(path);
}

static void SetString(xpc_object_t reply, const char *key, NSString *value) {
    xpc_dictionary_set_string(reply, key, value.UTF8String ?: "");
}

static NSString *ReadSmallTextFile(const char *path, NSUInteger limit) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return @"";
    NSMutableData *data = [NSMutableData dataWithLength:limit];
    ssize_t count = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (count <= 0) return @"";
    data.length = (NSUInteger)count;
    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    return [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static void AddStatus(xpc_object_t reply) {
    int wsPID = 0;
    BOOL ws = JobHasPID(kWindowServerLabel, &wsPID);
    int inputPID = 0;
    BOOL inputJob = JobHasPID(kInputLabel, &inputPID);
    uint32_t width = 0, height = 0;
    uint64_t frameGeneration = 0;
    BOOL frame = ws && ReadFrame(&width, &height) &&
        ReadCaptureAck(wsPID, 0, &frameGeneration);
    BOOL busy;
    NSString *phase;
    NSString *lastError;
    os_unfair_lock_lock(&gStateLock);
    busy = gBusy;
    phase = gPhase;
    lastError = gLastError;
    pid_t activeAppPID = gActiveAppPID;
    NSString *activeAppID = gActiveAppID;
    if (activeAppPID > 1 && kill(activeAppPID, 0) != 0 && errno == ESRCH) {
        gActiveAppPID = 0;
        gActiveAppID = @"";
        activeAppPID = 0;
        activeAppID = @"";
    }
    os_unfair_lock_unlock(&gStateLock);

    // macos_gui.sh runs its watchdog independently so it can still recover the
    // device if this daemon or the App disconnects. Surface its durable reason
    // through the typed status protocol instead of leaving the UI looking like
    // an unexplained WindowServer exit.
    NSString *safetyTrip = ReadSmallTextFile(kSafetyTrip, 1024);
    if (!ws && !busy && safetyTrip.length) {
        phase = @"安全保护已触发";
        lastError = safetyTrip;
    }

    xpc_dictionary_set_uint64(reply, "protocol_version", MACWS_CONTROL_VERSION);
    xpc_dictionary_set_bool(reply, "busy", busy);
    SetString(reply, "phase", phase);
    SetString(reply, "last_error", lastError);
    SetString(reply, "safety_trip", safetyTrip);
    xpc_dictionary_set_bool(reply, "rootfs_ready", RootFSReady());
    xpc_dictionary_set_bool(reply, "windowserver_running", ws);
    xpc_dictionary_set_int64(reply, "windowserver_pid", wsPID);
    xpc_dictionary_set_bool(reply, "input_running", inputJob && IsSocket(kInputSocket));
    xpc_dictionary_set_int64(reply, "input_pid", inputPID);
    xpc_dictionary_set_int64(reply, "active_app_pid", activeAppPID);
    SetString(reply, "active_app_id", activeAppID);
    xpc_dictionary_set_bool(reply, "app_input_ready",
                            IsAppInputSocket(activeAppPID));
    xpc_dictionary_set_bool(reply, "frame_ready", frame);
    xpc_dictionary_set_uint64(reply, "frame_width", width);
    xpc_dictionary_set_uint64(reply, "frame_height", height);
    xpc_dictionary_set_uint64(reply, "frame_generation", frameGeneration);
    xpc_dictionary_set_bool(reply, "experimental_mode",
        access(kExperimentalKCmd, F_OK) == 0 || access(kExperimentalCompletion, F_OK) == 0);
    xpc_dictionary_set_bool(reply, "glassdemo_available", access("/var/mnt/rootfs/tmp/GlassDemo", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "terminal_available", access("/var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "activity_monitor_available", access("/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "finder_available", access("/var/mnt/rootfs/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "system_settings_available",
        access("/var/mnt/rootfs/System/Applications/System Settings.app/Contents/MacOS/System Settings", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "maps_available",
        access("/var/mnt/rootfs/System/Applications/Maps.app/Contents/MacOS/Maps", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "vscode_available",
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron", X_OK) == 0 &&
        access(kVSCodePlist, R_OK) == 0);
    xpc_dictionary_set_bool(reply, "amadine_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Amadine.app/Contents/MacOS/Amadine"));
    xpc_dictionary_set_bool(reply, "word_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word"));
    xpc_dictionary_set_bool(reply, "excel_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel"));
    xpc_dictionary_set_bool(reply, "powerpoint_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft PowerPoint.app/Contents/MacOS/Microsoft PowerPoint"));
    xpc_dictionary_set_bool(reply, "asphalt_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Asphalt.app/Contents/MacOS/Asphalt"));
}

static NSString *TailFile(const char *path, NSUInteger limit) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return @"";
    off_t end = lseek(fd, 0, SEEK_END);
    off_t start = end > (off_t)limit ? end - (off_t)limit : 0;
    (void)lseek(fd, start, SEEK_SET);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(end - start)];
    ssize_t count = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (count < 0) return @"";
    data.length = (NSUInteger)count;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static void ReplyResult(xpc_object_t request, BOOL ok, NSString *message,
                        void (^extra)(xpc_object_t reply)) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return;
    xpc_dictionary_set_bool(reply, "ok", ok);
    SetString(reply, "message", message ?: @"");
    if (extra) extra(reply);
    xpc_connection_send_message(peer, reply);
}

// macOS Libinfo normally sends getaddrinfo requests to mDNSResponder.  The
// chroot has the Ventura client frameworks but not a viable resolver daemon in
// its bootstrap namespace, while this iOS-native daemon has the real network
// configuration and resolver service.  Preserve the standard getaddrinfo ABI
// across a small typed XPC request; callers reconstruct ordinary addrinfo
// nodes and keep the successful local macOS path untouched.
static void ReplyHostResolution(xpc_object_t request) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return;

    const char *node = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_DNS_NODE);
    const char *service = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_DNS_SERVICE);
    if (!node || node[0] == '\0' || strnlen(node, 254) > 253 ||
        (service && strnlen(service, 65) > 64)) {
        xpc_dictionary_set_int64(reply, "gai_error", EAI_NONAME);
        xpc_connection_send_message(peer, reply);
        return;
    }

    struct addrinfo hints = {0};
    hints.ai_flags = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_FLAGS);
    hints.ai_family = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_FAMILY);
    hints.ai_socktype = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_SOCKTYPE);
    hints.ai_protocol = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_PROTOCOL);
    if (hints.ai_family != AF_UNSPEC && hints.ai_family != AF_INET &&
        hints.ai_family != AF_INET6) {
        xpc_dictionary_set_int64(reply, "gai_error", EAI_FAMILY);
        xpc_connection_send_message(peer, reply);
        return;
    }

    struct addrinfo *resolved = NULL;
    int error = getaddrinfo(node, service && service[0] ? service : NULL,
                            &hints, &resolved);
    xpc_dictionary_set_int64(reply, "gai_error", error);
    if (error == 0) {
        xpc_object_t entries = xpc_array_create(NULL, 0);
        size_t count = 0;
        for (const struct addrinfo *item = resolved;
             item && count < 64; item = item->ai_next, count++) {
            if (!item->ai_addr || item->ai_addrlen == 0 ||
                item->ai_addrlen > sizeof(struct sockaddr_storage)) continue;
            xpc_object_t entry = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_int64(entry, "flags", item->ai_flags);
            xpc_dictionary_set_int64(entry, "family", item->ai_family);
            xpc_dictionary_set_int64(entry, "socktype", item->ai_socktype);
            xpc_dictionary_set_int64(entry, "protocol", item->ai_protocol);
            xpc_dictionary_set_data(entry, "address", item->ai_addr,
                                    item->ai_addrlen);
            if (item->ai_canonname)
                xpc_dictionary_set_string(entry, "canonname",
                                          item->ai_canonname);
            xpc_array_append_value(entries, entry);
        }
        xpc_dictionary_set_value(reply, "results", entries);
        freeaddrinfo(resolved);
    }
    xpc_connection_send_message(peer, reply);
}

static BOOL WaitForGUIComponents(NSTimeInterval timeout, int *wsPIDOut) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        int pid = 0;
        if (JobHasPID(kWindowServerLabel, &pid) &&
            JobHasPID(kInputLabel, NULL) &&
            JobHasPID(kDisplayLabel, NULL) &&
            IsSocket(kInputSocket)) {
            if (wsPIDOut) *wsPIDOut = pid;
            return YES;
        }
        usleep(250000);
    }
    return NO;
}

static BOOL WaitForCapture(int wsPID, uint64_t generation,
                           NSTimeInterval timeout, BOOL *processExited) {
    if (processExited) *processExited = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (kill(wsPID, 0) != 0 && errno == ESRCH) {
            if (processExited) *processExited = YES;
            return NO;
        }
        if (ReadCaptureAck(wsPID, generation, NULL) && ReadFrame(NULL, NULL))
            return YES;
        usleep(100000);
    }
    return NO;
}

static void RotateWindowServerLog(void) {
    NSString *previous = [@(kWindowServerLog) stringByAppendingString:@".previous"];
    (void)unlink(previous.fileSystemRepresentation);
    if (rename(kWindowServerLog, previous.fileSystemRepresentation) == 0)
        HostLog(@"rotated WindowServer log to %@", previous);
}

static BOOL StopGUI(NSString **message);

static BOOL StartGUI(BOOL experimental, NSString **message) {
    if (!RootFSReady()) {
        *message = @"macOS rootfs 或启动组件不完整";
        return NO;
    }
    if (!TouchPath(kShareFlag)) {
        *message = [NSString stringWithFormat:@"无法准备共享帧标志: %s", strerror(errno)];
        return NO;
    }
    RemovePath(kFrame);
    RemovePath(kCaptureFlag);
    RemovePath(kCaptureAck);
    RemovePath(kSafetyTrip);
    if (experimental) {
        // Explicitly diagnostic: these flags do not represent protocol fixes.
        if (!TouchPath(kExperimentalKCmd) || !TouchPath(kExperimentalCompletion)) {
            *message = @"无法启用实验兼容模式";
            return NO;
        }
        HostLog(@"DIAGNOSTIC-SCAFFOLD enabled: macws_kcmd_fix + macws_cancel_completion");
    } else {
        RemovePath(kExperimentalKCmd);
        RemovePath(kExperimentalCompletion);
    }

    RotateWindowServerLog();
    SetState(YES, @"检查并修复启动环境…", @"");
    const char *startArgv[] = {kBash, kGUI, "start", "coexist",
                               "--no-terminal", "--no-vnc", NULL};
    int rc = RunCommand(startArgv, YES);
    if (rc != 0) {
        *message = [NSString stringWithFormat:@"GUI 启动脚本失败（退出码 %d）", rc];
        return NO;
    }
    // The script has already loaded and validated WindowServer, inputd and
    // displayd.  In the native window architecture there is intentionally no
    // AppKit window yet (`--no-terminal --no-vnc`), so requiring a framebuffer
    // acknowledgement here creates a circular dependency: the user cannot
    // launch an app until a frame exists, while no frame can exist until an
    // app is launched.  Runtime-confirmed on 2026-07-31: all three services
    // remained healthy for a minute with a zero-window DisplayStream, then the
    // old 60-second capture deadline tore them down.  Establish workspace
    // readiness from the actual service endpoints; LaunchAllowedApp separately
    // requires that process's real NSWindow metrics before reporting success.
    SetState(YES, @"等待 WindowServer、触控与窗口流…", @"");
    int wsPID = 0;
    if (WaitForGUIComponents(15.0, &wsPID)) {
        *message = @"macOS 工作区、触控桥与窗口流已就绪";
        return YES;
    }

    HostLog(@"workspace endpoints unavailable after launcher success");
    NSString *stopMessage = nil;
    (void)StopGUI(&stopMessage);
    *message = @"macOS 工作区服务未能完成就绪，已安全停止";
    return NO;
}

static BOOL StopGUI(NSString **message) {
    const char *argv[] = {kBash, kGUI, "stop", NULL};
    int rc = RunCommand(argv, YES);
    const char *unloadUIKitSystem[] = {
        kLaunchctl, "unload", kUIKitSystemPlist, NULL,
    };
    (void)RunCommand(unloadUIKitSystem, YES);
    const char *appNames[] = {"GlassDemo", "Terminal", "Activity Monitor",
                              "Finder", "System Settings", "Maps",
                              "MacWSCatalystLauncher", "UIKitSystem"};
    for (NSUInteger i = 0; i < sizeof(appNames) / sizeof(appNames[0]); i++) {
        const char *killArgv[] = {kKillall, "-9", appNames[i], NULL};
        (void)RunCommand(killArgv, YES);
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = 0;
    gActiveAppID = @"";
    os_unfair_lock_unlock(&gStateLock);
    RemovePath(kFrame);
    RemovePath(kShareFlag);
    RemovePath(kCaptureFlag);
    RemovePath(kCaptureAck);
    RemovePath(kExperimentalKCmd);
    RemovePath(kExperimentalCompletion);
    if (rc != 0) {
        *message = [NSString stringWithFormat:@"停止脚本失败（退出码 %d）", rc];
        return NO;
    }
    *message = @"macOS GUI 已停止，iPadOS 保持运行";
    return YES;
}

typedef struct {
    const char *identifier;
    const char *rootPath;
    const char *logPath;
} AllowedApp;

static const AllowedApp kAllowedApps[] = {
    {"glassdemo", "/tmp/GlassDemo", "/var/mobile/Library/Logs/GlassDemo.host.log"},
    {"terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "/var/mobile/Library/Logs/Terminal.host.log"},
    {"activity-monitor", "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", "/var/mobile/Library/Logs/ActivityMonitor.host.log"},
    {"finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/var/mobile/Library/Logs/Finder.host.log"},
    {"system-settings", "/System/Applications/System Settings.app/Contents/MacOS/System Settings", "/var/mobile/Library/Logs/SystemSettings.host.log"},
    {"maps", "/System/Applications/Maps.app/Contents/MacOS/Maps", "/var/mobile/Library/Logs/Maps.host.log"},
    {"amadine", "/Applications/Amadine.app/Contents/MacOS/Amadine", "/var/mobile/Library/Logs/Amadine.host.log"},
    {"word", "/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word", "/var/mobile/Library/Logs/MicrosoftWord.host.log"},
    {"excel", "/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel", "/var/mobile/Library/Logs/MicrosoftExcel.host.log"},
    {"powerpoint", "/Applications/Microsoft PowerPoint.app/Contents/MacOS/Microsoft PowerPoint", "/var/mobile/Library/Logs/MicrosoftPowerPoint.host.log"},
};

static BOOL IsThirdPartyAppIdentifier(const char *identifier) {
    return identifier &&
        (strcmp(identifier, "amadine") == 0 ||
         strcmp(identifier, "word") == 0 ||
         strcmp(identifier, "excel") == 0 ||
         strcmp(identifier, "powerpoint") == 0);
}

// A native Host launch is complete when AppInputBridge has published at least
// one real NSWindow descriptor. This replaces the VNC framebuffer
// acknowledgement, which is intentionally absent under `start --no-vnc`.
static uint64_t ReadWindowMetricsGeneration(pid_t pid) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_window_metrics.%d.bin", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    MacWSWindowMetricsHeader header = {0};
    struct stat st = {0};
    ssize_t count = read(fd, &header, sizeof(header));
    BOOL valid = fstat(fd, &st) == 0 &&
        count == (ssize_t)sizeof(header) &&
        st.st_size >= (off_t)sizeof(header) &&
        MacWSWindowMetricsAreValid(&header, (size_t)st.st_size);
    close(fd);
    return valid ? header.generation : 0;
}

static BOOL WaitForWindowMetricsFlagsAfterGeneration(
        pid_t pid, NSTimeInterval timeout, uint32_t requiredFlags,
        uint64_t minimumGenerationExclusive, int *exitStatusOut) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_window_metrics.%d.bin", pid);
    // AppInputBridge removes this PID-scoped sidecar in the target process's
    // constructor before it starts publishing.  Removing it here races a
    // process that is already running (notably a reused VS Code launch): its
    // unchanged-window fast path would then have no reason to recreate the
    // file, turning a healthy window into a 30-second false timeout.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            if (exitStatusOut) *exitStatusOut = status;
            return NO;
        }

        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            struct stat st = {0};
            MacWSWindowMetricsHeader header = {0};
            ssize_t count = read(fd, &header, sizeof(header));
            BOOL valid = fstat(fd, &st) == 0 &&
                count == (ssize_t)sizeof(header) &&
                st.st_size >= (off_t)sizeof(header) &&
                MacWSWindowMetricsAreValid(&header, (size_t)st.st_size);
            BOOL ready = NO;
            if (valid &&
                (minimumGenerationExclusive == 0 ||
                 header.generation > minimumGenerationExclusive)) {
                // NSApplication.windows retains ordered-out panels and other
                // invisible objects after the last user window closes.
                // Runtime-confirmed with Terminal after Scene discard: the
                // sidecar still had entries while displayd's validated
                // catalog had no window for that PID. A launch is reusable
                // only when at least one real AppKit window is visible.
                for (uint32_t index = 0; index < header.entryCount; index++) {
                    MacWSWindowMetricsEntry entry = {0};
                    off_t offset = (off_t)header.size +
                        (off_t)index * header.entrySize;
                    if (pread(fd, &entry, sizeof(entry), offset) !=
                            (ssize_t)sizeof(entry))
                        break;
                    if ((entry.flags & requiredFlags) == requiredFlags) {
                        ready = YES;
                        break;
                    }
                }
            }
            close(fd);
            if (ready) return YES;
        }
        usleep(100000);
    }
    return NO;
}

static BOOL WaitForWindowMetricsFlags(pid_t pid, NSTimeInterval timeout,
                                      uint32_t requiredFlags,
                                      int *exitStatusOut) {
    return WaitForWindowMetricsFlagsAfterGeneration(
        pid, timeout, requiredFlags, 0, exitStatusOut);
}

static BOOL WaitForWindowMetrics(pid_t pid, NSTimeInterval timeout,
                                 int *exitStatusOut) {
    return WaitForWindowMetricsFlags(pid, timeout,
                                     MacWSStreamWindowVisible,
                                     exitStatusOut);
}

// launchd reaps macwshostd itself, but a successfully launched macOS app is
// our direct child.  WaitForWindowMetrics owns waitpid only until the first
// real window is published; after that there was previously no waiter at all.
// Runtime witness on 2026-08-01: killed Terminal PID 6471 remained
// `Z <defunct>` with macwshostd as PPID, so later launch/reuse transactions
// accumulated stale process state.  Install one blocking waiter only after
// the initial-window transaction has finished, avoiding a race with its
// WNOHANG exit witness while guaranteeing every long-lived app is reaped.
static void BeginApplicationChildReaper(pid_t pid, NSString *identifier) {
    if (pid <= 1) return;
    NSString *identifierCopy = [identifier copy] ?: @"app";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t waited = 0;
        do {
            waited = waitpid(pid, &status, 0);
        } while (waited < 0 && errno == EINTR);
        if (waited == pid) {
            NSString *result = WIFEXITED(status)
                ? [NSString stringWithFormat:@"exit-%d", WEXITSTATUS(status)]
                : (WIFSIGNALED(status)
                    ? [NSString stringWithFormat:@"signal-%d", WTERMSIG(status)]
                    : [NSString stringWithFormat:@"status-%d", status]);
            HostLog(@"launch-app reaped id=%@ pid=%d result=%@",
                    identifierCopy, pid, result);
            os_unfair_lock_lock(&gStateLock);
            if (gActiveAppPID == pid) {
                gActiveAppPID = 0;
                gActiveAppID = @"";
            }
            os_unfair_lock_unlock(&gStateLock);
        } else if (errno != ECHILD) {
            HostLog(@"launch-app reap-failed id=%@ pid=%d errno=%d (%s)",
                    identifierCopy, pid, errno, strerror(errno));
        }
    });
}

static BOOL WaitForAppInputEndpoint(pid_t pid, NSTimeInterval timeout) {
    if (pid <= 1) return NO;
    char path[PATH_MAX] = {0};
    int length = snprintf(path, sizeof(path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (access(path, F_OK) == 0) return YES;
        if (kill(pid, 0) != 0 && errno == ESRCH) return NO;
        usleep(50000);
    }
    return NO;
}

static BOOL SendAppInputRecord(pid_t pid, MacWSInputRecord *record,
                               int *errorOut) {
    if (pid <= 1 || !record) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        if (errorOut) *errorOut = errno;
        return NO;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    int length = snprintf(address.sun_path, sizeof(address.sun_path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) {
        close(socketFD);
        if (errorOut) *errorOut = ENAMETOOLONG;
        return NO;
    }
    record->targetPID = pid;
    ssize_t sent = sendto(socketFD, record, sizeof(*record), 0,
        (const struct sockaddr *)&address, sizeof(address));
    int savedError = sent < 0 ? errno :
        (sent == (ssize_t)sizeof(*record) ? 0 : EMSGSIZE);
    close(socketFD);
    if (errorOut) *errorOut = savedError;
    return savedError == 0;
}

// Finder launched as a chroot executable reaches NSApplication's ordinary
// event loop but does not create a browser window by itself. Runtime evidence
// on 2026-08-01: PID 1400 kept a valid zero-entry metrics sidecar for 30 s,
// while its AppInputBridge endpoint was live and the process stayed healthy.
// Ask that exact AppKit process to resolve and perform its standard enabled
// Command-N menu target/action, then require a visible-window metrics witness.
// This is the missing launch action, not a synthetic window or uptime check.
static BOOL RequestFinderBrowserWindow(pid_t pid, NSTimeInterval timeout) {
    if (!WaitForAppInputEndpoint(pid, MIN(timeout, 5.0))) {
        HostLog(@"finder-bootstrap pid=%d result=no-appinput-endpoint", pid);
        return NO;
    }
    static _Atomic uint32_t sampleSequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindCreateInitialWindow,
        .x = 0.0f,
        .y = 0.0f,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = pid,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sampleSequence, 1) + 1,
    };
    int sendError = 0;
    BOOL sent = SendAppInputRecord(pid, &record, &sendError);
    HostLog(@"finder-bootstrap pid=%d action=appkit-command-n sent=%@ "
            "errno=%d", pid, sent ? @"YES" : @"NO", sendError);
    if (!sent) return NO;
    int exitStatus = -1;
    BOOL ready = WaitForWindowMetrics(pid, timeout, &exitStatus);
    HostLog(@"finder-bootstrap pid=%d result=%@ exit-status=%d", pid,
            ready ? @"window-ready" : @"no-visible-window", exitStatus);
    return ready;
}

// Apps launched by launchdchrootexec have a valid AppKit event loop,
// HIServices process record and real NSWindows, but launchservicesd cannot
// create their AppleEvent endpoint (runtime: both PID and ProcessSerialNumber
// kAEReopenApplication sends return procNotFound/-600).  System Settings is a
// concrete witness: its SwiftUI delegate creates an ordered-out settings scene
// at (239,87,715x625), then waits for the ordinary reopen lifecycle before
// ordering it on screen. Deliver that exact public NSApplicationDelegate
// lifecycle inside the owning process and require a visible metrics entry.
static BOOL RequestApplicationReopen(pid_t pid, NSTimeInterval timeout) {
    if (!WaitForAppInputEndpoint(pid, MIN(timeout, 5.0))) {
        HostLog(@"application-reopen pid=%d result=no-appinput-endpoint", pid);
        return NO;
    }
    uint64_t previousGeneration = ReadWindowMetricsGeneration(pid);
    static _Atomic uint32_t sampleSequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindReopenApplication,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = pid,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sampleSequence, 1) + 1,
    };
    int sendError = 0;
    BOOL sent = SendAppInputRecord(pid, &record, &sendError);
    HostLog(@"application-reopen pid=%d sent=%@ errno=%d",
            pid, sent ? @"YES" : @"NO", sendError);
    if (!sent) return NO;
    int exitStatus = -1;
    BOOL ready = WaitForWindowMetricsFlagsAfterGeneration(
        pid, timeout, MacWSStreamWindowVisible, previousGeneration,
        &exitStatus);
    HostLog(@"application-reopen pid=%d result=%@ previous-generation=%llu "
            "current-generation=%llu exit-status=%d", pid,
            ready ? @"window-ready" : @"no-visible-window",
            (unsigned long long)previousGeneration,
            (unsigned long long)ReadWindowMetricsGeneration(pid), exitStatus);
    return ready;
}

// Return a live, real Ventura Settings UI extension. System Settings persists
// the selected pane, so Appearance is not a valid universal readiness proxy:
// after reopening on Displays, Bluetooth, etc. the shell is healthy while the
// Appearance executable is correctly absent. Match the exact stock extension
// point in the appex's Info.plist as well as its strict on-disk executable
// path; an unrelated ExtensionKit child cannot satisfy this witness.
static pid_t FindRunningSettingsExtension(NSString **executableOut) {
    typedef int (*MacWSProcListPIDs)(uint32_t, uint32_t, void *, int);
    typedef int (*MacWSProcPIDPath)(int, void *, uint32_t);
    static MacWSProcListPIDs procListPIDs;
    static MacWSProcPIDPath procPIDPath;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procListPIDs = (MacWSProcListPIDs)dlsym(
            RTLD_DEFAULT, "proc_listpids");
        procPIDPath = (MacWSProcPIDPath)dlsym(
            RTLD_DEFAULT, "proc_pidpath");
    });
    if (!procListPIDs || !procPIDPath) return 0;

    int capacity = procListPIDs(1 /* PROC_ALL_PIDS */, 0, NULL, 0);
    if (capacity <= 0) return 0;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return 0;
    int bytes = procListPIDs(1, 0, pids, capacity);
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    NSString *const rootPrefix = @"/System/Library/ExtensionKit/Extensions/";
    NSString *const hostPrefix =
        @"/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/";
    NSString *const privateHostPrefix =
        @"/private/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/";
    NSString *const executableMarker = @".appex/Contents/MacOS/";
    pid_t found = 0;
    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) continue;
        char processPath[4096] = {0};
        if (procPIDPath(pid, processPath, sizeof(processPath)) <= 0)
            continue;
        NSString *candidate = [NSString stringWithUTF8String:processPath];
        NSString *rootPath = nil;
        if ([candidate hasPrefix:rootPrefix]) {
            rootPath = candidate;
        } else if ([candidate hasPrefix:hostPrefix] ||
                   [candidate hasPrefix:privateHostPrefix]) {
            rootPath = [candidate substringFromIndex:
                [candidate hasPrefix:privateHostPrefix]
                    ? @"/private/var/mnt/rootfs".length
                    : @"/var/mnt/rootfs".length];
        } else {
            continue;
        }
        if ([rootPath containsString:@".."] ||
            ![rootPath containsString:executableMarker] ||
            [rootPath hasSuffix:executableMarker]) continue;
        NSRange marker = [rootPath rangeOfString:executableMarker];
        if (marker.location == NSNotFound) continue;
        NSUInteger appexEnd = marker.location + @".appex".length;
        NSString *bundleRoot = [rootPath substringToIndex:appexEnd];
        NSString *infoPath = [@"/var/mnt/rootfs"
            stringByAppendingFormat:@"%@/Contents/Info.plist", bundleRoot];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            infoPath];
        NSDictionary *attributes = [info[@"EXAppExtensionAttributes"]
            isKindOfClass:NSDictionary.class]
                ? info[@"EXAppExtensionAttributes"] : nil;
        NSString *extensionPoint = [attributes[@"EXExtensionPointIdentifier"]
            isKindOfClass:NSString.class]
                ? attributes[@"EXExtensionPointIdentifier"] : nil;
        if (![extensionPoint isEqualToString:
                @"com.apple.Settings.extension.ui"]) continue;
        if (kill(pid, 0) != 0 && errno != EPERM) continue;
        found = pid;
        if (executableOut) *executableOut = rootPath;
        break;
    }
    free(pids);
    return found;
}

// System Settings' SwiftUI shell can publish a real visible NSWindow before
// ExtensionKit has supplied the selected remote preference pane. Require both
// halves of the stock transaction: a fresh shell-window generation
// (RequestApplicationReopen above) and one real, metadata-validated Ventura
// Settings extension executable launched by ExtensionKit. This does not
// synthesize content or convert an extension error into success.
static BOOL WaitForSystemSettingsContent(NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSString *executable = nil;
        pid_t extensionPID = FindRunningSettingsExtension(&executable);
        if (extensionPID > 1) {
            HostLog(@"system-settings content result=settings-extension-ready "
                    "pid=%d executable=%@", extensionPID, executable);
            return YES;
        }
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    HostLog(@"system-settings content result=missing-settings-extension");
    return NO;
}

static off_t FileSizeAtPath(const char *path) {
    struct stat st = {0};
    return stat(path, &st) == 0 && st.st_size > 0 ? st.st_size : 0;
}

// Associate Electron's own renderer-health diagnostics with one launch.  The
// production log is append-only, so a byte boundary avoids both stale alerts
// from a prior PID and assumptions about wall-clock/time-zone formatting.
static void WriteVSCodeHealthMarker(pid_t pid, off_t logOffset) {
    char value[96];
    int length = snprintf(value, sizeof(value), "%d %lld\n", pid,
                          (long long)MAX(logOffset, (off_t)0));
    int fd = open(kVSCodeHealthMarker,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, value, (size_t)length);
    close(fd);
}

static BOOL ReadVSCodeHealthMarker(pid_t *pidOut, off_t *logOffsetOut) {
    char value[96] = {0};
    int fd = open(kVSCodeHealthMarker, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    int pid = 0;
    long long offset = 0;
    if (count <= 0 || sscanf(value, "%d %lld", &pid, &offset) != 2 ||
        pid <= 1 || offset < 0)
        return NO;
    if (pidOut) *pidOut = (pid_t)pid;
    if (logOffsetOut) *logOffsetOut = (off_t)offset;
    return YES;
}

static BOOL VSCodeLogContainsUnresponsiveAfter(off_t startOffset) {
    static const char needle[] = "CodeWindow: detected unresponsive";
    const NSUInteger overlap = sizeof(needle) - 2;
    int fd = open(kVSCodeLog, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || startOffset < 0 || startOffset > st.st_size) {
        close(fd);
        return NO;
    }
    if (lseek(fd, startOffset, SEEK_SET) < 0) {
        close(fd);
        return NO;
    }
    NSData *needleData = [NSData dataWithBytes:needle length:sizeof(needle) - 1];
    NSMutableData *window = [NSMutableData data];
    uint8_t buffer[32768];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            [window appendBytes:buffer length:(NSUInteger)count];
            if ([window rangeOfData:needleData options:0
                              range:NSMakeRange(0, window.length)].location !=
                    NSNotFound) {
                close(fd);
                return YES;
            }
            if (window.length > overlap) {
                NSData *tail = [window subdataWithRange:
                    NSMakeRange(window.length - overlap, overlap)];
                [window setData:tail];
            }
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(fd);
    return NO;
}

// Return an already-running instance of this exact chroot executable. App
// identity is the resolved executable path, not a display name or p_comm:
// those can collide and would make a different application steal the Scene.
// proc_pidpath may expose either the process's chroot-relative macOS path or
// the iOS host path, depending on which kernel image supplied the caller.
static pid_t FindRunningRootExecutable(NSString *rootPath) {
    if (!rootPath.length) return 0;
    typedef int (*MacWSProcListPIDs)(uint32_t, uint32_t, void *, int);
    typedef int (*MacWSProcPIDPath)(int, void *, uint32_t);
    static MacWSProcListPIDs procListPIDs;
    static MacWSProcPIDPath procPIDPath;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procListPIDs = (MacWSProcListPIDs)dlsym(
            RTLD_DEFAULT, "proc_listpids");
        procPIDPath = (MacWSProcPIDPath)dlsym(
            RTLD_DEFAULT, "proc_pidpath");
    });
    if (!procListPIDs || !procPIDPath) return 0;
    NSString *hostPath = [@("/var/mnt/rootfs")
        stringByAppendingString:rootPath];
    char canonicalHostPath[PATH_MAX] = {0};
    if (realpath(hostPath.fileSystemRepresentation, canonicalHostPath)) {
        hostPath = [NSString stringWithUTF8String:canonicalHostPath];
    }
    const uint32_t allPIDs = 1; // PROC_ALL_PIDS from Darwin libproc.h
    int capacity = procListPIDs(allPIDs, 0, NULL, 0);
    if (capacity <= 0) return 0;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return 0;
    int bytes = procListPIDs(allPIDs, 0, pids, capacity);
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    pid_t found = 0;
    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) continue;
        char processPath[4096] = {0};
        if (procPIDPath(pid, processPath, sizeof(processPath)) <= 0)
            continue;
        NSString *candidate = [NSString stringWithUTF8String:processPath];
        if (![candidate isEqualToString:rootPath] &&
            ![candidate isEqualToString:hostPath]) continue;
        if (kill(pid, 0) == 0 || errno == EPERM) {
            found = pid;
            break;
        }
    }
    free(pids);
    return found;
}

// LaunchServices' authoritative running-application record does retire when a
// bridged AppKit process exits, but the macOS 13.4 Dock in this chroot does not
// receive the corresponding termination notification. Runtime evidence: after
// a clean final-window close, lsappinfo no longer listed Terminal while Dock
// kept its running dot; restarting only Dock removed it. RE evidence from the
// exact Dock binary: its state rebuild calls _LSCopyRunningApplicationArray at
// Dock+0x2a8cd4. Rebuild only after the exact target process is gone, and only
// terminate the exact Dock executable. This is deliberately a bounded
// compatibility repair for the missing notification, not an assertion that
// the native notification path is fixed.
static BOOL RefreshDockAfterProcessExit(pid_t targetPID, NSString **message) {
    if (targetPID <= 1) {
        *message = @"缺少有效的应用进程标识，Dock 未改动";
        return NO;
    }
    NSDate *exitDeadline = [NSDate dateWithTimeIntervalSinceNow:0.65];
    while (exitDeadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(targetPID, 0) != 0 && errno == ESRCH) break;
        usleep(50000);
    }
    errno = 0;
    if (kill(targetPID, 0) == 0 || errno != ESRCH) {
        HostLog(@"dock-refresh skipped target=%d reason=still-running",
                targetPID);
        *message = [NSString stringWithFormat:
            @"应用 PID %d 仍在运行，未重建 Dock 状态", targetPID];
        return YES;
    }

    NSString *dockPath =
        @"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
    pid_t oldDockPID = FindRunningRootExecutable(dockPath);
    if (oldDockPID <= 1) {
        HostLog(@"dock-refresh target=%d state=already-absent", targetPID);
        *message = @"应用已退出；Dock 当前未运行，无陈旧状态可清理";
        return YES;
    }
    HostLog(@"dock-refresh target=%d dock=%d signal=TERM", targetPID,
            oldDockPID);
    if (kill(oldDockPID, SIGTERM) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"应用已退出，但 Dock 状态重建失败（PID %d，errno=%d）",
            oldDockPID, errno];
        return NO;
    }

    NSDate *restartDeadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    pid_t newDockPID = 0;
    while (restartDeadline.timeIntervalSinceNow > 0) {
        newDockPID = FindRunningRootExecutable(dockPath);
        if (newDockPID > 1 && newDockPID != oldDockPID) break;
        usleep(50000);
    }
    if (newDockPID <= 1 || newDockPID == oldDockPID) {
        *message = [NSString stringWithFormat:
            @"应用已退出，但 Dock 未在时限内完成状态重建（旧 PID %d）",
            oldDockPID];
        return NO;
    }
    HostLog(@"dock-refresh complete target=%d old-dock=%d new-dock=%d",
            targetPID, oldDockPID, newDockPID);
    *message = @"应用已退出，Dock 运行状态已重建";
    return YES;
}

// An AppKit application can outlive its last NSWindow.  That is the normal
// result after an iPad Scene asks AppInputBridge to performClose:, but such a
// process cannot satisfy a later launch request by merely being "reused".
// Gracefully retire only the exact executable whose metrics sidecar remained
// empty for the complete WaitForWindowMetrics grace period.  This keeps the
// single-instance invariant without treating process uptime as a window.
static BOOL TerminateWindowlessRootExecutable(pid_t pid, NSString *rootPath,
                                              NSString **message) {
    if (pid <= 1 || !rootPath.length) return NO;
    HostLog(@"launch-app windowless-retire pid=%d executable=%@ signal=TERM",
            pid, rootPath);
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"无窗口实例无法正常退出（PID %d，errno=%d）", pid, errno];
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) {
            HostLog(@"launch-app windowless-retired pid=%d executable=%@",
                    pid, rootPath);
            return YES;
        }
        usleep(50000);
    }
    // Runtime-confirmed with Terminal on 2026-07-31 and again on 2026-08-06:
    // after its last NSWindow performed the ordinary close action, SIGTERM
    // leaves the zero-window process alive; waiting three seconds changed no
    // state and directly inflated the next launch. The app has already failed
    // its real metrics + AppKit reopen transaction before this helper runs, so
    // retain a bounded 400-ms cooperative grace and then retire that exact
    // executable. This remains a final lifecycle step, not a process-uptime
    // substitute for window health.
    HostLog(@"launch-app windowless-retire pid=%d executable=%@ signal=KILL "
            "reason=term-timeout", pid, rootPath);
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"无窗口实例无法清理（PID %d，errno=%d）", pid, errno];
        return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) {
            HostLog(@"launch-app windowless-retired pid=%d executable=%@ "
                    "after=KILL", pid, rootPath);
            return YES;
        }
        usleep(50000);
    }
    *message = [NSString stringWithFormat:
        @"无窗口实例清理超时（PID %d），未创建重复进程", pid];
    return NO;
}

// A LaunchServices session can discard its mounted Settings extension records
// while leaving the already-running SwiftUI shell alive.  Once that shell has
// cached an empty PPCenter catalog, reopening its NSWindow cannot populate the
// panes: runtime A/B on 2026-08-12 kept the old shell blank after all 48
// records verified, while retiring that exact executable and launching it
// again immediately created real Appearance/Trackpad/Mouse extension
// processes.  Retire only that identified process, with the same bounded
// cooperative grace used for a windowless application.
static BOOL RetireRootExecutableForCatalogRefresh(pid_t pid,
                                                  NSString *rootPath,
                                                  NSString **message) {
    if (pid <= 1 || !rootPath.length) return YES;
    HostLog(@"launch-app catalog-refresh-retire pid=%d executable=%@ "
            "signal=TERM", pid, rootPath);
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"设置目录已修复，但旧进程无法退出（PID %d，errno=%d）",
            pid, errno];
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) return YES;
        usleep(50000);
    }
    HostLog(@"launch-app catalog-refresh-retire pid=%d executable=%@ "
            "signal=KILL reason=term-timeout", pid, rootPath);
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"设置目录已修复，但旧进程无法清理（PID %d，errno=%d）",
            pid, errno];
        return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) return YES;
        usleep(50000);
    }
    *message = [NSString stringWithFormat:
        @"设置目录已修复，但旧进程清理超时（PID %d）", pid];
    return NO;
}

// Validate the records actually visible to the current LaunchServices
// generation immediately before launching System Settings.  The startup
// marker alone is insufficient: runtime-confirmed on 2026-08-12, the same
// session that had prepared 48/48 panes later returned an
// LSApplicationExtensionRecord with identifier=<nil>, platform=0 and url=nil.
// Re-register through stock LaunchServices only when the exact verifier fails;
// do not manufacture a pane or treat process uptime as content readiness.
static BOOL EnsureSystemSettingsCatalog(BOOL *repairedOut,
                                        NSString **message) {
    if (repairedOut) *repairedOut = NO;
    const char *verify[] = {
        kChrootExec, "0", "0", kRootFS, kWorkspaceCtl,
        "verify-launchservices-catalog", NULL,
    };
    int verifyResult = RunCommand(verify, YES);
    if (verifyResult == 0) {
        HostLog(@"system-settings catalog result=verified action=reuse");
        return YES;
    }

    static const char *const registrationEnvironment[] = {
        "MACWS_CATALOG_REGISTRATION=1",
    };
    char **environment = CopyEnvironmentAdding(
        registrationEnvironment,
        sizeof(registrationEnvironment) /
            sizeof(registrationEnvironment[0]));
    if (!environment) {
        *message = @"无法构造系统设置目录修复环境";
        return NO;
    }
    const char *repairCatalog[] = {
        kChrootExec, "0", "0", kRootFS, kWorkspaceCtl,
        "repair-launchservices-catalog", NULL,
    };
    int repairResult = RunCommandWithEnvironment(
        repairCatalog, environment, YES);
    FreeCopiedEnvironment(environment);
    int repairedVerifyResult = repairResult == 0
        ? RunCommand(verify, YES) : 126;
    HostLog(@"system-settings catalog result=%s initial_verify=%d "
            "repair=%d final_verify=%d",
            repairedVerifyResult == 0 ? "repaired" : "failed",
            verifyResult, repairResult, repairedVerifyResult);
    if (repairedVerifyResult != 0) {
        *message = [NSString stringWithFormat:
            @"系统设置目录修复失败（验证 %d，修复 %d，复验 %d）",
            verifyResult, repairResult, repairedVerifyResult];
        return NO;
    }
    if (repairedOut) *repairedOut = YES;
    return YES;
}

static pid_t WaitForRunningRootExecutable(NSString *rootPath,
                                          NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        pid_t pid = FindRunningRootExecutable(rootPath);
        if (pid > 1) return pid;
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    return 0;
}

static BOOL MapsHostCarrierMarkerMatches(pid_t pid) {
    char value[32] = {0};
    int fd = open(kMapsHostCarrierMarker, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    int markerPID = 0;
    return count > 0 && sscanf(value, "%d", &markerPID) == 1 &&
        markerPID == pid && pid > 1;
}

static BOOL CatalystChildMarkerMatches(pid_t pid, const char *rootExecutable,
                                       const char *bundleIdentifier) {
    if (pid <= 1 || !rootExecutable || !bundleIdentifier) return NO;
    char markerPath[PATH_MAX] = {0};
    int length = snprintf(
        markerPath, sizeof(markerPath),
        "/var/mnt/rootfs/private/tmp/macws_catalyst_child.%d.info", pid);
    if (length <= 0 || (size_t)length >= sizeof(markerPath)) return NO;
    int fd = open(markerPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat status = {0};
    char payload[PATH_MAX + 512] = {0};
    ssize_t count = read(fd, payload, sizeof(payload) - 1);
    int statusResult = fstat(fd, &status);
    close(fd);
    if (count <= 0 || (size_t)count >= sizeof(payload) ||
        statusResult != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != 0 || (status.st_mode & 022) != 0 ||
        status.st_nlink != 1) return NO;
    payload[count] = '\0';
    NSString *expected = [NSString stringWithFormat:@"v1\n%s\n%s\n",
                          rootExecutable, bundleIdentifier];
    return strcmp(payload, expected.UTF8String) == 0;
}

static BOOL WriteCatalystLaunchRequest(const char *rootExecutable,
                                       const char *bundleIdentifier,
                                       const char *containerHome,
                                       NSString **message) {
    NSDictionary *request = @{
        @"root_executable": @(rootExecutable),
        @"bundle_identifier": @(bundleIdentifier),
        @"container_home": @(containerHome),
    };
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:request
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    if (!data) {
        *message = [NSString stringWithFormat:
            @"无法构造 Catalyst 启动请求：%@",
            serializationError.localizedDescription ?: @"未知错误"];
        return NO;
    }
    char temporaryPath[PATH_MAX] = {0};
    int length = snprintf(temporaryPath, sizeof(temporaryPath),
                          "%s.new.%d", kCatalystRequestPath, getpid());
    if (length <= 0 || (size_t)length >= sizeof(temporaryPath)) {
        *message = @"Catalyst 启动请求路径过长";
        return NO;
    }
    unlink(temporaryPath);
    int fd = open(temporaryPath,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                  0600);
    if (fd < 0) {
        *message = [NSString stringWithFormat:
            @"无法创建 Catalyst 启动请求（errno=%d）", errno];
        return NO;
    }
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    BOOL written = YES;
    while (remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            written = NO;
            break;
        }
        cursor += count;
        remaining -= (size_t)count;
    }
    if (written && fsync(fd) != 0) written = NO;
    if (close(fd) != 0) written = NO;
    if (!written || rename(temporaryPath, kCatalystRequestPath) != 0) {
        int savedError = errno;
        unlink(temporaryPath);
        *message = [NSString stringWithFormat:
            @"无法发布 Catalyst 启动请求（errno=%d）", savedError];
        return NO;
    }
    return YES;
}

static void RetireLegacyMapsUIKitCarrier(void) {
    // The pre-fullscreen architecture foregrounded this UIApplication and
    // kept its empty UIWindowScene alive after Maps exited.  A process whose
    // executable is still MacWSCatalystLauncher is necessarily that legacy
    // UI carrier: the new helper replaces itself with launchdchrootexec before
    // Maps starts.  Retire it before notifying the foreground Host so the
    // user cannot inherit the old black iPadOS window after an upgrade.
    const char *retire[] = {
        kKillall, "-TERM", "MacWSCatalystLauncher", NULL,
    };
    int result = RunCommand(retire, YES);
    HostLog(@"maps legacy-ui-carrier retire result=%d", result);
}

// Maps is a Mac Catalyst application. MacWSHost is already the foreground
// UIApplication and owns the user's fullscreen scene. Ask that existing Host
// to spawn a setuid helper which immediately execs Maps as its direct child.
// This preserves the valid UIKit/FrontBoard responsible-process ancestry
// without ever foregrounding the old empty MacWSCatalystLauncher UIWindowScene.
static BOOL LaunchMapsViaUIKitCarrier(NSString **message) {
    NSString *mapsRootPath = @(kMapsExecutable);
    NSString *mapsHostPath = [@("/var/mnt/rootfs")
        stringByAppendingString:mapsRootPath];
    if (access(mapsHostPath.fileSystemRepresentation, X_OK) != 0 ||
        access(kUIKitSystemPlist, R_OK) != 0) {
        *message = @"Maps 的 Catalyst 启动组件不完整，请先修复环境";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    RetireLegacyMapsUIKitCarrier();

    pid_t uikitSystemPID = FindRunningRootExecutable(
        @(kUIKitSystemExecutable));
    if (uikitSystemPID <= 1) {
        const char *loadUIKitSystem[] = {
            kLaunchctl, "load", kUIKitSystemPlist, NULL,
        };
        const char *kickstartUIKitSystem[] = {
            kLaunchctl, "kickstart", "-k",
            "user/501/com.apple.uikitsystemapp", NULL,
        };
        (void)RunCommand(loadUIKitSystem, YES);
        (void)RunCommand(kickstartUIKitSystem, YES);
        uikitSystemPID = WaitForRunningRootExecutable(
            @(kUIKitSystemExecutable), 8.0);
        if (uikitSystemPID <= 1) {
            *message = @"UIKitSystem 未能完成 Catalyst 场景服务启动";
            return NO;
        }
    }

    pid_t mapsPID = FindRunningRootExecutable(mapsRootPath);
    BOOL freshHostChild = MapsHostCarrierMarkerMatches(mapsPID);
    if (mapsPID > 1 && !freshHostChild) {
        // A previously published Catalyst scene may be reopened in place.
        // If it is a stale windowless generation, retire it before asking the
        // live Host for one new exact process generation.
        if (RequestApplicationReopen(mapsPID, 8.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = mapsPID;
            gActiveAppID = @"maps";
            os_unfair_lock_unlock(&gStateLock);
            HostLog(@"launch-app reuse id=maps pid=%d route=existing-window",
                    mapsPID);
            *message = @"地图已在运行，现有原生窗口已进入窗口列表";
            return YES;
        }
        if (!TerminateWindowlessRootExecutable(
                mapsPID, mapsRootPath, message)) return NO;
        mapsPID = 0;
    }
    if (mapsPID <= 1) {
        unlink(kMapsHostCarrierMarker);
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kMapsHostLaunchNotification, NULL, NULL, true);
        mapsPID = WaitForRunningRootExecutable(mapsRootPath, 3.0);
        freshHostChild = MapsHostCarrierMarkerMatches(mapsPID);
    }
    if (mapsPID <= 1) {
        *message = @"MacWSHost 未能从当前工作区启动地图；没有创建黑色 UIKit 载体窗口";
        return NO;
    }
    if (!freshHostChild) {
        *message = @"地图进程没有匹配当前 MacWSHost 的启动代次，已拒绝创建额外 iOS 场景";
        return NO;
    }
    // Do not synchronously wait up to 30 seconds for a Catalyst window here.
    // The foreground Host already owns the DisplayStream catalog and can
    // observe the exact (PID, window ID) publication without polling.  Return
    // the responsible process immediately so its generic pending-window
    // transaction can stabilize and activate that native window while input
    // and the control center remain responsive.
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = mapsPID;
    gActiveAppID = @"maps";
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"launch-app process-ready id=maps pid=%d uikitsystem=%d "
            "route=existing-MacWSHost catalog=asynchronous", mapsPID,
            uikitSystemPID);
    *message = @"地图正在当前工作区打开，未创建新的 iPadOS 窗口";
    return YES;
}

// Asphalt is the first third-party Catalyst control-center target. Its
// executable, bundle identity and container are an exact allowlist entry;
// macwshostd publishes one root-owned request and the already-foreground
// MacWSHost creates the responsible-process child. The container is owned by
// the iPadOS login uid (501), matching a normal Catalyst application and its
// Data Protection Keychain session. This is the same upstream
// UIKit/FrontBoard ancestry that runtime-confirmed the native AGX drawable,
// not a bare chroot spawn or a second black UIKit scene.
static BOOL LaunchAsphaltViaUIKitCarrier(NSString **message) {
    NSString *rootPath = @(kAsphaltExecutable);
    NSString *hostPath = [@(kRootFS) stringByAppendingString:rootPath];
    NSString *hostContainer = [@(kRootFS)
        stringByAppendingString:@"/Users/mobile/Library/Containers/com.gameloft.asphalt9mac/Data"];
    struct stat containerStatus = {0};
    if (!HasExecutableFileMode(hostPath.fileSystemRepresentation) ||
        stat(hostContainer.fileSystemRepresentation, &containerStatus) != 0 ||
        !S_ISDIR(containerStatus.st_mode) ||
        access(kUIKitSystemPlist, R_OK) != 0) {
        *message = @"Asphalt 的可执行文件、容器或 Catalyst 服务不完整";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    pid_t uikitSystemPID = FindRunningRootExecutable(
        @(kUIKitSystemExecutable));
    if (uikitSystemPID <= 1) {
        const char *loadUIKitSystem[] = {
            kLaunchctl, "load", kUIKitSystemPlist, NULL,
        };
        const char *kickstartUIKitSystem[] = {
            kLaunchctl, "kickstart", "-k",
            "user/501/com.apple.uikitsystemapp", NULL,
        };
        (void)RunCommand(loadUIKitSystem, YES);
        (void)RunCommand(kickstartUIKitSystem, YES);
        uikitSystemPID = WaitForRunningRootExecutable(
            @(kUIKitSystemExecutable), 8.0);
        if (uikitSystemPID <= 1) {
            *message = @"UIKitSystem 未能完成 Asphalt 场景服务启动";
            return NO;
        }
    }

    pid_t asphaltPID = FindRunningRootExecutable(rootPath);
    if (asphaltPID > 1) {
        BOOL exactCarrier = CatalystChildMarkerMatches(
            asphaltPID, kAsphaltExecutable, kAsphaltBundleIdentifier);
        if (exactCarrier && RequestApplicationReopen(asphaltPID, 8.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = asphaltPID;
            gActiveAppID = @"asphalt";
            os_unfair_lock_unlock(&gStateLock);
            *message = @"Asphalt 已在当前 MacWSHost 工作区运行";
            return YES;
        }
        if (!TerminateWindowlessRootExecutable(asphaltPID, rootPath, message))
            return NO;
    }

    RetireLegacyMapsUIKitCarrier();
    if (!WriteCatalystLaunchRequest(
            kAsphaltExecutable, kAsphaltBundleIdentifier,
            kAsphaltContainerHome, message)) return NO;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kCatalystHostLaunchNotification, NULL, NULL, true);
    asphaltPID = WaitForRunningRootExecutable(rootPath, 5.0);
    unlink(kCatalystRequestPath);
    if (asphaltPID <= 1) {
        *message = @"MacWSHost 未能在当前工作区启动 Asphalt";
        return NO;
    }
    if (!CatalystChildMarkerMatches(
            asphaltPID, kAsphaltExecutable, kAsphaltBundleIdentifier)) {
        NSString *retireMessage = nil;
        (void)TerminateWindowlessRootExecutable(
            asphaltPID, rootPath, &retireMessage);
        *message = @"Asphalt 进程缺少匹配的 Host Catalyst 身份，已拒绝";
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = asphaltPID;
    gActiveAppID = @"asphalt";
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"launch-app process-ready id=asphalt pid=%d uikitsystem=%d "
            "route=existing-MacWSHost catalog=asynchronous",
            asphaltPID, uikitSystemPID);
    *message = @"Asphalt 正在当前工作区打开，未创建新的 iPadOS 窗口";
    return YES;
}

static BOOL LaunchVSCode(NSString **message) {
    if (access(kVSCodePlist, R_OK) != 0 ||
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
               X_OK) != 0) {
        *message = @"VS Code 或生产启动配置不存在";
        return NO;
    }
    int pid = 0;
    off_t launchLogOffset = FileSizeAtPath(kVSCodeLog);
    BOOL jobLoaded = NO;
    BOOL reusedJob = InspectJob(kVSCodeLabel, &pid, &jobLoaded);
    if (!reusedJob) {
        // A one-shot launchd job can remain loaded with no PID after Electron
        // exits. Treat that state separately from a genuinely absent job: the
        // former needs `start`, while the latter needs `load` immediately.
        const char *startArgv[] = {kLaunchctl, "start", kVSCodeLabel, NULL};
        const char *loadArgv[] = {kLaunchctl, "load", kVSCodePlist, NULL};
        int loadResult = 0;
        if (jobLoaded) {
            (void)RunCommand(startArgv, YES);
            (void)WaitForJobPID(kVSCodeLabel, 2.0, &pid);
        } else {
            // Runtime-confirmed on 2026-08-02: after an ordinary unload the
            // former start-first path waited its entire two-second dormant-job
            // grace even though `launchctl list` had already established that
            // the label did not exist. Load an absent job immediately; retain
            // start-first only for the distinct loaded-without-PID state.
            loadResult = RunCommand(loadArgv, YES);
            (void)WaitForJobPID(kVSCodeLabel, 3.0, &pid);
        }
        if (pid <= 1) {
            if (jobLoaded)
                loadResult = RunCommand(loadArgv, YES);
            if (!WaitForJobPID(kVSCodeLabel, 3.0, &pid)) {
                // A loaded-but-damaged definition did not respond to start and
                // also rejected load. Refresh that exact production plist;
                // never use a bare Electron spawn with a different environment.
                HostLog(@"launch-app vscode-refresh-job start/load result=%d",
                        loadResult);
                const char *unloadArgv[] = {
                    kLaunchctl, "unload", kVSCodePlist, NULL};
                (void)RunCommand(unloadArgv, YES);
                launchLogOffset = FileSizeAtPath(kVSCodeLog);
                if (RunCommand(loadArgv, YES) != 0)
                    pid = 0;
                else
                    (void)WaitForJobPID(kVSCodeLabel, 10.0, &pid);
            }
        }
    }
    if (pid <= 1) {
        *message = @"VS Code 生产任务未取得进程";
        return NO;
    }
    if (!reusedJob) WriteVSCodeHealthMarker(pid, launchLogOffset);
    if (reusedJob) {
        int reuseExitStatus = -1;
        uint32_t workspaceFlags = MacWSStreamWindowVisible |
                                  MacWSStreamWindowResizable;
        pid_t markerPID = 0;
        off_t markerOffset = 0;
        BOOL markerMatches = ReadVSCodeHealthMarker(&markerPID, &markerOffset) &&
                             markerPID == pid;
        BOOL electronUnresponsive = markerMatches &&
            VSCodeLogContainsUnresponsiveAfter(markerOffset);
        BOOL workspaceReady = WaitForWindowMetricsFlags(
            pid, 3.0, workspaceFlags, &reuseExitStatus);
        if (!markerMatches)
            WriteVSCodeHealthMarker(pid, FileSizeAtPath(kVSCodeLog));
        if (!workspaceReady || electronUnresponsive) {
            // Runtime-confirmed on 2026-07-31: Electron logged
            // `CodeWindow: detected unresponsive`; its metrics sidecar then
            // continued to describe a visible/resizable base NSWindow under
            // the recovery sheet. Window geometry therefore cannot establish
            // renderer health. Use Electron's exact per-launch health witness;
            // the production launchd job remains the restart boundary.
            HostLog(@"launch-app vscode-restart pid=%d "
                    "reason=%@", pid,
                    electronUnresponsive ? @"electron-unresponsive" :
                                           @"no-resizable-workspace");
            const char *unloadArgv[] = {kLaunchctl, "unload", kVSCodePlist, NULL};
            (void)RunCommand(unloadArgv, YES);
            launchLogOffset = FileSizeAtPath(kVSCodeLog);
            const char *loadArgv[] = {kLaunchctl, "load", kVSCodePlist, NULL};
            if (RunCommand(loadArgv, YES) != 0) {
                *message = @"VS Code 无响应实例已停止，但生产任务重启失败";
                return NO;
            }
            pid = 0;
            (void)WaitForJobPID(kVSCodeLabel, 15.0, &pid);
            if (pid <= 1) {
                *message = @"VS Code 生产任务重启后未取得进程";
                return NO;
            }
            WriteVSCodeHealthMarker(pid, launchLogOffset);
        }
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = @"vscode";
    os_unfair_lock_unlock(&gStateLock);
    int exitStatus = -1;
    if (!WaitForWindowMetricsFlags(pid, 30.0,
            MacWSStreamWindowVisible | MacWSStreamWindowResizable,
            &exitStatus)) {
        *message = @"VS Code 正在运行，但 30 秒内没有发布可调尺寸的工作区窗口";
        return NO;
    }
    HostLog(@"launch-app window-ready id=vscode pid=%d path=DisplayStream", pid);
    *message = @"VS Code 已通过生产 AGX/JIT 配置启动，窗口已进入列表";
    return YES;
}

static BOOL LaunchRootExecutable(const char *identifier,
                                 NSString *rootPath,
                                 const char *logPath,
                                 NSTimeInterval timeout,
                                 NSString **message) {
    NSString *hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    // access(X_OK) asks iPadOS whether this foreign-platform Mach-O may be
    // executed directly in the caller's native context.  AMFI correctly
    // answers EPERM for Finder even though launchdchrootexec can admit the
    // trusted image after entering the macOS root.  Validate the filesystem
    // invariant here; the real chroot launch remains the admission witness.
    if (!HasExecutableFileMode(hostPath.fileSystemRepresentation)) {
        *message = [NSString stringWithFormat:@"应用不存在或不可执行: %@",
                    rootPath];
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL)) {
        *message = @"请先启动 macOS GUI";
        return NO;
    }


    pid_t existingPID = FindRunningRootExecutable(rootPath);
    if (existingPID > 1) {
        int exitStatus = -1;
        BOOL finder = strcmp(identifier, "finder") == 0;
        BOOL reopenLifecycle = strcmp(identifier, "system-settings") == 0 ||
                               strcmp(identifier, "maps") == 0;
        // System Settings and Maps own native reopen lifecycles.  Their
        // metrics sidecar may describe a window that has since closed if the
        // application main queue stopped publishing.  Require a fresh
        // generation produced after the exact reopen request; PID uptime or a
        // stale Visible bit is not a launch-success witness.
        // A current visible metrics entry is an immediate reuse witness; a
        // generic AppKit process with zero windows must receive the same real
        // reopen lifecycle as a Dock/open request before it is discarded.
        // Runtime-confirmed with Terminal pid 99506 on 2026-08-06: the app was
        // healthy and idle in NSApplication.run with a live AppInput endpoint,
        // and one ReopenApplication record published its normal Terminal
        // window. The old three-second metrics-only wait could never change a
        // windowless process and was followed by another three-second TERM
        // timeout. Use that upstream lifecycle for every ordinary AppKit app;
        // Finder retains its native Command-N browser transaction below.
        BOOL existingWindow = reopenLifecycle
            ? RequestApplicationReopen(existingPID, 8.0)
            : WaitForWindowMetrics(existingPID, 0.15, &exitStatus);
        if (existingWindow && strcmp(identifier, "system-settings") == 0)
            existingWindow = WaitForSystemSettingsContent(12.0);
        if (!existingWindow && finder)
            existingWindow = RequestFinderBrowserWindow(existingPID, 8.0);
        if (!existingWindow && !finder && !reopenLifecycle)
            // Runtime-confirmed on Terminal pid 14367 (2026-08-06): a
            // successful AppKit reopen publishes its window metrics within
            // 400 ms.  A zero-window instance that has not answered after one
            // second never answered during the old 2.5-second grace either;
            // the additional wait only delayed the replacement launch.
            existingWindow = RequestApplicationReopen(existingPID, 1.0);
        if (!existingWindow) {
            // Runtime-confirmed on the default Terminal bootstrap: closing
            // its last represented iPad Scene leaves a healthy process with
            // a valid zero-entry metrics header. Reusing that process can
            // never produce a Scene; spawning beside it violates the user's
            // one-application-instance model. Retire the windowless instance
            // first, then continue through the ordinary launch path below.
            if (!TerminateWindowlessRootExecutable(existingPID, rootPath,
                                                    message))
                return NO;
            existingPID = 0;
        } else {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = existingPID;
            gActiveAppID = [@(identifier) copy];
            os_unfair_lock_unlock(&gStateLock);
            HostLog(@"launch-app reuse id=%s pid=%d executable=%@ "
                    "identity=proc_pidpath",
                    identifier, existingPID, rootPath);
            *message = [NSString stringWithFormat:
                @"%s 已在运行，正在打开现有窗口", identifier];
            return YES;
        }
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    const char *rootExecutable = rootPath.fileSystemRepresentation;
    const char *ordinaryArgv[] = {kChrootExec, "0", "0", kRootFS,
                                  rootExecutable, NULL};
    const char *cleanStateArgv[] = {kChrootExec, "0", "0", kRootFS,
        rootExecutable, "-ApplePersistenceIgnoreState", "YES", NULL};
    BOOL cleanState = strcmp(identifier, "terminal") == 0 ||
                      strcmp(identifier, "finder") == 0;
    const char *const *argv = cleanState ? cleanStateArgv : ordinaryArgv;
    // Runtime-confirmed on 2026-08-02: Terminal's ordinary launch restored
    // two historical windows/tabs (including diagnostic text) and needed
    // 3.30 s to publish a usable window. With AppKit's persistence override it
    // published one clean window in 1.50 s. Finder likewise accumulated one
    // restored browser per prior test launch. Start both user-facing shell
    // apps cleanly; this changes their launch transaction upstream and does
    // not hide extra catalog entries or relax the real-window witness below.
    pid_t pid = 0;
    char **childEnvironment = environ;
    char **ownedEnvironment = NULL;
    if (strcmp(identifier, "glassdemo") == 0) {
        static const char *const nativeAGXEnvironment[] = {
            "MACWS_AGX_NATIVE=1",
            "MACWS_AGX_REGISTER_CLASSES=1",
            "MACWS_PIN_FALLBACK=1",
        };
        ownedEnvironment = CopyEnvironmentAdding(
            nativeAGXEnvironment,
            sizeof(nativeAGXEnvironment) /
                sizeof(nativeAGXEnvironment[0]));
        if (!ownedEnvironment) {
            posix_spawn_file_actions_destroy(&actions);
            if (logFD >= 0) close(logFD);
            *message = @"无法为 GlassDemo 构造 native AGX 启动环境";
            return NO;
        }
        childEnvironment = ownedEnvironment;
    } else if (strcmp(identifier, "activity-monitor") == 0 ||
               strcmp(identifier, "custom-path") == 0 ||
               IsThirdPartyAppIdentifier(identifier)) {
        // Runtime-confirmed by Amadine-2026-08-11-141854.ips: creating a
        // document made AppKit resolve a NIB image through NSWorkspace, which
        // dispatched LaunchServices bundle registration and recursively
        // finalized 511 CoreServicesInternal FileCache/CFURL frames when the
        // host mount escaped the chroot.  A controlled A/B with the complete
        // logical-root namespace produced the real canvas and no new crash.
        // Activity Monitor reaches the same root invariant while resolving a
        // sampled process icon: runtime-confirmed by
        // Activity Monitor-2026-08-12-010001.ips, whose crashing thread enters
        // NSWorkspace iconForFile: -> _LSFindOrRegisterBundleNode -> NSURL
        // bookmarkData -> CoreServicesInternal FileCache recursion until the
        // stack guard fires. Scope the filesystem contract to these proven
        // consumers; ordinary Terminal/Finder keep their separately proven
        // fork/catalog policies.
        static const char *const thirdPartyEnvironment[] = {
            "MACWS_APP_MOUNT_COMPAT=1",
        };
        ownedEnvironment = CopyEnvironmentAdding(
            thirdPartyEnvironment,
            sizeof(thirdPartyEnvironment) /
                sizeof(thirdPartyEnvironment[0]));
        if (!ownedEnvironment) {
            posix_spawn_file_actions_destroy(&actions);
            if (logFD >= 0) close(logFD);
            *message = @"无法为应用构造 chroot 根卷环境";
            return NO;
        }
        childEnvironment = ownedEnvironment;
    }
    int error = SpawnMacOSApplication(
        &pid, kChrootExec, &actions, (char *const *)argv, childEnvironment);
    FreeCopiedEnvironment(ownedEnvironment);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (error != 0) {
        *message = [NSString stringWithFormat:@"拉起应用失败: %s", strerror(error)];
        return NO;
    }
    HostLog(@"launch-app id=%s pid=%d executable=%@", identifier, pid,
            rootPath);
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = [@(identifier) copy];
    os_unfair_lock_unlock(&gStateLock);
    if (JobHasPID(kDisplayLabel, NULL)) {
        int exitStatus = -1;
        BOOL finder = strcmp(identifier, "finder") == 0;
        BOOL reopenLifecycle = strcmp(identifier, "system-settings") == 0 ||
                               strcmp(identifier, "maps") == 0;
        BOOL customPath = strcmp(identifier, "custom-path") == 0 ||
                          IsThirdPartyAppIdentifier(identifier);
        BOOL windowReady = NO;
        if (finder) {
            windowReady = RequestFinderBrowserWindow(pid, timeout);
        } else if (reopenLifecycle) {
            windowReady = RequestApplicationReopen(pid, timeout);
        } else if (customPath) {
            // Runtime-confirmed with Amadine pid 60156/60398 on 2026-08-11:
            // the application remained healthy with a live AppInput endpoint,
            // while its valid metrics catalog stayed at entryCount=0 for more
            // than one minute.  A bare executable launch has no LaunchServices
            // AppleEvent to perform the ordinary Dock/open lifecycle.  Give a
            // third-party app a short chance to publish its initial NSWindow,
            // then deliver the real NSApplication reopen inside that owning
            // process.  This is the same generic lifecycle used when reusing a
            // windowless process above, not an app-name exception or a
            // synthetic window-success witness.
            NSTimeInterval initialWindowTimeout = MIN(timeout, 3.0);
            windowReady = WaitForWindowMetrics(
                pid, initialWindowTimeout, &exitStatus);
            if (!windowReady && exitStatus < 0) {
                windowReady = RequestApplicationReopen(
                    pid, MAX(1.0, timeout - initialWindowTimeout));
            }
        } else {
            windowReady = WaitForWindowMetrics(pid, timeout, &exitStatus);
        }
        if (windowReady && strcmp(identifier, "system-settings") == 0)
            windowReady = WaitForSystemSettingsContent(12.0);
        if (!windowReady) {
            os_unfair_lock_lock(&gStateLock);
            if (gActiveAppPID == pid) {
                gActiveAppPID = 0;
                gActiveAppID = @"";
            }
            os_unfair_lock_unlock(&gStateLock);
            if (exitStatus >= 0 && WIFEXITED(exitStatus)) {
                *message = [NSString stringWithFormat:
                    @"%s 在发布 AppKit 窗口前退出（状态 %d）",
                    identifier, WEXITSTATUS(exitStatus)];
            } else if (exitStatus >= 0 && WIFSIGNALED(exitStatus)) {
                *message = [NSString stringWithFormat:
                    @"%s 在发布 AppKit 窗口前被信号 %d 终止",
                    identifier, WTERMSIG(exitStatus)];
            } else {
                *message = [NSString stringWithFormat:
                    @"%s 已启动，但 %.0f 秒内没有发布可捕获的 AppKit 窗口",
                    identifier, timeout];
            }
            BeginApplicationChildReaper(pid, @(identifier));
            return NO;
        }
        HostLog(@"launch-app window-ready id=%s pid=%d path=DisplayStream",
                identifier, pid);
    } else {
        *message = @"DisplayStream 服务未运行";
        BeginApplicationChildReaper(pid, @(identifier));
        return NO;
    }
    BeginApplicationChildReaper(pid, @(identifier));
    return YES;
}

static NSString *ResolveExecutableRootPath(const char *requestedPath,
                                           NSString **errorOut) {
    if (!requestedPath || requestedPath[0] != '/' ||
        strlen(requestedPath) >= PATH_MAX) {
        if (errorOut) *errorOut = @"请输入 macOS 绝对路径";
        return nil;
    }
    NSString *rootPath = [@(requestedPath) stringByStandardizingPath];
    NSString *hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:hostPath
                                            isDirectory:&directory]) {
        if (errorOut) *errorOut = @"路径不存在";
        return nil;
    }
    if (directory) {
        NSString *plistPath = [hostPath stringByAppendingPathComponent:
            @"Contents/Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *executable = plist[@"CFBundleExecutable"];
        if (!executable.length) {
            if (errorOut) *errorOut = @"该目录不是可启动的 macOS App";
            return nil;
        }
        rootPath = [[rootPath stringByAppendingPathComponent:@"Contents/MacOS"]
            stringByAppendingPathComponent:executable];
        hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    }
    char resolvedRoot[PATH_MAX] = {0};
    char resolved[PATH_MAX] = {0};
    if (!realpath("/var/mnt/rootfs", resolvedRoot)) {
        HostLog(@"launch-path reject stage=root-realpath errno=%d (%s)",
                errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    if (!realpath(hostPath.fileSystemRepresentation, resolved)) {
        HostLog(@"launch-path reject stage=target-realpath path=%@ errno=%d (%s)",
                hostPath, errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    size_t rootLength = strlen(resolvedRoot);
    // iPadOS canonicalizes /var to /private/var.  Compare two canonical paths
    // and require a component boundary: the old literal-prefix check rejected
    // every valid app, while a boundary-less prefix would admit sibling paths
    // such as /private/var/mnt/rootfs-escape.
    struct stat executableStatus = {0};
    BOOL executableFile = stat(resolved, &executableStatus) == 0 &&
        S_ISREG(executableStatus.st_mode) &&
        (executableStatus.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
    if (strncmp(resolved, resolvedRoot, rootLength) != 0 ||
        resolved[rootLength] != '/' || !executableFile) {
        HostLog(@"launch-path reject stage=boundary-or-mode root=%s "
                "target=%s boundary=%d mode=%#o errno=%d (%s)",
                resolvedRoot, resolved, (int)(unsigned char)resolved[rootLength],
                executableStatus.st_mode, errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    HostLog(@"launch-path accepted requested=%s executable=%s",
            requestedPath, resolved + rootLength);
    return [NSString stringWithUTF8String:resolved + rootLength];
}

static BOOL LaunchAllowedApp(const char *identifier, NSString **message);

static BOOL LaunchRequestedPath(const char *requestedPath, NSString **message) {
    NSString *error = nil;
    NSString *rootPath = ResolveExecutableRootPath(requestedPath, &error);
    if (!rootPath) {
        *message = error ?: @"无法解析路径";
        return NO;
    }
    // A Dock tile and Control Center must enter the same application launch
    // transaction.  Preserve the special lifecycle already proven for Maps,
    // VS Code, System Settings, Finder and the other packaged apps instead of
    // reducing a resolved bundle URL to a bare generic exec.
    if ([rootPath isEqualToString:@(kVSCodeExecutable)] ||
        [rootPath isEqualToString:@(kVSCodeBundleExecutable)])
        return LaunchAllowedApp("vscode", message);
    if ([rootPath isEqualToString:@(kAsphaltExecutable)])
        return LaunchAllowedApp("asphalt", message);
    for (NSUInteger index = 0;
         index < sizeof(kAllowedApps) / sizeof(kAllowedApps[0]); index++) {
        if ([rootPath isEqualToString:@(kAllowedApps[index].rootPath)])
            return LaunchAllowedApp(kAllowedApps[index].identifier, message);
    }
    return LaunchRootExecutable("custom-path", rootPath,
        "/var/mobile/Library/Logs/CustomApp.host.log", 30.0, message);
}

static BOOL LaunchAllowedApp(const char *identifier, NSString **message) {
    if (identifier && strcmp(identifier, "vscode") == 0)
        return LaunchVSCode(message);
    if (identifier && strcmp(identifier, "maps") == 0)
        return LaunchMapsViaUIKitCarrier(message);
    if (identifier && strcmp(identifier, "asphalt") == 0)
        return LaunchAsphaltViaUIKitCarrier(message);
    const AllowedApp *app = NULL;
    for (NSUInteger i = 0; i < sizeof(kAllowedApps) / sizeof(kAllowedApps[0]); i++) {
        if (identifier && strcmp(identifier, kAllowedApps[i].identifier) == 0) {
            app = &kAllowedApps[i];
            break;
        }
    }
    if (!app) {
        *message = @"应用标识不在白名单中";
        return NO;
    }
    if (strcmp(identifier, "system-settings") == 0) {
        BOOL repaired = NO;
        if (!EnsureSystemSettingsCatalog(&repaired, message)) return NO;
        if (repaired) {
            NSString *rootPath = @(app->rootPath);
            pid_t cachedPID = FindRunningRootExecutable(rootPath);
            if (!RetireRootExecutableForCatalogRefresh(
                    cachedPID, rootPath, message)) return NO;
        }
    }
    if (!LaunchRootExecutable(identifier, @(app->rootPath), app->logPath,
                              30.0, message)) return NO;
    if (strcmp(identifier, "glassdemo") == 0) {
        *message = @"GlassDemo 窗口已就绪；从窗口列表打开后即可直接触控";
    } else {
        *message = [NSString stringWithFormat:
            @"已启动 %s，AppKit 窗口已进入 DisplayStream 列表", identifier];
    }
    return YES;
}

static void ServeRequest(xpc_object_t request) {
    if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
    const char *op = xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_OP);
    if (!op) {
        ReplyResult(request, NO, @"缺少操作类型", nil);
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_STATUS) == 0) {
        ReplyResult(request, YES, @"状态已刷新", ^(xpc_object_t reply) { AddStatus(reply); });
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_LOGS) == 0) {
        ReplyResult(request, YES, @"日志已刷新", ^(xpc_object_t reply) {
            SetString(reply, "hostd_log", TailFile(kLogPath, 32768));
            SetString(reply, "windowserver_log", TailFile("/var/jb/var/mobile/WindowServer.err", 32768));
            SetString(reply, "input_log", TailFile("/var/jb/var/mobile/macwsinputd.err", 16384));
            SetString(reply, "postinst_log", TailFile("/var/jb/var/mobile/postinst.log", 16384));
        });
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_RESOLVE_HOST) == 0) {
        ReplyHostResolution(request);
        return;
    }

    dispatch_async(gControlQueue, ^{
        os_unfair_lock_lock(&gStateLock);
        BOOL alreadyBusy = gBusy;
        if (!alreadyBusy) gBusy = YES;
        os_unfair_lock_unlock(&gStateLock);
        if (alreadyBusy) {
            ReplyResult(request, NO, @"另一项系统操作正在执行", ^(xpc_object_t reply) { AddStatus(reply); });
            return;
        }

        NSString *message = @"不支持的操作";
        BOOL ok = NO;
        pid_t launchedAppPID = 0;
        if (strcmp(op, MACWS_CONTROL_OP_START) == 0) {
            BOOL experimental = xpc_dictionary_get_bool(request, MACWS_CONTROL_KEY_EXPERIMENTAL);
            ok = StartGUI(experimental, &message);
        } else if (strcmp(op, MACWS_CONTROL_OP_STOP) == 0) {
            SetState(YES, @"停止 macOS GUI…", @"");
            ok = StopGUI(&message);
        } else if (strcmp(op, MACWS_CONTROL_OP_REPAIR) == 0) {
            SetState(YES, @"停止工作区并修复启动环境…", @"");
            if (JobHasPID(kWindowServerLabel, NULL)) {
                NSString *stopMessage = nil;
                if (!StopGUI(&stopMessage)) {
                    message = [NSString stringWithFormat:@"修复前无法安全停止工作区：%@",
                               stopMessage ?: @"未知错误"];
                    SetState(NO, @"操作失败", message);
                    ReplyResult(request, NO, message,
                                ^(xpc_object_t reply) { AddStatus(reply); });
                    return;
                }
            }
            SetState(YES, @"重新签名并恢复信任缓存…", @"");
            const char *argv[] = {kBash, kPostinst, NULL};
            int rc = access(kPostinst, R_OK) == 0 ? RunCommand(argv, YES) : 127;
            ok = rc == 0;
            message = ok ? @"启动环境修复完成" :
                [NSString stringWithFormat:@"环境修复失败（退出码 %d）", rc];
        } else if (strcmp(op, MACWS_CONTROL_OP_RECOVER) == 0) {
            SetState(YES, @"执行安全恢复…", @"");
            ok = StopGUI(&message);
        } else if (strcmp(op, MACWS_CONTROL_OP_LAUNCH_APP) == 0) {
            SetState(YES, @"启动 macOS 应用…", @"");
            ok = LaunchAllowedApp(xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_APP_ID), &message);
            if (ok) {
                os_unfair_lock_lock(&gStateLock);
                launchedAppPID = gActiveAppPID;
                os_unfair_lock_unlock(&gStateLock);
            }
        } else if (strcmp(op, MACWS_CONTROL_OP_LAUNCH_PATH) == 0) {
            SetState(YES, @"启动 macOS 路径…", @"");
            ok = LaunchRequestedPath(
                xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_APP_PATH),
                &message);
        } else if (strcmp(op, MACWS_CONTROL_OP_CAPTURE) == 0) {
            SetState(YES, @"请求刷新共享帧…", @"");
            int wsPID = 0;
            uint64_t generation = 0;
            ok = JobHasPID(kWindowServerLabel, &wsPID) &&
                 TouchPath(kShareFlag) && (generation = ArmCapture()) != 0 &&
                 WaitForCapture(wsPID, generation, 60.0, NULL);
            message = ok ? @"共享帧已刷新并由 WindowServer 确认" :
                @"WindowServer 未在 60 秒内确认刷新帧";
        } else if (strcmp(op, MACWS_CONTROL_OP_REFRESH_DOCK) == 0) {
            // This operation is internal to the Scene close transaction. It
            // never terminates the target application; it only observes that
            // the application has already exited before rebuilding Dock.
            pid_t targetPID = (pid_t)xpc_dictionary_get_int64(
                request, MACWS_CONTROL_KEY_TARGET_PID);
            ok = RefreshDockAfterProcessExit(targetPID, &message);
        }

        SetState(NO, ok ? @"就绪" : @"操作失败", ok ? @"" : message);
        ReplyResult(request, ok, message, ^(xpc_object_t reply) {
            AddStatus(reply);
            if (launchedAppPID > 1)
                xpc_dictionary_set_int64(reply, "launched_app_pid",
                                         launchedAppPID);
        });
    });
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // launchd provides a deliberately sparse environment.  macos_gui.sh
        // uses standard Procursus tools (id, ps, grep, awk, ...), so define
        // the same explicit iOS-side PATH used by the documented SSH flow.
        setenv("PATH", "/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        setenv("HOME", "/var/jb/var/root", 1);
        setenv("TMPDIR", "/tmp", 1);
        gControlQueue = dispatch_queue_create("com.macwsguide.hostd.control", DISPATCH_QUEUE_SERIAL);
        gLogQueue = dispatch_queue_create("com.macwsguide.hostd.log", DISPATCH_QUEUE_SERIAL);
        HostLog(@"macwshostd starting pid=%d protocol=%u uid=%d", getpid(),
                MACWS_CONTROL_VERSION, getuid());

        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            HostLog(@"xpc_connection_create_mach_service symbol missing");
            return 1;
        }
        dispatch_queue_t listenerQueue = dispatch_queue_create(
            "com.macwsguide.hostd.listener", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t listener = createMach(
            MACWS_CONTROL_SERVICE, listenerQueue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) {
            HostLog(@"failed to create mach listener");
            return 1;
        }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
                ServeRequest(event);
            });
            xpc_connection_resume((xpc_connection_t)peer);
        });
        xpc_connection_resume(listener);
        HostLog(@"published %s", MACWS_CONTROL_SERVICE);
        dispatch_main();
    }
    return 0;
}
