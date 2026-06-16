@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
#import <rootless.h>
#import <xpc/xpc.h>
#import "utils.h"

// FORCE_M1_DRIVER auto-enabled for the arm64e on-device slice only (see
// mac_hooks.m). arm64e -> real macOS AGX driver; arm64/x86_64 -> MTLSimDevice.
#if defined(__arm64e__) && defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

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

// MTLFakeDevice creates a new ObjC class.  On arm64e, on-device lld emits a
// plain (non-auth) chained-fixup rebase for class_t->data, but macOS libobjc
// expects an address-diversified autda pointer → EXC_BREAKPOINT (PAC trap DA)
// in readClass during map_images.  Exclude the entire class from arm64e so the
// arm64e slice has no class_t entries, letting the arm64 slice handle Metal.
// On-device builds (misc/build_on_ios.sh) pass -DLIBMACHOOK_ON_DEVICE_BUILD: lld
// uses -fixup_chains there, so arm64e can include this code.
#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
static id(*MTLCreateSimulatorDevice)(void);
@interface MTLFakeDevice : _MTLDevice
@end
@implementation MTLFakeDevice
- (BOOL)initHooks {
    if(%c(MTLSimDevice)) {
        return YES; // Already hooked
    }
    
    void *handle = dlopen("@loader_path/../Frameworks/MetalSerializer.framework/MetalSerializer", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MetalSerializer framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MetalSerializer successfully!");
    }
    
    handle = dlopen("@loader_path/../Frameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_GLOBAL);
    if(!handle) {
        NSLog(@"#### debugbydcmmc Failed to load MTLSimDriver framework: %s", dlerror());
        return NO;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLSimDriver successfully!");
    }
    MTLCreateSimulatorDevice = dlsym(handle, "MTLCreateSimulatorDevice");
    NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    
    Class MTLSimDeviceClass = %c(MTLSimDevice);
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithBytesNoCopy:length:options:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(newBufferWithLength:options:pointer:copyBytes:deallocator:), MTLFakeDevice.class, @selector(hooked_newBufferWithLength:options:pointer:copyBytes:deallocator:));
    swizzle2(MTLSimDeviceClass, @selector(acceleratorPort), MTLFakeDevice.class, @selector(hooked_acceleratorPort));
    swizzle2(MTLSimDeviceClass, @selector(location), MTLFakeDevice.class, @selector(hooked_location));
    swizzle2(MTLSimDeviceClass, @selector(locationNumber), MTLFakeDevice.class, @selector(hooked_locationNumber));
    swizzle2(MTLSimDeviceClass, @selector(maxTransferRate), MTLFakeDevice.class, @selector(hooked_maxTransferRate));
    NSLog(@"#### debugbydcmmc load swizzle2 successfully!");
    
    uint32_t *imp;
    // This check isn't present in iOS 14 simulator, maybe it was added in iOS 15?
    // Patch -[MTLSimTexture initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:] to bypass `IOSurface backed XR10 textures are not supported in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimTexture), @selector(initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0xfb7c] <+144>: bl     0x2e660        ; objc_msgSend$pixelFormat
        // -> MTLSimDriver[0xfb80] <+148>: and    x8, x0, #0xfffffffffffffffc
        // -> MTLSimDriver[0xfb84] <+152>: cmp    x8, #0x228
        // -> MTLSimDriver[0xfb88] <+156>: b.eq   0xfdf8         ; <+780>
        if(imp[i] == 0x927ef408 && imp[i+1] == 0xf108a11f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t[3]), ^{
                imp[i+1] = imp[i+2] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    // Patch -[MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:] to bypass `Linear texture can only be created on buffers with MTLStorageModePrivate in the simulator`
    imp = (uint32_t *)method_getImplementation(class_getInstanceMethod(%c(MTLSimBuffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:)));
    for(int i = 0; i < 50; i++) {
        //    MTLSimDriver[0x85bc] <+84>:  bl     0x2eda0        ; objc_msgSend$storageMode
        // -> MTLSimDriver[0x85c0] <+88>:  cmp    x0, #0x2
        //    MTLSimDriver[0x85c4] <+92>:  b.ne   0x8798         ; <+560>
        if(imp[i] == 0xf100081f) {
            ModifyExecutableRegion(imp, sizeof(uint32_t), ^{
                imp[i] = imp[i+1] = 0xd503201f; // nop
            });
            break;
        }
    }
    
    return YES;
}

- (id)initWithAcceleratorPort:(int)port {
    if(![self initHooks]) {
        return nil;
    }
    if(!MTLCreateSimulatorDevice) {
        NSLog(@"#### debugbydcmmc Failed to find MTLCreateSimulatorDevice: %s", dlerror());
        return nil;
    } else {
        // NSLog(@"#### debugbydcmmc load MTLCreateSimulatorDevice successfully!");
    }
    // Class cls = NSClassFromString(@"MTLSimDevice");
    // NSLog(@"#### debugbydcmmc MTLSimDevice class %@", cls ? @"present" : @"missing");
    self = MTLCreateSimulatorDevice();
    // NSLog(@"#### debugbydcmmc MTLCreateSimulatorDevice done");
    objc_setAssociatedObject(self, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_ASSIGN);
    return self;
}

- (uint32_t)hooked_acceleratorPort {
    uint32_t port = ((NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort))).unsignedIntValue;
    // NSLog(@"#### debugbydcmmc hooked_acceleratorPort %lu", (unsigned long) port);
    return port;
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
    // NSLog(@"#### debugbydcmmc hooked_newBufferWithBytesNoCopy start");
    if(malloc_size(bytes) > 0) {
        // XPC doesn't like malloced buffers since they don't have MAP_SHARED flag, so we mirror it to a shared region here
        vm_address_t mirrored = 0;
        vm_prot_t cur_prot, max_prot;
        kern_return_t ret = vm_remap(mach_task_self(), &mirrored, length, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)bytes, false, &cur_prot, &max_prot, VM_INHERIT_SHARE);
        if(ret != KERN_SUCCESS) {
            NSLog(@"#### debugbydcmmc Failed to mirror memory: %s", mach_error_string(ret));
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
#endif // MTLFakeDevice static class (off for arm64e on-device)

// Forward declarations for AGX init redirect (definitions below the hook).
static void install_agx_init_redirect(Class agx);

%hookf(Class, getMetalPluginClassForService, int service) {
    // MACWS_AGX_NATIVE=1: both slices return the real AGX device class.
    // dlopen the AGXMetal13_3 bundle on demand so its ObjC classes register,
    // then look up AGXG13GFamilyDevice.
    static int agx_once = 0;
    static Class agx_cls = Nil;
    if (getenv("MACWS_AGX_NATIVE")) {
        if (!agx_once) {
            agx_once = 1;
            void *h = dlopen("/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3", RTLD_NOW);
            if (!h) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 FAILED: %s\n", dlerror());
            } else {
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlopen AGXMetal13_3 OK h=%p\n", h);
            }
            agx_cls = objc_getClass("AGXG13GFamilyDevice");
            fprintf(stderr, "#### MACWS_AGX_NATIVE getMetalPluginClassForService: returning class %s = %p\n",
                agx_cls ? class_getName(agx_cls) : "(nil)", (void*)agx_cls);
            if (agx_cls) {
                install_agx_init_redirect(agx_cls);
            }
        }
        return agx_cls;
    }

#ifdef FORCE_M1_DRIVER
    // FORCE_M1_DRIVER on-device default (env unset): Nil = CPU/sim fallback for stability.
    return Nil;
#else
    return MTLFakeDevice.class;
#endif
}

// When Metal asks the plugin class to instantiate a device, it does:
//   id raw = [pluginClass alloc];
//   [raw initWithAcceleratorPort:port];
//
// MTLFakeDevice has -initWithAcceleratorPort:. AGXG13GFamilyDevice does NOT —
// it has -initWithAcceleratorPort:simultaneousInstances: (two-arg). So Metal's
// single-arg dispatch on AGXG13GFamilyDevice falls through to NSObject (no-op),
// leaving AGX-specific ivars (especially the AGX::G13::Device* at offset 0x3a8)
// uninitialized → crashes later in newBufferWithLength: at +132.
//
// We install the single-arg method on AGXG13GFamilyDevice at runtime via
// class_addMethod (Logos %hook can't add a previously-nonexistent method
// reliably) and have it forward to the 2-arg init.
static id agx_initWithAcceleratorPort_impl(id self, SEL _cmd, int port) {
    fprintf(stderr, "#### MACWS_AGX_NATIVE redirecting AGXG13GFamilyDevice init(port=%d) → 2-arg variant\n", port);
    SEL realSel = sel_registerName("initWithAcceleratorPort:simultaneousInstances:");
    typedef id (*RealInit)(id, SEL, int, uint64_t);
    return ((RealInit)objc_msgSend)(self, realSel, port, 1);
}

static void install_agx_init_redirect(Class agx) {
    SEL sel = @selector(initWithAcceleratorPort:);
    BOOL ok = class_addMethod(agx, sel, (IMP)agx_initWithAcceleratorPort_impl, "@@:i");
    fprintf(stderr, "#### MACWS_AGX_NATIVE class_addMethod(AGXG13GFamilyDevice, initWithAcceleratorPort:) = %d\n", (int)ok);

    // No-op methods that crash in chroot because their setup dependencies
    // (timers, mempools, dispatch sources, etc.) require kernel state that
    // wasn't fully initialized. Downstream code may not actually need them.
    // setupDeferred: the dispatch_once block crashes in chroot; the AGXMetal13_3
    // binary cmp/b.hi patches in mac_hooks.m skip its mempool grow calls, but
    // post-grow code still reads uninitialized ivars. As a workaround, no-op
    // the ObjC method entirely — combined with proper init redirect this allows
    // newBuffer/newTexture/newCommandQueue/newCommandBuffer to succeed (probe7
    // stages 1-6+8). Texture/buffer creation reads OTHER ivars set by the 2-arg
    // init, not the deferred mempool ivars.
    // Note: setupDeferred is NOT noop'd here anymore. Texture init reads
    // mempool storage that setupDeferred populates (see crash in
    // AGX::Mempool<...ImageStateEncoderGen6...>::grow when WS creates an
    // IOSurface-backed texture). The alert* methods are still noop'd because
    // their dispatch_source setup fails in chroot but no other code uses them.
    const char *noopMethods[] = {
        "alertCommandBufferActivityStart",
        "alertCommandBufferActivityComplete",
        NULL
    };
    IMP noop = imp_implementationWithBlock(^void(id self) {
        // silently
    });
    for (int i = 0; noopMethods[i]; i++) {
        SEL s = sel_registerName(noopMethods[i]);
        Method m = class_getInstanceMethod(agx, s);
        if (m) {
            method_setImplementation(m, noop);
            fprintf(stderr, "#### MACWS_AGX_NATIVE noop'd %s\n", noopMethods[i]);
        }
    }
}

@interface MTLTextureDescriptorInternal : MTLTextureDescriptor
@end
%hook MTLTextureDescriptorInternal
- (MTLStorageMode)storageMode {
    MTLStorageMode mode = %orig;
    static int callCount = 0;
    if (getenv("MACWS_TEX_TRACE") && callCount < 100) {
        callCount++;
        fprintf(stderr, "#### MTL_TEX storageMode=%d fmt=%lu w=%lu h=%lu usage=%#lx\n",
            (int)mode, (unsigned long)self.pixelFormat,
            (unsigned long)self.width, (unsigned long)self.height,
            (unsigned long)self.usage);
    }
    if(mode == 1) { // MTLStorageModeManaged (macOS only) → Shared on iOS
        self.storageMode = MTLStorageModeShared;
        return MTLStorageModeShared;
    }
    if(mode == 3) { // MTLStorageModeMemoryless (iOS support is narrower than macOS)
                    // → Private. Without this, Memoryless textures cause AGX kernel
                    // to return kIOReturnBadArgument and layers render BLACK.
        self.storageMode = MTLStorageModePrivate;
        return MTLStorageModePrivate;
    }
    return mode;
}
%end

const char *metalSimService = "com.apple.metal.simulator";
xpc_connection_t (*orig_xpc_connection_create_mach_service)(const char * name, dispatch_queue_t targetq, uint64_t flags);
xpc_connection_t hooked_xpc_connection_create_mach_service(const char * name, dispatch_queue_t targetq, uint64_t flags) {
    flags &= ~XPC_CONNECTION_MACH_SERVICE_PRIVILEGED;
    // Log every mach-service connection attempt so we can spot the hiservices /
    // AppKit window-creation flow in chroot. Filter to Terminal process to limit noise.
    if (getenv("MACWS_XPC_DEBUG") || strstr(getprogname() ?: "", "Terminal")) {
        fprintf(stderr, "#### XPC_TRACE mach_service create: '%s' flags=%#llx\n",
            name ?: "(null)", (unsigned long long)flags);
    }
    if(!strncmp(name, metalSimService, strlen(metalSimService))) {
        return xpc_connection_create(metalSimService, 0);
    }
    return orig_xpc_connection_create_mach_service(name, targetq, flags);
}

// Also trace xpc_connection_create (the XPC service / bundle-name style)
xpc_connection_t (*orig_xpc_connection_create)(const char *name, dispatch_queue_t queue);
xpc_connection_t hooked_xpc_connection_create(const char *name, dispatch_queue_t queue) {
    if (name && (getenv("MACWS_XPC_DEBUG") || strstr(getprogname() ?: "", "Terminal"))) {
        fprintf(stderr, "#### XPC_TRACE service create: '%s'\n", name);
    }
    return orig_xpc_connection_create(name, queue);
}

extern int xpc_connection_enable_sim2host_4sim();
%hookf(int, xpc_connection_enable_sim2host_4sim) {
    return 0;
}

// Deferred install of NSXPCSharedListener swizzle.
// AppKit calls +[NSXPCSharedListener endpointForReply:withListenerName:replyErrorCode:]
// to obtain endpoints to ViewBridgeAuxiliary / hiservices. In chroot these XPC services
// can't be spawned (macOS-only frameworks; iOS launchd has no equivalent), so the call
// returns nil and AppKit logs "Connection invalid", skipping window content creation.
//
// We return a process-local NSXPCListener's endpoint so AppKit thinks it got one. The
// in-process listener doesn't actually serve the real protocol, but AppKit's "endpoint
// non-nil" check passes and downstream window creation proceeds.
//
// MUST run AFTER libSystem_initializer (constructor-time NSClassFromString causes
// libSystem PAC traps on arm64e). Install via dispatch_async-after-main-loop.
static IMP gOrigEndpointForReply = NULL;

static id hook_endpointForReply_replacement(Class self, SEL _cmd, id reply,
                                             id listenerName, int *replyErrorCode) {
    // listenerName is an OS_xpc_string (XPC string), not NSString. Extract cstring
    // via the OS_xpc_string instance method instead of NSString's UTF8String.
    const char *name_c = "(nil)";
    if (listenerName) {
        SEL utf8_sel = sel_registerName("UTF8String");
        if ([listenerName respondsToSelector:utf8_sel]) {
            // NSString-style — fine
            name_c = ((const char *(*)(id, SEL))objc_msgSend)(listenerName, utf8_sel);
        } else {
            // Assume xpc_string_t — try xpc_string_get_string_ptr
            extern const char *xpc_string_get_string_ptr(xpc_object_t xstring);
            name_c = xpc_string_get_string_ptr((xpc_object_t)listenerName);
            if (!name_c) name_c = "(xpc-string?)";
        }
    }
    fprintf(stderr, "#### NSXPCSharedListener intercept: listener=%s\n", name_c);

    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    if (!listenerName) {
        if (replyErrorCode) *replyErrorCode = 0;
        return nil;
    }
    NSString *key = [NSString stringWithUTF8String:name_c];
    @synchronized(cache) {
        NSXPCListenerEndpoint *ep = cache[key];
        if (!ep) {
            NSXPCListener *l = [NSXPCListener anonymousListener];
            [l resume];
            ep = l.endpoint;
            cache[key] = ep;
            fprintf(stderr, "#### NSXPCSharedListener: provided in-process endpoint %p for '%s'\n",
                ep, name_c);
        }
        if (replyErrorCode) *replyErrorCode = 0;
        return ep;
    }
}

// Replacement for +[NSXPCSharedListener connectToService:instanceIdentifier:listener:error:].
// Returning YES makes ViewBridge believe the connection is up; it then dereferences
// an expected proxy and crashes in __auxiliaryProxyFor_block_invoke. Returning NO
// makes ViewBridge bail with a graceful failure — auxiliaryProxyFor returns nil,
// NSRemoteView initialize finishes without crashing, AppKit continues to window
// creation (which doesn't strictly need NSRemoteView).
static BOOL hook_connectToService_replacement(Class self, SEL _cmd, id service,
                                                id instanceIdentifier, id listener,
                                                NSError **errorPtr) {
    fprintf(stderr, "#### NSXPCSharedListener connectToService intercepted (graceful fail)\n");
    // Don't set errorPtr; NSError instantiation triggers PAC autda fault in chroot arm64e.
    // Returning NO with *errorPtr untouched should be acceptable for ViewBridge's call site.
    return NO;
}

static void install_nsxpcsharedlistener_swizzle(void) {
    Class shl = objc_getClass("NSXPCSharedListener");
    fprintf(stderr, "#### NSXPCSharedListener class=%p\n", shl);
    if (!shl) return;
    SEL sel = sel_registerName("endpointForReply:withListenerName:replyErrorCode:");
    Method m = class_getClassMethod(shl, sel);
    if (m) {
        gOrigEndpointForReply = method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_endpointForReply_replacement);
        fprintf(stderr, "#### NSXPCSharedListener endpointForReply swizzle installed\n");
    }
    // Also swizzle connectToService:instanceIdentifier:listener:error: to silently succeed.
    SEL sel2 = sel_registerName("connectToService:instanceIdentifier:listener:error:");
    Method m2 = class_getClassMethod(shl, sel2);
    if (m2) {
        method_setImplementation(m2, (IMP)hook_connectToService_replacement);
        fprintf(stderr, "#### NSXPCSharedListener connectToService swizzle installed\n");
    }
}

__attribute__((constructor)) static void InitMetalHooks() {
    // Install plugin-class hook unconditionally — it inspects MACWS_AGX_NATIVE
    // at first invocation and decides whether to return AGXG13GFamilyDevice or Nil.
    MSImageRef sys = MSGetImageByName("/System/Library/Frameworks/Metal.framework/Metal");
    %init(getMetalPluginClassForService = MSFindSymbol(sys, "_getMetalPluginClassForService"));

    // NOTE: we used to short-circuit out of all sim-related init when
    // MACWS_AGX_NATIVE=1, but Metal.framework still needs the EnableSimApple5
    // CFPref + MTLSimDriver registration paths so that fallback codepaths
    // resolve without nil-deref crashes when AGX-native paths exit early.
    // Leave the rest of init running unconditionally; the plugin-class hook
    // alone is enough to route the device choice.

    dispatch_async(dispatch_get_main_queue(), ^{
        // force Apple 5 profile.
        // NOTE: do NOT pass ObjC/CF constant literals (@"..." / @(YES)) here. On the
        // on-device lld arm64e build, the constant CFString's pointer still PAC-faults
        // when CoreFoundation reads it (autda DA trap in CFStringGetCharacterAtIndex
        // via _CFXPreferences withSearchListForIdentifier) -- even with -fixup_chains.
        // Build the strings at runtime (proper isa from the CF allocator) instead.
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, "EnableSimApple5", kCFStringEncodingUTF8);
        CFStringRef app = CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.Metal", kCFStringEncodingUTF8);
        CFPreferencesSetAppValue(key, kCFBooleanTrue, app);
        CFRelease(key);
        CFRelease(app);
    });

    MSImageRef xpc = MSGetImageByName("/usr/lib/system/libxpc.dylib");
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create_mach_service"), hooked_xpc_connection_create_mach_service, (void *)&orig_xpc_connection_create_mach_service);
    MSHookFunction(MSFindSymbol(xpc, "_xpc_connection_create"), hooked_xpc_connection_create, (void *)&orig_xpc_connection_create);

    // Defer NSXPCSharedListener swizzle install until after libSystem is fully up.
    // Constructor-time class lookup PAC-traps on arm64e (autda fault in libobjc class
    // realization). dispatch_async waits until the main runloop is active.
    dispatch_async(dispatch_get_main_queue(), ^{
        // (NOTE: tried calling MTLCreateSystemDefaultDevice here to force Metal load
        // for the black-tab fix — it DEADLOCKED chroot AppKit startup. Revisit via
        // a background queue load or hook on NSWindow display time.)

        install_nsxpcsharedlistener_swizzle();

        // If this is Terminal, force "New Window" via responder chain since AppKit's
        // automatic startup-window-creation depends on hiservices/launchservices which
        // are broken in chroot. Multiple selector attempts (Terminal uses
        // newWindowWithProfile: typically, but newWindow: also responds).
        const char *prog = getprogname();
        if (prog && strstr(prog, "Terminal")) {
            // Schedule slightly after main queue so app's didFinishLaunching has fired.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                fprintf(stderr, "#### Forcing Terminal new-window via sendAction:\n");
                SEL sels[] = {
                    sel_registerName("newWindow:"),
                    sel_registerName("newWindowWithProfile:"),
                    sel_registerName("newTerminal:"),
                    sel_registerName("newTerminalWithDefaultProfile:"),
                };
                Class app_cls = objc_getClass("NSApplication");
                id app = ((id (*)(Class, SEL))objc_msgSend)(app_cls, sel_registerName("sharedApplication"));
                fprintf(stderr, "#### NSApp=%p\n", app);
                if (app) {
                    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
                        BOOL ok = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                            app, sel_registerName("sendAction:to:from:"),
                            sels[i], nil, nil);
                        fprintf(stderr, "####   sendAction %s -> %d\n", sel_getName(sels[i]), ok);
                        if (ok) break;
                    }
                }
            });
        }
    });
    // register MTLSimDriverHost.xpc
    char frameworkPath[PATH_MAX];
    // NSLog(@"#### debugbydcmmc register MTLSimDriverHost.xpc");
    snprintf(frameworkPath, sizeof(frameworkPath), "%s/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc", JBROOT_PATH("/usr/macOS/Frameworks"));
    xpc_add_bundle(frameworkPath, 2);

    // ViewBridgeAuxiliary.xpc & hiservices-xpcservice.xpc are now registered via
    // _xpc_bootstrap_services in mac_hooks.m's libxpc branch — pointing at the
    // FRAMEWORK BINARY paths, which lets xpc auto-discover bundled XPCServices/
    // children. xpc_add_bundle (the .xpc-path variant) didn't actually trigger
    // spawn; _xpc_bootstrap_services does. (Credit: user-suggested fix based on
    // their earlier MTLCompilerService shader recompile issue.)
}
