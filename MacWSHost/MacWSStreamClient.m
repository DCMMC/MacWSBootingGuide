#import "MacWSStreamClient.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <xpc/xpc.h>

@implementation MacWSStreamWindow
- (instancetype)initWithDescriptor:(MacWSStreamWindowDescriptor)descriptor
                              title:(NSString *)title {
    self = [super init];
    if (self) {
        _descriptor = descriptor;
        _title = [title copy];
    }
    return self;
}
@end

@implementation MacWSSurfaceFrame {
    IOSurfaceRef _surface;
}

- (instancetype)initWithDescriptor:(MacWSStreamFrameDescriptor)descriptor
                            surface:(IOSurfaceRef)surface
                        receiptTime:(uint64_t)receiptTime {
    self = [super init];
    if (self) {
        _descriptor = descriptor;
        _surface = surface ? (IOSurfaceRef)CFRetain(surface) : NULL;
        _receiptTime = receiptTime;
    }
    return self;
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
}

- (IOSurfaceRef)surface { return _surface; }
@end

@interface MacWSStreamClient ()
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, readwrite) MacWSStreamMode mode;
@property(nonatomic, readwrite) uint32_t windowID;
@property(nonatomic) MacWSStreamMode subscribedMode;
@property(nonatomic) uint32_t subscribedWindowID;
@property(nonatomic) BOOL subscriptionActive;
@property(nonatomic) NSData *lastWindowCatalog;
@end

@implementation MacWSStreamClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.macwsguide.host.display-client",
                                       DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)publishStatus:(NSString *)status connected:(BOOL)connected {
    self.connected = connected;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate streamClient:self statusChanged:status connected:connected];
    });
}

- (BOOL)ensureConnection {
    if (self.connection) return YES;
    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) {
        [self publishStatus:@"DisplayStream XPC API 不可用" connected:NO];
        return NO;
    }
    xpc_connection_t connection = createMach(MACWS_STREAM_SERVICE, self.queue, 0);
    if (!connection) {
        [self publishStatus:@"DisplayStream 服务未注册" connected:NO];
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        [weakSelf handleEvent:event];
    });
    xpc_connection_resume(connection);
    self.connection = connection;

    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, MACWS_STREAM_KEY_OP,
                              MACWS_STREAM_OP_HELLO);
    xpc_dictionary_set_uint64(hello, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_connection_send_message(connection, hello);
    return YES;
}

- (void)sendSubscription {
    if (![self ensureConnection]) return;
    uint32_t desiredWindowID = self.mode == MacWSStreamModeWindow
        ? self.windowID : 0;
    if (self.subscriptionActive && self.subscribedMode == self.mode &&
        self.subscribedWindowID == desiredWindowID) return;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                              MACWS_STREAM_OP_SUBSCRIBE);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_MODE, self.mode);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_WINDOW_ID,
                              self.windowID);
    xpc_connection_send_message(self.connection, request);
    self.subscribedMode = self.mode;
    self.subscribedWindowID = desiredWindowID;
    self.subscriptionActive = YES;
}

- (void)subscribeToMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID {
    if (mode != MacWSStreamModeFullscreen && mode != MacWSStreamModeWindow)
        return;
    if (mode == MacWSStreamModeWindow && windowID == 0) return;
    dispatch_async(self.queue, ^{
        self.mode = mode;
        self.windowID = mode == MacWSStreamModeWindow ? windowID : 0;
        if (![self ensureConnection]) return;
        if (self.isConnected) [self sendSubscription];
    });
}

- (void)requestWindowList {
    dispatch_async(self.queue, ^{
        if (![self ensureConnection]) return;
        // Callers use an explicit list request as a synchronization barrier
        // after launch/reopen. The bytes may equal the last unsolicited
        // catalog, but the newly-installed pending PID transaction still
        // needs that snapshot. Keep deduplication for broadcasts and force
        // only this user/control-plane query to reach the delegate.
        self.lastWindowCatalog = nil;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_LIST_WINDOWS);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                                  MACWS_STREAM_VERSION);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)unsubscribe {
    dispatch_async(self.queue, ^{
        self.subscriptionActive = NO;
        if (!self.connection) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_UNSUBSCRIBE);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)releaseFrame:(MacWSSurfaceFrame *)frame {
    [self releaseToken:frame.descriptor.leaseToken];
}

- (void)releaseToken:(uint64_t)leaseToken {
    if (!leaseToken) return;
    dispatch_async(self.queue, ^{
        if (!self.connection) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_RELEASE_FRAME);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_LEASE_TOKEN,
                                  leaseToken);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)invalidate {
    xpc_connection_t connection = self.connection;
    self.connection = nil;
    self.connected = NO;
    self.subscriptionActive = NO;
    self.lastWindowCatalog = nil;
    if (connection) xpc_connection_cancel(connection);
}

- (void)handleEvent:(xpc_object_t)event {
    if (event == XPC_ERROR_CONNECTION_INVALID ||
        event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        xpc_connection_t connection = self.connection;
        self.connection = nil;
        self.subscriptionActive = NO;
        self.lastWindowCatalog = nil;
        if (connection) xpc_connection_cancel(connection);
        [self publishStatus:event == XPC_ERROR_CONNECTION_INTERRUPTED
            ? @"DisplayStream 连接中断，等待重新连接"
            : @"DisplayStream 服务离线"
                  connected:NO];
        return;
    }
    if (!event || xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *eventName = xpc_dictionary_get_string(
        event, MACWS_STREAM_KEY_EVENT);
    if (!eventName) return;
    if (strcmp(eventName, MACWS_STREAM_EVENT_READY) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_PROTOCOL_VERSION);
        if (version != MACWS_STREAM_VERSION) {
            [self publishStatus:@"DisplayStream 协议版本不匹配" connected:NO];
            return;
        }
        [self publishStatus:@"DisplayStream IOSurface 直传已连接" connected:YES];
        if (self.mode) [self sendSubscription];
        [self requestWindowList];
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_FRAME) == 0) {
        [self handleFrameEvent:event];
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_LAYER_REMOVED) == 0) {
        uint64_t baseWindowID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_WINDOW_ID);
        uint64_t layerWindowID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_LAYER_WINDOW_ID);
        if ((self.mode != MacWSStreamModeWindow &&
             self.mode != MacWSStreamModeFullscreen) ||
            baseWindowID != self.windowID || layerWindowID == 0 ||
            layerWindowID > UINT32_MAX || layerWindowID == baseWindowID)
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate streamClient:self
                   removedLayerWindowID:(uint32_t)layerWindowID];
        });
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_WINDOWS) == 0) {
        [self handleWindowsEvent:event];
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_STOPPED) == 0 ||
               strcmp(eventName, MACWS_STREAM_EVENT_ERROR) == 0) {
        self.subscriptionActive = NO;
        const char *message = xpc_dictionary_get_string(
            event, MACWS_STREAM_KEY_MESSAGE);
        NSString *status = message ? [NSString stringWithUTF8String:message]
                                   : @"DisplayStream 已停止";
        [self publishStatus:status connected:self.isConnected];
    }
}

- (void)handleFrameEvent:(xpc_object_t)event {
    uint64_t receiptTime = mach_absolute_time();
    uint64_t eventLease = xpc_dictionary_get_uint64(
        event, MACWS_STREAM_KEY_LEASE_TOKEN);
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(
        event, MACWS_STREAM_KEY_DESCRIPTOR, &descriptorSize);
    MacWSStreamFrameDescriptor descriptor = {0};
    if (!descriptorBytes || descriptorSize != sizeof(descriptor)) {
        [self releaseToken:eventLease];
        return;
    }
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    if (!MacWSStreamFrameDescriptorIsValid(&descriptor, descriptorSize) ||
        eventLease == 0 || descriptor.leaseToken != eventLease) {
        [self releaseToken:eventLease];
        return;
    }
    if (self.mode == MacWSStreamModeWindow &&
        descriptor.windowID != self.windowID) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }
    if (self.mode == MacWSStreamModeFullscreen && descriptor.windowID != 0) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }
    BOOL overlay = (descriptor.flags & MacWSStreamFrameOverlay) != 0;
    if ((overlay && (self.mode != MacWSStreamModeWindow &&
                     self.mode != MacWSStreamModeFullscreen)) ||
        (overlay && descriptor.layerWindowID == descriptor.windowID) ||
        (!overlay && self.mode == MacWSStreamModeWindow &&
         descriptor.layerWindowID != descriptor.windowID)) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }

    IOSurfaceRef surface = NULL;
    mach_port_t port = xpc_dictionary_copy_mach_send(
        event, MACWS_STREAM_KEY_SURFACE_PORT);
    if (MACH_PORT_VALID(port)) {
        surface = IOSurfaceLookupFromMachPort(port);
        mach_port_deallocate(mach_task_self(), port);
    }
    if (!surface) {
        uint64_t surfaceID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_SURFACE_ID);
        if (surfaceID > 0 && surfaceID <= UINT32_MAX)
            surface = IOSurfaceLookup((uint32_t)surfaceID);
    }
    if (!surface) {
        [self releaseToken:descriptor.leaseToken];
        [self publishStatus:@"收到帧但无法导入 IOSurface" connected:YES];
        return;
    }

    BOOL geometryMatches = IOSurfaceGetWidth(surface) == descriptor.width &&
        IOSurfaceGetHeight(surface) == descriptor.height &&
        IOSurfaceGetBytesPerRow(surface) == descriptor.bytesPerRow;
    uint32_t actualFormat = IOSurfaceGetPixelFormat(surface);
    if (descriptor.pixelFormat && actualFormat &&
        actualFormat != descriptor.pixelFormat) {
        geometryMatches = NO;
    }
    if (!geometryMatches) {
        CFRelease(surface);
        [self releaseToken:descriptor.leaseToken];
        [self publishStatus:@"拒绝尺寸或像素格式不匹配的 IOSurface"
                  connected:YES];
        return;
    }

    MacWSSurfaceFrame *frame = [[MacWSSurfaceFrame alloc]
        initWithDescriptor:descriptor surface:surface receiptTime:receiptTime];
    CFRelease(surface);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate streamClient:self receivedFrame:frame];
    });
}

- (void)handleWindowsEvent:(xpc_object_t)event {
    xpc_object_t array = xpc_dictionary_get_value(event,
                                                   MACWS_STREAM_KEY_WINDOWS);
    if (!array || xpc_get_type(array) != XPC_TYPE_ARRAY) return;
    NSMutableArray<MacWSStreamWindow *> *windows = [NSMutableArray array];
    NSMutableData *fingerprint = [NSMutableData data];
    xpc_array_apply(array, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (windows.count >= MACWS_STREAM_MAX_WINDOWS ||
            xpc_get_type(value) != XPC_TYPE_DATA) return true;
        size_t byteCount = xpc_data_get_length(value);
        const void *bytes = xpc_data_get_bytes_ptr(value);
        if (!MacWSStreamWindowDescriptorIsValid(bytes, byteCount)) return true;
        uint32_t stableByteCount = byteCount <= UINT32_MAX
            ? (uint32_t)byteCount : 0;
        [fingerprint appendBytes:&stableByteCount length:sizeof(stableByteCount)];
        [fingerprint appendBytes:bytes length:byteCount];
        MacWSStreamWindowDescriptor descriptor;
        memcpy(&descriptor, bytes, sizeof(descriptor));
        NSData *titleData = [NSData dataWithBytes:(const uint8_t *)bytes +
                             sizeof(descriptor) length:descriptor.titleLength];
        NSString *title = [[NSString alloc] initWithData:titleData
                                                encoding:NSUTF8StringEncoding];
        if (!title) title = @"macOS Window";
        [windows addObject:[[MacWSStreamWindow alloc]
            initWithDescriptor:descriptor title:title]];
        return true;
    });
    if ([self.lastWindowCatalog isEqualToData:fingerprint]) return;
    self.lastWindowCatalog = [fingerprint copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate streamClient:self receivedWindows:windows];
    });
}

@end
