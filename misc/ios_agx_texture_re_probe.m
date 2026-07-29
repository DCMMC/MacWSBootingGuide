// Native-iOS, read-only AGX texture reverse-engineering locator.
//
// Creating the default Metal device loads the exact iOS AGXMetal13_3 bundle.
// The probe then asks the Objective-C runtime for the implementation address of
// the texture initImpl method.  It does not allocate a resource, create a
// command queue, or submit GPU work.

@import Foundation;
@import Metal;

#import <dlfcn.h>
#import <objc/runtime.h>
#import <ptrauth.h>
#import <signal.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "IOS-AGX-TEXTURE-RE device=%p class=%s\n",
            (void *)device, device ? object_getClassName(device) : "(nil)");
        if (!device) return 2;

        Class textureClass = objc_getClass("AGXG13GFamilyTexture");
        SEL selector = sel_registerName(
            "initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:"
            "allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:");
        Method method = textureClass
            ? class_getInstanceMethod(textureClass, selector) : NULL;
        IMP implementation = method ? method_getImplementation(method) : NULL;
        IMP strippedImplementation = implementation
            ? ptrauth_strip(implementation, ptrauth_key_function_pointer)
            : NULL;
        Dl_info image = {0};
        if (strippedImplementation) {
            dladdr((const void *)strippedImplementation, &image);
        }

        fprintf(stderr,
            "IOS-AGX-TEXTURE-RE class=%p method=%p imp=%p stripped=%p "
            "image=%s base=%p offset=%#llx\n",
            (void *)textureClass, (void *)method, (void *)implementation,
            (void *)strippedImplementation,
            image.dli_fname ?: "(nil)", image.dli_fbase,
            (unsigned long long)(strippedImplementation && image.dli_fbase
                ? (uintptr_t)strippedImplementation - (uintptr_t)image.dli_fbase
                : 0));

        // Opt-in runtime ABI witness for the Chromium failure captured on
        // 2026-07-30.  The default invocation above remains read-only.  With
        // MACWS_IOS_MIP_TEXTURE_PROBE=1, create the exact small mipmapped
        // shape that made macOS AGXMetal13_3 request a parent type-0x80
        // resource.  MACWS_IOS_MIP_TEXTURE_HOLD=1 stops after the native
        // device is ready so the project's LLDB resource-return tracer can
        // be installed before any texture resource is created.
        if (getenv("MACWS_IOS_MIP_TEXTURE_PROBE")) {
            if (getenv("MACWS_IOS_MIP_TEXTURE_HOLD")) {
                fprintf(stderr,
                    "IOS-AGX-TEXTURE-RE mip hold pid=%d before texture\n",
                    getpid());
                raise(SIGSTOP);
            }
            MTLTextureDescriptor *descriptor =
                [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                    width:6
                    height:1
                    mipmapped:YES];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageShaderRead |
                MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
            fprintf(stderr,
                "IOS-AGX-TEXTURE-RE mip create size=%lux%lu pf=%lu "
                "mips=%lu storage=%lu usage=%#lx\n",
                (unsigned long)descriptor.width,
                (unsigned long)descriptor.height,
                (unsigned long)descriptor.pixelFormat,
                (unsigned long)descriptor.mipmapLevelCount,
                (unsigned long)descriptor.storageMode,
                (unsigned long)descriptor.usage);
            id<MTLTexture> texture =
                [device newTextureWithDescriptor:descriptor];
            fprintf(stderr,
                "IOS-AGX-TEXTURE-RE mip result=%p class=%s\n",
                (void *)texture,
                texture ? object_getClassName(texture) : "(nil)");
            if (!texture) return 4;
        }
        return implementation ? 0 : 3;
    }
}
