#ifndef MACWS_TOUCH_POLICY_H
#define MACWS_TOUCH_POLICY_H

#include <stdbool.h>
#include <math.h>

// Product-level direct-touch thresholds. Keep these in a pure header so the
// UIKit state machine and local boundary tests cannot silently diverge.
#define MACWS_DIRECT_GESTURE_THRESHOLD_POINTS 6.0
#define MACWS_DIRECT_LONG_PRESS_SECONDS 0.45

typedef enum {
    MacWSTouchCandidateDecisionWait = 0,
    MacWSTouchCandidateDecisionTap,
    MacWSTouchCandidateDecisionScroll,
    MacWSTouchCandidateDecisionLongPress,
} MacWSTouchCandidateDecision;

// Once a direct-touch scroll has crossed the gesture threshold, keep it on
// one axis for the lifetime of that gesture.  A slight vertical bias matches
// the common iPad reading gesture and prevents hand jitter from producing a
// horizontal wheel stream in editors and web pages.
typedef enum {
    MacWSDirectScrollAxisNone = 0,
    MacWSDirectScrollAxisHorizontal,
    MacWSDirectScrollAxisVertical,
} MacWSDirectScrollAxis;

static inline MacWSDirectScrollAxis MacWSChooseDirectScrollAxis(
        double displacementX, double displacementY) {
    double x = fabs(displacementX);
    double y = fabs(displacementY);
    if (x == 0.0 && y == 0.0) return MacWSDirectScrollAxisNone;
    return y >= x * 0.75 ? MacWSDirectScrollAxisVertical
                         : MacWSDirectScrollAxisHorizontal;
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
    // Direct touch is scroll-first: crossing the movement threshold before a
    // hold becomes a native scroll gesture.  A stationary hold arms mouse
    // dragging; the UIKit state machine decides on release whether an armed
    // hold was a drag or a secondary click.  Check travel first so a delayed
    // main-queue timer cannot reinterpret an already-moving finger as a hold.
    if (travelPoints >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS)
        return MacWSTouchCandidateDecisionScroll;
    if (elapsedSeconds >= MACWS_DIRECT_LONG_PRESS_SECONDS)
        return MacWSTouchCandidateDecisionLongPress;
    return didEnd ? MacWSTouchCandidateDecisionTap
                  : MacWSTouchCandidateDecisionWait;
}

#endif
