#ifndef MACWS_DISPLAY_GEOMETRY_H
#define MACWS_DISPLAY_GEOMETRY_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>

// SkyLight exposes desktop/window bounds in logical points while its window
// capture IOSurfaces and layer destinations use backing pixels. Derive both
// canvas axes from the same logical-bounds × backing-scale invariant.
static inline bool MacWSPhysicalDisplayExtent(double logicalWidth,
                                               double logicalHeight,
                                               double backingScale,
                                               size_t maximumDimension,
                                               size_t *widthOut,
                                               size_t *heightOut) {
    if (!widthOut || !heightOut || !isfinite(logicalWidth) ||
        !isfinite(logicalHeight) || !isfinite(backingScale) ||
        logicalWidth <= 0.0 || logicalHeight <= 0.0 ||
        backingScale < 0.5 || backingScale > 8.0 ||
        maximumDimension == 0) return false;
    double physicalWidth = round(logicalWidth * backingScale);
    double physicalHeight = round(logicalHeight * backingScale);
    if (!isfinite(physicalWidth) || !isfinite(physicalHeight) ||
        physicalWidth < 1.0 || physicalHeight < 1.0 ||
        physicalWidth > (double)maximumDimension ||
        physicalHeight > (double)maximumDimension) return false;
    *widthOut = (size_t)physicalWidth;
    *heightOut = (size_t)physicalHeight;
    return true;
}

#endif
