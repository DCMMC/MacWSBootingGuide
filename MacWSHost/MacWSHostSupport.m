// MacWSHostSupport.m — implementation of the shared Host statics.
#import "MacWSHostSupport.h"

#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>


NSString *const MacWSFramePath =
    @"/var/mnt/rootfs/private/tmp/macws_vnc_fb";
NSString *const MacWSCaptureAckPath =
    @"/var/mnt/rootfs/private/tmp/macws_capture_done";
NSString *const MacWSLogPath = @"/var/mobile/Library/Logs/MacWSHost.log";
BOOL MacWSHostDiagnosticsEnabled(void) {
    static dispatch_once_t onceToken;
    static BOOL enabled;
    dispatch_once(&onceToken, ^{
        enabled = NSProcessInfo.processInfo.environment[
            @"MACWS_RUNTIME_DIAGNOSTICS"] != nil ||
            access("/var/mnt/rootfs/private/tmp/macws_runtime_diagnostics",
                   F_OK) == 0;
    });
    return enabled;
}
BOOL MacWSLegacyFramebufferFallbackEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:@"MacWSLegacyFramebufferFallback"];
}
BOOL MacWSAppInputEndpointReady(int32_t pid) {
    if (pid <= 1) return NO;
    char path[PATH_MAX] = {0};
    int length = snprintf(path, sizeof(path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    return length > 0 && (size_t)length < sizeof(path) &&
        access(path, F_OK) == 0;
}
double MacWSMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return -1.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)mach_timebase_info(&timebase);
    });
    if (!timebase.denom) return -1.0;
    long double nanoseconds = (long double)(end - start) *
        timebase.numer / timebase.denom;
    return (double)(nanoseconds / 1000000.0L);
}
BOOL MacWSStreamFrameGeometryEqual(
        MacWSStreamFrameDescriptor left,
        MacWSStreamFrameDescriptor right) {
    return left.streamID == right.streamID &&
        left.windowID == right.windowID &&
        left.layerWindowID == right.layerWindowID &&
        left.width == right.width && left.height == right.height &&
        left.contentX == right.contentX && left.contentY == right.contentY &&
        left.contentWidth == right.contentWidth &&
        left.contentHeight == right.contentHeight &&
        left.destinationX == right.destinationX &&
        left.destinationY == right.destinationY &&
        left.destinationWidth == right.destinationWidth &&
        left.destinationHeight == right.destinationHeight &&
        fabsf(left.backingScale - right.backingScale) < 0.001f;
}
NSUInteger MacWSIOSurfaceReadOnlyTextureAlignment(
        id<MTLDevice> device) {
    SEL selector = NSSelectorFromString(
        @"iosurfaceReadOnlyTextureAlignmentBytes");
    if (!device || ![device respondsToSelector:selector]) return 0;
    return [(NSObject *)device iosurfaceReadOnlyTextureAlignmentBytes];
}
CGFloat MacWSDensityModeFactor(MacWSHostDisplayDensity density) {
    if (density == MacWSHostDisplayDensityKeyboard) return 0.85;
    if (density == MacWSHostDisplayDensityComfort) return 1.10;
    return 1.0;
}
void MacWSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", message);

    static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&logLock);
    FILE *file = fopen(MacWSLogPath.fileSystemRepresentation, "a");
    if (file) {
        fprintf(file, "%.3f %s\n", NSDate.date.timeIntervalSince1970,
                message.UTF8String);
        fclose(file);
    }
    pthread_mutex_unlock(&logLock);
}
BOOL MacWSReadCaptureAck(uint64_t *generationOut) {
    char value[96] = {0};
    int fd = open(MacWSCaptureAckPath.fileSystemRepresentation,
                  O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return NO;
    int producerPID = 0;
    unsigned long long generation = 0;
    if (sscanf(value, "%d %llu", &producerPID, &generation) != 2 ||
        producerPID <= 0 || generation == 0) {
        return NO;
    }
    if (generationOut) *generationOut = (uint64_t)generation;
    return YES;
}
uint16_t MacWSMacKeyCodeForHIDUsage(NSInteger usage) {
    static const uint16_t letterCodes[] = {
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    };
    if (usage >= 4 && usage <= 29) return letterCodes[usage - 4];
    static const uint16_t digitCodes[] = {18, 19, 20, 21, 23, 22, 26, 28, 25, 29};
    if (usage >= 30 && usage <= 39) return digitCodes[usage - 30];
    switch (usage) {
        case 40: return 36;  // Return
        case 41: return 53;  // Escape
        case 42: return 51;  // Delete backward
        case 43: return 48;  // Tab
        case 44: return 49;  // Space
        case 45: return 27;  // -
        case 46: return 24;  // =
        case 47: return 33;  // [
        case 48: return 30;  // ]
        case 49: return 42;  // backslash
        case 51: return 41;  // ;
        case 52: return 39;  // quote
        case 53: return 50;  // grave
        case 54: return 43;  // comma
        case 55: return 47;  // period
        case 56: return 44;  // slash
        case 57: return 57;  // Caps Lock
        case 58: return 122; // F1
        case 59: return 120; // F2
        case 60: return 99;  // F3
        case 61: return 118; // F4
        case 62: return 96;  // F5
        case 63: return 97;  // F6
        case 64: return 98;  // F7
        case 65: return 100; // F8
        case 66: return 101; // F9
        case 67: return 109; // F10
        case 68: return 103; // F11
        case 69: return 111; // F12
        case 74: return 115; // Home
        case 75: return 116; // Page Up
        case 76: return 117; // Delete forward
        case 77: return 119; // End
        case 78: return 121; // Page Down
        case 79: return 124; // Right
        case 80: return 123; // Left
        case 81: return 125; // Down
        case 82: return 126; // Up
        case 224: return 59; // Left Control
        case 225: return 56; // Left Shift
        case 226: return 58; // Left Option
        case 227: return 55; // Left Command
        case 228: return 62; // Right Control
        case 229: return 60; // Right Shift
        case 230: return 61; // Right Option
        case 231: return 54; // Right Command
        default: return UINT16_MAX;
    }
}
uint32_t MacWSKeySymForHIDUsage(NSInteger usage, NSString *characters,
                                      UIKeyModifierFlags modifiers) {
    switch (usage) {
        case 40: return 0xff0d;
        case 41: return 0xff1b;
        case 42: return 0xff08;
        case 43: return 0xff09;
        case 57: return 0xffe5; // Caps Lock
        case 58 ... 69: return 0xffbeu + (uint32_t)(usage - 58);
        case 74: return 0xff50;
        case 75: return 0xff55;
        case 76: return 0xffff;
        case 77: return 0xff57;
        case 78: return 0xff56;
        case 79: return 0xff53;
        case 80: return 0xff51;
        case 81: return 0xff54;
        case 82: return 0xff52;
        case 224: return 0xffe3;
        case 225: return 0xffe1;
        case 226: return 0xffe9;
        case 227: return 0xffe7;
        case 228: return 0xffe4;
        case 229: return 0xffe2;
        case 230: return 0xffea;
        case 231: return 0xffe8;
    }
    if (characters.length == 0) {
        // Runtime symptom on the production iPad keyboard path: Return kept
        // working (it has a fixed HID mapping above) while printable keys did
        // not. UIKey is allowed to provide an empty characters string for a
        // physical key transition; never turn a perfectly valid HID usage
        // into keysym 0. Derive the same US-layout scalar used by the existing
        // Mac key-code table. The target AppKit event still carries the real
        // modifier mask, so Shift/Caps semantics remain native downstream.
        BOOL shift = (modifiers & UIKeyModifierShift) != 0;
        BOOL caps = (modifiers & UIKeyModifierAlphaShift) != 0;
        if (usage >= 4 && usage <= 29) {
            uint32_t scalar = 'a' + (uint32_t)(usage - 4);
            return shift ^ caps ? scalar - ('a' - 'A') : scalar;
        }
        if (usage >= 30 && usage <= 39) {
            static const char ordinary[] = "1234567890";
            static const char shifted[] = "!@#$%^&*()";
            return (uint32_t)(shift ? shifted[usage - 30]
                                    : ordinary[usage - 30]);
        }
        switch (usage) {
            case 44: return ' ';
            case 45: return shift ? '_' : '-';
            case 46: return shift ? '+' : '=';
            case 47: return shift ? '{' : '[';
            case 48: return shift ? '}' : ']';
            case 49: return shift ? '|' : '\\';
            case 51: return shift ? ':' : ';';
            case 52: return shift ? '"' : '\'';
            case 53: return shift ? '~' : '`';
            case 54: return shift ? '<' : ',';
            case 55: return shift ? '>' : '.';
            case 56: return shift ? '?' : '/';
            default: return 0;
        }
    }
    __block uint32_t scalar = 0;
    // UIKey.characters already reflects Shift and Caps Lock. Lowercasing it
    // made the Unicode payload override an otherwise-correct Shift+A keycode.
    [characters enumerateSubstringsInRange:
        NSMakeRange(0, characters.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *substring, NSRange substringRange,
                     NSRange enclosingRange, BOOL *stop) {
            (void)substringRange;
            (void)enclosingRange;
            NSData *data = [substring dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
            if (data.length >= sizeof(scalar)) memcpy(&scalar, data.bytes, sizeof(scalar));
            *stop = YES;
        }];
    return scalar;
}
NSInteger MacWSHIDUsageForASCII(uint32_t scalar) {
    uint32_t lower = scalar >= 'A' && scalar <= 'Z'
        ? scalar + ('a' - 'A') : scalar;
    if (lower >= 'a' && lower <= 'z') return 4 + (lower - 'a');
    if (lower >= '1' && lower <= '9') return 30 + (lower - '1');
    if (lower == '0') return 39;
    switch (lower) {
        case '\n': case '\r': return 40;
        case 0x1b: return 41;
        case '\b': return 42;
        case '\t': return 43;
        case ' ': return 44;
        case '-': case '_': return 45;
        case '=': case '+': return 46;
        case '[': case '{': return 47;
        case ']': case '}': return 48;
        case '\\': case '|': return 49;
        case ';': case ':': return 51;
        case '\'': case '"': return 52;
        case '`': case '~': return 53;
        case ',': case '<': return 54;
        case '.': case '>': return 55;
        case '/': case '?': return 56;
        default: return -1;
    }
}
