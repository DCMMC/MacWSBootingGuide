#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#import "MacWSControlClient.h"
#import "MacWSInteropClient.h"
#import "MacWSMenuClient.h"
#import "MacWSStreamClient.h"
#include "macws_control_protocol.h"
#include "macws_host_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

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
static const char MacWSInputSocketPath[] =
    "/var/mnt/rootfs/private/tmp/macws_host_input.sock";

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

static CGFloat MacWSDensityModeFactor(MacWSHostDisplayDensity density) {
    return density == MacWSHostDisplayDensityKeyboard ? 0.85 : 1.0;
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

static uint32_t MacWSKeySymForHIDUsage(NSInteger usage, NSString *characters) {
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
    if (characters.length == 0) return 0;
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
    UITouch *_directTouch;
    UITouch *_secondaryPointerTouch;
    BOOL _directGestureBlocked;
    MacWSDirectTouchState _directTouchState;
    CGPoint _directTouchStartPoint;
    CGPoint _directTouchPreviousPoint;
    CGPoint _directScrollVelocity;
    CGPoint _directScrollFramePoint;
    NSTimeInterval _directTouchStartTimestamp;
    NSTimeInterval _directTouchPreviousTimestamp;
    uint64_t _directTouchSerial;
    UIImpactFeedbackGenerator *_directTouchFeedback;
    CGFloat _viewportZoom;
    CGPoint _viewportCenter;
    CGFloat _fixedZoomScale;
    BOOL _contentGesturesPassthrough;
    UIPanGestureRecognizer *_twoFingerPanRecognizer;
    CADisplayLink *_scrollMomentumDisplayLink;
    CGPoint _scrollMomentumVelocity;
    CGPoint _scrollMomentumFramePoint;
    CFTimeInterval _scrollMomentumLastTimestamp;
    BOOL _scrollMomentumBegan;
    BOOL _windowConfigurationDispatchPending;
    CGSize _pendingRequestedWindowSize;
    CGFloat _pendingRequestedDensityScale;
    uint32_t _inputSampleSequence;
    CGSize _lastRequestedWindowSize;
    CGFloat _lastRequestedDensityScale;
    uint64_t _windowConfigurationSettlementSerial;
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

    // iPad's indirect pointer is a material circle rather than a desktop
    // arrow.  Keep it visible in trackpad mode between gestures, with a fine
    // rim and a small shadow so it remains legible over light and dark apps.
    _trackpadCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 24, 24)];
    _trackpadCursorView.backgroundColor =
        [UIColor colorWithWhite:0.68 alpha:0.92];
    _trackpadCursorView.layer.borderWidth = 0.75;
    _trackpadCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.92].CGColor;
    _trackpadCursorView.layer.cornerRadius = 12;
    _trackpadCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _trackpadCursorView.layer.shadowOpacity = 0.34;
    _trackpadCursorView.layer.shadowRadius = 4.5;
    _trackpadCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _trackpadCursorView.userInteractionEnabled = NO;
    _trackpadCursorView.hidden = YES;
    [self addSubview:_trackpadCursorView];

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
        [self addGestureRecognizer:hover];
    }
    _twoFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(twoFingerPanned:)];
    _twoFingerPanRecognizer.minimumNumberOfTouches = 2;
    _twoFingerPanRecognizer.maximumNumberOfTouches = 2;
    _twoFingerPanRecognizer.cancelsTouchesInView = YES;
    _twoFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_twoFingerPanRecognizer];
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
    _lastRequestedWindowSize = CGSizeZero;
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
    _sourceTexture = nil;
    _textureWidth = 0;
    _textureHeight = 0;
    _contentRect = CGRectZero;
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
    _targetPID = targetPID;
    [self refreshPresentationPolicy];
}

- (void)setDisplayDensity:(MacWSHostDisplayDensity)displayDensity {
    if (displayDensity != MacWSHostDisplayDensityTouchComfort &&
        displayDensity != MacWSHostDisplayDensityKeyboard) return;
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
            MacWSHostDisplayDensityKeyboard ? @"更多空间" : @"像素匹配 Retina";
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
            key.keyCode, key.characters);
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

    if (directSurface && _overlayFrames.count) {
        NSArray<NSNumber *> *overlayKeys = [_overlayFrames.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(
                NSNumber *lhs, NSNumber *rhs) {
                MacWSStreamFrameDescriptor left =
                    _overlayFrames[lhs].descriptor;
                MacWSStreamFrameDescriptor right =
                    _overlayFrames[rhs].descriptor;
                if (left.layerLevel < right.layerLevel)
                    return NSOrderedAscending;
                if (left.layerLevel > right.layerLevel)
                    return NSOrderedDescending;
                return [lhs compare:rhs];
            }];
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
        for (NSNumber *key in overlayKeys) {
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
    if (submittedFrame && (submittedFrame.descriptor.sequence % 120) == 0) {
        uint64_t captureTime = submittedFrame.descriptor.displayTime;
        uint64_t receiptTime = submittedFrame.receiptTime;
        uint64_t sequence = submittedFrame.descriptor.sequence;
        uint64_t streamID = submittedFrame.descriptor.streamID;
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
            @"%u×%u  ·  DisplayStream #%llu  ·  IOSurface 直传",
            presentedWidth, presentedHeight,
            (unsigned long long)submittedFrame.descriptor.sequence]];
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
        if (showTrackpad) _trackpadCursorView.center = pointerCenter;
    }
    _trackpadCursorView.hidden = !showTrackpad;
    if (showTrackpad) [self bringSubviewToFront:_trackpadCursorView];
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

- (void)emitKind:(MacWSInputKind)kind touch:(UITouch *)touch point:(CGPoint)viewPoint {
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
        .flags = inputFlags,
        .altitude = altitude,
        .azimuth = azimuth,
        .tiltX = tiltX,
        .tiltY = tiltY,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (source != MacWSInputSourceIndirectPointer &&
        self.inputMode == MacWSHostInputModeDirect) {
        _directTouchIndicator.center = viewPoint;
        _directTouchIndicator.hidden = kind == MacWSInputKindTouchUp ||
                                       kind == MacWSInputKindTouchCancel;
        if (!_directTouchIndicator.hidden)
            [self bringSubviewToFront:_directTouchIndicator];
    }
}

- (void)emitTouches:(NSSet<UITouch *> *)touches kind:(MacWSInputKind)kind {
    for (UITouch *touch in touches)
        [self emitKind:kind touch:touch point:[touch locationInView:self]];
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
    _directTouchIndicator.hidden = YES;
}

- (void)beginDirectTouchCandidate:(UITouch *)touch {
    _directTouch = touch;
    _directTouchState = MacWSDirectTouchStateCandidate;
    _directTouchStartPoint = [touch locationInView:self];
    _directTouchPreviousPoint = _directTouchStartPoint;
    _directScrollVelocity = CGPointZero;
    _directScrollFramePoint = CGPointZero;
    _directTouchStartTimestamp = touch.timestamp;
    _directTouchPreviousTimestamp = touch.timestamp;
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
    if (pointerTouch) {
        if (@available(iOS 13.4, *)) {
            if ((event.buttonMask & UIEventButtonMaskSecondary) != 0) {
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
    if (pointerTouch) {
        if (touch != _secondaryPointerTouch)
            [self emitTouches:touches kind:MacWSInputKindTouchMove];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            CGFloat travel = hypot(point.x - _directTouchStartPoint.x,
                                   point.y - _directTouchStartPoint.y);
            MacWSTouchCandidateDecision decision =
                MacWSDecideTouchCandidate(
                    _directTouch.timestamp - _directTouchStartTimestamp,
                    travel, false);
            if (_directTouchState == MacWSDirectTouchStateCandidate &&
                decision == MacWSTouchCandidateDecisionScroll) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateScrolling;
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
            _trackpadCursor.x = fmin(fmax(_trackpadCursor.x + dx * scaleX * 0.82,
                                          0.0), [self currentFrameWidth] - 1.0);
            _trackpadCursor.y = fmin(fmax(_trackpadCursor.y + dy * scaleY * 0.82,
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
            [self setNeedsDisplay];
        }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else
            [self emitTouches:touches kind:MacWSInputKindTouchUp];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            if (_directTouchState == MacWSDirectTouchStateCandidate) {
                MacWSTouchCandidateDecision decision = MacWSDecideTouchCandidate(
                    _directTouch.timestamp - _directTouchStartTimestamp,
                    hypot(point.x - _directTouchStartPoint.x,
                          point.y - _directTouchStartPoint.y), true);
                if (decision == MacWSTouchCandidateDecisionLongPress) {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                    [_directTouchFeedback impactOccurred];
                } else if (decision == MacWSTouchCandidateDecisionTap) {
                    [self emitKind:MacWSInputKindTap
                             touch:_directTouch point:point];
                } else if (decision == MacWSTouchCandidateDecisionScroll) {
                    // Preserve a quick flick even when UIKit coalesces it to a
                    // final sample; movement in direct mode is scrolling, not
                    // an implicit primary-button drag.
                    CGPoint framePoint = CGPointZero;
                    if ([self framePointForViewPoint:point output:&framePoint]) {
                        CGPoint delta = CGPointMake(
                            point.x - _directTouchStartPoint.x,
                            point.y - _directTouchStartPoint.y);
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:MacWSInputFlagScrollBegan
                                           timestamp:_directTouchStartTimestamp];
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:MacWSInputFlagScrollEnded
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchStartTimestamp, 1.0 / 120.0);
                        [self startScrollMomentumWithVelocity:
                            CGPointMake(delta.x / dt, delta.y / dt)
                                                   framePoint:framePoint];
                    }
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateLongPressArmed) {
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
                [self emitKind:MacWSInputKindTouchUp touch:_directTouch
                         point:point];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                CGPoint framePoint = _directScrollFramePoint;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                    }
                    _directScrollFramePoint = framePoint;
                }
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:MacWSInputFlagScrollEnded
                                   timestamp:_directTouch.timestamp];
                [self startScrollMomentumWithVelocity:_directScrollVelocity
                                           framePoint:_directScrollFramePoint];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
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
    if (pointerTouch) {
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
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _contentGesturesPassthrough = NO;
    [self updateZoomHUD];
    [self setNeedsDisplay];
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

- (BOOL)scrollFramePointForRecognizer:(UIPanGestureRecognizer *)recognizer
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
    float horizontal = (float)(-translation.x * scaleX);
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
        .pressure = (float)(-translation.y * scaleY),
        .contactID = horizontalBits,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
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
    if (hypot(velocity.x, velocity.y) < 80.0) return;
    [self stopScrollMomentumWithTerminalPhase:NO];
    _scrollMomentumVelocity = velocity;
    _scrollMomentumFramePoint = framePoint;
    _scrollMomentumBegan = NO;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumDisplayLink = [CADisplayLink
        displayLinkWithTarget:self selector:@selector(scrollMomentumTick:)];
    _scrollMomentumDisplayLink.preferredFramesPerSecond = 60;
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
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollEnded
                               timestamp:CACurrentMediaTime()];
            CGPoint velocity = [recognizer velocityInView:self];
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
    texture.label = [NSString stringWithFormat:@"MacWS stream %llu frame %llu",
        (unsigned long long)frame.descriptor.streamID,
        (unsigned long long)frame.descriptor.sequence];

    if ((frame.descriptor.flags & MacWSStreamFrameOverlay) != 0) {
        NSNumber *key = @(frame.descriptor.layerWindowID);
        MacWSSurfaceFrame *previous = _overlayFrames[key];
        if (previous) [_retiredSurfaceFrames addObject:previous];
        _overlayFrames[key] = frame;
        _overlayTextures[key] = texture;
        _streamConnected = YES;
        [self setNeedsDisplay];
        return;
    }

    MacWSSurfaceFrame *previous = _surfaceFrame;
    if (previous) {
        if (previous.descriptor.sequence == _submittedSurfaceSequence)
            [_retiredSurfaceFrames addObject:previous];
        else
            [client releaseFrame:previous];
    }
    _surfaceFrame = frame;
    _surfaceTexture = texture;
    _streamConnected = YES;
    // DisplayStream is now authoritative. Stop polling the legacy mmap
    // acknowledgement files until this Scene changes streams or disconnects.
    _framePollDisplayLink.paused = YES;
    [self updatePresentationGeometry];
    [self scheduleWindowConfiguration];
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
                               resizable:(BOOL)resizable;
- (void)performURLAction:(NSString *)action;
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
@end

static void MacWSRequestNewScene(UIScene *requestingScene,
                                 uint32_t windowID,
                                 int32_t ownerPID,
                                 uint32_t logicalGroupID,
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
            if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeWindow ||
                [info[@"owner_pid"] intValue] != ownerPID) continue;
            uint32_t candidateGroup =
                [info[@"logical_group_id"] unsignedIntValue];
            uint32_t candidateWindow = [info[@"window_id"] unsignedIntValue];
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
    [application requestSceneSessionActivation:existingSession
                                  userActivity:activity
                                       options:nil
                                  errorHandler:^(NSError *error) {
        MacWSLog(@"scene-activation failed: %@", error);
        if (failureHandler) failureHandler(error);
    }];
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
    if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeWindow ||
        [info[@"window_id"] unsignedIntValue] == 0 ||
        [info[@"owner_pid"] intValue] <= 1) return nil;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [info[@"title"] isKindOfClass:NSString.class]
        ? info[@"title"] : @"MacWS Window";
    activity.userInfo = info;
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
    uint32_t windowID = [info[@"window_id"] unsignedIntValue];
    int32_t ownerPID = [info[@"owner_pid"] intValue];
    if ([info[@"mode"] unsignedIntValue] == MacWSStreamModeWindow &&
        windowID != 0 && ownerPID > 1) {
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
    uint32_t windowID = [info[@"window_id"] unsignedIntValue];
    int32_t ownerPID = [info[@"owner_pid"] intValue];
    if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeWindow ||
        windowID == 0 || ownerPID <= 1) return NO;
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
    [self dismissViewControllerAnimated:NO completion:^{
        if (selection) selection(item);
    }];
}

@end

@implementation MacWSViewController {
    NSString *_sceneIdentifier;
    MacWSStreamMode _streamMode;
    uint32_t _windowID;
    int32_t _windowOwnerPID;
    uint32_t _windowGroupID;
    CGSize _windowMinimumSize;
    BOOL _windowResizable;
    MacWSControlClient *_controlClient;
    MacWSInteropClient *_interopClient;
    MacWSMenuClient *_menuClient;
    MacWSMenuSnapshot *_menuSnapshot;
    UIVisualEffectView *_semanticMenuBar;
    UIScrollView *_semanticMenuScroll;
    UIStackView *_semanticMenuTitles;
    UIViewController *_semanticMenuPanel;
    UIVisualEffectView *_controlPanel;
    UIControl *_controlDismissLayer;
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
    BOOL _bootstrapTerminalPending;
    BOOL _bootstrapWorkspaceStartInFlight;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                               resizable:(BOOL)resizable {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sceneIdentifier = [identifier copy];
        _streamMode = streamMode;
        _windowID = windowID;
        _windowOwnerPID = windowID ? ownerPID : 0;
        _windowGroupID = windowID ? logicalGroupID : 0;
        _windowMinimumSize = windowID ? minimumSize : CGSizeZero;
        _windowResizable = windowID ? resizable : NO;
        _bootstrapTerminalPending = streamMode != MacWSStreamModeWindow ||
            windowID == 0;
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
    [_semanticMenuBar setNeedsLayout];
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
            [self->_menuClient performItem:item inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *error) {
                    if (status == MacWSMenuStatusOK) {
                        [self setNotice:[NSString stringWithFormat:
                            @"已发送“%@”", item.title] success:YES];
                    } else {
                        [self setNotice:error.localizedDescription ?: @"菜单项无法执行"
                                 success:NO];
                        [self refreshSemanticMenuWithCompletion:nil];
                    }
                }];
        }];
    UIPopoverPresentationController *popover = panel.popoverPresentationController;
    popover.sourceView = source;
    popover.sourceRect = source.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionUp |
        UIPopoverArrowDirectionDown;
    _semanticMenuPanel = panel;
    [self presentViewController:panel animated:YES completion:nil];
}

- (void)semanticMenuTitleTapped:(UIButton *)sender {
    uint32_t siblingIndex = UINT32_MAX;
    if (sender.tag >= 0) {
        MacWSMenuItem *old = [_menuSnapshot itemWithID:(uint64_t)sender.tag];
        siblingIndex = old.siblingIndex;
    }
    sender.enabled = NO;
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
    if (savedDensity != MacWSHostDisplayDensityKeyboard)
        savedDensity = MacWSHostDisplayDensityTouchComfort;
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

    _controlPanel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlPanel.layer.cornerRadius = 22;
    _controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _controlPanel.clipsToBounds = YES;
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
    _applicationButtons = @[glassDemo, terminal, activity, finder, vscode];
    UIStackView *appRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[glassDemo, terminal]];
    UIStackView *appRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[activity, finder]];
    UIStackView *appRow3 = [[UIStackView alloc] initWithArrangedSubviews:@[vscode]];
    for (UIStackView *row in @[appRow1, appRow2, appRow3]) {
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
        initWithItems:@[@"像素匹配 Retina", @"更多空间 +18%"]];
    _densityControl.selectedSegmentIndex =
        _metalView.displayDensity == MacWSHostDisplayDensityKeyboard ? 1 : 0;
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

    _showControlsButton = [self buttonWithTitle:@"控制中心" image:@"sidebar.left"
                                         action:@selector(showControls) prominent:YES];
    _showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _showControlsButton.hidden = YES;
    if (_semanticMenuBar) {
        UIButtonConfiguration *configuration =
            [UIButtonConfiguration plainButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:@"switch.2"];
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(3, 5, 3, 5);
        _showControlsButton.configuration = configuration;
        _showControlsButton.accessibilityLabel = @"MacWS 控制中心";
        [_semanticMenuBar.contentView addSubview:_showControlsButton];
    } else {
        [root addSubview:_showControlsButton];
    }

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
    ]];
    if (_semanticMenuBar) {
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [_semanticMenuBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [_semanticMenuBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [_semanticMenuBar.heightAnchor constraintEqualToConstant:26],
            [_showControlsButton.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor constant:-4],
            [_showControlsButton.centerYAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.centerYAnchor],
            [_showControlsButton.widthAnchor constraintEqualToConstant:32],
            [_showControlsButton.heightAnchor constraintEqualToConstant:24],
        ]];
        // A native macOS window should open as content, not as a settings
        // sheet. Keep the compact menu visible and expose Control Center as a
        // small explicit affordance; fullscreen/bootstrap scenes still open
        // with controls shown.
        _controlPanel.hidden = YES;
        _showControlsButton.hidden = NO;
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [_showControlsButton.leadingAnchor constraintEqualToAnchor:
                safe.leadingAnchor constant:12],
            [_showControlsButton.topAnchor constraintEqualToAnchor:
                controlTop constant:12],
        ]];
    }
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
    _showControlsButton.hidden = NO;
}

- (void)showControls {
    _controlDismissLayer.hidden = NO;
    _controlPanel.hidden = NO;
    _showControlsButton.hidden = YES;
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
    MacWSHostDisplayDensity density = sender.selectedSegmentIndex == 1
        ? MacWSHostDisplayDensityKeyboard
        : MacWSHostDisplayDensityTouchComfort;
    _metalView.displayDensity = density;
    [NSUserDefaults.standardUserDefaults setInteger:density
                                              forKey:@"MacWSDisplayDensity"];
    _inputLabel.text = density == MacWSHostDisplayDensityKeyboard
        ? [NSString stringWithFormat:
            @"显示：更多空间；当前有效密度 %.0f%%，画布比像素匹配模式多约 18%%",
            _metalView.effectiveDensityScale * 100.0]
        : [NSString stringWithFormat:
            @"显示：像素匹配 Retina；当前有效密度 %.0f%%（随 iPadOS 合成比例自动调整）",
            _metalView.effectiveDensityScale * 100.0];
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
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:@"在新 iPadOS 窗口中打开"
                         message:@"每个 Scene 只订阅一个 macOS 窗口的 IOSurface 流。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(logicalWindows.count, 24);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = logicalWindows[index];
        NSString *title = window.title.length ? window.title :
            [NSString stringWithFormat:@"Window %u", window.descriptor.windowID];
        [picker addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                MacWSRequestNewScene(self.view.window.windowScene,
                    window.descriptor.windowID, window.descriptor.ownerPID,
                    window.descriptor.logicalGroupID,
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
    _windowResizable =
        (window.descriptor.flags & MacWSStreamWindowResizable) != 0;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.targetWindowResizable = _windowResizable;
}

- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason {
    if (windowID == 0 || ownerPID <= 1) return;
    [_metalView suspendStream];
    _streamMode = MacWSStreamModeWindow;
    _windowID = windowID;
    _windowOwnerPID = ownerPID;
    _windowGroupID = logicalGroupID;
    _windowMinimumSize = CGSizeZero;
    _windowResizable = NO;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    _metalView.targetPID = ownerPID;
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
    MacWSRequestNewScene(self.view.window.windowScene, 0, 0, 0,
                         CGSizeZero, NO,
                         @"MacWS Workspace", ^(NSError *error) {
        [self setNotice:error.localizedDescription success:NO];
    });
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
    BOOL activeAppInput = [status[@"app_input_ready"] boolValue];
    int32_t activeAppPID = (int32_t)[status[@"active_app_pid"] intValue];
    int32_t targetPID = _streamMode == MacWSStreamModeWindow
        ? _windowOwnerPID : activeAppPID;
    BOOL appInput = _streamMode == MacWSStreamModeWindow
        ? MacWSAppInputEndpointReady(targetPID) : activeAppInput;
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
            : (targetPID > 1 ? @"在线 · 等待应用输入端点" : @"在线 · 等待应用"))
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
    BOOL inputReady = connected && !busy && ws && input && renderableFrame &&
        targetPID > 1 && appInput;
    NSString *inputReason = nil;
    if (!connected) inputReason = @"root 控制服务离线";
    else if (busy) inputReason = @"macOS 正在启动或切换";
    else if (!ws) inputReason = @"macOS 工作区已停止";
    else if (!input) inputReason = @"触控桥离线";
    else if (!renderableFrame) inputReason = @"等待 DisplayStream IOSurface 首帧";
    else if (targetPID <= 1) inputReason = _streamMode == MacWSStreamModeWindow
        ? @"等待该窗口的所属应用" : @"请先从控制中心启动一个 macOS 应用";
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
                if ([identifier isEqualToString:@"finder"]) {
                    self->_pendingFinderWindowPID =
                        launchedPID;
                    self->_pendingFinderMenuAttempts = 0;
                    self->_finderMenuRequestInFlight = NO;
                    MacWSLog(@"finder-browser launch-reply pid=%d active=%d",
                             self->_pendingFinderWindowPID,
                             (int32_t)[reply[@"active_app_pid"] intValue]);
                } else if (launchedPID > 1) {
                    self->_pendingApplicationWindowPID = launchedPID;
                    self->_pendingApplicationIdentifier = identifier;
                    self->_pendingApplicationWindowAttempts = 0;
                    self->_pendingApplicationWindowRetryScheduled = NO;
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
    [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
             arguments:@{@MACWS_CONTROL_KEY_APP_ID: sender.accessibilityIdentifier ?: @""}];
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
               [action isEqualToString:@"finder"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: action}];
    } else if ([action isEqualToString:@"recover"]) {
        [self recoverAction];
    } else if ([action isEqualToString:@"repair"]) {
        [self repairAction];
    } else if ([action isEqualToString:@"capture"]) {
        [self captureAction];
    } else if ([action isEqualToString:@"close-window"]) {
        [self closeCurrentWindow];
    } else if ([action isEqualToString:@"screenshot-ui"]) {
        [self writeHostUISnapshot];
    } else if ([action isEqualToString:@"hide-controls"]) {
        [self hideControls];
    } else if ([action isEqualToString:@"show-controls"]) {
        [self showControls];
    }
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    (void)view;
    _statusLabel.text = [@"画面：" stringByAppendingString:status];
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
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID != ownerPID) continue;
        target = window;
        if (window.descriptor.flags & MacWSStreamWindowFocused) break;
    }
    if (!target) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    NSString *identifier = _pendingApplicationIdentifier ?: @"macOS app";
    _pendingApplicationWindowPID = 0;
    _pendingApplicationIdentifier = nil;
    _pendingApplicationWindowAttempts = 0;
    _pendingApplicationWindowRetryScheduled = NO;
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

- (void)openNewMacWindowsFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    if (![self isWindowDiscoveryCoordinator]) return;
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
        NSString *identity = MacWSWindowIdentity(
            [info[@"owner_pid"] intValue],
            [info[@"window_id"] unsignedIntValue],
            [info[@"logical_group_id"] unsignedIntValue]);
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
            NSString *title = stableWindow.title.length
                ? stableWindow.title : @"macOS Window";
            MacWSLog(@"window-auto-scene identity=%@ title=%@ stable-ms=250",
                     identity, title);
            MacWSRequestNewScene(self.view.window.windowScene,
                stableWindow.descriptor.windowID,
                stableWindow.descriptor.ownerPID,
                stableWindow.descriptor.logicalGroupID,
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
            uint32_t resolvedID = resolvedWindow.descriptor.windowID;
            _windowOwnerPID = resolvedWindow.descriptor.ownerPID;
            _windowGroupID = resolvedWindow.descriptor.logicalGroupID;
            _windowMinimumSize = CGSizeMake(
                resolvedWindow.descriptor.minimumLogicalWidth,
                resolvedWindow.descriptor.minimumLogicalHeight);
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
        @"minimum_width": @(_windowMinimumSize.width),
        @"minimum_height": @(_windowMinimumSize.height),
        @"resizable": @(_windowResizable),
        @"title": activity.title,
    };
    return activity;
}

- (void)suspendSceneStream {
    [_semanticMenuPanel dismissViewControllerAnimated:NO completion:nil];
    _semanticMenuPanel = nil;
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
}

- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record {
    (void)view;
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
        case MacWSInputKindKeyDown: phase = @"key-down"; break;
        case MacWSInputKindKeyUp: phase = @"key-up"; break;
        case MacWSInputKindConfigureWindow: phase = @"configure-window"; break;
        case MacWSInputKindCloseWindow: phase = @"close-window"; break;
        default: break;
    }
    int sendError = 0;
    BOOL sent = MacWSSendInputRecord(&record, &sendError);
    _inputLogSequence++;
    BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                      record.kind == MacWSInputKindHover ||
                      record.kind == MacWSInputKindScroll;
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
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session == session) {
                activity = MacWSLiveRestorationActivity(scene);
                break;
            }
        }
        NSDictionary *info = activity.userInfo;
        if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeWindow)
            continue;
        uint32_t windowID = [info[@"window_id"] unsignedIntValue];
        int32_t ownerPID = [info[@"owner_pid"] intValue];
        if (windowID == 0 || ownerPID <= 1) continue;
        errno = 0;
        if (kill(ownerPID, 0) == 0 || errno != ESRCH) continue;
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
        BOOL exactWindow = [info[@"mode"] unsignedIntValue] ==
            MacWSStreamModeWindow &&
            [info[@"window_id"] unsignedIntValue] != 0;
        if (exactWindow || (connectedScene && connectedScene.activationState ==
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
    if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeWindow) return nil;
    int32_t ownerPID = [info[@"owner_pid"] intValue];
    uint32_t windowID = [info[@"window_id"] unsignedIntValue];
    uint32_t groupID = [info[@"logical_group_id"] unsignedIntValue];
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
    BOOL resizable = [activity.userInfo[@"resizable"] boolValue];
    if (streamMode != MacWSStreamModeWindow || windowID == 0) {
        streamMode = MacWSStreamModeFullscreen;
        windowID = 0;
        ownerPID = 0;
        logicalGroupID = 0;
        minimumSize = CGSizeZero;
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
                      resizable:resizable];
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    MacWSRememberSceneBinding(session, [controller streamRestorationActivity]);
    MacWSLog(@"scene-connected id=%@ role=%@ mode=%u window=%u",
             session.persistentIdentifier, session.role, streamMode, windowID);
    SEL restrictionsSelector = NSSelectorFromString(@"sizeRestrictions");
    id restrictions = [windowScene respondsToSelector:restrictionsSelector]
        ? [windowScene valueForKey:@"sizeRestrictions"] : nil;
    SEL minimumSelector = NSSelectorFromString(@"minimumSize");
    SEL maximumSelector = NSSelectorFromString(@"maximumSize");
    NSValue *minimumValue = restrictions && [restrictions
        respondsToSelector:minimumSelector]
        ? [restrictions valueForKey:@"minimumSize"] : nil;
    NSValue *maximumValue = restrictions && [restrictions
        respondsToSelector:maximumSelector]
        ? [restrictions valueForKey:@"maximumSize"] : nil;
    CGSize minimum = minimumValue ? minimumValue.CGSizeValue : CGSizeZero;
    CGSize maximum = maximumValue ? maximumValue.CGSizeValue : CGSizeZero;
    MacWSLog(@"scene-geometry id=%@ bounds=%.1fx%.1f restrictions=%@ min=%.1fx%.1f max=%.1fx%.1f",
             session.persistentIdentifier, windowScene.coordinateSpace.bounds.size.width,
             windowScene.coordinateSpace.bounds.size.height,
             restrictions ? @"present" : @"absent", minimum.width,
             minimum.height, maximum.width, maximum.height);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MacWSDeduplicateWindowScenes();
    });
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
        MacWSCloseMacWindowForSceneSession(session, @"disconnect-discarded");
    });
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
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
            MacWSRequestNewScene(scene, windowID, ownerPID, 0,
                                 CGSizeZero, NO, title, ^(NSError *error) {
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
            // cursor A/Bs or a complete down/up pair without fabricating UIKit
            // touches:
            // macwshost://test-input?kind=tap&x=1194&y=834&w=2388&h=1668
            uint32_t frameWidth = 2388;
            uint32_t frameHeight = 1668;
            float x = 1194.0f;
            float y = 834.0f;
            float scrollX = 0.0f;
            float scrollY = 0.0f;
            NSString *scrollPhase = @"changed";
            NSString *requestedKind = @"hover";
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
            NSDictionary *status = [controller valueForKey:@"latestStatus"];
            uint32_t targetWindowID = (uint32_t)[[controller
                valueForKey:@"windowID"] unsignedIntValue];
            int32_t targetOwnerPID = (int32_t)[[controller
                valueForKey:@"windowOwnerPID"] intValue];
            record.targetPID = targetWindowID != 0
                ? targetOwnerPID
                : (int32_t)[status[@"active_app_pid"] intValue];
            if (targetWindowID != 0)
                record.sceneID = MacWSInputSceneForWindow(targetWindowID, 0);
            if ([requestedKind isEqualToString:@"tap"])
                record.kind = MacWSInputKindTap;
            else if ([requestedKind isEqualToString:@"secondary"])
                record.kind = MacWSInputKindSecondaryTap;
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
            MacWSLog(@"input-v4 synthetic kind=%@ routed-through-controller scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                     requestedKind, record.sceneID, record.targetPID,
                     record.x, record.y, record.frameWidth,
                     record.frameHeight);
            break;
        }
        NSString *host = context.URL.host ?: @"status";
        if ([@[@"status", @"start", @"start-experimental", @"stop",
               @"glassdemo", @"terminal", @"vscode", @"activity-monitor", @"finder",
               @"recover", @"repair", @"capture",
               @"close-window",
               @"screenshot-ui", @"hide-controls", @"show-controls"]
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
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:session.persistentIdentifier]) {
            [MacWSSceneSessionsPreservingMacWindow
                removeObject:session.persistentIdentifier];
            MacWSSetPersistedSceneBinding(session.persistentIdentifier, nil);
            MacWSLog(@"scene-discard duplicate-only id=%@ mac-window=preserved",
                     session.persistentIdentifier);
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
