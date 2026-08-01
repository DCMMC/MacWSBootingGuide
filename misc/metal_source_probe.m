#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

static void DumpNewEventImplementation(id device) {
    if (!getenv("MACWS_METAL_PROBE_DUMP_EVENT_IMP")) return;

    SEL selector = sel_registerName("newEvent");
    Class concreteClass = object_getClass(device);
    Method resolved = class_getInstanceMethod(concreteClass, selector);
    IMP signedImplementation = resolved ? method_getImplementation(resolved) : NULL;
    const unsigned char *implementation = signedImplementation
        ? (const unsigned char *)ptrauth_strip(
              signedImplementation, ptrauth_key_function_pointer)
        : NULL;
    Class owner = Nil;
    for (Class candidate = concreteClass; candidate && !owner;
         candidate = class_getSuperclass(candidate)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(candidate, &count);
        for (unsigned index = 0; methods && index < count; index++) {
            if (method_getName(methods[index]) == selector) {
                owner = candidate;
                break;
            }
        }
        free(methods);
    }

    Dl_info imageInfo = {0};
    BOOL hasImage = implementation && dladdr(implementation, &imageInfo);
    fprintf(stderr,
            "METAL_SOURCE_PROBE newEventIMP class=%s owner=%s imp=%p "
            "image=%s imageBase=%p symbol=%s symbolBase=%p\n",
            class_getName(concreteClass),
            owner ? class_getName(owner) : "(none)", implementation,
            hasImage && imageInfo.dli_fname ? imageInfo.dli_fname : "(unknown)",
            hasImage ? imageInfo.dli_fbase : NULL,
            hasImage && imageInfo.dli_sname ? imageInfo.dli_sname : "(unknown)",
            hasImage ? imageInfo.dli_saddr : NULL);
    if (!implementation) return;

    // A bounded byte witness avoids debugger/shared-cache symbol dependence.
    // The executable mapping is readable on both tested arm64e systems.
    for (size_t offset = 0; offset < 192; offset += 16) {
        fprintf(stderr, "METAL_SOURCE_PROBE newEventCode +0x%03zx:", offset);
        for (size_t byte = 0; byte < 16; byte++)
            fprintf(stderr, " %02x", implementation[offset + byte]);
        fputc('\n', stderr);
    }

    Class eventClass = objc_getClass("IOGPUMTLEvent");
    SEL initSelector = sel_registerName("initWithDevice:");
    Method initMethod = eventClass
        ? class_getInstanceMethod(eventClass, initSelector) : NULL;
    IMP signedInit = initMethod ? method_getImplementation(initMethod) : NULL;
    const unsigned char *initImplementation = signedInit
        ? (const unsigned char *)ptrauth_strip(
              signedInit, ptrauth_key_function_pointer)
        : NULL;
    Dl_info initImageInfo = {0};
    BOOL hasInitImage = initImplementation &&
        dladdr(initImplementation, &initImageInfo);
    fprintf(stderr,
            "METAL_SOURCE_PROBE eventInitIMP class=%s imp=%p image=%s "
            "imageBase=%p symbol=%s symbolBase=%p\n",
            eventClass ? class_getName(eventClass) : "(none)",
            initImplementation,
            hasInitImage && initImageInfo.dli_fname
                ? initImageInfo.dli_fname : "(unknown)",
            hasInitImage ? initImageInfo.dli_fbase : NULL,
            hasInitImage && initImageInfo.dli_sname
                ? initImageInfo.dli_sname : "(unknown)",
            hasInitImage ? initImageInfo.dli_saddr : NULL);
    if (!initImplementation) return;
    for (size_t offset = 0; offset < 256; offset += 16) {
        fprintf(stderr, "METAL_SOURCE_PROBE eventInitCode +0x%03zx:", offset);
        for (size_t byte = 0; byte < 16; byte++)
            fprintf(stderr, " %02x", initImplementation[offset + byte]);
        fputc('\n', stderr);
    }

    // Event creation and destruction are adjacent external-method ABI
    // operations, but their selector deltas differ across the macOS 13.4 and
    // iOS 16.3 IOGPU builds.  Dump the concrete dealloc IMP as a second,
    // independent byte witness so the translation table can be derived from
    // both producers instead of inferred from selector numbering.
    SEL deallocSelector = sel_registerName("dealloc");
    Method deallocMethod = eventClass
        ? class_getInstanceMethod(eventClass, deallocSelector) : NULL;
    IMP signedDealloc = deallocMethod
        ? method_getImplementation(deallocMethod) : NULL;
    const unsigned char *deallocImplementation = signedDealloc
        ? (const unsigned char *)ptrauth_strip(
              signedDealloc, ptrauth_key_function_pointer)
        : NULL;
    Dl_info deallocImageInfo = {0};
    BOOL hasDeallocImage = deallocImplementation &&
        dladdr(deallocImplementation, &deallocImageInfo);
    fprintf(stderr,
            "METAL_SOURCE_PROBE eventDeallocIMP class=%s imp=%p image=%s "
            "imageBase=%p symbol=%s symbolBase=%p\n",
            eventClass ? class_getName(eventClass) : "(none)",
            deallocImplementation,
            hasDeallocImage && deallocImageInfo.dli_fname
                ? deallocImageInfo.dli_fname : "(unknown)",
            hasDeallocImage ? deallocImageInfo.dli_fbase : NULL,
            hasDeallocImage && deallocImageInfo.dli_sname
                ? deallocImageInfo.dli_sname : "(unknown)",
            hasDeallocImage ? deallocImageInfo.dli_saddr : NULL);
    if (!deallocImplementation) return;
    for (size_t offset = 0; offset < 160; offset += 16) {
        fprintf(stderr,
                "METAL_SOURCE_PROBE eventDeallocCode +0x%03zx:", offset);
        for (size_t byte = 0; byte < 16; byte++)
            fprintf(stderr, " %02x", deallocImplementation[offset + byte]);
        fputc('\n', stderr);
    }
}

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

        DumpNewEventImplementation(device);

        // Optional bounded LLDB attach window.  Pause only after Metal and the
        // concrete AGX/IOGPU classes are loaded, but before either event
        // constructor is called.  This is a read-only diagnostic aid; normal
        // probe invocations do not set the variable and remain unchanged.
        const char *pauseText = getenv("MACWS_METAL_PROBE_PAUSE_SECONDS");
        if (pauseText) {
            unsigned long pauseSeconds = strtoul(pauseText, NULL, 10);
            if (pauseSeconds > 120) pauseSeconds = 120;
            if (pauseSeconds) {
                fprintf(stderr,
                        "METAL_SOURCE_PROBE lldbPauseSeconds=%lu pid=%d\n",
                        pauseSeconds, getpid());
                sleep((unsigned)pauseSeconds);
            }
        }

        // Chromium/ANGLE uses MTLSharedEvent for EGL fences before the
        // Aquarium draw loop starts.  Keep this as an independent witness:
        // a nil event must be diagnosed at creation time instead of being
        // handed to -encodeSignalEvent:value:, where AGX's superclass raises
        // an NSArray nil-insertion exception.
        if (!getenv("MACWS_METAL_PROBE_SOURCE_ONLY")) {
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
            BOOL respondsToNewEvent =
                [device respondsToSelector:newEventSelector];
            id legacyEvent = respondsToNewEvent
                ? ((id (*)(id, SEL))objc_msgSend)(device, newEventSelector)
                : nil;
            fprintf(stderr,
                    "METAL_SOURCE_PROBE newEvent responds=%d event=%p class=%s\n",
                    respondsToNewEvent, legacyEvent,
                    legacyEvent ? object_getClassName(legacyEvent) : "(nil)");

            BOOL sharedEventCommandsOK = NO;
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
                    sharedEventCommandsOK =
                        signalBuffer.status ==
                            MTLCommandBufferStatusCompleted &&
                        waitBuffer.status ==
                            MTLCommandBufferStatusCompleted &&
                        sharedEvent.signaledValue == 1 &&
                        signalBuffer.error == nil && waitBuffer.error == nil;
                } @catch (NSException *exception) {
                    fprintf(stderr,
                            "METAL_SOURCE_PROBE sharedEventCommand exception=%s "
                            "reason=%s\n",
                            exception.name.UTF8String,
                            exception.reason.UTF8String);
                }
            }

        // The iOS-native event ABI witness must not depend on the separate
        // chroot MTLCompilerService experiment below.  In particular, a
        // native iOS process has no reason to request or validate a macOS AIR
        // target.  This opt-in endpoint gives the event probe a strict exit
        // status after both the public shared-event commands and the private
        // -newEvent constructor have been exercised.
            if (getenv("MACWS_METAL_PROBE_EVENT_ONLY")) {
                BOOL eventOnlyOK = legacyEvent != nil &&
                    sharedEventCommandsOK;
                fprintf(stderr,
                        "METAL_SOURCE_PROBE eventOnlyResult=%s\n",
                        eventOnlyOK ? "PASS" : "FAIL");
            // Force ARC to run both event destructors while libmachook's
            // IOKit interposer and stderr are still live.  Returning from
            // main can let process teardown reclaim VM mappings before the
            // external-method result is observable in the probe log.
#if __has_feature(objc_arc)
                legacyEvent = nil;
                sharedEvent = nil;
#else
                [legacyEvent release];
                [sharedEvent release];
#endif
                fprintf(stderr,
                        "METAL_SOURCE_PROBE eventOnlyReleased=YES\n");
                return eventOnlyOK ? 0 : 5;
            }
        }

        // Include a per-process comment so each invocation proves a fresh XPC
        // compilation instead of accepting a persistent source-cache hit.
        // An optional source file lets the same bounded probe replay an exact
        // MSL program captured from a real client (for example ANGLE's YUV
        // conversion shader) without starting Electron or WindowServer.  The
        // compiler and Metal loader still consume the unmodified source after
        // the harmless cache-busting comment; no result is synthesized.
        const char *sourcePath = getenv("MACWS_METAL_PROBE_SOURCE_PATH");
        const char *functionText = getenv("MACWS_METAL_PROBE_FUNCTION");
        NSString *functionName = functionText && functionText[0]
            ? [NSString stringWithUTF8String:functionText]
            : (sourcePath ? @"main0" : @"macws_probe");
        NSString *source = nil;
        if (sourcePath && sourcePath[0]) {
            NSError *readError = nil;
            NSString *captured = [NSString
                stringWithContentsOfFile:[NSString stringWithUTF8String:sourcePath]
                                encoding:NSUTF8StringEncoding
                                   error:&readError];
            fprintf(stderr,
                    "METAL_SOURCE_PROBE sourcePath=%s bytes=%lu readError=%s\n",
                    sourcePath, (unsigned long)captured.length,
                    readError
                        ? readError.localizedDescription.UTF8String : "(nil)");
            if (!captured) return 6;
            if (getenv("MACWS_METAL_PROBE_EXACT_SOURCE")) {
                // Deterministic replay for a source captured at the failing
                // public Metal boundary.  Do not add the ordinary cache-bust
                // comment: its hash and byte length are part of the witness.
                source = captured;
            } else {
                source = [NSString stringWithFormat:
                    @"// macws source probe pid=%d\n%@", getpid(), captured];
            }
        } else {
            source = [NSString stringWithFormat:
                @"// macws source probe pid=%d\n"
                 "#include <metal_stdlib>\n"
                 "using namespace metal;\n"
                 "kernel void macws_probe(device uint *out [[buffer(0)]], "
                 "uint tid [[thread_position_in_grid]]) { out[tid] = tid + 1; }\n",
                 getpid()];
        }
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

        id<MTLFunction> function = [library newFunctionWithName:functionName];
        fprintf(stderr,
                "METAL_SOURCE_PROBE functionName=%s function=%p class=%s\n",
                functionName.UTF8String,
                function,
                function ? object_getClassName(function) : "(nil)");
        return function ? 0 : 4;
    }
}
