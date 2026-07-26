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
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#import "MacWSControlClient.h"
#include "macws_control_protocol.h"
#include "macws_host_protocol.h"

static NSString *const MacWSFramePath =
    @"/var/mnt/rootfs/private/tmp/macws_vnc_fb";
static NSString *const MacWSCaptureAckPath =
    @"/var/mnt/rootfs/private/tmp/macws_capture_done";
static NSString *const MacWSLogPath = @"/var/mobile/Library/Logs/MacWSHost.log";
static const char MacWSInputSocketPath[] =
    "/var/mnt/rootfs/private/tmp/macws_host_input.sock";

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

static BOOL MacWSSendInputRecord(const MacWSInputRecord *record,
                                 int *errorOut) {
    static int socketFD = -1;
    static pthread_mutex_t socketLock = PTHREAD_MUTEX_INITIALIZER;
    BOOL sent = NO;
    int savedError = 0;

    pthread_mutex_lock(&socketLock);
    if (socketFD < 0) {
        socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (socketFD < 0) savedError = errno;
    }
    if (socketFD >= 0) {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        _Static_assert(sizeof(MacWSInputSocketPath) <= sizeof(address.sun_path),
                       "input socket path exceeds sockaddr_un.sun_path");
        memcpy(address.sun_path, MacWSInputSocketPath,
               sizeof(MacWSInputSocketPath));
        ssize_t written = sendto(socketFD, record, sizeof(*record), 0,
                                 (const struct sockaddr *)&address,
                                 sizeof(address));
        sent = written == (ssize_t)sizeof(*record);
        if (!sent) savedError = written < 0 ? errno : EMSGSIZE;
    }
    pthread_mutex_unlock(&socketLock);

    if (errorOut) *errorOut = savedError;
    return sent;
}

static BOOL MacWSReadCaptureAck(uint64_t *generationOut) {
    char value[96] = {0};
    int fd = open(MacWSCaptureAckPath.fileSystemRepresentation,
                  O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return NO;
    int producerPID = 0;
    unsigned long long generation = 0;
    if (sscanf(value, "%d %llu", &producerPID, &generation) != 2 ||
        producerPID <= 0 || generation == 0) {
        return NO;
    }
    if (generationOut) *generationOut = (uint64_t)generation;
    return YES;
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
@property(nonatomic) int32_t targetPID;
@property(nonatomic, getter=isMacWSInputEnabled) BOOL macWSInputEnabled;
- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason;
@end

@implementation MacWSMetalView {
    MacWSMappedFrame *_frame;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _sourceTexture;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CGRect _contentRect;
    BOOL _reportedNonzeroFrame;
    BOOL _submittedPresentWitness;
    NSString *_lastStatus;
    UIView *_touchMarker;
    UILabel *_inputUnavailableLabel;
    UIImageView *_fallbackImageView;
    CADisplayLink *_framePollDisplayLink;
    uint64_t _fallbackSignature;
    BOOL _reportedFallbackFrame;
    uint64_t _pendingCaptureGeneration;
    uint64_t _presentedCaptureGeneration;
    BOOL _macWSInputEnabled;
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
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0.025, 0.028, 0.035, 1.0);
    self.multipleTouchEnabled = YES;
    // Status polling enables interaction only after WindowServer, the input
    // socket and an exact-PID acknowledged frame are all present.  A stale
    // screenshot must never look like a live, touchable workspace.
    self.userInteractionEnabled = NO;

    _frame = [MacWSMappedFrame new];
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"MacWSHost display queue";
    _contentRect = CGRectZero;

    _touchMarker = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    _touchMarker.backgroundColor = UIColor.clearColor;
    _touchMarker.layer.borderWidth = 2;
    _touchMarker.layer.borderColor = UIColor.systemCyanColor.CGColor;
    _touchMarker.layer.cornerRadius = 11;
    _touchMarker.userInteractionEnabled = NO;
    _touchMarker.hidden = YES;
    [self addSubview:_touchMarker];

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
        MacWSLog(@"native Metal device unavailable; UIKit fallback armed");
    }

    _framePollDisplayLink = [CADisplayLink displayLinkWithTarget:self
        selector:@selector(pollSharedFrame:)];
    _framePollDisplayLink.preferredFramesPerSecond = 5;
    [_framePollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                               forMode:NSRunLoopCommonModes];

    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(hovered:)];
        [self addGestureRecognizer:hover];
    }
    return self;
}

- (void)dealloc {
    [_framePollDisplayLink invalidate];
}

- (void)setMacWSInputEnabled:(BOOL)enabled {
    [self setMacWSInputEnabled:enabled reason:nil];
}

- (BOOL)isMacWSInputEnabled {
    return _macWSInputEnabled;
}

- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason {
    _macWSInputEnabled = enabled;
    self.userInteractionEnabled = enabled;
    _inputUnavailableLabel.hidden = enabled;
    if (!enabled) {
        _touchMarker.hidden = YES;
        _inputUnavailableLabel.text = [NSString stringWithFormat:
            @"触控暂不可用 · %@", reason.length ? reason : @"工作区未就绪"];
    }
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
    _presentedCaptureGeneration = _pendingCaptureGeneration;
    _pendingCaptureGeneration = 0;
    NSString *content = _reportedNonzeroFrame ? @"有效像素" : @"全黑";
    [self publishStatus:[NSString stringWithFormat:
        @"%u×%u  ·  快照 #%llu  ·  %@",
        _frame.width, _frame.height,
        (unsigned long long)_presentedCaptureGeneration, content]];
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
    if (!self.isMacWSInputEnabled) return;
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
        .frameWidth = _frame.width,
        .frameHeight = _frame.height,
        .targetPID = self.targetPID,
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
    if (!self.isMacWSInputEnabled) return;
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
        .frameWidth = _frame.width,
        .frameHeight = _frame.height,
        .targetPID = self.targetPID,
    };
    _touchMarker.center = viewPoint;
    _touchMarker.hidden = recognizer.state == UIGestureRecognizerStateEnded;
    [self.statusDelegate metalView:self emittedInput:record];
}
@end

@interface MacWSViewController : UIViewController <MacWSMetalViewStatusDelegate>
- (instancetype)initWithSceneIdentifier:(NSString *)identifier;
- (void)performURLAction:(NSString *)action;
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
    MacWSControlClient *_controlClient;
    UIVisualEffectView *_controlPanel;
    UIButton *_showControlsButton;
    UILabel *_serviceLabel;
    UILabel *_phaseLabel;
    UILabel *_rootfsLabel;
    UILabel *_windowServerLabel;
    UILabel *_bridgeLabel;
    UILabel *_frameLabel;
    UILabel *_statusLabel;
    UILabel *_inputLabel;
    UILabel *_noticeLabel;
    UIButton *_primaryButton;
    UIButton *_repairButton;
    UIButton *_recoverButton;
    UIButton *_captureButton;
    UIButton *_logsButton;
    UIButton *_exportButton;
    UITextView *_logsView;
    UISwitch *_experimentalSwitch;
    NSArray<UIButton *> *_applicationButtons;
    MacWSMetalView *_metalView;
    NSTimer *_statusTimer;
    NSDictionary<NSString *, id> *_latestStatus;
    BOOL _experimentalTouched;
    uint64_t _inputLogSequence;
    NSString *_lastLoggedControlSummary;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sceneIdentifier = [identifier copy];
        _controlClient = [MacWSControlClient new];
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

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.blackColor;
    self.view = root;

    _metalView = [[MacWSMetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.statusDelegate = self;
    _metalView.sceneID = (uint64_t)_sceneIdentifier.hash;
    [root addSubview:_metalView];

    _controlPanel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlPanel.layer.cornerRadius = 22;
    _controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _controlPanel.clipsToBounds = YES;
    [root addSubview:_controlPanel];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [_controlPanel.contentView addSubview:scroll];

    UILabel *title = MacWSMakeLabel(@"MacWS 控制中心",
        [UIFont systemFontOfSize:23 weight:UIFontWeightBold], UIColor.labelColor);
    UILabel *subtitle = MacWSMakeLabel(@"iPadOS 原生窗口 · macOS AGX 工作区",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);
    UIStackView *titleLabels = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
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

    UILabel *experimentalText = MacWSMakeLabel(@"实验兼容模式",
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.labelColor);
    UILabel *experimentalDetail = MacWSMakeLabel(
        @"启用命令 ABI / completion 诊断脚手架；受 90 秒与高 CPU 热保护，不是根因修复。",
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
        UIColor.systemOrangeColor);
    UIStackView *experimentalLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[experimentalText, experimentalDetail]];
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
    _applicationButtons = @[glassDemo, terminal, activity, finder];
    UIStackView *appRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[glassDemo, terminal]];
    UIStackView *appRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[activity, finder]];
    for (UIStackView *row in @[appRow1, appRow2]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _captureButton = [self buttonWithTitle:@"刷新画面" image:@"camera.viewfinder"
                                    action:@selector(captureAction) prominent:NO];
    _repairButton = [self buttonWithTitle:@"修复环境" image:@"wrench.and.screwdriver"
                                   action:@selector(repairAction) prominent:NO];
    _recoverButton = [self buttonWithTitle:@"安全恢复" image:@"lifepreserver"
                                    action:@selector(recoverAction) prominent:NO];
    _logsButton = [self buttonWithTitle:@"查看日志" image:@"doc.text.magnifyingglass"
                                 action:@selector(logsAction) prominent:NO];
    _exportButton = [self buttonWithTitle:@"导出诊断" image:@"square.and.arrow.up"
                                   action:@selector(exportDiagnostics) prominent:NO];
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
    [_logsView.heightAnchor constraintEqualToConstant:220].active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        serviceCard,
        [self sectionTitle:@"系统状态"],
        statusRows,
        _primaryButton,
        experimentalRow,
        [self sectionTitle:@"macOS 应用"],
        appRow1,
        appRow2,
        [self sectionTitle:@"工具与恢复"],
        toolRow1,
        toolRow2,
        _exportButton,
        _noticeLabel,
        [self divider],
        _statusLabel,
        _inputLabel,
        _logsView,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    content.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:content];

    _showControlsButton = [self buttonWithTitle:@"控制中心" image:@"sidebar.left"
                                         action:@selector(showControls) prominent:YES];
    _showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _showControlsButton.hidden = YES;
    [root addSubview:_showControlsButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *responsiveWidth = [_controlPanel.widthAnchor
        constraintEqualToAnchor:safe.widthAnchor multiplier:0.92];
    responsiveWidth.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_controlPanel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
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
        [_showControlsButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_showControlsButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
        selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)hideControls {
    _controlPanel.hidden = YES;
    _showControlsButton.hidden = NO;
}

- (void)showControls {
    _controlPanel.hidden = NO;
    _showControlsButton.hidden = YES;
}

- (void)setNotice:(NSString *)notice success:(BOOL)success {
    _noticeLabel.hidden = notice.length == 0;
    _noticeLabel.text = notice;
    _noticeLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
}

- (void)setControlsEnabled:(BOOL)enabled {
    _primaryButton.enabled = enabled;
    _repairButton.enabled = enabled;
    _recoverButton.enabled = enabled;
    _captureButton.enabled = enabled;
    _exportButton.enabled = enabled;
    _experimentalSwitch.enabled = enabled;
    for (UIButton *button in _applicationButtons) button.enabled = enabled;
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
    BOOL frame = [status[@"frame_ready"] boolValue];
    BOOL appInput = [status[@"app_input_ready"] boolValue];
    int32_t activeAppPID = (int32_t)[status[@"active_app_pid"] intValue];
    NSString *controlSummary = [NSString stringWithFormat:
        @"connected=%@ busy=%@ rootfs=%@ ws=%@ input=%@ frame=%@ phase=%@ error=%@",
        connected ? @"YES" : @"NO", busy ? @"YES" : @"NO",
        rootfs ? @"YES" : @"NO", ws ? @"YES" : @"NO",
        input ? @"YES" : @"NO", frame ? @"YES" : @"NO",
        status[@"phase"] ?: @"", status[@"last_error"] ?: @""];
    if (![_lastLoggedControlSummary isEqualToString:controlSummary]) {
        _lastLoggedControlSummary = controlSummary;
        MacWSLog(@"control-status %@", controlSummary);
    }
    _serviceLabel.text = connected ? @"● root 控制服务已连接" : @"● root 控制服务离线";
    _serviceLabel.textColor = connected ? UIColor.systemGreenColor : UIColor.systemRedColor;
    _phaseLabel.text = status[@"phase"] ?: status[@"message"] ?: @"等待状态";
    _rootfsLabel.text = rootfs ? @"就绪" : @"缺失/未挂载";
    _rootfsLabel.textColor = rootfs ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSInteger wsPID = [status[@"windowserver_pid"] integerValue];
    _windowServerLabel.text = ws ? [NSString stringWithFormat:@"运行中 · %ld", (long)wsPID] : @"已停止";
    _windowServerLabel.textColor = ws ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    _bridgeLabel.text = input
        ? (activeAppPID > 1 && appInput
            ? [NSString stringWithFormat:@"在线 · 目标 PID %d", activeAppPID]
            : (activeAppPID > 1 ? @"在线 · 等待应用输入端点" : @"在线 · 等待应用"))
        : @"离线";
    _bridgeLabel.textColor = input ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    if (frame) {
        _frameLabel.text = [NSString stringWithFormat:@"%@×%@",
                            status[@"frame_width"], status[@"frame_height"]];
        _frameLabel.textColor = UIColor.systemGreenColor;
    } else {
        _frameLabel.text = @"等待首帧";
        _frameLabel.textColor = UIColor.systemOrangeColor;
    }
    if (!_experimentalTouched || ws) {
        _experimentalSwitch.on = [status[@"experimental_mode"] boolValue];
    }
    NSString *lastError = status[@"last_error"];
    if (lastError.length) [self setNotice:lastError success:NO];

    _metalView.targetPID = activeAppPID;
    BOOL inputReady = connected && !busy && ws && input && frame &&
        activeAppPID > 1 && appInput;
    NSString *inputReason = nil;
    if (!connected) inputReason = @"root 控制服务离线";
    else if (busy) inputReason = @"macOS 正在启动或切换";
    else if (!ws) inputReason = @"macOS 工作区已停止";
    else if (!input) inputReason = @"触控桥离线";
    else if (!frame) inputReason = @"等待已确认的共享帧";
    else if (activeAppPID <= 1) inputReason = @"请先从控制中心启动一个 macOS 应用";
    else if (!appInput) inputReason = @"目标应用输入端点尚未就绪";
    [_metalView setMacWSInputEnabled:inputReady reason:inputReason];
    _inputLabel.text = inputReady
        ? @"触控：已就绪 · 直接点击或拖动 macOS 画面"
        : [NSString stringWithFormat:@"触控：不可用 · %@",
           inputReason ?: @"工作区未就绪"];
    _inputLabel.textColor = inputReady
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;

    [self setControlsEnabled:connected && !busy];
    if (busy) {
        [self setButton:_primaryButton title:status[@"phase"] ?: @"处理中…"
                   image:@"hourglass"];
    } else if (ws) {
        [self setButton:_primaryButton title:@"停止 macOS" image:@"stop.fill"];
    } else {
        [self setButton:_primaryButton
                  title:rootfs ? @"启动 macOS 工作区" : @"初始化并启动"
                  image:@"play.fill"];
    }

    NSDictionary<NSString *, NSString *> *availability = @{
        @"glassdemo": @"glassdemo_available",
        @"terminal": @"terminal_available",
        @"activity-monitor": @"activity_monitor_available",
        @"finder": @"finder_available",
    };
    for (UIButton *button in _applicationButtons) {
        BOOL available = [status[availability[button.accessibilityIdentifier]] boolValue];
        button.enabled = connected && !busy && ws && available;
    }
}

- (void)runOperation:(NSString *)operation arguments:(NSDictionary *)arguments {
    [self setControlsEnabled:NO];
    [self setNotice:@"操作已提交，请保持 App 在前台…" success:YES];
    [_controlClient performOperation:operation arguments:arguments
        completion:^(NSDictionary<NSString *,id> *reply) {
            BOOL ok = [reply[@"ok"] boolValue];
            [self setNotice:reply[@"message"] ?: @"操作完成" success:ok];
            [self applyStatus:reply];
            [self refreshStatus];
        }];
}

- (void)primaryAction {
    if ([_latestStatus[@"windowserver_running"] boolValue]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else {
        [self setControlsEnabled:NO];
        [self setNotice:_experimentalSwitch.isOn
            ? @"正在用实验兼容模式启动；已启用 90 秒与高 CPU 自动热保护。"
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

- (void)experimentalChanged:(UISwitch *)sender {
    _experimentalTouched = YES;
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn
                                          forKey:@"MacWSExperimentalMode"];
    NSString *state = sender.isOn ? @"已选择实验兼容模式，将在下次启动时生效。" :
        @"已选择标准模式，将在下次启动时移除诊断脚手架。";
    [self setNotice:state success:!sender.isOn];
}

- (void)launchApplication:(UIButton *)sender {
    [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
             arguments:@{@MACWS_CONTROL_KEY_APP_ID: sender.accessibilityIdentifier ?: @""}];
}

- (void)captureAction {
    [self runOperation:@MACWS_CONTROL_OP_CAPTURE arguments:nil];
}

- (void)repairAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR arguments:nil];
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
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:self.view.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *png = UIImagePNGRepresentation(image);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-ui.png";
    BOOL written = [png writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"ui-snapshot written=%@ bytes=%lu path=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (void)exportDiagnostics {
    NSURL *snapshot = [self writeHostUISnapshot];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"MacWS Host diagnostics\n%@\n\n=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
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
               [action isEqualToString:@"activity-monitor"] ||
               [action isEqualToString:@"finder"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: action}];
    } else if ([action isEqualToString:@"recover"]) {
        [self recoverAction];
    } else if ([action isEqualToString:@"repair"]) {
        [self repairAction];
    } else if ([action isEqualToString:@"capture"]) {
        [self captureAction];
    } else if ([action isEqualToString:@"screenshot-ui"]) {
        [self writeHostUISnapshot];
    }
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    (void)view;
    _statusLabel.text = [@"画面：" stringByAppendingString:status];
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
    int sendError = 0;
    BOOL sent = MacWSSendInputRecord(&record, &sendError);
    _inputLabel.text = [NSString stringWithFormat:
        @"触控桥 M4 %@ · %@ · %.0f, %.0f",
        sent ? @"已发送" : @"离线", phase, record.x, record.y];
    _inputLogSequence++;
    BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                      record.kind == MacWSInputKindHover;
    if (!continuous || (_inputLogSequence % 60) == 0) {
        MacWSLog(@"input-v3 transport=%@ errno=%d scene=%llx target=%d kind=%@ point=(%.2f,%.2f) frame=%ux%u pressure=%.3f contact=%u seq=%llu",
                 sent ? @"sent" : @"failed", sendError, record.sceneID,
                 record.targetPID, phase, record.x, record.y,
                 record.frameWidth, record.frameHeight,
                 record.pressure, record.contactID,
                 (unsigned long long)_inputLogSequence);
    }
    if (!sent) {
        [_metalView setMacWSInputEnabled:NO reason:@"触控桥连接已中断"];
        [self refreshStatus];
    }
}
@end

@interface MacWSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end


@implementation MacWSSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
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
    if (connectionOptions.URLContexts.count) {
        NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scene:scene openURLContexts:contexts];
        });
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if ([context.URL.host isEqualToString:@"new"]) {
            MacWSRequestNewScene(scene, nil);
            break;
        }
        if ([context.URL.host isEqualToString:@"test-input"]) {
            // Explicit transport diagnostic. Query parameters allow two-point
            // cursor A/Bs or a complete down/up pair without fabricating UIKit
            // touches:
            // macwshost://test-input?kind=tap&x=1194&y=834&w=2388&h=1668
            uint32_t frameWidth = 2388;
            uint32_t frameHeight = 1668;
            float x = 1194.0f;
            float y = 834.0f;
            NSString *requestedKind = @"hover";
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"x"]) x = item.value.floatValue;
                else if ([item.name isEqualToString:@"y"]) y = item.value.floatValue;
                else if ([item.name isEqualToString:@"w"]) frameWidth = item.value.intValue;
                else if ([item.name isEqualToString:@"h"]) frameHeight = item.value.intValue;
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
                .sceneID = (uint64_t)scene.session.persistentIdentifier.hash,
                .timestamp = CACurrentMediaTime(),
                .x = x,
                .y = y,
                .contactID = MACWS_INPUT_CONTACT_DIAGNOSTIC,
                .frameWidth = frameWidth,
                .frameHeight = frameHeight,
                .targetPID = 0,
            };
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            NSDictionary *status = [controller valueForKey:@"latestStatus"];
            record.targetPID = (int32_t)[status[@"active_app_pid"] intValue];
            if ([requestedKind isEqualToString:@"tap"])
                record.kind = MacWSInputKindTouchDown;
            int sendError = 0;
            BOOL sent = MacWSSendInputRecord(&record, &sendError);
            MacWSLog(@"input-v3 synthetic kind=%@ transport=%@ errno=%d scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                     requestedKind,
                     sent ? @"sent" : @"failed", sendError, record.sceneID,
                     record.targetPID, record.x, record.y,
                     record.frameWidth, record.frameHeight);
            if (sent && record.kind == MacWSInputKindTouchDown) {
                record.kind = MacWSInputKindTouchUp;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              60 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    int upError = 0;
                    BOOL upSent = MacWSSendInputRecord(&record, &upError);
                    MacWSLog(@"input-v3 synthetic kind=tap-up transport=%@ errno=%d scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                             upSent ? @"sent" : @"failed", upError,
                             record.sceneID, record.targetPID,
                             record.x, record.y,
                             record.frameWidth, record.frameHeight);
                });
            }
            break;
        }
        NSString *host = context.URL.host ?: @"status";
        if ([@[@"status", @"start", @"start-experimental", @"stop",
               @"glassdemo", @"terminal", @"activity-monitor", @"finder",
               @"recover", @"repair", @"capture",
               @"screenshot-ui"] containsObject:host]) {
            MacWSViewController *controller = (MacWSViewController *)self.window.rootViewController;
            [controller performURLAction:host];
            break;
        }
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
