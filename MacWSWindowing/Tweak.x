@import Foundation;
@import UIKit;
@import Darwin;

#import <objc/message.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

// Source-confirmed against TrollPad 1.3 and RE-confirmed against the target
// iPadOS 16.3.1 SpringBoard: SBSwitcherChamoisLayoutAttributes stores the
// width/height candidate arrays consumed by
// _nearestGridSizeForSize:gridWidths:gridHeights:bounds:.  Keep the system's
// original maximum and every original candidate, then add 10-point
// intermediates beginning at TrollPad's source-confirmed 150-point floor.
// Final Scene geometry still goes through SpringBoard's ordinary nearest-grid
// and bounds validation; no UIWindow transform or validation bypass is
// involved.  The lower floor is needed for utility panels whose real AppKit
// content size is smaller than iPadOS's stock Stage Manager presets.

static const char *const MacWSDenseGridDisabled =
    "/var/mobile/Library/Preferences/com.macwsguide.dense-grid.disabled";
static const char *const MacWSDenseGridLoaded =
    "/var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded";
static CFStringRef const MacWSRequestFullscreenNotification =
    CFSTR("com.macwsguide.windowing.request-fullscreen");
static CFStringRef const MacWSRequestResizeNotification =
    CFSTR("com.macwsguide.windowing.request-resize");
static const char *const MacWSWindowingLog =
    "/var/mobile/Library/Logs/MacWSWindowing.log";
static NSString *const MacWSResizeRequestDirectory =
    @"/var/mobile/Library/Preferences";
static NSString *const MacWSFullscreenRequestPrefix =
    @"com.macwsguide.windowing.fullscreen-request.";
static NSString *const MacWSResizeRequestPrefix =
    @"com.macwsguide.windowing.resize-request.";
static NSMutableSet<NSString *> *MacWSFullscreenRequestsInFlight;
static NSMutableSet<NSString *> *MacWSResizeRequestsInFlight;

// RE-confirmed via SpringBoard 16.3.1
// -[SBItemResizeGestureSwitcherModifier
// _responseForSceneSizeUpdateToSize:center:sceneUpdatesOnly:] at
// 0x1c79cfaf4. _SBDisplayItemAttributedSizeInfer returns the opaque 56-byte
// value passed to -attributesByModifyingAttributedSize:. Keep the value
// opaque so this bridge follows the real ABI without inventing field
// semantics.
typedef struct {
    uint64_t words[7];
} MacWSDisplayItemAttributedSize;

typedef MacWSDisplayItemAttributedSize (*MacWSInferAttributedSizeFn)(
    CGSize proposedSize, CGRect containerBounds, CGSize defaultWindowSize,
    CGFloat screenEdgePadding);
typedef NSUInteger (*MacWSSizingPolicyFn)(NSUInteger supportedPolicies);

static void MacWSWindowingLogLine(NSString *line) {
    int fd = open(MacWSWindowingLog,
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    struct timespec now = {0};
    clock_gettime(CLOCK_REALTIME, &now);
    dprintf(fd, "%lld.%03lld %s\n", (long long)now.tv_sec,
            (long long)(now.tv_nsec / 1000000), line.UTF8String ?: "");
    close(fd);
}

static id MacWSMessageObject(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGSize MacWSMessageSize(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGSizeZero;
    return ((CGSize (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGRect MacWSMessageRect(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGFloat MacWSMessageFloat(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0.0;
    return ((CGFloat (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL MacWSMessageCanPerformFullscreen(id receiver) {
    SEL selector = NSSelectorFromString(
        @"canPerformKeyboardShortcutAction:forBundleIdentifier:");
    if (!receiver || ![receiver respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(
        receiver, selector, 0x0b, nil);
}

static void MacWSMessagePerformFullscreen(id receiver) {
    SEL selector = NSSelectorFromString(
        @"performKeyboardShortcutAction:forBundleIdentifier:");
    ((void (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(
        receiver, selector, 0x0b, nil);
}

static void MacWSFinishFullscreenRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSFullscreenRequestsInFlight removeObject:path];
}

// RE-confirmed on iPadOS 16.3.1 SpringBoard at 0x1c7669964:
// -[SpringBoard _handleMakeFullscreenKeyShortcut:] asks the active display
// window scene for its switcherController, checks action 0x0b, then performs
// that same action. Reuse that complete system transaction so SpringBoard
// owns the Chamois layout mutation, animation, status bar and Home Indicator.
// This does not mutate private ivars or force a validation result.
//
// The Host includes the exact FBS scene identifier in a short-lived request.
// Reject rather than resizing another app if focus changes before SpringBoard
// drains the Darwin notification.
static void MacWSApplyFullscreenRequest(NSDictionary *request,
                                        NSString *path) {
    NSString *bundleIdentifier = request[@"bundle_identifier"];
    NSString *requestedIdentifier = request[@"scene_identifier"];
    NSTimeInterval issuedAt = [request[@"issued_at"] doubleValue];
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - issuedAt;
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"] ||
        ![requestedIdentifier isKindOfClass:NSString.class] ||
        requestedIdentifier.length == 0 || !isfinite(age) || age < -2.0 ||
        age > 15.0) {
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"fullscreen-rejected path=%@ scene=%@ age=%.3f",
            path.lastPathComponent, requestedIdentifier ?: @"nil", age]);
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    id windowSceneManager = MacWSMessageObject(
        application, NSSelectorFromString(@"windowSceneManager"));
    id activeScene = MacWSMessageObject(
        windowSceneManager,
        NSSelectorFromString(@"activeDisplayWindowScene"));
    id switcherController = MacWSMessageObject(
        activeScene, NSSelectorFromString(@"switcherController"));
    NSString *activeIdentifier = MacWSMessageObject(
        activeScene, NSSelectorFromString(@"sceneIdentifier"));
    BOOL exactScene = [activeIdentifier isKindOfClass:NSString.class] &&
        [activeIdentifier isEqualToString:requestedIdentifier];
    BOOL allowed = exactScene &&
        MacWSMessageCanPerformFullscreen(switcherController);
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"fullscreen-request requested=%@ active=%@ exact=%@ manager=%@ switcher=%@ allowed=%@",
        requestedIdentifier, activeIdentifier ?: @"nil",
        exactScene ? @"YES" : @"NO", windowSceneManager ? @"YES" : @"NO",
        switcherController ? @"YES" : @"NO", allowed ? @"YES" : @"NO"]);
    if (!allowed) {
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"fullscreen-not-performed requested=%@ active=%@ reason=%@",
            requestedIdentifier, activeIdentifier ?: @"nil",
            exactScene ? @"system-action-unavailable" : @"scene-mismatch"]);
        return;
    }
    MacWSMessagePerformFullscreen(switcherController);
    MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
        @"fullscreen-performed scene=%@ action=11", activeIdentifier]);
}

static void MacWSHandleFullscreenRequest(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *names = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:MacWSResizeRequestDirectory error:nil];
        for (NSString *name in names) {
            if (![name hasPrefix:MacWSFullscreenRequestPrefix] ||
                ![name hasSuffix:@".plist"]) continue;
            NSString *path = [MacWSResizeRequestDirectory
                stringByAppendingPathComponent:name];
            if ([MacWSFullscreenRequestsInFlight containsObject:path]) continue;
            NSDictionary *request =
                [NSDictionary dictionaryWithContentsOfFile:path];
            if (![request isKindOfClass:NSDictionary.class]) {
                [[NSFileManager defaultManager] removeItemAtPath:path
                                                           error:nil];
                continue;
            }
            if (!MacWSFullscreenRequestsInFlight)
                MacWSFullscreenRequestsInFlight = [NSMutableSet set];
            [MacWSFullscreenRequestsInFlight addObject:path];
            MacWSApplyFullscreenRequest(request, path);
        }
    });
}

static void MacWSFinishResizeRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSResizeRequestsInFlight removeObject:path];
}

// RE-confirmed via SpringBoard 16.3.1:
//
// * +[SBDisplayItem applicationDisplayItemWithBundleIdentifier:
//   sceneIdentifier:] at 0x1c773f33c stores the FBS scene identifier as the
//   display item's uniqueIdentifier. This gives us an exact, non-title-based
//   match for a particular multi-window UIScene.
// * The real resize transaction at 0x1c79cfaf4 calls
//   _SBDisplayItemAttributedSizeInfer, immutable
//   attributesByModifyingAttributedSize:/SizingPolicy:, immutable
//   appLayoutByModifyingLayoutAttributes:forItem:, then creates an
//   SBMutableSwitcherTransitionRequest.
// * -[SBMainSwitcherControllerCoordinator
//   switcherContentController:performTransitionWithRequest:gestureInitiated:]
//   at 0x1c79e67b8 submits that request through SBMainWorkspace when the
//   transition is not gesture-initiated.
//
// Reproduce that complete model transaction. No UIWindow frame/transform or
// SpringBoard ivar is overwritten, and every ordinary system validation and
// scene update remains in the path.
static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,
                                    NSUInteger attempt) {
    NSString *bundleIdentifier = request[@"bundle_identifier"];
    NSString *sceneIdentifier = request[@"scene_identifier"];
    CGFloat width = [request[@"width"] doubleValue];
    CGFloat height = [request[@"height"] doubleValue];
    NSTimeInterval issuedAt = [request[@"issued_at"] doubleValue];
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - issuedAt;
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"] ||
        ![sceneIdentifier isKindOfClass:NSString.class] ||
        sceneIdentifier.length == 0 || !isfinite(width) || !isfinite(height) ||
        width < 150.0 || height < 150.0 || width > 4096.0 || height > 4096.0 ||
        !isfinite(age) || age < -2.0 || age > 15.0) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-rejected path=%@ scene=%@ size=%.1fx%.1f age=%.3f",
            path.lastPathComponent, sceneIdentifier ?: @"nil", width, height,
            age]);
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    id windowSceneManager = MacWSMessageObject(
        application, NSSelectorFromString(@"windowSceneManager"));
    id displayWindowScene = MacWSMessageObject(
        windowSceneManager,
        NSSelectorFromString(@"activeDisplayWindowScene"));
    id switcherController = MacWSMessageObject(
        displayWindowScene, NSSelectorFromString(@"switcherController"));
    id contentController = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"contentViewController"));
    if (!contentController) {
        contentController = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"switcherViewController"));
    }
    id coordinator = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"switcherCoordinator"));

    NSArray *appLayouts = MacWSMessageObject(
        coordinator, NSSelectorFromString(@"recentAppLayouts"));
    id targetLayout = nil;
    id targetItem = nil;
    for (id layout in appLayouts) {
        for (id item in MacWSMessageObject(
                 layout, NSSelectorFromString(@"allItems"))) {
            NSString *candidateBundle = MacWSMessageObject(
                item, NSSelectorFromString(@"bundleIdentifier"));
            NSString *candidateIdentifier = MacWSMessageObject(
                item, NSSelectorFromString(@"uniqueIdentifier"));
            if ([candidateBundle isEqualToString:bundleIdentifier] &&
                [candidateIdentifier isEqualToString:sceneIdentifier]) {
                targetLayout = layout;
                targetItem = item;
                break;
            }
        }
        if (targetItem) break;
    }

    if (!switcherController || !contentController || !coordinator ||
        !targetLayout || !targetItem) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSApplyResizeRequest(request, path, attempt + 1);
            });
            return;
        }
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=scene-layout-not-ready attempts=%lu controller=%@ content=%@ coordinator=%@",
            sceneIdentifier, (unsigned long)(attempt + 1),
            switcherController ? @"YES" : @"NO",
            contentController ? @"YES" : @"NO",
            coordinator ? @"YES" : @"NO"]);
        return;
    }

    MacWSInferAttributedSizeFn inferAttributedSize =
        (MacWSInferAttributedSizeFn)dlsym(
            RTLD_DEFAULT, "SBDisplayItemAttributedSizeInfer");
    MacWSSizingPolicyFn smallestSizingPolicy =
        (MacWSSizingPolicyFn)dlsym(
            RTLD_DEFAULT, "SBDisplayItemSizingPolicyAllowingSmallestSize");
    id attributes = ((id (*)(id, SEL, id))objc_msgSend)(
        targetLayout, NSSelectorFromString(@"layoutAttributesForItem:"),
        targetItem);
    id chamoisAttributes = MacWSMessageObject(
        contentController, NSSelectorFromString(@"chamoisLayoutAttributes"));
    CGRect containerBounds = MacWSMessageRect(
        contentController, NSSelectorFromString(@"containerViewBounds"));
    CGSize defaultWindowSize = MacWSMessageSize(
        chamoisAttributes, NSSelectorFromString(@"defaultWindowSize"));
    CGFloat screenEdgePadding = MacWSMessageFloat(
        chamoisAttributes, NSSelectorFromString(@"screenEdgePadding"));
    SEL supportedSelector = NSSelectorFromString(
        @"supportedSizingPoliciesForItem:inAppLayout:");
    NSUInteger supportedPolicies = 0;
    if ([contentController respondsToSelector:supportedSelector]) {
        supportedPolicies = ((NSUInteger (*)(id, SEL, id, id))objc_msgSend)(
            contentController, supportedSelector, targetItem, targetLayout);
    }
    if (!inferAttributedSize || !smallestSizingPolicy || !attributes ||
        !chamoisAttributes || CGRectIsEmpty(containerBounds) ||
        CGSizeEqualToSize(defaultWindowSize, CGSizeZero) ||
        supportedPolicies == 0) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=transaction-capability infer=%@ policy=%@ attrs=%@ chamois=%@ bounds=%@ supported=0x%lx",
            sceneIdentifier, inferAttributedSize ? @"YES" : @"NO",
            smallestSizingPolicy ? @"YES" : @"NO",
            attributes ? @"YES" : @"NO",
            chamoisAttributes ? @"YES" : @"NO",
            NSStringFromCGRect(containerBounds),
            (unsigned long)supportedPolicies]);
        return;
    }

    MacWSDisplayItemAttributedSize attributedSize = inferAttributedSize(
        CGSizeMake(width, height), containerBounds, defaultWindowSize,
        screenEdgePadding);
    SEL modifySizeSelector =
        NSSelectorFromString(@"attributesByModifyingAttributedSize:");
    id resizedAttributes = attributes &&
        [attributes respondsToSelector:modifySizeSelector]
        ? ((id (*)(id, SEL,
                   const MacWSDisplayItemAttributedSize *))objc_msgSend)(
              attributes, modifySizeSelector, &attributedSize)
        : nil;
    NSUInteger sizingPolicy = smallestSizingPolicy(supportedPolicies);
    SEL modifyPolicySelector =
        NSSelectorFromString(@"attributesByModifyingSizingPolicy:");
    resizedAttributes = resizedAttributes &&
        [resizedAttributes respondsToSelector:modifyPolicySelector]
        ? ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
              resizedAttributes, modifyPolicySelector, sizingPolicy)
        : nil;
    SEL modifyLayoutSelector = NSSelectorFromString(
        @"appLayoutByModifyingLayoutAttributes:forItem:");
    id resizedLayout = resizedAttributes &&
        [targetLayout respondsToSelector:modifyLayoutSelector]
        ? ((id (*)(id, SEL, id, id))objc_msgSend)(
              targetLayout, modifyLayoutSelector, resizedAttributes,
              targetItem)
        : nil;
    SEL bringFrontSelector = NSSelectorFromString(
        @"appLayoutByBringingItemToFront:inAppLayout:");
    if (resizedLayout &&
        [contentController respondsToSelector:bringFrontSelector]) {
        resizedLayout = ((id (*)(id, SEL, id, id))objc_msgSend)(
            contentController, bringFrontSelector, targetItem, resizedLayout);
    }

    Class requestClass = NSClassFromString(
        @"SBMutableSwitcherTransitionRequest");
    id transitionRequest = resizedLayout
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              requestClass,
              NSSelectorFromString(@"requestForActivatingAppLayout:"),
              resizedLayout)
        : nil;
    if ([transitionRequest respondsToSelector:
            NSSelectorFromString(@"setSceneUpdatesOnly:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            transitionRequest,
            NSSelectorFromString(@"setSceneUpdatesOnly:"), NO);
    }
    SEL performSelector = NSSelectorFromString(
        @"switcherContentController:performTransitionWithRequest:gestureInitiated:");
    if (!transitionRequest || ![coordinator respondsToSelector:performSelector]) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=transition-unavailable layout=%@ request=%@",
            sceneIdentifier, resizedLayout ? @"YES" : @"NO",
            transitionRequest ? @"YES" : @"NO"]);
        return;
    }

    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
        coordinator, performSelector, contentController, transitionRequest,
        NO);
    MacWSFinishResizeRequest(path, [NSString stringWithFormat:
        @"resize-performed scene=%@ requested=%.1fx%.1f bounds=%@ default=%.1fx%.1f supported=0x%lx policy=%lu route=SBMainWorkspace",
        sceneIdentifier, width, height, NSStringFromCGRect(containerBounds),
        defaultWindowSize.width, defaultWindowSize.height,
        (unsigned long)supportedPolicies, (unsigned long)sizingPolicy]);
}

static void MacWSHandleResizeRequest(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *names = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:MacWSResizeRequestDirectory error:nil];
        for (NSString *name in names) {
            if (![name hasPrefix:MacWSResizeRequestPrefix] ||
                ![name hasSuffix:@".plist"]) continue;
            NSString *path = [MacWSResizeRequestDirectory
                stringByAppendingPathComponent:name];
            if ([MacWSResizeRequestsInFlight containsObject:path]) continue;
            NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![request isKindOfClass:NSDictionary.class]) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                continue;
            }
            if (!MacWSResizeRequestsInFlight)
                MacWSResizeRequestsInFlight = [NSMutableSet set];
            [MacWSResizeRequestsInFlight addObject:path];
            MacWSApplyResizeRequest(request, path, 0);
        }
    });
}

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
    static const double nativeWindowFloor = 150.0;
    double first = ceil(nativeWindowFloor / step) * step;
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
                                   nativeWindowFloor, maximum);
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
    if (fd >= 0) {
        dprintf(fd, "version=6 pid=%d step=10 minimum=150 "
                    "fullscreen=exact-scene-keyboard-action-11 "
                    "resize=app-layout-transaction\n", getpid());
        close(fd);
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        MacWSHandleFullscreenRequest, MacWSRequestFullscreenNotification,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        MacWSHandleResizeRequest, MacWSRequestResizeNotification,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
