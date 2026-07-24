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
#import <stdint.h>
#import <stdio.h>

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
        return implementation ? 0 : 3;
    }
}
