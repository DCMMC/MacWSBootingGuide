// Per-application input endpoint for the native iPadOS host.
//
// macwsinputd cannot use CGEventPost across the chroot boundary: the actual
// runtime CGPreflightPostEventAccess result is NO, and CGWindowListCopyWindowInfo
// returns NULL for its launchd session.  Every supported AppKit application
// already loads libmachook, so receive the versioned record inside its target
// process and enqueue an ordinary NSEvent on that process's main thread.

@import Foundation;
@import Darwin;

#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>

#import "macws_host_protocol.h"

typedef id (*MacWSMsgID)(id, SEL);
typedef CGRect (*MacWSMsgRect)(id, SEL);
typedef CGPoint (*MacWSMsgPointPoint)(id, SEL, CGPoint);
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
typedef BOOL (*MacWSMsgBool)(id, SEL);
typedef id (*MacWSMouseEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                     NSTimeInterval, NSInteger, id, NSInteger,
                                     NSInteger, float);
typedef void (*MacWSPostEvent)(id, SEL, id, BOOL);

static int MacWSAppInputSocket = -1;
static char MacWSAppInputPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
static NSInteger MacWSAppInputEventNumber;

static BOOL MacWSAppInputSupportedProcess(void) {
    const char *program = getprogname();
    return program &&
        (strcmp(program, "GlassDemo") == 0 ||
         strcmp(program, "Terminal") == 0 ||
         strcmp(program, "Activity Monitor") == 0 ||
         strcmp(program, "Finder") == 0);
}

static BOOL MacWSPointInRect(CGPoint point, CGRect rect) {
    return point.x >= rect.origin.x && point.y >= rect.origin.y &&
           point.x < rect.origin.x + rect.size.width &&
           point.y < rect.origin.y + rect.size.height;
}

static NSUInteger MacWSNSEventType(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown: return 1;  // NSEventTypeLeftMouseDown
        case MacWSInputKindTouchMove: return 6;  // NSEventTypeLeftMouseDragged
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel: return 2; // NSEventTypeLeftMouseUp
        case MacWSInputKindHover: return 5;       // NSEventTypeMouseMoved
    }
    return 0;
}

static BOOL MacWSInputRecordIsValid(const MacWSInputRecord *record) {
    return record->magic == MACWS_INPUT_MAGIC &&
        record->version == MACWS_INPUT_VERSION &&
        record->targetPID == getpid() &&
        record->kind >= MacWSInputKindTouchDown &&
        record->kind <= MacWSInputKindHover &&
        record->frameWidth > 0 && record->frameHeight > 0 &&
        isfinite(record->x) && isfinite(record->y) &&
        record->x >= 0.0f && record->y >= 0.0f &&
        record->x < record->frameWidth &&
        record->y < record->frameHeight;
}

static id MacWSWindowForScreenPoint(id application, CGPoint screenPoint) {
    SEL frameSelector = sel_registerName("frame");
    id keyWindow = ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("keyWindow"));
    if (keyWindow) {
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(keyWindow, frameSelector);
        if (MacWSPointInRect(screenPoint, frame)) return keyWindow;
    }

    id windows = ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("orderedWindows"));
    NSUInteger count = [windows count];
    for (NSUInteger i = 0; i < count; i++) {
        id window = [windows objectAtIndex:i];
        BOOL visible = ((MacWSMsgBool)objc_msgSend)(window,
            sel_registerName("isVisible"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(window, frameSelector);
        if (visible && MacWSPointInRect(screenPoint, frame)) return window;
    }
    return keyWindow ?: ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("mainWindow"));
}

static void MacWSPostInputOnMainThread(MacWSInputRecord record) {
    BOOL logEvent = record.kind != MacWSInputKindTouchMove &&
                    record.kind != MacWSInputKindHover;
    if (logEvent) {
        fprintf(stderr,
                "#### APP-INPUT MAIN pid=%d kind=%u target=%d thread-main=%s\n",
                getpid(), record.kind, record.targetPID,
                pthread_main_np() ? "YES" : "NO");
        fflush(stderr);
    }
    Class applicationClass = objc_getClass("NSApplication");
    Class screenClass = objc_getClass("NSScreen");
    Class eventClass = objc_getClass("NSEvent");
    if (!applicationClass || !screenClass || !eventClass) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=AppKit-classes-unavailable\n",
                getpid());
        return;
    }
    id application = ((MacWSMsgID)objc_msgSend)((id)applicationClass,
        sel_registerName("sharedApplication"));
    id screen = ((MacWSMsgID)objc_msgSend)((id)screenClass,
        sel_registerName("mainScreen"));
    if (!application || !screen || record.frameWidth == 0 ||
        record.frameHeight == 0) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-application-or-screen\n",
                getpid());
        return;
    }

    CGRect screenFrame = ((MacWSMsgRect)objc_msgSend)(screen,
        sel_registerName("frame"));
    CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
    CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
    CGPoint screenPoint = {
        screenFrame.origin.x + normalizedX * screenFrame.size.width,
        screenFrame.origin.y + (1.0 - normalizedY) * screenFrame.size.height,
    };
    id window = MacWSWindowForScreenPoint(application, screenPoint);
    if (!window) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-window screen=(%.2f,%.2f)\n",
                getpid(), screenPoint.x, screenPoint.y);
        return;
    }
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(window,
        sel_registerName("windowNumber"));
    CGPoint windowPoint = ((MacWSMsgPointPoint)objc_msgSend)(window,
        sel_registerName("convertPointFromScreen:"), screenPoint);
    NSUInteger eventType = MacWSNSEventType((MacWSInputKind)record.kind);
    float pressure = record.kind == MacWSInputKindTouchDown ||
                     record.kind == MacWSInputKindTouchMove
        ? (record.pressure > 0.0f ? record.pressure : 1.0f) : 0.0f;
    id event = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
        sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        eventType, windowPoint, 0, record.timestamp, windowNumber, nil,
        ++MacWSAppInputEventNumber, 1, pressure);
    if (!event) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=event-create window=%ld\n",
                getpid(), (long)windowNumber);
        return;
    }
    ((MacWSPostEvent)objc_msgSend)(application,
        sel_registerName("postEvent:atStart:"), event, NO);
    if (logEvent) {
        fprintf(stderr,
                "#### APP-INPUT POST pid=%d kind=%u window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                getpid(), record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
        fflush(stderr);
    }
}

static void *MacWSAppInputThread(void *unused) {
    (void)unused;
    fprintf(stderr, "#### APP-INPUT THREAD pid=%d socket=%d\n",
            getpid(), MacWSAppInputSocket);
    fflush(stderr);
    while (MacWSAppInputSocket >= 0) {
        MacWSInputRecord record = {0};
        ssize_t count = recv(MacWSAppInputSocket, &record, sizeof(record), 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (record.kind != MacWSInputKindTouchMove &&
            record.kind != MacWSInputKindHover) {
            fprintf(stderr,
                    "#### APP-INPUT RX pid=%d bytes=%zd kind=%u target=%d\n",
                    getpid(), count, record.kind, record.targetPID);
            fflush(stderr);
        }
        if (count != sizeof(record) || !MacWSInputRecordIsValid(&record)) {
            fprintf(stderr,
                    "#### APP-INPUT REJECT pid=%d bytes=%zd magic=%#x version=%u target=%d\n",
                    getpid(), count, record.magic, record.version,
                    record.targetPID);
            fflush(stderr);
            continue;
        }
        // AppKit can spend long periods in nested modal/event-tracking loops
        // (GlassDemo's diagnostic context menu does exactly that).  Such a
        // loop does not necessarily drain libdispatch's main queue.  Schedule
        // against the main CFRunLoop common modes so input is serviced both by
        // the ordinary application loop and nested AppKit tracking loops.
        CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
            @autoreleasepool {
                MacWSPostInputOnMainThread(record);
            }
        });
        CFRunLoopWakeUp(mainRunLoop);
    }
    return NULL;
}

__attribute__((constructor)) static void MacWSInstallAppInputBridge(void) {
    if (!MacWSAppInputSupportedProcess()) return;
    snprintf(MacWSAppInputPath, sizeof(MacWSAppInputPath),
             "/private/tmp/macws_app_input.%d.sock", getpid());
    MacWSAppInputSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (MacWSAppInputSocket < 0) return;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MacWSAppInputPath, sizeof(address.sun_path));
    unlink(MacWSAppInputPath);
    if (bind(MacWSAppInputSocket, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        close(MacWSAppInputSocket);
        MacWSAppInputSocket = -1;
        return;
    }
    chmod(MacWSAppInputPath, 0600);
    pthread_t thread;
    if (pthread_create(&thread, NULL, MacWSAppInputThread, NULL) == 0) {
        pthread_detach(thread);
        fprintf(stderr, "#### APP-INPUT READY pid=%d socket=%s abi=%u record=%zu\n",
                getpid(), MacWSAppInputPath, MACWS_INPUT_VERSION,
                sizeof(MacWSInputRecord));
        fflush(stderr);
    }
}

__attribute__((destructor)) static void MacWSRemoveAppInputBridge(void) {
    if (MacWSAppInputSocket >= 0) close(MacWSAppInputSocket);
    if (MacWSAppInputPath[0]) unlink(MacWSAppInputPath);
}
