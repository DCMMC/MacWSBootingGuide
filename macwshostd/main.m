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
    BOOL ws = JobHasPID("com.apple.WindowServer", &wsPID);
    int inputPID = 0;
    BOOL inputJob = JobHasPID("com.macwsguide.input", &inputPID);
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
        if (JobHasPID("com.apple.WindowServer", &pid) &&
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

    uint64_t captureGeneration = ArmCapture();
    if (captureGeneration == 0) {
        *message = [NSString stringWithFormat:@"无法请求首帧捕获: %s",
                    strerror(errno)];
        return NO;
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
    SetState(YES, @"启动 WindowServer…", @"");
    const char *wsArgv[] = {kLaunchctl, "start", "com.apple.WindowServer", NULL};
    rc = RunCommand(wsArgv, YES);
    if (rc != 0) {
        *message = [NSString stringWithFormat:@"WindowServer 启动请求失败（退出码 %d）", rc];
        return NO;
    }
    // WindowServer still has a runtime-confirmed, intermittent Foundation
    // SystemStatus XPC SIGBUS during startup. Do not pretend that crash is a
    // healthy session: preserve its crash report/log, then retry the whole
    // process at most twice. A live process that simply fails to publish a
    // frame is not retried; it is stopped after the bounded 60-second wait.
    for (unsigned attempt = 1; attempt <= 3; attempt++) {
        if (attempt > 1) {
            SetState(YES, [NSString stringWithFormat:
                @"WindowServer 启动重试 %u/3…", attempt], @"");
            const char *killArgv[] = {kKillall, "-9", "WindowServer", NULL};
            (void)RunCommand(killArgv, YES);
            RemovePath(kFrame);
            RemovePath(kCaptureFlag);
            RemovePath(kCaptureAck);
            captureGeneration = ArmCapture();
            if (captureGeneration == 0) break;
            usleep(500000);
            if (RunCommand(wsArgv, YES) != 0) continue;
        }

        SetState(YES, @"等待 WindowServer 与触控桥…", @"");
        int wsPID = 0;
        if (!WaitForGUIComponents(15.0, &wsPID)) {
            HostLog(@"startup attempt %u/3 failed before GUI components", attempt);
            continue;
        }
        SetState(YES, @"等待首个可显示帧…", @"");
        BOOL processExited = NO;
        if (WaitForCapture(wsPID, captureGeneration, 60.0,
                           &processExited)) {
            *message = attempt == 1
                ? @"macOS GUI、触控桥与首帧均已就绪"
                : [NSString stringWithFormat:
                    @"macOS GUI 已在第 %u 次尝试完成首帧", attempt];
            return YES;
        }
        HostLog(@"startup attempt %u/3 frame failed pid=%d exited=%@",
                attempt, wsPID, processExited ? @"YES" : @"NO");
        if (!processExited) break;
    }

    NSString *stopMessage = nil;
    (void)StopGUI(&stopMessage);
    *message = @"WindowServer 未能确认首帧，已在有界重试后自动停止以避免空转";
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

static BOOL LaunchAllowedApp(const char *identifier, NSString **message) {
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
    NSString *hostPath = [@("/var/mnt/rootfs") stringByAppendingString:@(app->rootPath)];
    if (access(hostPath.fileSystemRepresentation, X_OK) != 0) {
        *message = [NSString stringWithFormat:@"应用不存在: %s", app->rootPath];
        return NO;
    }
    if (!JobHasPID("com.apple.WindowServer", NULL)) {
        *message = @"请先启动 macOS GUI";
        return NO;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(app->logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    const char *argv[] = {kChrootExec, "0", "0", kRootFS, app->rootPath, NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, kChrootExec, &actions, NULL,
                            (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (error != 0) {
        *message = [NSString stringWithFormat:@"拉起应用失败: %s", strerror(error)];
        return NO;
    }
    HostLog(@"launch-app id=%s pid=%d executable=%s", identifier, pid, app->rootPath);
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = [@(identifier) copy];
    os_unfair_lock_unlock(&gStateLock);
    // Each launch requests one bounded post-launch snapshot.  The producer
    // acknowledges the exact generation; a stale desktop frame cannot make
    // this operation succeed.
    usleep(3000000);
    uint64_t generation = ArmCapture();
    int wsPID = 0;
    if (generation == 0 || !JobHasPID("com.apple.WindowServer", &wsPID) ||
        !WaitForCapture(wsPID, generation, 60.0, NULL)) {
        *message = [NSString stringWithFormat:
            @"%s 已启动，但 WindowServer 未确认更新后的共享帧", identifier];
        return NO;
    }
    if (strcmp(identifier, "glassdemo") == 0) {
        *message = @"GlassDemo 已启动；首次轻触会关闭它的启动诊断菜单，随后可直接操作控件";
    } else {
        *message = [NSString stringWithFormat:@"已启动 %s 并刷新画面", identifier];
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
        if (strcmp(op, MACWS_CONTROL_OP_START) == 0) {
            BOOL experimental = xpc_dictionary_get_bool(request, MACWS_CONTROL_KEY_EXPERIMENTAL);
            ok = StartGUI(experimental, &message);
        } else if (strcmp(op, MACWS_CONTROL_OP_STOP) == 0) {
            SetState(YES, @"停止 macOS GUI…", @"");
            ok = StopGUI(&message);
        } else if (strcmp(op, MACWS_CONTROL_OP_REPAIR) == 0) {
            SetState(YES, @"停止工作区并修复启动环境…", @"");
            if (JobHasPID("com.apple.WindowServer", NULL)) {
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
        } else if (strcmp(op, MACWS_CONTROL_OP_CAPTURE) == 0) {
            SetState(YES, @"请求刷新共享帧…", @"");
            int wsPID = 0;
            uint64_t generation = 0;
            ok = JobHasPID("com.apple.WindowServer", &wsPID) &&
                 TouchPath(kShareFlag) && (generation = ArmCapture()) != 0 &&
                 WaitForCapture(wsPID, generation, 60.0, NULL);
            message = ok ? @"共享帧已刷新并由 WindowServer 确认" :
                @"WindowServer 未在 60 秒内确认刷新帧";
        }

        SetState(NO, ok ? @"就绪" : @"操作失败", ok ? @"" : message);
        ReplyResult(request, ok, message, ^(xpc_object_t reply) { AddStatus(reply); });
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
