#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <simd/simd.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "macws_host_protocol.h"

static NSString *const MacWSFramePath =
    @"/var/mnt/rootfs/private/tmp/macws_vnc_fb";
static NSString *const MacWSLogPath = @"/var/mobile/Library/Logs/MacWSHost.log";

static void MacWSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void MacWSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", message);

    static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&logLock);
    FILE *file = fopen(MacWSLogPath.fileSystemRepresentation, "a");
    if (file) {
        fprintf(file, "%.3f %s\n", NSDate.date.timeIntervalSince1970,
                message.UTF8String);
        fclose(file);
    }
    pthread_mutex_unlock(&logLock);
}

// Read-only witness for Metal's RE-confirmed registration inputs.  The iOS
// 16.3.1 Metal binary's MTLRegisterDevices matches IOAcceleratorES, reads
// MetalPluginName/MetalPluginClassName, and then loads the named bundle.
static void MacWSLogMetalRegistryState(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"), &iterator);
    NSUInteger count = 0;
    io_service_t service;
    while (kr == KERN_SUCCESS && (service = IOIteratorNext(iterator))) {
        count++;
        io_name_t serviceName = {0};
        IORegistryEntryGetName(service, serviceName);
        CFTypeRef pluginValue = IORegistryEntryCreateCFProperty(
            service, CFSTR("MetalPluginName"), kCFAllocatorDefault, 0);
        CFTypeRef classValue = IORegistryEntryCreateCFProperty(
            service, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
        NSString *pluginName = CFBridgingRelease(pluginValue);
        NSString *className = CFBridgingRelease(classValue);
        NSString *bundlePath = pluginName.length
            ? [@"/System/Library/Extensions" stringByAppendingPathComponent:
                [pluginName stringByAppendingString:@".bundle"]]
            : nil;
        NSBundle *bundle = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;
        Class pluginClass = className.length ? NSClassFromString(className) : Nil;
        MacWSLog(@"metal-registry service=%s plugin=%@ class=%@ bundle=%@ loaded=%@ realized=%@",
                 serviceName, pluginName, className, bundlePath,
                 bundle.isLoaded ? @"YES" : @"NO", pluginClass);
        IOObjectRelease(service);
    }
    if (iterator) IOObjectRelease(iterator);
    MacWSLog(@"metal-registry enumeration kr=0x%x count=%lu",
             kr, (unsigned long)count);
}

@interface MacWSMappedFrame : NSObject
@property(nonatomic, readonly) const uint8_t *pixels;
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) uint32_t stride;
@property(nonatomic, readonly) NSString *lastError;
- (BOOL)refresh;
@end

@implementation MacWSMappedFrame {
    void *_mapping;
    size_t _mappingSize;
    dev_t _device;
    ino_t _inode;
    const uint8_t *_pixels;
    uint32_t _width;
    uint32_t _height;
    uint32_t _stride;
    NSString *_lastError;
}

- (void)dealloc {
    if (_mapping) munmap(_mapping, _mappingSize);
}

- (void)setFailure:(NSString *)failure {
    _lastError = failure;
    _pixels = NULL;
    _width = 0;
    _height = 0;
    _stride = 0;
}

- (void)unmap {
    if (_mapping) munmap(_mapping, _mappingSize);
    _mapping = NULL;
    _mappingSize = 0;
    _device = 0;
    _inode = 0;
    _pixels = NULL;
}

- (BOOL)refresh {
    struct stat pathStat;
    const char *path = MacWSFramePath.fileSystemRepresentation;
    if (stat(path, &pathStat) != 0) {
        [self unmap];
        [self setFailure:@"等待 WindowServer 共享帧"];
        return NO;
    }
    if (pathStat.st_size < 16) {
        [self setFailure:@"共享帧尚未初始化"];
        return NO;
    }

    BOOL changed = !_mapping || _mappingSize != (size_t)pathStat.st_size ||
        _device != pathStat.st_dev || _inode != pathStat.st_ino;
    if (changed) {
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            [self setFailure:[NSString stringWithFormat:@"打开共享帧失败: %s",
                              strerror(errno)]];
            return NO;
        }
        struct stat openStat;
        if (fstat(fd, &openStat) != 0 || openStat.st_size < 16) {
            int savedErrno = errno;
            close(fd);
            [self setFailure:[NSString stringWithFormat:@"读取共享帧状态失败: %s",
                              strerror(savedErrno)]];
            return NO;
        }
        size_t newSize = (size_t)openStat.st_size;
        void *newMapping = mmap(NULL, newSize, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (newMapping == MAP_FAILED) {
            [self setFailure:[NSString stringWithFormat:@"映射共享帧失败: %s",
                              strerror(errno)]];
            return NO;
        }
        [self unmap];
        _mapping = newMapping;
        _mappingSize = newSize;
        _device = openStat.st_dev;
        _inode = openStat.st_ino;
    }

    uint32_t header[4];
    memcpy(header, _mapping, sizeof(header));
    uint32_t width = header[1], height = header[2], stride = header[3];
    if (header[0] != MACWS_FRAME_MAGIC || width == 0 || height == 0 ||
        width > 16384 || height > 16384 || stride < width * 4u) {
        [self setFailure:@"共享帧头无效"];
        return NO;
    }
    uint64_t payloadSize = (uint64_t)stride * height;
    if (payloadSize > SIZE_MAX - 16 || 16 + payloadSize > _mappingSize) {
        [self setFailure:@"共享帧长度不完整"];
        return NO;
    }

    _width = width;
    _height = height;
    _stride = stride;
    _pixels = (const uint8_t *)_mapping + 16;
    _lastError = nil;
    return YES;
}

- (const uint8_t *)pixels { return _pixels; }
- (uint32_t)width { return _width; }
- (uint32_t)height { return _height; }
- (uint32_t)stride { return _stride; }
- (NSString *)lastError { return _lastError; }
@end

@class MacWSMetalView;

@protocol MacWSMetalViewStatusDelegate <NSObject>
- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status;
- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record;
@end

@interface MacWSMetalView : MTKView <MTKViewDelegate>
@property(nonatomic, weak) id<MacWSMetalViewStatusDelegate> statusDelegate;
@property(nonatomic) uint64_t sceneID;
@end

@implementation MacWSMetalView {
    MacWSMappedFrame *_frame;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _sourceTexture;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CGRect _contentRect;
    CFTimeInterval _statusEpoch;
    NSUInteger _framesSinceStatus;
    BOOL _reportedNonzeroFrame;
    BOOL _submittedPresentWitness;
    NSString *_lastStatus;
    UIView *_touchMarker;
    UIImageView *_fallbackImageView;
    CADisplayLink *_fallbackDisplayLink;
    uint64_t _fallbackSignature;
    BOOL _reportedFallbackFrame;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) return nil;

    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.enableSetNeedsDisplay = NO;
    self.paused = NO;
    self.preferredFramesPerSecond = 20;
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0.025, 0.028, 0.035, 1.0);
    self.multipleTouchEnabled = YES;
    self.userInteractionEnabled = YES;

    _frame = [MacWSMappedFrame new];
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"MacWSHost display queue";
    _statusEpoch = CACurrentMediaTime();
    _contentRect = CGRectZero;

    _touchMarker = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    _touchMarker.backgroundColor = UIColor.clearColor;
    _touchMarker.layer.borderWidth = 2;
    _touchMarker.layer.borderColor = UIColor.systemCyanColor.CGColor;
    _touchMarker.layer.cornerRadius = 11;
    _touchMarker.userInteractionEnabled = NO;
    _touchMarker.hidden = YES;
    [self addSubview:_touchMarker];

    if (device) {
        [self buildPipeline];
    } else {
        self.paused = YES;
        _fallbackImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _fallbackImageView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fallbackImageView.backgroundColor = UIColor.blackColor;
        _fallbackImageView.contentMode = UIViewContentModeScaleAspectFit;
        _fallbackImageView.userInteractionEnabled = NO;
        [self insertSubview:_fallbackImageView atIndex:0];
        _fallbackDisplayLink = [CADisplayLink displayLinkWithTarget:self
            selector:@selector(drawFallbackFrame:)];
        _fallbackDisplayLink.preferredFramesPerSecond = 5;
        [_fallbackDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                   forMode:NSRunLoopCommonModes];
        MacWSLog(@"native Metal device unavailable; UIKit fallback armed");
    }

    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(hovered:)];
        [self addGestureRecognizer:hover];
    }
    return self;
}

- (void)dealloc {
    [_fallbackDisplayLink invalidate];
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
    _pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
    if (!_pipeline) {
        [self publishStatus:[NSString stringWithFormat:@"Metal pipeline 创建失败: %@",
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
    CGFloat sourceAspect = (CGFloat)_frame.width / (CGFloat)_frame.height;
    CGFloat viewAspect = viewHeight > 0 ? viewWidth / viewHeight : sourceAspect;
    CGFloat sx = 1.0, sy = 1.0;
    if (sourceAspect > viewAspect) {
        sy = viewAspect / sourceAspect;
    } else {
        sx = sourceAspect / viewAspect;
    }
    CGFloat contentWidth = viewWidth * sx;
    CGFloat contentHeight = viewHeight * sy;
    _contentRect = CGRectMake((viewWidth - contentWidth) * 0.5,
                              (viewHeight - contentHeight) * 0.5,
                              contentWidth, contentHeight);
    vertices[0] = (simd_float4){-sx, -sy, 0, 1};
    vertices[1] = (simd_float4){ sx, -sy, 1, 1};
    vertices[2] = (simd_float4){-sx,  sy, 0, 0};
    vertices[3] = (simd_float4){ sx,  sy, 1, 0};
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

- (void)drawFallbackFrame:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (![_frame refresh]) {
        [self publishStatus:_frame.lastError ?: @"等待共享帧"];
        return;
    }
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    uint64_t signature = [self fallbackFrameSignature];
    if (_fallbackImageView.image && signature == _fallbackSignature) return;

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
        BOOL nonzero = [self frameHasSampledContent];
        if (nonzero && !_reportedFallbackFrame) {
            _reportedFallbackFrame = YES;
            MacWSLog(@"runtime-confirmed UIKit fallback frame nonzero %ux%u stride=%u",
                     _frame.width, _frame.height, _frame.stride);
        }
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  UIKit fallback  ·  iOS Metal Device=nil",
            _frame.width, _frame.height]];
    } else {
        [self publishStatus:@"UIKit fallback 无法创建 BGRA 图像"];
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_pipeline || !_commandQueue) return;
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

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    simd_float4 vertices[4];
    [self updateContentRectAndVertices:vertices];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:_sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    if (_reportedNonzeroFrame && !_submittedPresentWitness) {
        _submittedPresentWitness = YES;
        uint32_t witnessWidth = _frame.width;
        uint32_t witnessHeight = _frame.height;
        uint64_t witnessScene = self.sceneID;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSError *error = completed.error;
            MacWSLog(@"runtime-confirmed native Metal present scene=%llx frame=%ux%u status=%ld error=%@",
                     witnessScene, witnessWidth, witnessHeight,
                     (long)completed.status, error ?: @"nil");
        }];
    }
    [commandBuffer commit];

    _framesSinceStatus++;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _statusEpoch >= 1.0) {
        double fps = _framesSinceStatus / (now - _statusEpoch);
        NSString *content = _reportedNonzeroFrame ? @"有效像素" : @"全黑/等待首帧";
        [self publishStatus:[NSString stringWithFormat:@"%u×%u  ·  %.1f fps  ·  %@",
                             _frame.width, _frame.height, fps, content]];
        _statusEpoch = now;
        _framesSinceStatus = 0;
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint output:(CGPoint *)framePoint {
    if (_frame.width == 0 || _frame.height == 0 ||
        CGRectIsEmpty(_contentRect) || !CGRectContainsPoint(_contentRect, viewPoint)) {
        return NO;
    }
    CGFloat nx = (viewPoint.x - CGRectGetMinX(_contentRect)) / _contentRect.size.width;
    CGFloat ny = (viewPoint.y - CGRectGetMinY(_contentRect)) / _contentRect.size.height;
    framePoint->x = fmin(fmax(nx, 0.0), 1.0) * (_frame.width - 1);
    framePoint->y = fmin(fmax(ny, 0.0), 1.0) * (_frame.height - 1);
    return YES;
}

- (void)emitKind:(MacWSInputKind)kind touch:(UITouch *)touch point:(CGPoint)viewPoint {
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    float pressure = touch.maximumPossibleForce > 0
        ? touch.force / touch.maximumPossibleForce : 0.0f;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = self.sceneID,
        .timestamp = touch.timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = (uint32_t)touch.hash,
    };
    _touchMarker.center = viewPoint;
    _touchMarker.hidden = kind == MacWSInputKindTouchUp ||
                          kind == MacWSInputKindTouchCancel;
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitTouches:(NSSet<UITouch *> *)touches kind:(MacWSInputKind)kind {
    for (UITouch *touch in touches)
        [self emitKind:kind touch:touch point:[touch locationInView:self]];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self emitTouches:touches kind:MacWSInputKindTouchDown];
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self emitTouches:touches kind:MacWSInputKindTouchMove];
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self emitTouches:touches kind:MacWSInputKindTouchUp];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self emitTouches:touches kind:MacWSInputKindTouchCancel];
    [super touchesCancelled:touches withEvent:event];
}

- (void)hovered:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4)) {
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = self.sceneID,
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
    };
    _touchMarker.center = viewPoint;
    _touchMarker.hidden = recognizer.state == UIGestureRecognizerStateEnded;
    [self.statusDelegate metalView:self emittedInput:record];
}
@end

@interface MacWSViewController : UIViewController <MacWSMetalViewStatusDelegate>
- (instancetype)initWithSceneIdentifier:(NSString *)identifier;
@end

static void MacWSRequestNewScene(UIScene *requestingScene,
                                 void (^failureHandler)(NSError *error)) {
    UIApplication *application = UIApplication.sharedApplication;
    MacWSLog(@"scene-activation requested supportsMultiple=%@ connected=%lu open=%lu origin=%@ mode=all-nil",
             application.supportsMultipleScenes ? @"YES" : @"NO",
             (unsigned long)application.connectedScenes.count,
             (unsigned long)application.openSessions.count,
             requestingScene.session.persistentIdentifier);
    [application requestSceneSessionActivation:nil
                                  userActivity:nil
                                       options:nil
                                  errorHandler:^(NSError *error) {
        MacWSLog(@"scene-activation failed: %@", error);
        if (failureHandler) failureHandler(error);
    }];
}

@implementation MacWSViewController {
    NSString *_sceneIdentifier;
    UILabel *_statusLabel;
    UILabel *_inputLabel;
    MacWSMetalView *_metalView;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _sceneIdentifier = [identifier copy];
    return self;
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.blackColor;
    self.view = root;

    _metalView = [[MacWSMetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.statusDelegate = self;
    _metalView.sceneID = (uint64_t)_sceneIdentifier.hash;
    [root addSubview:_metalView];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 14;
    panel.clipsToBounds = YES;
    [root addSubview:panel];

    UILabel *title = [UILabel new];
    title.text = @"MacWS · 原生 AGX 画面";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [UILabel new];
    _statusLabel.text = @"正在连接 WindowServer 共享帧…";
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _inputLabel = [UILabel new];
    _inputLabel.text = @"触控桥：M0 坐标验证";
    _inputLabel.textColor = UIColor.systemCyanColor;
    _inputLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _inputLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *newWindow = [UIButton buttonWithType:UIButtonTypeSystem];
    [newWindow setTitle:@"新建窗口" forState:UIControlStateNormal];
    [newWindow addTarget:self action:@selector(openNewWindow)
        forControlEvents:UIControlEventTouchUpInside];
    newWindow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc]
        initWithArrangedSubviews:@[title, _statusLabel, _inputLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:labels];
    [panel.contentView addSubview:newWindow];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [labels.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:14],
        [labels.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:10],
        [labels.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-10],
        [newWindow.leadingAnchor constraintEqualToAnchor:labels.trailingAnchor constant:18],
        [newWindow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-14],
        [newWindow.centerYAnchor constraintEqualToAnchor:panel.contentView.centerYAnchor],
    ]];
}

- (void)openNewWindow {
    MacWSRequestNewScene(self.view.window.windowScene, ^(NSError *error) {
        self->_statusLabel.text = [NSString stringWithFormat:@"新建窗口失败: %@",
                                   error.localizedDescription];
    });
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    (void)view;
    _statusLabel.text = status;
}

- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record {
    (void)view;
    NSString *phase = @"?";
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown: phase = @"down"; break;
        case MacWSInputKindTouchMove: phase = @"move"; break;
        case MacWSInputKindTouchUp: phase = @"up"; break;
        case MacWSInputKindTouchCancel: phase = @"cancel"; break;
        case MacWSInputKindHover: phase = @"hover"; break;
    }
    _inputLabel.text = [NSString stringWithFormat:@"触控桥 M0 · %@ · %.0f, %.0f",
                        phase, record.x, record.y];
    MacWSLog(@"input-v1 scene=%llx kind=%@ point=(%.2f,%.2f) pressure=%.3f contact=%u",
             record.sceneID, phase, record.x, record.y, record.pressure,
             record.contactID);
}
@end

@interface MacWSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end


@implementation MacWSSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    (void)connectionOptions;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    NSString *shortID = session.persistentIdentifier;
    if (shortID.length > 8) shortID = [shortID substringToIndex:8];
    windowScene.title = [NSString stringWithFormat:@"MacWS %@", shortID];
    MacWSViewController *controller = [[MacWSViewController alloc]
        initWithSceneIdentifier:session.persistentIdentifier];
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    MacWSLog(@"scene-connected id=%@ role=%@", session.persistentIdentifier,
             session.role);
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if (![context.URL.host isEqualToString:@"new"]) continue;
        MacWSRequestNewScene(scene, nil);
        break;
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    (void)scene;
    return [[NSUserActivity alloc] initWithActivityType:@"com.macwsguide.host.window"];
}
@end

@interface MacWSAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation MacWSAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)launchOptions;
    id<MTLDevice> nativeDevice = MTLCreateSystemDefaultDevice();
    MacWSLog(@"launched native-device=%@ supportsMultiple=%@ frame-path=%@",
             nativeDevice.name,
             application.supportsMultipleScenes ? @"YES" : @"NO",
             MacWSFramePath);
    MacWSLogMetalRegistryState();
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
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(MacWSAppDelegate.class));
    }
}
