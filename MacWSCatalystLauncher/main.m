@import Darwin;
@import UIKit;

#include "macws_macho_arch.h"

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define MACWS_PROC_PIDPATH_MAX 4096

static const char *const kMacWSRoot = "/var/mnt/rootfs";
static const char *const kMapsExecutable =
    "/System/Applications/Maps.app/Contents/MacOS/Maps";
static const char *const kMapsHostExecutable =
    "/var/mnt/rootfs/System/Applications/Maps.app/Contents/MacOS/Maps";
static const char *const kChrootExec =
    "/var/jb/usr/macOS/bin/launchdchrootexec";
static const char *const kHostCarrierMarker =
    "/var/jb/var/mobile/macws-maps-host-carrier.pid";
static pid_t gMapsPID = -1;

static pid_t macws_live_host_carried_maps_pid(void) {
    int marker = open(kHostCarrierMarker, O_RDONLY | O_CLOEXEC);
    if (marker < 0) return 0;
    char value[32] = {0};
    ssize_t count = read(marker, value, sizeof(value) - 1);
    close(marker);
    int candidate = 0;
    if (count <= 0 || sscanf(value, "%d", &candidate) != 1 || candidate <= 1)
        return 0;
    char path[MACWS_PROC_PIDPATH_MAX] = {0};
    if (proc_pidpath(candidate, path, sizeof(path)) <= 0 ||
        strcmp(path, kMapsExecutable) != 0) return 0;
    return (pid_t)candidate;
}

static bool macws_configure_maps_environment(void) {
    macws_macho_arch_t arch = macws_macho_arch_for_path(kMapsHostExecutable);
    const char *insert = macws_insert_dylib_for_arch(arch);
    if (!insert) return false;
    setenv("DYLD_INSERT_LIBRARIES", insert, 1);
    setenv("HOME", "/Users/root", 1);
    setenv("USER", "root", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("MallocNanoZone", "0", 1);
    setenv("CA_DISABLE_SWAP_ICC", "1", 1);
    setenv("CA_VSYNC_OFF", "1", 1);
    setenv("MACWS_AGX_NATIVE", "1", 1);
    setenv("MACWS_AGX_REGISTER_CLASSES", "1", 1);
    setenv("MACWS_PIN_FALLBACK", "1", 1);
    setenv("COMMAND_MODE", "unix2003", 1);
    setenv("__CFBundleIdentifier", "com.apple.Maps", 1);
    setenv("MACWS_CATALYST_REQUEST_INITIAL_SCENE", "1", 1);
    setenv("MACWS_CATALYST_REGISTER_APPLICATION", "1", 1);
    setenv("APPLICATION_SUPPORT_SERVICE_MACH_NAME",
           "com.apple.macosbooter.frontboard.systemappservices", 1);
    return true;
}

// MacWSHost is already a foreground UIApplication with a valid live
// FrontBoard scene.  In this mode the setuid helper does not create a second
// UIKit scene: it immediately replaces only itself with the chroot exec
// carrier.  The resulting Maps process remains a direct child of MacWSHost,
// while the Host keeps its fullscreen workspace and input connection alive.
static int macws_exec_maps_from_existing_host(void) {
    if (geteuid() != 0) return 77;
    if (macws_live_host_carried_maps_pid() > 1) return 0;
    if (!macws_configure_maps_environment()) return 78;
    int marker = open(kHostCarrierMarker,
                      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (marker >= 0) {
        char value[32];
        int length = snprintf(value, sizeof(value), "%d\n", getpid());
        if (length > 0) (void)write(marker, value, (size_t)length);
        close(marker);
    }
    char *const childArgv[] = {
        (char *)kChrootExec, "0", "0", (char *)kMacWSRoot,
        (char *)kMapsExecutable, NULL,
    };
    execv(kChrootExec, childArgv);
    return errno ? errno : 78;
}

static void macws_open_launcher_log(void) {
    int fd = open("/var/jb/var/mobile/catalyst-launcher.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)dup2(fd, STDOUT_FILENO);
    (void)dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) close(fd);
}

static void macws_spawn_maps(void) {
    if (gMapsPID > 1 && (kill(gMapsPID, 0) == 0 || errno == EPERM)) return;

    // Keep the iOS UIApplication carrier alive after it has completed its real
    // FrontBoard scene handshake.  SETEXEC used to preserve the numeric PID,
    // but runtime evidence from SpringBoard showed that exec invalidates the
    // carrier's workspace connection and immediately marks that RBS process as
    // pending exit.  Maps could create two real AppKit windows, then iOS reaped
    // it roughly 45 seconds later.  A separate chroot child gives Maps its own
    // exec generation while the carrier continues to own the live iOS scene.
    // UIKitSystem validates the child's audit token and executable path before
    // registering that exact generation through FrontBoard's native bootstrap.
    if (seteuid(0) < 0) {
        perror("[MacWSCatalystLauncher] restore root euid");
        return;
    }
    fprintf(stderr,
            "[MacWSCatalystLauncher] UIKit lifecycle active; spawning Maps "
            "pid=%d uid=%d euid=%d\n",
            getpid(), getuid(), geteuid());
    fflush(stderr);

    if (geteuid() != 0) {
        fprintf(stderr,
                "[MacWSCatalystLauncher] root transition unavailable; "
                "refusing to fabricate a Catalyst process identity\n");
        return;
    }

    if (!macws_configure_maps_environment()) {
        fprintf(stderr,
                "[MacWSCatalystLauncher] unsupported Maps architecture\n");
        (void)seteuid(getuid());
        return;
    }
    // Complete UIKitMacHelper's native process-support handshake and initial
    // scene request through the live carrier.  UIKitSystem validates the Maps
    // child's real audit token and exact exec generation; no UIScreen or
    // application predicate is fabricated.  Verbose CATALYST_TRACE is
    // intentionally absent from the production environment.
    char *const childArgv[] = {
        (char *)kChrootExec, "0", "0", (char *)kMacWSRoot,
        (char *)kMapsExecutable, NULL,
    };
    extern char **environ;
    pid_t child = 0;
    int error = posix_spawn(&child, kChrootExec, NULL, NULL, childArgv,
                            environ);
    int restoreError = seteuid(getuid());
    if (error != 0) {
        errno = error;
        perror("[MacWSCatalystLauncher] posix_spawn Maps child");
        return;
    }
    if (restoreError < 0)
        perror("[MacWSCatalystLauncher] restore mobile euid");

    gMapsPID = child;
    fprintf(stderr,
            "[MacWSCatalystLauncher] Maps child started carrier=%d child=%d\n",
            getpid(), child);
    fflush(stderr);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t waited = 0;
        do {
            waited = waitpid(child, &status, 0);
        } while (waited < 0 && errno == EINTR);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gMapsPID == child) gMapsPID = -1;
            if (waited == child) {
                if (WIFEXITED(status)) {
                    fprintf(stderr,
                            "[MacWSCatalystLauncher] Maps child=%d exited "
                            "status=%d\n",
                            child, WEXITSTATUS(status));
                } else if (WIFSIGNALED(status)) {
                    fprintf(stderr,
                            "[MacWSCatalystLauncher] Maps child=%d signaled "
                            "%d\n",
                            child, WTERMSIG(status));
                }
            } else {
                fprintf(stderr,
                        "[MacWSCatalystLauncher] Maps child=%d wait failed "
                        "errno=%d\n",
                        child, errno);
            }
            fflush(stderr);
        });
    });
}

@interface MacWSCatalystLauncherDelegate : UIResponder <UIApplicationDelegate>
@end

@interface MacWSCatalystLauncherSceneDelegate
    : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

static void macws_schedule_exec_maps(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        macws_spawn_maps();
    });
}

@implementation MacWSCatalystLauncherSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    (void)session;
    (void)connectionOptions;
    fprintf(stderr,
            "[MacWSCatalystLauncher] UIScene connected class=%s pid=%d\n",
            object_getClassName(scene), getpid());
    fflush(stderr);
    // A connected UIWindowScene is a concrete witness that UIKit completed
    // the process-support and FrontBoard scene handshake.  Only then start the
    // chroot child, while retaining this carrier and its live workspace link.
    macws_schedule_exec_maps();
}

@end

@implementation MacWSCatalystLauncherDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    fprintf(stderr,
            "[MacWSCatalystLauncher] UIApplication didFinishLaunching "
            "pid=%d\n",
            getpid());
    fflush(stderr);
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    // Legacy-scene fallback.  The normal iPadOS 16 path schedules from the
    // scene delegate above after receiving a real UIWindowScene.
    macws_schedule_exec_maps();
}

@end


int main(int argc, char *argv[]) {
    @autoreleasepool {
        macws_open_launcher_log();
        fprintf(stderr, "[MacWSCatalystLauncher] pid=%d uid=%d euid=%d\n",
                getpid(), getuid(), geteuid());
        fflush(stderr);
        if (geteuid() != 0) {
            fprintf(stderr,
                    "[MacWSCatalystLauncher] setuid-root installation is "
                    "required before UIApplicationMain\n");
            return 77;
        }
        if (argc == 2 && strcmp(argv[1], "--exec-maps-from-host") == 0)
            return macws_exec_maps_from_existing_host();
        uid_t launchUser = getuid();
        if (seteuid(launchUser) < 0) {
            perror("[MacWSCatalystLauncher] enter mobile UIKit identity");
            return 77;
        }
        fprintf(stderr,
                "[MacWSCatalystLauncher] entering UIApplicationMain "
                "uid=%d euid=%d\n",
                getuid(), geteuid());
        fflush(stderr);
        return UIApplicationMain(
            argc, argv, nil,
            NSStringFromClass([MacWSCatalystLauncherDelegate class]));
    }
}
