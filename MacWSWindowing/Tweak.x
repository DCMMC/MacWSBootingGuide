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

static NSInteger MacWSMessageInteger(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSInteger MacWSMessageIntegerWithObject(id receiver, SEL selector,
                                               id object) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL, id))objc_msgSend)(
        receiver, selector, object);
}

static BOOL MacWSMessageBool(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void MacWSMessagePerformFullscreen(id receiver) {
    SEL selector = NSSelectorFromString(
        @"performKeyboardShortcutAction:forBundleIdentifier:");
    ((void (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(
        receiver, selector, 0x11, nil);
}

static void MacWSFinishFullscreenRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSFullscreenRequestsInFlight removeObject:path];
}

static BOOL MacWSAppLayoutContainsExactScene(
        id layout, NSString *bundleIdentifier, NSString *sceneIdentifier) {
    if (!layout || bundleIdentifier.length == 0 || sceneIdentifier.length == 0)
        return NO;
    NSArray *items = MacWSMessageObject(
        layout, NSSelectorFromString(@"allItems"));
    if (![items isKindOfClass:NSArray.class]) return NO;
    for (id item in items) {
        NSString *candidateBundle = MacWSMessageObject(
            item, NSSelectorFromString(@"bundleIdentifier"));
        NSString *candidateIdentifier = MacWSMessageObject(
            item, NSSelectorFromString(@"uniqueIdentifier"));
        if ([candidateBundle isEqualToString:bundleIdentifier] &&
            [candidateIdentifier isEqualToString:sceneIdentifier]) return YES;
    }
    return NO;
}

// RE-confirmed on iPadOS 16.3.1 SpringBoard at 0x1c7669808:
// -[SpringBoard _handleEnterFullScreenKeyShortcut:] asks the active display
// window scene for its switcherController and directly performs action 0x11.
// This is distinct from _handleMakeFullscreenKeyShortcut: at 0x1c7669964,
// whose action 0x0b is unavailable in the active Chamois modifier state.
// Reuse the correct system transaction so SpringBoard owns the layout
// mutation, animation, status bar and Home Indicator. This does not mutate
// private ivars, force a condition, or skip a check present in Apple's path.
//
// Runtime-confirmed on the same device: activeDisplayWindowScene is the
// enclosing SBWindowScene whose identifier is com.apple.springboard.  The
// foreground app identity instead lives in the switcher content controller's
// leafAppLayoutForKeyboardFocusedScene / keyboardFocusedAppLayout.  Validate
// the request against that focused layout's SBDisplayItem uniqueIdentifier;
// +[SBDisplayItem applicationDisplayItemWithBundleIdentifier:sceneIdentifier:]
// stores the exact FBS scene identifier there (RE-confirmed at 0x1c773f33c).
// Retry briefly while a just-activated Scene acquires keyboard focus.
static void MacWSApplyFullscreenRequest(NSDictionary *request,
                                        NSString *path,
                                        NSUInteger attempt) {
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
    id contentController = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"contentViewController"));
    if (!contentController) {
        contentController = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"switcherViewController"));
    }
    id focusedLayout = MacWSMessageObject(
        contentController,
        NSSelectorFromString(@"leafAppLayoutForKeyboardFocusedScene"));
    NSString *focusSource = focusedLayout
        ? @"leafAppLayoutForKeyboardFocusedScene" : nil;
    if (!focusedLayout) {
        focusedLayout = MacWSMessageObject(
            contentController,
            NSSelectorFromString(@"keyboardFocusedAppLayout"));
        if (focusedLayout) focusSource = @"keyboardFocusedAppLayout";
    }
    if (!focusedLayout) {
        focusedLayout = MacWSMessageObject(
            switcherController,
            NSSelectorFromString(@"_currentMainAppLayout"));
        if (focusedLayout) focusSource = @"_currentMainAppLayout";
    }
    if (!focusedLayout) {
        id coordinator = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"switcherCoordinator"));
        focusedLayout = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"_currentAppLayout"));
        if (focusedLayout) focusSource = @"_currentAppLayout";
    }
    BOOL exactScene = MacWSAppLayoutContainsExactScene(
        focusedLayout, bundleIdentifier, requestedIdentifier);
    SEL performSelector = NSSelectorFromString(
        @"performKeyboardShortcutAction:forBundleIdentifier:");
    BOOL actionAvailable = switcherController &&
        [switcherController respondsToSelector:performSelector];
    BOOL allowed = exactScene && actionAvailable;
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"fullscreen-request requested=%@ exact-focus=%@ focus-source=%@ manager=%@ switcher=%@ content=%@ action=%@ attempt=%lu",
        requestedIdentifier, exactScene ? @"YES" : @"NO",
        focusSource ?: @"none", windowSceneManager ? @"YES" : @"NO",
        switcherController ? @"YES" : @"NO",
        contentController ? @"YES" : @"NO",
        actionAvailable ? @"YES" : @"NO",
        (unsigned long)(attempt + 1)]);
    if (!allowed) {
        if (!exactScene && attempt < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSApplyFullscreenRequest(request, path, attempt + 1);
            });
            return;
        }
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"fullscreen-not-performed requested=%@ reason=%@ attempts=%lu",
            requestedIdentifier,
            exactScene ? @"system-action-unavailable" : @"focused-scene-mismatch",
            (unsigned long)(attempt + 1)]);
        return;
    }
    MacWSMessagePerformFullscreen(switcherController);
    MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
        @"fullscreen-performed scene=%@ action=17 focus-source=%@",
        requestedIdentifier, focusSource]);
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
            MacWSApplyFullscreenRequest(request, path, 0);
        }
    });
}

static void MacWSFinishResizeRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSResizeRequestsInFlight removeObject:path];
}

static void MacWSVerifyResizePostcondition(id coordinator,
                                           NSString *bundleIdentifier,
                                           NSString *sceneIdentifier,
                                           BOOL expectedWindowedRole) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        NSArray *appLayouts = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"recentAppLayouts"));
        id actualLayout = nil;
        id actualItem = nil;
        for (id layout in appLayouts) {
            for (id item in MacWSMessageObject(
                     layout, NSSelectorFromString(@"allItems"))) {
                NSString *candidateBundle = MacWSMessageObject(
                    item, NSSelectorFromString(@"bundleIdentifier"));
                NSString *candidateIdentifier = MacWSMessageObject(
                    item, NSSelectorFromString(@"uniqueIdentifier"));
                if ([candidateBundle isEqualToString:bundleIdentifier] &&
                    [candidateIdentifier isEqualToString:sceneIdentifier]) {
                    actualLayout = layout;
                    actualItem = item;
                    break;
                }
            }
            if (actualItem) break;
        }
        NSInteger actualRole = MacWSMessageIntegerWithObject(
            actualLayout, NSSelectorFromString(@"layoutRoleForItem:"),
            actualItem);
        NSInteger actualCenter = MacWSMessageInteger(
            actualLayout, NSSelectorFromString(@"centerConfiguration"));
        NSInteger actualEnvironment = MacWSMessageInteger(
            actualLayout, NSSelectorFromString(@"environment"));
        NSInteger *centerRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRoleCenter");
        BOOL landed = actualLayout && actualItem;
        if (expectedWindowedRole) {
            landed = landed && centerRoleAddress &&
                actualRole == *centerRoleAddress && actualCenter == 1 &&
                actualEnvironment == 3;
        }
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"resize-postcondition scene=%@ landed=%@ role=%ld center=%ld environment=%ld expected-windowed=%@",
            sceneIdentifier, landed ? @"YES" : @"NO", (long)actualRole,
            (long)actualCenter, (long)actualEnvironment,
            expectedWindowedRole ? @"YES" : @"NO"]);
    });
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
//
// A full-screen AppLayout cannot be restored to a Chamois window by changing
// only its attributed size. RE-confirmed on the same SpringBoard build:
//
// * -[SBTransitionSwitcherModifierEvent isFullScreenToCenterWindowEvent] at
//   0x1c774138c requires the same item to move from SBLayoutRolePrimary to
//   SBLayoutRoleCenter, with from.configuration == 1.
// * _isEnteringPageCenterWindowEvent at 0x1c7740fac additionally requires
//   from.centerConfiguration == 0 and to.centerConfiguration == 1.
// * -[SBAppLayout appLayoutByModifyingRole:forItem:] at 0x1c7a36dd4 is the
//   immutable role-change API.  Apple's own center-window constructor at
//   0x1c79e0bec initializes a center layout with configuration=1 and
//   centerConfiguration=1.
//
// Only an explicit windowed_role request performs that role conversion;
// ordinary resize requests preserve their existing layout role.
static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,
                                    NSUInteger attempt) {
    NSString *bundleIdentifier = request[@"bundle_identifier"];
    NSString *sceneIdentifier = request[@"scene_identifier"];
    CGFloat width = [request[@"width"] doubleValue];
    CGFloat height = [request[@"height"] doubleValue];
    BOOL requestWindowedRole = [request[@"windowed_role"] boolValue];
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

    // A windowed-role transition cannot preserve a request that is exactly
    // the full Chamois container: that size is presentation state from the
    // Primary/full-screen layout, not a valid remembered Center-window size.
    // This can happen after Host is restored while the Scene is full-screen.
    // Use SpringBoard's own per-device defaultWindowSize as the recovery
    // input; do not invent an iPad model-specific size or overwrite a frame.
    CGSize effectiveRequestedSize = CGSizeMake(width, height);
    BOOL normalizedFullscreenSize = requestWindowedRole &&
        fabs(width - containerBounds.size.width) <= 1.0 &&
        fabs(height - containerBounds.size.height) <= 1.0;
    if (normalizedFullscreenSize)
        effectiveRequestedSize = defaultWindowSize;

    MacWSDisplayItemAttributedSize attributedSize = inferAttributedSize(
        effectiveRequestedSize, containerBounds, defaultWindowSize,
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

    NSInteger sourceRole = MacWSMessageIntegerWithObject(
        resizedLayout, NSSelectorFromString(@"layoutRoleForItem:"),
        targetItem);
    NSInteger sourceCenterConfiguration = MacWSMessageInteger(
        resizedLayout, NSSelectorFromString(@"centerConfiguration"));
    if (requestWindowedRole) {
        NSInteger *centerRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRoleCenter");
        NSInteger *primaryRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRolePrimary");
        SEL modifyRoleSelector = NSSelectorFromString(
            @"appLayoutByModifyingRole:forItem:");
        NSInteger centerRole = centerRoleAddress ? *centerRoleAddress : 0;
        NSInteger primaryRole = primaryRoleAddress ? *primaryRoleAddress : 0;
        if (centerRoleAddress && sourceRole == centerRole &&
            sourceCenterConfiguration == 1) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-windowed-role scene=%@ already-center role=%ld center=%ld",
                sceneIdentifier, (long)sourceRole,
                (long)sourceCenterConfiguration]);
        } else if (!centerRoleAddress || !primaryRoleAddress ||
                   sourceRole != primaryRole ||
                   sourceCenterConfiguration != 0) {
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-failed scene=%@ reason=unexpected-fullscreen-layout source-role=%ld primary=%ld center=%ld source-center=%ld role-symbols=%@",
                sceneIdentifier, (long)sourceRole, (long)primaryRole,
                (long)centerRole, (long)sourceCenterConfiguration,
                centerRoleAddress && primaryRoleAddress ? @"YES" : @"NO"]);
            return;
        } else {
        id roleLayout = centerRoleAddress &&
            [resizedLayout respondsToSelector:modifyRoleSelector]
            ? ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(
                  resizedLayout, modifyRoleSelector, centerRole, targetItem)
            : nil;

        // appLayoutByModifyingRole: correctly moves the item but deliberately
        // retains the source centerConfiguration. Reconstruct the immutable
        // value with the same public model fields and Page Center
        // configuration, exactly as Apple's addCenterRole path does.
        // Runtime-confirmed via SpringBoard-2026-08-02-163302.ips and
        // RE-confirmed at 0x1c7a34234: the first initializer argument is the
        // complete item set. Passing itemsWithoutCenterOrFloatingItems trips
        // SBAppLayout.m:329, "`centerItem` must be nil or included in
        // `items`". Keep every item; the separate center/floating arguments
        // classify members of that same set.
        NSArray *allItems = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"allItems"));
        id centerItem = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"centerItem"));
        id floatingItem = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"floatingItem"));
        id attributesMap = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"itemsToLayoutAttributesMap"));
        NSInteger configuration = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"configuration"));
        NSInteger sourceEnvironment = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"environment"));
        BOOL hidden = MacWSMessageBool(
            roleLayout, NSSelectorFromString(@"isHidden"));
        NSInteger displayOrdinal = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"preferredDisplayOrdinal"));
        SEL centerInitializer = NSSelectorFromString(
            @"initWithItems:centerItem:floatingItem:configuration:itemsToLayoutAttributes:centerConfiguration:environment:hidden:preferredDisplayOrdinal:");
        Class layoutClass = roleLayout ? [roleLayout class] : Nil;
        id pageCenterLayout = nil;
        BOOL centerIncluded = centerItem &&
            [allItems containsObject:centerItem];
        BOOL floatingIncluded = !floatingItem ||
            [allItems containsObject:floatingItem];
        // RE-confirmed via SpringBoard 20D67
        // -[SBMainSwitcherControllerCoordinator
        // addCenterRoleAppLayoutForDisplayItem:windowScene:completion:] at
        // 0x1c79e0d10: Apple's Page Center constructor passes environment=3.
        // _configureRequest:forSwitcherTransitionRequest:withEventLabel: then
        // takes its Chamois branch at 0x1c79e2c70 and installs the Center
        // entity plus requestedCenterConfiguration. Preserving the source
        // full-screen environment leaves that builder on the wrong branch;
        // the request can be submitted but cannot become a Center window.
        static const NSInteger pageCenterEnvironment = 3;
        if (layoutClass && centerItem == targetItem && centerIncluded &&
            floatingIncluded && attributesMap && configuration == 1 &&
            [layoutClass instancesRespondToSelector:centerInitializer]) {
            id allocated = ((id (*)(id, SEL))objc_msgSend)(
                layoutClass, @selector(alloc));
            pageCenterLayout =
                ((id (*)(id, SEL, id, id, id, NSInteger, id, NSInteger,
                          NSInteger, BOOL, NSInteger))objc_msgSend)(
                    allocated, centerInitializer, allItems, centerItem,
                    floatingItem, configuration, attributesMap, 1,
                    pageCenterEnvironment, hidden, displayOrdinal);
        }
        if (!pageCenterLayout) {
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-failed scene=%@ reason=center-role-conversion source-role=%ld source-center=%ld role-symbol=%@ role-layout=%@ center-match=%@ center-in-items=%@ floating-in-items=%@ attrs=%@ configuration=%ld",
                sceneIdentifier, (long)sourceRole,
                (long)sourceCenterConfiguration,
                centerRoleAddress ? @"YES" : @"NO",
                roleLayout ? @"YES" : @"NO",
                centerItem == targetItem ? @"YES" : @"NO",
                centerIncluded ? @"YES" : @"NO",
                floatingIncluded ? @"YES" : @"NO",
                attributesMap ? @"YES" : @"NO", (long)configuration]);
            return;
        }
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"resize-windowed-layout scene=%@ source-environment=%ld target-environment=%ld",
            sceneIdentifier, (long)sourceEnvironment,
            (long)pageCenterEnvironment]);
        resizedLayout = pageCenterLayout;
        }
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
    // 0x33 is the system keyboard/top-affordance transition source used by
    // -[SBMedusaDecoratedDeviceApplicationSceneViewController
    // performSwitcherKeyboardShortcutAction:] at 0x1c7add284.
    if ([transitionRequest respondsToSelector:NSSelectorFromString(@"setSource:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            transitionRequest, NSSelectorFromString(@"setSource:"), 0x33);
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
    MacWSVerifyResizePostcondition(coordinator, bundleIdentifier,
                                  sceneIdentifier, requestWindowedRole);
    MacWSFinishResizeRequest(path, [NSString stringWithFormat:
        @"resize-submitted scene=%@ requested=%.1fx%.1f effective=%.1fx%.1f normalized-fullscreen-size=%@ bounds=%@ default=%.1fx%.1f supported=0x%lx policy=%lu windowed-role=%@ source-role=%ld source-center=%ld target-center=%ld target-environment=%ld source=0x33 route=SBMainWorkspace",
        sceneIdentifier, width, height, effectiveRequestedSize.width,
        effectiveRequestedSize.height,
        normalizedFullscreenSize ? @"YES" : @"NO",
        NSStringFromCGRect(containerBounds),
        defaultWindowSize.width, defaultWindowSize.height,
        (unsigned long)supportedPolicies, (unsigned long)sizingPolicy,
        requestWindowedRole ? @"YES" : @"NO", (long)sourceRole,
        (long)sourceCenterConfiguration,
        (long)MacWSMessageInteger(
            resizedLayout, NSSelectorFromString(@"centerConfiguration")),
        (long)MacWSMessageInteger(
            resizedLayout, NSSelectorFromString(@"environment"))]);
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
        dprintf(fd, "version=12 pid=%d step=10 minimum=150 "
                    "fullscreen=focused-scene-enter-action-17 "
                    "resize=app-layout-transaction "
                    "exit=primary-to-page-center-environment-3 "
                    "return-size=system-default-on-fullscreen-state\n",
                    getpid());
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
