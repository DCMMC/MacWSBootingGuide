@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
#import <mach-o/dyld.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <rootless.h>
#import <xpc/xpc.h>
#import "utils.h"

// #define FORCE_M1_DRIVER

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

// MTLFakeDevice is objc_allocateClassPair + class_addMethod (no @implementation)
// so the dylib has no static class_t for it — avoids arm64e PAC traps from on-device
// lld without -Wl,-fixup_chains.

static id (*MTLCreateSimulatorDevice)(void);
static Class gMTLFakeDeviceClass;

static Class MTLFakeDeviceCls(void) {
    return gMTLFakeDeviceClass;
}

static BOOL MTLFD_initHooks(id self, SEL _cmd) {
    if(%c(MTLSimDevice)) {
        return YES; // Already hooked
    }

    void *handle = dlopen("@loader_path/../Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MetalSerializer framework: %s", dlerror());
        return NO;
    }

    handle = dlopen("@loader_path/../Frameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MTLSimDriver framework: %s", dlerror());
        return NO;
    }
    MTLCreateSimulatorDevice = dlsym(handle, "MTLCreateSimulatorDevice");
    NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");

    Class MTLSimDeviceClass = %c(MTLSimDevice);
    Class fakeCls = MTLFakeDeviceCls();
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), fakeCls, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithLength:options:pointer:copyBytes:deallocator:), fakeCls, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(acceleratorPort), fakeCls, @selector(hooked_acceleratorPort));
    swizzle2(MTLSimDeviceClass, @selector(location), fakeCls, @selector(hooked_location));
    swizzle2(MTLSimDeviceClass, @selector(locationNumber), fakeCls, @selector(hooked_locationNumber));
    swizzle2(MTLSimDeviceClass, @selector(maxTransferRate), fakeCls, @selector(hooked_maxTransferRate));
    NSLog(@"#### debugbydcmmc load swizzle2 successfully!");

    uint32_t *imp;
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimTexture), @selector(initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:)));
    for(int i = 0; i < 50; i++) {
        if(imp[i] == 0x927ef408 && imp[i+1] == 0xf108a11f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t[3]), ^{
                imp[i+1] = imp[i+2] = 0xd503201f; // nop
            });
            break;
        }
    }

    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimBuffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:)));
    for(int i = 0; i < 50; i++) {
        if(imp[i] == 0xf100081f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t), ^{
                imp[i] = imp[i+1] = 0xd503201f; // nop
            });
            break;
        }
    }

    return YES;
}

static id MTLFD_initWithAcceleratorPort(id self, SEL _cmd, int port) {
    if(!((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(initHooks))) {
        return nil;
    }
    if(!MTLCreateSimulatorDevice) {
        NSLog(@"#### debugbydcmmc Failed to find MTLCreateSimulatorDevice: %s", dlerror());
        return nil;
    }
    id sim = MTLCreateSimulatorDevice();
    objc_setAssociatedObject(sim, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_ASSIGN);
    return sim;
}

static uint32_t MTLFD_hooked_acceleratorPort(id self, SEL _cmd) {
    return ((NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort))).unsignedIntValue;
}

static NSUInteger MTLFD_hooked_location(id self, SEL _cmd) {
    return 0;
}

static NSUInteger MTLFD_hooked_locationNumber(id self, SEL _cmd) {
    return 0;
}

static NSUInteger MTLFD_hooked_maxTransferRate(id self, SEL _cmd) {
    return 0;
}

static id MTLFD_hooked_newBufferWithBytesNoCopy(id self, SEL _cmd, void *bytes, NSUInteger length, MTLResourceOptions options, void (^deallocator)(void *pointer, NSUInteger length)) {
    SEL hookedSel = @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:);
    typedef id (*Msg5)(id, SEL, void *, NSUInteger, MTLResourceOptions, id);
    Msg5 sendHooked = (Msg5)objc_msgSend;

    if(malloc_size(bytes) > 0) {
        vm_address_t mirrored = 0;
        vm_prot_t cur_prot, max_prot;
        kern_return_t ret = vm_remap(mach_task_self(), &mirrored, length, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)bytes, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
        if(ret != KERN_SUCCESS) {
            NSLog(@"#### debugbydcmmc Failed to mirror memory: %s", mach_error_string(ret));
            return nil;
        }
        vm_protect(mach_task_self(), mirrored, length, NO, VM_PROT_READ | VM_PROT_WRITE);

        void (^outerDealloc)(void *, NSUInteger) = ^(void *pointer, NSUInteger len) {
            vm_deallocate(mach_task_self(), (vm_address_t)pointer, len);
            if(deallocator) deallocator(bytes, length);
        };
        return sendHooked(self, hookedSel, (void *)mirrored, length, options, outerDealloc);
    }
    return sendHooked(self, hookedSel, bytes, length, options, deallocator);
}

static id MTLFD_hooked_newBufferWithLength(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options, void *pointer, BOOL copyBytes, void (^deallocator)(void *pointer, NSUInteger length)) {
    if(options & (1 << MTLResourceStorageModeShift)) {
        options &= ~(1 << MTLResourceStorageModeShift);
        options |= MTLResourceStorageModeShared;
    }
    typedef id (*Msg6)(id, SEL, NSUInteger, MTLResourceOptions, void *, BOOL, id);
    return ((Msg6)objc_msgSend)(self, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:), length, options, pointer, copyBytes, deallocator);
}

static pthread_mutex_t gMTLFakeRegLock = PTHREAD_MUTEX_INITIALIZER;

static void MTLFakeDeviceRegister(void) {
    if(gMTLFakeDeviceClass) {
        return;
    }
    pthread_mutex_lock(&gMTLFakeRegLock);
    if(gMTLFakeDeviceClass) {
        pthread_mutex_unlock(&gMTLFakeRegLock);
        return;
    }
    Class existing = objc_getClass("MTLFakeDevice");
    if(existing) {
        gMTLFakeDeviceClass = existing;
        pthread_mutex_unlock(&gMTLFakeRegLock);
        return;
    }
    Class superCls = objc_getClass("_MTLDevice");
    if(!superCls) {
        pthread_mutex_unlock(&gMTLFakeRegLock);
        return;
    }
    Class cls = objc_allocateClassPair(superCls, "MTLFakeDevice", 0);
    if(!cls) {
        NSLog(@"#### debugbydcmmc MTLFakeDevice: objc_allocateClassPair failed");
        pthread_mutex_unlock(&gMTLFakeRegLock);
        return;
    }
    class_addMethod(cls, @selector(initHooks), (IMP)MTLFD_initHooks, "B16@0:8");
    class_addMethod(cls, @selector(initWithAcceleratorPort:), (IMP)MTLFD_initWithAcceleratorPort, "@20@0:8i16");
    class_addMethod(cls, @selector(hooked_acceleratorPort), (IMP)MTLFD_hooked_acceleratorPort, "I16@0:8");
    class_addMethod(cls, @selector(hooked_location), (IMP)MTLFD_hooked_location, "Q16@0:8");
    class_addMethod(cls, @selector(hooked_locationNumber), (IMP)MTLFD_hooked_locationNumber, "Q16@0:8");
    class_addMethod(cls, @selector(hooked_maxTransferRate), (IMP)MTLFD_hooked_maxTransferRate, "Q16@0:8");
    class_addMethod(cls, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)MTLFD_hooked_newBufferWithBytesNoCopy, "@48@0:8^v16Q24Q32@?40");
    class_addMethod(cls, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:), (IMP)MTLFD_hooked_newBufferWithLength, "@52@0:8Q16Q24^v32B40@?44");
    objc_registerClassPair(cls);
    gMTLFakeDeviceClass = cls;
    pthread_mutex_unlock(&gMTLFakeRegLock);
}

// Bash and other non-Metal processes do not have Metal.framework mapped at
// libmachook constructor time; MSFindSymbol(NULL, ...) traps.  Install this
// hook only once Metal is present (or already loaded), via dyld add_image.
static pthread_mutex_t gMetalPluginHookLock = PTHREAD_MUTEX_INITIALIZER;
static bool gMetalPluginHookInstalled = false;

// MSGetImageByName("/.../Metal.framework/Metal") often fails: dyld records the real path
// (.../Metal.framework/Versions/A/Metal).  Then the hook is never installed and WindowServer
// falls through to AGXMetal13_3 bundle lookup.
static MSImageRef MSImageForMetalFramework(void) {
    MSImageRef ref = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Metal");
    if(ref) {
        return ref;
    }
    ref = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Versions/A/Metal");
    if(ref) {
        return ref;
    }
    int n = _dyld_image_count();
    for(int i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if(!name) {
            continue;
        }
        if(strstr(name, "/Metal.framework/") == NULL) {
            continue;
        }
        if(strstr(name, "MTLCompiler") || strstr(name, "MetalPerformanceShaders") || strstr(name, "MetalTools")) {
            continue;
        }
        const char *slash = strrchr(name, '/');
        if(slash && strcmp(slash + 1, "Metal") == 0) {
            return (MSImageRef)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static Class hooked_getMetalPluginClassForService(int service) {
    MTLFakeDeviceRegister();
#ifdef FORCE_M1_DRIVER
    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/Extensions/AGXMetal13_3.bundle"];
    [bundle load];
    return %c(AGXG13GDevice);
#else
    return gMTLFakeDeviceClass;
#endif
}

static void tryInstallMetalPluginClassHook(void) {
    if(gMetalPluginHookInstalled) {
        return;
    }
    pthread_mutex_lock(&gMetalPluginHookLock);
    if(gMetalPluginHookInstalled) {
        pthread_mutex_unlock(&gMetalPluginHookLock);
        return;
    }
    MSImageRef sys = MSImageForMetalFramework();
    if(!sys) {
        pthread_mutex_unlock(&gMetalPluginHookLock);
        return;
    }
    void *sym = MSFindSymbol(sys, "_getMetalPluginClassForService");
    if(!sym) {
        sym = MSFindSymbol(sys, "getMetalPluginClassForService");
    }
    if(!sym) {
        pthread_mutex_unlock(&gMetalPluginHookLock);
        return;
    }
    MTLFakeDeviceRegister();
    if(!gMTLFakeDeviceClass) {
        NSLog(@"#### debugbydcmmc getMetalPluginClassForService hook: MTLFakeDevice not registered (_MTLDevice missing?)");
        pthread_mutex_unlock(&gMetalPluginHookLock);
        return;
    }
    MSHookFunction(sym, (void *)hooked_getMetalPluginClassForService, NULL);
    gMetalPluginHookInstalled = true;
    pthread_mutex_unlock(&gMetalPluginHookLock);
}

static void metalPluginImageCallback(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if(dladdr((const void *)mh, &info) && info.dli_fname && strstr(info.dli_fname, "/Metal.framework/")) {
        tryInstallMetalPluginClassHook();
        // _MTLDevice may not be visible until after ObjC +load; retry once on the main queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            tryInstallMetalPluginClassHook();
        });
    }
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
    // NSLog(@"#### debugbydcmmc hooked_xpc_connection_create_mach_service %s", name);
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
    
    tryInstallMetalPluginClassHook();
    _dyld_register_func_for_add_image(metalPluginImageCallback);

    MSImageRef xpc = MSGetImageByName("/usr/lib/system/libxpc.dylib");
    if(xpc) {
        void *xpcSym = MSFindSymbol(xpc, "_xpc_connection_create_mach_service");
        if(xpcSym) {
            MSHookFunction(xpcSym, hooked_xpc_connection_create_mach_service, (void *)&orig_xpc_connection_create_mach_service);
        }
    }
    // register MTLSimDriverHost.xpc
    char frameworkPath[PATH_MAX];
    // NSLog(@"#### debugbydcmmc register MTLSimDriverHost.xpc");
    snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc", JBROOT_PATH("/usr/macOS/Frameworks"));
    xpc_add_bundle(frameworkPath, 2);
}
