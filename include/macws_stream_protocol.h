#ifndef MACWS_STREAM_PROTOCOL_H
#define MACWS_STREAM_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The display service is owned by a macOS process launched through
// launchdchrootexec.  MacWSHost consumes it from the iOS side.  Keep every
// message self-describing: the two processes are built against different SDKs
// and can temporarily be on different package revisions during development.
#define MACWS_STREAM_SERVICE "com.macwsguide.display"
#define MACWS_STREAM_INVALIDATE_SOCKET_PATH \
    "/private/tmp/macws_display_invalidate.sock"
#define MACWS_STREAM_MAGIC 0x4d575354u /* "MWST" */
// Version 5 makes the layer_removed stream/sequence cutoff mandatory.  A v4
// displayd only sent the CGWindow ID, so a newer Host could permanently
// tombstone a still-live capture stream when Mission Control temporarily
// removed and then restored an application window.  Keep this as a hard wire
// compatibility boundary: silently pairing a v5 Host with a stale v4 daemon
// recreates the "only the focused app remains" failure.
#define MACWS_STREAM_VERSION 5u

#define MACWS_STREAM_MAX_DIMENSION 16384u
#define MACWS_STREAM_MAX_BYTES_PER_ROW (MACWS_STREAM_MAX_DIMENSION * 16u)
#define MACWS_STREAM_MAX_WINDOWS 256u
#define MACWS_STREAM_MAX_DAMAGE_RECTS 64u
#define MACWS_WINDOW_METRICS_MAGIC 0x4d57474du /* "MWGM" */
#define MACWS_WINDOW_METRICS_VERSION 2u
#define MACWS_GEOMETRY_INVALIDATION_MAGIC 0x4d574749u /* "MWGI" */
#define MACWS_GEOMETRY_INVALIDATION_VERSION 1u

#define MACWS_STREAM_KEY_OP "op"
#define MACWS_STREAM_KEY_EVENT "event"
#define MACWS_STREAM_KEY_PROTOCOL_VERSION "protocol_version"
#define MACWS_STREAM_KEY_MODE "mode"
#define MACWS_STREAM_KEY_WINDOW_ID "window_id"
#define MACWS_STREAM_KEY_LAYER_WINDOW_ID "layer_window_id"
#define MACWS_STREAM_KEY_STREAM_ID "stream_id"
#define MACWS_STREAM_KEY_SEQUENCE "sequence"
#define MACWS_STREAM_KEY_DESCRIPTOR "descriptor"
#define MACWS_STREAM_KEY_WINDOWS "windows"
#define MACWS_STREAM_KEY_SURFACE_PORT "surface_port"
#define MACWS_STREAM_KEY_SURFACE_ID "surface_id"
#define MACWS_STREAM_KEY_DAMAGE_RECTS "damage_rects"
#define MACWS_STREAM_KEY_LEASE_TOKEN "lease_token"
#define MACWS_STREAM_KEY_MESSAGE "message"
#define MACWS_STREAM_KEY_OK "ok"

#define MACWS_STREAM_OP_HELLO "hello"
#define MACWS_STREAM_OP_LIST_WINDOWS "list_windows"
#define MACWS_STREAM_OP_SUBSCRIBE "subscribe"
#define MACWS_STREAM_OP_UNSUBSCRIBE "unsubscribe"
#define MACWS_STREAM_OP_RELEASE_FRAME "release_frame"

#define MACWS_STREAM_EVENT_READY "ready"
#define MACWS_STREAM_EVENT_WINDOWS "windows"
#define MACWS_STREAM_EVENT_FRAME "frame"
#define MACWS_STREAM_EVENT_LAYER_REMOVED "layer_removed"
#define MACWS_STREAM_EVENT_STOPPED "stopped"
#define MACWS_STREAM_EVENT_ERROR "error"

typedef uint32_t MacWSStreamMode;
enum {
    // One iPadOS scene presents the complete macOS display.  This is the
    // replacement for the native Host's use of an RFB/full-frame snapshot.
    MacWSStreamModeFullscreen = 1,
    // One iPadOS scene is bound to exactly one SkyLight window number.
    MacWSStreamModeWindow = 2,
};

typedef uint32_t MacWSStreamWindowFlags;
enum {
    MacWSStreamWindowVisible = 1u << 0,
    MacWSStreamWindowOnScreen = 1u << 1,
    MacWSStreamWindowHasShadow = 1u << 2,
    MacWSStreamWindowResizable = 1u << 3,
    MacWSStreamWindowMenuBar = 1u << 4,
    MacWSStreamWindowTransient = 1u << 5,
    MacWSStreamWindowFocused = 1u << 6,
};

typedef uint32_t MacWSStreamFrameFlags;
enum {
    MacWSStreamFrameComplete = 1u << 0,
    MacWSStreamFrameHasDamage = 1u << 1,
    MacWSStreamFrameSizeChanged = 1u << 2,
    MacWSStreamFrameOccluded = 1u << 3,
    MacWSStreamFrameOverlay = 1u << 4,
    // The captured layer belongs to a non-AppKit global input owner such as
    // Dock. Host must preserve desktop coordinates and route through that
    // process's CGS endpoint even when its AppInput socket is present.
    MacWSStreamFrameGlobalSystemSurface = 1u << 5,
    // Visual-only system layers (currently the real WindowServer cursor)
    // participate in Metal composition but must never become the hit-test
    // owner for a touch at the cursor's own position.
    MacWSStreamFrameInputPassthrough = 1u << 6,
};

// Title bytes immediately follow this descriptor in a window-list item.  The
// title is UTF-8 and is not NUL-terminated on the wire.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t windowID;
    int32_t ownerPID;
    uint32_t flags;
    // Stable identity for one user-visible AppKit window group.  AppKit tabs
    // are separate NSWindow/CGWindow objects and selecting a tab changes the
    // on-screen window number.  All members of a tab group publish the same
    // nonzero ID so an iPadOS Scene can follow that native identity change.
    uint32_t logicalGroupID;
    float logicalX;
    float logicalY;
    float logicalWidth;
    float logicalHeight;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
    float minimumLogicalWidth;
    float minimumLogicalHeight;
    float backingScale;
    uint32_t titleLength;
} MacWSStreamWindowDescriptor;

// The IOSurface itself is transported separately as a Mach send right.  Its
// global IOSurfaceID is included only as a compatibility fallback and must be
// validated against this descriptor before creating a Metal texture.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t streamID;
    uint32_t windowID;
    uint32_t flags;
    uint64_t leaseToken;
    uint64_t sequence;
    uint64_t displayTime;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    float backingScale;
    uint32_t damageRectCount;
    // Select the useful pixel rectangle in this exact-window IOSurface. The
    // current SkyLight producer uses the complete surface; keeping the fields
    // explicit makes padding/plane changes forward-compatible without changing
    // input or Scene geometry.
    uint32_t contentX;
    uint32_t contentY;
    uint32_t contentWidth;
    uint32_t contentHeight;
    // Every Scene has one base layer and zero or more SkyLight window layers.
    // A window Scene attaches its AppKit-owned transients; a fullscreen Scene
    // attaches the visible desktop window catalog over a Retina IOSurface
    // canvas. Each is transported as its own native window IOSurface and
    // composed by Host Metal. destination* is expressed in base backing pixels.
    uint32_t layerWindowID;
    // Fullscreen input must follow the same graph that Host composites.
    // SkyLight's independent global routing order can disagree after captured
    // windows have been repositioned, so carry the actual layer owner too.
    int32_t layerOwnerPID;
    int32_t layerLevel;
    int32_t destinationX;
    int32_t destinationY;
    uint32_t destinationWidth;
    uint32_t destinationHeight;
} MacWSStreamFrameDescriptor;

// A layer-removed event carries the exact producer stream and the last frame
// sequence detached from Host. displayd may keep that CGDisplayStream alive
// during its five-second reuse grace and explicitly republish the retained
// IOSurface if the same SkyLight window returns. In that case a higher
// sequence from the same stream is authoritative; an older/equal sequence is
// a delayed pre-removal frame and must remain rejected. A zero cutoff is the
// compatibility form from an older producer and cannot prove same-stream
// return, so only a different stream generation may clear it.
static inline bool MacWSStreamFrameSupersedesLayerRemoval(
        uint64_t frameStreamID, uint64_t frameSequence,
        uint64_t removedStreamID, uint64_t removedThroughSequence) {
    if (removedStreamID == 0 || frameStreamID != removedStreamID) return true;
    return removedThroughSequence != 0 &&
           frameSequence > removedThroughSequence;
}

// Map a point in the fullscreen desktop canvas into one captured layer.  A
// continuous gesture must use the descriptor captured at its Begin boundary:
// the window's live destination changes while WindowServer drags it, and
// feeding that new destination into the next sample subtracts the displacement
// that the preceding sample just applied.
static inline bool MacWSStreamMapDesktopPointToLayer(
    const MacWSStreamFrameDescriptor *descriptor, float desktopX,
    float desktopY, float *layerX, float *layerY) {
    if (!descriptor || !layerX || !layerY ||
        descriptor->destinationWidth == 0 ||
        descriptor->destinationHeight == 0 ||
        descriptor->contentWidth == 0 || descriptor->contentHeight == 0) {
        return false;
    }
    double u = (desktopX - descriptor->destinationX) /
        (double)descriptor->destinationWidth;
    double v = (desktopY - descriptor->destinationY) /
        (double)descriptor->destinationHeight;
    if (u < 0.0) u = 0.0;
    if (u > 0.999999) u = 0.999999;
    if (v < 0.0) v = 0.0;
    if (v > 0.999999) v = 0.999999;
    *layerX = descriptor->contentX + (float)(u * descriptor->contentWidth);
    *layerY = descriptor->contentY + (float)(v * descriptor->contentHeight);
    return true;
}

typedef struct __attribute__((packed)) {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
} MacWSStreamDamageRect;

// AppInputBridge sends this datagram only after AppKit has accepted a real
// NSWindow geometry change. Carry the committed target in pixels so displayd
// does not race an asynchronously updated CGWindow catalog when deciding
// whether an exact-window DisplayStream must be recreated.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t windowID;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
} MacWSGeometryInvalidation;

static inline bool MacWSGeometryInvalidationIsValid(
    const MacWSGeometryInvalidation *record, size_t byteCount) {
    return record && byteCount == sizeof(*record) &&
        record->magic == MACWS_GEOMETRY_INVALIDATION_MAGIC &&
        record->version == MACWS_GEOMETRY_INVALIDATION_VERSION &&
        record->size == sizeof(*record) && record->windowID != 0 &&
        record->pixelWidth != 0 && record->pixelHeight != 0 &&
        record->pixelWidth <= MACWS_STREAM_MAX_DIMENSION &&
        record->pixelHeight <= MACWS_STREAM_MAX_DIMENSION;
}

// AppInputBridge publishes this small per-process sidecar under
// /private/tmp/macws_window_metrics.<pid>.bin. macwsdisplayd reads it only
// while building the window catalog; it is never on the per-frame path.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t entrySize;
    uint32_t entryCount;
    uint64_t generation;
} MacWSWindowMetricsHeader;

typedef struct __attribute__((packed)) {
    uint32_t windowID;
    uint32_t flags;
    uint32_t logicalGroupID;
    float minimumLogicalWidth;
    float minimumLogicalHeight;
} MacWSWindowMetricsEntry;

static inline bool MacWSWindowMetricsAreValid(
    const MacWSWindowMetricsHeader *header, size_t byteCount) {
    if (!header || header->magic != MACWS_WINDOW_METRICS_MAGIC ||
        header->version != MACWS_WINDOW_METRICS_VERSION ||
        header->size != sizeof(*header) ||
        header->entrySize != sizeof(MacWSWindowMetricsEntry) ||
        header->entryCount > MACWS_STREAM_MAX_WINDOWS ||
        header->generation == 0) return false;
    size_t entriesSize =
        (size_t)header->entryCount * sizeof(MacWSWindowMetricsEntry);
    return entriesSize <= SIZE_MAX - sizeof(*header) &&
        byteCount == sizeof(*header) + entriesSize;
}

static inline bool MacWSStreamWindowDescriptorIsValid(
    const MacWSStreamWindowDescriptor *descriptor, size_t byteCount) {
    if (!descriptor || byteCount < sizeof(*descriptor) ||
        descriptor->magic != MACWS_STREAM_MAGIC ||
        descriptor->version != MACWS_STREAM_VERSION ||
        descriptor->size != sizeof(*descriptor) ||
        descriptor->windowID == 0 || descriptor->ownerPID <= 0 ||
        descriptor->logicalWidth <= 0.0f ||
        descriptor->logicalHeight <= 0.0f ||
        descriptor->pixelWidth == 0 || descriptor->pixelHeight == 0 ||
        descriptor->pixelWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->pixelHeight > MACWS_STREAM_MAX_DIMENSION ||
        !(descriptor->minimumLogicalWidth >= 0.0f) ||
        !(descriptor->minimumLogicalHeight >= 0.0f) ||
        descriptor->minimumLogicalWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->minimumLogicalHeight > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->backingScale <= 0.0f ||
        descriptor->backingScale > 8.0f) {
        return false;
    }
    return descriptor->titleLength <= byteCount - sizeof(*descriptor);
}

static inline bool MacWSStreamFrameDescriptorIsValid(
    const MacWSStreamFrameDescriptor *descriptor, size_t byteCount) {
    if (!descriptor || byteCount != sizeof(*descriptor) ||
        descriptor->magic != MACWS_STREAM_MAGIC ||
        descriptor->version != MACWS_STREAM_VERSION ||
        descriptor->size != sizeof(*descriptor) ||
        descriptor->streamID == 0 || descriptor->leaseToken == 0 ||
        descriptor->sequence == 0 || descriptor->width == 0 ||
        descriptor->height == 0 ||
        descriptor->width > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->height > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->bytesPerRow < descriptor->width * 4u ||
        descriptor->bytesPerRow > MACWS_STREAM_MAX_BYTES_PER_ROW ||
        descriptor->backingScale <= 0.0f ||
        descriptor->backingScale > 8.0f ||
        descriptor->damageRectCount > MACWS_STREAM_MAX_DAMAGE_RECTS ||
        descriptor->contentWidth == 0 || descriptor->contentHeight == 0 ||
        descriptor->contentX > descriptor->width ||
        descriptor->contentY > descriptor->height ||
        descriptor->contentWidth > descriptor->width - descriptor->contentX ||
        descriptor->contentHeight > descriptor->height - descriptor->contentY ||
        descriptor->layerWindowID == 0 ||
        descriptor->destinationWidth == 0 ||
        descriptor->destinationHeight == 0 ||
        descriptor->destinationWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationHeight > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationX < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationY < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationX > (int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationY > (int32_t)MACWS_STREAM_MAX_DIMENSION) {
        return false;
    }
    return (uint64_t)descriptor->bytesPerRow * descriptor->height <= SIZE_MAX;
}

#if defined(__cplusplus)
static_assert(sizeof(MacWSStreamWindowDescriptor) == 64,
              "MacWS window descriptor ABI");
static_assert(sizeof(MacWSStreamFrameDescriptor) == 116,
              "MacWS frame descriptor ABI");
static_assert(sizeof(MacWSStreamDamageRect) == 16,
              "MacWS damage rect ABI");
static_assert(sizeof(MacWSGeometryInvalidation) == 20,
              "MacWS geometry invalidation ABI");
static_assert(sizeof(MacWSWindowMetricsHeader) == 24,
              "MacWS window metrics header ABI");
static_assert(sizeof(MacWSWindowMetricsEntry) == 20,
              "MacWS window metrics entry ABI");
#else
_Static_assert(sizeof(MacWSStreamWindowDescriptor) == 64,
               "MacWS window descriptor ABI");
_Static_assert(sizeof(MacWSStreamFrameDescriptor) == 116,
               "MacWS frame descriptor ABI");
_Static_assert(sizeof(MacWSStreamDamageRect) == 16,
               "MacWS damage rect ABI");
_Static_assert(sizeof(MacWSGeometryInvalidation) == 20,
               "MacWS geometry invalidation ABI");
_Static_assert(sizeof(MacWSWindowMetricsHeader) == 24,
               "MacWS window metrics header ABI");
_Static_assert(sizeof(MacWSWindowMetricsEntry) == 20,
               "MacWS window metrics entry ABI");
#endif

#endif
