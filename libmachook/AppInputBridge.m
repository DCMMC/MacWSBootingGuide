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
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
typedef BOOL (*MacWSMsgBool)(id, SEL);
typedef id (*MacWSMouseEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                     NSTimeInterval, NSInteger, id, NSInteger,
                                     NSInteger, float);
typedef void (*MacWSPostEvent)(id, SEL, id, BOOL);
typedef void (*MacWSSendEvent)(id, SEL, id);

static int MacWSAppInputSocket = -1;
static char MacWSAppInputPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
static NSInteger MacWSAppInputEventNumber;
static NSMutableArray *MacWSAppInputPending;
static BOOL MacWSAppInputDrainScheduled;
// Main-thread-only. RFB tap-down is held until its matching up arrives. The
// pair can then be delivered with up already in NSApplication's queue before
// sendEvent(down) enters an NSButton/NSControl nested tracking loop.
static CFTypeRef MacWSAppInputDeferredRFBDownEvent;
// Main-thread-only. True while sendEvent(mouseDown) owns an AppKit nested
// tracking loop. Records scheduled by the socket thread during that interval
// must enter NSApplication's event queue so the real control tracker, rather
// than a synthetic direct action, consumes move/up in order.
static BOOL MacWSAppInputRFBTrackingActive;
// Main-thread-only.  Retain the window selected by mouse-down until the
// matching up/cancel.  Runtime evidence showed a title-bar down can close the
// front Terminal window synchronously; re-hit-testing the up then targeted the
// newly exposed window (23 -> 6), splitting one gesture across two windows.
static CFTypeRef MacWSAppInputGestureWindow;

static void MacWSSetAppInputGestureWindow(id window) {
    CFTypeRef replacement = window
        ? CFRetain((__bridge CFTypeRef)window) : NULL;
    CFTypeRef previous = MacWSAppInputGestureWindow;
    MacWSAppInputGestureWindow = replacement;
    if (previous) CFRelease(previous);
}

static void MacWSSetDeferredRFBDownEvent(id event) {
    CFTypeRef replacement = event
        ? CFRetain((__bridge CFTypeRef)event) : NULL;
    CFTypeRef previous = MacWSAppInputDeferredRFBDownEvent;
    MacWSAppInputDeferredRFBDownEvent = replacement;
    if (previous) CFRelease(previous);
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
        ++MacWSAppInputEventNumber, 1, pressure);
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
            ++MacWSAppInputEventNumber, 1, 0.0f);
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
        MacWSSetAppInputGestureWindow(nil);
        return;
    }
    if (isRFB && record.kind == MacWSInputKindTouchDown) {
        // Do not enter control tracking until the complete tap is available.
        // The chroot application has no ordinary login-session event pump;
        // runtime evidence showed two postEvent: calls remain unconsumed.
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
        // The first meaningful move turns a held possible-tap into a drag. Put
        // that move in the queue before entering control tracking; later move
        // and up records run through the re-entrant branch above.
        id downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
        MacWSSetDeferredRFBDownEvent(nil);
        MacWSAppInputRFBTrackingActive = YES;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), downEvent);
        MacWSAppInputRFBTrackingActive = NO;
        fprintf(stderr,
            "#### APP-INPUT DRAG-DISPATCH-RETURN pid=%d gesture=%u window=%ld "
            "first-move=(%.2f,%.2f)\n",
            getpid(), record.contactID, (long)windowNumber,
            screenPoint.x, screenPoint.y);
        fflush(stderr);
        [downEvent release];
    } else if (isRFB &&
        (record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel) &&
        MacWSAppInputDeferredRFBDownEvent) {
        id downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
        MacWSSetDeferredRFBDownEvent(nil);
        // Put mouse-up at the front before mouse-down enters a nested control
        // tracking loop. AppKit consumes the matching up using its normal
        // nextEventMatchingMask path; no target action is invoked directly.
        MacWSAppInputRFBTrackingActive = YES;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), downEvent);
        MacWSAppInputRFBTrackingActive = NO;
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
        // (GlassDemo's diagnostic context menu does exactly that). Enqueue an
        // ordered drain in common modes so both ordinary and nested loops
        // service input without reordering a gesture.
        MacWSEnqueueAppInputRecord(record);
    }
    return NULL;
}

__attribute__((constructor)) static void MacWSInstallAppInputBridge(void) {
    if (!MacWSAppInputSupportedProcess()) return;
    MacWSAppInputPending = [NSMutableArray new];
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
    MacWSSetDeferredRFBDownEvent(nil);
    MacWSSetAppInputGestureWindow(nil);
    if (MacWSAppInputSocket >= 0) close(MacWSAppInputSocket);
    if (MacWSAppInputPath[0]) unlink(MacWSAppInputPath);
}
