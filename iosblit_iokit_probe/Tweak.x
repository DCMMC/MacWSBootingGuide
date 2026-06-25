@import CydiaSubstrate;
@import Foundation;
@import Darwin;
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>

// Hook IOConnectCallMethod inside iosblit to capture every sel=9 input.
// Output: /var/mobile/Containers/Data/Application/<uuid>/Documents/iosblit_iokit.log (sandbox-safe)
// or fallback /tmp/iosblit_iokit.log (works if entitlements allow).

static FILE *g_log = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_calls = 0;
static int g_sel9 = 0;

typedef kern_return_t (*IOConnectCallMethod_t)(
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt);

static IOConnectCallMethod_t orig_IOConnectCallMethod = NULL;

static kern_return_t my_IOConnectCallMethod(
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt) {

    // Snapshot input bytes BEFORE the call (kernel may write back into them)
    uint64_t pre_in10 = 0, pre_in40 = 0, pre_in00 = 0, pre_in08 = 0;
    if (inputStruct && inputStructCnt >= 0x48) {
        const uint8_t *ib = (const uint8_t *)inputStruct;
        memcpy(&pre_in00, ib + 0x00, 8);
        memcpy(&pre_in08, ib + 0x08, 8);
        memcpy(&pre_in10, ib + 0x10, 8);
        memcpy(&pre_in40, ib + 0x40, 8);
    }
    size_t pre_outsc = outputStructCnt ? *outputStructCnt : 0;

    kern_return_t kr = orig_IOConnectCallMethod(conn, selector, input, inputCnt,
                                                 inputStruct, inputStructCnt,
                                                 output, outputCnt,
                                                 outputStruct, outputStructCnt);

    pthread_mutex_lock(&g_lock);
    g_calls++;
    if (g_log) {
        fprintf(g_log, "[%04d] conn=%u sel=%u inCnt=%u inSC=%zu outSC=%zu->%zu kr=%d\n",
                g_calls, conn, selector, inputCnt,
                inputStructCnt, pre_outsc, outputStructCnt ? *outputStructCnt : 0, kr);
        if (selector == 9 && kr == 0 && inputStruct && inputStructCnt >= 0x48) {
            g_sel9++;
            uint64_t post_in40 = 0, post_out08 = 0, post_out18 = 0, post_out40 = 0;
            memcpy(&post_in40, (const uint8_t *)inputStruct + 0x40, 8);
            if (outputStruct && outputStructCnt && *outputStructCnt >= 0x20) {
                const uint8_t *ob = (const uint8_t *)outputStruct;
                memcpy(&post_out08, ob + 0x08, 8);
                memcpy(&post_out18, ob + 0x18, 8);
                if (*outputStructCnt >= 0x48) memcpy(&post_out40, ob + 0x40, 8);
            }
            fprintf(g_log,
                "  SEL9#%03d PRE: in+0x00=%#llx in+0x08=%#llx in+0x10=%#llx in+0x40=%#llx\n"
                "           POST: in+0x40=%#llx out+0x08(gpuAddr)=%#llx out+0x18(region)=%#llx (=%#llx) out+0x40=%#llx\n",
                g_sel9,
                (unsigned long long)pre_in00, (unsigned long long)pre_in08,
                (unsigned long long)pre_in10, (unsigned long long)pre_in40,
                (unsigned long long)post_in40,
                (unsigned long long)post_out08,
                (unsigned long long)post_out18,
                (unsigned long long)(post_out18 >> 32),
                (unsigned long long)post_out40);
        }
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);

    return kr;
}

%ctor {
    // EARLIEST possible diagnostic — syslog always works
    syslog(LOG_NOTICE, "IOSBLIT_PROBE: ctor running pid=%d", getpid());
    fprintf(stderr, "IOSBLIT_PROBE: ctor running pid=%d\n", getpid());

    // iOS sandbox: write to NSDocumentDirectory (always writable for the app)
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    syslog(LOG_NOTICE, "IOSBLIT_PROBE: NSDocumentDirectory has %lu paths", (unsigned long)paths.count);
    if (paths.count > 0) {
        NSString *p = [paths.firstObject stringByAppendingPathComponent:@"iosblit_iokit.log"];
        g_log = fopen(p.UTF8String, "w");
        if (g_log) {
            fprintf(g_log, "==== iosblit_iokit_probe loaded; logging to %s ====\n", p.UTF8String);
            // Also drop a marker filename into /tmp via syslog so we can find the container
            syslog(LOG_NOTICE, "iosblit_iokit_probe: log at %s", p.UTF8String);
        }
    }
    if (!g_log) {
        // Fallback paths
        const char *paths_c[] = { "/tmp/iosblit_iokit.log", "/var/tmp/iosblit_iokit.log", NULL };
        for (int i = 0; paths_c[i]; i++) {
            g_log = fopen(paths_c[i], "w");
            if (g_log) {
                fprintf(g_log, "==== iosblit_iokit_probe loaded; logging to %s ====\n", paths_c[i]);
                break;
            }
        }
    }
    if (!g_log) {
        syslog(LOG_NOTICE, "iosblit_iokit_probe: ALL paths failed");
        g_log = stderr;
    }
    fflush(g_log);

    MSHookFunction((void *)&IOConnectCallMethod,
                   (void *)&my_IOConnectCallMethod,
                   (void **)&orig_IOConnectCallMethod);
    fprintf(g_log, "==== IOConnectCallMethod hook installed ====\n");
    fflush(g_log);
}
