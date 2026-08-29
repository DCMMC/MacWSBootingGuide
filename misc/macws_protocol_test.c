#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "macws_interop_protocol.h"
#include "macws_composite_candidate_policy.h"
#include "macws_display_geometry.h"
#include "macws_final_composite_protocol.h"
#include "macws_host_protocol.h"
#include "macws_menu_protocol.h"
#include "macws_stream_protocol.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"

static int Near(float lhs, float rhs) {
    return fabsf(lhs - rhs) < 0.0001f;
}

int main(void) {
    assert(MacWSCompositeCandidateShouldReplace(
        false, false, 0, false, 3983184));
    // A larger offscreen target must not poison a later owned desktop target.
    assert(MacWSCompositeCandidateShouldReplace(
        true, false, 4255000, true, 3983184));
    assert(!MacWSCompositeCandidateShouldReplace(
        true, true, 3983184, false, 4255000));
    // Within the same update, unowned fallbacks still select by area.
    assert(MacWSCompositeCandidateShouldReplace(
        true, false, 1000, false, 2000));
    assert(!MacWSCompositeCandidateShouldReplace(
        true, false, 2000, false, 1000));
    // Later owned scanouts represent the later composite in the update.
    assert(MacWSCompositeCandidateShouldReplace(
        true, true, 3983184, true, 3983184));
    size_t physicalWidth = 0, physicalHeight = 0;
    assert(MacWSPhysicalDisplayExtent(1194.0, 834.0, 2.0, 8192,
                                      &physicalWidth, &physicalHeight));
    assert(physicalWidth == 2388 && physicalHeight == 1668);
    assert(!MacWSPhysicalDisplayExtent(1194.0, 834.0, 0.0, 8192,
                                       &physicalWidth, &physicalHeight));
    assert(!MacWSPhysicalDisplayExtent(5000.0, 5000.0, 2.0, 8192,
                                       &physicalWidth, &physicalHeight));
    assert(MacWSLayerCoversLogicalDisplay(
        0.0, 0.0, 1194.0, 834.0, 0.0, 0.0, 1194.0, 834.0));
    assert(MacWSLayerCoversLogicalDisplay(
        -0.25, -0.25, 1194.25, 834.25,
        0.0, 0.0, 1194.0, 834.0));
    assert(!MacWSLayerCoversLogicalDisplay(
        0.0, 0.0, 1194.0, 417.0, 0.0, 0.0, 1194.0, 834.0));
    assert(MACWS_INPUT_VERSION == 5u);
    assert(MACWS_STREAM_VERSION == 8u);
    assert(MACWS_FINAL_COMPOSITE_VERSION == 1u);
    assert(sizeof(MacWSFinalCompositeRecord) == 56);
    assert(sizeof(MacWSInputRecord) == 84);
    assert(MacWSInputSourcePencil != MacWSInputSourceFinger);
    assert(MacWSInputKindDesktopCommand == 20);
    assert(MacWSInputKindSystemGesture == 21);
    assert(MacWSInputKindRotate == 22);
    assert(MacWSSystemGestureAxisHorizontal == 1);
    assert(MacWSSystemGestureAxisVertical == 2);
    assert(!MacWSStreamFrameSupersedesLayerRemoval(7, 41, 7, 41));
    assert(!MacWSStreamFrameSupersedesLayerRemoval(7, 40, 7, 41));
    assert(MacWSStreamFrameSupersedesLayerRemoval(7, 42, 7, 41));
    assert(MacWSStreamFrameSupersedesLayerRemoval(8, 1, 7, 41));
    assert(!MacWSStreamFrameSupersedesLayerRemoval(7, 42, 7, 0));
    assert(MacWSDesktopCommandMissionControl !=
           MacWSDesktopCommandApplicationWindows);
    assert(MacWSDesktopCommandSpaceLeft == 3);
    assert(MacWSDesktopCommandSpaceRight == 4);
    assert((MacWSInputFlagDoubleClick & MacWSInputFlagScrollBegan) == 0);
    assert((MacWSInputFlagGlobalSystemSurface &
            (MacWSInputFlagDoubleClick | MacWSInputFlagScrollBegan |
             MacWSInputFlagGestureChanged)) == 0);
    uint64_t fullscreenPointerScene =
        MacWSInputSceneForWindow(0, 0x1234u);
    assert(MacWSInputWindowIDForScene(fullscreenPointerScene) == 0);
    assert(MacWSInputModifiersForScene(fullscreenPointerScene) == 0x1234u);
    assert(MacWSDecideTouchCandidate(0.10, 0.0, false) ==
           MacWSTouchCandidateDecisionWait);
    assert(MacWSDecideTouchCandidate(0.44, 7.99, true) ==
           MacWSTouchCandidateDecisionTap);
    assert(MacWSDecideTouchCandidate(0.10, 8.0, false) ==
           MacWSTouchCandidateDecisionScroll);
    assert(MacWSDecideTouchCandidate(0.45, 7.99, false) ==
           MacWSTouchCandidateDecisionLongPress);
    // Movement wins when timer delivery and the touch sample arrive together;
    // an already-moving finger must not become a delayed long press.
    // The movement sample itself occurred after the hardware hold threshold:
    // this is hold-then-drag even if the main-queue feedback timer was late.
    assert(MacWSDecideTouchCandidate(0.45, 8.0, false) ==
           MacWSTouchCandidateDecisionLongPress);
    assert(!MacWSTouchReachedLongPress(0.10));
    assert(!MacWSTouchReachedLongPress(0.449));
    assert(MacWSTouchReachedLongPress(0.45));
    assert(MacWSIsDirectDoubleTap(10.0, 10.40, 20.0, 20.0));
    assert(!MacWSIsDirectDoubleTap(10.0, 10.43, 0.0, 0.0));
    assert(!MacWSIsDirectDoubleTap(10.0, 10.20, 44.1, 0.0));
    assert(!MacWSShouldStartScrollMomentum(79.99, 0.0));
    assert(MacWSShouldStartScrollMomentum(80.0, 0.0));
    assert(MacWSShouldStartScrollMomentum(60.0, 60.0));
    assert(Near((float)MacWSAppKitRotationDegreesForUIKitRadians(
                    3.14159265358979323846 / 2.0), -90.0f));
    assert(Near((float)MacWSAppKitRotationDegreesForUIKitRadians(
                    -3.14159265358979323846 / 4.0), 45.0f));
    assert(MacWSInputSupersedesPendingVisibilitySample(
        MacWSInputKindHover, MacWSInputKindTap));
    assert(MacWSInputSupersedesPendingVisibilitySample(
        MacWSInputKindHover, MacWSInputKindSecondaryTap));
    assert(!MacWSInputSupersedesPendingVisibilitySample(
        MacWSInputKindScroll, MacWSInputKindTap));
    assert(!MacWSInputSupersedesPendingVisibilitySample(
        MacWSInputKindHover, MacWSInputKindTouchMove));
    assert(MACWS_THREE_FINGER_CHORD_GRACE_SECONDS >= 0.08);
    assert(MACWS_THREE_FINGER_CHORD_GRACE_SECONDS <= 0.15);
    assert(MacWSChooseDirectScrollAxis(2.0, 6.0) ==
           MacWSDirectScrollAxisVertical);
    assert(MacWSChooseDirectScrollAxis(6.0, 4.6) ==
           MacWSDirectScrollAxisFree);
    assert(MacWSChooseDirectScrollAxis(6.0, 4.0) ==
           MacWSDirectScrollAxisHorizontal);
    assert(MacWSClassifyThreeFingerPan(-100.0, 10.0, 0.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureLeft);
    assert(MacWSClassifyThreeFingerPan(100.0, 10.0, 0.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureRight);
    assert(MacWSClassifyThreeFingerPan(10.0, -100.0, 0.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureUp);
    assert(MacWSClassifyThreeFingerPan(10.0, 100.0, 0.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureDown);
    assert(MacWSClassifyThreeFingerPan(30.0, 30.0, 1500.0, 1500.0, 800.0) ==
           MacWSThreeFingerGestureNone);
    assert(MacWSClassifyThreeFingerPan(-30.0, 2.0, -1000.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureLeft);
    assert(MacWSClassifyThreeFingerPan(-27.0, 1.0, -1000.0, 0.0, 800.0) ==
           MacWSThreeFingerGestureNone);
    assert(MacWSSystemGestureAxisForTranslation(-12.0, 1.0, 800.0) ==
           MacWSSystemGestureAxisHorizontal);
    assert(MacWSSystemGestureAxisForTranslation(1.0, -12.0, 800.0) ==
           MacWSSystemGestureAxisVertical);
    assert(MacWSSystemGestureAxisForTranslation(5.0, 0.0, 800.0) == 0);
    assert(MacWSSystemGestureAxisForTranslation(12.0, 12.0, 800.0) ==
           MacWSSystemGestureAxisVertical);
    assert(MacWSSystemGestureAxisForTranslation(11.0, 12.0, 800.0) ==
           MacWSSystemGestureAxisVertical);
    assert(MacWSSystemGestureAxisForTranslation(12.0, 11.0, 800.0) ==
           MacWSSystemGestureAxisHorizontal);
    assert(Near((float)MacWSSystemGestureReferenceDistance(834.0),
                233.52f));
    // UIKit finger-left/finger-up are both negative, but Dock's verified
    // private gesture progress uses different signs for the two axes.
    assert(Near((float)MacWSSystemGestureProgressForDisplacement(
                    MacWSSystemGestureAxisHorizontal, -120.0, 240.0),
                0.5f));
    assert(Near((float)MacWSSystemGestureProgressForDisplacement(
                    MacWSSystemGestureAxisHorizontal, 120.0, 240.0),
                -0.5f));
    assert(Near((float)MacWSSystemGestureProgressForDisplacement(
                    MacWSSystemGestureAxisVertical, -120.0, 240.0),
                -0.5f));
    assert(Near((float)MacWSSystemGestureProgressForDisplacement(
                    MacWSSystemGestureAxisVertical, 120.0, 240.0),
                0.5f));
    assert(MacWSSystemGestureProgressForDisplacement(0, -120.0, 240.0) ==
           0.0);
    assert(MacWSSystemGestureProgressForDisplacement(
               MacWSSystemGestureAxisVertical, -120.0, 0.0) == 0.0);
    double constrainedX = 2.0, constrainedY = -9.0;
    MacWSConstrainDirectScrollDelta(MacWSDirectScrollAxisVertical,
                                    &constrainedX, &constrainedY);
    assert(constrainedX == 0.0 && constrainedY == -9.0);
    constrainedX = 4.0;
    constrainedY = -7.0;
    MacWSConstrainDirectScrollDelta(MacWSDirectScrollAxisFree,
                                    &constrainedX, &constrainedY);
    assert(constrainedX == 4.0 && constrainedY == -7.0);

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
        .contentWidth = 2732,
        .contentHeight = 2048,
        .layerWindowID = 42,
        .destinationWidth = 2732,
        .destinationHeight = 2048,
    };
    assert(MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));
    assert((MacWSStreamFrameInputPassthrough &
            MacWSStreamFrameGlobalSystemSurface) == 0);
    frame.flags = MacWSStreamFrameComplete |
        MacWSStreamFrameFinalComposite;
    frame.windowID = 0;
    frame.layerWindowID = UINT32_MAX;
    assert(MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));
    frame.flags |= MacWSStreamFrameOverlay;
    assert(!MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));
    MacWSFinalCompositeRecord finalRecord = {
        .magic = MACWS_FINAL_COMPOSITE_MAGIC,
        .version = MACWS_FINAL_COMPOSITE_VERSION,
        .size = sizeof(finalRecord),
        .producerPID = 42,
        .surfaceID = 7,
        .sequence = 1,
        .completionTime = 2,
        .width = 2388,
        .height = 1668,
        .bytesPerRow = 9600,
        .ioSurfacePixelFormat = MACWS_FINAL_COMPOSITE_BGRA,
        .metalPixelFormat = MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM,
    };
    assert(MacWSFinalCompositeRecordIsValid(
        &finalRecord, sizeof(finalRecord)));
    finalRecord.bytesPerRow = finalRecord.width * 4u - 1u;
    assert(!MacWSFinalCompositeRecordIsValid(
        &finalRecord, sizeof(finalRecord)));
    frame.flags = MacWSStreamFrameComplete;
    frame.windowID = 42;
    frame.layerWindowID = 42;
    frame.destinationX = 200;
    frame.destinationY = 100;
    frame.destinationWidth = 1000;
    frame.destinationHeight = 800;
    frame.contentWidth = 1000;
    frame.contentHeight = 800;
    float layerX = 0.0f, layerY = 0.0f;
    assert(MacWSStreamMapDesktopPointToLayer(
        &frame, 400.0f, 300.0f, &layerX, &layerY));
    assert(Near(layerX, 200.0f));
    assert(Near(layerY, 200.0f));
    // WindowServer moved the live window 50 px after the first drag sample.
    // The gesture snapshot must still map the next desktop sample through the
    // original destination: local x=300 reconstructs desktop x=500. Mapping
    // through a live destination x=250 would incorrectly yield x=250 and feed
    // the 50-px window displacement back against the user's finger.
    assert(MacWSStreamMapDesktopPointToLayer(
        &frame, 500.0f, 300.0f, &layerX, &layerY));
    assert(Near(layerX, 300.0f));
    MacWSStreamFrameDescriptor movedFrame = frame;
    movedFrame.destinationX = 250;
    assert(MacWSStreamMapDesktopPointToLayer(
        &movedFrame, 500.0f, 300.0f, &layerX, &layerY));
    assert(Near(layerX, 250.0f));
    MacWSStreamLayerGeometry layerGeometry = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(layerGeometry),
        .streamID = frame.streamID,
        .sequence = frame.sequence + 1,
        .displayTime = 1,
        .windowID = 0,
        .layerWindowID = frame.layerWindowID,
        .layerOwnerPID = 99,
        .layerLevel = 12,
        .destinationX = -100,
        .destinationY = 20,
        .destinationWidth = 1000,
        .destinationHeight = 800,
        .flags = MacWSStreamFrameOverlay,
    };
    assert(MacWSStreamLayerGeometryIsValid(&layerGeometry,
                                            sizeof(layerGeometry)));
    assert(MacWSStreamLayerGeometrySupersedesFrame(&layerGeometry, &frame));
    layerGeometry.sequence = frame.sequence;
    assert(!MacWSStreamLayerGeometrySupersedesFrame(&layerGeometry, &frame));
    layerGeometry.sequence++;
    layerGeometry.streamID++;
    assert(!MacWSStreamLayerGeometrySupersedesFrame(&layerGeometry, &frame));
    layerGeometry.streamID = frame.streamID;
    layerGeometry.flags = 0;
    assert(!MacWSStreamLayerGeometryIsValid(&layerGeometry,
                                             sizeof(layerGeometry)));
    layerGeometry.flags = MacWSStreamFrameOverlay;
    layerGeometry.destinationWidth = MACWS_STREAM_MAX_DIMENSION + 1;
    assert(!MacWSStreamLayerGeometryIsValid(&layerGeometry,
                                             sizeof(layerGeometry)));
    frame.bytesPerRow = 1;
    assert(!MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));
    frame.bytesPerRow = 2732 * 4;
    frame.contentX = 1000;
    frame.contentWidth = 2000;
    assert(!MacWSStreamFrameDescriptorIsValid(&frame, sizeof(frame)));

    MacWSGeometryInvalidation geometry = {
        .magic = MACWS_GEOMETRY_INVALIDATION_MAGIC,
        .version = MACWS_GEOMETRY_INVALIDATION_VERSION,
        .size = sizeof(geometry),
        .windowID = 42,
        .pixelWidth = 1868,
        .pixelHeight = 1184,
    };
    assert(MacWSGeometryInvalidationIsValid(&geometry, sizeof(geometry)));
    assert(!MacWSGeometryInvalidationIsValid(&geometry,
                                              sizeof(geometry) - 1));
    geometry.pixelWidth = MACWS_STREAM_MAX_DIMENSION + 1;
    assert(!MacWSGeometryInvalidationIsValid(&geometry, sizeof(geometry)));

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
        .logicalGroupID = 12,
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

    MacWSMenuRequest menuRequest = {
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(menuRequest),
        .operation = MacWSMenuOperationSnapshot,
        .nonce = 1,
        .ownerPID = 99,
        .windowID = 12,
    };
    assert(MacWSMenuRequestIsValid(&menuRequest, sizeof(menuRequest)));
    menuRequest.itemID = 1;
    assert(!MacWSMenuRequestIsValid(&menuRequest, sizeof(menuRequest)));

    unsigned char menuBytes[sizeof(MacWSMenuResponseHeader) +
                            sizeof(MacWSMenuNode) + 4] = {0};
    MacWSMenuResponseHeader *menu = (void *)menuBytes;
    *menu = (MacWSMenuResponseHeader){
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(*menu),
        .status = MacWSMenuStatusOK,
        .nonce = 1,
        .ownerPID = 99,
        .windowID = 12,
        .generation = 2,
        .nodeCount = 1,
        .stringBytes = 4,
        .totalBytes = sizeof(menuBytes),
    };
    MacWSMenuNode *menuNode = (void *)(menuBytes + sizeof(*menu));
    *menuNode = (MacWSMenuNode){
        .itemID = 1,
        .titleLength = 4,
    };
    memcpy(menuBytes + sizeof(*menu) + sizeof(*menuNode), "File", 4);
    assert(MacWSMenuResponseIsValid(menu, sizeof(menuBytes)));
    menuNode->titleLength = 5;
    assert(!MacWSMenuResponseIsValid(menu, sizeof(menuBytes)));

    puts("macws protocol validators: PASS");
    return 0;
}
