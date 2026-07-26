#ifndef MACWS_HOST_PROTOCOL_H
#define MACWS_HOST_PROTOCOL_H

#include <stdint.h>

#define MACWS_FRAME_MAGIC 0x564e4346u /* "VNCF" */
#define MACWS_INPUT_MAGIC 0x4d574556u /* "MWEV" */
#define MACWS_INPUT_VERSION 3u
#define MACWS_INPUT_CONTACT_DIAGNOSTIC 0x44494147u /* "DIAG" */

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

#if defined(__cplusplus)
static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
static_assert(sizeof(MacWSInputRecord) == 52, "MacWS input record ABI");
#else
_Static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
_Static_assert(sizeof(MacWSInputRecord) == 52, "MacWS input record ABI");
#endif

#endif
