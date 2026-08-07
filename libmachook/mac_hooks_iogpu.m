// mac_hooks_iogpu.m — part 4 of the mac_hooks.m split.
// Shared preamble, types and externs live in mac_hooks_internal.h.

@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
#import <stdarg.h>
#import "interpose.h"
#import "utils.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <pthread.h>
#import <limits.h>
#import <math.h>
#import <crt_externs.h>
#import <ptrauth.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <poll.h>
#include <execinfo.h>
#import "macws_host_protocol.h"
#import "macws_control_protocol.h"
#include "mac_hooks_internal.h"

#ifdef FORCE_M1_DRIVER
// IOKit
io_connect_t iogpuClients[10];
int iogpuClientsCount = 0;
BOOL IOConnectIsIOGPU(io_connect_t client) {
    for(int i = 0; i < iogpuClientsCount; ++i) {
        if(iogpuClients[i] == client) {
            return YES;
        }
    }
    return NO;
}
uint32_t IOConnectTranslateSelector(io_connect_t client, uint32_t selector) {
    if(IOConnectIsIOGPU(client)) {
        // translate selector to match iOS
        //NSLog(@"Translating selector 0x%x for IOGPU client %d", selector, client);
        // macOS -> iOS
        // 0x108 -> 0x108 (same)
        // 0x102 -> 0x102 (same)
        // 0x100 -> 0x100 (same)
        // 0x20 -> 0x20 (same)
        // 0x11 -> 0xf
        // 0xa -> 0x9
        //???
        // 0x8 -> 0x7
        // 0x7 -> 0x6
        // 0x5 -> 0x4
        // 0x2 -> 0x2 (same)
        // 0x0 -> 0x0 (same)
        switch(selector) {
            case 0x5: // IOGPUDeviceCreateWithAPIProperty + 672
                return 0x4;
            case 0x6: // IOGPUDeviceGetNextGlobalTraceID
                return 0x5;
            case 0x7: // IOGPUDeviceCreateWithAPIProperty + 172: sends "Metal"
                return 0x6;
            case 0x8: // IOGPUCommandQueueCreateWithQoS + 392
                return 0x7;
            case 0x9: // ioGPUCommandQueueFinalize
                return 0x8;
            case 0xa: // IOGPUResourceCreate
                return 0x9;
            case 0xb: // ioGPUResourceFinalize
                return 0xa;
            case 0xd: // IOGPUResourceSetPurgeable — function exists in both
                      // builds (macOS IOGPU at 0x19d156478, iOS IOGPU at
                      // 0x1eec60320). Byte-identical except `mov w1, #X`:
                      // macOS uses #0xd, iOS uses #0xc. Args identical:
                      // (resource->0x30, newState) → oldState; inCnt=2,
                      // outCnt=1. Confirmed by static disasm of both this
                      // session (2026-06-17). Without this, IOGPUMetal\
                      // Texture's super-init issues sel=0xd to set
                      // texture's heap purgeable state, iOS kernel returns
                      // 0xe00002c2 (kIOReturnNoMemory or kIOReturnBadArg),
                      // init returns nil + zeros self → texture wrap nil.
                return 0xc;
            case 0xf: // IOGPUDeviceCreateDeviceShmem
                return 0xd;
            case 0x10: // IOGPUDeviceDestroyDeviceShmem
                return 0xe;
            case 0x11: // IOGPUCommandQueueCreateWithQoS + 452
                return 0xf;
            case 0x12: // ioGPUNotificationQueueFinalize
                return 0x10;
            case 0x16: // IOGPUMTLFence initWithDevice:
                       // RE-confirmed 2026-08-04 against the exact macOS
                       // 13.4 and iPad13,6 iOS 16.3.1 IOGPU images. Both
                       // implementations pass zero scalar/struct input and
                       // request one 32-bit fence index; only the external
                       // method ordinal differs (macOS 0x16, iOS 0x12).
                       // Without this translation newFence returns nil and
                       // VectorKit later faults in updateFence:afterStages:
                       // while reading that fence's _fenceIndex ivar.
                return 0x12;
            case 0x17: // IOGPUMTLFence dealloc
                       // Paired lifecycle call for the mapping above. The
                       // actual implementations both pass the stored fence
                       // index as one scalar; macOS uses 0x17 and this iOS
                       // driver uses 0x13.
                return 0x13;
            case 0x18: // IOGPUMTLEvent initWithDevice:
                       // RE-confirmed 2026-07-29 from the actual framework
                       // binaries and an iOS-native runtime byte dump. macOS
                       // 13.4 IOGPU UUID CE2B5551-857F-3EDD-9E4F-435215CC8C27
                       // calls IOConnectCallMethod with selector 0x18; iOS
                       // 16.3 IOGPU at runtime offset +0x170b0 uses 0x14.
                       // Both functions otherwise pass zero scalar/struct
                       // input, request exactly two scalar outputs, and store
                       // the returned event ID/value into the same object
                       // fields. Leaving 0x18 untranslated returns
                       // 0xe00002c2 and forced the incomplete newSharedEvent
                       // fallback on every Chromium frame.
                return 0x14;
            case 0x19: // IOGPUMTLEvent dealloc
                       // RE-confirmed 2026-07-29 from both live framework
                       // implementations. macOS 13.4 IOGPU UUID
                       // CE2B5551-857F-3EDD-9E4F-435215CC8C27 at
                       // IOGPU+0x15488 loads object+0x10 as the sole scalar
                       // input and executes `mov w1, #0x19`. iOS 16.3 at
                       // live IOGPU+0x17190 has the same call ABI but executes
                       // `mov w1, #0x15`. This is the destructor paired with
                       // the adjacent 0x18 -> 0x14 event constructor above;
                       // leaving it untranslated makes every attempted
                       // kernel-event destruction return 0xe00002c2.
                return 0x15;
            case 0x1d: // IOGPUCommandQueueCreateWithQoS + 516
                return 0x19;
            case 0x1e: // IOGPUCommandQueueSubmitCommandBuffers
                return 0x1a;
            case 0x1f: // IOGPUCommandQueueSetPriorityAndBackground
                return 0x1b;
            case 0x25: // IOGPUDeviceSetDisplayParams — confirmed by BN disasm of both
                       // macOS IOGPU.framework (file /Users/.../agx-re/IOGPU at func
                       // _IOGPUDeviceSetDisplayParams uses `mov w1, #0x25; mov w3, #0x2`)
                       // and iOS IOGPU.bndb (same function uses sel 0x21 with same
                       // inCnt=2). Without this, WS loops on sel 0x25 →
                       // kIOReturnBadArgument while trying to set up the compositor
                       // display params during NSVisualEffectView backdrop-blur init,
                       // resulting in opaque-black vibrancy and high autosignd load.
                return 0x21;
            case 0x2a: // IOGPUDeviceCreateVNIODesc
                return 0x26;
        }
    }
    return selector;
}

// Per-thread IOSurfaceID stash. Set by Metal_hooks.x's swizzled
// hooked_newTextureWithDescriptor:iosurface:plane: before %orig runs, read
// here by IOConnectCallMethod_new to inject args[+0x30] for sel=0xa
// type=0x82 — the iOS kernel AGX dispatcher requires the IOSurfaceID at
// that offset to call find_iosurface_for_id (without it, returns
// kIOReturnNoMemory).
extern uint32_t macws_get_current_iosurface_id(void);
extern uint32_t macws_get_current_iosurface_plane(void);
extern uint64_t macws_get_current_iosurface_compression_header_span(void);

// AGX ID-translation shim. The iOS kernel AUTO-ASSIGNS resource GIDs (IOGPUObject
// atomic counter; getResource matches resource+0x28), but the macOS AGX driver uses
// CLIENT-ASSIGNED ids at IOGPUNewResourceArgs+0x48 (e.g. heap=0x20000, sub-resource
// parent-id=0x20000). libmachook is userspace-only (can't patch the kernel), so we
// bridge the two id-spaces here: record each created resource's clientID -> the
// iOS GID returned in its OUT struct, and rewrite parent-id references in 0x80
// sub-resources from clientID to the iOS GID so getResource() finds the parent.
macws_g_agxIdMap_t g_agxIdMap[128];
int g_agxIdMapCount;

// Successful IOGPU resource lifecycle diagnostic.  The previous create-minus-
// destroy counter included failed creates and did not compare resource IDs, so
// it could not establish a leak.  This table is keyed by the iOS kernel GID
// returned at IOGPUNewResourceOutArgs+0x1c and is removed by the scalar passed
// to ioGPUResourceFinalize.  Logs report only kernel-accepted operations.
//
// RE-confirmed with the project LLDB on macOS 13.4 IOGPU:
//   IOGPUResourceCreate+324 loads w8 from out+0x1c and stores wrapper+0x30;
//   ioGPUResourceFinalize+24 loads wrapper+0x30 and passes it as selector 0xb's
//   sole scalar. out+0x28 is copied to wrapper+0x50 and is NOT the resource ID.
struct macws_agx_life_entry g_agxLife[MACWS_AGX_LIFE_CAP];
pthread_mutex_t g_agxLifeLock = PTHREAD_MUTEX_INITIALIZER;
uint64_t g_agxLifeLive[256], g_agxLifeBytes[256];
uint64_t g_agxLifeCreateOK, g_agxLifeCreateFail;
uint64_t g_agxLifeDestroyOK, g_agxLifeDestroyFail;
uint64_t g_agxLifeUnmatchedDestroy, g_agxLifeTableFull;

// Resource flight recorder.  The live table proves bounded ownership, but a
// GPU page fault also needs the recently-destroyed ranges: a KCMD can retain a
// stale VA after its wrapper has already finalized.  Keep this diagnostic
// metadata in a fixed ring; it neither retains resources nor changes any
// create/finalize call.
struct macws_agx_life_event
    g_agxLifeEvents[MACWS_AGX_LIFE_EVENT_CAP];
uint64_t g_agxLifeEventSerial;

// Exact producer/kernel request bytes for recently-created type-0x82
// resources.  This is populated only while the raw IOGPU error sentinel is
// present.  The lifecycle table intentionally stores only compact metadata;
// a separate bounded ring avoids adding half a kilobyte to every one of its
// 16K slots during ordinary WindowServer runs.
struct macws_agx_t82_request
    g_macwsAgxT82Requests[MACWS_AGX_T82_REQUEST_CAP];
uint64_t g_macwsAgxT82RequestSequence;

bool macws_agx_life_diagnostics_enabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        value = macws_runtime_diagnostics_enabled() ||
            getenv("MACWS_AGX_LIFE_VERBOSE") != NULL ||
            macws_iogpu_error_diag_enabled() ||
            macws_submit_ring_enabled() ||
            access("/tmp/macws_submit_fast_ring", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

// Read the resource-generation boundary without exposing the lifecycle
// table's lock ordering to the submit recorder.  The returned serial is the
// newest successful create/finalize event that completed before this call.
// A later error dump can therefore distinguish a resource that stayed in the
// same generation from a GID that was destroyed and reused while the GPU work
// was outstanding.  This is observation only; it does not retain a resource
// or delay its finalizer.
uint64_t macws_agx_life_current_event_serial(void) {
    if (!macws_agx_life_diagnostics_enabled()) return 0;
    pthread_mutex_lock(&g_agxLifeLock);
    uint64_t serial = g_agxLifeEventSerial;
    pthread_mutex_unlock(&g_agxLifeLock);
    return serial;
}

void macws_agx_life_record_locked(
    uint8_t action, const struct macws_agx_life_entry *resource) {
    if (!resource) return;
    uint64_t serial = ++g_agxLifeEventSerial;
    g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP] =
        (struct macws_agx_life_event){serial, *resource, action};
}

unsigned macws_agx_life_hash(uint64_t gid) {
    return (unsigned)((gid * 11400714819323198485ull) >> 50) &
        (MACWS_AGX_LIFE_CAP - 1);
}

void macws_agx_life_summary_locked(const char *event, uint64_t id,
                                          uint8_t type, uint32_t surface_id,
                                          uint64_t bytes,
                                          IOReturn kr) {
    uint64_t live_total = 0, bytes_total = 0;
    for (unsigned i = 0; i < 256; i++) {
        live_total += g_agxLifeLive[i];
        bytes_total += g_agxLifeBytes[i];
    }
    fprintf(stderr,
        "#### AGX_LIFE %s id=%#llx type=%#x surf=%#x bytes=%#llx kr=%#x "
        "okC=%llu failC=%llu okD=%llu failD=%llu unmatchedD=%llu full=%llu "
        "live=%llu/%lluMB [t0=%llu/%lluMB t80=%llu/%lluMB t82=%llu/%lluMB]\n",
        event, (unsigned long long)id, type, surface_id,
        (unsigned long long)bytes, kr,
        (unsigned long long)g_agxLifeCreateOK,
        (unsigned long long)g_agxLifeCreateFail,
        (unsigned long long)g_agxLifeDestroyOK,
        (unsigned long long)g_agxLifeDestroyFail,
        (unsigned long long)g_agxLifeUnmatchedDestroy,
        (unsigned long long)g_agxLifeTableFull,
        (unsigned long long)live_total,
        (unsigned long long)(bytes_total >> 20),
        (unsigned long long)g_agxLifeLive[0],
        (unsigned long long)(g_agxLifeBytes[0] >> 20),
        (unsigned long long)g_agxLifeLive[0x80],
        (unsigned long long)(g_agxLifeBytes[0x80] >> 20),
        (unsigned long long)g_agxLifeLive[0x82],
        (unsigned long long)(g_agxLifeBytes[0x82] >> 20));
}

void macws_agx_life_create(uint64_t gid, uint8_t type,
                                  uint32_t client_id, uint32_t surface_id,
                                  uint64_t gpu_address, uint64_t data_bytes,
                                  uint64_t client_shared, uint64_t bytes,
                                  uint32_t flags_14, uint64_t request_50,
                                  const void *raw_request,
                                  size_t raw_request_length,
                                  const void *sent_request,
                                  size_t sent_request_length) {
    if (!macws_agx_life_diagnostics_enabled()) return;
    pthread_mutex_lock(&g_agxLifeLock);
    g_agxLifeCreateOK++;
    unsigned start = macws_agx_life_hash(gid), first_tomb = MACWS_AGX_LIFE_CAP;
    unsigned slot = MACWS_AGX_LIFE_CAP;
    for (unsigned probe = 0; probe < MACWS_AGX_LIFE_CAP; probe++) {
        unsigned i = (start + probe) & (MACWS_AGX_LIFE_CAP - 1);
        uint64_t here = g_agxLife[i].gid;
        if (here == gid) { slot = i; break; }
        if (here == UINT64_MAX && first_tomb == MACWS_AGX_LIFE_CAP)
            first_tomb = i;
        if (here == 0) {
            slot = first_tomb != MACWS_AGX_LIFE_CAP ? first_tomb : i;
            break;
        }
    }
    if (slot == MACWS_AGX_LIFE_CAP || gid == 0 || gid == UINT64_MAX) {
        g_agxLifeTableFull++;
        macws_agx_life_summary_locked("CREATE-UNTRACKED", gid, type,
                                      surface_id, bytes, 0);
    } else {
        if (g_agxLife[slot].gid == gid) {
            uint8_t old_type = g_agxLife[slot].type;
            g_agxLifeLive[old_type]--;
            g_agxLifeBytes[old_type] -= g_agxLife[slot].bytes;
        }
        g_agxLife[slot] = (struct macws_agx_life_entry){
            .gid = gid, .gpu_address = gpu_address,
            .data_bytes = data_bytes, .client_shared = client_shared,
            .bytes = bytes,
            .request_50 = request_50, .client_id = client_id,
            .surface_id = surface_id, .flags_14 = flags_14, .type = type
        };
        macws_agx_life_record_locked(1, &g_agxLife[slot]);
        if (type == 0x82 &&
            macws_iogpu_error_diag_enabled()) {
            uint64_t request_sequence = ++g_macwsAgxT82RequestSequence;
            struct macws_agx_t82_request *request =
                &g_macwsAgxT82Requests[(request_sequence - 1) %
                                       MACWS_AGX_T82_REQUEST_CAP];
            memset(request, 0, sizeof(*request));
            request->sequence = request_sequence;
            request->life_event_serial = g_agxLifeEventSerial;
            request->gid = gid;
            request->gpu_address = gpu_address;
            request->surface_id = surface_id;
            request->raw_length = (uint16_t)MIN(raw_request_length,
                (size_t)MACWS_AGX_T82_REQUEST_BYTES);
            request->sent_length = (uint16_t)MIN(sent_request_length,
                (size_t)MACWS_AGX_T82_REQUEST_BYTES);
            if (raw_request && request->raw_length != 0) {
                memcpy(request->raw, raw_request, request->raw_length);
            }
            if (sent_request && request->sent_length != 0) {
                memcpy(request->sent, sent_request, request->sent_length);
            }
        }
        g_agxLifeLive[type]++;
        g_agxLifeBytes[type] += bytes;
        // The normal steady-state type-0x82 live set is only 4--6 entries, so
        // the old `live <= 96` condition logged every frame (hundreds of
        // create/destroy lines per second) and became its own load source.
        // Keep full per-operation output opt-in; ordinary runs retain startup
        // witnesses plus periodic lifecycle summaries.
        if (g_agxLifeCreateOK <= 16 ||
            getenv("MACWS_AGX_LIFE_VERBOSE") ||
            (g_agxLifeCreateOK % 250) == 0)
            macws_agx_life_summary_locked("CREATE", gid, type,
                                          surface_id, bytes, 0);
    }
    pthread_mutex_unlock(&g_agxLifeLock);
}

void macws_agx_life_create_failed(uint8_t type, uint64_t bytes,
                                         IOReturn kr) {
    if (!macws_agx_life_diagnostics_enabled()) return;
    pthread_mutex_lock(&g_agxLifeLock);
    g_agxLifeCreateFail++;
    macws_agx_life_summary_locked("CREATE-FAIL", 0, type, 0, bytes, kr);
    pthread_mutex_unlock(&g_agxLifeLock);
}

void macws_agx_life_destroy(uint64_t gid, IOReturn kr) {
    if (!macws_agx_life_diagnostics_enabled()) return;
    pthread_mutex_lock(&g_agxLifeLock);
    if (kr != 0) {
        g_agxLifeDestroyFail++;
        macws_agx_life_summary_locked("DESTROY-FAIL", gid, 0xff, 0, 0, kr);
        pthread_mutex_unlock(&g_agxLifeLock);
        return;
    }
    g_agxLifeDestroyOK++;
    unsigned start = macws_agx_life_hash(gid), slot = MACWS_AGX_LIFE_CAP;
    for (unsigned probe = 0; probe < MACWS_AGX_LIFE_CAP; probe++) {
        unsigned i = (start + probe) & (MACWS_AGX_LIFE_CAP - 1);
        uint64_t here = g_agxLife[i].gid;
        if (here == gid) { slot = i; break; }
        if (here == 0) break;
    }
    if (slot == MACWS_AGX_LIFE_CAP) {
        g_agxLifeUnmatchedDestroy++;
        if (g_agxLifeUnmatchedDestroy <= 32 ||
            (g_agxLifeUnmatchedDestroy % 250) == 0)
            macws_agx_life_summary_locked("DESTROY-UNMATCHED", gid, 0xff,
                                          0, 0, kr);
    } else {
        struct macws_agx_life_entry resource = g_agxLife[slot];
        uint8_t type = resource.type;
        uint32_t surface_id = resource.surface_id;
        uint64_t bytes = resource.bytes;
        g_agxLifeLive[type]--;
        g_agxLifeBytes[type] -= bytes;
        macws_agx_life_record_locked(2, &resource);
        g_agxLife[slot].gid = UINT64_MAX;
        if (g_agxLifeDestroyOK <= 16 ||
            getenv("MACWS_AGX_LIFE_VERBOSE") ||
            (g_agxLifeDestroyOK % 250) == 0)
            macws_agx_life_summary_locked("DESTROY", gid, type,
                                          surface_id, bytes, kr);
    }
    pthread_mutex_unlock(&g_agxLifeLock);
}

const struct macws_agx_life_entry *
macws_agx_life_find_active_va_locked(uint64_t address) {
    for (unsigned i = 0; i < MACWS_AGX_LIFE_CAP; i++) {
        const struct macws_agx_life_entry *entry = &g_agxLife[i];
        if (entry->gid == 0 || entry->gid == UINT64_MAX ||
            entry->gpu_address == 0 || entry->bytes == 0) continue;
        if (address >= entry->gpu_address &&
            address - entry->gpu_address < entry->bytes) return entry;
    }
    return NULL;
}

const struct macws_agx_life_event *
macws_agx_life_find_recent_destroyed_va_locked(uint64_t address) {
    uint64_t newest = g_agxLifeEventSerial;
    uint64_t oldest = newest > MACWS_AGX_LIFE_EVENT_CAP
        ? newest - MACWS_AGX_LIFE_EVENT_CAP + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        const struct macws_agx_life_event *event =
            &g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP];
        const struct macws_agx_life_entry *entry = &event->resource;
        if (event->serial != serial || event->action != 2 ||
            entry->gpu_address == 0 || entry->bytes == 0) continue;
        if (address >= entry->gpu_address &&
            address - entry->gpu_address < entry->bytes) return event;
    }
    return NULL;
}

const struct macws_agx_t82_request *
macws_agx_find_t82_request_locked(
        const struct macws_agx_life_entry *resource) {
    if (!resource || resource->type != 0x82) return NULL;
    uint64_t newest = g_macwsAgxT82RequestSequence;
    uint64_t oldest = newest > MACWS_AGX_T82_REQUEST_CAP
        ? newest - MACWS_AGX_T82_REQUEST_CAP + 1 : 1;
    for (uint64_t sequence = newest;
         sequence >= oldest && sequence != 0; sequence--) {
        const struct macws_agx_t82_request *request =
            &g_macwsAgxT82Requests[(sequence - 1) %
                                   MACWS_AGX_T82_REQUEST_CAP];
        if (request->sequence != sequence ||
            request->gid != resource->gid ||
            request->gpu_address != resource->gpu_address ||
            request->surface_id != resource->surface_id) continue;
        return request;
    }
    return NULL;
}


// Read-only error artifact.  Correlate aligned 64-bit KCMD words against the
// kernel-returned VA ranges, and preserve the complete active/recent resource
// state.  A match is evidence; unmatched address-looking words remain opaque
// and are deliberately not labelled as broken.
void macws_agx_life_dump_snapshot(const char *directory,
                                         const unsigned char *commands,
                                         size_t commands_length) {
    if (!directory) return;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/resources.txt", directory);
    FILE *output = fopen(path, "w");
    if (!output) return;

    // The actual macOS 13.4 IOGPU cache image establishes these meanings:
    // IOGPUResourceCreate+0x134 copies kernel output +0x08 to wrapper+0x18,
    // IOGPUResourceGetDataBytes returns wrapper+0x18, while output +0x10 is
    // copied to wrapper+0x48 and returned by GetClientShared.  Preserve both
    // fields, but only read DataBytes for directly referenced type-0 resources.
    // The fixed count and per-resource byte cap keep a PageFault storm bounded.
    struct macws_agx_life_entry cpu_dumps[MACWS_AGX_CPU_DUMP_CAP];
    unsigned cpu_dump_count = 0;
    struct macws_agx_surface_dump
        surface_dumps[MACWS_AGX_SURFACE_DUMP_CAP];
    unsigned surface_dump_count = 0;

    pthread_mutex_lock(&g_agxLifeLock);
    fprintf(output,
        "create_ok=%llu destroy_ok=%llu create_fail=%llu destroy_fail=%llu "
        "unmatched_destroy=%llu event_newest=%llu\n",
        (unsigned long long)g_agxLifeCreateOK,
        (unsigned long long)g_agxLifeDestroyOK,
        (unsigned long long)g_agxLifeCreateFail,
        (unsigned long long)g_agxLifeDestroyFail,
        (unsigned long long)g_agxLifeUnmatchedDestroy,
        (unsigned long long)g_agxLifeEventSerial);
    fprintf(output, "[active]\n");
    for (unsigned i = 0; i < MACWS_AGX_LIFE_CAP; i++) {
        const struct macws_agx_life_entry *entry = &g_agxLife[i];
        if (entry->gid == 0 || entry->gid == UINT64_MAX) continue;
        fprintf(output,
            "gid=%#llx va=%#llx data=%#llx shared=%#llx bytes=%#llx "
            "type=%#x surface=%#x "
            "client=%#x flags14=%#x request50=%#llx\n",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->client_shared,
            (unsigned long long)entry->bytes, entry->type,
            entry->surface_id, entry->client_id, entry->flags_14,
            (unsigned long long)entry->request_50);
    }
    fprintf(output, "[kcmd-va-matches]\n");
    for (size_t offset = 0; commands && offset + 8 <= commands_length;
         offset += 8) {
        uint64_t value = *(const uint64_t *)(commands + offset);
        const struct macws_agx_life_entry *active =
            macws_agx_life_find_active_va_locked(value);
        if (active) {
            fprintf(output,
                "offset=%#zx value=%#llx state=ACTIVE gid=%#llx base=%#llx "
                "delta=%#llx bytes=%#llx type=%#x surface=%#x\n",
                offset, (unsigned long long)value,
                (unsigned long long)active->gid,
                (unsigned long long)active->gpu_address,
                (unsigned long long)(value - active->gpu_address),
                (unsigned long long)active->bytes, active->type,
                active->surface_id);
            if (active->type == 0 && active->data_bytes != 0 &&
                cpu_dump_count < MACWS_AGX_CPU_DUMP_CAP) {
                BOOL duplicate = NO;
                for (unsigned i = 0; i < cpu_dump_count; i++) {
                    if (cpu_dumps[i].gid == active->gid) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) cpu_dumps[cpu_dump_count++] = *active;
            }
            if (active->type == 0x82 && active->surface_id != 0 &&
                surface_dump_count < MACWS_AGX_SURFACE_DUMP_CAP) {
                BOOL duplicate = NO;
                for (unsigned i = 0; i < surface_dump_count; i++) {
                    const struct macws_agx_life_entry *saved =
                        &surface_dumps[i].resource;
                    if (saved->gid == active->gid &&
                        saved->gpu_address == active->gpu_address &&
                        saved->surface_id == active->surface_id) {
                        duplicate = YES;
                        break;
                    }
                }
                if (!duplicate) {
                    struct macws_agx_surface_dump *selected =
                        &surface_dumps[surface_dump_count++];
                    memset(selected, 0, sizeof(*selected));
                    selected->resource = *active;
                    const struct macws_agx_t82_request *request =
                        macws_agx_find_t82_request_locked(active);
                    if (request) {
                        selected->request = *request;
                        selected->has_request = YES;
                    }
                }
            }
            continue;
        }
        const struct macws_agx_life_event *destroyed =
            macws_agx_life_find_recent_destroyed_va_locked(value);
        if (destroyed) {
            const struct macws_agx_life_entry *entry = &destroyed->resource;
            fprintf(output,
                "offset=%#zx value=%#llx state=DESTROYED event=%llu "
                "gid=%#llx base=%#llx delta=%#llx bytes=%#llx "
                "type=%#x surface=%#x\n",
                offset, (unsigned long long)value,
                (unsigned long long)destroyed->serial,
                (unsigned long long)entry->gid,
                (unsigned long long)entry->gpu_address,
                (unsigned long long)(value - entry->gpu_address),
                (unsigned long long)entry->bytes, entry->type,
                entry->surface_id);
        }
    }
    fprintf(output, "[recent-events]\n");
    uint64_t newest = g_agxLifeEventSerial;
    uint64_t oldest = newest > MACWS_AGX_LIFE_EVENT_CAP
        ? newest - MACWS_AGX_LIFE_EVENT_CAP + 1 : 1;
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        const struct macws_agx_life_event *event =
            &g_agxLifeEvents[(serial - 1) % MACWS_AGX_LIFE_EVENT_CAP];
        if (event->serial != serial) continue;
        const struct macws_agx_life_entry *entry = &event->resource;
        fprintf(output,
            "event=%llu action=%s gid=%#llx va=%#llx data=%#llx "
            "shared=%#llx bytes=%#llx type=%#x surface=%#x client=%#x "
            "flags14=%#x request50=%#llx\n",
            (unsigned long long)serial,
            event->action == 1 ? "CREATE" : "DESTROY",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->client_shared,
            (unsigned long long)entry->bytes, entry->type,
            entry->surface_id, entry->client_id, entry->flags_14,
            (unsigned long long)entry->request_50);
    }
    pthread_mutex_unlock(&g_agxLifeLock);

    fprintf(output,
        "[direct-type0-cpu-dumps] selected=%u max_resources=%u "
        "max_bytes_each=%#x\n",
        cpu_dump_count, MACWS_AGX_CPU_DUMP_CAP, MACWS_AGX_CPU_DUMP_BYTES);
    for (unsigned i = 0; i < cpu_dump_count; i++) {
        const struct macws_agx_life_entry *entry = &cpu_dumps[i];
        size_t wanted = entry->bytes < MACWS_AGX_CPU_DUMP_BYTES
            ? (size_t)entry->bytes : MACWS_AGX_CPU_DUMP_BYTES;
        unsigned char *copy = wanted ? malloc(wanted) : NULL;
        mach_vm_size_t received = 0;
        kern_return_t kr = copy ? mach_vm_read_overwrite(
            mach_task_self(), (mach_vm_address_t)entry->data_bytes,
            (mach_vm_size_t)wanted, (mach_vm_address_t)copy,
            &received) : KERN_RESOURCE_SHORTAGE;
        char dump_path[PATH_MAX];
        snprintf(dump_path, sizeof(dump_path),
            "%s/resource_gid%llx_va%llx_cpu%llx.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes);
        size_t written = 0;
        if (kr == KERN_SUCCESS && received != 0) {
            FILE *dump = fopen(dump_path, "wb");
            if (dump) {
                written = fwrite(copy, 1, (size_t)received, dump);
                fclose(dump);
            }
        }
        fprintf(output,
            "gid=%#llx va=%#llx data=%#llx bytes=%#llx wanted=%#zx "
            "vm_read_kr=%#x received=%#llx written=%#zx file=%s\n",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->data_bytes,
            (unsigned long long)entry->bytes, wanted, kr,
            (unsigned long long)received, written,
            written ? dump_path : "(none)");
        free(copy);
    }

    fprintf(output,
        "[direct-type82-iosurface-dumps] selected=%u max_resources=%u "
        "max_head_bytes_each=%#x\n",
        surface_dump_count, MACWS_AGX_SURFACE_DUMP_CAP,
        MACWS_AGX_SURFACE_DUMP_BYTES);
    for (unsigned i = 0; i < surface_dump_count; i++) {
        const struct macws_agx_surface_dump *selected = &surface_dumps[i];
        const struct macws_agx_life_entry *entry = &selected->resource;
        char raw_path[PATH_MAX], sent_path[PATH_MAX];
        snprintf(raw_path, sizeof(raw_path),
            "%s/resource_gid%llx_va%llx_surf%x_request_raw.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        snprintf(sent_path, sizeof(sent_path),
            "%s/resource_gid%llx_va%llx_surf%x_request_sent.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t raw_written = 0, sent_written = 0;
        if (selected->has_request) {
            FILE *request_file = fopen(raw_path, "wb");
            if (request_file) {
                raw_written = fwrite(selected->request.raw, 1,
                    selected->request.raw_length, request_file);
                fclose(request_file);
            }
            request_file = fopen(sent_path, "wb");
            if (request_file) {
                sent_written = fwrite(selected->request.sent, 1,
                    selected->request.sent_length, request_file);
                fclose(request_file);
            }
        }

        IOSurfaceRef surface = IOSurfaceLookup(entry->surface_id);
        fprintf(output,
            "gid=%#llx va=%#llx bytes=%#llx surface=%#x request50=%#llx "
            "request_found=%s request_seq=%llu request_event=%llu "
            "raw=%u/%#zx sent=%u/%#zx lookup=%p",
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address,
            (unsigned long long)entry->bytes, entry->surface_id,
            (unsigned long long)entry->request_50,
            selected->has_request ? "YES" : "NO",
            (unsigned long long)selected->request.sequence,
            (unsigned long long)selected->request.life_event_serial,
            selected->request.raw_length, raw_written,
            selected->request.sent_length, sent_written,
            (__bridge void *)surface);
        if (!surface) {
            fprintf(output, "\n");
            continue;
        }

        size_t width = IOSurfaceGetWidth(surface);
        size_t height = IOSurfaceGetHeight(surface);
        size_t alloc_size = IOSurfaceGetAllocSize(surface);
        size_t bytes_per_row = IOSurfaceGetBytesPerRow(surface);
        size_t bytes_per_element = IOSurfaceGetBytesPerElement(surface);
        size_t plane_count = IOSurfaceGetPlaneCount(surface);
        OSType pixel_format = IOSurfaceGetPixelFormat(surface);
        uint32_t actual_id = IOSurfaceGetID(surface);

        char properties_path[PATH_MAX];
        snprintf(properties_path, sizeof(properties_path),
            "%s/resource_gid%llx_va%llx_surf%x_properties.plist", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t properties_written = 0;
        CFDictionaryRef properties = IOSurfaceCopyAllValues(surface);
        if (properties) {
            CFErrorRef property_error = NULL;
            CFDataRef property_data = CFPropertyListCreateData(
                kCFAllocatorDefault, properties,
                kCFPropertyListXMLFormat_v1_0, 0, &property_error);
            if (property_data) {
                FILE *properties_file = fopen(properties_path, "wb");
                if (properties_file) {
                    properties_written = fwrite(CFDataGetBytePtr(property_data),
                        1, (size_t)CFDataGetLength(property_data),
                        properties_file);
                    fclose(properties_file);
                }
                CFRelease(property_data);
            }
            if (property_error) CFRelease(property_error);
            CFRelease(properties);
        }

        uint32_t seed = 0;
        int lock_result = IOSurfaceLock(surface, 1u, &seed);
        void *base = lock_result == 0 ? IOSurfaceGetBaseAddress(surface) : NULL;
        size_t head_wanted = alloc_size < MACWS_AGX_SURFACE_DUMP_BYTES
            ? alloc_size : MACWS_AGX_SURFACE_DUMP_BYTES;
        char head_path[PATH_MAX], tail_path[PATH_MAX];
        snprintf(head_path, sizeof(head_path),
            "%s/resource_gid%llx_va%llx_surf%x_surface_head.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        snprintf(tail_path, sizeof(tail_path),
            "%s/resource_gid%llx_va%llx_surf%x_surface_tail.bin", directory,
            (unsigned long long)entry->gid,
            (unsigned long long)entry->gpu_address, entry->surface_id);
        size_t head_written = 0, tail_written = 0;
        if (base && head_wanted != 0) {
            FILE *surface_file = fopen(head_path, "wb");
            if (surface_file) {
                head_written = fwrite(base, 1, head_wanted, surface_file);
                fclose(surface_file);
            }
            if (alloc_size > head_wanted) {
                size_t tail_wanted = alloc_size - head_wanted;
                if (tail_wanted > 0x10000) tail_wanted = 0x10000;
                surface_file = fopen(tail_path, "wb");
                if (surface_file) {
                    tail_written = fwrite((const unsigned char *)base +
                        alloc_size - tail_wanted, 1, tail_wanted,
                        surface_file);
                    fclose(surface_file);
                }
            }
        }
        int unlock_result = lock_result == 0
            ? IOSurfaceUnlock(surface, 1u, &seed) : -1;
        fprintf(output,
            " actual_id=%#x width=%#zx height=%#zx alloc=%#zx bpr=%#zx "
            "bpe=%#zx planes=%#zx pixel_format=%#x properties=%#zx "
            "lock=%d base=%p seed=%u head=%#zx/%#zx tail=%#zx "
            "unlock=%d\n",
            actual_id, width, height, alloc_size, bytes_per_row,
            bytes_per_element, plane_count, (unsigned)pixel_format,
            properties_written, lock_result, base, seed,
            head_written, head_wanted, tail_written, unlock_result);
        CFRelease((CFTypeRef)surface);
    }
    fclose(output);
}

// 2026-06-19 — sel=0xa double-translation root cause:
// `launchdchrootexec` DYLD_INSERTs BOTH `libmachook.dylib` (arm64e) and
// `libmachook_arm64.dylib` (arm64). For arm64 chroot binaries (bash, our
// test tools), macOS arm64e dyld actually loads BOTH dylibs side-by-side
// (the comment in launchdchrootexec/main.m's "silently skips" is wrong:
// the device's dyld loads both anyway). Both run their initializers, both
// register DYLD_INTERPOSE tuples for IOConnectCallMethod. The result is
// that EACH `IOConnectCallMethod_new` invocation is re-entered AGAIN by
// the OTHER dylib's interpose. With per-dylib static `g_skip_translate`,
// the inner re-entry sees a different variable address (proved by &g_skip
// dump: outer 0x10090c9c0, inner 0x10087c5f0). The selector gets
// translated TWICE — for sel=0xa: 0xa→0x9→0x8 (queue_finalize) — and the
// kernel returns kIOReturnNoBandwidth (0xe00002c2). EVERY chroot
// "sel=0xa fails" event traces back to this. Decisive fix: detect the
// re-entry by inspecting the immediate caller via __builtin_return_address;
// if the caller is inside ANY copy of libmachook, skip translation. Works
// regardless of how many libmachook arch variants are loaded.
int caller_is_libmachook(void *ret) {
    Dl_info di;
    if (!dladdr(ret, &di) || !di.dli_fname) return 0;
    const char *base = strrchr(di.dli_fname, '/');
    base = base ? base + 1 : di.dli_fname;
    return strncmp(base, "libmachook", 10) == 0;
}

// Diagnostic protocol adapter for coexistence-mode IOMFB cancellation.
//
// Runtime-confirmed on 2026-07-25 with the exact QuartzCore image
// CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC:
//   * IOMobileFramebufferFrameInfo registration returned 0 and enabled the
//     display's frame-info bit;
//   * every successful SwapCancel ID (10759...) was subsequently retained in
//     IOMFBDisplay's pending FrameInfo vector at +0x510/+0x518;
//   * no frame_info_callback fired, so the vector and 15-MiB IOSurfaces grew
//     until Jetsam (792819 x 16-KiB resident pages).
// A cancelled swap has no physical-display completion notification.  Observe
// Apple's enabled registration state and exact callback/context so the opt-in
// diagnostic can synthesize the missing *cancellation completion* after the
// successful Cancel returns.
// This is deliberately gated by /tmp/macws_cancel_completion until runtime
// proves callback ordering, bounded ownership, and unchanged VNC pixels.


pthread_mutex_t g_macws_iomfb_frame_lock = PTHREAD_MUTEX_INITIALIZER;
struct macws_iomfb_frame_registration g_macws_iomfb_frame_regs[8];
unsigned g_macws_iomfb_frame_reg_count = 0;

// Do not wrap IOMobileFramebufferFrameInfo itself.  Runtime control runs
// showed that adding a plain-arm64 forwarding frame makes its private callback
// registration return kIOReturnNoBandwidth, while the untouched QuartzCore
// call returns success.  Instead observe the immediately following
// IOMFBServer::enable_frame_info_tag_list call.  RE-confirmed call order at
// QuartzCore 0x187ac8d44..0x187ac8d70 is:
//   FrameInfo(...) -> set_frame_info_enabled(status == 0) -> enable_tag_list.
// The enabled bit written by set_frame_info_enabled is display+0x9a4 bit 35.
MacwsEnableFrameInfoTagListFunction
    g_macws_orig_enable_frame_info_tag_list = NULL;
uintptr_t g_macws_quartzcore_header = 0;

void macws_enable_frame_info_tag_list(
    void *server, const char *const *available_tags, size_t available_count,
    const char *const *requested_tags, size_t requested_count) {
    g_macws_orig_enable_frame_info_tag_list(server, available_tags,
        available_count, requested_tags, requested_count);

    if (!server || !g_macws_quartzcore_header)
        return;
    void *display_holder = *(void **)((char *)server + 0x58);
    void *display = display_holder;
    MacwsIOMobileFramebufferRef framebuffer = display_holder
        ? *(MacwsIOMobileFramebufferRef *)((char *)display_holder + 0x300)
        : NULL;
    uint64_t flags = display
        ? *(const volatile uint64_t *)((const char *)display + 0x9a4)
        : 0;
    BOOL frame_info_enabled = (flags & 0x800000000ull) != 0;
    if (!frame_info_enabled || !framebuffer)
        return;

    // RE-confirmed via live iOS 16.3.1 kern_SwapEnd: the io_connect_t used for
    // selector 5 is the uint32_t at IOMobileFramebufferRef+0x14.  QuartzCore's
    // exact frame_info_callback is at image offset 0x29209c; call its raw code
    // address from the plain-arm64 WindowServer slice on the main queue.
    io_connect_t client =
        *(const volatile io_connect_t *)((const char *)framebuffer + 0x14);
    MacwsIOMFBFrameInfoCallback callback =
        (MacwsIOMFBFrameInfoCallback)(g_macws_quartzcore_header + 0x29209c);
    unsigned registration_slot = 0;
    pthread_mutex_lock(&g_macws_iomfb_frame_lock);
    for (; registration_slot < g_macws_iomfb_frame_reg_count;
         registration_slot++) {
        if (g_macws_iomfb_frame_regs[registration_slot].framebuffer ==
            framebuffer) {
            break;
        }
    }
    if (registration_slot == g_macws_iomfb_frame_reg_count &&
        registration_slot < sizeof(g_macws_iomfb_frame_regs) /
                                sizeof(g_macws_iomfb_frame_regs[0])) {
        g_macws_iomfb_frame_reg_count++;
    }
    if (registration_slot < sizeof(g_macws_iomfb_frame_regs) /
                                sizeof(g_macws_iomfb_frame_regs[0])) {
        uint64_t last_presentation_time =
            g_macws_iomfb_frame_regs[registration_slot]
                .last_presentation_time;
        g_macws_iomfb_frame_regs[registration_slot] =
            (struct macws_iomfb_frame_registration){
                framebuffer, client, callback, server,
                last_presentation_time};
    }
    pthread_mutex_unlock(&g_macws_iomfb_frame_lock);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION observed enabled registration "
            "fb=%p client=%u callback=%p context=%p flags=%#llx slot=%u "
            "vsync=%#x source=%#x displayTimer=%p fallbackTimer=%p runLoop=%p\n",
            framebuffer, client, callback, server,
            (unsigned long long)flags, registration_slot,
            *(const volatile uint8_t *)((const char *)server + 0x324),
            *(const volatile uint8_t *)((const char *)server + 0x325),
            *(void *const volatile *)((const char *)server + 0x298),
            *(void *const volatile *)((const char *)server + 0x2a0),
            *(void *const volatile *)((const char *)server + 0x278));
    }
}

void macws_install_quartzcore_frame_info_hook(
    const struct mach_header *untyped_header) {
    // RE-confirmed via the exact macOS 13.4 QuartzCore image:
    //   UUID CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC
    //   __TEXT vmaddr                                  0x1879be000
    //   IOMFBServer::enable_frame_info_tag_list        0x187c5085c
    //   IOMFBServer::frame_info_callback               0x187c5009c
    static const uint8_t expected_uuid[16] = {
        0xcf, 0x85, 0x3b, 0xbd, 0x01, 0xb6, 0x3f, 0x46,
        0xad, 0xa1, 0xec, 0x70, 0xfd, 0x2d, 0xc9, 0xdc,
    };
    static const uint32_t expected_prologue[4] = {
        0xd503237f, // pacibsp
        0xd10243ff, // sub sp, sp, #0x90
        0xa9036ffc, // stp x28, x27, [sp, #0x30]
        0xa90467fa, // stp x26, x25, [sp, #0x40]
    };
    enum {
        kQuartzCoreEnableFrameInfoTagListOffset = 0x29285c,
    };

    static _Atomic int installed = 0;
    if (atomic_exchange(&installed, 1))
        return;

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!header || header->magic != MH_MAGIC_64) {
        atomic_store(&installed, 0);
        return;
    }
    const uint8_t *command_bytes = (const uint8_t *)(header + 1);
    BOOL uuid_matches = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)command_bytes;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            uuid_matches = memcmp(uuid->uuid, expected_uuid,
                                  sizeof(expected_uuid)) == 0;
            break;
        }
        if (command->cmdsize < sizeof(*command))
            break;
        command_bytes += command->cmdsize;
    }
    if (!uuid_matches) {
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION QuartzCore observer skipped: "
            "UUID mismatch\n");
        atomic_store(&installed, 0);
        return;
    }

    void *target = (void *)((uintptr_t)header +
        kQuartzCoreEnableFrameInfoTagListOffset);
    if (memcmp(target, expected_prologue, sizeof(expected_prologue)) != 0) {
        const uint32_t *actual = (const uint32_t *)target;
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION QuartzCore observer skipped: "
            "enable-tag-list prologue mismatch %#x %#x %#x %#x\n",
            actual[0], actual[1], actual[2], actual[3]);
        atomic_store(&installed, 0);
        return;
    }

    g_macws_quartzcore_header = (uintptr_t)header;
    MSHookFunction(target, (void *)macws_enable_frame_info_tag_list,
        (void **)&g_macws_orig_enable_frame_info_tag_list);
    fprintf(stderr,
        "#### IOMFB CANCEL-COMPLETION QuartzCore observer "
        "enable-tag-list=%p trampoline=%p callback=%p\n",
        target, g_macws_orig_enable_frame_info_tag_list,
        (void *)(g_macws_quartzcore_header + 0x29209c));
}

// Keep virtual-display pacing outside QuartzCore's display-server locks.
//
// RE-confirmed with project LLDB against the loaded macOS 13.4 QuartzCore
// CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC on 2026-08-05:
//
//   IOMFBServer::begin_skylight_update  image+0x291288
//     +28  pthread_mutex_lock(server+0x18)
//     +36  pthread_mutex_lock(server+0x158)
//
//   IOMFBServer::finish_skylight_update image+0x291220
//     +64  calls IOMFBDisplay::finish_skylight_update
//           (its SwapEnd call is at image+0x2fdcc8)
//     +76  pthread_mutex_unlock(server+0x158)
//     +84  pthread_mutex_unlock(server+0x18)
//
//   IOMFBServer::vsync_callback          image+0x28f0fc
//     +72  pthread_mutex_lock(server+0x158)
//
// Runtime sample `/tmp/ws-magnify.sample` placed 232/266 display-timer
// samples in vsync_callback+76 waiting for that mutex while the updater was
// in MacwsIOMobileFramebufferSwapEnd_new's poll.  The old synchronous wait
// preserved bounded one-submit/one-completion ownership, but did so inside
// both server locks.  Pace once immediately BEFORE begin acquires them.  The
// finish wrapper only marks the exact dynamic scope in which SwapEnd must not
// repeat that wait; cancellation and its one matching completion remain in
// the original SwapEnd hook below.
MacwsIOMFBServerBeginSkylightUpdateFunction
    g_macws_orig_iomfbserver_begin_skylight_update;
MacwsIOMFBServerFinishSkylightUpdateFunction
    g_macws_orig_iomfbserver_finish_skylight_update;
_Thread_local unsigned g_macws_iomfbserver_finish_depth;

uintptr_t macws_iomfbserver_begin_skylight_update(
    void *server, void *update) {
    if (atomic_load_explicit(&g_macws_iomfb_coexist_swap_cancel,
                             memory_order_acquire) &&
        macws_cancel_completion_enabled()) {
        uint32_t pace_us = macws_coexist_activity_pace_us(
            macws_coexist_completion_pace_us());
        uint32_t slept_us =
            macws_coexist_wait_for_completion_slot(pace_us);
        if (macws_runtime_diagnostics_enabled()) {
            static _Atomic unsigned long paced_updates;
            unsigned long sequence = atomic_fetch_add_explicit(
                &paced_updates, 1, memory_order_relaxed) + 1;
            if (sequence <= 4 || (sequence % 600) == 0) {
                fprintf(stderr,
                    "#### COEXIST pre-lock completion pace #%lu: "
                    "interval=%u us slept=%u us server=%p\n",
                    sequence, pace_us, slept_us, server);
            }
        }
    }
    return g_macws_orig_iomfbserver_begin_skylight_update(server, update);
}

uintptr_t macws_iomfbserver_finish_skylight_update(
    void *server, void *update, uint32_t flags, uint64_t seed) {
    g_macws_iomfbserver_finish_depth++;
    uintptr_t result = g_macws_orig_iomfbserver_finish_skylight_update(
        server, update, flags, seed);
    g_macws_iomfbserver_finish_depth--;
    return result;
}

void macws_install_quartzcore_coexist_pacing_hooks(
    const struct mach_header *untyped_header) {
    static const uint8_t expected_uuid[16] = {
        0xcf, 0x85, 0x3b, 0xbd, 0x01, 0xb6, 0x3f, 0x46,
        0xad, 0xa1, 0xec, 0x70, 0xfd, 0x2d, 0xc9, 0xdc,
    };
    static const uint32_t expected_finish_prologue[4] = {
        0xd503237f, // pacibsp
        0xa9be4ff4, // stp x20, x19, [sp, #-0x20]!
        0xa9017bfd, // stp x29, x30, [sp, #0x10]
        0x910043fd, // add x29, sp, #0x10
    };
    static const uint32_t expected_begin_prologue[4] = {
        0xd503237f, // pacibsp
        0xa9be4ff4, // stp x20, x19, [sp, #-0x20]!
        0xa9017bfd, // stp x29, x30, [sp, #0x10]
        0x910043fd, // add x29, sp, #0x10
    };
    enum {
        kQuartzCoreIOMFBServerFinishSkylightUpdateOffset = 0x291220,
        kQuartzCoreIOMFBServerBeginSkylightUpdateOffset = 0x291288,
    };

    static _Atomic int installed;
    if (atomic_exchange_explicit(&installed, 1, memory_order_acq_rel)) return;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)untyped_header;
    if (!header || header->magic != MH_MAGIC_64 ||
        !macws_macho_uuid_matches(header, expected_uuid)) {
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    void *finish_target = (void *)((uintptr_t)header +
        kQuartzCoreIOMFBServerFinishSkylightUpdateOffset);
    void *begin_target = (void *)((uintptr_t)header +
        kQuartzCoreIOMFBServerBeginSkylightUpdateOffset);
    // Validate both endpoints before modifying either one. A partial install
    // would pace before begin and then pace again inside SwapEnd.
    if (memcmp(finish_target, expected_finish_prologue,
               sizeof(expected_finish_prologue)) != 0 ||
        memcmp(begin_target, expected_begin_prologue,
               sizeof(expected_begin_prologue)) != 0) {
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                "#### COEXIST pre-lock pacing skipped: QuartzCore "
                "begin/finish prologue mismatch\n");
        }
        atomic_store_explicit(&installed, 0, memory_order_release);
        return;
    }

    MSHookFunction(begin_target,
        (void *)macws_iomfbserver_begin_skylight_update,
        (void **)&g_macws_orig_iomfbserver_begin_skylight_update);
    MSHookFunction(finish_target,
        (void *)macws_iomfbserver_finish_skylight_update,
        (void **)&g_macws_orig_iomfbserver_finish_skylight_update);
    if (macws_runtime_diagnostics_enabled()) {
        fprintf(stderr,
            "#### COEXIST pre-lock pacing installed begin=%p/%p "
            "finish=%p/%p\n",
            begin_target, g_macws_orig_iomfbserver_begin_skylight_update,
            finish_target, g_macws_orig_iomfbserver_finish_skylight_update);
    }
}

void macws_iomfb_complete_cancelled_swap(
    io_connect_t client, uint32_t swap_id,
    uint64_t requested_presentation_time) {
    if (!macws_cancel_completion_enabled())
        return;

    struct macws_iomfb_frame_registration registration = {0};
    pthread_mutex_lock(&g_macws_iomfb_frame_lock);
    for (unsigned i = 0; i < g_macws_iomfb_frame_reg_count; i++) {
        if (g_macws_iomfb_frame_regs[i].client == client) {
            registration = g_macws_iomfb_frame_regs[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_macws_iomfb_frame_lock);

    BOOL diagnostics = macws_runtime_diagnostics_enabled();
    static _Atomic unsigned long scheduled_count = 0;
    unsigned long sequence = diagnostics
        ? atomic_fetch_add(&scheduled_count, 1) + 1 : 0;
    if (!registration.callback) {
        if (sequence && (sequence <= 16 || (sequence % 600) == 0)) {
            fprintf(stderr,
                "#### IOMFB CANCEL-COMPLETION schedule #%lu swapID=%u "
                "client=%u FAIL no registration\n",
                sequence, swap_id, client);
        }
        return;
    }

    // A 200-ms FIFO experiment was runtime-disproved on 2026-07-26:
    // submissions were not completion-paced, so the FIFO grew without bound
    // while WindowServer stayed at 83-86% CPU.  Keep one completion per
    // successful cancellation and let the caller pace the ownership boundary.
    if (sequence && (sequence <= 16 || (sequence % 600) == 0)) {
        fprintf(stderr,
            "#### IOMFB CANCEL-COMPLETION schedule #%lu swapID=%u "
            "client=%u fb=%p\n",
            sequence, swap_id, client, registration.framebuffer);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // RE-confirmed from the exact macOS 13.4 QuartzCore image
        // CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC. frame_info_callback at
        // 0x187c5009c reads Presentation_time, Vbl_FrameTime (falling back to
        // Presentation_time only when zero), Requested_presentation,
        // Min_FrameTime, and Max_FrameTime.  It converts the first three raw
        // mach_absolute_time ticks and uses them in its presentation cadence
        // calculation.  The prior empty dictionary therefore did not merely
        // omit optional telemetry: it supplied zero scheduler timestamps.
        //
        // Runtime-confirmed in native iOS 16.3 backboardd at QuartzCore
        // 0x19d41717c: these keys are NSNumber values in raw absolute-time
        // ticks; Vbl_FrameTime was Presentation_time-3 in the captured real
        // frame, and Min/Max were zero.  A cancelled coexistence frame has no
        // physical scanout, so its paced delivery slot is the virtual vblank
        // and both presentation fields use that same honest delivery time.
        uint64_t presentation_time = mach_absolute_time();
        uint64_t presentation_delta = 0;
        pthread_mutex_lock(&g_macws_iomfb_frame_lock);
        for (unsigned i = 0; i < g_macws_iomfb_frame_reg_count; i++) {
            if (g_macws_iomfb_frame_regs[i].client == client) {
                uint64_t prior = g_macws_iomfb_frame_regs[i]
                    .last_presentation_time;
                if (prior && presentation_time >= prior)
                    presentation_delta = presentation_time - prior;
                g_macws_iomfb_frame_regs[i].last_presentation_time =
                    presentation_time;
                break;
            }
        }
        pthread_mutex_unlock(&g_macws_iomfb_frame_lock);
        if (!presentation_delta &&
            presentation_time >= requested_presentation_time) {
            presentation_delta =
                presentation_time - requested_presentation_time;
        }

        void *display_holder = diagnostics && registration.context
            ? *(void **)((char *)registration.context + 0x58) : NULL;
        uintptr_t pending_begin_before = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x510) : 0;
        uintptr_t pending_end_before = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x518) : 0;
        size_t pending_before = pending_end_before >= pending_begin_before
            ? (pending_end_before - pending_begin_before) / sizeof(void *) : 0;
        NSDictionary *cancelInfo = @{
            @"Presentation_delta": @(presentation_delta),
            @"Presentation_time": @(presentation_time),
            @"Requested_presentation": @(requested_presentation_time),
            @"Vbl_FrameTime": @(presentation_time),
            @"Min_FrameTime": @0ull,
            @"Max_FrameTime": @0ull,
        };
        registration.callback(registration.framebuffer, swap_id,
            (__bridge CFDictionaryRef)cancelInfo, registration.context);
        uintptr_t pending_begin_after = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x510) : 0;
        uintptr_t pending_end_after = display_holder
            ? *(const volatile uintptr_t *)((char *)display_holder + 0x518) : 0;
        size_t pending_after = pending_end_after >= pending_begin_after
            ? (pending_end_after - pending_begin_after) / sizeof(void *) : 0;
        static _Atomic unsigned long delivered_count = 0;
        unsigned long delivered = diagnostics
            ? atomic_fetch_add(&delivered_count, 1) + 1 : 0;
        if (delivered && (delivered <= 16 || (delivered % 600) == 0)) {
            fprintf(stderr,
                "#### IOMFB CANCEL-COMPLETION delivered #%lu swapID=%u "
                "client=%u requested=%llu presentation=%llu delta=%llu "
                "pending=%zu->%zu\n",
                delivered, swap_id, client,
                (unsigned long long)requested_presentation_time,
                (unsigned long long)presentation_time,
                (unsigned long long)presentation_delta,
                pending_before, pending_after);
        }
    });
}

// Bounded command-submit diagnostics for the native-AGX VNC control pass.
//
// Enable read-only capture by creating /tmp/macws_submit_diag in the chroot.
// At most eight translated selector-0x1a submits are inspected per process,
// and at most 0x300 command bytes are printed for each descriptor.  Each
// structurally valid subtype-1 record is also copied verbatim to
// /tmp/macws_submit_type1_<sequence>_<record>.bin.  The binary artifact is
// needed for a byte-for-byte comparison with the native-iOS record; stderr's
// bounded prefix is insufficient to locate a trailing ABI insertion.  This
// is intentionally opt-in: ordinary WindowServer submits are far too frequent
// for an unconditional deep dump.
//
// /tmp/macws_kcmd_fix enables a SEPARATE TEMPORARY ABI-TRANSLATION
// EXPERIMENT.  It is not a production fix.  Historical native-iOS versus
// macOS-chroot byte captures found a subtype-3 record whose macOS form had a
// 16-byte zero pad before the same 12-byte terminal sentinel.  We only remove
// that pad when every structural field and every signature byte matches.  A
// successful IOConnect return is not evidence that this worked; the caller's
// exact clear/control pixel remains the required execution witness.

_Atomic unsigned g_macws_submit_diag_sequence = 0;
// The compositor submits multi-segment KCMD storage continuously.  Preserve
// translation for every structurally validated submission (later frames are
// the actual GUI witness), while bounding the per-segment diagnostic output.
_Atomic unsigned g_macws_multisegment_log_batches = 0;

// Completion errors are asynchronous: by the time Metal exposes an NSError,
// the selector-0x1a IOConnect call that supplied the offending bytes has long
// returned and its command-storage object may already be recycled.  The old
// "first eight submits" capture therefore missed the first Terminal workload
// that runtime-reported `00000102` after more than 500 successful submissions.
//
// `/tmp/macws_submit_ring` enables a read-only, process-local flight recorder.
// It retains the most recent 2048 descriptor snapshots in memory and writes them
// only when `macws_dump_recent_agx_submits` is called by the Metal completion
// observer.  This is diagnostic instrumentation, not an ABI patch: it neither
// changes submission order nor modifies any additional command bytes.



pthread_mutex_t g_macws_submit_ring_lock = PTHREAD_MUTEX_INITIALIZER;
struct macws_submit_ring_entry
    g_macws_submit_ring[MACWS_SUBMIT_RING_COUNT];
_Atomic uint64_t g_macws_submit_ring_serial = 0;
_Atomic unsigned g_macws_submit_ring_dump_count = 0;

// A diagnostic producer (currently the native tile-binding witness) can mark
// the exact Metal command-buffer objects whose KCMD bytes must survive an
// asynchronous error delay. Pointer values only: this does not retain or
// message the object and therefore cannot extend a resource lifetime.
_Atomic uintptr_t g_macws_submit_marks[MACWS_SUBMIT_MARK_COUNT];
_Atomic uint64_t g_macws_submit_mark_serial = 0;
_Atomic uint64_t g_macws_submit_serial_marks[MACWS_SUBMIT_MARK_COUNT];

__attribute__((used, visibility("default")))
void macws_mark_agx_submit_for_error_dump(const void *command_buffer) {
    if (!command_buffer || !macws_submit_ring_enabled())
        return;
    uint64_t serial = atomic_fetch_add(&g_macws_submit_mark_serial, 1) + 1;
    atomic_store(&g_macws_submit_marks[
        (serial - 1) % MACWS_SUBMIT_MARK_COUNT],
        (uintptr_t)command_buffer);
    if (serial <= 8) {
        fprintf(stderr,
            "#### AGX_SUBMIT_RING mark #%llu commandBuffer=%p "
            "(pointer only; no retain)\n",
            (unsigned long long)serial, command_buffer);
    }
}

__attribute__((used, visibility("default")))
void macws_mark_agx_submit_serial_for_error_dump(uint64_t submit_serial) {
    if (!submit_serial || !macws_submit_ring_enabled())
        return;
    uint64_t mark = atomic_fetch_add(&g_macws_submit_mark_serial, 1) + 1;
    atomic_store(&g_macws_submit_serial_marks[
        (mark - 1) % MACWS_SUBMIT_MARK_COUNT], submit_serial);
}

BOOL macws_submit_ring_is_marked(uintptr_t command_buffer) {
    if (!command_buffer) return NO;
    for (size_t i = 0; i < MACWS_SUBMIT_MARK_COUNT; i++) {
        if (atomic_load(&g_macws_submit_marks[i]) == command_buffer)
            return YES;
    }
    return NO;
}

BOOL macws_submit_ring_serial_is_marked(uint64_t submit_serial) {
    if (!submit_serial) return NO;
    for (size_t i = 0; i < MACWS_SUBMIT_MARK_COUNT; i++) {
        if (atomic_load(&g_macws_submit_serial_marks[i]) == submit_serial)
            return YES;
    }
    return NO;
}

__attribute__((used, visibility("default")))
uint64_t macws_latest_agx_submit_serial(const void *command_buffer) {
    if (!command_buffer || !macws_submit_ring_enabled())
        return 0;
    uint64_t result = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    uint64_t newest = atomic_load(&g_macws_submit_ring_serial);
    uint64_t oldest = newest > MACWS_SUBMIT_RING_COUNT
        ? newest - MACWS_SUBMIT_RING_COUNT + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == serial &&
            entry->command_buffer == (uintptr_t)command_buffer) {
            result = serial;
            break;
        }
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return result;
}

__attribute__((used, visibility("default")))
unsigned macws_agx_submit_fixed_count(uint64_t submit_serial) {
    if (!submit_serial || !macws_submit_ring_enabled())
        return 0;
    unsigned result = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    unsigned slot = (unsigned)((submit_serial - 1) %
                               MACWS_SUBMIT_RING_COUNT);
    struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
    if (entry->serial == submit_serial)
        result = entry->fixed;
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return result;
}

__attribute__((used, visibility("default")))
int macws_agx_submit_dimensions(uint64_t submit_serial,
                                uint32_t *width_out,
                                uint32_t *height_out) {
    if (!submit_serial || !macws_submit_ring_enabled())
        return 0;
    int result = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    unsigned slot = (unsigned)((submit_serial - 1) %
                               MACWS_SUBMIT_RING_COUNT);
    struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
    // The first translated render record stores its target dimensions at
    // record+0x3b0/+0x3b4 in both the pre- and post-normalized layouts.
    if (entry->serial == submit_serial && entry->post_commands &&
        entry->post_commands_length >= 0x3b8) {
        memcpy(&width, entry->post_commands + 0x3b0, sizeof(width));
        memcpy(&height, entry->post_commands + 0x3b4, sizeof(height));
        result = width != 0 && height != 0;
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    if (result) {
        if (width_out) *width_out = width;
        if (height_out) *height_out = height;
    }
    return result;
}

void macws_submit_ring_replace(unsigned char **destination,
                                      size_t *destination_length,
                                      const unsigned char *source,
                                      size_t source_length) {
    free(*destination);
    *destination = NULL;
    *destination_length = 0;
    if (!source || source_length == 0 ||
        source_length > MACWS_SUBMIT_RING_MAX_BYTES)
        return;
    unsigned char *copy = malloc(source_length);
    if (!copy) return;
    memcpy(copy, source, source_length);
    *destination = copy;
    *destination_length = source_length;
}

struct macws_submit_ring_token macws_submit_ring_begin(
        unsigned sequence, unsigned descriptor,
        uintptr_t descriptor_pointer, uintptr_t command_buffer,
        uintptr_t storage,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    struct macws_submit_ring_token token = {0};
    if (!macws_submit_ring_enabled())
        return token;

    token.serial = atomic_fetch_add(&g_macws_submit_ring_serial, 1) + 1;
    token.slot = (unsigned)((token.serial - 1) % MACWS_SUBMIT_RING_COUNT);
    token.active = 1;

    // Take the lifecycle boundary before the ring lock.  Error dumping uses
    // ring -> lifecycle lock order; never invert that order here.  Other
    // threads may create resources after this point, but every event at or
    // below this serial was visible when the segment list was captured.
    uint64_t life_event_serial = macws_agx_life_current_event_serial();

    pthread_mutex_lock(&g_macws_submit_ring_lock);
    struct macws_submit_ring_entry *entry =
        &g_macws_submit_ring[token.slot];
    macws_submit_ring_replace(&entry->pre_commands,
        &entry->pre_commands_length, commands, commands_length);
    macws_submit_ring_replace(&entry->pre_segments,
        &entry->pre_segments_length, segments, segments_length);
    macws_submit_ring_replace(&entry->post_commands,
        &entry->post_commands_length, NULL, 0);
    macws_submit_ring_replace(&entry->post_segments,
        &entry->post_segments_length, NULL, 0);
    entry->sequence = sequence;
    entry->descriptor = descriptor;
    entry->fixed = 0;
    entry->descriptor_pointer = descriptor_pointer;
    entry->command_buffer = command_buffer;
    entry->storage = storage;
    entry->life_event_serial = life_event_serial;
    // Publish serial last while holding the lock.  A concurrent error dumper
    // can never observe new metadata paired with the overwritten slot's data.
    entry->serial = token.serial;
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    return token;
}

void macws_submit_ring_finish(
        struct macws_submit_ring_token token, unsigned fixed,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    if (!token.active) return;
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    struct macws_submit_ring_entry *entry =
        &g_macws_submit_ring[token.slot];
    if (entry->serial == token.serial) {
        entry->fixed = fixed;
        macws_submit_ring_replace(&entry->post_commands,
            &entry->post_commands_length, commands, commands_length);
        macws_submit_ring_replace(&entry->post_segments,
            &entry->post_segments_length, segments, segments_length);
    }
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
}

size_t macws_submit_ring_write_file(const char *path,
                                           const unsigned char *bytes,
                                           size_t length) {
    if (!path || !bytes || !length) return 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 0;
    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, bytes + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    close(fd);
    return written;
}

void macws_dump_recent_agx_submits_impl(
        const char *reason, const void *command_buffer,
        uint64_t requested_serial) {
    if (!macws_submit_ring_enabled())
        return;
    unsigned dump = atomic_fetch_add(&g_macws_submit_ring_dump_count, 1) + 1;
    // Keep the first generic completion error, the first raw page-fault
    // callback, and one post-recovery clean control as separate witnesses.
    // WindowServer currently reports an
    // early Code=1/00000102 command-buffer error before the later Code=3
    // address fault; a one-dump process limit let that startup error consume
    // the only slot and hid the faulting submission.  The Metal observer uses
    // independent one-shot latches for those classes.  The existing public
    // Metal completion observer also consumes one slot immediately after the
    // raw PageFault callback, so four directories are required to retain the
    // later post-recovery clean control.  The bound still prevents a GPU
    // recovery storm from writing indefinitely.
    if (dump > 4) return;

    char directory[PATH_MAX];
    snprintf(directory, sizeof(directory),
        "/tmp/macws_submit_error_%d_%u", getpid(), dump);
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr,
            "#### AGX_SUBMIT_RING dump mkdir failed path=%s errno=%d\n",
            directory, errno);
        return;
    }

    char manifest_path[PATH_MAX];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.txt",
        directory);
    FILE *manifest = fopen(manifest_path, "w");
    pthread_mutex_lock(&g_macws_submit_ring_lock);
    uint64_t newest = atomic_load(&g_macws_submit_ring_serial);
    uint64_t oldest = newest > MACWS_SUBMIT_RING_COUNT
        ? newest - MACWS_SUBMIT_RING_COUNT + 1 : 1;
    uint64_t matched_serial = 0;
    struct macws_submit_ring_entry *matched_entry = NULL;
    if (requested_serial >= oldest && requested_serial <= newest) {
        unsigned slot = (unsigned)((requested_serial - 1) %
                                   MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == requested_serial) {
            matched_serial = requested_serial;
            matched_entry = entry;
        }
    }
    for (uint64_t serial = oldest;
         !matched_entry && serial <= newest; serial++) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry = &g_macws_submit_ring[slot];
        if (entry->serial == serial &&
            entry->command_buffer == (uintptr_t)command_buffer) {
            matched_serial = serial;
            matched_entry = entry;
            break;
        }
    }
    unsigned saved = 0;
    if (manifest) fprintf(manifest,
        "reason=%s pid=%d command_buffer=%p requested_serial=%llu "
        "matched_serial=%llu "
        "oldest=%llu newest=%llu\n",
        reason ?: "(nil)", getpid(), command_buffer,
        (unsigned long long)requested_serial,
        (unsigned long long)matched_serial,
        (unsigned long long)oldest, (unsigned long long)newest);
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        unsigned slot = (unsigned)((serial - 1) % MACWS_SUBMIT_RING_COUNT);
        struct macws_submit_ring_entry *entry =
            &g_macws_submit_ring[slot];
        if (entry->serial != serial) continue;
        if (manifest) fprintf(manifest,
            "serial=%llu life_event_serial=%llu "
            "sequence=%u descriptor=%u fixed=%u "
            "descriptor_pointer=%#llx command_buffer=%#llx storage=%#llx "
            "matched=%s marked=%s serial_marked=%s "
            "pre_commands=%zu pre_segments=%zu "
            "post_commands=%zu post_segments=%zu\n",
            (unsigned long long)entry->serial,
            (unsigned long long)entry->life_event_serial, entry->sequence,
            entry->descriptor, entry->fixed,
            (unsigned long long)entry->descriptor_pointer,
            (unsigned long long)entry->command_buffer,
            (unsigned long long)entry->storage,
            (requested_serial
                ? entry->serial == requested_serial
                : entry->command_buffer == (uintptr_t)command_buffer)
                ? "YES" : "NO",
            macws_submit_ring_is_marked(entry->command_buffer)
                ? "YES" : "NO",
            macws_submit_ring_serial_is_marked(entry->serial)
                ? "YES" : "NO",
            entry->pre_commands_length, entry->pre_segments_length,
            entry->post_commands_length, entry->post_segments_length);

        struct {
            const char *phase;
            const char *kind;
            const unsigned char *bytes;
            size_t length;
        } files[] = {
            {"pre", "kcmd", entry->pre_commands,
                entry->pre_commands_length},
            {"pre", "segments", entry->pre_segments,
                entry->pre_segments_length},
            {"post", "kcmd", entry->post_commands,
                entry->post_commands_length},
            {"post", "segments", entry->post_segments,
                entry->post_segments_length},
        };
        // Retain all metadata, but write bytes only for the exact matching
        // descriptor owner plus the most recent 64 submits.  A 2048-entry
        // in-memory window is needed because WindowServer can have roughly
        // 1000 producers outstanding before Metal reports the first error;
        // writing four files for every entry would distort that timing and
        // needlessly consume the chroot filesystem.
        BOOL write_bytes =
            (requested_serial && entry->serial == requested_serial) ||
            entry->command_buffer == (uintptr_t)command_buffer ||
            // Large translated compositor batches are rare, and an earlier
            // clean batch is the strongest control for a later batch of the
            // same shape that page-faults.  Save them directly instead of
            // relying on the shared 32-slot tile mark ring, whose entries can
            // be evicted during the roughly 100 submissions between control
            // and fault.
            entry->fixed >= 8 ||
            macws_submit_ring_is_marked(entry->command_buffer) ||
            macws_submit_ring_serial_is_marked(entry->serial) ||
            serial + 64 > newest;
        for (size_t i = 0; write_bytes &&
             i < sizeof(files) / sizeof(files[0]); i++) {
            if (!files[i].bytes || !files[i].length) continue;
            char path[PATH_MAX];
            snprintf(path, sizeof(path),
                "%s/s%llu_q%u_d%u_%s_%s.bin", directory,
                (unsigned long long)entry->serial, entry->sequence,
                entry->descriptor, files[i].phase, files[i].kind);
            macws_submit_ring_write_file(
                path, files[i].bytes, files[i].length);
        }
        saved++;
    }
    macws_agx_life_dump_snapshot(directory,
        matched_entry ? matched_entry->post_commands : NULL,
        matched_entry ? matched_entry->post_commands_length : 0);
    if (manifest) fclose(manifest);
    pthread_mutex_unlock(&g_macws_submit_ring_lock);
    fprintf(stderr,
        "#### AGX_SUBMIT_RING dumped reason=%s commandBuffer=%p entries=%u "
        "range=%llu..%llu path=%s\n",
        reason ?: "(nil)", command_buffer, saved,
        (unsigned long long)oldest,
        (unsigned long long)newest, directory);
}

__attribute__((used, visibility("default")))
void macws_dump_recent_agx_submits(const char *reason,
                                   const void *command_buffer) {
    macws_dump_recent_agx_submits_impl(reason, command_buffer, 0);
}

__attribute__((used, visibility("default")))
void macws_dump_recent_agx_submit_serial(const char *reason,
                                         const void *command_buffer,
                                         uint64_t submit_serial) {
    macws_dump_recent_agx_submits_impl(
        reason, command_buffer, submit_serial);
}

// Low-disturbance first-error flight recorder for high-rate Chromium submits.
//
// The older /tmp/macws_submit_ring recorder intentionally retains complete
// pre/post command and segment blobs, but it does so with four heap operations
// while holding one process-wide mutex for every descriptor.  A runtime CPU
// sample from the VS Code GPU process caught macws_submit_ring_begin on that
// hot path, and the first 0x102 error reproducibly disappeared when the deep
// ring was enabled.  That makes the deep ring unsuitable for finding a timing-
// sensitive high-concurrency failure.
//
// /tmp/macws_submit_fast_ring selects this separate recorder.  Its producer
// path has no allocation, file I/O, or mutex: a descriptor copies only its
// post-translation bytes into a preallocated slot.  The error observer freezes
// the recorder before reading it, waits for every in-flight producer to leave,
// and only then writes the first snapshot.  The bounded payload is deliberate:
// existing VS Code failure witnesses are 0x858-byte commands with 0x188-byte
// segment lists, while the larger multi-record batches remain represented by
// their full lengths and a truncated prefix.
// Chromium's 60,000-fish workload runtime-captured a 21-segment submission
// with 0x4a58 command bytes and a 0x3270 resource list.  The former
// 0x3000/0x1000 caps truncated both before the first error could be decoded.
// The VS Code Simple Browser Aquarium follow-up reached a 13-segment,
// post-translation 0x69e8-byte KCMD; the 0x6000 cap then hid its last two
// records and wrapper. Keep the diagnostic footprint bounded by trading
// history depth for complete payload width:
// A later VS Code raw IOGPU completion witness exposed the next local limit:
// its failing command-buffer storage had start=0x12958c000 and
// current=0x1295a34c0 (0x174c0 command bytes), plus an 0x8000-byte segment
// list.  The old inspector rejected every KCMD over 0x10000 before either
// translation or recording, so that submit reached iOS with all macOS ABI
// records untouched and the completion returned 0x103.  This 64-KiB boundary
// was ours, not IOGPU's: RE of the exact iOS 16.3
// IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer shows the storage
// doubling below 2 MiB and then growing in 1-MiB increments.
//
// Preserve the same 18-MiB explicit-diagnostic footprint while exchanging
// history depth for enough width to hold the complete observed batch:
// 48 * (0x40000 + 0x20000) = 18 MiB.  The inspector and translator remain
// bounded; these are evidence-backed workload ceilings, not protocol claims.
// The pages are written only when /tmp/macws_submit_fast_ring explicitly
// enables this diagnostic recorder; production preflight removes that flag.



struct macws_fast_submit_entry
    g_macws_fast_submit_ring[MACWS_FAST_SUBMIT_RING_COUNT];
_Atomic int g_macws_fast_submit_enabled = -1;
_Atomic int g_macws_fast_submit_frozen = 0;
_Atomic unsigned g_macws_fast_submit_active = 0;
_Atomic unsigned g_macws_fast_submit_dump_count = 0;
_Atomic uint64_t g_macws_fast_submit_serial = 0;

int macws_fast_submit_is_enabled(void) {
    int enabled = atomic_load_explicit(
        &g_macws_fast_submit_enabled, memory_order_acquire);
    if (enabled >= 0) return enabled;
    int detected = getenv("MACWS_SUBMIT_FAST_RING") != NULL ||
        access("/tmp/macws_submit_fast_ring", F_OK) == 0;
    int expected = -1;
    atomic_compare_exchange_strong_explicit(
        &g_macws_fast_submit_enabled, &expected, detected,
        memory_order_release, memory_order_relaxed);
    return atomic_load_explicit(
        &g_macws_fast_submit_enabled, memory_order_acquire);
}

struct macws_fast_submit_token macws_fast_submit_begin(
        unsigned sequence, unsigned descriptor,
        uintptr_t descriptor_pointer, uintptr_t command_buffer,
        uintptr_t storage) {
    struct macws_fast_submit_token token = {0};
    if (!macws_fast_submit_is_enabled() ||
        atomic_load_explicit(&g_macws_fast_submit_frozen,
                             memory_order_acquire)) {
        return token;
    }

    atomic_fetch_add_explicit(&g_macws_fast_submit_active, 1,
                              memory_order_acq_rel);
    // Close the race with the error thread: once frozen is published, that
    // thread waits for this active count before touching any non-atomic slot
    // payload.  A producer that entered concurrently simply backs out.
    if (atomic_load_explicit(&g_macws_fast_submit_frozen,
                             memory_order_acquire)) {
        atomic_fetch_sub_explicit(&g_macws_fast_submit_active, 1,
                                  memory_order_acq_rel);
        return token;
    }

    token.serial = atomic_fetch_add_explicit(
        &g_macws_fast_submit_serial, 1, memory_order_relaxed) + 1;
    token.life_event_serial = macws_agx_life_current_event_serial();
    token.slot = (unsigned)((token.serial - 1) %
                            MACWS_FAST_SUBMIT_RING_COUNT);
    token.sequence = sequence;
    token.descriptor = descriptor;
    token.descriptor_pointer = descriptor_pointer;
    token.command_buffer = command_buffer;
    token.storage = storage;
    token.active = 1;
    return token;
}

void macws_fast_submit_finish(
        struct macws_fast_submit_token token, unsigned fixed,
        const unsigned char *commands, size_t commands_length,
        const unsigned char *segments, size_t segments_length) {
    if (!token.active) return;
    struct macws_fast_submit_entry *entry =
        &g_macws_fast_submit_ring[token.slot];
    uint64_t writing_guard = token.serial * 2 + 1;
    atomic_store_explicit(&entry->guard, writing_guard,
                          memory_order_release);

    entry->life_event_serial = token.life_event_serial;
    entry->sequence = token.sequence;
    entry->descriptor = token.descriptor;
    atomic_store_explicit(&entry->fixed, fixed, memory_order_relaxed);
    entry->descriptor_pointer = token.descriptor_pointer;
    entry->storage = token.storage;
    entry->commands_length = commands_length;
    entry->commands_saved = commands && commands_length
        ? (commands_length < MACWS_FAST_SUBMIT_COMMAND_CAP
            ? commands_length : MACWS_FAST_SUBMIT_COMMAND_CAP) : 0;
    entry->segments_length = segments_length;
    entry->segments_saved = segments && segments_length
        ? (segments_length < MACWS_FAST_SUBMIT_SEGMENT_CAP
            ? segments_length : MACWS_FAST_SUBMIT_SEGMENT_CAP) : 0;
    if (entry->commands_saved)
        memcpy(entry->commands, commands, entry->commands_saved);
    if (entry->segments_saved)
        memcpy(entry->segments, segments, entry->segments_saved);

    atomic_store_explicit(&entry->command_buffer, token.command_buffer,
                          memory_order_relaxed);
    atomic_store_explicit(&entry->serial, token.serial,
                          memory_order_relaxed);
    atomic_store_explicit(&entry->guard, token.serial * 2,
                          memory_order_release);
    atomic_fetch_sub_explicit(&g_macws_fast_submit_active, 1,
                              memory_order_acq_rel);
}

__attribute__((used, visibility("default")))
uint64_t macws_fast_latest_agx_submit_serial(const void *command_buffer) {
    if (!command_buffer || !macws_fast_submit_is_enabled()) return 0;
    uint64_t newest = atomic_load_explicit(
        &g_macws_fast_submit_serial, memory_order_acquire);
    uint64_t oldest = newest > MACWS_FAST_SUBMIT_RING_COUNT
        ? newest - MACWS_FAST_SUBMIT_RING_COUNT + 1 : 1;
    for (uint64_t serial = newest; serial >= oldest && serial != 0; serial--) {
        struct macws_fast_submit_entry *entry =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        uint64_t guard_before = atomic_load_explicit(
            &entry->guard, memory_order_acquire);
        if (guard_before != serial * 2) continue;
        uint64_t entry_serial = atomic_load_explicit(
            &entry->serial, memory_order_relaxed);
        uintptr_t entry_command_buffer = atomic_load_explicit(
            &entry->command_buffer, memory_order_relaxed);
        uint64_t guard_after = atomic_load_explicit(
            &entry->guard, memory_order_acquire);
        if (guard_before == guard_after && entry_serial == serial &&
            entry_command_buffer == (uintptr_t)command_buffer) {
            return serial;
        }
    }
    return 0;
}

__attribute__((used, visibility("default")))
unsigned macws_fast_agx_submit_fixed_count(uint64_t submit_serial) {
    if (!submit_serial || !macws_fast_submit_is_enabled()) return 0;
    struct macws_fast_submit_entry *entry =
        &g_macws_fast_submit_ring[(submit_serial - 1) %
                                  MACWS_FAST_SUBMIT_RING_COUNT];
    uint64_t guard_before = atomic_load_explicit(
        &entry->guard, memory_order_acquire);
    if (guard_before != submit_serial * 2) return 0;
    unsigned fixed = atomic_load_explicit(&entry->fixed,
                                          memory_order_relaxed);
    uint64_t guard_after = atomic_load_explicit(
        &entry->guard, memory_order_acquire);
    return guard_before == guard_after ? fixed : 0;
}

__attribute__((used, visibility("default")))
void macws_dump_fast_agx_submit_serial(const char *reason,
                                       const void *command_buffer,
                                       uint64_t requested_serial) {
    if (!macws_fast_submit_is_enabled()) return;
    unsigned dump = atomic_fetch_add_explicit(
        &g_macws_fast_submit_dump_count, 1, memory_order_acq_rel) + 1;
    if (dump != 1) return;

    atomic_store_explicit(&g_macws_fast_submit_frozen, 1,
                          memory_order_release);
    unsigned waits = 0;
    while (atomic_load_explicit(&g_macws_fast_submit_active,
                                memory_order_acquire) != 0 && waits < 500) {
        usleep(1000);
        waits++;
    }
    unsigned active = atomic_load_explicit(
        &g_macws_fast_submit_active, memory_order_acquire);
    if (active != 0) {
        fprintf(stderr,
            "#### AGX_FAST_RING freeze timed out reason=%s active=%u "
            "waited_ms=%u; refusing a racy payload dump\n",
            reason ?: "(nil)", active, waits);
        return;
    }

    uint64_t newest = atomic_load_explicit(
        &g_macws_fast_submit_serial, memory_order_acquire);
    uint64_t oldest = newest > MACWS_FAST_SUBMIT_RING_COUNT
        ? newest - MACWS_FAST_SUBMIT_RING_COUNT + 1 : 1;
    uint64_t matched_serial = 0;
    struct macws_fast_submit_entry *matched_entry = NULL;
    if (requested_serial >= oldest && requested_serial <= newest) {
        struct macws_fast_submit_entry *candidate =
            &g_macws_fast_submit_ring[(requested_serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&candidate->serial,
                                 memory_order_relaxed) == requested_serial) {
            matched_serial = requested_serial;
            matched_entry = candidate;
        }
    }
    for (uint64_t serial = newest;
         !matched_entry && serial >= oldest && serial != 0; serial--) {
        struct macws_fast_submit_entry *candidate =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&candidate->serial,
                                 memory_order_relaxed) == serial &&
            atomic_load_explicit(&candidate->command_buffer,
                                 memory_order_relaxed) ==
                (uintptr_t)command_buffer) {
            matched_serial = serial;
            matched_entry = candidate;
            break;
        }
    }

    char directory[PATH_MAX];
    snprintf(directory, sizeof(directory),
             "/tmp/macws_fast_submit_error_%d_%u", getpid(), dump);
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr,
            "#### AGX_FAST_RING dump mkdir failed path=%s errno=%d\n",
            directory, errno);
        return;
    }
    char manifest_path[PATH_MAX];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.txt",
             directory);
    FILE *manifest = fopen(manifest_path, "w");
    if (manifest) {
        fprintf(manifest,
            "reason=%s pid=%d command_buffer=%p requested_serial=%llu "
            "matched_serial=%llu oldest=%llu newest=%llu "
            "freeze_wait_ms=%u\n",
            reason ?: "(nil)", getpid(), command_buffer,
            (unsigned long long)requested_serial,
            (unsigned long long)matched_serial,
            (unsigned long long)oldest, (unsigned long long)newest, waits);
    }

    unsigned entries = 0;
    unsigned byte_entries = 0;
    unsigned same_shape_controls = 0;
    size_t matched_commands_length = matched_entry
        ? matched_entry->commands_length : 0;
    size_t matched_segments_length = matched_entry
        ? matched_entry->segments_length : 0;
    unsigned matched_fixed = matched_entry ? atomic_load_explicit(
        &matched_entry->fixed, memory_order_relaxed) : 0;
    for (uint64_t serial = oldest; serial <= newest; serial++) {
        struct macws_fast_submit_entry *entry =
            &g_macws_fast_submit_ring[(serial - 1) %
                                      MACWS_FAST_SUBMIT_RING_COUNT];
        if (atomic_load_explicit(&entry->serial,
                                 memory_order_relaxed) != serial) continue;
        entries++;
        BOOL exact = serial == matched_serial;
        BOOL same_shape = matched_entry && serial < matched_serial &&
            entry->commands_length == matched_commands_length &&
            entry->segments_length == matched_segments_length &&
            atomic_load_explicit(&entry->fixed, memory_order_relaxed) ==
                matched_fixed && same_shape_controls < 8;
        BOOL recent = serial + 16 > newest;
        BOOL write_bytes = exact || same_shape || recent;
        if (same_shape) same_shape_controls++;
        if (manifest) {
            fprintf(manifest,
                "serial=%llu life_event_serial=%llu sequence=%u "
                "descriptor=%u fixed=%u descriptor_pointer=%#llx "
                "command_buffer=%#llx storage=%#llx matched=%s "
                "same_shape=%s commands=%zu saved=%zu truncated=%s "
                "segments=%zu saved=%zu truncated=%s\n",
                (unsigned long long)serial,
                (unsigned long long)entry->life_event_serial,
                entry->sequence, entry->descriptor,
                atomic_load_explicit(&entry->fixed, memory_order_relaxed),
                (unsigned long long)entry->descriptor_pointer,
                (unsigned long long)atomic_load_explicit(
                    &entry->command_buffer, memory_order_relaxed),
                (unsigned long long)entry->storage,
                exact ? "YES" : "NO", same_shape ? "YES" : "NO",
                entry->commands_length, entry->commands_saved,
                entry->commands_saved < entry->commands_length ? "YES" : "NO",
                entry->segments_length, entry->segments_saved,
                entry->segments_saved < entry->segments_length ? "YES" : "NO");
        }
        if (!write_bytes) continue;
        char path[PATH_MAX];
        if (entry->commands_saved) {
            snprintf(path, sizeof(path), "%s/s%llu_q%u_d%u_post_kcmd.bin",
                directory, (unsigned long long)serial,
                entry->sequence, entry->descriptor);
            macws_submit_ring_write_file(
                path, entry->commands, entry->commands_saved);
        }
        if (entry->segments_saved) {
            snprintf(path, sizeof(path),
                "%s/s%llu_q%u_d%u_post_segments.bin",
                directory, (unsigned long long)serial,
                entry->sequence, entry->descriptor);
            macws_submit_ring_write_file(
                path, entry->segments, entry->segments_saved);
        }
        byte_entries++;
    }
    if (manifest) fclose(manifest);
    macws_agx_life_dump_snapshot(directory,
        matched_entry ? matched_entry->commands : NULL,
        matched_entry ? matched_entry->commands_saved : 0);
    fprintf(stderr,
        "#### AGX_FAST_RING dumped reason=%s commandBuffer=%p "
        "requested=%llu matched=%llu entries=%u byteEntries=%u "
        "range=%llu..%llu path=%s\n",
        reason ?: "(nil)", command_buffer,
        (unsigned long long)requested_serial,
        (unsigned long long)matched_serial, entries, byte_entries,
        (unsigned long long)oldest, (unsigned long long)newest, directory);
}

uint64_t macws_strip_user_pointer(uint64_t raw) {
    return raw & 0x0000ffffffffffffULL;
}

int macws_plausible_agx_pointer(uint64_t raw, size_t bytes) {
    uint64_t p = macws_strip_user_pointer(raw);
    // The previous upper bound (0x280000000) happened to cover
    // WindowServer's allocator zones, but it is not an IOGPU ABI boundary.
    // Runtime LLDB capture from VS Code 1.130 / Chromium 148 showed the live
    // selector-0x1e descriptor chain in readable GPU-process regions at
    // 0x601128040 -> command buffer 0x601be1c00 -> storage 0x6001adc00.
    // Rejecting those ordinary 0x600... heap addresses made the existing
    // structurally validated KCMD translator silently skip every Chromium
    // submission.  Keep a bounded process-user range and retain the overflow
    // and per-object size checks; downstream descriptor/self/storage anchors
    // still have to validate before any byte is inspected or translated.
    const uint64_t user_limit = 0x800000000ULL;
    return p >= 0x100000000ULL && p < user_limit &&
        bytes <= 0x10000 && p + bytes >= p && p + bytes <= user_limit;
}

void macws_submit_hex(const char *what, unsigned sequence,
                             const unsigned char *p, size_t length) {
    fprintf(stderr, "#### AGX_SUBMIT_DIAG #%u %s bytes=%#zx\n",
        sequence, what, length);
    for (size_t off = 0; off < length; off += 32) {
        fprintf(stderr, "####   +%04zx:", off);
        for (size_t j = 0; j < 32 && off + j < length; j++)
            fprintf(stderr, " %02x", p[off + j]);
        fprintf(stderr, "\n");
    }
}

void macws_submit_save_type1(unsigned sequence, unsigned record,
                                    const unsigned char *p, size_t length) {
    if (!p || length < 0x38 || length > 0x10000) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_type1_%u_%u.bin", sequence, record);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u record[%u] save %s failed errno=%d\n",
            sequence, record, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u record[%u] saved=%#zx/%#zx path=%s errno=%d\n",
        sequence, record, written, length, path,
        written == length ? 0 : saved_errno);
}

void macws_submit_save_kcmd(unsigned sequence, unsigned descriptor,
                                   const char *phase,
                                   const unsigned char *p, size_t length) {
    if (!phase || !p || length < 0x38 ||
        length > MACWS_AGX_KCMD_INSPECT_MAX) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_kcmd_%u_%u_%s.bin", sequence, descriptor, phase);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD-%s save %s "
            "failed errno=%d\n",
            sequence, descriptor, phase, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD-%s "
        "saved=%#zx/%#zx path=%s errno=%d\n",
        sequence, descriptor, phase, written, length, path,
        written == length ? 0 : saved_errno);
}

void macws_submit_save_segment_list(unsigned sequence,
                                           unsigned descriptor,
                                           const unsigned char *p,
                                           size_t length) {
    if (!p || length < 0x10 ||
        length > MACWS_AGX_SEGMENT_INSPECT_MAX) return;

    char path[PATH_MAX];
    int path_length = snprintf(path, sizeof(path),
        "/tmp/macws_submit_segment_%u_%u.bin", sequence, descriptor);
    if (path_length <= 0 || (size_t)path_length >= sizeof(path)) return;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment save %s "
            "failed errno=%d\n",
            sequence, descriptor, path, errno);
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, p + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    int saved_errno = errno;
    close(fd);
    fprintf(stderr,
        "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment saved=%#zx/%#zx "
        "path=%s errno=%d\n",
        sequence, descriptor, written, length, path,
        written == length ? 0 : saved_errno);
}

int macws_submit_bytes_are_zero(const unsigned char *p,
                                       size_t length) {
    for (size_t i = 0; i < length; i++) {
        if (p[i] != 0) return 0;
    }
    return 1;
}

// DIAGNOSTIC-ONLY semantic-field A/B for the macOS-13.4 -> iOS-16.3
// subtype-1 command ABI.  This is deliberately not part of the default KCMD
// normalizer and is not a fix.
//
// Runtime hardware-watchpoint evidence from the exact 1140x798 PF550 control:
//
//   native iOS 16.3 AGX, normalized record+0x3a0:
//     0x221ac9618 ldr w9, [x20, #0xa4]   ; runtime value 4
//     0x221ac961c str w9, [x8]
//
//   macOS 13.4 AGX, original record+0x3b0 (normalized +0x3a0):
//     0x1ee0cf3a4 ldr x9, [x19, #0x570]
//     0x1ee0cf3a8 bfxil x9, x8, #1, #6
//     0x1ee0cf3b4 str x9, [x8, #0x378]   ; runtime value 8
//
// The macOS function has no counterpart to the following native iOS +0xa4
// store.  The experiment tests only whether this one proven producer-version
// delta explains the first multi-segment PageFault.  A positive result still
// requires locating/deriving the native field semantically before shipping.
void macws_subtype1_field_a4_diagnostic(unsigned sequence,
                                                unsigned segment,
                                                unsigned char *record) {
    if (!record ||
        !macws_kcmd_field_a4_diag_enabled())
        return;

    uint32_t old_value = *(uint32_t *)(record + 0x3a0);
    if (old_value != 8)
        return;

    uint32_t width = *(uint32_t *)(record + 0x3b0);
    uint32_t height = *(uint32_t *)(record + 0x3b4);
    *(uint32_t *)(record + 0x3a0) = 4;

    static _Atomic unsigned log_count = 0;
    unsigned observed = atomic_fetch_add(&log_count, 1) + 1;
    if (observed <= 32 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX-KCMD-FIELD-A4-DIAG #%u segment=%u "
            "normalized+0x3a0=%u->4 target=%ux%u observed=%u\n",
            sequence, segment, old_value, width, height, observed);
    }
}

// DIAGNOSTIC-ONLY A/B for two additional subtype-1 semantic fields.  These
// switches test causality; they are not ABI fixes and remain inert unless the
// matching sentinel exists.
//
// normalized record+0x5e3:
//   macOS 13.4 copies byte 8 of q0 from state+0xed0 through [sp+0x80], then
//   stores that byte at original record+0x603 (normalized +0x5e3).  Runtime
//   hardware-watchpoint evidence measured 1.  iOS 16.3 computes the
//   corresponding field from state+0xbc2 and the exact native PF550 control
//   contains zero.
//
// normalized record+0x6bc:
//   Both actual binaries compute state+0xbec identically as
//       (state_word_at_0x178 >> 16) & 0x1ff
//   and copy it into the command record.  Runtime captures measured 16 for
//   macOS and 8 for the exact native 1140x798 PF550 control.  Because this is
//   a real upstream state difference rather than a layout mismatch, forcing
//   it is especially unsuitable for production; the experiment only answers
//   whether that difference participates in the current PageFault.
void macws_subtype1_semantic_field_diagnostic(
    unsigned sequence, unsigned segment, unsigned char *record) {
    if (!macws_runtime_diagnostics_enabled())
        return;
    macws_subtype1_field_a4_diagnostic(sequence, segment, record);
    if (!record)
        return;

    BOOL test5e3 =
        macws_kcmd_field_5e3_diag_enabled();
    BOOL test6bc =
        macws_kcmd_field_6bc_diag_enabled();
    unsigned char old5e3 = record[0x5e3];
    uint32_t old6bc = *(uint32_t *)(record + 0x6bc);
    BOOL changed5e3 = test5e3 && old5e3 == 1;
    BOOL changed6bc = test6bc && old6bc == 16;
    if (changed5e3)
        record[0x5e3] = 0;
    if (changed6bc)
        *(uint32_t *)(record + 0x6bc) = 8;
    if (!test5e3 && !test6bc)
        return;

    static _Atomic unsigned log_count = 0;
    unsigned observed = atomic_fetch_add(&log_count, 1) + 1;
    if (observed <= 32 || (observed & (observed - 1)) == 0) {
        fprintf(stderr,
            "#### AGX-KCMD-SEMANTIC-FIELD-DIAG #%u segment=%u "
            "+0x5e3=%u%s +0x603=%u +0x6bc=%u%s +0x6dc=%u "
            "observed=%u\n",
            sequence, segment, old5e3, changed5e3 ? "->0" : "",
            record[0x603], old6bc, changed6bc ? "->8" : "",
            *(uint32_t *)(record + 0x6dc), observed);
    }
}

// Validated ABI translation for the wrapped single-segment form.  It remains
// behind the explicit /tmp/macws_kcmd_wrapped_fix experimental-mode gate.
//
// Project LLDB stopped at the first non-InnocentVictim IOGPU completion on
// 2026-07-26, before IOGPUMetalCommandBuffer released its storage.  The raw
// callback error was 0x102 and the submitted CoreAnimation command had:
//
//   KCMD 0x868 bytes:
//     +0x00 type=9, span=0x10, count=1       (wrapper)
//     +0x10 type=0x10000, span=0x858         (known subtype-1 segment)
//   segment list 0x148 bytes:
//     +0x08 count=1, +0x0c=0x40000001       (wrapper)
//     +0x14 nested-list offset=0x10
//     +0x20 count=1, +0x24=0x80000130       (known inner list)
//     +0x30 range=[0x10,0x868)
//
// Artifacts `/tmp/macws-raw102-{kcmd,segments}-20260726.bin` have SHA-256
// 486bd31db1f26b541bd40fb2b4b8eba4f33178ac8bb750ebf569646a2ec7fe87
// and 17c887655f3d4c649203f4a23a2182de7f45f716c8409a99ba481dca01887597.
// The old normalizer required the vendor record at KCMD offset zero and a
// top-level 0x130-byte list, so it skipped this command completely.  The first
// A/B normalized the nested record while retaining both wrappers: that
// removed parser error 0x102 but exposed a repeatable ProtectionViolation.
// The 2026-07-29 native-layout A/B below identified the retained macOS wrapper
// as the remaining mismatch and supplied output/completion/input witnesses.
unsigned macws_translate_agx_wrapped_single_subtype1(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t *segment_length_io) {
    size_t segment_length = segment_length_io ? *segment_length_io : 0;
    if (!commands || !total_io || !segment_list ||
        *total_io != 0x868 || segment_length != 0x148)
        return 0;

    size_t total = *total_io;
    unsigned char *record = commands + 0x10;
    int wrapper_ok =
        *(uint32_t *)(commands + 0x00) == 9 &&
        *(uint32_t *)(commands + 0x04) == 0x10 &&
        *(uint32_t *)(commands + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x0c) == 0x40000001 &&
        *(uint32_t *)(segment_list + 0x14) == 0x10 &&
        *(uint32_t *)(segment_list + 0x20) == 1 &&
        *(uint32_t *)(segment_list + 0x24) == 0x80000130 &&
        *(uint32_t *)(segment_list + 0x30) == 0x10 &&
        *(uint32_t *)(segment_list + 0x34) == total;
    int subtype1_ok =
        *(uint32_t *)(record + 0x00) == 0x10000 &&
        *(uint32_t *)(record + 0x04) == 0x858 &&
        *(uint32_t *)(record + 0x28) == 0x818 &&
        *(uint32_t *)(record + 0x2c) == 0x7e8 &&
        *(uint32_t *)(record + 0x30) == 0x30 &&
        *(uint32_t *)(record + 0x34) == 1 &&
        memcmp(record + 0xd8,
            "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
        macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
        *(uint32_t *)(record + 0x1e0) == 1 &&
        *(uint32_t *)(record + 0x1e8) == 0x1c &&
        memcmp(record + 0x1f8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0 &&
        macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
        *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
        (*(uint32_t *)(record + 0x4d4) == 0x100 ||
         *(uint32_t *)(record + 0x4d4) == 0x300) &&
        memcmp(record + 0x4e8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0;
    if (!wrapper_ok || !subtype1_ok)
        return 0;

    // Delete the same two macOS-only windows proven for the unwrapped form.
    // First move the complete storage tail so no bytes are lost while the two
    // windows overlap; the wrapper-specific 0x18-byte suffix is removed only
    // by the independently validated flattening step below.  Work from the
    // higher original offset downward.
    memmove(record + 0x4c0, record + 0x4d0,
            total - (0x10 + 0x4d0));
    total -= 0x10;
    memmove(record + 0x1c0, record + 0x1d0,
            total - (0x10 + 0x1d0));
    total -= 0x10;
    memset(commands + total, 0, 0x20);

    *(uint32_t *)(record + 0x04) = 0x838;
    *(uint32_t *)(record + 0x28) = 0x7f8;
    *(uint32_t *)(record + 0x2c) = 0x7c8;
    macws_subtype1_semantic_field_diagnostic(sequence, 0, record);

    // The exact iOS-native PF550 control captured with the project LLDB on
    // 2026-07-29 is a direct subtype-1 KCMD of 0x820 bytes and a direct
    // 0x130-byte segment list
    // (SHA-256 b0e11e0d0177749a... / ffb991a1c94f9b4e...).  The failing
    // WindowServer submit has the same normalized record end (0x7f8), but
    // carries a 0x10 type-9 leading wrapper, a 0x18 larger record trailer,
    // and the matching 0x18 segment-list wrapper.  Runtime-confirmed A/B on
    // the actual arm64 WindowServer: retaining the wrappers produced 68
    // ProtectionViolation observations in the first bounded sample;
    // flattening exactly these three framing differences produced zero, then
    // delivered 4,200/4,200 clean PF80 VNC-copy completions, a full Retina
    // Terminal frame, and 16/16 visibly acknowledged keyboard events.  This
    // is protocol translation to the observed iOS-native layout, not an error
    // or completion bypass.
    memmove(commands, record, 0x820);
    memset(commands + 0x820, 0, total - 0x820);
    *(uint32_t *)(commands + 0x04) = 0x820;

    memmove(segment_list, segment_list + 0x18, 0x130);
    memset(segment_list + 0x130, 0, 0x18);
    *(uint32_t *)(segment_list + 0x18) = 0;
    *(uint32_t *)(segment_list + 0x1c) = 0x820;
    *segment_length_io = 0x130;
    total = 0x820;
    *total_io = total;

    // CA_VSYNC_OFF can submit this command continuously while a consumer is
    // connected.  Keep enough witnesses to prove the path remains active,
    // without turning the diagnostic itself into a stderr/CPU storm.
    if (macws_runtime_diagnostics_enabled()) {
        static unsigned match_count;
        unsigned observed =
            __atomic_add_fetch(&match_count, 1, __ATOMIC_RELAXED);
        if (observed <= 4 || (observed & (observed - 1)) == 0) {
            fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-WRAPPED-FIX match=%u "
                "type9=0x10 subtype1@0x10 span=0x858->0x838 "
                "range=0x10..0x868->0x848 storage=0x868->0x848 "
                "flatten=iOS-direct final=0x%zx\n",
                sequence, observed, total);
        }
    }
    return 1;
}

// TEMPORARY ABI-TRANSLATION EXPERIMENT for Chromium's trailing-wrapper form.
//
// The raw IOGPU callback correlated VS Code submit serial 2 with
// MTLCommandBufferErrorDomain/1 and internal status 0x102.  Its retained
// pre-submit artifacts (SHA-256 KCMD
// 8df48a8ed24efd35bf27a4623d182214c303d6e983138159b37f58da9a060820,
// segment list
// 6ab4552a490b4eecfc5fca1456d18212deae23be580a9c91f185845d9f82189d)
// have a third framing variant:
//
//   KCMD 0x858 or 0x870 bytes:
//     +0x000 subtype-1 span 0x840 (known macOS record + trailer)
//     +0x840 one or two 0x18-byte type-3 wrapper records
//   segment list (captured sizes 0x148 and 0x188 bytes):
//     +0x008 inner count=1, encoded length=L, range=[0,0x840)
//     +L trailing wrapper, range=[0x840,total)
//
// A later Chromium GPU-process capture (submit serial 18, retained under
// docs/evidence/vscode-trailing-wrapper-fix-20260728-2105) has the exact
// same command framing with L=0x170 instead of 0x130.  The intervening bytes
// are resource-list payload, so validate L and the wrapper record rather than
// assuming one fixed resource count.
//
// The existing direct translator rejected it because the complete KCMD span
// is deliberately larger than the inner subtype-1 range.  Preserve the two
// wrapper records byte-for-byte, normalize only the same two RE-confirmed
// macOS-only subtype-1 padding windows, then shift both exact ranges.  This is
// diagnostic scaffolding under /tmp/macws_kcmd_wrapped_fix, not a claim that
// type-3 wrapper semantics have been fully reconstructed.
unsigned macws_translate_agx_trailing_wrapped_subtype1(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t segment_length) {
    if (!commands || !total_io || !segment_list ||
        (*total_io != 0x858 && *total_io != 0x870) ||
        segment_length < 0x38)
        return 0;

    size_t total = *total_io;
    unsigned char *record = commands;
    uint32_t list_magic = *(uint32_t *)(segment_list + 0x00);
    uint32_t encoded_length = *(uint32_t *)(segment_list + 0x0c);
    if (encoded_length < 0x20 ||
        (size_t)encoded_length + 0x18 != segment_length)
        return 0;
    unsigned char *wrapper_list = segment_list + encoded_length;
    uint32_t wrapper_opcode = *(uint32_t *)(commands + 0x848);
    uint32_t list_generation = *(uint32_t *)(segment_list + 0x04);
    unsigned wrapper_count = (unsigned)((total - 0x840) / 0x18);
    int wrapper_records_ok = wrapper_count >= 1 && wrapper_count <= 2;
    for (unsigned i = 0; wrapper_records_ok && i < wrapper_count; i++) {
        size_t offset = 0x840 + (size_t)i * 0x18;
        wrapper_records_ok =
            *(uint32_t *)(commands + offset + 0x00) == 3 &&
            *(uint32_t *)(commands + offset + 0x04) == 0x18 &&
            *(uint32_t *)(commands + offset + 0x08) == wrapper_opcode;
    }
    int wrapper_ok =
        *(uint32_t *)(segment_list + 0x08) == 1 &&
        *(uint32_t *)(segment_list + 0x18) == 0 &&
        *(uint32_t *)(segment_list + 0x1c) == 0x840 &&
        *(uint32_t *)(wrapper_list + 0x00) == list_magic &&
        // Runtime-confirmed 2026-07-29 from the exact first failing VS Code
        // submit after a clean restart (KCMD SHA-256 bf14ff937dcf789a...;
        // segment SHA-256 c4ba7fbea0b64f21...).  This dword is not a fixed
        // wrapper type: both the outer list and its trailing record changed
        // together from 2 in every earlier capture to 3 in this capture.
        // The remaining framing stayed identical and the actual blob was
        // 0x148 bytes while list+0x0c remained the base-list offset 0x130.
        // A clean production VS Code 1.130 launch on 2026-07-30 captured the
        // same 0x870 KCMD / 0x148 list shape with both generation fields equal
        // to 4.  The first mapped failure from a genuinely empty profile after
        // reboot captured the identical structure with generation 0, opcode
        // 0x9903 and two type-3 records: fast-ring serial 2 had fixed=0 and
        // then returned 0x102.  The outer/tail generation equality, exact
        // ranges and every other wrapper anchor still match.  A bounded
        // VSCode video reproduction on 2026-08-01 then captured generation 1
        // in both the outer and trailing records with the same exact framing:
        // serial 2 used KCMD 0x870/list 0x148/opcode 0x9b03 and serial 3 used
        // KCMD 0x858/list 0x148/opcode 0x9b03.  The former was the command
        // buffer matched to error 0x102.  All generations 0 through 4 are now
        // runtime-observed; keep the upper bound and every structural anchor.
        list_generation <= 4 &&
        *(uint32_t *)(wrapper_list + 0x04) == list_generation &&
        *(uint32_t *)(wrapper_list + 0x08) == 1 &&
        *(uint32_t *)(wrapper_list + 0x0c) == 0xc0000001 &&
        *(uint32_t *)(wrapper_list + 0x10) == 0x840 &&
        *(uint32_t *)(wrapper_list + 0x14) == total &&
        wrapper_opcode < 0x10000 &&
        wrapper_records_ok;
    int subtype1_ok =
        *(uint32_t *)(record + 0x00) == 0x10000 &&
        *(uint32_t *)(record + 0x04) == 0x840 &&
        *(uint32_t *)(record + 0x28) == 0x818 &&
        *(uint32_t *)(record + 0x2c) == 0x7e8 &&
        *(uint32_t *)(record + 0x30) == 0x30 &&
        *(uint32_t *)(record + 0x34) == 1 &&
        memcmp(record + 0xd8,
            "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
        macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
        *(uint32_t *)(record + 0x1e0) == 1 &&
        *(uint32_t *)(record + 0x1e8) == 0x1c &&
        memcmp(record + 0x1f8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0 &&
        macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
        *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
        (*(uint32_t *)(record + 0x4d4) == 0x100 ||
         *(uint32_t *)(record + 0x4d4) == 0x300) &&
        memcmp(record + 0x4e8,
            "\xff\xff\xff\xff\xff\xff\xff\xff"
            "\xff\xff\xff\xff", 12) == 0;
    if (!wrapper_ok || !subtype1_ok)
        return 0;

    // Delete from high to low so offsets still refer to the captured macOS
    // record. Both moves include the complete 0x30-byte wrapper tail.
    memmove(record + 0x4c0, record + 0x4d0, total - 0x4d0);
    total -= 0x10;
    memmove(record + 0x1c0, record + 0x1d0, total - 0x1d0);
    total -= 0x10;
    memset(commands + total, 0, 0x20);

    *(uint32_t *)(record + 0x04) = 0x820;
    *(uint32_t *)(record + 0x28) = 0x7f8;
    *(uint32_t *)(record + 0x2c) = 0x7c8;
    macws_subtype1_semantic_field_diagnostic(sequence, 0, record);
    *(uint32_t *)(segment_list + 0x1c) = 0x820;
    *(uint32_t *)(wrapper_list + 0x10) = 0x820;
    *(uint32_t *)(wrapper_list + 0x14) = (uint32_t)total;
    *total_io = total;

    if (macws_runtime_diagnostics_enabled()) {
        static _Atomic unsigned match_count = 0;
        unsigned observed = atomic_fetch_add(&match_count, 1) + 1;
        if (observed <= 8 || (observed & (observed - 1)) == 0) {
            fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-TRAILING-WRAPPER-FIX "
                "match=%u subtype1=0..0x840->0..0x820 "
                "wrappers=%u range=0x840..%#zx->0x820..%#zx\n",
                sequence, observed, wrapper_count, total + 0x20, total);
        }
    }
    return 1;
}

// TEMPORARY ABI-TRANSLATION EXPERIMENT for a storage object containing one or
// more validated segments. Runtime capture of WindowServer submit #9 established
// the segment-list framing on this exact iOS 16.3 device:
//
//   list+0x08 = segment count
//   list+0x0c = 0x80000000 | list byte length
//   every KCMD segment starts with type 0x10000 and carries its complete
//   segment span (vendor record plus trailer) at segment+0x04
//   the segment list contains one aligned {start,end} u32 pair per KCMD
//
// The captured two-segment list had ranges [0,0x858) and
// [0x858,0x10b0), and the KCMD storage contained a subtype-1 record at both
// exact starts.  The old linear walker stopped on the first record's trailer,
// so neither segment was translated and the command buffer completed with
// kernel parser error 0x102.  Validate the complete range table before
// changing anything, then work backwards so deleting 0x20 bytes from a later
// segment cannot invalidate an earlier segment's original coordinates.
//
// A later 28-segment compositor capture disproved the initial THEORY that
// every segment-list entry has a fixed 0x120 stride: resource-list payloads
// make the entries variable-sized.  Its header count was 28, the KCMD chain
// contained exactly 28 records, and each derived KCMD range occurred exactly
// once as an 8-byte-aligned {start,end} pair in the actual segment list.
// Use those cross-buffer invariants instead of assuming a C struct stride.
//
// This remains a diagnostic scaffold.  It deliberately handles only the
// already-observed subtype-1, subtype-2 and subtype-3 macOS layouts and is
// still gated
// by /tmp/macws_kcmd_fix at the caller.
//
// The original minimum count of two was correct for the direct-list cases
// that motivated this walker, but too strict for an independently framed
// trailing-wrapper list. Runtime evidence from VS Code GPU-process submit 480
// on 2026-07-30 is exactly one subtype-3 segment followed by one type-3 KCMD
// wrapper: KCMD 0x240, base span/range 0..0x228, list 0x108 with wrapper-list
// offset 0xf0, and matching generation 4 tail range 0x228..0x240. It returned
// 0x103 with fixed=0. Permit count=1 only for that already-validated trailing
// wrapper contract; a direct one-segment list remains owned by the narrower
// linear translator below.

BOOL macws_agx_fragment_entry_length(
    const unsigned char *entry, size_t available,
    size_t *length_out) {
    if (!entry || !length_out || available < 0x20)
        return NO;
    uint32_t resource_count = *(uint32_t *)(entry + 0x18);
    uint32_t group_count = *(uint32_t *)(entry + 0x1c);
    if (group_count > 64 ||
        (size_t)group_count > (SIZE_MAX - 0x20) / 0x40)
        return NO;
    size_t length = 0x20 + (size_t)group_count * 0x40;
    if (length > available)
        return NO;

    uint32_t decoded_resources = 0;
    for (uint32_t group = 0; group < group_count; group++) {
        uint16_t valid = *(uint16_t *)(
            entry + 0x20 + (size_t)group * 0x40 + 0x3e);
        if (valid > 6 || decoded_resources > UINT32_MAX - valid)
            return NO;
        decoded_resources += valid;
    }
    if (decoded_resources != resource_count)
        return NO;
    *length_out = length;
    return YES;
}

// Parse, but do not flatten, the segmented signal-event contract.  A paired
// selector-0x1a capture from this exact iPad/iOS build now proves that native
// IOGPU uses the same framing for both _MTLSharedEvent (type 3) and the legacy
// IOGPUMTLEvent (type 5): one or more descriptor chunks are separated by
// 0x18-byte signal commands and matching 0x18-byte range records.  The legacy
// draw -> signal -> blit -> signal control completed status=4/error=nil with
// KCMD 0xa50 and list 0x250 (SHA-256 8524e33e... / 83899e58...).  Signal
// removal therefore destroys a real synchronization invariant.  Collect the
// vendor and signal range locations so the ordinary ABI translator can shrink
// only vendor records and update every downstream range in place.
BOOL macws_collect_agx_fragmented_list_ranges(
    const unsigned char *commands, size_t total,
    const unsigned char *segment_list, size_t list_length,
    uint32_t *vendor_pair_offsets, uint32_t *vendor_count_out,
    uint32_t *signal_pair_offsets, uint32_t *signal_count_out) {
    if (!commands || !segment_list || !vendor_pair_offsets ||
        !vendor_count_out || !signal_pair_offsets || !signal_count_out ||
        total < 0x100 || list_length < 0x60)
        return NO;

    uint64_t list_token = *(uint64_t *)(segment_list + 0x00);
    uint32_t vendor_count = 0;
    uint32_t signal_count = 0;
    uint32_t fragment_count = 0;
    uint32_t command_cursor = 0;
    size_t list_cursor = 0;

    while (list_cursor + 0x10 <= list_length) {
        const unsigned char *chunk = segment_list + list_cursor;
        if (*(uint64_t *)(chunk + 0x00) != list_token)
            return NO;
        uint32_t count = *(uint32_t *)(chunk + 0x08);
        uint32_t encoded_length = *(uint32_t *)(chunk + 0x0c);
        BOOL terminal_direct = (encoded_length & 0x80000000U) != 0;
        uint32_t chunk_length = encoded_length & 0x7fffffffU;
        if (count < 1 ||
            count > MACWS_AGX_SEGMENT_LIST_MAX_RECORDS - vendor_count ||
            chunk_length < 0x30 ||
            (size_t)chunk_length > list_length - list_cursor)
            return NO;

        size_t entry_cursor = 0x10;
        for (uint32_t index = 0; index < count; index++) {
            size_t entry_length = 0;
            if (!macws_agx_fragment_entry_length(
                    chunk + entry_cursor, chunk_length - entry_cursor,
                    &entry_length))
                return NO;
            const unsigned char *entry = chunk + entry_cursor;
            uint32_t start = *(uint32_t *)(entry + 0x08);
            uint32_t end = *(uint32_t *)(entry + 0x0c);
            if (start != command_cursor || end <= start || end > total ||
                end - start < 0x38 ||
                (*(uint32_t *)(commands + start) != 0x10000 &&
                 *(uint32_t *)(commands + start) != 0x10001) ||
                *(uint32_t *)(commands + start + 0x04) != end - start)
                return NO;
            vendor_pair_offsets[vendor_count++] =
                (uint32_t)(list_cursor + entry_cursor + 0x08);
            command_cursor = end;
            entry_cursor += entry_length;
        }
        if (entry_cursor != chunk_length)
            return NO;
        fragment_count++;
        list_cursor += chunk_length;

        if (terminal_direct) {
            if (list_cursor != list_length)
                return NO;
            break;
        }
        if (list_cursor + 0x18 > list_length ||
            signal_count >= MACWS_AGX_SEGMENT_LIST_MAX_RECORDS)
            return NO;

        const unsigned char *signal_list = segment_list + list_cursor;
        uint32_t signal_flags = *(uint32_t *)(signal_list + 0x0c);
        uint32_t signal_start = *(uint32_t *)(signal_list + 0x10);
        uint32_t signal_end = *(uint32_t *)(signal_list + 0x14);
        if (*(uint64_t *)(signal_list + 0x00) != list_token ||
            *(uint32_t *)(signal_list + 0x08) != 1 ||
            (signal_flags != 0x40000001U &&
             signal_flags != 0xc0000001U) ||
            signal_start != command_cursor ||
            signal_end != signal_start + 0x18 || signal_end > total)
            return NO;

        const unsigned char *signal = commands + signal_start;
        uint32_t signal_type = *(uint32_t *)(signal + 0x00);
        uint32_t event_id = *(uint32_t *)(signal + 0x08);
        if ((signal_type != 3 && signal_type != 5) ||
            *(uint32_t *)(signal + 0x04) != 0x18 || event_id == 0 ||
            // iOS _MTLSharedEvent explicitly zeroes this word; legacy
            // IOGPUMTLEvent does not write it, so type 5 padding is opaque.
            (signal_type == 3 && *(uint32_t *)(signal + 0x0c) != 0))
            return NO;
        signal_pair_offsets[signal_count++] =
            (uint32_t)(list_cursor + 0x10);
        command_cursor = signal_end;
        list_cursor += 0x18;
        if (list_cursor == list_length)
            break;
    }

    if (fragment_count < 2 || signal_count < 1 || vendor_count < 2 ||
        command_cursor != total || list_cursor != list_length)
        return NO;
    *vendor_count_out = vendor_count;
    *signal_count_out = signal_count;
    return YES;
}

unsigned macws_translate_agx_segment_list_records(
    unsigned sequence, unsigned char *commands, size_t *total_io,
    unsigned char *segment_list, size_t *segment_length_io) {
    size_t segment_length = segment_length_io ? *segment_length_io : 0;
    if (!commands || !total_io || !segment_list || !segment_length_io ||
        segment_length < 0x20)
        return 0;

    size_t total = *total_io;
    uint32_t pair_offsets[MACWS_AGX_SEGMENT_LIST_MAX_RECORDS] = {0};
    uint32_t signal_pair_offsets[MACWS_AGX_SEGMENT_LIST_MAX_RECORDS] = {0};
    uint32_t signal_pair_count = 0;
    uint32_t count = *(uint32_t *)(segment_list + 0x08);
    BOOL fragmented_list = macws_collect_agx_fragmented_list_ranges(
        commands, total, segment_list, segment_length,
        pair_offsets, &count, signal_pair_offsets, &signal_pair_count);
    uint32_t encoded_length = *(uint32_t *)(segment_list + 0x0c);
    BOOL direct_list =
        encoded_length == (0x80000000U | (uint32_t)segment_length);
    // Chromium also emits the same trailing type-3 wrapper already captured
    // for a single subtype-1 segment, but after a variable-length list of two
    // or more vendor segments.  In that framing list+0x0c is the byte offset
    // of a final 0x18-byte wrapper-list record, not the high-bit-tagged total
    // list size.  Exact runtime witnesses:
    //   error 0x102 serial 12: KCMD 0x1098, list 0x2a8, base list 0x290
    //   error 0x0a  serial 13: KCMD 0x0a68, list 0x268, base list 0x250
    BOOL trailing_wrapper_list =
        encoded_length >= 0x20 &&
        (size_t)encoded_length + 0x18 == segment_length;
    // Runtime-confirmed by VS Code 1.130 Aquarium submit serial 155 on
    // 2026-07-30: the direct list contains 69 individually well-framed,
    // uniquely ranged records (KCMD length 0xee60, list length 0x3cf0).  The
    // former diagnostic-era limit of 64 rejected the entire batch before the
    // ABI walk and the completion returned 0x103 with fixed=0.  This is a
    // local parser-capacity bound, not an AGX protocol limit.  Keep a bounded
    // stack array but size it for the observed Chromium workload plus ample
    // headroom; all existing record, total-span and unique-range validation
    // still runs before any byte is changed.
    if (!fragmented_list &&
        (count < 1 || count > MACWS_AGX_SEGMENT_LIST_MAX_RECORDS ||
         (direct_list && count < 2) ||
         (!direct_list && !trailing_wrapper_list)))
        return 0;

    uint32_t wrapper_pair_offset = UINT32_MAX;
    unsigned wrapper_count = 0;
    uint32_t wrapper_type = 0;
    uint32_t wrapper_opcode = 0;
    uint32_t list_generation = 0;
    if (!fragmented_list) {
    uint32_t cursor = 0;
    for (uint32_t i = 0; i < count; i++) {
        if ((size_t)cursor + 0x38 > total)
            return 0;
        unsigned char *record = commands + cursor;
        uint32_t type = *(uint32_t *)(record + 0x00);
        uint32_t span = *(uint32_t *)(record + 0x04);
        if ((type != 0x10000 && type != 0x10001) || span < 0x38 ||
            span > 0x2000 || (size_t)cursor + span > total)
            return 0;
        uint32_t end = cursor + span;

        unsigned matches = 0;
        for (size_t off = 0; off + 8 <= segment_length; off += 8) {
            if (*(uint32_t *)(segment_list + off) == cursor &&
                *(uint32_t *)(segment_list + off + 4) == end) {
                pair_offsets[i] = (uint32_t)off;
                matches++;
            }
        }
        if (matches != 1)
            return 0;
        cursor = end;
    }
    if (direct_list) {
        if (cursor != total)
            return 0;
    } else {
        if (cursor > total)
            return 0;
        size_t wrapper_bytes = total - cursor;
        if (wrapper_bytes != 0x18 && wrapper_bytes != 0x30) {
            return 0;
        }
        wrapper_count = (unsigned)(wrapper_bytes / 0x18);
        wrapper_type = *(uint32_t *)(commands + cursor + 0x00);
        wrapper_opcode = *(uint32_t *)(commands + cursor + 0x08);
        // The wrapper record type is the dword at +0x00 (3); the opaque
        // operation token at +0x08 is not another type tag.  Chromium 148
        // Fish Tank runtime-captured two otherwise valid, identical wrapper
        // records with token 0x9207.  The former low-byte==3 requirement
        // rejected that list, after which the single-record fallback shifted
        // KCMD bytes without its multi-segment ranges and produced error 0x0a.
        BOOL wrapper_commands_ok = wrapper_type == 3 &&
            wrapper_opcode < 0x10000;
        for (unsigned i = 0; wrapper_commands_ok && i < wrapper_count; i++) {
            size_t offset = cursor + (size_t)i * 0x18;
            wrapper_commands_ok =
                *(uint32_t *)(commands + offset + 0x00) == 3 &&
                *(uint32_t *)(commands + offset + 0x04) == 0x18 &&
                *(uint32_t *)(commands + offset + 0x08) == wrapper_opcode;
        }
        // Runtime-confirmed by the first independent VS Code Simple Browser
        // Aquarium failure (GPU PID 56040, matched submit serial 108): a
        // subtype-3 segment [0,0x210) was followed by this exact type-5
        // 0x18-byte record and a generation-4 wrapper list covering
        // [0x210,0x228).  The iOS 16.3 AGX kernel parser rejects the preceding
        // subtype-3 body at 0xfffffe00086e2408 because its macOS size is
        // 0x1b8 instead of 0x1a8, then returns 0x103 at
        // 0xfffffe00086e4108.  Preserve the type-5 record byte-for-byte while
        // shortening only that RE-confirmed vendor segment and its ranges.
        //
        // RE of the macOS signal-event producer proves record+0x0c is
        // unwritten padding, but that fact alone is not a sufficient framing
        // contract for translating the preceding vendor record.  A runtime
        // A/B that accepted every {type=5,size=0x18} wrapper produced 0x102/
        // 0x103 from the first second of VS Code startup and more than ten
        // thousand failed completions in one session.  Keep the narrower
        // previously clean runtime shape here until the additional
        // relationship is identified; accepting arbitrary padding is
        // explicitly runtime-disproved as a production fix.
        // RE-confirmed via the actual macOS 13.4 IOGPU implementation of
        // -[IOGPUMTLEvent _encodeIOGPUKernelSignalEventCommandArgs:value:].
        // The dword at +0x08 is the event identifier, +0x10 is the 64-bit
        // signal value, and +0x0c is never written by the producer.  It is
        // therefore padding, not an opcode/ordinal or a protocol field.  Two
        // independently captured failing submissions contain 0x15 there
        // while retaining every structural list/range invariant.  Do not
        // reject a valid signal record based on stale contents in padding.
        uint32_t type5_event_id =
            *(uint32_t *)(commands + cursor + 0x08);
        if (wrapper_type == 5 && wrapper_count == 1 &&
            *(uint32_t *)(commands + cursor + 0x04) == 0x18 &&
            type5_event_id != 0 &&
            *(uint32_t *)(commands + cursor + 0x10) == 1 &&
            *(uint32_t *)(commands + cursor + 0x14) == 0) {
            wrapper_commands_ok = YES;
        }
        unsigned char *wrapper_list = segment_list + encoded_length;
        uint32_t list_magic = *(uint32_t *)(segment_list + 0x00);
        list_generation = *(uint32_t *)(segment_list + 0x04);
        BOOL wrapper_list_ok =
            *(uint32_t *)(wrapper_list + 0x00) == list_magic &&
            // Runtime-observed generations 2, 3 and 4 all use this exact
            // trailing-wrapper list contract.  After admitting the exact
            // cold-start single-segment generation-0 form above, fast-ring
            // serial 12 exposed the same generation-0 contract around two
            // subtype-1 segments and one type-3 opcode 0x9b03 wrapper
            // (KCMD 0x1098, list 0x2a8, range 0x1080..0x1098, fixed=0,
            // completion 0x102).  Keep the outer/tail equality and exact
            // ranges.  The 2026-08-01 VSCode video reproduction added the
            // missing generation-1 witness (outer/tail equal, exact one- and
            // two-wrapper ranges, opcode 0x9b03).  Admit the now-observed
            // bounded generation family 0..4, not arbitrary values.
            list_generation <= 4 &&
            *(uint32_t *)(wrapper_list + 0x04) == list_generation &&
            *(uint32_t *)(wrapper_list + 0x08) == 1 &&
            *(uint32_t *)(wrapper_list + 0x0c) == 0xc0000001 &&
            *(uint32_t *)(wrapper_list + 0x10) == cursor &&
            *(uint32_t *)(wrapper_list + 0x14) == total;
        if (!wrapper_commands_ok || !wrapper_list_ok)
            return 0;
        wrapper_pair_offset = encoded_length + 0x10;
    }
    }

    int log_segments = macws_runtime_diagnostics_enabled() &&
        atomic_fetch_add(&g_macws_multisegment_log_batches, 1) < 4;

    unsigned fixed = 0;
    for (uint32_t reverse = count; reverse > 0; reverse--) {
        uint32_t i = reverse - 1;
        unsigned char *range = segment_list + pair_offsets[i];
        uint32_t start = *(uint32_t *)(range + 0x00);
        uint32_t end = *(uint32_t *)(range + 0x04);
        size_t span = (size_t)end - start;
        unsigned char *record = commands + start;

        int subtype1 = span >= 0x818 &&
            *(uint32_t *)(record + 0x00) == 0x10000 &&
            *(uint32_t *)(record + 0x04) == span &&
            *(uint32_t *)(record + 0x28) == 0x818 &&
            *(uint32_t *)(record + 0x2c) == 0x7e8 &&
            *(uint32_t *)(record + 0x30) == 0x30 &&
            *(uint32_t *)(record + 0x34) == 1;
        int subtype1_anchors = subtype1 && span <= 0x1000 &&
            memcmp(record + 0xd8,
                "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
            macws_submit_bytes_are_zero(record + 0x1c0, 0x10) &&
            *(uint32_t *)(record + 0x1e0) == 1 &&
            *(uint32_t *)(record + 0x1e8) == 0x1c &&
            memcmp(record + 0x1f8,
                "\xff\xff\xff\xff\xff\xff\xff\xff"
                "\xff\xff\xff\xff", 12) == 0 &&
            macws_submit_bytes_are_zero(record + 0x4c0, 0x10) &&
            *(uint32_t *)(record + 0x4d0) == 0x3f800000 &&
            (*(uint32_t *)(record + 0x4d4) == 0x100 ||
             *(uint32_t *)(record + 0x4d4) == 0x300) &&
            memcmp(record + 0x4e8,
                "\xff\xff\xff\xff\xff\xff\xff\xff"
                "\xff\xff\xff\xff", 12) == 0;

        // RE-confirmed macOS 13.4 -> iOS 16.3 fast-2D command ABI delta.
        // The paired AGXMetal13_3 producers call ContextCommon::newCommand
        // with 0x3f8 (macOS) vs 0x3e8 (iOS), then clear a 0x3c0 vs 0x3b0-byte
        // subtype-2 body.  Crucially, both setupSpillBuffer implementations
        // pass body+0x1e0 to the paired allocateUSCSpillBuffer routine.  That
        // routine writes through descriptor offset +0x74 and the descriptor
        // has an aligned size of 0x78, so the common AGXSpillDesc occupies
        // body[0x1e0..0x258), or record[0x210..0x288).  The former deletion at
        // record+0x208 cut across that common descriptor and was structurally
        // invalid.  Every following AGX3DCommandCommonRec field is exactly
        // 0x10 earlier in iOS (+0x2cc -> +0x2bc, +0x2d0 -> +0x2c0,
        // +0x358 -> +0x348 and +0x3b0 -> +0x3a0), placing the macOS-only
        // aligned member immediately after AGXSpillDesc at
        // record[0x288..0x298).  A native-iOS generateMipmapsForTexture
        // control produced two successful subtype-2 records with the expected
        // 0x408/0x3b0 layout.
        int subtype2_anchors = span == 0x418 &&
            *(uint32_t *)(record + 0x00) == 0x10000 &&
            *(uint32_t *)(record + 0x04) == 0x418 &&
            *(uint32_t *)(record + 0x24) == 0x18 &&
            *(uint32_t *)(record + 0x28) == 0x3f0 &&
            *(uint32_t *)(record + 0x2c) == 0x3c0 &&
            *(uint32_t *)(record + 0x30) == 0x30 &&
            *(uint32_t *)(record + 0x34) == 2 &&
            *(uint64_t *)(record + 0x1e8) == 0x4000 &&
            *(uint64_t *)(record + 0x1f8) == 0x100000 &&
            *(uint64_t *)(record + 0x200) != 0 &&
            macws_submit_bytes_are_zero(record + 0x288, 0x10) &&
            *(uint32_t *)(record + 0x304) == 0x100 &&
            // Do not constrain +0x308: runtime controls have now observed
            // 0, 1 and 0x10291939 here.  Paired producer disassembly places
            // it after the deleted window, so it is payload to shift rather
            // than a record-layout anchor.
            *(uint32_t *)(record + 0x318) == 0xffffffff &&
            *(uint32_t *)(record + 0x31c) == 0xffffffff &&
            *(uint32_t *)(record + 0x320) == 0xffffffff;

        static const unsigned char subtype3_sentinel[12] = {
            0x01, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff
        };
        // This mode dword is after the macOS-only window, so its original
        // location is 0x10 later than the normalized iOS record.
        uint32_t subtype3_mode = span >= 0x1f8
            ? *(uint32_t *)(record + 0x1f4) : 0;
        int subtype3_anchors = span >= 0x1e8 && span <= 0x800 &&
            *(uint32_t *)(record + 0x00) == 0x10000 &&
            *(uint32_t *)(record + 0x04) == span &&
            *(uint32_t *)(record + 0x28) == 0x1e8 &&
            *(uint32_t *)(record + 0x2c) == 0x1b8 &&
            *(uint32_t *)(record + 0x30) == 0x30 &&
            *(uint32_t *)(record + 0x34) == 3 &&
            macws_submit_bytes_are_zero(record + 0x1cc, 0x10) &&
            memcmp(record + 0x1dc, subtype3_sentinel,
                   sizeof(subtype3_sentinel)) == 0;
        if (!subtype1_anchors && !subtype2_anchors && !subtype3_anchors)
            continue;

        uint32_t shrink = subtype1_anchors ? 0x20 : 0x10;
        if (subtype1_anchors) {
            // Delete both macOS-only zero windows from the complete remaining
            // storage tail.  Later segments have already been normalized and
            // are intentionally shifted together with that tail.
            memmove(record + 0x4c0, record + 0x4d0,
                    total - ((size_t)start + 0x4d0));
            total -= 0x10;
            memmove(record + 0x1c0, record + 0x1d0,
                    total - ((size_t)start + 0x1d0));
            total -= 0x10;
            *(uint32_t *)(record + 0x28) = 0x7f8;
            *(uint32_t *)(record + 0x2c) = 0x7c8;
            macws_subtype1_semantic_field_diagnostic(sequence, i, record);
        } else if (subtype2_anchors) {
            memmove(record + 0x288, record + 0x298,
                    total - ((size_t)start + 0x298));
            total -= 0x10;
            *(uint32_t *)(record + 0x28) = 0x3e0;
            *(uint32_t *)(record + 0x2c) = 0x3b0;
        } else {
            // Four native-iOS controls provide a paired semantic witness for
            // this boundary.  Successful blit/blittexture commands have
            // normalized mode=1 and dword +0x1cc=1; successful MPS
            // compute/scale commands have mode=2 and +0x1cc=0.  Deleting the
            // macOS window at 0x1cc preserves the mode-1 flag, while mode 2
            // must retain the preceding zero and delete [0x1d0,0x1e0).
            // Everything from normalized +0x1d0 onward is identical between
            // the two moves.  The former unconditional 0x1cc deletion made
            // every Aquarium mode-2 record carry the impossible {2,1}
            // mode/flag pair and the completed command buffer returned 0x103.
            size_t delete_offset =
                subtype3_mode == 2 ? 0x1d0 : 0x1cc;
            memmove(record + delete_offset, record + delete_offset + 0x10,
                    total - ((size_t)start + delete_offset + 0x10));
            total -= 0x10;
            *(uint32_t *)(record + 0x28) = 0x1d8;
            *(uint32_t *)(record + 0x2c) = 0x1a8;
        }
        memset(commands + total, 0, shrink);
        *(uint32_t *)(record + 0x04) = (uint32_t)(span - shrink);

        // This segment's end and every later segment's start/end are offsets
        // into the same compacted KCMD storage.
        *(uint32_t *)(range + 0x04) = end - shrink;
        for (uint32_t later = i + 1; later < count; later++) {
            unsigned char *later_range =
                segment_list + pair_offsets[later];
            *(uint32_t *)(later_range + 0x00) -= shrink;
            *(uint32_t *)(later_range + 0x04) -= shrink;
        }
        // Fragmented native IOGPU lists retain signal events between vendor
        // records.  A shrink in an earlier vendor record shifts the matching
        // signal and every later signal in the shared KCMD storage.  Earlier
        // signal ranges have already completed before this record and must
        // remain unchanged.
        for (uint32_t signal_index = 0;
             signal_index < signal_pair_count; signal_index++) {
            unsigned char *signal_range =
                segment_list + signal_pair_offsets[signal_index];
            if (*(uint32_t *)(signal_range + 0x00) >= end) {
                *(uint32_t *)(signal_range + 0x00) -= shrink;
                *(uint32_t *)(signal_range + 0x04) -= shrink;
            }
        }
        if (wrapper_pair_offset != UINT32_MAX) {
            unsigned char *wrapper_range =
                segment_list + wrapper_pair_offset;
            *(uint32_t *)(wrapper_range + 0x00) -= shrink;
            *(uint32_t *)(wrapper_range + 0x04) -= shrink;
        }
        fixed++;
        if (log_segments) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-SEGMENT-LIST-FIX "
                "segment=%u/%u subtype=%u range=%#x..%#x->%#x "
                "shrink=%#x storage=%#zx wrappedTail=%s\n",
                sequence, i, count,
                subtype1_anchors ? 1 : (subtype2_anchors ? 2 : 3),
                start, end, end - shrink, shrink, total,
                wrapper_pair_offset == UINT32_MAX ? "NO" : "YES");
    }

    // Runtime-confirmed native framing A/B for the first fully matched VS
    // Code Aquarium error after the 256-record capacity fix.  The failing
    // macOS submit (GPU PID 70010, serial 162) normalized all thirteen vendor
    // records but retained a generation-4 trailing wrapper:
    //
    //   KCMD 0x69e8 = base records 0x69d0 + {3,0x18,0x9203,0,0x78,0}
    //   list 0x1088 = base list 0x1070 + range [0x69d0,0x69e8)
    //
    // The project LLDB then captured the selector-0x1a payload of an iOS-
    // native thirteen-render-pass control on this same iPad/iOS build.  It
    // completed status=4/error=nil and used a direct count-13 list with no
    // final type-3 command or list wrapper (KCMD SHA-256 bb9d3663..., list
    // SHA-256 26ba9e8c...).  Flatten only that exact observed macOS wrapper
    // generation/opcode/count after every vendor record has independently
    // passed the ABI anchors above.  This is a bounded protocol A/B, not an
    // error/completion bypass; the thirteen GPU commands and their resource
    // descriptors remain byte-for-byte intact.
    if (wrapper_pair_offset != UINT32_MAX && fixed == count && count == 13 &&
        wrapper_count == 1 && wrapper_type == 3 &&
        wrapper_opcode == 0x9203 && list_generation == 4) {
        unsigned char *wrapper_range =
            segment_list + wrapper_pair_offset;
        uint32_t wrapper_start = *(uint32_t *)(wrapper_range + 0x00);
        uint32_t wrapper_end = *(uint32_t *)(wrapper_range + 0x04);
        if ((size_t)wrapper_start + 0x18 == total &&
            wrapper_end == total && encoded_length + 0x18 == segment_length) {
            memset(commands + wrapper_start, 0, 0x18);
            total = wrapper_start;
            memset(segment_list + encoded_length, 0, 0x18);
            *(uint32_t *)(segment_list + 0x0c) =
                0x80000000U | encoded_length;
            segment_length = encoded_length;
            fixed++;
            if (log_segments) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-SEGMENT-LIST-FLATTEN "
                "count=13 generation=4 opcode=0x9203 "
                "kcmd=%#x->%#zx list=%#x->%#zx\n",
                sequence, wrapper_end, total,
                encoded_length + 0x18, segment_length);
        }
    }

    *total_io = total;
    *segment_length_io = segment_length;
    return fixed;
}

struct macws_submit_diag_result
macws_inspect_agx_submit(const uint64_t *in, uint32_t inCnt,
                         const void *inStruct, size_t inStructCnt,
                         int allow_fix, int verbose_requested) {
    struct macws_submit_diag_result result = {0};
    int diagnostics = macws_runtime_diagnostics_enabled() || verbose_requested;
    if (diagnostics) {
        result.sequence =
            atomic_fetch_add(&g_macws_submit_diag_sequence, 1) + 1;
    }
    if (!inStruct || inStructCnt < 0x20)
        return result;

    // Keep the expensive byte dumps bounded, but never let that diagnostic
    // limit disable an explicitly requested ABI translation.  The previous
    // `sequence > 8` early return meant WindowServer's later command buffers
    // silently skipped TEMP-KCMD-ABI-FIX altogether.  Runtime witness:
    // `VNC-FINAL clear-control` then completed with MTL internal error 0x102.
    int verbose = verbose_requested && result.sequence <= 8;

    const unsigned char *submit = (const unsigned char *)inStruct;
    if (verbose) {
        size_t submit_dump = inStructCnt < 0x40 ? inStructCnt : 0x40;
        macws_submit_hex("submit-struct", result.sequence, submit, submit_dump);
        fprintf(stderr, "#### AGX_SUBMIT_DIAG #%u scalars[%u]:",
            result.sequence, inCnt);
        for (uint32_t i = 0; in && i < inCnt && i < 8; i++)
            fprintf(stderr, " %#llx", (unsigned long long)in[i]);
        fprintf(stderr, " fix-requested=%s\n", allow_fix ? "YES" : "NO");
    }

    // IOGPUMetalDevice::cmdBufArgsSize returns 0x38 on this exact image, and
    // runtime selector-0x1e captures show inStructCnt=56/112/224 for batches
    // of 1/2/4 command buffers.  The previous parser inspected only offsets
    // +0x10/+0x18 of the first 0x38-byte entry.  Chromium's first 0x102
    // completion witnesses consequently had submitSerial=0 while another
    // command buffer from the same batch was present in the flight recorder.
    // Walk every complete args entry; the queue splits batches at 32 in
    // -[IOGPUMetalCommandQueue submitCommandBuffers:count:].
    const size_t command_buffer_args_size = 0x38;
    size_t submit_entry_count = inStructCnt / command_buffer_args_size;
    if (submit_entry_count == 0 ||
        inStructCnt % command_buffer_args_size != 0) {
        submit_entry_count = 1;
    }
    if (submit_entry_count > 32) submit_entry_count = 32;
    uint64_t seen_state[64] = {0};
    unsigned seen_state_count = 0;
    if (verbose) fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u argsSize=%#zx submitEntries=%zu\n",
            result.sequence, inStructCnt, submit_entry_count);
    for (size_t submit_entry = 0; submit_entry < submit_entry_count;
         submit_entry++) {
        const unsigned char *entry =
            submit + submit_entry * command_buffer_args_size;
        uint64_t descriptor_raw[2] = {
            *(const uint64_t *)(entry + 0x10),
            *(const uint64_t *)(entry + 0x18)
        };
        for (unsigned descriptor_slot = 0; descriptor_slot < 2;
             descriptor_slot++) {
        unsigned descriptor_index =
            (unsigned)(submit_entry * 2 + descriptor_slot);
        uint64_t descriptor = macws_strip_user_pointer(
            descriptor_raw[descriptor_slot]);
        if (!macws_plausible_agx_pointer(descriptor_raw[descriptor_slot],
                                          0x28)) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u]=%#llx invalid\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)descriptor_raw[descriptor_slot]);
            continue;
        }

        const unsigned char *descriptor_bytes =
            (const unsigned char *)(uintptr_t)descriptor;
        uint64_t self_raw = *(const uint64_t *)(descriptor_bytes + 0x20);
        uint64_t self = macws_strip_user_pointer(self_raw);
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u]=%#llx raw=%#llx "
                "self=%#llx rawSelf=%#llx\n",
                result.sequence, descriptor_index,
                (unsigned long long)descriptor,
                (unsigned long long)descriptor_raw[descriptor_slot],
                (unsigned long long)self, (unsigned long long)self_raw);
        if (!macws_plausible_agx_pointer(self_raw, 0x258))
            continue;

        uint64_t state_raw = *(const uint64_t *)(uintptr_t)(self + 0x250);
        uint64_t state = macws_strip_user_pointer(state_raw);
        if (!macws_plausible_agx_pointer(state_raw, 0x348)) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx invalid\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)state_raw);
            continue;
        }
        BOOL duplicate_state = NO;
        for (unsigned seen = 0; seen < seen_state_count; seen++) {
            if (seen_state[seen] == state) {
                duplicate_state = YES;
                break;
            }
        }
        if (duplicate_state) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx duplicate\n",
                    result.sequence, descriptor_index,
                    (unsigned long long)state);
            continue;
        }
        if (seen_state_count < sizeof(seen_state) / sizeof(seen_state[0]))
            seen_state[seen_state_count++] = state;

        // RE-confirmed via the iOS 16.3 IOGPU implementations of
        // IOGPUMetalCommandBufferStorageCreateExt and
        // IOGPUMetalCommandBufferStorageFinalizeShmemHeader: +0x68 is the
        // segment/resource-list mapping base, +0x70 its limit, +0x328 the
        // finalized logical end, and +0x340 the active-header mode.  The
        // kernel's process_command_buffer parser writes submission error
        // 0x0a when this variable-length list fails its framing checks.  Dump
        // it read-only so native iOS and chroot layouts can be compared.
        uint64_t segment_start_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x68);
        uint64_t segment_limit_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x70);
        uint64_t segment_current_raw =
            *(const uint64_t *)(uintptr_t)(state + 0x328);
        uint64_t segment_start = macws_strip_user_pointer(segment_start_raw);
        uint64_t segment_limit = macws_strip_user_pointer(segment_limit_raw);
        uint64_t segment_current =
            macws_strip_user_pointer(segment_current_raw);
        int32_t segment_mode =
            *(const int32_t *)(uintptr_t)(state + 0x340);
        size_t segment_length = 0;
        if (macws_plausible_agx_pointer(segment_start_raw, 1) &&
            segment_current >= segment_start &&
            segment_current <= segment_limit &&
            segment_current - segment_start <=
                MACWS_AGX_SEGMENT_INSPECT_MAX) {
            segment_length = (size_t)(segment_current - segment_start);
        }
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u] segment "
                "start=%#llx current=%#llx limit=%#llx length=%#zx mode=%d\n",
                result.sequence, descriptor_index,
                (unsigned long long)segment_start,
                (unsigned long long)segment_current,
                (unsigned long long)segment_limit, segment_length, segment_mode);
        if (verbose && segment_length >= 0x10) {
            macws_submit_hex("segment-list", result.sequence,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length < 0x300 ? segment_length : 0x300);
            macws_submit_save_segment_list(result.sequence, descriptor_index,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
        }

        uint64_t start_raw = *(const uint64_t *)(uintptr_t)(state + 0x28);
        uint64_t current_raw = *(const uint64_t *)(uintptr_t)(state + 0x30);
        uint64_t end_raw = *(const uint64_t *)(uintptr_t)(state + 0x38);
        uint64_t start = macws_strip_user_pointer(start_raw);
        uint64_t current = macws_strip_user_pointer(current_raw);
        uint64_t end = macws_strip_user_pointer(end_raw);
        if (verbose) fprintf(stderr,
                "#### AGX_SUBMIT_DIAG #%u descriptor[%u] state=%#llx "
                "start=%#llx current=%#llx end=%#llx\n",
                result.sequence, descriptor_index,
                (unsigned long long)state, (unsigned long long)start,
                (unsigned long long)current, (unsigned long long)end);
        if (!macws_plausible_agx_pointer(start_raw, 1) ||
            current <= start ||
            current - start > MACWS_AGX_KCMD_INSPECT_MAX || end < current) {
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u descriptor[%u] KCMD bounds invalid\n",
                    result.sequence, descriptor_index);
            continue;
        }

        unsigned char *commands = (unsigned char *)(uintptr_t)start;
        size_t total = (size_t)(current - start);
        unsigned fixed_before_descriptor = result.fixed;
        struct macws_fast_submit_token fast_ring_token = {0};
        struct macws_submit_ring_token ring_token = {0};
        if (diagnostics) {
            fast_ring_token = macws_fast_submit_begin(
                result.sequence, descriptor_index, (uintptr_t)descriptor,
                (uintptr_t)self, (uintptr_t)state);
            ring_token = macws_submit_ring_begin(
                result.sequence, descriptor_index, (uintptr_t)descriptor,
                (uintptr_t)self, (uintptr_t)state, commands, total,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
        }
        size_t dump_length = total < 0x300 ? total : 0x300;
        if (verbose) macws_submit_hex("kernel-commands", result.sequence,
                                      commands, dump_length);
        // Read-only evidence capture.  The existing type-1 dump stops at the
        // AGX record's end_offset and therefore omits the 0x28-byte trailer
        // that follows the clear record.  iOS IOGPU parses that trailer after
        // the vendor command, so preserve the complete storage range before
        // any temporary ABI translation.
        if (verbose) macws_submit_save_kcmd(result.sequence, descriptor_index,
                                            "pre", commands, total);

        if (allow_fix && segment_length >= 0x38 &&
            macws_kcmd_wrapped_fix_enabled()) {
            unsigned wrapped_fixed =
                macws_translate_agx_wrapped_single_subtype1(
                    result.sequence, commands, &total,
                    (unsigned char *)(uintptr_t)segment_start,
                    &segment_length);
            if (!wrapped_fixed) {
                wrapped_fixed =
                    macws_translate_agx_trailing_wrapped_subtype1(
                        result.sequence, commands, &total,
                        (unsigned char *)(uintptr_t)segment_start,
                        segment_length);
            }
            if (wrapped_fixed) {
                result.candidates += wrapped_fixed;
                result.fixed += wrapped_fixed;
                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                // Runtime-confirmed by the first clean-log VS Code-triggered
                // WindowServer 0x100 flight record (PID 17741, submit 1): the
                // leading-wrapper translator produced the native 0x820 KCMD
                // and moved the direct list bytes to a 0x130 layout, but the
                // finalized logical list end at state+0x328 still made the
                // submitted span 0x148.  The captured list consequently had
                // header length 0x80000130 inside an actual 0x148-byte span.
                // Keep the RE-confirmed IOGPU storage logical-end field in
                // lockstep with the list bytes, just as state+0x30 is updated
                // for the shortened KCMD above.
                uint64_t new_segment_current =
                    segment_start + segment_length;
                uint64_t new_segment_current_raw =
                    (segment_current_raw & 0xffff000000000000ULL) |
                    new_segment_current;
                *(uint64_t *)(uintptr_t)(state + 0x328) =
                    new_segment_current_raw;
                segment_current_raw = new_segment_current_raw;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index,
                    "wrapped-post", commands, total);
            }
        }

        if (allow_fix && segment_length >= 0x20) {
            unsigned multisegment_fixed =
                macws_translate_agx_segment_list_records(
                    result.sequence, commands, &total,
                    (unsigned char *)(uintptr_t)segment_start,
                    &segment_length);
            if (multisegment_fixed) {
                result.candidates += multisegment_fixed;
                result.fixed += multisegment_fixed;
                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                // The exact native-framing A/B above can shorten the segment
                // list as well as KCMD storage. Keep IOGPU's RE-confirmed
                // finalized list end synchronized with the in-place header;
                // otherwise selector 0x1a would still submit the zeroed
                // wrapper bytes past the new high-bit-tagged direct length.
                uint64_t new_segment_current =
                    segment_start + segment_length;
                uint64_t new_segment_current_raw =
                    (segment_current_raw & 0xffff000000000000ULL) |
                    new_segment_current;
                *(uint64_t *)(uintptr_t)(state + 0x328) =
                    new_segment_current_raw;
                segment_current_raw = new_segment_current_raw;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index,
                    "multisegment-post", commands, total);
            }
        }

        BOOL single_direct_segment = segment_length >= 0x20 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                (0x80000000U | (uint32_t)segment_length) &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
            *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total;
        size_t off = 0;
        unsigned walked = 0;
        while (off + 0x38 <= total && walked++ < 16) {
            uint32_t type = *(uint32_t *)(commands + off);
            uint32_t end_offset = *(uint32_t *)(commands + off + 0x28);
            uint32_t size = *(uint32_t *)(commands + off + 0x2c);
            uint32_t inner = *(uint32_t *)(commands + off + 0x30);
            uint32_t subtype = *(uint32_t *)(commands + off + 0x34);
            unsigned record_index = result.records;
            if (verbose) fprintf(stderr,
                    "#### AGX_SUBMIT_DIAG #%u record[%u] off=%#zx type=%#x "
                    "end=%#x size=%#x inner=%#x subtype=%u\n",
                    result.sequence, record_index, off, type, end_offset,
                    size, inner, subtype);
            result.records++;

            if ((type != 0x10000 && type != 0x10001) ||
                end_offset < 0x38 || end_offset > total - off) {
                if (verbose) fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u record walk stopped: invalid framing\n",
                        result.sequence);
                break;
            }

            if (verbose && inner == 0x30 && subtype == 1)
                macws_submit_save_type1(result.sequence, record_index,
                                        commands + off, end_offset);

            // TEMPORARY ABI-TRANSLATION EXPERIMENT — native-iOS clear only.
            //
            // Runtime captures on this exact iPad/iOS 16.3 combination show:
            //
            //   iOS AGX clear:   total=0x820, end=0x7f8, size=0x7c8
            //   macOS AGX clear: total=0x840, end=0x818, size=0x7e8
            //
            // A byte alignment of the complete records found two independent
            // 0x10 all-zero insertions in the macOS layout.  Removing the
            // windows at original record offsets 0x1c0 and 0x4c0 and fixing
            // the three size fields makes the header byte-identical and 2005
            // of 2040 record bytes (98.28%) identical to the native capture.
            // The native reference was rerun at the exact same 2388x1668
            // dimensions, so there is no dimension mismatch.  The remaining
            // 35 differing bytes form runtime-varying GPU virtual addresses,
            // resource/segment identifiers, plus one opaque 32-bit token at
            // +0x610.  This classification is descriptive only; it is not
            // evidence that every remaining value is semantically valid.
            //
            // RE-confirmed against iPad13,6 com.apple.AGXG13G 227.2.43:
            // processRender treats record+0x38 as its payload and reads
            // payload+0x19c/+0x1a8/+0x1ae/+0x6a8.  All four windows become
            // byte-identical to native iOS after this normalization.
            //
            // Keep the gate deliberately narrower than the generic subtype-1
            // shape.  Runtime captures identify scalar[0]==3 for the VNC
            // clear-only control and scalar[0]==1 for agxprobe stage 5's
            // isolated IOSurface clear.  The enclosed record is the same
            // 0x818-byte subtype-1 macOS layout in every capture, but its
            // complete command-storage span and resource-list length vary
            // with the opaque trailer/resource count.  In particular, the
            // first exactly correlated WindowServer error (submit serial 194,
            // MTL error 00000102) was storage=0x870 and list=0x1f0.  Its list
            // still had the RE-confirmed one-segment framing: count=1,
            // encoded byte length, and range [0,total) at +0x18.  Validate
            // those invariants instead of hard-coding the resource count.
            // This remains a diagnostic ABI experiment, not a semantic
            // translation of scalar[0] or of the opaque trailer.
            if (off == 0 && type == 0x10000 && inner == 0x30 &&
                subtype == 1 && size == 0x7e8 && end_offset == 0x818 &&
                total >= 0x818 && segment_length >= 0x20) {
                uint64_t observed_scalar0 = in && inCnt >= 1
                    ? in[0] : UINT64_MAX;
                int check_scalar = in && inCnt >= 1 &&
                    (in[0] == 1 || in[0] == 3);
                int check_total = total >= 0x818 && total <= 0x1000;
                int check_segment_length = segment_length >= 0x20 &&
                    segment_length <= 0x10000;
                int check_segment_header =
                    *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                        (0x80000000U | (uint32_t)segment_length) &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
                    *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total;
                int check_command_total =
                    *(uint32_t *)(commands + 0x04) == total;
                int check_d8 = memcmp(commands + 0xd8,
                    "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0;
                int check_pad_1 =
                    macws_submit_bytes_are_zero(commands + 0x1c0, 0x10);
                int check_1e0 = *(uint32_t *)(commands + 0x1e0) == 1 &&
                    *(uint32_t *)(commands + 0x1e8) == 0x1c;
                int check_1f8 = memcmp(commands + 0x1f8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0;
                int check_pad_2 =
                    macws_submit_bytes_are_zero(commands + 0x4c0, 0x10);
                // Runtime captures show the same ABI padding around two
                // legitimate operation-state values: 0x300 for a clear and
                // 0x100 for a textured draw/detile.  Preserve the value; it
                // is an operation field, not part of the layout delta.
                uint32_t operation_state =
                    *(uint32_t *)(commands + 0x4d4);
                int check_4d0 =
                    *(uint32_t *)(commands + 0x4d0) == 0x3f800000 &&
                    (operation_state == 0x100 || operation_state == 0x300);
                int check_4e8 = memcmp(commands + 0x4e8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0;
                if (diagnostics) {
                    static _Atomic unsigned subtype1_observed_count = 0;
                    unsigned subtype1_observed = atomic_fetch_add(
                        &subtype1_observed_count, 1) + 1;
                    if (subtype1_observed <= 8) {
                    fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u subtype1-predicate "
                        "scalar0=%#llx legacy-scalar-gate=%d "
                        "total=%#zx/%d seglen=%#zx/%d "
                        "seghdr=%d cmdtotal=%d d8=%d pad1=%d f1=%d "
                        "sent1=%d pad2=%d f2=%d sent2=%d\n",
                        result.sequence,
                        (unsigned long long)observed_scalar0, check_scalar,
                        total, check_total,
                        segment_length, check_segment_length,
                        check_segment_header, check_command_total, check_d8,
                        check_pad_1, check_1e0, check_1f8, check_pad_2,
                        check_4d0, check_4e8);
                    if (!verbose) {
                        macws_submit_save_kcmd(result.sequence,
                            descriptor_index, "type1-observed", commands, total);
                        macws_submit_save_segment_list(result.sequence,
                            descriptor_index,
                            (const unsigned char *)(uintptr_t)segment_start,
                            segment_length);
                    }
                    }
                }
            }
            // scalar[0] deliberately does not participate in this gate.  It
            // is outside the vendor record being translated, is not modified,
            // and runtime-confirmed values differ between otherwise
            // byte-identical stage-5 and WindowServer clear records.  Treating
            // {1,3} as a semantic requirement was an unsupported diagnostic
            // restriction; the parser-facing record and segment invariants
            // below remain mandatory.
            if (allow_fix && off == 0 &&
                type == 0x10000 && inner == 0x30 && subtype == 1 &&
                size == 0x7e8 && end_offset == 0x818 &&
                total >= 0x818 && total <= 0x1000 &&
                segment_length >= 0x20 && segment_length <= 0x10000 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x08) == 1 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x0c) ==
                    (0x80000000U | (uint32_t)segment_length) &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x18) == 0 &&
                *(uint32_t *)(uintptr_t)(segment_start + 0x1c) == total &&
                *(uint32_t *)(commands + 0x04) == total &&
                memcmp(commands + 0xd8,
                    "\x03\x00\x6b\x00\x12\x00\x3a\x00", 8) == 0 &&
                macws_submit_bytes_are_zero(commands + 0x1c0, 0x10) &&
                *(uint32_t *)(commands + 0x1e0) == 1 &&
                *(uint32_t *)(commands + 0x1e8) == 0x1c &&
                memcmp(commands + 0x1f8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0 &&
                macws_submit_bytes_are_zero(commands + 0x4c0, 0x10) &&
                *(uint32_t *)(commands + 0x4d0) == 0x3f800000 &&
                (*(uint32_t *)(commands + 0x4d4) == 0x100 ||
                 *(uint32_t *)(commands + 0x4d4) == 0x300) &&
                memcmp(commands + 0x4e8,
                    "\xff\xff\xff\xff\xff\xff\xff\xff"
                    "\xff\xff\xff\xff", 12) == 0) {
                result.candidates++;
                size_t original_total = total;

                // Work from the higher original offset downward so both
                // deletion coordinates continue to refer to the captured
                // macOS record.  Move the complete submit tail as well: the
                // native command has a 0x28-byte trailer after record end.
                memmove(commands + 0x4c0, commands + 0x4d0,
                        total - 0x4d0);
                total -= 0x10;
                memmove(commands + 0x1c0, commands + 0x1d0,
                        total - 0x1d0);
                total -= 0x10;
                memset(commands + total, 0, 0x20);

                *(uint32_t *)(commands + 0x04) = (uint32_t)total;
                *(uint32_t *)(commands + 0x28) = 0x7f8;
                *(uint32_t *)(commands + 0x2c) = 0x7c8;
                macws_subtype1_semantic_field_diagnostic(
                    result.sequence, 0, commands);

                // IOGPUMetalCommandBufferStorageEndSegment writes the KCMD
                // span into the first segment record at overall list+0x1c.
                // The native iOS capture has the shortened complete KCMD span
                // here, matching its storage current-start.  Leaving the
                // macOS value after the KCMD deletion breaks that cross-shmem
                // invariant.  The record shrinks by 0x20; its opaque trailer
                // is preserved byte-for-byte by the memmoves above.
                *(uint32_t *)(uintptr_t)(segment_start + 0x1c) =
                    (uint32_t)total;

                uint64_t new_current = start + total;
                uint64_t new_current_raw =
                    (current_raw & 0xffff000000000000ULL) | new_current;
                *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                current_raw = new_current_raw;
                result.fixed++;
                if (verbose) macws_submit_save_kcmd(
                    result.sequence, descriptor_index, "post", commands, total);
                static _Atomic unsigned subtype1_fix_log_count = 0;
                unsigned subtype1_fix_log = diagnostics
                    ? atomic_fetch_add(&subtype1_fix_log_count, 1) + 1 : 0;
                if (verbose || (diagnostics && subtype1_fix_log <= 8))
                    fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-ABI-FIX "
                        "subtype1-clear pads=0x1c0,0x4c0 total=%#zx->%#zx "
                        "size=0x7e8->0x7c8 end=0x818->0x7f8 "
                        "segment-span=%#zx\n",
                        result.sequence, original_total, total, total);
                off += 0x7f8;
                continue;
            }

            // The linear fallback updates only the one direct range at
            // list+0x18.  Never apply it to a multi-segment or trailing-
            // wrapper list: shifting its KCMD tail without updating every
            // later range is a malformed command, not a compatibility fix.
            if (single_direct_segment &&
                inner == 0x30 && subtype == 3 && size == 0x1b8 &&
                end_offset == 0x1e8 && off + 0x1e8 <= total) {
                static const unsigned char sentinel[12] = {
                    0x01, 0x00, 0x00, 0x00,
                    0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff
                };
                int zero_pad = 1;
                for (size_t i = 0x1cc; i < 0x1dc; i++) {
                    if (commands[off + i] != 0) {
                        zero_pad = 0;
                        break;
                    }
                }
                int sentinel_match = memcmp(commands + off + 0x1dc,
                                            sentinel, sizeof(sentinel)) == 0;
                result.candidates++;
                if (verbose) fprintf(stderr,
                        "#### AGX_SUBMIT_DIAG #%u subtype3-mac-layout off=%#zx "
                        "zero-pad=%s sentinel=%s\n",
                        result.sequence, off, zero_pad ? "YES" : "NO",
                        sentinel_match ? "YES" : "NO");
                if (allow_fix && zero_pad && sentinel_match) {
                    size_t move_length = total - (off + 0x1dc);
                    memmove(commands + off + 0x1cc,
                            commands + off + 0x1dc, move_length);
                    memset(commands + total - 0x10, 0, 0x10);
                    *(uint32_t *)(commands + off + 0x28) = 0x1d8;
                    *(uint32_t *)(commands + off + 0x2c) = 0x1a8;
                    total -= 0x10;
                    // Runtime-confirmed by the first Aquarium Internal Error
                    // flight recorder (GPU process 9392, submit 5936): the
                    // translated blob and its direct segment range were both
                    // 0x1e0 bytes, but this outer KCMD header still declared
                    // the pre-deletion 0x1f0 span.  The iOS parser therefore
                    // walked ten bytes beyond the submitted command.  Keep
                    // the command's own complete-span field synchronized with
                    // the storage current pointer and segment range, just as
                    // the subtype-1 normalization above already does.
                    *(uint32_t *)(commands + 0x04) = (uint32_t)total;
                    *(uint32_t *)(uintptr_t)(segment_start + 0x1c) =
                        (uint32_t)total;
                    uint64_t new_current = start + total;
                    uint64_t new_current_raw =
                        (current_raw & 0xffff000000000000ULL) | new_current;
                    *(uint64_t *)(uintptr_t)(state + 0x30) = new_current_raw;
                    current_raw = new_current_raw;
                    result.fixed++;
                    static _Atomic unsigned subtype3_fix_log_count = 0;
                    unsigned subtype3_fix_log = diagnostics
                        ? atomic_fetch_add(&subtype3_fix_log_count, 1) + 1 : 0;
                    if (verbose || (diagnostics && subtype3_fix_log <= 8))
                        fprintf(stderr,
                            "#### AGX_SUBMIT_DIAG #%u TEMP-KCMD-ABI-FIX off=%#zx "
                            "size=0x1b8->0x1a8 end=0x1e8->0x1d8 "
                            "moved=%#zx new-total=%#zx\n",
                            result.sequence, off, move_length, total);
                    off += 0x1d8;
                    continue;
                }
            }
            off += end_offset;
        }
        if (diagnostics) {
            macws_submit_ring_finish(ring_token,
                result.fixed - fixed_before_descriptor,
                commands, total,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
            macws_fast_submit_finish(fast_ring_token,
                result.fixed - fixed_before_descriptor,
                commands, total,
                (const unsigned char *)(uintptr_t)segment_start,
                segment_length);
        }
        }
    }
    return result;
}

// macOS 13.4 and iOS 16.3 use different IOSurface user-client release ABIs.
// This is an exact two-call-to-one-call protocol adapter, not a generic trap
// bypass:
//
//   macOS IOSurface 2B44B850-7D19-34F3-AB8E-A3B93016A96D
//     IOSurfaceClientRelease+0xa0: IOConnectTrap1(conn, 4, surfaceID)
//     release client+0x60
//     IOSurfaceClientRelease+0x104: IOConnectTrap1(conn, 5, surfaceID)
//
//   iOS IOSurface DF041B53-4BAA-3668-8781-43DE39FA8905
//     release client+0x60
//     IOConnectCallMethod(conn, 1, &surfaceID, 1, ...)
//
// RE-confirmed from the exact framework binaries.  Runtime confirmation from
// misc/iosurface_release_probe.m is even more direct: 16 create/map/CFRelease
// pairs left exactly 16 IOSurface regions / 16384 16-KiB pages resident when
// the macOS trap ABI reached the iOS kernel.  Translate only the two verified
// call sites.  TLS pairing permits the replacement at the second call site
// only when trap 5 follows trap 4 with the same connection and surface ID on
// the same thread.

__thread struct macws_iosurface_release_pair
    g_macws_iosurface_release_pair;

BOOL macws_macho_uuid_matches(const struct mach_header_64 *header,
                                     const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64)
        return NO;
    const uint8_t *command_bytes = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)command_bytes;
        if (command->cmdsize < sizeof(*command))
            return NO;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        command_bytes += command->cmdsize;
    }
    return NO;
}

// Metal 310.37 (macOS 13.4) chooses the target platform for source-built
// libraries by calling dyld_get_active_platform() from five call sites in
// MTLLibraryBuilder::newLibraryWithSource.  In the chroot that correctly
// reports macOS (1), but the resulting library is then loaded by the native
// iOS AGX driver, which rejects the macOS library format.  Translate only the
// five RE-confirmed calls in the exact Metal image below to iOS (2).  Every
// other caller, including the rest of Metal and all other frameworks, keeps
// the real chroot platform.
//
// RE-confirmed with misc/ios_lldb_tmux.sh against the loaded binary:
//   UUID 2BAB169C-42DA-36E3-955A-F30B709EC2AD
//   image base                         Metal[0x0000000189848000]
//   MTLLibraryBuilder::newLibrary...   Metal[0x000000018993572c]
//   dyld_get_active_platform LR offsets from image base:
//       0x0edf14 0x0edf28 0x0ee018 0x0ee654 0x0ee690
// Runtime success still has to be witnessed by a non-nil MTLLibrary and a
// rendered WebGL frame; this translator is not labelled a completed fix yet.
extern uint32_t dyld_get_active_platform(void);

uint32_t dyld_get_active_platform_new(void) {
    uint32_t actual = dyld_get_active_platform();
    // Diagnostic A/B only.  The first runtime trial proved that forcing these
    // calls to iOS makes MTLCompilerService emit an iOS MTLB container
    // (0x0001/0x8200), which the macOS Metal loader rejects.  Keep it opt-in
    // while the unmodified macOS-platform request is measured with the now
    // working compiler cache path.
    if (!getenv("MACWS_AGX_NATIVE") ||
        !getenv("MACWS_METAL_SOURCE_FORCE_IOS"))
        return actual;

    void *signed_return_address = __builtin_return_address(0);
    void *return_address = ptrauth_strip(signed_return_address,
                                         ptrauth_key_return_address);
    Dl_info info = {0};
    if (!return_address || !dladdr(return_address, &info) ||
        !info.dli_fbase || !info.dli_fname)
        return actual;

    const char *basename = strrchr(info.dli_fname, '/');
    basename = basename ? basename + 1 : info.dli_fname;
    static const uint8_t metal_13_4_uuid[16] = {
        0x2b, 0xab, 0x16, 0x9c, 0x42, 0xda, 0x36, 0xe3,
        0x95, 0x5a, 0xf3, 0x0b, 0x70, 0x9e, 0xc2, 0xad,
    };
    if (strcmp(basename, "Metal") != 0 ||
        !macws_macho_uuid_matches(
            (const struct mach_header_64 *)info.dli_fbase,
            metal_13_4_uuid))
        return actual;

    uintptr_t offset = (uintptr_t)return_address - (uintptr_t)info.dli_fbase;
    static const uintptr_t source_builder_platform_returns[] = {
        0x0edf14, 0x0edf28, 0x0ee018, 0x0ee654, 0x0ee690,
    };
    BOOL exact_callsite = NO;
    for (size_t i = 0;
         i < sizeof(source_builder_platform_returns) /
             sizeof(source_builder_platform_returns[0]);
         i++) {
        if (offset == source_builder_platform_returns[i]) {
            exact_callsite = YES;
            break;
        }
    }
    if (!exact_callsite)
        return actual;

    static _Atomic unsigned long translation_count = 0;
    unsigned long sequence =
        atomic_fetch_add_explicit(&translation_count, 1,
                                  memory_order_relaxed) + 1;
    if (sequence <= 32 || (sequence % 500) == 0) {
        fprintf(stderr,
            "#### METAL-SOURCE-PLATFORM #%lu callerOffset=%#lx "
            "actual=%u -> ios=2\n",
            sequence, (unsigned long)offset, actual);
    }
    return 2; // PLATFORM_IOS
}

kern_return_t IOConnectTrap1_new(io_connect_t connect, uint32_t index,
                                  uintptr_t p1) {
    void *raw_return_address = __builtin_return_address(0);
    void *return_address = ptrauth_strip(raw_return_address,
                                         ptrauth_key_return_address);

    // launchdchrootexec can load both libmachook architecture variants.  Let
    // only the outer interpose inspect IOSurface's caller; an inner interpose
    // must forward rather than consume the pair a second time.
    if (caller_is_libmachook(return_address))
        return IOConnectTrap1(connect, index, p1);

    Dl_info info;
    static const uint8_t macos_iosurface_uuid[16] = {
        0x2b, 0x44, 0xb8, 0x50, 0x7d, 0x19, 0x34, 0xf3,
        0xab, 0x8e, 0xa3, 0xb9, 0x30, 0x16, 0xa9, 0x6d,
    };
    BOOL exact_image = NO;
    if (dladdr(return_address, &info) && info.dli_fbase && info.dli_fname) {
        const char *image_basename = strrchr(info.dli_fname, '/');
        image_basename = image_basename ? image_basename + 1 : info.dli_fname;
        exact_image = strcmp(image_basename, "IOSurface") == 0 &&
            macws_macho_uuid_matches(
                (const struct mach_header_64 *)info.dli_fbase,
                macos_iosurface_uuid);
    }
    uintptr_t return_offset = exact_image
        ? (uintptr_t)return_address - (uintptr_t)info.dli_fbase : 0;
    uint32_t call_instruction = exact_image
        ? *((const uint32_t *)return_address - 1) : 0;
    BOOL exact_first = exact_image && return_offset == 0x4b90 &&
        call_instruction == 0x94003617 && index == 4;
    BOOL exact_second = exact_image && return_offset == 0x4bf4 &&
        call_instruction == 0x940035fe && index == 5;

    if (exact_first) {
        g_macws_iosurface_release_pair =
            (struct macws_iosurface_release_pair){connect, p1, YES};
        // iOS has no first operation.  Its sole release selector belongs at
        // the second call site, after macOS has released client+0x60.
        return KERN_SUCCESS;
    }

    if (exact_second && g_macws_iosurface_release_pair.armed &&
        g_macws_iosurface_release_pair.connect == connect &&
        g_macws_iosurface_release_pair.surface_id == p1) {
        g_macws_iosurface_release_pair.armed = NO;
        uint64_t surface_id = p1;
        kern_return_t result = IOConnectCallScalarMethod(
            connect, 1, &surface_id, 1, NULL, NULL);
        static _Atomic unsigned long release_count = 0;
        unsigned long release_n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&release_count, 1) + 1 : 0;
        if ((release_n &&
             (release_n <= 16 || (release_n % 250) == 0)) ||
            result != KERN_SUCCESS) {
            fprintf(stderr,
                "#### IOSURFACE-RELEASE-ABI pair #%lu: conn=%u "
                "surfaceID=%llu sel=1 -> %#x\n",
                release_n, connect, (unsigned long long)p1, result);
        }
        return result;
    }

    // A mismatched second half must not inherit a stale pair later.  Preserve
    // the real trap for this call so an unexpected framework build/sequence
    // fails observably instead of silently changing semantics.
    if (exact_second)
        g_macws_iosurface_release_pair.armed = NO;
    return IOConnectTrap1(connect, index, p1);
}

IOReturn IOConnectCallMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int skip = caller_is_libmachook(__builtin_return_address(0));
    if (!skip) selector = IOConnectTranslateSelector(client, selector);
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) *outStructCnt = 0x70;
    // sel=0x9 (ResCreate): WAS bumping outStructCnt 0x50 → 0x10000 here based
    // on a misread of `IOGPUDevice::new_resource <+76>`. Standalone iOS-native
    // test (misc/agx_iogpu_probe.c + misc/sel9_test_macos.c) proves the OPPOSITE:
    //
    //   outSC=0x50   → SUCCESS (kernel-correct, what macOS userland sends)
    //   outSC=0x10000 → FAIL with kIOReturnNoBandwidth (0xe00002c2)
    //
    // The 0xe00002c2 reject IS the result of this bump. EVERY chroot sel=0xa
    // failure in this codebase traces back to this single line. Removed. See
    // [[cross-image-objc-class-register-and-ioconnect-heap-blocker]] LATE
    // UPDATE for the runtime evidence.
    //
    // (Set MACWS_RESTORE_OUTBUMP=1 to revive for A/B testing.)
    if(IOConnectIsIOGPU(client) && selector == 0x9 && outStructCnt && *outStructCnt == 0x50 &&
       getenv("MACWS_RESTORE_OUTBUMP")) {
        *outStructCnt = 0x10000;
    }
    // Preserve the translated selector-7 queue payload. RE-confirmed against
    // iOS 16.3 IOGPU::_IOGPUCommandQueueCreateWithQoS @ 0x1eec62a00 and
    // macOS 13.4 IOGPU::_IOGPUCommandQueueCreateWithQoS @ 0x19d1558b8: both
    // zero a 0x408-byte buffer, copy proc_pidpath into the first 0x400 bytes,
    // then store QoS at +0x400 and the background/priority byte at +0x404.
    // The iOS 16.3 kernel IOGPUCommandQueue initializer @
    // 0xfffffe0009f0c798 only bounds-checks +0x400 against 4 and copies the
    // leading bytes as the queue name; it does not reject a non-empty path.
    //
    // Keep zero substitution only as an explicitly requested A/B diagnostic.
    // It is a scaffold, not an ABI fix.
    unsigned char *qbuf = NULL;
    if (IOConnectIsIOGPU(client) && selector == 0x7 &&
        inStruct && inStructCnt == 0x408 &&
        getenv("MACWS_AGX_ZERO_QUEUE_ARGS")) {
        qbuf = (unsigned char *)calloc(1, inStructCnt);
        inStruct = qbuf;
        static int q_patched;
        if (!q_patched) {
            q_patched = 1;
            fprintf(stderr,
                "#### AGXIOC QueueArgs-DIAGNOSTIC sel=0x%x: MACWS_AGX_ZERO_QUEUE_ARGS replaced native-shaped path/QoS payload with zeroed 0x408 scaffold\n",
                selector);
        }
    }
    unsigned char shadowbuf[256];
    uint8_t  agxType = 0; uint32_t agxClientID = 0; uint64_t agxHeapSz = 0;
    const void *agxRawRequest = NULL;
    size_t agxRawRequestLength = 0;
    uint32_t resDiagSequence = 0;
    int resDiagActive = macws_res_diag_enabled();
    int agxIsRes = (IOConnectIsIOGPU(client) && selector == 0x9 && inStruct && inStructCnt >= 0x60 && inStructCnt <= sizeof(shadowbuf));
    if(agxIsRes) {
        const unsigned char *src = (const unsigned char *)inStruct;
        if (resDiagActive) {
            static _Atomic uint32_t sequence = 0;
            resDiagSequence = atomic_fetch_add(&sequence, 1) + 1;
            if (resDiagSequence <= 64) {
                fprintf(stderr,
                    "#### AGX_RES_DIAG #%u RAW type=%#x len=%zu:",
                    resDiagSequence, src[0], inStructCnt);
                for (size_t offset = 0; offset + 8 <= inStructCnt;
                     offset += 8) {
                    fprintf(stderr, " +%02zx=%#llx", offset,
                        (unsigned long long)*(const uint64_t *)(src + offset));
                }
                fprintf(stderr, "\n");
            }
        }
        agxType = src[0];
        if (agxType == 0x82 &&
            macws_iogpu_error_diag_enabled()) {
            agxRawRequest = src;
            agxRawRequestLength = inStructCnt;
        }
        uint8_t  f15  = src[0x15];                                // flag byte; bit-3 = "has parent"
        uint64_t bc   = *(const uint64_t *)(src + 0x40);          // for type=0: heap byte-count
        uint64_t f30  = *(const uint64_t *)(src + 0x30);
        uint64_t va38 = *(const uint64_t *)(src + 0x38);
        uint64_t va48 = *(const uint64_t *)(src + 0x48);          // parent_id OR length depending on type/flags
        // RE confirms (iOS kernel IOGPUDevice::new_resource @
        // fffffe0009f03c1c): for type=0x80, args[0x48] is
        // parent_id only when args[0x15] bit-3 is set. Otherwise it's
        // the client buffer length and the kernel skips the parent
        // lookup, calling IOGPUResource::newResourceWithClientBuffer
        // with (args[0x40], args[0x30], args[0x38]) instead. The
        // previous translator unconditionally clobbered args[0x48]
        // which corrupted the length on every client-buffer path.
        BOOL t80_has_parent = (agxType == 0x80) && (f15 & 0x08);
        // type=0 owns a macOS client-assigned resource ID at +0x48.  type=0x80
        // uses the same field as a parent reference only when f15.bit3 is set.
        // The previous ternary accidentally forced every type=0 ID to zero,
        // collapsing g_agxIdMap to one entry and making every real parent-ID
        // translation miss. Runtime witness: thousands of lines read
        // `heap clientID 0 -> GID ...` while the paired ResCreate dump showed
        // `type=0 clientID=0x40000`.
        agxClientID = (agxType == 0 || t80_has_parent)
            ? *(const uint32_t *)(src + 0x48) : 0;
        int patched = 0;
        memcpy(shadowbuf, inStruct, inStructCnt);
        if(bc == 0 && agxType == 0) {
            // Heap byte-count fixup (only valid for type=0 heap creation;
            // type=0x80 client-buffer path uses args+0x40 as the end VA,
            // not a size). Prefer the exact length captured at the upstream
            // AGXBuffer initFull boundary. The old uint32_t(+0x58) fallback
            // truncated VA-shaped values and underallocated growing Mempools.
            uint32_t sz32 = *(const uint32_t *)(src + 0x58);
            uint64_t mac_span = *(const uint64_t *)(src + 0x48);
            // RE-confirmed in iOS 16.3 IOGPUDevice::new_resource at
            // 0xfffffe0009f0415c: type-0 allocation size is read from
            // args+0x40.  Runtime comparison of matching AGX internal
            // requests shows macOS leaves +0x40 zero and puts the intended
            // span at +0x48, while +0x58 can be a much larger VA-shaped
            // value (for example 0x48000000 beside a 0x8000 span).  The old
            // low32(+0x58) fallback inflated five 0x8000 native buffers into
            // 128 MiB--1.125 GiB allocations; the resulting resource VA
            // 0x1558080000 faulted in hardware as 0x1158080000.
            //
            // A bit-3 parent request gives +0x48 a different kernel meaning,
            // so only use it as the span on the no-parent type-0 path.  The
            // upstream initFull length remains more precise for ordinary
            // MTLBuffers whose allocation span is rounded to a larger page.
            uint64_t fallback_span = (!(f15 & 0x08) && mac_span > 0 &&
                mac_span <= 0x40000000ULL) ? mac_span :
                (sz32 ? sz32 : 0x1000);
            uint64_t nb = g_macws_agx_initfull_len ?
                g_macws_agx_initfull_len : fallback_span;
            *(uint64_t *)(shadowbuf + 0x40) = nb;
            if (!(f15 & 0x08)) {
                // Full 0x68-byte LLDB captures of the matching iOS 16.3
                // requests establish a tail-field ABI shift:
                //
                //   macOS: +0x48=span, +0x50=0, +0x58=arena<<24
                //   iOS:   +0x48=0,    +0x50=arena<<24, +0x58=0
                //
                // Only the low 32 bits carry the arena value.  For example,
                // f14=0x8430 uses 0x48000000 at iOS +0x50 and the kernel
                // returns the special 0x18000/0x28000 VA windows.  Sending
                // zero at +0x50 instead returned an ordinary 0x15... VA;
                // the GPU then consumed that address with bit 34 clear and
                // raised a BIF0 page fault.  Translate the request field at
                // its source; do not rewrite the returned GPU VA.
                uint32_t arena = *(const uint32_t *)(src + 0x58);
                *(uint64_t *)(shadowbuf + 0x48) = 0;
                *(uint64_t *)(shadowbuf + 0x50) = arena;
                *(uint64_t *)(shadowbuf + 0x58) = 0;
            }
            agxHeapSz = nb;
            patched = 1;
            if (g_macws_agx_initfull_len &&
                macws_runtime_diagnostics_enabled()) {
                static _Atomic int exact_len_log_count = 0;
                int exact_n = atomic_fetch_add(&exact_len_log_count, 1);
                if (exact_n < 16) {
                    fprintf(stderr,
                        "#### AGXIOC type0 exact initFull length: +0x58=%#llx low32=%#x -> +0x40=%#llx\n",
                        (unsigned long long)*(const uint64_t *)(src + 0x58),
                        sz32, (unsigned long long)nb);
                }
            } else if (resDiagActive && resDiagSequence <= 64) {
                fprintf(stderr,
                    "#### AGX_RES_DIAG #%u type0 size source: "
                    "+0x48 span=%#llx +0x58 low32=%#x -> +0x40=%#llx\n",
                    resDiagSequence, (unsigned long long)mac_span, sz32,
                    (unsigned long long)nb);
            }
        }
        // type=0 with args+0x40 already set (high bit pattern = pinned-VA
        // shape — macOS used `pinnedGPULocation:` to request a specific
        // VA range; the kernel reads args+0x40 as IOByteCount and
        // rejects sizes that look like VAs). For SLCADisplay scanout
        // backing: args+0x40 = 0x80888f00 (= 2.15 GB, bit 31 set) and
        // args+0x48 = 0x1fb8000 (~33 MB, looks like a real length).
        // Substitute the length-shaped args+0x48 as the size.
        // Widened VA-shape detection (2026-06-19 part 2):
        //
        // Original condition `bc & 0x80000000` only caught SLCADisplay
        // scanout backing where args+0x40 = 0x80888f00 (bit-31 set).
        // For texture-backing requests SkyLight sends args+0x40 like
        // 0x108198000 or 0x1081f4000 — values > 4 GB whose bit-31 is
        // CLEAR (the high 33+ bits hold the VA). The previous condition
        // missed these → unpatched VA reaches kernel → rejected as
        // oversized IOByteCount → AGXTexture super-init returns nil →
        // downstream SkyLight Unbalanced Composites assert.
        //
        // Widened condition: any args+0x40 > 0x40000000 (1 GB) is treated
        // as a VA (no real allocation request is that big — IOGPU+0x108
        // cap is ~5 GB total, individual allocations rarely exceed
        // hundreds of MB). Use args+0x48 as the real length.
        // 2026-06-19 part 3 — type=0 heap with pinned-VA args+0x38 also
        // triggers kernel kIOReturnNoMemory. SkyLight texture path sends
        // args+0x38=0x102fec000 (high VA) AND args+0x40=0x4000 (already a
        // length, so previous VA-shape patch on +0x40 doesn't fire). The
        // VA at +0x38 tells the macOS kernel "place this heap at this
        // pinned GPU VA", iOS kernel rejects. Zero args+0x38 for ANY
        // type=0 heap call where it's >1GB — same logic as +0x40 swap.
        // 2026-06-20 — ONE-SHOT pre-patch dump for type=0x82 (IOSurface
        // texture).  RE of IOGPUDevice::new_resource (kernelcache
        // 0xfffffe0009f03b4c) shows the newResourceWithIOSurface (wrap)
        // path requires args+0x34 >= IOSurface-plane-dimension AND
        // args+0x15 bit3.  Our SURF diagnostics proved the resulting
        // texture has SEPARATE backing (GPU renders there, IOSurface
        // VNC reads stays black).  Hypothesis: our arg-mangling routes
        // the call away from the wrap path.  Dump the ORIGINAL macOS
        // args to see what +0x34 / +0x15 / +0x40 / +0x58 actually hold
        // before we touch them.
        if (agxType == 0x82 && macws_runtime_diagnostics_enabled()) {
            static int t82_pre = 0;
            if (!t82_pre) {
                t82_pre = 1;
                fprintf(stderr,
                    "#### AGXIOC RAW DUMP sel=0x9 type=0x82 inStructCnt=%zu (PRE-patch):\n",
                    inStructCnt);
                for (size_t i = 0; i < inStructCnt && i < 0x70; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", src[i + j]);
                    fprintf(stderr, "\n");
                }
                fprintf(stderr,
                    "####   key fields: +0x14=%#x +0x15(byte)=%#x +0x30=%#x "
                    "+0x34=%#x +0x38=%#llx +0x40=%#llx +0x48=%#llx +0x58=%#llx\n",
                    *(const uint32_t *)(src + 0x14),
                    (unsigned)src[0x15],
                    *(const uint32_t *)(src + 0x30),
                    *(const uint32_t *)(src + 0x34),
                    (unsigned long long)*(const uint64_t *)(src + 0x38),
                    (unsigned long long)*(const uint64_t *)(src + 0x40),
                    (unsigned long long)*(const uint64_t *)(src + 0x48),
                    (unsigned long long)*(const uint64_t *)(src + 0x58));
            }
        }
        // Apply VA-shape + flag-strip to ALL types (was only type=0).
        // type=0x80 client-buffer path showed same pattern: args+0x38 has
        // pinned-VA, args+0x14=0x0c30 has bit 11 (macOS-only) set.
        {
            uint64_t va38 = *(const uint64_t *)(src + 0x38);
            // A parent-backed type-0x80 request is the exception to the
            // generic pinned-VA removal.  The native-iOS 6x1 mip texture
            // witness captured with LLDB on 2026-07-30 returned success with
            // the same base VA at both +0x30 and +0x38.  Its +0x40 held the
            // 0x20000 parent span.  Zeroing +0x38 here made the later parent
            // translator construct a layout that no native producer sends.
            if (va38 > 0x40000000ULL && agxType != 0x82 &&
                !t80_has_parent) {
                static int log_once_38 = 0;
                if (macws_runtime_diagnostics_enabled() &&
                    log_once_38++ < 4) {
                    fprintf(stderr,
                        "#### AGXIOC sel=0x9 type=%#x VA-shape +0x38=%#llx → 0\n",
                        agxType, (unsigned long long)va38);
                }
                *(uint64_t *)(shadowbuf + 0x38) = 0;
                patched = 1;
            }
            // args+0x14 flag mask: known-good values are 0x470 / 0x430.
            // SkyLight texture path sends 0x2c30 (type=0) or 0x0c30
            // (type=0x80) — both add bit 11 (0x800), 0x2c30 also adds
            // bit 13 (0x2000). These are macOS-only options that iOS
            // kernel rejects. Strip 0x2800.
            uint32_t f14 = *(const uint32_t *)(src + 0x14);
            uint32_t f14_clean = f14 & ~0x2800u;
            if (f14_clean != f14) {
                static int log_once_14 = 0;
                if (macws_runtime_diagnostics_enabled() &&
                    log_once_14++ < 4) {
                    fprintf(stderr,
                        "#### AGXIOC sel=0x9 type=%#x args+0x14=%#x → %#x "
                        "(stripped macOS-only bits 0x2800)\n",
                        agxType, f14, f14_clean);
                }
                *(uint32_t *)(shadowbuf + 0x14) = f14_clean;
                patched = 1;
            }
        }
        if(agxType == 0 && bc != 0 && bc > 0x40000000ULL) {
            uint64_t len_field = *(const uint64_t *)(src + 0x48);
            uint64_t va58 = *(const uint64_t *)(src + 0x58);
            // Only swap if the length looks reasonable (<= 2 GB).
            if (len_field > 0 && len_field < 0x80000000ULL) {
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### AGXIOC sel=0x9 type=0 VA-shape detected: "
                        "args+0x40=%#llx (>1GB) → using args+0x48=%#llx as size, +0x58 %#llx → 0\n",
                        (unsigned long long)bc,
                        (unsigned long long)len_field,
                        (unsigned long long)va58);
                }
                *(uint64_t *)(shadowbuf + 0x40) = len_field;
                // SLCADisplay scanout: macOS leaves args+0x58 set to a tagged
                // GPU-VA (e.g. 0x380888f00). On iOS the kernel reads this as
                // a "pinned VA" request — a macOS-only fast path that doesn't
                // exist on iOS → kIOReturnNoMemory (0xe00002be). Zero it so
                // the kernel falls into the standard heap allocator (which
                // chooses its own VA), same as the type=0x82 IOSurface fix
                // a few blocks down. RE-runtime-confirmed: chroot WS WAS
                // failing every SLCADisplay scanout heap with 0xe00002be even
                // after the +0x40 swap; this companion zero is needed.
                *(uint64_t *)(shadowbuf + 0x58) = 0;
                agxHeapSz = len_field;
                patched = 1;
            }
        }
        // (Obsolete bc>cap check moved into the heap fixup above —
        // macOS leaves args+0x40 = 0; the size we cap is the one we
        // derive from src+0x58, not bc.)
        if(agxType == 0x80 && t80_has_parent) {
            // Sub-resource carved from a tracked parent heap.
            int mapped = 0;
            for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) {
                // Runtime-confirmed with the exact native iOS 16.3 producer
                // through IOGPUResourceCreate+0xf0 (w0=0):
                //
                //   native: +0x30=base, +0x38=base,
                //           +0x40=parent span, +0x48=kernel resource ID
                //   macOS:  +0x30=0,    +0x38=base,
                //           +0x40=base, +0x48=client parent ID
                //
                // The old translation sent base+span / 0 / base / ID.
                // Once base crossed 3*(IOGPU+0x108)/4, that VA in +0x40
                // hit the RE-confirmed size gate and returned 0xe00002c2.
                // Translate the producer ABI itself; do not bypass the
                // kernel check or manufacture a texture on failure.
                *(uint64_t *)(shadowbuf + 0x30) = va38;
                *(uint64_t *)(shadowbuf + 0x38) = va38;
                *(uint64_t *)(shadowbuf + 0x40) = g_agxIdMap[i].size;
                *(uint32_t *)(shadowbuf + 0x48) =
                    (uint32_t)g_agxIdMap[i].iosResourceID;
                patched = 1; mapped = 1;
                if (macws_runtime_diagnostics_enabled()) {
                    fprintf(stderr,
                        "#### AGXIOC subres parent %#x -> resourceID %#llx, "
                        "base=%#llx span=%#llx\n",
                        agxClientID,
                        (unsigned long long)g_agxIdMap[i].iosResourceID,
                        (unsigned long long)va38,
                        (unsigned long long)g_agxIdMap[i].size);
                }
                break;
            }
            if(!mapped && f30 == 0 && va38) {
                // Preserve the native base/base relationship, but leave the
                // unresolved parent ID and span untouched so the real call
                // fails observably instead of being synthesized as valid.
                *(uint64_t *)(shadowbuf + 0x30) = va38;
                *(uint64_t *)(shadowbuf + 0x38) = va38;
                patched = 1;
            }
        } else if(agxType == 0x80) {
            // ONE-SHOT raw-bytes dump: capture the EXACT inStruct bytes
            // macOS WS sends for sel=0x9 type=0x80 BEFORE any libmachook
            // patching. Compare to iOS-native probe (agx_iogpu_probe.c)
            // args that also fail kr=0xe00002be. If bytes match → truly
            // structural; if they diverge, the differing field IS the
            // rejection trigger.
            static int t80_dumped = 0;
            if (macws_runtime_diagnostics_enabled() && !t80_dumped) {
                t80_dumped = 1;
                fprintf(stderr,
                    "#### AGXIOC RAW DUMP sel=0x9 type=0x80 inStructCnt=%zu (pre-patch):\n",
                    inStructCnt);
                for (size_t i = 0; i < inStructCnt; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", src[i + j]);
                    fprintf(stderr, "\n");
                }
                // Non-zero u64 scan past 0x60 in case macOS sends more.
                const uint64_t *u = (const uint64_t *)src;
                for (size_t i = 12; i * 8 < inStructCnt; i++) {
                    if (u[i]) fprintf(stderr, "    nz @ +%#zx: %#llx\n",
                        i * 8, (unsigned long long)u[i]);
                }
            }
            // Client-buffer path (type=0x80, no parent flag): iOS kernel
            // entry checks `args[0x40] <= limit` early (IOGPUDevice::
            // new_resource @ fffffe0009f03c4c: cmp x9, x10; b.ls). macOS
            // IOGPUMetalBuffer init writes args[0x40] = client pointer VA
            // (same as args[0x38]) which exceeds the limit (a kalloc-sized
            // value), so this fails before the actual newResourceWithClient-
            // Buffer call. iOS native userland writes args[0x40] = length
            // here. Length sits at args[0x48] (macOS IOGPUMetalBuffer
            // stores it there before this call).
            // 2026-06-19 — type=0x80 + args+0x30=0x1 + mach_vm VA at +0x38
            // is the macOS SCANOUT-buffer creation path. iOS kernel
            // accepts it (probe[5] proved kr=0) but treats the result as
            // a display-engine scanout source — wiring our garbage
            // buffer to the physical LCD framebuffer, corrupting iOS UI
            // (purple/pink screen). Reverted: keep kernel rejection.
            // The CODEHEAP-SHIM IOSurface synth path handles AGXBuffer
            // creates more safely (no scanout side-effect).
            uint64_t length = va48;
            uint64_t cur40 = *(const uint64_t *)(src + 0x40);
            if(length && (cur40 == va38 || cur40 > 0x40000000ULL)) {
                *(uint64_t *)(shadowbuf + 0x40) = length;
                patched = 1;
            }
            uint64_t cur30 = *(const uint64_t *)(src + 0x30);
            if (cur30 > 0x40000000ULL || cur30 == 0x1) {
                *(uint64_t *)(shadowbuf + 0x30) = 0;
                patched = 1;
            }
            uint64_t cur58 = *(const uint64_t *)(src + 0x58);
            if (cur58 != 0) {
                *(uint64_t *)(shadowbuf + 0x58) = 0;
                patched = 1;
            }
        }
        // type=0x82 is the iOS-NATIVE type byte for iosurface-backed textures
        // too — confirmed by static disasm of iOS IOGPUMetalTexture's
        // initWithDevice:descriptor:iosurface:plane:field:args:argsSize: at
        // 0x1eec5d33c: `ldr d0, [#0x1eec7e710]; str d0, [args]` loads the 8-
        // byte template `82 00 00 00 00 00 00 00` and writes it to args[0].
        //
        // Runtime-confirmed type=0x82 tail-field ABI shift (2026-07-24).
        // The exact same 2388x1668 BGRA8 IOSurface texture request was
        // captured from both userlands:
        //
        //   native iOS: +0x30=surfaceID, +0x38=0,
        //               +0x50=0x180888f00, +0x58=0
        //   macOS WS:   +0x30=0, +0x38=surfaceID,
        //               +0x50=0, +0x58=0x180888f00
        //
        // Evidence: /tmp/lldb-iosdraw-native-2388.log res #15 and
        // /tmp/ws-pf550-fault-20260724-190809/WindowServer.err res #16.
        // Therefore the macOS +0x58 value is not a pinned VA to discard; it
        // is the texture-layout word that iOS expects at +0x50.  BGRA8 happened
        // to render with a zero layout word, but the first pf=550 read then
        // faulted.  Translate the producer ABI before the request reaches the
        // kernel: move both shifted fields and clear their old macOS slots.
        // 2026-06-18 disasm of iOS AGXG13G + IOGPUFamily kexts located the
        // exact kernel check that rejects our chroot args. IOGPUDevice::
        // new_resource() at fffffe0009f03bb4:
        //   cmp w8, #0x82                 ; type word
        //   ldr w1, [x24, #0x30]          ; args+0x30 = IOSurfaceID
        //   ldr x2, [x22, #0x50]          ; this->0x50 = task
        //   bl  IOGPU::find_iosurface_for_id
        //   cbz x0, FAIL                  ; ← we hit this. IOSurfaceID=0 →
        //                                   no lookup hit → kIOReturnNoMemory
        // iOS userland's iOS IOGPUMetalTexture iosurface init writes
        //   stp w0, w21, [x24, #0x30]      ; +0x30 = IOSurfaceGetID(io)
        // before sel=0xa fires. macOS WS path leaves +0x30 = 0.
        //
        // Fix: read the IOSurfaceID, plane and compression-header span from
        // Metal_hooks.x's lock-protected wrapper scope. The scope is process-
        // wide because the initializer may issue this call on a worker thread.
        // The swizzled newTextureWithDescriptor:iosurface:plane: (we're called
        // synchronously from inside that swizzle's %orig), and inject it
        // into args[+0x30]. Keep +0x40 zero and move the macOS texture-layout
        // word from +0x58 to iOS +0x50.
        // macOS chroot stores the IOSurfaceID at args+0x38. Native iOS packs
        // IOSurfaceID and plane as two adjacent u32 values at +0x30/+0x34:
        // the producer instruction above is `stp w0, w21, [x24, #0x30]`, not
        // a write to +0x38. Project-LLDB captured the exact successful native
        // 640x360 NV12 requests on 2026-08-01:
        //
        //   Y:  u64(+0x30)=0x00000000_000000a7, u64(+0x38)=0
        //   UV: u64(+0x30)=0x00000001_000000a7, u64(+0x38)=0
        //
        // The former translator wrote plane at +0x38, so the kernel imported
        // plane 0 for both logical textures even though the ObjC texture's
        // private `boundPlane` field reported 1. Runtime A/B then showed:
        // decoded IOSurface bytes == public texture getBytes, direct GPU
        // sampling green/magenta, and an ordinary texture uploaded from those
        // same bytes rendering correctly. Pack the two native fields exactly
        // and clear macOS's shifted +0x38 slot.
        // Project-LLDB RE of the successful native pf550 path subsequently
        // located the exact iOS producer, `-[AGXG13GFamilyDevice
        // initNewTextureData:]` at runtime 0x2260cf0e0:
        //   0x2260cf23c: orr x9, x9, #0x180000000
        //   0x2260cf250: bfi x9, x11, #33, #1  // compression object exists
        //   0x2260cf278: str x8, [x2, #0x58]   // aligned metadata span
        // For the CA Framebuffer, IOSurfaceCopyAllValues reports the same
        // per-plane reserved compression-header span (0x40000) that native
        // iOS sends at +0x58.  Therefore +0x58 must be reconstructed from the
        // current IOSurface's properties, not blindly zeroed.  Presence of
        // that span also supplies native layout-word bit 33.
        if(agxType == 0x82) {
            uint32_t f14 = *(const uint32_t *)(src + 0x14);
            uint64_t old_40 = *(const uint64_t *)(src + 0x40);
            uint64_t old_50 = *(const uint64_t *)(src + 0x50);
            uint64_t old_58 = *(const uint64_t *)(src + 0x58);
            uint32_t old_30 = *(const uint32_t *)(src + 0x30);
            uint32_t old_34 = *(const uint32_t *)(src + 0x34);
            uint32_t old_38 = *(const uint32_t *)(src + 0x38);
            uint32_t old_3c = *(const uint32_t *)(src + 0x3c);
            uint32_t current_surface_id = macws_get_current_iosurface_id();
            uint32_t current_plane = macws_get_current_iosurface_plane();
            uint64_t compression_header_span =
                macws_get_current_iosurface_compression_header_span();
            *(uint64_t *)(shadowbuf + 0x40) = 0;
            uint64_t translated_50 = old_50;
            if (old_50 == 0 && old_58 != 0) {
                translated_50 = old_58;
            }
            if (compression_header_span != 0) {
                translated_50 |= (1ULL << 33);
            }
            *(uint64_t *)(shadowbuf + 0x50) = translated_50;
            *(uint64_t *)(shadowbuf + 0x58) = compression_header_span;
            if (current_surface_id != 0) {
                *(uint32_t *)(shadowbuf + 0x30) = current_surface_id;
                *(uint32_t *)(shadowbuf + 0x34) = current_plane;
                *(uint64_t *)(shadowbuf + 0x38) = 0;
            } else if (old_30 == 0 && old_38 != 0) {
                // Legacy callers outside the Metal swizzle still carry the
                // macOS surface ID at +0x38. Preserve their observed plane-0
                // behavior when no semantic wrapper scope exists.
                *(uint32_t *)(shadowbuf + 0x30) = old_38;
                *(uint32_t *)(shadowbuf + 0x34) = 0;
                *(uint64_t *)(shadowbuf + 0x38) = 0;
            }
            patched = 1;
            static _Atomic unsigned int t82_patch_count = 0;
            unsigned int t82_n = macws_runtime_diagnostics_enabled()
                ? atomic_fetch_add(&t82_patch_count, 1) + 1 : 0;
            static _Atomic unsigned int t82_plane_log_count = 0;
            unsigned int plane_log = t82_n && current_plane != 0
                ? atomic_fetch_add(&t82_plane_log_count, 1) + 1 : 0;
            if (t82_n && (t82_n <= 16 || (t82_n % 500) == 0 ||
                          (plane_log != 0 && plane_log <= 8))) {
                fprintf(stderr,
                    "#### AGXIOC type=0x82 patch #%u: scopeID=%#x scopePlane=%u "
                    "f14=%#x +0x30 {%#x,%#x}→{%#x,%#x} "
                    "+0x38 {%#x,%#x}→%#llx "
                    "+0x40 %#llx→0 +0x50 %#llx→%#llx +0x58 %#llx→%#llx\n",
                    t82_n, current_surface_id, current_plane, f14,
                    old_30, old_34,
                    *(const uint32_t *)(shadowbuf + 0x30),
                    *(const uint32_t *)(shadowbuf + 0x34),
                    old_38, old_3c,
                    (unsigned long long)*(const uint64_t *)(shadowbuf + 0x38),
                    (unsigned long long)old_40,
                    (unsigned long long)old_50,
                    (unsigned long long)*(const uint64_t *)(shadowbuf + 0x50),
                    (unsigned long long)old_58,
                    (unsigned long long)*(const uint64_t *)(shadowbuf + 0x58));
            }
        }
        if(patched) inStruct = shadowbuf;
        if (resDiagActive && resDiagSequence <= 64) {
            const unsigned char *sent = (const unsigned char *)inStruct;
            fprintf(stderr,
                "#### AGX_RES_DIAG #%u SENT type=%#x len=%zu:",
                resDiagSequence, sent[0], inStructCnt);
            for (size_t offset = 0; offset + 8 <= inStructCnt;
                 offset += 8) {
                fprintf(stderr, " +%02zx=%#llx", offset,
                    (unsigned long long)*(const uint64_t *)(sent + offset));
            }
            fprintf(stderr, "\n");
        }
        // POST-patch dump for sel=0x9 type=0x80: capture EXACT bytes that
        // hit the kernel — to compare against iOS-native probe args that
        // also fail kr=0xe00002be with all-zero-but-required-fields.
        if (agxType == 0x80 && macws_runtime_diagnostics_enabled()) {
            static int t80_post_dumped = 0;
            if (!t80_post_dumped) {
                t80_post_dumped = 1;
                fprintf(stderr,
                    "#### AGXIOC POST-PATCH sel=0x9 type=0x80 inStructCnt=%zu (bytes that hit kernel):\n",
                    inStructCnt);
                const unsigned char *p = (const unsigned char *)inStruct;
                for (size_t i = 0; i < inStructCnt; i += 16) {
                    fprintf(stderr, "    +%#04zx:", i);
                    for (size_t j = 0; j < 16 && (i + j) < inStructCnt; j++)
                        fprintf(stderr, " %02x", p[i + j]);
                    fprintf(stderr, "\n");
                }
            }
        }
    }
    struct macws_submit_diag_result submit_diag = {0};
    int translated_agx_submit = !skip && IOConnectIsIOGPU(client) &&
        selector == 0x1a;
    int submit_diag_active = translated_agx_submit &&
        macws_submit_diag_enabled();
    int submit_fix_active = translated_agx_submit &&
        macws_kcmd_fix_enabled();
    // The ABI translator and the byte-dump diagnostic are independent gates.
    // Previously, macws_kcmd_fix was silently inert unless submit_diag also
    // existed, which made the same PF80 submit complete in exclusive tests but
    // fail with MTL 0x102 in an ordinary VNC run.  Inspection is still needed
    // to prove all structural anchors before translating, but deep dumps are
    // emitted only when their own sentinel is present.
    if (submit_diag_active || submit_fix_active) {
        submit_diag = macws_inspect_agx_submit(
            in, inCnt, inStruct, inStructCnt,
            submit_fix_active, submit_diag_active);
    }
    unsigned queue_qos_diag_sequence = 0;
    if (IOConnectIsIOGPU(client) &&
        macws_queue_qos_diag_enabled() &&
        ((orig == 0x8 && selector == 0x7 && inStruct &&
          inStructCnt == 0x408) ||
         (orig == 0x1f && selector == 0x1b))) {
        static _Atomic unsigned queue_qos_diag_count = 0;
        queue_qos_diag_sequence = atomic_fetch_add(
            &queue_qos_diag_count, 1) + 1;
        if (queue_qos_diag_sequence <= 8) {
            if (orig == 0x8) {
                const unsigned char *queue = inStruct;
                char path_prefix[65] = {0};
                size_t path_length = strnlen((const char *)queue, 64);
                memcpy(path_prefix, queue, path_length);
                fprintf(stderr,
                    "#### AGX_QUEUE_QOS #%u CREATE orig=%#x sent=%#x "
                    "path='%s' qos=%u flag404=%u tail405=%02x%02x%02x "
                    "inCnt=%u\n",
                    queue_qos_diag_sequence, orig, selector, path_prefix,
                    *(const uint32_t *)(queue + 0x400), queue[0x404],
                    queue[0x405], queue[0x406], queue[0x407], inCnt);
            } else {
                const unsigned char *bytes = inStruct;
                fprintf(stderr,
                    "#### AGX_QUEUE_QOS #%u SET orig=%#x sent=%#x "
                    "scalar0=%#llx inCnt=%u inSC=%zu bytes=%s%02x%02x%02x%02x"
                    "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                    queue_qos_diag_sequence, orig, selector,
                    (unsigned long long)(in && inCnt ? in[0] : 0),
                    inCnt, inStructCnt,
                    inStruct && inStructCnt >= 12 ? "" : "(short)",
                    inStruct && inStructCnt > 0 ? bytes[0] : 0,
                    inStruct && inStructCnt > 1 ? bytes[1] : 0,
                    inStruct && inStructCnt > 2 ? bytes[2] : 0,
                    inStruct && inStructCnt > 3 ? bytes[3] : 0,
                    inStruct && inStructCnt > 4 ? bytes[4] : 0,
                    inStruct && inStructCnt > 5 ? bytes[5] : 0,
                    inStruct && inStructCnt > 6 ? bytes[6] : 0,
                    inStruct && inStructCnt > 7 ? bytes[7] : 0,
                    inStruct && inStructCnt > 8 ? bytes[8] : 0,
                    inStruct && inStructCnt > 9 ? bytes[9] : 0,
                    inStruct && inStructCnt > 10 ? bytes[10] : 0,
                    inStruct && inStructCnt > 11 ? bytes[11] : 0);
            }
        }
    }
    IOReturn r = IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if (queue_qos_diag_sequence && queue_qos_diag_sequence <= 8) {
        uint32_t queue_id = 0;
        uint64_t queue_token = 0;
        if (r == 0 && orig == 0x8 && outStruct && outStructCnt &&
            *outStructCnt >= 0x10) {
            queue_id = *(const uint32_t *)outStruct;
            queue_token = *(const uint64_t *)((const unsigned char *)outStruct + 8);
        }
        fprintf(stderr,
            "#### AGX_QUEUE_QOS #%u RETURN kr=%#x outSC=%zu "
            "queueID=%#x token=%#llx\n",
            queue_qos_diag_sequence, r,
            outStructCnt ? *outStructCnt : 0, queue_id,
            (unsigned long long)queue_token);
    }
    if (agxIsRes && resDiagActive && resDiagSequence <= 64) {
        size_t returned = (outStructCnt ? *outStructCnt : 0);
        fprintf(stderr,
            "#### AGX_RES_DIAG #%u RETURN kr=%#x outLen=%zu:",
            resDiagSequence, r, returned);
        if (outStruct) {
            const unsigned char *bytes = (const unsigned char *)outStruct;
            for (size_t offset = 0; offset + 8 <= returned; offset += 8) {
                fprintf(stderr, " +%02zx=%#llx", offset,
                    (unsigned long long)*(const uint64_t *)(bytes + offset));
            }
        }
        fprintf(stderr, "\n");
    }
    if (submit_diag_active && submit_diag.sequence <= 8) {
        fprintf(stderr,
            "#### AGX_SUBMIT_DIAG #%u result=%#x records=%u candidates=%u fixed=%u\n",
            submit_diag.sequence, r, submit_diag.records,
            submit_diag.candidates, submit_diag.fixed);
    }
    if (agxIsRes) {
        const unsigned char *sent = (const unsigned char *)inStruct;
        uint64_t requested = (sent && inStructCnt >= 0x48)
            ? *(const uint64_t *)(sent + 0x40) : 0;
        uint32_t client_id = (sent && inStructCnt >= 0x4c)
            ? *(const uint32_t *)(sent + 0x48) : 0;
        uint32_t surface_id = (agxType == 0x82 && sent && inStructCnt >= 0x34)
            ? *(const uint32_t *)(sent + 0x30) : 0;
        if (r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x50) {
            const unsigned char *o = (const unsigned char *)outStruct;
            uint64_t gpu_address = *(const uint64_t *)(o + 0x00);
            uint64_t data_bytes = *(const uint64_t *)(o + 0x08);
            uint64_t client_shared = *(const uint64_t *)(o + 0x10);
            uint64_t gid = *(const uint32_t *)(o + 0x1c);
            uint64_t bytes = *(const uint64_t *)(o + 0x48);
            uint32_t flags_14 = inStructCnt >= 0x18
                ? *(const uint32_t *)(sent + 0x14) : 0;
            uint64_t request_50 = inStructCnt >= 0x58
                ? *(const uint64_t *)(sent + 0x50) : 0;
            macws_agx_life_create(gid, agxType, client_id, surface_id,
                                  gpu_address, data_bytes, client_shared,
                                  bytes, flags_14, request_50,
                                  agxRawRequest, agxRawRequestLength,
                                  inStruct, inStructCnt);
            if (agxType == 0x82 && macws_runtime_diagnostics_enabled()) {
                static _Atomic unsigned int t82_bt_count = 0;
                unsigned int bt_n = atomic_fetch_add(&t82_bt_count, 1);
                if (bt_n < 4) {
                    void *frames[16];
                    int nf = backtrace(frames, 16);
                    fprintf(stderr,
                        "#### AGX_LIFE type82 CREATE stack #%u resourceID=%#llx surf=%#x (%d frames):\n",
                        bt_n + 1, (unsigned long long)gid, surface_id, nf);
                    backtrace_symbols_fd(frames, nf, STDERR_FILENO);
                }

                // Opt-in diagnostic for the display-sized resources that
                // dominate long native-AGX sessions.  The first four type-82
                // calls above happen during compositor bootstrap and miss the
                // later ~20 MiB CAWindowServerSurface churn.  Record successful
                // creates only; do not alter the arguments, result, ownership,
                // or finalize path.  A bounded count keeps a failed experiment
                // from turning its stderr into another pressure source.
                if (getenv("MACWS_AGX_LIFE_STACK_LARGE") &&
                    bytes >= (8ull << 20)) {
                    static _Atomic unsigned int large_t82_bt_count = 0;
                    unsigned int large_n =
                        atomic_fetch_add(&large_t82_bt_count, 1);
                    if (large_n < 24) {
                        void *frames[24];
                        int nf = backtrace(frames, 24);
                        fprintf(stderr,
                            "#### AGX_LIFE LARGE-TYPE82 stack #%u "
                            "resourceID=%#llx surf=%#x bytes=%#llx "
                            "(%d frames):\n",
                            large_n + 1, (unsigned long long)gid,
                            surface_id, (unsigned long long)bytes, nf);
                        backtrace_symbols_fd(frames, nf, STDERR_FILENO);
                    }
                }
            }
        } else if (r != 0) {
            macws_agx_life_create_failed(agxType, requested, r);
        }
    }
    if (IOConnectIsIOGPU(client) && orig == 0xb && in && inCnt >= 1) {
        // Runtime-correlate finalize's scalar against create out+0x1c.  The
        // first matched AGX_LIFE DESTROY line is the direct ABI witness.
        macws_agx_life_destroy(in[0], r);
    }
    // Log the kr for sel=0x9 type=0x80 once so we can pair it with the
    // POST-PATCH dump above.
    if (agxIsRes && agxType == 0x80 &&
        macws_runtime_diagnostics_enabled()) {
        static int t80_kr_logged = 0;
        if (!t80_kr_logged) {
            t80_kr_logged = 1;
            fprintf(stderr,
                "#### AGXIOC POST-CALL sel=0x9 type=0x80 -> kr=%#x\n", r);
        }
    }
    // Parameter fuzz: if sel=0x9 ResCreate returned BadArgument, try a
    // handful of perturbations and report which ones the kernel accepts.
    // One-shot per process (static seen flag) and only for type=0 heap
    // creates, since those are what's broken.
    if (getenv("MACWS_AGXIOC_FUZZ") && IOConnectIsIOGPU(client) && selector == 0x9 &&
        r == 0xe00002c2 && inStruct && inStructCnt >= 0x60) {
        static int s_fuzz_done = 0;
        const unsigned char *src = (const unsigned char *)inStruct;
        if (!s_fuzz_done && src[0] == 0) {
            s_fuzz_done = 1;
            unsigned char buf[256];
            struct { const char *name; int ofs; int sz; uint64_t val; } perturbs[] = {
                {"zero args+0x40",     0x40, 8, 0},
                {"args+0x40 = 0x1000", 0x40, 8, 0x1000},
                {"args+0x40 = 0x4000", 0x40, 8, 0x4000},
                {"zero args+0x58",     0x58, 8, 0},
                {"args+0x14 = 0",      0x14, 4, 0},
                {"args+0x10..1f = 0",  0x10, 8, 0},
                {"args+0x48 = 0",      0x48, 8, 0},
                {"args+0x60 = 0",      0x60, 8, 0},
                {"args+0x08 = 0",      0x08, 8, 0},
                {NULL, 0, 0, 0}
            };
            for (int i = 0; perturbs[i].name; i++) {
                memcpy(buf, inStruct, inStructCnt);
                if (perturbs[i].sz == 8) {
                    *(uint64_t*)(buf + perturbs[i].ofs) = perturbs[i].val;
                } else {
                    *(uint32_t*)(buf + perturbs[i].ofs) = (uint32_t)perturbs[i].val;
                }
                size_t osc = outStructCnt ? *outStructCnt : 0;
                IOReturn rr = IOConnectCallMethod(client, selector, in, inCnt,
                    buf, inStructCnt, out, outCnt, outStruct, outStructCnt ? &osc : NULL);
                fprintf(stderr,
                    "#### AGXIOC FUZZ [%s]: outSC=%zu → 0x%x\n",
                    perturbs[i].name, osc, rr);
                // Restore for next iteration
                if (outStructCnt) *outStructCnt = osc;
            }
            // Also try with outStructCnt = 0
            if (outStructCnt) {
                size_t saved = *outStructCnt;
                *outStructCnt = 0;
                memcpy(buf, inStruct, inStructCnt);
                IOReturn rr = IOConnectCallMethod(client, selector, in, inCnt,
                    buf, inStructCnt, out, outCnt, outStruct, outStructCnt);
                fprintf(stderr, "#### AGXIOC FUZZ [outStructCnt=0]: → 0x%x\n", rr);
                *outStructCnt = saved;
            }
        }
    }
    if(agxIsRes && r == 0 && agxType == 0 && outStruct && outStructCnt && *outStructCnt >= 0x30) {
        const unsigned char *o = (const unsigned char *)outStruct;
        uint64_t gid = *(const uint32_t *)(o + 0x1c);   // RE-confirmed iOS resource ID; finalize uses this exact scalar
        int slot = -1;
        for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) { slot = i; break; }  // overwrite (clientID reused)
        if(slot < 0 && g_agxIdMapCount < 128) slot = g_agxIdMapCount++;
        if(slot >= 0) { g_agxIdMap[slot].clientID = agxClientID; g_agxIdMap[slot].iosResourceID = gid; g_agxIdMap[slot].size = agxHeapSz; }
        static _Atomic unsigned int heap_map_count = 0;
        unsigned int heap_n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&heap_map_count, 1) + 1 : 0;
        if (heap_n && (heap_n <= 16 || (heap_n % 500) == 0)) {
            fprintf(stderr,
                "#### AGXIOC heap map #%u clientID %#x -> resourceID %#llx size %#llx\n",
                heap_n, agxClientID, (unsigned long long)gid,
                (unsigned long long)agxHeapSz);
        }
    }
    if(IOConnectIsIOGPU(client) && macws_runtime_diagnostics_enabled()) {
        // Resource create/destroy have their own structured AGX_LIFE logs.
        // Successful submit/finalize calls are also a per-frame hot path: the
        // previous unconditional line reached tens of thousands of writes in
        // a two-minute idle session. Keep startup + periodic witnesses and
        // every failure without turning stderr into part of the workload.
        static _Atomic unsigned long methodSuccessCount[256];
        unsigned index = orig < 256 ? orig : 255;
        unsigned long successSequence = r == 0
            ? atomic_fetch_add(&methodSuccessCount[index], 1) + 1 : 0;
        BOOL logMethod = r != 0 ||
            ((orig != 0xa && orig != 0xb) &&
             (successSequence <= 8 || (successSequence % 1000) == 0));
        if (logMethod) {
            fprintf(stderr,
                "#### AGXIOC Method sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n",
                orig, selector, inCnt, inStructCnt,
                outStructCnt ? *outStructCnt : 0, r);
        }
        // Diagnostic: dump the inStruct for sel=0x7/0x8 failures (queue
        // creation). 1032-byte args; the iOS kernel rejects with 0xe00002c2.
        // Dump first 128 bytes + scan for non-zero regions so we can RE the
        // macOS-vs-iOS field divergence.
        if (r == 0xe00002c2 && (orig == 0x7 || orig == 0x8) &&
            inStruct && inStructCnt >= 0x10) {
            const unsigned char *src = (const unsigned char *)inStruct;
            static int q_dump_done[2] = {0, 0};
            int slot = (orig == 0x7) ? 0 : 1;
            if (!q_dump_done[slot]) {
                q_dump_done[slot] = 1;
                fprintf(stderr,
                    "####   QueueCreate sel=0x%x inSC=%zu FAIL — full dump:\n",
                    orig, inStructCnt);
                // Hex dump head + every non-zero u64 chunk
                size_t max = inStructCnt;
                for (size_t i = 0; i < max && i < 256; i++) {
                    if (i % 16 == 0) fprintf(stderr, "\n####     %03zx:", i);
                    fprintf(stderr, " %02x", src[i]);
                }
                fprintf(stderr, "\n");
                // Scan for non-zero u64s past offset 256
                size_t step = 8;
                for (size_t i = 256; i + step <= inStructCnt; i += step) {
                    uint64_t v = *(const uint64_t *)(src + i);
                    if (v) {
                        fprintf(stderr,
                            "####     +%03zx: %016llx\n",
                            i, (unsigned long long)v);
                    }
                }
            }
        }
        // Diagnostic: dump the inStruct for ALL sel=0xa calls (resource
        // create). Compare successful heap (line A) vs failing texture
        // (line B) so we can identify what kernel rejects.
        static _Atomic unsigned int res_verbose_count = 0;
        unsigned int res_verbose_n = (orig == 0xa && selector == 0x9)
            ? atomic_fetch_add(&res_verbose_count, 1) : UINT_MAX;
        if (orig == 0xa && selector == 0x9 &&
            inStruct && inStructCnt >= 0x60 &&
            (r != 0 || res_verbose_n < 48)) {
            const unsigned char *src = (const unsigned char *)inStruct;
            uint8_t type = src[0];
            uint32_t clientID = *(const uint32_t *)(src + 0x48);
            uint64_t f30 = *(const uint64_t *)(src + 0x30);
            uint64_t va38 = *(const uint64_t *)(src + 0x38);
            uint64_t bc40 = *(const uint64_t *)(src + 0x40);
            uint64_t va58 = *(const uint64_t *)(src + 0x58);
            // RE-confirmed via the actual iOS 16.3 and macOS 13.4
            // IOGPUResourceCreate implementations: kernel output +0 is
            // copied to IOGPUResource+0x38. IOGPUResourceGetGPUVirtualAddress
            // returns that field, and IOGPUMetalResource init stores it in
            // the ivar returned by -gpuAddress. Output +0x1c is resourceID;
            // output +0x48 is the GPU-VA span. Keep +0x10 in the log because
            // it is a distinct client-shared field, not the GPU address.
            uint64_t out00 = 0, out08 = 0, out10 = 0, out48 = 0;
            if (r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x18) {
                const unsigned char *o = (const unsigned char *)outStruct;
                out00 = *(const uint64_t *)(o + 0x00);
                out08 = *(const uint64_t *)(o + 0x08);
                out10 = *(const uint64_t *)(o + 0x10);
                if (*outStructCnt >= 0x50)
                    out48 = *(const uint64_t *)(o + 0x48);
            }
            fprintf(stderr,
                "####   ResCreate %s type=%#x clientID=%#x "
                "+0x30=%#llx +0x38=%#llx +0x40=%#llx +0x58=%#llx "
                "OUT[+0]=%#llx OUT[+0x08]=%#llx OUT[+0x10]=%#llx "
                "OUT[+0x48]=%#llx\n",
                r ? "FAIL" : "OK",
                type, clientID,
                (unsigned long long)f30, (unsigned long long)va38,
                (unsigned long long)bc40,
                (unsigned long long)va58,
                (unsigned long long)out00, (unsigned long long)out08,
                (unsigned long long)out10, (unsigned long long)out48);
            // Hex dump first 0x70 bytes
            fprintf(stderr, "####   inStruct[0..%zu]:", inStructCnt);
            for (size_t i = 0; i < inStructCnt && i < 0x70; i++) {
                if (i % 16 == 0) fprintf(stderr, "\n####     %02zx:", i);
                fprintf(stderr, " %02x", src[i]);
            }
            fprintf(stderr, "\n");
            // For each FAILED type=0x80 sub-resource: dump the caller chain
            // so we know which AGXBuffer / IOGPUMetalBuffer path picked the
            // parent. Sometimes ties macOS's `allocBufferSubData` vs the
            // standalone init path.
            if (r != 0 && type == 0x80) {
                void *frames[12];
                int nf = backtrace(frames, 12);
                fprintf(stderr, "####   caller chain (%d frames):\n", nf);
                for (int i = 0; i < nf; i++) {
                    Dl_info di;
                    if (dladdr(frames[i], &di) && di.dli_fname) {
                        uintptr_t base = (uintptr_t)di.dli_fbase;
                        const char *fname = strrchr(di.dli_fname, '/');
                        fname = fname ? fname + 1 : di.dli_fname;
                        fprintf(stderr, "####     [%d] %p %s+%#llx (%s)\n",
                            i, frames[i],
                            di.dli_sname ? di.dli_sname : "?",
                            (unsigned long long)((uintptr_t)frames[i] -
                                (uintptr_t)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)),
                            fname);
                    } else {
                        fprintf(stderr, "####     [%d] %p (unmapped)\n", i, frames[i]);
                    }
                }
            }
        }
    }
    if (qbuf) free(qbuf);
    return r;
}
IOReturn IOConnectCallScalarMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    if (!caller_is_libmachook(__builtin_return_address(0)))
        selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallScalarMethod(client, selector, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client) && orig != selector &&
        macws_runtime_diagnostics_enabled()) {
        static _Atomic unsigned long scalarSuccessCount[256];
        unsigned index = orig < 256 ? orig : 255;
        unsigned long successSequence = r == 0
            ? atomic_fetch_add(&scalarSuccessCount[index], 1) + 1 : 0;
        if (r != 0 || successSequence <= 8 || (successSequence % 1000) == 0) {
            fprintf(stderr,
                "#### AGXIOC Scalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n",
                orig, selector, inCnt, r);
        }
    }
    return r;
}

// RE-confirmed via the actual macOS 13.4 IOMobileFramebuffer image
// 9485C742-B91F-3C6C-897C-AB2C8ACF7625:
//
//   kern_SwapEnd    0x18b026400..0x18b0264e0
//     selector 5; then releases framebuffer+0xb00, increments +0x670, and
//     periodically reports underrun analytics.
//   kern_SwapCancel 0x18b026714..0x18b026778
//     selector 0x34 with the swap ID; then returns directly.
//
// Translating only SwapEnd's nested IOConnect call to selector 0x34 therefore
// ran the wrong user-space tail after a successful cancellation.  Interpose at
// the exported protocol boundary instead: pair SwapBegin with the complete
// public SwapCancel operation and never enter SwapEnd.  The narrow nested-call
// adapter below remains only as a fail-safe for any direct kern_SwapEnd caller
// that bypasses this exported API.
extern IOReturn IOMobileFramebufferSwapEnd(MacwsIOMobileFramebufferRef framebuffer);
extern IOReturn IOMobileFramebufferSwapCancel(
    MacwsIOMobileFramebufferRef framebuffer, uint32_t swap_id);

// Diagnostic-only pacing knob for the cancelled-swap completion scaffold.
// The production default stays at one 60-Hz interval. A bounded slower value
// lets an A/B test distinguish a producer/backpressure problem from a command
// ABI or resource-lifetime problem without changing either command bytes or
// completion semantics. This is intentionally not presented as a refresh-rate
// implementation: the synthetic completion is still not a real display/GPU
// completion signal.
uint32_t macws_coexist_completion_pace_us(void) {
    enum {
        kDefaultPaceUS = 16667,
        kMinimumPaceUS = 8333,
        kMaximumPaceUS = 100000,
    };
    static dispatch_once_t once;
    static uint32_t pace_us = kDefaultPaceUS;
    dispatch_once(&once, ^{
        char file_value[32] = {0};
        const char *value = getenv("MACWS_COEXIST_PACE_US");
        const char *source = "default";
        if (value && *value) {
            source = "environment";
        } else {
            int fd = open("/private/tmp/macws_coexist_pace_us", O_RDONLY);
            if (fd >= 0) {
                ssize_t count = read(fd, file_value, sizeof(file_value) - 1);
                close(fd);
                if (count > 0) {
                    file_value[count] = '\0';
                    value = file_value;
                    source = "diagnostic-file";
                }
            }
        }

        if (value && *value) {
            char *end = NULL;
            errno = 0;
            unsigned long parsed = strtoul(value, &end, 10);
            while (end && (*end == ' ' || *end == '\t' ||
                           *end == '\r' || *end == '\n')) {
                end++;
            }
            if (errno == 0 && end && end != value && *end == '\0' &&
                parsed >= kMinimumPaceUS && parsed <= kMaximumPaceUS) {
                pace_us = (uint32_t)parsed;
            } else {
                fprintf(stderr,
                    "#### COEXIST DIAGNOSTIC pace rejected: source=%s "
                    "value='%s' valid=%u..%u us; using default=%u us\n",
                    source, value, kMinimumPaceUS, kMaximumPaceUS,
                    kDefaultPaceUS);
                source = "default-after-invalid-value";
            }
        }
        if (macws_runtime_diagnostics_enabled()) {
            fprintf(stderr,
                "#### VIRTUAL-DISPLAY-COMPAT completion pace: %u us source=%s "
                "(synthetic completion; not a refresh-rate implementation)\n",
                pace_us, source);
        }
    });
    return pace_us;
}

uint32_t macws_coexist_activity_pace_us(uint32_t idle_pace_us) {
    enum {
        kInteractivePaceUS = 16667,
        kInteractionWindowNS = 1000 * NSEC_PER_MSEC,
    };
    if (idle_pace_us <= kInteractivePaceUS) return idle_pace_us;

    static int activity_fd = -1;
    if (activity_fd < 0) {
        activity_fd = open("/private/tmp/macws_vnc_activity",
                           O_RDONLY | O_CLOEXEC);
    }
    uint64_t activity_ns = 0;
    BOOL interactive = NO;
    if (activity_fd >= 0 &&
        pread(activity_fd, &activity_ns,
              sizeof(activity_ns), 0) == sizeof(activity_ns)) {
        struct timespec now = {0};
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            uint64_t now_ns = (uint64_t)now.tv_sec * NSEC_PER_SEC +
                (uint64_t)now.tv_nsec;
            interactive = now_ns >= activity_ns &&
                now_ns - activity_ns <= kInteractionWindowNS;
        }
    }

    if (macws_runtime_diagnostics_enabled()) {
        static _Atomic int prior_mode = -1;
        int mode = interactive ? 1 : 0;
        int prior = atomic_exchange_explicit(
            &prior_mode, mode, memory_order_acq_rel);
        if (prior != mode) {
            fprintf(stderr,
                "#### COEXIST DIAGNOSTIC activity pace: mode=%s "
                "pace=%u us idle=%u us window=1000ms\n",
                interactive ? "interactive" : "idle",
                interactive ? kInteractivePaceUS : idle_pace_us,
                idle_pace_us);
        }
    }
    return interactive ? kInteractivePaceUS : idle_pace_us;
}

// Pace completion timestamps, not post-render delays.  The former fixed
// usleep(interval) below made the virtual frame period equal to
// render_time + interval; the 2026-07-28 Chromium 148 control consequently
// produced an average 55-ms rAF interval while each 100-draw issue took only
// 0.09 ms.  Keep one synchronous completion per swap (so no callback FIFO can
// accumulate), but subtract time already spent rendering since the preceding
// completion.  This remains a virtual-display timing scaffold, not a claim
// that a synthetic callback is a hardware vblank or GPU fence.
int macws_coexist_interaction_wake_socket(void) {
    static dispatch_once_t once;
    static int socket_fd = -1;
    dispatch_once(&once, ^{
        int candidate = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (candidate < 0) return;

        (void)fcntl(candidate, F_SETFD, FD_CLOEXEC);
        int flags = fcntl(candidate, F_GETFL, 0);
        if (flags >= 0) {
            (void)fcntl(candidate, F_SETFL, flags | O_NONBLOCK);
        }
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        address.sun_len = sizeof(address);
        strlcpy(address.sun_path, MACWS_INTERACTION_WAKE_SOCKET_PATH,
                sizeof(address.sun_path));
        (void)unlink(MACWS_INTERACTION_WAKE_SOCKET_PATH);
        if (bind(candidate, (const struct sockaddr *)&address,
                 sizeof(address)) != 0) {
            close(candidate);
            return;
        }
        (void)chmod(MACWS_INTERACTION_WAKE_SOCKET_PATH, 0666);
        socket_fd = candidate;
    });
    return socket_fd;
}

void macws_coexist_drain_interaction_wake(int socket_fd) {
    uint8_t tokens[64];
    while (recv(socket_fd, tokens, sizeof(tokens), MSG_DONTWAIT) > 0) {
    }
}

uint32_t macws_coexist_wait_for_completion_slot(uint32_t interval_us) {
    static pthread_mutex_t pace_lock = PTHREAD_MUTEX_INITIALIZER;
    static uint64_t last_completion_ns = 0;
    uint32_t slept_us = 0;

    pthread_mutex_lock(&pace_lock);
    struct timespec now_ts = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now_ts) == 0) {
        uint64_t start_ns = (uint64_t)now_ts.tv_sec * NSEC_PER_SEC +
            (uint64_t)now_ts.tv_nsec;
        uint64_t base_ns = last_completion_ns ? last_completion_ns : start_ns;
        uint32_t effective_interval_us = interval_us;
        uint64_t target_ns = base_ns +
            (uint64_t)effective_interval_us * 1000u;
        uint64_t now_ns = start_ns;
        int wake_fd = macws_coexist_interaction_wake_socket();

        while (target_ns > now_ns) {
            uint64_t remaining_ns = target_ns - now_ns;
            uint64_t remaining_ms = (remaining_ns + NSEC_PER_MSEC - 1) /
                NSEC_PER_MSEC;
            if (remaining_ms > INT_MAX) remaining_ms = INT_MAX;
            bool interaction_wake = false;
            if (wake_fd >= 0) {
                struct pollfd descriptor = {
                    .fd = wake_fd,
                    .events = POLLIN,
                };
                int poll_result;
                do {
                    poll_result = poll(&descriptor, 1, (int)remaining_ms);
                } while (poll_result < 0 && errno == EINTR);
                if (poll_result > 0 && (descriptor.revents & POLLIN)) {
                    macws_coexist_drain_interaction_wake(wake_fd);
                    interaction_wake = true;
                } else if (poll_result < 0) {
                    uint64_t remaining_us = (remaining_ns + 999u) / 1000u;
                    usleep((useconds_t)MIN(remaining_us, UINT32_MAX));
                }
            } else {
                uint64_t remaining_us = (remaining_ns + 999u) / 1000u;
                usleep((useconds_t)MIN(remaining_us, UINT32_MAX));
            }

            if (clock_gettime(CLOCK_MONOTONIC, &now_ts) != 0) break;
            now_ns = (uint64_t)now_ts.tv_sec * NSEC_PER_SEC +
                (uint64_t)now_ts.tv_nsec;
            if (interaction_wake) {
                uint32_t interactive_interval =
                    macws_coexist_activity_pace_us(interval_us);
                if (interactive_interval < effective_interval_us) {
                    effective_interval_us = interactive_interval;
                    target_ns = base_ns +
                        (uint64_t)effective_interval_us * 1000u;
                }
            }
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now_ts) == 0) {
            last_completion_ns = (uint64_t)now_ts.tv_sec * NSEC_PER_SEC +
                (uint64_t)now_ts.tv_nsec;
            uint64_t elapsed_us =
                (last_completion_ns - start_ns + 999u) / 1000u;
            slept_us = (uint32_t)MIN(elapsed_us, UINT32_MAX);
        } else {
            last_completion_ns = target_ns;
        }
    } else {
        // Preserve the established bounded behavior if the monotonic clock is
        // unexpectedly unavailable on a future target.
        slept_us = interval_us;
        usleep((useconds_t)interval_us);
    }
    pthread_mutex_unlock(&pace_lock);
    return slept_us;
}

IOReturn MacwsIOMobileFramebufferSwapEnd_new(void *framebuffer) {
    if (!atomic_load(&g_macws_iomfb_coexist_swap_cancel) || !framebuffer) {
        return g_macws_orig_iomfb_swap_end
            ? g_macws_orig_iomfb_swap_end(framebuffer)
            : IOMobileFramebufferSwapEnd(framebuffer);
    }

    uint32_t swap_id = *(const volatile uint32_t *)
        ((const char *)framebuffer + 0x68);
    uint64_t requested_presentation_time = mach_absolute_time();
    IOReturn result = IOMobileFramebufferSwapCancel(framebuffer, swap_id);
    static _Atomic unsigned long cancel_count = 0;
    unsigned long sequence = macws_runtime_diagnostics_enabled()
        ? atomic_fetch_add(&cancel_count, 1) + 1 : 0;
    if ((sequence &&
         (sequence <= 16 || (sequence % 600) == 0)) ||
        result != KERN_SUCCESS) {
        fprintf(stderr,
            "#### COEXIST API SwapCancel #%lu: fb=%p swapID=%u -> %#x "
            "(SwapEnd tail skipped)\n",
            sequence, framebuffer, swap_id, result);
    }
    if (result == KERN_SUCCESS) {
        // Runtime-confirmed 2026-07-26: immediate synthetic completion drove
        // 3,600 swaps/minute and held WindowServer at 98% CPU until the
        // thermal watchdog stopped it.  The earlier asynchronous 200-ms FIFO
        // did not pace submissions and grew without bound.  Block this exact
        // SwapEnd ownership boundary for one 60-Hz interval before queueing
        // its one matching completion.  Pace against the preceding completion
        // timestamp so render work counts toward (rather than being added to)
        // the requested interval.
        BOOL paced_before_server_locks =
            g_macws_iomfbserver_finish_depth != 0;
        uint32_t pace_us = 0;
        uint32_t slept_us = 0;
        if (!paced_before_server_locks) {
            pace_us = macws_coexist_activity_pace_us(
                macws_coexist_completion_pace_us());
            slept_us = macws_coexist_wait_for_completion_slot(pace_us);
        }
        io_connect_t client = *(const volatile io_connect_t *)
            ((const char *)framebuffer + 0x14);
        macws_iomfb_complete_cancelled_swap(
            client, swap_id, requested_presentation_time);
        if (sequence && sequence <= 4) {
            fprintf(stderr,
                "#### COEXIST completion pace #%lu: interval=%u us "
                "slept=%u us pre-lock=%s before swapID=%u\n",
                sequence, pace_us, slept_us,
                paced_before_server_locks ? "YES" : "NO", swap_id);
        }
    }
    return result;
}

IOReturn IOConnectCallStructMethod_new(io_connect_t client, uint32_t selector, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int struct_skip = caller_is_libmachook(__builtin_return_address(0));
    if (!struct_skip)
        selector = IOConnectTranslateSelector(client, selector);
    // macOS 13.4 kern_SwapEnd passes conn+0x18 as its 0x46c-byte selector-5
    // input. SwapBegin stored the active swap ID at conn+0x68, hence input+0x50.
    // In coexistence, cancel that exact swap through the RE-confirmed iOS ABI
    // instead of presenting to the panel. Return the real cancel status; the
    // caller then continues the remainder of kern_SwapEnd normally.
    // `/tmp/macws_real_swapend` is a short-lived A/B diagnostic only.  It
    // leaves the verified macOS selector-5 call entirely untouched so we can
    // measure whether the Cancel substitution itself breaks page ownership.
    // Do not ship the sentinel: a real SwapEnd can contend with backboardd for
    // the physical panel in coexistence mode.
    BOOL realSwapEndDiagnostic =
        macws_real_swapend_diagnostic_enabled();
    if (!struct_skip && !realSwapEndDiagnostic &&
        atomic_load(&g_macws_iomfb_coexist_swap_cancel) &&
        orig == 5 && selector == 5 && inStruct && inStructCnt == 0x46c) {
        uint32_t swap_id = *(const volatile uint32_t *)((const char *)inStruct + 0x50);
        uint64_t scalar = swap_id;
        uint64_t requested_presentation_time = mach_absolute_time();
        IOReturn cancel_r = IOConnectCallScalarMethod(
            client, 0x34, &scalar, 1, NULL, NULL);
        static _Atomic unsigned long cancel_count = 0;
        unsigned long cancel_n = macws_runtime_diagnostics_enabled()
            ? atomic_fetch_add(&cancel_count, 1) + 1 : 0;
        if ((cancel_n &&
             (cancel_n <= 8 || (cancel_n % 600) == 0)) ||
            cancel_r != KERN_SUCCESS) {
            fprintf(stderr,
                "#### COEXIST SwapCancel #%lu: conn=%u swapID=%u sel=0x34 -> %#x\n",
                cancel_n, client, swap_id, cancel_r);
        }

        if (cancel_r == KERN_SUCCESS) {
            // The public SwapEnd trampoline normally owns this pacing.  This
            // branch is its exact-call-shape fallback, so it must preserve the
            // same one-submit/one-paced-completion invariant.  Runtime-
            // confirmed 2026-07-29: the Mac cross-build had compiled the
            // public hook out, this unpaced path delivered 4,200 completions
            // in a bounded run and kept WindowServer hot even at an intended
            // 100-ms idle pace.
            BOOL paced_before_server_locks =
                g_macws_iomfbserver_finish_depth != 0;
            uint32_t pace_us = 0;
            uint32_t slept_us = 0;
            if (!paced_before_server_locks) {
                pace_us = macws_coexist_activity_pace_us(
                    macws_coexist_completion_pace_us());
                slept_us = macws_coexist_wait_for_completion_slot(pace_us);
            }
            macws_iomfb_complete_cancelled_swap(
                client, swap_id, requested_presentation_time);
            if (cancel_n && cancel_n <= 4) {
                fprintf(stderr,
                    "#### COEXIST fallback completion pace #%lu: "
                    "interval=%u us slept=%u us pre-lock=%s before swapID=%u\n",
                    cancel_n, pace_us, slept_us,
                    paced_before_server_locks ? "YES" : "NO", swap_id);
            }
        }

        return cancel_r;
    }
    // AGX GPU device-info query (method 256 / setupImmediate): macOS 13.4 asks for
    // a 0x78 (120-byte) output struct, but the iOS 16.x GPU userclient hard-checks
    // the output size at 0x70 (112). The 8-byte mismatch -> kIOReturnBadArgument and
    // AGX device init aborts. Clamp to what the iOS kernel accepts. (Found by diffing
    // macOS AGXMetal13_3 727C250E vs iOS BA327004 in Ghidra: both selector 0x100,
    // outStructCnt 0x78 vs 0x70.)
    if(IOConnectIsIOGPU(client) && selector == 0x100 && outStructCnt && *outStructCnt == 0x78) {
        *outStructCnt = 0x70;
    }
    IOReturn r = IOConnectCallStructMethod(client, selector, inStruct, inStructCnt, outStruct, outStructCnt);
    // Read-only witness for the exclusive-mode control experiment.  The exact
    // 0x46c-byte shape is the macOS 13.4 kern_SwapEnd call verified above;
    // coexistence returns from the narrow SwapCancel branch before reaching
    // this point.  Do not change the selector, payload, return code, or state.
    if ((getenv("MACWS_IOMFB_SWAP_TRACE") || realSwapEndDiagnostic) && !struct_skip &&
        orig == 5 && selector == 5 && inStruct && inStructCnt == 0x46c) {
        uint32_t swap_id =
            *(const volatile uint32_t *)((const char *)inStruct + 0x50);
        static _Atomic unsigned long real_swap_count = 0;
        unsigned long swap_n = atomic_fetch_add(&real_swap_count, 1) + 1;
        if (swap_n <= 16 || (swap_n % 600) == 0 || r != KERN_SUCCESS) {
            fprintf(stderr,
                "#### IOMFB REAL SwapEnd #%lu: conn=%u swapID=%u "
                "sel=5 bytes=0x46c -> %#x\n",
                swap_n, client, swap_id, r);
        }
    }
    if(IOConnectIsIOGPU(client) && orig != selector &&
       macws_runtime_diagnostics_enabled())
        fprintf(stderr, "#### AGXIOC Struct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncMethod(client, selector, wake_port, ref, refCnt, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client) && macws_runtime_diagnostics_enabled())
        fprintf(stderr, "#### AGXIOC AsyncMethod sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inCnt, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncScalarMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    if (IOConnectIsIOGPU(client) && orig == 0x107 &&
        macws_runtime_diagnostics_enabled() &&
        macws_iogpu_error_diag_enabled()) {
        static _Atomic unsigned registration_count = 0;
        unsigned sequence = atomic_fetch_add(&registration_count, 1) + 1;
        if (sequence <= 8) {
            void *caller = __builtin_return_address(0);
            Dl_info caller_info = {0};
            (void)dladdr(caller, &caller_info);
            fprintf(stderr,
                "#### AGXIOC ASYNC-REGISTER #%u conn=%u sel=0x%x->0x%x "
                "wake=%u ref=%p refCnt=%u inCnt=%u caller=%p image=%s "
                "symbol=%s\n",
                sequence, client, orig, selector, wake_port, ref, refCnt,
                inCnt, caller,
                caller_info.dli_fname ?: "(unknown)",
                caller_info.dli_sname ?: "(unknown)");
            uint32_t limit = refCnt < 8 ? refCnt : 8;
            for (uint32_t index = 0; ref && index < limit; index++) {
                void *candidate = (void *)(uintptr_t)ref[index];
                Dl_info info = {0};
                int resolved = candidate ? dladdr(candidate, &info) : 0;
                fprintf(stderr,
                    "#### AGXIOC ASYNC-REFERENCE registration=%u index=%u "
                    "value=%#llx image=%s symbol=%s symbolAddress=%p\n",
                    sequence, index, (unsigned long long)ref[index],
                    resolved && info.dli_fname ? info.dli_fname : "(none)",
                    resolved && info.dli_sname ? info.dli_sname : "(none)",
                    resolved ? info.dli_saddr : NULL);
            }
        }
    }
    IOReturn r = IOConnectCallAsyncScalarMethod(client, selector, wake_port, ref, refCnt, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client) && macws_runtime_diagnostics_enabled())
        fprintf(stderr, "#### AGXIOC AsyncScalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallAsyncStructMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncStructMethod(client, selector, wake_port, ref, refCnt, inStruct, inStructCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncStruct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}

// Read-only CVDisplayLink protocol witness for the Chromium/WebGL pacing
// investigation.  Chromium creates its link with an explicit
// CGDirectDisplayID, whereas the control probe that remains near 120 Hz uses
// CVDisplayLinkCreateWithActiveCGDisplays.  When the sentinel exists, retain
// Chromium's callback unchanged and log the exact requested/current display
// IDs plus the `now` and `outputTime` values delivered by CoreVideo.  This is
// deliberately not a timestamp correction: it establishes which layer first
// produces the negative callback_timebase_to_display value seen in Chromium's
// trace before an adapter is considered.

extern MacwsCVReturn CVDisplayLinkCreateWithCGDisplay(
    MacwsCGDirectDisplayID display_id, MacwsCVDisplayLinkRef *display_link_out);
extern MacwsCVReturn CVDisplayLinkSetOutputCallback(
    MacwsCVDisplayLinkRef display_link,
    MacwsCVDisplayLinkOutputCallback callback,
    void *user_info);
extern MacwsCGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(
    MacwsCVDisplayLinkRef display_link);
extern uint64_t CVGetCurrentHostTime(void);


pthread_mutex_t g_macws_cvdisplaylink_trace_lock =
    PTHREAD_MUTEX_INITIALIZER;
struct macws_cvdisplaylink_trace_slot
    g_macws_cvdisplaylink_trace_slots[8];

bool macws_cvdisplaylink_trace_enabled(void) {
    return access("/tmp/macws_cvdl_trace", F_OK) == 0;
}

int64_t macws_cvdisplaylink_tick_delta(uint64_t later,
                                              uint64_t earlier) {
    return later >= earlier
        ? (int64_t)(later - earlier)
        : -(int64_t)(earlier - later);
}

struct macws_cvdisplaylink_trace_slot *
macws_cvdisplaylink_trace_find_or_allocate(MacwsCVDisplayLinkRef display_link) {
    struct macws_cvdisplaylink_trace_slot *empty = NULL;
    for (unsigned index = 0;
         index < sizeof(g_macws_cvdisplaylink_trace_slots) /
                     sizeof(g_macws_cvdisplaylink_trace_slots[0]);
         index++) {
        struct macws_cvdisplaylink_trace_slot *slot =
            &g_macws_cvdisplaylink_trace_slots[index];
        if (slot->display_link == display_link) return slot;
        if (!slot->display_link && !empty) empty = slot;
    }
    if (empty) {
        empty->display_link = display_link;
        empty->requested_display_id = UINT32_MAX;
        atomic_store_explicit(&empty->callback_count, 0,
                              memory_order_relaxed);
    }
    return empty;
}

MacwsCVReturn macws_cvdisplaylink_trace_callback(
    MacwsCVDisplayLinkRef display_link,
    const MacwsCVTimeStampPrefix *now,
    const MacwsCVTimeStampPrefix *output_time,
    MacwsCVOptionFlags flags_in,
    MacwsCVOptionFlags *flags_out,
    void *slot_context) {
    struct macws_cvdisplaylink_trace_slot *slot = slot_context;
    MacwsCVDisplayLinkOutputCallback callback = NULL;
    void *user_info = NULL;
    MacwsCGDirectDisplayID requested_display_id = UINT32_MAX;
    pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
    if (slot) {
        callback = slot->callback;
        user_info = slot->user_info;
        requested_display_id = slot->requested_display_id;
    }
    pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);

    unsigned long sequence = slot
        ? atomic_fetch_add_explicit(&slot->callback_count, 1,
                                    memory_order_relaxed) + 1
        : 0;
    const bool should_log = sequence <= 24 || (sequence % 600) == 0;
    const uint64_t callback_entry_host_time = should_log
        ? CVGetCurrentHostTime() : 0;
    if (should_log) {
        const uint64_t current_host_time = callback_entry_host_time;
        const uint64_t now_host_time = now ? now->hostTime : 0;
        const uint64_t output_host_time = output_time
            ? output_time->hostTime : 0;
        const MacwsCGDirectDisplayID current_display_id =
            CVDisplayLinkGetCurrentCGDisplay(display_link);
        fprintf(stderr,
            "#### CVDL-TRACE callback #%lu link=%p requested=%#x "
            "current=%#x now.host=%llu output.host=%llu current.host=%llu "
            "output-now=%lld output-current=%lld current-now=%lld "
            "now.video=%lld/%d output.video=%lld/%d refresh=%lld "
            "flags=%#llx\n",
            sequence, display_link, requested_display_id,
            current_display_id,
            (unsigned long long)now_host_time,
            (unsigned long long)output_host_time,
            (unsigned long long)current_host_time,
            (long long)macws_cvdisplaylink_tick_delta(
                output_host_time, now_host_time),
            (long long)macws_cvdisplaylink_tick_delta(
                output_host_time, current_host_time),
            (long long)macws_cvdisplaylink_tick_delta(
                current_host_time, now_host_time),
            (long long)(now ? now->videoTime : 0),
            now ? now->videoTimeScale : 0,
            (long long)(output_time ? output_time->videoTime : 0),
            output_time ? output_time->videoTimeScale : 0,
            (long long)(output_time ? output_time->videoRefreshPeriod : 0),
            (unsigned long long)flags_in);
    }

    MacwsCVReturn result = callback
        ? callback(display_link, now, output_time, flags_in, flags_out,
                   user_info)
        : 0;
    if (should_log) {
        const uint64_t callback_return_host_time = CVGetCurrentHostTime();
        fprintf(stderr,
            "#### CVDL-TRACE callback-return #%lu link=%p result=%d "
            "entry.host=%llu return.host=%llu duration.ticks=%lld\n",
            sequence, display_link, result,
            (unsigned long long)callback_entry_host_time,
            (unsigned long long)callback_return_host_time,
            (long long)macws_cvdisplaylink_tick_delta(
                callback_return_host_time, callback_entry_host_time));
    }
    return result;
}

MacwsCVReturn CVDisplayLinkCreateWithCGDisplay_new(
    MacwsCGDirectDisplayID display_id,
    MacwsCVDisplayLinkRef *display_link_out) {
    MacwsCVReturn result = CVDisplayLinkCreateWithCGDisplay(
        display_id, display_link_out);
    if (!macws_cvdisplaylink_trace_enabled()) return result;

    MacwsCVDisplayLinkRef display_link =
        result == 0 && display_link_out ? *display_link_out : NULL;
    if (display_link) {
        pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
        struct macws_cvdisplaylink_trace_slot *slot =
            macws_cvdisplaylink_trace_find_or_allocate(display_link);
        if (slot) slot->requested_display_id = display_id;
        pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);
    }

    static _Atomic unsigned long create_count = 0;
    unsigned long sequence = atomic_fetch_add_explicit(
        &create_count, 1, memory_order_relaxed) + 1;
    void *caller = __builtin_return_address(0);
    Dl_info caller_info = {0};
    (void)dladdr(caller, &caller_info);
    MacwsCGDirectDisplayID current_display_id = display_link
        ? CVDisplayLinkGetCurrentCGDisplay(display_link) : UINT32_MAX;
    fprintf(stderr,
        "#### CVDL-TRACE create #%lu requested=%#x result=%d link=%p "
        "current=%#x caller=%p image=%s symbol=%s\n",
        sequence, display_id, result, display_link, current_display_id,
        caller, caller_info.dli_fname ?: "(unknown)",
        caller_info.dli_sname ?: "(unknown)");
    return result;
}

MacwsCVReturn CVDisplayLinkSetOutputCallback_new(
    MacwsCVDisplayLinkRef display_link,
    MacwsCVDisplayLinkOutputCallback callback,
    void *user_info) {
    if (!macws_cvdisplaylink_trace_enabled() || !callback) {
        return CVDisplayLinkSetOutputCallback(
            display_link, callback, user_info);
    }

    pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
    struct macws_cvdisplaylink_trace_slot *slot =
        macws_cvdisplaylink_trace_find_or_allocate(display_link);
    if (slot) {
        slot->callback = callback;
        slot->user_info = user_info;
        atomic_store_explicit(&slot->callback_count, 0,
                              memory_order_relaxed);
    }
    pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);

    if (!slot) {
        fprintf(stderr,
            "#### CVDL-TRACE callback slot table full link=%p; pass-through\n",
            display_link);
        return CVDisplayLinkSetOutputCallback(
            display_link, callback, user_info);
    }

    MacwsCVReturn result = CVDisplayLinkSetOutputCallback(
        display_link, macws_cvdisplaylink_trace_callback, slot);
    fprintf(stderr,
        "#### CVDL-TRACE set-callback link=%p requested=%#x result=%d "
        "original=%p user=%p wrapper=%p\n",
        display_link, slot->requested_display_id, result,
        (void *)callback, user_info,
        (void *)macws_cvdisplaylink_trace_callback);
    if (result != 0) {
        pthread_mutex_lock(&g_macws_cvdisplaylink_trace_lock);
        slot->callback = NULL;
        slot->user_info = NULL;
        pthread_mutex_unlock(&g_macws_cvdisplaylink_trace_lock);
    }
    return result;
}

DYLD_INTERPOSE(IOConnectCallMethod_new, IOConnectCallMethod);
DYLD_INTERPOSE(IOConnectCallScalarMethod_new, IOConnectCallScalarMethod);
DYLD_INTERPOSE(IOConnectCallStructMethod_new, IOConnectCallStructMethod);
DYLD_INTERPOSE(IOConnectCallAsyncMethod_new, IOConnectCallAsyncMethod);
DYLD_INTERPOSE(IOConnectCallAsyncScalarMethod_new, IOConnectCallAsyncScalarMethod);
DYLD_INTERPOSE(IOConnectCallAsyncStructMethod_new, IOConnectCallAsyncStructMethod);
DYLD_INTERPOSE(IOConnectTrap1_new, IOConnectTrap1);
DYLD_INTERPOSE(dyld_get_active_platform_new, dyld_get_active_platform);
DYLD_INTERPOSE(CVDisplayLinkCreateWithCGDisplay_new,
               CVDisplayLinkCreateWithCGDisplay);
DYLD_INTERPOSE(CVDisplayLinkSetOutputCallback_new,
               CVDisplayLinkSetOutputCallback);
DYLD_INTERPOSE(vproc_swap_string_new, vproc_swap_string);
DYLD_INTERPOSE(macws_confstr_new, confstr);

// XPC-borrow the AGX io_connect_t from macwsallocd. The helper is iOS-Apple-
// signed-equivalent so the kernel runs the full privileged UC-init (sets
// device->0x108, this->0x100, etc.) — which the chroot's macOS-userland
// IOServiceOpen can't trigger directly (RE-traced to per-UC size limit at
// IOGPUDevice::new_resource +0xff; see memory cross-image-objc-class-
// register-and-ioconnect-heap-blocker). Once borrowed, IOConnectCallMethod
// calls from the chroot run against the kernel-side UC state set by the
// helper — heap/queue/resource create all become available.
mach_port_t macws_borrow_agx_conn_xpc(void) {
    static mach_port_t cached = MACH_PORT_NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) return;
        xpc_connection_t conn = createMach("com.macwsguide.alloc", NULL, 0);
        if (!conn) return;
        xpc_connection_set_event_handler(conn, ^(xpc_object_t e) { (void)e; });
        xpc_connection_resume(conn);
        xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(req, "op", "borrow-agx-conn");
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
        if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            const char *result = xpc_dictionary_get_string(reply, "result");
            if (result && strcmp(result, "ok") == 0) {
                cached = xpc_dictionary_copy_mach_send(reply, "connect");
            }
            fprintf(stderr, "#### borrow-agx-conn reply result=%s cached=%u\n",
                result ?: "(none)", cached);
        } else {
            fprintf(stderr, "#### borrow-agx-conn no reply\n");
        }
    });
    return cached;
}

kern_return_t IOServiceOpen_new(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect) {
    static io_service_t agxService;
    if(!agxService) {
        agxService = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
        assert(agxService != IO_OBJECT_NULL);
    }

    // BORROW path: when MACWS_AGX_BORROW_CONN=1 and the open is for the AGX
    // service, ask macwsallocd to open it on our behalf (the helper runs in
    // iOS-native context where the kernel does full UC privileged init) and
    // return the borrowed mach port as the io_connect_t. All subsequent
    // IOConnectCallMethod calls then run against the kernel-side UC state
    // set by the helper.
    if (getenv("MACWS_AGX_BORROW_CONN") && service == agxService) {
        mach_port_t borrowed = macws_borrow_agx_conn_xpc();
        if (borrowed != MACH_PORT_NULL) {
            *connect = (io_connect_t)borrowed;
            assert(iogpuClientsCount < sizeof(iogpuClients) / sizeof(iogpuClients[0]));
            iogpuClients[iogpuClientsCount++] = *connect;
            fprintf(stderr, "#### IOServiceOpen agx BORROWED connect=%u (type was %u)\n",
                *connect, type);
            return KERN_SUCCESS;
        }
        // Fallback to normal path if XPC borrow failed.
        fprintf(stderr, "#### IOServiceOpen agx BORROW failed — falling back to normal IOServiceOpen\n");
    }

    uint32_t requested_type = type;

    // RE-confirmed user-space ABI translation: macOS 13.4 IOGPU builds
    // 5|(options<<16), while iOS 16.3 accepts low type 1 or 0x21.  Remove
    // only macOS platform bit 4; preserve the caller's high-word options.
    // Native-reference LLDB captured options=0x10 and type=0x100001, and the
    // KRW probe runtime-confirmed those bits at UC+0x128 and Device+0xd8.
    type &= ~4;

    // Keep the former high-word mask as an explicit diagnostic A/B only.  It
    // is not a fix: queue-only probing shows both types can create equivalent
    // kernel queues, while the high word changes real device state.
    if (getenv("MACWS_AGX_NATIVE") && service == agxService) {
        if (getenv("MACWS_AGX_STRIP_OPEN_OPTIONS")) {
            type &= 0xFFFF;
        }
        const char *force = getenv("MACWS_AGX_FORCE_TYPE");
        if (force) {
            type = (uint32_t)strtoul(force, NULL, 0);
        }
    }

    kern_return_t result = IOServiceOpen(service, owningTask, type, connect);
    assert(iogpuClientsCount < sizeof(iogpuClients) / sizeof(iogpuClients[0]));
    if(result == KERN_SUCCESS && service == agxService) {
        iogpuClients[iogpuClientsCount++] = *connect;
        fprintf(stderr, "#### debugbydcmmc IOServiceOpen agx connect=%d type=%#x (requested=%#x)\n",
            *connect, type, requested_type);
    }
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif
