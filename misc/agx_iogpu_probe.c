// agx_iogpu_probe.c — iOS-native diagnostic for IOGPU::+0x108 size-cap.
//
// Opens an AGXAccelerator user-client in iOS-native context (where things
// work), uses Dopamine KRW to walk:
//
//   io_connect_t (mach port name)
//     → UC kernel kobject              [task_get_ipc_port_kobject]
//     → IOGPUDevice* at UC+0x120       [kread64]
//     → IOGPU*       at IOGPUDevice+0x48
//     → cap fields   at IOGPU+0x108 / IOGPU+0x224
//
// Compile + sign + run on iOS (NOT chroot):
//   clang -arch arm64 -framework IOKit /tmp/agx_iogpu_probe.c -o /tmp/agx_iogpu_probe
//   sudo ldid -S /tmp/agx_iogpu_probe
//   sudo /var/jb/usr/bin/jbctl trustcache add $(ldid -arch arm64 -h /tmp/agx_iogpu_probe \
//        2>/dev/null | awk -F= '/CDHash/{print $2}')
//   sudo /tmp/agx_iogpu_probe
//
// Decision matrix once we have numbers:
//
//   +0x108 != 0 here  &  +0x108 != 0 in chroot WS via libmachook KRW path:
//     → '+0x108 is the limit' hypothesis is WRONG; reject point is elsewhere
//       (look at the +0x44 b.hi at f03b9c, or +0x224 path)
//
//   +0x108 != 0 here  &  +0x108 == 0 in chroot WS:
//     → IOGPU is NOT a singleton; per-UC instance is real
//       → RE the createDevice / IOGPU::start path more carefully to find what
//         conditions cause re-init or fork
//
//   +0x108 == 0 here too:
//     → IOGPU::start never ran or didn't propagate; check GARTCacheSize
//       property in IORegistry, check boot-args, check whether backboardd
//       was actually working with sel=0x9 (maybe IT uses something else)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

static uint64_t (*p_task_self)(void);
static uint64_t (*p_task_get_ipc_port_kobject)(uint64_t task, mach_port_name_t port);
static uint64_t (*p_kread64)(uint64_t addr);
static uint32_t (*p_kread32)(uint64_t addr);
static int      (*p_jbclient_process_checkin)(char **rootPath, char **bootUUID,
                                              char **sandboxExt, bool *fullyDebugged);
static int      (*p_jbclient_initialize_primitives)(void);
static int      (*p_is_kcall_available)(void);

static int load_libjb(void) {
    void *lib = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "dlopen libjailbreak: %s\n", dlerror());
        return -1;
    }
    p_task_self                  = dlsym(lib, "task_self");
    p_task_get_ipc_port_kobject  = dlsym(lib, "task_get_ipc_port_kobject");
    p_kread64                    = dlsym(lib, "kread64");
    p_kread32                    = dlsym(lib, "kread32");
    p_jbclient_process_checkin   = dlsym(lib, "jbclient_process_checkin");
    p_jbclient_initialize_primitives = dlsym(lib, "jbclient_initialize_primitives");
    p_is_kcall_available         = dlsym(lib, "is_kcall_available");
    if (!p_task_self || !p_task_get_ipc_port_kobject || !p_kread64 || !p_kread32) {
        fprintf(stderr, "dlsym critical missing: ts=%p tgkobj=%p k64=%p k32=%p\n",
                p_task_self, p_task_get_ipc_port_kobject, p_kread64, p_kread32);
        return -1;
    }
    if (p_jbclient_process_checkin) {
        char *root = NULL, *uuid = NULL, *sbox = NULL;
        bool dbg = false;
        int r = p_jbclient_process_checkin(&root, &uuid, &sbox, &dbg);
        fprintf(stderr, "jbclient_process_checkin = %d (root=%s)\n", r,
                root ? root : "(null)");
    }
    if (p_jbclient_initialize_primitives) {
        int r = p_jbclient_initialize_primitives();
        fprintf(stderr, "jbclient_initialize_primitives = %d\n", r);
    }
    if (p_is_kcall_available) {
        fprintf(stderr, "is_kcall_available = %d (informational)\n",
                p_is_kcall_available());
    }
    return 0;
}

static void probe_one(const char *match_class, uint32_t type) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching(match_class));
    if (!svc) {
        fprintf(stderr, "[%s] no service\n", match_class);
        return;
    }
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
    IOObjectRelease(svc);
    if (kr != 0) {
        fprintf(stderr, "[%s type=%u] IOServiceOpen kr=0x%x\n",
                match_class, type, kr);
        return;
    }
    fprintf(stderr, "\n=== [%s type=%u] io_connect_t=0x%x ===\n",
            match_class, type, conn);

    uint64_t task = p_task_self();
    uint64_t uc   = p_task_get_ipc_port_kobject(task, conn);
    fprintf(stderr, "  task            = %#llx\n", (unsigned long long)task);
    fprintf(stderr, "  UC kobj         = %#llx\n", (unsigned long long)uc);
    if (!uc) {
        fprintf(stderr, "  no kobject — closing\n");
        IOServiceClose(conn);
        return;
    }

    uint64_t vt_uc  = p_kread64(uc + 0x00);
    uint64_t device = p_kread64(uc + 0x120);
    uint8_t  uc_103 = (uint8_t)(p_kread32(uc + 0x100) >> 24);
    fprintf(stderr, "  UC vtable       = %#llx\n", (unsigned long long)vt_uc);
    fprintf(stderr, "  UC+0x120 device = %#llx\n", (unsigned long long)device);
    fprintf(stderr, "  UC+0x103 byte   = 0x%02x  (1=restricted method table)\n", uc_103);
    if (!device) { IOServiceClose(conn); return; }

    uint64_t vt_dev = p_kread64(device + 0x00);
    uint64_t iogpu  = p_kread64(device + 0x48);
    fprintf(stderr, "  Device vtable   = %#llx\n", (unsigned long long)vt_dev);
    fprintf(stderr, "  Device+0x48 IOGPU = %#llx\n", (unsigned long long)iogpu);
    if (!iogpu) { IOServiceClose(conn); return; }

    uint64_t vt_iogpu = p_kread64(iogpu + 0x00);
    uint64_t cap_108  = p_kread64(iogpu + 0x108);
    uint32_t cap_224  = p_kread32(iogpu + 0x224);
    fprintf(stderr, "  IOGPU vtable    = %#llx\n", (unsigned long long)vt_iogpu);
    fprintf(stderr, "  IOGPU+0x108     = %#llx  (the size cap field)\n",
            (unsigned long long)cap_108);
    fprintf(stderr, "  IOGPU+0x224     = %#x      (outCnt-related field)\n",
            cap_224);
    fprintf(stderr, "  derived         3*0x108/4 = %#llx\n",
            (unsigned long long)((cap_108 * 3) / 4));

    // === Trigger sel=0xa heap-create from iOS-native context ===
    // The iOS-native userland Metal builds args this way (from
    // ~/Downloads/agx-re/ios/IOGPU disasm of _IOGPUResourceCreate):
    //   args+0x00 = type byte (0 = heap, 0x80 = client buffer, 0x82 = iosurface)
    //   args+0x14 = flag mask (0x430 for iosurface, 0x0 for heap typical)
    //   args+0x40 = size (for type=0 heap) or length (for type=0x80)
    //   total inStructCnt typically 0x60 - 0x70 bytes
    //
    // Output struct: kernel writes a IOGPUResource ID/handle at args.out
    // outStructCnt = 0x50 (matches what macOS userland sends).
    {
        unsigned char in_args[0x70];
        unsigned char out_args[0x50];
        memset(in_args, 0, sizeof(in_args));
        memset(out_args, 0, sizeof(out_args));
        // type=0 heap, size=0x10000 (64KB heap chunk like Mempool would req)
        in_args[0x00] = 0x00;
        *(uint64_t *)(in_args + 0x40) = 0x10000;
        size_t outSz = sizeof(out_args);
        // *** CRITICAL: iOS-native sel=0x9 = new_resource (NOT sel=0xa).
        // Chroot's macOS sel=0xa goes through libmachook's
        // IOConnectTranslateSelector → 0x9 → kernel's new_resource. So to
        // match what chroot's failing call REALLY hits, we call 0x9 here.
        kr = IOConnectCallMethod(conn, 0x9,
            NULL, 0,          /* scalar in */
            in_args, sizeof(in_args),
            NULL, NULL,       /* scalar out */
            out_args, &outSz);
        fprintf(stderr, "  sel=0x9 type=0 size=0x10000 (raw, no pre-setup) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS!)" : "(FAIL)");
        if (kr == 0) {
            uint32_t gid = *(uint32_t *)(out_args + 0x00);
            fprintf(stderr, "    out gid          = %#x\n", gid);
            fprintf(stderr, "    outStructCnt out = %#zx\n", outSz);
        }
    }

    // Hypothesis: iOS Metal calls sel=0x6 (set_api_property) FIRST, that sets
    // up per-UC state (maybe writes UC->0x108 / device->0x224 / similar) that
    // new_resource depends on. Let's try the sequence:
    //   1. sel=0x6 with zeroed 0x408 inStruct (we just confirmed this works)
    //   2. sel=0x9 with type=0 heap-create
    // If sel=0x9 now succeeds → 0x6 IS the missing setup step.
    {
        unsigned char in_p[0x408];
        unsigned char out_p[0x10];
        memset(in_p, 0, sizeof(in_p));
        memset(out_p, 0, sizeof(out_p));
        size_t outSz = sizeof(out_p);
        kr = IOConnectCallMethod(conn, 0x6,
            NULL, 0,
            in_p, sizeof(in_p),
            NULL, NULL,
            out_p, &outSz);
        fprintf(stderr, "  sel=0x6 set_api_property (prereq?) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS)" : "(FAIL)");
    }
    // Retry sel=0x9 after sel=0x6
    {
        unsigned char in_args[0x70];
        unsigned char out_args[0x50];
        memset(in_args, 0, sizeof(in_args));
        memset(out_args, 0, sizeof(out_args));
        in_args[0x00] = 0x00;
        *(uint64_t *)(in_args + 0x40) = 0x10000;
        size_t outSz = sizeof(out_args);
        kr = IOConnectCallMethod(conn, 0x9,
            NULL, 0,
            in_args, sizeof(in_args),
            NULL, NULL,
            out_args, &outSz);
        fprintf(stderr, "  sel=0x9 AFTER sel=0x6 setup -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS — sel=0x6 IS the missing prereq)" : "(FAIL)");
    }

    // Try sel=0x7 = new_command_queue (kernel-side). Chroot fails on this.
    {
        unsigned char in_q[0x408];
        unsigned char out_q[0x10];
        memset(in_q, 0, sizeof(in_q));
        memset(out_q, 0, sizeof(out_q));
        size_t outSz = sizeof(out_q);
        kr = IOConnectCallMethod(conn, 0x7,
            NULL, 0,
            in_q, sizeof(in_q),
            NULL, NULL,
            out_q, &outSz);
        fprintf(stderr, "  sel=0x7 (queue-create) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS)" : "(FAIL)");
    }

    // Try sel=0x100 = device info query — should always work
    {
        unsigned char out_info[0x70];
        memset(out_info, 0, sizeof(out_info));
        size_t outSz = sizeof(out_info);
        kr = IOConnectCallMethod(conn, 0x100,
            NULL, 0, NULL, 0, NULL, NULL,
            out_info, &outSz);
        fprintf(stderr, "  sel=0x100 (device-info) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(OK)" : "(FAIL)");
    }

    IOServiceClose(conn);
}

int main(int argc, char **argv) {
    fprintf(stderr, "agx_iogpu_probe — iOS-native AGX UC field reader\n");
    if (load_libjb() != 0) return 1;

    // Try several user-client class types to ensure at least one works.
    probe_one("AGXAccelerator", 1);   // standard IOGPUDeviceUserClient
    probe_one("AGXAccelerator", 0);   // alt type used by chroot WS path
    probe_one("AGXAccelerator", 2);   // explicit alt
    probe_one("IOGPU", 1);            // direct
    return 0;
}
