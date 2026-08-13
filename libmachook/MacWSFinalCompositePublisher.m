#import "MacWSFinalCompositePublisher.h"

#import <IOSurface/IOSurfaceRef.h>
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/bootstrap.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "macws_final_composite_protocol.h"

extern void MacWSHideNativeCursorAfterFirstComposite(void);

static _Atomic uint64_t PublishedSequence;
static _Atomic bool ContentValidated;
static pthread_mutex_t ServiceLock = PTHREAD_MUTEX_INITIALIZER;
static mach_port_t CachedService = MACH_PORT_NULL;
static uint64_t ServiceRefreshDeadlineNS;
static _Atomic uint32_t FailureWitnesses;
static _Atomic uint32_t LookupWitnesses;
static NSObject *CompletionLock;
static id<MTLCommandBuffer> PendingCommand;
static id<MTLTexture> PendingSourceTexture;
static IOSurfaceRef PendingSurface;
static uint32_t PendingPixelFormat;
static _Atomic bool CompletionWorkerRunning;

// The SkyLight display target is intentionally reused by WindowServer. A
// completion callback proves that one render finished, but it does not stop a
// later command buffer from modifying that same IOSurface while Host samples
// it. Preserve presentation effects (blur, shadows, Dock magnification) by
// copying the completed native composite on its own AGX command queue into a
// small pool of independent IOSurfaces. displayd marks a surface in-use while
// it or Host holds a lease, so a pool slot is never overwritten under a
// consumer.
enum { MacWSFinalCompositeSnapshotSlotCount = 4 };
typedef struct {
    IOSurfaceRef surface;
    id<MTLTexture> texture;
    id<MTLDevice> device;
    size_t width;
    size_t height;
    uint64_t lastPublishedNS;
} MacWSFinalCompositeSnapshotSlot;
static MacWSFinalCompositeSnapshotSlot SnapshotSlots[
    MacWSFinalCompositeSnapshotSlotCount];
static NSUInteger NextSnapshotSlot;
static _Atomic uint32_t SnapshotFailureWitnesses;

static bool DirectCompositeTransportRequested(void) {
    static bool direct;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *value = getenv("MACWS_FINAL_COMPOSITE_DIRECT");
        direct = value && value[0] && strcmp(value, "0") != 0;
    });
    return direct;
}

static void SnapshotLogFailure(const char *stage, id object) {
    uint32_t witness = atomic_fetch_add_explicit(
        &SnapshotFailureWitnesses, 1, memory_order_relaxed) + 1;
    if (witness <= 12) {
        dprintf(STDERR_FILENO,
            "#### FINAL-COMPOSITE snapshot-failed stage=%s witness=%u "
            "object=%p\n", stage, witness, (__bridge void *)object);
    }
}

static uint64_t MonotonicNanoseconds(void) {
    struct timespec now = {0};
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec : 0;
}

// Returns a caller-owned reference. CachedService remains an independent
// lookup anchor so concurrent publishers cannot invalidate a borrowed name.
static mach_port_t AcquireService(void) {
    uint64_t nowNS = MonotonicNanoseconds();
    pthread_mutex_lock(&ServiceLock);
    bool refreshDue = !MACH_PORT_VALID(CachedService) || nowNS == 0 ||
        nowNS >= ServiceRefreshDeadlineNS;
    if (refreshDue) {
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(
            bootstrap_port, MACWS_FINAL_COMPOSITE_MACH_SERVICE, &service);
        if (result == BOOTSTRAP_SUCCESS && MACH_PORT_VALID(service)) {
            if (service == CachedService) {
                (void)mach_port_deallocate(mach_task_self(), service);
            } else {
                mach_port_t previous = CachedService;
                CachedService = service;
                if (MACH_PORT_VALID(previous))
                    (void)mach_port_deallocate(mach_task_self(), previous);
            }
        } else {
            uint32_t witness = atomic_fetch_add_explicit(
                &LookupWitnesses, 1, memory_order_relaxed) + 1;
            if (witness <= 8) {
                dprintf(STDERR_FILENO,
                    "#### FINAL-COMPOSITE bootstrap-lookup-failed "
                    "witness=%u bootstrap=%u cached=%u returned=%u kr=%#x\n",
                    witness, bootstrap_port, CachedService, service, result);
            }
        }
        // displayd may replace its receive right while an old send right still
        // accepts queued messages. Refresh once per second even without an
        // INVALID_DEST result so a static desktop recovers after a relaunch.
        ServiceRefreshDeadlineNS = nowNS ? nowNS + NSEC_PER_SEC : 0;
    }
    mach_port_t result = CachedService;
    if (MACH_PORT_VALID(result) && mach_port_mod_refs(
            mach_task_self(), result, MACH_PORT_RIGHT_SEND, 1) !=
            KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), result);
        CachedService = MACH_PORT_NULL;
        ServiceRefreshDeadlineNS = 0;
        result = MACH_PORT_NULL;
    }
    pthread_mutex_unlock(&ServiceLock);
    return result;
}

static void InvalidateService(mach_port_t failedService) {
    pthread_mutex_lock(&ServiceLock);
    if (CachedService == failedService) {
        (void)mach_port_deallocate(mach_task_self(), failedService);
        CachedService = MACH_PORT_NULL;
        ServiceRefreshDeadlineNS = 0;
    }
    pthread_mutex_unlock(&ServiceLock);
}

static mach_msg_return_t SendMessage(
        MacWSFinalCompositeMachMessage *message, mach_port_t service) {
    if (!message || !MACH_PORT_VALID(service)) return MACH_SEND_INVALID_DEST;
    message->header.msgh_remote_port = service;
    return mach_msg(&message->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    sizeof(*message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
}

void MacWSFinalCompositePublisherMarkContentValidated(void) {
    atomic_store_explicit(&ContentValidated, true, memory_order_release);
    MacWSHideNativeCursorAfterFirstComposite();
}

bool MacWSFinalCompositePublisherCanPublish(void) {
    return atomic_load_explicit(&ContentValidated, memory_order_acquire);
}

uint64_t MacWSFinalCompositePublisherPublishedSequence(void) {
    return atomic_load_explicit(&PublishedSequence, memory_order_relaxed);
}

bool MacWSFinalCompositePublisherPublishSurface(
        IOSurfaceRef surface, uint32_t metalPixelFormat) {
    if (!surface || metalPixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return false;

    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    uint32_t ioSurfacePixelFormat = IOSurfaceGetPixelFormat(surface);
    if (ioSurfacePixelFormat == 0)
        ioSurfacePixelFormat = MACWS_FINAL_COMPOSITE_BGRA;
    MacWSFinalCompositeRecord record = {
        .magic = MACWS_FINAL_COMPOSITE_MAGIC,
        .version = MACWS_FINAL_COMPOSITE_VERSION,
        .size = sizeof(MacWSFinalCompositeRecord),
        .producerPID = getpid(),
        .surfaceID = IOSurfaceGetID(surface),
        .sequence = atomic_fetch_add_explicit(
            &PublishedSequence, 1, memory_order_relaxed) + 1,
        .completionTime = mach_absolute_time(),
        .width = width <= UINT32_MAX ? (uint32_t)width : 0,
        .height = height <= UINT32_MAX ? (uint32_t)height : 0,
        .bytesPerRow = bytesPerRow <= UINT32_MAX
            ? (uint32_t)bytesPerRow : 0,
        .ioSurfacePixelFormat = ioSurfacePixelFormat,
        .metalPixelFormat = metalPixelFormat,
    };
    if (!MacWSFinalCompositeRecordIsValid(&record, sizeof(record)))
        return false;

    mach_port_t service = AcquireService();
    if (!MACH_PORT_VALID(service)) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=bootstrap-lookup "
                "witness=%u sequence=%llu surface=%u\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID);
        }
        return false;
    }
    mach_port_t surfacePort = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(surfacePort)) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=surface-port "
                "witness=%u sequence=%llu surface=%u service=%u\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID, service);
        }
        (void)mach_port_deallocate(mach_task_self(), service);
        return false;
    }

    MacWSFinalCompositeMachMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(
        MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = service;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = MACWS_FINAL_COMPOSITE_MACH_MESSAGE_ID;
    message.body.msgh_descriptor_count = 1;
    message.surfacePort.name = surfacePort;
    message.surfacePort.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.surfacePort.type = MACH_MSG_PORT_DESCRIPTOR;
    message.record = record;
    mach_msg_return_t result = SendMessage(&message, service);
    if (result == MACH_SEND_INVALID_DEST) {
        InvalidateService(service);
        (void)mach_port_deallocate(mach_task_self(), service);
        service = AcquireService();
        if (MACH_PORT_VALID(service)) result = SendMessage(&message, service);
    }
    (void)mach_port_deallocate(mach_task_self(), surfacePort);
    if (result == MACH_SEND_INVALID_DEST) InvalidateService(service);
    if (MACH_PORT_VALID(service))
        (void)mach_port_deallocate(mach_task_self(), service);
    if (result != MACH_MSG_SUCCESS) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=mach-msg "
                "witness=%u sequence=%llu surface=%u service=%u kr=%d\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID, service, result);
        }
    }
    if (result == MACH_MSG_SUCCESS)
        MacWSHideNativeCursorAfterFirstComposite();
    return result == MACH_MSG_SUCCESS;
}

static dispatch_queue_t CompletionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.macwsguide.final-composite-observer",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static id RetainObject(id object) {
#if __has_feature(objc_arc)
    return object;
#else
    return [object retain];
#endif
}

static void ReleaseObject(id object) {
#if __has_feature(objc_arc)
    (void)object;
#else
    [object release];
#endif
}

static void ResetSnapshotSlot(MacWSFinalCompositeSnapshotSlot *slot) {
    if (!slot) return;
    ReleaseObject(slot->texture);
    ReleaseObject(slot->device);
    if (slot->surface) CFRelease(slot->surface);
    memset(slot, 0, sizeof(*slot));
}

static MacWSFinalCompositeSnapshotSlot *AcquireSnapshotSlot(
        id<MTLDevice> device, size_t width, size_t height) {
    if (!device || width == 0 || height == 0 || width > UINT32_MAX ||
        height > UINT32_MAX || width > SIZE_MAX / 4) return NULL;
    size_t tightBytesPerRow = width * 4;
    size_t bytesPerRow = (tightBytesPerRow + 63) & ~(size_t)63;
    if (bytesPerRow < tightBytesPerRow || height > SIZE_MAX / bytesPerRow)
        return NULL;

    uint64_t nowNS = MonotonicNanoseconds();
    for (NSUInteger attempt = 0;
         attempt < MacWSFinalCompositeSnapshotSlotCount; attempt++) {
        NSUInteger index = (NextSnapshotSlot + attempt) %
            MacWSFinalCompositeSnapshotSlotCount;
        MacWSFinalCompositeSnapshotSlot *slot = &SnapshotSlots[index];
        BOOL compatible = slot->surface && slot->texture &&
            slot->device == device && slot->width == width &&
            slot->height == height;
        if (slot->surface && !compatible) {
            if (IOSurfaceIsInUse(slot->surface)) continue;
            ResetSnapshotSlot(slot);
        }
        if (slot->surface) {
            // Four 120-Hz frames already provide ~33 ms for displayd to take
            // its cross-process use-count. Keep the explicit minimum as a
            // handoff guard if frames were coalesced unusually quickly.
            if (IOSurfaceIsInUse(slot->surface) ||
                (nowNS && slot->lastPublishedNS &&
                 nowNS - slot->lastPublishedNS < 30 * NSEC_PER_MSEC)) {
                continue;
            }
            NextSnapshotSlot = (index + 1) %
                MacWSFinalCompositeSnapshotSlotCount;
            return slot;
        }

        NSDictionary *properties = @{
            (__bridge id)kIOSurfaceWidth: @(width),
            (__bridge id)kIOSurfaceHeight: @(height),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
            (__bridge id)kIOSurfaceBytesPerRow: @(bytesPerRow),
            (__bridge id)kIOSurfaceAllocSize: @(bytesPerRow * height),
            (__bridge id)kIOSurfacePixelFormat:
                @(MACWS_FINAL_COMPOSITE_BGRA),
        };
        IOSurfaceRef surface = IOSurfaceCreate(
            (__bridge CFDictionaryRef)properties);
        if (!surface) {
            SnapshotLogFailure("iosurface-create", device);
            return NULL;
        }
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead |
            MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device
            newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        if (!texture) {
            CFRelease(surface);
            SnapshotLogFailure("texture-create", device);
            return NULL;
        }
        slot->surface = surface;
        slot->texture = RetainObject(texture);
        slot->device = RetainObject(device);
        slot->width = width;
        slot->height = height;
        ReleaseObject(texture);
        NextSnapshotSlot = (index + 1) %
            MacWSFinalCompositeSnapshotSlotCount;
        return slot;
    }
    return NULL;
}

static bool SnapshotAndPublish(id<MTLCommandBuffer> completedCommand,
                               id<MTLTexture> sourceTexture,
                               uint32_t pixelFormat) {
    if (!completedCommand || !sourceTexture ||
        pixelFormat != MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM)
        return false;
    id<MTLCommandQueue> queue = completedCommand.commandQueue;
    id<MTLDevice> device = sourceTexture.device;
    size_t width = sourceTexture.width;
    size_t height = sourceTexture.height;
    if (!queue || !device || width == 0 || height == 0) {
        SnapshotLogFailure("source", sourceTexture);
        return false;
    }
    MacWSFinalCompositeSnapshotSlot *slot = AcquireSnapshotSlot(
        device, width, height);
    if (!slot) return false;

    id<MTLCommandBuffer> copyCommand = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [copyCommand blitCommandEncoder];
    if (!copyCommand || !blit) {
        SnapshotLogFailure("command", queue);
        return false;
    }
    [blit copyFromTexture:sourceTexture
              sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:slot->texture
         destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [copyCommand commit];

    MTLCommandBufferStatus status = copyCommand.status;
    unsigned polls = 0;
    while (status != MTLCommandBufferStatusCompleted &&
           status != MTLCommandBufferStatusError && polls < 2000) {
        usleep(500);
        status = copyCommand.status;
        polls++;
    }
    if (status != MTLCommandBufferStatusCompleted || copyCommand.error) {
        SnapshotLogFailure("copy-completion", copyCommand);
        return false;
    }
    bool published = MacWSFinalCompositePublisherPublishSurface(
        slot->surface, pixelFormat);
    if (published) slot->lastPublishedNS = MonotonicNanoseconds();
    return published;
}

void MacWSFinalCompositePublisherEnqueueCompletion(
        id<MTLCommandBuffer> commandBuffer, id<MTLTexture> sourceTexture,
        IOSurfaceRef surface,
        uint32_t metalPixelFormat) {
    if (!commandBuffer || !sourceTexture || !surface || metalPixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ CompletionLock = [NSObject new]; });

    id<MTLCommandBuffer> retainedCommand = RetainObject(commandBuffer);
    id<MTLTexture> retainedSource = RetainObject(sourceTexture);
    IOSurfaceRef retainedSurface = (IOSurfaceRef)CFRetain(surface);
    @synchronized (CompletionLock) {
        id<MTLCommandBuffer> oldCommand = PendingCommand;
        id<MTLTexture> oldSource = PendingSourceTexture;
        IOSurfaceRef oldSurface = PendingSurface;
        PendingCommand = retainedCommand;
        PendingSourceTexture = retainedSource;
        PendingSurface = retainedSurface;
        PendingPixelFormat = metalPixelFormat;
        ReleaseObject(oldCommand);
        ReleaseObject(oldSource);
        if (oldSurface) CFRelease(oldSurface);
    }
    if (atomic_exchange_explicit(&CompletionWorkerRunning, true,
                                 memory_order_acq_rel)) return;

    dispatch_async(CompletionQueue(), ^{
        for (;;) {
            @autoreleasepool {
                id<MTLCommandBuffer> command = nil;
                id<MTLTexture> sourceTexture = nil;
                IOSurfaceRef completedSurface = NULL;
                uint32_t pixelFormat = 0;
                @synchronized (CompletionLock) {
                    if (!PendingCommand || !PendingSourceTexture ||
                        !PendingSurface) {
                        atomic_store_explicit(&CompletionWorkerRunning, false,
                                              memory_order_release);
                        return;
                    }
                    command = PendingCommand;
                    sourceTexture = PendingSourceTexture;
                    completedSurface = PendingSurface;
                    pixelFormat = PendingPixelFormat;
                    PendingCommand = nil;
                    PendingSourceTexture = nil;
                    PendingSurface = NULL;
                    PendingPixelFormat = 0;
                }
                MTLCommandBufferStatus status = command.status;
                unsigned polls = 0;
                while (status != MTLCommandBufferStatusCompleted &&
                       status != MTLCommandBufferStatusError && polls < 2000) {
                    usleep(1000);
                    status = command.status;
                    polls++;
                }
                if (status == MTLCommandBufferStatusCompleted &&
                    command.error == nil &&
                    MacWSFinalCompositePublisherCanPublish()) {
                    if (DirectCompositeTransportRequested()) {
                        (void)MacWSFinalCompositePublisherPublishSurface(
                            completedSurface, pixelFormat);
                    } else {
                        (void)SnapshotAndPublish(command, sourceTexture,
                                                 pixelFormat);
                    }
                }
                ReleaseObject(command);
                ReleaseObject(sourceTexture);
                CFRelease(completedSurface);
            }
        }
    });
}
