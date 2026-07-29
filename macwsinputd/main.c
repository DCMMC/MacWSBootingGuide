// Keep this target independent of Theos's legacy vendor IOKit headers.
// Importing the modern CoreGraphics module and those headers together creates
// conflicting IOPhysicalRange definitions, so the small stable C ABI used by
// this daemon is declared here and still linked against CoreGraphics.

#include <errno.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "macws_host_protocol.h"

typedef uint32_t CGDirectDisplayID;
typedef uint32_t CGEventType;
typedef uint32_t CGMouseButton;
typedef uint32_t CGEventTapLocation;
typedef uint32_t CGEventField;
typedef uint32_t CGWindowID;
typedef uint32_t CGWindowListOption;
typedef const void *CGEventRef;

extern CGDirectDisplayID CGMainDisplayID(void);
extern CGRect CGDisplayBounds(CGDirectDisplayID display);
extern size_t CGDisplayPixelsWide(CGDirectDisplayID display);
extern size_t CGDisplayPixelsHigh(CGDirectDisplayID display);
extern CGEventRef CGEventCreateMouseEvent(const void *source, CGEventType type,
                                         CGPoint point, CGMouseButton button);
extern CGEventRef CGEventCreate(const void *source);
extern CGPoint CGEventGetLocation(CGEventRef event);
extern void CGEventSetIntegerValueField(CGEventRef event, CGEventField field,
                                        int64_t value);
extern void CGEventPost(CGEventTapLocation tap, CGEventRef event);
extern void CGEventPostToPid(pid_t pid, CGEventRef event);
extern bool CGPreflightPostEventAccess(void);
extern CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption option,
                                             CGWindowID relativeToWindow);
extern const CFStringRef kCGWindowNumber;
extern const CFStringRef kCGWindowLayer;
extern const CFStringRef kCGWindowBounds;
extern const CFStringRef kCGWindowOwnerPID;
extern bool CGRectMakeWithDictionaryRepresentation(CFDictionaryRef dictionary,
                                                    CGRect *rect);

enum {
    MacWSCGEventLeftMouseDown = 1,
    MacWSCGEventLeftMouseUp = 2,
    MacWSCGEventRightMouseDown = 3,
    MacWSCGEventRightMouseUp = 4,
    MacWSCGEventMouseMoved = 5,
    MacWSCGEventLeftMouseDragged = 6,
    MacWSCGMouseButtonLeft = 0,
    MacWSCGMouseButtonRight = 1,
    MacWSCGHIDEventTap = 0,
    MacWSCGMouseEventClickState = 1,
    MacWSCGMouseEventButtonNumber = 3,
    MacWSCGMouseEventWindowUnderMousePointer = 91,
    MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent = 92,
    MacWSCGWindowListOptionOnScreenOnly = 1 << 0,
    MacWSCGWindowListExcludeDesktopElements = 1 << 4,
};

static const char InputSocketPath[] = "/private/tmp/macws_host_input.sock";
static const char InputLockPath[] = "/private/tmp/macws_host_input.lock";
static const char TargetSocketPath[] = "/private/tmp/macws_input_target.sock";
static const char CaptureRequestPath[] = "/tmp/macws_capture_final";
static volatile sig_atomic_t StopRequested;
static volatile sig_atomic_t InputSocketFD = -1;
static volatile sig_atomic_t TargetSocketFD = -1;
static uint64_t LastCaptureGeneration;
static uint64_t TargetProbeNonce;

static bool RuntimeDiagnosticsEnabled(void) {
    static int cached = -1;
    if (cached < 0) {
        cached = getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_runtime_diagnostics", F_OK) == 0;
    }
    return cached != 0;
}

typedef struct {
    pid_t pid;
    int32_t windowID;
    bool selectedWasActive;
    bool selectedWasFrontUIProcess;
    bool competingActiveOwner;
    bool responseIncomplete;
} MacWSWindowTarget;

static void HandleSignal(int signalNumber) {
    (void)signalNumber;
    StopRequested = 1;
    // close(2) is async-signal-safe.  Closing the descriptor here makes a
    // blocking recv(2) return even on systems where signal() installs a
    // restarting handler, so launchd stop does not leave an orphan daemon.
    int socketFD = (int)InputSocketFD;
    InputSocketFD = -1;
    if (socketFD >= 0) close(socketFD);
    int targetSocketFD = (int)TargetSocketFD;
    TargetSocketFD = -1;
    if (targetSocketFD >= 0) close(targetSocketFD);
}

static const char *KindName(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown: return "down";
        case MacWSInputKindTouchMove: return "move";
        case MacWSInputKindTouchUp: return "up";
        case MacWSInputKindTouchCancel: return "cancel";
        case MacWSInputKindHover: return "hover";
        case MacWSInputKindTap: return "tap";
        case MacWSInputKindTargetProbe: return "target-probe";
        case MacWSInputKindActivateTarget: return "activate-target";
        case MacWSInputKindDeactivateApplication: return "deactivate-app";
        case MacWSInputKindMenuHover: return "menu-hover";
        case MacWSInputKindKeyDown: return "key-down";
        case MacWSInputKindKeyUp: return "key-up";
        case MacWSInputKindSecondaryTap: return "secondary-tap";
    }
    return "invalid";
}

static bool RecordIsValid(const MacWSInputRecord *record) {
    if (record->magic != MACWS_INPUT_MAGIC ||
        record->version != MACWS_INPUT_VERSION ||
        !isfinite(record->x) || !isfinite(record->y) ||
        record->frameWidth == 0 || record->frameHeight == 0 ||
        record->x < 0.0f || record->y < 0.0f ||
        record->x >= record->frameWidth || record->y >= record->frameHeight ||
        record->targetPID < 0) {
        return false;
    }
    return record->kind >= MacWSInputKindTouchDown &&
           record->kind <= MacWSInputKindSecondaryTap;
}

static CGPoint QuartzPointForRecord(const MacWSInputRecord *record,
                                    CGRect displayBounds) {
    double normalizedX = record->x / (double)record->frameWidth;
    double normalizedY = record->y / (double)record->frameHeight;
    normalizedX = fmin(fmax(normalizedX, 0.0), 1.0);
    normalizedY = fmin(fmax(normalizedY, 0.0), 1.0);
    return (CGPoint){
        displayBounds.origin.x + normalizedX * displayBounds.size.width,
        displayBounds.origin.y + normalizedY * displayBounds.size.height,
    };
}

static CGEventType EventTypeForRecord(const MacWSInputRecord *record,
                                      bool *buttonDown) {
    switch ((MacWSInputKind)record->kind) {
        case MacWSInputKindTouchDown:
            *buttonDown = true;
            return MacWSCGEventLeftMouseDown;
        case MacWSInputKindTouchMove:
            return *buttonDown ? MacWSCGEventLeftMouseDragged
                               : MacWSCGEventMouseMoved;
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
            *buttonDown = false;
            return MacWSCGEventLeftMouseUp;
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
            return MacWSCGEventMouseMoved;
        case MacWSInputKindTap:
            return MacWSCGEventLeftMouseDown;
        case MacWSInputKindSecondaryTap:
            return MacWSCGEventRightMouseDown;
        case MacWSInputKindTargetProbe:
        case MacWSInputKindActivateTarget:
        case MacWSInputKindDeactivateApplication:
        case MacWSInputKindKeyDown:
        case MacWSInputKindKeyUp:
            // Consumed before event construction in main().
            return 0;
    }
    return 0;
}

static bool ReadCursorPoint(CGPoint *point) {
    CGEventRef stateEvent = CGEventCreate(NULL);
    if (!stateEvent) return false;
    *point = CGEventGetLocation(stateEvent);
    CFRelease(stateEvent);
    return true;
}

static void ReadDisplayGeometry(CGDirectDisplayID *display, CGRect *bounds,
                                size_t *pixelWidth, size_t *pixelHeight) {
    *display = CGMainDisplayID();
    *bounds = CGDisplayBounds(*display);
    *pixelWidth = CGDisplayPixelsWide(*display);
    *pixelHeight = CGDisplayPixelsHigh(*display);
}

static bool PointInRect(CGPoint point, CGRect rect) {
    return point.x >= rect.origin.x && point.y >= rect.origin.y &&
           point.x < rect.origin.x + rect.size.width &&
           point.y < rect.origin.y + rect.size.height;
}

// CGEventPost(kCGHIDEventTap) updates the posting process's cursor state in
// this chroot, but runtime capture proved that it does not route mouse events
// into the frontmost AppKit process. Resolve the front-to-back, layer-zero
// window containing the point and use CoreGraphics' public per-process route.
// Window bounds and input points are both in Quartz logical coordinates.
static MacWSWindowTarget WindowTargetAtPoint(CGPoint point) {
    MacWSWindowTarget target = {0};
    static unsigned probeCount;
    bool logProbe = RuntimeDiagnosticsEnabled() && probeCount++ < 2;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        MacWSCGWindowListOptionOnScreenOnly |
            MacWSCGWindowListExcludeDesktopElements,
        0);
    if (!windows) {
        if (logProbe) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-LIST point=(%.2f,%.2f) result=NULL\n",
                    point.x, point.y);
            fflush(stderr);
        }
        return target;
    }

    CFIndex count = CFArrayGetCount(windows);
    if (logProbe) {
        fprintf(stderr,
                "MACWS-INPUT TARGET-LIST point=(%.2f,%.2f) count=%ld\n",
                point.x, point.y, (long)count);
    }
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        CFNumberRef pidValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowOwnerPID);
        CFNumberRef layerValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowLayer);
        CFNumberRef windowValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowNumber);
        CFDictionaryRef boundsValue = (CFDictionaryRef)CFDictionaryGetValue(
            info, kCGWindowBounds);
        int32_t pid = 0, layer = -1, windowID = 0;
        CGRect bounds = {{0, 0}, {0, 0}};
        bool decoded = pidValue && layerValue && windowValue && boundsValue &&
            CFNumberGetValue(pidValue, kCFNumberSInt32Type, &pid) &&
            CFNumberGetValue(layerValue, kCFNumberSInt32Type, &layer) &&
            CFNumberGetValue(windowValue, kCFNumberSInt32Type, &windowID) &&
            CGRectMakeWithDictionaryRepresentation(boundsValue, &bounds);
        if (logProbe && i < 16) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-CANDIDATE index=%ld decoded=%s "
                    "pid=%d layer=%d window=%d bounds=(%.1f,%.1f %.1fx%.1f) contains=%s\n",
                    (long)i, decoded ? "YES" : "NO", pid, layer, windowID,
                    bounds.origin.x, bounds.origin.y,
                    bounds.size.width, bounds.size.height,
                    decoded && PointInRect(point, bounds) ? "YES" : "NO");
        }
        if (!decoded) {
            continue;
        }
        if (pid <= 1 || pid == getpid() || layer != 0 ||
            !PointInRect(point, bounds)) {
            continue;
        }
        target.pid = (pid_t)pid;
        target.windowID = windowID;
        break;
    }
    if (logProbe) fflush(stderr);
    CFRelease(windows);
    return target;
}

static uint64_t RealtimeNanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static bool SendToAppInputBridge(int socketFD,
                                 const MacWSInputRecord *record,
                                 int *errorOut) {
    if (record->targetPID <= 1) {
        if (errorOut) *errorOut = EDESTADDRREQ;
        return false;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    int length = snprintf(address.sun_path, sizeof(address.sun_path),
                          "/private/tmp/macws_app_input.%d.sock",
                          record->targetPID);
    if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) {
        if (errorOut) *errorOut = ENAMETOOLONG;
        return false;
    }
    bool continuous = record->kind == MacWSInputKindTouchMove ||
                      record->kind == MacWSInputKindHover ||
                      record->kind == MacWSInputKindMenuHover;
    unsigned attempts = continuous ? 1 : 8;
    ssize_t sent = -1;
    int savedError = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        sent = sendto(socketFD, record, sizeof(*record), MSG_DONTWAIT,
                      (const struct sockaddr *)&address, sizeof(address));
        if (sent == (ssize_t)sizeof(*record)) break;
        savedError = sent < 0 ? errno : EMSGSIZE;
        if (continuous) break;
        usleep((useconds_t)(1000u * (attempt + 1)));
    }
    if (errorOut) *errorOut = sent == (ssize_t)sizeof(*record)
        ? 0 : savedError;
    return sent == (ssize_t)sizeof(*record);
}

static size_t AppInputBridgePIDs(pid_t *pids, size_t capacity);

// The normal Workspace activation broadcast is absent in the chroot. A real
// native click can consequently leave both the old and new NSApplication
// reporting isActive=YES; runtime target replies then become ambiguous and the
// visible global menu bar remains owned by the old app. Send control records,
// never NSEvents, to make every non-target endpoint resign before the selected
// endpoint receives its matching activation control.
static size_t DeactivateOtherAppInputBridges(
        int socketFD, pid_t targetPID, const MacWSInputRecord *source) {
    pid_t pids[64] = {0};
    size_t discovered = AppInputBridgePIDs(pids, 64);
    size_t count = discovered < 64 ? discovered : 64;
    size_t sentCount = 0;
    for (size_t index = 0; index < count; index++) {
        if (pids[index] <= 1 || pids[index] == targetPID) continue;
        MacWSInputRecord control = *source;
        control.kind = MacWSInputKindDeactivateApplication;
        control.targetPID = pids[index];
        int error = 0;
        bool sent = SendToAppInputBridge(socketFD, &control, &error);
        if (sent) sentCount++;
        else fprintf(stderr,
                "MACWS-INPUT ACTIVATE deactivate-send pid=%d errno=%d\n",
                pids[index], error);
    }
    return sentCount;
}

static size_t AppInputBridgePIDs(pid_t *pids, size_t capacity) {
    static const char prefix[] = "macws_app_input.";
    static const char suffix[] = ".sock";
    DIR *directory = opendir("/private/tmp");
    if (!directory) return 0;
    size_t matches = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        const char *name = entry->d_name;
        size_t length = strlen(name);
        size_t prefixLength = sizeof(prefix) - 1;
        size_t suffixLength = sizeof(suffix) - 1;
        if (length <= prefixLength + suffixLength ||
            strncmp(name, prefix, prefixLength) != 0 ||
            strcmp(name + length - suffixLength, suffix) != 0) {
            continue;
        }
        char *end = NULL;
        long parsed = strtol(name + prefixLength, &end, 10);
        if (!end || strcmp(end, suffix) != 0 || parsed <= 1 ||
            parsed > INT32_MAX || kill((pid_t)parsed, 0) != 0) {
            continue;
        }
        if (matches < capacity) pids[matches] = (pid_t)parsed;
        matches++;
    }
    closedir(directory);
    return matches;
}

// Runtime-confirmed on the chroot launchd session: CGWindowListCopyWindowInfo
// returns NULL even though an AppInputBridge socket is live. When there is
// exactly one healthy AppKit endpoint, it remains an unambiguous fallback.
static pid_t SoleAppInputBridgePID(void) {
    pid_t pids[2] = {0};
    return AppInputBridgePIDs(pids, 2) == 1 ? pids[0] : 0;
}

static bool PIDInList(pid_t pid, const pid_t *pids, size_t count) {
    for (size_t index = 0; index < count; index++) {
        if (pids[index] == pid) return true;
    }
    return false;
}

// Ask every live AppKit process to hit-test on its own main thread, then send
// the real event only to the unique best reply. This is a query broadcast,
// not an event broadcast: probes cannot create NSEvents. Active/key state
// disambiguates overlapping windows; equal-ranked overlaps remain unresolved
// rather than delivering one click to multiple applications.
static MacWSWindowTarget ProbeAppInputTarget(
        int targetSocketFD, const MacWSInputRecord *record) {
    MacWSWindowTarget target = {0};
    MacWSWindowTarget activeTarget = {0};
    MacWSWindowTarget frontTarget = {0};
    if (targetSocketFD < 0 || record->frameWidth == 0 ||
        record->frameHeight == 0) return target;

    pid_t pids[64] = {0};
    size_t discovered = AppInputBridgePIDs(pids, 64);
    size_t pidCount = discovered < 64 ? discovered : 64;
    if (pidCount == 0) return target;

    // Replies from a timed-out older probe must not influence this decision.
    MacWSInputTargetReply stale;
    while (recv(targetSocketFD, &stale, sizeof(stale), MSG_DONTWAIT) > 0) {}

    uint64_t nonce = ++TargetProbeNonce;
    if (nonce == 0) nonce = ++TargetProbeNonce;
    MacWSInputTargetProbe probe = {
        .magic = MACWS_TARGET_PROBE_MAGIC,
        .version = MACWS_TARGET_VERSION,
        .size = sizeof(MacWSInputTargetProbe),
        .nonce = nonce,
        .x = record->x,
        .y = record->y,
        .frameWidth = record->frameWidth,
        .frameHeight = record->frameHeight,
    };

    size_t sentCount = 0;
    for (size_t index = 0; index < pidCount; index++) {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        int length = snprintf(address.sun_path, sizeof(address.sun_path),
                              "/private/tmp/macws_app_input.%d.sock",
                              pids[index]);
        if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) continue;
        ssize_t sent = sendto(targetSocketFD, &probe, sizeof(probe),
                              MSG_DONTWAIT,
                              (const struct sockaddr *)&address,
                              sizeof(address));
        if (sent == (ssize_t)sizeof(probe)) sentCount++;
    }
    if (sentCount == 0) return target;

    uint64_t deadline = RealtimeNanoseconds() + 150000000ull;
    size_t replies = 0;
    int bestScore = -1;
    bool ambiguous = false;
    bool activeAmbiguous = false;
    bool frontAmbiguous = false;
    while (replies < sentCount) {
        uint64_t now = RealtimeNanoseconds();
        if (now >= deadline) break;
        int remainingMilliseconds = (int)((deadline - now + 999999ull) /
                                          1000000ull);
        struct pollfd descriptor = {
            .fd = targetSocketFD,
            .events = POLLIN,
        };
        int pollResult = poll(&descriptor, 1, remainingMilliseconds);
        if (pollResult <= 0) break;
        MacWSInputTargetReply reply = {0};
        ssize_t received = recv(targetSocketFD, &reply, sizeof(reply), 0);
        if (received != sizeof(reply) ||
            reply.magic != MACWS_TARGET_REPLY_MAGIC ||
            reply.version != MACWS_TARGET_VERSION ||
            reply.size != sizeof(MacWSInputTargetReply) ||
            reply.nonce != nonce || reply.pid <= 1 ||
            !PIDInList((pid_t)reply.pid, pids, pidCount)) {
            continue;
        }
        replies++;
        static unsigned replyLogs;
        if (RuntimeDiagnosticsEnabled() && replyLogs++ < 48) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-REPLY nonce=%llu pid=%d window=%d "
                    "flags=%#x\n",
                    (unsigned long long)nonce, reply.pid,
                    reply.windowNumber, reply.flags);
        }
        if (reply.flags & MacWSInputTargetApplicationActive) {
            if (activeTarget.pid <= 1) {
                activeTarget.pid = (pid_t)reply.pid;
                activeTarget.windowID = reply.windowNumber;
                activeTarget.selectedWasActive = true;
                activeTarget.selectedWasFrontUIProcess =
                    (reply.flags & MacWSInputTargetFrontUIProcess) != 0;
            } else if (activeTarget.pid != reply.pid) {
                activeAmbiguous = true;
            }
        }
        if (reply.flags & MacWSInputTargetFrontUIProcess) {
            if (frontTarget.pid <= 1) {
                frontTarget.pid = (pid_t)reply.pid;
                frontTarget.windowID = reply.windowNumber;
                frontTarget.selectedWasActive =
                    (reply.flags & MacWSInputTargetApplicationActive) != 0;
                frontTarget.selectedWasFrontUIProcess = true;
            } else if (frontTarget.pid != reply.pid) {
                frontAmbiguous = true;
            }
        }
        if (!(reply.flags & MacWSInputTargetHit)) continue;
        int score = 0;
        if (reply.flags & MacWSInputTargetFrontUIProcess) score += 4;
        if (reply.flags & MacWSInputTargetApplicationActive) score += 2;
        if (reply.flags & MacWSInputTargetKeyWindow) score += 1;
        if (score > bestScore) {
            bestScore = score;
            target.pid = (pid_t)reply.pid;
            target.windowID = reply.windowNumber;
            target.selectedWasActive =
                (reply.flags & MacWSInputTargetApplicationActive) != 0;
            target.selectedWasFrontUIProcess =
                (reply.flags & MacWSInputTargetFrontUIProcess) != 0;
            ambiguous = false;
        } else if (score == bestScore && target.pid != reply.pid) {
            ambiguous = true;
        }
    }
    // If an endpoint missed the deadline, only an active application's hit is
    // authoritative. Otherwise a responsive covered app could steal a click
    // from an unresponsive front app.
    if (ambiguous || (replies < sentCount && bestScore < 2))
        target = (MacWSWindowTarget){0};
    // Menu-bar and contextual-menu presentation surfaces are not ordinary
    // ordered NSWindows.  Use the unique application whose real AppKit state
    // reports active when no authoritative window hit exists.  Ordinary
    // click/down routing retains the stricter hit rule; the sole exception is
    // an ActivateTarget control in the physical top 4% of the framebuffer.
    // Runtime evidence at 2388x1668 showed the native menu-bar down at y=20
    // returning no hit from either AppKit endpoint and being dropped as PID 0,
    // even though Terminal was the unique active owner.  This control record
    // carries no NSEvent and therefore only repairs ownership; OSXvnc still
    // delivers the real native menu click.
    bool systemMenuActivation =
        record->kind == MacWSInputKindActivateTarget &&
        record->frameHeight > 0 &&
        record->y >= 0.0f &&
        record->y <= (float)record->frameHeight * 0.04f;
    bool allowActiveFallback =
        record->kind == MacWSInputKindTargetProbe ||
        record->kind == MacWSInputKindHover ||
        record->kind == MacWSInputKindMenuHover ||
        record->kind == MacWSInputKindKeyDown ||
        record->kind == MacWSInputKindKeyUp ||
        systemMenuActivation;
    if (target.pid <= 1 && allowActiveFallback) {
        if (!frontAmbiguous && frontTarget.pid > 1) {
            target = frontTarget;
        } else if (!activeAmbiguous && activeTarget.pid > 1) {
            target = activeTarget;
        }
    }
    if (target.pid > 1) {
        target.competingActiveOwner = activeAmbiguous;
        // A native click may make the hit application active before a covered
        // application drains its main-thread target probe.  Runtime evidence
        // from a Terminal-over-GlassDemo switch showed nonce 1 receiving only
        // Terminal within the bounded 150-ms probe, followed immediately by
        // nonce 2 receiving both endpoints and reporting two active owners.
        // Treat an unanswered live endpoint as unresolved activation state;
        // the activation transaction will resign every non-target endpoint
        // and rebuild the selected application's real AppKit lifecycle.
        target.responseIncomplete = replies < sentCount;
    }
    static unsigned resultLogs;
    if (RuntimeDiagnosticsEnabled() && resultLogs++ < 32) {
        fprintf(stderr,
                "MACWS-INPUT TARGET-PROBE nonce=%llu endpoints=%zu sent=%zu "
                "replies=%zu selected=%d window=%d score=%d "
                "selected-active=%s selected-front=%s "
                "competing-active=%s incomplete=%s ambiguous=%s "
                "system-menu=%s\n",
                (unsigned long long)nonce, pidCount, sentCount, replies,
                target.pid, target.windowID, bestScore,
                target.selectedWasActive ? "YES" : "NO",
                target.selectedWasFrontUIProcess ? "YES" : "NO",
                target.competingActiveOwner ? "YES" : "NO",
                target.responseIncomplete ? "YES" : "NO",
                (ambiguous || activeAmbiguous || frontAmbiguous)
                    ? "YES" : "NO",
                systemMenuActivation ? "YES" : "NO");
        fflush(stderr);
    }
    return target;
}

// A native OSXvnc button-down is delivered before this control record.  The
// target AppKit main thread can therefore be inside its synchronous mouseDown
// dispatch while the first target probe is drained.  Runtime evidence from a
// Terminal-over-GlassDemo switch showed nonce 7 receiving only Terminal with
// no authoritative hit, followed immediately by nonce 8 receiving both live
// endpoints and the correct Terminal hit.  Retry only the button-triggered
// activation query; periodic hover probes must never activate an application.
static MacWSWindowTarget ProbeActivationTarget(
        int targetSocketFD, const MacWSInputRecord *record) {
    MacWSWindowTarget first = ProbeAppInputTarget(targetSocketFD, record);
    if (first.pid > 1 && !first.responseIncomplete) return first;

    usleep(10000);
    MacWSWindowTarget second = ProbeAppInputTarget(targetSocketFD, record);
    if (second.pid > 1) {
        if (RuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "MACWS-INPUT ACTIVATE-PROBE-RETRY first=%d incomplete=%s "
                "second=%d competing=%s\n",
                first.pid, first.responseIncomplete ? "YES" : "NO",
                second.pid,
                second.competingActiveOwner ? "YES" : "NO");
        fflush(stderr);
        }
        return second;
    }
    if (first.pid > 1) {
        if (RuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "MACWS-INPUT ACTIVATE-PROBE-RETRY first=%d incomplete=%s "
                "second=0 preserve-first=YES\n",
                first.pid, first.responseIncomplete ? "YES" : "NO");
        fflush(stderr);
        }
        return first;
    }
    return second;
}

// Arm one diagnostic capture for a completed gesture. Continuous PF80/PF115
// publication is responsible for live hover/drag feedback; creating/truncating
// this control file for every pointer sample previously forced up to five full
// 2388x1668 PF550 observations per second in addition to ordinary compositing.
// This remains a request for observation only: WindowServer must ACK the exact
// generation after publishing a real frame.
static uint64_t ArmCaptureForInput(const MacWSInputRecord *record) {
    if (record->kind != MacWSInputKindTouchUp &&
        record->kind != MacWSInputKindTouchCancel &&
        record->kind != MacWSInputKindTap) {
        return 0;
    }
    uint64_t generation = RealtimeNanoseconds();
    if (generation == 0) return 0;
    if (generation <= LastCaptureGeneration)
        generation = LastCaptureGeneration + 1;

    char value[48];
    int length = snprintf(value, sizeof(value), "%llu\n",
                          (unsigned long long)generation);
    int fd = open(CaptureRequestPath,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    ssize_t written = write(fd, value, (size_t)length);
    close(fd);
    if (written != length) {
        unlink(CaptureRequestPath);
        return 0;
    }
    LastCaptureGeneration = generation;
    return generation;
}

int main(void) {
    signal(SIGINT, HandleSignal);
    signal(SIGTERM, HandleSignal);

    int lockFD = open(InputLockPath, O_CREAT | O_RDWR, 0600);
    if (lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "macwsinputd singleton lock %s failed: %s\n",
                InputLockPath, strerror(errno));
        if (lockFD >= 0) close(lockFD);
        return 1;
    }

    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        fprintf(stderr, "macwsinputd socket failed: %s\n", strerror(errno));
        close(lockFD);
        return 1;
    }
    InputSocketFD = socketFD;

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    _Static_assert(sizeof(InputSocketPath) <= sizeof(address.sun_path),
                   "input socket path exceeds sockaddr_un.sun_path");
    memcpy(address.sun_path, InputSocketPath, sizeof(InputSocketPath));
    unlink(InputSocketPath);
    if (bind(socketFD, (const struct sockaddr *)&address, sizeof(address)) < 0) {
        fprintf(stderr, "macwsinputd bind %s failed: %s\n",
                InputSocketPath, strerror(errno));
        close(socketFD);
        close(lockFD);
        return 2;
    }
    if (chmod(InputSocketPath, 0666) < 0) {
        fprintf(stderr, "macwsinputd chmod %s failed: %s\n",
                InputSocketPath, strerror(errno));
    }

    int targetSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (targetSocketFD >= 0) {
        struct sockaddr_un targetAddress = {0};
        targetAddress.sun_family = AF_UNIX;
        memcpy(targetAddress.sun_path, TargetSocketPath,
               sizeof(TargetSocketPath));
        unlink(TargetSocketPath);
        if (bind(targetSocketFD,
                 (const struct sockaddr *)&targetAddress,
                 sizeof(targetAddress)) < 0) {
            fprintf(stderr, "macwsinputd bind %s failed: %s\n",
                    TargetSocketPath, strerror(errno));
            close(targetSocketFD);
            targetSocketFD = -1;
        } else if (chmod(TargetSocketPath, 0666) < 0) {
            fprintf(stderr, "macwsinputd chmod %s failed: %s\n",
                    TargetSocketPath, strerror(errno));
        }
    } else {
        fprintf(stderr, "macwsinputd target socket failed: %s\n",
                strerror(errno));
    }
    TargetSocketFD = targetSocketFD;

    CGDirectDisplayID display;
    CGRect bounds;
    size_t pixelWidth;
    size_t pixelHeight;
    ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
    fprintf(stderr,
            "MACWS-INPUT READY socket=%s abi=%u record=%zu display=%u "
            "bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu postAccess=%s "
            "targetSocket=%s\n",
            InputSocketPath, MACWS_INPUT_VERSION, sizeof(MacWSInputRecord),
            display, bounds.origin.x, bounds.origin.y,
            bounds.size.width, bounds.size.height, pixelWidth, pixelHeight,
            CGPreflightPostEventAccess() ? "YES" : "NO",
            targetSocketFD >= 0 ? "READY" : "UNAVAILABLE");
    fflush(stderr);

    uint64_t sequence = 0;
    bool buttonDown = false;
    MacWSWindowTarget gestureTarget = {0};
    MacWSWindowTarget hoverTarget = {0};
    // A native menu enters a synchronous event loop in the selected process,
    // so later target probes cannot be serviced until the menu closes.  Keep
    // the authoritative target resolved for the real button-down; OSXvnc only
    // emits MenuHover during its bounded native-menu candidate lifetime.
    MacWSWindowTarget menuTarget = {0};
    while (!StopRequested) {
        MacWSInputRecord record = {0};
        ssize_t received = recv(socketFD, &record, sizeof(record), 0);
        if (received < 0) {
            // SIGTERM closes InputSocketFD to wake this blocking recv.  EBADF
            // is the expected half of that shutdown handshake, not a receiver
            // failure worth surfacing to the App's diagnostics.
            if (StopRequested || errno == EBADF) break;
            if (errno == EINTR) continue;
            fprintf(stderr, "MACWS-INPUT recv failed: %s\n", strerror(errno));
            break;
        }
        if (received != (ssize_t)sizeof(record) || !RecordIsValid(&record)) {
            fprintf(stderr,
                    "MACWS-INPUT REJECT bytes=%zd magic=%#x version=%u "
                    "kind=%u point=(%.3f,%.3f) frame=%ux%u target=%d "
                    "finite=%s\n",
                    received, record.magic, record.version, record.kind,
                    record.x, record.y, record.frameWidth,
                    record.frameHeight, record.targetPID,
                    (isfinite(record.x) && isfinite(record.y))
                        ? "YES" : "NO");
            fflush(stderr);
            continue;
        }

        // launchd can start this job before WindowServer has published its
        // display. Refresh on the first record, whenever geometry is zero,
        // and periodically so later display reconfiguration is not frozen.
        if (sequence == 0 || bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0 || (sequence % 120) == 0) {
            ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                        "MACWS-INPUT DISPLAY display=%u bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu\n",
                        display, bounds.origin.x, bounds.origin.y,
                        bounds.size.width, bounds.size.height,
                        pixelWidth, pixelHeight);
                fflush(stderr);
            }
        }
        if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
            fprintf(stderr,
                    "MACWS-INPUT DROP reason=no-display scene=%llx kind=%s frame=(%.2f,%.2f)/%ux%u\n",
                    (unsigned long long)record.sceneID,
                    KindName((MacWSInputKind)record.kind), record.x, record.y,
                    record.frameWidth, record.frameHeight);
            fflush(stderr);
            continue;
        }

        CGPoint point = QuartzPointForRecord(&record, bounds);
        if (record.kind == MacWSInputKindTargetProbe) {
            hoverTarget = ProbeAppInputTarget(targetSocketFD, &record);
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                        "MACWS-INPUT HOVER-OWNER seq=%llu pid=%d window=%d "
                        "frame=(%.2f,%.2f)/%ux%u quartz=(%.2f,%.2f)\n",
                        (unsigned long long)sequence,
                        hoverTarget.pid, hoverTarget.windowID,
                        record.x, record.y, record.frameWidth,
                        record.frameHeight, point.x, point.y);
                fflush(stderr);
            }
            continue;
        }
        CGEventType eventType = EventTypeForRecord(&record, &buttonDown);
        MacWSWindowTarget eventTarget = {0};
        bool keyRecord = record.kind == MacWSInputKindKeyDown ||
                         record.kind == MacWSInputKindKeyUp;
        if (keyRecord && menuTarget.pid > 1) {
            // ActivateTarget is resolved before the authoritative native
            // mouse-down and remains the front application target after the
            // menu candidate ends.  Keyboard focus follows that application,
            // including while its AppKit main thread is inside a nested menu
            // loop and cannot answer another target probe.
            eventTarget = menuTarget;
        } else if (record.kind == MacWSInputKindSecondaryTap &&
                   menuTarget.pid > 1) {
            // OSXvnc resolves and activates the hit owner on right-button
            // down, then emits the atomic tap on release. Reuse that exact
            // owner instead of starting a second main-thread probe just as
            // the application is about to enter its contextual-menu loop.
            eventTarget = menuTarget;
        } else if (keyRecord && hoverTarget.pid > 1) {
            eventTarget = hoverTarget;
        } else if (record.kind == MacWSInputKindMenuHover &&
            menuTarget.pid > 1) {
            eventTarget = menuTarget;
        } else if ((record.kind == MacWSInputKindHover ||
                    record.kind == MacWSInputKindMenuHover) &&
            hoverTarget.pid > 1) {
            eventTarget = hoverTarget;
        } else if (record.kind == MacWSInputKindActivateTarget) {
            // Window content requires an authoritative hit.  The target probe
            // itself recognizes the system menu-bar surface, which has no
            // ordinary NSWindow, and may select its unique active owner.
            eventTarget = ProbeActivationTarget(targetSocketFD, &record);
        } else if (record.kind != MacWSInputKindHover &&
            record.kind != MacWSInputKindMenuHover &&
            record.kind != MacWSInputKindTap && gestureTarget.pid > 1) {
            eventTarget = gestureTarget;
        } else if (record.targetPID > 1) {
            eventTarget.pid = record.targetPID;
            if (record.kind == MacWSInputKindTouchDown)
                gestureTarget = eventTarget;
        } else {
            eventTarget = WindowTargetAtPoint(point);
            if (eventTarget.pid <= 1) {
                if (record.kind == MacWSInputKindTouchDown ||
                    record.kind == MacWSInputKindTap ||
                    record.kind == MacWSInputKindSecondaryTap || keyRecord) {
                    eventTarget = ProbeAppInputTarget(targetSocketFD, &record);
                } else if ((record.kind == MacWSInputKindHover ||
                            record.kind == MacWSInputKindMenuHover) &&
                           hoverTarget.pid <= 1) {
                    // Recover if the cached endpoint exited between periodic
                    // target refreshes. Probe records themselves never enter
                    // an application's event stream.
                    eventTarget = ProbeAppInputTarget(targetSocketFD, &record);
                    hoverTarget = eventTarget;
                }
            }
            if (eventTarget.pid <= 1) {
                eventTarget.pid = SoleAppInputBridgePID();
            }
            if (record.kind == MacWSInputKindTouchDown)
                gestureTarget = eventTarget;
        }
        if (record.kind == MacWSInputKindActivateTarget)
            menuTarget = eventTarget;
        uint64_t captureGeneration = ArmCaptureForInput(&record);
        // WindowTargetAtPoint resolves targetPID=0 producers (including RFB)
        // to an actual layer-zero AppKit window. Send that resolved PID on the
        // wire; passing the original zero-valued record made
        // SendToAppInputBridge reject it before sendto(2).
        MacWSInputRecord routedRecord = record;
        routedRecord.targetPID = eventTarget.pid;
        size_t deactivated = 0;
        bool activationRepairNeeded =
            record.kind == MacWSInputKindActivateTarget &&
            eventTarget.pid > 1 &&
            (!eventTarget.selectedWasActive ||
             !eventTarget.selectedWasFrontUIProcess ||
             eventTarget.competingActiveOwner ||
             eventTarget.responseIncomplete);
        // A freshly launched application can visibly own the system menu bar
        // while HIToolbox's long-lived menu presentation has not recalculated
        // its root menu under that ownership.  A top-bar down therefore needs
        // a control-plane preflight even when the target already reports both
        // active and front.  The target process runs its real SetRootMenu /
        // RecalcBar path before OSXvnc posts the native down; no mouse NSEvent
        // is synthesized here.  Do not deactivate other applications for this
        // already-consistent case.
        bool systemMenuPreflightNeeded =
            record.kind == MacWSInputKindActivateTarget &&
            eventTarget.pid > 1 && record.frameHeight > 0 &&
            record.y >= 0.0f &&
            record.y <= (float)record.frameHeight * 0.04f;
        if (activationRepairNeeded) {
            deactivated = DeactivateOtherAppInputBridges(
                socketFD, eventTarget.pid, &record);
        }
        int appBridgeError = 0;
        bool appBridgeAttempted =
            record.kind != MacWSInputKindActivateTarget ||
            activationRepairNeeded || systemMenuPreflightNeeded;
        bool appBridgeSent = appBridgeAttempted &&
            SendToAppInputBridge(socketFD, &routedRecord, &appBridgeError);
        if ((record.kind == MacWSInputKindHover ||
             record.kind == MacWSInputKindMenuHover) &&
            !appBridgeSent &&
            eventTarget.pid == hoverTarget.pid) {
            hoverTarget = (MacWSWindowTarget){0};
        }
        if (record.kind == MacWSInputKindMenuHover &&
            !appBridgeSent && eventTarget.pid == menuTarget.pid) {
            menuTarget = (MacWSWindowTarget){0};
        }
        if (record.kind == MacWSInputKindActivateTarget ||
            record.kind == MacWSInputKindDeactivateApplication) {
            sequence++;
            if (RuntimeDiagnosticsEnabled()) fprintf(stderr,
                    "MACWS-INPUT ACTIVATE seq=%llu kind=%s target=%d "
                    "window=%d repair=%s menu-preflight=%s deactivated=%zu "
                    "sent=%s errno=%d\n",
                    (unsigned long long)sequence,
                    KindName((MacWSInputKind)record.kind),
                    eventTarget.pid, eventTarget.windowID,
                    activationRepairNeeded ? "YES" : "NO",
                    systemMenuPreflightNeeded ? "YES" : "NO", deactivated,
                    !appBridgeAttempted ? "SKIPPED" :
                        (appBridgeSent ? "YES" : "NO"), appBridgeError);
            if (RuntimeDiagnosticsEnabled()) fflush(stderr);
            continue;
        }
        if (keyRecord) {
            // The chroot's global CG keyboard route is the failed transport
            // that this record replaces.  A key is meaningful only inside an
            // AppKit application, so never reinterpret eventType=0 as a mouse
            // event when target selection or the per-app socket is absent.
            sequence++;
            if (RuntimeDiagnosticsEnabled()) fprintf(stderr,
                    "MACWS-INPUT KEY seq=%llu kind=%s target=%d "
                    "keycode=%.0f keysym=%#x modifiers=%#llx sent=%s errno=%d\n",
                    (unsigned long long)sequence,
                    KindName((MacWSInputKind)record.kind), eventTarget.pid,
                    record.pressure, record.contactID,
                    (unsigned long long)(record.sceneID & 0xffffffffull),
                    appBridgeSent ? "YES" : "NO", appBridgeError);
            if (RuntimeDiagnosticsEnabled()) fflush(stderr);
            continue;
        }
        CGMouseButton mouseButton =
            record.kind == MacWSInputKindSecondaryTap
                ? MacWSCGMouseButtonRight : MacWSCGMouseButtonLeft;
        CGEventRef event = appBridgeSent ? NULL :
            CGEventCreateMouseEvent(NULL, eventType, point, mouseButton);
        bool created = event != NULL;
        CGPoint observed = {-1.0, -1.0};
        bool observedCursor = false;
        unsigned cursorSamples = 0;
        if (event) {
            if (eventType == MacWSCGEventLeftMouseDown ||
                eventType == MacWSCGEventLeftMouseUp ||
                eventType == MacWSCGEventRightMouseDown ||
                eventType == MacWSCGEventRightMouseUp) {
                CGEventSetIntegerValueField(event,
                    MacWSCGMouseEventClickState, 1);
            }
            CGEventSetIntegerValueField(event,
                MacWSCGMouseEventButtonNumber, mouseButton);
            if (eventTarget.pid > 1) {
                if (eventTarget.windowID > 0) {
                    CGEventSetIntegerValueField(event,
                        MacWSCGMouseEventWindowUnderMousePointer,
                        eventTarget.windowID);
                    CGEventSetIntegerValueField(event,
                        MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                        eventTarget.windowID);
                }
                CGEventPostToPid(eventTarget.pid, event);
            } else {
                CGEventPost(MacWSCGHIDEventTap, event);
            }
            CFRelease(event);
            if (record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap) {
                CGEventRef upEvent = CGEventCreateMouseEvent(
                    NULL,
                    record.kind == MacWSInputKindSecondaryTap
                        ? MacWSCGEventRightMouseUp
                        : MacWSCGEventLeftMouseUp,
                    point, mouseButton);
                if (upEvent) {
                    CGEventSetIntegerValueField(upEvent,
                        MacWSCGMouseEventClickState, 1);
                    CGEventSetIntegerValueField(upEvent,
                        MacWSCGMouseEventButtonNumber,
                        mouseButton);
                    if (eventTarget.pid > 1) {
                        if (eventTarget.windowID > 0) {
                            CGEventSetIntegerValueField(upEvent,
                                MacWSCGMouseEventWindowUnderMousePointer,
                                eventTarget.windowID);
                            CGEventSetIntegerValueField(upEvent,
                                MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                eventTarget.windowID);
                        }
                        CGEventPostToPid(eventTarget.pid, upEvent);
                    } else {
                        CGEventPost(MacWSCGHIDEventTap, upEvent);
                    }
                    CFRelease(upEvent);
                }
            }
            unsigned sampleLimit =
                record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC ? 21 : 1;
            for (unsigned sample = 0; sample < sampleLimit; sample++) {
                if (sample > 0) usleep(5000);
                observedCursor = ReadCursorPoint(&observed);
                cursorSamples++;
                if (!observedCursor || sampleLimit == 1 ||
                    (fabs(observed.x - point.x) <= 0.5 &&
                     fabs(observed.y - point.y) <= 0.5)) {
                    break;
                }
            }
        }
        sequence++;
        bool continuous = record.kind == MacWSInputKindTouchMove ||
                          record.kind == MacWSInputKindHover ||
                          record.kind == MacWSInputKindMenuHover;
        if (RuntimeDiagnosticsEnabled() &&
            (!continuous || (sequence % 60) == 0)) {
            fprintf(stderr,
                    "MACWS-INPUT RX seq=%llu scene=%llx kind=%s "
                    "target=%d frame=(%.2f,%.2f)/%ux%u quartz=(%.2f,%.2f) event=%u "
                    "created=%s post=%s route_errno=%d cursor=%s(%.2f,%.2f) samples=%u capture=%llu\n",
                    (unsigned long long)sequence,
                    (unsigned long long)record.sceneID,
                    KindName((MacWSInputKind)record.kind), record.targetPID,
                    record.x, record.y,
                    record.frameWidth, record.frameHeight, point.x, point.y,
                    eventType, created ? "YES" : "NO",
                    appBridgeSent || created ? "issued" : "not-issued",
                    appBridgeError,
                    observedCursor ? "observed" : "unavailable",
                    observed.x, observed.y, cursorSamples,
                    (unsigned long long)captureGeneration);
            fprintf(stderr,
                    "MACWS-INPUT ROUTE seq=%llu route=%s pid=%d window=%d\n",
                    (unsigned long long)sequence,
                    appBridgeSent ? "appkit-socket" :
                        (eventTarget.pid > 1 ? "target-pid" : "global-fallback"),
                    eventTarget.pid, eventTarget.windowID);
            fflush(stderr);
        }
        if (record.kind == MacWSInputKindTouchUp ||
            record.kind == MacWSInputKindTouchCancel ||
            record.kind == MacWSInputKindTap ||
            record.kind == MacWSInputKindSecondaryTap) {
            gestureTarget = (MacWSWindowTarget){0};
        }
    }

    if (InputSocketFD >= 0) {
        close((int)InputSocketFD);
        InputSocketFD = -1;
    }
    if (TargetSocketFD >= 0) {
        close((int)TargetSocketFD);
        TargetSocketFD = -1;
    }
    flock(lockFD, LOCK_UN);
    close(lockFD);
    unlink(InputSocketPath);
    unlink(TargetSocketPath);
    fprintf(stderr, "MACWS-INPUT STOP\n");
    return 0;
}
