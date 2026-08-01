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
#import <dlfcn.h>
#import <math.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <ptrauth.h>
#import <ctype.h>
#import <stdatomic.h>
#import <stdarg.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>

#import "macws_host_protocol.h"
#import "macws_menu_protocol.h"
#import "macws_stream_protocol.h"

typedef id (*MacWSMsgID)(id, SEL);
typedef id (*MacWSMsgIDID)(id, SEL, id);
typedef id (*MacWSMsgIDInteger)(id, SEL, NSInteger);
typedef CGRect (*MacWSMsgRect)(id, SEL);
typedef CGRect (*MacWSMsgRectRect)(id, SEL, CGRect);
typedef CGRect (*MacWSMsgRectRectID)(id, SEL, CGRect, id);
typedef CGPoint (*MacWSMsgPoint)(id, SEL);
typedef CGPoint (*MacWSMsgPointPoint)(id, SEL, CGPoint);
typedef CGPoint (*MacWSMsgPointPointID)(id, SEL, CGPoint, id);
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
typedef NSInteger (*MacWSMsgIntegerPointInteger)(id, SEL, CGPoint, NSInteger);
typedef NSUInteger (*MacWSMsgUInteger)(id, SEL);
typedef CGSize (*MacWSMsgSize)(id, SEL);
typedef BOOL (*MacWSMsgBool)(id, SEL);
typedef BOOL (*MacWSMsgBoolSEL)(id, SEL, SEL);
typedef BOOL (*MacWSMsgBoolID)(id, SEL, id);
typedef BOOL (*MacWSMsgBoolSELIDID)(id, SEL, SEL, id, id);
typedef void (*MacWSMsgVoid)(id, SEL);
typedef void (*MacWSMsgVoidBool)(id, SEL, BOOL);
typedef void (*MacWSMsgVoidRectBoolBool)(id, SEL, CGRect, BOOL, BOOL);
typedef double (*MacWSMsgDouble)(id, SEL);
typedef id (*MacWSMsgIDPoint)(id, SEL, CGPoint);
typedef id (*MacWSMouseEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                     NSTimeInterval, NSInteger, id, NSInteger,
                                     NSInteger, float);
typedef id (*MacWSKeyEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                   NSTimeInterval, NSInteger, id, id, id,
                                   BOOL, unsigned short);
typedef const void *MacWSCGEventRef;
typedef MacWSCGEventRef (*MacWSCreateKeyboardCGEvent)(
    const void *, unsigned short, bool);
typedef MacWSCGEventRef (*MacWSCreateMouseCGEvent)(
    const void *, uint32_t, CGPoint, uint32_t);
typedef MacWSCGEventRef (*MacWSCreateScrollWheelCGEvent)(
    const void *, uint32_t, uint32_t, ...);
typedef MacWSCGEventRef (*MacWSCreateScrollWheelCGEvent2)(
    const void *, uint32_t, uint32_t, int32_t, int32_t, int32_t);
typedef void (*MacWSSetCGEventFlags)(MacWSCGEventRef, uint64_t);
typedef void (*MacWSSetCGEventLocation)(MacWSCGEventRef, CGPoint);
typedef void (*MacWSSetCGEventTimestamp)(MacWSCGEventRef, uint64_t);
typedef void (*MacWSSetCGEventUnicode)(MacWSCGEventRef, size_t,
                                      const unichar *);
typedef void (*MacWSSetCGEventIntegerField)(MacWSCGEventRef, uint32_t,
                                            int64_t);
typedef void (*MacWSSetCGEventDoubleField)(MacWSCGEventRef, uint32_t, double);
typedef id (*MacWSEventFromCGEvent)(id, SEL, MacWSCGEventRef);
typedef const void *(*MacWSEventRef)(id, SEL);
typedef void (*MacWSPostEvent)(id, SEL, id, BOOL);
typedef void (*MacWSSendEvent)(id, SEL, id);
typedef id (*MacWSNextEvent)(id, SEL, NSUInteger, id, id, BOOL);
typedef void (*MacWSHandleApplicationEvent)(id, SEL, id);
typedef void (*MacWSMenuEventLoop)(id, SEL, BOOL, id);
typedef NSUInteger (*MacWSPressedMouseButtons)(id, SEL);
typedef CGPoint (*MacWSMouseLocation)(id, SEL);
typedef int32_t (*MacWSCancelMenuTrackingPrivate)(uint8_t);
typedef int32_t (*MacWSCGWindowLevelForKey)(int32_t);
typedef void (*MacWSOrderWindow)(id, SEL, NSInteger, NSInteger);

static int MacWSAppInputSocket = -1;
static _Atomic int MacWSAppInputInstallState;
static char MacWSAppInputPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char MacWSWindowMetricsPath[PATH_MAX];
static NSData *MacWSLastWindowMetricsEntries;
static uint64_t MacWSWindowMetricsGeneration;
static void MacWSPublishWindowMetrics(void);
static void MacWSNotifyDisplayCatalogChanged(uint8_t reason);
static void MacWSNotifyDisplayGeometryChanged(uint32_t windowID, id window,
                                              CGRect appliedFrame);
// Main-thread-only semantic menu snapshot cache. ObjC objects never cross the
// process boundary: Host receives generation-scoped integer IDs, while the
// target process retains the corresponding item and index path solely long
// enough to revalidate a later action against the current NSMainMenu tree.
static NSMutableDictionary *MacWSMenuCaches;
static uint64_t MacWSMenuNextGeneration;
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
// NSEvent.pressedMouseButtons bit(s) represented by the one atomic gesture
// currently dispatched through AppKit (left=1, right=2).
static NSUInteger MacWSAppInputRFBTrackingButtons;
// NSApplication.windows is not a complete ownership registry: runtime on the
// current VSCode/Electron build captured a live level-101 CGWindow while both
// windows and orderedWindows contained only the document window. Keep weak
// references to real NSWindow instances when AppKit orders them, so routing
// can resolve the exact transient object instead of treating its pixels as an
// outside click on the base window.
static NSHashTable *MacWSOrderedWindowRegistry;
static MacWSOrderWindow MacWSOriginalOrderWindow;
static MacWSPressedMouseButtons MacWSOriginalPressedMouseButtons;
static MacWSMouseLocation MacWSOriginalMouseLocation;
// Main-thread scoped. AppKit's menu-bar tracker ignores the passed NSEvent's
// location while updating its tracked controller and consults this class
// property instead. Keep the override live only for that one handler call.
static BOOL MacWSAppInputMouseLocationActive;
static CGPoint MacWSAppInputMouseLocation;
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

static BOOL MacWSRuntimeDiagnosticsEnabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_runtime_diagnostics", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

static void MacWSTrackOrderedWindow(id window) {
    if (!window || !MacWSOrderedWindowRegistry) return;
    [MacWSOrderedWindowRegistry addObject:window];
}

static void MacWSAppInputOrderWindow(id self, SEL selector,
                                     NSInteger place,
                                     NSInteger relativeTo) {
    MacWSOriginalOrderWindow(self, selector, place, relativeTo);
    MacWSTrackOrderedWindow(self);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            self, sel_registerName("windowNumber"));
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            self, sel_registerName("level"));
        if (level > 0) {
            CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                self, sel_registerName("frame"));
            fprintf(stderr,
                "#### APP-INPUT WINDOW-REGISTRY pid=%d number=%ld class=%s "
                "place=%ld relative=%ld level=%ld frame=(%.1f,%.1f %.1fx%.1f)\n",
                getpid(), (long)number, object_getClassName(self),
                (long)place, (long)relativeTo, (long)level,
                frame.origin.x, frame.origin.y,
                frame.size.width, frame.size.height);
            fflush(stderr);
        }
    }
}

static void MacWSInstallOrderedWindowRegistry(void) {
    if (!MacWSOrderedWindowRegistry) {
        Class hashTableClass = objc_getClass("NSHashTable");
        if (hashTableClass) {
            MacWSOrderedWindowRegistry = [((id (*)(id, SEL))objc_msgSend)(
                (id)hashTableClass,
                sel_registerName("weakObjectsHashTable")) retain];
        }
    }
    Class windowClass = objc_getClass("NSWindow");
    SEL selector = sel_registerName("orderWindow:relativeTo:");
    Method method = windowClass
        ? class_getInstanceMethod(windowClass, selector) : NULL;
    if (!method || MacWSOriginalOrderWindow) return;
    IMP implementation = method_getImplementation(method);
    if (implementation == (IMP)MacWSAppInputOrderWindow) return;
    MacWSOriginalOrderWindow = (MacWSOrderWindow)implementation;
    method_setImplementation(method, (IMP)MacWSAppInputOrderWindow);
    // This runs from libmachook's initializer, before AppKit has registered
    // the process. Do not call +[NSApplication sharedApplication] here:
    // runtime on Electron PID 72595 showed that doing so aborts in
    // _RegisterApplication. Existing document windows remain discoverable
    // through the request-time application.windows scan; this registry is
    // specifically for later transient windows crossing orderWindow:.
}

// Objective-C constant-string objects emitted into this injected arm64e dylib
// carry the dylib's build-time authenticated isa representation.  The target
// macOS shared cache uses a different arm64e signing context on iOS, so
// messaging one of those literals can fault in objc_msgSend before the method
// body runs.  Runtime-confirmed by
// Terminal-2026-07-31-122017.ips: MacWSMenuAppendString received the @""
// returned by MacWSMenuShortcutForItem and objc_msgSend authenticated its isa
// as 0x00200001fc9b05e8.  Construct the few bridge-owned strings through the
// realized runtime class instead; AppKit-owned NSString instances remain
// untouched.
static NSString *MacWSRuntimeString(const char *utf8) {
    Class stringClass = objc_getClass("NSString");
    if (!stringClass || !utf8) return nil;
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)stringClass, sel_registerName("stringWithUTF8String:"), utf8);
}

static int MacWSFilteredFprintf(FILE *stream, const char *format, ...)
    __attribute__((format(printf, 2, 3)));
static int MacWSFilteredFprintf(FILE *stream, const char *format, ...) {
    if (stream == stderr && !MacWSRuntimeDiagnosticsEnabled()) return 0;
    va_list args;
    va_start(args, format);
    int result = vfprintf(stream, format, args);
    va_end(args);
    return result;
}
#define fprintf MacWSFilteredFprintf

typedef struct {
    NSInteger windowNumber;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
    BOOL menuSurface;
} MacWSDirectTrackingSnapshot;
// The target probe runs on the application main thread immediately before a
// native VNC button-down.  Cache the selected application's ordinary AppKit
// event-queue geometry there so the socket thread can post mouseMoved while a
// synchronous NSCarbonMenuImpl tracker owns the main thread.  The Carbon
// tracker in this macOS build calls _NSHLTBMenuEventProc, which in turn blocks
// in NSApplication's _nextEventMatching...; posting a separate Carbon EventRef
// targets the wrong queue.
static MacWSDirectTrackingSnapshot MacWSAppInputMenuContext;
static BOOL MacWSAppInputMenuContextValid;
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
static MacWSSendEvent MacWSOriginalApplicationSendEvent;
static MacWSHandleApplicationEvent MacWSOriginalHandleActivatedEvent;
typedef struct {
    Class ownerClass;
    MacWSMenuEventLoop original;
} MacWSMenuEventLoopHook;
static MacWSMenuEventLoopHook MacWSMenuEventLoopHooks[32];
static size_t MacWSMenuEventLoopHookCount;
// Socket-thread key records are ordered. When Escape closes an active menu
// through AppKit's semantic cancellation path, consume its matching key-up so
// it cannot leak into the content window after the asynchronous close lands.
static _Atomic BOOL MacWSAppInputConsumeEscapeUp;
// True from immediately before an atomic secondary down enters
// NSApplication.sendEvent until the contextual-menu/rightMouseDown call
// returns. The socket thread uses this lifecycle witness to cancel the real
// HIToolbox tracker even if a main-thread target probe cannot publish the
// transient NSMenuWindowManagerWindow while that tracker is nested.
static _Atomic BOOL MacWSAppInputSynchronousTrackingActive;
// Main-thread-only observational witness. The wrapped AppKit method owns the
// real nested menu event loop for the complete lifetime of this pointer.
// AppInput uses it only to put mouse-moved NSEvents into NSApplication's real
// queue; AppKit remains responsible for hit-testing, highlighting and action.
static id MacWSAppInputTrackingMenuPresentation;
// Main-thread-only.  This is the real AppKit/CGS activation event delivered
// for the latest native click, retained so a missing Workspace lifecycle
// callback can be completed with the exact event AppKit generated.
static CFTypeRef MacWSLastSystemActivationEvent;
static double MacWSLastSystemActivationEventTime;
static _Atomic uint64_t MacWSApplicationDisplaySettleSerial;
static uint32_t MacWSApplicationDisplaySettleMilliseconds;

typedef struct {
    uint32_t highLongOfPSN;
    uint32_t lowLongOfPSN;
} MacWSProcessSerialNumber;

typedef int32_t (*MacWSGetFrontUIProcess)(MacWSProcessSerialNumber *);
typedef int32_t (*MacWSSameProcess)(const MacWSProcessSerialNumber *,
                                    const MacWSProcessSerialNumber *,
                                    uint8_t *);
typedef const void *(*MacWSGetCurrentApplicationASN)(void);
typedef int32_t (*MacWSSetFrontApplication)(int32_t, const void *,
                                            CFDictionaryRef);
typedef int32_t (*MacWSSetApplicationInformationItem)(
    int32_t, const void *, CFStringRef, CFTypeRef, CFDictionaryRef *);
typedef int32_t (*MacWSSLPSGetProcess)(MacWSProcessSerialNumber *);
typedef int32_t (*MacWSSLPSGetKeyFocusProcess)(
    MacWSProcessSerialNumber *, uint8_t *);
typedef int32_t (*MacWSSLPSSetFrontProcessWithOptions)(
    const MacWSProcessSerialNumber *, uint32_t, uint64_t);
typedef int32_t (*MacWSSLPSStealKeyFocus)(void *, uint32_t);
typedef void *(*MacWSHIApplicationGetAppObject)(void);
typedef void (*MacWSHIApplicationFrontUILost)(void *);
typedef void (*MacWSSetMenuBarObscured)(uint8_t);
typedef void (*MacWSRecalcBar)(uint8_t);
static void *MacWSResolveHIToolboxLocal(uintptr_t imageOffset,
                                        const uint8_t *expectedPrologue,
                                        size_t expectedPrologueSize);

typedef struct {
    int32_t getStatus;
    int32_t sameStatus;
    MacWSProcessSerialNumber front;
    BOOL ownsFrontUIProcess;
} MacWSFrontUISnapshot;

// RE-confirmed on-device against macOS 13.4:
// +[NSMenuUtils isCurrentProcessMenuBarOwner] calls _GetFrontUIProcess and
// SameProcess against the special current-process PSN {0, 2}.  Mirror that
// read-only test so target selection observes the same ownership invariant as
// AppKit's global menu and transient-presentation code.
static MacWSFrontUISnapshot MacWSCaptureFrontUISnapshot(void) {
    static MacWSGetFrontUIProcess getFrontUIProcess;
    static MacWSSameProcess sameProcess;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getFrontUIProcess = (MacWSGetFrontUIProcess)dlsym(
            RTLD_DEFAULT, "_GetFrontUIProcess");
        sameProcess = (MacWSSameProcess)dlsym(RTLD_DEFAULT, "SameProcess");
    });
    MacWSFrontUISnapshot snapshot = {
        .getStatus = INT32_MIN,
        .sameStatus = INT32_MIN,
    };
    if (!getFrontUIProcess || !sameProcess) return snapshot;
    snapshot.getStatus = getFrontUIProcess(&snapshot.front);
    if (snapshot.getStatus != 0) return snapshot;
    const MacWSProcessSerialNumber current = {0, 2};
    uint8_t same = 0;
    snapshot.sameStatus = sameProcess(&snapshot.front, &current, &same);
    snapshot.ownsFrontUIProcess = snapshot.sameStatus == 0 && same != 0;
    return snapshot;
}

// SkyLight front/key focus, LaunchServices front application, and
// LaunchServices menu-bar ownership are three separate transactions in this
// macOS build.  On-device RE proves _LSSetFrontApplication sends message 0x38e
// and only changes LSSession::frontApplication.  Menu ownership is an
// application property, not a session-meta property: the five-argument
// _LSSetApplicationInformationItem(-2, ASN, _kLSMenuBarOwningASNKey, ASN,
// NULL) sends command 0x1fe.  Its launchservicesd handler resolves the target
// application and the key callback reaches
// LSSession::SetMenuBarOwningApplication, which locks the session shared page,
// writes MenuBarOwnerASNLow, and increments its seed.  The superficially
// successful _LSSetMetaApplicationInformationItem command 0xd2 instead logs
// this key as unrecognized and performs no owner mutation.  Run the upstream
// transactions only after the broker has observed a real cross-process native
// click whose normal activation transaction did not converge.
static BOOL MacWSRepairFrontUIApplication(id application, const char *phase) {
    BOOL diagnostics = MacWSRuntimeDiagnosticsEnabled();
    MacWSFrontUISnapshot before = diagnostics
        ? MacWSCaptureFrontUISnapshot() : (MacWSFrontUISnapshot){0};
    MacWSProcessSerialNumber currentProcess = {0};
    MacWSProcessSerialNumber keyFocusBefore = {0};
    MacWSProcessSerialNumber keyFocusAfter = {0};
    uint8_t keyFocusBeforeValid = 0;
    uint8_t keyFocusAfterValid = 0;
    int32_t currentProcessStatus = INT32_MIN;
    int32_t skyLightSetStatus = INT32_MIN;
    int32_t stealKeyFocusStatus = INT32_MIN;
    int32_t keyFocusBeforeStatus = INT32_MIN;
    int32_t keyFocusAfterStatus = INT32_MIN;
    uint32_t targetWindowNumber = 0;
    int32_t setStatus = INT32_MIN;
    int32_t menuOwnerSetStatus = INT32_MIN;
    const void *asn = NULL;
    static MacWSGetCurrentApplicationASN getCurrentApplicationASN;
    static MacWSSetFrontApplication setFrontApplication;
    static MacWSSetApplicationInformationItem
        setApplicationInformationItem;
    static const CFStringRef *menuBarOwningASNKeyAddress;
    static MacWSSLPSGetProcess getCurrentProcess;
    static MacWSSLPSGetKeyFocusProcess getKeyFocusProcess;
    static MacWSSLPSSetFrontProcessWithOptions
        setFrontProcessWithOptions;
    static MacWSSLPSStealKeyFocus stealKeyFocus;
    static MacWSSetMenuBarObscured setMenuBarObscured;
    static MacWSRecalcBar recalcBar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getCurrentApplicationASN =
            (MacWSGetCurrentApplicationASN)dlsym(
                RTLD_DEFAULT, "_LSGetCurrentApplicationASN");
        setFrontApplication = (MacWSSetFrontApplication)dlsym(
            RTLD_DEFAULT, "_LSSetFrontApplication");
        setApplicationInformationItem =
            (MacWSSetApplicationInformationItem)dlsym(
                RTLD_DEFAULT, "_LSSetApplicationInformationItem");
        menuBarOwningASNKeyAddress = (const CFStringRef *)dlsym(
            RTLD_DEFAULT, "_kLSMenuBarOwningASNKey");
        getCurrentProcess = (MacWSSLPSGetProcess)dlsym(
            RTLD_DEFAULT, "SLPSGetCurrentProcess");
        getKeyFocusProcess = (MacWSSLPSGetKeyFocusProcess)dlsym(
            RTLD_DEFAULT, "SLPSGetKeyFocusProcess");
        setFrontProcessWithOptions =
            (MacWSSLPSSetFrontProcessWithOptions)dlsym(
                RTLD_DEFAULT, "SLPSSetFrontProcessWithOptions");
        stealKeyFocus = (MacWSSLPSStealKeyFocus)dlsym(
            RTLD_DEFAULT, "SLPSStealKeyFocus");
        setMenuBarObscured = (MacWSSetMenuBarObscured)dlsym(
            RTLD_DEFAULT, "SetMenuBarObscured");
        if (!setMenuBarObscured) {
            static const uint8_t prologue[16] = {
                0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x00, 0xd1,
                0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9,
            };
            setMenuBarObscured = (MacWSSetMenuBarObscured)
                MacWSResolveHIToolboxLocal(
                    0x467f4, prologue, sizeof(prologue));
        }
        // RE-confirmed against this HIToolbox UUID: SetRootMenu calls
        // RecalcBarIfRoot, but skips that entire transaction when the target
        // process already installed the same gRootMenu before it became the
        // session menu-bar owner. Resolve the exact downstream RecalcBar(1)
        // used by RecalcBarIfRoot+0x84 so the owner handoff can recompute and
        // invalidate the target process's real root menu.
        static const uint8_t recalcBarPrologue[12] = {
            0x7f, 0x23, 0x03, 0xd5, 0xfd, 0x7b, 0xbf, 0xa9,
            0xfd, 0x03, 0x00, 0x91,
        };
        recalcBar = (MacWSRecalcBar)MacWSResolveHIToolboxLocal(
            0x11878, recalcBarPrologue, sizeof(recalcBarPrologue));
    });
    if (diagnostics && getKeyFocusProcess) {
        keyFocusBeforeStatus = getKeyFocusProcess(
            &keyFocusBefore, &keyFocusBeforeValid);
    }
    if (getCurrentProcess) {
        currentProcessStatus = getCurrentProcess(&currentProcess);
    }
    id keyWindow = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow")) : nil;
    if (!keyWindow && application) {
        keyWindow = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainWindow"));
    }
    if (!keyWindow && application) {
        id orderedWindows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("orderedWindows"));
        NSUInteger count = [orderedWindows count];
        for (NSUInteger index = 0; index < count; index++) {
            id candidate = [orderedWindows objectAtIndex:index];
            if (((MacWSMsgBool)objc_msgSend)(
                    candidate, sel_registerName("isVisible"))) {
                keyWindow = candidate;
                break;
            }
        }
    }
    if (keyWindow) {
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            keyWindow, sel_registerName("windowNumber"));
        if (number > 0 && number <= UINT32_MAX)
            targetWindowNumber = (uint32_t)number;
    }
    if (currentProcessStatus == 0 && setFrontProcessWithOptions) {
        // RE-confirmed in SkyLight 13.4: option 0x100 is allWindows and
        // 0x200 is causedByUser.  The public HIServices path discards both
        // before calling SLPSSetFrontProcess(window=0, options=0).  This
        // broker control exists only after a real native RFB mouse-down, so
        // preserve that actual user cause and the exact AppKit key window in
        // the server-side front-process transaction.
        skyLightSetStatus = setFrontProcessWithOptions(
            &currentProcess, targetWindowNumber, 0x300);
    }
    if (skyLightSetStatus == 0 && stealKeyFocus) {
        // Runtime-confirmed before this call was added: the explicit front
        // transaction returned 0 while SLPSGetKeyFocusProcess still named
        // GlassDemo (PSN 0x9009) from inside Terminal (PSN 0x8008).  This
        // official SkyLight operation asks the caller's primary connection to
        // become key focus; it does not forge an isKey/isActive result.
        stealKeyFocusStatus = stealKeyFocus(NULL, 0);
    }
    asn = getCurrentApplicationASN
        ? getCurrentApplicationASN() : NULL;
    if (asn && setFrontApplication) {
        // -2 is the current LaunchServices session.  It is the same session
        // selector used by _GetFrontUIProcess's _LSCopyFrontUIApplication
        // call in this exact binary.  Send the transaction for every broker-
        // coordinated activation: runtime showed that SameProcess can report
        // the caller-equivalent PSN before the visible global menu has moved,
        // so it is a postcondition witness but not a safe reason to omit the
        // upstream LaunchServices write.
        setStatus = setFrontApplication(-2, asn, NULL);
    }
    if (asn && setApplicationInformationItem &&
        menuBarOwningASNKeyAddress && *menuBarOwningASNKeyAddress) {
        // Target the current application's real information record.  The
        // fifth argument requests the prior dictionary when non-NULL; the
        // bridge does not need it.  Do not write the client shared page: its
        // mapping is read-only and an on-device unchanged-value write was
        // runtime-confirmed to raise SIGBUS.
        menuOwnerSetStatus = setApplicationInformationItem(
            -2, asn, *menuBarOwningASNKeyAddress, (CFTypeRef)asn, NULL);
    }
    id mainMenu = nil;
    id menuImplementation = nil;
    const char *installedMainMenuBar = "NO";
    SEL mainMenuSelector = sel_registerName("mainMenu");
    SEL menuImplementationSelector = sel_registerName("_menuImpl");
    SEL setAsMainMenuBarSelector = sel_registerName("setAsMainMenuBar");
    SEL setAsMainCarbonMenuBarSelector =
        sel_registerName("setAsMainCarbonMenuBar");
    if (application && ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            mainMenuSelector)) {
        mainMenu = ((MacWSMsgID)objc_msgSend)(
            application, mainMenuSelector);
    }
    if (mainMenu && ((MacWSMsgBoolSEL)objc_msgSend)(
            mainMenu, sel_registerName("respondsToSelector:"),
            menuImplementationSelector)) {
        menuImplementation = ((MacWSMsgID)objc_msgSend)(
            mainMenu, menuImplementationSelector);
    }
    if (menuImplementation && ((MacWSMsgBoolSEL)objc_msgSend)(
            menuImplementation, sel_registerName("respondsToSelector:"),
            setAsMainMenuBarSelector)) {
        // RE-confirmed in this AppKit build: NSMenu's NSMainMenu path ends by
        // sending setAsMainMenuBar to its existing _menuImpl.  Re-send that
        // real installation step after the missing cross-process activation
        // transaction; do not replace the menu, forge ownership, or override
        // any AppKit predicate.
        ((MacWSMsgVoid)objc_msgSend)(
            menuImplementation, setAsMainMenuBarSelector);
        installedMainMenuBar = "APPKIT";
    } else if (menuImplementation && ((MacWSMsgBoolSEL)objc_msgSend)(
            menuImplementation, sel_registerName("respondsToSelector:"),
            setAsMainCarbonMenuBarSelector)) {
        // The compatibility menu implementation takes the sibling branch in
        // the same NSMenu::_setMenuName(NSMainMenu) function.  Terminal 13.4
        // runtime-confirmed its _menuImpl exposes this selector rather than
        // setAsMainMenuBar.
        ((MacWSMsgVoid)objc_msgSend)(
            menuImplementation, setAsMainCarbonMenuBarSelector);
        installedMainMenuBar = "CARBON";
    }
    const char *recalculatedMainMenuBar = "NOT-CARBON";
    if (strcmp(installedMainMenuBar, "CARBON") == 0) {
        if (recalcBar) {
            recalcBar(1);
            recalculatedMainMenuBar = "CALLED";
        } else {
            recalculatedMainMenuBar = "UNAVAILABLE";
        }
    }
    const char *unobscuredMenuBar = "UNAVAILABLE";
    if (setMenuBarObscured) {
        // RE-confirmed ordering in HIToolbox 13.4:
        // HIApplication::HandleActivated(active=true) executes
        // EndNonActiveMenuBar followed by SetMenuBarObscured(false), while
        // FrontUILost executes SetMenuBarObscured(true).  The native target
        // activation arrives before the broker can drain the old process's
        // asynchronous deactivation.  Re-assert the real final activation
        // step after installing this target's actual menu implementation.
        setMenuBarObscured(0);
        unobscuredMenuBar = "CALLED";
    }
    if (diagnostics && getKeyFocusProcess) {
        keyFocusAfterStatus = getKeyFocusProcess(
            &keyFocusAfter, &keyFocusAfterValid);
    }
    MacWSFrontUISnapshot after = MacWSCaptureFrontUISnapshot();
    if (diagnostics) {
        fprintf(stderr,
        "#### APP-INPUT FRONT-UI pid=%d phase=%s "
        "before=%s get=%d same=%d psn=%#x-%#x "
        "current=%d:%#x-%#x sky-set=%d steal-key=%d window=%u "
        "key-before=%d:%d:%#x-%#x key-after=%d:%d:%#x-%#x "
        "asn=%p ls-set=%d ls-menu-owner=%d menu=%p impl=%p "
        "install=%s recalc=%s unobscure=%s "
        "after=%s get=%d same=%d psn=%#x-%#x\n",
        getpid(), phase ? phase : "(null)",
        before.ownsFrontUIProcess ? "OWNED" : "OTHER",
        before.getStatus, before.sameStatus,
        before.front.highLongOfPSN, before.front.lowLongOfPSN,
        currentProcessStatus, currentProcess.highLongOfPSN,
        currentProcess.lowLongOfPSN, skyLightSetStatus,
        stealKeyFocusStatus,
        targetWindowNumber,
        keyFocusBeforeStatus, keyFocusBeforeValid,
        keyFocusBefore.highLongOfPSN, keyFocusBefore.lowLongOfPSN,
        keyFocusAfterStatus, keyFocusAfterValid,
        keyFocusAfter.highLongOfPSN, keyFocusAfter.lowLongOfPSN,
        asn, setStatus, menuOwnerSetStatus, mainMenu, menuImplementation,
        installedMainMenuBar, recalculatedMainMenuBar, unobscuredMenuBar,
        after.ownsFrontUIProcess ? "OWNED" : "OTHER",
        after.getStatus, after.sameStatus,
            after.front.highLongOfPSN, after.front.lowLongOfPSN);
        fflush(stderr);
    }
    return after.ownsFrontUIProcess;
}

static double MacWSAppInputMonotonicSeconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void MacWSSetLastSystemActivationEvent(id event) {
    CFTypeRef replacement = event
        ? CFRetain((__bridge CFTypeRef)event) : NULL;
    CFTypeRef previous = MacWSLastSystemActivationEvent;
    MacWSLastSystemActivationEvent = replacement;
    MacWSLastSystemActivationEventTime = event
        ? MacWSAppInputMonotonicSeconds() : 0.0;
    if (previous) CFRelease(previous);
}

static void MacWSAppInputHandleActivatedEvent(id self, SEL command, id event) {
    MacWSSetLastSystemActivationEvent(event);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        NSInteger windowNumber = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber")) : 0;
        NSInteger data1 = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("data1")) : 0;
        NSInteger data2 = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("data2")) : 0;
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-ACTIVATE-EVENT pid=%d window=%ld "
            "data1=%ld data2=%ld retained=%s\n",
            getpid(), (long)windowNumber, (long)data1, (long)data2,
            event ? "YES" : "NO");
        fflush(stderr);
    }
    if (MacWSOriginalHandleActivatedEvent)
        MacWSOriginalHandleActivatedEvent(self, command, event);
}

// Narrow usability scaffold at a runtime-confirmed Terminal race.  With fast
// commands, the pty model can advance after Return's delayed AppKit redraw has
// already been consumed, leaving the result one transaction behind.  LLDB also
// proved that Terminal normally calls -[NSView setNeedsDisplayInRect:] from an
// NSFireDelayedPerform callback, and output deliberately delayed by two seconds
// renders without this callback.  Therefore this is NOT a replacement display
// clock and must not be installed globally: only an application whose launch
// environment explicitly sets MACWS_APP_DISPLAY_SETTLE_MS gets one debounced
// post-key-up invalidation.  A 250-ms displayIfNeeded-only A/B observed
// viewsNeedDisplay=NO and did not recover the fast-output race; the forced
// responder invalidation is intentionally labelled a scaffold, not a root fix.
static void MacWSScheduleApplicationDisplaySettle(void) {
    uint64_t serial = atomic_fetch_add_explicit(
        &MacWSApplicationDisplaySettleSerial, 1,
        memory_order_acq_rel) + 1;
    uint64_t delayNanoseconds =
        (uint64_t)MacWSApplicationDisplaySettleMilliseconds * NSEC_PER_MSEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
                   dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&MacWSApplicationDisplaySettleSerial,
                                 memory_order_acquire) != serial) return;
        Class applicationClass = objc_getClass("NSApplication");
        id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
            applicationClass, sel_registerName("sharedApplication")) : nil;
        id window = application ? ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow")) : nil;
        id responder = window ? ((MacWSMsgID)objc_msgSend)(
            window, sel_registerName("firstResponder")) : nil;
        SEL setNeedsDisplay = sel_registerName("setNeedsDisplay:");
        BOOL canInvalidate = responder && ((MacWSMsgBoolSEL)objc_msgSend)(
            responder, sel_registerName("respondsToSelector:"),
            setNeedsDisplay);
        BOOL diagnostics = MacWSRuntimeDiagnosticsEnabled();
        BOOL hasString = diagnostics && responder &&
            ((MacWSMsgBoolSEL)objc_msgSend)(
                responder, sel_registerName("respondsToSelector:"),
                sel_registerName("string"));
        id string = hasString ? ((MacWSMsgID)objc_msgSend)(
            responder, sel_registerName("string")) : nil;
        NSUInteger stringLength = string ? ((MacWSMsgUInteger)objc_msgSend)(
            string, sel_registerName("length")) : 0;
        BOOL neededBefore = diagnostics && window &&
            ((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("viewsNeedDisplay"));
        double started = diagnostics
            ? MacWSAppInputMonotonicSeconds() : 0.0;
        if (canInvalidate) ((MacWSMsgVoidBool)objc_msgSend)(
            responder, setNeedsDisplay, YES);
        if (window) ((void (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("displayIfNeeded"));
        Class transactionClass = objc_getClass("CATransaction");
        SEL flushSelector = sel_registerName("flush");
        if (transactionClass && class_respondsToSelector(
                object_getClass(transactionClass), flushSelector)) {
            ((void (*)(id, SEL))objc_msgSend)(
                transactionClass, flushSelector);
        }
        if (diagnostics) {
            BOOL neededAfter = window && ((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("viewsNeedDisplay"));
            static _Atomic uint64_t settleCount;
            uint64_t count = atomic_fetch_add_explicit(
                &settleCount, 1, memory_order_relaxed) + 1;
            if (count <= 24) {
            fprintf(stderr,
                "#### APP-INPUT DISPLAY-SETTLE pid=%d serial=%llu "
                "window=%ld responder=%s string-length=%lu "
                "forced=%s needed-before=%s needed-after=%s "
                "delay=%ums elapsed=%.3fms at=%.6f\n",
                getpid(), (unsigned long long)serial,
                window ? (long)((MacWSMsgInteger)objc_msgSend)(
                    window, sel_registerName("windowNumber")) : -1L,
                responder ? object_getClassName(responder) : "(null)",
                (unsigned long)stringLength,
                canInvalidate ? "YES" : "NO",
                neededBefore ? "YES" : "NO",
                neededAfter ? "YES" : "NO",
                MacWSApplicationDisplaySettleMilliseconds,
                (MacWSAppInputMonotonicSeconds() - started) * 1000.0,
                started);
            fflush(stderr);
            }
        }
    });
}

// Observational witness for the boundary between CoreGraphics' event queue
// and the target AppKit main thread. OSXvnc logs the same monotonic clock at
// handleKeyboard entry. Comparing the two proves whether delay occurs before
// or after NSApplication receives the event; this hook never creates,
// suppresses, or rewrites an event.
static void MacWSAppInputApplicationSendEvent(id self, SEL command, id event) {
    NSUInteger type = event ? ((MacWSMsgUInteger)objc_msgSend)(
        event, sel_registerName("type")) : 0;
    uint64_t serial = 0;
    double started = 0.0;
    uint64_t mouseSerial = 0;
    double mouseStarted = 0.0;
    BOOL logMouseReturn = NO;
    id keyWindow = nil;
    id responder = nil;
    if ((type == 10 || type == 11) &&
        MacWSRuntimeDiagnosticsEnabled()) { // NSEventTypeKeyDown / KeyUp
        static _Atomic uint64_t keyEvents;
        serial = atomic_fetch_add_explicit(
            &keyEvents, 1, memory_order_relaxed) + 1;
        started = MacWSAppInputMonotonicSeconds();
        keyWindow = ((MacWSMsgID)objc_msgSend)(
            self, sel_registerName("keyWindow"));
        responder = keyWindow ? ((MacWSMsgID)objc_msgSend)(
            keyWindow, sel_registerName("firstResponder")) : nil;
        if (serial <= 48) {
            NSInteger keyCode = ((MacWSMsgInteger)objc_msgSend)(
                event, sel_registerName("keyCode"));
            id characters = ((MacWSMsgID)objc_msgSend)(
                event, sel_registerName("characters"));
            const char *utf8 = characters
                ? ((const char *(*)(id, SEL))objc_msgSend)(
                    characters, sel_registerName("UTF8String")) : NULL;
            fprintf(stderr,
                "#### APP-INPUT KEY-EVENT pid=%d serial=%llu type=%lu "
                "keycode=%ld chars=%s active=%s window=%ld responder=%s "
                "at=%.6f\n",
                getpid(), (unsigned long long)serial, (unsigned long)type,
                (long)keyCode, utf8 ?: "(null)",
                ((MacWSMsgBool)objc_msgSend)(
                    self, sel_registerName("isActive")) ? "YES" : "NO",
                keyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    keyWindow, sel_registerName("windowNumber")) : -1L,
                responder ? object_getClassName(responder) : "(null)",
                started);
            fflush(stderr);
        }
    } else if (type >= 1 && type <= 7 &&
               MacWSRuntimeDiagnosticsEnabled()) {
        // Observational boundary witness for the native-VNC A/B.  These are
        // the ordinary AppKit mouse event types (left/right down/up, moved,
        // left/right dragged).  Logging their real window/location/button
        // state proves whether CGPostMouseEvent delivered a coherent stream;
        // this hook never creates, changes, or suppresses an event.
        static _Atomic uint64_t mouseEvents;
        mouseSerial = atomic_fetch_add_explicit(
            &mouseEvents, 1, memory_order_relaxed) + 1;
        mouseStarted = MacWSAppInputMonotonicSeconds();
        logMouseReturn = mouseSerial <= 128 || (mouseSerial % 600) == 0;
        if (logMouseReturn) {
            NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(
                event, sel_registerName("windowNumber"));
            CGPoint location = ((MacWSMsgPoint)objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            Class eventClass = object_getClass(event);
            NSUInteger pressed = eventClass
                ? ((MacWSPressedMouseButtons)objc_msgSend)(
                    (id)eventClass, sel_registerName("pressedMouseButtons"))
                : 0;
            fprintf(stderr,
                "#### APP-INPUT MOUSE-EVENT pid=%d serial=%llu type=%lu "
                "window=%ld local=(%.2f,%.2f) pressed=%#lx at=%.6f\n",
                getpid(), (unsigned long long)mouseSerial,
                (unsigned long)type, (long)windowNumber,
                location.x, location.y, (unsigned long)pressed,
                mouseStarted);
            fflush(stderr);
        }
    }
    // Runtime-confirmed on a freshly launchd-started Terminal in coexist mode:
    // native CGPostMouseEvent delivered left down/up to the real window
    // (window=48), yet NSApplication.isActive stayed NO and target probes kept
    // returning Hit-only flags=0x1.  The title controls remained inactive and
    // the global menu bar had no owner.  Normal AppKit activates the receiving
    // application before dispatching a primary click; restore that lifecycle
    // transition through the public API only after a real window-targeted
    // native down has arrived in this process.
    if (type == 1) {
        NSInteger eventWindow = ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber"));
        BOOL active = ((MacWSMsgBool)objc_msgSend)(
            self, sel_registerName("isActive"));
        SEL activateSelector = sel_registerName("activateIgnoringOtherApps:");
        if (eventWindow > 0 && !active &&
            ((MacWSMsgBoolSEL)objc_msgSend)(
                self, sel_registerName("respondsToSelector:"),
                activateSelector)) {
            ((MacWSMsgVoidBool)objc_msgSend)(
                self, activateSelector, YES);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT SYSTEM-ACTIVATE pid=%d window=%ld "
                    "active-before=NO active-after=%s\n",
                    getpid(), (long)eventWindow,
                    ((MacWSMsgBool)objc_msgSend)(
                        self, sel_registerName("isActive")) ? "YES" : "NO");
                fflush(stderr);
            }
        }
    }
    // A permitted hardware CGEvent updates both the pressed-button mask and
    // +[NSEvent mouseLocation] before AppKit dispatches mouseDown.  Our
    // process-local NSEvent route already restores the former above, but the
    // latter otherwise remains at WindowServer's stale global cursor because
    // this launchd session cannot post a CGEvent.  AppKit's title/toolbar
    // trackers consult that global location even though the event carries a
    // correct locationInWindow; leaving the two coordinate states divergent
    // makes content views clickable while title-bar controls ignore the same
    // coherent down/up pair.  Scope the location bridge to the synchronous
    // synthetic tracker only.  Every unrelated caller still receives the
    // original NSEvent class-method result.
    BOOL bridgeMouseLocation = type >= 1 && type <= 7 &&
        MacWSAppInputRFBTrackingActive;
    BOOL previousMouseLocationActive = MacWSAppInputMouseLocationActive;
    CGPoint previousMouseLocation = MacWSAppInputMouseLocation;
    CGPoint bridgedMouseLocation = {0.0, 0.0};
    CGPoint originalMouseLocation = {0.0, 0.0};
    BOOL hasBridgedMouseLocation = NO;
    if (bridgeMouseLocation && event) {
        id eventWindow = ((MacWSMsgID)objc_msgSend)(
            event, sel_registerName("window"));
        if (eventWindow) {
            CGPoint eventLocation = ((MacWSMsgPoint)objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            bridgedMouseLocation = ((MacWSMsgPointPoint)objc_msgSend)(
                eventWindow, sel_registerName("convertPointToScreen:"),
                eventLocation);
            Class eventClass = object_getClass(event);
            originalMouseLocation = MacWSOriginalMouseLocation && eventClass
                ? MacWSOriginalMouseLocation(
                    (id)eventClass, sel_registerName("mouseLocation"))
                : (CGPoint){0.0, 0.0};
            MacWSAppInputMouseLocation = bridgedMouseLocation;
            MacWSAppInputMouseLocationActive = YES;
            hasBridgedMouseLocation = YES;
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT MOUSE-LOCATION pid=%d type=%lu "
                    "original=(%.2f,%.2f) event=(%.2f,%.2f)\n",
                    getpid(), (unsigned long)type,
                    originalMouseLocation.x, originalMouseLocation.y,
                    bridgedMouseLocation.x, bridgedMouseLocation.y);
                fflush(stderr);
            }
        }
    }
    if (MacWSOriginalApplicationSendEvent)
        MacWSOriginalApplicationSendEvent(self, command, event);
    if (hasBridgedMouseLocation) {
        MacWSAppInputMouseLocation = previousMouseLocation;
        MacWSAppInputMouseLocationActive = previousMouseLocationActive;
    }
    if (logMouseReturn) {
        double finished = MacWSAppInputMonotonicSeconds();
        Class eventClass = object_getClass(event);
        NSUInteger pressed = eventClass
            ? ((MacWSPressedMouseButtons)objc_msgSend)(
                (id)eventClass, sel_registerName("pressedMouseButtons"))
            : 0;
        fprintf(stderr,
            "#### APP-INPUT MOUSE-RETURN pid=%d serial=%llu type=%lu "
            "pressed=%#lx elapsed=%.3fms at=%.6f\n",
            getpid(), (unsigned long long)mouseSerial,
            (unsigned long)type, (unsigned long)pressed,
            (finished - mouseStarted) * 1000.0, finished);
        fflush(stderr);
    }
    if (type == 11 && MacWSApplicationDisplaySettleMilliseconds != 0)
        MacWSScheduleApplicationDisplaySettle();
    if (serial != 0 && serial <= 48) {
        double finished = MacWSAppInputMonotonicSeconds();
        BOOL hasString = responder && ((MacWSMsgBoolSEL)objc_msgSend)(
            responder, sel_registerName("respondsToSelector:"),
            sel_registerName("string"));
        id string = hasString ? ((MacWSMsgID)objc_msgSend)(
            responder, sel_registerName("string")) : nil;
        NSUInteger length = string ? ((MacWSMsgUInteger)objc_msgSend)(
            string, sel_registerName("length")) : 0;
        fprintf(stderr,
            "#### APP-INPUT KEY-RETURN pid=%d serial=%llu elapsed=%.3fms "
            "active=%s responder=%s has-string=%s length=%lu\n",
            getpid(), (unsigned long long)serial,
            (finished - started) * 1000.0,
            ((MacWSMsgBool)objc_msgSend)(
                self, sel_registerName("isActive")) ? "YES" : "NO",
            responder ? object_getClassName(responder) : "(null)",
            hasString ? "YES" : "NO", (unsigned long)length);
        fflush(stderr);
    }
}

static void MacWSInstallApplicationKeyWitness(void) {
    const char *settleValue = getenv("MACWS_APP_DISPLAY_SETTLE_MS");
    if (settleValue && *settleValue) {
        char *settleEnd = NULL;
        errno = 0;
        unsigned long settleMilliseconds = strtoul(
            settleValue, &settleEnd, 10);
        if (errno != 0 || settleEnd == settleValue || *settleEnd != '\0' ||
            settleMilliseconds < 16 || settleMilliseconds > 2000) {
            fprintf(stderr,
                "#### APP-INPUT DISPLAY-SETTLE disabled invalid "
                "MACWS_APP_DISPLAY_SETTLE_MS='%s' (valid=16..2000)\n",
                settleValue);
            fflush(stderr);
        } else {
            MacWSApplicationDisplaySettleMilliseconds =
                (uint32_t)settleMilliseconds;
        }
    }
    // This constructor runs while dyld is still executing initializers.
    // NSClassFromString builds an NSString and entered Foundation before its
    // ObjC initialization was complete on arm64e (runtime crash witness:
    // Terminal-2026-07-28-021535.ips, NSClassFromString+52). The ObjC runtime
    // lookup takes a plain C string and is already used by the bridge's event
    // path for these AppKit classes.
    Class applicationClass = objc_getClass("NSApplication");
    Method method = applicationClass ? class_getInstanceMethod(
        applicationClass, sel_registerName("sendEvent:")) : NULL;
    if (method) {
        IMP implementation = method_getImplementation(method);
        if (implementation != (IMP)MacWSAppInputApplicationSendEvent) {
            MacWSOriginalApplicationSendEvent = (MacWSSendEvent)implementation;
            method_setImplementation(method,
                (IMP)MacWSAppInputApplicationSendEvent);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-WITNESS installed "
                    "-[NSApplication sendEvent:] display-settle=%ums "
                    "(diagnostic scaffold)\n",
                    MacWSApplicationDisplaySettleMilliseconds);
                fflush(stderr);
            }
        }
    }
    Method activationMethod = applicationClass ? class_getInstanceMethod(
        applicationClass,
        sel_registerName("_handleActivatedEvent:")) : NULL;
    if (activationMethod) {
        IMP implementation = method_getImplementation(activationMethod);
        if (implementation != (IMP)MacWSAppInputHandleActivatedEvent) {
            MacWSOriginalHandleActivatedEvent =
                (MacWSHandleApplicationEvent)implementation;
            method_setImplementation(activationMethod,
                (IMP)MacWSAppInputHandleActivatedEvent);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT ACTIVATION-WITNESS installed "
                    "-[NSApplication _handleActivatedEvent:]\n");
                fflush(stderr);
            }
        }
    }
}

// Electron injects libmachook before AppKit has necessarily realized
// NSApplication.  The constructor's immediate lookup can therefore miss the
// observational sendEvent witness even though the same process later creates
// native menus. Retry only on the main queue, with a finite five-second
// window; the bridge's socket/event delivery does not depend on this witness.
static void MacWSScheduleApplicationKeyWitnessInstall(unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MacWSInstallApplicationKeyWitness();
        if ((!MacWSOriginalApplicationSendEvent ||
             !MacWSOriginalHandleActivatedEvent) && attempt < 19)
            MacWSScheduleApplicationKeyWitnessInstall(attempt + 1);
    });
}

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
    if (!MacWSRuntimeDiagnosticsEnabled()) return;
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

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSClearMenuContextLocked(void) {
    if (MacWSAppInputMenuContext.application) {
        CFRelease(MacWSAppInputMenuContext.application);
        MacWSAppInputMenuContext.application = NULL;
    }
    MacWSAppInputMenuContext.windowNumber = 0;
    MacWSAppInputMenuContext.screenFrame = (CGRect){0};
    MacWSAppInputMenuContext.windowMinusScreen = (CGPoint){0};
    MacWSAppInputMenuContext.eventClass = Nil;
    MacWSAppInputMenuContext.menuSurface = NO;
    MacWSAppInputMenuContextValid = NO;
}

// MacWSAppInputRouteLock must be held by the caller.  A system-menu probe can
// legitimately have no application NSWindow, so windowNumber=0 and screen
// coordinates are retained as an ordinary AppKit event target.
static void MacWSCacheMenuContextLocked(id application, Class eventClass,
                                        NSInteger windowNumber,
                                        CGRect screenFrame,
                                        CGPoint screenPoint,
                                        CGPoint windowPoint,
                                        BOOL menuSurface) {
    MacWSClearMenuContextLocked();
    if (!application || !eventClass || screenFrame.size.width <= 0.0 ||
        screenFrame.size.height <= 0.0) return;
    MacWSAppInputMenuContext.windowNumber = windowNumber;
    MacWSAppInputMenuContext.screenFrame = screenFrame;
    MacWSAppInputMenuContext.windowMinusScreen = (CGPoint){
        windowPoint.x - screenPoint.x,
        windowPoint.y - screenPoint.y,
    };
    MacWSAppInputMenuContext.eventClass = eventClass;
    MacWSAppInputMenuContext.application =
        CFRetain((__bridge CFTypeRef)application);
    MacWSAppInputMenuContext.menuSurface = menuSurface;
    MacWSAppInputMenuContextValid = YES;
}

// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSPrepareDirectMenuPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    BOOL isMenuMotion = record.kind == MacWSInputKindMenuHover ||
                        record.kind == MacWSInputKindHover;
    BOOL carbonTrackerActive = atomic_load_explicit(
        &MacWSAppInputSynchronousTrackingActive, memory_order_acquire);
    BOOL legacyVNCMenuMotion =
        record.sceneID == 0x564e430000000001ull &&
        record.kind == MacWSInputKindMenuHover;
    if (!isMenuMotion ||
        (!carbonTrackerActive && !legacyVNCMenuMotion) ||
        !MacWSAppInputMenuContextValid ||
        !MacWSAppInputMenuContext.application ||
        !MacWSAppInputMenuContext.eventClass) return NO;
    *snapshot = MacWSAppInputMenuContext;
    snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
    return YES;
}

// A contextual menu owns the application main thread synchronously inside
// HIToolbox TrackMenuCommon. A later Host tap therefore cannot be constructed
// by the ordinary main-run-loop drain: that drain is exactly what the tracker
// is blocking. Use the application/window geometry captured immediately
// before rightMouseDown entered the tracker and put the ordinary NSEvent pair
// into the queue that _NSHLTBMenuEventProc is already consuming.
// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSPrepareDirectMenuTapPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    if (record.kind != MacWSInputKindTap ||
        !atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                              memory_order_acquire) ||
        !MacWSAppInputMenuContextValid ||
        !MacWSAppInputMenuContext.application ||
        !MacWSAppInputMenuContext.eventClass) return NO;
    *snapshot = MacWSAppInputMenuContext;
    snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
    return YES;
}

// Target probes cache the selected process and its application object before
// the native down can enter a synchronous menu loop. Keyboard records use the
// same authoritative application context but do not depend on pointer
// geometry or a menu window number.
static BOOL MacWSPrepareDirectKeyPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    if ((record.kind != MacWSInputKindKeyDown &&
         record.kind != MacWSInputKindKeyUp) ||
        !atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                              memory_order_acquire) ||
        !MacWSAppInputMenuContextValid ||
        !MacWSAppInputMenuContext.application ||
        !MacWSAppInputMenuContext.eventClass) return NO;
    *snapshot = MacWSAppInputMenuContext;
    snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
    return YES;
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
    if (MacWSAppInputRFBTrackingActive)
        buttons |= MacWSAppInputRFBTrackingButtons;
    return buttons;
}

static CGPoint MacWSAppInputCurrentMouseLocation(id self, SEL command) {
    if (MacWSAppInputMouseLocationActive)
        return MacWSAppInputMouseLocation;
    return MacWSOriginalMouseLocation
        ? MacWSOriginalMouseLocation(self, command) : (CGPoint){0.0, 0.0};
}

// Process-local NSEvents cannot update WindowServer's global cursor state.
// Keep +[NSEvent mouseLocation] and pressedMouseButtons coherent for the
// duration of one direct synthetic dispatch, matching the state invariants of
// a hardware CGEvent. This is required even for button-free mouseMoved:
// NSTabBar uses the class-level mouse location to enter its hover state and
// reveal the standard close button before the following click.
static void MacWSSendMouseEventWithStateBridge(id application, id event,
                                                NSUInteger buttons) {
    if (!application || !event) return;
    BOOL previousActive = MacWSAppInputRFBTrackingActive;
    NSUInteger previousButtons = MacWSAppInputRFBTrackingButtons;
    MacWSAppInputRFBTrackingActive = YES;
    MacWSAppInputRFBTrackingButtons = buttons;
    ((MacWSSendEvent)objc_msgSend)(application,
        sel_registerName("sendEvent:"), event);
    MacWSAppInputRFBTrackingButtons = previousButtons;
    MacWSAppInputRFBTrackingActive = previousActive;
}

static void MacWSLogNSEventFactorySelectors(Class eventClass) {
    if (!eventClass || !MacWSRuntimeDiagnosticsEnabled()) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsigned int count = 0;
        Method *methods = class_copyMethodList(object_getClass(eventClass),
                                                &count);
        fprintf(stderr,
            "#### APP-INPUT NSEVENT-FACTORIES class=%s methods=%u\n",
            class_getName(eventClass), count);
        for (unsigned int index = 0; index < count; index++) {
            SEL selector = method_getName(methods[index]);
            const char *name = selector ? sel_getName(selector) : NULL;
            if (!name || (!strstr(name, "Event") &&
                          !strstr(name, "event") &&
                          !strstr(name, "Mouse") &&
                          !strstr(name, "mouse") &&
                          !strstr(name, "Window") &&
                          !strstr(name, "window"))) continue;
            fprintf(stderr,
                "#### APP-INPUT NSEVENT-FACTORY selector=%s types=%s\n",
                name, method_getTypeEncoding(methods[index]) ?: "(null)");
        }
        free(methods);
        fflush(stderr);
    });
}

static void MacWSInstallPressedMouseButtonsBridge(Class eventClass) {
    MacWSLogNSEventFactorySelectors(eventClass);
    SEL selector = sel_registerName("pressedMouseButtons");
    Method method = class_getClassMethod(eventClass, selector);
    if (!MacWSOriginalPressedMouseButtons && !method) {
        fprintf(stderr,
            "#### APP-INPUT STATE-BRIDGE unavailable: +[NSEvent pressedMouseButtons]\n");
        fflush(stderr);
    } else if (!MacWSOriginalPressedMouseButtons) {
        IMP implementation = method_getImplementation(method);
        if (implementation != (IMP)MacWSAppInputPressedMouseButtons) {
            MacWSOriginalPressedMouseButtons =
                (MacWSPressedMouseButtons)implementation;
            method_setImplementation(method,
                (IMP)MacWSAppInputPressedMouseButtons);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT STATE-BRIDGE installed "
                    "+[NSEvent pressedMouseButtons]\n");
                fflush(stderr);
            }
        }
    }

    SEL locationSelector = sel_registerName("mouseLocation");
    Method locationMethod = class_getClassMethod(eventClass,
                                                  locationSelector);
    if (!MacWSOriginalMouseLocation && locationMethod) {
        IMP implementation = method_getImplementation(locationMethod);
        if (implementation != (IMP)MacWSAppInputCurrentMouseLocation) {
            MacWSOriginalMouseLocation = (MacWSMouseLocation)implementation;
            method_setImplementation(locationMethod,
                (IMP)MacWSAppInputCurrentMouseLocation);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT STATE-BRIDGE installed "
                    "+[NSEvent mouseLocation]\n");
                fflush(stderr);
            }
        }
    }
}

static BOOL MacWSAppInputSupportedProcess(void) {
    const char *program = getprogname();
    // A finite application-name allowlist cannot cover Finder panels, menu
    // extras, newly installed GUI applications, or future Electron shells.
    // Install in every real AppKit application.  Chromium helpers are kept
    // out because they can load AppKit without owning a window/run loop; a
    // non-replying helper would unnecessarily consume the target-probe
    // deadline.  Processes that do not load NSApplication are not endpoints.
    if (!program || !objc_getClass("NSApplication")) return NO;
    if (strstr(program, "Helper") || strstr(program, "Renderer") ||
        strstr(program, "GPU") || strcmp(program, "WindowServer") == 0 ||
        strstr(program, "OSXvnc") || strcmp(program, "launchservicesd") == 0 ||
        strcmp(program, "macwsdisplayd") == 0 ||
        strcmp(program, "macwsinteropd") == 0)
        return NO;
    return YES;
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
        case MacWSInputKindMenuHover: return 5;   // menu-owned mouseMoved
        case MacWSInputKindTap: return 1;         // atomic left down + up
        case MacWSInputKindSecondaryTap: return 3; // atomic right down + up
        case MacWSInputKindTargetProbe:
        case MacWSInputKindActivateTarget:
        case MacWSInputKindDeactivateApplication:
        case MacWSInputKindKeyDown:
        case MacWSInputKindKeyUp:
        case MacWSInputKindScroll:
        case MacWSInputKindConfigureWindow:
        case MacWSInputKindCloseWindow:
            return 0; // control-plane only; handled before event construction
    }
    return 0;
}

// A stationary Host/VNC click has to satisfy two different, legitimate AppKit
// consumers.  NSControl/NSMenu can enter a nested tracker while handling down,
// so up must already be in NSApplication's queue.  Electron content controls,
// on the other hand, return from down without starting that tracker and this
// launchd-created application session does not necessarily pump the queued up
// afterwards.  Runtime evidence from VSCode PID 41954 showed the latter case:
// sendEvent(type=1) returned in 0.261 ms and no sendEvent(type=2) followed.
//
// Query the real AppKit queue for the exact prequeued up after down returns. If
// a nested tracker consumed it, the nonblocking query returns nil. Otherwise,
// remove and dispatch that same NSEvent immediately. eventNumber is unique in
// this process and prevents an unrelated release from being stolen. This keeps
// one coherent down/up pair for both consumers without app-specific actions or
// timing heuristics.
static void MacWSCompletePrequeuedAtomicUp(id application, id expectedEvent,
                                           NSUInteger upType) {
    if (!application || !expectedEvent || upType >= sizeof(NSUInteger) * 8)
        return;
    SEL nextSelector = sel_registerName(
        "nextEventMatchingMask:untilDate:inMode:dequeue:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            nextSelector)) return;

    Class dateClass = objc_getClass("NSDate");
    Class runLoopClass = objc_getClass("NSRunLoop");
    id deadline = dateClass ? ((MacWSMsgID)objc_msgSend)(
        (id)dateClass, sel_registerName("distantPast")) : nil;
    id runLoop = runLoopClass ? ((MacWSMsgID)objc_msgSend)(
        (id)runLoopClass, sel_registerName("currentRunLoop")) : nil;
    id mode = runLoop ? ((MacWSMsgID)objc_msgSend)(
        runLoop, sel_registerName("currentMode")) : nil;
    if (!mode) {
        id *defaultMode = (id *)dlsym(RTLD_DEFAULT, "NSDefaultRunLoopMode");
        if (defaultMode) mode = *defaultMode;
    }
    if (!mode) mode = MacWSRuntimeString("kCFRunLoopDefaultMode");
    if (!deadline || !mode) return;

    id queuedEvent = ((MacWSNextEvent)objc_msgSend)(
        application, nextSelector, ((NSUInteger)1 << upType), deadline, mode,
        YES);
    if (!queuedEvent) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT ATOMIC-UP pid=%d type=%lu route=tracker-consumed\n",
                getpid(), (unsigned long)upType);
            fflush(stderr);
        }
        return;
    }

    NSInteger expectedNumber = ((MacWSMsgInteger)objc_msgSend)(
        expectedEvent, sel_registerName("eventNumber"));
    NSInteger queuedNumber = ((MacWSMsgInteger)objc_msgSend)(
        queuedEvent, sel_registerName("eventNumber"));
    if (queuedNumber != expectedNumber) {
        // The exact event was already consumed and an older same-button release
        // was the next match. Preserve that unrelated event at the queue head.
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), queuedEvent, YES);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT ATOMIC-UP pid=%d type=%lu "
                "route=unrelated-preserved expected=%ld actual=%ld\n",
                getpid(), (unsigned long)upType, (long)expectedNumber,
                (long)queuedNumber);
            fflush(stderr);
        }
        return;
    }

    ((MacWSSendEvent)objc_msgSend)(application,
        sel_registerName("sendEvent:"), queuedEvent);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT ATOMIC-UP pid=%d type=%lu "
            "route=queue-drain event=%ld\n",
            getpid(), (unsigned long)upType, (long)queuedNumber);
        fflush(stderr);
    }
}

// RE-confirmed against the macOS 13.4 AppKit binary loaded in VSCode on
// 2026-07-29. -[NSMenuPresentationInstance _doMenuEventLoop:inMode:] calls
// -[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:] at +0x13c,
// then passes that dequeued NSEvent to -handleEvent: at +0x250.  It does not
// route menu-tracking events through -[NSApplication sendEvent:].  Therefore
// an AppInput hover must enter NSApplication's real queue while a menu owns
// the nested tracker; synchronously calling sendEvent: cannot reach it.
static void MacWSMenuEventLoopWitness(id self, SEL command, BOOL track,
                                      id mode) {
    id previous = MacWSAppInputTrackingMenuPresentation;
    MacWSAppInputTrackingMenuPresentation = self;
    // This is the authoritative AppKit nested-event-loop boundary. Electron
    // can schedule a native menu after the originating leftMouseDown has
    // already returned, so button-specific prediction cannot cover it. Keep
    // the socket-side direct queue route active for the exact lifetime of
    // _doMenuEventLoop: itself; the cached transform still comes from the
    // real preceding target-window click.
    BOOL previousSynchronousTracking = atomic_exchange_explicit(
        &MacWSAppInputSynchronousTrackingActive, YES,
        memory_order_acq_rel);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-BEGIN pid=%d presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    MacWSMenuEventLoop original = NULL;
    for (Class candidate = object_getClass(self); candidate && !original;
         candidate = class_getSuperclass(candidate)) {
        for (size_t index = 0; index < MacWSMenuEventLoopHookCount;
             index++) {
            if (MacWSMenuEventLoopHooks[index].ownerClass == candidate) {
                original = MacWSMenuEventLoopHooks[index].original;
                break;
            }
        }
    }
    if (original) original(self, command, track, mode);
    else {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-DROP pid=%d reason=no-original "
                "presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-END pid=%d presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    MacWSAppInputTrackingMenuPresentation = previous;
    atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive,
                          previousSynchronousTracking,
                          memory_order_release);
}

static void MacWSInstallMenuEventLoopWitness(void) {
    SEL selector = sel_registerName("_doMenuEventLoop:inMode:");
    Class baseClass = objc_getClass("NSMenuPresentationInstance");
    int classCount = objc_getClassList(NULL, 0);
    Class *classes = classCount > 0
        ? calloc((size_t)classCount, sizeof(Class)) : NULL;
    if (!baseClass || !classes ||
        objc_getClassList(classes, classCount) <= 0) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-WITNESS unavailable "
                "base=%s classes=%d\n",
                baseClass ? "YES" : "NO", classCount);
        fflush(stderr);
        free(classes);
        return;
    }

    for (int classIndex = 0; classIndex < classCount &&
         MacWSMenuEventLoopHookCount < 32; classIndex++) {
        Class candidate = classes[classIndex];
        BOOL isPresentationClass = NO;
        for (Class superclass = candidate; superclass;
             superclass = class_getSuperclass(superclass)) {
            if (superclass == baseClass) {
                isPresentationClass = YES;
                break;
            }
        }
        if (!isPresentationClass) continue;

        unsigned methodCount = 0;
        Method *methods = class_copyMethodList(candidate, &methodCount);
        Method directMethod = NULL;
        for (unsigned methodIndex = 0; methodIndex < methodCount;
             methodIndex++) {
            if (method_getName(methods[methodIndex]) == selector) {
                directMethod = methods[methodIndex];
                break;
            }
        }
        free(methods);
        if (!directMethod) continue;

        const char *types = method_getTypeEncoding(directMethod);
        // Runtime-confirmed on macOS 13.4 as v28@0:8B16@20: void return,
        // BOOL, object. Keep this a load-bearing witness rather than
        // installing a guessed calling convention on another AppKit build.
        if (!types || strcmp(types, "v28@0:8B16@20") != 0) {
            fprintf(stderr,
                    "#### APP-INPUT MENU-TRACK-WITNESS skip class=%s "
                    "types=%s\n",
                    class_getName(candidate), types ?: "nil");
            fflush(stderr);
            continue;
        }
        IMP implementation = method_getImplementation(directMethod);
        if (implementation == (IMP)MacWSMenuEventLoopWitness) continue;
        MacWSMenuEventLoopHooks[MacWSMenuEventLoopHookCount++] =
            (MacWSMenuEventLoopHook){
                .ownerClass = candidate,
                .original = (MacWSMenuEventLoop)implementation,
            };
        method_setImplementation(directMethod,
                                 (IMP)MacWSMenuEventLoopWitness);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                    "#### APP-INPUT MENU-TRACK-WITNESS hook class=%s types=%s\n",
                    class_getName(candidate), types);
            fflush(stderr);
        }
    }
    free(classes);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-WITNESS installed hooks=%zu\n",
                MacWSMenuEventLoopHookCount);
        fflush(stderr);
    }
}

static id MacWSActiveMenuPresentationInstance(void) {
    if (MacWSAppInputTrackingMenuPresentation)
        return MacWSAppInputTrackingMenuPresentation;

    Class menuPresentationClass =
        objc_getClass("NSMenuPresentationInstance");
    SEL activeSelector =
        sel_registerName("activeMenuPresentationInstance");
    if (menuPresentationClass && class_respondsToSelector(
            object_getClass(menuPresentationClass), activeSelector)) {
        id active = ((MacWSMsgID)objc_msgSend)(
            (id)menuPresentationClass, activeSelector);
        if (active) return active;
    }

    // macOS 13's menu bar uses a long-lived presentation subclass. Runtime
    // evidence on VSCode showed a visible File menu while the base class's
    // weak activeMenuPresentationInstance and NSApp.orderedWindows were both
    // empty of menu state. AppKit exposes the actual active bar through this
    // class method; require its own tracking flag so ordinary content hover
    // keeps the synchronous non-menu route.
    Class menuBarClass = objc_getClass("NSMenuBarPresentationInstance");
    SEL getActiveBar = sel_registerName("_getActiveMenuBar");
    if (!menuBarClass || !class_respondsToSelector(
            object_getClass(menuBarClass), getActiveBar)) return nil;
    id activeBar = ((MacWSMsgID)objc_msgSend)(
        (id)menuBarClass, getActiveBar);
    SEL handlingSelector = sel_registerName("isActivelyHandlingEvents");
    if (!activeBar || !((MacWSMsgBoolSEL)objc_msgSend)(
            activeBar, sel_registerName("respondsToSelector:"),
            handlingSelector)) return nil;
    return ((MacWSMsgBool)objc_msgSend)(activeBar, handlingSelector)
        ? activeBar : nil;
}

static id MacWSMenuBarPresentationInstance(void) {
    Class menuBarClass = objc_getClass("NSMenuBarPresentationInstance");
    SEL getActiveBar = sel_registerName("_getActiveMenuBar");
    if (!menuBarClass || !class_respondsToSelector(
            object_getClass(menuBarClass), getActiveBar)) return nil;
    return ((MacWSMsgID)objc_msgSend)((id)menuBarClass, getActiveBar);
}

static void MacWSOrderOutObservedMenuWindow(id application,
                                             NSInteger windowNumber) {
    if (!application || windowNumber <= 0) return;
    CFTypeRef retainedApplication = CFRetain((__bridge CFTypeRef)application);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            id app = (__bridge id)retainedApplication;
            (void)app;
            Class managerClass = objc_getClass("NSMenuWindowManager");
            SEL managerForWindow = sel_registerName("managerForWindowID:");
            id manager = managerClass && class_respondsToSelector(
                    object_getClass(managerClass), managerForWindow)
                ? ((MacWSMsgIDInteger)objc_msgSend)(
                    (id)managerClass, managerForWindow, windowNumber)
                : nil;
            SEL orderOut = sel_registerName("orderOut");
            BOOL canOrderOut = manager &&
                ((MacWSMsgBoolSEL)objc_msgSend)(
                    manager, sel_registerName("respondsToSelector:"),
                    orderOut);
            if (canOrderOut)
                ((MacWSMsgVoid)objc_msgSend)(manager, orderOut);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-MENU-UPDATE pid=%d "
                    "window=%ld manager=%s route=%s\n",
                    getpid(), (long)windowNumber,
                    manager ? object_getClassName(manager) : "nil",
                    canOrderOut ? "native-manager-order-out" : "no-manager");
                fflush(stderr);
            }
            CFRelease(retainedApplication);
        });
}

// RE-confirmed against macOS 13.4 HIToolbox on 2026-07-29:
// _CancelMenuTracking(immediate) supplies dismissal reason 8 and tail-calls
// _CancelMenuTracking2. That function reads HIToolbox's active tracking
// session, obtains its actual root MenuRef, and calls CancelMenuTracking.
// CancelMenuTracking marks the session cancelled and invokes QuitEventLoop,
// which is the native termination path for TrackMenuCommon. Schedule it on
// the main CFRunLoop because the API is explicitly not thread-safe and the
// AppInput Escape record normally arrives on the per-app socket thread.
static BOOL MacWSCancelCarbonMenuTrackingForEscape(id application,
                                                    NSInteger windowNumber) {
    static MacWSCancelMenuTrackingPrivate cancelMenuTracking;
    static dispatch_once_t cancelOnce;
    dispatch_once(&cancelOnce, ^{
        cancelMenuTracking = (MacWSCancelMenuTrackingPrivate)dlsym(
            RTLD_DEFAULT, "_CancelMenuTracking");
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT CARBON-MENU-CANCEL resolve=%p\n",
                (void *)cancelMenuTracking);
            fflush(stderr);
        }
    });
    if (!cancelMenuTracking) return NO;

    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (!mainRunLoop) return NO;
    CFRetain(mainRunLoop);
    CFTypeRef retainedApplication = application
        ? CFRetain((__bridge CFTypeRef)application) : NULL;
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        int32_t status = cancelMenuTracking(1);
        id app = retainedApplication ? (__bridge id)retainedApplication : nil;
        MacWSOrderOutObservedMenuWindow(app, windowNumber);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT CARBON-MENU-CANCEL pid=%d window=%ld "
                "immediate=YES status=%d route=hitoolbox-active-tracker\n",
                getpid(), (long)windowNumber, status);
            fflush(stderr);
        }
        if (retainedApplication) CFRelease(retainedApplication);
        CFRelease(mainRunLoop);
    });
    CFRunLoopWakeUp(mainRunLoop);
    return YES;
}

// RE-confirmed against macOS 13.4 AppKit on 2026-07-29:
// -[NSMenuPresentationInstance _closeRootImplAnimated:] does not mutate menu
// state on its caller's thread. It retains self weakly, uses
// CFRunLoopPerformBlock on CFRunLoopGetMain, wakes the main loop when needed,
// and its block loads the root impl at presentation+0x8 and sends
// dismissAnimated:. This is AppKit's own cross-thread handoff into the full
// dismissal lifecycle (end notification, background-event cleanup, monitor
// teardown and timer invalidation), not a forced visibility/state setter.
static BOOL MacWSCancelActiveMenuForEscape(id application,
                                            NSInteger windowNumber,
                                            BOOL menuSurface) {
    // Context menus are tracked synchronously by NSCarbonMenuImpl. Hiding the
    // NSMenuWindowManager surface alone leaves rightMouseDown blocked inside
    // HIToolbox TrackMenuCommon, so subsequent clicks never reach AppKit.
    // Prefer HIToolbox's own active-session cancellation whenever the target
    // probe observed an exact NSMenuWindowManagerWindow.
    BOOL secondaryTracker = atomic_load_explicit(
        &MacWSAppInputSynchronousTrackingActive, memory_order_acquire);
    if ((menuSurface || secondaryTracker) &&
        MacWSCancelCarbonMenuTrackingForEscape(
            application, menuSurface ? windowNumber : 0)) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT KEY-MENU-CANCEL pid=%d window=%ld "
                "source=%s route=hitoolbox-active-tracker\n",
                getpid(), (long)windowNumber,
                menuSurface ? "menu-window" : "secondary-tracker");
            fflush(stderr);
        }
        return YES;
    }

    id presentation = MacWSActiveMenuPresentationInstance();
    const char *source = "active";
    // Runtime target probes can still see the owned NS*Menu*Window while this
    // chroot's Carbon tracker leaves isActivelyHandlingEvents false. In that
    // state +activeMenuPresentationInstance is nil, but the long-lived menu
    // bar presentation is the owner of the visible root submenu. Restrict
    // this fallback to an AppKit menu-class window observed on the main thread;
    // ordinary document/panel key events never take it.
    if (!presentation && menuSurface) {
        presentation = MacWSMenuBarPresentationInstance();
        source = "menu-window";
    }
    if (!presentation) return NO;
    SEL closeRoot = sel_registerName("_closeRootImplAnimated:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            presentation, sel_registerName("respondsToSelector:"),
            closeRoot)) return NO;
    // Runtime-confirmed on the coexist AGX stack: animated=YES ends the menu
    // tracker (Terminal CPU drops from ~69% to idle) but the fade never
    // publishes its terminal frame; the old menu pixels remain until a later
    // click. AppKit ships cancelTrackingWithoutAnimation, whose macOS 13.4
    // implementation passes NO to the same cancellation family. Use that
    // native no-animation semantic for this VNC Escape route.
    ((MacWSMsgVoidBool)objc_msgSend)(presentation, closeRoot, NO);
    // Runtime-confirmed on the coexist AGX/VNC stack on 2026-07-29: the
    // semantic close above ends tracking but does not publish replacement
    // pixels for the ordered menu surface.  A/B runs with animated close,
    // no-animation close, and updateWindows all left the old pixels visible;
    // resolving the exact NSMenuWindowManager for the observed menu window
    // and invoking its native -orderOut closed the menu in 0.300 s and the
    // complete system-menu regression passed 5/5. RE-confirmed in macOS 13.4
    // AppKit, +managerForWindowID: enumerates live managers and matches their
    // real windowID, while -orderOut sends orderOut: to that manager's retained
    // window. Ordinary application windows can never enter this route.
    MacWSOrderOutObservedMenuWindow(application, windowNumber);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT KEY-MENU-CANCEL pid=%d presentation=%s "
            "window=%ld source=%s route=close-root-impl-no-animation\n",
            getpid(), object_getClassName(presentation), (long)windowNumber,
            source);
        fflush(stderr);
    }
    return YES;
}

static BOOL MacWSInputRecordIsValid(const MacWSInputRecord *record) {
    if (record->magic != MACWS_INPUT_MAGIC ||
        record->version != MACWS_INPUT_VERSION ||
        record->targetPID != getpid() ||
        record->frameWidth == 0 || record->frameHeight == 0 ||
        record->source > MacWSInputSourceVNC ||
        !isfinite(record->x) || !isfinite(record->y) ||
        !isfinite(record->altitude) || !isfinite(record->azimuth) ||
        !isfinite(record->tiltX) || !isfinite(record->tiltY) ||
        record->tiltX < -1.0f || record->tiltX > 1.0f ||
        record->tiltY < -1.0f || record->tiltY > 1.0f) return NO;
    if (record->kind == MacWSInputKindConfigureWindow) {
        return MacWSInputWindowIDForScene(record->sceneID) != 0 &&
            record->x >= 64.0f && record->y >= 64.0f &&
            record->x <= MACWS_STREAM_MAX_DIMENSION &&
            record->y <= MACWS_STREAM_MAX_DIMENSION &&
            isfinite(record->pressure) &&
            record->pressure >= 0.5f && record->pressure <= 4.0f;
    }
    if (record->kind == MacWSInputKindCloseWindow) {
        return MacWSInputWindowIDForScene(record->sceneID) != 0;
    }
    if (record->kind == MacWSInputKindScroll) {
        float horizontal = 0.0f;
        memcpy(&horizontal, &record->contactID, sizeof(horizontal));
        if (!isfinite(record->pressure) || !isfinite(horizontal) ||
            fabsf(record->pressure) > 16384.0f ||
            fabsf(horizontal) > 16384.0f) return NO;
    }
    return
        record->version == MACWS_INPUT_VERSION &&
        record->kind >= MacWSInputKindTouchDown &&
        record->kind <= MacWSInputKindScroll &&
        record->x >= 0.0f && record->y >= 0.0f &&
        record->x < record->frameWidth &&
        record->y < record->frameHeight;
}

// Build the wheel event inside the selected AppKit process.  The central
// broker's CGEventPostToPid path is unavailable in this launchd session
// (runtime CGPreflightPostEventAccess=NO), which made two-finger scroll appear
// to be accepted while no target application received it.  A real
// CGEventCreateScrollWheelEvent still provides AppKit's native precise-delta
// fields; wrapping it as NSEvent and putting it on this application's own
// queue avoids the denied cross-process post without inventing a control
// action or changing the target window's state directly.
static id MacWSCreateAppScrollEvent(Class eventClass,
                                    MacWSInputRecord record,
                                    CGPoint windowPoint,
                                    CGRect screenFrame,
                                    NSInteger windowNumber) {
    static MacWSCreateScrollWheelCGEvent createScroll;
    static MacWSCreateScrollWheelCGEvent2 createScroll2;
    static MacWSSetCGEventLocation setLocation;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventTimestamp setTimestamp;
    static MacWSSetCGEventIntegerField setInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createScroll = (MacWSCreateScrollWheelCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateScrollWheelEvent");
        createScroll2 = (MacWSCreateScrollWheelCGEvent2)dlsym(
            RTLD_DEFAULT, "CGEventCreateScrollWheelEvent2");
        setLocation = (MacWSSetCGEventLocation)dlsym(
            RTLD_DEFAULT, "CGEventSetLocation");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || (!createScroll2 && !createScroll) ||
        !class_respondsToSelector(object_getClass(eventClass),
                                  eventWithCGEvent)) return nil;

    float horizontalFloat = 0.0f;
    memcpy(&horizontalFloat, &record.contactID, sizeof(horizontalFloat));
    int32_t vertical = (int32_t)lrintf(record.pressure);
    int32_t horizontal = (int32_t)lrintf(horizontalFloat);
    // The fixed-arity API avoids a cross-image variadic ABI mismatch observed
    // here: the old call produced {deltaX=wheel1, deltaY=wheelCount} instead of
    // {deltaX=wheel2, deltaY=wheel1}. macOS has exported Event2 since 10.13;
    // keep the variadic form only as an older-runtime fallback.
    MacWSCGEventRef cgEvent = createScroll2
        ? createScroll2(NULL, 0 /* kCGScrollEventUnitPixel */, 2,
                        vertical, horizontal, 0)
        : createScroll(NULL, 0 /* kCGScrollEventUnitPixel */, 2,
                       vertical, horizontal);
    if (!cgEvent) return nil;
    if (setTimestamp && record.timestamp > 0.0)
        setTimestamp(cgEvent, (uint64_t)llround(record.timestamp * 1.0e9));
    // eventWithCGEvent: cannot associate a target NSWindow in this chroot even
    // after fields 91/92 are set (runtime windowNumber=0).  NSWindow's public
    // sendEvent: path therefore consumes the event below.  Encode the intended
    // window-local point in the CG wrapper so its locationInWindow is already
    // correct for that target instead of retaining a screen-space offset.
    CGPoint cgWindowPoint = {
        windowPoint.x,
        screenFrame.origin.y + screenFrame.size.height - windowPoint.y,
    };
    if (setLocation) setLocation(cgEvent, cgWindowPoint);
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));
    if (setInteger) {
        uint64_t phase = 0;
        if (record.flags & MacWSInputFlagScrollBegan) phase = 1;
        else if (record.flags & MacWSInputFlagScrollChanged) phase = 4;
        else if (record.flags & MacWSInputFlagScrollEnded) phase = 8;
        else if (record.flags & MacWSInputFlagScrollCancelled) phase = 16;
        setInteger(cgEvent, 88 /* kCGScrollWheelEventIsContinuous */, 1);
        if (record.flags & MacWSInputFlagScrollMomentum) {
            setInteger(cgEvent, 99 /* kCGScrollWheelEventScrollPhase */, 0);
            setInteger(cgEvent, 123 /* ...MomentumPhase */, phase);
        } else {
            setInteger(cgEvent, 99 /* kCGScrollWheelEventScrollPhase */, phase);
            setInteger(cgEvent, 123 /* ...MomentumPhase */, 0);
        }
        if (windowNumber > 0) {
            setInteger(cgEvent, 91 /* kCGMouseEventWindowUnderMousePointer */,
                       windowNumber);
            setInteger(cgEvent,
                       92 /* ...WindowUnderMousePointerThatCanHandleThisEvent */,
                       windowNumber);
        }
    }
    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    return event;
}

// Diagnostic probe: build an ordinary CoreGraphics mouse record inside the
// selected process, attach target-window fields, then wrap it as an NSEvent.
// Runtime InputLab evidence on 2026-07-31 shows macOS 13.4 in this chroot
// discards those fields (windowNumber=0 and screen-space location), so the
// strict equivalence check deliberately rejects it and production does not
// pay this probe's cost. No cross-process/global event post occurs.
static id MacWSCreateAppMouseEvent(Class eventClass,
                                   MacWSInputRecord record,
                                   NSUInteger eventType,
                                   CGPoint screenPoint,
                                   CGPoint expectedWindowPoint,
                                   CGRect screenFrame,
                                   NSInteger windowNumber) {
    static MacWSCreateMouseCGEvent createMouse;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventDoubleField setDouble;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createMouse = (MacWSCreateMouseCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateMouseEvent");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setDouble = (MacWSSetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventSetDoubleValueField");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || !createMouse || !setInteger ||
        !class_respondsToSelector(object_getClass(eventClass),
                                  eventWithCGEvent)) return nil;

    BOOL secondary = eventType == 3 || eventType == 4 || eventType == 7;
    CGPoint cgPoint = {
        screenPoint.x,
        screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
    };
    MacWSCGEventRef cgEvent = createMouse(
        NULL, (uint32_t)eventType, cgPoint, secondary ? 1u : 0u);
    if (!cgEvent) return nil;
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));
    setInteger(cgEvent, 1 /* kCGMouseEventClickState */, 1);
    setInteger(cgEvent, 3 /* kCGMouseEventButtonNumber */,
               secondary ? 1 : 0);
    if (windowNumber > 0) {
        setInteger(cgEvent, 91 /* kCGMouseEventWindowUnderMousePointer */,
                   windowNumber);
        setInteger(cgEvent,
                   92 /* ...WindowUnderMousePointerThatCanHandleThisEvent */,
                   windowNumber);
    }
    if (setDouble && (eventType == 1 || eventType == 3 ||
                      eventType == 6 || eventType == 7)) {
        setDouble(cgEvent, 2 /* kCGMouseEventPressure */,
                  record.pressure > 0.0f ? record.pressure : 1.0f);
    }
    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    if (!event) return nil;
    NSInteger actualWindow = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    CGPoint actualPoint = ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    BOOL equivalent = actualWindow == windowNumber &&
        fabs(actualPoint.x - expectedWindowPoint.x) <= 2.0 &&
        fabs(actualPoint.y - expectedWindowPoint.y) <= 2.0;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT CG-MOUSE pid=%d type=%lu window=%ld->%ld "
            "local=(%.2f,%.2f)->(%.2f,%.2f) equivalent=%s\n",
            getpid(), (unsigned long)eventType, (long)windowNumber,
            (long)actualWindow, expectedWindowPoint.x,
            expectedWindowPoint.y, actualPoint.x, actualPoint.y,
            equivalent ? "YES" : "NO");
        fflush(stderr);
    }
    return equivalent ? event : nil;
}

// Preserve Apple Pencil identity and geometry on the same mouse NSEvent that
// AppKit already uses for hit testing and control tracking. CoreGraphics
// documents mouse subtype 1 as tablet-point and fields 15..24 as tablet
// position/buttons/pressure/tilt/rotation/device ID. This avoids fabricating a
// second event that could reorder against the click while giving drawing apps
// real NSEvent tablet metadata. Runtime validation still needs to confirm which
// target applications consume the subtype under macOS 13.4 in this chroot.
static void MacWSApplyTabletMetadata(id event, MacWSInputRecord record) {
    if (!event || record.source != MacWSInputSourcePencil) return;
    SEL cgEventSelector = sel_registerName("CGEvent");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            event, sel_registerName("respondsToSelector:"), cgEventSelector))
        return;
    MacWSCGEventRef cgEvent = ((MacWSEventRef)objc_msgSend)(
        event, cgEventSelector);
    if (!cgEvent) return;

    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventDoubleField setDouble;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setDouble = (MacWSSetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventSetDoubleValueField");
    });
    if (!setInteger || !setDouble) return;

    BOOL touching = record.kind == MacWSInputKindTouchDown ||
                    record.kind == MacWSInputKindTouchMove ||
                    record.kind == MacWSInputKindTap;
    setInteger(cgEvent, 7 /* kCGMouseEventSubtype */, 1);
    setInteger(cgEvent, 15 /* kCGTabletEventPointX */,
               (int64_t)llround(record.x));
    setInteger(cgEvent, 16 /* kCGTabletEventPointY */,
               (int64_t)llround(record.y));
    setInteger(cgEvent, 17 /* kCGTabletEventPointZ */, 0);
    setInteger(cgEvent, 18 /* kCGTabletEventPointButtons */, touching ? 1 : 0);
    setDouble(cgEvent, 19 /* kCGTabletEventPointPressure */,
              fmax(0.0, fmin(1.0, record.pressure)));
    setDouble(cgEvent, 20 /* kCGTabletEventTiltX */, record.tiltX);
    setDouble(cgEvent, 21 /* kCGTabletEventTiltY */, record.tiltY);
    setDouble(cgEvent, 22 /* kCGTabletEventRotation */, 0.0);
    setDouble(cgEvent, 23 /* kCGTabletEventTangentialPressure */, 0.0);
    setInteger(cgEvent, 24 /* kCGTabletEventDeviceID */,
               record.contactID ? record.contactID : 1);
}

static BOOL MacWSRFBKeySymIsModifier(uint32_t keySym) {
    // XK_Shift_L through XK_Hyper_R, including Caps/Shift lock.
    return keySym >= 0xffe1u && keySym <= 0xffeeu;
}

static uint32_t MacWSFunctionCharacterForRFBKeySym(uint32_t keySym) {
    switch (keySym) {
        case 0xff50: return 0xf729; // Home
        case 0xff51: return 0xf702; // Left
        case 0xff52: return 0xf700; // Up
        case 0xff53: return 0xf703; // Right
        case 0xff54: return 0xf701; // Down
        case 0xff55: return 0xf72c; // Page Up
        case 0xff56: return 0xf72d; // Page Down
        case 0xff57: return 0xf72b; // End
        case 0xff58: return 0xf72a; // Begin
        case 0xff61: return 0xf72e; // Print Screen
        case 0xff63: return 0xf727; // Insert
        case 0xff67: return 0xf735; // Menu
        case 0xff6a: return 0xf746; // Help
        case 0xffff: return 0xf728; // Forward Delete
        default: break;
    }
    if (keySym >= 0xffbeu && keySym <= 0xffe0u)
        return 0xf704u + (keySym - 0xffbeu); // F1 ... F35
    return 0;
}

static NSString *MacWSStringForUnicodeScalar(uint32_t scalar) {
    if (scalar > 0x10ffffu ||
        (scalar >= 0xd800u && scalar <= 0xdfffu))
        return MacWSRuntimeString("");
    unichar characters[2] = {0};
    NSUInteger length = 1;
    if (scalar <= 0xffffu) {
        characters[0] = (unichar)scalar;
    } else {
        scalar -= 0x10000u;
        characters[0] = (unichar)(0xd800u + (scalar >> 10));
        characters[1] = (unichar)(0xdc00u + (scalar & 0x3ffu));
        length = 2;
    }
    return [NSString stringWithCharacters:characters length:length];
}

static NSString *MacWSCharactersForRFBKeySym(uint32_t keySym,
                                              BOOL ignoringModifiers) {
    if (MacWSRFBKeySymIsModifier(keySym)) return MacWSRuntimeString("");
    uint32_t scalar = 0;
    switch (keySym) {
        case 0xff08: scalar = 0x7f; break; // Backspace on macOS
        case 0xff09:
        case 0xfe20: scalar = '\t'; break;
        case 0xff0a: scalar = '\n'; break;
        case 0xff0d:
        case 0xff8d: scalar = '\r'; break;
        case 0xff1b: scalar = 0x1b; break;
        case 0xff80: scalar = ' '; break; // keypad space
        case 0xffaa: scalar = '*'; break;
        case 0xffab: scalar = '+'; break;
        case 0xffad: scalar = '-'; break;
        case 0xffae: scalar = '.'; break;
        case 0xffaf: scalar = '/'; break;
        case 0xffbd: scalar = '='; break;
        default:
            if (keySym >= 0xffb0u && keySym <= 0xffb9u)
                scalar = '0' + (keySym - 0xffb0u);
            else if (keySym >= 0x20u && keySym <= 0xffu)
                scalar = keySym;
            else if ((keySym & 0xff000000u) == 0x01000000u)
                scalar = keySym & 0x00ffffffu;
            else
                scalar = MacWSFunctionCharacterForRFBKeySym(keySym);
            break;
    }
    if (ignoringModifiers) {
        if (scalar >= 'A' && scalar <= 'Z') scalar += 'a' - 'A';
        else {
            static const char shifted[] = "~!@#$%^&*()_+{}|:\"<>?";
            static const char base[] =    "`1234567890-=[]\\;',./";
            const char *match = scalar <= 0x7f
                ? strchr(shifted, (int)scalar) : NULL;
            if (match) scalar = (uint32_t)base[match - shifted];
        }
    }
    return scalar ? MacWSStringForUnicodeScalar(scalar)
                  : MacWSRuntimeString("");
}

static NSString *MacWSCharactersApplyingCapsLock(NSString *characters,
                                                  NSUInteger modifiers) {
    if ((modifiers & 0x10000u) == 0 || characters.length != 1)
        return characters;
    unichar character = [characters characterAtIndex:0];
    if (!((character >= 'a' && character <= 'z') ||
          (character >= 'A' && character <= 'Z'))) return characters;
    BOOL shift = (modifiers & 0x20000u) != 0;
    unichar transformed = shift
        ? (unichar)tolower((int)character)
        : (unichar)toupper((int)character);
    return [NSString stringWithCharacters:&transformed length:1];
}

// RE-confirmed via the installed arm64 OSXvnc-server: its
// sendKeyEvent:down:modifiers: creates a CGEvent, posts it at vncTapLocation,
// then polls CGEventSourceFlagsState every 10 ms for as long as 250 ms.
// Runtime evidence on this coexist stack showed 18 such RFB events consuming
// about 2.1 seconds while the front Terminal received zero NSEvents. Preserve
// OSXvnc's upstream keysym -> keycode/modifier state machine, but put its
// translated result into the selected application's real NSApplication queue.
static BOOL MacWSPostKeyRecord(MacWSInputRecord record, id application,
                               Class eventClass, NSInteger windowNumber,
                               BOOL fromSocketThread, BOOL menuSurface) {
    if (!application || !eventClass ||
        (record.kind != MacWSInputKindKeyDown &&
         record.kind != MacWSInputKindKeyUp) ||
        !isfinite(record.pressure) || record.pressure < 0.0f ||
        record.pressure > UINT16_MAX) return NO;
    uint32_t roundedKeyCode = (uint32_t)llround(record.pressure);
    if (fabs((double)record.pressure - roundedKeyCode) > 0.01) return NO;
    uint32_t keySym = record.contactID;
    if (keySym == 0xff1bu) {
        if (record.kind == MacWSInputKindKeyUp &&
            atomic_exchange_explicit(&MacWSAppInputConsumeEscapeUp, NO,
                                     memory_order_acq_rel)) {
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-MENU-CANCEL pid=%d route=consume-key-up\n",
                    getpid());
                fflush(stderr);
            }
            return YES;
        }
        if (record.kind == MacWSInputKindKeyDown &&
            MacWSCancelActiveMenuForEscape(application, windowNumber,
                                           fromSocketThread && menuSurface)) {
            atomic_store_explicit(&MacWSAppInputConsumeEscapeUp, YES,
                                  memory_order_release);
            // The key-down snapshot remains valid for the asynchronous
            // manager order-out above, but it must not identify this already
            // closed surface as the target of a later unrelated Escape.
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            if (MacWSAppInputMenuContextValid &&
                MacWSAppInputMenuContext.application ==
                    (__bridge CFTypeRef)application &&
                MacWSAppInputMenuContext.windowNumber == windowNumber &&
                MacWSAppInputMenuContext.menuSurface) {
                MacWSAppInputMenuContext.menuSurface = NO;
                MacWSAppInputMenuContext.windowNumber = 0;
            }
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
            return YES;
        }
    }
    NSUInteger modifiers = (NSUInteger)
        MacWSInputModifiersForScene(record.sceneID);
    NSString *characters = MacWSCharactersApplyingCapsLock(
        MacWSCharactersForRFBKeySym(keySym, NO), modifiers);
    NSString *charactersIgnoring =
        MacWSCharactersForRFBKeySym(keySym, YES);
    NSUInteger eventType = record.kind == MacWSInputKindKeyDown ? 10 : 11;
    id event = nil;
    const char *eventRoute = "FACTORY";
    static MacWSCreateKeyboardCGEvent createKeyboardCGEvent;
    static MacWSSetCGEventFlags setCGEventFlags;
    static MacWSSetCGEventTimestamp setCGEventTimestamp;
    static MacWSSetCGEventUnicode setCGEventUnicode;
    static dispatch_once_t cgEventOnce;
    dispatch_once(&cgEventOnce, ^{
        createKeyboardCGEvent = (MacWSCreateKeyboardCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateKeyboardEvent");
        setCGEventFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setCGEventTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setCGEventUnicode = (MacWSSetCGEventUnicode)dlsym(
            RTLD_DEFAULT, "CGEventKeyboardSetUnicodeString");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    // Runtime-confirmed with LLDB at _NSHLTBMenuEventProc+0x134: a long-lived
    // session had an unbounded stream of NSEventTypeKeyDown records (type 10),
    // and x21 == 1 proved the tracker was dequeuing rather than peeking them.
    // The exact originating key is not yet proven.  Keep the CG-backed route
    // required by ordinary text, but do not attach Escape menu-control events
    // to a CG keyboard source.  The clean factory-event A/B delivered exactly
    // one down/up pair and left Terminal at 0% CPU after menu cancellation.
    BOOL canWrapCGEvent = keySym != 0xff1bu &&
        createKeyboardCGEvent && setCGEventFlags &&
        class_respondsToSelector(object_getClass(eventClass),
                                 eventWithCGEvent);
    if (canWrapCGEvent) {
        MacWSCGEventRef cgEvent = createKeyboardCGEvent(
            NULL, (unsigned short)roundedKeyCode,
            record.kind == MacWSInputKindKeyDown);
        if (cgEvent) {
            setCGEventFlags(cgEvent, modifiers);
            if (setCGEventTimestamp && record.timestamp > 0.0)
                setCGEventTimestamp(cgEvent,
                    (uint64_t)llround(record.timestamp * 1.0e9));
            NSUInteger characterCount = [characters length];
            if (setCGEventUnicode && characterCount > 0 &&
                characterCount <= 8) {
                unichar unicode[8] = {0};
                [characters getCharacters:unicode
                                    range:NSMakeRange(0, characterCount)];
                setCGEventUnicode(cgEvent, characterCount, unicode);
            }
            event = ((MacWSEventFromCGEvent)objc_msgSend)(
                (id)eventClass, eventWithCGEvent, cgEvent);
            CFRelease(cgEvent);
            if (event) eventRoute = "CG-WRAP";
        }
    }
    if (!event) {
        event = ((MacWSKeyEventFactory)objc_msgSend)(
            (id)eventClass,
            sel_registerName("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
            eventType, (CGPoint){0.0, 0.0}, modifiers, record.timestamp,
            windowNumber, nil, characters, charactersIgnoring, NO,
            (unsigned short)roundedKeyCode);
    }
    if (!event) return NO;
    if (fromSocketThread) {
        // Escape-down must be visible to the active nested NSMenu loop even
        // when Chromium has older unrelated events queued. Its matching up is
        // appended, so the pair cannot reverse. Ordinary typing remains FIFO.
        BOOL atStart = record.kind == MacWSInputKindKeyDown &&
                       keySym == 0xff1bu;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, atStart);
    } else {
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        const void *eventRef = ((MacWSMsgBoolSEL)objc_msgSend)(
                event, sel_registerName("respondsToSelector:"),
                sel_registerName("_eventRef"))
            ? ((MacWSEventRef)objc_msgSend)(
                event, sel_registerName("_eventRef")) : NULL;
        fprintf(stderr,
            "#### APP-INPUT KEY-POST pid=%d kind=%u keycode=%u keysym=%#x "
            "modifiers=%#lx window=%ld route=%s delivery=%s event-ref=%p "
            "chars-length=%lu\n",
            getpid(), record.kind, roundedKeyCode, keySym,
            (unsigned long)modifiers, (long)windowNumber,
            fromSocketThread ? "QUEUE" : "MAIN-SEND",
            eventRoute, eventRef,
            (unsigned long)[characters length]);
        fflush(stderr);
    }
    return YES;
}

// The route lock closes the only dangerous transition: a socket record either
// enters MacWSAppInputPending before the main thread arms live tracking (and is
// visible to its fallback check), or snapshots the armed context and is posted
// directly. It cannot fall between those two states.
static BOOL MacWSPrepareDirectTrackingPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    BOOL isTrackingRecord = record.kind == MacWSInputKindTouchMove ||
        record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel;
    // The context is armed only after this endpoint accepted the matching
    // down. Window-Scene pointer drags need the same socket-thread posting as
    // RFB: AppKit's synchronous control tracker owns the main thread until it
    // receives move/up from NSApplication's event queue.
    if (!isTrackingRecord ||
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
            MacWSApplyTabletMetadata(event, record);
            // Apple documents that events posted from subthreads enter the
            // main-thread event queue.  A Carbon system menu consumes that
            // queue from _NSHLTBMenuEventProc while Electron can continue to
            // append unrelated application events behind the tracker.  A
            // menu hover is a replaceable current-position sample, so put it
            // at the queue head; otherwise it can remain behind Chromium's
            // traffic until after the menu closes.  Gesture move/up records
            // keep FIFO tail ordering because their chronology is semantic.
            BOOL atStart = record.kind == MacWSInputKindMenuHover ||
                (record.kind == MacWSInputKindHover &&
                 atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                                      memory_order_acquire));
            ((MacWSPostEvent)objc_msgSend)(
                (__bridge id)snapshot.application,
                sel_registerName("postEvent:atStart:"), event, atStart);
            // MenuHover is a 60/120-Hz stream just like a live drag.  The old
            // condition treated every menu sample as a transition and forced
            // one synchronous stderr write from this socket thread per event,
            // in addition to the RX log below.  Sample continuous traffic;
            // keep every semantic button/key transition fully logged.
            if (MacWSRuntimeDiagnosticsEnabled()) {
                BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                                  record.kind == MacWSInputKindMenuHover;
                static _Atomic uint64_t continuousPostLogs;
                uint64_t continuousPost = continuous
                    ? atomic_fetch_add_explicit(&continuousPostLogs, 1,
                                                memory_order_relaxed) + 1
                    : 0;
                if (!continuous || continuousPost <= 12 ||
                    (continuousPost % 600) == 0) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-POST pid=%d kind=%u gesture=%u "
                    "window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                    getpid(), record.kind, record.contactID,
                    (long)snapshot.windowNumber, screenPoint.x, screenPoint.y,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
                }
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

static void MacWSPostDirectMenuTapRecord(
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
        id downEvent = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            1 /* NSEventTypeLeftMouseDown */, windowPoint, 0,
            record.timestamp, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, 1.0f);
        id upEvent = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            2 /* NSEventTypeLeftMouseUp */, windowPoint, 0,
            record.timestamp + 0.001, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, 0.0f);
        if (downEvent && upEvent) {
            MacWSApplyTabletMetadata(downEvent, record);
            MacWSInputRecord upRecord = record;
            upRecord.kind = MacWSInputKindTouchUp;
            upRecord.pressure = 0.0f;
            MacWSApplyTabletMetadata(upEvent, upRecord);
            // atStart is a stack. Push up first so the tracker dequeues the
            // complete gesture in down -> up order.
            id application = (__bridge id)snapshot.application;
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), upEvent, YES);
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), downEvent, YES);
            MacWSNotifyDisplayCatalogChanged('t');
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT MENU-TAP-QUEUE pid=%d gesture=%u "
                    "window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                    getpid(), record.contactID, (long)snapshot.windowNumber,
                    screenPoint.x, screenPoint.y,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
            }
        } else {
            fprintf(stderr,
                "#### APP-INPUT LIVE-DROP pid=%d kind=%u gesture=%u "
                "reason=menu-tap-event-create\n",
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
    Class windowClass = objc_getClass("NSWindow");
    SEL globalHitSelector = sel_registerName(
        "windowNumberAtPoint:belowWindowWithWindowNumber:");
    NSInteger globalWindowNumber = 0;
    if (windowClass && class_respondsToSelector(
            object_getClass(windowClass), globalHitSelector)) {
        globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
            (id)windowClass, globalHitSelector, screenPoint, 0);
    }
    SEL applicationWindowSelector =
        sel_registerName("windowWithWindowNumber:");
    if (globalWindowNumber > 0 && ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            applicationWindowSelector)) {
        id globalWindow = ((MacWSMsgIDInteger)objc_msgSend)(
            application, applicationWindowSelector, globalWindowNumber);
        if (!globalWindow) {
            for (id candidate in [MacWSOrderedWindowRegistry allObjects]) {
                NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("windowNumber"));
                if (number == globalWindowNumber) {
                    globalWindow = candidate;
                    break;
                }
            }
        }
        if (globalWindow) {
            static unsigned transientWindowLogs;
            if (MacWSRuntimeDiagnosticsEnabled() &&
                transientWindowLogs++ < 24) {
                CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                    globalWindow, frameSelector);
                fprintf(stderr,
                    "#### APP-INPUT GLOBAL-WINDOW pid=%d number=%ld "
                    "class=%s frame=(%.1f,%.1f %.1fx%.1f)\n",
                    getpid(), (long)globalWindowNumber,
                    object_getClassName(globalWindow),
                    frame.origin.x, frame.origin.y,
                    frame.size.width, frame.size.height);
                fflush(stderr);
            }
            return globalWindow;
        }
    }
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
    id trackedHit = nil;
    NSInteger trackedLevel = NSIntegerMin;
    for (id candidate in [MacWSOrderedWindowRegistry allObjects]) {
        BOOL visible = ((MacWSMsgBool)objc_msgSend)(
            candidate, sel_registerName("isVisible"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            candidate, frameSelector);
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            candidate, sel_registerName("level"));
        if (visible && MacWSPointInRect(screenPoint, frame) &&
            (!trackedHit || level > trackedLevel)) {
            trackedHit = candidate;
            trackedLevel = level;
        }
    }
    if (trackedHit) return trackedHit;
    return keyWindow ?: ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("mainWindow"));
}

static id MacWSWindowWithNumber(id application, uint32_t windowNumber) {
    if (!application || windowNumber == 0) return nil;
    SEL selector = sel_registerName("windowWithWindowNumber:");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"), selector)) {
        id window = ((MacWSMsgIDInteger)objc_msgSend)(
            application, selector, (NSInteger)windowNumber);
        if (window) return window;
    }
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    for (id window in windows) {
        NSInteger candidate = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (candidate == (NSInteger)windowNumber) return window;
    }
    for (id window in [MacWSOrderedWindowRegistry allObjects]) {
        NSInteger candidate = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (candidate == (NSInteger)windowNumber) return window;
    }
    return nil;
}

// Return the frontmost real popup-menu-level window that is visible but does
// not contain this click. CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) is
// the public source of the level value; no application/class name participates
// in popup discovery. Runtime-confirmed in VSCode: its Views popup is level 101
// and a later AppKit menu is an NSMenuWindowManagerWindow at the same level.
static id MacWSOutsidePopupWindow(id application, id baseWindow,
                                  CGPoint screenPoint) {
    static MacWSCGWindowLevelForKey levelForKey;
    static NSInteger popupLevel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        levelForKey = (MacWSCGWindowLevelForKey)dlsym(
            RTLD_DEFAULT, "CGWindowLevelForKey");
        if (!levelForKey) {
            // libmachook itself deliberately has no CoreGraphics link. Under
            // the chroot's dyld shared cache, an AppKit dependency is not
            // guaranteed to place every re-export in RTLD_DEFAULT even though
            // the framework is loaded. Resolve from the framework handle just
            // as native callers linked against CoreGraphics do.
            void *coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL);
            if (coreGraphics) {
                levelForKey = (MacWSCGWindowLevelForKey)dlsym(
                    coreGraphics, "CGWindowLevelForKey");
            }
        }
        // CGWindowLevelKey is zero-based and the popup-menu key is 11.
        // Runtime probe against this macOS 13.4 CoreGraphics returned
        // key 10 -> 8 (modal), key 11 -> 101 (popup), key 12 -> 500
        // (dragging).  Using 12 here silently searched for drag images and
        // therefore missed every real NSMenuWindowManagerWindow.
        popupLevel = levelForKey
            ? levelForKey(11 /* kCGPopUpMenuWindowLevelKey */) : NSIntegerMax;
    });
    if (!application || !baseWindow || popupLevel == NSIntegerMax) return nil;
    id orderedWindows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("orderedWindows"));
    id applicationWindows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    // NSApplication's orderedWindows intentionally omits some transient menu
    // windows. Runtime evidence in VSCode showed a live layer-101 window in
    // CGWindowList and windowWithWindowNumber:, while orderedWindows.count was
    // exactly one (the document). NSApplication.windows owns those auxiliary
    // objects, so scan the stable union without guessing an application or
    // private window class.
    NSMutableOrderedSet *windowSet = [NSMutableOrderedSet orderedSet];
    if (orderedWindows) [windowSet addObjectsFromArray:orderedWindows];
    if (applicationWindows) [windowSet addObjectsFromArray:applicationWindows];
    NSArray *trackedWindows = [MacWSOrderedWindowRegistry allObjects];
    if (trackedWindows) [windowSet addObjectsFromArray:trackedWindows];
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT POPUP-SCAN pid=%d api=%p level=%ld ordered=%lu "
            "all=%lu tracked=%lu unique=%lu point=(%.1f,%.1f)\n",
            getpid(), levelForKey, (long)popupLevel,
            (unsigned long)[orderedWindows count],
            (unsigned long)[applicationWindows count],
            (unsigned long)[trackedWindows count],
            (unsigned long)[windowSet count], screenPoint.x, screenPoint.y);
    }
    for (id candidate in windowSet) {
        if (candidate == baseWindow || !((MacWSMsgBool)objc_msgSend)(
                candidate, sel_registerName("isVisible"))) continue;
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            candidate, sel_registerName("level"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            candidate, sel_registerName("frame"));
        if (MacWSRuntimeDiagnosticsEnabled() && level > 0) {
            fprintf(stderr,
                "#### APP-INPUT POPUP-CANDIDATE pid=%d number=%ld class=%s "
                "level=%ld frame=(%.1f,%.1f %.1fx%.1f)\n",
                getpid(),
                (long)((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("windowNumber")),
                object_getClassName(candidate), (long)level,
                frame.origin.x, frame.origin.y,
                frame.size.width, frame.size.height);
        }
        if (level == popupLevel && !MacWSPointInRect(screenPoint, frame))
            return candidate;
    }
    return nil;
}

static CGSize MacWSEffectiveMinimumFrameSize(id window, CGRect frame,
                                              BOOL *resizableOut) {
    NSUInteger styleMask = ((MacWSMsgUInteger)objc_msgSend)(
        window, sel_registerName("styleMask"));
    BOOL resizable = (styleMask & (1u << 3)) != 0;
    if (resizableOut) *resizableOut = resizable;
    if (!resizable) return frame.size;

    CGSize frameMinimum = {0};
    CGSize contentMinimum = {0};
    SEL minSizeSelector = sel_registerName("minSize");
    SEL contentMinSelector = sel_registerName("contentMinSize");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), minSizeSelector))
        frameMinimum = ((MacWSMsgSize)objc_msgSend)(window,
                                                      minSizeSelector);
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), contentMinSelector))
        contentMinimum = ((MacWSMsgSize)objc_msgSend)(window,
                                                       contentMinSelector);
    CGRect contentRect = frame;
    SEL contentRectSelector = sel_registerName("contentRectForFrameRect:");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"),
            contentRectSelector)) {
        contentRect = ((MacWSMsgRectRect)objc_msgSend)(
            window, contentRectSelector, frame);
    }
    CGFloat width = fmax(frameMinimum.width,
        contentMinimum.width + fmax(0.0,
            frame.size.width - contentRect.size.width));
    CGFloat height = fmax(frameMinimum.height,
        contentMinimum.height + fmax(0.0,
            frame.size.height - contentRect.size.height));
    if (!isfinite(width) || width < 0.0 ||
        width > MACWS_STREAM_MAX_DIMENSION) width = 0.0;
    if (!isfinite(height) || height < 0.0 ||
        height > MACWS_STREAM_MAX_DIMENSION) height = 0.0;
    return (CGSize){width, height};
}

// Complete the real AppKit lifecycle when CGS deactivation succeeded but the
// chroot never delivered its corresponding Workspace event.  On-device LLDB
// disassembly of macOS 13.4 proves this handler does not read x2/the event
// argument; it performs the complete notification, active-bit, key/main, and
// window refresh transaction that is otherwise missing here.
static BOOL MacWSDeliverMissingDeactivateEvent(id application) {
    if (!application || !((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) return NO;
    SEL handlerSelector = sel_registerName("_handleDeactivateEvent:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            handlerSelector)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(
        application, handlerSelector, nil);
    return YES;
}

// RE-confirmed on-device against HIToolbox 13.4:
// HIApplication::HandleActivated(event, active=false, ...) calls
// IsCurrentProcessMenuBarOwner before deciding between BeginNonActiveMenuBar
// and FrontUILost.  Runtime target replies from Terminal and GlassDemo show
// that both processes simultaneously see their own PSN as the menu-bar owner,
// so the old application takes the former branch even after the broker has
// selected and activated a different process.  FrontUILost is the complete
// upstream false-owner branch: SetMenuBarObscured(1),
// _DeactivateWindowGroups, font-cache
// reset, and EndNonActiveMenuBar.  Execute that real idempotent lifecycle only
// for the non-target applications selected by the system-wide broker.
// HIApplicationGetCurrent/GetApplication returns the HIObject wrapper;
// GetAppObject is the RE-confirmed accessor that loads wrapper+0x10 and returns
// the internal C++ object required as FrontUILost's this pointer.
static void *MacWSResolveHIToolboxLocal(uintptr_t imageOffset,
                                        const uint8_t *expectedPrologue,
                                        size_t expectedPrologueSize) {
    // These routines are present in LLDB's local-symbol view but absent from
    // HIToolbox's export trie.  Use the exact macOS 13.4 image only after both
    // its LC_UUID and the RE-captured function prologue match.  Any other
    // build stays unsupported instead of jumping through an unverified offset.
    static const uint8_t expectedUUID[16] = {
        0xd8, 0x00, 0x27, 0x8b, 0x4e, 0x6c, 0x30, 0x32,
        0xb5, 0x6f, 0x02, 0x7a, 0x93, 0x8a, 0x51, 0xd6,
    };
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !strstr(name, "/HIToolbox.framework/")) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) return NULL;
        const struct load_command *command =
            (const struct load_command *)((const uint8_t *)header +
                                           sizeof(*header));
        BOOL uuidMatches = NO;
        for (uint32_t item = 0; item < header->ncmds; item++) {
            if (command->cmdsize < sizeof(*command)) return NULL;
            if (command->cmd == LC_UUID &&
                command->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *uuid =
                    (const struct uuid_command *)command;
                uuidMatches = memcmp(uuid->uuid, expectedUUID,
                                     sizeof(expectedUUID)) == 0;
                break;
            }
            command = (const struct load_command *)(
                (const uint8_t *)command + command->cmdsize);
        }
        if (!uuidMatches) return NULL;
        const uint8_t *candidate =
            (const uint8_t *)header + imageOffset;
        if (memcmp(candidate, expectedPrologue,
                   expectedPrologueSize) != 0) return NULL;
        return ptrauth_sign_unauthenticated(
            (void *)candidate, ptrauth_key_function_pointer, 0);
    }
    return NULL;
}

static BOOL MacWSCompleteFrontUILostLifecycle(void) {
    static MacWSHIApplicationGetAppObject getAppObject;
    static MacWSHIApplicationFrontUILost frontUILost;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getAppObject = (MacWSHIApplicationGetAppObject)dlsym(
            RTLD_DEFAULT, "_ZN13HIApplication12GetAppObjectEv");
        frontUILost = (MacWSHIApplicationFrontUILost)dlsym(
            RTLD_DEFAULT, "_ZN13HIApplication11FrontUILostEv");
        static const uint8_t getAppObjectPrologue[16] = {
            0x7f, 0x23, 0x03, 0xd5, 0xfd, 0x7b, 0xbf, 0xa9,
            0xfd, 0x03, 0x00, 0x91, 0xef, 0xa7, 0xfe, 0x97,
        };
        static const uint8_t frontUILostPrologue[16] = {
            0x7f, 0x23, 0x03, 0xd5, 0xf4, 0x4f, 0xbe, 0xa9,
            0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91,
        };
        if (!getAppObject) {
            getAppObject = (MacWSHIApplicationGetAppObject)
                MacWSResolveHIToolboxLocal(
                    0x59778, getAppObjectPrologue,
                    sizeof(getAppObjectPrologue));
        }
        if (!frontUILost) {
            frontUILost = (MacWSHIApplicationFrontUILost)
                MacWSResolveHIToolboxLocal(
                    0x4d608, frontUILostPrologue,
                    sizeof(frontUILostPrologue));
        }
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT FRONT-UI-LOST-RESOLVE pid=%d "
                "get-app-object=%p front-ui-lost=%p\n",
                getpid(), getAppObject, frontUILost);
            fflush(stderr);
        }
    });
    if (!getAppObject || !frontUILost) return NO;
    void *application = getAppObject();
    if (!application) return NO;
    frontUILost(application);
    return YES;
}

// AppKit has two main-menu implementations in this build.  The modern
// NSMenuBarImpl clear method is intentionally a no-op, while the compatibility
// NSCarbonMenuImpl clearAsMainCarbonMenuBar tail-calls
// _menuLostMainMenuStatus.  On-device disassembly proves that routine clears
// its main-menu bit, removes linked shortcut menus, and destroys the old
// principal MenuRef.  This is the real counterpart to the target's
// setAsMainCarbonMenuBar -> SetRootMenu transaction.
static const char *MacWSClearMainMenuBar(id application) {
    if (!application) return "NO-APPLICATION";
    id mainMenu = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("mainMenu"));
    if (!mainMenu) return "NO-MENU";
    id implementation = ((MacWSMsgID)objc_msgSend)(
        mainMenu, sel_registerName("_menuImpl"));
    if (!implementation) return "NO-IMPLEMENTATION";
    SEL clearMenuBar = sel_registerName("clearAsMainMenuBar");
    SEL clearCarbonMenuBar =
        sel_registerName("clearAsMainCarbonMenuBar");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            implementation, sel_registerName("respondsToSelector:"),
            clearMenuBar)) {
        ((MacWSMsgVoid)objc_msgSend)(implementation, clearMenuBar);
        return "APPKIT";
    }
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            implementation, sel_registerName("respondsToSelector:"),
            clearCarbonMenuBar)) {
        ((MacWSMsgVoid)objc_msgSend)(
            implementation, clearCarbonMenuBar);
        return "CARBON";
    }
    return "UNAVAILABLE";
}

// RE-confirmed with the project LLDB helper against the exact macOS 13.4
// AppKit image: -_handleActivatedEvent: consumes windowNumber at +376, data1
// at +628, and data2 at +488/+1188.  Its windowNumber==0 branch is deliberate:
// both Terminal and Electron received a real startup activation event with
// window=0/data2=64, and the method proceeds through WillBecomeActive, sets
// NSApplication's active bit at +924/+928, then posts DidBecomeActive.  Do not
// fabricate that object.  The witness above retains the exact system event
// AppKit received in this process.  A recent window-bound event must still
// resolve to one of this application's windows.  The windowless system event
// is accepted only with the runtime-observed data2=64 signature and only from
// this user-triggered ActivateTarget recovery path after isActive stayed false.
static BOOL MacWSDeliverMissingActivateEvent(id application) {
    if (!application || !MacWSOriginalHandleActivatedEvent ||
        !MacWSLastSystemActivationEvent ||
        ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) return NO;
    double age = MacWSAppInputMonotonicSeconds() -
        MacWSLastSystemActivationEventTime;
    if (age < 0.0) return NO;
    id event = (__bridge id)MacWSLastSystemActivationEvent;
    NSInteger eventWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    NSInteger eventData1 = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("data1"));
    NSInteger eventData2 = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("data2"));
    // _handleDeactivateEvent: intentionally clears keyWindow/mainWindow, so
    // keyWindow cannot validate the retained event here.  Match AppKit's own
    // _handleActivatedEvent:+396 validation instead: the event's window
    // number must still resolve inside this NSApplication.
    BOOL windowBoundEvent = eventWindowNumber > 0;
    id eventWindow = windowBoundEvent
        ? ((MacWSMsgIDInteger)objc_msgSend)(
            application, sel_registerName("windowWithWindowNumber:"),
            eventWindowNumber) : nil;
    BOOL recentOwnedWindowEvent = windowBoundEvent && eventWindow && age <= 1.5;
    BOOL authenticWindowlessSystemEvent =
        eventWindowNumber == 0 && eventData2 == 64;
    if (!recentOwnedWindowEvent && !authenticWindowlessSystemEvent) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-ACTIVATE-REPLAY-REJECT pid=%d "
                "age=%.3f window=%ld owned=%s data1=%ld data2=%ld\n",
                getpid(), age, (long)eventWindowNumber,
                eventWindow ? "YES" : "NO", (long)eventData1,
                (long)eventData2);
            fflush(stderr);
        }
        return NO;
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-ACTIVATE-REPLAY pid=%d age=%.3f "
            "window=%ld data1=%ld data2=%ld provenance=%s\n",
            getpid(), age, (long)eventWindowNumber, (long)eventData1,
            (long)eventData2, recentOwnedWindowEvent
                ? "RECENT-OWNED-WINDOW" : "AUTHENTIC-WINDOWLESS-SYSTEM");
        fflush(stderr);
    }
    CFRetain((__bridge CFTypeRef)event);
    MacWSOriginalHandleActivatedEvent(
        application, sel_registerName("_handleActivatedEvent:"), event);
    CFRelease((__bridge CFTypeRef)event);
    return ((MacWSMsgBool)objc_msgSend)(
        application, sel_registerName("isActive"));
}

static void MacWSPostInputOnMainThread(MacWSInputRecord record) {
    BOOL logEvent = MacWSRuntimeDiagnosticsEnabled() &&
        record.kind != MacWSInputKindTouchMove &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindMenuHover;
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

    if (record.kind == MacWSInputKindDeactivateApplication) {
        BOOL before = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        SEL deactivateSelector = sel_registerName("deactivate");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                deactivateSelector)) {
            ((MacWSMsgVoid)objc_msgSend)(application, deactivateSelector);
        }
        BOOL afterPublicDeactivate = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        BOOL repairedMissingEvent = NO;
        if (afterPublicDeactivate) {
            // RE-confirmed via macOS 13.4 AppKit on-device LLDB:
            // -deactivate calls _NXEndKeyAndMain, then only asks
            // CGSDeactivateCurrContext when _NXIsActiveApp is true.  In this
            // chroot no Workspace deactivate event returns, so the
            // application active bit remains set.  The actual downstream
            // -_handleDeactivateEvent: implementation does not read its event
            // argument; it posts WillResign/DidResign notifications, clears
            // the active bit, ends key/main state, and refreshes windows.
            // Deliver that missing lifecycle event only after the public
            // transaction demonstrably failed.  This is not an isActive hook
            // or a constant-return bypass.
            repairedMissingEvent =
                MacWSDeliverMissingDeactivateEvent(application);
        }
        BOOL completedFrontUILost =
            MacWSCompleteFrontUILostLifecycle();
        const char *clearedMainMenuBar =
            MacWSClearMainMenuBar(application);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-DEACTIVATE pid=%d active=%s->%s->%s "
                "missing-event=%s front-ui-lost=%s clear-menu=%s\n",
                getpid(), before ? "YES" : "NO",
                afterPublicDeactivate ? "YES" : "NO",
                ((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive")) ? "YES" : "NO",
                repairedMissingEvent ? "DELIVERED" : "NO",
                completedFrontUILost ? "COMPLETED" : "UNAVAILABLE",
                clearedMainMenuBar);
            fflush(stderr);
        }
        return;
    }
    if (record.kind == MacWSInputKindActivateTarget) {
        BOOL before = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        uint32_t requestedWindowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id requestedWindow = requestedWindowNumber
            ? MacWSWindowWithNumber(application, requestedWindowNumber) : nil;
        BOOL keyedRequestedWindow = NO;
        if (requestedWindow) {
            BOOL visible = ((MacWSMsgBool)objc_msgSend)(
                requestedWindow, sel_registerName("isVisible"));
            BOOL canBecomeKey = ((MacWSMsgBool)objc_msgSend)(
                requestedWindow, sel_registerName("canBecomeKeyWindow"));
            id currentKeyWindow = ((MacWSMsgID)objc_msgSend)(
                application, sel_registerName("keyWindow"));
            if (visible && canBecomeKey && currentKeyWindow != requestedWindow &&
                ((MacWSMsgBoolSEL)objc_msgSend)(requestedWindow,
                    sel_registerName("respondsToSelector:"),
                    sel_registerName("makeKeyWindow"))) {
                // ActivateTarget is explicit user intent from one exact Host
                // Scene.  Select that already-visible AppKit window through
                // the normal key-window transaction, without ordering it or
                // re-entering NSWindowStackController's tab-order path.
                ((MacWSMsgVoid)objc_msgSend)(
                    requestedWindow, sel_registerName("makeKeyWindow"));
                keyedRequestedWindow = ((MacWSMsgID)objc_msgSend)(
                    application, sel_registerName("keyWindow")) ==
                    requestedWindow;
            } else {
                keyedRequestedWindow = currentKeyWindow == requestedWindow;
            }
        }
        BOOL systemMenuPreflight = record.frameHeight > 0 &&
            record.y >= 0.0f &&
            record.y <= (float)record.frameHeight * 0.04f;
        BOOL preflightOwner = NO;
        if (before && systemMenuPreflight) {
            // macwsinputd sends this control before OSXvnc posts the real
            // native menu-bar down.  The app may already be active/front yet
            // its long-lived NSMenuBarPresentationInstance still reflects the
            // root menu installed before the LS menu-owner handoff.  Run the
            // real owner + Carbon SetRootMenu/RecalcBar transaction now so the
            // native down enters a current tracker.  This creates no NSEvent.
            preflightOwner = MacWSRepairFrontUIApplication(
                application, "system-menu-preflight");
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT SYSTEM-MENU-PREFLIGHT pid=%d active=YES "
                    "front-owner=%s native-down=pending\n",
                    getpid(), preflightOwner ? "YES" : "NO");
                fflush(stderr);
            }
        }
        SEL activateSelector = sel_registerName("activateIgnoringOtherApps:");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                activateSelector)) {
            // OSXvnc now sends this control immediately before its native
            // down.  Preserve an already-active target: deactivating and
            // rebuilding it hid its just-installed menu while the chroot was
            // missing the matching second Carbon activation event.
            uint64_t coordinationDelay = before
                ? 20 * NSEC_PER_MSEC : 0;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, coordinationDelay),
                dispatch_get_main_queue(), ^{
                    if (!((MacWSMsgBool)objc_msgSend)(
                            application, sel_registerName("isActive"))) {
                        ((MacWSMsgVoidBool)objc_msgSend)(
                            application, activateSelector, YES);
                    }
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      80 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(), ^{
                            BOOL missingActivationDelivered = NO;
                            if (!((MacWSMsgBool)objc_msgSend)(
                                    application,
                                    sel_registerName("isActive"))) {
                                missingActivationDelivered =
                                    MacWSDeliverMissingActivateEvent(
                                        application);
                            }
                            if (!((MacWSMsgBool)objc_msgSend)(
                                    application,
                                    sel_registerName("isActive"))) {
                                ((MacWSMsgVoidBool)objc_msgSend)(
                                    application, activateSelector, YES);
                            }
                            BOOL ownsFrontUIProcess =
                                MacWSRepairFrontUIApplication(
                                    application, before
                                        ? "native-active" : "direct");
                            if (MacWSRuntimeDiagnosticsEnabled()) {
                                fprintf(stderr,
                                    "#### APP-INPUT SYSTEM-ACTIVATE-SETTLED "
                                    "pid=%d active=%s lifecycle-rebuilt=%s "
                                    "missing-event=%s front-owner=%s\n",
                                    getpid(),
                                    ((MacWSMsgBool)objc_msgSend)(
                                        application,
                                        sel_registerName("isActive"))
                                        ? "YES" : "NO",
                                    "NO",
                                    missingActivationDelivered
                                        ? "DELIVERED" : "NO",
                                    ownsFrontUIProcess ? "YES" : "NO");
                                fflush(stderr);
                            }
                        });
                });
        }
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-ACTIVATE-CONTROL pid=%d active=%s "
                "coordination=%s requested-window=%u keyed=%s\n",
                getpid(), before ? "YES" : "NO",
                before ? "PRESERVE-NATIVE" : "DIRECT",
                requestedWindowNumber,
                keyedRequestedWindow ? "YES" : "NO");
            fflush(stderr);
        }
        return;
    }

    if (record.kind == MacWSInputKindCloseWindow) {
        uint32_t windowNumber = MacWSInputWindowIDForScene(record.sceneID);
        id window = MacWSWindowWithNumber(application, windowNumber);
        SEL performClose = sel_registerName("performClose:");
        if (window && ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                performClose)) {
            ((void (*)(id, SEL, id))objc_msgSend)(window, performClose, nil);
            // performClose: can run delegate validation synchronously, while
            // the final NSApplication.windows mutation lands on the next main
            // loop turn. Publish the committed catalog after that turn so
            // every Host Scene observes the close without a polling delay.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSPublishWindowMetrics();
                MacWSNotifyDisplayCatalogChanged('c');
            });
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT CLOSE-WINDOW pid=%d window=%u\n",
                    getpid(), windowNumber);
                fflush(stderr);
            }
        }
        return;
    }

    if (record.kind == MacWSInputKindConfigureWindow) {
        uint32_t windowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id window = MacWSWindowWithNumber(application, windowNumber);
        if (!window) {
            fprintf(stderr,
                "#### APP-INPUT CONFIGURE-DROP pid=%d reason=no-window "
                "window=%u\n", getpid(), windowNumber);
            fflush(stderr);
            return;
        }
        CGRect oldFrame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        BOOL resizable = NO;
        CGSize minimum = MacWSEffectiveMinimumFrameSize(
            window, oldFrame, &resizable);
        CGSize requested = resizable ? (CGSize){
            fmax(record.x, minimum.width), fmax(record.y, minimum.height),
        } : oldFrame.size;
        CGRect newFrame = oldFrame;
        newFrame.size = requested;
        BOOL anchorTopLeft =
            (record.flags & MacWSInputFlagConfigureAnchorTopLeft) != 0;
        BOOL anchorTopRight =
            (record.flags & MacWSInputFlagConfigureAnchorTopRight) != 0;
        if (anchorTopLeft || anchorTopRight) {
            id windowScreen = ((MacWSMsgID)objc_msgSend)(
                window, sel_registerName("screen"));
            CGRect targetScreen = ((MacWSMsgRect)objc_msgSend)(
                windowScreen ?: screen, sel_registerName("frame"));
            newFrame.origin.x = anchorTopRight
                ? targetScreen.origin.x + targetScreen.size.width -
                    requested.width
                : targetScreen.origin.x;
            newFrame.origin.y = targetScreen.origin.y +
                targetScreen.size.height - requested.height;
        } else {
            newFrame.origin.y += oldFrame.size.height - requested.height;
        }
        SEL setter = sel_registerName("setFrame:display:animate:");
        if (!((MacWSMsgBoolSEL)objc_msgSend)(window,
                sel_registerName("respondsToSelector:"), setter)) return;
        ((MacWSMsgVoidRectBoolBool)objc_msgSend)(
            window, setter, newFrame, YES, NO);
        CGRect appliedFrame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        BOOL geometryChanged =
            fabs(appliedFrame.origin.x - oldFrame.origin.x) > 0.25 ||
            fabs(appliedFrame.origin.y - oldFrame.origin.y) > 0.25 ||
            fabs(appliedFrame.size.width - oldFrame.size.width) > 0.25 ||
            fabs(appliedFrame.size.height - oldFrame.size.height) > 0.25;
        // setFrame:display:animate: is synchronous with AppKit's accepted
        // geometry. Publish that committed size now instead of making Host
        // wait for the 500-ms recovery timer or issue a blind catalog poll.
        MacWSPublishWindowMetrics();
        if (geometryChanged) MacWSNotifyDisplayGeometryChanged(
            windowNumber, window, appliedFrame);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT CONFIGURE pid=%d window=%u "
                "old=%.1fx%.1f requested=%.1fx%.1f minimum=%.1fx%.1f "
                "applied=(%.1f,%.1f %.1fx%.1f) changed=%s density=%.2f anchor=%s\n",
                getpid(), windowNumber,
                oldFrame.size.width, oldFrame.size.height,
                record.x, record.y, minimum.width, minimum.height,
                appliedFrame.origin.x, appliedFrame.origin.y,
                appliedFrame.size.width, appliedFrame.size.height,
                geometryChanged ? "YES" : "NO", record.pressure,
                anchorTopRight ? "top-right" :
                    (anchorTopLeft ? "top-left" : "preserve"));
            fflush(stderr);
        }
        return;
    }

    if (record.kind == MacWSInputKindKeyDown ||
        record.kind == MacWSInputKindKeyUp) {
        uint32_t requestedWindowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id keyWindow = requestedWindowNumber
            ? MacWSWindowWithNumber(application, requestedWindowNumber)
            : ((MacWSMsgID)objc_msgSend)(
                application, sel_registerName("keyWindow"));
        if (requestedWindowNumber && !keyWindow) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=target-window-closed "
                "window=%u kind=%u\n",
                getpid(), requestedWindowNumber, record.kind);
            fflush(stderr);
            return;
        }
        if (!keyWindow) keyWindow = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainWindow"));
        NSInteger keyWindowNumber = keyWindow
            ? ((MacWSMsgInteger)objc_msgSend)(
                keyWindow, sel_registerName("windowNumber")) : 0;
        if (!MacWSPostKeyRecord(record, application, eventClass,
                                keyWindowNumber, NO, NO)) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=key-event-create "
                "kind=%u keycode=%.3f keysym=%#x\n",
                getpid(), record.kind, record.pressure, record.contactID);
            fflush(stderr);
        }
        return;
    }

    CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
    CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
    CGRect screenFrame = ((MacWSMsgRect)objc_msgSend)(screen,
        sel_registerName("frame"));
    uint32_t requestedWindowNumber =
        MacWSInputWindowIDForScene(record.sceneID);
    id window = nil;
    id requestedBaseWindow = nil;
    id outsidePopupWindow = nil;
    BOOL routedToTransientWindow = NO;
    CGPoint screenPoint = {0};
    if (requestedWindowNumber != 0) {
        window = MacWSWindowWithNumber(application, requestedWindowNumber);
        if (!window) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=target-window-closed "
                "window=%u kind=%u\n",
                getpid(), requestedWindowNumber, record.kind);
            fflush(stderr);
            return;
        }
        requestedBaseWindow = window;
        // Window DisplayStream coordinates are top-left backing pixels. Map
        // them through the producer's real backing scale, not by normalizing
        // them into NSWindow.frame. Runtime-confirmed in VSCode PID 53270:
        // DisplayStream remained 2388 px / 1194 pt after Electron restored the
        // base NSWindow to 1004 pt; the old normalization compressed every
        // input coordinate and made the popup's x=1004..1169 pt region
        // unreachable even though Host correctly composited those pixels.
        // The base window stays top-left anchored, so its current maxY and
        // origin remain the stable screen-space origin during live resizing.
        CGRect windowFrame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        CGFloat backingScale = 0.0;
        SEL backingScaleSelector = sel_registerName("backingScaleFactor");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                backingScaleSelector)) {
            backingScale = ((MacWSMsgDouble)objc_msgSend)(
                window, backingScaleSelector);
        }
        if (!isfinite(backingScale) || backingScale < 0.5 ||
            backingScale > 8.0) {
            id windowScreen = ((MacWSMsgID)objc_msgSend)(
                window, sel_registerName("screen"));
            if (windowScreen && ((MacWSMsgBoolSEL)objc_msgSend)(
                    windowScreen, sel_registerName("respondsToSelector:"),
                    backingScaleSelector)) {
                backingScale = ((MacWSMsgDouble)objc_msgSend)(
                    windowScreen, backingScaleSelector);
            }
        }
        if (!isfinite(backingScale) || backingScale < 0.5 ||
            backingScale > 8.0) {
            // This fallback is equivalent to the prior mapping only when the
            // stream and NSWindow are already the same size. It avoids inventing
            // a Retina factor on a screen that does not report one.
            backingScale = record.frameWidth > 0
                ? record.frameWidth / fmax(windowFrame.size.width, 1.0) : 1.0;
        }
        screenPoint = (CGPoint){
            windowFrame.origin.x + record.x / backingScale,
            windowFrame.origin.y + windowFrame.size.height -
                record.y / backingScale,
        };

        // A menu, sheet, tooltip, or popover is a real higher-level NSWindow
        // owned by the same application. Exact-window streaming still uses
        // the base window as its coordinate space, but AppKit must receive the
        // event in whichever of its own stacked windows is actually under the
        // mapped screen point. Restrict this to a visible window above the
        // requested base level so another ordinary same-process document
        // window cannot steal input from its Scene.
        id hitWindow = MacWSWindowForScreenPoint(application, screenPoint);
        if (hitWindow && hitWindow != requestedBaseWindow) {
            NSInteger baseLevel = ((MacWSMsgInteger)objc_msgSend)(
                requestedBaseWindow, sel_registerName("level"));
            NSInteger hitLevel = ((MacWSMsgInteger)objc_msgSend)(
                hitWindow, sel_registerName("level"));
            BOOL hitVisible = ((MacWSMsgBool)objc_msgSend)(
                hitWindow, sel_registerName("isVisible"));
            if (hitVisible && hitLevel > baseLevel) {
                window = hitWindow;
                routedToTransientWindow = YES;
            }
        }
        if (!routedToTransientWindow &&
            (record.kind == MacWSInputKindTap ||
             record.kind == MacWSInputKindSecondaryTap)) {
            outsidePopupWindow = MacWSOutsidePopupWindow(
                application, requestedBaseWindow, screenPoint);
        }
    } else {
        screenPoint = (CGPoint){
            screenFrame.origin.x + normalizedX * screenFrame.size.width,
            screenFrame.origin.y +
                (1.0 - normalizedY) * screenFrame.size.height,
        };
    }
    if (!window && record.kind != MacWSInputKindTouchDown &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindMenuHover &&
        record.kind != MacWSInputKindTap &&
        record.kind != MacWSInputKindSecondaryTap &&
        MacWSAppInputGestureWindow) {
        window = (__bridge id)MacWSAppInputGestureWindow;
    } else if (!window) {
        window = MacWSWindowForScreenPoint(application, screenPoint);
    }
    if (!window) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-window screen=(%.2f,%.2f)\n",
                getpid(), screenPoint.x, screenPoint.y);
        return;
    }
    if (outsidePopupWindow && record.kind == MacWSInputKindTap) {
        NSInteger popupWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
            outsidePopupWindow, sel_registerName("windowNumber"));
        Class menuWindowClass = objc_getClass("NSMenuWindowManagerWindow");
        BOOL appKitMenu = menuWindowClass && ((MacWSMsgBoolID)objc_msgSend)(
            outsidePopupWindow, sel_registerName("isKindOfClass:"),
            (id)menuWindowClass);
        BOOL dismissed = NO;
        const char *route = "escape-pair";
        if (appKitMenu) {
            dismissed = MacWSCancelActiveMenuForEscape(
                application, popupWindowNumber, YES);
            route = "appkit-menu-cancel";
        } else {
            // Chromium/Electron's Views popup has no NSMenuPresentationInstance
            // and no nested AppKit tracker. Its own responder lifecycle closes
            // on an ordinary Escape pair. Deliver that semantic on the same
            // application main thread; never orderOut: the foreign window or
            // mutate Chromium state behind its delegate.
            MacWSInputRecord escape = record;
            escape.sceneID = MacWSInputSceneForWindow(
                requestedWindowNumber, 0);
            escape.kind = MacWSInputKindKeyDown;
            escape.pressure = 53.0f;
            escape.contactID = 0xff1bu;
            escape.source = record.source == MacWSInputSourceUnknown
                ? MacWSInputSourceFinger : record.source;
            BOOL down = MacWSPostKeyRecord(
                escape, application, eventClass,
                (NSInteger)requestedWindowNumber, NO, NO);
            escape.kind = MacWSInputKindKeyUp;
            escape.timestamp += 0.001;
            BOOL up = MacWSPostKeyRecord(
                escape, application, eventClass,
                (NSInteger)requestedWindowNumber, NO, NO);
            dismissed = down && up;
        }
        if (dismissed) {
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT POPUP-OUTSIDE pid=%d base=%u popup=%ld "
                    "class=%s route=%s\n",
                    getpid(), requestedWindowNumber, (long)popupWindowNumber,
                    object_getClassName(outsidePopupWindow), route);
                fflush(stderr);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          40 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSNotifyDisplayCatalogChanged('t');
            });
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
    }
    if (record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap)
        MacWSSetAppInputGestureWindow(window);
    if (!routedToTransientWindow &&
        (record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap)) {
        id oldKeyWindow = ((MacWSMsgID)objc_msgSend)(application,
            sel_registerName("keyWindow"));
        BOOL wasActive = ((MacWSMsgBool)objc_msgSend)(application,
            sel_registerName("isActive"));
        if (window != oldKeyWindow && ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                sel_registerName("makeKeyWindow"))) {
            ((MacWSMsgVoid)objc_msgSend)(window,
                sel_registerName("makeKeyWindow"));
        }
        if (!wasActive && ((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                sel_registerName("activateIgnoringOtherApps:"))) {
            ((MacWSMsgVoidBool)objc_msgSend)(application,
                sel_registerName("activateIgnoringOtherApps:"), YES);
        }
        BOOL isActive = ((MacWSMsgBool)objc_msgSend)(application,
            sel_registerName("isActive"));
        id keyWindow = ((MacWSMsgID)objc_msgSend)(application,
            sel_registerName("keyWindow"));
        static unsigned focusLogs;
        if (MacWSRuntimeDiagnosticsEnabled() && focusLogs++ < 12) {
            fprintf(stderr,
                "#### APP-INPUT FOCUS pid=%d gesture=%u active=%s->%s "
                "key=%ld->%ld selected=%ld\n",
                getpid(), record.contactID,
                wasActive ? "YES" : "NO", isActive ? "YES" : "NO",
                oldKeyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    oldKeyWindow, sel_registerName("windowNumber")) : -1L,
                keyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    keyWindow, sel_registerName("windowNumber")) : -1L,
                (long)((MacWSMsgInteger)objc_msgSend)(window,
                    sel_registerName("windowNumber")));
            fflush(stderr);
        }
    }
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(window,
        sel_registerName("windowNumber"));
    id keyWindowBeforeEvent = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow"));
    NSInteger keyWindowNumberBeforeEvent = keyWindowBeforeEvent
        ? ((MacWSMsgInteger)objc_msgSend)(keyWindowBeforeEvent,
            sel_registerName("windowNumber")) : 0;
    CGPoint windowPoint = ((MacWSMsgPointPoint)objc_msgSend)(window,
        sel_registerName("convertPointFromScreen:"), screenPoint);
    if (record.kind == MacWSInputKindScroll) {
        id scrollEvent = MacWSCreateAppScrollEvent(
            eventClass, record, windowPoint, screenFrame, windowNumber);
        if (!scrollEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=scroll-event-create "
                "window=%ld\n", getpid(), (long)windowNumber);
            return;
        }
        NSInteger eventWindow = ((MacWSMsgInteger)objc_msgSend)(
            scrollEvent, sel_registerName("windowNumber"));
        CGPoint eventPoint = ((MacWSMsgPoint)objc_msgSend)(
            scrollEvent, sel_registerName("locationInWindow"));
        // AppKit's application queue discards the wrapped scroll event because
        // eventWithCGEvent: leaves windowNumber=0 on this launchd session.
        // The broker already selected the exact native NSWindow on its main
        // thread, so use NSWindow's standard event dispatcher. This preserves
        // responder-chain hit testing and scrollWheel: semantics; it does not
        // invoke a control action directly.
        ((MacWSSendEvent)objc_msgSend)(window,
            sel_registerName("sendEvent:"), scrollEvent);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SCROLL-DISPATCH pid=%d target-window=%ld "
                "event-window=%ld local=(%.2f,%.2f) delta=(%.2f,%.2f) "
                "route=NSWindow.sendEvent\n",
                getpid(), (long)windowNumber, (long)eventWindow,
                eventPoint.x, eventPoint.y,
                ((double (*)(id, SEL))objc_msgSend)(
                    scrollEvent, sel_registerName("scrollingDeltaX")),
                ((double (*)(id, SEL))objc_msgSend)(
                    scrollEvent, sel_registerName("scrollingDeltaY")));
            fflush(stderr);
        }
        return;
    }
    if (MacWSRuntimeDiagnosticsEnabled() &&
        (record.kind == MacWSInputKindTouchDown ||
         record.kind == MacWSInputKindTap)) {
        id contentView = ((MacWSMsgID)objc_msgSend)(window,
            sel_registerName("contentView"));
        id frameView = contentView ? ((MacWSMsgID)objc_msgSend)(
            contentView, sel_registerName("superview")) : nil;
        CGPoint contentPoint = contentView
            ? ((MacWSMsgPointPointID)objc_msgSend)(contentView,
                sel_registerName("convertPoint:fromView:"), windowPoint,
                nil) : (CGPoint){0.0, 0.0};
        CGPoint framePoint = frameView
            ? ((MacWSMsgPointPointID)objc_msgSend)(frameView,
                sel_registerName("convertPoint:fromView:"), windowPoint,
                nil) : (CGPoint){0.0, 0.0};
        id hitView = contentView
            ? ((MacWSMsgIDPoint)objc_msgSend)(contentView,
                sel_registerName("hitTest:"), contentPoint) : nil;
        id frameHitView = frameView
            ? ((MacWSMsgIDPoint)objc_msgSend)(frameView,
                sel_registerName("hitTest:"), framePoint) : nil;
        MacWSSetAppInputGestureHitView(hitView);
        static unsigned hitLogs;
        if (hitLogs++ < 12) {
            fprintf(stderr,
                "#### APP-INPUT HIT pid=%d gesture=%u kind=%u window=%ld "
                "screen=(%.2f,%.2f) local=(%.2f,%.2f) content=(%.2f,%.2f) "
                "view=%s frame-view=%s\n",
                getpid(), record.contactID, record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y,
                contentPoint.x, contentPoint.y,
                hitView ? object_getClassName(hitView) : "nil",
                frameHitView ? object_getClassName(frameHitView) : "nil");
            fflush(stderr);
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled() &&
        record.kind == MacWSInputKindTouchDown) {
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
    id event = MacWSRuntimeDiagnosticsEnabled()
        ? MacWSCreateAppMouseEvent(eventClass, record, eventType,
            screenPoint, windowPoint, screenFrame, windowNumber)
        : nil;
    if (!event) {
        event = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            eventType, windowPoint, 0, record.timestamp, windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, pressure);
    }
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
    MacWSApplyTabletMetadata(event, record);
    BOOL isRFB = record.sceneID == 0x564e430000000001ull;
    BOOL usesBufferedTracking = isRFB || requestedWindowNumber != 0;
    if (record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap) {
        // Both VNC and the native Host express a stationary click as one
        // record. Construct the matching pair in the target process, queue up
        // first, then let AppKit's real synchronous control/menu tracker
        // consume it while dispatching down. Splitting this pair across two
        // datagrams previously allowed a nested tracker to starve the up.
        BOOL secondary = record.kind == MacWSInputKindSecondaryTap;
        NSUInteger upType = secondary ? 4 /* rightMouseUp */
                                      : 2 /* leftMouseUp */;
        MacWSInputRecord upRecord = record;
        upRecord.kind = MacWSInputKindTouchUp;
        upRecord.pressure = 0.0f;
        id upEvent = MacWSRuntimeDiagnosticsEnabled()
            ? MacWSCreateAppMouseEvent(eventClass, upRecord, upType,
                screenPoint, windowPoint, screenFrame, windowNumber)
            : nil;
        if (!upEvent) {
            upEvent = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
                sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
                upType, windowPoint, 0,
                record.timestamp + 0.001, windowNumber, nil,
                MacWSNextAppInputEventNumber(), 1, 0.0f);
        }
        if (!upEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=tap-up-create window=%ld gesture=%u\n",
                getpid(), (long)windowNumber, record.contactID);
            MacWSSetAppInputGestureWindow(nil);
            return;
        }
        upRecord.kind = MacWSInputKindTouchUp;
        MacWSApplyTabletMetadata(upEvent, upRecord);
        id activeMenuPresentation = MacWSActiveMenuPresentationInstance();
        if (!secondary && !activeMenuPresentation &&
            requestedWindowNumber != 0) {
            // A direct UIKit tap has no preceding pointer-motion packet, while
            // AppKit and Electron legitimately use mouseMoved/tracking-area
            // state to reveal and arm controls (Terminal's tab close button is
            // one concrete example). Apply the same complete semantic after
            // routing to a real higher-level transient NSWindow instead of
            // silently omitting hover only because the final window differs
            // from the base. activeMenuPresentation remains the authoritative
            // exclusion for an already-running native AppKit menu tracker.
            MacWSInputRecord hoverRecord = record;
            hoverRecord.kind = MacWSInputKindHover;
            hoverRecord.pressure = 0.0f;
            id hoverEvent = MacWSRuntimeDiagnosticsEnabled()
                ? MacWSCreateAppMouseEvent(eventClass, hoverRecord,
                    5 /* mouseMoved */, screenPoint, windowPoint,
                    screenFrame, windowNumber)
                : nil;
            if (!hoverEvent) {
                hoverEvent = ((MacWSMouseEventFactory)objc_msgSend)(
                    (id)eventClass,
                    sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
                    5, windowPoint, 0, record.timestamp, windowNumber, nil,
                    MacWSNextAppInputEventNumber(), 0, 0.0f);
            }
            if (hoverEvent)
                MacWSSendMouseEventWithStateBridge(
                    application, hoverEvent, 0);
        }
        if (activeMenuPresentation && routedToTransientWindow) {
            // NSMenuPresentationInstance owns a nested nextEvent loop and does
            // not receive mouse input through NSApplication.sendEvent:. Put a
            // complete down/up pair in its real queue in chronological order.
            // AppKit remains responsible for hit testing and invoking the
            // selected item's action.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), upEvent, YES);
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, YES);
            MacWSNotifyDisplayCatalogChanged('t');
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
        // Either mouse button can synchronously enter AppKit/Carbon tracking:
        // a primary click can open an Electron toolbar menu just as a
        // secondary click opens a context menu. Cache the exact source/window
        // transform before sendEvent: and expose the synchronous interval to
        // the socket thread. If sendEvent: returns normally this interval is
        // only a few microseconds; if it enters TrackMenuCommon, later taps go
        // straight into the event queue that the nested tracker consumes.
        CGRect inputMappingFrame = screenFrame;
        if (requestedBaseWindow) {
            inputMappingFrame = ((MacWSMsgRect)objc_msgSend)(
                requestedBaseWindow, sel_registerName("frame"));
        }
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSCacheMenuContextLocked(
            application, eventClass, windowNumber, inputMappingFrame,
            screenPoint, windowPoint, NO);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        MacWSAppInputRFBTrackingActive = YES;
        MacWSAppInputRFBTrackingButtons = secondary ? 2u : 1u;
        atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, YES,
                              memory_order_release);
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), upEvent, YES);
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
        MacWSCompletePrequeuedAtomicUp(application, upEvent, upType);
        atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, NO,
                              memory_order_release);
        MacWSAppInputRFBTrackingActive = NO;
        MacWSAppInputRFBTrackingButtons = 0;
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT TAP-COMPLETE pid=%d button=%s gesture=%u window=%ld "
                "screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                getpid(), secondary ? "secondary" : "primary",
                record.contactID, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
            fflush(stderr);
        }
        MacWSLogAppInputGestureHitResult("tap", record.contactID);
        id keyWindowAfterEvent = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow"));
        NSInteger keyWindowNumberAfterEvent = keyWindowAfterEvent
            ? ((MacWSMsgInteger)objc_msgSend)(keyWindowAfterEvent,
                sel_registerName("windowNumber")) : 0;
        if (keyWindowNumberAfterEvent != keyWindowNumberBeforeEvent)
            MacWSNotifyDisplayCatalogChanged('k');
        // Any atomic click can create or dismiss a separate AppKit/Electron
        // popover window while the key window remains unchanged. Runtime on
        // VSCode's Simple Browser showed the outside click completed in the
        // base NSWindow, but Host kept compositing the closed transient's last
        // IOSurface because this edge was previously emitted only for right
        // clicks. Reconcile after every semantic click; displayd still reads
        // the real on-screen CGWindow catalog and owns attach/detach policy.
        MacWSNotifyDisplayCatalogChanged('t');
        MacWSSetAppInputGestureWindow(nil);
        MacWSClearDeferredRFBMoveEvents();
        return;
    }
    if (usesBufferedTracking && record.kind == MacWSInputKindTouchDown) {
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
    if (usesBufferedTracking && MacWSAppInputRFBTrackingActive) {
        // This block is running re-entrantly inside sendEvent(mouseDown)'s
        // tracking loop. Queue the real event at the head; the tracker consumes
        // it before requesting the next one. In particular, up releases the
        // synchronous outer dispatch instead of starting another sendEvent.
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
    } else if (usesBufferedTracking && record.kind == MacWSInputKindTouchMove &&
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
            MacWSAppInputRFBTrackingButtons = 1u;
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
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-FALLBACK pid=%d gesture=%u "
                    "reason=pending-record\n",
                    getpid(), record.contactID);
                fflush(stderr);
            }
        } else {
            ((MacWSSendEvent)objc_msgSend)(application,
                sel_registerName("sendEvent:"), downEvent);
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            MacWSAppInputRFBTrackingActive = NO;
            MacWSAppInputRFBTrackingButtons = 0;
            MacWSClearDirectTrackingContextLocked();
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-DISPATCH-RETURN pid=%d gesture=%u "
                    "window=%ld first-move=(%.2f,%.2f)\n",
                    getpid(), record.contactID, (long)windowNumber,
                    screenPoint.x, screenPoint.y);
                fflush(stderr);
            }
            MacWSLogAppInputGestureHitResult("live-drag", record.contactID);
            [downEvent release];
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
    } else if (usesBufferedTracking &&
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
        MacWSAppInputRFBTrackingButtons = 1u;
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
        MacWSAppInputRFBTrackingButtons = 0;
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT GESTURE-DISPATCH-RETURN pid=%d gesture=%u "
                "window=%ld moves=%lu release=(%.2f,%.2f)\n",
                getpid(), record.contactID, (long)windowNumber,
                (unsigned long)[moves count], screenPoint.x, screenPoint.y);
            fflush(stderr);
        }
        MacWSLogAppInputGestureHitResult("drag", record.contactID);
        [moves release];
        [downEvent release];
    } else if ((isRFB || requestedWindowNumber != 0) &&
               (record.kind == MacWSInputKindHover ||
                record.kind == MacWSInputKindMenuHover)) {
        id menuPresentation = MacWSActiveMenuPresentationInstance();
        if (menuPresentation) {
            // The active menu's nested nextEvent loop is the queue consumer.
            // Keep normal event ordering and let AppKit's own handleEvent:
            // perform hit-testing, submenu switching, and highlighting.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, NO);
            static _Atomic uint64_t menuHoverPosts;
            uint64_t post = MacWSRuntimeDiagnosticsEnabled()
                ? atomic_fetch_add_explicit(
                    &menuHoverPosts, 1, memory_order_relaxed) + 1 : 0;
            if (post != 0 && (post <= 48 || (post % 600) == 0)) {
                fprintf(stderr,
                    "#### APP-INPUT MENU-QUEUE pid=%d event=%llu "
                    "window=%ld local=(%.2f,%.2f) presentation=%s\n",
                    getpid(), (unsigned long long)post,
                    (long)windowNumber, windowPoint.x, windowPoint.y,
                    object_getClassName(menuPresentation));
                fflush(stderr);
            }
        } else {
            // RE-confirmed in macOS 13.4 AppKit:
            // NSMenuBarPresentationInstance::_mouseMovedEventHandler: first
            // invokes _updateTrackedControllerForMenuBar. It forwards to the
            // ordinary NSMenuPresentationInstance handler only when that
            // update found a tracker (or its own active flag is already set),
            // and otherwise returns false. This is the system's own routing
            // decision, not a forced highlight/action.
            id menuBarPresentation = MacWSMenuBarPresentationInstance();
            SEL menuBarMove =
                sel_registerName("_mouseMovedEventHandler:");
            BOOL menuBarHandled = menuBarPresentation &&
                ((MacWSMsgBoolSEL)objc_msgSend)(
                    menuBarPresentation,
                    sel_registerName("respondsToSelector:"), menuBarMove);
            if (menuBarHandled) {
                BOOL previousLocationActive =
                    MacWSAppInputMouseLocationActive;
                CGPoint previousLocation = MacWSAppInputMouseLocation;
                MacWSAppInputMouseLocation = screenPoint;
                MacWSAppInputMouseLocationActive = YES;
                menuBarHandled = ((MacWSMsgBoolID)objc_msgSend)(
                    menuBarPresentation, menuBarMove, event);
                MacWSAppInputMouseLocation = previousLocation;
                MacWSAppInputMouseLocationActive = previousLocationActive;
            }
            if (menuBarHandled) {
                static _Atomic uint64_t menuBarHovers;
                uint64_t handled = MacWSRuntimeDiagnosticsEnabled()
                    ? atomic_fetch_add_explicit(
                        &menuBarHovers, 1, memory_order_relaxed) + 1 : 0;
                if (handled != 0 &&
                    (handled <= 48 || (handled % 600) == 0)) {
                    fprintf(stderr,
                        "#### APP-INPUT MENU-BAR-HANDLED pid=%d event=%llu "
                        "window=%ld local=(%.2f,%.2f) presentation=%s\n",
                        getpid(), (unsigned long long)handled,
                        (long)windowNumber, windowPoint.x, windowPoint.y,
                        object_getClassName(menuBarPresentation));
                    fflush(stderr);
                }
            } else {
                MacWSSendMouseEventWithStateBridge(application, event, 0);
            }
        }
    } else {
        // Native-host gestures, hover, and RFB drags keep ordinary queue
        // semantics. Flush a deferred tap-down before the first drag record.
        if (usesBufferedTracking && MacWSAppInputDeferredRFBDownEvent) {
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
                          record.kind == MacWSInputKindHover ||
                          record.kind == MacWSInputKindMenuHover ||
                          record.kind == MacWSInputKindScroll ||
                          record.kind == MacWSInputKindConfigureWindow;
        BOOL replaced = NO;
        NSUInteger pendingCount = [MacWSAppInputPending count];
        if (continuous && pendingCount != 0) {
            NSData *lastData = [MacWSAppInputPending objectAtIndex:pendingCount - 1];
            if ([lastData length] == sizeof(MacWSInputRecord)) {
                MacWSInputRecord last = {0};
                [lastData getBytes:&last length:sizeof(last)];
                if (last.kind == record.kind &&
                    last.sceneID == record.sceneID &&
                    (record.kind == MacWSInputKindScroll ||
                     last.contactID == record.contactID) &&
                    (record.kind != MacWSInputKindScroll ||
                     last.flags == record.flags) &&
                    last.targetPID == record.targetPID) {
                    if (record.kind == MacWSInputKindScroll) {
                        float previousHorizontal = 0.0f;
                        float incomingHorizontal = 0.0f;
                        memcpy(&previousHorizontal, &last.contactID,
                               sizeof(previousHorizontal));
                        memcpy(&incomingHorizontal, &record.contactID,
                               sizeof(incomingHorizontal));
                        record.pressure = fmaxf(-16384.0f,
                            fminf(16384.0f,
                                last.pressure + record.pressure));
                        incomingHorizontal = fmaxf(-16384.0f,
                            fminf(16384.0f,
                                previousHorizontal + incomingHorizontal));
                        memcpy(&record.contactID, &incomingHorizontal,
                               sizeof(record.contactID));
                        [data release];
                        data = [[NSData alloc] initWithBytes:&record
                                                     length:sizeof(record)];
                    }
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
                        candidate.kind == MacWSInputKindHover ||
                        candidate.kind == MacWSInputKindMenuHover ||
                        candidate.kind == MacWSInputKindScroll ||
                        candidate.kind == MacWSInputKindConfigureWindow) {
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
// +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:] applies the
// WindowServer's front-to-back mouse-down rules and may return a window owned
// by another application.  Comparing that number with the process-local
// orderedWindows candidate prevents overlapping apps that both incorrectly
// report isActive=YES in the chroot from both claiming the same point.
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
    Class windowClass = objc_getClass("NSWindow");
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
    NSInteger globalWindowNumber = 0;
    BOOL menuSurface = NO;
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
        SEL globalHitSelector = sel_registerName(
            "windowNumberAtPoint:belowWindowWithWindowNumber:");
        if (windowClass && class_respondsToSelector(
                object_getClass(windowClass), globalHitSelector)) {
            globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
                (id)windowClass, globalHitSelector, screenPoint, 0);
        }
        SEL applicationWindowSelector =
            sel_registerName("windowWithWindowNumber:");
        if (globalWindowNumber > 0 && ((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                applicationWindowSelector)) {
            hitWindow = ((MacWSMsgIDInteger)objc_msgSend)(
                application, applicationWindowSelector,
                globalWindowNumber);
            if (hitWindow) {
                hitWindowFrame = ((MacWSMsgRect)objc_msgSend)(
                    hitWindow, sel_registerName("frame"));
            }
        }
        id windows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("orderedWindows"));
        NSUInteger count = [windows count];
        for (NSUInteger index = 0; !hitWindow && index < count; index++) {
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
        NSInteger contextWindowNumber = hitWindow
            ? ((MacWSMsgInteger)objc_msgSend)(
                hitWindow, sel_registerName("windowNumber")) : 0;
        CGPoint contextWindowPoint = hitWindow
            ? ((MacWSMsgPointPoint)objc_msgSend)(
                hitWindow, sel_registerName("convertPointFromScreen:"),
                screenPoint) : screenPoint;
        Class eventClass = objc_getClass("NSEvent");
        // Runtime probes identify both the menu-bar root menu and Terminal's
        // contextual menu as NSMenuWindowManagerWindow. Use AppKit's exact
        // class relationship instead of a broad class-name substring so an
        // unrelated panel with "Menu" in its private class name cannot acquire
        // the privileged Escape/dismiss route.
        Class menuWindowClass = objc_getClass("NSMenuWindowManagerWindow");
        menuSurface = hitWindow && menuWindowClass &&
            ((MacWSMsgBoolID)objc_msgSend)(
                hitWindow, sel_registerName("isKindOfClass:"),
                (id)menuWindowClass);
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSCacheMenuContextLocked(application, eventClass,
            contextWindowNumber, screenFrame, screenPoint,
            contextWindowPoint, menuSurface);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
    }
    if (hitWindow) {
        NSInteger localWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
            hitWindow, sel_registerName("windowNumber"));
        reply.windowNumber = (int32_t)localWindowNumber;
        // A nonpositive global result means the API was unavailable or the
        // WindowServer found no hittable window; retain the old local test as
        // a compatibility fallback.  A positive result is authoritative.
        if (globalWindowNumber <= 0 ||
            localWindowNumber == globalWindowNumber) {
            reply.flags |= MacWSInputTargetHit;
            if (hitWindow == keyWindow)
                reply.flags |= MacWSInputTargetKeyWindow;
        }
    }
    if (application && ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) {
        reply.flags |= MacWSInputTargetApplicationActive;
    }
    if (application &&
        MacWSCaptureFrontUISnapshot().ownsFrontUIProcess) {
        reply.flags |= MacWSInputTargetFrontUIProcess;
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
    if (MacWSRuntimeDiagnosticsEnabled() && probeLogs++ < 24) {
        fprintf(stderr,
                "#### APP-INPUT TARGET-REPLY pid=%d nonce=%llu "
                "window=%d global=%ld flags=%#x "
                "class=%s menu-surface=%s frame=(%.1f,%.1f %.1fx%.1f) "
                "sent=%zd errno=%d\n",
                getpid(), (unsigned long long)probe.nonce,
                reply.windowNumber, (long)globalWindowNumber, reply.flags,
                hitWindow ? object_getClassName(hitWindow) : "nil",
                menuSurface ? "YES" : "NO",
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

static MacWSMenuResponseHeader MacWSMenuResponseHeaderMake(
    const MacWSMenuRequest *request, MacWSMenuStatus status,
    uint64_t generation) {
    return (MacWSMenuResponseHeader){
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(MacWSMenuResponseHeader),
        .status = status,
        .nonce = request->nonce,
        .ownerPID = getpid(),
        .windowID = request->windowID,
        .generation = generation ? generation : 1,
        .totalBytes = sizeof(MacWSMenuResponseHeader),
    };
}

static void MacWSMenuAppendString(NSMutableData *strings, NSString *value,
                                  uint32_t *offsetOut,
                                  uint32_t *lengthOut) {
    if (offsetOut) *offsetOut = (uint32_t)strings.length;
    if (lengthOut) *lengthOut = 0;
    if (![value isKindOfClass:[NSString class]] || value.length == 0 ||
        strings.length >= MACWS_MENU_MAX_STRING_BYTES) return;

    NSString *bounded = value;
    NSData *encoded = [bounded dataUsingEncoding:NSUTF8StringEncoding];
    while (encoded.length > MACWS_MENU_MAX_ITEM_STRING_BYTES &&
           bounded.length > 0) {
        NSRange last = [bounded rangeOfComposedCharacterSequenceAtIndex:
            bounded.length - 1];
        bounded = [bounded substringToIndex:last.location];
        encoded = [bounded dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSUInteger available = MACWS_MENU_MAX_STRING_BYTES - strings.length;
    if (!encoded || encoded.length > available || encoded.length > UINT32_MAX)
        return;
    if (offsetOut) *offsetOut = (uint32_t)strings.length;
    if (lengthOut) *lengthOut = (uint32_t)encoded.length;
    [strings appendData:encoded];
}

static NSString *MacWSMenuShortcutForItem(id item) {
    id key = ((MacWSMsgID)objc_msgSend)(
        item, sel_registerName("keyEquivalent"));
    if (![key isKindOfClass:objc_getClass("NSString")] || [key length] == 0)
        return MacWSRuntimeString("");
    NSUInteger modifiers = ((MacWSMsgUInteger)objc_msgSend)(
        item, sel_registerName("keyEquivalentModifierMask"));
    NSMutableString *shortcut = [NSMutableString string];
    if (modifiers & (1u << 18))
        [shortcut appendString:MacWSRuntimeString("⌃")];
    if (modifiers & (1u << 19))
        [shortcut appendString:MacWSRuntimeString("⌥")];
    if (modifiers & (1u << 17))
        [shortcut appendString:MacWSRuntimeString("⇧")];
    if (modifiers & (1u << 20))
        [shortcut appendString:MacWSRuntimeString("⌘")];
    [shortcut appendString:[key uppercaseString]];
    return shortcut;
}

static BOOL MacWSMenuAppendTree(id menu, uint64_t parentItemID,
                                NSUInteger depth, NSArray *parentPath,
                                NSMutableData *nodes, NSMutableData *strings,
                                NSMutableArray *items,
                                NSMutableArray *paths) {
    if (!menu || depth >= MACWS_MENU_MAX_DEPTH) return YES;
    SEL updateSelector = sel_registerName("update");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            menu, sel_registerName("respondsToSelector:"), updateSelector))
        ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
    id itemArray = ((MacWSMsgID)objc_msgSend)(
        menu, sel_registerName("itemArray"));
    if (![itemArray isKindOfClass:objc_getClass("NSArray")]) return NO;

    NSUInteger count = [itemArray count];
    for (NSUInteger index = 0; index < count; index++) {
        if (nodes.length / sizeof(MacWSMenuNode) >= MACWS_MENU_MAX_NODES)
            return YES;
        id item = [itemArray objectAtIndex:index];
        if (!item) continue;
        uint64_t itemID = nodes.length / sizeof(MacWSMenuNode) + 1;
        NSMutableArray *path = [NSMutableArray arrayWithArray:
            parentPath ?: [NSArray array]];
        [path addObject:@(index)];
        [items addObject:item];
        [paths addObject:path];

        BOOL separator = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isSeparatorItem"));
        BOOL enabled = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isEnabled"));
        BOOL hidden = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isHidden"));
        BOOL alternate = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isAlternate"));
        id submenu = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("submenu"));
        id customView = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("view"));
        NSInteger state = ((MacWSMsgInteger)objc_msgSend)(
            item, sel_registerName("state"));
        NSString *title = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("title"));
        MacWSMenuNode node = {
            .itemID = itemID,
            .parentItemID = parentItemID,
            .siblingIndex = (uint32_t)index,
            .flags = (separator ? MacWSMenuNodeSeparator : 0) |
                (enabled ? MacWSMenuNodeEnabled : 0) |
                (hidden ? MacWSMenuNodeHidden : 0) |
                (submenu ? MacWSMenuNodeHasSubmenu : 0) |
                (state == 1 ? MacWSMenuNodeChecked : 0) |
                (state == -1 ? MacWSMenuNodeMixed : 0) |
                (alternate ? MacWSMenuNodeAlternate : 0) |
                (customView ? MacWSMenuNodeRequiresWorkspace : 0),
            .state = (int32_t)state,
        };
        uint32_t titleOffset = 0;
        uint32_t titleLength = 0;
        uint32_t shortcutOffset = 0;
        uint32_t shortcutLength = 0;
        MacWSMenuAppendString(strings, title, &titleOffset, &titleLength);
        MacWSMenuAppendString(strings, MacWSMenuShortcutForItem(item),
                              &shortcutOffset, &shortcutLength);
        node.titleOffset = titleOffset;
        node.titleLength = titleLength;
        node.shortcutOffset = shortcutOffset;
        node.shortcutLength = shortcutLength;
        [nodes appendBytes:&node length:sizeof(node)];
        if (submenu && !MacWSMenuAppendTree(submenu, itemID, depth + 1,
                                            path, nodes, strings,
                                            items, paths)) return NO;
    }
    return YES;
}

static id MacWSMenuItemAtPath(id mainMenu, NSArray *path) {
    id menu = mainMenu;
    id item = nil;
    for (NSNumber *component in path) {
        SEL updateSelector = sel_registerName("update");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                menu, sel_registerName("respondsToSelector:"),
                updateSelector))
            ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
        id array = ((MacWSMsgID)objc_msgSend)(
            menu, sel_registerName("itemArray"));
        NSUInteger index = component.unsignedIntegerValue;
        if (![array isKindOfClass:objc_getClass("NSArray")] ||
            index >= [array count])
            return nil;
        item = [array objectAtIndex:index];
        menu = ((MacWSMsgID)objc_msgSend)(item, sel_registerName("submenu"));
    }
    return item;
}

static NSData *MacWSMenuSnapshotOnMainThread(
    const MacWSMenuRequest *request) {
    uint64_t generation = ++MacWSMenuNextGeneration;
    if (generation == 0) generation = ++MacWSMenuNextGeneration;
    MacWSMenuResponseHeader header = MacWSMenuResponseHeaderMake(
        request, MacWSMenuStatusTargetUnavailable, generation);
    Class applicationClass = objc_getClass("NSApplication");
    id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
        applicationClass, sel_registerName("sharedApplication")) : nil;
    id window = application
        ? MacWSWindowWithNumber(application, request->windowID) : nil;
    id mainMenu = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("mainMenu")) : nil;
    if (!window || !mainMenu) return [NSData dataWithBytes:&header
                                                    length:sizeof(header)];

    id appearance = ((MacWSMsgID)objc_msgSend)(
        window, sel_registerName("effectiveAppearance"));
    if (appearance) {
        NSArray *candidates = [NSArray arrayWithObjects:
            MacWSRuntimeString("NSAppearanceNameAqua"),
            MacWSRuntimeString("NSAppearanceNameDarkAqua"), nil];
        id match = ((MacWSMsgIDID)objc_msgSend)(appearance,
            sel_registerName("bestMatchFromAppearancesWithNames:"),
            candidates);
        if ([match isEqual:MacWSRuntimeString("NSAppearanceNameDarkAqua")])
            header.appearance = MacWSMenuAppearanceDark;
        else if ([match isEqual:MacWSRuntimeString("NSAppearanceNameAqua")])
            header.appearance = MacWSMenuAppearanceLight;
    }

    // A snapshot is a read-only query.  In particular, never order or key the
    // requested window here: NSWindowStackController can be in the middle of
    // committing a Terminal tab-group transition while displayd asks for a
    // menu refresh.  Runtime evidence from Terminal showed this former
    // makeKeyAndOrderFront: call re-entering
    // _doTabbedWindowOrderInWithWasVisible: and terminating on the AppKit
    // "expected no items" invariant.  Explicit Host interaction activates
    // the represented window before an action; passive refreshes must not
    // mutate the application's window graph.
    NSMutableData *nodes = [NSMutableData data];
    NSMutableData *strings = [NSMutableData data];
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *paths = [NSMutableArray array];
    BOOL built = MacWSMenuAppendTree(mainMenu, 0, 0, [NSArray array],
                                     nodes, strings,
                                     items, paths);
    NSUInteger total = sizeof(header) + nodes.length + strings.length;
    if (!built || items.count == 0 || total > MACWS_MENU_MAX_TOTAL_BYTES) {
        header.status = MacWSMenuStatusInternalError;
        return [NSData dataWithBytes:&header length:sizeof(header)];
    }

    if (!MacWSMenuCaches) MacWSMenuCaches = [NSMutableDictionary new];
    NSArray *itemsCopy = [items copy];
    NSArray *pathsCopy = [paths copy];
    NSDictionary *cache = [NSDictionary dictionaryWithObjectsAndKeys:
        itemsCopy, MacWSRuntimeString("items"),
        pathsCopy, MacWSRuntimeString("paths"),
        @(request->windowID), MacWSRuntimeString("window"), nil];
    [itemsCopy release];
    [pathsCopy release];
    MacWSMenuCaches[@(generation)] = cache;
    if (MacWSMenuCaches.count > 8) {
        NSArray *ordered = [MacWSMenuCaches.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        [MacWSMenuCaches removeObjectForKey:ordered.firstObject];
    }

    header.status = MacWSMenuStatusOK;
    header.nodeCount = (uint32_t)items.count;
    header.stringBytes = (uint32_t)strings.length;
    header.totalBytes = (uint32_t)total;
    NSMutableData *response = [NSMutableData dataWithBytes:&header
                                                     length:sizeof(header)];
    [response appendData:nodes];
    [response appendData:strings];
    return response;
}

static NSData *MacWSMenuActionOnMainThread(
    const MacWSMenuRequest *request, BOOL perform) {
    MacWSMenuStatus status = MacWSMenuStatusStaleGeneration;
    NSDictionary *cache = MacWSMenuCaches[@(request->generation)];
    NSArray *cachedItems = [cache objectForKey:MacWSRuntimeString("items")];
    NSArray *cachedPaths = [cache objectForKey:MacWSRuntimeString("paths")];
    if ([[cache objectForKey:MacWSRuntimeString("window")] unsignedIntValue] ==
            request->windowID &&
        request->itemID > 0 &&
        request->itemID <= cachedItems.count) {
        Class applicationClass = objc_getClass("NSApplication");
        id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
            applicationClass, sel_registerName("sharedApplication")) : nil;
        id window = application ? MacWSWindowWithNumber(
            application, request->windowID) : nil;
        id mainMenu = application ? ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainMenu")) : nil;
        id cached = [cachedItems objectAtIndex:request->itemID - 1];
        NSArray *path = [cachedPaths objectAtIndex:request->itemID - 1];
        id current = mainMenu ? MacWSMenuItemAtPath(mainMenu, path) : nil;
        if (!window || !current || current != cached) {
            status = MacWSMenuStatusTargetUnavailable;
        } else if (((MacWSMsgBool)objc_msgSend)(
                       current, sel_registerName("isHidden")) ||
                   !((MacWSMsgBool)objc_msgSend)(
                       current, sel_registerName("isEnabled"))) {
            status = MacWSMenuStatusDisabled;
        } else if (((MacWSMsgID)objc_msgSend)(
                       current, sel_registerName("submenu")) ||
                   ((MacWSMsgID)objc_msgSend)(
                       current, sel_registerName("view"))) {
            status = MacWSMenuStatusUnsupported;
        } else {
            SEL action = ((SEL (*)(id, SEL))objc_msgSend)(
                current, sel_registerName("action"));
            if (!action) {
                status = MacWSMenuStatusUnsupported;
            } else if (!perform) {
                // The socket thread sends this acknowledgement before asking
                // the main queue to execute the already validated action. A
                // terminating action such as Quit can therefore destroy the
                // process without also destroying its only success reply.
                status = MacWSMenuStatusOK;
            } else {
                // Action execution is also deliberately free of window-order
                // mutations.  The Host emits ActivateTarget as the explicit
                // user intent before arriving here.  Reordering from inside
                // a menu transaction can re-enter AppKit's tab controller,
                // which is the exact failure the snapshot path used to cause.
                id target = ((MacWSMsgID)objc_msgSend)(
                    current, sel_registerName("target"));
                status = ((MacWSMsgBoolSELIDID)objc_msgSend)(application,
                    sel_registerName("sendAction:to:from:"), action, target,
                    current) ? MacWSMenuStatusOK
                             : MacWSMenuStatusUnsupported;
            }
        }
    }
    MacWSMenuResponseHeader header = MacWSMenuResponseHeaderMake(
        request, status, request->generation);
    return [NSData dataWithBytes:&header length:sizeof(header)];
}

static void MacWSHandleMenuRequest(const MacWSMenuRequest *request,
                                   const struct sockaddr_un *replyAddress,
                                   socklen_t replyAddressLength) {
    if (!replyAddress || replyAddressLength == 0 ||
        request->ownerPID != getpid()) return;
    __block NSData *response = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSData *generated = request->operation == MacWSMenuOperationSnapshot
                ? MacWSMenuSnapshotOnMainThread(request)
                : MacWSMenuActionOnMainThread(request, NO);
            response = [generated retain];
        }
    });
    if (!response) return;

    MacWSMenuResponseHeader replyHeader = *(const MacWSMenuResponseHeader *)
        response.bytes;
    if (request->operation == MacWSMenuOperationSnapshot &&
        replyHeader.status == MacWSMenuStatusOK) {
        NSString *path = [NSString stringWithFormat:MacWSRuntimeString(
            "/private/tmp/macws_menu_snapshot.%d.%016llx.bin"), getpid(),
            (unsigned long long)request->nonce];
        NSError *error = nil;
        if (![response writeToFile:path options:NSDataWritingAtomic
                             error:&error]) {
            replyHeader.status = MacWSMenuStatusInternalError;
        } else {
            chmod(path.fileSystemRepresentation, 0600);
        }
        // The datagram is an acknowledgement; the bounded snapshot lives in
        // the atomic sidecar and is consumed/unlinked by macwsdisplayd.
        replyHeader.nodeCount = 0;
        replyHeader.stringBytes = 0;
        replyHeader.totalBytes = sizeof(replyHeader);
    }
    (void)sendto(MacWSAppInputSocket, &replyHeader, sizeof(replyHeader), 0,
                 (const struct sockaddr *)replyAddress,
                 replyAddressLength);
    if (request->operation == MacWSMenuOperationAction &&
        replyHeader.status == MacWSMenuStatusOK) {
        MacWSMenuRequest accepted = *request;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                NSData *result = MacWSMenuActionOnMainThread(&accepted, YES);
                if (MacWSRuntimeDiagnosticsEnabled()) {
                    const MacWSMenuResponseHeader *header = result.bytes;
                    fprintf(stderr,
                        "#### APP-MENU ACTION-DISPATCH pid=%d window=%u "
                        "generation=%llu item=%llu status=%u\n",
                        getpid(), accepted.windowID,
                        (unsigned long long)accepted.generation,
                        (unsigned long long)accepted.itemID,
                        header ? header->status : 0);
                    fflush(stderr);
                }
            }
        });
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-MENU op=%u pid=%d window=%u generation=%llu "
            "status=%u nodes=%u\n",
            request->operation, getpid(), request->windowID,
            (unsigned long long)replyHeader.generation, replyHeader.status,
            ((const MacWSMenuResponseHeader *)response.bytes)->nodeCount);
        fflush(stderr);
    }
    [response release];
}

static void *MacWSAppInputThread(void *unused) {
    (void)unused;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr, "#### APP-INPUT THREAD pid=%d socket=%d\n",
                getpid(), MacWSAppInputSocket);
        fflush(stderr);
    }
    while (MacWSAppInputSocket >= 0) {
        union {
            MacWSInputRecord record;
            MacWSInputTargetProbe probe;
            MacWSMenuRequest menu;
        } message = {0};
        struct sockaddr_un sourceAddress = {0};
        socklen_t sourceAddressLength = sizeof(sourceAddress);
        ssize_t count = recvfrom(MacWSAppInputSocket, &message,
                                 sizeof(message), 0,
                                 (struct sockaddr *)&sourceAddress,
                                 &sourceAddressLength);
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
        if (count == sizeof(MacWSMenuRequest) &&
            MacWSMenuRequestIsValid(&message.menu, sizeof(message.menu))) {
            MacWSHandleMenuRequest(&message.menu, &sourceAddress,
                                   sourceAddressLength);
            continue;
        }
        MacWSInputRecord record = message.record;
        if (MacWSRuntimeDiagnosticsEnabled() &&
            record.kind != MacWSInputKindTouchMove &&
            record.kind != MacWSInputKindHover &&
            record.kind != MacWSInputKindMenuHover) {
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
        BOOL keyRecord = record.kind == MacWSInputKindKeyDown ||
                         record.kind == MacWSInputKindKeyUp;
        BOOL directMenuTap = MacWSPrepareDirectMenuTapPostLocked(
            record, &snapshot);
        BOOL postedDirectly = directMenuTap || (keyRecord
            ? MacWSPrepareDirectKeyPostLocked(record, &snapshot)
            : ((record.kind == MacWSInputKindMenuHover ||
                record.kind == MacWSInputKindHover)
                ? MacWSPrepareDirectMenuPostLocked(record, &snapshot)
                : MacWSPrepareDirectTrackingPostLocked(record, &snapshot)));
        if (!postedDirectly) MacWSEnqueueAppInputRecord(record);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        if (directMenuTap) {
            MacWSPostDirectMenuTapRecord(record, snapshot);
        } else if (postedDirectly && keyRecord) {
            BOOL posted = MacWSPostKeyRecord(
                record, (__bridge id)snapshot.application,
                snapshot.eventClass, snapshot.windowNumber, YES,
                snapshot.menuSurface);
            if (!posted) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-DROP pid=%d kind=%u "
                    "keycode=%.3f keysym=%#x reason=event-create\n",
                    getpid(), record.kind, record.pressure, record.contactID);
                fflush(stderr);
            }
            if (snapshot.application) CFRelease(snapshot.application);
        } else if (postedDirectly) {
            MacWSPostDirectTrackingRecord(record, snapshot);
        }
    }
    return NULL;
}

// Runs on the application main thread. This reports the real AppKit
// constraints; macwsdisplayd must not invent a product-wide minimum width.
static char MacWSLogicalWindowGroupAssociationKey;

static uint32_t MacWSLogicalWindowGroupID(id window) {
    NSInteger ownNumber = ((MacWSMsgInteger)objc_msgSend)(
        window, sel_registerName("windowNumber"));
    if (ownNumber <= 0 || (uint64_t)ownNumber > UINT32_MAX) return 0;
    uint32_t groupID = (uint32_t)ownNumber;

    SEL tabGroupSelector = sel_registerName("tabGroup");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            window, sel_registerName("respondsToSelector:"),
            tabGroupSelector)) return groupID;
    id tabGroup = ((MacWSMsgID)objc_msgSend)(window, tabGroupSelector);
    if (!tabGroup) return groupID;
    SEL windowsSelector = sel_registerName("windows");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            tabGroup, sel_registerName("respondsToSelector:"),
            windowsSelector)) return groupID;
    id groupWindows = ((MacWSMsgID)objc_msgSend)(tabGroup, windowsSelector);
    NSUInteger groupCount = [groupWindows count];

    // NSWindow.windowNumber is the capture identity, not the user's window
    // identity: selecting an AppKit tab changes the on-screen window number.
    // Retain one process-local integer on the real NSWindowTabGroup object so
    // it survives selection and closing the member that originally had the
    // smallest number.  Member associations carry the identity across a
    // native merge that replaces the tab-group object.
    id token = objc_getAssociatedObject(
        tabGroup, &MacWSLogicalWindowGroupAssociationKey);
    if (!token) {
        for (NSUInteger index = 0; index < groupCount && !token; index++) {
            token = objc_getAssociatedObject(
                [groupWindows objectAtIndex:index],
                &MacWSLogicalWindowGroupAssociationKey);
        }
    }
    // Closing the penultimate tab leaves a one-window NSWindowTabGroup. Keep
    // its established identity so a Scene following the closed member can
    // still resolve the survivor. A window that has never belonged to a tab
    // group has no token and continues to use its real window number.
    if (groupCount <= 1) {
        if (token) {
            uint32_t established = (uint32_t)((MacWSMsgUInteger)objc_msgSend)(
                token, sel_registerName("unsignedIntValue"));
            if (established != 0) return established;
        }
        return groupID;
    }
    for (NSUInteger index = 0; index < groupCount; index++) {
        id member = [groupWindows objectAtIndex:index];
        NSInteger memberNumber = ((MacWSMsgInteger)objc_msgSend)(
            member, sel_registerName("windowNumber"));
        if (memberNumber > 0 && (uint64_t)memberNumber <= UINT32_MAX &&
            (uint32_t)memberNumber < groupID)
            groupID = (uint32_t)memberNumber;
    }
    if (!token) {
        Class numberClass = objc_getClass("NSNumber");
        token = numberClass ? ((id (*)(id, SEL, unsigned int))objc_msgSend)(
            (id)numberClass, sel_registerName("numberWithUnsignedInt:"),
            groupID) : nil;
    } else {
        groupID = (uint32_t)((MacWSMsgUInteger)objc_msgSend)(
            token, sel_registerName("unsignedIntValue"));
    }
    if (token && groupID != 0) {
        objc_setAssociatedObject(tabGroup,
            &MacWSLogicalWindowGroupAssociationKey, token,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSUInteger index = 0; index < groupCount; index++) {
            objc_setAssociatedObject([groupWindows objectAtIndex:index],
                &MacWSLogicalWindowGroupAssociationKey, token,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return groupID;
}

static void MacWSNotifyDisplayCatalogChanged(uint8_t reason) {
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) return;
    struct sockaddr_un target = {0};
    target.sun_family = AF_UNIX;
    strlcpy(target.sun_path, MACWS_STREAM_INVALIDATE_SOCKET_PATH,
            sizeof(target.sun_path));
    (void)sendto(socketFD, &reason, sizeof(reason), MSG_DONTWAIT,
                 (const struct sockaddr *)&target, sizeof(target));
    close(socketFD);
}

static void MacWSNotifyDisplayGeometryChanged(uint32_t windowID, id window,
                                              CGRect appliedFrame) {
    if (windowID == 0 || !window || appliedFrame.size.width <= 0.0 ||
        appliedFrame.size.height <= 0.0) return;
    CGFloat scale = ((MacWSMsgDouble)objc_msgSend)(
        window, sel_registerName("backingScaleFactor"));
    if (!isfinite(scale) || scale <= 0.0 || scale > 8.0) return;
    uint64_t pixelWidth = (uint64_t)llround(appliedFrame.size.width * scale);
    uint64_t pixelHeight = (uint64_t)llround(appliedFrame.size.height * scale);
    if (pixelWidth == 0 || pixelHeight == 0 ||
        pixelWidth > MACWS_STREAM_MAX_DIMENSION ||
        pixelHeight > MACWS_STREAM_MAX_DIMENSION) return;
    MacWSGeometryInvalidation record = {
        .magic = MACWS_GEOMETRY_INVALIDATION_MAGIC,
        .version = MACWS_GEOMETRY_INVALIDATION_VERSION,
        .size = sizeof(record),
        .windowID = windowID,
        .pixelWidth = (uint32_t)pixelWidth,
        .pixelHeight = (uint32_t)pixelHeight,
    };
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) return;
    struct sockaddr_un target = {0};
    target.sun_family = AF_UNIX;
    strlcpy(target.sun_path, MACWS_STREAM_INVALIDATE_SOCKET_PATH,
            sizeof(target.sun_path));
    (void)sendto(socketFD, &record, sizeof(record), MSG_DONTWAIT,
                 (const struct sockaddr *)&target, sizeof(target));
    close(socketFD);
}

static void MacWSPublishWindowMetrics(void) {
    Class applicationClass = objc_getClass("NSApplication");
    if (!applicationClass || !MacWSWindowMetricsPath[0]) return;
    id application = ((MacWSMsgID)objc_msgSend)(
        (id)applicationClass, sel_registerName("sharedApplication"));
    if (!application) return;
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    id keyWindow = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow"));
    NSMutableData *entries = [NSMutableData data];
    NSUInteger count = [windows count];
    for (NSUInteger index = 0;
         index < count && entries.length / sizeof(MacWSWindowMetricsEntry) <
             MACWS_STREAM_MAX_WINDOWS;
         index++) {
        id window = [windows objectAtIndex:index];
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (number <= 0 || (uint64_t)number > UINT32_MAX) continue;
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        if (!isfinite(frame.size.width) || !isfinite(frame.size.height) ||
            frame.size.width <= 0.0 || frame.size.height <= 0.0) continue;

        BOOL resizable = NO;
        CGSize minimum = MacWSEffectiveMinimumFrameSize(
            window, frame, &resizable);
        BOOL orderedVisible = ((MacWSMsgBool)objc_msgSend)(
            window, sel_registerName("isVisible"));
        NSInteger windowLevel = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("level"));
        // `Visible` is the cross-process contract for a window that may own
        // an iPad Scene, not merely AppKit's ordered-in bit. Runtime evidence
        // for Terminal's Low Disk Space alert was exact: metrics advertised
        // window 138 as Visible while displayd observed the same CGWindow at
        // level 8 and correctly attached it as window 137's transient layer.
        // Publish only ordinary level-0 windows here; panels/alerts continue
        // through displayd's transient stream and cannot satisfy launcher
        // readiness or create their own Scene.
        BOOL visible = orderedVisible && windowLevel == 0;
        MacWSWindowMetricsEntry entry = {
            .windowID = (uint32_t)number,
            .flags = (resizable ? MacWSStreamWindowResizable : 0) |
                (visible ? MacWSStreamWindowVisible : 0) |
                (window == keyWindow ? MacWSStreamWindowFocused : 0),
            .logicalGroupID = MacWSLogicalWindowGroupID(window),
            .minimumLogicalWidth = (float)minimum.width,
            .minimumLogicalHeight = (float)minimum.height,
        };
        [entries appendBytes:&entry length:sizeof(entry)];
    }
    NSString *path = [NSString stringWithUTF8String:MacWSWindowMetricsPath];
    BOOL entriesChanged = !MacWSLastWindowMetricsEntries ||
        ![MacWSLastWindowMetricsEntries isEqualToData:entries];
    // Recover the publication if a consumer or cleanup pass removed the
    // sidecar while the AppKit window set remained unchanged.  The old early
    // return made that loss permanent for the lifetime of the application.
    if (!entriesChanged &&
        [NSFileManager.defaultManager fileExistsAtPath:path]) return;
    if (entriesChanged) {
        [MacWSLastWindowMetricsEntries release];
        MacWSLastWindowMetricsEntries = [entries copy];
    }
    MacWSWindowMetricsHeader header = {
        .magic = MACWS_WINDOW_METRICS_MAGIC,
        .version = MACWS_WINDOW_METRICS_VERSION,
        .size = sizeof(MacWSWindowMetricsHeader),
        .entrySize = sizeof(MacWSWindowMetricsEntry),
        .entryCount = (uint32_t)(entries.length /
                                 sizeof(MacWSWindowMetricsEntry)),
        .generation = ++MacWSWindowMetricsGeneration,
    };
    NSMutableData *file = [NSMutableData dataWithBytes:&header
                                                 length:sizeof(header)];
    [file appendData:entries];
    NSError *error = nil;
    BOOL written = [file writeToFile:path
                             options:NSDataWritingAtomic error:&error];
    if (!written && MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr, "#### APP-INPUT METRICS-WRITE pid=%d error=%s\n",
                getpid(), error.localizedDescription.UTF8String ?: "unknown");
        fflush(stderr);
    }
    if (written && entriesChanged)
        MacWSNotifyDisplayCatalogChanged('m');
}

static void MacWSScheduleWindowMetricsPublish(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool { MacWSPublishWindowMetrics(); }
        MacWSScheduleWindowMetricsPublish();
    });
}

static void MacWSInstallAppInputBridgeNow(void) {
    if (!MacWSAppInputSupportedProcess()) return;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &MacWSAppInputInstallState, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return;
    MacWSInstallApplicationKeyWitness();
    MacWSInstallMenuEventLoopWitness();
    MacWSInstallOrderedWindowRegistry();
    if (!MacWSOriginalApplicationSendEvent ||
        !MacWSOriginalHandleActivatedEvent)
        MacWSScheduleApplicationKeyWitnessInstall(0);
    MacWSAppInputPending = [NSMutableArray new];
    MacWSAppInputDeferredRFBMoveEvents = [NSMutableArray new];
    snprintf(MacWSAppInputPath, sizeof(MacWSAppInputPath),
             "/private/tmp/macws_app_input.%d.sock", getpid());
    snprintf(MacWSWindowMetricsPath, sizeof(MacWSWindowMetricsPath),
             "/private/tmp/macws_window_metrics.%d.bin", getpid());
    unlink(MacWSWindowMetricsPath);
    MacWSAppInputSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (MacWSAppInputSocket < 0) {
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
        return;
    }
    int inputReceiveBuffer = 512 * 1024;
    (void)setsockopt(MacWSAppInputSocket, SOL_SOCKET, SO_RCVBUF,
                     &inputReceiveBuffer, sizeof(inputReceiveBuffer));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MacWSAppInputPath, sizeof(address.sun_path));
    unlink(MacWSAppInputPath);
    if (bind(MacWSAppInputSocket, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        close(MacWSAppInputSocket);
        MacWSAppInputSocket = -1;
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
        return;
    }
    chmod(MacWSAppInputPath, 0600);
    pthread_t thread;
    if (pthread_create(&thread, NULL, MacWSAppInputThread, NULL) == 0) {
        pthread_detach(thread);
        MacWSScheduleWindowMetricsPublish();
        atomic_store_explicit(&MacWSAppInputInstallState, 2,
                              memory_order_release);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr, "#### APP-INPUT READY pid=%d socket=%s abi=%u record=%zu\n",
                    getpid(), MacWSAppInputPath, MACWS_INPUT_VERSION,
                    sizeof(MacWSInputRecord));
            fflush(stderr);
        }
    } else {
        close(MacWSAppInputSocket);
        MacWSAppInputSocket = -1;
        unlink(MacWSAppInputPath);
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
    }
}

// DYLD_INSERT_LIBRARIES constructors can precede AppKit's Objective-C class
// realization.  Runtime-confirmed with Terminal pid 67547 on 2026-07-31: the
// process displayed a real window, but the one-shot constructor observed no
// NSApplication and never created either its app-input socket or window
// metrics sidecar. Retry only after returning to the application's main queue;
// the finite ten-second window prevents a command-line process that merely
// maps AppKit from retaining a timer forever. Installation remains conditional
// on the real NSApplication class and never fabricates an AppKit endpoint.
static void MacWSScheduleAppInputBridgeInstall(unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&MacWSAppInputInstallState,
                                 memory_order_acquire) == 2) return;
        MacWSInstallAppInputBridgeNow();
        if (atomic_load_explicit(&MacWSAppInputInstallState,
                                 memory_order_acquire) != 2 &&
            attempt < 39) {
            MacWSScheduleAppInputBridgeInstall(attempt + 1);
        }
    });
}

__attribute__((constructor)) static void MacWSInstallAppInputBridge(void) {
    const char *shell_env = getenv("VSCODE_RESOLVING_ENVIRONMENT");
    if (shell_env && strcmp(shell_env, "1") == 0) return;
    MacWSInstallAppInputBridgeNow();
    if (atomic_load_explicit(&MacWSAppInputInstallState,
                             memory_order_acquire) != 2) {
        MacWSScheduleAppInputBridgeInstall(0);
    }
}

__attribute__((destructor)) static void MacWSRemoveAppInputBridge(void) {
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    MacWSAppInputRFBTrackingActive = NO;
    MacWSAppInputRFBTrackingButtons = 0;
    atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, NO,
                          memory_order_release);
    MacWSClearDirectTrackingContextLocked();
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
    MacWSSetDeferredRFBDownEvent(nil);
    MacWSClearDeferredRFBMoveEvents();
    MacWSSetAppInputGestureWindow(nil);
    MacWSSetAppInputGestureHitView(nil);
    MacWSSetLastSystemActivationEvent(nil);
    if (MacWSAppInputSocket >= 0) close(MacWSAppInputSocket);
    if (MacWSAppInputPath[0]) unlink(MacWSAppInputPath);
    if (MacWSWindowMetricsPath[0]) unlink(MacWSWindowMetricsPath);
    [MacWSLastWindowMetricsEntries release];
    MacWSLastWindowMetricsEntries = nil;
    [MacWSMenuCaches release];
    MacWSMenuCaches = nil;
    [MacWSOrderedWindowRegistry release];
    MacWSOrderedWindowRegistry = nil;
}
