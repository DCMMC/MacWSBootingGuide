@import CydiaSubstrate;
@import Darwin;
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <syslog.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <errno.h>

// Hook ALL IOConnectCall* + IOServiceOpen variants. PAC-cached function pointer theory predicts
// MSHook on the umbrella IOConnectCallMethod fails. But if Metal uses a DIFFERENT variant, hook
// on that variant will fire. IOServiceOpen is a control: must fire at least once (Metal opens a
// user-client at startup).

static FILE *g_log = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_calls = 0;
static int g_sel9 = 0;
static int g_iso_count = 0;

#define HOOK_DECL(name, ret, ...) \
    typedef ret (*name##_t)(__VA_ARGS__); \
    static name##_t orig_##name = NULL; \
    static ret my_##name(__VA_ARGS__)

// === IOServiceOpen (control: must fire) ===
HOOK_DECL(IOServiceOpen, kern_return_t, io_service_t s, task_t t, uint32_t type, io_connect_t *c) {
    kern_return_t kr = orig_IOServiceOpen(s, t, type, c);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_iso_count++;
        fprintf(g_log, "[IOServiceOpen #%d] type=%u kr=%d conn=%u\n", g_iso_count, type, kr, c ? *c : 0);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === Helper: dump a sel=9 call ===
static void log_sel9(const char *kind, mach_port_t conn, uint32_t selector,
                     const void *inputStruct, size_t inputStructCnt,
                     const void *outputStruct, size_t outputStructCnt, kern_return_t kr) {
    if (selector != 9 || kr != 0) return;
    if (!inputStruct || inputStructCnt < 0x48) return;
    g_sel9++;
    uint64_t in00 = 0, in08 = 0, in10 = 0, in40 = 0;
    const uint8_t *ib = inputStruct;
    memcpy(&in00, ib+0x00, 8);
    memcpy(&in08, ib+0x08, 8);
    memcpy(&in10, ib+0x10, 8);
    memcpy(&in40, ib+0x40, 8);
    uint64_t out08 = 0, out18 = 0;
    if (outputStruct && outputStructCnt >= 0x20) {
        const uint8_t *ob = outputStruct;
        memcpy(&out08, ob+0x08, 8);
        memcpy(&out18, ob+0x18, 8);
    }
    fprintf(g_log,
        "  SEL9#%03d [%s] conn=%u | in+0x10=%#llx in+0x40=%#llx | out+0x08=%#llx out+0x18(R=%#llx)\n",
        g_sel9, kind, conn,
        (unsigned long long)in10, (unsigned long long)in40,
        (unsigned long long)out08, (unsigned long long)(out18 >> 32));
}

// === IOConnectCallMethod ===
HOOK_DECL(IOConnectCallMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt) {
    kern_return_t kr = orig_IOConnectCallMethod(conn, selector, input, inputCnt,
        inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallMethod conn=%u sel=%u inSC=%zu kr=%d\n", g_calls, conn, selector, inputStructCnt, kr);
        log_sel9("CallMethod", conn, selector, inputStruct, inputStructCnt,
                 outputStruct, outputStructCnt ? *outputStructCnt : 0, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === IOConnectCallScalarMethod ===
HOOK_DECL(IOConnectCallScalarMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    uint64_t *output, uint32_t *outputCnt) {
    kern_return_t kr = orig_IOConnectCallScalarMethod(conn, selector, input, inputCnt, output, outputCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallScalarMethod conn=%u sel=%u inCnt=%u kr=%d\n", g_calls, conn, selector, inputCnt, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === IOConnectCallStructMethod ===
HOOK_DECL(IOConnectCallStructMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    const void *inputStruct, size_t inputStructCnt,
    void *outputStruct, size_t *outputStructCnt) {
    kern_return_t kr = orig_IOConnectCallStructMethod(conn, selector, inputStruct, inputStructCnt,
        outputStruct, outputStructCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallStructMethod conn=%u sel=%u inSC=%zu kr=%d\n", g_calls, conn, selector, inputStructCnt, kr);
        log_sel9("CallStructMethod", conn, selector, inputStruct, inputStructCnt,
                 outputStruct, outputStructCnt ? *outputStructCnt : 0, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === IOConnectCallAsyncMethod ===
HOOK_DECL(IOConnectCallAsyncMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    mach_port_t wakePort, uint64_t *reference, uint32_t referenceCnt,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt) {
    kern_return_t kr = orig_IOConnectCallAsyncMethod(conn, selector, wakePort, reference, referenceCnt,
        input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallAsyncMethod conn=%u sel=%u inSC=%zu kr=%d\n", g_calls, conn, selector, inputStructCnt, kr);
        log_sel9("CallAsyncMethod", conn, selector, inputStruct, inputStructCnt,
                 outputStruct, outputStructCnt ? *outputStructCnt : 0, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === IOConnectCallAsyncStructMethod ===
HOOK_DECL(IOConnectCallAsyncStructMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    mach_port_t wakePort, uint64_t *reference, uint32_t referenceCnt,
    const void *inputStruct, size_t inputStructCnt,
    void *outputStruct, size_t *outputStructCnt) {
    kern_return_t kr = orig_IOConnectCallAsyncStructMethod(conn, selector, wakePort, reference, referenceCnt,
        inputStruct, inputStructCnt, outputStruct, outputStructCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallAsyncStructMethod conn=%u sel=%u inSC=%zu kr=%d\n", g_calls, conn, selector, inputStructCnt, kr);
        log_sel9("CallAsyncStructMethod", conn, selector, inputStruct, inputStructCnt,
                 outputStruct, outputStructCnt ? *outputStructCnt : 0, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

// === IOConnectCallAsyncScalarMethod ===
HOOK_DECL(IOConnectCallAsyncScalarMethod, kern_return_t,
    mach_port_t conn, uint32_t selector,
    mach_port_t wakePort, uint64_t *reference, uint32_t referenceCnt,
    const uint64_t *input, uint32_t inputCnt,
    uint64_t *output, uint32_t *outputCnt) {
    kern_return_t kr = orig_IOConnectCallAsyncScalarMethod(conn, selector, wakePort, reference, referenceCnt,
        input, inputCnt, output, outputCnt);
    pthread_mutex_lock(&g_lock);
    if (g_log) {
        g_calls++;
        fprintf(g_log, "[%04d] CallAsyncScalarMethod conn=%u sel=%u kr=%d\n", g_calls, conn, selector, kr);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}

%ctor {
    syslog(LOG_NOTICE, "IOSBLIT_PROBE: ctor entered pid=%d", getpid());

    char path[1024];
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(path, sizeof path, "%s/Documents/iosblit_iokit.log", home);
        g_log = fopen(path, "w");
    }
    if (!g_log) {
        const char *fb[] = { "/tmp/iosblit_iokit.log", "/var/tmp/iosblit_iokit.log", NULL };
        for (int i = 0; fb[i] && !g_log; i++) g_log = fopen(fb[i], "w");
    }
    if (!g_log) g_log = stderr;
    fprintf(g_log, "==== iosblit_iokit_probe v2 pid=%d HOME=%s ====\n", getpid(), home ? home : "(null)");
    fflush(g_log);

    // Hook all variants. MSHookFunction handles arm64e PAC via libsubstrate's PAC-aware path.
    #define HOOK_ONE(name) do { \
        void *target = dlsym(RTLD_DEFAULT, #name); \
        if (target) { \
            MSHookFunction(target, (void *)&my_##name, (void **)&orig_##name); \
            fprintf(g_log, "  hooked %s @ %p (orig=%p)\n", #name, target, orig_##name); \
        } else { \
            fprintf(g_log, "  dlsym %s failed\n", #name); \
        } \
    } while (0)

    HOOK_ONE(IOServiceOpen);
    HOOK_ONE(IOConnectCallMethod);
    HOOK_ONE(IOConnectCallScalarMethod);
    HOOK_ONE(IOConnectCallStructMethod);
    HOOK_ONE(IOConnectCallAsyncMethod);
    HOOK_ONE(IOConnectCallAsyncStructMethod);
    HOOK_ONE(IOConnectCallAsyncScalarMethod);

    #undef HOOK_ONE
    fflush(g_log);
    syslog(LOG_NOTICE, "IOSBLIT_PROBE: hooks done");
}
