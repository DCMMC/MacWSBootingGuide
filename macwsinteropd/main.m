#import <AppKit/AppKit.h>
#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <math.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "macws_interop_protocol.h"

static dispatch_queue_t InteropQueue;
static NSMutableSet *Clients;
static NSInteger LastPasteboardChange = -1;
static NSInteger AppliedPasteboardChange = -1;
static uint64_t DaemonOriginID;
static uint64_t Generation;
static uint64_t LastIncomingOrigin;
static uint64_t LastIncomingGeneration;
static NSXPCConnection *LocationSimulationConnection;
static id LocationSimulationProxy;
static BOOL LocationSimulationStarted;
static uint64_t LocationFixCount;
static CLLocation *LastNativeLocation;
static NSXPCConnection *LocationControlConnection;
static id LocationControlProxy;
static BOOL LocationControlReady;
static BOOL LocationControlInFlight;
static BOOL LocationRetryScheduled;
static CLLocationManager *LocationKeepaliveManager;
static id LocationKeepaliveDelegate;

static void InteropLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void PublishLocationProviderReadiness(void) {
    static _Atomic bool published = false;
    if (atomic_load_explicit(&published, memory_order_acquire)) return;
    // This is an end-to-end readiness witness, not a requested-state flag. It
    // is published only after the unmodified Ventura CLLocationManager
    // receives a location from Ventura locationd.
    const char *path = "/private/tmp/macws_location_provider_ready";
    int descriptor = open(path,
                          O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                          0644);
    if (descriptor < 0) {
        InteropLog(@"could not publish location provider readiness: %s",
                   strerror(errno));
        return;
    }
    char payload[32];
    int length = snprintf(payload, sizeof(payload), "%d\n", getpid());
    ssize_t written = length > 0
        ? write(descriptor, payload, (size_t)length) : -1;
    int savedError = written < 0 ? errno : EIO;
    close(descriptor);
    if (length <= 0 || written != length) {
        unlink(path);
        InteropLog(@"could not complete location provider readiness: %s",
                   strerror(savedError));
        return;
    }
    atomic_store_explicit(&published, true, memory_order_release);
    InteropLog(@"Ventura location provider readiness published");
}

@interface MacWSLocationKeepaliveDelegate : NSObject <CLLocationManagerDelegate>
@end

@implementation MacWSLocationKeepaliveDelegate
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    static dispatch_once_t once;
    CLLocation *location = locations.lastObject;
    if (!location) return;
    PublishLocationProviderReadiness();
    dispatch_once(&once, ^{
        InteropLog(@"Ventura CLLocationManager output ready");
    });
}

- (void)locationManager:(CLLocationManager *)manager
        didFailWithError:(NSError *)error {
    (void)manager;
    InteropLog(@"Ventura CLLocationManager client error: %@", error);
}
@end

@protocol MacWSSimulationLocationProtocol
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
- (void)setSimulationScenario:(id)scenario;
- (void)appendSimulatedLocations:(NSArray<CLLocation *> *)locations;
- (void)clearSimulatedLocations;
- (void)setLocationDeliveryBehavior:(uint8_t)behavior;
- (void)setLocationRepeatBehavior:(uint8_t)behavior;
- (void)setIntermediateLocationDistance:(double)distance;
- (void)setLocationInterval:(double)interval;
- (void)setLocationTravellingSpeed:(double)speed;
@end

// RE-confirmed from Ventura locationd's Objective-C protocol metadata.  The
// status reply is an int, not BOOL; matching that ABI is load-bearing.
@protocol MacWSLocationInternalServiceProtocol
- (void)setLocationServicesEnabled:(BOOL)enabled
                         replyBlock:(void (^)(NSError *error))reply;
- (void)setAuthorizationStatus:(BOOL)authorized
    withCorrectiveCompensation:(int)correctiveCompensation
                    forBundleID:(NSString *)bundleID
                   orBundlePath:(NSString *)bundlePath
                     replyBlock:(void (^)(NSError *error))reply;
@end

static void SubmitVenturaLocation(CLLocation *location);
static void ScheduleLocationRetry(void);
static void EnsureVenturaLocationClient(void);

static void InteropLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MACWS-INTEROP %s\n", message.UTF8String);
    fflush(stderr);
}

static void CreateVenturaLocationClientOnMainThread(void) {
    if (LocationKeepaliveManager) return;
    LocationKeepaliveDelegate = [MacWSLocationKeepaliveDelegate new];
    // Do not create NSApplication before CLLocationManager. Runtime logs from
    // the target showed that AppKit changes CoreLocation's default effective
    // bundle to the frontmost app (Maps in the failing run). That selects
    // initWithEffectiveBundleIdentifier:bundlePath:... and CoreLocationAgent
    // receives do_Register(..., forwardVerification=0), whose Ventura
    // implementation only logs "not forwarding" and returns. Construct the
    // ordinary manager on the real main thread while this process still owns
    // its bundle identity. postinst embeds an identifier-only designated
    // requirement so the Agent can validate this live executable without
    // weakening the stock check.
    InteropLog(@"Ventura CoreLocation client identity %@ path=%@",
               NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
               NSBundle.mainBundle.bundlePath ?: @"(nil)");
    LocationKeepaliveManager = [CLLocationManager new];
    LocationKeepaliveManager.delegate = LocationKeepaliveDelegate;
    LocationKeepaliveManager.desiredAccuracy = kCLLocationAccuracyBest;
    [LocationKeepaliveManager startUpdatingLocation];
    InteropLog(@"Ventura CLLocationManager lifecycle client started");
}

static void EnsureVenturaLocationClient(void) {
    if (LocationKeepaliveManager) return;
    if (NSThread.isMainThread) {
        CreateVenturaLocationClientOnMainThread();
        return;
    }
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        CreateVenturaLocationClientOnMainThread();
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static id<MacWSSimulationLocationProtocol> LocationSimulation(void) {
    if (LocationSimulationProxy) return LocationSimulationProxy;
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:
        @protocol(MacWSSimulationLocationProtocol)];
    // Match CLLocationSimulationProtocol's server-side secure-coding
    // whitelist exactly.  Mutable containers decode as NSArray and are not a
    // separate wire type.
    NSSet *classes = [NSSet setWithObjects:NSArray.class,
        CLLocation.class, nil];
    [interface setClasses:classes
              forSelector:@selector(appendSimulatedLocations:)
            argumentIndex:0
                  ofReply:NO];
    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithMachServiceName:@"com.apple.macosbooter.locationd.simulation"
                        options:0];
    connection.remoteObjectInterface = interface;
    connection.interruptionHandler = ^{
        dispatch_async(InteropQueue, ^{
            InteropLog(@"Ventura simulation service interrupted");
            LocationSimulationConnection = nil;
            LocationSimulationProxy = nil;
            LocationSimulationStarted = NO;
            ScheduleLocationRetry();
        });
    };
    connection.invalidationHandler = ^{
        dispatch_async(InteropQueue, ^{
            InteropLog(@"Ventura simulation service invalidated");
            LocationSimulationConnection = nil;
            LocationSimulationProxy = nil;
            LocationSimulationStarted = NO;
            ScheduleLocationRetry();
        });
    };
    [connection resume];
    LocationSimulationConnection = connection;
    LocationSimulationProxy = [connection remoteObjectProxyWithErrorHandler:
        ^(NSError *error) {
            dispatch_async(InteropQueue, ^{
                InteropLog(@"Ventura simulation request failed: %@", error);
                LocationSimulationConnection = nil;
                LocationSimulationProxy = nil;
                LocationSimulationStarted = NO;
                ScheduleLocationRetry();
            });
        }];
    return LocationSimulationProxy;
}

static void ResetLocationControl(void) {
    LocationControlConnection = nil;
    LocationControlProxy = nil;
    LocationControlReady = NO;
    LocationControlInFlight = NO;
}

static void PrepareVenturaLocationControl(void) {
    if (LocationControlReady || LocationControlInFlight) return;
    LocationControlInFlight = YES;
    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithMachServiceName:
            @"com.apple.macosbooter.locationd.desktop.synchronous"
                        options:0];
    connection.remoteObjectInterface = [NSXPCInterface
        interfaceWithProtocol:@protocol(MacWSLocationInternalServiceProtocol)];
    connection.interruptionHandler = ^{
        dispatch_async(InteropQueue, ^{
            InteropLog(@"Ventura location control service interrupted");
            ResetLocationControl();
            ScheduleLocationRetry();
        });
    };
    connection.invalidationHandler = ^{
        dispatch_async(InteropQueue, ^{
            InteropLog(@"Ventura location control service invalidated");
            ResetLocationControl();
            ScheduleLocationRetry();
        });
    };
    [connection resume];
    LocationControlConnection = connection;
    LocationControlProxy = [connection remoteObjectProxyWithErrorHandler:
        ^(NSError *error) {
            dispatch_async(InteropQueue, ^{
                InteropLog(@"Ventura location control request failed: %@",
                           error);
                ResetLocationControl();
                ScheduleLocationRetry();
            });
        }];
    id<MacWSLocationInternalServiceProtocol> control = LocationControlProxy;
    [control setLocationServicesEnabled:YES replyBlock:^(NSError *error) {
        if (error) {
            dispatch_async(InteropQueue, ^{
                InteropLog(@"Ventura location enable failed: %@", error);
                ResetLocationControl();
                ScheduleLocationRetry();
            });
            return;
        }
        id<MacWSLocationInternalServiceProtocol> authorizationControl =
            LocationControlProxy;
        [authorizationControl setAuthorizationStatus:YES
            withCorrectiveCompensation:0
                            forBundleID:@"com.apple.Maps"
                           orBundlePath:nil
                             replyBlock:^(NSError *authorizationError) {
            if (authorizationError) {
                dispatch_async(InteropQueue, ^{
                    InteropLog(@"Ventura Maps authorization failed: %@",
                               authorizationError);
                    ResetLocationControl();
                    ScheduleLocationRetry();
                });
                return;
            }
            dispatch_async(InteropQueue, ^{
                LocationControlReady = YES;
                LocationControlInFlight = NO;
                InteropLog(@"Ventura location services and Maps authorization ready");
                if (LastNativeLocation)
                    SubmitVenturaLocation(LastNativeLocation);
            });
        }];
    }];
}

static double MacWSGetXPCDouble(xpc_object_t dictionary, const char *key) {
    uint64_t bits = xpc_dictionary_get_uint64(dictionary, key);
    double value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static int MacWSVenturaLocationType(CLLocation *location) {
    SEL selector = NSSelectorFromString(@"type");
    if (![location respondsToSelector:selector]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(location, selector);
}

static int MacWSVenturaReferenceFrame(CLLocation *location) {
    SEL selector = NSSelectorFromString(@"referenceFrame");
    if (![location respondsToSelector:selector]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(location, selector);
}

static CLLocation *MacWSLocationByApplyingNativeMetadata(
    CLLocation *location, int locationType, int referenceFrame,
    int rawReferenceFrame) {
    // RE-confirmed against Ventura 13.4 CoreLocation on the target:
    //   -[CLLocation clientLocation] returns a 176-byte CLClientLocation.
    //   -[CLLocation type] loads self->_internal + 0x68.
    //   -clientLocation copies that field to result + 0x60.
    //   -[CLLocation referenceFrame] reads self->_internal + 0x8c.
    //   -clientLocation copies that field to result + 0x84 and the adjacent
    //    rawReferenceFrame to result + 0x88.
    //   -initWithClientLocation: consumes the same 176-byte ABI.
    // Runtime-confirmed before this adaptation: Ventura locationd accepted
    // every bridged fix but logged "location dropped due to referenceFrame"
    // with the value Unknown. Preserve the native provider metadata at this
    // ABI boundary instead of inventing a location result downstream.
    // Fail closed if a different CoreLocation build does not match all of
    // those structural witnesses.
    enum {
        kClientLocationSize = 176,
        kClientLocationTypeOffset = 0x60,
        kClientLocationReferenceFrameOffset = 0x84,
        kClientLocationRawReferenceFrameOffset = 0x88,
    };
    SEL clientSelector = NSSelectorFromString(@"clientLocation");
    SEL initSelector = NSSelectorFromString(@"initWithClientLocation:");
    NSMethodSignature *clientSignature =
        [location methodSignatureForSelector:clientSelector];
    NSMethodSignature *initSignature =
        [CLLocation instanceMethodSignatureForSelector:initSelector];
    if (!clientSignature || !initSignature ||
        clientSignature.methodReturnLength != kClientLocationSize ||
        initSignature.numberOfArguments != 3) {
        InteropLog(@"Ventura CLLocation private ABI unavailable");
        return nil;
    }
    NSUInteger argumentSize = 0;
    NSUInteger argumentAlignment = 0;
    NSGetSizeAndAlignment([initSignature getArgumentTypeAtIndex:2],
                          &argumentSize, &argumentAlignment);
    if (argumentSize != kClientLocationSize || argumentAlignment != 8 ||
        kClientLocationTypeOffset + sizeof(int) > argumentSize ||
        kClientLocationReferenceFrameOffset + sizeof(int) > argumentSize ||
        kClientLocationRawReferenceFrameOffset + sizeof(int) > argumentSize) {
        InteropLog(@"Ventura CLLocation private ABI mismatch size=%lu align=%lu",
                   (unsigned long)argumentSize,
                   (unsigned long)argumentAlignment);
        return nil;
    }

    NSMutableData *clientLocation =
        [NSMutableData dataWithLength:kClientLocationSize];
    NSInvocation *getter =
        [NSInvocation invocationWithMethodSignature:clientSignature];
    getter.target = location;
    getter.selector = clientSelector;
    [getter invoke];
    [getter getReturnValue:clientLocation.mutableBytes];
    memcpy((uint8_t *)clientLocation.mutableBytes + kClientLocationTypeOffset,
           &locationType, sizeof(locationType));
    memcpy((uint8_t *)clientLocation.mutableBytes +
               kClientLocationReferenceFrameOffset,
           &referenceFrame, sizeof(referenceFrame));
    memcpy((uint8_t *)clientLocation.mutableBytes +
               kClientLocationRawReferenceFrameOffset,
           &rawReferenceFrame, sizeof(rawReferenceFrame));

    CLLocation *allocated = [CLLocation alloc];
    NSInvocation *initializer =
        [NSInvocation invocationWithMethodSignature:initSignature];
    initializer.target = allocated;
    initializer.selector = initSelector;
    [initializer setArgument:clientLocation.mutableBytes atIndex:2];
    [initializer invoke];
    __unsafe_unretained CLLocation *unretainedResult = nil;
    [initializer getReturnValue:&unretainedResult];
    CLLocation *rebuilt = unretainedResult;
    if (!rebuilt || MacWSVenturaLocationType(rebuilt) != locationType ||
        MacWSVenturaReferenceFrame(rebuilt) != referenceFrame) {
        InteropLog(@"Ventura CLLocation private metadata reconstruction failed");
        return nil;
    }
    NSMutableData *rebuiltClientLocation =
        [NSMutableData dataWithLength:kClientLocationSize];
    getter.target = rebuilt;
    [getter invoke];
    [getter getReturnValue:rebuiltClientLocation.mutableBytes];
    int rebuiltRawReferenceFrame = 0;
    memcpy(&rebuiltRawReferenceFrame,
           (const uint8_t *)rebuiltClientLocation.bytes +
               kClientLocationRawReferenceFrameOffset,
           sizeof(rebuiltRawReferenceFrame));
    if (rebuiltRawReferenceFrame != rawReferenceFrame) {
        InteropLog(@"Ventura CLLocation raw reference-frame reconstruction failed");
        return nil;
    }
    return rebuilt;
}

static void SubmitVenturaLocation(CLLocation *location) {
    LastNativeLocation = location;
    // The desktop control and simulation listeners are independent Mach
    // services.  Do not serialize simulation startup behind the control
    // service's asynchronous reply: Ventura locationd starts a hard-coded
    // three-second idle timer during startRun.  Runtime evidence on
    // 2026-08-05 showed that it accepted the enable request, but the old early
    // return prevented appendSimulatedLocations: from being sent before that
    // timer expired.
    if (!LocationControlReady && !LocationControlInFlight) {
        PrepareVenturaLocationControl();
    }
    id<MacWSSimulationLocationProtocol> simulation = LocationSimulation();
    if (!simulation) return;
    // Keep one ordinary CoreLocation client registered.  locationd's idle
    // policy intentionally counts real CLLocation clients rather than its
    // administrative simulation/control connections; this also gives us an
    // end-to-end witness that injected fixes leave the provider graph.
    EnsureVenturaLocationClient();
    if (!LocationSimulationStarted) {
        // Use Ventura's stock defaults.  Runtime evidence showed that forcing
        // delivery behavior 0 asks the daemon to synthesize an unavailable
        // CLLocation (rawLat/lon 0, timestamp -1), discarding the valid item
        // that was just appended.
        [simulation clearSimulatedLocations];
        [simulation setLocationInterval:1.0];
        [simulation appendSimulatedLocations:@[ location ]];
        [simulation startLocationSimulation];
        LocationSimulationStarted = YES;
    } else {
        [simulation appendSimulatedLocations:@[ location ]];
    }
    LocationFixCount++;
    InteropLog(@"submitted Ventura-native location #%llu accuracy=%.1fm",
               (unsigned long long)LocationFixCount,
               location.horizontalAccuracy);
}

static void ScheduleLocationRetry(void) {
    if (LocationRetryScheduled || !LastNativeLocation) return;
    LocationRetryScheduled = YES;
    // The launch contract deliberately throttles failed/idle Ventura daemon
    // relaunches to ten seconds.  Retry after that window instead of spinning.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC),
                   InteropQueue, ^{
        LocationRetryScheduled = NO;
        if (LastNativeLocation &&
            (!LocationControlReady || !LocationSimulationStarted)) {
            InteropLog(@"retrying last native location after service restart");
            SubmitVenturaLocation(LastNativeLocation);
        }
    });
}

static void ApplyNativeLocation(xpc_object_t request) {
    double latitude = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_LATITUDE);
    double longitude = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_LONGITUDE);
    double altitude = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_ALTITUDE);
    double horizontalAccuracy = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_HORIZONTAL_ACCURACY);
    double verticalAccuracy = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_VERTICAL_ACCURACY);
    double course = MacWSGetXPCDouble(request, MACWS_INTEROP_KEY_COURSE);
    double speed = MacWSGetXPCDouble(request, MACWS_INTEROP_KEY_SPEED);
    double timestamp = MacWSGetXPCDouble(
        request, MACWS_INTEROP_KEY_TIMESTAMP);
    int64_t locationTypeValue = xpc_dictionary_get_int64(
        request, MACWS_INTEROP_KEY_LOCATION_TYPE);
    int64_t referenceFrameValue = xpc_dictionary_get_int64(
        request, MACWS_INTEROP_KEY_REFERENCE_FRAME);
    int64_t rawReferenceFrameValue = xpc_dictionary_get_int64(
        request, MACWS_INTEROP_KEY_RAW_REFERENCE_FRAME);
    if (!isfinite(latitude) || !isfinite(longitude) ||
        !isfinite(altitude) || !isfinite(horizontalAccuracy) ||
        !isfinite(verticalAccuracy) || !isfinite(course) ||
        !isfinite(speed) || !isfinite(timestamp) ||
        latitude < -90.0 || latitude > 90.0 ||
        longitude < -180.0 || longitude > 180.0 ||
        horizontalAccuracy < 0.0 || timestamp < 978307200.0 ||
        locationTypeValue < 1 || locationTypeValue > 9 ||
        referenceFrameValue <= 0 || referenceFrameValue > INT32_MAX ||
        rawReferenceFrameValue < 0 || rawReferenceFrameValue > INT32_MAX) {
        InteropLog(@"rejected malformed native location scalar message");
        return;
    }
    CLLocation *location = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                  altitude:altitude
        horizontalAccuracy:horizontalAccuracy
          verticalAccuracy:verticalAccuracy
                    course:course
                     speed:speed
                 timestamp:[NSDate dateWithTimeIntervalSince1970:timestamp]];
    CLLocation *typedLocation = MacWSLocationByApplyingNativeMetadata(
        location, (int)locationTypeValue, (int)referenceFrameValue,
        (int)rawReferenceFrameValue);
    if (!typedLocation) return;
    SubmitVenturaLocation(typedLocation);
}

static void Digest(NSData *data, uint8_t output[16]) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    memcpy(output, digest, 16);
}

static xpc_object_t EventForData(MacWSInteropKind kind, NSData *data,
                                 NSString *type) {
    MacWSInteropItemDescriptor descriptor = {
        .magic = MACWS_INTEROP_MAGIC,
        .version = MACWS_INTEROP_VERSION,
        .size = sizeof(MacWSInteropItemDescriptor),
        .kind = kind,
        .flags = MacWSInteropInlinePayload | MacWSInteropFromMacOS,
        .generation = ++Generation,
        .originID = DaemonOriginID,
        .payloadLength = data.length,
    };
    Digest(data, descriptor.digest);
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_EVENT,
                              MACWS_INTEROP_EVENT_CLIPBOARD);
    xpc_dictionary_set_data(event, MACWS_INTEROP_KEY_DESCRIPTOR,
                            &descriptor, sizeof(descriptor));
    xpc_dictionary_set_data(event, MACWS_INTEROP_KEY_PAYLOAD,
                            data.bytes, data.length);
    xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_TYPE, type.UTF8String);
    return event;
}

static void Broadcast(xpc_object_t event) {
    for (id object in [Clients copy]) {
        xpc_connection_t connection = (xpc_connection_t)object;
        xpc_connection_send_message(connection, event);
    }
}

static void PublishPasteboardIfChanged(void) {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger change = pasteboard.changeCount;
    if (change == LastPasteboardChange) return;
    LastPasteboardChange = change;
    if (change == AppliedPasteboardChange) return;

    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count) {
        xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_EVENT,
                                  MACWS_INTEROP_EVENT_FILES_READY);
        xpc_object_t paths = xpc_array_create(NULL, 0);
        NSUInteger count = MIN(urls.count, MACWS_INTEROP_MAX_ITEMS);
        for (NSUInteger index = 0; index < count; index++) {
            NSString *path = urls[index].path;
            if (path.length && path.length <= MACWS_INTEROP_MAX_PATH_BYTES)
                xpc_array_set_string(paths, XPC_ARRAY_APPEND,
                                     path.fileSystemRepresentation);
        }
        xpc_dictionary_set_value(event, MACWS_INTEROP_KEY_ITEMS, paths);
        xpc_dictionary_set_uint64(event, "origin_id", DaemonOriginID);
        xpc_dictionary_set_uint64(event, "generation", ++Generation);
        Broadcast(event);
        return;
    }

    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (png.length && png.length <= MACWS_INTEROP_MAX_INLINE_BYTES) {
        Broadcast(EventForData(MacWSInteropKindPNG, png, @"public.png"));
        return;
    }
    NSString *string = [pasteboard stringForType:NSPasteboardTypeString];
    NSData *text = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (text.length && text.length <= MACWS_INTEROP_MAX_INLINE_BYTES)
        Broadcast(EventForData(MacWSInteropKindUTF8Text, text,
                               @"public.utf8-plain-text"));
}

static BOOL SafeImportedPath(NSString *path) {
    NSString *root = @"/Users/Shared/MacWS Imports";
    NSString *standard = path.stringByStandardizingPath;
    return [standard isEqualToString:root] ||
        [standard hasPrefix:[root stringByAppendingString:@"/"]];
}

static void ApplyInlineClipboard(xpc_object_t request) {
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(
        request, MACWS_INTEROP_KEY_DESCRIPTOR, &descriptorSize);
    if (!descriptorBytes || descriptorSize != sizeof(MacWSInteropItemDescriptor))
        return;
    MacWSInteropItemDescriptor descriptor;
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    if (!MacWSInteropItemDescriptorIsValid(&descriptor, descriptorSize) ||
        descriptor.originID == DaemonOriginID ||
        ((descriptor.flags & MacWSInteropFromIOS) == 0)) return;
    size_t payloadSize = 0;
    const void *payloadBytes = xpc_dictionary_get_data(
        request, MACWS_INTEROP_KEY_PAYLOAD, &payloadSize);
    if (!payloadBytes || payloadSize != descriptor.payloadLength ||
        payloadSize > MACWS_INTEROP_MAX_INLINE_BYTES) return;
    NSData *payload = [NSData dataWithBytes:payloadBytes length:payloadSize];
    uint8_t digest[16];
    Digest(payload, digest);
    if (memcmp(digest, descriptor.digest, sizeof(digest)) != 0) return;
    if (descriptor.originID == LastIncomingOrigin &&
        descriptor.generation <= LastIncomingGeneration) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    BOOL applied = NO;
    if (descriptor.kind == MacWSInteropKindUTF8Text) {
        NSString *text = [[NSString alloc] initWithData:payload
                                               encoding:NSUTF8StringEncoding];
        if (text) applied = [pasteboard setString:text
                                          forType:NSPasteboardTypeString];
    } else if (descriptor.kind == MacWSInteropKindPNG) {
        applied = [pasteboard setData:payload forType:NSPasteboardTypePNG];
    } else if (descriptor.kind == MacWSInteropKindJPEG) {
        applied = [pasteboard setData:payload
                              forType:@"public.jpeg"];
    }
    if (applied) {
        LastIncomingOrigin = descriptor.originID;
        LastIncomingGeneration = descriptor.generation;
        AppliedPasteboardChange = pasteboard.changeCount;
        LastPasteboardChange = AppliedPasteboardChange;
    }
}

static void ApplyImportedFiles(xpc_object_t request) {
    xpc_object_t items = xpc_dictionary_get_value(request,
                                                   MACWS_INTEROP_KEY_ITEMS);
    if (!items || xpc_get_type(items) != XPC_TYPE_ARRAY) return;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    xpc_array_apply(items, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (urls.count >= MACWS_INTEROP_MAX_ITEMS ||
            xpc_get_type(value) != XPC_TYPE_STRING) return true;
        const char *pathBytes = xpc_string_get_string_ptr(value);
        NSString *path = pathBytes ? [NSString stringWithUTF8String:pathBytes]
                                   : nil;
        BOOL isDirectory = NO;
        if (path && SafeImportedPath(path) &&
            [NSFileManager.defaultManager fileExistsAtPath:path
                                                isDirectory:&isDirectory]) {
            [urls addObject:[NSURL fileURLWithPath:path isDirectory:isDirectory]];
        }
        return true;
    });
    if (!urls.count) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if ([pasteboard writeObjects:urls]) {
        AppliedPasteboardChange = pasteboard.changeCount;
        LastPasteboardChange = AppliedPasteboardChange;
    }
}

static void HandleMessage(xpc_connection_t peer, xpc_object_t message) {
    if (message == XPC_ERROR_CONNECTION_INVALID ||
        message == XPC_ERROR_CONNECTION_INTERRUPTED) {
        [Clients removeObject:(id)peer];
        return;
    }
    if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
    const char *operation = xpc_dictionary_get_string(message,
                                                       MACWS_INTEROP_KEY_OP);
    if (!operation) return;
    if (strcmp(operation, MACWS_INTEROP_OP_HELLO) == 0) {
        xpc_object_t ready = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_EVENT,
                                  MACWS_INTEROP_EVENT_READY);
        uint64_t version = xpc_dictionary_get_uint64(
            message, MACWS_INTEROP_KEY_PROTOCOL_VERSION);
        if (version != MACWS_INTEROP_VERSION) {
            xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_EVENT,
                                      MACWS_INTEROP_EVENT_ERROR);
            xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_MESSAGE,
                                      "protocol version mismatch");
        }
        xpc_dictionary_set_uint64(ready, MACWS_INTEROP_KEY_PROTOCOL_VERSION,
                                  MACWS_INTEROP_VERSION);
        xpc_connection_send_message(peer, ready);
    } else if (strcmp(operation, MACWS_INTEROP_OP_SUBSCRIBE) == 0) {
        LastPasteboardChange = -1;
        PublishPasteboardIfChanged();
    } else if (strcmp(operation, MACWS_INTEROP_OP_PUBLISH_CLIPBOARD) == 0) {
        ApplyInlineClipboard(message);
    } else if (strcmp(operation, MACWS_INTEROP_OP_IMPORT_FILES) == 0) {
        ApplyImportedFiles(message);
    } else if (strcmp(operation, MACWS_INTEROP_OP_PUBLISH_LOCATION) == 0) {
        ApplyNativeLocation(message);
    }
}

static void AcceptConnection(xpc_connection_t peer) {
    [Clients addObject:(id)peer];
    xpc_connection_set_target_queue(peer, InteropQueue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        HandleMessage(peer, message);
    });
    xpc_connection_resume(peer);
}

int main(void) {
    @autoreleasepool {
        InteropQueue = dispatch_queue_create("com.macwsguide.interop.queue",
                                             DISPATCH_QUEUE_SERIAL);
        Clients = [NSMutableSet set];
        arc4random_buf(&DaemonOriginID, sizeof(DaemonOriginID));
        if (!DaemonOriginID) DaemonOriginID = 1;
        xpc_connection_t listener = xpc_connection_create_mach_service(
            MACWS_INTEROP_SERVICE, InteropQueue,
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) return 1;
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                AcceptConnection((xpc_connection_t)event);
        });
        xpc_connection_resume(listener);
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, InteropQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ PublishPasteboardIfChanged(); });
        dispatch_resume(timer);
        // dispatch_main() terminates the process's original main thread. That
        // is valid for a pure GCD daemon, but CoreLocation installs timers and
        // delegate delivery on the actual main run loop. Runtime evidence on
        // the target was: "Attempting to add timer to main runloop, but the
        // main thread has exited", followed by the client aborting. Keep the
        // real main thread and its CFRunLoop alive instead.
        EnsureVenturaLocationClient();
        InteropLog(@"READY service=%s protocol=%u origin=%llu",
            MACWS_INTEROP_SERVICE, MACWS_INTEROP_VERSION,
            (unsigned long long)DaemonOriginID);
        CFRunLoopRun();
    }
}
