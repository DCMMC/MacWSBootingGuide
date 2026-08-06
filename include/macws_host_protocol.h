#ifndef MACWS_HOST_PROTOCOL_H
#define MACWS_HOST_PROTOCOL_H

#include <stdint.h>

#define MACWS_FRAME_MAGIC 0x564e4346u /* "VNCF" */
#define MACWS_INPUT_MAGIC 0x4d574556u /* "MWEV" */
#define MACWS_INPUT_VERSION 4u
#define MACWS_INPUT_CONTACT_DIAGNOSTIC 0x44494147u /* "DIAG" */
#define MACWS_INPUT_WINDOW_SCENE_FLAG UINT64_C(0x0000000080000000)
#define MACWS_TARGET_PROBE_MAGIC 0x4d575450u /* "MWTP" */
#define MACWS_TARGET_REPLY_MAGIC 0x4d575452u /* "MWTR" */
#define MACWS_TARGET_VERSION 1u
#define MACWS_INPUT_ACK_MAGIC 0x4d574941u /* "MWIA" */
#define MACWS_INPUT_ACK_VERSION 1u
#define MACWS_INTERACTION_WAKE_SOCKET_PATH \
    "/private/tmp/macws_interaction_wake.sock"
#define MACWS_VNC_ACTIVATION_REPLY_SOCKET_PATH \
    "/private/tmp/macws_vnc_activation_reply.sock"

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} MacWSFrameHeader;

typedef uint16_t MacWSInputKind;
enum {
    MacWSInputKindTouchDown = 1,
    MacWSInputKindTouchMove = 2,
    MacWSInputKindTouchUp = 3,
    MacWSInputKindTouchCancel = 4,
    MacWSInputKindHover = 5,
    // A complete stationary primary-button gesture.  Keeping the down/up pair
    // in one datagram prevents an accepted mouse-up from being separated from
    // a failed mouse-down when a local AF_UNIX queue is under pressure.
    MacWSInputKindTap = 6,
    // Refresh macwsinputd's unique AppKit hover owner without creating an
    // NSEvent.  OSXvnc sends this after its native pointer path has updated
    // WindowServer's global cursor/application state; the following hover can
    // then supplement AppKit menu tracking in that one selected process.
    MacWSInputKindTargetProbe = 7,
    // Control-plane records used only for a real VNC button-down. The producer
    // sends ActivateTarget after receiving that user packet but immediately
    // before posting its native down, so the broker can resolve the still-
    // responsive target even when the down enters a synchronous menu tracker.
    // The broker deactivates every other endpoint and activates the selected
    // endpoint. Neither control record constructs an NSEvent.
    MacWSInputKindActivateTarget = 8,
    MacWSInputKindDeactivateApplication = 9,
    // A button-free pointer update during a native menu lifecycle. macOS
    // 13.4's NSCarbonMenuImpl ultimately waits in NSApplication's NSEvent
    // queue through _NSHLTBMenuEventProc, so this kind lets the selected app
    // feed that queue from its socket thread while the main thread is inside
    // the synchronous menu tracker. It remains distinct from normal-window
    // hover so the route is bounded to an actual menu candidate lifetime.
    MacWSInputKindMenuHover = 10,
    // OSXvnc's own key-table/state machine has already translated the RFB
    // keysym when these records are emitted.  For key records, pressure is
    // the translated 16-bit CGKeyCode, contactID is the original 32-bit RFB
    // keysym, and sceneID's low 32 bits carry NSEvent/CG modifier flags.  The
    // v4 receivers validate the complete record before using these fields.
    MacWSInputKindKeyDown = 11,
    MacWSInputKindKeyUp = 12,
    // A complete stationary secondary-button gesture. Like Tap, the pair is
    // transported in one datagram and materialized inside the selected
    // AppKit process, so a fast RFB release cannot overtake its down before
    // rightMouseDown enters the native contextual-menu tracker.
    MacWSInputKindSecondaryTap = 13,
    // Two-axis precision scrolling. x/y remain the cursor location in frame
    // pixels, pressure carries vertical pixel delta, and contactID carries
    // the IEEE-754 bits of the horizontal float delta.
    MacWSInputKindScroll = 14,
    // Control-plane request for one captured AppKit window. sceneID carries
    // its exact window number, x/y are the desired frame size in macOS
    // logical points, and pressure carries iPad points per macOS point.
    // AppInputBridge clamps against the real NSWindow minimum before calling
    // the native frame setter; it never bypasses AppKit validation.
    MacWSInputKindConfigureWindow = 15,
    // A user discarded the iPad window Scene representing one exact AppKit
    // window. The target process performs the ordinary NSWindow close action;
    // backgrounding or stream disconnection never emits this control record.
    MacWSInputKindCloseWindow = 16,
    // Bootstrap one ordinary document/browser window in an AppKit process
    // that deliberately launches without a window (Finder is the concrete
    // case). The target resolves the enabled Command-N item from its current
    // NSMainMenu and sends that item's real target/action through NSApp.
    MacWSInputKindCreateInitialWindow = 17,
    // Deliver the standard NSApplication reopen lifecycle inside a directly
    // exec'd chroot application. Such processes have real HIServices and
    // WindowServer records but no LaunchServices AppleEvent endpoint, so a
    // Dock/open-style kAEReopenApplication addressed from another process
    // returns procNotFound. The target asks its real NSApplicationDelegate to
    // handle applicationShouldHandleReopen:hasVisibleWindows: on the main
    // thread; no application-specific window is synthesized.
    MacWSInputKindReopenApplication = 18,
    // Native AppKit magnification gesture. pressure carries the incremental
    // magnification delta (for example +0.05 means 5% larger), contactID is a
    // stable identity for the gesture, and the phase reuses the scroll-phase
    // flag bits below. The wire record stays ABI-compatible at 84 bytes.
    MacWSInputKindMagnify = 19,
    // One semantic macOS Space gesture produced only by the fullscreen
    // workspace. contactID carries MacWSDesktopCommand. Vertical three-finger
    // overview stays in Host because native Mission Control is unsafe in this
    // headless WindowServer; only left/right reach an AppKit endpoint as the
    // ordinary Control+Arrow shortcut.
    MacWSInputKindDesktopCommand = 20,
};

typedef uint32_t MacWSDesktopCommand;
enum {
    // Reserved wire values from the diagnostic implementation. Validators
    // reject them: Control+Up runtime-crashed WindowServer in MPS.
    MacWSDesktopCommandMissionControl = 1,
    MacWSDesktopCommandApplicationWindows = 2,
    MacWSDesktopCommandSpaceLeft = 3,
    MacWSDesktopCommandSpaceRight = 4,
};

typedef uint16_t MacWSHostInputMode;
enum {
    // Finger location maps directly to the macOS backing surface. Best for
    // large controls and is the default for a touch-first iPad experience.
    MacWSHostInputModeDirect = 1,
    // The iPad glass acts as a relative precision touchpad. Magic Keyboard
    // pointer events remain absolute and are not converted to relative input.
    MacWSHostInputModeTrackpad = 2,
};

typedef uint16_t MacWSHostDisplayDensity;
enum {
    // Pixel-matched Retina mode. The Host derives density from the exported
    // AppKit backing scale divided by the current MTK drawable/Scene scale;
    // this remains correct when Stage Manager changes UIKit's render scale.
    MacWSHostDisplayDensityTouchComfort = 1,
    // Optional more-space mode. It applies a 0.85 factor to the dynamic native
    // density so about 18% more macOS logical points fit into the Scene, at the
    // cost of a controlled downsample.
    MacWSHostDisplayDensityKeyboard = 2,
    // Optional larger touch presentation. The Host applies a mild 10%
    // high-quality upsample, so this is deliberately not described as exact
    // Retina. TouchComfort remains the default one-source-pixel-to-one-
    // drawable-pixel mode.
    MacWSHostDisplayDensityComfort = 3,
};

// Physical source of an input sample. Version 4 keeps this explicit instead
// of inferring Pencil, finger and indirect-pointer semantics from pressure or
// contact IDs. Producers that cannot identify the device (for example the
// legacy VNC bridge) use Unknown and retain ordinary mouse behavior.
typedef uint16_t MacWSInputSource;
enum {
    MacWSInputSourceUnknown = 0,
    MacWSInputSourceFinger = 1,
    MacWSInputSourcePencil = 2,
    MacWSInputSourceIndirectPointer = 3,
    MacWSInputSourceHardwareKeyboard = 4,
    MacWSInputSourceSoftwareKeyboard = 5,
    MacWSInputSourceVNC = 6,
};

enum {
    MacWSInputFlagPreciseLocation = 1u << 0,
    MacWSInputFlagEstimatedLocation = 1u << 1,
    MacWSInputFlagEstimatedPressure = 1u << 2,
    MacWSInputFlagExpectingLocationUpdate = 1u << 3,
    MacWSInputFlagExpectingPressureUpdate = 1u << 4,
    // UIKit's authoritative UITouch.tapCount says this atomic primary tap is
    // the second member of a double click. The first tap is still delivered
    // immediately, so ordinary single-click latency is unchanged.
    MacWSInputFlagDoubleClick = 1u << 5,
    // The fullscreen compositor resolved a real SkyLight layer that has no
    // process-local AppInput endpoint (Dock/system surfaces are the common
    // cases). Coordinates remain in the complete desktop framebuffer.
    // targetPID + encoded window name the real owner; the broker must
    // independently confirm that exact frontmost hit before posting to it.
    MacWSInputFlagGlobalSystemSurface = 1u << 6,
    // The producer has already accepted the release velocity and will follow
    // this finger ScrollEnded record with a momentum Began sequence. The AppKit
    // endpoint keeps its native per-window scroll target latched across that
    // boundary; without this explicit contract it must end the session now.
    MacWSInputFlagScrollWillMomentum = 1u << 7,
    MacWSInputFlagScrollBegan = 1u << 8,
    MacWSInputFlagScrollChanged = 1u << 9,
    MacWSInputFlagScrollEnded = 1u << 10,
    MacWSInputFlagScrollCancelled = 1u << 11,
    MacWSInputFlagScrollMomentum = 1u << 12,
    // These aliases describe the same NSEventPhase state machine for native
    // magnification without allocating another set of wire bits.
    MacWSInputFlagGestureBegan = MacWSInputFlagScrollBegan,
    MacWSInputFlagGestureChanged = MacWSInputFlagScrollChanged,
    MacWSInputFlagGestureEnded = MacWSInputFlagScrollEnded,
    MacWSInputFlagGestureCancelled = MacWSInputFlagScrollCancelled,
    // ConfigureWindow requests from an exact native Host Scene anchor the
    // represented AppKit window at the upper-left of its real NSScreen. This
    // makes AppKit constrain popovers against the same screen edge that bounds
    // the Scene capture instead of an arbitrary restored desktop position.
    MacWSInputFlagConfigureAnchorTopLeft = 1u << 13,
    // Keep the captured window's upper-right corner on the real NSScreen edge.
    // AppKit constrains popup-menu windows to NSScreen, not to their owner's
    // frame; right anchoring therefore keeps a right-edge popup inside the
    // exact-window DisplayStream instead of clipping it past the Scene edge.
    MacWSInputFlagConfigureAnchorTopRight = 1u << 14,
    // Bounded lab probes may request latency aggregation at the receiving
    // AppInput endpoint. Production UIKit/VNC producers leave this clear.
    MacWSInputFlagLatencyDiagnostic = 1u << 15,
};

// Versioned wire record for the iOS-host -> macOS event bridge.
// Coordinates are physical pixels in the producer's MacWSFrameHeader space.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t kind;
    uint64_t sceneID;
    double timestamp;
    float x;
    float y;
    float pressure;
    uint32_t contactID;
    uint32_t frameWidth;
    uint32_t frameHeight;
    int32_t targetPID;
    uint16_t source;
    uint16_t flags;
    uint32_t buttons;
    // Raw UIKit Pencil geometry in radians plus normalized Cartesian tilt.
    // Non-Pencil producers write zero. tiltX/tiltY are in [-1, 1].
    float altitude;
    float azimuth;
    float tiltX;
    float tiltY;
    // Monotonic per-producer sequence. Zero means the producer has no sequence.
    uint32_t sampleSequence;
    uint32_t reserved;
} MacWSInputRecord;

// ABI v3 originally used sceneID as an opaque scene token, while key records
// reserved its low 32 bits for modifier flags. A window Scene needs both an
// exact CGWindowID and those modifiers. UIKit's modifier flags occupy bits
// 16..21, so unused bit 31 marks this encoding, bits 32..63 retain the full
// 32-bit macOS window number, and bits 0..30 retain modifier flags.
// Fullscreen/RFB records keep the marker bit clear.
static inline uint64_t MacWSInputSceneForWindow(uint32_t windowID,
                                                uint32_t modifiers) {
    return MACWS_INPUT_WINDOW_SCENE_FLAG |
        ((uint64_t)windowID << 32) |
        (modifiers & UINT32_C(0x7fffffff));
}

static inline uint32_t MacWSInputWindowIDForScene(uint64_t sceneID) {
    if ((sceneID & MACWS_INPUT_WINDOW_SCENE_FLAG) == 0) return 0;
    return (uint32_t)(sceneID >> 32);
}

static inline uint32_t MacWSInputModifiersForScene(uint64_t sceneID) {
    return (uint32_t)sceneID & UINT32_C(0x7fffffff);
}

// macwsinputd has no usable CoreGraphics window list in its launchd session.
// Before routing an untargeted RFB down/tap, it asks every live AppKit endpoint
// to hit-test the point on that process's main thread. Only the selected PID
// receives the real MacWSInputRecord; probes never synthesize an NSEvent.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t nonce;
    float x;
    float y;
    uint32_t frameWidth;
    uint32_t frameHeight;
} MacWSInputTargetProbe;

enum {
    MacWSInputTargetHit = 1u << 0,
    MacWSInputTargetApplicationActive = 1u << 1,
    MacWSInputTargetKeyWindow = 1u << 2,
    // The global menu bar and application-owned transient surfaces follow
    // Process Manager's front UI process, which can diverge from
    // NSApplication.isActive when the chroot misses a LaunchServices
    // lifecycle update.  This flag is observational and lets the broker
    // request a real activation transaction when that divergence exists.
    MacWSInputTargetFrontUIProcess = 1u << 3,
};

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t nonce;
    int32_t pid;
    int32_t windowNumber;
    uint32_t flags;
} MacWSInputTargetReply;

enum {
    MacWSInputAckTargetReady = 1u << 0,
    MacWSInputAckRepairQueued = 1u << 1,
    MacWSInputAckRouteFailed = 1u << 2,
    MacWSInputAckMenuPreflight = 1u << 3,
};

// Bounded control-plane acknowledgement used only before OSXvnc emits a real
// native mouse-down. It reports whether the broker found the already-active
// target or had to queue an activation repair; it never acknowledges the
// subsequent NSEvent and therefore cannot create duplicate event ownership.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t sampleSequence;
    uint32_t flags;
} MacWSInputAck;

#if defined(__cplusplus)
static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
static_assert(sizeof(MacWSInputRecord) == 84, "MacWS input record ABI");
static_assert(sizeof(MacWSInputTargetProbe) == 32,
              "MacWS target probe ABI");
static_assert(sizeof(MacWSInputTargetReply) == 28,
              "MacWS target reply ABI");
static_assert(sizeof(MacWSInputAck) == 16, "MacWS input ack ABI");
#else
_Static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
_Static_assert(sizeof(MacWSInputRecord) == 84, "MacWS input record ABI");
_Static_assert(sizeof(MacWSInputTargetProbe) == 32,
               "MacWS target probe ABI");
_Static_assert(sizeof(MacWSInputTargetReply) == 28,
               "MacWS target reply ABI");
_Static_assert(sizeof(MacWSInputAck) == 16, "MacWS input ack ABI");
#endif

#endif
