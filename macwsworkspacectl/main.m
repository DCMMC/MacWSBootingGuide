#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ptrauth.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <sys/un.h>

#import "../include/macws_host_protocol.h"

extern char **environ;

static int SetWallpaper(const char *pathBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    if (path.length == 0 || ![[NSFileManager defaultManager]
            fileExistsAtPath:path]) {
        fprintf(stderr, "macwsworkspacectl: wallpaper does not exist: %s\n",
                pathBytes ?: "(null)");
        return 66;
    }

    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count == 0) {
        fprintf(stderr, "macwsworkspacectl: no AppKit screens are available\n");
        return 69;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    for (NSScreen *screen in screens) {
        NSError *error = nil;
        BOOL changed = [workspace setDesktopImageURL:url
                                          forScreen:screen
                                            options:@{}
                                              error:&error];
        if (!changed) {
            fprintf(stderr,
                    "macwsworkspacectl: set wallpaper failed for %s: %s\n",
                    screen.localizedName.UTF8String ?: "(unnamed)",
                    error.description.UTF8String ?: "unknown error");
            return 1;
        }
    }
    fprintf(stdout, "wallpaper-ready screens=%lu path=%s\n",
            (unsigned long)screens.count, path.fileSystemRepresentation);
    return 0;
}

static int ShowLaunchpad(void) {
    static const char *const executable =
        "/System/Applications/Launchpad.app/Contents/MacOS/Launchpad";
    pid_t pid = 0;
    char *const arguments[] = {(char *)executable, NULL};
    int spawnError = posix_spawn(&pid, executable, NULL, NULL,
                                 arguments, environ);
    if (spawnError != 0) {
        fprintf(stderr,
                "macwsworkspacectl: Launchpad spawn failed: %s\n",
                strerror(spawnError));
        return spawnError;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return errno;
    if (!WIFEXITED(status)) return 1;
    return WEXITSTATUS(status);
}

static int RegisterSettingsExtension(void) {
    static NSString *const path =
        @"/System/Library/ExtensionKit/Extensions/Appearance.appex";
    static NSString *const expectedIdentifier =
        @"com.apple.Appearance-Settings.extension";
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path
                                               isDirectory:&directory] ||
        !directory) {
        fprintf(stderr,
                "macwsworkspacectl: settings extension is missing: %s\n",
                path.fileSystemRepresentation);
        return 66;
    }

    void *launchServices = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
        "Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
        RTLD_NOW | RTLD_LOCAL);
    typedef int32_t (*LSRegisterPluginURL)(CFURLRef);
    LSRegisterPluginURL registerPluginURL = launchServices
        ? (LSRegisterPluginURL)dlsym(launchServices,
                                     "_LSRegisterPluginURL")
        : NULL;
    if (!registerPluginURL) {
        fprintf(stderr,
                "macwsworkspacectl: LaunchServices plug-in registrar is "
                "unavailable: %s\n", dlerror() ?: "unknown error");
        if (launchServices) dlclose(launchServices);
        return 69;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    int32_t status = registerPluginURL((__bridge CFURLRef)url);
    if (status != 0) {
        fprintf(stderr,
                "macwsworkspacectl: stock LaunchServices registration "
                "failed status=%d path=%s\n", status,
                path.fileSystemRepresentation);
        dlclose(launchServices);
        return 1;
    }

    // Validate the record produced by LaunchServices rather than treating a
    // zero status as sufficient.  Before this registration the real target
    // database reported `invalid plugin / Container state is -1`; after the
    // stock registrar it must resolve to the exact platform-1 Appearance
    // record at the real bundle URL.
    Class recordClass = NSClassFromString(@"LSApplicationExtensionRecord");
    NSError *recordError = nil;
    id record = recordClass
        ? ((id (*)(id, SEL))objc_msgSend)(
              (id)recordClass, sel_registerName("alloc"))
        : nil;
    record = record
        ? ((id (*)(id, SEL, id, id *))objc_msgSend)(
              record, sel_registerName("initWithURL:error:"),
              url, &recordError)
        : nil;
    NSString *identifier = record
        ? ((id (*)(id, SEL))objc_msgSend)(
              record, sel_registerName("bundleIdentifier"))
        : nil;
    unsigned platform = record
        ? ((unsigned (*)(id, SEL))objc_msgSend)(
              record, sel_registerName("platform"))
        : 0;
    NSURL *recordURL = record
        ? ((id (*)(id, SEL))objc_msgSend)(
              record, sel_registerName("URL"))
        : nil;
    BOOL valid = [identifier isEqualToString:expectedIdentifier] &&
        platform == 1 && [recordURL.path isEqualToString:path];
    if (!valid) {
        fprintf(stderr,
                "macwsworkspacectl: registered settings record failed "
                "validation identifier=%s platform=%u url=%s error=%s\n",
                identifier.UTF8String ?: "<nil>", platform,
                recordURL.path.UTF8String ?: "<nil>",
                recordError.description.UTF8String ?: "none");
        dlclose(launchServices);
        return 1;
    }
    fprintf(stdout,
            "settings-extension-ready identifier=%s platform=%u path=%s\n",
            identifier.UTF8String, platform,
            recordURL.path.fileSystemRepresentation);
    dlclose(launchServices);
    return 0;
}

static int OpenApplication(const char *pathBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    BOOL directory = NO;
    if (path.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:path
                                               isDirectory:&directory] ||
        !directory || ![path.pathExtension isEqualToString:@"app"]) {
        fprintf(stderr,
                "macwsworkspacectl: application bundle does not exist: %s\n",
                pathBytes ?: "(null)");
        return 66;
    }

    // LaunchServices supplies the open-application AppleEvent and activation
    // context that direct execution of many AppKit/SwiftUI bundle executables
    // does not.  Keep this synchronous API here so the short-lived helper can
    // report the actual NSRunningApplication PID before it exits.
    NSError *error = nil;
    NSRunningApplication *application =
        [NSWorkspace.sharedWorkspace
            launchApplicationAtURL:[NSURL fileURLWithPath:path]
                            options:NSWorkspaceLaunchDefault
                      configuration:@{}
                              error:&error];
    if (!application) {
        fprintf(stderr,
                "macwsworkspacectl: LaunchServices failed for %s: %s\n",
                path.fileSystemRepresentation,
                error.description.UTF8String ?: "unknown error");
        return 1;
    }
    fprintf(stdout, "application-ready pid=%d bundle=%s path=%s\n",
            application.processIdentifier,
            application.bundleIdentifier.UTF8String ?: "<unknown>",
            path.fileSystemRepresentation);
    return 0;
}

static int SessionStatus(void) {
    typedef CFDictionaryRef (*CopySessionDictionaryFunction)(void);
    static const char *const symbolNames[] = {
        "CGSSessionCopyCurrentSessionProperties",
        "CGSessionCopyCurrentDictionary",
    };
    for (size_t index = 0;
         index < sizeof(symbolNames) / sizeof(symbolNames[0]); index++) {
        CopySessionDictionaryFunction copySession =
            (CopySessionDictionaryFunction)dlsym(RTLD_DEFAULT,
                                                  symbolNames[index]);
        if (!copySession) {
            fprintf(stdout, "session-provider symbol=%s unavailable\n",
                    symbolNames[index]);
            continue;
        }
        CFDictionaryRef copied = copySession();
        if (!copied) {
            fprintf(stdout, "session-provider symbol=%s dictionary=<null>\n",
                    symbolNames[index]);
            continue;
        }
        NSDictionary *dictionary = CFBridgingRelease(copied);
        id loginDone = dictionary[@"kCGSessionLoginDoneKey"];
        id onConsole = dictionary[@"kCGSSessionOnConsoleKey"];
        id userID = dictionary[@"kCGSSessionUserIDKey"];
        id userName = dictionary[@"kCGSSessionUserNameKey"];
        fprintf(stdout,
                "session-provider symbol=%s login-done=%s on-console=%s "
                "uid=%s user=%s dictionary=%s\n",
                symbolNames[index],
                [[loginDone description] UTF8String] ?: "<missing>",
                [[onConsole description] UTF8String] ?: "<missing>",
                [[userID description] UTF8String] ?: "<missing>",
                [[userName description] UTF8String] ?: "<missing>",
                [[dictionary description] UTF8String] ?: "<invalid>");
    }
    return 0;
}

static int ActivateProcess(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) {
        fprintf(stderr, "macwsworkspacectl: invalid PID: %s\n",
                pidBytes ?: "(null)");
        return 64;
    }
    pid_t pid = (pid_t)parsed;
    NSRunningApplication *application =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (application && [application activateWithOptions:
            (NSApplicationActivateAllWindows |
             NSApplicationActivateIgnoringOtherApps)]) {
        fprintf(stdout, "application-active pid=%d route=NSRunningApplication\n",
                pid);
        return 0;
    }

    // Direct chroot launch targets can own valid SkyLight windows without an
    // LS process record. HIServices resolves that existing process by PID and
    // performs the normal front-window transaction; it does not synthesize a
    // window or create a second application instance.
    ProcessSerialNumber process = {0, 0};
    OSStatus lookup = GetProcessForPID(pid, &process);
    if (lookup != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: GetProcessForPID(%d) failed: %d\n",
                pid, (int)lookup);
        return 1;
    }
    OSStatus activated = SetFrontProcessWithOptions(
        &process, kSetFrontProcessFrontWindowOnly |
                  kSetFrontProcessCausedByUser);
    if (activated != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: SetFrontProcessWithOptions(%d) "
                "failed: %d\n", pid, (int)activated);
        return 1;
    }
    fprintf(stdout, "application-active pid=%d route=HIServices\n", pid);
    return 0;
}

static int ListWindows(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) return 64;
    pid_t pid = (pid_t)parsed;
    CFArrayRef copied = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll, kCGNullWindowID);
    NSArray<NSDictionary *> *windows = CFBridgingRelease(copied);
    NSUInteger count = 0;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        count++;
        fprintf(stdout,
                "window pid=%d id=%u layer=%d onscreen=%s alpha=%s "
                "name=%s bounds=%s\n",
                pid, [window[(id)kCGWindowNumber] unsignedIntValue],
                [window[(id)kCGWindowLayer] intValue],
                [window[(id)kCGWindowIsOnscreen] boolValue] ? "yes" : "no",
                [[window[(id)kCGWindowAlpha] description] UTF8String]
                    ?: "<missing>",
                [[window[(id)kCGWindowName] description] UTF8String]
                    ?: "<unnamed>",
                [[window[(id)kCGWindowBounds] description] UTF8String]
                    ?: "<missing>");
    }
    fprintf(stdout, "window-count pid=%d count=%lu\n", pid,
            (unsigned long)count);
    return 0;
}

static int ReopenProcess(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) return 64;
    pid_t pid = (pid_t)parsed;
    ProcessSerialNumber process = {0, 0};
    OSStatus status = GetProcessForPID(pid, &process);
    if (status != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: GetProcessForPID(%d) failed before "
                "reopen: %d\n", pid, (int)status);
        return 1;
    }
    AEAddressDesc target = {typeNull, NULL};
    AppleEvent event = {typeNull, NULL};
    // Directly exec'd chroot applications have a valid HIServices process
    // record (GetProcessForPID and front-process activation both work), but
    // are absent from LaunchServices' PID-addressed AppleEvent registry.  A
    // typeKernelProcessID target consequently returns procNotFound (-600).
    // Address the same standard kAEReopenApplication event through the
    // process's real Carbon serial number instead of inventing an app-specific
    // show-window hook.
    status = AECreateDesc(typeProcessSerialNumber, &process, sizeof(process),
                          &target);
    if (status == noErr) {
        status = AECreateAppleEvent(kCoreEventClass, kAEReopenApplication,
                                    &target, kAutoGenerateReturnID,
                                    kAnyTransactionID, &event);
    }
    if (status == noErr) {
        status = AESendMessage(&event, NULL,
                               kAENoReply | kAECanSwitchLayer,
                               kAEDefaultTimeout);
    }
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);
    if (status == procNotFound) {
        // launchdchrootexec children are missing only the cross-process
        // LaunchServices/AppleEvent endpoint. Their libmachook-owned app-input
        // endpoint runs on the real NSApplication main thread, where the
        // standard delegate reopen lifecycle can be delivered without an
        // app-specific show-window method.
        int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        int pathLength = snprintf(address.sun_path, sizeof(address.sun_path),
                                  "/private/tmp/macws_app_input.%d.sock", pid);
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindReopenApplication,
            .frameWidth = 1,
            .frameHeight = 1,
            .targetPID = pid,
            .source = MacWSInputSourceUnknown,
            .sampleSequence = 1,
        };
        ssize_t sent = -1;
        if (socketFD >= 0 && pathLength > 0 &&
            (size_t)pathLength < sizeof(address.sun_path)) {
            sent = sendto(socketFD, &record, sizeof(record), 0,
                          (const struct sockaddr *)&address,
                          sizeof(address));
        }
        int sendError = sent == (ssize_t)sizeof(record) ? 0 : errno;
        if (socketFD >= 0) close(socketFD);
        if (sendError == 0) {
            fprintf(stdout,
                    "application-reopen-sent pid=%d route=AppInputBridge\n",
                    pid);
            return 0;
        }
        fprintf(stderr,
                "macwsworkspacectl: reopen AppInputBridge fallback for pid "
                "%d failed: %s\n", pid, strerror(sendError));
    } else if (status == noErr) {
        fprintf(stdout, "application-reopen-sent pid=%d route=AppleEvent\n",
                pid);
        return 0;
    }
    if (status != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: reopen AppleEvent for pid %d failed: %d\n",
                pid, (int)status);
        return 1;
    }
    return 1;
}

static int InspectAppKitReopen(void) {
    Class applicationClass = NSClassFromString(@"NSApplication");
    for (Class cursor = applicationClass; cursor; cursor = class_getSuperclass(cursor)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cursor, &count);
        for (unsigned int index = 0; index < count; index++) {
            SEL selector = method_getName(methods[index]);
            const char *name = sel_getName(selector);
            if (!name || (!strcasestr(name, "reopen") &&
                          !strcasestr(name, "untitled") &&
                          !strcasestr(name, "openfile") &&
                          !strcasestr(name, "coreevent"))) continue;
            IMP signedImplementation = method_getImplementation(methods[index]);
            void *implementation = ptrauth_strip(signedImplementation,
                                                  ptrauth_key_function_pointer);
            Dl_info image = {0};
            dladdr(implementation, &image);
            fprintf(stdout,
                    "appkit-method class=%s selector=%s types=%s imp=%p "
                    "image=%s offset=%#llx bytes=",
                    class_getName(cursor), name,
                    method_getTypeEncoding(methods[index]) ?: "<unknown>",
                    implementation, image.dli_fname ?: "<unknown>",
                    (unsigned long long)((uintptr_t)implementation -
                                         (uintptr_t)image.dli_fbase));
            const uint8_t *bytes = implementation;
            size_t byteCount = strcmp(name, "_handleAEReopen:") == 0
                ? 512 : 64;
            for (size_t byte = 0; byte < byteCount; byte++)
                fprintf(stdout, "%02x", bytes[byte]);
            fputc('\n', stdout);
        }
        free(methods);
    }
    return 0;
}

static int InspectUIKitMac(void) {
    void *image = dlopen(
        "/System/Library/PrivateFrameworks/UIKitMacHelper.framework/"
        "Versions/A/UIKitMacHelper", RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "macwsworkspacectl: UIKitMacHelper dlopen failed: %s\n",
                dlerror());
        return 1;
    }
    NSApplication *hostApplication = NSApplication.sharedApplication;
    Class workspaceClass = objc_getClass("UINSWorkspace");
    id workspace = workspaceClass ? ((id (*)(id, SEL))objc_msgSend)(
        (id)workspaceClass, sel_registerName("sharedInstance")) : nil;
    id initialScreen = workspace ? ((id (*)(id, SEL))objc_msgSend)(
        workspace, sel_registerName("initialScreen")) : nil;
    id workspaceApplication = workspace ? ((id (*)(id, SEL))objc_msgSend)(
        workspace, sel_registerName("application")) : nil;
    Class delegateClass = objc_getClass("UINSApplicationDelegate");
    id sharedDelegate = delegateClass ? ((id (*)(id, SEL))objc_msgSend)(
        (id)delegateClass, sel_registerName("sharedDelegate")) : nil;
    fprintf(stdout,
            "uikitmac-state workspace=%s initial-screen=%s application=%s "
            "shared-delegate=%s ns-application=%s\n",
            workspace ? object_getClassName(workspace) : "nil",
            initialScreen ? object_getClassName(initialScreen) : "nil",
            workspaceApplication ? object_getClassName(workspaceApplication) :
                "nil",
            sharedDelegate ? object_getClassName(sharedDelegate) : "nil",
            hostApplication ? object_getClassName(hostApplication) : "nil");
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
        const char *className = class_getName(classes[classIndex]);
        if (!className || (strncmp(className, "UINS", 4) != 0 &&
                           strncmp(className, "_UINS", 5) != 0 &&
                           strcmp(className, "UIScreen") != 0 &&
                           strcmp(className, "UIApplication") != 0))
            continue;
        fprintf(stdout, "uikitmac-class name=%s\n", className);
        for (int meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(classes[classIndex])
                               : classes[classIndex];
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            for (unsigned int methodIndex = 0;
                 methodIndex < methodCount; methodIndex++) {
                const char *name = sel_getName(method_getName(
                    methods[methodIndex]));
                BOOL primaryClass = strcmp(className, "UINSWorkspace") == 0 ||
                                    strcmp(className,
                                           "UINSApplicationDelegate") == 0;
                if (!name || (!primaryClass && !strcasestr(name, "scene") &&
                              !strcasestr(name, "screen") &&
                              !strcasestr(name, "launch") &&
                              !strcasestr(name, "display") &&
                              !strcasestr(name, "application") &&
                              !strcasestr(name, "run"))) continue;
                IMP signedImplementation = method_getImplementation(
                    methods[methodIndex]);
                void *implementation = ptrauth_strip(
                    signedImplementation, ptrauth_key_function_pointer);
                Dl_info ownerImage = {0};
                dladdr(implementation, &ownerImage);
                fprintf(stdout,
                        "uikitmac-method class=%s scope=%c selector=%s "
                        "types=%s image=%s offset=%#llx\n",
                        className, meta ? '+' : '-', name,
                        method_getTypeEncoding(methods[methodIndex]) ?:
                            "<unknown>",
                        ownerImage.dli_fname ?: "<unknown>",
                        (unsigned long long)((uintptr_t)implementation -
                            (uintptr_t)ownerImage.dli_fbase));
            }
            free(methods);
        }
    }
    free(classes);
    dlclose(image);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "set-wallpaper") == 0) {
            const char *path = argc >= 3 ? argv[2] :
                "/System/Library/Desktop Pictures/Solid Colors/Blue Violet.png";
            return SetWallpaper(path);
        }
        if (argc == 2 && strcmp(argv[1], "show-launchpad") == 0) {
            return ShowLaunchpad();
        }
        if (argc == 2 &&
            strcmp(argv[1], "register-settings-extension") == 0) {
            return RegisterSettingsExtension();
        }
        if (argc == 3 && strcmp(argv[1], "open-application") == 0) {
            return OpenApplication(argv[2]);
        }
        if (argc == 2 && strcmp(argv[1], "session-status") == 0) {
            return SessionStatus();
        }
        if (argc == 3 && strcmp(argv[1], "activate-process") == 0) {
            return ActivateProcess(argv[2]);
        }
        if (argc == 3 && strcmp(argv[1], "list-windows") == 0) {
            return ListWindows(argv[2]);
        }
        if (argc == 3 && strcmp(argv[1], "reopen-process") == 0) {
            return ReopenProcess(argv[2]);
        }
        if (argc == 2 && strcmp(argv[1], "inspect-appkit-reopen") == 0) {
            return InspectAppKitReopen();
        }
        if (argc == 2 && strcmp(argv[1], "inspect-uikitmac") == 0) {
            return InspectUIKitMac();
        }
        fprintf(stderr,
                "usage: macwsworkspacectl set-wallpaper [path] | "
                "show-launchpad | register-settings-extension | "
                "open-application /absolute/App.app | "
                "session-status | activate-process PID | list-windows PID | "
                "reopen-process PID | inspect-appkit-reopen | "
                "inspect-uikitmac\n");
        return 64;
    }
}
