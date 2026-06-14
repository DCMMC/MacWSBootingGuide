#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char **argv) {
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    uint32_t (*kread32)(uint64_t) = dlsym(h, "kread32");
    int (*kwrite32)(uint64_t, uint32_t) = dlsym(h, "kwrite32");
    uint32_t (*physread32)(uint64_t) = dlsym(h, "physread32");
    int (*physwrite32)(uint64_t, uint32_t) = dlsym(h, "physwrite32");
    uint64_t (*kvtophys)(uint64_t) = dlsym(h, "kvtophys");
    if (init() != 0) return 1;
    uint8_t *gSI = dlsym(h, "gSystemInfo");
    uint64_t slide = *(uint64_t*)gSI;
    uint64_t physBase = *(uint64_t*)(gSI + 5*8);
    uint64_t physEnd = physBase + *(uint64_t*)(gSI + 6*8);
    uint64_t va = 0xfffffe000873ba44ULL + slide;
    fprintf(stderr, "[+] va=%#llx slide=%#llx DRAM=%#llx..%#llx\n", va, slide, physBase, physEnd);

    uint32_t origK = kread32(va);
    fprintf(stderr, "[+] kread orig = %#x\n", origK);

    uint64_t pa = kvtophys(va);
    fprintf(stderr, "[+] kvtophys -> %#llx (in DRAM=%d)\n", pa, pa >= physBase && pa < physEnd);

    uint32_t origP = physread32(pa);
    fprintf(stderr, "[+] physread = %#x (match=%d)\n", origP, origP == origK);

    // IDENTITY kwrite first
    int r1 = kwrite32(va, origK);
    uint32_t afterK = kread32(va);
    fprintf(stderr, "[+] kwrite32 identity r=%d after_kread=%#x (unchanged=%d)\n", r1, afterK, afterK == origK);

    // IDENTITY physwrite
    int r2 = physwrite32(pa, origK);
    uint32_t afterP = physread32(pa);
    fprintf(stderr, "[+] physwrite32 identity r=%d after_physread=%#x (unchanged=%d)\n", r2, afterP, afterP == origK);

    // REAL WRITE: replace with NOP
    if (argc > 1 && !strcmp(argv[1], "GO")) {
        uint32_t nop = 0xd503201fU;
        fprintf(stderr, "[*] REAL WRITE: %#x -> %#x via physwrite32\n", origK, nop);
        int r3 = physwrite32(pa, nop);
        uint32_t now_p = physread32(pa);
        uint32_t now_k = kread32(va);
        fprintf(stderr, "[+] r=%d physread=%#x kread=%#x (want %#x)\n", r3, now_p, now_k, nop);
        // Restore
        int r4 = physwrite32(pa, origK);
        uint32_t restored = physread32(pa);
        fprintf(stderr, "[+] restored r=%d physread=%#x (want %#x)\n", r4, restored, origK);
    }
    return 0;
}
