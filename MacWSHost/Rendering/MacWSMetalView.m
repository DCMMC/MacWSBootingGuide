#import "MacWSMetalView.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <simd/simd.h>

#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>

#import "MacWSCatalystDrawableCompositor.h"
#import "MacWSCatalystDrawableProbe.h"
#import "MacWSCatalystDrawableReceiver.h"
#import "MacWSHostDiagnostics.h"
#import "MacWSHostRuntime.h"
#import "MacWSKeyMapping.h"
#import "MacWSMappedFrame.h"
#import "MacWSPerformanceGestureScenario.h"
#include "macws_catalyst_drawable_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

typedef NS_ENUM(uint8_t, MacWSDirectTouchState) {
    MacWSDirectTouchStateIdle = 0,
    MacWSDirectTouchStateCandidate,
    MacWSDirectTouchStateScrolling,
    MacWSDirectTouchStateLongPressArmed,
    MacWSDirectTouchStateDragging,
};

// UIKit lets a pinch/rotation recognizer begin as soon as the first two
// contacts move.  A slightly staggered third contact consequently arrives
// after that two-finger recognizer has already won, so the three-finger Dock
// pan never receives a viable sequence.  This gate keeps only the direct
// two-finger recognizers Possible for one short hardware-chord interval.  A
// real third contact begins the gate and rejects those competitors; otherwise
// it fails after the bounded interval and releases ordinary two-finger input.
@interface MacWSThreeFingerChordGateGestureRecognizer : UIGestureRecognizer
@end

@implementation MacWSThreeFingerChordGateGestureRecognizer {
    NSMutableSet<UITouch *> *_directTouches;
    NSMutableDictionary<NSValue *, NSValue *> *_initialTouchLocations;
    uint64_t _deadlineGeneration;
    BOOL _deadlineScheduled;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _directTouches = [NSMutableSet set];
        _initialTouchLocations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)reset {
    [super reset];
    [_directTouches removeAllObjects];
    [_initialTouchLocations removeAllObjects];
    _deadlineScheduled = NO;
    _deadlineGeneration++;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (self.state != UIGestureRecognizerStatePossible) return;
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeDirect) [_directTouches addObject:touch];
    }
    if (_directTouches.count >= 3) {
        self.state = UIGestureRecognizerStateBegan;
        return;
    }
    if (_directTouches.count != 2 || _deadlineScheduled) return;
    [_initialTouchLocations removeAllObjects];
    for (UITouch *touch in _directTouches) {
        _initialTouchLocations[[NSValue valueWithNonretainedObject:touch]] =
            [NSValue valueWithCGPoint:[touch locationInView:self.view]];
    }
    _deadlineScheduled = YES;
    uint64_t generation = ++_deadlineGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t)(MACWS_THREE_FINGER_CHORD_GRACE_SECONDS * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_deadlineGeneration != generation ||
                strongSelf.state != UIGestureRecognizerStatePossible) return;
            strongSelf.state = UIGestureRecognizerStateFailed;
        });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if (self.state == UIGestureRecognizerStatePossible &&
        _directTouches.count == 2 && _initialTouchLocations.count == 2) {
        NSArray<UITouch *> *contacts = _directTouches.allObjects;
        CGPoint initial[2] = {CGPointZero, CGPointZero};
        CGPoint current[2] = {CGPointZero, CGPointZero};
        double maximumTravel = 0.0;
        BOOL complete = YES;
        for (NSUInteger index = 0; index < 2; index++) {
            UITouch *touch = contacts[index];
            NSValue *value = _initialTouchLocations[
                [NSValue valueWithNonretainedObject:touch]];
            if (!value) {
                complete = NO;
                break;
            }
            initial[index] = value.CGPointValue;
            current[index] = [touch locationInView:self.view];
            maximumTravel = fmax(maximumTravel,
                hypot(current[index].x - initial[index].x,
                      current[index].y - initial[index].y));
        }
        if (complete) {
            double initialSpan = hypot(initial[1].x - initial[0].x,
                                       initial[1].y - initial[0].y);
            double currentSpan = hypot(current[1].x - current[0].x,
                                       current[1].y - current[0].y);
            if (MacWSTwoFingerMotionHasCommitted(
                    maximumTravel, currentSpan - initialSpan)) {
                // Release dependencies on this same UIKit movement event.
                // UIPinch/UIPan retain their accumulated displacement and can
                // begin without waiting for the fixed chord deadline.
                self.state = UIGestureRecognizerStateFailed;
                return;
            }
        }
    }
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateChanged;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) [_directTouches removeObject:touch];
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        if (_directTouches.count < 3)
            self.state = UIGestureRecognizerStateEnded;
    } else if (self.state == UIGestureRecognizerStatePossible &&
               _directTouches.count < 2) {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [_directTouches removeAllObjects];
    self.state = (self.state == UIGestureRecognizerStateBegan ||
                  self.state == UIGestureRecognizerStateChanged)
        ? UIGestureRecognizerStateCancelled
        : UIGestureRecognizerStateFailed;
}

@end

@implementation MacWSMetalView {
    MacWSMappedFrame *_frame;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLRenderPipelineState> _opaquePipeline;
    id<MTLRenderPipelineState> _shadowPipeline;
    id<MTLTexture> _sourceTexture;
    MacWSPerformanceMonitor *_performanceMonitor;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CGRect _contentRect;
    CGRect _visibleSourceRect;
    BOOL _reportedNonzeroFrame;
    BOOL _submittedPresentWitness;
    BOOL _submittedCatalystDrawableWitness;
    NSString *_lastStatus;
    UIView *_directTouchIndicator;
    UIImageView *_directTouchStateGlyph;
    NSMutableArray<UIView *> *_multitouchIndicators;
    UIView *_trackpadCursorView;
    UIImageView *_trackpadStateGlyph;
    UIView *_pencilCursorView;
    UILabel *_inputUnavailableLabel;
    UIView *_tooSmallOverlay;
    UILabel *_tooSmallLabel;
    UIVisualEffectView *_zoomHUD;
    UILabel *_zoomHUDLabel;
    UIImageView *_fallbackImageView;
    CADisplayLink *_framePollDisplayLink;
    uint64_t _fallbackSignature;
    BOOL _reportedFallbackFrame;
    uint64_t _pendingCaptureGeneration;
    uint64_t _presentedCaptureGeneration;
    BOOL _macWSInputEnabled;
    BOOL _windowTooSmall;
    MacWSStreamClient *_streamClient;
    MacWSSurfaceFrame *_surfaceFrame;
    id<MTLTexture> _surfaceTexture;
    NSMutableDictionary<NSNumber *, MacWSSurfaceFrame *> *_overlayFrames;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *_overlayTextures;
    MacWSCatalystDrawableCompositor *_catalystDrawableCompositor;
    NSArray<MacWSStreamWindow *> *_latestWindows;
    NSSet<NSNumber *> *_spatialCanvasPIDs;
    NSSet<NSNumber *> *_fullscreenCanvasPIDs;
    int32_t _reportedFullscreenCanvasPID;
    uint32_t _reportedFullscreenCanvasWindowID;
    CGRect _reportedFullscreenCanvasPixels;
    NSSet<NSNumber *> *_shadowWindowIDs;
    BOOL _directTouchUsesPrimaryDrag;
    uint64_t _surfaceTextureImports;
    uint64_t _surfaceTextureReuses;
    uint64_t _lastPerformanceLogStreamID;
    uint64_t _lastPerformanceLogSequence;
    BOOL _catalogRevalidationRequestedForPresentation;
    BOOL _targetRetirementCatalogRequeryScheduled;
    CFTimeInterval _lastDirectDrawableHeartbeatTime;
    int32_t _directDrawableHeartbeatPID;
    uint32_t _directDrawableHeartbeatLayerID;
    BOOL _reportedDirectDrawableJoinMiss;
    BOOL _reportedDirectDrawableExactLayerSuppression;
    BOOL _reportedDirectDrawableBaseElision;
    NSString *_pendingRenderedDrawableSnapshotPath;
    NSArray<NSNumber *> *_sortedOverlayKeys;
    NSMutableArray<MacWSSurfaceFrame *> *_retiredSurfaceFrames;
    uint64_t _submittedSurfaceLeaseToken;
    NSMutableDictionary<NSNumber *, NSNumber *> *_submittedOverlayLeaseTokens;
    BOOL _streamConnected;
    UITouch *_trackpadTouch;
    CGPoint _trackpadCursor;
    CGPoint _trackpadPreviousPoint;
    CGFloat _trackpadTravel;
    NSTimeInterval _trackpadBeganAt;
    BOOL _trackpadButtonDown;
    BOOL _trackpadHadMultipleTouches;
    BOOL _trackpadCursorWasTouched;
    BOOL _externalPointerHoverActive;
    BOOL _pencilHoverActive;
    UITouch *_pencilTouch;
    CGPoint _pencilTouchStartPoint;
    CGFloat _pencilTouchTravel;
    NSTimeInterval _pencilTouchBeganAt;
    UITouch *_directTouch;
    UITouch *_secondaryPointerTouch;
    BOOL _directGestureBlocked;
    MacWSDirectTouchState _directTouchState;
    CGPoint _directTouchStartPoint;
    CGPoint _directTouchPreviousPoint;
    CGPoint _directScrollVelocity;
    CGPoint _directScrollFramePoint;
    MacWSDirectScrollAxis _directScrollAxis;
    NSTimeInterval _directTouchStartTimestamp;
    NSTimeInterval _directTouchPreviousTimestamp;
    NSTimeInterval _lastDirectTapTimestamp;
    CGPoint _lastDirectTapPoint;
    uint64_t _directTouchSerial;
    UIImpactFeedbackGenerator *_directTouchFeedback;
    CGFloat _viewportZoom;
    CGPoint _viewportCenter;
    CGFloat _fixedZoomScale;
    BOOL _contentGesturesPassthrough;
    UIPanGestureRecognizer *_twoFingerPanRecognizer;
    UIPanGestureRecognizer *_indirectScrollRecognizer;
    UIPinchGestureRecognizer *_pinchRecognizer;
    UIRotationGestureRecognizer *_rotationRecognizer;
    MacWSThreeFingerChordGateGestureRecognizer *_threeFingerChordGate;
    UIPanGestureRecognizer *_threeFingerPanRecognizer;
    BOOL _threeFingerSystemGestureActive;
    MacWSSystemGestureAxis _threeFingerSystemGestureAxis;
    CGFloat _threeFingerSystemGestureReferenceDistance;
    uint32_t _threeFingerSystemGestureContactID;
    int32_t _threeFingerSystemGestureTargetPID;
    uint32_t _threeFingerSystemGestureFrameWidth;
    uint32_t _threeFingerSystemGestureFrameHeight;
    CGFloat _threeFingerSystemGestureLastProgress;
    CGFloat _threeFingerSystemGestureLastVelocity;
    CADisplayLink *_scrollMomentumDisplayLink;
    CGPoint _scrollMomentumVelocity;
    CGPoint _scrollMomentumFramePoint;
    CGPoint _scrollEmissionResidual;
    CFTimeInterval _scrollMomentumLastTimestamp;
    BOOL _scrollMomentumBegan;
    BOOL _windowConfigurationDispatchPending;
    CGSize _pendingRequestedWindowSize;
    CGFloat _pendingRequestedDensityScale;
    uint32_t _inputSampleSequence;
    uint32_t _lastKeyboardFrameWidth;
    uint32_t _lastKeyboardFrameHeight;
    CGSize _lastRequestedWindowSize;
    CGFloat _lastRequestedDensityScale;
    uint64_t _windowConfigurationSettlementSerial;
    BOOL _windowConfigurationAwaitingAcknowledgement;
    BOOL _fullscreenGestureRouteActive;
    uint32_t _fullscreenGestureRouteContactID;
    int32_t _fullscreenGestureRoutePID;
    uint32_t _fullscreenGestureRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenGestureRouteDescriptor;
    CFTimeInterval _fullscreenLastTapRouteTimestamp;
    int32_t _fullscreenLastTapRoutePID;
    uint32_t _fullscreenLastTapRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenLastTapRouteDescriptor;
    int32_t _fullscreenGlobalPointerPresentationPID;
    uint32_t _fullscreenGlobalPointerPresentationContactID;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) return nil;

    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // The producer publishes acknowledged snapshots, not a live 20-fps pixel
    // stream.  Continuous MTKView drawing uploaded the unchanged 15.2-MiB
    // frame 20 times per second and runtime-measured as 13-15% App CPU.  Poll
    // only the tiny generation ACK and draw exactly once per new snapshot.
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    // Own drawable sizing explicitly. The adaptive policy preserves the
    // producer's pixels for the desktop, while a validated fullscreen canvas
    // uses one output pixel per UIKit point so a game does not pay for a
    // second high-resolution presentation pass.
    self.autoResizeDrawable = NO;
    self.clearColor = MTLClearColorMake(0.025, 0.028, 0.035, 1.0);
    self.multipleTouchEnabled = YES;
    self.inputMode = MacWSHostInputModeDirect;
    self.fixedZoomScale = 1.5;
    self.displayDensity = MacWSHostDisplayDensityTouchComfort;
    // Status polling enables interaction only after WindowServer, the input
    // socket and an exact-PID acknowledged frame are all present.  A stale
    // screenshot must never look like a live, touchable workspace.
    self.userInteractionEnabled = NO;

    _frame = [MacWSMappedFrame new];
    _streamClient = [MacWSStreamClient new];
    _streamClient.delegate = self;
    _overlayFrames = [NSMutableDictionary dictionary];
    _overlayTextures = [NSMutableDictionary dictionary];
    _catalystDrawableCompositor =
        [[MacWSCatalystDrawableCompositor alloc] initWithDevice:device];
    _retiredSurfaceFrames = [NSMutableArray array];
    _submittedOverlayLeaseTokens = [NSMutableDictionary dictionary];
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"MacWSHost display queue";
    _performanceMonitor = [[MacWSPerformanceMonitor alloc]
        initWithSceneLabel:[NSString stringWithFormat:@"scene-%p", self]];
    _contentRect = CGRectZero;
    _visibleSourceRect = CGRectMake(0, 0, 1, 1);
    _trackpadCursor = CGPointMake(-1, -1);
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _directTouchState = MacWSDirectTouchStateIdle;
    _directTouchFeedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    MacWSStartCatalystDrawableReceiver();
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(catalystDrawableDidPresent:)
        name:MacWSCatalystDrawableDidPresentNotification object:nil];

    // Direct touch uses a soft contact halo.  It is deliberately different
    // from the trackpad cursor: one represents the finger's absolute contact,
    // the other represents persistent relative-pointer state.
    _directTouchIndicator = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 30, 30)];
    _directTouchIndicator.backgroundColor =
        [UIColor.systemCyanColor colorWithAlphaComponent:0.15];
    _directTouchIndicator.layer.borderWidth = 1.5;
    _directTouchIndicator.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.82].CGColor;
    _directTouchIndicator.layer.cornerRadius = 15;
    _directTouchIndicator.layer.shadowColor = UIColor.blackColor.CGColor;
    _directTouchIndicator.layer.shadowOpacity = 0.22;
    _directTouchIndicator.layer.shadowRadius = 5;
    _directTouchIndicator.layer.shadowOffset = CGSizeMake(0, 2);
    _directTouchIndicator.userInteractionEnabled = NO;
    _directTouchIndicator.hidden = YES;
    UIView *contactDot = [[UIView alloc] initWithFrame:CGRectMake(11, 11, 8, 8)];
    contactDot.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.92];
    contactDot.layer.cornerRadius = 4;
    contactDot.userInteractionEnabled = NO;
    [_directTouchIndicator addSubview:contactDot];
    contactDot.tag = 501;
    _directTouchStateGlyph = [[UIImageView alloc] initWithFrame:
        CGRectMake(7, 7, 16, 16)];
    _directTouchStateGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _directTouchStateGlyph.tintColor = UIColor.whiteColor;
    _directTouchStateGlyph.hidden = YES;
    _directTouchStateGlyph.userInteractionEnabled = NO;
    [_directTouchIndicator addSubview:_directTouchStateGlyph];
    [self addSubview:_directTouchIndicator];
    _multitouchIndicators = [NSMutableArray array];

    // A finger-driven relative trackpad uses the same circular MacWS pointer
    // language advertised by the control center. The previous black macOS
    // arrow duplicated the real cursor presentation and was visibly mistaken
    // for a cursor leaking out of the WindowServer final composite. Hardware
    // Magic Keyboard pointers keep UIKit's native adaptive pointer and do not
    // draw this overlay.
    _trackpadCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 24, 24)];
    _trackpadCursorView.backgroundColor =
        [UIColor.systemGrayColor colorWithAlphaComponent:0.74];
    _trackpadCursorView.layer.cornerRadius = 12.0;
    _trackpadCursorView.layer.borderWidth = 1.0;
    _trackpadCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.88].CGColor;
    _trackpadCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _trackpadCursorView.layer.shadowOpacity = 0.30;
    _trackpadCursorView.layer.shadowRadius = 3.0;
    _trackpadCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _trackpadCursorView.userInteractionEnabled = NO;
    _trackpadCursorView.hidden = YES;
    _trackpadStateGlyph = [[UIImageView alloc] initWithFrame:
        CGRectMake(5, 5, 14, 14)];
    _trackpadStateGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _trackpadStateGlyph.tintColor = UIColor.whiteColor;
    _trackpadStateGlyph.image = [UIImage systemImageNamed:
        @"hand.point.up.left.fill"];
    _trackpadStateGlyph.hidden = YES;
    _trackpadStateGlyph.userInteractionEnabled = NO;
    [_trackpadCursorView addSubview:_trackpadStateGlyph];
    [self addSubview:_trackpadCursorView];

    // Pencil hover follows iPad's precise-pointer visual language. Native
    // in-air updates arrive only on hover-capable hardware; contact movement
    // remains a non-clicking preview on older iPads until a short tap ends.
    _pencilCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 20, 20)];
    _pencilCursorView.backgroundColor =
        [UIColor.systemGrayColor colorWithAlphaComponent:0.72];
    _pencilCursorView.layer.borderWidth = 1.0;
    _pencilCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.90].CGColor;
    _pencilCursorView.layer.cornerRadius = 10;
    _pencilCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _pencilCursorView.layer.shadowOpacity = 0.28;
    _pencilCursorView.layer.shadowRadius = 4;
    _pencilCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _pencilCursorView.userInteractionEnabled = NO;
    _pencilCursorView.hidden = YES;
    [self addSubview:_pencilCursorView];

    _inputUnavailableLabel = [UILabel new];
    _inputUnavailableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _inputUnavailableLabel.text = @"触控暂不可用 · macOS 工作区未就绪";
    _inputUnavailableLabel.textColor = UIColor.whiteColor;
    _inputUnavailableLabel.backgroundColor =
        [UIColor.systemOrangeColor colorWithAlphaComponent:0.88];
    _inputUnavailableLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _inputUnavailableLabel.textAlignment = NSTextAlignmentCenter;
    _inputUnavailableLabel.numberOfLines = 0;
    _inputUnavailableLabel.layer.cornerRadius = 12;
    _inputUnavailableLabel.clipsToBounds = YES;
    _inputUnavailableLabel.userInteractionEnabled = NO;
    [self addSubview:_inputUnavailableLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_inputUnavailableLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_inputUnavailableLabel.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                                                            constant:-18],
        [_inputUnavailableLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor
                                                                    multiplier:0.82],
        [_inputUnavailableLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
    ]];

    _tooSmallOverlay = [UIView new];
    _tooSmallOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallOverlay.backgroundColor =
        [UIColor.systemBackgroundColor colorWithAlphaComponent:0.98];
    _tooSmallOverlay.hidden = YES;
    _tooSmallOverlay.userInteractionEnabled = NO;
    [self addSubview:_tooSmallOverlay];
    _tooSmallLabel = [UILabel new];
    _tooSmallLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallLabel.numberOfLines = 0;
    _tooSmallLabel.textAlignment = NSTextAlignmentCenter;
    _tooSmallLabel.textColor = UIColor.labelColor;
    _tooSmallLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [_tooSmallOverlay addSubview:_tooSmallLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_tooSmallOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tooSmallOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tooSmallOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_tooSmallOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_tooSmallLabel.centerXAnchor constraintEqualToAnchor:_tooSmallOverlay.centerXAnchor],
        [_tooSmallLabel.centerYAnchor constraintEqualToAnchor:_tooSmallOverlay.centerYAnchor],
        [_tooSmallLabel.widthAnchor constraintLessThanOrEqualToAnchor:_tooSmallOverlay.widthAnchor
                                                             multiplier:0.82],
    ]];

    _zoomHUD = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _zoomHUD.translatesAutoresizingMaskIntoConstraints = NO;
    _zoomHUD.layer.cornerRadius = 13;
    _zoomHUD.clipsToBounds = YES;
    _zoomHUD.hidden = YES;
    [self addSubview:_zoomHUD];
    _zoomHUDLabel = [UILabel new];
    _zoomHUDLabel.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                         weight:UIFontWeightSemibold];
    _zoomHUDLabel.textColor = UIColor.labelColor;
    _zoomHUDLabel.textAlignment = NSTextAlignmentCenter;
    [_zoomHUDLabel.widthAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    UIStackView *zoomHUDContent = [[UIStackView alloc]
        initWithArrangedSubviews:@[_zoomHUDLabel]];
    zoomHUDContent.translatesAutoresizingMaskIntoConstraints = NO;
    zoomHUDContent.axis = UILayoutConstraintAxisHorizontal;
    zoomHUDContent.alignment = UIStackViewAlignmentCenter;
    zoomHUDContent.spacing = 7;
    zoomHUDContent.layoutMargins = UIEdgeInsetsMake(7, 9, 7, 9);
    zoomHUDContent.layoutMarginsRelativeArrangement = YES;
    [_zoomHUD.contentView addSubview:zoomHUDContent];
    [NSLayoutConstraint activateConstraints:@[
        [_zoomHUD.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor
                                                 constant:-12],
        [_zoomHUD.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                                            constant:12],
        [zoomHUDContent.leadingAnchor constraintEqualToAnchor:_zoomHUD.contentView.leadingAnchor],
        [zoomHUDContent.trailingAnchor constraintEqualToAnchor:_zoomHUD.contentView.trailingAnchor],
        [zoomHUDContent.topAnchor constraintEqualToAnchor:_zoomHUD.contentView.topAnchor],
        [zoomHUDContent.bottomAnchor constraintEqualToAnchor:_zoomHUD.contentView.bottomAnchor],
    ]];

    if (device) {
        [self buildPipeline];
    } else {
        self.paused = YES;
        _fallbackImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _fallbackImageView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fallbackImageView.backgroundColor = UIColor.blackColor;
        _fallbackImageView.contentMode = UIViewContentModeScaleAspectFit;
        _fallbackImageView.clipsToBounds = YES;
        _fallbackImageView.userInteractionEnabled = NO;
        [self insertSubview:_fallbackImageView atIndex:0];
        MacWSLog(@"native Metal device unavailable; UIKit fallback armed");
    }

    _framePollDisplayLink = [CADisplayLink displayLinkWithTarget:self
        selector:@selector(pollSharedFrame:)];
    _framePollDisplayLink.preferredFramesPerSecond = 5;
    _framePollDisplayLink.paused = !MacWSLegacyFramebufferFallbackEnabled();
    [_framePollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                               forMode:NSRunLoopCommonModes];

    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(hovered:)];
        hover.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:hover];
        UIHoverGestureRecognizer *pencilHover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(pencilHovered:)];
        pencilHover.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:pencilHover];
    }
    _twoFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(twoFingerPanned:)];
    _twoFingerPanRecognizer.minimumNumberOfTouches = 2;
    _twoFingerPanRecognizer.maximumNumberOfTouches = 2;
    _twoFingerPanRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    if (@available(iOS 13.4, *))
        _twoFingerPanRecognizer.allowedScrollTypesMask = 0;
    _twoFingerPanRecognizer.cancelsTouchesInView = YES;
    _twoFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_twoFingerPanRecognizer];
    if (@available(iOS 13.4, *)) {
        // A Magic Keyboard trackpad or mouse wheel is a UIKit scroll event,
        // not two UITouch contacts.  The old two-finger recognizer required
        // exactly two touches and therefore could never receive this input.
        // Apple's supported split is an independent pan recognizer with the
        // desired scroll mask and an empty allowedTouchTypes set; direct
        // fingers remain exclusively owned by the recognizer above.
        _indirectScrollRecognizer = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(indirectScrolled:)];
        _indirectScrollRecognizer.allowedTouchTypes = @[];
        _indirectScrollRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
        _indirectScrollRecognizer.cancelsTouchesInView = NO;
        _indirectScrollRecognizer.delegate = self;
        [self addGestureRecognizer:_indirectScrollRecognizer];
    }
    _pinchRecognizer = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(pinched:)];
    _pinchRecognizer.cancelsTouchesInView = YES;
    _pinchRecognizer.delegate = self;
    [self addGestureRecognizer:_pinchRecognizer];
    _rotationRecognizer = [[UIRotationGestureRecognizer alloc]
        initWithTarget:self action:@selector(rotated:)];
    // Do not restrict allowedTouchTypes here. UIKit's rotation recognizer is
    // the supported common boundary for both direct fingers and the Magic
    // Keyboard/trackpad's indirect two-finger rotation stream.
    _rotationRecognizer.cancelsTouchesInView = YES;
    _rotationRecognizer.delegate = self;
    [self addGestureRecognizer:_rotationRecognizer];
    _threeFingerChordGate =
        [[MacWSThreeFingerChordGateGestureRecognizer alloc]
            initWithTarget:self action:@selector(threeFingerChordChanged:)];
    _threeFingerChordGate.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _threeFingerChordGate.cancelsTouchesInView = YES;
    _threeFingerChordGate.delegate = self;
    [self addGestureRecognizer:_threeFingerChordGate];
    _threeFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(threeFingerPanned:)];
    _threeFingerPanRecognizer.minimumNumberOfTouches = 3;
    _threeFingerPanRecognizer.maximumNumberOfTouches = 3;
    _threeFingerPanRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _threeFingerPanRecognizer.cancelsTouchesInView = YES;
    _threeFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_threeFingerPanRecognizer];
    [_twoFingerPanRecognizer
        requireGestureRecognizerToFail:_threeFingerChordGate];
    [_pinchRecognizer requireGestureRecognizerToFail:_threeFingerChordGate];
    [_rotationRecognizer requireGestureRecognizerToFail:_threeFingerChordGate];
    UITapGestureRecognizer *resetZoom = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(viewportZoomToggled:)];
    resetZoom.numberOfTouchesRequired = 2;
    resetZoom.numberOfTapsRequired = 2;
    resetZoom.cancelsTouchesInView = YES;
    [self addGestureRecognizer:resetZoom];
    UITapGestureRecognizer *secondaryTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(trackpadSecondaryTapped:)];
    secondaryTap.numberOfTouchesRequired = 2;
    secondaryTap.cancelsTouchesInView = NO;
    [secondaryTap requireGestureRecognizerToFail:resetZoom];
    [self addGestureRecognizer:secondaryTap];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:MacWSCatalystDrawableDidPresentNotification object:nil];
    [_framePollDisplayLink invalidate];
    [_scrollMomentumDisplayLink invalidate];
    if (_surfaceFrame) [_streamClient releaseFrame:_surfaceFrame];
    for (MacWSSurfaceFrame *frame in _overlayFrames.allValues)
        [_streamClient releaseFrame:frame];
    for (MacWSSurfaceFrame *frame in _retiredSurfaceFrames)
        [_streamClient releaseFrame:frame];
    [_streamClient invalidate];
}

- (void)catalystDrawableDidPresent:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    MacWSCatalystDrawableFrame *accepted =
        [_catalystDrawableCompositor consumeDeliveryObject:notification.object
            shouldAcceptOwner:^BOOL(int32_t ownerPID) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return NO;
                if (strongSelf.targetPID == ownerPID) return YES;
                if (strongSelf.targetWindowID != 0) return NO;
                for (MacWSSurfaceFrame *frame in
                        strongSelf->_overlayFrames.allValues) {
                    if (frame.descriptor.layerOwnerPID == ownerPID) return YES;
                }
                return NO;
            }];
    if (!accepted) return;

    uint64_t directReceiptTime = mach_absolute_time();
    [_performanceMonitor
        recordDirectDrawableReceivedForOwnerPID:accepted.record.ownerPID
        sequence:accepted.record.sequence
        completionTime:accepted.record.completionTime
        receiptTime:directReceiptTime
        isTarget:self.targetPID == accepted.record.ownerPID];

    // Suppress redundant capture only after joining the direct drawable to
    // AppInputBridge's live focused+fullscreen catalog identity. PID alone is
    // not sufficient: one process can own menus, launch windows and the game
    // window simultaneously. The drawable resolution is intentionally not an
    // identity field (Stray publishes its configured 1400x900 render target
    // into a 2388x1668 fullscreen window). displayd independently validates
    // the same PID/window/focus/full-canvas geometry before stopping capture.
    MacWSCatalystDrawableRecord direct = accepted.record;
    uint32_t canvasWidth = _surfaceFrame.descriptor.contentWidth;
    uint32_t canvasHeight = _surfaceFrame.descriptor.contentHeight;
    uint32_t matchedWindowID = 0;
    NSString *identitySource = nil;
    if (_reportedFullscreenCanvasPID == direct.ownerPID &&
        _reportedFullscreenCanvasWindowID != 0) {
        matchedWindowID = _reportedFullscreenCanvasWindowID;
        identitySource = @"retained-live-fullscreen-canvas";
    }
    uint64_t matchedScore = 0;
    for (MacWSStreamWindow *window in
            (matchedWindowID == 0 ? _latestWindows : @[])) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if (descriptor.ownerPID != direct.ownerPID ||
            descriptor.windowID == 0 ||
            (descriptor.flags & MacWSStreamWindowFocused) == 0 ||
            (descriptor.flags & MacWSStreamWindowFullscreenCanvas) == 0 ||
            (_targetWindowID != 0 &&
             descriptor.windowID != _targetWindowID)) continue;
        uint64_t score = (uint64_t)descriptor.pixelWidth *
            (uint64_t)descriptor.pixelHeight;
        if (score > matchedScore) {
            matchedScore = score;
            matchedWindowID = descriptor.windowID;
            identitySource = @"focused-fullscreen-catalog";
        }
    }
    if (matchedWindowID == 0 &&
        self.targetPID == direct.ownerPID &&
        self.targetWindowID != 0 &&
        [_fullscreenCanvasPIDs containsObject:@(direct.ownerPID)] &&
        MacWSAppInputEndpointReady(direct.ownerPID) &&
        [self hasFinalCompositeFrame] &&
        canvasWidth != 0 && canvasHeight != 0) {
        // The controller has already selected this exact window from a
        // Focused|FullscreenCanvas catalog record and retains it only while
        // the same AppInput endpoint is alive.  R19 runtime evidence shows
        // SkyLight can retire every corresponding surface before the delayed
        // direct-drawable activation, so MacWSMetalView never gets a
        // simultaneous layer from which to establish its own cache.  Join
        // the same validated target identity here; FullscreenCanvas makes the
        // final-composite extent, rather than the retired backing size, the
        // semantic destination.
        matchedWindowID = self.targetWindowID;
        identitySource = @"retained-targeted-fullscreen-endpoint";
        _reportedFullscreenCanvasPID = direct.ownerPID;
        _reportedFullscreenCanvasWindowID = matchedWindowID;
        _reportedFullscreenCanvasPixels =
            CGRectMake(0, 0, canvasWidth, canvasHeight);
    }
    if (matchedWindowID != 0 && canvasWidth != 0 && canvasHeight != 0) {
        CFTimeInterval now = CACurrentMediaTime();
        BOOL identityChanged =
            _directDrawableHeartbeatPID != direct.ownerPID ||
            _directDrawableHeartbeatLayerID != matchedWindowID;
        if (identityChanged || now - _lastDirectDrawableHeartbeatTime >= 0.25) {
            _lastDirectDrawableHeartbeatTime = now;
            _directDrawableHeartbeatPID = direct.ownerPID;
            _directDrawableHeartbeatLayerID = matchedWindowID;
            if (identityChanged) {
                MacWSLog(@"direct-drawable-heartbeat pid=%d layer=%u "
                         "drawable=%ux%u canvas=%ux%u "
                         "identity=%@",
                         direct.ownerPID, matchedWindowID,
                         direct.width, direct.height,
                         canvasWidth, canvasHeight, identitySource);
            }
            [_streamClient noteDirectDrawableForOwnerPID:direct.ownerPID
                                           layerWindowID:matchedWindowID
                                                   width:direct.width
                                                  height:direct.height];
        }
    } else if (!_reportedDirectDrawableJoinMiss) {
        _reportedDirectDrawableJoinMiss = YES;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            if (descriptor.ownerPID != direct.ownerPID) continue;
            [candidates addObject:[NSString stringWithFormat:
                @"%u:flags=0x%x/%ux%u", descriptor.windowID,
                descriptor.flags, descriptor.pixelWidth,
                descriptor.pixelHeight]];
        }
        MacWSLog(@"direct-drawable-join-miss pid=%d drawable=%ux%u "
                 "canvas=%ux%u catalog-candidates=%@",
                 direct.ownerPID, direct.width, direct.height,
                 canvasWidth, canvasHeight, candidates);
    }
    [self setNeedsDisplay];
}

- (NSString *)exportCatalystDrawableProbeForPID:(int32_t)ownerPID
                                           error:(NSError **)error {
    MacWSCatalystDrawableFrame *frame =
        [_catalystDrawableCompositor frameForOwnerPID:ownerPID];
    if (!frame) {
        if (error) *error = [NSError errorWithDomain:@"MacWSCatalystProbe"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"当前目标还没有 Catalyst drawable"}];
        return nil;
    }
    NSString *directory = @"/var/mobile/Library/Logs/MacWSPerformance";
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil error:error])
        return nil;
    NSString *rawPath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"catalyst-drawable-%d.bgra", ownerPID]];
    NSDictionary *probe = MacWSProbeCatalystDrawable(frame, rawPath, error);
    if (!probe) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:probe
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!json) return nil;
    NSString *jsonPath = [directory stringByAppendingPathComponent:
        @"latest-catalyst-drawable.json"];
    if (![json writeToFile:jsonPath options:NSDataWritingAtomic error:error])
        return nil;
    MacWSLog(@"catalyst-drawable-probe path=%@ result=%@", jsonPath, probe);
    return jsonPath;
}

- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID {
    // A UIKit scene/mode transition can cancel its recognizers after the
    // DisplayStream subscription has already changed.  Close the native Dock
    // phase stream while its latched endpoint is still valid; clearing these
    // fields without a Cancel strands Dock's fluid controller in a gesture
    // that no later touch owns.
    [self cancelActiveThreeFingerSystemGestureAtTimestamp:
        CACurrentMediaTime()];
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _lastRequestedWindowSize = CGSizeZero;
    _fullscreenGestureRouteActive = NO;
    _fullscreenGestureRouteContactID = 0;
    _fullscreenGestureRoutePID = 0;
    _fullscreenGestureRouteWindowID = 0;
    _fullscreenGestureRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    _threeFingerSystemGestureActive = NO;
    _threeFingerSystemGestureAxis = 0;
    _threeFingerSystemGestureReferenceDistance = 0.0;
    _threeFingerSystemGestureContactID = 0;
    _threeFingerSystemGestureTargetPID = 0;
    _threeFingerSystemGestureFrameWidth = 0;
    _threeFingerSystemGestureFrameHeight = 0;
    _threeFingerSystemGestureLastProgress = 0.0;
    _threeFingerSystemGestureLastVelocity = 0.0;
    _fullscreenLastTapRouteTimestamp = 0.0;
    _fullscreenLastTapRoutePID = 0;
    _fullscreenLastTapRouteWindowID = 0;
    _fullscreenLastTapRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    _catalogRevalidationRequestedForPresentation = NO;
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    [_catalystDrawableCompositor removeAllFrames];
    self.targetWindowID = mode == MacWSStreamModeWindow ? windowID : 0;
    // A window Scene must only display the IOSurface exported for that window.
    // The mmap framebuffer is a full-desktop compatibility path and would show
    // a misleading crop while the direct stream is negotiating its first frame.
    _framePollDisplayLink.paused = self.targetWindowID != 0 ||
        !MacWSLegacyFramebufferFallbackEnabled();
    [_streamClient subscribeToMode:mode windowID:windowID];
    [self refreshPresentationPolicy];
}

- (uint64_t)inputSceneIDWithModifiers:(uint32_t)modifiers {
    if (self.targetWindowID != 0)
        return MacWSInputSceneForWindow(self.targetWindowID, modifiers);
    // sceneID's low 32 bits are the keyboard modifier ABI.  A fullscreen
    // UIWindowScene identity is an opaque hash and must never occupy that
    // field: runtime record 0xe94da71f accidentally asserted AlphaShift,
    // Control and Option, making both hardware and software input uppercase.
    // The protocol already defines a marked zero-window encoding for a
    // fullscreen system surface; use it even when modifiers are zero.
    return MacWSInputSceneForWindow(0, modifiers);
}

- (void)requestStreamWindowList {
    [_streamClient requestWindowList];
}

- (void)suspendStream {
    [self cancelActiveThreeFingerSystemGestureAtTimestamp:
        CACurrentMediaTime()];
    _framePollDisplayLink.paused = YES;
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    [_streamClient unsubscribe];
    NSMutableArray<MacWSSurfaceFrame *> *leases =
        [_retiredSurfaceFrames mutableCopy];
    [_retiredSurfaceFrames removeAllObjects];
    if (_surfaceFrame) [leases addObject:_surfaceFrame];
    [leases addObjectsFromArray:_overlayFrames.allValues];
    _surfaceFrame = nil;
    _surfaceTexture = nil;
    [_overlayFrames removeAllObjects];
    [_overlayTextures removeAllObjects];
    [_submittedOverlayLeaseTokens removeAllObjects];
    _submittedSurfaceLeaseToken = 0;
    _sortedOverlayKeys = nil;
    _catalogRevalidationRequestedForPresentation = NO;
    _sourceTexture = nil;
    _textureWidth = 0;
    _textureHeight = 0;
    _contentRect = CGRectZero;
    // A UIWindow/Stage Manager maximization animation can rescale the last
    // CAMetalDrawable before the replacement DisplayStream generation lands.
    // Rendering a deterministic clear frame prevents that stale exact-window
    // image from appearing as a cropped/magnified full desktop.
    _submittedPresentWitness = NO;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    [self hideMultitouchIndicators];
    _directTouchIndicator.hidden = YES;
    _trackpadCursorView.hidden = YES;
    if (leases.count && _commandQueue) {
        id<MTLCommandBuffer> fence = [_commandQueue commandBuffer];
        __weak MacWSStreamClient *weakClient = _streamClient;
        [fence addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            for (MacWSSurfaceFrame *frame in leases)
                [weakClient releaseFrame:frame];
        }];
        [fence commit];
    } else {
        for (MacWSSurfaceFrame *frame in leases)
            [_streamClient releaseFrame:frame];
    }
    [self setNeedsDisplay];
}

- (uint32_t)currentFrameWidth {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentWidth : _frame.width;
}

- (uint32_t)currentFrameHeight {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentHeight : _frame.height;
}

- (CGFloat)effectiveDensityScale {
    // Density describes the macOS source's logical geometry in the UIKit
    // Scene; it must not change when the presentation drawable is deliberately
    // lower resolution. Derive it from the authoritative source frame and
    // backing scale. On the target iPad source=2388x1668, backing=2 and
    // bounds=1389x970 preserve the existing ~1.16 mapping.
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 2.0;
    if (_streamClient.mode == MacWSStreamModeWindow) {
        UIScreen *screen = self.window.windowScene.screen ?: UIScreen.mainScreen;
        return MacWSStableWindowDensity(
            backingScale, screen.scale,
            MacWSDensityModeFactor(self.displayDensity));
    }
    CGFloat sourceWidth = [self currentFrameWidth];
    CGFloat sourceHeight = [self currentFrameHeight];
    CGFloat scaleX = self.bounds.size.width > 0 && sourceWidth > 0
        ? sourceWidth / self.bounds.size.width : 0.0;
    CGFloat scaleY = self.bounds.size.height > 0 && sourceHeight > 0
        ? sourceHeight / self.bounds.size.height : 0.0;
    CGFloat sourcePixelsPerPoint = (scaleX + scaleY) * 0.5;
    if (!isfinite(sourcePixelsPerPoint) || sourcePixelsPerPoint < 0.5)
        sourcePixelsPerPoint = self.contentScaleFactor;
    if (!isfinite(sourcePixelsPerPoint) || sourcePixelsPerPoint < 0.5)
        sourcePixelsPerPoint = 2.0;
    CGFloat pixelMatched = backingScale / sourcePixelsPerPoint;
    pixelMatched = fmin(fmax(pixelMatched, 0.5), 2.0);
    return pixelMatched * MacWSDensityModeFactor(self.displayDensity);
}

- (BOOL)hasDirectSurfaceFrame { return _surfaceFrame != nil; }
- (BOOL)hasFinalCompositeFrame {
    return _surfaceFrame &&
        (_surfaceFrame.descriptor.flags & MacWSStreamFrameFinalComposite) != 0;
}
- (BOOL)streamServiceConnected { return _streamClient.isConnected; }

- (void)requestRenderedDrawableSnapshotToPath:(NSString *)path {
    if (path.length == 0) return;
    _pendingRenderedDrawableSnapshotPath = [path copy];
    [self setNeedsDisplay];
}

- (void)setTargetPID:(int32_t)targetPID {
    if (_targetPID == targetPID) return;
    int32_t previousTargetPID = _targetPID;
    _lastKeyboardFrameWidth = 0;
    _lastKeyboardFrameHeight = 0;
    MacWSLog(@"presentation-target-change previous=%d next=%d "
             "direct-heartbeat=%d/%u fullscreen-canvas=%d/%u mode=%lu",
             previousTargetPID, targetPID, _directDrawableHeartbeatPID,
             _directDrawableHeartbeatLayerID, _reportedFullscreenCanvasPID,
             _reportedFullscreenCanvasWindowID,
             (unsigned long)_streamClient.mode);
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    if (_reportedFullscreenCanvasPID != targetPID) {
        _reportedFullscreenCanvasPID = 0;
        _reportedFullscreenCanvasWindowID = 0;
        _reportedFullscreenCanvasPixels = CGRectZero;
    }
    if (previousTargetPID > 1) {
        NSMutableSet<NSNumber *> *capabilities =
            [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
        [capabilities removeObject:@(previousTargetPID)];
        _fullscreenCanvasPIDs = [capabilities copy];
    }
    _targetPID = targetPID;
    _directTouchUsesPrimaryDrag = targetPID > 1 &&
        [_spatialCanvasPIDs containsObject:@(targetPID)];
    [self refreshPresentationPolicy];
}

- (void)noteValidatedFullscreenCanvasForPID:(int32_t)ownerPID
                                   windowID:(uint32_t)windowID {
    if (ownerPID <= 1 || windowID == 0 || ownerPID != self.targetPID) return;
    NSMutableSet<NSNumber *> *capabilities =
        [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
    [capabilities addObject:@(ownerPID)];
    _fullscreenCanvasPIDs = [capabilities copy];
    _reportedFullscreenCanvasPID = ownerPID;
    _reportedFullscreenCanvasWindowID = windowID;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    _reportedFullscreenCanvasPixels = width != 0 && height != 0
        ? CGRectMake(0, 0, width, height) : CGRectZero;
    MacWSLog(@"fullscreen-canvas-capability pid=%d window=%u "
             "source=controller-validated-catalog canvas=%ux%u",
             ownerPID, windowID, width, height);
    [self updateDrawableResolution];
    [self setNeedsDisplay];
}

- (void)setDisplayDensity:(MacWSHostDisplayDensity)displayDensity {
    if (displayDensity != MacWSHostDisplayDensityTouchComfort &&
        displayDensity != MacWSHostDisplayDensityKeyboard &&
        displayDensity != MacWSHostDisplayDensityComfort) return;
    _displayDensity = displayDensity;
    _lastRequestedWindowSize = CGSizeZero;
    [self resetViewportZoom];
    [self geometryDidChange];
}

- (void)setPresentationResolution:
        (MacWSHostPresentationResolution)presentationResolution {
    if (presentationResolution !=
            MacWSHostPresentationResolutionAutomatic &&
        presentationResolution !=
            MacWSHostPresentationResolutionSourceNative &&
        presentationResolution !=
            MacWSHostPresentationResolutionPerformance) return;
    if (_presentationResolution == presentationResolution) return;
    _presentationResolution = presentationResolution;
    [self updateDrawableResolution];
    [self updatePresentationGeometry];
    [self setNeedsDisplay];
}

- (void)setFixedZoomScale:(CGFloat)fixedZoomScale {
    CGFloat normalized = fixedZoomScale >= 1.75 ? 2.0 : 1.5;
    BOOL wasZoomed = _viewportZoom > 1.001;
    _fixedZoomScale = normalized;
    if (wasZoomed) {
        _viewportZoom = normalized;
        [self setNeedsDisplay];
    }
    [self updateZoomHUD];
}

- (BOOL)isViewportZoomed {
    return _viewportZoom > 1.001;
}

- (void)updateZoomHUD {
    BOOL visible = [self isViewportZoomed] && !_windowTooSmall;
    _zoomHUD.hidden = !visible;
    _zoomHUDLabel.text = [NSString stringWithFormat:@"%.1f×", _viewportZoom];
}

- (void)setMinimumLogicalSize:(CGSize)minimumLogicalSize {
    _minimumLogicalSize = (CGSize){
        isfinite(minimumLogicalSize.width) && minimumLogicalSize.width > 0
            ? minimumLogicalSize.width : 0,
        isfinite(minimumLogicalSize.height) && minimumLogicalSize.height > 0
            ? minimumLogicalSize.height : 0,
    };
    [self refreshPresentationPolicy];
}

- (void)setTargetWindowResizable:(BOOL)targetWindowResizable {
    _targetWindowResizable = targetWindowResizable;
    [self refreshPresentationPolicy];
}

- (void)updateWindowTooSmallState {
    CGFloat density = self.effectiveDensityScale;
    CGSize available = self.bounds.size;
    CGFloat requiredWidth = self.minimumLogicalSize.width * density;
    CGFloat requiredHeight = self.minimumLogicalSize.height * density;
    BOOL hasRequirement = self.targetWindowID != 0 &&
        (requiredWidth > 0 || requiredHeight > 0);
    _windowTooSmall = hasRequirement &&
        ((requiredWidth > 0 && available.width + 0.5 < requiredWidth) ||
         (requiredHeight > 0 && available.height + 0.5 < requiredHeight));
    _tooSmallOverlay.hidden = !_windowTooSmall;
    _inputUnavailableLabel.hidden = _windowTooSmall || _macWSInputEnabled;
    self.userInteractionEnabled = _macWSInputEnabled && !_windowTooSmall;
    if (_windowTooSmall) {
        NSString *densityName = self.displayDensity ==
            MacWSHostDisplayDensityKeyboard ? @"更多空间" :
            (self.displayDensity == MacWSHostDisplayDensityComfort
                ? @"放大 +10%" : @"像素匹配 Retina");
        _tooSmallLabel.text = [NSString stringWithFormat:
            @"窗口太小\n\n此 macOS 应用至少需要 %.0f × %.0f 点\n"
             "当前 %@ 模式需要约 %.0f × %.0f iPad 点\n\n"
             "请放大 iPadOS 窗口，或切换到更多空间模式。",
            self.minimumLogicalSize.width,
            self.minimumLogicalSize.height,
            densityName, requiredWidth, requiredHeight];
    }
    [self updateZoomHUD];
    [self updatePointerVisibility];
}

- (void)scheduleWindowConfiguration {
    if (self.targetWindowID == 0 || self.targetPID <= 1 ||
        _windowTooSmall || self.bounds.size.width < 64 ||
        self.bounds.size.height < 64) return;
    CGFloat density = self.effectiveDensityScale;
    CGSize requested = {
        self.bounds.size.width / density,
        self.bounds.size.height / density,
    };
    _pendingRequestedWindowSize = requested;
    _pendingRequestedDensityScale = density;
    if (_windowConfigurationDispatchPending) return;
    _windowConfigurationDispatchPending = YES;
    // Stage Manager can report geometry on every display refresh.  Coalesce
    // those callbacks into the newest AppKit size at a bounded 30-Hz rate,
    // rather than waiting for a 180-ms quiet period after the drag.  This
    // preserves AppKit's real minimum-size validation while making the macOS
    // content follow the iPad window continuously.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_windowConfigurationDispatchPending = NO;
        if (self->_windowTooSmall || self.targetPID <= 1 ||
            self.targetWindowID == 0) return;
        CGSize requested = self->_pendingRequestedWindowSize;
        CGFloat density = self->_pendingRequestedDensityScale;
        if (fabs(requested.width - self->_lastRequestedWindowSize.width) < 1.0 &&
            fabs(requested.height - self->_lastRequestedWindowSize.height) < 1.0 &&
            fabs(density - self->_lastRequestedDensityScale) < 0.001) return;
        self->_lastRequestedWindowSize = requested;
        self->_lastRequestedDensityScale = density;
        self->_windowConfigurationAwaitingAcknowledgement = YES;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindConfigureWindow,
            .sceneID = MacWSInputSceneForWindow(self.targetWindowID, 0),
            .timestamp = CACurrentMediaTime(),
            .x = (float)requested.width,
            .y = (float)requested.height,
            .pressure = (float)density,
            .frameWidth = (uint32_t)ceil(requested.width) + 1,
            .frameHeight = (uint32_t)ceil(requested.height) + 1,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceUnknown,
            .flags = MacWSInputFlagConfigureAnchorTopRight,
            .sampleSequence = ++self->_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
        // Electron restores its persisted NSWindow frame after the first
        // DisplayStream/Scene transaction. A single datagram can therefore be
        // accepted and then legitimately superseded. Re-assert the same native
        // frame invariant at three bounded settlement points. A new Scene size,
        // density, target, or suspension changes the serial and cancels these
        // retries; this is not a periodic poll and does not touch WindowServer.
        uint64_t settlementSerial = ++self->_windowConfigurationSettlementSerial;
        const int64_t retryNanoseconds[] = {
            350 * NSEC_PER_MSEC,
            1200 * NSEC_PER_MSEC,
            3000 * NSEC_PER_MSEC,
        };
        for (NSUInteger index = 0;
             index < sizeof(retryNanoseconds) / sizeof(retryNanoseconds[0]);
             index++) {
            int64_t delay = retryNanoseconds[index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                           dispatch_get_main_queue(), ^{
                if (self->_windowConfigurationSettlementSerial !=
                        settlementSerial ||
                    !self->_windowConfigurationAwaitingAcknowledgement ||
                    self->_windowTooSmall || self.targetPID <= 1 ||
                    self.targetWindowID == 0 ||
                    fabs(self->_pendingRequestedWindowSize.width -
                         requested.width) >= 1.0 ||
                    fabs(self->_pendingRequestedWindowSize.height -
                         requested.height) >= 1.0 ||
                    fabs(self->_pendingRequestedDensityScale - density) >=
                         0.001) return;
                MacWSInputRecord retry = record;
                retry.timestamp = CACurrentMediaTime();
                retry.sampleSequence = ++self->_inputSampleSequence;
                [self.statusDelegate metalView:self emittedInput:retry];
            });
        }
    });
}

- (void)refreshPresentationPolicy {
    [self updateWindowTooSmallState];
    [self updateDrawableResolution];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateDrawableResolution];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)updateDrawableResolution {
    CGFloat logicalWidth = ceil(self.bounds.size.width);
    CGFloat logicalHeight = ceil(self.bounds.size.height);
    if (!isfinite(logicalWidth) || !isfinite(logicalHeight) ||
        logicalWidth < 1.0 || logicalHeight < 1.0) return;

    BOOL validatedFullscreenCanvas =
        _streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)];
    BOOL performanceResolution =
        self.presentationResolution ==
            MacWSHostPresentationResolutionPerformance ||
        (self.presentationResolution ==
             MacWSHostPresentationResolutionAutomatic &&
         validatedFullscreenCanvas);
    uint32_t sourceWidth = [self currentFrameWidth];
    uint32_t sourceHeight = [self currentFrameHeight];
    BOOL sourceNativeAvailable = !performanceResolution &&
        _surfaceFrame != nil && sourceWidth > 0 && sourceHeight > 0;

    CGSize target = CGSizeMake(logicalWidth, logicalHeight);
    NSString *policy = performanceResolution
        ? @"performance-logical-one-to-one"
        : @"logical-one-to-one-awaiting-source";
    if (sourceNativeAvailable) {
        // Do not allocate more presentation pixels than the UIKit Scene can
        // physically display. The normal desktop is 2388x1668 inside a
        // 2778x1940 Scene, so this preserves every producer pixel exactly.
        // A future oversized/external-display source is fitted once here
        // instead of asking iPadOS to downsample another oversized drawable.
        UIScreen *screen = self.window.windowScene.screen ?: UIScreen.mainScreen;
        CGFloat displayScale = screen.scale;
        if (!isfinite(displayScale) || displayScale < 1.0)
            displayScale = self.contentScaleFactor;
        if (!isfinite(displayScale) || displayScale < 1.0)
            displayScale = 1.0;
        CGFloat maximumWidth = logicalWidth * displayScale;
        CGFloat maximumHeight = logicalHeight * displayScale;
        CGFloat fit = fmin(1.0, fmin(maximumWidth / sourceWidth,
                                    maximumHeight / sourceHeight));
        if (!isfinite(fit) || fit <= 0.0) fit = 1.0;
        target = CGSizeMake(round(sourceWidth * fit),
                            round(sourceHeight * fit));
        policy = self.presentationResolution ==
                MacWSHostPresentationResolutionSourceNative
            ? @"source-native-forced" : @"source-native-auto";
    }
    CGSize previous = self.drawableSize;
    if (fabs(previous.width - target.width) < 0.5 &&
        fabs(previous.height - target.height) < 0.5) return;
    self.drawableSize = target;
    MacWSLog(@"host-drawable-policy bounds=%.0fx%.0f previous=%.0fx%.0f "
             "source=%ux%u drawable=%.0fx%.0f policy=%@ "
             "fullscreen-canvas=%@",
             self.bounds.size.width, self.bounds.size.height,
             previous.width, previous.height, sourceWidth, sourceHeight,
             target.width, target.height, policy,
             validatedFullscreenCanvas ? @"YES" : @"NO");
}

- (void)geometryDidChange {
    // Geometry changes invalidate the view-to-surface transform immediately;
    // do not leave an old down/scroll sequence alive across rotation or a
    // Stage Manager resize.
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_trackpadTouch && _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _directTouchSerial++;
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directGestureBlocked = NO;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadHadMultipleTouches = NO;
    [self stopScrollMomentumWithTerminalPhase:YES];
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    [self hideMultitouchIndicators];
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)setMacWSInputEnabled:(BOOL)enabled {
    [self setMacWSInputEnabled:enabled reason:nil];
}

- (BOOL)isMacWSInputEnabled {
    return _macWSInputEnabled && !_windowTooSmall;
}

- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason {
    if (!enabled && _macWSInputEnabled) {
        if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
            [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                     point:[_directTouch locationInView:self]];
        } else if (_directTouch &&
                   _directTouchState == MacWSDirectTouchStateScrolling) {
            [self emitScrollAtFramePoint:_directScrollFramePoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
        }
        if (_trackpadTouch && _trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:CACurrentMediaTime()];
        }
        _directTouchSerial++;
        _directTouch = nil;
        _directTouchState = MacWSDirectTouchStateIdle;
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self stopScrollMomentumWithTerminalPhase:YES];
        [self setDirectTouchHeld:NO dragging:NO animated:NO];
        [self hideMultitouchIndicators];
        [self setTrackpadPointerPressed:NO animated:NO];
    }
    _macWSInputEnabled = enabled;
    if (!enabled) {
        _directTouchIndicator.hidden = YES;
        _trackpadCursorView.hidden = YES;
        _inputUnavailableLabel.text = [NSString stringWithFormat:
            @"触控暂不可用 · %@", reason.length ? reason : @"工作区未就绪"];
    }
    [self updateWindowTooSmallState];
    [self updatePointerVisibility];
}

- (void)setInputMode:(MacWSHostInputMode)inputMode {
    if (inputMode != MacWSHostInputModeDirect &&
        inputMode != MacWSHostInputModeTrackpad) return;
    if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
        _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_inputMode == MacWSHostInputModeTrackpad && _trackpadTouch &&
        _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _inputMode = inputMode;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadTravel = 0;
    _trackpadHadMultipleTouches = NO;
    _trackpadCursorWasTouched = NO;
    _externalPointerHoverActive = NO;
    _directTouch = nil;
    _directGestureBlocked = NO;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directTouchSerial++;
    [self stopScrollMomentumWithTerminalPhase:YES];
    _directTouchIndicator.hidden = YES;
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePointerVisibility];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (BOOL)restoreHardwareKeyboardFocusWithReason:(NSString *)reason {
    if (self.softwareKeyboardActive || !self.window ||
        !self.isMacWSInputEnabled) return NO;
    BOOL alreadyFocused = self.isFirstResponder;
    BOOL focused = alreadyFocused || [self becomeFirstResponder];
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-focus reason=%@ focused=%@ already=%@ "
                  "scene-active=%ld target=%d frame=%ux%u",
                 reason ?: @"unspecified", focused ? @"YES" : @"NO",
                 alreadyFocused ? @"YES" : @"NO",
                 (long)self.window.windowScene.activationState,
                 self.targetPID, [self currentFrameWidth],
                 [self currentFrameHeight]);
    }
    return focused;
}

- (BOOL)emitKeyPresses:(NSSet<UIPress *> *)presses kind:(MacWSInputKind)kind {
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-callback kind=%u presses=%lu responder=%@ "
                  "input-enabled=%@ target=%d frame=%ux%u",
                 kind, (unsigned long)presses.count,
                 self.isFirstResponder ? @"YES" : @"NO",
                 self.isMacWSInputEnabled ? @"YES" : @"NO",
                 self.targetPID, [self currentFrameWidth],
                 [self currentFrameHeight]);
    }
    if (!self.isMacWSInputEnabled) return NO;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width != 0 && height != 0) {
        _lastKeyboardFrameWidth = width;
        _lastKeyboardFrameHeight = height;
    } else {
        // DisplayStream retires the old surface before publishing the resized
        // successor. Runtime log 1788371421.797 captured a real hardware key
        // callback in that interval with input enabled and target PID stable,
        // but frame=0x0 made the key disappear. Keyboard dispatch does not use
        // the pointer coordinates; retain only the same target's last valid
        // dimensions so a geometry handoff cannot swallow physical keys.
        width = _lastKeyboardFrameWidth;
        height = _lastKeyboardFrameHeight;
    }
    if (width == 0 || height == 0) return NO;
    BOOL emitted = NO;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        uint16_t keyCode = MacWSMacKeyCodeForHIDUsage(key.keyCode);
        if (keyCode == UINT16_MAX) continue;
        // sceneID forwards UIKit's modifier flags to AppKit as the authority
        // for Shift/Caps/Option state. If UIKit supplies a pre-transformed
        // `characters` value while declaring none of those text modifiers,
        // forwarding that transformed scalar makes the remote application
        // type uppercase even though its NSEvent has no Shift/Caps flag. Use
        // the layout-aware unmodified value in precisely that inconsistent
        // state; real Shift, Caps Lock and Option input continues to use
        // UIKit's transformed characters unchanged.
        UIKeyModifierFlags textModifiers = UIKeyModifierShift |
            UIKeyModifierAlphaShift | UIKeyModifierAlternate;
        NSString *mappedCharacters = key.characters;
        if ((key.modifierFlags & textModifiers) == 0 &&
            key.charactersIgnoringModifiers.length != 0) {
            mappedCharacters = key.charactersIgnoringModifiers;
        }
        uint32_t keySym = MacWSKeySymForHIDUsage(
            key.keyCode, mappedCharacters, key.modifierFlags);
        if (keySym == 0) continue;
        if (MacWSHostDiagnosticsEnabled()) {
            MacWSLog(@"hardware-key-map kind=%u usage=%ld keycode=%u "
                     "characters=%@ ignoring=%@ mapped=%@ modifiers=%#lx "
                     "keysym=%#x",
                     kind, (long)key.keyCode, keyCode,
                     key.characters ?: @"", key.charactersIgnoringModifiers ?: @"",
                     mappedCharacters ?: @"",
                     (unsigned long)key.modifierFlags, keySym);
        }
        CGPoint keyPoint = _trackpadCursor;
        if (keyPoint.x < 0 || keyPoint.y < 0 ||
            keyPoint.x >= width || keyPoint.y >= height)
            keyPoint = CGPointMake(width * 0.5, height * 0.5);
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            // AppInputBridge's established v3 keyboard ABI stores AppKit-
            // compatible modifier bits in sceneID's low 32 bits.
            .sceneID = [self inputSceneIDWithModifiers:
                (uint32_t)key.modifierFlags],
            .timestamp = press.timestamp,
            .x = (float)keyPoint.x,
            .y = (float)keyPoint.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceHardwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
        emitted = YES;
    }
    return emitted;
}

- (BOOL)forwardHardwarePresses:(NSSet<UIPress *> *)presses
                       keyDown:(BOOL)keyDown {
    return [self emitKeyPresses:presses
                           kind:keyDown ? MacWSInputKindKeyDown
                                        : MacWSInputKindKeyUp];
}

- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers {
    if (!self.isMacWSInputEnabled || keySym == 0) return;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width != 0 && height != 0) {
        _lastKeyboardFrameWidth = width;
        _lastKeyboardFrameHeight = height;
    } else {
        width = _lastKeyboardFrameWidth;
        height = _lastKeyboardFrameHeight;
    }
    if (width == 0 || height == 0) return;
    uint32_t scalar = (keySym & 0xff000000u) == 0x01000000u
        ? keySym & 0x00ffffffu : keySym;
    NSInteger usage = MacWSHIDUsageForASCII(scalar);
    uint16_t keyCode = usage >= 0
        ? MacWSMacKeyCodeForHIDUsage(usage) : 0;
    switch (keySym) {
        case 0xff08: keyCode = 51; break;
        case 0xff09: keyCode = 48; break;
        case 0xff0d: keyCode = 36; break;
        case 0xff1b: keyCode = 53; break;
        case 0xff51: keyCode = 123; break;
        case 0xff52: keyCode = 126; break;
        case 0xff53: keyCode = 124; break;
        case 0xff54: keyCode = 125; break;
        default: break;
    }
    CGPoint point = _trackpadCursor;
    if (point.x < 0 || point.y < 0 || point.x >= width || point.y >= height)
        point = CGPointMake(width * 0.5, height * 0.5);
    for (MacWSInputKind kind = MacWSInputKindKeyDown;
         kind <= MacWSInputKindKeyUp; kind++) {
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            .sceneID = [self inputSceneIDWithModifiers:modifiers],
            .timestamp = CACurrentMediaTime(),
            .x = (float)point.x,
            .y = (float)point.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceSoftwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
    }
}

- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers {
    if (!text.length) return;
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *scalars = utf32.bytes;
    for (NSUInteger index = 0; index < utf32.length / sizeof(uint32_t); index++) {
        uint32_t scalar = scalars[index];
        uint32_t keySym = scalar > 0xffu ? 0x01000000u | scalar : scalar;
        if (scalar == '\n' || scalar == '\r') keySym = 0xff0d;
        else if (scalar == '\t') keySym = 0xff09;
        else if (scalar == '\b') keySym = 0xff08;
        [self emitSoftwareKeySym:keySym modifiers:modifiers];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyDown];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
                withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesCancelled:presses withEvent:event];
}

- (void)buildPipeline {
    if (!self.device) {
        [self publishStatus:@"此设备没有可用的原生 Metal Device"];
        return;
    }
    static NSString *const shaderSource =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 position [[position]]; float2 uv; };\n"
         "vertex VOut macws_vertex(uint vid [[vertex_id]],\n"
         "    constant float4 *vertices [[buffer(0)]]) {\n"
         "  VOut o; o.position = float4(vertices[vid].xy, 0.0, 1.0);\n"
         "  o.uv = vertices[vid].zw; return o;\n"
         "}\n"
         "fragment half4 macws_fragment(VOut in [[stage_in]],\n"
         "    texture2d<half> image [[texture(0)]]) {\n"
         "  constexpr sampler s(coord::normalized, address::clamp_to_edge,\n"
         "                      filter::linear);\n"
         "  return image.sample(s, in.uv);\n"
         "}\n"
         "fragment half4 macws_fragment_opaque(VOut in [[stage_in]],\n"
         "    texture2d<half> image [[texture(0)]]) {\n"
         "  constexpr sampler s(coord::normalized, address::clamp_to_edge,\n"
         "                      filter::linear);\n"
         "  half4 pixel = image.sample(s, in.uv);\n"
         "  return half4(pixel.rgb, 1.0h);\n"
         "}\n"
         "fragment half4 macws_shadow(VOut in [[stage_in]],\n"
         "    constant float4 *geometry [[buffer(0)]]) {\n"
         "  float2 quad = geometry[0].xy;\n"
         "  float2 innerOrigin = geometry[0].zw;\n"
         "  float2 innerSize = geometry[1].xy;\n"
         "  float radius = geometry[1].z;\n"
         "  float sigma = geometry[1].w;\n"
         "  float2 p = in.uv * quad - (innerOrigin + innerSize * 0.5);\n"
         "  float2 q = abs(p) - (innerSize * 0.5 - radius);\n"
         "  float distance = length(max(q, 0.0))\n"
         "      + min(max(q.x, q.y), 0.0) - radius;\n"
         "  float outside = max(distance, 0.0);\n"
         "  half alpha = half(0.30 * exp(-(outside * outside)\n"
         "      / (2.0 * sigma * sigma)));\n"
         "  return half4(0.0h, 0.0h, 0.0h, alpha);\n"
         "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource
                                                      options:nil error:&error];
    if (!library) {
        [self publishStatus:[NSString stringWithFormat:@"Metal shader 编译失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
        return;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"MacWSHost BGRA display pipeline";
    descriptor.vertexFunction = [library newFunctionWithName:@"macws_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"macws_fragment"];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
    if (!_pipeline) {
        [self publishStatus:[NSString stringWithFormat:@"Metal pipeline 创建失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
    }
    // A validated FullscreenCanvas is an opaque display authority.  Its
    // CAMetalLayer backing can nevertheless retain non-255 alpha values that
    // are meaningful inside the producer but are not a request to blend an
    // obsolete WindowServer snapshot behind the fullscreen game.  Keep the
    // ordinary premultiplied-alpha pipeline for desktop/native windows and
    // use this sibling only after the exact fullscreen drawable join.
    descriptor.label = @"MacWSHost opaque fullscreen drawable pipeline";
    // Runtime-confirmed from Stray pid 9198 drawable surface 687 on
    // 2026-08-29: all 1,296,000 alpha bytes are zero while every RGB pixel is
    // nonzero and contains the complete game scene. Disabling blending alone
    // copies that zero alpha into the CAMetalDrawable, so the downstream
    // UIKit compositor treats the otherwise-correct game pixels as
    // transparent. FullscreenCanvas is already the exact opaque authority;
    // make its output alpha match that semantic ownership.
    descriptor.fragmentFunction =
        [library newFunctionWithName:@"macws_fragment_opaque"];
    descriptor.colorAttachments[0].blendingEnabled = NO;
    _opaquePipeline = [self.device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_opaquePipeline) {
        [self publishStatus:[NSString stringWithFormat:
            @"全屏 drawable pipeline 创建失败: %@",
            error.localizedDescription ?: @"未知错误"]];
    }
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.label = @"MacWSHost native-window shadow pipeline";
    descriptor.fragmentFunction = [library newFunctionWithName:@"macws_shadow"];
    _shadowPipeline = [self.device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_shadowPipeline) {
        [self publishStatus:[NSString stringWithFormat:
            @"窗口阴影 pipeline 创建失败: %@",
            error.localizedDescription ?: @"未知错误"]];
    }
}

- (void)publishStatus:(NSString *)status {
    if (!status || [_lastStatus isEqualToString:status]) return;
    _lastStatus = [status copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusDelegate metalView:self statusChanged:status];
    });
}

- (BOOL)ensureSourceTexture {
    if (_sourceTexture && _textureWidth == _frame.width &&
        _textureHeight == _frame.height) return YES;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:_frame.width
                                                          height:_frame.height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    _sourceTexture = [self.device newTextureWithDescriptor:descriptor];
    _sourceTexture.label = @"MacWSHost mmap upload";
    _textureWidth = _frame.width;
    _textureHeight = _frame.height;
    _reportedNonzeroFrame = NO;
    return _sourceTexture != nil;
}

- (void)updateContentRectAndVertices:(simd_float4 [4])vertices {
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];

    // A low-resolution game window remains a real layer inside the native
    // full-resolution desktop.  For bundle-declared fullscreen canvases,
    // crop the completed WindowServer composite to that exact layer's
    // destination and fit it to the iPad Scene.  Because _visibleSourceRect
    // is also the input transform below, keyboard/pointer activation and
    // pixels retain one coordinate authority.  The source is still the final
    // composite, so Steam's separately composited FPS panel is preserved.
    CGRect fullscreenCanvasPixels = CGRectZero;
    BOOL focusFullscreenCanvas = NO;
    uint32_t fullscreenCanvasWindowID = 0;
    if (_viewportZoom <= 1.001 &&
        _streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)] &&
        [self hasFinalCompositeFrame] && frameWidth > 0 && frameHeight > 0) {
        uint32_t preferredWindowID = 0;
        uint64_t preferredScore = 0;
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            // During Stray's AppKit fullscreen transition the live catalog
            // publishes 0x140 (Focused|FullscreenCanvas) without the ordinary
            // ordered-window Visible/OnScreen bits. The matching live layer
            // below remains the pixel/geometry witness; rejecting that exact
            // bundle capability here collapsed presentation back to the
            // uncropped desktop even while its 1024x768 stream advanced.
            if (descriptor.ownerPID != self.targetPID ||
                descriptor.windowID == 0 ||
                (descriptor.flags & MacWSStreamWindowFullscreenCanvas) == 0)
                continue;
            uint64_t area = (uint64_t)descriptor.pixelWidth *
                (uint64_t)descriptor.pixelHeight;
            uint64_t score = area +
                ((descriptor.flags & MacWSStreamWindowFocused) != 0
                    ? UINT64_C(1) << 62 : 0);
            if (score > preferredScore) {
                preferredScore = score;
                preferredWindowID = descriptor.windowID;
            }
        }
        MacWSSurfaceFrame *layer = preferredWindowID != 0
            ? _overlayFrames[@(preferredWindowID)] : nil;
        if (!layer) {
            // SkyLight can retire the AppKit window ID that published the
            // capability while immediately replacing it with a new backing
            // layer for the same process. Follow only this already-validated
            // target PID and choose its largest current surface; do not infer
            // game identity from names, titles or dimensions.
            uint64_t largestArea = 0;
            for (MacWSSurfaceFrame *candidateLayer in
                    _overlayFrames.allValues) {
                MacWSStreamFrameDescriptor candidateDescriptor =
                    candidateLayer.descriptor;
                if (candidateDescriptor.layerOwnerPID != self.targetPID ||
                    candidateDescriptor.layerWindowID == 0) continue;
                uint64_t area =
                    (uint64_t)candidateDescriptor.destinationWidth *
                    (uint64_t)candidateDescriptor.destinationHeight;
                if (area > largestArea) {
                    largestArea = area;
                    layer = candidateLayer;
                }
            }
        }
        if (layer) {
            MacWSStreamFrameDescriptor descriptor = layer.descriptor;
            CGRect canvas = CGRectMake(0, 0, frameWidth, frameHeight);
            CGRect candidate = CGRectMake(
                descriptor.destinationX, descriptor.destinationY,
                descriptor.destinationWidth, descriptor.destinationHeight);
            candidate = CGRectIntersection(candidate, canvas);
            if (descriptor.layerOwnerPID == self.targetPID &&
                descriptor.layerWindowID != 0 &&
                !CGRectIsNull(candidate) && !CGRectIsEmpty(candidate) &&
                candidate.size.width >= 320.0 &&
                candidate.size.height >= 240.0) {
                fullscreenCanvasPixels = candidate;
                focusFullscreenCanvas = YES;
                fullscreenCanvasWindowID = descriptor.layerWindowID;
            }
        }
    }
    // SkyLight can retire the exact fullscreen layer after it has handed the
    // Catalyst CAMetalLayer off to the Host.  Runtime-confirmed by
    // MacWSHost.log for Stray pid 16096 on 2026-08-25: window 188 was first
    // validated as Focused|FullscreenCanvas, then the catalog and overlay
    // entries both disappeared while the same AppInput endpoint and completed
    // 1400x900 drawable continued.  Retain the already-validated geometry
    // across only that window-generation gap.  Target changes, capability
    // revocation, or endpoint death invalidate it independently.
    BOOL preserveFullscreenCanvasIdentity =
        _reportedFullscreenCanvasPID == self.targetPID &&
        _reportedFullscreenCanvasWindowID != 0 &&
        !CGRectIsEmpty(_reportedFullscreenCanvasPixels) &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)];
    BOOL retainedFullscreenCanvas = !focusFullscreenCanvas &&
        preserveFullscreenCanvasIdentity &&
        MacWSAppInputEndpointReady(self.targetPID) &&
        [self hasFinalCompositeFrame] && frameWidth > 0 && frameHeight > 0;
    if (retainedFullscreenCanvas) {
        CGRect canvas = CGRectMake(0, 0, frameWidth, frameHeight);
        CGRect retained = CGRectIntersection(
            _reportedFullscreenCanvasPixels, canvas);
        if (!CGRectIsNull(retained) && !CGRectIsEmpty(retained)) {
            fullscreenCanvasPixels = retained;
            fullscreenCanvasWindowID = _reportedFullscreenCanvasWindowID;
            focusFullscreenCanvas = YES;
        }
    }
    if (focusFullscreenCanvas && viewWidth > 0 && viewHeight > 0) {
        if (_reportedFullscreenCanvasPID != self.targetPID ||
            _reportedFullscreenCanvasWindowID != fullscreenCanvasWindowID) {
            _reportedFullscreenCanvasPID = self.targetPID;
            _reportedFullscreenCanvasWindowID = fullscreenCanvasWindowID;
            MacWSLog(@"runtime-confirmed fullscreen-canvas-focus pid=%d "
                     "window=%u source=(%.0f,%.0f %.0fx%.0f) "
                     "desktop=%ux%u",
                     self.targetPID, fullscreenCanvasWindowID,
                     fullscreenCanvasPixels.origin.x,
                     fullscreenCanvasPixels.origin.y,
                     fullscreenCanvasPixels.size.width,
                     fullscreenCanvasPixels.size.height,
                     frameWidth, frameHeight);
        }
        _reportedFullscreenCanvasPixels = fullscreenCanvasPixels;
        CGFloat pixelScaleX = self.drawableSize.width > 0
            ? self.drawableSize.width / viewWidth : self.contentScaleFactor;
        CGFloat pixelScaleY = self.drawableSize.height > 0
            ? self.drawableSize.height / viewHeight : self.contentScaleFactor;
        if (!isfinite(pixelScaleX) || pixelScaleX <= 0) pixelScaleX = 1.0;
        if (!isfinite(pixelScaleY) || pixelScaleY <= 0) pixelScaleY = 1.0;
        CGFloat viewPixelWidth = viewWidth * pixelScaleX;
        CGFloat viewPixelHeight = viewHeight * pixelScaleY;
        CGFloat scale = MIN(
            viewPixelWidth / fullscreenCanvasPixels.size.width,
            viewPixelHeight / fullscreenCanvasPixels.size.height);
        CGFloat fittedPixelWidth =
            round(fullscreenCanvasPixels.size.width * scale);
        CGFloat fittedPixelHeight =
            round(fullscreenCanvasPixels.size.height * scale);
        _contentRect = CGRectMake(
            round((viewPixelWidth - fittedPixelWidth) * 0.5) / pixelScaleX,
            round((viewPixelHeight - fittedPixelHeight) * 0.5) / pixelScaleY,
            fittedPixelWidth / pixelScaleX,
            fittedPixelHeight / pixelScaleY);
        _visibleSourceRect = CGRectMake(
            fullscreenCanvasPixels.origin.x / frameWidth,
            fullscreenCanvasPixels.origin.y / frameHeight,
            fullscreenCanvasPixels.size.width / frameWidth,
            fullscreenCanvasPixels.size.height / frameHeight);
        _viewportCenter = CGPointMake(CGRectGetMidX(_visibleSourceRect),
                                      CGRectGetMidY(_visibleSourceRect));
        CGFloat left = CGRectGetMinX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat right = CGRectGetMaxX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat top = 1.0 - CGRectGetMinY(_contentRect) / viewHeight * 2.0;
        CGFloat bottom = 1.0 - CGRectGetMaxY(_contentRect) / viewHeight * 2.0;
        CGFloat minX = CGRectGetMinX(_visibleSourceRect);
        CGFloat maxX = CGRectGetMaxX(_visibleSourceRect);
        CGFloat minY = CGRectGetMinY(_visibleSourceRect);
        CGFloat maxY = CGRectGetMaxY(_visibleSourceRect);
        vertices[0] = (simd_float4){left, bottom, minX, maxY};
        vertices[1] = (simd_float4){right, bottom, maxX, maxY};
        vertices[2] = (simd_float4){left, top, minX, minY};
        vertices[3] = (simd_float4){right, top, maxX, minY};
        return;
    }
    if (_reportedFullscreenCanvasWindowID != 0 &&
        !preserveFullscreenCanvasIdentity) {
        MacWSLog(@"fullscreen-canvas-focus cleared pid=%d window=%u",
                 _reportedFullscreenCanvasPID,
                 _reportedFullscreenCanvasWindowID);
        _reportedFullscreenCanvasPID = 0;
        _reportedFullscreenCanvasWindowID = 0;
        _reportedFullscreenCanvasPixels = CGRectZero;
    }
    // At 1x, preserve the complete macOS window. A Scene aspect mismatch may
    // add small margins, but must never crop title bars, traffic lights, or
    // resize edges. This invariant also applies while AppKit is producing the
    // replacement IOSurface during a Stage Manager or orientation resize: an
    // old correctly proportioned frame may letterbox briefly, but is never
    // stretched. Deliberate 1.5x/2x zoom uses the crop/pan path below.
    if (_viewportZoom <= 1.001 && frameWidth > 0 && frameHeight > 0 &&
        viewWidth > 0 && viewHeight > 0) {
        CGFloat pixelScaleX = self.drawableSize.width > 0
            ? self.drawableSize.width / viewWidth : self.contentScaleFactor;
        CGFloat pixelScaleY = self.drawableSize.height > 0
            ? self.drawableSize.height / viewHeight : self.contentScaleFactor;
        if (!isfinite(pixelScaleX) || pixelScaleX <= 0) pixelScaleX = 1.0;
        if (!isfinite(pixelScaleY) || pixelScaleY <= 0) pixelScaleY = 1.0;
        CGFloat viewPixelWidth = viewWidth * pixelScaleX;
        CGFloat viewPixelHeight = viewHeight * pixelScaleY;
        CGFloat scale = MIN(viewPixelWidth / frameWidth,
                            viewPixelHeight / frameHeight);
        CGFloat fittedPixelWidth = round(frameWidth * scale);
        CGFloat fittedPixelHeight = round(frameHeight * scale);
        CGFloat originPixelX = round((viewPixelWidth - fittedPixelWidth) * 0.5);
        CGFloat originPixelY = round((viewPixelHeight - fittedPixelHeight) * 0.5);
        _contentRect = CGRectMake(originPixelX / pixelScaleX,
                                  originPixelY / pixelScaleY,
                                  fittedPixelWidth / pixelScaleX,
                                  fittedPixelHeight / pixelScaleY);
        _visibleSourceRect = CGRectMake(0, 0, 1, 1);
        _viewportCenter = CGPointMake(0.5, 0.5);
        _viewportZoom = 1.0;
        CGFloat left = CGRectGetMinX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat right = CGRectGetMaxX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat top = 1.0 - CGRectGetMinY(_contentRect) / viewHeight * 2.0;
        CGFloat bottom = 1.0 - CGRectGetMaxY(_contentRect) / viewHeight * 2.0;
        vertices[0] = (simd_float4){left, bottom, 0, 1};
        vertices[1] = (simd_float4){right, bottom, 1, 1};
        vertices[2] = (simd_float4){left, top, 0, 0};
        vertices[3] = (simd_float4){right, top, 1, 0};
        return;
    }
    MacWSViewport viewport = {0};
    BOOL valid = MacWSComputeViewport(
        frameWidth, frameHeight, viewWidth, viewHeight, _viewportZoom,
        _viewportCenter.x, _viewportCenter.y, &viewport);
    if (!valid) {
        viewport = (MacWSViewport){
            .visibleSource = {0, 0, 1, 1},
            .centerX = 0.5,
            .centerY = 0.5,
            .zoom = 1.0,
        };
    }
    _viewportZoom = viewport.zoom;
    _viewportCenter = CGPointMake(viewport.centerX, viewport.centerY);
    _visibleSourceRect = CGRectMake(
        viewport.visibleSource.x, viewport.visibleSource.y,
        viewport.visibleSource.width, viewport.visibleSource.height);
    _contentRect = self.bounds;
    CGFloat minX = CGRectGetMinX(_visibleSourceRect);
    CGFloat maxX = CGRectGetMaxX(_visibleSourceRect);
    CGFloat minY = CGRectGetMinY(_visibleSourceRect);
    CGFloat maxY = CGRectGetMaxY(_visibleSourceRect);
    // A user-requested enlarged view fills the Scene and pans over a bounded
    // source crop.
    vertices[0] = (simd_float4){-1, -1, minX, maxY};
    vertices[1] = (simd_float4){ 1, -1, maxX, maxY};
    vertices[2] = (simd_float4){-1,  1, minX, minY};
    vertices[3] = (simd_float4){ 1,  1, maxX, minY};
}

- (void)updatePresentationGeometry {
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    [self updatePointerVisibility];
}

- (BOOL)frameHasSampledContent {
    if (!_frame.pixels) return NO;
    size_t samples = 128;
    for (size_t i = 0; i < samples; i++) {
        size_t x = (i * 7919u) % _frame.width;
        size_t y = (i * 104729u) % _frame.height;
        const uint8_t *pixel = _frame.pixels + y * _frame.stride + x * 4;
        if (pixel[0] || pixel[1] || pixel[2]) return YES;
    }
    return NO;
}

- (uint64_t)fallbackFrameSignature {
    uint64_t hash = 1469598103934665603ull;
    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    size_t step = payloadSize / 4096;
    if (step < 4) step = 4;
    for (size_t offset = 0; offset < payloadSize; offset += step) {
        hash ^= _frame.pixels[offset];
        hash *= 1099511628211ull;
    }
    hash ^= ((uint64_t)_frame.width << 32) | _frame.height;
    return hash;
}

- (void)pollSharedFrame:(CADisplayLink *)displayLink {
    (void)displayLink;
    uint64_t generation = 0;
    if (!MacWSReadCaptureAck(&generation)) {
        if (_presentedCaptureGeneration != 0 ||
            _pendingCaptureGeneration != 0) {
            _presentedCaptureGeneration = 0;
            _pendingCaptureGeneration = 0;
            _fallbackImageView.image = nil;
            (void)[_frame refresh];
            if (self.device) [self setNeedsDisplay];
            [self publishStatus:_frame.lastError ?: @"等待已确认的共享帧"];
        }
        return;
    }
    if (generation == _presentedCaptureGeneration) return;
    if (generation != _pendingCaptureGeneration)
        _pendingCaptureGeneration = generation;
    if (self.device) {
        [self setNeedsDisplay];
    } else {
        [self drawFallbackFrame];
    }
}

- (void)drawFallbackFrame {
    if (![_frame refresh]) {
        [self publishStatus:_frame.lastError ?: @"等待共享帧"];
        return;
    }
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    uint64_t signature = [self fallbackFrameSignature];
    if (_fallbackImageView.image && signature == _fallbackSignature) {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  像素未变化",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
        return;
    }

    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    NSData *snapshot = [NSData dataWithBytes:_frame.pixels length:payloadSize];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)snapshot);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little |
        kCGImageAlphaPremultipliedFirst;
    CGImageRef image = CGImageCreate(_frame.width, _frame.height, 8, 32,
        _frame.stride, colorSpace, bitmapInfo, provider, NULL, false,
        kCGRenderingIntentDefault);
    if (image) {
        _fallbackImageView.image = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
        _fallbackSignature = signature;
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        BOOL nonzero = [self frameHasSampledContent];
        if (nonzero && !_reportedFallbackFrame) {
            _reportedFallbackFrame = YES;
            MacWSLog(@"runtime-confirmed UIKit fallback frame nonzero %ux%u stride=%u",
                     _frame.width, _frame.height, _frame.stride);
        }
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  UIKit fallback",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
    } else {
        [self publishStatus:@"UIKit fallback 无法创建 BGRA 图像"];
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_pipeline || !_commandQueue) return;
    BOOL drewCatalystDrawable = NO;
    MacWSCatalystDrawableFrame *catalystWitnessFrame = nil;
    // A newly delivered producer frame can replace the compositor's current
    // dictionary entry while this command buffer is still reading the old
    // IOSurface texture.  Retain every exact frame encoded below until Metal
    // completes this Host submission; the frame owns the producer-transferred
    // IOSurface use count.
    NSMutableArray<MacWSCatalystDrawableFrame *> *submittedCatalystFrames =
        [NSMutableArray array];
    BOOL directSurface = _surfaceFrame != nil && _surfaceTexture != nil;
    BOOL finalComposite = directSurface &&
        (_surfaceFrame.descriptor.flags &
            MacWSStreamFrameFinalComposite) != 0;
    CFTimeInterval directHeartbeatAge =
        CACurrentMediaTime() - _lastDirectDrawableHeartbeatTime;
    MacWSSurfaceFrame *fullscreenDirectLayer =
        _directDrawableHeartbeatLayerID != 0
            ? _overlayFrames[@(_directDrawableHeartbeatLayerID)] : nil;
    MacWSCatalystDrawableFrame *fullscreenDirectFrame =
        [_catalystDrawableCompositor frameForOwnerPID:self.targetPID];
    MacWSStreamFrameDescriptor fullscreenDirectDescriptor =
        fullscreenDirectLayer
            ? fullscreenDirectLayer.descriptor
            : (MacWSStreamFrameDescriptor){0};
    BOOL retainedFullscreenDirectIdentity = !fullscreenDirectLayer &&
        self.targetPID > 1 &&
        _reportedFullscreenCanvasPID == self.targetPID &&
        _reportedFullscreenCanvasWindowID != 0 &&
        _directDrawableHeartbeatLayerID ==
            _reportedFullscreenCanvasWindowID &&
        !CGRectIsEmpty(_reportedFullscreenCanvasPixels) &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)] &&
        MacWSAppInputEndpointReady(self.targetPID);
    BOOL controllerValidatedFullscreenIdentity =
        _reportedFullscreenCanvasPID == self.targetPID &&
        _reportedFullscreenCanvasWindowID != 0 &&
        _reportedFullscreenCanvasWindowID ==
            _directDrawableHeartbeatLayerID &&
        !CGRectIsEmpty(_reportedFullscreenCanvasPixels) &&
        MacWSAppInputEndpointReady(self.targetPID);
    BOOL fullscreenDirectAuthoritative =
        _opaquePipeline && fullscreenDirectFrame.texture &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)] &&
        _directDrawableHeartbeatPID == self.targetPID &&
        controllerValidatedFullscreenIdentity &&
        ((fullscreenDirectDescriptor.layerOwnerPID == self.targetPID &&
          fullscreenDirectDescriptor.layerWindowID ==
              _directDrawableHeartbeatLayerID) ||
         retainedFullscreenDirectIdentity) &&
        _lastDirectDrawableHeartbeatTime > 0.0 &&
        directHeartbeatAge >= 0.0 && directHeartbeatAge <= 3.0;
    if (directSurface) {
        _sourceTexture = _surfaceTexture;
    } else {
        if (self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled()) {
            [self publishStatus:self.targetWindowID != 0
                ? @"等待该窗口的 DisplayStream IOSurface 直传帧"
                : @"等待全屏 DisplayStream IOSurface 直传帧"];
            // MTKView retains its previous drawable if no command buffer is
            // submitted.  During a window -> fullscreen Scene transaction
            // iPadOS then scales that old window-sized drawable to the panel,
            // which looks like a cropped desktop and cannot share the new
            // input coordinate generation.  Clear through the real Metal
            // render pass while waiting; the first new IOSurface replaces it
            // through the normal draw path below.
            MTLRenderPassDescriptor *waitingPass =
                view.currentRenderPassDescriptor;
            id<CAMetalDrawable> waitingDrawable = view.currentDrawable;
            if (waitingPass && waitingDrawable) {
                waitingPass.colorAttachments[0].loadAction =
                    MTLLoadActionClear;
                waitingPass.colorAttachments[0].storeAction =
                    MTLStoreActionStore;
                waitingPass.colorAttachments[0].clearColor =
                    MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
                id<MTLCommandBuffer> waitingBuffer =
                    [_commandQueue commandBuffer];
                id<MTLRenderCommandEncoder> waitingEncoder =
                    [waitingBuffer renderCommandEncoderWithDescriptor:
                        waitingPass];
                [waitingEncoder endEncoding];
                [waitingBuffer presentDrawable:waitingDrawable];
                [waitingBuffer commit];
            }
            return;
        }
        if (![_frame refresh]) {
            [self publishStatus:_frame.lastError ?: @"等待共享帧"];
            return;
        }
        if (![self ensureSourceTexture]) {
            [self publishStatus:@"无法创建帧上传纹理"];
            return;
        }

        MTLRegion region = MTLRegionMake2D(0, 0, _frame.width, _frame.height);
        [_sourceTexture replaceRegion:region mipmapLevel:0 withBytes:_frame.pixels
                          bytesPerRow:_frame.stride];

        if (!_reportedNonzeroFrame && [self frameHasSampledContent]) {
            _reportedNonzeroFrame = YES;
            MacWSLog(@"runtime-confirmed source frame nonzero %ux%u stride=%u path=%@",
                     _frame.width, _frame.height, _frame.stride, MacWSFramePath);
        }
    }

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    if (fullscreenDirectAuthoritative) {
        // The exact fullscreen drawable will cover the semantic game canvas.
        // Clear any letterbox outside it and do not shade the retained desktop
        // final composite underneath a layer that is already authoritative.
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    }
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    simd_float4 vertices[4];
    [self updateContentRectAndVertices:vertices];
    if (directSurface) {
        MacWSStreamFrameDescriptor descriptor = _surfaceFrame.descriptor;
        float originU = descriptor.contentX / (float)descriptor.width;
        float originV = descriptor.contentY / (float)descriptor.height;
        float scaleU = descriptor.contentWidth / (float)descriptor.width;
        float scaleV = descriptor.contentHeight / (float)descriptor.height;
        for (NSUInteger index = 0; index < 4; index++) {
            vertices[index].z = originU + vertices[index].z * scaleU;
            vertices[index].w = originV + vertices[index].w * scaleV;
        }
    }
    if (!fullscreenDirectAuthoritative) {
        [encoder setRenderPipelineState:_pipeline];
        [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [encoder setFragmentTexture:_sourceTexture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0 vertexCount:4];
    } else if (!_reportedDirectDrawableBaseElision) {
        _reportedDirectDrawableBaseElision = YES;
        MacWSLog(@"runtime-confirmed direct-fullscreen-base-elided pid=%d "
                 "layer=%u drawable=%ux%u heartbeat-age-ms=%.1f",
                 self.targetPID, _directDrawableHeartbeatLayerID,
                 fullscreenDirectFrame.record.width,
                 fullscreenDirectFrame.record.height,
                 directHeartbeatAge * 1000.0);
    }

    // A Host-carried Catalyst CAMetalLayer can bypass SkyLight's client-area
    // capture while its native AppKit title bar remains present. Draw the
    // completed producer IOSurface over only the content portion, preserving
    // the captured traffic lights/title bar and the exact existing viewport.
    MacWSCatalystDrawableFrame *baseCatalystFrame =
        [_catalystDrawableCompositor frameForOwnerPID:self.targetPID];
    // A catalog-validated fullscreen canvas has no AppKit title bar to
    // preserve.  Its completed drawable also carries Steam's in-process FPS
    // overlay, so excluding the first 48 source pixels would replace the live
    // overlay with the retained WindowServer strip.  Native windows retain
    // the existing title-bar exclusion.
    CGFloat catalystTitlebarHeightPixels =
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)] ? 0.0 : 48.0;
    if (directSurface && !finalComposite &&
        !fullscreenDirectAuthoritative && baseCatalystFrame.texture) {
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        if (MacWSEncodeCatalystDrawable(
                encoder, baseCatalystFrame, basePixels, visiblePixels,
                _contentRect, self.bounds.size,
                catalystTitlebarHeightPixels)) {
            drewCatalystDrawable = YES;
            catalystWitnessFrame = baseCatalystFrame;
            [submittedCatalystFrames addObject:baseCatalystFrame];
        }
    }

    if (fullscreenDirectAuthoritative) {
        // The controller-validated FullscreenCanvas identity and the live
        // AppInput endpoint establish the semantic destination.  The
        // completed Catalyst drawable is then a self-contained fullscreen
        // pixel source; it must not depend on a simultaneous final-composite
        // frame.  MacWSFinalCompositePublisher intentionally withholds stale
        // composites, and requiring one here regressed the same valid game
        // drawable into a small desktop overlay (R24: final=NO while every
        // PID/window/endpoint/drawable identity check was YES).
        CGRect basePixels = CGRectMake(
            0, 0, _surfaceFrame.descriptor.contentWidth,
            _surfaceFrame.descriptor.contentHeight);
        CGRect destination = CGRectIntersection(
            _reportedFullscreenCanvasPixels, basePixels);
        if (!CGRectIsNull(destination) && !CGRectIsEmpty(destination)) {
            [encoder setRenderPipelineState:_opaquePipeline];
            if (MacWSEncodeCatalystDrawable(
                    encoder, fullscreenDirectFrame, destination, destination,
                    _contentRect, self.bounds.size, 0.0)) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = fullscreenDirectFrame;
                [submittedCatalystFrames addObject:fullscreenDirectFrame];
                if (!_reportedDirectDrawableExactLayerSuppression) {
                    _reportedDirectDrawableExactLayerSuppression = YES;
                    MacWSLog(@"runtime-confirmed direct-drawable "
                             "fullscreen-present pid=%d layer=%u "
                             "drawable=%ux%u authority=controller-validated-"
                             "canvas-plus-live-endpoint-plus-completed-drawable",
                             self.targetPID,
                             _reportedFullscreenCanvasWindowID,
                             fullscreenDirectFrame.record.width,
                             fullscreenDirectFrame.record.height);
                }
            }
            [encoder setRenderPipelineState:_pipeline];
        }
    }

    MacWSSurfaceFrame *performanceFrame = directSurface ? _surfaceFrame : nil;
    // A FinalComposite frame is WindowServer's completed desktop image, not a
    // wallpaper/material underlay. Runtime snapshots on iPad13,6 at
    // 1787945412 captured the same Terminal window in both the base surface
    // and exact layer 58. Painting that layer again produced a synthetic
    // second shadow; while dragging, the independently-timed base and layer
    // occupied different positions and visibly ghosted. Keep exact-window
    // layers solely as the fallback graph when no final composite is live.
    // Catalyst drawables which really are absent from a final composite are
    // joined by the narrowly-scoped pass below instead.
    //
    // A controller-validated fullscreen drawable likewise owns the complete
    // semantic canvas. Steam's FPS overlay is already in that texture.
    if (directSurface && _overlayFrames.count &&
        !finalComposite && !fullscreenDirectAuthoritative) {
        [self overlayKeysBackToFront];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        CGFloat viewWidth = CGRectGetWidth(self.bounds);
        CGFloat viewHeight = CGRectGetHeight(self.bounds);
        for (NSNumber *key in _sortedOverlayKeys) {
            MacWSSurfaceFrame *overlayFrame = _overlayFrames[key];
            id<MTLTexture> overlayTexture = _overlayTextures[key];
            MacWSStreamFrameDescriptor overlay = overlayFrame.descriptor;
            CGRect destination = CGRectMake(
                overlay.destinationX, overlay.destinationY,
                overlay.destinationWidth, overlay.destinationHeight);
            CGRect clipped = CGRectIntersection(destination, visiblePixels);
            if (!overlayTexture || CGRectIsNull(clipped) ||
                CGRectIsEmpty(clipped) || viewWidth <= 0 || viewHeight <= 0 ||
                visiblePixels.size.width <= 0 ||
                visiblePixels.size.height <= 0) continue;
            if (!performanceFrame ||
                overlayFrame.receiptTime > performanceFrame.receiptTime)
                performanceFrame = overlayFrame;

            MacWSCatalystDrawableFrame *catalystFrame =
                [_catalystDrawableCompositor frameForOwnerPID:
                    overlay.layerOwnerPID];
            CFTimeInterval layerDirectHeartbeatAge =
                CACurrentMediaTime() - _lastDirectDrawableHeartbeatTime;
            BOOL directLayerAuthoritative = finalComposite &&
                catalystFrame.texture &&
                _directDrawableHeartbeatPID == overlay.layerOwnerPID &&
                _directDrawableHeartbeatLayerID == overlay.layerWindowID &&
                _lastDirectDrawableHeartbeatTime > 0.0 &&
                layerDirectHeartbeatAge >= 0.0 &&
                layerDirectHeartbeatAge <= 3.0;
            if (directLayerAuthoritative &&
                !_reportedDirectDrawableExactLayerSuppression) {
                _reportedDirectDrawableExactLayerSuppression = YES;
                MacWSLog(@"runtime-confirmed direct-drawable exact-layer-"
                         "suppressed pid=%d layer=%u heartbeat-age-ms=%.1f "
                         "authority=final-composite-plus-completed-drawable",
                         overlay.layerOwnerPID, overlay.layerWindowID,
                         layerDirectHeartbeatAge * 1000.0);
            }

            // SkyLight's exact-window stream contains the window backing but
            // not the compositor's external drop shadow.  The private stream
            // boolean was runtime-probed both ways on window 88 and returned
            // the same 960x656 surface, so no native shadow pixels exist to
            // copy.  AppInputBridge now publishes NSWindow.hasShadow from the
            // real window; render one inexpensive rounded Gaussian SDF behind
            // that layer on the GPU before painting its authoritative pixels.
            if (!directLayerAuthoritative && _shadowPipeline &&
                [_shadowWindowIDs containsObject:
                    @(overlay.layerWindowID)]) {
                const CGFloat marginLeft = 32.0;
                const CGFloat marginTop = 24.0;
                const CGFloat marginRight = 32.0;
                const CGFloat marginBottom = 40.0;
                CGRect shadowDestination = CGRectMake(
                    destination.origin.x - marginLeft,
                    destination.origin.y - marginTop,
                    destination.size.width + marginLeft + marginRight,
                    destination.size.height + marginTop + marginBottom);
                CGRect shadowClipped = CGRectIntersection(
                    shadowDestination, visiblePixels);
                if (!CGRectIsNull(shadowClipped) &&
                    !CGRectIsEmpty(shadowClipped)) {
                    CGFloat shadowLeft = CGRectGetMinX(_contentRect) +
                        (CGRectGetMinX(shadowClipped) -
                         CGRectGetMinX(visiblePixels)) /
                            CGRectGetWidth(visiblePixels) *
                            CGRectGetWidth(_contentRect);
                    CGFloat shadowRight = CGRectGetMinX(_contentRect) +
                        (CGRectGetMaxX(shadowClipped) -
                         CGRectGetMinX(visiblePixels)) /
                            CGRectGetWidth(visiblePixels) *
                            CGRectGetWidth(_contentRect);
                    CGFloat shadowTop = CGRectGetMinY(_contentRect) +
                        (CGRectGetMinY(shadowClipped) -
                         CGRectGetMinY(visiblePixels)) /
                            CGRectGetHeight(visiblePixels) *
                            CGRectGetHeight(_contentRect);
                    CGFloat shadowBottom = CGRectGetMinY(_contentRect) +
                        (CGRectGetMaxY(shadowClipped) -
                         CGRectGetMinY(visiblePixels)) /
                            CGRectGetHeight(visiblePixels) *
                            CGRectGetHeight(_contentRect);
                    float u0 = (CGRectGetMinX(shadowClipped) -
                                CGRectGetMinX(shadowDestination)) /
                               CGRectGetWidth(shadowDestination);
                    float u1 = (CGRectGetMaxX(shadowClipped) -
                                CGRectGetMinX(shadowDestination)) /
                               CGRectGetWidth(shadowDestination);
                    float v0 = (CGRectGetMinY(shadowClipped) -
                                CGRectGetMinY(shadowDestination)) /
                               CGRectGetHeight(shadowDestination);
                    float v1 = (CGRectGetMaxY(shadowClipped) -
                                CGRectGetMinY(shadowDestination)) /
                               CGRectGetHeight(shadowDestination);
                    simd_float4 shadowVertices[4] = {
                        {(float)(shadowLeft / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowBottom / viewHeight * 2.0),
                         u0, v1},
                        {(float)(shadowRight / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowBottom / viewHeight * 2.0),
                         u1, v1},
                        {(float)(shadowLeft / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowTop / viewHeight * 2.0),
                         u0, v0},
                        {(float)(shadowRight / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowTop / viewHeight * 2.0),
                         u1, v0},
                    };
                    simd_float4 shadowGeometry[2] = {
                        {(float)shadowDestination.size.width,
                         (float)shadowDestination.size.height,
                         (float)marginLeft, (float)marginTop},
                        {(float)destination.size.width,
                         (float)destination.size.height, 12.0f, 13.0f},
                    };
                    [encoder setRenderPipelineState:_shadowPipeline];
                    [encoder setVertexBytes:shadowVertices
                                      length:sizeof(shadowVertices) atIndex:0];
                    [encoder setFragmentBytes:shadowGeometry
                                        length:sizeof(shadowGeometry) atIndex:0];
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                vertexStart:0 vertexCount:4];
                    [encoder setRenderPipelineState:_pipeline];
                }
            }

            if (!directLayerAuthoritative) {
                CGFloat relativeLeft =
                    (CGRectGetMinX(clipped) - CGRectGetMinX(visiblePixels)) /
                    CGRectGetWidth(visiblePixels);
                CGFloat relativeRight =
                    (CGRectGetMaxX(clipped) - CGRectGetMinX(visiblePixels)) /
                    CGRectGetWidth(visiblePixels);
                CGFloat relativeTop =
                    (CGRectGetMinY(clipped) - CGRectGetMinY(visiblePixels)) /
                    CGRectGetHeight(visiblePixels);
                CGFloat relativeBottom =
                    (CGRectGetMaxY(clipped) - CGRectGetMinY(visiblePixels)) /
                    CGRectGetHeight(visiblePixels);
                CGFloat viewLeft = CGRectGetMinX(_contentRect) +
                    relativeLeft * CGRectGetWidth(_contentRect);
                CGFloat viewRight = CGRectGetMinX(_contentRect) +
                    relativeRight * CGRectGetWidth(_contentRect);
                CGFloat viewTop = CGRectGetMinY(_contentRect) +
                    relativeTop * CGRectGetHeight(_contentRect);
                CGFloat viewBottom = CGRectGetMinY(_contentRect) +
                    relativeBottom * CGRectGetHeight(_contentRect);

                float sourceLeft = (overlay.contentX +
                    (CGRectGetMinX(clipped) - CGRectGetMinX(destination)) /
                        CGRectGetWidth(destination) * overlay.contentWidth) /
                    (float)overlay.width;
                float sourceRight = (overlay.contentX +
                    (CGRectGetMaxX(clipped) - CGRectGetMinX(destination)) /
                        CGRectGetWidth(destination) * overlay.contentWidth) /
                    (float)overlay.width;
                float sourceTop = (overlay.contentY +
                    (CGRectGetMinY(clipped) - CGRectGetMinY(destination)) /
                        CGRectGetHeight(destination) * overlay.contentHeight) /
                    (float)overlay.height;
                float sourceBottom = (overlay.contentY +
                    (CGRectGetMaxY(clipped) - CGRectGetMinY(destination)) /
                        CGRectGetHeight(destination) * overlay.contentHeight) /
                    (float)overlay.height;
                simd_float4 overlayVertices[4] = {
                    {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewBottom / viewHeight * 2.0),
                     sourceLeft, sourceBottom},
                    {(float)(viewRight / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewBottom / viewHeight * 2.0),
                     sourceRight, sourceBottom},
                    {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewTop / viewHeight * 2.0),
                     sourceLeft, sourceTop},
                    {(float)(viewRight / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewTop / viewHeight * 2.0),
                     sourceRight, sourceTop},
                };
                [encoder setVertexBytes:overlayVertices
                                  length:sizeof(overlayVertices) atIndex:0];
                [encoder setFragmentTexture:overlayTexture atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                            vertexStart:0 vertexCount:4];
            }
            if (directLayerAuthoritative && _opaquePipeline)
                [encoder setRenderPipelineState:_opaquePipeline];
            if (MacWSEncodeCatalystDrawable(
                    encoder, catalystFrame, destination, visiblePixels,
                    _contentRect, self.bounds.size,
                    catalystTitlebarHeightPixels)) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = catalystFrame;
                if (![submittedCatalystFrames containsObject:catalystFrame])
                    [submittedCatalystFrames addObject:catalystFrame];
            }
            if (directLayerAuthoritative && _opaquePipeline)
                [encoder setRenderPipelineState:_pipeline];
            // The lease token is the unique ownership identity across stream
            // recreation.  A later frame can now distinguish an IOSurface
            // actually referenced by an in-flight command buffer from one
            // merely imported and superseded before this draw.
            _submittedOverlayLeaseTokens[key] =
                @(overlayFrame.descriptor.leaseToken);
        }
    }
    if (directSurface && finalComposite && _overlayFrames.count &&
        ![_fullscreenCanvasPIDs containsObject:@(self.targetPID)]) {
        // Final-composite is authoritative for native SkyLight effects, but a
        // Host-carried Catalyst CAMetalLayer is absent from that snapshot even
        // though its real drawable is complete. Replace only the focused
        // Catalyst client's rectangle. Restricting this to targetPID keeps an
        // obscured/background game from painting over native windows already
        // resolved by WindowServer in the final composite.
        [self overlayKeysBackToFront];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        MacWSCatalystDrawableFrame *focusedFrame =
            [_catalystDrawableCompositor frameForOwnerPID:self.targetPID];
        for (NSNumber *key in _sortedOverlayKeys) {
            MacWSSurfaceFrame *overlayFrame = _overlayFrames[key];
            MacWSStreamFrameDescriptor overlay = overlayFrame.descriptor;
            if (overlay.layerOwnerPID != self.targetPID) continue;
            CGRect destination = CGRectMake(
                overlay.destinationX, overlay.destinationY,
                overlay.destinationWidth, overlay.destinationHeight);
            if (MacWSEncodeCatalystDrawable(
                    encoder, focusedFrame, destination, visiblePixels,
                    _contentRect, self.bounds.size,
                    catalystTitlebarHeightPixels)) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = focusedFrame;
                if (![submittedCatalystFrames containsObject:focusedFrame])
                    [submittedCatalystFrames addObject:focusedFrame];
                break;
            }
        }
    }
    [encoder endEncoding];
    NSString *renderedSnapshotPath = _pendingRenderedDrawableSnapshotPath;
    _pendingRenderedDrawableSnapshotPath = nil;
    NSUInteger renderedSnapshotWidth = drawable.texture.width;
    NSUInteger renderedSnapshotHeight = drawable.texture.height;
    MTLPixelFormat renderedSnapshotPixelFormat = drawable.texture.pixelFormat;
    NSUInteger renderedSnapshotBytesPerRow =
        ((renderedSnapshotWidth * 4 + 255) / 256) * 256;
    id<MTLBuffer> renderedSnapshotBuffer = nil;
    if (renderedSnapshotPath.length != 0) {
        MacWSLog(@"rendered-drawable-authority target=%d authoritative=%@ "
                 "final=%@ capability=%@ controller-identity=%@ "
                 "layer=%@ retained=%@ heartbeat-pid=%d "
                 "heartbeat-window=%u heartbeat-age-ms=%.1f "
                 "direct-sequence=%llu endpoint=%@",
                 self.targetPID,
                 fullscreenDirectAuthoritative ? @"YES" : @"NO",
                 finalComposite ? @"YES" : @"NO",
                 [_fullscreenCanvasPIDs containsObject:@(self.targetPID)]
                    ? @"YES" : @"NO",
                 controllerValidatedFullscreenIdentity ? @"YES" : @"NO",
                 fullscreenDirectLayer ? @"YES" : @"NO",
                 retainedFullscreenDirectIdentity ? @"YES" : @"NO",
                 _directDrawableHeartbeatPID,
                 _directDrawableHeartbeatLayerID,
                 directHeartbeatAge * 1000.0,
                 (unsigned long long)fullscreenDirectFrame.record.sequence,
                 MacWSAppInputEndpointReady(self.targetPID)
                    ? @"YES" : @"NO");
    }
    if (renderedSnapshotPath.length != 0 &&
        renderedSnapshotWidth != 0 && renderedSnapshotHeight != 0 &&
        (renderedSnapshotPixelFormat == MTLPixelFormatBGRA8Unorm ||
         renderedSnapshotPixelFormat == MTLPixelFormatBGRA8Unorm_sRGB)) {
        renderedSnapshotBuffer = [self.device newBufferWithLength:
            renderedSnapshotBytesPerRow * renderedSnapshotHeight
            options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = renderedSnapshotBuffer
            ? [commandBuffer blitCommandEncoder] : nil;
        if (blit) {
            [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(renderedSnapshotWidth,
                                         renderedSnapshotHeight, 1)
                    toBuffer:renderedSnapshotBuffer destinationOffset:0
           destinationBytesPerRow:renderedSnapshotBytesPerRow
         destinationBytesPerImage:
             renderedSnapshotBytesPerRow * renderedSnapshotHeight];
            [blit endEncoding];
        }
    }
    if (renderedSnapshotPath.length != 0) {
        id<MTLBuffer> completedSnapshotBuffer = renderedSnapshotBuffer;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSData *png = nil;
            NSError *writeError = nil;
            if (completed.status == MTLCommandBufferStatusCompleted &&
                completedSnapshotBuffer) {
                NSData *pixels = [NSData dataWithBytes:
                    completedSnapshotBuffer.contents length:
                    renderedSnapshotBytesPerRow * renderedSnapshotHeight];
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(
                    (__bridge CFDataRef)pixels);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGImageRef image = provider && colorSpace ? CGImageCreate(
                    renderedSnapshotWidth, renderedSnapshotHeight, 8, 32,
                    renderedSnapshotBytesPerRow, colorSpace,
                    kCGBitmapByteOrder32Little |
                        kCGImageAlphaPremultipliedFirst,
                    provider, NULL, false, kCGRenderingIntentDefault) : NULL;
                if (image) {
                    png = UIImagePNGRepresentation(
                        [UIImage imageWithCGImage:image]);
                    CGImageRelease(image);
                }
                if (colorSpace) CGColorSpaceRelease(colorSpace);
                if (provider) CGDataProviderRelease(provider);
                if (png.length)
                    [png writeToFile:renderedSnapshotPath
                             options:NSDataWritingAtomic error:&writeError];
            }
            MacWSLog(@"rendered-drawable-snapshot written=%@ bytes=%lu "
                     "size=%lux%lu pixel-format=%lu status=%ld path=%@ "
                     "error=%@",
                     png.length && !writeError ? @"YES" : @"NO",
                     (unsigned long)png.length,
                     (unsigned long)renderedSnapshotWidth,
                     (unsigned long)renderedSnapshotHeight,
                     (unsigned long)renderedSnapshotPixelFormat,
                     (long)completed.status, renderedSnapshotPath,
                     writeError ?: completed.error ?: @"nil");
        }];
    }
    uint64_t submitTime = mach_absolute_time();
    uint64_t performanceStreamID = performanceFrame
        ? performanceFrame.descriptor.streamID : 0;
    uint64_t performanceSequence = performanceFrame
        ? performanceFrame.descriptor.sequence : 0;
    uint64_t performanceCaptureTime = performanceFrame
        ? performanceFrame.descriptor.displayTime : 0;
    uint64_t performanceReceiptTime = performanceFrame
        ? performanceFrame.receiptTime : submitTime;
    [_performanceMonitor recordSubmissionForStream:performanceStreamID
        sequence:performanceSequence captureTime:performanceCaptureTime
        receiptTime:performanceReceiptTime submitTime:submitTime
        commandBuffer:commandBuffer drawable:drawable];
    for (MacWSCatalystDrawableFrame *directFrame in
            submittedCatalystFrames) {
        MacWSCatalystDrawableRecord record = directFrame.record;
        [_performanceMonitor
            recordDirectDrawableSubmissionForOwnerPID:record.ownerPID
            sequence:record.sequence completionTime:record.completionTime
            isTarget:self.targetPID == record.ownerPID drawable:drawable];
    }
    [commandBuffer presentDrawable:drawable];
    if (submittedCatalystFrames.count) {
        NSArray<MacWSCatalystDrawableFrame *> *leasedCatalystFrames =
            [submittedCatalystFrames copy];
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> cb) {
            // Capturing the immutable array is the lifetime fence.  Releasing
            // this completion block releases each frame and only then returns
            // its transferred IOSurface use count to CAMetalLayer.
            (void)leasedCatalystFrames.count;
        }];
    }
    if (drewCatalystDrawable && !_submittedCatalystDrawableWitness) {
        _submittedCatalystDrawableWitness = YES;
        MacWSCatalystDrawableRecord witness = catalystWitnessFrame.record;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            MacWSLog(@"runtime-confirmed catalyst-drawable presented pid=%d "
                     "surface=%u sequence=%llu size=%ux%u status=%ld "
                     "error=%@",
                     witness.ownerPID, witness.surfaceID,
                     (unsigned long long)witness.sequence, witness.width,
                     witness.height, (long)completed.status,
                     completed.error ?: @"nil");
        }];
    }
    uint32_t presentedWidth = [self currentFrameWidth];
    uint32_t presentedHeight = [self currentFrameHeight];
    MacWSSurfaceFrame *submittedFrame = directSurface ? _surfaceFrame : nil;
    NSArray<MacWSSurfaceFrame *> *framesToRelease =
        _retiredSurfaceFrames.count ? [_retiredSurfaceFrames copy] : @[];
    [_retiredSurfaceFrames removeAllObjects];
    if (submittedFrame)
        _submittedSurfaceLeaseToken = submittedFrame.descriptor.leaseToken;
    if (MacWSHostDiagnosticsEnabled() && performanceFrame &&
        (performanceFrame.descriptor.sequence % 120) == 0 &&
        (_lastPerformanceLogStreamID != performanceFrame.descriptor.streamID ||
         _lastPerformanceLogSequence != performanceFrame.descriptor.sequence)) {
        uint64_t captureTime = performanceFrame.descriptor.displayTime;
        uint64_t receiptTime = performanceFrame.receiptTime;
        uint64_t sequence = performanceFrame.descriptor.sequence;
        uint64_t streamID = performanceFrame.descriptor.streamID;
        _lastPerformanceLogStreamID = streamID;
        _lastPerformanceLogSequence = sequence;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            uint64_t completeTime = mach_absolute_time();
            MacWSLog(@"display-perf stream=%llu sequence=%llu "
                     "capture-to-receipt-ms=%.3f receipt-to-submit-ms=%.3f "
                     "submit-to-complete-ms=%.3f status=%ld error=%@",
                     (unsigned long long)streamID,
                     (unsigned long long)sequence,
                     MacWSMachMilliseconds(captureTime, receiptTime),
                     MacWSMachMilliseconds(receiptTime, submitTime),
                     MacWSMachMilliseconds(submitTime, completeTime),
                     (long)completed.status, completed.error ?: @"nil");
        }];
    }
    if ((directSurface || _reportedNonzeroFrame) && !_submittedPresentWitness) {
        _submittedPresentWitness = YES;
        uint32_t witnessWidth = presentedWidth;
        uint32_t witnessHeight = presentedHeight;
        uint64_t witnessScene = self.sceneID;
        float witnessBackingScale = directSurface
            ? submittedFrame.descriptor.backingScale : 1.0f;
        CGSize witnessDrawableSize = self.drawableSize;
        CGRect witnessContentRect = _contentRect;
        CGFloat witnessDensity = self.effectiveDensityScale;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSError *error = completed.error;
            MacWSLog(@"runtime-confirmed native Metal present scene=%llx "
                     "frame=%ux%u backing=%.3f drawable=%.0fx%.0f "
                     "content=(%.2f,%.2f %.2fx%.2f) density=%.2f "
                     "source=%@ status=%ld error=%@",
                     witnessScene, witnessWidth, witnessHeight,
                     witnessBackingScale, witnessDrawableSize.width,
                     witnessDrawableSize.height, witnessContentRect.origin.x,
                     witnessContentRect.origin.y, witnessContentRect.size.width,
                     witnessContentRect.size.height, witnessDensity,
                     directSurface ? @"IOSurface" : @"mmap-upload",
                     (long)completed.status, error ?: @"nil");
        }];
    }
    if (framesToRelease.count) {
        __weak MacWSStreamClient *weakClient = _streamClient;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            for (MacWSSurfaceFrame *frame in framesToRelease)
                [weakClient releaseFrame:frame];
        }];
    }
    [commandBuffer commit];
    if (directSurface) {
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  DisplayStream  ·  IOSurface 直传",
            presentedWidth, presentedHeight]];
    } else {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        NSString *content = _reportedNonzeroFrame ? @"有效像素" : @"全黑";
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  %@",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration, content]];
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    [self updatePresentationGeometry];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint
                       output:(CGPoint *)framePoint
           clampContinuationToContent:(BOOL)clampContinuation {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0 || CGRectIsEmpty(_contentRect)) {
        return NO;
    }
    if (!CGRectContainsPoint(_contentRect, viewPoint) && !clampContinuation)
        return NO;
    // A pointer transaction which began on the macOS surface must always
    // receive its Move/Up/Cancel boundary.  In a fitted Scene, UIKit can keep
    // delivering the finger in the one-pixel letterbox or deferred top/bottom
    // system-gesture inset.  Dropping those samples froze a title-bar drag
    // before it reached the native macOS screen edge and could also strand the
    // primary button down.  Clamp only continuations; an independent tap or
    // hover outside the rendered desktop remains rejected.
    if (clampContinuation) {
        viewPoint.x = fmin(fmax(viewPoint.x, CGRectGetMinX(_contentRect)),
                           CGRectGetMaxX(_contentRect));
        viewPoint.y = fmin(fmax(viewPoint.y, CGRectGetMinY(_contentRect)),
                           CGRectGetMaxY(_contentRect));
    }
    CGFloat nx = (viewPoint.x - CGRectGetMinX(_contentRect)) /
        _contentRect.size.width;
    CGFloat ny = (viewPoint.y - CGRectGetMinY(_contentRect)) /
        _contentRect.size.height;
    CGFloat sourceX = CGRectGetMinX(_visibleSourceRect) +
        fmin(fmax(nx, 0.0), 1.0) * CGRectGetWidth(_visibleSourceRect);
    CGFloat sourceY = CGRectGetMinY(_visibleSourceRect) +
        fmin(fmax(ny, 0.0), 1.0) * CGRectGetHeight(_visibleSourceRect);
    framePoint->x = sourceX * (frameWidth - 1);
    framePoint->y = sourceY * (frameHeight - 1);
    return YES;
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint output:(CGPoint *)framePoint {
    return [self framePointForViewPoint:viewPoint output:framePoint
                    clampContinuationToContent:NO];
}

- (BOOL)viewPointForFramePoint:(CGPoint)framePoint output:(CGPoint *)viewPoint {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    CGFloat visibleWidth = CGRectGetWidth(_visibleSourceRect);
    CGFloat visibleHeight = CGRectGetHeight(_visibleSourceRect);
    if (frameWidth == 0 || frameHeight == 0 || CGRectIsEmpty(_contentRect) ||
        visibleWidth <= 0 || visibleHeight <= 0) return NO;
    CGFloat sourceX = framePoint.x / MAX(frameWidth - 1, 1u);
    CGFloat sourceY = framePoint.y / MAX(frameHeight - 1, 1u);
    CGFloat nx = (sourceX - CGRectGetMinX(_visibleSourceRect)) / visibleWidth;
    CGFloat ny = (sourceY - CGRectGetMinY(_visibleSourceRect)) / visibleHeight;
    nx = fmin(fmax(nx, 0.0), 1.0);
    ny = fmin(fmax(ny, 0.0), 1.0);
    if (viewPoint) {
        *viewPoint = CGPointMake(CGRectGetMinX(_contentRect) +
            nx * CGRectGetWidth(_contentRect),
            CGRectGetMinY(_contentRect) + ny * CGRectGetHeight(_contentRect));
    }
    return YES;
}

- (NSArray<NSNumber *> *)overlayKeysBackToFront {
    if (!_sortedOverlayKeys) {
        _sortedOverlayKeys = [_overlayFrames.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(
                NSNumber *lhs, NSNumber *rhs) {
                MacWSStreamFrameDescriptor left =
                    self->_overlayFrames[lhs].descriptor;
                MacWSStreamFrameDescriptor right =
                    self->_overlayFrames[rhs].descriptor;
                if (left.layerLevel < right.layerLevel)
                    return NSOrderedAscending;
                if (left.layerLevel > right.layerLevel)
                    return NSOrderedDescending;
                return [lhs compare:rhs];
            }];
    }
    return _sortedOverlayKeys;
}

- (BOOL)resolveFinalCompositeCatalogAtPoint:(CGPoint)point
                                        pid:(int32_t *)pidOut
                                   windowID:(uint32_t *)windowIDOut
                                 descriptor:(MacWSStreamFrameDescriptor *)descriptorOut {
    if (![self hasFinalCompositeFrame] || !_streamConnected ||
        _latestWindows.count == 0) return NO;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0 || point.x < 0.0 ||
        point.y < 0.0 || point.x >= frameWidth || point.y >= frameHeight)
        return NO;

    // displayd preserves CGWindowList's front-to-back catalog order.  Its
    // catalog contains only validated AppKit layer-zero windows, so the first
    // live endpoint whose backing-pixel rectangle contains this point is the
    // application represented by the already-composited pixels there.
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        if (candidate.ownerPID <= 1 || candidate.windowID == 0 ||
            (candidate.flags & required) != required ||
            (candidate.flags & MacWSStreamWindowMenuBar) != 0 ||
            !MacWSAppInputEndpointReady(candidate.ownerPID) ||
            !isfinite(candidate.logicalX) ||
            !isfinite(candidate.logicalY) ||
            !isfinite(candidate.logicalWidth) ||
            !isfinite(candidate.logicalHeight) ||
            !isfinite(candidate.backingScale) ||
            candidate.logicalWidth <= 0.0f ||
            candidate.logicalHeight <= 0.0f ||
            candidate.backingScale < 0.5f ||
            candidate.backingScale > 8.0f) continue;
        CGFloat scale = candidate.backingScale;
        CGRect destination = CGRectMake(
            candidate.logicalX * scale, candidate.logicalY * scale,
            candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        if (!CGRectContainsPoint(destination, point)) continue;
        if (pidOut) *pidOut = candidate.ownerPID;
        if (windowIDOut) *windowIDOut = candidate.windowID;
        if (descriptorOut) {
            // Scroll/magnify/rotate are routed application-locally.  Build
            // their affine mapping from the same catalog geometry instead of
            // requiring a duplicate overlay IOSurface to remain leased.
            *descriptorOut = (MacWSStreamFrameDescriptor){
                .magic = MACWS_STREAM_MAGIC,
                .version = MACWS_STREAM_VERSION,
                .size = sizeof(MacWSStreamFrameDescriptor),
                .width = candidate.pixelWidth,
                .height = candidate.pixelHeight,
                .backingScale = scale,
                .contentWidth = candidate.pixelWidth,
                .contentHeight = candidate.pixelHeight,
                .layerWindowID = candidate.windowID,
                .layerOwnerPID = candidate.ownerPID,
                .destinationX = (int32_t)llround(CGRectGetMinX(destination)),
                .destinationY = (int32_t)llround(CGRectGetMinY(destination)),
                .destinationWidth = (uint32_t)llround(
                    CGRectGetWidth(destination)),
                .destinationHeight = (uint32_t)llround(
                    CGRectGetHeight(destination)),
            };
        }
        return YES;
    }
    return NO;
}

- (int32_t)frontmostInputApplicationPIDAmongPIDs:(NSSet<NSNumber *> *)pids {
    // Prefer the session-wide LaunchServices authority published by
    // macwsdisplayd.  Unlike process-local keyWindow/Focused state, exactly
    // one application owns this flag.  It also follows the already-composited
    // final desktop when an old independent capture layer has stopped
    // producing and therefore retains obsolete z-order metadata.
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if ((descriptor.flags &
                MacWSStreamWindowFrontmostApplication) == 0 ||
            descriptor.ownerPID <= 1 ||
            (pids.count != 0 &&
             ![pids containsObject:@(descriptor.ownerPID)]) ||
            !MacWSAppInputEndpointReady(descriptor.ownerPID)) continue;
        return descriptor.ownerPID;
    }
    // The workspace layer graph carries displayd's current on-screen ordering
    // as layerLevel. It remains the z-order authority even while an independent
    // FinalComposite supplies the pixels: CopyCatalogWindowInfo's OptionAll
    // catalog is an identity/lifecycle list and is not reordered by every
    // activation on this chroot. Runtime-confirmed on 2026-08-30 after bringing
    // Settings window 320 forward: retained layer levels were Activity=4,
    // Terminal=5, Settings=6 (matching the rendered snapshot), while
    // _latestWindows remained Activity, Terminal, Settings. Selecting the
    // catalog first therefore reset keyboard targetPID to the covered Activity
    // Monitor immediately after the correct pointer activation.
    //
    // A nonempty catalog still constrains eligible identities. An empty catalog
    // is a real fullscreen-game state (runtime: Stray PID 22119 kept layer 67
    // and its input endpoint while publishing no AppKit catalog item), so the
    // same live layer graph remains authoritative there as well.
    BOOL restrictToCatalogPIDs = pids.count != 0;
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID <= 1 ||
            (restrictToCatalogPIDs &&
             ![pids containsObject:@(descriptor.layerOwnerPID)]) ||
            descriptor.layerWindowID == 0 ||
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0 ||
            (descriptor.flags & MacWSStreamFrameInputPassthrough) != 0 ||
            !MacWSAppInputEndpointReady(descriptor.layerOwnerPID)) continue;
        return descriptor.layerOwnerPID;
    }
    if ([self hasFinalCompositeFrame] && _streamConnected) {
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags required =
                MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
            if (descriptor.ownerPID <= 1 || descriptor.windowID == 0 ||
                (restrictToCatalogPIDs &&
                 ![pids containsObject:@(descriptor.ownerPID)]) ||
                (descriptor.flags & required) != required ||
                !MacWSAppInputEndpointReady(descriptor.ownerPID)) continue;
            MacWSLog(@"fullscreen-frontmost route=final-composite-catalog-"
                     "fallback pid=%d window=%u flags=%#x",
                     descriptor.ownerPID, descriptor.windowID,
                     descriptor.flags);
            return descriptor.ownerPID;
        }
    }
    return 0;
}

- (void)logPerformanceSnapshotWithReason:(NSString *)reason {
    NSMutableArray<NSString *> *layers = [NSMutableArray array];
    for (NSNumber *key in [self overlayKeysBackToFront]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        [layers addObject:[NSString stringWithFormat:
            @"layer=%u/pid=%d/stream=%llu/sequence=%llu/surface=%u/age-ms=%.2f",
            descriptor.layerWindowID, descriptor.layerOwnerPID,
            (unsigned long long)descriptor.streamID,
            (unsigned long long)descriptor.sequence,
            IOSurfaceGetID(frame.surface),
            MacWSMachMilliseconds(frame.receiptTime, mach_absolute_time())]];
    }
    MacWSStreamFrameDescriptor base = _surfaceFrame.descriptor;
    MacWSLog(@"display-performance-snapshot reason=%@ "
             "base-stream=%llu base-sequence=%llu base-surface=%u "
             "texture-imports=%llu texture-reuses=%llu layers=[%@]",
             reason.length ? reason : @"manual",
             (unsigned long long)base.streamID,
             (unsigned long long)base.sequence,
             _surfaceFrame ? IOSurfaceGetID(_surfaceFrame.surface) : 0,
             (unsigned long long)_surfaceTextureImports,
             (unsigned long long)_surfaceTextureReuses,
             [layers componentsJoinedByString:@", "]);
}

- (BOOL)writeBaseSurfaceSnapshotToPath:(NSString *)path {
    IOSurfaceRef surface = _surfaceFrame.surface;
    if (!surface || path.length == 0) return NO;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;
    int32_t locked = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    if (locked != 0) return NO;
    void *base = IOSurfaceGetBaseAddress(surface);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = base && colorSpace
        ? CGBitmapContextCreate(base, width, height, 8, bytesPerRow,
              colorSpace, kCGBitmapByteOrder32Little |
                  kCGImageAlphaPremultipliedFirst)
        : NULL;
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    NSData *png = image
        ? UIImagePNGRepresentation([UIImage imageWithCGImage:image]) : nil;
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    if (image) CGImageRelease(image);
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    MacWSLog(@"base-surface-snapshot written=%@ bytes=%lu stream=%llu "
             "sequence=%llu surface=%u path=%@ error=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             (unsigned long long)_surfaceFrame.descriptor.streamID,
             (unsigned long long)_surfaceFrame.descriptor.sequence,
             IOSurfaceGetID(surface), path, error ?: @"");
    return written;
}

- (BOOL)writeSurface:(IOSurfaceRef)surface
              toPath:(NSString *)path
          sampleName:(NSString *)sampleName
          descriptor:(MacWSStreamFrameDescriptor)descriptor {
    if (!surface || path.length == 0) return NO;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;
    int32_t locked = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    if (locked != 0) {
        MacWSLog(@"workspace-layer-snapshot name=%@ lock=%d", sampleName,
                 locked);
        return NO;
    }
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    NSUInteger sampled = 0;
    NSUInteger nonzeroRGB = 0;
    NSUInteger nonzeroAlpha = 0;
    uint8_t minAlpha = UINT8_MAX;
    uint8_t maxAlpha = 0;
    if (base) {
        const NSUInteger targetSamples = 8192;
        size_t pixelCount = width * height;
        size_t step = MAX((size_t)1, pixelCount / targetSamples);
        for (size_t index = 0; index < pixelCount; index += step) {
            size_t x = index % width;
            size_t y = index / width;
            const uint8_t *pixel = base + y * bytesPerRow + x * 4;
            sampled++;
            if (pixel[0] || pixel[1] || pixel[2]) nonzeroRGB++;
            if (pixel[3]) nonzeroAlpha++;
            minAlpha = MIN(minAlpha, pixel[3]);
            maxAlpha = MAX(maxAlpha, pixel[3]);
        }
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = base && colorSpace
        ? CGBitmapContextCreate((void *)base, width, height, 8, bytesPerRow,
              colorSpace, kCGBitmapByteOrder32Little |
                  kCGImageAlphaPremultipliedFirst)
        : NULL;
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    NSData *png = image
        ? UIImagePNGRepresentation([UIImage imageWithCGImage:image]) : nil;
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    if (image) CGImageRelease(image);
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    MacWSLog(@"workspace-layer-snapshot name=%@ written=%@ bytes=%lu "
             "surface=%u size=%zux%zu bpr=%zu sampled=%lu rgb=%lu "
             "alpha=%lu alpha-range=%u..%u flags=0x%x level=%d "
             "destination=%d,%d %ux%u content=%u,%u %ux%u "
             "path=%@ error=%@",
             sampleName, written ? @"YES" : @"NO", (unsigned long)png.length,
             IOSurfaceGetID(surface), width, height, bytesPerRow,
             (unsigned long)sampled, (unsigned long)nonzeroRGB,
             (unsigned long)nonzeroAlpha,
             sampled ? minAlpha : 0, maxAlpha, descriptor.flags,
             descriptor.layerLevel, descriptor.destinationX,
             descriptor.destinationY, descriptor.destinationWidth,
             descriptor.destinationHeight, descriptor.contentX,
             descriptor.contentY, descriptor.contentWidth,
             descriptor.contentHeight, path, error ?: @"");
    return written;
}

- (NSUInteger)writeWorkspaceSurfaceSnapshotsToDirectory:(NSString *)directory {
    if (directory.length == 0) return 0;
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager]
            createDirectoryAtPath:directory
       withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        MacWSLog(@"workspace-layer-snapshot directory=%@ error=%@", directory,
                 directoryError ?: @"unknown");
        return 0;
    }
    NSUInteger written = 0;
    if (_surfaceFrame && [self writeSurface:_surfaceFrame.surface
        toPath:[directory stringByAppendingPathComponent:@"base.png"]
        sampleName:@"base" descriptor:_surfaceFrame.descriptor]) written++;
    for (NSNumber *key in [self overlayKeysBackToFront]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        NSString *name = [NSString stringWithFormat:@"layer-%u-pid-%d",
            frame.descriptor.layerWindowID, frame.descriptor.layerOwnerPID];
        NSString *path = [directory stringByAppendingPathComponent:
            [name stringByAppendingPathExtension:@"png"]];
        if ([self writeSurface:frame.surface toPath:path sampleName:name
                    descriptor:frame.descriptor]) written++;
    }
    MacWSLog(@"workspace-layer-snapshot-complete directory=%@ written=%lu "
             "expected=%lu", directory, (unsigned long)written,
             (unsigned long)(_overlayFrames.count + (_surfaceFrame ? 1 : 0)));
    return written;
}

- (BOOL)resolveFullscreenLayerAtPoint:(CGPoint)point
                                  pid:(int32_t *)pidOut
                             windowID:(uint32_t *)windowIDOut
                           descriptor:(MacWSStreamFrameDescriptor *)descriptorOut {
    // A live FinalComposite is the surface drawInMTKView actually presents.
    // Resolve it against displayd's live front-to-back OnScreenOnly catalog
    // before consulting independent layer captures. Those captures are
    // intentionally suspended once FinalComposite is authoritative and can
    // therefore be minutes stale: runtime snapshot on 2026-08-30 measured
    // Settings child 302 at 144 s old and its main layer at 2212 s old while
    // the base composite was current. Overlay-first hit-testing consequently
    // sent Activity Monitor scrolling to stale Settings PID 95665.
    if ([self resolveFinalCompositeCatalogAtPoint:point pid:pidOut
                                         windowID:windowIDOut
                                       descriptor:descriptorOut]) return YES;

    // Without a catalog-resolvable final composite (notably a fullscreen game
    // drawable), traverse the exact independent graph in reverse paint order.
    // This is main-thread, in-process O(visible layers): no WindowServer IPC
    // and no bounded all-process target-probe round trip.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID <= 1 ||
            descriptor.layerWindowID == 0 ||
            (descriptor.flags & MacWSStreamFrameInputPassthrough) != 0 ||
            descriptor.destinationWidth == 0 ||
            descriptor.destinationHeight == 0) continue;
        CGRect destination = CGRectMake(
            descriptor.destinationX, descriptor.destinationY,
            descriptor.destinationWidth, descriptor.destinationHeight);
        if (!CGRectContainsPoint(destination, point)) continue;
        // Full-display Dock/menu surfaces are intentionally transparent away
        // from their controls. Rectangle-only hit testing therefore selects
        // Dock above every application even though Metal visibly composites
        // the application through that pixel. Read the same BGRA alpha byte
        // used by the fragment blend and skip only a proven transparent pixel.
        // The leased DisplayStream IOSurface is already CPU-mapped; this is a
        // single-byte read at gesture start, not an IOSurface lock or scan.
        const uint8_t *base = IOSurfaceGetBaseAddress(frame.surface);
        size_t stride = IOSurfaceGetBytesPerRow(frame.surface);
        size_t surfaceWidth = IOSurfaceGetWidth(frame.surface);
        size_t surfaceHeight = IOSurfaceGetHeight(frame.surface);
        if (base && stride >= surfaceWidth * 4 && surfaceWidth > 0 &&
            surfaceHeight > 0 && descriptor.contentWidth > 0 &&
            descriptor.contentHeight > 0) {
            double u = (point.x - CGRectGetMinX(destination)) /
                CGRectGetWidth(destination);
            double v = (point.y - CGRectGetMinY(destination)) /
                CGRectGetHeight(destination);
            size_t sourceX = MIN((size_t)descriptor.contentX +
                (size_t)floor(fmax(0.0, fmin(u, 0.999999)) *
                              descriptor.contentWidth), surfaceWidth - 1);
            size_t sourceY = MIN((size_t)descriptor.contentY +
                (size_t)floor(fmax(0.0, fmin(v, 0.999999)) *
                              descriptor.contentHeight), surfaceHeight - 1);
            if (base[sourceY * stride + sourceX * 4 + 3] == 0) continue;
        }
        if (pidOut) *pidOut = descriptor.layerOwnerPID;
        if (windowIDOut) *windowIDOut = descriptor.layerWindowID;
        if (descriptorOut) *descriptorOut = descriptor;
        return YES;
    }
    return NO;
}

- (BOOL)performanceVisiblePointForTargetPID:(int32_t)targetPID
                                      point:(CGPoint *)point {
    if (targetPID <= 1) return NO;
    static const CGFloat fractions[][2] = {
        {0.50, 0.50}, {0.35, 0.35}, {0.65, 0.35}, {0.35, 0.65},
        {0.65, 0.65}, {0.50, 0.30}, {0.50, 0.70}, {0.30, 0.50},
        {0.70, 0.50}, {0.20, 0.20}, {0.80, 0.20}, {0.20, 0.80},
        {0.80, 0.80},
    };
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID != targetPID ||
            descriptor.destinationWidth == 0 ||
            descriptor.destinationHeight == 0) continue;
        CGRect destination = CGRectMake(
            descriptor.destinationX, descriptor.destinationY,
            descriptor.destinationWidth, descriptor.destinationHeight);
        for (NSUInteger index = 0;
             index < sizeof(fractions) / sizeof(fractions[0]); index++) {
            CGPoint candidate = CGPointMake(
                CGRectGetMinX(destination) +
                    CGRectGetWidth(destination) * fractions[index][0],
                CGRectGetMinY(destination) +
                    CGRectGetHeight(destination) * fractions[index][1]);
            int32_t resolvedPID = 0;
            uint32_t resolvedWindowID = 0;
            if ([self resolveFullscreenLayerAtPoint:candidate
                                                pid:&resolvedPID
                                           windowID:&resolvedWindowID
                                         descriptor:NULL] &&
                resolvedPID == targetPID &&
                resolvedWindowID == descriptor.layerWindowID) {
                if (point) *point = candidate;
                return YES;
            }
        }
    }

    // A FinalComposite surface already contains every WindowServer layer, so
    // displayd intentionally retires the duplicate per-window overlay
    // surfaces after that producer becomes authoritative.  Keep the
    // performance probe evidence-based in that mode: require both a live
    // final-composite frame and a current visible/on-screen catalog entry for
    // this exact PID, then select a point inside the catalog rectangle.  The
    // normal fullscreen input path still sends this point through Dock's
    // global CGEvent endpoint, leaving WindowServer as the actual hit tester.
    if (![self hasFinalCompositeFrame] || !_streamConnected ||
        _latestWindows.count == 0) return NO;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0) return NO;
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        if (candidate.ownerPID != targetPID ||
            (candidate.flags & required) != required ||
            (candidate.flags & MacWSStreamWindowMenuBar) != 0 ||
            !isfinite(candidate.logicalX) ||
            !isfinite(candidate.logicalY) ||
            !isfinite(candidate.logicalWidth) ||
            !isfinite(candidate.logicalHeight) ||
            candidate.logicalWidth <= 0.0f ||
            candidate.logicalHeight <= 0.0f) continue;
        CGFloat scale = candidate.backingScale;
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;
        CGRect destination = CGRectMake(
            candidate.logicalX * scale, candidate.logicalY * scale,
            candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        CGRect intersection = CGRectIntersection(destination,
            CGRectMake(0.0, 0.0, frameWidth, frameHeight));
        if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection))
            continue;
        for (NSUInteger index = 0;
             index < sizeof(fractions) / sizeof(fractions[0]); index++) {
            CGPoint visiblePoint = CGPointMake(
                CGRectGetMinX(intersection) + CGRectGetWidth(intersection) *
                    fractions[index][0],
                CGRectGetMinY(intersection) + CGRectGetHeight(intersection) *
                    fractions[index][1]);
            int32_t resolvedPID = 0;
            uint32_t resolvedWindowID = 0;
            if (![self resolveFinalCompositeCatalogAtPoint:visiblePoint
                                                       pid:&resolvedPID
                                                  windowID:&resolvedWindowID
                                                descriptor:NULL] ||
                resolvedPID != targetPID ||
                resolvedWindowID != candidate.windowID) continue;
            if (point) *point = visiblePoint;
            MacWSLog(@"performance-visible-target "
                     "route=final-composite-catalog pid=%d window=%u "
                     "flags=%#x point=(%.1f,%.1f) frame=%ux%u",
                     targetPID, candidate.windowID, candidate.flags,
                     visiblePoint.x, visiblePoint.y, frameWidth, frameHeight);
            return YES;
        }
    }
    return NO;
}

- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record
             presentationTargetPID:(int32_t *)presentationTargetPID {
    if (!record || _streamClient.mode != MacWSStreamModeFullscreen)
        return NO;
    if (presentationTargetPID) *presentationTargetPID = record->targetPID;
    BOOL globalPointer =
        record->kind == MacWSInputKindTouchDown ||
        record->kind == MacWSInputKindTouchMove ||
        record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel ||
        record->kind == MacWSInputKindHover ||
        record->kind == MacWSInputKindMenuHover ||
        record->kind == MacWSInputKindTap ||
        record->kind == MacWSInputKindSecondaryTap;
    if (globalPointer) {
        // A fullscreen desktop is one WindowServer input surface, just like a
        // physical Mac display or OSXvnc.  Do not route pointer input into the
        // AppKit process whose *captured* pixels happen to be under the
        // finger: Mission Control applies compositor-only transforms to those
        // windows, so their local NSWindow coordinates are no longer the
        // visible card coordinates.  Runtime A/B on 2026-08-08 proved that
        // the old route ignored or crashed on a Mission Control card, while
        // the same point through OSXvnc's global CGPostMouseEvent selected the
        // card and completed with stable WindowServer/Dock/Terminal PIDs.
        //
        // Dock is already the verified CGS-connected owner used for native
        // three-finger gestures.  A zero encoded window deliberately tells
        // its endpoint to preserve full-desktop coordinates and let
        // WindowServer perform the authoritative, current global hit test.
        int32_t dockPID = [self dockSystemGestureTargetPID];
        if (dockPID > 1) {
            int32_t visualPID = 0;
            uint32_t visualWindowID = 0;
            BOOL beginsGlobalDrag = record->kind == MacWSInputKindTouchDown;
            BOOL continuesGlobalDrag = record->kind == MacWSInputKindTouchMove ||
                record->kind == MacWSInputKindTouchUp ||
                record->kind == MacWSInputKindTouchCancel;
            if (continuesGlobalDrag &&
                _fullscreenGlobalPointerPresentationPID > 1 &&
                record->contactID ==
                    _fullscreenGlobalPointerPresentationContactID) {
                visualPID = _fullscreenGlobalPointerPresentationPID;
            } else {
                (void)[self resolveFullscreenLayerAtPoint:
                    CGPointMake(record->x, record->y) pid:&visualPID
                    windowID:&visualWindowID descriptor:NULL];
            }
            if (beginsGlobalDrag) {
                _fullscreenGlobalPointerPresentationPID = visualPID;
                _fullscreenGlobalPointerPresentationContactID =
                    record->contactID;
            }
            if (presentationTargetPID) {
                // An explicit fullscreen regression probe measures the
                // global WindowServer/Dock transaction, including a
                // compositor-only Mission Control card retirement. Ordinary
                // physical input remains correlated with the visual app so
                // app-owned content latency keeps its existing meaning.
                *presentationTargetPID =
                    (record->flags & MacWSInputFlagLatencyDiagnostic)
                        ? dockPID : visualPID;
            }
            if (visualPID > 1 &&
                visualPID != dockPID &&
                (record->kind == MacWSInputKindTouchDown ||
                 record->kind == MacWSInputKindTap ||
                 record->kind == MacWSInputKindSecondaryTap)) {
                // The clicked pixels are the strongest foreground witness in
                // fullscreen mode. Keep later hardware/software keyboard
                // records on that exact application without asking a stale
                // process-local focused flag to reorder the desktop.
                self.targetPID = visualPID;
            } else if (visualPID == dockPID && self.targetPID != dockPID &&
                       (record->kind == MacWSInputKindTouchDown ||
                        record->kind == MacWSInputKindTap ||
                        record->kind == MacWSInputKindSecondaryTap)) {
                // Dock is the global CGEvent transport endpoint, not the
                // semantic owner of the application pixels being presented.
                // Keep the current application target until the app/window
                // catalog observes the result of the Dock click.  Assigning
                // Dock here used to clear the live fullscreen drawable join:
                // runtime logs at 1787944038.743 retired Stray's SkyLight
                // layer, 1787944042.808 then retained Dock as target, and the
                // Host immediately fell back to the desktop while Stray kept
                // rendering at 94%% GPU.  A real Dock launch still travels
                // through record->targetPID=dockPID below and the newly
                // frontmost application becomes the target from the catalog.
                MacWSLog(@"fullscreen-presentation-target retained=%d "
                         "ignored-system-proxy=%d kind=%u point=(%.1f,%.1f)",
                         self.targetPID, dockPID, record->kind,
                         record->x, record->y);
            }
            uint32_t modifiers =
                MacWSInputModifiersForScene(record->sceneID);
            record->targetPID = dockPID;
            // Ordinary fullscreen input stays a zero-window system stream so
            // WindowServer remains the final hit-test authority. An explicit
            // regression sample additionally carries Host's already-resolved
            // CGWindowID as a correlation key; Dock still posts the same
            // global CGPostMouseEvent and does not route by this identity.
            uint32_t diagnosticWindowID =
                (record->flags & MacWSInputFlagLatencyDiagnostic)
                    ? visualWindowID : 0;
            record->sceneID = MacWSInputSceneForWindow(
                diagnosticWindowID, modifiers);
            record->flags |= MacWSInputFlagGlobalSystemSurface;
            if ((record->kind == MacWSInputKindTouchUp ||
                 record->kind == MacWSInputKindTouchCancel) &&
                record->contactID ==
                    _fullscreenGlobalPointerPresentationContactID) {
                _fullscreenGlobalPointerPresentationPID = 0;
                _fullscreenGlobalPointerPresentationContactID = 0;
            }
            return YES;
        }
    }
    BOOL terminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & (MacWSInputFlagScrollEnded |
                           MacWSInputFlagScrollCancelled))) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) &&
         (record->flags & (MacWSInputFlagGestureEnded |
                           MacWSInputFlagGestureCancelled)));
    BOOL begins = record->kind == MacWSInputKindTouchDown ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & MacWSInputFlagScrollBegan)) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) &&
         (record->flags & MacWSInputFlagGestureBegan));
    BOOL continuation = record->kind == MacWSInputKindTouchMove || terminal ||
        (record->kind == MacWSInputKindScroll && !begins) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) && !begins);
    // Continuous scroll records encode horizontal delta bits in contactID, so
    // the URL performance suite cannot use the legacy "DIAG" contact value.
    // Its typed latency flag is the common diagnostic identity for pointer,
    // scroll, magnify and rotate. Log only transaction edges to keep a 120 Hz
    // validation run bounded while retaining the resolved Begin descriptor
    // and the frozen End route as runtime evidence.
    BOOL diagnostic =
        record->contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC ||
        (record->flags & MacWSInputFlagLatencyDiagnostic) != 0;
    BOOL diagnosticEdge = diagnostic &&
        (!continuation || begins || terminal);
    if (diagnosticEdge) {
        MacWSLog(@"fullscreen-route-entry view=%p kind=%u begin=%@ continuation=%@ terminal=%@ active=%@ contact=%u owner-contact=%u frozen-destination=(%d,%d %ux%u)",
                 self, record->kind, begins ? @"YES" : @"NO",
                 continuation ? @"YES" : @"NO", terminal ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 record->contactID, _fullscreenGestureRouteContactID,
                 _fullscreenGestureRouteDescriptor.destinationX,
                 _fullscreenGestureRouteDescriptor.destinationY,
                 _fullscreenGestureRouteDescriptor.destinationWidth,
                 _fullscreenGestureRouteDescriptor.destinationHeight);
    }

    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    MacWSStreamFrameDescriptor descriptor = {0};
    BOOL resolved = NO;
    BOOL atomicPrimaryTap = record->kind == MacWSInputKindTap;
    BOOL reuseDoubleTapRoute = atomicPrimaryTap &&
        (record->flags & MacWSInputFlagDoubleClick) != 0 &&
        _fullscreenLastTapRouteTimestamp > 0.0 &&
        record->timestamp >= _fullscreenLastTapRouteTimestamp &&
        record->timestamp - _fullscreenLastTapRouteTimestamp <=
            MACWS_DIRECT_DOUBLE_TAP_SECONDS + 0.05 &&
        _fullscreenLastTapRoutePID > 1 &&
        _fullscreenLastTapRouteWindowID != 0 &&
        _overlayFrames[@(_fullscreenLastTapRouteWindowID)] != nil;
    if (reuseDoubleTapRoute) {
        ownerPID = _fullscreenLastTapRoutePID;
        windowID = _fullscreenLastTapRouteWindowID;
        descriptor = _fullscreenLastTapRouteDescriptor;
        resolved = YES;
    } else if (continuation && _fullscreenGestureRouteActive) {
        ownerPID = _fullscreenGestureRoutePID;
        windowID = _fullscreenGestureRouteWindowID;
        resolved = ownerPID > 1 && windowID != 0;
        // A gesture is one affine transaction. WindowServer changes the live
        // layer destination after every native title-bar drag sample. Mapping
        // the next fixed desktop point through that moving destination
        // subtracts the displacement just applied and makes the window bounce
        // left/right. The Begin descriptor is already retained specifically as
        // the coordinate snapshot, so keep it authoritative through End.
        descriptor = _fullscreenGestureRouteDescriptor;
    } else {
        resolved = [self resolveFullscreenLayerAtPoint:
            CGPointMake(record->x, record->y) pid:&ownerPID
                     windowID:&windowID descriptor:&descriptor];
    }
    if (resolved) {
        if (presentationTargetPID) *presentationTargetPID = ownerPID;
        float desktopX = record->x;
        float desktopY = record->y;
        uint32_t modifiers = MacWSInputModifiersForScene(record->sceneID);
        BOOL globalSystemSurface =
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0;
        BOOL ownerHasEndpoint = MacWSAppInputEndpointReady(ownerPID);
        if (!globalSystemSurface && ownerHasEndpoint) {
            float layerX = 0.0f, layerY = 0.0f;
            resolved = MacWSStreamMapDesktopPointToLayer(
                &descriptor, desktopX, desktopY, &layerX, &layerY);
            if (!resolved) return NO;
            record->x = layerX;
            record->y = layerY;
            record->frameWidth = descriptor.width;
            record->frameHeight = descriptor.height;
            record->targetPID = ownerPID;
        } else {
            // Dock and similar global owners use a real process-local CGS
            // endpoint, but they are not AppKit windows and their capture is
            // the complete desktop coordinate space. Preserve those desktop
            // coordinates and identify the route explicitly from displayd's
            // catalog metadata; endpoint existence alone cannot distinguish
            // Dock from an ordinary exact-window application.
            record->targetPID = ownerPID;
            record->flags |= MacWSInputFlagGlobalSystemSurface;
        }
        record->sceneID = MacWSInputSceneForWindow(windowID, modifiers);
        if (diagnosticEdge) {
            MacWSLog(@"fullscreen-layer-input runtime-confirmed pid=%d target=%d route=%@ window=%u flags=%#x desktop=(%.1f,%.1f) local=(%.1f,%.1f)/%ux%u destination=(%d,%d %ux%u)",
                     ownerPID, record->targetPID,
                     globalSystemSurface ? @"global-system" : @"app",
                     windowID, descriptor.flags, desktopX, desktopY,
                     record->x, record->y, record->frameWidth,
                     record->frameHeight, descriptor.destinationX,
                     descriptor.destinationY, descriptor.destinationWidth,
                     descriptor.destinationHeight);
        }
    }
    // The first click can activate/reorder a native window and the event-
    // driven catalog refresh may land before the second physical click. Keep
    // a short-lived identity snapshot so a UIKit-authoritative double tap is
    // one AppKit transaction, matching VNC's proven same-connection pair.
    // Do not retain vanished popup/menu layers: a dismissal must expose the
    // newly hit-tested surface beneath it for the next independent tap.
    if (atomicPrimaryTap) {
        if (resolved) {
            _fullscreenLastTapRouteTimestamp = record->timestamp;
            _fullscreenLastTapRoutePID = ownerPID;
            _fullscreenLastTapRouteWindowID = windowID;
            _fullscreenLastTapRouteDescriptor = descriptor;
        } else if ((record->flags & MacWSInputFlagDoubleClick) == 0) {
            _fullscreenLastTapRouteTimestamp = 0.0;
            _fullscreenLastTapRoutePID = 0;
            _fullscreenLastTapRouteWindowID = 0;
            _fullscreenLastTapRouteDescriptor =
                (MacWSStreamFrameDescriptor){0};
        }
    }
    if (begins) {
        _fullscreenGestureRouteActive = resolved;
        _fullscreenGestureRouteContactID = resolved ? record->contactID : 0;
        _fullscreenGestureRoutePID = resolved ? ownerPID : 0;
        _fullscreenGestureRouteWindowID = resolved ? windowID : 0;
        _fullscreenGestureRouteDescriptor = resolved
            ? descriptor : (MacWSStreamFrameDescriptor){0};
    }
    // UIKit can deliver an unrelated pointer/finger cancellation while a
    // fullscreen title-bar tracker is active (URL/Scene activation is one
    // reproducible source). A Touch route belongs to its Begin contact; only
    // that contact may release it. Scroll carries horizontal delta bits in
    // contactID, so its native phase boundary remains the owner there.
    BOOL touchTerminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel;
    BOOL terminalOwnsRoute = !touchTerminal ||
        !_fullscreenGestureRouteActive ||
        record->contactID == _fullscreenGestureRouteContactID;
    if (terminal && terminalOwnsRoute) {
        _fullscreenGestureRouteActive = NO;
        _fullscreenGestureRouteContactID = 0;
        _fullscreenGestureRoutePID = 0;
        _fullscreenGestureRouteWindowID = 0;
        _fullscreenGestureRouteDescriptor =
            (MacWSStreamFrameDescriptor){0};
    }
    if (diagnostic) {
        MacWSLog(@"fullscreen-route-exit view=%p kind=%u resolved=%@ active=%@ owner-contact=%u destination=(%d,%d %ux%u)",
                 self, record->kind, resolved ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 _fullscreenGestureRouteContactID, descriptor.destinationX,
                 descriptor.destinationY, descriptor.destinationWidth,
                 descriptor.destinationHeight);
    }
    return resolved;
}

- (void)updatePointerVisibility {
    BOOL available = self.isMacWSInputEnabled &&
        [self currentFrameWidth] > 0 && [self currentFrameHeight] > 0;
    if (self.inputMode != MacWSHostInputModeDirect || !available ||
        !_directTouch) {
        _directTouchIndicator.hidden = YES;
    }
    BOOL showTrackpad = self.inputMode == MacWSHostInputModeTrackpad &&
        available && _trackpadCursorWasTouched && !_externalPointerHoverActive;
    if (showTrackpad) {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        CGPoint pointerCenter = CGPointZero;
        showTrackpad = [self viewPointForFramePoint:_trackpadCursor
                                             output:&pointerCenter];
        if (showTrackpad) {
            _trackpadCursorView.frame = CGRectMake(pointerCenter.x - 12.0,
                pointerCenter.y - 12.0, 24.0, 24.0);
        }
    }
    _trackpadCursorView.hidden = !showTrackpad;
    if (showTrackpad) [self bringSubviewToFront:_trackpadCursorView];
    BOOL showPencil = available && (_pencilHoverActive || _pencilTouch != nil);
    _pencilCursorView.hidden = !showPencil;
    if (showPencil) [self bringSubviewToFront:_pencilCursorView];
}

- (UIView *)makeMultitouchIndicator {
    UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    indicator.backgroundColor =
        [UIColor.systemCyanColor colorWithAlphaComponent:0.16];
    indicator.layer.borderWidth = 1.5;
    indicator.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.86].CGColor;
    indicator.layer.cornerRadius = 15.0;
    indicator.layer.shadowColor = UIColor.blackColor.CGColor;
    indicator.layer.shadowOpacity = 0.24;
    indicator.layer.shadowRadius = 5.0;
    indicator.layer.shadowOffset = CGSizeMake(0, 2);
    indicator.userInteractionEnabled = NO;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(11, 11, 8, 8)];
    dot.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.94];
    dot.layer.cornerRadius = 4.0;
    dot.userInteractionEnabled = NO;
    [indicator addSubview:dot];
    indicator.hidden = YES;
    [self addSubview:indicator];
    return indicator;
}

- (void)hideMultitouchIndicators {
    for (UIView *indicator in _multitouchIndicators) indicator.hidden = YES;
}

- (void)updateMultitouchIndicatorsForRecognizer:
        (UIGestureRecognizer *)recognizer {
    NSUInteger count = recognizer.numberOfTouches;
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed || count < 2) {
        [self hideMultitouchIndicators];
        return;
    }
    while (_multitouchIndicators.count < count)
        [_multitouchIndicators addObject:[self makeMultitouchIndicator]];
    for (NSUInteger index = 0; index < _multitouchIndicators.count; index++) {
        UIView *indicator = _multitouchIndicators[index];
        indicator.hidden = index >= count;
        if (index < count) {
            indicator.center = [recognizer locationOfTouch:index inView:self];
            [self bringSubviewToFront:indicator];
        }
    }
}

- (void)setDirectTouchHeld:(BOOL)held dragging:(BOOL)dragging
                  animated:(BOOL)animated {
    UIView *contactDot = [_directTouchIndicator viewWithTag:501];
    _directTouchStateGlyph.image = [UIImage systemImageNamed:
        dragging ? @"hand.draw.fill" : @"hand.point.up.left.fill"];
    _directTouchStateGlyph.hidden = !held;
    contactDot.hidden = held;
    UIColor *accent = dragging ? UIColor.systemPurpleColor
                               : UIColor.systemOrangeColor;
    void (^changes)(void) = ^{
        self->_directTouchIndicator.transform = held
            ? CGAffineTransformMakeScale(1.22, 1.22)
            : CGAffineTransformIdentity;
        self->_directTouchIndicator.backgroundColor = held
            ? [accent colorWithAlphaComponent:0.58]
            : [UIColor.systemCyanColor colorWithAlphaComponent:0.15];
        self->_directTouchIndicator.layer.borderWidth = held ? 2.25 : 1.5;
        self->_directTouchIndicator.layer.borderColor = held
            ? UIColor.whiteColor.CGColor
            : [UIColor.whiteColor colorWithAlphaComponent:0.82].CGColor;
        self->_directTouchIndicator.layer.shadowColor = held
            ? accent.CGColor : UIColor.blackColor.CGColor;
        self->_directTouchIndicator.layer.shadowOpacity = held ? 0.72 : 0.22;
        self->_directTouchIndicator.layer.shadowRadius = held ? 9.0 : 5.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.14 delay:0
            usingSpringWithDamping:0.72 initialSpringVelocity:0
            options:UIViewAnimationOptionBeginFromCurrentState |
                    UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated {
    _trackpadStateGlyph.hidden = !pressed;
    void (^changes)(void) = ^{
        self->_trackpadCursorView.transform = pressed
            ? CGAffineTransformMakeScale(1.20, 1.20)
            : CGAffineTransformIdentity;
        self->_trackpadCursorView.alpha = 1.0;
        self->_trackpadCursorView.backgroundColor = pressed
            ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.86]
            : [UIColor.systemGrayColor colorWithAlphaComponent:0.74];
        self->_trackpadCursorView.layer.borderWidth = pressed ? 2.0 : 1.0;
        self->_trackpadCursorView.layer.shadowColor = pressed
            ? UIColor.systemOrangeColor.CGColor : UIColor.blackColor.CGColor;
        self->_trackpadCursorView.layer.shadowOpacity = pressed ? 0.68 : 0.30;
        self->_trackpadCursorView.layer.shadowRadius = pressed ? 8.0 : 3.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0
            options:UIViewAnimationOptionBeginFromCurrentState |
                    UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)emitKind:(MacWSInputKind)kind
      framePoint:(CGPoint)framePoint
        pressure:(float)pressure
       contactID:(uint32_t)contactID
       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = contactID,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitKind:(MacWSInputKind)kind
           touch:(UITouch *)touch
           point:(CGPoint)viewPoint
      extraFlags:(uint16_t)extraFlags {
    if (touch.type == UITouchTypePencil)
        viewPoint = [touch preciseLocationInView:self];
    CGPoint framePoint;
    BOOL pointerContinuation = kind == MacWSInputKindTouchMove ||
        kind == MacWSInputKindTouchUp ||
        kind == MacWSInputKindTouchCancel;
    if (![self framePointForViewPoint:viewPoint output:&framePoint
                   clampContinuationToContent:pointerContinuation]) return;
    float pressure = touch.maximumPossibleForce > 0
        ? touch.force / touch.maximumPossibleForce : 0.0f;
    MacWSInputSource source = MacWSInputSourceFinger;
    if (touch.type == UITouchTypePencil)
        source = MacWSInputSourcePencil;
    else if (touch.type == UITouchTypeIndirectPointer)
        source = MacWSInputSourceIndirectPointer;
    float altitude = 0.0f;
    float azimuth = 0.0f;
    float tiltX = 0.0f;
    float tiltY = 0.0f;
    uint16_t inputFlags = 0;
    if (source == MacWSInputSourcePencil) {
        altitude = (float)touch.altitudeAngle;
        azimuth = (float)[touch azimuthAngleInView:self];
        float tiltMagnitude = fmaxf(0.0f, fminf(1.0f, cosf(altitude)));
        tiltX = tiltMagnitude * cosf(azimuth);
        tiltY = tiltMagnitude * sinf(azimuth);
        inputFlags |= MacWSInputFlagPreciseLocation;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = touch.timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = (uint32_t)touch.hash,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .flags = inputFlags | extraFlags,
        .altitude = altitude,
        .azimuth = azimuth,
        .tiltX = tiltX,
        .tiltY = tiltY,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (source == MacWSInputSourceFinger &&
        self.inputMode == MacWSHostInputModeDirect) {
        _directTouchIndicator.center = viewPoint;
        _directTouchIndicator.hidden = kind == MacWSInputKindTouchUp ||
                                       kind == MacWSInputKindTouchCancel;
        if (!_directTouchIndicator.hidden)
            [self bringSubviewToFront:_directTouchIndicator];
    }
}

- (void)emitKind:(MacWSInputKind)kind touch:(UITouch *)touch point:(CGPoint)viewPoint {
    [self emitKind:kind touch:touch point:viewPoint extraFlags:0];
}

- (void)emitTouches:(NSSet<UITouch *> *)touches kind:(MacWSInputKind)kind {
    for (UITouch *touch in touches)
        [self emitKind:kind touch:touch point:[touch locationInView:self]];
}

- (void)emitPencilHoverForTouch:(UITouch *)touch point:(CGPoint)viewPoint {
    if (!touch) return;
    viewPoint = [touch preciseLocationInView:self];
    [self emitKind:MacWSInputKindHover touch:touch point:viewPoint];
    _pencilCursorView.center = viewPoint;
    _pencilCursorView.hidden = NO;
    [self bringSubviewToFront:_pencilCursorView];
}

- (void)cancelDirectTouchForMultitouch {
    _directTouchSerial++;
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    _directTouchIndicator.hidden = YES;
}

- (void)beginDirectTouchCandidate:(UITouch *)touch {
    _directTouch = touch;
    _directTouchState = MacWSDirectTouchStateCandidate;
    _directTouchStartPoint = [touch locationInView:self];
    _directTouchPreviousPoint = _directTouchStartPoint;
    _directScrollVelocity = CGPointZero;
    _directScrollFramePoint = CGPointZero;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    _directTouchStartTimestamp = touch.timestamp;
    _directTouchPreviousTimestamp = touch.timestamp;
    // A real finger now owns the interaction transaction. Any delayed
    // ConfigureWindow settlement from Scene creation would otherwise re-anchor
    // the AppKit window underneath a native title-bar drag. A subsequent UIKit
    // geometry change cancels this touch in geometryDidChange and starts its own
    // fresh configuration transaction.
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    uint64_t serial = ++_directTouchSerial;
    [_directTouchFeedback prepare];
    _directTouchIndicator.center = _directTouchStartPoint;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    _directTouchIndicator.hidden = NO;
    [self bringSubviewToFront:_directTouchIndicator];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(MACWS_DIRECT_LONG_PRESS_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (serial != self->_directTouchSerial ||
            self->_directTouch != touch ||
            self->_directTouchState != MacWSDirectTouchStateCandidate)
            return;
        CGPoint point = [touch locationInView:self];
        double travel = hypot(point.x - self->_directTouchStartPoint.x,
                              point.y - self->_directTouchStartPoint.y);
        if (MacWSDecideTouchCandidate(MACWS_DIRECT_LONG_PRESS_SECONDS,
                                      travel, false) !=
            MacWSTouchCandidateDecisionLongPress)
            return;
        // Holding only arms a primary-button drag.  Sending right-click here
        // made it structurally impossible to drag after the long press.  If
        // the armed finger is released without moving, release handling keeps
        // the useful long-press-as-context-menu behavior.
        self->_directTouchState = MacWSDirectTouchStateLongPressArmed;
        [self setDirectTouchHeld:YES dragging:NO animated:YES];
        [self->_directTouchFeedback impactOccurred];
        [self publishStatus:@"已进入拖动状态 · 滑动即可拖动"];
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The hidden UITextField owns the software keyboard. Taking first
    // responder here used to dismiss it on the very first touch inside the
    // macOS surface. Hardware-key focus remains on the Metal view whenever
    // the software keyboard is not intentionally active.
    [self restoreHardwareKeyboardFocusWithReason:@"pointer-down"];
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (touch.type == UITouchTypePencil) {
        _pencilTouch = touch;
        _pencilHoverActive = NO;
        _pencilTouchStartPoint = [touch preciseLocationInView:self];
        _pencilTouchTravel = 0;
        _pencilTouchBeganAt = touch.timestamp;
        // Pencil contact is a real tablet-button lifecycle, not a hovering
        // preview. Runtime A/B with Amadine's Rectangle tool confirmed that
        // the old Hover-only route could select the tool but could not create
        // a Path layer, while this down/move/up route with tablet metadata
        // created a visible rectangle and Path layer. Preserve UIKit's
        // precise point, pressure, altitude and azimuth; the separate
        // UIHoverGestureRecognizer remains the non-contact route.
        [self emitKind:MacWSInputKindTouchDown touch:touch
                 point:_pencilTouchStartPoint];
        _pencilCursorView.center = _pencilTouchStartPoint;
        _pencilCursorView.hidden = NO;
        [self bringSubviewToFront:_pencilCursorView];
    } else if (pointerTouch) {
        if (@available(iOS 13.4, *)) {
            // buttonMask is the complete current button state.  A primary
            // transition can briefly coexist with a stale secondary bit after
            // scene/focus handoff; never reinterpret that primary transition
            // as a right click.  A genuine secondary click has Secondary set
            // without Primary.
            BOOL primaryButton =
                (event.buttonMask & UIEventButtonMaskPrimary) != 0;
            BOOL secondaryButton =
                (event.buttonMask & UIEventButtonMaskSecondary) != 0;
            if (secondaryButton && !primaryButton) {
                _secondaryPointerTouch = touch;
                [self emitKind:MacWSInputKindSecondaryTap touch:touch
                         point:[touch locationInView:self]];
            } else {
                [self emitTouches:touches kind:MacWSInputKindTouchDown];
            }
        } else {
            [self emitTouches:touches kind:MacWSInputKindTouchDown];
        }
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (event.allTouches.count > 1) {
            [self cancelDirectTouchForMultitouch];
            _directGestureBlocked = YES;
        } else if (!_directGestureBlocked && !_directTouch && touch) {
            [self beginDirectTouchCandidate:touch];
            if (_directTouchUsesPrimaryDrag) {
                // Spatial canvases map one finger to the native primary-drag
                // lifecycle immediately. Waiting for MacWS's document-scroll
                // threshold would first emit a scroll wheel, which Maps
                // correctly interprets as zoom and cannot later reinterpret
                // as a pan. The existing Dragging move/up/cancel path retains
                // AppKit's synchronous control tracking and two-finger input
                // still cancels this contact before magnification begins.
                _directTouchState = MacWSDirectTouchStateDragging;
                [self setDirectTouchHeld:YES dragging:YES animated:YES];
                [self emitKind:MacWSInputKindTouchDown touch:touch
                         point:_directTouchStartPoint];
            }
        }
    } else if (!_trackpadTouch && touch) {
        _trackpadTouch = touch;
        _trackpadCursorWasTouched = YES;
        _externalPointerHoverActive = NO;
        _trackpadPreviousPoint = [touch locationInView:self];
        _trackpadTravel = 0;
        _trackpadBeganAt = touch.timestamp;
        _trackpadHadMultipleTouches = event.allTouches.count > 1;
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        [self updatePointerVisibility];
        uint32_t contactID = (uint32_t)touch.hash;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self->_trackpadTouch == touch &&
                self->_trackpadTravel < 6.0 &&
                !self->_trackpadHadMultipleTouches &&
                !self->_trackpadButtonDown) {
                self->_trackpadButtonDown = YES;
                [self setTrackpadPointerPressed:YES animated:YES];
                [self emitKind:MacWSInputKindTouchDown
                     framePoint:self->_trackpadCursor pressure:1.0f
                      contactID:contactID timestamp:CACurrentMediaTime()];
            }
        });
    } else if (event.allTouches.count > 1) {
        _trackpadHadMultipleTouches = YES;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        [self emitKind:MacWSInputKindTouchMove touch:_pencilTouch point:point];
        _pencilCursorView.center = point;
        _pencilCursorView.hidden = NO;
        [self bringSubviewToFront:_pencilCursorView];
    } else if (pointerTouch) {
        if (touch != _secondaryPointerTouch)
            [self emitTouches:touches kind:MacWSInputKindTouchMove];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            CGFloat travel = hypot(point.x - _directTouchStartPoint.x,
                                   point.y - _directTouchStartPoint.y);
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // dispatch_after can run before an already-recorded UIKit move
            // when the main queue was stalled.  Its LongPressArmed state is
            // provisional; the touch hardware timestamp is authoritative.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
            }
            MacWSTouchCandidateDecision decision =
                MacWSDecideTouchCandidate(
                    elapsed, travel, false);
            if (_directTouchState == MacWSDirectTouchStateCandidate &&
                decision == MacWSTouchCandidateDecisionScroll) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateScrolling;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
                _directScrollAxis = MacWSChooseDirectScrollAxis(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                [self stopScrollMomentumWithTerminalPhase:YES];
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    _directScrollFramePoint = framePoint;
                    [self emitScrollAtFramePoint:framePoint
                                     translation:CGPointZero
                                           flags:MacWSInputFlagScrollBegan
                                       timestamp:_directTouch.timestamp];
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    [self emitScrollAtFramePoint:framePoint translation:delta
                                           flags:MacWSInputFlagScrollChanged
                                       timestamp:_directTouch.timestamp];
                    NSTimeInterval dt = MAX(_directTouch.timestamp -
                        _directTouchPreviousTimestamp, 1.0 / 240.0);
                    _directScrollVelocity = CGPointMake(delta.x / dt,
                                                        delta.y / dt);
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState ==
                           MacWSDirectTouchStateCandidate &&
                       decision == MacWSTouchCandidateDecisionLongPress) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateLongPressArmed;
                [self setDirectTouchHeld:YES dragging:NO animated:YES];
                [_directTouchFeedback impactOccurred];
            } else if (_directTouchState ==
                           MacWSDirectTouchStateLongPressArmed &&
                       travel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                _directTouchState = MacWSDirectTouchStateDragging;
                [self setDirectTouchHeld:YES dragging:YES animated:YES];
                CGPoint startFrame = CGPointZero;
                if ([self framePointForViewPoint:_directTouchStartPoint
                                          output:&startFrame]) {
                    [self emitKind:MacWSInputKindTouchDown
                        framePoint:startFrame pressure:1.0f
                         contactID:(uint32_t)_directTouch.hash
                          timestamp:_directTouchStartTimestamp];
                }
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
            } else if (_directTouchState == MacWSDirectTouchStateScrolling) {
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.72 + instant.x * 0.28;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.72 + instant.y * 0.28;
                    }
                    _directScrollFramePoint = framePoint;
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
            }
            _directTouchIndicator.center = point;
        }
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (event.allTouches.count > 1) _trackpadHadMultipleTouches = YES;
        CGPoint point = [_trackpadTouch locationInView:self];
        CGFloat dx = point.x - _trackpadPreviousPoint.x;
        CGFloat dy = point.y - _trackpadPreviousPoint.y;
        _trackpadPreviousPoint = point;
        _trackpadTravel += hypot(dx, dy);
        // The two-finger pan recognizer intentionally does not cancel raw
        // touches. Once a gesture becomes multi-touch, keep its translation
        // exclusively on the scroll route so scrolling cannot also move or
        // drag the macOS pointer.
        if (!_trackpadHadMultipleTouches) {
            CGFloat scaleX = CGRectGetWidth(_contentRect) > 0
                ? [self currentFrameWidth] / CGRectGetWidth(_contentRect) : 1.0;
            CGFloat scaleY = CGRectGetHeight(_contentRect) > 0
                ? [self currentFrameHeight] / CGRectGetHeight(_contentRect) : 1.0;
            _trackpadCursor.x = fmin(fmax(_trackpadCursor.x + dx * scaleX * 1.25,
                                          0.0), [self currentFrameWidth] - 1.0);
            _trackpadCursor.y = fmin(fmax(_trackpadCursor.y + dy * scaleY * 1.25,
                                          0.0), [self currentFrameHeight] - 1.0);
            [self emitKind:_trackpadButtonDown ? MacWSInputKindTouchMove
                                                : MacWSInputKindHover
                 framePoint:_trackpadCursor pressure:_trackpadButtonDown ? 1.0f : 0.0f
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:_trackpadTouch.timestamp];
            CGFloat sourceX = _trackpadCursor.x /
                MAX([self currentFrameWidth] - 1, 1u);
            CGFloat sourceY = _trackpadCursor.y /
                MAX([self currentFrameHeight] - 1, 1u);
            CGPoint previousViewportCenter = _viewportCenter;
            if (sourceX < CGRectGetMinX(_visibleSourceRect))
                _viewportCenter.x -= CGRectGetMinX(_visibleSourceRect) - sourceX;
            else if (sourceX > CGRectGetMaxX(_visibleSourceRect))
                _viewportCenter.x += sourceX - CGRectGetMaxX(_visibleSourceRect);
            if (sourceY < CGRectGetMinY(_visibleSourceRect))
                _viewportCenter.y -= CGRectGetMinY(_visibleSourceRect) - sourceY;
            else if (sourceY > CGRectGetMaxY(_visibleSourceRect))
                _viewportCenter.y += sourceY - CGRectGetMaxY(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self updatePointerVisibility];
            // The pointer is a native UIKit subview. At 1x, moving it must not
            // re-present an unchanged multi-megabyte macOS IOSurface; redraw
            // Metal only if a zoomed viewport was actually panned.
            if (fabs(previousViewportCenter.x - _viewportCenter.x) > 0.00001 ||
                fabs(previousViewportCenter.y - _viewportCenter.y) > 0.00001)
                [self setNeedsDisplay];
        }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        [self emitKind:MacWSInputKindTouchUp touch:_pencilTouch point:point];
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else
            [self emitTouches:touches kind:MacWSInputKindTouchUp];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // The long-press timer is deliberately not authoritative.  If a
            // short tap's touch-up was queued behind that timer during a main
            // thread stall, restore Candidate so the normal tap/scroll policy
            // below classifies it from the real hardware duration.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
            }
            if (_directTouchState == MacWSDirectTouchStateCandidate) {
                MacWSTouchCandidateDecision decision = MacWSDecideTouchCandidate(
                    elapsed,
                    hypot(point.x - _directTouchStartPoint.x,
                          point.y - _directTouchStartPoint.y), true);
                if (decision == MacWSTouchCandidateDecisionLongPress) {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                    [_directTouchFeedback impactOccurred];
                } else if (decision == MacWSTouchCandidateDecisionTap) {
                    BOOL doubleTap = _directTouch.tapCount >= 2 ||
                        MacWSIsDirectDoubleTap(
                            _lastDirectTapTimestamp, _directTouch.timestamp,
                            point.x - _lastDirectTapPoint.x,
                            point.y - _lastDirectTapPoint.y);
                    if (doubleTap) {
                        _lastDirectTapTimestamp = 0.0;
                    } else {
                        _lastDirectTapTimestamp = _directTouch.timestamp;
                        _lastDirectTapPoint = point;
                    }
                    [self emitKind:MacWSInputKindTap
                             touch:_directTouch point:point
                        extraFlags:doubleTap
                            ? MacWSInputFlagDoubleClick : 0];
                } else if (decision == MacWSTouchCandidateDecisionScroll) {
                    _lastDirectTapTimestamp = 0.0;
                    // Preserve a quick flick even when UIKit coalesces it to a
                    // final sample; movement in direct mode is scrolling, not
                    // an implicit primary-button drag.
                    CGPoint framePoint = CGPointZero;
                    if ([self framePointForViewPoint:point output:&framePoint]) {
                        CGPoint delta = CGPointMake(
                            point.x - _directTouchStartPoint.x,
                            point.y - _directTouchStartPoint.y);
                        _directScrollAxis = MacWSChooseDirectScrollAxis(
                            delta.x, delta.y);
                        double deltaX = delta.x, deltaY = delta.y;
                        MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                        &deltaX, &deltaY);
                        delta = CGPointMake(deltaX, deltaY);
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:MacWSInputFlagScrollBegan
                                           timestamp:_directTouchStartTimestamp];
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchStartTimestamp, 1.0 / 120.0);
                        CGPoint velocity = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        uint16_t endedFlags = MacWSInputFlagScrollEnded;
                        if (MacWSShouldStartScrollMomentum(
                                velocity.x, velocity.y))
                            endedFlags |= MacWSInputFlagScrollWillMomentum;
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:endedFlags
                                           timestamp:_directTouch.timestamp];
                        [self startScrollMomentumWithVelocity:velocity
                                                   framePoint:framePoint];
                    }
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateLongPressArmed) {
                _lastDirectTapTimestamp = 0.0;
                CGFloat armedTravel = hypot(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                if (armedTravel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                    // Preserve hold-then-drag if UIKit coalesces the threshold
                    // crossing into the terminal touch sample.
                    CGPoint startFrame = CGPointZero;
                    if ([self framePointForViewPoint:_directTouchStartPoint
                                              output:&startFrame]) {
                        [self emitKind:MacWSInputKindTouchDown
                            framePoint:startFrame pressure:1.0f
                             contactID:(uint32_t)_directTouch.hash
                              timestamp:_directTouchStartTimestamp];
                        [self emitKind:MacWSInputKindTouchMove
                                 touch:_directTouch point:point];
                        [self emitKind:MacWSInputKindTouchUp
                                 touch:_directTouch point:point];
                    }
                } else {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateDragging) {
                _lastDirectTapTimestamp = 0.0;
                [self emitKind:MacWSInputKindTouchUp touch:_directTouch
                         point:point];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                _lastDirectTapTimestamp = 0.0;
                CGPoint framePoint = _directScrollFramePoint;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        // Include the final hardware segment in release
                        // velocity. Omitting it made a short iOS-style flick
                        // inherit an older, often sub-threshold sample and
                        // silently skip the momentum phase.
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.55 + instant.x * 0.45;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.55 + instant.y * 0.45;
                    }
                    _directScrollFramePoint = framePoint;
                }
                uint16_t endedFlags = MacWSInputFlagScrollEnded;
                if (MacWSShouldStartScrollMomentum(
                        _directScrollVelocity.x, _directScrollVelocity.y))
                    endedFlags |= MacWSInputFlagScrollWillMomentum;
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:endedFlags
                                   timestamp:_directTouch.timestamp];
                [self startScrollMomentumWithVelocity:_directScrollVelocity
                                           framePoint:_directScrollFramePoint];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            [self setDirectTouchHeld:NO dragging:NO animated:NO];
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        MacWSInputKind kind = _trackpadButtonDown ? MacWSInputKindTouchUp
            : MacWSInputKindTap;
        if (_trackpadButtonDown ||
            (!_trackpadHadMultipleTouches && _trackpadTravel < 10.0 &&
             touch.timestamp - _trackpadBeganAt < 0.40)) {
            [self emitKind:kind framePoint:_trackpadCursor pressure:0
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        [self emitKind:MacWSInputKindTouchCancel touch:_pencilTouch
                 point:[_pencilTouch preciseLocationInView:self]];
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else
            [self emitTouches:touches kind:MacWSInputKindTouchCancel];
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                         point:[_directTouch locationInView:self]];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:MacWSInputFlagScrollCancelled
                                   timestamp:_directTouch.timestamp];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            [self setDirectTouchHeld:NO dragging:NO animated:NO];
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (_trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesCancelled:touches withEvent:event];
}

- (void)resetViewportZoom {
    CGFloat previousZoom = _viewportZoom;
    CGPoint previousCenter = _viewportCenter;
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _contentGesturesPassthrough = NO;
    [self updateZoomHUD];
    [self setNeedsDisplay];
    MacWSLog(@"viewport-reset previous-zoom=%.3f previous-center=(%.3f,%.3f) zoom=%.3f center=(%.3f,%.3f)",
             previousZoom, previousCenter.x, previousCenter.y,
             _viewportZoom, _viewportCenter.x, _viewportCenter.y);
}

- (void)viewportZoomToggled:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    if ([self isViewportZoomed]) {
        [self resetViewportZoom];
        [self publishStatus:@"已退出放大视角"];
    } else {
        if ([self currentFrameWidth] == 0 || [self currentFrameHeight] == 0)
            return;
        simd_float4 unusedVertices[4];
        [self updateContentRectAndVertices:unusedVertices];
        CGPoint location = [recognizer locationInView:self];
        CGPoint normalized = CGPointMake(
            self.bounds.size.width > 0
                ? location.x / self.bounds.size.width : 0.5,
            self.bounds.size.height > 0
                ? location.y / self.bounds.size.height : 0.5);
        CGPoint sourcePoint = CGPointMake(
            CGRectGetMinX(_visibleSourceRect) +
                normalized.x * CGRectGetWidth(_visibleSourceRect),
            CGRectGetMinY(_visibleSourceRect) +
                normalized.y * CGRectGetHeight(_visibleSourceRect));
        _viewportZoom = _fixedZoomScale;
        // First derive the enlarged visible size, then choose a center that
        // keeps the tapped source point under the same two-finger centroid.
        // The viewport clamp may adjust this only near texture boundaries.
        [self updateContentRectAndVertices:unusedVertices];
        MacWSNormalizedPoint requestedCenter = MacWSViewportCenterKeepingAnchor(
            (MacWSNormalizedRect){
                .x = CGRectGetMinX(_visibleSourceRect),
                .y = CGRectGetMinY(_visibleSourceRect),
                .width = CGRectGetWidth(_visibleSourceRect),
                .height = CGRectGetHeight(_visibleSourceRect),
            },
            (MacWSNormalizedPoint){sourcePoint.x, sourcePoint.y},
            normalized.x, normalized.y);
        _viewportCenter = CGPointMake(requestedCenter.x, requestedCenter.y);
        [self updateContentRectAndVertices:unusedVertices];
        [self updateZoomHUD];
        [self setNeedsDisplay];
        [self publishStatus:[NSString stringWithFormat:
            @"已进入 %.1f× 放大视角", _fixedZoomScale]];
    }
}

- (BOOL)scrollFramePointForRecognizer:(UIGestureRecognizer *)recognizer
                               output:(CGPoint *)scrollPoint {
    CGPoint point = _trackpadCursor;
    if (self.inputMode == MacWSHostInputModeDirect) {
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&point]) return NO;
    } else {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (point.x < 0 || point.y < 0 ||
            point.x >= width || point.y >= height)
            point = CGPointMake(width * 0.5, height * 0.5);
    }
    if (scrollPoint) *scrollPoint = point;
    return YES;
}

- (void)emitMagnifyAtFramePoint:(CGPoint)framePoint
                          amount:(CGFloat)amount
                           flags:(uint16_t)flags
                       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled || !isfinite(amount)) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindMagnify,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = (float)amount,
        .contactID = 0x50494e43u, // "PINC"
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitRotationAtFramePoint:(CGPoint)framePoint
                         degrees:(CGFloat)degrees
                           flags:(uint16_t)flags
                       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled || !isfinite(degrees)) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindRotate,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = (float)degrees,
        .contactID = 0x524f5441u, // "ROTA"
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitScrollAtFramePoint:(CGPoint)framePoint
                    translation:(CGPoint)translation
                          flags:(uint16_t)flags
                      timestamp:(NSTimeInterval)timestamp {
    CGFloat direction = self.inputMode == MacWSHostInputModeDirect ? 1.0 : -1.0;
    [self emitScrollAtFramePoint:framePoint translation:translation
                          flags:flags timestamp:timestamp
                          source:MacWSInputSourceFinger
               directionMultiplier:direction];
}

- (void)emitScrollAtFramePoint:(CGPoint)framePoint
                    translation:(CGPoint)translation
                          flags:(uint16_t)flags
                      timestamp:(NSTimeInterval)timestamp
                         source:(MacWSInputSource)source
            directionMultiplier:(CGFloat)direction {
    if (!self.isMacWSInputEnabled) return;
    // UIKit translation is measured in Host points, while AppKit precise
    // scrollingDelta is measured in target logical points. The old fixed 2x
    // multiplier made a Retina 1770px/885pt Terminal move roughly twice the
    // finger distance. Derive the transform from the current exact surface,
    // viewport and backing scale so scrolling stays 1:1 at every Scene size.
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 1.0;
    CGFloat contentWidth = CGRectGetWidth(_contentRect);
    CGFloat contentHeight = CGRectGetHeight(_contentRect);
    CGFloat sourceWidth = [self currentFrameWidth] *
        CGRectGetWidth(_visibleSourceRect) / backingScale;
    CGFloat sourceHeight = [self currentFrameHeight] *
        CGRectGetHeight(_visibleSourceRect) / backingScale;
    CGFloat scaleX = contentWidth > 1.0 ? sourceWidth / contentWidth : 1.0;
    CGFloat scaleY = contentHeight > 1.0 ? sourceHeight / contentHeight : 1.0;
    scaleX = fmin(fmax(scaleX, 0.25), 4.0);
    scaleY = fmin(fmax(scaleY, 0.25), 4.0);
    // Direct manipulation follows iOS: moving content down requests a
    // positive AppKit scroll delta. Relative and hardware trackpads keep
    // MacBook-style natural scrolling, whose UIKit translation is inverted at
    // this bridge. The caller supplies the input-device policy so a physical
    // scroll never changes direction when the HUD touch mode is switched.
    float horizontal = (float)(direction * translation.x * scaleX);
    float vertical = (float)(direction * translation.y * scaleY);
    BOOL momentum = (flags & MacWSInputFlagScrollMomentum) != 0;
    BOOL began = (flags & MacWSInputFlagScrollBegan) != 0;
    BOOL changed = (flags & MacWSInputFlagScrollChanged) != 0;
    BOOL terminal = (flags & (MacWSInputFlagScrollEnded |
                              MacWSInputFlagScrollCancelled)) != 0;
    if (began && !momentum) _scrollEmissionResidual = CGPointZero;
    if (changed) {
        // CGEventCreateScrollWheelEvent2 accepts integral pixel deltas. Keep
        // the sub-pixel remainder across 60/120 Hz UIKit and deceleration
        // samples so slow motion is accumulated into real pixels instead of
        // every tail sample being rounded independently to zero.
        double accumulatedX = horizontal + _scrollEmissionResidual.x;
        double accumulatedY = vertical + _scrollEmissionResidual.y;
        horizontal = (float)nearbyint(accumulatedX);
        vertical = (float)nearbyint(accumulatedY);
        _scrollEmissionResidual.x = accumulatedX - horizontal;
        _scrollEmissionResidual.y = accumulatedY - vertical;
    }
    // Preserve every UIKit movement sample. AppInputBridge already performs
    // lossless adjacent-scroll coalescing when the consumer is backpressured;
    // a second one-logical-pixel dead zone here delayed slow direct
    // manipulation by one or more display frames in Maps and web content.
    uint32_t horizontalBits = 0;
    memcpy(&horizontalBits, &horizontal, sizeof(horizontalBits));
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindScroll,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = vertical,
        .contactID = horizontalBits,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (terminal &&
        (momentum || !(flags & MacWSInputFlagScrollWillMomentum)))
        _scrollEmissionResidual = CGPointZero;
}

- (void)indirectScrolled:(UIPanGestureRecognizer *)recognizer
    API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    CGPoint scrollPoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&scrollPoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopScrollMomentumWithTerminalPhase:YES];
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollBegan
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            break;
        case UIGestureRecognizerStateChanged:
            if (translation.x != 0.0 || translation.y != 0.0) {
                [self emitScrollAtFramePoint:scrollPoint
                                 translation:translation
                                       flags:MacWSInputFlagScrollChanged
                                   timestamp:timestamp
                                      source:MacWSInputSourceIndirectPointer
                         directionMultiplier:-1.0];
            }
            break;
        case UIGestureRecognizerStateEnded:
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollEnded
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            break;
        default:
            break;
    }
}

- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase {
    if (terminalPhase && _scrollMomentumDisplayLink) {
        [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollEnded |
                                     MacWSInputFlagScrollMomentum
                           timestamp:CACurrentMediaTime()];
    }
    [_scrollMomentumDisplayLink invalidate];
    _scrollMomentumDisplayLink = nil;
    _scrollMomentumVelocity = CGPointZero;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumBegan = NO;
}

- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint {
    if (!MacWSShouldStartScrollMomentum(velocity.x, velocity.y)) return;
    [self stopScrollMomentumWithTerminalPhase:NO];
    _scrollMomentumVelocity = velocity;
    _scrollMomentumFramePoint = framePoint;
    _scrollMomentumBegan = NO;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumDisplayLink = [CADisplayLink
        displayLinkWithTarget:self selector:@selector(scrollMomentumTick:)];
    NSInteger maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    _scrollMomentumDisplayLink.preferredFramesPerSecond =
        MAX(60, MIN(maximumFPS, 120));
    [_scrollMomentumDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                     forMode:NSRunLoopCommonModes];
}

- (void)scrollMomentumTick:(CADisplayLink *)link {
    CFTimeInterval timestamp = link.timestamp;
    CFTimeInterval deltaTime = _scrollMomentumLastTimestamp > 0
        ? timestamp - _scrollMomentumLastTimestamp : link.duration;
    _scrollMomentumLastTimestamp = timestamp;
    deltaTime = fmin(fmax(deltaTime, 1.0 / 240.0), 1.0 / 20.0);
    // UIScrollView's normal deceleration rate is approximately 0.998 per ms.
    CGFloat decay = pow(0.998, deltaTime * 1000.0);
    _scrollMomentumVelocity.x *= decay;
    _scrollMomentumVelocity.y *= decay;
    CGFloat speed = hypot(_scrollMomentumVelocity.x,
                          _scrollMomentumVelocity.y);
    if (speed < 18.0) {
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    uint16_t phase = _scrollMomentumBegan
        ? MacWSInputFlagScrollChanged : MacWSInputFlagScrollBegan;
    _scrollMomentumBegan = YES;
    CGPoint translation = CGPointMake(_scrollMomentumVelocity.x * deltaTime,
                                      _scrollMomentumVelocity.y * deltaTime);
    [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                     translation:translation
                           flags:phase | MacWSInputFlagScrollMomentum
                       timestamp:CACurrentMediaTime()];
}

- (void)twoFingerPanned:(UIPanGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    BOOL moveViewport = self.inputMode == MacWSHostInputModeDirect &&
        [self isViewportZoomed] && !_contentGesturesPassthrough;
    if (moveViewport) {
        if (self.bounds.size.width > 0 && self.bounds.size.height > 0) {
            _viewportCenter.x -= translation.x / self.bounds.size.width *
                CGRectGetWidth(_visibleSourceRect);
            _viewportCenter.y -= translation.y / self.bounds.size.height *
                CGRectGetHeight(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self setNeedsDisplay];
        }
        return;
    }
    CGPoint scrollPoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&scrollPoint])
        return;
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopScrollMomentumWithTerminalPhase:YES];
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollBegan
                               timestamp:CACurrentMediaTime()];
            break;
        case UIGestureRecognizerStateChanged:
            if (translation.x != 0 || translation.y != 0) {
                [self emitScrollAtFramePoint:scrollPoint translation:translation
                                       flags:MacWSInputFlagScrollChanged
                                   timestamp:CACurrentMediaTime()];
            }
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint velocity = [recognizer velocityInView:self];
            uint16_t endedFlags = MacWSInputFlagScrollEnded;
            if (MacWSShouldStartScrollMomentum(velocity.x, velocity.y))
                endedFlags |= MacWSInputFlagScrollWillMomentum;
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:endedFlags
                               timestamp:CACurrentMediaTime()];
            [self startScrollMomentumWithVelocity:velocity
                                       framePoint:scrollPoint];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
            [self stopScrollMomentumWithTerminalPhase:NO];
            break;
        default:
            break;
    }
}

- (void)pinched:(UIPinchGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint framePoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&framePoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            // UIKit has already accumulated real movement while Possible,
            // including the short three-finger chord interval. Preserve that
            // first delta; resetting it here caused the visible pinch dead
            // zone even after gesture recognition had succeeded.
            CGFloat initialAmount = recognizer.scale - 1.0;
            recognizer.scale = 1.0;
            [self emitMagnifyAtFramePoint:framePoint amount:initialAmount
                                    flags:MacWSInputFlagGestureBegan
                                timestamp:timestamp];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            // UIPinchGestureRecognizer.scale is cumulative. AppKit's
            // magnification is an incremental delta, so consume and reset the
            // ratio at every UIKit sample instead of accelerating over time.
            CGFloat amount = recognizer.scale - 1.0;
            recognizer.scale = 1.0;
            if (fabs(amount) > 0.00001) {
                [self emitMagnifyAtFramePoint:framePoint amount:amount
                                        flags:MacWSInputFlagGestureChanged
                                    timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureEnded
                                timestamp:timestamp];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureCancelled
                                timestamp:timestamp];
            break;
        default:
            break;
    }
}

- (void)rotated:(UIRotationGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint framePoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&framePoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            recognizer.rotation = 0.0;
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureBegan
                                 timestamp:timestamp];
            break;
        case UIGestureRecognizerStateChanged: {
            // UIKit reports cumulative radians; Ventura NSEvent.rotation is
            // an incremental degree value. Consume each delta once.
            CGFloat degrees =
                MacWSAppKitRotationDegreesForUIKitRadians(
                    recognizer.rotation);
            recognizer.rotation = 0.0;
            if (fabs(degrees) > 0.0001) {
                [self emitRotationAtFramePoint:framePoint degrees:degrees
                                         flags:MacWSInputFlagGestureChanged
                                     timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureEnded
                                 timestamp:timestamp];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureCancelled
                                 timestamp:timestamp];
            break;
        default:
            break;
    }
}

- (void)threeFingerChordChanged:
        (MacWSThreeFingerChordGateGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        MacWSLog(@"three-finger-chord admitted grace-ms=%.0f touches=%lu",
                 MACWS_THREE_FINGER_CHORD_GRACE_SECONDS * 1000.0,
                 (unsigned long)recognizer.numberOfTouches);
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled) {
        MacWSLog(@"three-finger-chord terminal state=%ld",
                 (long)recognizer.state);
    }
}

- (int32_t)dockSystemGestureTargetPID {
    // The system input owner belongs to the desktop session contract.  A
    // retained final-composite Dock layer can outlive the process that created
    // it, so prefer the exact current launchd owner supplied by hostd.
    if (_systemInputPID > 1 &&
        MacWSAppInputEndpointReady(_systemInputPID))
        return _systemInputPID;

    // displayd marks only real Dock-owned capture layers with
    // GlobalSystemSurface.  Use that catalog identity instead of guessing a
    // PID from process names on the iOS side or borrowing the front app's CGS
    // connection as the old keyboard-shortcut path did.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSStreamFrameDescriptor descriptor =
            _overlayFrames[key].descriptor;
        if ((descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0 &&
            descriptor.layerOwnerPID > 1 &&
            MacWSAppInputEndpointReady(descriptor.layerOwnerPID))
            return descriptor.layerOwnerPID;
    }
    return 0;
}

- (void)emitSystemGestureAxis:(MacWSSystemGestureAxis)axis
                      progress:(CGFloat)progress
                      velocity:(CGFloat)velocity
                         flags:(uint16_t)flags
                     timestamp:(NSTimeInterval)timestamp {
    BOOL terminalPhase = (flags & (MacWSInputFlagGestureEnded |
        MacWSInputFlagGestureCancelled)) != 0;
    // Once Begin reached Dock, its terminal record is mandatory even if a
    // Scene transition has already disabled new pointer input. The endpoint
    // and geometry below are latched precisely so this close can outlive the
    // current DisplayStream/UI input-ready state.
    if ((!self.isMacWSInputEnabled && !terminalPhase) ||
        !_threeFingerSystemGestureActive ||
        (axis != MacWSSystemGestureAxisHorizontal &&
         axis != MacWSSystemGestureAxisVertical) ||
        !isfinite(progress) || !isfinite(velocity)) return;
    // A hardware gesture has one device/endpoint for its complete phase
    // lifetime.  Mission Control can temporarily remove or reorder Dock's
    // captured layers, and a UIKit scene transition can unsubscribe the
    // fullscreen stream before delivering its recognizer cancellation.  Use
    // the Begin-time identity rather than re-resolving a moving capture graph
    // for every Changed/End record.
    int32_t dockPID = _threeFingerSystemGestureTargetPID;
    uint32_t width = _threeFingerSystemGestureFrameWidth;
    uint32_t height = _threeFingerSystemGestureFrameHeight;
    if (width == 0 || height == 0 || dockPID <= 1) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindSystemGesture,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = width * 0.5f,
        .y = height * 0.5f,
        .pressure = (float)fmax(-2.0, fmin(progress, 2.0)),
        .contactID = _threeFingerSystemGestureContactID,
        .frameWidth = width,
        .frameHeight = height,
        .targetPID = dockPID,
        .source = MacWSInputSourceFinger,
        .flags = flags | MacWSInputFlagGlobalSystemSurface,
        .buttons = axis,
        .altitude = (float)fmax(-12.0, fmin(velocity, 12.0)),
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)resetActiveThreeFingerSystemGesture {
    _threeFingerSystemGestureActive = NO;
    _threeFingerSystemGestureAxis = 0;
    _threeFingerSystemGestureReferenceDistance = 0.0;
    _threeFingerSystemGestureContactID = 0;
    _threeFingerSystemGestureTargetPID = 0;
    _threeFingerSystemGestureFrameWidth = 0;
    _threeFingerSystemGestureFrameHeight = 0;
    _threeFingerSystemGestureLastProgress = 0.0;
    _threeFingerSystemGestureLastVelocity = 0.0;
}

- (void)cancelActiveThreeFingerSystemGestureAtTimestamp:
        (NSTimeInterval)timestamp {
    if (!_threeFingerSystemGestureActive) return;
    [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                       progress:_threeFingerSystemGestureLastProgress
                       velocity:_threeFingerSystemGestureLastVelocity
                          flags:MacWSInputFlagGestureCancelled
                      timestamp:timestamp > 0.0 ? timestamp :
                          CACurrentMediaTime()];
    [self resetActiveThreeFingerSystemGesture];
}

- (void)threeFingerPanned:(UIPanGestureRecognizer *)recognizer {
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self cancelActiveThreeFingerSystemGestureAtTimestamp:
            CACurrentMediaTime()];
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    BOOL terminalState =
        recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed;
    // UIKit is allowed to report cancellation after the Scene has suspended
    // or changed stream mode.  A live latched gesture must still close; only
    // an attempt to begin a new gesture requires a current fullscreen stream.
    if (_streamClient.mode != MacWSStreamModeFullscreen &&
        !_threeFingerSystemGestureActive) return;
    if (terminalState && !_threeFingerSystemGestureActive) return;
    CGPoint translation = [recognizer translationInView:self];
    CGPoint velocity = [recognizer velocityInView:self];
    NSTimeInterval timestamp = CACurrentMediaTime();
    if (!_threeFingerSystemGestureActive &&
        recognizer.state == UIGestureRecognizerStateChanged) {
        CGFloat minimumDimension = MIN(self.bounds.size.width,
                                       self.bounds.size.height);
        _threeFingerSystemGestureAxis =
            MacWSSystemGestureAxisForTranslation(
                translation.x, translation.y, minimumDimension);
        if (_threeFingerSystemGestureAxis == 0) return;
        _threeFingerSystemGestureReferenceDistance =
            MacWSSystemGestureReferenceDistance(minimumDimension);
        _threeFingerSystemGestureContactID =
            0x33464700u | ((++_directTouchSerial) & 0xffu); // "3FG"
        _threeFingerSystemGestureTargetPID =
            [self dockSystemGestureTargetPID];
        _threeFingerSystemGestureFrameWidth = [self currentFrameWidth];
        _threeFingerSystemGestureFrameHeight = [self currentFrameHeight];
        if (_threeFingerSystemGestureTargetPID <= 1 ||
            _threeFingerSystemGestureFrameWidth == 0 ||
            _threeFingerSystemGestureFrameHeight == 0) {
            [self resetActiveThreeFingerSystemGesture];
            return;
        }
        _threeFingerSystemGestureActive = YES;
        CGFloat initialDisplacement = _threeFingerSystemGestureAxis ==
            MacWSSystemGestureAxisHorizontal ? translation.x : translation.y;
        CGFloat initialVelocity = _threeFingerSystemGestureAxis ==
            MacWSSystemGestureAxisHorizontal ? velocity.x : velocity.y;
        [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                           progress:MacWSSystemGestureProgressForDisplacement(
                                _threeFingerSystemGestureAxis,
                                initialDisplacement,
                                _threeFingerSystemGestureReferenceDistance)
                           velocity:MacWSSystemGestureProgressForDisplacement(
                                _threeFingerSystemGestureAxis,
                                initialVelocity,
                                _threeFingerSystemGestureReferenceDistance)
                              flags:MacWSInputFlagGestureBegan
                          timestamp:timestamp];
    }
    if (!_threeFingerSystemGestureActive) return;

    CGFloat displacement = _threeFingerSystemGestureAxis ==
        MacWSSystemGestureAxisHorizontal ? translation.x : translation.y;
    CGFloat pointVelocity = _threeFingerSystemGestureAxis ==
        MacWSSystemGestureAxisHorizontal ? velocity.x : velocity.y;
    // Use Dock's RE- and runtime-confirmed per-axis sign convention. A single
    // Cartesian sign flip misroutes finger-up to the disabled App Expose slot
    // instead of the live native Mission Control fluid controller.
    CGFloat progress = MacWSSystemGestureProgressForDisplacement(
        _threeFingerSystemGestureAxis, displacement,
        _threeFingerSystemGestureReferenceDistance);
    CGFloat progressVelocity = MacWSSystemGestureProgressForDisplacement(
        _threeFingerSystemGestureAxis, pointVelocity,
        _threeFingerSystemGestureReferenceDistance);
    _threeFingerSystemGestureLastProgress = progress;
    _threeFingerSystemGestureLastVelocity = progressVelocity;
    uint16_t phase = 0;
    switch (recognizer.state) {
        case UIGestureRecognizerStateChanged:
            phase = MacWSInputFlagGestureChanged;
            break;
        case UIGestureRecognizerStateEnded:
            phase = MacWSInputFlagGestureEnded;
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            phase = MacWSInputFlagGestureCancelled;
            break;
        default:
            return;
    }
    [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                       progress:progress velocity:progressVelocity
                          flags:phase timestamp:timestamp];
    if (phase & (MacWSInputFlagGestureEnded |
                 MacWSInputFlagGestureCancelled)) {
        [self resetActiveThreeFingerSystemGesture];
    }
}

- (void)runPerformanceGestureScenario:(NSString *)scenario
    completion:(void (^)(BOOL success, NSString *message))completion {
    void (^finish)(BOOL, NSString *) = completion
        ? [completion copy]
        : [^(BOOL success, NSString *message) {
            (void)success;
            (void)message;
        } copy];
    if (!self.isMacWSInputEnabled) {
        finish(NO, @"触控桥尚未就绪");
        return;
    }

    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (!width || !height) {
        finish(NO, @"DisplayStream 尚无有效画面尺寸");
        return;
    }
    CGPoint center = CGPointMake(width * 0.5, height * 0.5);
    BOOL systemScenario = [scenario hasPrefix:@"three-"] ||
        [scenario isEqualToString:@"mission-select"];
    if (!systemScenario && _streamClient.mode == MacWSStreamModeFullscreen &&
        ![self performanceVisiblePointForTargetPID:self.targetPID
                                             point:&center]) {
        finish(NO, @"目标应用当前没有可见、可命中的性能测试区域");
        return;
    }

    MacWSPerformanceGestureScenario *adapter =
        [MacWSPerformanceGestureScenario new];
    adapter.name = scenario;
    adapter.targetPoint = center;
    CGPoint alternate = center;
    if (_streamClient.mode == MacWSStreamModeFullscreen) {
        int32_t centerPID = 0;
        uint32_t centerWindowID = 0;
        if ([self resolveFullscreenLayerAtPoint:center pid:&centerPID
                                       windowID:&centerWindowID
                                     descriptor:NULL]) {
            static const CGFloat offsets[][2] = {
                {16.0, 0.0}, {-16.0, 0.0}, {0.0, 16.0},
                {0.0, -16.0}, {24.0, 0.0}, {-24.0, 0.0},
            };
            for (NSUInteger index = 0;
                 index < sizeof(offsets) / sizeof(offsets[0]); index++) {
                CGPoint candidate = CGPointMake(
                    center.x + offsets[index][0],
                    center.y + offsets[index][1]);
                int32_t candidatePID = 0;
                uint32_t candidateWindowID = 0;
                if ([self resolveFullscreenLayerAtPoint:candidate
                                                    pid:&candidatePID
                                               windowID:&candidateWindowID
                                             descriptor:NULL] &&
                    candidatePID == centerPID &&
                    candidateWindowID == centerWindowID) {
                    alternate = candidate;
                    break;
                }
            }
        }
    } else {
        alternate.x = fmin(width - 1.0, center.x + 16.0);
    }
    adapter.alternateTargetPoint = alternate;
    adapter.frameWidth = width;
    adapter.frameHeight = height;
    adapter.targetPID = self.targetPID;
    adapter.dockPID = systemScenario ? [self dockSystemGestureTargetPID] : 0;
    adapter.fullscreen =
        _streamClient.mode == MacWSStreamModeFullscreen;
    adapter.contactID = 0x50524600u |
        ((++_directTouchSerial) & 0xffu); // "PRF"
    adapter.pointerFlags = MacWSInputFlagLatencyDiagnostic;

    __weak typeof(self) weakSelf = self;
    __weak MacWSPerformanceGestureScenario *weakAdapter = adapter;
    adapter.emitPointer = ^(MacWSInputKind kind, CGPoint point,
                            float pressure, uint16_t flags) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        MacWSPerformanceGestureScenario *strongAdapter = weakAdapter;
        if (!strongSelf || !strongAdapter) return;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            .sceneID = [strongSelf inputSceneIDWithModifiers:0],
            .timestamp = CACurrentMediaTime(),
            .x = (float)point.x,
            .y = (float)point.y,
            .pressure = pressure,
            .contactID = strongAdapter.contactID,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = strongSelf.targetPID,
            // The performance hover is the regression surrogate for the
            // Magic Keyboard's UIHoverGestureRecognizer path.  Preserve its
            // indirect-pointer source identity instead of labelling that one
            // stream as a finger; down/move/up scenarios remain direct touch.
            .source = kind == MacWSInputKindHover
                ? MacWSInputSourceIndirectPointer
                : MacWSInputSourceFinger,
            .flags = flags,
            .sampleSequence = ++strongSelf->_inputSampleSequence,
        };
        [strongSelf.statusDelegate metalView:strongSelf emittedInput:record];
    };
    adapter.emitScroll = ^(CGPoint point, CGPoint translation,
                           uint16_t flags, NSTimeInterval timestamp) {
        [weakSelf emitScrollAtFramePoint:point translation:translation
                                   flags:flags timestamp:timestamp];
    };
    adapter.emitMagnify = ^(CGPoint point, CGFloat amount, uint16_t flags,
                            NSTimeInterval timestamp) {
        [weakSelf emitMagnifyAtFramePoint:point amount:amount flags:flags
                                timestamp:timestamp];
    };
    adapter.startMomentum = ^(CGPoint velocity, CGPoint point) {
        [weakSelf startScrollMomentumWithVelocity:velocity framePoint:point];
    };
    adapter.stopMomentum = ^(BOOL terminalPhase) {
        [weakSelf stopScrollMomentumWithTerminalPhase:terminalPhase];
    };
    adapter.prepareSystemGesture = ^(
            MacWSSystemGestureAxis axis, uint32_t contactID, int32_t dockPID,
            uint32_t frameWidth, uint32_t frameHeight, CGFloat velocity) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_threeFingerSystemGestureActive = YES;
        strongSelf->_threeFingerSystemGestureAxis = axis;
        strongSelf->_threeFingerSystemGestureContactID = contactID;
        strongSelf->_threeFingerSystemGestureTargetPID = dockPID;
        strongSelf->_threeFingerSystemGestureFrameWidth = frameWidth;
        strongSelf->_threeFingerSystemGestureFrameHeight = frameHeight;
        strongSelf->_threeFingerSystemGestureLastProgress = 0.0;
        strongSelf->_threeFingerSystemGestureLastVelocity = velocity;
    };
    adapter.emitSystemGesture = ^(
            MacWSSystemGestureAxis axis, CGFloat progress, CGFloat velocity,
            uint16_t flags, NSTimeInterval timestamp) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_threeFingerSystemGestureLastProgress = progress;
        strongSelf->_threeFingerSystemGestureLastVelocity = velocity;
        [strongSelf emitSystemGestureAxis:axis progress:progress
                                 velocity:velocity flags:flags
                                timestamp:timestamp];
    };
    adapter.resetSystemGesture = ^{
        [weakSelf resetActiveThreeFingerSystemGesture];
    };
    adapter.missionControlDidCommit = ^{
        // Dock's native modal router must see a real pointer-family event
        // before a card click. Prime that exact hit context immediately after
        // Mission Control settles; this is a normal hover and is also what a
        // physical trackpad produces before pressing.
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        MacWSPerformanceGestureScenario *strongAdapter = weakAdapter;
        if (!strongAdapter) return;
        strongAdapter.emitPointer(
            MacWSInputKindHover, strongAdapter.targetPoint, 0.0f,
            MacWSInputFlagLatencyDiagnostic);
    };
    [adapter runWithCompletion:finish];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _threeFingerPanRecognizer ||
        gestureRecognizer == _threeFingerChordGate)
        return self.isMacWSInputEnabled &&
            _streamClient.mode == MacWSStreamModeFullscreen;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    // A physical two-finger gesture can carry translation, scale and rotation
    // in the same sample. Preserve every native stream so Maps can pan, zoom
    // and rotate without UIKit forcing one recognizer to win.
    NSSet *twoFingerRecognizers = [NSSet setWithObjects:
        _twoFingerPanRecognizer, _pinchRecognizer, _rotationRecognizer, nil];
    BOOL gateAndThreeFinger =
        (gestureRecognizer == _threeFingerChordGate &&
         otherGestureRecognizer == _threeFingerPanRecognizer) ||
        (otherGestureRecognizer == _threeFingerChordGate &&
         gestureRecognizer == _threeFingerPanRecognizer);
    if (gateAndThreeFinger) return YES;
    return [twoFingerRecognizers containsObject:gestureRecognizer] &&
           [twoFingerRecognizers containsObject:otherGestureRecognizer];
}

- (void)trackpadSecondaryTapped:(UITapGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled ||
        recognizer.state != UIGestureRecognizerStateEnded) return;
    if (self.inputMode == MacWSHostInputModeDirect) {
        CGPoint framePoint = CGPointZero;
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&framePoint]) return;
        [self emitKind:MacWSInputKindSecondaryTap framePoint:framePoint
             pressure:0 contactID:0x53454332u
             timestamp:CACurrentMediaTime()];
        return;
    }
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
        _trackpadCursor.x >= width || _trackpadCursor.y >= height)
        _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
    [self emitKind:MacWSInputKindSecondaryTap framePoint:_trackpadCursor
         pressure:0 contactID:0x53454332u timestamp:CACurrentMediaTime()];
}

- (void)hovered:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    if (recognizer.state == UIGestureRecognizerStateBegan)
        [self restoreHardwareKeyboardFocusWithReason:@"pointer-enter"];
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceIndirectPointer,
        .sampleSequence = ++_inputSampleSequence,
    };
    _externalPointerHoverActive = recognizer.state ==
            UIGestureRecognizerStateBegan ||
        recognizer.state == UIGestureRecognizerStateChanged;
    _trackpadCursor = framePoint;
    if (self.inputMode == MacWSHostInputModeTrackpad)
        [self updatePointerVisibility];
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)pencilHovered:(UIHoverGestureRecognizer *)recognizer
    API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint = CGPointZero;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    BOOL active = recognizer.state == UIGestureRecognizerStateBegan ||
                  recognizer.state == UIGestureRecognizerStateChanged;
    _pencilHoverActive = active;
    _pencilCursorView.center = viewPoint;
    [self updatePointerVisibility];
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourcePencil,
        .flags = MacWSInputFlagPreciseLocation,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)streamClient:(MacWSStreamClient *)client
       statusChanged:(NSString *)status
           connected:(BOOL)connected {
    (void)client;
    MacWSLog(@"display-stream status connected=%@ message=%@",
             connected ? @"YES" : @"NO", status ?: @"");
    _streamConnected = connected;
    if (!connected) {
        _latestWindows = @[];
        _catalogRevalidationRequestedForPresentation = NO;
    }
    if (!connected && (_surfaceFrame || _overlayFrames.count)) {
        _framePollDisplayLink.paused = self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled();
        if (_surfaceFrame) {
            if (_surfaceFrame.descriptor.leaseToken ==
                _submittedSurfaceLeaseToken)
                [_retiredSurfaceFrames addObject:_surfaceFrame];
            else
                [_streamClient releaseFrame:_surfaceFrame];
        }
        for (NSNumber *key in _overlayFrames) {
            MacWSSurfaceFrame *frame = _overlayFrames[key];
            if (frame.descriptor.leaseToken ==
                [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
                [_retiredSurfaceFrames addObject:frame];
            else
                [_streamClient releaseFrame:frame];
        }
        _surfaceFrame = nil;
        _surfaceTexture = nil;
        [_overlayFrames removeAllObjects];
        [_overlayTextures removeAllObjects];
        [_submittedOverlayLeaseTokens removeAllObjects];
        _submittedSurfaceLeaseToken = 0;
        _sortedOverlayKeys = nil;
        _sourceTexture = nil;
        _textureWidth = 0;
        _textureHeight = 0;
        [self updateDrawableResolution];
        [self setNeedsDisplay];
    }
    if (!_surfaceFrame) [self publishStatus:status];
}

- (void)streamClient:(MacWSStreamClient *)client
      receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)client;
    _latestWindows = [windows copy];
    NSMutableSet<NSNumber *> *spatialCanvasPIDs = [NSMutableSet set];
    NSMutableSet<NSNumber *> *fullscreenCanvasPIDs =
        [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
    // A fullscreen conversion briefly removes every catalog entry for the
    // game while its process and AppInput endpoint remain alive. Preserve the
    // controller-validated current target even during the earlier
    // endpoint-not-yet-registered phase. A real target change removes that
    // PID in setTargetPID:; non-target capabilities still use endpoint
    // liveness as their revocation edge.
    for (NSNumber *pidValue in [fullscreenCanvasPIDs.allObjects copy]) {
        BOOL controllerValidatedCurrentTarget =
            pidValue.intValue == self.targetPID &&
            _reportedFullscreenCanvasPID == self.targetPID &&
            _reportedFullscreenCanvasWindowID != 0;
        if (!controllerValidatedCurrentTarget &&
            !MacWSAppInputEndpointReady(pidValue.intValue))
            [fullscreenCanvasPIDs removeObject:pidValue];
    }
    NSMutableSet<NSNumber *> *shadowWindowIDs = [NSMutableSet set];
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID > 1 &&
            (window.descriptor.flags & MacWSStreamWindowSpatialCanvas) != 0)
            [spatialCanvasPIDs addObject:@(window.descriptor.ownerPID)];
        if (window.descriptor.ownerPID > 1 &&
            (window.descriptor.flags &
                MacWSStreamWindowFullscreenCanvas) != 0)
            [fullscreenCanvasPIDs addObject:@(window.descriptor.ownerPID)];
        if (window.descriptor.windowID != 0 &&
            (window.descriptor.flags & MacWSStreamWindowHasShadow) != 0)
            [shadowWindowIDs addObject:@(window.descriptor.windowID)];
    }
    _spatialCanvasPIDs = [spatialCanvasPIDs copy];
    _fullscreenCanvasPIDs = [fullscreenCanvasPIDs copy];
    _shadowWindowIDs = [shadowWindowIDs copy];
    _directTouchUsesPrimaryDrag = self.targetPID > 1 &&
        [_spatialCanvasPIDs containsObject:@(self.targetPID)];
    if (_streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID <= 1) {
        NSMutableArray<NSString *> *catalog = [NSMutableArray array];
        for (MacWSStreamWindow *window in windows) {
            if (catalog.count >= 32) break;
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            [catalog addObject:[NSString stringWithFormat:
                @"%d/%u/%#x/endpoint=%@", descriptor.ownerPID,
                descriptor.windowID, descriptor.flags,
                MacWSAppInputEndpointReady(descriptor.ownerPID)
                    ? @"YES" : @"NO"]];
        }
        NSMutableArray<NSString *> *layers = [NSMutableArray array];
        for (NSNumber *key in [self overlayKeysBackToFront]) {
            if (layers.count >= 32) break;
            MacWSStreamFrameDescriptor descriptor =
                _overlayFrames[key].descriptor;
            [layers addObject:[NSString stringWithFormat:
                @"%d/%u/%#x", descriptor.layerOwnerPID,
                descriptor.layerWindowID, descriptor.flags]];
        }
        MacWSLog(@"fullscreen-target-candidates final=%@ catalog=[%@] "
                 "layers=[%@]",
                 [self hasFinalCompositeFrame] ? @"YES" : @"NO",
                 [catalog componentsJoinedByString:@","],
                 [layers componentsJoinedByString:@","]);
    }
    if (MacWSHostDiagnosticsEnabled())
        MacWSLog(@"display-stream window-list count=%lu",
                 (unsigned long)windows.count);
    [self updateDrawableResolution];
    [self setNeedsDisplay];
    [self.statusDelegate metalView:self receivedWindows:windows];
}

- (void)streamClient:(MacWSStreamClient *)client
        receivedFrame:(MacWSSurfaceFrame *)frame {
    uint32_t format = frame.descriptor.pixelFormat;
    // SkyLight/CGDisplayStream is requested as 32BGRA.  Reject another
    // explicit FourCC instead of silently interpreting it with the wrong
    // Metal pixel format.  A zero FourCC is accepted for older IOSurfaces
    // whose pixel-format property is absent.
    if (format != 0 && format != 0x42475241u) {
        [client releaseFrame:frame];
        [self publishStatus:@"DisplayStream 返回了非 BGRA IOSurface"];
        return;
    }
    if (!self.device) {
        [client releaseFrame:frame];
        return;
    }
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(frame.surface);
    NSUInteger requiredAlignment =
        MacWSIOSurfaceReadOnlyTextureAlignment(self.device);
    if (requiredAlignment != 0 &&
        bytesPerRow % requiredAlignment != 0) {
        MacWSLog(@"display-stream reject-metal-stride stream=%llu frame=%llu "
                 "window=%u layer=%u surface=%ux%u bpr=%zu required=%lu",
            (unsigned long long)frame.descriptor.streamID,
            (unsigned long long)frame.descriptor.sequence,
            frame.descriptor.windowID, frame.descriptor.layerWindowID,
            frame.descriptor.width, frame.descriptor.height, bytesPerRow,
            (unsigned long)requiredAlignment);
        [client releaseFrame:frame];
        [self publishStatus:[NSString stringWithFormat:
            @"DisplayStream IOSurface 行跨度未按 Metal 要求对齐（%zu / %lu）",
            bytesPerRow, (unsigned long)requiredAlignment]];
        return;
    }
    BOOL overlayFrame =
        (frame.descriptor.flags & MacWSStreamFrameOverlay) != 0;
    NSNumber *overlayKey = overlayFrame
        ? @(frame.descriptor.layerWindowID) : nil;
    MacWSSurfaceFrame *texturePredecessor = overlayFrame
        ? _overlayFrames[overlayKey] : _surfaceFrame;
    if (texturePredecessor &&
        ((frame.descriptor.streamID ==
              texturePredecessor.descriptor.streamID &&
          frame.descriptor.sequence <=
              texturePredecessor.descriptor.sequence) ||
         frame.descriptor.streamID <
              texturePredecessor.descriptor.streamID)) {
        // XPC is ordered, but frame delivery is paced to the next display
        // link while geometry batches are applied immediately on main. A
        // delayed content frame must not roll the compositor back behind an
        // already-visible geometry transaction or a newer producer stream.
        [client releaseFrame:frame];
        return;
    }
    id<MTLTexture> texture = overlayFrame
        ? _overlayTextures[overlayKey] : _surfaceTexture;
    uint32_t incomingSurfaceID = IOSurfaceGetID(frame.surface);
    uint32_t predecessorSurfaceID = texturePredecessor
        ? IOSurfaceGetID(texturePredecessor.surface) : 0;
    BOOL reusedTexture = texture && incomingSurfaceID != 0 &&
        incomingSurfaceID == predecessorSurfaceID &&
        texture.width == frame.descriptor.width &&
        texture.height == frame.descriptor.height &&
        texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
    if (!reusedTexture) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:frame.descriptor.width
                                                              height:frame.descriptor.height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        texture = [self.device newTextureWithDescriptor:descriptor
                                              iosurface:frame.surface
                                                  plane:0];
    }
    if (!texture) {
        [client releaseFrame:frame];
        [self publishStatus:@"无法从 DisplayStream IOSurface 创建 Metal 纹理"];
        return;
    }
    if (!overlayFrame) {
        [_performanceMonitor recordBaseTransportFinalComposite:
            ((frame.descriptor.flags &
              MacWSStreamFrameFinalComposite) != 0)
            streamID:frame.descriptor.streamID
            sequence:frame.descriptor.sequence
            surfaceID:incomingSurfaceID];
    }
    [_performanceMonitor recordFrameReceivedForStream:
        frame.descriptor.streamID sequence:frame.descriptor.sequence
        layerWindowID:frame.descriptor.layerWindowID
        ownerPID:frame.descriptor.layerOwnerPID
        captureTime:frame.descriptor.displayTime receiptTime:frame.receiptTime];
    if (reusedTexture) {
        _surfaceTextureReuses++;
    } else {
        _surfaceTextureImports++;
        texture.label = [NSString stringWithFormat:
            @"MacWS stream %llu frame %llu",
            (unsigned long long)frame.descriptor.streamID,
            (unsigned long long)frame.descriptor.sequence];
    }

    if (overlayFrame) {
        NSNumber *key = overlayKey;
        MacWSSurfaceFrame *previous = texturePredecessor;
        if (!previous ||
            previous.descriptor.layerLevel != frame.descriptor.layerLevel)
            _sortedOverlayKeys = nil;
        if (previous) {
            if (previous.descriptor.leaseToken ==
                [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
                [_retiredSurfaceFrames addObject:previous];
            else
                [client releaseFrame:previous];
        }
        _overlayFrames[key] = frame;
        _overlayTextures[key] = texture;
        _streamConnected = YES;
        if (_streamClient.mode == MacWSStreamModeFullscreen &&
            !_catalogRevalidationRequestedForPresentation) {
            _catalogRevalidationRequestedForPresentation = YES;
            MacWSLog(@"display-stream catalog-revalidate "
                     "reason=first-overlay-presentation window=%u pid=%d",
                     frame.descriptor.layerWindowID,
                     frame.descriptor.layerOwnerPID);
            [_streamClient requestWindowList];
        }
        [self setNeedsDisplay];
        return;
    }

    MacWSSurfaceFrame *previous = texturePredecessor;
    BOOL becameFinalComposite =
        (frame.descriptor.flags & MacWSStreamFrameFinalComposite) != 0 &&
        (!previous || (previous.descriptor.flags &
                       MacWSStreamFrameFinalComposite) == 0);
    BOOL geometryChanged = !previous ||
        !MacWSStreamFrameGeometryEqual(previous.descriptor,
                                       frame.descriptor);
    if (previous) {
        if (previous.descriptor.leaseToken == _submittedSurfaceLeaseToken)
            [_retiredSurfaceFrames addObject:previous];
        else
            [client releaseFrame:previous];
    }
    _surfaceFrame = frame;
    _surfaceTexture = texture;
    if (frame.descriptor.contentWidth != 0 &&
        frame.descriptor.contentHeight != 0) {
        _lastKeyboardFrameWidth = frame.descriptor.contentWidth;
        _lastKeyboardFrameHeight = frame.descriptor.contentHeight;
    }
    _streamConnected = YES;
    if (_windowConfigurationAwaitingAcknowledgement &&
        self.targetWindowID != 0 &&
        frame.descriptor.windowID == self.targetWindowID &&
        frame.descriptor.backingScale > 0.0f) {
        CGSize applied = {
            frame.descriptor.contentWidth / frame.descriptor.backingScale,
            frame.descriptor.contentHeight / frame.descriptor.backingScale,
        };
        if (fabs(applied.width - _pendingRequestedWindowSize.width) < 1.0 &&
            fabs(applied.height - _pendingRequestedWindowSize.height) < 1.0) {
            // The DisplayStream IOSurface is the visible downstream
            // postcondition of AppKit accepting ConfigureWindow. Stop all
            // remaining retries as soon as that exact size lands.
            _windowConfigurationAwaitingAcknowledgement = NO;
            _windowConfigurationSettlementSerial++;
        }
    }
    if (!previous) {
        // suspendStream deliberately releases the old stream's base frame.
        // applyStatus consequently disables input until the replacement has
        // an IOSurface.  A DisplayStream connection notification can precede
        // this frame, so publish a distinct first-frame state transition and
        // let the controller re-evaluate the complete input invariant.
        [self publishStatus:@"DisplayStream IOSurface 首帧已就绪"];
    }
    // DisplayStream is now authoritative. Stop polling the legacy mmap
    // acknowledgement files until this Scene changes streams or disconnects.
    _framePollDisplayLink.paused = YES;
    if (geometryChanged) {
        [self updateDrawableResolution];
        [self updatePresentationGeometry];
        [self scheduleWindowConfiguration];
    }
    if (becameFinalComposite) {
        // The initial catalog can arrive before this first surface, when the
        // final-composite fallback is intentionally not yet eligible. Ask for
        // one fresh catalog after the surface becomes authoritative so target
        // selection and pointer correlation converge after a Host relaunch
        // without waiting for an unrelated AppKit window mutation.
        if (!_catalogRevalidationRequestedForPresentation) {
            _catalogRevalidationRequestedForPresentation = YES;
            MacWSLog(@"display-stream catalog-revalidate "
                     "reason=first-final-composite");
            [_streamClient requestWindowList];
        }
    }
    [self setNeedsDisplay];
}

- (void)streamClient:(MacWSStreamClient *)client
 receivedLayerGeometryUpdates:(NSData *)updates
                   receiptTime:(uint64_t)receiptTime {
    (void)client;
    if (!updates.length ||
        updates.length % sizeof(MacWSStreamLayerGeometry) != 0 ||
        updates.length / sizeof(MacWSStreamLayerGeometry) >
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    const MacWSStreamLayerGeometry *records = updates.bytes;
    NSUInteger count = updates.length / sizeof(*records);
    [_performanceMonitor recordGeometryBatchReceived];
    BOOL changed = NO;
    BOOL presentationOrderChanged = NO;
    for (NSUInteger index = 0; index < count; index++) {
        const MacWSStreamLayerGeometry *geometry = &records[index];
        if (!MacWSStreamLayerGeometryIsValid(geometry,
                                              sizeof(*geometry))) continue;
        NSNumber *key = @(geometry->layerWindowID);
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        if (!frame) continue;
        MacWSStreamFrameDescriptor current = frame.descriptor;
        if (!MacWSStreamLayerGeometrySupersedesFrame(
                geometry, &current)) continue;
        MacWSStreamFrameDescriptor descriptor = current;
        BOOL levelChanged = descriptor.layerLevel != geometry->layerLevel;
        descriptor.sequence = geometry->sequence;
        descriptor.displayTime = geometry->displayTime;
        descriptor.layerOwnerPID = geometry->layerOwnerPID;
        descriptor.layerLevel = geometry->layerLevel;
        descriptor.destinationX = geometry->destinationX;
        descriptor.destinationY = geometry->destinationY;
        descriptor.destinationWidth = geometry->destinationWidth;
        descriptor.destinationHeight = geometry->destinationHeight;
        descriptor.flags = (descriptor.flags &
            ~(MacWSStreamFrameGlobalSystemSurface |
              MacWSStreamFrameInputPassthrough)) |
            (geometry->flags &
                (MacWSStreamFrameGlobalSystemSurface |
                 MacWSStreamFrameInputPassthrough));
        _overlayFrames[key] = [[MacWSSurfaceFrame alloc]
            initWithDescriptor:descriptor surface:frame.surface
            receiptTime:receiptTime];
        if (levelChanged) {
            _sortedOverlayKeys = nil;
            presentationOrderChanged = YES;
        }
        [_performanceMonitor recordGeometryReceivedForStream:
            descriptor.streamID sequence:descriptor.sequence
            layerWindowID:descriptor.layerWindowID
            ownerPID:descriptor.layerOwnerPID
            captureTime:descriptor.displayTime receiptTime:receiptTime];
        changed = YES;
    }
    if (changed) [self setNeedsDisplay];
    if (presentationOrderChanged && _latestWindows.count) {
        // A native activation reorders retained layers without necessarily
        // changing the OptionAll identity catalog. Re-evaluate targetPID on
        // that exact ordered-geometry transaction; otherwise the visible app
        // changes while subsequent hardware keys remain bound to the previous
        // PID until an unrelated catalog mutation occurs. This is local and
        // event-driven, so dragging a window (geometry only, same level) does
        // not trigger catalog work or a target-selection loop.
        MacWSLog(@"display-stream input-target-revalidate "
                 "reason=layer-order-changed layers=%lu windows=%lu",
                 (unsigned long)_overlayFrames.count,
                 (unsigned long)_latestWindows.count);
        [self.statusDelegate metalView:self receivedWindows:_latestWindows];
    }
}

- (void)streamClient:(MacWSStreamClient *)client
 removedLayerWindowID:(uint32_t)layerWindowID {
    (void)client;
    NSNumber *key = @(layerWindowID);
    MacWSSurfaceFrame *frame = _overlayFrames[key];
    if (!frame) return;
    MacWSStreamFrameDescriptor retiredDescriptor = frame.descriptor;
    int32_t retiredOwnerPID = frame.descriptor.layerOwnerPID;
    if (frame.descriptor.leaseToken ==
        [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
        [_retiredSurfaceFrames addObject:frame];
    else
        [_streamClient releaseFrame:frame];
    [_overlayFrames removeObjectForKey:key];
    [_overlayTextures removeObjectForKey:key];
    [_submittedOverlayLeaseTokens removeObjectForKey:key];
    _sortedOverlayKeys = nil;
    // A layer removal changes the next drawable without delivering a new
    // IOSurface. Record that real geometry transaction before requesting the
    // redraw so input-to-visible measurement can pair a Mission Control card
    // click with the presentation that actually removes its Dock layers.
    uint64_t retirementTime = mach_absolute_time();
    [_performanceMonitor recordGeometryReceivedForStream:
        retiredDescriptor.streamID sequence:retiredDescriptor.sequence
        layerWindowID:retiredDescriptor.layerWindowID
        ownerPID:retiredDescriptor.layerOwnerPID
        captureTime:retirementTime receiptTime:retirementTime];
    MacWSLog(@"display-stream overlay-retire-ui layer=%u immediate=YES",
             layerWindowID);
    [self setNeedsDisplay];
    // Layer retirement is the authoritative edge that can invalidate the
    // exact NSWindow cached for fullscreen keyboard routing.  Re-read the
    // low-rate window catalog once at this lifecycle boundary; the controller
    // will follow the target only when the retired identity is truly absent.
    // This does not add work to frame or pointer-move paths.
    if (retiredOwnerPID > 1 && retiredOwnerPID == self.targetPID &&
        !_targetRetirementCatalogRequeryScheduled) {
        _targetRetirementCatalogRequeryScheduled = YES;
        MacWSLog(@"display-stream catalog-requery-scheduled reason=target-layer-retired pid=%d layer=%u",
                 retiredOwnerPID, layerWindowID);
        // WindowServer commonly retires every layer in one transaction.  One
        // catalog snapshot after that batch is authoritative; requesting once
        // per sibling layer duplicated XPC/CGWindow work at application exit.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     75 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            self->_targetRetirementCatalogRequeryScheduled = NO;
            if (!self->_streamConnected) return;
            MacWSLog(@"display-stream catalog-requery reason=target-layer-retirement-batch");
            [self->_streamClient requestWindowList];
        });
    }
}
@end
