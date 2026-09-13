// One-shot diagnostic; no injection, debugger subscription or file mutation.
// Each invocation queries ONE operator-selected file URL and its real icon.
#import <AppKit/AppKit.h>
#include <signal.h>
#include <unistd.h>

int main(int argc, const char *argv[]) {
    if (argc != 2 || argv[1][0] != '/') return 64;
    alarm(10);
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *error = nil;
        NSDictionary *values = [url resourceValuesForKeys:@[
            NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsAliasFileKey,
            NSURLIsVolumeKey, NSURLCanonicalPathKey, NSURLVolumeURLKey]
            error:&error];
        printf("icon-probe path=%s properties=%s error=%s\n", argv[1],
               values.description.UTF8String ?: "nil", error.description.UTF8String ?: "nil");
        fflush(stdout);
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        printf("icon-probe completed image=%s size=%.1fx%.1f\n",
               icon ? "yes" : "no", icon.size.width, icon.size.height);
        fflush(stdout);
        return icon ? 0 : 1;
    }
}
