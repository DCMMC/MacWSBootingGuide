#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>

typedef int (*init_primitives_t)(void);
typedef uint64_t (*kread64_t)(uint64_t va);

int main(int argc, char **argv) {
    fprintf(stderr, "krwtest: uid=%d pid=%d\n", getuid(), getpid());
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
    int (*init)(void) = dlsym(h, "jbclient_initialize_primitives");
    kread64_t kread64 = dlsym(h, "kread64");
    int rc = init();
    fprintf(stderr, "init rc=%d\n", rc);
    if (rc != 0) return 2;

    // gSystemInfo is the big struct. Look it up.
    uint8_t *gSI = (uint8_t *)dlsym(h, "gSystemInfo");
    if (!gSI) { fprintf(stderr, "gSystemInfo NOT FOUND\n"); return 3; }
    // First 8 fields of kernelConstant are uint64_t each (per info.h order):
    // staticBase, base, virtBase, virtSize, physBase, physSize, cpuTTEP, kernel_el
    uint64_t *kc = (uint64_t *)gSI;
    fprintf(stderr, "kernelConstant.staticBase = %#llx\n", kc[0]);
    fprintf(stderr, "kernelConstant.base       = %#llx\n", kc[1]);
    fprintf(stderr, "kernelConstant.virtBase   = %#llx\n", kc[2]);
    fprintf(stderr, "kernelConstant.virtSize   = %#llx\n", kc[3]);
    fprintf(stderr, "kernelConstant.physBase   = %#llx\n", kc[4]);
    fprintf(stderr, "kernelConstant.physSize   = %#llx\n", kc[5]);
    fprintf(stderr, "kernelConstant.cpuTTEP    = %#llx\n", kc[6]);
    fprintf(stderr, "kernelConstant.kernel_el  = %#llx\n", kc[7]);
    fprintf(stderr, "kernelConstant.pointer_mask = %#llx\n", kc[8]);

    // Read mach header at base
    uint64_t base = kc[1];
    if (base) {
        uint64_t v = kread64(base);
        fprintf(stderr, "kread64(base=%#llx) = %#llx\n", base, v);
    }
    return 0;
}
