#ifndef MACWS_VIEWPORT_MATH_H
#define MACWS_VIEWPORT_MATH_H

#include <math.h>
#include <stdbool.h>

// Pure, SDK-independent presentation math shared by MacWSHost and its local
// tests.  The returned rectangle is normalized to the producer texture.  It
// always fills the destination: an aspect-ratio mismatch crops the source and
// never introduces letterboxing.
typedef struct {
    float x;
    float y;
    float width;
    float height;
} MacWSNormalizedRect;

typedef struct {
    MacWSNormalizedRect visibleSource;
    float centerX;
    float centerY;
    float zoom;
} MacWSViewport;

typedef struct {
    float x;
    float y;
} MacWSNormalizedPoint;

static inline float MacWSClampFloat(float value, float minimum,
                                    float maximum) {
    return fminf(fmaxf(value, minimum), maximum);
}

static inline bool MacWSComputeViewport(float sourceWidth, float sourceHeight,
                                        float viewWidth, float viewHeight,
                                        float requestedZoom,
                                        float requestedCenterX,
                                        float requestedCenterY,
                                        MacWSViewport *result) {
    if (!result || !isfinite(sourceWidth) || !isfinite(sourceHeight) ||
        !isfinite(viewWidth) || !isfinite(viewHeight) ||
        !isfinite(requestedZoom) || !isfinite(requestedCenterX) ||
        !isfinite(requestedCenterY) || sourceWidth <= 0 || sourceHeight <= 0 ||
        viewWidth <= 0 || viewHeight <= 0) return false;

    float sourceAspect = sourceWidth / sourceHeight;
    float viewAspect = viewWidth / viewHeight;
    float visibleWidth = 1.0f;
    float visibleHeight = 1.0f;
    if (sourceAspect > viewAspect)
        visibleWidth = viewAspect / sourceAspect;
    else
        visibleHeight = sourceAspect / viewAspect;

    // Product interaction is binary: 1x or one configured enlarged view.
    // Current settings expose 1.5x and 2x, so never admit an accidental
    // continuous-pinch scale outside that range.
    float zoom = MacWSClampFloat(requestedZoom, 1.0f, 2.0f);
    visibleWidth /= zoom;
    visibleHeight /= zoom;
    float centerX = MacWSClampFloat(requestedCenterX, visibleWidth * 0.5f,
                                    1.0f - visibleWidth * 0.5f);
    float centerY = MacWSClampFloat(requestedCenterY, visibleHeight * 0.5f,
                                    1.0f - visibleHeight * 0.5f);
    *result = (MacWSViewport){
        .visibleSource = {
            .x = centerX - visibleWidth * 0.5f,
            .y = centerY - visibleHeight * 0.5f,
            .width = visibleWidth,
            .height = visibleHeight,
        },
        .centerX = centerX,
        .centerY = centerY,
        .zoom = zoom,
    };
    return true;
}

static inline MacWSNormalizedPoint MacWSViewportMapPoint(
        const MacWSViewport *viewport, float normalizedViewX,
        float normalizedViewY) {
    if (!viewport) return (MacWSNormalizedPoint){0, 0};
    float x = MacWSClampFloat(normalizedViewX, 0.0f, 1.0f);
    float y = MacWSClampFloat(normalizedViewY, 0.0f, 1.0f);
    return (MacWSNormalizedPoint){
        .x = viewport->visibleSource.x + x * viewport->visibleSource.width,
        .y = viewport->visibleSource.y + y * viewport->visibleSource.height,
    };
}

// Returns the requested viewport center that keeps sourceAnchor under the
// same normalized point after changing zoom. Pass the visibleSource size
// computed at the new zoom; MacWSComputeViewport performs final edge clamps.
static inline MacWSNormalizedPoint MacWSViewportCenterKeepingAnchor(
        MacWSNormalizedRect enlargedVisibleSource,
        MacWSNormalizedPoint sourceAnchor, float normalizedViewX,
        float normalizedViewY) {
    float viewX = MacWSClampFloat(normalizedViewX, 0.0f, 1.0f);
    float viewY = MacWSClampFloat(normalizedViewY, 0.0f, 1.0f);
    return (MacWSNormalizedPoint){
        .x = sourceAnchor.x +
             (0.5f - viewX) * enlargedVisibleSource.width,
        .y = sourceAnchor.y +
             (0.5f - viewY) * enlargedVisibleSource.height,
    };
}

#endif
