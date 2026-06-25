// metal_probe_lib.m — dylib version: inject via DYLD_INSERT_LIBRARIES
// Build: clang -dynamiclib -framework Foundation -framework IOKit -o /tmp/metal_probe.dylib misc/metal_probe_lib.m
// Use:   DYLD_INSERT_LIBRARIES=/tmp/metal_probe.dylib ./metal_test
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>

extern kern_return_t IOConnectCallMethod(
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt);

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static int call_count = 0;
static int sel9_count = 0;
static FILE *logfp = NULL;

__attribute__((constructor))
static void init_probe(void) {
    logfp = fopen("/tmp/mac_iokit.log", "w");
    if (!logfp) logfp = stderr;
    fprintf(logfp, "==== metal_probe_lib loaded pid=%d ====\n", getpid());
    fflush(logfp);
}

kern_return_t my_IOConnectCallMethod(
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt) {

    kern_return_t kr = IOConnectCallMethod(conn, selector, input, inputCnt,
                                            inputStruct, inputStructCnt,
                                            output, outputCnt,
                                            outputStruct, outputStructCnt);

    pthread_mutex_lock(&log_lock);
    int idx = ++call_count;
    size_t outsc = outputStructCnt ? *outputStructCnt : 0;
    fprintf(logfp, "[%05d] conn=%u sel=%u inCnt=%u inSC=%zu outSC=%zu kr=%d",
            idx, conn, selector, inputCnt, inputStructCnt, outsc, kr);

    if (selector == 9 && kr == 0 && inputStruct && inputStructCnt >= 0x48 &&
        outputStruct && outsc >= 0x20) {
        sel9_count++;
        const uint8_t *ib = inputStruct;
        const uint8_t *ob = outputStruct;
        uint64_t in10 = 0, in40 = 0;
        memcpy(&in10, ib + 0x10, 8);
        memcpy(&in40, ib + 0x40, 8);
        uint64_t out08 = 0, out18 = 0, out40 = 0;
        memcpy(&out08, ob + 0x08, 8);
        memcpy(&out18, ob + 0x18, 8);
        if (outsc >= 0x48) memcpy(&out40, ob + 0x40, 8);
        fprintf(logfp, "\n  SEL9#%03d | in+0x10=%#018llx in+0x40=%#llx | "
                "out+0x08(gpuAddr)=%#llx out+0x18=%#llx REGION=0x%llx out+0x40=%#llx",
                sel9_count,
                (unsigned long long)in10, (unsigned long long)in40,
                (unsigned long long)out08, (unsigned long long)out18,
                (unsigned long long)(out18 >> 32),
                (unsigned long long)out40);
    }
    fprintf(logfp, "\n");
    fflush(logfp);
    pthread_mutex_unlock(&log_lock);

    return kr;
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } \
   _interpose_##_replacee __attribute__ ((section ("__DATA,__interpose"))) = { \
       (const void*)(unsigned long)&_replacement, \
       (const void*)(unsigned long)&_replacee \
   };

DYLD_INTERPOSE(my_IOConnectCallMethod, IOConnectCallMethod)
