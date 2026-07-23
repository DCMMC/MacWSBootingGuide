// iosclear_ref — native-iOS reference for the AGX render-clear command ABI.
//
// Build this as arm64e/iOS and temporarily place it in a foreground UIKit app
// bundle.  A foreground app has the real iOS Metal/AGX setup that a headless
// ad-hoc tool does not.  The program encodes one BGRA8 IOSurface clear, dumps
// IOGPUMetalCommandBuffer's private kernel-command byte range before commit,
// then proves execution with both command-buffer status and the exact pixel.
//
// This is diagnostic-only.  It does not load libmachook and does not patch any
// driver or command bytes.

@import Foundation;
@import IOSurface;
@import Metal;
@import UIKit;

#import <os/log.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>

static os_log_t g_log;

static size_t macws_dimension_from_env(const char *name, size_t fallback) {
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    return end && *end == '\0' && parsed >= 1 && parsed <= 8192
        ? (size_t)parsed : fallback;
}

static int macws_log_write(void *cookie, const char *bytes, int count) {
    (void)cookie;
    static char line[2048];
    static int used;
    for (int i = 0; i < count; i++) {
        char c = bytes[i];
        if (c == '\n' || used == (int)sizeof(line) - 1) {
            line[used] = 0;
            if (used) os_log_error(g_log, "%{public}s", line);
            used = 0;
            if (c != '\n') line[used++] = c;
        } else {
            line[used++] = c;
        }
    }
    return count;
}

static void macws_dump_commands(id<MTLCommandBuffer> commandBuffer,
                                const char *phase) {
    SEL selector = NSSelectorFromString(
        @"getCurrentKernelCommandBufferStart:current:end:");
    if (![commandBuffer respondsToSelector:selector]) {
        fprintf(stderr, "IOSCLEAR %s no getCurrentKernelCommandBuffer SPI\n",
            phase);
        return;
    }

    void *start = NULL, *current = NULL, *end = NULL;
    IMP method = [(NSObject *)commandBuffer methodForSelector:selector];
    void (*implementation)(id, SEL, void **, void **, void **) =
        (void *)method;
    implementation(commandBuffer, selector, &start, &current, &end);
    size_t length = start && current > start
        ? (size_t)((uintptr_t)current - (uintptr_t)start) : 0;
    fprintf(stderr,
        "IOSCLEAR %s KCMD start=%p current=%p end=%p length=%#zx\n",
        phase, start, current, end, length);
    if (!start || !length || length > 0x10000) return;

    const unsigned char *p = start;
    for (size_t off = 0; off < length; off += 32) {
        char line[256];
        int used = snprintf(line, sizeof(line),
            "IOSCLEAR %s +%04zx:", phase, off);
        for (size_t j = 0; j < 32 && off + j < length; j++) {
            used += snprintf(line + used, sizeof(line) - (size_t)used,
                " %02x", p[off + j]);
        }
        fprintf(stderr, "%s\n", line);
    }

    size_t off = 0;
    unsigned record = 0;
    while (off + 0x38 <= length && record < 16) {
        uint32_t type = *(const uint32_t *)(p + off);
        uint32_t next = *(const uint32_t *)(p + off + 0x28);
        uint32_t size = *(const uint32_t *)(p + off + 0x2c);
        uint32_t inner = *(const uint32_t *)(p + off + 0x30);
        uint32_t subtype = *(const uint32_t *)(p + off + 0x34);
        fprintf(stderr,
            "IOSCLEAR %s record[%u] off=%#zx type=%#x next=%#x "
            "size=%#x inner=%#x subtype=%u\n",
            phase, record++, off, type, next, size, inner, subtype);
        if ((type != 0x10000 && type != 0x10001) ||
            next < 0x38 || next > length - off) break;
        off += next;
    }
}

static void macws_run_clear(void) {
    @autoreleasepool {
        // Diagnostic attach point: unlike IOSCLEAR_HOLD below, this stops
        // before MTLCreateSystemDefaultDevice so project LLDB can observe the
        // complete native IOGPU setup/resource-create sequence.  The sentinel
        // is convenient for a UIKit app launched by FrontBoard, where adding
        // process environment variables is awkward.  It has no effect unless
        // explicitly armed and is intentionally confined to this reference
        // diagnostic.
        if (getenv("IOSCLEAR_EARLY_HOLD") ||
            access("/var/mobile/iosclear_early_hold", F_OK) == 0) {
            fprintf(stderr,
                "IOSCLEAR EARLY-HOLD before MTL device creation pid=%d "
                "(attach project LLDB)\n",
                getpid());
            raise(SIGSTOP);
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        fprintf(stderr, "IOSCLEAR device=%p class=%s name=%s queue=%p\n",
            (__bridge void *)device,
            device ? object_getClassName(device) : "nil",
            device ? [[device name] UTF8String] : "nil",
            (__bridge void *)queue);
        if (!device || !queue) return;

        const size_t width = macws_dimension_from_env("IOSCLEAR_WIDTH", 64);
        const size_t height = macws_dimension_from_env("IOSCLEAR_HEIGHT", 64);
        NSDictionary *properties = @{
            (id)kIOSurfaceWidth: @(width),
            (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
            (id)kIOSurfaceIsGlobal: @YES,
        };
        IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModeShared;
        textureDescriptor.usage = MTLTextureUsageRenderTarget |
            MTLTextureUsageShaderRead;
        id<MTLTexture> texture = surface
            ? [device newTextureWithDescriptor:textureDescriptor
                                     iosurface:surface plane:0] : nil;
        fprintf(stderr, "IOSCLEAR surface=%p texture=%p class=%s\n",
            (void *)surface, (__bridge void *)texture,
            texture ? object_getClassName(texture) : "nil");
        if (!surface || !texture) return;

        MTLCommandBufferDescriptor *commandDescriptor =
            [MTLCommandBufferDescriptor new];
        commandDescriptor.retainedReferences = YES;
        commandDescriptor.errorOptions =
            MTLCommandBufferErrorOptionEncoderExecutionStatus;
        id<MTLCommandBuffer> commandBuffer =
            [queue commandBufferWithDescriptor:commandDescriptor];
        commandBuffer.label = @"IOSCLEAR native clear reference";

        MTLRenderPassDescriptor *renderPass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        renderPass.colorAttachments[0].texture = texture;
        renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.125, 0.25, 0.5, 1.0);
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
        encoder.label = @"IOSCLEAR native clear reference";
        [encoder endEncoding];

        macws_dump_commands(commandBuffer, "PRE");
        if (getenv("IOSCLEAR_HOLD")) {
            fprintf(stderr,
                "IOSCLEAR HOLD before commit pid=%d (attach project LLDB)\n",
                getpid());
            raise(SIGSTOP);
        }
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        // Do not call getCurrentKernelCommandBuffer... after completion.  The
        // iOS implementation releases its state before waitUntilCompleted
        // returns in a headless process; runtime crash evidence showed the
        // method dereferencing state+0x28 through NULL.  Project LLDB captures
        // the populated state synchronously at IOConnectCallMethod(sel=0x1a).

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
        const unsigned char *base = IOSurfaceGetBaseAddress(surface);
        const unsigned char *pixel = base
            ? base + (height / 2) * bytesPerRow + (width / 2) * 4 : NULL;
        fprintf(stderr,
            "IOSCLEAR RESULT status=%ld error=%s bpr=%zu center=%02x%02x%02x%02x\n",
            (long)[commandBuffer status], [commandBuffer error]
                ? [[[commandBuffer error] description] UTF8String] : "nil",
            bytesPerRow, pixel ? pixel[0] : 0, pixel ? pixel[1] : 0,
            pixel ? pixel[2] : 0, pixel ? pixel[3] : 0);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        CFRelease(surface);
    }
}

@interface IOSClearAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation IOSClearAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            macws_run_clear();
        });
    return YES;
}
@end

int main(int argc, char **argv) {
    g_log = os_log_create("com.dcmmc.iosclear", "reference");
    FILE *stream = funopen(NULL, NULL, macws_log_write, NULL, NULL);
    if (stream) {
        setvbuf(stream, NULL, _IONBF, 0);
        stderr = stream;
    }
    fprintf(stderr, "IOSCLEAR main pid=%d\n", getpid());
    // Lock-screen fallback for diagnostics.  This deliberately runs the same
    // binary/entitlements without UIApplication foreground activation.  If
    // MTLCreateSystemDefaultDevice fails here, that is runtime evidence that
    // the foreground sandbox extension (not merely platform-application) is
    // required; the normal UIKit path remains the authoritative reference.
    if (getenv("IOSCLEAR_HEADLESS")) {
        fprintf(stderr, "IOSCLEAR entering headless fallback\n");
        macws_run_clear();
        sleep(2);
        return 0;
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass(IOSClearAppDelegate.class));
    }
}
