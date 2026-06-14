#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <IOKit/IOKitLib.h>

int main(int argc, char **argv) {
    int do_write = (argc > 1 && strcmp(argv[1], "WRITE") == 0);
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    uint64_t (*kread64)(uint64_t) = dlsym(h, "kread64");
    uint64_t (*physread64)(uint64_t) = dlsym(h, "physread64");
    int      (*physwrite64)(uint64_t, uint64_t) = dlsym(h, "physwrite64");
    uint64_t (*task_self)(void) = dlsym(h, "task_self");
    uint64_t (*tgipk)(uint64_t, mach_port_t) = dlsym(h, "task_get_ipc_port_kobject");
    uint64_t (*kvtophys)(uint64_t) = dlsym(h, "kvtophys");
    if (init() != 0) return 2;
    uint8_t *gSI = dlsym(h, "gSystemInfo");
    uint64_t pmask = ((uint64_t *)gSI)[9];

    #define UNSIGN(p) (((p) & (1ULL << 55)) ? ((p) | pmask) : ((p) & ~pmask))

    // We can't navigate to OUR UAT (krwtest doesn't open AGX user client).
    // Instead, find ALL DUC instances and pick the one belonging to OUR pid OR any one.
    io_service_t agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAcceleratorG13G_B0"));
    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(agx, "IOService", &it);
    io_object_t child;
    int idx = 0;
    while ((child = IOIteratorNext(it))) {
        io_name_t klass = {0};
        IOObjectGetClass(child, klass);
        if (!strstr(klass, "DeviceUserClient")) { IOObjectRelease(child); continue; }
        uint64_t kp = tgipk(task_self(), child);
        uint64_t agxshared = UNSIGN(kread64(kp + 0x120));
        uint64_t gart = UNSIGN(kread64(agxshared + 0x58));
        uint64_t local_mux = UNSIGN(kread64(gart + 0x288));
        uint64_t per_task = UNSIGN(kread64(local_mux + 0x10));
        uint64_t ttb_va = UNSIGN(kread64(per_task + 0x28));
        uint64_t ttb_pa = ttb_va ? kvtophys(ttb_va) : 0;
        fprintf(stderr, "[%d] DUC=%#llx Gart=%#llx LocalMux=%#llx PerTask=%#llx TTB_VA=%#llx TTB_PA=%#llx\n",
                idx, kp, gart, local_mux, per_task, ttb_va, ttb_pa);
        if (ttb_pa) {
            uint64_t l1_0 = physread64(ttb_pa);
            uint64_t l1_1 = physread64(ttb_pa + 8);
            fprintf(stderr, "   L1[0]=%#llx L1[1]=%#llx\n", l1_0, l1_1);
        }
        idx++;
        IOObjectRelease(child);
        if (idx >= 3) break;  // first 3 DUCs only
    }
    IOObjectRelease(it);
    return 0;
}
