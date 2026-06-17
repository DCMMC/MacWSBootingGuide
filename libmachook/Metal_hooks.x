@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import Metal;
#import <rootless.h>
#import <xpc/xpc.h>
#import "utils.h"

#import <IOSurface/IOSurfaceRef.h>

extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);

// Process-wide stash of the current IOSurfaceID being wrapped as a texture.
// Was per-thread but the texture init dispatches the kernel call onto a
// worker thread that __thread doesn't reach. Set by
// `hooked_newTextureWithDescriptor:iosurface:plane:` before %orig is
// invoked, cleared after. Read by IOConnectCallMethod_new in mac_hooks.m
// to inject args[+0x30] = IOSurfaceID for sel=0xa type=0x82 — the iOS
// kernel AGX dispatcher requires this for IOSurface-backed textures.
//
// Race risk: WS may have concurrent texture creates from different
// threads. Mitigate by capturing the value just before %orig and restoring
// just after; concurrent creates would see each other's IDs, but in
// practice WS serialises scanout texture creation.
static _Atomic uint32_t s_current_iosurface_id = 0;

__attribute__((visibility("default")))
uint32_t macws_get_current_iosurface_id(void) {
    return s_current_iosurface_id;
}

__attribute__((visibility("default")))
void macws_set_current_iosurface_id(uint32_t id) {
    s_current_iosurface_id = id;
}

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

// ─── Tile-pipeline → render-pipeline substitution ────────────────────────────
// (definition moved into the MTLFakeDevice category below as
// `hooked_newRenderPipelineStateWithTileDescriptor:...`, then runtime-swizzled
// onto MTLSimDevice in initHooks. Logos `%hook MTLSimDevice` doesn't apply
// here because MTLSimDevice has no compile-time interface declaration.)

// MTLSimRenderCommandEncoder forwarding helpers — BlurState issues
// setTileTexture:atIndex:, setTileBuffer:offset:atIndex:,
// setTileBytes:length:atIndex: on the regular render encoder (since the
// substitute pipeline isn't actually a tile pipeline, but BlurState doesn't
// know). Redirect each tile-* selector to its fragment-* equivalent.
// MACWS_BLUR_TRACE=1 dumps every tile-encoder selector forward with the
// actual arguments so we can reconstruct what BlurState is staging into the
// (substitute) fragment slots and align the shader IO accordingly.
static int macws_blur_trace(void) {
    static int v = -1;
    if (v < 0) v = getenv("MACWS_BLUR_TRACE") ? 1 : 0;
    return v;
}
// Associated-object keys for caching the source / destination textures
// captured on the render encoder so dispatchThreadsPerTile can hand them to
// the XPC blur forward.
static const void *MACWS_SRC_TEX_KEY = &MACWS_SRC_TEX_KEY;
static const void *MACWS_DST_TEX_KEY = &MACWS_DST_TEX_KEY;

static void macws_setTileTexture_impl(id self, SEL _cmd, id tex, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger w = 0, h = 0;
        @try { if (tex) { label = [[tex label] UTF8String] ?: "(nolabel)";
                          w = (NSUInteger)[tex width]; h = (NSUInteger)[tex height]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileTexture[%lu] = %p label=%s %lux%lu\n",
                (unsigned long)idx, (void *)tex, label, (unsigned long)w, (unsigned long)h);
    }
    // Cache source texture on the encoder so the dispatchThreadsPerTile→XPC
    // path can recover it.
    if (idx == 0 && tex) {
        objc_setAssociatedObject(self, MACWS_SRC_TEX_KEY, tex, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentTexture:atIndex:"), tex, idx);
}
static void macws_setTileBuffer_impl(id self, SEL _cmd, id buf, NSUInteger off, NSUInteger idx) {
    if (macws_blur_trace()) {
        const char *label = "?";
        NSUInteger len = 0;
        @try { if (buf) { label = [[buf label] UTF8String] ?: "(nolabel)";
                          len = (NSUInteger)[buf length]; } } @catch (NSException *e) {}
        fprintf(stderr, "#### blur-trace setTileBuffer[%lu] = %p label=%s len=%lu off=%lu\n",
                (unsigned long)idx, (void *)buf, label, (unsigned long)len, (unsigned long)off);
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBuffer:offset:atIndex:"), buf, off, idx);
}
static void macws_setTileBytes_impl(id self, SEL _cmd, const void *bytes, NSUInteger len, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileBytes[%lu] len=%lu", (unsigned long)idx, (unsigned long)len);
        const uint8_t *p = (const uint8_t *)bytes;
        size_t dump = len < 64 ? len : 64;
        fprintf(stderr, "  bytes=");
        for (size_t i = 0; i < dump; i++) fprintf(stderr, "%02x", p[i]);
        // Also interpret first 32 bytes as 8 floats (typical uniform layout).
        if (len >= 32) {
            const float *f = (const float *)bytes;
            fprintf(stderr, "\n####   floats=[%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]);
        }
        fprintf(stderr, "\n");
    }
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentBytes:length:atIndex:"), bytes, len, idx);
}
static void macws_setTileSamplerState_impl(id self, SEL _cmd, id sampler, NSUInteger idx) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace setTileSampler[%lu] = %p\n", (unsigned long)idx, (void *)sampler);
    }
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        self, sel_registerName("setFragmentSamplerState:atIndex:"), sampler, idx);
}
// dispatchThreadsPerTile: dispatches the tile shader once per tile in the
// render target. For a regular render encoder we substitute a fullscreen
// triangle draw (3 vertices, MTLPrimitiveTypeTriangle) — the
// downsample_blur_vert_lpf passthrough writes positions covering NDC.
// 3-vertex fullscreen triangle layout (vertex shader fallback when XPC
// blur forward isn't available).
typedef struct {
    float pos[4];
    float tex[4];
    float col[4];
} macws_fs_vtx_t;
static const macws_fs_vtx_t macws_fs_triangle[3] = {
    {{-1.0f, -1.0f, 0.0f, 1.0f}, {0.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{ 3.0f, -1.0f, 0.0f, 1.0f}, {2.0f, 1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
    {{-1.0f,  3.0f, 0.0f, 1.0f}, {0.0f,-1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
};

// XPC blur forward to MTLSimDriverHost (iOS Metal + MPSImageGaussianBlur).
// Cached connection so we don't reconnect every frame.
static xpc_connection_t gBlurXpc = NULL;
static xpc_connection_t macws_blur_xpc(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            fprintf(stderr, "#### blur-xpc: createMach symbol missing\n");
            return;
        }
        gBlurXpc = createMach("com.macwsguide.blur", NULL, 0);
        if (!gBlurXpc) {
            fprintf(stderr, "#### blur-xpc: createMach returned NULL\n");
            return;
        }
        xpc_connection_set_event_handler(gBlurXpc, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(gBlurXpc);
        fprintf(stderr, "#### blur-xpc: opened connection to com.macwsguide.blur\n");
    });
    return gBlurXpc;
}

// Send the source+dest IOSurfaces over to the host, wait synchronously, and
// return YES on a successful blur. The caller then skips drawPrimitives so
// the existing render encoder doesn't overwrite the host's MPS output.
static BOOL macws_blur_forward(IOSurfaceRef src, IOSurfaceRef dst, double sigma) {
    xpc_connection_t conn = macws_blur_xpc();
    if (!conn || !src || !dst) return NO;
    mach_port_t srcPort = IOSurfaceCreateMachPort(src);
    mach_port_t dstPort = IOSurfaceCreateMachPort(dst);
    if (srcPort == MACH_PORT_NULL || dstPort == MACH_PORT_NULL) {
        if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
        if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
        return NO;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "blur");
    xpc_dictionary_set_mach_send(req, "source_port", srcPort);
    xpc_dictionary_set_mach_send(req, "dest_port", dstPort);
    xpc_dictionary_set_double(req, "radius", sigma);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    BOOL ok = NO;
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        const char *r = xpc_dictionary_get_string(reply, "result");
        ok = r && strcmp(r, "ok") == 0;
        if (macws_blur_trace()) {
            fprintf(stderr, "#### blur-xpc reply: %s\n", r ?: "(no result)");
        }
    } else if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-xpc no reply\n");
    }
    if (srcPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), srcPort);
    if (dstPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), dstPort);
    return ok;
}

static void macws_dispatchThreadsPerTile_impl(id self, SEL _cmd, void *sizeArg) {
    if (macws_blur_trace()) {
        fprintf(stderr, "#### blur-trace dispatchThreadsPerTile\n");
    }

    // Try the XPC forward: pick up the source (cached in setTileTexture[0])
    // and destination (cached in newRenderCommandEncoderWithDescriptor hook).
    // MACWS_BLUR_XPC=1 enables — default off so the synchronous reply wait
    // can't hang WS if MTLSimDriverHost doesn't publish the listener.
    id<MTLTexture> srcTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_SRC_TEX_KEY) : nil;
    id<MTLTexture> dstTex = getenv("MACWS_BLUR_XPC") ? objc_getAssociatedObject(self, MACWS_DST_TEX_KEY) : nil;
    if (srcTex && dstTex) {
        IOSurfaceRef srcSurf = NULL, dstSurf = NULL;
        @try { srcSurf = [srcTex iosurface]; } @catch (NSException *e) {}
        @try { dstSurf = [dstTex iosurface]; } @catch (NSException *e) {}
        if (srcSurf && dstSurf) {
            // sigma from setTileBytes[0] is BlurState's tap-count/level — we
            // map that to a fixed sigma for now (8 for the menu-bar feel).
            BOOL ok = macws_blur_forward(srcSurf, dstSurf, 8.0);
            if (ok) {
                if (macws_blur_trace()) {
                    fprintf(stderr, "#### blur-xpc: forward OK — skipping drawPrimitives\n");
                }
                // Host already wrote the destination IOSurface; don't run
                // the local substitute draw which would overwrite it.
                return;
            }
        }
    }

    // Fallback: substitute non-tile draw with QC blur shaders.
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("setVertexBytes:length:atIndex:"),
        (const void *)macws_fs_triangle,
        (NSUInteger)sizeof(macws_fs_triangle),
        (NSUInteger)30);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))objc_msgSend)(
        self, sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
        (NSUInteger)3, (NSUInteger)0, (NSUInteger)3);
}
// setThreadgroupMemoryLength:offset:atIndex: is a tile-encoder API for
// declaring tile-local shared memory. Regular encoders don't need it.
static void macws_setThreadgroupMemoryLength_impl(id self, SEL _cmd, NSUInteger len, NSUInteger off, NSUInteger idx) {
    (void)self; (void)len; (void)off; (void)idx;
    // no-op for non-tile encoder
}
// Swizzle target on MTLSimCommandBuffer: captures the render-pass
// descriptor's color attachment[0] texture and associates it with the
// returned encoder so dispatchThreadsPerTile→XPC can read it back.
static id (*orig_renderCommandEncoderWithDescriptor)(id, SEL, id) = NULL;
static id macws_renderCommandEncoder_capture(id self, SEL _cmd, id passDesc) {
    id encoder = orig_renderCommandEncoderWithDescriptor(self, _cmd, passDesc);
    if (encoder && passDesc) {
        @try {
            id colorAtts = [passDesc valueForKey:@"colorAttachments"];
            id att0 = [colorAtts objectAtIndexedSubscript:0];
            id<MTLTexture> dst = [att0 valueForKey:@"texture"];
            if (dst) {
                objc_setAssociatedObject(encoder, MACWS_DST_TEX_KEY, dst, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (macws_blur_trace()) {
                    NSUInteger w = (NSUInteger)[dst width], h = (NSUInteger)[dst height];
                    const char *lab = [[dst label] UTF8String] ?: "(nolabel)";
                    fprintf(stderr, "#### blur-trace renderCommandEncoder colorAtt[0] = %p label=%s %lux%lu\n",
                            (void *)dst, lab, (unsigned long)w, (unsigned long)h);
                }
            }
        } @catch (NSException *e) {}
    }
    return encoder;
}

__attribute__((constructor)) static void macws_install_tile_encoder_forwards(void) {
    // Defer until MTLSimRenderCommandEncoder class is loaded.
    dispatch_async(dispatch_get_main_queue(), ^{
        Class enc = objc_getClass("MTLSimRenderCommandEncoder");
        if (!enc) {
            fprintf(stderr, "#### tile-encoder forwards: class MTLSimRenderCommandEncoder NOT found\n");
            return;
        }
        class_addMethod(enc, sel_registerName("setTileTexture:atIndex:"),
                        (IMP)macws_setTileTexture_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("setTileBuffer:offset:atIndex:"),
                        (IMP)macws_setTileBuffer_impl, "v@:@QQ");
        class_addMethod(enc, sel_registerName("setTileBytes:length:atIndex:"),
                        (IMP)macws_setTileBytes_impl, "v@:^vQQ");
        class_addMethod(enc, sel_registerName("setTileSamplerState:atIndex:"),
                        (IMP)macws_setTileSamplerState_impl, "v@:@Q");
        class_addMethod(enc, sel_registerName("dispatchThreadsPerTile:"),
                        (IMP)macws_dispatchThreadsPerTile_impl, "v@:^v");
        class_addMethod(enc, sel_registerName("setThreadgroupMemoryLength:offset:atIndex:"),
                        (IMP)macws_setThreadgroupMemoryLength_impl, "v@:QQQ");
        fprintf(stderr, "#### tile-encoder forwards installed on MTLSimRenderCommandEncoder\n");
        fflush(stderr);
        fprintf(stderr, "#### BLUR-DEBUG: about to look for MTLSim command buffer class\n");
        fflush(stderr);

        // Swizzle the MTLSim command-buffer class's
        // renderCommandEncoderWithDescriptor: to capture the render pass's
        // color attachment[0] texture (= the blur destination) so the XPC
        // forward can pass it across. Class name varies across MTLSimDriver
        // builds — try several candidates.
        const char *cb_names[] = {
            "MTLSimCommandBuffer",
            "MTLSimMainCommandBuffer",
            "MTLSimSecondaryCommandBuffer",
            "MTLSimulatorCommandBuffer",
            "MTLToolsCommandBuffer",
            "MTLDebugCommandBuffer",
            "MTLIGAccelCommandBuffer",
            NULL
        };
        Class cb = nil;
        for (int i = 0; cb_names[i]; i++) {
            Class c = objc_getClass(cb_names[i]);
            if (c) {
                cb = c;
                fprintf(stderr, "#### blur: found command-buffer class %s\n", cb_names[i]);
                break;
            }
        }
        if (!cb) {
            // Fall back: enumerate ALL classes, find any whose name has
            // "CommandBuffer" and "Sim" or implements renderCommandEncoder.
            unsigned int n = 0;
            Class *all = objc_copyClassList(&n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = class_getName(all[i]);
                if (!nm) continue;
                if (strstr(nm, "CommandBuffer") && (strstr(nm, "Sim") || strstr(nm, "MTL"))) {
                    Method mm = class_getInstanceMethod(all[i],
                        sel_registerName("renderCommandEncoderWithDescriptor:"));
                    if (mm) {
                        cb = all[i];
                        fprintf(stderr, "#### blur: located command-buffer class %s by scan\n", nm);
                        break;
                    }
                }
            }
            if (all) free(all);
        }
        if (cb) {
            SEL sel = sel_registerName("renderCommandEncoderWithDescriptor:");
            Method m = class_getInstanceMethod(cb, sel);
            if (m) {
                orig_renderCommandEncoderWithDescriptor =
                    (id (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)macws_renderCommandEncoder_capture);
                fprintf(stderr, "#### %s.renderCommandEncoderWithDescriptor swizzled\n",
                        class_getName(cb));
            } else {
                fprintf(stderr, "#### blur: cmd-buffer class %s has NO renderCommandEncoderWithDescriptor\n",
                        class_getName(cb));
            }
        } else {
            fprintf(stderr, "#### blur: no MTLSim command-buffer class found\n");
        }
    });
}

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
    // MACWS_TEX_TRACE=1 enables full IOSurface→Metal texture descriptor logging.
    // Always-installed because the cold/abort path of MTLSimDriver's
    // sendXPCMessageWithReplySync hits abort() with no recovery — we MUST see
    // every descriptor right before the failure to know what to translate.
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:iosurface:plane:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
    swizzle2(MTLSimDeviceClass, @selector(newTextureWithDescriptor:),
             MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
    // Tile-pipeline → render-pipeline substitution: MTLSimDevice's tile-
    // pipeline impl MTLReportFailure-aborts WS. Swizzle to our converter.
    swizzle2(MTLSimDeviceClass,
             @selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:),
             MTLFakeDevice.class,
             @selector(hooked_newRenderPipelineStateWithTileDescriptor:options:reflection:error:));
    fprintf(stderr, "#### MTLSimDevice tile-pipeline → MTLFakeDevice converter swizzled\n");

    // MTLSimDevice has SUBCLASSES (MTLSimGPU13MDevice, MTLSimGPU11Device, ...).
    // If the runtime class is a subclass that overrides our hooked selectors, the
    // base-class swizzle is shadowed and our hook never runs. Enumerate all
    // subclasses and apply the same swizzle to each one that has its own IMP.
    unsigned int numClasses = 0;
    Class *allClasses = objc_copyClassList(&numClasses);
    int subclassPatched = 0;
    for (unsigned int i = 0; i < numClasses; i++) {
        Class c = allClasses[i];
        // Walk superclasses to find MTLSimDevice ancestry
        Class p = c;
        BOOL is_sim_sub = NO;
        while (p && p != MTLSimDeviceClass) {
            p = class_getSuperclass(p);
        }
        if (p != MTLSimDeviceClass || c == MTLSimDeviceClass) continue;
        // Only swizzle if THIS class itself implements the selector (not inherited)
        unsigned int nm = 0;
        Method *methods = class_copyMethodList(c, &nm);
        BOOL has_iosurf = NO;
        BOOL has_plain  = NO;
        SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
        SEL plain_sel  = @selector(newTextureWithDescriptor:);
        for (unsigned int j = 0; j < nm; j++) {
            SEL s = method_getName(methods[j]);
            if (s == iosurf_sel) has_iosurf = YES;
            if (s == plain_sel)  has_plain  = YES;
        }
        if (methods) free(methods);
        if (has_iosurf) {
            swizzle2(c, iosurf_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:iosurface:plane:));
            subclassPatched++;
        }
        if (has_plain) {
            swizzle2(c, plain_sel, MTLFakeDevice.class, @selector(hooked_newTextureWithDescriptor:));
            subclassPatched++;
        }
        fprintf(stderr, "#### MTL_TEX subclass %s iosurf=%d plain=%d\n",
            class_getName(c), has_iosurf, has_plain);
    }
    if (allClasses) free(allClasses);
    fprintf(stderr, "#### MTL_TEX swizzled MTLSimDevice + %d subclass overrides\n", subclassPatched);
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
    // CRITICAL: use OBJC_ASSOCIATION_RETAIN (not ASSIGN). With ASSIGN the
    // autoreleased @(port) NSNumber is deallocated after the autorelease pool
    // drains, leaving a dangling pointer. -[hooked_acceleratorPort] then reads
    // garbage, WS thinks the GPU port is invalid → falls back to software
    // rendering, the SW renderer creates an IOSurface with FourCC '&b38'
    // (0x26623338) that MTLSim cannot wrap, and WS crash-loops in
    // WSCompositeDestinationCreateWithMetalTexture. Same root cause as the
    // upstream README "Unimplemented pixel format of 645346401" bug.
    objc_setAssociatedObject(self, @selector(acceleratorPort), @(port), OBJC_ASSOCIATION_RETAIN);
    fprintf(stderr, "#### MTLFakeDevice initWithAcceleratorPort:%d retained\n", port);
    return self;
}

- (uint32_t)hooked_acceleratorPort {
    NSNumber *n = (NSNumber *)objc_getAssociatedObject(self, @selector(acceleratorPort));
    uint32_t port = n ? [n unsignedIntValue] : 0;
    static int trace_count = 0;
    if (trace_count < 10) {
        fprintf(stderr, "#### MTLFakeDevice acceleratorPort -> %u (NSNumber=%p)\n", port, n);
        trace_count++;
    }
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

// IOSurface-backed texture creation: the SkyLight WSCompositeDestination /
// CAWindowServerDisplay surface path goes through here, and MTLSimDriver's
// sendXPCMessageWithReplySync cold path aborts on XPC reply errors with no
// recovery. Log every descriptor + IOSurface so we can characterize failures
// from the WindowServer.err / oslog stream BEFORE the abort kills the process.
static void macws_log_mtldesc(MTLTextureDescriptor *desc, IOSurfaceRef iosurface,
                              NSUInteger plane, const char *tag) {
    if (!desc) {
        fprintf(stderr, "#### MTL_TEX/%s desc=NIL\n", tag);
        return;
    }
    @try {
        fprintf(stderr, "#### MTL_TEX/%s pfmt=%lu type=%lu w=%lu h=%lu d=%lu mips=%lu arr=%lu samp=%lu storage=%lu cpu=%lu usage=%#lx swiz=%#x cs=%p plane=%lu ios=%p\n",
            tag,
            (unsigned long)desc.pixelFormat,
            (unsigned long)desc.textureType,
            (unsigned long)desc.width,
            (unsigned long)desc.height,
            (unsigned long)desc.depth,
            (unsigned long)desc.mipmapLevelCount,
            (unsigned long)desc.arrayLength,
            (unsigned long)desc.sampleCount,
            (unsigned long)desc.storageMode,
            (unsigned long)desc.cpuCacheMode,
            (unsigned long)desc.usage,
            0u, // swizzle placeholder (Metal 13+ only)
            (void*)0,
            (unsigned long)plane,
            (void*)iosurface);
    } @catch (NSException *e) {
        fprintf(stderr, "#### MTL_TEX/%s exception reading desc: %s\n", tag, [[e description] UTF8String] ?: "?");
    }
    if (iosurface) {
        uint32_t iosfmt = IOSurfaceGetPixelFormat(iosurface);
        char fmtstr[8] = {0};
        for (int i = 0; i < 4; i++) {
            char c = (char)((iosfmt >> (24 - i * 8)) & 0xff);
            fmtstr[i] = (c >= 0x20 && c < 0x7f) ? c : '.';
        }
        size_t npl = IOSurfaceGetPlaneCount(iosurface);
        fprintf(stderr, "####     ios: w=%zu h=%zu bpr=%zu fmt=%#x(%s) elemSz=%zu allocSz=%zu planes=%zu\n",
            IOSurfaceGetWidth(iosurface),
            IOSurfaceGetHeight(iosurface),
            IOSurfaceGetBytesPerRow(iosurface),
            (unsigned)iosfmt, fmtstr,
            IOSurfaceGetElementWidth(iosurface),
            IOSurfaceGetAllocSize(iosurface),
            npl);
        for (size_t p = 0; p < npl && p < 4; p++) {
            fprintf(stderr, "####       plane[%zu]: w=%zu h=%zu bpr=%zu bpe=%zu\n",
                p,
                IOSurfaceGetWidthOfPlane(iosurface, p),
                IOSurfaceGetHeightOfPlane(iosurface, p),
                IOSurfaceGetBytesPerRowOfPlane(iosurface, p),
                IOSurfaceGetBytesPerElementOfPlane(iosurface, p));
        }
        // Dump ALL IOSurface property keys (one-shot — only on NIL traces so we
        // don't flood per-frame). The dict reveals IOSurfacePlaneCompressionType
        // and other Apple-private flags that explain WHY iOS Metal rejects it.
        if (strstr(tag, ".NIL") || strstr(tag, ".IN")) {
            CFDictionaryRef d = (CFDictionaryRef)IOSurfaceCopyAllValues(iosurface);
            if (d) {
                NSDictionary *nd = (__bridge NSDictionary *)d;
                for (id k in [nd allKeys]) {
                    NSString *desc = [nd[k] description];
                    if ([desc length] > 200) desc = [desc substringToIndex:200];
                    fprintf(stderr, "####       prop[%s] = %s\n",
                        [[k description] UTF8String] ?: "?",
                        [desc UTF8String] ?: "?");
                }
                CFRelease(d);
            }
        }
    }
}

// Empirical: macOS SkyLight on iPad asks for MTLPixelFormat=550 wrapping an
// IOSurface with FourCC '&b38' (0x26623338) — Apple-private 40-bit BGRA10_XR-like
// format used for iPad display backbuffers (5.19 bytes/pixel). iOS Metal returns
// nil for unknown private formats, so we translate 550 → public BGRA10_XR (552),
// falling back to sRGB (553), RGB10A2 (90), BGRA8 (80). The first hit wins.
//
// Translation list ordered by closeness to the source layout. Add formats here
// as new IOSurface fourCCs surface in the trace.
static const NSUInteger kMacwsTexFmt550Fallbacks[] = {
    552,  // BGRA10_XR
    553,  // BGRA10_XR_sRGB
    94,   // BGR10A2Unorm (32-bit packed, lossy width)
    90,   // RGB10A2Unorm
    80,   // BGRA8Unorm (degraded SDR)
    81,   // BGRA8Unorm_sRGB
    0
};

// SIGABRT survival scope. MTLSimDriver's sendXPCMessageWithReplySync.cold.1
// calls abort() on any XPC reply error — there is NO return path. We install a
// thread-local SIGABRT handler around the %orig call so abort()-via-pthread_kill
// becomes a recoverable siglongjmp instead of a fatal process exit. Outside the
// protected scope, abort() reverts to the system default.
static __thread sigjmp_buf macws_abort_env;
static __thread int macws_in_protected = 0;
static void macws_sigabrt_trampoline(int sig) {
    if (macws_in_protected) {
        siglongjmp(macws_abort_env, 1);
    }
    // Not in our scope — re-raise with default to give the system its abort.
    signal(SIGABRT, SIG_DFL);
    raise(SIGABRT);
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc
                                        iosurface:(IOSurfaceRef)iosurface
                                            plane:(NSUInteger)plane {
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.IN");
    }
    static int classlog = 0;
    if (classlog < 3) {
        fprintf(stderr, "#### MTL_TEX entry self class=%s\n", class_getName([self class]));
        classlog++;
    }
    // AGX gate probe: log the EXACT values the 3 entry-gate IOSurface APIs
    // return for THIS surface. If our prediction is right (compType=0,
    // heightInCompTiles=0, validateWithDevice=YES) and the texture is still
    // nil, then the failure must be inside `initImplWith...` (post-gate).
    // Logged once per unique (self_class, iosurface, plane) combo to avoid
    // spam.
    if (getenv("MACWS_AGX_TEX_BYPASS_GATE") && iosurface) {
        extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(IOSurfaceRef, size_t)
            __attribute__((weak_import));
        static int probelog = 0;
        if (probelog < 8) {
            uint32_t ctype = IOSurfaceGetCompressionTypeOfPlane
                ? IOSurfaceGetCompressionTypeOfPlane(iosurface, plane) : 0xFFFFFFFF;
            size_t hct = IOSurfaceGetHeightInCompressedTilesOfPlane
                ? IOSurfaceGetHeightInCompressedTilesOfPlane(iosurface, plane) : (size_t)-1;
            BOOL validOK = NO;
            @try {
                validOK = [desc respondsToSelector:@selector(validateWithDevice:)]
                    ? ((BOOL (*)(id, SEL, id))objc_msgSend)(desc,
                          @selector(validateWithDevice:), self)
                    : NO;
            } @catch (NSException *e) {
                validOK = -1; // marker that it threw
            }
            fprintf(stderr,
                "#### AGX_GATE_PROBE class=%s ios=%p plane=%lu "
                "compressionType=%u heightInCompressedTiles=%zu validateWithDevice=%d "
                "desc=(w=%lu h=%lu pf=%lu storage=%lu usage=0x%lx)\n",
                class_getName([self class]),
                (void*)iosurface, (unsigned long)plane,
                ctype, hct, (int)validOK,
                (unsigned long)desc.width, (unsigned long)desc.height,
                (unsigned long)desc.pixelFormat,
                (unsigned long)desc.storageMode, (unsigned long)desc.usage);
            probelog++;
        }
    }
    // Stash the IOSurfaceID into TLS so IOConnectCallMethod_new can inject it
    // into args[+0x30] for the sel=0xa type=0x82 path. Save/restore the
    // previous value to handle re-entry (shadow IOSurface fallback path).
    uint32_t prev_iosurface_id = macws_get_current_iosurface_id();
    macws_set_current_iosurface_id(iosurface ? IOSurfaceGetID(iosurface) : 0);
    static int tls_log = 0;
    if (tls_log < 8) {
        fprintf(stderr,
            "#### MTL_TEX TLS set iosurface=%p id=%#x (thread=%p addr=%p)\n",
            iosurface, macws_get_current_iosurface_id(), (void*)pthread_self(),
            NULL);
        tls_log++;
    }

    id<MTLTexture> result = nil;
    struct sigaction old_sa, new_sa;
    memset(&new_sa, 0, sizeof(new_sa));
    new_sa.sa_handler = macws_sigabrt_trampoline;
    sigemptyset(&new_sa.sa_mask);
    new_sa.sa_flags = SA_NODEFER;
    sigaction(SIGABRT, &new_sa, &old_sa);
    macws_in_protected = 1;
    if (sigsetjmp(macws_abort_env, 1) == 0) {
        result = [self hooked_newTextureWithDescriptor:desc iosurface:iosurface plane:plane];
    } else {
        fprintf(stderr, "#### MTL_TEX/iosurf CAUGHT SIGABRT (XPC reply error) "
            "— recovered, will fall back (w=%lu h=%lu pf=%lu ios=%p)\n",
            (unsigned long)desc.width, (unsigned long)desc.height,
            (unsigned long)desc.pixelFormat, (void*)iosurface);
        result = nil;
    }
    macws_in_protected = 0;
    sigaction(SIGABRT, &old_sa, NULL);
    if (!result && desc) {
        NSUInteger orig_fmt = desc.pixelFormat;
        // Try fallback translations only for the private 550 format (and nearby
        // private values in case Apple varies). Don't retry for known public
        // formats — their nil return means a real semantic error.
        BOOL is_private = (orig_fmt >= 548 && orig_fmt <= 551);
        if (is_private) {
            for (int i = 0; kMacwsTexFmt550Fallbacks[i] != 0; i++) {
                NSUInteger try_fmt = kMacwsTexFmt550Fallbacks[i];
                desc.pixelFormat = try_fmt;
                result = [self hooked_newTextureWithDescriptor:desc iosurface:iosurface plane:plane];
                if (result) {
                    fprintf(stderr,
                        "#### MTL_TEX/iosurf translated %lu->%lu OK (w=%lu h=%lu ios=%p tex=%p)\n",
                        (unsigned long)orig_fmt, (unsigned long)try_fmt,
                        (unsigned long)desc.width, (unsigned long)desc.height,
                        (void*)iosurface, (void*)result);
                    break;
                }
            }
            desc.pixelFormat = orig_fmt; // restore so caller sees original
        }
        // Shadow IOSurface substitution: when MTLSim/AGX-native cannot wrap
        // the iPad's compressed CA Framebuffer ('&b38' FourCC, 0x26-prefixed
        // Apple lossless-compressed format), allocate a SHADOW IOSurface in
        // plain BGRA8 with the same dimensions and wrap THAT in a Metal
        // texture. SkyLight + AGX both accept BGRA8 IOSurfaces fine; the
        // shadow stays in this process's address space so VNC's compositor
        // read path (which goes via the SkyLight display surface, not the
        // iPad's IOMFB scanout) sees the new content. The original iPad
        // scanout buffer stays untouched — coexistence mode (CA_VSYNC_OFF=1)
        // keeps the iPad panel on iOS anyway, so no visible artifact there.
        //
        // Pattern mirrors misc/TestMetalIOSurface and misc/agxprobe.m's
        // stage 5: minimal IOSurfaceCreate(width, height, bpe=4, pf='BGRA').
        //
        // Cache (original IOSurface ptr → shadow IOSurface ptr) so repeated
        // calls for the same scanout buffer reuse the same shadow.
        if (!result && iosurface && desc.width > 0 && desc.height > 0) {
            uint32_t fcc = IOSurfaceGetPixelFormat(iosurface);
            BOOL is_apple_compressed = ((fcc & 0xFF000000u) == 0x26000000u);
            if (is_apple_compressed) {
                static NSMutableDictionary *shadowCache = nil;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ shadowCache = [NSMutableDictionary new]; });
                NSValue *origKey = [NSValue valueWithPointer:(void *)iosurface];
                NSValue *shadowVal;
                @synchronized(shadowCache) {
                    shadowVal = shadowCache[origKey];
                }
                IOSurfaceRef shadow = (IOSurfaceRef)[shadowVal pointerValue];
                if (!shadow) {
                    // Match the iPad CA Framebuffer's kernel-side IOSurface
                    // properties so AGX accepts our shadow for
                    // newTextureWithDescriptor:iosurface:. Without these
                    // hints the userland IOSurface lacks IOGPU memory-region
                    // metadata and AGX rejects the wrap (verified: bare
                    // BGRA8 shadow at 2388x1668 returns nil; even h=48
                    // returns nil). The properties are mirrored from the
                    // original surface's reported "CreationProperties" dict:
                    //   IOSurfaceCacheMode      = 1792  (= 0x700, kIOMapWriteCombineCache)
                    //   IOSurfaceMapCacheAttribute = 0
                    //   IOSurfaceMemoryRegion   = "PurpleGfxMem"
                    NSDictionary *props = @{
                        @"IOSurfaceWidth":              @(desc.width),
                        @"IOSurfaceHeight":             @(desc.height),
                        @"IOSurfaceBytesPerElement":    @4,
                        @"IOSurfacePixelFormat":        @((uint32_t)'BGRA'),
                        @"IOSurfaceCacheMode":          @1792,
                        @"IOSurfaceMapCacheAttribute":  @0,
                        @"IOSurfaceMemoryRegion":       @"PurpleGfxMem",
                    };
                    shadow = IOSurfaceCreate((__bridge CFDictionaryRef)props);
                    // Fall back to bare BGRA8 if the kernel rejects
                    // PurpleGfxMem from userland.
                    if (!shadow) {
                        NSDictionary *bareprops = @{
                            @"IOSurfaceWidth":           @(desc.width),
                            @"IOSurfaceHeight":          @(desc.height),
                            @"IOSurfaceBytesPerElement": @4,
                            @"IOSurfacePixelFormat":     @((uint32_t)'BGRA'),
                        };
                        shadow = IOSurfaceCreate((__bridge CFDictionaryRef)bareprops);
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem rejected, fallback bare BGRA8 = %p\n",
                                (void *)shadow);
                    } else {
                        fprintf(stderr, "#### MTL_TEX/iosurf SHADOW PurpleGfxMem accepted = %p\n",
                                (void *)shadow);
                    }
                    if (shadow) {
                        @synchronized(shadowCache) {
                            shadowCache[origKey] = [NSValue valueWithPointer:(void *)shadow];
                        }
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW alloc'd BGRA8 (%lux%lu) %p for orig=%p (fcc=%#x)\n",
                            (unsigned long)desc.width, (unsigned long)desc.height,
                            (void *)shadow, (void *)iosurface, (unsigned)fcc);
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW IOSurfaceCreate FAILED for %lux%lu\n",
                            (unsigned long)desc.width, (unsigned long)desc.height);
                    }
                }
                if (shadow) {
                    MTLPixelFormat orig_fmt = desc.pixelFormat;
                    desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
                    result = [self hooked_newTextureWithDescriptor:desc iosurface:shadow plane:0];
                    desc.pixelFormat = orig_fmt;
                    if (result) {
                        static int logged = 0;
                        if (logged < 8) {
                            fprintf(stderr,
                                "#### MTL_TEX/iosurf SHADOW-backed texture %p (BGRA8) for orig surf=%p\n",
                                (void *)result, (void *)iosurface);
                            logged++;
                        }
                    } else {
                        fprintf(stderr,
                            "#### MTL_TEX/iosurf SHADOW newTexture STILL nil — giving up\n");
                    }
                }
            }
        }
    }
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/iosurf.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, iosurface, plane, "iosurf.NIL");
    }
    macws_set_current_iosurface_id(prev_iosurface_id);
    return result;
}

- (id<MTLTexture>)hooked_newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        macws_log_mtldesc(desc, NULL, 0, "plain.IN");
    }
    id<MTLTexture> result = [self hooked_newTextureWithDescriptor:desc];
    if (getenv("MACWS_TEX_TRACE") != NULL) {
        fprintf(stderr, "#### MTL_TEX/plain.OUT -> %p (label=%s)\n",
            (void*)result,
            result ? ([[result label] UTF8String] ?: "(nolabel)") : "(nil)");
    } else if (!result) {
        macws_log_mtldesc(desc, NULL, 0, "plain.NIL");
    }
    return result;
}

// ─── Tile-pipeline → render-pipeline converter ──────────────────────────────
// MTLSimDevice's `newRenderPipelineStateWithTileDescriptor:options:reflection:
// error:` MTLReportFailure-aborts WS. Swizzled onto MTLSimDevice; converts
// the MTLTileRenderPipelineDescriptor into an MTLRenderPipelineDescriptor
// (tileFunction → fragmentFunction, copy color attachments + sample count)
// and creates a regular MTLRenderPipelineState. BlurState::tile_downsample
// stores this in PingPongState and the subsequent draw runs through a
// regular MTLRenderCommandEncoder. Tile-specific shader intrinsics will not
// behave the same way they would on a real tile pipeline, but the BlurState
// flow does NOT short-circuit on nil and the destination texture DOES get
// written, so vibrancy panels render with content instead of solid black.
- (id)hooked_newRenderPipelineStateWithTileDescriptor:(id)tileDesc
                                              options:(NSUInteger)opt
                                           reflection:(id *)refl
                                                error:(NSError **)err {
    static int log_count = 0;
    if (log_count < 4) {
        log_count++;
        fprintf(stderr, "#### MTLSim tile-pipeline req → converting to render-pipeline\n");
    }

    MTLRenderPipelineDescriptor *rdesc = [[MTLRenderPipelineDescriptor alloc] init];
    if ([tileDesc respondsToSelector:@selector(label)]) {
        rdesc.label = [tileDesc performSelector:@selector(label)] ?: @"TileFallback";
    }

    // Use QuartzCore's own non-tile downsample-blur shaders. Their default
    // .metallib at /System/Library/Frameworks/QuartzCore.framework/Versions/A/
    // Resources/default.metallib defines `downsample_blur_4_frag_lpf` and
    // `downsample_blur_vert_lpf` for exactly this purpose — the non-tile
    // fallback path that QuartzCore uses on devices without tile rendering.
    // These shaders are pre-compiled and DO compile in chroot (no source
    // compilation needed).
    static dispatch_once_t qc_lib_once;
    static id<MTLLibrary> qc_lib = nil;
    static id<MTLFunction> qc_frag = nil;
    dispatch_once(&qc_lib_once, ^{
        NSURL *qcurl = [NSURL fileURLWithPath:
            @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *lerr = nil;
        qc_lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
        if (qc_lib) {
            qc_frag = [qc_lib newFunctionWithName:@"downsample_blur_4_frag_lpf"];
            fprintf(stderr, "#### tile-pipeline: QC frag = %p (downsample_blur_4_frag_lpf)\n",
                    (void *)qc_frag);
        }
    });
    if (qc_frag) {
        rdesc.fragmentFunction = qc_frag;
    } else if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
        // Last-resort: use the tile function as fragment (will likely fail
        // to compile due to imageblock intrinsics, but we already log that).
        id tileFn = [tileDesc performSelector:@selector(tileFunction)];
        rdesc.fragmentFunction = (id<MTLFunction>)tileFn;
    }
    // Tile pipelines have no vertex stage but MTLRenderPipelineDescriptor
    // validation REQUIRES a vertex function. Source-level compilation fails
    // in chroot (`This library format is not supported on this platform`),
    // so try a pre-existing library route instead.
    //
    // Try device's default library + the tile descriptor's tileFunction's
    // own library (the same .metallib that contains the tile fragment also
    // usually has a vertex helper). If both fail, return nil + NSError.
    static dispatch_once_t vfn_once;
    static id<MTLFunction> cached_vfn = nil;
    static NSArray<NSString *> *cand_names = nil;
    dispatch_once(&vfn_once, ^{
        cand_names = @[
            @"vertex_passthrough", @"vertexPassthrough",
            @"passthrough_vertex", @"passthroughVertex",
            @"PassthroughVertex", @"passthrough",
            @"fs_vertex", @"fullscreen_vertex", @"fullscreenVertex",
            @"main_vertex", @"vert_main", @"main0",
        ];
    });
    if (!cached_vfn) {
        // First: try the tile function's own library (BlurState's tile
        // shader is in QuartzCore's default.metallib, which also exposes
        // std_vert0_lpf / std_vert1_lpf / upsample_vert_lpf / etc.).
        id tileFn = nil;
        if ([tileDesc respondsToSelector:@selector(tileFunction)]) {
            tileFn = [tileDesc performSelector:@selector(tileFunction)];
        }
        // Order matters: downsample_blur_vert_lpf provides the texcoord0
        // output that downsample_blur_4_frag_lpf reads. std_vert0_lpf only
        // emits position and causes "Fragment input mismatching" errors.
        NSArray<NSString *> *qc_names = @[
            @"downsample_blur_vert_lpf",
            @"upsample_vert_lpf",
            @"std_vert1_lpf", @"std_vert0_lpf",
            @"read_surf_vert",
        ];
        if (tileFn && [tileFn respondsToSelector:@selector(library)]) {
            id lib = [tileFn performSelector:@selector(library)];
            for (NSString *nm in qc_names) {
                id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                if (f) { cached_vfn = f; break; }
            }
            if (!cached_vfn) {
                for (NSString *nm in cand_names) {
                    id<MTLFunction> f = [(id<MTLLibrary>)lib newFunctionWithName:nm];
                    if (f) { cached_vfn = f; break; }
                }
            }
        }
        // Second: load QuartzCore's default.metallib directly by URL.
        if (!cached_vfn) {
            @try {
                NSURL *qcurl = [NSURL fileURLWithPath:
                    @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
                NSError *lerr = nil;
                id<MTLLibrary> lib = [(id<MTLDevice>)self newLibraryWithURL:qcurl error:&lerr];
                if (lib) {
                    for (NSString *nm in qc_names) {
                        id<MTLFunction> f = [lib newFunctionWithName:nm];
                        if (f) { cached_vfn = f; break; }
                    }
                } else if (lerr) {
                    fprintf(stderr, "#### tile-pipeline: QC metallib load err: %s\n",
                            [[lerr localizedDescription] UTF8String]);
                }
            } @catch (NSException *e) {}
        }
        fprintf(stderr, "#### tile-pipeline: vertex fn lookup = %p (name=%s)\n",
                (void *)cached_vfn,
                cached_vfn ? [[cached_vfn name] UTF8String] : "(none)");
    }
    if (cached_vfn) {
        rdesc.vertexFunction = cached_vfn;
        NSArray *attrs = [cached_vfn performSelector:@selector(vertexAttributes)];
        if (attrs && [attrs count] > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            // Log all attributes so we know what to pre-populate for draw.
            for (id a in attrs) {
                NSUInteger idx = (NSUInteger)[[a valueForKey:@"attributeIndex"] unsignedLongValue];
                NSUInteger attrType = (NSUInteger)[[a valueForKey:@"attributeType"] unsignedLongValue];
                NSString *nm = [a valueForKey:@"name"];
                fprintf(stderr,
                    "#### blur-trace vertex attr[%lu]: name=%s type=%lu\n",
                    (unsigned long)idx,
                    nm ? [nm UTF8String] : "(no name)",
                    (unsigned long)attrType);
                // All attributes use buffer idx 0 (we'll populate one buffer
                // with all needed data per vertex in dispatchThreadsPerTile).
                vd.attributes[idx].format = MTLVertexFormatFloat4;
                vd.attributes[idx].offset = idx * 16;
                vd.attributes[idx].bufferIndex = 30;  // high slot to avoid clash
            }
            vd.layouts[30].stride = [attrs count] * 16;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[30].stepRate = 1;
            rdesc.vertexDescriptor = vd;
        }
    } else {
        if (err) *err = [NSError errorWithDomain:@"MTLDevice" code:0
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   @"No passthrough vertex function available"}];
        return nil;
    }

    if ([tileDesc respondsToSelector:@selector(colorAttachments)]) {
        id colAtts = [tileDesc performSelector:@selector(colorAttachments)];
        for (NSUInteger i = 0; i < 8; i++) {
            id src = nil;
            @try { src = [colAtts objectAtIndexedSubscript:i]; } @catch (NSException *e) { break; }
            if (!src) continue;
            MTLPixelFormat fmt = MTLPixelFormatInvalid;
            @try { fmt = (MTLPixelFormat)[[src valueForKey:@"pixelFormat"] unsignedLongValue]; } @catch (NSException *e) {}
            if (fmt == MTLPixelFormatInvalid) continue;
            rdesc.colorAttachments[i].pixelFormat = fmt;
        }
    }
    if ([tileDesc respondsToSelector:@selector(rasterSampleCount)]) {
        @try {
            rdesc.rasterSampleCount = (NSUInteger)[[tileDesc valueForKey:@"rasterSampleCount"] unsignedLongValue] ?: 1;
        } @catch (NSException *e) { rdesc.rasterSampleCount = 1; }
    }

    NSError *e2 = nil;
    id<MTLRenderPipelineState> result =
        [(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:rdesc
                                                          options:opt
                                                       reflection:nil
                                                            error:&e2];
    if (refl) *refl = nil;
    if (!result) {
        // Last resort: nil + NSError. WS stays alive; BlurState bails out
        // and the panel reverts to defensive solid color (still no abort).
        if (err) *err = e2 ?: [NSError errorWithDomain:@"MTLDevice" code:0
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Tile pipeline conversion failed"}];
        static int fail_count = 0;
        if (fail_count++ < 4) {
            fprintf(stderr, "#### tile-pipeline conversion FAILED: %s\n",
                    e2 ? [[e2 localizedDescription] UTF8String] : "(no error)");
        }
        return nil;
    }
    if (err) *err = nil;
    return result;
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
            // Pre-load IOGPU so its symbols are in the address space when
            // dyld binds AGXMetal13_3's cross-image references. AGXMetal13_3
            // calls IOGPU pool-allocator / IOGPUMetalCommonResource functions
            // through __got/__auth_got slots; if dyld can't resolve them at
            // bind time, the slots end up null and Mempool::grow's lambda
            // tail-jumps into garbage (see memory:
            // agx-mempool-grow-fault-decomposed and the lambda BL NOP fix in
            // mac_hooks.m). Force-loading IOGPU first lets the binder do its
            // job for those refs.
            const char *iogpuPaths[] = {
                "/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU",
                NULL
            };
            void *iogpu = NULL;
            for (int i = 0; iogpuPaths[i]; i++) {
                iogpu = dlopen(iogpuPaths[i], RTLD_GLOBAL | RTLD_NOW);
                if (iogpu) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE pre-loaded IOGPU via %s -> %p\n",
                        iogpuPaths[i], iogpu);
                    break;
                }
            }
            if (!iogpu) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE could NOT pre-load IOGPU: %s\n", dlerror());
            }
            // Verify some critical IOGPU symbols are resolvable
            const char *probeSyms[] = {
                "IOGPUResourceCreate",
                "IOGPUMetalCommonResourceCreate",
                "IOGPUDeviceCreateWithAPIProperty",
                "_IOGPUMetalAllocateResource",
                "IOGPUMetalAllocateResource",
                NULL
            };
            for (int i = 0; probeSyms[i]; i++) {
                void *p = dlsym(RTLD_DEFAULT, probeSyms[i]);
                fprintf(stderr, "#### MACWS_AGX_NATIVE dlsym(%s) = %p\n", probeSyms[i], p);
            }

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

// Diag hook on `-[AGXG13GFamilyTexture initImplWithDevice:Descriptor:iosurface:plane:buffer:
//                bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:]`.
// Per-call log of (self_class, iosurface, descriptor.pixelFormat, return value).
// Identifies which calls return nil and correlates to the iosurface.
typedef id (*macws_initimpl_orig_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked);
static macws_initimpl_orig_t macws_orig_initimpl = NULL;

static id macws_hook_initimpl(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    id buffer, NSUInteger bytesPerRow, BOOL allowNPOT, NSUInteger sparsePageSize,
    BOOL isCompressedIOSurface, BOOL isHeapBacked) {
    id result = nil;
    if (macws_orig_initimpl) {
        result = macws_orig_initimpl(self, _cmd, device, descriptor, iosurface,
            plane, buffer, bytesPerRow, allowNPOT, sparsePageSize,
            isCompressedIOSurface, isHeapBacked);
    }
    static int log_count = 0;
    if (log_count < 30) {
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        fprintf(stderr,
            "#### INITIMPL_HOOK self=%p cls=%s ios=%p ios_fcc=%#x desc(pf=%lu w=%lu h=%lu) "
            "buf=%p bpr=%lu npot=%d sparse=%lu compIOS=%d heap=%d → result=%p\n",
            self, class_getName([self class]),
            iosurface, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            buffer, (unsigned long)bytesPerRow,
            (int)allowNPOT, (unsigned long)sparsePageSize,
            (int)isCompressedIOSurface, (int)isHeapBacked,
            result);
        log_count++;
    }
    return result;
}

static void install_agx_initimpl_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE")) return;
    Class tex_cls = objc_getClass("AGXG13GFamilyTexture");
    if (!tex_cls) {
        fprintf(stderr, "#### INITIMPL_HOOK: AGXG13GFamilyTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:"
        "allowNPOT:sparsePageSize:isCompressedIOSurface:isHeapBacked:");
    Method m = class_getInstanceMethod(tex_cls, sel);
    if (!m) {
        fprintf(stderr, "#### INITIMPL_HOOK: method not found\n");
        return;
    }
    macws_orig_initimpl = (macws_initimpl_orig_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_initimpl);
    fprintf(stderr, "#### INITIMPL_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_initimpl);
}

// Diag hook on `-[IOGPUMetalTexture initWithDevice:descriptor:iosurface:plane:
//                field:args:argsSize:]`. This is the SUPER-INIT dispatched by
// -[AGXTexture initWithDevice:desc:iosurface:plane:] via objc_msgSendSuper2.
// AGXG13GFamilyTexture's initImpl succeeds (verified by INITIMPL_HOOK), so the
// nil-exit happens here at the cbz x0 at static 0x1e5a5af3c. Per the static
// disasm there are only two nil-exit paths after initImpl: super-init returns
// 0 OR validate returns BIT0=0 (we already patched validate to always-YES).
// Therefore super-init MUST be returning 0 — log its args + return.
typedef id (*macws_iogpu_init_t)(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize);
static macws_iogpu_init_t macws_orig_iogpu_init = NULL;

static id macws_hook_iogpu_init(
    id self, SEL _cmd,
    id device, id descriptor, IOSurfaceRef iosurface, NSUInteger plane,
    NSUInteger field, void *args, NSUInteger argsSize) {
    static int log_count = 0;
    // Log BEFORE calling orig — IOGPUMetalTexture's init may zero out self
    // on failure (verified by lldb: self.isa = 0 after orig returns nil),
    // so any [self class] after orig will crash.
    const char *cls_name_before = "?";
    if (log_count < 30) {
        Class c = object_getClass(self);
        cls_name_before = c ? class_getName(c) : "(nil)";
        NSUInteger pf = 0, w = 0, h = 0;
        if (descriptor) {
            pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(pixelFormat));
            w  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(width));
            h  = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, @selector(height));
        }
        uint32_t fcc = iosurface ? IOSurfaceGetPixelFormat(iosurface) : 0;
        // argsSize comes in via stack slot; the caller stores only the low
        // 32 bits (`str w8, [sp]`), so mask off the high garbage.
        NSUInteger argsSize_lo = argsSize & 0xFFFFFFFFu;
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [pre] self=%p cls=%s ios=%p ios_fcc=%#x "
            "desc(pf=%lu w=%lu h=%lu) plane=%lu field=%lu args=%p "
            "argsSize=%lu (raw=%#lx)\n",
            self, cls_name_before,
            iosurface, fcc,
            (unsigned long)pf, (unsigned long)w, (unsigned long)h,
            (unsigned long)plane, (unsigned long)field,
            args, (unsigned long)argsSize_lo, (unsigned long)argsSize);
    }
    // Save isa BEFORE calling orig — orig zeros the entire object on
    // failure, which makes any subsequent msgSend on `self` crash.
    uint64_t saved_isa = *(uint64_t *)self;
    id result = nil;
    if (macws_orig_iogpu_init) {
        result = macws_orig_iogpu_init(self, _cmd, device, descriptor,
            iosurface, plane, field, args, argsSize);
    }
    // If orig zeroed our isa, restore it so the caller's super-init bypass
    // hands a usable (if partially-init'd) object back to SkyLight. The
    // texture's IVAR area is uninitialised but its objc identity works:
    // [self class] / [self pixelFormat] / ARC retain/release all dispatch
    // correctly.
    uint64_t isa_after = *(uint64_t *)self;
    if (isa_after == 0 && saved_isa != 0) {
        *(uint64_t *)self = saved_isa;
    }
    if (log_count < 30) {
        fprintf(stderr,
            "#### IOGPU_INIT_HOOK [post] self=%p isa_was=%#llx isa_after=%#llx "
            "(restored=%d) → result=%p\n",
            self,
            (unsigned long long)saved_isa,
            (unsigned long long)isa_after,
            isa_after == 0 && saved_isa != 0,
            result);
        log_count++;
    }
    return result;
}

static void install_iogpu_init_hook(void) {
    if (!getenv("MACWS_AGX_INITIMPL_TRACE")) return;
    Class iogpu_cls = objc_getClass("IOGPUMetalTexture");
    if (!iogpu_cls) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: IOGPUMetalTexture class not found\n");
        return;
    }
    SEL sel = sel_registerName(
        "initWithDevice:descriptor:iosurface:plane:field:args:argsSize:");
    Method m = class_getInstanceMethod(iogpu_cls, sel);
    if (!m) {
        fprintf(stderr, "#### IOGPU_INIT_HOOK: method not found\n");
        return;
    }
    macws_orig_iogpu_init = (macws_iogpu_init_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)macws_hook_iogpu_init);
    fprintf(stderr, "#### IOGPU_INIT_HOOK: installed (orig=%p)\n",
        (void*)macws_orig_iogpu_init);
}

static void install_agx_init_redirect(Class agx) {
    install_agx_initimpl_hook();  // install diag hook on texture class
    install_iogpu_init_hook();    // install diag hook on IOGPUMetalTexture super-init

    SEL sel = @selector(initWithAcceleratorPort:);
    BOOL ok = class_addMethod(agx, sel, (IMP)agx_initWithAcceleratorPort_impl, "@@:i");
    fprintf(stderr, "#### MACWS_AGX_NATIVE class_addMethod(AGXG13GFamilyDevice, initWithAcceleratorPort:) = %d\n", (int)ok);

#if !defined(__arm64e__) || !defined(LIBMACHOOK_ON_DEVICE_BUILD)
    // Also swizzle AGXG13GFamilyDevice's newTextureWithDescriptor:iosurface:plane:
    // so our shadow-IOSurface fallback runs when AGX-native is active.
    // Without this, the MTLSimDevice swizzle in -[MTLFakeDevice initHooks]
    // doesn't reach AGXG13GFamilyDevice (it's a separate class hierarchy under
    // AGXTexture, not MTLSimDevice). SkyLight's compositor path goes through
    // AGXG13GFamilyTexture's underlying device method, which returns nil on
    // the iPad's '&b38' compressed CA Framebuffer just like MTLSim does.
    SEL iosurf_sel = @selector(newTextureWithDescriptor:iosurface:plane:);
    SEL iosurf_hook_sel = @selector(hooked_newTextureWithDescriptor:iosurface:plane:);
    if (class_getInstanceMethod(agx, iosurf_sel)) {
        swizzle2(agx, iosurf_sel, MTLFakeDevice.class, iosurf_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:\n");
    }
    SEL plain_sel = @selector(newTextureWithDescriptor:);
    SEL plain_hook_sel = @selector(hooked_newTextureWithDescriptor:);
    if (class_getInstanceMethod(agx, plain_sel)) {
        swizzle2(agx, plain_sel, MTLFakeDevice.class, plain_hook_sel);
        fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled AGXG13GFamilyDevice newTextureWithDescriptor:\n");
    }
#endif

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
