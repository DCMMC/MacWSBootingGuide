// Keep this target independent of Theos's legacy vendor IOKit headers.
// Importing the modern CoreGraphics module and those headers together creates
// conflicting IOPhysicalRange definitions, so the small stable C ABI used by
// this daemon is declared here and still linked against CoreGraphics.

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "macws_host_protocol.h"

typedef uint32_t CGDirectDisplayID;
typedef uint32_t CGEventType;
typedef uint32_t CGMouseButton;
typedef uint32_t CGEventTapLocation;
typedef uint32_t CGEventField;
typedef struct { double x, y; } CGPoint;
typedef struct { double width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
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
extern void CFRelease(const void *object);

enum {
    MacWSCGEventLeftMouseDown = 1,
    MacWSCGEventLeftMouseUp = 2,
    MacWSCGEventMouseMoved = 5,
    MacWSCGEventLeftMouseDragged = 6,
    MacWSCGMouseButtonLeft = 0,
    MacWSCGHIDEventTap = 0,
    MacWSCGMouseEventClickState = 1,
};

static const char InputSocketPath[] = "/private/tmp/macws_host_input.sock";
static const char InputLockPath[] = "/private/tmp/macws_host_input.lock";
static volatile sig_atomic_t StopRequested;

static void HandleSignal(int signalNumber) {
    (void)signalNumber;
    StopRequested = 1;
}

static const char *KindName(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown: return "down";
        case MacWSInputKindTouchMove: return "move";
        case MacWSInputKindTouchUp: return "up";
        case MacWSInputKindTouchCancel: return "cancel";
        case MacWSInputKindHover: return "hover";
    }
    return "invalid";
}

static bool RecordIsValid(const MacWSInputRecord *record) {
    if (record->magic != MACWS_INPUT_MAGIC ||
        record->version != MACWS_INPUT_VERSION ||
        !isfinite(record->x) || !isfinite(record->y) ||
        record->frameWidth == 0 || record->frameHeight == 0 ||
        record->x < 0.0f || record->y < 0.0f ||
        record->x >= record->frameWidth || record->y >= record->frameHeight) {
        return false;
    }
    return record->kind >= MacWSInputKindTouchDown &&
           record->kind <= MacWSInputKindHover;
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
            return MacWSCGEventMouseMoved;
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

    CGDirectDisplayID display;
    CGRect bounds;
    size_t pixelWidth;
    size_t pixelHeight;
    ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
    fprintf(stderr,
            "MACWS-INPUT READY socket=%s abi=%u record=%zu display=%u "
            "bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu\n",
            InputSocketPath, MACWS_INPUT_VERSION, sizeof(MacWSInputRecord),
            display, bounds.origin.x, bounds.origin.y,
            bounds.size.width, bounds.size.height, pixelWidth, pixelHeight);
    fflush(stderr);

    uint64_t sequence = 0;
    bool buttonDown = false;
    while (!StopRequested) {
        MacWSInputRecord record = {0};
        ssize_t received = recv(socketFD, &record, sizeof(record), 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "MACWS-INPUT recv failed: %s\n", strerror(errno));
            break;
        }
        if (received != (ssize_t)sizeof(record) || !RecordIsValid(&record)) {
            fprintf(stderr,
                    "MACWS-INPUT REJECT bytes=%zd magic=%#x version=%u kind=%u\n",
                    received, record.magic, record.version, record.kind);
            fflush(stderr);
            continue;
        }

        // launchd can start this job before WindowServer has published its
        // display. Refresh on the first record, whenever geometry is zero,
        // and periodically so later display reconfiguration is not frozen.
        if (sequence == 0 || bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0 || (sequence % 120) == 0) {
            ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
            fprintf(stderr,
                    "MACWS-INPUT DISPLAY display=%u bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu\n",
                    display, bounds.origin.x, bounds.origin.y,
                    bounds.size.width, bounds.size.height,
                    pixelWidth, pixelHeight);
            fflush(stderr);
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
        CGEventType eventType = EventTypeForRecord(&record, &buttonDown);
        CGEventRef event = CGEventCreateMouseEvent(NULL, eventType, point,
                                                   MacWSCGMouseButtonLeft);
        bool created = event != NULL;
        CGPoint observed = {-1.0, -1.0};
        bool observedCursor = false;
        unsigned cursorSamples = 0;
        if (event) {
            if (eventType == MacWSCGEventLeftMouseDown ||
                eventType == MacWSCGEventLeftMouseUp) {
                CGEventSetIntegerValueField(event,
                    MacWSCGMouseEventClickState, 1);
            }
            CGEventPost(MacWSCGHIDEventTap, event);
            CFRelease(event);
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
        fprintf(stderr,
                "MACWS-INPUT RX seq=%llu scene=%llx kind=%s "
                "frame=(%.2f,%.2f)/%ux%u quartz=(%.2f,%.2f) event=%u "
                "created=%s post=%s cursor=%s(%.2f,%.2f) samples=%u\n",
                (unsigned long long)sequence,
                (unsigned long long)record.sceneID,
                KindName((MacWSInputKind)record.kind), record.x, record.y,
                record.frameWidth, record.frameHeight, point.x, point.y,
                eventType, created ? "YES" : "NO",
                created ? "issued" : "not-issued",
                observedCursor ? "observed" : "unavailable",
                observed.x, observed.y, cursorSamples);
        fflush(stderr);
    }

    close(socketFD);
    flock(lockFD, LOCK_UN);
    close(lockFD);
    unlink(InputSocketPath);
    fprintf(stderr, "MACWS-INPUT STOP\n");
    return 0;
}
