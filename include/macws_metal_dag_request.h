#ifndef MACWS_METAL_DAG_REQUEST_H
#define MACWS_METAL_DAG_REQUEST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// RE-confirmed MTLCompiler 482ee5289d703ed7a746d19bb741245b,
// +0x79b40: discriminator 14 contains a NUL-terminated DAG followed by
// optional AIR version, function count, then optional target strings and
// length-prefixed wrapped AIR modules. Reject truncation/unknown trailers.
// Match only MacWS metal2metal's exact current Catalyst AIR target in EVERY
// module; ordinary iOS MPS/DAG inputs never opt into this adaptation.
static inline bool MacWSMetalDAGHasCatalystInputs(const void *data, size_t size) {
    static const char target[] = "air64-apple-ios19.0.0-macabi";
    if (!data || size < 20 || size > 32U * 1024U * 1024U) return false;
    const uint8_t *bytes = data, *cursor = bytes, *end = bytes + size;
    if (memcmp(cursor, " gad", 4)) return false;
    cursor += 4;
    const uint8_t *terminator = memchr(cursor, 0, (size_t)(end - cursor));
    if (!terminator || terminator == cursor) return false;
    cursor = terminator + 1;
    if (end - cursor >= 4 && !memcmp(cursor, "vria", 4)) {
        if (end - cursor < 12) return false;
        cursor += 12;
    }
    if (end - cursor < 8 || memcmp(cursor, "fmun", 4)) return false;
    uint32_t count;
    memcpy(&count, cursor + 4, sizeof(count));
    cursor += 8;
    if (!count || count > 4096) return false;
    for (uint32_t i = 0; i < count; i++) {
        if (end - cursor >= 4 && !memcmp(cursor, "lprt", 4)) {
            cursor += 4;
            terminator = memchr(cursor, 0, (size_t)(end - cursor));
            if (!terminator || (size_t)(terminator - cursor) != sizeof(target)-1 ||
                memcmp(cursor, target, sizeof(target)-1)) return false;
            cursor = terminator + 1;
        }
        if (end - cursor < 8 || memcmp(cursor, "ctib", 4)) return false;
        uint32_t length;
        memcpy(&length, cursor + 4, sizeof(length));
        cursor += 8;
        if (length < 24 || length > (size_t)(end - cursor)) return false;
        uint32_t magic, version, bitcodeOffset, bitcodeSize;
        memcpy(&magic, cursor, 4);
        memcpy(&version, cursor + 4, 4);
        memcpy(&bitcodeOffset, cursor + 8, 4);
        memcpy(&bitcodeSize, cursor + 12, 4);
        if (magic != UINT32_C(0x0b17c0de) || version || bitcodeOffset < 20 ||
            bitcodeOffset > length || bitcodeSize > length - bitcodeOffset ||
            bitcodeSize < sizeof(target)-1 ||
            memcmp(cursor + bitcodeOffset, "BC\xc0\xde", 4)) return false;
        const uint8_t *air = cursor + bitcodeOffset;
        bool found = false;
        for (size_t j = 0; j <= bitcodeSize - (sizeof(target)-1); j++) {
            if (air[j] == 'a' && !memcmp(air + j, target, sizeof(target)-1)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
        cursor += length;
    }
    return cursor == end;
}
#endif
