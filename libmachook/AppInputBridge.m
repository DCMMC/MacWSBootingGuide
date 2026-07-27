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
typedef id (*MacWSMsgIDInteger)(id, SEL, NSInteger);
typedef CGRect (*MacWSMsgRect)(id, SEL);
typedef CGRect (*MacWSMsgRectRect)(id, SEL, CGRect);
typedef CGRect (*MacWSMsgRectRectID)(id, SEL, CGRect, id);
typedef CGPoint (*MacWSMsgPointPoint)(id, SEL, CGPoint);
typedef CGPoint (*MacWSMsgPointPointID)(id, SEL, CGPoint, id);
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
typedef BOOL (*MacWSMsgBool)(id, SEL);
typedef double (*MacWSMsgDouble)(id, SEL);
typedef id (*MacWSMsgIDPoint)(id, SEL, CGPoint);
typedef id (*MacWSMouseEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                     NSTimeInterval, NSInteger, id, NSInteger,
                                     NSInteger, float);
typedef void (*MacWSPostEvent)(id, SEL, id, BOOL);
typedef void (*MacWSSendEvent)(id, SEL, id);
typedef NSUInteger (*MacWSPressedMouseButtons)(id, SEL);

static int MacWSAppInputSocket = -1;
static char MacWSAppInputPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
static const char MacWSInputTargetReplyPath[] =
    "/private/tmp/macws_input_target.sock";
static NSInteger MacWSAppInputEventNumber;
static NSMutableArray *MacWSAppInputPending;
static BOOL MacWSAppInputDrainScheduled;
// Serializes the socket thread's enqueue-vs-live-post decision with the main
// thread arming a real AppKit tracking loop. Without this lock an up record can
// decide to enqueue just before live mode starts, then enter the pending array
// just after the main thread checked it and leave NSControlTrackMouse waiting.
static pthread_mutex_t MacWSAppInputRouteLock = PTHREAD_MUTEX_INITIALIZER;
// Main-thread-only. RFB tap-down is held until its matching up arrives. The
// pair can then be delivered with up already in NSApplication's queue before
// sendEvent(down) enters an NSButton/NSControl nested tracking loop.
static CFTypeRef MacWSAppInputDeferredRFBDownEvent;
// Main-thread-only. RFB can deliver motion before mouse-up over several socket
// records. Keep those ordinary NSEvents until the matching release is present,
// then put the complete sequence in NSApplication's real event queue before
// dispatching down. This prevents a control tracker from observing a transient
// empty queue and returning before a later CFRunLoop block posts mouse-up.
static NSMutableArray *MacWSAppInputDeferredRFBMoveEvents;
// Main-thread-only. True while sendEvent(mouseDown) owns an AppKit nested
// tracking loop. In addition to selecting the queue path, this supplies the
// matching global pressed-button state that a hardware CGEvent normally
// updates before AppKit receives mouseDown.
static BOOL MacWSAppInputRFBTrackingActive;
static MacWSPressedMouseButtons MacWSOriginalPressedMouseButtons;
typedef struct {
    BOOL accepting;
    uint32_t contactID;
    NSInteger windowNumber;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
} MacWSDirectTrackingContext;
static MacWSDirectTrackingContext MacWSAppInputDirectContext;

typedef struct {
    NSInteger windowNumber;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
} MacWSDirectTrackingSnapshot;
// Main-thread-only.  Retain the window selected by mouse-down until the
// matching up/cancel.  Runtime evidence showed a title-bar down can close the
// front Terminal window synchronously; re-hit-testing the up then targeted the
// newly exposed window (23 -> 6), splitting one gesture across two windows.
static CFTypeRef MacWSAppInputGestureWindow;
// Main-thread-only diagnostic witness for whether the real hit NSControl
// changed state after AppKit dispatch. It is observational: no setter/action
// is called by the bridge.
static CFTypeRef MacWSAppInputGestureHitView;
static double MacWSAppInputGestureHitValueBefore;
static BOOL MacWSAppInputGestureHitHasValue;

static void MacWSSetAppInputGestureWindow(id window) {
    CFTypeRef replacement = window
        ? CFRetain((__bridge CFTypeRef)window) : NULL;
    CFTypeRef previous = MacWSAppInputGestureWindow;
    MacWSAppInputGestureWindow = replacement;
    if (previous) CFRelease(previous);
}

static void MacWSSetAppInputGestureHitView(id view) {
    CFTypeRef replacement = view
        ? CFRetain((__bridge CFTypeRef)view) : NULL;
    CFTypeRef previous = MacWSAppInputGestureHitView;
    MacWSAppInputGestureHitView = replacement;
    MacWSAppInputGestureHitHasValue = view &&
        [view respondsToSelector:sel_registerName("doubleValue")];
    MacWSAppInputGestureHitValueBefore = MacWSAppInputGestureHitHasValue
        ? ((MacWSMsgDouble)objc_msgSend)(view, sel_registerName("doubleValue"))
        : 0.0;
    if (previous) CFRelease(previous);
}

static void MacWSLogAppInputGestureHitResult(const char *phase,
                                             uint32_t gesture) {
    id view = (__bridge id)MacWSAppInputGestureHitView;
    if (!view) return;
    BOOL enabled = ![view respondsToSelector:sel_registerName("isEnabled")] ||
        ((MacWSMsgBool)objc_msgSend)(view, sel_registerName("isEnabled"));
    double after = MacWSAppInputGestureHitHasValue
        ? ((MacWSMsgDouble)objc_msgSend)(view, sel_registerName("doubleValue"))
        : 0.0;
    fprintf(stderr,
        "#### APP-INPUT CONTROL-RESULT pid=%d gesture=%u phase=%s "
        "view=%s enabled=%s has-value=%s before=%.6f after=%.6f\n",
        getpid(), gesture, phase, object_getClassName(view),
        enabled ? "YES" : "NO",
        MacWSAppInputGestureHitHasValue ? "YES" : "NO",
        MacWSAppInputGestureHitValueBefore, after);
    fflush(stderr);
    MacWSSetAppInputGestureHitView(nil);
}

static void MacWSSetDeferredRFBDownEvent(id event) {
    CFTypeRef replacement = event
        ? CFRetain((__bridge CFTypeRef)event) : NULL;
    CFTypeRef previous = MacWSAppInputDeferredRFBDownEvent;
    MacWSAppInputDeferredRFBDownEvent = replacement;
    if (previous) CFRelease(previous);
}

static void MacWSClearDeferredRFBMoveEvents(void) {
    [MacWSAppInputDeferredRFBMoveEvents removeAllObjects];
}

static NSInteger MacWSNextAppInputEventNumber(void) {
    return __sync_add_and_fetch(&MacWSAppInputEventNumber, 1);
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSClearDirectTrackingContextLocked(void) {
    MacWSAppInputDirectContext.accepting = NO;
    if (MacWSAppInputDirectContext.application) {
        CFRelease(MacWSAppInputDirectContext.application);
        MacWSAppInputDirectContext.application = NULL;
    }
    MacWSAppInputDirectContext.contactID = 0;
    MacWSAppInputDirectContext.windowNumber = 0;
    MacWSAppInputDirectContext.screenFrame = (CGRect){0};
    MacWSAppInputDirectContext.windowMinusScreen = (CGPoint){0};
    MacWSAppInputDirectContext.eventClass = Nil;
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSArmDirectTrackingContextLocked(id application,
                                                Class eventClass,
                                                uint32_t contactID,
                                                NSInteger windowNumber,
                                                CGRect screenFrame,
                                                CGPoint screenPoint,
                                                CGPoint windowPoint) {
    MacWSClearDirectTrackingContextLocked();
    MacWSAppInputDirectContext.accepting = YES;
    MacWSAppInputDirectContext.contactID = contactID;
    MacWSAppInputDirectContext.windowNumber = windowNumber;
    MacWSAppInputDirectContext.screenFrame = screenFrame;
    MacWSAppInputDirectContext.windowMinusScreen = (CGPoint){
        windowPoint.x - screenPoint.x,
        windowPoint.y - screenPoint.y,
    };
    MacWSAppInputDirectContext.eventClass = eventClass;
    MacWSAppInputDirectContext.application = application
        ? CFRetain((__bridge CFTypeRef)application) : NULL;
}

static NSUInteger MacWSAppInputPressedMouseButtons(id self, SEL command) {
    NSUInteger buttons = MacWSOriginalPressedMouseButtons
        ? MacWSOriginalPressedMouseButtons(self, command) : 0;
    // RE-confirmed in the macOS 13.4 AppKit actually loaded on the device:
    // NSControlTrackMouse+668 calls +[NSEvent pressedMouseButtons], and
    // +672..720 immediately invokes _controlStopTracking when bit 0 is clear,
    // before it constructs _NSMouseTracker/trackEvent:usingHandler:. Our
    // per-process NSEvent transport has no CGEvent to update that global bit,
    // so reflect the left-button state only for the synchronous synthetic
    // gesture. All unrelated callers receive the real AppKit result unchanged.
    if (MacWSAppInputRFBTrackingActive) buttons |= 1u;
    return buttons;
}

static void MacWSInstallPressedMouseButtonsBridge(Class eventClass) {
    if (MacWSOriginalPressedMouseButtons) return;
    SEL selector = sel_registerName("pressedMouseButtons");
    Method method = class_getClassMethod(eventClass, selector);
    if (!method) {
        fprintf(stderr,
            "#### APP-INPUT STATE-BRIDGE unavailable: +[NSEvent pressedMouseButtons]\n");
        fflush(stderr);
        return;
    }
    IMP implementation = method_getImplementation(method);
    if (implementation == (IMP)MacWSAppInputPressedMouseButtons) return;
    MacWSOriginalPressedMouseButtons =
        (MacWSPressedMouseButtons)implementation;
    method_setImplementation(method,
        (IMP)MacWSAppInputPressedMouseButtons);
    fprintf(stderr,
        "#### APP-INPUT STATE-BRIDGE installed +[NSEvent pressedMouseButtons]\n");
    fflush(stderr);
}

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
        case MacWSInputKindTap: return 1;         // atomic left down + up
    }
    return 0;
}

static BOOL MacWSInputRecordIsValid(const MacWSInputRecord *record) {
    return record->magic == MACWS_INPUT_MAGIC &&
        record->version == MACWS_INPUT_VERSION &&
        record->targetPID == getpid() &&
        record->kind >= MacWSInputKindTouchDown &&
        record->kind <= MacWSInputKindTap &&
        record->frameWidth > 0 && record->frameHeight > 0 &&
        isfinite(record->x) && isfinite(record->y) &&
        record->x >= 0.0f && record->y >= 0.0f &&
        record->x < record->frameWidth &&
        record->y < record->frameHeight;
}

// The route lock closes the only dangerous transition: a socket record either
// enters MacWSAppInputPending before the main thread arms live tracking (and is
// visible to its fallback check), or snapshots the armed context and is posted
// directly. It cannot fall between those two states.
static BOOL MacWSPrepareDirectTrackingPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    BOOL isRFB = record.sceneID == 0x564e430000000001ull;
    BOOL isTrackingRecord = record.kind == MacWSInputKindTouchMove ||
        record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel;
    if (!isRFB || !isTrackingRecord ||
        !MacWSAppInputDirectContext.accepting ||
        MacWSAppInputDirectContext.contactID != record.contactID ||
        !MacWSAppInputDirectContext.application ||
        !MacWSAppInputDirectContext.eventClass) {
        return NO;
    }
    snapshot->windowNumber = MacWSAppInputDirectContext.windowNumber;
    snapshot->screenFrame = MacWSAppInputDirectContext.screenFrame;
    snapshot->windowMinusScreen =
        MacWSAppInputDirectContext.windowMinusScreen;
    snapshot->eventClass = MacWSAppInputDirectContext.eventClass;
    snapshot->application =
        CFRetain(MacWSAppInputDirectContext.application);
    if (record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel) {
        // The release is now owned by AppKit's event queue. Do not allow a
        // later hover or duplicate transition to enter the same tracker.
        MacWSAppInputDirectContext.accepting = NO;
    }
    return YES;
}

static void MacWSPostDirectTrackingRecord(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot snapshot) {
    @autoreleasepool {
        CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
        CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
        CGPoint screenPoint = {
            snapshot.screenFrame.origin.x +
                normalizedX * snapshot.screenFrame.size.width,
            snapshot.screenFrame.origin.y +
                (1.0 - normalizedY) * snapshot.screenFrame.size.height,
        };
        CGPoint windowPoint = {
            screenPoint.x + snapshot.windowMinusScreen.x,
            screenPoint.y + snapshot.windowMinusScreen.y,
        };
        float pressure = record.kind == MacWSInputKindTouchMove ? 1.0f : 0.0f;
        id event = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            MacWSNSEventType((MacWSInputKind)record.kind), windowPoint, 0,
            record.timestamp, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, pressure);
        if (event) {
            // Apple documents that events posted from subthreads enter the
            // main-thread event queue. Appending preserves socket arrival
            // order while NSControlTrackMouse is synchronously tracking.
            ((MacWSPostEvent)objc_msgSend)(
                (__bridge id)snapshot.application,
                sel_registerName("postEvent:atStart:"), event, NO);
            static unsigned liveMoveLogs;
            if (record.kind != MacWSInputKindTouchMove || liveMoveLogs++ < 12) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-POST pid=%d kind=%u gesture=%u "
                    "window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                    getpid(), record.kind, record.contactID,
                    (long)snapshot.windowNumber, screenPoint.x, screenPoint.y,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
            }
        } else {
            fprintf(stderr,
                "#### APP-INPUT LIVE-DROP pid=%d kind=%u gesture=%u "
                "reason=event-create\n",
                getpid(), record.kind, record.contactID);
            fflush(stderr);
        }
    }
    if (snapshot.application) CFRelease(snapshot.application);
}

// The caller holds MacWSAppInputRouteLock, so a socket record cannot pass its
// direct-post decision while this scan is in progress.
static BOOL MacWSHasPendingRFBTrackingRecordLocked(uint32_t contactID) {
    @synchronized(MacWSAppInputPending) {
        for (NSData *data in MacWSAppInputPending) {
            if ([data length] != sizeof(MacWSInputRecord)) continue;
            MacWSInputRecord pending = {0};
            [data getBytes:&pending length:sizeof(pending)];
            if (pending.sceneID == 0x564e430000000001ull &&
                pending.contactID == contactID &&
                (pending.kind == MacWSInputKindTouchMove ||
                 pending.kind == MacWSInputKindTouchUp ||
                 pending.kind == MacWSInputKindTouchCancel)) {
                return YES;
            }
        }
    }
    return NO;
}

static id MacWSWindowForScreenPoint(id application, CGPoint screenPoint) {
    SEL frameSelector = sel_registerName("frame");
    id keyWindow = ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("keyWindow"));
    // orderedWindows is front-to-back. A restored Terminal session can have
    // several overlapping windows while keyWindow still names a covered one.
    // Runtime LLDB evidence for a click on the visible front close button:
    // choosing keyWindow produced local x=116 and dispatched to
    // NSTitlebarView, whereas the visible front window starts at x~=174 and
    // the button is at local x~=29. Hit-test stacking order before using the
    // key/main window as an off-point fallback.
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
    MacWSInstallPressedMouseButtonsBridge(eventClass);
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
    id window = nil;
    if (record.kind != MacWSInputKindTouchDown &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindTap && MacWSAppInputGestureWindow) {
        window = (__bridge id)MacWSAppInputGestureWindow;
    } else {
        window = MacWSWindowForScreenPoint(application, screenPoint);
    }
    if (!window) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-window screen=(%.2f,%.2f)\n",
                getpid(), screenPoint.x, screenPoint.y);
        return;
    }
    if (record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap)
        MacWSSetAppInputGestureWindow(window);
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(window,
        sel_registerName("windowNumber"));
    CGPoint windowPoint = ((MacWSMsgPointPoint)objc_msgSend)(window,
        sel_registerName("convertPointFromScreen:"), screenPoint);
    if (record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap) {
        id contentView = ((MacWSMsgID)objc_msgSend)(window,
            sel_registerName("contentView"));
        CGPoint contentPoint = contentView
            ? ((MacWSMsgPointPointID)objc_msgSend)(contentView,
                sel_registerName("convertPoint:fromView:"), windowPoint,
                nil) : (CGPoint){0.0, 0.0};
        id hitView = contentView
            ? ((MacWSMsgIDPoint)objc_msgSend)(contentView,
                sel_registerName("hitTest:"), contentPoint) : nil;
        MacWSSetAppInputGestureHitView(hitView);
        static unsigned hitLogs;
        if (hitLogs++ < 12) {
            fprintf(stderr,
                "#### APP-INPUT HIT pid=%d gesture=%u kind=%u window=%ld "
                "screen=(%.2f,%.2f) local=(%.2f,%.2f) content=(%.2f,%.2f) "
                "view=%s\n",
                getpid(), record.contactID, record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y,
                contentPoint.x, contentPoint.y,
                hitView ? object_getClassName(hitView) : "nil");
            fflush(stderr);
        }
    }
    if (record.kind == MacWSInputKindTouchDown) {
        static unsigned geometryLogs;
        if (geometryLogs++ < 3) {
            id ordered = ((MacWSMsgID)objc_msgSend)(application,
                sel_registerName("orderedWindows"));
            NSUInteger orderedCount = [ordered count];
            for (NSUInteger index = 0; index < orderedCount && index < 12;
                 index++) {
                id candidate = [ordered objectAtIndex:index];
                CGRect candidateFrame = ((MacWSMsgRect)objc_msgSend)(candidate,
                    sel_registerName("frame"));
                NSInteger candidateNumber = ((MacWSMsgInteger)objc_msgSend)(candidate,
                    sel_registerName("windowNumber"));
                BOOL visible = ((MacWSMsgBool)objc_msgSend)(candidate,
                    sel_registerName("isVisible"));
                BOOL key = candidate == ((MacWSMsgID)objc_msgSend)(application,
                    sel_registerName("keyWindow"));
                fprintf(stderr,
                    "#### APP-INPUT WINDOW index=%lu number=%ld visible=%s "
                    "key=%s frame=(%.1f,%.1f %.1fx%.1f) selected=%s\n",
                    (unsigned long)index, (long)candidateNumber,
                    visible ? "YES" : "NO", key ? "YES" : "NO",
                    candidateFrame.origin.x, candidateFrame.origin.y,
                    candidateFrame.size.width, candidateFrame.size.height,
                    candidate == window ? "YES" : "NO");
            }
            id closeButton = ((MacWSMsgIDInteger)objc_msgSend)(window,
                sel_registerName("standardWindowButton:"), 0);
            id buttonSuperview = closeButton
                ? ((MacWSMsgID)objc_msgSend)(closeButton,
                    sel_registerName("superview")) : nil;
            if (closeButton && buttonSuperview) {
                CGRect buttonFrame = ((MacWSMsgRect)objc_msgSend)(closeButton,
                    sel_registerName("frame"));
                CGRect inWindow = ((MacWSMsgRectRectID)objc_msgSend)(buttonSuperview,
                    sel_registerName("convertRect:toView:"), buttonFrame, nil);
                CGRect inScreen = ((MacWSMsgRectRect)objc_msgSend)(window,
                    sel_registerName("convertRectToScreen:"), inWindow);
                fprintf(stderr,
                    "#### APP-INPUT CLOSE window=%ld screen=(%.1f,%.1f %.1fx%.1f)\n",
                    (long)windowNumber, inScreen.origin.x, inScreen.origin.y,
                    inScreen.size.width, inScreen.size.height);
            }
            fflush(stderr);
        }
    }
    NSUInteger eventType = MacWSNSEventType((MacWSInputKind)record.kind);
    float pressure = record.kind == MacWSInputKindTouchDown ||
                     record.kind == MacWSInputKindTap ||
                     record.kind == MacWSInputKindTouchMove
        ? (record.pressure > 0.0f ? record.pressure : 1.0f) : 0.0f;
    id event = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
        sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        eventType, windowPoint, 0, record.timestamp, windowNumber, nil,
        MacWSNextAppInputEventNumber(), 1, pressure);
    if (!event) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=event-create window=%ld\n",
                getpid(), (long)windowNumber);
        if (record.kind == MacWSInputKindTouchUp ||
            record.kind == MacWSInputKindTouchCancel) {
            MacWSSetAppInputGestureWindow(nil);
        }
        return;
    }
    BOOL isRFB = record.sceneID == 0x564e430000000001ull;
    if (isRFB && record.kind == MacWSInputKindTap) {
        // VNC holds a stationary down until release and emits this one-record
        // gesture. Construct the matching pair in the target process, queue up
        // first, then let AppKit's real NSControl tracking consume it while
        // dispatching down synchronously. There is no split transport window.
        id upEvent = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            2 /* NSEventTypeLeftMouseUp */, windowPoint, 0,
            record.timestamp + 0.001, windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, 0.0f);
        if (!upEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=tap-up-create window=%ld gesture=%u\n",
                getpid(), (long)windowNumber, record.contactID);
            MacWSSetAppInputGestureWindow(nil);
            return;
        }
        MacWSAppInputRFBTrackingActive = YES;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), upEvent, YES);
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
        MacWSAppInputRFBTrackingActive = NO;
        fprintf(stderr,
            "#### APP-INPUT TAP-COMPLETE pid=%d gesture=%u window=%ld "
            "screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
            getpid(), record.contactID, (long)windowNumber,
            screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
        fflush(stderr);
        MacWSLogAppInputGestureHitResult("tap", record.contactID);
        MacWSSetAppInputGestureWindow(nil);
        MacWSClearDeferredRFBMoveEvents();
        return;
    }
    if (isRFB && record.kind == MacWSInputKindTouchDown) {
        // Do not enter control tracking until the complete tap is available.
        // The chroot application has no ordinary login-session event pump;
        // runtime evidence showed two postEvent: calls remain unconsumed.
        MacWSClearDeferredRFBMoveEvents();
        MacWSSetDeferredRFBDownEvent(event);
        if (logEvent) {
            fprintf(stderr,
                "#### APP-INPUT DEFER pid=%d kind=%u window=%ld\n",
                getpid(), record.kind, (long)windowNumber);
            fflush(stderr);
        }
        return;
    }
    if (isRFB && MacWSAppInputRFBTrackingActive) {
        // This block is running re-entrantly inside sendEvent(mouseDown)'s
        // tracking loop. Queue the real event at the head; the tracker consumes
        // it before requesting the next one. In particular, up releases the
        // synchronous outer dispatch instead of starting another sendEvent.
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
    } else if (isRFB && record.kind == MacWSInputKindTouchMove &&
               MacWSAppInputDeferredRFBDownEvent) {
        // Start the real AppKit tracker as soon as the gesture crosses VNC's
        // drag slop. While sendEvent(mouseDown) owns the main thread, the
        // socket thread posts subsequent ordinary NSEvents directly into the
        // application queue. NSApplication explicitly supports subthread
        // postEvent:atStart: and wakes the main event queue.
        //
        // A fast gesture may already have records in MacWSAppInputPending. Do
        // not start live mode in that case: its pre-scheduled CFRunLoop block
        // is not guaranteed to execute inside every NSControl tracking loop.
        // The route lock makes this test race-free against socket enqueue.
        BOOL useBufferedFallback = NO;
        id downEvent = nil;
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSArmDirectTrackingContextLocked(application, eventClass,
            record.contactID, windowNumber, screenFrame,
            screenPoint, windowPoint);
        useBufferedFallback =
            MacWSHasPendingRFBTrackingRecordLocked(record.contactID);
        if (useBufferedFallback) {
            MacWSClearDirectTrackingContextLocked();
        } else {
            downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
            MacWSSetDeferredRFBDownEvent(nil);
            MacWSAppInputRFBTrackingActive = YES;
            // Seed the queue before dispatching down. Future socket records
            // append at the tail, preserving move...up arrival order.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, YES);
        }
        pthread_mutex_unlock(&MacWSAppInputRouteLock);

        if (useBufferedFallback) {
            // Keep only the newest position. The macOS 13.4 _NSMouseTracker
            // explicitly enables event coalescing; runtime LLDB evidence
            // showed a prefilled four-move burst invokes continueTracking:
            // once at a middle sample, while one latest move lands exactly at
            // release.
            [MacWSAppInputDeferredRFBMoveEvents removeAllObjects];
            [MacWSAppInputDeferredRFBMoveEvents addObject:event];
            fprintf(stderr,
                "#### APP-INPUT LIVE-FALLBACK pid=%d gesture=%u "
                "reason=pending-record\n",
                getpid(), record.contactID);
            fflush(stderr);
        } else {
            ((MacWSSendEvent)objc_msgSend)(application,
                sel_registerName("sendEvent:"), downEvent);
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            MacWSAppInputRFBTrackingActive = NO;
            MacWSClearDirectTrackingContextLocked();
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
            fprintf(stderr,
                "#### APP-INPUT LIVE-DISPATCH-RETURN pid=%d gesture=%u "
                "window=%ld first-move=(%.2f,%.2f)\n",
                getpid(), record.contactID, (long)windowNumber,
                screenPoint.x, screenPoint.y);
            fflush(stderr);
            MacWSLogAppInputGestureHitResult("live-drag", record.contactID);
            [downEvent release];
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
    } else if (isRFB &&
        (record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel) &&
        MacWSAppInputDeferredRFBDownEvent) {
        id downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
        MacWSSetDeferredRFBDownEvent(nil);
        NSArray *moves = [MacWSAppInputDeferredRFBMoveEvents copy];
        MacWSClearDeferredRFBMoveEvents();
        // Build the real queue head in move[0]..move[n-1],up order. Runtime
        // LLDB breakpoints on NSSliderCell showed that posting moves forward
        // and then up with atStart:YES reached startTrackingAt: and
        // stopTracking: but never continueTracking: -- every insertion is a
        // push, so up became the first matching event. Appending at the tail
        // also produced no continueTracking: call in this launchd-created
        // session. Push up first, then moves in reverse order, leaving the
        // complete gesture at the head in chronological order. No
        // target/action/value setter is used.
        MacWSAppInputRFBTrackingActive = YES;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
        for (NSUInteger index = [moves count]; index > 0; index--) {
            id moveEvent = [moves objectAtIndex:index - 1];
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), moveEvent, YES);
        }
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), downEvent);
        MacWSAppInputRFBTrackingActive = NO;
        fprintf(stderr,
            "#### APP-INPUT GESTURE-DISPATCH-RETURN pid=%d gesture=%u "
            "window=%ld moves=%lu release=(%.2f,%.2f)\n",
            getpid(), record.contactID, (long)windowNumber,
            (unsigned long)[moves count], screenPoint.x, screenPoint.y);
        fflush(stderr);
        MacWSLogAppInputGestureHitResult("drag", record.contactID);
        [moves release];
        [downEvent release];
    } else if (isRFB && record.kind == MacWSInputKindHover) {
        // The launchd-created applications do not consistently drain events
        // inserted into NSApplication's ordinary queue. Mouse-moved dispatch
        // cannot enter button tracking, so deliver it synchronously.
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
    } else {
        // Native-host gestures, hover, and RFB drags keep ordinary queue
        // semantics. Flush a deferred tap-down before the first drag record.
        if (isRFB && MacWSAppInputDeferredRFBDownEvent) {
            id downEvent = (__bridge id)MacWSAppInputDeferredRFBDownEvent;
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), downEvent, NO);
            MacWSSetDeferredRFBDownEvent(nil);
        }
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, NO);
    }
    if (logEvent) {
        fprintf(stderr,
                "#### APP-INPUT POST pid=%d kind=%u window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                getpid(), record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
        fflush(stderr);
    }
    if (record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel) {
        MacWSSetAppInputGestureWindow(nil);
        MacWSSetAppInputGestureHitView(nil);
    }
}

// CFRunLoopPerformBlock does not promise ordering between separately queued
// blocks. Runtime VNC evidence on 2026-07-26 showed the datagram thread receive
// down(1) then up(3), while AppKit executed the two blocks as up(3) then
// down(1). Keep one scheduled drain and an explicit FIFO so a gesture's event
// order is invariant even in nested AppKit tracking run loops.
static void MacWSDrainOneAppInputOnMainThread(void);

static void MacWSScheduleAppInputDrain(void) {
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        MacWSDrainOneAppInputOnMainThread();
    });
    CFRunLoopWakeUp(mainRunLoop);
}

static void MacWSDrainOneAppInputOnMainThread(void) {
    NSData *data = nil;
    BOOL scheduleNext = NO;
    @synchronized(MacWSAppInputPending) {
        if ([MacWSAppInputPending count] != 0) {
            data = [[MacWSAppInputPending objectAtIndex:0] retain];
            [MacWSAppInputPending removeObjectAtIndex:0];
            if ([MacWSAppInputPending count] != 0) {
                // Keep the scheduled token and enqueue the next block before
                // dispatching this event. sendEvent(mouseDown) can enter a
                // nested button-tracking run loop; that loop must be able to
                // execute the already-ordered mouseUp block to let the first
                // sendEvent return.
                scheduleNext = YES;
            } else {
                MacWSAppInputDrainScheduled = NO;
            }
        } else {
            MacWSAppInputDrainScheduled = NO;
        }
    }
    if (scheduleNext) MacWSScheduleAppInputDrain();
    if ([data length] == sizeof(MacWSInputRecord)) {
        MacWSInputRecord record = {0};
        [data getBytes:&record length:sizeof(record)];
        @autoreleasepool {
            MacWSPostInputOnMainThread(record);
        }
    }
    [data release];
}

static void MacWSEnqueueAppInputRecord(MacWSInputRecord record) {
    BOOL scheduleDrain = NO;
    NSData *data = [[NSData alloc] initWithBytes:&record length:sizeof(record)];
    @synchronized(MacWSAppInputPending) {
        BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                          record.kind == MacWSInputKindHover;
        BOOL replaced = NO;
        NSUInteger pendingCount = [MacWSAppInputPending count];
        if (continuous && pendingCount != 0) {
            NSData *lastData = [MacWSAppInputPending objectAtIndex:pendingCount - 1];
            if ([lastData length] == sizeof(MacWSInputRecord)) {
                MacWSInputRecord last = {0};
                [lastData getBytes:&last length:sizeof(last)];
                if (last.kind == record.kind &&
                    last.sceneID == record.sceneID &&
                    last.contactID == record.contactID &&
                    last.targetPID == record.targetPID) {
                    [MacWSAppInputPending replaceObjectAtIndex:pendingCount - 1
                                                    withObject:data];
                    replaced = YES;
                }
            }
        }
        if (!replaced) {
            // Never discard a button transition. If a stalled main thread has
            // accumulated motion, evict its oldest continuous sample first so
            // a release/tap can always enter the bounded queue.
            while ([MacWSAppInputPending count] >= 128) {
                NSUInteger removable = NSNotFound;
                for (NSUInteger index = 0;
                     index < [MacWSAppInputPending count]; index++) {
                    NSData *candidateData =
                        [MacWSAppInputPending objectAtIndex:index];
                    if ([candidateData length] != sizeof(MacWSInputRecord)) continue;
                    MacWSInputRecord candidate = {0};
                    [candidateData getBytes:&candidate length:sizeof(candidate)];
                    if (candidate.kind == MacWSInputKindTouchMove ||
                        candidate.kind == MacWSInputKindHover) {
                        removable = index;
                        break;
                    }
                }
                if (removable == NSNotFound) break;
                [MacWSAppInputPending removeObjectAtIndex:removable];
            }
            if (!continuous || [MacWSAppInputPending count] < 128)
                [MacWSAppInputPending addObject:data];
        }
        if (!MacWSAppInputDrainScheduled) {
            MacWSAppInputDrainScheduled = YES;
            scheduleDrain = YES;
        }
    }
    [data release];
    if (scheduleDrain) MacWSScheduleAppInputDrain();
}

// macwsinputd's launchd session has no CoreGraphics window list.  A target
// probe performs only a read-only AppKit hit test in each application; the
// broker sends the real input record to exactly one selected PID afterward.
// Keeping this on the main thread is required because orderedWindows and
// keyWindow are AppKit state, not socket-thread APIs.
static void MacWSReplyToTargetProbeOnMainThread(
        MacWSInputTargetProbe probe) {
    MacWSInputTargetReply reply = {
        .magic = MACWS_TARGET_REPLY_MAGIC,
        .version = MACWS_TARGET_VERSION,
        .size = sizeof(MacWSInputTargetReply),
        .nonce = probe.nonce,
        .pid = getpid(),
    };
    Class applicationClass = objc_getClass("NSApplication");
    Class screenClass = objc_getClass("NSScreen");
    id application = applicationClass
        ? ((MacWSMsgID)objc_msgSend)((id)applicationClass,
                                    sel_registerName("sharedApplication"))
        : nil;
    id screen = screenClass
        ? ((MacWSMsgID)objc_msgSend)((id)screenClass,
                                    sel_registerName("mainScreen"))
        : nil;
    id hitWindow = nil;
    CGRect hitWindowFrame = {{0.0, 0.0}, {0.0, 0.0}};
    id keyWindow = application
        ? ((MacWSMsgID)objc_msgSend)(application,
                                    sel_registerName("keyWindow"))
        : nil;
    if (application && screen && probe.frameWidth != 0 &&
        probe.frameHeight != 0) {
        CGRect screenFrame = ((MacWSMsgRect)objc_msgSend)(
            screen, sel_registerName("frame"));
        CGPoint screenPoint = {
            screenFrame.origin.x +
                (probe.x / (CGFloat)probe.frameWidth) *
                    screenFrame.size.width,
            screenFrame.origin.y +
                (1.0 - probe.y / (CGFloat)probe.frameHeight) *
                    screenFrame.size.height,
        };
        id windows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("orderedWindows"));
        NSUInteger count = [windows count];
        for (NSUInteger index = 0; index < count; index++) {
            id candidate = [windows objectAtIndex:index];
            BOOL visible = ((MacWSMsgBool)objc_msgSend)(
                candidate, sel_registerName("isVisible"));
            CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                candidate, sel_registerName("frame"));
            if (visible && MacWSPointInRect(screenPoint, frame)) {
                hitWindow = candidate;
                hitWindowFrame = frame;
                break;
            }
        }
    }
    if (hitWindow) {
        reply.flags |= MacWSInputTargetHit;
        reply.windowNumber = (int32_t)((MacWSMsgInteger)objc_msgSend)(
            hitWindow, sel_registerName("windowNumber"));
        if (hitWindow == keyWindow)
            reply.flags |= MacWSInputTargetKeyWindow;
    }
    if (application && ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) {
        reply.flags |= MacWSInputTargetApplicationActive;
    }

    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    ssize_t sent = -1;
    int savedError = 0;
    if (socketFD >= 0) {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, MacWSInputTargetReplyPath,
                sizeof(address.sun_path));
        sent = sendto(socketFD, &reply, sizeof(reply), MSG_DONTWAIT,
                      (const struct sockaddr *)&address, sizeof(address));
        if (sent != (ssize_t)sizeof(reply)) savedError = errno;
        close(socketFD);
    } else {
        savedError = errno;
    }
    static unsigned probeLogs;
    if (probeLogs++ < 24) {
        fprintf(stderr,
                "#### APP-INPUT TARGET-REPLY pid=%d nonce=%llu "
                "window=%d flags=%#x frame=(%.1f,%.1f %.1fx%.1f) "
                "sent=%zd errno=%d\n",
                getpid(), (unsigned long long)probe.nonce,
                reply.windowNumber, reply.flags,
                hitWindowFrame.origin.x, hitWindowFrame.origin.y,
                hitWindowFrame.size.width, hitWindowFrame.size.height, sent,
                sent == (ssize_t)sizeof(reply) ? 0 : savedError);
        fflush(stderr);
    }
}

static void MacWSScheduleTargetProbeReply(MacWSInputTargetProbe probe) {
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            MacWSReplyToTargetProbeOnMainThread(probe);
        }
    });
    CFRunLoopWakeUp(mainRunLoop);
}

static void *MacWSAppInputThread(void *unused) {
    (void)unused;
    fprintf(stderr, "#### APP-INPUT THREAD pid=%d socket=%d\n",
            getpid(), MacWSAppInputSocket);
    fflush(stderr);
    while (MacWSAppInputSocket >= 0) {
        union {
            MacWSInputRecord record;
            MacWSInputTargetProbe probe;
        } message = {0};
        ssize_t count = recv(MacWSAppInputSocket, &message, sizeof(message), 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (count == sizeof(MacWSInputTargetProbe) &&
            message.probe.magic == MACWS_TARGET_PROBE_MAGIC &&
            message.probe.version == MACWS_TARGET_VERSION &&
            message.probe.size == sizeof(MacWSInputTargetProbe) &&
            isfinite(message.probe.x) && isfinite(message.probe.y) &&
            message.probe.frameWidth != 0 &&
            message.probe.frameHeight != 0) {
            MacWSScheduleTargetProbeReply(message.probe);
            continue;
        }
        MacWSInputRecord record = message.record;
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
        // During a real NSControl tracking loop the main thread is synchronous
        // inside sendEvent(mouseDown), and that private tracker does not run
        // our CFRunLoop common-mode drain. NSApplication documents subthread
        // postEvent:atStart: as feeding the main event queue, so route live
        // move/up records there. The route lock makes this mutually exclusive
        // with the ordinary pending queue at the live-mode boundary.
        MacWSDirectTrackingSnapshot snapshot = {0};
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        BOOL postedDirectly =
            MacWSPrepareDirectTrackingPostLocked(record, &snapshot);
        if (!postedDirectly) MacWSEnqueueAppInputRecord(record);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        if (postedDirectly) MacWSPostDirectTrackingRecord(record, snapshot);
    }
    return NULL;
}

__attribute__((constructor)) static void MacWSInstallAppInputBridge(void) {
    if (!MacWSAppInputSupportedProcess()) return;
    MacWSAppInputPending = [NSMutableArray new];
    MacWSAppInputDeferredRFBMoveEvents = [NSMutableArray new];
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
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    MacWSAppInputRFBTrackingActive = NO;
    MacWSClearDirectTrackingContextLocked();
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
    MacWSSetDeferredRFBDownEvent(nil);
    MacWSClearDeferredRFBMoveEvents();
    MacWSSetAppInputGestureWindow(nil);
    MacWSSetAppInputGestureHitView(nil);
    if (MacWSAppInputSocket >= 0) close(MacWSAppInputSocket);
    if (MacWSAppInputPath[0]) unlink(MacWSAppInputPath);
}
