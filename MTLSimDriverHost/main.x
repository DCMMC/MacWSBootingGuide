@import Darwin;
@import Foundation;
@import Metal;
#include <rootless.h>
#include <xpc/xpc.h>
@import CydiaSubstrate;
#include <mach-o/dyld.h>
#include <pthread.h>

// ─── Root-cause stability fix: MTLSimDriverHost appContext race (multi-handler) ───
//
// MTLSimApplicationContext per-connection `this` ([conn_ctx+0x10]) is NULL during
// a race window between xpc_connection_activate and the connection's init message.
// Under heavy compositing (Firefox loads ~50 GPU contexts per second), the race
// fires constantly. Each XPC verb handler dereferences `this` directly and faults
// at 0x0.
//
// We observed this fault in TWO handlers so far:
//   * newObjectCommand_DEPRECATED  → MTLSimImplementation+0x27bc  (offset confirmed)
//   * deleteObject                  → MTLSimImplementation+0x29ec  (the new crash)
//
// But MTLSimApplicationContext has 15+ XPC handlers (newBufferWithLength,
// submitCommandBuffer, newCommandQueueWithDescriptor, newSharedEventHandle, etc.)
// — ANY of them can race. Rather than guard one at a time, we install a UNIFIED
// guard on every public handler.
//
// Strategy: hook each handler with a small trampoline that swaps `thiz` for the
// last-known-good per-process appContext if it's NULL. We cache the live one
// from EVERY successful call, so as soon as any handler has been called once
// successfully the cache is warm.
//
// All handlers share the prototype `void* fn(void *thiz, void *xpcMsg)` (with
// xpcMsg sometimes being a block or a listener for the few non-XPC variants —
// these still don't dereference xpcMsg until after `this` is consulted, so the
// guard remains correct: if we serve the cached `this`, the original function
// continues normally).
//
// xpc reply objects are opaque void* in our code to keep ARC out of their +1
// create-reply ownership.

static void *(*p_xpc_dictionary_create_reply)(void *original);
static void *g_last_appContext = NULL;
static pthread_rwlock_t g_ctx_lock = PTHREAD_RWLOCK_INITIALIZER;

static inline void cache_ctx(void *thiz) {
    if (thiz == NULL) return;
    pthread_rwlock_wrlock(&g_ctx_lock);
    g_last_appContext = thiz;
    pthread_rwlock_unlock(&g_ctx_lock);
}

static inline void *peek_ctx(void) {
    pthread_rwlock_rdlock(&g_ctx_lock);
    void *v = g_last_appContext;
    pthread_rwlock_unlock(&g_ctx_lock);
    return v;
}

// One trampoline-factory macro: declares `orig_<name>`, `hooked_<name>`, and a
// constant `OFF_<name>` for the file offset. Each hook reuses the cached
// per-process appContext when its `thiz` is NULL.
//
// We keep a counter and rate-limited log per handler to avoid drowning the log
// when the race fires hundreds of times per second.
#define GUARD_HANDLER(NAME, MANGLED)                                                 \
    static const char OFF_##NAME[] = MANGLED;                                        \
    static void *(*orig_##NAME)(void *, void *);                                     \
    static unsigned g_race_count_##NAME = 0;                                         \
    static void *hooked_##NAME(void *thiz, void *xpcMsg) {                           \
        if (__builtin_expect(thiz != NULL, 1)) {                                     \
            cache_ctx(thiz);                                                          \
            return orig_##NAME(thiz, xpcMsg);                                        \
        }                                                                            \
        void *cached = peek_ctx();                                                   \
        if (cached != NULL) {                                                        \
            unsigned n = __atomic_add_fetch(&g_race_count_##NAME, 1, __ATOMIC_RELAXED);\
            if (n <= 5 || (n & 0xFF) == 0) {                                         \
                NSLog(@"#### debugbydcmmc %s race (count=%u) -> serve with cached %p", \
                      #NAME, n, cached);                                             \
            }                                                                        \
            return orig_##NAME(cached, xpcMsg);                                      \
        }                                                                            \
        NSLog(@"#### debugbydcmmc %s race but no cache -> empty reply", #NAME);      \
        return p_xpc_dictionary_create_reply ? p_xpc_dictionary_create_reply(xpcMsg) : NULL; \
    }

// Symbol-offset table — verified against
//   nm -arch arm64 MTLSimImplementation.framework/MTLSimImplementation
// (these are stable as long as the bundled MTLSimImplementation doesn't change).
GUARD_HANDLER(newObjectCommand_DEPRECATED,
              "__ZN24MTLSimApplicationContext27newObjectCommand_DEPRECATEDEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(deleteObject,
              "__ZN24MTLSimApplicationContext12deleteObjectEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newBufferWithLength,
              "__ZN24MTLSimApplicationContext19newBufferWithLengthEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(submitCommandBuffer,
              "__ZN24MTLSimApplicationContext19submitCommandBufferEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newIOSurfaceTexture,
              "__ZN24MTLSimApplicationContext19newIOSurfaceTextureEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newCommandQueueWithDescriptor,
              "__ZN24MTLSimApplicationContext29newCommandQueueWithDescriptorEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newSharedEventHandle,
              "__ZN24MTLSimApplicationContext20newSharedEventHandleEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newSharedEventWithHandle,
              "__ZN24MTLSimApplicationContext24newSharedEventWithHandleEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newSharedEventWithMachPort,
              "__ZN24MTLSimApplicationContext26newSharedEventWithMachPortEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(newFunction,
              "__ZN24MTLSimApplicationContext11newFunctionEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(reportLeaks,
              "__ZN24MTLSimApplicationContext11reportLeaksEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(notificationWithListener,
              "__ZN24MTLSimApplicationContext24notificationWithListenerEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(wait,
              "__ZN24MTLSimApplicationContext4waitEPU24objcproto13OS_xpc_object8NSObject")
GUARD_HANDLER(getBytes,
              "__ZN24MTLSimApplicationContext8getBytesEPU24objcproto13OS_xpc_object8NSObject")

// Install a hook by mangled name. Returns 1 on success, 0 on failure.
static int install_one(MSImageRef simHdr, const char *mangled,
                       void *hook_fn, void **orig_out, const char *short_name) {
    void *sym = MSFindSymbol(simHdr, mangled);
    if (!sym) {
        NSLog(@"#### debugbydcmmc could NOT resolve %s -- skipping", short_name);
        return 0;
    }
    MSHookFunction(sym, hook_fn, orig_out);
    NSLog(@"#### debugbydcmmc installed guard on %s @ %p", short_name, sym);
    return 1;
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

    dispatch_async(dispatch_get_main_queue(), ^{
        char frameworkPath[PATH_MAX];
        void *debug_handle = dlopen("/var/mnt/rootfs/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
        NSCAssert(debug_handle, @"Failed to load MetalSerializer framework: %s", dlerror());
        snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimImplementation.framework/MTLSimImplementation", JBROOT_PATH("/usr/macOS/Frameworks"));
        void *handle = dlopen(frameworkPath, RTLD_GLOBAL);
        NSCAssert(handle, @"Failed to load MTLSimImplementation framework: %s", dlerror());

        // Install NULL-`this` guards before the event loop starts. Locate the loaded
        // MTLSimImplementation image by suffix (the recorded path is canonicalised
        // through /private/preboot).
        const struct mach_header *simHdr = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm && strstr(nm, "MTLSimImplementation.framework/MTLSimImplementation")) {
                simHdr = _dyld_get_image_header(i);
                break;
            }
        }
        p_xpc_dictionary_create_reply = dlsym(RTLD_DEFAULT, "xpc_dictionary_create_reply");
        if (!simHdr || !p_xpc_dictionary_create_reply) {
            NSLog(@"#### debugbydcmmc CRITICAL: could not find MTLSimImplementation header (%p) or xpc_dictionary_create_reply (%p)",
                  simHdr, p_xpc_dictionary_create_reply);
        } else {
#define INSTALL(NAME) install_one((MSImageRef)simHdr, \
    OFF_##NAME, (void *)hooked_##NAME, (void **)&orig_##NAME, #NAME)
            int n = 0;
            n += INSTALL(newObjectCommand_DEPRECATED);
            n += INSTALL(deleteObject);
            n += INSTALL(newBufferWithLength);
            n += INSTALL(submitCommandBuffer);
            n += INSTALL(newIOSurfaceTexture);
            n += INSTALL(newCommandQueueWithDescriptor);
            n += INSTALL(newSharedEventHandle);
            n += INSTALL(newSharedEventWithHandle);
            n += INSTALL(newSharedEventWithMachPort);
            n += INSTALL(newFunction);
            n += INSTALL(reportLeaks);
            n += INSTALL(notificationWithListener);
            n += INSTALL(wait);
            n += INSTALL(getBytes);
            NSLog(@"#### debugbydcmmc installed %d/14 MTLSimApplicationContext guards", n);
#undef INSTALL
        }

        void (*init_with_xpc_connection)(xpc_connection_t, uint64_t, uint64_t) = dlsym(handle, "init_with_xpc_connection");
        init_with_xpc_connection(peerConnection, MTLCreateSystemDefaultDevice().registryID, 0LL);
    });
    dispatch_main();
}
