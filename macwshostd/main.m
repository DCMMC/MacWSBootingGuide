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
static const char *const kExperimentalKCmd = "/var/mnt/rootfs/private/tmp/macws_kcmd_fix";
static const char *const kExperimentalCompletion = "/var/mnt/rootfs/private/tmp/macws_cancel_completion";

static dispatch_queue_t gControlQueue;
static dispatch_queue_t gLogQueue;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static BOOL gBusy;
static NSString *gPhase = @"就绪";
static NSString *gLastError = @"";

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
    ssize_t count = read(fd, header, sizeof(header));
    close(fd);
    if (count != sizeof(header) || header[0] != MACWS_FRAME_MAGIC ||
        header[1] == 0 || header[2] == 0 || header[1] > 16384 || header[2] > 16384)
        return NO;
    if (width) *width = header[1];
    if (height) *height = header[2];
    return YES;
}

static BOOL IsSocket(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISSOCK(st.st_mode);
}

static void SetString(xpc_object_t reply, const char *key, NSString *value) {
    xpc_dictionary_set_string(reply, key, value.UTF8String ?: "");
}

static void AddStatus(xpc_object_t reply) {
    int wsPID = 0;
    BOOL ws = JobHasPID("com.apple.WindowServer", &wsPID);
    int inputPID = 0;
    BOOL inputJob = JobHasPID("com.macwsguide.input", &inputPID);
    uint32_t width = 0, height = 0;
    BOOL frame = ReadFrame(&width, &height);
    BOOL busy;
    NSString *phase;
    NSString *lastError;
    os_unfair_lock_lock(&gStateLock);
    busy = gBusy;
    phase = gPhase;
    lastError = gLastError;
    os_unfair_lock_unlock(&gStateLock);

    xpc_dictionary_set_uint64(reply, "protocol_version", MACWS_CONTROL_VERSION);
    xpc_dictionary_set_bool(reply, "busy", busy);
    SetString(reply, "phase", phase);
    SetString(reply, "last_error", lastError);
    xpc_dictionary_set_bool(reply, "rootfs_ready", RootFSReady());
    xpc_dictionary_set_bool(reply, "windowserver_running", ws);
    xpc_dictionary_set_int64(reply, "windowserver_pid", wsPID);
    xpc_dictionary_set_bool(reply, "input_running", inputJob && IsSocket(kInputSocket));
    xpc_dictionary_set_int64(reply, "input_pid", inputPID);
    xpc_dictionary_set_bool(reply, "frame_ready", ws && frame);
    xpc_dictionary_set_uint64(reply, "frame_width", width);
    xpc_dictionary_set_uint64(reply, "frame_height", height);
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

static BOOL WaitForGUI(NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (JobHasPID("com.apple.WindowServer", NULL) && IsSocket(kInputSocket)) return YES;
        usleep(250000);
    }
    return NO;
}

static BOOL StartGUI(BOOL experimental, NSString **message) {
    if (!RootFSReady()) {
        *message = @"macOS rootfs 或启动组件不完整";
        return NO;
    }
    if (!TouchPath(kShareFlag)) {
        *message = [NSString stringWithFormat:@"无法准备共享帧标志: %s", strerror(errno)];
        return NO;
    }
    RemovePath(kCaptureFlag);
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
    SetState(YES, @"等待画面与触控桥…", @"");
    BOOL ready = WaitForGUI(25.0);
    *message = ready ? @"macOS GUI 与触控桥已启动" :
        @"启动命令已完成，但画面或触控桥尚未就绪；请查看诊断日志";
    return ready;
}

static BOOL StopGUI(NSString **message) {
    const char *argv[] = {kBash, kGUI, "stop", NULL};
    int rc = RunCommand(argv, YES);
    const char *appNames[] = {"GlassDemo", "Terminal", "Activity Monitor", "Finder"};
    for (NSUInteger i = 0; i < sizeof(appNames) / sizeof(appNames[0]); i++) {
        const char *killArgv[] = {kKillall, "-9", appNames[i], NULL};
        (void)RunCommand(killArgv, YES);
    }
    RemovePath(kFrame);
    RemovePath(kShareFlag);
    RemovePath(kCaptureFlag);
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
    if (strcmp(identifier, "glassdemo") == 0) {
        // The current PF550 readback is a one-shot diagnostic. Arm it only
        // after GlassDemo has had time to create its window, rather than
        // consuming the one shot on an unrelated compositor frame.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       gControlQueue, ^{
            if (TouchPath(kCaptureFlag))
                HostLog(@"diagnostic one-shot capture armed after GlassDemo launch");
        });
    }
    *message = [NSString stringWithFormat:@"已启动 %s", identifier];
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
            ok = TouchPath(kShareFlag) && TouchPath(kCaptureFlag);
            message = ok ? @"已请求刷新共享帧" : @"无法创建捕获标志";
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
