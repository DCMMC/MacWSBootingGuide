#include <string.h>
// text_write_test — verify Dopamine can physwrite to a __TEXT page on iOS 16.3.1 arm64e
// Pick a safe address: AGXSecureGart::deallocate's first instruction (rarely called for our test)
// Read original → physwrite same value back (identity, no harm) → read back → compare
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>

int main(int argc, char **argv) {
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    uint32_t (*kread32)(uint64_t) = dlsym(h, "kread32");
    int (*kwrite32)(uint64_t, uint32_t) = dlsym(h, "kwrite32");
    uint32_t (*physread32)(uint64_t) = dlsym(h, "physread32");
    int (*physwrite32)(uint64_t, uint32_t) = dlsym(h, "physwrite32");
    uint64_t (*kvtophys)(uint64_t) = dlsym(h, "kvtophys");
    if (init() != 0) return 2;
    uint8_t *gSI = dlsym(h, "gSystemInfo");
    uint64_t slide = ((uint64_t *)gSI)[0];
    uint64_t physBase = ((uint64_t *)gSI)[5];
    uint64_t physEnd = physBase + ((uint64_t *)gSI)[6];
    fprintf(stderr, "[+] init slide=%#llx DRAM=%#llx..%#llx\n", slide, physBase, physEnd);

    // AGXSecureGart::deallocate(uint64_t, uint64_t, uint32_t, uint64_t) @ unslid 0xfffffe000873ba44
    uint64_t target_va = 0xfffffe000873ba44ULL + slide;
    fprintf(stderr, "[*] target = %#llx (slid AGXSecureGart::deallocate)\n", target_va);

    // 1) kread first 4 bytes
    uint32_t orig_kread = kread32(target_va);
    fprintf(stderr, "[+] kread32 orig = %#x\n", orig_kread);

    // 2) kvtophys
    uint64_t target_pa = kvtophys(target_va);
    fprintf(stderr, "[+] kvtophys = %#llx (in DRAM=%d)\n", target_pa, target_pa >= physBase && target_pa < physEnd);

    // 3) physread same address
    uint32_t orig_phys = physread32(target_pa);
    fprintf(stderr, "[+] physread32 = %#x (match kread? %d)\n", orig_phys, orig_phys == orig_kread);

    if (orig_phys != orig_kread) {
        fprintf(stderr, "[!] kread/physread mismatch — something weird with mapping\n");
        return 3;
    }

    // 4) Try kwrite32 — write SAME value back. If kernel rejects, kwrite32 returns nonzero.
    int kw_r = kwrite32(target_va, orig_kread);
    fprintf(stderr, "[+] kwrite32 identity write r=%d\n", kw_r);

    // 5) Try physwrite32 — write SAME value back.
    int pw_r = physwrite32(target_pa, orig_kread);
    fprintf(stderr, "[+] physwrite32 identity write r=%d\n", pw_r);

    // 6) Read back to verify (try BOTH paths since they should agree)
    uint32_t after_kread = kread32(target_va);
    uint32_t after_phys = physread32(target_pa);
    fprintf(stderr, "[+] AFTER: kread=%#x physread=%#x (orig=%#x)\n", after_kread, after_phys, orig_kread);
    fprintf(stderr, "[+] kread unchanged: %d, physread unchanged: %d\n",
        after_kread == orig_kread, after_phys == orig_kread);

    // 7) Real test: write a DIFFERENT value (NOP = 0xd503201f) then restore. ONLY do this if asked.
    if (argc > 1 && !strcmp(argv[1], "REAL_WRITE")) {
        uint32_t nop = 0xd503201fU;
        fprintf(stderr, "[*] REAL_WRITE: replacing first inst with NOP via physwrite32...\n");
        int r1 = physwrite32(target_pa, nop);
        uint32_t v1_phys = physread32(target_pa);
        uint32_t v1_kread = kread32(target_va);
        fprintf(stderr, "[+] r=%d physread=%#x kread=%#x (expect %#x)\n", r1, v1_phys, v1_kread, nop);
        // Restore
        int r2 = physwrite32(target_pa, orig_kread);
        uint32_t v2_phys = physread32(target_pa);
        fprintf(stderr, "[+] restored r=%d physread=%#x (expect %#x)\n", r2, v2_phys, orig_kread);
    }
    return 0;
}
