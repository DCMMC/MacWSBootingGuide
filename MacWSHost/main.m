#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>

#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#import "MacWSControlClient.h"
#import "MacWSInteropClient.h"
#import "MacWSMenuClient.h"
#import "MacWSStreamClient.h"
#include "macws_control_protocol.h"
#include "macws_host_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

@interface UIWindowScene (MacWSFullscreenState)
@property(nonatomic, readonly, getter=isFullScreen) BOOL fullScreen;
@end

@interface UIScene (MacWSSceneIdentity)
// RE-confirmed via UIKitCore 16.3.1 -[UIScene _sceneIdentifier] at
// 0x189322ff0. This is the FBS identifier used as SBDisplayItem's
// uniqueIdentifier, unlike UISceneSession.persistentIdentifier.
- (NSString *)_sceneIdentifier;
@end

@interface UISceneActivationRequestOptions (MacWSFullscreenRequest)
- (void)_setRequestFullscreen:(BOOL)fullscreen;
@end

@interface NSObject (MacWSMetalIOSurfaceAlignment)
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes;
@end

static NSString *const MacWSFramePath =
    @"/var/mnt/rootfs/private/tmp/macws_vnc_fb";
static NSString *const MacWSCaptureAckPath =
    @"/var/mnt/rootfs/private/tmp/macws_capture_done";
static NSString *const MacWSLogPath = @"/var/mobile/Library/Logs/MacWSHost.log";
static NSMutableSet<NSString *> *MacWSSceneSessionsPreservingMacWindow;
static NSMutableDictionary<NSString *, NSUserActivity *> *MacWSSceneBindings;
static NSMutableSet<NSString *> *MacWSSceneCloseRequestsSent;
static NSMutableSet<NSString *> *MacWSObservedWindowIdentities;
static NSMutableSet<NSString *> *MacWSPendingWindowSceneIdentities;
static NSString *const MacWSSceneBindingsDefaultsKey =
    @"MacWSPersistedSceneWindowBindings";
static NSString *const MacWSWindowingLoadedPath =
    @"/var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded";
static CFStringRef const MacWSRequestFullscreenNotification =
    CFSTR("com.macwsguide.windowing.request-fullscreen");
static CFStringRef const MacWSRequestResizeNotification =
    CFSTR("com.macwsguide.windowing.request-resize");
static CFStringRef const MacWSLaunchMapsFromHostNotification =
    CFSTR("com.macwsguide.host.launch-maps");
static NSString *const MacWSResizeRequestDirectory =
    @"/var/mobile/Library/Preferences";
static NSString *const MacWSFullscreenRequestPrefix =
    @"com.macwsguide.windowing.fullscreen-request.";
static NSString *const MacWSResizeRequestPrefix =
    @"com.macwsguide.windowing.resize-request.";
static const char MacWSInputSocketPath[] =
    "/var/mnt/rootfs/private/tmp/macws_host_input.sock";
static const char MacWSCatalystLauncherPath[] =
    "/var/jb/Applications/MacWSCatalystLauncher.app/"
    "MacWSCatalystLauncher";

static BOOL MacWSHostDiagnosticsEnabled(void) {
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

// DisplayStream IOSurface transport is the production path. The historical
// full-display mmap remains available only for controlled compatibility A/Bs;
// it must never silently stand in for a native stream.
static BOOL MacWSLegacyFramebufferFallbackEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:@"MacWSLegacyFramebufferFallback"];
}

static BOOL MacWSAppInputEndpointReady(int32_t pid) {
    if (pid <= 1) return NO;
    char path[PATH_MAX] = {0};
    int length = snprintf(path, sizeof(path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    return length > 0 && (size_t)length < sizeof(path) &&
        access(path, F_OK) == 0;
}

static double MacWSMachMilliseconds(uint64_t start, uint64_t end) {
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

static BOOL MacWSStreamFrameGeometryEqual(
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

// Metal`_mtlValidateStrideTextureParameters in the target iOS 16.3.1 image
// calls this native-device selector for ShaderRead IOSurfaces and aborts the
// process through MTLReportFailure when bytesPerRow is not aligned. Query the
// same device-owned requirement before import so a malformed producer frame
// is rejected at the transport boundary instead of terminating every Scene.
// The producer is still responsible for allocating a conforming IOSurface.
static NSUInteger MacWSIOSurfaceReadOnlyTextureAlignment(
        id<MTLDevice> device) {
    SEL selector = NSSelectorFromString(
        @"iosurfaceReadOnlyTextureAlignmentBytes");
    if (!device || ![device respondsToSelector:selector]) return 0;
    return [(NSObject *)device iosurfaceReadOnlyTextureAlignmentBytes];
}

static CGFloat MacWSDensityModeFactor(MacWSHostDisplayDensity density) {
    if (density == MacWSHostDisplayDensityKeyboard) return 0.85;
    if (density == MacWSHostDisplayDensityComfort) return 1.10;
    return 1.0;
}

static void MacWSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void MacWSLog(NSString *format, ...) {
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

static BOOL MacWSSpawnMapsFromForegroundHost(int *errorOut) {
    char *const arguments[] = {
        (char *)MacWSCatalystLauncherPath,
        "--exec-maps-from-host",
        NULL,
    };
    extern char **environ;
    pid_t child = 0;
    int error = posix_spawn(&child, MacWSCatalystLauncherPath,
                            NULL, NULL, arguments, environ);
    if (errorOut) *errorOut = error;
    MacWSLog(@"maps-host-carrier spawn result=%d child=%d parent=%d",
             error, child, getpid());
    if (error == 0 && child > 1) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int status = 0;
            pid_t waited = 0;
            do {
                waited = waitpid(child, &status, 0);
            } while (waited < 0 && errno == EINTR);
            if (waited == child) {
                MacWSLog(@"maps-host-carrier child-exit pid=%d exited=%@ code=%d signaled=%@ signal=%d",
                         child, WIFEXITED(status) ? @"YES" : @"NO",
                         WIFEXITED(status) ? WEXITSTATUS(status) : -1,
                         WIFSIGNALED(status) ? @"YES" : @"NO",
                         WIFSIGNALED(status) ? WTERMSIG(status) : -1);
            } else {
                MacWSLog(@"maps-host-carrier wait-failed pid=%d errno=%d",
                         child, errno);
            }
        });
    }
    return error == 0;
}

static void MacWSLaunchMapsNotificationCallback(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int error = 0;
        (void)MacWSSpawnMapsFromForegroundHost(&error);
    });
}

static BOOL MacWSSendInputRecord(const MacWSInputRecord *record,
                                 int *errorOut) {
    static int socketFD = -1;
    static pthread_mutex_t socketLock = PTHREAD_MUTEX_INITIALIZER;
    BOOL sent = NO;
    int savedError = 0;

    pthread_mutex_lock(&socketLock);
    for (unsigned attempt = 0; attempt < 2 && !sent; attempt++) {
        if (socketFD < 0) {
            socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
            if (socketFD < 0) {
                savedError = errno;
                break;
            }
            int flags = fcntl(socketFD, F_GETFL, 0);
            if (flags >= 0) (void)fcntl(socketFD, F_SETFL, flags | O_NONBLOCK);
            int sendBuffer = 256 * 1024;
            (void)setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF,
                             &sendBuffer, sizeof(sendBuffer));
            struct sockaddr_un address = {0};
            address.sun_family = AF_UNIX;
            _Static_assert(sizeof(MacWSInputSocketPath) <=
                           sizeof(address.sun_path),
                           "input socket path exceeds sockaddr_un.sun_path");
            memcpy(address.sun_path, MacWSInputSocketPath,
                   sizeof(MacWSInputSocketPath));
            if (connect(socketFD, (const struct sockaddr *)&address,
                        sizeof(address)) != 0) {
                savedError = errno;
                close(socketFD);
                socketFD = -1;
                continue;
            }
        }

        ssize_t written = send(socketFD, record, sizeof(*record), MSG_DONTWAIT);
        sent = written == (ssize_t)sizeof(*record);
        if (sent) break;
        savedError = written < 0 ? errno : EMSGSIZE;

        // The chroot input daemon owns the receiving endpoint and can be
        // restarted independently of this UIKit process. A connected Unix
        // datagram retains the dead endpoint. Runtime evidence on 2026-07-31:
        // the first post-restart Host send failed with errno=39. Recreate the
        // client endpoint once; queue-pressure failures must remain visible.
        if (savedError == EAGAIN || savedError == EWOULDBLOCK ||
            savedError == ENOBUFS) break;
        close(socketFD);
        socketFD = -1;
    }
    pthread_mutex_unlock(&socketLock);

    if (errorOut) *errorOut = savedError;
    return sent;
}

static BOOL MacWSReadCaptureAck(uint64_t *generationOut) {
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

// Read-only witness for Metal's RE-confirmed registration inputs.  The iOS
// 16.3.1 Metal binary's MTLRegisterDevices matches IOAcceleratorES, reads
// MetalPluginName/MetalPluginClassName, and then loads the named bundle.
static void MacWSLogMetalRegistryState(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"), &iterator);
    NSUInteger count = 0;
    io_service_t service;
    while (kr == KERN_SUCCESS && (service = IOIteratorNext(iterator))) {
        count++;
        io_name_t serviceName = {0};
        IORegistryEntryGetName(service, serviceName);
        CFTypeRef pluginValue = IORegistryEntryCreateCFProperty(
            service, CFSTR("MetalPluginName"), kCFAllocatorDefault, 0);
        CFTypeRef classValue = IORegistryEntryCreateCFProperty(
            service, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
        NSString *pluginName = CFBridgingRelease(pluginValue);
        NSString *className = CFBridgingRelease(classValue);
        NSString *bundlePath = pluginName.length
            ? [@"/System/Library/Extensions" stringByAppendingPathComponent:
                [pluginName stringByAppendingString:@".bundle"]]
            : nil;
        NSBundle *bundle = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;
        Class pluginClass = className.length ? NSClassFromString(className) : Nil;
        MacWSLog(@"metal-registry service=%s plugin=%@ class=%@ bundle=%@ loaded=%@ realized=%@",
                 serviceName, pluginName, className, bundlePath,
                 bundle.isLoaded ? @"YES" : @"NO", pluginClass);
        IOObjectRelease(service);
    }
    if (iterator) IOObjectRelease(iterator);
    MacWSLog(@"metal-registry enumeration kr=0x%x count=%lu",
             kr, (unsigned long)count);
}

@interface MacWSMappedFrame : NSObject
@property(nonatomic, readonly) const uint8_t *pixels;
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) uint32_t stride;
@property(nonatomic, readonly) NSString *lastError;
- (BOOL)refresh;
@end

@implementation MacWSMappedFrame {
    void *_mapping;
    size_t _mappingSize;
    dev_t _device;
    ino_t _inode;
    const uint8_t *_pixels;
    uint32_t _width;
    uint32_t _height;
    uint32_t _stride;
    NSString *_lastError;
}

- (void)dealloc {
    if (_mapping) munmap(_mapping, _mappingSize);
}

- (void)setFailure:(NSString *)failure {
    _lastError = failure;
    _pixels = NULL;
    _width = 0;
    _height = 0;
    _stride = 0;
}

- (void)unmap {
    if (_mapping) munmap(_mapping, _mappingSize);
    _mapping = NULL;
    _mappingSize = 0;
    _device = 0;
    _inode = 0;
    _pixels = NULL;
}

- (BOOL)refresh {
    struct stat pathStat;
    const char *path = MacWSFramePath.fileSystemRepresentation;
    if (stat(path, &pathStat) != 0) {
        [self unmap];
        [self setFailure:@"等待 WindowServer 共享帧"];
        return NO;
    }
    if (pathStat.st_size < 16) {
        [self setFailure:@"共享帧尚未初始化"];
        return NO;
    }

    BOOL changed = !_mapping || _mappingSize != (size_t)pathStat.st_size ||
        _device != pathStat.st_dev || _inode != pathStat.st_ino;
    if (changed) {
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            [self setFailure:[NSString stringWithFormat:@"打开共享帧失败: %s",
                              strerror(errno)]];
            return NO;
        }
        struct stat openStat;
        if (fstat(fd, &openStat) != 0 || openStat.st_size < 16) {
            int savedErrno = errno;
            close(fd);
            [self setFailure:[NSString stringWithFormat:@"读取共享帧状态失败: %s",
                              strerror(savedErrno)]];
            return NO;
        }
        size_t newSize = (size_t)openStat.st_size;
        void *newMapping = mmap(NULL, newSize, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (newMapping == MAP_FAILED) {
            [self setFailure:[NSString stringWithFormat:@"映射共享帧失败: %s",
                              strerror(errno)]];
            return NO;
        }
        [self unmap];
        _mapping = newMapping;
        _mappingSize = newSize;
        _device = openStat.st_dev;
        _inode = openStat.st_ino;
    }

    uint32_t header[4];
    memcpy(header, _mapping, sizeof(header));
    uint32_t width = header[1], height = header[2], stride = header[3];
    if (header[0] != MACWS_FRAME_MAGIC || width == 0 || height == 0 ||
        width > 16384 || height > 16384 || stride < width * 4u) {
        [self setFailure:@"共享帧头无效"];
        return NO;
    }
    uint64_t payloadSize = (uint64_t)stride * height;
    if (payloadSize > SIZE_MAX - 16 || 16 + payloadSize > _mappingSize) {
        [self setFailure:@"共享帧长度不完整"];
        return NO;
    }

    _width = width;
    _height = height;
    _stride = stride;
    _pixels = (const uint8_t *)_mapping + 16;
    _lastError = nil;
    return YES;
}

- (const uint8_t *)pixels { return _pixels; }
- (uint32_t)width { return _width; }
- (uint32_t)height { return _height; }
- (uint32_t)stride { return _stride; }
- (NSString *)lastError { return _lastError; }
@end

static uint16_t MacWSMacKeyCodeForHIDUsage(NSInteger usage) {
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

static uint32_t MacWSKeySymForHIDUsage(NSInteger usage, NSString *characters,
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

static NSInteger MacWSHIDUsageForASCII(uint32_t scalar) {
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

@class MacWSMetalView;

typedef NS_ENUM(uint8_t, MacWSDirectTouchState) {
    MacWSDirectTouchStateIdle = 0,
    MacWSDirectTouchStateCandidate,
    MacWSDirectTouchStateScrolling,
    MacWSDirectTouchStateLongPressArmed,
    MacWSDirectTouchStateDragging,
};

@protocol MacWSMetalViewStatusDelegate <NSObject>
- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status;
- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record;
- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows;
- (void)metalView:(MacWSMetalView *)view
 requestedWindowOverviewForCurrentApplication:(BOOL)currentApplicationOnly;
@end

@interface MacWSMetalView : MTKView
    <MTKViewDelegate, MacWSStreamClientDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, weak) id<MacWSMetalViewStatusDelegate> statusDelegate;
@property(nonatomic) uint64_t sceneID;
@property(nonatomic) uint32_t targetWindowID;
@property(nonatomic) int32_t targetPID;
@property(nonatomic, getter=isMacWSInputEnabled) BOOL macWSInputEnabled;
@property(nonatomic) MacWSHostInputMode inputMode;
@property(nonatomic) MacWSHostDisplayDensity displayDensity;
@property(nonatomic) CGFloat fixedZoomScale;
@property(nonatomic) CGSize minimumLogicalSize;
@property(nonatomic) BOOL targetWindowResizable;
@property(nonatomic) BOOL softwareKeyboardActive;
@property(nonatomic, readonly) BOOL hasDirectSurfaceFrame;
@property(nonatomic, readonly) BOOL streamServiceConnected;
@property(nonatomic, readonly) CGFloat effectiveDensityScale;
- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason;
- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID;
- (void)requestStreamWindowList;
- (void)refreshPresentationPolicy;
- (void)resetViewportZoom;
- (void)geometryDidChange;
- (void)suspendStream;
- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers;
- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers;
- (void)updatePresentationGeometry;
- (void)updatePointerVisibility;
- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated;
- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint;
- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase;
- (uint32_t)currentFrameWidth;
- (uint32_t)currentFrameHeight;
- (NSArray<NSNumber *> *)overlayKeysBackToFront;
- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record;
- (void)logPerformanceSnapshotWithReason:(NSString *)reason;
@end

@implementation MacWSMetalView {
    MacWSMappedFrame *_frame;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _sourceTexture;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CGRect _contentRect;
    CGRect _visibleSourceRect;
    BOOL _reportedNonzeroFrame;
    BOOL _submittedPresentWitness;
    NSString *_lastStatus;
    UIView *_directTouchIndicator;
    UIView *_trackpadCursorView;
    UIView *_pencilCursorView;
    UILabel *_inputUnavailableLabel;
    UIView *_tooSmallOverlay;
    UILabel *_tooSmallLabel;
    UIVisualEffectView *_zoomHUD;
    UILabel *_zoomHUDLabel;
    UIImageView *_fallbackImageView;
    CADisplayLink *_framePollDisplayLink;
    uint64_t _fallbackSignature;
    BOOL _reportedFallbackFrame;
    uint64_t _pendingCaptureGeneration;
    uint64_t _presentedCaptureGeneration;
    BOOL _macWSInputEnabled;
    BOOL _windowTooSmall;
    MacWSStreamClient *_streamClient;
    MacWSSurfaceFrame *_surfaceFrame;
    id<MTLTexture> _surfaceTexture;
    NSMutableDictionary<NSNumber *, MacWSSurfaceFrame *> *_overlayFrames;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *_overlayTextures;
    uint64_t _surfaceTextureImports;
    uint64_t _lastPerformanceLogStreamID;
    uint64_t _lastPerformanceLogSequence;
    NSArray<NSNumber *> *_sortedOverlayKeys;
    NSMutableArray<MacWSSurfaceFrame *> *_retiredSurfaceFrames;
    uint64_t _submittedSurfaceSequence;
    BOOL _streamConnected;
    UITouch *_trackpadTouch;
    CGPoint _trackpadCursor;
    CGPoint _trackpadPreviousPoint;
    CGFloat _trackpadTravel;
    NSTimeInterval _trackpadBeganAt;
    BOOL _trackpadButtonDown;
    BOOL _trackpadHadMultipleTouches;
    BOOL _trackpadCursorWasTouched;
    BOOL _externalPointerHoverActive;
    BOOL _pencilHoverActive;
    UITouch *_pencilTouch;
    CGPoint _pencilTouchStartPoint;
    CGFloat _pencilTouchTravel;
    NSTimeInterval _pencilTouchBeganAt;
    UITouch *_directTouch;
    UITouch *_secondaryPointerTouch;
    BOOL _directGestureBlocked;
    MacWSDirectTouchState _directTouchState;
    CGPoint _directTouchStartPoint;
    CGPoint _directTouchPreviousPoint;
    CGPoint _directScrollVelocity;
    CGPoint _directScrollFramePoint;
    MacWSDirectScrollAxis _directScrollAxis;
    NSTimeInterval _directTouchStartTimestamp;
    NSTimeInterval _directTouchPreviousTimestamp;
    NSTimeInterval _lastDirectTapTimestamp;
    CGPoint _lastDirectTapPoint;
    uint64_t _directTouchSerial;
    UIImpactFeedbackGenerator *_directTouchFeedback;
    CGFloat _viewportZoom;
    CGPoint _viewportCenter;
    CGFloat _fixedZoomScale;
    BOOL _contentGesturesPassthrough;
    UIPanGestureRecognizer *_twoFingerPanRecognizer;
    UIPinchGestureRecognizer *_pinchRecognizer;
    UIPanGestureRecognizer *_threeFingerPanRecognizer;
    BOOL _threeFingerCommandDispatched;
    CADisplayLink *_scrollMomentumDisplayLink;
    CGPoint _scrollMomentumVelocity;
    CGPoint _scrollMomentumFramePoint;
    CGPoint _scrollEmissionResidual;
    CFTimeInterval _scrollMomentumLastTimestamp;
    BOOL _scrollMomentumBegan;
    BOOL _windowConfigurationDispatchPending;
    CGSize _pendingRequestedWindowSize;
    CGFloat _pendingRequestedDensityScale;
    uint32_t _inputSampleSequence;
    CGSize _lastRequestedWindowSize;
    CGFloat _lastRequestedDensityScale;
    uint64_t _windowConfigurationSettlementSerial;
    BOOL _windowConfigurationAwaitingAcknowledgement;
    BOOL _fullscreenGestureRouteActive;
    uint32_t _fullscreenGestureRouteContactID;
    int32_t _fullscreenGestureRoutePID;
    uint32_t _fullscreenGestureRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenGestureRouteDescriptor;
    CFTimeInterval _fullscreenLastTapRouteTimestamp;
    int32_t _fullscreenLastTapRoutePID;
    uint32_t _fullscreenLastTapRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenLastTapRouteDescriptor;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) return nil;

    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // The producer publishes acknowledged snapshots, not a live 20-fps pixel
    // stream.  Continuous MTKView drawing uploaded the unchanged 15.2-MiB
    // frame 20 times per second and runtime-measured as 13-15% App CPU.  Poll
    // only the tiny generation ACK and draw exactly once per new snapshot.
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0.025, 0.028, 0.035, 1.0);
    self.multipleTouchEnabled = YES;
    self.inputMode = MacWSHostInputModeDirect;
    self.fixedZoomScale = 1.5;
    self.displayDensity = MacWSHostDisplayDensityTouchComfort;
    // Status polling enables interaction only after WindowServer, the input
    // socket and an exact-PID acknowledged frame are all present.  A stale
    // screenshot must never look like a live, touchable workspace.
    self.userInteractionEnabled = NO;

    _frame = [MacWSMappedFrame new];
    _streamClient = [MacWSStreamClient new];
    _streamClient.delegate = self;
    _overlayFrames = [NSMutableDictionary dictionary];
    _overlayTextures = [NSMutableDictionary dictionary];
    _retiredSurfaceFrames = [NSMutableArray array];
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"MacWSHost display queue";
    _contentRect = CGRectZero;
    _visibleSourceRect = CGRectMake(0, 0, 1, 1);
    _trackpadCursor = CGPointMake(-1, -1);
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _directTouchState = MacWSDirectTouchStateIdle;
    _directTouchFeedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];

    // Direct touch uses a soft contact halo.  It is deliberately different
    // from the trackpad cursor: one represents the finger's absolute contact,
    // the other represents persistent relative-pointer state.
    _directTouchIndicator = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 30, 30)];
    _directTouchIndicator.backgroundColor =
        [UIColor.systemCyanColor colorWithAlphaComponent:0.15];
    _directTouchIndicator.layer.borderWidth = 1.5;
    _directTouchIndicator.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.82].CGColor;
    _directTouchIndicator.layer.cornerRadius = 15;
    _directTouchIndicator.layer.shadowColor = UIColor.blackColor.CGColor;
    _directTouchIndicator.layer.shadowOpacity = 0.22;
    _directTouchIndicator.layer.shadowRadius = 5;
    _directTouchIndicator.layer.shadowOffset = CGSizeMake(0, 2);
    _directTouchIndicator.userInteractionEnabled = NO;
    _directTouchIndicator.hidden = YES;
    UIView *contactDot = [[UIView alloc] initWithFrame:CGRectMake(11, 11, 8, 8)];
    contactDot.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.92];
    contactDot.layer.cornerRadius = 4;
    contactDot.userInteractionEnabled = NO;
    [_directTouchIndicator addSubview:contactDot];
    [self addSubview:_directTouchIndicator];

    // A finger-driven relative trackpad controls a macOS desktop, so represent
    // its persistent position with the familiar macOS arrow rather than the
    // iPad direct-manipulation circle. Hardware Magic Keyboard pointers keep
    // UIKit's native adaptive pointer and do not draw this overlay.
    _trackpadCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 22, 28)];
    _trackpadCursorView.backgroundColor = UIColor.clearColor;
    _trackpadCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _trackpadCursorView.layer.shadowOpacity = 0.42;
    _trackpadCursorView.layer.shadowRadius = 2.5;
    _trackpadCursorView.layer.shadowOffset = CGSizeMake(0, 1.0);
    _trackpadCursorView.userInteractionEnabled = NO;
    _trackpadCursorView.hidden = YES;
    CAShapeLayer *arrow = [CAShapeLayer layer];
    UIBezierPath *arrowPath = [UIBezierPath bezierPath];
    [arrowPath moveToPoint:CGPointMake(2.0, 1.5)];
    [arrowPath addLineToPoint:CGPointMake(2.0, 22.5)];
    [arrowPath addLineToPoint:CGPointMake(7.6, 17.1)];
    [arrowPath addLineToPoint:CGPointMake(11.5, 26.0)];
    [arrowPath addLineToPoint:CGPointMake(15.0, 24.4)];
    [arrowPath addLineToPoint:CGPointMake(11.1, 15.8)];
    [arrowPath addLineToPoint:CGPointMake(19.0, 15.4)];
    [arrowPath closePath];
    arrow.path = arrowPath.CGPath;
    arrow.fillColor = UIColor.blackColor.CGColor;
    arrow.strokeColor = UIColor.whiteColor.CGColor;
    arrow.lineWidth = 1.25;
    arrow.lineJoin = kCALineJoinRound;
    [_trackpadCursorView.layer addSublayer:arrow];
    [self addSubview:_trackpadCursorView];

    // Pencil hover follows iPad's precise-pointer visual language. Native
    // in-air updates arrive only on hover-capable hardware; contact movement
    // remains a non-clicking preview on older iPads until a short tap ends.
    _pencilCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 20, 20)];
    _pencilCursorView.backgroundColor =
        [UIColor.systemGrayColor colorWithAlphaComponent:0.72];
    _pencilCursorView.layer.borderWidth = 1.0;
    _pencilCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.90].CGColor;
    _pencilCursorView.layer.cornerRadius = 10;
    _pencilCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _pencilCursorView.layer.shadowOpacity = 0.28;
    _pencilCursorView.layer.shadowRadius = 4;
    _pencilCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _pencilCursorView.userInteractionEnabled = NO;
    _pencilCursorView.hidden = YES;
    [self addSubview:_pencilCursorView];

    _inputUnavailableLabel = [UILabel new];
    _inputUnavailableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _inputUnavailableLabel.text = @"触控暂不可用 · macOS 工作区未就绪";
    _inputUnavailableLabel.textColor = UIColor.whiteColor;
    _inputUnavailableLabel.backgroundColor =
        [UIColor.systemOrangeColor colorWithAlphaComponent:0.88];
    _inputUnavailableLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _inputUnavailableLabel.textAlignment = NSTextAlignmentCenter;
    _inputUnavailableLabel.numberOfLines = 0;
    _inputUnavailableLabel.layer.cornerRadius = 12;
    _inputUnavailableLabel.clipsToBounds = YES;
    _inputUnavailableLabel.userInteractionEnabled = NO;
    [self addSubview:_inputUnavailableLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_inputUnavailableLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_inputUnavailableLabel.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                                                            constant:-18],
        [_inputUnavailableLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor
                                                                    multiplier:0.82],
        [_inputUnavailableLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
    ]];

    _tooSmallOverlay = [UIView new];
    _tooSmallOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallOverlay.backgroundColor =
        [UIColor.systemBackgroundColor colorWithAlphaComponent:0.98];
    _tooSmallOverlay.hidden = YES;
    _tooSmallOverlay.userInteractionEnabled = NO;
    [self addSubview:_tooSmallOverlay];
    _tooSmallLabel = [UILabel new];
    _tooSmallLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallLabel.numberOfLines = 0;
    _tooSmallLabel.textAlignment = NSTextAlignmentCenter;
    _tooSmallLabel.textColor = UIColor.labelColor;
    _tooSmallLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [_tooSmallOverlay addSubview:_tooSmallLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_tooSmallOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tooSmallOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tooSmallOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_tooSmallOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_tooSmallLabel.centerXAnchor constraintEqualToAnchor:_tooSmallOverlay.centerXAnchor],
        [_tooSmallLabel.centerYAnchor constraintEqualToAnchor:_tooSmallOverlay.centerYAnchor],
        [_tooSmallLabel.widthAnchor constraintLessThanOrEqualToAnchor:_tooSmallOverlay.widthAnchor
                                                             multiplier:0.82],
    ]];

    _zoomHUD = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _zoomHUD.translatesAutoresizingMaskIntoConstraints = NO;
    _zoomHUD.layer.cornerRadius = 13;
    _zoomHUD.clipsToBounds = YES;
    _zoomHUD.hidden = YES;
    [self addSubview:_zoomHUD];
    _zoomHUDLabel = [UILabel new];
    _zoomHUDLabel.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                         weight:UIFontWeightSemibold];
    _zoomHUDLabel.textColor = UIColor.labelColor;
    _zoomHUDLabel.textAlignment = NSTextAlignmentCenter;
    [_zoomHUDLabel.widthAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    UIStackView *zoomHUDContent = [[UIStackView alloc]
        initWithArrangedSubviews:@[_zoomHUDLabel]];
    zoomHUDContent.translatesAutoresizingMaskIntoConstraints = NO;
    zoomHUDContent.axis = UILayoutConstraintAxisHorizontal;
    zoomHUDContent.alignment = UIStackViewAlignmentCenter;
    zoomHUDContent.spacing = 7;
    zoomHUDContent.layoutMargins = UIEdgeInsetsMake(7, 9, 7, 9);
    zoomHUDContent.layoutMarginsRelativeArrangement = YES;
    [_zoomHUD.contentView addSubview:zoomHUDContent];
    [NSLayoutConstraint activateConstraints:@[
        [_zoomHUD.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor
                                                 constant:-12],
        [_zoomHUD.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                                            constant:12],
        [zoomHUDContent.leadingAnchor constraintEqualToAnchor:_zoomHUD.contentView.leadingAnchor],
        [zoomHUDContent.trailingAnchor constraintEqualToAnchor:_zoomHUD.contentView.trailingAnchor],
        [zoomHUDContent.topAnchor constraintEqualToAnchor:_zoomHUD.contentView.topAnchor],
        [zoomHUDContent.bottomAnchor constraintEqualToAnchor:_zoomHUD.contentView.bottomAnchor],
    ]];

    if (device) {
        [self buildPipeline];
    } else {
        self.paused = YES;
        _fallbackImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _fallbackImageView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fallbackImageView.backgroundColor = UIColor.blackColor;
        _fallbackImageView.contentMode = UIViewContentModeScaleAspectFit;
        _fallbackImageView.clipsToBounds = YES;
        _fallbackImageView.userInteractionEnabled = NO;
        [self insertSubview:_fallbackImageView atIndex:0];
        MacWSLog(@"native Metal device unavailable; UIKit fallback armed");
    }

    _framePollDisplayLink = [CADisplayLink displayLinkWithTarget:self
        selector:@selector(pollSharedFrame:)];
    _framePollDisplayLink.preferredFramesPerSecond = 5;
    _framePollDisplayLink.paused = !MacWSLegacyFramebufferFallbackEnabled();
    [_framePollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                               forMode:NSRunLoopCommonModes];

    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(hovered:)];
        hover.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:hover];
        UIHoverGestureRecognizer *pencilHover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(pencilHovered:)];
        pencilHover.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:pencilHover];
    }
    _twoFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(twoFingerPanned:)];
    _twoFingerPanRecognizer.minimumNumberOfTouches = 2;
    _twoFingerPanRecognizer.maximumNumberOfTouches = 2;
    _twoFingerPanRecognizer.cancelsTouchesInView = YES;
    _twoFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_twoFingerPanRecognizer];
    _pinchRecognizer = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(pinched:)];
    _pinchRecognizer.cancelsTouchesInView = YES;
    _pinchRecognizer.delegate = self;
    [self addGestureRecognizer:_pinchRecognizer];
    _threeFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(threeFingerPanned:)];
    _threeFingerPanRecognizer.minimumNumberOfTouches = 3;
    _threeFingerPanRecognizer.maximumNumberOfTouches = 3;
    _threeFingerPanRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _threeFingerPanRecognizer.cancelsTouchesInView = YES;
    _threeFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_threeFingerPanRecognizer];
    UITapGestureRecognizer *resetZoom = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(viewportZoomToggled:)];
    resetZoom.numberOfTouchesRequired = 2;
    resetZoom.numberOfTapsRequired = 2;
    resetZoom.cancelsTouchesInView = YES;
    [self addGestureRecognizer:resetZoom];
    UITapGestureRecognizer *secondaryTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(trackpadSecondaryTapped:)];
    secondaryTap.numberOfTouchesRequired = 2;
    secondaryTap.cancelsTouchesInView = NO;
    [secondaryTap requireGestureRecognizerToFail:resetZoom];
    [self addGestureRecognizer:secondaryTap];
    return self;
}

- (void)dealloc {
    [_framePollDisplayLink invalidate];
    [_scrollMomentumDisplayLink invalidate];
    if (_surfaceFrame) [_streamClient releaseFrame:_surfaceFrame];
    for (MacWSSurfaceFrame *frame in _overlayFrames.allValues)
        [_streamClient releaseFrame:frame];
    for (MacWSSurfaceFrame *frame in _retiredSurfaceFrames)
        [_streamClient releaseFrame:frame];
    [_streamClient invalidate];
}

- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID {
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _lastRequestedWindowSize = CGSizeZero;
    _fullscreenGestureRouteActive = NO;
    _fullscreenGestureRouteContactID = 0;
    _fullscreenGestureRoutePID = 0;
    _fullscreenGestureRouteWindowID = 0;
    _fullscreenGestureRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    _fullscreenLastTapRouteTimestamp = 0.0;
    _fullscreenLastTapRoutePID = 0;
    _fullscreenLastTapRouteWindowID = 0;
    _fullscreenLastTapRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    self.targetWindowID = mode == MacWSStreamModeWindow ? windowID : 0;
    // A window Scene must only display the IOSurface exported for that window.
    // The mmap framebuffer is a full-desktop compatibility path and would show
    // a misleading crop while the direct stream is negotiating its first frame.
    _framePollDisplayLink.paused = self.targetWindowID != 0 ||
        !MacWSLegacyFramebufferFallbackEnabled();
    [_streamClient subscribeToMode:mode windowID:windowID];
    [self refreshPresentationPolicy];
}

- (uint64_t)inputSceneIDWithModifiers:(uint32_t)modifiers {
    if (self.targetWindowID != 0)
        return MacWSInputSceneForWindow(self.targetWindowID, modifiers);
    return modifiers ? (uint64_t)modifiers : self.sceneID;
}

- (void)requestStreamWindowList {
    [_streamClient requestWindowList];
}

- (void)suspendStream {
    _framePollDisplayLink.paused = YES;
    [_streamClient unsubscribe];
    NSMutableArray<MacWSSurfaceFrame *> *leases =
        [_retiredSurfaceFrames mutableCopy];
    [_retiredSurfaceFrames removeAllObjects];
    if (_surfaceFrame) [leases addObject:_surfaceFrame];
    [leases addObjectsFromArray:_overlayFrames.allValues];
    _surfaceFrame = nil;
    _surfaceTexture = nil;
    [_overlayFrames removeAllObjects];
    [_overlayTextures removeAllObjects];
    _sortedOverlayKeys = nil;
    _sourceTexture = nil;
    _textureWidth = 0;
    _textureHeight = 0;
    _contentRect = CGRectZero;
    // A UIWindow/Stage Manager maximization animation can rescale the last
    // CAMetalDrawable before the replacement DisplayStream generation lands.
    // Rendering a deterministic clear frame prevents that stale exact-window
    // image from appearing as a cropped/magnified full desktop.
    _submittedPresentWitness = NO;
    _directTouchIndicator.hidden = YES;
    _trackpadCursorView.hidden = YES;
    if (leases.count && _commandQueue) {
        id<MTLCommandBuffer> fence = [_commandQueue commandBuffer];
        __weak MacWSStreamClient *weakClient = _streamClient;
        [fence addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            for (MacWSSurfaceFrame *frame in leases)
                [weakClient releaseFrame:frame];
        }];
        [fence commit];
    } else {
        for (MacWSSurfaceFrame *frame in leases)
            [_streamClient releaseFrame:frame];
    }
    [self setNeedsDisplay];
}

- (uint32_t)currentFrameWidth {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentWidth : _frame.width;
}

- (uint32_t)currentFrameHeight {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentHeight : _frame.height;
}

- (CGFloat)effectiveDensityScale {
    // Pixel matching is dynamic under Stage Manager: UIKit may render a Scene
    // at an effective scale below the panel's nominal 2x scale.  Match the
    // macOS IOSurface's actual backing pixels to the MTK drawable pixels, then
    // apply the user's optional more-space factor.  Runtime witness on the
    // target iPad measured backing=2.000 and drawable/bounds~=1.72, yielding a
    // native density near 1.16 rather than either the old 1.35 or a fixed 1.0.
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 2.0;
    CGFloat scaleX = self.bounds.size.width > 0 && self.drawableSize.width > 0
        ? self.drawableSize.width / self.bounds.size.width : self.contentScaleFactor;
    CGFloat scaleY = self.bounds.size.height > 0 && self.drawableSize.height > 0
        ? self.drawableSize.height / self.bounds.size.height : self.contentScaleFactor;
    CGFloat drawableScale = (scaleX + scaleY) * 0.5;
    if (!isfinite(drawableScale) || drawableScale < 0.5)
        drawableScale = 2.0;
    CGFloat pixelMatched = backingScale / drawableScale;
    pixelMatched = fmin(fmax(pixelMatched, 0.5), 2.0);
    return pixelMatched * MacWSDensityModeFactor(self.displayDensity);
}

- (BOOL)hasDirectSurfaceFrame { return _surfaceFrame != nil; }
- (BOOL)streamServiceConnected { return _streamClient.isConnected; }

- (void)setTargetPID:(int32_t)targetPID {
    if (_targetPID == targetPID) return;
    _targetPID = targetPID;
    [self refreshPresentationPolicy];
}

- (void)setDisplayDensity:(MacWSHostDisplayDensity)displayDensity {
    if (displayDensity != MacWSHostDisplayDensityTouchComfort &&
        displayDensity != MacWSHostDisplayDensityKeyboard &&
        displayDensity != MacWSHostDisplayDensityComfort) return;
    _displayDensity = displayDensity;
    _lastRequestedWindowSize = CGSizeZero;
    [self resetViewportZoom];
    [self geometryDidChange];
}

- (void)setFixedZoomScale:(CGFloat)fixedZoomScale {
    CGFloat normalized = fixedZoomScale >= 1.75 ? 2.0 : 1.5;
    BOOL wasZoomed = _viewportZoom > 1.001;
    _fixedZoomScale = normalized;
    if (wasZoomed) {
        _viewportZoom = normalized;
        [self setNeedsDisplay];
    }
    [self updateZoomHUD];
}

- (BOOL)isViewportZoomed {
    return _viewportZoom > 1.001;
}

- (void)updateZoomHUD {
    BOOL visible = [self isViewportZoomed] && !_windowTooSmall;
    _zoomHUD.hidden = !visible;
    _zoomHUDLabel.text = [NSString stringWithFormat:@"%.1f×", _viewportZoom];
}

- (void)setMinimumLogicalSize:(CGSize)minimumLogicalSize {
    _minimumLogicalSize = (CGSize){
        isfinite(minimumLogicalSize.width) && minimumLogicalSize.width > 0
            ? minimumLogicalSize.width : 0,
        isfinite(minimumLogicalSize.height) && minimumLogicalSize.height > 0
            ? minimumLogicalSize.height : 0,
    };
    [self refreshPresentationPolicy];
}

- (void)setTargetWindowResizable:(BOOL)targetWindowResizable {
    _targetWindowResizable = targetWindowResizable;
    [self refreshPresentationPolicy];
}

- (void)updateWindowTooSmallState {
    CGFloat density = self.effectiveDensityScale;
    CGSize available = self.bounds.size;
    CGFloat requiredWidth = self.minimumLogicalSize.width * density;
    CGFloat requiredHeight = self.minimumLogicalSize.height * density;
    BOOL hasRequirement = self.targetWindowID != 0 &&
        (requiredWidth > 0 || requiredHeight > 0);
    _windowTooSmall = hasRequirement &&
        ((requiredWidth > 0 && available.width + 0.5 < requiredWidth) ||
         (requiredHeight > 0 && available.height + 0.5 < requiredHeight));
    _tooSmallOverlay.hidden = !_windowTooSmall;
    _inputUnavailableLabel.hidden = _windowTooSmall || _macWSInputEnabled;
    self.userInteractionEnabled = _macWSInputEnabled && !_windowTooSmall;
    if (_windowTooSmall) {
        NSString *densityName = self.displayDensity ==
            MacWSHostDisplayDensityKeyboard ? @"更多空间" :
            (self.displayDensity == MacWSHostDisplayDensityComfort
                ? @"放大 +10%" : @"像素匹配 Retina");
        _tooSmallLabel.text = [NSString stringWithFormat:
            @"窗口太小\n\n此 macOS 应用至少需要 %.0f × %.0f 点\n"
             "当前 %@ 模式需要约 %.0f × %.0f iPad 点\n\n"
             "请放大 iPadOS 窗口，或切换到更多空间模式。",
            self.minimumLogicalSize.width,
            self.minimumLogicalSize.height,
            densityName, requiredWidth, requiredHeight];
    }
    [self updateZoomHUD];
    [self updatePointerVisibility];
}

- (void)scheduleWindowConfiguration {
    if (self.targetWindowID == 0 || self.targetPID <= 1 ||
        _windowTooSmall || self.bounds.size.width < 64 ||
        self.bounds.size.height < 64) return;
    CGFloat density = self.effectiveDensityScale;
    CGSize requested = {
        self.bounds.size.width / density,
        self.bounds.size.height / density,
    };
    _pendingRequestedWindowSize = requested;
    _pendingRequestedDensityScale = density;
    if (_windowConfigurationDispatchPending) return;
    _windowConfigurationDispatchPending = YES;
    // Stage Manager can report geometry on every display refresh.  Coalesce
    // those callbacks into the newest AppKit size at a bounded 30-Hz rate,
    // rather than waiting for a 180-ms quiet period after the drag.  This
    // preserves AppKit's real minimum-size validation while making the macOS
    // content follow the iPad window continuously.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_windowConfigurationDispatchPending = NO;
        if (self->_windowTooSmall || self.targetPID <= 1 ||
            self.targetWindowID == 0) return;
        CGSize requested = self->_pendingRequestedWindowSize;
        CGFloat density = self->_pendingRequestedDensityScale;
        if (fabs(requested.width - self->_lastRequestedWindowSize.width) < 1.0 &&
            fabs(requested.height - self->_lastRequestedWindowSize.height) < 1.0 &&
            fabs(density - self->_lastRequestedDensityScale) < 0.001) return;
        self->_lastRequestedWindowSize = requested;
        self->_lastRequestedDensityScale = density;
        self->_windowConfigurationAwaitingAcknowledgement = YES;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindConfigureWindow,
            .sceneID = MacWSInputSceneForWindow(self.targetWindowID, 0),
            .timestamp = CACurrentMediaTime(),
            .x = (float)requested.width,
            .y = (float)requested.height,
            .pressure = (float)density,
            .frameWidth = (uint32_t)ceil(requested.width) + 1,
            .frameHeight = (uint32_t)ceil(requested.height) + 1,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceUnknown,
            .flags = MacWSInputFlagConfigureAnchorTopRight,
            .sampleSequence = ++self->_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
        // Electron restores its persisted NSWindow frame after the first
        // DisplayStream/Scene transaction. A single datagram can therefore be
        // accepted and then legitimately superseded. Re-assert the same native
        // frame invariant at three bounded settlement points. A new Scene size,
        // density, target, or suspension changes the serial and cancels these
        // retries; this is not a periodic poll and does not touch WindowServer.
        uint64_t settlementSerial = ++self->_windowConfigurationSettlementSerial;
        const int64_t retryNanoseconds[] = {
            350 * NSEC_PER_MSEC,
            1200 * NSEC_PER_MSEC,
            3000 * NSEC_PER_MSEC,
        };
        for (NSUInteger index = 0;
             index < sizeof(retryNanoseconds) / sizeof(retryNanoseconds[0]);
             index++) {
            int64_t delay = retryNanoseconds[index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                           dispatch_get_main_queue(), ^{
                if (self->_windowConfigurationSettlementSerial !=
                        settlementSerial ||
                    !self->_windowConfigurationAwaitingAcknowledgement ||
                    self->_windowTooSmall || self.targetPID <= 1 ||
                    self.targetWindowID == 0 ||
                    fabs(self->_pendingRequestedWindowSize.width -
                         requested.width) >= 1.0 ||
                    fabs(self->_pendingRequestedWindowSize.height -
                         requested.height) >= 1.0 ||
                    fabs(self->_pendingRequestedDensityScale - density) >=
                         0.001) return;
                MacWSInputRecord retry = record;
                retry.timestamp = CACurrentMediaTime();
                retry.sampleSequence = ++self->_inputSampleSequence;
                [self.statusDelegate metalView:self emittedInput:retry];
            });
        }
    });
}

- (void)refreshPresentationPolicy {
    [self updateWindowTooSmallState];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)geometryDidChange {
    // Geometry changes invalidate the view-to-surface transform immediately;
    // do not leave an old down/scroll sequence alive across rotation or a
    // Stage Manager resize.
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_trackpadTouch && _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _directTouchSerial++;
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directGestureBlocked = NO;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadHadMultipleTouches = NO;
    [self stopScrollMomentumWithTerminalPhase:YES];
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)setMacWSInputEnabled:(BOOL)enabled {
    [self setMacWSInputEnabled:enabled reason:nil];
}

- (BOOL)isMacWSInputEnabled {
    return _macWSInputEnabled && !_windowTooSmall;
}

- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason {
    if (!enabled && _macWSInputEnabled) {
        if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
            [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                     point:[_directTouch locationInView:self]];
        } else if (_directTouch &&
                   _directTouchState == MacWSDirectTouchStateScrolling) {
            [self emitScrollAtFramePoint:_directScrollFramePoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
        }
        if (_trackpadTouch && _trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:CACurrentMediaTime()];
        }
        _directTouchSerial++;
        _directTouch = nil;
        _directTouchState = MacWSDirectTouchStateIdle;
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self stopScrollMomentumWithTerminalPhase:YES];
        [self setTrackpadPointerPressed:NO animated:NO];
    }
    _macWSInputEnabled = enabled;
    if (!enabled) {
        _directTouchIndicator.hidden = YES;
        _trackpadCursorView.hidden = YES;
        _inputUnavailableLabel.text = [NSString stringWithFormat:
            @"触控暂不可用 · %@", reason.length ? reason : @"工作区未就绪"];
    }
    [self updateWindowTooSmallState];
    [self updatePointerVisibility];
}

- (void)setInputMode:(MacWSHostInputMode)inputMode {
    if (inputMode != MacWSHostInputModeDirect &&
        inputMode != MacWSHostInputModeTrackpad) return;
    if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
        _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_inputMode == MacWSHostInputModeTrackpad && _trackpadTouch &&
        _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _inputMode = inputMode;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadTravel = 0;
    _trackpadHadMultipleTouches = NO;
    _trackpadCursorWasTouched = NO;
    _externalPointerHoverActive = NO;
    _directTouch = nil;
    _directGestureBlocked = NO;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directTouchSerial++;
    [self stopScrollMomentumWithTerminalPhase:YES];
    _directTouchIndicator.hidden = YES;
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePointerVisibility];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)emitKeyPresses:(NSSet<UIPress *> *)presses kind:(MacWSInputKind)kind {
    if (!self.isMacWSInputEnabled) return;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width == 0 || height == 0) return;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        uint16_t keyCode = MacWSMacKeyCodeForHIDUsage(key.keyCode);
        if (keyCode == UINT16_MAX) continue;
        uint32_t keySym = MacWSKeySymForHIDUsage(
            key.keyCode, key.characters, key.modifierFlags);
        if (keySym == 0) continue;
        CGPoint keyPoint = _trackpadCursor;
        if (keyPoint.x < 0 || keyPoint.y < 0 ||
            keyPoint.x >= width || keyPoint.y >= height)
            keyPoint = CGPointMake(width * 0.5, height * 0.5);
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            // AppInputBridge's established v3 keyboard ABI stores AppKit-
            // compatible modifier bits in sceneID's low 32 bits.
            .sceneID = [self inputSceneIDWithModifiers:
                (uint32_t)key.modifierFlags],
            .timestamp = press.timestamp,
            .x = (float)keyPoint.x,
            .y = (float)keyPoint.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceHardwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
    }
}

- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers {
    if (!self.isMacWSInputEnabled || keySym == 0) return;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width == 0 || height == 0) return;
    uint32_t scalar = (keySym & 0xff000000u) == 0x01000000u
        ? keySym & 0x00ffffffu : keySym;
    NSInteger usage = MacWSHIDUsageForASCII(scalar);
    uint16_t keyCode = usage >= 0
        ? MacWSMacKeyCodeForHIDUsage(usage) : 0;
    switch (keySym) {
        case 0xff08: keyCode = 51; break;
        case 0xff09: keyCode = 48; break;
        case 0xff0d: keyCode = 36; break;
        case 0xff1b: keyCode = 53; break;
        case 0xff51: keyCode = 123; break;
        case 0xff52: keyCode = 126; break;
        case 0xff53: keyCode = 124; break;
        case 0xff54: keyCode = 125; break;
        default: break;
    }
    CGPoint point = _trackpadCursor;
    if (point.x < 0 || point.y < 0 || point.x >= width || point.y >= height)
        point = CGPointMake(width * 0.5, height * 0.5);
    for (MacWSInputKind kind = MacWSInputKindKeyDown;
         kind <= MacWSInputKindKeyUp; kind++) {
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            .sceneID = [self inputSceneIDWithModifiers:modifiers],
            .timestamp = CACurrentMediaTime(),
            .x = (float)point.x,
            .y = (float)point.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceSoftwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
    }
}

- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers {
    if (!text.length) return;
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *scalars = utf32.bytes;
    for (NSUInteger index = 0; index < utf32.length / sizeof(uint32_t); index++) {
        uint32_t scalar = scalars[index];
        uint32_t keySym = scalar > 0xffu ? 0x01000000u | scalar : scalar;
        if (scalar == '\n' || scalar == '\r') keySym = 0xff0d;
        else if (scalar == '\t') keySym = 0xff09;
        else if (scalar == '\b') keySym = 0xff08;
        [self emitSoftwareKeySym:keySym modifiers:modifiers];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyDown];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
                withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesCancelled:presses withEvent:event];
}

- (void)buildPipeline {
    if (!self.device) {
        [self publishStatus:@"此设备没有可用的原生 Metal Device"];
        return;
    }
    static NSString *const shaderSource =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 position [[position]]; float2 uv; };\n"
         "vertex VOut macws_vertex(uint vid [[vertex_id]],\n"
         "    constant float4 *vertices [[buffer(0)]]) {\n"
         "  VOut o; o.position = float4(vertices[vid].xy, 0.0, 1.0);\n"
         "  o.uv = vertices[vid].zw; return o;\n"
         "}\n"
         "fragment half4 macws_fragment(VOut in [[stage_in]],\n"
         "    texture2d<half> image [[texture(0)]]) {\n"
         "  constexpr sampler s(coord::normalized, address::clamp_to_edge,\n"
         "                      filter::linear);\n"
         "  return image.sample(s, in.uv);\n"
         "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource
                                                      options:nil error:&error];
    if (!library) {
        [self publishStatus:[NSString stringWithFormat:@"Metal shader 编译失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
        return;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"MacWSHost BGRA display pipeline";
    descriptor.vertexFunction = [library newFunctionWithName:@"macws_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"macws_fragment"];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
    if (!_pipeline) {
        [self publishStatus:[NSString stringWithFormat:@"Metal pipeline 创建失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
    }
}

- (void)publishStatus:(NSString *)status {
    if (!status || [_lastStatus isEqualToString:status]) return;
    _lastStatus = [status copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusDelegate metalView:self statusChanged:status];
    });
}

- (BOOL)ensureSourceTexture {
    if (_sourceTexture && _textureWidth == _frame.width &&
        _textureHeight == _frame.height) return YES;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:_frame.width
                                                          height:_frame.height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    _sourceTexture = [self.device newTextureWithDescriptor:descriptor];
    _sourceTexture.label = @"MacWSHost mmap upload";
    _textureWidth = _frame.width;
    _textureHeight = _frame.height;
    _reportedNonzeroFrame = NO;
    return _sourceTexture != nil;
}

- (void)updateContentRectAndVertices:(simd_float4 [4])vertices {
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    // At 1x, preserve the complete macOS window. A Scene aspect mismatch may
    // add small margins, but must never crop title bars, traffic lights, or
    // resize edges. This invariant also applies while AppKit is producing the
    // replacement IOSurface during a Stage Manager or orientation resize: an
    // old correctly proportioned frame may letterbox briefly, but is never
    // stretched. Deliberate 1.5x/2x zoom uses the crop/pan path below.
    if (_viewportZoom <= 1.001 && frameWidth > 0 && frameHeight > 0 &&
        viewWidth > 0 && viewHeight > 0) {
        CGFloat pixelScaleX = self.drawableSize.width > 0
            ? self.drawableSize.width / viewWidth : self.contentScaleFactor;
        CGFloat pixelScaleY = self.drawableSize.height > 0
            ? self.drawableSize.height / viewHeight : self.contentScaleFactor;
        if (!isfinite(pixelScaleX) || pixelScaleX <= 0) pixelScaleX = 1.0;
        if (!isfinite(pixelScaleY) || pixelScaleY <= 0) pixelScaleY = 1.0;
        CGFloat viewPixelWidth = viewWidth * pixelScaleX;
        CGFloat viewPixelHeight = viewHeight * pixelScaleY;
        CGFloat scale = MIN(viewPixelWidth / frameWidth,
                            viewPixelHeight / frameHeight);
        CGFloat fittedPixelWidth = round(frameWidth * scale);
        CGFloat fittedPixelHeight = round(frameHeight * scale);
        CGFloat originPixelX = round((viewPixelWidth - fittedPixelWidth) * 0.5);
        CGFloat originPixelY = round((viewPixelHeight - fittedPixelHeight) * 0.5);
        _contentRect = CGRectMake(originPixelX / pixelScaleX,
                                  originPixelY / pixelScaleY,
                                  fittedPixelWidth / pixelScaleX,
                                  fittedPixelHeight / pixelScaleY);
        _visibleSourceRect = CGRectMake(0, 0, 1, 1);
        _viewportCenter = CGPointMake(0.5, 0.5);
        _viewportZoom = 1.0;
        CGFloat left = CGRectGetMinX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat right = CGRectGetMaxX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat top = 1.0 - CGRectGetMinY(_contentRect) / viewHeight * 2.0;
        CGFloat bottom = 1.0 - CGRectGetMaxY(_contentRect) / viewHeight * 2.0;
        vertices[0] = (simd_float4){left, bottom, 0, 1};
        vertices[1] = (simd_float4){right, bottom, 1, 1};
        vertices[2] = (simd_float4){left, top, 0, 0};
        vertices[3] = (simd_float4){right, top, 1, 0};
        return;
    }
    MacWSViewport viewport = {0};
    BOOL valid = MacWSComputeViewport(
        frameWidth, frameHeight, viewWidth, viewHeight, _viewportZoom,
        _viewportCenter.x, _viewportCenter.y, &viewport);
    if (!valid) {
        viewport = (MacWSViewport){
            .visibleSource = {0, 0, 1, 1},
            .centerX = 0.5,
            .centerY = 0.5,
            .zoom = 1.0,
        };
    }
    _viewportZoom = viewport.zoom;
    _viewportCenter = CGPointMake(viewport.centerX, viewport.centerY);
    _visibleSourceRect = CGRectMake(
        viewport.visibleSource.x, viewport.visibleSource.y,
        viewport.visibleSource.width, viewport.visibleSource.height);
    _contentRect = self.bounds;
    CGFloat minX = CGRectGetMinX(_visibleSourceRect);
    CGFloat maxX = CGRectGetMaxX(_visibleSourceRect);
    CGFloat minY = CGRectGetMinY(_visibleSourceRect);
    CGFloat maxY = CGRectGetMaxY(_visibleSourceRect);
    // A user-requested enlarged view fills the Scene and pans over a bounded
    // source crop.
    vertices[0] = (simd_float4){-1, -1, minX, maxY};
    vertices[1] = (simd_float4){ 1, -1, maxX, maxY};
    vertices[2] = (simd_float4){-1,  1, minX, minY};
    vertices[3] = (simd_float4){ 1,  1, maxX, minY};
}

- (void)updatePresentationGeometry {
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    [self updatePointerVisibility];
}

- (BOOL)frameHasSampledContent {
    if (!_frame.pixels) return NO;
    size_t samples = 128;
    for (size_t i = 0; i < samples; i++) {
        size_t x = (i * 7919u) % _frame.width;
        size_t y = (i * 104729u) % _frame.height;
        const uint8_t *pixel = _frame.pixels + y * _frame.stride + x * 4;
        if (pixel[0] || pixel[1] || pixel[2]) return YES;
    }
    return NO;
}

- (uint64_t)fallbackFrameSignature {
    uint64_t hash = 1469598103934665603ull;
    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    size_t step = payloadSize / 4096;
    if (step < 4) step = 4;
    for (size_t offset = 0; offset < payloadSize; offset += step) {
        hash ^= _frame.pixels[offset];
        hash *= 1099511628211ull;
    }
    hash ^= ((uint64_t)_frame.width << 32) | _frame.height;
    return hash;
}

- (void)pollSharedFrame:(CADisplayLink *)displayLink {
    (void)displayLink;
    uint64_t generation = 0;
    if (!MacWSReadCaptureAck(&generation)) {
        if (_presentedCaptureGeneration != 0 ||
            _pendingCaptureGeneration != 0) {
            _presentedCaptureGeneration = 0;
            _pendingCaptureGeneration = 0;
            _fallbackImageView.image = nil;
            (void)[_frame refresh];
            if (self.device) [self setNeedsDisplay];
            [self publishStatus:_frame.lastError ?: @"等待已确认的共享帧"];
        }
        return;
    }
    if (generation == _presentedCaptureGeneration) return;
    if (generation != _pendingCaptureGeneration)
        _pendingCaptureGeneration = generation;
    if (self.device) {
        [self setNeedsDisplay];
    } else {
        [self drawFallbackFrame];
    }
}

- (void)drawFallbackFrame {
    if (![_frame refresh]) {
        [self publishStatus:_frame.lastError ?: @"等待共享帧"];
        return;
    }
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    uint64_t signature = [self fallbackFrameSignature];
    if (_fallbackImageView.image && signature == _fallbackSignature) {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  像素未变化",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
        return;
    }

    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    NSData *snapshot = [NSData dataWithBytes:_frame.pixels length:payloadSize];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)snapshot);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little |
        kCGImageAlphaPremultipliedFirst;
    CGImageRef image = CGImageCreate(_frame.width, _frame.height, 8, 32,
        _frame.stride, colorSpace, bitmapInfo, provider, NULL, false,
        kCGRenderingIntentDefault);
    if (image) {
        _fallbackImageView.image = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
        _fallbackSignature = signature;
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        BOOL nonzero = [self frameHasSampledContent];
        if (nonzero && !_reportedFallbackFrame) {
            _reportedFallbackFrame = YES;
            MacWSLog(@"runtime-confirmed UIKit fallback frame nonzero %ux%u stride=%u",
                     _frame.width, _frame.height, _frame.stride);
        }
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  UIKit fallback",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
    } else {
        [self publishStatus:@"UIKit fallback 无法创建 BGRA 图像"];
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_pipeline || !_commandQueue) return;
    BOOL directSurface = _surfaceFrame != nil && _surfaceTexture != nil;
    if (directSurface) {
        _sourceTexture = _surfaceTexture;
    } else {
        if (self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled()) {
            [self publishStatus:self.targetWindowID != 0
                ? @"等待该窗口的 DisplayStream IOSurface 直传帧"
                : @"等待全屏 DisplayStream IOSurface 直传帧"];
            // MTKView retains its previous drawable if no command buffer is
            // submitted.  During a window -> fullscreen Scene transaction
            // iPadOS then scales that old window-sized drawable to the panel,
            // which looks like a cropped desktop and cannot share the new
            // input coordinate generation.  Clear through the real Metal
            // render pass while waiting; the first new IOSurface replaces it
            // through the normal draw path below.
            MTLRenderPassDescriptor *waitingPass =
                view.currentRenderPassDescriptor;
            id<CAMetalDrawable> waitingDrawable = view.currentDrawable;
            if (waitingPass && waitingDrawable) {
                waitingPass.colorAttachments[0].loadAction =
                    MTLLoadActionClear;
                waitingPass.colorAttachments[0].storeAction =
                    MTLStoreActionStore;
                waitingPass.colorAttachments[0].clearColor =
                    MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
                id<MTLCommandBuffer> waitingBuffer =
                    [_commandQueue commandBuffer];
                id<MTLRenderCommandEncoder> waitingEncoder =
                    [waitingBuffer renderCommandEncoderWithDescriptor:
                        waitingPass];
                [waitingEncoder endEncoding];
                [waitingBuffer presentDrawable:waitingDrawable];
                [waitingBuffer commit];
            }
            return;
        }
        if (![_frame refresh]) {
            [self publishStatus:_frame.lastError ?: @"等待共享帧"];
            return;
        }
        if (![self ensureSourceTexture]) {
            [self publishStatus:@"无法创建帧上传纹理"];
            return;
        }

        MTLRegion region = MTLRegionMake2D(0, 0, _frame.width, _frame.height);
        [_sourceTexture replaceRegion:region mipmapLevel:0 withBytes:_frame.pixels
                          bytesPerRow:_frame.stride];

        if (!_reportedNonzeroFrame && [self frameHasSampledContent]) {
            _reportedNonzeroFrame = YES;
            MacWSLog(@"runtime-confirmed source frame nonzero %ux%u stride=%u path=%@",
                     _frame.width, _frame.height, _frame.stride, MacWSFramePath);
        }
    }

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    simd_float4 vertices[4];
    [self updateContentRectAndVertices:vertices];
    if (directSurface) {
        MacWSStreamFrameDescriptor descriptor = _surfaceFrame.descriptor;
        float originU = descriptor.contentX / (float)descriptor.width;
        float originV = descriptor.contentY / (float)descriptor.height;
        float scaleU = descriptor.contentWidth / (float)descriptor.width;
        float scaleV = descriptor.contentHeight / (float)descriptor.height;
        for (NSUInteger index = 0; index < 4; index++) {
            vertices[index].z = originU + vertices[index].z * scaleU;
            vertices[index].w = originV + vertices[index].w * scaleV;
        }
    }
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:_sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];

    MacWSSurfaceFrame *performanceFrame = directSurface ? _surfaceFrame : nil;
    if (directSurface && _overlayFrames.count) {
        [self overlayKeysBackToFront];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        CGFloat viewWidth = CGRectGetWidth(self.bounds);
        CGFloat viewHeight = CGRectGetHeight(self.bounds);
        for (NSNumber *key in _sortedOverlayKeys) {
            MacWSSurfaceFrame *overlayFrame = _overlayFrames[key];
            id<MTLTexture> overlayTexture = _overlayTextures[key];
            MacWSStreamFrameDescriptor overlay = overlayFrame.descriptor;
            CGRect destination = CGRectMake(
                overlay.destinationX, overlay.destinationY,
                overlay.destinationWidth, overlay.destinationHeight);
            CGRect clipped = CGRectIntersection(destination, visiblePixels);
            if (!overlayTexture || CGRectIsNull(clipped) ||
                CGRectIsEmpty(clipped) || viewWidth <= 0 || viewHeight <= 0 ||
                visiblePixels.size.width <= 0 ||
                visiblePixels.size.height <= 0) continue;
            if (!performanceFrame ||
                overlayFrame.receiptTime > performanceFrame.receiptTime)
                performanceFrame = overlayFrame;

            CGFloat relativeLeft =
                (CGRectGetMinX(clipped) - CGRectGetMinX(visiblePixels)) /
                CGRectGetWidth(visiblePixels);
            CGFloat relativeRight =
                (CGRectGetMaxX(clipped) - CGRectGetMinX(visiblePixels)) /
                CGRectGetWidth(visiblePixels);
            CGFloat relativeTop =
                (CGRectGetMinY(clipped) - CGRectGetMinY(visiblePixels)) /
                CGRectGetHeight(visiblePixels);
            CGFloat relativeBottom =
                (CGRectGetMaxY(clipped) - CGRectGetMinY(visiblePixels)) /
                CGRectGetHeight(visiblePixels);
            CGFloat viewLeft = CGRectGetMinX(_contentRect) +
                relativeLeft * CGRectGetWidth(_contentRect);
            CGFloat viewRight = CGRectGetMinX(_contentRect) +
                relativeRight * CGRectGetWidth(_contentRect);
            CGFloat viewTop = CGRectGetMinY(_contentRect) +
                relativeTop * CGRectGetHeight(_contentRect);
            CGFloat viewBottom = CGRectGetMinY(_contentRect) +
                relativeBottom * CGRectGetHeight(_contentRect);

            float sourceLeft = (overlay.contentX +
                (CGRectGetMinX(clipped) - CGRectGetMinX(destination)) /
                    CGRectGetWidth(destination) * overlay.contentWidth) /
                (float)overlay.width;
            float sourceRight = (overlay.contentX +
                (CGRectGetMaxX(clipped) - CGRectGetMinX(destination)) /
                    CGRectGetWidth(destination) * overlay.contentWidth) /
                (float)overlay.width;
            float sourceTop = (overlay.contentY +
                (CGRectGetMinY(clipped) - CGRectGetMinY(destination)) /
                    CGRectGetHeight(destination) * overlay.contentHeight) /
                (float)overlay.height;
            float sourceBottom = (overlay.contentY +
                (CGRectGetMaxY(clipped) - CGRectGetMinY(destination)) /
                    CGRectGetHeight(destination) * overlay.contentHeight) /
                (float)overlay.height;
            simd_float4 overlayVertices[4] = {
                {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                 (float)(1.0 - viewBottom / viewHeight * 2.0),
                 sourceLeft, sourceBottom},
                {(float)(viewRight / viewWidth * 2.0 - 1.0),
                 (float)(1.0 - viewBottom / viewHeight * 2.0),
                 sourceRight, sourceBottom},
                {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                 (float)(1.0 - viewTop / viewHeight * 2.0),
                 sourceLeft, sourceTop},
                {(float)(viewRight / viewWidth * 2.0 - 1.0),
                 (float)(1.0 - viewTop / viewHeight * 2.0),
                 sourceRight, sourceTop},
            };
            [encoder setVertexBytes:overlayVertices
                              length:sizeof(overlayVertices) atIndex:0];
            [encoder setFragmentTexture:overlayTexture atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0 vertexCount:4];
        }
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    uint64_t submitTime = mach_absolute_time();
    uint32_t presentedWidth = [self currentFrameWidth];
    uint32_t presentedHeight = [self currentFrameHeight];
    MacWSSurfaceFrame *submittedFrame = directSurface ? _surfaceFrame : nil;
    NSArray<MacWSSurfaceFrame *> *framesToRelease =
        _retiredSurfaceFrames.count ? [_retiredSurfaceFrames copy] : @[];
    [_retiredSurfaceFrames removeAllObjects];
    if (submittedFrame) _submittedSurfaceSequence = submittedFrame.descriptor.sequence;
    if (performanceFrame &&
        (performanceFrame.descriptor.sequence % 120) == 0 &&
        (_lastPerformanceLogStreamID != performanceFrame.descriptor.streamID ||
         _lastPerformanceLogSequence != performanceFrame.descriptor.sequence)) {
        uint64_t captureTime = performanceFrame.descriptor.displayTime;
        uint64_t receiptTime = performanceFrame.receiptTime;
        uint64_t sequence = performanceFrame.descriptor.sequence;
        uint64_t streamID = performanceFrame.descriptor.streamID;
        _lastPerformanceLogStreamID = streamID;
        _lastPerformanceLogSequence = sequence;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            uint64_t completeTime = mach_absolute_time();
            MacWSLog(@"display-perf stream=%llu sequence=%llu "
                     "capture-to-receipt-ms=%.3f receipt-to-submit-ms=%.3f "
                     "submit-to-complete-ms=%.3f status=%ld error=%@",
                     (unsigned long long)streamID,
                     (unsigned long long)sequence,
                     MacWSMachMilliseconds(captureTime, receiptTime),
                     MacWSMachMilliseconds(receiptTime, submitTime),
                     MacWSMachMilliseconds(submitTime, completeTime),
                     (long)completed.status, completed.error ?: @"nil");
        }];
    }
    if ((directSurface || _reportedNonzeroFrame) && !_submittedPresentWitness) {
        _submittedPresentWitness = YES;
        uint32_t witnessWidth = presentedWidth;
        uint32_t witnessHeight = presentedHeight;
        uint64_t witnessScene = self.sceneID;
        float witnessBackingScale = directSurface
            ? submittedFrame.descriptor.backingScale : 1.0f;
        CGSize witnessDrawableSize = self.drawableSize;
        CGRect witnessContentRect = _contentRect;
        CGFloat witnessDensity = self.effectiveDensityScale;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSError *error = completed.error;
            MacWSLog(@"runtime-confirmed native Metal present scene=%llx "
                     "frame=%ux%u backing=%.3f drawable=%.0fx%.0f "
                     "content=(%.2f,%.2f %.2fx%.2f) density=%.2f "
                     "source=%@ status=%ld error=%@",
                     witnessScene, witnessWidth, witnessHeight,
                     witnessBackingScale, witnessDrawableSize.width,
                     witnessDrawableSize.height, witnessContentRect.origin.x,
                     witnessContentRect.origin.y, witnessContentRect.size.width,
                     witnessContentRect.size.height, witnessDensity,
                     directSurface ? @"IOSurface" : @"mmap-upload",
                     (long)completed.status, error ?: @"nil");
        }];
    }
    if (framesToRelease.count) {
        __weak MacWSStreamClient *weakClient = _streamClient;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            for (MacWSSurfaceFrame *frame in framesToRelease)
                [weakClient releaseFrame:frame];
        }];
    }
    [commandBuffer commit];
    if (directSurface) {
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  DisplayStream  ·  IOSurface 直传",
            presentedWidth, presentedHeight]];
    } else {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        NSString *content = _reportedNonzeroFrame ? @"有效像素" : @"全黑";
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  %@",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration, content]];
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    [self updatePresentationGeometry];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint output:(CGPoint *)framePoint {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0 ||
        CGRectIsEmpty(_contentRect) || !CGRectContainsPoint(_contentRect, viewPoint)) {
        return NO;
    }
    CGFloat nx = (viewPoint.x - CGRectGetMinX(_contentRect)) /
        _contentRect.size.width;
    CGFloat ny = (viewPoint.y - CGRectGetMinY(_contentRect)) /
        _contentRect.size.height;
    CGFloat sourceX = CGRectGetMinX(_visibleSourceRect) +
        fmin(fmax(nx, 0.0), 1.0) * CGRectGetWidth(_visibleSourceRect);
    CGFloat sourceY = CGRectGetMinY(_visibleSourceRect) +
        fmin(fmax(ny, 0.0), 1.0) * CGRectGetHeight(_visibleSourceRect);
    framePoint->x = sourceX * (frameWidth - 1);
    framePoint->y = sourceY * (frameHeight - 1);
    return YES;
}

- (BOOL)viewPointForFramePoint:(CGPoint)framePoint output:(CGPoint *)viewPoint {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    CGFloat visibleWidth = CGRectGetWidth(_visibleSourceRect);
    CGFloat visibleHeight = CGRectGetHeight(_visibleSourceRect);
    if (frameWidth == 0 || frameHeight == 0 || CGRectIsEmpty(_contentRect) ||
        visibleWidth <= 0 || visibleHeight <= 0) return NO;
    CGFloat sourceX = framePoint.x / MAX(frameWidth - 1, 1u);
    CGFloat sourceY = framePoint.y / MAX(frameHeight - 1, 1u);
    CGFloat nx = (sourceX - CGRectGetMinX(_visibleSourceRect)) / visibleWidth;
    CGFloat ny = (sourceY - CGRectGetMinY(_visibleSourceRect)) / visibleHeight;
    nx = fmin(fmax(nx, 0.0), 1.0);
    ny = fmin(fmax(ny, 0.0), 1.0);
    if (viewPoint) {
        *viewPoint = CGPointMake(CGRectGetMinX(_contentRect) +
            nx * CGRectGetWidth(_contentRect),
            CGRectGetMinY(_contentRect) + ny * CGRectGetHeight(_contentRect));
    }
    return YES;
}

- (NSArray<NSNumber *> *)overlayKeysBackToFront {
    if (!_sortedOverlayKeys) {
        _sortedOverlayKeys = [_overlayFrames.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(
                NSNumber *lhs, NSNumber *rhs) {
                MacWSStreamFrameDescriptor left =
                    self->_overlayFrames[lhs].descriptor;
                MacWSStreamFrameDescriptor right =
                    self->_overlayFrames[rhs].descriptor;
                if (left.layerLevel < right.layerLevel)
                    return NSOrderedAscending;
                if (left.layerLevel > right.layerLevel)
                    return NSOrderedDescending;
                return [lhs compare:rhs];
            }];
    }
    return _sortedOverlayKeys;
}

- (void)logPerformanceSnapshotWithReason:(NSString *)reason {
    NSMutableArray<NSString *> *layers = [NSMutableArray array];
    for (NSNumber *key in [self overlayKeysBackToFront]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        [layers addObject:[NSString stringWithFormat:
            @"layer=%u/pid=%d/stream=%llu/sequence=%llu/surface=%u/age-ms=%.2f",
            descriptor.layerWindowID, descriptor.layerOwnerPID,
            (unsigned long long)descriptor.streamID,
            (unsigned long long)descriptor.sequence,
            IOSurfaceGetID(frame.surface),
            MacWSMachMilliseconds(frame.receiptTime, mach_absolute_time())]];
    }
    MacWSStreamFrameDescriptor base = _surfaceFrame.descriptor;
    MacWSLog(@"display-performance-snapshot reason=%@ "
             "base-stream=%llu base-sequence=%llu base-surface=%u "
             "texture-imports=%llu layers=[%@]",
             reason.length ? reason : @"manual",
             (unsigned long long)base.streamID,
             (unsigned long long)base.sequence,
             _surfaceFrame ? IOSurfaceGetID(_surfaceFrame.surface) : 0,
             (unsigned long long)_surfaceTextureImports,
             [layers componentsJoinedByString:@", "]);
}

- (BOOL)resolveFullscreenLayerAtPoint:(CGPoint)point
                                  pid:(int32_t *)pidOut
                             windowID:(uint32_t *)windowIDOut
                           descriptor:(MacWSStreamFrameDescriptor *)descriptorOut {
    // Traverse the exact graph used by drawInMTKView: in reverse paint order.
    // This is main-thread, in-process O(visible layers): no WindowServer IPC
    // and no bounded 150-ms all-process target-probe round trip.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID <= 1 ||
            descriptor.layerWindowID == 0 ||
            (descriptor.flags & MacWSStreamFrameInputPassthrough) != 0 ||
            descriptor.destinationWidth == 0 ||
            descriptor.destinationHeight == 0) continue;
        CGRect destination = CGRectMake(
            descriptor.destinationX, descriptor.destinationY,
            descriptor.destinationWidth, descriptor.destinationHeight);
        if (!CGRectContainsPoint(destination, point)) continue;
        // Full-display Dock/menu surfaces are intentionally transparent away
        // from their controls. Rectangle-only hit testing therefore selects
        // Dock above every application even though Metal visibly composites
        // the application through that pixel. Read the same BGRA alpha byte
        // used by the fragment blend and skip only a proven transparent pixel.
        // The leased DisplayStream IOSurface is already CPU-mapped; this is a
        // single-byte read at gesture start, not an IOSurface lock or scan.
        const uint8_t *base = IOSurfaceGetBaseAddress(frame.surface);
        size_t stride = IOSurfaceGetBytesPerRow(frame.surface);
        size_t surfaceWidth = IOSurfaceGetWidth(frame.surface);
        size_t surfaceHeight = IOSurfaceGetHeight(frame.surface);
        if (base && stride >= surfaceWidth * 4 && surfaceWidth > 0 &&
            surfaceHeight > 0 && descriptor.contentWidth > 0 &&
            descriptor.contentHeight > 0) {
            double u = (point.x - CGRectGetMinX(destination)) /
                CGRectGetWidth(destination);
            double v = (point.y - CGRectGetMinY(destination)) /
                CGRectGetHeight(destination);
            size_t sourceX = MIN((size_t)descriptor.contentX +
                (size_t)floor(fmax(0.0, fmin(u, 0.999999)) *
                              descriptor.contentWidth), surfaceWidth - 1);
            size_t sourceY = MIN((size_t)descriptor.contentY +
                (size_t)floor(fmax(0.0, fmin(v, 0.999999)) *
                              descriptor.contentHeight), surfaceHeight - 1);
            if (base[sourceY * stride + sourceX * 4 + 3] == 0) continue;
        }
        if (pidOut) *pidOut = descriptor.layerOwnerPID;
        if (windowIDOut) *windowIDOut = descriptor.layerWindowID;
        if (descriptorOut) *descriptorOut = descriptor;
        return YES;
    }
    return NO;
}

- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record {
    if (!record || _streamClient.mode != MacWSStreamModeFullscreen)
        return NO;
    BOOL terminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & (MacWSInputFlagScrollEnded |
                           MacWSInputFlagScrollCancelled))) ||
        (record->kind == MacWSInputKindMagnify &&
         (record->flags & (MacWSInputFlagGestureEnded |
                           MacWSInputFlagGestureCancelled)));
    BOOL begins = record->kind == MacWSInputKindTouchDown ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & MacWSInputFlagScrollBegan)) ||
        (record->kind == MacWSInputKindMagnify &&
         (record->flags & MacWSInputFlagGestureBegan));
    BOOL continuation = record->kind == MacWSInputKindTouchMove || terminal ||
        (record->kind == MacWSInputKindScroll && !begins) ||
        (record->kind == MacWSInputKindMagnify && !begins);
    BOOL diagnostic = record->contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC;
    if (diagnostic) {
        MacWSLog(@"fullscreen-route-entry view=%p kind=%u begin=%@ continuation=%@ terminal=%@ active=%@ contact=%u owner-contact=%u frozen-destination=(%d,%d %ux%u)",
                 self, record->kind, begins ? @"YES" : @"NO",
                 continuation ? @"YES" : @"NO", terminal ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 record->contactID, _fullscreenGestureRouteContactID,
                 _fullscreenGestureRouteDescriptor.destinationX,
                 _fullscreenGestureRouteDescriptor.destinationY,
                 _fullscreenGestureRouteDescriptor.destinationWidth,
                 _fullscreenGestureRouteDescriptor.destinationHeight);
    }

    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    MacWSStreamFrameDescriptor descriptor = {0};
    BOOL resolved = NO;
    BOOL atomicPrimaryTap = record->kind == MacWSInputKindTap;
    BOOL reuseDoubleTapRoute = atomicPrimaryTap &&
        (record->flags & MacWSInputFlagDoubleClick) != 0 &&
        _fullscreenLastTapRouteTimestamp > 0.0 &&
        record->timestamp >= _fullscreenLastTapRouteTimestamp &&
        record->timestamp - _fullscreenLastTapRouteTimestamp <=
            MACWS_DIRECT_DOUBLE_TAP_SECONDS + 0.05 &&
        _fullscreenLastTapRoutePID > 1 &&
        _fullscreenLastTapRouteWindowID != 0 &&
        _overlayFrames[@(_fullscreenLastTapRouteWindowID)] != nil;
    if (reuseDoubleTapRoute) {
        ownerPID = _fullscreenLastTapRoutePID;
        windowID = _fullscreenLastTapRouteWindowID;
        descriptor = _fullscreenLastTapRouteDescriptor;
        resolved = YES;
    } else if (continuation && _fullscreenGestureRouteActive) {
        ownerPID = _fullscreenGestureRoutePID;
        windowID = _fullscreenGestureRouteWindowID;
        resolved = ownerPID > 1 && windowID != 0;
        // A gesture is one affine transaction. WindowServer changes the live
        // layer destination after every native title-bar drag sample. Mapping
        // the next fixed desktop point through that moving destination
        // subtracts the displacement just applied and makes the window bounce
        // left/right. The Begin descriptor is already retained specifically as
        // the coordinate snapshot, so keep it authoritative through End.
        descriptor = _fullscreenGestureRouteDescriptor;
    } else {
        resolved = [self resolveFullscreenLayerAtPoint:
            CGPointMake(record->x, record->y) pid:&ownerPID
                     windowID:&windowID descriptor:&descriptor];
    }
    if (resolved) {
        float desktopX = record->x;
        float desktopY = record->y;
        uint32_t modifiers = MacWSInputModifiersForScene(record->sceneID);
        BOOL globalSystemSurface =
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0;
        BOOL ownerHasEndpoint = MacWSAppInputEndpointReady(ownerPID);
        if (!globalSystemSurface && ownerHasEndpoint) {
            float layerX = 0.0f, layerY = 0.0f;
            resolved = MacWSStreamMapDesktopPointToLayer(
                &descriptor, desktopX, desktopY, &layerX, &layerY);
            if (!resolved) return NO;
            record->x = layerX;
            record->y = layerY;
            record->frameWidth = descriptor.width;
            record->frameHeight = descriptor.height;
            record->targetPID = ownerPID;
        } else {
            // Dock and similar global owners use a real process-local CGS
            // endpoint, but they are not AppKit windows and their capture is
            // the complete desktop coordinate space. Preserve those desktop
            // coordinates and identify the route explicitly from displayd's
            // catalog metadata; endpoint existence alone cannot distinguish
            // Dock from an ordinary exact-window application.
            record->targetPID = ownerPID;
            record->flags |= MacWSInputFlagGlobalSystemSurface;
        }
        record->sceneID = MacWSInputSceneForWindow(windowID, modifiers);
        if (record->contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) {
            MacWSLog(@"fullscreen-layer-input runtime-confirmed pid=%d target=%d route=%@ window=%u flags=%#x desktop=(%.1f,%.1f) local=(%.1f,%.1f)/%ux%u destination=(%d,%d %ux%u)",
                     ownerPID, record->targetPID,
                     globalSystemSurface ? @"global-system" : @"app",
                     windowID, descriptor.flags, desktopX, desktopY,
                     record->x, record->y, record->frameWidth,
                     record->frameHeight, descriptor.destinationX,
                     descriptor.destinationY, descriptor.destinationWidth,
                     descriptor.destinationHeight);
        }
    }
    // The first click can activate/reorder a native window and the event-
    // driven catalog refresh may land before the second physical click. Keep
    // a short-lived identity snapshot so a UIKit-authoritative double tap is
    // one AppKit transaction, matching VNC's proven same-connection pair.
    // Do not retain vanished popup/menu layers: a dismissal must expose the
    // newly hit-tested surface beneath it for the next independent tap.
    if (atomicPrimaryTap) {
        if (resolved) {
            _fullscreenLastTapRouteTimestamp = record->timestamp;
            _fullscreenLastTapRoutePID = ownerPID;
            _fullscreenLastTapRouteWindowID = windowID;
            _fullscreenLastTapRouteDescriptor = descriptor;
        } else if ((record->flags & MacWSInputFlagDoubleClick) == 0) {
            _fullscreenLastTapRouteTimestamp = 0.0;
            _fullscreenLastTapRoutePID = 0;
            _fullscreenLastTapRouteWindowID = 0;
            _fullscreenLastTapRouteDescriptor =
                (MacWSStreamFrameDescriptor){0};
        }
    }
    if (begins) {
        _fullscreenGestureRouteActive = resolved;
        _fullscreenGestureRouteContactID = resolved ? record->contactID : 0;
        _fullscreenGestureRoutePID = resolved ? ownerPID : 0;
        _fullscreenGestureRouteWindowID = resolved ? windowID : 0;
        _fullscreenGestureRouteDescriptor = resolved
            ? descriptor : (MacWSStreamFrameDescriptor){0};
    }
    // UIKit can deliver an unrelated pointer/finger cancellation while a
    // fullscreen title-bar tracker is active (URL/Scene activation is one
    // reproducible source). A Touch route belongs to its Begin contact; only
    // that contact may release it. Scroll carries horizontal delta bits in
    // contactID, so its native phase boundary remains the owner there.
    BOOL touchTerminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel;
    BOOL terminalOwnsRoute = !touchTerminal ||
        !_fullscreenGestureRouteActive ||
        record->contactID == _fullscreenGestureRouteContactID;
    if (terminal && terminalOwnsRoute) {
        _fullscreenGestureRouteActive = NO;
        _fullscreenGestureRouteContactID = 0;
        _fullscreenGestureRoutePID = 0;
        _fullscreenGestureRouteWindowID = 0;
        _fullscreenGestureRouteDescriptor =
            (MacWSStreamFrameDescriptor){0};
    }
    if (diagnostic) {
        MacWSLog(@"fullscreen-route-exit view=%p kind=%u resolved=%@ active=%@ owner-contact=%u destination=(%d,%d %ux%u)",
                 self, record->kind, resolved ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 _fullscreenGestureRouteContactID, descriptor.destinationX,
                 descriptor.destinationY, descriptor.destinationWidth,
                 descriptor.destinationHeight);
    }
    return resolved;
}

- (void)updatePointerVisibility {
    BOOL available = self.isMacWSInputEnabled &&
        [self currentFrameWidth] > 0 && [self currentFrameHeight] > 0;
    if (self.inputMode != MacWSHostInputModeDirect || !available ||
        !_directTouch) {
        _directTouchIndicator.hidden = YES;
    }
    BOOL showTrackpad = self.inputMode == MacWSHostInputModeTrackpad &&
        available && _trackpadCursorWasTouched && !_externalPointerHoverActive;
    if (showTrackpad) {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        CGPoint pointerCenter = CGPointZero;
        showTrackpad = [self viewPointForFramePoint:_trackpadCursor
                                             output:&pointerCenter];
        if (showTrackpad) {
            // Keep the arrow's 2,1.5 path vertex as the macOS hot spot.
            _trackpadCursorView.frame = CGRectMake(pointerCenter.x - 2.0,
                pointerCenter.y - 1.5, 22.0, 28.0);
        }
    }
    _trackpadCursorView.hidden = !showTrackpad;
    if (showTrackpad) [self bringSubviewToFront:_trackpadCursorView];
    BOOL showPencil = available && (_pencilHoverActive || _pencilTouch != nil);
    _pencilCursorView.hidden = !showPencil;
    if (showPencil) [self bringSubviewToFront:_pencilCursorView];
}

- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated {
    void (^changes)(void) = ^{
        self->_trackpadCursorView.transform = pressed
            ? CGAffineTransformMakeScale(0.78, 0.78)
            : CGAffineTransformIdentity;
        self->_trackpadCursorView.alpha = pressed ? 0.78 : 1.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0
            options:UIViewAnimationOptionBeginFromCurrentState |
                    UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)emitKind:(MacWSInputKind)kind
      framePoint:(CGPoint)framePoint
        pressure:(float)pressure
       contactID:(uint32_t)contactID
       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = contactID,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitKind:(MacWSInputKind)kind
           touch:(UITouch *)touch
           point:(CGPoint)viewPoint
      extraFlags:(uint16_t)extraFlags {
    if (touch.type == UITouchTypePencil)
        viewPoint = [touch preciseLocationInView:self];
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    float pressure = touch.maximumPossibleForce > 0
        ? touch.force / touch.maximumPossibleForce : 0.0f;
    MacWSInputSource source = MacWSInputSourceFinger;
    if (touch.type == UITouchTypePencil)
        source = MacWSInputSourcePencil;
    else if (touch.type == UITouchTypeIndirectPointer)
        source = MacWSInputSourceIndirectPointer;
    float altitude = 0.0f;
    float azimuth = 0.0f;
    float tiltX = 0.0f;
    float tiltY = 0.0f;
    uint16_t inputFlags = 0;
    if (source == MacWSInputSourcePencil) {
        altitude = (float)touch.altitudeAngle;
        azimuth = (float)[touch azimuthAngleInView:self];
        float tiltMagnitude = fmaxf(0.0f, fminf(1.0f, cosf(altitude)));
        tiltX = tiltMagnitude * cosf(azimuth);
        tiltY = tiltMagnitude * sinf(azimuth);
        inputFlags |= MacWSInputFlagPreciseLocation;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = touch.timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = (uint32_t)touch.hash,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .flags = inputFlags | extraFlags,
        .altitude = altitude,
        .azimuth = azimuth,
        .tiltX = tiltX,
        .tiltY = tiltY,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (source == MacWSInputSourceFinger &&
        self.inputMode == MacWSHostInputModeDirect) {
        _directTouchIndicator.center = viewPoint;
        _directTouchIndicator.hidden = kind == MacWSInputKindTouchUp ||
                                       kind == MacWSInputKindTouchCancel;
        if (!_directTouchIndicator.hidden)
            [self bringSubviewToFront:_directTouchIndicator];
    }
}

- (void)emitKind:(MacWSInputKind)kind touch:(UITouch *)touch point:(CGPoint)viewPoint {
    [self emitKind:kind touch:touch point:viewPoint extraFlags:0];
}

- (void)emitTouches:(NSSet<UITouch *> *)touches kind:(MacWSInputKind)kind {
    for (UITouch *touch in touches)
        [self emitKind:kind touch:touch point:[touch locationInView:self]];
}

- (void)emitPencilHoverForTouch:(UITouch *)touch point:(CGPoint)viewPoint {
    if (!touch) return;
    viewPoint = [touch preciseLocationInView:self];
    [self emitKind:MacWSInputKindHover touch:touch point:viewPoint];
    _pencilCursorView.center = viewPoint;
    _pencilCursorView.hidden = NO;
    [self bringSubviewToFront:_pencilCursorView];
}

- (void)cancelDirectTouchForMultitouch {
    _directTouchSerial++;
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    _directTouchIndicator.hidden = YES;
}

- (void)beginDirectTouchCandidate:(UITouch *)touch {
    _directTouch = touch;
    _directTouchState = MacWSDirectTouchStateCandidate;
    _directTouchStartPoint = [touch locationInView:self];
    _directTouchPreviousPoint = _directTouchStartPoint;
    _directScrollVelocity = CGPointZero;
    _directScrollFramePoint = CGPointZero;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    _directTouchStartTimestamp = touch.timestamp;
    _directTouchPreviousTimestamp = touch.timestamp;
    // A real finger now owns the interaction transaction. Any delayed
    // ConfigureWindow settlement from Scene creation would otherwise re-anchor
    // the AppKit window underneath a native title-bar drag. A subsequent UIKit
    // geometry change cancels this touch in geometryDidChange and starts its own
    // fresh configuration transaction.
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    uint64_t serial = ++_directTouchSerial;
    [_directTouchFeedback prepare];
    _directTouchIndicator.center = _directTouchStartPoint;
    _directTouchIndicator.transform = CGAffineTransformIdentity;
    _directTouchIndicator.hidden = NO;
    [self bringSubviewToFront:_directTouchIndicator];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(MACWS_DIRECT_LONG_PRESS_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (serial != self->_directTouchSerial ||
            self->_directTouch != touch ||
            self->_directTouchState != MacWSDirectTouchStateCandidate)
            return;
        CGPoint point = [touch locationInView:self];
        double travel = hypot(point.x - self->_directTouchStartPoint.x,
                              point.y - self->_directTouchStartPoint.y);
        if (MacWSDecideTouchCandidate(MACWS_DIRECT_LONG_PRESS_SECONDS,
                                      travel, false) !=
            MacWSTouchCandidateDecisionLongPress)
            return;
        // Holding only arms a primary-button drag.  Sending right-click here
        // made it structurally impossible to drag after the long press.  If
        // the armed finger is released without moving, release handling keeps
        // the useful long-press-as-context-menu behavior.
        self->_directTouchState = MacWSDirectTouchStateLongPressArmed;
        [UIView animateWithDuration:0.12 animations:^{
            self->_directTouchIndicator.transform =
                CGAffineTransformMakeScale(0.78, 0.78);
        }];
        [self->_directTouchFeedback impactOccurred];
        [self publishStatus:@"已进入拖动状态 · 滑动即可拖动"];
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The hidden UITextField owns the software keyboard. Taking first
    // responder here used to dismiss it on the very first touch inside the
    // macOS surface. Hardware-key focus remains on the Metal view whenever
    // the software keyboard is not intentionally active.
    if (!self.softwareKeyboardActive) [self becomeFirstResponder];
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (touch.type == UITouchTypePencil) {
        _pencilTouch = touch;
        _pencilHoverActive = NO;
        _pencilTouchStartPoint = [touch preciseLocationInView:self];
        _pencilTouchTravel = 0;
        _pencilTouchBeganAt = touch.timestamp;
        [self emitPencilHoverForTouch:touch point:_pencilTouchStartPoint];
    } else if (pointerTouch) {
        if (@available(iOS 13.4, *)) {
            // buttonMask is the complete current button state.  A primary
            // transition can briefly coexist with a stale secondary bit after
            // scene/focus handoff; never reinterpret that primary transition
            // as a right click.  A genuine secondary click has Secondary set
            // without Primary.
            BOOL primaryButton =
                (event.buttonMask & UIEventButtonMaskPrimary) != 0;
            BOOL secondaryButton =
                (event.buttonMask & UIEventButtonMaskSecondary) != 0;
            if (secondaryButton && !primaryButton) {
                _secondaryPointerTouch = touch;
                [self emitKind:MacWSInputKindSecondaryTap touch:touch
                         point:[touch locationInView:self]];
            } else {
                [self emitTouches:touches kind:MacWSInputKindTouchDown];
            }
        } else {
            [self emitTouches:touches kind:MacWSInputKindTouchDown];
        }
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (event.allTouches.count > 1) {
            [self cancelDirectTouchForMultitouch];
            _directGestureBlocked = YES;
        } else if (!_directGestureBlocked && !_directTouch && touch) {
            [self beginDirectTouchCandidate:touch];
        }
    } else if (!_trackpadTouch && touch) {
        _trackpadTouch = touch;
        _trackpadCursorWasTouched = YES;
        _externalPointerHoverActive = NO;
        _trackpadPreviousPoint = [touch locationInView:self];
        _trackpadTravel = 0;
        _trackpadBeganAt = touch.timestamp;
        _trackpadHadMultipleTouches = event.allTouches.count > 1;
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        [self updatePointerVisibility];
        uint32_t contactID = (uint32_t)touch.hash;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self->_trackpadTouch == touch &&
                self->_trackpadTravel < 6.0 &&
                !self->_trackpadHadMultipleTouches &&
                !self->_trackpadButtonDown) {
                self->_trackpadButtonDown = YES;
                [self setTrackpadPointerPressed:YES animated:YES];
                [self emitKind:MacWSInputKindTouchDown
                     framePoint:self->_trackpadCursor pressure:1.0f
                      contactID:contactID timestamp:CACurrentMediaTime()];
            }
        });
    } else if (event.allTouches.count > 1) {
        _trackpadHadMultipleTouches = YES;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        [self emitPencilHoverForTouch:_pencilTouch point:point];
    } else if (pointerTouch) {
        if (touch != _secondaryPointerTouch)
            [self emitTouches:touches kind:MacWSInputKindTouchMove];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            CGFloat travel = hypot(point.x - _directTouchStartPoint.x,
                                   point.y - _directTouchStartPoint.y);
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // dispatch_after can run before an already-recorded UIKit move
            // when the main queue was stalled.  Its LongPressArmed state is
            // provisional; the touch hardware timestamp is authoritative.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                _directTouchIndicator.transform = CGAffineTransformIdentity;
            }
            MacWSTouchCandidateDecision decision =
                MacWSDecideTouchCandidate(
                    elapsed, travel, false);
            if (_directTouchState == MacWSDirectTouchStateCandidate &&
                decision == MacWSTouchCandidateDecisionScroll) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateScrolling;
                _directScrollAxis = MacWSChooseDirectScrollAxis(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                [self stopScrollMomentumWithTerminalPhase:YES];
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    _directScrollFramePoint = framePoint;
                    [self emitScrollAtFramePoint:framePoint
                                     translation:CGPointZero
                                           flags:MacWSInputFlagScrollBegan
                                       timestamp:_directTouch.timestamp];
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    [self emitScrollAtFramePoint:framePoint translation:delta
                                           flags:MacWSInputFlagScrollChanged
                                       timestamp:_directTouch.timestamp];
                    NSTimeInterval dt = MAX(_directTouch.timestamp -
                        _directTouchPreviousTimestamp, 1.0 / 240.0);
                    _directScrollVelocity = CGPointMake(delta.x / dt,
                                                        delta.y / dt);
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState ==
                           MacWSDirectTouchStateCandidate &&
                       decision == MacWSTouchCandidateDecisionLongPress) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateLongPressArmed;
                _directTouchIndicator.transform =
                    CGAffineTransformMakeScale(0.78, 0.78);
                [_directTouchFeedback impactOccurred];
            } else if (_directTouchState ==
                           MacWSDirectTouchStateLongPressArmed &&
                       travel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                _directTouchState = MacWSDirectTouchStateDragging;
                CGPoint startFrame = CGPointZero;
                if ([self framePointForViewPoint:_directTouchStartPoint
                                          output:&startFrame]) {
                    [self emitKind:MacWSInputKindTouchDown
                        framePoint:startFrame pressure:1.0f
                         contactID:(uint32_t)_directTouch.hash
                          timestamp:_directTouchStartTimestamp];
                }
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
            } else if (_directTouchState == MacWSDirectTouchStateScrolling) {
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.72 + instant.x * 0.28;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.72 + instant.y * 0.28;
                    }
                    _directScrollFramePoint = framePoint;
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
            }
            _directTouchIndicator.center = point;
        }
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (event.allTouches.count > 1) _trackpadHadMultipleTouches = YES;
        CGPoint point = [_trackpadTouch locationInView:self];
        CGFloat dx = point.x - _trackpadPreviousPoint.x;
        CGFloat dy = point.y - _trackpadPreviousPoint.y;
        _trackpadPreviousPoint = point;
        _trackpadTravel += hypot(dx, dy);
        // The two-finger pan recognizer intentionally does not cancel raw
        // touches. Once a gesture becomes multi-touch, keep its translation
        // exclusively on the scroll route so scrolling cannot also move or
        // drag the macOS pointer.
        if (!_trackpadHadMultipleTouches) {
            CGFloat scaleX = CGRectGetWidth(_contentRect) > 0
                ? [self currentFrameWidth] / CGRectGetWidth(_contentRect) : 1.0;
            CGFloat scaleY = CGRectGetHeight(_contentRect) > 0
                ? [self currentFrameHeight] / CGRectGetHeight(_contentRect) : 1.0;
            _trackpadCursor.x = fmin(fmax(_trackpadCursor.x + dx * scaleX * 1.25,
                                          0.0), [self currentFrameWidth] - 1.0);
            _trackpadCursor.y = fmin(fmax(_trackpadCursor.y + dy * scaleY * 1.25,
                                          0.0), [self currentFrameHeight] - 1.0);
            [self emitKind:_trackpadButtonDown ? MacWSInputKindTouchMove
                                                : MacWSInputKindHover
                 framePoint:_trackpadCursor pressure:_trackpadButtonDown ? 1.0f : 0.0f
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:_trackpadTouch.timestamp];
            CGFloat sourceX = _trackpadCursor.x /
                MAX([self currentFrameWidth] - 1, 1u);
            CGFloat sourceY = _trackpadCursor.y /
                MAX([self currentFrameHeight] - 1, 1u);
            CGPoint previousViewportCenter = _viewportCenter;
            if (sourceX < CGRectGetMinX(_visibleSourceRect))
                _viewportCenter.x -= CGRectGetMinX(_visibleSourceRect) - sourceX;
            else if (sourceX > CGRectGetMaxX(_visibleSourceRect))
                _viewportCenter.x += sourceX - CGRectGetMaxX(_visibleSourceRect);
            if (sourceY < CGRectGetMinY(_visibleSourceRect))
                _viewportCenter.y -= CGRectGetMinY(_visibleSourceRect) - sourceY;
            else if (sourceY > CGRectGetMaxY(_visibleSourceRect))
                _viewportCenter.y += sourceY - CGRectGetMaxY(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self updatePointerVisibility];
            // The pointer is a native UIKit subview. At 1x, moving it must not
            // re-present an unchanged multi-megabyte macOS IOSurface; redraw
            // Metal only if a zoomed viewport was actually panned.
            if (fabs(previousViewportCenter.x - _viewportCenter.x) > 0.00001 ||
                fabs(previousViewportCenter.y - _viewportCenter.y) > 0.00001)
                [self setNeedsDisplay];
        }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        // On pre-hover iPads contact movement is a precise, non-clicking
        // preview. A short stationary contact retains normal Pencil tap.
        if (_pencilTouchTravel < MACWS_DIRECT_GESTURE_THRESHOLD_POINTS &&
            touch.timestamp - _pencilTouchBeganAt < 0.45) {
            [self emitKind:MacWSInputKindTap touch:_pencilTouch point:point];
        }
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else
            [self emitTouches:touches kind:MacWSInputKindTouchUp];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // The long-press timer is deliberately not authoritative.  If a
            // short tap's touch-up was queued behind that timer during a main
            // thread stall, restore Candidate so the normal tap/scroll policy
            // below classifies it from the real hardware duration.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                _directTouchIndicator.transform = CGAffineTransformIdentity;
            }
            if (_directTouchState == MacWSDirectTouchStateCandidate) {
                MacWSTouchCandidateDecision decision = MacWSDecideTouchCandidate(
                    elapsed,
                    hypot(point.x - _directTouchStartPoint.x,
                          point.y - _directTouchStartPoint.y), true);
                if (decision == MacWSTouchCandidateDecisionLongPress) {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                    [_directTouchFeedback impactOccurred];
                } else if (decision == MacWSTouchCandidateDecisionTap) {
                    BOOL doubleTap = _directTouch.tapCount >= 2 ||
                        MacWSIsDirectDoubleTap(
                            _lastDirectTapTimestamp, _directTouch.timestamp,
                            point.x - _lastDirectTapPoint.x,
                            point.y - _lastDirectTapPoint.y);
                    if (doubleTap) {
                        _lastDirectTapTimestamp = 0.0;
                    } else {
                        _lastDirectTapTimestamp = _directTouch.timestamp;
                        _lastDirectTapPoint = point;
                    }
                    [self emitKind:MacWSInputKindTap
                             touch:_directTouch point:point
                        extraFlags:doubleTap
                            ? MacWSInputFlagDoubleClick : 0];
                } else if (decision == MacWSTouchCandidateDecisionScroll) {
                    _lastDirectTapTimestamp = 0.0;
                    // Preserve a quick flick even when UIKit coalesces it to a
                    // final sample; movement in direct mode is scrolling, not
                    // an implicit primary-button drag.
                    CGPoint framePoint = CGPointZero;
                    if ([self framePointForViewPoint:point output:&framePoint]) {
                        CGPoint delta = CGPointMake(
                            point.x - _directTouchStartPoint.x,
                            point.y - _directTouchStartPoint.y);
                        _directScrollAxis = MacWSChooseDirectScrollAxis(
                            delta.x, delta.y);
                        double deltaX = delta.x, deltaY = delta.y;
                        MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                        &deltaX, &deltaY);
                        delta = CGPointMake(deltaX, deltaY);
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:MacWSInputFlagScrollBegan
                                           timestamp:_directTouchStartTimestamp];
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchStartTimestamp, 1.0 / 120.0);
                        CGPoint velocity = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        uint16_t endedFlags = MacWSInputFlagScrollEnded;
                        if (MacWSShouldStartScrollMomentum(
                                velocity.x, velocity.y))
                            endedFlags |= MacWSInputFlagScrollWillMomentum;
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:endedFlags
                                           timestamp:_directTouch.timestamp];
                        [self startScrollMomentumWithVelocity:velocity
                                                   framePoint:framePoint];
                    }
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateLongPressArmed) {
                _lastDirectTapTimestamp = 0.0;
                CGFloat armedTravel = hypot(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                if (armedTravel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                    // Preserve hold-then-drag if UIKit coalesces the threshold
                    // crossing into the terminal touch sample.
                    CGPoint startFrame = CGPointZero;
                    if ([self framePointForViewPoint:_directTouchStartPoint
                                              output:&startFrame]) {
                        [self emitKind:MacWSInputKindTouchDown
                            framePoint:startFrame pressure:1.0f
                             contactID:(uint32_t)_directTouch.hash
                              timestamp:_directTouchStartTimestamp];
                        [self emitKind:MacWSInputKindTouchMove
                                 touch:_directTouch point:point];
                        [self emitKind:MacWSInputKindTouchUp
                                 touch:_directTouch point:point];
                    }
                } else {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateDragging) {
                _lastDirectTapTimestamp = 0.0;
                [self emitKind:MacWSInputKindTouchUp touch:_directTouch
                         point:point];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                _lastDirectTapTimestamp = 0.0;
                CGPoint framePoint = _directScrollFramePoint;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        // Include the final hardware segment in release
                        // velocity. Omitting it made a short iOS-style flick
                        // inherit an older, often sub-threshold sample and
                        // silently skip the momentum phase.
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.55 + instant.x * 0.45;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.55 + instant.y * 0.45;
                    }
                    _directScrollFramePoint = framePoint;
                }
                uint16_t endedFlags = MacWSInputFlagScrollEnded;
                if (MacWSShouldStartScrollMomentum(
                        _directScrollVelocity.x, _directScrollVelocity.y))
                    endedFlags |= MacWSInputFlagScrollWillMomentum;
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:endedFlags
                                   timestamp:_directTouch.timestamp];
                [self startScrollMomentumWithVelocity:_directScrollVelocity
                                           framePoint:_directScrollFramePoint];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            _directTouchIndicator.transform = CGAffineTransformIdentity;
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        MacWSInputKind kind = _trackpadButtonDown ? MacWSInputKindTouchUp
            : MacWSInputKindTap;
        if (_trackpadButtonDown ||
            (!_trackpadHadMultipleTouches && _trackpadTravel < 10.0 &&
             touch.timestamp - _trackpadBeganAt < 0.40)) {
            [self emitKind:kind framePoint:_trackpadCursor pressure:0
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else
            [self emitTouches:touches kind:MacWSInputKindTouchCancel];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                         point:[_directTouch locationInView:self]];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:MacWSInputFlagScrollCancelled
                                   timestamp:_directTouch.timestamp];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            _directTouchIndicator.transform = CGAffineTransformIdentity;
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (_trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesCancelled:touches withEvent:event];
}

- (void)resetViewportZoom {
    CGFloat previousZoom = _viewportZoom;
    CGPoint previousCenter = _viewportCenter;
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _contentGesturesPassthrough = NO;
    [self updateZoomHUD];
    [self setNeedsDisplay];
    MacWSLog(@"viewport-reset previous-zoom=%.3f previous-center=(%.3f,%.3f) zoom=%.3f center=(%.3f,%.3f)",
             previousZoom, previousCenter.x, previousCenter.y,
             _viewportZoom, _viewportCenter.x, _viewportCenter.y);
}

- (void)viewportZoomToggled:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    if ([self isViewportZoomed]) {
        [self resetViewportZoom];
        [self publishStatus:@"已退出放大视角"];
    } else {
        if ([self currentFrameWidth] == 0 || [self currentFrameHeight] == 0)
            return;
        simd_float4 unusedVertices[4];
        [self updateContentRectAndVertices:unusedVertices];
        CGPoint location = [recognizer locationInView:self];
        CGPoint normalized = CGPointMake(
            self.bounds.size.width > 0
                ? location.x / self.bounds.size.width : 0.5,
            self.bounds.size.height > 0
                ? location.y / self.bounds.size.height : 0.5);
        CGPoint sourcePoint = CGPointMake(
            CGRectGetMinX(_visibleSourceRect) +
                normalized.x * CGRectGetWidth(_visibleSourceRect),
            CGRectGetMinY(_visibleSourceRect) +
                normalized.y * CGRectGetHeight(_visibleSourceRect));
        _viewportZoom = _fixedZoomScale;
        // First derive the enlarged visible size, then choose a center that
        // keeps the tapped source point under the same two-finger centroid.
        // The viewport clamp may adjust this only near texture boundaries.
        [self updateContentRectAndVertices:unusedVertices];
        MacWSNormalizedPoint requestedCenter = MacWSViewportCenterKeepingAnchor(
            (MacWSNormalizedRect){
                .x = CGRectGetMinX(_visibleSourceRect),
                .y = CGRectGetMinY(_visibleSourceRect),
                .width = CGRectGetWidth(_visibleSourceRect),
                .height = CGRectGetHeight(_visibleSourceRect),
            },
            (MacWSNormalizedPoint){sourcePoint.x, sourcePoint.y},
            normalized.x, normalized.y);
        _viewportCenter = CGPointMake(requestedCenter.x, requestedCenter.y);
        [self updateContentRectAndVertices:unusedVertices];
        [self updateZoomHUD];
        [self setNeedsDisplay];
        [self publishStatus:[NSString stringWithFormat:
            @"已进入 %.1f× 放大视角", _fixedZoomScale]];
    }
}

- (BOOL)scrollFramePointForRecognizer:(UIGestureRecognizer *)recognizer
                               output:(CGPoint *)scrollPoint {
    CGPoint point = _trackpadCursor;
    if (self.inputMode == MacWSHostInputModeDirect) {
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&point]) return NO;
    } else {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (point.x < 0 || point.y < 0 ||
            point.x >= width || point.y >= height)
            point = CGPointMake(width * 0.5, height * 0.5);
    }
    if (scrollPoint) *scrollPoint = point;
    return YES;
}

- (void)emitMagnifyAtFramePoint:(CGPoint)framePoint
                          amount:(CGFloat)amount
                           flags:(uint16_t)flags
                       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled || !isfinite(amount)) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindMagnify,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = (float)amount,
        .contactID = 0x50494e43u, // "PINC"
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitScrollAtFramePoint:(CGPoint)framePoint
                    translation:(CGPoint)translation
                          flags:(uint16_t)flags
                      timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled) return;
    // UIKit translation is measured in Host points, while AppKit precise
    // scrollingDelta is measured in target logical points. The old fixed 2x
    // multiplier made a Retina 1770px/885pt Terminal move roughly twice the
    // finger distance. Derive the transform from the current exact surface,
    // viewport and backing scale so scrolling stays 1:1 at every Scene size.
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 1.0;
    CGFloat contentWidth = CGRectGetWidth(_contentRect);
    CGFloat contentHeight = CGRectGetHeight(_contentRect);
    CGFloat sourceWidth = [self currentFrameWidth] *
        CGRectGetWidth(_visibleSourceRect) / backingScale;
    CGFloat sourceHeight = [self currentFrameHeight] *
        CGRectGetHeight(_visibleSourceRect) / backingScale;
    CGFloat scaleX = contentWidth > 1.0 ? sourceWidth / contentWidth : 1.0;
    CGFloat scaleY = contentHeight > 1.0 ? sourceHeight / contentHeight : 1.0;
    scaleX = fmin(fmax(scaleX, 0.25), 4.0);
    scaleY = fmin(fmax(scaleY, 0.25), 4.0);
    // Direct manipulation follows iOS: moving content down requests a
    // positive AppKit scroll delta. The relative trackpad keeps MacBook-style
    // natural scrolling, whose UIKit translation is inverted at this bridge.
    CGFloat direction = self.inputMode == MacWSHostInputModeDirect ? 1.0 : -1.0;
    float horizontal = (float)(direction * translation.x * scaleX);
    float vertical = (float)(direction * translation.y * scaleY);
    BOOL momentum = (flags & MacWSInputFlagScrollMomentum) != 0;
    BOOL began = (flags & MacWSInputFlagScrollBegan) != 0;
    BOOL changed = (flags & MacWSInputFlagScrollChanged) != 0;
    BOOL terminal = (flags & (MacWSInputFlagScrollEnded |
                              MacWSInputFlagScrollCancelled)) != 0;
    if (began && !momentum) _scrollEmissionResidual = CGPointZero;
    if (changed) {
        // CGEventCreateScrollWheelEvent2 accepts integral pixel deltas. Keep
        // the sub-pixel remainder across 60/120 Hz UIKit and deceleration
        // samples so slow motion is accumulated into real pixels instead of
        // every tail sample being rounded independently to zero.
        double accumulatedX = horizontal + _scrollEmissionResidual.x;
        double accumulatedY = vertical + _scrollEmissionResidual.y;
        horizontal = (float)nearbyint(accumulatedX);
        vertical = (float)nearbyint(accumulatedY);
        _scrollEmissionResidual.x = accumulatedX - horizontal;
        _scrollEmissionResidual.y = accumulatedY - vertical;
    }
    // Preserve every UIKit movement sample. AppInputBridge already performs
    // lossless adjacent-scroll coalescing when the consumer is backpressured;
    // a second one-logical-pixel dead zone here delayed slow direct
    // manipulation by one or more display frames in Maps and web content.
    uint32_t horizontalBits = 0;
    memcpy(&horizontalBits, &horizontal, sizeof(horizontalBits));
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindScroll,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = vertical,
        .contactID = horizontalBits,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (terminal &&
        (momentum || !(flags & MacWSInputFlagScrollWillMomentum)))
        _scrollEmissionResidual = CGPointZero;
}

- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase {
    if (terminalPhase && _scrollMomentumDisplayLink) {
        [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollEnded |
                                     MacWSInputFlagScrollMomentum
                           timestamp:CACurrentMediaTime()];
    }
    [_scrollMomentumDisplayLink invalidate];
    _scrollMomentumDisplayLink = nil;
    _scrollMomentumVelocity = CGPointZero;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumBegan = NO;
}

- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint {
    if (!MacWSShouldStartScrollMomentum(velocity.x, velocity.y)) return;
    [self stopScrollMomentumWithTerminalPhase:NO];
    _scrollMomentumVelocity = velocity;
    _scrollMomentumFramePoint = framePoint;
    _scrollMomentumBegan = NO;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumDisplayLink = [CADisplayLink
        displayLinkWithTarget:self selector:@selector(scrollMomentumTick:)];
    NSInteger maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    _scrollMomentumDisplayLink.preferredFramesPerSecond =
        MAX(60, MIN(maximumFPS, 120));
    [_scrollMomentumDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                     forMode:NSRunLoopCommonModes];
}

- (void)scrollMomentumTick:(CADisplayLink *)link {
    CFTimeInterval timestamp = link.timestamp;
    CFTimeInterval deltaTime = _scrollMomentumLastTimestamp > 0
        ? timestamp - _scrollMomentumLastTimestamp : link.duration;
    _scrollMomentumLastTimestamp = timestamp;
    deltaTime = fmin(fmax(deltaTime, 1.0 / 240.0), 1.0 / 20.0);
    // UIScrollView's normal deceleration rate is approximately 0.998 per ms.
    CGFloat decay = pow(0.998, deltaTime * 1000.0);
    _scrollMomentumVelocity.x *= decay;
    _scrollMomentumVelocity.y *= decay;
    CGFloat speed = hypot(_scrollMomentumVelocity.x,
                          _scrollMomentumVelocity.y);
    if (speed < 18.0) {
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    uint16_t phase = _scrollMomentumBegan
        ? MacWSInputFlagScrollChanged : MacWSInputFlagScrollBegan;
    _scrollMomentumBegan = YES;
    CGPoint translation = CGPointMake(_scrollMomentumVelocity.x * deltaTime,
                                      _scrollMomentumVelocity.y * deltaTime);
    [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                     translation:translation
                           flags:phase | MacWSInputFlagScrollMomentum
                       timestamp:CACurrentMediaTime()];
}

- (void)twoFingerPanned:(UIPanGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    BOOL moveViewport = self.inputMode == MacWSHostInputModeDirect &&
        [self isViewportZoomed] && !_contentGesturesPassthrough;
    if (moveViewport) {
        if (self.bounds.size.width > 0 && self.bounds.size.height > 0) {
            _viewportCenter.x -= translation.x / self.bounds.size.width *
                CGRectGetWidth(_visibleSourceRect);
            _viewportCenter.y -= translation.y / self.bounds.size.height *
                CGRectGetHeight(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self setNeedsDisplay];
        }
        return;
    }
    CGPoint scrollPoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&scrollPoint])
        return;
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopScrollMomentumWithTerminalPhase:YES];
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollBegan
                               timestamp:CACurrentMediaTime()];
            break;
        case UIGestureRecognizerStateChanged:
            if (translation.x != 0 || translation.y != 0) {
                [self emitScrollAtFramePoint:scrollPoint translation:translation
                                       flags:MacWSInputFlagScrollChanged
                                   timestamp:CACurrentMediaTime()];
            }
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint velocity = [recognizer velocityInView:self];
            uint16_t endedFlags = MacWSInputFlagScrollEnded;
            if (MacWSShouldStartScrollMomentum(velocity.x, velocity.y))
                endedFlags |= MacWSInputFlagScrollWillMomentum;
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:endedFlags
                               timestamp:CACurrentMediaTime()];
            [self startScrollMomentumWithVelocity:velocity
                                       framePoint:scrollPoint];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
            [self stopScrollMomentumWithTerminalPhase:NO];
            break;
        default:
            break;
    }
}

- (void)pinched:(UIPinchGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    CGPoint framePoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&framePoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            recognizer.scale = 1.0;
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureBegan
                                timestamp:timestamp];
            break;
        case UIGestureRecognizerStateChanged: {
            // UIPinchGestureRecognizer.scale is cumulative. AppKit's
            // magnification is an incremental delta, so consume and reset the
            // ratio at every UIKit sample instead of accelerating over time.
            CGFloat amount = recognizer.scale - 1.0;
            recognizer.scale = 1.0;
            if (fabs(amount) > 0.00001) {
                [self emitMagnifyAtFramePoint:framePoint amount:amount
                                        flags:MacWSInputFlagGestureChanged
                                    timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureEnded
                                timestamp:timestamp];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureCancelled
                                timestamp:timestamp];
            break;
        default:
            break;
    }
}

- (void)emitDesktopCommand:(MacWSDesktopCommand)command {
    if (!self.isMacWSInputEnabled ||
        _streamClient.mode != MacWSStreamModeFullscreen ||
        command < MacWSDesktopCommandSpaceLeft ||
        command > MacWSDesktopCommandSpaceRight) return;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    int32_t commandTargetPID = 0;
    // A fullscreen workspace may have been opened from the desktop bootstrap
    // scene, whose configured targetPID is zero. Select the frontmost real
    // application layer with a live AppInput endpoint; the endpoint merely
    // supplies the CGS-connected process from which the standard
    // Control+Arrow shortcut is posted.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSStreamFrameDescriptor descriptor =
            _overlayFrames[key].descriptor;
        if (descriptor.layerOwnerPID > 1 &&
            descriptor.layerWindowID != 0 &&
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) == 0 &&
            MacWSAppInputEndpointReady(descriptor.layerOwnerPID)) {
            commandTargetPID = descriptor.layerOwnerPID;
            break;
        }
    }
    if (commandTargetPID <= 1 && self.targetPID > 1 &&
        MacWSAppInputEndpointReady(self.targetPID))
        commandTargetPID = self.targetPID;
    if (width == 0 || height == 0 || commandTargetPID <= 1) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindDesktopCommand,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = width * 0.5f,
        .y = height * 0.5f,
        .contactID = command,
        .frameWidth = width,
        .frameHeight = height,
        .targetPID = commandTargetPID,
        .source = MacWSInputSourceFinger,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)threeFingerPanned:(UIPanGestureRecognizer *)recognizer {
    if (_streamClient.mode != MacWSStreamModeFullscreen) return;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        _threeFingerCommandDispatched = NO;
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    if (_threeFingerCommandDispatched ||
        (recognizer.state != UIGestureRecognizerStateChanged &&
         recognizer.state != UIGestureRecognizerStateEnded)) return;
    CGPoint translation = [recognizer translationInView:self];
    CGPoint velocity = [recognizer velocityInView:self];
    MacWSThreeFingerGesture gesture = MacWSClassifyThreeFingerPan(
        translation.x, translation.y, velocity.x, velocity.y,
        MIN(self.bounds.size.width, self.bounds.size.height));
    if (gesture == MacWSThreeFingerGestureNone) return;
    MacWSDesktopCommand command = 0;
    NSString *status = nil;
    if (gesture == MacWSThreeFingerGestureLeft ||
        gesture == MacWSThreeFingerGestureRight) {
        command = gesture == MacWSThreeFingerGestureLeft
            ? MacWSDesktopCommandSpaceRight
            : MacWSDesktopCommandSpaceLeft;
        status = gesture == MacWSThreeFingerGestureLeft
            ? @"切换到右侧桌面" : @"切换到左侧桌面";
    } else {
        // A native Control+Up Mission Control transaction reaches MPS from
        // this headless WindowServer and runtime-crashed it with
        // OS_REASON_COREANIMATION / MPS Internal Error 00000103. Preserve the
        // MacBook gesture vocabulary with Host's real window catalog instead
        // of risking the whole desktop.
        _threeFingerCommandDispatched = YES;
        [self.statusDelegate metalView:self
            requestedWindowOverviewForCurrentApplication:
                gesture == MacWSThreeFingerGestureDown];
        [_directTouchFeedback impactOccurred];
        [self publishStatus:gesture == MacWSThreeFingerGestureUp
            ? @"macOS 窗口总览" : @"当前应用窗口"];
        return;
    }
    if (!command) return;
    _threeFingerCommandDispatched = YES;
    [self emitDesktopCommand:command];
    [_directTouchFeedback impactOccurred];
    [self publishStatus:status];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _threeFingerPanRecognizer)
        return self.isMacWSInputEnabled &&
            _streamClient.mode == MacWSStreamModeFullscreen;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    // A physical two-finger gesture carries translation and scale at the same
    // time. Preserve both streams so Maps/canvas apps can pan while pinching,
    // matching a MacBook trackpad instead of making UIKit choose one winner.
    return (gestureRecognizer == _twoFingerPanRecognizer &&
            otherGestureRecognizer == _pinchRecognizer) ||
           (gestureRecognizer == _pinchRecognizer &&
            otherGestureRecognizer == _twoFingerPanRecognizer);
}

- (void)trackpadSecondaryTapped:(UITapGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled ||
        recognizer.state != UIGestureRecognizerStateEnded) return;
    if (self.inputMode == MacWSHostInputModeDirect) {
        CGPoint framePoint = CGPointZero;
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&framePoint]) return;
        [self emitKind:MacWSInputKindSecondaryTap framePoint:framePoint
             pressure:0 contactID:0x53454332u
             timestamp:CACurrentMediaTime()];
        return;
    }
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
        _trackpadCursor.x >= width || _trackpadCursor.y >= height)
        _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
    [self emitKind:MacWSInputKindSecondaryTap framePoint:_trackpadCursor
         pressure:0 contactID:0x53454332u timestamp:CACurrentMediaTime()];
}

- (void)hovered:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceIndirectPointer,
        .sampleSequence = ++_inputSampleSequence,
    };
    _externalPointerHoverActive = recognizer.state ==
            UIGestureRecognizerStateBegan ||
        recognizer.state == UIGestureRecognizerStateChanged;
    _trackpadCursor = framePoint;
    if (self.inputMode == MacWSHostInputModeTrackpad)
        [self updatePointerVisibility];
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)pencilHovered:(UIHoverGestureRecognizer *)recognizer
    API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint = CGPointZero;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    BOOL active = recognizer.state == UIGestureRecognizerStateBegan ||
                  recognizer.state == UIGestureRecognizerStateChanged;
    _pencilHoverActive = active;
    _pencilCursorView.center = viewPoint;
    [self updatePointerVisibility];
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourcePencil,
        .flags = MacWSInputFlagPreciseLocation,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)streamClient:(MacWSStreamClient *)client
       statusChanged:(NSString *)status
           connected:(BOOL)connected {
    (void)client;
    MacWSLog(@"display-stream status connected=%@ message=%@",
             connected ? @"YES" : @"NO", status ?: @"");
    _streamConnected = connected;
    if (!connected && (_surfaceFrame || _overlayFrames.count)) {
        _framePollDisplayLink.paused = self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled();
        if (_surfaceFrame &&
            _surfaceFrame.descriptor.sequence == _submittedSurfaceSequence)
            [_retiredSurfaceFrames addObject:_surfaceFrame];
        else if (_surfaceFrame)
            [_streamClient releaseFrame:_surfaceFrame];
        [_retiredSurfaceFrames addObjectsFromArray:_overlayFrames.allValues];
        _surfaceFrame = nil;
        _surfaceTexture = nil;
        [_overlayFrames removeAllObjects];
        [_overlayTextures removeAllObjects];
        _sortedOverlayKeys = nil;
        _sourceTexture = nil;
        _textureWidth = 0;
        _textureHeight = 0;
        [self setNeedsDisplay];
    }
    if (!_surfaceFrame) [self publishStatus:status];
}

- (void)streamClient:(MacWSStreamClient *)client
      receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)client;
    MacWSLog(@"display-stream window-list count=%lu",
             (unsigned long)windows.count);
    [self.statusDelegate metalView:self receivedWindows:windows];
}

- (void)streamClient:(MacWSStreamClient *)client
        receivedFrame:(MacWSSurfaceFrame *)frame {
    uint32_t format = frame.descriptor.pixelFormat;
    // SkyLight/CGDisplayStream is requested as 32BGRA.  Reject another
    // explicit FourCC instead of silently interpreting it with the wrong
    // Metal pixel format.  A zero FourCC is accepted for older IOSurfaces
    // whose pixel-format property is absent.
    if (format != 0 && format != 0x42475241u) {
        [client releaseFrame:frame];
        [self publishStatus:@"DisplayStream 返回了非 BGRA IOSurface"];
        return;
    }
    if (!self.device) {
        [client releaseFrame:frame];
        return;
    }
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(frame.surface);
    NSUInteger requiredAlignment =
        MacWSIOSurfaceReadOnlyTextureAlignment(self.device);
    if (requiredAlignment != 0 &&
        bytesPerRow % requiredAlignment != 0) {
        MacWSLog(@"display-stream reject-metal-stride stream=%llu frame=%llu "
                 "window=%u layer=%u surface=%ux%u bpr=%zu required=%lu",
            (unsigned long long)frame.descriptor.streamID,
            (unsigned long long)frame.descriptor.sequence,
            frame.descriptor.windowID, frame.descriptor.layerWindowID,
            frame.descriptor.width, frame.descriptor.height, bytesPerRow,
            (unsigned long)requiredAlignment);
        [client releaseFrame:frame];
        [self publishStatus:[NSString stringWithFormat:
            @"DisplayStream IOSurface 行跨度未按 Metal 要求对齐（%zu / %lu）",
            bytesPerRow, (unsigned long)requiredAlignment]];
        return;
    }
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:frame.descriptor.width
                                                          height:frame.descriptor.height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor
                                                         iosurface:frame.surface
                                                             plane:0];
    if (!texture) {
        [client releaseFrame:frame];
        [self publishStatus:@"无法从 DisplayStream IOSurface 创建 Metal 纹理"];
        return;
    }
    _surfaceTextureImports++;
    texture.label = [NSString stringWithFormat:@"MacWS stream %llu frame %llu",
        (unsigned long long)frame.descriptor.streamID,
        (unsigned long long)frame.descriptor.sequence];

    if ((frame.descriptor.flags & MacWSStreamFrameOverlay) != 0) {
        NSNumber *key = @(frame.descriptor.layerWindowID);
        MacWSSurfaceFrame *previous = _overlayFrames[key];
        if (!previous ||
            previous.descriptor.layerLevel != frame.descriptor.layerLevel)
            _sortedOverlayKeys = nil;
        if (previous) [_retiredSurfaceFrames addObject:previous];
        _overlayFrames[key] = frame;
        _overlayTextures[key] = texture;
        _streamConnected = YES;
        [self setNeedsDisplay];
        return;
    }

    MacWSSurfaceFrame *previous = _surfaceFrame;
    BOOL geometryChanged = !previous ||
        !MacWSStreamFrameGeometryEqual(previous.descriptor,
                                       frame.descriptor);
    if (previous) {
        if (previous.descriptor.sequence == _submittedSurfaceSequence)
            [_retiredSurfaceFrames addObject:previous];
        else
            [client releaseFrame:previous];
    }
    _surfaceFrame = frame;
    _surfaceTexture = texture;
    _streamConnected = YES;
    if (_windowConfigurationAwaitingAcknowledgement &&
        self.targetWindowID != 0 &&
        frame.descriptor.windowID == self.targetWindowID &&
        frame.descriptor.backingScale > 0.0f) {
        CGSize applied = {
            frame.descriptor.contentWidth / frame.descriptor.backingScale,
            frame.descriptor.contentHeight / frame.descriptor.backingScale,
        };
        if (fabs(applied.width - _pendingRequestedWindowSize.width) < 1.0 &&
            fabs(applied.height - _pendingRequestedWindowSize.height) < 1.0) {
            // The DisplayStream IOSurface is the visible downstream
            // postcondition of AppKit accepting ConfigureWindow. Stop all
            // remaining retries as soon as that exact size lands.
            _windowConfigurationAwaitingAcknowledgement = NO;
            _windowConfigurationSettlementSerial++;
        }
    }
    if (!previous) {
        // suspendStream deliberately releases the old stream's base frame.
        // applyStatus consequently disables input until the replacement has
        // an IOSurface.  A DisplayStream connection notification can precede
        // this frame, so publish a distinct first-frame state transition and
        // let the controller re-evaluate the complete input invariant.
        [self publishStatus:@"DisplayStream IOSurface 首帧已就绪"];
    }
    // DisplayStream is now authoritative. Stop polling the legacy mmap
    // acknowledgement files until this Scene changes streams or disconnects.
    _framePollDisplayLink.paused = YES;
    if (geometryChanged) {
        [self updatePresentationGeometry];
        [self scheduleWindowConfiguration];
    }
    [self setNeedsDisplay];
}

- (void)streamClient:(MacWSStreamClient *)client
 removedLayerWindowID:(uint32_t)layerWindowID {
    (void)client;
    NSNumber *key = @(layerWindowID);
    MacWSSurfaceFrame *frame = _overlayFrames[key];
    if (!frame) return;
    [_retiredSurfaceFrames addObject:frame];
    [_overlayFrames removeObjectForKey:key];
    [_overlayTextures removeObjectForKey:key];
    _sortedOverlayKeys = nil;
    MacWSLog(@"display-stream overlay-retire-ui layer=%u immediate=YES",
             layerWindowID);
    [self setNeedsDisplay];
}
@end

@interface MacWSViewController : UIViewController
    <MacWSMetalViewStatusDelegate, MacWSInteropClientDelegate,
     UIDocumentPickerDelegate, UIDragInteractionDelegate, UITextFieldDelegate,
     UIDropInteractionDelegate>
- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable;
- (void)performURLAction:(NSString *)action;
- (void)launchApplicationIdentifier:(NSString *)identifier;
- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled;
- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason;
- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason;
- (NSUserActivity *)streamRestorationActivity;
- (void)suspendSceneStream;
- (void)resumeSceneStream;
- (void)cancelBootstrapTerminal;
- (void)sceneGeometryDidChange;
- (BOOL)activateCurrentMacWindow;
- (BOOL)activateMacWindow:(MacWSStreamWindow *)window;
- (BOOL)isFullscreenWorkspace;
- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title;
- (void)presentWindowOverviewCurrentApplication:(BOOL)currentApplicationOnly;
- (void)reassertFullscreenScenePresentation;
- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity;
- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID;
@end

// A fullscreen workspace remains the presentation of the exact AppKit window
// from which it was entered. Resolve that owned identity uniformly anywhere
// Scene lifecycle code needs to deduplicate, prune, close or restore it.
static BOOL MacWSSceneOwnedWindowFields(NSDictionary *info,
                                        int32_t *ownerPIDOut,
                                        uint32_t *windowIDOut,
                                        uint32_t *logicalGroupIDOut) {
    MacWSStreamMode mode = (MacWSStreamMode)[info[@"mode"] unsignedIntValue];
    int32_t ownerPID = 0;
    uint32_t windowID = 0, logicalGroupID = 0;
    if (mode == MacWSStreamModeWindow) {
        ownerPID = [info[@"owner_pid"] intValue];
        windowID = [info[@"window_id"] unsignedIntValue];
        logicalGroupID = [info[@"logical_group_id"] unsignedIntValue];
    } else if (mode == MacWSStreamModeFullscreen) {
        ownerPID = [info[@"return_owner_pid"] intValue];
        windowID = [info[@"return_window_id"] unsignedIntValue];
        logicalGroupID =
            [info[@"return_logical_group_id"] unsignedIntValue];
    }
    if (ownerPID <= 1 || windowID == 0) return NO;
    if (ownerPIDOut) *ownerPIDOut = ownerPID;
    if (windowIDOut) *windowIDOut = windowID;
    if (logicalGroupIDOut) *logicalGroupIDOut = logicalGroupID;
    return YES;
}

static BOOL MacWSSceneIsFullscreenWorkspace(NSDictionary *info) {
    return [info isKindOfClass:NSDictionary.class] &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
}

static void MacWSRequestNewScene(UIScene *requestingScene,
                                 uint32_t windowID,
                                 int32_t ownerPID,
                                 uint32_t logicalGroupID,
                                 CGSize preferredSize,
                                 CGSize minimumSize,
                                 BOOL resizable,
                                 NSString *title,
                                 void (^failureHandler)(NSError *error)) {
    UIApplication *application = UIApplication.sharedApplication;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Workspace";
    activity.userInfo = @{
        @"mode": @(windowID ? MacWSStreamModeWindow : MacWSStreamModeFullscreen),
        @"window_id": @(windowID),
        @"owner_pid": @(windowID ? ownerPID : 0),
        @"logical_group_id": @(windowID ? logicalGroupID : 0),
        @"preferred_width": @(windowID ? preferredSize.width : 0),
        @"preferred_height": @(windowID ? preferredSize.height : 0),
        @"minimum_width": @(windowID ? minimumSize.width : 0),
        @"minimum_height": @(windowID ? minimumSize.height : 0),
        @"resizable": @(windowID ? resizable : NO),
        @"title": activity.title,
    };
    UISceneSession *existingSession = nil;
    if (windowID != 0 && ownerPID > 1) {
        for (UISceneSession *session in application.openSessions) {
            NSUserActivity *candidate = session.stateRestorationActivity;
            for (UIScene *scene in application.connectedScenes) {
                if (scene.session != session ||
                    ![scene isKindOfClass:UIWindowScene.class]) continue;
                UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
                    .rootViewController;
                if ([root isKindOfClass:MacWSViewController.class])
                    candidate = [(MacWSViewController *)root
                        streamRestorationActivity];
                break;
            }
            NSDictionary *info = candidate.userInfo;
            int32_t candidateOwner = 0;
            uint32_t candidateWindow = 0, candidateGroup = 0;
            if (!MacWSSceneOwnedWindowFields(info, &candidateOwner,
                    &candidateWindow, &candidateGroup) ||
                candidateOwner != ownerPID) continue;
            BOOL sameIdentity = logicalGroupID != 0 && candidateGroup != 0
                ? logicalGroupID == candidateGroup
                : windowID == candidateWindow;
            if (sameIdentity) {
                existingSession = session;
                break;
            }
        }
    }
    MacWSLog(@"scene-activation requested supportsMultiple=%@ connected=%lu open=%lu origin=%@ window=%u",
             application.supportsMultipleScenes ? @"YES" : @"NO",
             (unsigned long)application.connectedScenes.count,
             (unsigned long)application.openSessions.count,
             requestingScene.session.persistentIdentifier, windowID);
    if (existingSession) {
        MacWSLog(@"scene-activation reusing id=%@ owner=%d group=%u window=%u",
                 existingSession.persistentIdentifier, ownerPID,
                 logicalGroupID, windowID);
    }
    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    options.requestingScene = requestingScene;
    [application requestSceneSessionActivation:existingSession
                                  userActivity:activity
                                       options:options
                                  errorHandler:^(NSError *error) {
        MacWSLog(@"scene-activation failed: %@", error);
        if (failureHandler) failureHandler(error);
    }];
}

// A fullscreen Scene is a Primary AppLayout.  On iPadOS 16, asking
// SpringBoard to mutate that existing layout back to Center accepts the
// transaction but leaves the UIWindow panel-sized (runtime-confirmed by the
// resize-postcondition witness).  A newly activated ordinary window Scene,
// however, is placed by the system in the current Stage Manager layout.  Use
// that native lifecycle for the return transition and transfer ownership of
// the exact AppKit window; never close it while the old fullscreen Scene is
// being discarded.
static BOOL MacWSRequestWindowedReplacementScene(
        UIScene *requestingScene, uint32_t windowID, int32_t ownerPID,
        uint32_t logicalGroupID, CGSize preferredSize, CGSize minimumSize,
        BOOL resizable, NSString *title,
        void (^failureHandler)(NSError *error)) {
    UISceneSession *oldSession = requestingScene.session;
    NSString *oldIdentifier = oldSession.persistentIdentifier;
    if (!oldSession || !oldIdentifier.length || windowID == 0 || ownerPID <= 1)
        return NO;

    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Window";
    activity.userInfo = @{
        @"mode": @(MacWSStreamModeWindow),
        @"window_id": @(windowID),
        @"owner_pid": @(ownerPID),
        @"logical_group_id": @(logicalGroupID),
        @"preferred_width": @(preferredSize.width),
        @"preferred_height": @(preferredSize.height),
        @"minimum_width": @(minimumSize.width),
        @"minimum_height": @(minimumSize.height),
        @"resizable": @(resizable),
        @"title": activity.title,
        @"replaces_session_identifier": oldIdentifier,
    };
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:oldIdentifier];

    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    options.requestingScene = requestingScene;
    MacWSLog(@"scene-windowed-replacement requested old=%@ owner=%d window=%u group=%u preferred=%.1fx%.1f route=new-system-window-scene",
             oldIdentifier, ownerPID, windowID, logicalGroupID,
             preferredSize.width, preferredSize.height);
    [UIApplication.sharedApplication
        requestSceneSessionActivation:nil userActivity:activity options:options
        errorHandler:^(NSError *error) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:oldIdentifier];
            MacWSLog(@"scene-windowed-replacement failed old=%@ error=%@",
                     oldIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSWindowingBridgeIsLoadedWithCapability(
        NSString *capability) {
    NSString *witness = [NSString stringWithContentsOfFile:
        MacWSWindowingLoadedPath encoding:NSUTF8StringEncoding error:nil];
    NSRange versionMarker = [witness rangeOfString:@"version="];
    NSInteger version = versionMarker.location == NSNotFound ? 0 :
        [[witness substringFromIndex:NSMaxRange(versionMarker)] integerValue];
    return version >= 13 && [witness containsString:capability];
}

static BOOL MacWSWindowingFullscreenBridgeIsLoaded(void) {
    return MacWSWindowingBridgeIsLoadedWithCapability(
        @"fullscreen=focused-scene-maximization-toggle-action-17");
}

static BOOL MacWSWindowingResizeBridgeIsLoaded(void) {
    return MacWSWindowingBridgeIsLoadedWithCapability(
        @"resize=app-layout-transaction");
}

static BOOL MacWSRequestNativeSceneSizeWithRole(UIWindowScene *scene,
                                                CGSize preferredSize,
                                                BOOL requestWindowedRole) {
    if (!scene || !scene.session || !isfinite(preferredSize.width) ||
        !isfinite(preferredSize.height) || preferredSize.width < 150.0 ||
        preferredSize.height < 150.0) {
        return NO;
    }
    if (!MacWSWindowingResizeBridgeIsLoaded()) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=windowing-bridge-not-loaded",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=fbs-scene-identifier-missing",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSResizeRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"width": @(round(preferredSize.width)),
        @"height": @(round(preferredSize.height)),
        @"windowed_role": @(requestWindowedRole),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    BOOL wrote = [request writeToFile:path atomically:YES];
    if (!wrote) {
        MacWSLog(@"scene-native-size unavailable id=%@ fbs=%@ requested=%.1fx%.1f reason=request-write-failed",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height);
        return NO;
    }

    MacWSLog(@"scene-native-size requested id=%@ fbs=%@ requested=%.1fx%.1f windowed-role=%@ route=SBMainWorkspace",
             scene.session.persistentIdentifier, sceneIdentifier,
             preferredSize.width, preferredSize.height,
             requestWindowedRole ? @"YES" : @"NO");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestResizeNotification, NULL, NULL, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        MacWSLog(@"scene-native-size result id=%@ fbs=%@ requested=%.1fx%.1f windowed-role=%@ fills-screen=%@ bounds=%.1fx%.1f",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height,
                 requestWindowedRole ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 sceneBounds.size.width, sceneBounds.size.height);
    });
    return YES;
}

static BOOL MacWSRequestCurrentSceneMaximization(
        UIWindowScene *scene, BOOL expectedFullscreen,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive) {
        MacWSLog(@"scene-fullscreen unavailable reason=scene-not-active session=%@",
                 scene.session.persistentIdentifier ?: @"none");
        return NO;
    }

    if (!MacWSWindowingFullscreenBridgeIsLoaded()) {
        MacWSLog(@"scene-fullscreen unavailable reason=windowing-bridge-not-loaded session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-fullscreen unavailable reason=fbs-scene-identifier-missing session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    UIWindow *sceneWindow = nil;
    for (UIWindow *candidate in scene.windows) {
        if (candidate.isKeyWindow) {
            sceneWindow = candidate;
            break;
        }
        if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
            sceneWindow = candidate;
    }
    // UIWindowScene.coordinateSpace is panel-sized under Stage Manager even
    // while the actual app window is 1004x807 (runtime-confirmed on scene
    // DCEB78D2).  UIWindow.bounds is the user-visible scene extent and is the
    // only valid source/postcondition for the maximize transaction.
    CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                     : scene.coordinateSpace.bounds;
    CGRect screenBounds = scene.screen.bounds;
    BOOL sourceGeometryFullscreen =
        fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
        fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
        fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
        fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSFullscreenRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"expected_fullscreen": @(expectedFullscreen),
        @"source_geometry_fullscreen": @(sourceGeometryFullscreen),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    if (![request writeToFile:path atomically:YES]) {
        MacWSLog(@"scene-fullscreen unavailable reason=request-write-failed session=%@ fbs=%@",
                 scene.session.persistentIdentifier, sceneIdentifier);
        return NO;
    }

    MacWSLog(@"scene-maximization requested session=%@ fbs=%@ expected-fullscreen=%@ source-geometry-fullscreen=%@ route=springboard-maximization-toggle-action-17 current-bounds=%@ screen-bounds=%@",
             scene.session.persistentIdentifier, sceneIdentifier,
             expectedFullscreen ? @"YES" : @"NO",
             sourceGeometryFullscreen ? @"YES" : @"NO",
             NSStringFromCGRect(sceneBounds), NSStringFromCGRect(screenBounds));
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestFullscreenNotification, NULL, NULL, true);

    // The SpringBoard transaction is asynchronous.  A Primary AppLayout is
    // not sufficient evidence of full-screen geometry under Stage Manager;
    // runtime showed Primary/center=0 while this Scene remained 1194x807 on a
    // 1389x970 screen.  Re-sample the owning UIWindowScene after the system
    // action; MacWSWindowing's AppLayout record is a model observation only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        BOOL supportsState = [scene respondsToSelector:@selector(isFullScreen)];
        BOOL systemState = supportsState && scene.isFullScreen;
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
            fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
            fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        MacWSLog(@"scene-maximization UIKit-observation session=%@ expected-fullscreen=%@ is-fullscreen=%@ fills-screen=%@ bounds=%@ screen=%@ authoritative-postcondition=UIKit-scene-screen-geometry",
                 scene.session.persistentIdentifier,
                 expectedFullscreen ? @"YES" : @"NO",
                 systemState ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 NSStringFromCGRect(sceneBounds),
                 NSStringFromCGRect(screenBounds));
        (void)failureHandler;
    });
    return YES;
}

// UIKit's current-session fullscreen activation is the private route closest
// to video/game presentation: it asks FrontBoard to make this exact existing
// session fullscreen rather than resizing a Metal layer.  Earlier builds lost
// the display subscription when FrontBoard reconnected the Scene; the Scene
// ownership and compositor handoff are now persistent, so retry the real
// system request before falling back to the Stage Manager maximization bridge.
static BOOL MacWSRequestCurrentSceneImmersiveFullscreen(
        UIWindowScene *scene, NSUserActivity *activity,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive)
        return NO;
    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    SEL selector = @selector(_setRequestFullscreen:);
    if (![options respondsToSelector:selector]) return NO;
    [options _setRequestFullscreen:YES];
    options.requestingScene = scene;
    MacWSLog(@"scene-immersive requested session=%@ fbs=%@ route=current-session-activation",
             scene.session.persistentIdentifier,
             [scene respondsToSelector:@selector(_sceneIdentifier)]
                ? [scene _sceneIdentifier] : @"unknown");
    [UIApplication.sharedApplication
        requestSceneSessionActivation:scene.session
        userActivity:activity
        options:options
        errorHandler:^(NSError *error) {
            MacWSLog(@"scene-immersive failed session=%@ error=%@",
                     scene.session.persistentIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSSendCloseWindow(uint32_t windowID, int32_t ownerPID,
                                 int *errorOut) {
    if (windowID == 0 || ownerPID <= 1) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindCloseWindow,
        .sceneID = MacWSInputSceneForWindow(windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = ownerPID,
        .source = MacWSInputSourceUnknown,
    };
    return MacWSSendInputRecord(&record, errorOut);
}

static NSString *MacWSWindowIdentity(int32_t ownerPID, uint32_t windowID,
                                     uint32_t logicalGroupID) {
    if (ownerPID <= 1 || windowID == 0) return nil;
    return logicalGroupID != 0
        ? [NSString stringWithFormat:@"%d:g:%u", ownerPID, logicalGroupID]
        : [NSString stringWithFormat:@"%d:w:%u", ownerPID, windowID];
}

static NSDictionary *MacWSPersistedSceneBinding(NSString *identifier) {
    if (!identifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    id value = bindings[identifier];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void MacWSSetPersistedSceneBinding(NSString *identifier,
                                          NSDictionary *info) {
    if (!identifier.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *bindings = [[defaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey] mutableCopy] ?:
        [NSMutableDictionary dictionary];
    if (info) bindings[identifier] = info;
    else [bindings removeObjectForKey:identifier];
    [defaults setObject:bindings forKey:MacWSSceneBindingsDefaultsKey];
    // Binding changes are rare lifecycle transactions. Flush them before a
    // possible FrontBoard process eviction so a reconnected Scene does not
    // regress to its original bootstrap activity.
    [defaults synchronize];
}

static NSUserActivity *MacWSPersistedSceneActivity(NSString *identifier) {
    NSDictionary *info = MacWSPersistedSceneBinding(identifier);
    if (!MacWSSceneOwnedWindowFields(info, NULL, NULL, NULL) &&
        !MacWSSceneIsFullscreenWorkspace(info)) return nil;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [info[@"title"] isKindOfClass:NSString.class]
        ? info[@"title"] : @"MacWS Window";
    activity.userInfo = info;
    return activity;
}

static NSUserActivity *MacWSRecoverOrphanedWorkspaceActivity(
        UISceneSession *newSession) {
    NSString *newIdentifier = newSession.persistentIdentifier;
    if (!newIdentifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    if (bindings.count == 0) return nil;
    NSString *candidateIdentifier = nil;
    NSDictionary *candidateInfo = nil;
    for (NSString *identifier in bindings) {
        if ([identifier isEqualToString:newIdentifier]) continue;
        NSDictionary *info = [bindings[identifier]
            isKindOfClass:NSDictionary.class] ? bindings[identifier] : nil;
        if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeFullscreen)
            continue;
        int32_t ownerPID = 0;
        BOOL ownsReturnWindow = MacWSSceneOwnedWindowFields(
            info, &ownerPID, NULL, NULL);
        if (ownsReturnWindow) {
            errno = 0;
            if (kill(ownerPID, 0) != 0 && errno == ESRCH) continue;
        }
        // More than one orphaned workspace cannot be assigned safely without
        // a stable token from UIKit. Refuse ambiguity instead of restoring an
        // unrelated AppKit window into the new Scene.
        if (candidateInfo) return nil;
        candidateIdentifier = identifier;
        candidateInfo = info;
    }
    if (!candidateInfo) return nil;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:candidateIdentifier];
    [MacWSSceneBindings removeObjectForKey:candidateIdentifier];
    MacWSSetPersistedSceneBinding(newIdentifier, candidateInfo);
    MacWSSetPersistedSceneBinding(candidateIdentifier, nil);
    MacWSLog(@"scene-workspace-binding-migrated old=%@ new=%@ return-window=%u owner=%d",
             candidateIdentifier, newIdentifier,
             [candidateInfo[@"return_window_id"] unsignedIntValue],
             [candidateInfo[@"return_owner_pid"] intValue]);
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [candidateInfo[@"title"] isKindOfClass:NSString.class]
        ? candidateInfo[@"title"] : @"MacWS Workspace";
    activity.userInfo = candidateInfo;
    return activity;
}

// UISceneSession.stateRestorationActivity is not updated continuously while a
// Scene changes from the bootstrap workspace to an exact macOS window. Keep
// the live binding by persistent session identifier, and make closing a
// transaction that is idempotent across the explicit close button,
// didDiscardSceneSessions:, and a late sceneDidDisconnect: callback.
static void MacWSRememberSceneBinding(UISceneSession *session,
                                      NSUserActivity *activity) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    // Once this session has committed a close transaction, a late state
    // restoration callback must not resurrect the binding and send a second
    // performClose: while UIKit is tearing the Scene down.
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    if (MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL) ||
        MacWSSceneIsFullscreenWorkspace(info)) {
        MacWSSceneBindings[identifier] = activity;
        [MacWSSceneCloseRequestsSent removeObject:identifier];
        MacWSSetPersistedSceneBinding(identifier, info);
    } else {
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);
    }
}

static BOOL MacWSCloseMacWindowForSceneSession(UISceneSession *session,
                                                NSString *source) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return NO;
    if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
        return NO;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return YES;
    NSUserActivity *activity = MacWSSceneBindings[identifier] ?:
        MacWSPersistedSceneActivity(identifier) ?:
        session.stateRestorationActivity;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL))
        return NO;
    int sendError = 0;
    BOOL sent = MacWSSendCloseWindow(windowID, ownerPID, &sendError);
    if (sent) {
        [MacWSSceneCloseRequestsSent addObject:identifier];
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);
    }
    MacWSLog(@"scene-close source=%@ id=%@ window=%u target=%d sent=%@ errno=%d",
             source ?: @"unknown", identifier, windowID, ownerPID,
             sent ? @"YES" : @"NO", sendError);
    return sent;
}

typedef void (^MacWSCompactMenuSelection)(MacWSMenuItem *item);

// UIAlertController action sheets have a fixed iOS row metric and do not
// relayout reliably when actions are appended after presentation. A macOS menu
// snapshot is already a complete immutable tree, so render one compact table
// only after that tree arrives. This keeps every row present on the first
// frame and gives the semantic menu macOS-like density without private UIKit
// APIs.
@interface MacWSCompactMenuController : UIViewController
    <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection;
@end

@implementation MacWSCompactMenuController {
    NSArray<MacWSMenuItem *> *_items;
    MacWSCompactMenuSelection _selection;
    UITableView *_tableView;
}

- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _items = [items copy];
    _selection = [selection copy];
    self.modalPresentationStyle = UIModalPresentationPopover;
    if (appearance == MacWSMenuAppearanceDark)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

    CGFloat width = 168.0;
    CGFloat height = 2.0;
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0]
    };
    NSDictionary *shortcutAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0]
    };
    for (MacWSMenuItem *item in _items) {
        if (item.flags & MacWSMenuNodeHidden) continue;
        if (item.flags & MacWSMenuNodeSeparator) {
            height += 8.0;
            continue;
        }
        CGFloat titleWidth = [item.title sizeWithAttributes:titleAttributes].width;
        CGFloat shortcutWidth = [item.shortcut
            sizeWithAttributes:shortcutAttributes].width;
        width = MAX(width, titleWidth + shortcutWidth +
            ((item.flags & MacWSMenuNodeHasSubmenu) ? 60.0 : 48.0));
        height += 29.0;
    }
    self.preferredContentSize = CGSizeMake(MIN(320.0, ceil(width)),
                                            MIN(380.0, ceil(height)));
    return self;
}

- (void)loadView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                               style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(1, 0, 1, 0);
    _tableView.scrollEnabled = self.preferredContentSize.height >= 380.0;
    _tableView.showsVerticalScrollIndicator = _tableView.scrollEnabled;
    _tableView.layer.cornerRadius = 8.0;
    _tableView.clipsToBounds = YES;
    self.view = _tableView;
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_items.count;
}

- (CGFloat)tableView:(UITableView *)tableView
  heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    return (item.flags & MacWSMenuNodeSeparator) ? 8.0 : 29.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if (item.flags & MacWSMenuNodeSeparator) {
        UITableViewCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"MacWSMenuSeparator"];
        if (!cell) {
            cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
              reuseIdentifier:@"MacWSMenuSeparator"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = UIColor.clearColor;
            UIView *line = [UIView new];
            line.tag = 91;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            line.backgroundColor = UIColor.separatorColor;
            [cell.contentView addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:
                    cell.contentView.leadingAnchor constant:8],
                [line.trailingAnchor constraintEqualToAnchor:
                    cell.contentView.trailingAnchor constant:-8],
                [line.centerYAnchor constraintEqualToAnchor:
                    cell.contentView.centerYAnchor],
                [line.heightAnchor constraintEqualToConstant:0.5],
            ]];
        }
        return cell;
    }

    UITableViewCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"MacWSMenuItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:@"MacWSMenuItem"];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        UIView *selection = [UIView new];
        selection.backgroundColor = UIColor.systemBlueColor;
        cell.selectedBackgroundView = selection;
    }
    NSString *prefix = @"";
    if (item.flags & MacWSMenuNodeChecked) prefix = @"✓  ";
    else if (item.flags & MacWSMenuNodeMixed) prefix = @"—  ";
    cell.textLabel.text = [prefix stringByAppendingString:item.title ?: @""];
    NSString *suffix = item.shortcut ?: @"";
    if (item.flags & MacWSMenuNodeHasSubmenu)
        suffix = suffix.length ? [suffix stringByAppendingString:@"   ›"] : @"›";
    cell.detailTextLabel.text = suffix;
    BOOL enabled = (item.flags & MacWSMenuNodeEnabled) != 0;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if ((item.flags & (MacWSMenuNodeHidden | MacWSMenuNodeSeparator)) ||
        (item.flags & MacWSMenuNodeEnabled) == 0) return;
    MacWSCompactMenuSelection selection = _selection;
    if (selection) selection(item);
}

@end

@implementation MacWSViewController {
    NSString *_sceneIdentifier;
    MacWSStreamMode _streamMode;
    uint32_t _windowID;
    int32_t _windowOwnerPID;
    uint32_t _windowGroupID;
    CGSize _windowMinimumSize;
    CGSize _windowPreferredSize;
    BOOL _windowResizable;
    MacWSControlClient *_controlClient;
    MacWSInteropClient *_interopClient;
    MacWSMenuClient *_menuClient;
    MacWSMenuSnapshot *_menuSnapshot;
    UIVisualEffectView *_semanticMenuBar;
    NSLayoutConstraint *_semanticMenuHeightConstraint;
    UIScrollView *_semanticMenuScroll;
    UIStackView *_semanticMenuTitles;
    UIViewController *_semanticMenuPanel;
    UIControl *_semanticMenuDismissLayer;
    UIVisualEffectView *_controlPanel;
    UIControl *_controlDismissLayer;
    UIVisualEffectView *_showControlsMaterial;
    UIButton *_showControlsButton;
    UILabel *_serviceLabel;
    UILabel *_phaseLabel;
    UILabel *_rootfsLabel;
    UILabel *_windowServerLabel;
    UILabel *_bridgeLabel;
    UILabel *_frameLabel;
    UILabel *_statusLabel;
    UILabel *_inputLabel;
    UILabel *_interopLabel;
    UILabel *_noticeLabel;
    UIButton *_primaryButton;
    UIButton *_repairButton;
    UIButton *_recoverButton;
    UIButton *_captureButton;
    UIButton *_logsButton;
    UIButton *_exportButton;
    UIButton *_windowPickerButton;
    UIButton *_closeWindowButton;
    UIButton *_menuBarButton;
    UIButton *_clipboardButton;
    UIButton *_importButton;
    UIButton *_macFilesButton;
    UIButton *_keyboardButton;
    UITextField *_keyboardProxy;
    UIView *_softwareKeyBar;
    NSLayoutConstraint *_softwareKeyBarHeightConstraint;
    UITextField *_appSearchField;
    NSArray<UIButton *> *_softModifierButtons;
    uint32_t _softModifiers;
    UITextView *_logsView;
    UISwitch *_experimentalSwitch;
    UISegmentedControl *_inputModeControl;
    UISegmentedControl *_densityControl;
    UISegmentedControl *_zoomScaleControl;
    UIButton *_resetZoomButton;
    NSArray<UIButton *> *_applicationButtons;
    MacWSMetalView *_metalView;
    NSTimer *_statusTimer;
    NSDictionary<NSString *, id> *_latestStatus;
    BOOL _experimentalTouched;
    uint64_t _inputLogSequence;
    NSString *_lastLoggedControlSummary;
    NSArray<MacWSStreamWindow *> *_streamWindows;
    NSArray<NSURL *> *_receivedMacOSFiles;
    int32_t _pendingFinderWindowPID;
    NSUInteger _pendingFinderMenuAttempts;
    BOOL _finderMenuRequestInFlight;
    int32_t _pendingApplicationWindowPID;
    NSString *_pendingApplicationIdentifier;
    NSUInteger _pendingApplicationWindowAttempts;
    BOOL _pendingApplicationWindowRetryScheduled;
    uint32_t _pendingApplicationCandidateWindowID;
    CFTimeInterval _pendingApplicationCandidateSince;
    BOOL _bootstrapTerminalPending;
    BOOL _bootstrapWindowReplacementPending;
    BOOL _bootstrapWorkspaceStartInFlight;
    BOOL _targetWindowObservedInCatalog;
    BOOL _targetWindowMissingCheckPending;
    BOOL _sceneDestructionRequested;
    uint64_t _targetWindowMissingSerial;
    BOOL _workspaceReturnValid;
    uint32_t _workspaceReturnWindowID;
    int32_t _workspaceReturnOwnerPID;
    uint32_t _workspaceReturnGroupID;
    CGSize _workspaceReturnMinimumSize;
    CGSize _workspaceReturnPreferredSize;
    CGSize _workspaceReturnSceneSize;
    BOOL _workspaceReturnResizable;
    NSString *_workspaceReturnTitle;
}

- (BOOL)prefersStatusBarHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return _streamMode == MacWSStreamModeFullscreen
        ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)updateImmersivePresentation {
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    BOOL expected = _streamMode == MacWSStreamModeFullscreen;
    for (NSNumber *delay in @[@0, @250, @1250]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     delay.longLongValue * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIWindowScene *scene = self.view.window.windowScene;
            BOOL actualStatusHidden = scene.statusBarManager.statusBarHidden;
            MacWSLog(@"immersive-postcondition expected=%@ status-request=%@ status-hidden=%@ home-indicator-auto-hide=%@ deferred-edges=%lu bounds=%@ screen=%@ safe-insets=%@",
                     expected ? @"YES" : @"NO",
                     self.prefersStatusBarHidden ? @"YES" : @"NO",
                     actualStatusHidden ? @"YES" : @"NO",
                     self.prefersHomeIndicatorAutoHidden ? @"YES" : @"NO",
                     (unsigned long)self.preferredScreenEdgesDeferringSystemGestures,
                     NSStringFromCGRect(scene.coordinateSpace.bounds),
                     NSStringFromCGRect(scene.screen.bounds),
                     NSStringFromUIEdgeInsets(self.view.safeAreaInsets));
        });
    }
}

- (void)updateWorkspaceChrome {
    BOOL fullscreen = _streamMode == MacWSStreamModeFullscreen;
    _semanticMenuBar.hidden = fullscreen;
    _semanticMenuHeightConstraint.constant = fullscreen ? 0.0 : 26.0;
    if (_menuBarButton) {
        [self setButton:_menuBarButton
                  title:fullscreen
                      ? @"进入窗口模式" : @"打开全屏 macOS 工作区"
                  image:fullscreen
                      ? @"arrow.down.right.and.arrow.up.left"
                      : @"arrow.up.left.and.arrow.down.right"];
    }
    _closeWindowButton.hidden = fullscreen || _windowID == 0;
    [self.view setNeedsLayout];
}

- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity {
    NSDictionary *info = activity.userInfo;
    BOOL explicitFullscreenRestoration = activity &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
    if (_streamMode != MacWSStreamModeFullscreen ||
        !explicitFullscreenRestoration) return;

    // An explicit restored workspace remains a real desktop even when its
    // optional return AppKit window is already gone.  The old early return
    // left both bootstrap flags set whenever return_window_id was zero, so the
    // next Maps/Terminal catalog entry converted the live fullscreen Scene
    // into a per-window Scene.  A nil activity still represents the genuine
    // first-launch placeholder and deliberately keeps these flags set.
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    if ([info[@"return_window_id"] unsignedIntValue] == 0 ||
        [info[@"return_owner_pid"] intValue] <= 1) return;
    _workspaceReturnValid = YES;
    _workspaceReturnWindowID = [info[@"return_window_id"] unsignedIntValue];
    _workspaceReturnOwnerPID = [info[@"return_owner_pid"] intValue];
    _workspaceReturnGroupID = [info[@"return_logical_group_id"] unsignedIntValue];
    _workspaceReturnMinimumSize = CGSizeMake(
        [info[@"return_minimum_width"] doubleValue],
        [info[@"return_minimum_height"] doubleValue]);
    _workspaceReturnPreferredSize = CGSizeMake(
        [info[@"return_preferred_width"] doubleValue],
        [info[@"return_preferred_height"] doubleValue]);
    _workspaceReturnSceneSize = CGSizeMake(
        [info[@"return_scene_width"] doubleValue],
        [info[@"return_scene_height"] doubleValue]);
    _workspaceReturnResizable = [info[@"return_resizable"] boolValue];
    _workspaceReturnTitle = [info[@"return_title"] isKindOfClass:NSString.class]
        ? [info[@"return_title"] copy] : @"MacWS Window";
}

- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID {
    if (_streamMode != MacWSStreamModeFullscreen ||
        !_workspaceReturnValid || _workspaceReturnOwnerPID != ownerPID ||
        _workspaceReturnWindowID != windowID) return NO;

    // The return window is navigation history, not the owner of the full
    // desktop stream.  If that AppKit process exits while the workspace is
    // visible, preserve the compositor subscription and merely make the
    // transition back to that exact window unavailable.
    _workspaceReturnValid = NO;
    _workspaceReturnWindowID = 0;
    _workspaceReturnOwnerPID = 0;
    _workspaceReturnGroupID = 0;
    _workspaceReturnMinimumSize = CGSizeZero;
    _workspaceReturnPreferredSize = CGSizeZero;
    _workspaceReturnSceneSize = CGSizeZero;
    _workspaceReturnResizable = NO;
    _workspaceReturnTitle = nil;
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    [self setNotice:@"来源窗口已关闭；完整 macOS 工作区仍保持运行。"
             success:YES];
    MacWSLog(@"workspace-return-detached owner-missing pid=%d window=%u scene=%@",
             ownerPID, windowID,
             self.view.window.windowScene.session.persistentIdentifier);
    return YES;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sceneIdentifier = [identifier copy];
        _streamMode = streamMode;
        _windowID = windowID;
        _windowOwnerPID = windowID ? ownerPID : 0;
        _windowGroupID = windowID ? logicalGroupID : 0;
        _windowMinimumSize = windowID ? minimumSize : CGSizeZero;
        _windowPreferredSize = windowID ? preferredSize : CGSizeZero;
        _windowResizable = windowID ? resizable : NO;
        _bootstrapTerminalPending = streamMode != MacWSStreamModeWindow ||
            windowID == 0;
        _bootstrapWindowReplacementPending = _bootstrapTerminalPending;
        _controlClient = [MacWSControlClient new];
        _interopClient = [MacWSInteropClient new];
        _interopClient.delegate = self;
        _menuClient = [MacWSMenuClient new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults objectForKey:@"MacWSExperimentalMode"] == nil)
            [defaults setBool:YES forKey:@"MacWSExperimentalMode"];
        _experimentalTouched = YES;
    }
    return self;
}

static UILabel *MacWSMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title image:(NSString *)imageName
                        action:(SEL)action prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = prominent
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    configuration.imagePadding = 8;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setButton:(UIButton *)button title:(NSString *)title image:(NSString *)imageName {
    UIButtonConfiguration *configuration = [button.configuration copy];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    button.configuration = configuration;
}

- (UIStackView *)statusRowWithTitle:(NSString *)title
                              value:(UILabel * __strong *)valueOut {
    UILabel *name = MacWSMakeLabel(title,
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
        UIColor.secondaryLabelColor);
    UILabel *value = MacWSMakeLabel(@"检查中…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.tertiaryLabelColor);
    value.textAlignment = NSTextAlignmentRight;
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, value]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    if (valueOut) *valueOut = value;
    return row;
}

- (UIView *)divider {
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.45];
    [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return line;
}

- (UILabel *)sectionTitle:(NSString *)title {
    UILabel *label = MacWSMakeLabel(title.uppercaseString,
        [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
        UIColor.secondaryLabelColor);
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    return label;
}

- (UIButton *)keyboardAccessoryButton:(NSString *)title
                                   tag:(NSInteger)tag
                              modifier:(BOOL)modifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    button.configuration = configuration;
    button.tag = tag;
    [button addTarget:self
               action:modifier ? @selector(softModifierTapped:)
                               : @selector(softKeyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)makeKeyboardAccessoryView {
    UIInputView *input = [[UIInputView alloc]
        initWithFrame:CGRectMake(0, 0, 0, 52)
        inputViewStyle:UIInputViewStyleKeyboard];
    UIButton *escape = [self keyboardAccessoryButton:@"esc" tag:0xff1b
                                             modifier:NO];
    UIButton *control = [self keyboardAccessoryButton:@"control" tag:(1u << 18)
                                              modifier:YES];
    UIButton *option = [self keyboardAccessoryButton:@"option" tag:(1u << 19)
                                             modifier:YES];
    UIButton *command = [self keyboardAccessoryButton:@"⌘" tag:(1u << 20)
                                              modifier:YES];
    UIButton *shift = [self keyboardAccessoryButton:@"⇧" tag:(1u << 17)
                                            modifier:YES];
    UIButton *tab = [self keyboardAccessoryButton:@"tab" tag:0xff09
                                          modifier:NO];
    UIButton *left = [self keyboardAccessoryButton:@"←" tag:0xff51
                                           modifier:NO];
    UIButton *up = [self keyboardAccessoryButton:@"↑" tag:0xff52
                                         modifier:NO];
    UIButton *down = [self keyboardAccessoryButton:@"↓" tag:0xff54
                                           modifier:NO];
    UIButton *right = [self keyboardAccessoryButton:@"→" tag:0xff53
                                            modifier:NO];
    UIButton *dismiss = [self keyboardAccessoryButton:@"键盘↓" tag:0
                                              modifier:NO];
    dismiss.accessibilityIdentifier = @"dismiss-keyboard";
    _softModifierButtons = @[control, option, command, shift];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        escape, control, option, command, shift, tab, left, up, down, right,
        dismiss
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    [scroll addSubview:stack];
    [input addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:input.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:input.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:input.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:input.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    return input;
}

- (void)renderSemanticMenuTitles {
    if (!_semanticMenuTitles) return;
    for (UIView *view in [_semanticMenuTitles.arrangedSubviews copy]) {
        [_semanticMenuTitles removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MacWSMenuItem *> *roots = [_menuSnapshot childrenOfItemID:0];
    NSMutableArray<MacWSMenuItem *> *visible = [NSMutableArray array];
    for (MacWSMenuItem *item in roots) {
        if ((item.flags & MacWSMenuNodeHidden) == 0 && item.title.length)
            [visible addObject:item];
    }
    UIButton *apple = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *appleConfiguration =
        [UIButtonConfiguration plainButtonConfiguration];
    appleConfiguration.title = @"";
    appleConfiguration.baseForegroundColor = UIColor.labelColor;
    appleConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(0, 7, 0, 7);
    appleConfiguration.titleTextAttributesTransformer =
        ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:16
                weight:UIFontWeightSemibold];
            return result;
        };
    apple.configuration = appleConfiguration;
    apple.userInteractionEnabled = NO;
    apple.accessibilityLabel = @"Apple 菜单";
    [_semanticMenuTitles addArrangedSubview:apple];
    // The containing UIScrollView already handles narrow iPad windows. Keep
    // every real macOS root menu visible instead of collapsing to three
    // arbitrary titles and an iOS-style "more" action.
    NSUInteger limit = visible.count;
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSMenuItem *item = visible[index];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration =
            [UIButtonConfiguration plainButtonConfiguration];
        configuration.title = item.title;
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
        configuration.titleTextAttributesTransformer =
            ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *result = [attributes mutableCopy];
                result[NSFontAttributeName] = [UIFont systemFontOfSize:13.0
                    weight:index == 0 ? UIFontWeightSemibold
                                      : UIFontWeightRegular];
                return result;
            };
        button.configuration = configuration;
        button.configurationUpdateHandler = ^(UIButton *updated) {
            UIButtonConfiguration *state = [updated.configuration copy];
            state.baseForegroundColor = updated.highlighted
                ? UIColor.whiteColor : UIColor.labelColor;
            state.background.backgroundColor = updated.highlighted
                ? UIColor.systemBlueColor : UIColor.clearColor;
            state.background.cornerRadius = 4.0;
            updated.configuration = state;
        };
        button.tag = (NSInteger)item.itemID;
        button.accessibilityLabel = [NSString stringWithFormat:
            @"%@ 菜单", item.title];
        [button addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:button];
    }
    if (visible.count == 0) {
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        [retry setTitle:@"macOS 菜单…" forState:UIControlStateNormal];
        retry.tag = -1;
        [retry addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:retry];
    }
}

- (void)applyMacOSMenuAppearance:(MacWSMenuAppearance)appearance {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (appearance == MacWSMenuAppearanceDark)
        style = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        style = UIUserInterfaceStyleLight;
    _semanticMenuBar.overrideUserInterfaceStyle = style;
    _showControlsMaterial.overrideUserInterfaceStyle = style;
    _controlPanel.overrideUserInterfaceStyle = style;
    [_semanticMenuBar setNeedsLayout];
    [_showControlsMaterial setNeedsLayout];
    [_controlPanel setNeedsLayout];
}

- (void)refreshSemanticMenuWithCompletion:(void (^ _Nullable)(
        MacWSMenuSnapshot * _Nullable, NSError * _Nullable))completion {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        if (completion) completion(nil, [NSError errorWithDomain:@"MacWSMenu"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"全屏工作区使用真实 macOS 菜单栏"}]);
        return;
    }
    [_menuClient requestSnapshotForPID:_windowOwnerPID windowID:_windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            if (snapshot && snapshot.windowID == self->_windowID &&
                snapshot.ownerPID == self->_windowOwnerPID) {
                self->_menuSnapshot = snapshot;
                [self applyMacOSMenuAppearance:snapshot.appearance];
                [self renderSemanticMenuTitles];
            }
            if (completion) completion(snapshot, error);
        }];
}

- (BOOL)activateCurrentMacWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(_windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = _windowOwnerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    return YES;
}

- (BOOL)activateMacWindow:(MacWSStreamWindow *)window {
    if (!window || window.descriptor.windowID == 0 ||
        window.descriptor.ownerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(
            window.descriptor.windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = window.descriptor.ownerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    NSString *title = window.title.length ? window.title :
        [NSString stringWithFormat:@"Window %u",
            window.descriptor.windowID];
    [self setNotice:[NSString stringWithFormat:@"已切换到 %@", title]
             success:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_streamMode == MacWSStreamModeFullscreen)
            [self->_metalView requestStreamWindowList];
    });
    return YES;
}

- (BOOL)isFullscreenWorkspace {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title {
    if (_streamMode != MacWSStreamModeFullscreen ||
        windowID == 0 || ownerPID <= 1) return NO;
    for (MacWSStreamWindow *window in _streamWindows) {
        if (window.descriptor.windowID == windowID &&
            window.descriptor.ownerPID == ownerPID)
            return [self activateMacWindow:window];
    }
    [_metalView requestStreamWindowList];
    [self setNotice:[NSString stringWithFormat:@"%@ 已在当前全屏工作区中打开，正在等待窗口目录更新。",
        title.length ? title : @"macOS 应用"] success:YES];
    MacWSLog(@"fullscreen-window-route pending pid=%d window=%u title=%@",
             ownerPID, windowID, title ?: @"");
    return YES;
}

- (void)presentWindowOverviewCurrentApplication:(BOOL)currentApplicationOnly {
    if (_streamMode != MacWSStreamModeFullscreen) return;
    [_metalView requestStreamWindowList];
    NSArray<MacWSStreamWindow *> *logicalWindows =
        [self logicalWindowRepresentatives];
    int32_t currentPID = _metalView.targetPID;
    if (currentPID <= 1) {
        for (MacWSStreamWindow *window in logicalWindows) {
            if ((window.descriptor.flags & MacWSStreamWindowFocused) != 0) {
                currentPID = window.descriptor.ownerPID;
                break;
            }
        }
    }
    NSMutableArray<MacWSStreamWindow *> *visible = [NSMutableArray array];
    for (MacWSStreamWindow *window in logicalWindows) {
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        if (window.descriptor.ownerPID <= 1 ||
            (flags & MacWSStreamWindowVisible) == 0 ||
            (flags & MacWSStreamWindowOnScreen) == 0 ||
            (currentApplicationOnly &&
             window.descriptor.ownerPID != currentPID)) continue;
        [visible addObject:window];
    }
    if (visible.count == 0) {
        [self setNotice:currentApplicationOnly
            ? @"当前应用没有可切换的 macOS 窗口"
            : @"当前桌面没有可切换的 macOS 窗口" success:NO];
        return;
    }
    UIAlertController *overview = [UIAlertController
        alertControllerWithTitle:currentApplicationOnly
            ? @"当前应用窗口" : @"macOS 窗口总览"
                         message:@"三指左右切换 Space；点选窗口立即置前。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(visible.count, 24);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = visible[index];
        BOOL focused =
            (window.descriptor.flags & MacWSStreamWindowFocused) != 0;
        NSString *baseTitle = window.title.length ? window.title :
            [NSString stringWithFormat:@"Window %u",
                window.descriptor.windowID];
        NSString *title = focused
            ? [NSString stringWithFormat:@"✓ %@", baseTitle] : baseTitle;
        [overview addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                [self activateMacWindow:window];
            }]];
    }
    [overview addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    overview.popoverPresentationController.sourceView = _metalView;
    overview.popoverPresentationController.sourceRect = CGRectMake(
        CGRectGetMidX(_metalView.bounds), CGRectGetMidY(_metalView.bounds),
        1.0, 1.0);
    overview.popoverPresentationController.permittedArrowDirections = 0;
    [self presentViewController:overview animated:YES completion:nil];
}

- (void)performSemanticShortcutForDiagnostics:(NSString *)shortcut {
    if (_windowID == 0 || _windowOwnerPID <= 1 || !shortcut.length) {
        MacWSLog(@"diagnostic-menu shortcut=%@ result=no-exact-window",
                 shortcut ?: @"");
        return;
    }
    [self refreshSemanticMenuWithCompletion:^(MacWSMenuSnapshot *snapshot,
                                               NSError *error) {
        if (!snapshot || error) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=snapshot-failed "
                     "error=%@", shortcut,
                     error.localizedDescription ?: @"unknown");
            return;
        }
        MacWSMenuItem *match = nil;
        for (MacWSMenuItem *item in snapshot.items) {
            if ([item.shortcut isEqualToString:shortcut] &&
                (item.flags & MacWSMenuNodeEnabled) &&
                !(item.flags & (MacWSMenuNodeHidden |
                                MacWSMenuNodeHasSubmenu |
                                MacWSMenuNodeRequiresWorkspace))) {
                match = item;
                break;
            }
        }
        if (!match) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=item-not-found",
                     shortcut);
            return;
        }
        MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ owner=%d window=%u",
                 shortcut, match.title, snapshot.ownerPID,
                 snapshot.windowID);
        [self activateCurrentMacWindow];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      120 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self->_menuClient performItem:match inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ "
                             "status=%u error=%@", shortcut, match.title,
                             (unsigned)status,
                             actionError.localizedDescription ?: @"none");
                }];
        });
    }];
}

- (void)dismissSemanticMenu {
    [_semanticMenuDismissLayer removeFromSuperview];
    _semanticMenuDismissLayer = nil;
    if (!_semanticMenuPanel) return;
    [_semanticMenuPanel willMoveToParentViewController:nil];
    [_semanticMenuPanel.view removeFromSuperview];
    [_semanticMenuPanel removeFromParentViewController];
    _semanticMenuPanel = nil;
}

- (void)presentSemanticMenuForParent:(uint64_t)parentID
                             snapshot:(MacWSMenuSnapshot *)snapshot
                               source:(UIView *)source
                                title:(NSString *)title {
    NSMutableArray<MacWSMenuItem *> *items = [NSMutableArray array];
    for (MacWSMenuItem *item in [snapshot childrenOfItemID:parentID]) {
        if ((item.flags & MacWSMenuNodeHidden) == 0) [items addObject:item];
    }
    if (items.count == 0) {
        [self setNotice:[NSString stringWithFormat:@"“%@”菜单当前没有可见项目。",
            title.length ? title : @"macOS"] success:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    MacWSCompactMenuController *panel = [[MacWSCompactMenuController alloc]
        initWithItems:items appearance:snapshot.appearance
        selection:^(MacWSMenuItem *item) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self dismissSemanticMenu];
            if (item.flags & MacWSMenuNodeRequiresWorkspace) {
                [self setNotice:@"此菜单项包含 macOS 自定义视图，请在全屏工作区中使用。"
                         success:NO];
                return;
            }
            if (item.flags & MacWSMenuNodeHasSubmenu) {
                [self presentSemanticMenuForParent:item.itemID
                                          snapshot:snapshot source:source
                                             title:item.title];
                return;
            }
            // The iOS menu is outside AppKit, so selecting it does not itself
            // focus the represented NSWindow.  Send the same control-plane
            // activation as a real click and let AppKit finish its documented
            // activation transaction before routing a First Responder action.
            // Unlike the old bridge-side makeKeyAndOrderFront:, this happens
            // only for explicit user intent and never during passive refresh.
            [self activateCurrentMacWindow];
            uint32_t selectedWindowID = snapshot.windowID;
            int32_t selectedOwnerPID = snapshot.ownerPID;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          120 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_windowID != selectedWindowID ||
                    self->_windowOwnerPID != selectedOwnerPID) {
                    [self setNotice:@"窗口已经切换，请重新选择菜单项" success:NO];
                    return;
                }
                [self->_menuClient performItem:item inSnapshot:snapshot
                    completion:^(MacWSMenuStatus status, NSError *error) {
                        if (status == MacWSMenuStatusOK) {
                            [self setNotice:[NSString stringWithFormat:
                                @"已发送“%@”", item.title] success:YES];
                        } else {
                            [self setNotice:error.localizedDescription ?:
                                @"菜单项无法执行" success:NO];
                            [self refreshSemanticMenuWithCompletion:nil];
                        }
                    }];
            });
        }];
    [self dismissSemanticMenu];
    [self.view layoutIfNeeded];
    CGRect sourceRect = [source convertRect:source.bounds toView:self.view];
    CGRect safeBounds = UIEdgeInsetsInsetRect(self.view.bounds,
                                               self.view.safeAreaInsets);
    CGSize preferred = panel.preferredContentSize;
    CGFloat width = MIN(preferred.width, MAX(120.0, safeBounds.size.width));
    CGFloat height = MIN(preferred.height,
                         MAX(80.0, safeBounds.size.height - 4.0));
    CGFloat x = MIN(MAX(CGRectGetMinX(sourceRect), CGRectGetMinX(safeBounds)),
        MAX(CGRectGetMinX(safeBounds), CGRectGetMaxX(safeBounds) - width));
    CGFloat y = CGRectGetMaxY(sourceRect) + 1.0;
    if (y + height > CGRectGetMaxY(safeBounds))
        y = MAX(CGRectGetMinY(safeBounds),
                CGRectGetMinY(sourceRect) - height - 1.0);

    UIControl *dismissLayer = [[UIControl alloc] initWithFrame:self.view.bounds];
    dismissLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
    dismissLayer.backgroundColor = UIColor.clearColor;
    [dismissLayer addTarget:self action:@selector(dismissSemanticMenu)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dismissLayer];
    _semanticMenuDismissLayer = dismissLayer;

    [self addChildViewController:panel];
    panel.view.frame = CGRectMake(x, y, width, height);
    panel.view.backgroundColor = UIColor.secondarySystemBackgroundColor;
    panel.view.layer.cornerRadius = 8.0;
    panel.view.layer.borderWidth = 0.5;
    panel.view.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    panel.view.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.view.layer.shadowOpacity = 0.25;
    panel.view.layer.shadowRadius = 10;
    panel.view.layer.shadowOffset = CGSizeMake(0, 4);
    [self.view addSubview:panel.view];
    [panel didMoveToParentViewController:self];
    _semanticMenuPanel = panel;
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"menu-present parent=%llu source=(%.1f,%.1f %.1fx%.1f) panel=(%.1f,%.1f %.1fx%.1f)",
                 parentID, sourceRect.origin.x, sourceRect.origin.y,
                 sourceRect.size.width, sourceRect.size.height,
                 x, y, width, height);
    }
}

- (void)semanticMenuTitleTapped:(UIButton *)sender {
    uint32_t siblingIndex = UINT32_MAX;
    if (sender.tag >= 0) {
        MacWSMenuItem *old = [_menuSnapshot itemWithID:(uint64_t)sender.tag];
        siblingIndex = old.siblingIndex;
    }
    sender.enabled = NO;
    [self activateCurrentMacWindow];
    [self refreshSemanticMenuWithCompletion:^(MacWSMenuSnapshot *snapshot,
                                               NSError *error) {
        sender.enabled = YES;
        if (error || !snapshot) {
            [self setNotice:error.localizedDescription ?: @"菜单暂不可用"
                     success:NO];
            return;
        }
        uint64_t parentID = 0;
        NSString *title = @"macOS 菜单";
        if (siblingIndex != UINT32_MAX) {
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == siblingIndex) {
                    parentID = root.itemID;
                    title = root.title;
                    break;
                }
            }
        }
        [self presentSemanticMenuForParent:parentID snapshot:snapshot
                                    source:sender title:title];
    }];
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.blackColor;
    self.view = root;

    _metalView = [[MacWSMetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.statusDelegate = self;
    _metalView.sceneID = ((uint64_t)_sceneIdentifier.hash) &
        ~MACWS_INPUT_WINDOW_SCENE_FLAG;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.targetWindowResizable = _windowResizable;
    MacWSHostDisplayDensity savedDensity = (MacWSHostDisplayDensity)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSDisplayDensity"];
    if (savedDensity != MacWSHostDisplayDensityTouchComfort &&
        savedDensity != MacWSHostDisplayDensityKeyboard &&
        savedDensity != MacWSHostDisplayDensityComfort)
        savedDensity = MacWSHostDisplayDensityTouchComfort;
    // The first comfort-mode experiment migrated exact pixel matching to a
    // 10% host-side upsample. That makes controls larger, but it cannot retain
    // one-source-pixel-to-one-drawable-pixel sharpness. Restore the exact mode
    // once for existing installations; Comfort remains an explicit choice.
    if (![NSUserDefaults.standardUserDefaults
            boolForKey:@"MacWSDensityPixelMatchMigrationV2"]) {
        if (savedDensity == MacWSHostDisplayDensityComfort)
            savedDensity = MacWSHostDisplayDensityTouchComfort;
        [NSUserDefaults.standardUserDefaults setBool:YES
            forKey:@"MacWSDensityPixelMatchMigrationV2"];
        [NSUserDefaults.standardUserDefaults setInteger:savedDensity
            forKey:@"MacWSDisplayDensity"];
    }
    _metalView.displayDensity = savedDensity;
    CGFloat savedZoomScale =
        [NSUserDefaults.standardUserDefaults doubleForKey:@"MacWSFixedZoomScale"];
    _metalView.fixedZoomScale = savedZoomScale >= 1.75 ? 2.0 : 1.5;
    // Scene restoration constructs background controllers too.  Record the
    // target here, but defer the actual DisplayStream subscription until the
    // Scene enters the foreground so dormant Scenes cannot consume leases.
    _metalView.targetWindowID = _streamMode == MacWSStreamModeWindow ? _windowID : 0;
    _metalView.targetPID = _windowOwnerPID;
    [root addSubview:_metalView];

    // The iPadOS Scene exists before its default Terminal window is launched.
    // Keep a native menu bar during that short bootstrap interval too, so an
    // empty DisplayStream never presents as an unexplained black workspace
    // with a detached control button in the upper-left corner.
    _semanticMenuBar = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        _semanticMenuBar.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuBar.clipsToBounds = YES;
        _semanticMenuBar.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        _semanticMenuScroll = [UIScrollView new];
        _semanticMenuScroll.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuScroll.showsHorizontalScrollIndicator = NO;
        _semanticMenuTitles = [UIStackView new];
        _semanticMenuTitles.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuTitles.axis = UILayoutConstraintAxisHorizontal;
        _semanticMenuTitles.alignment = UIStackViewAlignmentFill;
        _semanticMenuTitles.spacing = 0;
        [_semanticMenuScroll addSubview:_semanticMenuTitles];
        [_semanticMenuBar.contentView addSubview:_semanticMenuScroll];
        UIView *menuSeparator = [UIView new];
        menuSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        menuSeparator.backgroundColor = [UIColor.separatorColor
            colorWithAlphaComponent:0.58];
        [_semanticMenuBar.contentView addSubview:menuSeparator];
        [root addSubview:_semanticMenuBar];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuScroll.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor constant:4],
            [_semanticMenuScroll.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor constant:-40],
            [_semanticMenuScroll.topAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.topAnchor],
            [_semanticMenuScroll.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [_semanticMenuTitles.leadingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.leadingAnchor],
            [_semanticMenuTitles.trailingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.trailingAnchor],
            [_semanticMenuTitles.topAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.topAnchor],
            [_semanticMenuTitles.bottomAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.bottomAnchor],
            [_semanticMenuTitles.heightAnchor constraintEqualToAnchor:
                _semanticMenuScroll.frameLayoutGuide.heightAnchor],
            [menuSeparator.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor],
            [menuSeparator.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor],
            [menuSeparator.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [menuSeparator.heightAnchor constraintEqualToConstant:0.5],
        ]];
    [self renderSemanticMenuTitles];

    _keyboardProxy = [UITextField new];
    _keyboardProxy.translatesAutoresizingMaskIntoConstraints = NO;
    _keyboardProxy.delegate = self;
    _keyboardProxy.text = @" ";
    _keyboardProxy.autocorrectionType = UITextAutocorrectionTypeNo;
    _keyboardProxy.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyboardProxy.smartDashesType = UITextSmartDashesTypeNo;
    _keyboardProxy.smartQuotesType = UITextSmartQuotesTypeNo;
    _keyboardProxy.spellCheckingType = UITextSpellCheckingTypeNo;
    _keyboardProxy.alpha = 0.01;
    [root addSubview:_keyboardProxy];
    // The modifier row belongs to the MacWS window layout, not to the floating
    // iPad keyboard. Giving it an explicit 52-point region prevents it from
    // covering macOS pixels while leaving the movable software keyboard free
    // to overlap wherever the user places it.
    _softwareKeyBar = [self makeKeyboardAccessoryView];
    _softwareKeyBar.translatesAutoresizingMaskIntoConstraints = NO;
    _softwareKeyBar.hidden = YES;
    [root addSubview:_softwareKeyBar];
    _softwareKeyBarHeightConstraint = [_softwareKeyBar.heightAnchor
        constraintEqualToConstant:0];

    _controlDismissLayer = [UIControl new];
    _controlDismissLayer.translatesAutoresizingMaskIntoConstraints = NO;
    _controlDismissLayer.backgroundColor = UIColor.clearColor;
    _controlDismissLayer.hidden = YES;
    [_controlDismissLayer addTarget:self action:@selector(hideControls)
                   forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_controlDismissLayer];

    // The expanded card must be a stable reading surface. The former fixed
    // dark blur was composited with adaptive light/dark labels and fills,
    // which produced incorrect translucency and contrast. Keep blur only for
    // the small floating affordance; the card itself follows one opaque
    // semantic color system.
    _controlPanel = [[UIVisualEffectView alloc] initWithEffect:nil];
    _controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlPanel.layer.cornerRadius = 22;
    _controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _controlPanel.clipsToBounds = YES;
    _controlPanel.contentView.backgroundColor = UIColor.systemBackgroundColor;
    [root addSubview:_controlPanel];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [_controlPanel.contentView addSubview:scroll];

    UILabel *title = MacWSMakeLabel(@"MacWS 控制中心",
        [UIFont systemFontOfSize:23 weight:UIFontWeightBold], UIColor.labelColor);
    UILabel *subtitle = MacWSMakeLabel(@"iPadOS 原生窗口 · macOS AGX 工作区",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);
    UIStackView *titleLabels = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titleLabels.axis = UILayoutConstraintAxisVertical;
    titleLabels.spacing = 1;

    UIButton *hide = [self buttonWithTitle:@"" image:@"sidebar.left"
                                    action:@selector(hideControls) prominent:NO];
    UIButtonConfiguration *hideConfiguration = [hide.configuration copy];
    hideConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
    hide.configuration = hideConfiguration;
    [hide.widthAnchor constraintEqualToConstant:52].active = YES;
    [hide setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
    [hide setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabels, hide]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;

    _serviceLabel = MacWSMakeLabel(@"正在连接 root 控制服务…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.systemOrangeColor);
    _phaseLabel = MacWSMakeLabel(@"打开 App 后会自动检查重启恢复状态",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);

    UIStackView *serviceCard = [[UIStackView alloc]
        initWithArrangedSubviews:@[_serviceLabel, _phaseLabel]];
    serviceCard.axis = UILayoutConstraintAxisVertical;
    serviceCard.spacing = 5;
    serviceCard.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    serviceCard.layoutMarginsRelativeArrangement = YES;
    serviceCard.backgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.48];
    serviceCard.layer.cornerRadius = 12;

    UIStackView *statusRows = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self statusRowWithTitle:@"macOS RootFS" value:&_rootfsLabel],
        [self divider],
        [self statusRowWithTitle:@"WindowServer" value:&_windowServerLabel],
        [self divider],
        [self statusRowWithTitle:@"触控桥" value:&_bridgeLabel],
        [self divider],
        [self statusRowWithTitle:@"共享帧" value:&_frameLabel],
    ]];
    statusRows.axis = UILayoutConstraintAxisVertical;
    statusRows.spacing = 8;
    statusRows.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    statusRows.layoutMarginsRelativeArrangement = YES;
    statusRows.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.42];
    statusRows.layer.cornerRadius = 12;

    _primaryButton = [self buttonWithTitle:@"初始化并启动" image:@"play.fill"
                                    action:@selector(primaryAction) prominent:YES];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;

    UILabel *experimentalText = MacWSMakeLabel(@"实验兼容模式",
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.labelColor);
    UILabel *experimentalDetail = MacWSMakeLabel(
        @"启用命令 ABI / completion 诊断脚手架；受 5 分钟与高 CPU 热保护，不是根因修复。",
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
        UIColor.systemOrangeColor);
    UIStackView *experimentalLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[experimentalText, experimentalDetail]];
    experimentalLabels.axis = UILayoutConstraintAxisVertical;
    experimentalLabels.spacing = 2;
    _experimentalSwitch = [UISwitch new];
    _experimentalSwitch.on = [NSUserDefaults.standardUserDefaults
        boolForKey:@"MacWSExperimentalMode"];
    [_experimentalSwitch addTarget:self action:@selector(experimentalChanged:)
                  forControlEvents:UIControlEventValueChanged];
    UIStackView *experimentalRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[experimentalLabels, _experimentalSwitch]];
    experimentalRow.axis = UILayoutConstraintAxisHorizontal;
    experimentalRow.alignment = UIStackViewAlignmentCenter;
    experimentalRow.spacing = 10;

    UIButton *glassDemo = [self buttonWithTitle:@"GlassDemo" image:@"sparkles.rectangle.stack"
                                         action:@selector(launchApplication:) prominent:NO];
    glassDemo.accessibilityIdentifier = @"glassdemo";
    UIButton *terminal = [self buttonWithTitle:@"终端" image:@"terminal"
                                        action:@selector(launchApplication:) prominent:NO];
    terminal.accessibilityIdentifier = @"terminal";
    UIButton *activity = [self buttonWithTitle:@"活动监视器" image:@"waveform.path.ecg.rectangle"
                                        action:@selector(launchApplication:) prominent:NO];
    activity.accessibilityIdentifier = @"activity-monitor";
    UIButton *finder = [self buttonWithTitle:@"Finder" image:@"folder"
                                      action:@selector(launchApplication:) prominent:NO];
    finder.accessibilityIdentifier = @"finder";
    UIButton *vscode = [self buttonWithTitle:@"VS Code" image:@"chevron.left.forwardslash.chevron.right"
                                      action:@selector(launchApplication:) prominent:NO];
    vscode.accessibilityIdentifier = @"vscode";
    UIButton *settings = [self buttonWithTitle:@"系统设置" image:@"gearshape"
                                        action:@selector(launchApplication:) prominent:NO];
    settings.accessibilityIdentifier = @"system-settings";
    UIButton *maps = [self buttonWithTitle:@"地图" image:@"map"
                                    action:@selector(launchApplication:) prominent:NO];
    maps.accessibilityIdentifier = @"maps";
    _applicationButtons = @[
        glassDemo, terminal, activity, finder, vscode, settings, maps,
    ];
    UIStackView *appRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[glassDemo, terminal]];
    UIStackView *appRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[activity, finder]];
    UIStackView *appRow3 = [[UIStackView alloc] initWithArrangedSubviews:@[vscode, settings]];
    UIStackView *appRow4 = [[UIStackView alloc] initWithArrangedSubviews:@[maps]];
    for (UIStackView *row in @[appRow1, appRow2, appRow3, appRow4]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _appSearchField = [UITextField new];
    _appSearchField.delegate = self;
    _appSearchField.placeholder = @"搜索应用或输入 macOS 绝对路径";
    _appSearchField.returnKeyType = UIReturnKeyGo;
    _appSearchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _appSearchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _appSearchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _appSearchField.backgroundColor = [UIColor.secondarySystemFillColor
        colorWithAlphaComponent:0.52];
    _appSearchField.layer.cornerRadius = 11;
    _appSearchField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _appSearchField.leftViewMode = UITextFieldViewModeAlways;
    [_appSearchField.heightAnchor constraintEqualToConstant:44].active = YES;

    _keyboardButton = [self buttonWithTitle:@"打开虚拟键盘"
                                     image:@"keyboard"
                                    action:@selector(keyboardAction)
                                 prominent:NO];

    _captureButton = [self buttonWithTitle:@"刷新画面" image:@"camera.viewfinder"
                                    action:@selector(captureAction) prominent:NO];
    _repairButton = [self buttonWithTitle:@"修复环境" image:@"wrench.and.screwdriver"
                                   action:@selector(repairAction) prominent:NO];
    _recoverButton = [self buttonWithTitle:@"安全恢复" image:@"lifepreserver"
                                    action:@selector(recoverAction) prominent:NO];
    _logsButton = [self buttonWithTitle:@"查看日志" image:@"doc.text.magnifyingglass"
                                 action:@selector(logsAction) prominent:NO];
    _exportButton = [self buttonWithTitle:@"导出诊断" image:@"square.and.arrow.up"
                                   action:@selector(exportDiagnostics) prominent:NO];
    _windowPickerButton = [self buttonWithTitle:@"打开 macOS 窗口"
                                          image:@"macwindow.on.rectangle"
                                         action:@selector(openWindowPicker)
                                      prominent:NO];
    _closeWindowButton = [self buttonWithTitle:@"关闭此 macOS 窗口"
                                         image:@"xmark.square"
                                        action:@selector(closeCurrentWindow)
                                     prominent:NO];
    _closeWindowButton.hidden = _windowID == 0;
    _menuBarButton = [self buttonWithTitle:@"打开全屏 macOS 工作区"
                                     image:@"arrow.up.left.and.arrow.down.right"
                                    action:@selector(openFullscreenWorkspace)
                                 prominent:NO];
    _clipboardButton = [self buttonWithTitle:@"同步剪贴板到 macOS"
                                       image:@"doc.on.clipboard"
                                      action:@selector(syncClipboardAction)
                                   prominent:NO];
    _importButton = [self buttonWithTitle:@"导入文件到 macOS"
                                    image:@"square.and.arrow.down.on.square"
                                   action:@selector(importFilesAction)
                                prominent:NO];
    _macFilesButton = [self buttonWithTitle:@"macOS 文件"
                                      image:@"arrow.up.doc"
                                     action:@selector(shareMacOSFiles)
                                  prominent:NO];
    _macFilesButton.enabled = NO;
    UIStackView *interopRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[_clipboardButton, _importButton]];
    interopRow.axis = UILayoutConstraintAxisHorizontal;
    interopRow.distribution = UIStackViewDistributionFillEqually;
    interopRow.spacing = 8;
    [_macFilesButton addInteraction:[[UIDragInteraction alloc]
        initWithDelegate:self]];
    [_metalView addInteraction:[[UIDropInteraction alloc]
        initWithDelegate:self]];
    UIStackView *toolRow1 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_captureButton, _repairButton]];
    UIStackView *toolRow2 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_recoverButton, _logsButton]];
    for (UIStackView *row in @[toolRow1, toolRow2]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _statusLabel = [UILabel new];
    _statusLabel.text = @"画面：正在连接 WindowServer 共享帧…";
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 0;

    _inputLabel = [UILabel new];
    _inputLabel.text = @"触控：等待桥接服务";
    _inputLabel.textColor = UIColor.systemCyanColor;
    _inputLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _inputLabel.numberOfLines = 0;

    _interopLabel = [UILabel new];
    _interopLabel.text = @"互操作：等待 macOS 剪贴板与文件桥";
    _interopLabel.textColor = UIColor.systemIndigoColor;
    _interopLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                     weight:UIFontWeightRegular];
    _interopLabel.numberOfLines = 0;

    _inputModeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"直接触控", @"精确触控板"]];
    MacWSHostInputMode savedInputMode = (MacWSHostInputMode)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSInputMode"];
    if (savedInputMode != MacWSHostInputModeTrackpad)
        savedInputMode = MacWSHostInputModeDirect;
    _inputModeControl.selectedSegmentIndex =
        savedInputMode == MacWSHostInputModeTrackpad ? 1 : 0;
    _metalView.inputMode = savedInputMode;
    [_inputModeControl addTarget:self action:@selector(inputModeChanged:)
                forControlEvents:UIControlEventValueChanged];

    _densityControl = [[UISegmentedControl alloc]
        initWithItems:@[@"像素匹配", @"放大 +10%", @"更多空间 +18%"]];
    _densityControl.selectedSegmentIndex =
        _metalView.displayDensity == MacWSHostDisplayDensityKeyboard ? 2 :
        (_metalView.displayDensity == MacWSHostDisplayDensityComfort ? 1 : 0);
    [_densityControl addTarget:self action:@selector(densityChanged:)
               forControlEvents:UIControlEventValueChanged];
    _zoomScaleControl = [[UISegmentedControl alloc]
        initWithItems:@[@"双指双击 1.5×", @"双指双击 2.0×"]];
    _zoomScaleControl.selectedSegmentIndex =
        _metalView.fixedZoomScale >= 1.75 ? 1 : 0;
    [_zoomScaleControl addTarget:self action:@selector(zoomScaleChanged:)
                 forControlEvents:UIControlEventValueChanged];
    _resetZoomButton = [self buttonWithTitle:@"退出放大视角"
        image:@"arrow.counterclockwise"
        action:@selector(resetZoomAction) prominent:NO];

    _noticeLabel = MacWSMakeLabel(@"",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.systemCyanColor);
    _noticeLabel.hidden = YES;

    _logsView = [UITextView new];
    _logsView.editable = NO;
    _logsView.selectable = YES;
    _logsView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.35];
    _logsView.textColor = UIColor.systemGreenColor;
    _logsView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logsView.layer.cornerRadius = 10;
    _logsView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _logsView.hidden = YES;
    [_logsView.heightAnchor constraintEqualToConstant:220].active = YES;

    // Interaction choices are the first controls a user needs. Detailed
    // subsystem rows and recovery/debug tools stay out of the production UI;
    // a compact readiness summary remains at the bottom.
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        [self sectionTitle:@"触摸方式"],
        _inputModeControl,
        [self sectionTitle:@"显示密度"],
        _densityControl,
        _keyboardButton,
        _primaryButton,
        [self sectionTitle:@"macOS 应用"],
        _appSearchField,
        appRow1,
        appRow2,
        appRow3,
        appRow4,
        _windowPickerButton,
        _menuBarButton,
        _closeWindowButton,
        [self sectionTitle:@"iOS / macOS 互操作"],
        interopRow,
        _macFilesButton,
        [self sectionTitle:@"放大视角"],
        _zoomScaleControl,
        _resetZoomButton,
        _noticeLabel,
        [self divider],
        serviceCard,
        _statusLabel,
        _inputLabel,
        _interopLabel,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    content.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:content];

    _showControlsMaterial = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _showControlsMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    _showControlsMaterial.layer.cornerRadius = 15;
    _showControlsMaterial.layer.cornerCurve = kCACornerCurveContinuous;
    _showControlsMaterial.layer.borderWidth = 0.5;
    _showControlsMaterial.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.55].CGColor;
    _showControlsMaterial.clipsToBounds = YES;
    [root addSubview:_showControlsMaterial];

    _showControlsButton = [self buttonWithTitle:@"控制中心" image:@"sidebar.left"
                                         action:@selector(showControls) prominent:NO];
    _showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration plainButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"switch.2"];
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(3, 5, 3, 5);
    _showControlsButton.configuration = configuration;
    _showControlsButton.accessibilityLabel = @"MacWS 控制中心";
    [_showControlsMaterial.contentView addSubview:_showControlsButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *responsiveWidth = [_controlPanel.widthAnchor
        constraintEqualToAnchor:safe.widthAnchor multiplier:0.92];
    responsiveWidth.priority = 999;
    NSLayoutYAxisAnchor *metalTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : root.topAnchor;
    NSLayoutYAxisAnchor *controlTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : safe.topAnchor;
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:metalTop],
        [_metalView.bottomAnchor constraintEqualToAnchor:_softwareKeyBar.topAnchor],
        [_softwareKeyBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_softwareKeyBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_softwareKeyBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _softwareKeyBarHeightConstraint,
        [_keyboardProxy.widthAnchor constraintEqualToConstant:1],
        [_keyboardProxy.heightAnchor constraintEqualToConstant:1],
        [_keyboardProxy.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_keyboardProxy.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlDismissLayer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_controlDismissLayer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_controlDismissLayer.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_controlDismissLayer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_controlPanel.topAnchor constraintEqualToAnchor:controlTop constant:12],
        [_controlPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_controlPanel.widthAnchor constraintLessThanOrEqualToConstant:420],
        responsiveWidth,
        [scroll.leadingAnchor constraintEqualToAnchor:_controlPanel.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_controlPanel.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_controlPanel.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_controlPanel.contentView.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [_showControlsMaterial.trailingAnchor constraintEqualToAnchor:
            safe.trailingAnchor constant:-6],
        [_showControlsMaterial.topAnchor constraintEqualToAnchor:
            safe.topAnchor constant:2],
        [_showControlsMaterial.widthAnchor constraintEqualToConstant:38],
        [_showControlsMaterial.heightAnchor constraintEqualToConstant:30],
        [_showControlsButton.leadingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.leadingAnchor],
        [_showControlsButton.trailingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.trailingAnchor],
        [_showControlsButton.topAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.topAnchor],
        [_showControlsButton.bottomAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.bottomAnchor],
    ]];
    if (_semanticMenuBar) {
        _semanticMenuHeightConstraint = [_semanticMenuBar.heightAnchor
            constraintEqualToConstant:26];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [_semanticMenuBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [_semanticMenuBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
            _semanticMenuHeightConstraint,
        ]];
        // A native macOS window should open as content, not as a settings
        // sheet. Keep the compact menu visible and expose Control Center as a
        // small explicit affordance; fullscreen/bootstrap scenes still open
        // with controls shown.
        _controlPanel.hidden = YES;
        _showControlsMaterial.hidden = NO;
    }
    [self updateWorkspaceChrome];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UISceneActivationState activation = self.view.window.windowScene.activationState;
    if (activation != UISceneActivationStateBackground &&
        activation != UISceneActivationStateUnattached &&
        !(_bootstrapTerminalPending && _windowID == 0)) {
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    }
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
        selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self dismissSemanticMenu];
    [_metalView geometryDidChange];
    [coordinator animateAlongsideTransition:nil completion:^(
        id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        [self sceneGeometryDidChange];
    }];
}

- (void)sceneGeometryDidChange {
    // UIWindowScene reports Stage Manager resizing as coordinate-space
    // updates, while ordinary split/full-screen transitions arrive through
    // view-controller layout.  Converge both on one transform/configuration
    // boundary so input and pixels never use different generations.
    [self dismissSemanticMenu];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [_metalView geometryDidChange];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)hideControls {
    _controlPanel.hidden = YES;
    _controlDismissLayer.hidden = YES;
    _showControlsMaterial.hidden = NO;
}

- (void)showControls {
    _controlDismissLayer.hidden = NO;
    _controlPanel.hidden = NO;
    _showControlsMaterial.hidden = YES;
}

- (void)setNotice:(NSString *)notice success:(BOOL)success {
    _noticeLabel.hidden = notice.length == 0;
    _noticeLabel.text = notice;
    _noticeLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
}

- (void)setControlsEnabled:(BOOL)enabled {
    _primaryButton.enabled = enabled;
    _repairButton.enabled = enabled;
    _recoverButton.enabled = enabled;
    _captureButton.enabled = enabled;
    _exportButton.enabled = enabled;
    _windowPickerButton.enabled = enabled;
    _closeWindowButton.enabled = enabled && _windowID != 0;
    _menuBarButton.enabled = enabled;
    _clipboardButton.enabled = enabled;
    _importButton.enabled = enabled;
    _macFilesButton.enabled = _receivedMacOSFiles.count > 0;
    _experimentalSwitch.enabled = enabled;
    _inputModeControl.enabled = enabled;
    _densityControl.enabled = enabled;
    _zoomScaleControl.enabled = enabled;
    _resetZoomButton.enabled = enabled;
    for (UIButton *button in _applicationButtons) button.enabled = enabled;
}

- (void)closeCurrentWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        [self setNotice:@"当前是工作区，不对应单独的 macOS 窗口。" success:NO];
        return;
    }
    UISceneSession *session = self.view.window.windowScene.session;
    if (!session) return;
    MacWSRememberSceneBinding(session, [self streamRestorationActivity]);
    if (!MacWSCloseMacWindowForSceneSession(session, @"control-center")) {
        [self setNotice:@"关闭请求发送失败；macOS 窗口保持打开。" success:NO];
        return;
    }
    [UIApplication.sharedApplication
        requestSceneSessionDestruction:session
                              options:nil
                         errorHandler:^(NSError *error) {
        [self setNotice:[NSString stringWithFormat:
            @"macOS 窗口已请求关闭，但 iPadOS 场景未能移除：%@",
            error.localizedDescription ?: @"未知错误"] success:NO];
    }];
}

- (void)keyboardAction {
    if (_keyboardProxy.isFirstResponder) {
        [_keyboardProxy resignFirstResponder];
        [self setButton:_keyboardButton title:@"打开虚拟键盘"
                   image:@"keyboard"];
    } else {
        _keyboardProxy.text = @" ";
        if ([_keyboardProxy becomeFirstResponder]) {
            _metalView.softwareKeyboardActive = YES;
            [self setButton:_keyboardButton title:@"收起虚拟键盘"
                       image:@"keyboard.chevron.compact.down"];
        }
    }
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    _metalView.softwareKeyboardActive = YES;
    _softwareKeyBar.hidden = NO;
    _softwareKeyBarHeightConstraint.constant = 52;
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    }];
    [self setButton:_keyboardButton title:@"收起虚拟键盘"
               image:@"keyboard.chevron.compact.down"];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    _metalView.softwareKeyboardActive = NO;
    _softwareKeyBarHeightConstraint.constant = 0;
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        self->_softwareKeyBar.hidden = YES;
    }];
    [self setButton:_keyboardButton title:@"打开虚拟键盘"
               image:@"keyboard"];
    [_metalView becomeFirstResponder];
}

- (void)softModifierTapped:(UIButton *)sender {
    uint32_t mask = (uint32_t)sender.tag;
    _softModifiers ^= mask;
    sender.selected = (_softModifiers & mask) != 0;
    UIButtonConfiguration *configuration = sender.selected
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = sender.configuration.title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    sender.configuration = configuration;
}

- (void)softKeyTapped:(UIButton *)sender {
    if ([sender.accessibilityIdentifier isEqualToString:@"dismiss-keyboard"]) {
        [self keyboardAction];
        return;
    }
    [_metalView emitSoftwareKeySym:(uint32_t)sender.tag
                         modifiers:_softModifiers];
}

- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)string {
    (void)range;
    if (textField != _keyboardProxy) return YES;
    if (string.length == 0)
        [_metalView emitSoftwareKeySym:0xff08 modifiers:_softModifiers];
    else
        [_metalView emitSoftwareText:string modifiers:_softModifiers];
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _keyboardProxy) {
        [_metalView emitSoftwareKeySym:0xff0d modifiers:_softModifiers];
        return NO;
    }
    if (textField != _appSearchField) return YES;
    NSString *query = [textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return NO;
    NSString *lower = query.lowercaseString;
    NSString *identifier = nil;
    if ([lower containsString:@"visual studio"] ||
        [lower containsString:@"vscode"] || [lower isEqualToString:@"code"])
        identifier = @"vscode";
    else if ([lower containsString:@"terminal"] ||
             [query containsString:@"终端"])
        identifier = @"terminal";
    else if ([lower containsString:@"glass"])
        identifier = @"glassdemo";
    else if ([lower containsString:@"activity"] ||
             [query containsString:@"活动"])
        identifier = @"activity-monitor";
    else if ([lower containsString:@"finder"])
        identifier = @"finder";
    [textField resignFirstResponder];
    if (identifier) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier}];
    } else if ([query hasPrefix:@"/"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_PATH
                 arguments:@{@MACWS_CONTROL_KEY_APP_PATH: query}];
    } else {
        [self setNotice:@"未找到应用；可输入 VS Code、Terminal、Finder，或 / 开头的 macOS 绝对路径。"
                 success:NO];
    }
    return NO;
}

- (void)inputModeChanged:(UISegmentedControl *)sender {
    MacWSHostInputMode mode = sender.selectedSegmentIndex == 1
        ? MacWSHostInputModeTrackpad : MacWSHostInputModeDirect;
    _metalView.inputMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"MacWSInputMode"];
    _inputLabel.text = mode == MacWSHostInputModeTrackpad
        ? @"输入：单指移动圆形指针，轻点单击，长按拖动，双指滚动/右击"
        : @"输入：轻点单击、单指滑动滚动；长按后滑动拖动，长按释放右击";
}

- (void)densityChanged:(UISegmentedControl *)sender {
    MacWSHostDisplayDensity density = sender.selectedSegmentIndex == 2
        ? MacWSHostDisplayDensityKeyboard
        : (sender.selectedSegmentIndex == 1
            ? MacWSHostDisplayDensityComfort
            : MacWSHostDisplayDensityTouchComfort);
    _metalView.displayDensity = density;
    [NSUserDefaults.standardUserDefaults setInteger:density
                                              forKey:@"MacWSDisplayDensity"];
    if (density == MacWSHostDisplayDensityKeyboard) {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：更多空间；当前有效密度 %.0f%%，画布比像素匹配模式多约 18%%",
            _metalView.effectiveDensityScale * 100.0];
    } else if (density == MacWSHostDisplayDensityComfort) {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：放大 +10%%；有效密度 %.0f%%，使用 Metal 高质量重采样；如需逐像素锐利请切换像素匹配",
            _metalView.effectiveDensityScale * 100.0];
    } else {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：像素匹配 Retina；当前有效密度 %.0f%%（随 iPadOS 合成比例自动调整）",
            _metalView.effectiveDensityScale * 100.0];
    }
}

- (void)zoomScaleChanged:(UISegmentedControl *)sender {
    CGFloat scale = sender.selectedSegmentIndex == 1 ? 2.0 : 1.5;
    _metalView.fixedZoomScale = scale;
    [NSUserDefaults.standardUserDefaults setDouble:scale
                                             forKey:@"MacWSFixedZoomScale"];
    [self setNotice:[NSString stringWithFormat:
        @"双指双击放大倍率已设为 %.1f×", scale] success:YES];
}

- (void)resetZoomAction {
    [_metalView resetViewportZoom];
    [self setNotice:@"已退出放大视角并恢复中心位置" success:YES];
}

- (void)syncClipboardAction {
    [_interopClient publishGeneralPasteboard];
}

- (void)importFilesAction {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    [_interopClient stageAndPublishFiles:urls
        completion:^(NSArray<NSURL *> *stagedURLs, NSError *error) {
            [self setNotice:error ? error.localizedDescription :
                [NSString stringWithFormat:@"已导入 %lu 个文件；macOS 应用可直接粘贴。",
                 (unsigned long)stagedURLs.count]
                success:error == nil];
        }];
}

- (void)shareMacOSFiles {
    if (!_receivedMacOSFiles.count) {
        [self setNotice:@"macOS 剪贴板中还没有可导出的文件" success:NO];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:_receivedMacOSFiles applicationActivities:nil];
    activity.popoverPresentationController.sourceView = _macFilesButton;
    activity.popoverPresentationController.sourceRect = _macFilesButton.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)interopClient:(MacWSInteropClient *)client
        statusChanged:(NSString *)status
            connected:(BOOL)connected {
    (void)client;
    _interopLabel.text = [@"互操作：" stringByAppendingString:status];
    _interopLabel.textColor = connected ? UIColor.systemGreenColor
                                        : UIColor.systemOrangeColor;
}

- (void)interopClient:(MacWSInteropClient *)client
 receivedMacOSFilesAtURLs:(NSArray<NSURL *> *)urls {
    (void)client;
    _receivedMacOSFiles = [urls copy];
    _macFilesButton.enabled = urls.count > 0;
    [self setButton:_macFilesButton
              title:[NSString stringWithFormat:@"拖出/分享 macOS 文件 · %lu",
                     (unsigned long)urls.count]
              image:@"arrow.up.doc"];
}

- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction
                     itemsForBeginningSession:(id<UIDragSession>)session {
    (void)interaction;
    (void)session;
    NSMutableArray<UIDragItem *> *items = [NSMutableArray array];
    for (NSURL *url in _receivedMacOSFiles) {
        NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
        if (provider) [items addObject:[[UIDragItem alloc]
            initWithItemProvider:provider]];
    }
    return items;
}

- (BOOL)dropInteraction:(UIDropInteraction *)interaction
        canHandleSession:(id<UIDropSession>)session {
    (void)interaction;
    return [session hasItemsConformingToTypeIdentifiers:@[
        @"public.item", @"public.image", @"public.text"
    ]];
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction
                    sessionDidUpdate:(id<UIDropSession>)session {
    (void)interaction;
    (void)session;
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}

- (void)dropInteraction:(UIDropInteraction *)interaction
      performDrop:(id<UIDropSession>)session {
    (void)interaction;
    for (UIDragItem *dragItem in session.items) {
        NSItemProvider *provider = dragItem.itemProvider;
        if ([provider hasItemConformingToTypeIdentifier:@"public.item"]) {
            [provider loadFileRepresentationForTypeIdentifier:@"public.item"
                completionHandler:^(NSURL *url, NSError *error) {
                    if (!url || error) return;
                    NSString *cacheDirectory = [@"/var/mobile/Library/Caches/MacWSDrops"
                        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
                    [NSFileManager.defaultManager
                        createDirectoryAtPath:cacheDirectory
                  withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *name = url.lastPathComponent.length
                        ? url.lastPathComponent : @"Dropped Item";
                    NSURL *copy = [NSURL fileURLWithPath:
                        [cacheDirectory stringByAppendingPathComponent:name]];
                    NSError *copyError = nil;
                    if (![NSFileManager.defaultManager copyItemAtURL:url
                                                               toURL:copy
                                                               error:&copyError]) return;
                    [self->_interopClient stageAndPublishFiles:@[copy]
                        completion:^(NSArray<NSURL *> *staged, NSError *stageError) {
                            [self setNotice:stageError ? stageError.localizedDescription :
                                [NSString stringWithFormat:@"已拖入 %lu 个文件到 macOS",
                                 (unsigned long)staged.count]
                                success:stageError == nil];
                        }];
                }];
        } else if ([provider canLoadObjectOfClass:UIImage.class]) {
            [provider loadObjectOfClass:UIImage.class
                completionHandler:^(UIImage *image, NSError *error) {
                    if (!image || error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIPasteboard.generalPasteboard.image = image;
                        [self->_interopClient publishGeneralPasteboard];
                    });
                }];
        } else if ([provider canLoadObjectOfClass:NSString.class]) {
            [provider loadObjectOfClass:NSString.class
                completionHandler:^(NSString *text, NSError *error) {
                    if (!text || error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIPasteboard.generalPasteboard.string = text;
                        [self->_interopClient publishGeneralPasteboard];
                    });
                }];
        }
    }
}

- (NSArray<MacWSStreamWindow *> *)logicalWindowRepresentatives {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *representatives =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in _streamWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (!identity) continue;
        MacWSStreamWindow *current = representatives[identity];
        if (!current) {
            representatives[identity] = window;
            [order addObject:identity];
            continue;
        }
        MacWSStreamWindowFlags flags = descriptor.flags;
        MacWSStreamWindowFlags currentFlags = current.descriptor.flags;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((descriptor.windowID == _windowID) ? 1 : 0);
        NSUInteger currentScore =
            ((currentFlags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((currentFlags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((current.descriptor.windowID == _windowID) ? 1 : 0);
        if (score > currentScore) representatives[identity] = window;
    }
    NSMutableArray<MacWSStreamWindow *> *result = [NSMutableArray array];
    for (NSString *identity in order) {
        MacWSStreamWindow *window = representatives[identity];
        if (window) [result addObject:window];
    }
    return result;
}

- (void)openWindowPicker {
    [_metalView requestStreamWindowList];
    NSArray<MacWSStreamWindow *> *logicalWindows =
        [self logicalWindowRepresentatives];
    if (logicalWindows.count == 0) {
        [self setNotice:@"正在读取 macOS 窗口；DisplayStream 服务就绪后请再试一次。"
                 success:YES];
        return;
    }
    BOOL fullscreenWorkspace = [self isFullscreenWorkspace];
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:fullscreenWorkspace
            ? @"切换 macOS 窗口" : @"在新 iPadOS 窗口中打开"
                         message:fullscreenWorkspace
            ? @"所选窗口会留在当前全屏桌面中，不会创建新的 iPadOS 窗口。"
            : @"每个 Scene 只订阅一个 macOS 窗口的 IOSurface 流。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(logicalWindows.count, 24);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = logicalWindows[index];
        NSString *title = window.title.length ? window.title :
            [NSString stringWithFormat:@"Window %u", window.descriptor.windowID];
        [picker addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if ([self isFullscreenWorkspace]) {
                    [self activateMacWindow:window];
                    return;
                }
                MacWSRequestNewScene(self.view.window.windowScene,
                    window.descriptor.windowID, window.descriptor.ownerPID,
                    window.descriptor.logicalGroupID,
                    CGSizeMake(window.descriptor.logicalWidth,
                               window.descriptor.logicalHeight),
                    CGSizeMake(window.descriptor.minimumLogicalWidth,
                               window.descriptor.minimumLogicalHeight),
                    (window.descriptor.flags & MacWSStreamWindowResizable) != 0,
                    title, ^(NSError *error) {
                        if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                            error.code == 2) {
                            [self openWindowInCurrentScene:window
                                reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                        } else {
                            [self setNotice:error.localizedDescription success:NO];
                        }
                    });
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = _windowPickerButton;
    picker.popoverPresentationController.sourceRect = _windowPickerButton.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason {
    if (!window || window.descriptor.windowID == 0) return;
    [self openWindowIDInCurrentScene:window.descriptor.windowID
                            ownerPID:window.descriptor.ownerPID
                      logicalGroupID:window.descriptor.logicalGroupID
                               title:window.title
                              reason:reason];
    _windowMinimumSize = CGSizeMake(window.descriptor.minimumLogicalWidth,
                                    window.descriptor.minimumLogicalHeight);
    _windowPreferredSize = CGSizeMake(window.descriptor.logicalWidth,
                                      window.descriptor.logicalHeight);
    _windowResizable =
        (window.descriptor.flags & MacWSStreamWindowResizable) != 0;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.targetWindowResizable = _windowResizable;
    // openWindowIDInCurrentScene: establishes the stream before catalog
    // metadata is installed. Persist once more with the authoritative AppKit
    // size so a later FrontBoard reconnect can reproduce the same small
    // native Scene instead of falling back to a stock category.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
}

- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason {
    if (windowID == 0 || ownerPID <= 1) return;
    [_metalView suspendStream];
    // A Scene is reused across per-window and desktop presentation. A
    // double-tap zoom belongs to the old stream's coordinate space; carrying
    // it into the new stream crops the desktop and maps input into that stale
    // crop. Reset before installing the new stream identity.
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeWindow;
    _windowID = windowID;
    _windowOwnerPID = ownerPID;
    _windowGroupID = logicalGroupID;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _windowMinimumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    _metalView.targetPID = ownerPID;
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = title.length ? title :
        [NSString stringWithFormat:@"MacWS Window %u", windowID];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    if (_semanticMenuBar) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [self setNotice:reason.length ? reason : @"已在当前 iPadOS 窗口中打开 macOS 窗口"
             success:YES];
    MacWSLog(@"scene-reused mode=window window=%u owner=%d reason=%@",
             windowID, ownerPID, reason ?: @"");
}

- (void)openFullscreenWorkspace {
    if (_streamMode == MacWSStreamModeFullscreen) {
        if (!_workspaceReturnValid || _workspaceReturnWindowID == 0 ||
            _workspaceReturnOwnerPID <= 1) {
            // A restored desktop can legitimately outlive the AppKit window
            // from which it was entered.  Use the current focused, visible
            // catalog window as the return destination instead of making the
            // fullscreen toggle one-way. This is the same generic window
            // identity used by the picker and input router.
            MacWSStreamWindow *fallback = nil;
            for (MacWSStreamWindow *candidate in _streamWindows) {
                MacWSStreamWindowFlags flags = candidate.descriptor.flags;
                if (candidate.descriptor.ownerPID <= 1 ||
                    (flags & MacWSStreamWindowVisible) == 0 ||
                    (flags & MacWSStreamWindowOnScreen) == 0) continue;
                if (!fallback) fallback = candidate;
                if (flags & MacWSStreamWindowFocused) {
                    fallback = candidate;
                    break;
                }
            }
            if (!fallback) {
                [self setNotice:@"当前工作区没有可恢复的 macOS 窗口；请先打开一个应用。"
                         success:NO];
                return;
            }
            _workspaceReturnValid = YES;
            _workspaceReturnWindowID = fallback.descriptor.windowID;
            _workspaceReturnOwnerPID = fallback.descriptor.ownerPID;
            _workspaceReturnGroupID = fallback.descriptor.logicalGroupID;
            _workspaceReturnMinimumSize = CGSizeMake(
                fallback.descriptor.minimumLogicalWidth,
                fallback.descriptor.minimumLogicalHeight);
            _workspaceReturnPreferredSize = CGSizeMake(
                fallback.descriptor.logicalWidth,
                fallback.descriptor.logicalHeight);
            _workspaceReturnSceneSize = _workspaceReturnPreferredSize;
            _workspaceReturnResizable =
                (fallback.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _workspaceReturnTitle = fallback.title.length
                ? [fallback.title copy] : @"macOS Window";
            MacWSLog(@"workspace-return recovered-from-catalog owner=%d window=%u group=%u title=%@",
                     _workspaceReturnOwnerPID, _workspaceReturnWindowID,
                     _workspaceReturnGroupID, _workspaceReturnTitle);
        }

        uint32_t returnWindowID = _workspaceReturnWindowID;
        int32_t returnOwnerPID = _workspaceReturnOwnerPID;
        uint32_t returnGroupID = _workspaceReturnGroupID;
        CGSize returnMinimumSize = _workspaceReturnMinimumSize;
        CGSize returnPreferredSize = _workspaceReturnPreferredSize;
        CGSize returnSceneSize = _workspaceReturnSceneSize;
        BOOL returnResizable = _workspaceReturnResizable;
        NSString *returnTitle = [_workspaceReturnTitle copy];
        UIWindowScene *scene = self.view.window.windowScene;
        __weak MacWSViewController *weakSelf = self;
        void (^restoreInCurrentScene)(NSError *) = ^(NSError *error) {
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_sceneDestructionRequested = NO;
            BOOL requestedSystemWindowed =
                MacWSRequestCurrentSceneMaximization(scene, NO, nil);
            strongSelf->_workspaceReturnValid = NO;
            strongSelf->_workspaceReturnWindowID = 0;
            strongSelf->_workspaceReturnOwnerPID = 0;
            strongSelf->_workspaceReturnGroupID = 0;
            strongSelf->_workspaceReturnMinimumSize = CGSizeZero;
            strongSelf->_workspaceReturnPreferredSize = CGSizeZero;
            strongSelf->_workspaceReturnSceneSize = CGSizeZero;
            strongSelf->_workspaceReturnResizable = NO;
            strongSelf->_workspaceReturnTitle = nil;
            [strongSelf openWindowIDInCurrentScene:returnWindowID
                                          ownerPID:returnOwnerPID
                                    logicalGroupID:returnGroupID
                                             title:returnTitle
                                            reason:nil];
            strongSelf->_windowMinimumSize = returnMinimumSize;
            strongSelf->_windowPreferredSize = returnPreferredSize;
            strongSelf->_windowResizable = returnResizable;
            strongSelf->_metalView.minimumLogicalSize = returnMinimumSize;
            strongSelf->_metalView.targetWindowResizable = returnResizable;
            MacWSRememberSceneBinding(scene.session,
                                      [strongSelf streamRestorationActivity]);
            [strongSelf hideControls];
            [strongSelf setNotice:error
                ? [NSString stringWithFormat:
                    @"系统未能创建窗口场景，已在当前场景恢复：%@",
                    error.localizedDescription ?: @"未知错误"]
                : (requestedSystemWindowed
                    ? @"正在通过 iPadOS 系统动画恢复窗口模式"
                    : @"已恢复 macOS 窗口内容")
                         success:error == nil];
            MacWSLog(@"scene-reused mode=window restored-from-workspace window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f system-unzoom-requested=%@ replacement-error=%@",
                     returnWindowID, returnOwnerPID, returnGroupID,
                     returnSceneSize.width, returnSceneSize.height,
                     requestedSystemWindowed ? @"YES" : @"NO",
                     error ?: @"none");
        };

        if (_sceneDestructionRequested) return;
        _sceneDestructionRequested = YES;
        BOOL requestedReplacement = MacWSRequestWindowedReplacementScene(
            scene, returnWindowID, returnOwnerPID, returnGroupID,
            returnPreferredSize, returnMinimumSize, returnResizable,
            returnTitle, restoreInCurrentScene);
        if (!requestedReplacement) {
            restoreInCurrentScene(nil);
            return;
        }
        [self hideControls];
        [self setNotice:@"正在通过 iPadOS 系统窗口动画恢复窗口模式"
                 success:YES];
        MacWSLog(@"scene-windowed-replacement submitted old=%@ window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f",
                 scene.session.persistentIdentifier, returnWindowID,
                 returnOwnerPID, returnGroupID, returnSceneSize.width,
                 returnSceneSize.height);
        return;
    }

    // Fullscreen is a presentation mode of the current Scene. The previous
    // implementation requested a second Scene session, so the button could
    // never make the window the user was operating become the workspace.
    // First activate the exact native window while its ID/PID mapping is still
    // authoritative, then detach this Scene from that identity and subscribe
    // it to the complete desktop producer.
    _workspaceReturnValid = _windowID != 0 && _windowOwnerPID > 1;
    _workspaceReturnWindowID = _windowID;
    _workspaceReturnOwnerPID = _windowOwnerPID;
    _workspaceReturnGroupID = _windowGroupID;
    _workspaceReturnMinimumSize = _windowMinimumSize;
    _workspaceReturnPreferredSize = _windowPreferredSize;
    // UIWindowScene.coordinateSpace is panel-sized even for a Stage Manager
    // Center window on iPadOS 16 (runtime: 1389x970 in both roles). The root
    // view is the actual Scene content extent. Preserve it only as a witness;
    // SpringBoard's maximization toggle owns restoration of the native size.
    CGSize currentViewSize = self.view.bounds.size;
    _workspaceReturnSceneSize =
        currentViewSize.width >= 150.0 && currentViewSize.height >= 150.0
            ? currentViewSize : _windowPreferredSize;
    _workspaceReturnResizable = _windowResizable;
    _workspaceReturnTitle = [self.view.window.windowScene.title copy];
    BOOL activatedExactWindow = [self activateCurrentMacWindow];
    [_metalView suspendStream];
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeFullscreen;
    _windowID = 0;
    _windowOwnerPID = 0;
    _windowGroupID = 0;
    _windowMinimumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    _metalView.targetPID = 0;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    [self dismissSemanticMenu];
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = @"MacWS Workspace";
    [_metalView configureStreamMode:_streamMode windowID:0];
    [_metalView requestStreamWindowList];
    // Fullscreen is presentation state, not a new owner identity. Persist the
    // return identity in the Scene activity so a UIKit process eviction does
    // not strand the AppKit window or turn the toggle into a one-way action.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    NSUserActivity *workspaceActivity = [self streamRestorationActivity];
    BOOL requestedSystemFullscreen =
        MacWSRequestCurrentSceneImmersiveFullscreen(
        self.view.window.windowScene, workspaceActivity,
        ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    if (!requestedSystemFullscreen) {
        requestedSystemFullscreen = MacWSRequestCurrentSceneMaximization(
            self.view.window.windowScene, YES,
            ^(NSError *error) {
                [self setNotice:[NSString stringWithFormat:
                    @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                    error.localizedDescription ?: @"未知错误"] success:NO];
            });
    }
    if (requestedSystemFullscreen) {
        // _requestFullscreen: is asynchronous and can be accepted without a
        // FrontBoard geometry transition for an already-connected Stage
        // Manager Scene. Verify the real UIWindow, then use the SpringBoard
        // window action only when the native video/game route did not land.
        __weak MacWSViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     1250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf ||
                strongSelf->_streamMode != MacWSStreamModeFullscreen) return;
            UIWindowScene *currentScene = strongSelf.view.window.windowScene;
            CGRect visibleBounds = strongSelf.view.window.bounds;
            CGRect screenBounds = currentScene.screen.bounds;
            BOOL systemState = [currentScene respondsToSelector:
                @selector(isFullScreen)] && currentScene.isFullScreen;
            BOOL fillsPanel = fabs(visibleBounds.size.width -
                                   screenBounds.size.width) <= 1.0 &&
                fabs(visibleBounds.size.height -
                     screenBounds.size.height) <= 1.0;
            if (systemState || fillsPanel) {
                MacWSLog(@"scene-immersive landed session=%@ is-fullscreen=%@ bounds=%@ screen=%@",
                         currentScene.session.persistentIdentifier,
                         systemState ? @"YES" : @"NO",
                         NSStringFromCGRect(visibleBounds),
                         NSStringFromCGRect(screenBounds));
                return;
            }
            MacWSLog(@"scene-immersive fallback session=%@ reason=window-bounds-not-fullscreen bounds=%@ screen=%@",
                     currentScene.session.persistentIdentifier,
                     NSStringFromCGRect(visibleBounds),
                     NSStringFromCGRect(screenBounds));
            MacWSRequestCurrentSceneMaximization(
                currentScene, YES, ^(NSError *error) {
                    [strongSelf setNotice:[NSString stringWithFormat:
                        @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                        error.localizedDescription ?: @"未知错误"] success:NO];
                });
        });
    }
    [self hideControls];
    [self refreshStatus];
    [self setNotice:requestedSystemFullscreen
        ? @"正在将当前 iPadOS 窗口最大化并显示完整 macOS 工作区"
        : @"已显示完整 macOS 工作区；当前 iPadOS 版本没有可用的最大化请求"
             success:requestedSystemFullscreen];
    MacWSLog(@"scene-reused mode=fullscreen previous-window-activated=%@ system-fullscreen-requested=%@",
             activatedExactWindow ? @"YES" : @"NO",
             requestedSystemFullscreen ? @"YES" : @"NO");
}

- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled {
    BOOL active = _streamMode == MacWSStreamModeFullscreen;
    if (active == enabled) {
        MacWSLog(@"workspace-mode request idempotent requested=%@ active=%@",
                 enabled ? @"fullscreen" : @"window",
                 active ? @"fullscreen" : @"window");
        return;
    }
    [self openFullscreenWorkspace];
}

- (void)reassertFullscreenScenePresentation {
    if (_streamMode != MacWSStreamModeFullscreen) return;
    [self updateImmersivePresentation];
    BOOL requested = MacWSRequestCurrentSceneMaximization(
        self.view.window.windowScene, YES, ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已恢复，但 iPadOS 无法重新最大化窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    MacWSLog(@"scene-fullscreen foreground-reassert requested=%@",
             requested ? @"YES" : @"NO");
}

- (void)refreshStatus {
    [_controlClient fetchStatus:^(NSDictionary<NSString *,id> *reply) {
        [self applyStatus:reply];
    }];
}

- (void)applyStatus:(NSDictionary<NSString *, id> *)status {
    _latestStatus = status;
    BOOL connected = ![status[@"connection_error"] boolValue];
    BOOL busy = [status[@"busy"] boolValue];
    BOOL rootfs = [status[@"rootfs_ready"] boolValue];
    BOOL ws = [status[@"windowserver_running"] boolValue];
    BOOL input = [status[@"input_running"] boolValue];
    BOOL frame = [status[@"frame_ready"] boolValue];
    BOOL legacyFramebuffer = MacWSLegacyFramebufferFallbackEnabled();
    BOOL renderableFrame = _metalView.hasDirectSurfaceFrame ||
        (legacyFramebuffer && frame);
    int32_t catalogPID = _metalView.targetPID;
    int32_t targetPID = _streamMode == MacWSStreamModeWindow
        ? _windowOwnerPID
        : (MacWSAppInputEndpointReady(catalogPID) ? catalogPID : 0);
    // The full workspace must follow AppKit's actual focused window catalog,
    // not macwshostd's process-local "last app launched" cache.  The daemon
    // can restart while healthy chroot applications and their endpoints stay
    // alive; treating its empty cache as authoritative disabled all touch on
    // an otherwise visible desktop.  Endpoint existence is the invariant for
    // both exact-window and full-workspace routing.
    BOOL appInput = MacWSAppInputEndpointReady(targetPID);
    BOOL fullscreenSystemRoute =
        _streamMode == MacWSStreamModeFullscreen && targetPID <= 1;
    NSString *controlSummary = [NSString stringWithFormat:
        @"connected=%@ busy=%@ rootfs=%@ ws=%@ input=%@ frame=%@ phase=%@ error=%@",
        connected ? @"YES" : @"NO", busy ? @"YES" : @"NO",
        rootfs ? @"YES" : @"NO", ws ? @"YES" : @"NO",
        input ? @"YES" : @"NO", frame ? @"YES" : @"NO",
        status[@"phase"] ?: @"", status[@"last_error"] ?: @""];
    if (![_lastLoggedControlSummary isEqualToString:controlSummary]) {
        _lastLoggedControlSummary = controlSummary;
        MacWSLog(@"control-status %@", controlSummary);
    }
    _serviceLabel.text = connected ? @"● root 控制服务已连接" : @"● root 控制服务离线";
    _serviceLabel.textColor = connected ? UIColor.systemGreenColor : UIColor.systemRedColor;
    _phaseLabel.text = status[@"phase"] ?: status[@"message"] ?: @"等待状态";
    _rootfsLabel.text = rootfs ? @"就绪" : @"缺失/未挂载";
    _rootfsLabel.textColor = rootfs ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSInteger wsPID = [status[@"windowserver_pid"] integerValue];
    _windowServerLabel.text = ws ? [NSString stringWithFormat:@"运行中 · %ld", (long)wsPID] : @"已停止";
    _windowServerLabel.textColor = ws ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    _bridgeLabel.text = input
        ? (targetPID > 1 && appInput
            ? [NSString stringWithFormat:@"在线 · 目标 PID %d", targetPID]
            : (fullscreenSystemRoute
                ? @"在线 · 全桌面逐点命中"
                : (targetPID > 1 ? @"在线 · 等待应用输入端点" : @"在线 · 等待应用")))
        : @"离线";
    _bridgeLabel.textColor = input ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    if (_metalView.hasDirectSurfaceFrame) {
        _frameLabel.text = @"DisplayStream · IOSurface";
        _frameLabel.textColor = UIColor.systemGreenColor;
    } else if (legacyFramebuffer && frame) {
        _frameLabel.text = [NSString stringWithFormat:@"%@×%@",
                            status[@"frame_width"], status[@"frame_height"]];
        _frameLabel.textColor = UIColor.systemGreenColor;
    } else {
        _frameLabel.text = @"等待 DisplayStream IOSurface 首帧";
        _frameLabel.textColor = UIColor.systemOrangeColor;
    }
    if (!_experimentalTouched || ws) {
        _experimentalSwitch.on = [status[@"experimental_mode"] boolValue];
    }
    NSString *lastError = status[@"last_error"];
    if (lastError.length) [self setNotice:lastError success:NO];

    if (ws && !_metalView.streamServiceConnected &&
        !(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    if (ws && !_interopClient.isConnected) [_interopClient connect];

    _metalView.targetPID = targetPID;
    // A root control transaction (for example a 30-second application launch
    // witness) does not stop WindowServer, DisplayStream, or the per-process
    // input sockets.  Coupling desktop input to hostd's unrelated `busy` bit
    // made the whole fullscreen workspace intentionally unresponsive while an
    // app was starting.  Keep controls serialized, but derive input readiness
    // solely from the live display/input transport invariants.
    BOOL inputReady = connected && ws && input && renderableFrame &&
        ((targetPID > 1 && appInput) || fullscreenSystemRoute);
    NSString *inputReason = nil;
    if (!connected) inputReason = @"root 控制服务离线";
    else if (!ws) inputReason = @"macOS 工作区已停止";
    else if (!input) inputReason = @"触控桥离线";
    else if (!renderableFrame) inputReason = @"等待 DisplayStream IOSurface 首帧";
    else if (targetPID <= 1 && !fullscreenSystemRoute)
        inputReason = @"等待该窗口的所属应用";
    else if (!appInput) inputReason = @"目标应用输入端点尚未就绪";
    [_metalView setMacWSInputEnabled:inputReady reason:inputReason];
    _inputLabel.text = inputReady
        ? @"触控：已就绪 · 直接点击或拖动 macOS 画面"
        : [NSString stringWithFormat:@"触控：不可用 · %@",
           inputReason ?: @"工作区未就绪"];
    _inputLabel.textColor = inputReady
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;

    [self setControlsEnabled:connected && !busy];
    if (busy) {
        [self setButton:_primaryButton title:status[@"phase"] ?: @"处理中…"
                   image:@"hourglass"];
    } else if (ws) {
        [self setButton:_primaryButton title:@"停止 macOS" image:@"stop.fill"];
    } else {
        [self setButton:_primaryButton
                  title:rootfs ? @"启动 macOS 工作区" : @"初始化并启动"
                  image:@"play.fill"];
    }

    NSDictionary<NSString *, NSString *> *availability = @{
        @"glassdemo": @"glassdemo_available",
        @"terminal": @"terminal_available",
        @"activity-monitor": @"activity_monitor_available",
        @"finder": @"finder_available",
        @"vscode": @"vscode_available",
        @"system-settings": @"system_settings_available",
        @"maps": @"maps_available",
    };
    for (UIButton *button in _applicationButtons) {
        BOOL available = [status[availability[button.accessibilityIdentifier]] boolValue];
        button.enabled = connected && !busy && ws && available;
    }

    // A new Host Scene is a launcher for one concrete macOS window, not a
    // full-display workspace. Start production macOS if needed, then launch
    // Terminal exactly once. The first catalog entry replaces this Scene
    // in-place, so no redundant black Scene survives startup.
    if (_bootstrapTerminalPending && connected && !busy) {
        if (ws) {
            _bootstrapTerminalPending = NO;
            [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                     arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"terminal"}];
        } else if (!_bootstrapWorkspaceStartInFlight) {
            _bootstrapWorkspaceStartInFlight = YES;
            [self setNotice:@"正在启动 macOS，并准备默认终端窗口…" success:YES];
            [_controlClient startWithExperimentalMode:YES
                completion:^(NSDictionary<NSString *,id> *reply) {
                    self->_bootstrapWorkspaceStartInFlight = NO;
                    BOOL ok = [reply[@"ok"] boolValue];
                    [self applyStatus:reply];
                    if (!ok) {
                        [self setNotice:reply[@"message"] ?:
                            @"macOS 工作区启动失败" success:NO];
                    }
                }];
        }
    }
}

- (void)runOperation:(NSString *)operation arguments:(NSDictionary *)arguments {
    [self setControlsEnabled:NO];
    [self setNotice:@"操作已提交，请保持 App 在前台…" success:YES];
    [_controlClient performOperation:operation arguments:arguments
        completion:^(NSDictionary<NSString *,id> *reply) {
            BOOL ok = [reply[@"ok"] boolValue];
            [self setNotice:reply[@"message"] ?: @"操作完成" success:ok];
            [self applyStatus:reply];
            if (ok && [operation isEqualToString:@MACWS_CONTROL_OP_LAUNCH_APP]) {
                NSString *identifier = arguments[@MACWS_CONTROL_KEY_APP_ID];
                int32_t launchedPID =
                    (int32_t)[reply[@"launched_app_pid"] intValue];
                if (launchedPID > 1) {
                    // hostd now completes Finder's native Command-N bootstrap
                    // before replying, so Finder follows the same catalog ->
                    // one Scene transaction as every other application. The
                    // old post-reply menu walk created a second browser window
                    // after the first had already become visible.
                    self->_pendingApplicationWindowPID = launchedPID;
                    self->_pendingApplicationIdentifier = identifier;
                    self->_pendingApplicationWindowAttempts = 0;
                    self->_pendingApplicationWindowRetryScheduled = NO;
                    self->_pendingApplicationCandidateWindowID = 0;
                    self->_pendingApplicationCandidateSince = 0;
                    [self schedulePendingApplicationWindowRetry];
                }
                [self->_metalView requestStreamWindowList];
            }
            [self refreshStatus];
        }];
}

- (void)primaryAction {
    if ([_latestStatus[@"windowserver_running"] boolValue]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else {
        [self setControlsEnabled:NO];
        [self setNotice:_experimentalSwitch.isOn
            ? @"正在用实验兼容模式启动；已启用 5 分钟与高 CPU 自动热保护。"
            : @"正在检查环境；重启后丢失的信任缓存会自动恢复。" success:YES];
        [_controlClient startWithExperimentalMode:_experimentalSwitch.isOn
            completion:^(NSDictionary<NSString *,id> *reply) {
                BOOL ok = [reply[@"ok"] boolValue];
                [self setNotice:reply[@"message"] ?: @"启动完成" success:ok];
                [self applyStatus:reply];
                [self refreshStatus];
            }];
    }
}

- (void)experimentalChanged:(UISwitch *)sender {
    _experimentalTouched = YES;
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn
                                          forKey:@"MacWSExperimentalMode"];
    NSString *state = sender.isOn ? @"已选择实验兼容模式，将在下次启动时生效。" :
        @"已选择标准模式，将在下次启动时移除诊断脚手架。";
    [self setNotice:state success:!sender.isOn];
}

- (void)launchApplication:(UIButton *)sender {
    [self launchApplicationIdentifier:sender.accessibilityIdentifier ?: @""];
}

- (void)launchApplicationIdentifier:(NSString *)identifier {
    // hostd owns application-launch serialization.  For Maps it sends one
    // Darwin request back to this already-foreground Host, whose observer
    // performs the responsible-process spawn.  Spawning here as well created
    // two Maps generations during the 200 ms hostd round trip and left both
    // competing for one UIKitSystem scene.  Keep one transaction and one
    // process generation for Control Center, Dock and URL launches alike.
    [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
             arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier ?: @""}];
}

- (void)captureAction {
    [_metalView suspendStream];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [self setNotice:@"正在重新连接 DisplayStream；不会启动 VNC 或复制 framebuffer。"
             success:YES];
}

- (void)repairAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR arguments:nil];
}

- (void)recoverAction {
    [self runOperation:@MACWS_CONTROL_OP_RECOVER arguments:nil];
}

- (void)logsAction {
    if (!_logsView.hidden) {
        _logsView.hidden = YES;
        [self setButton:_logsButton title:@"查看日志" image:@"doc.text.magnifyingglass"];
        return;
    }
    [self setButton:_logsButton title:@"收起日志" image:@"doc.text.magnifyingglass"];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            reply[@"hostd_log"] ?: @"", reply[@"windowserver_log"] ?: @"",
            reply[@"input_log"] ?: @"", reply[@"postinst_log"] ?: @""];
        self->_logsView.text = text;
        self->_logsView.hidden = NO;
        if (text.length) [self->_logsView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    }];
}

- (NSURL *)writeHostUISnapshot {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:self.view.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *png = UIImagePNGRepresentation(image);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-ui.png";
    BOOL written = [png writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"ui-snapshot written=%@ bytes=%lu path=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)writeHostScreenSnapshot {
    // RE-confirmed in the target iOS 16.3.1 UIKitCore image: exported
    // _UICreateScreenUIImage at 0x189df62ac returns the foreground screen
    // composite. Keep this explicit diagnostic off every display/input hot
    // path; unlike drawViewHierarchy it can witness system chrome.
    UIImage *(*createScreenImage)(void) =
        (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    UIImage *image = createScreenImage ? createScreenImage() : nil;
    NSData *png = image ? UIImagePNGRepresentation(image) : nil;
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-screen.png";
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    MacWSLog(@"screen-snapshot written=%@ bytes=%lu symbol=%@ path=%@ error=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             createScreenImage ? @"YES" : @"NO", path, error ?: @"");
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (void)exportDiagnostics {
    NSURL *snapshot = [self writeHostUISnapshot];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"MacWS Host diagnostics\n%@\n\n=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            self->_latestStatus ?: @{}, reply[@"hostd_log"] ?: @"",
            reply[@"windowserver_log"] ?: @"", reply[@"input_log"] ?: @"",
            reply[@"postinst_log"] ?: @""];
        NSString *path = @"/var/mobile/Library/Logs/MacWSHost-diagnostics.txt";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:path]];
        if (snapshot) [items addObject:snapshot];
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:items applicationActivities:nil];
        activity.popoverPresentationController.sourceView = self->_exportButton;
        activity.popoverPresentationController.sourceRect = self->_exportButton.bounds;
        [self presentViewController:activity animated:YES completion:nil];
    }];
}

- (void)performURLAction:(NSString *)action {
    MacWSLog(@"url-control action=%@", action);
    if ([action isEqualToString:@"status"] || action.length == 0) {
        [self refreshStatus];
    } else if ([action isEqualToString:@"start"] ||
               [action isEqualToString:@"start-experimental"]) {
        if (![_latestStatus[@"windowserver_running"] boolValue]) {
            _experimentalSwitch.on = [action isEqualToString:@"start-experimental"];
            [self experimentalChanged:_experimentalSwitch];
            [self primaryAction];
        } else {
            [self setNotice:@"macOS 工作区已经在运行" success:YES];
        }
    } else if ([action isEqualToString:@"stop"]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else if ([action isEqualToString:@"glassdemo"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"glassdemo"}];
    } else if ([action isEqualToString:@"terminal"] ||
               [action isEqualToString:@"vscode"] ||
               [action isEqualToString:@"activity-monitor"] ||
               [action isEqualToString:@"finder"] ||
               [action isEqualToString:@"system-settings"] ||
               [action isEqualToString:@"maps"]) {
        [self launchApplicationIdentifier:action];
    } else if ([action isEqualToString:@"recover"]) {
        [self recoverAction];
    } else if ([action isEqualToString:@"repair"]) {
        [self repairAction];
    } else if ([action isEqualToString:@"capture"]) {
        [self captureAction];
    } else if ([action isEqualToString:@"test-open-file"]) {
        [self performSemanticShortcutForDiagnostics:@"⌘O"];
    } else if ([action isEqualToString:@"fullscreen"]) {
        [self openFullscreenWorkspace];
    } else if ([action isEqualToString:@"enter-workspace"]) {
        [self setFullscreenWorkspaceEnabled:YES];
    } else if ([action isEqualToString:@"exit-workspace"]) {
        [self setFullscreenWorkspaceEnabled:NO];
    } else if ([action isEqualToString:@"close-window"]) {
        [self closeCurrentWindow];
    } else if ([action isEqualToString:@"screenshot-ui"]) {
        [self writeHostUISnapshot];
    } else if ([action isEqualToString:@"screenshot-screen"]) {
        [self writeHostScreenSnapshot];
    } else if ([action isEqualToString:@"performance-snapshot"]) {
        [_metalView logPerformanceSnapshotWithReason:@"url-control"];
    } else if ([action isEqualToString:@"hide-controls"]) {
        [self hideControls];
    } else if ([action isEqualToString:@"show-controls"]) {
        [self showControls];
    }
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    _statusLabel.text = [@"画面：" stringByAppendingString:status];
    if (view.hasDirectSurfaceFrame && !view.isMacWSInputEnabled) {
        MacWSLog(@"display-stream first-frame revalidate-input mode=%lu target=%d status=%@",
                 (unsigned long)_streamMode, view.targetPID, status);
        [self refreshStatus];
    }
}

- (void)openInitialFinderBrowserWindowIfNeeded:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingFinderWindowPID;
    if (ownerPID <= 1 || _finderMenuRequestInFlight) return;
    MacWSStreamWindow *seed = nil;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID == ownerPID) {
            seed = window;
            break;
        }
    }
    if (!seed) return;
    if (_pendingFinderMenuAttempts >= 8) {
        _pendingFinderWindowPID = 0;
        [self setNotice:@"Finder 已启动；菜单在限定时间内尚未就绪，可稍后从窗口菜单选择“文件 → 新建 Finder 窗口”。"
                 success:NO];
        return;
    }
    _pendingFinderMenuAttempts++;
    _finderMenuRequestInFlight = YES;
    MacWSLog(@"finder-browser menu-attempt=%lu pid=%d seed-window=%u",
             (unsigned long)_pendingFinderMenuAttempts, ownerPID,
             seed.descriptor.windowID);
    [_menuClient requestSnapshotForPID:ownerPID
        windowID:seed.descriptor.windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            self->_finderMenuRequestInFlight = NO;
            if (self->_pendingFinderWindowPID != ownerPID) return;
            if (!snapshot || error) {
                MacWSLog(@"finder-browser menu-not-ready attempt=%lu error=%@",
                         (unsigned long)self->_pendingFinderMenuAttempts,
                         error.localizedDescription ?: @"无菜单快照");
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *fileMenu = nil;
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == 1 ||
                    [root.title localizedCaseInsensitiveContainsString:@"file"] ||
                    [root.title containsString:@"文件"]) {
                    fileMenu = root;
                    break;
                }
            }
            if (!fileMenu) {
                MacWSLog(@"finder-browser file-menu-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *newWindow = nil;
            for (MacWSMenuItem *item in
                    [snapshot childrenOfItemID:fileMenu.itemID]) {
                BOOL named = [item.title
                    localizedCaseInsensitiveContainsString:@"new finder window"] ||
                    [item.title containsString:@"新建 Finder 窗口"];
                BOOL commandN = [item.shortcut hasSuffix:@"⌘N"] ||
                    [item.shortcut isEqualToString:@"⌘N"];
                if ((named || commandN) &&
                    (item.flags & MacWSMenuNodeEnabled) &&
                    !(item.flags & MacWSMenuNodeHasSubmenu)) {
                    newWindow = item;
                    break;
                }
            }
            if (!newWindow) {
                MacWSLog(@"finder-browser new-window-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            [self->_menuClient performItem:newWindow inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    if (status == MacWSMenuStatusOK) {
                        self->_pendingFinderWindowPID = 0;
                        self->_pendingApplicationWindowPID = ownerPID;
                        self->_pendingApplicationIdentifier = @"finder";
                        self->_pendingApplicationWindowAttempts = 0;
                        self->_pendingApplicationWindowRetryScheduled = NO;
                        [self setNotice:@"Finder 浏览窗口已创建，可从“打开 macOS 窗口”进入。"
                                 success:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                      500 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            [self->_metalView requestStreamWindowList];
                        });
                    } else {
                        MacWSLog(@"finder-browser action-not-ready attempt=%lu status=%u error=%@",
                                 (unsigned long)self->_pendingFinderMenuAttempts,
                                 (unsigned)status,
                                 actionError.localizedDescription ?: @"无错误描述");
                        [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                    }
                }];
        }];
}

- (void)scheduleFinderBrowserMenuRetryForPID:(int32_t)ownerPID {
    if (_pendingFinderWindowPID != ownerPID || ownerPID <= 1) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_pendingFinderWindowPID != ownerPID) return;
        [self openInitialFinderBrowserWindowIfNeeded:self->_streamWindows ?: @[]];
    });
}

- (void)schedulePendingApplicationWindowRetry {
    if (_pendingApplicationWindowPID <= 1 ||
        _pendingApplicationWindowRetryScheduled ||
        _pendingApplicationWindowAttempts >= 20) return;
    _pendingApplicationWindowRetryScheduled = YES;
    _pendingApplicationWindowAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_pendingApplicationWindowRetryScheduled = NO;
        if (self->_pendingApplicationWindowPID <= 1) return;
        [self->_metalView requestStreamWindowList];
        [self schedulePendingApplicationWindowRetry];
    });
}

- (void)openPendingApplicationWindowFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingApplicationWindowPID;
    if (ownerPID <= 1) return;
    MacWSStreamWindow *target = nil;
    NSUInteger targetScore = 0;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID != ownerPID) continue;
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        // Sheets and app-modal panels are transported as overlays of their
        // presenting logical window. They must never own an iPadOS Scene.
        if (flags & MacWSStreamWindowTransient) continue;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 8 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 4 : 0) |
            ((flags & MacWSStreamWindowVisible) ? 2 : 0) |
            ((flags & MacWSStreamWindowTransient) ? 0 : 1);
        CGFloat area = window.descriptor.logicalWidth *
                       window.descriptor.logicalHeight;
        CGFloat targetArea = target ? target.descriptor.logicalWidth *
                                      target.descriptor.logicalHeight : 0.0;
        if (!target || score > targetScore ||
            (score == targetScore && area > targetArea)) {
            target = window;
            targetScore = score;
        }
    }
    if (!target) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    // Catalyst and ExtensionKit can publish a short-lived black bootstrap
    // NSWindow before their real scene/content window.  Wait for the best
    // candidate identity to remain stable for 500 ms; if focus or the window
    // number changes, restart the interval.  This is generic catalog
    // stabilization and does not special-case Maps or Settings titles.
    CFTimeInterval now = CACurrentMediaTime();
    if (_pendingApplicationCandidateWindowID != target.descriptor.windowID) {
        _pendingApplicationCandidateWindowID = target.descriptor.windowID;
        _pendingApplicationCandidateSince = now;
        MacWSLog(@"launch-auto-window candidate app=%@ pid=%d window=%u score=%lu state=new",
                 _pendingApplicationIdentifier ?: @"macOS app", ownerPID,
                 target.descriptor.windowID, (unsigned long)targetScore);
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    if (now - _pendingApplicationCandidateSince < 0.5) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    NSString *identifier = _pendingApplicationIdentifier ?: @"macOS app";
    _pendingApplicationWindowPID = 0;
    _pendingApplicationIdentifier = nil;
    _pendingApplicationWindowAttempts = 0;
    _pendingApplicationWindowRetryScheduled = NO;
    _pendingApplicationCandidateWindowID = 0;
    _pendingApplicationCandidateSince = 0;
    NSString *title = target.title.length ? target.title : identifier;
    MacWSLog(@"launch-auto-window app=%@ pid=%d window=%u group=%u",
             identifier, ownerPID, target.descriptor.windowID,
             target.descriptor.logicalGroupID);
    NSString *targetIdentity = MacWSWindowIdentity(
        target.descriptor.ownerPID, target.descriptor.windowID,
        target.descriptor.logicalGroupID);
    if (!MacWSObservedWindowIdentities)
        MacWSObservedWindowIdentities = [NSMutableSet set];
    if (targetIdentity) [MacWSObservedWindowIdentities addObject:targetIdentity];
    if (_streamMode == MacWSStreamModeFullscreen &&
        _bootstrapWindowReplacementPending) {
        // This is the first-launch placeholder rather than an intentional
        // fullscreen desktop entered from an AppKit window.  Replace the
        // placeholder in place, matching the startup contract documented in
        // applyStatus:, instead of retaining a black workspace Scene.
        _bootstrapWindowReplacementPending = NO;
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        MacWSLog(@"launch-auto-window replaced-bootstrap app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_streamMode == MacWSStreamModeFullscreen) {
        // The fullscreen Scene already presents WindowServer's complete
        // desktop. Turning it into a per-window stream here both crops that
        // desktop and asks UIKit to create/restore a windowed Scene. Keep the
        // workspace identity intact and activate the exact catalog window in
        // place.  Merely waiting for the focused flag left newly launched
        // Catalyst/AppKit applications behind the previous frontmost app, so
        // both pixels and AppInput continued to target the old process.
        // ActivateTarget uses the window ID + owner PID already published by
        // DisplayStream; it neither creates a UIKit Scene nor starts another
        // application generation.
        [self activateMacWindow:target];
        [self setNotice:[NSString stringWithFormat:
            @"%@ 已在当前全屏工作区中打开。", identifier] success:YES];
        MacWSLog(@"launch-auto-window activated-fullscreen app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_windowID == 0) {
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        return;
    }
    MacWSRequestNewScene(self.view.window.windowScene,
        target.descriptor.windowID, target.descriptor.ownerPID,
        target.descriptor.logicalGroupID,
        CGSizeMake(target.descriptor.logicalWidth,
                   target.descriptor.logicalHeight),
        CGSizeMake(target.descriptor.minimumLogicalWidth,
                   target.descriptor.minimumLogicalHeight),
        (target.descriptor.flags & MacWSStreamWindowResizable) != 0,
        title, ^(NSError *error) {
            if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                error.code == 2) {
                [self openWindowInCurrentScene:target
                    reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开。"];
            } else {
                [self setNotice:error.localizedDescription success:NO];
            }
        });
}

- (BOOL)isWindowDiscoveryCoordinator {
    UIScene *candidate = self.view.window.windowScene;
    if (!candidate || candidate.activationState !=
            UISceneActivationStateForegroundActive) return NO;
    NSString *candidateID = candidate.session.persistentIdentifier;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene == candidate || scene.activationState !=
                UISceneActivationStateForegroundActive) continue;
        NSString *identifier = scene.session.persistentIdentifier;
        if ([identifier compare:candidateID] == NSOrderedAscending) return NO;
    }
    return YES;
}

- (BOOL)hasForegroundFullscreenWorkspace {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
            .rootViewController;
        if ([root isKindOfClass:MacWSViewController.class] &&
            ((MacWSViewController *)root)->_streamMode ==
                MacWSStreamModeFullscreen)
            return YES;
    }
    return NO;
}

- (void)openNewMacWindowsFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    if (!MacWSPendingWindowSceneIdentities)
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *current =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in windows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if ((descriptor.flags & MacWSStreamWindowVisible) == 0) continue;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (identity) current[identity] = window;
    }
    if ([self hasForegroundFullscreenWorkspace]) {
        // New AppKit windows are already visible in the desktop stream. They
        // must not become additional iPadOS Scenes until every foreground
        // workspace has returned to per-window mode. This must be a global
        // Scene invariant: a second foreground windowed controller also
        // receives the same catalog and used to create the unwanted Stage
        // Manager window even though the initiating controller was fullscreen.
        if (!MacWSObservedWindowIdentities)
            MacWSObservedWindowIdentities = [NSMutableSet set];
        // Dock and other macOS-native launch owners call hostd directly, so
        // they do not receive the Control Center's pending-PID callback. The
        // DisplayStream catalog is the common authoritative boundary for
        // every launch source. Activate the best newly published, ordinary
        // window in the existing desktop while retaining the one fullscreen
        // iPadOS Scene. Pending Control Center launches add their identity
        // before reaching this branch and therefore remain exactly-once.
        MacWSStreamWindow *newTarget = nil;
        NSUInteger newTargetScore = 0;
        for (NSString *identity in current) {
            if ([MacWSObservedWindowIdentities containsObject:identity])
                continue;
            MacWSStreamWindow *window = current[identity];
            MacWSStreamWindowFlags flags = window.descriptor.flags;
            if (window.descriptor.ownerPID <= 1 ||
                (flags & MacWSStreamWindowTransient) != 0) continue;
            NSUInteger score =
                ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
                ((flags & MacWSStreamWindowVisible) ? 2 : 0) | 1;
            if (!newTarget || score > newTargetScore) {
                newTarget = window;
                newTargetScore = score;
            }
        }
        [MacWSObservedWindowIdentities setSet:
            [NSSet setWithArray:current.allKeys]];
        [MacWSPendingWindowSceneIdentities removeAllObjects];
        if (newTarget) {
            [self activateMacWindow:newTarget];
            MacWSLog(@"window-auto-scene activated-fullscreen-catalog pid=%d window=%u group=%u score=%lu",
                     newTarget.descriptor.ownerPID,
                     newTarget.descriptor.windowID,
                     newTarget.descriptor.logicalGroupID,
                     (unsigned long)newTargetScore);
        }
        return;
    }
    if (![self isWindowDiscoveryCoordinator]) return;
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [NSMutableSet setWithArray:current.allKeys];
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
        return;
    }

    NSMutableSet<NSString *> *occupied = [NSMutableSet set];
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions) {
        NSUserActivity *activity = MacWSSceneBindings[
            session.persistentIdentifier] ?:
            MacWSPersistedSceneActivity(session.persistentIdentifier) ?:
            session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        int32_t ownerPID = 0;
        uint32_t windowID = 0, groupID = 0;
        NSString *identity = MacWSSceneOwnedWindowFields(
            info, &ownerPID, &windowID, &groupID)
            ? MacWSWindowIdentity(ownerPID, windowID, groupID) : nil;
        if (identity) [occupied addObject:identity];
    }

    NSMutableArray<MacWSStreamWindow *> *newWindows = [NSMutableArray array];
    for (NSString *identity in current) {
        if ([MacWSObservedWindowIdentities containsObject:identity] ||
            [MacWSPendingWindowSceneIdentities containsObject:identity] ||
            [occupied containsObject:identity]) continue;
        MacWSStreamWindow *window = current[identity];
        BOOL relevantOwner = _windowOwnerPID > 1 &&
            window.descriptor.ownerPID == _windowOwnerPID;
        BOOL focused = (window.descriptor.flags & MacWSStreamWindowFocused) != 0;
        if (relevantOwner || focused) [newWindows addObject:window];
    }
    [MacWSObservedWindowIdentities setSet:[NSSet setWithArray:current.allKeys]];

    // A user gesture normally creates one native window. Bound a pathological
    // application burst so one catalog invalidation cannot flood FrontBoard.
    NSUInteger limit = MIN(newWindows.count, 3);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = newWindows[index];
        NSString *identity = MacWSWindowIdentity(window.descriptor.ownerPID,
            window.descriptor.windowID, window.descriptor.logicalGroupID);
        if (!identity) continue;
        [MacWSPendingWindowSceneIdentities addObject:identity];
        // AppKit dialogs can briefly appear as a layer-0 catalog window and
        // then become the base window's transient layer on the next commit.
        // Runtime-confirmed with Terminal's Low Disk Space alert: requesting
        // a Scene on the first edge created both an exact iPad window and the
        // correct in-window overlay. Require the identity to remain a real
        // visible catalog entry after one short ordering interval. Ordinary
        // new windows remain in _streamWindows; alerts disappear from it when
        // displayd's real CGWindow layer reconciliation runs.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSStreamWindow *stableWindow = nil;
            for (MacWSStreamWindow *candidate in self->_streamWindows) {
                NSString *candidateIdentity = MacWSWindowIdentity(
                    candidate.descriptor.ownerPID,
                    candidate.descriptor.windowID,
                    candidate.descriptor.logicalGroupID);
                if ([candidateIdentity isEqualToString:identity] &&
                    (candidate.descriptor.flags & MacWSStreamWindowVisible)) {
                    stableWindow = candidate;
                    break;
                }
            }
            if (!stableWindow) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                MacWSLog(@"window-auto-scene cancelled identity=%@ reason=transient",
                         identity);
                return;
            }
            if ([self hasForegroundFullscreenWorkspace]) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                if (!MacWSObservedWindowIdentities)
                    MacWSObservedWindowIdentities = [NSMutableSet set];
                [MacWSObservedWindowIdentities addObject:identity];
                [self activateMacWindow:stableWindow];
                MacWSLog(@"window-auto-scene retained-fullscreen identity=%@ pid=%d window=%u",
                         identity, stableWindow.descriptor.ownerPID,
                         stableWindow.descriptor.windowID);
                return;
            }
            NSString *title = stableWindow.title.length
                ? stableWindow.title : @"macOS Window";
            MacWSLog(@"window-auto-scene identity=%@ title=%@ stable-ms=250",
                     identity, title);
            MacWSRequestNewScene(self.view.window.windowScene,
                stableWindow.descriptor.windowID,
                stableWindow.descriptor.ownerPID,
                stableWindow.descriptor.logicalGroupID,
                CGSizeMake(stableWindow.descriptor.logicalWidth,
                           stableWindow.descriptor.logicalHeight),
                CGSizeMake(stableWindow.descriptor.minimumLogicalWidth,
                           stableWindow.descriptor.minimumLogicalHeight),
                (stableWindow.descriptor.flags & MacWSStreamWindowResizable) != 0,
                title, ^(NSError *error) {
                    [MacWSPendingWindowSceneIdentities removeObject:identity];
                    [MacWSObservedWindowIdentities removeObject:identity];
                    [self setNotice:error.localizedDescription success:NO];
                });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [MacWSPendingWindowSceneIdentities removeObject:identity];
        });
    }
}

- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)view;
    _streamWindows = [windows copy];
    if (_streamMode == MacWSStreamModeFullscreen) {
        MacWSStreamWindow *fallback = nil;
        MacWSStreamWindow *focused = nil;
        for (MacWSStreamWindow *window in windows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags flags = descriptor.flags;
            if (descriptor.ownerPID <= 1 ||
                !MacWSAppInputEndpointReady(descriptor.ownerPID) ||
                (flags & MacWSStreamWindowVisible) == 0 ||
                (flags & MacWSStreamWindowOnScreen) == 0) continue;
            // CGWindowList preserves front-to-back order.  Keep its first
            // eligible entry only as a cold-start fallback; AppInputBridge's
            // real NSWindow isKeyWindow publication remains authoritative.
            if (!fallback) fallback = window;
            if (flags & MacWSStreamWindowFocused) {
                focused = window;
                break;
            }
        }
        MacWSStreamWindow *target = focused ?: fallback;
        int32_t previousPID = _metalView.targetPID;
        int32_t targetPID = target ? target.descriptor.ownerPID : 0;
        if (targetPID != previousPID) {
            _metalView.targetPID = targetPID;
            MacWSLog(@"fullscreen-input-target pid=%d window=%u source=%@ title=%@",
                     targetPID, target ? target.descriptor.windowID : 0,
                     target
                        ? (focused ? @"appkit-focused" : @"frontmost-fallback")
                        : @"system-point-hit-test",
                     target.title ?: @"");
            // Runtime-confirmed with Dock switching System Settings -> Maps:
            // Dock published Maps as the AppKit-focused catalog owner, but
            // the previous application's window remained above it and its
            // menu bar stayed active. Reconcile a real cross-process focus
            // edge by activating the exact focused catalog window. The PID is
            // stored before this request, so the resulting catalog refresh is
            // idempotent rather than an activation loop.
            if (previousPID > 1 && targetPID > 1 && focused) {
                [self activateMacWindow:target];
                MacWSLog(@"fullscreen-focus-reconciled previous-pid=%d pid=%d window=%u route=exact-catalog-window",
                         previousPID, targetPID,
                         target.descriptor.windowID);
            }
            [self refreshStatus];
        }
    }
    // Establish the first complete catalog as a baseline before an explicit
    // launch transaction consumes it. This prevents restoring Host from
    // opening every pre-existing macOS window at once; subsequent identities
    // are the actual native windows created after Host became live.
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            NSString *identity = MacWSWindowIdentity(
                window.descriptor.ownerPID, window.descriptor.windowID,
                window.descriptor.logicalGroupID);
            if (identity) [MacWSObservedWindowIdentities addObject:identity];
        }
    }
    [self openInitialFinderBrowserWindowIfNeeded:windows];
    [self openPendingApplicationWindowFromCatalog:windows];
    [self openNewMacWindowsFromCatalog:windows];
    if (_windowID != 0) {
        MacWSStreamWindow *exactWindow = nil;
        MacWSStreamWindow *groupReplacement = nil;
        for (MacWSStreamWindow *window in windows) {
            if (window.descriptor.windowID == _windowID) {
                exactWindow = window;
            } else if (_windowGroupID != 0 &&
                       window.descriptor.ownerPID == _windowOwnerPID &&
                       window.descriptor.logicalGroupID == _windowGroupID) {
                MacWSStreamWindowFlags flags = window.descriptor.flags;
                MacWSStreamWindowFlags oldFlags =
                    groupReplacement ? groupReplacement.descriptor.flags : 0;
                NSUInteger score =
                    ((flags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((flags & MacWSStreamWindowOnScreen) ? 1 : 0);
                NSUInteger oldScore =
                    ((oldFlags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((oldFlags & MacWSStreamWindowOnScreen) ? 1 : 0);
                if (!groupReplacement || score > oldScore)
                    groupReplacement = window;
            }
        }
        // CGWindowListOptionAll intentionally retains Terminal's inactive tab
        // members. Selecting a tab can therefore leave the old exact ID in the
        // catalog even though a focused/on-screen member of the same native
        // NSWindowTabGroup is now the only visible representation. Resolve the
        // logical group by real screen state before falling back to exact ID.
        BOOL exactOnScreen = exactWindow &&
            (exactWindow.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        BOOL replacementFocused = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowFocused) != 0;
        BOOL replacementOnScreen = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        MacWSStreamWindow *resolvedWindow = exactWindow;
        if (groupReplacement && (replacementFocused ||
                (!exactOnScreen && replacementOnScreen)))
            resolvedWindow = groupReplacement;
        if (!resolvedWindow) resolvedWindow = groupReplacement;
        if (resolvedWindow) {
            _targetWindowObservedInCatalog = YES;
            _targetWindowMissingCheckPending = NO;
            _targetWindowMissingSerial++;
            uint32_t resolvedID = resolvedWindow.descriptor.windowID;
            _windowOwnerPID = resolvedWindow.descriptor.ownerPID;
            _windowGroupID = resolvedWindow.descriptor.logicalGroupID;
            _windowMinimumSize = CGSizeMake(
                resolvedWindow.descriptor.minimumLogicalWidth,
                resolvedWindow.descriptor.minimumLogicalHeight);
            _windowPreferredSize = CGSizeMake(
                resolvedWindow.descriptor.logicalWidth,
                resolvedWindow.descriptor.logicalHeight);
            _windowResizable =
                (resolvedWindow.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _metalView.minimumLogicalSize = _windowMinimumSize;
            _metalView.targetWindowResizable = _windowResizable;
            if (resolvedID != _windowID) {
                uint32_t oldID = _windowID;
                [_metalView suspendStream];
                _windowID = resolvedID;
                _metalView.targetPID = _windowOwnerPID;
                [_metalView configureStreamMode:MacWSStreamModeWindow
                                        windowID:_windowID];
                self.view.window.windowScene.title = resolvedWindow.title.length
                    ? resolvedWindow.title
                    : [NSString stringWithFormat:@"MacWS Window %u", _windowID];
                MacWSLog(@"window-identity-follow owner=%d group=%u old=%u new=%u",
                         _windowOwnerPID, _windowGroupID, oldID, _windowID);
                MacWSRememberSceneBinding(self.view.window.windowScene.session,
                                          [self streamRestorationActivity]);
            }
        } else if (_targetWindowObservedInCatalog &&
                   !_targetWindowMissingCheckPending &&
                   !_sceneDestructionRequested) {
            // The catalog is authoritative, but one transient refresh can
            // occur while AppKit replaces a tab-group member. Re-query once
            // and require the exact ID and its logical group to remain absent
            // for a bounded interval before removing the corresponding Scene.
            _targetWindowMissingCheckPending = YES;
            uint64_t serial = ++_targetWindowMissingSerial;
            uint32_t expectedWindowID = _windowID;
            uint32_t expectedGroupID = _windowGroupID;
            int32_t expectedOwnerPID = _windowOwnerPID;
            [_metalView requestStreamWindowList];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         650 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (serial != self->_targetWindowMissingSerial ||
                    !self->_targetWindowMissingCheckPending ||
                    self->_sceneDestructionRequested ||
                    self->_windowID != expectedWindowID) return;
                BOOL present = NO;
                for (MacWSStreamWindow *candidate in self->_streamWindows) {
                    if (candidate.descriptor.windowID == expectedWindowID ||
                        (expectedGroupID != 0 &&
                         candidate.descriptor.ownerPID == expectedOwnerPID &&
                         candidate.descriptor.logicalGroupID == expectedGroupID)) {
                        present = YES;
                        break;
                    }
                }
                self->_targetWindowMissingCheckPending = NO;
                if (present) return;
                UISceneSession *session = self.view.window.windowScene.session;
                NSString *identifier = session.persistentIdentifier;
                if (!session || !identifier.length) return;
                if (!MacWSSceneSessionsPreservingMacWindow)
                    MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
                if (!MacWSSceneCloseRequestsSent)
                    MacWSSceneCloseRequestsSent = [NSMutableSet set];
                [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
                [MacWSSceneCloseRequestsSent addObject:identifier];
                [MacWSSceneBindings removeObjectForKey:identifier];
                MacWSSetPersistedSceneBinding(identifier, nil);
                self->_sceneDestructionRequested = YES;
                MacWSLog(@"runtime-confirmed mac-window-removed id=%@ owner=%d window=%u group=%u catalog-count=%lu",
                         identifier, expectedOwnerPID, expectedWindowID,
                         expectedGroupID,
                         (unsigned long)self->_streamWindows.count);
                [UIApplication.sharedApplication
                    requestSceneSessionDestruction:session options:nil
                    errorHandler:^(NSError *error) {
                        self->_sceneDestructionRequested = NO;
                        [MacWSSceneSessionsPreservingMacWindow
                            removeObject:identifier];
                        [MacWSSceneCloseRequestsSent removeObject:identifier];
                        MacWSLog(@"mac-window-removed scene-destruction failed id=%@ error=%@",
                                 identifier, error);
                    }];
            });
        }
    }
    NSUInteger logicalWindowCount = [self logicalWindowRepresentatives].count;
    [self setButton:_windowPickerButton
              title:logicalWindowCount
                ? [NSString stringWithFormat:@"打开 macOS 窗口 · %lu",
                   (unsigned long)logicalWindowCount]
                : @"打开 macOS 窗口"
              image:@"macwindow.on.rectangle"];
}

- (void)metalView:(MacWSMetalView *)view
 requestedWindowOverviewForCurrentApplication:(BOOL)currentApplicationOnly {
    (void)view;
    [self presentWindowOverviewCurrentApplication:currentApplicationOnly];
}

- (NSUserActivity *)streamRestorationActivity {
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = _windowID
        ? [NSString stringWithFormat:@"MacWS Window %u", _windowID]
        : @"MacWS Workspace";
    activity.userInfo = @{
        @"mode": @(_streamMode),
        @"window_id": @(_windowID),
        @"owner_pid": @(_windowOwnerPID),
        @"logical_group_id": @(_windowGroupID),
        @"preferred_width": @(_windowPreferredSize.width),
        @"preferred_height": @(_windowPreferredSize.height),
        @"minimum_width": @(_windowMinimumSize.width),
        @"minimum_height": @(_windowMinimumSize.height),
        @"resizable": @(_windowResizable),
        @"title": activity.title,
        @"return_window_id": @(_workspaceReturnValid
            ? _workspaceReturnWindowID : 0),
        @"return_owner_pid": @(_workspaceReturnValid
            ? _workspaceReturnOwnerPID : 0),
        @"return_logical_group_id": @(_workspaceReturnValid
            ? _workspaceReturnGroupID : 0),
        @"return_preferred_width": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.width : 0),
        @"return_preferred_height": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.height : 0),
        @"return_minimum_width": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.width : 0),
        @"return_minimum_height": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.height : 0),
        @"return_scene_width": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.width : 0),
        @"return_scene_height": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.height : 0),
        @"return_resizable": @(_workspaceReturnValid
            ? _workspaceReturnResizable : NO),
        @"return_title": _workspaceReturnValid
            ? (_workspaceReturnTitle ?: @"MacWS Window") : @"",
    };
    return activity;
}

- (void)suspendSceneStream {
    [self dismissSemanticMenu];
    [_metalView suspendStream];
}

- (void)resumeSceneStream {
    if (!(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
}

- (void)cancelBootstrapTerminal {
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
}

- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record {
    (void)view;
    // A fullscreen workspace is the DisplayStream layer graph currently
    // painted by MacWSMetalView. Route pointer/gesture records against that
    // same graph; SkyLight's independent global routing order can disagree
    // after captured windows are repositioned. The zero-target broker route
    // remains only for pixels without a rendered owner layer.
    if (_streamMode == MacWSStreamModeFullscreen &&
        record.kind != MacWSInputKindKeyDown &&
        record.kind != MacWSInputKindKeyUp &&
        record.kind != MacWSInputKindActivateTarget &&
        record.kind != MacWSInputKindDesktopCommand) {
        if (![_metalView routeFullscreenInputRecord:&record]) {
            record.targetPID = 0;
            record.sceneID &= UINT64_C(0x7fffffff);
        }
    }
    NSString *phase = @"?";
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown: phase = @"down"; break;
        case MacWSInputKindTouchMove: phase = @"move"; break;
        case MacWSInputKindTouchUp: phase = @"up"; break;
        case MacWSInputKindTouchCancel: phase = @"cancel"; break;
        case MacWSInputKindHover: phase = @"hover"; break;
        case MacWSInputKindTap: phase = @"tap"; break;
        case MacWSInputKindSecondaryTap: phase = @"secondary"; break;
        case MacWSInputKindScroll: phase = @"scroll"; break;
        case MacWSInputKindMagnify: phase = @"magnify"; break;
        case MacWSInputKindDesktopCommand: phase = @"desktop-command"; break;
        case MacWSInputKindKeyDown: phase = @"key-down"; break;
        case MacWSInputKindKeyUp: phase = @"key-up"; break;
        case MacWSInputKindConfigureWindow: phase = @"configure-window"; break;
        case MacWSInputKindCloseWindow: phase = @"close-window"; break;
        case MacWSInputKindCreateInitialWindow:
            phase = @"create-initial-window"; break;
        default: break;
    }
    int sendError = 0;
    BOOL sent = MacWSSendInputRecord(&record, &sendError);
    _inputLogSequence++;
    BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                      record.kind == MacWSInputKindHover ||
                      record.kind == MacWSInputKindScroll ||
                      record.kind == MacWSInputKindMagnify;
    if (MacWSHostDiagnosticsEnabled() &&
        (!continuous || (_inputLogSequence % 60) == 0)) {
        MacWSLog(@"input-v4 transport=%@ errno=%d scene=%llx target=%d kind=%@ source=%u point=(%.2f,%.2f) frame=%ux%u pressure=%.3f contact=%u sample=%u seq=%llu",
                 sent ? @"sent" : @"failed", sendError, record.sceneID,
                 record.targetPID, phase, record.source, record.x, record.y,
                 record.frameWidth, record.frameHeight,
                 record.pressure, record.contactID, record.sampleSequence,
                 (unsigned long long)_inputLogSequence);
    }
    if (!sent) {
        _inputLabel.text = [NSString stringWithFormat:
            @"触控桥离线 · %@ · errno=%d", phase, sendError];
        [_metalView setMacWSInputEnabled:NO reason:@"触控桥连接已中断"];
        [self refreshStatus];
    } else if (_streamMode == MacWSStreamModeFullscreen &&
               (record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap ||
                record.kind == MacWSInputKindTouchUp)) {
        // A global click can make another real AppKit window key. Refresh the
        // catalog at two bounded settlement points so subsequent keyboard and
        // gesture records follow that owner. This is event-driven, not a
        // frame-time poll.
        for (NSNumber *delay in @[@80, @280]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         delay.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_streamMode == MacWSStreamModeFullscreen)
                    [self->_metalView requestStreamWindowList];
            });
        }
    }
}
@end

static NSUserActivity *MacWSLiveRestorationActivity(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class])
        return scene.session.stateRestorationActivity;
    UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
        .rootViewController;
    if ([root isKindOfClass:MacWSViewController.class])
        return [(MacWSViewController *)root streamRestorationActivity];
    return scene.session.stateRestorationActivity;
}

static void MacWSPruneDeadWindowSceneSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        MacWSViewController *controller = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session == session) {
                activity = MacWSLiveRestorationActivity(scene);
                if ([scene isKindOfClass:UIWindowScene.class]) {
                    UIViewController *root = ((UIWindowScene *)scene)
                        .windows.firstObject.rootViewController;
                    if ([root isKindOfClass:MacWSViewController.class])
                        controller = (MacWSViewController *)root;
                }
                break;
            }
        }
        NSDictionary *info = activity.userInfo;
        uint32_t windowID = 0;
        int32_t ownerPID = 0;
        if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL))
            continue;
        errno = 0;
        if (kill(ownerPID, 0) == 0 || errno != ESRCH) continue;
        if ([info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [controller detachMissingWorkspaceReturnOwnerPID:ownerPID
                                                     windowID:windowID]) {
            continue;
        }
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"runtime-confirmed stale-scene owner-missing id=%@ pid=%d window=%u",
                 identifier, ownerPID, windowID);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"stale-scene destruction failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static void MacWSPruneDormantWorkspaceSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        UIScene *connectedScene = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session != session) continue;
            connectedScene = scene;
            activity = MacWSLiveRestorationActivity(scene);
            break;
        }
        // FrontBoard can retain restoration metadata after its corresponding
        // scene handle has already disappeared. Public destruction returns
        // SBApplicationSupportService/2 for those metadata-only entries, so
        // leave them to UIKit's persistence cleanup and prune only live,
        // dormant workspace Scenes.
        if (!connectedScene) continue;
        NSDictionary *info = activity.userInfo;
        BOOL ownsWindow = MacWSSceneOwnedWindowFields(
            info, NULL, NULL, NULL);
        BOOL fullscreenWorkspace = MacWSSceneIsFullscreenWorkspace(info);
        if (ownsWindow || fullscreenWorkspace ||
            (connectedScene && connectedScene.activationState ==
                UISceneActivationStateForegroundActive)) continue;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"workspace-scene-prune id=%@ state=%ld",
                 identifier, (long)connectedScene.activationState);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"workspace-scene-prune failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static NSString *MacWSSceneWindowIdentity(NSUserActivity *activity) {
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0, groupID = 0;
    if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, &groupID))
        return nil;
    return MacWSWindowIdentity(ownerPID, windowID, groupID);
}

static NSInteger MacWSSceneRetentionRank(UIScene *scene) {
    switch (scene.activationState) {
        case UISceneActivationStateForegroundActive: return 0;
        case UISceneActivationStateForegroundInactive: return 1;
        case UISceneActivationStateBackground: return 2;
        case UISceneActivationStateUnattached: return 3;
    }
    return 4;
}

static void MacWSDeduplicateWindowScenes(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableDictionary<NSString *, NSMutableArray<UIScene *> *> *groups =
        [NSMutableDictionary dictionary];
    for (UIScene *scene in application.connectedScenes) {
        NSString *identity = MacWSSceneWindowIdentity(
            MacWSLiveRestorationActivity(scene));
        if (!identity) continue;
        if (!groups[identity]) groups[identity] = [NSMutableArray array];
        [groups[identity] addObject:scene];
    }
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (NSString *identity in groups) {
        NSArray<UIScene *> *duplicates = [groups[identity]
            sortedArrayUsingComparator:^NSComparisonResult(UIScene *lhs,
                                                            UIScene *rhs) {
                NSInteger leftRank = MacWSSceneRetentionRank(lhs);
                NSInteger rightRank = MacWSSceneRetentionRank(rhs);
                if (leftRank < rightRank) return NSOrderedAscending;
                if (leftRank > rightRank) return NSOrderedDescending;
                return [lhs.session.persistentIdentifier compare:
                    rhs.session.persistentIdentifier];
            }];
        if (duplicates.count <= 1) continue;
        UIScene *keeper = duplicates.firstObject;
        for (NSUInteger index = 1; index < duplicates.count; index++) {
            UISceneSession *session = duplicates[index].session;
            NSString *identifier = session.persistentIdentifier;
            if ([MacWSSceneSessionsPreservingMacWindow
                    containsObject:identifier]) continue;
            [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
            MacWSLog(@"scene-deduplicate identity=%@ keep=%@ discard=%@",
                     identity, keeper.session.persistentIdentifier,
                     identifier);
            [application requestSceneSessionDestruction:session
                options:nil errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:identifier];
                    MacWSLog(@"scene-deduplicate failed id=%@ error=%@",
                             identifier, error);
                }];
        }
    }
}

@interface MacWSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MacWSSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    NSUserActivity *activity = connectionOptions.userActivities.anyObject;
    BOOL connectionHasExactWindow =
        [activity.userInfo[@"mode"] unsignedIntValue] ==
            MacWSStreamModeWindow &&
        [activity.userInfo[@"window_id"] unsignedIntValue] != 0;
    if (!connectionHasExactWindow) {
        NSUserActivity *persisted = MacWSPersistedSceneActivity(
            session.persistentIdentifier);
        activity = persisted ?: activity ?: session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        BOOL emptyWorkspace =
            [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [info[@"return_window_id"] unsignedIntValue] == 0;
        if (emptyWorkspace) {
            activity = MacWSRecoverOrphanedWorkspaceActivity(session) ?:
                activity;
        }
    }
    MacWSStreamMode streamMode = (MacWSStreamMode)
        [activity.userInfo[@"mode"] unsignedIntValue];
    uint32_t windowID = [activity.userInfo[@"window_id"] unsignedIntValue];
    int32_t ownerPID = (int32_t)[activity.userInfo[@"owner_pid"] intValue];
    uint32_t logicalGroupID =
        [activity.userInfo[@"logical_group_id"] unsignedIntValue];
    CGSize minimumSize = CGSizeMake(
        [activity.userInfo[@"minimum_width"] doubleValue],
        [activity.userInfo[@"minimum_height"] doubleValue]);
    CGSize preferredSize = CGSizeMake(
        [activity.userInfo[@"preferred_width"] doubleValue],
        [activity.userInfo[@"preferred_height"] doubleValue]);
    BOOL resizable = [activity.userInfo[@"resizable"] boolValue];
    if (streamMode != MacWSStreamModeWindow || windowID == 0) {
        streamMode = MacWSStreamModeFullscreen;
        windowID = 0;
        ownerPID = 0;
        logicalGroupID = 0;
        minimumSize = CGSizeZero;
        preferredSize = CGSizeZero;
        resizable = NO;
    }
    NSString *shortID = session.persistentIdentifier;
    if (shortID.length > 8) shortID = [shortID substringToIndex:8];
    NSString *requestedTitle = activity.userInfo[@"title"];
    windowScene.title = requestedTitle.length ? requestedTitle :
        [NSString stringWithFormat:@"MacWS %@", shortID];
    MacWSViewController *controller = [[MacWSViewController alloc]
        initWithSceneIdentifier:session.persistentIdentifier
                     streamMode:streamMode windowID:windowID
                       ownerPID:ownerPID logicalGroupID:logicalGroupID
                    minimumSize:minimumSize
                  preferredSize:preferredSize
                      resizable:resizable];
    [controller restoreWorkspaceReturnFromActivity:activity];
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    // Scene restoration can reconnect directly in fullscreen mode without
    // passing through openFullscreenWorkspace. Re-assert and log UIKit's
    // authoritative status-bar/Home-Indicator policy after the real window
    // is visible so cold launch and interactive transition share the same
    // immersive postconditions.
    [controller updateImmersivePresentation];
    if (streamMode == MacWSStreamModeWindow && windowID != 0)
        MacWSRequestNativeSceneSizeWithRole(
            windowScene, preferredSize, NO);
    MacWSRememberSceneBinding(session, [controller streamRestorationActivity]);
    MacWSLog(@"scene-connected id=%@ role=%@ mode=%u window=%u",
             session.persistentIdentifier, session.role, streamMode, windowID);
    NSString *FBSSceneIdentifier = [windowScene respondsToSelector:
        @selector(_sceneIdentifier)] ? [windowScene _sceneIdentifier] : nil;
    MacWSLog(@"scene-geometry id=%@ fbs=%@ bounds=%.1fx%.1f preferred=%.1fx%.1f minimum=%.1fx%.1f resizable=%@",
             session.persistentIdentifier, FBSSceneIdentifier ?: @"missing",
             windowScene.coordinateSpace.bounds.size.width,
             windowScene.coordinateSpace.bounds.size.height,
             preferredSize.width, preferredSize.height, minimumSize.width,
             minimumSize.height, resizable ? @"YES" : @"NO");
    NSString *replacedIdentifier =
        [activity.userInfo[@"replaces_session_identifier"]
            isKindOfClass:NSString.class]
        ? activity.userInfo[@"replaces_session_identifier"] : nil;
    if (replacedIdentifier.length) {
        if (!MacWSSceneSessionsPreservingMacWindow)
            MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
        [MacWSSceneSessionsPreservingMacWindow addObject:replacedIdentifier];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UISceneSession *replacedSession = nil;
            for (UISceneSession *candidate in
                    UIApplication.sharedApplication.openSessions) {
                if ([candidate.persistentIdentifier
                        isEqualToString:replacedIdentifier]) {
                    replacedSession = candidate;
                    break;
                }
            }
            if (!replacedSession) {
                [MacWSSceneSessionsPreservingMacWindow
                    removeObject:replacedIdentifier];
                MacWSLog(@"scene-windowed-replacement old-already-gone old=%@ new=%@",
                         replacedIdentifier, session.persistentIdentifier);
                return;
            }
            MacWSSetPersistedSceneBinding(replacedIdentifier, nil);
            MacWSLog(@"scene-windowed-replacement connected old=%@ new=%@ window=%u bounds=%@",
                     replacedIdentifier, session.persistentIdentifier,
                     windowID, NSStringFromCGRect(self.window.bounds));
            [UIApplication.sharedApplication
                requestSceneSessionDestruction:replacedSession options:nil
                errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:replacedIdentifier];
                    MacWSLog(@"scene-windowed-replacement old-destruction-failed old=%@ new=%@ error=%@",
                             replacedIdentifier,
                             session.persistentIdentifier, error);
                }];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSDeduplicateWindowScenes();
        });
    }
    if (connectionOptions.URLContexts.count) {
        [controller cancelBootstrapTerminal];
        NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scene:scene openURLContexts:contexts];
        });
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    (void)scene;
    [(MacWSViewController *)self.window.rootViewController resumeSceneStream];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    (void)scene;
    [(MacWSViewController *)self.window.rootViewController
        reassertFullscreenScenePresentation];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    (void)scene;
    [(MacWSViewController *)self.window.rootViewController suspendSceneStream];
}

- (void)windowScene:(UIWindowScene *)windowScene
 didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
       interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
            traitCollection:(UITraitCollection *)previousTraitCollection {
    (void)windowScene;
    (void)previousCoordinateSpace;
    (void)previousInterfaceOrientation;
    (void)previousTraitCollection;
    [(MacWSViewController *)self.window.rootViewController
        sceneGeometryDidChange];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Disconnect alone can be ordinary resource reclamation. Close only after
    // UIKit has actually removed the persistent session from openSessions.
    UISceneSession *session = scene.session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([UIApplication.sharedApplication.openSessions containsObject:session])
            return;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
            MacWSLog(@"scene-disconnect preserved id=%@ mac-window=preserved",
                     identifier);
            return;
        }
        MacWSCloseMacWindowForSceneSession(session, @"disconnect-discarded");
    });
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if ([context.URL.host isEqualToString:@"toggle-workspace"]) {
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if (controller) [controller openFullscreenWorkspace];
            break;
        }
        if ([context.URL.host isEqualToString:@"new"]) {
            uint32_t windowID = 0;
            int32_t ownerPID = 0;
            NSString *title = nil;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"window"])
                    windowID = item.value.intValue;
                else if ([item.name isEqualToString:@"pid"])
                    ownerPID = item.value.intValue;
                else if ([item.name isEqualToString:@"title"])
                    title = item.value;
            }
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if ([controller isFullscreenWorkspace] && windowID != 0 &&
                ownerPID > 1) {
                [controller activateMacWindowIDInFullscreenWorkspace:windowID
                    ownerPID:ownerPID title:title];
                break;
            }
            MacWSRequestNewScene(scene, windowID, ownerPID, 0,
                                 CGSizeZero, CGSizeZero, NO, title,
                                 ^(NSError *error) {
                if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                    error.code == 2 && windowID != 0 && ownerPID > 1) {
                    MacWSViewController *controller =
                        (MacWSViewController *)self.window.rootViewController;
                    [controller openWindowIDInCurrentScene:windowID
                        ownerPID:ownerPID logicalGroupID:0 title:title
                        reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                }
            });
            break;
        }
        if ([context.URL.host isEqualToString:@"test-input"]) {
            // Explicit transport diagnostic. Query parameters allow two-point
            // cursor A/Bs or a complete down/move/up transaction without
            // fabricating UIKit touches:
            // macwshost://test-input?kind=down&x=1194&y=834&w=2388&h=1668
            uint32_t frameWidth = 2388;
            uint32_t frameHeight = 1668;
            float x = 1194.0f;
            float y = 834.0f;
            float scrollX = 0.0f;
            float scrollY = 0.0f;
            NSString *scrollPhase = @"changed";
            NSString *requestedKind = @"hover";
            BOOL diagnosticDoubleTap = NO;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"x"]) x = item.value.floatValue;
                else if ([item.name isEqualToString:@"y"]) y = item.value.floatValue;
                else if ([item.name isEqualToString:@"w"]) frameWidth = item.value.intValue;
                else if ([item.name isEqualToString:@"h"]) frameHeight = item.value.intValue;
                else if ([item.name isEqualToString:@"dx"]) scrollX = item.value.floatValue;
                else if ([item.name isEqualToString:@"dy"]) scrollY = item.value.floatValue;
                else if ([item.name isEqualToString:@"phase"] && item.value.length)
                    scrollPhase = item.value.lowercaseString;
                else if ([item.name isEqualToString:@"kind"] && item.value.length)
                    requestedKind = item.value.lowercaseString;
            }
            if (frameWidth == 0) frameWidth = 2388;
            if (frameHeight == 0) frameHeight = 1668;
            x = fminf(fmaxf(x, 0.0f), frameWidth - 1.0f);
            y = fminf(fmaxf(y, 0.0f), frameHeight - 1.0f);
            MacWSInputRecord record = {
                .magic = MACWS_INPUT_MAGIC,
                .version = MACWS_INPUT_VERSION,
                .kind = MacWSInputKindHover,
                .sceneID = ((uint64_t)scene.session.persistentIdentifier.hash) &
                    ~MACWS_INPUT_WINDOW_SCENE_FLAG,
                .timestamp = CACurrentMediaTime(),
                .x = x,
                .y = y,
                .contactID = MACWS_INPUT_CONTACT_DIAGNOSTIC,
                .frameWidth = frameWidth,
                .frameHeight = frameHeight,
                .targetPID = 0,
                .source = MacWSInputSourceUnknown,
            };
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            uint32_t targetWindowID = (uint32_t)[[controller
                valueForKey:@"windowID"] unsignedIntValue];
            int32_t targetOwnerPID = (int32_t)[[controller
                valueForKey:@"windowOwnerPID"] intValue];
            record.targetPID = targetWindowID != 0 ? targetOwnerPID : 0;
            if (targetWindowID != 0)
                record.sceneID = MacWSInputSceneForWindow(targetWindowID, 0);
            if ([requestedKind isEqualToString:@"tap"])
                record.kind = MacWSInputKindTap;
            else if ([requestedKind isEqualToString:@"double"]) {
                // Transport-only end-to-end witness for the same two physical
                // tap records emitted by direct touch. The title bar uses the
                // native CGPostMouseEvent route, whose double-click state is
                // derived from the ordered button transitions rather than the
                // NSEvent clickCount field, so diagnostics must preserve both
                // taps instead of fabricating one clickCount=2 event.
                record.kind = MacWSInputKindTap;
                diagnosticDoubleTap = YES;
            }
            else if ([requestedKind isEqualToString:@"secondary"])
                record.kind = MacWSInputKindSecondaryTap;
            else if ([requestedKind isEqualToString:@"down"])
                record.kind = MacWSInputKindTouchDown;
            else if ([requestedKind isEqualToString:@"move"])
                record.kind = MacWSInputKindTouchMove;
            else if ([requestedKind isEqualToString:@"up"])
                record.kind = MacWSInputKindTouchUp;
            else if ([requestedKind isEqualToString:@"cancel"])
                record.kind = MacWSInputKindTouchCancel;
            else if ([requestedKind isEqualToString:@"scroll"]) {
                record.kind = MacWSInputKindScroll;
                record.pressure = scrollY;
                memcpy(&record.contactID, &scrollX, sizeof(scrollX));
                record.flags = [scrollPhase isEqualToString:@"began"]
                    ? MacWSInputFlagScrollBegan
                    : [scrollPhase isEqualToString:@"ended"]
                        ? MacWSInputFlagScrollEnded
                        : [scrollPhase isEqualToString:@"cancelled"]
                            ? MacWSInputFlagScrollCancelled
                            : MacWSInputFlagScrollChanged;
                record.source = MacWSInputSourceFinger;
            }
            // Exercise the same controller boundary as a real UIKit touch.
            // Besides transport this schedules the post-AppKit window catalog
            // refresh required when a native tab selection swaps CGWindowID.
            [controller metalView:nil emittedInput:record];
            if (diagnosticDoubleTap) {
                MacWSInputRecord secondTap = record;
                secondTap.flags |= MacWSInputFlagDoubleClick;
                secondTap.timestamp += 0.10;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    [controller metalView:nil emittedInput:secondTap];
                });
            }
            MacWSLog(@"input-v4 synthetic kind=%@ routed-through-controller scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                     requestedKind, record.sceneID, record.targetPID,
                     record.x, record.y, record.frameWidth,
                     record.frameHeight);
            break;
        }
        NSString *host = context.URL.host ?: @"status";
        if ([@[@"status", @"start", @"start-experimental", @"stop",
               @"glassdemo", @"terminal", @"vscode", @"activity-monitor", @"finder",
               @"system-settings", @"maps",
               @"recover", @"repair", @"capture",
               @"test-open-file", @"fullscreen",
               @"enter-workspace", @"exit-workspace",
               @"close-window",
               @"screenshot-ui", @"screenshot-screen",
               @"performance-snapshot",
               @"hide-controls", @"show-controls"]
              containsObject:host]) {
            MacWSViewController *controller = (MacWSViewController *)self.window.rootViewController;
            [controller performURLAction:host];
            break;
        }
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    NSUserActivity *activity = [controller streamRestorationActivity];
    MacWSRememberSceneBinding(scene.session, activity);
    return activity;
}
@end

@interface MacWSAppDelegate : UIResponder <UIApplicationDelegate>
@end

extern void MacWSRunIOSClearReference(void);

@implementation MacWSAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)launchOptions;
    id<MTLDevice> nativeDevice = MTLCreateSystemDefaultDevice();
    MacWSLog(@"launched native-device=%@ supportsMultiple=%@ "
             "display-transport=IOSurface legacy-mmap=%@ frame-path=%@",
             nativeDevice.name,
             application.supportsMultipleScenes ? @"YES" : @"NO",
             MacWSLegacyFramebufferFallbackEnabled() ? @"enabled" : @"disabled",
             MacWSFramePath);
    MacWSLogMetalRegistryState();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        MacWSLaunchMapsNotificationCallback,
        MacWSLaunchMapsFromHostNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        MacWSPruneDeadWindowSceneSessions();
        MacWSPruneDormantWorkspaceSessions();
    });
    // Diagnostic-only native AGX reference.  Keeping this behind a sentinel
    // lets the established, FrontBoard-launched host provide the foreground
    // GPU context needed for a trustworthy iOS command-ABI capture without
    // changing normal host startup or its scene lifecycle.
    if (access("/var/mobile/iosclear_run", F_OK) == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MacWSLog(@"IOSCLEAR reference requested by sentinel");
            MacWSRunIOSClearReference();
        });
    }
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *configuration =
        [UISceneConfiguration configurationWithName:@"MacWS Window"
                                        sessionRole:connectingSceneSession.role];
    configuration.sceneClass = UIWindowScene.class;
    configuration.delegateClass = MacWSSceneDelegate.class;
    return configuration;
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    (void)application;
    for (UISceneSession *session in sceneSessions) {
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneBindings removeObjectForKey:identifier];
            MacWSSetPersistedSceneBinding(identifier, nil);
            MacWSLog(@"scene-discard duplicate-only id=%@ mac-window=preserved",
                     identifier);
            continue;
        }
        MacWSCloseMacWindowForSceneSession(session, @"did-discard");
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(MacWSAppDelegate.class));
    }
}
