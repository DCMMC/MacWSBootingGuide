// metal_probe.m — local Mac probe: intercept IOConnectCallMethod, see what regions macOS XNU gives a normal Metal app
//
// Build:  clang -framework Foundation -framework Metal -framework IOKit -o metal_probe metal_probe.m
// Run:    ./metal_probe 2>&1 | tee mac_probe.log
//
// Compares against chroot WS REGION-DIFF data to answer: does macOS-on-real-Mac produce ONE big
// region 0x11 USC heap, or fragmented chunks across 0x0b..0x1b like the chroot does?
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
static int sel9_count = 0;

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

    // Log EVERY call to confirm interpose works + classify by selector
    pthread_mutex_lock(&log_lock);
    static int call_count = 0;
    int idx = ++call_count;
    if (idx <= 100) {
        fprintf(stderr, "  [iokit] #%03d conn=%u sel=%u inCnt=%u inSC=%zu outSC=%zu kr=%d\n",
                idx, conn, selector, inputCnt, inputStructCnt,
                outputStructCnt ? *outputStructCnt : 0, kr);
    }
    pthread_mutex_unlock(&log_lock);

    if (selector == 9 && kr == 0 && inputStruct && inputStructCnt >= 0x48 &&
        outputStruct && outputStructCnt && *outputStructCnt >= 0x20) {
        pthread_mutex_lock(&log_lock);
        int idx = ++sel9_count;
        const uint8_t *ib = inputStruct;
        const uint8_t *ob = outputStruct;
        uint64_t in10 = 0, in40 = 0;
        memcpy(&in10, ib + 0x10, 8);
        memcpy(&in40, ib + 0x40, 8);
        uint64_t out08 = 0, out18 = 0, out40 = 0;
        memcpy(&out08, ob + 0x08, 8);
        memcpy(&out18, ob + 0x18, 8);
        if (*outputStructCnt >= 0x48) memcpy(&out40, ob + 0x40, 8);
        fprintf(stderr,
            "#### sel=9 #%03d conn=%u inSC=%zu outSC=%zu | "
            "in+0x10=%#018llx in+0x40=%#llx | "
            "out+0x08=%#llx out+0x18=%#llx (REGION=0x%llx) out+0x40=%#llx\n",
            idx, conn, inputStructCnt, *outputStructCnt,
            (unsigned long long)in10, (unsigned long long)in40,
            (unsigned long long)out08, (unsigned long long)out18,
            (unsigned long long)(out18 >> 32),
            (unsigned long long)out40);
        pthread_mutex_unlock(&log_lock);
    }
    return kr;
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } \
   _interpose_##_replacee __attribute__ ((section ("__DATA,__interpose"))) = { \
       (const void*)(unsigned long)&_replacement, \
       (const void*)(unsigned long)&_replacee \
   };

DYLD_INTERPOSE(my_IOConnectCallMethod, IOConnectCallMethod)

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "==== local Mac M3 metal_probe — device=%s\n", [[dev name] UTF8String]);

        // Stage 1: a few buffers (different storage modes)
        fprintf(stderr, "\n---- STAGE 1: shared buffers ----\n");
        id<MTLBuffer> buf1 = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        fprintf(stderr, "[probe] shared buf gpuAddress=%#llx\n", (unsigned long long)buf1.gpuAddress);
        id<MTLBuffer> buf2 = [dev newBufferWithLength:65536 options:MTLResourceStorageModePrivate];
        fprintf(stderr, "[probe] private buf gpuAddress=%#llx\n", (unsigned long long)buf2.gpuAddress);

        // Stage 2: compute shader compile (triggers MTLCompilerService + shader heap allocation)
        fprintf(stderr, "\n---- STAGE 2: compute shader compile + dispatch ----\n");
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\n"
                        @"using namespace metal;\n"
                        @"kernel void cf(device uint *b [[buffer(0)]], uint i [[thread_position_in_grid]]) "
                        @"{ b[i] = 0xC0DEC0DE; }";
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { NSLog(@"[probe] lib err: %@", err); return 1; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"cf"];
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!ps) { NSLog(@"[probe] pso err: %@", err); return 2; }
        fprintf(stderr, "[probe] pipeline state created\n");

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:buf1 offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        fprintf(stderr, "[probe] dispatch status=%ld\n", (long)cb.status);
        uint32_t *p = (uint32_t *)[buf1 contents];
        fprintf(stderr, "[probe] readback[0]=%#x [63]=%#x (expect 0xC0DEC0DE)\n",
                p[0], p[63]);

        // Stage 3: heap probe (allocate explicit shader heap)
        fprintf(stderr, "\n---- STAGE 3: explicit shader heap allocation ----\n");
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.size = 256 * 1024 * 1024;  // 256 MB
        hd.storageMode = MTLStorageModePrivate;
        id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
        fprintf(stderr, "[probe] heap=%@\n", heap);

        fprintf(stderr, "\n==== DONE: %d sel=9 calls captured ====\n", sel9_count);
    }
    return 0;
}
