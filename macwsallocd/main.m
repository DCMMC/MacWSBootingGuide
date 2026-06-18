// macwsallocd — iOS-native helper that allocates IOSurface-backed memory
// regions on behalf of the chroot WindowServer. WS in AGX-native mode hits
// a kernel-side block on sel=0xa (IOGPUResourceCreate) for heap-creates —
// the user-client it opens doesn't expose that selector. This daemon runs
// in iOS-native context (sees the real AGX user-client), allocates an
// IOSurface of the requested size (kernel-blessed shared GPU memory), and
// returns the IOSurface mach send-right back to the chroot via XPC.
//
// Listens on the launchd-published mach service `com.macwsguide.alloc`.
// See layout/Library/LaunchDaemons/com.macwsguide.alloc.plist.
//
// Protocol:
//   request dict:
//     "op"      = "alloc-iosurf"
//     "size"    = u64  (byte count, capped at 256 MB)
//     "options" = u64  (MTLResourceOptions passed through; informational)
//   reply dict:
//     "result"  = "ok" | "size_invalid" | "io_create_fail"
//     "surface" = mach send-right for IOSurface (if ok)
//     "alloc_size" = u64 (actual allocation, page-rounded)

@import Foundation;
@import IOSurface;
@import Darwin;
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>

// AGX user-client borrowing — opens IOAcceleratorES from iOS-native context
// where kernel runs the full privileged init (sets per-UC device->0x108 size
// limit, this->0x100 enable byte, etc.), then sends the mach port for the
// io_connect_t back to chroot WS. The chroot then uses the borrowed
// connection for direct IOConnectCallMethod calls — the kernel processes
// each call against the UC's stored state which was set when WE opened it.
//
// This sidesteps the macOS-userland-on-iOS-kernel rejection where IOServiceOpen
// returns a UC whose privileged init step was skipped.
static io_connect_t g_borrow_conn = MACH_PORT_NULL;
static dispatch_once_t g_borrow_once;

static void borrow_serve(xpc_object_t event) {
    dispatch_once(&g_borrow_once, ^{
        io_service_t agx = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceMatching("IOAcceleratorES"));
        if (agx == IO_OBJECT_NULL) {
            NSLog(@"borrow-agx-conn: IOServiceGetMatchingService(IOAcceleratorES) returned NULL");
            return;
        }
        // type=1 matches iOS Metal's "full IOGPUDevice user-client" type.
        // Helper has iOS-Apple-signed-equivalent context so kernel runs the
        // privileged init paths that set device->0x108 etc. on the UC.
        kern_return_t kr = IOServiceOpen(agx, mach_task_self(), 1, &g_borrow_conn);
        IOObjectRelease(agx);
        if (kr != KERN_SUCCESS) {
            NSLog(@"borrow-agx-conn: IOServiceOpen failed kr=%#x", kr);
            g_borrow_conn = MACH_PORT_NULL;
            return;
        }
        NSLog(@"borrow-agx-conn: opened AGX io_connect_t = %u", g_borrow_conn);
    });

    // Crash-safety: wrap the reply construction so a malformed mach right
    // can never explode the daemon (the last test triggered EXC_GUARD
    // ILLEGAL_MOVE when the io_connect_t reuse was racy, spinning launchd
    // respawn → 124 load average on the device).
    @try {
        xpc_connection_t peer = xpc_dictionary_get_remote_connection(event);
        xpc_object_t r = xpc_dictionary_create_reply(event);
        NSLog(@"borrow-agx-conn: building reply r=%p peer=%p g_borrow_conn=%u",
            r, peer, g_borrow_conn);
        if (!r || !peer) {
            NSLog(@"borrow-agx-conn: no reply context (r=%p peer=%p)", r, peer);
            return;
        }
        if (g_borrow_conn != MACH_PORT_NULL) {
            // xpc_dictionary_set_mach_send DOES NOT consume the send right
            // (it's a copy-send, not move-send by default for XPC). So no
            // mod_refs needed — we can just set it and keep g_borrow_conn
            // valid for future borrowers. The earlier mod_refs+1 we tried
            // was probably what triggered the EXC_GUARD on an io_connect_t,
            // since io_connect_t mach ports may be guarded by IOKit.
            NSLog(@"borrow-agx-conn: about to set_mach_send port=%u", g_borrow_conn);
            xpc_dictionary_set_string(r, "result", "ok");
            xpc_dictionary_set_mach_send(r, "connect", g_borrow_conn);
            NSLog(@"borrow-agx-conn: set_mach_send completed");
        } else {
            xpc_dictionary_set_string(r, "result", "open_failed");
        }
        NSLog(@"borrow-agx-conn: about to send_message");
        xpc_connection_send_message(peer, r);
        NSLog(@"borrow-agx-conn served: g_borrow_conn=%u (send done)", g_borrow_conn);
    } @catch (NSException *e) {
        NSLog(@"borrow-agx-conn: EXCEPTION %@", e);
    }
}

static void alloc_serve(xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *op = xpc_dictionary_get_string(event, "op");
    if (!op) return;
    if (strcmp(op, "borrow-agx-conn") == 0) {
        borrow_serve(event);
        return;
    }
    if (strcmp(op, "alloc-iosurf") != 0) return;

    uint64_t size = xpc_dictionary_get_uint64(event, "size");
    uint64_t options = xpc_dictionary_get_uint64(event, "options");
    (void)options;

    xpc_connection_t peer = xpc_dictionary_get_remote_connection(event);
    xpc_object_t r = xpc_dictionary_create_reply(event);
    const char *result = "ok";
    mach_port_t surfPort = MACH_PORT_NULL;
    uint64_t alloc_size = 0;

    if (size == 0 || size > (256ULL * 1024 * 1024)) {
        result = "size_invalid";
    } else {
        NSDictionary *props = @{
            (id)kIOSurfaceWidth:           @(size),
            (id)kIOSurfaceHeight:          @(1),
            (id)kIOSurfaceBytesPerElement: @(1),
            (id)kIOSurfacePixelFormat:     @((uint32_t)'L008'),
        };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) {
            result = "io_create_fail";
        } else {
            surfPort = IOSurfaceCreateMachPort(surf);
            alloc_size = IOSurfaceGetAllocSize(surf);
            CFRelease(surf);
            if (surfPort == MACH_PORT_NULL) {
                result = "io_create_fail";
            }
        }
    }

    if (r && peer) {
        xpc_dictionary_set_string(r, "result", result);
        if (surfPort != MACH_PORT_NULL) {
            xpc_dictionary_set_mach_send(r, "surface", surfPort);
            xpc_dictionary_set_uint64(r, "alloc_size", alloc_size);
        }
        xpc_connection_send_message(peer, r);
    }
    if (surfPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), surfPort);
    }
    NSLog(@"alloc-iosurf size=%llu options=%#llx -> %s (alloc=%llu, port=%u)",
        size, options, result, alloc_size, surfPort);
}

#include <dlfcn.h>

int main(int argc, const char **argv) {
    NSLog(@"macwsallocd starting (pid=%d)", getpid());

    // Resolve dynamically — the iOS xpc header marks this API unavailable
    // even though the symbol is exported from libSystem at runtime.
    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) {
        NSLog(@"macwsallocd: xpc_connection_create_mach_service symbol missing");
        return 1;
    }

    dispatch_queue_t q = dispatch_queue_create("com.macwsguide.alloc", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = createMach(
        "com.macwsguide.alloc", q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        NSLog(@"macwsallocd: failed to create mach listener");
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
            alloc_serve(event);
        });
        xpc_connection_resume((xpc_connection_t)peer);
    });
    xpc_connection_resume(listener);
    NSLog(@"macwsallocd: published com.macwsguide.alloc");

    dispatch_main();
    return 0;
}
