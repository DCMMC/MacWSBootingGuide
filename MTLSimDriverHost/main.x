@import Darwin;
@import Foundation;
@import Metal;
#include <rootless.h>
#include <xpc/xpc.h>
@import CydiaSubstrate;
#include <mach-o/dyld.h>

// ─── Root-cause stability fix: MTLSimDriverHost appContext race ──────────────
// Under heavy compositing MTLSimDriverHost SIGSEGVs at 0x0 in
// MTLSimApplicationContext::newObjectCommand_DEPRECATED. The lifecycle:
//   * appContext is PER-PROCESS, created/looked-up via
//     MTLSimGlobalContext::getApplicationForProcessRef and held by the global
//     registry. The per-connection context only stores a *pointer* to it at
//     [connectionContext+0x10], assigned by the connection's "init" message.
//   * MTLSimulatorHandleEvent xpc_connection_activate()s a new peer connection
//     while [ctx+0x10] is still NULL (it's zeroed at accept).
//   * Under load WindowServer's XPC connection is interrupted
//     (XPC_ERROR_CONNECTION_INTERRUPTED in the WindowServer logs); it reconnects
//     and a newObjectCommand beats the new connection's init message -> `this`
//     (= [ctx+0x10]) is NULL -> `ldr x0,[this]` faults.
//
// The appContext for WindowServer's process is STILL ALIVE in the global registry
// throughout this (the connection-invalid handler frees only the connection's
// pointer, not the registry's shared_ptr). So rather than fail the request, serve
// it with that same per-process appContext: cache the live one from every valid
// call and reuse it when the per-connection pointer is NULL. The request then
// SUCCEEDS with the correct context -> no nil texture is produced -> none of the
// downstream SkyLight nil-texture asserts can fire. Only if nothing has been
// cached yet (no valid call ever) do we fall back to an empty reply (the
// function's own "no object produced" semantics). xpc objects are opaque void* to
// keep ARC out of their +1 create-reply ownership.
static void *(*orig_newObjectCommand_DEPRECATED)(void *thiz, void *xpcMsg);
static void *(*p_xpc_dictionary_create_reply)(void *original);
static void *g_last_appContext = NULL;  // last live per-process appContext (kept alive by the global registry)
static void *hooked_newObjectCommand_DEPRECATED(void *thiz, void *xpcMsg) {
    if (thiz != NULL) {
        g_last_appContext = thiz;
        return orig_newObjectCommand_DEPRECATED(thiz, xpcMsg);
    }
    if (g_last_appContext != NULL) {
        NSLog(@"#### debugbydcmmc appContext race handled: served newObjectCommand with cached per-process appContext %p", g_last_appContext);
        return orig_newObjectCommand_DEPRECATED(g_last_appContext, xpcMsg);
    }
    NSLog(@"#### debugbydcmmc appContext race but NO cache yet -> empty reply");
    return p_xpc_dictionary_create_reply ? p_xpc_dictionary_create_reply(xpcMsg) : NULL;
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

        // Install the NULL-`this` guard before the event loop (init_with_xpc_connection)
        // starts handling requests. MSFindSymbol resolves the (local) C++ symbol from the
        // just-mapped image; locate it by walking the dyld image list (the recorded path is
        // canonicalised, so match by suffix rather than the dlopen path).
        const struct mach_header *simHdr = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm && strstr(nm, "MTLSimImplementation.framework/MTLSimImplementation")) {
                simHdr = _dyld_get_image_header(i);
                break;
            }
        }
        p_xpc_dictionary_create_reply = dlsym(RTLD_DEFAULT, "xpc_dictionary_create_reply");
        void *newObjCmd = simHdr ? MSFindSymbol((MSImageRef)simHdr,
            "__ZN24MTLSimApplicationContext27newObjectCommand_DEPRECATEDEPU24objcproto13OS_xpc_object8NSObject") : NULL;
        if (newObjCmd && p_xpc_dictionary_create_reply) {
            MSHookFunction(newObjCmd, (void *)hooked_newObjectCommand_DEPRECATED,
                           (void **)&orig_newObjectCommand_DEPRECATED);
            NSLog(@"#### debugbydcmmc installed NULL-this guard on newObjectCommand_DEPRECATED @ %p", newObjCmd);
        } else {
            NSLog(@"#### debugbydcmmc FAILED to install newObjectCommand_DEPRECATED guard (sym=%p reply=%p)", newObjCmd, p_xpc_dictionary_create_reply);
        }

        void (*init_with_xpc_connection)(xpc_connection_t, uint64_t, uint64_t) = dlsym(handle, "init_with_xpc_connection");
        // NSLog(@"#### debugbydcmmc MTLSimDriverHost.xpc main before init_with_xpc_connection");
        init_with_xpc_connection(peerConnection, MTLCreateSystemDefaultDevice().registryID, 0LL);
        // NSLog(@"#### debugbydcmmc MTLSimDriverHost.xpc main after init_with_xpc_connection");
    });
    dispatch_main();
}
