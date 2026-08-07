// MacWSMetalView.h — MTKView renderer + input pipeline for one macOS window.
// Split out of the former single-file control-center application so the display
// pipeline compiles and reads as its own module.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#import "macws_host_protocol.h"
#import "MacWSStreamClient.h"

@class MacWSMetalView;

typedef NS_ENUM(uint8_t, MacWSDirectTouchState) {
    MacWSDirectTouchStateIdle = 0,
    MacWSDirectTouchStateCandidate,
    MacWSDirectTouchStateScrolling,
    MacWSDirectTouchStateLongPressArmed,
    MacWSDirectTouchStateDragging,
};

@protocol MacWSMetalViewStatusDelegate <NSObject>
- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status;
- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record;
- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows;
- (void)metalView:(MacWSMetalView *)view
 requestedWindowOverviewForCurrentApplication:(BOOL)currentApplicationOnly;
@end

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
@property(nonatomic, readonly) BOOL streamServiceConnected;
@property(nonatomic, readonly) CGFloat effectiveDensityScale;
- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason;
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
- (uint32_t)currentFrameWidth;
- (uint32_t)currentFrameHeight;
- (NSArray<NSNumber *> *)overlayKeysBackToFront;
- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record;
- (void)logPerformanceSnapshotWithReason:(NSString *)reason;
@end
