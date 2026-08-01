#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <xpc/xpc.h>

#include "macws_menu_protocol.h"
#include "macws_stream_protocol.h"

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
static NSMutableSet *Clients;
static NSMutableDictionary<NSNumber *, id> *Leases;
static uint64_t NextStreamID = 1;
static uint64_t NextLeaseToken = 1;
static int InvalidationSocket = -1;
static dispatch_source_t InvalidationSource;
static BOOL TransientReconcilePending;
static BOOL CatalogBroadcastPending;
static _Atomic uint64_t GeometryRestartSerial;
static NSMutableDictionary<NSNumber *, NSValue *> *GeometryTargets;
static CGFloat ObservedWindowBackingScale;
static void ScheduleTransientReconcile(uint64_t delayNanoseconds);
static void ScheduleGeometryStreamRestart(void);
static void ScheduleCatalogBroadcast(void);

static void DisplayLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
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
@end

@implementation MacWSDisplayLease
- (void)dealloc { if (_surface) CFRelease(_surface); }
@end

@class MacWSDisplayClient;

@interface MacWSTransientLayer : NSObject
@property(nonatomic, weak) MacWSDisplayClient *client;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) int32_t level;
@property(nonatomic) CGRect destinationBounds;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) uint64_t firstDisplayTime;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) NSUInteger missCount;
@property(nonatomic) CGDisplayStreamRef stream;
- (void)stopStream;
@end

@implementation MacWSTransientLayer
- (void)dealloc { [self stopStream]; }
- (void)stopStream {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    _sequence = 0;
}
@end

@interface MacWSDisplayClient : NSObject
@property(nonatomic) xpc_connection_t connection;
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
@property(nonatomic) NSMutableDictionary<NSNumber *, MacWSTransientLayer *> *transientLayers;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *outstandingByLayer;
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
            (MacWSStreamWindowVisible | MacWSStreamWindowResizable |
             MacWSStreamWindowFocused);
    }
    if ([info[(id)kCGWindowIsOnscreen] boolValue])
        descriptor.flags |= MacWSStreamWindowOnScreen;
    return descriptor;
}

static void SendWindowList(MacWSDisplayClient *client) {
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
        if ((metrics.flags & MacWSStreamWindowVisible) == 0) continue;
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
            } else {
                for (ssize_t index = 0; index < count; index++) {
                    if (bytes[index] == 'g') geometryChanged = YES;
                }
            }
        }
        ScheduleCatalogBroadcast();
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
        (__bridge id)kCGDisplayStreamMinimumFrameTime: @(1.0 / 60.0),
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

    MacWSDisplayLease *lease = [MacWSDisplayLease new];
    lease.token = NextLeaseToken++;
    if (lease.token == 0) lease.token = NextLeaseToken++;
    lease.surface = (IOSurfaceRef)CFRetain(surface);
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
                 (layer ? MacWSStreamFrameOverlay : 0),
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
                   "surface=%ux%u bpr=%u pf=%08x destination=(%d,%d %ux%u)",
            (unsigned long long)producerStreamID, client.windowID,
            layerWindowID, layer ? "YES" : "NO",
            descriptor.width, descriptor.height, descriptor.bytesPerRow,
            descriptor.pixelFormat, descriptor.destinationX,
            descriptor.destinationY, descriptor.destinationWidth,
            descriptor.destinationHeight);
    }
    uint64_t firstDisplayTime = layer ? layer.firstDisplayTime
                                      : client.firstDisplayTime;
    if ((descriptor.sequence % 120) == 0 &&
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
    size_t width = CGDisplayPixelsWide(display);
    size_t height = CGDisplayPixelsHigh(display);
    if (width == 0 || height == 0 || width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION || width > SIZE_MAX / 4)
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
    client.windowBackingScale = MainDisplayBackingScale();
    return surface;
}

static void SendLayerRemoved(MacWSDisplayClient *client,
                             uint32_t layerWindowID) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_LAYER_REMOVED);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_WINDOW_ID,
                              client.windowID);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_LAYER_WINDOW_ID,
                              layerWindowID);
    xpc_connection_send_message(client.connection, event);
}

static void StartTransientLayer(MacWSTransientLayer *layer) {
    MacWSDisplayClient *client = layer.client;
    if (!client || layer.windowID == 0) return;
    [layer stopStream];
    layer.streamID = NextStreamID++;
    if (layer.streamID == 0) layer.streamID = NextStreamID++;
    layer.droppedFrames = 0;
    layer.firstDisplayTime = 0;
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
            if (status == kCGDisplayStreamFrameStatusFrameComplete)
                PublishFrame(strongClient, strongLayer, displayTime,
                             frameSurface);
        };
    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow) return;
    layer.stream = createWindow(layer.windowID, false,
        (__bridge CFDictionaryRef)StreamProperties(), DisplayQueue, handler);
    if (!layer.stream) return;
    CGError error = CGDisplayStreamStart(layer.stream);
    if (error != kCGErrorSuccess) {
        [layer stopStream];
        DisplayLog(@"layer-start failed base=%u layer=%u error=%d",
                   client.windowID, layer.windowID, error);
        return;
    }
    DisplayLog(@"layer-start stream=%llu base=%u layer=%u level=%d "
               "destination=(%.0f,%.0f %.0fx%.0f)",
        (unsigned long long)layer.streamID, client.windowID, layer.windowID,
        layer.level, layer.destinationBounds.origin.x,
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
        PublishFrame(client, nil, mach_absolute_time(),
                     client.workspaceCanvas);
        DisplayLog(@"workspace-start id=%llu display=%zux%zu scale=%.3f transport=window-iosurface-composite",
                   (unsigned long long)client.streamID,
                   IOSurfaceGetWidth(client.workspaceCanvas),
                   IOSurfaceGetHeight(client.workspaceCanvas),
                   client.windowBackingScale);
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
            DisplayLog(@"geometry-stream-restart window=%u old-stream=%llu current=%zux%zu expected=%ux%u",
                       client.windowID,
                       (unsigned long long)client.streamID,
                       client.lastSurfaceWidth, client.lastSurfaceHeight,
                       expectedWidth, expectedHeight);
            client.windowBackingScale = 0.0;
            [client stopTransientLayers];
            StartClientStream(client);
        }
        ScheduleTransientReconcile(0);
    });
}

static void StartSubscription(MacWSDisplayClient *client,
                              MacWSStreamMode mode, uint32_t windowID) {
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
    NSArray<NSDictionary *> *windowInfo = CopyOnScreenWindowInfo();
    NSArray<NSDictionary *> *desktopInfo = nil;
    BOOL needsFollowup = NO;
    BOOL workspaceNeedsFollowup = NO;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (client.mode == MacWSStreamModeFullscreen) {
            if (!desktopInfo) desktopInfo = CopyCompleteDesktopWindowInfo();
            CGRect desktopBounds = CGDisplayBounds(CGMainDisplayID());
            CGFloat scale = client.windowBackingScale > 0.0
                ? client.windowBackingScale : MainDisplayBackingScale();
            if (CGRectIsEmpty(desktopBounds) || !isfinite(scale) ||
                scale < 0.5 || scale > 8.0) continue;
            if (!client.transientLayers)
                client.transientLayers = [NSMutableDictionary dictionary];
            NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
            NSUInteger attached = 0;
            NSUInteger count = desktopInfo.count;
            for (NSUInteger index = 0; index < count; index++) {
                NSDictionary *info = desktopInfo[index];
                uint32_t candidateWindowID =
                    [info[(id)kCGWindowNumber] unsignedIntValue];
                if (attached >= 48 || candidateWindowID == 0 ||
                    [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
                CGRect candidateBounds = CGRectZero;
                if (!CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                        &candidateBounds) || CGRectIsEmpty(candidateBounds) ||
                    !CGRectIntersectsRect(desktopBounds, candidateBounds))
                    continue;
                NSNumber *key = @(candidateWindowID);
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
                // CGWindowList is front-to-back. Host draws ascending levels,
                // so reverse that rank and preserve the actual desktop z-order
                // even when several ordinary windows all report layer zero.
                layer.level = (int32_t)MIN((NSUInteger)INT32_MAX,
                                           count - index);
                layer.destinationBounds = CGRectMake(
                    (candidateBounds.origin.x - desktopBounds.origin.x) * scale,
                    (candidateBounds.origin.y - desktopBounds.origin.y) * scale,
                    candidateBounds.size.width * scale,
                    candidateBounds.size.height * scale);
                layer.missCount = 0;
                if (isNew || !layer.stream) StartTransientLayer(layer);
            }
            for (NSNumber *key in [client.transientLayers.allKeys copy]) {
                MacWSTransientLayer *layer = client.transientLayers[key];
                if ([seen containsObject:key]) continue;
                layer.missCount++;
                if (layer.missCount < 2) continue;
                DisplayLog(@"workspace-layer-remove layer=%u",
                           layer.windowID);
                SendLayerRemoved(client, layer.windowID);
                [layer stopStream];
                [client.transientLayers removeObjectForKey:key];
            }
            workspaceNeedsFollowup |= client.transientLayers.count != 0;
            continue;
        }
        if (client.mode != MacWSStreamModeWindow || client.windowID == 0)
            continue;
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
            if (attached >= 8 || candidateWindowID == 0 ||
                candidateWindowID == client.windowID || level == 0 ||
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
            layer.level = (int32_t)MAX(INT32_MIN,
                MIN((NSInteger)INT32_MAX, level));
            layer.destinationBounds = destination;
            layer.missCount = 0;
            if (isNew || !layer.stream) StartTransientLayer(layer);
        }

        for (NSNumber *key in [client.transientLayers.allKeys copy]) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            if ([seen containsObject:key]) continue;
            // A transient can briefly disappear from the on-screen catalog
            // while AppKit swaps its selection/shadow surface. Three misses
            // bound detach latency to 300 ms without a one-sample flicker.
            layer.missCount++;
            if (layer.missCount < 3) continue;
            DisplayLog(@"layer-remove base=%u layer=%u",
                       client.windowID, layer.windowID);
            SendLayerRemoved(client, layer.windowID);
            [layer stopStream];
            [client.transientLayers removeObjectForKey:key];
        }
        if (client.transientLayers.count) needsFollowup = YES;
    }
    if (needsFollowup || workspaceNeedsFollowup)
        ScheduleTransientReconcile((workspaceNeedsFollowup ? 250 : 100) *
                                   NSEC_PER_MSEC);
}

static void ScheduleTransientReconcile(uint64_t delayNanoseconds) {
    if (TransientReconcilePending) return;
    TransientReconcilePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
                   DisplayQueue, ^{ ReconcileTransientStreams(); });
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

static void RemoveClient(MacWSDisplayClient *client) {
    [client stopTransientLayers];
    [client stopStream];
    NSArray<NSNumber *> *tokens = [Leases.allKeys copy];
    for (NSNumber *token in tokens) {
        MacWSDisplayLease *lease = Leases[token];
        if (lease.owner == client) [Leases removeObjectForKey:token];
    }
    [Clients removeObject:client];
}

static void HandleRequest(MacWSDisplayClient *client, xpc_object_t request) {
    if (request == XPC_ERROR_CONNECTION_INVALID ||
        request == XPC_ERROR_CONNECTION_INTERRUPTED) {
        RemoveClient(client);
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
        StartSubscription(client, mode, (uint32_t)windowID);
    } else if (strcmp(operation, MACWS_STREAM_OP_UNSUBSCRIBE) == 0) {
        [client stopTransientLayers];
        [client stopStream];
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
        DisplayQueue = dispatch_queue_create("com.macwsguide.display.queue",
                                             DISPATCH_QUEUE_SERIAL);
        MenuQueue = dispatch_queue_create("com.macwsguide.display.menu",
                                          DISPATCH_QUEUE_CONCURRENT);
        Clients = [NSMutableSet set];
        Leases = [NSMutableDictionary dictionary];
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
        DisplayLog(@"READY service=%s protocol=%u", MACWS_STREAM_SERVICE,
                   MACWS_STREAM_VERSION);
        dispatch_main();
    }
}
