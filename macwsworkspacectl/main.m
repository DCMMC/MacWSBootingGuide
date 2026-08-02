#import <AppKit/AppKit.h>
#import <errno.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>

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
        fprintf(stderr,
                "usage: macwsworkspacectl set-wallpaper [path] | "
                "show-launchpad\n");
        return 64;
    }
}
