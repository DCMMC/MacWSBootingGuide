#ifndef MACWS_TOUCH_POLICY_H
#define MACWS_TOUCH_POLICY_H

#include <stdbool.h>
#include <math.h>

// Product-level direct-touch thresholds. Keep these in a pure header so the
// UIKit state machine and local boundary tests cannot silently diverge.
// Four UIKit points is enough to reject normal tap jitter on an 11-inch
// iPad, while avoiding the extra display-frame of perceived latency that the
// previous six-point gate added to slow, deliberate map/document pans.
#define MACWS_DIRECT_GESTURE_THRESHOLD_POINTS 4.0
#define MACWS_DIRECT_LONG_PRESS_SECONDS 0.45
#define MACWS_SCROLL_MOMENTUM_MINIMUM_POINTS_PER_SECOND 80.0

// A dispatch_after callback is only a visual/feedback hint.  The Host main
// queue can be busy presenting a large IOSurface when that callback becomes
// runnable, while UIKit's already-recorded touch-up is still waiting behind
// it.  Always use the UITouch hardware timestamps at the next real event to
// decide whether the hold duration was actually reached.
static inline bool MacWSTouchReachedLongPress(double elapsedSeconds) {
    return elapsedSeconds >= MACWS_DIRECT_LONG_PRESS_SECONDS;
}

static inline bool MacWSShouldStartScrollMomentum(double velocityX,
                                                  double velocityY) {
    return hypot(velocityX, velocityY) >=
        MACWS_SCROLL_MOMENTUM_MINIMUM_POINTS_PER_SECOND;
}

typedef enum {
    MacWSTouchCandidateDecisionWait = 0,
    MacWSTouchCandidateDecisionTap,
    MacWSTouchCandidateDecisionScroll,
    MacWSTouchCandidateDecisionLongPress,
} MacWSTouchCandidateDecision;

// Once a direct-touch scroll has crossed the gesture threshold, lock clearly
// horizontal/vertical gestures for stable document scrolling, but preserve
// both axes for genuinely diagonal direct manipulation.  Always forcing one
// axis made Maps and 2-D canvases lag behind the finger because half of the
// physical trajectory was discarded before AppKit ever saw it.
typedef enum {
    MacWSDirectScrollAxisNone = 0,
    MacWSDirectScrollAxisHorizontal,
    MacWSDirectScrollAxisVertical,
    MacWSDirectScrollAxisFree,
} MacWSDirectScrollAxis;

static inline MacWSDirectScrollAxis MacWSChooseDirectScrollAxis(
        double displacementX, double displacementY) {
    double x = fabs(displacementX);
    double y = fabs(displacementY);
    if (x == 0.0 && y == 0.0) return MacWSDirectScrollAxisNone;
    if (y >= x * 1.5) return MacWSDirectScrollAxisVertical;
    if (x >= y * 1.5) return MacWSDirectScrollAxisHorizontal;
    return MacWSDirectScrollAxisFree;
}

static inline void MacWSConstrainDirectScrollDelta(
        MacWSDirectScrollAxis axis, double *deltaX, double *deltaY) {
    if (axis == MacWSDirectScrollAxisVertical) {
        *deltaX = 0.0;
    } else if (axis == MacWSDirectScrollAxisHorizontal) {
        *deltaY = 0.0;
    }
}

static inline MacWSTouchCandidateDecision MacWSDecideTouchCandidate(
        double elapsedSeconds, double travelPoints, bool didEnd) {
    // UITouch.timestamp is the hardware event time, independent of when the
    // main queue gets to process it.  A movement sample recorded after the
    // hold threshold therefore means "hold, then move" and must arm a mouse
    // drag even if dispatch_after's visual feedback callback was delayed.
    // Movement whose hardware timestamp is still before the threshold remains
    // scroll-first. Once scrolling starts the UIKit state machine no longer
    // asks this candidate policy, so a long continuous scroll cannot turn
    // into a drag when its total duration later crosses the hold threshold.
    if (MacWSTouchReachedLongPress(elapsedSeconds))
        return MacWSTouchCandidateDecisionLongPress;
    if (travelPoints >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS)
        return MacWSTouchCandidateDecisionScroll;
    return didEnd ? MacWSTouchCandidateDecisionTap
                  : MacWSTouchCandidateDecisionWait;
}

#endif
