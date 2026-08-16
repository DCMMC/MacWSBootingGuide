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
#include <limits.h>
#include <netdb.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include <mach/task.h>

#include "macws_control_protocol.h"
#include "macws_host_protocol.h"
#include "macws_steam_mach_rendezvous_protocol.h"
#include "macws_steam_semaphore_protocol.h"
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
static const char *const kStartupLogPath =
    "/var/mobile/Library/Logs/MacWSStartup.log";
static const char *const kGUIStartState =
    "/var/jb/var/mobile/macos_gui_start.state";
static const char *const kPostinstLog = "/var/jb/var/mobile/postinst.log";
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
static const char *const kWeatherExecutable =
    "/System/Applications/Weather.app/Contents/MacOS/Weather";
static const char *const kWeatherBundleIdentifier = "com.apple.weather";
static const char *const kWeatherContainerHome =
    "/Users/mobile/Library/Containers/com.apple.weather/Data";
static const char *const kWeatherKnownSceneSessions =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data";
static const char *const kWeatherKnownSceneSessionsLegacyPreBootstrap =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data.macws-pre-bootstrap";
static const char *const kWeatherKnownSceneSessionsLegacyLastStale =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data.macws-last-stale";
static const char *const kWeatherKnownSceneSessionsBackup =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/.macws-weather-known-scene-last.data";
static const char *const kWeatherKnownSceneSessionsLegacyBackup =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/.macws-weather-known-scene-legacy.data";
static const char *const kAsphaltExecutable =
    "/Applications/Asphalt.app/Contents/MacOS/Asphalt";
static const char *const kAsphaltBundleIdentifier =
    "com.gameloft.asphalt9mac";
static const char *const kAsphaltContainerHome =
    "/Users/mobile/Library/Containers/com.gameloft.asphalt9mac/Data";
static const char *const kCatalystRequestPath =
    "/var/jb/var/mobile/macws-catalyst-launch-request.plist";
static const char *const kSteamLabel = "com.macwsguide.steam";
static const char *const kSteamPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist";
static const char *const kSteamOuterExecutable =
    "/Applications/Steam.app/Contents/MacOS/steam_osx";
static const char *const kSteamLiveExecutable =
    "/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx";
static CFStringRef const kMapsHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-maps");
static CFStringRef const kCatalystHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-catalyst");
static pid_t WaitForRunningRootExecutable(NSString *rootPath,
                                          NSTimeInterval timeout);

static dispatch_queue_t gControlQueue;
static dispatch_queue_t gLogQueue;
static dispatch_queue_t gSteamSemaphoreQueue;
static dispatch_queue_t gSteamMachRendezvousQueue;
static dispatch_source_t gSteamSemaphoreWaitListener;
static int gSteamSemaphoreWaitListenerDescriptor = -1;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static BOOL gBusy;
static NSString *gPhase = @"就绪";
static NSString *gLastError = @"";
static BOOL gStartupOperationActive;
static BOOL gStartupRetryAvailable;
static time_t gStartupBeganAt;
static pid_t gActiveAppPID;
static NSString *gActiveAppID = @"";

typedef struct {
    uint64_t generation;
    uint32_t references;
    uint32_t value;
    BOOL unlinked;
    char name[112];
    mach_port_t waiterPorts[32];
    uint32_t waiterCount;
    int waiterSockets[32];
    uint64_t waiterSocketRequestIDs[32];
    uint64_t waiterSocketIDs[32];
    uint32_t waiterSocketCount;
    uint64_t pollingWaiters[64];
    uint8_t pollingWaiterGranted[64];
    uint32_t pollingWaiterCount;
} MacWSSteamSemaphoreEntry;

static NSMutableDictionary<NSString *, NSValue *> *gSteamSemaphoreNames;
static NSMutableDictionary<NSString *, NSNumber *> *gSteamMachRendezvousPorts;
static NSMutableDictionary<NSNumber *, NSValue *> *gSteamSemaphoreGenerations;
// name -> generation returned by the latest successful unlink. A protocol-v21
// recreate must present that exact receipt before it may retire a name won by
// a racing opener. This keeps ordinary O_CREAT|O_EXCL strict.
static NSMutableDictionary<NSString *, NSNumber *> *
    gSteamSemaphoreUnlinkReceipts;
static uint64_t gSteamSemaphoreNextGeneration;
static NSString *gSteamSemaphoreEpoch;

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

// Catalyst's responsible-process carrier supplies HOME explicitly, but the
// mounted Ventura filesystem does not have containermanagerd to materialize a
// first-run container.  Runtime on iPad13,6 showed Weather's executable and
// UIKitSystem service present while this one directory was absent; the
// already-working Asphalt carrier has the concrete ownership/mode contract
// mirrored below.  Only fixed allowlist constants reach this helper.
static BOOL EnsureCatalystContainer(const char *containerHome,
                                    NSString **message) {
    if (!containerHome ||
        strncmp(containerHome, "/Users/mobile/Library/Containers/",
                strlen("/Users/mobile/Library/Containers/")) != 0 ||
        strstr(containerHome, "..") != NULL) {
        if (message) *message = @"Catalyst 容器路径不在允许范围内";
        return NO;
    }
    NSString *dataPath = [@(kRootFS) stringByAppendingString:@(containerHome)];
    if (![dataPath.lastPathComponent isEqualToString:@"Data"]) {
        if (message) *message = @"Catalyst 容器必须以 Data 为根";
        return NO;
    }
    NSString *containerPath = dataPath.stringByDeletingLastPathComponent;
    NSArray<NSDictionary<NSString *, id> *> *directories = @[
        @{@"path": containerPath, @"mode": @(0700)},
        @{@"path": dataPath, @"mode": @(0700)},
        @{@"path": [dataPath stringByAppendingPathComponent:@"Documents"],
          @"mode": @(0755)},
        @{@"path": [dataPath stringByAppendingPathComponent:@"Library"],
          @"mode": @(0755)},
    ];
    for (NSDictionary<NSString *, id> *entry in directories) {
        NSString *path = entry[@"path"];
        mode_t mode = (mode_t)[entry[@"mode"] unsignedShortValue];
        const char *fileSystemPath = path.fileSystemRepresentation;
        struct stat status = {0};
        if (lstat(fileSystemPath, &status) != 0) {
            if (errno != ENOENT || mkdir(fileSystemPath, mode) != 0) {
                if (message) *message = [NSString stringWithFormat:
                    @"无法创建 Catalyst 容器 %@（errno=%d）",
                    path.lastPathComponent, errno];
                return NO;
            }
        } else if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
            if (message) *message = [NSString stringWithFormat:
                @"Catalyst 容器路径不是目录：%@", path];
            return NO;
        }
        if (chown(fileSystemPath, 501, 501) != 0 ||
            chmod(fileSystemPath, mode) != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"无法设置 Catalyst 容器权限 %@（errno=%d）",
                path.lastPathComponent, errno];
            return NO;
        }
    }
    return YES;
}

// Runtime-confirmed on iPad13,6 with Weather pids 79331/89014/89042: UIKit
// first tracked the current process's newly requested persistent scene ID,
// then restored the preceding process's ID from this exact archive. FuseBoard
// reused one FUScene identifier for both transactions, after which
// UINSApplicationDelegate logged "untracked scene, ignoring" and the real
// Weather NSWindow remained onscreen=false with CGSCopySpacesForWindows=().
// A clean-launch A/B at pid 90330 then moved data.data but left two earlier
// MacWS backups in KnownSceneSessions; UIKit still restored the ID contained
// by those backups. Move every exact, known MacWS filename out of Saved
// Application State as well as the stock archive. Weather locations and
// preferences live elsewhere and remain untouched. Two fixed backups retain
// the last stock/legacy inputs without accumulating files across launches.
static BOOL MoveWeatherSceneStateFile(const char *source,
                                      const char *destination,
                                      const char *label,
                                      long long *bytesMoved,
                                      NSString **message) {
    struct stat stateStatus = {0};
    if (lstat(source, &stateStatus) != 0) {
        if (errno == ENOENT) return YES;
        if (message) *message = [NSString stringWithFormat:
            @"无法检查天气场景恢复记录（errno=%d）", errno];
        return NO;
    }
    if (!S_ISREG(stateStatus.st_mode) || S_ISLNK(stateStatus.st_mode) ||
        stateStatus.st_nlink != 1 ||
        (stateStatus.st_uid != 0 && stateStatus.st_uid != 501)) {
        HostLog(@"weather scene-restoration reject mode=%#o uid=%u links=%u",
                stateStatus.st_mode, stateStatus.st_uid,
                (unsigned)stateStatus.st_nlink);
        if (message) *message = @"天气场景恢复记录的类型或所有者异常，未修改";
        return NO;
    }

    struct stat backupStatus = {0};
    int backupResult = lstat(destination, &backupStatus);
    int backupError = errno;
    if (backupResult == 0 &&
        (!S_ISREG(backupStatus.st_mode) ||
         S_ISLNK(backupStatus.st_mode) || backupStatus.st_nlink != 1 ||
         (backupStatus.st_uid != 0 && backupStatus.st_uid != 501))) {
        HostLog(@"weather scene-restoration backup-reject mode=%#o uid=%u "
                "links=%u", backupStatus.st_mode, backupStatus.st_uid,
                (unsigned)backupStatus.st_nlink);
        if (message) *message = @"天气场景恢复备份的类型或所有者异常，未修改";
        return NO;
    } else if (backupResult != 0 && backupError != ENOENT) {
        if (message) *message = [NSString stringWithFormat:
            @"无法检查天气场景恢复备份（errno=%d）", backupError];
        return NO;
    }

    if (rename(source, destination) != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法轮换天气场景恢复记录（errno=%d）", errno];
        return NO;
    }
    if (bytesMoved) *bytesMoved += (long long)stateStatus.st_size;
    HostLog(@"weather scene-restoration moved label=%s bytes=%lld uid=%u "
            "backup=%s", label, (long long)stateStatus.st_size,
            stateStatus.st_uid, destination);
    return YES;
}

static BOOL RotateWeatherKnownSceneSessions(NSString **message) {
    long long bytesMoved = 0;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessionsLegacyPreBootstrap,
            kWeatherKnownSceneSessionsLegacyBackup, "legacy-pre-bootstrap",
            &bytesMoved, message)) return NO;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessionsLegacyLastStale,
            kWeatherKnownSceneSessionsLegacyBackup, "legacy-last-stale",
            &bytesMoved, message)) return NO;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessions, kWeatherKnownSceneSessionsBackup,
            "stock", &bytesMoved, message)) return NO;
    HostLog(@"weather scene-restoration clean moved-total-bytes=%lld",
            bytesMoved);
    return YES;
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

static int RunCommandWithEnvironmentToLog(const char *const argv[],
                                          char *const environment[],
                                          BOOL waitForExit,
                                          const char *logPath) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(logPath ? logPath : kLogPath,
                     O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
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

static int RunCommandWithEnvironment(const char *const argv[],
                                     char *const environment[],
                                     BOOL waitForExit) {
    return RunCommandWithEnvironmentToLog(argv, environment, waitForExit,
                                          kLogPath);
}

static int RunCommand(const char *const argv[], BOOL waitForExit) {
    return RunCommandWithEnvironment(argv, environ, waitForExit);
}

static int RunCommandToLog(const char *const argv[], BOOL waitForExit,
                           const char *logPath) {
    return RunCommandWithEnvironmentToLog(argv, environ, waitForExit,
                                          logPath);
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

static NSString *TailFile(const char *path, NSUInteger limit);

static NSString *GUIStartStateValue(NSString *key) {
    NSString *state = ReadSmallTextFile(kGUIStartState, 4096);
    NSString *prefix = [key stringByAppendingString:@"="];
    for (NSString *line in [state componentsSeparatedByCharactersInSet:
             NSCharacterSet.newlineCharacterSet]) {
        if ([line hasPrefix:prefix]) return [line substringFromIndex:prefix.length];
    }
    return @"";
}

static NSString *StartupPhaseDisplay(NSString *phaseCode) {
    if (!phaseCode.length) return @"检查并修复启动环境…";
    static NSDictionary<NSString *, NSString *> *phases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        phases = @{
            @"preparing": @"正在生成启动配置…",
            @"cleaning": @"正在清理旧的服务状态…",
            @"assets": @"正在准备应用运行环境…",
            @"preflight": @"正在验证图形启动条件…",
            @"safety": @"正在启动安全保护…",
            @"trust": @"检查并修复启动环境…",
            @"services": @"正在启动 macOS 系统服务…",
            @"first-frame": @"正在等待第一帧画面…",
            @"ready": @"macOS 工作区已就绪",
        };
    });
    return phases[phaseCode] ?: @"检查并修复启动环境…";
}

static NSString *StartupLogText(time_t startupBeganAt,
                                BOOL includePostinst) {
    NSMutableString *text = [NSMutableString string];
    NSString *startup = TailFile(kStartupLogPath, 12288);
    if (startup.length) [text appendString:startup];

    struct stat postinstStatus = {0};
    BOOL currentPostinst = includePostinst &&
        stat(kPostinstLog, &postinstStatus) == 0 &&
        postinstStatus.st_mtime >= startupBeganAt;
    if (currentPostinst) {
        NSString *postinst = TailFile(kPostinstLog, 12288);
        if (postinst.length) {
            if (text.length) [text appendString:@"\n\n"];
            [text appendString:@"=== postinst.sh ===\n"];
            [text appendString:postinst];
        }
    }
    if (!text.length)
        [text appendString:@"等待启动日志…"];
    return text;
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
    BOOL startupActive;
    BOOL startupRetryAvailable;
    time_t startupBeganAt;
    NSString *phase;
    NSString *lastError;
    os_unfair_lock_lock(&gStateLock);
    busy = gBusy;
    startupActive = gStartupOperationActive;
    startupRetryAvailable = gStartupRetryAvailable;
    startupBeganAt = gStartupBeganAt;
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

    NSString *startupPhaseCode = GUIStartStateValue(@"phase");
    if (startupActive)
        phase = StartupPhaseDisplay(startupPhaseCode);

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
    xpc_dictionary_set_bool(reply, "startup_retry_available",
                            startupRetryAvailable);
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
    SetString(reply, "startup_log",
              (startupActive || startupRetryAvailable)
                  ? StartupLogText(startupBeganAt,
                                   [startupPhaseCode isEqualToString:@"trust"] ||
                                       startupRetryAvailable)
                  : @"");
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
    xpc_dictionary_set_bool(reply, "weather_available", HasExecutableFileMode(
        "/var/mnt/rootfs/System/Applications/Weather.app/Contents/MacOS/Weather"));
    xpc_dictionary_set_bool(reply, "sublime_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Sublime Text.app/Contents/MacOS/sublime_text"));
    xpc_dictionary_set_bool(reply, "steam_available",
        access(kSteamPlist, R_OK) == 0 &&
        (HasExecutableFileMode(
             "/var/mnt/rootfs/Applications/Steam.app/Contents/MacOS/steam_osx") ||
         HasExecutableFileMode(
             "/var/mnt/rootfs/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")));
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
    int startupLogFD = open(kStartupLogPath,
                            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (startupLogFD >= 0) close(startupLogFD);
    int rc = RunCommandToLog(startArgv, YES, kStartupLogPath);
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
                              "Amadine", "Microsoft Word", "Microsoft Excel",
                              "Microsoft PowerPoint",
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
    {"sublime", "/Applications/Sublime Text.app/Contents/MacOS/sublime_text", "/var/mobile/Library/Logs/SublimeText.host.log"},
};

static BOOL IsThirdPartyAppIdentifier(const char *identifier) {
    return identifier &&
        (strcmp(identifier, "amadine") == 0 ||
         strcmp(identifier, "word") == 0 ||
         strcmp(identifier, "excel") == 0 ||
         strcmp(identifier, "powerpoint") == 0 ||
         strcmp(identifier, "sublime") == 0);
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
static BOOL LaunchCatalystViaUIKitCarrier(const char *identifier,
                                          const char *displayName,
                                          const char *executable,
                                          const char *bundleIdentifier,
                                          const char *containerHome,
                                          NSString **message) {
    NSString *rootPath = @(executable);
    NSString *hostPath = [@(kRootFS) stringByAppendingString:rootPath];
    NSString *hostContainer = [@(kRootFS) stringByAppendingString:@(containerHome)];
    NSString *name = @(displayName);
    if (!EnsureCatalystContainer(containerHome, message)) return NO;
    struct stat containerStatus = {0};
    if (!HasExecutableFileMode(hostPath.fileSystemRepresentation) ||
        stat(hostContainer.fileSystemRepresentation, &containerStatus) != 0 ||
        !S_ISDIR(containerStatus.st_mode) ||
        access(kUIKitSystemPlist, R_OK) != 0) {
        *message = [NSString stringWithFormat:
            @"%@ 的可执行文件、容器或 Catalyst 服务不完整", name];
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
            *message = [NSString stringWithFormat:
                @"UIKitSystem 未能完成 %@ 场景服务启动", name];
            return NO;
        }
    }

    pid_t catalystPID = FindRunningRootExecutable(rootPath);
    if (catalystPID > 1) {
        BOOL exactCarrier = CatalystChildMarkerMatches(
            catalystPID, executable, bundleIdentifier);
        if (exactCarrier && RequestApplicationReopen(catalystPID, 8.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = catalystPID;
            gActiveAppID = @(identifier);
            os_unfair_lock_unlock(&gStateLock);
            *message = [NSString stringWithFormat:
                @"%@ 已在当前 macPad 工作区运行", name];
            return YES;
        }
        if (!TerminateWindowlessRootExecutable(catalystPID, rootPath, message))
            return NO;
    }

    if (strcmp(identifier, "weather") == 0 &&
        !RotateWeatherKnownSceneSessions(message)) return NO;

    RetireLegacyMapsUIKitCarrier();
    if (!WriteCatalystLaunchRequest(
            executable, bundleIdentifier, containerHome, message)) return NO;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kCatalystHostLaunchNotification, NULL, NULL, true);
    catalystPID = WaitForRunningRootExecutable(rootPath, 5.0);
    unlink(kCatalystRequestPath);
    if (catalystPID <= 1) {
        *message = [NSString stringWithFormat:
            @"macPad 未能在当前工作区启动 %@", name];
        return NO;
    }
    if (!CatalystChildMarkerMatches(
            catalystPID, executable, bundleIdentifier)) {
        NSString *retireMessage = nil;
        (void)TerminateWindowlessRootExecutable(
            catalystPID, rootPath, &retireMessage);
        *message = [NSString stringWithFormat:
            @"%@ 进程缺少匹配的 Host Catalyst 身份，已拒绝", name];
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = catalystPID;
    gActiveAppID = @(identifier);
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"launch-app process-ready id=%s pid=%d uikitsystem=%d "
            "route=existing-MacWSHost catalog=asynchronous",
            identifier, catalystPID, uikitSystemPID);
    *message = [NSString stringWithFormat:
        @"%@ 正在当前工作区打开，未创建新的 iPadOS 窗口", name];
    return YES;
}

static BOOL LaunchAsphaltViaUIKitCarrier(NSString **message) {
    return LaunchCatalystViaUIKitCarrier(
        "asphalt", "Asphalt", kAsphaltExecutable,
        kAsphaltBundleIdentifier, kAsphaltContainerHome, message);
}

static BOOL LaunchWeatherViaUIKitCarrier(NSString **message) {
    return LaunchCatalystViaUIKitCarrier(
        "weather", "天气", kWeatherExecutable,
        kWeatherBundleIdentifier, kWeatherContainerHome, message);
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

static pid_t FindRunningSteamExecutable(void) {
    pid_t pid = FindRunningRootExecutable(@(kSteamLiveExecutable));
    return pid > 1 ? pid : FindRunningRootExecutable(@(kSteamOuterExecutable));
}

static BOOL LaunchSteam(NSString **message) {
    NSString *outerHostPath = [@(kRootFS)
        stringByAppendingString:@(kSteamOuterExecutable)];
    NSString *liveHostPath = [@(kRootFS)
        stringByAppendingString:@(kSteamLiveExecutable)];
    if (access(kSteamPlist, R_OK) != 0 ||
        (!HasExecutableFileMode(outerHostPath.fileSystemRepresentation) &&
         !HasExecutableFileMode(liveHostPath.fileSystemRepresentation))) {
        *message = @"Steam 或其生产运行任务不存在";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    pid_t steamPID = FindRunningSteamExecutable();
    if (steamPID > 1) {
        (void)RequestApplicationReopen(steamPID, 1.0);
        os_unfair_lock_lock(&gStateLock);
        gActiveAppPID = steamPID;
        gActiveAppID = @"steam";
        os_unfair_lock_unlock(&gStateLock);
        *message = @"Steam 已在运行，正在打开现有窗口";
        return YES;
    }

    int jobPID = 0;
    BOOL jobLoaded = NO;
    (void)InspectJob(kSteamLabel, &jobPID, &jobLoaded);
    const char *startArgv[] = {kLaunchctl, "start", kSteamLabel, NULL};
    const char *loadArgv[] = {kLaunchctl, "load", kSteamPlist, NULL};
    int launchResult = jobLoaded
        ? RunCommand(startArgv, YES) : RunCommand(loadArgv, YES);
    if (launchResult != 0) {
        *message = [NSString stringWithFormat:
            @"Steam 生产任务启动失败（退出码 %d）", launchResult];
        return NO;
    }
    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 20.0;
    do {
        steamPID = FindRunningSteamExecutable();
        if (steamPID > 1) break;
        usleep(100000);
    } while (NSDate.date.timeIntervalSince1970 < deadline);
    if (steamPID <= 1) {
        *message = @"Steam 生产任务已提交，但 20 秒内没有取得 steam_osx 进程";
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = steamPID;
    gActiveAppID = @"steam";
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"launch-app process-ready id=steam pid=%d label=%s",
            steamPID, kSteamLabel);
    *message = @"Steam 正在通过生产运行任务打开";
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
    if ([rootPath isEqualToString:@(kWeatherExecutable)])
        return LaunchAllowedApp("weather", message);
    if ([rootPath isEqualToString:@(kSteamOuterExecutable)] ||
        [rootPath isEqualToString:@(kSteamLiveExecutable)])
        return LaunchAllowedApp("steam", message);
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
    if (identifier && strcmp(identifier, "weather") == 0)
        return LaunchWeatherViaUIKitCarrier(message);
    if (identifier && strcmp(identifier, "steam") == 0)
        return LaunchSteam(message);
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

static BOOL IsSteamSemaphoreName(const char *name) {
    if (!name || strnlen(name, 112) >= 112) return NO;
    return strncmp(name, "/BSem/", 6) == 0 ||
        strncmp(name, "/Evt/", 5) == 0 ||
        strncmp(name, "/MTX/", 5) == 0;
}

static BOOL IsSteamSemaphoreOperation(const char *operation) {
    return operation &&
        (!strcmp(operation, MACWS_STEAM_SEM_OP_OPEN) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_RECREATE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_CLOSE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_UNLINK) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_RESET) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_DELAY) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_TRYWAIT) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_WAIT_POLL) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_POST) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_GETVALUE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_REGISTER_WAIT) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_NOTIFY));
}

static BOOL IsSteamMachRendezvousName(const char *name) {
    static const char prefix[] = MACWS_STEAM_MACH_RENDEZVOUS_PREFIX;
    if (!name || strncmp(name, prefix, sizeof(prefix) - 1) != 0 ||
        strnlen(name, 128) >= 128) return NO;
    const char *suffix = name + sizeof(prefix) - 1;
    if (!*suffix) return NO;
    for (const char *cursor = suffix; *cursor; cursor++) {
        if (*cursor < '0' || *cursor > '9') return NO;
    }
    return YES;
}

static BOOL IsSteamMachRendezvousOperation(const char *operation) {
    return operation &&
        (!strcmp(operation, MACWS_STEAM_MACH_OP_REGISTER) ||
         !strcmp(operation, MACWS_STEAM_MACH_OP_LOOKUP));
}

static BOOL ReplySteamMachRendezvous(xpc_object_t request, int error,
                                     mach_port_t sendPort) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_MACH_KEY_ERROR, error);
    if (error == 0 && MACH_PORT_VALID(sendPort))
        xpc_dictionary_set_mach_send(
            reply, MACWS_STEAM_MACH_KEY_PORT, sendPort);
    xpc_connection_send_message(peer, reply);
    return YES;
}

static void ServeSteamMachRendezvousRequest(xpc_object_t request,
                                            const char *operation) {
    const char *name = xpc_dictionary_get_string(
        request, MACWS_STEAM_MACH_KEY_NAME);
    if (!IsSteamMachRendezvousName(name)) {
        ReplySteamMachRendezvous(request, EINVAL, MACH_PORT_NULL);
        return;
    }
    NSString *key = @(name);
    BOOL registerOperation =
        !strcmp(operation, MACWS_STEAM_MACH_OP_REGISTER);
    mach_port_t registeredPort = registerOperation
        ? xpc_dictionary_copy_mach_send(
            request, MACWS_STEAM_MACH_KEY_PORT)
        : MACH_PORT_NULL;
    if (registerOperation && !MACH_PORT_VALID(registeredPort)) {
        ReplySteamMachRendezvous(request, EINVAL, MACH_PORT_NULL);
        return;
    }

    dispatch_async(gSteamMachRendezvousQueue, ^{
        if (registerOperation) {
            NSNumber *previous = gSteamMachRendezvousPorts[key];
            if (!previous && gSteamMachRendezvousPorts.count >= 64) {
                // PID-qualified entries cannot be reused by a later browser.
                // Keep the broker bounded across repeated failed launches.
                NSString *oldest = gSteamMachRendezvousPorts.allKeys.firstObject;
                NSNumber *stale = oldest
                    ? gSteamMachRendezvousPorts[oldest] : nil;
                if (oldest) [gSteamMachRendezvousPorts removeObjectForKey:oldest];
                if (stale && MACH_PORT_VALID(stale.unsignedIntValue))
                    (void)mach_port_deallocate(
                        mach_task_self(), stale.unsignedIntValue);
            }
            if (previous && MACH_PORT_VALID(previous.unsignedIntValue))
                (void)mach_port_deallocate(
                    mach_task_self(), previous.unsignedIntValue);
            gSteamMachRendezvousPorts[key] = @(registeredPort);
            HostLog(@"Steam Mach rendezvous registered name=%@ port=%u",
                    key, registeredPort);
            ReplySteamMachRendezvous(request, 0, MACH_PORT_NULL);
            return;
        }

        NSNumber *stored = gSteamMachRendezvousPorts[key];
        mach_port_t sendPort = stored
            ? (mach_port_t)stored.unsignedIntValue : MACH_PORT_NULL;
        if (!MACH_PORT_VALID(sendPort)) {
            ReplySteamMachRendezvous(request, ENOENT, MACH_PORT_NULL);
            return;
        }
        HostLog(@"Steam Mach rendezvous lookup name=%@ port=%u",
                key, sendPort);
        ReplySteamMachRendezvous(request, 0, sendPort);
    });
}

static BOOL WriteSteamSemaphoreWaitReply(int descriptor, int error,
                                         uint64_t generation,
                                         uint32_t value,
                                         uint64_t requestID) {
    MacWSSteamSemaphoreWaitReply reply = {
        .magic = MACWS_STEAM_SEM_WAIT_MAGIC,
        .version = MACWS_STEAM_SEM_VERSION,
        .error = error,
        .value = value,
        .generation = generation,
        .requestID = requestID,
    };
    const uint8_t *cursor = (const uint8_t *)&reply;
    size_t remaining = sizeof(reply);
    while (remaining != 0) {
        ssize_t amount = write(descriptor, cursor, remaining);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return NO;
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    return YES;
}

static uint64_t SteamSemaphoreHash(const char *name) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const unsigned char *cursor = (const unsigned char *)name;
         *cursor; cursor++) {
        hash ^= *cursor;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void SteamSemaphoreHostPath(const MacWSSteamSemaphoreEntry *entry,
                                   char *path, size_t pathSize) {
    snprintf(path, pathSize,
             "/var/mnt/rootfs/private/tmp/"
             ".macws-steam-sem-%016llx-%016llx",
             (unsigned long long)SteamSemaphoreHash(entry->name),
             (unsigned long long)entry->generation);
}

static int CreateSteamSemaphoreState(MacWSSteamSemaphoreEntry *entry,
                                     uint32_t initialValue) {
    char path[PATH_MAX] = {0};
    SteamSemaphoreHostPath(entry, path, sizeof(path));
    int descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
                          0600);
    if (descriptor < 0) return errno;
    MacWSSteamSemaphoreState state = {
        .magic = MACWS_STEAM_SEM_STATE_MAGIC,
        .version = MACWS_STEAM_SEM_STATE_VERSION,
        .value = initialValue,
        .revision = 1,
        .brokerGeneration = entry->generation,
    };
    strlcpy(state.name, entry->name, sizeof(state.name));
    int error = 0;
    if (fchown(descriptor, 501, 501) != 0 ||
        fchmod(descriptor, 0600) != 0 ||
        pwrite(descriptor, &state, sizeof(state), 0) !=
            (ssize_t)sizeof(state) ||
        ftruncate(descriptor, sizeof(state)) != 0)
        error = errno ?: EIO;
    close(descriptor);
    if (error != 0) (void)unlink(path);
    return error;
}

static void UnlinkSteamSemaphoreState(
        const MacWSSteamSemaphoreEntry *entry) {
    char path[PATH_MAX] = {0};
    SteamSemaphoreHostPath(entry, path, sizeof(path));
    (void)unlink(path);
}

static void DestroySteamSemaphoreEntry(MacWSSteamSemaphoreEntry *entry) {
    if (!entry) return;
    for (uint32_t index = 0; index < entry->waiterCount; index++) {
        if (MACH_PORT_VALID(entry->waiterPorts[index]))
            (void)mach_port_deallocate(
                mach_task_self(), entry->waiterPorts[index]);
    }
    for (uint32_t index = 0; index < entry->waiterSocketCount; index++) {
        int descriptor = entry->waiterSockets[index];
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, ECANCELED, entry->generation, entry->value,
            entry->waiterSocketRequestIDs[index]);
        close(descriptor);
    }
    free(entry);
}

static void RemoveSteamSemaphoreSocketWaiter(
        MacWSSteamSemaphoreEntry *entry, uint32_t index) {
    if (!entry || index >= entry->waiterSocketCount) return;
    entry->waiterSocketCount--;
    if (index == entry->waiterSocketCount) return;
    size_t remaining = entry->waiterSocketCount - index;
    memmove(&entry->waiterSockets[index],
            &entry->waiterSockets[index + 1],
            remaining * sizeof(entry->waiterSockets[0]));
    memmove(&entry->waiterSocketRequestIDs[index],
            &entry->waiterSocketRequestIDs[index + 1],
            remaining * sizeof(entry->waiterSocketRequestIDs[0]));
    memmove(&entry->waiterSocketIDs[index],
            &entry->waiterSocketIDs[index + 1],
            remaining * sizeof(entry->waiterSocketIDs[0]));
}

static BOOL GrantSteamSemaphoreSocketWaiter(
        MacWSSteamSemaphoreEntry *entry, BOOL diagnostics) {
    while (entry && entry->waiterSocketCount != 0) {
        int descriptor = entry->waiterSockets[0];
        uint64_t requestID = entry->waiterSocketRequestIDs[0];
        uint64_t waiter = entry->waiterSocketIDs[0];
        RemoveSteamSemaphoreSocketWaiter(entry, 0);
        BOOL delivered = WriteSteamSemaphoreWaitReply(
            descriptor, 0, entry->generation, entry->value, requestID);
        close(descriptor);
        if (!delivered) continue;
        if (diagnostics)
            HostLog(@"Steam semaphore EVFILT_READ wake generation=%llu "
                    "waiter=%llu request=%llu remaining=%u",
                    entry->generation, waiter, requestID,
                    entry->waiterSocketCount);
        return YES;
    }
    return NO;
}

static BOOL SteamSemaphoreDiagnosticsEnabled(xpc_object_t request) {
    return getenv("MACWS_STEAM_SEM_DIAGNOSTICS") != NULL ||
        xpc_dictionary_get_bool(request,
            MACWS_STEAM_SEM_KEY_DIAGNOSTICS);
}

static BOOL ReplySteamSemaphore(xpc_object_t request, int error,
                                uint64_t generation, BOOL created) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
    if (diagnostics)
        HostLog(@"Steam semaphore reply request=%p peer=%p reply=%p "
                "error=%d generation=%llu", request, peer, reply, error,
                generation);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_SEM_KEY_ERROR, error);
    if (error == 0 && generation != 0) {
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_GENERATION,
                                  generation);
        xpc_dictionary_set_bool(reply, MACWS_STEAM_SEM_KEY_CREATED, created);
    }
    xpc_connection_send_message(peer, reply);
    return YES;
}

static BOOL ReplySteamSemaphoreValue(xpc_object_t request, int error,
                                     uint64_t generation, uint32_t value) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
    // EAGAIN is the expected zero-value polling result. Logging every such
    // result changed the system being measured: runtime sampling showed
    // hostd at 92.8% CPU and thousands of lines per second for one generation,
    // while another connection remained on its first reply port. Preserve
    // diagnostics for state transitions and actual errors only.
    if (diagnostics && error != EAGAIN)
        HostLog(@"Steam semaphore value reply request=%p peer=%p reply=%p "
                "error=%d generation=%llu value=%u", request, peer, reply,
                error, generation, value);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_SEM_KEY_ERROR, error);
    if (error == 0) {
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_GENERATION,
                                  generation);
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_VALUE, value);
    }
    xpc_connection_send_message(peer, reply);
    return YES;
}

static BOOL ReadSteamSemaphoreWaitRequest(
        int descriptor, MacWSSteamSemaphoreWaitRequest *request) {
    uint8_t *cursor = (uint8_t *)request;
    size_t remaining = sizeof(*request);
    while (remaining != 0) {
        ssize_t amount = read(descriptor, cursor, remaining);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return NO;
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    return YES;
}

static void RemoveSteamSemaphorePollingWaiter(
        MacWSSteamSemaphoreEntry *entry, uint32_t index) {
    if (!entry || index >= entry->pollingWaiterCount) return;
    entry->pollingWaiterCount--;
    if (index == entry->pollingWaiterCount) return;
    memmove(&entry->pollingWaiters[index],
            &entry->pollingWaiters[index + 1],
            (entry->pollingWaiterCount - index) *
                sizeof(entry->pollingWaiters[0]));
    memmove(&entry->pollingWaiterGranted[index],
            &entry->pollingWaiterGranted[index + 1],
            (entry->pollingWaiterCount - index) *
                sizeof(entry->pollingWaiterGranted[0]));
}

static BOOL GrantSteamSemaphorePollingWaiter(
        MacWSSteamSemaphoreEntry *entry, BOOL diagnostics) {
    for (uint32_t index = 0; index < entry->pollingWaiterCount;) {
        if (entry->pollingWaiterGranted[index]) {
            index++;
            continue;
        }
        uint64_t waiter = entry->pollingWaiters[index];
        pid_t waiterPID = (pid_t)(waiter >> 32);
        entry->pollingWaiterGranted[index] = 1;
        if (waiterPID > 1 && kill(waiterPID, SIGUSR2) == 0) {
            if (diagnostics)
                HostLog(@"Steam semaphore FIFO grant generation=%llu "
                        "waiter=%llu pid=%d signal=%d position=%u waiters=%u",
                        entry->generation, waiter, waiterPID, SIGUSR2, index,
                        entry->pollingWaiterCount);
            return YES;
        }
        int signalError = waiterPID <= 1 ? EINVAL : errno;
        if (diagnostics)
            HostLog(@"Steam semaphore FIFO signal failed generation=%llu "
                    "waiter=%llu pid=%d errno=%d",
                    entry->generation, waiter, waiterPID, signalError);
        RemoveSteamSemaphorePollingWaiter(entry, index);
    }
    return NO;
}

static void ServeSteamSemaphoreWaitDescriptor(int descriptor) {
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                     &enabled, sizeof(enabled));
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout));

    pid_t peerPID = 0;
    socklen_t peerPIDSize = sizeof(peerPID);
    int peerResult = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID,
                                &peerPID, &peerPIDSize);
    if (peerResult != 0 || peerPIDSize != sizeof(peerPID) || peerPID <= 1) {
        int peerError = peerResult == 0 ? EACCES : errno;
        HostLog(@"Steam semaphore socket peer rejected fd=%d result=%d "
                "errno=%d size=%u peer=%d", descriptor, peerResult,
                peerError, peerPIDSize, peerPID);
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, peerError, 0, 0, 0);
        close(descriptor);
        return;
    }

    MacWSSteamSemaphoreWaitRequest request = {0};
    BOOL readRequest = ReadSteamSemaphoreWaitRequest(descriptor, &request);
    BOOL validRequest = readRequest &&
        request.magic == MACWS_STEAM_SEM_WAIT_MAGIC &&
        request.version == MACWS_STEAM_SEM_VERSION &&
        request.generation != 0 && !(request.reserved &
            ~MACWS_STEAM_SEM_SOCKET_FLAG_DIAGNOSTICS) &&
        request.requestID != 0 &&
        (pid_t)(request.waiter >> 32) == peerPID &&
        request.operation >= MACWS_STEAM_SEM_SOCKET_WAIT_POLL &&
        request.operation <= MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK;
    if (!validRequest) {
        int readError = readRequest ? 0 : errno;
        HostLog(@"Steam semaphore socket request rejected fd=%d read=%d "
                "errno=%d peer=%d magic=%#x version=%u op=%u flags=%#x "
                "generation=%llu waiter=%llu waiter_pid=%d request=%llu",
                descriptor, readRequest, readError, peerPID, request.magic,
                request.version, request.operation, request.reserved,
                request.generation, request.waiter,
                (pid_t)(request.waiter >> 32), request.requestID);
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, EPROTO, request.generation, 0,
            request.requestID);
        close(descriptor);
        return;
    }

    dispatch_async(gSteamSemaphoreQueue, ^{
        BOOL diagnostics = (request.reserved &
            MACWS_STEAM_SEM_SOCKET_FLAG_DIAGNOSTICS) != 0;
        if (diagnostics && request.operation !=
                MACWS_STEAM_SEM_SOCKET_GETVALUE)
            HostLog(@"Steam semaphore socket request id=%llu op=%u "
                    "generation=%llu waiter=%llu peer=%d",
                    request.requestID, request.operation,
                    request.generation, request.waiter, peerPID);
        MacWSSteamSemaphoreEntry *entry =
            gSteamSemaphoreGenerations[@(request.generation)].pointerValue;
        if (!entry || entry->references == 0) {
            (void)WriteSteamSemaphoreWaitReply(
                descriptor, EINVAL, request.generation, 0,
                request.requestID);
            close(descriptor);
            return;
        }
        int replyError = 0;
        uint32_t replyValue = entry->value;

        if (request.operation == MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK) {
            if (entry->value != 0) {
                entry->value--;
                replyValue = entry->value;
            } else if (entry->waiterSocketCount >=
                       sizeof(entry->waiterSockets) /
                           sizeof(entry->waiterSockets[0])) {
                replyError = ENOSPC;
            } else {
                uint32_t index = entry->waiterSocketCount++;
                entry->waiterSockets[index] = descriptor;
                entry->waiterSocketRequestIDs[index] = request.requestID;
                entry->waiterSocketIDs[index] = request.waiter;
                if (diagnostics)
                    HostLog(@"Steam semaphore EVFILT_READ enqueue "
                            "generation=%llu waiter=%llu request=%llu "
                            "position=%u waiters=%u",
                            entry->generation, request.waiter,
                            request.requestID, index,
                            entry->waiterSocketCount);
                // Ownership of descriptor moved to the FIFO. A later post,
                // unlink/reset or peer failure writes/closes it.
                return;
            }
        } else if (request.operation == MACWS_STEAM_SEM_SOCKET_WAIT_POLL) {
            if (request.waiter == 0) {
                replyError = EINVAL;
            } else {
                uint32_t index = 0;
                for (; index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] == request.waiter) break;
                }
                if (index == entry->pollingWaiterCount) {
                    if (index >= sizeof(entry->pollingWaiters) /
                                     sizeof(entry->pollingWaiters[0])) {
                        replyError = ENOSPC;
                    } else {
                        entry->pollingWaiters[index] = request.waiter;
                        entry->pollingWaiterGranted[index] = 0;
                        entry->pollingWaiterCount++;
                        if (entry->value != 0) {
                            entry->value--;
                            entry->pollingWaiterGranted[index] = 1;
                        }
                        if (diagnostics)
                            HostLog(@"Steam semaphore socket FIFO enqueue "
                                    "generation=%llu waiter=%llu granted=%u "
                                    "position=%u waiters=%u",
                                    entry->generation, request.waiter,
                                    entry->pollingWaiterGranted[index], index,
                                    entry->pollingWaiterCount);
                    }
                }
                if (replyError == 0)
                    replyValue = entry->pollingWaiterGranted[index] ? 1 : 0;
            }
        } else if (request.operation == MACWS_STEAM_SEM_SOCKET_TRYWAIT) {
            BOOL consumedGrant = NO;
            if (request.waiter != 0) {
                for (uint32_t index = 0;
                     index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] != request.waiter ||
                        !entry->pollingWaiterGranted[index]) continue;
                    RemoveSteamSemaphorePollingWaiter(entry, index);
                    consumedGrant = YES;
                    break;
                }
            }
            if (!consumedGrant) {
                if (entry->value == 0) replyError = EAGAIN;
                else entry->value--;
            }
            replyValue = entry->value;
        } else if (request.operation == MACWS_STEAM_SEM_SOCKET_POST) {
            if (!GrantSteamSemaphoreSocketWaiter(entry, diagnostics) &&
                !GrantSteamSemaphorePollingWaiter(entry, diagnostics)) {
                if (entry->value == MACWS_STEAM_SEM_VALUE_MAX)
                    replyError = EOVERFLOW;
                else entry->value++;
            }
            replyValue = entry->value;
        } else {
            replyValue = entry->value;
        }

        if (diagnostics && request.operation !=
                MACWS_STEAM_SEM_SOCKET_GETVALUE &&
            (replyError != EAGAIN || replyValue != 0))
            HostLog(@"Steam semaphore socket reply id=%llu op=%u "
                    "generation=%llu waiter=%llu error=%d value=%u",
                    request.requestID, request.operation,
                    request.generation, request.waiter, replyError,
                    replyValue);
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, replyError, entry->generation, replyValue,
            request.requestID);
        close(descriptor);
    });
}

static BOOL StartSteamSemaphoreWaitListener(void) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    int length = snprintf(path, sizeof(path), "%s%s", kRootFS,
                          MACWS_STEAM_SEM_WAIT_SOCKET_PATH);
    if (length <= 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return NO;
    }
    (void)unlink(path);
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return NO;
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                     &enabled, sizeof(enabled));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    struct passwd *mobileAccount = getpwnam("mobile");
    uid_t clientUID = mobileAccount ? mobileAccount->pw_uid : 501;
    gid_t clientGID = mobileAccount ? mobileAccount->pw_gid : 501;
    if (bind(descriptor, (const struct sockaddr *)&address,
             sizeof(address)) != 0 ||
        chown(path, clientUID, clientGID) != 0 ||
        chmod(path, 0600) != 0 || listen(descriptor, 64) != 0) {
        int savedError = errno;
        close(descriptor);
        (void)unlink(path);
        errno = savedError;
        return NO;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        int savedError = errno;
        close(descriptor);
        (void)unlink(path);
        errno = savedError;
        return NO;
    }

    gSteamSemaphoreWaitListenerDescriptor = descriptor;
    dispatch_queue_t listenerQueue = dispatch_queue_create(
        "com.macwsguide.hostd.steam-semaphore-wait-listener",
        DISPATCH_QUEUE_SERIAL);
    gSteamSemaphoreWaitListener = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, listenerQueue);
    dispatch_source_set_event_handler(gSteamSemaphoreWaitListener, ^{
        for (;;) {
            int client = accept(descriptor, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                if (errno != EAGAIN && errno != EWOULDBLOCK)
                    HostLog(@"Steam semaphore wait accept failed errno=%d",
                            errno);
                break;
            }
            // Runtime-confirmed on the real iPad: accepted descriptors inherit
            // O_NONBLOCK from this listener.  Before the client's first bytes
            // arrived, ReadSteamSemaphoreWaitRequest returned EAGAIN and the
            // server emitted an empty EPROTO envelope; Steam then reported
            // `Locked the ceiling, couldn't release the floor` for /MTX/.
            // Requests are fixed-size and SO_RCVTIMEO bounds a stalled peer,
            // so restore blocking mode on the connected descriptor before
            // reading the request.
            int clientFlags = fcntl(client, F_GETFL, 0);
            if (clientFlags < 0 ||
                fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) != 0) {
                int savedError = errno ?: EIO;
                HostLog(@"Steam semaphore accepted socket mode failed "
                        "fd=%d errno=%d", client, savedError);
                close(client);
                continue;
            }
            // Read and enqueue accepted requests on one serial listener queue.
            // THEORY under test: the previous global-queue hop could let the
            // high-rate GETVALUE client overtake an already accepted POST.
            // Request IDs in the diagnostic log make that ordering directly
            // observable; the actual counter mutation remains isolated on
            // gSteamSemaphoreQueue.
            ServeSteamSemaphoreWaitDescriptor(client);
        }
    });
    dispatch_source_set_cancel_handler(gSteamSemaphoreWaitListener, ^{
        close(descriptor);
    });
    dispatch_resume(gSteamSemaphoreWaitListener);
    HostLog(@"Steam semaphore wait listener published path=%s protocol=%u",
            path, MACWS_STEAM_SEM_VERSION);
    return YES;
}

static void ServeSteamSemaphoreRequest(xpc_object_t request,
                                       const char *operation) {
    // Keep this protocol independent of the GUI control queue. Steam's WebUI
    // handshakes can wait while another application launch is in progress;
    // applying the hostd "busy" gate here would deadlock an unrelated client.
    BOOL resetOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_RESET);
    BOOL openOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_OPEN);
    BOOL recreateOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_RECREATE);
    BOOL unlinkOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_UNLINK);
    BOOL delayOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_DELAY);
    BOOL tryWaitOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_TRYWAIT);
    BOOL waitPollOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_WAIT_POLL);
    BOOL postOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_POST);
    BOOL getValueOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_GETVALUE);
    BOOL registerWaitOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_REGISTER_WAIT);
    BOOL notifyOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_NOTIFY);

    if (delayOperation) {
        uint64_t microseconds = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_VALUE);
        // Runtime LLDB on the real Steam Helper showed that
        // macOS-originated nanosleep, kevent timers and thread_switch waits
        // never expire on this iOS kernel. A first host-side implementation
        // called usleep, but that blocked the broker itself in
        // __semwait_signal. Let iOS-native libdispatch own the deadline.
        //
        // This operation deliberately bypasses gSteamSemaphoreQueue. CEF can
        // issue a deadline while steam_osx is publishing a large batch of
        // logical names; deadline delivery must not depend on draining that
        // unrelated namespace traffic first.
        if (microseconds == 0 || microseconds > 100000) {
            ReplySteamSemaphore(request, EINVAL, 0, NO);
            return;
        }
        dispatch_after(dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(microseconds * NSEC_PER_USEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                ReplySteamSemaphore(request, 0, 0, NO);
            });
        return;
    }

    dispatch_async(gSteamSemaphoreQueue, ^{
        if (resetOperation) {
            const char *epoch = xpc_dictionary_get_string(
                request, MACWS_STEAM_SEM_KEY_EPOCH);
            if (!epoch || epoch[0] == '\0' || strnlen(epoch, 128) >= 128) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            NSString *requestedEpoch = @(epoch);
            if ([gSteamSemaphoreEpoch isEqualToString:requestedEpoch]) {
                ReplySteamSemaphore(request, 0, 0, NO);
                return;
            }
            NSArray<NSValue *> *entries =
                gSteamSemaphoreGenerations.allValues.copy;
            [gSteamSemaphoreNames removeAllObjects];
            [gSteamSemaphoreGenerations removeAllObjects];
            [gSteamSemaphoreUnlinkReceipts removeAllObjects];
            for (NSValue *value in entries) {
                MacWSSteamSemaphoreEntry *entry = value.pointerValue;
                UnlinkSteamSemaphoreState(entry);
                DestroySteamSemaphoreEntry(entry);
            }
            gSteamSemaphoreEpoch = requestedEpoch;
            HostLog(@"Steam semaphore namespace reset epoch=%@ count=%lu",
                    requestedEpoch, (unsigned long)entries.count);
            ReplySteamSemaphore(request, 0, 0, NO);
            return;
        }

        const char *name = xpc_dictionary_get_string(
            request, MACWS_STEAM_SEM_KEY_NAME);
        if (openOperation || recreateOperation) {
            if (!IsSteamSemaphoreName(name)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            BOOL created = NO;
            int flags = (int)xpc_dictionary_get_int64(
                request, MACWS_STEAM_SEM_KEY_FLAGS);
            uint64_t initialValue = xpc_dictionary_get_uint64(
                request, MACWS_STEAM_SEM_KEY_VALUE);
            NSString *key = @(name);
            MacWSSteamSemaphoreEntry *entry =
                gSteamSemaphoreNames[key].pointerValue;
            if (recreateOperation) {
                uint64_t receipt = xpc_dictionary_get_uint64(
                    request, MACWS_STEAM_SEM_KEY_GENERATION);
                NSNumber *expected = gSteamSemaphoreUnlinkReceipts[key];
                if (!(flags & O_CREAT) || !(flags & O_EXCL) || receipt == 0 ||
                    !expected || expected.unsignedLongLongValue != receipt) {
                    ReplySteamSemaphore(request, ESTALE, 0, NO);
                    return;
                }
                [gSteamSemaphoreUnlinkReceipts removeObjectForKey:key];
                uint64_t replacedGeneration = 0;
                if (entry) {
                    replacedGeneration = entry->generation;
                    [gSteamSemaphoreNames removeObjectForKey:key];
                    entry->unlinked = YES;
                    UnlinkSteamSemaphoreState(entry);
                    if (entry->references == 0) {
                        [gSteamSemaphoreGenerations
                            removeObjectForKey:@(entry->generation)];
                        DestroySteamSemaphoreEntry(entry);
                    }
                    entry = NULL;
                }
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore atomic recreate name=%s "
                            "receipt=%llu replaced-generation=%llu",
                            name, receipt, replacedGeneration);
            }
            if (entry && (flags & O_CREAT) && (flags & O_EXCL)) {
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore open EEXIST name=%s "
                            "flags=%#x initial=%llu generation=%llu "
                            "references=%u unlinked=%d",
                            name, flags, initialValue, entry->generation,
                            entry->references, entry->unlinked);
                ReplySteamSemaphore(request, EEXIST, 0, NO);
                return;
            }
            if (!entry && !(flags & O_CREAT)) {
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore open ENOENT name=%s "
                            "flags=%#x initial=%llu",
                            name, flags, initialValue);
                ReplySteamSemaphore(request, ENOENT, 0, NO);
                return;
            }
            if (!entry) {
                if (initialValue > INT32_MAX) {
                    ReplySteamSemaphore(request, EINVAL, 0, NO);
                    return;
                }
                entry = calloc(1, sizeof(*entry));
                if (!entry) {
                    ReplySteamSemaphore(request, ENOMEM, 0, NO);
                    return;
                }
                entry->generation = ++gSteamSemaphoreNextGeneration;
                entry->value = (uint32_t)initialValue;
                strlcpy(entry->name, name, sizeof(entry->name));
                int createError = CreateSteamSemaphoreState(
                    entry, (uint32_t)initialValue);
                if (createError != 0) {
                    DestroySteamSemaphoreEntry(entry);
                    ReplySteamSemaphore(request, createError, 0, NO);
                    return;
                }
                NSValue *value = [NSValue valueWithPointer:entry];
                gSteamSemaphoreNames[key] = value;
                gSteamSemaphoreGenerations[@(entry->generation)] = value;
                created = YES;
            }
            if (entry->references == UINT32_MAX) {
                ReplySteamSemaphore(request, EMFILE, 0, NO);
                return;
            }
            entry->references++;
            ReplySteamSemaphore(request, 0, entry->generation, created);
            return;
        }

        if (unlinkOperation) {
            if (!IsSteamSemaphoreName(name)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            NSString *key = @(name);
            MacWSSteamSemaphoreEntry *entry =
                gSteamSemaphoreNames[key].pointerValue;
            if (!entry) {
                ReplySteamSemaphore(request, ENOENT, 0, NO);
                return;
            }
            [gSteamSemaphoreNames removeObjectForKey:key];
            entry->unlinked = YES;
            uint64_t generation = entry->generation;
            gSteamSemaphoreUnlinkReceipts[key] = @(generation);
            UnlinkSteamSemaphoreState(entry);
            if (entry->references == 0) {
                [gSteamSemaphoreGenerations
                    removeObjectForKey:@(entry->generation)];
                DestroySteamSemaphoreEntry(entry);
            }
            ReplySteamSemaphore(request, 0, generation, NO);
            return;
        }

        uint64_t generation = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_GENERATION);
        MacWSSteamSemaphoreEntry *entry =
            gSteamSemaphoreGenerations[@(generation)].pointerValue;
        if (!entry || entry->references == 0) {
            ReplySteamSemaphore(request, EINVAL, 0, NO);
            return;
        }

        uint64_t waiter = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_WAITER);

        // Legacy XPC high-frequency adapter retained only for protocol
        // diagnostics and older clients. Protocol v21 clients mutate the same
        // authoritative counter through the Unix-stream listener above;
        // blocking waits leave their connected descriptor in a FIFO until a
        // post writes the exact reply. Runtime v18 proved that an ordinary
        // blocking read could miss a cross-runtime stream wake, so v21 clients
        // block through measured-good kqueue/EVFILT_READ instead.
        if (tryWaitOperation) {
            if (waiter != 0) {
                for (uint32_t index = 0;
                     index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] != waiter ||
                        !entry->pollingWaiterGranted[index]) continue;
                    entry->pollingWaiterCount--;
                    if (index != entry->pollingWaiterCount) {
                        memmove(&entry->pollingWaiters[index],
                                &entry->pollingWaiters[index + 1],
                                (entry->pollingWaiterCount - index) *
                                    sizeof(entry->pollingWaiters[0]));
                        memmove(&entry->pollingWaiterGranted[index],
                                &entry->pollingWaiterGranted[index + 1],
                                (entry->pollingWaiterCount - index) *
                                    sizeof(entry->pollingWaiterGranted[0]));
                    }
                    ReplySteamSemaphoreValue(
                        request, 0, generation, entry->value);
                    return;
                }
            }
            if (entry->value == 0) {
                // A synchronous client cannot enqueue its next poll until it
                // receives this reply. Yield once before replying so the XPC
                // listener can enqueue work from another Steam process or
                // generation; this is a fairness boundary, not a fabricated
                // timeout or semaphore token.
                sched_yield();
                ReplySteamSemaphoreValue(request, EAGAIN, generation, 0);
                return;
            }
            entry->value--;
            ReplySteamSemaphoreValue(request, 0, generation, entry->value);
            return;
        }

        if (postOperation) {
            BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
            if (GrantSteamSemaphoreSocketWaiter(entry, diagnostics) ||
                GrantSteamSemaphorePollingWaiter(entry, diagnostics)) {
                ReplySteamSemaphoreValue(
                    request, 0, generation, entry->value);
                return;
            }
            if (entry->value == MACWS_STEAM_SEM_VALUE_MAX) {
                ReplySteamSemaphoreValue(request, EOVERFLOW, generation,
                                         entry->value);
                return;
            }
            entry->value++;
            ReplySteamSemaphoreValue(request, 0, generation, entry->value);
            return;
        }

        if (getValueOperation) {
            ReplySteamSemaphoreValue(request, 0, generation, entry->value);
            return;
        }

        if (waitPollOperation) {
            if (waiter == 0) {
                ReplySteamSemaphoreValue(request, EINVAL, generation, 0);
                return;
            }
            for (uint32_t index = 0;
                 index < entry->pollingWaiterCount; index++) {
                if (entry->pollingWaiters[index] != waiter) continue;
                ReplySteamSemaphoreValue(
                    request, 0, generation,
                    entry->pollingWaiterGranted[index] ? 1 : 0);
                return;
            }
            if (entry->pollingWaiterCount >=
                sizeof(entry->pollingWaiters) /
                    sizeof(entry->pollingWaiters[0])) {
                ReplySteamSemaphoreValue(request, ENOSPC, generation, 0);
                return;
            }
            uint32_t index = entry->pollingWaiterCount++;
            entry->pollingWaiters[index] = waiter;
            if (entry->value != 0) {
                entry->value--;
                entry->pollingWaiterGranted[index] = 1;
            }
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore FIFO enqueue generation=%llu "
                        "waiter=%llu granted=%u position=%u waiters=%u",
                        generation, waiter,
                        entry->pollingWaiterGranted[index], index,
                        entry->pollingWaiterCount);
            ReplySteamSemaphoreValue(
                request, 0, generation,
                entry->pollingWaiterGranted[index] ? 1 : 0);
            return;
        }

        if (registerWaitOperation) {
            mach_port_t port = xpc_dictionary_copy_mach_send(
                request, MACWS_STEAM_SEM_KEY_WAIT_PORT);
            if (!MACH_PORT_VALID(port)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            BOOL duplicate = NO;
            for (uint32_t index = 0; index < entry->waiterCount; index++) {
                if (entry->waiterPorts[index] == port) {
                    duplicate = YES;
                    break;
                }
            }
            if (duplicate) {
                (void)mach_port_deallocate(mach_task_self(), port);
            } else if (entry->waiterCount >=
                       sizeof(entry->waiterPorts) /
                           sizeof(entry->waiterPorts[0])) {
                (void)mach_port_deallocate(mach_task_self(), port);
                ReplySteamSemaphore(request, ENOSPC, 0, NO);
                return;
            } else {
                entry->waiterPorts[entry->waiterCount++] = port;
            }
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore registered wake port "
                        "generation=%llu port=%u waiters=%u",
                        generation, port, entry->waiterCount);
            ReplySteamSemaphore(request, 0, generation, NO);
            return;
        }

        if (notifyOperation) {
            mach_msg_header_t message = {0};
            message.msgh_bits = MACH_MSGH_BITS(
                MACH_MSG_TYPE_COPY_SEND, 0);
            message.msgh_size = sizeof(message);
            message.msgh_id = 0x4d5753;
            uint32_t output = 0;
            for (uint32_t index = 0; index < entry->waiterCount; index++) {
                mach_port_t port = entry->waiterPorts[index];
                message.msgh_remote_port = port;
                mach_msg_return_t sendResult = mach_msg(
                    &message, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    sizeof(message), 0, MACH_PORT_NULL, 0,
                    MACH_PORT_NULL);
                if (sendResult == MACH_SEND_INVALID_DEST) {
                    // The failed mach_msg has already disposed the invalid
                    // destination name.  Deallocating that numeric name a
                    // second time is not a harmless KERN_INVALID_NAME on this
                    // iOS kernel: the task has a Mach-port guard and is killed
                    // with EXC_GUARD/INVALID_NAME.  Runtime witness from the
                    // production Steam bootstrap (2026-08-14):
                    //
                    //   macwshostd[98055] SIGKILL
                    //   GUARD_TYPE_MACH_PORT INVALID_NAME on mach port 35075
                    //
                    // Removing the dead destination from the waiter table is
                    // the complete ownership transition after this send
                    // result; there is no remaining right to release.
                    continue;
                }
                entry->waiterPorts[output++] = port;
            }
            entry->waiterCount = output;
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore notify generation=%llu "
                        "waiters=%u", generation, output);
            return;
        }

        entry->references--;
        if (entry->unlinked && entry->references == 0) {
            [gSteamSemaphoreGenerations removeObjectForKey:@(generation)];
            DestroySteamSemaphoreEntry(entry);
        }
        ReplySteamSemaphore(request, 0, 0, NO);
    });
}

static void ServeRequest(xpc_object_t request) {
    if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
    const char *op = xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_OP);
    if (!op) {
        ReplyResult(request, NO, @"缺少操作类型", nil);
        return;
    }
    if (IsSteamSemaphoreOperation(op)) {
        ServeSteamSemaphoreRequest(request, op);
        return;
    }
    if (IsSteamMachRendezvousOperation(op)) {
        ServeSteamMachRendezvousRequest(request, op);
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
            os_unfair_lock_lock(&gStateLock);
            gStartupOperationActive = YES;
            gStartupRetryAvailable = NO;
            gStartupBeganAt = time(NULL);
            os_unfair_lock_unlock(&gStateLock);
            BOOL experimental = xpc_dictionary_get_bool(request, MACWS_CONTROL_KEY_EXPERIMENTAL);
            ok = StartGUI(experimental, &message);
            os_unfair_lock_lock(&gStateLock);
            gStartupOperationActive = NO;
            gStartupRetryAvailable = !ok;
            os_unfair_lock_unlock(&gStateLock);
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
        gSteamSemaphoreQueue = dispatch_queue_create(
            "com.macwsguide.hostd.steam-semaphore", DISPATCH_QUEUE_SERIAL);
        gSteamMachRendezvousQueue = dispatch_queue_create(
            "com.macwsguide.hostd.steam-mach-rendezvous",
            DISPATCH_QUEUE_SERIAL);
        gSteamSemaphoreNames = [NSMutableDictionary dictionary];
        gSteamMachRendezvousPorts = [NSMutableDictionary dictionary];
        gSteamSemaphoreGenerations = [NSMutableDictionary dictionary];
        gSteamSemaphoreUnlinkReceipts = [NSMutableDictionary dictionary];
        gSteamSemaphoreNextGeneration =
            ((uint64_t)arc4random() << 32) | arc4random();
        if (gSteamSemaphoreNextGeneration == UINT64_MAX)
            gSteamSemaphoreNextGeneration = 1;
        if (!StartSteamSemaphoreWaitListener()) {
            HostLog(@"failed to publish Steam semaphore wait listener "
                    "errno=%d", errno);
            return 1;
        }
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
