@import Foundation;
@import Darwin;

// Source-confirmed against TrollPad 1.3 and RE-confirmed against the target
// iPadOS 16.3.1 SpringBoard: SBSwitcherChamoisLayoutAttributes stores the
// width/height candidate arrays consumed by
// _nearestGridSizeForSize:gridWidths:gridHeights:bounds:.  Keep the system's
// original minimum, maximum, and every original candidate, then add 10-point
// intermediates only inside that already-approved envelope.  Final Scene
// geometry still goes through SpringBoard's ordinary nearest-grid and bounds
// validation; no UIWindow transform or validation bypass is involved.

static const char *const MacWSDenseGridDisabled =
    "/var/mobile/Library/Preferences/com.macwsguide.dense-grid.disabled";
static const char *const MacWSDenseGridLoaded =
    "/var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded";

static void MacWSWriteDenseGridWitness(const char *axis, NSUInteger original,
                                       NSUInteger expanded, double minimum,
                                       double maximum) {
    char path[PATH_MAX] = {0};
    snprintf(path, sizeof(path),
             "/var/mobile/Library/Preferences/com.macwsguide.dense-grid.%s",
             axis);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dprintf(fd, "version=2 pid=%d axis=%s step=10 original=%lu expanded=%lu "
                "minimum=%.3f maximum=%.3f\n",
            getpid(), axis, (unsigned long)original, (unsigned long)expanded,
            minimum, maximum);
    close(fd);
}

static NSArray<NSNumber *> *MacWSDenseCandidates(NSArray<NSNumber *> *source,
                                                  const char *axis) {
    if (![source isKindOfClass:NSArray.class] || source.count < 2 ||
        access(MacWSDenseGridDisabled, F_OK) == 0) return source;
    double minimum = DBL_MAX;
    double maximum = 0.0;
    NSMutableSet<NSNumber *> *values = [NSMutableSet setWithCapacity:source.count];
    for (id object in source) {
        if (![object isKindOfClass:NSNumber.class]) return source;
        double value = [object doubleValue];
        if (!isfinite(value) || value <= 0.0) return source;
        minimum = fmin(minimum, value);
        maximum = fmax(maximum, value);
        [values addObject:@(value)];
    }
    if (!isfinite(minimum) || !isfinite(maximum) || maximum <= minimum)
        return source;

    static const double step = 10.0;
    double first = ceil(minimum / step) * step;
    for (double value = first; value < maximum && values.count < 256;
         value += step) {
        [values addObject:@(value)];
    }
    NSArray<NSNumber *> *ordered = [values.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs,
                                                        NSNumber *rhs) {
            return [lhs compare:rhs];
        }];
    if (ordered.count > source.count)
        MacWSWriteDenseGridWitness(axis, source.count, ordered.count,
                                   minimum, maximum);
    return ordered.count >= source.count ? ordered : source;
}

%hook SBSwitcherChamoisLayoutAttributes
- (void)setGridWidths:(NSArray<NSNumber *> *)widths {
    %orig(MacWSDenseCandidates(widths, "width"));
}
- (void)setGridHeights:(NSArray<NSNumber *> *)heights {
    %orig(MacWSDenseCandidates(heights, "height"));
}
- (NSArray<NSNumber *> *)gridWidths {
    return MacWSDenseCandidates(%orig, "width-getter");
}
- (NSArray<NSNumber *> *)gridHeights {
    return MacWSDenseCandidates(%orig, "height-getter");
}
%end

__attribute__((constructor)) static void MacWSDenseGridLoadedWitness(void) {
    int fd = open(MacWSDenseGridLoaded,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dprintf(fd, "version=2 pid=%d step=10\n", getpid());
    close(fd);
}
