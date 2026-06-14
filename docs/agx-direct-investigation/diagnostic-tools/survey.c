#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

static uint64_t g_physBase, g_physEnd;
static int score_table_pt(uint64_t *page, int count) {
    int valid = 0;
    for (int i = 0; i < count; i++) {
        uint64_t e = page[i];
        if (e == 0) continue;
        if ((e & 0x3) != 0x3) continue;
        uint64_t pa = (e & 0x000000ffffffc000ULL);
        if (pa >= g_physBase && pa < g_physEnd) valid++;
    }
    return valid;
}

int main(void) {
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    uint64_t (*kread64)(uint64_t) = dlsym(h, "kread64");
    int (*physreadbuf)(uint64_t, void*, size_t) = dlsym(h, "physreadbuf");
    uint64_t (*task_self)(void) = dlsym(h, "task_self");
    uint64_t (*tgipk)(uint64_t, mach_port_t) = dlsym(h, "task_get_ipc_port_kobject");
    uint64_t (*kvtophys)(uint64_t) = dlsym(h, "kvtophys");
    if (init() != 0) return 2;
    uint8_t *gSI = dlsym(h, "gSystemInfo");
    uint64_t pmask = ((uint64_t *)gSI)[9];
    g_physBase = ((uint64_t *)gSI)[5];
    g_physEnd = g_physBase + ((uint64_t *)gSI)[6];
    #define UNSIGN(p) (((p) & (1ULL << 55)) ? ((p) | pmask) : ((p) & ~pmask))

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
    uint64_t local_mux = UNSIGN(kread64(gart + 0x288));
    uint64_t shared_mux = UNSIGN(kread64(gart + 0x28));
    fprintf(stderr, "DRAM=%#llx..%#llx\nGart=%#llx SharedMux=%#llx LocalMux=%#llx\n",
            g_physBase, g_physEnd, gart, shared_mux, local_mux);

    uint64_t page[2048];
    // 2-level scan from Gart
    fprintf(stderr, "\n=== Gart 2-level: any pointer leading to a 16K page with >=3 valid table entries ===\n");
    int hits = 0;
    for (int l1 = 0x10; l1 < 0x300; l1 += 8) {
        uint64_t c = UNSIGN(kread64(gart + l1));
        if ((c >> 48) != 0xfffe && (c >> 48) != 0xffff) continue;
        // Try this pointer's PA
        uint64_t pa = kvtophys(c);
        if (pa >= g_physBase && pa < g_physEnd && physreadbuf(pa, page, sizeof(page)) == 0) {
            int v = score_table_pt(page, 2048);
            if (v >= 3) {
                fprintf(stderr, "  L1 Gart+%#x va=%#llx pa=%#llx valid_table_entries=%d\n", l1, c, pa, v);
                for (int i = 0; i < 8; i++) {
                    int ok = (page[i] & 0x3) == 0x3 && (page[i] & 0x000000ffffffc000ULL) >= g_physBase && (page[i] & 0x000000ffffffc000ULL) < g_physEnd;
                    if (page[i]) fprintf(stderr, "    [%d]=%#llx%s\n", i, page[i], ok ? " *VALID*" : "");
                }
                hits++;
            }
        }
        // L2: scan inside c
        for (int l2 = 0; l2 < 0x100; l2 += 8) {
            uint64_t v = UNSIGN(kread64(c + l2));
            if ((v >> 48) != 0xfffe && (v >> 48) != 0xffff) continue;
            uint64_t pa2 = kvtophys(v);
            if (pa2 < g_physBase || pa2 >= g_physEnd) continue;
            if (physreadbuf(pa2, page, sizeof(page)) != 0) continue;
            int valid = score_table_pt(page, 2048);
            if (valid >= 3) {
                fprintf(stderr, "  L2 Gart+%#x->+%#x va=%#llx pa=%#llx valid_table_entries=%d\n",
                        l1, l2, v, pa2, valid);
                for (int i = 0; i < 8; i++) {
                    int ok = (page[i] & 0x3) == 0x3 && (page[i] & 0x000000ffffffc000ULL) >= g_physBase && (page[i] & 0x000000ffffffc000ULL) < g_physEnd;
                    if (page[i]) fprintf(stderr, "    [%d]=%#llx%s\n", i, page[i], ok ? " *VALID*" : "");
                }
                hits++;
                if (hits > 12) goto done;
            }
        }
    }
done:
    fprintf(stderr, "\nDone. hits=%d\n", hits);
    return 0;
}
