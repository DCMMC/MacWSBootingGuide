#ifndef MACWS_TOUCH_POLICY_H
#define MACWS_TOUCH_POLICY_H

#include <stdbool.h>

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
