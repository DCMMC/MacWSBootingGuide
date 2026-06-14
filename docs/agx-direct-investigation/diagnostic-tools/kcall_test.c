#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

static uint64_t g_pmask;
#define UNSIGN(p) (((p) & (1ULL << 55)) ? ((p) | g_pmask) : ((p) & ~g_pmask))
#define IS_KP(p)  (((p) >> 48) == 0xfffe || ((p) >> 48) == 0xffff)

int main(int argc, char **argv) {
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    uint64_t (*kread64)(uint64_t) = dlsym(h, "kread64");
    int (*kcall_fn)(uint64_t*, uint64_t, int, const uint64_t*) = dlsym(h, "kcall");
    uint64_t (*fugu14_kcall)(uint64_t, int, ...) = dlsym(h, "fugu14_kcall");
    int (*jbclient_get_fugu14_kcall_fn)(void) = dlsym(h, "jbclient_get_fugu14_kcall");
    int (*is_kcall_available_fn)(void) = dlsym(h, "is_kcall_available");
    uint64_t (*task_self)(void) = dlsym(h, "task_self");
    uint64_t (*tgipk)(uint64_t, mach_port_t) = dlsym(h, "task_get_ipc_port_kobject");
    uint8_t *gSI = dlsym(h, "gSystemInfo");
    if (init() != 0) return 2;
    g_pmask = ((uint64_t *)gSI)[9];
    uint64_t slide = ((uint64_t *)gSI)[0];
    fprintf(stderr, "[+] init slide=%#llx\n", slide);

    fprintf(stderr, "[*] is_kcall_available pre = %d\n", is_kcall_available_fn());
    fprintf(stderr, "[*] forcing jbclient_get_fugu14_kcall...\n");
    int gr = jbclient_get_fugu14_kcall_fn();
    fprintf(stderr, "[+] jbclient_get_fugu14_kcall returned %d\n", gr);
    fprintf(stderr, "[*] is_kcall_available post = %d\n", is_kcall_available_fn());

    // Try a simple kcall as test: load address of mapWithAddress
    if (!is_kcall_available_fn()) {
        fprintf(stderr, "[!] still no kcall — aborting\n");
        return 3;
    }
    fprintf(stderr, "[+] kcall is now available!\n");

    // Navigate to first DUC's Gart
    io_service_t agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAcceleratorG13G_B0"));
    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(agx, "IOService", &it);
    io_object_t child = IOIteratorNext(it);
    while (child) { io_name_t klass={0}; IOObjectGetClass(child, klass);
                    if (strstr(klass, "DeviceUserClient")) break;
                    IOObjectRelease(child); child = IOIteratorNext(it); }
    uint64_t kp = tgipk(task_self(), child);
    uint64_t agxshared = UNSIGN(kread64(kp + 0x120));
    uint64_t gart = UNSIGN(kread64(agxshared + 0x58));
    fprintf(stderr, "[+] DUC=%#llx Gart=%#llx\n", kp, gart);

    // First — kcall sanity: read Gart's vtable via a benign kernel function we KNOW returns nonzero.
    // Try calling `_current_task` if available, or just call mapWithAddress with NULL desc (should return 0 safely)
    uint64_t mapWithAddr = 0xfffffe000873bee4ULL + slide;
    fprintf(stderr, "[*] sanity kcall mapWithAddress(gart, NULL, 0x1100000000, 0x4000, 0)...\n");
    uint64_t result = 0xdeadbeef;
    uint64_t a[5] = {gart, 0, 0x1100000000ULL, 0x4000, 0};
    int r = kcall_fn(&result, mapWithAddr, 5, a);
    fprintf(stderr, "[+] sanity kcall r=%d result=%#llx (NULL desc, should be 0=fail)\n", r, result);
    return 0;
}
