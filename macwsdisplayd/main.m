#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/socket.h>
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
@end

@implementation MacWSDisplayLease
- (void)dealloc { if (_surface) CFRelease(_surface); }
@end

@interface MacWSDisplayClient : NSObject
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic) MacWSStreamMode mode;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CGDisplayStreamRef stream;
@property(nonatomic) NSUInteger outstandingFrames;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) uint64_t firstDisplayTime;
- (void)stopStream;
@end

@implementation MacWSDisplayClient
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

static NSArray<NSDictionary *> *CopyWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static CGFloat MainDisplayBackingScale(void) {
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    size_t pixelWidth = CGDisplayPixelsWide(display);
    if (bounds.size.width <= 0 || pixelWidth == 0) return 1.0;
    CGFloat scale = pixelWidth / bounds.size.width;
    return scale > 0 && scale <= 8.0 ? scale : 1.0;
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
        .flags = MacWSStreamWindowVisible | MacWSStreamWindowOnScreen |
                 MacWSStreamWindowResizable,
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
        descriptor.flags &= ~MacWSStreamWindowResizable;
        descriptor.flags |= metrics->flags & MacWSStreamWindowResizable;
    }
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
    for (NSDictionary *info in CopyWindowInfo()) {
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
        CGFloat alpha = [info[(id)kCGWindowAlpha] doubleValue];
        if (!metricsValue || layer != 0 || alpha <= 0.01) continue;
        [metricsValue getValue:&metrics];
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

static void PublishFrame(MacWSDisplayClient *client, uint64_t displayTime,
                         IOSurfaceRef surface) {
    if (!surface || ![Clients containsObject:client]) return;
    // With a stream queue depth of three, retaining more than three surfaces
    // can pin every compositor buffer. Drop instead of blocking SkyLight or
    // allocating an unbounded compatibility pool.
    if (client.outstandingFrames >= 3) {
        client.droppedFrames++;
        if (client.droppedFrames == 1 ||
            (client.droppedFrames % 120) == 0) {
            DisplayLog(@"backpressure stream=%llu window=%u outstanding=%lu "
                       "dropped=%llu",
                (unsigned long long)client.streamID, client.windowID,
                (unsigned long)client.outstandingFrames,
                (unsigned long long)client.droppedFrames);
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

    MacWSDisplayLease *lease = [MacWSDisplayLease new];
    lease.token = NextLeaseToken++;
    if (lease.token == 0) lease.token = NextLeaseToken++;
    lease.surface = (IOSurfaceRef)CFRetain(surface);
    lease.owner = client;
    Leases[@(lease.token)] = lease;
    client.outstandingFrames++;

    CGFloat scale = MainDisplayBackingScale();
    MacWSStreamFrameDescriptor descriptor = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamFrameDescriptor),
        .streamID = client.streamID,
        .windowID = client.windowID,
        .flags = MacWSStreamFrameComplete,
        .leaseToken = lease.token,
        .sequence = ++client.sequence,
        .displayTime = displayTime,
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .bytesPerRow = (uint32_t)bytesPerRow,
        .pixelFormat = IOSurfaceGetPixelFormat(surface),
        .backingScale = scale,
    };
    if (descriptor.sequence == 1) client.firstDisplayTime = displayTime;
    if ((descriptor.sequence % 120) == 0 &&
        displayTime >= client.firstDisplayTime) {
        static mach_timebase_info_data_t timebase;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
        double elapsed = timebase.denom
            ? (double)(displayTime - client.firstDisplayTime) *
                timebase.numer / timebase.denom / 1.0e9
            : 0.0;
        DisplayLog(@"throughput stream=%llu window=%u frames=%llu "
                   "elapsed=%.3f fps=%.2f outstanding=%lu dropped=%llu",
            (unsigned long long)client.streamID, client.windowID,
            (unsigned long long)descriptor.sequence, elapsed,
            elapsed > 0.0 ? (descriptor.sequence - 1) / elapsed : 0.0,
            (unsigned long)client.outstandingFrames,
            (unsigned long long)client.droppedFrames);
    }
    if (descriptor.pixelFormat == 0) descriptor.pixelFormat = 0x42475241u;

    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(port)) {
        [Leases removeObjectForKey:@(lease.token)];
        client.outstandingFrames--;
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
    CGDisplayStreamFrameAvailableHandler handler =
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
            (void)updateRef;
            MacWSDisplayClient *strongClient = weakClient;
            if (!strongClient) return;
            if (status == kCGDisplayStreamFrameStatusFrameComplete) {
                PublishFrame(strongClient, displayTime, frameSurface);
            } else if (status == kCGDisplayStreamFrameStatusStopped) {
                SendStatus(strongClient, MACWS_STREAM_EVENT_STOPPED,
                           @"DisplayStream stopped", YES);
            }
        };
    if (client.mode == MacWSStreamModeFullscreen) {
        CGDirectDisplayID display = CGMainDisplayID();
        size_t width = CGDisplayPixelsWide(display);
        size_t height = CGDisplayPixelsHigh(display);
        return CGDisplayStreamCreateWithDispatchQueue(
            display, width, height, 0x42475241u,
            (__bridge CFDictionaryRef)properties, DisplayQueue, handler);
    }

    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow || client.windowID == 0) return NULL;
    return createWindow(client.windowID, false,
                        (__bridge CFDictionaryRef)properties,
                        DisplayQueue, handler);
}

static void StartSubscription(MacWSDisplayClient *client,
                              MacWSStreamMode mode, uint32_t windowID) {
    [client stopStream];
    client.mode = mode;
    client.windowID = mode == MacWSStreamModeWindow ? windowID : 0;
    client.streamID = NextStreamID++;
    if (client.streamID == 0) client.streamID = NextStreamID++;
    client.droppedFrames = 0;
    client.firstDisplayTime = 0;
    client.stream = CreateStream(client);
    if (!client.stream) {
        SendStatus(client, MACWS_STREAM_EVENT_ERROR,
            mode == MacWSStreamModeWindow
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
    DisplayLog(@"stream-start id=%llu mode=%u window=%u",
        (unsigned long long)client.streamID, mode, client.windowID);
}

static void ReleaseLease(uint64_t token, MacWSDisplayClient *client) {
    MacWSDisplayLease *lease = Leases[@(token)];
    if (!lease || lease.owner != client) return;
    if (client.outstandingFrames) client.outstandingFrames--;
    [Leases removeObjectForKey:@(token)];
}

static void RemoveClient(MacWSDisplayClient *client) {
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
