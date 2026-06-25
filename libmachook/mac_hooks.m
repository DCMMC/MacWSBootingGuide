@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import <malloc/malloc.h>
#import <stdatomic.h>
#import "interpose.h"
#import "utils.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <time.h>

// IOSurface
typedef id IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(NSDictionary* properties);
// BYPASS-COMPRESSION forward decls (defined near IOSurfaceCreate_safe below):
static IOSurfaceRef (*orig_IOSurfaceCreate_ms)(CFDictionaryRef);
static IOSurfaceRef hooked_IOSurfaceCreate(CFDictionaryRef);
static IOSurfaceRef (*orig_ws_targetable)(int, int, int, uint64_t, const char *);
static IOSurfaceRef hooked_ws_targetable(int, int, int, uint64_t, const char *);
extern IOSurfaceRef IOSurfaceLookupFromMachPort(mach_port_t port);
extern uint32_t IOSurfaceGetPixelFormat(IOSurfaceRef surface);
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
static void *g_glass_wcb = NULL;   // GlassDemo's WSCAWindowBacking (set in gen_layers, mode-5 window)
static void *g_iosurface_isa = NULL;   // isa of a known IOSurface — to safely identify IOSurfaces by pointer
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
extern int IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern int IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerElement(IOSurfaceRef surface);
extern CFTypeID IOSurfaceGetTypeID(void);

// True for a plausible userland/heap/mapped arm64 pointer (avoids deref of garbage).
static inline int macws_ptr_ok(uint64_t p) {
    return p >= 0x100000000ULL && p < 0x800000000000ULL;
}

// ─── Synthesized AGXG13GFamilyBuffer accessors (CODEHEAP-SHIM) ──────────────
//
// When the iOS-native macwsallocd hands us an IOSurface with CPU base address
// X and size Y, we need a buffer-like object whose -resourceSize / -length /
// -contents / -virtualAddress / -gpuAddress return values derived from
// (X, Y, IOSurface). Direct re-implementation of MTLBuffer-protocol on a new
// class is heavy; the lightweight alternative is to associate the values
// onto the alloc'd instance and override the accessors so they read those
// associated values when present, falling back to the original impl
// otherwise.
//
// SAFE: an alloc'd-but-uninit'd instance has nil isa-ivars; the original
// accessors would return 0/null on those. Our overrides check the
// associated marker and only kick in for our synthesized objects.

static const char kSynthMarkerKey = 0;
static const char kSynthContentsKey = 0;
static const char kSynthLengthKey = 0;
static const char kSynthGpuAddrKey = 0;
static const char kSynthDeviceKey = 0;
static const char kSynthSurfaceKey = 0;

static IMP s_orig_resourceSize = NULL;
static IMP s_orig_length = NULL;
static IMP s_orig_contents = NULL;
static IMP s_orig_virtualAddress = NULL;
static IMP s_orig_gpuAddress = NULL;
static IMP s_orig_device = NULL;

#define MACWS_SYNTH_MARKER ((__bridge id)(void *)0x53594E5448) /* "SYNTH" */

static NSUInteger macws_synth_resourceSize(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        id v = objc_getAssociatedObject(self, &kSynthLengthKey);
        return v ? [v unsignedIntegerValue] : 0;
    }
    return ((NSUInteger(*)(id, SEL))s_orig_resourceSize)(self, _cmd);
}
static NSUInteger macws_synth_length(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        id v = objc_getAssociatedObject(self, &kSynthLengthKey);
        return v ? [v unsignedIntegerValue] : 0;
    }
    return ((NSUInteger(*)(id, SEL))s_orig_length)(self, _cmd);
}
static void *macws_synth_contents(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        id v = objc_getAssociatedObject(self, &kSynthContentsKey);
        return v ? [v pointerValue] : NULL;
    }
    return ((void *(*)(id, SEL))s_orig_contents)(self, _cmd);
}
static void *macws_synth_virtualAddress(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        id v = objc_getAssociatedObject(self, &kSynthContentsKey);
        return v ? [v pointerValue] : NULL;
    }
    return ((void *(*)(id, SEL))s_orig_virtualAddress)(self, _cmd);
}
static uint64_t macws_synth_gpuAddress(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        id v = objc_getAssociatedObject(self, &kSynthGpuAddrKey);
        return v ? [v unsignedLongLongValue] : 0;
    }
    return ((uint64_t(*)(id, SEL))s_orig_gpuAddress)(self, _cmd);
}
static id macws_synth_device(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kSynthMarkerKey)) {
        return objc_getAssociatedObject(self, &kSynthDeviceKey);
    }
    return ((id(*)(id, SEL))s_orig_device)(self, _cmd);
}

// Install the synth overrides on the given class. Idempotent — first call
// captures orig IMPs, subsequent calls are no-ops.
static void macws_install_synth_overrides(Class cls) {
    if (!cls) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL sels[] = {
            @selector(resourceSize),
            @selector(length),
            @selector(contents),
            @selector(virtualAddress),
            @selector(gpuAddress),
            @selector(device),
        };
        IMP newImps[] = {
            (IMP)macws_synth_resourceSize,
            (IMP)macws_synth_length,
            (IMP)macws_synth_contents,
            (IMP)macws_synth_virtualAddress,
            (IMP)macws_synth_gpuAddress,
            (IMP)macws_synth_device,
        };
        IMP *origSlots[] = {
            &s_orig_resourceSize,
            &s_orig_length,
            &s_orig_contents,
            &s_orig_virtualAddress,
            &s_orig_gpuAddress,
            &s_orig_device,
        };
        for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
            Method m = class_getInstanceMethod(cls, sels[i]);
            if (m) {
                *origSlots[i] = method_getImplementation(m);
                method_setImplementation(m, newImps[i]);
                fprintf(stderr, "#### SYNTH override installed: %s\n",
                    sel_getName(sels[i]));
            } else {
                fprintf(stderr, "#### SYNTH override SKIP %s — class %s has no method\n",
                    sel_getName(sels[i]), class_getName(cls));
            }
        }
    });
}

// ─── XPC client: ask iOS-native MTLSimDriverHost to allocate an IOSurface ──
// for chroot CodeHeap use. The chroot kernel rejects sel=0xa heap-creates,
// but an iOS-native helper opens AGX with the right userclient and CAN
// allocate. Returns the IOSurface mach send-right (or MACH_PORT_NULL on
// failure) plus the actual allocated size out-param. Caller is responsible
// for mach_port_deallocate'ing the returned port.
// See MTLSimDriverHost/main.x install_alloc_listener for the server side.
// out_iosurf_id (optional) receives the global IOSurfaceID — used for
// IOSurfaceLookup(int) cross-process lookup since the per-task
// IOSurfaceClient.IOSurfaceLookupFromMachPort doesn't resolve send-rights
// created in another task (runtime-confirmed 2026-06-19).
static mach_port_t macws_alloc_iosurf_xpc(uint64_t size, uint64_t options,
                                           uint64_t *out_alloc_size,
                                           uint32_t *out_iosurf_id) {
    static xpc_connection_t conn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            fprintf(stderr, "#### alloc-xpc: createMach symbol missing\n");
            return;
        }
        // com.macwsguide.alloc is published by the dedicated launchd job
        // /var/jb/Library/LaunchDaemons/com.macwsguide.alloc.plist, which
        // launchd auto-spawns on first lookup. No bootstrap needed.
        conn = createMach("com.macwsguide.alloc", NULL, 0);
        if (!conn) {
            fprintf(stderr, "#### alloc-xpc: createMach returned NULL\n");
            return;
        }
        xpc_connection_set_event_handler(conn, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(conn);
        fprintf(stderr, "#### alloc-xpc: opened connection to com.macwsguide.alloc\n");
    });
    if (!conn) return MACH_PORT_NULL;

    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "alloc-iosurf");
    xpc_dictionary_set_uint64(req, "size", size);
    xpc_dictionary_set_uint64(req, "options", options);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    mach_port_t port = MACH_PORT_NULL;
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        const char *result = xpc_dictionary_get_string(reply, "result");
        if (result && strcmp(result, "ok") == 0) {
            port = xpc_dictionary_copy_mach_send(reply, "surface");
            if (out_alloc_size) *out_alloc_size = xpc_dictionary_get_uint64(reply, "alloc_size");
            if (out_iosurf_id) *out_iosurf_id = (uint32_t)xpc_dictionary_get_uint64(reply, "iosurface_id");
        }
        static int once_log = 0;
        if (once_log++ < 6) {
            fprintf(stderr,
                "#### alloc-xpc reply: result=%s port=%u alloc_size=%llu iosurface_id=%u\n",
                result ?: "(none)", port,
                out_alloc_size ? (unsigned long long)*out_alloc_size : 0ULL,
                out_iosurf_id ? *out_iosurf_id : 0);
        }
    } else {
        static int once_log = 0;
        if (once_log++ < 6) fprintf(stderr, "#### alloc-xpc: no reply\n");
    }
    return port;
}

// macws_make_mem_entry_xpc — ask iOS-native macwsallocd to allocate a
// CPU buffer + mach_make_memory_entry_64-wrap it, return entry port +
// mapped VA in our task. Used for type=0x80 standalone client-buffer
// path where iOS kernel rejects raw mmap'd CPU VAs (rejected even with
// pre-fault + mlock). Memory entry created by an iOS-native task with
// real task credentials passes the kernel's wire check.
//
// PoC verified 2026-06-19 via misc/test_mem_entry_xpc.c that mach
// memory entry mach ports DO cross XPC task boundaries (unlike
// io_connect_t which trips EXC_GUARD ILLEGAL_MOVE).
//
// Returns the mapped CPU VA in our task on success, 0 on failure.
// Caller writes this VA into args+0x30 before sel=0xa.
extern kern_return_t mach_vm_map(
    vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size,
    mach_vm_offset_t mask, int flags, mach_port_t object,
    memory_object_offset_t offset, boolean_t copy,
    vm_prot_t cur_protection, vm_prot_t max_protection,
    vm_inherit_t inheritance);

__attribute__((unused))
static uint64_t macws_make_mem_entry_xpc(uint64_t size, uint64_t *out_size) {
    static xpc_connection_t conn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) return;
        conn = createMach("com.macwsguide.alloc", NULL, 0);
        if (!conn) return;
        xpc_connection_set_event_handler(conn, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(conn);
    });
    if (!conn) return 0;

    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", "make-mem-entry");
    xpc_dictionary_set_uint64(req, "size", size);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        static int log_once = 0;
        if (!log_once++) fprintf(stderr, "#### mem-entry-xpc: no reply\n");
        return 0;
    }
    const char *result = xpc_dictionary_get_string(reply, "result");
    if (!result || strcmp(result, "ok") != 0) {
        static int log_once = 0;
        if (log_once++ < 4) fprintf(stderr,
            "#### mem-entry-xpc: result=%s\n", result ?: "(null)");
        return 0;
    }
    mach_port_t entry = xpc_dictionary_copy_mach_send(reply, "entry");
    uint64_t actual = xpc_dictionary_get_uint64(reply, "size");
    if (entry == MACH_PORT_NULL || actual == 0) return 0;

    // Map the entry into THIS task (chroot WS). The mapped VA is what
    // the kernel will see when we put it in args+0x30.
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_map(
        mach_task_self(), &addr, (mach_vm_size_t)actual, 0,
        0x1 /* VM_FLAGS_ANYWHERE */, entry, 0, FALSE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE,
        VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), entry);
    if (kr != KERN_SUCCESS) {
        static int log_once = 0;
        if (log_once++ < 4) fprintf(stderr,
            "#### mem-entry-xpc: mach_vm_map kr=%#x\n", kr);
        return 0;
    }
    static int log_once = 0;
    if (log_once++ < 6) {
        fprintf(stderr,
            "#### mem-entry-xpc: req=%#llx → addr=%#llx size=%#llx (mapped from helper)\n",
            (unsigned long long)size, (unsigned long long)addr,
            (unsigned long long)actual);
    }
    if (out_size) *out_size = actual;
    return (uint64_t)addr;
}

extern au_asid_t audit_token_to_asid(audit_token_t atoken);
extern uid_t audit_token_to_auid(audit_token_t atoken);

// #define FORCE_SW_RENDER 1
BOOL hooked_return_1(void) { return YES; }
void EnableJIT(void);

// FORCE_M1_DRIVER: route Metal through the REAL macOS AGX (M1/G13G) GPU driver
// instead of the MTLSimDriver simulator bridge. Auto-enabled for both arm64e
// (Terminal, etc. — AGX-direct is their only Metal path) and arm64 (WS).
//
// HISTORY: f37b55e enabled for arm64 too, 5e89f2b reverted on the
// (incorrect) assumption that the raw sel=0xa hit a working path. Disasm
// of iOS sDeviceMethods table shows sel=0xa = s_delete_resource. macOS
// WS's create-shaped args sent to that selector get rejected at the
// IOExternalMethod arg-count check (checkScalarInputCount=1 mismatch
// with macOS's 0). Translation `sel=0xa → 0x9` IS the right thing; what
// went wrong was the type=0 args layout for s_new_resource. Re-enabled.
#if defined(LIBMACHOOK_ON_DEVICE_BUILD)
#define FORCE_M1_DRIVER 1
#endif

// offsets hardcoded for macOS 13.4
// IOMobileFramebuffer`kern_SwapEnd + 36
#define OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt 0x4400 + 0x24
// IOMobileFramebuffer`kern_SwapEnd + 0x30: `bl IOConnectCallStructMethod` (sel=5) — the call
// that presents WindowServer's composited surface to the PHYSICAL iPad panel. In coexistence
// mode (iOS backboardd owns the panel, macOS viewed via VNC off-screen) we neutralize this so
// WS never scans out to the panel -> no iOS/macOS flicker. Gated to WindowServer + auto-detection
// of a running backboardd (coexistence); left intact in the original macOS-on-panel mode where
// backboardd is unloaded. (/tmp/ws_headless still force-enables it for testing.)
#define OFF_IOMobileFramebuffer_kern_SwapEnd_submit 0x4400 + 0x30
// SkyLight`WS::Displays::CAWSManager::CAWSManager() + 560
#define OFF_SkyLight_CAWSManager_register_abort 0x18013c
#if FORCE_SW_RENDER
// SkyLight`WSSystemCanCompositeWithMetal::once
// #define OFF_SkyLight_WSSystemCanCompositeWithMetal 0x1d72b148
#define OFF_SkyLight_WSSystemCanCompositeWithMetal 0x53ae9028
#endif
// Metal`MTLFragmentReflectionReader::deserialize + 364
#define OFF_Metal_MTLFragmentReflectionReader_deserialize_extra 0x90ebc + 0x16c
// Metal`MTLInputStageReflectionReader::deserialize + 956
#define OFF_Metal_MTLInputStageReflectionReader_deserialize_extra 0x90678 + 0x3bc
// QuartzCore`CABackingStorePrepareUpdates_ + 812.  At this site the original
// `cbz w21, +852` sends every window backing store down the NON-accelerated path
// (w21==0 because the format/capability arg w23==2 has bit 8 clear): it allocates a
// CPU `CA::Render::Shmem::new_bitmap` instead of an IOSurface, so drawn content never
// becomes a GPU surface WindowServer can composite -> window CONTENT stays BLACK
// (chrome renders via a different path).  Forcing this branch to `b +840` takes the
// accelerated path (`mov w8,#1; str w8,[sp,#0x68]`), so create_iosurface() runs and an
// IOSurface-backed buffer is allocated -> content renders.  Verified live with lldb:
// patching this single instruction makes create_iosurface + IOSurfaceCreate fire.
#define OFF_QuartzCore_CABackingStore_force_accel 0x227cc

const char *IOMFBPath = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/Versions/A/IOMobileFramebuffer";
const char *MetalPath = "/System/Library/Frameworks/Metal.framework/Versions/A/Metal";
const char *SkyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
const char *QuartzCorePath = "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore";
const char *libxpcPath = "/usr/lib/system/libxpc.dylib";
const char *AGXMetalPath = "/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3";

// Private malloc zone for synth-buffer scratch (ivar+0x30) — Mempool freelist
// target. AGX driver writes its own sentinels (e.g. 0x1) into this buffer for
// its internal freelist tracking. When the synth AGXG13GFamilyBuffer is
// dealloc'd, free() routes the pointer to its zone. With this private zone,
// the corruption stays here — nothing else allocates from this zone, so
// tiny_malloc_from_free_list iterations in the DEFAULT zone never touch it.
// Without this isolation, AGX driver's `0x1` writes poison the default-zone
// free list and crash WS at the next NSString/CF object allocation.
static malloc_zone_t *macws_synth_scratch_zone(void) {
    static malloc_zone_t *zone = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zone = malloc_create_zone(0, 0);
        if (zone) malloc_set_zone_name(zone, "macws_synth_scratch");
        fprintf(stderr,
            "#### CODEHEAP-SHIM private scratch zone created: %p name=%s\n",
            zone, zone ? malloc_get_zone_name(zone) : "(nil)");
    });
    return zone;
}

// True if a process named `name` is currently running anywhere on the system.
// chroot shares the kernel proc table, so iOS-context processes (e.g.
// backboardd) are visible. Used to auto-detect coexistence mode: when iOS's
// backboardd is alive we share the device with iOS UI so WindowServer must
// not scan out to the panel. Cherry-picked from commit 0bba4a6 on stale
// branch feat/window-content-rendering.
static BOOL is_process_running(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    len += len / 8 + 0x4000;  // pad: proc table can grow between size + fetch
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t n = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
                found = YES;
                break;
            }
        }
    }
    free(procs);
    return found;
}

// ─── Chained-fixups walker for chroot-loaded AGXMetal13_3 ──────────────────
//
// In chroot, AGXMetal13_3.bundle is loaded from disk via dlopen, not from
// dyld_shared_cache. iOS dyld processes LC_DYLD_CHAINED_FIXUPS at image-load
// time. Cross-image bindings (especially to IOGPU.framework) fail silently
// when IOGPU isn't yet loaded → all 97 __got slots stay NULL → AGX::Mempool
// ::grow's lambda crashes on the null function pointers.
//
// This walker re-parses the chained-fixups load command and patches each null
// import bind by resolving the symbol via dlsym(RTLD_DEFAULT, name). The
// arm64e auth variants are PAC-signed with the embedded key + diversifier.

#include <mach-o/fixup-chains.h>

static inline uint64_t macws_ptr_blend(uint64_t addr, uint16_t div) {
    return (addr & 0x0000FFFFFFFFFFFFull) | ((uint64_t)div << 48);
}

#if __arm64e__
static inline uint64_t macws_pac_sign(uint64_t ptr, uint64_t mod, uint8_t key) {
    uint64_t r = ptr;
    switch (key) {
        case 0: asm("pacia %0, %1" : "+r"(r) : "r"(mod)); break;
        case 1: asm("pacib %0, %1" : "+r"(r) : "r"(mod)); break;
        case 2: asm("pacda %0, %1" : "+r"(r) : "r"(mod)); break;
        case 3: asm("pacdb %0, %1" : "+r"(r) : "r"(mod)); break;
    }
    return r;
}
#else
static inline uint64_t macws_pac_sign(uint64_t ptr, uint64_t mod, uint8_t key) {
    return ptr;  // no PAC on plain arm64
}
#endif

#include <mach-o/nlist.h>
#include <mach-o/reloc.h>

// Repair __got / __auth_got slots via indirect symbol table + LC_SYMTAB. Used
// for dlopen'd DSC-bound images that have no LC_DYLD_CHAINED_FIXUPS (because
// the cache builder removed it; cache pre-filled __got at cache-prep time).
// When loaded standalone, the pre-fill is gone — but the indirect symbol
// table still references LC_SYMTAB entries that name each slot's target.
static void macws_repair_got_via_symtab(const struct mach_header_64 *header,
                                        intptr_t slide,
                                        const char *image_name) {
    const struct symtab_command   *st = NULL;
    const struct dysymtab_command *dt = NULL;
    uint64_t linkedit_vmaddr = 0, linkedit_fileoff = 0;
    const struct segment_command_64 *segs[16] = {0};
    int seg_count = 0;

    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        switch (cmd->cmd) {
            case LC_SYMTAB:   st = (const struct symtab_command *)cmd; break;
            case LC_DYSYMTAB: dt = (const struct dysymtab_command *)cmd; break;
            case LC_SEGMENT_64: {
                const struct segment_command_64 *sc = (const struct segment_command_64 *)cmd;
                if (strcmp(sc->segname, "__LINKEDIT") == 0) {
                    linkedit_vmaddr  = sc->vmaddr;
                    linkedit_fileoff = sc->fileoff;
                }
                if (seg_count < 16) segs[seg_count++] = sc;
                break;
            }
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    if (!st || !dt || !linkedit_vmaddr) {
        fprintf(stderr, "#### MACWS_GOT %s: missing LC_SYMTAB/LC_DYSYMTAB/LC_SEGMENT\n", image_name);
        return;
    }
    int64_t linkedit_runtime_base = (int64_t)linkedit_vmaddr + slide - (int64_t)linkedit_fileoff;
    const struct nlist_64 *symtab    = (const struct nlist_64 *)(linkedit_runtime_base + st->symoff);
    const char            *strtab    = (const char           *)(linkedit_runtime_base + st->stroff);
    const uint32_t        *indirect  = (const uint32_t        *)(linkedit_runtime_base + dt->indirectsymoff);

    fprintf(stderr, "#### MACWS_GOT %s: symtab=%u syms, strtab=%u bytes, indirect=%u entries\n",
        image_name, st->nsyms, st->strsize, dt->nindirectsyms);

    int total_indirect_slots = 0, patched = 0, failed = 0;
    for (int s = 0; s < seg_count; s++) {
        const struct segment_command_64 *sc = segs[s];
        const struct section_64 *sect =
            (const struct section_64 *)((const uint8_t *)sc + sizeof(*sc));
        for (uint32_t k = 0; k < sc->nsects; k++) {
            const struct section_64 *sn = &sect[k];
            uint32_t type = sn->flags & SECTION_TYPE;
            // We want pointer-table sections that index into the indirect
            // symbol table. Per Mach-O spec, these are:
            //   S_NON_LAZY_SYMBOL_POINTERS (__got, __auth_got pointers)
            //   S_LAZY_SYMBOL_POINTERS     (__la_symbol_ptr — old style)
            //   S_SYMBOL_STUBS             (__stubs / __auth_stubs)
            // Match by sectname — DSC strips section type bits but preserves
            // the section NAME and reserved1 (indirect symbol table start).
            // Also accept ANY section in __DATA_CONST/__AUTH_CONST whose
            // reserved1 is non-zero AND whose name suggests pointer table
            // (`got`, `ptr`, `symbol`). Catches:
            //   __DATA_CONST,__got           (no-auth GOT)
            //   __AUTH_CONST,__auth_got      (PAC-auth GOT)
            //   __DATA,__la_symbol_ptr       (lazy stubs)
            //   __DATA,__nl_symbol_ptr       (non-lazy pointers)
            //   __DATA_CONST,__symbol_ptrs   (some images)
            //   __AUTH_CONST,__auth_ptr      (when reserved1 set)
            BOOL is_pointer_section = (strstr(sn->sectname, "got") != NULL ||
                                       strstr(sn->sectname, "ptr") != NULL ||
                                       strstr(sn->sectname, "symbol") != NULL);
            if (!is_pointer_section) continue;
            if (sn->reserved1 == 0) continue;
            uint32_t entries = (uint32_t)(sn->size / 8);
            uint32_t indirect_start = sn->reserved1;
            BOOL is_auth = (strstr(sn->sectname, "auth") != NULL);
            uint64_t *slots = (uint64_t *)(sn->addr + slide);
            fprintf(stderr, "####   sect[%u] %s,%s type=%u entries=%u indirect_start=%u auth=%d\n",
                k, sc->segname, sn->sectname, type, entries, indirect_start, is_auth);
            for (uint32_t e = 0; e < entries; e++) {
                if (indirect_start + e >= dt->nindirectsyms) break;
                total_indirect_slots++;
                uint32_t idx = indirect[indirect_start + e];
                if (idx == INDIRECT_SYMBOL_LOCAL ||
                    idx == INDIRECT_SYMBOL_ABS ||
                    idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
                    continue;
                }
                if (idx >= st->nsyms) {
                    failed++;
                    continue;
                }
                const struct nlist_64 *sym = &symtab[idx];
                const char *name = strtab + sym->n_un.n_strx;
                if (!name || !name[0]) { failed++; continue; }
                // Skip leading underscore for dlsym
                const char *lookup = name;
                if (lookup[0] == '_') lookup++;
                void *resolved = dlsym(RTLD_DEFAULT, lookup);
                if (!resolved) {
                    failed++;
                    if (failed < 6) {
                        fprintf(stderr, "####   bind FAIL %s\n", name);
                    }
                    continue;
                }
                // Force-redirect objc_alloc to our tracer regardless of current
                // slot value. The lambda in AGX::Mempool::grow calls objc_alloc
                // through this slot; we need to log its result and provide a
                // class_createInstance fallback when libobjc returns nil for an
                // under-realized AGX class.
                int force_override = 0;
                extern id objc_alloc_trace(Class);
                if (!strcmp(lookup, "objc_alloc")) {
                    resolved = (void *)objc_alloc_trace;
                    force_override = 1;
                }
                uint64_t value = (uint64_t)resolved;
                // For __auth_got we'd need PAC signing — but without chained
                // fixup metadata we don't know diversifier/key. For non-auth
                // __got (which is what the diagnostic showed as 97 nulls), no
                // PAC needed.
                //
                // Most slot consumers expect a non-auth pointer for __got
                // and PAC-signed for __auth_got. If we patch __auth_got with
                // a raw pointer, the consuming code's autda/autia will fail
                // and trap. For now, skip __auth_got — we'll see how far we
                // get with __got alone.
                uint64_t *slot = &slots[e];
                uint64_t cur = *slot;
                // arm64e standard ABI for cross-image __auth_got slots:
                //   key=IA (0), addrDiv=1, diversity=0
                // The modifier becomes blend(slot_addr, 0) = slot_addr (low 48
                // bits). Consumer uses `ldraa x16, [slot]` which auths with
                // this exact modifier, then branches.
                if (is_auth) {
                    if (getenv("MACWS_GOT_SKIP_AUTH")) continue;
                    if (!getenv("MACWS_GOT_RAW_AUTH")) {
                        uint64_t mod = (uint64_t)slot & 0xFFFFFFFFFFFFull;
                        value = macws_pac_sign(value, mod, 0);  // key=IA
                    }
                }
                if (cur == 0 || force_override) {
                    ModifyExecutableRegion(slot, sizeof(uint64_t), ^{
                        *slot = value;
                    });
                    patched++;
                    if (patched < 12 || force_override) {
                        fprintf(stderr, "####   bind[%d] %s -> %p (slot=%p auth=%d%s)\n",
                            patched, name, resolved, slot, is_auth,
                            force_override ? " FORCE" : "");
                    }
                    // Dump IOGPU-related symbols specifically — these are the
                    // pool allocator helpers we need to know about.
                    if (strstr(name, "IOGPU") || strstr(name, "iogpu") ||
                        strstr(name, "MetalCommon") || strstr(name, "PoolAlloc") ||
                        strstr(name, "Pool") || strstr(name, "Heap")) {
                        fprintf(stderr, "####   IOGPU-CRITICAL %s = %p (slot=%p auth=%d)\n",
                            name, resolved, slot, is_auth);
                    }
                }
            }
        }
    }
    fprintf(stderr, "#### MACWS_GOT %s: indirect_slots=%d patched=%d failed=%d\n",
        image_name, total_indirect_slots, patched, failed);
}

static void macws_walk_chained_fixups(const struct mach_header_64 *header,
                                      intptr_t slide,
                                      const char *image_name) {
    // 1) Find LC_DYLD_CHAINED_FIXUPS load command and __LINKEDIT segment base
    const struct linkedit_data_command *fixups_cmd = NULL;
    uint64_t linkedit_vmaddr = 0;
    uint64_t linkedit_fileoff = 0;
    const struct load_command *cmd = (const struct load_command *)((const uint8_t *)header + sizeof(*header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_DYLD_CHAINED_FIXUPS) {
            fixups_cmd = (const struct linkedit_data_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cmd;
            if (strcmp(sc->segname, "__LINKEDIT") == 0) {
                linkedit_vmaddr  = sc->vmaddr;
                linkedit_fileoff = sc->fileoff;
            }
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    if (!fixups_cmd) {
        // No LC_DYLD_CHAINED_FIXUPS — the binary was loaded from
        // dyld_shared_cache, whose builder strips fixup info and pre-fills
        // the __got. When dlopen'd standalone, __got entries stay null.
        // Fall back to: walk indirect symbol table + LC_SYMTAB to recover
        // symbol names for each __got slot, dlsym, write back.
        macws_repair_got_via_symtab(header, slide, image_name);
        return;
    }
    if (!linkedit_vmaddr) {
        fprintf(stderr, "#### MACWS_FIXUP %s: no __LINKEDIT segment\n", image_name);
        return;
    }
    // dataoff is a FILE offset within __LINKEDIT; runtime addr = linkedit
    // vmaddr + slide + (dataoff - linkedit_fileoff).
    const uint8_t *fixups = (const uint8_t *)(linkedit_vmaddr + slide +
                                               ((int64_t)fixups_cmd->dataoff - (int64_t)linkedit_fileoff));
    const struct dyld_chained_fixups_header *fh =
        (const struct dyld_chained_fixups_header *)fixups;
    fprintf(stderr, "#### MACWS_FIXUP %s: header v=%u imports=%u fmt=%u sym_fmt=%u\n",
        image_name, fh->fixups_version, fh->imports_count,
        fh->imports_format, fh->symbols_format);

    const char *symbols = (const char *)(fixups + fh->symbols_offset);

    // Helper: resolve symbol name for an import index, given imports format.
    const void *imports_base = fixups + fh->imports_offset;
    __attribute__((unused))
    typedef const char *(*import_name_t)(const void *imports_base, uint32_t idx);
    const char *(^get_import_name)(uint32_t) = ^const char *(uint32_t idx) {
        switch (fh->imports_format) {
            case DYLD_CHAINED_IMPORT: {
                const struct dyld_chained_import *imp =
                    (const struct dyld_chained_import *)imports_base;
                return symbols + imp[idx].name_offset;
            }
            case DYLD_CHAINED_IMPORT_ADDEND: {
                const struct dyld_chained_import_addend *imp =
                    (const struct dyld_chained_import_addend *)imports_base;
                return symbols + imp[idx].name_offset;
            }
            case DYLD_CHAINED_IMPORT_ADDEND64: {
                const struct dyld_chained_import_addend64 *imp =
                    (const struct dyld_chained_import_addend64 *)imports_base;
                return symbols + imp[idx].name_offset;
            }
        }
        return "<unknown_format>";
    };

    // 2) Walk starts_in_image → starts_in_segment → chains
    const struct dyld_chained_starts_in_image *starts =
        (const struct dyld_chained_starts_in_image *)(fixups + fh->starts_offset);

    int total_binds = 0, patched_binds = 0, failed_binds = 0;
    int auth_binds = 0, non_auth_binds = 0;
    for (uint32_t s = 0; s < starts->seg_count; s++) {
        uint32_t seg_off = starts->seg_info_offset[s];
        if (!seg_off) continue;
        const struct dyld_chained_starts_in_segment *seg =
            (const struct dyld_chained_starts_in_segment *)((const uint8_t *)starts + seg_off);
        if (seg->pointer_format != DYLD_CHAINED_PTR_ARM64E &&
            seg->pointer_format != DYLD_CHAINED_PTR_ARM64E_USERLAND &&
            seg->pointer_format != DYLD_CHAINED_PTR_ARM64E_USERLAND24 &&
            seg->pointer_format != DYLD_CHAINED_PTR_64 &&
            seg->pointer_format != DYLD_CHAINED_PTR_64_OFFSET) {
            fprintf(stderr, "#### MACWS_FIXUP seg[%u] unsupported pointer_format=%u\n",
                s, seg->pointer_format);
            continue;
        }
        for (uint16_t p = 0; p < seg->page_count; p++) {
            uint16_t page_start = seg->page_start[p];
            if (page_start == DYLD_CHAINED_PTR_START_NONE) continue;
            uint64_t page_va = (uint64_t)header + seg->segment_offset + (uint64_t)p * seg->page_size;
            uint64_t chain_va = page_va + page_start;
            for (;;) {
                uint64_t *slot = (uint64_t *)chain_va;
                uint64_t raw = *slot;
                int is_bind = 0, is_auth = 0;
                uint32_t ordinal = 0;
                uint16_t diversity = 0;
                uint8_t key = 0;
                uint8_t addrDiv = 0;
                uint32_t next = 0;

                if (seg->pointer_format == DYLD_CHAINED_PTR_ARM64E ||
                    seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND ||
                    seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND24) {
                    is_bind = (raw >> 62) & 1;
                    is_auth = (raw >> 63) & 1;
                    if (seg->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND24 && is_bind) {
                        ordinal = raw & 0xFFFFFF;
                        next = (raw >> 51) & 0x7FF;
                    } else if (is_bind) {
                        ordinal = raw & 0xFFFF;
                        next = (raw >> 51) & 0x7FF;
                    } else {
                        next = (raw >> 51) & 0x7FF;
                    }
                    if (is_auth && is_bind) {
                        diversity = (raw >> 32) & 0xFFFF;
                        addrDiv = (raw >> 48) & 1;
                        key = (raw >> 49) & 3;
                    } else if (is_auth) {
                        diversity = (raw >> 32) & 0xFFFF;
                        addrDiv = (raw >> 48) & 1;
                        key = (raw >> 49) & 3;
                    }
                } else { // DYLD_CHAINED_PTR_64 / _64_OFFSET
                    is_bind = (raw >> 63) & 1;
                    next = (raw >> 51) & 0xFFF;
                    if (is_bind) {
                        ordinal = raw & 0xFFFFFF;
                    }
                }

                if (is_bind) {
                    total_binds++;
                    if (is_auth) auth_binds++; else non_auth_binds++;
                    if (ordinal < fh->imports_count) {
                        const char *name = get_import_name(ordinal);
                        if (name && name[0]) {
                            // dlsym wants the name without the leading underscore.
                            const char *lookup = name;
                            if (lookup[0] == '_') lookup++;
                            void *resolved = dlsym(RTLD_DEFAULT, lookup);
                            if (resolved) {
                                uint64_t value = (uint64_t)resolved;
                                if (is_auth) {
                                    uint64_t mod = addrDiv
                                        ? macws_ptr_blend((uint64_t)slot, diversity)
                                        : (uint64_t)diversity;
                                    value = macws_pac_sign(value, mod, key);
                                }
                                ModifyExecutableRegion(slot, sizeof(uint64_t), ^{
                                    *slot = value;
                                });
                                patched_binds++;
                                if (patched_binds < 6) {
                                    fprintf(stderr,
                                        "####   bind[%d] %s -> %p (auth=%d key=%d div=%#x addrDiv=%d)\n",
                                        patched_binds, name, resolved, is_auth, key,
                                        diversity, addrDiv);
                                }
                            } else {
                                failed_binds++;
                                if (failed_binds < 6) {
                                    fprintf(stderr,
                                        "####   bind FAIL %s — dlsym NULL\n", name);
                                }
                            }
                        }
                    }
                }

                if (next == 0) break;
                uint32_t stride = (seg->pointer_format == DYLD_CHAINED_PTR_64 ||
                                   seg->pointer_format == DYLD_CHAINED_PTR_64_OFFSET) ? 4 : 8;
                chain_va += (uint64_t)next * stride;
            }
        }
    }
    fprintf(stderr, "#### MACWS_FIXUP %s: walked binds=%d (auth=%d non-auth=%d) patched=%d failed=%d\n",
        image_name, total_binds, auth_binds, non_auth_binds, patched_binds, failed_binds);
}

// SkyLight `MetalIOSurfaceBacking::PrepareForUse(MetalContext*, unsigned long
// long)` tolerate-nil hook. See loadImageCallback for full rationale.
typedef int (*PrepareForUse_t)(void *self, void *ctx, unsigned long long arg);
static PrepareForUse_t orig_skylight_prepare_for_use = NULL;
static int hooked_skylight_prepare_for_use(void *self, void *ctx,
                                           unsigned long long arg) {
    if (ctx) {
        // MetalContext+0x1c0 is a single-byte "tolerate-nil-texture" flag
        // (ldrb w8 at the abort-decision site). SkyLight returns 0 from
        // PrepareForUse silently when the flag is set; aborts when it's 0.
        *((volatile uint8_t *)ctx + 0x1c0) = 1;
    }
    int r = orig_skylight_prepare_for_use(self, ctx, arg);
    if (access("/tmp/macws_ws_diag", F_OK) == 0) {
        // self = MetalIOSurfaceBacking; +0x18 typically the IOSurface-backed
        // MTLTexture. ret!=0 = source texture ready; ret==0 = nil/abort path.
        static int n; if (++n <= 40)
            fprintf(stderr, "#### WS_DIAG PrepareForUse #%d self=%p tex=%p ret=%d\n",
                    n, self, self ? *(void **)((char *)self + 0x18) : NULL, r);
    }
    return r;
}

// ── WS-side window-backing diagnostics (agent RE 2026-06-23; offsets VERIFIED
// against the on-device 13.4 SkyLight __TEXT @0x1850E5000 — all 4 are clean
// function prologues). DEREF-SAFE: count + raw arg pointer only (no field reads
// — the earlier win+0x838 read crashed WS when win wasn't a CGXWindow). Gate
// /tmp/macws_ws_diag2; addresses computed off the clean image header. ──
typedef void *(*wcb_flatten_t)(void *, void *, void *, void *);
static wcb_flatten_t orig_wcb_flatten = NULL;
static void *hooked_wcb_flatten(void *self, void *a1, void *a2, void *a3) {
    void *r = orig_wcb_flatten(self, a1, a2, a3);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
        static int n; if (++n <= 20) {
            int f2e8 = -1; void *a8 = NULL, *e0 = NULL;
            if ((uintptr_t)self > 0x100000000) { f2e8 = *(uint8_t *)((char *)self + 0x2e8);
                a8 = *(void **)((char *)self + 0xa8); e0 = *(void **)((char *)self + 0x2e0); }
            fprintf(stderr, "#### WS_DIAG2 Flatten #%d self=%p AFTER is_flat2e8=%d backing+0xa8=%p flat2e0=%p\n",
                    n, self, f2e8, a8, e0);
        }
    }
    return r;
}
static void *(*orig_popfc)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_popfc(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 PopulateFlattenedContent #%d self=%p\n", n, a); }
    return orig_popfc(a, b, c, d, e, f, g, h);
}
static void *(*orig_gfmb)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_gfmb(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *r = orig_gfmb(a, b, c, d, e, f, g, h);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 GetFlattenedMetalBacking #%d backing=%p ret=%p\n", n, a, r); }
    return r;
}
// Flatten-RENDER chain (the validity-commit path) — all normal prologues, hookable.
static void *(*orig_wlb_flatten)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_wlb_flatten(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 WSCALayerBacking::Flatten #%d self=%p\n", n, a); }
    return orig_wlb_flatten(a, b, c, d, e, f, g, h);
}
static int (*orig_cmb)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static int hooked_cmb(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    int r = orig_cmb(a, b, c, d, e, f, g, h);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 CreateMetalBacking #%d self=%p ret=%d\n", n, a, r); }
    return r;
}
static void *(*orig_csmpop)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_csmpop(void *self, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *before = ((uintptr_t)self > 0x100000000) ? *(void **)((char *)self + 0x58) : (void *)-1;
    void *r = orig_csmpop(self, b, c, d, e, f, g, h);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20) {
        void *after = ((uintptr_t)self > 0x100000000) ? *(void **)((char *)self + 0x58) : (void *)-1;
        fprintf(stderr, "#### WS_DIAG2 CSMPopulate #%d self=%p dirty+0x58 before=%p after=%p\n", n, self, before, after); }
    }
    return r;
}
static void *(*orig_cltd)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_cltd(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 CompositeLayersToDest #%d (AGX GPU composite)\n", n); }
    return orig_cltd(a, b, c, d, e, f, g, h);
}
static void *(*orig_wcomp)(void *, void *, void *, void *, void *, void *, void *, void *) = NULL;
static void *hooked_wcomp(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *r = orig_wcomp(a, b, c, d, e, f, g, h);
    // DIAGNOSTIC (gated /tmp/macws_force_wcomp): force "composite the flattened content"
    // even when IsFlattenedCopyValid says invalid — tests whether the produced flattened
    // surface (backing+0x2e0) is actually usable. If GlassDemo appears → content is real,
    // the validity check is the only gap. If black/crash → content genuinely invalid.
    if (!r && access("/tmp/macws_force_wcomp", F_OK) == 0) r = (void *)1;
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 30)
        fprintf(stderr, "#### WS_DIAG2 will_composite_ca_flat #%d win=%p ret=%p\n", n, a, r); }
    return r;
}
typedef int (*flat_valid_t)(void *, void *, void *, void *);
static flat_valid_t orig_flat_valid = NULL;
static int hooked_flat_valid(void *self, void *a1, void *a2, void *a3) {
    int r = orig_flat_valid(self, a1, a2, a3);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
        static int n; if (++n <= 30)
            fprintf(stderr, "#### WS_DIAG2 IsFlattenedCopyValid #%d self=%p ret=%d\n", n, self, r);
    }
    return r;
}
typedef void *(*upd_disp_t)(void *, void *, void *, void *);
static upd_disp_t orig_upd_disp = NULL;
static void *hooked_upd_disp(void *a, void *b, void *c, void *d) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
        static int n; if (++n <= 5)
            fprintf(stderr, "#### WS_DIAG2 UpdateDisplays #%d (SANITY: hook works)\n", n);
    }
    return orig_upd_disp(a, b, c, d);
}
typedef void *(*vis_list_t)(void *, void *, void *, void *);
static vis_list_t orig_vis_list = NULL;
static void *hooked_vis_list(void *a, void *b, void *c, void *d) {
    void *r = orig_vis_list(a, b, c, d);
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
        static int n; if (++n <= 10)
            fprintf(stderr, "#### WS_DIAG2 visible_window_list #%d ret=%p\n", n, r);
    }
    return r;
}
typedef void *(*gen_layers_t)(void *, void *, void *, void *);
static gen_layers_t orig_gen_layers = NULL;
static void *hooked_gen_layers(void *a0, void *win, void *a2, void *a3) {
    // RE-confirmed: generate_layers_for_window(x0=redrawState, x1=WINDOW). Window = arg1.
    // Emitted source layers are linked into *(redrawState+0x78). Capture it before+after the
    // orig call: if it changes for GlassDemo's window, generate_layers EMITTED a source layer
    // (drop-out is downstream / sampling); if unchanged, the window is dropped INSIDE
    // generate_layers (a content gate after entry).
    int  diag2  = (access("/tmp/macws_ws_diag2", F_OK) == 0);
    int  avalid = ((uintptr_t)a0 > 0x100000000 && (uintptr_t)a0 < 0x800000000000);
    void *list_before = (diag2 && avalid) ? *(void **)((char *)a0 + 0x78) : NULL;
    void *r = orig_gen_layers(a0, win, a2, a3);
    if (diag2 && (uintptr_t)win > 0x100000000 && (uintptr_t)win < 0x800000000000
        && *(int *)((char *)win + 0x58) == 5) {          // mode-5 CA-flatten window = GlassDemo
        void *w = *(void **)((char *)win + 0xf8);
        if ((uintptr_t)w > 0x100000000 && (uintptr_t)w < 0x800000000000) g_glass_wcb = w;
    }
    if (diag2) {
        static int n; if (++n <= 60) {
            if ((uintptr_t)win > 0x100000000 && (uintptr_t)win < 0x800000000000) {
                int    f58      = *(int  *)((char *)win + 0x58);
                void  *wcb_f8   = *(void **)((char *)win + 0xf8);   // WSCAWindowBacking object (prep_ca reads this)
                void  *flat838  = *(void **)((char *)win + 0x838);  // flatten backing (DP-5 content gate)
                void  *legacy128= *(void **)((char *)win + 0x128);  // legacy attached surface (DP-6)
                // DP-2/DP-4: wcb+0xa8 = the live present-backing (CA surface). Agent's #1 hypothesis:
                // this is the field that is non-NULL under SIM-WS but NULL under AGX-WS → no source layer.
                void  *present_a8 = (wcb_f8 && (uintptr_t)wcb_f8 > 0x100000000 && (uintptr_t)wcb_f8 < 0x800000000000)
                                    ? *(void **)((char *)wcb_f8 + 0xa8) : (void *)-1;
                void  *binddisp = *(void **)((char *)win + 0x818);  // DP-1 window's bound display
                void  *curdisp  = (a0 && (uintptr_t)a0 > 0x100000000 && (uintptr_t)a0 < 0x800000000000)
                                    ? *(void **)((char *)a0 + 0x30) : (void *)-1;  // DP-1 current display
                int    f718     = (int)(*(uint64_t *)((char *)win + 0x718) & 0x40);
                void  *list_after = avalid ? *(void **)((char *)a0 + 0x78) : (void *)-1;
                fprintf(stderr, "#### WS_DIAG2 genLayers #%d window=%p f58=%d bind818=%p cur=%p wcb=%p present_a8=%p f718&40=%d flat838=%p legacy128=%p  srclist %p->%p EMITTED=%d\n",
                        n, win, f58, binddisp, curdisp, wcb_f8, present_a8, f718, flat838, legacy128,
                        list_before, list_after, (list_before != list_after));
            }
        }
    }
    return r;
}
// CCA function range (set at install) — used by the IOSurfaceGetPixelFormat interpose to identify
// the client IOSurface that _MetalCompositeCoreAnimation resolves at 0x185177294 (it calls
// IOSurfaceGetPixelFormat(client_iosurface) at 0x1851772f4 — so a caller-filtered interpose catches it).
static void *g_cca_base = NULL, *g_cca_end = NULL;
// _MetalCompositeCoreAnimation@0x185176a14(window=x0, srcLayer=x1, dest=x2, sub=x3) — the LIVE
// CARenderServer CA-tree re-render that Route A (mode-5 CA-flatten) windows like GlassDemo depend on
// (vs the menu bar's static-IOSurface texture sample). If this fires at all in WS+GlassDemo it's
// GlassDemo's window → the chroot DOES reach the CA re-render (so the failure is the render itself, not
// a skip). ios_candidate walks the agent's chain wcb(window+0xf8)→+0x2b0→+0x18 (the client IOSurface
// the fn resolves at 0x185177294); chain-only read (no IOSurface deref) to stay crash-safe this pass.
typedef void *(*cca_t)(void *, void *, void *, void *);
static cca_t orig_cca = NULL;
static void *hooked_cca(void *window, void *srcLayer, void *dest, void *sub) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
        static int n; if (++n <= 20) {
            void *wcb = NULL, *a = NULL, *ios = NULL;
            if ((uintptr_t)window > 0x100000000 && (uintptr_t)window < 0x800000000000) {
                wcb = *(void **)((char *)window + 0xf8);
                if ((uintptr_t)wcb > 0x100000000 && (uintptr_t)wcb < 0x800000000000) {
                    a = *(void **)((char *)wcb + 0x2b0);
                    if ((uintptr_t)a > 0x100000000 && (uintptr_t)a < 0x800000000000)
                        ios = *(void **)((char *)a + 0x18);
                }
            }
            fprintf(stderr, "#### WS_DIAG2 CCA #%d CALLED (chroot re-renders client CA tree) window=%p dest=%p wcb=%p a(wcb+0x2b0)=%p ios_cand=%p\n",
                    n, window, dest, wcb, a, ios);
        }
        // one-shot: wcb+0x2b0 (the bound client surface) is NULL, so find the client IOSurface elsewhere in
        // the wcb / its CARenderUpdate (wcb+0xa8) — that's the capture point for the wcb+0x2b0 SYNTHESIS.
        // IOSurfaceGet* on a 16-aligned heap ptr is a field-read (safe); sane-dim filter rejects non-surfaces.
        static dispatch_once_t wdump;
        dispatch_once(&wdump, ^{
            if (!g_iosurface_isa) {   // reliable reference isa: create a throwaway IOSurface
                IOSurfaceRef t = IOSurfaceCreate((__bridge CFDictionaryRef)@{
                    @"IOSurfaceWidth": @4, @"IOSurfaceHeight": @4, @"IOSurfaceBytesPerElement": @4 });
                if (t) { g_iosurface_isa = *(void **)t; CFRelease(t); }
            }
            void *w = g_glass_wcb;   // GlassDemo's wcb (from gen_layers); fallback to this CCA's window
            if (!w && (uintptr_t)window > 0x100000000 && (uintptr_t)window < 0x800000000000)
                w = *(void **)((char *)window + 0xf8);
            if ((uintptr_t)w <= 0x100000000 || (uintptr_t)w >= 0x800000000000) {
                fprintf(stderr, "#### WCB-DUMP no wcb (g_glass_wcb=%p)\n", g_glass_wcb); return; }
            fprintf(stderr, "#### WCB-DUMP wcb=%p isa=%p\n", w, g_iosurface_isa);
            void *bases[2] = { w, *(void **)((char *)w + 0xa8) };
            const char *bn[2] = { "wcb", "cru" };
            for (int bi = 0; bi < 2; bi++) {
                void *base = bases[bi];
                if ((uintptr_t)base <= 0x100000000 || (uintptr_t)base >= 0x800000000000) continue;
                for (int off = 0; off < 0x340; off += 8) {
                    void *v = *(void **)((char *)base + off);
                    if ((uintptr_t)v <= 0x100000000 || (uintptr_t)v >= 0x800000000000 || ((uintptr_t)v & 0x7)) continue;
                    if (g_iosurface_isa && *(void **)v == g_iosurface_isa)   // isa-match = real IOSurface (safe to query)
                        fprintf(stderr, "#### WCB-FIELD %s+%#x=%p IOSurf %lux%lu id=%u pf=%#x\n",
                                bn[bi], off, v, (unsigned long)IOSurfaceGetWidth((IOSurfaceRef)v),
                                (unsigned long)IOSurfaceGetHeight((IOSurfaceRef)v), IOSurfaceGetID((IOSurfaceRef)v),
                                IOSurfaceGetPixelFormat((IOSurfaceRef)v));
                }
            }
            fprintf(stderr, "#### WCB-DUMP done\n");
        });
    }
    return orig_cca(window, srcLayer, dest, sub);
}
// Content-receipt chain (does the client's CA content reach WS + bind?). 8-arg
// safe passthrough (preserves x0-x7). Count-only, gate /tmp/macws_ws_diag2.
typedef void *(*sl8_t)(void *, void *, void *, void *, void *, void *, void *, void *);
static sl8_t orig_bind_layer_ctx = NULL, orig_ctx_payload = NULL, orig_bind_surface = NULL;
// RECEIPT-SET probe: read GlassDemo's wcb+0x2b0 (the field CCA samples; NULL in chroot) before/after each
// content-receipt fn — if any one sets it, we find the binder; if none, the setter is elsewhere (QuartzCore).
static void *macws_glass_2b0(void) {
    return (g_glass_wcb && (uintptr_t)g_glass_wcb > 0x100000000 && (uintptr_t)g_glass_wcb < 0x800000000000)
           ? *(void **)((char *)g_glass_wcb + 0x2b0) : NULL;
}
static void macws_receipt_check(const char *name, void *before) {
    void *after = macws_glass_2b0();
    if (g_glass_wcb && before != after && access("/tmp/macws_ws_diag2", F_OK) == 0)
        fprintf(stderr, "#### RECEIPT-SET %s wcb(%p)+0x2b0 %p->%p\n", name, g_glass_wcb, before, after);
}
static void *hooked_bind_layer_ctx(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *before = macws_glass_2b0();
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 BindLayerCtx #%d a0=%p a1=%p\n", n, a, b); }
    void *r = orig_bind_layer_ctx(a, b, c, d, e, f, g, h);
    macws_receipt_check("BindLayerCtx", before);
    return r;
}
static void *hooked_ctx_payload(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *before = macws_glass_2b0();
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 ctxPayloadChanged #%d a0=%p a1=%p\n", n, a, b); }
    void *r = orig_ctx_payload(a, b, c, d, e, f, g, h);
    macws_receipt_check("ctxPayload", before);
    return r;
}
static void *hooked_bind_surface(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *before = macws_glass_2b0();
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 BindSurface #%d a0=%p a2=%p a3(type?)=%p a4=%p\n", n, a, c, d, e); }
    void *r = orig_bind_surface(a, b, c, d, e, f, g, h);
    macws_receipt_check("BindSurface", before);
    return r;
}
static sl8_t orig_prep_ca = NULL;
static void *hooked_prep_ca(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    void *before = macws_glass_2b0();
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 10)
        fprintf(stderr, "#### WS_DIAG2 prepare_coreanimation #%d (flatten driver runs)\n", n); }
    void *r = orig_prep_ca(a, b, c, d, e, f, g, h);
    macws_receipt_check("prepare_ca", before);
    return r;
}
static sl8_t orig_upd_flat = NULL;
static void *hooked_upd_flat(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    if (access("/tmp/macws_ws_diag2", F_OK) == 0) { static int n; if (++n <= 20)
        fprintf(stderr, "#### WS_DIAG2 UpdateFlatteningIfNeeded #%d self=%p\n", n, a); }
    return orig_upd_flat(a, b, c, d, e, f, g, h);
}

// Raw (unsigned) address of SkyLight's _WSIOSurfaceCreateTargetableWithFormatAndProtection,
// resolved in the SkyLight install (DEST-IOSURF 2a). make_iosurf_dest PAC-signs + calls it.
void *g_ws_targetable_iosurf_raw = NULL;
// Raw addr of _WSCompositeDestinationCreateWithIOSurface@0x185437210 (type-2 dest path).
// The dest-routing fix calls this instead of WithMetalTexture so the compositor dest goes
// through MetalIOSurfaceBacking -> newTextureWithDescriptor:iosurface:plane: (the working
// source bind path), making impl+0x40 bind to the IOSurface's kernel-aliased GPU pages.
void *g_ws_wscd_iosurface_raw = NULL;

// SkyLight `MetalContext::StartCompositeForDisplayStream(id<MTLTexture>,
// id<MTLTexture>, MTLLoadAction, MTLStoreAction)` — asserts target_attachment_0
// != nil at MetalContext.mm:627. When the CA Framebuffer texture cascade from
// PrepareForUse leaves the display-stream target as nil, this asserts. Hook to
// early-return 0 (skip this composite frame) instead of aborting.
typedef int (*StartCompositeForDisplayStream_t)(void *self, id target0, id target1,
                                                 unsigned long load_action,
                                                 unsigned long store_action);
static StartCompositeForDisplayStream_t orig_skylight_start_composite_ds = NULL;
static int hooked_skylight_start_composite_ds(void *self, id target0, id target1,
                                              unsigned long load_action,
                                              unsigned long store_action) {
    if (!target0) {
        static int skipped = 0;
        if (skipped < 3) {
            fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream: target0=nil, skip\n");
            skipped++;
        }
        return 0;
    }
    int rv = orig_skylight_start_composite_ds(self, target0, target1, load_action, store_action);
    { extern void macws_dest_trace(const char *, id); macws_dest_trace("DS.target0", target0); macws_dest_trace("DS.target1", target1); }
    // WS-render-thread completion capture for VNC (gated /tmp/macws_vnc_share):
    // getBytes the previous (complete) display frame -> shared surface -> OSXvnc.
    { extern void macws_vnc_on_composite(id); macws_vnc_on_composite(target0); }
    { extern void macws_grab_composite(id); macws_grab_composite(target0); }
    return rv;
}

// SkyLight `MetalContext::StartComposite(WSCompositeDestination*,
// MTLLoadAction, MTLStoreAction)` at static 0x18522d358. Disasm
// (otool of SkyLight) confirms two assert sites inside this function:
//   line 589 — `state._target[0] && "Failed to obtain..."` (destination)
//   line 918 — `state->_target[1] && "Failed to add memoryless..."`
// Both protected by a tolerate-nil flag at MetalContext+0x1c0. The
// existing PrepareForUse-tolerate-nil sets the flag for IOSurface
// backing path, but THIS variant runs from CompositorMetal::composite
// with a different MetalContext. Hook to set the flag on the actual
// ctx (x0=self) being composited.
//
// 2026-06-20 — added pop-on-bail invariant restorer (see comments above
// `orig_skylight_state_stack_pop_back` below).
typedef int (*StartComposite_WSCD_t)(void *self, void *dest,
                                      unsigned long load_action,
                                      unsigned long store_action);
void *orig_skylight_start_composite_wscd_ref = NULL;
// SkyLight `MetalContext::StartComposite(MTLTexture*, MTLLoadAction,
// MTLStoreAction)` — texture variant, called from `SLCADisplay::
// render_update` (the path that drives the assert in MetalContext.mm:411).
//
// SAME pop-on-bail invariant restorer as the WSCD variant.
typedef int (*StartComposite_MTLTex_t)(void *self, id texture,
                                       unsigned long load_action,
                                       unsigned long store_action);
static StartComposite_MTLTex_t orig_skylight_start_composite_mtltex = NULL;

// SkyLight `std::deque<RenderState>::pop_back()` symbol at static 0x186637f84.
// `_state_stack` is the std::deque<RenderState> embedded as the FIRST member
// of MetalContext, so passing `MetalContext*` to pop_back is correct (same
// pointer the C++ symbol expects). MUST be resolved at runtime — the chroot
// SkyLight UUID differs from our static-analysis copy.
typedef void (*StateStack_pop_back_t)(void *deque);
static StateStack_pop_back_t orig_skylight_state_stack_pop_back = NULL;

// LEAK INVARIANT RESTORER — runs after MetalContext::StartComposite returns
// 0 (bail).
//
// Root cause RE'd 2026-06-20:
//   - MetalContext::StartComposite (BOTH the WSCD and MTLTex variants)
//     calls `_state_stack.emplace_back()` UNCONDITIONALLY at +0x12c, BEFORE
//     any inner resource allocation. The push grows [self+0x28] by 1.
//   - When the inner alloc fails (e.g. resolve-tex `_makeTextureFromSurface`
//     returns NULL on chroot because AGXIOC sel=0xa→0x9 ResCreate rejects
//     kIOReturnNoBandwidth), StartComposite returns 0 — WITHOUT popping the
//     just-pushed state.
//   - `SLCADisplay::render_update`'s SITE 2/3 cleanup paths
//     (render_update +0x16c8/+0x1738) handle `Start == 0` by jumping
//     STRAIGHT to `EndUpdate(_, 0, 0)` and SKIPPING the matching
//     `EndCurrentComposite`. They assume Apple's contract: rv==0 means no
//     push happened.
//   - On real Apple hardware the only `rv==0` path is P1 (degenerate rect,
//     checked BEFORE push), so the invariant holds. On our chroot the
//     post-push L3 path is the common case, so the invariant breaks — push
//     leaks, deque grows by one per failed composite, and the next frame's
//     `EndUpdate` trips `__assert_rtn(_state_stack.empty())` at
//     MetalContext.mm:411.
//
// Fix: at hook exit, if `%orig` returned 0 AND the deque size
// (`*((u64*)(self+0x28))`) is HIGHER than before %orig, call the deque's
// `pop_back` directly. That restores the invariant Apple's render_update
// is built on. NOT a NOP/return-bypass; the legitimate inverse of the push
// that StartComposite did.
// Compute the address of the last slot in the std::deque<RenderState> embedded
// in MetalContext. Mirrors the deque math at emplace_back +0x130-+0x170 and
// pop_back +0x14-+0x54 disassembly. Returns NULL on shape inconsistency.
//
// Layout:
//   deque+0x00: map_first    (allocation start)
//   deque+0x08: block_start  (pointer-to-pointer at start of in-use buckets)
//   deque+0x10: block_end    (pointer-to-pointer one past last in-use)
//   deque+0x18: map_last     (allocation end)
//   deque+0x20: start_offset (element index of first element from block 0)
//   deque+0x28: size         (element count)
//
// idx = start_offset + size - 1
// block_idx = idx / 23
// slot = block_start[block_idx] + (idx % 23) * 0xb0
static void *macws_deque_slot_ptr(void *self, uint64_t idx) {
    if (!self) return NULL;
    uintptr_t d = (uintptr_t)self;
    void **bucket = *(void ***)(d + 8);
    if (!bucket) return NULL;
    uint64_t block_idx = idx / 23;
    uint8_t *block = (uint8_t *)bucket[block_idx];
    if (!block || (uintptr_t)block < 0x1000) return NULL;
    return block + (idx % 23) * 0xb0;
}

static int macws_pop_on_startcomp_bail(void *self, uint64_t before, int rv) {
    if (rv != 0) return rv;
    if (!self || (uintptr_t)self < 0x1000) return rv;
    if (!orig_skylight_state_stack_pop_back) return rv;
    uint64_t after = *(volatile uint64_t *)((char *)self + 0x28);
    if (after <= before) return rv;
    // pop until we're back to the pre-call size. In practice that's a single
    // pop because StartComposite only pushes once, but a `while` guards us
    // against the (theoretical) case where it pushed twice before bailing.
    static _Atomic int leaks_observed = 0;
    int n = atomic_fetch_add(&leaks_observed, 1);
    if (n < 16) {
        dprintf(STDERR_FILENO,
            "#### SS BAIL-POP self=%p before=%llu after=%llu rv=%d (#%d)\n",
            self, (unsigned long long)before, (unsigned long long)after, rv, n);
    }
    while (after > before) {
        // Zero the just-pushed slot BEFORE pop_back's destructor runs.
        // RenderState::~RenderState (0x186637c0c) calls objc_release on
        // [slot+8], [slot+0x10], [slot+0x18], [slot+0x20] and another
        // cleanup on [slot+0x00]. After StartComposite L3 bailed, those
        // fields hold either: nil (for never-written), retained but
        // dangling refs (for L3 partial), or uninitialised stack-leftover.
        // Zero them — objc_release(nil) is a documented safe no-op, and
        // the [slot+0x00] cleanup is similarly nil-safe per the AppKit
        // convention. The OBJECTS the slot referenced are NOT released;
        // their owning code (CA backend) holds independent retains. We
        // skip releasing the slot's copies — equivalent to a one-frame
        // ObjC retain "leak" worth ≤4 refs per failed composite. The
        // alternative (allowing the destructor to chase the dangling
        // refs) was empirically SIGSEGV'ing on the first BAIL-POP fire.
        uint64_t start = *(volatile uint64_t *)((char *)self + 0x20);
        uint64_t cur_size = *(volatile uint64_t *)((char *)self + 0x28);
        if (cur_size == 0) break;
        void *slot = macws_deque_slot_ptr(self, start + cur_size - 1);
        if (slot) memset(slot, 0, 0xb0);
        orig_skylight_state_stack_pop_back(self);
        uint64_t new_after = *(volatile uint64_t *)((char *)self + 0x28);
        if (new_after >= after) break;  // safety: pop didn't shrink → stop
        after = new_after;
    }
    return rv;
}

int hooked_skylight_start_composite_wscd(void *self, void *dest,
                                          unsigned long load_action,
                                          unsigned long store_action) {
    if (self) {
        *((volatile uint8_t *)self + 0x1c0) = 1;
    }
    uint64_t before = (self && (uintptr_t)self >= 0x1000)
        ? *(volatile uint64_t *)((char *)self + 0x28) : 0;
    int rv = ((StartComposite_WSCD_t)orig_skylight_start_composite_wscd_ref)(
        self, dest, load_action, store_action);
    // VNC completion-capture: map the WSCompositeDestination back to its
    // MTLTexture (recorded at WSCompositeDestinationCreateWithMetalTexture)
    // and feed it to the WS-render-thread capture.
    { extern NSMutableDictionary *g_wscd_tex;
      if (g_wscd_tex && dest) {
          id tex = nil;
          @synchronized(g_wscd_tex) { tex = g_wscd_tex[[NSValue valueWithPointer:dest]]; }
          if (tex) { extern void macws_dest_trace(const char *, id); macws_dest_trace("WSCDstart", tex);
                     extern void macws_vnc_on_composite(id); macws_vnc_on_composite(tex);
                     extern void macws_grab_composite(id); macws_grab_composite(tex); }
      } }
    return macws_pop_on_startcomp_bail(self, before, rv);
}

static int hooked_skylight_start_composite_mtltex(void *self, id texture,
                                                  unsigned long load_action,
                                                  unsigned long store_action) {
    if (self) {
        *((volatile uint8_t *)self + 0x1c0) = 1;
    }
    uint64_t before = (self && (uintptr_t)self >= 0x1000)
        ? *(volatile uint64_t *)((char *)self + 0x28) : 0;
    { extern void macws_dest_trace(const char *, id); macws_dest_trace("MTLTex", texture); }
    // ── TEXTURE-WALL FIX (gated /tmp/macws_dest_iosurf): swap the plain dest for an
    // IOSurface-backed one (cached) so the composite renders into readable memory. ──
    id usetex = texture;
    if (access("/tmp/macws_dest_iosurf", F_OK) == 0) {
        extern id macws_make_iosurf_dest(id);
        id swapped = macws_make_iosurf_dest(texture);
        if (swapped) {
            static int sw = 0;
            if (sw++ < 4) fprintf(stderr, "#### MTLTEX DEST-SWAP texture=%p -> %p\n",
                                  (void *)texture, (void *)swapped);
            usetex = swapped;
        }
    }
    int rv = orig_skylight_start_composite_mtltex(
        self, usetex, load_action, store_action);
    { extern void macws_vnc_on_composite(id); macws_vnc_on_composite(usetex); }
    { extern void macws_grab_composite(id); macws_grab_composite(usetex); }
    return macws_pop_on_startcomp_bail(self, before, rv);
}

// SkyLight `WSCompositeDestinationCreateWithMetalTexture(MTLTexture*, MetalContext*, ...)`
// — asserts texture != nil at CompositeDestinationMetal.mm:165. BN disasm
// (SkyLight at 0x18523053c):
//   - first instr after prologue: `cbz x1, +0x344` → device assert (line 160)
//   - then `cbnz x19, +0x10` (x19 = x0) skips OK path if texture is set
//   - `cbz x19, +0x2e4` → texture assert (line 165)
// So x0 IS THE TEXTURE, x1 is the device/MetalContext. Earlier hook had the
// argument order REVERSED and was checking the wrong slot for nil, which is
// why the hook never absorbed the nil — the texture argument carrying the
// nil sat at x0 while the hook tested x1.
typedef void *(*WSCompositeDestinationCreateWithMetalTexture_t)(
    id texture, void *ctx, void *protectionOptions, void *colorspace, void *region);
static WSCompositeDestinationCreateWithMetalTexture_t orig_skylight_wsccd_with_tex = NULL;

// DIAG helper (gated /tmp/macws_dest_diag): identify which WSCD arg is the real
// MTLTexture vs a destination/scanout container — RE workflow + project hook
// disagree on arg index. Logs class + iosurface + _impl backing fields per arg.
static void macws_dump_wscd_arg(int n, const char *which, id obj) {
    char l[280];
    if (!macws_ptr_ok((uint64_t)obj)) {
        snprintf(l, sizeof l, "WSCDARG #%d %s = %p (not obj)\n", n, which, (void *)obj);
    } else {
        const char *cls = object_getClassName(obj);
        uint64_t ios = 0, impl = 0, b130 = 0, a0 = 0, res = 0;
        if ([obj respondsToSelector:@selector(iosurface)]) {
            typedef IOSurfaceRef (*f)(id, SEL);
            ios = (uint64_t)((f)objc_msgSend)(obj, @selector(iosurface));
        }
        Ivar iv = class_getInstanceVariable(object_getClass(obj), "_impl");
        if (iv) {
            impl = *(volatile uint64_t *)((char *)obj + ivar_getOffset(iv));
            if (macws_ptr_ok(impl)) {
                b130 = *(volatile uint64_t *)(impl + 0x130);
                a0   = *(volatile uint64_t *)(impl + 0xa0);
                res  = *(volatile uint64_t *)(impl + 0x10);
            }
        }
        snprintf(l, sizeof l,
            "WSCDARG #%d %s cls=%s iosurf=%#llx impl=%#llx 0x130=%#llx 0xa0=%#llx 0x10=%#llx\n",
            n, which, cls ? cls : "?", (unsigned long long)ios, (unsigned long long)impl,
            (unsigned long long)b130, (unsigned long long)a0, (unsigned long long)res);
    }
    int fd = open("/tmp/macws_dest.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, l, strlen(l)); close(fd); }
}
static void *hooked_skylight_wsccd_with_tex(id texture, void *ctx, void *protectionOptions,
                                            void *colorspace, void *region) {
    if (!texture) {
        static int nil_count = 0;
        if (nil_count < 4) {
            fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture: texture=nil, return NULL\n");
            nil_count++;
        }
        return NULL;
    }
    { extern void macws_dest_trace(const char *, id); macws_dest_trace("WSCDcreate", texture); }
    { extern void macws_2b_alias_dest(id); macws_2b_alias_dest(texture); }
    // ── DEST→IOSurface REDIRECT (gated /tmp/macws_wscd_iosurf) — THE FIX ──
    // RE-confirmed: the dest is created via WithMetalTexture (type-3, plain texture) so its
    // GPU-RT VA (impl+0x40) never binds to an IOSurface (NOT a kernel wall — type=0x82 maps
    // IOSurface pages writably, no gate). Route the dest through WithIOSurface (type-2) against
    // a WS targetable IOSurface so it goes through MetalIOSurfaceBacking ->
    // newTextureWithDescriptor:iosurface:plane: (the working source bind path) -> the GPU
    // renders into the IOSurface's kernel-aliased pages. Scoped to the 2000x1456 macOS dest.
    if (access("/tmp/macws_wscd_iosurf", F_OK) == 0 && g_ws_wscd_iosurface_raw && texture) {
        @try {
            typedef unsigned long (*wh_t)(id, SEL);
            unsigned long w = ((wh_t)objc_msgSend)(texture, @selector(width));
            unsigned long h = ((wh_t)objc_msgSend)(texture, @selector(height));
            if (w >= 1900 && w < 2300) {
                extern IOSurfaceRef macws_dest_targetable_iosurf(int, int);
                IOSurfaceRef ios = macws_dest_targetable_iosurf((int)w, (int)h);
                if (ios) {
#if __has_feature(ptrauth_calls)
                    void *(*wfn)(void *, void *, void *, void *, void *) =
                        __builtin_ptrauth_sign_unauthenticated(g_ws_wscd_iosurface_raw, 0, 0);
#else
                    void *(*wfn)(void *, void *, void *, void *, void *) =
                        (void *(*)(void *, void *, void *, void *, void *))g_ws_wscd_iosurface_raw;
#endif
                    void *wscd2 = NULL;
                    @try { wscd2 = wfn((void *)ios, ctx, protectionOptions, colorspace, region); }
                    @catch (__unused NSException *e) { wscd2 = NULL; }
                    static int rn;
                    if (rn++ < 4) fprintf(stderr, "#### WSCD->IOSURFACE redirect %lux%lu ios=%p wscd2=%p\n",
                                          (unsigned long)w, (unsigned long)h, (void *)ios, wscd2);
                    if (wscd2) return wscd2;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    // ── TEXTURE-WALL FIX (gated /tmp/macws_dest_iosurf) ──
    // RE-confirmed: the macOS compose dest (pf=550) is a PLAIN render target — the GPU
    // renders into its private backing and the scanout IOSurface stays empty (black).
    // Swap it for an IOSurface-backed dest (cached by w×h×pf) BEFORE the WSCompositeDestination
    // is built, so the composite renders into readable IOSurface memory. g_wscd_tex then
    // maps the WSCD to the swapped texture, so the grab/VNC read real pixels. nil-swap →
    // keep the original (safe).
    if (access("/tmp/macws_dest_iosurf", F_OK) == 0) {
        extern id macws_make_iosurf_dest(id);
        id swapped = macws_make_iosurf_dest(texture);
        if (swapped) {
            static int sw = 0;
            if (sw++ < 4) fprintf(stderr, "#### WSCD DEST-SWAP texture=%p -> IOSurface-backed=%p\n",
                                  (void *)texture, (void *)swapped);
            texture = swapped;
        }
    }
    void *wscd = orig_skylight_wsccd_with_tex(texture, ctx, protectionOptions, colorspace, region);
    // ── WSCDARG identify (gated /tmp/macws_dest_diag): which arg is the real
    // MTLTexture render dest vs the scanout container? Dump arg0(texture)+arg1(ctx). ──
    if (access("/tmp/macws_dest_diag", F_OK) == 0) {
        static _Atomic int idn = 0;
        int in = atomic_fetch_add(&idn, 1);
        if (in < 6) {
            macws_dump_wscd_arg(in, "arg0", texture);
            macws_dump_wscd_arg(in, "arg1", (id)ctx);
        }
    }
    // ── DEST-SCAN (gated /tmp/macws_dest_diag): the decisive step-① test ──
    // Does the COMPOSE actually render pixels into its destination IOSurface,
    // or is the dest empty? texture (arg0) is the compose destination. We scan
    // the PREVIOUS dest (already rendered by the frame between calls) with a
    // 1-frame lag, so we read content AFTER the GPU drew it. If nz% is high →
    // compose DOES produce content (then the wall is routing to VNC). If ~0 →
    // compose draws nothing (deeper / Metal-proxy). Reliable file-log; no lldb.
    if (access("/tmp/macws_dest_diag", F_OK) == 0 &&
        [texture respondsToSelector:@selector(iosurface)]) {
        // Self-contained per-call (NO cross-frame texture retain — that crashed
        // WS's texture lifecycle). The compose dest IOSurface is REUSED per frame
        // (base stable across scans), so scanning it at setup-time reads the PRIOR
        // frame's render. (1) read this texture's C++ _impl backing fields; (2)
        // scan its IOSurface content; (3) verdict: is the CPU base the IOSurface?
        typedef IOSurfaceRef (*iosurf_imp_t)(id, SEL);
        static _Atomic int dn = 0;
        int n = atomic_fetch_add(&dn, 1);
        if (n < 200) {
            uint64_t impl = 0, b130 = 0, a0 = 0, res = 0;
            Ivar iv = class_getInstanceVariable(object_getClass(texture), "_impl");
            if (iv) {
                impl = *(volatile uint64_t *)((char *)texture + ivar_getOffset(iv));
                if (macws_ptr_ok(impl)) {
                    b130 = *(volatile uint64_t *)(impl + 0x130);
                    a0   = *(volatile uint64_t *)(impl + 0xa0);
                    res  = *(volatile uint64_t *)(impl + 0x10);
                }
            }
            IOSurfaceRef surf = ((iosurf_imp_t)objc_msgSend)(texture, @selector(iosurface));
            uint64_t sbase = 0; size_t nz = 0, samp = 0, w = 0, h = 0, bpr = 0, bpe = 0;
            if (surf) {
                IOSurfaceLock(surf, 0x1, NULL);
                void *base = IOSurfaceGetBaseAddress(surf); sbase = (uint64_t)base;
                w = IOSurfaceGetWidth(surf); h = IOSurfaceGetHeight(surf);
                bpr = IOSurfaceGetBytesPerRow(surf); bpe = IOSurfaceGetBytesPerElement(surf);
                if (base && w && h && bpr && bpe) {
                    for (size_t gy = 0; gy < 64; gy++) { size_t y = gy * h / 64;
                        for (size_t gx = 0; gx < 64; gx++) { size_t x = gx * w / 64;
                            uint8_t *p = (uint8_t *)base + y * bpr + x * bpe;
                            uint64_t v = 0; for (size_t b = 0; b < bpe && b < 8; b++) v |= ((uint64_t)p[b]) << (8 * b);
                            if (v) nz++; samp++;
                        } }
                }
                IOSurfaceUnlock(surf, 0x1, NULL);
            }
            const char *match = (b130 && sbase && b130 == sbase) ? "B130==IOSURF"
                              : (b130 && sbase) ? "B130!=IOSURF(separate)" : "?";
            char line[360];
            snprintf(line, sizeof line,
                "DEST2 #%d %zux%zu bpe=%zu surfref=%p IOSurf.base=%#llx nz=%zu/%zu(%.1f%%) | impl=%#llx 0x130=%#llx 0xa0=%#llx res=%#llx | %s\n",
                n, w, h, bpe, (void *)surf, (unsigned long long)sbase, nz, samp,
                samp ? 100.0 * (double)nz / (double)samp : 0.0,
                (unsigned long long)impl, (unsigned long long)b130,
                (unsigned long long)a0, (unsigned long long)res, match);
            int fd = open("/tmp/macws_dest.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) { write(fd, line, strlen(line)); close(fd); }
        }
    }
    // ── BLIT-RB (gated /tmp/macws_blit_rb): one-shot GPU blit-readback of the
    // compose dest's ACTUAL GPU backing in the LIVE WS (which CAN submit). Splits
    // the last ambiguity: blit copyFromTexture:toBuffer: reads the texture's real
    // render backing regardless of IOSurface/field offsets. content>0 → the GPU
    // rendered but the backing is DECOUPLED from the scanout IOSurface (routing,
    // fixable: blit dest→IOSurface each frame). content~0 → compose draws nothing
    // (samples empty inputs → deeper). Fires at call #20 so the dest is composed.
    if (access("/tmp/macws_blit_rb", F_OK) == 0) {
        static _Atomic int bc = 0;
        int bn = atomic_fetch_add(&bc, 1);
        if (bn == 20) {
            {
                id tex = texture;
                id dev = ((id(*)(id, SEL))objc_msgSend)(tex, @selector(device));
                unsigned long w  = ((unsigned long(*)(id, SEL))objc_msgSend)(tex, @selector(width));
                unsigned long h  = ((unsigned long(*)(id, SEL))objc_msgSend)(tex, @selector(height));
                unsigned long pf = ((unsigned long(*)(id, SEL))objc_msgSend)(tex, @selector(pixelFormat));
                unsigned long bpe = (pf == 115) ? 8 : (pf == 10) ? 1 : 4;
                unsigned long bpr = w * bpe, total = bpr * h;
                id dst = ((id(*)(id, SEL, unsigned long, unsigned long))objc_msgSend)(
                    dev, @selector(newBufferWithLength:options:), total, 0 /*Shared*/);
                id q  = ((id(*)(id, SEL))objc_msgSend)(dev, @selector(newCommandQueue));
                id cb = ((id(*)(id, SEL))objc_msgSend)(q, @selector(commandBuffer));
                id bl = ((id(*)(id, SEL))objc_msgSend)(cb, @selector(blitCommandEncoder));
                typedef struct { unsigned long a, b, c; } V3;  // MTLOrigin / MTLSize (24B, indirect ABI)
                typedef void (*copy_t)(id, SEL, id, unsigned long, unsigned long, V3, V3,
                                       id, unsigned long, unsigned long, unsigned long);
                V3 org = {0, 0, 0}, sz = {w, h, 1};
                ((copy_t)objc_msgSend)(bl, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:),
                    tex, 0, 0, org, sz, dst, 0, bpr, total);
                ((void(*)(id, SEL))objc_msgSend)(bl, @selector(endEncoding));
                ((void(*)(id, SEL))objc_msgSend)(cb, @selector(commit));
                ((void(*)(id, SEL))objc_msgSend)(cb, @selector(waitUntilCompleted));
                long st = ((long(*)(id, SEL))objc_msgSend)(cb, @selector(status));
                id err  = ((id(*)(id, SEL))objc_msgSend)(cb, @selector(error));
                uint8_t *p = ((void *(*)(id, SEL))objc_msgSend)(dst, @selector(contents));
                size_t nz = 0, samp = 0;
                if (p && w && h) {
                    for (size_t gy = 0; gy < 64; gy++) { size_t y = gy * h / 64;
                        for (size_t gx = 0; gx < 64; gx++) { size_t x = gx * w / 64;
                            uint8_t *q2 = p + y * bpr + x * bpe;
                            uint64_t v = 0; for (size_t b = 0; b < bpe && b < 8; b++) v |= ((uint64_t)q2[b]) << (8 * b);
                            if (v) nz++; samp++;
                        } }
                }
                char line[256];
                snprintf(line, sizeof line,
                    "BLIT-RB w=%lu h=%lu bpe=%lu cbstatus=%ld err=%s nz=%zu/%zu (%.1f%%)\n",
                    w, h, bpe, st, err ? "YES" : "no", nz, samp, samp ? 100.0 * (double)nz / (double)samp : 0.0);
                int fd = open("/tmp/macws_blit_rb.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
                if (fd >= 0) { write(fd, line, strlen(line)); close(fd); }
                // one-shot diagnostic: intentionally leak dst/q/cb (no release, no
                // autoreleasepool) — avoids the async use-after-free that crashed WS
                // when the cb's completion fired after the pool drained / over-release.
            }
        }
    }
    // Map WSCompositeDestination -> its MTLTexture, so the WSCD-variant
    // StartComposite hook (the one that fires in coexist) can feed the
    // VNC completion-capture (which needs the destination texture).
    if (wscd && texture) {
        static NSMutableDictionary *m = nil; static dispatch_once_t o;
        dispatch_once(&o, ^{ m = [NSMutableDictionary new]; });
        extern NSMutableDictionary *g_wscd_tex; g_wscd_tex = m;
        @synchronized(m) { m[[NSValue valueWithPointer:wscd]] = texture; }
    }
    return wscd;
}
NSMutableDictionary *g_wscd_tex = nil;  // WSCD ptr (NSValue) -> id<MTLTexture>

// MetalContext::StopCapture() guard — see install_skylight_prepare_for_use_tolerate_nil_hook()
// for the call-site explanation.
typedef void (*MetalContext_StopCapture_t)(void *this);
static MetalContext_StopCapture_t orig_metalcontext_stop_capture = NULL;
static void hooked_metalcontext_stop_capture(void *this) {
    if ((uintptr_t)this < 0x1000) {
        static int bad_count = 0;
        if (bad_count < 4) {
            fprintf(stderr, "#### MetalContext::StopCapture: invalid this=%p, skipping\n", this);
            bad_count++;
        }
        return;
    }
    orig_metalcontext_stop_capture(this);
}

#import <execinfo.h>
// ── (diagnostic, gated /tmp/macws_modeset_trace) IOMFBDisplay mode-set trace ──
// Watchpoint-confirmed: [IOMFBDisplay+0x228] (scanout pixel-format/config) is
// NEVER written → stays -1 → current_page_surface's predicate discards the page
// every frame → per-frame realloc leak + no valid scanout. Log [self+0x228]/
// [+0x218]/[+0x20] before+after the mode-apply functions to locate the writer /
// the bail that skips the write. By-symbol hooks (no offset drift). NOT a fix.
typedef void (*ms_ufl_t)(void *self, unsigned int a);
typedef void (*ms_uti_t)(void *self);
typedef void (*ms_sps_t)(void *self, unsigned int on);
static intptr_t g_qc_slide = 0;   // QuartzCore ASLR slide (set in install_modeset_trace)
static ms_ufl_t orig_ms_ufl = NULL;
static ms_uti_t orig_ms_uti = NULL;
static ms_sps_t orig_ms_sps = NULL;
static void macws_rd228(const char *tag, void *self) {
    if (!self || (uintptr_t)self <= 0x1000) { fprintf(stderr, "#### MODESET %s self=%p\n", tag, self); return; }
    uint64_t v = *(volatile uint64_t *)((char *)self + 0x228);
    uint32_t f218 = *(volatile uint32_t *)((char *)self + 0x218);
    void *p20 = *(void **)((char *)self + 0x20);
    fprintf(stderr, "#### MODESET %s self=%p [+0x228]=%#llx [+0x218]=%#x [+0x20]=%p\n",
            tag, self, (unsigned long long)v, f218, p20);
}
static void macws_hook_ms_ufl(void *self, unsigned int a) {
    static int n = 0; int log = (n++ < 12);
    if (log) macws_rd228("ufl.IN", self);
    orig_ms_ufl(self, a);
    if (log) macws_rd228("ufl.OUT", self);
}
static void macws_hook_ms_uti(void *self) {
    static int n = 0; int log = (n++ < 12);
    if (log) macws_rd228("uti.IN", self);
    orig_ms_uti(self);
    if (log) macws_rd228("uti.OUT", self);
}
// The mode-set ORCHESTRATOR (unslid 0x187c83f44): big sub sp,#0x680 frame,
// the ONLY function that bl's update_framebuffer_locked (@0x187c85218/2e4),
// update_timing_info (@0x187c854e0) and set_power_state (@0x187c854f4). It's
// gated on its w1 flags arg (bail to epilogue unless flags&~0x130 != 0; the
// ufl/mode-apply is deep behind more flag/field gates). Log every (self,flags)
// to learn what flags chroot calls it with + correlate with whether ufl fires.
typedef void (*ms_orch_t)(void *self, unsigned int flags);
static ms_orch_t orig_ms_orch = NULL;
// Display CONSTRUCTION handshake (QC 13.4):
//  - 0x187a8aa08 = display init (calls orchestrator flags=-0x11 on some path)
//  - 0x187c8bf58 = setter: if [self+0x224]!=w1 -> store + orchestrator flags=0x246
// Both should fire at display construction and trigger the mode-set. Log them to
// see (a) does construction reach them in chroot, (b) [self+0x224] value (gate).
typedef void* (*disp_init_t)(void *self, void *a1, uint64_t a2, uint64_t a3);
typedef void* (*disp_setter_t)(void *self, unsigned int w1);
static disp_init_t   orig_disp_init = NULL;
static disp_setter_t orig_disp_setter = NULL;
_Atomic int g_in_createmode = 0;     // read by IOConnectCallMethod_new; set around the QC IOMFBDisplay ctor
static intptr_t macws_imfb_slide(void) {
    static intptr_t s = -1;
    if (s == -1) {
        s = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm && strstr(nm, "IOMobileFramebuffer")) { s = _dyld_get_image_vmaddr_slide(i); break; }
        }
    }
    return s;
}
static void *macws_hook_disp_init(void *self, void *a1, uint64_t a2, uint64_t a3) {
    // Lightweight one-shot logging only. (Removed the IOMFB __DATA table read —
    // _dyld_get_image_vmaddr_slide gives __TEXT slide; __DATA may be in a different
    // subcache with a different slide, so the computed-addr read could fault and
    // kill WS at display-init. Read IOMFB __DATA only via a verified slide later.)
    static int once = 0;
    if (!once) {
        once = 1;
        fprintf(stderr, "#### DISPCFG init self=%p a3=%#llx\n", self, (unsigned long long)a3);
    }
    // Mark the window so IOConnectCallMethod_new logs every IOConnect the ctor
    // makes (the mode/timing query that gates the mode-set). Safe: this hook is
    // QuartzCore (correct slide, known sig) — no IOMFB-function patching.
    atomic_fetch_add(&g_in_createmode, 1);
    void *r = orig_disp_init(self,a1,a2,a3);
    atomic_fetch_sub(&g_in_createmode, 1);
    return r;
}
static void *macws_hook_disp_setter(void *self, unsigned int w1) {
    static int n=0;
    if (n++<12) {
        uint8_t cur = ((uintptr_t)self>0x1000)?*(volatile uint8_t*)((char*)self+0x224):0xff;
        fprintf(stderr, "#### DISPCFG setter#%d self=%p w1=%u [+0x224]_before=%u (%s)\n",
                n, self, w1, cur, (cur==w1)?"SKIP-equal":"WILL-reconfig");
    }
    return orig_disp_setter(self,w1);
}
// IOMobileFramebuffer "create display-mode" accessor (unslid 0x18b024a5c). The
// QC IOMFBDisplay ctor calls it; it allocs a mode obj, calls an IOConnect mode/
// timing query (-> IOKit MIG leaf 0x1835881f8), and on query-error frees the obj
// and returns *out=0 -> the ctor's `cbz x1` skips the whole mode-set. We log its
// status + *out, and (via g_in_createmode) make the IOConnect hook log EVERY call
// it makes so we capture the exact failing selector/kr. Cache shares one slide,
// so this is reachable via g_qc_slide.
// current_page_surface (QC 0x187c98b10): the per-frame page allocator. Hook it to
// read the REAL churning display's scanout state ([+0x228]/[+0x218]/[+0x20]) — the
// prior measurement was on the set_power_state-target display which may differ.
// ONE-SHOT logging (per-frame fn — keep overhead near zero). Gated /tmp/macws_pred_hook.
typedef void* (*cps_t)(void *self, void *a1, void *a2, void *a3);
static cps_t orig_cps = NULL;
static void *macws_hook_cps(void *self, void *a1, void *a2, void *a3) {
    static int n = 0;
    if (n < 4 && (uintptr_t)self > 0x1000) {
        n++;
        uint64_t v228 = *(volatile uint64_t*)((char*)self + 0x228);
        uint32_t f218 = *(volatile uint32_t*)((char*)self + 0x218);
        void *p20 = *(void**)((char*)self + 0x20);
        fprintf(stderr, "#### CPS#%d self=%p [+0x228]=%#llx [+0x218]=%#x [+0x20]=%p\n",
                n, self, (unsigned long long)v228, f218, p20);
    }
    return orig_cps(self, a1, a2, a3);
}
typedef unsigned long (*imfb_cm_t)(void *a0, void *a1, void *a2, void **outp);
static imfb_cm_t orig_imfb_cm = NULL;
static unsigned long macws_hook_imfb_cm(void *a0, void *a1, void *a2, void **outp) {
    atomic_fetch_add(&g_in_createmode, 1);
    unsigned long st = orig_imfb_cm(a0, a1, a2, outp);
    atomic_fetch_sub(&g_in_createmode, 1);
    static int n=0;
    if (n++<8)
        fprintf(stderr, "#### IMFB createmode#%d a0=%p a1=%p a2=%p -> status=%#lx *out=%p\n",
                n, a0, a1, a2, st, outp ? *outp : NULL);
    return st;
}
// Second accessor variant (unslid 0x18b029710), used on the [this+0x2f8]==0 path
// (stub 0x187cbf9d8). Signature: (x0, x1=out**).
typedef unsigned long (*imfb_cm2_t)(void *a0, void **outp);
static imfb_cm2_t orig_imfb_cm2 = NULL;
static unsigned long macws_hook_imfb_cm2(void *a0, void **outp) {
    atomic_fetch_add(&g_in_createmode, 1);
    unsigned long st = orig_imfb_cm2(a0, outp);
    atomic_fetch_sub(&g_in_createmode, 1);
    static int n=0;
    if (n++<8)
        fprintf(stderr, "#### IMFB createmode2#%d a0=%p -> status=%#lx *out=%p\n",
                n, a0, st, outp ? *outp : NULL);
    return st;
}
static void macws_hook_ms_orch(void *self, unsigned int flags) {
    static int n = 0; int log = (n++ < 24);
    if (log) {
        uint64_t v228 = ((uintptr_t)self>0x1000)?*(volatile uint64_t*)((char*)self+0x228):0;
        fprintf(stderr, "#### MODESET ORCH#%d self=%p flags=%#x [+0x228]=%#llx\n",
                n, self, flags, (unsigned long long)v228);
    }
    orig_ms_orch(self, flags);
}
static void macws_hook_ms_sps(void *self, unsigned int on) {
    static int n = 0; int log = (n++ < 4);
    if (log) {
        void *ra = __builtin_return_address(0);
        uintptr_t unslid = (uintptr_t)ra - (uintptr_t)g_qc_slide;
        fprintf(stderr, "#### MODESET sps self=%p on=%u caller_ra=%p caller_unslid=%#lx\n",
                self, on, ra, (unsigned long)unslid);
        macws_rd228("sps.IN", self);
        // Full backtrace: resolve each QuartzCore frame to its unslid __text
        // offset (frame - slide) so we can map the display-setup call chain
        // offline against qc_text.bin and find where config SHOULD happen.
        void *bt[40]; int nf = backtrace(bt, 40);
        for (int i = 0; i < nf; i++) {
            uintptr_t u = (uintptr_t)bt[i] - (uintptr_t)g_qc_slide;
            Dl_info di; const char *img = "?";
            if (dladdr(bt[i], &di) && di.dli_fname) {
                const char *b = strrchr(di.dli_fname, '/'); img = b ? b+1 : di.dli_fname;
            }
            fprintf(stderr, "#### MODESET bt[%02d] %p unslid=%#lx %s\n",
                    i, bt[i], (unsigned long)u, img);
        }
    }
    orig_ms_sps(self, on);
    if (log) macws_rd228("sps.OUT", self);
}
// 13.4 QuartzCore UNSLID __text addresses (cache file addrs from extraction).
// update_framebuffer_locked / update_timing_info are LOCAL symbols (MSFindSymbol
// can't find them), but set_power_state IS exported — derive the ASLR slide from
// it and reach the locals by computed address.
#define QC_UNSLID_set_power_state        0x187c86c34
#define QC_UNSLID_update_framebuffer_lk  0x187c86174
#define QC_UNSLID_update_timing_info     0x187c869a0
#define QC_UNSLID_fetch_current_mode     0x187c88470
#define QC_UNSLID_modeset_orchestrator   0x187c83f44
#define QC_UNSLID_disp_init              0x187a8aa08
#define QC_UNSLID_disp_setter            0x187c8bf58
#define QC_UNSLID_current_page_surface   0x187c98b10
#define UNSLID_imfb_createmode           0x18b024a5c  /* IOMobileFramebuffer (same cache slide) */
#define UNSLID_imfb_createmode2          0x18b029710  /* variant used on [this+0x2f8]==0 path */
static void install_modeset_trace(void) {
    if (access("/tmp/macws_modeset_trace", F_OK) != 0) return;
    MSImageRef qc = MSGetImageByName(QuartzCorePath);
    if (!qc) { fprintf(stderr, "#### MODESET: QuartzCore image not found\n"); return; }
    void *s3 = MSFindSymbol(qc, "__ZN2CA12WindowServer12IOMFBDisplay15set_power_stateEb");
    if (!s3) { fprintf(stderr, "#### MODESET: set_power_state sym not found (cannot derive slide)\n"); return; }
    intptr_t slide = (intptr_t)s3 - (intptr_t)QC_UNSLID_set_power_state;
    g_qc_slide = slide;
    fprintf(stderr, "#### MODESET: set_power_state @%p slide=%#lx\n", s3, (long)slide);
    MSHookFunction(s3, (void *)macws_hook_ms_sps, (void **)&orig_ms_sps);
    void *s1 = (void *)((uintptr_t)QC_UNSLID_update_framebuffer_lk + slide);
    MSHookFunction(s1, (void *)macws_hook_ms_ufl, (void **)&orig_ms_ufl);
    fprintf(stderr, "#### MODESET hook update_framebuffer_locked @%p\n", s1);
    void *s2 = (void *)((uintptr_t)QC_UNSLID_update_timing_info + slide);
    MSHookFunction(s2, (void *)macws_hook_ms_uti, (void **)&orig_ms_uti);
    fprintf(stderr, "#### MODESET hook update_timing_info @%p\n", s2);
    void *s4 = (void *)((uintptr_t)QC_UNSLID_modeset_orchestrator + slide);
    MSHookFunction(s4, (void *)macws_hook_ms_orch, (void **)&orig_ms_orch);
    fprintf(stderr, "#### MODESET hook orchestrator @%p\n", s4);
    // disp_init (IOMFBDisplay ctor 0x187a8aa08) + disp_setter hooks DISABLED:
    // hooking the ctor destabilized WS startup (died at display-init before GPU,
    // reproducibly) while sps/ufl/uti/orchestrator hooks are stable. Re-enable only
    // with a gentler observation method if ctor-time data is needed again.
    (void)macws_hook_disp_init; (void)macws_hook_disp_setter;
    (void)QC_UNSLID_disp_init; (void)QC_UNSLID_disp_setter;
    fprintf(stderr, "#### MODESET disp_init/disp_setter hooks DISABLED (destabilize startup)\n");
    // Observe the REAL churn decision: hook current_page_surface (QC, stable class).
    if (access("/tmp/macws_pred_hook", F_OK) == 0) {
        void *sc = (void *)((uintptr_t)QC_UNSLID_current_page_surface + slide);
        MSHookFunction(sc, (void *)macws_hook_cps, (void **)&orig_cps);
        fprintf(stderr, "#### MODESET hook current_page_surface @%p\n", sc);
    }
    // Option B: hook the IOMFB mode accessors using the CORRECT IOMFB slide
    // (macws_imfb_slide — IOMFB is in a different subcache than QC, so g_qc_slide is
    // wrong for it; that was the earlier crash). Observe their return status + *out
    // in the chroot, and (next) synthesize a valid mode on failure. Gated by a
    // SEPARATE sentinel /tmp/macws_imfb_hook so it can be A/B'd against the stable
    // baseline (hooking IOMFB-internal fns may destabilize startup like the ctor hook).
    if (access("/tmp/macws_imfb_hook", F_OK) == 0) {
        intptr_t isl = macws_imfb_slide();
        if (isl) {
            void *s7 = (void *)((uintptr_t)UNSLID_imfb_createmode + isl);
            MSHookFunction(s7, (void *)macws_hook_imfb_cm, (void **)&orig_imfb_cm);
            void *s8 = (void *)((uintptr_t)UNSLID_imfb_createmode2 + isl);
            MSHookFunction(s8, (void *)macws_hook_imfb_cm2, (void **)&orig_imfb_cm2);
            fprintf(stderr, "#### MODESET imfb hooks @%p/%p imfb_slide=%#lx\n", s7, s8, (long)isl);
        } else {
            fprintf(stderr, "#### MODESET imfb hooks SKIP (IOMFB image not found yet)\n");
        }
    }
}

static void install_skylight_prepare_for_use_tolerate_nil_hook(const void *header) {
    MSImageRef sl = MSGetImageByName(SkyLightPath);
    if (!sl) {
        fprintf(stderr, "#### SkyLight tolerate-nil hooks: image not loadable, skipped\n");
        return;
    }
    void *sym1 = MSFindSymbol(sl,
        "__ZN21MetalIOSurfaceBacking13PrepareForUseEP12MetalContexty");
    if (sym1) {
        MSHookFunction(sym1, (void *)hooked_skylight_prepare_for_use,
                       (void **)&orig_skylight_prepare_for_use);
        fprintf(stderr, "#### SkyLight PrepareForUse tolerate-nil hook installed at %p\n", sym1);
        // WS-side window-backing diag (RE 2026-06-23): hook by computed slide off
        // sym1 (PrepareForUse @ unslid 0x185404fcc). ⚠️ DISABLED BY DEFAULT — the
        // offsets came from an agent RE of an off-version SkyLight.bndb (likely NOT
        // on-device 13.4), so these computed addresses are WRONG and crash WS (a
        // WS .ips was produced when they were installed). Gated behind a SEPARATE
        // file (/tmp/macws_ws_diag2) so the normal diag gate (/tmp/macws_ws_diag)
        // stays safe. DO NOT enable until the offsets are re-derived from the
        // on-device 13.4 SkyLight (the agx-re/ bndb is the wrong version).
        // ── 2026-06-23 FIX: force CA-flatten (sWSCAFlattenAlways=1) ──
        // RE-confirmed root cause (NOT GPU): in a -virtualonly chroot WS,
        // _WSWindowOrSurfaceMustFlatten@0x18521b9a8 returns 0 (no real/HiDPI display +
        // under-established session) so the FIRST CA-flatten never runs → window+0x838
        // (the flattened-content surface generate_layers' content gate reads) is never
        // produced → client app windows never composite. Set sWSCAFlattenAlways
        // (SkyLight __DATA @0x1d8bcc830) = 1 — the real Apple policy flag (official setter
        // _WSFlatteningSetDebugOptions(0x80000083) case sets Never=0,Always=1) that forces
        // the flatten path: makes _WSWindowOrSurfaceMustFlatten return 1 AND
        // UpdateFlatteningIfNeeded reach the Flatten@0x1852e69b4 BL (@0x1852e68cc).
        // This is a shipped WS policy switch, not a NOP/ret/assert-bypass. Gated
        // /tmp/macws_flatten_always for A/B; promote to default-on once verified.
        if (access("/tmp/macws_flatten_always", F_OK) == 0) {
            volatile uint8_t *fa = (volatile uint8_t *)(0x1d8bcc830 + ((uintptr_t)header - 0x1850E5000));
            uint8_t before = *fa;
            *fa = 1;
            fprintf(stderr, "#### MACWS_FLATTEN_ALWAYS sWSCAFlattenAlways @%p: %d -> %d\n",
                    (void *)fa, before, *fa);
        }
        // ── DEST-IOSURF (2a): resolve SkyLight's targetable-IOSurface helper ──
        // _WSIOSurfaceCreateTargetableWithFormatAndProtection@0x1853b9d9c
        //   (int w, int h, int format[4='BGRA'], uint64_t protection, const char *label)
        // builds an IOSurface with the kernel metadata AGX needs for a GPU-render
        // target (what the working source/capture path uses) — our plain IOSurfaceCreate
        // lacks it. Store the RAW (unsigned) addr; make_iosurf_dest PAC-signs + calls it.
        if (access("/tmp/macws_dest_iosurf", F_OK) == 0) {
            extern void *g_ws_targetable_iosurf_raw;
            g_ws_targetable_iosurf_raw = (void *)(0x1853b9d9c + ((uintptr_t)header - 0x1850E5000));
            g_ws_wscd_iosurface_raw = (void *)(0x185437210 + ((uintptr_t)header - 0x1850E5000));
            fprintf(stderr, "#### DEST-IOSURF targetable helper @ %p ; WithIOSurface @ %p\n",
                    g_ws_targetable_iosurf_raw, g_ws_wscd_iosurface_raw);
        }
        // BYPASS-COMPRESSION (gated /tmp/macws_uncompress): MSHook the REAL
        // IOSurfaceCreate (dlsym — NOT the DYLD_INTERPOSE'd symbol) so SkyLight's
        // intra-shared-cache DIRECT-bind composite-dest creation is caught and
        // rewritten to BGRA8 LINEAR (uncompressed). Then the AGX composite renders
        // the logo as plain pixels — no compression to decode.
        if (access("/tmp/macws_uncompress", F_OK) == 0 && !orig_IOSurfaceCreate_ms) {
            // Get the REAL IOSurfaceCreate from IOSurface.framework — NOT dlsym, which
            // returns libmachook's DYLD_INTERPOSE'd IOSurfaceCreate_safe (a low libmachook
            // addr); hooking THAT recursed + killed WS and never reached the composite.
            void *iosc = NULL;
            // Walk loaded images to find IOSurface, then dlsym ITS OWN handle for the
            // REAL IOSurfaceCreate (dlsym(RTLD_DEFAULT) returns libmachook's interpose;
            // MSGetImageByName(path) failed — shared-cache install name differs).
            for (uint32_t ii = 0; ii < _dyld_image_count(); ii++) {
                const char *nm = _dyld_get_image_name(ii);
                if (nm && strstr(nm, "IOSurface")) {
                    void *hh = dlopen(nm, RTLD_NOLOAD | RTLD_LAZY);
                    void *s = hh ? dlsym(hh, "IOSurfaceCreate") : NULL;
                    if (s) { iosc = s; fprintf(stderr, "#### UNCOMPRESS: real IOSurfaceCreate %p in %s\n", s, nm); break; }
                }
            }
            if (iosc) {
                MSHookFunction(iosc, (void *)hooked_IOSurfaceCreate, (void **)&orig_IOSurfaceCreate_ms);
                fprintf(stderr, "#### UNCOMPRESS: MSHook REAL IOSurfaceCreate @ %p installed (orig=%p)\n",
                        iosc, (void *)orig_IOSurfaceCreate_ms);
            } else {
                fprintf(stderr, "#### UNCOMPRESS: real IOSurfaceCreate not found in loaded images\n");
            }
            // Also hook SkyLight's targetable-surface creator — the '&b38' composite dest
            // is created there, NOT via the public IOSurfaceCreate (RING/CALL-confirmed).
            if (!orig_ws_targetable) {
                void *tgt = (void *)(0x1853b9d9c + ((uintptr_t)header - 0x1850E5000));
                MSHookFunction(tgt, (void *)hooked_ws_targetable, (void **)&orig_ws_targetable);
                fprintf(stderr, "#### UNCOMPRESS: MSHook _WSIOSurfaceCreateTargetable @ %p (orig=%p)\n",
                        tgt, (void *)orig_ws_targetable);
            }
        }
        if (access("/tmp/macws_ws_diag2", F_OK) == 0) {
            // CLEAN slide off the image header (NOT sym1 — sym1 is PAC-signed and
            // carried a wrong signature onto the computed addrs → MSHookFunction
            // crash). header = runtime SkyLight base; unslid __TEXT base verified
            // 0x1850E5000 (dd of on-device Cryptex cache; all 4 offsets are clean
            // function prologues).
            uintptr_t sl_slide = (uintptr_t)header - 0x1850E5000;
            void *fl = (void *)(0x1852e69b4 + sl_slide);
            MSHookFunction(fl, (void *)hooked_wcb_flatten, (void **)&orig_wcb_flatten);
            void *fv = (void *)(0x185320d98 + sl_slide);
            MSHookFunction(fv, (void *)hooked_flat_valid, (void **)&orig_flat_valid);
            void *gl = (void *)(0x185382d48 + sl_slide);
            MSHookFunction(gl, (void *)hooked_gen_layers, (void **)&orig_gen_layers);
            void *ud = (void *)(0x185379848 + sl_slide);
            MSHookFunction(ud, (void *)hooked_upd_disp, (void **)&orig_upd_disp);
            void *vl = (void *)(0x185104420 + sl_slide);
            MSHookFunction(vl, (void *)hooked_vis_list, (void **)&orig_vis_list);
            // content-receipt chain (RE-verified prologues @on-version __TEXT)
            void *blc = (void *)(0x18543bf20 + sl_slide);
            MSHookFunction(blc, (void *)hooked_bind_layer_ctx, (void **)&orig_bind_layer_ctx);
            void *cpc = (void *)(0x18543c080 + sl_slide);
            MSHookFunction(cpc, (void *)hooked_ctx_payload, (void **)&orig_ctx_payload);
            void *bsf = (void *)(0x1853a9274 + sl_slide);
            MSHookFunction(bsf, (void *)hooked_bind_surface, (void **)&orig_bind_surface);
            void *pca = (void *)(0x1853809e4 + sl_slide);
            MSHookFunction(pca, (void *)hooked_prep_ca, (void **)&orig_prep_ca);
            void *uf = (void *)(0x1852e66ec + sl_slide);
            MSHookFunction(uf, (void *)hooked_upd_flat, (void **)&orig_upd_flat);
            void *pfc = (void *)(0x1852e87d0 + sl_slide);
            MSHookFunction(pfc, (void *)hooked_popfc, (void **)&orig_popfc);
            // will_composite hook is a tiny tail-call fn — hooking it relocates the
            // tail-call to IsFlattenedCopyValid and bypasses that hook. Gate it so we can
            // run WITHOUT it (so the unmodified tail-call cleanly fires the fv hook).
            if (access("/tmp/macws_hook_wcomp", F_OK) == 0) {
                void *wcm = (void *)(0x18538e6a4 + sl_slide);
                MSHookFunction(wcm, (void *)hooked_wcomp, (void **)&orig_wcomp);
            }
            void *gfmb = (void *)(0x185320c9c + sl_slide);
            MSHookFunction(gfmb, (void *)hooked_gfmb, (void **)&orig_gfmb);
            // flatten-render validity chain (Step-0 diagnostic)
            void *wlbf = (void *)(0x18531c654 + sl_slide);
            MSHookFunction(wlbf, (void *)hooked_wlb_flatten, (void **)&orig_wlb_flatten);
            void *cmb = (void *)(0x1853f6f6c + sl_slide);
            MSHookFunction(cmb, (void *)hooked_cmb, (void **)&orig_cmb);
            void *csmp = (void *)(0x1853f6e54 + sl_slide);
            MSHookFunction(csmp, (void *)hooked_csmpop, (void **)&orig_csmpop);
            void *cltd = (void *)(0x185411dc4 + sl_slide);
            MSHookFunction(cltd, (void *)hooked_cltd, (void **)&orig_cltd);
            void *cca = (void *)(0x185176a14 + sl_slide);   // _MetalCompositeCoreAnimation (Route A live CA re-render)
            MSHookFunction(cca, (void *)hooked_cca, (void **)&orig_cca);
            g_cca_base = cca; g_cca_end = (void *)((char *)cca + 0x2000);   // for the IOSurfaceGetPixelFormat caller filter
            fprintf(stderr, "#### WS_DIAG2 hooks installed (header-based, verified offsets): slide=%#lx fl=%p gl=%p ud=%p cca=%p\n",
                    sl_slide, fl, gl, ud, cca);
        }
    } else {
        fprintf(stderr, "#### SkyLight PrepareForUse: symbol not found, skipped\n");
    }
    void *sym2 = MSFindSymbol(sl,
        "__ZN12MetalContext30StartCompositeForDisplayStreamEPU21objcproto10MTLTexture11objc_objectS1_13MTLLoadAction14MTLStoreAction");
    if (sym2) {
        MSHookFunction(sym2, (void *)hooked_skylight_start_composite_ds,
                       (void **)&orig_skylight_start_composite_ds);
        fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream nil-skip hook installed at %p\n", sym2);
    } else {
        fprintf(stderr, "#### SkyLight StartCompositeForDisplayStream: symbol not found, skipped\n");
    }
    // 2026-06-20 — MetalContext::StartComposite(WSCompositeDestination*,
    // MTLLoadAction, MTLStoreAction) — hook installed below. Helper
    // function definitions are at top-level (see above this function).
    extern void *orig_skylight_start_composite_wscd_ref;
    void *sym_sc_wscd = MSFindSymbol(sl,
        "__ZN12MetalContext14StartCompositeEP22WSCompositeDestination13MTLLoadAction14MTLStoreAction");
    if (sym_sc_wscd) {
        extern int hooked_skylight_start_composite_wscd(void *, void *,
                                                        unsigned long,
                                                        unsigned long);
        MSHookFunction(sym_sc_wscd,
            (void *)hooked_skylight_start_composite_wscd,
            (void **)&orig_skylight_start_composite_wscd_ref);
        fprintf(stderr,
            "#### SkyLight StartComposite(WSCD) tolerate-nil + pop-on-bail hook installed at %p\n",
            sym_sc_wscd);
    } else {
        fprintf(stderr,
            "#### SkyLight StartComposite(WSCD): symbol not found\n");
    }

    // 2026-06-20 — StartComposite(MTLTexture*, …) hook (the variant
    // called from SLCADisplay::render_update). Same pop-on-bail invariant
    // restorer logic as WSCD — when %orig returns 0 after pushing onto
    // _state_stack, restore the invariant the caller assumes (rv==0
    // ⟹ no push).
    void *sym_sc_mtltex = MSFindSymbol(sl,
        "__ZN12MetalContext14StartCompositeEPU21objcproto10MTLTexture"
        "11objc_object13MTLLoadAction14MTLStoreAction");
    if (sym_sc_mtltex) {
        MSHookFunction(sym_sc_mtltex,
            (void *)hooked_skylight_start_composite_mtltex,
            (void **)&orig_skylight_start_composite_mtltex);
        fprintf(stderr,
            "#### SkyLight StartComposite(MTLTex) pop-on-bail hook installed at %p\n",
            sym_sc_mtltex);
    } else {
        fprintf(stderr,
            "#### SkyLight StartComposite(MTLTex): symbol not found\n");
    }

    // 2026-06-20 — _state_stack pop_back resolution. MetalContext starts
    // with std::deque<RenderState>, so passing MetalContext* == passing
    // deque*. Required by `macws_pop_on_startcomp_bail` above.
    void *sym_pop = MSFindSymbol(sl,
        "__ZNSt3__15dequeI11RenderStateNS_9allocatorIS1_EEE8pop_backEv");
    if (sym_pop) {
        orig_skylight_state_stack_pop_back = (StateStack_pop_back_t)sym_pop;
        fprintf(stderr,
            "#### SkyLight _state_stack pop_back resolved at %p\n", sym_pop);
    } else {
        fprintf(stderr,
            "#### SkyLight _state_stack pop_back: symbol not found — "
            "pop-on-bail will NO-OP, expect Unbalanced Composites asserts\n");
    }

    void *sym3 = MSFindSymbol(sl, "_WSCompositeDestinationCreateWithMetalTexture");
    if (sym3) {
        MSHookFunction(sym3, (void *)hooked_skylight_wsccd_with_tex,
                       (void **)&orig_skylight_wsccd_with_tex);
        fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture nil-tolerate hook installed at %p\n", sym3);
    } else {
        fprintf(stderr, "#### SkyLight WSCompositeDestinationCreateWithMetalTexture: symbol not found, skipped\n");
    }

    // MetalContext::StopCapture() — called from render_update when the GPU
    // capture-in-progress flag is set. Under AGX-native the WS::Updater
    // sometimes invokes this with an invalid `this` (observed x0 = 0x95 on
    // the crashing thread), which then SEGVs on `ldr x0, [x0, #0xb8]` at
    // StopCapture+0x38. We don't actually want any GPU-capture work
    // happening during the AGX-native bring-up, so just no-op the call
    // when this looks invalid (< 0x1000 = unmapped low-address page).
    void *sym4 = MSFindSymbol(sl, "__ZN12MetalContext11StopCaptureEv");
    if (sym4) {
        MSHookFunction(sym4, (void *)hooked_metalcontext_stop_capture,
                       (void **)&orig_metalcontext_stop_capture);
        fprintf(stderr, "#### SkyLight MetalContext::StopCapture invalid-this guard installed at %p\n", sym4);
    } else {
        fprintf(stderr, "#### SkyLight MetalContext::StopCapture: symbol not found, skipped\n");
    }
}

// ─── Deterministic guard for the backdrop-blur layout=3 NULL-backing WS crash ───
// Gated /tmp/macws_wr3_guard or MACWS_WR3_GUARD. See
// [[ws-connection-crash-is-backdrop-blur-layout3]]. RE-confirmed (fresh .ips):
//   EXC_BAD_ACCESS write@0x0  _platform_memmove <- AGX::Texture<3>::writeRegion
//   <- -[AGXG13GFamilyTexture replaceRegion:] <- -[IOGPUMetalTexture replaceRegion:]
//   <- CA::OGL::MetalContext::create_texture <- ... <- visit_subclass(BackdropLayer).
// CA::OGL (software-Metal) uploads a layout=3 blur texture via replaceRegion, but the
// chroot-synth texture's CPU backing (this->0xa0) is NULL → writeRegion memmoves to NULL.
// ObjC-swizzle hooks of replaceRegion fire NON-deterministically here (double libmachook
// arm64+arm64e + CA::OGL multithread); an MSHookFunction PROLOGUE patch on writeRegion is
// deterministic (catches the direct C++ call). When this->0xa0 is NULL the write would
// fault, so skip it: the texture stays uninitialized (empty/garbage blur — a separate
// fidelity wall) but WS SURVIVES, which stops the restart-loop that re-floods the DCP →
// panic. writeRegion(this, uint×9, void* src, ulong, ulong) per mangled ...EjjjjjjjjjPvmm.
typedef void (*macws_wr3_t)(void *thiz, uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,
                            uint32_t,uint32_t,uint32_t,uint32_t, void *, uint64_t, uint64_t);
static macws_wr3_t macws_orig_wr3 = NULL;

static void macws_wr3_logline(const char *path, int trunc, const char *line) {
    int fl = O_WRONLY | O_CREAT | (trunc ? O_TRUNC : O_APPEND);
    int fd = open(path, fl, 0644);
    if (fd >= 0) { write(fd, line, strlen(line)); close(fd); }
}

// ─── ROOT-CAUSE diagnostic + S1 fix for the layout=3 backdrop-blur memmove(NULL) ───
// RE-confirmed (AGXMetal13_3 getCPUPtr@0x1e576fb74 disasm) the dst getCPUPtr returns is
// `*(this+0x130) + delta`; runtime-confirmed (WindowServer-2026-06-21-175127.ips:
// x21(dst)=0, x24(this)=0x147050d10, offset terms 0) that this->0x130 == 0 for the
// crashing texture. The CPU base 0x130 is set by the lazy binder @0x1e56de1e4 from
// `(this->0x10 /*resource*/)->0x218`, and that binder bails (leaving 0x130=0) if the
// cross-image prepare-call @0x1e5a5d4c0 fails. The earlier WR3-GUARD checked 0xa0
// (always non-NULL → inert). This rewrite checks the RIGHT field (0x130) and, when it
// is NULL, recovers the CPU base from the resource (mirroring the binder's success
// store, NO abort risk) — distinguishing S1 (resource->0x218 valid, binder just didn't
// run → fixable here) from S2 (resource->0x218 also 0 → resource itself unmapped).
static void macws_my_wr3(void *thiz, uint32_t a0,uint32_t a1,uint32_t a2,uint32_t a3,uint32_t a4,
                         uint32_t a5,uint32_t a6,uint32_t a7,uint32_t a8, void *src, uint64_t j, uint64_t k) {
    uint64_t cpubase = 0, res = 0, res218 = 0, a0field = 0;
    uint8_t  layout = 0xff;
    if (macws_ptr_ok((uint64_t)thiz)) {
        cpubase = *(volatile uint64_t *)((char *)thiz + 0x130);
        res     = *(volatile uint64_t *)((char *)thiz + 0x10);
        a0field = *(volatile uint64_t *)((char *)thiz + 0xa0);  // = the IOSurface (WSCDARG-confirmed)
        layout  = *(volatile uint8_t  *)((char *)thiz + 0x184);
        if (macws_ptr_ok(res)) res218 = *(volatile uint64_t *)((char *)res + 0x218);
    }

    static _Atomic int wn = 0;
    int n = atomic_fetch_add(&wn, 1);
    char line[320];
    snprintf(line, sizeof line,
        "WR3 #%d thiz=%p layout=%u 0x130=%#llx 0xa0=%#llx res=%#llx res218=%#llx src=%p len=%llu,%llu\n",
        n, thiz, (unsigned)(layout & 0xff),
        (unsigned long long)cpubase, (unsigned long long)a0field,
        (unsigned long long)res, (unsigned long long)res218, src,
        (unsigned long long)j, (unsigned long long)k);
    if (n < 80) macws_wr3_logline("/tmp/macws_wr3.log", 0, line);
    macws_wr3_logline("/tmp/macws_wr3_last", 1, line);

    if (cpubase == 0) {
        if (!access("/tmp/macws_wr3_diagonly", F_OK)) return;  // diag-only: skip, survive
        // PRINCIPLED FIX (gated /tmp/macws_wr3_iosfix): the texture references its IOSurface
        // at _impl+0xa0 (WSCDARG-confirmed: impl+0xa0 == [tex iosurface]) but the chroot AGX
        // init never wired the CPU base _impl+0x130 from it. Set 0x130 = IOSurfaceGetBaseAddress
        // (0xa0) so getCPUPtr returns an address INSIDE the IOSurface → writeRegion uploads into
        // the IOSurface (which the GPU then samples / VNC reads), instead of memmove(NULL).
        if (access("/tmp/macws_wr3_iosfix", F_OK) == 0 && macws_ptr_ok(a0field) &&
            CFGetTypeID((CFTypeRef)a0field) == IOSurfaceGetTypeID()) {
            uint64_t iosbase = (uint64_t)IOSurfaceGetBaseAddress((IOSurfaceRef)a0field);
            if (macws_ptr_ok(iosbase)) {
                *(volatile uint64_t *)((char *)thiz + 0x130) = iosbase;
                char f[160];
                snprintf(f, sizeof f, "WR3-FIX-IOS #%d set 0x130 = IOSurfaceGetBaseAddress(0xa0)=%#llx\n",
                         n, (unsigned long long)iosbase);
                macws_wr3_logline("/tmp/macws_wr3.log", 0, f);
                macws_orig_wr3(thiz, a0,a1,a2,a3,a4,a5,a6,a7,a8, src, j, k);
                return;
            }
        }
        if (macws_ptr_ok(res218)) {  // fallback: resource CPU base (binder's source)
            *(volatile uint64_t *)((char *)thiz + 0x130) = res218;
        } else {
            char f[160];
            snprintf(f, sizeof f, "WR3-SKIP #%d cpubase=0 0xa0=%#llx res218=%#llx\n",
                     n, (unsigned long long)a0field, (unsigned long long)res218);
            macws_wr3_logline("/tmp/macws_wr3.log", 0, f);
            return;  // survive (skip upload)
        }
    }
    macws_orig_wr3(thiz, a0,a1,a2,a3,a4,a5,a6,a7,a8, src, j, k);
}
static void macws_install_wr3_guard(void *fn) {
    static int done = 0; if (done) return; done = 1;
    extern void MSHookFunction(void *, void *, void **);
    MSHookFunction(fn, (void *)macws_my_wr3, (void **)&macws_orig_wr3);
    fprintf(stderr, "#### WR3-GUARD installed @ %p (orig=%p)\n", fn, (void *)macws_orig_wr3);
}

// ─── REAL-BLUR FIX: cache-proof IOSurface routing for CA::OGL blur textures ───
// (gated /tmp/macws_blur_route or MACWS_BLUR_ROUTE). RE-confirmed
// [[ws-connection-crash-is-backdrop-blur-layout3]]: CA::OGL caches the device's
// newTextureWithDescriptor: IMP for its render hot-path, BYPASSING the ObjC swizzle →
// the backdrop-blur layout=3 texture is created native (NO GPU-coherent backing) →
// getCPUPtr's address translation returns 0 → writeRegion memmove(NULL) → WS crash →
// restart → DCP re-flood. FIX: MSHookFunction the ORIGINAL AGXG13GFamilyDevice
// -[newTextureWithDescriptor:] IMP (unslid 0x1e574d5ec; a prologue patch catches the
// cached-IMP callers — proven to work on AGXMetal13_3 via macws_my_wr3) and re-dispatch
// via objc_msgSend to the swizzled IOSurface routing (hooked_newTextureWithDescriptor:),
// which builds a layout=0 IOSurface-backed GPU-coherent texture (proven for the 32x32).
// The routing's native fallback `[self hooked_newTextureWithDescriptor:]` resolves (via
// swizzle2's method exchange) back to this MSHook'd original; a __thread guard sends that
// re-entry to the real orig. Net: blur textures become GPU-coherent → getCPUPtr maps them
// → writeRegion writes + GPU samples → real blur, AND no crash/restart.
typedef id (*macws_newtex_t)(id, SEL, id);
static macws_newtex_t macws_orig_newtex = NULL;
static SEL macws_newtex_sel = NULL;
static __thread int macws_in_newtex = 0;
static id macws_my_newtex(id self, SEL _cmd, id desc) {
    if (macws_in_newtex)
        return macws_orig_newtex(self, _cmd, desc);   // re-entrant (routing's native fallback) → real AGX
    macws_in_newtex = 1;
    id r = ((id (*)(id, SEL, id))objc_msgSend)(self, macws_newtex_sel, desc);  // → swizzled IOSurface routing
    macws_in_newtex = 0;
    static int n = 0; if (n++ < 8) {
        fprintf(stderr, "#### BLUR-ROUTE redispatched newTex -> %p cls=%s\n",
                (void *)r, r ? object_getClassName(r) : "nil");
        fflush(stderr);
    }
    return r;
}
static void macws_install_blur_route(void *imp) {
    static int done = 0; if (done) return; done = 1;
    macws_newtex_sel = sel_registerName("newTextureWithDescriptor:");
    // MSHookFunction silently fails to stick on the dlopen'd (DSC-extracted) AGXMetal13_3
    // unless the target page is first made private-writable (VM_PROT_COPY resolved) by a
    // real write — confirmed: the writeRegion MSHook only took because the byte-patch had
    // COW'd writeRegion's page. newTextureWithDescriptor is on a different page, so force
    // a CoW resolve here (rewrite the first instruction to itself) before hooking.
    ModifyExecutableRegion(imp, 16, ^{
        volatile uint32_t *p = (uint32_t *)imp; uint32_t v = p[0]; p[0] = v;
    });
    extern void MSHookFunction(void *, void *, void **);
    MSHookFunction(imp, (void *)macws_my_newtex, (void **)&macws_orig_newtex);
    fprintf(stderr, "#### BLUR-ROUTE installed on AGX -[newTextureWithDescriptor:] @ %p (orig=%p)\n",
            imp, (void *)macws_orig_newtex);
}

// Gated /tmp/macws_status_skip: disable the SystemStatus status-DOMAIN re-registration
// that crashes WS in the chroot. RE-confirmed crash (WindowServer-2026-06-21-231156.ips):
// EXC_BAD_ACCESS cache_getImp ← _NSIsNSNumber ← -[NSXPCEncoder _encodeObject:] ← ... ←
// -[STStatusDomainXPCServerHandle _reregisterForDomains]_block_invoke_3 — i.e. NSXPC encodes
// a status-domain object with a bad isa in the chroot. Status domains (Control Center / menu-bar
// status items) are NOT a rendering path; like the project's sandbox/audit-token stubs, this
// disables an iOS-incompatible subsystem so WS survives a client connect. One-shot; retries each
// image load until the class is present.
// Default-ON in the AGX-native goal: the SystemStatus status-domain
// re-registration is a non-rendering subsystem (system status-bar items;
// needs a real status daemon that doesn't exist in the chroot) and it
// crashes WS on a client connect — RE-confirmed crash-diag: BUS_ADRALN at
// objc_msgSend, the encoded object's isa = `_xpc_type_serializer` (libxpc),
// i.e. NSXPC's `-[NSXPCEncoder _encodeObject:]` ObjC-messages a raw XPC
// object during `-[STStatusDomainXPCServerHandle _reregisterForDomains]`.
// Disabling it (like the project's sandbox / audit-token / HID stubs) keeps
// WS alive through the GlassDemo connect. Opt-OUT with /tmp/macws_no_status_skip.
static void macws_status_skip_try(void) {
    static int done = 0; if (done) return;
    if (access("/tmp/macws_no_status_skip", F_OK) == 0) { done = 1; return; }
    Class c = objc_getClass("STStatusDomainXPCServerHandle");
    if (!c) return;  // SystemStatus not loaded yet — retry later
    // class_getInstanceMethod searches the class AND its superclasses, so it
    // finds `_reregisterForDomains` even though it isn't in the class's OWN
    // method list (the earlier class_copyMethodList attempt missed it for
    // exactly that reason). Returns NULL until the method is registered, so
    // we keep retrying.
    SEL sel = sel_registerName("_reregisterForDomains");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;  // not registered yet — retry later
    IMP noop = imp_implementationWithBlock(^void(id self) { (void)self; });
    method_setImplementation(m, noop);
    done = 1;
    fprintf(stderr, "#### MACWS status-skip: -[STStatusDomainXPCServerHandle "
        "_reregisterForDomains] -> no-op (NSXPC-encode-XPC-object crash avoided)\n");
}

// WindowServer-only: the SystemStatus _reregisterForDomains crash is a WS-side
// issue, and this is called from loadImageCallback (every image, EVERY process).
// Running it in client apps (e.g. GlassDemo) — especially the dispatch_after
// backstop scheduled during the FIRST add-image callback, before the client's
// libdispatch/main is ready — HANGS the client at load (runtime-confirmed
// 2026-06-22: GlassDemo hung in ctor with no output until this was gated). Gate
// to WindowServer so no status-skip code (and no dispatch_after) runs in clients.
static int macws_is_windowserver(void) {
    static int v = -1;
    if (v < 0) {
        char exe[PATH_MAX]; uint32_t n = sizeof(exe);
        v = (_NSGetExecutablePath(exe, &n) == 0 &&
             strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL) ? 1 : 0;
    }
    return v;
}

static void macws_install_status_skip(void) {
    if (!macws_is_windowserver()) return;  // WS-only; never run in client apps
    // Called from loadImageCallback (fires per dylib load during startup) so the
    // swizzle lands as soon as SystemStatus + its category are up. A one-shot
    // dispatch_after backstop guarantees it installs before the ~t+4s client
    // connect even if no image loads late in startup.
    macws_status_skip_try();
    static dispatch_once_t backstop_once;
    dispatch_once(&backstop_once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ macws_status_skip_try(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ macws_status_skip_try(); });
    });
}

// PANIC FIX (gated /tmp/macws_swap_cancel): recycle the per-frame DCP swap object
// WITHOUT scanning out to the physical panel. Coexist can't present (iOS owns the
// panel → purple flicker) but NOPing the present leaks the swap → DCP RTKit OOM
// panic. RE (agent, IOMobileFramebuffer): SwapBegin(sel4) caches the swap-id at
// conn+0x68; SwapEnd(sel5,StructMethod) presents+recycles; kern_SwapCancel(sel52,
// ScalarMethod, 1 scalar = swap-id) RELEASES the swap with NO scanout. So replace
// the present with a cancel → frees the DCP object (no leak/panic), never drives the
// panel (no flicker). sel52 kernel semantics are THEORY (AppleCLCD2 table stripped)
// → gated + A/B. conn+0x14 = IOMFB fd, conn+0x68 = swap-id (RE-confirmed).
extern kern_return_t IOConnectCallScalarMethod(mach_port_t, uint32_t, const uint64_t *,
                                               uint32_t, uint64_t *, uint32_t *);
typedef int (*kern_SwapEnd_t)(void *conn);
static kern_SwapEnd_t orig_kern_SwapEnd = NULL;
static int hooked_kern_SwapEnd(void *conn) {
    if (conn) {
        uint32_t fd = *(volatile uint32_t *)((char *)conn + 0x14);
        uint32_t swapid = *(volatile uint32_t *)((char *)conn + 0x68);
        uint64_t sid = swapid;
        kern_return_t r = IOConnectCallScalarMethod(fd, 52, &sid, 1, NULL, NULL);
        static _Atomic int n = 0; int k = atomic_fetch_add(&n, 1);
        if (k < 5 || (k % 600) == 0)
            fprintf(stderr, "#### SWAP-CANCEL #%d fd=%u swapid=%u sel52 r=0x%x (recycle, no present)\n",
                    k, fd, swapid, (int)r);
        return 0;   /* KERN_SUCCESS — swap freed, no panel present */
    }
    return orig_kern_SwapEnd ? orig_kern_SwapEnd(conn) : 0;
}

void loadImageCallback(const struct mach_header* header, intptr_t vmaddr_slide) {
    Dl_info info;
    dladdr(header, &info);
    macws_install_status_skip();  // gated /tmp/macws_status_skip
    if(!strncmp(info.dli_fname, SkyLightPath, strlen(SkyLightPath))) {
        // allow coexist with backboardd in WS::Displays::CAWSManager::CAWSManager() + 560
        // if backboardd is running, WindowServer switches to offscreen rendering
        uint32_t *check = (uint32_t *)(OFF_SkyLight_CAWSManager_register_abort + (uintptr_t)header);
        ModifyExecutableRegion(check, sizeof(uint32_t), ^{
            // TODO: has hardcoded instruction
            // NSLog(@"#### debugbydcmmc OFF_SkyLight_CAWSManager_register_abort ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) check, (unsigned long) *check, (unsigned long) 0xb4000588);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching SkyLight version/arch.
            if (*check == 0xb4000588) { // cbz    x8, do_abort
                *check = 0xd503201f; // nop
            }
        });

        // 2026-06-21 — USER DIRECTION: use CA::Render (Metal) path, NEVER CARenderOGLRender.
        // MetalCompositeCoreAnimation (SkyLight+0x920ac) selects the renderer:
        //   +0x9208c ldrh w8,[x20,#0x52]; tst w8,#0x240
        //   +0x9209c b.eq +0x920b0   ; (flags&0x240)==0 → Metal vtable renderer (blraaz x8 @ +0x920d0)
        //   +0x920a8 bl CARenderOGLRender  ; else → OGL (crashes: layout-3 create_texture memmove NULL)
        // Backdrop/filter layers set flags&0x240 → OGL → crash. Force b.eq unconditional so
        // ALL layers use the Metal vtable renderer the majority already use; never OGL.
        // NULL-guarded by the function's own `cbz x8` at +0x920c8. Witness = VNC shows the
        // window rendering (not just survival). Gated /tmp/macws_no_ogl or MACWS_NO_OGL.
        if (getenv("MACWS_NO_OGL") || access("/tmp/macws_no_ogl", F_OK) == 0) {
            uint32_t *sel = (uint32_t *)((uintptr_t)header + 0x9209c);
            if (*sel == 0x540000a0u) {   // b.eq +0x920b0
                ModifyExecutableRegion(sel, sizeof(uint32_t), ^{ *sel = 0x14000005u; }); // b +0x920b0
                fprintf(stderr, "#### NO-OGL: MetalCompositeCoreAnimation b.eq->b @ %p (force Metal renderer, skip CARenderOGLRender)\n", (void *)sel);
            } else {
                fprintf(stderr, "#### NO-OGL: site %p = %#x != b.eq 0x540000a0 — abort patch\n", (void *)sel, *sel);
            }
        }

        // grant all permissions
        MSHookFunction(MSFindSymbol((MSImageRef)header, "_audit_token_check_tcc_access"), hooked_return_1, NULL);
            
        // NSLog(@"#### debugbydcmmc loadImageCallback before OFF_SkyLight_WSSystemCanCompositeWithMetal");
#if FORCE_SW_RENDER
        // skip Metal check (WSSystemCanCompositeWithMetal::once)
        int64_t *once = (int64_t *)(OFF_SkyLight_WSSystemCanCompositeWithMetal + (uintptr_t)header);
        *once = -1;
#endif

        // (Removed LAZY CAWSBackend.mm assert-NOP scanner — empirically
        // never fired in post-MACWS_AGX_REGISTER_CLASSES runs and was
        // masking real CA backend invariants. See AGENTS.md "Patch
        // Discipline".)

        // Tolerate-nil texture in MetalIOSurfaceBacking::PrepareForUse
        //
        // RE'd via live lldb on WS PID 4218: PrepareForUse calls
        // [device newTextureWithDescriptor:iosurface:plane:] at +340. If the
        // result is nil (cbz at +352 → +484), the function loads a flag from
        // MetalContext+0x1c0 (ldrb w8 at +484), and if w8 == 0 calls
        // MetalBacking::AbortWithTextureInfo at +512 — killing WS.
        //
        // SkyLight already ships a "tolerate-nil" code path at +492 (mov w0,#0;
        // ret 0) that fires when MetalContext+0x1c0 is non-zero. The hook here
        // sets that byte to 1 before %orig, so SkyLight's own fallback runs
        // instead of the abort. No instruction patching, no NOP cascade — we
        // just flip the flag SkyLight already checks.
        //
        // The CA Framebuffer 2388×1668 '&b38' compressed IOSurface returns nil
        // from MTLSim AND from AGXG13GFamilyDevice. Other surfaces (blur
        // scratchpads, normal app windows) wrap fine. Tolerating nil for the
        // specific failing surface keeps WS alive and lets blur scratchpad
        // textures (which DO succeed) run normally.
        install_skylight_prepare_for_use_tolerate_nil_hook((const void *)header);

        // (Removed LAZY render_update cbz/cbnz/assert-block retargets — 3
        // sites that flipped composite_destination-nil failures into
        // epilogue jumps. Never fired under MACWS_AGX_REGISTER_CLASSES;
        // even when AGX render targets fail, the upstream cause is the
        // ResCreate FAIL kernel rejection, not nil propagation through
        // render_update. See AGENTS.md "Patch Discipline".)
#if 0
        // Patch the `cbz x24, +0x660` at SkyLight 0x18525ec50 so that when
        // _WSCompositeDestinationCreateWithIOSurface (or its WithMetalTexture
        // inner call) returns NULL, render_update jumps STRAIGHT to its
        // epilogue at 0x18525f62c instead of falling into the assert block
        // at 0x18525f2b0. The assert block sets up arg strings and a `bl
        // sub_18547c20c` — we already NOP that BL via the CAWSBackend.mm
        // patcher, but the post-NOP code reads `[sp, #0x38]` which is an
        // uninitialized local var on the FAIL path (only the OK path writes
        // it earlier). x8 = 0x3ff... (NaN-shaped 1.0f from a prior d-reg
        // spill) then ldr x8, [x8, #0x10] faults.
        //
        // Re-targeting the cbz to the epilogue makes the FAIL path return
        // cleanly without touching sp+0x38. x0 = 0 from the failed
        // composite-destination call is harmless to the caller (UpdateDisplays
        // tolerates a 0 return — it just renders nothing for this frame).
        if (getenv("MACWS_KEEP_RENDER_UPDATE_CBZ")) {
            // LAZY (three sites): retargets cbz/cbnz/first-insn of
            // SkyLight's render_update assert block straight to its
            // epilogue. That kept WS alive when composite_destination
            // came back nil. Default off; the assert it dodges contains
            // the actual file/line of why composite_destination was nil,
            // which is what we need to see now. Opt-IN with
            // MACWS_KEEP_RENDER_UPDATE_CBZ=1.
            // Search for cbz x24 followed by an adrp+add+mov_w2+bl pattern
            // (the assert sequence). The cbz target is the assert block.
            const uint64_t expected_orig = 0xB4003318;  // cbz x24, +0x660
            const uint64_t expected_new  = 0xB4004EF8;  // cbz x24, +0x9DC
            uint64_t static_check_pc = 0x18525ec50;
            uint64_t sl_static_base  = 0x18523053c - 0; // anchor on the wsccd entry
            // Use the entry-symbol resolved address as the slide anchor.
            void *wsccd = MSFindSymbol((MSImageRef)header,
                "_WSCompositeDestinationCreateWithMetalTexture");
            if (wsccd) {
                // On arm64e MSFindSymbol returns a PAC-signed pointer.
                // Strip the auth bits before arithmetic so subsequent
                // pointer reads don't fault as `KERN_INVALID_ADDRESS at
                // 0xfc508001983dec50 (possible pointer authentication
                // failure)` when bash / other non-WS chroot processes
                // load SkyLight (e.g. via QuartzCore_hooks dlopen).
                uintptr_t wsccd_raw = ((uintptr_t)wsccd) & 0x0000007FFFFFFFFFULL;
                intptr_t slide_sl = (intptr_t)wsccd_raw - (intptr_t)sl_static_base;
                uint32_t *cbz_at = (uint32_t *)(static_check_pc + slide_sl);
                if (*cbz_at == expected_orig) {
                    ModifyExecutableRegion(cbz_at, sizeof(uint32_t), ^{
                        *cbz_at = (uint32_t)expected_new;
                    });
                    fprintf(stderr, "#### SkyLight render_update cbz retargeted to epilogue at %p\n",
                            cbz_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update cbz mismatch at %p (got %#x)\n",
                            cbz_at, *cbz_at);
                }

                // Second cbz at 0x18525f0a8: `cbz w0, 0x18525f2d0` — when
                // sub_18547aa0c returns 0 (rect-empty or similar), control
                // jumps DIRECTLY to the same `ldr x8, [sp,#0x38] / ldr x8,
                // [x8,#0x10]` crash sequence. Retarget the second cbz to the
                // epilogue too so this path also returns cleanly.
                const uint32_t orig2 = 0x34001140;  // cbz w0, +0x228
                const uint32_t new2  = 0x34002C20;  // cbz w0, +0x584
                uint32_t *cbz2_at = (uint32_t *)(0x18525f0a8 + slide_sl);
                if (*cbz2_at == orig2) {
                    ModifyExecutableRegion(cbz2_at, sizeof(uint32_t), ^{
                        *cbz2_at = new2;
                    });
                    fprintf(stderr, "#### SkyLight render_update second-cbz retargeted at %p\n",
                            cbz2_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update second-cbz mismatch at %p (got %#x)\n",
                            cbz2_at, *cbz2_at);
                }

                // THIRD entry to the assert/crash block: another
                // WithMetalTexture call at 0x18525f2a0 returns NULL → falls
                // through `cbnz x24, 0x18525ec54` at 0x18525f2ac into the
                // assert setup at 0x18525f2b0. The cleanest catch-all is to
                // overwrite the FIRST instruction of the assert block
                // (0x18525f2b0) with `b 0x18525f62c` (jump straight to
                // epilogue). This makes EVERY path into the assert block —
                // including the cbnz fall-through, cbz x24 jump (already
                // retargeted), and any future variants — exit render_update
                // cleanly instead of touching the post-NOP uninit-stack
                // sequence.
                //   imm26 = (0x18525f62c - 0x18525f2b0) / 4 = 0x37C/4 = 0xDF
                //   B encoding: 0x14000000 | imm26 = 0x140000DF
                const uint32_t orig3 = 0xb00012e0;  // adrp x0, 0x1854bc000
                const uint32_t new3  = 0x140000DF;  // b 0x18525f62c
                uint32_t *assert_block_at = (uint32_t *)(0x18525f2b0 + slide_sl);
                if (*assert_block_at == orig3) {
                    ModifyExecutableRegion(assert_block_at, sizeof(uint32_t), ^{
                        *assert_block_at = new3;
                    });
                    fprintf(stderr, "#### SkyLight render_update assert-block b-to-epilogue at %p\n",
                            assert_block_at);
                } else {
                    fprintf(stderr, "#### SkyLight render_update assert-block mismatch at %p (got %#x)\n",
                            assert_block_at, *assert_block_at);
                }
            }
        }
#endif

        // NSLog(@"#### debugbydcmmc loadImageCallback SkyLight modified");
    } else if(!strncmp(info.dli_fname, IOMFBPath, strlen(IOMFBPath))) {
        // patch kern_SwapEnd passing correct inputStructCnt
        uint32_t *swapEnd = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt + (uintptr_t)header);
        ModifyExecutableRegion(swapEnd, sizeof(uint32_t), ^{
            // NSLog(@"#### debugbydcmmc OFF_IOMobileFramebuffer_kern_SwapEnd_inputStructCnt ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) swapEnd, (unsigned long) *swapEnd, (unsigned long) 0x52808d03);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching IOMobileFramebuffer version/arch.  The
            // arm64 slice differs from arm64e, and CLI tools that merely pull
            // IOMFB in via libmachook's deps must not crash here.
            if (*swapEnd == 0x52808d03) { // mov    w3, #0x468
                *swapEnd = 0x52808d83; // mov    w3, #0x46c
            }
        });
        // NSLog(@"#### debugbydcmmc loadImageCallback IOMobileFramebuffer modified");

        // COEXISTENCE (flicker fix): in WindowServer only, when iOS's backboardd is running
        // (we're sharing the device with the iOS UI), neutralize kern_SwapEnd's panel present
        // so WS renders to its framebuffer (VNC reads it) but never scans out to the physical
        // iPad panel — iOS keeps the panel, eliminating the iOS/macOS flicker. When backboardd
        // is NOT running (the original "unload SpringBoard+backboardd, macOS takes the panel"
        // mode) the present is left intact. Auto-detecting backboardd makes this survive
        // reboots with no flag file; /tmp/ws_headless still force-enables it for testing.
        {
            char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
            if(_NSGetExecutablePath(exe, &exelen) == 0 &&
               strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL &&
               (is_process_running("backboardd") || access("/tmp/ws_headless", F_OK) == 0)) {
                // 2026-06-22 — the present-NOP is the DCP-panic REGRESSION: the
                // per-frame swap (SwapBegin/IOMFB sel74) allocates a DCP firmware
                // object that ONLY the panel-present (this sel=5 call) recycles;
                // NOPing it leaks one DCP object/frame → DCP RTKit heap OOM →
                // kernel panic (first seen 06-20, right after coexist auto-detect
                // 775e65d). /tmp/macws_present_recycle LETS THE PRESENT RUN so the
                // swap is recycled (no leak) — testing whether the backboardd
                // ownership conflict it was meant to avoid is actually fatal or
                // just cosmetic. Default (gate absent): keep the NOP (old behavior).
                // 2026-06-22 — DEFAULT = swap-cancel (THE panic fix, runtime-VALIDATED):
                // hook kern_SwapEnd → kern_SwapCancel(sel52) so the per-frame DCP swap
                // object is RELEASED (no leak → no DCP RTKit OOM panic) WITHOUT presenting
                // to the panel (no iOS purple flicker). Proven: 22k cancels r=0x0, WS
                // survived >4min coexist with ZERO DCP panic / reboot (vs reboot in ~90s
                // with the old present-NOP). Opt-outs for A/B: /tmp/macws_present_nop
                // (old NOP — LEAKS → panics) and /tmp/macws_present_recycle (present runs
                // → panel FLICKERS). Both are dead-ends kept only for comparison.
                if (access("/tmp/macws_present_recycle", F_OK) == 0) {
                    fprintf(stderr,
                        "#### COEXIST: present-recycle gate ON — present INTACT (FLICKERS, A/B only)\n");
                } else if (access("/tmp/macws_present_nop", F_OK) == 0) {
                    uint32_t *swapSubmit = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_submit + (uintptr_t)header);
                    ModifyExecutableRegion(swapSubmit, sizeof(uint32_t), ^{
                        if (*swapSubmit == 0x94001f64) { // bl IOConnectCallStructMethod (panel present)
                            *swapSubmit = 0xd2800000;    // mov x0, #0  (skip present)
                            fprintf(stderr,
                                "#### COEXIST: kern_SwapEnd panel-present NOPed (LEAKS→panics, A/B only)\n");
                        }
                    });
                } else {
                    // DEFAULT: recycle-without-scanout via SwapCancel(sel52).
                    void *swapEndFn = (void *)((uintptr_t)header + 0x4400);
                    MSHookFunction(swapEndFn, (void *)hooked_kern_SwapEnd,
                                   (void **)&orig_kern_SwapEnd);
                    fprintf(stderr,
                        "#### COEXIST: kern_SwapEnd → SwapCancel(sel52) recycle-without-scanout "
                        "@ %p (no leak, no flicker) [DEFAULT panic-fix]\n", swapEndFn);
                }
            }
        }
    } else if(!strncmp(info.dli_fname, libxpcPath, strlen(libxpcPath))) {
        // Register the bundled XPC services inside each framework. KEY here is
        // the FRAMEWORK BINARY path (not the .xpc bundle path) — _xpc_bootstrap_services
        // walks each framework, finds its XPCServices/ subdir, and registers every .xpc
        // inside. xpc_add_bundle (the .xpc-path variant) silently fails in this context;
        // _xpc_bootstrap_services is the working API.
        //
        // - Metal.framework → MTLCompilerService.xpc (existing, shader compile)
        // - ViewBridge.framework → ViewBridgeAuxiliary.xpc (NEW: AppKit window content
        //   render — without this, Terminal logs "Connection Invalid for
        //   com.apple.ViewBridgeAuxiliary" and window content never renders)
        // - HIServices.framework → com.apple.hiservices-xpcservice.xpc (NEW: AppKit's
        //   client-aux endpoint; previously: "Connection Invalid for
        //   com.apple.hiservices-xpcservice")
        xpc_object_t dict = (xpc_object_t)xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/Metal.framework/Metal", 2);
        // Framework binary path uses TLD symlink form (matches Metal pattern)
        xpc_dictionary_set_uint64(dict, "/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", 2);
        xpc_dictionary_set_uint64(dict, "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices", 2);
        void(*_xpc_bootstrap_services_fn)(xpc_object_t) = MSFindSymbol((MSImageRef)header, "__xpc_bootstrap_services");
        fprintf(stderr, "#### XPC_BOOTSTRAP: fn=%p dict=%p (registering Metal/ViewBridge/HIServices)\n",
            _xpc_bootstrap_services_fn, dict);
        if (_xpc_bootstrap_services_fn) {
            _xpc_bootstrap_services_fn(dict);
            fprintf(stderr, "#### XPC_BOOTSTRAP: called OK\n");
        } else {
            fprintf(stderr, "#### XPC_BOOTSTRAP: SYMBOL NOT FOUND\n");
        }
    } else if(!strncmp(info.dli_fname, MetalPath, strlen(MetalPath))) {
        // patch MTL*ReflectionReader::deserialize to match iOS
        // on macOS, there are extra instructions
        
        // 0x18ae78a34 <+956>:  mov    w9, #0x2                  ; =2
        // 0x18ae78a38 <+960>:  movk   w9, #0x1, lsl #16
        // 0x18ae78a3c <+964>:  cmp    w8, w9
        // 0x18ae78a40 <+968>:  b.lo   0x18ae78a8c               ; <+1044>
        // 0x18ae78a44 <+972>:  add    x0, sp, #0x68
        // 0x18ae78a48 <+976>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a4c <+980>:  add    x0, sp, #0x68
        // 0x18ae78a50 <+984>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a54 <+988>:  add    x0, sp, #0x68
        // 0x18ae78a58 <+992>:  bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a5c <+996>:  add    x0, sp, #0x68
        // 0x18ae78a60 <+1000>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a64 <+1004>: add    x0, sp, #0x68
        // 0x18ae78a68 <+1008>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae78a6c <+1012>: ldr    w8, [x20, #0x68]
        uint32_t *MTLInputStageReflectionReader_deserialize = (uint32_t *)(OFF_Metal_MTLInputStageReflectionReader_deserialize_extra + (uintptr_t)header);
        ModifyExecutableRegion(MTLInputStageReflectionReader_deserialize, sizeof(uint32_t[15]), ^{
            if (MTLInputStageReflectionReader_deserialize[0] == 0x52800049) { // mov w9, #0x2
                for(int i = 0; i < 15; ++i) {
                    MTLInputStageReflectionReader_deserialize[i] = 0xd503201f; // nop
                }
            }
        });
        
        // 0x18ae79028 <+364>: mov    w9, #0x2                  ; =2
        // 0x18ae7902c <+368>: movk   w9, #0x1, lsl #16
        // 0x18ae79030 <+372>: cmp    w8, w9
        // 0x18ae79034 <+376>: b.lo   0x18ae79080               ; <+452>
        // 0x18ae79038 <+380>: add    x0, sp, #0x8
        // 0x18ae7903c <+384>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79040 <+388>: add    x0, sp, #0x8
        // 0x18ae79044 <+392>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79048 <+396>: add    x0, sp, #0x8
        // 0x18ae7904c <+400>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79050 <+404>: add    x0, sp, #0x8
        // 0x18ae79054 <+408>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79058 <+412>: add    x0, sp, #0x8
        // 0x18ae7905c <+416>: bl     0x18ae0c0e0               ; DeserialContext::deserializeUint32()
        // 0x18ae79060 <+420>: ldr    w8, [x20, #0x68]
        uint32_t *MTLFragmentReflectionReader_deserialize = (uint32_t *)(OFF_Metal_MTLFragmentReflectionReader_deserialize_extra + (uintptr_t)header);
        ModifyExecutableRegion(MTLFragmentReflectionReader_deserialize, sizeof(uint32_t[15]), ^{
            if (MTLFragmentReflectionReader_deserialize[0] == 0x52800049) { // mov w9, #0x2
                for(int i = 0; i < 15; ++i) {
                    MTLFragmentReflectionReader_deserialize[i] = 0xd503201f; // nop
                }
            }
        });

        // 2026-06-19 — MallocScribble surfaced the real upstream bug:
        // -[AGXTexture initWithDevice:desc:isSuballocDisabled:] at static
        // 0x1e5a5b7d4 calls `_objc_msgSend$validateWithDevice:` on the
        // MTLTextureDescriptor; descriptor doesn't implement that selector
        // in chroot → forwarding raises doesNotRecognizeSelector exception
        // → uncaught → SIGTRAP. Add the selector as a class method
        // returning YES on MTLTextureDescriptor (and any subclass), so the
        // AGXTexture init's cbz w0 check (at 0x1e5a5b7d8) passes and the
        // init proceeds.
        if (getenv("MACWS_AGX_NATIVE")) {
            Class kDesc = objc_getClass("MTLTextureDescriptor");
            if (kDesc) {
                SEL valSel = sel_registerName("validateWithDevice:");
                if (!class_getInstanceMethod(kDesc, valSel)) {
                    IMP validStub = imp_implementationWithBlock(^BOOL(id self, id device) {
                        (void)self; (void)device;
                        return YES;
                    });
                    BOOL ok = class_addMethod(kDesc, valSel,
                                              validStub, "c@:@");
                    fprintf(stderr,
                        "#### MACWS_AGX_NATIVE class_addMethod(MTLTextureDescriptor, validateWithDevice:) = %d\n",
                        ok);
                } else {
                    fprintf(stderr,
                        "#### MACWS_AGX_NATIVE MTLTextureDescriptor already responds to validateWithDevice:\n");
                }
            } else {
                fprintf(stderr,
                    "#### MACWS_AGX_NATIVE objc_getClass(MTLTextureDescriptor) = nil\n");
            }
            // 2026-06-20 (lldb-confirmed) — AGXTexture init at static
            // 0x1e5a5b9cc calls `_objc_msgSend$isMemoryless` on the
            // result of super-init (x19 = IOGPUMetalTexture instance).
            // For our synth AGXG13GFamilyBuffer-as-texture this method
            // doesn't exist → forwarding → SIGTRAP. Add isMemoryless
            // returning NO (IOSurface-backed = real memory, not memoryless)
            // on IOGPUMetalTexture (the super class that AGXTexture
            // queries) AND on AGXG13GFamilyBuffer (the synth that gets
            // returned from CODEHEAP-SHIM).
            // 2026-06-20 — Full cascade RE'd via otool on AGXTexture init.
            // Selectors AGXTexture init sends that need to resolve on the
            // synth buffer / chroot descriptor / texture:
            //   validateWithDevice:   (descriptor) [already added above]
            //   isMemoryless          (super-init result texture)
            //   protectionOptions     (descriptor)
            //   getCPUSizeBytes       (descriptor or buffer)
            //   getAlignment          (descriptor)
            //   descriptorPrivate     (descriptor)
            //   getBytesPerRow        (descriptor)
            //   finalizeTextureCreation (self) [already added on AGXG13GFamilyBuffer]
            //   updateBindDataWithAddresses:gpuVirtualAddress:
            //   updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:
            //   allocBufferSubDataWithLength:options:alignment:heapIndex:bufferIndex:bufferOffset:
            //   initNewTextureData:
            //   initImplWithDevice:Descriptor:... (the real init — skip stubbing)
            // Pre-emptively stub the ones whose default value is well-defined.
            // Each returns a safe value (NO, 0, nil, self) so the call site
            // continues past doesNotRecognizeSelector.
            struct stub { const char *sel; const char *enc; IMP imp; };
            // BOOL stubs returning NO
            IMP retNO = imp_implementationWithBlock(^BOOL(id s) { (void)s; return NO; });
            // 2026-06-20 — isMemoryless was previously stubbed to ALWAYS
            // return NO, breaking memoryless texture handling: AGXTexture
            // init at 0x1e5a5b9c0 sends `isMemoryless` to the IOGPUMetalTexture
            // super-init result; returning NO sends it down the "with
            // backing memory" path, which for a memoryless request meant
            // ROUTE-IOSURF allocated a 31 MB IOSurface per call → 5120 MB
            // WS watermark OOM in <60 composite cycles.  Replace with an
            // IMP that queries the texture's storageMode property (part
            // of MTLTexture protocol; natively implemented on IOGPUMetalTexture
            // / AGXG13GFamilyBuffer) and returns YES iff the texture was
            // requested as memoryless (storageMode == 3).
            IMP retIsMemoryless = imp_implementationWithBlock(^BOOL(id s) {
                if (s && [s respondsToSelector:@selector(storageMode)]) {
                    // storageMode returns NSUInteger; use objc_msgSend variant
                    // to avoid pulling in Metal headers here.
                    typedef NSUInteger (*sm_t)(id, SEL);
                    NSUInteger sm = ((sm_t)objc_msgSend)(s, @selector(storageMode));
                    return sm == 3 /* MTLStorageModeMemoryless */;
                }
                return NO;
            });
            // size_t stubs returning 0
            IMP retZeroSize = imp_implementationWithBlock(^NSUInteger(id s) { (void)s; return 0; });
            // NSUInteger stubs returning 0
            IMP retZeroNS = imp_implementationWithBlock(^NSUInteger(id s) { (void)s; return 0; });
            // id stub returning self (for descriptorPrivate / initNewTextureData:)
            IMP retSelf = imp_implementationWithBlock(^id(id s) { (void)s; return s; });
            IMP retSelfArg = imp_implementationWithBlock(^id(id s, id a) { (void)s; (void)a; return s; });
            // void no-op (for finalizeTextureCreation, updateBindData…)
            IMP retVoid = imp_implementationWithBlock(^(id s) { (void)s; });
            IMP retVoid3 = imp_implementationWithBlock(^(id s, void *p, uint64_t va) { (void)s; (void)p; (void)va; });
            IMP retVoid4 = imp_implementationWithBlock(^(id s, void *p, uint64_t va, BOOL b) { (void)s; (void)p; (void)va; (void)b; });
            // nil stub for allocBufferSubData…
            IMP retNil = imp_implementationWithBlock(^id(id s, NSUInteger l, NSUInteger o, NSUInteger a,
                                                          NSUInteger h, NSUInteger b, NSUInteger off) {
                (void)s; (void)l; (void)o; (void)a; (void)h; (void)b; (void)off; return nil;
            });
            struct stub stubs[] = {
                { "isMemoryless",                                  "c@:",                retIsMemoryless },
                { "protectionOptions",                             "Q@:",                retZeroNS },
                { "getCPUSizeBytes",                               "Q@:",                retZeroSize },
                { "getAlignment",                                  "Q@:",                retZeroSize },
                { "descriptorPrivate",                             "@@:",                retSelf },
                { "getBytesPerRow",                                "Q@:",                retZeroSize },
                { "finalizeTextureCreation",                       "v@:",                retVoid },
                { "updateBindDataWithAddresses:gpuVirtualAddress:", "v@:^vQ",            retVoid3 },
                { "updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:", "v@:^vQc", retVoid4 },
                { "allocBufferSubDataWithLength:options:alignment:heapIndex:bufferIndex:bufferOffset:",
                                                                    "@@:QQQQQQ",        retNil },
                { "initNewTextureData:",                           "@@:@",               retSelfArg },
                { NULL, NULL, NULL }
            };
            const char *targets[] = {
                "IOGPUMetalTexture",
                "AGXG13GFamilyBuffer",
                "AGXTexture",
                "MTLTextureDescriptor",
                "AGXG13GFamilyTexture",
                NULL
            };
            for (int t = 0; targets[t]; t++) {
                Class k = objc_getClass(targets[t]);
                if (!k) continue;
                for (int s = 0; stubs[s].sel; s++) {
                    SEL sel = sel_registerName(stubs[s].sel);
                    if (class_getInstanceMethod(k, sel)) continue;
                    BOOL ok = class_addMethod(k, sel, stubs[s].imp, stubs[s].enc);
                    if (ok) {
                        fprintf(stderr,
                            "#### MACWS_AGX_NATIVE class_addMethod(%s, %s) = 1\n",
                            targets[t], stubs[s].sel);
                    }
                }
            }
        }
    } else if(!strncmp(info.dli_fname, QuartzCorePath, strlen(QuartzCorePath))) {
        // Force CABackingStorePrepareUpdates_ onto the accelerated/IOSurface path so window
        // content gets a GPU surface instead of a CPU bitmap (see OFF_ comment above).
        // Patch `cbz w21, +852` (0x34000155) -> `b +840` (0x14000007).
        //
        // Apply only in CLIENT apps, NOT in WindowServer itself: WindowServer also links
        // QuartzCore and uses CABackingStore for its own (menu bar / cursor) rendering, where
        // forcing the accelerated path breaks its UI (menus stop opening).  Detect WindowServer
        // by its main executable path and skip the patch there.
        char exe[PATH_MAX]; uint32_t exelen = sizeof(exe);
        BOOL isWindowServer = NO;
        if(_NSGetExecutablePath(exe, &exelen) == 0) {
            isWindowServer = (strstr(exe, "SkyLight.framework/Resources/WindowServer") != NULL);
        }
        { uint32_t *fa = (uint32_t *)(OFF_QuartzCore_CABackingStore_force_accel + (uintptr_t)header);
          fprintf(stderr, "#### FORCE-ACCEL gate: prog=%s isWS=%d env=%s byte=%#x\n",
                  getprogname() ?: "?", isWindowServer,
                  getenv("MACWS_KEEP_FORCE_ACCEL") ?: "(null)", *fa); }
        if(!isWindowServer && getenv("MACWS_KEEP_FORCE_ACCEL")) {
            // RE-confirmed LOAD-BEARING (SIM-vs-AGX A/B): forces
            // CABackingStorePrepareUpdates_ onto the IOSurface branch so client
            // window content becomes a GPU surface WS can composite (else CPU
            // bitmap → window+0x128==0 → not composited).
            uint32_t *forceAccel = (uint32_t *)(OFF_QuartzCore_CABackingStore_force_accel + (uintptr_t)header);
            ModifyExecutableRegion(forceAccel, sizeof(uint32_t), ^{
                if (*forceAccel == 0x34000155) { // cbz w21, #0x28 (+852)
                    *forceAccel = 0x14000007;    // b +840 (accelerated path)
                    fprintf(stderr, "#### FORCE-ACCEL: PATCHED CABackingStore→IOSurface in %s\n", getprogname() ?: "?");
                } else {
                    fprintf(stderr, "#### FORCE-ACCEL: byte mismatch %#x (not patched) in %s\n", *forceAccel, getprogname() ?: "?");
                }
            });
        }
        if (isWindowServer) install_modeset_trace();  // diag, gated /tmp/macws_modeset_trace
    } else if(getenv("MACWS_AGX_NATIVE") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
        // 2026-06-20 — One-shot guard.  AGXMetal13_3 is dlopen'd multiple
        // times across the WS lifetime (initial Metal load + chroot's
        // explicit re-dlopen + dyld notify on dependent-loads).  Re-running
        // the patches is idempotent BUT the diagnostic fprintf calls
        // accumulate stderr writes, and on the Nth invocation we've seen
        // KERN_PROTECTION_FAILURE in __write_nocancel (stderr's FILE buffer
        // gets corrupted somewhere — likely a stack overlap during the
        // dyld notify-load lock).  Make this block fire ONCE per process.
        static _Atomic int s_agxmetal_patched = 0;
        if (atomic_exchange(&s_agxmetal_patched, 1)) {
            return; // already patched in this process
        }
        // CHROOT AGX-NATIVE patches for the strict-AGX-native userspace path.
        //
        // Originally three layered binary patches lived here:
        //
        //   1. NOP setupDeferred's dispatch_once  (b.ne at +0x64 → NOP)
        //   2. NOP the first forward BL inside each Mempool<X>::grow (the lambda
        //      that tail-jumps to the IOGPU pool allocator BSS slot)
        //   3. Replace `b.hs +<off>` near grow's entry with an unconditional
        //      `b epilogue` so the broken inline freelist loop is skipped
        //
        // All three existed because cross-image IOGPU bindings stayed null in
        // chroot dyld — Mempool::grow's lambda then crashed dereferencing the
        // garbage function pointer at data_21f95bc90.
        //
        // Those root causes have since been fixed by the chained-fixups walker
        // (macws_walk_chained_fixups), the LC_SYMTAB-based GOT repair
        // (macws_repair_got_via_symtab), the IOGPU ctor preload, and the
        // sub_1e5a5dfc0 stub rewrite. Once IOGPU is bound, setupDeferred and
        // grow's lambda both have to run — they're the only place
        // _storageCreateParams.hwResourcePoolCount gets set, and without that
        // commandBufferResourceInfo returns nil and DataBufferAllocator::
        // newCommand crashes on a null base.
        //
        // Removed 2026-06-18 after auditing the patches.
        uint64_t text_static_base = 0x1e53e321c;
        unsigned long text_sz = 0;
        uint8_t *text = getsectiondata((const struct mach_header_64 *)header,
                                       "__TEXT", "__text", &text_sz);
        intptr_t slide = (intptr_t)text - (intptr_t)text_static_base;

        // USC-BASE EXPERIMENT (gated /tmp/macws_uscbase): the BIF0 fault is the GPU shader/USC unit
        // (requestor=1) reading shader code at 0x1168000000, in the 0x11xx region the iOS kernel
        // defines (AGXG13G VA-region table {0x11xx,0x13xx,0x14xx}) but does not map for the chroot
        // context. 0x1100000000 is a const in AGXMetal's __DATA_CONST/__TEXT region tables. This
        // rewrites it (to the flag-file value, default 0x1500000000 = the mapped GEM base) to test
        // whether the fault VA moves -> confirms this is the USC-base control point.
        if (access("/tmp/macws_uscbase", F_OK) == 0) {
            uint64_t newbase = 0x1500000000ULL;
            FILE *uf = fopen("/tmp/macws_uscbase","r");
            if (uf){ unsigned long long v=0; if (fscanf(uf,"%llx",&v)==1 && v) newbase=v; fclose(uf); }
            int npatched=0;
            const char *segn[] = {"__DATA_CONST","__TEXT","__DATA","__AUTH_CONST"};
            for (int si=0; si<4; si++){
                unsigned long segsz=0;
                uint8_t *seg=getsegmentdata((const struct mach_header_64*)header, segn[si], &segsz);
                if(!seg) continue;
                int isText = (si==1);  // __TEXT is executable -> needs CoW via vm_protect, not mprotect
                for (unsigned long i=0; i+8<=segsz; i+=4){   // 4-aligned: the consts sit at 0x..bc/0x..3c
                    uint64_t v; memcpy(&v, seg+i, 8);
                    if(v==0x1100000000ULL){
                        uintptr_t pg=(uintptr_t)(seg+i) & ~0xfffUL;
                        int ok=0;
                        if(isText){
                            if(vm_protect(mach_task_self(),pg,0x2000,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)==KERN_SUCCESS){
                                memcpy(seg+i,&newbase,8);
                                vm_protect(mach_task_self(),pg,0x2000,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
                                ok=1;
                            }
                        } else if(mprotect((void*)pg,0x2000,PROT_READ|PROT_WRITE)==0){
                            memcpy(seg+i,&newbase,8);
                            mprotect((void*)pg,0x2000,PROT_READ);
                            ok=1;
                        }
                        if(ok){ npatched++; fprintf(stderr,"#### USCBASE: patched %s+%#lx\n",segn[si],i); }
                    }
                }
            }
            fprintf(stderr,"#### USCBASE: patched %d x 0x1100000000 -> %#llx in AGXMetal\n",
                    npatched,(unsigned long long)newbase);
        }

        // ROOT-CAUSE diagnostic + S1 fix for the backdrop-blur memmove(NULL) crash
        // (gated /tmp/macws_wr3_guard). RE+runtime-confirmed the crash is
        // getCPUPtr→*(this+0x130)==0; see macws_my_wr3 above. We intercept writeRegion
        // with an MSHookFunction PROLOGUE patch (runs full C logic: read 0x130/resource,
        // log, recover the CPU base). MSHookFunction silently no-ops on the dlopen'd
        // arm64e AGXMetal13_3 UNLESS its page is first made private via VM_PROT_COPY, so
        // we ModifyExecutableRegion the writeRegion page (a NO-OP write that preserves the
        // original instruction — only the CoW side effect matters) before installing the
        // hook. writeRegion start (0x1e5771af8) and the touched insn (+0x6c) share one
        // page (0x1e5771000), so CoW'ing there makes the prologue patchable.
        if (getenv("MACWS_WR3_GUARD") || access("/tmp/macws_wr3_guard", F_OK) == 0) {
            uint32_t *site = (uint32_t *)((uintptr_t)0x1e5771b64 + slide);  // writeRegion+0x6c (same page)
            uint32_t orig_insn = *site;
            ModifyExecutableRegion(site, sizeof(uint32_t), ^{ *site = orig_insn; });  // no-op write → CoW page
            void *wr3 = (void *)((uintptr_t)0x1e5771af8 + slide);  // AGX::Texture<3>::writeRegion
            macws_install_wr3_guard(wr3);
            fprintf(stderr, "#### WR3-GUARD: CoW'd page + MSHook writeRegion @ %p\n", wr3);
        }

        // REAL-BLUR FIX (gated /tmp/macws_blur_route): cache-proof IOSurface routing.
        // AGXG13GFamilyDevice -[newTextureWithDescriptor:] @ unslid 0x1e574d5ec.
        if (getenv("MACWS_BLUR_ROUTE") || access("/tmp/macws_blur_route", F_OK) == 0) {
            void *imp = (void *)((uintptr_t)0x1e574d5ec + slide);
            macws_install_blur_route(imp);
        }

        // ──────────────────────────────────────────────────────────────────
        // AGX texture wrap gate bypass (env-gated).
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] @ 0x1e5a5ae18 calls
        //   sub_1e5a5d5f0(iosurface, plane)   ; some IOSurface-type query
        //   cmp w0, #0x4
        //   ccmp w0, #0x1, #0x4, ls           ; flags = (w0==1 if w0<=4) else Z=1
        //   b.eq EXIT_NIL                     ; @ 0x1e5a5ae60, fires if w0==1 OR w0>4
        // In chroot the query returns a value that triggers the nil-exit even for
        // a perfectly valid BGRA8 IOSurface. NOP the b.eq so the function always
        // proceeds to the real init path (sub_1e5aad880 →
        // initImplWithDevice:Descriptor:iosurface:plane:buffer:bytesPerRow:...).
        // Gated by MACWS_AGX_TEX_BYPASS_GATE=1 so we can A/B with the original.
        // DIAG: identify the cross-image GOT bindings used by AGXTexture's
        // init chain. The stubs:
        //   sub_1e5a5d540 loads *0x21f934130 → gate-1 query (called from
        //     -[AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:])
        //   sub_1e5a5d5f0 loads *0x21f934200 → gate-1 of -[AGXTexture init...]
        //     (returns int; value 1 or >4 triggers immediate nil)
        //   sub_1e5a5d650 loads *0x21f934240 → gate-3 query (iosurface)
        //   sub_1e5a5d590 loads *0x21f934220 → property loader (no gate)
        // Resolve each via dladdr to identify the actual IOSurface/IOGPU
        // symbol so we can reason about what they SEMANTICALLY check
        // rather than blindly NOPing.
        if (getenv("MACWS_AGX_TEX_BYPASS_GATE")) {
            struct got_probe { uint64_t addr; const char *role; } probes[] = {
                { 0x21f934130, "newTexture:iosurface: gate query" },
                { 0x21f934200, "AGXTexture init gate-1 (returns int)" },
                { 0x21f934220, "AGXTexture init prop load" },
                { 0x21f934240, "AGXTexture init gate-3 (iosurface)" },
                // Stub @0x1e5a5dfc0 = adrp 0x21f95b000 + add #0xca8 + ldr [#0xca8].
                // (Earlier note had this as 0x21f934ca8 — wrong page; the
                // ADRP target for THIS stub is 0x21f95b000.)
                //
                // BN's macOS DSC view shows ALL __auth_stubs reference one of
                // ~15 cache-shared __got pages (0x21f927000..0x21f95b000). The
                // 0x21f95b000 page is the libobjc runtime-helper page; sub_
                // 1e5a5dfc0 specifically is `_objc_msgSendSuper2` (called from
                // every -[…super dealloc] / [super initWith…] in this image).
                //
                // In chroot the page is OUTSIDE the dlopen'd image's segments
                // → the slot reads whatever happens to be at that VA (e.g.
                // MTCapabilityIsAvailable from MediaToolbox), super-init
                // returns 0, -[AGXTexture init…] nil-exits.
                //
                // The MACWS_AGX_NATIVE block below patches the stub itself
                // (movz/movk/movk/br x16 to dlsym'd objc_msgSendSuper2),
                // bypassing the broken slot entirely.
                { 0x21f95bca8, "objc_msgSendSuper2 slot (via stub sub_1e5a5dfc0)" },
            };
            for (size_t pi = 0; pi < sizeof(probes)/sizeof(probes[0]); pi++) {
                void **slot = (void **)(probes[pi].addr + slide);
                void *fn = *slot;
                Dl_info di = {0};
                int ok = dladdr(fn, &di);
                dprintf(2,
                    "#### AGX_TEX_DIAG GOT@%p = %p  (slid %#llx + %#zx = %#llx)\n"
                    "####   role: %s\n"
                    "####   dladdr ok=%d sym=%s base=%p path=%s\n",
                    slot, fn,
                    (unsigned long long)probes[pi].addr, (size_t)slide,
                    (unsigned long long)(probes[pi].addr + slide),
                    probes[pi].role,
                    ok, di.dli_sname ?: "(none)", di.dli_fbase, di.dli_fname ?: "(none)");
            }
        }
        // ──────────────────────────────────────────────────────────────────
        // texBaseAddressesUpdated null-deref skip (env-gated).
        //
        // Root cause (see memory [[agx-texbaseaddresses-nullderef]]):
        //   SkyLight's CompositorMetal::CreateShadowFromMask (window shadow
        //   texture for chrome rendering) calls -[AGXG13GFamilyDevice
        //   newTextureWithDescriptor:] (no-iosurface variant), which routes
        //   through -[AGXTexture initWithDevice:desc:isSuballocDisabled:].
        //   That init calls
        //     [self updateBindDataWithAddresses:gpuVirtualAddress:shouldInitMetadata:]
        //   which internally calls AGX::TextureGen4<G13>::texBaseAddressesUpdated().
        //   In chroot, the texture's `(self->0x1c8)->0x8` is null, so
        //   texBaseAddressesUpdated +2932 (ldr x11,[x11,#0x18] after
        //   `add x11,x11,x10` where x10 is an ivar offset of 0x18) faults
        //   at addr 0x30. WS dies with SIGSEGV.
        //
        // Confirmed by iOS-side lldb runtime trace (see [[lldb-remote-
        // debugserver-setup]] + misc/ios_lldb_tmux.sh): the initImpl* path
        // I'd been investigating earlier runs fine (9/9 calls reach
        // epilogue); only this initWithDevice:desc:isSuballocDisabled:
        // path crashes. The crash is in a SHADOW texture path, not the
        // framebuffer-IOSurface path.
        //
        // Patch: NOP the BL @ 0x1e5a5ba10 inside
        //   `-[AGXTexture initWithDevice:desc:isSuballocDisabled:]`. That
        // BL targets objc_msgSend$updateBindDataWithAddresses:gpuVirtual\
        // Address:shouldInitMetadata: (the stub @ 0x1e5ab1bc0). Skipping
        // it means the AGX encoder bind tables don't get updated with this
        // texture's base address (so a draw using the texture might show
        // garbage), but the texture object itself is still created and
        // returned. AGXTexture's `finalizeTextureCreation` call right
        // after (at 0x1e5a5ba18, bl 0x1e5aacfa0) still runs.
        //
        // For SkyLight's shadow-mask use case the worst-case is window
        // chrome shadows render incorrectly — acceptable trade vs WS dying.
        //
        // Gated by MACWS_AGX_SKIP_BIND_UPDATE=1 (default ON for AGX-native
        // mode since AGX-native otherwise crashes on first shadow draw).

        // DIAG: what class is in __objc_classrefs at offset 0x298?
        // -[AGXG13GFamilyDevice newTextureWithDescriptor:iosurface:plane:]
        //   at 0x1e574d5ac (FAIL path): loads classref @ 0x21a8a9298 →
        //   objc_alloc(<class>) → ... initWithDevice:desc:iosurface:plane:.
        // The init's `[self initImplWith...]` dispatch goes to the alloc'd
        // class's impl. If the class is AGXTexture (base, returns 0) the
        // texture wrap fails. If it's AGXG13GFamilyTexture (subclass with
        // the real impl), the wrap should work. Log which one.
        if (getenv("MACWS_AGX_NATIVE")) {
            void **classref_slot = (void **)(0x21a8a9298 + slide);
            void *cls = *classref_slot;
            const char *clsname = cls ? class_getName((Class)cls) : "(nil)";
            dprintf(2,
                "#### AGX_CLASSREF_DIAG newTexture iosurface alloc class "
                "@%p = %p name=%s\n",
                classref_slot, cls, clsname);
            // Check critical method on the texture class — initImpl variants
            // The plain stub on AGXTexture base returns 0 (we saw at static
            // 0x1e5a5a880-884: mov w0,#0; ret). If dispatch resolves to that
            // base stub instead of AGXG13GFamilyTexture's real impl, every
            // texture creation returns nil. Compare imp address against
            // both static addresses (with slide):
            //   AGXTexture initImplWith... = 0x1e5a5a880 (base, stub)
            //   AGXG13GFamilyTexture initImplWith... = 0x1e5a4a284 (subclass, real)
            if (cls) {
                SEL sel = sel_registerName(
                    "initImplWithDevice:Descriptor:iosurface:plane:buffer:"
                    "bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:"
                    "isHeapBacked:");
                Method m = class_getInstanceMethod((Class)cls, sel);
                IMP imp = m ? method_getImplementation(m) : NULL;
                uintptr_t agxtex_stub = (uintptr_t)0x1e5a5a880 + slide;
                uintptr_t agxg13_real = (uintptr_t)0x1e5a4a284 + slide;
                const char *which = "UNKNOWN";
                if ((uintptr_t)imp == agxtex_stub) which = "AGXTexture-stub-returns-0";
                else if ((uintptr_t)imp == agxg13_real) which = "AGXG13GFamilyTexture-real";
                dprintf(2,
                    "#### AGX_CLASSREF_DIAG initImpl method m=%p imp=%p "
                    "expected stub=%p real=%p WHICH=%s\n",
                    m, imp, (void*)agxtex_stub, (void*)agxg13_real, which);
            }
            // REC-SIZE FIX (gated /tmp/macws_recfix): the chroot runs macOS AGXMetal13_3 against the
            // iOS 16.3 GPU kernel. macOS emits the op-3 (compute/blit/render-pass) GPU command record
            // 0x10 LARGER than the iOS kernel validator (AGXCommandQueue::processSegmentKernelCommand)
            // accepts — size 0x1b8 vs 0x1a8, end 0x1e8 vs 0x1d8 — so EVERY submit is rejected 0x103.
            // Shrink the record by 0x10: the template const (size+end), the body memset size, and the
            // newCommand reservation; the trailing 16 bytes are droppable padding (clobbered by the
            // next record's header). RE+byte-verified (agx-blit-record-malformation workflow 2026-06-24).
            if (access("/tmp/macws_recfix", F_OK) == 0) {
                uint32_t *t1 = (uint32_t *)(0x1e5a629d0 + slide);   // {end=0x1e8, size=0x1b8}
                uint32_t *t2 = (uint32_t *)(0x1e5a62bb8 + slide);   // {size=0x1b8}
                uint32_t *b1 = (uint32_t *)(0x1e55fb308 + slide);   // mov w1,#0x1b8 (body memset)
                uint32_t *n1 = (uint32_t *)(0x1e55fb2cc + slide);   // mov w1,#0x1f0 (newCommand)
                int ok1 = (t1[0] == 0x1e8 && t1[1] == 0x1b8), ok2 = (t2[0] == 0x1b8);
                int ok3 = (*b1 == 0x52803701), ok4 = (*n1 == 0x52803e01);
                if (ok1) ModifyExecutableRegion(t1, sizeof(uint32_t[2]), ^{ t1[0] = 0x1d8; t1[1] = 0x1a8; });
                if (ok2) ModifyExecutableRegion(t2, sizeof(uint32_t),    ^{ t2[0] = 0x1a8; });
                if (ok3) ModifyExecutableRegion(b1, sizeof(uint32_t),    ^{ *b1 = 0x52803501; });
                if (ok4) ModifyExecutableRegion(n1, sizeof(uint32_t),    ^{ *n1 = 0x52803c01; });
                dprintf(2, "#### REC-SIZE FIX (op-3 0x1b8->0x1a8) sig[%d%d%d%d] slide=%p now t1={%#x,%#x} t2=%#x b1=%#x n1=%#x\n",
                    ok1, ok2, ok3, ok4, (void*)slide, t1[0], t1[1], t2[0], *b1, *n1);
            }
        }

        if (getenv("MACWS_AGX_SKIP_BIND_UPDATE") ||
            (getenv("MACWS_AGX_NATIVE") && !getenv("MACWS_AGX_KEEP_BIND_UPDATE"))) {
            // Two BL sites both target objc_msgSend$updateBindDataWith…
            // which calls AGX::TextureGen4<G13>::texBaseAddressesUpdated()
            // — that function +2932 does `ldr x11, [x11, #0x18]` where
            // x11's prior load is null in chroot → SEGV at addr 0x30.
            // NOP both so neither texture-init path crashes:
            //
            //   0x1e5a5ba10 (3-arg variant)
            //     called from -[AGXTexture initWithDevice:desc:isSuballocDisabled:]
            //     dispatches objc_msgSend$updateBindDataWithAddresses:
            //                gpuVirtualAddress:shouldInitMetadata:
            //   0x1e5a5afc4 (5-arg variant) — IOSURFACE init path
            //     called from -[AGXTexture initWithDevice:desc:iosurface:plane:]
            //     dispatches objc_msgSend$updateBindDataWithAddresses:cpu
            //                MetadataAddress:gpuVirtualAddress:isCompressible:
            //                shouldInitMetadata:
            //
            // After the sel=0xa type=0x82 IOSurfaceID fix (2026-06-18),
            // texture init reaches the iosurface variant for the first
            // time and crashes there too — symptom-identical to the
            // pre-existing 3-arg crash this patch already handled. Same
            // fix applies.
            uint64_t bl_statics[] = { 0x1e5a5ba10, 0x1e5a5afc4 };
            const uint32_t NOP_INSN = 0xd503201f;
            for (size_t i = 0; i < sizeof(bl_statics)/sizeof(bl_statics[0]); i++) {
                uint64_t bl_static = bl_statics[i];
                uint32_t *bl_at = (uint32_t *)(bl_static + slide);
                ModifyExecutableRegion(bl_at, sizeof(uint32_t), ^{
                    uint32_t insn = *bl_at;
                    // BL opcode mask: top 6 bits = 100101 (0x94/0x97 with imm).
                    BOOL is_bl = ((insn & 0xFC000000) == 0x94000000);
                    if (is_bl) {
                        *bl_at = NOP_INSN;
                        dprintf(2,
                            "#### MACWS_AGX_SKIP_BIND_UPDATE: NOPed BL @%p "
                            "(static %#llx + slide=%#zx)\n",
                            bl_at, (unsigned long long)bl_static,
                            (size_t)slide);
                    } else if (insn == NOP_INSN) {
                        /* already patched */
                    } else {
                        dprintf(2,
                            "#### MACWS_AGX_SKIP_BIND_UPDATE: @%p got %#x "
                            "expected BL — SKIP\n",
                            bl_at, insn);
                    }
                });
            }
        }
        //
        // Need to read what each gate actually does before patching. The
        // stubs sub_1e5a5d5f0 / sub_1e5a5d650 are __auth_stub jump-thunks
        // into IOSurface/IOGPU framework via __got slots 0x21f934200 /
        // 0x21f934240 (etc.). Those slots' bound symbols can only be read
        // by attaching lldb to a running WS and dumping the slot contents
        // (or by decoding the dyld chained-fixups via otool -bind).
        //
        // TODO once symbols are identified:
        //   1. Understand what the IOSurface property check actually wants
        //   2. Either: (a) modify our IOSurface to satisfy the check, or
        //      (b) hook the IOSurface API itself to return the expected
        //      value for AGX's framebuffer surfaces in chroot.

        // ──────────────────────────────────────────────────────────────────
        // __objc_superrefs slot patcher for AGXTexture → IOGPUMetalTexture.
        //
        // Background discovered 2026-06-17:
        //   -[AGXTexture initWithDevice:desc:iosurface:plane:] at 0x1e5a5af00
        //   loads its [super …] receiver class from 0x21a8a96d0 (an entry in
        //   __objc_superrefs). In a normal binary, dyld would process the
        //   chained-fixup record at that slot and write the runtime class
        //   pointer. AGXMetal13_3 was extracted from the DSC and has NO
        //   LC_DYLD_CHAINED_FIXUPS / LC_DYLD_INFO_ONLY — so the slot keeps
        //   its raw cache-baked chained-fixup encoding (e.g. high-byte 0x01,
        //   0xf0 noise bits) and reads back as a pointer to garbage.
        //
        //   objc_msgSendSuper2 then class-looks-up the selector against the
        //   garbage receiver → no method found → 0 return → init nil-exit
        //   at the cbz x0 immediately after. Our IOGPU_INIT_HOOK never fires
        //   even though class_getSuperclass(AGXTexture)==IOGPUMetalTexture
        //   resolves correctly via libobjc's superClassName fallback — the
        //   ABI-level superref slot is unaffected by that fallback.
        //
        // Fix: at AGXMetal13_3 load time, write the LIVE IOGPUMetalTexture
        // class pointer into 0x21a8a96d0+slide. __objc_superrefs is in plain
        // __DATA (no PAC auth needed); a raw pointer write suffices.
        //
        // Slot is at the very END of __objc_superrefs (size 0x140 from
        // 0x21a8a9598; offset 0x6d0 from page 0x21a8a9000 → 0x21a8a96d0,
        // which is 0x138 from the start of __objc_superrefs == the 40th /
        // last superref entry). Other superref entries used by other AGX
        // classes are TODO — patch reactively as more nil-exits surface.
        if (getenv("MACWS_AGX_NATIVE")) {
            // 2026-06-17 lldb-confirmed root cause of texture-init nil-exit
            // (and the actual fix that worked):
            //
            // libobjc's objc_msgSendSuper2 does at +16:
            //     autda x16, x17     ; PAC-auth super_class->superclass
            //     ldr   x10, [x16, #0x10]    ; load cache buckets
            //
            // AGXTexture's runtime class_t.superclass holds a raw unsigned
            // 0x1fdfdcfb0 (= IOGPUMetalTexture) — the cache-baked PAC-signed
            // chained-fixup record at __DATA AGXTexture+0x8 isn't processed
            // by chroot dyld (DSC extraction strips chained fixups), so
            // libobjc's name-based class registration left the field as a
            // raw pointer. autda on a raw pointer fails → x16 becomes 0 (or
            // poisoned) → ldr [x16+0x10] segfaults at 0x10. WS dies.
            //
            // PAC-signing from libmachook is unavailable here — we're built
            // as arm64 (not arm64e), so macws_pac_sign is a no-op. Instead:
            // replace the autda inside libobjc with xpacd x16. xpacd just
            // STRIPS PAC bits without verification — works for both signed
            // (legit) and raw (our case) pointers. autda x16,x17 and
            // xpacd x16 are both 4 bytes, so it's a single-instruction patch.
            //
            // Patch is per-process (ModifyExecutableRegion does COW), other
            // processes' libobjc unaffected.

            // (The previous AGXTexture super-init bypass that lived here —
            // forcing -[AGXTexture initWithDevice:desc:iosurface:plane:] to
            // return self regardless of IOGPUMetalTexture's super-init result
            // — was removed 2026-06-18. The IOSurfaceID +0x30 swap on sel=0xa
            // type=0x82 made the super-init actually succeed, so the bypass
            // is no longer needed.)

            void *super2 = dlsym(RTLD_DEFAULT, "objc_msgSendSuper2");
            if (super2) {
                // autda is at msgSendSuper2 + 16 (verified by lldb).
                uint32_t *autda_at = (uint32_t *)((uint8_t *)super2 + 16);
                const uint32_t AUTDA_X16_X17 = 0xdac11a30u;
                const uint32_t XPACD_X16     = 0xdac147f0u;
                uint32_t cur = *autda_at;
                dprintf(2,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH msgSendSuper2=%p "
                    "autda@%p insn=%#x\n",
                    super2, autda_at, cur);
                if (cur == XPACD_X16) {
                    dprintf(2, "####   already patched, skip\n");
                } else if (cur != AUTDA_X16_X17) {
                    dprintf(2,
                        "####   unexpected insn (expected %#x for autda x16,x17) — skip\n",
                        AUTDA_X16_X17);
                } else {
                    ModifyExecutableRegion(autda_at, 4, ^{
                        *autda_at = XPACD_X16;
                    });
                    dprintf(2,
                        "####   PATCHED autda x16,x17 → xpacd x16 (%#x → %#x)\n",
                        AUTDA_X16_X17, XPACD_X16);
                }
            } else {
                dprintf(2,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH: dlsym(objc_msgSendSuper2)=NULL\n");
            }

            // Diagnostic (read-only) — useful when triaging future variants.
            Class agx_tex = objc_getClass("AGXTexture");
            Class iogpu_tex = objc_getClass("IOGPUMetalTexture");
            if (agx_tex && iogpu_tex) {
                uint64_t *super_field = (uint64_t *)((uintptr_t)agx_tex + 8);
                dprintf(2,
                    "#### MACWS_AGX_SUPERCLASS_DIAG AGXTexture=%p field@%p=%#llx "
                    "IOGPUMetalTexture=%p\n",
                    (void*)agx_tex, super_field,
                    (unsigned long long)*super_field,
                    (void*)iogpu_tex);
            }
        }

        // ──────────────────────────────────────────────────────────────────
        // Runtime diagnostic: dump the cstring at the [super initWith…]
        // selector address used by -[AGXTexture initWithDevice:desc:iosurface\
        // :plane:].
        //
        // At static 0x1e5a5af08:
        //     adrp x8, 0x1cffc6000
        //     add  x1, x8, #0xf26    ; SEL @ 0x1cffc6f26
        //
        // 0x1cffc6f26 is OUTSIDE every segment of the extracted binary —
        // in the cache it points to libobjc's __objc_methname, which is
        // not part of the extracted image. After slide-relocation in chroot
        // it lands at some unrelated VA. objc_msgSendSuper2 sees a wrong
        // (or garbage) selector name → method lookup fails → returns 0 →
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] nil-exits at
        // cbz x0 (static 0x1e5a5af3c) before validate is ever reached.
        //
        // Print the first 96 bytes at the slid VA so we can see what
        // actually lives there.
        if (getenv("MACWS_AGX_NATIVE")) {
            uint64_t sel_static = 0x1cffc6f26;
            const char *sel_runtime = (const char *)(sel_static + slide);
            char preview[97] = {0};
            int readable = 0;
            @try {
                memcpy(preview, sel_runtime, 96);
                readable = 1;
            } @catch (id e) {
                readable = 0;
            }
            // Sanitize for printing
            for (size_t i = 0; i < sizeof(preview)-1; i++) {
                unsigned char c = (unsigned char)preview[i];
                if (c == 0) { preview[i] = 0; break; }
                if (c < 0x20 || c >= 0x7f) preview[i] = '.';
            }
            // 2026-06-20 — dprintf(2, ...) not dprintf(2, ...) here.
            // The latter writes to libsystem's _stderr FILE struct's
            // internal buffer; if the FILE struct's _p (current write
            // position) gets corrupted (we saw KERN_PROTECTION_FAILURE
            // in __write_nocancel writing to a shared-cache RO address),
            // every subsequent fprintf in any loadImageCallback re-entry
            // crashes WS.  dprintf does fresh-buffer-then-write(fd) — no
            // FILE* state involved, robust against the corruption.
            dprintf(2,
                "#### MACWS_AGX_SEL_DIAG super-init SEL static=%#llx slid=%p "
                "readable=%d\n"
                "####   bytes=\"%s\"\n",
                (unsigned long long)sel_static, sel_runtime, readable, preview);

            // Also: what does sel_registerName resolve THIS cstring to?
            if (readable && preview[0]) {
                SEL s = sel_registerName(sel_runtime);
                dprintf(2,
                    "####   sel_registerName(...) = %p name=\"%s\"\n",
                    s, sel_getName(s));
            }

            // And what selector does our AGXG13GFamilyTexture's superclass
            // actually expect for initWith…iosurface… ? Try the obvious
            // candidate names.
            const char *candidates[] = {
                "initWithDevice:desc:iosurface:plane:",
                "initWithDevice:descriptor:iosurface:plane:",
                "initWithDevice:descriptor:iosurface:plane:field:args:argsSize:",
                "initImplWithDevice:Descriptor:iosurface:plane:buffer:"
                  "bytesPerRow:allowNPOT:sparsePageSize:isCompressedIOSurface:"
                  "isHeapBacked:",
                NULL
            };
            // Also peek at IOGPUMetalTexture class registration + method list count
            Class iogpu_tex = objc_getClass("IOGPUMetalTexture");
            fprintf(stderr,
                "####   objc_getClass(IOGPUMetalTexture) = %p\n", iogpu_tex);
            if (iogpu_tex) {
                unsigned int n = 0;
                Method *ml = class_copyMethodList(iogpu_tex, &n);
                fprintf(stderr, "####   IOGPUMetalTexture method count = %u\n", n);
                int shown = 0;
                for (unsigned int j = 0; j < n && shown < 32; j++) {
                    const char *mn = sel_getName(method_getName(ml[j]));
                    if (strstr(mn, "init") || strstr(mn, "Init")) {
                        fprintf(stderr, "####     - %s\n", mn);
                        shown++;
                    }
                }
                if (ml) free(ml);
            }
            Class agxtex_cls = objc_getClass("AGXTexture");
            Class super_cls  = agxtex_cls ? class_getSuperclass(agxtex_cls) : NULL;
            fprintf(stderr,
                "####   AGXTexture super class = %p (%s)\n",
                super_cls, super_cls ? class_getName(super_cls) : "(nil)");
            for (int c = 0; candidates[c]; c++) {
                SEL s = sel_registerName(candidates[c]);
                Method m = super_cls ? class_getInstanceMethod(super_cls, s) : NULL;
                fprintf(stderr,
                    "####   super responds to \"%s\" = %d (Method=%p)\n",
                    candidates[c], m != NULL, m);
            }
        }

        // (Removed LAZY -[AGXG13GFamilyTexture validateBufferTextureWithSize:]
        // → always-YES patch. The magic-footer check at this site never
        // fires when we get to it under MACWS_AGX_REGISTER_CLASSES: the
        // upstream AGXIOC ResCreate FAIL returns nil before validate is
        // reached, and when it IS reached it now returns its real result.
        // See AGENTS.md "Patch Discipline".)
#if 0
        // Discovered this session (2026-06-17) while chasing the
        // newTextureWithDescriptor:iosurface:plane: = nil failure mode:
        //
        // -[AGXTexture initWithDevice:desc:iosurface:plane:] is reached. It
        // alloc's the texture and calls [AGXG13GFamilyTexture initImplWith…]
        // which we already verified returns 1 (success) for every format WS
        // tries (BGRA8 / depth / stencil / depth32f_s8 / 2-plane '&b38').
        //
        // Then init continues past initImpl and at static 0x1e5a5afdc does:
        //     ldr  x8, [x20, #0x28]
        //     and  x2, x8, #0xffffffffffffff
        //     mov  x0, x23
        //     bl   0x1e5ab1d00            ; objc_msgSend$validateBufferTexture\
        //                                 ; WithSize:
        //     tbnz w0, #0, return_self    ; if bit-0 set → success
        //     mov  x0, x23
        //     b    0x1e5a5e010            ; → -[AGXTexture dealloc] → nil
        //
        // i.e. if `validateBufferTextureWithSize:` returns 0 the init nil-
        // exits. AGXG13GFamilyTexture's impl at 0x1e576ef94 does:
        //     ivar_off = data_21a8a9884
        //     desc     = self->ivar
        //     if (!desc->0x18a)        return 1
        //     if (desc->0x168+0x10 > arg3) return 0    ; size check
        //     ptr      = desc->0x130
        //     if (!ptr)                return 1
        //     {a,b}    = *(ptr + desc->0x168)
        //     if ((a ^ 0x99b7d4010ce3ead3) | (b ^ 0x92482f97c0394fd0) == 0)
        //                              return 1        ; magic match
        //     return 0
        //
        // The two magic constants are a guard-word at the END of an internal
        // texture-metadata blob written by the AGX firmware/kernel after
        // creation. In chroot the blob is not initialised (firmware path
        // diverges) so the magic mismatches → validate returns 0 → init
        // nil-exits → newTextureWithDescriptor:iosurface:plane: = nil →
        // SkyLight gets nil texture → WSCompositeDestinationCreateWith\
        // MetalTexture: texture=nil → VNC stays black.
        //
        // Bypass: rewrite the function's first 2 instructions:
        //     movz w0, #1   (0x52800020)
        //     ret           (0xd65f03c0)
        // (Function has no PAC prologue; safe to overwrite from byte 0.)
        //
        // Risk: validate is checking that the texture metadata footer is
        // intact. Returning YES blindly means we accept textures whose
        // metadata is wrong; later GPU draws using them may render garbage.
        // For the SkyLight CaptureSurface path (a single 2-plane scanout
        // target) that's acceptable — VNC reads the IOSurface CPU side via
        // IOSurfaceLock and we don't need the GPU metadata at all.
        //
        // LAZY: validateBufferTextureWithSize: always-YES. This silenced
        // the magic-footer (0x99b7d4010ce3ead3 / 0x92482f97c0394fd0) check
        // failure that fires when AGX firmware-written texture metadata
        // diverges in chroot. Now opt-IN via MACWS_KEEP_VALIDATE_ALWAYS=1;
        // default is to let the real check return and expose downstream
        // failure (newTextureWithDescriptor:iosurface:plane: → nil).
        // See AGENTS.md "Patch Discipline".
        if (getenv("MACWS_AGX_NATIVE") &&
            !getenv("MACWS_AGX_KEEP_VALIDATE") &&
            getenv("MACWS_KEEP_VALIDATE_ALWAYS")) {
            uint64_t fn_static = 0x1e576ef94;
            uint32_t *fn_at = (uint32_t *)(fn_static + slide);
            const uint32_t MOVZ_W0_1 = 0x52800020u;   // movz w0, #1
            const uint32_t RET        = 0xd65f03c0u;  // ret
            uint32_t cur0 = fn_at[0], cur1 = fn_at[1];
            if (cur0 == MOVZ_W0_1 && cur1 == RET) {
                fprintf(stderr,
                    "#### MACWS_AGX_VALIDATE_ALWAYS: already patched @%p\n",
                    fn_at);
            } else {
                // Sanity: expected first instruction is ADRP (the ivar load).
                BOOL is_adrp = ((cur0 & 0x9F000000) == 0x90000000);
                if (!is_adrp) {
                    fprintf(stderr,
                        "#### MACWS_AGX_VALIDATE_ALWAYS: @%p got %#x expected"
                        " ADRP — skip\n",
                        fn_at, cur0);
                } else {
                    ModifyExecutableRegion(fn_at, 8, ^{
                        fn_at[0] = MOVZ_W0_1;
                        fn_at[1] = RET;
                    });
                    fprintf(stderr,
                        "#### MACWS_AGX_VALIDATE_ALWAYS: patched @%p "
                        "(static 0x1e576ef94 + slide=%#zx) → always YES\n",
                        fn_at, (size_t)slide);
                }
            }
        }
#endif

        // ──────────────────────────────────────────────────────────────────
        // External __auth_stub patcher (MACWS_AGX_NATIVE-gated).
        //
        // The chained-fixups walker above repairs slots INSIDE this image's
        // own __got / __auth_got sections. But AGXMetal13_3 was extracted
        // from the dyld_shared_cache, and the cache builder consolidated
        // cross-image function-pointer slots (objc_msgSend, objc_msgSend\
        // Super2, libc, libobjc helpers, …) into shared __got pages OUTSIDE
        // individual images. For this binary they live at:
        //     0x21f927000..0x21f95b000     (15 pages, ~228 slots total)
        // none of which are in any segment of the extracted file.
        //
        // 228 of AGXMetal13_3's __auth_stubs reference one of these external
        // pages — the only 4 that stay in-image use 0x21e807000 (the local
        // __auth_got). Walking chained-fixups can't reach the external slots:
        // they have no fixup record because they were inlined into the cache
        // at cache-build time.
        //
        // In chroot the pages are not mapped at the runtime VA the stubs
        // compute (or they land in whatever happens to be at that VA from a
        // neighboring mapping — e.g. MediaToolbox). `ldr x16, [x17] ; braa
        // x16, x17` then reads garbage and either auth-traps or tail-calls
        // the wrong function.
        //
        // Worked example confirmed via BN macOS DSC analysis this session:
        //   stub @ 0x1e5a5dfc0 = adrp 0x21f95b000 + #0xca8 = slot 0x21f95bca8
        //   slot in cache holds &_objc_msgSendSuper2
        //   xrefs to sub_1e5a5dfc0 confirm 100+ -[…super dealloc] /
        //     [super initWith…] call sites pass through this stub
        //   in chroot the slot is wrong → super-init returns 0 →
        //     -[AGXTexture initWithDevice:desc:iosurface:plane:] nil-exits →
        //     newTextureWithDescriptor:iosurface:plane: = nil →
        //     SkyLight's framebuffer wrap fails.
        //
        // Fix: rewrite the 4-instruction stub with a direct absolute jump:
        //     movz x16, #lo16
        //     movk x16, #mid16, lsl #16
        //     movk x16, #hi16, lsl #32          ; user-space VA is 48-bit
        //     br   x16                          ; unauthenticated br
        // Same byte count (16). No PAC modulus issues; br is not authed and
        // the stub itself lives in __TEXT which we already write through
        // ModifyExecutableRegion elsewhere.
        //
        // Bootstrap the slot-offset→symbol map with the highest-value entry
        // (msgSendSuper2). Extend as more broken paths are identified by
        // crash-log triage.
        if (getenv("MACWS_AGX_NATIVE")) {
            struct stub_repair {
                uint64_t    stub_static;
                uint64_t    slot_static;   // expected adrp(page)+add(off) for logging
                const char *symbol;
            };
            static const struct stub_repair repairs[] = {
                // sub_1e5a5dfc0 — adrp 0x21f95b000 + #0xca8 = slot 0x21f95bca8.
                // Slot holds _objc_msgSendSuper2 in the macOS DSC; the stub
                // is the super-init / super-dealloc dispatcher for every
                // class in this image.
                { 0x1e5a5dfc0, 0x21f95bca8, "objc_msgSendSuper2" },
            };
            for (size_t i = 0; i < sizeof(repairs)/sizeof(repairs[0]); i++) {
                const struct stub_repair *r = &repairs[i];
                void *fn = dlsym(RTLD_DEFAULT, r->symbol);
                if (!fn) {
                    fprintf(stderr, "#### MACWS_AGX_STUB_FIX dlsym(%s)=NULL skip\n",
                        r->symbol);
                    continue;
                }
                uint32_t *stub_at      = (uint32_t *)(r->stub_static + slide);
                void    **slot_runtime = (void **)   (r->slot_static + slide);

                uint32_t cur0 = stub_at[0], cur1 = stub_at[1];
                uint32_t cur2 = stub_at[2], cur3 = stub_at[3];

                // Read slot value defensively — VA may not be mapped.
                void *cur_slot = NULL;
                Dl_info di = {0};
                int dlinfo_ok = 0;
                @try {
                    cur_slot = *slot_runtime;
                    dlinfo_ok = dladdr(cur_slot, &di);
                } @catch (id e) {
                    cur_slot = (void *)-1;
                    dlinfo_ok = 0;
                }
                fprintf(stderr,
                    "#### MACWS_AGX_STUB_FIX %s\n"
                    "####   stub@%p insns=[%08x %08x %08x %08x]\n"
                    "####   slot@%p value=%p sym=%s base=%p path=%s\n",
                    r->symbol, stub_at, cur0, cur1, cur2, cur3,
                    slot_runtime, cur_slot,
                    dlinfo_ok ? (di.dli_sname ?: "(none)") : "(no-mapping)",
                    dlinfo_ok ? di.dli_fbase : NULL,
                    dlinfo_ok ? (di.dli_fname ?: "(none)") : "(none)");

                // Build movz/movk/movk/br x16 → fn. (4 named vars, not an
                // array — blocks can't capture C arrays directly.)
                uint64_t t  = (uint64_t)fn;
                uint16_t i0 = (uint16_t)( t        & 0xFFFF);
                uint16_t i1 = (uint16_t)((t >> 16) & 0xFFFF);
                uint16_t i2 = (uint16_t)((t >> 32) & 0xFFFF);
                const uint32_t Rd = 16;   // x16
                uint32_t insn0 = 0xD2800000u | ((uint32_t)i0 << 5) | Rd; // movz x16,#i0
                uint32_t insn1 = 0xF2A00000u | ((uint32_t)i1 << 5) | Rd; // movk x16,#i1,#16
                uint32_t insn2 = 0xF2C00000u | ((uint32_t)i2 << 5) | Rd; // movk x16,#i2,#32
                uint32_t insn3 = 0xD61F0200u;                            // br   x16

                BOOL already_patched = (cur0 == insn0 && cur1 == insn1 &&
                                        cur2 == insn2 && cur3 == insn3);
                if (already_patched) {
                    fprintf(stderr, "####   already patched, skipping\n");
                    continue;
                }
                // Sanity: top of original insn must look like ADRP.
                //   ADRP encoding: bit31=1, bits28:24=10000 → mask 0x9F000000 == 0x90000000
                BOOL is_adrp = ((cur0 & 0x9F000000) == 0x90000000);
                if (!is_adrp) {
                    fprintf(stderr, "####   first insn %#x not ADRP — skip\n", cur0);
                    continue;
                }
                ModifyExecutableRegion(stub_at, 16, ^{
                    stub_at[0] = insn0;
                    stub_at[1] = insn1;
                    stub_at[2] = insn2;
                    stub_at[3] = insn3;
                });
                fprintf(stderr,
                    "####   PATCHED → br %p (movz/movk/movk/br)\n"
                    "####   new=[%08x %08x %08x %08x]\n",
                    fn, insn0, insn1, insn2, insn3);
            }
        }

        // ──────────────────────────────────────────────────────────────────
        // EVERYTHING BELOW (class registration via objc_readClassPair, AGX
        // class-method swizzles, initFull subDis fix) is gated behind
        // MACWS_AGX_REGISTER_CLASSES=1. This is the still-experimental "full
        // strict AGX-native" path. Default off so the prior stable baseline
        // (MACWS_AGX_NATIVE=1 only → MTLSim path with stable nil-tolerate
        // hooks) keeps working without regressions.
        if (!getenv("MACWS_AGX_REGISTER_CLASSES")) {
            return;
        }
        // Diagnostic: check if AGXBuffer class is registered + __objc_classrefs
        // entries are populated. The Mempool::grow lambda calls
        // objc_alloc(AGXBuffer) — if the class ref slot at __objc_classrefs is
        // null, alloc returns nil and crashes downstream at addr 0x30 (the
        // *(this+0x28) deref).
        Class agxbuf = objc_getClass("AGXBuffer");
        fprintf(stderr, "#### MACWS_AGX_NATIVE objc_getClass(AGXBuffer) = %p\n", (void *)agxbuf);

        // Read __objc_classlist — list of pointers to OUR OWN classes. If
        // libobjc didn't process them (callback skipped due to dlopen path),
        // we can register them manually.
        unsigned long classlist_sz = 0;
        uint64_t *classlist = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__objc_classlist", &classlist_sz);
        if (!classlist) {
            classlist = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__objc_classlist", &classlist_sz);
        }
        if (classlist) {
            size_t n = classlist_sz / 8;
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classlist: %zu entries\n", n);
            // Dump first 6 with class name
            for (size_t i = 0; i < n && i < 6; i++) {
                if (classlist[i] == 0) continue;
                Class c = (Class)classlist[i];
                const char *name = class_getName(c);
                fprintf(stderr, "####   classlist[%zu] = %p name=%s registered=%p\n",
                    i, (void *)c, name ?: "?", (void *)objc_getClass(name ?: ""));
            }
            // Force registration by calling _objc_init-equivalent machinery:
            // libobjc's `_dyld_objc_register_callbacks` or `_objc_map_images`.
            // Alternatively: walk __objc_classlist, for each non-null class
            // pointer, call objc_registerClassPair() — but this fails on
            // already-registered classes. Try simpler: use the runtime's
            // class_addMethod/etc on each, which forces registration as a
            // side effect.
            //
            // Most reliable: directly call libobjc's `_objc_register_classes`
            // private API if exposed.
            // The classes are in classlist as RAW DATA but not in the
            // runtime's class table. dlsym a few possible APIs to register
            // them. Failing all those, use the runtime trick of allocating
            // a temporary class pair and then PIVOTING the existing class to
            // it via objc_setClass on instances — but that's incomplete.
            //
            // Most reliable: call `objc_duplicateClass(orig_cls, new_name)`
            // to register via class duplication. Or use the dyld objc
            // notification API by re-registering ourselves.
            void (*objc_duplicate)(Class, const char *, size_t) = dlsym(
                RTLD_DEFAULT, "objc_duplicateClass");
            fprintf(stderr, "#### MACWS_AGX_NATIVE objc_duplicateClass=%p\n",
                (void *)objc_duplicate);

            // Register each class with libobjc via objc_readClassPair.
            //
            // ROOT CAUSE of `objc_getClass("AGXBuffer") = 0x0`:
            //   AGXMetal13_3 is loaded by Metal.framework's eager constructor
            //   BEFORE libmachook's loadImageCallback can run. In a normal
            //   process flow, libobjc's _dyld_objc_notify_register callback
            //   processes __objc_classlist and adds each class to
            //   gdb_objc_realized_classes (the name → class hash). But in
            //   chroot, that processing never reached the AGXMetal13_3 entries
            //   (likely because Metal loads AGXMetal13_3 via a private dyld
            //   path that bypasses the notify hook, or because the load order
            //   races with libmachook's pre-load IOGPU dlopen).
            //
            //   Result: class STRUCT DATA is fully valid — class_getName,
            //   class_getSuperclass, class_isMetaClass all work — but
            //   objc_getClass(name) returns NULL because the name table was
            //   never populated.
            //
            // FIX: walk __objc_classlist, call objc_readClassPair on each
            //   entry. objc_readClassPair both calls readClass (which adds to
            //   gdb_objc_realized_classes) and realizeClassWithoutSwift (which
            //   sets up the cache / method tables). After this loop completes,
            //   objc_getClass("AGXBuffer") returns the right pointer and
            //   [AGXBuffer alloc] returns a real, usable instance.
            //
            // Get __objc_imageinfo (required arg to objc_readClassPair).
            typedef struct { uint32_t version; uint32_t flags; } objc_image_info_t;
            unsigned long iinfo_sz = 0;
            objc_image_info_t *iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__DATA_CONST", "__objc_imageinfo", &iinfo_sz);
            if (!iinfo) iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__DATA", "__objc_imageinfo", &iinfo_sz);
            if (!iinfo) iinfo = (objc_image_info_t *)getsectiondata(
                (const struct mach_header_64 *)header,
                "__OBJC", "__image_info", &iinfo_sz);
            fprintf(stderr, "#### MACWS_AGX_NATIVE imageinfo=%p sz=%lu\n",
                (void *)iinfo, iinfo_sz);

            typedef Class (*readPair_t)(Class, const void *);
            readPair_t readPair = (readPair_t)dlsym(RTLD_DEFAULT, "objc_readClassPair");
            int realized = 0;
            // Cross-image preregistration: previously this loop only walked
            // AGXMetal13_3's own __objc_classlist, so a class whose superclass
            // lives in another framework (e.g. AGXBuffer -> IOGPUMetalBuffer in
            // IOGPU.framework) failed because readClassPair needs the super to
            // already be in libobjc's name table. In chroot, the libobjc
            // _dyld_objc_notify_register callback misses IOGPU's classlist for
            // the same reason it misses AGXMetal's — so we have to register
            // every loaded image's pending classes here, not just our own.
            // Walks _dyld_image_count() and, for any image carrying a
            // __objc_classlist + __objc_imageinfo, runs the same multi-pass
            // readPair loop. IOGPU goes first because it's a parent of
            // AGXBuffer/AGXG13GFamilyBuffer/AGXG13GFamilyCommandBuffer/…
            // Per-image cap of 8 passes catches deep super chains.
            if (readPair) {
                uint32_t img_count = _dyld_image_count();
                for (uint32_t img_i = 0; img_i < img_count; img_i++) {
                    const struct mach_header *imgh = _dyld_get_image_header(img_i);
                    if (!imgh) continue;
                    const char *imgname = _dyld_get_image_name(img_i);
                    unsigned long cl_sz = 0;
                    uint64_t *cl = (uint64_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA_CONST",
                        "__objc_classlist", &cl_sz);
                    if (!cl) cl = (uint64_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA",
                        "__objc_classlist", &cl_sz);
                    if (!cl || cl_sz == 0) continue;
                    unsigned long ii_sz = 0;
                    objc_image_info_t *ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA_CONST",
                        "__objc_imageinfo", &ii_sz);
                    if (!ii) ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__DATA",
                        "__objc_imageinfo", &ii_sz);
                    if (!ii) ii = (objc_image_info_t *)getsectiondata(
                        (const struct mach_header_64 *)imgh, "__OBJC",
                        "__image_info", &ii_sz);
                    if (!ii) continue;
                    size_t nn = cl_sz / 8;
                    int img_realized = 0;
                    int img_pending = 0;
                    for (size_t i = 0; i < nn; i++) {
                        if (cl[i] == 0) continue;
                        Class cc = (Class)cl[i];
                        const char *nm = class_getName(cc);
                        if (nm && nm[0] && !objc_getClass(nm)) img_pending++;
                    }
                    if (img_pending == 0) continue;
                    for (int pass = 0; pass < 8; pass++) {
                        int tp = 0;
                        for (size_t i = 0; i < nn; i++) {
                            if (cl[i] == 0) continue;
                            Class cc = (Class)cl[i];
                            const char *nm = class_getName(cc);
                            if (!nm || !nm[0]) continue;
                            if (objc_getClass(nm)) continue;
                            Class rr = readPair(cc, ii);
                            if (rr && objc_getClass(nm)) { img_realized++; tp++; }
                        }
                        if (tp == 0) break;
                    }
                    realized += img_realized;
                    const char *bn = strrchr(imgname ? imgname : "", '/');
                    bn = bn ? bn + 1 : (imgname ? imgname : "?");
                    if (img_realized > 0) {
                        fprintf(stderr,
                            "#### PREREGISTER image[%u] %s: %d/%d realized\n",
                            img_i, bn, img_realized, img_pending);
                    }
                }
            }
            // Now also try AGXMetal13_3's own classlist (most should already be
            // realized by the loop above since this image is in img_count too,
            // but the original multi-pass below catches any leftover surface).
            if (readPair && iinfo) {
                // Multi-pass: re-iterate if any new classes registered, so a
                // class whose superclass got registered in pass N can register
                // in pass N+1.
                for (int pass = 0; pass < 3; pass++) {
                    int this_pass = 0;
                    for (size_t i = 0; i < n; i++) {
                        if (classlist[i] == 0) continue;
                        Class c = (Class)classlist[i];
                        const char *name = class_getName(c);
                        if (!name || !name[0]) continue;
                        if (objc_getClass(name)) continue;  // registered
                        Class result = readPair(c, iinfo);
                        if (result && objc_getClass(name)) {
                            realized++;
                            this_pass++;
                            if (realized < 6) {
                                fprintf(stderr, "####   registered %s -> %p\n",
                                    name, (void *)result);
                            }
                        } else {
                            if (i < 6 && pass == 0) {
                                fprintf(stderr, "####   FAILED %s: result=%p getClass=%p\n",
                                    name, (void *)result, (void *)objc_getClass(name));
                            }
                        }
                    }
                    fprintf(stderr, "#### MACWS_AGX_NATIVE register pass %d: %d new (total %d)\n",
                        pass, this_pass, realized);
                    if (this_pass == 0) break;
                }
            } else {
                fprintf(stderr, "#### MACWS_AGX_NATIVE readPair=%p iinfo=%p — CANNOT REGISTER\n",
                    (void *)readPair, (void *)iinfo);
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE realized %d/%zu classes\n", realized, n);
            Class agxbuf_after = objc_getClass("AGXBuffer");
            fprintf(stderr, "#### MACWS_AGX_NATIVE AGXBuffer after register: %p\n",
                (void *)agxbuf_after);
            // Also try sending +alloc to verify the registered class is usable.
            if (agxbuf_after) {
                @try {
                    id inst = ((id (*)(id, SEL))objc_msgSend)(
                        (id)agxbuf_after, sel_registerName("alloc"));
                    fprintf(stderr, "#### MACWS_AGX_NATIVE [AGXBuffer alloc] = %p\n",
                        (void *)inst);
                } @catch (NSException *e) {
                    fprintf(stderr, "#### MACWS_AGX_NATIVE [AGXBuffer alloc] threw: %s\n",
                        [[e description] UTF8String] ?: "?");
                }

                // Swizzle initUntrackedInternalBufferWithDevice:length:options:
                // and initWithDevice:length:alignment:options:isSuballocDisabled:
                // resourceInArgs:pinnedGPULocation: so we can trace what these
                // return in the AGX::Mempool::grow lambda hot path. If they
                // return nil, Mempool+0x8 stays NULL and setupDeferred crashes
                // dereferencing it at addr 0x30. Tracing tells us whether the
                // problem is alloc-side (class invalid) or IOGPU-side (kernel
                // resource creation fails).
                SEL initUntracked = sel_registerName("initUntrackedInternalBufferWithDevice:length:options:");
                Method m_unt = class_getInstanceMethod(agxbuf_after, initUntracked);
                if (m_unt) {
                    IMP orig_unt = method_getImplementation(m_unt);
                    IMP trace_unt = imp_implementationWithBlock(^id(id self, id dev, unsigned long len, unsigned long opt) {
                        id r = ((id (*)(id, SEL, id, unsigned long, unsigned long))orig_unt)(
                            self, initUntracked, dev, len, opt);
                        fprintf(stderr,
                            "#### TRACE -[AGXBuffer initUntracked] self=%p dev=%p len=%lu opt=%lu -> %p\n",
                            self, dev, len, opt, r);
                        return r;
                    });
                    method_setImplementation(m_unt, trace_unt);
                    fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled initUntrackedInternalBufferWithDevice:length:options:\n");
                }
                SEL initFull = sel_registerName("initWithDevice:length:alignment:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:");
                Method m_full = class_getInstanceMethod(agxbuf_after, initFull);
                if (m_full) {
                    IMP orig_full = method_getImplementation(m_full);
                    IMP trace_full = imp_implementationWithBlock(^id(id self, id dev, unsigned long len, unsigned long align, unsigned long opt, int subDis, void *resInArgs, void *pinned) {
                        // Capture class BEFORE orig in case it releases self.
                        Class pre_cls_full = object_getClass(self);
                        // iOS IOGPU's kernel sub-resource creation rejects
                        // align=1 with kIOReturnExclusiveAccess (0xe00002c2)
                        // for every length tier — Mempool::grow's freelist
                        // columns (len=64/384), QuartzCore staging buffers
                        // (len=8192), MetalContext scratch (len=131072), …
                        // all fail in chroot with align=1. Forcing align=64 +
                        // isSuballocDisabled=1 routes through the standalone-
                        // heap branch which the kernel accepts at any size.
                        // Confirmed 2026-06-18 by side-by-side trace.
                        //
                        // Side effect: the standalone branch creates a fresh
                        // heap, so each align=1 AGXBuffer now pays a heap-
                        // alloc syscall instead of a sub-resource slot from
                        // an existing heap. That's a slowdown but not a
                        // correctness issue for chroot WS.
                        int subDis_eff = subDis;
                        unsigned long align_eff = align;
                        if (align <= 1) {
                            align_eff = 64;
                            // isSuballocDisabled=1 routes through standalone-
                            // heap branch which the kernel accepts for any
                            // size when align=1 in chroot. BUT for medium-
                            // large lengths (>= 64KB) the standalone branch
                            // ends up using the device's small default heap
                            // (clientID 0x4000, 4KB) as parent and the
                            // sub-resource creation fails because the parent
                            // is too small. The medium/large align=1 callers
                            // (QuartzCore staging buffers) work fine with
                            // subDis=0 + align=64 because macOS's normal
                            // sub-resource path picks the right big heap.
                            // Cap the subDis=1 forcing at len<64KB.
                            if (len < 0x10000) subDis_eff = 1;
                        }
                        id r = ((id (*)(id, SEL, id, unsigned long, unsigned long, unsigned long, int, void *, void *))orig_full)(
                            self, initFull, dev, len, align_eff, opt, subDis_eff, resInArgs, pinned);
                        if (!r && (subDis_eff != subDis || align_eff != align)) {
                            // Forced path failed; retry with original args.
                            r = ((id (*)(id, SEL, id, unsigned long, unsigned long, unsigned long, int, void *, void *))orig_full)(
                                self, initFull, dev, len, align, opt, subDis, resInArgs, pinned);
                        }
                        // Mempool::grow's freelist-init loop reads
                        // `*(buf + global + 0x18)` (= *(buf+0x30) with the
                        // global symbol IOGPU.IOGPUMetalResource._res = 0x18)
                        // and writes sequential ints there. For our synth
                        // path we already populate that ivar from baseAddr.
                        // For the "orig-succeed" path (small buffers via
                        // align=64+subDis=1), the buf comes back with all
                        // ivars zero — including +0x30 — and Mempool's freelist
                        // init then null-derefs. Allocate a per-buf scratch
                        // (4 KB) and point +0x30 at it so the freelist init
                        // writes land in valid memory. Use malloc since the
                        // GPU never touches this region (it's freelist
                        // bookkeeping, not buffer contents).
                        if (r && ((void **)r)[6] == NULL) {
                            // 16 KB is enough for sequential-int freelist init
                            // (~15 entries) plus memcpy-grow expansion of the
                            // Mempool's internal counters. dealloc later free()s
                            // this pointer — AGX driver writes sentinel values
                            // (e.g. 0x1) into it for its own freelist tracking,
                            // which corrupts the default malloc free list on
                            // dealloc. Route through a private zone so the
                            // corruption stays isolated and the default zone's
                            // free list stays intact.
                            malloc_zone_t *zone = macws_synth_scratch_zone();
                            void *scratch = zone ?
                                malloc_zone_calloc(zone, 1, 16384) :
                                calloc(1, 16384);
                            if (scratch) {
                                ((void **)r)[6] = scratch;
                                static int fl_log = 0;
                                if (fl_log++ < 4) {
                                    fprintf(stderr,
                                        "#### initFull freelist-scratch: buf=%p ivar+0x30 ← %p (private-zone)\n",
                                        r, scratch);
                                }
                            }
                        }
                        // PIN-FALLBACK (MACWS_PIN_FALLBACK=1): when the 7-arg
                        // initFull returns nil (chroot kernel rejected the
                        // resInArgs-shaped IOConnect call), try the 6-arg
                        // `initWithDevice:length:options:isSuballocDisabled:
                        // pinnedGPULocation:` variant that PinnedVAProbe proved
                        // works in iOS-native userland end-to-end (alloc +
                        // compute write-through + blit roundtrip — see
                        // [[pinned-gpu-va-exists-in-ios-userland]]). The
                        // pinnedGPULocation: argument is a pointer to a u64
                        // holding the desired GPU VA; passing 0 lets the
                        // framework pick. Logs both empirical signal (does it
                        // work in chroot at all?) and wires up a real fallback
                        // if it does.
                        if (!r && getenv("MACWS_PIN_FALLBACK")) {
                            static SEL pin5_sel = NULL;
                            static int pin5_known_missing = 0;
                            if (!pin5_sel) {
                                pin5_sel = sel_registerName(
                                    "initWithDevice:length:options:isSuballocDisabled:pinnedGPULocation:");
                            }
                            // pre_cls_full was captured at block entry before
                            // orig consumed self (object_getClass(self) returns
                            // nil after orig freed self).
                            Class cls = pre_cls_full ?: object_getClass(self);
                            if (!pin5_known_missing && cls &&
                                class_getInstanceMethod(cls, pin5_sel)) {
                                // Fresh +alloc: the failed initFull consumed `self`.
                                id raw = ((id (*)(Class, SEL))objc_msgSend)(
                                    cls, sel_registerName("alloc"));
                                uint64_t pinVA = 0;  // framework picks
                                typedef id (*Pin5Fn)(id, SEL, id, unsigned long,
                                                      unsigned long, int, uint64_t *);
                                Pin5Fn pin5 = (Pin5Fn)objc_msgSend;
                                id pr = pin5(raw, pin5_sel, dev, len, opt, 1, &pinVA);
                                static int fb_log = 0;
                                if (fb_log++ < 12) {
                                    fprintf(stderr,
                                        "#### PIN_FALLBACK %s len=%lu opt=%lu -> %p (pinVA=%#llx)\n",
                                        class_getName(cls), len, opt,
                                        (void *)pr, (unsigned long long)pinVA);
                                }
                                if (pr) r = pr;
                            } else if (!pin5_known_missing) {
                                pin5_known_missing = 1;
                                fprintf(stderr,
                                    "#### PIN_FALLBACK: class %s does NOT respond to 5-colon pinnedGPULocation: selector\n",
                                    cls ? class_getName(cls) : "(nil)");
                            }
                        }
                        static int trace_cnt = 0;
                        if (trace_cnt++ < 12) {
                            fprintf(stderr,
                                "#### TRACE -[AGXBuffer initFull] self=%p dev=%p len=%lu align=%lu→%lu opt=%lu subDis=%d→%d resIn=%p pin=%p -> %p\n",
                                self, dev, len, align, align_eff, opt, subDis, subDis_eff, resInArgs, pinned, r);
                        }
                        return r;
                    });
                    method_setImplementation(m_full, trace_full);
                    fprintf(stderr, "#### MACWS_AGX_NATIVE swizzled initWithDevice:length:alignment:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:\n");
                }

                // 2026-06-19 — `finalizeTextureCreation` no-op on
                // AGXG13GFamilyBuffer.
                //
                // lldb caught chroot WS dying via objc_exception_throw with
                // reason `-[AGXG13GFamilyBuffer finalizeTextureCreation]:
                // unrecognized selector`. Backtrace:
                //   AGXTexture::initWithDevice:desc:isSuballocDisabled: +632
                //   SkyLight MetalTiledBacking::PrepareForUse + 528
                //   SkyLight CompositorMetal::composite ...
                //
                // RE shows AGXTexture +636 does `mov x0, x19; bl
                // objc_msgSend$finalizeTextureCreation` where x19 came from
                // an earlier `bl objc_msgSendSuper2` at +540. The super-init
                // returned an AGXG13GFamilyBuffer (instead of an
                // AGXG13GFamilyTexture) — probably because our PIN_FALLBACK
                // or CODEHEAP-SHIM intercept of -[IOGPUMetalResource
                // initWith...args:argsSize:] is sometimes also crossed by
                // a texture super-init path (both share that 4-arg init in
                // the AGXResource class hierarchy).
                //
                // `finalizeTextureCreation` is normally only declared on
                // AGXTexture / AGXG13GFamilyTexture (image lookup confirmed
                // — only two implementations in AGXMetal13_3). Adding a
                // no-op to AGXG13GFamilyBuffer keeps the AGXTexture init
                // moving forward when its super-init returns a Buffer-class
                // instance instead of a Texture-class one. Real
                // AGXG13GFamilyTexture instances STILL get the real method
                // via normal dispatch.
                {
                    Class kBuf = objc_getClass("AGXG13GFamilyBuffer");
                    if (kBuf) {
                        SEL sel_ftc = sel_registerName("finalizeTextureCreation");
                        IMP noop_ftc = imp_implementationWithBlock(^void(id self){
                            static int once = 0;
                            if (once++ < 6) {
                                fprintf(stderr,
                                    "#### finalizeTextureCreation no-op on AGXG13GFamilyBuffer self=%p cls=%s\n",
                                    self, object_getClass(self) ? class_getName(object_getClass(self)) : "(nil)");
                            }
                        });
                        BOOL added = class_addMethod(kBuf, sel_ftc, noop_ftc, "v@:");
                        fprintf(stderr,
                            "#### MACWS_AGX_NATIVE class_addMethod(AGXG13GFamilyBuffer, finalizeTextureCreation) = %d\n",
                            added);
                    }
                }

                // -[AGXBuffer initWithDevice:options:args:argsSize:] — the
                // 4-arg init called from inside `AGX::Heap<true>::allocateImpl`
                // (setupCompiler:'s CodeHeap dispatch_sync block). Runtime
                // lldb backtrace 2026-06-19:
                //   frame#3 AGX::Heap<true>::allocateImpl block_invoke +596
                //   frame#2 -[IOGPUMetalResource initWithDevice:remoteStorageResource:options:args:argsSize:] +460
                //   frame#1 IOGPUResourceCreate +236
                //   frame#0 IOConnectCallMethod sel=0xa → kernel 0xe00002c2
                // Pin-fallback approach: when orig returns nil (cascading from
                // IOConnect rejection), synthesize via the 6-arg `pinnedGPULocation:`
                // selector PinnedVAProbe proved works in iOS-native userland.
                // Size is extracted from args+0x58 sz32 field (the heap byte-
                // count macOS writes there before this init).
                {
                    SEL initArgs = sel_registerName("initWithDevice:options:args:argsSize:");
                    Method m_args = class_getInstanceMethod(agxbuf_after, initArgs);
                    if (m_args && getenv("MACWS_PIN_FALLBACK")) {
                        IMP orig_args = method_getImplementation(m_args);
                        IMP shim_args = imp_implementationWithBlock(^id(
                                id self, id dev, unsigned long opt,
                                void *args, unsigned long argsSize) {
                            // Capture class BEFORE orig — orig may release self
                            // and corrupt its isa on failure (object_getClass(self)
                            // then returns nil), making the post-orig fallback
                            // unable to identify the class.
                            Class pre_cls = object_getClass(self);
                            static int entry_log = 0;
                            if (entry_log++ < 4) {
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM entry self=%p cls=%s dev=%p opt=%#lx args=%p argsSize=%lu\n",
                                    self, pre_cls ? class_getName(pre_cls) : "(nil)",
                                    dev, opt, args, argsSize);
                            }
                            // 2026-06-22 — KernelUserShared fix (RE-confirmed via
                            // AGXMetal13_3+IOGPU+kernel disasm). -[IOGPUMetalResource
                            // initWithDevice:options:args:argsSize:] sets
                            // args+0x14 |= 0x10000 (kIOMemoryKernelUserShared) IFF
                            // (options & 0x40000); IOGPUSysMemory::withOptions then
                            // turns that into a full kernel-user-shared CPU mapping.
                            // Without it the iOS kernel only hands back the one-page
                            // ClientShared region → 16KB -contents → blur overruns.
                            // macOS CA/AGX never sets 0x40000 in the chroot. Force it
                            // on (heap + buffer creates both flow through here) so
                            // resources get FULL CPU-coherent mappings. Gated
                            // /tmp/macws_kusershare for A/B; promote to always-on once
                            // confirmed.
                            if (access("/tmp/macws_kusershare", F_OK) == 0 ||
                                getenv("MACWS_KUSERSHARE")) {
                                static int kus_log = 0;
                                if (kus_log++ < 4)
                                    fprintf(stderr,
                                        "#### KUSERSHARE: opt %#lx -> %#lx (set 0x40000 = request KernelUserShared)\n",
                                        opt, opt | 0x40000UL);
                                opt |= 0x40000UL;
                            }
                            id r = ((id (*)(id, SEL, id, unsigned long, void *, unsigned long))orig_args)(
                                self, initArgs, dev, opt, args, argsSize);
                            static int post_log = 0;
                            if (post_log++ < 4) {
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM post-orig: r=%p (orig %s)\n",
                                    r, r ? "non-nil" : "nil — entering synth");
                            }
                            if (r) return r;
                            // 2026-06-19 — texture super-init that reaches here
                            // means even AFTER the widened VA-shape patch the
                            // orig still returned nil. Log args ONCE per process
                            // for follow-up RE so we know if the patch missed a
                            // case. Then continue into the existing synth path
                            // (best-effort). This rarely fires now.
                            const char *pre_name = pre_cls ? class_getName(pre_cls) : "(nil)";
                            if (pre_name && strstr(pre_name, "Texture")) {
                                static int diag_once = 0;
                                if (!diag_once++) {
                                    fprintf(stderr,
                                        "#### CODEHEAP-SHIM POST-VAFIX texture-orig-nil pre_cls=%s "
                                        "args@%p argsSize=%lu — VA-shape patch did NOT cover this case\n",
                                        pre_name, args, argsSize);
                                    if (args && argsSize <= 0x200) {
                                        const uint8_t *a = (const uint8_t *)args;
                                        for (size_t i = 0; i < argsSize; i += 16) {
                                            fprintf(stderr, "####   args+%#04zx:", i);
                                            for (size_t j = 0; j < 16 && i + j < argsSize; j++) {
                                                fprintf(stderr, " %02x", a[i + j]);
                                            }
                                            fprintf(stderr, "\n");
                                        }
                                    }
                                }
                            }
                            // PIN-FALLBACK path. Use pre_cls (captured before orig)
                            // — orig consumed self, so object_getClass(self) now
                            // returns nil.
                            Class cls = pre_cls;
                            Class kFam = objc_getClass("AGXG13GFamilyBuffer");
                            Class target = kFam ?: cls;
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM synth-step1: kFam=%p (%s) target=%s\n",
                                kFam, kFam ? class_getName(kFam) : "(nil)",
                                target ? class_getName(target) : "(nil)");
                            static SEL pin5_sel = NULL;
                            if (!pin5_sel) pin5_sel = sel_registerName(
                                "initWithDevice:length:options:isSuballocDisabled:pinnedGPULocation:");
                            BOOL responds = class_getInstanceMethod(target, pin5_sel) != NULL;
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM synth-step2: %s responds to pin5? %d\n",
                                target ? class_getName(target) : "(nil)", responds);
                            if (!responds) {
                                static int log_once = 0;
                                if (!log_once++) {
                                    fprintf(stderr,
                                        "#### CODEHEAP-SHIM: %s does NOT respond to 5-colon pinnedGPULocation:\n",
                                        target ? class_getName(target) : "(nil)");
                                }
                                return nil;
                            }
                            uint64_t sz = 0;
                            if (args && argsSize >= 0x60) {
                                const uint8_t *a = (const uint8_t *)args;
                                // args+0x58 sz32 is what the existing heap fixup
                                // reads as the requested byte-count. Confirmed by
                                // runtime dump: args+0x58=0x38000000 for the
                                // setupCompiler CodeHeap allocation.
                                sz = (uint64_t)*(const uint32_t *)(a + 0x58);
                                // Safety cap at 256 MB — even if 0x38000000 (939 MB)
                                // is what macOS asks for, iOS-native CodeHeap rarely
                                // exceeds 64 MB, and oversizing on the iOS path may
                                // get rejected for separate reasons (kernel VA quota).
                                // 2026-06-19 — Empirically iOS IOSurface backing
                                // for >16MB allocations: macwsallocd creates the
                                // surface and returns port+id, but chroot's
                                // IOSurfaceLookup + IOSurfaceLookupFromMachPort
                                // BOTH return nil. Smaller (<= 16MB) round-trip
                                // fine. Cap at 16MB so synth-step3 reliably
                                // succeeds and downstream gets a real IOSurface.
                                if (sz > 0x1000000ULL) sz = 0x1000000ULL;
                                if (sz < 0x10000ULL)    sz = 0x10000ULL;
                            }
                            if (!sz) sz = 0x10000;
                            // pinnedGPULocation: ALSO routes through IOConnect
                            // sel=0xa internally and the iOS kernel rejects it
                            // the same way for chroot WS. Skip that path. The
                            // working approach is: ask iOS-native helper to
                            // allocate an IOSurface (kernel-blessed shared GPU
                            // memory), receive the mach send-right back, then
                            // wrap as a buffer using bytes/length init (which
                            // takes a CPU pointer and doesn't need sel=0xa).
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM synth-step3: requesting IOSurface from helper sz=%#llx\n",
                                (unsigned long long)sz);
                            uint64_t alloc_size = 0;
                            uint32_t iosurfid = 0;
                            mach_port_t surfPort = macws_alloc_iosurf_xpc(
                                sz, opt, &alloc_size, &iosurfid);
                            if (surfPort == MACH_PORT_NULL && iosurfid == 0) {
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM synth-step3 FAIL: alloc helper returned no surface\n");
                                return ((id (*)(Class, SEL))objc_msgSend)(
                                    target, sel_registerName("alloc"));
                            }
                            // 2026-06-19 — Per-task IOSurfaceClient's
                            // IOSurfaceLookupFromMachPort does NOT resolve
                            // send-rights created in a different task
                            // (runtime-confirmed: chroot local-test
                            // roundtrip works, cross-process returns nil).
                            // The IsGlobal=YES surface is reachable via the
                            // global IOSurfaceLookup(int id) table — try
                            // that first.
                            extern IOSurfaceRef IOSurfaceLookup(uint32_t id);
                            IOSurfaceRef surf = NULL;
                            if (iosurfid) {
                                surf = IOSurfaceLookup(iosurfid);
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM IOSurfaceLookup(id=%u) -> %p\n",
                                    iosurfid, (void *)surf);
                            }
                            if (!surf && surfPort != MACH_PORT_NULL) {
                                surf = IOSurfaceLookupFromMachPort(surfPort);
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM fallback IOSurfaceLookupFromMachPort(port=%u) -> %p\n",
                                    surfPort, (void *)surf);
                            }
                            if (surfPort != MACH_PORT_NULL)
                                mach_port_deallocate(mach_task_self(), surfPort);
                            if (!surf) {
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM synth-step3 FAIL: "
                                    "IOSurfaceLookup id=%u + LookupFromMachPort port=%u both returned nil\n",
                                    iosurfid, surfPort);
                                return ((id (*)(Class, SEL))objc_msgSend)(
                                    target, sel_registerName("alloc"));
                            }
                            void *baseAddr = IOSurfaceGetBaseAddress(surf);
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM synth-step4: IOSurface=%p baseAddr=%p alloc_size=%llu\n",
                                (void *)surf, baseAddr, (unsigned long long)alloc_size);
                            // Install the class-wide synth overrides on the
                            // target class once. From now on, instances tagged
                            // with kSynthMarkerKey respond with our values to
                            // -resourceSize / -length / -contents /
                            // -virtualAddress / -gpuAddress / -device. Untagged
                            // instances see the original impls (passthrough).
                            macws_install_synth_overrides(target);
                            // Alloc a bare instance — no init — so isa is the
                            // target class but ivars are zero (we don't use
                            // them, the overrides read associated objects).
                            id pr = ((id (*)(Class, SEL))objc_msgSend)(
                                target, sel_registerName("alloc"));
                            if (!pr) {
                                fprintf(stderr,
                                    "#### CODEHEAP-SHIM synth-step5 FAIL: alloc returned nil\n");
                                CFRelease((CFTypeRef)surf);
                                return nil;
                            }
                            // Tag + attach backing values. We pretend gpuAddress
                            // equals the CPU base address; chroot's GPU can't
                            // reach this VA but downstream code will surface
                            // the next cascade so we can plan from there.
                            objc_setAssociatedObject(pr, &kSynthMarkerKey,
                                @"SYNTH", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(pr, &kSynthContentsKey,
                                [NSValue valueWithPointer:baseAddr],
                                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(pr, &kSynthLengthKey,
                                @((NSUInteger)alloc_size),
                                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(pr, &kSynthGpuAddrKey,
                                @((uint64_t)(uintptr_t)baseAddr),
                                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(pr, &kSynthDeviceKey,
                                dev, OBJC_ASSOCIATION_ASSIGN);
                            // Retain the IOSurface via association so it stays
                            // alive as long as the buffer does.
                            objc_setAssociatedObject(pr, &kSynthSurfaceKey,
                                (__bridge id)surf,
                                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            CFRelease((CFTypeRef)surf);
                            // Mempool::grow's freelist-init loop loads from
                            // `*(buf + global + 0x18)` where global = 0x18
                            // (confirmed via lldb 2026-06-19, value at
                            // `IOGPU\`IOGPUMetalResource._res`). So the
                            // freelist target is at ivar offset 0x30. For
                            // a non-synth buffer this is set by the real init
                            // to a chunk freelist pointer that the buf's
                            // dealloc later free()s. The IOSurface base
                            // can NOT go here (libmalloc detects non-malloc
                            // address → checksum_botch → abort on dealloc).
                            // AGX driver also writes sentinel values
                            // (e.g. 0x1) into this buffer for its OWN freelist
                            // tracking, which then corrupts the default
                            // malloc free list when the buffer is dealloc'd.
                            // Route through a private zone so the corruption
                            // stays here — nothing else allocates from this
                            // zone, so tiny_malloc_from_free_list iterations
                            // in the DEFAULT zone never touch it.
                            // 16 KB suffices for sequential-int freelist
                            // init + later memcpy grow operations.
                            malloc_zone_t *zone = macws_synth_scratch_zone();
                            ((void **)pr)[6] = zone ?
                                malloc_zone_calloc(zone, 1, 16384) :
                                calloc(1, 16384);
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM ivar+0x30 = scratch (%p, 16K, private-zone) — Mempool freelist target\n",
                                ((void **)pr)[6]);
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM (%s) iosurf-synth len=%llu base=%p -> %p\n",
                                class_getName(target),
                                (unsigned long long)alloc_size, baseAddr, (void *)pr);
                            return pr;
                        });
                        method_setImplementation(m_args, shim_args);
                        fprintf(stderr,
                            "#### MACWS_PIN_FALLBACK swizzled -[AGXBuffer initWithDevice:options:args:argsSize:]\n");
                    }
                }
            }

            // Probe what libobjc class-registration symbols are exposed in this
            // libobjc build. Goal: find a callable function that takes a
            // pre-existing class struct (from __objc_classlist) and adds it
            // to gdb_objc_realized_classes (name → class map). Without that
            // table entry, objc_getClass(name) returns NULL even though the
            // class data exists at a known pointer.
            const char *libobjc_apis[] = {
                "objc_addClass",
                "_objc_addClass",
                "_objc_addClass_quiet",
                "objc_constructInstance",
                "_dyld_objc_notify_register",
                "_dyld_objc_register_callbacks",
                "_objc_loadDebug",
                "objc_readClassPair",
                "objc_registerClassPair",
                "_objc_register_class",
                "_objc_realizeClassFromSwift",
                "objc_realizeClassFromSwift",
                "_objc_addLoadImageFunc",
                "objc_addLoadImageFunc",
                "_objc_swiftMetadataInitializer",
                "_objc_remappedClasses",
                "_read_images",
                "map_images",
                "map_images_nolock",
                "_objc_init",
                NULL
            };
            for (int i = 0; libobjc_apis[i]; i++) {
                void *p = dlsym(RTLD_DEFAULT, libobjc_apis[i]);
                if (p) fprintf(stderr, "#### LIBOBJC dlsym(%s) = %p\n",
                                libobjc_apis[i], p);
            }

            // For each AGX class we found, dump:
            //   class ptr, name, superclass ptr, superclass name (if reachable),
            //   isMeta flag, classref-target-name.
            // This pinpoints whether class structs are corrupt or whether it's
            // purely a name-table miss.
            for (size_t i = 0; i < n && i < 16; i++) {
                if (classlist[i] == 0) continue;
                Class c = (Class)classlist[i];
                const char *name = class_getName(c);
                Class sc = class_getSuperclass(c);
                const char *scname = sc ? class_getName(sc) : "(nil)";
                BOOL meta = class_isMetaClass(c);
                fprintf(stderr,
                    "#### CLASS_DETAIL [%zu] %p name=%s super=%p (%s) meta=%d\n",
                    i, (void *)c, name ?: "?", (void *)sc, scname ?: "?", meta);
            }
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classlist NOT FOUND\n");
        }
        // Walk __objc_classrefs section: read each pointer entry.
        unsigned long classrefs_sz = 0;
        uint64_t *classrefs = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA", "__objc_classrefs", &classrefs_sz);
        if (classrefs) {
            size_t n = classrefs_sz / 8;
            int nulls = 0;
            for (size_t i = 0; i < n; i++) {
                if (classrefs[i] == 0) nulls++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __objc_classrefs: %zu entries, %d null\n", n, nulls);
            // Try to fix nulls by reading class name from neighboring metadata
            // and replacing with objc_getClass result. We don't have direct
            // mapping from classref slot to class name in stripped binaries —
            // but we have ALL OUR OWN classes in __objc_classlist which IS
            // populated. So our best bet is: dlsym OBJC_CLASS_$_NAME for known
            // AGX classes and patch their slot.
            const char *known_agx_classes[] = {
                "AGXBuffer",
                "AGXCommandQueue",
                "AGXCommandBuffer",
                "AGXMetalCommandQueue",
                "AGXMetalCommandBuffer",
                "AGXMetalBuffer",
                "AGXMetalTexture",
                "AGXMetalHeap",
                "AGXMetalResource",
                "AGXMetalDevice",
                "AGXMetalFence",
                "AGXTexture",
                "IOGPUMetalBuffer",
                "IOGPUMetalCommandBuffer",
                "IOGPUMetalCommandQueue",
                "IOGPUMetalDevice",
                "IOGPUMetalHeap",
                "IOGPUMetalResource",
                "IOGPUMetalTexture",
                "IOGPUMetalFence",
                "IOGPUMTLLateEvalEvent",
                NULL
            };
            for (int i = 0; known_agx_classes[i]; i++) {
                Class c = objc_getClass(known_agx_classes[i]);
                fprintf(stderr, "####   class %s = %p\n", known_agx_classes[i], (void *)c);
            }
            // Dump first 16 classrefs: deref each pointer, get class_getName.
            // If class_getName returns valid AGX name → classref points to OUR
            // class data (the bind worked, the slot just isn't realized in
            // libobjc's name table). If name is junk or addr is bad → bind
            // never happened and the slot points to stale/null garbage.
            for (size_t i = 0; i < n && i < 24; i++) {
                uint64_t cp = classrefs[i];
                if (cp == 0) {
                    fprintf(stderr, "#### CLASSREF [%zu] @%p = NULL\n",
                        i, (void *)&classrefs[i]);
                    continue;
                }
                const char *nm = "?";
                @try {
                    nm = class_getName((Class)cp) ?: "?";
                } @catch (NSException *e) {
                    nm = "(crash)";
                }
                fprintf(stderr, "#### CLASSREF [%zu] @%p -> %p name=%s\n",
                    i, (void *)&classrefs[i], (void *)cp, nm);
            }
        }

        // Walk LC_DYLD_CHAINED_FIXUPS and patch each null import bind by
        // resolving the symbol via dlsym(RTLD_DEFAULT). This repairs the
        // cross-image bindings that chroot dyld failed to resolve at load
        // time (especially IOGPU symbols). After this runs, the lambda in
        // Mempool::grow can safely tail-call its target.
        macws_walk_chained_fixups((const struct mach_header_64 *)header, vmaddr_slide, "AGXMetal13_3");

        // Diagnostic: enumerate __auth_got entries and report how many are null.
        // If null entries are present → cross-image binding failed in chroot dyld
        // and we'd need the chained-fixup walker to repair. If all are populated
        // → binding worked and the lambda crash is from a different cause.
        unsigned long auth_got_sz = 0;
        uint64_t *auth_got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__auth_got", &auth_got_sz);
        if (!auth_got) {
            auth_got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__auth_got", &auth_got_sz);
        }
        if (auth_got) {
            size_t entries = auth_got_sz / 8;
            int nulls = 0, nonnull = 0;
            for (size_t i = 0; i < entries; i++) {
                if (auth_got[i] == 0) nulls++;
                else nonnull++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __auth_got: %zu entries, %d null, %d non-null\n",
                entries, nulls, nonnull);
            // Dump first 8 entries
            for (size_t i = 0; i < entries && i < 8; i++) {
                fprintf(stderr, "####   auth_got[%zu] @%p = 0x%016llx\n",
                    i, (void *)&auth_got[i], (unsigned long long)auth_got[i]);
            }
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __auth_got section NOT FOUND\n");
        }
        unsigned long got_sz = 0;
        uint64_t *got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
            "__DATA_CONST", "__got", &got_sz);
        if (!got) {
            got = (uint64_t *)getsectiondata((const struct mach_header_64 *)header,
                "__DATA", "__got", &got_sz);
        }
        if (got) {
            size_t entries = got_sz / 8;
            int nulls = 0, nonnull = 0;
            for (size_t i = 0; i < entries; i++) {
                if (got[i] == 0) nulls++;
                else nonnull++;
            }
            fprintf(stderr, "#### MACWS_AGX_NATIVE __got: %zu entries, %d null, %d non-null\n",
                entries, nulls, nonnull);
        } else {
            fprintf(stderr, "#### MACWS_AGX_NATIVE __got section NOT FOUND\n");
        }

    }
}

// MACWS_AGX_CRASH_DIAG: install SIGSEGV/SIGBUS/SIGILL handlers so the faulting
// PC (slid + unslid) and backtrace land in stderr before the process exits.
// Faster than racing lldb against a short-lived crash. Gated by env var so
// production runs aren't affected.
#import <execinfo.h>
#import <dlfcn.h>
#import <unistd.h>
// mach_vm.h is marked unsupported in the iOS SDK; declare the one symbol
// we need so we can fail-safe read potentially-bad pointers.
extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size,
    mach_vm_address_t data, mach_vm_size_t *outsize);
extern kern_return_t mach_vm_allocate(
    vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_region(
    vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t *size,
    vm_region_flavor_t flavor, vm_region_info_t info,
    mach_msg_type_number_t *info_count, mach_port_t *object_name);

// Crash handler emits ALL diagnostic lines into a single static buffer then
// flushes via one write(2). Mixing fprintf calls from a signal handler with
// log lines from other threads scrambled the backtrace beyond use; an atomic
// write keeps the trace contiguous.
#define MACWS_CRASH_BUF_LEN 16384
static char macws_crash_buf[MACWS_CRASH_BUF_LEN];

static const char *macws_si_code_string(int signo, int code) {
    if (signo == SIGBUS) {
        if (code == BUS_ADRALN)  return "BUS_ADRALN (misaligned)";
        if (code == BUS_ADRERR)  return "BUS_ADRERR (nonexistent phys addr)";
        if (code == BUS_OBJERR)  return "BUS_OBJERR (hw object error)";
    } else if (signo == SIGSEGV) {
        if (code == SEGV_MAPERR) return "SEGV_MAPERR (unmapped)";
        if (code == SEGV_ACCERR) return "SEGV_ACCERR (permission)";
    } else if (signo == SIGILL) {
        if (code == ILL_ILLOPC)  return "ILL_ILLOPC (illegal opcode)";
        if (code == ILL_ILLTRP)  return "ILL_ILLTRP (illegal trap)";
        if (code == ILL_PRVOPC)  return "ILL_PRVOPC (priv opcode)";
        if (code == ILL_BADSTK)  return "ILL_BADSTK (bad stack)";
    }
    return "?";
}

static void macws_crash_diag_handler(int signo, siginfo_t *info, void *uctx_) {
    ucontext_t *uctx = (ucontext_t *)uctx_;
    uintptr_t pc = 0, lr = 0, fp = 0, sp = 0;
    uintptr_t fault_addr = (uintptr_t)(info ? info->si_addr : 0);
    int si_code = info ? info->si_code : 0;
#if defined(__arm64__) || defined(__arm64e__)
    if (uctx && uctx->uc_mcontext) {
        pc = (uintptr_t)arm_thread_state64_get_pc(uctx->uc_mcontext->__ss);
        lr = (uintptr_t)arm_thread_state64_get_lr(uctx->uc_mcontext->__ss);
        fp = (uintptr_t)arm_thread_state64_get_fp(uctx->uc_mcontext->__ss);
        sp = (uintptr_t)arm_thread_state64_get_sp(uctx->uc_mcontext->__ss);
    }
#endif
    char *p = macws_crash_buf;
    char *end = macws_crash_buf + MACWS_CRASH_BUF_LEN;
#define APPEND(...) do { \
        if (p < end) p += snprintf(p, (size_t)(end - p), __VA_ARGS__); \
    } while (0)

    Dl_info dli;
    APPEND("\n#### MACWS_CRASH_DIAG signo=%d si_code=%d (%s) "
           "fault_addr=%p pc=%p lr=%p fp=%p sp=%p\n",
        signo, si_code, macws_si_code_string(signo, si_code),
        (void*)fault_addr, (void*)pc, (void*)lr, (void*)fp, (void*)sp);
    if (pc && dladdr((void*)pc, &dli) && dli.dli_fname) {
        uintptr_t base = (uintptr_t)dli.dli_fbase;
        APPEND("####   pc image=%s base=%p pc-base=%#llx symbol=%s+%#llx\n",
            dli.dli_fname, (void*)base, (unsigned long long)(pc - base),
            dli.dli_sname ? dli.dli_sname : "?",
            (unsigned long long)(pc - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)));
    }
    if (lr && dladdr((void*)lr, &dli) && dli.dli_fname) {
        uintptr_t base = (uintptr_t)dli.dli_fbase;
        APPEND("####   lr image=%s base=%p lr-base=%#llx symbol=%s+%#llx\n",
            dli.dli_fname, (void*)base, (unsigned long long)(lr - base),
            dli.dli_sname ? dli.dli_sname : "?",
            (unsigned long long)(lr - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)));
    }
#if defined(__arm64__) || defined(__arm64e__)
    if (uctx && uctx->uc_mcontext) {
        APPEND("####   regs x0=%p x1=%p x2=%p x3=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[0],
            (void*)uctx->uc_mcontext->__ss.__x[1],
            (void*)uctx->uc_mcontext->__ss.__x[2],
            (void*)uctx->uc_mcontext->__ss.__x[3]);
        APPEND("####   regs x4=%p x5=%p x6=%p x7=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[4],
            (void*)uctx->uc_mcontext->__ss.__x[5],
            (void*)uctx->uc_mcontext->__ss.__x[6],
            (void*)uctx->uc_mcontext->__ss.__x[7]);
        APPEND("####   regs x8=%p x9=%p x10=%p x11=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[8],
            (void*)uctx->uc_mcontext->__ss.__x[9],
            (void*)uctx->uc_mcontext->__ss.__x[10],
            (void*)uctx->uc_mcontext->__ss.__x[11]);
        APPEND("####   regs x12=%p x13=%p x14=%p x15=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[12],
            (void*)uctx->uc_mcontext->__ss.__x[13],
            (void*)uctx->uc_mcontext->__ss.__x[14],
            (void*)uctx->uc_mcontext->__ss.__x[15]);
        APPEND("####   regs x16=%p x17=%p x19=%p x20=%p x21=%p x29(fp)=%p\n",
            (void*)uctx->uc_mcontext->__ss.__x[16],
            (void*)uctx->uc_mcontext->__ss.__x[17],
            (void*)uctx->uc_mcontext->__ss.__x[19],
            (void*)uctx->uc_mcontext->__ss.__x[20],
            (void*)uctx->uc_mcontext->__ss.__x[21],
            (void*)fp);
        // For Mempool::grow / similar init crashes, x19 is usually `this`.
        // Dump 8 qwords from x19 so we can see the layout (chunks, count,
        // and the *(this+0x28) field whose dereference faults).
        uintptr_t this_p = (uintptr_t)uctx->uc_mcontext->__ss.__x[19];
        if (this_p && this_p > 0x1000 && this_p < 0x800000000000ULL) {
            uint64_t mem[8] = {0};
            mach_vm_size_t mgot = 0;
            kern_return_t mkr = mach_vm_read_overwrite(
                mach_task_self(), (mach_vm_address_t)this_p, sizeof(mem),
                (mach_vm_address_t)mem, &mgot);
            if (mkr == KERN_SUCCESS) {
                APPEND("####   x19[0x00..0x38] = %016llx %016llx %016llx %016llx\n"
                       "####                    %016llx %016llx %016llx %016llx\n",
                    mem[0], mem[1], mem[2], mem[3],
                    mem[4], mem[5], mem[6], mem[7]);
                // mem[5] is *(this+0x28). If it's a real pointer, dump its first 8 qwords too.
                uintptr_t at28 = (uintptr_t)mem[5];
                if (at28 && at28 > 0x1000 && at28 < 0x800000000000ULL) {
                    uint64_t mem2[8] = {0};
                    mach_vm_size_t m2got = 0;
                    if (mach_vm_read_overwrite(mach_task_self(),
                            (mach_vm_address_t)at28, sizeof(mem2),
                            (mach_vm_address_t)mem2, &m2got) == KERN_SUCCESS) {
                        APPEND("####   *(x19+0x28)[0..7] = %016llx %016llx %016llx %016llx\n"
                               "####                       %016llx %016llx %016llx %016llx\n",
                            mem2[0], mem2[1], mem2[2], mem2[3],
                            mem2[4], mem2[5], mem2[6], mem2[7]);
                    } else {
                        APPEND("####   *(x19+0x28)=%p but vm_read failed (unmapped)\n",
                            (void*)at28);
                    }
                }
            } else {
                APPEND("####   vm_read(x19=%p) failed kr=%d\n", (void*)this_p, mkr);
            }
        }
        // If fault_addr == pc, this is an instruction-fetch fault. Try to
        // read the 16 bytes at pc to see whether the page is even readable.
        if (pc && fault_addr == pc) {
            uint32_t insn[4] = {0,0,0,0};
            mach_vm_size_t igot = 0;
            kern_return_t ikr = mach_vm_read_overwrite(
                mach_task_self(), (mach_vm_address_t)pc,
                sizeof(insn), (mach_vm_address_t)insn, &igot);
            APPEND("####   pc bytes (vm_read kr=%d got=%llu): %08x %08x %08x %08x\n",
                ikr, (unsigned long long)igot, insn[0], insn[1], insn[2], insn[3]);
        }
        // For an ObjC fault, x0 is usually the receiver. Try to dladdr its
        // isa to see what class it claims to be.
        uintptr_t obj = (uintptr_t)uctx->uc_mcontext->__ss.__x[0];
        if (obj && obj > 0x1000 && obj < 0x800000000000ULL) {
            uintptr_t isa = 0;
            Dl_info di2;
            if (dladdr((void*)obj, &di2) && di2.dli_fname) {
                APPEND("####   x0 dladdr: %s in %s\n",
                    di2.dli_sname ?: "?", di2.dli_fname);
            }
            mach_vm_size_t got = 0;
            kern_return_t kr = mach_vm_read_overwrite(
                mach_task_self(),
                (mach_vm_address_t)obj, sizeof(uintptr_t),
                (mach_vm_address_t)&isa, &got);
            if (kr == KERN_SUCCESS && got == sizeof(uintptr_t)) {
                uintptr_t stripped = isa & 0x0000007FFFFFFFFFULL;
                APPEND("####   x0->isa=%p stripped=%p\n",
                    (void*)isa, (void*)stripped);
                if (dladdr((void*)stripped, &di2) && di2.dli_fname) {
                    APPEND("####   x0->isa dladdr: %s in %s\n",
                        di2.dli_sname ?: "?", di2.dli_fname);
                }
            } else {
                APPEND("####   x0->isa: vm_read kr=%d (obj unmapped/freed)\n",
                    kr);
            }
        }
    }
#endif
    void *frames[32];
    int nf = backtrace(frames, 32);
    APPEND("####   backtrace (%d frames):\n", nf);
    for (int i = 0; i < nf; i++) {
        if (dladdr(frames[i], &dli) && dli.dli_fname) {
            APPEND("####     [%2d] %p %s+%#llx (%s)\n", i, frames[i],
                dli.dli_sname ? dli.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)),
                dli.dli_fname);
        } else {
            APPEND("####     [%2d] %p\n", i, frames[i]);
        }
    }
#undef APPEND
    // Atomic flush.
    size_t len = (size_t)(p - macws_crash_buf);
    if (len > MACWS_CRASH_BUF_LEN) len = MACWS_CRASH_BUF_LEN;
    (void)write(STDERR_FILENO, macws_crash_buf, len);
    _exit(128 + signo);
}

static void macws_install_crash_diag(void) {
    // Env (MACWS_AGX_CRASH_DIAG) OR the /tmp/macws_exit_trace file gate, so one
    // diagnostic run captures abort_with_payload + exit()/_exit() + SIGSEGV/
    // SIGBUS together. Needed because ReportCrash is itself unstable on this
    // device, so a real signal crash can leave NO .ips — the in-process
    // handler dumps registers + backtrace to stderr (WSERR) regardless.
    if (!getenv("MACWS_AGX_CRASH_DIAG") && access("/tmp/macws_exit_trace", F_OK) != 0) return;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = macws_crash_diag_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    fprintf(stderr, "#### MACWS_AGX_CRASH_DIAG handlers installed\n");
}

// ─── Targeted IOKit-IOHIDUnserialize bypass ──────────────────────────────
//
// The minimal fix for the IOMFBServer thread BUS_ADRALN crash. macOS
// IOKit's `_IOHIDUnserializeAndVMDealloc` takes a raw mach buffer (a
// binary plist serialized by the kernel) and feeds it through
// `CFPropertyListCreateFromStream` →
// `__CFBinaryPlistCreateObjectFiltered`. In our chroot the kernel-side
// serializer is iOS 16.3's IOKit, and the macOS 13.4 CoreFoundation
// parser builds an NSCFString whose internal char pointer lands on an
// unaligned byte. When the parser's cleanup block_invoke releases that
// string, the destructor faults with SIGBUS BUS_ADRALN inside
// `_CFRelease+0x4a4` (verified via the in-process MACWS_AGX_CRASH_DIAG
// handler — full backtrace: IOMFBServer ctor block_invoke →
// IOHIDEventSystemClientCreateWithType → IOHIDEventSystemClientRefresh →
// IOHIDEventSystemClientSetMatchingMultiple → CacheMatchingServices →
// IOHIDUnserializeAndVMDealloc → CFPropertyListCreateFromStream →
// CFBinaryPlist parse → CFRelease → objc_destructInstance → BUS_ADRALN).
//
// Stubbing this single function to return NULL skips the iOS plist parse
// without touching any of the public `IOHIDEventSystem*` APIs — those
// keep dispatching normally on the real client object, just with empty
// property data. WindowServer keeps running; we lose HID property data
// for display-related devices, which we don't have parseable copies of
// anyway.
__attribute__((unused))
static CFTypeRef hooked_IOHIDUnserializeAndVMDealloc(
        const void *buffer, mach_vm_size_t length) {
    (void)buffer; (void)length;
    return NULL;
}

// The IOHIDUnserialize symbol is internal (non-exported), so MSFindSymbol
// can't reach it. Hook the nearest PUBLIC API frame above the crash:
// `IOHIDEventSystemClientSetMatchingMultiple`. The IOMFBServer ctor block
// is the only consumer that crashes; it stores the client at +0x358 and
// then chains through SetMatchingMultiple → RegisterDeviceMatchingBlock →
// CopyServices → RegisterEventBlock → ScheduleWithRunLoop. Only the first
// of these dives into property serialization. Returning 1 (success) lets
// the block continue with an empty matching set; everything else stays
// real, so we don't have to fake out RegisterEventBlock/Schedule/etc.
static int hooked_IOHIDEventSystemClientSetMatchingMultiple_skip(
        CFTypeRef client, CFArrayRef multiple) {
    (void)client; (void)multiple;
    return 1;
}

// ─── abort_with_payload diagnostic hook ──────────────────────────────────
//
// QuartzCore's CA::OGL::MetalContext methods call abort_with_payload(13, X)
// (namespace = OS_REASON_COREANIMATION = 13) when they can't create a
// pipeline state / tile pipeline / compute pipeline / vertex shader /
// fragment shader / Metal context. There are seven such sites in the
// chroot's macOS 13.4 QuartzCore. Without runtime instrumentation we
// can't tell which one is firing — launchd only reports the namespace,
// not the reason_code or call site.
//
// This hook is a NON-INTERCEPTING diagnostic: it logs (reason_namespace,
// reason_code, reason_string, caller backtrace) and then tail-calls the
// real abort_with_payload so the process exits exactly as it would
// without the hook. That lets us identify the failing site in one run.
//
// Once the site is known, the proper fix lives in libmachook (skip the
// failing pipeline build, return a known-good replacement, …) — this
// hook is just here to find the site, not to "fix" the assert.
typedef int (*macws_abort_t)(uint32_t reason_namespace, uint64_t reason_code,
    void *payload, uint32_t payload_size, const char *reason_string,
    uint64_t reason_flags);
static macws_abort_t macws_orig_abort_with_payload = NULL;

static int hooked_abort_with_payload(uint32_t reason_namespace,
        uint64_t reason_code, void *payload, uint32_t payload_size,
        const char *reason_string, uint64_t reason_flags) {
    // Trace mode only (no survival action). Hanging the dispatch worker
    // and bypassing __assert_rtn KEPT THE PROCESS UP but left CA's
    // _state_stack non-empty, so the next MetalContext::EndUpdate
    // SEGV'd at StopCapture+0x38 on a nil shader-state pointer. The
    // real fix lives elsewhere: we need to build a real fallback
    // RenderPipelineState (vertex passthrough + simple fragment) at WS
    // init time and return it from a hook on
    // -[MTLDevice newRenderPipelineStateWithDescriptor:error:] when the
    // AGX compiler refuses a CA shader (e.g. the
    // "Encountered unlowered function call to agx.air.fract.v3f16.fast"
    // case observed on the macOS-13.4 AGXMetal13_3 + iOS-16.3 chroot
    // combination). Without that, hanging the worker just defers the
    // crash by one frame.
    // Default: behave like a tracing hook — log and forward to the real
    // abort_with_payload so other namespaces/codes still terminate.
    char *p = macws_crash_buf;
    char *end = macws_crash_buf + MACWS_CRASH_BUF_LEN;
#define AP(...) do { if (p < end) p += snprintf(p, (size_t)(end - p), __VA_ARGS__); } while (0)
    AP("\n#### MACWS_ABORT_TRACE namespace=%u code=%llu string=\"%s\" "
       "payload=%p size=%u flags=%llu\n",
        reason_namespace, (unsigned long long)reason_code,
        reason_string ? reason_string : "(null)",
        payload, payload_size, (unsigned long long)reason_flags);
    // Payload is usually a CFString-ish buffer with the Metal error
    // description in the first ~size bytes. Print as both hex and as
    // raw text so we see exactly what reason came from the driver.
    if (payload && payload_size > 0 && payload_size < 4096) {
        AP("####   payload bytes (text): \"");
        const unsigned char *pl = (const unsigned char *)payload;
        for (uint32_t i = 0; i < payload_size && p + 4 < end; i++) {
            unsigned char c = pl[i];
            if (c == '\\' || c == '"') { AP("\\%c", c); }
            else if (c >= 0x20 && c < 0x7f) { AP("%c", c); }
            else if (c == 0) { AP("\\0"); }
            else { AP("\\x%02x", c); }
        }
        AP("\"\n");
    }
    void *frames[24];
    int nf = backtrace(frames, 24);
    for (int i = 0; i < nf; i++) {
        Dl_info dli;
        if (dladdr(frames[i], &dli) && dli.dli_fname) {
            AP("####     [%2d] %p %s+%#llx (%s)\n", i, frames[i],
                dli.dli_sname ? dli.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] -
                    (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)),
                dli.dli_fname);
        } else {
            AP("####     [%2d] %p\n", i, frames[i]);
        }
    }
#undef AP
    size_t len = (size_t)(p - macws_crash_buf);
    if (len > MACWS_CRASH_BUF_LEN) len = MACWS_CRASH_BUF_LEN;
    (void)write(STDERR_FILENO, macws_crash_buf, len);
    // Tail-call the real abort_with_payload so process exit + launchd's
    // reason reporting are unchanged.
    if (macws_orig_abort_with_payload) {
        return macws_orig_abort_with_payload(reason_namespace, reason_code,
            payload, payload_size, reason_string, reason_flags);
    }
    _exit(128 + 6); // SIGABRT fallback
    return 0;
}

// ─── exit()/_exit() diagnostic tracer ────────────────────────────────────
//
// WS in coexist sometimes dies on a client (GlassDemo) connect WITHOUT a
// crash report (.ips) and WITHOUT a JetsamEvent — i.e. it is a VOLUNTARY
// exit()/_exit(), not abort_with_payload (which would emit an OS_REASON .ips)
// nor a SIGKILL. SkyLight's CGXServer calls exit() on some fatal-but-
// "recoverable" conditions (server teardown, port death). This is a NON-
// intercepting tracer: it logs the caller backtrace + code, then forwards to
// the real exit so the process terminates exactly as it would. Gated by the
// FILE /tmp/macws_exit_trace (not an env var) so it can be toggled without a
// plist edit — editing the WS plist would trip the FAST guardrail → full
// rebuild.
typedef void (*macws_exit_t)(int) __attribute__((noreturn));
static macws_exit_t macws_orig_exit  = NULL;
static macws_exit_t macws_orig__exit = NULL;

static void macws_dump_exit(const char *which, int code) {
    char *p = macws_crash_buf;
    char *end = macws_crash_buf + MACWS_CRASH_BUF_LEN;
#define AP(...) do { if (p < end) p += snprintf(p, (size_t)(end - p), __VA_ARGS__); } while (0)
    AP("\n#### MACWS_EXIT_TRACE %s(%d) pid=%d\n", which, code, getpid());
    void *frames[32];
    int nf = backtrace(frames, 32);
    for (int i = 0; i < nf; i++) {
        Dl_info dli;
        if (dladdr(frames[i], &dli) && dli.dli_fname) {
            AP("####     [%2d] %p %s+%#llx (%s)\n", i, frames[i],
                dli.dli_sname ? dli.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] -
                    (uintptr_t)(dli.dli_saddr ? dli.dli_saddr : dli.dli_fbase)),
                dli.dli_fname);
        } else {
            AP("####     [%2d] %p\n", i, frames[i]);
        }
    }
#undef AP
    size_t len = (size_t)(p - macws_crash_buf);
    if (len > MACWS_CRASH_BUF_LEN) len = MACWS_CRASH_BUF_LEN;
    (void)write(STDERR_FILENO, macws_crash_buf, len);
}

static void hooked_exit(int code) {
    macws_dump_exit("exit", code);
    if (macws_orig_exit) macws_orig_exit(code);
    _exit(code);
}
static void hooked__exit(int code) {
    macws_dump_exit("_exit", code);
    if (macws_orig__exit) macws_orig__exit(code);
    __builtin_trap();
}

static void macws_install_exit_trace(void) {
    if (access("/tmp/macws_exit_trace", F_OK) != 0) return;
    static int done = 0; if (done) return; done = 1;
    void *pe  = dlsym(RTLD_DEFAULT, "exit");
    void *p_e = dlsym(RTLD_DEFAULT, "_exit");
    if (pe) {
        MSHookFunction(pe, (void *)hooked_exit, (void **)&macws_orig_exit);
        fprintf(stderr, "#### MACWS_EXIT_TRACE: hooked exit @ %p\n", pe);
    }
    if (p_e && p_e != pe) {
        MSHookFunction(p_e, (void *)hooked__exit, (void **)&macws_orig__exit);
        fprintf(stderr, "#### MACWS_EXIT_TRACE: hooked _exit @ %p\n", p_e);
    }
}

// __assert_rtn is what `assert()` macro calls before abort(). CA's
// MetalContext.mm has classic-assert "Unbalanced Composites" / similar
// guards. When we park a pipeline-build worker on a pipeline failure
// (above), the CA state stack is left non-empty, and the *next* frame's
// EndUpdate hits assert(_state_stack.empty()). That triggers abort() on
// a DIFFERENT thread from the abort_with_payload hang. Catch it here too
// and just return; the assertion message is logged for diagnostics.
static void hooked_assert_rtn(const char *func, const char *file, int line,
                              const char *expr) {
    char buf[512];
    int len = snprintf(buf, sizeof(buf),
        "#### MACWS_ASSERT_BYPASS func=%s file=%s line=%d expr=%s — return, "
        "NOT aborting\n",
        func ?: "?", file ?: "?", line, expr ?: "?");
    (void)write(STDERR_FILENO, buf,
        (size_t)(len > 0 ? (size_t)len : 0));
    return;
}

static void macws_install_assert_bypass(void) {
    // LAZY-fix kill switch. Default behaviour is to skip — this hook
    // globally turns every __assert_rtn into log+return, which has
    // masked real composite-state-stack leaks (Unbalanced Composites at
    // MetalContext.mm:411). See AGENTS.md "Patch Discipline" + memory
    // [[feedback-no-lazy-nop-ret-bypass]]. Opt-IN by setting
    // MACWS_KEEP_ASSERT_BYPASS=1 in WS plist to restore the old bypass
    // while debugging upstream.
    if (!getenv("MACWS_KEEP_ASSERT_BYPASS")) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS DISABLED (set MACWS_KEEP_ASSERT_BYPASS=1 "
            "to restore lazy bypass) — real __assert_rtn now reaches abort\n");
        return;
    }
    MSImageRef libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_c.dylib");
    if (!libsys) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS: libsystem_c image not found, skip\n");
        return;
    }
    void *sym = MSFindSymbol(libsys, "___assert_rtn");
    if (!sym) sym = MSFindSymbol(libsys, "__assert_rtn");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_ASSERT_BYPASS: __assert_rtn not found, skip\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_assert_rtn, NULL);
    fprintf(stderr,
        "#### MACWS_ASSERT_BYPASS __assert_rtn → log+return at %p\n", sym);
}

// DIAG (gated /tmp/macws_assert_log): log-only __assert_rtn capture. NOT a
// bypass — it records func/file/line/expr to a truncating file (survives the
// abort, unlike block-buffered stderr) then STILL calls orig → abort. Used to
// capture the exact Metal MTLReportFailure assertion (which ends in __assert_rtn)
// for the IOSurface-wrapped pf552 texture, deterministically, without the global
// timing perturbation that unbuffered stderr causes.
static void (*macws_orig_assert_diag)(const char *, const char *, int, const char *) = NULL;
static void macws_diag_assert_rtn(const char *func, const char *file, int line, const char *expr) {
    char buf[640];
    int len = snprintf(buf, sizeof buf, "ASSERT func=%s file=%s line=%d expr=%s\n",
                       func ?: "?", file ?: "?", line, expr ?: "?");
    int fd = open("/tmp/macws_assert_last", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { if (len > 0) write(fd, buf, (size_t)len); close(fd); }
    int fd2 = open("/tmp/macws_assert.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd2 >= 0) { if (len > 0) write(fd2, buf, (size_t)len); close(fd2); }
    if (macws_orig_assert_diag) macws_orig_assert_diag(func, file, line, expr);
    abort();  // belt-and-suspenders: orig should not return, but ensure abort
}
static void macws_install_assert_diag(void) {
    if (access("/tmp/macws_assert_log", F_OK) != 0) return;
    MSImageRef libsys = MSGetImageByName("/usr/lib/system/libsystem_c.dylib");
    if (!libsys) return;
    void *sym = MSFindSymbol(libsys, "___assert_rtn");
    if (!sym) sym = MSFindSymbol(libsys, "__assert_rtn");
    if (!sym) return;
    MSHookFunction(sym, (void *)macws_diag_assert_rtn, (void **)&macws_orig_assert_diag);
    fprintf(stderr, "#### MACWS_ASSERT_DIAG installed (log-only, still aborts) @ %p\n", sym);
}

static void macws_install_abort_trace(void) {
    // Enabled by env (MACWS_ABORT_TRACE) OR by the /tmp/macws_exit_trace file
    // gate so a single diagnostic run captures BOTH abort_with_payload (CA
    // OS_REASON) and plain exit()/_exit() voluntary exits.
    if (!getenv("MACWS_ABORT_TRACE") && access("/tmp/macws_exit_trace", F_OK) != 0) return;
    MSImageRef libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_kernel.dylib");
    if (!libsys) libsys = MSGetImageByName(
        "/usr/lib/system/libsystem_c.dylib");
    if (!libsys) {
        fprintf(stderr,
            "#### MACWS_ABORT_TRACE: libsystem image not found, skip\n");
        return;
    }
    void *sym = MSFindSymbol(libsys, "_abort_with_payload");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_ABORT_TRACE: _abort_with_payload symbol not found\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_abort_with_payload,
        (void **)&macws_orig_abort_with_payload);
    fprintf(stderr,
        "#### MACWS_ABORT_TRACE installed at %p (orig=%p)\n",
        sym, (void *)macws_orig_abort_with_payload);
}

// ─── AGX fast-math forcing (root-cause fix for fract.v3f16) ─────────────
//
// QC's `default.metallib` ships with AIR that uses `air.fract.v3f16`.
// AGXCompilerCore (macOS 13.4 build, the one we run under iOS 16.3) has
// a fast-math optimization pass that — when enabled — renames the
// intrinsic to its AGX-internal "fast" form `agx.air.fract.v3f16.fast`
// and registers it for the dedicated fast-fract lowerer. The fast-fract
// lowerer (`AGCLLVMAirBuiltins::buildFastFract`) is actually present
// and DOES handle v3f16 correctly (it returns `x - floor(x)` with no
// post-clamp, since the clamp is f32-only), BUT the dispatch table that
// runs after the rename pass has no entry for `agx.air.fract.v3f16.fast`
// → `AGCLLVMUserObject::verifyLoweredIR()` reports "Encountered
// unlowered function call to agx.air.fract.v3f16.fast" and
// `CA::OGL::MetalContext::create_pipeline_state` calls
// abort_with_payload(13, 4, …).
//
// The fast-math rename happens iff bit 0 of the third argument to
// `AGCLLVMCtx::compile(AGCLLVMObject*, llvm::Module&, AGCFastMathFlags,
// llvm::AGX::PipelineType, llvm::AGX::CodeGenOptions&, bool)` is set
// (verified via static disasm — the function does
// `and w8, w19, #0x1 ; strb w8, [x25]` at offset +0xc0, writing the bit
// into CodeGenOptions[0], from which downstream passes read it). If we
// force AGCFastMathFlags to 0 at the function entry, the rename pass
// stays in "regular fract" mode and `AGCLLVMAirBuiltins::buildFract` —
// which has all four v{2,3,4}f16 cases wired into the dispatch table —
// handles the intrinsic. Trade-off: shaders compile with strict math
// instead of fast math; correctness is preserved, performance loses
// the fast-math optimizer's reassociation opportunities.
//
// AGCFastMathFlags is value-typed (≤ 8 bytes — passed in x3); only its
// low bit is read here, so a forwarded compile call with the third arg
// cleared is safe regardless of what the caller actually set.
typedef void (*macws_agc_compile_t)(void *self, void *obj, void *module,
    uint64_t fastMath, uint64_t pipeType, void *opts, uint64_t safeMode);
static macws_agc_compile_t macws_orig_agc_compile = NULL;

static void hooked_agc_compile(void *self, void *obj, void *module,
        uint64_t fastMath, uint64_t pipeType, void *opts, uint64_t safeMode) {
    static int log_once = 0;
    if (!log_once) {
        log_once = 1;
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF first AGCLLVMCtx::compile() call "
            "— forcing AGCFastMathFlags 0x%llx → 0 (avoids unlowered "
            "agx.air.fract.v3f16.fast)\n",
            (unsigned long long)fastMath);
    }
    macws_orig_agc_compile(self, obj, module, 0, pipeType, opts, safeMode);
}

// ─── Experiment: bypass verifyLoweredIR ─────────────────────────────────
//
// `AGCLLVMUserObject::verifyLoweredIR()` iterates the module's function
// list looking for declarations whose name contains "air.". Each match
// is logged via `_os_log_fault_impl` with the format
//   "Encountered unlowered function call to %s"
// and that log output is captured by the surrounding compile pipeline
// into the abort_with_payload payload string the host sees as
// "Metal failed to build render pipeline".
//
// If we make verifyLoweredIR a no-op (RET on entry), no fault is logged,
// no payload is constructed, the compile pipeline reports success, and
// the downstream codegen tries to emit machine code for the as-yet-
// unlowered call. There are three possible outcomes:
//
//   1. Codegen succeeds — the AGX backend has a fallback for the
//      unlowered call (perhaps emits a stub that the GPU runtime
//      handles), pipeline state builds OK, GPU executes correctly.
//      Best case — we've found the real fix.
//   2. Codegen succeeds but the GPU traps at runtime when the
//      unlowered call is reached.
//   3. Codegen itself fails with a different error.
//
// This is gated behind MACWS_AGC_VERIFY_BYPASS=1 because the trade-off
// depends on which outcome we hit. The verifier is meant to catch real
// bugs, so silencing it in general is risky.
typedef void (*macws_verify_t)(void *self);
static macws_verify_t macws_orig_agc_verify = NULL;
static void hooked_agc_verify(void *self) {
    static int log_once = 0;
    if (!log_once) {
        log_once = 1;
        fprintf(stderr,
            "#### MACWS_AGC_VERIFY_BYPASS verifyLoweredIR called on %p "
            "→ skipping check\n", self);
    }
    // Just return — don't iterate the module, don't log faults.
}

static void macws_install_agc_verify_bypass(MSImageRef img) {
    void *sym = MSFindSymbol(img,
        "__ZN17AGCLLVMUserObject15verifyLoweredIREv");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_AGC_VERIFY_BYPASS: verifyLoweredIR symbol not "
            "found, skip\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_agc_verify,
        (void **)&macws_orig_agc_verify);
    fprintf(stderr,
        "#### MACWS_AGC_VERIFY_BYPASS installed at %p "
        "(verifyLoweredIR → no-op)\n", sym);
}

static void macws_install_agc_fastmath_disable(void) {
    static int once = 0;
    if (once) return;
    // AGXCompilerCore is loaded on-demand the first time Metal asks the
    // device's compiler to build a pipeline; dlopen it eagerly so the
    // symbol is reachable from MSFindSymbol now.
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore",
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        NULL,
    };
    void *h = NULL;
    for (int i = 0; paths[i]; i++) {
        h = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) break;
    }
    if (!h) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF dlopen AGXCompilerCore FAILED: %s\n",
            dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore");
    if (!img) {
        img = MSGetImageByName(
            "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    }
    if (!img) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF: AGXCompilerCore image not "
            "MSGetImageByName-able\n");
        return;
    }
    const char *sym_name =
        "__ZN10AGCLLVMCtx7compileEP13AGCLLVMObjectRN4llvm6ModuleE"
        "16AGCFastMathFlagsNS2_3AGX12PipelineTypeERNS6_14CodeGenOptionsEb";
    void *sym = MSFindSymbol(img, sym_name);
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_AGC_FASTMATH_OFF: AGCLLVMCtx::compile symbol not "
            "found in AGXCompilerCore\n");
        return;
    }
    MSHookFunction(sym, (void *)hooked_agc_compile,
        (void **)&macws_orig_agc_compile);
    once = 1;
    fprintf(stderr,
        "#### MACWS_AGC_FASTMATH_OFF installed at %p — every "
        "AGCLLVMCtx::compile() call will receive AGCFastMathFlags=0 "
        "regardless of caller intent\n", sym);
}

// ─── AGXCompilerCore linkMetalRuntime rename patch ───────────────────────
//
// CONTEXT: chroot WindowServer compiles CA shaders IN-PROCESS via
// AGXCompilerCore (loaded as a dependency of AGXMetal13_3). The earlier
// hypothesis that compile goes out-of-process to MTLCompilerService.xpc
// was WRONG — `ps aux` shows no MTLCompilerService process at the time
// the v3f16 abort fires, and the matching Substrate-tweak patch never
// logs (its %ctor never runs in the chroot WS process). So the patch
// has to live here in libmachook, which already injects into the WS
// process.
//
// PATCH SITE: In macOS-13.4 AGXCompilerCore (the version chroot loads
// from the bind-mounted rootfs DSC), `AGCLLVMUserObject::linkMetalRuntime(bool)`
// at 0x1a2591b90 builds a renamed Function name as
// `"agx." + originalName + ".fast"`. The "agx." prepend is done by
// `std::string::insert(0, "agx.")`, a single BL at 0x1a2591ca0. The
// downstream dispatcher `AGCLLVMAirBuiltins::replaceBuiltins` only
// matches Function names that start with "air."; the renamer's "agx."
// prepend makes the renamed declaration invisible to the dispatcher and
// the verifier then aborts with "Encountered unlowered function call to
// agx.air.fract.v3f16.fast".
//
// If we NOP the insert call, the renamer produces `air.fract.v3f16.fast`
// instead — still starts with "air.", findPrefix splits at the first
// dot of the remainder ("fract" / "v3f16.fast"), the dispatcher's
// StringMap lookup hits the "fract" key → `buildFract`, which reads the
// operand type from the LLVM Value (half3) and emits the regular
// `x - floor(x)` lowering. No more unlowered call → no verifier
// complaint → no abort.
//
// ANCHOR + SIGNATURE:
//   _AIRNTGetVersion is exported by AGXCompilerCore; BL site is at
//   anchor + delta. To make the patch self-validating under DSC drift,
//   we also require that the instruction IMMEDIATELY BEFORE the BL
//   matches `add x2, x2, #0xdf4` (encoding 0x9137d042). That's the
//   literal-pool prep for the "agx." string pointer — it's a unique
//   signature for this exact call site.
//
//   Known deltas:
//     - macOS-13.4 chroot DSC (this device): -0x7e470 (RE'd 2026-06-18
//       from /System/Volumes/Preboot/Cryptexes/OS/.../dyld_shared_cache_arm64e,
//       linkMetalRuntime @ 0x1a2591b90, BL @ 0x1a2591ca0,
//       _AIRNTGetVersion @ 0x1a2610110)
//
// If the delta-1 instruction isn't the expected ADD, we walk a small
// window around the anchor looking for the (ADD #0xdf4) + (BL) pair so
// minor DSC version drift still resolves the right site.
//
// Opt-in via env: set MACWS_AGX_RENAMER_PATCH=1 in the WindowServer
// plist EnvironmentVariables. Off by default until we've validated the
// fix doesn't regress something else.
static void macws_install_agx_renamer_patch(void) {
    if (!getenv("MACWS_AGX_RENAMER_PATCH")) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH: off (set "
            "MACWS_AGX_RENAMER_PATCH=1 to enable)\n");
        return;
    }
    // Force-load AGXCompilerCore. It's pulled in by AGXMetal13_3 the
    // first time Metal asks the device for a compiler, but doing it
    // here ensures the symbol table is reachable before our hooks run.
    const char *acc_paths[] = {
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore",
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        NULL,
    };
    void *h = NULL;
    for (int i = 0; acc_paths[i]; i++) {
        h = dlopen(acc_paths[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            fprintf(stderr,
                "#### MACWS_AGX_RENAMER_PATCH dlopen ok %s -> %p\n",
                acc_paths[i], h);
            break;
        }
    }
    if (!h) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH dlopen FAILED: %s\n",
            dlerror());
        return;
    }
    void *anchor = dlsym(h, "AIRNTGetVersion");
    if (!anchor) anchor = dlsym(h, "_AIRNTGetVersion");
    if (!anchor) anchor = dlsym(RTLD_DEFAULT, "AIRNTGetVersion");
    if (!anchor) anchor = dlsym(RTLD_DEFAULT, "_AIRNTGetVersion");
    if (!anchor) {
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH: AIRNTGetVersion not found "
            "via dlsym in AGXCompilerCore handle or RTLD_DEFAULT\n");
        return;
    }
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH anchor AIRNTGetVersion=%p\n",
        anchor);
    // Signature: the BL site is preceded by `add x2, x2, #0xdf4`
    // (encoding 0x9137d042) which loads the "agx." literal pointer.
    // Patch only if both the ADD signature matches AND the next insn
    // is a BL — that's the unambiguous call site.
    const uint32_t SIG_ADD_X2_DF4 = 0x9137d042u;  // add x2, x2, #0xdf4
    BOOL (^try_patch)(uint32_t *, const char *) =
        ^BOOL(uint32_t *bl_site, const char *label) {
        uint32_t prev = bl_site[-1];
        uint32_t cur  = bl_site[0];
        unsigned op   = (cur >> 26) & 0x3F;
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH probe %s: site=%p prev=%#x "
            "insn=%#x op6=%#x (sig %s, BL %s)\n",
            label, bl_site, prev, cur, op,
            prev == SIG_ADD_X2_DF4 ? "OK" : "MISMATCH",
            op == 0x25 ? "OK" : "MISMATCH");
        if (prev != SIG_ADD_X2_DF4 || op != 0x25) return NO;
        ModifyExecutableRegion(bl_site, sizeof(uint32_t), ^{
            *bl_site = 0xd503201fu; // nop
        });
        fprintf(stderr,
            "#### MACWS_AGX_RENAMER_PATCH installed at %p (variant=%s) "
            "BL %#x → NOP\n",
            bl_site, label, cur);
        return YES;
    };

    // Primary delta: macOS-13.4 chroot DSC (this device).
    struct { intptr_t delta; const char *label; } candidates[] = {
        { -0x7e470,  "macOS-13.4 chroot" },
        // Legacy probes kept for diagnostic comparison only:
        { -0xa721c,  "alt-A (old probe)" },
        { -0x1259a4, "alt-B (old probe)" },
    };
    for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
        uint32_t *site = (uint32_t *)((uintptr_t)anchor + candidates[i].delta);
        if (try_patch(site, candidates[i].label)) return;
    }

    // Fallback: small +/-2KB scan for (ADD x2,x2,#0xdf4 ; BL) pair.
    // Stops at the first match.
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH: candidates missed — scanning "
        "+/-2KB around primary site for ADD+BL signature\n");
    uint32_t *base = (uint32_t *)((uintptr_t)anchor + (-0x7e470));
    for (int off = -512; off <= 512; off++) {
        uint32_t *probe = base + off;
        if (probe[-1] == SIG_ADD_X2_DF4 && ((probe[0] >> 26) & 0x3F) == 0x25) {
            char label[64];
            snprintf(label, sizeof label, "scan off=%+d", off);
            if (try_patch(probe, label)) return;
        }
    }
    fprintf(stderr,
        "#### MACWS_AGX_RENAMER_PATCH: no (ADD x2,x2,#0xdf4 ; BL) pair "
        "found — AGXCompilerCore version drift, NOT patching\n");
}

static void macws_install_iohid_unserialize_bypass(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    MSImageRef iokit = MSGetImageByName(
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit");
    if (!iokit) {
        iokit = MSGetImageByName(
            "/System/Library/Frameworks/IOKit.framework/IOKit");
    }
    if (!iokit) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: IOKit image not loadable, skip\n");
        return;
    }
    void *sym = MSFindSymbol(iokit,
        "_IOHIDEventSystemClientSetMatchingMultiple");
    if (!sym) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: SetMatchingMultiple not found, skip\n");
        return;
    }
    MSHookFunction(sym,
        (void *)hooked_IOHIDEventSystemClientSetMatchingMultiple_skip, NULL);
    fprintf(stderr,
        "#### MACWS_HID_BYPASS installed SetMatchingMultiple → no-op (1) "
        "at %p — skips iOS-format CFBinaryPlist parse inside\n"
        "####   IOHIDEventSystemClientCacheMatchingServices → "
        "IOHIDUnserializeAndVMDealloc → CFPropertyListCreateFromStream\n"
        "####   that BUS_ADRALNs in the IOMFBServer thread.\n", sym);
}

// ─── (Disabled) bulk IOMFBServer HID-init bypass ─────────────────────────
//
// QuartzCore's `CA::WindowServer::IOMFBServer` constructor enqueues a
// block (block_invoke at +0x3c) onto its runloop that walks the IOKit HID
// event-system to wire up display-related HID notifications (orientation,
// ambient light, hotplug). The block calls — in order:
//
//     client = IOHIDEventSystemClientCreate(NULL)
//     IOHIDEventSystemClientSetMatchingMultiple(client, matchArray)
//     IOHIDEventSystemClientRegisterDeviceMatchingBlock(client, …)
//     services = IOHIDEventSystemClientCopyServices(client)
//     for s in services: invoke per-service block
//     IOHIDEventSystemClientRegisterEventBlock(client, …)
//     IOHIDEventSystemClientScheduleWithRunLoop(client, …)
//
// In our chroot, the kernel that backs these calls is iOS 16.3's IOKit,
// not macOS 13.4's. The `SetMatchingMultiple` step asks the kernel to
// pre-cache matched services; the kernel responds with each service's
// property dict serialized as a binary plist. macOS CoreFoundation's
// `__CFBinaryPlistCreateObjectFiltered` parses the buffer and ends up
// constructing an NSCFString whose internal char pointer lands on an
// unaligned byte — the recursive parser's cleanup block_invoke then
// `CFRelease()`s that NSCFString and the destructor faults with SIGBUS
// si_code=BUS_ADRALN inside `_CFRelease+0x4a4` (verified by the in-process
// CRASH_DIAG handler — full stack: block_invoke → CFRelease →
// CFBinaryPlist → CFTryParseBinaryPlist → CFPropertyListCreateFromStream
// → _IOHIDUnserializeAndVMDealloc → CacheMatchingServices → SetMatching).
//
// The mismatch is between the iOS-kernel binary-plist serializer and the
// macOS-userspace parser. We don't have iOS-style HID devices that WS can
// usefully drive anyway, so the cheapest correct fix is: take WS out of
// the entire HID notification path. We make `…ClientCreate*` return a
// real (refcounted) sentinel CF object so the block's `str x0,[x20,#0x358]`
// store + later CFRetain/CFRelease still work, and we no-op every
// `…Client*` function that would otherwise mach-msg the kernel.
static CFTypeRef macws_hid_sentinel = NULL;
static dispatch_once_t macws_hid_sentinel_once = 0;
static CFTypeRef macws_get_hid_sentinel(void) {
    dispatch_once(&macws_hid_sentinel_once, ^{
        macws_hid_sentinel = (CFTypeRef)CFArrayCreate(
            kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
        if (macws_hid_sentinel) {
            CFRetain(macws_hid_sentinel);  // pin forever
        }
    });
    return macws_hid_sentinel;
}

static CFTypeRef hooked_IOHIDEventSystemClientCreate(
        CFAllocatorRef allocator) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr, "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreate "
        "→ sentinel %p\n", s);
    if (s) CFRetain(s);
    return s;
}
static CFTypeRef hooked_IOHIDEventSystemClientCreateWithType(
        CFAllocatorRef allocator, int type, CFDictionaryRef attributes) {
    CFTypeRef s = macws_get_hid_sentinel();
    fprintf(stderr,
        "#### MACWS_HID_BYPASS IOHIDEventSystemClientCreateWithType(type=%d) "
        "→ sentinel %p\n", type, s);
    if (s) CFRetain(s);
    return s;
}
// Boolean-returning setter; return 1 for "success".
static int hooked_IOHIDEventSystemClientSetMatchingMultiple(
        CFTypeRef client, CFArrayRef multiple) {
    (void)client; (void)multiple;
    return 1;
}
static void hooked_IOHIDEventSystemClientRegisterDeviceMatchingBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
static void hooked_IOHIDEventSystemClientUnregisterDeviceMatchingBlock(
        CFTypeRef client) {
    (void)client;
}
static void hooked_IOHIDEventSystemClientRegisterEventBlock(
        CFTypeRef client, void *block, void *ctx, void *target) {
    (void)client; (void)block; (void)ctx; (void)target;
}
// Callback-pointer variant — same signature shape, also a no-op.
static void hooked_IOHIDEventSystemClientRegisterEventCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
static void hooked_IOHIDEventSystemClientRegisterPropertyChangedCallback(
        CFTypeRef client, void *callback, void *target, void *refcon) {
    (void)client; (void)callback; (void)target; (void)refcon;
}
static void hooked_IOHIDEventSystemClientScheduleWithRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
static void hooked_IOHIDEventSystemClientUnscheduleFromRunLoop(
        CFTypeRef client, CFRunLoopRef rl, CFStringRef mode) {
    (void)client; (void)rl; (void)mode;
}
static CFArrayRef hooked_IOHIDEventSystemClientCopyServices(
        CFTypeRef client) {
    (void)client;
    return NULL;  // block checks cbz x0 and skips iteration
}
// Generic no-op stub — used for every "set/register/schedule/activate/cancel"
// IOHIDEventSystem call that takes our sentinel and otherwise tries to
// dereference its non-CFArray internals.
static void hooked_IOHID_noop(void) {}
// Bool/int returning variant — return 1 (success) by convention.
static int hooked_IOHID_noop_ret1(void) { return 1; }

static void macws_hook_iokit_sym(MSImageRef img, const char *sym,
                                  void *replacement) {
    void *p = MSFindSymbol(img, sym);
    if (!p) {
        fprintf(stderr, "#### MACWS_HID_BYPASS: %s not found, skip\n", sym);
        return;
    }
    MSHookFunction(p, replacement, NULL);
    fprintf(stderr, "#### MACWS_HID_BYPASS hooked %s @ %p\n", sym, p);
}

static void macws_install_iomfb_hid_bypass(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    MSImageRef iokit = MSGetImageByName(
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit");
    if (!iokit) {
        iokit = MSGetImageByName(
            "/System/Library/Frameworks/IOKit.framework/IOKit");
    }
    if (!iokit) {
        fprintf(stderr,
            "#### MACWS_HID_BYPASS: IOKit image not loadable, skip\n");
        return;
    }
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCreate",
        (void *)hooked_IOHIDEventSystemClientCreate);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCreateWithType",
        (void *)hooked_IOHIDEventSystemClientCreateWithType);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientSetMatchingMultiple",
        (void *)hooked_IOHIDEventSystemClientSetMatchingMultiple);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientRegisterDeviceMatchingBlock",
        (void *)hooked_IOHIDEventSystemClientRegisterDeviceMatchingBlock);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientUnregisterDeviceMatchingBlock",
        (void *)hooked_IOHIDEventSystemClientUnregisterDeviceMatchingBlock);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientRegisterEventBlock",
        (void *)hooked_IOHIDEventSystemClientRegisterEventBlock);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientRegisterEventCallback",
        (void *)hooked_IOHIDEventSystemClientRegisterEventCallback);
    macws_hook_iokit_sym(iokit,
        "_IOHIDEventSystemClientRegisterPropertyChangedCallback",
        (void *)hooked_IOHIDEventSystemClientRegisterPropertyChangedCallback);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientScheduleWithRunLoop",
        (void *)hooked_IOHIDEventSystemClientScheduleWithRunLoop);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientUnscheduleFromRunLoop",
        (void *)hooked_IOHIDEventSystemClientUnscheduleFromRunLoop);
    macws_hook_iokit_sym(iokit, "_IOHIDEventSystemClientCopyServices",
        (void *)hooked_IOHIDEventSystemClientCopyServices);
    // All remaining client-side IOHIDEventSystem APIs that SkyLight /
    // QuartzCore call on our sentinel. Each one would otherwise read an
    // internal IOHID-object vtable from the sentinel (CFArray storage,
    // not an IOHID object) and SEGV. The no-op stubs absorb the call.
    static const char *noop_void_syms[] = {
        "_IOHIDEventSystemClientActivate",
        "_IOHIDEventSystemClientCancel",
        "_IOHIDEventSystemClientScheduleWithDispatchQueue",
        "_IOHIDEventSystemClientSetCancelHandler",
        "_IOHIDEventSystemClientSetDispatchQueue",
        "_IOHIDEventSystemClientUnregisterEventCallback",
        "_IOHIDEventSystemClientUnregisterPropertyChangedCallback",
        "_IOHIDEventSystemClientStop",
        "_IOHIDEventSystemRegisterServicesCallback",
        NULL
    };
    static const char *noop_ret1_syms[] = {
        "_IOHIDEventSystemClientSetMatching",
        "_IOHIDEventSystemClientSetMatchingMultiple",
        "_IOHIDEventSystemClientSetProperty",
        "_IOHIDEventSystemSetProperty",
        NULL
    };
    for (int i = 0; noop_void_syms[i]; i++) {
        void *p = MSFindSymbol(iokit, noop_void_syms[i]);
        if (p) {
            MSHookFunction(p, (void *)hooked_IOHID_noop, NULL);
            fprintf(stderr, "#### MACWS_HID_BYPASS noop %s @ %p\n",
                noop_void_syms[i], p);
        }
    }
    for (int i = 0; noop_ret1_syms[i]; i++) {
        void *p = MSFindSymbol(iokit, noop_ret1_syms[i]);
        if (p) {
            // Already hooked SetMatchingMultiple above with a specialised
            // 2-arg stub; the generic ret-1 works equivalently for it but
            // re-hooking is harmless. MSHook keeps the first install.
            MSHookFunction(p, (void *)hooked_IOHID_noop_ret1, NULL);
            fprintf(stderr, "#### MACWS_HID_BYPASS ret1 %s @ %p\n",
                noop_ret1_syms[i], p);
        }
    }
}

// ─── OSXvnc framebuffer delivery hook ────────────────────────────────────────
// OSXvnc-server captures via CGDisplayCreateImage(CGMainDisplayID()), but in its
// "off-screen user session" that returns BLACK (CGS session isolation — same
// displayID as a CLI capture that DOES see our composite). Source
// (github.com/stweil/OSXvnc, OSXvnc-server/main.c): rfbGetFramebuffer() caches
// frameBufferData and returns its .mutableBytes; rfbGetFramebufferUpdateInRect()
// re-captures per frame INTO it. We hook both and overwrite frameBufferData with
// OUR content, bypassing the black session-CreateImage.
//   Phase 1 (this build): write a TEST GRADIENT to prove the delivery path
//   end-to-end on VNC. Phase 2: read the detiled composite from a shared
//   IOSurface instead of the gradient.
// rfbScreenInfo (rfb.h): width@0 paddedWidthInBytes@+4 height@+8 depth@+12
//   bitsPerPixel@+16 (all int32). Offsets from base 0x100000000 (otool of the
//   device OSXvnc-server arm64): rfbGetFramebuffer @0xd9d4,
//   rfbGetFramebufferUpdateInRect @0xdc28, rfbScreen @0x79bf8.
// Always installed inside OSXvnc but INERT unless /tmp/macws_vnc_test exists.
static char *(*macws_orig_rfbGetFB)(void);
static void (*macws_orig_rfbGetFBRect)(int, int, int, int);
static char *macws_vnc_fb = NULL;
static int  *macws_rfbScreen = NULL;
static int   macws_vnc_test_on = 0;

static IOSurfaceRef macws_vnc_src = NULL;
static void macws_vnc_fill_test(void) {
    if (!macws_vnc_fb || !macws_rfbScreen) return;
    int padded = macws_rfbScreen[1];   // paddedWidthInBytes
    int height = macws_rfbScreen[2];   // height
    int bpp    = macws_rfbScreen[4];   // bitsPerPixel
    if (padded <= 0 || height <= 0 || height > 8192 || padded > (1 << 20)) return;
    int bytespp = (bpp > 0 ? bpp / 8 : 4); if (bytespp < 1) bytespp = 4;
    // 1) Preferred: the detiled composite WS writes to the mmap'd file
    //    /tmp/macws_vnc_fb (IOSurfaceIsGlobal+Lookup is NULL cross-process on
    //    this iOS, so we use a shared mmap instead). Header (16B): magic 'VNCF',
    //    w, h, stride; BGRA8 data follows. Gradient is the fallback.
    static void *rmap = NULL; static size_t rmap_sz = 0;
    if (!rmap) {
        int fd = open("/tmp/macws_vnc_fb", O_RDONLY);
        if (fd >= 0) {
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size >= 16) {
                void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
                if (m != MAP_FAILED) { rmap = m; rmap_sz = (size_t)st.st_size; }
            }
            close(fd);
        }
    }
    if (rmap && rmap_sz >= 16) {
        uint32_t *hdr = (uint32_t *)rmap;
        if (hdr[0] == 0x564E4346u) {
            size_t sh = hdr[2], sstride = hdr[3];
            char *data = (char *)rmap + 16;
            if (16 + sstride * sh <= rmap_sz) {
                size_t cw = ((size_t)padded < sstride) ? (size_t)padded : sstride;
                size_t rows = ((size_t)height < sh) ? (size_t)height : sh;
                for (size_t y = 0; y < rows; y++)
                    memcpy(macws_vnc_fb + y * (size_t)padded, data + y * sstride, cw);
                return;
            }
        }
    }
    // 2) Fallback: test gradient (only when /tmp/macws_vnc_test exists).
    if (!macws_vnc_test_on) return;
    int pxw = padded / bytespp;
    for (int y = 0; y < height; y++) {
        unsigned char *row = (unsigned char *)macws_vnc_fb + (size_t)y * padded;
        for (int x = 0; x < pxw; x++) {
            unsigned char *p = row + (size_t)x * bytespp;
            p[0] = (unsigned char)((x * 255) / (pxw ? pxw : 1)); // X ramp
            p[1] = (unsigned char)((y * 255) / height);          // Y ramp
            p[2] = 0x40;
            if (bytespp >= 4) p[3] = 0xff;
        }
    }
}

// 2026-06-21 LEAK FIX: OSXvnc's original rfbGetFramebufferUpdateInRect re-captures
// the desktop every frame via CGDisplayCreateImage → SLSHWCaptureDesktop →
// WindowServer's _XHWCaptureDesktop allocates a fresh full-screen 15MB IOSurface
// PER FRAME that isn't recycled → unbounded leak → WS Jetsam + DCP-RTKit OOM panic
// (symbol-traced via IOSURF_STATS backtrace 2026-06-21). We OVERWRITE the framebuffer
// with our own content (mmap/gradient) anyway, so the original capture is pure waste.
// Skip it to stop the leak. Gated /tmp/macws_vnc_skipcap so it can be A/B'd; once
// proven this should be the default (the orig capture serves no purpose for us).
// THROTTLE the per-frame capture: the orig CGDisplayCreateImage capture both DRIVES
// WS's compositing (in coexist there's no physical display, so capture requests are
// WS's only render trigger — fully skipping it makes WS idle/exit) AND leaks a 15MB
// WS-side IOSurface per call. So call orig only 1-in-N to keep WS driven while cutting
// the leak (and DCP-panic) rate ~N×. N from /tmp/macws_vnc_capthrottle content (default
// 12); absent → no throttle (orig every frame, original behavior).
static int macws_cap_throttle = -2;
static int macws_cap_throttle_n(void) {
    if (macws_cap_throttle == -2) {
        macws_cap_throttle = 0;
        FILE *f = fopen("/tmp/macws_vnc_capthrottle", "r");
        if (f) { int v=0; if (fscanf(f, "%d", &v)==1 && v>0) macws_cap_throttle = v; else macws_cap_throttle = 12; fclose(f); }
    }
    return macws_cap_throttle;   // 0 = no throttle
}
static char *macws_new_rfbGetFB(void) {
    char *p = macws_orig_rfbGetFB ? macws_orig_rfbGetFB() : NULL;
    macws_vnc_fb = p;
    macws_vnc_fill_test();
    return p;
}
static void macws_new_rfbGetFBRect(int x, int y, int w, int h) {
    static unsigned long callno = 0;
    int n = macws_cap_throttle_n();
    int do_orig = (n <= 0) ? 1 : ((callno++ % (unsigned)n) == 0);
    if (macws_orig_rfbGetFBRect && do_orig) macws_orig_rfbGetFBRect(x, y, w, h);
    macws_vnc_fill_test();
}

static void macws_install_osxvnc_hooks(void) {
    const char *prog = getprogname();
    if (!prog || !strstr(prog, "OSXvnc")) return;
    macws_vnc_test_on = (access("/tmp/macws_vnc_test", F_OK) == 0);
    const struct mach_header *mh = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "OSXvnc-server")) { mh = _dyld_get_image_header(i); break; }
    }
    if (!mh) mh = _dyld_get_image_header(0);
    if (!mh) return;
    char *base = (char *)mh;
    macws_rfbScreen = (int *)(base + 0x79bf8);
    MSHookFunction(base + 0xd9d4, (void *)macws_new_rfbGetFB,     (void **)&macws_orig_rfbGetFB);
    MSHookFunction(base + 0xdc28, (void *)macws_new_rfbGetFBRect, (void **)&macws_orig_rfbGetFBRect);
    fprintf(stderr, "#### OSXVNC delivery hooks installed (test=%d) base=%p rfbScreen=%p\n",
            macws_vnc_test_on, (void *)mh, (void *)macws_rfbScreen);
}

// DIAGNOSTIC (gated /tmp/macws_raise_footprint, content=MB default 12288, or env
// MACWS_FOOTPRINT_MB). lldb-confirmed 2026-06-21: WS is killed by a per-task
// phys_footprint EXC_RESOURCE high-watermark (limit=5120 MB) — the AGX-native
// compositor's GPU working set (~6.3GB) genuinely exceeds it, and cutting
// footprint can't get under (Mempool just allocates more chunks). Raise the
// task's own footprint limit so we can peel past this wall and test the
// downstream render path (the layout=3 shadow crash etc.). This is the
// "necessary component" half of the fix, NOT a standalone band-aid.
extern kern_return_t task_set_phys_footprint_limit(task_t task, int new_limit_mb, int *old_limit_mb);
__attribute__((constructor)) static void macws_raise_footprint_limit(void) {
    if (!getenv("MACWS_RAISE_FOOTPRINT") && access("/tmp/macws_raise_footprint", F_OK) != 0) return;
    int mb = 12288;
    const char *e = getenv("MACWS_FOOTPRINT_MB");
    if (e) mb = atoi(e);
    else { FILE *f = fopen("/tmp/macws_raise_footprint", "r");
           if (f) { int v = 0; if (fscanf(f, "%d", &v) == 1 && v > 0) mb = v; fclose(f); } }
    int old = -1;
    kern_return_t kr = task_set_phys_footprint_limit(mach_task_self(), mb, &old);
    fprintf(stderr, "#### FOOTPRINT-RAISE set_phys_footprint_limit(%d MB) kr=%d old=%d MB\n", mb, kr, old);
}

// B: SYNTHETIC VSYNC DRIVER (gated /tmp/macws_vsync_drive, WindowServer only).
// In coexist there's no physical vblank, so WS's per-frame composite callback is
// never armed (gate _WSCurrentSessionDrawsToFramebuffer=0) → windows never get
// composited into the display dest (only ~3-6%). RE (agent, SkyLight.bndb):
// update_display_callback@0x18536ed0c composites ALL windows, armed by
// _CGXScheduleUpdateDisplay@0x18536f9c8. We replace the missing vblank: a 60Hz
// MAIN-QUEUE dispatch timer calls CGXScheduleUpdateDisplay(NULL,1,0) (must run on
// the WS main thread for correct session context — hence main queue, not a bg
// pthread). Result lands in the same SLCADisplay dest IOSurface we already read.
static void macws_install_vsync_driver(void) {
    if (access("/tmp/macws_vsync_drive", F_OK) != 0) return;
    const char *pn = getprogname();
    if (!pn || !strstr(pn, "WindowServer")) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Defer onto the main queue so it runs AFTER WS sets up its run-loop/session.
        dispatch_async(dispatch_get_main_queue(), ^{
            // CGXScheduleUpdateDisplay is a PRIVATE (non-exported) SkyLight symbol —
            // dlsym fails; MSFindSymbol reads the symbol table incl. local symbols.
            extern const char *SkyLightPath;
            MSImageRef sl = MSGetImageByName(SkyLightPath);
            void *sched = sl ? MSFindSymbol(sl, "_CGXScheduleUpdateDisplay") : NULL;
            if (!sched && sl) sched = MSFindSymbol(sl, "_SLSScheduleUpdateDisplay");
            fprintf(stderr, "#### VSYNC-DRIVE: sl=%p CGXScheduleUpdateDisplay=%p\n", (void *)sl, sched);
            if (!sched) { fprintf(stderr, "#### VSYNC-DRIVE: symbol unresolved\n"); return; }
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 16ull * NSEC_PER_MSEC, 4ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(t, ^{
                static _Atomic int n = 0;
                int k = atomic_fetch_add(&n, 1);
                if (k < 3 || (k % 120) == 0) fprintf(stderr, "#### VSYNC-DRIVE tick %d\n", k);
                ((void (*)(void *, int, int))sched)(NULL, 1, 0);
            });
            dispatch_resume(t);   // leak intentionally — lives for process lifetime
            fprintf(stderr, "#### VSYNC-DRIVE: 60Hz main-queue timer installed\n");
        });
    });
}

__attribute__((constructor)) void InitStuff() {
    // DEBUG (gated /tmp/macws_suspend_ws): SIGSTOP WindowServer in its ctor so
    // lldb can attach BEFORE AGX/GPU init (setupDeferred queue/heap creates that
    // return 0xe00002c2). Gated to WindowServer ONLY via progname so other chroot
    // execs (run_bash helpers, MTLCompilerService, etc.) don't wedge — cf. the
    // fork/exit-trace deadlock [[fork-deadlock-from-exit-trace-diagnostic]].
    // Resume with: process signal SIGCONT (or `continue` after breakpoints set).
    if (access("/tmp/macws_suspend_ws", F_OK) == 0) {
        const char *pn = getprogname();
        if (pn && strstr(pn, "WindowServer")) {
            fprintf(stderr, "#### MACWS_SUSPEND_WS: SIGSTOP pid=%d — attach lldb, set bps, then SIGCONT\n", getpid());
            raise(SIGSTOP);
            fprintf(stderr, "#### MACWS_SUSPEND_WS: resumed pid=%d\n", getpid());
        }
    }
    macws_install_vsync_driver();   // B: drive coexist composite (gated /tmp/macws_vsync_drive)
    // DIAG (gated /tmp/macws_lbuf_stderr): make stderr LINE-buffered (_IOLBF) so
    // Metal's MTLReportFailure/__assert_rtn message (which ends in \n) flushes to
    // WindowServer.err before abort(). Far lighter than _IONBF (per-char) — only
    // flushes on newline, which fprintf already emits, so minimal perturbation.
    if (access("/tmp/macws_lbuf_stderr", F_OK) == 0) {
        setvbuf(stderr, NULL, _IOLBF, 4096);
    }
    EnableJIT();
    macws_install_crash_diag();
    macws_install_osxvnc_hooks();
    // HID bypass is OPT-IN. Whole-IOKit-symbol hooking creates a tower of
    // MSHook'd functions; if any one of them is itself called recursively
    // via PAC-signed pointers from elsewhere in IOKit, the bypass starts
    // cascading crashes. In practice, WindowServer survives the original
    // CFBinaryPlist BUS_ADRALN crash by itself most of the time once the
    // other AGX-native patches are in place, so don't install the bypass
    // by default. Re-enable with MACWS_HID_BYPASS=1 on a process whose
    // IOMFB/SkyLight HID setup is reliably crashing.
    // Targeted fix for the IOMFBServer thread BUS_ADRALN: skip just the
    // CFBinaryPlist deserialize step inside IOKit's HID-property cache.
    macws_install_iohid_unserialize_bypass();
    // AGX renamer patch — opt-in via MACWS_AGX_RENAMER_PATCH=1.
    macws_install_agx_renamer_patch();
    // (AGCLLVMCtx::compile fast-math hook attempt — VERIFIED NOT
    // CALLED for CA pipeline compiles. The fast-math AIR-intrinsic
    // rename happens in AGCLLVMUserObject::compile's optimization
    // passes which read FastMathFlags from each llvm::Instruction's
    // own metadata, NOT from the AGCFastMathFlags arg to
    // AGCLLVMCtx::compile. Env-level toggles
    // AGC_ENABLE_F16_FASTMATH_BUILTINS=0 and AGC_DISABLE_OPTIMIZATIONS
    // also fail to suppress the rename. Real fix requires either
    // patching the rename pass directly or rewriting the LLVM IR
    // before it reaches the AGX backend — open work. The
    // QC-metallib-substitute fallback in Metal_hooks.x stays available
    // via MACWS_PIPELINE_FALLBACK=1 as a temporary survival path while
    // the proper fix is being designed.)
    if (getenv("MACWS_AGC_FASTMATH_HOOK")) {
        macws_install_agc_fastmath_disable();
    }
    // Verify-bypass experiment: if the unlowered `agx.air.fract.v3f16.fast`
    // is benign (codegen has a fallback or never executes it on the
    // observed CA pipelines), bypassing the verifier is the simplest
    // viable elegant fix. Opt-in via env to keep the verifier honest
    // in normal operation.
    if (getenv("MACWS_AGC_VERIFY_BYPASS")) {
        const char *path =
            "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/Versions/A/AGXCompilerCore";
        void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        (void)h;
        MSImageRef img = MSGetImageByName(path);
        if (img) {
            macws_install_agc_verify_bypass(img);
        } else {
            fprintf(stderr,
                "#### MACWS_AGC_VERIFY_BYPASS: AGXCompilerCore not in "
                "image table, skip\n");
        }
    }
    // Optional: trace which abort_with_payload site fires (opt-in via env).
    macws_install_abort_trace();
    // Optional: trace voluntary exit()/_exit() call sites (file-gated).
    macws_install_exit_trace();
    // Assert bypass needs no env gate — it's strictly defensive against
    // CA::OGL::MetalContext assert() calls that fire as a downstream
    // consequence of a failed pipeline build.
    macws_install_assert_bypass();
    // Broader bulk hook (one stub per public `IOHIDEventSystem*` symbol)
    // is opt-in and currently unstable — see the comment block in
    // `macws_install_iomfb_hid_bypass`. Keep it accessible for debugging.
    if (getenv("MACWS_HID_BYPASS")) {
        macws_install_iomfb_hid_bypass();
    }

    // Pre-load IOGPU BEFORE Metal.framework speculatively loads AGXMetal13_3.
    // AGXMetal13_3 has cross-image GOT entries that reference IOGPU symbols
    // (the pool allocator, IOGPUMetalResource helpers, ...). If IOGPU is not
    // yet in the address space when dyld binds AGXMetal13_3, those slots
    // resolve to null/<unresolved>. A later dlopen of IOGPU does NOT trigger
    // a re-bind, so the slots stay broken and AGX::Mempool::grow's lambda
    // tail-jumps into garbage (SIGSEGV at addr 0x30, see memory note
    // agx-mempool-grow-fault-decomposed). Doing this in the constructor
    // (instead of in the getMetalPluginClassForService hook) guarantees IOGPU
    // is bound before Metal touches AGXMetal13_3.
    if (getenv("MACWS_AGX_NATIVE")) {
        const char *iogpuPaths[] = {
            "/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
            "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU",
            NULL
        };
        void *iogpu = NULL;
        for (int i = 0; iogpuPaths[i]; i++) {
            iogpu = dlopen(iogpuPaths[i], RTLD_GLOBAL | RTLD_NOW);
            if (iogpu) {
                fprintf(stderr, "#### MACWS_AGX_NATIVE [ctor] pre-loaded IOGPU via %s -> %p\n",
                    iogpuPaths[i], iogpu);
                break;
            }
        }
        if (!iogpu) {
            fprintf(stderr, "#### MACWS_AGX_NATIVE [ctor] could NOT pre-load IOGPU: %s\n", dlerror());
        }
    }

    _dyld_register_func_for_add_image((void (*)(const struct mach_header *, intptr_t))loadImageCallback);
}

extern int gpu_bundle_find_trusted(const char *name, char *trusted_path, size_t trusted_path_len);

int sysctlbyname_new(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // printf("debugbydcmmc Calling interposed sysctlbyname\n");
    if (name && oldp) {
        if(!strcmp(name, "kern.osvariant_status")) {
            *(unsigned long long *)oldp = 0x70010000f388828b; // bit 0 = diagnostics enabled
            return 0;
        } else if(!strcmp(name, "kern.osproductversion")) {
            sysctlbyname(name, oldp, oldlenp, newp, newlen);
            char *version = (char *)oldp;
            assert(version[0] == '1');
            if(version[1] >= '4') {
                version[1] -= 3; // 16 -> 13
            } else {
                version[1] = '1'; // always macOS 11
            }
            return 0;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char **params, char **errorbuf);
int sandbox_init_with_parameters_new(const char *profile, uint64_t flags, const char **params, char **errorbuf) {
    // printf("debugbydcmmc Calling interposed sandbox_init_with_parameters\n");
    return 0;
}

kern_return_t mach_port_construct_new(ipc_space_t task, mach_port_options_ptr_t options, uint64_t context, mach_port_name_t *name) {
    options->flags &= ~MPO_TG_BLOCK_TRACKING;
    return mach_port_construct(task, options, context, name);
}

// Simulate functions that are not implemented in iOS kernel
au_asid_t audit_token_to_asid_new(audit_token_t atoken) {
    // fake asid to pid
    return atoken.val[6] = atoken.val[5];
}
uid_t audit_token_to_auid_new(audit_token_t atoken) {
    return atoken.val[0] = 501;
}
void auditinfo_fill(auditinfo_addr_t *addr) {
    if(addr->ai_asid == 0) {
        addr->ai_asid = getpid();
    }
    addr->ai_auid = 501;
    if(getuid() == 0) {
        addr->ai_mask.am_success = 0;
        addr->ai_mask.am_failure = 0;
    } else {
        addr->ai_mask.am_success = -1;
        addr->ai_mask.am_failure = -1;
    }
    addr->ai_termid.at_port = 0x3000002;
    addr->ai_termid.at_type = 0x4;
    memset(addr->ai_termid.at_addr, 0, sizeof(addr->ai_termid.at_addr));
    addr->ai_flags = 0x6030;
}
void auditpinfo_fill(auditpinfo_addr_t *addr) {
    if(addr->ap_pid == 0) {
        addr->ap_pid = getpid();
    }
    addr->ap_auid = 501;
    if(getuid() == 0) {
        addr->ap_mask.am_success = 0;
        addr->ap_mask.am_failure = 0;
    } else {
        addr->ap_mask.am_success = -1;
        addr->ap_mask.am_failure = -1;
    }
    addr->ap_termid.at_port = 0x3000002;
    addr->ap_termid.at_type = 0x4;
    memset(addr->ap_termid.at_addr, 0, sizeof(addr->ap_termid.at_addr));
    addr->ap_asid = addr->ap_pid;
    addr->ap_flags = 0x6030;
}
int auditon_new(int cmd, void *data, uint32_t length) {
    if(!data) {
        errno = EINVAL;
        return -1;
    }
    switch(cmd) {
        case A_GETSINFO_ADDR: {
            auditinfo_addr_t *addr = (auditinfo_addr_t *)data;
            auditinfo_fill(addr);
        } return 0;
        case A_GETPINFO_ADDR: {
            auditpinfo_addr_t *addr = (auditpinfo_addr_t *)data;
            auditpinfo_fill(addr);
        } return 0;
        case A_GETCOND: {
            if(length < sizeof(int)) {
                errno = EINVAL;
                return -1;
            }
            int *cond = (int *)data;
            *cond = 2; // AUC_NOAUDIT
        } return 0;
        default:
            NSLog(@"auditon: unimplemented cmd: %d", cmd);
            abort();
    }
}
int getaudit_addr_new(auditinfo_addr_t *auditinfo_addr, u_int length) {
    if(auditinfo_addr == NULL || length < sizeof(auditinfo_addr_t)) {
        return EINVAL;
    }
    auditinfo_addr->ai_asid = getpid();
    auditinfo_fill(auditinfo_addr);
    return 0;
}

IOSurfaceRef IOSurfaceCreate_new(NSMutableDictionary *properties) {
    // WindowServer composites window content into Apple-GPU LOSSLESS-COMPRESSED / TILED
    // IOSurfaces (IOSurfacePlaneCompressionType != 0, pf 0x26425241, 16x16 tiles). The
    // MTLSimDevice simulator cannot read/write compressed-tiled textures, so the composited
    // CONTENT comes out BLACK (chrome, drawn uncompressed, is fine). Detect a compressed
    // surface and rebuild it as PLAIN UNCOMPRESSED BGRA (linear) so the sim Metal device can
    // write it. See memory agx-direct-path-kernel-abi-deadend UPDATE 12.
    int w = [[properties objectForKey:@"IOSurfaceWidth"] intValue];
    int h = [[properties objectForKey:@"IOSurfaceHeight"] intValue];
    NSArray *planes = [properties objectForKey:@"IOSurfacePlaneInfo"];
    BOOL compressed = NO;
    if([planes isKindOfClass:[NSArray class]]) {
        for(NSDictionary *pl in planes) {
            id ct = [pl objectForKey:@"IOSurfacePlaneCompressionType"];
            if(ct && [ct intValue] != 0) { compressed = YES; break; }
        }
    }
    NSDictionary *useProps = properties;
    if(compressed && w > 0 && h > 0) {
        const int bpe = 4;                 // BGRA8888
        size_t bytesPerRow = (size_t)w * bpe;
        size_t planeSize   = bytesPerRow * (size_t)h;
        NSMutableDictionary *np = [NSMutableDictionary dictionary];
        np[@"IOSurfaceWidth"]  = @(w);
        np[@"IOSurfaceHeight"] = @(h);
        np[@"IOSurfacePixelFormat"] = @((unsigned int)'BGRA');   // 0x42475241, uncompressed
        np[@"IOSurfaceBytesPerElement"] = @(bpe);
        np[@"IOSurfaceBytesPerRow"] = @(bytesPerRow);
        np[@"IOSurfaceAllocSize"] = @(planeSize);
        np[@"IOSurfaceCacheMode"] = [properties objectForKey:@"IOSurfaceCacheMode"] ?: @0;
        np[@"IOSurfacePixelSizeCastingAllowed"] = @0;
        // single linear plane, no compression keys
        np[@"IOSurfacePlaneInfo"] = @[ @{
            @"IOSurfacePlaneWidth": @(w),
            @"IOSurfacePlaneHeight": @(h),
            @"IOSurfacePlaneBytesPerRow": @(bytesPerRow),
            @"IOSurfacePlaneBytesPerElement": @(bpe),
            @"IOSurfacePlaneElementWidth": @1,
            @"IOSurfacePlaneElementHeight": @1,
            @"IOSurfacePlaneOffset": @0,
            @"IOSurfacePlaneSize": @(planeSize),
            @"IOSurfaceAddressFormat": @0,
        } ];
        useProps = np;
    }
    IOSurfaceRef result = IOSurfaceCreate((NSDictionary *)useProps);
    // Log EVERY surface (size + format + compression) to map the full topology — the per-window
    // content source surface (e.g. 500x350) vs the 1920x1080 display/composite surfaces.
    unsigned int pf = [[properties objectForKey:@"IOSurfacePixelFormat"] unsignedIntValue];
    char fcc[5] = { (char)(pf>>24), (char)(pf>>16), (char)(pf>>8), (char)pf, 0 };
    fprintf(stderr, "#### IOSURF %dx%d pf=0x%x('%s') comp=%d -> %p%s\n",
            w, h, pf, fcc, (int)compressed, (void*)result, compressed ? " [DECOMP]" : "");
    return result;
}

DYLD_INTERPOSE(sysctlbyname_new, sysctlbyname);
DYLD_INTERPOSE(sandbox_init_with_parameters_new, sandbox_init_with_parameters);
DYLD_INTERPOSE(mach_port_construct_new, mach_port_construct);
DYLD_INTERPOSE(audit_token_to_asid_new, audit_token_to_asid);
DYLD_INTERPOSE(audit_token_to_auid_new, audit_token_to_auid);
DYLD_INTERPOSE(auditon_new, auditon);
DYLD_INTERPOSE(getaudit_addr_new, getaudit_addr);

// ─── objc_alloc tracer for AGX classes ──────────────────────────────────────
// When AGXMetal13_3's AGX::Mempool::grow lambda calls objc_alloc(AGXBuffer),
// the GOT slot for objc_alloc is resolved via our walker. If that slot still
// returns nil — either because the slot isn't bound or because libobjc's
// alloc dispatch fails on an under-realized class — Mempool gets nil buffers
// and setupDeferred crashes at +0x180 dereferencing the first buffer field.
// Interpose objc_alloc so every AGX-named class allocation gets logged AND
// gets a class_createInstance fallback if libobjc's alloc returns nil.
// objc_alloc trace: ONLY active when the experimental "register AGX classes"
// flag is set. Otherwise it's a pure passthrough (same behavior as no
// interpose) so the prior stable baseline stays unaffected.
extern id objc_alloc(Class);
id objc_alloc_trace(Class cls) {
    id r = objc_alloc(cls);
    if (!getenv("MACWS_AGX_REGISTER_CLASSES")) return r;
    if (cls) {
        const char *n = class_getName(cls);
        if (n && strncmp(n, "AGX", 3) == 0) {
            static int agx_alloc_count = 0;
            if (agx_alloc_count++ < 6) {
                fprintf(stderr, "#### objc_alloc(%s) -> %p\n", n, r);
            }
        }
    }
    return r;
}
DYLD_INTERPOSE(objc_alloc_trace, objc_alloc);

// ─── CARenderServer bootstrap-name rewrite ──────────────────────────────────
// The macOS window-content pipeline ships each app's rendered IOSurface to
// WindowServer over a CARenderServer connection.  WindowServer
// bootstrap_check_in("com.apple.CARenderServer") and clients
// bootstrap_look_up("com.apple.CARenderServer") (QuartzCore
// CARenderServerGetServerPort, hardcoded string).  But iOS launchd never
// publishes the com.apple.CARenderServer endpoint (it is declared in the WS
// plist yet dropped -- count 0 system-wide, not a name conflict; apparently a
// reserved iOS name).  So WS's check-in fails, clients' look-up fails, no remote
// context is formed, and window CONTENT never reaches WindowServer -> black
// (chrome still shows, drawn by WS from window geometry).
//
// Fix: rewrite the bootstrap name on BOTH sides to an unreserved name that our
// WindowServer LaunchDaemon plist declares (com.apple.macosbooter.CARenderServer),
// so check-in publishes a port and look-up resolves it.  Same DYLD_INSERT runs in
// WS and clients, so both rewrites are consistent.
#define CARENDER_ORIG "com.apple.CARenderServer"
#define CARENDER_NEW  "com.apple.macosbooter.CARenderServer"
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
kern_return_t bootstrap_look_up_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    BOOL ca = (name && !strcmp(name, CARENDER_ORIG));
    if(ca) name = CARENDER_NEW;
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    if(ca) fprintf(stderr, "#### CARENDER look_up by %s -> kr=%#x port=%#x\n",
                   getprogname() ?: "?", kr, sp ? *sp : 0);
    return kr;
}
kern_return_t bootstrap_check_in_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    BOOL ca = (name && !strcmp(name, CARENDER_ORIG));
    if(ca) name = CARENDER_NEW;
    kern_return_t kr = bootstrap_check_in(bp, name, sp);
    if(ca) fprintf(stderr, "#### CARENDER check_in by %s -> kr=%#x port=%#x\n",
                   getprogname() ?: "?", kr, sp ? *sp : 0);
    return kr;
}
DYLD_INTERPOSE(bootstrap_look_up_new, bootstrap_look_up);
DYLD_INTERPOSE(bootstrap_check_in_new, bootstrap_check_in);

// 2026-06-19 RE: chroot's texture super-init failure traces to
// `-[IOGPUMetalResource initWithDevice:remoteStorageResource:options:args:
// argsSize:]` returning nil at the GetClientShared cbz check. Original
// hypothesis was CF-type-id mismatch; runtime+disasm refined: macOS
// `_IOGPUResourceCreate` (unslid 0x19d156140..0x19d156248) builds a CF
// wrapper after kernel sel=0xa returns. On the success leg it copies
// fields out of `outStruct`:
//   wrapper[+0x40] = outStruct[+0x48]
//   wrapper[+0x48] = outStruct[+0x10]   ← what GetClientShared returns
// `_IOGPUResourceGetClientShared(wrapper)` returns wrapper[+0x48]. The
// orig init then `cbz x0, error` — if wrapper[+0x48] == 0, releases self
// and returns nil. So if iOS kernel doesn't populate outStruct[+0x10]
// for the chroot's texture-path call, the whole texture init dies.
//
// NOT FIXED YET — next step is to actually read outStruct[+0x10] at
// runtime for the failing call (via lldb at the wrapper-construction
// site, +0x19d1561d8 / +0x19d15621c) to confirm it's NULL, then dig into
// iOS userland's `_IOGPUResourceCreate` to see what args bit makes iOS
// kernel populate that field. Then patch our IOConnectCallMethod_new
// args swap so kernel returns a valid value there.
//
// The simplest hack (DYLD_INTERPOSE GetClientShared to fall back to the
// resource pointer when it returns NULL) was tried + reverted — user
// asked for structural understanding first, not whack-a-mole.

// ── BYPASS-COMPRESSION (gated /tmp/macws_uncompress) ───────────────────────
// Rewrite SkyLight's compressed '&b38' "CA Framebuffer" composite dest into a
// plain BGRA8 LINEAR (uncompressed) surface (Asahi: linear ⟹ never compressed),
// so the AGX composite renders the logo as plain pixels we can read directly —
// no decompress, no detile, no cross-hatch. The existing DYLD_INTERPOSE
// (IOSurfaceCreate_safe) CANNOT reach the composite: SkyLight's IOSurfaceCreate
// call inside _MetalCompositeCoreAnimation is an intra-shared-cache DIRECT bind
// that DYLD_INTERPOSE can't redirect. MSHookFunction patches the function itself,
// so the direct bind hits it too.
static IOSurfaceRef (*orig_IOSurfaceCreate_ms)(CFDictionaryRef) = NULL;

static NSMutableDictionary *macws_caframebuffer_to_bgra8_linear(CFDictionaryRef properties_cf) {
    if (!properties_cf || CFGetTypeID(properties_cf) != CFDictionaryGetTypeID()) return nil;
    CFNumberRef pfNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfacePixelFormat"));
    uint32_t pf = 0;
    if (pfNum && CFGetTypeID(pfNum) == CFNumberGetTypeID()) CFNumberGetValue(pfNum, kCFNumberSInt32Type, &pf);
    if ((pf & 0xFF000000u) != 0x26000000u) return nil;   // Apple-compression marker (high byte 0x26)
    CFStringRef name = (CFStringRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceName"));
    if (!(name && CFGetTypeID(name) == CFStringGetTypeID() &&
          CFStringCompare(name, CFSTR("CA Framebuffer"), 0) == kCFCompareEqualTo)) return nil;
    CFNumberRef wNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
    CFNumberRef hNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
    int w = 0, h = 0;
    if (wNum && CFGetTypeID(wNum) == CFNumberGetTypeID()) CFNumberGetValue(wNum, kCFNumberSInt32Type, &w);
    if (hNum && CFGetTypeID(hNum) == CFNumberGetTypeID()) CFNumberGetValue(hNum, kCFNumberSInt32Type, &h);
    if (w <= 0 || h <= 0) return nil;
    const int bpe = 4;
    size_t bytesPerRow = ((size_t)w * (size_t)bpe + 63u) & ~63ul;   // BytesPerRow set ⟹ Linear ⟹ uncompressed
    size_t planeSize = bytesPerRow * (size_t)h;
    NSMutableDictionary *np = [NSMutableDictionary dictionary];
    np[@"IOSurfaceWidth"] = @(w); np[@"IOSurfaceHeight"] = @(h);
    np[@"IOSurfacePixelFormat"] = @((unsigned int)'BGRA');   // 0x42475241, plain uncompressed BGRA8
    np[@"IOSurfaceBytesPerElement"] = @(bpe);
    np[@"IOSurfaceBytesPerRow"] = @(bytesPerRow);
    np[@"IOSurfaceAllocSize"] = @(planeSize);
    np[@"IOSurfaceName"] = @"CA Framebuffer";   // preserve identity so SkyLight still treats it as the dest
    CFNumberRef wsFlag = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("CAWindowServerSurface"));
    if (wsFlag) np[@"CAWindowServerSurface"] = (__bridge id)wsFlag;
    return np;
}

static IOSurfaceRef hooked_IOSurfaceCreate(CFDictionaryRef properties_cf) {
    static int s_on = -1;
    if (s_on < 0) s_on = (access("/tmp/macws_uncompress", F_OK) == 0) ? 1 : 0;
    if (s_on) {
        // DIAG: log the first calls' pf+name+size so we can see whether the '&b38'
        // composite dest is even created via this IOSurfaceCreate (or elsewhere).
        static int s_cn = 0;
        if (s_cn < 50 && properties_cf && CFGetTypeID(properties_cf) == CFDictionaryGetTypeID()) {
            s_cn++;
            uint32_t dpf = 0; CFNumberRef pn = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfacePixelFormat"));
            if (pn && CFGetTypeID(pn) == CFNumberGetTypeID()) CFNumberGetValue(pn, kCFNumberSInt32Type, &dpf);
            CFStringRef nm = (CFStringRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceName"));
            char nb[64] = "?"; if (nm && CFGetTypeID(nm) == CFStringGetTypeID()) CFStringGetCString(nm, nb, 64, kCFStringEncodingUTF8);
            int dw = 0, dh = 0;
            CFNumberRef wn = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
            CFNumberRef hn = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
            if (wn && CFGetTypeID(wn) == CFNumberGetTypeID()) CFNumberGetValue(wn, kCFNumberSInt32Type, &dw);
            if (hn && CFGetTypeID(hn) == CFNumberGetTypeID()) CFNumberGetValue(hn, kCFNumberSInt32Type, &dh);
            fprintf(stderr, "#### UNCOMPRESS-CALL #%d pf=%#x name='%s' %dx%d\n", s_cn, dpf, nb, dw, dh);
        }
        NSMutableDictionary *np = macws_caframebuffer_to_bgra8_linear(properties_cf);
        if (np) {
            IOSurfaceRef r = orig_IOSurfaceCreate_ms((__bridge CFDictionaryRef)np);
            static int nl = 0; if (nl++ < 16)
                fprintf(stderr, "#### UNCOMPRESS: CA-Framebuffer '&b38' -> BGRA8 linear %p\n", (void *)r);
            return r;
        }
    }
    return orig_IOSurfaceCreate_ms(properties_cf);
}

// BYPASS-COMPRESSION: hook SkyLight's targetable-surface creator. The compressed
// '&b38' composite dest is created HERE (not via the public IOSurfaceCreate). Log
// every call's (w,h,format,protection,label); FORCE the full-screen Apple-compressed
// dest to plain BGRA8 so the AGX composite renders uncompressed. Gated /tmp/macws_uncompress.
static IOSurfaceRef hooked_ws_targetable(int w, int h, int format, uint64_t protection, const char *label) {
    static int s_cn = 0;
    if (s_cn < 40) { s_cn++;
        char fc[5] = { (char)format, (char)(format >> 8), (char)(format >> 16), (char)(format >> 24), 0 };
        fprintf(stderr, "#### WSTARGET #%d %dx%d format=%#x '%s' prot=%#llx label='%s'\n",
                s_cn, w, h, (unsigned)format, fc, (unsigned long long)protection, label ? label : "?");
    }
    if (access("/tmp/macws_uncompress", F_OK) == 0 && w >= 1900 && h >= 1400 &&
        (((unsigned)format & 0xFF000000u) == 0x26000000u)) {     // Apple-compression marker
        IOSurfaceRef r = orig_ws_targetable(w, h, (int)'BGRA', protection, label);
        static int nl = 0; if (nl++ < 8)
            fprintf(stderr, "#### WSTARGET-FORCE %dx%d %#x->'BGRA' -> %p\n", w, h, (unsigned)format, (void *)r);
        return r;
    }
    return orig_ws_targetable(w, h, format, protection, label);
}

// Tightly-scoped IOSurfaceCreate interposer — only rewrites SkyLight's "CA
// Framebuffer" 2-plane Apple-GPU-compressed BGRA10_XR surface (FourCC '&b38' /
// 0x26623338). Without rewrite, MTLSimDriverHost cannot wrap this IOSurface in
// any iOS-Metal-accepted MTLPixelFormat (we tried 552/553/94/90/80/81 — all NIL),
// so SkyLight asserts on its compositor destination and WS dies on every frame.
//
// The previous wide-scope rewrite crashed CoreImage-using apps (Terminal) because
// IOSurfaceCreate_new called -objectForKey: on a dict that turned out to be a
// non-NSDictionary CFType — PAC fault. We now (a) typecheck the input via
// CFGetTypeID == CFDictionaryGetTypeID, and (b) gate the rewrite on the
// IOSurfaceName key being EXACTLY "CA Framebuffer" plus the FourCC's high byte
// being 0x26 (Apple compression marker), which excludes every other surface.
IOSurfaceRef IOSurfaceCreate_safe(CFDictionaryRef properties_cf) {
    if (getenv("MACWS_IOSURF_TRACE") != NULL) {
        fprintf(stderr, "#### IOSURF_HOOK call cf=%p\n", (void *)properties_cf);
    }
    // OOM leak diagnostic (2026-06-20): count creates + per-caller bytes.
    // Every 25 calls, dump caller+size attribution so we can find who's
    // accumulating IOSurfaces against the 5120 MB WS watermark.
    {
        static _Atomic unsigned long s_count = 0;
        static _Atomic unsigned long s_total_bytes = 0;
        unsigned long my_n = atomic_fetch_add(&s_count, 1) + 1;
        size_t my_bytes = 0;
        if (properties_cf && CFGetTypeID(properties_cf) == CFDictionaryGetTypeID()) {
            CFNumberRef w = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
            CFNumberRef h = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
            CFNumberRef bpe = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceBytesPerElement"));
            int wi = 0, hi = 0, bi = 4;
            if (w && CFGetTypeID(w) == CFNumberGetTypeID()) CFNumberGetValue(w, kCFNumberSInt32Type, &wi);
            if (h && CFGetTypeID(h) == CFNumberGetTypeID()) CFNumberGetValue(h, kCFNumberSInt32Type, &hi);
            if (bpe && CFGetTypeID(bpe) == CFNumberGetTypeID()) CFNumberGetValue(bpe, kCFNumberSInt32Type, &bi);
            my_bytes = (size_t)wi * (size_t)hi * (size_t)bi;
        }
        unsigned long my_total = atomic_fetch_add(&s_total_bytes, my_bytes) + my_bytes;
        // Gated: the dladdr+__builtin_return_address(0..7) walk SIGSEGVs on shallow call
        // stacks (e.g. a standalone chroot CLI: main→IOSurfaceCreate has no 8 frames, so the
        // high return-address slots are garbage and dladdr() faults). It's a leak-attribution
        // DIAGNOSTIC — gate it behind MACWS_IOSURF_TRACE so non-WS callers don't crash.
        if (my_n % 250 == 1 && getenv("MACWS_IOSURF_TRACE") /* 1,251,501,... */) {
            Dl_info di;
            void *ra1 = __builtin_return_address(0);
            void *ra2 = __builtin_return_address(1);
            void *raN[8] = { ra1, ra2, __builtin_return_address(2), __builtin_return_address(3),
                             __builtin_return_address(4), __builtin_return_address(5),
                             __builtin_return_address(6), __builtin_return_address(7) };
            fprintf(stderr, "#### IOSURF_STATS n=%lu cum=%lu MB sz=%zu KB\n",
                    my_n, my_total / (1024*1024), my_bytes / 1024);
            for (int ci = 0; ci < 8; ci++) {
                const char *s = "?";
                if (raN[ci] && dladdr(raN[ci], &di) && di.dli_sname) s = di.dli_sname;
                fprintf(stderr, "  c%d=%s\n", ci+1, s);
            }
            (void)ra2;
        }
    }
    // ─── VNC capture-surface RECYCLE (gated /tmp/macws_vnc_cappool) ───────────
    // The VNC screen-capture path (WS::Capture::create_iosurface_for_window_list →
    // CompositorMetal::CreateCaptureSurface → CaptureSurfaceMetal::CreateMetalBacking,
    // driven by OSXvnc's per-frame CGDisplayCreateImage → _XHWCaptureDesktop) allocates
    // a FRESH full-screen 15MB IOSurface per frame that never frees → n→751 → Jetsam +
    // DCP-RTKit OOM panic (symbol-traced 2026-06-21). In coexist the captures are
    // load-bearing (only render trigger) so we can't skip/throttle them. Instead POOL:
    // reuse ONE retained surface per (w,h,pf) so n stays ~1 at full capture rate. Scoped
    // to the capture path via caller symbol (other surfaces untouched). __thread reent
    // guard avoids the libmachook double-interpose pooling twice.
    {
        static int s_cappool = -1;
        if (s_cappool < 0) s_cappool = (access("/tmp/macws_vnc_cappool", F_OK) == 0);
        static __thread int cap_reent = 0;
        if (s_cappool && !cap_reent && properties_cf &&
            CFGetTypeID(properties_cf) == CFDictionaryGetTypeID()) {
            int wi=0, hi=0, bi=4; uint32_t cpf=0;
            CFNumberRef cw =(CFNumberRef)CFDictionaryGetValue(properties_cf,(const void*)CFSTR("IOSurfaceWidth"));
            CFNumberRef ch =(CFNumberRef)CFDictionaryGetValue(properties_cf,(const void*)CFSTR("IOSurfaceHeight"));
            CFNumberRef cbe=(CFNumberRef)CFDictionaryGetValue(properties_cf,(const void*)CFSTR("IOSurfaceBytesPerElement"));
            CFNumberRef cpn=(CFNumberRef)CFDictionaryGetValue(properties_cf,(const void*)CFSTR("IOSurfacePixelFormat"));
            if (cw &&CFGetTypeID(cw )==CFNumberGetTypeID()) CFNumberGetValue(cw ,kCFNumberSInt32Type,&wi);
            if (ch &&CFGetTypeID(ch )==CFNumberGetTypeID()) CFNumberGetValue(ch ,kCFNumberSInt32Type,&hi);
            if (cbe&&CFGetTypeID(cbe)==CFNumberGetTypeID()) CFNumberGetValue(cbe,kCFNumberSInt32Type,&bi);
            if (cpn&&CFGetTypeID(cpn)==CFNumberGetTypeID()) CFNumberGetValue(cpn,kCFNumberSInt32Type,&cpf);
            if ((size_t)wi*(size_t)hi*(size_t)bi >= 0x400000) {  // only big (full-screen)
                int is_cap = 0; Dl_info cdi;
                void *rr[6] = { __builtin_return_address(0), __builtin_return_address(1),
                                __builtin_return_address(2), __builtin_return_address(3),
                                __builtin_return_address(4), __builtin_return_address(5) };
                // Pool BOTH the VNC capture path AND the dominant leak: the
                // display-page churn CA::WindowServer::Display::allocate_iosurface ←
                // IOMFBDisplay (pf=643969848, the page-recycle predicate discards it
                // every frame). Reusing one surface per (w,h,pf) IS the swapchain the
                // predicate failed to keep.
                // Pool ALL big (>=4MB) full-screen surfaces in WS by (w,h,pf): the
                // churn is across multiple allocators (capture BGRA, display-page
                // 643969848 via Display::allocate_iosurface, composite 1380411457 via
                // start_composite). Per-allocator symbol matching kept missing some;
                // for a full-screen WS surface of a churning format, reuse-by-(w,h,pf)
                // is the swapchain behavior. (Coexist WS has no unique-per-frame
                // full-screen consumer that needs distinct buffers — the page-recycle
                // predicate WANTED to reuse but discarded.)
                is_cap = 1; (void)cdi; (void)rr;
                { static int dl=0; if (dl++<16) { const char *s2="?",*s3="?"; Dl_info d2;
                    if (rr[2]&&dladdr(rr[2],&d2)&&d2.dli_sname) s2=d2.dli_sname;
                    if (rr[3]&&dladdr(rr[3],&d2)&&d2.dli_sname) s3=d2.dli_sname;
                    fprintf(stderr,"#### CAPDBG is_cap=%d %dx%d pf=%u sz=%zuKB c2=%.34s c3=%.34s\n",
                            is_cap,wi,hi,cpf,(size_t)wi*hi*bi/1024,s2,s3); } }
                if (is_cap) {
                    static NSMutableDictionary *capPool = nil; static dispatch_once_t capOnce;
                    dispatch_once(&capOnce, ^{ capPool = [NSMutableDictionary new]; });
                    NSString *k = [NSString stringWithFormat:@"%dx%d-%u-%d", wi, hi, cpf, bi];
                    IOSurfaceRef out = NULL;
                    @synchronized(capPool) {
                        NSValue *v = capPool[k];
                        if (v) { out = (IOSurfaceRef)[v pointerValue]; CFRetain(out); }
                    }
                    if (!out) {
                        cap_reent = 1;
                        @try { out = IOSurfaceCreate((NSDictionary *)properties_cf); }
                        @finally { cap_reent = 0; }   // ALWAYS reset (else stuck=>pool dies)
                        if (out) {
                            CFRetain(out);  // pool keeps a persistent ref
                            @synchronized(capPool) { capPool[k] = [NSValue valueWithPointer:out]; }
                            static int nl=0; if (nl++<24) fprintf(stderr,"#### CAPPOOL NEW %s -> %p (poolN=%lu)\n",[k UTF8String],(void*)out,(unsigned long)capPool.count);
                        }
                    } else {
                        static int hl=0; if (hl++<8) fprintf(stderr,"#### CAPPOOL HIT %s -> %p\n",[k UTF8String],(void*)out);
                    }
                    return out;
                }
            }
        }
    }
    if (!properties_cf) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    // Scope this rewrite to WindowServer ONLY. Other processes (Activity Monitor,
    // Terminal, etc.) crash in CFDictionaryGetValue when properties_cf is a
    // real NSMutableDictionary subclass — the toll-free bridge dispatches to
    // -[NSDictionary objectForKey:], and on-device arm64e PAC-faults when
    // hashing keys whose class pointer is iOS-signed. WindowServer is the only
    // caller that creates the '&b38' Apple-compressed CA Framebuffer surface
    // we need to rewrite anyway.
    {
        static int s_is_ws = -1;
        if (s_is_ws < 0) {
            const char *prog = getprogname();
            s_is_ws = (prog && strstr(prog, "WindowServer")) ? 1 : 0;
        }
        if (!s_is_ws) {
            return IOSurfaceCreate((NSDictionary *)properties_cf);
        }
    }
    // CoreImage sometimes passes a CFDictionary whose -objectForKey: is not a
    // real NSDictionary bridge — fall back to the raw CFDictionaryGetValue.
    if (CFGetTypeID(properties_cf) != CFDictionaryGetTypeID()) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    CFNumberRef pfNum = (CFNumberRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("IOSurfacePixelFormat"));
    uint32_t pf = 0;
    if (pfNum && CFGetTypeID(pfNum) == CFNumberGetTypeID()) {
        CFNumberGetValue(pfNum, kCFNumberSInt32Type, &pf);
    }
    BOOL is_apple_compressed = ((pf & 0xFF000000u) == 0x26000000u);
    CFStringRef name = (CFStringRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("IOSurfaceName"));
    BOOL is_ca_fb = NO;
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
        is_ca_fb = (CFStringCompare(name, CFSTR("CA Framebuffer"), 0) == kCFCompareEqualTo);
    }
    if (!(is_apple_compressed && is_ca_fb)) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    // Rebuild as plain BGRA8 — drop the compression-metadata plane and the
    // private FourCC so MTLSimDriverHost can wrap it as MTLPixelFormatBGRA8Unorm.
    CFNumberRef wNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceWidth"));
    CFNumberRef hNum = (CFNumberRef)CFDictionaryGetValue(properties_cf, (const void *)CFSTR("IOSurfaceHeight"));
    int w = 0, h = 0;
    if (wNum && CFGetTypeID(wNum) == CFNumberGetTypeID()) CFNumberGetValue(wNum, kCFNumberSInt32Type, &w);
    if (hNum && CFGetTypeID(hNum) == CFNumberGetTypeID()) CFNumberGetValue(hNum, kCFNumberSInt32Type, &h);
    if (w <= 0 || h <= 0) {
        return IOSurfaceCreate((NSDictionary *)properties_cf);
    }
    const int bpe = 4;                         // BGRA8 = 4 bytes/pixel
    size_t bytesPerRow = (size_t)w * (size_t)bpe;
    // Align to 64 bytes (typical Apple GPU stride alignment)
    bytesPerRow = (bytesPerRow + 63u) & ~63ul;
    size_t planeSize = bytesPerRow * (size_t)h;
    NSMutableDictionary *np = [NSMutableDictionary dictionary];
    np[@"IOSurfaceWidth"]  = @(w);
    np[@"IOSurfaceHeight"] = @(h);
    np[@"IOSurfacePixelFormat"] = @((unsigned int)'BGRA');   // 0x42475241
    np[@"IOSurfaceBytesPerElement"] = @(bpe);
    np[@"IOSurfaceBytesPerRow"] = @(bytesPerRow);
    np[@"IOSurfaceAllocSize"] = @(planeSize);
    np[@"IOSurfaceCacheMode"] = @0;
    np[@"IOSurfacePixelSizeCastingAllowed"] = @0;
    np[@"IOSurfaceName"] = @"CA Framebuffer";  // preserve identity
    // Carry CAWindowServerSurface so SkyLight still treats it as the compositor target.
    CFNumberRef wsFlag = (CFNumberRef)CFDictionaryGetValue(properties_cf,
        (const void *)CFSTR("CAWindowServerSurface"));
    if (wsFlag) np[@"CAWindowServerSurface"] = (__bridge id)wsFlag;
    np[@"IOSurfacePlaneInfo"] = @[ @{
        @"IOSurfacePlaneWidth": @(w),
        @"IOSurfacePlaneHeight": @(h),
        @"IOSurfacePlaneBytesPerRow": @(bytesPerRow),
        @"IOSurfacePlaneBytesPerElement": @(bpe),
        @"IOSurfacePlaneElementWidth": @1,
        @"IOSurfacePlaneElementHeight": @1,
        @"IOSurfacePlaneOffset": @0,
        @"IOSurfacePlaneSize": @(planeSize),
        @"IOSurfaceAddressFormat": @0,
    } ];
    IOSurfaceRef result = IOSurfaceCreate(np);
    if (result && !g_iosurface_isa) g_iosurface_isa = *(void **)result;   // reference isa for safe IOSurface ID
    fprintf(stderr, "#### IOSURF/CA_FB rewrote %dx%d pf=0x%x->BGRA8 result=%p\n",
        w, h, pf, (void *)result);
    return result;
}
DYLD_INTERPOSE(IOSurfaceCreate_safe, IOSurfaceCreate);

// NOTE: a caller-filtered IOSurfaceGetPixelFormat interpose to catch the CCA client IOSurface was tried
// and REMOVED — runtime-verified it fires (28x) but NEVER with a caller in the CCA range (in_cca=0): the
// SkyLight→IOSurface call inside _MetalCompositeCoreAnimation is an intra-dyld-shared-cache DIRECT bind
// that DYLD_INTERPOSE cannot redirect. It also broke WS (an always-on interpose returning 0 when
// dlsym(RTLD_NEXT) is null poisons every IOSurfaceGetPixelFormat). To grab the CCA client surface, use
// lldb at 0x185177294+slide or replicate the exact x9_11=*(window+0xf8+OFF)→+0x2b0→+0x18 chain in hooked_cca.

// DIAG (gated /tmp/macws_dest_diag): tag cross-process IOSurface origin. Logs every
// full-screen IOSurfaceLookupFromMachPort so we can tell whether the compose-dest's
// surfref (logged by DEST2) came from a cross-process lookup (macwsallocd) or an
// in-process create (CAPPOOL NEW). Interposer's call to the real fn does NOT recurse
// (same pattern as IOSurfaceCreate_safe → IOSurfaceCreate).
IOSurfaceRef IOSurfaceLookupFromMachPort_log(mach_port_t port) {
    IOSurfaceRef s = IOSurfaceLookupFromMachPort(port);
    if (s && access("/tmp/macws_dest_diag", F_OK) == 0) {
        size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
        if (w * h >= 0x4000) {       // window-sized+ (catches GlassDemo's window, the menu bar, fb)
            static int ll = 0;
            if (ll++ < 40) {
                // OPTION-2 GATE: read the looked-up (client) surface content. A window-sized surface with
                // nonzero content = GlassDemo's CG-rendered window arriving at WS → capture point for the
                // static-texture bypass. (Lookup may be pre-first-frame; the shared surface fills later.)
                IOSurfaceLock(s, 0x1 /*readonly*/, NULL);
                void *b = IOSurfaceGetBaseAddress(s); size_t sz = IOSurfaceGetAllocSize(s);
                size_t nz = 0, samp = 0;
                if (b && sz) for (size_t o = 0; o + 4 <= sz; o += 1021 * 4) { if (*(volatile uint32_t *)((char *)b + o) & 0xffffff) nz++; samp++; }
                IOSurfaceUnlock(s, 0x1, NULL);
                unsigned int pf = IOSurfaceGetPixelFormat(s);
                fprintf(stderr, "#### IOSLOOKUP port=%u -> %p %zux%zu pf=0x%x sz=%#zx nonzero=%.1f%%\n",
                        port, (void *)s, w, h, pf, sz, samp ? 100.0 * nz / samp : 0.0);
            }
        }
    }
    return s;
}
DYLD_INTERPOSE(IOSurfaceLookupFromMachPort_log, IOSurfaceLookupFromMachPort);

// IOKit
CFMutableDictionaryRef IOServiceNameMatching_new(const char *name) {
    // printf("debugbydcmmc IOServiceNameMatching called with name: %s\n", name);
    if (strcmp("IOSurfaceRoot", name) == 0) {
        return IOServiceNameMatching("IOCoreSurfaceRoot");
    } else if (strcmp("IOAccelerator", name) == 0) {
        return IOServiceNameMatching("IOAcceleratorES");
    }
    CFMutableDictionaryRef service = IOServiceNameMatching(name);
    if(!service) {
        fprintf(stderr, "debugbydcmmc IOServiceNameMatching not found for name: %s\n", name);
    }
    return service;
}

CFDictionaryRef IOServiceMatching_new(const char *name) {
    // printf("debugbydcmmc IOServiceMatching called with name: %s\n", name);
    if (name && strstr(name, "IOMobileFramebuffer") &&
        access("/tmp/macws_iomfb_trace", F_OK) == 0) {
        fprintf(stderr, "#### IOSVC-MATCH IOServiceMatching(\"%s\")\n", name);
    }
    if (strcmp("IOSurfaceRoot", name) == 0) {
        return IOServiceMatching("IOCoreSurfaceRoot");
    } else if (strcmp("IOAccelerator", name) == 0) {
        return IOServiceMatching("IOAcceleratorES");
    }
    CFMutableDictionaryRef service = IOServiceMatching(name);
    if(!service) {
        fprintf(stderr, "debugbydcmmc IOServiceMatching not found for name: %s\n", name);
    }
    return service;
}
DYLD_INTERPOSE(IOServiceNameMatching_new, IOServiceNameMatching);
DYLD_INTERPOSE(IOServiceMatching_new, IOServiceMatching);

// (IOMFB service matching CONFIRMED working in chroot — IOServiceMatching
// "IOMobileFramebuffer" + IOServiceGetMatchingService return valid svc handles.
// The per-call GetMatchingService interposes were removed: they added fprintf
// volume on every IOService lookup which perturbed WS startup (caused the
// non-deterministic early deaths). Keep matching unhooked.)

#ifndef FORCE_M1_DRIVER
kern_return_t IOServiceOpen_new(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect) {
    // clear flag 4 (FIXME: idk what is this)
    type &= ~4;
    kern_return_t result = IOServiceOpen(service, owningTask, type, connect);
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif

// don't discard our privilleges
int _libsecinit_initializer();
int _libsecinit_initializer_new() {
    return 0;
}
int setegid_new(gid_t gid) {
    return 0;
}
int seteuid_new(uid_t uid) {
    return 0;
}
DYLD_INTERPOSE(_libsecinit_initializer_new, _libsecinit_initializer);
DYLD_INTERPOSE(setegid_new, setegid);
DYLD_INTERPOSE(seteuid_new, seteuid);

// utilities
void ModifyExecutableRegion(void *addr, size_t size, void(^callback)(void)) {
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    callback();
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_EXEC);
}

#ifdef FORCE_M1_DRIVER
// IOKit
io_connect_t iogpuClients[10];
int iogpuClientsCount = 0;
static BOOL IOConnectIsIOGPU(io_connect_t client) {
    for(int i = 0; i < iogpuClientsCount; ++i) {
        if(iogpuClients[i] == client) {
            return YES;
        }
    }
    return NO;
}
static uint32_t IOConnectTranslateSelector(io_connect_t client, uint32_t selector) {
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

// AGX ID-translation shim. The iOS kernel AUTO-ASSIGNS resource GIDs (IOGPUObject
// atomic counter; getResource matches resource+0x28), but the macOS AGX driver uses
// CLIENT-ASSIGNED ids at IOGPUNewResourceArgs+0x48 (e.g. heap=0x20000, sub-resource
// parent-id=0x20000). libmachook is userspace-only (can't patch the kernel), so we
// bridge the two id-spaces here: record each created resource's clientID -> the
// iOS GID returned in its OUT struct, and rewrite parent-id references in 0x80
// sub-resources from clientID to the iOS GID so getResource() finds the parent.
static struct { uint64_t clientID, iosGID, size; } g_agxIdMap[128];
static int g_agxIdMapCount;

// ─── type=0x82 IOSurface→DCP dedup (gated /tmp/macws_t82dedup or MACWS_T82_DEDUP) ──
// RE+runtime-confirmed 2026-06-21: of 378 sel=0xa type=0x82 (IOSurface-backed)
// ResCreates during WS startup, 364 re-wrap the SAME IOSurface (id 0x17); only 4
// distinct surfaces total. Each type=0x82 create registers the surface with the
// DCP (display footprint) in IOGPUDevice::create_resource_iosurface →
// newResourceWithIOSurface, and the DCP RTKit firmware heap fills → kernel panic
// "DCP PANIC - CXXnew:2208" → device reboot. (Distinct from the host-side capture
// IOSurface leak the cappool fixes; see [[dcp-oom-is-dominant-blocker-after-leak-fix]].)
//
// Fix: dedup by IOSurfaceID. Keep ONE kernel resource alive per distinct surface
// (bounded to T82_MAX; the kernel frees them when WS exits and closes the UC), return
// its cached outStruct for every repeat wrap (NO kernel call → NO new DCP
// registration), and SWALLOW frees whose scalar in[0] is an owned resource-id.
// Safe-by-construction against double-free: owned resource-ids are NEVER kernel-freed,
// so the kernel can't recycle the id and a stale free can't hit a different resource.
// Correlation (RE of ios/IOGPU): create (sel 0x9) returns the resource-id at
// OUT[+0x1c]; _IOGPUResourceCreate stores it at resource->0x30; _ioGPUResourceFinalize
// frees via IOConnectCallMethod(sel=0xa, inCnt=1, in[0]=resource->0x30). So
// owned-id == OUT[+0x1c] == free's in[0]. A fixed display/composite surface re-wrapped
// every frame SHOULD reuse one resource, so returning the same one is also correct.
#define MACWS_T82_MAX 32
static struct { uint32_t iosID; uint32_t resID; size_t outLen; unsigned char out[0x80]; } g_t82[MACWS_T82_MAX];
static int g_t82n;
static int g_t82_on = -1;
static int macws_t82_dedup_on(void) {
    // 2026-06-22 — DEFAULT-ON (was opt-in via /tmp/macws_t82dedup). The dedup IS
    // the principled fix for the DCP RTKit firmware-heap OOM panic that reboots
    // the device: it keeps exactly ONE live kernel resource per distinct
    // IOSurfaceID and serves the cached outStruct for every repeat wrap, so a
    // fixed display/composite surface re-wrapped every frame reuses one DCP
    // registration instead of issuing a fresh one (RE+runtime: ~189-378 type=0x82
    // creates collapse to ~4 distinct surfaces). NOT a blunt nop/cap — it restores
    // the correct one-resource-per-surface invariant and is safe-by-construction
    // against double-free (owned ids are never kernel-freed). See
    // [[dcp-oom-is-dominant-blocker-after-leak-fix]]. Opt-out:
    // /tmp/macws_no_t82dedup or MACWS_NO_T82_DEDUP (A/B back to per-call creates).
    if (g_t82_on < 0)
        g_t82_on = (getenv("MACWS_NO_T82_DEDUP") || access("/tmp/macws_no_t82dedup", F_OK) == 0) ? 0 : 1;
    return g_t82_on;
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
#include <execinfo.h>
static int caller_is_libmachook(void *ret) {
    Dl_info di;
    if (!dladdr(ret, &di) || !di.dli_fname) return 0;
    const char *base = strrchr(di.dli_fname, '/');
    base = base ? base + 1 : di.dli_fname;
    return strncmp(base, "libmachook", 10) == 0;
}

// ─── IOMFB per-selector RATE counter (gated /tmp/macws_iomfb_rate_diag) ──────
// PHASE-0 diagnostic for the DCP RTKit firmware-heap OOM panic
// (`DCP PANIC - CXXnew:2208 - iomfb_ap_callee_0(21)`). The per-frame call that
// allocates a DCP object is NOT IOGPU (type=0x82 ResCreate is deduped to ~4)
// and NOT the already-NOP'd panel-present (kern_SwapEnd sel=5). It must be
// another non-IOGPU (IOMobileFramebuffer) UC selector in the swap lifecycle.
// Count every non-IOGPU IOConnect call by (translated) selector and, once per
// wall-second, append the per-second + cumulative counts to a fsync'd file that
// SURVIVES the panic-reboot — so ONE short no-VNC-client run reveals the
// per-frame swap selector by its rate, with no kernel disassembly. Read-only;
// cannot worsen the panic.
static int macws_iomfb_rate_on(void) {
    static int on = -1;
    if (on < 0) on = (access("/tmp/macws_iomfb_rate_diag", F_OK) == 0) ? 1 : 0;
    return on;
}
static _Atomic unsigned long long g_iomfb_sel[512];
static _Atomic unsigned long long g_iomfb_sel_tot[512];
static void macws_iomfb_rate_tick(uint32_t selector) {
    if (!macws_iomfb_rate_on()) return;
    uint32_t s = (selector < 512) ? selector : 511;
    atomic_fetch_add(&g_iomfb_sel[s], 1ULL);
    atomic_fetch_add(&g_iomfb_sel_tot[s], 1ULL);
    static _Atomic long last_sec = 0;
    long now = (long)time(NULL);
    long prev = atomic_load(&last_sec);
    if (now != prev && atomic_compare_exchange_strong(&last_sec, &prev, now)) {
        char buf[3072]; int n = 0;
        n += snprintf(buf + n, sizeof(buf) - n, "#### IOMFB-RATE t=%ld:", now);
        for (uint32_t i = 0; i < 512 && n < (int)sizeof(buf) - 96; i++) {
            unsigned long long c = atomic_exchange(&g_iomfb_sel[i], 0ULL);
            if (c) n += snprintf(buf + n, sizeof(buf) - n, " sel%u=%llu/s(tot%llu)",
                                 i, c, atomic_load(&g_iomfb_sel_tot[i]));
        }
        n += snprintf(buf + n, sizeof(buf) - n, "\n");
        if (n > 0) {
            (void)write(STDERR_FILENO, buf, (size_t)n);
            int fd = open("/tmp/macws_iomfb_rate", O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) { (void)write(fd, buf, (size_t)n); fsync(fd); close(fd); }
        }
    }
}

// One-shot signature dump for a non-IOGPU (IOMFB) selector — captures which
// IOConnect variant it uses + the in/out counts so the sel74 (per-frame swap)
// intercept can fake the right return shape instead of blind-NOPing. Gated by
// the same /tmp/macws_iomfb_rate_diag file. `phase` = "pre"/"post" the call.
static void macws_iomfb_sig(const char *hook, const char *phase, uint32_t sel,
        uint32_t inCnt, size_t inSC, const uint64_t *out, uint32_t *outCnt,
        const void *outStruct, size_t *outSC, IOReturn r) {
    if (!macws_iomfb_rate_on()) return;
    if (sel >= 512) return;
    static _Atomic unsigned char dumped[512];
    unsigned char z = 0;
    if (!atomic_compare_exchange_strong(&dumped[sel], &z, 1)) return;
    char buf[320]; int n = snprintf(buf, sizeof buf,
        "#### IOMFB-SIG %s/%s sel=%u inCnt=%u inSC=%zu outCnt=%u outSC=%zu r=%#x out0=%#llx out1=%#llx\n",
        hook, phase, sel, inCnt, inSC,
        outCnt ? *outCnt : 0xffffffffu, outSC ? *outSC : (size_t)-1, r,
        (out && outCnt && *outCnt >= 1) ? (unsigned long long)out[0] : 0ULL,
        (out && outCnt && *outCnt >= 2) ? (unsigned long long)out[1] : 0ULL);
    (void)outStruct;
    if (n > 0) {
        (void)write(STDERR_FILENO, buf, (size_t)n);
        int fd = open("/tmp/macws_iomfb_rate", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { (void)write(fd, buf, (size_t)n); fsync(fd); close(fd); }
    }
}

// Captured AGX device user-client connection (the one ResCreate sel=0x9 uses).
// Exposed so the buffer CPU-map experiment (clientMemoryForType /
// IOConnectMapMemory64) in Metal_hooks.x can map a resource's full CPU memory.
_Atomic io_connect_t g_agx_conn = 0;
__attribute__((visibility("default"))) io_connect_t macws_get_agx_conn(void) {
    return atomic_load(&g_agx_conn);
}

// SUBMIT-DUMP: set by the libmachook BLIT-TEST around its [cb commit] so the IOConnectCallMethod
// selector-30 (AGX command-buffer submit) dump can tag MY submit vs WS's. See agx commit RE:
// the kernel (AGXCommandQueue::processSegmentKernelCommand) rejects with 0x103 when an embedded
// command record isn't {type=0x30, size=0x1a8, next=size+0x30}. Dump+compare WS (valid) vs mine.
_Atomic int g_dump_my_submit = 0;

static void macws_scan_records(const char *tag, const char *where, const uint32_t *p, size_t n_u32) {
    int found = 0;
    for (size_t k = 0; k + 1 < n_u32 && found < 16; k++) {
        if (p[k] == 0x30) {                       // candidate kernel-command record type
            uint32_t size = p[k + 1];
            fprintf(stderr, "#### SUBMIT-DUMP[%s] %s rec@+%#zx type=0x30 size=%#x next=%#x %s\n",
                tag, where, k * 4, size, p[k + 1] + 0x30,
                size == 0x1a8 ? "(VALID 0x1a8)" : "(!!MISMATCH want 0x1a8)");
            found++;
        }
    }
    if (!found) fprintf(stderr, "#### SUBMIT-DUMP[%s] %s NO type=0x30 record in %zu u32\n", tag, where, n_u32);
}

static void macws_dump_submit(const char *tag, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt) {
    fprintf(stderr, "#### SUBMIT-DUMP[%s] inCnt=%u inStructCnt=%zu inStruct=%p scalars:", tag, inCnt, inStructCnt, inStruct);
    for (uint32_t i = 0; i < inCnt && i < 8; i++) fprintf(stderr, " %#llx", (unsigned long long)in[i]);
    fprintf(stderr, "\n");
    if (!inStruct || inStructCnt < 8) return;
    const uint8_t *b = (const uint8_t *)inStruct;
    fprintf(stderr, "#### SUBMIT-DUMP[%s] inStruct head:", tag);
    for (size_t i = 0; i < inStructCnt && i < 64; i++) fprintf(stderr, "%02x", b[i]);
    fprintf(stderr, "\n");
    macws_scan_records(tag, "inStruct", (const uint32_t *)inStruct, inStructCnt / 4);
    // follow plausible pointers in inStruct to the command-stream segment(s)
    const uint64_t *u = (const uint64_t *)inStruct;
    for (size_t i = 0; i < inStructCnt / 8 && i < 24; i++) {
        uint64_t pp = u[i];
        if (pp < 0x100000000ULL || pp > 0x7fffffffffffULL) continue;
        vm_address_t a = (vm_address_t)pp; vm_size_t sz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t mo = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &mo) != KERN_SUCCESS) continue;
        if (a > (vm_address_t)pp || (vm_address_t)(a + sz) < (vm_address_t)pp + 256 || !(bi.protection & VM_PROT_READ)) continue;
        const uint8_t *sb = (const uint8_t *)pp; const uint32_t *seg = (const uint32_t *)pp;
        fprintf(stderr, "#### SUBMIT-DUMP[%s] args[%zu]=%#llx seg head:", tag, i, (unsigned long long)pp);
        for (size_t j = 0; j < 96; j++) fprintf(stderr, "%02x", sb[j]);
        fprintf(stderr, "\n");
        size_t segn = ((vm_address_t)(a + sz) - (vm_address_t)pp) / 4; if (segn > 512) segn = 512;
        char w[40]; snprintf(w, sizeof w, "seg[%zu]", i);
        macws_scan_records(tag, w, seg, segn);
        for (size_t j = 0; j < segn; j++)
            if (seg[j] == 0x10000 || seg[j] == 0x10001) { fprintf(stderr, "#### SUBMIT-DUMP[%s] %s MAGIC %#x @+%#zx\n", tag, w, seg[j], j * 4); break; }
        // 0x115xxxxxxx HUNT: scan EVERY u64 in the segment for the GPU-fault-VA range. This is the
        // userland-built data structure containing the 0x115xxxxxxx that the GPU later reads.
        // Scan a bigger window (segn is u32 count; treat as u64 pairs).
        const uint64_t *u64seg = (const uint64_t *)pp;
        size_t u64n = ((vm_address_t)(a + sz) - (vm_address_t)pp) / 8; if (u64n > 16384) u64n = 16384;
        int va_hits = 0;
        for (size_t j = 0; j < u64n && va_hits < 8; j++) {
            uint64_t v = u64seg[j];
            if (v >= 0x1100000000ULL && v < 0x1200000000ULL) {
                fprintf(stderr, "#### SUBMIT-DUMP[%s] %s VA-HIT @+%#zx val=%#llx ctx:",
                    tag, w, j * 8, (unsigned long long)v);
                size_t cs_start = j * 8 > 32 ? j * 8 - 32 : 0;
                size_t cs_end   = j * 8 + 64; if (cs_end > u64n * 8) cs_end = u64n * 8;
                for (size_t k = cs_start; k < cs_end; k++)
                    fprintf(stderr, "%02x", sb[k]);
                fprintf(stderr, "\n");
                va_hits++;
            }
        }
    }
}

// USC-REDIRECT (gated /tmp/macws_uscredir): the GPU shader/USC unit faults reading shader code at
// the USC region 0x11xx, which the iOS kernel does NOT map for the chroot. But the SAME shader heap
// IS mapped at its GEM VA (0x15xx = USC + 0x4<<32, same in-region offset). So before submit, rewrite
// every 0x11xx GPU-VA in the command stream -> +0x4<<32 (region 0x11 -> the mapped 0x15 GEM region).
// This sidesteps the missing kernel mapping by pointing the GPU at the mapping that exists.
// Tests the open question: does the GPU shader-fetch honor the descriptor VA (works) or a fixed
// hardware USC base (fault moves/persists)?  Follows inStruct pointers via vm_region_64 (bounded/safe).
static int macws_usc_redirect(const void *inStruct, size_t inStructCnt) {
    // Broad sweep: the shader's USC VA (0x11xx) lives in a deeper GPU-shared buffer, not the
    // level-1 command-stream segments. Walk ALL writable VM regions in the GPU-shared address
    // range and rewrite every 0x11xx GPU-VA -> +0x4<<32 (the mapped 0x15xx GEM alias).
    (void)inStruct; (void)inStructCnt;
    int total = 0; size_t scanned = 0;
    vm_address_t addr = 0x100000000ULL;          // start above the low CPU heap
    while (addr < 0x800000000ULL && scanned < 0x8000000ULL) {   // GPU-shared range; cap 128MB scanned
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t mo = MACH_PORT_NULL;
        vm_address_t a = addr;
        if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &mo) != KERN_SUCCESS) break;
        if (a >= 0x800000000ULL) break;
        if ((bi.protection & (VM_PROT_READ|VM_PROT_WRITE)) == (VM_PROT_READ|VM_PROT_WRITE) && sz <= 0x2000000) {
            uint8_t *base = (uint8_t *)a;
            for (size_t j = 0; j + 8 <= sz; j += 4) {
                uint64_t v; memcpy(&v, base + j, 8); uint64_t nv = 0;
                // TARGETED: only the ENCODED USC descriptor (x9 = (VA>>2)|bit41, region 0x11 in bits
                // 30-37 -> the encoded word lands in [0x20440000000, 0x20480000000)). +0x1<<32 makes
                // it region 0x15 (the mapped GEM alias). Raw-0x11xx broad sweep removed (it corrupted
                // unrelated data + muddied the test).
                if (v >= 0x20440000000ULL && v < 0x20480000000ULL) nv = v + 0x100000000ULL;
                if (nv) {
                    memcpy(base + j, &nv, 8);
                    if (total < 16) fprintf(stderr, "#### USC-REDIR @%#llx %#llx -> %#llx\n",
                        (unsigned long long)(a + j), (unsigned long long)v, (unsigned long long)nv);
                    total++;
                }
            }
            scanned += sz;
        }
        addr = a + sz;
    }
    if (total) fprintf(stderr, "#### USC-REDIR rewrote %d x 0x11xx -> 0x15xx (broad sweep, %zuMB)\n", total, scanned>>20);
    else       fprintf(stderr, "#### USC-REDIR found 0 encoded descriptors in %zuMB (range [0x20440000000,0x20480000000) absent at submit)\n", scanned>>20);
    return total;
}

IOReturn IOConnectCallMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int skip = caller_is_libmachook(__builtin_return_address(0));
    if (!skip) selector = IOConnectTranslateSelector(client, selector);
    if (IOConnectIsIOGPU(client) && selector == 0x9) atomic_store(&g_agx_conn, client);
    // USC-CHUNK-BIG (gated /tmp/macws_usc_chunk_big): inverse experiment. The chroot's shader
    // faults at 0x115xxxxxxx = ~3.8 GB into region 0x11. Region 0x11 is a 128 MB USC chunk
    // (class 0x43001000101). Shader expects contiguous multi-GB region. Bump chunk size to 4 GB
    // so the 3.8 GB offset fits within one mapped chunk.
    //
    // Reverse direction from the iosblit-based SIZE-FILL: that filled small sizes (iosblit's
    // run-time), but the chroot needs LARGER per-class allocation than the kernel's default.
    if (selector == 0x9 && inStruct && inStructCnt >= 0x48 && IOConnectIsIOGPU(client) && !skip &&
        access("/tmp/macws_usc_chunk_big", F_OK) == 0) {
        uint64_t v10 = *(uint64_t *)((uintptr_t)inStruct + 0x10);
        uint64_t *sz_ptr = (uint64_t *)((uintptr_t)inStruct + 0x40);
        if (v10 == 0x43001000101ULL && *sz_ptr == 0) {
            *sz_ptr = 0x100000000ULL;  // 4 GB (covers the observed 3.8 GB shader offset)
            static int bn = 0;
            if (bn++ < 8) fprintf(stderr, "#### USC-CHUNK-BIG +0x40: 0 -> 0x100000000 (4 GB) for v10=0x43001000101\n");
        }
    }
    // USC-SIZE-FILL (gated /tmp/macws_usc_size_fill): the chroot's macOS AGXMetal13_3 passes
    // +0x40 = 0 (the size field) for ALL sel=9 ResCreate calls. The iOS kernel responds with
    // large per-class default sizes (128MB / 384MB / 896MB). But macOS-AGXMetal13_3's encoded USC
    // descriptors are calibrated for SMALL sizes -- when the kernel gives it a huge region, the
    // shader-baked offsets land within the region but outside the buffer macOS-AGXMetal "expects",
    // causing GPU page-fault at 0x115xxxxxxx.
    //
    // FIX (from iosblit_iokit_probe captured data, 2026-06-25): explicitly fill +0x40 with the
    // sizes iOS-native iosblit uses for each class tag:
    //   v10 = 0x43001000101  -> +0x40 = 0x8000   (32 KB)   [USC chunk]
    //   v10 = 0x47001000101  -> +0x40 = 0x20000  (128 KB)  [page]
    //   v10 = 0x843001000101 -> +0x40 = 0x8000   (32 KB)   [parent]
    //   v10 = 0xc3001000101  -> +0x40 = 0x20000  (128 KB)  [op]
    //   v10 = 0x800001000101 -> +0x40 = 0x10000  (64 KB)
    //   v10 = 0x1000101      -> +0x40 = 0x10000  (64 KB)
    if (selector == 0x9 && inStruct && inStructCnt >= 0x48 && IOConnectIsIOGPU(client) && !skip &&
        access("/tmp/macws_usc_size_fill", F_OK) == 0) {
        uint64_t v10 = *(uint64_t *)((uintptr_t)inStruct + 0x10);
        uint64_t *sz_ptr = (uint64_t *)((uintptr_t)inStruct + 0x40);
        uint64_t old = *sz_ptr;
        uint64_t newsz = 0;
        if (old == 0) {
            switch (v10) {
                case 0x43001000101ULL:  newsz = 0x8000;  break;
                case 0x47001000101ULL:  newsz = 0x20000; break;
                case 0x843001000101ULL: newsz = 0x8000;  break;
                case 0xc3001000101ULL:  newsz = 0x20000; break;
                case 0x800001000101ULL: newsz = 0x10000; break;
                case 0x1000101ULL:      newsz = 0x10000; break;
            }
        }
        if (newsz) {
            *sz_ptr = newsz;
            static int fn = 0;
            if (fn++ < 32) fprintf(stderr, "#### USC-SIZE-FILL v10=%#llx +0x40: %#llx -> %#llx\n",
                (unsigned long long)v10, (unsigned long long)old, (unsigned long long)newsz);
        }
    }
    // USC-CHUNK-SIZE-BUMP (gated /tmp/macws_usc_chunk_bump): the chroot's macOS AGXMetal13_3 asks
    // for USC chunks of 128 MB (in+0x40 = 0x8000000) with in+0x10 = 0x43001000101. Bump each chunk
    // to 384 MB (0x18000000) — kernel HAS shown it accepts that size (regions 0x16/0x18/0x1e in
    // baseline got 384 MB). If kernel honors the bigger ask, shader fault VA (around 0x115xxxxxxx,
    // ~3.8 GB into region 0x11) might land within a larger first-chunk allocation.
    if (selector == 0x9 && inStruct && inStructCnt >= 0x48 && IOConnectIsIOGPU(client) && !skip &&
        access("/tmp/macws_usc_chunk_bump", F_OK) == 0) {
        uint64_t v10 = *(uint64_t *)((uintptr_t)inStruct + 0x10);
        uint64_t *sz_ptr = (uint64_t *)((uintptr_t)inStruct + 0x40);
        // Diagnostic: ALWAYS log to confirm path runs
        static int diag = 0;
        if (diag++ < 200) fprintf(stderr, "#### USC-CHUNK-DIAG sel=%u inSC=%zu skip=%d v10=%#llx sz=%#llx\n",
            selector, inStructCnt, skip, (unsigned long long)v10, (unsigned long long)*sz_ptr);
        // USC chunk pattern: in+0x10 == 0x43001000101 AND in+0x40 == 128 MB
        if (v10 == 0x43001000101ULL && *sz_ptr == 0x8000000ULL) {
            *sz_ptr = 0x18000000ULL;  // 128 MB -> 384 MB
            static int bn = 0;
            if (bn++ < 8) fprintf(stderr, "#### USC-CHUNK-BUMP +0x40: 0x8000000 -> 0x18000000 (128 MB -> 384 MB)\n");
        }
    }
    // USC-CLASS-TAG (gated /tmp/macws_usc_classtag): the chroot's sel=9 input at +0x14 carries a
    // class-tag in the low 12 bits (e.g. 0x430 = USC chunk class, 0x470 = device-private page,
    // 0x8430 = bit15 + USC chunk). iOS-native iosblit sends `0x8000` (pure bit15, no class tag) at
    // the same offset and gets a much larger region back. THEORY: zeroing the low 12 bits at +0x14
    // makes the chroot's request match iOS-native's "open large region" path. This is a clean
    // userland-only test of why iOS works and chroot doesn't.
    if (selector == 0x9 && inStruct && inStructCnt >= 0x18 && IOConnectIsIOGPU(client) && !skip &&
        access("/tmp/macws_usc_classtag", F_OK) == 0) {
        uint32_t *p14 = (uint32_t *)((uintptr_t)inStruct + 0x14);
        uint32_t v14 = *p14;
        uint32_t low = v14 & 0xfff;
        // Only mutate the USC-class tags. Don't touch 0x000 (already clean) or unknown classes.
        if (low == 0x430 || low == 0x470 || low == 0x420 || low == 0x460) {
            uint32_t nv = v14 & ~0xfffu;                   // strip class tag, keep bit15 etc.
            static int n = 0;
            if (n++ < 12) fprintf(stderr, "#### USC-CLASS-TAG +0x14: %#x -> %#x (strip class %#x)\n",
                v14, nv, low);
            *p14 = nv;
        }
    }
    // USC-REDIRECT at submit (sel 0x1a/0x1e = AGX command-buffer submit), BEFORE the orig call so the GPU sees it.
    if ((orig == 0x1a || orig == 0x1e || selector == 0x1a) && IOConnectIsIOGPU(client) && !skip &&
        access("/tmp/macws_uscredir", F_OK) == 0) {
        macws_usc_redirect(inStruct, inStructCnt);
    }
    // SUBMIT-DUMP (gated /tmp/macws_submit_dump): one-shot dump of the AGX command-buffer submit
    // (selector 30 = 0x1e) command-stream records, tagged MY (g_dump_my_submit) vs WS. Read-only.
    if ((orig == 0x1e || selector == 0x1e) && IOConnectIsIOGPU(client) && access("/tmp/macws_submit_dump", F_OK) == 0) {
        int mine = atomic_load(&g_dump_my_submit);
        static int dumped_ws = 0, dumped_mine = 0;
        if ((mine && !dumped_mine) || (!mine && !dumped_ws)) {
            if (mine) dumped_mine = 1; else dumped_ws = 1;
            macws_dump_submit(mine ? "MYBLIT" : "WS", in, inCnt, inStruct, inStructCnt);
        }
    }
    if (!skip && !IOConnectIsIOGPU(client)) {
        macws_iomfb_rate_tick(selector);
        macws_iomfb_sig("M", "pre", selector, inCnt, inStructCnt, in, &inCnt, inStruct, outStructCnt, 0);
        // NOTE: a prior attempt skipped sel74 (SwapBegin) here to avoid the
        // per-frame DCP alloc — but skipping the ALLOC breaks WS startup (WS
        // needs the swap; WS died at startup → respawn storm → panic anyway,
        // runtime-confirmed 2026-06-22). The DCP swap object must be RECYCLED,
        // not un-allocated — that happens by letting the panel-present run (see
        // the /tmp/macws_present_recycle gate in loadImageCallback), so the
        // sel74 intercept was removed.
    }
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
    // sel=0x6 (iOS IOGPUDeviceCreateWithAPIProperty) and sel=0x7 (iOS
    // IOGPUCommandQueueCreateWithQoS) both take inSC=1032 (0x408). iOS
    // userland zeros the entire buffer first, then writes QoS at +0x400 and
    // priority at +0x404. macOS userland instead writes a process path
    // string starting at offset 0 ("/System/Library/PrivateFrameworks/
    // SkyLight.framework/Versions/A/Resources/WindowServer\0…"). The iOS
    // kernel then reads whatever is at +0x400/+0x404 as QoS/priority — and
    // for the macOS payload, those are zero (since the path is well under
    // 1024 bytes), which iOS could in principle tolerate. But the kernel
    // also seems to scan the leading bytes (probably the "device flags" /
    // "api_property" header at +0x0..+0x10) and rejects non-zero garbage
    // there. Fix: build a fresh zeroed 1032-byte buffer (the iOS-native
    // shape with QoS/priority defaulting to 0), pass that instead. The
    // existing 256-byte shadowbuf is too small; allocate on the heap.
    unsigned char *qbuf = NULL;
    if (IOConnectIsIOGPU(client) && (selector == 0x6 || selector == 0x7) &&
        inStruct && inStructCnt == 0x408) {
        qbuf = (unsigned char *)calloc(1, inStructCnt);
        // Default QoS/priority = 0 is fine; iOS Metal uses 0 when no
        // explicit QoS is requested. Leave +0x400/+0x404 as zero.
        inStruct = qbuf;
        static int q_patched[2] = {0, 0};
        int sl = (selector == 0x6) ? 0 : 1;
        if (!q_patched[sl]) {
            q_patched[sl] = 1;
            fprintf(stderr,
                "#### AGXIOC QueueArgs-fix sel=0x%x: replaced path-string args with zeroed 0x408 buffer\n",
                selector);
        }
    }
    unsigned char shadowbuf[256];
    uint8_t  agxType = 0; uint32_t agxClientID = 0; uint64_t agxHeapSz = 0;
    int agxIsRes = (IOConnectIsIOGPU(client) && selector == 0x9 && inStruct && inStructCnt >= 0x60 && inStructCnt <= sizeof(shadowbuf));
    if(agxIsRes) {
        const unsigned char *src = (const unsigned char *)inStruct;
        agxType = src[0];
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
        agxClientID = t80_has_parent ? *(const uint32_t *)(src + 0x48) : 0;
        int patched = 0;
        memcpy(shadowbuf, inStruct, inStructCnt);
        if(bc == 0 && agxType == 0) {
            // Heap byte-count fixup (only valid for type=0 heap creation;
            // type=0x80 client-buffer path uses args+0x40 as the end VA,
            // not a size).
            uint32_t sz32 = *(const uint32_t *)(src + 0x58);
            uint64_t nb = sz32 ? sz32 : 0x1000;
            // FOOTPRINT-CAP EXPERIMENT (gated MACWS_CAP_HEAP, cap MB via
            // MACWS_HEAP_CAP_MB, default 256). RE-confirmed 2026-06-21:
            // these type=0 AGX heaps are charged to WS phys_footprint as
            // wired GPU memory (RSS stays ~80MB but footprint hits the
            // 5120MB EXC_RESOURCE watermark → WS killed). Idle alloc is
            // ~3.9GB (13x128MiB + 3x384MiB + 1x939MiB CodeHeap); a client
            // app's render adds ~5GB (11x384MiB) → >5120MB. This caps the
            // byte-count we pass to the iOS kernel. EXPERIMENT: must verify
            // rendering still produces content — if AGX overruns the capped
            // heap it will fault. Back off / raise the cap if so.
            // Sentinel /tmp/macws_cap_heap (content = cap MB, default 256) so it
            // toggles with a FAST libmachook-only build (no WS-plist edit).
            // Env MACWS_HEAP_CAP_MB overrides the cap value.
            static long s_cap = -2;
            if (s_cap == -2) {
                s_cap = -1;
                if (getenv("MACWS_CAP_HEAP") || access("/tmp/macws_cap_heap", F_OK) == 0) {
                    s_cap = 256;
                    const char *mb = getenv("MACWS_HEAP_CAP_MB");
                    if (mb) s_cap = atol(mb);
                    else {
                        FILE *cf = fopen("/tmp/macws_cap_heap", "r");
                        if (cf) { long v = 0; if (fscanf(cf, "%ld", &v) == 1 && v > 0) s_cap = v; fclose(cf); }
                    }
                    fprintf(stderr, "#### FOOTPRINT-CAP enabled, cap=%ld MB\n", s_cap);
                }
            }
            if (s_cap > 0) {
                uint64_t capb = (uint64_t)s_cap << 20;
                if (nb > capb) {
                    static int caplog = 0;
                    if (caplog++ < 12)
                        fprintf(stderr, "#### FOOTPRINT-CAP heap %#llx (%lluMB) → %#llx (%ldMB)\n",
                                (unsigned long long)nb, (unsigned long long)(nb>>20),
                                (unsigned long long)capb, s_cap);
                    nb = capb;
                }
            }
            *(uint64_t *)(shadowbuf + 0x40) = nb;
            agxHeapSz = nb;
            patched = 1;
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
        if (agxType == 0x82) {
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
            if (va38 > 0x40000000ULL && agxType != 0x82) {
                static int log_once_38 = 0;
                if (log_once_38++ < 4) {
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
                if (log_once_14++ < 4) {
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
                fprintf(stderr,
                    "#### AGXIOC sel=0x9 type=0 VA-shape detected: "
                    "args+0x40=%#llx (>1GB) → using args+0x48=%#llx as size, +0x58 %#llx → 0\n",
                    (unsigned long long)bc, (unsigned long long)len_field,
                    (unsigned long long)va58);
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
                *(uint32_t *)(shadowbuf + 0x48) = (uint32_t)g_agxIdMap[i].iosGID;            // parent-id: client -> iOS GID
                if(f30 == 0 && va38) *(uint64_t *)(shadowbuf + 0x30) = va38 + g_agxIdMap[i].size;  // +0x30 = end-VA so size(=+0x30-+0x38) = parent size
                patched = 1; mapped = 1;
                fprintf(stderr, "#### AGXIOC subres parent %#x -> GID %#llx, +0x30=%#llx (sz %#llx)\n", agxClientID, (unsigned long long)g_agxIdMap[i].iosGID, (unsigned long long)(va38 + g_agxIdMap[i].size), (unsigned long long)g_agxIdMap[i].size);
                break;
            }
            if(!mapped && f30 == 0 && va38) { *(uint64_t *)(shadowbuf + 0x30) = va38; patched = 1; }  // fallback: nonzero
        } else if(agxType == 0x80) {
            // ONE-SHOT raw-bytes dump: capture the EXACT inStruct bytes
            // macOS WS sends for sel=0x9 type=0x80 BEFORE any libmachook
            // patching. Compare to iOS-native probe (agx_iogpu_probe.c)
            // args that also fail kr=0xe00002be. If bytes match → truly
            // structural; if they diverge, the differing field IS the
            // rejection trigger.
            static int t80_dumped = 0;
            if (!t80_dumped) {
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
        // The chroot WS fails not because of the type byte, but because the
        // macOS userland fills two extra fields that iOS init leaves zero:
        //
        //   field      iOS userland sets                  macOS sets
        //   args+0x40  0    (zero-initialised stack)      0x80888300 (flag mask)
        //   args+0x58  0    (zero-initialised stack)      0x180888300 (pinned VA)
        //
        // Both non-zero values trigger the iOS kernel's macOS-only
        // "standalone with pinned GPU VA" code path which doesn't exist,
        // returning kIOReturnNoMemory.
        //
        // Fix: for iosurface texture creates (detected by args+0x14 flag
        // mask 0x430 — the iOS-set marker from IOGPUMetalResource init),
        // zero args+0x40 and args+0x58. The iOS kernel then takes the same
        // path as native iOS iosurface texture creation. The IOSurface
        // identity is still bound by the follow-up sel=0x29→0x25
        // (IOGPUResourceCreateIOSurface) call.
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
        // Fix: read the IOSurfaceID we stashed in TLS from Metal_hooks.x's
        // swizzled newTextureWithDescriptor:iosurface:plane: (we're called
        // synchronously from inside that swizzle's %orig), and inject it
        // into args[+0x30]. Also keep the +0x40 / +0x58 zeroing because
        // non-zero values there take the pinned-VA fast path which iOS
        // doesn't recognise.
        // macOS chroot stores the IOSurfaceID at args+0x38 (where iOS puts
        // the plane index); iOS userland stores IOSurfaceID at args+0x30
        // (which macOS leaves zero). Swap them: write +0x38's value into
        // +0x30, and put the actual plane (always 0 in our path) at +0x38.
        // Also zero +0x40 / +0x58 — the iOS kernel rejects non-zero values
        // there (pinned-VA path that doesn't exist on iOS).
        if(agxType == 0x82) {
            uint32_t f14 = *(const uint32_t *)(src + 0x14);
            uint64_t old_40 = *(const uint64_t *)(src + 0x40);
            uint64_t old_58 = *(const uint64_t *)(src + 0x58);
            uint32_t old_30 = *(const uint32_t *)(src + 0x30);
            uint32_t old_38 = *(const uint32_t *)(src + 0x38);
            *(uint64_t *)(shadowbuf + 0x40) = 0;
            *(uint64_t *)(shadowbuf + 0x58) = 0;
            // If +0x30 is empty and +0x38 looks like an IOSurfaceID, swap.
            if (old_30 == 0 && old_38 != 0) {
                *(uint32_t *)(shadowbuf + 0x30) = old_38;
                *(uint32_t *)(shadowbuf + 0x38) = 0;
            }
            patched = 1;
            fprintf(stderr,
                "#### AGXIOC type=0x82 patch: f14=%#x +0x30 %#x→%#x +0x38 %#x→%#x "
                "+0x40 %#llx→0 +0x58 %#llx→0\n",
                f14,
                old_30, *(const uint32_t *)(shadowbuf + 0x30),
                old_38, *(const uint32_t *)(shadowbuf + 0x38),
                (unsigned long long)old_40, (unsigned long long)old_58);
        }
        // 2026-06-22 — CPU-MAP-SIZE FIX (gated /tmp/macws_cpusize). RE+runtime
        // confirmed: for type=0 BUFFER resources the chroot's macOS-AGX sets the
        // CPU-mappable byte-count at args+0x40 to 0x1000 (4KB → one 16KB page),
        // while the buffer's real size sits at args+0x48 (e.g. 0x40000=256KB).
        // The iOS kernel maps exactly page_round(args+0x40), so -[buffer contents]
        // comes back 16KB and any full-length CPU write overruns → SIGSEGV/SIGBUS
        // (the backdrop-blur crash). The compiler codeheap PROVES the kernel
        // honors a large args+0x40 (it sets +0x40=full → OUT[+0x48]=full CPU map),
        // and a native iOS process gets full maps the same way. Fix: set
        // args+0x40 = args+0x48 so the kernel maps the WHOLE buffer CPU-side →
        // GPU-coherent full-length contents → real blur, no kcall / no proxy.
        if (agxType == 0 &&
            (access("/tmp/macws_cpusize", F_OK) == 0 || getenv("MACWS_CPUSIZE"))) {
            const unsigned char *isrc = (const unsigned char *)inStruct;
            uint64_t cpu_sz = *(const uint64_t *)(isrc + 0x40);
            uint64_t tot_sz = *(const uint64_t *)(isrc + 0x48);
            uint64_t v58    = *(const uint64_t *)(isrc + 0x58);
            // Only plain buffer resources: +0x58==0 (a pinned/codeheap-class
            // resource carries a GPU VA at +0x58 and must NOT have +0x40 rewritten
            // — runtime-confirmed it carries a special meaning there).
            if (v58 == 0 && tot_sz >= 0x8000 && tot_sz > cpu_sz && cpu_sz <= 0x4000) {
                *(uint64_t *)(shadowbuf + 0x40) = tot_sz;
                patched = 1;
                static int cs_log = 0;
                if (cs_log++ < 8)
                    fprintf(stderr,
                        "#### CPUSIZE: type=0 +0x40 %#llx -> %#llx (= +0x48 total; full CPU map)\n",
                        (unsigned long long)cpu_sz, (unsigned long long)tot_sz);
            }
        }
        if(patched) inStruct = shadowbuf;
        // POST-patch dump for sel=0x9 type=0x80: capture EXACT bytes that
        // hit the kernel — to compare against iOS-native probe args that
        // also fail kr=0xe00002be with all-zero-but-required-fields.
        if (agxType == 0x80) {
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
    // ─── type=0x82 IOSurface→DCP dedup: create cache-hit / free swallow ───
    int    t82_hit = 0;        // create satisfied from cache → skip kernel (no DCP reg)
    int    t82_free_sw = 0;    // free of an owned resource → swallow (never kernel-free)
    uint32_t t82_iosID = 0;    // create's IOSurfaceID (for post-call cache on miss)
    if (macws_t82_dedup_on() && IOConnectIsIOGPU(client) && !skip) {
        if (agxIsRes && agxType == 0x82) {
            t82_iosID = *(const uint32_t *)((const unsigned char *)inStruct + 0x30);
            if (t82_iosID) {
                for (int i = 0; i < g_t82n; i++) if (g_t82[i].iosID == t82_iosID) {
                    if (outStruct && outStructCnt && *outStructCnt >= g_t82[i].outLen) {
                        memcpy(outStruct, g_t82[i].out, g_t82[i].outLen);
                        *outStructCnt = g_t82[i].outLen;
                        t82_hit = 1;
                        static int hl = 0; if (hl++ < 16)
                            fprintf(stderr, "#### T82 DEDUP HIT ios=%#x resID=%#x (n=%d)\n",
                                    t82_iosID, g_t82[i].resID, g_t82n);
                    }
                    break;
                }
            }
        } else if (selector == 0xa && inCnt == 1 && in && inStructCnt == 0) {
            uint32_t resID = (uint32_t)in[0];
            for (int i = 0; i < g_t82n; i++) if (g_t82[i].resID == resID) {
                t82_free_sw = 1;
                static int fl = 0; if (fl++ < 16)
                    fprintf(stderr, "#### T82 DEDUP SWALLOW free resID=%#x\n", resID);
                break;
            }
        }
    }
    IOReturn r = (t82_hit || t82_free_sw)
        ? (IOReturn)0 /* kIOReturnSuccess */
        : IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    // REGION-DIFF (gated /tmp/macws_regiondiff): for every successful sel=9 ResCreate, log the input
    // args bytes alongside which region the kernel returned (out+0x18 high nibble). One line per
    // unique (input-hash, region) so we can byte-diff a 0x11 (USC) request vs a 0x15 (GEM) request
    // and find the exact input byte that selects region.
    if (selector == 0x9 && r == 0 && IOConnectIsIOGPU(client) && outStruct && outStructCnt &&
        *outStructCnt >= 0x20 && inStruct && inStructCnt >= 0x60 && access("/tmp/macws_regiondiff", F_OK) == 0) {
        uint64_t out18 = *(const uint64_t *)((const uint8_t *)outStruct + 0x18);
        unsigned region = (unsigned)(out18 >> 32) & 0xff;
        // Dedupe by (region, first 16 bytes of input) — only log distinct shapes per region.
        static struct { unsigned region; uint64_t sig[2]; } seen[32];
        static int nseen = 0;
        uint64_t s0, s1; memcpy(&s0, inStruct, 8); memcpy(&s1, (const uint8_t*)inStruct+8, 8);
        int dup = 0;
        for (int i = 0; i < nseen; i++)
            if (seen[i].region == region && seen[i].sig[0] == s0 && seen[i].sig[1] == s1) { dup = 1; break; }
        if (!dup && nseen < 32) {
            seen[nseen].region = region; seen[nseen].sig[0] = s0; seen[nseen].sig[1] = s1; nseen++;
            fprintf(stderr, "#### REGION-DIFF region=0x%02x out+0x18=%#llx inSC=%zu in:",
                region, (unsigned long long)out18, inStructCnt);
            const uint8_t *ib = (const uint8_t *)inStruct;
            for (size_t k = 0; k < inStructCnt && k < 0x68; k++) fprintf(stderr, "%02x", ib[k]);
            fprintf(stderr, "\n");
        }
    }
    // USC-TRACE (gated /tmp/macws_usctrace): the chroot DOES get region 0x11 (USC) assigned -> some
    // AGXMetal function deliberately requested a USC/parameter heap. Capture the call chain at the
    // moment a region-0x11 resource is created (out+0x18 = 0x11<<32) to find THAT function (and any
    // follow-up USC-map call it expects). Also dumps the input (the type/flag that requests USC).
    if (selector == 0x9 && r == 0 && IOConnectIsIOGPU(client) && outStruct && outStructCnt &&
        *outStructCnt >= 0x20 && access("/tmp/macws_usctrace", F_OK) == 0) {
        uint64_t out18 = *(const uint64_t *)((const uint8_t *)outStruct + 0x18);
        if (out18 >= 0x1100000000ULL && out18 < 0x1200000000ULL) {   // region 0x11 = USC
            static int utn = 0;
            if (utn++ < 4) {
                fprintf(stderr, "#### USC-TRACE region-0x11 ResCreate out+0x18=%#llx inSC=%zu in[0..0x30]:",
                    (unsigned long long)out18, inStructCnt);
                const uint8_t *ib = (const uint8_t *)inStruct;
                for (size_t k = 0; inStruct && k < inStructCnt && k < 0x30; k++) fprintf(stderr, "%02x", ib[k]);
                fprintf(stderr, "\n");
                void *frames[24]; int nf = backtrace(frames, 24);
                for (int i = 1; i < nf; i++) {
                    Dl_info di;
                    if (dladdr(frames[i], &di) && di.dli_fname) {
                        const char *fn = strrchr(di.dli_fname, '/'); fn = fn ? fn + 1 : di.dli_fname;
                        fprintf(stderr, "####   [%d] %s %s+%#llx\n", i, fn,
                            di.dli_sname ? di.dli_sname : "?",
                            (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)));
                    } else fprintf(stderr, "####   [%d] %p\n", i, frames[i]);
                }
            }
        }
    }
    // VASCAN (gated /tmp/macws_vascan): hunt the 0x11xx fixed-region base (the BIF0 fault VA range,
    // 0x1168000000) in the IOConnect traffic. If a config input/output carries a 0x11xx value -> patch
    // that field to a mapped 0x15xx base. If 0x11xx is absent everywhere -> it is AGXMetal-internal
    // (the command stream picks it; needs the relocate-and-patch-references path instead).
    if (IOConnectIsIOGPU(client) && access("/tmp/macws_vascan", F_OK) == 0) {
        const uint64_t VLO=0x1100000000ULL, VHI=0x1200000000ULL;
        if (inStruct && inStructCnt>=8) { const uint64_t *u=(const uint64_t*)inStruct;
            for (size_t i=0;i<inStructCnt/8;i++) if (u[i]>=VLO && u[i]<VHI)
                fprintf(stderr,"#### VASCAN sel=%u->%u IN+%#zx=%#llx (inSC=%zu)\n",orig,selector,i*8,(unsigned long long)u[i],inStructCnt); }
        if (r==0 && outStruct && outStructCnt && *outStructCnt>=8) { const uint64_t *u=(const uint64_t*)outStruct;
            for (size_t i=0;i<*outStructCnt/8;i++) if (u[i]>=VLO && u[i]<VHI)
                fprintf(stderr,"#### VASCAN sel=%u->%u OUT+%#zx=%#llx\n",orig,selector,i*8,(unsigned long long)u[i]); }
        if (orig==0x8 && inStruct && inStructCnt>=0x400) { static dispatch_once_t qd; dispatch_once(&qd, ^{
            const uint64_t *u=(const uint64_t*)inStruct;
            fprintf(stderr,"#### VASCAN queue-create(sel0x8) inSC=%zu nonzero-u64s:\n",inStructCnt);
            for (size_t i=0;i<inStructCnt/8;i++) if (u[i]) fprintf(stderr,"####   +%#zx = %#llx\n",i*8,(unsigned long long)u[i]); }); }
    }
    // type=0x82 create cache-MISS that succeeded: record the kernel resource so future
    // wraps of this IOSurface reuse it (and its single DCP registration).
    if (macws_t82_dedup_on() && IOConnectIsIOGPU(client) && !skip && !t82_hit &&
        agxIsRes && agxType == 0x82 && t82_iosID && r == 0 &&
        outStruct && outStructCnt && *outStructCnt >= 0x20) {
        size_t ol = *outStructCnt; if (ol > sizeof(g_t82[0].out)) ol = sizeof(g_t82[0].out);
        uint32_t resID = *(const uint32_t *)((const unsigned char *)outStruct + 0x1c);
        int idx = -1;
        for (int i = 0; i < g_t82n; i++) if (g_t82[i].iosID == t82_iosID) { idx = i; break; }
        if (idx < 0 && g_t82n < MACWS_T82_MAX) idx = g_t82n++;
        if (idx >= 0) {
            g_t82[idx].iosID = t82_iosID; g_t82[idx].resID = resID; g_t82[idx].outLen = ol;
            memcpy(g_t82[idx].out, outStruct, ol);
            static int nl = 0; if (nl++ < 16)
                fprintf(stderr, "#### T82 DEDUP CACHE ios=%#x resID=%#x outLen=%zu (n=%d)\n",
                        t82_iosID, resID, ol, g_t82n);
        }
    }
    // CM-IOC: every non-IOGPU IOConnect made WHILE the QC IOMFBDisplay ctor runs
    // (g_in_createmode>0, set by macws_hook_disp_init). The mode/timing query that
    // gates the mode-set is in here — logs sel+kr+out so we see exactly which one
    // and whether it fails at kr or returns success+empty.
    if (atomic_load(&g_in_createmode) > 0 && !IOConnectIsIOGPU(client)) {
        size_t osc = outStructCnt ? *outStructCnt : 0;
        fprintf(stderr, "#### CM-IOC c=%u sel=%u inCnt=%u inSC=%zu outSC=%zu kr=%#x",
                client, selector, inCnt, inStructCnt, osc, r);
        const uint8_t *o = (const uint8_t *)outStruct;
        if (o && osc) { fprintf(stderr, " outS="); for (size_t i=0;i<osc&&i<48;i++) fprintf(stderr,"%02x",o[i]); }
        fprintf(stderr, "\n");
    }
    // IOMFB-FAIL (gated /tmp/macws_iomfb_trace): log EVERY non-IOGPU IOConnect that
    // returns an ERROR (kr != 0), with NO dedup — the IOMFBDisplay-ctor mode/timing
    // query (-> IOKit MIG) errors in the chroot and is the gate that skips the
    // mode-set. Capturing every failure (sel + kr + in/out) pinpoints it without
    // the slide/signature risk of hooking IOMFB framework functions directly.
    if (!skip && r != 0 && !IOConnectIsIOGPU(client) &&
        access("/tmp/macws_iomfb_trace", F_OK) == 0) {
        static int failN = 0;
        if (failN++ < 64) {
            size_t osc = outStructCnt ? *outStructCnt : 0;
            fprintf(stderr, "#### IOMFB-FAIL c=%u sel=%u inCnt=%u inSC=%zu outSC=%zu kr=%#x",
                    client, selector, inCnt, inStructCnt, osc, r);
            const uint8_t *ip = (const uint8_t *)inStruct;
            if (ip && inStructCnt) { fprintf(stderr, " inS="); for (size_t i=0;i<inStructCnt&&i<32;i++) fprintf(stderr,"%02x",ip[i]); }
            fprintf(stderr, "\n");
        }
    }
    // IOMFB-TRACE (gated /tmp/macws_iomfb_trace): capture NON-IOGPU IOConnect
    // calls (IOMFB display-mode/timing/power, IOSurface, HID) + their returns,
    // deduped per (client,selector), to find which selector should populate the
    // display scanout config / mode but returns error/garbage in the chroot.
    // 2026-06-21 — diagnostic for the current_page_surface page-leak root
    // (display never reaches a valid powered-on mode). Read-only logging.
    if (!skip && !IOConnectIsIOGPU(client) &&
        access("/tmp/macws_iomfb_trace", F_OK) == 0) {
        static struct { io_connect_t c; uint32_t s; } seen[96];
        static int seenN = 0;
        int dup = 0;
        for (int i = 0; i < seenN; i++) if (seen[i].c == client && seen[i].s == selector) { dup = 1; break; }
        if (!dup && seenN < 96) {
            seen[seenN].c = client; seen[seenN].s = selector; seenN++;
            size_t osc = outStructCnt ? *outStructCnt : 0;
            size_t oc  = outCnt ? *outCnt : 0;
            fprintf(stderr, "#### IOMFB-TRACE c=%u sel=%u inCnt=%u inSC=%zu outCnt=%zu outSC=%zu kr=%#x",
                    client, selector, inCnt, inStructCnt, oc, osc, r);
            const uint8_t *o = (const uint8_t *)outStruct;
            if (o && osc) { fprintf(stderr, " outS="); for (size_t i = 0; i < osc && i < 40; i++) fprintf(stderr, "%02x", o[i]); }
            if (out && oc) { fprintf(stderr, " out64="); for (size_t i = 0; i < oc && i < 6; i++) fprintf(stderr, "%llx,", (unsigned long long)out[i]); }
            fprintf(stderr, "\n");
        }
    }
    // Log the kr for sel=0x9 type=0x80 once so we can pair it with the
    // POST-PATCH dump above.
    if (agxIsRes && agxType == 0x80) {
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
        uint64_t gid = *(const uint64_t *)(o + 0x28);   // iOS GID: monotonic IOGPUObject counter, echoed at OUT+0x28
        int slot = -1;
        for(int i = 0; i < g_agxIdMapCount; i++) if(g_agxIdMap[i].clientID == agxClientID) { slot = i; break; }  // overwrite (clientID reused)
        if(slot < 0 && g_agxIdMapCount < 128) slot = g_agxIdMapCount++;
        if(slot >= 0) { g_agxIdMap[slot].clientID = agxClientID; g_agxIdMap[slot].iosGID = gid; g_agxIdMap[slot].size = agxHeapSz; }
        fprintf(stderr, "#### AGXIOC heap clientID %#x -> GID %#llx size %#llx\n", agxClientID, (unsigned long long)gid, (unsigned long long)agxHeapSz);
    }
    if(IOConnectIsIOGPU(client)) {
        // OOM leak diagnostic (2026-06-20): periodic per-caller sel=0xa vs
        // sel=0xb delta — narrows which AGX upstream creates without
        // matching releases.  We sample 1 in 50 of each (sel=0xa, sel=0xb)
        // to bound log volume; cumulative counts always printed.
        if (orig == 0xa || orig == 0xb) {
            static _Atomic unsigned long s_a_count = 0;
            static _Atomic unsigned long s_b_count = 0;
            unsigned long me = (orig == 0xa)
                ? atomic_fetch_add(&s_a_count, 1) + 1
                : atomic_fetch_add(&s_b_count, 1) + 1;
            if (me % 500 == 1) {
                Dl_info di;
                void *ra = __builtin_return_address(0);
                const char *sym = "?";
                if (dladdr(ra, &di) && di.dli_sname) sym = di.dli_sname;
                fprintf(stderr,
                    "#### AGX_LEAK sel=0x%x #%lu (cumA=%lu cumB=%lu delta=%ld) caller=%s\n",
                    orig, me,
                    atomic_load(&s_a_count), atomic_load(&s_b_count),
                    (long)(atomic_load(&s_a_count) - atomic_load(&s_b_count)),
                    sym);
            }
        }
        fprintf(stderr, "#### AGXIOC Method sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inCnt, inStructCnt, outStructCnt?*outStructCnt:0, r);
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
        if (orig == 0xa && selector == 0x9 &&
            inStruct && inStructCnt >= 0x60) {
            const unsigned char *src = (const unsigned char *)inStruct;
            uint8_t type = src[0];
            uint32_t clientID = *(const uint32_t *)(src + 0x48);
            uint64_t f30 = *(const uint64_t *)(src + 0x30);
            uint64_t va38 = *(const uint64_t *)(src + 0x38);
            uint64_t bc40 = *(const uint64_t *)(src + 0x40);
            uint64_t va58 = *(const uint64_t *)(src + 0x58);
            // 2026-06-19 diagnostic for outStruct[+0x10]: macOS userland
            // copies outStruct[+0x10] → wrapper[+0x48] (the
            // "client-shared-memory pointer" returned by
            // _IOGPUResourceGetClientShared). If outStruct[+0x10] is
            // NULL, IOGPUMetalResource init bails to error path.
            uint64_t out10 = 0, out48 = 0;
            if (r == 0 && outStruct && outStructCnt && *outStructCnt >= 0x18) {
                const unsigned char *o = (const unsigned char *)outStruct;
                out10 = *(const uint64_t *)(o + 0x10);
                if (*outStructCnt >= 0x50)
                    out48 = *(const uint64_t *)(o + 0x48);
            }
            fprintf(stderr,
                "####   ResCreate %s type=%#x clientID=%#x "
                "+0x30=%#llx +0x38=%#llx +0x40=%#llx +0x58=%#llx "
                "OUT[+0x10]=%#llx OUT[+0x48]=%#llx\n",
                r ? "FAIL" : "OK",
                type, clientID,
                (unsigned long long)f30, (unsigned long long)va38,
                (unsigned long long)bc40,
                (unsigned long long)va58,
                (unsigned long long)out10, (unsigned long long)out48);
            // Hex dump first 0x70 bytes
            fprintf(stderr, "####   inStruct[0..%zu]:", inStructCnt);
            for (size_t i = 0; i < inStructCnt && i < 0x70; i++) {
                if (i % 16 == 0) fprintf(stderr, "\n####     %02zx:", i);
                fprintf(stderr, " %02x", src[i]);
            }
            fprintf(stderr, "\n");
            // OUT-DIFF: full output struct dump (iOS 80-byte layout) to field-diff vs the
            // macOS 88-byte layout (local mingpu) — the iOS kernel returns a different/shorter
            // output, so macOS Metal reads the resource's mapping/size from wrong offsets.
            { static int odn = 0;
              if (r == 0 && outStruct && outStructCnt && *outStructCnt && odn++ < 3) {
                const unsigned char *o = (const unsigned char *)outStruct;
                fprintf(stderr, "####   OUTstruct[cnt=%zu]:", *outStructCnt);
                for (size_t i = 0; i < *outStructCnt && i < 0x60; i++) {
                    if (i % 16 == 0) fprintf(stderr, "\n####     %02zx:", i);
                    fprintf(stderr, " %02x", o[i]);
                }
                fprintf(stderr, "\n");
              } }
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
    // OUT-XLATE (gated /tmp/macws_outxlate): translate the iOS-kernel sel=0x9 ResCreate output ABI
    // to the macOS layout macOS Metal expects. mingpu local-vs-chroot diff (commit cddd259): macOS
    // sel=0x9 output = 88B, iOS = 80B with fields shifted 8 bytes (sizes at local +0x28/+0x50 <->
    // iOS +0x20/+0x48; zeros +0x40/+0x48 <-> +0x38/+0x40; count +0x20 <-> +0x18). macOS Metal reads
    // the resource size/descriptor at the macOS offsets (+0x50 doesn't exist in the 80B output) ->
    // garbage -> bogus GPU mapping -> BIF0 fault (mingpu 0x102/0xb). Fix: shift the 80 iOS bytes up
    // by 8 into the macOS layout + cnt=88. Done LAST (after all internal iOS-layout reads) so only
    // the macOS-Metal caller sees the translated struct. SELF-VERIFYING: mingpu render-clear
    // status 5->4 confirms. The macOS-Metal buffer capacity is >=88 (it expects 88, per the local
    // IOConnectCallMethod trace), so writing 88 is in-bounds.
    if (selector == 0x9 && r == 0 && outStruct && outStructCnt && *outStructCnt == 80 &&
        inStruct && inStructCnt >= 1 && ((const unsigned char *)inStruct)[0] == 0x82 &&
        access("/tmp/macws_outxlate", F_OK) == 0) {   // type=0x82 IOSurface textures ONLY. Extending
                                                      // to all sel=0x9 (buffers/heaps/cmdbuf storage)
                                                      // BREAKS init (mg_all.out): those have a DIFFERENT
                                                      // output layout that macOS reads fine at 80B (no
                                                      // +0x50 extra). Only textures need the 88B layout.
        // RE + EMPIRICALLY-CONFIRMED translation (2026-06-24):
        //  CONSUMER = macOS 13.4 _IOGPUResourceCreate @ IOGPU 0x19d1560a0 allocates
        //    outStructCnt = device[+0x34](=8)+0x50 = 88; reads out[+0x08]->GPU VA, out[+0x28]->size,
        //    memcpy out[+0x50..+0x58]->obj+0x70.
        //  PRODUCER = iOS 16.3 IOGPUDevice::new_resource @ 0xfffffe0009f03b4c writes 80 bytes
        //    (output size = IOGPU->0x224(=0)+0x50).
        //  The iOS 16.3 and macOS 13.4 layouts DIFFER: macOS has an extra 8-byte field at +0x18,
        //  shifting +0x18.. up by 8. EMPIRICALLY CONFIRMED: insert-8B-@+0x18 beats the page fault
        //  (0xb->0x9); "extend-only" (no shift, just zero the +0x50 extra) brings the page fault
        //  BACK -> the shift is REQUIRED, not the size alone. (Front-insert @+0x00 crashed Metal:
        //  it moved the VAs at +0x08/+0x10, which are NOT shifted.)
        //  0x9 ROOT CAUSE (RE-confirmed via the cmdbuf resource-table lookup @ 0xeea3a4):
        //  getResource(id) rejects id==0 -> NULL -> kIOReturnInvalidResource. The +0x18 memset
        //  ZEROED out[+0x1c] = the resource ID (iOS writes a namespace index there; the consumer
        //  reads out[+0x1c]->obj+0x30 and macOS Metal uses it in the cmdbuf). So preserve it:
        //  save the iOS resID before the shift, restore it at +0x1c after. Keeps the shift's
        //  VA/size/extra placement (no page fault) AND a valid resource ID (no 0x9).
        unsigned char *o = (unsigned char *)outStruct;
        uint32_t resID = *(const uint32_t *)(o + 0x1c);   // iOS resource-table namespace index
        memmove(o + 0x20, o + 0x18, 0x38);   // iOS[0x18..0x50) -> macOS[0x20..0x58)
        memset(o + 0x18, 0, 8);              // inserted macOS-only field @ +0x18
        *(uint32_t *)(o + 0x1c) = resID;     // restore resID @ +0x1c (getResource rejects id==0)
        *outStructCnt = 88;
        static int xn = 0; if (xn++ < 4)
            fprintf(stderr, "#### OUT-XLATE: iOS 80B -> macOS 88B (insert@+0x18 + resID@+0x1c=%u preserved)\n", resID);
    }
    if (qbuf) free(qbuf);
    return r;
}
IOReturn IOConnectCallScalarMethod_new(io_connect_t client, uint32_t selector, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    if (!caller_is_libmachook(__builtin_return_address(0)))
        selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallScalarMethod(client, selector, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client) && orig != selector) fprintf(stderr, "#### AGXIOC Scalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallStructMethod_new(io_connect_t client, uint32_t selector, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    int sm_skip = caller_is_libmachook(__builtin_return_address(0));
    if (!sm_skip)
        selector = IOConnectTranslateSelector(client, selector);
    if (!sm_skip && !IOConnectIsIOGPU(client)) {
        macws_iomfb_rate_tick(selector);
        macws_iomfb_sig("S", "pre", selector, 0, inStructCnt, NULL, NULL, inStruct, outStructCnt, 0);
        // PRESENT-STRUCT dump (gated /tmp/macws_present_dump): with the
        // present-recycle gate on, the per-frame IOMFB panel-present
        // (kern_SwapEnd's IOConnectCallStructMethod) reaches this hook. Dump its
        // inStruct (one-shot per selector) so we can find the scanout-target /
        // display field to redirect to a virtual surface (recycle w/o lighting
        // the panel). fsync'd to /tmp/macws_present_struct (survives any reboot).
        if (inStruct && inStructCnt && selector < 256 &&
            access("/tmp/macws_present_dump", F_OK) == 0) {
            static _Atomic unsigned char pd_done[256];
            unsigned char z0 = 0;
            if (atomic_compare_exchange_strong(&pd_done[selector], &z0, 1)) {
                const unsigned char *s = (const unsigned char *)inStruct;
                char b[1400]; int n = 0;
                n += snprintf(b+n, sizeof(b)-n, "#### PRESENT-STRUCT sel=%u inSC=%zu:\n", selector, inStructCnt);
                size_t lim = inStructCnt < 256 ? inStructCnt : 256;
                for (size_t i = 0; i < lim && n < (int)sizeof(b)-8; i++) {
                    if (i % 16 == 0) n += snprintf(b+n, sizeof(b)-n, "\n  %03zx:", i);
                    n += snprintf(b+n, sizeof(b)-n, " %02x", s[i]);
                }
                n += snprintf(b+n, sizeof(b)-n, "\n");
                if (n > 0) { (void)write(STDERR_FILENO, b, (size_t)n);
                    int fd = open("/tmp/macws_present_struct", O_WRONLY|O_CREAT|O_APPEND, 0644);
                    if (fd >= 0) { (void)write(fd, b, (size_t)n); fsync(fd); close(fd); } }
            }
        }
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
    if(IOConnectIsIOGPU(client) && orig != selector) fprintf(stderr, "#### AGXIOC Struct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, const void *inStruct, size_t inStructCnt, uint64_t *out, uint32_t *outCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncMethod(client, selector, wake_port, ref, refCnt, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncMethod sel=0x%x->0x%x inCnt=%u inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inCnt, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
IOReturn IOConnectCallAsyncScalarMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncScalarMethod(client, selector, wake_port, ref, refCnt, in, inCnt, out, outCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncScalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallAsyncStructMethod_new(io_connect_t client, uint32_t selector, mach_port_t wake_port, uint64_t *ref, uint32_t refCnt, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    selector = IOConnectTranslateSelector(client, selector);
    IOReturn r = IOConnectCallAsyncStructMethod(client, selector, wake_port, ref, refCnt, inStruct, inStructCnt, outStruct, outStructCnt);
    if(IOConnectIsIOGPU(client)) fprintf(stderr, "#### AGXIOC AsyncStruct sel=0x%x->0x%x inSC=%zu outSC=%zu -> 0x%x\n", orig, selector, inStructCnt, outStructCnt?*outStructCnt:0, r);
    return r;
}
DYLD_INTERPOSE(IOConnectCallMethod_new, IOConnectCallMethod);
DYLD_INTERPOSE(IOConnectCallScalarMethod_new, IOConnectCallScalarMethod);
DYLD_INTERPOSE(IOConnectCallStructMethod_new, IOConnectCallStructMethod);
DYLD_INTERPOSE(IOConnectCallAsyncMethod_new, IOConnectCallAsyncMethod);
DYLD_INTERPOSE(IOConnectCallAsyncScalarMethod_new, IOConnectCallAsyncScalarMethod);
DYLD_INTERPOSE(IOConnectCallAsyncStructMethod_new, IOConnectCallAsyncStructMethod);

// 2026-06-22 — MAPDIAG (gated /tmp/macws_map_diag): the deep blur RE. AGX
// buffers in chroot get a full GPU allocation but a CPU -contents mapping
// capped at 16KB (BUFDIAG vm_extent=0x4000). Log every IOConnectMapMemory[64]
// the AGX driver issues for an IOGPU connection: memoryType (= resource id),
// the kernel-returned CPU address, and crucially the SIZE the kernel maps. If
// the kernel returns a truncated *ofSize the cap is kernel-side; if AGX passes
// a small size / never maps the rest, it's userland-side. fsync'd to survive
// the WS crash.
// IOConnectMapMemory64 is exported by IOKit but absent from this SDK's headers;
// declare it (resolved at runtime via -undefined dynamic_lookup).
extern kern_return_t IOConnectMapMemory64(io_connect_t connect, uint32_t memoryType,
                                          task_port_t intoTask, mach_vm_address_t *atAddress,
                                          mach_vm_size_t *ofSize, IOOptionBits options);

static void macws_mapdiag_log(io_connect_t c, uint32_t mt,
                              uint64_t addr, uint64_t size, IOOptionBits opt, kern_return_t kr) {
    if (access("/tmp/macws_map_diag", F_OK) != 0) return;
    static _Atomic int mn = 0;
    int n = atomic_fetch_add(&mn, 1);
    if (n >= 128) return;
    char b[224];
    int k = snprintf(b, sizeof b,
        "MAPDIAG #%d Map64 isIOGPU=%d memType=0x%x addr=%#llx size=%#llx opt=%#x kr=%#x\n",
        n, IOConnectIsIOGPU(c), mt, (unsigned long long)addr,
        (unsigned long long)size, opt, kr);
    int fd = open("/tmp/macws_mapdiag.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { if (k > 0) write(fd, b, (size_t)k); fsync(fd); close(fd); }
}

kern_return_t IOConnectMapMemory64_new(io_connect_t c, uint32_t mt, task_port_t t,
                                       mach_vm_address_t *addr, mach_vm_size_t *size, IOOptionBits opt) {
    kern_return_t kr = IOConnectMapMemory64(c, mt, t, addr, size, opt);
    macws_mapdiag_log(c, mt, addr ? *addr : 0, size ? *size : 0, opt, kr);
    // VASCAN step 2: is the 0x11xx fixed region mapped via IOConnectMapMemory64? Log all mappings
    // + flag any landing in the BIF0 fault range. If 0x11xx shows here -> interceptable (redirect mt
    // or the returned addr). If not -> the 0x11xx VA is established purely in AGXMetal userland.
    if (kr == 0 && addr && access("/tmp/macws_vascan", F_OK) == 0)
        fprintf(stderr, "#### VASCAN MAPMEM conn=%u mt=%u addr=%#llx size=%#llx opt=%#x%s\n",
            c, mt, (unsigned long long)*addr, (unsigned long long)(size ? *size : 0), opt,
            (*addr >= 0x1100000000ULL && *addr < 0x1200000000ULL) ? "  <<< 0x11xx!" : "");
    return kr;
}
DYLD_INTERPOSE(IOConnectMapMemory64_new, IOConnectMapMemory64);

// XPC-borrow the AGX io_connect_t from macwsallocd. The helper is iOS-Apple-
// signed-equivalent so the kernel runs the full privileged UC-init (sets
// device->0x108, this->0x100, etc.) — which the chroot's macOS-userland
// IOServiceOpen can't trigger directly (RE-traced to per-UC size limit at
// IOGPUDevice::new_resource +0xff; see memory cross-image-objc-class-
// register-and-ioconnect-heap-blocker). Once borrowed, IOConnectCallMethod
// calls from the chroot run against the kernel-side UC state set by the
// helper — heap/queue/resource create all become available.
static mach_port_t macws_borrow_agx_conn_xpc(void) {
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

    // clear flag 4 (FIXME: idk what is this)
    type &= ~4;

    // AGXG13GFamilyDevice opens its user client with type=0x100001 on macOS.
    // The iOS AGX kext doesn't recognise that high-bit flag and gives us back
    // a degraded user client whose sel=0x8/0x9 (heap/sub-resource create) all
    // return kIOReturnExclusiveAccess (0xe00002c2) — fuzzing every byte of
    // args+0x08..+0x60 confirmed the user client itself rejects the calls,
    // not the args. Masking the high-bit flag down to type=1 (the iOS-native
    // "full IOGPUDevice user client" type) gets us a real client. Gated on
    // MACWS_AGX_NATIVE so the sim path is unaffected. Allow MACWS_AGX_FORCE_TYPE
    // to override the masked type for fuzzing.
    uint32_t orig_type = type;
    if (getenv("MACWS_AGX_NATIVE") && service == agxService) {
        if (type & 0xFFFF0000) {
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
        fprintf(stderr, "#### debugbydcmmc IOServiceOpen agx connect=%d type=%u (orig=%u)\n",
            *connect, type, orig_type);
    }
    return result;
}
DYLD_INTERPOSE(IOServiceOpen_new, IOServiceOpen);
#endif