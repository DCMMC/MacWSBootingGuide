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

static const char *const kLogPath = "/var/mobile/Library/Logs/MacWSHostd.log";
static const char *const kRootFS = "/var/mnt/rootfs";
static const char *const kGUI = "/var/jb/usr/macOS/bin/macos_gui.sh";
static const char *const kBash = "/var/jb/usr/bin/bash";
static const char *const kLaunchctl = "/var/jb/usr/bin/launchctl";
static const char *const kKillall = "/var/jb/usr/bin/killall";
static const char *const kChrootExec = "/var/jb/usr/macOS/bin/launchdchrootexec";
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

static int RunCommand(const char *const argv[], BOOL waitForExit) {
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
                                 (char *const *)argv, environ);
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

static BOOL JobHasPID(const char *label, int *pidOut) {
    const char *argv[] = {kLaunchctl, "list", label, NULL};
    NSString *output = CaptureCommand(argv, 32768);
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\\"PID\\\"\\s*=\\s*([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0
                                                     range:NSMakeRange(0, output.length)];
    int pid = 0;
    if (match.numberOfRanges > 1)
        pid = [[output substringWithRange:[match rangeAtIndex:1]] intValue];
    if (pidOut) *pidOut = pid;
    return pid > 0;
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
    xpc_dictionary_set_bool(reply, "vscode_available",
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron", X_OK) == 0 &&
        access(kVSCodePlist, R_OK) == 0);
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
    const char *appNames[] = {"GlassDemo", "Terminal", "Activity Monitor", "Finder"};
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
};

// A native Host launch is complete when AppInputBridge has published at least
// one real NSWindow descriptor. This replaces the VNC framebuffer
// acknowledgement, which is intentionally absent under `start --no-vnc`.
static BOOL WaitForWindowMetrics(pid_t pid, NSTimeInterval timeout,
                                 int *exitStatusOut) {
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
            BOOL ready = fstat(fd, &st) == 0 &&
                count == (ssize_t)sizeof(header) &&
                st.st_size >= (off_t)sizeof(header) &&
                MacWSWindowMetricsAreValid(&header, (size_t)st.st_size) &&
                header.entryCount > 0;
            close(fd);
            if (ready) return YES;
        }
        usleep(100000);
    }
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

static BOOL LaunchVSCode(NSString **message) {
    if (access(kVSCodePlist, R_OK) != 0 ||
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
               X_OK) != 0) {
        *message = @"VS Code 或生产启动配置不存在";
        return NO;
    }
    int pid = 0;
    if (!JobHasPID(kVSCodeLabel, &pid)) {
        const char *loadArgv[] = {kLaunchctl, "load", kVSCodePlist, NULL};
        int rc = RunCommand(loadArgv, YES);
        if (rc != 0) {
            // A loaded but dormant one-shot job rejects a second load. Ask
            // launchd to start that exact production job; never fall back to
            // a bare Electron spawn that would lose the validated JIT/AGX
            // environment and isolated profile.
            const char *startArgv[] = {kLaunchctl, "start", kVSCodeLabel, NULL};
            (void)RunCommand(startArgv, YES);
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
        while (deadline.timeIntervalSinceNow > 0 &&
               !JobHasPID(kVSCodeLabel, &pid)) {
            usleep(100000);
        }
    }
    if (pid <= 1) {
        *message = @"VS Code 生产任务未取得进程";
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = @"vscode";
    os_unfair_lock_unlock(&gStateLock);
    int exitStatus = -1;
    if (!WaitForWindowMetrics(pid, 30.0, &exitStatus)) {
        *message = @"VS Code 正在运行，但 30 秒内没有发布 AppKit 窗口";
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
    if (access(hostPath.fileSystemRepresentation, X_OK) != 0) {
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
        if (!WaitForWindowMetrics(existingPID, 3.0, &exitStatus)) {
            HostLog(@"launch-app reuse-blocked id=%s pid=%d executable=%@ "
                    "reason=no-window-metrics",
                    identifier, existingPID, rootPath);
            *message = [NSString stringWithFormat:
                @"%s 已在运行（PID %d），但尚未发布可捕获窗口；为避免重复实例，未再次启动",
                identifier, existingPID];
            return NO;
        }
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

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    const char *rootExecutable = rootPath.fileSystemRepresentation;
    const char *argv[] = {kChrootExec, "0", "0", kRootFS,
                          rootExecutable, NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, kChrootExec, &actions, NULL,
                            (char *const *)argv, environ);
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
        if (!WaitForWindowMetrics(pid, timeout, &exitStatus)) {
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
            return NO;
        }
        HostLog(@"launch-app window-ready id=%s pid=%d path=DisplayStream",
                identifier, pid);
    } else {
        *message = @"DisplayStream 服务未运行";
        return NO;
    }
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
    char resolved[PATH_MAX] = {0};
    static const char hostRootPrefix[] = "/var/mnt/rootfs/";
    if (!realpath(hostPath.fileSystemRepresentation, resolved) ||
        strncmp(resolved, hostRootPrefix, sizeof(hostRootPrefix) - 1) != 0 ||
        access(resolved, X_OK) != 0) {
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    return [NSString stringWithUTF8String:resolved + strlen("/var/mnt/rootfs")];
}

static BOOL LaunchRequestedPath(const char *requestedPath, NSString **message) {
    NSString *error = nil;
    NSString *rootPath = ResolveExecutableRootPath(requestedPath, &error);
    if (!rootPath) {
        *message = error ?: @"无法解析路径";
        return NO;
    }
    return LaunchRootExecutable("custom-path", rootPath,
        "/var/mobile/Library/Logs/CustomApp.host.log", 30.0, message);
}

static BOOL LaunchAllowedApp(const char *identifier, NSString **message) {
    if (identifier && strcmp(identifier, "vscode") == 0)
        return LaunchVSCode(message);
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
