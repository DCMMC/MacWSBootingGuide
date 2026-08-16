#import <MetalKit/MetalKit.h>

#import "MacWSPerformanceMonitor.h"
#import "MacWSStreamClient.h"
#include "macws_host_protocol.h"

NS_ASSUME_NONNULL_BEGIN

@class MacWSMetalView;

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
@property(nonatomic, getter=isMacWSInputEnabled) BOOL macWSInputEnabled;
@property(nonatomic) MacWSHostInputMode inputMode;
@property(nonatomic) MacWSHostDisplayDensity displayDensity;
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
- (void)refreshPresentationPolicy;
- (void)resetViewportZoom;
- (void)geometryDidChange;
- (void)suspendStream;
- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers;
- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers;
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
- (BOOL)writeBaseSurfaceSnapshotToPath:(NSString *)path;
- (void)runPerformanceGestureScenario:(NSString *)scenario
    completion:(void (^)(BOOL success, NSString *message))completion;
- (nullable NSString *)exportCatalystDrawableProbeForPID:(int32_t)ownerPID
                                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
