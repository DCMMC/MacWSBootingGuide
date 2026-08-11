#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#include <sched.h>

static CGRect MacWSLargestWindowForPID(pid_t pid) {
    CGRect best = CGRectNull;
    CGFloat bestArea = 0.0;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    for (NSDictionary *entry in (__bridge NSArray *)windows) {
        if ([entry[(id)kCGWindowOwnerPID] intValue] != pid ||
            [entry[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)entry[(id)kCGWindowBounds],
                &bounds)) continue;
        CGFloat area = bounds.size.width * bounds.size.height;
        if (area > bestArea) {
            best = bounds;
            bestArea = area;
        }
    }
    if (windows) CFRelease(windows);
    return best;
}

static void MacWSPostMouse(pid_t pid, CGEventType type, CGPoint point,
                           CGMouseButton button) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, button);
    if (!event) return;
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    // Post through WindowServer's ordinary HID event tap.  CGEventPostToPid
    // reports success but does not participate in AppKit's mouse target and
    // pressed-button state machine on current macOS; that is a different and
    // unfair path from the hardware trackpad baseline this tool measures.
    // The destination is still constrained by the discovered InputLab window
    // geometry, and the caller must have Accessibility event-post access.
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void MacWSWaitUntil(uint64_t deadline, mach_timebase_info_data_t timebase) {
    for (;;) {
        uint64_t now = mach_absolute_time();
        if (now >= deadline) return;
        uint64_t remaining = deadline - now;
        uint64_t nanos = remaining * timebase.numer / timebase.denom;
        if (nanos > 2000000) {
            struct timespec sleep = {
                .tv_sec = 0,
                .tv_nsec = (long)(nanos - 1000000),
            };
            nanosleep(&sleep, NULL);
        } else {
            sched_yield();
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "--click") == 0) {
            CGPoint point = CGPointMake(strtod(argv[2], NULL),
                                        strtod(argv[3], NULL));
            MacWSPostMouse(getpid(), kCGEventLeftMouseDown, point,
                           kCGMouseButtonLeft);
            usleep(30000);
            MacWSPostMouse(getpid(), kCGEventLeftMouseUp, point,
                           kCGMouseButtonLeft);
            return 0;
        }
        if (argc != 4) {
            fprintf(stderr,
                    "usage: %s PID DURATION_SECONDS HZ | --click X Y\n",
                    argv[0]);
            return 64;
        }
        pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
        double duration = strtod(argv[2], NULL);
        double hz = strtod(argv[3], NULL);
        if (pid <= 1 || duration <= 0 || hz <= 0 || hz > 1000) return 64;

        CGRect bounds = MacWSLargestWindowForPID(pid);
        if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) {
            fprintf(stderr, "no visible layer-0 window for pid %d\n", pid);
            return 2;
        }
        NSRunningApplication *application =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        [NSThread sleepForTimeInterval:0.15];
        // InputLab's canvas fills the upper portion of the content view.  A
        // horizontal sweep through the visual center remains safely outside
        // the title bar and native controls on both the MacBook and iPad.
        CGFloat left = CGRectGetMinX(bounds) + bounds.size.width * 0.30;
        CGFloat right = CGRectGetMinX(bounds) + bounds.size.width * 0.75;
        CGFloat y = CGRectGetMinY(bounds) + bounds.size.height * 0.46;
        CGPoint start = CGPointMake(left, y);

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        NSUInteger samples = MAX(2, (NSUInteger)llround(duration * hz));
        uint64_t interval = (uint64_t)llround(
            (1e9 / hz) * timebase.denom / timebase.numer);
        uint64_t began = mach_absolute_time();
        MacWSPostMouse(pid, kCGEventLeftMouseDown, start, kCGMouseButtonLeft);
        uint64_t deadline = mach_absolute_time();
        for (NSUInteger index = 0; index < samples; index++) {
            double phase = (double)index / MAX(1.0, (double)samples - 1.0) * 3.0;
            double fraction = fmod(phase, 1.0);
            if (((NSUInteger)phase) & 1) fraction = 1.0 - fraction;
            CGPoint point = CGPointMake(
                left + fraction * (right - left),
                y + 35.0 * sin((double)index * 2.0 * M_PI / 60.0));
            MacWSPostMouse(pid, kCGEventLeftMouseDragged, point,
                           kCGMouseButtonLeft);
            deadline += interval;
            MacWSWaitUntil(deadline, timebase);
        }
        MacWSPostMouse(pid, kCGEventLeftMouseUp, start, kCGMouseButtonLeft);
        uint64_t ended = mach_absolute_time();
        double elapsed = (double)(ended - began) * timebase.numer /
            timebase.denom / 1e9;
        NSDictionary *result = @{
            @"result": @"SENT",
            @"transport": @"macOS WindowServer HID event tap",
            @"pid": @(pid),
            @"requested_hz": @(hz),
            @"duration_s": @(elapsed),
            @"move_records_sent": @(samples),
            @"window_bounds": @{
                @"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
                @"width": @(bounds.size.width),
                @"height": @(bounds.size.height),
            },
            @"accessibility_preflight": @(CGPreflightPostEventAccess()),
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
            options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
