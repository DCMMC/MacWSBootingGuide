#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

static uint64_t g_physBase, g_physEnd, g_pmask;
#define UNSIGN(p) (((p) & (1ULL << 55)) ? ((p) | g_pmask) : ((p) & ~g_pmask))
#define IS_KP(p)  (((p) >> 48) == 0xfffe || ((p) >> 48) == 0xffff)

static int score_table(uint64_t *page, int count) {
    int valid = 0;
    for (int i = 0; i < count; i++) {
        uint64_t e = page[i];
        if (e == 0) continue;
        // Table descriptor: bits 0+1 = 0b11
        if ((e & 0x3) == 0x3) {
            uint64_t pa = (e & 0x000000ffffffc000ULL);
            if (pa >= g_physBase && pa < g_physEnd) valid++;
        }
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
    fprintf(stderr, "Gart=%#llx SharedMux=%#llx\n", gart, shared_mux);

    uint64_t page[2048];
    int hits = 0;

    // 3-level: gart -> ptr -> ptr -> ptr -> physread+score
    for (int l1 = 0x10; l1 < 0x300 && hits < 8; l1 += 8) {
        uint64_t p1 = UNSIGN(kread64(gart + l1));
        if (!IS_KP(p1)) continue;
        for (int l2 = 0; l2 < 0x100 && hits < 8; l2 += 8) {
            uint64_t p2 = UNSIGN(kread64(p1 + l2));
            if (!IS_KP(p2)) continue;
            // L3: also try the ptr itself
            uint64_t targets[2] = {p2, 0};
            for (int t = 0; t < 1; t++) {
                uint64_t v = targets[t];
                if (!v) continue;
                uint64_t pa = kvtophys(v);
                if (pa < g_physBase || pa >= g_physEnd) continue;
                if (physreadbuf(pa, page, sizeof(page)) != 0) continue;
                int valid = score_table(page, 2048);
                if (valid >= 8) {
                    fprintf(stderr, "PT-PAGE g+%#x->+%#x va=%#llx pa=%#llx valid_descriptors=%d\n", l1, l2, v, pa, valid);
                    int shown = 0;
                    for (int i = 0; i < 16 && shown < 10; i++) {
                        uint64_t e = page[i];
                        if (!e) continue;
                        int ok = (e & 0x3) == 0x3 && (e & 0x000000ffffffc000ULL) >= g_physBase && (e & 0x000000ffffffc000ULL) < g_physEnd;
                        fprintf(stderr, "  [%d]=%#llx %s\n", i, e, ok ? "*TABLE*" : "");
                        shown++;
                    }
                    hits++;
                }
            }
            // L3: follow p2 one more level
            for (int l3 = 0; l3 < 0x100 && hits < 8; l3 += 8) {
                uint64_t p3 = UNSIGN(kread64(p2 + l3));
                if (!IS_KP(p3)) continue;
                uint64_t pa = kvtophys(p3);
                if (pa < g_physBase || pa >= g_physEnd) continue;
                if (physreadbuf(pa, page, sizeof(page)) != 0) continue;
                int valid = score_table(page, 2048);
                if (valid >= 8) {
                    fprintf(stderr, "PT-PAGE L3 g+%#x->+%#x->+%#x va=%#llx pa=%#llx valid=%d\n",
                            l1, l2, l3, p3, pa, valid);
                    int shown = 0;
                    for (int i = 0; i < 16 && shown < 10; i++) {
                        uint64_t e = page[i];
                        if (!e) continue;
                        int ok = (e & 0x3) == 0x3 && (e & 0x000000ffffffc000ULL) >= g_physBase && (e & 0x000000ffffffc000ULL) < g_physEnd;
                        fprintf(stderr, "  [%d]=%#llx %s\n", i, e, ok ? "*T*" : "");
                        shown++;
                    }
                    hits++;
                }
            }
        }
    }
    fprintf(stderr, "\nL3 survey done. hits=%d\n", hits);
    return 0;
}
