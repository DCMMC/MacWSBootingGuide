#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

// Minimal chroot-side witness for the MTLCompilerService bridge.  It avoids
// WindowServer, Electron and Aquarium so one source compile can be tested
// without a GPU-process restart loop or sustained compositor load.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "METAL_SOURCE_PROBE device=%p class=%s name=%s\n",
                device,
                device ? object_getClassName(device) : "(nil)",
                device ? device.name.UTF8String : "(nil)");
        if (!device) return 2;

        // Chromium/ANGLE uses MTLSharedEvent for EGL fences before the
        // Aquarium draw loop starts.  Keep this as an independent witness:
        // a nil event must be diagnosed at creation time instead of being
        // handed to -encodeSignalEvent:value:, where AGX's superclass raises
        // an NSArray nil-insertion exception.
        id<MTLSharedEvent> sharedEvent = nil;
        if ([device respondsToSelector:@selector(newSharedEvent)])
            sharedEvent = [device newSharedEvent];
        fprintf(stderr,
                "METAL_SOURCE_PROBE sharedEvent=%p class=%s signaledValue=%llu\n",
                sharedEvent,
                sharedEvent ? object_getClassName(sharedEvent) : "(nil)",
                (unsigned long long)(sharedEvent
                    ? sharedEvent.signaledValue : 0));

        // Chromium 148's actual libGLESv2 binary calls the older private
        // -newEvent selector (RE-confirmed at arm64 file offset 0x2db888),
        // not public -newSharedEvent.  Compare the two on the same device.
        SEL newEventSelector = sel_registerName("newEvent");
        BOOL respondsToNewEvent = [device respondsToSelector:newEventSelector];
        id legacyEvent = respondsToNewEvent
            ? ((id (*)(id, SEL))objc_msgSend)(device, newEventSelector)
            : nil;
        fprintf(stderr,
                "METAL_SOURCE_PROBE newEvent responds=%d event=%p class=%s\n",
                respondsToNewEvent, legacyEvent,
                legacyEvent ? object_getClassName(legacyEvent) : "(nil)");

        if (sharedEvent) {
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> signalBuffer = [queue commandBuffer];
            id<MTLCommandBuffer> waitBuffer = [queue commandBuffer];
            @try {
                [signalBuffer encodeSignalEvent:sharedEvent value:1];
                [waitBuffer encodeWaitForEvent:sharedEvent value:1];
                [signalBuffer commit];
                [waitBuffer commit];
                [waitBuffer waitUntilCompleted];
                fprintf(stderr,
                        "METAL_SOURCE_PROBE sharedEventCommands "
                        "signalStatus=%ld waitStatus=%ld eventValue=%llu "
                        "signalError=%s waitError=%s\n",
                        (long)signalBuffer.status,
                        (long)waitBuffer.status,
                        (unsigned long long)sharedEvent.signaledValue,
                        signalBuffer.error
                            ? signalBuffer.error.localizedDescription.UTF8String
                            : "(nil)",
                        waitBuffer.error
                            ? waitBuffer.error.localizedDescription.UTF8String
                            : "(nil)");
            } @catch (NSException *exception) {
                fprintf(stderr,
                        "METAL_SOURCE_PROBE sharedEventCommand exception=%s "
                        "reason=%s\n",
                        exception.name.UTF8String,
                        exception.reason.UTF8String);
            }
        }

        // Include a per-process comment so each invocation proves a fresh XPC
        // compilation instead of accepting a persistent source-cache hit.
        NSString *source = [NSString stringWithFormat:
            @"// macws source probe pid=%d\n"
             "#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "kernel void macws_probe(device uint *out [[buffer(0)]], "
             "uint tid [[thread_position_in_grid]]) { out[tid] = tid + 1; }\n",
             getpid()];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source
                                                      options:options
                                                        error:&error];
        fprintf(stderr,
                "METAL_SOURCE_PROBE library=%p class=%s errorDomain=%s "
                "errorCode=%ld description=%s\n",
                library,
                library ? object_getClassName(library) : "(nil)",
                error ? error.domain.UTF8String : "(nil)",
                (long)(error ? error.code : 0),
                error ? error.localizedDescription.UTF8String : "(nil)");
        if (!library) return 3;

        id<MTLFunction> function = [library newFunctionWithName:@"macws_probe"];
        fprintf(stderr, "METAL_SOURCE_PROBE function=%p class=%s\n",
                function,
                function ? object_getClassName(function) : "(nil)");
        return function ? 0 : 4;
    }
}
