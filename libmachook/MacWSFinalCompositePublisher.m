#import "MacWSFinalCompositePublisher.h"

#import <IOSurface/IOSurfaceRef.h>
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/bootstrap.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "macws_final_composite_protocol.h"

static _Atomic uint64_t PublishedSequence;
static _Atomic bool ContentValidated;
static pthread_mutex_t ServiceLock = PTHREAD_MUTEX_INITIALIZER;
static mach_port_t CachedService = MACH_PORT_NULL;
static uint64_t ServiceRefreshDeadlineNS;
static _Atomic uint32_t FailureWitnesses;
static _Atomic uint32_t LookupWitnesses;
static NSObject *CompletionLock;
static id<MTLCommandBuffer> PendingCommand;
static IOSurfaceRef PendingSurface;
static uint32_t PendingPixelFormat;
static _Atomic bool CompletionWorkerRunning;

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

void MacWSFinalCompositePublisherEnqueueCompletion(
        id<MTLCommandBuffer> commandBuffer, IOSurfaceRef surface,
        uint32_t metalPixelFormat) {
    if (!commandBuffer || !surface || metalPixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ CompletionLock = [NSObject new]; });

    id<MTLCommandBuffer> retainedCommand = RetainObject(commandBuffer);
    IOSurfaceRef retainedSurface = (IOSurfaceRef)CFRetain(surface);
    @synchronized (CompletionLock) {
        id<MTLCommandBuffer> oldCommand = PendingCommand;
        IOSurfaceRef oldSurface = PendingSurface;
        PendingCommand = retainedCommand;
        PendingSurface = retainedSurface;
        PendingPixelFormat = metalPixelFormat;
        ReleaseObject(oldCommand);
        if (oldSurface) CFRelease(oldSurface);
    }
    if (atomic_exchange_explicit(&CompletionWorkerRunning, true,
                                 memory_order_acq_rel)) return;

    dispatch_async(CompletionQueue(), ^{
        for (;;) {
            @autoreleasepool {
                id<MTLCommandBuffer> command = nil;
                IOSurfaceRef completedSurface = NULL;
                uint32_t pixelFormat = 0;
                @synchronized (CompletionLock) {
                    if (!PendingCommand || !PendingSurface) {
                        atomic_store_explicit(&CompletionWorkerRunning, false,
                                              memory_order_release);
                        return;
                    }
                    command = PendingCommand;
                    completedSurface = PendingSurface;
                    pixelFormat = PendingPixelFormat;
                    PendingCommand = nil;
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
                    (void)MacWSFinalCompositePublisherPublishSurface(
                        completedSurface, pixelFormat);
                }
                ReleaseObject(command);
                CFRelease(completedSurface);
            }
        }
    });
}
