@import Darwin;
@import Foundation;
@import Metal;
#include <rootless.h>

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

// decompiled from MTLSimDriverHost.xpc with some modifications
xpc_connection_t xpc_connection_create_listener(const char* name, dispatch_queue_t queue);
xpc_connection_t xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq, uint64_t flags);
int main(int argc, const char **argv, const char **envp) {
    xpc_object_t (*xpc_connection_create_mach_service)(const char *name, dispatch_queue_t targetq, uint64_t flags) = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    xpc_connection_t peerConnection = xpc_connection_create_mach_service("com.apple.metal.simulator", dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    // NSLog(@"#### debugbydcmmc MTLSimDriverHost.xpc main before dispatch_async");
    dispatch_async(dispatch_get_main_queue(), ^{
        char frameworkPath[PATH_MAX];
        void *debug_handle = dlopen("/var/mnt/rootfs/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
        NSCAssert(debug_handle, @"Failed to load MetalSerializer framework: %s", dlerror());
        snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimImplementation.framework/MTLSimImplementation", JBROOT_PATH("/usr/macOS/Frameworks"));
        void *handle = dlopen(frameworkPath, RTLD_GLOBAL);
        NSCAssert(handle, @"Failed to load MTLSimImplementation framework: %s", dlerror());
        void (*init_with_xpc_connection)(xpc_connection_t, uint64_t, uint64_t) = dlsym(handle, "init_with_xpc_connection");
        // NSLog(@"#### debugbydcmmc MTLSimDriverHost.xpc main before init_with_xpc_connection");
        init_with_xpc_connection(peerConnection, MTLCreateSystemDefaultDevice().registryID, 0LL);
        // NSLog(@"#### debugbydcmmc MTLSimDriverHost.xpc main after init_with_xpc_connection");
    });
    dispatch_main();
}
