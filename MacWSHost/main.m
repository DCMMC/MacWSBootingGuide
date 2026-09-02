#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>

#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#import "MacWSControlClient.h"
#import "MacWSInteropClient.h"
#import "MacWSMenuClient.h"
#import "MacWSPerformanceMonitor.h"
#import "MacWSPerformanceGestureScenario.h"
#import "MacWSCatalystDrawableProbe.h"
#import "MacWSStreamClient.h"
#import "MacWSHostDiagnostics.h"
#import "MacWSHostRuntime.h"
#import "MacWSKeyMapping.h"
#import "MacWSCatalystDrawableReceiver.h"
#import "MacWSCatalystDrawableCompositor.h"
#import "MacWSMetalView.h"
#import "MacWSCatalystLaunchCoordinator.h"
#import "MacWSMappedFrame.h"
#include "macws_control_protocol.h"
#include "macws_catalyst_drawable_protocol.h"
#include "macws_host_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

@interface UIWindowScene (MacWSFullscreenState)
@property(nonatomic, readonly, getter=isFullScreen) BOOL fullScreen;
@end

@interface UIScene (MacWSSceneIdentity)
// RE-confirmed via UIKitCore 16.3.1 -[UIScene _sceneIdentifier] at
// 0x189322ff0. This is the FBS identifier used as SBDisplayItem's
// uniqueIdentifier, unlike UISceneSession.persistentIdentifier.
- (NSString *)_sceneIdentifier;
@end

@interface UISceneActivationRequestOptions (MacWSFullscreenRequest)
- (void)_setRequestFullscreen:(BOOL)fullscreen;
@end

@interface NSObject (MacWSMetalIOSurfaceAlignment)
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes;
@end

static NSMutableSet<NSString *> *MacWSSceneSessionsPreservingMacWindow;
static NSMutableDictionary<NSString *, NSUserActivity *> *MacWSSceneBindings;
static NSMutableSet<NSString *> *MacWSSceneCloseRequestsSent;
static NSMutableSet<NSString *> *MacWSObservedWindowIdentities;
static NSMutableSet<NSString *> *MacWSPendingWindowSceneIdentities;
static NSString *const MacWSSceneBindingsDefaultsKey =
    @"MacWSPersistedSceneWindowBindings";
static NSString *const MacWSWindowingLoadedPath =
    @"/var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded";
static CFStringRef const MacWSRequestFullscreenNotification =
    CFSTR("com.macwsguide.windowing.request-fullscreen");
static CFStringRef const MacWSRequestResizeNotification =
    CFSTR("com.macwsguide.windowing.request-resize");
static NSString *const MacWSResizeRequestDirectory =
    @"/var/mobile/Library/Preferences";
static NSString *const MacWSFullscreenRequestPrefix =
    @"com.macwsguide.windowing.fullscreen-request.";
static NSString *const MacWSResizeRequestPrefix =
    @"com.macwsguide.windowing.resize-request.";
static NSString *const MacWSControlCenterLanguageDefaultsKey =
    @"MacWSControlCenterLanguage";

static BOOL MacWSControlCenterUsesEnglish(void) {
    return [[NSUserDefaults.standardUserDefaults
        stringForKey:MacWSControlCenterLanguageDefaultsKey]
        isEqualToString:@"en"];
}

static NSString *MacWSLocalized(NSString *chinese, NSString *english) {
    return MacWSControlCenterUsesEnglish() ? english : chinese;
}

static NSString *MacWSLocalizedPhase(NSString *phase) {
    if (!MacWSControlCenterUsesEnglish() || phase.length == 0) return phase;
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        translations = @{
            @"就绪": @"Ready",
            @"操作失败": @"Operation Failed",
            @"检查并修复启动环境…": @"Checking and repairing the environment…",
            @"等待 WindowServer、触控与窗口流…": @"Waiting for WindowServer, touch, and window streaming…",
            @"停止 macOS GUI…": @"Stopping the macOS GUI…",
            @"停止工作区并修复启动环境…": @"Stopping and repairing the workspace…",
            @"重新签名并恢复信任缓存…": @"Re-signing and restoring the trust cache…",
            @"执行安全恢复…": @"Running safe recovery…",
            @"启动 macOS 应用…": @"Launching a macOS app…",
            @"启动 macOS 路径…": @"Launching a macOS path…",
            @"正在验证系统设置扩展运行时…": @"Verifying System Settings extensions…",
            @"正在增量更新系统设置依赖…": @"Updating System Settings dependencies…",
            @"正在完整修复系统设置扩展…": @"Fully repairing System Settings extensions…",
            @"请求刷新共享帧…": @"Requesting a display refresh…",
            @"安全保护已触发": @"Safety protection triggered",
            @"正在生成启动配置…": @"Generating startup configuration…",
            @"正在清理旧的服务状态…": @"Cleaning previous service state…",
            @"正在准备应用运行环境…": @"Preparing the application runtime…",
            @"正在验证图形启动条件…": @"Validating graphics startup requirements…",
            @"正在启动安全保护…": @"Starting safety protection…",
            @"正在启动 macOS 系统服务…": @"Starting macOS system services…",
            @"正在等待第一帧画面…": @"Waiting for the first frame…",
            @"macOS 工作区已就绪": @"macOS workspace is ready",
        };
    });
    return translations[phase] ?: phase;
}

@interface MacWSViewController : UIViewController
    <MacWSMetalViewStatusDelegate, MacWSInteropClientDelegate,
     UIDocumentPickerDelegate, UIDragInteractionDelegate, UITextFieldDelegate,
     UIDropInteractionDelegate>
- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable;
- (void)performURLAction:(NSString *)action;
- (void)resetPerformanceMeasurementForTargetPID:(int32_t)targetPID;
- (void)launchApplicationIdentifier:(NSString *)identifier;
- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled;
- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason;
- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason;
- (NSUserActivity *)streamRestorationActivity;
- (void)suspendSceneStream;
- (void)resumeSceneStream;
- (void)cancelBootstrapTerminal;
- (void)sceneGeometryDidChange;
- (BOOL)activateCurrentMacWindow;
- (BOOL)activateMacWindow:(MacWSStreamWindow *)window;
- (BOOL)isFullscreenWorkspace;
- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title;
- (void)reassertFullscreenScenePresentation;
- (void)restoreHardwareKeyboardFocusWithReason:(NSString *)reason;
- (BOOL)forwardHardwarePressEvent:(UIPressesEvent *)event;
- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity;
- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID;
@end

// A fullscreen workspace remains the presentation of the exact AppKit window
// from which it was entered. Resolve that owned identity uniformly anywhere
// Scene lifecycle code needs to deduplicate, prune, close or restore it.
static BOOL MacWSSceneOwnedWindowFields(NSDictionary *info,
                                        int32_t *ownerPIDOut,
                                        uint32_t *windowIDOut,
                                        uint32_t *logicalGroupIDOut) {
    MacWSStreamMode mode = (MacWSStreamMode)[info[@"mode"] unsignedIntValue];
    int32_t ownerPID = 0;
    uint32_t windowID = 0, logicalGroupID = 0;
    if (mode == MacWSStreamModeWindow) {
        ownerPID = [info[@"owner_pid"] intValue];
        windowID = [info[@"window_id"] unsignedIntValue];
        logicalGroupID = [info[@"logical_group_id"] unsignedIntValue];
    } else if (mode == MacWSStreamModeFullscreen) {
        ownerPID = [info[@"return_owner_pid"] intValue];
        windowID = [info[@"return_window_id"] unsignedIntValue];
        logicalGroupID =
            [info[@"return_logical_group_id"] unsignedIntValue];
    }
    if (ownerPID <= 1 || windowID == 0) return NO;
    if (ownerPIDOut) *ownerPIDOut = ownerPID;
    if (windowIDOut) *windowIDOut = windowID;
    if (logicalGroupIDOut) *logicalGroupIDOut = logicalGroupID;
    return YES;
}

static BOOL MacWSSceneIsFullscreenWorkspace(NSDictionary *info) {
    return [info isKindOfClass:NSDictionary.class] &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
}

static void MacWSRequestNewScene(UIScene *requestingScene,
                                 uint32_t windowID,
                                 int32_t ownerPID,
                                 uint32_t logicalGroupID,
                                 CGSize preferredSize,
                                 CGSize minimumSize,
                                 BOOL resizable,
                                 NSString *title,
                                 void (^failureHandler)(NSError *error)) {
    UIApplication *application = UIApplication.sharedApplication;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Workspace";
    activity.userInfo = @{
        @"mode": @(windowID ? MacWSStreamModeWindow : MacWSStreamModeFullscreen),
        @"window_id": @(windowID),
        @"owner_pid": @(windowID ? ownerPID : 0),
        @"logical_group_id": @(windowID ? logicalGroupID : 0),
        @"preferred_width": @(windowID ? preferredSize.width : 0),
        @"preferred_height": @(windowID ? preferredSize.height : 0),
        @"minimum_width": @(windowID ? minimumSize.width : 0),
        @"minimum_height": @(windowID ? minimumSize.height : 0),
        @"resizable": @(windowID ? resizable : NO),
        @"title": activity.title,
    };
    UISceneSession *existingSession = nil;
    if (windowID != 0 && ownerPID > 1) {
        for (UISceneSession *session in application.openSessions) {
            NSUserActivity *candidate = session.stateRestorationActivity;
            for (UIScene *scene in application.connectedScenes) {
                if (scene.session != session ||
                    ![scene isKindOfClass:UIWindowScene.class]) continue;
                UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
                    .rootViewController;
                if ([root isKindOfClass:MacWSViewController.class])
                    candidate = [(MacWSViewController *)root
                        streamRestorationActivity];
                break;
            }
            NSDictionary *info = candidate.userInfo;
            int32_t candidateOwner = 0;
            uint32_t candidateWindow = 0, candidateGroup = 0;
            if (!MacWSSceneOwnedWindowFields(info, &candidateOwner,
                    &candidateWindow, &candidateGroup) ||
                candidateOwner != ownerPID) continue;
            BOOL sameIdentity = logicalGroupID != 0 && candidateGroup != 0
                ? logicalGroupID == candidateGroup
                : windowID == candidateWindow;
            if (sameIdentity) {
                existingSession = session;
                break;
            }
        }
    }
    MacWSLog(@"scene-activation requested supportsMultiple=%@ connected=%lu open=%lu origin=%@ window=%u",
             application.supportsMultipleScenes ? @"YES" : @"NO",
             (unsigned long)application.connectedScenes.count,
             (unsigned long)application.openSessions.count,
             requestingScene.session.persistentIdentifier, windowID);
    if (existingSession) {
        MacWSLog(@"scene-activation reusing id=%@ owner=%d group=%u window=%u",
                 existingSession.persistentIdentifier, ownerPID,
                 logicalGroupID, windowID);
    }
    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    options.requestingScene = requestingScene;
    [application requestSceneSessionActivation:existingSession
                                  userActivity:activity
                                       options:options
                                  errorHandler:^(NSError *error) {
        MacWSLog(@"scene-activation failed: %@", error);
        if (failureHandler) failureHandler(error);
    }];
}

// A fullscreen Scene is a Primary AppLayout.  On iPadOS 16, asking
// SpringBoard to mutate that existing layout back to Center accepts the
// transaction but leaves the UIWindow panel-sized (runtime-confirmed by the
// resize-postcondition witness).  A newly activated ordinary window Scene,
// however, is placed by the system in the current Stage Manager layout.  Use
// that native lifecycle for the return transition and transfer ownership of
// the exact AppKit window; never close it while the old fullscreen Scene is
// being discarded.
static BOOL MacWSRequestWindowedReplacementScene(
        UIScene *requestingScene, uint32_t windowID, int32_t ownerPID,
        uint32_t logicalGroupID, CGSize preferredSize, CGSize minimumSize,
        BOOL resizable, NSString *title,
        void (^failureHandler)(NSError *error)) {
    UISceneSession *oldSession = requestingScene.session;
    NSString *oldIdentifier = oldSession.persistentIdentifier;
    if (!oldSession || !oldIdentifier.length || windowID == 0 || ownerPID <= 1)
        return NO;

    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Window";
    activity.userInfo = @{
        @"mode": @(MacWSStreamModeWindow),
        @"window_id": @(windowID),
        @"owner_pid": @(ownerPID),
        @"logical_group_id": @(logicalGroupID),
        @"preferred_width": @(preferredSize.width),
        @"preferred_height": @(preferredSize.height),
        @"minimum_width": @(minimumSize.width),
        @"minimum_height": @(minimumSize.height),
        @"resizable": @(resizable),
        @"title": activity.title,
        @"replaces_session_identifier": oldIdentifier,
    };
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:oldIdentifier];

    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    options.requestingScene = requestingScene;
    MacWSLog(@"scene-windowed-replacement requested old=%@ owner=%d window=%u group=%u preferred=%.1fx%.1f route=new-system-window-scene",
             oldIdentifier, ownerPID, windowID, logicalGroupID,
             preferredSize.width, preferredSize.height);
    [UIApplication.sharedApplication
        requestSceneSessionActivation:nil userActivity:activity options:options
        errorHandler:^(NSError *error) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:oldIdentifier];
            MacWSLog(@"scene-windowed-replacement failed old=%@ error=%@",
                     oldIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSWindowingBridgeIsLoadedWithCapability(
        NSString *capability) {
    NSString *witness = [NSString stringWithContentsOfFile:
        MacWSWindowingLoadedPath encoding:NSUTF8StringEncoding error:nil];
    NSRange versionMarker = [witness rangeOfString:@"version="];
    NSInteger version = versionMarker.location == NSNotFound ? 0 :
        [[witness substringFromIndex:NSMaxRange(versionMarker)] integerValue];
    NSRange pidMarker = [witness rangeOfString:@" pid="];
    pid_t publisherPID = pidMarker.location == NSNotFound ? 0 :
        (pid_t)[[witness substringFromIndex:NSMaxRange(pidMarker)] intValue];
    // The witness is published by SpringBoard only after both Darwin request
    // observers are installed.  A package update can leave that file behind
    // while a later SpringBoard generation is running without the tweak.
    // Runtime-confirmed on 2026-08-17: witness pid=342, live SpringBoard
    // pid=10865, and two Host maximize notifications produced no SpringBoard
    // log or geometry transaction. Treat publisher liveness as part of the
    // readiness contract instead of accepting a stale capability string.
    BOOL publisherAlive = publisherPID > 1 &&
        (kill(publisherPID, 0) == 0 || errno == EPERM);
    return version >= 16 && publisherAlive &&
        [witness containsString:capability];
}

static BOOL MacWSWindowingFullscreenBridgeIsLoaded(void) {
    return MacWSWindowingBridgeIsLoadedWithCapability(
        @"fullscreen=exact-scene-activate-then-maximization-toggle-action-17");
}

static BOOL MacWSWindowingResizeBridgeIsLoaded(void) {
    return MacWSWindowingBridgeIsLoadedWithCapability(
        @"resize=app-layout-transaction");
}

static BOOL MacWSRequestNativeSceneSizeWithRole(UIWindowScene *scene,
                                                CGSize preferredSize,
                                                BOOL requestWindowedRole) {
    if (!scene || !scene.session || !isfinite(preferredSize.width) ||
        !isfinite(preferredSize.height) || preferredSize.width < 150.0 ||
        preferredSize.height < 150.0) {
        return NO;
    }
    if (!MacWSWindowingResizeBridgeIsLoaded()) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=windowing-bridge-not-loaded",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=fbs-scene-identifier-missing",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSResizeRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"width": @(round(preferredSize.width)),
        @"height": @(round(preferredSize.height)),
        @"windowed_role": @(requestWindowedRole),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    BOOL wrote = [request writeToFile:path atomically:YES];
    if (!wrote) {
        MacWSLog(@"scene-native-size unavailable id=%@ fbs=%@ requested=%.1fx%.1f reason=request-write-failed",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height);
        return NO;
    }

    MacWSLog(@"scene-native-size requested id=%@ fbs=%@ requested=%.1fx%.1f windowed-role=%@ route=SBMainWorkspace",
             scene.session.persistentIdentifier, sceneIdentifier,
             preferredSize.width, preferredSize.height,
             requestWindowedRole ? @"YES" : @"NO");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestResizeNotification, NULL, NULL, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        MacWSLog(@"scene-native-size result id=%@ fbs=%@ requested=%.1fx%.1f windowed-role=%@ fills-screen=%@ bounds=%.1fx%.1f",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height,
                 requestWindowedRole ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 sceneBounds.size.width, sceneBounds.size.height);
    });
    return YES;
}

static BOOL MacWSRequestCurrentSceneMaximization(
        UIWindowScene *scene, BOOL expectedFullscreen,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive) {
        MacWSLog(@"scene-fullscreen unavailable reason=scene-not-active session=%@",
                 scene.session.persistentIdentifier ?: @"none");
        return NO;
    }

    if (!MacWSWindowingFullscreenBridgeIsLoaded()) {
        MacWSLog(@"scene-fullscreen unavailable reason=windowing-bridge-not-loaded session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-fullscreen unavailable reason=fbs-scene-identifier-missing session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    UIWindow *sceneWindow = nil;
    for (UIWindow *candidate in scene.windows) {
        if (candidate.isKeyWindow) {
            sceneWindow = candidate;
            break;
        }
        if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
            sceneWindow = candidate;
    }
    // UIWindowScene.coordinateSpace is panel-sized under Stage Manager even
    // while the actual app window is 1004x807 (runtime-confirmed on scene
    // DCEB78D2).  UIWindow.bounds is the user-visible scene extent and is the
    // only valid source/postcondition for the maximize transaction.
    CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                     : scene.coordinateSpace.bounds;
    CGRect screenBounds = scene.screen.bounds;
    BOOL sourceGeometryFullscreen =
        fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
        fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
        fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
        fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSFullscreenRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"expected_fullscreen": @(expectedFullscreen),
        @"source_geometry_fullscreen": @(sourceGeometryFullscreen),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    if (![request writeToFile:path atomically:YES]) {
        MacWSLog(@"scene-fullscreen unavailable reason=request-write-failed session=%@ fbs=%@",
                 scene.session.persistentIdentifier, sceneIdentifier);
        return NO;
    }

    MacWSLog(@"scene-maximization requested session=%@ fbs=%@ expected-fullscreen=%@ source-geometry-fullscreen=%@ route=springboard-maximization-toggle-action-17 current-bounds=%@ screen-bounds=%@",
             scene.session.persistentIdentifier, sceneIdentifier,
             expectedFullscreen ? @"YES" : @"NO",
             sourceGeometryFullscreen ? @"YES" : @"NO",
             NSStringFromCGRect(sceneBounds), NSStringFromCGRect(screenBounds));
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestFullscreenNotification, NULL, NULL, true);

    // The SpringBoard transaction is asynchronous.  A Primary AppLayout is
    // not sufficient evidence of full-screen geometry under Stage Manager;
    // runtime showed Primary/center=0 while this Scene remained 1194x807 on a
    // 1389x970 screen.  Re-sample the owning UIWindowScene after the system
    // action; MacWSWindowing's AppLayout record is a model observation only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        BOOL supportsState = [scene respondsToSelector:@selector(isFullScreen)];
        BOOL systemState = supportsState && scene.isFullScreen;
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
            fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
            fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        MacWSLog(@"scene-maximization UIKit-observation session=%@ expected-fullscreen=%@ is-fullscreen=%@ fills-screen=%@ bounds=%@ screen=%@ authoritative-postcondition=UIKit-scene-screen-geometry",
                 scene.session.persistentIdentifier,
                 expectedFullscreen ? @"YES" : @"NO",
                 systemState ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 NSStringFromCGRect(sceneBounds),
                 NSStringFromCGRect(screenBounds));
        (void)failureHandler;
    });
    return YES;
}

// UIKit's current-session fullscreen activation is the private route closest
// to video/game presentation: it asks FrontBoard to make this exact existing
// session fullscreen rather than resizing a Metal layer.  Earlier builds lost
// the display subscription when FrontBoard reconnected the Scene; the Scene
// ownership and compositor handoff are now persistent, so retry the real
// system request before falling back to the Stage Manager maximization bridge.
static BOOL MacWSRequestCurrentSceneImmersiveFullscreen(
        UIWindowScene *scene, NSUserActivity *activity,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive)
        return NO;
    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    SEL selector = @selector(_setRequestFullscreen:);
    if (![options respondsToSelector:selector]) return NO;
    [options _setRequestFullscreen:YES];
    options.requestingScene = scene;
    MacWSLog(@"scene-immersive requested session=%@ fbs=%@ route=current-session-activation",
             scene.session.persistentIdentifier,
             [scene respondsToSelector:@selector(_sceneIdentifier)]
                ? [scene _sceneIdentifier] : @"unknown");
    [UIApplication.sharedApplication
        requestSceneSessionActivation:scene.session
        userActivity:activity
        options:options
        errorHandler:^(NSError *error) {
            MacWSLog(@"scene-immersive failed session=%@ error=%@",
                     scene.session.persistentIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSSendCloseWindow(uint32_t windowID, int32_t ownerPID,
                                 int *errorOut) {
    if (windowID == 0 || ownerPID <= 1) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindCloseWindow,
        .sceneID = MacWSInputSceneForWindow(windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = ownerPID,
        .source = MacWSInputSourceUnknown,
    };
    return MacWSSendInputRecord(&record, errorOut);
}

static NSString *MacWSWindowIdentity(int32_t ownerPID, uint32_t windowID,
                                     uint32_t logicalGroupID) {
    if (ownerPID <= 1 || windowID == 0) return nil;
    return logicalGroupID != 0
        ? [NSString stringWithFormat:@"%d:g:%u", ownerPID, logicalGroupID]
        : [NSString stringWithFormat:@"%d:w:%u", ownerPID, windowID];
}

static NSDictionary *MacWSPersistedSceneBinding(NSString *identifier) {
    if (!identifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    id value = bindings[identifier];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void MacWSSetPersistedSceneBinding(NSString *identifier,
                                          NSDictionary *info) {
    if (!identifier.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *bindings = [[defaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey] mutableCopy] ?:
        [NSMutableDictionary dictionary];
    if (info) bindings[identifier] = info;
    else [bindings removeObjectForKey:identifier];
    [defaults setObject:bindings forKey:MacWSSceneBindingsDefaultsKey];
    // Binding changes are rare lifecycle transactions. Flush them before a
    // possible FrontBoard process eviction so a reconnected Scene does not
    // regress to its original bootstrap activity.
    [defaults synchronize];
}

static NSUserActivity *MacWSPersistedSceneActivity(NSString *identifier) {
    NSDictionary *info = MacWSPersistedSceneBinding(identifier);
    if (!MacWSSceneOwnedWindowFields(info, NULL, NULL, NULL) &&
        !MacWSSceneIsFullscreenWorkspace(info)) return nil;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [info[@"title"] isKindOfClass:NSString.class]
        ? info[@"title"] : @"MacWS Window";
    activity.userInfo = info;
    return activity;
}

static NSUserActivity *MacWSRecoverOrphanedWorkspaceActivity(
        UISceneSession *newSession) {
    NSString *newIdentifier = newSession.persistentIdentifier;
    if (!newIdentifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    if (bindings.count == 0) return nil;
    NSString *candidateIdentifier = nil;
    NSDictionary *candidateInfo = nil;
    for (NSString *identifier in bindings) {
        if ([identifier isEqualToString:newIdentifier]) continue;
        NSDictionary *info = [bindings[identifier]
            isKindOfClass:NSDictionary.class] ? bindings[identifier] : nil;
        if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeFullscreen)
            continue;
        int32_t ownerPID = 0;
        BOOL ownsReturnWindow = MacWSSceneOwnedWindowFields(
            info, &ownerPID, NULL, NULL);
        if (ownsReturnWindow) {
            errno = 0;
            if (kill(ownerPID, 0) != 0 && errno == ESRCH) continue;
        }
        // More than one orphaned workspace cannot be assigned safely without
        // a stable token from UIKit. Refuse ambiguity instead of restoring an
        // unrelated AppKit window into the new Scene.
        if (candidateInfo) return nil;
        candidateIdentifier = identifier;
        candidateInfo = info;
    }
    if (!candidateInfo) return nil;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:candidateIdentifier];
    [MacWSSceneBindings removeObjectForKey:candidateIdentifier];
    MacWSSetPersistedSceneBinding(newIdentifier, candidateInfo);
    MacWSSetPersistedSceneBinding(candidateIdentifier, nil);
    MacWSLog(@"scene-workspace-binding-migrated old=%@ new=%@ return-window=%u owner=%d",
             candidateIdentifier, newIdentifier,
             [candidateInfo[@"return_window_id"] unsignedIntValue],
             [candidateInfo[@"return_owner_pid"] intValue]);
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [candidateInfo[@"title"] isKindOfClass:NSString.class]
        ? candidateInfo[@"title"] : @"MacWS Workspace";
    activity.userInfo = candidateInfo;
    return activity;
}

// UISceneSession.stateRestorationActivity is not updated continuously while a
// Scene changes from the bootstrap workspace to an exact macOS window. Keep
// the live binding by persistent session identifier, and make closing a
// transaction that is idempotent across the explicit close button,
// didDiscardSceneSessions:, and a late sceneDidDisconnect: callback.
static void MacWSRememberSceneBinding(UISceneSession *session,
                                      NSUserActivity *activity) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    // Once this session has committed a close transaction, a late state
    // restoration callback must not resurrect the binding and send a second
    // performClose: while UIKit is tearing the Scene down.
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    if (MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL) ||
        MacWSSceneIsFullscreenWorkspace(info)) {
        MacWSSceneBindings[identifier] = activity;
        [MacWSSceneCloseRequestsSent removeObject:identifier];
        MacWSSetPersistedSceneBinding(identifier, info);
    } else {
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);
    }
}

static BOOL MacWSCloseMacWindowForSceneSession(UISceneSession *session,
                                                NSString *source) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return NO;
    if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
        return NO;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return YES;
    NSUserActivity *activity = MacWSSceneBindings[identifier] ?:
        MacWSPersistedSceneActivity(identifier) ?:
        session.stateRestorationActivity;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL))
        return NO;
    int sendError = 0;
    BOOL sent = MacWSSendCloseWindow(windowID, ownerPID, &sendError);
    if (sent) {
        [MacWSSceneCloseRequestsSent addObject:identifier];
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);

        // Runtime-confirmed on macOS 13.4 in this chroot: after Terminal's
        // final window accepted performClose: and NSApplication terminated,
        // lsappinfo immediately stopped listing the process but Dock retained
        // its running dot. Restarting only Dock rebuilt the correct state via
        // its imported _LSCopyRunningApplicationArray. Ask root hostd to do
        // that bounded repair only after it proves this exact owner PID has
        // exited. A vetoed close or a process with another window stays alive
        // and therefore cannot trigger the repair.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     450 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSControlClient *client = [MacWSControlClient new];
            [client performOperation:@MACWS_CONTROL_OP_REFRESH_DOCK
                           arguments:@{
                               @MACWS_CONTROL_KEY_TARGET_PID: @(ownerPID)
                           }
                          completion:^(NSDictionary<NSString *,id> *reply) {
                MacWSLog(@"scene-close dock-refresh target=%d ok=%@ message=%@",
                         ownerPID,
                         [reply[@"ok"] boolValue] ? @"YES" : @"NO",
                         reply[@"message"] ?: @"");
            }];
        });
    }
    MacWSLog(@"scene-close source=%@ id=%@ window=%u target=%d sent=%@ errno=%d",
             source ?: @"unknown", identifier, windowID, ownerPID,
             sent ? @"YES" : @"NO", sendError);
    return sent;
}

typedef void (^MacWSCompactMenuSelection)(MacWSMenuItem *item);

// UIAlertController action sheets have a fixed iOS row metric and do not
// relayout reliably when actions are appended after presentation. A macOS menu
// snapshot is already a complete immutable tree, so render one compact table
// only after that tree arrives. This keeps every row present on the first
// frame and gives the semantic menu macOS-like density without private UIKit
// APIs.
@interface MacWSCompactMenuController : UIViewController
    <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection;
@end

@implementation MacWSCompactMenuController {
    NSArray<MacWSMenuItem *> *_items;
    MacWSCompactMenuSelection _selection;
    UITableView *_tableView;
}

- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _items = [items copy];
    _selection = [selection copy];
    self.modalPresentationStyle = UIModalPresentationPopover;
    if (appearance == MacWSMenuAppearanceDark)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

    CGFloat width = 168.0;
    CGFloat height = 2.0;
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0]
    };
    NSDictionary *shortcutAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0]
    };
    for (MacWSMenuItem *item in _items) {
        if (item.flags & MacWSMenuNodeHidden) continue;
        if (item.flags & MacWSMenuNodeSeparator) {
            height += 8.0;
            continue;
        }
        CGFloat titleWidth = [item.title sizeWithAttributes:titleAttributes].width;
        CGFloat shortcutWidth = [item.shortcut
            sizeWithAttributes:shortcutAttributes].width;
        width = MAX(width, titleWidth + shortcutWidth +
            ((item.flags & MacWSMenuNodeHasSubmenu) ? 60.0 : 48.0));
        height += 29.0;
    }
    self.preferredContentSize = CGSizeMake(MIN(320.0, ceil(width)),
                                            MIN(380.0, ceil(height)));
    return self;
}

- (void)loadView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                               style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(1, 0, 1, 0);
    _tableView.scrollEnabled = self.preferredContentSize.height >= 380.0;
    _tableView.showsVerticalScrollIndicator = _tableView.scrollEnabled;
    _tableView.layer.cornerRadius = 8.0;
    _tableView.clipsToBounds = YES;
    self.view = _tableView;
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_items.count;
}

- (CGFloat)tableView:(UITableView *)tableView
  heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    return (item.flags & MacWSMenuNodeSeparator) ? 8.0 : 29.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if (item.flags & MacWSMenuNodeSeparator) {
        UITableViewCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"MacWSMenuSeparator"];
        if (!cell) {
            cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
              reuseIdentifier:@"MacWSMenuSeparator"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = UIColor.clearColor;
            UIView *line = [UIView new];
            line.tag = 91;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            line.backgroundColor = UIColor.separatorColor;
            [cell.contentView addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:
                    cell.contentView.leadingAnchor constant:8],
                [line.trailingAnchor constraintEqualToAnchor:
                    cell.contentView.trailingAnchor constant:-8],
                [line.centerYAnchor constraintEqualToAnchor:
                    cell.contentView.centerYAnchor],
                [line.heightAnchor constraintEqualToConstant:0.5],
            ]];
        }
        return cell;
    }

    UITableViewCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"MacWSMenuItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:@"MacWSMenuItem"];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        UIView *selection = [UIView new];
        selection.backgroundColor = UIColor.systemBlueColor;
        cell.selectedBackgroundView = selection;
    }
    NSString *prefix = @"";
    if (item.flags & MacWSMenuNodeChecked) prefix = @"✓  ";
    else if (item.flags & MacWSMenuNodeMixed) prefix = @"—  ";
    cell.textLabel.text = [prefix stringByAppendingString:item.title ?: @""];
    NSString *suffix = item.shortcut ?: @"";
    if (item.flags & MacWSMenuNodeHasSubmenu)
        suffix = suffix.length ? [suffix stringByAppendingString:@"   ›"] : @"›";
    cell.detailTextLabel.text = suffix;
    BOOL enabled = (item.flags & MacWSMenuNodeEnabled) != 0;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if ((item.flags & (MacWSMenuNodeHidden | MacWSMenuNodeSeparator)) ||
        (item.flags & MacWSMenuNodeEnabled) == 0) return;
    MacWSCompactMenuSelection selection = _selection;
    if (selection) selection(item);
}

@end

@implementation MacWSViewController {
    NSString *_sceneIdentifier;
    MacWSStreamMode _streamMode;
    uint32_t _windowID;
    int32_t _windowOwnerPID;
    uint32_t _windowGroupID;
    CGSize _windowMinimumSize;
    CGSize _windowPreferredSize;
    BOOL _windowResizable;
    MacWSControlClient *_controlClient;
    MacWSInteropClient *_interopClient;
    MacWSMenuClient *_menuClient;
    MacWSMenuSnapshot *_menuSnapshot;
    UIVisualEffectView *_semanticMenuBar;
    NSLayoutConstraint *_semanticMenuHeightConstraint;
    UIScrollView *_semanticMenuScroll;
    UIStackView *_semanticMenuTitles;
    UIViewController *_semanticMenuPanel;
    UIControl *_semanticMenuDismissLayer;
    UIVisualEffectView *_controlPanel;
    UIControl *_controlDismissLayer;
    UIVisualEffectView *_showControlsMaterial;
    UIButton *_showControlsButton;
    UILabel *_serviceLabel;
    UILabel *_phaseLabel;
    UILabel *_rootfsLabel;
    UILabel *_windowServerLabel;
    UILabel *_bridgeLabel;
    UILabel *_frameLabel;
    UILabel *_statusLabel;
    UILabel *_inputLabel;
    UILabel *_interopLabel;
    UILabel *_noticeLabel;
    UILabel *_controlTitleLabel;
    UILabel *_controlSubtitleLabel;
    UILabel *_touchSectionLabel;
    UILabel *_displaySectionLabel;
    UILabel *_performanceSectionLabel;
    UILabel *_applicationsSectionLabel;
    UILabel *_interopSectionLabel;
    UILabel *_zoomSectionLabel;
    UILabel *_languageSectionLabel;
    UILabel *_startupLogSectionLabel;
    UILabel *_experimentalTitleLabel;
    UILabel *_experimentalDetailLabel;
    UILabel *_systemHUDTitleLabel;
    UILabel *_systemHUDDetailLabel;
    UIButton *_primaryButton;
    UIButton *_repairDesktopButton;
    UIButton *_repairButton;
    UIButton *_recoverButton;
    UIButton *_captureButton;
    UIButton *_logsButton;
    UIButton *_exportButton;
    UIButton *_windowPickerButton;
    UIButton *_closeWindowButton;
    UIButton *_menuBarButton;
    UIButton *_clipboardButton;
    UIButton *_importButton;
    UIButton *_macFilesButton;
    UIButton *_keyboardButton;
    UIButton *_retryStartupButton;
    UITextField *_keyboardProxy;
    UIView *_softwareKeyBar;
    NSLayoutConstraint *_softwareKeyBarHeightConstraint;
    UITextField *_appSearchField;
    NSArray<UIButton *> *_softModifierButtons;
    uint32_t _softModifiers;
    UITextView *_logsView;
    UISwitch *_experimentalSwitch;
    UISegmentedControl *_inputModeControl;
    UISegmentedControl *_densityControl;
    UISegmentedControl *_presentationResolutionControl;
    UISegmentedControl *_zoomScaleControl;
    UISegmentedControl *_performanceHUDControl;
    UISegmentedControl *_languageControl;
    UISwitch *_systemPerformanceHUDSwitch;
    UIButton *_performanceResetButton;
    UIButton *_performanceExportButton;
    UIButton *_performanceRunButton;
    UIButton *_resetZoomButton;
    NSArray<UIButton *> *_applicationButtons;
    MacWSMetalView *_metalView;
    NSTimer *_statusTimer;
    NSDictionary<NSString *, id> *_latestStatus;
    BOOL _experimentalTouched;
    uint64_t _inputLogSequence;
    NSString *_lastLoggedControlSummary;
    NSString *_lastStartupLog;
    NSArray<MacWSStreamWindow *> *_streamWindows;
    NSArray<NSURL *> *_receivedMacOSFiles;
    int32_t _pendingFinderWindowPID;
    NSUInteger _pendingFinderMenuAttempts;
    BOOL _finderMenuRequestInFlight;
    int32_t _pendingApplicationWindowPID;
    NSString *_pendingApplicationIdentifier;
    NSUInteger _pendingApplicationWindowAttempts;
    BOOL _pendingApplicationWindowRetryScheduled;
    uint32_t _pendingApplicationCandidateWindowID;
    CFTimeInterval _pendingApplicationCandidateSince;
    int32_t _fullscreenCatalogRetainedInputPID;
    uint32_t _fullscreenActivatedInputWindowID;
    int32_t _fullscreenActivatedInputOwnerPID;
    BOOL _bootstrapTerminalPending;
    BOOL _bootstrapWindowReplacementPending;
    BOOL _bootstrapWorkspaceStartInFlight;
    BOOL _bootstrapWorkspaceStartAttempted;
    BOOL _targetWindowObservedInCatalog;
    BOOL _targetWindowMissingCheckPending;
    BOOL _sceneDestructionRequested;
    uint64_t _targetWindowMissingSerial;
    BOOL _workspaceReturnValid;
    uint32_t _workspaceReturnWindowID;
    int32_t _workspaceReturnOwnerPID;
    uint32_t _workspaceReturnGroupID;
    CGSize _workspaceReturnMinimumSize;
    CGSize _workspaceReturnPreferredSize;
    CGSize _workspaceReturnSceneSize;
    BOOL _workspaceReturnResizable;
    NSString *_workspaceReturnTitle;
}

- (BOOL)prefersStatusBarHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return _streamMode == MacWSStreamModeFullscreen
        ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)updateImmersivePresentation {
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    BOOL expected = _streamMode == MacWSStreamModeFullscreen;
    for (NSNumber *delay in @[@0, @250, @1250]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     delay.longLongValue * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIWindowScene *scene = self.view.window.windowScene;
            BOOL actualStatusHidden = scene.statusBarManager.statusBarHidden;
            MacWSLog(@"immersive-postcondition expected=%@ status-request=%@ status-hidden=%@ home-indicator-auto-hide=%@ deferred-edges=%lu bounds=%@ screen=%@ safe-insets=%@",
                     expected ? @"YES" : @"NO",
                     self.prefersStatusBarHidden ? @"YES" : @"NO",
                     actualStatusHidden ? @"YES" : @"NO",
                     self.prefersHomeIndicatorAutoHidden ? @"YES" : @"NO",
                     (unsigned long)self.preferredScreenEdgesDeferringSystemGestures,
                     NSStringFromCGRect(scene.coordinateSpace.bounds),
                     NSStringFromCGRect(scene.screen.bounds),
                     NSStringFromUIEdgeInsets(self.view.safeAreaInsets));
        });
    }
}

- (void)updateWorkspaceChrome {
    BOOL fullscreen = _streamMode == MacWSStreamModeFullscreen;
    _semanticMenuBar.hidden = fullscreen;
    _semanticMenuHeightConstraint.constant = fullscreen ? 0.0 : 26.0;
    if (_menuBarButton) {
        [self setButton:_menuBarButton
                  title:fullscreen
                      ? MacWSLocalized(@"进入窗口模式", @"Enter Window Mode")
                      : MacWSLocalized(@"打开全屏 macOS 工作区",
                                       @"Open Full-Screen macOS Workspace")
                  image:fullscreen
                      ? @"arrow.down.right.and.arrow.up.left"
                      : @"arrow.up.left.and.arrow.down.right"];
    }
    _closeWindowButton.hidden = fullscreen || _windowID == 0;
    [self.view setNeedsLayout];
}

- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity {
    NSDictionary *info = activity.userInfo;
    BOOL explicitFullscreenRestoration = activity &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
    if (_streamMode != MacWSStreamModeFullscreen ||
        !explicitFullscreenRestoration) return;

    // An explicit restored workspace remains a real desktop even when its
    // optional return AppKit window is already gone.  The old early return
    // left both bootstrap flags set whenever return_window_id was zero, so the
    // next Maps/Terminal catalog entry converted the live fullscreen Scene
    // into a per-window Scene.  A nil activity still represents the genuine
    // first-launch placeholder and deliberately keeps these flags set.
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    if ([info[@"return_window_id"] unsignedIntValue] == 0 ||
        [info[@"return_owner_pid"] intValue] <= 1) return;
    _workspaceReturnValid = YES;
    _workspaceReturnWindowID = [info[@"return_window_id"] unsignedIntValue];
    _workspaceReturnOwnerPID = [info[@"return_owner_pid"] intValue];
    _workspaceReturnGroupID = [info[@"return_logical_group_id"] unsignedIntValue];
    _workspaceReturnMinimumSize = CGSizeMake(
        [info[@"return_minimum_width"] doubleValue],
        [info[@"return_minimum_height"] doubleValue]);
    _workspaceReturnPreferredSize = CGSizeMake(
        [info[@"return_preferred_width"] doubleValue],
        [info[@"return_preferred_height"] doubleValue]);
    _workspaceReturnSceneSize = CGSizeMake(
        [info[@"return_scene_width"] doubleValue],
        [info[@"return_scene_height"] doubleValue]);
    _workspaceReturnResizable = [info[@"return_resizable"] boolValue];
    _workspaceReturnTitle = [info[@"return_title"] isKindOfClass:NSString.class]
        ? [info[@"return_title"] copy] : @"MacWS Window";
}

- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID {
    if (_streamMode != MacWSStreamModeFullscreen ||
        !_workspaceReturnValid || _workspaceReturnOwnerPID != ownerPID ||
        _workspaceReturnWindowID != windowID) return NO;

    // The return window is navigation history, not the owner of the full
    // desktop stream.  If that AppKit process exits while the workspace is
    // visible, preserve the compositor subscription and merely make the
    // transition back to that exact window unavailable.
    _workspaceReturnValid = NO;
    _workspaceReturnWindowID = 0;
    _workspaceReturnOwnerPID = 0;
    _workspaceReturnGroupID = 0;
    _workspaceReturnMinimumSize = CGSizeZero;
    _workspaceReturnPreferredSize = CGSizeZero;
    _workspaceReturnSceneSize = CGSizeZero;
    _workspaceReturnResizable = NO;
    _workspaceReturnTitle = nil;
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    [self setNotice:@"来源窗口已关闭；完整 macOS 工作区仍保持运行。"
             success:YES];
    MacWSLog(@"workspace-return-detached owner-missing pid=%d window=%u scene=%@",
             ownerPID, windowID,
             self.view.window.windowScene.session.persistentIdentifier);
    return YES;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sceneIdentifier = [identifier copy];
        _streamMode = streamMode;
        _windowID = windowID;
        _windowOwnerPID = windowID ? ownerPID : 0;
        _windowGroupID = windowID ? logicalGroupID : 0;
        _windowMinimumSize = windowID ? minimumSize : CGSizeZero;
        _windowPreferredSize = windowID ? preferredSize : CGSizeZero;
        _windowResizable = windowID ? resizable : NO;
        _bootstrapTerminalPending = streamMode != MacWSStreamModeWindow ||
            windowID == 0;
        _bootstrapWindowReplacementPending = _bootstrapTerminalPending;
        _controlClient = [MacWSControlClient new];
        _interopClient = [MacWSInteropClient new];
        _interopClient.delegate = self;
        _menuClient = [MacWSMenuClient new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults objectForKey:@"MacWSExperimentalMode"] == nil)
            [defaults setBool:YES forKey:@"MacWSExperimentalMode"];
        _experimentalTouched = YES;
    }
    return self;
}

static UILabel *MacWSMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title image:(NSString *)imageName
                        action:(SEL)action prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = prominent
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    configuration.imagePadding = 8;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setButton:(UIButton *)button title:(NSString *)title image:(NSString *)imageName {
    UIButtonConfiguration *configuration = [button.configuration copy];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    button.configuration = configuration;
}

- (UIStackView *)statusRowWithTitle:(NSString *)title
                              value:(UILabel * __strong *)valueOut {
    UILabel *name = MacWSMakeLabel(title,
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
        UIColor.secondaryLabelColor);
    UILabel *value = MacWSMakeLabel(@"检查中…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.tertiaryLabelColor);
    value.textAlignment = NSTextAlignmentRight;
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, value]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    if (valueOut) *valueOut = value;
    return row;
}

- (UIView *)divider {
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.45];
    [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return line;
}

- (UILabel *)sectionTitle:(NSString *)title {
    UILabel *label = MacWSMakeLabel(title.uppercaseString,
        [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
        UIColor.secondaryLabelColor);
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    return label;
}

- (UIButton *)keyboardAccessoryButton:(NSString *)title
                                   tag:(NSInteger)tag
                              modifier:(BOOL)modifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    button.configuration = configuration;
    button.tag = tag;
    [button addTarget:self
               action:modifier ? @selector(softModifierTapped:)
                               : @selector(softKeyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)makeKeyboardAccessoryView {
    UIInputView *input = [[UIInputView alloc]
        initWithFrame:CGRectMake(0, 0, 0, 52)
        inputViewStyle:UIInputViewStyleKeyboard];
    UIButton *escape = [self keyboardAccessoryButton:@"esc" tag:0xff1b
                                             modifier:NO];
    UIButton *control = [self keyboardAccessoryButton:@"control" tag:(1u << 18)
                                              modifier:YES];
    UIButton *option = [self keyboardAccessoryButton:@"option" tag:(1u << 19)
                                             modifier:YES];
    UIButton *command = [self keyboardAccessoryButton:@"⌘" tag:(1u << 20)
                                              modifier:YES];
    UIButton *shift = [self keyboardAccessoryButton:@"⇧" tag:(1u << 17)
                                            modifier:YES];
    UIButton *tab = [self keyboardAccessoryButton:@"tab" tag:0xff09
                                          modifier:NO];
    UIButton *left = [self keyboardAccessoryButton:@"←" tag:0xff51
                                           modifier:NO];
    UIButton *up = [self keyboardAccessoryButton:@"↑" tag:0xff52
                                         modifier:NO];
    UIButton *down = [self keyboardAccessoryButton:@"↓" tag:0xff54
                                           modifier:NO];
    UIButton *right = [self keyboardAccessoryButton:@"→" tag:0xff53
                                            modifier:NO];
    UIButton *dismiss = [self keyboardAccessoryButton:@"键盘↓" tag:0
                                              modifier:NO];
    dismiss.accessibilityIdentifier = @"dismiss-keyboard";
    _softModifierButtons = @[control, option, command, shift];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        escape, control, option, command, shift, tab, left, up, down, right,
        dismiss
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    [scroll addSubview:stack];
    [input addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:input.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:input.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:input.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:input.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    return input;
}

- (void)renderSemanticMenuTitles {
    if (!_semanticMenuTitles) return;
    for (UIView *view in [_semanticMenuTitles.arrangedSubviews copy]) {
        [_semanticMenuTitles removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MacWSMenuItem *> *roots = [_menuSnapshot childrenOfItemID:0];
    NSMutableArray<MacWSMenuItem *> *visible = [NSMutableArray array];
    for (MacWSMenuItem *item in roots) {
        if ((item.flags & MacWSMenuNodeHidden) == 0 && item.title.length)
            [visible addObject:item];
    }
    UIButton *apple = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *appleConfiguration =
        [UIButtonConfiguration plainButtonConfiguration];
    appleConfiguration.title = @"";
    appleConfiguration.baseForegroundColor = UIColor.labelColor;
    appleConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(0, 7, 0, 7);
    appleConfiguration.titleTextAttributesTransformer =
        ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:16
                weight:UIFontWeightSemibold];
            return result;
        };
    apple.configuration = appleConfiguration;
    apple.userInteractionEnabled = NO;
    apple.accessibilityLabel = @"Apple 菜单";
    [_semanticMenuTitles addArrangedSubview:apple];
    // The containing UIScrollView already handles narrow iPad windows. Keep
    // every real macOS root menu visible instead of collapsing to three
    // arbitrary titles and an iOS-style "more" action.
    NSUInteger limit = visible.count;
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSMenuItem *item = visible[index];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration =
            [UIButtonConfiguration plainButtonConfiguration];
        configuration.title = item.title;
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
        configuration.titleTextAttributesTransformer =
            ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *result = [attributes mutableCopy];
                result[NSFontAttributeName] = [UIFont systemFontOfSize:13.0
                    weight:index == 0 ? UIFontWeightSemibold
                                      : UIFontWeightRegular];
                return result;
            };
        button.configuration = configuration;
        button.configurationUpdateHandler = ^(UIButton *updated) {
            UIButtonConfiguration *state = [updated.configuration copy];
            state.baseForegroundColor = updated.highlighted
                ? UIColor.whiteColor : UIColor.labelColor;
            state.background.backgroundColor = updated.highlighted
                ? UIColor.systemBlueColor : UIColor.clearColor;
            state.background.cornerRadius = 4.0;
            updated.configuration = state;
        };
        button.tag = (NSInteger)item.itemID;
        button.accessibilityLabel = [NSString stringWithFormat:
            @"%@ 菜单", item.title];
        [button addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:button];
    }
    if (visible.count == 0) {
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        [retry setTitle:@"macOS 菜单…" forState:UIControlStateNormal];
        retry.tag = -1;
        [retry addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:retry];
    }
}

- (void)applyMacOSMenuAppearance:(MacWSMenuAppearance)appearance {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (appearance == MacWSMenuAppearanceDark)
        style = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        style = UIUserInterfaceStyleLight;
    _semanticMenuBar.overrideUserInterfaceStyle = style;
    _showControlsMaterial.overrideUserInterfaceStyle = style;
    _controlPanel.overrideUserInterfaceStyle = style;
    [_semanticMenuBar setNeedsLayout];
    [_showControlsMaterial setNeedsLayout];
    [_controlPanel setNeedsLayout];
}

- (void)refreshSemanticMenuWithCompletion:(void (^ _Nullable)(
        MacWSMenuSnapshot * _Nullable, NSError * _Nullable))completion {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        if (completion) completion(nil, [NSError errorWithDomain:@"MacWSMenu"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"全屏工作区使用真实 macOS 菜单栏"}]);
        return;
    }
    [_menuClient requestSnapshotForPID:_windowOwnerPID windowID:_windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            if (snapshot && snapshot.windowID == self->_windowID &&
                snapshot.ownerPID == self->_windowOwnerPID) {
                self->_menuSnapshot = snapshot;
                [self applyMacOSMenuAppearance:snapshot.appearance];
                [self renderSemanticMenuTitles];
            }
            if (completion) completion(snapshot, error);
        }];
}

- (BOOL)activateCurrentMacWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(_windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = _windowOwnerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    return YES;
}

- (BOOL)activateMacWindow:(MacWSStreamWindow *)window {
    if (!window || window.descriptor.windowID == 0 ||
        window.descriptor.ownerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    // Bind subsequent keyboard input immediately to the same explicit user
    // target. Waiting for another catalog callback reintroduced stale focus
    // from unrelated processes before this activation had even committed.
    _metalView.targetPID = window.descriptor.ownerPID;
    if (_streamMode == MacWSStreamModeFullscreen) {
        _fullscreenActivatedInputWindowID = window.descriptor.windowID;
        _fullscreenActivatedInputOwnerPID = window.descriptor.ownerPID;
        if ((window.descriptor.flags &
                MacWSStreamWindowFullscreenCanvas) != 0) {
            [_metalView noteValidatedFullscreenCanvasForPID:
                window.descriptor.ownerPID
                                                   windowID:
                window.descriptor.windowID];
        }
    }
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(
            window.descriptor.windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = window.descriptor.ownerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    NSString *title = window.title.length ? window.title :
        [NSString stringWithFormat:@"Window %u",
            window.descriptor.windowID];
    [self setNotice:[NSString stringWithFormat:@"已切换到 %@", title]
             success:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_streamMode == MacWSStreamModeFullscreen)
            [self->_metalView requestStreamWindowList];
    });
    return YES;
}

- (BOOL)isFullscreenWorkspace {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title {
    if (_streamMode != MacWSStreamModeFullscreen ||
        windowID == 0 || ownerPID <= 1) return NO;
    for (MacWSStreamWindow *window in _streamWindows) {
        if (window.descriptor.windowID == windowID &&
            window.descriptor.ownerPID == ownerPID)
            return [self activateMacWindow:window];
    }
    [_metalView requestStreamWindowList];
    [self setNotice:[NSString stringWithFormat:@"%@ 已在当前全屏工作区中打开，正在等待窗口目录更新。",
        title.length ? title : @"macOS 应用"] success:YES];
    MacWSLog(@"fullscreen-window-route pending pid=%d window=%u title=%@",
             ownerPID, windowID, title ?: @"");
    return YES;
}

- (void)performSemanticShortcutForDiagnostics:(NSString *)shortcut {
    uint32_t targetWindowID = _windowID;
    int32_t targetOwnerPID = _windowOwnerPID;
    if (_streamMode == MacWSStreamModeFullscreen && targetWindowID == 0) {
        targetOwnerPID = _metalView.targetPID;
        for (MacWSStreamWindow *window in _streamWindows) {
            if (window.descriptor.ownerPID != targetOwnerPID ||
                window.descriptor.windowID == 0 ||
                (window.descriptor.flags & MacWSStreamWindowVisible) == 0)
                continue;
            targetWindowID = window.descriptor.windowID;
            break;
        }
    }
    if (targetWindowID == 0 || targetOwnerPID <= 1 || !shortcut.length) {
        MacWSLog(@"diagnostic-menu shortcut=%@ result=no-exact-window",
                 shortcut ?: @"");
        return;
    }
    [_menuClient requestSnapshotForPID:targetOwnerPID
                              windowID:targetWindowID
                            completion:^(MacWSMenuSnapshot *snapshot,
                                         NSError *error) {
        if (!snapshot || error) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=snapshot-failed "
                     "error=%@", shortcut,
                     error.localizedDescription ?: @"unknown");
            return;
        }
        MacWSMenuItem *match = nil;
        for (MacWSMenuItem *item in snapshot.items) {
            if ([item.shortcut isEqualToString:shortcut] &&
                (item.flags & MacWSMenuNodeEnabled) &&
                !(item.flags & (MacWSMenuNodeHidden |
                                MacWSMenuNodeHasSubmenu |
                                MacWSMenuNodeRequiresWorkspace))) {
                match = item;
                break;
            }
        }
        if (!match) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=item-not-found",
                     shortcut);
            return;
        }
        MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ owner=%d window=%u",
                 shortcut, match.title, snapshot.ownerPID,
                 snapshot.windowID);
        if (self->_streamMode == MacWSStreamModeFullscreen) {
            [self activateMacWindowIDInFullscreenWorkspace:targetWindowID
                ownerPID:targetOwnerPID title:match.title];
        } else {
            [self activateCurrentMacWindow];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      120 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self->_menuClient performItem:match inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ "
                             "status=%u error=%@", shortcut, match.title,
                             (unsigned)status,
                             actionError.localizedDescription ?: @"none");
                }];
        });
    }];
}

- (void)dismissSemanticMenu {
    [_semanticMenuDismissLayer removeFromSuperview];
    _semanticMenuDismissLayer = nil;
    if (!_semanticMenuPanel) return;
    [_semanticMenuPanel willMoveToParentViewController:nil];
    [_semanticMenuPanel.view removeFromSuperview];
    [_semanticMenuPanel removeFromParentViewController];
    _semanticMenuPanel = nil;
}

- (void)presentSemanticMenuForParent:(uint64_t)parentID
                             snapshot:(MacWSMenuSnapshot *)snapshot
                               source:(UIView *)source
                                title:(NSString *)title {
    NSMutableArray<MacWSMenuItem *> *items = [NSMutableArray array];
    for (MacWSMenuItem *item in [snapshot childrenOfItemID:parentID]) {
        if ((item.flags & MacWSMenuNodeHidden) == 0) [items addObject:item];
    }
    if (items.count == 0) {
        [self setNotice:[NSString stringWithFormat:@"“%@”菜单当前没有可见项目。",
            title.length ? title : @"macOS"] success:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    MacWSCompactMenuController *panel = [[MacWSCompactMenuController alloc]
        initWithItems:items appearance:snapshot.appearance
        selection:^(MacWSMenuItem *item) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self dismissSemanticMenu];
            if (item.flags & MacWSMenuNodeRequiresWorkspace) {
                [self setNotice:@"此菜单项包含 macOS 自定义视图，请在全屏工作区中使用。"
                         success:NO];
                return;
            }
            if (item.flags & MacWSMenuNodeHasSubmenu) {
                [self presentSemanticMenuForParent:item.itemID
                                          snapshot:snapshot source:source
                                             title:item.title];
                return;
            }
            // The iOS menu is outside AppKit, so selecting it does not itself
            // focus the represented NSWindow.  Send the same control-plane
            // activation as a real click and let AppKit finish its documented
            // activation transaction before routing a First Responder action.
            // Unlike the old bridge-side makeKeyAndOrderFront:, this happens
            // only for explicit user intent and never during passive refresh.
            [self activateCurrentMacWindow];
            uint32_t selectedWindowID = snapshot.windowID;
            int32_t selectedOwnerPID = snapshot.ownerPID;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          120 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_windowID != selectedWindowID ||
                    self->_windowOwnerPID != selectedOwnerPID) {
                    [self setNotice:@"窗口已经切换，请重新选择菜单项" success:NO];
                    return;
                }
                [self->_menuClient performItem:item inSnapshot:snapshot
                    completion:^(MacWSMenuStatus status, NSError *error) {
                        if (status == MacWSMenuStatusOK) {
                            [self setNotice:[NSString stringWithFormat:
                                @"已发送“%@”", item.title] success:YES];
                        } else {
                            [self setNotice:error.localizedDescription ?:
                                @"菜单项无法执行" success:NO];
                            [self refreshSemanticMenuWithCompletion:nil];
                        }
                    }];
            });
        }];
    [self dismissSemanticMenu];
    [self.view layoutIfNeeded];
    CGRect sourceRect = [source convertRect:source.bounds toView:self.view];
    CGRect safeBounds = UIEdgeInsetsInsetRect(self.view.bounds,
                                               self.view.safeAreaInsets);
    CGSize preferred = panel.preferredContentSize;
    CGFloat width = MIN(preferred.width, MAX(120.0, safeBounds.size.width));
    CGFloat height = MIN(preferred.height,
                         MAX(80.0, safeBounds.size.height - 4.0));
    CGFloat x = MIN(MAX(CGRectGetMinX(sourceRect), CGRectGetMinX(safeBounds)),
        MAX(CGRectGetMinX(safeBounds), CGRectGetMaxX(safeBounds) - width));
    CGFloat y = CGRectGetMaxY(sourceRect) + 1.0;
    if (y + height > CGRectGetMaxY(safeBounds))
        y = MAX(CGRectGetMinY(safeBounds),
                CGRectGetMinY(sourceRect) - height - 1.0);

    UIControl *dismissLayer = [[UIControl alloc] initWithFrame:self.view.bounds];
    dismissLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
    dismissLayer.backgroundColor = UIColor.clearColor;
    [dismissLayer addTarget:self action:@selector(dismissSemanticMenu)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dismissLayer];
    _semanticMenuDismissLayer = dismissLayer;

    [self addChildViewController:panel];
    panel.view.frame = CGRectMake(x, y, width, height);
    panel.view.backgroundColor = UIColor.secondarySystemBackgroundColor;
    panel.view.layer.cornerRadius = 8.0;
    panel.view.layer.borderWidth = 0.5;
    panel.view.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    panel.view.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.view.layer.shadowOpacity = 0.25;
    panel.view.layer.shadowRadius = 10;
    panel.view.layer.shadowOffset = CGSizeMake(0, 4);
    [self.view addSubview:panel.view];
    [panel didMoveToParentViewController:self];
    _semanticMenuPanel = panel;
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"menu-present parent=%llu source=(%.1f,%.1f %.1fx%.1f) panel=(%.1f,%.1f %.1fx%.1f)",
                 parentID, sourceRect.origin.x, sourceRect.origin.y,
                 sourceRect.size.width, sourceRect.size.height,
                 x, y, width, height);
    }
}

- (void)semanticMenuTitleTapped:(UIButton *)sender {
    uint32_t siblingIndex = UINT32_MAX;
    if (sender.tag >= 0) {
        MacWSMenuItem *old = [_menuSnapshot itemWithID:(uint64_t)sender.tag];
        siblingIndex = old.siblingIndex;
    }
    sender.enabled = NO;
    [self activateCurrentMacWindow];
    [self refreshSemanticMenuWithCompletion:^(MacWSMenuSnapshot *snapshot,
                                               NSError *error) {
        sender.enabled = YES;
        if (error || !snapshot) {
            [self setNotice:error.localizedDescription ?: @"菜单暂不可用"
                     success:NO];
            return;
        }
        uint64_t parentID = 0;
        NSString *title = @"macOS 菜单";
        if (siblingIndex != UINT32_MAX) {
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == siblingIndex) {
                    parentID = root.itemID;
                    title = root.title;
                    break;
                }
            }
        }
        [self presentSemanticMenuForParent:parentID snapshot:snapshot
                                    source:sender title:title];
    }];
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.blackColor;
    self.view = root;

    _metalView = [[MacWSMetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.statusDelegate = self;
    _metalView.sceneID = ((uint64_t)_sceneIdentifier.hash) &
        ~MACWS_INPUT_WINDOW_SCENE_FLAG;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.targetWindowResizable = _windowResizable;
    MacWSHostDisplayDensity savedDensity = (MacWSHostDisplayDensity)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSDisplayDensity"];
    if (savedDensity != MacWSHostDisplayDensityTouchComfort &&
        savedDensity != MacWSHostDisplayDensityKeyboard &&
        savedDensity != MacWSHostDisplayDensityComfort)
        savedDensity = MacWSHostDisplayDensityTouchComfort;
    // The first comfort-mode experiment migrated exact pixel matching to a
    // 10% host-side upsample. That makes controls larger, but it cannot retain
    // one-source-pixel-to-one-drawable-pixel sharpness. Restore the exact mode
    // once for existing installations; Comfort remains an explicit choice.
    if (![NSUserDefaults.standardUserDefaults
            boolForKey:@"MacWSDensityPixelMatchMigrationV2"]) {
        if (savedDensity == MacWSHostDisplayDensityComfort)
            savedDensity = MacWSHostDisplayDensityTouchComfort;
        [NSUserDefaults.standardUserDefaults setBool:YES
            forKey:@"MacWSDensityPixelMatchMigrationV2"];
        [NSUserDefaults.standardUserDefaults setInteger:savedDensity
            forKey:@"MacWSDisplayDensity"];
    }
    _metalView.displayDensity = savedDensity;
    MacWSHostPresentationResolution savedPresentationResolution =
        (MacWSHostPresentationResolution)
        [NSUserDefaults.standardUserDefaults integerForKey:
            @"MacWSPresentationResolution"];
    if (savedPresentationResolution !=
            MacWSHostPresentationResolutionAutomatic &&
        savedPresentationResolution !=
            MacWSHostPresentationResolutionSourceNative &&
        savedPresentationResolution !=
            MacWSHostPresentationResolutionPerformance)
        savedPresentationResolution =
            MacWSHostPresentationResolutionAutomatic;
    _metalView.presentationResolution = savedPresentationResolution;
    CGFloat savedZoomScale =
        [NSUserDefaults.standardUserDefaults doubleForKey:@"MacWSFixedZoomScale"];
    _metalView.fixedZoomScale = savedZoomScale >= 1.75 ? 2.0 : 1.5;
    // Scene restoration constructs background controllers too.  Record the
    // target here, but defer the actual DisplayStream subscription until the
    // Scene enters the foreground so dormant Scenes cannot consume leases.
    _metalView.targetWindowID = _streamMode == MacWSStreamModeWindow ? _windowID : 0;
    _metalView.targetPID = _windowOwnerPID;
    [root addSubview:_metalView];
    MacWSPerformanceHUDMode savedHUDMode = (MacWSPerformanceHUDMode)
        [NSUserDefaults.standardUserDefaults integerForKey:
            @"MacWSPerformanceHUDMode"];
    if (savedHUDMode < MacWSPerformanceHUDModeOff ||
        savedHUDMode > MacWSPerformanceHUDModeFull)
        savedHUDMode = MacWSPerformanceHUDModeOff;
    _metalView.performanceMonitor.HUDMode = savedHUDMode;
    [_metalView.performanceMonitor attachHUDToView:root];

    // The iPadOS Scene exists before its default Terminal window is launched.
    // Keep a native menu bar during that short bootstrap interval too, so an
    // empty DisplayStream never presents as an unexplained black workspace
    // with a detached control button in the upper-left corner.
    _semanticMenuBar = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        _semanticMenuBar.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuBar.clipsToBounds = YES;
        _semanticMenuBar.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        _semanticMenuScroll = [UIScrollView new];
        _semanticMenuScroll.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuScroll.showsHorizontalScrollIndicator = NO;
        _semanticMenuTitles = [UIStackView new];
        _semanticMenuTitles.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuTitles.axis = UILayoutConstraintAxisHorizontal;
        _semanticMenuTitles.alignment = UIStackViewAlignmentFill;
        _semanticMenuTitles.spacing = 0;
        [_semanticMenuScroll addSubview:_semanticMenuTitles];
        [_semanticMenuBar.contentView addSubview:_semanticMenuScroll];
        UIView *menuSeparator = [UIView new];
        menuSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        menuSeparator.backgroundColor = [UIColor.separatorColor
            colorWithAlphaComponent:0.58];
        [_semanticMenuBar.contentView addSubview:menuSeparator];
        [root addSubview:_semanticMenuBar];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuScroll.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor constant:4],
            [_semanticMenuScroll.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor constant:-40],
            [_semanticMenuScroll.topAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.topAnchor],
            [_semanticMenuScroll.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [_semanticMenuTitles.leadingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.leadingAnchor],
            [_semanticMenuTitles.trailingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.trailingAnchor],
            [_semanticMenuTitles.topAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.topAnchor],
            [_semanticMenuTitles.bottomAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.bottomAnchor],
            [_semanticMenuTitles.heightAnchor constraintEqualToAnchor:
                _semanticMenuScroll.frameLayoutGuide.heightAnchor],
            [menuSeparator.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor],
            [menuSeparator.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor],
            [menuSeparator.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [menuSeparator.heightAnchor constraintEqualToConstant:0.5],
        ]];
    [self renderSemanticMenuTitles];

    _keyboardProxy = [UITextField new];
    _keyboardProxy.translatesAutoresizingMaskIntoConstraints = NO;
    _keyboardProxy.delegate = self;
    _keyboardProxy.text = @" ";
    _keyboardProxy.autocorrectionType = UITextAutocorrectionTypeNo;
    _keyboardProxy.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyboardProxy.smartDashesType = UITextSmartDashesTypeNo;
    _keyboardProxy.smartQuotesType = UITextSmartQuotesTypeNo;
    _keyboardProxy.spellCheckingType = UITextSpellCheckingTypeNo;
    _keyboardProxy.alpha = 0.01;
    [root addSubview:_keyboardProxy];
    // The modifier row belongs to the MacWS window layout, not to the floating
    // iPad keyboard. Giving it an explicit 52-point region prevents it from
    // covering macOS pixels while leaving the movable software keyboard free
    // to overlap wherever the user places it.
    _softwareKeyBar = [self makeKeyboardAccessoryView];
    _softwareKeyBar.translatesAutoresizingMaskIntoConstraints = NO;
    _softwareKeyBar.hidden = YES;
    [root addSubview:_softwareKeyBar];
    _softwareKeyBarHeightConstraint = [_softwareKeyBar.heightAnchor
        constraintEqualToConstant:0];

    _controlDismissLayer = [UIControl new];
    _controlDismissLayer.translatesAutoresizingMaskIntoConstraints = NO;
    _controlDismissLayer.backgroundColor = UIColor.clearColor;
    _controlDismissLayer.hidden = YES;
    [_controlDismissLayer addTarget:self action:@selector(hideControls)
                   forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_controlDismissLayer];

    // The expanded card must be a stable reading surface. The former fixed
    // dark blur was composited with adaptive light/dark labels and fills,
    // which produced incorrect translucency and contrast. Keep blur only for
    // the small floating affordance; the card itself follows one opaque
    // semantic color system.
    _controlPanel = [[UIVisualEffectView alloc] initWithEffect:nil];
    _controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlPanel.layer.cornerRadius = 22;
    _controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _controlPanel.clipsToBounds = YES;
    _controlPanel.contentView.backgroundColor = UIColor.systemBackgroundColor;
    [root addSubview:_controlPanel];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [_controlPanel.contentView addSubview:scroll];

    _controlTitleLabel = MacWSMakeLabel(@"macPad 控制中心",
        [UIFont systemFontOfSize:23 weight:UIFontWeightBold], UIColor.labelColor);
    _controlSubtitleLabel = MacWSMakeLabel(@"iPadOS 原生窗口 · macOS AGX 工作区",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);
    UIStackView *titleLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[_controlTitleLabel, _controlSubtitleLabel]];
    titleLabels.axis = UILayoutConstraintAxisVertical;
    titleLabels.spacing = 1;

    UIButton *hide = [self buttonWithTitle:@"" image:@"sidebar.left"
                                    action:@selector(hideControls) prominent:NO];
    UIButtonConfiguration *hideConfiguration = [hide.configuration copy];
    hideConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
    hide.configuration = hideConfiguration;
    [hide.widthAnchor constraintEqualToConstant:52].active = YES;
    [hide setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
    [hide setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabels, hide]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;

    _serviceLabel = MacWSMakeLabel(@"正在连接 root 控制服务…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.systemOrangeColor);
    _phaseLabel = MacWSMakeLabel(@"打开 App 后会自动检查重启恢复状态",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);

    UIStackView *serviceCard = [[UIStackView alloc]
        initWithArrangedSubviews:@[_serviceLabel, _phaseLabel]];
    serviceCard.axis = UILayoutConstraintAxisVertical;
    serviceCard.spacing = 5;
    serviceCard.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    serviceCard.layoutMarginsRelativeArrangement = YES;
    serviceCard.backgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.48];
    serviceCard.layer.cornerRadius = 12;

    UIStackView *statusRows = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self statusRowWithTitle:@"macOS RootFS" value:&_rootfsLabel],
        [self divider],
        [self statusRowWithTitle:@"WindowServer" value:&_windowServerLabel],
        [self divider],
        [self statusRowWithTitle:@"触控桥" value:&_bridgeLabel],
        [self divider],
        [self statusRowWithTitle:@"共享帧" value:&_frameLabel],
    ]];
    statusRows.axis = UILayoutConstraintAxisVertical;
    statusRows.spacing = 8;
    statusRows.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    statusRows.layoutMarginsRelativeArrangement = YES;
    statusRows.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.42];
    statusRows.layer.cornerRadius = 12;

    _primaryButton = [self buttonWithTitle:@"初始化并启动" image:@"play.fill"
                                    action:@selector(primaryAction) prominent:YES];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;

    _experimentalTitleLabel = MacWSMakeLabel(@"实验兼容模式",
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.labelColor);
    _experimentalDetailLabel = MacWSMakeLabel(
        @"启用命令 ABI / completion 诊断脚手架；受 5 分钟与高 CPU 热保护，不是根因修复。",
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
        UIColor.systemOrangeColor);
    UIStackView *experimentalLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[_experimentalTitleLabel,
                                   _experimentalDetailLabel]];
    experimentalLabels.axis = UILayoutConstraintAxisVertical;
    experimentalLabels.spacing = 2;
    _experimentalSwitch = [UISwitch new];
    _experimentalSwitch.on = [NSUserDefaults.standardUserDefaults
        boolForKey:@"MacWSExperimentalMode"];
    [_experimentalSwitch addTarget:self action:@selector(experimentalChanged:)
                  forControlEvents:UIControlEventValueChanged];
    UIStackView *experimentalRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[experimentalLabels, _experimentalSwitch]];
    experimentalRow.axis = UILayoutConstraintAxisHorizontal;
    experimentalRow.alignment = UIStackViewAlignmentCenter;
    experimentalRow.spacing = 10;

    UIButton *glassDemo = [self buttonWithTitle:@"GlassDemo" image:@"sparkles.rectangle.stack"
                                         action:@selector(launchApplication:) prominent:NO];
    glassDemo.accessibilityIdentifier = @"glassdemo";
    UIButton *terminal = [self buttonWithTitle:@"终端" image:@"terminal"
                                        action:@selector(launchApplication:) prominent:NO];
    terminal.accessibilityIdentifier = @"terminal";
    UIButton *activity = [self buttonWithTitle:@"活动监视器" image:@"waveform.path.ecg.rectangle"
                                        action:@selector(launchApplication:) prominent:NO];
    activity.accessibilityIdentifier = @"activity-monitor";
    UIButton *finder = [self buttonWithTitle:@"Finder" image:@"folder"
                                      action:@selector(launchApplication:) prominent:NO];
    finder.accessibilityIdentifier = @"finder";
    UIButton *vscode = [self buttonWithTitle:@"VS Code" image:@"chevron.left.forwardslash.chevron.right"
                                      action:@selector(launchApplication:) prominent:NO];
    vscode.accessibilityIdentifier = @"vscode";
    UIButton *settings = [self buttonWithTitle:@"系统设置" image:@"gearshape"
                                        action:@selector(launchApplication:) prominent:NO];
    settings.accessibilityIdentifier = @"system-settings";
    UIButton *maps = [self buttonWithTitle:@"地图" image:@"map"
                                    action:@selector(launchApplication:) prominent:NO];
    maps.accessibilityIdentifier = @"maps";
    UIButton *amadine = [self buttonWithTitle:@"Amadine"
                                        image:@"paintbrush.pointed"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    amadine.accessibilityIdentifier = @"amadine";
    UIButton *word = [self buttonWithTitle:@"Word" image:@"doc.richtext"
                                     action:@selector(launchApplication:)
                                  prominent:NO];
    word.accessibilityIdentifier = @"word";
    UIButton *excel = [self buttonWithTitle:@"Excel" image:@"tablecells"
                                      action:@selector(launchApplication:)
                                   prominent:NO];
    excel.accessibilityIdentifier = @"excel";
    UIButton *powerpoint = [self buttonWithTitle:@"PowerPoint"
                                           image:@"play.rectangle"
                                          action:@selector(launchApplication:)
                                       prominent:NO];
    powerpoint.accessibilityIdentifier = @"powerpoint";
    UIButton *steam = [self buttonWithTitle:@"Steam"
                                      image:@"gamecontroller"
                                     action:@selector(launchApplication:)
                                  prominent:NO];
    steam.accessibilityIdentifier = @"steam";
    UIButton *weather = [self buttonWithTitle:@"天气"
                                        image:@"cloud.sun"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    weather.accessibilityIdentifier = @"weather";
    UIButton *sublime = [self buttonWithTitle:@"Sublime Text"
                                        image:@"chevron.left.forwardslash.chevron.right"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    sublime.accessibilityIdentifier = @"sublime";
    _applicationButtons = @[
        glassDemo, terminal, activity, finder, vscode, settings, maps,
        weather, sublime, steam, amadine, word, excel, powerpoint,
    ];
    UIStackView *appRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[glassDemo, terminal]];
    UIStackView *appRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[activity, finder]];
    UIStackView *appRow3 = [[UIStackView alloc] initWithArrangedSubviews:@[vscode, settings]];
    UIStackView *appRow4 = [[UIStackView alloc] initWithArrangedSubviews:@[maps]];
    UIStackView *appRow5 = [[UIStackView alloc]
        initWithArrangedSubviews:@[weather, sublime]];
    UIStackView *appRow6 = [[UIStackView alloc]
        initWithArrangedSubviews:@[steam, amadine]];
    UIStackView *appRow7 = [[UIStackView alloc]
        initWithArrangedSubviews:@[word, excel]];
    UIStackView *appRow8 = [[UIStackView alloc]
        initWithArrangedSubviews:@[powerpoint]];
    for (UIStackView *row in @[
             appRow1, appRow2, appRow3, appRow4, appRow5, appRow6, appRow7,
             appRow8]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _appSearchField = [UITextField new];
    _appSearchField.delegate = self;
    _appSearchField.placeholder = @"搜索应用或输入 macOS 绝对路径";
    _appSearchField.returnKeyType = UIReturnKeyGo;
    _appSearchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _appSearchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _appSearchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _appSearchField.backgroundColor = [UIColor.secondarySystemFillColor
        colorWithAlphaComponent:0.52];
    _appSearchField.layer.cornerRadius = 11;
    _appSearchField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _appSearchField.leftViewMode = UITextFieldViewModeAlways;
    [_appSearchField.heightAnchor constraintEqualToConstant:44].active = YES;

    _keyboardButton = [self buttonWithTitle:@"打开虚拟键盘"
                                     image:@"keyboard"
                                    action:@selector(keyboardAction)
                                 prominent:NO];

    _captureButton = [self buttonWithTitle:@"刷新画面" image:@"camera.viewfinder"
                                    action:@selector(captureAction) prominent:NO];
    _repairDesktopButton = [self buttonWithTitle:@"修复桌面"
                                           image:@"arrow.clockwise.circle"
                                          action:@selector(repairDesktopAction)
                                       prominent:YES];
    _repairDesktopButton.accessibilityIdentifier = @"repair-desktop";
    _repairButton = [self buttonWithTitle:@"修复环境" image:@"wrench.and.screwdriver"
                                   action:@selector(repairAction) prominent:NO];
    _recoverButton = [self buttonWithTitle:@"安全恢复" image:@"lifepreserver"
                                    action:@selector(recoverAction) prominent:NO];
    _logsButton = [self buttonWithTitle:@"查看日志" image:@"doc.text.magnifyingglass"
                                 action:@selector(logsAction) prominent:NO];
    _exportButton = [self buttonWithTitle:@"导出诊断" image:@"square.and.arrow.up"
                                   action:@selector(exportDiagnostics) prominent:NO];
    _windowPickerButton = [self buttonWithTitle:@"打开 macOS 窗口"
                                          image:@"macwindow.on.rectangle"
                                         action:@selector(openWindowPicker)
                                      prominent:NO];
    _closeWindowButton = [self buttonWithTitle:@"关闭此 macOS 窗口"
                                         image:@"xmark.square"
                                        action:@selector(closeCurrentWindow)
                                     prominent:NO];
    _closeWindowButton.hidden = _windowID == 0;
    _menuBarButton = [self buttonWithTitle:@"打开全屏 macOS 工作区"
                                     image:@"arrow.up.left.and.arrow.down.right"
                                    action:@selector(openFullscreenWorkspace)
                                 prominent:NO];
    _clipboardButton = [self buttonWithTitle:@"同步剪贴板到 macOS"
                                       image:@"doc.on.clipboard"
                                      action:@selector(syncClipboardAction)
                                   prominent:NO];
    _importButton = [self buttonWithTitle:@"导入文件到 macOS"
                                    image:@"square.and.arrow.down.on.square"
                                   action:@selector(importFilesAction)
                                prominent:NO];
    _macFilesButton = [self buttonWithTitle:@"macOS 文件"
                                      image:@"arrow.up.doc"
                                     action:@selector(shareMacOSFiles)
                                  prominent:NO];
    _macFilesButton.enabled = NO;
    UIStackView *interopRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[_clipboardButton, _importButton]];
    interopRow.axis = UILayoutConstraintAxisHorizontal;
    interopRow.distribution = UIStackViewDistributionFillEqually;
    interopRow.spacing = 8;
    [_macFilesButton addInteraction:[[UIDragInteraction alloc]
        initWithDelegate:self]];
    [_metalView addInteraction:[[UIDropInteraction alloc]
        initWithDelegate:self]];
    UIStackView *toolRow1 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_captureButton, _repairButton]];
    UIStackView *toolRow2 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_recoverButton, _logsButton]];
    for (UIStackView *row in @[toolRow1, toolRow2]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _statusLabel = [UILabel new];
    _statusLabel.text = @"画面：正在连接 WindowServer 共享帧…";
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 0;

    _inputLabel = [UILabel new];
    _inputLabel.text = @"触控：等待桥接服务";
    _inputLabel.textColor = UIColor.systemCyanColor;
    _inputLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _inputLabel.numberOfLines = 0;

    _interopLabel = [UILabel new];
    _interopLabel.text = @"互操作：等待 macOS 剪贴板与文件桥";
    _interopLabel.textColor = UIColor.systemIndigoColor;
    _interopLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                     weight:UIFontWeightRegular];
    _interopLabel.numberOfLines = 0;

    _inputModeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"直接触控", @"精确触控板"]];
    MacWSHostInputMode savedInputMode = (MacWSHostInputMode)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSInputMode"];
    if (savedInputMode != MacWSHostInputModeTrackpad)
        savedInputMode = MacWSHostInputModeDirect;
    _inputModeControl.selectedSegmentIndex =
        savedInputMode == MacWSHostInputModeTrackpad ? 1 : 0;
    _metalView.inputMode = savedInputMode;
    [_inputModeControl addTarget:self action:@selector(inputModeChanged:)
                forControlEvents:UIControlEventValueChanged];

    _densityControl = [[UISegmentedControl alloc]
        initWithItems:@[@"像素匹配", @"放大 +10%", @"更多空间 +18%"]];
    _densityControl.selectedSegmentIndex =
        _metalView.displayDensity == MacWSHostDisplayDensityKeyboard ? 2 :
        (_metalView.displayDensity == MacWSHostDisplayDensityComfort ? 1 : 0);
    [_densityControl addTarget:self action:@selector(densityChanged:)
               forControlEvents:UIControlEventValueChanged];

    _presentationResolutionControl = [[UISegmentedControl alloc]
        initWithItems:@[@"自动清晰", @"始终清晰", @"性能优先"]];
    _presentationResolutionControl.selectedSegmentIndex =
        _metalView.presentationResolution;
    [_presentationResolutionControl addTarget:self
        action:@selector(presentationResolutionChanged:)
        forControlEvents:UIControlEventValueChanged];

    _performanceHUDControl = [[UISegmentedControl alloc]
        initWithItems:@[@"关闭", @"简洁", @"完整"]];
    _performanceHUDControl.selectedSegmentIndex = savedHUDMode;
    [_performanceHUDControl addTarget:self
        action:@selector(performanceHUDChanged:)
        forControlEvents:UIControlEventValueChanged];

    _systemHUDTitleLabel = MacWSMakeLabel(@"Apple 系统渲染 HUD",
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
        UIColor.labelColor);
    _systemHUDDetailLabel = MacWSMakeLabel(
        @"QuartzCore RenderServer 全系统 FPS / GPU / 卡顿视图",
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
        UIColor.secondaryLabelColor);
    UIStackView *systemHUDLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[_systemHUDTitleLabel,
                                   _systemHUDDetailLabel]];
    systemHUDLabels.axis = UILayoutConstraintAxisVertical;
    systemHUDLabels.spacing = 2;
    _systemPerformanceHUDSwitch = [UISwitch new];
    NSInteger systemHUDLevel =
        [MacWSPerformanceMonitor systemPerformanceHUDLevel];
    _systemPerformanceHUDSwitch.on = systemHUDLevel > 0;
    _systemPerformanceHUDSwitch.enabled = systemHUDLevel >= 0;
    [_systemPerformanceHUDSwitch addTarget:self
        action:@selector(systemPerformanceHUDChanged:)
        forControlEvents:UIControlEventValueChanged];
    UIStackView *systemHUDRow = [[UIStackView alloc]
        initWithArrangedSubviews:@[systemHUDLabels,
                                   _systemPerformanceHUDSwitch]];
    systemHUDRow.axis = UILayoutConstraintAxisHorizontal;
    systemHUDRow.alignment = UIStackViewAlignmentCenter;
    systemHUDRow.spacing = 10;
    _performanceResetButton = [self buttonWithTitle:@"重新计时"
        image:@"stopwatch" action:@selector(resetPerformanceMeasurement)
        prominent:NO];
    _performanceExportButton = [self buttonWithTitle:@"导出 JSON"
        image:@"square.and.arrow.up"
        action:@selector(exportPerformanceMeasurement) prominent:NO];
    UIStackView *performanceActions = [[UIStackView alloc]
        initWithArrangedSubviews:@[_performanceResetButton,
                                   _performanceExportButton]];
    performanceActions.axis = UILayoutConstraintAxisHorizontal;
    performanceActions.distribution = UIStackViewDistributionFillEqually;
    performanceActions.spacing = 8;
    _performanceRunButton = [self buttonWithTitle:@"运行标准触摸 / 手势回归"
        image:@"hand.draw" action:@selector(runPerformanceGestureSuite)
        prominent:NO];
    _zoomScaleControl = [[UISegmentedControl alloc]
        initWithItems:@[@"双指双击 1.5×", @"双指双击 2.0×"]];
    _zoomScaleControl.selectedSegmentIndex =
        _metalView.fixedZoomScale >= 1.75 ? 1 : 0;
    [_zoomScaleControl addTarget:self action:@selector(zoomScaleChanged:)
                 forControlEvents:UIControlEventValueChanged];
    _resetZoomButton = [self buttonWithTitle:@"退出放大视角"
        image:@"arrow.counterclockwise"
        action:@selector(resetZoomAction) prominent:NO];

    _noticeLabel = MacWSMakeLabel(@"",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.systemCyanColor);
    _noticeLabel.hidden = YES;

    _logsView = [UITextView new];
    _logsView.editable = NO;
    _logsView.selectable = YES;
    _logsView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.35];
    _logsView.textColor = UIColor.systemGreenColor;
    _logsView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logsView.layer.cornerRadius = 10;
    _logsView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _logsView.hidden = YES;
    _logsView.accessibilityLabel = @"macPad 启动日志";
    [_logsView.heightAnchor constraintEqualToConstant:220].active = YES;

    // Interaction choices are the first controls a user needs. Detailed
    // subsystem rows and recovery/debug tools stay out of the production UI;
    // a compact readiness summary remains at the bottom.
    _languageSectionLabel = [self sectionTitle:@"语言"];
    _touchSectionLabel = [self sectionTitle:@"触摸方式"];
    _displaySectionLabel = [self sectionTitle:@"显示密度"];
    _performanceSectionLabel = [self sectionTitle:@"性能测量"];
    _applicationsSectionLabel = [self sectionTitle:@"macOS 应用"];
    _interopSectionLabel = [self sectionTitle:@"iOS / macOS 互操作"];
    _zoomSectionLabel = [self sectionTitle:@"放大视角"];
    _startupLogSectionLabel = [self sectionTitle:@"启动日志（实时）"];
    _startupLogSectionLabel.hidden = YES;
    _retryStartupButton = [self buttonWithTitle:@"重新尝试启动"
        image:@"arrow.clockwise" action:@selector(retryStartupAction)
        prominent:YES];
    _retryStartupButton.hidden = YES;
    _languageControl = [[UISegmentedControl alloc]
        initWithItems:@[@"中文", @"English"]];
    _languageControl.selectedSegmentIndex =
        MacWSControlCenterUsesEnglish() ? 1 : 0;
    [_languageControl addTarget:self action:@selector(languageChanged:)
               forControlEvents:UIControlEventValueChanged];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        _languageSectionLabel,
        _languageControl,
        _touchSectionLabel,
        _inputModeControl,
        _displaySectionLabel,
        _densityControl,
        _presentationResolutionControl,
        _keyboardButton,
        _primaryButton,
        _repairDesktopButton,
        _performanceSectionLabel,
        _performanceHUDControl,
        systemHUDRow,
        performanceActions,
        _performanceRunButton,
        _applicationsSectionLabel,
        _appSearchField,
        appRow1,
        appRow2,
        appRow3,
        appRow4,
        appRow5,
        appRow6,
        appRow7,
        appRow8,
        _windowPickerButton,
        _menuBarButton,
        _closeWindowButton,
        _interopSectionLabel,
        interopRow,
        _macFilesButton,
        _zoomSectionLabel,
        _zoomScaleControl,
        _resetZoomButton,
        _noticeLabel,
        [self divider],
        serviceCard,
        _statusLabel,
        _inputLabel,
        _interopLabel,
        _retryStartupButton,
        _startupLogSectionLabel,
        _logsView,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    content.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:content];

    _showControlsMaterial = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _showControlsMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    _showControlsMaterial.layer.cornerRadius = 15;
    _showControlsMaterial.layer.cornerCurve = kCACornerCurveContinuous;
    _showControlsMaterial.layer.borderWidth = 0.5;
    _showControlsMaterial.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.55].CGColor;
    _showControlsMaterial.clipsToBounds = YES;
    [root addSubview:_showControlsMaterial];

    _showControlsButton = [self buttonWithTitle:@"控制中心" image:@"sidebar.left"
                                         action:@selector(showControls) prominent:NO];
    _showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration plainButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"switch.2"];
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(3, 5, 3, 5);
    _showControlsButton.configuration = configuration;
    _showControlsButton.accessibilityLabel = @"MacWS 控制中心";
    [_showControlsMaterial.contentView addSubview:_showControlsButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *responsiveWidth = [_controlPanel.widthAnchor
        constraintEqualToAnchor:safe.widthAnchor multiplier:0.92];
    responsiveWidth.priority = 999;
    NSLayoutYAxisAnchor *metalTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : root.topAnchor;
    NSLayoutYAxisAnchor *controlTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : safe.topAnchor;
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:metalTop],
        [_metalView.bottomAnchor constraintEqualToAnchor:_softwareKeyBar.topAnchor],
        [_softwareKeyBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_softwareKeyBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_softwareKeyBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _softwareKeyBarHeightConstraint,
        [_keyboardProxy.widthAnchor constraintEqualToConstant:1],
        [_keyboardProxy.heightAnchor constraintEqualToConstant:1],
        [_keyboardProxy.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_keyboardProxy.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlDismissLayer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_controlDismissLayer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_controlDismissLayer.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_controlDismissLayer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_controlPanel.topAnchor constraintEqualToAnchor:controlTop constant:12],
        [_controlPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_controlPanel.widthAnchor constraintLessThanOrEqualToConstant:420],
        responsiveWidth,
        [scroll.leadingAnchor constraintEqualToAnchor:_controlPanel.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_controlPanel.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_controlPanel.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_controlPanel.contentView.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [_showControlsMaterial.trailingAnchor constraintEqualToAnchor:
            safe.trailingAnchor constant:-6],
        [_showControlsMaterial.topAnchor constraintEqualToAnchor:
            safe.topAnchor constant:2],
        [_showControlsMaterial.widthAnchor constraintEqualToConstant:38],
        [_showControlsMaterial.heightAnchor constraintEqualToConstant:30],
        [_showControlsButton.leadingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.leadingAnchor],
        [_showControlsButton.trailingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.trailingAnchor],
        [_showControlsButton.topAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.topAnchor],
        [_showControlsButton.bottomAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.bottomAnchor],
    ]];
    if (_semanticMenuBar) {
        _semanticMenuHeightConstraint = [_semanticMenuBar.heightAnchor
            constraintEqualToConstant:26];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [_semanticMenuBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [_semanticMenuBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
            _semanticMenuHeightConstraint,
        ]];
        // _semanticMenuBar is constructed for every controller and hidden by
        // updateWorkspaceChrome in fullscreen mode.  Its mere existence is
        // therefore not evidence that this Scene owns a concrete AppKit
        // window. Runtime-confirmed via MacWSHost-ui.png on 2026-08-29: after
        // the desktop had been stopped, a freshly launched fullscreen Scene
        // entered this branch and showed a black canvas with only the tiny
        // Control Center affordance. Hide the panel only for an exact native
        // macOS window; a workspace/bootstrap Scene must remain an operable
        // launcher while its display service is offline.
        if (_streamMode == MacWSStreamModeWindow && _windowID != 0) {
            _controlPanel.hidden = YES;
            _showControlsMaterial.hidden = NO;
        }
    }
    [self applyControlCenterLanguage];
    [self updateWorkspaceChrome];
}

- (void)languageChanged:(UISegmentedControl *)sender {
    NSString *language = sender.selectedSegmentIndex == 1 ? @"en" : @"zh-Hans";
    [NSUserDefaults.standardUserDefaults setObject:language
        forKey:MacWSControlCenterLanguageDefaultsKey];
    [self applyControlCenterLanguage];
    [self updateWorkspaceChrome];
    if (_latestStatus) [self applyStatus:_latestStatus];
}

- (void)applyControlCenterLanguage {
    BOOL english = MacWSControlCenterUsesEnglish();
    _controlTitleLabel.text = english ? @"macPad Control Center" : @"macPad 控制中心";
    _controlSubtitleLabel.text = english
        ? @"Native iPadOS windows · macOS AGX workspace"
        : @"iPadOS 原生窗口 · macOS AGX 工作区";
    _languageSectionLabel.text = (english ? @"LANGUAGE" : @"语言");
    _touchSectionLabel.text = (english ? @"TOUCH MODE" : @"触摸方式");
    _displaySectionLabel.text = (english ? @"DISPLAY DENSITY" : @"显示密度");
    _performanceSectionLabel.text = (english ? @"PERFORMANCE" : @"性能测量");
    _applicationsSectionLabel.text = (english ? @"MACOS APPS" : @"MACOS 应用");
    _interopSectionLabel.text = (english ? @"IOS / MACOS INTEROP" : @"IOS / MACOS 互操作");
    _zoomSectionLabel.text = (english ? @"ZOOM VIEW" : @"放大视角");
    _startupLogSectionLabel.text = english
        ? @"STARTUP LOG (LIVE)" : @"启动日志（实时）";
    _experimentalTitleLabel.text = english ? @"Experimental Compatibility" : @"实验兼容模式";
    _experimentalDetailLabel.text = english
        ? @"Enables bounded command ABI/completion diagnostics; this is diagnostic scaffolding, not a root-cause fix."
        : @"启用命令 ABI / completion 诊断脚手架；受 5 分钟与高 CPU 热保护，不是根因修复。";
    _systemHUDTitleLabel.text = english ? @"Apple System Rendering HUD" : @"Apple 系统渲染 HUD";
    _systemHUDDetailLabel.text = english
        ? @"QuartzCore RenderServer system FPS / GPU / hitch view"
        : @"QuartzCore RenderServer 全系统 FPS / GPU / 卡顿视图";

    [_inputModeControl setTitle:(english ? @"Direct Touch" : @"直接触控")
              forSegmentAtIndex:0];
    [_inputModeControl setTitle:(english ? @"Precision Trackpad" : @"精确触控板")
              forSegmentAtIndex:1];
    NSArray *density = english
        ? @[@"Pixel Match", @"Larger +10%", @"More Space +18%"]
        : @[@"像素匹配", @"放大 +10%", @"更多空间 +18%"];
    NSArray *presentationResolution = english
        ? @[@"Auto Sharp", @"Always Sharp", @"Performance"]
        : @[@"自动清晰", @"始终清晰", @"性能优先"];
    NSArray *hud = english ? @[@"Off", @"Compact", @"Full"]
                           : @[@"关闭", @"简洁", @"完整"];
    NSArray *zoom = english ? @[@"Two-Finger Double-Tap 1.5×",
                                @"Two-Finger Double-Tap 2.0×"]
                            : @[@"双指双击 1.5×", @"双指双击 2.0×"];
    for (NSInteger index = 0; index < 3; index++) {
        [_densityControl setTitle:density[(NSUInteger)index]
                forSegmentAtIndex:index];
        [_performanceHUDControl setTitle:hud[(NSUInteger)index]
                forSegmentAtIndex:index];
        [_presentationResolutionControl
            setTitle:presentationResolution[(NSUInteger)index]
            forSegmentAtIndex:index];
    }
    for (NSInteger index = 0; index < 2; index++)
        [_zoomScaleControl setTitle:zoom[(NSUInteger)index]
                  forSegmentAtIndex:index];

    NSDictionary<NSString *, NSArray<NSString *> *> *appTitles = @{
        @"glassdemo": @[@"GlassDemo", @"GlassDemo"],
        @"terminal": @[@"终端", @"Terminal"],
        @"activity-monitor": @[@"活动监视器", @"Activity Monitor"],
        @"finder": @[@"Finder", @"Finder"],
        @"vscode": @[@"VS Code", @"VS Code"],
        @"system-settings": @[@"系统设置", @"System Settings"],
        @"maps": @[@"地图", @"Maps"],
        @"weather": @[@"天气", @"Weather"],
        @"sublime": @[@"Sublime Text", @"Sublime Text"],
        @"steam": @[@"Steam", @"Steam"],
        @"amadine": @[@"Amadine", @"Amadine"],
        @"word": @[@"Word", @"Word"],
        @"excel": @[@"Excel", @"Excel"],
        @"powerpoint": @[@"PowerPoint", @"PowerPoint"],
    };
    for (UIButton *button in _applicationButtons) {
        NSArray<NSString *> *titles = appTitles[button.accessibilityIdentifier];
        if (!titles) continue;
        UIButtonConfiguration *configuration = [button.configuration copy];
        configuration.title = titles[english ? 1 : 0];
        button.configuration = configuration;
    }
    _appSearchField.placeholder = english
        ? @"Search apps or enter an absolute macOS path"
        : @"搜索应用或输入 macOS 绝对路径";
    [self setButton:_keyboardButton
              title:english ? @"Open Software Keyboard" : @"打开虚拟键盘"
              image:@"keyboard"];
    [self setButton:_captureButton title:english ? @"Refresh Display" : @"刷新画面"
              image:@"camera.viewfinder"];
    [self setButton:_repairDesktopButton
              title:english ? @"Repair Desktop" : @"修复桌面"
              image:@"arrow.clockwise.circle"];
    [self setButton:_repairButton title:english ? @"Repair Environment" : @"修复环境"
              image:@"wrench.and.screwdriver"];
    [self setButton:_recoverButton title:english ? @"Safe Recovery" : @"安全恢复"
              image:@"lifepreserver"];
    [self setButton:_logsButton title:english ? @"View Logs" : @"查看日志"
              image:@"doc.text.magnifyingglass"];
    [self setButton:_exportButton title:english ? @"Export Diagnostics" : @"导出诊断"
              image:@"square.and.arrow.up"];
    [self setButton:_windowPickerButton title:english ? @"Open macOS Window" : @"打开 macOS 窗口"
              image:@"macwindow.on.rectangle"];
    [self setButton:_closeWindowButton title:english ? @"Close This macOS Window" : @"关闭此 macOS 窗口"
              image:@"xmark.square"];
    [self setButton:_clipboardButton title:english ? @"Sync Clipboard to macOS" : @"同步剪贴板到 macOS"
              image:@"doc.on.clipboard"];
    [self setButton:_importButton title:english ? @"Import Files to macOS" : @"导入文件到 macOS"
              image:@"square.and.arrow.down.on.square"];
    [self setButton:_macFilesButton title:english ? @"macOS Files" : @"macOS 文件"
              image:@"arrow.up.doc"];
    [self setButton:_performanceResetButton title:english ? @"Reset Timing" : @"重新计时"
              image:@"stopwatch"];
    [self setButton:_performanceExportButton title:english ? @"Export JSON" : @"导出 JSON"
              image:@"square.and.arrow.up"];
    [self setButton:_performanceRunButton title:english ? @"Run Touch / Gesture Regression" : @"运行标准触摸 / 手势回归"
              image:@"hand.draw"];
    [self setButton:_resetZoomButton title:english ? @"Exit Zoom View" : @"退出放大视角"
              image:@"arrow.counterclockwise"];
    [self setButton:_retryStartupButton
              title:english ? @"Try Starting Again" : @"重新尝试启动"
              image:@"arrow.clockwise"];
    _showControlsButton.accessibilityLabel = english
        ? @"macPad Control Center" : @"macPad 控制中心";
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UISceneActivationState activation = self.view.window.windowScene.activationState;
    if (activation != UISceneActivationStateBackground &&
        activation != UISceneActivationStateUnattached &&
        !(_bootstrapTerminalPending && _windowID == 0)) {
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    }
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
        selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
    [self restoreHardwareKeyboardFocusWithReason:@"view-did-appear"];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self dismissSemanticMenu];
    [_metalView geometryDidChange];
    [coordinator animateAlongsideTransition:nil completion:^(
        id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        [self sceneGeometryDidChange];
    }];
}

- (void)sceneGeometryDidChange {
    // UIWindowScene reports Stage Manager resizing as coordinate-space
    // updates, while ordinary split/full-screen transitions arrive through
    // view-controller layout.  Converge both on one transform/configuration
    // boundary so input and pixels never use different generations.
    [self dismissSemanticMenu];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [_metalView geometryDidChange];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)hideControls {
    _controlPanel.hidden = YES;
    _controlDismissLayer.hidden = YES;
    _showControlsMaterial.hidden = NO;
    // The tapped control remains UIKit's responder until this event returns.
    // Reclaim the workspace's physical-keyboard focus on the next main turn.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restoreHardwareKeyboardFocusWithReason:@"controls-hidden"];
    });
}

- (void)showControls {
    _controlDismissLayer.hidden = NO;
    _controlPanel.hidden = NO;
    _showControlsMaterial.hidden = YES;
}

- (void)restoreHardwareKeyboardFocusWithReason:(NSString *)reason {
    if (!_controlPanel.hidden || _keyboardProxy.isFirstResponder) return;
    [_metalView restoreHardwareKeyboardFocusWithReason:reason];
}

- (BOOL)forwardHardwarePressEvent:(UIPressesEvent *)event {
    if (!_controlPanel.hidden || !_metalView.isMacWSInputEnabled || !event)
        return NO;
    BOOL forwarded = NO;
    for (UIPress *press in event.allPresses) {
        BOOL keyDown = NO;
        switch (press.phase) {
            case UIPressPhaseBegan:
                keyDown = YES;
                break;
            case UIPressPhaseEnded:
            case UIPressPhaseCancelled:
                keyDown = NO;
                break;
            default:
                continue;
        }
        forwarded = [_metalView forwardHardwarePresses:[NSSet setWithObject:press]
                                               keyDown:keyDown] || forwarded;
    }
    if (forwarded && MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-window-route presses=%lu target=%d",
                 (unsigned long)event.allPresses.count, _metalView.targetPID);
    }
    return forwarded;
}

- (void)setNotice:(NSString *)notice success:(BOOL)success {
    _noticeLabel.hidden = notice.length == 0;
    _noticeLabel.text = notice;
    _noticeLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
}

- (void)setControlsEnabled:(BOOL)enabled {
    _primaryButton.enabled = enabled;
    _repairDesktopButton.enabled = enabled;
    _repairButton.enabled = enabled;
    _recoverButton.enabled = enabled;
    _captureButton.enabled = enabled;
    _exportButton.enabled = enabled;
    _windowPickerButton.enabled = enabled;
    _closeWindowButton.enabled = enabled && _windowID != 0;
    _menuBarButton.enabled = enabled;
    _clipboardButton.enabled = enabled;
    _importButton.enabled = enabled;
    _macFilesButton.enabled = _receivedMacOSFiles.count > 0;
    _experimentalSwitch.enabled = enabled;
    _inputModeControl.enabled = enabled;
    _performanceHUDControl.enabled = YES;
    _performanceResetButton.enabled = YES;
    _performanceExportButton.enabled = YES;
    _performanceRunButton.enabled = enabled;
    _densityControl.enabled = enabled;
    _presentationResolutionControl.enabled = enabled;
    _zoomScaleControl.enabled = enabled;
    _resetZoomButton.enabled = enabled;
    _retryStartupButton.enabled = enabled;
    for (UIButton *button in _applicationButtons) button.enabled = enabled;
}

- (void)closeCurrentWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        [self setNotice:@"当前是工作区，不对应单独的 macOS 窗口。" success:NO];
        return;
    }
    UISceneSession *session = self.view.window.windowScene.session;
    if (!session) return;
    MacWSRememberSceneBinding(session, [self streamRestorationActivity]);
    if (!MacWSCloseMacWindowForSceneSession(session, @"control-center")) {
        [self setNotice:@"关闭请求发送失败；macOS 窗口保持打开。" success:NO];
        return;
    }
    [UIApplication.sharedApplication
        requestSceneSessionDestruction:session
                              options:nil
                         errorHandler:^(NSError *error) {
        [self setNotice:[NSString stringWithFormat:
            @"macOS 窗口已请求关闭，但 iPadOS 场景未能移除：%@",
            error.localizedDescription ?: @"未知错误"] success:NO];
    }];
}

- (void)keyboardAction {
    if (_keyboardProxy.isFirstResponder) {
        [_keyboardProxy resignFirstResponder];
        [self setButton:_keyboardButton title:@"打开虚拟键盘"
                   image:@"keyboard"];
    } else {
        _keyboardProxy.text = @" ";
        if ([_keyboardProxy becomeFirstResponder]) {
            _metalView.softwareKeyboardActive = YES;
            [self setButton:_keyboardButton title:@"收起虚拟键盘"
                       image:@"keyboard.chevron.compact.down"];
        }
    }
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    _metalView.softwareKeyboardActive = YES;
    _softwareKeyBar.hidden = NO;
    _softwareKeyBarHeightConstraint.constant = 52;
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    }];
    [self setButton:_keyboardButton title:@"收起虚拟键盘"
               image:@"keyboard.chevron.compact.down"];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    _metalView.softwareKeyboardActive = NO;
    _softwareKeyBarHeightConstraint.constant = 0;
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        self->_softwareKeyBar.hidden = YES;
    }];
    [self setButton:_keyboardButton title:@"打开虚拟键盘"
               image:@"keyboard"];
    [_metalView becomeFirstResponder];
}

- (void)softModifierTapped:(UIButton *)sender {
    uint32_t mask = (uint32_t)sender.tag;
    _softModifiers ^= mask;
    sender.selected = (_softModifiers & mask) != 0;
    UIButtonConfiguration *configuration = sender.selected
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = sender.configuration.title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    sender.configuration = configuration;
}

- (void)softKeyTapped:(UIButton *)sender {
    if ([sender.accessibilityIdentifier isEqualToString:@"dismiss-keyboard"]) {
        [self keyboardAction];
        return;
    }
    [_metalView emitSoftwareKeySym:(uint32_t)sender.tag
                         modifiers:_softModifiers];
}

- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)string {
    (void)range;
    if (textField != _keyboardProxy) return YES;
    if (string.length == 0)
        [_metalView emitSoftwareKeySym:0xff08 modifiers:_softModifiers];
    else
        [_metalView emitSoftwareText:string modifiers:_softModifiers];
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _keyboardProxy) {
        [_metalView emitSoftwareKeySym:0xff0d modifiers:_softModifiers];
        return NO;
    }
    if (textField != _appSearchField) return YES;
    NSString *query = [textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return NO;
    NSString *lower = query.lowercaseString;
    NSString *identifier = nil;
    if ([lower containsString:@"visual studio"] ||
        [lower containsString:@"vscode"] || [lower isEqualToString:@"code"])
        identifier = @"vscode";
    else if ([lower containsString:@"terminal"] ||
             [query containsString:@"终端"])
        identifier = @"terminal";
    else if ([lower containsString:@"glass"])
        identifier = @"glassdemo";
    else if ([lower containsString:@"activity"] ||
             [query containsString:@"活动"])
        identifier = @"activity-monitor";
    else if ([lower containsString:@"finder"])
        identifier = @"finder";
    else if ([lower containsString:@"maps"] ||
             [query containsString:@"地图"])
        identifier = @"maps";
    else if ([lower containsString:@"settings"] ||
             [query containsString:@"设置"])
        identifier = @"system-settings";
    else if ([lower containsString:@"amadine"])
        identifier = @"amadine";
    else if ([lower isEqualToString:@"word"] ||
             [lower containsString:@"microsoft word"])
        identifier = @"word";
    else if ([lower isEqualToString:@"excel"] ||
             [lower containsString:@"microsoft excel"])
        identifier = @"excel";
    else if ([lower containsString:@"powerpoint"] ||
             [lower isEqualToString:@"ppt"])
        identifier = @"powerpoint";
    else if ([lower containsString:@"steam"])
        identifier = @"steam";
    else if ([lower containsString:@"weather"] ||
             [query containsString:@"天气"])
        identifier = @"weather";
    else if ([lower containsString:@"sublime"])
        identifier = @"sublime";
    [textField resignFirstResponder];
    if (identifier) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier}];
    } else if ([query hasPrefix:@"/"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_PATH
                 arguments:@{@MACWS_CONTROL_KEY_APP_PATH: query}];
    } else {
        [self setNotice:@"未找到应用；可搜索 Steam、天气、Sublime、Office，或输入 / 开头的 macOS 绝对路径。"
                 success:NO];
    }
    return NO;
}

- (void)inputModeChanged:(UISegmentedControl *)sender {
    MacWSHostInputMode mode = sender.selectedSegmentIndex == 1
        ? MacWSHostInputModeTrackpad : MacWSHostInputModeDirect;
    _metalView.inputMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"MacWSInputMode"];
    _inputLabel.text = mode == MacWSHostInputModeTrackpad
        ? MacWSLocalized(@"输入：单指移动圆形指针，轻点单击，长按拖动，双指滚动/右击",
                         @"Input: move the circular pointer with one finger; tap, hold-drag, two-finger scroll/right-click")
        : MacWSLocalized(@"输入：轻点单击、单指滑动滚动；长按后滑动拖动，长按释放右击",
                         @"Input: tap to click, swipe to scroll; hold-drag, or hold and release to right-click");
}

- (void)densityChanged:(UISegmentedControl *)sender {
    MacWSHostDisplayDensity density = sender.selectedSegmentIndex == 2
        ? MacWSHostDisplayDensityKeyboard
        : (sender.selectedSegmentIndex == 1
            ? MacWSHostDisplayDensityComfort
            : MacWSHostDisplayDensityTouchComfort);
    _metalView.displayDensity = density;
    [NSUserDefaults.standardUserDefaults setInteger:density
                                              forKey:@"MacWSDisplayDensity"];
    if (density == MacWSHostDisplayDensityKeyboard) {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：更多空间；当前有效密度 %.0f%%，画布比像素匹配模式多约 18%%",
            _metalView.effectiveDensityScale * 100.0];
    } else if (density == MacWSHostDisplayDensityComfort) {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：放大 +10%%；有效密度 %.0f%%，使用 Metal 高质量重采样；如需逐像素锐利请切换像素匹配",
            _metalView.effectiveDensityScale * 100.0];
    } else {
        _inputLabel.text = [NSString stringWithFormat:
            @"显示：像素匹配 Retina；当前有效密度 %.0f%%（随 iPadOS 合成比例自动调整）",
            _metalView.effectiveDensityScale * 100.0];
    }
}

- (void)presentationResolutionChanged:(UISegmentedControl *)sender {
    MacWSHostPresentationResolution resolution =
        (MacWSHostPresentationResolution)sender.selectedSegmentIndex;
    _metalView.presentationResolution = resolution;
    [NSUserDefaults.standardUserDefaults setInteger:resolution
        forKey:@"MacWSPresentationResolution"];
    if (resolution == MacWSHostPresentationResolutionSourceNative) {
        [self setNotice:@"显示清晰度：始终保留 WindowServer 源像素；全屏游戏会增加显示合成负载。"
                 success:YES];
    } else if (resolution == MacWSHostPresentationResolutionPerformance) {
        [self setNotice:@"显示清晰度：性能优先；输出为每个 UIKit 点一个像素。"
                 success:YES];
    } else {
        [self setNotice:@"显示清晰度：桌面保留源像素，全屏游戏自动切换性能分辨率。"
                 success:YES];
    }
}

- (void)performanceHUDChanged:(UISegmentedControl *)sender {
    MacWSPerformanceHUDMode mode = (MacWSPerformanceHUDMode)
        sender.selectedSegmentIndex;
    _metalView.performanceMonitor.HUDMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode
        forKey:@"MacWSPerformanceHUDMode"];
    if (mode == MacWSPerformanceHUDModeOff) {
        [self setNotice:@"MacWS 性能 HUD 已隐藏；手动计时会持续到导出，普通生产热路径停止采样"
                 success:YES];
    } else {
        [self setNotice:mode == MacWSPerformanceHUDModeFull
            ? @"完整性能 HUD 已开启（2 Hz 刷新，不改变 DisplayStream 帧率）"
            : @"简洁性能 HUD 已开启（实际 drawable 呈现 FPS / 1% low）"
                 success:YES];
    }
}

- (void)systemPerformanceHUDChanged:(UISwitch *)sender {
    NSError *error = nil;
    // CAPerfHUD level 5 is Apple's Full render-server view. Keep this
    // explicit and independently switchable because it is system-wide and
    // persists until disabled or backboardd restarts.
    NSInteger requestedLevel = sender.isOn ? 5 : 0;
    BOOL applied = [MacWSPerformanceMonitor
        setSystemPerformanceHUDLevel:requestedLevel error:&error];
    if (!applied) sender.on = !sender.isOn;
    [self setNotice:applied
        ? (sender.isOn ? @"Apple 全系统渲染 HUD 已开启"
                       : @"Apple 全系统渲染 HUD 已关闭")
        : (error.localizedDescription ?: @"无法切换 Apple 系统渲染 HUD")
        success:applied];
}

- (void)resetPerformanceMeasurement {
    [_metalView.performanceMonitor resetWithReason:@"control-center"];
    [self setNotice:@"性能计时已清零；请立即执行要测量的触摸手势"
             success:YES];
}

- (void)exportPerformanceMeasurement {
    NSError *error = nil;
    NSString *path = [_metalView.performanceMonitor
        exportSnapshotWithReason:@"control-center" error:&error];
    if (!path) {
        [self setNotice:error.localizedDescription ?: @"性能 JSON 导出失败"
                 success:NO];
        return;
    }
    MacWSLog(@"performance-profile-export path=%@", path);
    [self setNotice:[NSString stringWithFormat:@"性能报告已保存：%@", path]
             success:YES];
}

- (void)runPerformanceGestureSuite {
    if (!_metalView.isMacWSInputEnabled) {
        [self setNotice:@"触控桥或 DisplayStream 尚未就绪，不能开始回归"
                 success:NO];
        return;
    }
    _performanceRunButton.enabled = NO;
    NSError *systemHUDError = nil;
    (void)[MacWSPerformanceMonitor setSystemPerformanceHUDLevel:0
        error:&systemHUDError];
    _systemPerformanceHUDSwitch.on = NO;
    [_metalView.performanceMonitor resetWithReason:@"gesture-suite"];
    NSMutableArray<NSString *> *scenarios = [@[
        @"tap", @"double-tap", @"right-tap", @"hover", @"drag",
        @"long-drag", @"scroll", @"scroll-momentum", @"magnify",
    ] mutableCopy];
    if (_streamMode == MacWSStreamModeFullscreen) {
        [scenarios addObjectsFromArray:@[
            @"three-up", @"three-down", @"three-left", @"three-right",
        ]];
    }
    [self setNotice:[NSString stringWithFormat:
        @"正在运行 %lu 个标准手势；请暂时不要触摸屏幕",
        (unsigned long)scenarios.count] success:YES];

    __block NSUInteger index = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^runNext)(void) = nil;
    runNext = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (index >= scenarios.count) {
            NSError *error = nil;
            NSString *path = [strongSelf->_metalView.performanceMonitor
                exportSnapshotWithReason:@"gesture-suite" error:&error];
            strongSelf->_performanceRunButton.enabled = YES;
            [strongSelf setNotice:path
                ? [NSString stringWithFormat:
                    @"标准手势回归完成，性能报告：%@", path]
                : (error.localizedDescription ?: @"手势完成，但报告导出失败")
                success:path != nil];
            MacWSLog(@"performance-gesture-suite-end count=%lu path=%@ error=%@",
                     (unsigned long)scenarios.count, path ?: @"",
                     error ?: @"");
            runNext = nil;
            return;
        }
        NSString *scenario = scenarios[index++];
        [strongSelf->_metalView runPerformanceGestureScenario:scenario
            completion:^(BOOL success, NSString *message) {
                typeof(self) innerSelf = weakSelf;
                if (!innerSelf) return;
                if (!success) {
                    innerSelf->_performanceRunButton.enabled = YES;
                    [innerSelf setNotice:[NSString stringWithFormat:
                        @"手势 %@ 失败：%@", scenario, message] success:NO];
                    MacWSLog(@"performance-gesture-suite-abort scenario=%@ reason=%@",
                             scenario, message);
                    runNext = nil;
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              250 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), runNext);
            }];
    };
    MacWSLog(@"performance-gesture-suite-start count=%lu",
             (unsigned long)scenarios.count);
    runNext();
}

- (void)zoomScaleChanged:(UISegmentedControl *)sender {
    CGFloat scale = sender.selectedSegmentIndex == 1 ? 2.0 : 1.5;
    _metalView.fixedZoomScale = scale;
    [NSUserDefaults.standardUserDefaults setDouble:scale
                                             forKey:@"MacWSFixedZoomScale"];
    [self setNotice:[NSString stringWithFormat:
        @"双指双击放大倍率已设为 %.1f×", scale] success:YES];
}

- (void)resetZoomAction {
    [_metalView resetViewportZoom];
    [self setNotice:@"已退出放大视角并恢复中心位置" success:YES];
}

- (void)syncClipboardAction {
    [_interopClient publishGeneralPasteboard];
}

- (void)importFilesAction {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    [_interopClient stageAndPublishFiles:urls
        completion:^(NSArray<NSURL *> *stagedURLs, NSError *error) {
            [self setNotice:error ? error.localizedDescription :
                [NSString stringWithFormat:@"已导入 %lu 个文件；macOS 应用可直接粘贴。",
                 (unsigned long)stagedURLs.count]
                success:error == nil];
        }];
}

- (void)shareMacOSFiles {
    if (!_receivedMacOSFiles.count) {
        [self setNotice:@"macOS 剪贴板中还没有可导出的文件" success:NO];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:_receivedMacOSFiles applicationActivities:nil];
    activity.popoverPresentationController.sourceView = _macFilesButton;
    activity.popoverPresentationController.sourceRect = _macFilesButton.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)interopClient:(MacWSInteropClient *)client
        statusChanged:(NSString *)status
            connected:(BOOL)connected {
    (void)client;
    _interopLabel.text = [@"互操作：" stringByAppendingString:status];
    _interopLabel.textColor = connected ? UIColor.systemGreenColor
                                        : UIColor.systemOrangeColor;
}

- (void)interopClient:(MacWSInteropClient *)client
 receivedMacOSFilesAtURLs:(NSArray<NSURL *> *)urls {
    (void)client;
    _receivedMacOSFiles = [urls copy];
    _macFilesButton.enabled = urls.count > 0;
    [self setButton:_macFilesButton
              title:[NSString stringWithFormat:@"拖出/分享 macOS 文件 · %lu",
                     (unsigned long)urls.count]
              image:@"arrow.up.doc"];
}

- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction
                     itemsForBeginningSession:(id<UIDragSession>)session {
    (void)interaction;
    (void)session;
    NSMutableArray<UIDragItem *> *items = [NSMutableArray array];
    for (NSURL *url in _receivedMacOSFiles) {
        NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
        if (provider) [items addObject:[[UIDragItem alloc]
            initWithItemProvider:provider]];
    }
    return items;
}

- (BOOL)dropInteraction:(UIDropInteraction *)interaction
        canHandleSession:(id<UIDropSession>)session {
    (void)interaction;
    return [session hasItemsConformingToTypeIdentifiers:@[
        @"public.item", @"public.image", @"public.text"
    ]];
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction
                    sessionDidUpdate:(id<UIDropSession>)session {
    (void)interaction;
    (void)session;
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}

- (void)dropInteraction:(UIDropInteraction *)interaction
      performDrop:(id<UIDropSession>)session {
    (void)interaction;
    for (UIDragItem *dragItem in session.items) {
        NSItemProvider *provider = dragItem.itemProvider;
        if ([provider hasItemConformingToTypeIdentifier:@"public.item"]) {
            [provider loadFileRepresentationForTypeIdentifier:@"public.item"
                completionHandler:^(NSURL *url, NSError *error) {
                    if (!url || error) return;
                    NSString *cacheDirectory = [@"/var/mobile/Library/Caches/MacWSDrops"
                        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
                    [NSFileManager.defaultManager
                        createDirectoryAtPath:cacheDirectory
                  withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *name = url.lastPathComponent.length
                        ? url.lastPathComponent : @"Dropped Item";
                    NSURL *copy = [NSURL fileURLWithPath:
                        [cacheDirectory stringByAppendingPathComponent:name]];
                    NSError *copyError = nil;
                    if (![NSFileManager.defaultManager copyItemAtURL:url
                                                               toURL:copy
                                                               error:&copyError]) return;
                    [self->_interopClient stageAndPublishFiles:@[copy]
                        completion:^(NSArray<NSURL *> *staged, NSError *stageError) {
                            [self setNotice:stageError ? stageError.localizedDescription :
                                [NSString stringWithFormat:@"已拖入 %lu 个文件到 macOS",
                                 (unsigned long)staged.count]
                                success:stageError == nil];
                        }];
                }];
        } else if ([provider canLoadObjectOfClass:UIImage.class]) {
            [provider loadObjectOfClass:UIImage.class
                completionHandler:^(UIImage *image, NSError *error) {
                    if (!image || error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIPasteboard.generalPasteboard.image = image;
                        [self->_interopClient publishGeneralPasteboard];
                    });
                }];
        } else if ([provider canLoadObjectOfClass:NSString.class]) {
            [provider loadObjectOfClass:NSString.class
                completionHandler:^(NSString *text, NSError *error) {
                    if (!text || error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIPasteboard.generalPasteboard.string = text;
                        [self->_interopClient publishGeneralPasteboard];
                    });
                }];
        }
    }
}

- (NSArray<MacWSStreamWindow *> *)logicalWindowRepresentatives {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *representatives =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in _streamWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (!identity) continue;
        MacWSStreamWindow *current = representatives[identity];
        if (!current) {
            representatives[identity] = window;
            [order addObject:identity];
            continue;
        }
        MacWSStreamWindowFlags flags = descriptor.flags;
        MacWSStreamWindowFlags currentFlags = current.descriptor.flags;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((descriptor.windowID == _windowID) ? 1 : 0);
        NSUInteger currentScore =
            ((currentFlags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((currentFlags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((current.descriptor.windowID == _windowID) ? 1 : 0);
        if (score > currentScore) representatives[identity] = window;
    }
    NSMutableArray<MacWSStreamWindow *> *result = [NSMutableArray array];
    for (NSString *identity in order) {
        MacWSStreamWindow *window = representatives[identity];
        if (window) [result addObject:window];
    }
    return result;
}

- (void)openWindowPicker {
    [_metalView requestStreamWindowList];
    NSArray<MacWSStreamWindow *> *logicalWindows =
        [self logicalWindowRepresentatives];
    if (logicalWindows.count == 0) {
        [self setNotice:@"正在读取 macOS 窗口；DisplayStream 服务就绪后请再试一次。"
                 success:YES];
        return;
    }
    BOOL fullscreenWorkspace = [self isFullscreenWorkspace];
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:fullscreenWorkspace
            ? @"切换 macOS 窗口" : @"在新 iPadOS 窗口中打开"
                         message:fullscreenWorkspace
            ? @"所选窗口会留在当前全屏桌面中，不会创建新的 iPadOS 窗口。"
            : @"每个 Scene 只订阅一个 macOS 窗口的 IOSurface 流。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(logicalWindows.count, 24);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = logicalWindows[index];
        NSString *title = window.title.length ? window.title :
            [NSString stringWithFormat:@"Window %u", window.descriptor.windowID];
        [picker addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if ([self isFullscreenWorkspace]) {
                    [self activateMacWindow:window];
                    return;
                }
                MacWSRequestNewScene(self.view.window.windowScene,
                    window.descriptor.windowID, window.descriptor.ownerPID,
                    window.descriptor.logicalGroupID,
                    CGSizeMake(window.descriptor.logicalWidth,
                               window.descriptor.logicalHeight),
                    CGSizeMake(window.descriptor.minimumLogicalWidth,
                               window.descriptor.minimumLogicalHeight),
                    (window.descriptor.flags & MacWSStreamWindowResizable) != 0,
                    title, ^(NSError *error) {
                        if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                            error.code == 2) {
                            [self openWindowInCurrentScene:window
                                reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                        } else {
                            [self setNotice:error.localizedDescription success:NO];
                        }
                    });
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = _windowPickerButton;
    picker.popoverPresentationController.sourceRect = _windowPickerButton.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason {
    if (!window || window.descriptor.windowID == 0) return;
    [self openWindowIDInCurrentScene:window.descriptor.windowID
                            ownerPID:window.descriptor.ownerPID
                      logicalGroupID:window.descriptor.logicalGroupID
                               title:window.title
                              reason:reason];
    _windowMinimumSize = CGSizeMake(window.descriptor.minimumLogicalWidth,
                                    window.descriptor.minimumLogicalHeight);
    _windowPreferredSize = CGSizeMake(window.descriptor.logicalWidth,
                                      window.descriptor.logicalHeight);
    _windowResizable =
        (window.descriptor.flags & MacWSStreamWindowResizable) != 0;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.targetWindowResizable = _windowResizable;
    // openWindowIDInCurrentScene: establishes the stream before catalog
    // metadata is installed. Persist once more with the authoritative AppKit
    // size so a later FrontBoard reconnect can reproduce the same small
    // native Scene instead of falling back to a stock category.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
}

- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason {
    if (windowID == 0 || ownerPID <= 1) return;
    [_metalView suspendStream];
    // A Scene is reused across per-window and desktop presentation. A
    // double-tap zoom belongs to the old stream's coordinate space; carrying
    // it into the new stream crops the desktop and maps input into that stale
    // crop. Reset before installing the new stream identity.
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeWindow;
    _windowID = windowID;
    _windowOwnerPID = ownerPID;
    _windowGroupID = logicalGroupID;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _windowMinimumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    _metalView.targetPID = ownerPID;
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = title.length ? title :
        [NSString stringWithFormat:@"MacWS Window %u", windowID];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    if (_semanticMenuBar) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [self setNotice:reason.length ? reason : @"已在当前 iPadOS 窗口中打开 macOS 窗口"
             success:YES];
    MacWSLog(@"scene-reused mode=window window=%u owner=%d reason=%@",
             windowID, ownerPID, reason ?: @"");
}

- (void)openFullscreenWorkspace {
    if (_streamMode == MacWSStreamModeFullscreen) {
        if (!_workspaceReturnValid || _workspaceReturnWindowID == 0 ||
            _workspaceReturnOwnerPID <= 1) {
            // A restored desktop can legitimately outlive the AppKit window
            // from which it was entered.  Use the current focused, visible
            // catalog window as the return destination instead of making the
            // fullscreen toggle one-way. This is the same generic window
            // identity used by the picker and input router.
            MacWSStreamWindow *fallback = nil;
            for (MacWSStreamWindow *candidate in _streamWindows) {
                MacWSStreamWindowFlags flags = candidate.descriptor.flags;
                if (candidate.descriptor.ownerPID <= 1 ||
                    (flags & MacWSStreamWindowVisible) == 0 ||
                    (flags & MacWSStreamWindowOnScreen) == 0) continue;
                if (!fallback) fallback = candidate;
                if (flags & MacWSStreamWindowFocused) {
                    fallback = candidate;
                    break;
                }
            }
            if (!fallback) {
                [self setNotice:@"当前工作区没有可恢复的 macOS 窗口；请先打开一个应用。"
                         success:NO];
                return;
            }
            _workspaceReturnValid = YES;
            _workspaceReturnWindowID = fallback.descriptor.windowID;
            _workspaceReturnOwnerPID = fallback.descriptor.ownerPID;
            _workspaceReturnGroupID = fallback.descriptor.logicalGroupID;
            _workspaceReturnMinimumSize = CGSizeMake(
                fallback.descriptor.minimumLogicalWidth,
                fallback.descriptor.minimumLogicalHeight);
            _workspaceReturnPreferredSize = CGSizeMake(
                fallback.descriptor.logicalWidth,
                fallback.descriptor.logicalHeight);
            _workspaceReturnSceneSize = _workspaceReturnPreferredSize;
            _workspaceReturnResizable =
                (fallback.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _workspaceReturnTitle = fallback.title.length
                ? [fallback.title copy] : @"macOS Window";
            MacWSLog(@"workspace-return recovered-from-catalog owner=%d window=%u group=%u title=%@",
                     _workspaceReturnOwnerPID, _workspaceReturnWindowID,
                     _workspaceReturnGroupID, _workspaceReturnTitle);
        }

        uint32_t returnWindowID = _workspaceReturnWindowID;
        int32_t returnOwnerPID = _workspaceReturnOwnerPID;
        uint32_t returnGroupID = _workspaceReturnGroupID;
        CGSize returnMinimumSize = _workspaceReturnMinimumSize;
        CGSize returnPreferredSize = _workspaceReturnPreferredSize;
        CGSize returnSceneSize = _workspaceReturnSceneSize;
        BOOL returnResizable = _workspaceReturnResizable;
        NSString *returnTitle = [_workspaceReturnTitle copy];
        UIWindowScene *scene = self.view.window.windowScene;
        __weak MacWSViewController *weakSelf = self;
        void (^restoreInCurrentScene)(NSError *) = ^(NSError *error) {
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_sceneDestructionRequested = NO;
            BOOL requestedSystemWindowed =
                MacWSRequestCurrentSceneMaximization(scene, NO, nil);
            strongSelf->_workspaceReturnValid = NO;
            strongSelf->_workspaceReturnWindowID = 0;
            strongSelf->_workspaceReturnOwnerPID = 0;
            strongSelf->_workspaceReturnGroupID = 0;
            strongSelf->_workspaceReturnMinimumSize = CGSizeZero;
            strongSelf->_workspaceReturnPreferredSize = CGSizeZero;
            strongSelf->_workspaceReturnSceneSize = CGSizeZero;
            strongSelf->_workspaceReturnResizable = NO;
            strongSelf->_workspaceReturnTitle = nil;
            [strongSelf openWindowIDInCurrentScene:returnWindowID
                                          ownerPID:returnOwnerPID
                                    logicalGroupID:returnGroupID
                                             title:returnTitle
                                            reason:nil];
            strongSelf->_windowMinimumSize = returnMinimumSize;
            strongSelf->_windowPreferredSize = returnPreferredSize;
            strongSelf->_windowResizable = returnResizable;
            strongSelf->_metalView.minimumLogicalSize = returnMinimumSize;
            strongSelf->_metalView.targetWindowResizable = returnResizable;
            MacWSRememberSceneBinding(scene.session,
                                      [strongSelf streamRestorationActivity]);
            [strongSelf hideControls];
            [strongSelf setNotice:error
                ? [NSString stringWithFormat:
                    @"系统未能创建窗口场景，已在当前场景恢复：%@",
                    error.localizedDescription ?: @"未知错误"]
                : (requestedSystemWindowed
                    ? @"正在通过 iPadOS 系统动画恢复窗口模式"
                    : @"已恢复 macOS 窗口内容")
                         success:error == nil];
            MacWSLog(@"scene-reused mode=window restored-from-workspace window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f system-unzoom-requested=%@ replacement-error=%@",
                     returnWindowID, returnOwnerPID, returnGroupID,
                     returnSceneSize.width, returnSceneSize.height,
                     requestedSystemWindowed ? @"YES" : @"NO",
                     error ?: @"none");
        };

        if (_sceneDestructionRequested) return;
        _sceneDestructionRequested = YES;
        BOOL requestedReplacement = MacWSRequestWindowedReplacementScene(
            scene, returnWindowID, returnOwnerPID, returnGroupID,
            returnPreferredSize, returnMinimumSize, returnResizable,
            returnTitle, restoreInCurrentScene);
        if (!requestedReplacement) {
            restoreInCurrentScene(nil);
            return;
        }
        [self hideControls];
        [self setNotice:@"正在通过 iPadOS 系统窗口动画恢复窗口模式"
                 success:YES];
        MacWSLog(@"scene-windowed-replacement submitted old=%@ window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f",
                 scene.session.persistentIdentifier, returnWindowID,
                 returnOwnerPID, returnGroupID, returnSceneSize.width,
                 returnSceneSize.height);
        return;
    }

    // Fullscreen is a presentation mode of the current Scene. The previous
    // implementation requested a second Scene session, so the button could
    // never make the window the user was operating become the workspace.
    // First activate the exact native window while its ID/PID mapping is still
    // authoritative, then detach this Scene from that identity and subscribe
    // it to the complete desktop producer.
    _workspaceReturnValid = _windowID != 0 && _windowOwnerPID > 1;
    _workspaceReturnWindowID = _windowID;
    _workspaceReturnOwnerPID = _windowOwnerPID;
    _workspaceReturnGroupID = _windowGroupID;
    _workspaceReturnMinimumSize = _windowMinimumSize;
    _workspaceReturnPreferredSize = _windowPreferredSize;
    // UIWindowScene.coordinateSpace is panel-sized even for a Stage Manager
    // Center window on iPadOS 16 (runtime: 1389x970 in both roles). The root
    // view is the actual Scene content extent. Preserve it only as a witness;
    // SpringBoard's maximization toggle owns restoration of the native size.
    CGSize currentViewSize = self.view.bounds.size;
    _workspaceReturnSceneSize =
        currentViewSize.width >= 150.0 && currentViewSize.height >= 150.0
            ? currentViewSize : _windowPreferredSize;
    _workspaceReturnResizable = _windowResizable;
    _workspaceReturnTitle = [self.view.window.windowScene.title copy];
    BOOL activatedExactWindow = [self activateCurrentMacWindow];
    [_metalView suspendStream];
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeFullscreen;
    _windowID = 0;
    _windowOwnerPID = 0;
    _windowGroupID = 0;
    _windowMinimumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    _metalView.targetPID = 0;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    [self dismissSemanticMenu];
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = @"MacWS Workspace";
    [_metalView configureStreamMode:_streamMode windowID:0];
    [_metalView requestStreamWindowList];
    // Fullscreen is presentation state, not a new owner identity. Persist the
    // return identity in the Scene activity so a UIKit process eviction does
    // not strand the AppKit window or turn the toggle into a one-way action.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    NSUserActivity *workspaceActivity = [self streamRestorationActivity];
    BOOL requestedSystemFullscreen =
        MacWSRequestCurrentSceneImmersiveFullscreen(
        self.view.window.windowScene, workspaceActivity,
        ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    if (!requestedSystemFullscreen) {
        requestedSystemFullscreen = MacWSRequestCurrentSceneMaximization(
            self.view.window.windowScene, YES,
            ^(NSError *error) {
                [self setNotice:[NSString stringWithFormat:
                    @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                    error.localizedDescription ?: @"未知错误"] success:NO];
            });
    }
    if (requestedSystemFullscreen) {
        // _requestFullscreen: is asynchronous and can be accepted without a
        // FrontBoard geometry transition for an already-connected Stage
        // Manager Scene. Verify the real UIWindow, then use the SpringBoard
        // window action only when the native video/game route did not land.
        __weak MacWSViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     1250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf ||
                strongSelf->_streamMode != MacWSStreamModeFullscreen) return;
            UIWindowScene *currentScene = strongSelf.view.window.windowScene;
            CGRect visibleBounds = strongSelf.view.window.bounds;
            CGRect screenBounds = currentScene.screen.bounds;
            BOOL systemState = [currentScene respondsToSelector:
                @selector(isFullScreen)] && currentScene.isFullScreen;
            BOOL fillsPanel = fabs(visibleBounds.size.width -
                                   screenBounds.size.width) <= 1.0 &&
                fabs(visibleBounds.size.height -
                     screenBounds.size.height) <= 1.0;
            if (systemState || fillsPanel) {
                MacWSLog(@"scene-immersive landed session=%@ is-fullscreen=%@ bounds=%@ screen=%@",
                         currentScene.session.persistentIdentifier,
                         systemState ? @"YES" : @"NO",
                         NSStringFromCGRect(visibleBounds),
                         NSStringFromCGRect(screenBounds));
                return;
            }
            MacWSLog(@"scene-immersive fallback session=%@ reason=window-bounds-not-fullscreen bounds=%@ screen=%@",
                     currentScene.session.persistentIdentifier,
                     NSStringFromCGRect(visibleBounds),
                     NSStringFromCGRect(screenBounds));
            MacWSRequestCurrentSceneMaximization(
                currentScene, YES, ^(NSError *error) {
                    [strongSelf setNotice:[NSString stringWithFormat:
                        @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                        error.localizedDescription ?: @"未知错误"] success:NO];
                });
        });
    }
    [self hideControls];
    [self refreshStatus];
    [self setNotice:requestedSystemFullscreen
        ? @"正在将当前 iPadOS 窗口最大化并显示完整 macOS 工作区"
        : @"已显示完整 macOS 工作区；当前 iPadOS 版本没有可用的最大化请求"
             success:requestedSystemFullscreen];
    MacWSLog(@"scene-reused mode=fullscreen previous-window-activated=%@ system-fullscreen-requested=%@",
             activatedExactWindow ? @"YES" : @"NO",
             requestedSystemFullscreen ? @"YES" : @"NO");
}

- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled {
    BOOL active = _streamMode == MacWSStreamModeFullscreen;
    if (active == enabled) {
        MacWSLog(@"workspace-mode request idempotent requested=%@ active=%@ recovery=%@",
                 enabled ? @"fullscreen" : @"window",
                 active ? @"fullscreen" : @"window",
                 enabled ? @"YES" : @"NO");
        // A service restart does not change the controller's persisted mode,
        // but it can invalidate the DisplayStream connection and the system's
        // presentation transaction.  Treat a repeated enter-workspace request
        // as an explicit recovery operation: reassert the real UIKit scene
        // geometry and refreshStatus will reconnect the stream when its live
        // connection witness is false.  Exiting an already-windowed workspace
        // remains a true no-op.
        if (enabled) {
            // A Host restart can restore the persisted fullscreen stream mode
            // while the freshly-created controller still has its bootstrap
            // control panel visible.  Reasserting only the Scene geometry then
            // leaves a screen-filling control center over a healthy macOS
            // desktop.  Converge the presentation state as well as the stream
            // and geometry state, matching the first-entry path below.
            [self hideControls];
            [self reassertFullscreenScenePresentation];
            [self refreshStatus];
            MacWSLog(@"workspace-mode recovery controls-hidden=YES");
        }
        return;
    }
    [self openFullscreenWorkspace];
}

- (void)reassertFullscreenScenePresentation {
    if (_streamMode != MacWSStreamModeFullscreen) return;
    [self updateImmersivePresentation];
    BOOL requested = MacWSRequestCurrentSceneMaximization(
        self.view.window.windowScene, YES, ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已恢复，但 iPadOS 无法重新最大化窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    MacWSLog(@"scene-fullscreen foreground-reassert requested=%@",
             requested ? @"YES" : @"NO");
}

- (void)refreshStatus {
    [_controlClient fetchStatus:^(NSDictionary<NSString *,id> *reply) {
        [self applyStatus:reply];
    }];
}

- (void)applyStatus:(NSDictionary<NSString *, id> *)status {
    _latestStatus = status;
    BOOL connected = ![status[@"connection_error"] boolValue];
    BOOL busy = [status[@"busy"] boolValue];
    BOOL rootfs = [status[@"rootfs_ready"] boolValue];
    BOOL ws = [status[@"windowserver_running"] boolValue];
    BOOL input = [status[@"input_running"] boolValue];
    BOOL systemInputReady =
        [status[@MACWS_CONTROL_KEY_SYSTEM_INPUT_READY] boolValue];
    int32_t systemInputPID = systemInputReady
        ? [status[@MACWS_CONTROL_KEY_SYSTEM_INPUT_PID] intValue] : 0;
    BOOL frame = [status[@"frame_ready"] boolValue];
    BOOL startupRetry = [status[@"startup_retry_available"] boolValue];
    BOOL legacyFramebuffer = MacWSLegacyFramebufferFallbackEnabled();
    BOOL renderableFrame = _metalView.hasDirectSurfaceFrame ||
        (legacyFramebuffer && frame);
    int32_t catalogPID = _metalView.targetPID;
    int32_t targetPID = _streamMode == MacWSStreamModeWindow
        ? _windowOwnerPID
        : (MacWSAppInputEndpointReady(catalogPID) ? catalogPID : 0);
    // The full workspace must follow AppKit's actual focused window catalog,
    // not macwshostd's process-local "last app launched" cache.  The daemon
    // can restart while healthy chroot applications and their endpoints stay
    // alive; treating its empty cache as authoritative disabled all touch on
    // an otherwise visible desktop.  Endpoint existence is the invariant for
    // both exact-window and full-workspace routing.
    BOOL appInput = MacWSAppInputEndpointReady(targetPID);
    BOOL fullscreenSystemRoute =
        _streamMode == MacWSStreamModeFullscreen && targetPID <= 1 &&
        systemInputReady && systemInputPID > 1;
    NSString *controlSummary = [NSString stringWithFormat:
        @"connected=%@ busy=%@ rootfs=%@ ws=%@ input=%@ system-input=%@/%d frame=%@ phase=%@ error=%@",
        connected ? @"YES" : @"NO", busy ? @"YES" : @"NO",
        rootfs ? @"YES" : @"NO", ws ? @"YES" : @"NO",
        input ? @"YES" : @"NO", systemInputReady ? @"YES" : @"NO",
        systemInputPID, frame ? @"YES" : @"NO",
        status[@"phase"] ?: @"", status[@"last_error"] ?: @""];
    if (![_lastLoggedControlSummary isEqualToString:controlSummary]) {
        _lastLoggedControlSummary = controlSummary;
        MacWSLog(@"control-status %@", controlSummary);
    }
    // A persisted fullscreen Scene can reconnect before the root control
    // reply reveals that WindowServer is gone (for example after an iPadOS
    // respring retires the UIKit-hosted bridge generation).  The black Metal
    // canvas is not a usable recovery UI.  Converge any such stale Scene on
    // the Control Center as soon as the authoritative WindowServer state is
    // known. This also repairs already-persisted sessions created by older
    // builds rather than relying only on the initializer above.
    if (!ws && _controlPanel.hidden) {
        [self showControls];
        MacWSLog(@"workspace-offline controls-shown=YES mode=%u window=%u",
                 _streamMode, _windowID);
    }
    _serviceLabel.text = connected
        ? MacWSLocalized(@"● root 控制服务已连接", @"● Root control service connected")
        : MacWSLocalized(@"● root 控制服务离线", @"● Root control service offline");
    _serviceLabel.textColor = connected ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSString *rawPhase = status[@"phase"] ?: status[@"message"];
    _phaseLabel.text = MacWSLocalizedPhase(rawPhase) ?:
        MacWSLocalized(@"等待状态", @"Waiting for status");
    _rootfsLabel.text = rootfs ? MacWSLocalized(@"就绪", @"Ready")
                               : MacWSLocalized(@"缺失/未挂载", @"Missing / Unmounted");
    _rootfsLabel.textColor = rootfs ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSInteger wsPID = [status[@"windowserver_pid"] integerValue];
    _windowServerLabel.text = ws
        ? [NSString stringWithFormat:MacWSLocalized(@"运行中 · %ld", @"Running · %ld"),
                                     (long)wsPID]
        : MacWSLocalized(@"已停止", @"Stopped");
    _windowServerLabel.textColor = ws ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    _bridgeLabel.text = input
        ? (targetPID > 1 && appInput
            ? [NSString stringWithFormat:MacWSLocalized(@"在线 · 目标 PID %d", @"Online · Target PID %d"), targetPID]
            : (fullscreenSystemRoute
                ? MacWSLocalized(@"在线 · 全桌面逐点命中", @"Online · Desktop hit testing")
                : (targetPID > 1
                    ? MacWSLocalized(@"在线 · 等待应用输入端点", @"Online · Waiting for app input endpoint")
                    : MacWSLocalized(@"在线 · 等待应用", @"Online · Waiting for app"))))
        : MacWSLocalized(@"离线", @"Offline");
    _bridgeLabel.textColor = input ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    if (_metalView.hasDirectSurfaceFrame) {
        _frameLabel.text = _metalView.hasFinalCompositeFrame
            ? MacWSLocalized(@"最终合成 · IOSurface", @"Final Composite · IOSurface")
            : MacWSLocalized(@"窗口层合成 · IOSurface", @"Window-Layer Composite · IOSurface");
        _frameLabel.textColor =
            (_streamMode == MacWSStreamModeFullscreen &&
             !_metalView.hasFinalCompositeFrame)
                ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
    } else if (legacyFramebuffer && frame) {
        _frameLabel.text = [NSString stringWithFormat:@"%@×%@",
                            status[@"frame_width"], status[@"frame_height"]];
        _frameLabel.textColor = UIColor.systemGreenColor;
    } else {
        _frameLabel.text = MacWSLocalized(@"等待 DisplayStream IOSurface 首帧",
                                          @"Waiting for first DisplayStream IOSurface frame");
        _frameLabel.textColor = UIColor.systemOrangeColor;
    }
    if (!_experimentalTouched || ws) {
        _experimentalSwitch.on = [status[@"experimental_mode"] boolValue];
    }
    NSString *lastError = status[@"last_error"];
    if (lastError.length) [self setNotice:lastError success:NO];

    if (ws && !_metalView.streamServiceConnected &&
        !(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    if (ws && !_interopClient.isConnected) [_interopClient connect];

    _metalView.targetPID = targetPID;
    _metalView.systemInputPID = systemInputPID;
    // A root control transaction (for example a 30-second application launch
    // witness) does not stop WindowServer, DisplayStream, or the per-process
    // input sockets.  Coupling desktop input to hostd's unrelated `busy` bit
    // made the whole fullscreen workspace intentionally unresponsive while an
    // app was starting.  Keep controls serialized, but derive input readiness
    // solely from the live display/input transport invariants.
    BOOL inputReady = connected && ws && input && renderableFrame &&
        ((targetPID > 1 && appInput) || fullscreenSystemRoute);
    NSString *inputReason = nil;
    if (!connected) inputReason = MacWSLocalized(@"root 控制服务离线", @"Root control service offline");
    else if (!ws) inputReason = MacWSLocalized(@"macOS 工作区已停止", @"macOS workspace stopped");
    else if (!input) inputReason = MacWSLocalized(@"触控桥离线", @"Touch bridge offline");
    else if (!renderableFrame) inputReason = MacWSLocalized(@"等待 DisplayStream IOSurface 首帧", @"Waiting for first DisplayStream frame");
    else if (_streamMode == MacWSStreamModeFullscreen && targetPID <= 1 &&
             !fullscreenSystemRoute)
        inputReason = MacWSLocalized(@"等待桌面系统输入端点", @"Waiting for desktop system input endpoint");
    else if (targetPID <= 1 && !fullscreenSystemRoute)
        inputReason = MacWSLocalized(@"等待该窗口的所属应用", @"Waiting for this window's app");
    else if (!appInput) inputReason = MacWSLocalized(@"目标应用输入端点尚未就绪", @"Target app input endpoint is not ready");
    BOOL inputWasReady = _metalView.isMacWSInputEnabled;
    [_metalView setMacWSInputEnabled:inputReady reason:inputReason];
    if (inputReady && !inputWasReady) {
        // Scene activation and control dismissal can precede the first
        // DisplayStream frame. Their focus requests correctly decline while
        // input is unavailable; complete the same ownership transaction on
        // the actual not-ready -> ready edge instead of waiting for a click.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreHardwareKeyboardFocusWithReason:@"input-ready"];
        });
    }
    _inputLabel.text = inputReady
        ? MacWSLocalized(@"触控：已就绪 · 直接点击或拖动 macOS 画面",
                         @"Touch: Ready · Tap or drag the macOS display")
        : [NSString stringWithFormat:MacWSLocalized(@"触控：不可用 · %@",
                                                     @"Touch: Unavailable · %@"),
           inputReason ?: MacWSLocalized(@"工作区未就绪", @"Workspace not ready")];
    _inputLabel.textColor = inputReady
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;

    [self setControlsEnabled:connected && !busy];
    if (busy) {
        [self setButton:_primaryButton title:MacWSControlCenterUsesEnglish()
            ? @"Working…" : (status[@"phase"] ?: @"处理中…")
                   image:@"hourglass"];
    } else if (ws) {
        [self setButton:_primaryButton title:MacWSLocalized(@"停止 macOS", @"Stop macOS") image:@"stop.fill"];
    } else if (startupRetry) {
        [self setButton:_primaryButton
                  title:MacWSLocalized(@"重新尝试启动", @"Try Starting Again")
                  image:@"arrow.clockwise"];
    } else {
        [self setButton:_primaryButton
                  title:rootfs ? MacWSLocalized(@"启动 macOS 工作区", @"Start macOS Workspace")
                               : MacWSLocalized(@"初始化并启动", @"Initialize and Start")
                  image:@"play.fill"];
    }

    NSString *startupLog = status[@"startup_log"] ?: @"";
    BOOL showStartupLog = startupLog.length > 0 || startupRetry;
    _startupLogSectionLabel.hidden = !showStartupLog;
    _logsView.hidden = !showStartupLog;
    _retryStartupButton.hidden = !startupRetry;
    if (showStartupLog && startupLog.length &&
        ![_lastStartupLog isEqualToString:startupLog]) {
        _lastStartupLog = [startupLog copy];
        _logsView.text = startupLog;
        [_logsView scrollRangeToVisible:NSMakeRange(startupLog.length - 1, 1)];
    }

    NSDictionary<NSString *, NSString *> *availability = @{
        @"glassdemo": @"glassdemo_available",
        @"terminal": @"terminal_available",
        @"activity-monitor": @"activity_monitor_available",
        @"finder": @"finder_available",
        @"vscode": @"vscode_available",
        @"system-settings": @"system_settings_available",
        @"maps": @"maps_available",
        @"amadine": @"amadine_available",
        @"word": @"word_available",
        @"excel": @"excel_available",
        @"powerpoint": @"powerpoint_available",
        @"steam": @"steam_available",
        @"weather": @"weather_available",
        @"sublime": @"sublime_available",
    };
    for (UIButton *button in _applicationButtons) {
        BOOL available = [status[availability[button.accessibilityIdentifier]] boolValue];
        button.enabled = connected && !busy && ws && available;
    }

    // A new Host Scene is a launcher for one concrete macOS window, not a
    // full-display workspace. Start production macOS if needed, then launch
    // Terminal exactly once. The first catalog entry replaces this Scene
    // in-place, so no redundant black Scene survives startup.
    if (_bootstrapTerminalPending && connected && !busy) {
        if (ws) {
            _bootstrapTerminalPending = NO;
            [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                     arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"terminal"}];
        } else if (!_bootstrapWorkspaceStartInFlight &&
                   !_bootstrapWorkspaceStartAttempted) {
            // One Scene owns at most one automatic workspace start. A failed
            // start leaves ws=NO; applyStatus: is called again by the status
            // timer, so checking only the in-flight bit created an unbounded
            // restart loop. Runtime-confirmed on 2026-08-29 by consecutive
            // macos_gui.sh owners 40307 -> 42910 -> 45547. Explicit retry and
            // repair controls remain available after this one attempt.
            _bootstrapWorkspaceStartAttempted = YES;
            _bootstrapWorkspaceStartInFlight = YES;
            MacWSLog(@"bootstrap-workspace automatic-start attempt=1");
            [self setNotice:@"正在启动 macOS，并准备默认终端窗口…" success:YES];
            [_controlClient startWithExperimentalMode:YES
                completion:^(NSDictionary<NSString *,id> *reply) {
                    self->_bootstrapWorkspaceStartInFlight = NO;
                    BOOL ok = [reply[@"ok"] boolValue];
                    MacWSLog(@"bootstrap-workspace automatic-start completed=%@ message=%@",
                             ok ? @"YES" : @"NO",
                             reply[@"message"] ?: @"(nil)");
                    [self applyStatus:reply];
                    if (!ok) {
                        [self setNotice:reply[@"message"] ?:
                            @"macOS 工作区启动失败" success:NO];
                    }
                }];
        }
    }
}

- (void)runOperation:(NSString *)operation arguments:(NSDictionary *)arguments {
    [self setControlsEnabled:NO];
    NSString *submitted = [operation isEqualToString:
        @MACWS_CONTROL_OP_REPAIR_DESKTOP]
        ? MacWSLocalized(
            @"正在保留当前应用并重建 Dock、图标、桌布与菜单服务…",
            @"Keeping current apps open while rebuilding Dock, icons, wallpaper, and menu services…")
        : @"操作已提交，请保持 App 在前台…";
    [self setNotice:submitted success:YES];
    [_controlClient performOperation:operation arguments:arguments
        completion:^(NSDictionary<NSString *,id> *reply) {
            BOOL ok = [reply[@"ok"] boolValue];
            [self setNotice:reply[@"message"] ?: @"操作完成" success:ok];
            [self applyStatus:reply];
            if (ok && [operation isEqualToString:@MACWS_CONTROL_OP_LAUNCH_APP]) {
                NSString *identifier = arguments[@MACWS_CONTROL_KEY_APP_ID];
                int32_t launchedPID =
                    (int32_t)[reply[@"launched_app_pid"] intValue];
                if (launchedPID > 1) {
                    // hostd now completes Finder's native Command-N bootstrap
                    // before replying, so Finder follows the same catalog ->
                    // one Scene transaction as every other application. The
                    // old post-reply menu walk created a second browser window
                    // after the first had already become visible.
                    self->_pendingApplicationWindowPID = launchedPID;
                    self->_pendingApplicationIdentifier = identifier;
                    self->_pendingApplicationWindowAttempts = 0;
                    self->_pendingApplicationWindowRetryScheduled = NO;
                    self->_pendingApplicationCandidateWindowID = 0;
                    self->_pendingApplicationCandidateSince = 0;
                    [self schedulePendingApplicationWindowRetry];
                }
                [self->_metalView requestStreamWindowList];
            }
            if (ok && [operation isEqualToString:
                       @MACWS_CONTROL_OP_REPAIR_DESKTOP]) {
                // Dock/SystemUIServer replacement changes the fullscreen
                // layer graph while WindowServer and ordinary applications
                // remain alive. Reconnect only this Host's display stream so
                // the repaired final composite and icon-backed Dock windows
                // replace any retained pre-repair frame.
                [self->_metalView suspendStream];
                [self->_metalView configureStreamMode:self->_streamMode
                                              windowID:self->_windowID];
                [self->_metalView requestStreamWindowList];
                if (self->_windowID != 0)
                    [self refreshSemanticMenuWithCompletion:nil];
            }
            [self refreshStatus];
        }];
}

- (void)primaryAction {
    if ([_latestStatus[@"windowserver_running"] boolValue]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else {
        [self setControlsEnabled:NO];
        _retryStartupButton.hidden = YES;
        _startupLogSectionLabel.hidden = NO;
        _logsView.hidden = NO;
        _lastStartupLog = MacWSLocalized(@"正在请求启动…", @"Requesting startup…");
        _logsView.text = _lastStartupLog;
        [self setNotice:_experimentalSwitch.isOn
            ? @"正在用实验兼容模式启动；已启用 5 分钟与高 CPU 自动热保护。"
            : @"正在检查环境；重启后丢失的信任缓存会自动恢复。" success:YES];
        [_controlClient startWithExperimentalMode:_experimentalSwitch.isOn
            completion:^(NSDictionary<NSString *,id> *reply) {
                BOOL ok = [reply[@"ok"] boolValue];
                [self setNotice:reply[@"message"] ?: @"启动完成" success:ok];
                [self applyStatus:reply];
                [self refreshStatus];
            }];
    }
}

- (void)retryStartupAction {
    [self setNotice:MacWSLocalized(
        @"正在重新执行启动检查；日志会在下方实时更新。",
        @"Retrying startup checks; the live log will update below.")
             success:YES];
    [self primaryAction];
}

- (void)experimentalChanged:(UISwitch *)sender {
    _experimentalTouched = YES;
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn
                                          forKey:@"MacWSExperimentalMode"];
    NSString *state = sender.isOn ? @"已选择实验兼容模式，将在下次启动时生效。" :
        @"已选择标准模式，将在下次启动时移除诊断脚手架。";
    [self setNotice:state success:!sender.isOn];
}

- (void)launchApplication:(UIButton *)sender {
    [self launchApplicationIdentifier:sender.accessibilityIdentifier ?: @""];
}

- (void)launchApplicationIdentifier:(NSString *)identifier {
    // hostd owns application-launch serialization.  For Maps it sends one
    // Darwin request back to this already-foreground Host, whose observer
    // performs the responsible-process spawn.  Spawning here as well created
    // two Maps generations during the 200 ms hostd round trip and left both
    // competing for one UIKitSystem scene.  Keep one transaction and one
    // process generation for Control Center, Dock and URL launches alike.
    [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
             arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier ?: @""}];
}

- (void)captureAction {
    [_metalView suspendStream];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [self setNotice:@"正在重新连接 DisplayStream；不会启动 VNC 或复制 framebuffer。"
             success:YES];
}

- (void)repairAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR arguments:nil];
}

- (void)repairDesktopAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR_DESKTOP arguments:nil];
}

- (void)recoverAction {
    [self runOperation:@MACWS_CONTROL_OP_RECOVER arguments:nil];
}

- (void)logsAction {
    if (!_logsView.hidden) {
        _logsView.hidden = YES;
        [self setButton:_logsButton title:@"查看日志" image:@"doc.text.magnifyingglass"];
        return;
    }
    [self setButton:_logsButton title:@"收起日志" image:@"doc.text.magnifyingglass"];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            reply[@"hostd_log"] ?: @"", reply[@"windowserver_log"] ?: @"",
            reply[@"input_log"] ?: @"", reply[@"postinst_log"] ?: @""];
        self->_logsView.text = text;
        self->_logsView.hidden = NO;
        if (text.length) [self->_logsView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    }];
}

- (NSURL *)writeHostUISnapshot {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    // Automation classifies logical UI state, not individual Retina pixels.
    // Encoding the 1389x970-point workspace at the physical 2x scale produced
    // 2778x1940 PNGs of roughly 7.5 MB every observation cycle.  Keep the
    // content and coordinate space exact while avoiding that diagnostic-only
    // encode/transfer load. writeHostScreenSnapshot remains the full-density
    // system-composite capture when pixel-level evidence is required.
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:self.view.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *png = UIImagePNGRepresentation(image);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-ui.png";
    BOOL written = [png writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"ui-snapshot written=%@ bytes=%lu scale=%.1f path=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             format.scale, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)writeHostAutomationSnapshot {
    // The state machine needs scene identity and readable labels, not a
    // lossless Retina artifact. The hierarchy must still be rendered at its
    // exact logical bounds: runtime comparison showed that drawing MTKView
    // into a smaller target loses its CAMetalLayer pixels and preserves only
    // the UIKit FPS overlay. JPEG removes the expensive lossless encode and
    // transfer without changing that capture semantic.
    CGSize size = self.view.bounds.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.58);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-automation.jpg";
    BOOL written = [jpeg writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"automation-snapshot written=%@ bytes=%lu size=%.0fx%.0f path=%@",
             written ? @"YES" : @"NO", (unsigned long)jpeg.length,
             size.width, size.height, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)writeHostScreenSnapshot {
    // RE-confirmed in the target iOS 16.3.1 UIKitCore image: exported
    // _UICreateScreenUIImage at 0x189df62ac returns the foreground screen
    // composite. Keep this explicit diagnostic off every display/input hot
    // path; unlike drawViewHierarchy it can witness system chrome.
    UIImage *(*createScreenImage)(void) =
        (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    UIImage *image = createScreenImage ? createScreenImage() : nil;
    NSData *png = image ? UIImagePNGRepresentation(image) : nil;
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-screen.png";
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    MacWSLog(@"screen-snapshot written=%@ bytes=%lu symbol=%@ path=%@ error=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             createScreenImage ? @"YES" : @"NO", path, error ?: @"");
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (void)exportDiagnostics {
    NSURL *snapshot = [self writeHostUISnapshot];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"macPad diagnostics\n%@\n\n=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            self->_latestStatus ?: @{}, reply[@"hostd_log"] ?: @"",
            reply[@"windowserver_log"] ?: @"", reply[@"input_log"] ?: @"",
            reply[@"postinst_log"] ?: @""];
        NSString *path = @"/var/mobile/Library/Logs/MacWSHost-diagnostics.txt";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:path]];
        if (snapshot) [items addObject:snapshot];
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:items applicationActivities:nil];
        activity.popoverPresentationController.sourceView = self->_exportButton;
        activity.popoverPresentationController.sourceRect = self->_exportButton.bounds;
        [self presentViewController:activity animated:YES completion:nil];
    }];
}

- (void)performURLAction:(NSString *)action {
    MacWSLog(@"url-control action=%@", action);
    if ([action isEqualToString:@"status"] || action.length == 0) {
        [self refreshStatus];
    } else if ([action isEqualToString:@"start"] ||
               [action isEqualToString:@"start-experimental"]) {
        if (![_latestStatus[@"windowserver_running"] boolValue]) {
            _experimentalSwitch.on = [action isEqualToString:@"start-experimental"];
            [self experimentalChanged:_experimentalSwitch];
            [self primaryAction];
        } else {
            [self setNotice:@"macOS 工作区已经在运行" success:YES];
        }
    } else if ([action isEqualToString:@"stop"]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else if ([action isEqualToString:@"glassdemo"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"glassdemo"}];
    } else if ([action isEqualToString:@"terminal"] ||
               [action isEqualToString:@"vscode"] ||
               [action isEqualToString:@"activity-monitor"] ||
               [action isEqualToString:@"finder"] ||
               [action isEqualToString:@"system-settings"] ||
               [action isEqualToString:@"maps"] ||
               [action isEqualToString:@"weather"] ||
               [action isEqualToString:@"sublime"] ||
               [action isEqualToString:@"steam"] ||
               [action isEqualToString:@"amadine"] ||
               [action isEqualToString:@"word"] ||
               [action isEqualToString:@"excel"] ||
               [action isEqualToString:@"powerpoint"] ||
               [action isEqualToString:@"asphalt"]) {
        [self launchApplicationIdentifier:action];
    } else if ([action isEqualToString:@"recover"]) {
        [self recoverAction];
    } else if ([action isEqualToString:@"repair"]) {
        [self repairAction];
    } else if ([action isEqualToString:@"repair-desktop"]) {
        [self repairDesktopAction];
    } else if ([action isEqualToString:@"capture"]) {
        [self captureAction];
    } else if ([action isEqualToString:@"test-open-file"]) {
        [self performSemanticShortcutForDiagnostics:@"⌘O"];
    } else if ([action isEqualToString:@"test-quit"]) {
        // Exercise the same serialized NSMenuItem action used by macPad's
        // mirrored menu bar. This is an end-to-end quit witness, unlike a
        // signal or a direct process kill, and lets the session supervisor
        // prove Dock convergence after the application accepts termination.
        [self performSemanticShortcutForDiagnostics:@"⌘Q"];
    } else if ([action isEqualToString:@"fullscreen"]) {
        [self openFullscreenWorkspace];
    } else if ([action isEqualToString:@"enter-workspace"]) {
        [self setFullscreenWorkspaceEnabled:YES];
    } else if ([action isEqualToString:@"exit-workspace"]) {
        [self setFullscreenWorkspaceEnabled:NO];
    } else if ([action isEqualToString:@"close-window"]) {
        [self closeCurrentWindow];
    } else if ([action isEqualToString:@"screenshot-ui"]) {
        [self writeHostUISnapshot];
    } else if ([action isEqualToString:@"screenshot-automation"]) {
        [self writeHostAutomationSnapshot];
    } else if ([action isEqualToString:@"screenshot-screen"]) {
        [self writeHostScreenSnapshot];
    } else if ([action isEqualToString:@"screenshot-rendered"]) {
        [_metalView requestRenderedDrawableSnapshotToPath:
            @"/var/mobile/Library/Logs/MacWSHost-rendered.png"];
    } else if ([action isEqualToString:@"screenshot-base"]) {
        [_metalView writeBaseSurfaceSnapshotToPath:
            @"/var/mobile/Library/Logs/MacWSHost-base.png"];
    } else if ([action isEqualToString:@"screenshot-layers"]) {
        [_metalView writeWorkspaceSurfaceSnapshotsToDirectory:
            @"/var/mobile/Library/Logs/MacWSHost-layers"];
    } else if ([action isEqualToString:@"performance-snapshot"]) {
        [_metalView logPerformanceSnapshotWithReason:@"url-control"];
        [self exportPerformanceMeasurement];
    } else if ([action isEqualToString:@"performance-reset"]) {
        [self resetPerformanceMeasurementForTargetPID:0];
    } else if ([action isEqualToString:@"performance-gesture-suite"]) {
        [self runPerformanceGestureSuite];
    } else if ([action hasPrefix:@"performance-gesture-"]) {
        NSString *scenario = [action substringFromIndex:
            @"performance-gesture-".length];
        [_metalView runPerformanceGestureScenario:scenario
            completion:^(BOOL success, NSString *message) {
                MacWSLog(@"performance-url-gesture scenario=%@ success=%@ message=%@",
                         scenario, success ? @"YES" : @"NO", message);
            }];
    } else if ([action isEqualToString:@"performance-hud-off"] ||
               [action isEqualToString:@"performance-hud-compact"] ||
               [action isEqualToString:@"performance-hud-full"]) {
        _performanceHUDControl.selectedSegmentIndex =
            [action isEqualToString:@"performance-hud-full"] ? 2 :
            ([action isEqualToString:@"performance-hud-compact"] ? 1 : 0);
        [self performanceHUDChanged:_performanceHUDControl];
    } else if ([action isEqualToString:@"system-performance-hud-on"] ||
               [action isEqualToString:@"system-performance-hud-off"]) {
        _systemPerformanceHUDSwitch.on =
            [action isEqualToString:@"system-performance-hud-on"];
        [self systemPerformanceHUDChanged:_systemPerformanceHUDSwitch];
    } else if ([action isEqualToString:@"hide-controls"]) {
        [self hideControls];
    } else if ([action isEqualToString:@"show-controls"]) {
        [self showControls];
    }
}

- (void)resetPerformanceMeasurementForTargetPID:(int32_t)targetPID {
    int32_t previousPID = _metalView.targetPID;
    if (targetPID > 1) {
        // A benchmark has already proved the exact process and its AppKit
        // input endpoint before requesting a measurement generation.  Bind
        // the Host monitor to that explicit identity instead of whichever
        // ordinary desktop window happened to be foremost when the URL was
        // delivered.  Runtime-confirmed on 2026-08-29: an otherwise healthy
        // Stray run requested pid=68082 while stale VSCode pid=54057 was the
        // passive catalog target, invalidating the whole scored interval.
        if (!MacWSAppInputEndpointReady(targetPID)) {
            MacWSLog(@"performance-profile-target-rejected requested=%d "
                     "previous=%d reason=input-endpoint-missing",
                     targetPID, previousPID);
            return;
        }
        _metalView.targetPID = targetPID;
    }
    [_metalView.performanceMonitor resetWithReason:
        targetPID > 1 ? @"url-control-explicit-pid" : @"url-control"];
    // Give the external regression runner a fresh focus witness for this
    // exact reset.  Reading the last historical catalog message can bind a
    // new run to an application that was frontmost minutes earlier.
    MacWSLog(@"performance-profile-target pid=%d window=%u mode=%lu "
             "requested=%d previous=%d",
             _metalView.targetPID, _metalView.targetWindowID,
             (unsigned long)_streamMode, targetPID, previousPID);
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    _statusLabel.text = [@"画面：" stringByAppendingString:status];
    if (view.hasDirectSurfaceFrame && !view.isMacWSInputEnabled) {
        MacWSLog(@"display-stream first-frame revalidate-input mode=%lu target=%d status=%@",
                 (unsigned long)_streamMode, view.targetPID, status);
        [self refreshStatus];
    }
}

- (void)openInitialFinderBrowserWindowIfNeeded:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingFinderWindowPID;
    if (ownerPID <= 1 || _finderMenuRequestInFlight) return;
    MacWSStreamWindow *seed = nil;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID == ownerPID) {
            seed = window;
            break;
        }
    }
    if (!seed) return;
    if (_pendingFinderMenuAttempts >= 8) {
        _pendingFinderWindowPID = 0;
        [self setNotice:@"Finder 已启动；菜单在限定时间内尚未就绪，可稍后从窗口菜单选择“文件 → 新建 Finder 窗口”。"
                 success:NO];
        return;
    }
    _pendingFinderMenuAttempts++;
    _finderMenuRequestInFlight = YES;
    MacWSLog(@"finder-browser menu-attempt=%lu pid=%d seed-window=%u",
             (unsigned long)_pendingFinderMenuAttempts, ownerPID,
             seed.descriptor.windowID);
    [_menuClient requestSnapshotForPID:ownerPID
        windowID:seed.descriptor.windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            self->_finderMenuRequestInFlight = NO;
            if (self->_pendingFinderWindowPID != ownerPID) return;
            if (!snapshot || error) {
                MacWSLog(@"finder-browser menu-not-ready attempt=%lu error=%@",
                         (unsigned long)self->_pendingFinderMenuAttempts,
                         error.localizedDescription ?: @"无菜单快照");
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *fileMenu = nil;
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == 1 ||
                    [root.title localizedCaseInsensitiveContainsString:@"file"] ||
                    [root.title containsString:@"文件"]) {
                    fileMenu = root;
                    break;
                }
            }
            if (!fileMenu) {
                MacWSLog(@"finder-browser file-menu-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *newWindow = nil;
            for (MacWSMenuItem *item in
                    [snapshot childrenOfItemID:fileMenu.itemID]) {
                BOOL named = [item.title
                    localizedCaseInsensitiveContainsString:@"new finder window"] ||
                    [item.title containsString:@"新建 Finder 窗口"];
                BOOL commandN = [item.shortcut hasSuffix:@"⌘N"] ||
                    [item.shortcut isEqualToString:@"⌘N"];
                if ((named || commandN) &&
                    (item.flags & MacWSMenuNodeEnabled) &&
                    !(item.flags & MacWSMenuNodeHasSubmenu)) {
                    newWindow = item;
                    break;
                }
            }
            if (!newWindow) {
                MacWSLog(@"finder-browser new-window-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            [self->_menuClient performItem:newWindow inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    if (status == MacWSMenuStatusOK) {
                        self->_pendingFinderWindowPID = 0;
                        self->_pendingApplicationWindowPID = ownerPID;
                        self->_pendingApplicationIdentifier = @"finder";
                        self->_pendingApplicationWindowAttempts = 0;
                        self->_pendingApplicationWindowRetryScheduled = NO;
                        [self setNotice:@"Finder 浏览窗口已创建，可从“打开 macOS 窗口”进入。"
                                 success:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                      500 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            [self->_metalView requestStreamWindowList];
                        });
                    } else {
                        MacWSLog(@"finder-browser action-not-ready attempt=%lu status=%u error=%@",
                                 (unsigned long)self->_pendingFinderMenuAttempts,
                                 (unsigned)status,
                                 actionError.localizedDescription ?: @"无错误描述");
                        [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                    }
                }];
        }];
}

- (void)scheduleFinderBrowserMenuRetryForPID:(int32_t)ownerPID {
    if (_pendingFinderWindowPID != ownerPID || ownerPID <= 1) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_pendingFinderWindowPID != ownerPID) return;
        [self openInitialFinderBrowserWindowIfNeeded:self->_streamWindows ?: @[]];
    });
}

- (void)schedulePendingApplicationWindowRetry {
    if (_pendingApplicationWindowPID <= 1 ||
        _pendingApplicationWindowRetryScheduled ||
        _pendingApplicationWindowAttempts >= 20) return;
    _pendingApplicationWindowRetryScheduled = YES;
    _pendingApplicationWindowAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_pendingApplicationWindowRetryScheduled = NO;
        if (self->_pendingApplicationWindowPID <= 1) return;
        [self->_metalView requestStreamWindowList];
        [self schedulePendingApplicationWindowRetry];
    });
}

- (void)openPendingApplicationWindowFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingApplicationWindowPID;
    if (ownerPID <= 1) return;
    MacWSStreamWindow *target = nil;
    NSUInteger targetScore = 0;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID != ownerPID) continue;
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        // Sheets and app-modal panels are transported as overlays of their
        // presenting logical window. They must never own an iPadOS Scene.
        if (flags & MacWSStreamWindowTransient) continue;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 8 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 4 : 0) |
            ((flags & MacWSStreamWindowVisible) ? 2 : 0) |
            ((flags & MacWSStreamWindowTransient) ? 0 : 1);
        CGFloat area = window.descriptor.logicalWidth *
                       window.descriptor.logicalHeight;
        CGFloat targetArea = target ? target.descriptor.logicalWidth *
                                      target.descriptor.logicalHeight : 0.0;
        if (!target || score > targetScore ||
            (score == targetScore && area > targetArea)) {
            target = window;
            targetScore = score;
        }
    }
    if (!target) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    // Catalyst and ExtensionKit can publish a short-lived black bootstrap
    // NSWindow before their real scene/content window.  Wait for the best
    // candidate identity to remain stable for 500 ms; if focus or the window
    // number changes, restart the interval.  This is generic catalog
    // stabilization and does not special-case Maps or Settings titles.
    CFTimeInterval now = CACurrentMediaTime();
    if (_pendingApplicationCandidateWindowID != target.descriptor.windowID) {
        _pendingApplicationCandidateWindowID = target.descriptor.windowID;
        _pendingApplicationCandidateSince = now;
        MacWSLog(@"launch-auto-window candidate app=%@ pid=%d window=%u score=%lu state=new",
                 _pendingApplicationIdentifier ?: @"macOS app", ownerPID,
                 target.descriptor.windowID, (unsigned long)targetScore);
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    if (now - _pendingApplicationCandidateSince < 0.5) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    NSString *identifier = _pendingApplicationIdentifier ?: @"macOS app";
    _pendingApplicationWindowPID = 0;
    _pendingApplicationIdentifier = nil;
    _pendingApplicationWindowAttempts = 0;
    _pendingApplicationWindowRetryScheduled = NO;
    _pendingApplicationCandidateWindowID = 0;
    _pendingApplicationCandidateSince = 0;
    NSString *title = target.title.length ? target.title : identifier;
    MacWSLog(@"launch-auto-window app=%@ pid=%d window=%u group=%u",
             identifier, ownerPID, target.descriptor.windowID,
             target.descriptor.logicalGroupID);
    NSString *targetIdentity = MacWSWindowIdentity(
        target.descriptor.ownerPID, target.descriptor.windowID,
        target.descriptor.logicalGroupID);
    if (!MacWSObservedWindowIdentities)
        MacWSObservedWindowIdentities = [NSMutableSet set];
    if (targetIdentity) [MacWSObservedWindowIdentities addObject:targetIdentity];
    if (_streamMode == MacWSStreamModeFullscreen &&
        _bootstrapWindowReplacementPending) {
        // This is the first-launch placeholder rather than an intentional
        // fullscreen desktop entered from an AppKit window.  Replace the
        // placeholder in place, matching the startup contract documented in
        // applyStatus:, instead of retaining a black workspace Scene.
        _bootstrapWindowReplacementPending = NO;
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        MacWSLog(@"launch-auto-window replaced-bootstrap app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_streamMode == MacWSStreamModeFullscreen) {
        // The fullscreen Scene already presents WindowServer's complete
        // desktop. Turning it into a per-window stream here both crops that
        // desktop and asks UIKit to create/restore a windowed Scene. Keep the
        // workspace identity intact and activate the exact catalog window in
        // place.  Merely waiting for the focused flag left newly launched
        // Catalyst/AppKit applications behind the previous frontmost app, so
        // both pixels and AppInput continued to target the old process.
        // ActivateTarget uses the window ID + owner PID already published by
        // DisplayStream; it neither creates a UIKit Scene nor starts another
        // application generation.
        [self activateMacWindow:target];
        [self setNotice:[NSString stringWithFormat:
            @"%@ 已在当前全屏工作区中打开。", identifier] success:YES];
        MacWSLog(@"launch-auto-window activated-fullscreen app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_windowID == 0) {
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        return;
    }
    MacWSRequestNewScene(self.view.window.windowScene,
        target.descriptor.windowID, target.descriptor.ownerPID,
        target.descriptor.logicalGroupID,
        CGSizeMake(target.descriptor.logicalWidth,
                   target.descriptor.logicalHeight),
        CGSizeMake(target.descriptor.minimumLogicalWidth,
                   target.descriptor.minimumLogicalHeight),
        (target.descriptor.flags & MacWSStreamWindowResizable) != 0,
        title, ^(NSError *error) {
            if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                error.code == 2) {
                [self openWindowInCurrentScene:target
                    reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开。"];
            } else {
                [self setNotice:error.localizedDescription success:NO];
            }
        });
}

- (BOOL)isWindowDiscoveryCoordinator {
    UIScene *candidate = self.view.window.windowScene;
    if (!candidate || candidate.activationState !=
            UISceneActivationStateForegroundActive) return NO;
    NSString *candidateID = candidate.session.persistentIdentifier;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene == candidate || scene.activationState !=
                UISceneActivationStateForegroundActive) continue;
        NSString *identifier = scene.session.persistentIdentifier;
        if ([identifier compare:candidateID] == NSOrderedAscending) return NO;
    }
    return YES;
}

- (BOOL)hasForegroundFullscreenWorkspace {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
            .rootViewController;
        if ([root isKindOfClass:MacWSViewController.class] &&
            ((MacWSViewController *)root)->_streamMode ==
                MacWSStreamModeFullscreen)
            return YES;
    }
    return NO;
}

- (void)openNewMacWindowsFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    if (!MacWSPendingWindowSceneIdentities)
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *current =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in windows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if ((descriptor.flags & MacWSStreamWindowVisible) == 0) continue;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (identity) current[identity] = window;
    }
    if ([self hasForegroundFullscreenWorkspace]) {
        // New AppKit windows are already visible in the desktop stream. They
        // must not become additional iPadOS Scenes until every foreground
        // workspace has returned to per-window mode. This must be a global
        // Scene invariant: a second foreground windowed controller also
        // receives the same catalog and used to create the unwanted Stage
        // Manager window even though the initiating controller was fullscreen.
        if (!MacWSObservedWindowIdentities)
            MacWSObservedWindowIdentities = [NSMutableSet set];
        // Dock and other macOS-native launch owners call hostd directly, so
        // they do not receive the Control Center's pending-PID callback. The
        // DisplayStream catalog is the common authoritative boundary for
        // every launch source. Activate the best newly published, ordinary
        // window in the existing desktop while retaining the one fullscreen
        // iPadOS Scene. Pending Control Center launches add their identity
        // before reaching this branch and therefore remain exactly-once.
        MacWSStreamWindow *newTarget = nil;
        NSUInteger newTargetScore = 0;
        for (NSString *identity in current) {
            if ([MacWSObservedWindowIdentities containsObject:identity])
                continue;
            MacWSStreamWindow *window = current[identity];
            MacWSStreamWindowFlags flags = window.descriptor.flags;
            if (window.descriptor.ownerPID <= 1 ||
                (flags & MacWSStreamWindowTransient) != 0) continue;
            NSUInteger score =
                ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
                ((flags & MacWSStreamWindowVisible) ? 2 : 0) | 1;
            if (!newTarget || score > newTargetScore) {
                newTarget = window;
                newTargetScore = score;
            }
        }
        [MacWSObservedWindowIdentities setSet:
            [NSSet setWithArray:current.allKeys]];
        [MacWSPendingWindowSceneIdentities removeAllObjects];
        BOOL changesInputOwner = newTarget &&
            newTarget.descriptor.ownerPID != _metalView.targetPID;
        BOOL isFocusedWindow = newTarget &&
            (newTarget.descriptor.flags & MacWSStreamWindowFocused) != 0;
        if (newTarget && (changesInputOwner || isFocusedWindow)) {
            [self activateMacWindow:newTarget];
            MacWSLog(@"window-auto-scene activated-fullscreen-catalog pid=%d window=%u group=%u score=%lu",
                     newTarget.descriptor.ownerPID,
                     newTarget.descriptor.windowID,
                     newTarget.descriptor.logicalGroupID,
                     (unsigned long)newTargetScore);
        } else if (newTarget) {
            // Runtime-confirmed with Stray pid=37813: its focused FCocoaWindow
            // 410 was followed by non-focused window 417 (score 3), which was
            // retired 571 ms later.  Activating every same-process catalog
            // edge replaced inputd's valid key target with that temporary
            // window, so AppInputBridge later rejected W as
            // target-window-closed.  A non-focused window from the already
            // active owner is observational only; pointer hit-testing still
            // reaches it, while a real focused replacement takes the branch
            // above and updates keyboard ownership.
            MacWSLog(@"window-auto-scene observed-same-owner-nonfocused pid=%d window=%u group=%u score=%lu activation=SKIPPED",
                     newTarget.descriptor.ownerPID,
                     newTarget.descriptor.windowID,
                     newTarget.descriptor.logicalGroupID,
                     (unsigned long)newTargetScore);
        }
        return;
    }
    if (![self isWindowDiscoveryCoordinator]) return;
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [NSMutableSet setWithArray:current.allKeys];
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
        return;
    }

    NSMutableSet<NSString *> *occupied = [NSMutableSet set];
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions) {
        NSUserActivity *activity = MacWSSceneBindings[
            session.persistentIdentifier] ?:
            MacWSPersistedSceneActivity(session.persistentIdentifier) ?:
            session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        int32_t ownerPID = 0;
        uint32_t windowID = 0, groupID = 0;
        NSString *identity = MacWSSceneOwnedWindowFields(
            info, &ownerPID, &windowID, &groupID)
            ? MacWSWindowIdentity(ownerPID, windowID, groupID) : nil;
        if (identity) [occupied addObject:identity];
    }

    NSMutableArray<MacWSStreamWindow *> *newWindows = [NSMutableArray array];
    for (NSString *identity in current) {
        if ([MacWSObservedWindowIdentities containsObject:identity] ||
            [MacWSPendingWindowSceneIdentities containsObject:identity] ||
            [occupied containsObject:identity]) continue;
        MacWSStreamWindow *window = current[identity];
        BOOL relevantOwner = _windowOwnerPID > 1 &&
            window.descriptor.ownerPID == _windowOwnerPID;
        BOOL focused = (window.descriptor.flags & MacWSStreamWindowFocused) != 0;
        if (relevantOwner || focused) [newWindows addObject:window];
    }
    [MacWSObservedWindowIdentities setSet:[NSSet setWithArray:current.allKeys]];

    // A user gesture normally creates one native window. Bound a pathological
    // application burst so one catalog invalidation cannot flood FrontBoard.
    NSUInteger limit = MIN(newWindows.count, 3);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = newWindows[index];
        NSString *identity = MacWSWindowIdentity(window.descriptor.ownerPID,
            window.descriptor.windowID, window.descriptor.logicalGroupID);
        if (!identity) continue;
        [MacWSPendingWindowSceneIdentities addObject:identity];
        // AppKit dialogs can briefly appear as a layer-0 catalog window and
        // then become the base window's transient layer on the next commit.
        // Runtime-confirmed with Terminal's Low Disk Space alert: requesting
        // a Scene on the first edge created both an exact iPad window and the
        // correct in-window overlay. Require the identity to remain a real
        // visible catalog entry after one short ordering interval. Ordinary
        // new windows remain in _streamWindows; alerts disappear from it when
        // displayd's real CGWindow layer reconciliation runs.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSStreamWindow *stableWindow = nil;
            for (MacWSStreamWindow *candidate in self->_streamWindows) {
                NSString *candidateIdentity = MacWSWindowIdentity(
                    candidate.descriptor.ownerPID,
                    candidate.descriptor.windowID,
                    candidate.descriptor.logicalGroupID);
                if ([candidateIdentity isEqualToString:identity] &&
                    (candidate.descriptor.flags & MacWSStreamWindowVisible)) {
                    stableWindow = candidate;
                    break;
                }
            }
            if (!stableWindow) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                MacWSLog(@"window-auto-scene cancelled identity=%@ reason=transient",
                         identity);
                return;
            }
            if ([self hasForegroundFullscreenWorkspace]) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                if (!MacWSObservedWindowIdentities)
                    MacWSObservedWindowIdentities = [NSMutableSet set];
                [MacWSObservedWindowIdentities addObject:identity];
                [self activateMacWindow:stableWindow];
                MacWSLog(@"window-auto-scene retained-fullscreen identity=%@ pid=%d window=%u",
                         identity, stableWindow.descriptor.ownerPID,
                         stableWindow.descriptor.windowID);
                return;
            }
            NSString *title = stableWindow.title.length
                ? stableWindow.title : @"macOS Window";
            MacWSLog(@"window-auto-scene identity=%@ title=%@ stable-ms=250",
                     identity, title);
            MacWSRequestNewScene(self.view.window.windowScene,
                stableWindow.descriptor.windowID,
                stableWindow.descriptor.ownerPID,
                stableWindow.descriptor.logicalGroupID,
                CGSizeMake(stableWindow.descriptor.logicalWidth,
                           stableWindow.descriptor.logicalHeight),
                CGSizeMake(stableWindow.descriptor.minimumLogicalWidth,
                           stableWindow.descriptor.minimumLogicalHeight),
                (stableWindow.descriptor.flags & MacWSStreamWindowResizable) != 0,
                title, ^(NSError *error) {
                    [MacWSPendingWindowSceneIdentities removeObject:identity];
                    [MacWSObservedWindowIdentities removeObject:identity];
                    [self setNotice:error.localizedDescription success:NO];
                });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [MacWSPendingWindowSceneIdentities removeObject:identity];
        });
    }
}

- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)view;
    _streamWindows = [windows copy];
    if (_streamMode == MacWSStreamModeFullscreen) {
        NSMutableSet<NSNumber *> *eligiblePIDs = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags flags = descriptor.flags;
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            BOOL ordinaryAuthority =
                (flags & MacWSStreamWindowVisible) != 0 &&
                (flags & MacWSStreamWindowOnScreen) != 0;
            BOOL focusedFullscreenCanvas =
                (flags & fullscreenAuthority) == fullscreenAuthority;
            if (descriptor.ownerPID > 1 &&
                MacWSAppInputEndpointReady(descriptor.ownerPID) &&
                (ordinaryAuthority || focusedFullscreenCanvas)) {
                [eligiblePIDs addObject:@(descriptor.ownerPID)];
            }
        }
        int32_t visualPID =
            [_metalView frontmostInputApplicationPIDAmongPIDs:eligiblePIDs];
        MacWSStreamWindow *frontmost = nil;
        for (MacWSStreamWindow *window in windows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags flags = descriptor.flags;
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            BOOL ordinaryAuthority =
                (flags & MacWSStreamWindowVisible) != 0 &&
                (flags & MacWSStreamWindowOnScreen) != 0;
            BOOL focusedFullscreenCanvas =
                (flags & fullscreenAuthority) == fullscreenAuthority;
            if (descriptor.ownerPID <= 1 ||
                !MacWSAppInputEndpointReady(descriptor.ownerPID) ||
                (!ordinaryAuthority && !focusedFullscreenCanvas)) continue;
            if (descriptor.ownerPID != visualPID) continue;
            // The compositor graph is already the exact presentation order
            // Host draws. Do not prefer the process-local Focused bit here:
            // runtime logs from
            // 1786551260-1786551560 captured Terminal, Finder, Excel and Code
            // concurrently publishing stale focused state.  The former
            // passive-catalog handler reacted by activating each reporter in
            // turn, reordered the real desktop, retired/restarted its exact
            // capture layers and visibly flashed while the pointer moved.
            frontmost = window;
            break;
        }
        int32_t previousPID = _metalView.targetPID;
        int32_t catalogFallbackPID = visualPID;
        BOOL retainedPreviousTarget =
            visualPID != previousPID && previousPID > 1 &&
            MacWSAppInputEndpointReady(previousPID) &&
            ![eligiblePIDs containsObject:@(previousPID)];
        if (retainedPreviousTarget) {
            // A fullscreen Metal application may stop publishing its AppKit
            // catalog window while its process-local input endpoint and the
            // full-display stream remain live.  The next ordinary overlay in
            // paint order (usually Terminal) is not evidence of a foreground
            // change. Explicit activation and pointer hit-testing already set
            // targetPID at their user-action boundaries, so keep that live
            // target until it exits or a real user action selects another.
            // Runtime-confirmed with Stray pid=69410: layer 661 retired at
            // 1787255929.503, then the old callback incorrectly selected
            // Terminal pid=15404 at 1787255930.463 even though Stray's input
            // socket and display presentation continued.
            visualPID = previousPID;
            frontmost = nil;
            if (_fullscreenCatalogRetainedInputPID != previousPID) {
                _fullscreenCatalogRetainedInputPID = previousPID;
                MacWSLog(@"fullscreen-input-target retained-live-endpoint pid=%d rejected-catalog-fallback-pid=%d",
                         previousPID, catalogFallbackPID);
            }
        } else {
            _fullscreenCatalogRetainedInputPID = 0;
        }
        MacWSStreamWindow *target = frontmost;
        int32_t targetPID = visualPID;
        if (target) {
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            if ((target.descriptor.flags & fullscreenAuthority) ==
                    fullscreenAuthority) {
                [_metalView noteValidatedFullscreenCanvasForPID:
                    target.descriptor.ownerPID
                                                       windowID:
                    target.descriptor.windowID];
            }
        }
        if (targetPID != previousPID) {
            _metalView.targetPID = targetPID;
            if (_fullscreenActivatedInputOwnerPID != targetPID) {
                _fullscreenActivatedInputWindowID = 0;
                _fullscreenActivatedInputOwnerPID = 0;
            }
            MacWSLog(@"fullscreen-input-target pid=%d window=%u source=%@ title=%@",
                     targetPID, target ? target.descriptor.windowID : 0,
                     target ? @"frontmost-presented-layer" :
                              @"system-point-hit-test",
                     target.title ?: @"");
            // Catalog reception is observational.  Explicit Control Center,
            // Dock/new-window, click and menu operations already call
            // activateMacWindow: at their user-action boundary.  Mutating
            // WindowServer ordering from this callback creates a feedback
            // loop (activation -> catalog -> activation) and makes a capture
            // transport bug look like application flicker.
            [self refreshStatus];
        }

        // An explicit activation carries an exact NSWindow number into
        // inputd's cached keyboard target.  If that native window is later
        // removed while its application remains the live fullscreen owner,
        // follow the best remaining ordinary window from the authoritative
        // catalog.  This is a lifecycle repair, not passive focus
        // reconciliation: it runs only after the exact activated identity is
        // absent, so it cannot create activation -> catalog feedback on an
        // otherwise stable desktop.
        if (_fullscreenActivatedInputWindowID != 0 &&
            _fullscreenActivatedInputOwnerPID == _metalView.targetPID) {
            BOOL activatedWindowPresent = NO;
            MacWSStreamWindow *replacement = nil;
            NSUInteger replacementScore = 0;
            CGFloat replacementArea = 0.0;
            for (MacWSStreamWindow *window in windows) {
                MacWSStreamWindowDescriptor descriptor = window.descriptor;
                if (descriptor.ownerPID !=
                    _fullscreenActivatedInputOwnerPID) continue;
                if (descriptor.windowID ==
                    _fullscreenActivatedInputWindowID) {
                    activatedWindowPresent = YES;
                    break;
                }
                MacWSStreamWindowFlags flags = descriptor.flags;
                if (descriptor.windowID == 0 ||
                    (flags & MacWSStreamWindowTransient) != 0 ||
                    (flags & MacWSStreamWindowVisible) == 0 ||
                    (flags & MacWSStreamWindowOnScreen) == 0) continue;
                NSUInteger score =
                    ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
                    ((flags & MacWSStreamWindowOnScreen) ? 2 : 0) | 1;
                CGFloat area = descriptor.logicalWidth *
                               descriptor.logicalHeight;
                if (!replacement || score > replacementScore ||
                    (score == replacementScore && area > replacementArea)) {
                    replacement = window;
                    replacementScore = score;
                    replacementArea = area;
                }
            }
            if (!activatedWindowPresent && replacement) {
                uint32_t retiredWindowID =
                    _fullscreenActivatedInputWindowID;
                [self activateMacWindow:replacement];
                MacWSLog(@"fullscreen-input-window-follow pid=%d old=%u new=%u score=%lu reason=activated-window-absent",
                         replacement.descriptor.ownerPID, retiredWindowID,
                         replacement.descriptor.windowID,
                         (unsigned long)replacementScore);
            }
        }
    }
    // Establish the first complete catalog as a baseline before an explicit
    // launch transaction consumes it. This prevents restoring Host from
    // opening every pre-existing macOS window at once; subsequent identities
    // are the actual native windows created after Host became live.
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            NSString *identity = MacWSWindowIdentity(
                window.descriptor.ownerPID, window.descriptor.windowID,
                window.descriptor.logicalGroupID);
            if (identity) [MacWSObservedWindowIdentities addObject:identity];
        }
    }
    [self openInitialFinderBrowserWindowIfNeeded:windows];
    [self openPendingApplicationWindowFromCatalog:windows];
    [self openNewMacWindowsFromCatalog:windows];
    if (_windowID != 0) {
        MacWSStreamWindow *exactWindow = nil;
        MacWSStreamWindow *groupReplacement = nil;
        for (MacWSStreamWindow *window in windows) {
            if (window.descriptor.windowID == _windowID) {
                exactWindow = window;
            } else if (_windowGroupID != 0 &&
                       window.descriptor.ownerPID == _windowOwnerPID &&
                       window.descriptor.logicalGroupID == _windowGroupID) {
                MacWSStreamWindowFlags flags = window.descriptor.flags;
                MacWSStreamWindowFlags oldFlags =
                    groupReplacement ? groupReplacement.descriptor.flags : 0;
                NSUInteger score =
                    ((flags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((flags & MacWSStreamWindowOnScreen) ? 1 : 0);
                NSUInteger oldScore =
                    ((oldFlags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((oldFlags & MacWSStreamWindowOnScreen) ? 1 : 0);
                if (!groupReplacement || score > oldScore)
                    groupReplacement = window;
            }
        }
        // CGWindowListOptionAll intentionally retains Terminal's inactive tab
        // members. Selecting a tab can therefore leave the old exact ID in the
        // catalog even though a focused/on-screen member of the same native
        // NSWindowTabGroup is now the only visible representation. Resolve the
        // logical group by real screen state before falling back to exact ID.
        BOOL exactOnScreen = exactWindow &&
            (exactWindow.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        BOOL replacementFocused = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowFocused) != 0;
        BOOL replacementOnScreen = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        MacWSStreamWindow *resolvedWindow = exactWindow;
        if (groupReplacement && (replacementFocused ||
                (!exactOnScreen && replacementOnScreen)))
            resolvedWindow = groupReplacement;
        if (!resolvedWindow) resolvedWindow = groupReplacement;
        if (resolvedWindow) {
            _targetWindowObservedInCatalog = YES;
            _targetWindowMissingCheckPending = NO;
            _targetWindowMissingSerial++;
            uint32_t resolvedID = resolvedWindow.descriptor.windowID;
            _windowOwnerPID = resolvedWindow.descriptor.ownerPID;
            _windowGroupID = resolvedWindow.descriptor.logicalGroupID;
            _windowMinimumSize = CGSizeMake(
                resolvedWindow.descriptor.minimumLogicalWidth,
                resolvedWindow.descriptor.minimumLogicalHeight);
            _windowPreferredSize = CGSizeMake(
                resolvedWindow.descriptor.logicalWidth,
                resolvedWindow.descriptor.logicalHeight);
            _windowResizable =
                (resolvedWindow.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _metalView.minimumLogicalSize = _windowMinimumSize;
            _metalView.targetWindowResizable = _windowResizable;
            if (resolvedID != _windowID) {
                uint32_t oldID = _windowID;
                [_metalView suspendStream];
                _windowID = resolvedID;
                _metalView.targetPID = _windowOwnerPID;
                [_metalView configureStreamMode:MacWSStreamModeWindow
                                        windowID:_windowID];
                self.view.window.windowScene.title = resolvedWindow.title.length
                    ? resolvedWindow.title
                    : [NSString stringWithFormat:@"MacWS Window %u", _windowID];
                MacWSLog(@"window-identity-follow owner=%d group=%u old=%u new=%u",
                         _windowOwnerPID, _windowGroupID, oldID, _windowID);
                MacWSRememberSceneBinding(self.view.window.windowScene.session,
                                          [self streamRestorationActivity]);
            }
        } else if (_targetWindowObservedInCatalog &&
                   !_targetWindowMissingCheckPending &&
                   !_sceneDestructionRequested) {
            // The catalog is authoritative, but one transient refresh can
            // occur while AppKit replaces a tab-group member. Re-query once
            // and require the exact ID and its logical group to remain absent
            // for a bounded interval before removing the corresponding Scene.
            _targetWindowMissingCheckPending = YES;
            uint64_t serial = ++_targetWindowMissingSerial;
            uint32_t expectedWindowID = _windowID;
            uint32_t expectedGroupID = _windowGroupID;
            int32_t expectedOwnerPID = _windowOwnerPID;
            [_metalView requestStreamWindowList];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         650 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (serial != self->_targetWindowMissingSerial ||
                    !self->_targetWindowMissingCheckPending ||
                    self->_sceneDestructionRequested ||
                    self->_windowID != expectedWindowID) return;
                BOOL present = NO;
                for (MacWSStreamWindow *candidate in self->_streamWindows) {
                    if (candidate.descriptor.windowID == expectedWindowID ||
                        (expectedGroupID != 0 &&
                         candidate.descriptor.ownerPID == expectedOwnerPID &&
                         candidate.descriptor.logicalGroupID == expectedGroupID)) {
                        present = YES;
                        break;
                    }
                }
                self->_targetWindowMissingCheckPending = NO;
                if (present) return;
                UISceneSession *session = self.view.window.windowScene.session;
                NSString *identifier = session.persistentIdentifier;
                if (!session || !identifier.length) return;
                if (!MacWSSceneSessionsPreservingMacWindow)
                    MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
                if (!MacWSSceneCloseRequestsSent)
                    MacWSSceneCloseRequestsSent = [NSMutableSet set];
                [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
                [MacWSSceneCloseRequestsSent addObject:identifier];
                [MacWSSceneBindings removeObjectForKey:identifier];
                MacWSSetPersistedSceneBinding(identifier, nil);
                self->_sceneDestructionRequested = YES;
                MacWSLog(@"runtime-confirmed mac-window-removed id=%@ owner=%d window=%u group=%u catalog-count=%lu",
                         identifier, expectedOwnerPID, expectedWindowID,
                         expectedGroupID,
                         (unsigned long)self->_streamWindows.count);
                [UIApplication.sharedApplication
                    requestSceneSessionDestruction:session options:nil
                    errorHandler:^(NSError *error) {
                        self->_sceneDestructionRequested = NO;
                        [MacWSSceneSessionsPreservingMacWindow
                            removeObject:identifier];
                        [MacWSSceneCloseRequestsSent removeObject:identifier];
                        MacWSLog(@"mac-window-removed scene-destruction failed id=%@ error=%@",
                                 identifier, error);
                    }];
            });
        }
    }
    NSUInteger logicalWindowCount = [self logicalWindowRepresentatives].count;
    [self setButton:_windowPickerButton
              title:logicalWindowCount
                ? [NSString stringWithFormat:@"打开 macOS 窗口 · %lu",
                   (unsigned long)logicalWindowCount]
                : @"打开 macOS 窗口"
              image:@"macwindow.on.rectangle"];
}

- (NSUserActivity *)streamRestorationActivity {
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = _windowID
        ? [NSString stringWithFormat:@"MacWS Window %u", _windowID]
        : @"MacWS Workspace";
    activity.userInfo = @{
        @"mode": @(_streamMode),
        @"window_id": @(_windowID),
        @"owner_pid": @(_windowOwnerPID),
        @"logical_group_id": @(_windowGroupID),
        @"preferred_width": @(_windowPreferredSize.width),
        @"preferred_height": @(_windowPreferredSize.height),
        @"minimum_width": @(_windowMinimumSize.width),
        @"minimum_height": @(_windowMinimumSize.height),
        @"resizable": @(_windowResizable),
        @"title": activity.title,
        @"return_window_id": @(_workspaceReturnValid
            ? _workspaceReturnWindowID : 0),
        @"return_owner_pid": @(_workspaceReturnValid
            ? _workspaceReturnOwnerPID : 0),
        @"return_logical_group_id": @(_workspaceReturnValid
            ? _workspaceReturnGroupID : 0),
        @"return_preferred_width": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.width : 0),
        @"return_preferred_height": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.height : 0),
        @"return_minimum_width": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.width : 0),
        @"return_minimum_height": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.height : 0),
        @"return_scene_width": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.width : 0),
        @"return_scene_height": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.height : 0),
        @"return_resizable": @(_workspaceReturnValid
            ? _workspaceReturnResizable : NO),
        @"return_title": _workspaceReturnValid
            ? (_workspaceReturnTitle ?: @"MacWS Window") : @"",
    };
    return activity;
}

- (void)suspendSceneStream {
    [self dismissSemanticMenu];
    [_metalView suspendStream];
}

- (void)resumeSceneStream {
    if (!(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
}

- (void)cancelBootstrapTerminal {
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
}

- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record {
    int32_t presentationTargetPID = record.targetPID;
    // Fullscreen pointer records become one hardware-style global stream in
    // routeFullscreenInputRecord:, leaving WindowServer authoritative for
    // Dock/Mission Control transforms. Scroll, magnify and rotation still
    // freeze the captured layer selected at Begin because those gestures
    // belong to one
    // application-local responder for their complete lifetime.
    if (_streamMode == MacWSStreamModeFullscreen &&
        record.kind != MacWSInputKindKeyDown &&
        record.kind != MacWSInputKindKeyUp &&
        record.kind != MacWSInputKindActivateTarget &&
        record.kind != MacWSInputKindDesktopCommand &&
        record.kind != MacWSInputKindSystemGesture) {
        if (![_metalView routeFullscreenInputRecord:&record
                              presentationTargetPID:
                                  &presentationTargetPID]) {
            record.targetPID = 0;
            record.sceneID &= UINT64_C(0x7fffffff);
            presentationTargetPID = 0;
        }
    }
    NSString *phase = @"?";
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown: phase = @"down"; break;
        case MacWSInputKindTouchMove: phase = @"move"; break;
        case MacWSInputKindTouchUp: phase = @"up"; break;
        case MacWSInputKindTouchCancel: phase = @"cancel"; break;
        case MacWSInputKindHover: phase = @"hover"; break;
        case MacWSInputKindTap: phase = @"tap"; break;
        case MacWSInputKindSecondaryTap: phase = @"secondary"; break;
        case MacWSInputKindScroll: phase = @"scroll"; break;
        case MacWSInputKindMagnify: phase = @"magnify"; break;
        case MacWSInputKindRotate: phase = @"rotate"; break;
        case MacWSInputKindDesktopCommand: phase = @"desktop-command"; break;
        case MacWSInputKindSystemGesture: phase = @"system-gesture"; break;
        case MacWSInputKindKeyDown: phase = @"key-down"; break;
        case MacWSInputKindKeyUp: phase = @"key-up"; break;
        case MacWSInputKindConfigureWindow: phase = @"configure-window"; break;
        case MacWSInputKindCloseWindow: phase = @"close-window"; break;
        case MacWSInputKindCreateInitialWindow:
            phase = @"create-initial-window"; break;
        default: break;
    }
    int sendError = 0;
    BOOL sent = MacWSSendInputRecord(&record, &sendError);
    [_metalView.performanceMonitor recordInputKind:record.kind
        sampleTime:record.timestamp targetPID:presentationTargetPID
        transportSuccess:sent];
    _inputLogSequence++;
    BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                      record.kind == MacWSInputKindHover ||
                      record.kind == MacWSInputKindScroll ||
                      record.kind == MacWSInputKindMagnify ||
                      record.kind == MacWSInputKindRotate ||
                      record.kind == MacWSInputKindSystemGesture;
    if (MacWSHostDiagnosticsEnabled() &&
        (!continuous || (_inputLogSequence % 60) == 0)) {
        MacWSLog(@"input-v5 transport=%@ errno=%d scene=%llx target=%d kind=%@ source=%u point=(%.2f,%.2f) frame=%ux%u pressure=%.3f contact=%u sample=%u seq=%llu",
                 sent ? @"sent" : @"failed", sendError, record.sceneID,
                 record.targetPID, phase, record.source, record.x, record.y,
                 record.frameWidth, record.frameHeight,
                 record.pressure, record.contactID, record.sampleSequence,
                 (unsigned long long)_inputLogSequence);
    }
    if (!sent) {
        _inputLabel.text = [NSString stringWithFormat:
            @"触控桥离线 · %@ · errno=%d", phase, sendError];
        [_metalView setMacWSInputEnabled:NO reason:@"触控桥连接已中断"];
        [self refreshStatus];
    } else if (_streamMode == MacWSStreamModeFullscreen &&
               (record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap ||
                record.kind == MacWSInputKindTouchUp)) {
        // A global click can make another real AppKit window key. Refresh the
        // catalog at two bounded settlement points so subsequent keyboard and
        // gesture records follow that owner. This is event-driven, not a
        // frame-time poll.
        for (NSNumber *delay in @[@80, @280]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         delay.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_streamMode == MacWSStreamModeFullscreen)
                    [self->_metalView requestStreamWindowList];
            });
        }
    }
}
@end

// Hardware keyboard UIPressesEvents always enter UIWindow before UIKit chooses
// a first responder. Route them at that stable public boundary while the macOS
// workspace is the active UI. The former MTKView-only pressesBegan: path had a
// responder ownership precondition even though this app intentionally moves
// first responder among the Metal view, controls, restored Scenes and a hidden
// keyboard proxy. Returning to UIKit for control-center/unsupported events
// preserves native text-field and Scene behavior, while a forwarded event is
// consumed exactly once so MTKView's responder fallback cannot duplicate it.
@interface MacWSWorkspaceWindow : UIWindow
@end

@implementation MacWSWorkspaceWindow
- (void)sendEvent:(UIEvent *)event {
    if ([event isKindOfClass:UIPressesEvent.class]) {
        UIViewController *root = self.rootViewController;
        if ([root isKindOfClass:MacWSViewController.class] &&
            [(MacWSViewController *)root
                forwardHardwarePressEvent:(UIPressesEvent *)event])
            return;
    }
    [super sendEvent:event];
}
@end

static NSUserActivity *MacWSLiveRestorationActivity(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class])
        return scene.session.stateRestorationActivity;
    UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
        .rootViewController;
    if ([root isKindOfClass:MacWSViewController.class])
        return [(MacWSViewController *)root streamRestorationActivity];
    return scene.session.stateRestorationActivity;
}

static void MacWSPruneDeadWindowSceneSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        MacWSViewController *controller = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session == session) {
                activity = MacWSLiveRestorationActivity(scene);
                if ([scene isKindOfClass:UIWindowScene.class]) {
                    UIViewController *root = ((UIWindowScene *)scene)
                        .windows.firstObject.rootViewController;
                    if ([root isKindOfClass:MacWSViewController.class])
                        controller = (MacWSViewController *)root;
                }
                break;
            }
        }
        NSDictionary *info = activity.userInfo;
        uint32_t windowID = 0;
        int32_t ownerPID = 0;
        if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL))
            continue;
        errno = 0;
        if (kill(ownerPID, 0) == 0 || errno != ESRCH) continue;
        if ([info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [controller detachMissingWorkspaceReturnOwnerPID:ownerPID
                                                     windowID:windowID]) {
            continue;
        }
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"runtime-confirmed stale-scene owner-missing id=%@ pid=%d window=%u",
                 identifier, ownerPID, windowID);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"stale-scene destruction failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static void MacWSPruneDormantWorkspaceSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        UIScene *connectedScene = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session != session) continue;
            connectedScene = scene;
            activity = MacWSLiveRestorationActivity(scene);
            break;
        }
        // FrontBoard can retain restoration metadata after its corresponding
        // scene handle has already disappeared. Public destruction returns
        // SBApplicationSupportService/2 for those metadata-only entries, so
        // leave them to UIKit's persistence cleanup and prune only live,
        // dormant workspace Scenes.
        if (!connectedScene) continue;
        NSDictionary *info = activity.userInfo;
        BOOL ownsWindow = MacWSSceneOwnedWindowFields(
            info, NULL, NULL, NULL);
        BOOL fullscreenWorkspace = MacWSSceneIsFullscreenWorkspace(info);
        if (ownsWindow || fullscreenWorkspace ||
            (connectedScene && connectedScene.activationState ==
                UISceneActivationStateForegroundActive)) continue;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"workspace-scene-prune id=%@ state=%ld",
                 identifier, (long)connectedScene.activationState);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"workspace-scene-prune failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static NSString *MacWSSceneWindowIdentity(NSUserActivity *activity) {
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0, groupID = 0;
    if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, &groupID))
        return nil;
    return MacWSWindowIdentity(ownerPID, windowID, groupID);
}

static NSInteger MacWSSceneRetentionRank(UIScene *scene) {
    switch (scene.activationState) {
        case UISceneActivationStateForegroundActive: return 0;
        case UISceneActivationStateForegroundInactive: return 1;
        case UISceneActivationStateBackground: return 2;
        case UISceneActivationStateUnattached: return 3;
    }
    return 4;
}

static void MacWSDeduplicateWindowScenes(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableDictionary<NSString *, NSMutableArray<UIScene *> *> *groups =
        [NSMutableDictionary dictionary];
    for (UIScene *scene in application.connectedScenes) {
        NSString *identity = MacWSSceneWindowIdentity(
            MacWSLiveRestorationActivity(scene));
        if (!identity) continue;
        if (!groups[identity]) groups[identity] = [NSMutableArray array];
        [groups[identity] addObject:scene];
    }
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (NSString *identity in groups) {
        NSArray<UIScene *> *duplicates = [groups[identity]
            sortedArrayUsingComparator:^NSComparisonResult(UIScene *lhs,
                                                            UIScene *rhs) {
                NSInteger leftRank = MacWSSceneRetentionRank(lhs);
                NSInteger rightRank = MacWSSceneRetentionRank(rhs);
                if (leftRank < rightRank) return NSOrderedAscending;
                if (leftRank > rightRank) return NSOrderedDescending;
                return [lhs.session.persistentIdentifier compare:
                    rhs.session.persistentIdentifier];
            }];
        if (duplicates.count <= 1) continue;
        UIScene *keeper = duplicates.firstObject;
        for (NSUInteger index = 1; index < duplicates.count; index++) {
            UISceneSession *session = duplicates[index].session;
            NSString *identifier = session.persistentIdentifier;
            if ([MacWSSceneSessionsPreservingMacWindow
                    containsObject:identifier]) continue;
            [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
            MacWSLog(@"scene-deduplicate identity=%@ keep=%@ discard=%@",
                     identity, keeper.session.persistentIdentifier,
                     identifier);
            [application requestSceneSessionDestruction:session
                options:nil errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:identifier];
                    MacWSLog(@"scene-deduplicate failed id=%@ error=%@",
                             identifier, error);
                }];
        }
    }
}

@interface MacWSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MacWSSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    NSUserActivity *activity = connectionOptions.userActivities.anyObject;
    BOOL connectionHasExactWindow =
        [activity.userInfo[@"mode"] unsignedIntValue] ==
            MacWSStreamModeWindow &&
        [activity.userInfo[@"window_id"] unsignedIntValue] != 0;
    if (!connectionHasExactWindow) {
        NSUserActivity *persisted = MacWSPersistedSceneActivity(
            session.persistentIdentifier);
        activity = persisted ?: activity ?: session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        BOOL emptyWorkspace =
            [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [info[@"return_window_id"] unsignedIntValue] == 0;
        if (emptyWorkspace) {
            activity = MacWSRecoverOrphanedWorkspaceActivity(session) ?:
                activity;
        }
    }
    MacWSStreamMode streamMode = (MacWSStreamMode)
        [activity.userInfo[@"mode"] unsignedIntValue];
    uint32_t windowID = [activity.userInfo[@"window_id"] unsignedIntValue];
    int32_t ownerPID = (int32_t)[activity.userInfo[@"owner_pid"] intValue];
    uint32_t logicalGroupID =
        [activity.userInfo[@"logical_group_id"] unsignedIntValue];
    CGSize minimumSize = CGSizeMake(
        [activity.userInfo[@"minimum_width"] doubleValue],
        [activity.userInfo[@"minimum_height"] doubleValue]);
    CGSize preferredSize = CGSizeMake(
        [activity.userInfo[@"preferred_width"] doubleValue],
        [activity.userInfo[@"preferred_height"] doubleValue]);
    BOOL resizable = [activity.userInfo[@"resizable"] boolValue];
    if (streamMode != MacWSStreamModeWindow || windowID == 0) {
        streamMode = MacWSStreamModeFullscreen;
        windowID = 0;
        ownerPID = 0;
        logicalGroupID = 0;
        minimumSize = CGSizeZero;
        preferredSize = CGSizeZero;
        resizable = NO;
    }
    NSString *shortID = session.persistentIdentifier;
    if (shortID.length > 8) shortID = [shortID substringToIndex:8];
    NSString *requestedTitle = activity.userInfo[@"title"];
    windowScene.title = requestedTitle.length ? requestedTitle :
        [NSString stringWithFormat:@"MacWS %@", shortID];
    MacWSViewController *controller = [[MacWSViewController alloc]
        initWithSceneIdentifier:session.persistentIdentifier
                     streamMode:streamMode windowID:windowID
                       ownerPID:ownerPID logicalGroupID:logicalGroupID
                    minimumSize:minimumSize
                  preferredSize:preferredSize
                      resizable:resizable];
    [controller restoreWorkspaceReturnFromActivity:activity];
    self.window = [[MacWSWorkspaceWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    // Scene restoration can reconnect directly in fullscreen mode without
    // passing through openFullscreenWorkspace. Re-assert and log UIKit's
    // authoritative status-bar/Home-Indicator policy after the real window
    // is visible so cold launch and interactive transition share the same
    // immersive postconditions.
    [controller updateImmersivePresentation];
    if (streamMode == MacWSStreamModeWindow && windowID != 0)
        MacWSRequestNativeSceneSizeWithRole(
            windowScene, preferredSize, NO);
    MacWSRememberSceneBinding(session, [controller streamRestorationActivity]);
    MacWSLog(@"scene-connected id=%@ role=%@ mode=%u window=%u",
             session.persistentIdentifier, session.role, streamMode, windowID);
    NSString *FBSSceneIdentifier = [windowScene respondsToSelector:
        @selector(_sceneIdentifier)] ? [windowScene _sceneIdentifier] : nil;
    MacWSLog(@"scene-geometry id=%@ fbs=%@ bounds=%.1fx%.1f preferred=%.1fx%.1f minimum=%.1fx%.1f resizable=%@",
             session.persistentIdentifier, FBSSceneIdentifier ?: @"missing",
             windowScene.coordinateSpace.bounds.size.width,
             windowScene.coordinateSpace.bounds.size.height,
             preferredSize.width, preferredSize.height, minimumSize.width,
             minimumSize.height, resizable ? @"YES" : @"NO");
    NSString *replacedIdentifier =
        [activity.userInfo[@"replaces_session_identifier"]
            isKindOfClass:NSString.class]
        ? activity.userInfo[@"replaces_session_identifier"] : nil;
    if (replacedIdentifier.length) {
        if (!MacWSSceneSessionsPreservingMacWindow)
            MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
        [MacWSSceneSessionsPreservingMacWindow addObject:replacedIdentifier];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UISceneSession *replacedSession = nil;
            for (UISceneSession *candidate in
                    UIApplication.sharedApplication.openSessions) {
                if ([candidate.persistentIdentifier
                        isEqualToString:replacedIdentifier]) {
                    replacedSession = candidate;
                    break;
                }
            }
            if (!replacedSession) {
                [MacWSSceneSessionsPreservingMacWindow
                    removeObject:replacedIdentifier];
                MacWSLog(@"scene-windowed-replacement old-already-gone old=%@ new=%@",
                         replacedIdentifier, session.persistentIdentifier);
                return;
            }
            MacWSSetPersistedSceneBinding(replacedIdentifier, nil);
            MacWSLog(@"scene-windowed-replacement connected old=%@ new=%@ window=%u bounds=%@",
                     replacedIdentifier, session.persistentIdentifier,
                     windowID, NSStringFromCGRect(self.window.bounds));
            [UIApplication.sharedApplication
                requestSceneSessionDestruction:replacedSession options:nil
                errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:replacedIdentifier];
                    MacWSLog(@"scene-windowed-replacement old-destruction-failed old=%@ new=%@ error=%@",
                             replacedIdentifier,
                             session.persistentIdentifier, error);
                }];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSDeduplicateWindowScenes();
        });
    }
    if (connectionOptions.URLContexts.count) {
        [controller cancelBootstrapTerminal];
        NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scene:scene openURLContexts:contexts];
        });
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    (void)scene;
    // A fullscreen macOS workspace is an interactive display session.  Keep
    // iPadOS from auto-locking while that Scene is in the foreground; once
    // locked, FrontBoard only prewarms a relaunched Host (ActivePrewarm=1)
    // and cannot reconnect its UIWindowScene until the user authenticates.
    // Restore the ordinary system policy as soon as the Scene backgrounds so
    // this does not turn a dormant Host process into a permanent wake lock.
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    [(MacWSViewController *)self.window.rootViewController resumeSceneStream];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    (void)scene;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    [controller reassertFullscreenScenePresentation];
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller restoreHardwareKeyboardFocusWithReason:@"scene-active"];
    });
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    (void)scene;
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [(MacWSViewController *)self.window.rootViewController suspendSceneStream];
}

- (void)windowScene:(UIWindowScene *)windowScene
 didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
       interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
            traitCollection:(UITraitCollection *)previousTraitCollection {
    (void)windowScene;
    (void)previousCoordinateSpace;
    (void)previousInterfaceOrientation;
    (void)previousTraitCollection;
    [(MacWSViewController *)self.window.rootViewController
        sceneGeometryDidChange];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Disconnect alone can be ordinary resource reclamation. Close only after
    // UIKit has actually removed the persistent session from openSessions.
    UISceneSession *session = scene.session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([UIApplication.sharedApplication.openSessions containsObject:session])
            return;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
            MacWSLog(@"scene-disconnect preserved id=%@ mac-window=preserved",
                     identifier);
            return;
        }
        MacWSCloseMacWindowForSceneSession(session, @"disconnect-discarded");
    });
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if ([context.URL.host isEqualToString:@"toggle-workspace"]) {
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if (controller) [controller openFullscreenWorkspace];
            break;
        }
        if ([context.URL.host isEqualToString:@"new"]) {
            uint32_t windowID = 0;
            int32_t ownerPID = 0;
            NSString *title = nil;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"window"])
                    windowID = item.value.intValue;
                else if ([item.name isEqualToString:@"pid"])
                    ownerPID = item.value.intValue;
                else if ([item.name isEqualToString:@"title"])
                    title = item.value;
            }
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if ([controller isFullscreenWorkspace] && windowID != 0 &&
                ownerPID > 1) {
                [controller activateMacWindowIDInFullscreenWorkspace:windowID
                    ownerPID:ownerPID title:title];
                break;
            }
            MacWSRequestNewScene(scene, windowID, ownerPID, 0,
                                 CGSizeZero, CGSizeZero, NO, title,
                                 ^(NSError *error) {
                if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                    error.code == 2 && windowID != 0 && ownerPID > 1) {
                    MacWSViewController *controller =
                        (MacWSViewController *)self.window.rootViewController;
                    [controller openWindowIDInCurrentScene:windowID
                        ownerPID:ownerPID logicalGroupID:0 title:title
                        reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                }
            });
            break;
        }
        if ([context.URL.host isEqualToString:@"test-input"]) {
            // Explicit transport diagnostic. Query parameters allow two-point
            // cursor A/Bs or a complete down/move/up transaction without
            // fabricating UIKit touches:
            // macwshost://test-input?kind=down&x=1194&y=834&w=2388&h=1668
            uint32_t frameWidth = 2388;
            uint32_t frameHeight = 1668;
            float x = 1194.0f;
            float y = 834.0f;
            float scrollX = 0.0f;
            float scrollY = 0.0f;
            NSString *scrollPhase = @"changed";
            NSString *requestedKind = @"hover";
            BOOL diagnosticDoubleTap = NO;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"x"]) x = item.value.floatValue;
                else if ([item.name isEqualToString:@"y"]) y = item.value.floatValue;
                else if ([item.name isEqualToString:@"w"]) frameWidth = item.value.intValue;
                else if ([item.name isEqualToString:@"h"]) frameHeight = item.value.intValue;
                else if ([item.name isEqualToString:@"dx"]) scrollX = item.value.floatValue;
                else if ([item.name isEqualToString:@"dy"]) scrollY = item.value.floatValue;
                else if ([item.name isEqualToString:@"phase"] && item.value.length)
                    scrollPhase = item.value.lowercaseString;
                else if ([item.name isEqualToString:@"kind"] && item.value.length)
                    requestedKind = item.value.lowercaseString;
            }
            if (frameWidth == 0) frameWidth = 2388;
            if (frameHeight == 0) frameHeight = 1668;
            x = fminf(fmaxf(x, 0.0f), frameWidth - 1.0f);
            y = fminf(fmaxf(y, 0.0f), frameHeight - 1.0f);
            MacWSInputRecord record = {
                .magic = MACWS_INPUT_MAGIC,
                .version = MACWS_INPUT_VERSION,
                .kind = MacWSInputKindHover,
                .sceneID = ((uint64_t)scene.session.persistentIdentifier.hash) &
                    ~MACWS_INPUT_WINDOW_SCENE_FLAG,
                .timestamp = CACurrentMediaTime(),
                .x = x,
                .y = y,
                .contactID = MACWS_INPUT_CONTACT_DIAGNOSTIC,
                .frameWidth = frameWidth,
                .frameHeight = frameHeight,
                .targetPID = 0,
                .source = MacWSInputSourceUnknown,
            };
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            uint32_t targetWindowID = (uint32_t)[[controller
                valueForKey:@"windowID"] unsignedIntValue];
            int32_t targetOwnerPID = (int32_t)[[controller
                valueForKey:@"windowOwnerPID"] intValue];
            record.targetPID = targetWindowID != 0 ? targetOwnerPID : 0;
            if (targetWindowID != 0)
                record.sceneID = MacWSInputSceneForWindow(targetWindowID, 0);
            if ([requestedKind isEqualToString:@"tap"])
                record.kind = MacWSInputKindTap;
            else if ([requestedKind isEqualToString:@"double"]) {
                // Transport-only end-to-end witness for the same two physical
                // tap records emitted by direct touch. The title bar uses the
                // native CGPostMouseEvent route, whose double-click state is
                // derived from the ordered button transitions rather than the
                // NSEvent clickCount field, so diagnostics must preserve both
                // taps instead of fabricating one clickCount=2 event.
                record.kind = MacWSInputKindTap;
                diagnosticDoubleTap = YES;
            }
            else if ([requestedKind isEqualToString:@"secondary"])
                record.kind = MacWSInputKindSecondaryTap;
            else if ([requestedKind isEqualToString:@"down"])
                record.kind = MacWSInputKindTouchDown;
            else if ([requestedKind isEqualToString:@"move"])
                record.kind = MacWSInputKindTouchMove;
            else if ([requestedKind isEqualToString:@"up"])
                record.kind = MacWSInputKindTouchUp;
            else if ([requestedKind isEqualToString:@"cancel"])
                record.kind = MacWSInputKindTouchCancel;
            else if ([requestedKind isEqualToString:@"scroll"]) {
                record.kind = MacWSInputKindScroll;
                record.pressure = scrollY;
                memcpy(&record.contactID, &scrollX, sizeof(scrollX));
                record.flags = [scrollPhase isEqualToString:@"began"]
                    ? MacWSInputFlagScrollBegan
                    : [scrollPhase isEqualToString:@"ended"]
                        ? MacWSInputFlagScrollEnded
                        : [scrollPhase isEqualToString:@"cancelled"]
                            ? MacWSInputFlagScrollCancelled
                            : MacWSInputFlagScrollChanged;
                record.source = MacWSInputSourceFinger;
            }
            // Exercise the same controller boundary as a real UIKit touch.
            // Besides transport this schedules the post-AppKit window catalog
            // refresh required when a native tab selection swaps CGWindowID.
            [controller metalView:nil emittedInput:record];
            if (diagnosticDoubleTap) {
                MacWSInputRecord secondTap = record;
                secondTap.flags |= MacWSInputFlagDoubleClick;
                secondTap.timestamp += 0.10;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    [controller metalView:nil emittedInput:secondTap];
                });
            }
            MacWSLog(@"input-v5 synthetic kind=%@ routed-through-controller scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                     requestedKind, record.sceneID, record.targetPID,
                     record.x, record.y, record.frameWidth,
                     record.frameHeight);
            break;
        }
        if ([context.URL.host isEqualToString:@"test-catalyst-drawable"]) {
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            MacWSMetalView *metalView = [controller valueForKey:@"metalView"];
            int32_t ownerPID = metalView.targetPID;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"pid"] && item.value.intValue > 1)
                    ownerPID = item.value.intValue;
            }
            NSError *error = nil;
            NSString *path = [metalView exportCatalystDrawableProbeForPID:
                ownerPID error:&error];
            MacWSLog(@"test-catalyst-drawable pid=%d path=%@ error=%@",
                     ownerPID, path ?: @"", error ?: @"nil");
            break;
        }
        NSString *host = context.URL.host ?: @"status";
        if ([host isEqualToString:@"performance-reset"]) {
            int32_t targetPID = 0;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"pid"] &&
                    item.value.intValue > 1) {
                    targetPID = item.value.intValue;
                    break;
                }
            }
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            [controller resetPerformanceMeasurementForTargetPID:targetPID];
            break;
        }
        if ([@[@"status", @"start", @"start-experimental", @"stop",
               @"glassdemo", @"terminal", @"vscode", @"activity-monitor", @"finder",
               @"system-settings", @"maps", @"weather", @"sublime", @"steam",
               @"amadine", @"word", @"excel",
               @"powerpoint", @"asphalt",
               @"recover", @"repair", @"repair-desktop", @"capture",
               @"test-open-file", @"test-quit", @"fullscreen",
               @"enter-workspace", @"exit-workspace",
               @"close-window",
               @"screenshot-ui", @"screenshot-automation",
               @"screenshot-rendered",
               @"screenshot-screen", @"screenshot-base",
               @"screenshot-layers",
               @"performance-snapshot", @"performance-reset",
               @"performance-gesture-suite", @"performance-gesture-tap",
               @"performance-gesture-tap-burst",
               @"performance-gesture-double-tap",
               @"performance-gesture-right-tap",
               @"performance-gesture-hover",
               @"performance-gesture-drag",
               @"performance-gesture-long-drag",
               @"performance-gesture-scroll",
               @"performance-gesture-scroll-momentum",
               @"performance-gesture-magnify",
               @"performance-gesture-three-up",
               @"performance-gesture-three-down",
               @"performance-gesture-three-left",
               @"performance-gesture-three-right",
               @"performance-gesture-mission-select",
               @"performance-hud-off", @"performance-hud-compact",
               @"performance-hud-full", @"system-performance-hud-on",
               @"system-performance-hud-off",
               @"hide-controls", @"show-controls"]
              containsObject:host]) {
            MacWSViewController *controller = (MacWSViewController *)self.window.rootViewController;
            [controller performURLAction:host];
            break;
        }
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    NSUserActivity *activity = [controller streamRestorationActivity];
    MacWSRememberSceneBinding(scene.session, activity);
    return activity;
}
@end

@interface MacWSAppDelegate : UIResponder <UIApplicationDelegate>
@end

extern void MacWSRunIOSClearReference(void);

@implementation MacWSAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)launchOptions;
    id<MTLDevice> nativeDevice = MTLCreateSystemDefaultDevice();
    MacWSLog(@"launched native-device=%@ supportsMultiple=%@ "
             "display-transport=IOSurface legacy-mmap=%@ frame-path=%@",
             nativeDevice.name,
             application.supportsMultipleScenes ? @"YES" : @"NO",
             MacWSLegacyFramebufferFallbackEnabled() ? @"enabled" : @"disabled",
             MacWSFramePath);
    MacWSLogMetalRegistryState();
    MacWSInstallCatalystLaunchCoordinator();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        MacWSPruneDeadWindowSceneSessions();
        MacWSPruneDormantWorkspaceSessions();
    });
    // Diagnostic-only native AGX reference.  Keeping this behind a sentinel
    // lets the established, FrontBoard-launched host provide the foreground
    // GPU context needed for a trustworthy iOS command-ABI capture without
    // changing normal host startup or its scene lifecycle.
    if (access("/var/mobile/iosclear_run", F_OK) == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MacWSLog(@"IOSCLEAR reference requested by sentinel");
            MacWSRunIOSClearReference();
        });
    }
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *configuration =
        [UISceneConfiguration configurationWithName:@"MacWS Window"
                                        sessionRole:connectingSceneSession.role];
    configuration.sceneClass = UIWindowScene.class;
    configuration.delegateClass = MacWSSceneDelegate.class;
    return configuration;
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    (void)application;
    for (UISceneSession *session in sceneSessions) {
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneBindings removeObjectForKey:identifier];
            MacWSSetPersistedSceneBinding(identifier, nil);
            MacWSLog(@"scene-discard duplicate-only id=%@ mac-window=preserved",
                     identifier);
            continue;
        }
        MacWSCloseMacWindowForSceneSession(session, @"did-discard");
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(MacWSAppDelegate.class));
    }
}
