#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <xpc/xpc.h>

#include "macws_menu_protocol.h"
#include "macws_display_geometry.h"
#include "macws_stream_protocol.h"
#import "MacWSFinalCompositeReceiver.h"

// macOS 13.4 SkyLight RE witness (binary UUID
// 96676A53-B1E0-3D7E-B98B-B73873CD1880):
// SLSHWCaptureStreamCreateWithWindow at 0x185210714 preserves x0..x4 as
// window ID, frame-shape-selection flag, properties, dispatch queue, and frame
// handler. RE witness: x0 is passed to CGSLocalWindowByID during preflight;
// WindowServer's CGXHWCaptureStreamCreate stores x1 at WSCaptureStream+0x40,
// and WSCaptureStreamStart reads that byte to select
// CGXCopyScreenFrameShapeForWindow (true) instead of
// CGXCopyScreenContentShapeForWindow (false). The producer selects the content
// shape so non-content pixels are not deliberately added to the touch target;
// exact surface-to-NSWindow.frame congruence remains a device runtime gate.
// Keep this private dependency isolated here so the rest of the wire protocol
// and Host do not depend on SkyLight declarations.
typedef CGDisplayStreamRef (*MacWSSLSWindowStreamCreate)(
    uint32_t windowID, bool useScreenFrameShape, CFDictionaryRef properties,
    dispatch_queue_t queue, CGDisplayStreamFrameAvailableHandler handler);

static dispatch_queue_t DisplayQueue;
static dispatch_queue_t MenuQueue;
// Presentation-only SkyLight description calls can synchronously stall for
// 90+ ms at their tail even though their median cost is below 1 ms. Keep those
// calls off DisplayQueue: exact-window capture callbacks, leases and input-
// correlated content frames must remain drainable while WindowServer answers
// a Mission Control geometry query.
static dispatch_queue_t WorkspaceGeometryQueue;
static NSMutableSet *Clients;
static NSMutableDictionary<NSNumber *, id> *Leases;
// The latest WindowServer-owned final AGX composite is retained independently
// of any Host Scene. A foreground fullscreen subscriber can therefore acquire
// the current native desktop immediately without waiting for unrelated damage.
static IOSurfaceRef FinalCompositeSurface;
static MacWSFinalCompositeRecord FinalCompositeRecord;
// A SkyLight popup can disappear while its final AGX command buffer is still
// retiring.  Keep the capture object alive for a bounded grace period instead
// of synchronously stopping it from the catalog-removal stack.
static NSMutableArray *RetiredTransientLayers;
// A Mission Control transition removes several full-Retina Dock capture
// windows in the same catalog transaction.  Their five-second reuse grace
// therefore expires on the same DisplayQueue turn.  Stopping all of those
// streams in one call stack recreates the AGX/WindowServer teardown burst that
// RetireFullscreenClientStaggered already avoids.  Drain validated retirements
// one display interval apart while preserving the existing reuse grace.
static NSMutableArray *RetiredTransientStopBlocks;
static BOOL RetiredTransientStopDrainPending;
static uint64_t NextStreamID = 1;
static uint64_t NextLeaseToken = 1;
static int InvalidationSocket = -1;
static dispatch_source_t InvalidationSource;
static BOOL TransientReconcilePending;
// Every request receives a generation. An urgent event-driven reconcile can
// therefore supersede the slow correctness poll already queued for 100/250ms
// instead of being rejected by its pending bit.
static uint64_t TransientReconcileGeneration;
// A completed semantic pointer click is an authoritative catalog edge: the
// target process emits it only after AppKit's synchronous control/menu tracker
// has returned.  Keep two independent post-click CGWindow snapshots (one
// display interval apart) so a genuinely dismissed popup disappears promptly,
// while the ordinary recovery poll retains its more conservative three-miss
// policy for uncorrelated catalog churn.
static unsigned UrgentTransientRetirePasses;
// Dock's native Mission Control/App Expose/Spaces animations move existing
// SkyLight windows without sending the AppKit geometry sidecar datagrams used
// by ordinary window moves.  A one-second idle recovery scan therefore turns
// a continuous native gesture into a handful of Host compositor positions.
// Dock emits the lightweight 'a' invalidation only after its real
// DOCKGestures handler consumes a progress sample.  Keep the expensive desktop
// catalog scan at display cadence only while those samples are arriving, then
// retain a short tail so Dock's spring/settlement animation is captured too.
static CFTimeInterval WorkspaceAnimationSamplingDeadline;
// Dock owns a spring after the last input sample. Continue only while real
// SkyLight presentation geometry is still changing, with this hard bound so a
// noisy catalog can never turn one gesture into permanent high-rate polling.
static CFTimeInterval WorkspaceAnimationSettlementHardDeadline;
static BOOL WorkspaceGeometryQueryInFlight;
static BOOL WorkspaceGeometryQueryPending;
static BOOL WorkspaceGeometryBurstActive;
static uint64_t WorkspaceGeometryQueryGeneration;
static uint64_t WorkspaceGeometryQuerySamples;
static uint64_t WorkspaceGeometryRecordsSent;
static double WorkspaceGeometryQueryDurationsMS[256];
static NSUInteger WorkspaceGeometryQueryDurationCount;
static NSUInteger WorkspaceGeometryQueryDurationCursor;
static BOOL CatalogBroadcastPending;
static _Atomic uint64_t GeometryRestartSerial;
static NSMutableDictionary<NSNumber *, NSValue *> *GeometryTargets;
static CGFloat ObservedWindowBackingScale;
static CGFloat AppKitMainDisplayBackingScale;
static void ScheduleTransientReconcile(uint64_t delayNanoseconds);
static void RequestWorkspaceGeometrySample(void);
static void ScheduleGeometryStreamRestart(void);
static void ScheduleCatalogBroadcast(void);
static void EnqueueRetiredTransientStop(dispatch_block_t stopBlock);

static void DisplayLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static BOOL MacWSDisplayDiagnosticsEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *value = getenv("MACWS_DISPLAY_DIAGNOSTICS");
        enabled = value && value[0] && strcmp(value, "0") != 0;
    });
    return enabled;
}

static void DisplayLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MACWS-DISPLAY %s\n", message.UTF8String);
    fflush(stderr);
}

@interface MacWSDisplayLease : NSObject
@property(nonatomic) uint64_t token;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, weak) id owner;
@property(nonatomic) uint32_t layerWindowID;
@property(nonatomic) BOOL holdsSurfaceUseCount;
@end

@implementation MacWSDisplayLease
- (void)dealloc {
    if (_surface && _holdsSurfaceUseCount)
        IOSurfaceDecrementUseCount(_surface);
    if (_surface) CFRelease(_surface);
}
@end

@class MacWSDisplayClient;

@interface MacWSTransientLayer : NSObject {
    IOSurfaceRef _latestSurface;
    // One fixed, allocation-free ring is enough to score an active native
    // animation burst.  A gap is deliberately excluded: Mission Control can
    // remain open and static between its enter and exit animations, and the
    // old first-to-last calculation therefore reported 28 fps for a healthy
    // producer simply because the tester inspected the screen for a second.
    double _activeFrameIntervalsMS[512];
    NSUInteger _activeFrameIntervalCount;
    NSUInteger _activeFrameIntervalCursor;
}
@property(nonatomic, weak) MacWSDisplayClient *client;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) int32_t ownerPID;
@property(nonatomic, copy) NSString *ownerName;
@property(nonatomic, copy) NSString *windowName;
@property(nonatomic) NSInteger skyLightLayer;
@property(nonatomic) int32_t level;
@property(nonatomic) CGRect destinationBounds;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) uint64_t firstDisplayTime;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) NSUInteger missCount;
@property(nonatomic) CGDisplayStreamRef stream;
@property(nonatomic) IOSurfaceRef latestSurface;
@property(nonatomic) uint64_t latestDisplayTime;
@property(nonatomic) BOOL oneShotCapture;
@property(nonatomic) BOOL snapshotComplete;
@property(nonatomic) BOOL retiring;
@property(nonatomic) uint64_t retirementGeneration;
- (void)recordActiveFrameAtDisplayTime:(uint64_t)displayTime;
- (void)finishActiveFrameBurstWithReason:(NSString *)reason;
- (void)stopCapturePreservingSurface;
- (void)stopStream;
@end

@implementation MacWSTransientLayer
- (void)dealloc {
    [self stopStream];
    self.latestSurface = NULL;
}
- (IOSurfaceRef)latestSurface { return _latestSurface; }
- (void)setLatestSurface:(IOSurfaceRef)surface {
    if (_latestSurface == surface) return;
    if (surface) CFRetain(surface);
    if (_latestSurface) CFRelease(_latestSurface);
    _latestSurface = surface;
}

static int MacWSCompareFrameInterval(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

- (void)finishActiveFrameBurstWithReason:(NSString *)reason {
    if (!MacWSDisplayDiagnosticsEnabled()) {
        _activeFrameIntervalCount = 0;
        _activeFrameIntervalCursor = 0;
        return;
    }
    NSUInteger count = MIN(_activeFrameIntervalCount,
                           sizeof(_activeFrameIntervalsMS) /
                               sizeof(_activeFrameIntervalsMS[0]));
    if (count >= 8) {
        double intervals[512];
        double total = 0.0;
        for (NSUInteger index = 0; index < count; index++) {
            intervals[index] = _activeFrameIntervalsMS[index];
            total += intervals[index];
        }
        qsort(intervals, count, sizeof(intervals[0]),
              MacWSCompareFrameInterval);
        NSUInteger p50Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.50) - 1);
        NSUInteger p99Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.99) - 1);
        double meanInterval = total / count;
        double p50 = intervals[p50Index];
        double p99 = intervals[p99Index];
        DisplayLog(@"active-frame-burst layer=%u owner=%@ reason=%@ "
                   "intervals=%lu average-fps=%.2f p50-ms=%.3f "
                   "p99-ms=%.3f one-percent-low-fps=%.2f",
                   self.windowID, self.ownerName ?: @"", reason ?: @"end",
                   (unsigned long)count,
                   meanInterval > 0.0 ? 1000.0 / meanInterval : 0.0,
                   p50, p99, p99 > 0.0 ? 1000.0 / p99 : 0.0);
    }
    _activeFrameIntervalCount = 0;
    _activeFrameIntervalCursor = 0;
}

- (void)recordActiveFrameAtDisplayTime:(uint64_t)displayTime {
    if (!MacWSDisplayDiagnosticsEnabled()) return;
    if (!_latestDisplayTime || displayTime <= _latestDisplayTime) return;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return;
    double intervalMS = (double)(displayTime - _latestDisplayTime) *
        timebase.numer / timebase.denom / 1.0e6;
    // A native animation produces no CGDisplayStream callback while its layer
    // is static.  Split at that real producer gap instead of counting idle
    // inspection time as dropped frames.  Very small/non-finite timestamps
    // are invalid timing samples, not zero-latency frames.
    if (!isfinite(intervalMS) || intervalMS < 0.05) return;
    if (intervalMS > 150.0) {
        [self finishActiveFrameBurstWithReason:@"producer-gap"];
        return;
    }
    NSUInteger capacity = sizeof(_activeFrameIntervalsMS) /
        sizeof(_activeFrameIntervalsMS[0]);
    _activeFrameIntervalsMS[_activeFrameIntervalCursor] = intervalMS;
    _activeFrameIntervalCursor = (_activeFrameIntervalCursor + 1) % capacity;
    if (_activeFrameIntervalCount < capacity) _activeFrameIntervalCount++;
}
- (void)stopCapturePreservingSurface {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    _sequence = 0;
}
- (void)stopStream {
    [self stopCapturePreservingSurface];
    self.latestSurface = NULL;
    _latestDisplayTime = 0;
    _snapshotComplete = NO;
}
@end

@interface MacWSDisplayClient : NSObject
@property(nonatomic) xpc_connection_t connection;
// A full-desktop subscription owns a complete SkyLight capture graph (menu
// bar, Dock, wallpaper and every visible window).  It is deliberately
// exclusive: duplicating that graph for two Host Scenes creates two sets of
// full-Retina capture streams inside the same WindowServer.
@property(nonatomic) BOOL subscriptionActive;
@property(nonatomic) MacWSStreamMode mode;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CGDisplayStreamRef stream;
@property(nonatomic) IOSurfaceRef workspaceCanvas;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) uint64_t firstDisplayTime;
@property(nonatomic) CGFloat windowBackingScale;
@property(nonatomic) size_t lastSurfaceWidth;
@property(nonatomic) size_t lastSurfaceHeight;
// CGDisplayStreamStop is asynchronous.  A generation token keeps a delayed
// exact-window recreation from resurrecting an obsolete Scene subscription.
@property(nonatomic) uint64_t geometryRestartGeneration;
@property(nonatomic) NSMutableDictionary<NSNumber *, MacWSTransientLayer *> *transientLayers;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *outstandingByLayer;
// A fullscreen Host can be relaunched or have its UIWindowScene recreated
// while WindowServer keeps producing the same desktop. Keep a generation for
// the bounded disconnect handoff instead of tearing down the whole capture
// graph synchronously from the XPC error callback.
@property(nonatomic) uint64_t disconnectGeneration;
@property(nonatomic) BOOL deliveryPaused;
- (void)stopStream;
- (void)stopTransientLayers;
@end

@implementation MacWSDisplayClient
- (void)dealloc {
    [self stopTransientLayers];
    [self stopStream];
}
- (void)stopTransientLayers {
    for (MacWSTransientLayer *layer in _transientLayers.allValues)
        [layer stopStream];
    [_transientLayers removeAllObjects];
}
- (void)stopStream {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    if (_workspaceCanvas) {
        CFRelease(_workspaceCanvas);
        _workspaceCanvas = NULL;
    }
    _sequence = 0;
}
@end

static void SendStatus(MacWSDisplayClient *client, const char *eventName,
                       NSString *message, BOOL ok) {
    if (!client.connection || client.deliveryPaused) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT, eventName);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_bool(event, MACWS_STREAM_KEY_OK, ok);
    if (message.length)
        xpc_dictionary_set_string(event, MACWS_STREAM_KEY_MESSAGE,
                                  message.UTF8String);
    xpc_connection_send_message(client.connection, event);
}

static void SendMenuResponse(MacWSDisplayClient *client, NSData *response) {
    if (!client || !response.length) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_MENU_XPC_EVENT_RESPONSE);
    xpc_dictionary_set_data(event, MACWS_MENU_XPC_KEY_RESPONSE,
                            response.bytes, response.length);
    xpc_connection_send_message(client.connection, event);
}

static NSData *MenuErrorResponse(const MacWSMenuRequest *request,
                                 MacWSMenuStatus status) {
    MacWSMenuResponseHeader header = {
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(header),
        .status = status,
        .nonce = request->nonce,
        .ownerPID = request->ownerPID,
        .windowID = request->windowID,
        .generation = request->generation ? request->generation : 1,
        .totalBytes = sizeof(header),
    };
    return [NSData dataWithBytes:&header length:sizeof(header)];
}

static void RelayMenuRequest(MacWSDisplayClient *client,
                             MacWSMenuRequest request) {
    dispatch_async(MenuQueue, ^{
        @autoreleasepool {
            int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
            if (socketFD < 0) {
                SendMenuResponse(client, MenuErrorResponse(
                    &request, MacWSMenuStatusInternalError));
                return;
            }
            struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
            (void)setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO,
                             &timeout, sizeof(timeout));
            char sourcePath[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
            snprintf(sourcePath, sizeof(sourcePath),
                     "/private/tmp/macws_menu_client.%d.%08x.sock",
                     getpid(), arc4random());
            struct sockaddr_un source = {0};
            source.sun_family = AF_UNIX;
            strlcpy(source.sun_path, sourcePath, sizeof(source.sun_path));
            unlink(sourcePath);
            if (bind(socketFD, (const struct sockaddr *)&source,
                     sizeof(source)) != 0) {
                close(socketFD);
                SendMenuResponse(client, MenuErrorResponse(
                    &request, MacWSMenuStatusInternalError));
                return;
            }

            char targetPath[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
            snprintf(targetPath, sizeof(targetPath),
                     "/private/tmp/macws_app_input.%d.sock",
                     request.ownerPID);
            struct sockaddr_un target = {0};
            target.sun_family = AF_UNIX;
            strlcpy(target.sun_path, targetPath, sizeof(target.sun_path));
            ssize_t sent = sendto(socketFD, &request, sizeof(request), 0,
                                  (const struct sockaddr *)&target,
                                  sizeof(target));
            MacWSMenuResponseHeader acknowledgement = {0};
            ssize_t received = sent == sizeof(request)
                ? recv(socketFD, &acknowledgement,
                       sizeof(acknowledgement), 0) : -1;
            close(socketFD);
            unlink(sourcePath);

            MacWSMenuStatus failure = received < 0 &&
                (errno == EAGAIN || errno == EWOULDBLOCK)
                ? MacWSMenuStatusTimeout
                : MacWSMenuStatusTargetUnavailable;
            if (received != sizeof(acknowledgement) ||
                !MacWSMenuResponseIsValid(&acknowledgement,
                                           sizeof(acknowledgement)) ||
                acknowledgement.nonce != request.nonce ||
                acknowledgement.ownerPID != request.ownerPID ||
                acknowledgement.windowID != request.windowID) {
                SendMenuResponse(client, MenuErrorResponse(&request, failure));
                return;
            }
            if (request.operation != MacWSMenuOperationSnapshot ||
                acknowledgement.status != MacWSMenuStatusOK) {
                SendMenuResponse(client, [NSData dataWithBytes:&acknowledgement
                                                         length:sizeof(acknowledgement)]);
                return;
            }

            NSString *snapshotPath = [NSString stringWithFormat:
                @"/private/tmp/macws_menu_snapshot.%d.%016llx.bin",
                request.ownerPID, (unsigned long long)request.nonce];
            NSData *snapshot = [NSData dataWithContentsOfFile:snapshotPath
                options:NSDataReadingMappedIfSafe error:nil];
            unlink(snapshotPath.fileSystemRepresentation);
            const MacWSMenuResponseHeader *header = snapshot.length >=
                sizeof(MacWSMenuResponseHeader) ? snapshot.bytes : NULL;
            if (!MacWSMenuResponseIsValid(header, snapshot.length) ||
                header->status != MacWSMenuStatusOK ||
                header->nonce != request.nonce ||
                header->ownerPID != request.ownerPID ||
                header->windowID != request.windowID ||
                header->generation != acknowledgement.generation) {
                SendMenuResponse(client, MenuErrorResponse(
                    &request, MacWSMenuStatusInternalError));
                return;
            }
            SendMenuResponse(client, snapshot);
        }
    });
}

static NSArray<NSDictionary *> *CopyOnScreenWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyCompleteDesktopWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyWindowDescriptions(
        NSArray<NSNumber *> *windowIDs) {
    if (!windowIDs.count) return @[];
    // CGWindowListCreateDescriptionFromArray's historical ABI consumes each
    // element as an integer-sized CGWindowID, not as a retained CFNumber.
    // The target geometry probe runtime-confirmed that a callback-free array
    // of pointer-sized IDs exposes live presentation bounds; passing an
    // NSArray<NSNumber *> instead returns unrelated/model-only entries.
    const void *values[MACWS_STREAM_MAX_LAYER_GEOMETRY] = {0};
    CFIndex count = (CFIndex)MIN(windowIDs.count,
        (NSUInteger)MACWS_STREAM_MAX_LAYER_GEOMETRY);
    for (CFIndex index = 0; index < count; index++) {
        values[index] = (const void *)(uintptr_t)
            [windowIDs[(NSUInteger)index] unsignedIntValue];
    }
    CFArrayRef identifiers = CFArrayCreate(kCFAllocatorDefault, values,
                                            count, NULL);
    CFArrayRef raw = identifiers
        ? CGWindowListCreateDescriptionFromArray(identifiers) : NULL;
    if (identifiers) CFRelease(identifiers);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyCatalogWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static CGFloat MainDisplayBackingScale(void) {
    if (ObservedWindowBackingScale >= 0.5 &&
        ObservedWindowBackingScale <= 8.0)
        return ObservedWindowBackingScale;
    // NSScreen is the authoritative AppKit point-to-backing-pixel mapping.
    // The chroot virtual display's CGDisplayPixelsWide/High runtime-report its
    // logical extent, so that API pair alone collapses Retina to 1x during a
    // cold fullscreen subscription before any exact-window frame is observed.
    if (AppKitMainDisplayBackingScale >= 0.5 &&
        AppKitMainDisplayBackingScale <= 8.0)
        return AppKitMainDisplayBackingScale;
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    size_t pixelWidth = CGDisplayPixelsWide(display);
    if (bounds.size.width <= 0 || pixelWidth == 0) return 1.0;
    CGFloat scale = pixelWidth / bounds.size.width;
    return scale > 0 && scale <= 8.0 ? scale : 1.0;
}

static BOOL CopyWindowBounds(uint32_t windowID, CGRect *result) {
    if (windowID == 0 || !result) return NO;
    for (NSDictionary *info in CopyOnScreenWindowInfo()) {
        if ([info[(id)kCGWindowNumber] unsignedIntValue] != windowID)
            continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                &bounds) || bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0) return NO;
        *result = bounds;
        return YES;
    }
    return NO;
}

static NSDictionary<NSNumber *, NSValue *> *CopyWindowMetrics(int32_t pid) {
    if (pid <= 1) return @{};
    NSString *path = [NSString stringWithFormat:
        @"/private/tmp/macws_window_metrics.%d.bin", pid];
    NSData *data = [NSData dataWithContentsOfFile:path
                                         options:NSDataReadingMappedIfSafe
                                           error:nil];
    if (data.length < sizeof(MacWSWindowMetricsHeader)) return @{};
    const MacWSWindowMetricsHeader *header = data.bytes;
    if (!MacWSWindowMetricsAreValid(header, data.length)) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    const MacWSWindowMetricsEntry *entries =
        (const void *)((const uint8_t *)data.bytes + sizeof(*header));
    for (uint32_t index = 0; index < header->entryCount; index++) {
        MacWSWindowMetricsEntry entry = entries[index];
        if (entry.windowID == 0 ||
            !isfinite(entry.minimumLogicalWidth) ||
            !isfinite(entry.minimumLogicalHeight) ||
            entry.minimumLogicalWidth < 0 ||
            entry.minimumLogicalHeight < 0 ||
            entry.minimumLogicalWidth > MACWS_STREAM_MAX_DIMENSION ||
            entry.minimumLogicalHeight > MACWS_STREAM_MAX_DIMENSION) continue;
        result[@(entry.windowID)] = [NSValue valueWithBytes:&entry
                                                  objCType:@encode(MacWSWindowMetricsEntry)];
    }
    return result;
}

static MacWSStreamWindowDescriptor WindowDescriptor(
        NSDictionary *info, const MacWSWindowMetricsEntry *metrics) {
    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds);
    uint32_t windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
    int32_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
    CGFloat scale = MainDisplayBackingScale();
    MacWSStreamWindowDescriptor descriptor = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamWindowDescriptor),
        .windowID = windowID,
        .ownerPID = ownerPID,
        .flags = 0,
        .logicalGroupID = metrics ? metrics->logicalGroupID : windowID,
        .logicalX = bounds.origin.x,
        .logicalY = bounds.origin.y,
        .logicalWidth = bounds.size.width,
        .logicalHeight = bounds.size.height,
        .pixelWidth = (uint32_t)llround(bounds.size.width * scale),
        .pixelHeight = (uint32_t)llround(bounds.size.height * scale),
        // Zero means the AppKit endpoint has not published evidence yet. The
        // Host must not replace an unknown minimum with a guessed constant.
        .minimumLogicalWidth = metrics ? metrics->minimumLogicalWidth : 0,
        .minimumLogicalHeight = metrics ? metrics->minimumLogicalHeight : 0,
        .backingScale = scale,
    };
    if (metrics) {
        descriptor.flags |= metrics->flags &
            (MacWSStreamWindowVisible | MacWSStreamWindowHasShadow |
             MacWSStreamWindowResizable |
             MacWSStreamWindowFocused | MacWSStreamWindowSpatialCanvas);
    }
    if ([info[(id)kCGWindowIsOnscreen] boolValue])
        descriptor.flags |= MacWSStreamWindowOnScreen;
    return descriptor;
}

static void SendWindowList(MacWSDisplayClient *client) {
    if (!client.connection) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_WINDOWS);
    xpc_object_t array = xpc_array_create(NULL, 0);
    NSUInteger emitted = 0;
    NSMutableDictionary<NSNumber *, NSDictionary *> *metricsByPID =
        [NSMutableDictionary dictionary];
    for (NSDictionary *info in CopyCatalogWindowInfo()) {
        if (emitted >= MACWS_STREAM_MAX_WINDOWS) break;
        int32_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
        NSNumber *pidKey = @(ownerPID);
        NSDictionary<NSNumber *, NSValue *> *processMetrics = metricsByPID[pidKey];
        if (!processMetrics) {
            processMetrics = CopyWindowMetrics(ownerPID);
            metricsByPID[pidKey] = processMetrics;
        }
        uint32_t candidateWindowID =
            [info[(id)kCGWindowNumber] unsignedIntValue];
        MacWSWindowMetricsEntry metrics = {0};
        NSValue *metricsValue = processMetrics[@(candidateWindowID)];
        // A selectable Scene must correspond to a real, published AppKit
        // top-level window. Cursor/menu-bar/plugin surfaces have no matching
        // per-process metrics entry, while menus and overlays use nonzero
        // Quartz layers. Excluding both categories removes the black phantom
        // Scene without guessing from localized titles.
        NSInteger layer = [info[(id)kCGWindowLayer] integerValue];
        if (!metricsValue || layer != 0) continue;
        [metricsValue getValue:&metrics];
        if ((metrics.flags & MacWSStreamWindowVisible) == 0 ||
            (metrics.flags & MacWSStreamWindowTransient) != 0) continue;
        MacWSStreamWindowDescriptor descriptor = WindowDescriptor(
            info, &metrics);
        if (descriptor.windowID == 0 || descriptor.ownerPID <= 1 ||
            descriptor.logicalWidth <= 1 || descriptor.logicalHeight <= 1)
            continue;
        NSString *title = info[(id)kCGWindowName];
        if (![title isKindOfClass:NSString.class]) title = @"macOS Window";
        NSData *titleData = [title dataUsingEncoding:NSUTF8StringEncoding];
        if (titleData.length > UINT32_MAX) continue;
        descriptor.titleLength = (uint32_t)titleData.length;
        NSMutableData *bytes = [NSMutableData dataWithBytes:&descriptor
                                                     length:sizeof(descriptor)];
        [bytes appendData:titleData];
        xpc_object_t item = xpc_data_create(bytes.bytes, bytes.length);
        xpc_array_append_value(array, item);
        emitted++;
    }
    xpc_dictionary_set_value(event, MACWS_STREAM_KEY_WINDOWS, array);
    xpc_connection_send_message(client.connection, event);
}

static void BroadcastWindowList(void) {
    for (MacWSDisplayClient *client in [Clients copy])
        SendWindowList(client);
}

// A single AppKit action can update focus, key state and window metrics in
// separate callbacks. Runtime logs captured more than ten complete catalog
// broadcasts in the burst following one UI action. Preserve the latest
// authoritative CGWindow snapshot while collapsing each 16 ms burst into one
// display-queue edge.
// Explicit LIST_WINDOWS requests remain immediate in HandleRequest.
static void ScheduleCatalogBroadcast(void) {
    if (CatalogBroadcastPending) return;
    CatalogBroadcastPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        CatalogBroadcastPending = NO;
        BroadcastWindowList();
        ScheduleTransientReconcile(0);
    });
}

// AppKit processes publish their window metrics in a shared sidecar. This
// datagram is only an invalidation edge: displayd remains the single process
// that reads the real CGWindow catalog and broadcasts a validated snapshot.
// A dispatch source drains every queued byte before one broadcast, so a tab
// switch plus its metrics update cannot turn into repeated catalog scans.
static void StartInvalidationListener(void) {
    InvalidationSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (InvalidationSocket < 0) {
        DisplayLog(@"catalog-invalidation socket-create failed errno=%d", errno);
        return;
    }
    int flags = fcntl(InvalidationSocket, F_GETFL);
    if (flags >= 0) (void)fcntl(InvalidationSocket, F_SETFL,
                                flags | O_NONBLOCK);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MACWS_STREAM_INVALIDATE_SOCKET_PATH,
            sizeof(address.sun_path));
    unlink(MACWS_STREAM_INVALIDATE_SOCKET_PATH);
    if (bind(InvalidationSocket, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        DisplayLog(@"catalog-invalidation bind failed errno=%d", errno);
        close(InvalidationSocket);
        InvalidationSocket = -1;
        return;
    }
    chmod(MACWS_STREAM_INVALIDATE_SOCKET_PATH, 0666);
    InvalidationSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)InvalidationSocket, 0,
        DisplayQueue);
    dispatch_source_set_event_handler(InvalidationSource, ^{
        uint8_t bytes[128];
        BOOL geometryChanged = NO;
        BOOL semanticPointerClickCompleted = NO;
        BOOL workspaceAnimationAdvanced = NO;
        BOOL catalogChanged = NO;
        ssize_t count = 0;
        while ((count = recv(InvalidationSocket, bytes,
                             sizeof(bytes), 0)) > 0) {
            MacWSGeometryInvalidation geometry = {0};
            if ((size_t)count == sizeof(geometry)) {
                memcpy(&geometry, bytes, sizeof(geometry));
            }
            if (MacWSGeometryInvalidationIsValid(&geometry,
                                                  (size_t)count)) {
                @synchronized (GeometryTargets) {
                    GeometryTargets[@(geometry.windowID)] =
                        [NSValue valueWithBytes:&geometry
                            objCType:@encode(MacWSGeometryInvalidation)];
                }
                geometryChanged = YES;
                catalogChanged = YES;
            } else {
                for (ssize_t index = 0; index < count; index++) {
                    if (bytes[index] == 'a') {
                        workspaceAnimationAdvanced = YES;
                        continue;
                    }
                    catalogChanged = YES;
                    if (bytes[index] == 'g') geometryChanged = YES;
                    if (bytes[index] == 't')
                        semanticPointerClickCompleted = YES;
                }
            }
        }
        if (semanticPointerClickCompleted)
            UrgentTransientRetirePasses = 10;
        if (workspaceAnimationAdvanced) {
            CFTimeInterval now = CFAbsoluteTimeGetCurrent();
            BOOL wasSampling = now < WorkspaceAnimationSamplingDeadline;
            WorkspaceAnimationSamplingDeadline =
                now + 0.25;
            WorkspaceAnimationSettlementHardDeadline = now + 0.80;
            // This path only needs compositor geometry. Avoid broadcasting a
            // complete application-window list for every gesture sample. A
            // targeted asynchronous query is single-flight: 120-Hz input can
            // request the next sample without queuing redundant SkyLight RPCs.
            if (!wasSampling) ScheduleTransientReconcile(0);
            RequestWorkspaceGeometrySample();
        }
        if (catalogChanged) ScheduleCatalogBroadcast();
        if (geometryChanged) ScheduleGeometryStreamRestart();
    });
    dispatch_source_set_cancel_handler(InvalidationSource, ^{
        if (InvalidationSocket >= 0) close(InvalidationSocket);
        InvalidationSocket = -1;
        unlink(MACWS_STREAM_INVALIDATE_SOCKET_PATH);
    });
    dispatch_resume(InvalidationSource);
}

static NSDictionary *StreamProperties(void) {
    NSMutableDictionary *properties = [@{
        (__bridge id)kCGDisplayStreamQueueDepth: @3,
        (__bridge id)kCGDisplayStreamShowCursor: @NO,
        (__bridge id)kCGDisplayStreamPreserveAspectRatio: @YES,
        // The coexist compositor is paced at 120 Hz only during the bounded
        // one-second interaction window. Capping exact-window capture at 60
        // Hz forced a fresh VS Code frame to miss every other compositor
        // completion and runtime-measured 18.2 ms mean source intervals plus
        // 20.9 ms during momentum. A 120-Hz A/B restored 59 FPS average but
        // delivered bursts into an application/final-present path that is
        // currently near 60 Hz, increasing 33-66 ms tail gaps. A 90-Hz A/B
        // reduced the tails but momentum fell to 55.9 source FPS. Test the
        // midpoint at 100 Hz to retain the phase tolerance without needlessly
        // filling the three-surface lease queue. A static window still
        // produces no CGDisplayStream callback.
        (__bridge id)kCGDisplayStreamMinimumFrameTime: @(1.0 / 100.0),
    } mutableCopy];
    CFStringRef *surfacePropertiesKey = dlsym(
        RTLD_DEFAULT, "kSLDisplayStreamIOSurfaceProperties");
    if (surfacePropertiesKey && *surfacePropertiesKey) {
        properties[(__bridge NSString *)*surfacePropertiesKey] = @{
            (__bridge id)kIOSurfacePixelFormat: @(0x42475241u),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
        };
    }
    return properties;
}

static NSUInteger OutstandingFramesForLayer(MacWSDisplayClient *client,
                                             uint32_t layerWindowID) {
    return [client.outstandingByLayer[@(layerWindowID)] unsignedIntegerValue];
}

static void SetOutstandingFramesForLayer(MacWSDisplayClient *client,
                                         uint32_t layerWindowID,
                                         NSUInteger count) {
    if (!client.outstandingByLayer)
        client.outstandingByLayer = [NSMutableDictionary dictionary];
    if (count == 0) [client.outstandingByLayer removeObjectForKey:@(layerWindowID)];
    else client.outstandingByLayer[@(layerWindowID)] = @(count);
}

static void PublishFrame(MacWSDisplayClient *client,
                         MacWSTransientLayer *layer,
                         uint64_t displayTime, IOSurfaceRef surface) {
    if (!surface || ![Clients containsObject:client]) return;
    // Keep one immutable IOSurface reference per workspace layer.  A
    // fullscreen Scene ownership transfer can then republish the complete
    // current desktop without stopping/recreating any SkyLight stream.
    if (layer) {
        [layer recordActiveFrameAtDisplayTime:displayTime];
        layer.latestSurface = surface;
        layer.latestDisplayTime = displayTime;
    }
    // During the bounded fullscreen handoff grace period, keep the existing
    // SkyLight streams and their newest immutable surfaces alive but do not
    // manufacture leases for a dead XPC connection. The replacement Host
    // republishes these surfaces when it atomically takes ownership.
    if (!client.connection || client.deliveryPaused) return;
    uint32_t layerWindowID = layer ? layer.windowID
        : (client.windowID ? client.windowID : UINT32_MAX);
    uint64_t producerStreamID = layer ? layer.streamID : client.streamID;
    // With a stream queue depth of three, retaining more than three surfaces
    // from one producer can pin that producer's compositor buffers. Bound
    // base and each transient independently so a static menu cannot stall the
    // continuously updating document stream.
    NSUInteger outstanding = OutstandingFramesForLayer(client, layerWindowID);
    if (outstanding >= 3) {
        uint64_t dropped = layer ? ++layer.droppedFrames
                                 : ++client.droppedFrames;
        if (dropped == 1 || (dropped % 120) == 0) {
            DisplayLog(@"backpressure stream=%llu window=%u layer=%u outstanding=%lu "
                       "dropped=%llu",
                (unsigned long long)producerStreamID, client.windowID,
                layerWindowID, (unsigned long)outstanding,
                (unsigned long long)dropped);
        }
        return;
    }

    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 ||
        width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION ||
        bytesPerRow > UINT32_MAX) return;
    if (!layer) {
        client.lastSurfaceWidth = width;
        client.lastSurfaceHeight = height;
    }
    if (!layer && client.mode == MacWSStreamModeWindow &&
        client.windowBackingScale <= 0.0) {
        for (NSDictionary *info in CopyOnScreenWindowInfo()) {
            if ([info[(id)kCGWindowNumber] unsignedIntValue] !=
                client.windowID) continue;
            CGRect bounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &bounds) || bounds.size.width <= 0.0 ||
                bounds.size.height <= 0.0) break;
            CGFloat scaleX = width / bounds.size.width;
            CGFloat scaleY = height / bounds.size.height;
            CGFloat measured = (scaleX + scaleY) * 0.5;
            if (isfinite(measured) && measured >= 0.5 && measured <= 8.0 &&
                fabs(scaleX - scaleY) <= 0.08) {
                client.windowBackingScale = measured;
                ObservedWindowBackingScale = measured;
                DisplayLog(@"runtime-confirmed backing-scale window=%u surface=%zux%zu bounds=%.1fx%.1f scale=%.3f",
                           client.windowID, width, height,
                           bounds.size.width, bounds.size.height, measured);
            }
            break;
        }
    }
    uint32_t contentWidth = (uint32_t)width;
    uint32_t contentHeight = (uint32_t)height;
    int32_t destinationX = layer
        ? (int32_t)llround(layer.destinationBounds.origin.x) : 0;
    int32_t destinationY = layer
        ? (int32_t)llround(layer.destinationBounds.origin.y) : 0;
    uint32_t destinationWidth = layer
        ? (uint32_t)llround(layer.destinationBounds.size.width)
        : contentWidth;
    uint32_t destinationHeight = layer
        ? (uint32_t)llround(layer.destinationBounds.size.height)
        : contentHeight;
    if (destinationWidth == 0 || destinationHeight == 0) return;

    BOOL finalComposite = !layer &&
        client.mode == MacWSStreamModeFullscreen &&
        surface == FinalCompositeSurface &&
        FinalCompositeRecord.producerPID > 1;

    MacWSDisplayLease *lease = [MacWSDisplayLease new];
    lease.token = NextLeaseToken++;
    if (lease.token == 0) lease.token = NextLeaseToken++;
    lease.surface = (IOSurfaceRef)CFRetain(surface);
    if (finalComposite) {
        IOSurfaceIncrementUseCount(surface);
        lease.holdsSurfaceUseCount = YES;
    }
    lease.owner = client;
    lease.layerWindowID = layerWindowID;
    Leases[@(lease.token)] = lease;
    SetOutstandingFramesForLayer(client, layerWindowID, outstanding + 1);

    CGFloat scale = client.windowBackingScale > 0.0
        ? client.windowBackingScale : MainDisplayBackingScale();
    MacWSStreamFrameDescriptor descriptor = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamFrameDescriptor),
        .streamID = producerStreamID,
        .windowID = client.windowID,
        .flags = MacWSStreamFrameComplete |
                 (finalComposite
                     ? MacWSStreamFrameFinalComposite : 0) |
                 (layer ? MacWSStreamFrameOverlay : 0) |
                 (layer && [layer.ownerName isEqualToString:@"Dock"]
                     ? MacWSStreamFrameGlobalSystemSurface : 0) |
                 (layer && layer.skyLightLayer >=
                      CGWindowLevelForKey(kCGCursorWindowLevelKey)
                     ? MacWSStreamFrameInputPassthrough : 0),
        .leaseToken = lease.token,
        .sequence = layer ? ++layer.sequence : ++client.sequence,
        .displayTime = displayTime,
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .bytesPerRow = (uint32_t)bytesPerRow,
        .pixelFormat = IOSurfaceGetPixelFormat(surface),
        .backingScale = scale,
        .contentX = 0,
        .contentY = 0,
        .contentWidth = contentWidth,
        .contentHeight = contentHeight,
        .layerWindowID = layerWindowID,
        .layerOwnerPID = layer ? layer.ownerPID : 0,
        .layerLevel = layer ? layer.level : 0,
        .destinationX = destinationX,
        .destinationY = destinationY,
        .destinationWidth = destinationWidth,
        .destinationHeight = destinationHeight,
    };
    if (descriptor.sequence == 1) {
        if (layer) layer.firstDisplayTime = displayTime;
        else client.firstDisplayTime = displayTime;
        DisplayLog(@"frame-first stream=%llu window=%u layer=%u overlay=%s "
                   "owner=%@ owner-pid=%d flags=%#x surface=%ux%u bpr=%u "
                   "pf=%08x destination=(%d,%d %ux%u)",
            (unsigned long long)producerStreamID, client.windowID,
            layerWindowID, layer ? "YES" : "NO",
            layer.ownerName ?: @"", descriptor.layerOwnerPID,
            descriptor.flags,
            descriptor.width, descriptor.height, descriptor.bytesPerRow,
            descriptor.pixelFormat, descriptor.destinationX,
            descriptor.destinationY, descriptor.destinationWidth,
            descriptor.destinationHeight);
    }
    uint64_t firstDisplayTime = layer ? layer.firstDisplayTime
                                      : client.firstDisplayTime;
    if (MacWSDisplayDiagnosticsEnabled() &&
        (descriptor.sequence % 120) == 0 &&
        displayTime >= firstDisplayTime) {
        static mach_timebase_info_data_t timebase;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
        double elapsed = timebase.denom
            ? (double)(displayTime - firstDisplayTime) *
                timebase.numer / timebase.denom / 1.0e9
            : 0.0;
        DisplayLog(@"throughput stream=%llu window=%u layer=%u frames=%llu "
                   "elapsed=%.3f fps=%.2f outstanding=%lu dropped=%llu",
            (unsigned long long)producerStreamID, client.windowID,
            layerWindowID,
            (unsigned long long)descriptor.sequence, elapsed,
            elapsed > 0.0 ? (descriptor.sequence - 1) / elapsed : 0.0,
            (unsigned long)outstanding,
            (unsigned long long)(layer ? layer.droppedFrames
                                      : client.droppedFrames));
    }
    if (descriptor.pixelFormat == 0) descriptor.pixelFormat = 0x42475241u;

    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(port)) {
        [Leases removeObjectForKey:@(lease.token)];
        SetOutstandingFramesForLayer(client, layerWindowID, outstanding);
        return;
    }
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_FRAME);
    xpc_dictionary_set_data(event, MACWS_STREAM_KEY_DESCRIPTOR,
                            &descriptor, sizeof(descriptor));
    xpc_dictionary_set_mach_send(event, MACWS_STREAM_KEY_SURFACE_PORT, port);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_SURFACE_ID,
                              IOSurfaceGetID(surface));
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_LEASE_TOKEN,
                              lease.token);
    xpc_connection_send_message(client.connection, event);
    mach_port_deallocate(mach_task_self(), port);
}

static void DeliverFinalComposite(
        IOSurfaceRef surface, MacWSFinalCompositeRecord record) {
    if (!surface) return;
    if (FinalCompositeRecord.producerPID == record.producerPID &&
        FinalCompositeRecord.sequence >= record.sequence) return;
    IOSurfaceRef oldSurface = FinalCompositeSurface;
    // Own one cross-process use count for the current presentation surface.
    // Every Host lease owns an additional local count. The producer's pool
    // therefore sees IOSurfaceIsInUse until both the current-frame reference
    // and every outstanding GPU lease have retired.
    IOSurfaceIncrementUseCount(surface);
    FinalCompositeSurface = (IOSurfaceRef)CFRetain(surface);
    FinalCompositeRecord = record;
    if (oldSurface) {
        IOSurfaceDecrementUseCount(oldSurface);
        CFRelease(oldSurface);
    }

    NSUInteger subscribers = 0;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen) continue;
        subscribers++;
        PublishFrame(client, nil, record.completionTime,
                     FinalCompositeSurface);
    }
    static BOOL loggedFirstAcceptedFrame = NO;
    if (!loggedFirstAcceptedFrame || MacWSDisplayDiagnosticsEnabled()) {
        loggedFirstAcceptedFrame = YES;
        DisplayLog(@"final-composite-received producer=%d sequence=%llu "
                   "surface=%u size=%ux%u bpr=%u subscribers=%lu",
                   record.producerPID,
                   (unsigned long long)record.sequence, record.surfaceID,
                   record.width, record.height, record.bytesPerRow,
                   (unsigned long)subscribers);
    }
}

static CGDisplayStreamRef CreateStream(MacWSDisplayClient *client) {
    NSDictionary *properties = StreamProperties();
    __weak MacWSDisplayClient *weakClient = client;
    uint64_t generation = client.streamID;
    CGDisplayStreamFrameAvailableHandler handler =
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
            (void)updateRef;
            MacWSDisplayClient *strongClient = weakClient;
            // CGDisplayStreamStop is asynchronous. A terminal callback from
            // the previous exact/composite stream must not be relabelled with
            // the new streamID and overwrite the Host with stale pixels.
            if (!strongClient || strongClient.streamID != generation) return;
            if (status == kCGDisplayStreamFrameStatusFrameComplete) {
                PublishFrame(strongClient, nil, displayTime, frameSurface);
            } else if (status == kCGDisplayStreamFrameStatusStopped) {
                SendStatus(strongClient, MACWS_STREAM_EVENT_STOPPED,
                           @"DisplayStream stopped", YES);
            }
        };
    if (client.mode == MacWSStreamModeFullscreen) return NULL;

    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow || client.windowID == 0) return NULL;
    return createWindow(client.windowID, false,
                        (__bridge CFDictionaryRef)properties,
                        DisplayQueue, handler);
}

static IOSurfaceRef CreateWorkspaceCanvas(MacWSDisplayClient *client) {
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect logicalBounds = CGDisplayBounds(display);
    CGFloat backingScale = MainDisplayBackingScale();
    size_t width = 0, height = 0;
    // runtime-confirmed via macwsdisplayd.log on iPad13,6: the old canvas was
    // 1194x834 at scale 2 while the compositor published a 2388x1668 desktop
    // and layer destinations. That mixed coordinate spaces, cropping the
    // desktop and shifting every fullscreen input point by 2x.
    if (!MacWSPhysicalDisplayExtent(logicalBounds.size.width,
                                    logicalBounds.size.height,
                                    backingScale,
                                    MACWS_STREAM_MAX_DIMENSION,
                                    &width, &height) ||
        width > SIZE_MAX / 4)
        return NULL;
    // iOS 16.3 Metal's _mtlValidateStrideTextureParameters asks the native
    // AGX device for iosurfaceReadOnlyTextureAlignmentBytes before importing
    // a ShaderRead IOSurface. Runtime LLDB evidence on iPad13,6 shows that
    // value is 16 bytes. The target's 1194-pixel workspace was previously
    // allocated with a 4776-byte row, which violates that real invariant.
    static const size_t kMacWSMetalIOSurfaceRowAlignment = 16;
    size_t tightBytesPerRow = width * 4;
    if (tightBytesPerRow > SIZE_MAX -
            (kMacWSMetalIOSurfaceRowAlignment - 1)) return NULL;
    size_t bytesPerRow = (tightBytesPerRow +
        (kMacWSMetalIOSurfaceRowAlignment - 1)) &
        ~(kMacWSMetalIOSurfaceRowAlignment - 1);
    if (height > SIZE_MAX / bytesPerRow) return NULL;
    NSDictionary *properties = @{
        (__bridge id)kIOSurfaceWidth: @(width),
        (__bridge id)kIOSurfaceHeight: @(height),
        (__bridge id)kIOSurfaceBytesPerElement: @4,
        (__bridge id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (__bridge id)kIOSurfaceAllocSize: @(bytesPerRow * height),
        (__bridge id)kIOSurfacePixelFormat: @(0x42475241u),
    };
    IOSurfaceRef surface = IOSurfaceCreate(
        (__bridge CFDictionaryRef)properties);
    if (!surface) return NULL;
    IOReturn lockResult = IOSurfaceLock(surface, 0, NULL);
    if (lockResult != kIOReturnSuccess) {
        CFRelease(surface);
        return NULL;
    }
    uint32_t *pixels = IOSurfaceGetBaseAddress(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface) / sizeof(uint32_t);
    if (!pixels || stride < width) {
        IOSurfaceUnlock(surface, 0, NULL);
        CFRelease(surface);
        return NULL;
    }
    // Opaque graphite is only the desktop backing. Real wallpaper, menu bar,
    // Dock and application windows arrive as native SkyLight capture layers.
    // It also provides deterministic pixels when a desktop element declines
    // capture instead of exposing uninitialised IOSurface memory.
    for (size_t y = 0; y < height; y++) {
        uint32_t *row = pixels + y * stride;
        for (size_t x = 0; x < width; x++) row[x] = 0xff25282du;
    }
    IOSurfaceUnlock(surface, 0, NULL);
    client.windowBackingScale = backingScale;
    return surface;
}

static void SendLayerRemoved(MacWSDisplayClient *client,
                             MacWSTransientLayer *layer) {
    if (!client.connection || client.deliveryPaused) return;
    if (!layer || layer.windowID == 0) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_LAYER_REMOVED);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_WINDOW_ID,
                              client.windowID);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_LAYER_WINDOW_ID,
                              layer.windowID);
    // This is the exact ordered cutoff for the producer generation. A return
    // republish increments layer.sequence in PublishFrame, allowing Host to
    // distinguish it from an already-queued pre-removal frame without
    // restarting the real CGDisplayStream.
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_STREAM_ID,
                              layer.streamID);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_SEQUENCE,
                              layer.sequence);
    xpc_connection_send_message(client.connection, event);
}

static void AppendLayerGeometry(NSMutableData *batch,
                                MacWSDisplayClient *client,
                                MacWSTransientLayer *layer,
                                uint64_t displayTime) {
    if (!batch || !client || !layer || !layer.latestSurface ||
        layer.retiring || batch.length / sizeof(MacWSStreamLayerGeometry) >=
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    uint32_t flags = MacWSStreamFrameOverlay |
        ([layer.ownerName isEqualToString:@"Dock"]
            ? MacWSStreamFrameGlobalSystemSurface : 0) |
        (layer.skyLightLayer >= CGWindowLevelForKey(kCGCursorWindowLevelKey)
            ? MacWSStreamFrameInputPassthrough : 0);
    MacWSStreamLayerGeometry geometry = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamLayerGeometry),
        .streamID = layer.streamID,
        .sequence = ++layer.sequence,
        .displayTime = displayTime,
        .windowID = client.windowID,
        .layerWindowID = layer.windowID,
        .layerOwnerPID = layer.ownerPID,
        .layerLevel = layer.level,
        .destinationX = (int32_t)llround(layer.destinationBounds.origin.x),
        .destinationY = (int32_t)llround(layer.destinationBounds.origin.y),
        .destinationWidth = (uint32_t)llround(
            layer.destinationBounds.size.width),
        .destinationHeight = (uint32_t)llround(
            layer.destinationBounds.size.height),
        .flags = flags,
    };
    if (!MacWSStreamLayerGeometryIsValid(&geometry, sizeof(geometry))) {
        // Do not consume an invalid sequence. The next real content frame or
        // valid geometry transaction remains contiguous and authoritative.
        layer.sequence--;
        return;
    }
    [layer recordActiveFrameAtDisplayTime:displayTime];
    layer.latestDisplayTime = displayTime;
    [batch appendBytes:&geometry length:sizeof(geometry)];
}

static void SendLayerGeometryBatch(MacWSDisplayClient *client,
                                   NSData *batch) {
    if (!client.connection || client.deliveryPaused || !batch.length ||
        batch.length % sizeof(MacWSStreamLayerGeometry) != 0 ||
        batch.length / sizeof(MacWSStreamLayerGeometry) >
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_LAYER_GEOMETRY);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_WINDOW_ID,
                              client.windowID);
    xpc_dictionary_set_data(event, MACWS_STREAM_KEY_LAYER_GEOMETRY,
                            batch.bytes, batch.length);
    xpc_connection_send_message(client.connection, event);
}

static double WorkspaceMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return 0.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return 0.0;
    return (double)(end - start) * timebase.numer / timebase.denom / 1.0e6;
}

static void FinishWorkspaceGeometryBurst(void) {
    if (!WorkspaceGeometryBurstActive) return;
    WorkspaceGeometryBurstActive = NO;
    if (!MacWSDisplayDiagnosticsEnabled()) {
        WorkspaceGeometryQueryDurationCount = 0;
        WorkspaceGeometryQueryDurationCursor = 0;
        return;
    }
    NSUInteger count = MIN(WorkspaceGeometryQueryDurationCount,
        sizeof(WorkspaceGeometryQueryDurationsMS) /
            sizeof(WorkspaceGeometryQueryDurationsMS[0]));
    if (count) {
        double durations[256];
        double total = 0.0;
        for (NSUInteger index = 0; index < count; index++) {
            durations[index] = WorkspaceGeometryQueryDurationsMS[index];
            total += durations[index];
        }
        qsort(durations, count, sizeof(durations[0]),
              MacWSCompareFrameInterval);
        NSUInteger p50Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.50) - 1);
        NSUInteger p95Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.95) - 1);
        NSUInteger p99Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.99) - 1);
        DisplayLog(@"workspace-geometry-burst queries=%llu records=%llu "
                   "query-mean-ms=%.3f p50-ms=%.3f p95-ms=%.3f "
                   "p99-ms=%.3f route=targeted-description-async",
                   (unsigned long long)WorkspaceGeometryQuerySamples,
                   (unsigned long long)WorkspaceGeometryRecordsSent,
                   total / count, durations[p50Index], durations[p95Index],
                   durations[p99Index]);
    }
}

static void ApplyWorkspaceGeometryDescriptions(
        NSArray<NSDictionary *> *descriptions, uint64_t displayTime) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *byWindow =
        [NSMutableDictionary dictionaryWithCapacity:descriptions.count];
    for (NSDictionary *info in descriptions) {
        NSNumber *windowID = info[(id)kCGWindowNumber];
        if (windowID.unsignedIntValue) byWindow[windowID] = info;
    }
    CGRect desktopBounds = CGDisplayBounds(CGMainDisplayID());
    if (CGRectIsEmpty(desktopBounds)) return;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen) continue;
        CGFloat scale = client.windowBackingScale > 0.0
            ? client.windowBackingScale : MainDisplayBackingScale();
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;
        NSMutableData *geometryBatch = [NSMutableData dataWithCapacity:
            MIN(client.transientLayers.count, (NSUInteger)
                MACWS_STREAM_MAX_LAYER_GEOMETRY) *
                sizeof(MacWSStreamLayerGeometry)];
        for (NSNumber *key in [client.transientLayers.allKeys copy]) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            NSDictionary *info = byWindow[key];
            if (!layer || layer.retiring || !layer.latestSurface || !info)
                continue;
            CGRect bounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &bounds) || CGRectIsEmpty(bounds)) continue;
            CGRect destination = CGRectMake(
                (bounds.origin.x - desktopBounds.origin.x) * scale,
                (bounds.origin.y - desktopBounds.origin.y) * scale,
                bounds.size.width * scale, bounds.size.height * scale);
            if (CGRectEqualToRect(layer.destinationBounds, destination))
                continue;
            layer.destinationBounds = destination;
            AppendLayerGeometry(geometryBatch, client, layer, displayTime);
        }
        WorkspaceGeometryRecordsSent += geometryBatch.length /
            sizeof(MacWSStreamLayerGeometry);
        SendLayerGeometryBatch(client, geometryBatch);
    }
}

static void RequestWorkspaceGeometrySample(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now >= WorkspaceAnimationSamplingDeadline) {
        if (WorkspaceGeometryBurstActive &&
            !WorkspaceGeometryQueryInFlight) {
            WorkspaceGeometryQueryPending = NO;
            FinishWorkspaceGeometryBurst();
            ScheduleTransientReconcile(0);
        }
        return;
    }
    if (WorkspaceGeometryQueryInFlight) {
        WorkspaceGeometryQueryPending = YES;
        return;
    }
    NSMutableOrderedSet<NSNumber *> *identifiers = [NSMutableOrderedSet
        orderedSet];
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen) continue;
        for (NSNumber *key in client.transientLayers) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            if (layer.latestSurface && !layer.retiring)
                [identifiers addObject:key];
        }
    }
    if (!identifiers.count) return;
    if (!WorkspaceGeometryBurstActive) {
        WorkspaceGeometryBurstActive = YES;
        WorkspaceGeometryQuerySamples = 0;
        WorkspaceGeometryRecordsSent = 0;
        WorkspaceGeometryQueryDurationCount = 0;
        WorkspaceGeometryQueryDurationCursor = 0;
        memset(WorkspaceGeometryQueryDurationsMS, 0,
               sizeof(WorkspaceGeometryQueryDurationsMS));
    }
    WorkspaceGeometryQueryInFlight = YES;
    WorkspaceGeometryQueryPending = NO;
    uint64_t generation = ++WorkspaceGeometryQueryGeneration;
    NSArray<NSNumber *> *windowIDs = identifiers.array;
    uint64_t queryStarted = mach_absolute_time();
    dispatch_async(WorkspaceGeometryQueue, ^{
        @autoreleasepool {
            NSArray<NSDictionary *> *descriptions =
                CopyWindowDescriptions(windowIDs);
            uint64_t queryFinished = mach_absolute_time();
            dispatch_async(DisplayQueue, ^{
                WorkspaceGeometryQueryInFlight = NO;
                if (generation != WorkspaceGeometryQueryGeneration) return;
                double duration = WorkspaceMachMilliseconds(queryStarted,
                                                             queryFinished);
                NSUInteger capacity =
                    sizeof(WorkspaceGeometryQueryDurationsMS) /
                    sizeof(WorkspaceGeometryQueryDurationsMS[0]);
                WorkspaceGeometryQueryDurationsMS[
                    WorkspaceGeometryQueryDurationCursor] = duration;
                WorkspaceGeometryQueryDurationCursor =
                    (WorkspaceGeometryQueryDurationCursor + 1) % capacity;
                if (WorkspaceGeometryQueryDurationCount < capacity)
                    WorkspaceGeometryQueryDurationCount++;
                WorkspaceGeometryQuerySamples++;
                ApplyWorkspaceGeometryDescriptions(descriptions,
                                                    queryFinished);

                CFTimeInterval completedAt = CFAbsoluteTimeGetCurrent();
                if (completedAt < WorkspaceAnimationSamplingDeadline) {
                    const double frameBudgetMS = 1000.0 / 60.0;
                    uint64_t delay = duration < frameBudgetMS
                        ? (uint64_t)llround((frameBudgetMS - duration) *
                                           NSEC_PER_MSEC)
                        : 0;
                    // A queued real Dock progress edge wins over the cadence
                    // timer, but both collapse through the in-flight gate.
                    if (WorkspaceGeometryQueryPending) delay = 0;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                                   DisplayQueue, ^{
                        RequestWorkspaceGeometrySample();
                    });
                } else {
                    WorkspaceGeometryQueryPending = NO;
                    FinishWorkspaceGeometryBurst();
                    // Presentation sampling deliberately ignores topology.
                    // One authoritative full snapshot now discovers/removes
                    // transition windows after Dock's native animation ends.
                    ScheduleTransientReconcile(0);
                }
            });
        }
    });
}

static void DrainOneRetiredTransientStop(void) {
    if (RetiredTransientStopBlocks.count == 0) {
        RetiredTransientStopDrainPending = NO;
        return;
    }
    dispatch_block_t stopBlock = RetiredTransientStopBlocks.firstObject;
    [RetiredTransientStopBlocks removeObjectAtIndex:0];
    stopBlock();
    if (RetiredTransientStopBlocks.count == 0) {
        RetiredTransientStopDrainPending = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        DrainOneRetiredTransientStop();
    });
}

static void EnqueueRetiredTransientStop(dispatch_block_t stopBlock) {
    if (!stopBlock) return;
    [RetiredTransientStopBlocks addObject:[stopBlock copy]];
    DisplayLog(@"layer-retire-stop-queued depth=%lu interval-ms=16",
               (unsigned long)RetiredTransientStopBlocks.count);
    if (RetiredTransientStopDrainPending) return;
    RetiredTransientStopDrainPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        DrainOneRetiredTransientStop();
    });
}

static void RetireTransientLayer(MacWSDisplayClient *client,
                                 NSNumber *key,
                                 MacWSTransientLayer *layer,
                                 NSString *reason) {
    if (!client || !key || !layer || layer.retiring) return;
    layer.retiring = YES;
    [layer finishActiveFrameBurstWithReason:@"catalog-retire"];
    uint64_t generation = ++layer.retirementGeneration;
    // Detach delivery immediately: Host has already removed this layer and a
    // final frame racing from the old stream must not resurrect stale pixels.
    layer.client = nil;
    if (![RetiredTransientLayers containsObject:layer])
        [RetiredTransientLayers addObject:layer];
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{ (void)mach_timebase_info(&timebase); });
    double elapsed = 0.0;
    if (timebase.denom && layer.firstDisplayTime &&
        layer.latestDisplayTime >= layer.firstDisplayTime) {
        elapsed = (double)(layer.latestDisplayTime - layer.firstDisplayTime) *
            timebase.numer / timebase.denom / 1.0e9;
    }
    NSUInteger outstanding = OutstandingFramesForLayer(client,
                                                         layer.windowID);
    DisplayLog(@"layer-retire-begin layer=%u reason=%@ grace-ms=5000 "
               "frames=%llu elapsed=%.3f fps=%.2f outstanding=%lu "
               "dropped=%llu",
               layer.windowID, reason ?: @"catalog-removed",
               (unsigned long long)layer.sequence, elapsed,
               elapsed > 0.0 && layer.sequence > 1
                   ? (layer.sequence - 1) / elapsed : 0.0,
               (unsigned long)outstanding,
               (unsigned long long)layer.droppedFrames);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   DisplayQueue, ^{
        if (!layer.retiring ||
            layer.retirementGeneration != generation) return;
        // If the same SkyLight window ID returned during the grace period,
        // reconciliation cancels this retirement and reuses the live stream.
        if (client.transientLayers[key] != layer) {
            [RetiredTransientLayers removeObject:layer];
            return;
        }
        EnqueueRetiredTransientStop(^{
            // The catalog may have restored this exact window in the short
            // interval between the grace expiry and its staggered drain slot.
            if (!layer.retiring ||
                layer.retirementGeneration != generation ||
                client.transientLayers[key] != layer) {
                [RetiredTransientLayers removeObject:layer];
                return;
            }
            [layer stopStream];
            [client.transientLayers removeObjectForKey:key];
            [RetiredTransientLayers removeObject:layer];
            DisplayLog(@"layer-retire-complete layer=%u reason=%@",
                       layer.windowID, reason ?: @"catalog-removed");
        });
    });
}

static void StartTransientLayer(MacWSTransientLayer *layer) {
    MacWSDisplayClient *client = layer.client;
    if (!client || layer.windowID == 0) return;
    // Preserve the last complete IOSurface while SkyLight retires/recreates
    // the exact-window stream. Host can keep compositing it at the newly
    // committed destination instead of flashing a black hole during resize.
    [layer stopCapturePreservingSurface];
    layer.streamID = NextStreamID++;
    if (layer.streamID == 0) layer.streamID = NextStreamID++;
    layer.droppedFrames = 0;
    layer.firstDisplayTime = 0;
    layer.snapshotComplete = NO;
    uint64_t generation = layer.streamID;
    __weak MacWSTransientLayer *weakLayer = layer;
    CGDisplayStreamFrameAvailableHandler handler =
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
            (void)updateRef;
            MacWSTransientLayer *strongLayer = weakLayer;
            MacWSDisplayClient *strongClient = strongLayer.client;
            if (!strongLayer || !strongClient ||
                strongLayer.streamID != generation) return;
            if (status == kCGDisplayStreamFrameStatusFrameComplete) {
                PublishFrame(strongClient, strongLayer, displayTime,
                             frameSurface);
                if (strongLayer.oneShotCapture &&
                    !strongLayer.snapshotComplete) {
                    strongLayer.snapshotComplete = YES;
                    // Wallpaper/backing streams have fulfilled their only
                    // job after one complete native IOSurface. Stop capture
                    // on the next display-queue turn while retaining that
                    // immutable surface for Host composition.
                    dispatch_async(DisplayQueue, ^{
                        MacWSTransientLayer *snapshotLayer = weakLayer;
                        if (!snapshotLayer ||
                            snapshotLayer.streamID != generation ||
                            !snapshotLayer.oneShotCapture ||
                            !snapshotLayer.snapshotComplete) return;
                        [snapshotLayer stopCapturePreservingSurface];
                        DisplayLog(@"workspace-layer-snapshot stream=%llu layer=%u owner=%@ name=%@",
                            (unsigned long long)generation,
                            snapshotLayer.windowID,
                            snapshotLayer.ownerName ?: @"",
                            snapshotLayer.windowName ?: @"");
                    });
                }
            }
        };
    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow) return;
    layer.stream = createWindow(layer.windowID, false,
        (__bridge CFDictionaryRef)StreamProperties(), DisplayQueue, handler);
    if (!layer.stream) return;
    CGError error = CGDisplayStreamStart(layer.stream);
    if (error != kCGErrorSuccess) {
        [layer stopCapturePreservingSurface];
        DisplayLog(@"layer-start failed base=%u layer=%u error=%d",
                   client.windowID, layer.windowID, error);
        return;
    }
    DisplayLog(@"layer-start stream=%llu base=%u layer=%u level=%d "
               "owner-pid=%d owner=%@ name=%@ skylight-layer=%ld "
               "destination=(%.0f,%.0f %.0fx%.0f)",
        (unsigned long long)layer.streamID, client.windowID, layer.windowID,
        layer.level, layer.ownerPID, layer.ownerName ?: @"",
        layer.windowName ?: @"", (long)layer.skyLightLayer,
        layer.destinationBounds.origin.x,
        layer.destinationBounds.origin.y, layer.destinationBounds.size.width,
        layer.destinationBounds.size.height);
}

static void StartClientStream(MacWSDisplayClient *client) {
    [client stopStream];
    client.streamID = NextStreamID++;
    if (client.streamID == 0) client.streamID = NextStreamID++;
    client.droppedFrames = 0;
    client.firstDisplayTime = 0;
    if (client.mode == MacWSStreamModeFullscreen) {
        client.workspaceCanvas = CreateWorkspaceCanvas(client);
        if (!client.workspaceCanvas) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"无法创建 Retina 桌面 IOSurface 画布", NO);
            return;
        }
        IOSurfaceRef base = FinalCompositeSurface
            ? FinalCompositeSurface : client.workspaceCanvas;
        uint64_t baseTime = FinalCompositeSurface
            ? FinalCompositeRecord.completionTime : mach_absolute_time();
        PublishFrame(client, nil, baseTime, base);
        DisplayLog(@"workspace-start id=%llu display=%zux%zu scale=%.3f transport=%@",
                   (unsigned long long)client.streamID,
                   IOSurfaceGetWidth(base), IOSurfaceGetHeight(base),
                   client.windowBackingScale,
                   FinalCompositeSurface
                       ? @"final-composite-iosurface"
                       : @"window-iosurface-composite");
        return;
    }
    client.stream = CreateStream(client);
    if (!client.stream) {
        SendStatus(client, MACWS_STREAM_EVENT_ERROR,
            client.mode == MacWSStreamModeWindow
                ? @"无法创建 SkyLight window DisplayStream"
                : @"无法创建 fullscreen CGDisplayStream", NO);
        return;
    }
    CGError error = CGDisplayStreamStart(client.stream);
    if (error != kCGErrorSuccess) {
        NSString *message = [NSString stringWithFormat:
            @"CGDisplayStreamStart failed: %d", error];
        [client stopStream];
        SendStatus(client, MACWS_STREAM_EVENT_ERROR, message, NO);
        return;
    }
    DisplayLog(@"stream-start id=%llu mode=%u window=%u exact=%s",
        (unsigned long long)client.streamID, client.mode, client.windowID,
        client.mode == MacWSStreamModeWindow ? "YES" : "NO");
}

// SLSHWCaptureStreamCreateWithWindow fixes its output shape when the stream is
// created. Runtime evidence on VSCode window 512 was unambiguous: AppKit
// accepted 934x592 -> 785x592, while stream 255 continued publishing a
// 1868x1184 IOSurface, producing portrait black bars and a stale input map.
// Recreate exact-window streams after the final geometry invalidation. The
// serial is a debounce boundary for live Stage Manager resizing; no frame-time
// polling or aspect stretching is involved.
static void ScheduleGeometryStreamRestart(void) {
    uint64_t serial = atomic_fetch_add_explicit(
        &GeometryRestartSerial, 1, memory_order_relaxed) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        if (serial != atomic_load_explicit(
                &GeometryRestartSerial, memory_order_relaxed)) return;
        for (MacWSDisplayClient *client in [Clients copy]) {
            if (client.mode != MacWSStreamModeWindow || client.windowID == 0)
                continue;
            uint32_t expectedWidth = 0, expectedHeight = 0;
            NSValue *targetValue = nil;
            @synchronized (GeometryTargets) {
                targetValue = GeometryTargets[@(client.windowID)];
                if (targetValue)
                    [GeometryTargets removeObjectForKey:@(client.windowID)];
            }
            if (targetValue) {
                MacWSGeometryInvalidation target = {0};
                [targetValue getValue:&target];
                expectedWidth = target.pixelWidth;
                expectedHeight = target.pixelHeight;
            } else {
                CGRect bounds = CGRectZero;
                CGFloat scale = client.windowBackingScale > 0.0
                    ? client.windowBackingScale : MainDisplayBackingScale();
                if (CopyWindowBounds(client.windowID, &bounds) && scale > 0.0) {
                    expectedWidth = (uint32_t)llround(
                        bounds.size.width * scale);
                    expectedHeight = (uint32_t)llround(
                        bounds.size.height * scale);
                }
            }
            // A stale Scene subscription can briefly outlive its CGWindow.
            // With no committed target and no catalog bounds there is no
            // geometry invariant to restore, so leave it alone rather than
            // blindly restarting an already-orphaned capture stream.
            if (expectedWidth == 0 || expectedHeight == 0) continue;
            if (client.lastSurfaceWidth == expectedWidth &&
                client.lastSurfaceHeight == expectedHeight) {
                continue;
            }
            DisplayLog(@"geometry-stream-restart window=%u old-stream=%llu current=%zux%zu expected=%ux%u phase=stop",
                       client.windowID,
                       (unsigned long long)client.streamID,
                       client.lastSurfaceWidth, client.lastSurfaceHeight,
                       expectedWidth, expectedHeight);
            uint64_t restartGeneration = ++client.geometryRestartGeneration;
            uint32_t restartWindowID = client.windowID;
            client.windowBackingScale = 0.0;
            [client stopTransientLayers];
            [client stopStream];
            // Runtime-confirmed on Maps/System Settings: recreating in the
            // same display-queue turn eventually made
            // SLSHWCaptureStreamCreateWithWindow return NULL for every Scene;
            // reloading displayd immediately restored creation.  Leave one
            // bounded release interval for SkyLight to retire the old graph.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           DisplayQueue, ^{
                if (![Clients containsObject:client] ||
                    !client.subscriptionActive ||
                    client.mode != MacWSStreamModeWindow ||
                    client.windowID != restartWindowID ||
                    client.geometryRestartGeneration != restartGeneration)
                    return;
                DisplayLog(@"geometry-stream-restart window=%u generation=%llu phase=create",
                           client.windowID,
                           (unsigned long long)restartGeneration);
                StartClientStream(client);
                ScheduleTransientReconcile(0);
            });
        }
        ScheduleTransientReconcile(0);
    });
}

static void StartSubscription(MacWSDisplayClient *client,
                              MacWSStreamMode mode, uint32_t windowID) {
    client.geometryRestartGeneration++;
    if (mode == MacWSStreamModeFullscreen) {
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            // UIKit can briefly resign/reactivate the same fullscreen Scene
            // during app launch and system fullscreen transactions. Resume
            // this client's retained graph instead of treating the identical
            // subscription as a request to allocate a second desktop graph.
            client.deliveryPaused = NO;
            client.disconnectGeneration++;
            DisplayLog(@"workspace-resume stream=%llu layers=%lu transport=retained-graph",
                       (unsigned long long)client.streamID,
                       (unsigned long)client.transientLayers.count);
            IOSurfaceRef retainedBase = FinalCompositeSurface
                ? FinalCompositeSurface : client.workspaceCanvas;
            if (retainedBase)
                PublishFrame(client, nil,
                    FinalCompositeSurface
                        ? FinalCompositeRecord.completionTime
                        : mach_absolute_time(), retainedBase);
            for (MacWSTransientLayer *layer in
                    client.transientLayers.allValues) {
                if (layer.latestSurface)
                    PublishFrame(client, layer,
                        layer.latestDisplayTime ?: mach_absolute_time(),
                        layer.latestSurface);
            }
            ScheduleTransientReconcile(0);
            return;
        }
        // Runtime-confirmed on 2026-08-03: a stale fullscreen client kept
        // stream 10 and its desktop layers alive while the foreground Scene
        // created workspace stream 55.  The duplicated Retina capture graphs
        // were immediately followed by WindowServer AGX command-buffer error
        // 00000103 and a producer restart.  Fullscreen is one shared physical
        // macOS desktop, so transfer its producer ownership atomically to the
        // newest foreground subscriber instead of cloning the graph.
        MacWSDisplayClient *owner = nil;
        for (MacWSDisplayClient *candidate in [Clients copy]) {
            if (candidate != client && candidate.subscriptionActive &&
                candidate.mode == MacWSStreamModeFullscreen) {
                owner = candidate;
                break;
            }
        }
        if (owner) {
            BOOL ownerDisconnected = owner.connection == nil;
            owner.disconnectGeneration++;
            // Stop only this client's former exact-window graph.  The desktop
            // graph remains running and its layer callbacks dynamically read
            // layer.client, so moving the layer objects changes the XPC sink
            // without overlapping CGDisplayStreamStop/Create operations.
            [client stopTransientLayers];
            [client stopStream];
            client.outstandingByLayer = [NSMutableDictionary dictionary];
            client.subscriptionActive = YES;
            client.deliveryPaused = NO;
            client.mode = MacWSStreamModeFullscreen;
            client.windowID = 0;
            client.streamID = owner.streamID;
            client.sequence = owner.sequence;
            client.droppedFrames = owner.droppedFrames;
            client.firstDisplayTime = owner.firstDisplayTime;
            client.windowBackingScale = owner.windowBackingScale;
            client.lastSurfaceWidth = owner.lastSurfaceWidth;
            client.lastSurfaceHeight = owner.lastSurfaceHeight;
            client.workspaceCanvas = owner.workspaceCanvas;
            owner.workspaceCanvas = NULL;
            client.transientLayers = owner.transientLayers ?:
                [NSMutableDictionary dictionary];
            owner.transientLayers = [NSMutableDictionary dictionary];
            for (MacWSTransientLayer *layer in
                    client.transientLayers.allValues) {
                layer.client = client;
            }

            owner.subscriptionActive = NO;
            owner.deliveryPaused = NO;
            owner.mode = 0;
            owner.windowID = 0;
            owner.streamID = 0;
            owner.sequence = 0;
            owner.firstDisplayTime = 0;
            owner.droppedFrames = 0;
            owner.windowBackingScale = 0;
            owner.lastSurfaceWidth = 0;
            owner.lastSurfaceHeight = 0;

            DisplayLog(@"workspace-handoff stream=%llu layers=%lu new-client=%p transport=live-graph-transfer",
                       (unsigned long long)client.streamID,
                       (unsigned long)client.transientLayers.count, client);
            // Republish the retained current generation before waiting for a
            // future damage callback; static wallpaper/menu layers may not
            // otherwise emit another frame for the new Scene.
            IOSurfaceRef retainedBase = FinalCompositeSurface
                ? FinalCompositeSurface : client.workspaceCanvas;
            if (retainedBase) {
                PublishFrame(client, nil,
                    FinalCompositeSurface
                        ? FinalCompositeRecord.completionTime
                        : mach_absolute_time(), retainedBase);
            }
            NSArray<MacWSTransientLayer *> *layers =
                [client.transientLayers.allValues
                    sortedArrayUsingComparator:^NSComparisonResult(
                        MacWSTransientLayer *left,
                        MacWSTransientLayer *right) {
                    if (left.level < right.level) return NSOrderedAscending;
                    if (left.level > right.level) return NSOrderedDescending;
                    if (left.windowID < right.windowID)
                        return NSOrderedAscending;
                    if (left.windowID > right.windowID)
                        return NSOrderedDescending;
                    return NSOrderedSame;
                }];
            for (MacWSTransientLayer *layer in layers) {
                if (layer.latestSurface) {
                    PublishFrame(client, layer,
                        layer.latestDisplayTime ?: mach_absolute_time(),
                        layer.latestSurface);
                }
            }
            SendStatus(owner, MACWS_STREAM_EVENT_STOPPED,
                       @"全屏工作区已转移到当前前台窗口", YES);
            // A disconnected owner was retained solely as a short handoff
            // carrier. Its graph and retained surfaces now belong to the new
            // client, and its outstanding leases were cleared at disconnect,
            // so removing the empty shell performs no CGDisplayStream stop.
            if (ownerDisconnected) [Clients removeObject:owner];
            ScheduleTransientReconcile(0);
            return;
        }
    }
    client.subscriptionActive = YES;
    client.deliveryPaused = NO;
    client.mode = mode;
    client.windowID = mode == MacWSStreamModeWindow ? windowID : 0;
    client.windowBackingScale = 0.0;
    [client stopTransientLayers];
    StartClientStream(client);
    ScheduleTransientReconcile(0);
}

// Menus, popovers and sheets are real nonzero-layer SkyLight windows. Runtime
// evidence on the target iPad shows their exact window capture streams produce
// Retina IOSurfaces, while the full-display CGDisplayStream produces no first
// frame under WindowServer -virtualonly. Keep the base stream permanently
// exact and attach each same-owner transient as an independent native layer.
// Host composites the layers with Metal; no RFB, CPU copy, or stream-mode
// restart is involved.
static void ReconcileTransientStreams(void) {
    TransientReconcilePending = NO;
    BOOL urgentRetireConfirmation = UrgentTransientRetirePasses > 0;
    if (UrgentTransientRetirePasses > 0) UrgentTransientRetirePasses--;
    // Fullscreen owns an exclusive desktop capture graph and does not need
    // the application-only catalog.  Keeping this eager performed two full
    // CGWindow snapshots on every 60-Hz native gesture sample; load the second
    // list only if a window-mode client actually exists.
    NSArray<NSDictionary *> *windowInfo = nil;
    NSArray<NSDictionary *> *desktopInfo = nil;
    BOOL needsFollowup = NO;
    BOOL windowMissingLayerNeedsConfirmation = NO;
    BOOL workspaceNeedsFollowup = NO;
    BOOL workspaceMissingLayerNeedsConfirmation = NO;
    BOOL urgentPopupPresent = NO;
    BOOL workspacePresentationChanged = NO;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused) continue;
        if (client.mode == MacWSStreamModeFullscreen) {
            if (!desktopInfo) desktopInfo = CopyCompleteDesktopWindowInfo();
            CGRect desktopBounds = CGDisplayBounds(CGMainDisplayID());
            CGFloat scale = client.windowBackingScale > 0.0
                ? client.windowBackingScale : MainDisplayBackingScale();
            if (CGRectIsEmpty(desktopBounds) || !isfinite(scale) ||
                scale < 0.5 || scale > 8.0) continue;
            if (!client.transientLayers)
                client.transientLayers = [NSMutableDictionary dictionary];
            NSMutableData *geometryBatch = [NSMutableData dataWithCapacity:
                MIN(client.transientLayers.count, (NSUInteger)
                    MACWS_STREAM_MAX_LAYER_GEOMETRY) *
                    sizeof(MacWSStreamLayerGeometry)];
            uint64_t geometryDisplayTime = mach_absolute_time();
            NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
            NSUInteger attached = 0;
            NSUInteger count = desktopInfo.count;
            // The frontmost full-display negative-level window is Finder's
            // interactive desktop on the target runtime and must remain live
            // for icon selection. Lower negative layers are compositor
            // backing/wallpaper: capture one authoritative frame, then retain
            // it without keeping several redundant Retina streams active.
            uint32_t frontmostInteractiveDesktopWindowID = 0;
            for (NSDictionary *candidate in desktopInfo) {
                NSInteger candidateLevel =
                    [candidate[(id)kCGWindowLayer] integerValue];
                CGRect candidateBounds = CGRectZero;
                if (candidateLevel >= 0 ||
                    !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)
                            candidate[(id)kCGWindowBounds],
                        &candidateBounds) ||
                    !CGRectContainsRect(candidateBounds, desktopBounds))
                    continue;
                frontmostInteractiveDesktopWindowID =
                    [candidate[(id)kCGWindowNumber] unsignedIntValue];
                if (frontmostInteractiveDesktopWindowID != 0) break;
            }
            for (NSUInteger index = 0; index < count; index++) {
                NSDictionary *info = desktopInfo[index];
                uint32_t candidateWindowID =
                    [info[(id)kCGWindowNumber] unsignedIntValue];
                NSInteger candidateSkyLightLayer =
                    [info[(id)kCGWindowLayer] integerValue];
                // runtime-confirmed on iPad13,6 on 2026-08-12: WindowServer
                // publishes its black 34x46 `Cursor` as window 3 at
                // SkyLight layer 2147483630. Host already renders its own
                // direct-touch/trackpad/Pencil affordance, so composing that
                // hardware cursor creates a duplicate visual pointer. Cursor-
                // level surfaces are presentation-only and never belong in
                // the macOS desktop layer graph consumed by Host.
                if (candidateSkyLightLayer >=
                    CGWindowLevelForKey(kCGCursorWindowLevelKey)) continue;
                if (attached >= 48 || candidateWindowID == 0 ||
                    [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
                CGRect candidateBounds = CGRectZero;
                if (!CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                        &candidateBounds) || CGRectIsEmpty(candidateBounds) ||
                    !CGRectIntersectsRect(desktopBounds, candidateBounds))
                    continue;
                NSNumber *key = @(candidateWindowID);
                // A compositor layer is identified by its CGWindow ID.  Even
                // if SkyLight momentarily exposes the same ID more than once
                // while rebuilding the desktop list, it must still own only
                // one capture stream in this reconciliation transaction.
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                attached++;
                MacWSTransientLayer *layer = client.transientLayers[key];
                BOOL isNew = layer == nil;
                if (isNew) {
                    layer = [MacWSTransientLayer new];
                    layer.client = client;
                    layer.windowID = candidateWindowID;
                    client.transientLayers[key] = layer;
                }
                BOOL returnedFromCatalog = layer.retiring;
                if (returnedFromCatalog) {
                    layer.retiring = NO;
                    layer.retirementGeneration++;
                    [RetiredTransientLayers removeObject:layer];
                    DisplayLog(@"layer-retire-cancel layer=%u reason=window-returned",
                               layer.windowID);
                }
                layer.client = client;
                layer.ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
                id ownerName = info[(id)kCGWindowOwnerName];
                layer.ownerName = [ownerName isKindOfClass:NSString.class]
                    ? ownerName : @"";
                id windowName = info[(id)kCGWindowName];
                layer.windowName = [windowName isKindOfClass:NSString.class]
                    ? windowName : @"";
                layer.skyLightLayer = candidateSkyLightLayer;
                if (urgentRetireConfirmation &&
                    layer.skyLightLayer >=
                        CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) &&
                    layer.skyLightLayer <
                        CGWindowLevelForKey(kCGCursorWindowLevelKey))
                    urgentPopupPresent = YES;
                BOOL desiredOneShot = layer.skyLightLayer < 0 &&
                    CGRectContainsRect(candidateBounds, desktopBounds) &&
                    candidateWindowID != frontmostInteractiveDesktopWindowID;
                // Bind capture lifetime to the window identity that created
                // it, not to a later catalog rank.  During cold desktop
                // bootstrap the WindowServer backing, Dock wallpaper and
                // Finder desktop appear in separate snapshots; the previous
                // code reclassified the old full-screen layer each time a
                // more-front negative layer arrived, synchronously stopping
                // and recreating the same CGWindow stream.  Runtime logs on
                // 2026-08-06 prove window 2 was restarted as streams 3 -> 5
                // and window 4 as streams 4 -> 13 during one cold recovery.
                // Separately, launchd records the preceding WindowServer's
                // last exit as OS_REASON_COREANIMATION; the duplicate starts
                // are not claimed as that abort's cause, but they directly
                // violate the one-window/one-stream invariant. A window's
                // immutable first-seen policy restores that invariant.
                // Retirement and a genuinely new ID still create a fresh
                // policy.
                if (isNew) layer.oneShotCapture = desiredOneShot;
                // CGWindowList is front-to-back. Host draws ascending levels,
                // so reverse that rank and preserve the actual desktop z-order
                // even when several ordinary windows all report layer zero.
                int32_t newLevel = (int32_t)MIN((NSUInteger)INT32_MAX,
                                                count - index);
                CGRect newDestination = CGRectMake(
                    (candidateBounds.origin.x - desktopBounds.origin.x) * scale,
                    (candidateBounds.origin.y - desktopBounds.origin.y) * scale,
                    candidateBounds.size.width * scale,
                    candidateBounds.size.height * scale);
                BOOL presentationChanged = !isNew &&
                    (layer.level != newLevel ||
                     !CGRectEqualToRect(layer.destinationBounds,
                                        newDestination));
                layer.level = newLevel;
                layer.destinationBounds = newDestination;
                layer.missCount = 0;
                workspacePresentationChanged |=
                    isNew || presentationChanged || returnedFromCatalog;
                if (isNew ||
                           (!layer.stream &&
                            !(layer.oneShotCapture &&
                              layer.snapshotComplete))) {
                    StartTransientLayer(layer);
                }
                // Window movement does not necessarily damage its backing
                // store. Send an ordered geometry record while retaining the
                // already-imported IOSurface; waiting for a future capture
                // callback made title-bar dragging update at the 250ms
                // catalog-poll cadence, while republishing the surface made
                // every moving layer acquire another Mach port and lease.
                // SendLayerRemoved detached this layer from Host as soon as
                // the native overview/Space catalog hid it. If Dock restores
                // the window to exactly its old z-order and bounds, an exact
                // CGDisplayStream has no content damage to report and
                // presentationChanged is false. Re-publish the retained real
                // IOSurface on catalog return or the window remains invisible
                // even though it never closed.
                if (returnedFromCatalog && layer.latestSurface) {
                    PublishFrame(client, layer, mach_absolute_time(),
                                 layer.latestSurface);
                } else if (presentationChanged && layer.latestSurface) {
                    AppendLayerGeometry(geometryBatch, client, layer,
                                        geometryDisplayTime);
                }
            }
            SendLayerGeometryBatch(client, geometryBatch);
            for (NSNumber *key in [client.transientLayers.allKeys copy]) {
                MacWSTransientLayer *layer = client.transientLayers[key];
                if ([seen containsObject:key]) continue;
                if (layer.retiring) continue;
                layer.missCount++;
                if (layer.missCount < 2) {
                    // A native popup can disappear between two AppKit
                    // catalog notifications. Confirm the first miss on the
                    // next display interval instead of waiting for the 1 s
                    // idle recovery poll; otherwise the already-closed menu
                    // remains visibly composited as a translucent ghost.
                    // Two independent CGWindow snapshots remain required, so
                    // a one-sample catalog transition cannot detach a live
                    // window.
                    workspaceMissingLayerNeedsConfirmation = YES;
                    continue;
                }
                DisplayLog(@"workspace-layer-remove layer=%u stream=%llu through=%llu",
                           layer.windowID,
                           (unsigned long long)layer.streamID,
                           (unsigned long long)layer.sequence);
                SendLayerRemoved(client, layer);
                RetireTransientLayer(client, key, layer,
                                     @"workspace-catalog-removed");
            }
            workspaceNeedsFollowup |= client.transientLayers.count != 0;
            continue;
        }
        if (client.mode != MacWSStreamModeWindow || client.windowID == 0)
            continue;
        if (!windowInfo) windowInfo = CopyOnScreenWindowInfo();
        NSDictionary *baseInfo = nil;
        for (NSDictionary *info in windowInfo) {
            if ([info[(id)kCGWindowNumber] unsignedIntValue] ==
                client.windowID) {
                baseInfo = info;
                break;
            }
        }
        CGRect baseBounds = CGRectZero;
        if (!baseInfo || !CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)baseInfo[(id)kCGWindowBounds],
                &baseBounds) || CGRectIsEmpty(baseBounds)) continue;
        int32_t ownerPID = [baseInfo[(id)kCGWindowOwnerPID] intValue];
        NSDictionary<NSNumber *, NSValue *> *processMetrics =
            CopyWindowMetrics(ownerPID);
        MacWSWindowMetricsEntry baseMetrics = {0};
        NSValue *baseMetricsValue = processMetrics[@(client.windowID)];
        if (baseMetricsValue) [baseMetricsValue getValue:&baseMetrics];
        CGFloat scale = client.windowBackingScale > 0.0
            ? client.windowBackingScale : MainDisplayBackingScale();
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;

        if (!client.transientLayers)
            client.transientLayers = [NSMutableDictionary dictionary];
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        NSUInteger attached = 0;
        for (NSDictionary *info in windowInfo) {
            uint32_t candidateWindowID =
                [info[(id)kCGWindowNumber] unsignedIntValue];
            NSInteger level = [info[(id)kCGWindowLayer] integerValue];
            MacWSWindowMetricsEntry candidateMetrics = {0};
            NSValue *candidateMetricsValue =
                processMetrics[@(candidateWindowID)];
            if (candidateMetricsValue)
                [candidateMetricsValue getValue:&candidateMetrics];
            BOOL logicalTransient = level == 0 &&
                (candidateMetrics.flags & MacWSStreamWindowTransient) != 0 &&
                baseMetrics.logicalGroupID != 0 &&
                candidateMetrics.logicalGroupID == baseMetrics.logicalGroupID;
            if (attached >= 8 || candidateWindowID == 0 ||
                candidateWindowID == client.windowID ||
                (level == 0 && !logicalTransient) ||
                [info[(id)kCGWindowOwnerPID] intValue] != ownerPID ||
                [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
            CGRect candidateBounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &candidateBounds) || CGRectIsEmpty(candidateBounds) ||
                !CGRectIntersectsRect(baseBounds, candidateBounds)) continue;

            NSNumber *key = @(candidateWindowID);
            [seen addObject:key];
            attached++;
            CGRect destination = CGRectMake(
                (candidateBounds.origin.x - baseBounds.origin.x) * scale,
                (candidateBounds.origin.y - baseBounds.origin.y) * scale,
                candidateBounds.size.width * scale,
                candidateBounds.size.height * scale);
            MacWSTransientLayer *layer = client.transientLayers[key];
            BOOL isNew = layer == nil;
            if (isNew) {
                layer = [MacWSTransientLayer new];
                layer.client = client;
                layer.windowID = candidateWindowID;
                client.transientLayers[key] = layer;
            }
            if (layer.retiring) {
                layer.retiring = NO;
                layer.retirementGeneration++;
                [RetiredTransientLayers removeObject:layer];
                DisplayLog(@"layer-retire-cancel layer=%u reason=window-returned",
                           layer.windowID);
            }
            layer.client = client;
            layer.ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
            id ownerName = info[(id)kCGWindowOwnerName];
            layer.ownerName = [ownerName isKindOfClass:NSString.class]
                ? ownerName : @"";
            id windowName = info[(id)kCGWindowName];
            layer.windowName = [windowName isKindOfClass:NSString.class]
                ? windowName : @"";
            layer.skyLightLayer = level;
            if (urgentRetireConfirmation &&
                layer.skyLightLayer >=
                    CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) &&
                layer.skyLightLayer <
                    CGWindowLevelForKey(kCGCursorWindowLevelKey))
                urgentPopupPresent = YES;
            // An AppKit sheet can be a level-0 SkyLight window even though it
            // belongs above its presenting document. The metrics sidecar is
            // the owning process's authoritative relationship; assign only
            // those children a synthetic positive compositor level.
            NSInteger compositorLevel = logicalTransient ? 1 : level;
            layer.level = (int32_t)MAX(INT32_MIN,
                MIN((NSInteger)INT32_MAX, compositorLevel));
            layer.destinationBounds = destination;
            layer.missCount = 0;
            if (isNew || !layer.stream) StartTransientLayer(layer);
        }

        for (NSNumber *key in [client.transientLayers.allKeys copy]) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            if ([seen containsObject:key]) continue;
            if (layer.retiring) continue;
            // A transient can briefly disappear from the on-screen catalog
            // while AppKit swaps its selection/shadow surface. Ordinary
            // recovery polling still requires three misses. A completed
            // semantic click is stronger evidence, but still requires two
            // independent snapshots; confirm its first miss on the next
            // display interval instead of leaving a closed translucent menu
            // visible until the 250 ms recovery poll runs twice.
            layer.missCount++;
            unsigned requiredMisses = urgentRetireConfirmation ? 2 : 3;
            if (layer.missCount < requiredMisses) {
                if (urgentRetireConfirmation)
                    windowMissingLayerNeedsConfirmation = YES;
                continue;
            }
            DisplayLog(@"layer-remove base=%u layer=%u stream=%llu through=%llu",
                       client.windowID, layer.windowID,
                       (unsigned long long)layer.streamID,
                       (unsigned long long)layer.sequence);
            SendLayerRemoved(client, layer);
            RetireTransientLayer(client, key, layer,
                                 @"window-catalog-removed");
        }
        if (client.transientLayers.count) needsFollowup = YES;
    }
    CFTimeInterval reconcileFinished = CFAbsoluteTimeGetCurrent();
    if (workspacePresentationChanged &&
        reconcileFinished < WorkspaceAnimationSettlementHardDeadline) {
        CFTimeInterval settlementDeadline = fmin(
            WorkspaceAnimationSettlementHardDeadline,
            reconcileFinished + 0.10);
        WorkspaceAnimationSamplingDeadline = fmax(
            WorkspaceAnimationSamplingDeadline, settlementDeadline);
    }
    BOOL workspaceAnimationSampling =
        reconcileFinished < WorkspaceAnimationSamplingDeadline;
    if (workspaceAnimationSampling) RequestWorkspaceGeometrySample();
    if ((needsFollowup || workspaceNeedsFollowup) &&
        !workspaceAnimationSampling) {
        // Native AppKit geometry/catalog datagrams now preempt this timer at
        // 16ms. The periodic pass is only a recovery net for non-AppKit system
        // producers, so an idle fullscreen desktop no longer scans four times
        // per second.
        uint64_t delayNanoseconds = 0;
        delayNanoseconds =
            ((workspaceMissingLayerNeedsConfirmation ||
              windowMissingLayerNeedsConfirmation)
                ? 16
                : (urgentPopupPresent &&
                   UrgentTransientRetirePasses > 0)
                    ? 50
                    : (workspaceNeedsFollowup ? 1000 : 250)) *
            NSEC_PER_MSEC;
        ScheduleTransientReconcile(delayNanoseconds);
    }
}

static void ScheduleTransientReconcile(uint64_t delayNanoseconds) {
    // A delayed follow-up is only a recovery poll. A geometry/catalog edge is
    // authoritative and must be able to preempt it. Generation cancellation
    // keeps at most one effective reconcile without relying on an
    // uncancellable dispatch_after block.
    if (TransientReconcilePending && delayNanoseconds != 0) return;
    TransientReconcilePending = YES;
    uint64_t generation = ++TransientReconcileGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
                   DisplayQueue, ^{
        if (generation != TransientReconcileGeneration) return;
        ReconcileTransientStreams();
    });
}

static void ReleaseLease(uint64_t token, MacWSDisplayClient *client) {
    MacWSDisplayLease *lease = Leases[@(token)];
    if (!lease || lease.owner != client) return;
    NSUInteger outstanding = OutstandingFramesForLayer(
        client, lease.layerWindowID);
    if (outstanding)
        SetOutstandingFramesForLayer(client, lease.layerWindowID,
                                     outstanding - 1);
    [Leases removeObjectForKey:@(token)];
}

static void RemoveClientLeases(MacWSDisplayClient *client) {
    NSArray<NSNumber *> *tokens = [Leases.allKeys copy];
    for (NSNumber *token in tokens) {
        MacWSDisplayLease *lease = Leases[token];
        if (lease.owner == client) [Leases removeObjectForKey:token];
    }
    [client.outstandingByLayer removeAllObjects];
}

static void RemoveClient(MacWSDisplayClient *client) {
    client.disconnectGeneration++;
    [client stopTransientLayers];
    [client stopStream];
    RemoveClientLeases(client);
    [Clients removeObject:client];
}

static void RetireFullscreenClientStaggered(MacWSDisplayClient *client) {
    if (![Clients containsObject:client]) return;
    client.disconnectGeneration++;
    NSArray<MacWSTransientLayer *> *layers =
        [client.transientLayers.allValues copy];
    // Detach first so removing/deallocating the client cannot synchronously
    // stop every Retina stream in one stack frame. Runtime evidence from
    // WindowServer.err showed that the old disconnect/reconnect burst was
    // followed by AGX command-buffer Internal Error 00000103 and a fresh
    // WindowServer PID.
    client.transientLayers = [NSMutableDictionary dictionary];
    [client stopStream];
    RemoveClientLeases(client);
    client.subscriptionActive = NO;
    client.deliveryPaused = NO;
    client.mode = 0;
    client.windowID = 0;
    client.streamID = 0;
    if (!client.connection) [Clients removeObject:client];
    DisplayLog(@"workspace-retire-staggered layers=%lu interval-ms=16",
               (unsigned long)layers.count);
    [layers enumerateObjectsUsingBlock:^(MacWSTransientLayer *layer,
                                         NSUInteger index, BOOL *stop) {
        (void)stop;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(index + 1) * 16 *
                                         NSEC_PER_MSEC),
                       DisplayQueue, ^{
            [layer stopStream];
            if (index + 1 == layers.count)
                DisplayLog(@"workspace-retire-complete layers=%lu",
                           (unsigned long)layers.count);
        });
    }];
}

static void PreserveFullscreenClientForHandoff(
        MacWSDisplayClient *client, BOOL disconnected) {
    if (disconnected) client.connection = nil;
    client.deliveryPaused = YES;
    RemoveClientLeases(client);
    uint64_t generation = ++client.disconnectGeneration;
    DisplayLog(@"workspace-%@-grace stream=%llu layers=%lu grace-ms=5000",
               disconnected ? @"disconnect" : @"pause",
               (unsigned long long)client.streamID,
               (unsigned long)client.transientLayers.count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   DisplayQueue, ^{
        if (![Clients containsObject:client] ||
            client.disconnectGeneration != generation ||
            !client.subscriptionActive ||
            !client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen ||
            (disconnected && client.connection)) return;
        DisplayLog(@"workspace-%@-grace-expired stream=%llu",
                   disconnected ? @"disconnect" : @"pause",
                   (unsigned long long)client.streamID);
        RetireFullscreenClientStaggered(client);
    });
}

static void HandleRequest(MacWSDisplayClient *client, xpc_object_t request) {
    if (request == XPC_ERROR_CONNECTION_INVALID ||
        request == XPC_ERROR_CONNECTION_INTERRUPTED) {
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            PreserveFullscreenClientForHandoff(client, YES);
        } else {
            RemoveClient(client);
        }
        return;
    }
    if (!request || xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
    const char *operation = xpc_dictionary_get_string(request,
                                                       MACWS_STREAM_KEY_OP);
    if (!operation) return;
    if (strcmp(operation, MACWS_STREAM_OP_HELLO) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_PROTOCOL_VERSION);
        if (version != MACWS_STREAM_VERSION) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"protocol version mismatch", NO);
            return;
        }
        SendStatus(client, MACWS_STREAM_EVENT_READY, @"ready", YES);
    } else if (strcmp(operation, MACWS_STREAM_OP_LIST_WINDOWS) == 0) {
        SendWindowList(client);
    } else if (strcmp(operation, MACWS_STREAM_OP_SUBSCRIBE) == 0) {
        MacWSStreamMode mode = (MacWSStreamMode)xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_MODE);
        uint64_t windowID = xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_WINDOW_ID);
        if ((mode != MacWSStreamModeFullscreen &&
             mode != MacWSStreamModeWindow) ||
            (mode == MacWSStreamModeWindow &&
             (windowID == 0 || windowID > UINT32_MAX))) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"invalid subscription", NO);
            return;
        }
        DisplayLog(@"request-subscribe client=%p requested-mode=%u window=%llu current-mode=%u active=%@ paused=%@ stream=%llu",
                   client, mode, (unsigned long long)windowID, client.mode,
                   client.subscriptionActive ? @"YES" : @"NO",
                   client.deliveryPaused ? @"YES" : @"NO",
                   (unsigned long long)client.streamID);
        StartSubscription(client, mode, (uint32_t)windowID);
    } else if (strcmp(operation, MACWS_STREAM_OP_UNSUBSCRIBE) == 0) {
        client.geometryRestartGeneration++;
        DisplayLog(@"request-unsubscribe client=%p current-mode=%u active=%@ stream=%llu",
                   client, client.mode,
                   client.subscriptionActive ? @"YES" : @"NO",
                   (unsigned long long)client.streamID);
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            PreserveFullscreenClientForHandoff(client, NO);
        } else {
            client.subscriptionActive = NO;
            client.deliveryPaused = NO;
            client.mode = 0;
            client.windowID = 0;
            [client stopTransientLayers];
            [client stopStream];
        }
    } else if (strcmp(operation, MACWS_STREAM_OP_RELEASE_FRAME) == 0) {
        ReleaseLease(xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_LEASE_TOKEN), client);
    } else if (strcmp(operation, MACWS_MENU_XPC_OP_SNAPSHOT) == 0 ||
               strcmp(operation, MACWS_MENU_XPC_OP_ACTION) == 0) {
        size_t byteCount = 0;
        const void *bytes = xpc_dictionary_get_data(
            request, MACWS_MENU_XPC_KEY_REQUEST, &byteCount);
        MacWSMenuRequest menuRequest = {0};
        if (!bytes || byteCount != sizeof(menuRequest)) return;
        memcpy(&menuRequest, bytes, sizeof(menuRequest));
        if (!MacWSMenuRequestIsValid(&menuRequest, sizeof(menuRequest)) ||
            (menuRequest.operation == MacWSMenuOperationSnapshot) !=
                (strcmp(operation, MACWS_MENU_XPC_OP_SNAPSHOT) == 0)) return;
        RelayMenuRequest(client, menuRequest);
    }
}

static void AcceptConnection(xpc_connection_t connection) {
    MacWSDisplayClient *client = [MacWSDisplayClient new];
    client.connection = connection;
    client.transientLayers = [NSMutableDictionary dictionary];
    client.outstandingByLayer = [NSMutableDictionary dictionary];
    [Clients addObject:client];
    xpc_connection_set_target_queue(connection, DisplayQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        HandleRequest(client, event);
    });
    xpc_connection_resume(connection);
}

int main(void) {
    @autoreleasepool {
        // Establish the AppKit display mapping once on the main thread. The
        // serial display queue then consumes only this immutable scalar on
        // catalog/frame hot paths.
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat appKitScale = screen.backingScaleFactor;
        if (isfinite(appKitScale) && appKitScale >= 0.5 &&
            appKitScale <= 8.0) {
            AppKitMainDisplayBackingScale = appKitScale;
            DisplayLog(@"runtime-confirmed AppKit display backing-scale=%.3f frame=%@",
                       appKitScale, NSStringFromRect(screen.frame));
        }
        DisplayQueue = dispatch_queue_create("com.macwsguide.display.queue",
                                             DISPATCH_QUEUE_SERIAL);
        MenuQueue = dispatch_queue_create("com.macwsguide.display.menu",
                                          DISPATCH_QUEUE_CONCURRENT);
        WorkspaceGeometryQueue = dispatch_queue_create(
            "com.macwsguide.display.workspace-geometry",
            DISPATCH_QUEUE_SERIAL);
        Clients = [NSMutableSet set];
        Leases = [NSMutableDictionary dictionary];
        RetiredTransientLayers = [NSMutableArray array];
        RetiredTransientStopBlocks = [NSMutableArray array];
        GeometryTargets = [NSMutableDictionary dictionary];
        StartInvalidationListener();
        xpc_connection_t listener = xpc_connection_create_mach_service(
            MACWS_STREAM_SERVICE, DisplayQueue,
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) {
            DisplayLog(@"listener-create failed service=%s",
                       MACWS_STREAM_SERVICE);
            return 1;
        }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                AcceptConnection((xpc_connection_t)event);
        });
        xpc_connection_resume(listener);
        MacWSStartFinalCompositeReceiver(
            DisplayQueue,
            ^(IOSurfaceRef surface, MacWSFinalCompositeRecord record) {
                DeliverFinalComposite(surface, record);
            },
            ^(NSString *message) {
                DisplayLog(@"%@", message);
            });
        DisplayLog(@"READY service=%s protocol=%u", MACWS_STREAM_SERVICE,
                   MACWS_STREAM_VERSION);
        dispatch_main();
    }
}
