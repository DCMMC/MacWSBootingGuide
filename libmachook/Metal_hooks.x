@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
#include <rootless.h>

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    if(class_getInstanceMethod(class, originalAction) == NULL) {
        class_addMethod(class, originalAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
        method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
    }
}

@interface _MTLDevice : NSObject
- (uint32_t)acceleratorPort;
@end

@implementation _MTLDevice(MetalXPC)
- (void)_setAcceleratorService:(id)arg1 {}

- (uint32_t)peerGroupID {
    return self.acceleratorPort;
}
@end

@interface MTLFakeDevice : _MTLDevice
@end
@implementation MTLFakeDevice
- (id)initWithAcceleratorPort:(int)port {
    void *handle = dlopen("@loader_path/../Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"Failed to load MetalSerializer framework: %s", dlerror());
        return nil;
    }
    
    handle = dlopen("@loader_path/../Frameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"Failed to load MTLSimDriver framework: %s", dlerror());
        return nil;
    }
    
    Class MTLSimDeviceClass = %c(MTLSimDevice);
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithLength:options:pointer:copyBytes:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(acceleratorPort), MTLFakeDevice.class, @selector(hooked_acceleratorPort));
    swizzle2(MTLSimDeviceClass, @selector(location), MTLFakeDevice.class, @selector(hooked_location));
    swizzle2(MTLSimDeviceClass, @selector(locationNumber), MTLFakeDevice.class, @selector(hooked_locationNumber));
    swizzle2(MTLSimDeviceClass, @selector(maxTransferRate), MTLFakeDevice.class, @selector(hooked_maxTransferRate));
    
    id(*MTLCreateSimulatorDevice)(void) = dlsym(handle, "MTLCreateSimulatorDevice");
    self = MTLCreateSimulatorDevice();
    objc_setAssociatedObject(self, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_ASSIGN);
    return self;
}

- (uint32_t)hooked_acceleratorPort {
    return ((NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort))).unsignedIntValue;
}

- (NSUInteger)hooked_location {
    return 0; // MTLDeviceLocationBuiltIn
}

- (NSUInteger)hooked_locationNumber {
    return 0;
}

- (NSUInteger)hooked_maxTransferRate {
    return 0; // The maximum transfer rate for built-in GPUs is 0.
}

- (id<MTLBuffer>)hooked_newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void * pointer, NSUInteger length)) deallocator {
    if(malloc_size(bytes) > 0) {
        // XPC doesn't like malloced buffers since they don't have MAP_SHARED flag, so we mirror it to a shared region here
        vm_address_t mirrored = 0;
        vm_prot_t cur_prot, max_prot;
        kern_return_t ret = vm_remap(mach_task_self(), &mirrored, length, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)bytes, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
        if(ret != KERN_SUCCESS) {
            NSLog(@"Failed to mirror memory: %s", mach_error_string(ret));
            return nil;
        }
        vm_protect(mach_task_self(), mirrored, length, NO,
                VM_PROT_READ | VM_PROT_WRITE);
        
        return [self hooked_newBufferWithBytesNoCopy:(void *)mirrored length:length options:options deallocator:^(void * _Nonnull pointer, NSUInteger length) {
            vm_deallocate(mach_task_self(), (vm_address_t)pointer, length);
            if(deallocator) deallocator(bytes, length);
        }];
    } else {
        return [self hooked_newBufferWithBytesNoCopy:bytes length:length options:options deallocator:deallocator];
    }
}

- (id<MTLBuffer>)hooked_newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options pointer:(void *)pointer copyBytes:(BOOL)copyBytes deallocator:(void (^)(void * pointer, NSUInteger length))deallocator {
    // Handle MTLResourceStorageModeManaged
    if(options & (1 << MTLResourceStorageModeShift)) {
        options &= ~(1 << MTLResourceStorageModeShift);
        options |= MTLResourceStorageModeShared;
    }
    return [self hooked_newBufferWithLength:length options:options pointer:pointer copyBytes:copyBytes deallocator:deallocator];
}
@end
%hookf(Class, getMetalPluginClassForService, int service) {
#ifdef FORCE_M1_DRIVER
    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/Extensions/AGXMetal13_3.bundle"];
    [bundle load];
    return %c(AGXG13GDevice);
#else
    return MTLFakeDevice.class;
#endif
}

@interface MTLTextureDescriptorInternal : MTLTextureDescriptor
@end
%hook MTLTextureDescriptorInternal
- (MTLStorageMode)storageMode {
    MTLStorageMode mode = %orig;
    if(mode == 1) { // MTLStorageModeManaged
        self.storageMode = MTLStorageModeShared;
        return MTLStorageModeShared;
    }
    return mode;
}
%end

const char *metalSimService = "com.apple.metal.simulator";
xpc_connection_t (*orig_xpc_connection_create_mach_service)(const char * name, dispatch_queue_t targetq, uint64_t flags);
xpc_connection_t hooked_xpc_connection_create_mach_service(const char * name, dispatch_queue_t targetq, uint64_t flags) {
    flags &= ~XPC_CONNECTION_MACH_SERVICE_PRIVILEGED;
    if(!strncmp(name, metalSimService, strlen(metalSimService))) {
        return xpc_connection_create(metalSimService, 0);
    }
    return orig_xpc_connection_create_mach_service(name, targetq, flags);
}

extern int xpc_connection_enable_sim2host_4sim();
%hookf(int, xpc_connection_enable_sim2host_4sim) {
    return 0;
}

__attribute__((constructor)) static void InitMetalHooks() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // force Apple 5 profile
        CFPreferencesSetAppValue((const CFStringRef)@"EnableSimApple5", (__bridge CFPropertyListRef)@(YES), (const CFStringRef)@"com.apple.Metal");
    });
    
    MSImageRef sys = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Metal");
    %init(getMetalPluginClassForService = MSFindSymbol(sys, "_getMetalPluginClassForService"));
    
    MSImageRef xpc = MSGetImageByName("/usr/lib/system/libxpc.dylib");
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create_mach_service"), hooked_xpc_connection_create_mach_service, (void *)&orig_xpc_connection_create_mach_service);
    // register MTLSimDriverHost.xpc
    char frameworkPath[PATH_MAX];
    snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimDriver.framework/MTLSimDriver", JBROOT_PATH("/usr/macOS/Frameworks"));
    xpc_object_t dict0 = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(dict0, frameworkPath, 2);
    int(*_xpc_bootstrap_services)(xpc_object_t) = MSFindSymbol(xpc, "__xpc_bootstrap_services");
    _xpc_bootstrap_services(dict0);
}
