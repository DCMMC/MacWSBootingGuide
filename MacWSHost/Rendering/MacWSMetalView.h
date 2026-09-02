#import <MetalKit/MetalKit.h>

#import "MacWSPerformanceMonitor.h"
#import "MacWSStreamClient.h"
#include "macws_host_protocol.h"

NS_ASSUME_NONNULL_BEGIN

@class MacWSMetalView;

typedef NS_ENUM(NSUInteger, MacWSHostPresentationResolution) {
    // Preserve the producer's pixels for desktop/window presentation, but
    // keep the one-pixel-per-point path for a validated fullscreen canvas.
    MacWSHostPresentationResolutionAutomatic = 0,
    MacWSHostPresentationResolutionSourceNative = 1,
    MacWSHostPresentationResolutionPerformance = 2,
};

@protocol MacWSMetalViewStatusDelegate <NSObject>
- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status;
- (void)metalView:(nullable MacWSMetalView *)view
      emittedInput:(MacWSInputRecord)record;
- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows;
@end

/// Owns DisplayStream presentation and translates UIKit touch/keyboard input
/// into the versioned MacWS input protocol. Scene lifecycle and control-center
/// policy intentionally remain in MacWSViewController.
@interface MacWSMetalView : MTKView
    <MTKViewDelegate, MacWSStreamClientDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, weak) id<MacWSMetalViewStatusDelegate> statusDelegate;
@property(nonatomic) uint64_t sceneID;
@property(nonatomic) uint32_t targetWindowID;
@property(nonatomic) int32_t targetPID;
// Exact live Dock/session input owner published by macwshostd.  This is a
// lifecycle identity, not a visual-layer hint, and remains valid when the
// final-composite graph intentionally retains static pixels.
@property(nonatomic) int32_t systemInputPID;
@property(nonatomic, getter=isMacWSInputEnabled) BOOL macWSInputEnabled;
@property(nonatomic) MacWSHostInputMode inputMode;
@property(nonatomic) MacWSHostDisplayDensity displayDensity;
@property(nonatomic) MacWSHostPresentationResolution presentationResolution;
@property(nonatomic) CGFloat fixedZoomScale;
@property(nonatomic) CGSize minimumLogicalSize;
@property(nonatomic) BOOL targetWindowResizable;
@property(nonatomic) BOOL softwareKeyboardActive;
@property(nonatomic, readonly) BOOL hasDirectSurfaceFrame;
@property(nonatomic, readonly) BOOL hasFinalCompositeFrame;
@property(nonatomic, readonly) BOOL streamServiceConnected;
@property(nonatomic, readonly) CGFloat effectiveDensityScale;
@property(nonatomic, readonly) MacWSPerformanceMonitor *performanceMonitor;
- (void)setMacWSInputEnabled:(BOOL)enabled
                      reason:(nullable NSString *)reason;
- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID;
- (void)requestStreamWindowList;
- (void)noteValidatedFullscreenCanvasForPID:(int32_t)ownerPID
                                   windowID:(uint32_t)windowID;
- (void)refreshPresentationPolicy;
- (void)resetViewportZoom;
- (void)geometryDidChange;
- (void)suspendStream;
- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers;
- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers;
- (BOOL)forwardHardwarePresses:(NSSet<UIPress *> *)presses
                       keyDown:(BOOL)keyDown;
- (BOOL)restoreHardwareKeyboardFocusWithReason:(NSString *)reason;
- (void)updatePresentationGeometry;
- (void)updatePointerVisibility;
- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated;
- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint;
- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase;
- (void)cancelActiveThreeFingerSystemGestureAtTimestamp:
    (NSTimeInterval)timestamp;
- (uint32_t)currentFrameWidth;
- (uint32_t)currentFrameHeight;
- (NSArray<NSNumber *> *)overlayKeysBackToFront;
- (int32_t)frontmostInputApplicationPIDAmongPIDs:(NSSet<NSNumber *> *)pids;
- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record
             presentationTargetPID:(int32_t *)presentationTargetPID;
- (BOOL)performanceVisiblePointForTargetPID:(int32_t)targetPID
                                      point:(CGPoint *)point;
- (void)logPerformanceSnapshotWithReason:(NSString *)reason;
- (void)requestRenderedDrawableSnapshotToPath:(NSString *)path;
- (BOOL)writeBaseSurfaceSnapshotToPath:(NSString *)path;
- (NSUInteger)writeWorkspaceSurfaceSnapshotsToDirectory:(NSString *)directory;
- (void)runPerformanceGestureScenario:(NSString *)scenario
    completion:(void (^)(BOOL success, NSString *message))completion;
- (nullable NSString *)exportCatalystDrawableProbeForPID:(int32_t)ownerPID
                                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
