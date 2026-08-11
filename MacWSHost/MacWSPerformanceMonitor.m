#import "MacWSPerformanceMonitor.h"

#import <os/lock.h>

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>

static const NSUInteger MacWSPerfRingCapacity = 512;
static const double MacWSPerfActiveGapMilliseconds = 150.0;
static const double MacWSPerfInputActiveWindowMilliseconds = 250.0;
static const double MacWSPerfTargetFrameMilliseconds = 1000.0 / 60.0;
static const int MacWSQuartzCorePerformanceHUDFlag = 0x10000000;

typedef struct {
    double values[512];
    NSUInteger count;
    NSUInteger cursor;
} MacWSPerfRing;

static void MacWSPerfRingReset(MacWSPerfRing *ring) {
    memset(ring, 0, sizeof(*ring));
}

static void MacWSPerfRingAppend(MacWSPerfRing *ring, double value) {
    if (!isfinite(value) || value < 0.0) return;
    ring->values[ring->cursor] = value;
    ring->cursor = (ring->cursor + 1) % MacWSPerfRingCapacity;
    ring->count = MIN(ring->count + 1, MacWSPerfRingCapacity);
}

static NSArray<NSNumber *> *MacWSPerfSortedValues(const MacWSPerfRing *ring) {
    NSMutableArray<NSNumber *> *values =
        [NSMutableArray arrayWithCapacity:ring->count];
    NSUInteger first = ring->count == MacWSPerfRingCapacity
        ? ring->cursor : 0;
    for (NSUInteger index = 0; index < ring->count; index++) {
        NSUInteger slot = (first + index) % MacWSPerfRingCapacity;
        [values addObject:@(ring->values[slot])];
    }
    [values sortUsingComparator:^NSComparisonResult(NSNumber *left,
                                                      NSNumber *right) {
        return [left compare:right];
    }];
    return values;
}

static NSNumber *MacWSPerfPercentile(NSArray<NSNumber *> *values,
                                     double fraction) {
    if (!values.count) return (NSNumber *)NSNull.null;
    NSUInteger index = (NSUInteger)ceil(values.count * fraction);
    index = MIN(MAX(index, 1u), values.count) - 1;
    return values[index];
}

static NSDictionary<NSString *, id> *MacWSPerfRingSummary(
        const MacWSPerfRing *ring) {
    NSArray<NSNumber *> *values = MacWSPerfSortedValues(ring);
    if (!values.count) {
        return @{
            @"samples": @0,
            @"mean_ms": NSNull.null,
            @"p50_ms": NSNull.null,
            @"p95_ms": NSNull.null,
            @"p99_ms": NSNull.null,
            @"maximum_ms": NSNull.null,
        };
    }
    double total = 0.0;
    for (NSNumber *value in values) total += value.doubleValue;
    return @{
        @"samples": @(values.count),
        @"mean_ms": @(total / values.count),
        @"p50_ms": MacWSPerfPercentile(values, 0.50),
        @"p95_ms": MacWSPerfPercentile(values, 0.95),
        @"p99_ms": MacWSPerfPercentile(values, 0.99),
        @"maximum_ms": values.lastObject,
    };
}

static double MacWSPerfMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return -1.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return -1.0;
    long double nanoseconds = (long double)(end - start) *
        timebase.numer / timebase.denom;
    return (double)(nanoseconds / 1000000.0L);
}

static NSString *MacWSPerfThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

@interface MacWSPerformanceMonitor ()
@property(nonatomic, readwrite) UIView *HUDView;
@end

@implementation MacWSPerformanceMonitor {
    NSString *_sceneLabel;
    os_unfair_lock _lock;
    uint64_t _resetMachTime;
    uint64_t _measurementGeneration;
    NSDate *_resetDate;
    NSString *_resetReason;
    atomic_bool _instrumentationActive;
    BOOL _explicitRecording;

    uint64_t _framesReceived;
    uint64_t _framesSubmitted;
    uint64_t _framesPresented;
    uint64_t _commandErrors;
    uint64_t _inputsAttempted;
    uint64_t _inputsSent;
    uint64_t _inputTransportErrors;
    uint64_t _estimatedDroppedVsyncs;
    uint64_t _hitchCount;
    uint64_t _stallCount;
    uint64_t _inactiveGapCount;
    uint64_t _staleCaptureSamples;

    uint64_t _lastReceivedStream;
    uint64_t _lastReceivedCaptureTime;
    uint64_t _lastSubmittedStream;
    uint64_t _lastSubmittedSequence;
    double _lastPresentedSeconds;
    double _lastInteractivePresentedSeconds;
    uint64_t _lastInputMachTime;
    uint64_t _pendingInputMachTime;
    uint16_t _pendingInputKind;

    MacWSPerfRing _sourceIntervals;
    MacWSPerfRing _presentIntervals;
    MacWSPerfRing _observedPresentIntervals;
    MacWSPerfRing _captureToReceipt;
    MacWSPerfRing _receiptToSubmit;
    MacWSPerfRing _submitToComplete;
    MacWSPerfRing _gpuExecution;
    MacWSPerfRing _captureToPresent;
    MacWSPerfRing _inputToPresent;

    UIVisualEffectView *_HUDMaterial;
    UILabel *_HUDLabel;
    NSLayoutConstraint *_HUDWidthConstraint;
    NSLayoutConstraint *_HUDHeightConstraint;
    dispatch_source_t _HUDTimer;
}

- (instancetype)initWithSceneLabel:(NSString *)sceneLabel {
    self = [super init];
    if (!self) return nil;
    _sceneLabel = [sceneLabel copy] ?: @"unknown";
    _lock = OS_UNFAIR_LOCK_INIT;
    atomic_init(&_instrumentationActive, false);
    [self resetWithReason:@"monitor-created"];

    _HUDMaterial = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _HUDMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    _HUDMaterial.userInteractionEnabled = NO;
    _HUDMaterial.layer.cornerRadius = 13.0;
    _HUDMaterial.layer.cornerCurve = kCACornerCurveContinuous;
    _HUDMaterial.layer.borderWidth = 0.5;
    _HUDMaterial.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.22].CGColor;
    _HUDMaterial.clipsToBounds = YES;
    _HUDMaterial.accessibilityIdentifier = @"macws-performance-hud";

    _HUDLabel = [UILabel new];
    _HUDLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _HUDLabel.numberOfLines = 0;
    _HUDLabel.textColor = UIColor.whiteColor;
    _HUDLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                weight:UIFontWeightSemibold];
    [_HUDMaterial.contentView addSubview:_HUDLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_HUDLabel.leadingAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.leadingAnchor constant:10],
        [_HUDLabel.trailingAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.trailingAnchor constant:-10],
        [_HUDLabel.topAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.topAnchor constant:8],
        [_HUDLabel.bottomAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.bottomAnchor constant:-8],
    ]];
    self.HUDView = _HUDMaterial;
    self.HUDMode = MacWSPerformanceHUDModeOff;
    return self;
}

- (void)dealloc {
    if (_HUDTimer) dispatch_source_cancel(_HUDTimer);
}

- (void)attachHUDToView:(UIView *)view {
    if (!view || _HUDMaterial.superview == view) return;
    [_HUDMaterial removeFromSuperview];
    [view addSubview:_HUDMaterial];
    _HUDWidthConstraint = [_HUDMaterial.widthAnchor constraintEqualToConstant:228];
    _HUDHeightConstraint = [_HUDMaterial.heightAnchor constraintEqualToConstant:64];
    [NSLayoutConstraint activateConstraints:@[
        [_HUDMaterial.trailingAnchor constraintEqualToAnchor:
            view.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [_HUDMaterial.bottomAnchor constraintEqualToAnchor:
            view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        _HUDWidthConstraint,
        _HUDHeightConstraint,
    ]];
    [self applyHUDMode];
}

- (void)setHUDMode:(MacWSPerformanceHUDMode)HUDMode {
    if (HUDMode < MacWSPerformanceHUDModeOff ||
        HUDMode > MacWSPerformanceHUDModeFull)
        HUDMode = MacWSPerformanceHUDModeOff;
    _HUDMode = HUDMode;
    os_unfair_lock_lock(&_lock);
    atomic_store(&_instrumentationActive,
        _explicitRecording || HUDMode != MacWSPerformanceHUDModeOff);
    os_unfair_lock_unlock(&_lock);
    [self applyHUDMode];
}

- (void)applyHUDMode {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyHUDMode]; });
        return;
    }
    BOOL enabled = self.HUDMode != MacWSPerformanceHUDModeOff;
    _HUDMaterial.hidden = !enabled;
    _HUDWidthConstraint.constant = self.HUDMode == MacWSPerformanceHUDModeFull
        ? 292.0 : 228.0;
    _HUDHeightConstraint.constant = self.HUDMode == MacWSPerformanceHUDModeFull
        ? 146.0 : 64.0;
    if (enabled) {
        [self updateHUD];
        [self startHUDTimer];
    } else if (_HUDTimer) {
        dispatch_source_cancel(_HUDTimer);
        _HUDTimer = nil;
    }
}

- (void)startHUDTimer {
    if (_HUDTimer) return;
    _HUDTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
    dispatch_source_set_timer(_HUDTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_HUDTimer, ^{ [weakSelf updateHUD]; });
    dispatch_resume(_HUDTimer);
}

- (void)resetWithReason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    _explicitRecording = ![reason isEqualToString:@"monitor-created"];
    atomic_store(&_instrumentationActive,
        _explicitRecording || _HUDMode != MacWSPerformanceHUDModeOff);
    _resetMachTime = mach_absolute_time();
    _measurementGeneration++;
    _resetDate = NSDate.date;
    _resetReason = [reason copy] ?: @"manual";
    _framesReceived = 0;
    _framesSubmitted = 0;
    _framesPresented = 0;
    _commandErrors = 0;
    _inputsAttempted = 0;
    _inputsSent = 0;
    _inputTransportErrors = 0;
    _estimatedDroppedVsyncs = 0;
    _hitchCount = 0;
    _stallCount = 0;
    _inactiveGapCount = 0;
    _staleCaptureSamples = 0;
    _lastReceivedStream = 0;
    _lastReceivedCaptureTime = 0;
    _lastSubmittedStream = 0;
    _lastSubmittedSequence = 0;
    _lastPresentedSeconds = 0.0;
    _lastInteractivePresentedSeconds = 0.0;
    _lastInputMachTime = 0;
    _pendingInputMachTime = 0;
    _pendingInputKind = 0;
    MacWSPerfRingReset(&_sourceIntervals);
    MacWSPerfRingReset(&_presentIntervals);
    MacWSPerfRingReset(&_observedPresentIntervals);
    MacWSPerfRingReset(&_captureToReceipt);
    MacWSPerfRingReset(&_receiptToSubmit);
    MacWSPerfRingReset(&_submitToComplete);
    MacWSPerfRingReset(&_gpuExecution);
    MacWSPerfRingReset(&_captureToPresent);
    MacWSPerfRingReset(&_inputToPresent);
    os_unfair_lock_unlock(&_lock);
    if (self.HUDMode != MacWSPerformanceHUDModeOff)
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateHUD]; });
}

- (void)recordInputKind:(uint16_t)kind
             sampleTime:(CFTimeInterval)sampleTime
       transportSuccess:(BOOL)success {
    (void)sampleTime;
    if (!atomic_load(&_instrumentationActive)) return;
    uint64_t now = mach_absolute_time();
    os_unfair_lock_lock(&_lock);
    _inputsAttempted++;
    if (success) {
        _inputsSent++;
        _lastInputMachTime = now;
        // Keep the oldest not-yet-assigned event. It represents the first
        // user action waiting for a newly produced visible frame; high-rate
        // move records are naturally coalesced behind that boundary.
        if (!_pendingInputMachTime) {
            _pendingInputMachTime = now;
            _pendingInputKind = kind;
        }
    } else {
        _inputTransportErrors++;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)recordFrameReceivedForStream:(uint64_t)streamID
                            sequence:(uint64_t)sequence
                         captureTime:(uint64_t)captureTime
                         receiptTime:(uint64_t)receiptTime {
    (void)sequence;
    if (!atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    _framesReceived++;
    if (_lastReceivedStream == streamID && _lastReceivedCaptureTime &&
        captureTime > _lastReceivedCaptureTime) {
        double interval = MacWSPerfMachMilliseconds(_lastReceivedCaptureTime,
                                                    captureTime);
        if (interval <= MacWSPerfActiveGapMilliseconds)
            MacWSPerfRingAppend(&_sourceIntervals, interval);
    }
    _lastReceivedStream = streamID;
    _lastReceivedCaptureTime = captureTime;
    double captureReceipt = MacWSPerfMachMilliseconds(captureTime,
                                                      receiptTime);
    // displayd may explicitly republish a retained static IOSurface after a
    // layer temporarily leaves Mission Control. Its capture timestamp is
    // intentionally old and is not a transport-latency sample.
    if (captureReceipt >= 0.0 && captureReceipt <= 1000.0)
        MacWSPerfRingAppend(&_captureToReceipt, captureReceipt);
    else
        _staleCaptureSamples++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordSubmissionForStream:(uint64_t)streamID
                         sequence:(uint64_t)sequence
                      captureTime:(uint64_t)captureTime
                      receiptTime:(uint64_t)receiptTime
                       submitTime:(uint64_t)submitTime
                    commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         drawable:(id<MTLDrawable>)drawable {
    if (!commandBuffer || !drawable ||
        !atomic_load(&_instrumentationActive)) return;
    __block uint64_t inputMachTime = 0;
    __block uint64_t measurementGeneration = 0;
    __block BOOL newlyReceivedFrame = NO;
    os_unfair_lock_lock(&_lock);
    measurementGeneration = _measurementGeneration;
    newlyReceivedFrame = receiptTime >= _resetMachTime;
    _framesSubmitted++;
    _lastSubmittedStream = streamID;
    _lastSubmittedSequence = sequence;
    if (newlyReceivedFrame) {
        MacWSPerfRingAppend(&_receiptToSubmit,
            MacWSPerfMachMilliseconds(receiptTime, submitTime));
    }
    // Never pair input with a redraw of a frame captured before that input.
    if (_pendingInputMachTime && receiptTime >= _pendingInputMachTime) {
        inputMachTime = _pendingInputMachTime;
        _pendingInputMachTime = 0;
        _pendingInputKind = 0;
    }
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        uint64_t completeTime = mach_absolute_time();
        os_unfair_lock_lock(&strongSelf->_lock);
        if (measurementGeneration != strongSelf->_measurementGeneration ||
            !newlyReceivedFrame) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        MacWSPerfRingAppend(&strongSelf->_submitToComplete,
            MacWSPerfMachMilliseconds(submitTime, completeTime));
        if (completed.status == MTLCommandBufferStatusError)
            strongSelf->_commandErrors++;
        if (completed.GPUEndTime >= completed.GPUStartTime &&
            completed.GPUStartTime > 0.0) {
            MacWSPerfRingAppend(&strongSelf->_gpuExecution,
                (completed.GPUEndTime - completed.GPUStartTime) * 1000.0);
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
    }];

    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        uint64_t callbackTime = mach_absolute_time();
        double presentedSeconds = presentedDrawable.presentedTime;
        if (presentedSeconds <= 0.0) presentedSeconds = CACurrentMediaTime();
        os_unfair_lock_lock(&strongSelf->_lock);
        if (measurementGeneration != strongSelf->_measurementGeneration ||
            !newlyReceivedFrame) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        strongSelf->_framesPresented++;
        if (strongSelf->_lastPresentedSeconds > 0.0 &&
            presentedSeconds > strongSelf->_lastPresentedSeconds) {
            double interval = (presentedSeconds -
                               strongSelf->_lastPresentedSeconds) * 1000.0;
            if (interval <= MacWSPerfActiveGapMilliseconds)
                MacWSPerfRingAppend(&strongSelf->_observedPresentIntervals,
                                    interval);
        }
        strongSelf->_lastPresentedSeconds = presentedSeconds;
        double sinceInput = MacWSPerfMachMilliseconds(
            strongSelf->_lastInputMachTime, callbackTime);
        BOOL inputActive = sinceInput >= 0.0 &&
            sinceInput <= MacWSPerfInputActiveWindowMilliseconds;
        if (inputActive &&
            strongSelf->_lastInteractivePresentedSeconds > 0.0 &&
            presentedSeconds > strongSelf->_lastInteractivePresentedSeconds) {
            double interval = (presentedSeconds -
                strongSelf->_lastInteractivePresentedSeconds) * 1000.0;
            if (interval <= MacWSPerfActiveGapMilliseconds) {
                MacWSPerfRingAppend(&strongSelf->_presentIntervals,
                                    interval);
                if (interval > MacWSPerfTargetFrameMilliseconds * 1.5)
                    strongSelf->_hitchCount++;
                if (interval > 50.0) strongSelf->_stallCount++;
                NSUInteger vsyncs = (NSUInteger)llround(
                    interval / MacWSPerfTargetFrameMilliseconds);
                if (vsyncs > 1)
                    strongSelf->_estimatedDroppedVsyncs += vsyncs - 1;
            } else {
                strongSelf->_inactiveGapCount++;
            }
        }
        if (inputActive)
            strongSelf->_lastInteractivePresentedSeconds = presentedSeconds;
        double capturePresent = MacWSPerfMachMilliseconds(captureTime,
                                                          callbackTime);
        if (capturePresent >= 0.0 && capturePresent <= 1000.0)
            MacWSPerfRingAppend(&strongSelf->_captureToPresent,
                                capturePresent);
        else
            strongSelf->_staleCaptureSamples++;
        if (inputMachTime) {
            MacWSPerfRingAppend(&strongSelf->_inputToPresent,
                MacWSPerfMachMilliseconds(inputMachTime, callbackTime));
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
    }];
}

- (NSDictionary<NSString *, id> *)snapshotWithReason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    NSDictionary *present = MacWSPerfRingSummary(&_presentIntervals);
    NSDictionary *observedPresent =
        MacWSPerfRingSummary(&_observedPresentIntervals);
    NSDictionary *source = MacWSPerfRingSummary(&_sourceIntervals);
    NSDictionary *captureReceipt = MacWSPerfRingSummary(&_captureToReceipt);
    NSDictionary *receiptSubmit = MacWSPerfRingSummary(&_receiptToSubmit);
    NSDictionary *submitComplete = MacWSPerfRingSummary(&_submitToComplete);
    NSDictionary *gpu = MacWSPerfRingSummary(&_gpuExecution);
    NSDictionary *capturePresent = MacWSPerfRingSummary(&_captureToPresent);
    NSDictionary *inputPresent = MacWSPerfRingSummary(&_inputToPresent);
    uint64_t framesReceived = _framesReceived;
    uint64_t framesSubmitted = _framesSubmitted;
    uint64_t framesPresented = _framesPresented;
    uint64_t commandErrors = _commandErrors;
    uint64_t inputsAttempted = _inputsAttempted;
    uint64_t inputsSent = _inputsSent;
    uint64_t inputErrors = _inputTransportErrors;
    uint64_t dropped = _estimatedDroppedVsyncs;
    uint64_t hitches = _hitchCount;
    uint64_t stalls = _stallCount;
    uint64_t inactiveGaps = _inactiveGapCount;
    uint64_t staleCaptureSamples = _staleCaptureSamples;
    uint64_t lastStream = _lastSubmittedStream;
    uint64_t lastSequence = _lastSubmittedSequence;
    uint64_t resetTime = _resetMachTime;
    NSDate *resetDate = _resetDate;
    NSString *resetReason = _resetReason;
    BOOL instrumentationActive = atomic_load(&_instrumentationActive);
    os_unfair_lock_unlock(&_lock);

    NSNumber *meanFrame = present[@"mean_ms"];
    NSNumber *p99Frame = present[@"p99_ms"];
    double averageFPS = [meanFrame isKindOfClass:NSNumber.class] &&
                        meanFrame.doubleValue > 0.0
        ? 1000.0 / meanFrame.doubleValue : 0.0;
    double onePercentLowFPS = [p99Frame isKindOfClass:NSNumber.class] &&
                              p99Frame.doubleValue > 0.0
        ? 1000.0 / p99Frame.doubleValue : 0.0;
    NSUInteger intervalSamples = [present[@"samples"] unsignedIntegerValue];
    double hitchRate = intervalSamples
        ? (double)hitches / intervalSamples * 100.0 : 0.0;
    NSTimeInterval elapsed = MAX(0.0,
        MacWSPerfMachMilliseconds(resetTime, mach_absolute_time()) / 1000.0);

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });

    return @{
        @"schema": @"macws-ui-performance-v1",
        @"reason": reason.length ? reason : @"snapshot",
        @"scene": _sceneLabel,
        @"captured_at": [formatter stringFromDate:NSDate.date],
        @"measurement_started_at": [formatter stringFromDate:resetDate],
        @"measurement_reason": resetReason,
        @"elapsed_s": @(elapsed),
        @"target": @{
            @"active_fps": @60.0,
            @"one_percent_low_fps": @45.0,
            @"input_to_visible_p95_ms": @50.0,
            @"active_gap_cutoff_ms": @(MacWSPerfActiveGapMilliseconds),
            @"input_active_window_ms":
                @(MacWSPerfInputActiveWindowMilliseconds),
        },
        @"visible_presentation": @{
            @"active_average_fps": @(averageFPS),
            @"one_percent_low_fps": @(onePercentLowFPS),
            @"frame_interval": present,
            @"observed_frame_interval": observedPresent,
            @"estimated_dropped_vsyncs": @(dropped),
            @"hitches_over_1_5_frames": @(hitches),
            @"hitch_rate_percent": @(hitchRate),
            @"stalls_over_50ms": @(stalls),
            @"inactive_gaps_excluded": @(inactiveGaps),
            @"stale_capture_samples_excluded": @(staleCaptureSamples),
        },
        @"pipeline": @{
            @"source_frame_interval": source,
            @"capture_to_host_receipt": captureReceipt,
            @"host_receipt_to_submit": receiptSubmit,
            @"submit_to_command_complete": submitComplete,
            @"gpu_execution": gpu,
            @"capture_to_visible_callback": capturePresent,
            @"input_dispatch_to_visible_callback": inputPresent,
        },
        @"counters": @{
            @"frames_received": @(framesReceived),
            @"frames_submitted": @(framesSubmitted),
            @"frames_presented": @(framesPresented),
            @"command_errors": @(commandErrors),
            @"inputs_attempted": @(inputsAttempted),
            @"inputs_sent": @(inputsSent),
            @"input_transport_errors": @(inputErrors),
            @"last_stream": @(lastStream),
            @"last_sequence": @(lastSequence),
        },
        @"environment": @{
            @"thermal_state": MacWSPerfThermalStateName(
                NSProcessInfo.processInfo.thermalState),
            @"system_ca_hud_level": @([MacWSPerformanceMonitor
                systemPerformanceHUDLevel]),
            @"instrumentation_active": @(instrumentationActive),
        },
        @"measurement_notes": @[
            @"Interactive FPS uses CAMetalDrawable presentation callbacks within 250 ms of Host input; gaps over 150 ms are excluded.",
            @"Observed frame interval remains available for autonomous animation/WebGL workloads that do not emit input.",
            @"Input latency pairs the oldest unrepresented Host input with the first subsequently captured DisplayStream frame.",
            @"Synthetic transport probes do not measure physical finger-to-UIKit recognizer latency.",
        ],
    };
}

- (void)updateHUD {
    if (self.HUDMode == MacWSPerformanceHUDModeOff) return;
    NSDictionary *snapshot = [self snapshotWithReason:@"hud"];
    NSDictionary *visible = snapshot[@"visible_presentation"];
    NSDictionary *pipeline = snapshot[@"pipeline"];
    NSDictionary *counters = snapshot[@"counters"];
    double fps = [visible[@"active_average_fps"] doubleValue];
    double low = [visible[@"one_percent_low_fps"] doubleValue];
    NSDictionary *frame = visible[@"frame_interval"];
    NSString *headline = [NSString stringWithFormat:
        @"MacWS PERF   %5.1f FPS\n1%% low %5.1f  p99 %@ ms",
        fps, low, [self displayNumber:frame[@"p99_ms"]]];
    if (self.HUDMode == MacWSPerformanceHUDModeCompact) {
        _HUDLabel.text = headline;
        return;
    }
    NSDictionary *capturePresent = pipeline[@"capture_to_visible_callback"];
    NSDictionary *inputPresent = pipeline[@"input_dispatch_to_visible_callback"];
    NSDictionary *gpu = pipeline[@"gpu_execution"];
    _HUDLabel.text = [NSString stringWithFormat:
        @"%@\ncap→visible p50/p95 %@ / %@ ms\ninput→visible p50/p95 %@ / %@ ms\nGPU p50/p95 %@ / %@ ms\nhitch %.1f%%  drop %@  error %@\nthermal %@   samples %@",
        headline,
        [self displayNumber:capturePresent[@"p50_ms"]],
        [self displayNumber:capturePresent[@"p95_ms"]],
        [self displayNumber:inputPresent[@"p50_ms"]],
        [self displayNumber:inputPresent[@"p95_ms"]],
        [self displayNumber:gpu[@"p50_ms"]],
        [self displayNumber:gpu[@"p95_ms"]],
        [visible[@"hitch_rate_percent"] doubleValue],
        visible[@"estimated_dropped_vsyncs"], counters[@"command_errors"],
        snapshot[@"environment"][@"thermal_state"], frame[@"samples"]];
}

- (NSString *)displayNumber:(id)value {
    if (![value isKindOfClass:NSNumber.class]) return @"—";
    return [NSString stringWithFormat:@"%.1f", [value doubleValue]];
}

- (NSString *)exportSnapshotWithReason:(NSString *)reason
                                  error:(NSError **)error {
    NSDictionary *snapshot = [self snapshotWithReason:reason];
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
        error:error];
    if (!data) return nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = @"/var/mobile/Library/Logs/MacWSPerformance";
    if (![manager createDirectoryAtPath:directory
             withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSString *latest = [directory stringByAppendingPathComponent:@"latest.json"];
    if (![data writeToFile:latest options:NSDataWritingAtomic error:error])
        return nil;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *archive = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"profile-%@.json",
         [formatter stringFromDate:NSDate.date]]];
    if (![data writeToFile:archive options:NSDataWritingAtomic error:error])
        return nil;

    NSArray<NSString *> *files = [[manager contentsOfDirectoryAtPath:directory
        error:nil] filteredArrayUsingPredicate:[NSPredicate
            predicateWithBlock:^BOOL(NSString *name,
                                     NSDictionary *bindings) {
                (void)bindings;
                return [name hasPrefix:@"profile-"] &&
                       [name hasSuffix:@".json"];
            }]];
    files = [files sortedArrayUsingSelector:@selector(compare:)];
    if (files.count > 20) {
        for (NSString *name in [files subarrayWithRange:
             NSMakeRange(0, files.count - 20)]) {
            [manager removeItemAtPath:[directory
                stringByAppendingPathComponent:name] error:nil];
        }
    }
    os_unfair_lock_lock(&_lock);
    _explicitRecording = NO;
    atomic_store(&_instrumentationActive,
        _HUDMode != MacWSPerformanceHUDModeOff);
    os_unfair_lock_unlock(&_lock);
    return archive;
}

+ (NSInteger)systemPerformanceHUDLevel {
    typedef int (*GetFlagsFn)(mach_port_t);
    typedef int (*GetValueFn)(mach_port_t, int);
    GetFlagsFn getFlags = (GetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugFlags");
    GetValueFn getValue = (GetValueFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugValue");
    if (!getFlags || !getValue) return -1;
    if (!(getFlags(MACH_PORT_NULL) & MacWSQuartzCorePerformanceHUDFlag))
        return 0;
    return getValue(MACH_PORT_NULL, 1) + 1;
}

+ (BOOL)setSystemPerformanceHUDLevel:(NSInteger)level
                                error:(NSError **)error {
    typedef int (*GetFlagsFn)(mach_port_t);
    typedef void (*SetFlagsFn)(mach_port_t, int, int);
    typedef void (*SetValueFn)(mach_port_t, int, int);
    GetFlagsFn getFlags = (GetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugFlags");
    SetFlagsFn setFlags = (SetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerSetDebugFlags");
    SetValueFn setValue = (SetValueFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerSetDebugValue");
    if (!getFlags || !setFlags || !setValue) {
        if (error) *error = [NSError errorWithDomain:@"MacWSPerformance"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"QuartzCore render-server debug API is unavailable"}];
        return NO;
    }
    int flags = getFlags(MACH_PORT_NULL);
    if (level > 0) {
        flags |= MacWSQuartzCorePerformanceHUDFlag;
        setValue(MACH_PORT_NULL, 1, (int)level - 1);
    } else {
        flags &= ~MacWSQuartzCorePerformanceHUDFlag;
    }
    setFlags(MACH_PORT_NULL, MacWSQuartzCorePerformanceHUDFlag, flags);
    NSInteger actual = [self systemPerformanceHUDLevel];
    if (actual != level) {
        if (error) *error = [NSError errorWithDomain:@"MacWSPerformance"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"QuartzCore HUD requested level %ld but read back %ld",
                    (long)level, (long)actual]}];
        return NO;
    }
    return YES;
}

@end
