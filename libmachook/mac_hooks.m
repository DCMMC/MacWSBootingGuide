@import CoreServices;
@import CydiaSubstrate;
@import Darwin;
@import Foundation;
@import MachO;
#import <IOKit/IOKitLib.h>
#import <xpc/xpc.h>
#import <sys/sysctl.h>
#import "interpose.h"
#import "utils.h"

// IOSurface
typedef id IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(NSDictionary* properties);
extern IOSurfaceRef IOSurfaceLookupFromMachPort(mach_port_t port);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);

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
    return orig_skylight_prepare_for_use(self, ctx, arg);
}

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
    return orig_skylight_start_composite_ds(self, target0, target1, load_action, store_action);
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
    return orig_skylight_wsccd_with_tex(texture, ctx, protectionOptions, colorspace, region);
}

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

void loadImageCallback(const struct mach_header* header, intptr_t vmaddr_slide) {
    Dl_info info;
    dladdr(header, &info);
    if(!strncmp(info.dli_fname, SkyLightPath, strlen(SkyLightPath))) {
        // allow coexist with backboardd in WS::Displays::CAWSManager::CAWSManager() + 560
        // if backboardd is running, WindowServer switches to offscreen rendering
        uint32_t *check = (uint32_t *)(OFF_SkyLight_CAWSManager_register_abort + (uintptr_t)header);
        ModifyExecutableRegion(check, sizeof(uint32_t), ^{
#warning TODO: has hardcoded instruction
            // NSLog(@"#### debugbydcmmc OFF_SkyLight_CAWSManager_register_abort ModifyExecutableRegion addr %lu val %lu, expect: %lu",
            //     (unsigned long) check, (unsigned long) *check, (unsigned long) 0xb4000588);
            // Patch only if the expected instruction is present; skip (do not
            // abort) on a non-matching SkyLight version/arch.
            if (*check == 0xb4000588) { // cbz    x8, do_abort
                *check = 0xd503201f; // nop
            }
        });
        
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
                uint32_t *swapSubmit = (uint32_t *)(OFF_IOMobileFramebuffer_kern_SwapEnd_submit + (uintptr_t)header);
                ModifyExecutableRegion(swapSubmit, sizeof(uint32_t), ^{
                    if (*swapSubmit == 0x94001f64) { // bl IOConnectCallStructMethod (panel present)
                        *swapSubmit = 0xd2800000;    // mov x0, #0  (skip present, return KERN_SUCCESS)
                        fprintf(stderr,
                            "#### COEXIST: kern_SwapEnd panel-present NOPed (backboardd detected)\n");
                    }
                });
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
        if(!isWindowServer && getenv("MACWS_KEEP_FORCE_ACCEL")) {
            // LAZY: forces CABackingStorePrepareUpdates_ to take the
            // accelerated (IOSurface) branch unconditionally. Was hiding
            // the actual reason apps fell to the CPU bitmap path. Opt-IN
            // with MACWS_KEEP_FORCE_ACCEL=1; default off so the real
            // CPU-vs-GPU decision logic runs and we see why it picked CPU.
            uint32_t *forceAccel = (uint32_t *)(OFF_QuartzCore_CABackingStore_force_accel + (uintptr_t)header);
            ModifyExecutableRegion(forceAccel, sizeof(uint32_t), ^{
                if (*forceAccel == 0x34000155) { // cbz w21, #0x28 (+852)
                    *forceAccel = 0x14000007;    // b +840 (accelerated path)
                }
            });
        }
    } else if(getenv("MACWS_AGX_NATIVE") && !strncmp(info.dli_fname, AGXMetalPath, strlen(AGXMetalPath))) {
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
                fprintf(stderr,
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
            fprintf(stderr,
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
                fprintf(stderr,
                    "#### AGX_CLASSREF_DIAG initImpl method m=%p imp=%p "
                    "expected stub=%p real=%p WHICH=%s\n",
                    m, imp, (void*)agxtex_stub, (void*)agxg13_real, which);
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
                        fprintf(stderr,
                            "#### MACWS_AGX_SKIP_BIND_UPDATE: NOPed BL @%p "
                            "(static %#llx + slide=%#zx)\n",
                            bl_at, (unsigned long long)bl_static,
                            (size_t)slide);
                    } else if (insn == NOP_INSN) {
                        /* already patched */
                    } else {
                        fprintf(stderr,
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
                fprintf(stderr,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH msgSendSuper2=%p "
                    "autda@%p insn=%#x\n",
                    super2, autda_at, cur);
                if (cur == XPACD_X16) {
                    fprintf(stderr, "####   already patched, skip\n");
                } else if (cur != AUTDA_X16_X17) {
                    fprintf(stderr,
                        "####   unexpected insn (expected %#x for autda x16,x17) — skip\n",
                        AUTDA_X16_X17);
                } else {
                    ModifyExecutableRegion(autda_at, 4, ^{
                        *autda_at = XPACD_X16;
                    });
                    fprintf(stderr,
                        "####   PATCHED autda x16,x17 → xpacd x16 (%#x → %#x)\n",
                        AUTDA_X16_X17, XPACD_X16);
                }
            } else {
                fprintf(stderr,
                    "#### MACWS_AGX_OBJC_AUTDA_PATCH: dlsym(objc_msgSendSuper2)=NULL\n");
            }

            // Diagnostic (read-only) — useful when triaging future variants.
            Class agx_tex = objc_getClass("AGXTexture");
            Class iogpu_tex = objc_getClass("IOGPUMetalTexture");
            if (agx_tex && iogpu_tex) {
                uint64_t *super_field = (uint64_t *)((uintptr_t)agx_tex + 8);
                fprintf(stderr,
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
            fprintf(stderr,
                "#### MACWS_AGX_SEL_DIAG super-init SEL static=%#llx slid=%p "
                "readable=%d\n"
                "####   bytes=\"%s\"\n",
                (unsigned long long)sel_static, sel_runtime, readable, preview);

            // Also: what does sel_registerName resolve THIS cstring to?
            if (readable && preview[0]) {
                SEL s = sel_registerName(sel_runtime);
                fprintf(stderr,
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
                            // this pointer, so it MUST be malloc-derived.
                            void *scratch = calloc(1, 16384);
                            if (scratch) {
                                ((void **)r)[6] = scratch;
                                static int fl_log = 0;
                                if (fl_log++ < 4) {
                                    fprintf(stderr,
                                        "#### initFull freelist-scratch: buf=%p ivar+0x30 ← %p\n",
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
                                if (sz > 0x10000000ULL) sz = 0x10000000ULL;
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
                            // dealloc later free()s. CRITICAL: this MUST be
                            // a malloc'd pointer — using the IOSurface base
                            // here corrupts the libmalloc heap (dealloc → free
                            // → libmalloc detects non-malloc address →
                            // checksum_botch → abort). Use a separate
                            // calloc'd scratch (16 KB is enough for the
                            // sequential-int freelist init + later memcpy
                            // grow operations). The IOSurface stays attached
                            // via associated objects for downstream code that
                            // wants the contents pointer.
                            ((void **)pr)[6] = calloc(1, 16384);
                            fprintf(stderr,
                                "#### CODEHEAP-SHIM ivar+0x30 = scratch (%p, 16K) — Mempool freelist target\n",
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
    if (!getenv("MACWS_AGX_CRASH_DIAG")) return;
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

static void macws_install_abort_trace(void) {
    if (!getenv("MACWS_ABORT_TRACE")) return;
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

__attribute__((constructor)) void InitStuff() {
    EnableJIT();
    macws_install_crash_diag();
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
    if(name && !strcmp(name, CARENDER_ORIG)) name = CARENDER_NEW;
    return bootstrap_look_up(bp, name, sp);
}
kern_return_t bootstrap_check_in_new(mach_port_t bp, const char *name, mach_port_t *sp) {
    if(name && !strcmp(name, CARENDER_ORIG)) name = CARENDER_NEW;
    return bootstrap_check_in(bp, name, sp);
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
    fprintf(stderr, "#### IOSURF/CA_FB rewrote %dx%d pf=0x%x->BGRA8 result=%p\n",
        w, h, pf, (void *)result);
    return result;
}
DYLD_INTERPOSE(IOSurfaceCreate_safe, IOSurfaceCreate);

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
    IOReturn r = IOConnectCallMethod(client, selector, in, inCnt, inStruct, inStructCnt, out, outCnt, outStruct, outStructCnt);
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
    if(IOConnectIsIOGPU(client) && orig != selector) fprintf(stderr, "#### AGXIOC Scalar sel=0x%x->0x%x inCnt=%u -> 0x%x\n", orig, selector, inCnt, r);
    return r;
}
IOReturn IOConnectCallStructMethod_new(io_connect_t client, uint32_t selector, const void *inStruct, size_t inStructCnt, void *outStruct, size_t *outStructCnt) {
    uint32_t orig = selector;
    if (!caller_is_libmachook(__builtin_return_address(0)))
        selector = IOConnectTranslateSelector(client, selector);
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