#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <substrate.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "macws_audio_bridge.h"

typedef OSStatus (*MacWSAudioUnitSetPropertyFn)(
    AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
    const void *, UInt32);
typedef OSStatus (*MacWSAudioUnitGetPropertyFn)(
    AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
    void *, UInt32 *);

typedef struct {
    AURenderCallback original;
    void *originalContext;
    AudioStreamBasicDescription format;
    MacWSAudioRingHeader *ring;
    int16_t scratch[4096 * MACWS_AUDIO_CHANNELS];
} MacWSAudioRenderContext;

static MacWSAudioUnitSetPropertyFn gMacWSOriginalAudioUnitSetProperty;
static MacWSAudioUnitGetPropertyFn gMacWSAudioUnitGetProperty;
static _Atomic(bool) gMacWSAudioHookInstalled;

static MacWSAudioRingHeader *MacWSMapAudioRing(void) {
    int descriptor = open(MACWS_AUDIO_RING_CHROOT_PATH,
                          O_RDWR | O_CLOEXEC);
    if (descriptor < 0) return NULL;
    const size_t bytes = (size_t)MacWSAudioRingBytes(
        MACWS_AUDIO_RING_CAPACITY_FRAMES);
    void *mapping = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                         MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) return NULL;
    MacWSAudioRingHeader *header = mapping;
    if (__atomic_load_n(&header->magic, __ATOMIC_ACQUIRE) !=
            MACWS_AUDIO_RING_MAGIC ||
        header->version != MACWS_AUDIO_RING_VERSION ||
        header->sampleRate != MACWS_AUDIO_SAMPLE_RATE ||
        header->channels != MACWS_AUDIO_CHANNELS ||
        header->capacityFrames != MACWS_AUDIO_RING_CAPACITY_FRAMES) {
        munmap(mapping, bytes);
        return NULL;
    }
    return header;
}

static float MacWSReadAudioSample(const AudioBufferList *buffers,
                                  const AudioStreamBasicDescription *format,
                                  UInt32 frame, UInt32 channel) {
    if (!buffers || !format || buffers->mNumberBuffers == 0) return 0.0f;
    const bool nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 bufferIndex = nonInterleaved &&
            channel < buffers->mNumberBuffers ? channel : 0;
    const AudioBuffer *buffer = &buffers->mBuffers[bufferIndex];
    if (!buffer->mData) return 0.0f;
    const UInt32 channels = nonInterleaved ? 1 :
        (format->mChannelsPerFrame ?: buffer->mNumberChannels ?: 1);
    const UInt64 sampleIndex = (UInt64)frame * channels +
        (nonInterleaved ? 0 : channel % channels);
    const UInt32 bytesPerSample = format->mBitsPerChannel / 8;
    if (bytesPerSample == 0 ||
        (sampleIndex + 1) * bytesPerSample > buffer->mDataByteSize)
        return 0.0f;
    const uint8_t *source = buffer->mData;
    if ((format->mFormatFlags & kAudioFormatFlagIsFloat) &&
        format->mBitsPerChannel == 32) {
        return ((const float *)source)[sampleIndex];
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
        format->mBitsPerChannel == 16) {
        return ((const int16_t *)source)[sampleIndex] / 32768.0f;
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
        format->mBitsPerChannel == 32) {
        return ((const int32_t *)source)[sampleIndex] / 2147483648.0f;
    }
    return 0.0f;
}

static void MacWSPublishAudio(MacWSAudioRenderContext *context,
                              const AudioBufferList *buffers,
                              UInt32 sourceFrames) {
    if (!context || !buffers || sourceFrames == 0 ||
        context->format.mFormatID != kAudioFormatLinearPCM)
        return;
    if (!context->ring) context->ring = MacWSMapAudioRing();
    MacWSAudioRingHeader *header = context->ring;
    if (!header) return;

    // Audio render callbacks must never wait behind another process. Drop a
    // single quantum on contention; the next callback arrives in a few ms.
    if (__atomic_exchange_n(&header->reserved[0], 1,
                            __ATOMIC_ACQUIRE) != 0)
        return;

    double sourceRate = context->format.mSampleRate;
    if (sourceRate < 1.0) sourceRate = MACWS_AUDIO_SAMPLE_RATE;
    UInt32 outputFrames = (UInt32)(
        sourceFrames * (double)MACWS_AUDIO_SAMPLE_RATE / sourceRate + 0.5);
    if (outputFrames > 4096) outputFrames = 4096;
    uint16_t peak = 0;
    for (UInt32 outputFrame = 0; outputFrame < outputFrames; outputFrame++) {
        UInt32 sourceFrame = (UInt32)(
            outputFrame * sourceRate / (double)MACWS_AUDIO_SAMPLE_RATE);
        if (sourceFrame >= sourceFrames) sourceFrame = sourceFrames - 1;
        for (UInt32 channel = 0; channel < MACWS_AUDIO_CHANNELS; channel++) {
            UInt32 sourceChannel = context->format.mChannelsPerFrame > 1
                ? channel : 0;
            float value = MacWSReadAudioSample(
                buffers, &context->format, sourceFrame, sourceChannel);
            if (value > 1.0f) value = 1.0f;
            if (value < -1.0f) value = -1.0f;
            int16_t converted = (int16_t)(value * 32767.0f);
            context->scratch[outputFrame * MACWS_AUDIO_CHANNELS + channel] =
                converted;
            uint16_t magnitude = converted == INT16_MIN ? 32768 :
                (uint16_t)(converted < 0 ? -converted : converted);
            if (magnitude > peak) peak = magnitude;
        }
    }

    const uint64_t capacity = header->capacityFrames;
    uint64_t writeFrame = __atomic_load_n(
        &header->writeFrame, __ATOMIC_RELAXED);
    uint64_t offset = writeFrame % capacity;
    uint64_t firstFrames = capacity - offset;
    if (firstFrames > outputFrames) firstFrames = outputFrames;
    int16_t *ringSamples = (int16_t *)(header + 1);
    size_t firstSamples = (size_t)firstFrames * MACWS_AUDIO_CHANNELS;
    memcpy(ringSamples + offset * MACWS_AUDIO_CHANNELS, context->scratch,
           firstSamples * sizeof(*ringSamples));
    UInt32 remaining = outputFrames - (UInt32)firstFrames;
    if (remaining) {
        memcpy(ringSamples, context->scratch + firstSamples,
               (size_t)remaining * MACWS_AUDIO_CHANNELS *
                   sizeof(*ringSamples));
    }
    if (peak >= 8) {
        __atomic_store_n(&header->lastAudibleMachTime,
                         mach_continuous_time(), __ATOMIC_RELEASE);
    }
    __atomic_add_fetch(&header->callbackCount, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&header->writeFrame, writeFrame + outputFrames,
                     __ATOMIC_RELEASE);
    __atomic_store_n(&header->reserved[0], 0, __ATOMIC_RELEASE);
}

static OSStatus MacWSAudioRenderCallback(
        void *reference, AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
        AudioBufferList *buffers) {
    MacWSAudioRenderContext *context = reference;
    OSStatus status = context && context->original
        ? context->original(context->originalContext, flags, timestamp, bus,
                            frames, buffers)
        : kAudio_ParamError;
    if (status == noErr && buffers) MacWSPublishAudio(context, buffers, frames);
    return status;
}

static OSStatus MacWSAudioUnitSetProperty(
        AudioUnit unit, AudioUnitPropertyID property,
        AudioUnitScope scope, AudioUnitElement element,
        const void *data, UInt32 dataSize) {
    if (!gMacWSOriginalAudioUnitSetProperty) return kAudio_ParamError;
    if (property != kAudioUnitProperty_SetRenderCallback ||
        scope != kAudioUnitScope_Input || !data ||
        dataSize != sizeof(AURenderCallbackStruct)) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    const AURenderCallbackStruct *callback = data;
    if (!callback->inputProc) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    MacWSAudioRenderContext *context = calloc(1, sizeof(*context));
    if (!context) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    context->original = callback->inputProc;
    context->originalContext = callback->inputProcRefCon;
    UInt32 formatSize = sizeof(context->format);
    if (!gMacWSAudioUnitGetProperty ||
        gMacWSAudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, scope, element,
            &context->format, &formatSize) != noErr) {
        free(context);
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    AURenderCallbackStruct wrapped = {
        .inputProc = MacWSAudioRenderCallback,
        .inputProcRefCon = context,
    };
    OSStatus status = gMacWSOriginalAudioUnitSetProperty(
        unit, property, scope, element, &wrapped, sizeof(wrapped));
    if (status != noErr) free(context);
    return status;
}

void MacWSInstallAudioRenderBridge(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(
            &gMacWSAudioHookInstalled, &expected, true))
        return;
    void *setProperty = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    gMacWSAudioUnitGetProperty = (MacWSAudioUnitGetPropertyFn)
        dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");
    if (!setProperty || !gMacWSAudioUnitGetProperty) {
        atomic_store(&gMacWSAudioHookInstalled, false);
        return;
    }
    MSHookFunction(setProperty, (void *)MacWSAudioUnitSetProperty,
                   (void **)&gMacWSOriginalAudioUnitSetProperty);
}

__attribute__((constructor)) static void MacWSInitializeAudioRenderBridge(void) {
    const char *enabled = getenv("MACWS_AUDIO_RENDER_BRIDGE");
    if (!enabled || strcmp(enabled, "1") != 0) return;
    MacWSInstallAudioRenderBridge();
}
