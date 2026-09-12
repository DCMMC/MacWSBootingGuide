// Read-only catalog diagnostic. No NSApplication, activation, capture stream,
// window mutation or event injection. Invoke inside the macOS chroot.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static void Deadline(int signal) { (void)signal; _exit(124); }

int main(int argc, const char **argv) {
    signal(SIGALRM, Deadline);
    alarm(5);
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: %s OWNER_PID\n", argv[0]); return 64; }
        if (!strcmp(argv[1], "--capture-methods")) {
            const char *names[] = {"CGPreflightScreenCaptureAccess",
                                   "CGRequestScreenCaptureAccess"};
            for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
                void *address = dlsym(RTLD_DEFAULT, names[i]);
                Dl_info info = {0};
                if (!address || !dladdr(address, &info)) return 2;
                intptr_t slide = 0;
                for (uint32_t j = 0; j < _dyld_image_count(); ++j)
                    if (_dyld_get_image_header(j) == info.dli_fbase)
                        slide = _dyld_get_image_vmaddr_slide(j);
                printf("%s 0x%lx %s\n", names[i],
                    (unsigned long)((uintptr_t)address - slide), info.dli_fname);
            }
            return 0;
        }
        if (!strcmp(argv[1], "--window-methods")) {
            unsigned count = 0;
            Method *methods = class_copyMethodList(NSWindow.class, &count);
            for (unsigned i = 0; i < count; ++i) {
                const char *name = sel_getName(method_getName(methods[i]));
                if (!strcasestr(name, "size") && !strcasestr(name, "frame") &&
                    !strcasestr(name, "constraint") && !strcasestr(name, "layout")) continue;
                IMP imp = method_getImplementation(methods[i]);
                Dl_info info = {0};
                if (!dladdr((void *)imp, &info)) continue;
                intptr_t slide = 0;
                for (uint32_t j = 0; j < _dyld_image_count(); ++j)
                    if (_dyld_get_image_header(j) == info.dli_fbase)
                        slide = _dyld_get_image_vmaddr_slide(j);
                printf("%s %s 0x%lx %s\n", name,
                    method_getTypeEncoding(methods[i]),
                    (unsigned long)((uintptr_t)imp - slide), info.dli_fname);
            }
            free(methods);
            return 0;
        }
        char *end = NULL;
        errno = 0;
        long owner = strtol(argv[1], &end, 10);
        if (errno || !end || *end || owner <= 1 || owner > INT_MAX) return 64;
        NSArray *catalog = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll, kCGNullWindowID));
        if (!catalog) return 2;
        NSMutableArray *windows = [NSMutableArray array];
        for (NSDictionary *entry in catalog) {
            if ([entry[(id)kCGWindowOwnerPID] intValue] == owner)
                [windows addObject:entry];
        }
        CGDirectDisplayID display = CGMainDisplayID();
        CGRect rect = CGDisplayBounds(display);
        NSDictionary *result = @{
            @"time": @(NSDate.date.timeIntervalSince1970),
            @"display_id": @(display),
            @"display_bounds": @[@(rect.origin.x), @(rect.origin.y),
                @(rect.size.width), @(rect.size.height)],
            @"windows": windows,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
            options:NSJSONWritingPrettyPrinted error:NULL];
        if (!json) return 3;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
