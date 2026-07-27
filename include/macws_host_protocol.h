#ifndef MACWS_HOST_PROTOCOL_H
#define MACWS_HOST_PROTOCOL_H

#include <stdint.h>

#define MACWS_FRAME_MAGIC 0x564e4346u /* "VNCF" */
#define MACWS_INPUT_MAGIC 0x4d574556u /* "MWEV" */
#define MACWS_INPUT_VERSION 3u
#define MACWS_INPUT_CONTACT_DIAGNOSTIC 0x44494147u /* "DIAG" */
#define MACWS_TARGET_PROBE_MAGIC 0x4d575450u /* "MWTP" */
#define MACWS_TARGET_REPLY_MAGIC 0x4d575452u /* "MWTR" */
#define MACWS_TARGET_VERSION 1u

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
} MacWSInputRecord;

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

#if defined(__cplusplus)
static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
static_assert(sizeof(MacWSInputRecord) == 52, "MacWS input record ABI");
static_assert(sizeof(MacWSInputTargetProbe) == 32,
              "MacWS target probe ABI");
static_assert(sizeof(MacWSInputTargetReply) == 28,
              "MacWS target reply ABI");
#else
_Static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
_Static_assert(sizeof(MacWSInputRecord) == 52, "MacWS input record ABI");
_Static_assert(sizeof(MacWSInputTargetProbe) == 32,
               "MacWS target probe ABI");
_Static_assert(sizeof(MacWSInputTargetReply) == 28,
               "MacWS target reply ABI");
#endif

#endif
