#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

static uint64_t g_physBase, g_physEnd, g_pmask;
#define UNSIGN(p) (((p) & (1ULL << 55)) ? ((p) | g_pmask) : ((p) & ~g_pmask))
#define IS_KP(p)  (((p) >> 48) == 0xfffe || ((p) >> 48) == 0xffff)

// Strict: counts (valid_table, valid_pte, total_nonzero). Real PT will have ratio >= 0.8
static void score_strict(uint64_t *page, int count, int *out_table, int *out_pte, int *out_nonzero) {
    int t = 0, p = 0, n = 0;
    const uint64_t PTE_MASK = 0x0080000000000403ULL;
    for (int i = 0; i < count; i++) {
        uint64_t e = page[i];
        if (e == 0) continue;
        n++;
        if ((e & 0x3) == 0x3) {
            uint64_t pa = (e & 0x000000ffffffc000ULL);
            if (pa >= g_physBase && pa < g_physEnd) t++;
        }
        if ((e & PTE_MASK) == PTE_MASK) {
            uint64_t pa = (e & 0x000000ffffffc000ULL);
            if (pa >= g_physBase && pa < g_physEnd) p++;
        }
    }
    *out_table = t; *out_pte = p; *out_nonzero = n;
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
    g_pmask = ((uint64_t *)gSI)[9];
    g_physBase = ((uint64_t *)gSI)[5];
    g_physEnd = g_physBase + ((uint64_t *)gSI)[6];

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
    uint64_t shared_mux = UNSIGN(kread64(gart + 0x28));
    uint64_t local_mux = UNSIGN(kread64(gart + 0x288));
    fprintf(stderr, "Gart=%#llx SharedMux=%#llx LocalMux=%#llx\n", gart, shared_mux, local_mux);

    uint64_t page[2048];
    int total_pages_checked = 0;
    int hits = 0;

    // 3-level deep search, STRICT heuristic
    for (int l1 = 0x10; l1 < 0x300 && hits < 5; l1 += 8) {
        uint64_t p1 = UNSIGN(kread64(gart + l1));
        if (!IS_KP(p1)) continue;
        for (int l2 = 0; l2 < 0x200 && hits < 5; l2 += 8) {
            uint64_t p2 = UNSIGN(kread64(p1 + l2));
            if (!IS_KP(p2)) continue;
            uint64_t targets[3] = {p1, p2, 0};
            for (int t = 0; t < 2; t++) {
                uint64_t v = targets[t];
                if (!v) continue;
                uint64_t pa = kvtophys(v);
                if (pa < g_physBase || pa >= g_physEnd) continue;
                if (physreadbuf(pa, page, sizeof(page)) != 0) continue;
                total_pages_checked++;
                int nt, np, nn;
                score_strict(page, 2048, &nt, &np, &nn);
                // Strict: at least 8 valid entries AND ratio of valid/non-zero ≥ 0.7
                int valid = nt + np;
                if (valid >= 8 && nn > 0 && (valid * 10 / nn) >= 7) {
                    fprintf(stderr, "PT! g+%#x ptr%d=%#llx pa=%#llx table=%d pte=%d nonzero=%d ratio=%d%%\n",
                            l1, t, v, pa, nt, np, nn, valid*100/nn);
                    for (int i = 0; i < 16; i++) {
                        if (page[i]) fprintf(stderr, "  [%d]=%#llx\n", i, page[i]);
                    }
                    hits++;
                }
            }
            // L3
            for (int l3 = 0; l3 < 0x100 && hits < 5; l3 += 8) {
                uint64_t p3 = UNSIGN(kread64(p2 + l3));
                if (!IS_KP(p3)) continue;
                uint64_t pa = kvtophys(p3);
                if (pa < g_physBase || pa >= g_physEnd) continue;
                if (physreadbuf(pa, page, sizeof(page)) != 0) continue;
                total_pages_checked++;
                int nt, np, nn;
                score_strict(page, 2048, &nt, &np, &nn);
                int valid = nt + np;
                if (valid >= 8 && nn > 0 && (valid * 10 / nn) >= 7) {
                    fprintf(stderr, "PT-L3 g+%#x->+%#x->+%#x ptr=%#llx pa=%#llx table=%d pte=%d nonzero=%d ratio=%d%%\n",
                            l1, l2, l3, p3, pa, nt, np, nn, valid*100/nn);
                    for (int i = 0; i < 16; i++) {
                        if (page[i]) fprintf(stderr, "  [%d]=%#llx\n", i, page[i]);
                    }
                    hits++;
                }
            }
        }
    }
    fprintf(stderr, "\nstrict survey: checked %d pages, %d hits\n", total_pages_checked, hits);
    return 0;
}
