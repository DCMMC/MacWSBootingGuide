#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "macws_interop_protocol.h"
#include "macws_host_protocol.h"
#include "macws_stream_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

static int Near(float lhs, float rhs) {
    return fabsf(lhs - rhs) < 0.0001f;
}

int main(void) {
    assert(MacWSDecideTouchCandidate(0.10, 0.0, false) ==
           MacWSTouchCandidateDecisionWait);
    assert(MacWSDecideTouchCandidate(0.44, 5.99, true) ==
           MacWSTouchCandidateDecisionTap);
    assert(MacWSDecideTouchCandidate(0.10, 6.0, false) ==
           MacWSTouchCandidateDecisionDrag);
    assert(MacWSDecideTouchCandidate(0.45, 5.99, false) ==
           MacWSTouchCandidateDecisionSecondaryTap);
    assert(MacWSDecideTouchCandidate(0.45, 6.0, false) ==
           MacWSTouchCandidateDecisionSecondaryTap);

    MacWSViewport viewport = {0};
    assert(MacWSComputeViewport(1600, 1000, 600, 800, 1, 0.5, 0.5,
                                &viewport));
    assert(Near(viewport.visibleSource.width, 0.46875f));
    assert(Near(viewport.visibleSource.height, 1.0f));
    assert(Near(viewport.visibleSource.x, 0.265625f));
    assert(Near(viewport.visibleSource.y, 0.0f));
    assert(MacWSComputeViewport(1600, 1000, 600, 800, 1.5, 0.5, 0.5,
                                &viewport));
    assert(Near(viewport.visibleSource.width, 0.3125f));
    assert(Near(viewport.visibleSource.height, 2.0f / 3.0f));
    MacWSNormalizedPoint sourceAnchor = {0.42f, 0.55f};
    MacWSNormalizedPoint requestedCenter = MacWSViewportCenterKeepingAnchor(
        viewport.visibleSource, sourceAnchor, 0.35f, 0.60f);
    assert(MacWSComputeViewport(1600, 1000, 600, 800, 1.5,
                                requestedCenter.x, requestedCenter.y,
                                &viewport));
    MacWSNormalizedPoint preservedAnchor =
        MacWSViewportMapPoint(&viewport, 0.35f, 0.60f);
    assert(Near(preservedAnchor.x, sourceAnchor.x));
    assert(Near(preservedAnchor.y, sourceAnchor.y));
    assert(MacWSComputeViewport(1600, 1000, 600, 800, 2, 0.5, 0.5,
                                &viewport));
    assert(Near(viewport.visibleSource.width, 0.234375f));
    assert(Near(viewport.visibleSource.height, 0.5f));
    MacWSNormalizedPoint mapped = MacWSViewportMapPoint(&viewport, 0, 1);
    assert(Near(mapped.x, viewport.visibleSource.x));
    assert(Near(mapped.y, viewport.visibleSource.y +
                          viewport.visibleSource.height));
    assert(MacWSComputeViewport(1000, 1600, 1200, 600, 10, -1, 2,
                                &viewport));
    assert(Near(viewport.zoom, 2.0f));
    assert(Near(viewport.visibleSource.x, 0.0f));
    assert(Near(viewport.visibleSource.y + viewport.visibleSource.height,
                1.0f));
    assert(!MacWSComputeViewport(0, 1000, 600, 800, 1, 0.5, 0.5,
                                 &viewport));

    uint64_t windowScene = MacWSInputSceneForWindow(0x12345678u, 0x00120000u);
    assert(MacWSInputWindowIDForScene(windowScene) == 0x12345678u);
    assert(MacWSInputModifiersForScene(windowScene) == 0x00120000u);
    assert(MacWSInputWindowIDForScene(0x564e430000000001ull) == 0);

    unsigned char metricsBytes[sizeof(MacWSWindowMetricsHeader) +
                               sizeof(MacWSWindowMetricsEntry)] = {0};
    MacWSWindowMetricsHeader *metrics = (void *)metricsBytes;
    *metrics = (MacWSWindowMetricsHeader){
        .magic = MACWS_WINDOW_METRICS_MAGIC,
        .version = MACWS_WINDOW_METRICS_VERSION,
        .size = sizeof(*metrics),
        .entrySize = sizeof(MacWSWindowMetricsEntry),
        .entryCount = 1,
        .generation = 1,
    };
    assert(MacWSWindowMetricsAreValid(metrics, sizeof(metricsBytes)));
    assert(!MacWSWindowMetricsAreValid(metrics, sizeof(*metrics)));

    MacWSStreamFrameDescriptor frame = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(frame),
        .streamID = 1,
        .windowID = 42,
        .leaseToken = 7,
        .sequence = 9,
        .width = 2732,
        .height = 2048,
        .bytesPerRow = 2732 * 4,
        .pixelFormat = 0x42475241u,
        .backingScale = 2.0f,
    };
    assert(MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));
    frame.bytesPerRow = 1;
    assert(!MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));

    const char title[] = "Terminal";
    unsigned char windowBytes[sizeof(MacWSStreamWindowDescriptor) + sizeof(title) - 1];
    memset(windowBytes, 0, sizeof(windowBytes));
    MacWSStreamWindowDescriptor *window = (void *)windowBytes;
    *window = (MacWSStreamWindowDescriptor){
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(*window),
        .windowID = 12,
        .ownerPID = 99,
        .logicalWidth = 800,
        .logicalHeight = 600,
        .pixelWidth = 1600,
        .pixelHeight = 1200,
        .backingScale = 2.0f,
        .titleLength = sizeof(title) - 1,
    };
    memcpy(windowBytes + sizeof(*window), title, sizeof(title) - 1);
    assert(MacWSStreamWindowDescriptorIsValid(window, sizeof(windowBytes)));
    assert(!MacWSStreamWindowDescriptorIsValid(window, sizeof(*window)));

    MacWSInteropItemDescriptor item = {
        .magic = MACWS_INTEROP_MAGIC,
        .version = MACWS_INTEROP_VERSION,
        .size = sizeof(item),
        .kind = MacWSInteropKindPNG,
        .flags = MacWSInteropInlinePayload | MacWSInteropFromIOS,
        .generation = 1,
        .originID = 2,
        .payloadLength = 4096,
    };
    assert(MacWSInteropItemDescriptorIsValid(&item, sizeof(item)));
    item.flags |= MacWSInteropStagedFile;
    assert(!MacWSInteropItemDescriptorIsValid(&item, sizeof(item)));

    puts("macws protocol validators: PASS");
    return 0;
}
