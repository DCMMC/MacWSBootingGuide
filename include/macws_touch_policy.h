#ifndef MACWS_TOUCH_POLICY_H
#define MACWS_TOUCH_POLICY_H

#include <stdbool.h>

// Product-level direct-touch thresholds. Keep these in a pure header so the
// UIKit state machine and local boundary tests cannot silently diverge.
#define MACWS_DIRECT_DRAG_THRESHOLD_POINTS 6.0
#define MACWS_DIRECT_LONG_PRESS_SECONDS 0.45

typedef enum {
    MacWSTouchCandidateDecisionWait = 0,
    MacWSTouchCandidateDecisionTap,
    MacWSTouchCandidateDecisionDrag,
    MacWSTouchCandidateDecisionSecondaryTap,
} MacWSTouchCandidateDecision;

static inline MacWSTouchCandidateDecision MacWSDecideTouchCandidate(
        double elapsedSeconds, double travelPoints, bool didEnd) {
    // Whichever transition was observed first already moves the UIKit state
    // machine out of Candidate. If it is still a candidate at the deadline,
    // long-press wins; this also makes a delayed main queue deterministic.
    if (elapsedSeconds >= MACWS_DIRECT_LONG_PRESS_SECONDS)
        return MacWSTouchCandidateDecisionSecondaryTap;
    if (travelPoints >= MACWS_DIRECT_DRAG_THRESHOLD_POINTS)
        return MacWSTouchCandidateDecisionDrag;
    return didEnd ? MacWSTouchCandidateDecisionTap
                  : MacWSTouchCandidateDecisionWait;
}

#endif
